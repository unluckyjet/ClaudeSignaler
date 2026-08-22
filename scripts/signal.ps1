<#
.SYNOPSIS
    Pauses whatever is playing, plays a cue so you hear it, then resumes.

.DESCRIPTION
    Called by the Claude Code hook in hooks/signaler.js. Best effort by design:
    every failure path still tries to make a sound, and the script always exits 0
    so it can never disturb a Claude Code turn.

    Media control goes through the WinRT global system media transport controls,
    which give an explicit Pause and Play instead of the media-key toggle. That
    matters: a toggle would start music when nothing was playing.

.PARAMETER Signal
    Which config.json events entry to use: done, needsInput, or failed.

.PARAMETER Reason
    Free-text detail written to the log (notification_type, error kind, etc).

.PARAMETER NoCooldown
    Ignore the cooldown window. Used by the installer's --test.
#>
[CmdletBinding()]
param(
    [ValidateSet('done', 'needsInput', 'failed')]
    [string]$Signal = 'done',

    [string]$Reason = '',

    [switch]$NoCooldown,

    # Build the foreground-detection DLL and exit. Used by the installer so the
    # one-off ~512ms C# compile never lands on a real signal.
    [switch]$Prewarm
)

$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow

$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root 'config.json'
$SoundsDir = Join-Path $Root 'sounds'
$WarmDir = Join-Path $SoundsDir 'warm'
$StampPath = Join-Path $SoundsDir '.render-stamp.json'
$StateDir = Join-Path $Root '.state'
$CooldownPath = Join-Path $StateDir 'last-signal.txt'
$LogPath = Join-Path $Root 'logs\signaler.log'

$script:LogEnabled = $true
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
        # Logging must never be the reason the cue does not play.
    }
}

function Limit-Log {
    try {
        if (-not (Test-Path $LogPath)) { return }
        $lines = @(Get-Content -Path $LogPath)
        if ($lines.Count -le ($script:LogMaxLines * 2)) { return }
        $lines[-$script:LogMaxLines..-1] | Set-Content -Path $LogPath -Encoding utf8
    } catch {
    }
}

# --- config -----------------------------------------------------------------

function Get-SignalerConfig {
    $defaults = [ordered]@{
        Cue           = 'ready'
        Enabled       = $true
        Volume        = 0.32
        LeadInMs      = 400
        SampleRate    = 48000
        Mode          = 'pause'
        Resume        = $true
        SettleMs      = 180
        ResumeDelayMs = 250
        CooldownMs    = 1200
        LogEnabled    = $true
        LogMaxLines   = 400

        ShakeEnabled    = $true
        ShakeDurationMs = 1000
        ShakeAmplitude  = 45

        FocusedMode    = 'quiet'
        FocusedPattern = 'Claude Code'
    }

    if (-not (Test-Path $ConfigPath)) { return $defaults }

    try {
        $raw = Get-Content -Path $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-Log "config.json unreadable, using defaults: $($_.Exception.Message)"
        return $defaults
    }

    $entry = $null
    if ($raw.events -and $raw.events.PSObject.Properties.Name -contains $Signal) {
        $entry = $raw.events.$Signal
    }
    if ($entry) {
        if ($null -ne $entry.cue) { $defaults.Cue = [string]$entry.cue }
        if ($null -ne $entry.enabled) { $defaults.Enabled = [bool]$entry.enabled }
    }

    if ($raw.audio) {
        if ($null -ne $raw.audio.volume) { $defaults.Volume = [double]$raw.audio.volume }
        if ($null -ne $raw.audio.leadInMs) { $defaults.LeadInMs = [int]$raw.audio.leadInMs }
        if ($null -ne $raw.audio.sampleRate) { $defaults.SampleRate = [int]$raw.audio.sampleRate }
    }
    if ($raw.media) {
        if ($null -ne $raw.media.mode) { $defaults.Mode = [string]$raw.media.mode }
        if ($null -ne $raw.media.resume) { $defaults.Resume = [bool]$raw.media.resume }
        if ($null -ne $raw.media.settleMs) { $defaults.SettleMs = [int]$raw.media.settleMs }
        if ($null -ne $raw.media.resumeDelayMs) { $defaults.ResumeDelayMs = [int]$raw.media.resumeDelayMs }
    }
    if ($raw.shake) {
        if ($null -ne $raw.shake.enabled) { $defaults.ShakeEnabled = [bool]$raw.shake.enabled }
        if ($null -ne $raw.shake.durationMs) { $defaults.ShakeDurationMs = [int]$raw.shake.durationMs }
        if ($null -ne $raw.shake.amplitude) { $defaults.ShakeAmplitude = [int]$raw.shake.amplitude }
    }
    # Per-event override wins over the global shake switch.
    if ($entry -and $null -ne $entry.shake) { $defaults.ShakeEnabled = [bool]$entry.shake }

    if ($raw.whenFocused) {
        if ($null -ne $raw.whenFocused.mode) { $defaults.FocusedMode = [string]$raw.whenFocused.mode }
        if ($null -ne $raw.whenFocused.titlePattern) {
            $defaults.FocusedPattern = [string]$raw.whenFocused.titlePattern
        }
    }

    if ($null -ne $raw.cooldownMs) { $defaults.CooldownMs = [int]$raw.cooldownMs }
    if ($raw.logging) {
        if ($null -ne $raw.logging.enabled) { $defaults.LogEnabled = [bool]$raw.logging.enabled }
        if ($null -ne $raw.logging.maxLines) { $defaults.LogMaxLines = [int]$raw.logging.maxLines }
    }

    return $defaults
}

