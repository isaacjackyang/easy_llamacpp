[CmdletBinding()]
param(
  [switch]$ForceEnd,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskName = "\OpenClaw Watchdog"

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
  if (-not (Test-WatchdogTaskExists)) {
    Write-Host "OpenClaw Watchdog is not registered."
    exit 0
  }

  $disableResult = Invoke-Schtasks -Arguments @("/Change", "/TN", $taskName, "/DISABLE")
  if ($disableResult.ExitCode -ne 0) {
    throw "Failed to disable watchdog task: $($disableResult.Output)"
  }

  if ($ForceEnd) {
    $endResult = Invoke-Schtasks -Arguments @("/End", "/TN", $taskName)
    if ($endResult.ExitCode -ne 0 -and
        $endResult.Output -notmatch "not currently running" -and
        $endResult.Output -notmatch "has not yet run") {
      Write-Host ("schtasks /End exited {0}; continuing." -f $endResult.ExitCode)
    }
  }

  Write-Host "OpenClaw Watchdog disabled."
  if (-not $ForceEnd) {
    Write-Host "Any currently running watchdog pass was left alone so an in-progress restart can finish."
  }
  Write-Host "OpenClaw services were not stopped. Use stop_openclaw.cmd if you want to stop the stack too."
  Write-WatchdogSummary
} catch {
  Write-Host ""
  Write-Host "Error:"
  Write-Host $_.Exception.Message
  exit 1
} finally {
  Pause-BeforeExit
}
