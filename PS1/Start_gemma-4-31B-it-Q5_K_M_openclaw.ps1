[CmdletBinding()]
param(
  [int]$ReadyTimeoutSeconds = 180,
  [switch]$SkipSessionUpdate,
  [switch]$SkipLlamaStart,
  [switch]$SkipOpenClawRestart,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$targetModelId = "gemma-4-31B-it-Q5_K_M.gguf"
$targetPrimary = "llama-cpp/$targetModelId"
$fallbackContextWindow = 41216
$llamaModelsUrl = "http://127.0.0.1:8080/v1/models"
$llamaLauncherPath = Join-Path $projectRoot "Start_gemma-4-31B-it-Q5_K_M.gguf.cmd"
$llamaPidPath = Join-Path $projectRoot "logs\llama-server.pid"
$llamaStdOutLogPath = Join-Path $projectRoot "logs\llama-server.stdout.log"
$llamaStdErrLogPath = Join-Path $projectRoot "logs\llama-server.stderr.log"
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

function Get-SafeBackupSuffix {
  param([Parameter(Mandatory = $true)][string]$Text)

  return ([regex]::Replace($Text, '[^A-Za-z0-9._-]+', '-')).Trim('-')
}

function Backup-File {
  param([Parameter(Mandatory = $true)][string]$Path)

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
  $safeSuffix = Get-SafeBackupSuffix -Text $targetModelId
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
    [Parameter(Mandatory = $true)][int]$ContextWindow
  )

  $llamaProvider = Get-LlamaCppProviderNode -Payload $Payload

  $llamaProvider.baseUrl = "http://127.0.0.1:8080/v1"
  $llamaProvider.api = "openai-completions"

  $models = @($llamaProvider.models)
  $entry = $models | Where-Object { $_.id -eq $targetModelId } | Select-Object -First 1

  if ($null -eq $entry) {
    $entry = [pscustomobject]@{
      id = $targetModelId
      name = $targetModelId
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
    $entry.name = $targetModelId
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

function Wait-LlamaModelReady {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedModelId,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-RestMethod -Uri $llamaModelsUrl -TimeoutSec 5
      $availableIds = @()

      if ($null -ne $response.data) {
        $availableIds = @($response.data | ForEach-Object { [string]$_.id })
      } elseif ($null -ne $response.models) {
        $availableIds = @($response.models | ForEach-Object {
          if ($_.PSObject.Properties.Name -contains "model") {
            [string]$_.model
          } else {
            [string]$_.name
          }
        })
      }

      if ($availableIds -contains $ExpectedModelId) {
        return
      }
    } catch {
    }

    Start-Sleep -Seconds 2
  }

  throw "llama.cpp did not report $ExpectedModelId on $llamaModelsUrl within $TimeoutSeconds seconds."
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

function Invoke-Capture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @()
  )

  $output = & $FilePath @Arguments 2>&1
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = ((@($output) | ForEach-Object { [string]$_.ToString().TrimEnd() }) -join [Environment]::NewLine).Trim()
  }
}

function Show-CommandSection {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][object]$Result
  )

  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  if ([string]::IsNullOrWhiteSpace([string]$Result.Output)) {
    Write-Host "(no output)"
  } else {
    Write-Host $Result.Output
  }

  if ([int]$Result.ExitCode -ne 0) {
    Write-Host "ExitCode: $($Result.ExitCode)" -ForegroundColor Yellow
  }
}

