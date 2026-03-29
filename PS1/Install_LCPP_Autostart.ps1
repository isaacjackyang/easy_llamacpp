param(
    [string]$TaskName = "LCPP llama.cpp Autostart",
    [ValidateSet("Startup", "Logon")]
    [string]$TriggerMode = "Startup",
    [switch]$RunNow
)

$ErrorActionPreference = "Stop"

$ScriptHome = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = if ([string]::Equals([System.IO.Path]::GetFileName($ScriptHome), "PS1", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $ScriptHome
}
else {
    $ScriptHome
}
$LauncherScript = Join-Path $ProjectRoot "PS1\Start_LCPP.ps1"
if (-not (Test-Path -LiteralPath $LauncherScript)) {
    $LauncherScript = Join-Path $ProjectRoot "Start_LCPP.ps1"
}
$PowerShellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$CurrentUser = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME

if (-not (Test-Path -LiteralPath $LauncherScript)) {
    throw "Cannot find launcher script: $LauncherScript"
}

if (-not (Test-Path -LiteralPath $PowerShellExe)) {
    throw "Cannot find powershell.exe: $PowerShellExe"
}

$Arguments = @(
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy", "Bypass",
    "-File", ('"{0}"' -f $LauncherScript),
    "-BypassMenu",
    "-Background",
    "-NoBrowser",
    "-NoPause"
) -join " "

$Action = New-ScheduledTaskAction `
    -Execute $PowerShellExe `
    -Argument $Arguments `
    -WorkingDirectory $ProjectRoot

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

function Register-LcppTask {
    param(
        [ValidateSet("Startup", "Logon")]
        [string]$Mode
    )

    if ($Mode -eq "Startup") {
        $Trigger = New-ScheduledTaskTrigger -AtStartup
        $Principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType S4U -RunLevel Highest
        $Description = "Auto-start llama.cpp in background at Windows startup."
    }
    else {
        $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
        $Principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
        $Description = "Auto-start llama.cpp in background when $CurrentUser signs in."
    }

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Description $Description `
        -Force | Out-Null
}

$InstalledMode = $TriggerMode

try {
    Register-LcppTask -Mode $TriggerMode
}
catch {
    $IsAccessDenied = $_.Exception.Message -match "Access is denied"
    if ($TriggerMode -eq "Startup" -and $IsAccessDenied) {
        Write-Host "Startup task registration needs elevated rights. Falling back to logon trigger for this user." -ForegroundColor Yellow
        Register-LcppTask -Mode "Logon"
        $InstalledMode = "Logon"
    }
    else {
        throw
    }
}

Write-Host "Scheduled task installed." -ForegroundColor Green
Write-Host "Task   : $TaskName"
Write-Host "User   : $CurrentUser"
Write-Host "Trigger: $InstalledMode"
Write-Host "Runs   : $LauncherScript -BypassMenu -Background -NoBrowser -NoPause"

if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Task started once for verification." -ForegroundColor Cyan
}
