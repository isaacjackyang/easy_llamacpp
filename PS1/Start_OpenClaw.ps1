[CmdletBinding()]
param(
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$openClawSupportPath = Join-Path $PSScriptRoot "OpenClawSupport.ps1"
$syncScriptPath = Join-Path $PSScriptRoot "Update_OpenClaw_Status.ps1"
$llamaModelsUrl = "http://127.0.0.1:8080/v1/models"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$openClawConfigPath = Join-Path $openClawRoot "openclaw.json"
$openClawStopMarker = Join-Path $openClawRoot "openclaw.stop"
$openClawStartPath = Join-Path $openClawRoot "start.cmd"
$openClawRestartPath = Join-Path $openClawRoot "scripts\restart-openclaw-gateway.ps1"
$openClawWatchdogStartPath = Join-Path $PSScriptRoot "Start_OpenClaw_Watchdog.ps1"
$gatewayScriptPath = Join-Path $openClawRoot "gateway.cmd"
$nodeScriptPath = Join-Path $openClawRoot "node.cmd"
$gatewayStdoutLog = Join-Path $openClawRoot "logs\gateway.stdout.log"
$managedGatewayScriptName = "run-openclaw-gateway-with-media.ps1"
$managedTtsHealthPort = 8000
$managedSttHealthPort = 8001
$managedVisionHealthUrl = "http://127.0.0.1:8081/v1/models"
$defaultGatewayReadyTimeoutSeconds = 60
$managedMediaGatewayReadyTimeoutSeconds = 480

if (Test-Path -LiteralPath $openClawSupportPath) {
  . $openClawSupportPath
}

function Write-Info {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "[INFO] $Message"
}

function Write-Ok {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "[ OK ] $Message"
}

function Write-Warn {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-SafeBackupSuffix {
  param([Parameter(Mandatory = $true)][string]$Text)

  return ([regex]::Replace($Text, '[^A-Za-z0-9._-]+', '-')).Trim('-')
}

function Backup-File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Suffix
  )

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
  $safeSuffix = Get-SafeBackupSuffix -Text $Suffix
  $backupPath = "$Path.$safeSuffix.$stamp.bak"
  Copy-Item -LiteralPath $Path -Destination $backupPath -Force
  return $backupPath
}

