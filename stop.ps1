[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PidFile = Join-Path $ScriptRoot "llama-server.pid"
$PreferredServerExe = Join-Path $ScriptRoot "bin\llama-server.exe"
$LegacyServerExe = Join-Path $ScriptRoot "llama-server.exe"

$TargetServerPaths = @(
    $PreferredServerExe
    $LegacyServerExe
) | Where-Object { Test-Path -LiteralPath $_ }

$TargetServerPatterns = @($TargetServerPaths | ForEach-Object { [regex]::Escape($_) })
$ProcessIdsToStop = New-Object System.Collections.Generic.HashSet[int]

if (Test-Path -LiteralPath $PidFile) {
    $TrackedPidText = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($TrackedPidText -match '^\d+$') {
        $null = $ProcessIdsToStop.Add([int]$TrackedPidText)
    }
}

$WorkspaceProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.ExecutablePath -and ($TargetServerPaths -contains $_.ExecutablePath)) -or
            ($_.CommandLine -and ($TargetServerPatterns | Where-Object { $_.CommandLine -match $_ }).Count -gt 0)
        }
)

foreach ($WorkspaceProcess in $WorkspaceProcesses) {
    $null = $ProcessIdsToStop.Add([int]$WorkspaceProcess.ProcessId)
}

if ($ProcessIdsToStop.Count -eq 0) {
    if (Test-Path -LiteralPath $PidFile) {
        if ($PSCmdlet.ShouldProcess($PidFile, "Remove stale PID file")) {
            Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
        }
        Write-Host "No workspace llama.cpp server processes found. Removed stale PID file." -ForegroundColor Yellow
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

if ($PSCmdlet.ShouldProcess($PidFile, "Remove tracked PID file")) {
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
}

if ($WhatIfPreference) {
    Write-Host "WhatIf cleanup plan complete." -ForegroundColor Cyan
    return
}

Start-Sleep -Milliseconds 500

$RemainingIds = @(
    $ProcessIdsToStop |
        Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
)

if ($StoppedIds.Count -gt 0) {
    Write-Host "Stopped llama.cpp server process(es): $($StoppedIds -join ', ')" -ForegroundColor Green
}

if ($RemainingIds.Count -gt 0 -or $FailedIds.Count -gt 0) {
    $AllFailedIds = @($RemainingIds + $FailedIds | Select-Object -Unique)
    throw "Some llama.cpp server processes could not be cleared: $($AllFailedIds -join ', ')"
}

Write-Host "Workspace llama.cpp cleanup complete." -ForegroundColor Green
