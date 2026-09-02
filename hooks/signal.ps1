<#
.SYNOPSIS
    Claude Code completion signaller for Windows.

.DESCRIPTION
    One script, invoked directly by a Claude Code hook. Reads the hook payload on
    stdin, decides whether the moment is worth interrupting you for, and if so
    raises a branded Windows toast, plus optional speech and phone push.

    Design rules, learned from the previous version:
      - never write to stdout. Another hook may return JSON there.
      - always exit 0. A broken cue must never disturb a turn.
      - stay fast. Everything slow (speech) is detached, not awaited.

.PARAMETER Signal
    done       Claude finished a turn.
    needsInput Claude is blocked on you: permission prompt or agent question.
    idle       You did not come back. Fires ~60s after Stop. The escalation.
    failed     The turn ended on an API error.
    turnStart  Bookkeeping only: stamps the turn start time for the duration gate.
    speakNow   Internal: the detached half of text-to-speech.
    test       Fire every signal once, ignoring gates.

.PARAMETER Reason
    Free text recorded in the log (notification_type, error kind, and so on).
#>
[CmdletBinding()]
param(
    [ValidateSet('done', 'needsInput', 'idle', 'failed', 'turnStart', 'speakNow', 'test')]
    [string]$Signal = '',

    [string]$Reason = ''
)

$ErrorActionPreference = 'Stop'

$Root         = Split-Path -Parent $PSScriptRoot
$ConfigPath   = Join-Path $Root 'config.json'
$StateDir     = Join-Path $Root '.state'
$LogPath      = Join-Path $Root 'logs\signaler.log'
$SpeechPath   = Join-Path $StateDir 'speech.txt'
$CooldownPath = Join-Path $StateDir 'last-signal.txt'
$FocusDll     = Join-Path $StateDir 'foreground.dll'

# --- plumbing ---------------------------------------------------------------

$script:LogEnabled  = $true
$script:LogMaxLines = 400

function Write-Log {
    param([string]$Message)
    if (-not $script:LogEnabled) { return }
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
        Add-Content -Path $LogPath -Value "$stamp  $Message" -Encoding utf8
    } catch {
        # Logging must never be the reason a cue does not fire.
    }
}

