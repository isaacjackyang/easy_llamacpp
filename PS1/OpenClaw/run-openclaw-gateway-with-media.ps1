$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Hide-ServiceConsole {
  if ($env:OPENCLAW_HIDE_SERVICE_CONSOLE -ne "1") {
    return
  }

  try {
    Add-Type -Namespace OpenClaw.Win32 -Name ConsoleWindow -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@
    $handle = [OpenClaw.Win32.ConsoleWindow]::GetConsoleWindow()
    if ($handle -ne [System.IntPtr]::Zero) {
      [void][OpenClaw.Win32.ConsoleWindow]::ShowWindow($handle, 0)
    }
  } catch {
  }
}

Hide-ServiceConsole

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-HttpHealth {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSec = 2
  )

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
    return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
  } catch {
    return $false
  }
}

function Test-ProcessAlive {
  param([int]$ProcessId)

  if ($ProcessId -le 0) {
    return $true
  }

  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    return ($null -ne $process)
  } catch {
    return $false
  }
}

function Stop-MediaProcesses {
  $patterns = @(
    'workspace[\\/]+tts_server\.py',
    'workspace[\\/]+stt_server\.py'
  )

  Get-CimInstance Win32_Process |
    Where-Object {
      $commandLine = $_.CommandLine
      if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
      }

      foreach ($pattern in $patterns) {
        if ($commandLine -match $pattern) {
          return $true
        }
      }

      return $false
    } |
    ForEach-Object {
      try {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
      } catch {
      }
    }
}

