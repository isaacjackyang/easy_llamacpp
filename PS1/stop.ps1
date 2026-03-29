[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"

$ScriptHome = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = if ([string]::Equals([System.IO.Path]::GetFileName($ScriptHome), "PS1", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $ScriptHome
}
else {
    $ScriptHome
}

$PidFile = Join-Path $ProjectRoot "logs\llama-server.pid"
$LegacyPidFile = Join-Path $ProjectRoot "llama-server.pid"
$PreferredServerExe = Join-Path $ProjectRoot "bin\llama-server.exe"
$LegacyServerExe = Join-Path $ProjectRoot "llama-server.exe"
$StopTimeoutSec = 20

$TrackedPidFiles = @(
    $PidFile
    $LegacyPidFile
) | Select-Object -Unique

$TargetServerPaths = @(
    $PreferredServerExe
    $LegacyServerExe
) | Where-Object { Test-Path -LiteralPath $_ }

$TargetServerPatterns = @($TargetServerPaths | ForEach-Object { [regex]::Escape($_) })
$ProcessIdsToStop = New-Object System.Collections.Generic.HashSet[int]

foreach ($TrackedPidFile in $TrackedPidFiles) {
    if (-not (Test-Path -LiteralPath $TrackedPidFile)) {
        continue
    }

    $TrackedPidText = ((Get-Content -LiteralPath $TrackedPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
    if ($TrackedPidText -match '^\d+$') {
        $null = $ProcessIdsToStop.Add([int]$TrackedPidText)
    }
}

$WorkspaceProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $WorkspaceProcess = $_
            $MatchesExecutablePath = $WorkspaceProcess.ExecutablePath -and ($TargetServerPaths -contains $WorkspaceProcess.ExecutablePath)
            $MatchesCommandLine = $false

            if ($WorkspaceProcess.CommandLine) {
                foreach ($TargetServerPattern in $TargetServerPatterns) {
                    if ($WorkspaceProcess.CommandLine -match $TargetServerPattern) {
                        $MatchesCommandLine = $true
                        break
                    }
                }
            }

            $MatchesExecutablePath -or $MatchesCommandLine
        }
)

foreach ($WorkspaceProcess in $WorkspaceProcesses) {
    $null = $ProcessIdsToStop.Add([int]$WorkspaceProcess.ProcessId)
}

if ($ProcessIdsToStop.Count -eq 0) {
    $RemovedStalePid = $false
    foreach ($TrackedPidFile in $TrackedPidFiles) {
        if (Test-Path -LiteralPath $TrackedPidFile) {
            if ($PSCmdlet.ShouldProcess($TrackedPidFile, "Remove stale PID file")) {
                Remove-Item -LiteralPath $TrackedPidFile -ErrorAction SilentlyContinue
            }
            $RemovedStalePid = $true
        }
    }

    if ($RemovedStalePid) {
        Write-Host "No workspace llama.cpp server processes found. Removed stale PID file(s)." -ForegroundColor Yellow
    }
    else {
        Write-Host "No workspace llama.cpp server processes found." -ForegroundColor Yellow
    }
    return
}

$StoppedIds = New-Object System.Collections.Generic.List[int]
$FailedIds = New-Object System.Collections.Generic.List[int]

foreach ($ProcessId in $ProcessIdsToStop) {
    $Process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $Process) {
        continue
    }

    if ($PSCmdlet.ShouldProcess("PID $ProcessId", "Stop llama.cpp server process")) {
        try {
            Stop-Process -Id $ProcessId -Force -ErrorAction Stop
            $StoppedIds.Add([int]$ProcessId)
        }
        catch {
            $FailedIds.Add([int]$ProcessId)
        }
    }
}

foreach ($TrackedPidFile in $TrackedPidFiles) {
    if ($PSCmdlet.ShouldProcess($TrackedPidFile, "Remove tracked PID file")) {
        Remove-Item -LiteralPath $TrackedPidFile -ErrorAction SilentlyContinue
    }
}

if ($WhatIfPreference) {
    Write-Host "WhatIf cleanup plan complete." -ForegroundColor Cyan
    return
}

$StopDeadline = (Get-Date).AddSeconds($StopTimeoutSec)
$RemainingIds = @()
do {
    $RemainingIds = @(
        $ProcessIdsToStop |
            Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
    )

    if ($RemainingIds.Count -eq 0) {
        break
    }

    Start-Sleep -Milliseconds 500
}
while ((Get-Date) -lt $StopDeadline)

if ($StoppedIds.Count -gt 0) {
    Write-Host "Stopped llama.cpp server process(es): $($StoppedIds -join ', ')" -ForegroundColor Green
}

if ($RemainingIds.Count -gt 0 -or $FailedIds.Count -gt 0) {
    $AllFailedIds = @($RemainingIds + $FailedIds | Select-Object -Unique)
    throw "Some llama.cpp server processes could not be cleared: $($AllFailedIds -join ', ')"
}

Write-Host "Workspace llama.cpp cleanup complete." -ForegroundColor Green
