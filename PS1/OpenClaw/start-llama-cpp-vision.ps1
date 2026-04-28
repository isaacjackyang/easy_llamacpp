[CmdletBinding()]
param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 8081,
  [int]$ReadyTimeoutSeconds = 240,
  [switch]$Stop,
  [switch]$NoDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$logDir = Join-Path $root "logs"
$pidPath = Join-Path $logDir "llama-vision-server.pid"
$stdoutLog = Join-Path $logDir "llama-vision-server.stdout.log"
$stderrLog = Join-Path $logDir "llama-vision-server.stderr.log"

$modelPath = "E:\LLM Model\Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-Q8_0.gguf"
$mmprojPath = "E:\LLM Model\Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-mmproj-f16.gguf"
$mmprojUrl = "https://huggingface.co/HauhauCS/Qwen3VL-8B-Uncensored-HauhauCS-Aggressive/resolve/main/Qwen3VL-8B-Uncensored-HauhauCS-Aggressive-mmproj-f16.gguf"
$preferredServer = "F:\Documents\GitHub\easy_llamacpp\bin\llama-server.exe"
$temperature = "0.35"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Resolve-LlamaServer {
  if (Test-Path -LiteralPath $preferredServer) {
    return $preferredServer
  }

  $cmd = Get-Command llama-server -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    return $cmd.Source
  }

  throw "Cannot find llama-server.exe. Expected $preferredServer or llama-server in PATH."
}

function Test-TcpPort {
  param(
    [Parameter(Mandatory = $true)][string]$TargetHost,
    [Parameter(Mandatory = $true)][int]$TargetPort,
    [int]$TimeoutMs = 1000
  )

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $async = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      return $false
    }

    $client.EndConnect($async)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Test-VisionModelReady {
  try {
    $response = Invoke-RestMethod -Uri "http://${HostName}:${Port}/v1/models" -TimeoutSec 5
    $ids = @()
    if ($null -ne $response.data) {
      $ids = @($response.data | ForEach-Object { [string]$_.id })
    } elseif ($null -ne $response.models) {
      $ids = @($response.models | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains "model") {
          [string]$_.model
        } else {
          [string]$_.name
        }
      })
    }

    return ($ids -contains (Split-Path -Leaf $modelPath))
  } catch {
    return $false
  }
}

function Get-TrackedProcess {
  if (-not (Test-Path -LiteralPath $pidPath)) {
    return $null
  }

  $raw = (Get-Content -LiteralPath $pidPath -TotalCount 1 -ErrorAction SilentlyContinue | Select-Object -First 1)
  $pidValue = 0
  if (-not [int]::TryParse([string]$raw, [ref]$pidValue)) {
    return $null
  }

  return Get-Process -Id $pidValue -ErrorAction SilentlyContinue
}

function Stop-TrackedProcess {
  $process = Get-TrackedProcess
  if ($process) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }

  Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

function Stop-PortProcessIfVision {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -eq "llama-server.exe" -and
      $_.CommandLine -match "\b--port\s+$Port\b" -and
      $_.CommandLine -match [regex]::Escape($modelPath)
    } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Test-VisionServerUsesDesiredTemperature {
  $pattern = '(?:--temp(?:erature)?(?:=|\s+))' + [regex]::Escape($temperature) + '(?:\s|$)'

  return [bool](
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq "llama-server.exe" -and
        $_.CommandLine -match "\b--port\s+$Port\b" -and
        $_.CommandLine -match [regex]::Escape($modelPath) -and
        $_.CommandLine -match $pattern
      } |
      Select-Object -First 1
  )
}

function Ensure-Mmproj {
  if (Test-Path -LiteralPath $mmprojPath) {
    return $mmprojPath
  }

  if ($NoDownload) {
    return $null
  }

  $tmpPath = "$mmprojPath.download"
  Write-Host "Downloading mmproj to $mmprojPath"
  Invoke-WebRequest -UseBasicParsing -Uri $mmprojUrl -OutFile $tmpPath
  Move-Item -LiteralPath $tmpPath -Destination $mmprojPath -Force
  return $mmprojPath
}