function Limit-Log {
    try {
        if (-not (Test-Path $LogPath)) { return }
        # Reading the whole log back was the most expensive thing this script did,
        # on every single turn, growing as the log grew. Check the cheap byte count
        # first and only pay for the trim once there is actually something to trim.
        if ((Get-Item $LogPath).Length -lt ($script:LogMaxLines * 200)) { return }
        $lines = @(Get-Content -Path $LogPath)
        if ($lines.Count -le $script:LogMaxLines) { return }
        $lines[-$script:LogMaxLines..-1] | Set-Content -Path $LogPath -Encoding utf8
    } catch {
    }
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Initialize-StateDir {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
}

# --- config -----------------------------------------------------------------

function Get-SignalerConfig {
    if (-not (Test-Path $ConfigPath)) { return $null }
    try {
        return Get-Content -Path $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-Log "config.json unreadable, using defaults: $($_.Exception.Message)"
        return $null
    }
}

$Config = Get-SignalerConfig

$loggingCfg = Get-Prop $Config 'logging'
$script:LogEnabled  = [bool](Get-Prop $loggingCfg 'enabled' $true)
$script:LogMaxLines = [int](Get-Prop $loggingCfg 'maxLines' 400)

# --- hook payload -----------------------------------------------------------

function Read-Payload {
    try {
        if (-not [Console]::IsInputRedirected) { return $null }
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

# Notification types that mean "Claude is blocked on you right now".
$NeedsInputTypes = @(
    'permission_prompt',
    'agent_needs_input',
    'elicitation_dialog',
    'elicitation_url_dialog'
)

function Get-SignalFromPayload {
    param($Payload)
    $hookEvent = [string](Get-Prop $Payload 'hook_event_name' '')
    $type      = [string](Get-Prop $Payload 'notification_type' '')

    switch ($hookEvent) {
        'Stop'        { return @('done', 'Stop') }
        'StopFailure' { return @('failed', 'StopFailure') }
        'Notification' {
            if ($NeedsInputTypes -contains $type) { return @('needsInput', $type) }
            if ($type -eq 'idle_prompt')     { return @('idle', $type) }
            if ($type -eq 'agent_completed') { return @('done', $type) }
            return @($null, $type)
        }
    }
    return @($null, $hookEvent)
}

# --- gates ------------------------------------------------------------------

function Test-Cooldown {
    param([int]$WindowMs)
    if ($WindowMs -le 0) { return $true }
    try {
        Initialize-StateDir
        if (Test-Path $CooldownPath) {
            $stamp = (Get-Content -Path $CooldownPath -Raw).Trim()
            $last = [DateTime]::Parse($stamp, $null, [Globalization.DateTimeStyles]::RoundtripKind)
            if (([DateTime]::UtcNow - $last).TotalMilliseconds -lt $WindowMs) { return $false }
        }
        [DateTime]::UtcNow.ToString('o') | Set-Content -Path $CooldownPath -Encoding utf8
    } catch {
    }
    return $true
}

function Get-ForegroundTitle {
    # The P/Invoke type is pre-compiled by install.ps1 so a real signal never pays
    # the ~500ms csc cost. No DLL means no focus gate: fail open and notify.
    try {
        if (-not (Test-Path $FocusDll)) { return $null }
        Add-Type -Path $FocusDll -ErrorAction Stop
        return [ClaudeSignaler.Foreground]::Title()
    } catch {
        return $null
    }
}

function Test-Focused {
    param([string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $false }
    $title = Get-ForegroundTitle
    if ([string]::IsNullOrWhiteSpace($title)) { return $false }
    return ($title -match $Pattern)
}

function Get-TurnStampPath {
    param([string]$SessionId)
    $safe = $SessionId -replace '[^A-Za-z0-9_-]', ''
    return (Join-Path $StateDir ('turn-' + $safe + '.txt'))
}

function Get-TurnSeconds {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return -1 }
    try {
        $path = Get-TurnStampPath $SessionId
        if (-not (Test-Path $path)) { return -1 }
        $stamp = (Get-Content -Path $path -Raw).Trim()
        $started = [DateTime]::Parse($stamp, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        return [int]([DateTime]::UtcNow - $started).TotalSeconds
    } catch {
        return -1
    }
}

function Set-TurnStart {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return }
    try {
        Initialize-StateDir
        [DateTime]::UtcNow.ToString('o') | Set-Content -Path (Get-TurnStampPath $SessionId) -Encoding utf8

        # Sweep stamps older than a day so .state does not grow without bound.
        Get-ChildItem -Path $StateDir -Filter 'turn-*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
    }
}

# --- message ----------------------------------------------------------------

function Get-RepoName {
    param([string]$Cwd)
    if ([string]::IsNullOrWhiteSpace($Cwd)) { return 'Claude Code' }
    try { return Split-Path -Leaf $Cwd } catch { return 'Claude Code' }
}

function Get-Summary {
    param([string]$Text, [int]$MaxChars)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    # Fenced code blocks read as noise once collapsed onto one line.
    $clean = [regex]::Replace($Text, '(?s)```.*?```', ' ')
    $clean = [regex]::Replace($clean, '[`*_#>|]', '')
    $clean = [regex]::Replace($clean, '\s+', ' ').Trim()

    if ($clean.Length -le $MaxChars) { return $clean }
    $cut = $clean.Substring(0, $MaxChars)
    $lastSpace = $cut.LastIndexOf(' ')
    if ($lastSpace -gt ($MaxChars * 0.6)) { $cut = $cut.Substring(0, $lastSpace) }
    return $cut.TrimEnd() + '...'
}

# --- outputs ----------------------------------------------------------------

function Show-Toast {
    param([string]$Aumid, [string]$Title, [string]$Body, [string]$Sound)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

        $audio = '<audio silent="true"/>'
        if (-not [string]::IsNullOrWhiteSpace($Sound)) {
            $audio = '<audio src="ms-winsoundevent:' + [Security.SecurityElement]::Escape($Sound) + '"/>'
        }

        $safeTitle = [Security.SecurityElement]::Escape($Title)
        $safeBody  = [Security.SecurityElement]::Escape($Body)

        $xml = '<toast><visual><binding template="ToastGeneric">' +
               '<text>' + $safeTitle + '</text>' +
               '<text>' + $safeBody + '</text>' +
               '</binding></visual>' + $audio + '</toast>'

        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid).Show($toast)
        return $true
    } catch {
        Write-Log "toast failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-FallbackSound {
    param([string]$SignalName)
    try {
        switch ($SignalName) {
            'failed'     { [System.Media.SystemSounds]::Hand.Play() }
            'needsInput' { [System.Media.SystemSounds]::Exclamation.Play() }
            'idle'       { [System.Media.SystemSounds]::Exclamation.Play() }
            default      { [System.Media.SystemSounds]::Asterisk.Play() }
        }
    } catch {
    }
}

function Start-Speech {
    param([string]$Text)
    # Speaking blocks for seconds. Hand it to a detached, window-less PowerShell
    # so the hook returns immediately and the turn is never held up.
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return }
        Initialize-StateDir
        $Text | Set-Content -Path $SpeechPath -Encoding utf8

        $self = Join-Path $PSScriptRoot 'signal.ps1'
        $cmd  = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $self + '" -Signal speakNow'
        $shell = New-Object -ComObject WScript.Shell
        # 0 = no window is ever created, $false = do not wait for it to finish.
        [void]$shell.Run($cmd, 0, $false)
    } catch {
        Write-Log "speech launch failed: $($_.Exception.Message)"
    }
}

