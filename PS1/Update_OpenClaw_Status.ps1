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
$modelIndexPath = Join-Path $projectRoot "json\model-index.json"
$llamaStdErrLogPath = Join-Path $projectRoot "logs\llama-server.stderr.log"
$llamaPidPath = Join-Path $projectRoot "logs\llama-server.pid"
$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$openClawConfigPath = Join-Path $openClawRoot "openclaw.json"
$openClawStartPath = Join-Path $openClawRoot "start.cmd"
$openClawRestartPath = Join-Path $openClawRoot "scripts\restart-openclaw-gateway.ps1"
$gatewayScriptPath = Join-Path $openClawRoot "gateway.cmd"
$nodeScriptPath = Join-Path $openClawRoot "node.cmd"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe)) {
  $powershellExe = "powershell.exe"
}
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
    $updatedLoadPaths = @($loadPaths | Where-Object { $_ -notmatch '(?i)openclaw-web-search|voice-call|browser' })
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

      $entry = $Config.plugins.entries.$pluginName
      if (-not ($entry -is [pscustomobject])) {
        continue
      }

      if ($entry.PSObject.Properties.Name -contains "enabled") {
        if ($entry.enabled -ne $false) {
          $entry.enabled = $false
          $changedKeys.Add("plugins.entries.$pluginName.enabled")
        }
      } else {
        $entry | Add-Member -NotePropertyName "enabled" -NotePropertyValue $false
        $changedKeys.Add("plugins.entries.$pluginName.enabled")
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
  }
  catch {
    return $false
  }

  return (
    ($gatewayText -match [regex]::Escape($managedGatewayScriptName)) -or
    ($gatewayText -match 'start-openclaw-gateway-hidden\.vbs') -or
    ($gatewayText -match 'OPENCLAW_GATEWAY_LAUNCHER')
  )
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
  $ttsListening = Test-HttpReady -Url "http://127.0.0.1:$managedTtsHealthPort/health"
  $sttListening = Test-HttpReady -Url "http://127.0.0.1:$managedSttHealthPort/health"

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

function Test-MmprojFilePath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  $fileName = [System.IO.Path]::GetFileName($Path)
  return ($fileName -match '(?i)(^|[-_.])mmproj([-_.]|$)')
}

function Get-MmprojNameTokens {
  param([Parameter(Mandatory = $true)][string]$Text)

  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Text).ToLowerInvariant()
  $baseName = $baseName -replace 'mmproj', ' '
  $tokens = [regex]::Matches($baseName, '[a-z0-9]+') | ForEach-Object { $_.Value }
  $stopTokens = @(
    "q2", "q3", "q4", "q5", "q6", "q7", "q8", "q9",
    "k", "m", "s", "l", "xl", "xs", "p", "0", "1",
    "f16", "fp16", "bf16", "gguf", "uncensored"
  )

  return @($tokens | Where-Object { $_ -and ($stopTokens -notcontains $_) } | Select-Object -Unique)
}

function Get-MmprojTokenMatchScore {
  param(
    [Parameter(Mandatory = $true)][string]$ModelPath,
    [Parameter(Mandatory = $true)][string]$ProjectorPath
  )

  $modelTokens = @(Get-MmprojNameTokens -Text $ModelPath)
  $projectorTokens = @(Get-MmprojNameTokens -Text $ProjectorPath)
  if ($modelTokens.Count -eq 0 -or $projectorTokens.Count -eq 0) {
    return 0
  }

  $score = 0
  foreach ($token in $modelTokens) {
    if ($projectorTokens -contains $token) {
      $score += 10
    }
  }

  $modelName = ([System.IO.Path]::GetFileNameWithoutExtension($ModelPath)).ToLowerInvariant()
  $projectorName = ([System.IO.Path]::GetFileNameWithoutExtension($ProjectorPath)).ToLowerInvariant()
  $projectorName = $projectorName -replace '^mmproj[-_. ]*', ''
  $limit = [Math]::Min($modelName.Length, $projectorName.Length)
  for ($index = 0; $index -lt $limit; $index += 1) {
    if ($modelName[$index] -ne $projectorName[$index]) {
      break
    }

    $score += 1
  }

  return $score
}

