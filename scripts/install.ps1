<#
.SYNOPSIS
    Registers (or removes) the signaller hooks in ~/.claude/settings.json.

.DESCRIPTION
    Backs up settings.json before every write, and only ever touches hook entries
    that point at this repo. Other hooks are left exactly as they were.

.PARAMETER Uninstall
    Remove our hooks and exit.

.PARAMETER Status
    Show what is currently registered.

.PARAMETER Test
    Fire every signal once, ignoring all gates, so you can hear and see them.

.PARAMETER WhoHasFocus
    Print the current foreground window title. Use it to tune config.focusPattern.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Test,
    [switch]$WhoHasFocus
)

$ErrorActionPreference = 'Stop'

$Root         = Split-Path -Parent $PSScriptRoot
$HookDir      = Join-Path $Root 'hooks'
$HookScript   = Join-Path $HookDir 'signal.ps1'
$TurnScript   = Join-Path $HookDir 'turn-start.ps1'
$StateDir     = Join-Path $Root '.state'
$FocusDll     = Join-Path $StateDir 'foreground.dll'
$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$BackupDir    = Join-Path $env:USERPROFILE '.claude\backups'

# Notification is registered with a wildcard matcher and classified from the
# payload's notification_type instead, so we never depend on matcher regex
# semantics changing under us.
$HookPlan = @(
    @{ Event = 'UserPromptSubmit'; Script = $TurnScript; Signal = ''; Note = 'stamps turn start for the duration gate' },
    @{ Event = 'Stop';             Script = $HookScript; Signal = 'done';   Note = 'Claude finished its turn' },
    @{ Event = 'StopFailure';      Script = $HookScript; Signal = 'failed'; Note = 'turn died on an API error' },
    @{ Event = 'Notification';     Script = $HookScript; Signal = '';       Note = 'permission prompts, agent questions, idle' }
)

# PowerShell 7 starts appreciably faster than 5.1, and these scripts run on both.
# Most of a hook's cost is interpreter startup, so use pwsh when it is there.
function Get-HostExe {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) { return 'pwsh.exe' }
    return 'powershell.exe'
}

function Get-HookCommand {
    param([string]$Script, [string]$Signal)
    $path = $Script.Replace('\', '/')
    $cmd = (Get-HostExe) + ' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $path + '"'
    if (-not [string]::IsNullOrWhiteSpace($Signal)) { $cmd = $cmd + ' -Signal ' + $Signal }
    return $cmd
}

# Anything pointing into this repo's hooks directory is ours, and nothing else is.
function Test-OurHook {
    param($Hook)
    $cmd = [string]$Hook.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    return $cmd.Replace('\', '/').Contains($HookDir.Replace('\', '/'))
}

function Read-Settings {
    if (-not (Test-Path $SettingsPath)) { return (New-Object PSObject) }
    $raw = Get-Content -Path $SettingsPath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-Object PSObject) }
    try {
        return $raw | ConvertFrom-Json
    } catch {
        throw "settings.json is not valid JSON, refusing to touch it: $($_.Exception.Message)"
    }
}

function Backup-Settings {
    if (-not (Test-Path $SettingsPath)) { return $null }
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $stamp  = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $target = Join-Path $BackupDir "settings.json.$stamp.signaler.bak"
    Copy-Item -Path $SettingsPath -Destination $target -Force
    return $target
}

function Write-Settings {
    param($Settings)
    $dir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Settings | ConvertTo-Json -Depth 25
    Set-Content -Path $SettingsPath -Value $json -Encoding utf8
}

# Drops every matcher group whose hooks are all ours, and prunes ours from
# groups that also hold somebody else's.
function Remove-OurHooks {
    param($Settings)
    $removed = 0
    if (-not $Settings.PSObject.Properties['hooks']) { return 0 }
    $hooks = $Settings.hooks
    if ($null -eq $hooks) { return 0 }

    foreach ($prop in @($hooks.PSObject.Properties)) {
        $kept = @()
        foreach ($group in @($prop.Value)) {
            $inner = @()
            if ($group.PSObject.Properties['hooks']) { $inner = @($group.hooks) }

            $survivors = @($inner | Where-Object { -not (Test-OurHook $_) })
            $removed += ($inner.Count - $survivors.Count)

            if ($survivors.Count -gt 0) {
                $group.hooks = $survivors
                $kept += $group
            }
        }
        if ($kept.Count -gt 0) {
            $hooks | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $kept -Force
        } else {
            $hooks.PSObject.Properties.Remove($prop.Name)
        }
    }

    if (@($hooks.PSObject.Properties).Count -eq 0) {
        $Settings.PSObject.Properties.Remove('hooks')
    }
    return $removed
}

