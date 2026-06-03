[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$LlamaCppOnly
)

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
$LegacyMmprojPidFile = Join-Path $ProjectRoot "logs\vision-server.pid"
$RuntimeOwnerStateFile = Join-Path $ProjectRoot "logs\llama-runtime-owner.json"
$SupervisorPidFile = Join-Path $ProjectRoot "logs\llama-supervisor.pid"
$WatchdogPidFile = Join-Path $ProjectRoot "logs\llama-watchdog.pid"
$PreferredServerExe = Join-Path $ProjectRoot "bin\llama-server.exe"
$LegacyServerExe = Join-Path $ProjectRoot "llama-server.exe"
$SupervisorScriptPath = Join-Path $ProjectRoot "PS1\llama_supervisor.ps1"
$WatchdogScriptPath = Join-Path $ProjectRoot "PS1\llama_watchdog.ps1"
$TrackedPidFiles = @($PidFile, $LegacyPidFile, $LegacyMmprojPidFile, $SupervisorPidFile, $WatchdogPidFile) | Select-Object -Unique
$TargetServerPaths = @($PreferredServerExe, $LegacyServerExe) | Where-Object { Test-Path -LiteralPath $_ }
$TargetServerPatterns = @($TargetServerPaths | ForEach-Object { [regex]::Escape($_) })

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

function Wait-ForStoppedIds {
    param(
        [int[]]$TargetIds,
        [int]$TimeoutSec = 10
    )

    $Deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSec))
    do {
        $RemainingIds = @(
            $TargetIds |
                Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
        )
        if ($RemainingIds.Count -eq 0) {
            return @()
        }

        Start-Sleep -Milliseconds 500
    }
    while ((Get-Date) -lt $Deadline)

    return @($RemainingIds)
}

function Stop-ProcessGroup {
    param(
        [System.Collections.IEnumerable]$Processes,
        [string]$ActionLabel
    )

    $ProcessesToStop = @($Processes | Sort-Object ProcessId -Unique)
    if ($ProcessesToStop.Count -eq 0) {
        return [pscustomobject]@{
            FoundAny     = $false
            StoppedIds   = @()
            FailedIds    = @()
            RemainingIds = @()
        }
    }

    $StoppedIds = New-Object System.Collections.Generic.List[int]
    $FailedIds = New-Object System.Collections.Generic.List[int]

    foreach ($Process in $ProcessesToStop) {
        if ($PSCmdlet.ShouldProcess("PID $($Process.ProcessId)", $ActionLabel)) {
            try {
                Stop-Process -Id $Process.ProcessId -Force -ErrorAction Stop
                $StoppedIds.Add([int]$Process.ProcessId)
            }
            catch {
                $FailedIds.Add([int]$Process.ProcessId)
            }
        }
    }

    if ($WhatIfPreference) {
        return [pscustomobject]@{
            FoundAny     = $true
            StoppedIds   = @($StoppedIds)
            FailedIds    = @($FailedIds)
            RemainingIds = @()
        }
    }

    $TargetIds = @($ProcessesToStop | ForEach-Object { [int]$_.ProcessId } | Select-Object -Unique)
    $RemainingIds = Wait-ForStoppedIds -TargetIds $TargetIds -TimeoutSec 10
    return [pscustomobject]@{
        FoundAny     = $true
        StoppedIds   = @($StoppedIds)
        FailedIds    = @($FailedIds)
        RemainingIds = @($RemainingIds)
    }
}

function Remove-StalePidFile {
    param([string]$Path)

    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, "Remove stale PID file")) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $true
    }

    return $false
}

