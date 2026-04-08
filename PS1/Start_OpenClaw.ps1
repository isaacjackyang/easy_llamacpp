[CmdletBinding()]
param(
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$syncScriptPath = Join-Path $PSScriptRoot "Update_OpenClaw_Status.ps1"
$llamaModelsUrl = "http://127.0.0.1:8080/v1/models"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$openClawConfigPath = Join-Path $openClawRoot "openclaw.json"
$gatewayScriptPath = Join-Path $openClawRoot "gateway.cmd"
$nodeScriptPath = Join-Path $openClawRoot "node.cmd"

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

  return @($removedKeys)
}

function Repair-OpenClawConfigIfNeeded {
  if (-not (Test-Path -LiteralPath $openClawConfigPath)) {
    return
  }

  $config = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
  $removedKeys = @(Remove-DeprecatedOpenClawConfigKeys -Config $config)
  if ($removedKeys.Count -eq 0) {
    return
  }

  $configBackup = Backup-File -Path $openClawConfigPath -Suffix "deprecated-config-cleanup"
  Save-JsonUtf8 -Path $openClawConfigPath -Payload $config
  Write-Warn "Removed deprecated OpenClaw config keys: $($removedKeys -join ', ')"
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
    Output   = ((@($output) | ForEach-Object { [string]$_.ToString().TrimEnd() }) -join [Environment]::NewLine).Trim()
  }
}

function Invoke-OpenClawRestart {
  param([Parameter(Mandatory = $true)][string]$OpenClawCommandPath)

  Write-Info "Stopping any existing OpenClaw gateway/node processes"
  Stop-OpenClawRuntime

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
        ($_.Name -eq "node.exe" -and $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+dist[\\/]+index\.js' -and $_.CommandLine -match '\bnode\s+run\b') -or
        ($_.Name -like "powershell*.exe" -and $_.CommandLine -match 'start-openclaw-node\.ps1') -or
        ($_.Name -eq "cmd.exe" -and $_.CommandLine -match 'node\.cmd')
      }
  )
}

function Stop-OpenClawRuntime {
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
}

function Wait-OpenClawNodeHost {
  param([int]$TimeoutSeconds = 30)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-OpenClawNodeHostProcesses).Count -gt 0) {
      return $true
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
    $scriptResult = Invoke-Capture -FilePath "powershell.exe" -Arguments @(
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $syncScriptPath,
      "-RestartOpenClaw",
      "-NoPause"
    )
  } else {
    $scriptResult = Invoke-Capture -FilePath $powershellExe -Arguments @(
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $syncScriptPath,
      "-RestartOpenClaw",
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
      $scriptResult = Invoke-Capture -FilePath "powershell.exe" -Arguments @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $syncScriptPath,
        "-RestartOpenClaw",
        "-NoPause"
      )
    } else {
      $scriptResult = Invoke-Capture -FilePath $powershellExe -Arguments @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $syncScriptPath,
        "-RestartOpenClaw",
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
  if (-not (Wait-TcpPort -TargetHost "127.0.0.1" -Port 29644 -TimeoutSeconds 60 -ProbeIntervalSeconds 2)) {
    if (@(Get-OpenClawGatewayHostProcesses).Count -eq 0) {
      Write-Warn "Gateway process was not detected after the restart. Launching gateway.cmd directly."
      Start-BackgroundCmd -ScriptPath $gatewayScriptPath
    } else {
      Write-Warn "Gateway process exists but 127.0.0.1:29644 is still warming up. Waiting a bit longer."
    }

    if (-not (Wait-TcpPort -TargetHost "127.0.0.1" -Port 29644 -TimeoutSeconds 60 -ProbeIntervalSeconds 2)) {
      throw "OpenClaw gateway did not become ready on 127.0.0.1:29644."
    }
  }

  Write-Ok "OpenClaw gateway is listening on 127.0.0.1:29644"

  if (-not (Wait-OpenClawNodeHost -TimeoutSeconds 45)) {
    Write-Warn "Node host was not detected after the service restart. Launching node.cmd directly."
    Start-BackgroundCmd -ScriptPath $nodeScriptPath

    if (-not (Wait-OpenClawNodeHost -TimeoutSeconds 60)) {
      throw "OpenClaw node host did not stay running."
    }
  }

  Write-Ok "OpenClaw node host is running"
}

function Show-Summary {
  param([Parameter(Mandatory = $true)][bool]$ModelSyncPerformed)

  $activeModelId = Get-RunningLlamaModelId -ModelsUrl $llamaModelsUrl
  $gatewayListening = Test-TcpPort -TargetHost "127.0.0.1" -Port 29644
  $nodeProcesses = @(Get-OpenClawNodeHostProcesses)

  Write-Host ""
  Write-Host "OpenClaw Start Summary" -ForegroundColor Green
  Write-Host ("ModelSync : {0}" -f $(if ($ModelSyncPerformed) { "synced to the running llama.cpp model" } else { "not performed (no llama.cpp server)" }))
  if (-not [string]::IsNullOrWhiteSpace($activeModelId)) {
    Write-Host "Model     : $activeModelId"
  }
  Write-Host ("Gateway   : {0}" -f $(if ($gatewayListening) { "listening on 127.0.0.1:29644" } else { "not listening" }))
  Write-Host ("Node      : {0}" -f $(if ($nodeProcesses.Count -gt 0) { "running ($($nodeProcesses.Count) process entry/entries)" } else { "not detected" }))
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

try {
  $openClawCommandPath = Get-OpenClawCommandPath
  Repair-OpenClawConfigIfNeeded
  $hasRunningLlama = Test-LlamaServerAvailable -ModelsUrl $llamaModelsUrl

  if ($hasRunningLlama) {
    Write-Info "Detected a running llama.cpp server. Syncing OpenClaw to the active model and restarting services."
    Invoke-SyncCurrentModel
  } else {
    Write-Info "No running llama.cpp server detected. Starting OpenClaw with the existing configuration."
    Invoke-OpenClawRestart -OpenClawCommandPath $openClawCommandPath
  }

  Ensure-OpenClawRuntime
  Show-Summary -ModelSyncPerformed:$hasRunningLlama
} catch {
  Write-Host ""
  Write-Host "Error:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
} finally {
  Pause-BeforeExit
}
