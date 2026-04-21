[CmdletBinding()]
param(
  [switch]$SkipSessionUpdate,
  [switch]$RestartOpenClaw,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$openClawSupportPath = Join-Path $PSScriptRoot "OpenClawSupport.ps1"
$llamaModelsUrl = "http://127.0.0.1:8080/v1/models"
$llamaStdErrLogPath = Join-Path $projectRoot "logs\llama-server.stderr.log"
$llamaPidPath = Join-Path $projectRoot "logs\llama-server.pid"
$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$openClawConfigPath = Join-Path $openClawRoot "openclaw.json"
$gatewayScriptPath = Join-Path $openClawRoot "gateway.cmd"
$nodeScriptPath = Join-Path $openClawRoot "node.cmd"
$managedGatewayScriptName = "run-openclaw-gateway-with-media.ps1"
$managedTtsHealthPort = 8000
$managedSttHealthPort = 8001
$agentModelsPath = Join-Path $openClawRoot "agents\main\agent\models.json"
$sessionPaths = @(
  (Join-Path $openClawRoot "agents\main\sessions\sessions.json"),
  (Join-Path $openClawRoot "agents\worker1\sessions\sessions.json"),
  (Join-Path $openClawRoot "agents\worker2\sessions\sessions.json")
)

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

function Start-BackgroundCmd {
  param([Parameter(Mandatory = $true)][string]$ScriptPath)

  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Cannot find startup script: $ScriptPath"
  }

  Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$ScriptPath`"") -WindowStyle Hidden | Out-Null
}

function Get-LlamaContextWindowFromLogs {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int]$Fallback
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $Fallback
  }

  $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
  for ($index = $lines.Count - 1; $index -ge 0; $index -= 1) {
    if ($lines[$index] -match 'llama_context:\s+n_ctx\s*=\s*(\d+)') {
      return [int]$Matches[1]
    }
  }

  for ($index = $lines.Count - 1; $index -ge 0; $index -= 1) {
    if ($lines[$index] -match 'print_info:\s+n_ctx_train\s*=\s*(\d+)') {
      return [int]$Matches[1]
    }
  }

  return $Fallback
}

function Get-LlamaRuntimeTokenSnapshot {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $lines = @(Get-Content -LiteralPath $Path -Tail 4000 -ErrorAction SilentlyContinue)
  if (-not $lines -or $lines.Count -eq 0) {
    return $null
  }

  for ($index = $lines.Count - 1; $index -ge 0; $index -= 1) {
    if ($lines[$index] -match 'request \((\d+) tokens\) exceeds the available context size \((\d+) tokens\)') {
      return [pscustomobject]@{
        PromptTokens = [int]$Matches[1]
        ContextTokens = [int]$Matches[2]
        Overflow = $true
      }
    }

    if ($lines[$index] -match 'new prompt, n_ctx_slot = (\d+), n_keep = \d+, task\.n_tokens = (\d+)') {
      return [pscustomobject]@{
        PromptTokens = [int]$Matches[2]
        ContextTokens = [int]$Matches[1]
        Overflow = $false
      }
    }
  }

  $contextWindow = Get-LlamaContextWindowFromLogs -Path $Path -Fallback 0
  if ($contextWindow -gt 0) {
    return [pscustomobject]@{
      PromptTokens = $null
      ContextTokens = $contextWindow
      Overflow = $false
    }
  }

  return $null
}

function Get-RunningLlamaModelInfo {
  param([Parameter(Mandatory = $true)][string]$ModelsUrl)

  try {
    $response = Invoke-RestMethod -Uri $ModelsUrl -TimeoutSec 5
  }
  catch {
    throw "Cannot reach llama.cpp at $ModelsUrl. Start the server first, then run update_openclaw_sataus.cmd."
  }

  $modelId = $null
  $metaContext = $null

  if ($null -ne $response.data -and @($response.data).Count -gt 0) {
    $firstModel = @($response.data)[0]
    $modelId = [string]$firstModel.id
    if ($firstModel.PSObject.Properties.Name -contains "meta" -and
        $null -ne $firstModel.meta -and
        $firstModel.meta.PSObject.Properties.Name -contains "n_ctx_train" -and
        [string]$firstModel.meta.n_ctx_train) {
      $metaContext = [int]$firstModel.meta.n_ctx_train
    }
  } elseif ($null -ne $response.models -and @($response.models).Count -gt 0) {
    $firstModel = @($response.models)[0]
    if ($firstModel.PSObject.Properties.Name -contains "model") {
      $modelId = [string]$firstModel.model
    } else {
      $modelId = [string]$firstModel.name
    }
  }

  if ([string]::IsNullOrWhiteSpace($modelId)) {
    throw "llama.cpp responded, but no model id was reported by $ModelsUrl."
  }

  return [pscustomobject]@{
    ModelId      = $modelId
    TrainContext = $metaContext
  }
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
  }
  catch {
    return $false
  }
  finally {
    $client.Close()
  }
}

function Test-OpenClawGatewayUsesManagedMedia {
  if (-not (Test-Path -LiteralPath $gatewayScriptPath)) {
    return $false
  }

  try {
    $gatewayText = Get-Content -LiteralPath $gatewayScriptPath -Raw -ErrorAction Stop
  }
  catch {
    return $false
  }

  return ($gatewayText -match [regex]::Escape($managedGatewayScriptName))
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
    return $null
  }

  $mediaProcesses = @(Get-OpenClawManagedMediaProcesses)
  $ttsProcessDetected = @($mediaProcesses | Where-Object { $_.CommandLine -match 'workspace[\\/]+tts_server\.py' }).Count -gt 0
  $sttProcessDetected = @($mediaProcesses | Where-Object { $_.CommandLine -match 'workspace[\\/]+stt_server\.py' }).Count -gt 0
  $ttsListening = Test-TcpPort -TargetHost "127.0.0.1" -Port $managedTtsHealthPort
  $sttListening = Test-TcpPort -TargetHost "127.0.0.1" -Port $managedSttHealthPort

  $ttsStatus = if ($ttsListening) {
    "TTS ready on 127.0.0.1:$managedTtsHealthPort"
  } elseif ($ttsProcessDetected) {
    "TTS process detected"
  } else {
    "TTS not detected"
  }

  $sttStatus = if ($sttListening) {
    "STT ready on 127.0.0.1:$managedSttHealthPort"
  } elseif ($sttProcessDetected) {
    "STT process detected"
  } else {
    "STT not detected"
  }

  return "$ttsStatus; $sttStatus"
}

function Get-LlamaCppProviderNode {
  param([Parameter(Mandatory = $true)][object]$Payload)

  if ($Payload.PSObject.Properties.Name -contains "models" -and
      $null -ne $Payload.models -and
      $Payload.models.PSObject.Properties.Name -contains "providers" -and
      $null -ne $Payload.models.providers -and
      $Payload.models.providers.PSObject.Properties.Name -contains "llama-cpp") {
    return $Payload.models.providers.'llama-cpp'
  }

  if ($Payload.PSObject.Properties.Name -contains "providers" -and
      $null -ne $Payload.providers -and
      $Payload.providers.PSObject.Properties.Name -contains "llama-cpp") {
    return $Payload.providers.'llama-cpp'
  }

  throw "Could not find a llama-cpp provider node in the JSON payload."
}

function Ensure-LlamaCppModelEntry {
  param(
    [Parameter(Mandatory = $true)][object]$Payload,
    [Parameter(Mandatory = $true)][string]$ModelId,
    [Parameter(Mandatory = $true)][int]$ContextWindow
  )

  $llamaProvider = Get-LlamaCppProviderNode -Payload $Payload

  $llamaProvider.baseUrl = "http://127.0.0.1:8080/v1"
  $llamaProvider.api = "openai-completions"

  $models = @($llamaProvider.models)
  $entry = $models | Where-Object { $_.id -eq $ModelId } | Select-Object -First 1

  if ($null -eq $entry) {
    $entry = [pscustomobject]@{
      id = $ModelId
      name = $ModelId
      api = "openai-completions"
      reasoning = $false
      input = @("text")
      cost = [pscustomobject]@{
        input = 0
        output = 0
        cacheRead = 0
        cacheWrite = 0
      }
      contextWindow = $ContextWindow
      maxTokens = 8192
    }
    $models = @($models + $entry)
  } else {
    $entry.name = $ModelId
    $entry.api = "openai-completions"
    $entry.reasoning = $false
    $entry.input = @("text")
    $entry.contextWindow = $ContextWindow
    $entry.maxTokens = 8192
    if ($null -eq $entry.cost) {
      $entry | Add-Member -NotePropertyName cost -NotePropertyValue ([pscustomobject]@{})
    }
    $entry.cost.input = 0
    $entry.cost.output = 0
    $entry.cost.cacheRead = 0
    $entry.cost.cacheWrite = 0
  }

  $llamaProvider.models = @($models)
}

function Replace-ExactStringValue {
  param(
    [Parameter(Mandatory = $true)][AllowNull()][object]$Node,
    [Parameter(Mandatory = $true)][string]$OldValue,
    [Parameter(Mandatory = $true)][string]$NewValue
  )

  if ($null -eq $Node) {
    return $null
  }

  if ($Node -is [string]) {
    if ($Node -eq $OldValue) {
      return $NewValue
    }
    return $Node
  }

  if ($Node -is [System.Collections.IList]) {
    for ($index = 0; $index -lt $Node.Count; $index += 1) {
      $Node[$index] = Replace-ExactStringValue -Node $Node[$index] -OldValue $OldValue -NewValue $NewValue
    }
    return $Node
  }

  if ($Node -is [pscustomobject]) {
    foreach ($property in $Node.PSObject.Properties) {
      $property.Value = Replace-ExactStringValue -Node $property.Value -OldValue $OldValue -NewValue $NewValue
    }
    return $Node
  }

  return $Node
}

function Set-JsonNoteProperty {
  param(
    [Parameter(Mandatory = $true)][object]$Node,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()]$Value
  )

  if ($Node.PSObject.Properties.Name -contains $Name) {
    $Node.$Name = $Value
  } else {
    $Node | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Update-LlamaCppSessionEntries {
  param(
    [Parameter(Mandatory = $true)][object]$Sessions,
    [Parameter(Mandatory = $true)][string]$ModelId,
    [string]$PreviousModelId,
    [Parameter(Mandatory = $true)][int]$ContextWindow
  )

  $updated = $false

  foreach ($sessionProperty in $Sessions.PSObject.Properties) {
    $entry = $sessionProperty.Value
    if ($null -eq $entry -or -not ($entry -is [pscustomobject])) {
      continue
    }

    $entryModelProvider = if ($entry.PSObject.Properties.Name -contains "modelProvider") { [string]$entry.modelProvider } else { "" }
    $entryModel = if ($entry.PSObject.Properties.Name -contains "model") { [string]$entry.model } else { "" }
    $isLlamaEntry = ($entryModelProvider -eq "llama-cpp") -or ($entryModel -eq $ModelId) -or ((-not [string]::IsNullOrWhiteSpace($PreviousModelId)) -and $entryModel -eq $PreviousModelId)

    if (-not $isLlamaEntry) {
      continue
    }

    if ($entryModelProvider -ne "llama-cpp") {
      Set-JsonNoteProperty -Node $entry -Name "modelProvider" -Value "llama-cpp"
      $updated = $true
    }

    if ($entryModel -ne $ModelId) {
      Set-JsonNoteProperty -Node $entry -Name "model" -Value $ModelId
      $updated = $true
    }

    $entryContextTokens = if ($entry.PSObject.Properties.Name -contains "contextTokens") { $entry.contextTokens } else { $null }
    if ($entryContextTokens -ne $ContextWindow) {
      Set-JsonNoteProperty -Node $entry -Name "contextTokens" -Value $ContextWindow
      $updated = $true
    }
  }

  return $updated
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

function Get-NodeExecutablePath {
  $candidates = @(
    "C:\Program Files\nodejs\node.exe",
    "node.exe",
    "node"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }

    $resolved = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($resolved) {
      return $resolved.Source
    }
  }

  throw "Cannot find Node.js in PATH or the default installation directory."
}

function Invoke-SessionTokenBackfill {
  $backfillScriptPath = Join-Path $openClawRoot "scripts\backfill-session-token-cache.mjs"
  if (-not (Test-Path -LiteralPath $backfillScriptPath)) {
    Write-Warn "Skipping session token backfill because the script was not found: $backfillScriptPath"
    return
  }

  $nodePath = Get-NodeExecutablePath
  $output = & $nodePath $backfillScriptPath 2>&1
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  $text = ((@($output) | ForEach-Object { [string]$_.ToString().TrimEnd() }) -join [Environment]::NewLine).Trim()

  if ($exitCode -ne 0) {
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      Write-Warn "Session token backfill failed: $text"
    } else {
      Write-Warn "Session token backfill failed with exit code $exitCode."
    }
    return
  }

  if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Info "Session token backfill finished without output."
    return
  }

  try {
    $result = $text | ConvertFrom-Json
    Write-Ok "Session token cache backfill complete"
    Write-Info "Updated stores: $($result.updatedStores) | updated entries: $($result.updatedEntries) | already fresh: $($result.skippedAlreadyFresh) | skipped: $($result.skippedMissingTranscript)"
  }
  catch {
    Write-Info $text
  }
}

function Restart-OpenClawServices {
  param([Parameter(Mandatory = $true)][string]$OpenClawCommandPath)

  foreach ($taskName in @("OpenClaw Gateway", "OpenClaw Node")) {
    & schtasks.exe /End /TN $taskName *> $null
  }

  $processesToStop = @(
    @(Get-OpenClawGatewayHostProcesses) +
    @(Get-OpenClawNodeHostProcesses)
  ) | Sort-Object ProcessId -Unique

  foreach ($process in $processesToStop) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }

  Start-Sleep -Seconds 2
  Start-BackgroundCmd -ScriptPath $gatewayScriptPath
  Start-Sleep -Seconds 2
  Start-BackgroundCmd -ScriptPath $nodeScriptPath
}

function Show-Summary {
  param(
    [Parameter(Mandatory = $true)][string]$ModelId,
    [Parameter(Mandatory = $true)][int]$ContextWindow
  )

  $llamaPid = ""
  $gatewayListening = Test-TcpPort -TargetHost "127.0.0.1" -Port 29644
  $managedMediaStatus = Get-OpenClawManagedMediaStatusText
  if (Test-Path -LiteralPath $llamaPidPath) {
    $llamaPid = (Get-Content -LiteralPath $llamaPidPath -TotalCount 1 | Select-Object -First 1).Trim()
  }

  Write-Host ""
  Write-Host "OpenClaw Sync Summary" -ForegroundColor Green
  Write-Host "Model     : $ModelId"
  Write-Host "Primary   : llama-cpp/$ModelId"
  Write-Host "Context   : $ContextWindow"
  if (-not [string]::IsNullOrWhiteSpace($llamaPid)) {
  Write-Host "PID       : $llamaPid"
  }
  Write-Host "API       : $llamaModelsUrl"
  Write-Host "Config    : $openClawConfigPath"
  Write-Host "Registry  : $agentModelsPath"
  Write-Host "Gateway   : http://127.0.0.1:29644/"
  if ($gatewayListening) {
    Write-Host "Gateway TCP: listening"
  } elseif ($null -ne $managedMediaStatus) {
    Write-Host "Gateway TCP: warming up behind managed TTS/STT sidecars"
  } else {
    Write-Host "Gateway TCP: not listening"
  }
  if ($null -ne $managedMediaStatus) {
    Write-Host "Media     : $managedMediaStatus"
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
  $openClawCommandPath = Get-OpenClawCommandPath
  Ensure-ManagedOpenClawStartupAssets

  if (-not (Test-Path -LiteralPath $openClawConfigPath)) {
    throw "Cannot find OpenClaw config: $openClawConfigPath"
  }

  if (-not (Test-Path -LiteralPath $agentModelsPath)) {
    throw "Cannot find agent model registry: $agentModelsPath"
  }

  $runtimeModel = Get-RunningLlamaModelInfo -ModelsUrl $llamaModelsUrl
  $targetModelId = $runtimeModel.ModelId
  $runtimeTokenSnapshot = Get-LlamaRuntimeTokenSnapshot -Path $llamaStdErrLogPath
  $resolvedContextWindow = if ($runtimeTokenSnapshot -and $runtimeTokenSnapshot.ContextTokens) {
    [int]$runtimeTokenSnapshot.ContextTokens
  } else {
    Get-LlamaContextWindowFromLogs -Path $llamaStdErrLogPath -Fallback $(if ($runtimeModel.TrainContext) { $runtimeModel.TrainContext } else { 8192 })
  }
  $resolvedPromptTokens = if ($runtimeTokenSnapshot -and $null -ne $runtimeTokenSnapshot.PromptTokens) { [int]$runtimeTokenSnapshot.PromptTokens } else { $null }
  $targetPrimary = "llama-cpp/$targetModelId"

  Write-Ok "Detected running llama.cpp model $targetModelId"
  Write-Info "Resolved context window $resolvedContextWindow"
  if ($null -ne $resolvedPromptTokens) {
    Write-Info "Observed last runtime prompt tokens $resolvedPromptTokens"
  }

  $config = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
  $removedConfigKeys = @(Remove-DeprecatedOpenClawConfigKeys -Config $config)
  $currentPrimary = [string]$config.agents.defaults.model.primary
  $previousLlamaModelId = $null

  if ($currentPrimary -like "llama-cpp/*") {
    $previousLlamaModelId = $currentPrimary.Split("/", 2)[1]
  }

  Ensure-LlamaCppModelEntry -Payload $config -ModelId $targetModelId -ContextWindow $resolvedContextWindow
  Set-JsonNoteProperty -Node $config.agents.defaults.model -Name "primary" -Value $targetPrimary
  Set-JsonNoteProperty -Node $config.agents.defaults -Name "contextTokens" -Value $resolvedContextWindow

  $configBackup = Backup-File -Path $openClawConfigPath -Suffix $targetModelId
  Save-JsonUtf8 -Path $openClawConfigPath -Payload $config
  Write-Ok "Updated openclaw.json -> $targetPrimary"
  Write-Info "Backup written to $configBackup"
  if ($removedConfigKeys.Count -gt 0) {
    Write-Warn "Removed deprecated OpenClaw config keys: $($removedConfigKeys -join ', ')"
  }

  $agentModels = Get-Content -LiteralPath $agentModelsPath -Raw | ConvertFrom-Json
  Ensure-LlamaCppModelEntry -Payload $agentModels -ModelId $targetModelId -ContextWindow $resolvedContextWindow

  $agentModelsBackup = Backup-File -Path $agentModelsPath -Suffix $targetModelId
  Save-JsonUtf8 -Path $agentModelsPath -Payload $agentModels
  Write-Ok "Updated agents/main/agent/models.json"
  Write-Info "Backup written to $agentModelsBackup"

  if (-not $SkipSessionUpdate) {
    foreach ($sessionPath in $sessionPaths) {
      if (-not (Test-Path -LiteralPath $sessionPath)) {
        continue
      }

      $sessions = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
      $sessionChanged = $false

      if ($previousLlamaModelId -and $previousLlamaModelId -ne $targetModelId) {
        [void](Replace-ExactStringValue -Node $sessions -OldValue $previousLlamaModelId -NewValue $targetModelId)
        $sessionChanged = $true
      }

      if (Update-LlamaCppSessionEntries -Sessions $sessions -ModelId $targetModelId -PreviousModelId $previousLlamaModelId -ContextWindow $resolvedContextWindow) {
        $sessionChanged = $true
      }

      if (-not $sessionChanged) {
        continue
      }

      $sessionBackup = Backup-File -Path $sessionPath -Suffix $targetModelId
      Save-JsonUtf8 -Path $sessionPath -Payload $sessions
      Write-Ok "Updated llama-cpp session runtime state in $sessionPath"
      Write-Info "Backup written to $sessionBackup"
    }

    Invoke-SessionTokenBackfill
  } elseif ($SkipSessionUpdate) {
    Write-Info "Skipping session updates because -SkipSessionUpdate was provided."
  } else {
    Write-Info "No prior llama-cpp model reference needed a session update."
  }

  if ($RestartOpenClaw) {
    Write-Info "Restarting OpenClaw via local gateway/node startup scripts"
    Restart-OpenClawServices -OpenClawCommandPath $openClawCommandPath
    Write-Ok "OpenClaw gateway and node restart requested"
  } else {
    Write-Info "OpenClaw restart was not requested. Config and session state were synced only."
  }

  Write-Ok "OpenClaw is now pointed at $targetPrimary"
  Show-Summary -ModelId $targetModelId -ContextWindow $resolvedContextWindow
} catch {
  Write-Host ""
  Write-Host "Error:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
} finally {
  Pause-BeforeExit
}
