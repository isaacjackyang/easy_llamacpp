[CmdletBinding()]
param(
  [switch]$SkipSessionUpdate,
  [switch]$RestartOpenClaw,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$llamaModelsUrl = "http://127.0.0.1:8080/v1/models"
$llamaStdErrLogPath = Join-Path $projectRoot "logs\llama-server.stderr.log"
$llamaPidPath = Join-Path $projectRoot "logs\llama-server.pid"
$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$openClawConfigPath = Join-Path $openClawRoot "openclaw.json"
$agentModelsPath = Join-Path $openClawRoot "agents\main\agent\models.json"
$sessionPaths = @(
  (Join-Path $openClawRoot "agents\main\sessions\sessions.json"),
  (Join-Path $openClawRoot "agents\worker1\sessions\sessions.json"),
  (Join-Path $openClawRoot "agents\worker2\sessions\sessions.json")
)

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

function Restart-OpenClawServices {
  param([Parameter(Mandatory = $true)][string]$OpenClawCommandPath)

  Invoke-Checked -FilePath $OpenClawCommandPath -Arguments @("--no-color", "gateway", "restart")
  Start-Sleep -Seconds 2
  Invoke-Checked -FilePath $OpenClawCommandPath -Arguments @("--no-color", "node", "restart")
}

function Show-Summary {
  param(
    [Parameter(Mandatory = $true)][string]$ModelId,
    [Parameter(Mandatory = $true)][int]$ContextWindow
  )

  $llamaPid = ""
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
  Write-Host ("Gateway TCP: {0}" -f $(if (Test-TcpPort -TargetHost "127.0.0.1" -Port 29644) { "listening" } else { "not listening" }))
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

  if (-not (Test-Path -LiteralPath $openClawConfigPath)) {
    throw "Cannot find OpenClaw config: $openClawConfigPath"
  }

  if (-not (Test-Path -LiteralPath $agentModelsPath)) {
    throw "Cannot find agent model registry: $agentModelsPath"
  }

  $runtimeModel = Get-RunningLlamaModelInfo -ModelsUrl $llamaModelsUrl
  $targetModelId = $runtimeModel.ModelId
  $resolvedContextWindow = Get-LlamaContextWindowFromLogs -Path $llamaStdErrLogPath -Fallback $(if ($runtimeModel.TrainContext) { $runtimeModel.TrainContext } else { 8192 })
  $targetPrimary = "llama-cpp/$targetModelId"

  Write-Ok "Detected running llama.cpp model $targetModelId"
  Write-Info "Resolved context window $resolvedContextWindow"

  $config = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
  $currentPrimary = [string]$config.agents.defaults.model.primary
  $previousLlamaModelId = $null

  if ($currentPrimary -like "llama-cpp/*") {
    $previousLlamaModelId = $currentPrimary.Split("/", 2)[1]
  }

  Ensure-LlamaCppModelEntry -Payload $config -ModelId $targetModelId -ContextWindow $resolvedContextWindow
  $config.agents.defaults.model.primary = $targetPrimary

  $configBackup = Backup-File -Path $openClawConfigPath -Suffix $targetModelId
  Save-JsonUtf8 -Path $openClawConfigPath -Payload $config
  Write-Ok "Updated openclaw.json -> $targetPrimary"
  Write-Info "Backup written to $configBackup"

  $agentModels = Get-Content -LiteralPath $agentModelsPath -Raw | ConvertFrom-Json
  Ensure-LlamaCppModelEntry -Payload $agentModels -ModelId $targetModelId -ContextWindow $resolvedContextWindow

  $agentModelsBackup = Backup-File -Path $agentModelsPath -Suffix $targetModelId
  Save-JsonUtf8 -Path $agentModelsPath -Payload $agentModels
  Write-Ok "Updated agents/main/agent/models.json"
  Write-Info "Backup written to $agentModelsBackup"

  if (-not $SkipSessionUpdate -and $previousLlamaModelId -and $previousLlamaModelId -ne $targetModelId) {
    foreach ($sessionPath in $sessionPaths) {
      if (-not (Test-Path -LiteralPath $sessionPath)) {
        continue
      }

      $sessions = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
      [void](Replace-ExactStringValue -Node $sessions -OldValue $previousLlamaModelId -NewValue $targetModelId)

      $sessionBackup = Backup-File -Path $sessionPath -Suffix $targetModelId
      Save-JsonUtf8 -Path $sessionPath -Payload $sessions
      Write-Ok "Updated session model references in $sessionPath"
      Write-Info "Backup written to $sessionBackup"
    }
  } elseif ($SkipSessionUpdate) {
    Write-Info "Skipping session updates because -SkipSessionUpdate was provided."
  } else {
    Write-Info "No prior llama-cpp model reference needed a session update."
  }

  if ($RestartOpenClaw) {
    Write-Info "Restarting OpenClaw via official CLI service commands"
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
