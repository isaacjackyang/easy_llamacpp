[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bridgeScript = Join-Path $repoRoot "PS1\CodexTelegramWorker1\codex-telegram-worker1-bridge.mjs"
$stateDir = Join-Path $repoRoot ".codex-telegram-worker1"
$logsDir = Join-Path $repoRoot "logs"
$logPath = Join-Path $logsDir "codex-telegram-worker1-bridge.log"
$nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($nodeExe)) {
  $nodeExe = "node.exe"
}

New-Item -ItemType Directory -Force -Path $stateDir, $logsDir | Out-Null

$env:EASY_LLAMACPP_ROOT = $repoRoot
$env:CODEX_TELEGRAM_WORKER1_STATE_DIR = $stateDir

& $nodeExe $bridgeScript *>> $logPath
