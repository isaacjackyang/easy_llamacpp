[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeOwnerStateFile,
    [Parameter(Mandatory = $true)]
    [string]$PidFile,
    [Parameter(Mandatory = $true)]
    [string]$SupervisorPidFile,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogPidFile,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogLog,
    [Parameter(Mandatory = $true)]
    [string]$ServerExeCandidatesBase64,
    [ValidateSet("attach", "launch")]
    [string]$Mode = "attach",
    [string]$ServerExe = $null,
    [string]$ServerArgsBase64 = $null,
    [string]$StdOutLog = $null,
    [string]$StdErrLog = $null,
    [string]$SessionId = $null,
    [ValidateSet("background", "foreground")]
    [string]$LaunchMode = "background",
    [int]$Port = 8080,
    [string]$ModelPath = $null,
    [string]$MmprojPath = $null,
    [int]$IntervalSec = 15,
    [int]$RestartDelaySec = 2
)

$ErrorActionPreference = "Stop"
$StartupGraceSec = 60
$script:WatchdogScriptPath = $PSCommandPath

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

function Write-WatchdogLog {
    param(
        [string]$Message
    )

    try {
        Add-Content -LiteralPath $WatchdogLog -Value ("{0} {1}" -f (Get-Date).ToString("o"), $Message) -Encoding UTF8
    }
    catch {
    }
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
        [Parameter(Mandatory = $true)]
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

function Get-ProcessInfoById {
    param(
        [Nullable[int]]$ProcessId
    )

    if (-not $ProcessId -or $ProcessId.Value -le 0) {
        return $null
    }

    try {
        return Get-CimInstance Win32_Process -Filter "ProcessId = $($ProcessId.Value)" -ErrorAction SilentlyContinue
    }
    catch {
        return $null
    }
}

function Test-CommandLineReferencesPath {
    param(
        [string]$CommandLine,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return ($CommandLine -match [regex]::Escape($Path))
}

function Test-WorkspaceServerProcessInfo {
    param(
        $ProcessInfo
    )

    if (-not $ProcessInfo) {
        return $false
    }

    foreach ($CandidateExe in $script:ServerExeCandidates) {
        if ($ProcessInfo.ExecutablePath -and [string]::Equals($ProcessInfo.ExecutablePath, $CandidateExe, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if (Test-CommandLineReferencesPath -CommandLine ([string]$ProcessInfo.CommandLine) -Path $CandidateExe) {
            return $true
        }
    }

    return $false
}

function Get-WorkspaceServerProcesses {
    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue |
            Where-Object { Test-WorkspaceServerProcessInfo -ProcessInfo $_ }
    )
}

function Get-WorkspaceWatchdogProcesses {
    $WatchdogPattern = [regex]::Escape($script:WatchdogScriptPath)
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and ($_.CommandLine -match $WatchdogPattern)
            }
    )
}

function Test-TrackedPidAlive {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $PidText = ((Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
    if ($PidText -notmatch '^\d+$') {
        return $null
    }

    return Get-Process -Id ([int]$PidText) -ErrorAction SilentlyContinue
}

function Ensure-SingletonWatchdog {
    $TrackedWatchdog = Test-TrackedPidAlive -Path $WatchdogPidFile
    if ($TrackedWatchdog -and $TrackedWatchdog.Id -ne $PID) {
        exit 0
    }

    $RuntimeState = Read-RuntimeOwnerState
    if ($RuntimeState) {
        [int]$RuntimeWatchdogPid = 0
        if ([int]::TryParse([string]$RuntimeState.watchdog_pid, [ref]$RuntimeWatchdogPid) -and $RuntimeWatchdogPid -gt 0 -and $RuntimeWatchdogPid -ne $PID) {
            $ProcessInfo = Get-ProcessInfoById -ProcessId ([Nullable[int]]$RuntimeWatchdogPid)
            if ($ProcessInfo -and (Test-CommandLineReferencesPath -CommandLine ([string]$ProcessInfo.CommandLine) -Path $script:WatchdogScriptPath)) {
                exit 0
            }
        }
    }

    Set-Content -LiteralPath $WatchdogPidFile -Value $PID -Encoding ASCII
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue
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
    if (Test-Path -LiteralPath $WatchdogPidFile) {
        $WatchdogText = ((Get-Content -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        $WatchdogMissing = $true
        if ($WatchdogText -match '^\d+$') {
            $WatchdogMissing = -not (Get-Process -Id ([int]$WatchdogText) -ErrorAction SilentlyContinue)
        }
        if ([string]::IsNullOrWhiteSpace($WatchdogText) -or $WatchdogText -eq [string]$PID -or $WatchdogMissing) {
            Remove-Item -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $PidFile) {
        $PidText = ((Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        $TrackedPidMatches = ($ServerPid -and $ServerPid.Value -gt 0 -and $PidText -eq [string]$ServerPid.Value)
        $TrackedPidMissing = $false
        if ($PidText -match '^\d+$') {
            $TrackedPidMissing = -not (Get-Process -Id ([int]$PidText) -ErrorAction SilentlyContinue)
        }

        if ($TrackedPidMatches -or $TrackedPidMissing -or [string]::IsNullOrWhiteSpace($PidText)) {
            Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-LaunchConfigFromState {
    param(
        $RuntimeState
    )

    if (-not $RuntimeState) {
        throw "Cannot attach watchdog because runtime ownership state is missing: $RuntimeOwnerStateFile"
    }

    $StateServerExe = [string]$RuntimeState.server_exe
    $StateServerArgs = if ($RuntimeState.server_args) { @($RuntimeState.server_args | ForEach-Object { [string]$_ }) } else { @() }
    $StateStdOutLog = [string]$RuntimeState.stdout_log
    $StateStdErrLog = [string]$RuntimeState.stderr_log
    $ResolvedSessionId = if ([string]::IsNullOrWhiteSpace([string]$RuntimeState.session_id)) { [guid]::NewGuid().ToString() } else { [string]$RuntimeState.session_id }

    if ([string]::IsNullOrWhiteSpace($StateServerExe) -or $StateServerArgs.Count -eq 0) {
        throw "Runtime ownership state does not contain a valid server launch configuration."
    }

    return @{
        SessionId = $ResolvedSessionId
        ServerExe = $StateServerExe
        ServerArgs = $StateServerArgs
        StdOutLog = $StateStdOutLog
        StdErrLog = $StateStdErrLog
        Port = if ($RuntimeState.port) { [int]$RuntimeState.port } else { $Port }
        ModelPath = if ($RuntimeState.model_path) { [string]$RuntimeState.model_path } else { $ModelPath }
        MmprojPath = if ($RuntimeState.mmproj_path) { [string]$RuntimeState.mmproj_path } else { $MmprojPath }
        LaunchMode = if ($RuntimeState.launch_mode) { [string]$RuntimeState.launch_mode } else { $LaunchMode }
        CreatedAt = [string]$RuntimeState.created_at
        RestartCount = if ($RuntimeState.restart_count) { [int]$RuntimeState.restart_count } else { 0 }
        ExistingServerPid = if ($RuntimeState.server_pid) { [int]$RuntimeState.server_pid } else { 0 }
        WatchdogEnabled = $true
    }
}

function Resolve-LaunchConfig {
    if ($Mode -eq "launch") {
        if ([string]::IsNullOrWhiteSpace($ServerExe) -or [string]::IsNullOrWhiteSpace($ServerArgsBase64)) {
            throw "Launch mode requires ServerExe and ServerArgsBase64."
        }

        return @{
            SessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { [guid]::NewGuid().ToString() } else { $SessionId }
            ServerExe = $ServerExe
            ServerArgs = @(ConvertFrom-Base64JsonArray -EncodedValue $ServerArgsBase64 | ForEach-Object { [string]$_ })
            StdOutLog = $StdOutLog
            StdErrLog = $StdErrLog
            Port = $Port
            ModelPath = $ModelPath
            MmprojPath = $MmprojPath
            LaunchMode = $LaunchMode
            CreatedAt = $null
            RestartCount = 0
            ExistingServerPid = 0
            WatchdogEnabled = $true
        }
    }

    return Resolve-LaunchConfigFromState -RuntimeState (Read-RuntimeOwnerState)
}

function Write-ManagedState {
    param(
        [hashtable]$Config,
        [int]$ServerPid,
        [string]$Status,
        [int]$RestartCount,
        [Nullable[int]]$LastExitCode = $null,
        [string]$LastRestartAt = $null,
        [string]$LastError = $null
    )

    $State = @{
        session_id = $Config.SessionId
        launch_mode = $Config.LaunchMode
        project_root = $ProjectRoot
        server_exe = $Config.ServerExe
        server_pid = $ServerPid
        supervisor_pid = $null
        watchdog_pid = [int]$PID
        port = $Config.Port
        model_path = $Config.ModelPath
        mmproj_path = $Config.MmprojPath
        stdout_log = $Config.StdOutLog
        stderr_log = $Config.StdErrLog
        server_args = @($Config.ServerArgs)
        status = $Status
        restart_count = $RestartCount
        restart_policy = "always"
        watchdog_enabled = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.CreatedAt)) {
        $State.created_at = $Config.CreatedAt
    }
    if ($LastExitCode -ne $null) {
        $State.last_exit_code = [int]$LastExitCode.Value
    }
    if (-not [string]::IsNullOrWhiteSpace($LastRestartAt)) {
        $State.last_restart_at = $LastRestartAt
    }
    if (-not [string]::IsNullOrWhiteSpace($LastError)) {
        $State.last_error = $LastError
    }

    Write-RuntimeOwnerState -State $State
}

function Start-ManagedServer {
    param(
        [hashtable]$Config
    )

    foreach ($DirectoryPath in @(
            (Split-Path -Parent $Config.StdOutLog),
            (Split-Path -Parent $Config.StdErrLog),
            (Split-Path -Parent $RuntimeOwnerStateFile)
        )) {
        if (-not [string]::IsNullOrWhiteSpace($DirectoryPath) -and -not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $DirectoryPath -Force)
        }
    }

    $ServerArgumentString = ConvertTo-ArgumentString -Arguments $Config.ServerArgs
    $StartSplat = @{
        FilePath = $Config.ServerExe
        ArgumentList = $ServerArgumentString
        WorkingDirectory = $ProjectRoot
        RedirectStandardOutput = $Config.StdOutLog
        RedirectStandardError = $Config.StdErrLog
        PassThru = $true
    }
    if ($Config.LaunchMode -eq "background") {
        $StartSplat.WindowStyle = "Hidden"
    }

    $ServerProcess = Start-Process @StartSplat
    Set-Content -LiteralPath $PidFile -Value $ServerProcess.Id -Encoding ASCII
    return $ServerProcess
}

function Stop-IllegalWorkspaceProcesses {
    param(
        [int]$AllowedServerPid
    )

    $KilledIds = New-Object System.Collections.Generic.List[int]
    foreach ($WorkspaceServerProcess in @(Get-WorkspaceServerProcesses)) {
        if ($AllowedServerPid -gt 0 -and [int]$WorkspaceServerProcess.ProcessId -eq $AllowedServerPid) {
            continue
        }

        try {
            Stop-Process -Id $WorkspaceServerProcess.ProcessId -Force -ErrorAction Stop
            $KilledIds.Add([int]$WorkspaceServerProcess.ProcessId)
        }
        catch {
        }
    }

    if ($KilledIds.Count -gt 0) {
        Write-WatchdogLog ("killed illegal runtime pids={0}" -f ($KilledIds -join ','))
    }
}

function Get-ServerExitCode {
    param(
        $Process
    )

    if (-not $Process) {
        return $null
    }

    try {
        $Process.Refresh()
        return [int]$Process.ExitCode
    }
    catch {
        return $null
    }
}

function Get-LiveServerProcessFromConfig {
    param(
        [hashtable]$Config
    )

    $RuntimeState = Read-RuntimeOwnerState
    [int]$StateServerPid = 0
    if ($RuntimeState -and [int]::TryParse([string]$RuntimeState.server_pid, [ref]$StateServerPid) -and $StateServerPid -gt 0) {
        $ProcessInfo = Get-ProcessInfoById -ProcessId ([Nullable[int]]$StateServerPid)
        if ($ProcessInfo -and (Test-WorkspaceServerProcessInfo -ProcessInfo $ProcessInfo)) {
            return Get-Process -Id $StateServerPid -ErrorAction SilentlyContinue
        }
    }

    foreach ($WorkspaceServerProcess in @(Get-WorkspaceServerProcesses | Sort-Object ProcessId)) {
        $Process = Get-Process -Id ([int]$WorkspaceServerProcess.ProcessId) -ErrorAction SilentlyContinue
        if ($Process) {
            return $Process
        }
    }

    return $null
}

$script:ServerExeCandidates = @(ConvertFrom-Base64JsonArray -EncodedValue $ServerExeCandidatesBase64)
if ($script:ServerExeCandidates.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ServerExe)) {
    $script:ServerExeCandidates = @($ServerExe)
}

$Config = Resolve-LaunchConfig
$Config.CreatedAt = if ([string]::IsNullOrWhiteSpace($Config.CreatedAt)) { (Get-Date).ToString("o") } else { $Config.CreatedAt }
$ServerProcess = $null
$RestartCount = [int]$Config.RestartCount
$LastExitCode = $null
$LastRestartAt = $null
$HasEverStartedServer = $false

try {
    Ensure-SingletonWatchdog
    Write-WatchdogLog ("watchdog started pid={0} mode={1}" -f $PID, $Mode)

    if ($Config.ExistingServerPid -gt 0) {
        $ServerProcess = Get-Process -Id $Config.ExistingServerPid -ErrorAction SilentlyContinue
    }
    if (-not $ServerProcess) {
        $ServerProcess = Get-LiveServerProcessFromConfig -Config $Config
    }

    if ($ServerProcess) {
        $HasEverStartedServer = $true
        Write-ManagedState -Config $Config -ServerPid ([int]$ServerProcess.Id) -Status "running" -RestartCount $RestartCount -LastExitCode $LastExitCode -LastRestartAt $LastRestartAt
        Stop-IllegalWorkspaceProcesses -AllowedServerPid ([int]$ServerProcess.Id)
    }

    while ($true) {
        if (-not $ServerProcess -or -not (Get-Process -Id $ServerProcess.Id -ErrorAction SilentlyContinue)) {
            if ($HasEverStartedServer) {
                $RestartCount++
                $LastRestartAt = (Get-Date).ToString("o")
                Write-ManagedState -Config $Config -ServerPid 0 -Status "restarting" -RestartCount $RestartCount -LastExitCode $LastExitCode -LastRestartAt $LastRestartAt
                Write-WatchdogLog ("server exited; restarting after {0}s (restart_count={1}, last_exit_code={2})" -f $RestartDelaySec, $RestartCount, $(if ($LastExitCode -ne $null) { $LastExitCode } else { "-" }))
                Start-Sleep -Seconds ([Math]::Max(1, $RestartDelaySec))
            }

            try {
                $ServerProcess = Start-ManagedServer -Config $Config
                $HasEverStartedServer = $true
                Write-ManagedState -Config $Config -ServerPid ([int]$ServerProcess.Id) -Status "running" -RestartCount $RestartCount -LastExitCode $LastExitCode -LastRestartAt $LastRestartAt
                Write-WatchdogLog ("server started pid={0}" -f $ServerProcess.Id)
                Stop-IllegalWorkspaceProcesses -AllowedServerPid ([int]$ServerProcess.Id)
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-ManagedState -Config $Config -ServerPid 0 -Status "restart_failed" -RestartCount $RestartCount -LastExitCode $LastExitCode -LastRestartAt $LastRestartAt -LastError $ErrorMessage
                Write-WatchdogLog ("server start failed: {0}" -f $ErrorMessage)

                if (-not $HasEverStartedServer) {
                    throw
                }

                Start-Sleep -Seconds ([Math]::Max(5, $RestartDelaySec))
                continue
            }
        }

        Stop-IllegalWorkspaceProcesses -AllowedServerPid ([int]$ServerProcess.Id)
        Write-ManagedState -Config $Config -ServerPid ([int]$ServerProcess.Id) -Status "running" -RestartCount $RestartCount -LastExitCode $LastExitCode -LastRestartAt $LastRestartAt

        Wait-Process -Id $ServerProcess.Id -Timeout ([Math]::Max(5, $IntervalSec)) -ErrorAction SilentlyContinue
        if (Get-Process -Id $ServerProcess.Id -ErrorAction SilentlyContinue) {
            continue
        }

        $LastExitCode = Get-ServerExitCode -Process $ServerProcess
        $ServerProcess = $null
    }
}
finally {
    Clear-RuntimeOwnerArtifacts -ExpectedSessionId $Config.SessionId -ServerPid $(if ($ServerProcess) { [Nullable[int]]$ServerProcess.Id } else { $null })
}