function Find-MmprojForModel {
  param([AllowNull()][string]$ModelPath)

  if ([string]::IsNullOrWhiteSpace($ModelPath) -or -not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    return $null
  }
  if (Test-MmprojFilePath -Path $ModelPath) {
    return $null
  }

  $modelDirectory = Split-Path -Parent $ModelPath
  if ([string]::IsNullOrWhiteSpace($modelDirectory) -or -not (Test-Path -LiteralPath $modelDirectory -PathType Container)) {
    return $null
  }

  $projectors = @(Get-ChildItem -LiteralPath $modelDirectory -File -Filter "*mmproj*.gguf" -ErrorAction SilentlyContinue)
  if ($projectors.Count -eq 0) {
    return $null
  }

  $selectedProjector = @(
    foreach ($projector in $projectors) {
      [pscustomobject]@{
        Path = $projector.FullName
        Score = Get-MmprojTokenMatchScore -ModelPath $ModelPath -ProjectorPath $projector.FullName
      }
    }
  ) | Sort-Object Score -Descending | Select-Object -First 1

  if ($selectedProjector -and $selectedProjector.Score -gt 0) {
    return [string]$selectedProjector.Path
  }

  return $null
}

function Split-ArgumentLine {
  param([AllowNull()][string]$Line)

  if ([string]::IsNullOrWhiteSpace($Line)) {
    return @()
  }

  $matches = [regex]::Matches($Line, '(?:"((?:[^"\\]|\\.)*)"|(\S+))')
  return @(
    foreach ($match in $matches) {
      if ($match.Groups[1].Success) {
        $match.Groups[1].Value.Replace('\"', '"')
      } else {
        $match.Groups[2].Value
      }
    }
  )
}