function Save-JsonUtf8 {
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

function Remove-JsonNoteProperty {
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

function Remove-DeprecatedOpenClawConfigKeys {
  param([Parameter(Mandatory = $true)][object]$Config)

  $removedKeys = New-Object System.Collections.Generic.List[string]

  if ($Config.PSObject.Properties.Name -contains "models" -and $Config.models -is [pscustomobject]) {
    if (Remove-JsonNoteProperty -Node $Config.models -Name "bedrockDiscovery") {
      $removedKeys.Add("models.bedrockDiscovery")
    }
  }

  if (Get-Command Remove-OpenClawLegacyGraphitiPluginConfig -ErrorAction SilentlyContinue) {
    foreach ($removedKey in @(Remove-OpenClawLegacyGraphitiPluginConfig -Config $Config)) {
      $removedKeys.Add($removedKey)
    }
  }

  return @($removedKeys)
}

function Disable-OpenClawHeavyStartupPlugins {
  param([Parameter(Mandatory = $true)][object]$Config)

  $changedKeys = New-Object System.Collections.Generic.List[string]
  $heavyPlugins = @("agentmemory", "browser", "openclaw-web-search", "voice-call")

  if ($Config.PSObject.Properties.Name -contains "browser" -and $Config.browser -is [pscustomobject]) {
    if ($Config.browser.PSObject.Properties.Name -contains "enabled" -and $Config.browser.enabled -ne $false) {
      $Config.browser.enabled = $false
      $changedKeys.Add("browser.enabled")
    }
  }

  if ($Config.PSObject.Properties.Name -contains "hooks" -and
      $Config.hooks -is [pscustomobject] -and
      $Config.hooks.PSObject.Properties.Name -contains "internal" -and
      $Config.hooks.internal -is [pscustomobject] -and
      $Config.hooks.internal.PSObject.Properties.Name -contains "enabled" -and
      $Config.hooks.internal.enabled -ne $false) {
    $Config.hooks.internal.enabled = $false
    $changedKeys.Add("hooks.internal.enabled")
  }

  if (-not ($Config.PSObject.Properties.Name -contains "plugins") -or -not ($Config.plugins -is [pscustomobject])) {
    return @($changedKeys)
  }

  if ($Config.plugins.PSObject.Properties.Name -contains "allow") {
    $allowedPlugins = @($Config.plugins.allow | ForEach-Object { [string]$_ })
    $updatedAllowedPlugins = @($allowedPlugins | Where-Object { $heavyPlugins -notcontains $_ })
    if ($updatedAllowedPlugins.Count -ne $allowedPlugins.Count) {
      $Config.plugins.allow = @($updatedAllowedPlugins)
      $changedKeys.Add("plugins.allow")
    }
  }

  if ($Config.plugins.PSObject.Properties.Name -contains "load" -and
      $Config.plugins.load -is [pscustomobject] -and
      $Config.plugins.load.PSObject.Properties.Name -contains "paths") {
    $loadPaths = @($Config.plugins.load.paths | ForEach-Object { [string]$_ })
    $updatedLoadPaths = @($loadPaths | Where-Object { $_ -notmatch '(?i)agentmemory|openclaw-web-search|voice-call|browser' })
    if ($updatedLoadPaths.Count -ne $loadPaths.Count) {
      $Config.plugins.load.paths = @($updatedLoadPaths)
      $changedKeys.Add("plugins.load.paths")
    }
  }

  if ($Config.plugins.PSObject.Properties.Name -contains "entries" -and $Config.plugins.entries -is [pscustomobject]) {
    foreach ($pluginName in $heavyPlugins) {
      if (-not ($Config.plugins.entries.PSObject.Properties.Name -contains $pluginName)) {
        continue
      }

      if (Remove-JsonNoteProperty -Node $Config.plugins.entries -Name $pluginName) {
        $changedKeys.Add("plugins.entries.$pluginName")
      }
    }

    if (@($Config.plugins.entries.PSObject.Properties).Count -eq 0) {
      if (Remove-JsonNoteProperty -Node $Config.plugins -Name "entries") {
        $changedKeys.Add("plugins.entries")
      }
    }
  }

  if ($Config.PSObject.Properties.Name -contains "mcp" -and $Config.mcp -is [pscustomobject]) {
    $mcpPropertyNames = @($Config.mcp.PSObject.Properties | ForEach-Object { $_.Name })
    if ($mcpPropertyNames -contains "servers" -and $Config.mcp.servers -is [pscustomobject]) {
      foreach ($serverName in @("agentmemory", "markitdown")) {
        if (Remove-JsonNoteProperty -Node $Config.mcp.servers -Name $serverName) {
          $changedKeys.Add("mcp.servers.$serverName")
        }
      }

      if (@($Config.mcp.servers.PSObject.Properties).Count -eq 0) {
        if (Remove-JsonNoteProperty -Node $Config.mcp -Name "servers") {
          $changedKeys.Add("mcp.servers")
        }
      }
    }

    if (@($Config.mcp.PSObject.Properties).Count -eq 0) {
      if (Remove-JsonNoteProperty -Node $Config -Name "mcp") {
        $changedKeys.Add("mcp")
      }
    }
  }

  return @($changedKeys)
}

function Ensure-ManagedOpenClawStartupAssets {
  if (-not (Get-Command Sync-OpenClawManagedStartupAssets -ErrorAction SilentlyContinue)) {
    return
  }

  $syncResults = @(Sync-OpenClawManagedStartupAssets `
    -ProjectRoot $projectRoot `
    -OpenClawRoot $openClawRoot `
    -OpenClawConfigPath $openClawConfigPath `
    -GatewayPort 29644 `
    -EasyLlamacppRoot $projectRoot)

  foreach ($syncResult in $syncResults) {
    if ($null -eq $syncResult) {
      continue
    }

    switch ($syncResult.Status) {
      "template-missing" {
        Write-Warn "Skipping $($syncResult.Description) because the template was not found: $($syncResult.SourcePath)"
      }
      "created" {
        Write-Info "Created $($syncResult.Description): $($syncResult.Path)"
      }
      "updated" {
        Write-Info "Updated $($syncResult.Description): $($syncResult.Path)"
        if (-not [string]::IsNullOrWhiteSpace([string]$syncResult.BackupPath)) {
          Write-Info "Backup written to $($syncResult.BackupPath)"
        }
      }
    }
  }
}

function Repair-OpenClawConfigIfNeeded {
  if (-not (Test-Path -LiteralPath $openClawConfigPath)) {
    return
  }

  $config = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
  [object[]]$removedKeys = @(Remove-DeprecatedOpenClawConfigKeys -Config $config)
  [object[]]$disabledPluginKeys = @(Disable-OpenClawHeavyStartupPlugins -Config $config)
  [object[]]$telegramEnabledKeys = @(
    if (Get-Command Ensure-OpenClawTelegramEnabledConfig -ErrorAction SilentlyContinue) {
      Ensure-OpenClawTelegramEnabledConfig -Config $config
    }
  )
  [object[]]$networkKeys = @(
    if (Get-Command Ensure-OpenClawTelegramNetworkConfig -ErrorAction SilentlyContinue) {
      Ensure-OpenClawTelegramNetworkConfig -Config $config
    }
  )

  if ($removedKeys.Count -eq 0 -and $disabledPluginKeys.Count -eq 0 -and $telegramEnabledKeys.Count -eq 0 -and $networkKeys.Count -eq 0) {
    return
  }

  $configBackup = Backup-File -Path $openClawConfigPath -Suffix "deprecated-config-cleanup"
  Save-JsonUtf8 -Path $openClawConfigPath -Payload $config
  if ($removedKeys.Count -gt 0) {
    Write-Warn "Removed deprecated OpenClaw config keys: $($removedKeys -join ', ')"
  }
  if ($disabledPluginKeys.Count -gt 0) {
    Write-Warn "Disabled heavy OpenClaw startup plugins: $($disabledPluginKeys -join ', ')"
  }
  if ($telegramEnabledKeys.Count -gt 0) {
    Write-Warn "Enabled Telegram config: $($telegramEnabledKeys -join ', ')"
  }
  if ($networkKeys.Count -gt 0) {
    Write-Warn "Updated Telegram network config: $($networkKeys -join ', ')"
  }
  Write-Info "Backup written to $configBackup"
}

function Get-OpenClawCommandPath {
  $candidate = Get-Command openclaw.cmd -ErrorAction SilentlyContinue
  if (-not $candidate) {
    $candidate = Get-Command openclaw -ErrorAction SilentlyContinue
  }

  if (-not $candidate) {
    throw "Cannot find the openclaw command in PATH."
  }

  return $candidate.Source
}

function Test-LlamaServerAvailable {
  param([Parameter(Mandatory = $true)][string]$ModelsUrl)

  try {
    $response = Invoke-RestMethod -Uri $ModelsUrl -TimeoutSec 5
  } catch {
    return $false
  }

  if ($null -ne $response.data -and @($response.data).Count -gt 0) {
    return $true
  }

  if ($null -ne $response.models -and @($response.models).Count -gt 0) {
    return $true
  }

  return $false
}

function Get-RunningLlamaModelId {
  param([Parameter(Mandatory = $true)][string]$ModelsUrl)

  try {
    $response = Invoke-RestMethod -Uri $ModelsUrl -TimeoutSec 5
  } catch {
    return $null
  }

  if ($null -ne $response.data -and @($response.data).Count -gt 0) {
    return [string](@($response.data)[0].id)
  }

  if ($null -ne $response.models -and @($response.models).Count -gt 0) {
    $firstModel = @($response.models)[0]
    if ($firstModel.PSObject.Properties.Name -contains "model") {
      return [string]$firstModel.model
    }

    return [string]$firstModel.name
  }

  return $null
}

function Test-TcpPort {
  param(
    [Parameter(Mandatory = $true)][string]$TargetHost,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutMs = 1000
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $connect = $client.BeginConnect($TargetHost, $Port, $null, $null)
    if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      return $false
    }

    $client.EndConnect($connect)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Wait-TcpPort {
  param(
    [Parameter(Mandatory = $true)][string]$TargetHost,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutSeconds = 30,
    [int]$ProbeIntervalSeconds = 1
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-TcpPort -TargetHost $TargetHost -Port $Port) {
      return $true
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  return $false
}

function Test-HttpReady {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSec = 5
  )

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
    return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
  } catch {
    return $false
  }
}

function Wait-HttpReady {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSeconds = 60,
    [int]$ProbeIntervalSeconds = 2
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-HttpReady -Url $Url) {
      Write-Ok "$Name is ready at $Url"
      return
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  throw "$Name did not become ready at $Url"
}

function Test-GatewayReadyLog {
  if (-not (Test-Path -LiteralPath $gatewayStdoutLog)) {
    return $false
  }

  try {
    return [bool](Select-String -LiteralPath $gatewayStdoutLog -Pattern '\[gateway\]\s+ready\b' -Quiet)
  } catch {
    return $false
  }
}

function Wait-OpenClawGatewayReady {
  param(
    [int]$TimeoutSeconds = 60,
    [int]$ProbeIntervalSeconds = 2
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-HttpReady -Url "http://127.0.0.1:29644/health" -TimeoutSec 5) {
      return $true
    }

    if (Test-OpenClawGatewayHttp -Url "http://127.0.0.1:29644/" -TimeoutSec 5) {
      return $true
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  return $false
}

function Test-OpenClawGatewayProbe {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath,
    [int]$TimeoutSeconds = 45
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $probeResult = Invoke-Capture -FilePath $OpenClawCommandPath -Arguments @("gateway", "probe")
      if ($probeResult.ExitCode -eq 0 -and $probeResult.Output -match 'Reachable:\s+yes') {
        return $true
      }
    }
    catch {
    }

    Start-Sleep -Seconds 3
  }

  return $false
}

function Test-OpenClawGatewayHttp {
  param(
    [string]$Url = "http://127.0.0.1:29644/",
    [int]$TimeoutSec = 5
  )

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
    return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
  } catch {
    return $false
  }
}

function Test-OpenClawGatewayWebSocket {
  param(
    [string]$Url = "ws://127.0.0.1:29644/",
    [int]$TimeoutMs = 5000
  )

  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $nodeCommand) {
    return $false
  }

  $script = @'
const url = process.argv[1];
const timeoutMs = Number(process.argv[2] || 5000);

if (typeof WebSocket !== "function") {
  process.exit(3);
}

let done = false;
let timer = null;
let socket = null;

function finish(code) {
  if (done) {
    return;
  }
  done = true;
  if (timer) {
    clearTimeout(timer);
  }
  try {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.close(1000, "readiness-ok");
    }
  } catch {
  }
  setTimeout(() => process.exit(code), 25);
}

try {
  socket = new WebSocket(url);
  timer = setTimeout(() => finish(2), timeoutMs);
  socket.addEventListener("open", () => finish(0));
  socket.addEventListener("error", () => finish(1));
} catch {
  finish(4);
}
'@

  try {
    & $nodeCommand.Source "-e" $script $Url ([string]$TimeoutMs) *> $null
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    return ($exitCode -eq 0)
  } catch {
    return $false
  }
}

function Test-OpenClawGatewayReachable {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath,
    [int]$TimeoutSeconds = 45
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

  while ((Get-Date) -lt $deadline) {
    if (Test-OpenClawGatewayHttp) {
      return $true
    }

    Start-Sleep -Seconds 5
  }

  return $false
}

function Test-OpenClawGatewayUsesManagedMedia {
  if (-not (Test-Path -LiteralPath $gatewayScriptPath)) {
    return $false
  }

  $managedGatewayScriptPath = Join-Path $openClawRoot "scripts\$managedGatewayScriptName"
  if (-not (Test-Path -LiteralPath $managedGatewayScriptPath)) {
    return $false
  }

  try {
    $gatewayText = Get-Content -LiteralPath $gatewayScriptPath -Raw -ErrorAction Stop
  } catch {
    return $false
  }

  return (
    ($gatewayText -match [regex]::Escape($managedGatewayScriptName)) -or
    ($gatewayText -match 'start-openclaw-gateway-hidden\.vbs') -or
    ($gatewayText -match 'OPENCLAW_GATEWAY_LAUNCHER')
  )
}

function Get-OpenClawManagedMediaProcesses {
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $commandLine = $_.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
          return $false
        }

        ($commandLine -match 'workspace[\\/]+tts_server\.py') -or
        ($commandLine -match 'workspace[\\/]+stt_server\.py')
      }
  )
}

function Get-OpenClawManagedMediaStatusText {
  if (-not (Test-OpenClawGatewayUsesManagedMedia)) {
    return "not configured"
  }

  $mediaProcesses = @(Get-OpenClawManagedMediaProcesses)
  $ttsProcessDetected = @($mediaProcesses | Where-Object { $_.CommandLine -match 'workspace[\\/]+tts_server\.py' }).Count -gt 0
  $sttProcessDetected = @($mediaProcesses | Where-Object { $_.CommandLine -match 'workspace[\\/]+stt_server\.py' }).Count -gt 0
  $ttsHealthy = Test-HttpReady -Url "http://127.0.0.1:$managedTtsHealthPort/health"
  $sttHealthy = Test-HttpReady -Url "http://127.0.0.1:$managedSttHealthPort/health"
  $visionHealthy = Test-HttpReady -Url $managedVisionHealthUrl

  $ttsStatus = if ($ttsHealthy) {
    "TTS ready on 127.0.0.1:$managedTtsHealthPort"
  } elseif ($ttsProcessDetected) {
    "TTS process detected"
  } else {
    "TTS not detected"
  }

  $sttStatus = if ($sttHealthy) {
    "STT ready on 127.0.0.1:$managedSttHealthPort"
  } elseif ($sttProcessDetected) {
    "STT process detected"
  } else {
    "STT not detected"
  }

  $visionStatus = if ($visionHealthy) {
    "Vision ready on 127.0.0.1:8081"
  } else {
    "Vision not ready"
  }

  return "$ttsStatus; $sttStatus; $visionStatus"
}

function Get-OpenClawGatewayReadyTimeoutSeconds {
  if (Test-OpenClawGatewayUsesManagedMedia) {
    return $managedMediaGatewayReadyTimeoutSeconds
  }

  return $defaultGatewayReadyTimeoutSeconds
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @()
  )

  & $FilePath @Arguments
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  if ($exitCode -ne 0) {
    throw "Command failed with exit code ${exitCode}: $FilePath $($Arguments -join ' ')"
  }
}

function Invoke-ManagedOpenClawRestartScript {
  param([string]$Reason = "start")

  if (-not (Test-Path -LiteralPath $openClawRestartPath)) {
    throw "Cannot find managed restart script: $openClawRestartPath"
  }

  $logDir = Join-Path $openClawRoot "logs"
  if (-not (Test-Path -LiteralPath $logDir)) {
    [void](New-Item -ItemType Directory -Path $logDir -Force)
  }

  $stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
  $safeReason = ([regex]::Replace($Reason, '[^A-Za-z0-9._-]+', '-')).Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeReason)) {
    $safeReason = "start"
  }

  $stdoutPath = Join-Path $logDir ("start-openclaw-restart.{0}.{1}.stdout.log" -f $safeReason, $stamp)
  $stderrPath = Join-Path $logDir ("start-openclaw-restart.{0}.{1}.stderr.log" -f $safeReason, $stamp)
  $arguments = @(
    "-NoLogo",
    "-NoProfile",
    "-WindowStyle", "Hidden",
    "-ExecutionPolicy", "Bypass",
    "-File", $openClawRestartPath
  )

  $process = Start-Process `
    -FilePath $powershellExe `
    -ArgumentList $arguments `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

  Write-Info "Managed OpenClaw restart launched with PID $($process.Id); verifying runtime health next."
  Write-Info "Restart logs: $stdoutPath ; $stderrPath"
  return $true
}

function Clear-OpenClawStopMarker {
  if (Test-Path -LiteralPath $openClawStopMarker) {
    Remove-Item -LiteralPath $openClawStopMarker -Force
    Write-Info "Removed openclaw.stop so watchdog and hidden launchers can recover the stack."
  }
}

function Enable-OpenClawWatchdog {
  param([switch]$NoRun)

  if (-not (Test-Path -LiteralPath $openClawWatchdogStartPath)) {
    Write-Warn "Cannot find watchdog start script: $openClawWatchdogStartPath"
    return
  }

  $arguments = @(
    "-NoLogo",
    "-NoProfile",
    "-WindowStyle", "Hidden",
    "-ExecutionPolicy", "Bypass",
    "-File", $openClawWatchdogStartPath,
    "-NoPause"
  )
  if ($NoRun) {
    $arguments += "-NoRun"
  }

  try {
    Invoke-Checked -FilePath $powershellExe -Arguments $arguments
  } catch {
    Write-Warn "Could not enable OpenClaw Watchdog: $($_.Exception.Message)"
  }
}

function Invoke-Capture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @()
  )

  $output = & $FilePath @Arguments 2>&1
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output   = ((@($output) | ForEach-Object { [string]$_.ToString().TrimEnd() }) -join [Environment]::NewLine).Trim()
  }
}

