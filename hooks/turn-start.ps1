<#
    Stamps the moment a turn began, so signal.ps1 can tell a 4-second reply from
    an 8-minute one and stay quiet for the former.

    This runs on every prompt you submit, so it is deliberately tiny: PowerShell
    parses a whole script before running a line of it, and the full signal.ps1
    costs ~430ms of parsing on top of the ~440ms it takes to start PowerShell at
    all. Keeping this file small is the entire point of it existing separately.

    Never writes to stdout. Always exits 0.
#>
try {
    $stateDir = Join-Path (Split-Path -Parent $PSScriptRoot) '.state'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

    $sessionId = ''
    if ([Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $sessionId = [string](($raw | ConvertFrom-Json).session_id)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        $safe = $sessionId -replace '[^A-Za-z0-9_-]', ''
        [DateTime]::UtcNow.ToString('o') |
            Set-Content -Path (Join-Path $stateDir ("turn-$safe.txt")) -Encoding utf8
    }
} catch {
    # A missing stamp only means the duration gate opens. Never disturb a turn.
}

exit 0