function Invoke-SpeakNow {
    try {
        if (-not (Test-Path $SpeechPath)) { return }
        $text = (Get-Content -Path $SpeechPath -Raw -Encoding utf8).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return }

        $speechCfg = Get-Prop $Config 'speech'
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $synth.Rate   = [int](Get-Prop $speechCfg 'rate' 1)
        $synth.Volume = [int](Get-Prop $speechCfg 'volume' 80)
        $synth.Speak($text)
        $synth.Dispose()
    } catch {
        Write-Log "speech failed: $($_.Exception.Message)"
    }
}

function Send-Push {
    param([string]$Title, [string]$Body, [string]$SignalName)
    try {
        $pushCfg = Get-Prop $Config 'push'
        if (-not [bool](Get-Prop $pushCfg 'enabled' $false)) { return }
        $topic = [string](Get-Prop $pushCfg 'ntfyTopic' '')
        if ([string]::IsNullOrWhiteSpace($topic)) { return }

        $server = [string](Get-Prop $pushCfg 'server' 'https://ntfy.sh')

        $priority = 'default'
        if ($SignalName -eq 'needsInput' -or $SignalName -eq 'idle') { $priority = 'high' }

        $tag = 'robot'
        if ($SignalName -eq 'failed') { $tag = 'warning' }

        $headers = @{
            Title    = $Title
            Priority = $priority
            Tags     = $tag
        }

        # ntfy takes the message as a raw UTF-8 body.
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        Invoke-RestMethod -Uri "$server/$topic" -Method Post -Body $bytes -Headers $headers -TimeoutSec 5 | Out-Null
    } catch {
        Write-Log "push failed: $($_.Exception.Message)"
    }
}

# --- main -------------------------------------------------------------------