# --- WAV freshness ----------------------------------------------------------

function Test-RenderStale {
    param($Config, [string]$WavPath)

    if (-not (Test-Path $WavPath)) { return $true }
    if (-not (Test-Path $StampPath)) { return $true }

    try {
        $stamp = Get-Content -Path $StampPath -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        return $true
    }

    if ([math]::Abs([double]$stamp.volume - $Config.Volume) -gt 0.0001) { return $true }
    if ([int]$stamp.leadInMs -ne $Config.LeadInMs) { return $true }
    if ([int]$stamp.sampleRate -ne $Config.SampleRate) { return $true }
    return $false
}

function Invoke-Render {
    try {
        Write-Log 'render: config changed or WAV missing, re-rendering cues'
        $renderer = Join-Path $PSScriptRoot 'render-sounds.js'
        & node $renderer 2>&1 | ForEach-Object { Write-Log "render: $_" }
    } catch {
        Write-Log "render failed: $($_.Exception.Message)"
    }
}

# --- foreground window ------------------------------------------------------

$ForegroundSource = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace ClaudeSignaler {
    public class Foreground {
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
        public static string Title() {
            IntPtr handle = GetForegroundWindow();
            if (handle == IntPtr.Zero) return "";
            StringBuilder text = new StringBuilder(512);
            GetWindowTextW(handle, text, text.Capacity);
            return text.ToString();
        }
    }
}
'@

<#
Compiling this C# with Add-Type costs ~512ms, far too much to pay on every
signal. So it is compiled to a DLL once and loaded with -Path after that,
which measures ~20ms. Built on first use and by the installer's prewarm.
#>
function Initialize-Foreground {
    if ('ClaudeSignaler.Foreground' -as [type]) { return $true }

    try {
        $dll = Join-Path $PSScriptRoot 'lib\foreground.dll'
        if (-not (Test-Path $dll)) {
            $dir = Split-Path -Parent $dll
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Add-Type -TypeDefinition $ForegroundSource -OutputAssembly $dll
            Write-Log "built $dll"
        }
        if (-not ('ClaudeSignaler.Foreground' -as [type])) { Add-Type -Path $dll }
        return $true
    } catch {
        Write-Log "foreground detection unavailable: $($_.Exception.Message)"
        return $false
    }
}

<# Title of whatever window has focus right now, or '' if it cannot be read. #>
function Get-ForegroundTitle {
    if (-not (Initialize-Foreground)) { return '' }
    try {
        return [ClaudeSignaler.Foreground]::Title()
    } catch {
        return ''
    }
}

# --- WinRT media sessions ---------------------------------------------------

$script:AsTaskGeneric = $null

function Initialize-WinRt {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
}

function Wait-WinRt {
    param($Operation, [Type]$ResultType)
    $asTask = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task = $asTask.Invoke($null, @($Operation))
    if (-not $task.Wait(3000)) { throw 'WinRT operation timed out' }
    return $task.Result
}