function Invoke-CaptureIsolatedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 1200
  )

  $stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
  $stdoutPath = Join-Path $env:TEMP ("openclaw-start-$stamp.stdout.log")
  $stderrPath = Join-Path $env:TEMP ("openclaw-start-$stamp.stderr.log")
  $process = $null

  try {
    $process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $Arguments `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      Stop-ProcessTree -ProcessId $process.Id
      return [pscustomobject]@{
        ExitCode = 124
        Output = "Command timed out after ${TimeoutSeconds}s: $FilePath $($Arguments -join ' ')"
      }
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
    $text = ((@($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()

    return [pscustomobject]@{
      ExitCode = [int]$process.ExitCode
      Output = $text
    }
  } finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-ObjectPropertyValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  if ($Object.PSObject.Properties.Name -contains $Name) {
    return $Object.$Name
  }

  return $null
}

function Stop-ProcessTree {
  param([Parameter(Mandatory = $true)][int]$ProcessId)

  $children = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.ParentProcessId -eq $ProcessId }
  )

  foreach ($child in $children) {
    Stop-ProcessTree -ProcessId ([int]$child.ProcessId)
  }

  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    $process.WaitForExit(3000) | Out-Null
  } catch {
  }
}

function Stop-StaleTelegramStatusProbes {
  param([int]$MinimumAgeSeconds = 60)

  $now = Get-Date
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match 'channels\s+status' -and
      $_.CommandLine -match '--channel\s+telegram'
    } |
    ForEach-Object {
      $ageSeconds = 999999
      try {
        $createdAt = [System.Management.ManagementDateTimeConverter]::ToDateTime($_.CreationDate)
        $ageSeconds = ($now - $createdAt).TotalSeconds
      } catch {
      }

      if ($ageSeconds -ge $MinimumAgeSeconds) {
        Stop-ProcessTree -ProcessId ([int]$_.ProcessId)
      }
    }
}

function Invoke-OpenClawTelegramStatusJson {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath,
    [int]$TimeoutSeconds = 45
  )

  $stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMddHHmmssfff"), ([guid]::NewGuid().ToString("N"))
  $stdoutPath = Join-Path $env:TEMP ("openclaw-telegram-status-$stamp.stdout.log")
  $stderrPath = Join-Path $env:TEMP ("openclaw-telegram-status-$stamp.stderr.log")
  $openClawNpmRoot = Split-Path -Parent $OpenClawCommandPath
  $openClawEntry = Join-Path $openClawNpmRoot "node_modules\openclaw\openclaw.mjs"
  $telegramProbeScript = Join-Path $openClawRoot "scripts\probe-openclaw-telegram-status.mjs"
  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  $statusFilePath = $OpenClawCommandPath
  $statusArguments = @("channels", "status", "--channel", "telegram", "--json")
  if ($nodeCommand -and (Test-Path -LiteralPath $telegramProbeScript)) {
    $statusFilePath = $nodeCommand.Source
    $statusArguments = @($telegramProbeScript, "--timeout-ms", "30000")
  } elseif ($nodeCommand -and (Test-Path -LiteralPath $openClawEntry)) {
    $statusFilePath = $nodeCommand.Source
    $statusArguments = @($openClawEntry, "channels", "status", "--channel", "telegram", "--json")
  }
  $process = $null

  try {
    Stop-StaleTelegramStatusProbes -MinimumAgeSeconds 60
    $process = Start-Process `
      -FilePath $statusFilePath `
      -ArgumentList $statusArguments `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -WindowStyle Hidden `
      -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      Stop-ProcessTree -ProcessId $process.Id
      Stop-StaleTelegramStatusProbes -MinimumAgeSeconds 0
      return [pscustomobject]@{
        ExitCode = 124
        Output = ""
        Error = "openclaw telegram status probe timed out after ${TimeoutSeconds}s"
      }
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
    return [pscustomobject]@{
      ExitCode = [int]$process.ExitCode
      Output = $stdout.Trim()
      Error = $stderr.Trim()
    }
  } finally {
    Stop-StaleTelegramStatusProbes -MinimumAgeSeconds 60
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Test-OpenClawTelegramReady {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath,
    [ref]$Detail
  )

  $oldDisableAutoSelectFamily = $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY
  $oldDnsResultOrder = $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER
  $oldForceIpv4 = $env:OPENCLAW_TELEGRAM_FORCE_IPV4

  try {
    $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = "1"
    $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = "ipv4first"
    $env:OPENCLAW_TELEGRAM_FORCE_IPV4 = "1"

    $result = Invoke-OpenClawTelegramStatusJson -OpenClawCommandPath $OpenClawCommandPath -TimeoutSeconds 45
    $text = [string]$result.Output
    if ([int]$result.ExitCode -ne 0) {
      $Detail.Value = "openclaw channels status exited with code $($result.ExitCode)"
      if (-not [string]::IsNullOrWhiteSpace($result.Error)) {
        $Detail.Value += ": $($result.Error)"
      }
      return $false
    }

    $jsonStart = $text.IndexOf("{")
    $jsonEnd = $text.LastIndexOf("}")
    if ($jsonStart -lt 0 -or $jsonEnd -lt $jsonStart) {
      $Detail.Value = "Telegram status output did not contain JSON."
      return $false
    }

    $status = $text.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json
    $channelAccounts = Get-ObjectPropertyValue -Object $status -Name "channelAccounts"
    $telegramAccounts = Get-ObjectPropertyValue -Object $channelAccounts -Name "telegram"
    $enabledConfigured = @(
      @($telegramAccounts) |
        Where-Object {
          $null -ne $_ -and
          (Get-ObjectPropertyValue -Object $_ -Name "enabled") -eq $true -and
          (Get-ObjectPropertyValue -Object $_ -Name "configured") -eq $true
        }
    )

    if ($enabledConfigured.Count -eq 0) {
      $Detail.Value = "Telegram has no enabled configured accounts."
      return $false
    }

    $notReady = New-Object System.Collections.Generic.List[string]
    foreach ($account in $enabledConfigured) {
      $accountId = [string](Get-ObjectPropertyValue -Object $account -Name "accountId")
      if ([string]::IsNullOrWhiteSpace($accountId)) {
        $accountId = "unknown"
      }

      $running = (Get-ObjectPropertyValue -Object $account -Name "running") -eq $true
      $connected = (Get-ObjectPropertyValue -Object $account -Name "connected") -eq $true
      $probe = Get-ObjectPropertyValue -Object $account -Name "probe"
      $probeOk = $null -eq $probe -or (Get-ObjectPropertyValue -Object $probe -Name "ok") -eq $true
      if (-not ($running -and $connected -and $probeOk)) {
        $notReady.Add(("{0}(running={1}, connected={2}, probe={3})" -f $accountId, $running, $connected, $probeOk))
      }
    }

    if ($notReady.Count -eq 0) {
      $Detail.Value = "Telegram accounts ready: " + (($enabledConfigured | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "accountId") }) -join ", ")
      return $true
    }

    $Detail.Value = "Telegram accounts not ready: " + ($notReady -join "; ")
    return $false
  } catch {
    $Detail.Value = $_.Exception.Message
    return $false
  } finally {
    $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = $oldDisableAutoSelectFamily
    $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = $oldDnsResultOrder
    $env:OPENCLAW_TELEGRAM_FORCE_IPV4 = $oldForceIpv4
  }
}

function Wait-OpenClawTelegramReady {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath,
    [int]$TimeoutSeconds = 300,
    [int]$ProbeIntervalSeconds = 5
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $detail = ""
  while ((Get-Date) -lt $deadline) {
    if (Test-OpenClawTelegramReady -OpenClawCommandPath $OpenClawCommandPath -Detail ([ref]$detail)) {
      Write-Ok $detail
      return
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  throw "Telegram did not become ready. Last status: $detail"
}

function Invoke-OpenClawRestart {
  param([Parameter(Mandatory = $true)][string]$OpenClawCommandPath)

  Write-Info "Stopping any existing OpenClaw gateway/node processes"
  Stop-OpenClawRuntime

  if (Test-OpenClawGatewayUsesManagedMedia) {
    Write-Info "OpenClaw gateway manages Vision/TTS/STT sidecars, so they will be restarted together."
  }

  if (Test-Path -LiteralPath $openClawRestartPath) {
    Write-Info "Restarting OpenClaw stack with managed restart script"
    [void](Invoke-ManagedOpenClawRestartScript -Reason "manual")
    return
  }

  if (Test-Path -LiteralPath $openClawStartPath) {
    Write-Info "Restarting OpenClaw stack with .openclaw\\start.cmd"
    Invoke-Checked -FilePath $openClawStartPath
    return
  }

  Write-Info "Restarting OpenClaw gateway"
  Start-BackgroundCmd -ScriptPath $gatewayScriptPath
  Start-Sleep -Seconds 2

  Write-Info "Restarting OpenClaw node"
  Start-BackgroundCmd -ScriptPath $nodeScriptPath
  Write-Ok "OpenClaw gateway and node restarted"
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
        ($_.Name -eq "node.exe" -and $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+dist[\\/]+index\.js' -and $_.CommandLine -match '\bnode\s+run\b')
      }
  )
}

function Get-OpenClawNodeStartupProcesses {
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        ($_.Name -like "powershell*.exe" -and $_.CommandLine -match 'start-openclaw-node\.ps1') -or
        ($_.Name -eq "cmd.exe" -and $_.CommandLine -match 'node\.cmd')
      }
  )
}

function Get-OpenClawAgentMemoryProcesses {
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and (
          $_.CommandLine -match '\.openclaw[\\/]+agentmemory\.cmd' -or
          $_.CommandLine -match '\.openclaw[\\/]+tools[\\/]+agentmemory' -or
          $_.CommandLine -match '\.openclaw[\\/]+tools[\\/]+markitdown' -or
          $_.CommandLine -match '\bmarkitdown_mcp\b'
        )
      }
  )
}

function Stop-OpenClawRuntime {
  foreach ($taskName in @("OpenClaw Gateway", "OpenClaw Node")) {
    & schtasks.exe /End /TN $taskName *> $null
  }

  $processesToStop = @(
    @(Get-OpenClawGatewayHostProcesses) +
    @(Get-OpenClawNodeHostProcesses) +
    @(Get-OpenClawNodeStartupProcesses) +
    @(Get-OpenClawManagedMediaProcesses) +
    @(Get-OpenClawAgentMemoryProcesses)
  ) | Sort-Object ProcessId -Unique

  foreach ($process in $processesToStop) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }

  Start-Sleep -Seconds 2
}

function Wait-OpenClawNodeHost {
  param(
    [int]$TimeoutSeconds = 30,
    [int]$StableSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-OpenClawNodeHostProcesses).Count -gt 0) {
      Start-Sleep -Seconds $StableSeconds
      if (@(Get-OpenClawNodeHostProcesses).Count -gt 0) {
        return $true
      }
    }

    Start-Sleep -Seconds 1
  }

  return $false
}

function Start-BackgroundCmd {
  param([Parameter(Mandatory = $true)][string]$ScriptPath)

  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Cannot find startup script: $ScriptPath"
  }

  Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$ScriptPath`"") -WindowStyle Hidden | Out-Null
}

