[CmdletBinding()]
param(
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$workspaceDir = Join-Path $openClawRoot "workspace"
$logDir = Join-Path $openClawRoot "logs"
$gatewayScriptPath = Join-Path $openClawRoot "gateway.cmd"
$managedGatewayScriptName = "run-openclaw-gateway-with-media.ps1"

$services = @(
  [pscustomobject]@{
    Name = "TTS"
    PythonPath = "C:\Users\JackYang\Miniconda3\envs\qwen3-tts-fa2-test\python.exe"
    ScriptPath = Join-Path $workspaceDir "tts_server.py"
    CommandLinePattern = 'workspace[\\/]+tts_server\.py'
    HealthUrl = "http://127.0.0.1:8000/health"
    Host = "127.0.0.1"
    Port = 8000
    ReadyTimeoutSeconds = 180
    StdoutLog = Join-Path $logDir "tts-server.stdout.log"
    StderrLog = Join-Path $logDir "tts-server.stderr.log"
  }
  [pscustomobject]@{
    Name = "STT"
    PythonPath = "C:\Users\JackYang\Miniconda3\envs\qwen3-asr\python.exe"
    ScriptPath = Join-Path $workspaceDir "stt_server.py"
    CommandLinePattern = 'workspace[\\/]+stt_server\.py'
    HealthUrl = "http://127.0.0.1:8001/health"
    Host = "127.0.0.1"
    Port = 8001
    ReadyTimeoutSeconds = 240
    StdoutLog = Join-Path $logDir "stt-server.stdout.log"
    StderrLog = Join-Path $logDir "stt-server.stderr.log"
  }
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

function Invoke-HealthRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSec = 2
  )

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
      return $null
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
      return [pscustomobject]@{}
    }

    return ($response.Content | ConvertFrom-Json)
  }
  catch {
    return $null
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

function Get-VoiceServiceProcesses {
  param([Parameter(Mandatory = $true)][string]$CommandLinePattern)

  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $commandLine = $_.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
          return $false
        }

        $commandLine -match $CommandLinePattern
      }
  )
}

function Stop-VoiceServiceProcesses {
  param([Parameter(Mandatory = $true)][string]$CommandLinePattern)

  $processes = @(Get-VoiceServiceProcesses -CommandLinePattern $CommandLinePattern)
  foreach ($process in $processes) {
    try {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
    catch {
    }
  }

  return @($processes)
}

function Start-ManagedProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$StdoutLog,
    [Parameter(Mandatory = $true)][string]$StderrLog
  )

  Set-Content -LiteralPath $StdoutLog -Value "" -Encoding utf8
  Set-Content -LiteralPath $StderrLog -Value "" -Encoding utf8

  $process = Start-Process `
    -FilePath $FilePath `
    -ArgumentList @($ScriptPath) `
    -WorkingDirectory $WorkingDirectory `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -PassThru

  Write-Ok "$Name started with PID $($process.Id)"
  return $process
}