function Show-LaunchSummary {
  param(
    [Parameter(Mandatory = $true)][int]$ContextWindow,
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath
  )

  $llamaPid = ""
  if (Test-Path -LiteralPath $llamaPidPath) {
    $llamaPid = (Get-Content -LiteralPath $llamaPidPath -TotalCount 1 | Select-Object -First 1).Trim()
  }

  Write-Host ""
  Write-Host "Background Services Summary" -ForegroundColor Green
  Write-Host "llama.cpp : running in background"
  Write-Host "Model     : $targetModelId"
  Write-Host "Context   : $ContextWindow"
  if (-not [string]::IsNullOrWhiteSpace($llamaPid)) {
    Write-Host "PID       : $llamaPid"
  }
  Write-Host "API       : $llamaModelsUrl"
  Write-Host "Primary   : $targetPrimary"
  Write-Host "StdOut    : $llamaStdOutLogPath"
  Write-Host "StdErr    : $llamaStdErrLogPath"

  $gatewayStatus = Invoke-Capture -FilePath $OpenClawCommandPath -Arguments @("--no-color", "gateway", "status")
  $nodeStatus = Invoke-Capture -FilePath $OpenClawCommandPath -Arguments @("--no-color", "node", "status")

  Show-CommandSection -Title "Gateway Status" -Result $gatewayStatus
  Show-CommandSection -Title "Node Status" -Result $nodeStatus

  Write-Host ""
  Write-Host "You can close this window now. The background services will keep running." -ForegroundColor Green
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

  if (-not (Test-Path -LiteralPath $llamaLauncherPath)) {
    throw "Cannot find llama.cpp launcher: $llamaLauncherPath"
  }

  if (-not (Test-Path -LiteralPath $openClawConfigPath)) {
    throw "Cannot find OpenClaw config: $openClawConfigPath"
  }

  if (-not (Test-Path -LiteralPath $agentModelsPath)) {
    throw "Cannot find agent model registry: $agentModelsPath"
  }

  if (-not $SkipLlamaStart) {
    Write-Info "Starting llama.cpp with $targetModelId"
    Invoke-Checked -FilePath $llamaLauncherPath
  } else {
    Write-Info "Skipping llama.cpp launcher because -SkipLlamaStart was provided."
  }

  Write-Info "Waiting for llama.cpp to report $targetModelId"
  Wait-LlamaModelReady -ExpectedModelId $targetModelId -TimeoutSeconds $ReadyTimeoutSeconds
  Write-Ok "llama.cpp is serving $targetModelId"

  $resolvedContextWindow = Get-LlamaContextWindowFromLogs -Path $llamaStdErrLogPath -Fallback $fallbackContextWindow
  Write-Ok "Detected context window $resolvedContextWindow"

  $config = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
  $currentPrimary = [string]$config.agents.defaults.model.primary
  $previousLlamaModelId = $null

  if ($currentPrimary -like "llama-cpp/*") {
    $previousLlamaModelId = $currentPrimary.Split("/", 2)[1]
  }

  Ensure-LlamaCppModelEntry -Payload $config -ContextWindow $resolvedContextWindow
  $config.agents.defaults.model.primary = $targetPrimary

  $configBackup = Backup-File -Path $openClawConfigPath
  Save-JsonUtf8 -Path $openClawConfigPath -Payload $config
  Write-Ok "Updated openclaw.json -> $targetPrimary"
  Write-Info "Backup written to $configBackup"

  $agentModels = Get-Content -LiteralPath $agentModelsPath -Raw | ConvertFrom-Json
  Ensure-LlamaCppModelEntry -Payload $agentModels -ContextWindow $resolvedContextWindow

  $agentModelsBackup = Backup-File -Path $agentModelsPath
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

      $sessionBackup = Backup-File -Path $sessionPath
      Save-JsonUtf8 -Path $sessionPath -Payload $sessions
      Write-Ok "Updated session model references in $sessionPath"
      Write-Info "Backup written to $sessionBackup"
    }
  } elseif ($SkipSessionUpdate) {
    Write-Info "Skipping session updates because -SkipSessionUpdate was provided."
  } else {
    Write-Info "No prior llama-cpp model reference needed a session update."
  }

  if (-not $SkipOpenClawRestart) {
    Write-Info "Restarting OpenClaw gateway"
    Invoke-Checked -FilePath $openClawCommandPath -Arguments @("gateway", "restart")

    Write-Info "Restarting OpenClaw node"
    Invoke-Checked -FilePath $openClawCommandPath -Arguments @("node", "restart")

    Write-Ok "OpenClaw gateway and node restarted"
  } else {
    Write-Info "Skipping OpenClaw restart because -SkipOpenClawRestart was provided."
  }

  Write-Ok "OpenClaw is now pointed at $targetPrimary"
  Show-LaunchSummary -ContextWindow $resolvedContextWindow -OpenClawCommandPath $openClawCommandPath
} catch {
  Write-Host ""
  Write-Host "Error:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
} finally {
  Pause-BeforeExit
}