function Invoke-Signal {
    param([string]$Name, $Payload, [switch]$Force)

    $events = Get-Prop $Config 'events'
    $entry  = Get-Prop $events $Name

    if (-not $Force) {
        if (-not [bool](Get-Prop $entry 'enabled' $true)) {
            Write-Log "$Name skipped: disabled in config"
            return
        }
    }

    $sessionId = [string](Get-Prop $Payload 'session_id' '')
    $cwd       = [string](Get-Prop $Payload 'cwd' '')
    $repo      = Get-RepoName $cwd
    $turnSecs  = Get-TurnSeconds $sessionId

    if (-not $Force) {
        $minSecs = [int](Get-Prop $entry 'minTurnSeconds' 0)
        if ($minSecs -gt 0 -and $turnSecs -ge 0 -and $turnSecs -lt $minSecs) {
            Write-Log "$Name skipped: turn was ${turnSecs}s, under ${minSecs}s"
            return
        }

        if ([string](Get-Prop $Config 'whenFocused' 'silent') -ne 'full') {
            if (Test-Focused ([string](Get-Prop $Config 'focusPattern' 'Claude Code'))) {
                Write-Log "$Name skipped: you are already looking at it"
                return
            }
        }

        if (-not (Test-Cooldown ([int](Get-Prop $Config 'cooldownMs' 1500)))) {
            Write-Log "$Name skipped: inside cooldown window"
            return
        }
    }

    $toastCfg = Get-Prop $Config 'toast'
    $aumid    = [string](Get-Prop $toastCfg 'aumid' 'Claude_pzs8sxrjxfjjc!Claude')
    $maxChars = [int](Get-Prop $toastCfg 'bodyMaxChars' 180)

    $headline = switch ($Name) {
        'done'       { "$repo - finished" }
        'needsInput' { "$repo - needs you" }
        'idle'       { "$repo - still waiting" }
        'failed'     { "$repo - turn failed" }
        default      { $repo }
    }
    if ($Name -eq 'done' -and $turnSecs -gt 0) {
        $headline = "$headline (${turnSecs}s)"
    }

    $summary = Get-Summary ([string](Get-Prop $Payload 'last_assistant_message' '')) $maxChars
    if ([string]::IsNullOrWhiteSpace($summary)) {
        $summary = switch ($Name) {
            'needsInput' { 'Waiting on a permission prompt or a question.' }
            'idle'       { 'Claude has been idle since it handed control back.' }
            'failed'     { 'The turn ended on an API error.' }
            default      { 'Claude handed control back to you.' }
        }
    }

    $shown = $false
    if ([bool](Get-Prop $entry 'toast' $true)) {
        $shown = Show-Toast $aumid $headline $summary ([string](Get-Prop $entry 'sound' 'Notification.Default'))
    }
    if (-not $shown) {
        Invoke-FallbackSound $Name
    }

    if ([bool](Get-Prop $entry 'speak' $false)) {
        $speechCfg = Get-Prop $Config 'speech'
        $words  = [int](Get-Prop $speechCfg 'maxWords' 14)
        $spoken = ($summary -split '\s+' | Select-Object -First $words) -join ' '
        Start-Speech "$repo. $spoken"
    }

    if ([bool](Get-Prop $entry 'push' $false)) {
        Send-Push $headline $summary $Name
    }

    Write-Log "$Name fired: repo=$repo turn=${turnSecs}s reason=$Reason toast=$shown"
}

try {
    $payload = Read-Payload

    $name = $Signal
    if ([string]::IsNullOrWhiteSpace($name)) {
        $pair = Get-SignalFromPayload $payload
        $name = [string]$pair[0]
        if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = [string]$pair[1] }
    }

    switch ($name) {
        'speakNow'  { Invoke-SpeakNow }
        'turnStart' { Set-TurnStart ([string](Get-Prop $payload 'session_id' '')) }
        'test' {
            foreach ($n in @('done', 'needsInput', 'idle', 'failed')) {
                Invoke-Signal $n $payload -Force
                Start-Sleep -Milliseconds 1600
            }
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                Invoke-Signal $name $payload
            }
        }
    }

    Limit-Log
} catch {
    try { Write-Log "unhandled: $($_.Exception.Message)" } catch { }
}

exit 0
