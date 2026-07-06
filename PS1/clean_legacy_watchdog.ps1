[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LegacyScriptPaths = @(
    (Join-Path $ProjectRoot "PS1\llama_watchdog.ps1")
    (Join-Path $ProjectRoot "PS1\watchdog_control.ps1")
    (Join-Path $ProjectRoot "PS1\llama_supervisor.ps1")
)

Write-Host ""
Write-Host "Cleaning legacy llama watchdog..." -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot" -ForegroundColor DarkGray
Write-Host ""

$LegacyPatterns = @($LegacyScriptPaths | ForEach-Object { [regex]::Escape($_) })
$Processes = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not $_.CommandLine -or [int]$_.ProcessId -eq $PID) {
                return $false
            }
            foreach ($Pattern in $LegacyPatterns) {
                if ([string]$_.CommandLine -match $Pattern) {
                    return $true
                }
            }
            return $false
        } |
        Sort-Object ProcessId -Unique
)

$StoppedIds = New-Object System.Collections.Generic.List[int]
foreach ($Process in $Processes) {
    if ($PSCmdlet.ShouldProcess("PID $($Process.ProcessId)", "Stop legacy llama watchdog process")) {
        try {
            Stop-Process -Id ([int]$Process.ProcessId) -Force -ErrorAction Stop
            $StoppedIds.Add([int]$Process.ProcessId)
        }
        catch {
            Write-Warning "Could not stop PID $($Process.ProcessId): $($_.Exception.Message)"
        }
    }
}

if (-not $WhatIfPreference -and $StoppedIds.Count -gt 0) {
    $Deadline = (Get-Date).AddSeconds(10)
    do {
        $Remaining = @($StoppedIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($Remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $Deadline)
}

$Artifacts = @(
    (Join-Path $ProjectRoot "logs\llama-watchdog.pid")
    (Join-Path $ProjectRoot "logs\llama-watchdog.log")
    (Join-Path $ProjectRoot "logs\watchdog_smoke_test")
    (Join-Path $ProjectRoot "start_watchdog.cmd")
    (Join-Path $ProjectRoot "stop_watchdog.cmd")
) + $LegacyScriptPaths

$RemovedPaths = New-Object System.Collections.Generic.List[string]
foreach ($Path in $Artifacts | Select-Object -Unique) {
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, "Remove legacy watchdog artifact")) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        $RemovedPaths.Add($Path)
    }
}

$OwnerStatePath = Join-Path $ProjectRoot "logs\llama-runtime-owner.json"
if (Test-Path -LiteralPath $OwnerStatePath -PathType Leaf) {
    try {
        $State = Get-Content -LiteralPath $OwnerStatePath -Raw | ConvertFrom-Json
        $WatchdogFields = @(
            "watchdog_pid"
            "watchdog_enabled"
            "watchdog_managed"
            "restart_count"
            "last_restart_at"
            "last_exit_code"
        )
        $Changed = $false
        foreach ($Field in $WatchdogFields) {
            if ($State.PSObject.Properties[$Field]) {
                $State.PSObject.Properties.Remove($Field)
                $Changed = $true
            }
        }
        if ($Changed -and $PSCmdlet.ShouldProcess($OwnerStatePath, "Remove watchdog fields from runtime state")) {
            $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OwnerStatePath -Encoding UTF8
        }
    }
    catch {
        Write-Warning "Could not update runtime owner state: $($_.Exception.Message)"
    }
}

if ($StoppedIds.Count -gt 0) {
    Write-Host "Stopped process(es): $($StoppedIds -join ', ')" -ForegroundColor Green
}
else {
    Write-Host "No legacy watchdog process was running." -ForegroundColor DarkGray
}

if ($RemovedPaths.Count -gt 0) {
    Write-Host "Removed artifact(s):" -ForegroundColor Green
    $RemovedPaths | ForEach-Object { Write-Host "  $_" }
}
else {
    Write-Host "No legacy watchdog artifacts were found." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Legacy watchdog cleanup complete." -ForegroundColor Green
