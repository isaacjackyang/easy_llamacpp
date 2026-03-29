param(
    [string]$TaskName = "LCPP llama.cpp Autostart"
)

$ErrorActionPreference = "Stop"

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $Task) {
    Write-Host "Scheduled task not found: $TaskName" -ForegroundColor Yellow
    return
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Scheduled task removed: $TaskName" -ForegroundColor Green