<# Pauses every session currently Playing. Returns the sessions it paused. #>
function Suspend-PlayingMedia {
    $paused = New-Object System.Collections.ArrayList

    Initialize-WinRt
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime] | Out-Null
    $manager = Wait-WinRt ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

    foreach ($session in $manager.GetSessions()) {
        $status = $null
        try { $status = $session.GetPlaybackInfo().PlaybackStatus.ToString() } catch { continue }
        if ($status -ne 'Playing') { continue }

        try {
            $ok = Wait-WinRt ($session.TryPauseAsync()) ([bool])
            if ($ok) {
                [void]$paused.Add($session)
                Write-Log "paused $($session.SourceAppUserModelId)"
            } else {
                Write-Log "pause refused by $($session.SourceAppUserModelId)"
            }
        } catch {
            Write-Log "pause failed for $($session.SourceAppUserModelId): $($_.Exception.Message)"
        }
    }

    return $paused
}

<# Resumes only sessions this script paused, and only if still Paused. #>
function Resume-Media {
    param($Sessions)

    foreach ($session in $Sessions) {
        try {
            # Resume unless something already restarted it. Deliberately not
            # "only if still Paused": apps report Stopped/Changing while paused,
            # and the worst outcome here by far is leaving the music dead.
            $status = $session.GetPlaybackInfo().PlaybackStatus.ToString()
            if ($status -eq 'Playing') {
                Write-Log "skip resume for $($session.SourceAppUserModelId), already playing"
                continue
            }
            [void](Wait-WinRt ($session.TryPlayAsync()) ([bool]))
            Write-Log "resumed $($session.SourceAppUserModelId)"
        } catch {
            Write-Log "resume failed for $($session.SourceAppUserModelId): $($_.Exception.Message)"
        }
    }
}

# --- playback ---------------------------------------------------------------

<# Duration from the WAV header. Our renderer always writes a canonical 44-byte one. #>
function Get-WavDurationMs {
    param([string]$Path)
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $reader = New-Object System.IO.BinaryReader($stream)
            $stream.Position = 28
            $byteRate = $reader.ReadUInt32()
            $stream.Position = 40
            $dataSize = $reader.ReadUInt32()
            if ($byteRate -le 0) { return 1200 }
            return [int](($dataSize / $byteRate) * 1000)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return 1200
    }
}

<# Starts the cue without blocking, so the shake can run over the top of it. #>
function Start-Cue {
    param([string]$Path)
    $player = New-Object System.Media.SoundPlayer $Path
    $player.Load()
    $player.Play()
    return $player
}

function Invoke-Cue {
    param([string]$Path)
    $player = New-Object System.Media.SoundPlayer $Path
    try {
        $player.Load()
        $player.PlaySync()
    } finally {
        $player.Dispose()
    }
}

# --- screen shake -----------------------------------------------------------

<#
Shakes the whole screen and eats input while it does.

A screenshot of every monitor is thrown up in one borderless topmost window,
and that window is what moves. Because it is focused and on top, clicks and
keystrokes land on it and go nowhere, which is the point. The strip of real
desktop revealed at the trailing edge is identical to the screenshot, so the
seam does not read as one.