function Wait-Ready {
  $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-VisionModelReady) {
      return $true
    }

    Start-Sleep -Seconds 2
  }

  return $false
}

function ConvertTo-ProcessArgumentLine {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  ($Arguments | ForEach-Object {
    $argument = [string]$_
    if ($argument -notmatch '[\s"]') {
      return $argument
    }

    '"' + ($argument -replace '"', '\"') + '"'
  }) -join " "
}

if ($Stop) {
  Stop-TrackedProcess
  Stop-PortProcessIfVision
  exit 0
}

if (-not (Test-Path -LiteralPath $modelPath)) {
  throw "Cannot find vision model: $modelPath"
}

if ((Test-VisionModelReady) -and (Test-VisionServerUsesDesiredTemperature)) {
  Write-Host "Vision llama-server is already ready on http://${HostName}:${Port}/v1"
  exit 0
}

if (Test-VisionModelReady) {
  Write-Host "Vision llama-server is ready but not using --temp $temperature; restarting it."
}

if (Test-TcpPort -TargetHost $HostName -TargetPort $Port) {
  Stop-TrackedProcess
  Stop-PortProcessIfVision
  Start-Sleep -Seconds 2
  if (Test-TcpPort -TargetHost $HostName -TargetPort $Port) {
    throw "Port $Port is already in use, but it is not serving the expected Qwen3VL vision model."
  }
}

Stop-TrackedProcess
Stop-PortProcessIfVision

$serverExe = Resolve-LlamaServer
$resolvedMmprojPath = Ensure-Mmproj

$args = New-Object System.Collections.Generic.List[string]
$args.Add("-m")
$args.Add($modelPath)
$args.Add("--port")
$args.Add([string]$Port)
$args.Add("--host")
$args.Add($HostName)
$args.Add("--ctx-size")
$args.Add("32768")
$args.Add("--threads")
$args.Add([string]([Math]::Max(1, [Environment]::ProcessorCount - 2)))
$args.Add("--threads-batch")
$args.Add([string][Environment]::ProcessorCount)
$args.Add("--parallel")
$args.Add("2")
$args.Add("--cache-ram")
$args.Add("2048")
$args.Add("--flash-attn")
$args.Add("auto")
$args.Add("--image-min-tokens")
$args.Add("1024")
$args.Add("--temp")
$args.Add($temperature)
if ($resolvedMmprojPath) {
  $args.Add("--mmproj")
  $args.Add($resolvedMmprojPath)
} else {
  $args.Add("--mmproj-url")
  $args.Add($mmprojUrl)
}

Set-Content -LiteralPath $stdoutLog -Value "" -Encoding utf8
Set-Content -LiteralPath $stderrLog -Value "" -Encoding utf8

$process = Start-Process `
  -FilePath $serverExe `
  -ArgumentList (ConvertTo-ProcessArgumentLine -Arguments ($args.ToArray())) `
  -WorkingDirectory (Split-Path -Parent $serverExe) `
  -RedirectStandardOutput $stdoutLog `
  -RedirectStandardError $stderrLog `
  -WindowStyle Hidden `
  -PassThru

Set-Content -LiteralPath $pidPath -Value $process.Id -Encoding ASCII

if (Wait-Ready) {
  Write-Host "Vision llama-server ready on http://${HostName}:${Port}/v1"
  exit 0
}

$stderrTail = ""
if (Test-Path -LiteralPath $stderrLog) {
  $stderrTail = (Get-Content -LiteralPath $stderrLog -Tail 40 | Out-String).Trim()
}

throw "Vision llama-server did not become ready within $ReadyTimeoutSeconds seconds. Log: $stderrLog`n$stderrTail"
