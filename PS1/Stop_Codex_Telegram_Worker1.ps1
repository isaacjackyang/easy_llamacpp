[CmdletBinding()]
param(
  [switch]$ForceEnd,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$runnerScript = Join-Path $repoRoot "PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.ps1"
$bridgeScript = Join-Path $repoRoot "PS1\CodexTelegramWorker1\codex-telegram-worker1-bridge.mjs"
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueName = "CodexTelegramWorker1Bridge"

function Get-BridgeProcess {
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        (
          $_.CommandLine -match [regex]::Escape($runnerScript) -or
          $_.CommandLine -match [regex]::Escape($bridgeScript)
        )
      }
  )
}

function Pause-BeforeExit {
  if ($NoPause -or -not [Environment]::UserInteractive) {
    return
  }

  try {
    Read-Host "Press Enter to close this window" | Out-Null
  } catch {
  }
}

try {
  Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue

  $processes = @(Get-BridgeProcess)
  if ($ForceEnd -or $processes.Count -gt 0) {
    foreach ($process in $processes) {
      Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Host "Codex Telegram worker1 bridge autostart is disabled."
  if ($processes.Count -gt 0) {
    Write-Host "Bridge process stop was requested."
  }
} catch {
  Write-Host ""
  Write-Host "Error:"
  Write-Host $_.Exception.Message
  exit 1
} finally {
  Pause-BeforeExit
}