function Invoke-SyncCurrentModel {
  if (-not (Test-Path -LiteralPath $syncScriptPath)) {
    throw "Cannot find OpenClaw sync script: $syncScriptPath"
  }

  if (-not (Test-Path -LiteralPath $powershellExe)) {
    $scriptResult = Invoke-CaptureIsolatedProcess -FilePath "powershell.exe" -Arguments @(
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $syncScriptPath,
      "-NoPause"
    )
  } else {
    $scriptResult = Invoke-CaptureIsolatedProcess -FilePath $powershellExe -Arguments @(
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $syncScriptPath,
      "-NoPause"
    )
  }

  if (-not [string]::IsNullOrWhiteSpace($scriptResult.Output)) {
    Write-Host $scriptResult.Output
  }

  if ($scriptResult.ExitCode -eq 0) {
    return
  }

  if ($scriptResult.Output -match 'being used by another process') {
    Write-Warn "OpenClaw model registry was temporarily locked. Retrying the sync once after a restart."
    $openClawCommandPath = Get-OpenClawCommandPath
    Invoke-OpenClawRestart -OpenClawCommandPath $openClawCommandPath
    Start-Sleep -Seconds 2

    if (-not (Test-Path -LiteralPath $powershellExe)) {
      $scriptResult = Invoke-CaptureIsolatedProcess -FilePath "powershell.exe" -Arguments @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $syncScriptPath,
        "-NoPause"
      )
    } else {
      $scriptResult = Invoke-CaptureIsolatedProcess -FilePath $powershellExe -Arguments @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $syncScriptPath,
        "-NoPause"
      )
    }

    if (-not [string]::IsNullOrWhiteSpace($scriptResult.Output)) {
      Write-Host $scriptResult.Output
    }
  }

  if ($scriptResult.ExitCode -ne 0) {
    throw "Failed to sync OpenClaw to the current llama.cpp model."
  }
}

