[CmdletBinding()]
param(
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status
)

$ErrorActionPreference = "Stop"

$ScriptHome = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = if ([string]::Equals([System.IO.Path]::GetFileName($ScriptHome), "PS1", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $ScriptHome
}
else {
    $ScriptHome
}

$LogRoot = Join-Path $ProjectRoot "logs"
$RuntimeOwnerStateFile = Join-Path $LogRoot "llama-runtime-owner.json"
$PidFile = Join-Path $LogRoot "llama-server.pid"
$SupervisorPidFile = Join-Path $LogRoot "llama-supervisor.pid"
$WatchdogPidFile = Join-Path $LogRoot "llama-watchdog.pid"
$WatchdogLog = Join-Path $LogRoot "llama-watchdog.log"
$WatchdogScriptPath = Join-Path $ProjectRoot "PS1\llama_watchdog.ps1"
$PreferredServerExe = Join-Path $ProjectRoot "bin\llama-server.exe"
$LegacyServerExe = Join-Path $ProjectRoot "llama-server.exe"
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Read-RuntimeOwnerState {
    if (-not (Test-Path -LiteralPath $RuntimeOwnerStateFile)) {
        return $null
    }

    try {
        $RawState = Get-Content -LiteralPath $RuntimeOwnerStateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($RawState)) {
            return $null
        }

        return ($RawState | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Write-RuntimeOwnerState {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    $TempPath = "$RuntimeOwnerStateFile.tmp"
    $State.updated_at = (Get-Date).ToString("o")
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $TempPath -Encoding UTF8
    Move-Item -LiteralPath $TempPath -Destination $RuntimeOwnerStateFile -Force
}

function ConvertFrom-Base64JsonArray {
    param(
        [string]$EncodedValue
    )

    if ([string]::IsNullOrWhiteSpace($EncodedValue)) {
        return @()
    }

    $Json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedValue))
    $Decoded = $Json | ConvertFrom-Json -ErrorAction Stop
    return @($Decoded)
}

function ConvertTo-ArgumentString {
    param(
        [string[]]$Arguments
    )

    $QuotedArguments = foreach ($Argument in $Arguments) {
        if ($Argument -match '[\s"]') {
            '"{0}"' -f $Argument.Replace('"', '\"')
        }
        else {
            $Argument
        }
    }

    return ($QuotedArguments -join " ")
}

function Get-WorkspaceWatchdogProcesses {
    $WatchdogPattern = [regex]::Escape($WatchdogScriptPath)
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and ($_.CommandLine -match $WatchdogPattern)
            }
    )
}