function Build-FocusDll {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    if (Test-Path $FocusDll) { Remove-Item -Path $FocusDll -Force -ErrorAction SilentlyContinue }

    $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeSignaler {
    public static class Foreground {
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

        public static string Title() {
            IntPtr handle = GetForegroundWindow();
            if (handle == IntPtr.Zero) { return ""; }
            StringBuilder buffer = new StringBuilder(512);
            int written = GetWindowTextW(handle, buffer, buffer.Capacity);
            if (written <= 0) { return ""; }
            return buffer.ToString();
        }
    }
}
'@

    # Compiled once here so a real signal never pays the ~500ms csc cost.
    Add-Type -TypeDefinition $source -OutputAssembly $FocusDll -OutputType Library
}

function Show-Status {
    Write-Host ""
    Write-Host "script   : $HookScript"
    Write-Host "settings : $SettingsPath"
    Write-Host "focus dll: $(if (Test-Path $FocusDll) { 'built' } else { 'missing - focus gate is off' })"
    Write-Host ""

    $settings = Read-Settings
    $found = 0
    if ($settings.PSObject.Properties['hooks'] -and $null -ne $settings.hooks) {
        foreach ($prop in @($settings.hooks.PSObject.Properties)) {
            foreach ($group in @($prop.Value)) {
                $inner = @()
                if ($group.PSObject.Properties['hooks']) { $inner = @($group.hooks) }
                foreach ($hook in $inner) {
                    if (Test-OurHook $hook) {
                        $matcher = '*'
                        if ($group.PSObject.Properties['matcher']) { $matcher = [string]$group.matcher }
                        Write-Host ("  {0,-18} matcher {1}" -f $prop.Name, $matcher)
                        $found++
                    }
                }
            }
        }
    }
    if ($found -eq 0) { Write-Host "  (no signaller hooks registered)" }
    Write-Host ""
}

# --- entry points -----------------------------------------------------------

if ($WhoHasFocus) {
    if (-not (Test-Path $FocusDll)) { Build-FocusDll }
    Add-Type -Path $FocusDll
    Write-Host ""
    Write-Host "Foreground window title right now:"
    Write-Host ("  " + [ClaudeSignaler.Foreground]::Title())
    Write-Host ""
    Write-Host "Set config.focusPattern to a regex that matches this when Claude Code is in front."
    Write-Host ""
    exit 0
}

if ($Status) {
    Show-Status
    exit 0
}

if ($Test) {
    if (-not (Test-Path $FocusDll)) { Build-FocusDll }
    Write-Host ""
    Write-Host "Firing all four signals, ~1.6s apart. Watch the notification area."
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $HookScript -Signal test
    Write-Host "Done. If you saw nothing, check logs/signaler.log."
    Write-Host ""
    exit 0
}

if ($Uninstall) {
    $settings = Read-Settings
    $backup = Backup-Settings
    $removed = Remove-OurHooks $settings
    Write-Settings $settings

    Write-Host ""
    Write-Host "Removed $removed signaller hook(s)."
    if ($backup) { Write-Host "Backup  : $backup" }
    Write-Host "Restart Claude Code to drop them from the running session."
    Write-Host ""
    exit 0
}

# Install.
if (-not (Test-Path $HookScript)) { throw "hook script not found at $HookScript" }
if (-not (Test-Path $TurnScript)) { throw "hook script not found at $TurnScript" }

Build-FocusDll

$settings = Read-Settings
$backup = Backup-Settings

# Strip first, so a re-run refreshes rather than duplicates.
[void](Remove-OurHooks $settings)

if (-not $settings.PSObject.Properties['hooks'] -or $null -eq $settings.hooks) {
    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue (New-Object PSObject) -Force
}
$hooks = $settings.hooks

foreach ($plan in $HookPlan) {
    $entry = [PSCustomObject]@{
        type    = 'command'
        command = (Get-HookCommand $plan.Script $plan.Signal)
        timeout = 15
    }
    $group = [PSCustomObject]@{
        matcher = '*'
        hooks   = @($entry)
    }

    $existing = @()
    if ($hooks.PSObject.Properties[$plan.Event]) { $existing = @($hooks.($plan.Event)) }
    $hooks | Add-Member -NotePropertyName $plan.Event -NotePropertyValue ($existing + $group) -Force
}

Write-Settings $settings

Write-Host ""
Write-Host "Claude Code signaller installed."
Write-Host "  script   : $HookScript"
Write-Host "  settings : $SettingsPath"
if ($backup) { Write-Host "  backup   : $backup" }
Write-Host ""
foreach ($plan in $HookPlan) {
    Write-Host ("  {0,-18} -> {1}" -f $plan.Event, $plan.Note)
}
Write-Host ""
Write-Host "Other hooks in settings.json were left untouched."
Write-Host "Restart Claude Code (or start a new session) to pick these up."
Write-Host ""
Write-Host "NEXT, and do not skip it:" -ForegroundColor Yellow
Write-Host "  Click your Claude Code window, then run:  .\scripts\install.ps1 -WhoHasFocus"
Write-Host "  Set config.focusPattern to a regex matching what it prints."
Write-Host ""
Write-Host "  Until you do, focusPattern is a guess. Too broad and it silently"
Write-Host "  suppresses everything; too narrow and it never suppresses at all."
Write-Host "  Either way logs\signaler.log records the reason for every skip."
Write-Host ""
exit 0