function Ensure-OpenClawRuntime {
  param([Parameter(Mandatory = $true)][string]$OpenClawCommandPath)

  $gatewayUsesManagedMedia = Test-OpenClawGatewayUsesManagedMedia
  $gatewayReadyTimeoutSeconds = Get-OpenClawGatewayReadyTimeoutSeconds

  if ($gatewayUsesManagedMedia) {
    Write-Info "Detected managed Vision/TTS/STT sidecars behind gateway.cmd. Allowing up to $gatewayReadyTimeoutSeconds seconds for gateway warmup."
  }

  $gatewayReady = Wait-OpenClawGatewayReady -TimeoutSeconds $gatewayReadyTimeoutSeconds -ProbeIntervalSeconds 2
  if (-not $gatewayReady) {
    if (@(Get-OpenClawGatewayHostProcesses).Count -eq 0) {
      if (Test-Path -LiteralPath $openClawRestartPath) {
        Write-Warn "Gateway process was not detected after the restart. Running managed restart script."
        [void](Invoke-ManagedOpenClawRestartScript -Reason "runtime-recovery")
      } elseif (Test-Path -LiteralPath $openClawStartPath) {
        Write-Warn "Gateway process was not detected after the restart. Running .openclaw\\start.cmd."
        Invoke-Checked -FilePath $openClawStartPath
      } else {
        Write-Warn "Gateway process was not detected after the restart. Launching gateway.cmd directly."
        Start-BackgroundCmd -ScriptPath $gatewayScriptPath
      }
      $gatewayReady = Wait-OpenClawGatewayReady -TimeoutSeconds $gatewayReadyTimeoutSeconds -ProbeIntervalSeconds 2
    } elseif ($gatewayUsesManagedMedia) {
      Write-Warn "Gateway host is still warming up while the managed Vision/TTS/STT sidecars initialize."
    } else {
      Write-Warn "Gateway process exists but 127.0.0.1:29644 is still warming up."
    }
  }

  if (-not $gatewayReady) {
    $managedMediaDetail = if ($gatewayUsesManagedMedia) { " Managed TTS/STT sidecars: $(Get-OpenClawManagedMediaStatusText)." } else { "" }
    throw "OpenClaw gateway did not become ready on 127.0.0.1:29644.$managedMediaDetail"
  }

  Write-Ok "OpenClaw gateway is listening on 127.0.0.1:29644"

  if ($gatewayUsesManagedMedia) {
    Wait-HttpReady -Name "TTS" -Url "http://127.0.0.1:$managedTtsHealthPort/health" -TimeoutSeconds 60
    Wait-HttpReady -Name "STT" -Url "http://127.0.0.1:$managedSttHealthPort/health" -TimeoutSeconds 60
    Wait-HttpReady -Name "Vision" -Url $managedVisionHealthUrl -TimeoutSeconds 60
  }

  if (-not (Wait-OpenClawNodeHost -TimeoutSeconds 600)) {
    Write-Warn "Node host was not detected after the service restart. Launching node.cmd directly."
    Start-BackgroundCmd -ScriptPath $nodeScriptPath

    if (-not (Wait-OpenClawNodeHost -TimeoutSeconds 600)) {
      throw "OpenClaw node host did not stay running."
    }
  }

  Write-Ok "OpenClaw node host is running"

  $shouldCheckTelegram = $false
  if (Test-Path -LiteralPath $openClawConfigPath) {
    try {
      $configForTelegramCheck = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
      if (Get-Command Test-OpenClawTelegramConfigured -ErrorAction SilentlyContinue) {
        $shouldCheckTelegram = Test-OpenClawTelegramConfigured -Config $configForTelegramCheck
      }
    } catch {
      $shouldCheckTelegram = $false
    }
  }

  if ($shouldCheckTelegram) {
    Write-Warn "Telegram readiness is monitored by watchdog after the core stack is healthy."
  }
}