function Get-TrackedWatchdogProcess {
    if (Test-Path -LiteralPath $WatchdogPidFile) {
        $PidText = ((Get-Content -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        if ($PidText -match '^\d+$') {
            return Get-Process -Id ([int]$PidText) -ErrorAction SilentlyContinue
        }
    }

    return $null
}

function Get-AnyRunningWatchdogProcess {
    $TrackedWatchdog = Get-TrackedWatchdogProcess
    if ($TrackedWatchdog) {
        return $TrackedWatchdog
    }

    $WorkspaceWatchdogs = @(Get-WorkspaceWatchdogProcesses | Sort-Object ProcessId)
    foreach ($WorkspaceWatchdog in $WorkspaceWatchdogs) {
        $Process = Get-Process -Id ([int]$WorkspaceWatchdog.ProcessId) -ErrorAction SilentlyContinue
        if ($Process) {
            return $Process
        }
    }

    return $null
}

function Stop-WatchdogProcesses {
    $TargetIds = @(
        @((Get-TrackedWatchdogProcess | ForEach-Object { $_.Id })) +
        @(Get-WorkspaceWatchdogProcesses | ForEach-Object { [int]$_.ProcessId }) |
            Select-Object -Unique
    )

    $StoppedIds = New-Object System.Collections.Generic.List[int]
    foreach ($TargetId in $TargetIds) {
        try {
            Stop-Process -Id $TargetId -Force -ErrorAction Stop
            $StoppedIds.Add([int]$TargetId)
        }
        catch {
        }
    }

    Remove-Item -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue

    $State = Read-RuntimeOwnerState
    if ($State) {
        $State | Add-Member -NotePropertyName watchdog_pid -NotePropertyValue $null -Force
        $State | Add-Member -NotePropertyName watchdog_enabled -NotePropertyValue $false -Force
        $State | Add-Member -NotePropertyName status -NotePropertyValue "running-unmanaged" -Force
        Write-RuntimeOwnerState -State $State
    }

    return @($StoppedIds)
}

function Start-WatchdogProcess {
    $State = Read-RuntimeOwnerState
    if (-not $State) {
        throw "Cannot start watchdog because runtime ownership state is missing: $RuntimeOwnerStateFile"
    }

    $StateServerExe = [string]$State.server_exe
    $StateServerArgs = @($State.server_args | ForEach-Object { [string]$_ })
    if ([string]::IsNullOrWhiteSpace($StateServerExe) -or $StateServerArgs.Count -eq 0) {
        throw "Runtime ownership state does not contain a valid server launch configuration."
    }

    $ExistingWatchdog = Get-AnyRunningWatchdogProcess
    if ($ExistingWatchdog) {
        return [pscustomobject]@{
            Started = $false
            Pid = [int]$ExistingWatchdog.Id
        }
    }

    $ServerExeCandidates = @($PreferredServerExe, $LegacyServerExe) | Select-Object -Unique
    $EncodedCandidates = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($ServerExeCandidates | ConvertTo-Json -Compress)))
    $ArgumentList = @(
        "-NoLogo"
        "-NoProfile"
        "-ExecutionPolicy"
        "Bypass"
        "-File"
        $WatchdogScriptPath
        "-ProjectRoot"
        $ProjectRoot
        "-RuntimeOwnerStateFile"
        $RuntimeOwnerStateFile
        "-PidFile"
        $PidFile
        "-SupervisorPidFile"
        $SupervisorPidFile
        "-WatchdogPidFile"
        $WatchdogPidFile
        "-WatchdogLog"
        $WatchdogLog
        "-ServerExeCandidatesBase64"
        $EncodedCandidates
        "-Mode"
        "attach"
        "-IntervalSec"
        "15"
    )

    $WatchdogProcess = Start-Process -FilePath $PowerShellExe -ArgumentList (ConvertTo-ArgumentString -Arguments $ArgumentList) -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2

    $StartedProcess = Get-AnyRunningWatchdogProcess
    if (-not $StartedProcess) {
        throw "Watchdog process exited before startup completed."
    }

    $State | Add-Member -NotePropertyName watchdog_pid -NotePropertyValue ([int]$StartedProcess.Id) -Force
    $State | Add-Member -NotePropertyName watchdog_enabled -NotePropertyValue $true -Force
    if ([string]::Equals([string]$State.status, "running-unmanaged", [System.StringComparison]::OrdinalIgnoreCase)) {
        $State | Add-Member -NotePropertyName status -NotePropertyValue "running" -Force
    }
    Write-RuntimeOwnerState -State $State

    return [pscustomobject]@{
        Started = $true
        Pid = [int]$StartedProcess.Id
    }
}

if (-not $Start -and -not $Stop -and -not $Status) {
    $Status = $true
}

if ($Status) {
    $State = Read-RuntimeOwnerState
    $TrackedWatchdog = Get-TrackedWatchdogProcess
    if ($TrackedWatchdog) {
        Write-Host "Watchdog: running" -ForegroundColor Green
        Write-Host "PID     : $($TrackedWatchdog.Id)"
        if ($State -and $State.server_pid) {
            Write-Host "Server  : $($State.server_pid)"
        }
        if ($State -and $State.restart_count -ne $null) {
            Write-Host "Restarts: $($State.restart_count)"
        }
        if ($State -and $State.status) {
            Write-Host "Status  : $($State.status)"
        }
    }
    else {
        Write-Host "Watchdog: stopped" -ForegroundColor Yellow
        if (-not $State) {
            Write-Host "State   : runtime ownership state missing"
        }
        elseif ($State.status) {
            Write-Host "Status  : $($State.status)"
        }
    }
    return
}

if ($Stop) {
    $StoppedIds = @(Stop-WatchdogProcesses)
    if ($StoppedIds.Count -gt 0) {
        Write-Host "Stopped watchdog process(es): $($StoppedIds -join ', ')" -ForegroundColor Green
    }
    else {
        Write-Host "No watchdog process was running." -ForegroundColor Yellow
    }
    return
}

$Result = Start-WatchdogProcess
if ($Result.Started) {
    Write-Host "Started watchdog. PID: $($Result.Pid)" -ForegroundColor Green
}
else {
    Write-Host "Watchdog already running. PID: $($Result.Pid)" -ForegroundColor Yellow
}