function Wait-ManagedService {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][string]$HealthUrl,
    [Parameter(Mandatory = $true)][string]$StdoutLog,
    [Parameter(Mandatory = $true)][string]$StderrLog,
    [int]$ReadyTimeoutSeconds = 180,
    [int]$ProbeIntervalSeconds = 2
  )

  $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $Process.Refresh()
      if ($Process.HasExited) {
        break
      }
    }
    catch {
      break
    }

    $healthPayload = Invoke-HealthRequest -Url $HealthUrl -TimeoutSec 2
    if ($null -ne $healthPayload) {
      Write-Ok "$Name is healthy at $HealthUrl"
      return $healthPayload
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

function Assert-ServicePaths {
  param([Parameter(Mandatory = $true)][object]$Service)

  if (-not (Test-Path -LiteralPath $Service.PythonPath)) {
    throw "$($Service.Name) Python was not found at $($Service.PythonPath)"
  }

  if (-not (Test-Path -LiteralPath $Service.ScriptPath)) {
    throw "$($Service.Name) server script was not found at $($Service.ScriptPath)"
  }
}

function Ensure-VoiceService {
  param([Parameter(Mandatory = $true)][object]$Service)

  Assert-ServicePaths -Service $Service

  $existingHealth = Invoke-HealthRequest -Url $Service.HealthUrl -TimeoutSec 2
  if ($null -ne $existingHealth) {
    Write-Ok "$($Service.Name) is already healthy on $($Service.Host):$($Service.Port)"
    return [pscustomobject]@{
      Name = $Service.Name
      ProcessId = $null
      Health = $existingHealth
      Action = "already-running"
    }
  }

  $staleProcesses = @(Stop-VoiceServiceProcesses -CommandLinePattern $Service.CommandLinePattern)
  if ($staleProcesses.Count -gt 0) {
    Write-Warn "Stopped stale $($Service.Name) process(es): $($staleProcesses.ProcessId -join ', ')"
    Start-Sleep -Seconds 1
  }

  $process = Start-ManagedProcess `
    -Name $Service.Name `
    -FilePath $Service.PythonPath `
    -ScriptPath $Service.ScriptPath `
    -WorkingDirectory $workspaceDir `
    -StdoutLog $Service.StdoutLog `
    -StderrLog $Service.StderrLog

  $healthPayload = Wait-ManagedService `
    -Name $Service.Name `
    -Process $process `
    -HealthUrl $Service.HealthUrl `
    -StdoutLog $Service.StdoutLog `
    -StderrLog $Service.StderrLog `
    -ReadyTimeoutSeconds $Service.ReadyTimeoutSeconds

  return [pscustomobject]@{
    Name = $Service.Name
    ProcessId = $process.Id
    Health = $healthPayload
    Action = "started"
  }
}

function Show-Summary {
  param([Parameter(Mandatory = $true)][object[]]$Results)

  Write-Host ""
  Write-Host "Voice Service Start Summary" -ForegroundColor Green
  foreach ($result in $Results) {
    $health = $result.Health
    $model = if ($null -ne $health -and $health.PSObject.Properties.Name -contains "model") { [string]$health.model } else { "unknown" }
    $port = if ($null -ne $health -and $health.PSObject.Properties.Name -contains "port") { [string]$health.port } else { "unknown" }

    if ($result.Name -eq "TTS") {
      $speaker = if ($null -ne $health -and $health.PSObject.Properties.Name -contains "defaultSpeaker") { [string]$health.defaultSpeaker } else { "unknown" }
      Write-Host ("TTS   : {0} on 127.0.0.1:{1} | model {2} | speaker {3}" -f $result.Action, $port, $model, $speaker)
    }
    else {
      $device = if ($null -ne $health -and $health.PSObject.Properties.Name -contains "device") { [string]$health.device } else { "unknown" }
      $language = if ($null -ne $health -and $health.PSObject.Properties.Name -contains "defaultLanguage") { [string]$health.defaultLanguage } else { "unknown" }
      Write-Host ("STT   : {0} on 127.0.0.1:{1} | model {2} | default lang {3} | device {4}" -f $result.Action, $port, $model, $language, $device)
    }
  }
  Write-Host "Logs  : $logDir"
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
  }
  catch {
  }
}

try {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null

  if (Test-OpenClawGatewayUsesManagedMedia -and @(Get-OpenClawGatewayHostProcesses).Count -gt 0) {
    Write-Warn "OpenClaw gateway is currently running. Restarting standalone TTS/STT may briefly interrupt gateway audio features."
  }

  $results = foreach ($service in $services) {
    Write-Info "Ensuring $($service.Name) is running on $($service.Host):$($service.Port)"
    Ensure-VoiceService -Service $service
  }

  Show-Summary -Results @($results)
}
catch {
  Write-Host ""
  Write-Host "Error:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
}
finally {
  Pause-BeforeExit
}
