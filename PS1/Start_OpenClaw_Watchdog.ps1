[CmdletBinding()]
param(
  [switch]$NoPause,
  [switch]$NoRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$watchdogScript = Join-Path $openClawRoot "scripts\watch-openclaw-stack.ps1"
$watchdogHiddenLauncher = Join-Path $openClawRoot "scripts\watch-openclaw-stack-hidden.vbs"
$stopMarker = Join-Path $openClawRoot "openclaw.stop"
$taskName = "\OpenClaw Watchdog"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe)) {
  $powershellExe = "powershell.exe"
}
$wscriptExe = Join-Path $env:SystemRoot "System32\wscript.exe"
if (-not (Test-Path -LiteralPath $wscriptExe)) {
  $wscriptExe = "wscript.exe"
}

function Invoke-Schtasks {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $output = & schtasks.exe @Arguments 2>&1
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = (($output | Out-String).Trim())
  }
}

function Test-WatchdogTaskExists {
  $result = Invoke-Schtasks -Arguments @("/Query", "/TN", $taskName)
  return ($result.ExitCode -eq 0)
}

function Ensure-WatchdogTask {
  if (-not (Test-Path -LiteralPath $watchdogScript)) {
    throw "Cannot find watchdog script: $watchdogScript"
  }

  $taskCommand = if (Test-Path -LiteralPath $watchdogHiddenLauncher) {
    '"{0}" "{1}"' -f $wscriptExe, $watchdogHiddenLauncher
  } else {
    '"{0}" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $powershellExe, $watchdogScript
  }
  $startTime = (Get-Date).AddMinutes(1).ToString("HH:mm")
  $result = Invoke-Schtasks -Arguments @(
    "/Create",
    "/TN", $taskName,
    "/TR", $taskCommand,
    "/SC", "MINUTE",
    "/MO", "1",
    "/ST", $startTime,
    "/F"
  )

  if ($result.ExitCode -ne 0) {
    throw "Failed to create watchdog task: $($result.Output)"
  }
}

function Write-WatchdogSummary {
  $result = Invoke-Schtasks -Arguments @("/Query", "/TN", $taskName, "/V", "/FO", "LIST")
  if ($result.ExitCode -ne 0) {
    Write-Host "Watchdog task: not registered"
    return
  }

  $text = [string]$result.Output
  foreach ($name in @("Status", "Scheduled Task State", "Last Run Time", "Last Result", "Next Run Time", "Repeat: Every")) {
    if ($text -match ("(?m)^{0}:\s*(.+)$" -f [regex]::Escape($name))) {
      Write-Host ("{0}: {1}" -f $name, $Matches[1].Trim())
    }
  }
}

function Pause-BeforeExit {
  if ($NoPause) {
    return
  }

  if (-not [Environment]::UserInteractive) {
    return
  }

  try {
    Read-Host "Press Enter to close this window" | Out-Null
  } catch {
  }
}

try {
  Ensure-WatchdogTask

  $enableResult = Invoke-Schtasks -Arguments @("/Change", "/TN", $taskName, "/ENABLE")
  if ($enableResult.ExitCode -ne 0) {
    throw "Failed to enable watchdog task: $($enableResult.Output)"
  }

  if (-not $NoRun) {
    $runResult = Invoke-Schtasks -Arguments @("/Run", "/TN", $taskName)
    if ($runResult.ExitCode -ne 0 -and $runResult.Output -notmatch "already running") {
      throw "Failed to start watchdog task: $($runResult.Output)"
    }
  }

  Write-Host "OpenClaw Watchdog enabled."
  if (-not $NoRun) {
    Write-Host "OpenClaw Watchdog run requested."
  }
  if (Test-Path -LiteralPath $stopMarker) {
    Write-Host "Warning: openclaw.stop exists, so watchdog will not restart OpenClaw services until start_openclaw.cmd removes it."
  }
  Write-WatchdogSummary
} catch {
  Write-Host ""
  Write-Host "Error:"
  Write-Host $_.Exception.Message
  exit 1
} finally {
  Pause-BeforeExit
}
