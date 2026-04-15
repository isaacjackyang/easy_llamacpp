[CmdletBinding()]
param(
  [int]$ReadyTimeoutSeconds = 240,
  [switch]$SkipLlamaStart,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$targetModelId = "gemma-4-31B-it-RotorQuant-Q5_K_M.gguf"
$targetModelPath = "E:\LLM Model\gemma-4-31B-it-RotorQuant-Q5_K_M.gguf"
$llamaModelsUrl = "http://127.0.0.1:8080/v1/models"
$llamaLauncherPath = Join-Path $projectRoot "Start.cmd"
$openClawLauncherPath = Join-Path $PSScriptRoot "Start_OpenClaw.ps1"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Write-Info {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "[INFO] $Message"
}

function Write-Ok {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "[ OK ] $Message"
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
      }
      elseif ($null -ne $response.models) {
        $availableIds = @($response.models | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "model") {
              [string]$_.model
            }
            else {
              [string]$_.name
            }
          })
      }

      if ($availableIds -contains $ExpectedModelId) {
        return
      }
    }
    catch {
    }

    Start-Sleep -Seconds 2
  }

  throw "llama.cpp did not report $ExpectedModelId on $llamaModelsUrl within $TimeoutSeconds seconds."
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
  if (-not (Test-Path -LiteralPath $llamaLauncherPath)) {
    throw "Cannot find llama.cpp launcher: $llamaLauncherPath"
  }

  if (-not (Test-Path -LiteralPath $openClawLauncherPath)) {
    throw "Cannot find OpenClaw launcher: $openClawLauncherPath"
  }

  if (-not $SkipLlamaStart) {
    Write-Info "Starting llama.cpp with $targetModelId"
    Write-Info "RotorQuant KV cache flags: --cache-type-k planar3 --cache-type-v iso3"
    $llamaArguments = @(
      "-BypassMenu",
      "-Background",
      "-NoPause",
      "-OpenPath", "/",
      "-GpuLayers", "auto",
      "-ModelPath", $targetModelPath,
      "--ctx-size", "110000",
      "--fit-target", "0,0",
      "--cache-ram", "0",
      "--parallel", "1",
      "--cache-type-k", "planar3",
      "--cache-type-v", "iso3",
      "--temp", "0.7",
      "--top-k", "20",
      "--top-p", "0.8",
      "--min-p", "0",
      "--presence-penalty", "1.5",
      "--seed", "42"
    )
    Invoke-Checked -FilePath $llamaLauncherPath -Arguments $llamaArguments
  }
  else {
    Write-Info "Skipping llama.cpp launcher because -SkipLlamaStart was provided."
  }

  Write-Info "Waiting for llama.cpp to report $targetModelId"
  Wait-LlamaModelReady -ExpectedModelId $targetModelId -TimeoutSeconds $ReadyTimeoutSeconds
  Write-Ok "llama.cpp is serving $targetModelId"

  Write-Info "Starting and syncing OpenClaw"
  $openClawArguments = @(
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $openClawLauncherPath,
    "-NoPause"
  )

  if (-not (Test-Path -LiteralPath $powershellExe)) {
    Invoke-Checked -FilePath "powershell.exe" -Arguments $openClawArguments
  }
  else {
    Invoke-Checked -FilePath $powershellExe -Arguments $openClawArguments
  }
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