function Get-RunningPrimaryLlamaMmprojPath {
  if (-not (Test-Path -LiteralPath $llamaPidPath -PathType Leaf)) {
    return $null
  }

  $pidText = ((Get-Content -LiteralPath $llamaPidPath -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
  if ($pidText -notmatch '^\d+$') {
    return $null
  }

  $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $pidText" -ErrorAction SilentlyContinue
  if (-not $processInfo -or [string]::IsNullOrWhiteSpace([string]$processInfo.CommandLine)) {
    return $null
  }

  $tokens = @(Split-ArgumentLine -Line ([string]$processInfo.CommandLine))
  for ($index = 0; $index -lt $tokens.Count; $index += 1) {
    $argument = [string]$tokens[$index]
    if ($argument -match '^--mmproj=(.+)$') {
      return $Matches[1]
    }
    if ($argument -eq "--mmproj" -and ($index + 1) -lt $tokens.Count) {
      return [string]$tokens[$index + 1]
    }
  }

  return $null
}

function Resolve-ModelPathFromRuntimeId {
  param([Parameter(Mandatory = $true)][string]$ModelId)

  if (-not (Test-Path -LiteralPath $modelIndexPath -PathType Leaf)) {
    return $null
  }

  try {
    $index = Get-Content -LiteralPath $modelIndexPath -Raw | ConvertFrom-Json
  }
  catch {
    return $null
  }

  foreach ($entry in @($index.models)) {
    $entryPath = if ($entry.PSObject.Properties.Name -contains "path") { [string]$entry.path } else { "" }
    if ([string]::IsNullOrWhiteSpace($entryPath) -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
      continue
    }

    $entryFile = [System.IO.Path]::GetFileName($entryPath)
    $entryBase = [System.IO.Path]::GetFileNameWithoutExtension($entryPath)
    $entryName = if ($entry.PSObject.Properties.Name -contains "name") { [string]$entry.name } else { "" }
    $entryId = if ($entry.PSObject.Properties.Name -contains "id") { [string]$entry.id } else { "" }

    if ([string]::Equals($ModelId, $entryFile, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($ModelId, $entryBase, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($ModelId, $entryName, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($ModelId, $entryId, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $entryPath
    }
  }

  return $null
}

function Get-OrCreateModelProvidersNode {
  param([Parameter(Mandatory = $true)][object]$Payload)

  if ($Payload.PSObject.Properties.Name -contains "models" -and $Payload.models -is [pscustomobject]) {
    if (-not ($Payload.models.PSObject.Properties.Name -contains "providers") -or $null -eq $Payload.models.providers) {
      $Payload.models | Add-Member -NotePropertyName "providers" -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    return $Payload.models.providers
  }

  if ($Payload.PSObject.Properties.Name -contains "providers" -and $Payload.providers -is [pscustomobject]) {
    return $Payload.providers
  }

  if (-not ($Payload.PSObject.Properties.Name -contains "models") -or $null -eq $Payload.models) {
    $Payload | Add-Member -NotePropertyName "models" -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $Payload.models | Add-Member -NotePropertyName "providers" -NotePropertyValue ([pscustomobject]@{}) -Force
  return $Payload.models.providers
}

function Ensure-LlamaCppVisionModelEntry {
  param(
    [Parameter(Mandatory = $true)][object]$Payload,
    [Parameter(Mandatory = $true)][string]$ModelId,
    [Parameter(Mandatory = $true)][int]$ContextWindow,
    [string]$BaseUrl = "http://127.0.0.1:8081/v1"
  )

  $providers = Get-OrCreateModelProvidersNode -Payload $Payload
  if (-not ($providers.PSObject.Properties.Name -contains "llama-cpp-vision") -or $null -eq $providers.'llama-cpp-vision') {
    $providers | Add-Member -NotePropertyName "llama-cpp-vision" -NotePropertyValue ([pscustomobject]@{}) -Force
  }

  $visionProvider = $providers.'llama-cpp-vision'
  $visionProvider | Add-Member -NotePropertyName "baseUrl" -NotePropertyValue $BaseUrl -Force
  $visionProvider | Add-Member -NotePropertyName "apiKey" -NotePropertyValue "llama-cpp-local" -Force
  $visionProvider | Add-Member -NotePropertyName "api" -NotePropertyValue "openai-completions" -Force
  if (-not ($visionProvider.PSObject.Properties.Name -contains "models") -or $null -eq $visionProvider.models) {
    $visionProvider | Add-Member -NotePropertyName "models" -NotePropertyValue @() -Force
  }

  $models = @($visionProvider.models)
  $entry = $models | Where-Object { $_.id -eq $ModelId } | Select-Object -First 1
  if ($null -eq $entry) {
    $entry = [pscustomobject]@{
      id = $ModelId
      name = $ModelId
      api = "openai-completions"
      reasoning = $false
      input = @("text", "image")
      cost = [pscustomobject]@{
        input = 0
        output = 0
        cacheRead = 0
        cacheWrite = 0
      }
      contextWindow = $ContextWindow
      maxTokens = 2048
    }
    $models = @($models + $entry)
  } else {
    $entry.name = $ModelId
    $entry.api = "openai-completions"
    $entry.reasoning = $false
    $entry.input = @("text", "image")
    $entry.contextWindow = $ContextWindow
    $entry.maxTokens = 2048
    if ($null -eq $entry.cost) {
      $entry | Add-Member -NotePropertyName cost -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $entry.cost | Add-Member -NotePropertyName "input" -NotePropertyValue 0 -Force
    $entry.cost | Add-Member -NotePropertyName "output" -NotePropertyValue 0 -Force
    $entry.cost | Add-Member -NotePropertyName "cacheRead" -NotePropertyValue 0 -Force
    $entry.cost | Add-Member -NotePropertyName "cacheWrite" -NotePropertyValue 0 -Force
  }

  $visionProvider.models = @($models)

  if ($Payload.PSObject.Properties.Name -contains "agents" -and
      $Payload.agents -is [pscustomobject] -and
      $Payload.agents.PSObject.Properties.Name -contains "defaults" -and
      $Payload.agents.defaults -is [pscustomobject]) {
    if (-not ($Payload.agents.defaults.PSObject.Properties.Name -contains "imageModel") -or $null -eq $Payload.agents.defaults.imageModel) {
      $Payload.agents.defaults | Add-Member -NotePropertyName "imageModel" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $Payload.agents.defaults.imageModel | Add-Member -NotePropertyName "primary" -NotePropertyValue "llama-cpp-vision/$ModelId" -Force
  }

  if ($Payload.PSObject.Properties.Name -contains "tools" -and
      $Payload.tools -is [pscustomobject] -and
      $Payload.tools.PSObject.Properties.Name -contains "media" -and
      $Payload.tools.media -is [pscustomobject]) {
    if (-not ($Payload.tools.media.PSObject.Properties.Name -contains "image") -or $null -eq $Payload.tools.media.image) {
      $Payload.tools.media | Add-Member -NotePropertyName "image" -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $imageTool = $Payload.tools.media.image
    $imageTool | Add-Member -NotePropertyName "enabled" -NotePropertyValue $true -Force
    $imageTool | Add-Member -NotePropertyName "timeoutSeconds" -NotePropertyValue 180 -Force
    $imageTool | Add-Member -NotePropertyName "maxChars" -NotePropertyValue 1200 -Force
    $imageTool | Add-Member -NotePropertyName "models" -NotePropertyValue @(
      [pscustomobject]@{
        provider = "llama-cpp-vision"
        model = $ModelId
        prompt = "Describe the image in detail. If there is text, transcribe it accurately."
        timeoutSeconds = 180
        maxChars = 1200
      }
    ) -Force
  }
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

function Invoke-ManagedOpenClawRestartScript {
  param([string]$Reason = "model-sync")

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
    $safeReason = "model-sync"
  }

  $stdoutPath = Join-Path $logDir ("update-openclaw-restart.{0}.{1}.stdout.log" -f $safeReason, $stamp)
  $stderrPath = Join-Path $logDir ("update-openclaw-restart.{0}.{1}.stderr.log" -f $safeReason, $stamp)
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

  Write-Info "Managed OpenClaw restart launched with PID $($process.Id); runtime health will be verified by start_openclaw/watchdog."
  Write-Info "Restart logs: $stdoutPath ; $stderrPath"
  return $true
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

  if (Test-Path -LiteralPath $openClawRestartPath) {
    [void](Invoke-ManagedOpenClawRestartScript -Reason "model-sync")
    return
  }

  if (Test-Path -LiteralPath $openClawStartPath) {
    & $openClawStartPath
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    if ($exitCode -ne 0) {
      throw "OpenClaw managed startup failed with exit code $exitCode."
    }
    return
  }

  foreach ($taskName in @("OpenClaw Gateway", "OpenClaw Node")) {
    & schtasks.exe /End /TN $taskName *> $null
  }

  $processesToStop = @(
    @(Get-OpenClawGatewayHostProcesses) +
    @(Get-OpenClawNodeHostProcesses) +
    @(Get-OpenClawNodeStartupProcesses)
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
    [Parameter(Mandatory = $true)][int]$ContextWindow,
    [AllowNull()][string]$MmprojPath,
    [string]$VisionBaseUrl = "http://127.0.0.1:8081/v1"
  )

  $llamaPid = ""
  $gatewayListening = Test-HttpReady -Url "http://127.0.0.1:29644/health"
  $managedMediaStatus = Get-OpenClawManagedMediaStatusText
  if (Test-Path -LiteralPath $llamaPidPath) {
    $llamaPid = (Get-Content -LiteralPath $llamaPidPath -TotalCount 1 | Select-Object -First 1).Trim()
  }

  Write-Host ""
  Write-Host "OpenClaw Sync Summary" -ForegroundColor Green
  Write-Host "Model     : $ModelId"
  Write-Host "Primary   : llama-cpp/$ModelId"
  if (-not [string]::IsNullOrWhiteSpace($MmprojPath)) {
    Write-Host "Vision    : llama-cpp-vision/$ModelId"
    Write-Host "Mmproj    : $MmprojPath"
    Write-Host "VisionAPI : $VisionBaseUrl"
  }
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
  $targetModelPath = Resolve-ModelPathFromRuntimeId -ModelId $targetModelId
  $targetMmprojPath = if (-not [string]::IsNullOrWhiteSpace($targetModelPath)) { Find-MmprojForModel -ModelPath $targetModelPath } else { $null }
  $runtimeMmprojPath = Get-RunningPrimaryLlamaMmprojPath
  $visionProviderBaseUrl = if (-not [string]::IsNullOrWhiteSpace($runtimeMmprojPath)) { "http://127.0.0.1:8080/v1" } else { "http://127.0.0.1:8081/v1" }
  $runtimeTokenSnapshot = Get-LlamaRuntimeTokenSnapshot -Path $llamaStdErrLogPath
  $resolvedContextWindow = if ($runtimeTokenSnapshot -and $runtimeTokenSnapshot.ContextTokens) {
    [int]$runtimeTokenSnapshot.ContextTokens
  } else {
    Get-LlamaContextWindowFromLogs -Path $llamaStdErrLogPath -Fallback $(if ($runtimeModel.TrainContext) { $runtimeModel.TrainContext } else { 8192 })
  }
  $resolvedPromptTokens = if ($runtimeTokenSnapshot -and $null -ne $runtimeTokenSnapshot.PromptTokens) { [int]$runtimeTokenSnapshot.PromptTokens } else { $null }
  $targetPrimary = "llama-cpp/$targetModelId"

  Write-Ok "Detected running llama.cpp model $targetModelId"
  if (-not [string]::IsNullOrWhiteSpace($targetMmprojPath)) {
    Write-Ok "Detected matching vision mmproj $targetMmprojPath"
    if (-not [string]::IsNullOrWhiteSpace($runtimeMmprojPath)) {
      Write-Ok "Primary llama.cpp server is running with --mmproj"
    }
  }
  Write-Info "Resolved context window $resolvedContextWindow"
  if ($null -ne $resolvedPromptTokens) {
    Write-Info "Observed last runtime prompt tokens $resolvedPromptTokens"
  }

  $config = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
  [object[]]$removedConfigKeys = @(Remove-DeprecatedOpenClawConfigKeys -Config $config)
  [object[]]$disabledPluginKeys = @(Disable-OpenClawHeavyStartupPlugins -Config $config)
  [object[]]$telegramEnabledKeys = @(
    if (Get-Command Ensure-OpenClawTelegramEnabledConfig -ErrorAction SilentlyContinue) {
      Ensure-OpenClawTelegramEnabledConfig -Config $config
    }
  )
  [object[]]$telegramNetworkKeys = @(
    if (Get-Command Ensure-OpenClawTelegramNetworkConfig -ErrorAction SilentlyContinue) {
      Ensure-OpenClawTelegramNetworkConfig -Config $config
    }
  )
  $currentPrimary = [string]$config.agents.defaults.model.primary
  $previousLlamaModelId = $null

  if ($currentPrimary -like "llama-cpp/*") {
    $previousLlamaModelId = $currentPrimary.Split("/", 2)[1]
  }

  Ensure-LlamaCppModelEntry -Payload $config -ModelId $targetModelId -ContextWindow $resolvedContextWindow
  if (-not [string]::IsNullOrWhiteSpace($targetMmprojPath)) {
    Ensure-LlamaCppVisionModelEntry -Payload $config -ModelId $targetModelId -ContextWindow $resolvedContextWindow -BaseUrl $visionProviderBaseUrl
  }
  Set-JsonNoteProperty -Node $config.agents.defaults.model -Name "primary" -Value $targetPrimary
  Set-JsonNoteProperty -Node $config.agents.defaults -Name "contextTokens" -Value $resolvedContextWindow

  $configBackup = Backup-File -Path $openClawConfigPath -Suffix $targetModelId
  Save-JsonUtf8 -Path $openClawConfigPath -Payload $config
  Write-Ok "Updated openclaw.json -> $targetPrimary"
  Write-Info "Backup written to $configBackup"
  if ($removedConfigKeys.Count -gt 0) {
    Write-Warn "Removed deprecated OpenClaw config keys: $($removedConfigKeys -join ', ')"
  }
  if ($disabledPluginKeys.Count -gt 0) {
    Write-Warn "Disabled heavy OpenClaw startup plugins: $($disabledPluginKeys -join ', ')"
  }
  if ($telegramEnabledKeys.Count -gt 0) {
    Write-Warn "Enabled Telegram config: $($telegramEnabledKeys -join ', ')"
  }
  if ($telegramNetworkKeys.Count -gt 0) {
    Write-Warn "Updated Telegram network config: $($telegramNetworkKeys -join ', ')"
  }

  $agentModels = Get-Content -LiteralPath $agentModelsPath -Raw | ConvertFrom-Json
  Ensure-LlamaCppModelEntry -Payload $agentModels -ModelId $targetModelId -ContextWindow $resolvedContextWindow
  if (-not [string]::IsNullOrWhiteSpace($targetMmprojPath)) {
    Ensure-LlamaCppVisionModelEntry -Payload $agentModels -ModelId $targetModelId -ContextWindow $resolvedContextWindow -BaseUrl $visionProviderBaseUrl
  }

  $agentModelsBackup = Backup-File -Path $agentModelsPath -Suffix $targetModelId
  Save-JsonUtf8 -Path $agentModelsPath -Payload $agentModels
  Write-Ok "Updated agents/main/agent/models.json"
  Write-Info "Backup written to $agentModelsBackup"

  if (-not $SkipSessionUpdate) {
    foreach ($sessionPath in $sessionPaths) {
      if (-not (Test-Path -LiteralPath $sessionPath)) {
        continue
      }

      try {
        $sessions = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
      } catch {
        Write-Warn "Skipping invalid session registry JSON: $sessionPath"
        continue
      }

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
  Show-Summary -ModelId $targetModelId -ContextWindow $resolvedContextWindow -MmprojPath $targetMmprojPath -VisionBaseUrl $visionProviderBaseUrl
} catch {
  Write-Host ""
  Write-Host "Error:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
} finally {
  Pause-BeforeExit
}