function Get-LlamaCppProcesses {
    $TrackedIds = New-Object System.Collections.Generic.HashSet[int]
    foreach ($TrackedPidFile in $TrackedPidFiles) {
        if (-not (Test-Path -LiteralPath $TrackedPidFile)) {
            continue
        }

        $TrackedPidText = ((Get-Content -LiteralPath $TrackedPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        if ($TrackedPidText -match '^\d+$') {
            [void]$TrackedIds.Add([int]$TrackedPidText)
        }
    }

    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $CommandLine = [string]$_.CommandLine
                $MatchesExecutablePath = $_.ExecutablePath -and ($TargetServerPaths -contains $_.ExecutablePath)
                $MatchesCommandLine = $false
                if ($CommandLine) {
                    foreach ($TargetServerPattern in $TargetServerPatterns) {
                        if ($CommandLine -match $TargetServerPattern) {
                            $MatchesCommandLine = $true
                            break
                        }
                    }
                }

                $TrackedIds.Contains([int]$_.ProcessId) -or $MatchesExecutablePath -or $MatchesCommandLine
            }
    )
}

function Get-ScriptProcesses {
    param(
        [string]$ScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        return @()
    }

    $ScriptPattern = [regex]::Escape($ScriptPath)
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and ($_.CommandLine -match $ScriptPattern)
            }
    )
}

function Remove-RuntimeArtifactFiles {
    foreach ($RuntimeArtifact in @(
            $RuntimeOwnerStateFile,
            $SupervisorPidFile,
            $WatchdogPidFile
        )) {
        if ((Test-Path -LiteralPath $RuntimeArtifact) -and $PSCmdlet.ShouldProcess($RuntimeArtifact, "Remove runtime artifact")) {
            Remove-Item -LiteralPath $RuntimeArtifact -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-LlamaCppRuntime {
    $Processes = @(
        @(Get-ScriptProcesses -ScriptPath $WatchdogScriptPath) +
        @(Get-ScriptProcesses -ScriptPath $SupervisorScriptPath) +
        @(Get-LlamaCppProcesses)
    )
    $Processes = @(
        $Processes |
            Group-Object ProcessId |
            ForEach-Object { $_.Group | Select-Object -First 1 }
    )
    $RemovedStalePid = $false

    if ($Processes.Count -eq 0) {
        foreach ($TrackedPidFile in $TrackedPidFiles) {
            if (Remove-StalePidFile -Path $TrackedPidFile) {
                $RemovedStalePid = $true
            }
        }
        Remove-RuntimeArtifactFiles

        return [pscustomobject]@{
            FoundAny        = $false
            RemovedStalePid = $RemovedStalePid
            StoppedIds      = @()
            FailedIds       = @()
            RemainingIds    = @()
        }
    }

    $Result = Stop-ProcessGroup -Processes $Processes -ActionLabel "Stop llama.cpp server process"
    foreach ($TrackedPidFile in $TrackedPidFiles) {
        Remove-StalePidFile -Path $TrackedPidFile | Out-Null
    }
    Remove-RuntimeArtifactFiles

    return [pscustomobject]@{
        FoundAny        = $Result.FoundAny
        RemovedStalePid = $false
        StoppedIds      = $Result.StoppedIds
        FailedIds       = $Result.FailedIds
        RemainingIds    = $Result.RemainingIds
    }
}

Write-Host ""
Write-Host "Stopping workspace llama.cpp..." -ForegroundColor Cyan
Write-Host ""

$LcppResult = Stop-LlamaCppRuntime

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "WhatIf cleanup plan complete." -ForegroundColor Cyan
    return
}

if ($LcppResult.StoppedIds.Count -gt 0) {
    Write-Ok "Stopped llama.cpp server process(es): $($LcppResult.StoppedIds -join ', ')"
}
elseif ($LcppResult.RemovedStalePid) {
    Write-WarnText "No workspace llama.cpp server processes found. Removed stale PID file(s)."
}
else {
    Write-Info "No workspace llama.cpp server processes found."
}

$AllFailedIds = @(
    @($LcppResult.RemainingIds) +
    @($LcppResult.FailedIds)
) | Select-Object -Unique

if ($AllFailedIds.Count -gt 0) {
    throw "Some llama.cpp processes could not be cleared: $($AllFailedIds -join ', ')"
}

if ($LcppResult.StoppedIds.Count -eq 0 -and -not $LcppResult.RemovedStalePid) {
    return
}

Write-Ok "Workspace llama.cpp cleanup complete."