function Show-Summary {
  param([Parameter(Mandatory = $true)][bool]$ModelSyncPerformed)

  $activeModelId = Get-RunningLlamaModelId -ModelsUrl $llamaModelsUrl
  $gatewayListening = Test-HttpReady -Url "http://127.0.0.1:29644/health"
  $nodeProcesses = @(Get-OpenClawNodeHostProcesses)
  $managedMediaStatus = if (Test-OpenClawGatewayUsesManagedMedia) { Get-OpenClawManagedMediaStatusText } else { $null }
  $telegramDetail = ""
  $telegramReady = $false
  try {
    $telegramReady = Test-OpenClawTelegramReady -OpenClawCommandPath (Get-OpenClawCommandPath) -Detail ([ref]$telegramDetail)
  } catch {
    $telegramDetail = $_.Exception.Message
  }

  Write-Host ""
  Write-Host "OpenClaw Start Summary" -ForegroundColor Green
  Write-Host ("ModelSync : {0}" -f $(if ($ModelSyncPerformed) { "synced to the running llama.cpp model" } else { "not performed (no llama.cpp server)" }))
  if (-not [string]::IsNullOrWhiteSpace($activeModelId)) {
    Write-Host "Model     : $activeModelId"
  }
  Write-Host ("Gateway   : {0}" -f $(if ($gatewayListening) { "listening on 127.0.0.1:29644" } else { "not listening" }))
  Write-Host ("Node      : {0}" -f $(if ($nodeProcesses.Count -gt 0) { "running ($($nodeProcesses.Count) process entry/entries)" } else { "not detected" }))
  Write-Host ("Telegram  : {0}" -f $(if ($telegramReady) { $telegramDetail } else { "not ready ($telegramDetail)" }))
  if ($null -ne $managedMediaStatus) {
    Write-Host "Media     : $managedMediaStatus"
  }
  Write-Host "Config    : $openClawRoot"
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

$script:OpenClawStartExitCode = 0

try {
  $openClawCommandPath = Get-OpenClawCommandPath
  Clear-OpenClawStopMarker
  Ensure-ManagedOpenClawStartupAssets
  Repair-OpenClawConfigIfNeeded
  Enable-OpenClawWatchdog -NoRun
  $hasRunningLlama = Test-LlamaServerAvailable -ModelsUrl $llamaModelsUrl

  if ($hasRunningLlama) {
    Write-Info "Detected a running llama.cpp server. Syncing OpenClaw to the active model."
    Invoke-SyncCurrentModel
    Write-Info "Restarting OpenClaw services after model sync."
    Invoke-OpenClawRestart -OpenClawCommandPath $openClawCommandPath
  } else {
    Write-Info "No running llama.cpp server detected. Starting OpenClaw with the existing configuration."
    Invoke-OpenClawRestart -OpenClawCommandPath $openClawCommandPath
  }

  Ensure-OpenClawRuntime -OpenClawCommandPath $openClawCommandPath
  Show-Summary -ModelSyncPerformed:$hasRunningLlama
  Enable-OpenClawWatchdog
} catch {
  Write-Host ""
  Write-Host "Error:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  $script:OpenClawStartExitCode = 1
} finally {
  Pause-BeforeExit
  exit $script:OpenClawStartExitCode
}
