[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$LlamaCppOnly,
    [switch]$OpenClawOnly,
    [switch]$VoiceServiceOnly
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
$PreferredServerExe = Join-Path $ProjectRoot "bin\llama-server.exe"
$LegacyServerExe = Join-Path $ProjectRoot "llama-server.exe"
$StopTimeoutSec = 20
$OpenClawTaskNames = @("OpenClaw Gateway", "OpenClaw Node")

$TrackedPidFiles = @(
    $PidFile
    $LegacyPidFile
) | Select-Object -Unique

$TargetServerPaths = @(
    $PreferredServerExe
    $LegacyServerExe
) | Where-Object { Test-Path -LiteralPath $_ }

$TargetServerPatterns = @($TargetServerPaths | ForEach-Object { [regex]::Escape($_) })

$requestedModes = @(
    @($LlamaCppOnly, $OpenClawOnly, $VoiceServiceOnly) |
        Where-Object { $_ }
).Count

if ($requestedModes -gt 1) {
    throw "Use only one of -LlamaCppOnly, -OpenClawOnly, or -VoiceServiceOnly."
}

$RunLlamaCpp = -not ($OpenClawOnly -or $VoiceServiceOnly)
$RunOpenClaw = -not ($LlamaCppOnly -or $VoiceServiceOnly)
$RunVoiceService = $VoiceServiceOnly

$StopTargetLabel = if ($LlamaCppOnly) {
    "workspace llama.cpp"
}
elseif ($OpenClawOnly) {
    "OpenClaw"
}
elseif ($VoiceServiceOnly) {
    "voice service (TTS/STT)"
}
else {
    "workspace llama.cpp and OpenClaw"
}

$FailureScopeLabel = if ($LlamaCppOnly) {
    "llama.cpp"
}
elseif ($OpenClawOnly) {
    "OpenClaw"
}
elseif ($VoiceServiceOnly) {
    "voice service"
}
else {
    "llama.cpp/OpenClaw"
}

$CompletionMessage = if ($LlamaCppOnly) {
    "Workspace llama.cpp cleanup complete."
}
elseif ($OpenClawOnly) {
    "OpenClaw cleanup complete."
}
elseif ($VoiceServiceOnly) {
    "Voice service cleanup complete."
}
else {
    "Workspace llama.cpp and OpenClaw cleanup complete."
}

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

function Stop-LcppRuntime {
    $ProcessIdsToStop = New-Object System.Collections.Generic.HashSet[int]

    foreach ($TrackedPidFile in $TrackedPidFiles) {
        if (-not (Test-Path -LiteralPath $TrackedPidFile)) {
            continue
        }

        $TrackedPidText = ((Get-Content -LiteralPath $TrackedPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        if ($TrackedPidText -match '^\d+$') {
            $null = $ProcessIdsToStop.Add([int]$TrackedPidText)
        }
    }

    $WorkspaceProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $WorkspaceProcess = $_
                $MatchesExecutablePath = $WorkspaceProcess.ExecutablePath -and ($TargetServerPaths -contains $WorkspaceProcess.ExecutablePath)
                $MatchesCommandLine = $false

                if ($WorkspaceProcess.CommandLine) {
                    foreach ($TargetServerPattern in $TargetServerPatterns) {
                        if ($WorkspaceProcess.CommandLine -match $TargetServerPattern) {
                            $MatchesCommandLine = $true
                            break
                        }
                    }
                }

                $MatchesExecutablePath -or $MatchesCommandLine
            }
    )

    foreach ($WorkspaceProcess in $WorkspaceProcesses) {
        $null = $ProcessIdsToStop.Add([int]$WorkspaceProcess.ProcessId)
    }

    $RemovedStalePid = $false
    if ($ProcessIdsToStop.Count -eq 0) {
        foreach ($TrackedPidFile in $TrackedPidFiles) {
            if (Test-Path -LiteralPath $TrackedPidFile) {
                if ($PSCmdlet.ShouldProcess($TrackedPidFile, "Remove stale PID file")) {
                    Remove-Item -LiteralPath $TrackedPidFile -ErrorAction SilentlyContinue
                }
                $RemovedStalePid = $true
            }
        }

        return [pscustomobject]@{
            FoundAny        = $false
            RemovedStalePid = $RemovedStalePid
            StoppedIds      = @()
            FailedIds       = @()
            RemainingIds    = @()
        }
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

    foreach ($TrackedPidFile in $TrackedPidFiles) {
        if ($PSCmdlet.ShouldProcess($TrackedPidFile, "Remove tracked PID file")) {
            Remove-Item -LiteralPath $TrackedPidFile -ErrorAction SilentlyContinue
        }
    }

    if ($WhatIfPreference) {
        return [pscustomobject]@{
            FoundAny        = $true
            RemovedStalePid = $false
            StoppedIds      = @($StoppedIds)
            FailedIds       = @($FailedIds)
            RemainingIds    = @()
        }
    }

    $StopDeadline = (Get-Date).AddSeconds($StopTimeoutSec)
    $RemainingIds = @()
    do {
        $RemainingIds = @(
            $ProcessIdsToStop |
                Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
        )

        if ($RemainingIds.Count -eq 0) {
            break
        }

        Start-Sleep -Milliseconds 500
    }
    while ((Get-Date) -lt $StopDeadline)

    return [pscustomobject]@{
        FoundAny        = $true
        RemovedStalePid = $false
        StoppedIds      = @($StoppedIds)
        FailedIds       = @($FailedIds)
        RemainingIds    = @($RemainingIds)
    }
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

function Stop-VoiceServiceRuntime {
    $ProcessesToStop = @(Get-ManagedMediaProcesses) | Sort-Object ProcessId -Unique

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
        if ($PSCmdlet.ShouldProcess("PID $($Process.ProcessId)", "Stop voice-service process")) {
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

    $StopDeadline = (Get-Date).AddSeconds(10)
    $TargetIds = @($ProcessesToStop | ForEach-Object { [int]$_.ProcessId } | Select-Object -Unique)
    $RemainingIds = @()
    do {
        $RemainingIds = @(
            $TargetIds |
                Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
        )

        if ($RemainingIds.Count -eq 0) {
            break
        }

        Start-Sleep -Milliseconds 500
    }
    while ((Get-Date) -lt $StopDeadline)

    return [pscustomobject]@{
        FoundAny     = $true
        StoppedIds   = @($StoppedIds)
        FailedIds    = @($FailedIds)
        RemainingIds = @($RemainingIds)
    }
}

function Stop-OpenClawRuntime {
    foreach ($TaskName in $OpenClawTaskNames) {
        if ($PSCmdlet.ShouldProcess("Scheduled task $TaskName", "End OpenClaw autostart task")) {
            & schtasks.exe /End /TN $TaskName *> $null
        }
    }

    $ProcessesToStop = @(
        @(Get-OpenClawGatewayHostProcesses) +
        @(Get-OpenClawNodeHostProcesses) +
        @(Get-ManagedMediaProcesses)
    ) | Sort-Object ProcessId -Unique

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
        if ($PSCmdlet.ShouldProcess("PID $($Process.ProcessId)", "Stop OpenClaw-related process")) {
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

    $StopDeadline = (Get-Date).AddSeconds(10)
    $TargetIds = @($ProcessesToStop | ForEach-Object { [int]$_.ProcessId } | Select-Object -Unique)
    $RemainingIds = @()
    do {
        $RemainingIds = @(
            $TargetIds |
                Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
        )

        if ($RemainingIds.Count -eq 0) {
            break
        }

        Start-Sleep -Milliseconds 500
    }
    while ((Get-Date) -lt $StopDeadline)

    return [pscustomobject]@{
        FoundAny     = $true
        StoppedIds   = @($StoppedIds)
        FailedIds    = @($FailedIds)
        RemainingIds = @($RemainingIds)
    }
}

Write-Host ""
Write-Host "Stopping $StopTargetLabel..." -ForegroundColor Cyan
Write-Host ""

$LcppResult = if ($RunLlamaCpp) {
    Stop-LcppRuntime
}
else {
    [pscustomobject]@{
        FoundAny        = $false
        RemovedStalePid = $false
        StoppedIds      = @()
        FailedIds       = @()
        RemainingIds    = @()
    }
}

$OpenClawResult = if ($RunOpenClaw) {
    Stop-OpenClawRuntime
}
else {
    [pscustomobject]@{
        FoundAny        = $false
        RemovedStalePid = $false
        StoppedIds      = @()
        FailedIds       = @()
        RemainingIds    = @()
    }
}

$VoiceServiceResult = if ($RunVoiceService) {
    Stop-VoiceServiceRuntime
}
else {
    [pscustomobject]@{
        FoundAny     = $false
        StoppedIds   = @()
        FailedIds    = @()
        RemainingIds = @()
    }
}

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "WhatIf cleanup plan complete." -ForegroundColor Cyan
    return
}

if ($RunLlamaCpp) {
    if ($LcppResult.StoppedIds.Count -gt 0) {
        Write-Ok "Stopped llama.cpp server process(es): $($LcppResult.StoppedIds -join ', ')"
    }
    elseif ($LcppResult.RemovedStalePid) {
        Write-WarnText "No workspace llama.cpp server processes found. Removed stale PID file(s)."
    }
    else {
        Write-Info "No workspace llama.cpp server processes found."
    }
}

if ($RunOpenClaw) {
    if ($OpenClawResult.StoppedIds.Count -gt 0) {
        Write-Ok "Stopped OpenClaw/TTS/STT process(es): $($OpenClawResult.StoppedIds -join ', ')"
    }
    else {
        Write-Info "No OpenClaw/TTS/STT processes found."
    }
}

if ($RunVoiceService) {
    if ($VoiceServiceResult.StoppedIds.Count -gt 0) {
        Write-Ok "Stopped voice-service process(es): $($VoiceServiceResult.StoppedIds -join ', ')"
    }
    else {
        Write-Info "No voice-service processes found."
    }
}

$AllFailedIds = @(
    @($LcppResult.RemainingIds) +
    @($LcppResult.FailedIds) +
    @($OpenClawResult.RemainingIds) +
    @($OpenClawResult.FailedIds) +
    @($VoiceServiceResult.RemainingIds) +
    @($VoiceServiceResult.FailedIds)
) | Select-Object -Unique

if ($AllFailedIds.Count -gt 0) {
    throw "Some $FailureScopeLabel processes could not be cleared: $($AllFailedIds -join ', ')"
}

if ($RunLlamaCpp -and $RunOpenClaw) {
    if ($LcppResult.StoppedIds.Count -eq 0 -and -not $LcppResult.RemovedStalePid -and $OpenClawResult.StoppedIds.Count -eq 0) {
        Write-WarnText "No workspace llama.cpp or OpenClaw processes found."
        return
    }
}
elseif ($RunLlamaCpp) {
    if ($LcppResult.StoppedIds.Count -eq 0 -and -not $LcppResult.RemovedStalePid) {
        return
    }
}
elseif ($RunOpenClaw) {
    if ($OpenClawResult.StoppedIds.Count -eq 0) {
        return
    }
}
elseif ($RunVoiceService) {
    if ($VoiceServiceResult.StoppedIds.Count -eq 0) {
        return
    }
}

Write-Ok $CompletionMessage
