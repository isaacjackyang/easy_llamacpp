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
    [int]$IntervalSec = 15
)

$ErrorActionPreference = "Stop"
$StartupGraceSec = 60

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

function Get-WorkspaceSupervisorProcesses {
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and (Test-CommandLineReferencesPath -CommandLine ([string]$_.CommandLine) -Path $script:SupervisorScriptPath)
            }
    )
}

function Clear-StaleRuntimeArtifacts {
    Remove-Item -LiteralPath $RuntimeOwnerStateFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
}

$script:ServerExeCandidates = @(ConvertFrom-Base64JsonArray -EncodedValue $ServerExeCandidatesBase64)
$script:SupervisorScriptPath = Join-Path $ProjectRoot "PS1\llama_supervisor.ps1"
$InvalidStateStreak = 0

if (Test-Path -LiteralPath $WatchdogPidFile) {
    $ExistingPidText = ((Get-Content -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
    if ($ExistingPidText -match '^\d+$' -and ([int]$ExistingPidText -ne $PID)) {
        $ExistingProcess = Get-Process -Id ([int]$ExistingPidText) -ErrorAction SilentlyContinue
        if ($ExistingProcess) {
            exit 0
        }
    }
}

Set-Content -LiteralPath $WatchdogPidFile -Value $PID -Encoding ASCII
Write-WatchdogLog "watchdog started pid=$PID"

while ($true) {
    $RuntimeState = Read-RuntimeOwnerState
    [int]$AllowedServerPid = 0
    [int]$AllowedSupervisorPid = 0
    $StateIsValid = $false
    $StateIsInStartupGrace = $false
    $ClaimedServerExists = $false

    if ($RuntimeState) {
        if ([int]::TryParse([string]$RuntimeState.server_pid, [ref]$AllowedServerPid) -and $AllowedServerPid -gt 0) {
            try {
                $CreatedAt = [datetime][string]$RuntimeState.created_at
                $StateIsInStartupGrace = (((Get-Date) - $CreatedAt).TotalSeconds -lt $StartupGraceSec)
            }
            catch {
            }

            $ClaimedServerExists = [bool](Get-Process -Id $AllowedServerPid -ErrorAction SilentlyContinue)
            if ([int]::TryParse([string]$RuntimeState.supervisor_pid, [ref]$AllowedSupervisorPid) -and $AllowedSupervisorPid -gt 0) {
                $SupervisorProcessInfo = Get-ProcessInfoById -ProcessId ([Nullable[int]]$AllowedSupervisorPid)
                if (-not ($SupervisorProcessInfo -and (Test-CommandLineReferencesPath -CommandLine ([string]$SupervisorProcessInfo.CommandLine) -Path $script:SupervisorScriptPath))) {
                    $AllowedSupervisorPid = 0
                }
            }

            if ($ClaimedServerExists) {
                $StateIsValid = $true
            }
            elseif ($StateIsInStartupGrace) {
                $StateIsValid = $true
            }
        }
    }

    if ($StateIsValid -or $StateIsInStartupGrace) {
        $InvalidStateStreak = 0
    }
    elseif ($RuntimeState -and -not $ClaimedServerExists) {
        $InvalidStateStreak++
    }
    else {
        $InvalidStateStreak = 0
    }

    $EnforceClaimedRuntimeCleanup = (-not $StateIsValid) -and (-not $StateIsInStartupGrace) -and ($InvalidStateStreak -ge 3)

    $KilledIds = New-Object System.Collections.Generic.List[int]
    foreach ($WorkspaceServerProcess in @(Get-WorkspaceServerProcesses)) {
        if (($StateIsValid -or $StateIsInStartupGrace -or ((-not $EnforceClaimedRuntimeCleanup) -and $AllowedServerPid -gt 0)) -and ([int]$WorkspaceServerProcess.ProcessId -eq $AllowedServerPid)) {
            continue
        }

        try {
            Stop-Process -Id $WorkspaceServerProcess.ProcessId -Force -ErrorAction Stop
            $KilledIds.Add([int]$WorkspaceServerProcess.ProcessId)
        }
        catch {
        }
    }

    foreach ($SupervisorProcess in @(Get-WorkspaceSupervisorProcesses)) {
        if (($StateIsValid -or $StateIsInStartupGrace -or ((-not $EnforceClaimedRuntimeCleanup) -and $AllowedSupervisorPid -gt 0)) -and ([int]$SupervisorProcess.ProcessId -eq $AllowedSupervisorPid)) {
            continue
        }

        try {
            Stop-Process -Id $SupervisorProcess.ProcessId -Force -ErrorAction Stop
            $KilledIds.Add([int]$SupervisorProcess.ProcessId)
        }
        catch {
        }
    }

    if ((-not $StateIsValid) -and (-not $StateIsInStartupGrace) -and $EnforceClaimedRuntimeCleanup) {
        Clear-StaleRuntimeArtifacts
    }

    if ($KilledIds.Count -gt 0) {
        Write-WatchdogLog ("killed illegal runtime pids={0}" -f ($KilledIds -join ','))
    }

    Start-Sleep -Seconds ([Math]::Max(5, $IntervalSec))
}
