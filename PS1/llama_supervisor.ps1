[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$ServerExe,
    [Parameter(Mandatory = $true)]
    [string]$ServerArgsBase64,
    [Parameter(Mandatory = $true)]
    [string]$StdOutLog,
    [Parameter(Mandatory = $true)]
    [string]$StdErrLog,
    [Parameter(Mandatory = $true)]
    [string]$PidFile,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeOwnerStateFile,
    [Parameter(Mandatory = $true)]
    [string]$SupervisorPidFile,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogPidFile,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogLog,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogScriptPath,
    [Parameter(Mandatory = $true)]
    [string]$SessionId,
    [ValidateSet("background", "foreground")]
    [string]$LaunchMode = "background",
    [int]$Port = 8080,
    [string]$ModelPath = $null,
    [string]$MmprojPath = $null,
    [int]$WatchdogIntervalSec = 15
)

$ErrorActionPreference = "Stop"

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

function Get-CurrentHostExecutablePath {
    try {
        $HostProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($HostProcess -and -not [string]::IsNullOrWhiteSpace($HostProcess.Path)) {
            return [string]$HostProcess.Path
        }
    }
    catch {
    }

    return "powershell.exe"
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
        [hashtable]$State
    )

    $TempPath = "$RuntimeOwnerStateFile.tmp"
    $State.updated_at = (Get-Date).ToString("o")
    if (-not $State.ContainsKey("created_at")) {
        $State.created_at = $State.updated_at
    }

    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $TempPath -Encoding UTF8
    Move-Item -LiteralPath $TempPath -Destination $RuntimeOwnerStateFile -Force
}

function Clear-RuntimeOwnerArtifacts {
    param(
        [string]$ExpectedSessionId,
        [Nullable[int]]$ServerPid = $null
    )

    $CurrentState = Read-RuntimeOwnerState
    if ($CurrentState -and -not [string]::IsNullOrWhiteSpace([string]$CurrentState.session_id) -and -not [string]::Equals([string]$CurrentState.session_id, $ExpectedSessionId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    Remove-Item -LiteralPath $RuntimeOwnerStateFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $PidFile) {
        $PidText = ((Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        if (($ServerPid -and $ServerPid.Value -gt 0 -and $PidText -eq [string]$ServerPid.Value) -or [string]::IsNullOrWhiteSpace($PidText)) {
            Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
        }
    }
}

function Start-OwnershipWatchdog {
    if (-not (Test-Path -LiteralPath $WatchdogScriptPath)) {
        return $null
    }

    if (Test-Path -LiteralPath $WatchdogPidFile) {
        $TrackedPidText = ((Get-Content -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        if ($TrackedPidText -match '^\d+$') {
            $TrackedWatchdog = Get-Process -Id ([int]$TrackedPidText) -ErrorAction SilentlyContinue
            if ($TrackedWatchdog) {
                return [int]$TrackedPidText
            }
        }
    }

    $HostExecutable = Get-CurrentHostExecutablePath
    $ServerExeCandidates = @(
        $ServerExe
        (Join-Path $ProjectRoot "llama-server.exe")
    ) | Select-Object -Unique
    $EncodedCandidates = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($ServerExeCandidates | ConvertTo-Json -Compress)))
    $WatchdogArgs = @(
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
        "-IntervalSec"
        ([string]$WatchdogIntervalSec)
    )

    $WatchdogProcess = Start-Process -FilePath $HostExecutable -ArgumentList (ConvertTo-ArgumentString -Arguments $WatchdogArgs) -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
    return $WatchdogProcess.Id
}

foreach ($DirectoryPath in @(
        (Split-Path -Parent $StdOutLog),
        (Split-Path -Parent $StdErrLog),
        (Split-Path -Parent $RuntimeOwnerStateFile)
    )) {
    if (-not [string]::IsNullOrWhiteSpace($DirectoryPath) -and -not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $DirectoryPath -Force)
    }
}

$ServerArgs = @(ConvertFrom-Base64JsonArray -EncodedValue $ServerArgsBase64)
$ServerProcess = $null
$WatchdogPid = $null
$PreserveBackgroundRuntime = $false

try {
    Set-Content -LiteralPath $SupervisorPidFile -Value $PID -Encoding ASCII

    $ServerArgumentString = ConvertTo-ArgumentString -Arguments $ServerArgs
    if ($LaunchMode -eq "background") {
        $ServerProcess = Start-Process `
            -FilePath $ServerExe `
            -ArgumentList $ServerArgumentString `
            -WorkingDirectory $ProjectRoot `
            -RedirectStandardOutput $StdOutLog `
            -RedirectStandardError $StdErrLog `
            -WindowStyle Hidden `
            -PassThru
    }
    else {
        $ServerProcess = Start-Process `
            -FilePath $ServerExe `
            -ArgumentList $ServerArgumentString `
            -WorkingDirectory $ProjectRoot `
            -RedirectStandardOutput $StdOutLog `
            -RedirectStandardError $StdErrLog `
            -PassThru
    }

    Set-Content -LiteralPath $PidFile -Value $ServerProcess.Id -Encoding ASCII
    Write-RuntimeOwnerState -State @{
        session_id = $SessionId
        launch_mode = $LaunchMode
        project_root = $ProjectRoot
        server_exe = $ServerExe
        server_pid = [int]$ServerProcess.Id
        supervisor_pid = [int]$PID
        watchdog_pid = $null
        port = $Port
        model_path = $ModelPath
        mmproj_path = $MmprojPath
        stdout_log = $StdOutLog
        stderr_log = $StdErrLog
        server_args = @($ServerArgs)
        status = "running"
    }

    $WatchdogPid = Start-OwnershipWatchdog
    if ($WatchdogPid) {
        Write-RuntimeOwnerState -State @{
            session_id = $SessionId
            launch_mode = $LaunchMode
            project_root = $ProjectRoot
            server_exe = $ServerExe
            server_pid = [int]$ServerProcess.Id
            supervisor_pid = [int]$PID
            watchdog_pid = [int]$WatchdogPid
            port = $Port
            model_path = $ModelPath
            mmproj_path = $MmprojPath
            stdout_log = $StdOutLog
            stderr_log = $StdErrLog
            server_args = @($ServerArgs)
            status = "running"
        }
    }

    if ($LaunchMode -eq "background") {
        $PreserveBackgroundRuntime = $true
        return
    }

    Wait-Process -Id $ServerProcess.Id
    try {
        $ServerProcess.Refresh()
        exit $ServerProcess.ExitCode
    }
    catch {
        exit 0
    }
}
finally {
    if (($LaunchMode -eq "foreground") -or (-not $PreserveBackgroundRuntime)) {
        Clear-RuntimeOwnerArtifacts -ExpectedSessionId $SessionId -ServerPid $(if ($ServerProcess) { [Nullable[int]]$ServerProcess.Id } else { $null })
    }
}