Bounded by a stopwatch, closed in `finally`, and Escape aborts it: the screen
must never stay covered.
#>
function Invoke-ScreenShake {
    param([int]$DurationMs = 1000, [int]$Amplitude = 45)

    $form = $null
    $bitmap = $null

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        } finally {
            $graphics.Dispose()
        }

        # The window is bigger than the screen by the shake amplitude, with the
        # screenshot inset by that much. So however far it moves it still covers
        # every pixel, and the trailing edge falls back to the form's black
        # instead of exposing the real, un-shaking desktop underneath. At 18px
        # that seam was invisible; at 45 it would read as a glitch.
        $pad = $Amplitude + 6
        $formBounds = New-Object System.Drawing.Rectangle `
        (($bounds.X - $pad), ($bounds.Y - $pad), ($bounds.Width + 2 * $pad), ($bounds.Height + 2 * $pad))

        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = 'None'
        $form.StartPosition = 'Manual'
        $form.Bounds = $formBounds
        $form.BackColor = [System.Drawing.Color]::Black
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.KeyPreview = $true
        $form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $this.Close() } })

        # DrawImageUnscaled in a Paint handler, not BackgroundImage: the latter
        # runs GDI+ layout logic on every expose and cost ~600ms for one frame.
        $form.Add_Paint({ $_.Graphics.DrawImageUnscaled($bitmap, $pad, $pad) }.GetNewClosure())
        # DoubleBuffered is protected; reflection is the no-compile way in.
        $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $form.GetType().GetProperty('DoubleBuffered', $flags).SetValue($form, $true, $null)

        $form.Show()
        $form.Activate()

        # Pay for the first full-screen paint before the clock starts, otherwise
        # it eats the entire shake budget and you get one frozen frame.
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()

        $originX = $bounds.X - $pad
        $originY = $bounds.Y - $pad
        # An instance, not Get-Random: the cmdlet costs ~0.5ms and this runs
        # a few hundred times.
        $rng = New-Object System.Random

        $frames = 0
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt $DurationMs -and -not $form.IsDisposed) {
            $frames++
            $elapsed = $watch.ElapsedMilliseconds
            $progress = $elapsed / $DurationMs

            # Full strength for the first 70%, then ease out - a flat decay over
            # a long shake spends most of its time barely moving.
            $decay = if ($progress -lt 0.7) { 1.0 } else { (1 - $progress) / 0.3 }

            # Two summed frequencies (~12Hz and ~20Hz) plus a little per-frame
            # noise, so it reads as a violent shake rather than a tidy wobble.
            # The loop measures ~180fps, so even the noise stays well sampled -
            # the original 21/30Hz sine at ~30fps was above Nyquist and aliased
            # into jitter, which is why it looked wrong rather than strong.
            $dx = [Math]::Sin($elapsed * 0.075) * 0.55 + [Math]::Sin($elapsed * 0.125) * 0.30 +
            ($rng.NextDouble() * 2 - 1) * 0.15
            $dy = [Math]::Cos($elapsed * 0.089) * 0.55 + [Math]::Cos($elapsed * 0.145) * 0.30 +
            ($rng.NextDouble() * 2 - 1) * 0.15

            # Clamp so the summed terms can never exceed the pad and tear a seam.
            $dx = [Math]::Max(-1.0, [Math]::Min(1.0, $dx))
            $dy = [Math]::Max(-1.0, [Math]::Min(1.0, $dy))

            $form.Location = New-Object System.Drawing.Point `
            (($originX + [int]($dx * $Amplitude * $decay)), ($originY + [int]($dy * $Amplitude * $decay)))

            # No sleep: one core busy for under a second buys ~55fps instead of
            # the ~30 that Start-Sleep's 15ms granularity caps you at.
            [System.Windows.Forms.Application]::DoEvents()
        }
        Write-Log ("shake {0}x{1} {2} frames in {3:N0}ms" -f `
                $bounds.Width, $bounds.Height, $frames, $watch.ElapsedMilliseconds)
    } catch {
        Write-Log "shake failed: $($_.Exception.Message)"
    } finally {
        if ($null -ne $form) {
            try { $form.Close(); $form.Dispose() } catch { }
        }
        if ($null -ne $bitmap) {
            try { $bitmap.Dispose() } catch { }
        }
    }
}

# --- main -------------------------------------------------------------------

if ($Prewarm) {
    [void](Initialize-Foreground)
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, 'ClaudeSignaler.Cue')
$holdsMutex = $false
$pausedSessions = @()
$config = $null

try {
    $config = Get-SignalerConfig
    $script:LogEnabled = $config.LogEnabled
    $script:LogMaxLines = $config.LogMaxLines

    if (-not $config.Enabled) {
        Write-Log "event=$Signal skipped, disabled in config"
        exit 0
    }

    # A second signal while one is already sounding is dropped, not queued.
    $holdsMutex = $mutex.WaitOne(0)
    if (-not $holdsMutex) {
        Write-Log "event=$Signal skipped, another cue is playing"
        exit 0
    }

    if (-not $NoCooldown -and $config.CooldownMs -gt 0 -and (Test-Path $CooldownPath)) {
        try {
            $last = [DateTime]::Parse((Get-Content -Path $CooldownPath -Raw).Trim(), $null, 'RoundtripKind')
            $sinceMs = ([DateTime]::UtcNow - $last).TotalMilliseconds
            if ($sinceMs -lt $config.CooldownMs) {
                Write-Log ("event={0} skipped, {1:N0}ms inside {2}ms cooldown" -f $Signal, $sinceMs, $config.CooldownMs)
                exit 0
            }
        } catch {
        }
    }

    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    # If you are already looking at the Claude Code window you do not need to be
    # told, least of all by having your screen thrown around.
    if ($config.FocusedMode -ne 'full') {
        $title = Get-ForegroundTitle
        if ($title -and $title -match $config.FocusedPattern) {
            if ($config.FocusedMode -eq 'silent') {
                Write-Log "event=$Signal skipped, focused on '$title'"
                exit 0
            }
            $config.ShakeEnabled = $false
            Write-Log "shake off, focused on '$title'"
        }
    }

    $warmWav = Join-Path $WarmDir "$($config.Cue).wav"
    $coldWav = Join-Path $SoundsDir "$($config.Cue).wav"
    if (Test-RenderStale -Config $config -WavPath $coldWav) { Invoke-Render }

    if ($config.Mode -eq 'pause') {
        try {
            $pausedSessions = @(Suspend-PlayingMedia)
        } catch {
            Write-Log "media control unavailable, playing over whatever is on: $($_.Exception.Message)"
            $pausedSessions = @()
        }
    }

    # Something was playing, so the Bluetooth link is awake: skip the lead-in.
    $wav = if ($pausedSessions.Count -gt 0) { $warmWav } else { $coldWav }
    if (-not (Test-Path $wav)) { $wav = $coldWav }
    if (-not (Test-Path $wav)) { throw "cue file missing: $wav" }

    if ($pausedSessions.Count -gt 0 -and $config.SettleMs -gt 0) {
        Start-Sleep -Milliseconds $config.SettleMs
    }

    # Start the cue first, then shake over the top of it, so the ~250ms of
    # screen capture and form setup never delays the sound.
    $beforePlay = [DateTime]::UtcNow
    $cueMs = Get-WavDurationMs -Path $wav
    $player = Start-Cue -Path $wav
    try {
        if ($config.ShakeEnabled -and $config.ShakeDurationMs -gt 0) {
            Invoke-ScreenShake -DurationMs $config.ShakeDurationMs -Amplitude $config.ShakeAmplitude
        }

        # Hold the process open for whatever is left of the cue: disposing the
        # player, or exiting, cuts playback dead.
        $remainingMs = $cueMs - ([DateTime]::UtcNow - $beforePlay).TotalMilliseconds
        if ($remainingMs -gt 0) { Start-Sleep -Milliseconds ([int]$remainingMs) }
    } finally {
        $player.Dispose()
    }

    $playMs = ([DateTime]::UtcNow - $beforePlay).TotalMilliseconds
    $leadMs = ($beforePlay - $started).TotalMilliseconds

    Write-Log ("event={0} cue={1} reason='{2}' paused={3} shake={4} startup={5:N0}ms play={6:N0}ms" -f `
            $Signal, $config.Cue, $Reason, $pausedSessions.Count, $config.ShakeEnabled, $leadMs, $playMs)
    Limit-Log
} catch {
    Write-Log "error: $($_.Exception.Message)"
    # Last resort: the user still wants to know Claude is done.
    try {
        $fallback = Join-Path $SoundsDir 'ready.wav'
        if (Test-Path $fallback) { Invoke-Cue -Path $fallback } else { [console]::beep(880, 180) }
    } catch {
    }
} finally {
    # Resume from here, not from the try body. Invoke-Cue is the line most likely
    # to throw in real use - AirPods disconnecting mid-cue, a truncated WAV - and
    # a throw there must never leave the user's music paused forever.
    if ($null -ne $config -and $config.Resume -and $pausedSessions.Count -gt 0) {
        if ($config.ResumeDelayMs -gt 0) { Start-Sleep -Milliseconds $config.ResumeDelayMs }
        Resume-Media -Sessions $pausedSessions
    }
    if ($holdsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

exit 0
