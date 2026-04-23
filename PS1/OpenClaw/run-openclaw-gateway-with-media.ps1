$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

function Report-ManagedServiceReadiness {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$HealthUrl,
    [int]$TimeoutSec = 2
  )

  if (Test-HttpHealth -Url $HealthUrl -TimeoutSec $TimeoutSec) {
    Write-Host "$Name is healthy at $HealthUrl" -ForegroundColor Green
    return
  }

  Write-Warning "$Name is still starting; continuing without blocking the gateway."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$workspaceDir = Join-Path $rootDir "workspace"
$logDir = Join-Path $rootDir "logs"

$gatewayPort = if ($env:OPENCLAW_GATEWAY_PORT) { [int]$env:OPENCLAW_GATEWAY_PORT } else { 29644 }
$nodeExe = "C:\Program Files\nodejs\node.exe"
$gatewayCli = "C:\Users\JackYang\AppData\Roaming\npm\node_modules\openclaw\dist\index.js"

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
$gatewayStdoutLog = Join-Path $logDir "gateway.stdout.log"
$gatewayStderrLog = Join-Path $logDir "gateway.stderr.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if (-not (Test-Path -LiteralPath $nodeExe)) {
  throw "Node.js was not found at $nodeExe"
}
if (-not (Test-Path -LiteralPath $gatewayCli)) {
  throw "OpenClaw gateway entrypoint was not found at $gatewayCli"
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

$managedProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$selfProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
$launcherParentId = if ($null -ne $selfProcess) { [int]$selfProcess.ParentProcessId } else { 0 }
$gatewayExitCode = 1

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

  Start-Sleep -Seconds 2
  Report-ManagedServiceReadiness -Name "TTS" -HealthUrl $ttsHealthUrl
  Report-ManagedServiceReadiness -Name "STT" -HealthUrl $sttHealthUrl

  Write-Step "Starting OpenClaw gateway"
  Set-Content -LiteralPath $gatewayStdoutLog -Value "" -Encoding utf8
  Set-Content -LiteralPath $gatewayStderrLog -Value "" -Encoding utf8
  $gatewayProcess = Start-Process `
    -FilePath $nodeExe `
    -ArgumentList @($gatewayCli, "gateway", "--port", "$gatewayPort") `
    -WorkingDirectory $rootDir `
    -RedirectStandardOutput $gatewayStdoutLog `
    -RedirectStandardError $gatewayStderrLog `
    -PassThru
  $managedProcesses.Add($gatewayProcess)

  $gatewayExitCode = Wait-GatewayExit `
    -GatewayProcess $gatewayProcess `
    -LauncherParentId $launcherParentId
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
