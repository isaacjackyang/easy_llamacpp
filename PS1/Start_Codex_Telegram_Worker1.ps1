[CmdletBinding()]
param(
  [switch]$NoRun,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$bridgeScript = Join-Path $repoRoot "PS1\CodexTelegramWorker1\codex-telegram-worker1-bridge.mjs"
$runnerScript = Join-Path $repoRoot "PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.ps1"
$runnerVbs = Join-Path $repoRoot "PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.vbs"
$stateDir = Join-Path $repoRoot ".codex-telegram-worker1"
$logsDir = Join-Path $repoRoot "logs"
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueName = "CodexTelegramWorker1Bridge"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe)) {
  $powershellExe = "powershell.exe"
}
$wscriptExe = Join-Path $env:SystemRoot "System32\wscript.exe"
if (-not (Test-Path -LiteralPath $wscriptExe)) {
  $wscriptExe = "wscript.exe"
}

function Get-BridgeProcess {
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match [regex]::Escape($runnerScript)
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
  if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "Cannot find bridge script: $bridgeScript"
  }
  if (-not (Test-Path -LiteralPath $runnerScript)) {
    throw "Cannot find bridge runner script: $runnerScript"
  }
  if (-not (Test-Path -LiteralPath $runnerVbs)) {
    throw "Cannot find bridge no-console runner: $runnerVbs"
  }

  New-Item -ItemType Directory -Force -Path $stateDir, $logsDir | Out-Null

  $runCommand = '"{0}" "{1}"' -f $wscriptExe, $runnerVbs
  New-Item -Path $runKeyPath -Force | Out-Null
  Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $runCommand

  if (-not $NoRun) {
    if (@(Get-BridgeProcess).Count -eq 0) {
      Start-Process `
        -FilePath $wscriptExe `
        -ArgumentList @($runnerVbs) `
        -WindowStyle Hidden | Out-Null
    }
  }

  Write-Host "Codex Telegram worker1 bridge autostart is enabled."
  if (-not $NoRun) {
    Write-Host "Bridge process is running or start was requested."
  }
  Write-Host ("Inbox: {0}" -f (Join-Path $stateDir "inbox.jsonl"))
} catch {
  Write-Host ""
  Write-Host "Error:"
  Write-Host $_.Exception.Message
  exit 1
} finally {
  Pause-BeforeExit
}
