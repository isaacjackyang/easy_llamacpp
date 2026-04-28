$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$env:OPENCLAW_HIDE_SERVICE_CONSOLE = "1"
$env:EASY_LLAMACPP_ROOT = if (-not [string]::IsNullOrWhiteSpace($env:EASY_LLAMACPP_ROOT)) { $env:EASY_LLAMACPP_ROOT } else { "F:\Documents\GitHub\easy_llamacpp" }
$env:OPENCLAW_PLUGIN_STAGE_DIR = Join-Path $env:EASY_LLAMACPP_ROOT ".openclaw-plugin-stage"
$env:OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS = "1"
$env:OPENCLAW_SKIP_PLUGIN_SERVICES = "1"
$env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = "1"
$env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = "1"
$env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = "ipv4first"
$env:OPENCLAW_TELEGRAM_FORCE_IPV4 = "1"
$env:OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS = "1"
New-Item -ItemType Directory -Force -Path $env:OPENCLAW_PLUGIN_STAGE_DIR | Out-Null

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$stopMarker = Join-Path $rootDir "openclaw.stop"
$nodeScript = Join-Path $rootDir "start-openclaw-node.ps1"

if (Test-Path -LiteralPath $stopMarker) {
  exit 0
}

if (-not (Test-Path -LiteralPath $nodeScript)) {
  throw "Cannot find OpenClaw node script: $nodeScript"
}

& $nodeScript -GatewayHost 127.0.0.1 -GatewayPort 29644 -WaitTimeoutSeconds 480
exit $LASTEXITCODE
