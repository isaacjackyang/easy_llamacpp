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

$StartupFolder = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$OpenClawStateDir = Join-Path $env:USERPROFILE ".openclaw"
$OpenClawGatewayScript = Join-Path $OpenClawStateDir "gateway.cmd"
$OpenClawNodeScript = Join-Path $OpenClawStateDir "node.cmd"
$LcppStopScript = Join-Path $ProjectRoot "PS1\stop.ps1"
$OpenClawTaskNames = @("OpenClaw Gateway", "OpenClaw Node")
$AutostartTaskNames = @("LCPP llama.cpp Autostart") + $OpenClawTaskNames
$StartupEntryNames = @("OpenClaw Gateway.cmd", "OpenClaw Node.cmd")

function Write-Info {
    param([string]$Message)

    Write-Host $Message -ForegroundColor Gray
}

function Write-Ok {
    param([string]$Message)

    Write-Host $Message -ForegroundColor Green
}

function Write-WarnText {
    param([string]$Message)

    Write-Host $Message -ForegroundColor Yellow
}

function Disable-AutostartTask {
    param([string]$TaskName)

    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $Task) {
        Write-Info "Scheduled task not found: $TaskName"
        return
    }

    if ($Task.State -eq "Disabled") {
        Write-Info "Scheduled task already disabled: $TaskName"
        return
    }

    if ($PSCmdlet.ShouldProcess($TaskName, "Disable scheduled task")) {
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    }

    Write-Ok "Disabled scheduled task: $TaskName"
}

function Disable-StartupEntry {
    param([string]$EntryName)

    $EntryPath = Join-Path $StartupFolder $EntryName
    $DisabledEntryPath = "$EntryPath.disabled"

    if (Test-Path -LiteralPath $DisabledEntryPath) {
        Write-Info "Startup entry already disabled: $DisabledEntryPath"
        return
    }

    if (-not (Test-Path -LiteralPath $EntryPath)) {
        Write-Info "Startup entry not found: $EntryPath"
        return
    }

    if ($PSCmdlet.ShouldProcess($EntryPath, "Disable startup entry")) {
        Rename-Item -LiteralPath $EntryPath -NewName ([System.IO.Path]::GetFileName($DisabledEntryPath)) -ErrorAction Stop
    }

    Write-Ok "Disabled startup entry: $EntryName"
}

function Get-OpenClawGatewayHostProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -eq "node.exe" -and $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+dist[\\/]+index\.js' -and $_.CommandLine -match '\bgateway\b') -or
                ($_.Name -eq "cmd.exe" -and $_.CommandLine -match 'gateway\.cmd')
            }
    )
}

function Get-OpenClawNodeHostProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Name -eq "node.exe" -and $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+dist[\\/]+index\.js' -and $_.CommandLine -match '\bnode\s+run\b') -or
                ($_.Name -like "powershell*.exe" -and $_.CommandLine -match 'start-openclaw-node\.ps1') -or
                ($_.Name -eq "cmd.exe" -and $_.CommandLine -match 'node\.cmd')
            }
    )
}

function Get-ManagedMediaProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and (
                    $_.CommandLine -match 'workspace[\\/]+tts_server\.py' -or
                    $_.CommandLine -match 'workspace[\\/]+stt_server\.py'
                )
            }
    )
}

function Stop-OpenClawRuntime {
    foreach ($TaskName in $OpenClawTaskNames) {
        & schtasks.exe /End /TN $TaskName *> $null
    }

    $ProcessesToStop = @(
        @(Get-OpenClawGatewayHostProcesses) +
        @(Get-OpenClawNodeHostProcesses) +
        @(Get-ManagedMediaProcesses)
    ) | Sort-Object ProcessId -Unique

    if ($ProcessesToStop.Count -eq 0) {
        Write-Info "No OpenClaw/TTS/STT processes found."
        return
    }

    foreach ($Process in $ProcessesToStop) {
        if ($PSCmdlet.ShouldProcess("PID $($Process.ProcessId)", "Stop OpenClaw-related process")) {
            Stop-Process -Id $Process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 2
    Write-Ok ("Stopped OpenClaw/TTS/STT process(es): {0}" -f (($ProcessesToStop | ForEach-Object { $_.ProcessId }) -join ", "))
}

function Stop-LcppRuntime {
    if (-not (Test-Path -LiteralPath $LcppStopScript)) {
        Write-WarnText "Cannot find llama.cpp stop script: $LcppStopScript"
        return
    }

    try {
        if ($PSCmdlet.ShouldProcess($LcppStopScript, "Stop llama.cpp runtime")) {
            & $LcppStopScript
        }
    }
    catch {
        Write-WarnText $_.Exception.Message
    }
}

Write-Host ""
Write-Host "Stopping auto services and disabling autostart..." -ForegroundColor Cyan
Write-Host ""

foreach ($TaskName in $AutostartTaskNames) {
    try {
        Disable-AutostartTask -TaskName $TaskName
    }
    catch {
        Write-WarnText ("Failed to disable scheduled task {0}: {1}" -f $TaskName, $_.Exception.Message)
    }
}

foreach ($EntryName in $StartupEntryNames) {
    try {
        Disable-StartupEntry -EntryName $EntryName
    }
    catch {
        Write-WarnText ("Failed to disable startup entry {0}: {1}" -f $EntryName, $_.Exception.Message)
    }
}

Stop-LcppRuntime
Stop-OpenClawRuntime

Write-Host ""
Write-Ok "Autostart is now disabled for llama.cpp and OpenClaw."
Write-Info "OpenClaw startup files remain on disk:"
Write-Info "  $OpenClawGatewayScript"
Write-Info "  $OpenClawNodeScript"
Write-Info "Disabled Startup-folder entries were renamed with a .disabled suffix."