function Start-ManagedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$StdoutLog,
    [Parameter(Mandatory = $true)][string]$StderrLog,
    [hashtable]$Environment = $null
  )

  Set-Content -LiteralPath $StdoutLog -Value "" -Encoding utf8
  Set-Content -LiteralPath $StderrLog -Value "" -Encoding utf8

  $ps = Start-Process `
    -FilePath $FilePath `
    -ArgumentList $Arguments `
    -WorkingDirectory $WorkingDirectory `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -WindowStyle Hidden `
    -PassThru

  Write-Host "$Name started with PID $($ps.Id)" -ForegroundColor Green
  return $ps
}

function Wait-ManagedService {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][string]$HealthUrl,
    [Parameter(Mandatory = $true)][string]$StdoutLog,
    [Parameter(Mandatory = $true)][string]$StderrLog,
    [int]$LauncherParentId = 0,
    [int]$ReadyTimeoutSeconds = 180,
    [int]$ProbeIntervalSeconds = 2
  )

  $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-ProcessAlive -ProcessId $LauncherParentId)) {
      throw "$Name startup was cancelled because the OpenClaw launcher exited."
    }

    try {
      $Process.Refresh()
      if ($Process.HasExited) {
        break
      }
    } catch {
      break
    }

    if (Test-HttpHealth -Url $HealthUrl) {
      Write-Host "$Name is healthy at $HealthUrl" -ForegroundColor Green
      return
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  $stdoutTail = ""
  $stderrTail = ""
  if (Test-Path -LiteralPath $StdoutLog) {
    $stdoutTail = (Get-Content -LiteralPath $StdoutLog -Tail 40 | Out-String).Trim()
  }
  if (Test-Path -LiteralPath $StderrLog) {
    $stderrTail = (Get-Content -LiteralPath $StderrLog -Tail 40 | Out-String).Trim()
  }

  if ($stdoutTail) {
    Write-Host ""
    Write-Host "[$Name stdout tail]"
    Write-Host $stdoutTail
  }
  if ($stderrTail) {
    Write-Host ""
    Write-Host "[$Name stderr tail]"
    Write-Host $stderrTail
  }

  throw "$Name did not become healthy in time."
}

function Wait-GatewayExit {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$GatewayProcess,
    [int]$LauncherParentId = 0,
    [int]$ProbeIntervalSeconds = 2
  )

  while ($true) {
    if (-not (Test-ProcessAlive -ProcessId $LauncherParentId)) {
      Write-Warning "OpenClaw launcher exited; stopping gateway."
      try {
        Stop-Process -Id $GatewayProcess.Id -Force -ErrorAction Stop
      } catch {
      }
    }

    try {
      $GatewayProcess.Refresh()
      if ($GatewayProcess.HasExited) {
        return [int]$GatewayProcess.ExitCode
      }
    } catch {
      return 1
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }
}

function Remove-OpenClawJsonProperty {
  param(
    [Parameter(Mandatory = $true)][object]$Node,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not ($Node -is [pscustomobject])) {
    return $false
  }

  if (-not ($Node.PSObject.Properties.Name -contains $Name)) {
    return $false
  }

  [void]$Node.PSObject.Properties.Remove($Name)
  return $true
}

function Save-OpenClawJsonUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][object]$Payload
  )

  $json = $Payload | ConvertTo-Json -Depth 100
  [System.IO.File]::WriteAllText(
    $Path,
    $json + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Disable-OpenClawHeavyGatewayStartupConfig {
  param([Parameter(Mandatory = $true)][string]$ConfigPath)

  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    return
  }

  $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  $changedKeys = New-Object System.Collections.Generic.List[string]
  $heavyPlugins = @("agentmemory", "browser", "openclaw-web-search", "voice-call")

  if ($config.PSObject.Properties.Name -contains "browser" -and $config.browser -is [pscustomobject]) {
    if (-not ($config.browser.PSObject.Properties.Name -contains "enabled") -or $config.browser.enabled -ne $false) {
      $config.browser | Add-Member -NotePropertyName "enabled" -NotePropertyValue $false -Force
      $changedKeys.Add("browser.enabled")
    }
  }

  if ($config.PSObject.Properties.Name -contains "hooks" -and
      $config.hooks -is [pscustomobject] -and
      $config.hooks.PSObject.Properties.Name -contains "internal" -and
      $config.hooks.internal -is [pscustomobject] -and
      $config.hooks.internal.PSObject.Properties.Name -contains "enabled" -and
      $config.hooks.internal.enabled -ne $false) {
    $config.hooks.internal.enabled = $false
    $changedKeys.Add("hooks.internal.enabled")
  }

  if ($config.PSObject.Properties.Name -contains "plugins" -and $config.plugins -is [pscustomobject]) {
    if ($config.plugins.PSObject.Properties.Name -contains "allow") {
      $allowedPlugins = @($config.plugins.allow | ForEach-Object { [string]$_ })
      $updatedAllowedPlugins = @($allowedPlugins | Where-Object { $heavyPlugins -notcontains $_ })
      if ($updatedAllowedPlugins.Count -ne $allowedPlugins.Count) {
        $config.plugins.allow = @($updatedAllowedPlugins)
        $changedKeys.Add("plugins.allow")
      }
    }

    if ($config.plugins.PSObject.Properties.Name -contains "load" -and
        $config.plugins.load -is [pscustomobject] -and
        $config.plugins.load.PSObject.Properties.Name -contains "paths") {
      $loadPaths = @($config.plugins.load.paths | ForEach-Object { [string]$_ })
      $updatedLoadPaths = @($loadPaths | Where-Object { $_ -notmatch '(?i)agentmemory|browser|openclaw-web-search|voice-call' })
      if ($updatedLoadPaths.Count -ne $loadPaths.Count) {
        $config.plugins.load.paths = @($updatedLoadPaths)
        $changedKeys.Add("plugins.load.paths")
      }
    }

    if ($config.plugins.PSObject.Properties.Name -contains "entries" -and $config.plugins.entries -is [pscustomobject]) {
      foreach ($pluginName in $heavyPlugins) {
        if (Remove-OpenClawJsonProperty -Node $config.plugins.entries -Name $pluginName) {
          $changedKeys.Add("plugins.entries.$pluginName")
        }
      }
    }
  }

  if ($config.PSObject.Properties.Name -contains "mcp" -and $config.mcp -is [pscustomobject]) {
    if ($config.mcp.PSObject.Properties.Name -contains "servers" -and $config.mcp.servers -is [pscustomobject]) {
      foreach ($serverName in @("agentmemory", "markitdown")) {
        if (Remove-OpenClawJsonProperty -Node $config.mcp.servers -Name $serverName) {
          $changedKeys.Add("mcp.servers.$serverName")
        }
      }
    }
  }

  if ($changedKeys.Count -eq 0) {
    return
  }

  $backupPath = "{0}.gateway-startup-sanitize.{1}.bak" -f $ConfigPath, (Get-Date -Format "yyyyMMdd-HHmmss-fff")
  Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
  Save-OpenClawJsonUtf8NoBom -Path $ConfigPath -Payload $config
  Write-Host ("Sanitized OpenClaw gateway startup config: {0}" -f ($changedKeys -join ", "))
  Write-Host ("Backup written to {0}" -f $backupPath)
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$workspaceDir = Join-Path $rootDir "workspace"
$logDir = Join-Path $rootDir "logs"

$gatewayPort = if ($env:OPENCLAW_GATEWAY_PORT) { [int]$env:OPENCLAW_GATEWAY_PORT } else { 29644 }
$nodeExe = "C:\Program Files\nodejs\node.exe"
$openClawPackageRoot = "C:\Users\JackYang\AppData\Roaming\npm\node_modules\openclaw"
$gatewayCli = @(
  (Join-Path $openClawPackageRoot "dist\index.js"),
  (Join-Path $openClawPackageRoot "openclaw.mjs")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$ttsPython = "C:\Users\JackYang\Miniconda3\envs\qwen3-tts-fa2-test\python.exe"
$ttsScript = Join-Path $workspaceDir "tts_server.py"
$ttsStdoutLog = Join-Path $logDir "tts-server.stdout.log"
$ttsStderrLog = Join-Path $logDir "tts-server.stderr.log"
$ttsHealthUrl = "http://127.0.0.1:8000/health"

$sttPython = "C:\Users\JackYang\Miniconda3\envs\qwen3-asr\python.exe"
$sttScript = Join-Path $workspaceDir "stt_server.py"
$sttStdoutLog = Join-Path $logDir "stt-server.stdout.log"
$sttStderrLog = Join-Path $logDir "stt-server.stderr.log"
$sttHealthUrl = "http://127.0.0.1:8001/health"
$visionStartupScript = Join-Path $scriptDir "start-llama-cpp-vision.ps1"
$gatewayStdoutLog = Join-Path $logDir "gateway.stdout.log"
$gatewayStderrLog = Join-Path $logDir "gateway.stderr.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Repair-OpenClawSessionUtilsExport {
  param([Parameter(Mandatory = $true)][string]$GatewayCliPath)

  $entryDir = Split-Path -Parent $GatewayCliPath
  $distDir = if (Test-Path -LiteralPath (Join-Path $entryDir "dist")) { Join-Path $entryDir "dist" } else { $entryDir }
  if (-not (Test-Path -LiteralPath $distDir)) {
    return
  }

  $implementation = @'
function resolveDeletedAgentIdFromSessionKey(cfg, sessionKey) {
	const parsed = parseAgentSessionKey(sessionKey);
	if (!parsed?.agentId) return null;
	const agentId = normalizeAgentId(parsed.agentId);
	if (!agentId) return null;
	const configuredAgentIds = new Set(listAgentIds(cfg).map((id) => normalizeAgentId(id)).filter(Boolean));
	return configuredAgentIds.has(agentId) ? null : agentId;
}
'@

  Get-ChildItem -LiteralPath $distDir -Filter "session-utils-*.js" -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      $content = Get-Content -LiteralPath $_.FullName -Raw
      if ($content -notmatch 'resolveDeletedAgentIdFromSessionKey' -or
          $content -match 'function\s+resolveDeletedAgentIdFromSessionKey\s*\(') {
        return
      }

      if ($content -notmatch 'function\s+buildGatewaySessionStoreScanTargets\s*\(') {
        return
      }

      $updated = $content -replace 'function\s+buildGatewaySessionStoreScanTargets\s*\(', ($implementation + "`r`nfunction buildGatewaySessionStoreScanTargets(")
      if ($updated -ne $content) {
        Set-Content -LiteralPath $_.FullName -Value $updated -Encoding utf8
        Write-Host ("Applied OpenClaw session-utils export hotfix: {0}" -f $_.FullName)
      }
    }
}

function Repair-OpenClawGatewayDeferSidecarsEnv {
  param([Parameter(Mandatory = $true)][string]$GatewayCliPath)

  $entryDir = Split-Path -Parent $GatewayCliPath
  $distDir = if (Test-Path -LiteralPath (Join-Path $entryDir "dist")) { Join-Path $entryDir "dist" } else { $entryDir }
  if (-not (Test-Path -LiteralPath $distDir)) {
    return
  }

  Get-ChildItem -LiteralPath $distDir -Filter "server.impl-*.js" -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      $content = Get-Content -LiteralPath $_.FullName -Raw
      $new = "deferSidecars: opts.deferStartupSidecars === true || isTruthyEnvValue(process.env.OPENCLAW_DEFER_STARTUP_SIDECARS)"
      $updated = [regex]::Replace(
        $content,
        'deferSidecars:\s*opts\.deferStartupSidecars === true(?:\s*\|\|\s*isTruthyEnvValue\(process\.env\.OPENCLAW_DEFER_STARTUP_SIDECARS\))*',
        $new
      )
      if ($updated -ne $content) {
        Set-Content -LiteralPath $_.FullName -Value $updated -Encoding utf8
        Write-Host ("Applied OpenClaw deferred sidecars hotfix: {0}" -f $_.FullName)
      }
    }
}

function Repair-OpenClawGatewaySkipStartupModelPrewarmEnv {
  param([Parameter(Mandatory = $true)][string]$GatewayCliPath)

  $entryDir = Split-Path -Parent $GatewayCliPath
  $distDir = if (Test-Path -LiteralPath (Join-Path $entryDir "dist")) { Join-Path $entryDir "dist" } else { $entryDir }
  if (-not (Test-Path -LiteralPath $distDir)) {
    return
  }

  $old = @'
if (!skipChannels) try {
			await prewarmConfiguredPrimaryModel({
				cfg: params.cfg,
				log: params.log
			});
			await params.startChannels();
'@
  $new = @'
if (!skipChannels) try {
			if (!isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_MODEL_PREWARM)) await prewarmConfiguredPrimaryModel({
				cfg: params.cfg,
				log: params.log
			});
			else params.log.info("skipping startup model prewarm (OPENCLAW_SKIP_STARTUP_MODEL_PREWARM=1)");
			await params.startChannels();
'@

  Get-ChildItem -LiteralPath $distDir -Filter "server.impl-*.js" -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      $content = Get-Content -LiteralPath $_.FullName -Raw
      if ($content -match 'OPENCLAW_SKIP_STARTUP_MODEL_PREWARM') {
        return
      }

      $updated = $content.Replace($old, $new)
      if ($updated -ne $content) {
        Set-Content -LiteralPath $_.FullName -Value $updated -Encoding utf8
        Write-Host ("Applied OpenClaw startup model prewarm hotfix: {0}" -f $_.FullName)
      }
    }
}

function Repair-OpenClawTelegramDynamicImports {
  param(
    [Parameter(Mandatory = $true)][string]$GatewayCliPath,
    [string]$PluginStageDir = ""
  )

  $entryDir = Split-Path -Parent $GatewayCliPath
  $distDir = if (Test-Path -LiteralPath (Join-Path $entryDir "dist")) { Join-Path $entryDir "dist" } else { $entryDir }
  if (-not (Test-Path -LiteralPath $distDir)) {
    return
  }

  $roots = New-Object System.Collections.Generic.List[string]
  foreach ($relativeRoot in @("extensions\telegram", "telegram")) {
    $candidate = Join-Path $distDir $relativeRoot
    if (Test-Path -LiteralPath $candidate) {
      $roots.Add($candidate)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($PluginStageDir) -and (Test-Path -LiteralPath $PluginStageDir)) {
    Get-ChildItem -LiteralPath $PluginStageDir -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        foreach ($relativeRoot in @("dist\extensions\telegram", "dist\telegram")) {
          $candidate = Join-Path $_.FullName $relativeRoot
          if (Test-Path -LiteralPath $candidate) {
            $roots.Add($candidate)
          }
        }
      }
  }

  $uniqueRoots = @($roots | Select-Object -Unique)
  if ($uniqueRoots.Count -eq 0) {
    return
  }

  $patcher = @'
import fs from "node:fs";
import path from "node:path";

const roots = JSON.parse(process.env.OPENCLAW_TELEGRAM_PATCH_ROOTS || "[]");
const replacements = [
  [/import\("(\.{1,2}\/[^"]+?\.js)"\)/g, 'import(new URL("$1", import.meta.url).href)'],
  [/import\('(\.{1,2}\/[^']+?\.js)'\)/g, "import(new URL('$1', import.meta.url).href)"]
];

function listJavaScriptFiles(root) {
  const result = [];
  const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    let entries = [];
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (entry.isFile() && fullPath.endsWith(".js")) {
        result.push(fullPath);
      }
    }
  }
  return result;
}

let patchedFiles = 0;
for (const root of roots) {
  for (const filePath of listJavaScriptFiles(root)) {
    const original = fs.readFileSync(filePath, "utf8");
    let updated = original;
    for (const [pattern, replacement] of replacements) {
      updated = updated.replace(pattern, replacement);
    }
    if (updated !== original) {
      fs.writeFileSync(filePath, updated, "utf8");
      patchedFiles += 1;
    }
  }
}

console.log(String(patchedFiles));
'@

  $oldPatchRoots = $env:OPENCLAW_TELEGRAM_PATCH_ROOTS
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $env:OPENCLAW_TELEGRAM_PATCH_ROOTS = ($uniqueRoots | ConvertTo-Json -Compress)
    $ErrorActionPreference = "Continue"
    $output = $patcher | & $nodeExe --input-type=module 2>&1
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $ErrorActionPreference = $oldErrorActionPreference
    if ($exitCode -ne 0) {
      Write-Warning ("OpenClaw Telegram dynamic-import hotfix failed: " + (($output | Out-String).Trim()))
      return
    }

    $patchedFiles = 0
    if ($output) {
      [void][int]::TryParse((($output | Select-Object -Last 1) -as [string]).Trim(), [ref]$patchedFiles)
    }
    if ($patchedFiles -gt 0) {
      Write-Host ("Applied OpenClaw Telegram Windows dynamic-import hotfix to {0} file(s)." -f $patchedFiles)
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
    $env:OPENCLAW_TELEGRAM_PATCH_ROOTS = $oldPatchRoots
  }
}

function Repair-OpenClawPluginJitiNativeLoad {
  param([Parameter(Mandatory = $true)][string]$GatewayCliPath)

  $entryDir = Split-Path -Parent $GatewayCliPath
  $distDir = if (Test-Path -LiteralPath (Join-Path $entryDir "dist")) { Join-Path $entryDir "dist" } else { $entryDir }
  if (-not (Test-Path -LiteralPath $distDir)) {
    return
  }

  Get-ChildItem -LiteralPath $distDir -Filter "channel-entry-contract-*.js" -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      $content = Get-Content -LiteralPath $_.FullName -Raw
      if ($content -match 'tryNative:\s*false') {
        return
      }

      $updated = [regex]::Replace(
        $content,
        '(importerUrl:\s*import\.meta\.url,\s*preferBuiltDist:\s*true,\s*)jitiFilename:',
        '${1}tryNative: false, jitiFilename:',
        1
      )
      if ($updated -ne $content) {
        Set-Content -LiteralPath $_.FullName -Value $updated -Encoding utf8
        Write-Host ("Applied OpenClaw Windows jiti native-loader hotfix: {0}" -f $_.FullName)
      }
    }
}

# Keep the scheduled-task launch path and manual launches aligned by setting
# the same gateway process environment here instead of relying on gateway.cmd.
$env:TMPDIR = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { $env:TMPDIR }
$easyLlamacppRoot = if (-not [string]::IsNullOrWhiteSpace($env:EASY_LLAMACPP_ROOT)) { $env:EASY_LLAMACPP_ROOT } else { "F:\Documents\GitHub\easy_llamacpp" }
$env:EASY_LLAMACPP_ROOT = $easyLlamacppRoot
$env:OPENCLAW_PLUGIN_STAGE_DIR = Join-Path $easyLlamacppRoot ".openclaw-plugin-stage"
$env:OPENCLAW_STATE_DIR = $rootDir
$env:OPENCLAW_CONFIG_PATH = Join-Path $rootDir "openclaw.json"
$env:OPENCLAW_GATEWAY_PORT = "$gatewayPort"
$env:OPENCLAW_WINDOWS_TASK_NAME = "OpenClaw Gateway"
$env:OPENCLAW_SERVICE_MARKER = "openclaw"
$env:OPENCLAW_SERVICE_KIND = "gateway"
$env:OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS = "1"
$env:OPENCLAW_SKIP_PLUGIN_SERVICES = "1"
$env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = "1"
$env:OPENCLAW_GATEWAY_STARTUP_TRACE = "1"
$env:OPENCLAW_DEFER_STARTUP_SIDECARS = "1"
$env:OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS = "1"
$env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = "1"
$env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = "ipv4first"
$env:OPENCLAW_TELEGRAM_FORCE_IPV4 = "1"
New-Item -ItemType Directory -Force -Path $env:OPENCLAW_PLUGIN_STAGE_DIR | Out-Null

if (-not (Test-Path -LiteralPath $nodeExe)) {
  throw "Node.js was not found at $nodeExe"
}
if ([string]::IsNullOrWhiteSpace($gatewayCli) -or -not (Test-Path -LiteralPath $gatewayCli)) {
  throw "OpenClaw gateway entrypoint was not found under $openClawPackageRoot"
}
if (-not (Test-Path -LiteralPath $ttsPython)) {
  throw "TTS Python was not found at $ttsPython"
}
if (-not (Test-Path -LiteralPath $sttPython)) {
  throw "STT Python was not found at $sttPython"
}
if (-not (Test-Path -LiteralPath $ttsScript)) {
  throw "TTS server script was not found at $ttsScript"
}
if (-not (Test-Path -LiteralPath $sttScript)) {
  throw "STT server script was not found at $sttScript"
}
if (-not (Test-Path -LiteralPath $visionStartupScript)) {
  throw "Vision startup script was not found at $visionStartupScript"
}

Repair-OpenClawSessionUtilsExport -GatewayCliPath $gatewayCli
Repair-OpenClawGatewayDeferSidecarsEnv -GatewayCliPath $gatewayCli
Repair-OpenClawGatewaySkipStartupModelPrewarmEnv -GatewayCliPath $gatewayCli
Repair-OpenClawPluginJitiNativeLoad -GatewayCliPath $gatewayCli
Repair-OpenClawTelegramDynamicImports -GatewayCliPath $gatewayCli -PluginStageDir $env:OPENCLAW_PLUGIN_STAGE_DIR
Disable-OpenClawHeavyGatewayStartupConfig -ConfigPath $env:OPENCLAW_CONFIG_PATH

$managedProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$launcherParentId = 0
$gatewayExitCode = 1
$gatewayRapidFailureCount = 0

try {
  Write-Step "Stopping stale TTS/STT processes"
  Stop-MediaProcesses

  Write-Step "Starting TTS and STT sidecars"
  $ttsEnv = @{ PYTHONIOENCODING = "utf-8" }
  $ttsProcess = Start-ManagedProcess `
    -Name "TTS" `
    -FilePath $ttsPython `
    -Arguments @("-u", $ttsScript) `
    -WorkingDirectory $workspaceDir `
    -StdoutLog $ttsStdoutLog `
    -StderrLog $ttsStderrLog `
    -Environment $ttsEnv
  $managedProcesses.Add($ttsProcess)

  $sttEnv = @{ PYTHONIOENCODING = "utf-8" }
  $sttProcess = Start-ManagedProcess `
    -Name "STT" `
    -FilePath $sttPython `
    -Arguments @("-u", $sttScript) `
    -WorkingDirectory $workspaceDir `
    -StdoutLog $sttStdoutLog `
    -StderrLog $sttStderrLog `
    -Environment $sttEnv
  $managedProcesses.Add($sttProcess)

  Write-Step "Waiting for TTS/STT health"
  Wait-ManagedService `
    -Name "TTS" `
    -Process $ttsProcess `
    -HealthUrl $ttsHealthUrl `
    -StdoutLog $ttsStdoutLog `
    -StderrLog $ttsStderrLog `
    -LauncherParentId $launcherParentId `
    -ReadyTimeoutSeconds 360
  Wait-ManagedService `
    -Name "STT" `
    -Process $sttProcess `
    -HealthUrl $sttHealthUrl `
    -StdoutLog $sttStdoutLog `
    -StderrLog $sttStderrLog `
    -LauncherParentId $launcherParentId `
    -ReadyTimeoutSeconds 360

  Write-Step "Ensuring llama.cpp vision sidecar"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $visionStartupScript
  if ($LASTEXITCODE -ne 0) {
    throw "Vision sidecar failed to start."
  }

  while ($true) {
    Write-Step "Starting OpenClaw gateway"
    $gatewayStartedAt = Get-Date
    $gatewayProcess = Start-Process `
      -FilePath $nodeExe `
      -ArgumentList @($gatewayCli, "gateway", "run", "--port", "$gatewayPort") `
      -WorkingDirectory $rootDir `
      -RedirectStandardOutput $gatewayStdoutLog `
      -RedirectStandardError $gatewayStderrLog `
      -WindowStyle Hidden `
      -PassThru
    $managedProcesses.Add($gatewayProcess)

    $gatewayExitCode = Wait-GatewayExit `
      -GatewayProcess $gatewayProcess `
      -LauncherParentId $launcherParentId
    [void]$managedProcesses.Remove($gatewayProcess)

    $gatewayLifetimeSeconds = ((Get-Date) - $gatewayStartedAt).TotalSeconds
    if ($gatewayLifetimeSeconds -lt 30) {
      $gatewayRapidFailureCount += 1
    } else {
      $gatewayRapidFailureCount = 0
    }

    if ($gatewayRapidFailureCount -ge 3) {
      $stderrTail = if (Test-Path -LiteralPath $gatewayStderrLog) {
        (Get-Content -LiteralPath $gatewayStderrLog -Tail 40 | Out-String).Trim()
      } else {
        ""
      }
      throw "OpenClaw gateway crashed quickly $gatewayRapidFailureCount times. Last exit code: $gatewayExitCode. Stderr tail: $stderrTail"
    }

    Write-Warning "OpenClaw gateway exited with code $gatewayExitCode; restarting in 10 seconds."
    Start-Sleep -Seconds 10
  }
} finally {
  Write-Step "Stopping managed TTS/STT processes"
  foreach ($process in $managedProcesses) {
    try {
      $process.Refresh()
      if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
      }
    } catch {
    }
  }

  Stop-MediaProcesses
}

exit $gatewayExitCode
