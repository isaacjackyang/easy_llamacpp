[CmdletBinding()]
param(
  [int]$ReadyTimeoutSeconds = 480,
  [int]$ProbeIntervalSeconds = 2,
  [int]$RequiredHealthyProbes = 3
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$logDir = Join-Path $rootDir "logs"
$restartLogStamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
$gatewayStdoutLog = Join-Path $logDir "gateway.stdout.log"
$gatewayStderrLog = Join-Path $logDir "gateway.stderr.log"
$gatewayLauncherStdoutLog = Join-Path $logDir ("gateway-launcher.{0}.stdout.log" -f $restartLogStamp)
$gatewayLauncherStderrLog = Join-Path $logDir ("gateway-launcher.{0}.stderr.log" -f $restartLogStamp)
$nodeLauncherStdoutLog = Join-Path $logDir ("node-launcher.{0}.stdout.log" -f $restartLogStamp)
$nodeLauncherStderrLog = Join-Path $logDir ("node-launcher.{0}.stderr.log" -f $restartLogStamp)
$gatewayTaskName = "OpenClaw Gateway"
$nodeTaskName = "OpenClaw Node"
$watchdogTaskName = "OpenClaw Watchdog"
$stopMarker = Join-Path $rootDir "openclaw.stop"
$gatewayHiddenLauncher = Join-Path $scriptDir "start-openclaw-gateway-hidden.ps1"
$nodeHiddenLauncher = Join-Path $scriptDir "start-openclaw-node-hidden.ps1"
$restartMarker = Join-Path $rootDir "openclaw.restart"
$telegramWatchdogStatePath = Join-Path $logDir "openclaw-watchdog-telegram-state.json"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe)) {
  $powershellExe = "powershell.exe"
}
$watchdogDisabledByRestart = $false

Set-Content -LiteralPath $restartMarker -Value ("restart requested at {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding utf8
trap {
  Remove-Item -LiteralPath $restartMarker -Force -ErrorAction SilentlyContinue
  if ($watchdogDisabledByRestart -and -not (Test-Path -LiteralPath $stopMarker)) {
    & schtasks.exe /Change /TN $watchdogTaskName /ENABLE | Out-Null
  }
  Write-Error $_
  exit 1
}

if (Test-Path -LiteralPath $stopMarker) {
  Remove-Item -LiteralPath $stopMarker -Force
}

function Resolve-GatewayUrls {
  $configPath = Join-Path $rootDir "openclaw.json"
  $defaultPort = 29644
  $port = $defaultPort

  if (Test-Path -LiteralPath $configPath) {
    try {
      $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 100
      if ($null -ne $cfg.gateway -and $null -ne $cfg.gateway.port -and [int]$cfg.gateway.port -gt 0) {
        $port = [int]$cfg.gateway.port
      }
    } catch {
    }
  }

  return @{
    DashboardUrl = "http://127.0.0.1:{0}/" -f $port
    HealthUrl = "http://127.0.0.1:{0}/health" -f $port
  }
}

function Test-TcpEndpoint {
  param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutMilliseconds = 1500
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
      return $false
    }

    $client.EndConnect($async) | Out-Null
    return $true
  } catch {
    return $false
  } finally {
    $client.Dispose()
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

function Test-HttpReachable {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSec = 5
  )

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
    return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
  } catch {
    $response = $_.Exception.Response
    if ($null -ne $response -and $null -ne $response.StatusCode) {
      $code = [int]$response.StatusCode
      return ($code -ge 200 -and $code -lt 500)
    }

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
      Write-Host ("{0} ready: {1}" -f $Name, $Url)
      return
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  throw ("{0} did not become ready: {1}" -f $Name, $Url)
}

function Test-OpenClawNodeRunning {
  return [bool](
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+(?:dist[\\/]+index\.js|openclaw\.mjs)' -and
        $_.CommandLine -match '\bnode\s+run\b'
      } |
      Select-Object -First 1
  )
}

function Test-ProcessCommandLinePattern {
  param([Parameter(Mandatory = $true)][string[]]$Patterns)

  return [bool](
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $commandLine = $_.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
          return $false
        }

        foreach ($pattern in $Patterns) {
          if ($commandLine -match $pattern) {
            return $true
          }
        }

        return $false
      } |
      Select-Object -First 1
  )
}

function Wait-ProcessCommandLinePattern {
  param(
    [Parameter(Mandatory = $true)][string[]]$Patterns,
    [int]$TimeoutSeconds = 10,
    [int]$ProbeIntervalMilliseconds = 500
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-ProcessCommandLinePattern -Patterns $Patterns) {
      return $true
    }

    Start-Sleep -Milliseconds $ProbeIntervalMilliseconds
  }

  return $false
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
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
  } catch {
  }
}

function Invoke-OpenClawTelegramStatusJson {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath,
    [int]$TimeoutSeconds = 25
  )

  $stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMddHHmmssfff"), ([guid]::NewGuid().ToString("N"))
  $stdoutPath = Join-Path $env:TEMP ("openclaw-telegram-status-$stamp.stdout.log")
  $stderrPath = Join-Path $env:TEMP ("openclaw-telegram-status-$stamp.stderr.log")
  $openClawNpmRoot = Split-Path -Parent $OpenClawCommandPath
  $openClawEntry = Join-Path $openClawNpmRoot "node_modules\openclaw\openclaw.mjs"
  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  $statusFilePath = $OpenClawCommandPath
  $statusArguments = @("channels", "status", "--channel", "telegram", "--json")
  if ($nodeCommand -and (Test-Path -LiteralPath $openClawEntry)) {
    $statusFilePath = $nodeCommand.Source
    $statusArguments = @($openClawEntry, "channels", "status", "--channel", "telegram", "--json")
  }
  $process = $null

  try {
    $process = Start-Process `
      -FilePath $statusFilePath `
      -ArgumentList $statusArguments `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -WindowStyle Hidden `
      -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      Stop-ProcessTree -ProcessId $process.Id
      return [pscustomobject]@{
        ExitCode = 124
        Output = ""
        Error = "openclaw telegram status probe timed out after ${TimeoutSeconds}s"
      }
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
    if ($null -eq $stdout) { $stdout = "" }
    if ($null -eq $stderr) { $stderr = "" }
    return [pscustomobject]@{
      ExitCode = [int]$process.ExitCode
      Output = $stdout.Trim()
      Error = $stderr.Trim()
    }
  } finally {
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

    $result = Invoke-OpenClawTelegramStatusJson -OpenClawCommandPath $OpenClawCommandPath -TimeoutSeconds 25
    $text = [string]$result.Output
    if ([int]$result.ExitCode -ne 0) {
      $Detail.Value = "openclaw channels status exited with code $($result.ExitCode)"
      if (-not [string]::IsNullOrWhiteSpace($result.Error)) {
        $Detail.Value += ": $($result.Error)"
      } elseif (-not [string]::IsNullOrWhiteSpace($text)) {
        $Detail.Value += ": $text"
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
    $accounts = @($telegramAccounts)
    if ($accounts.Count -eq 0 -or $null -eq $accounts[0]) {
      $telegramChannel = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $status -Name "channels") -Name "telegram"
      if ($null -eq $telegramChannel) {
        $Detail.Value = "Telegram channel is not present in OpenClaw status."
        return $false
      }

      $probe = Get-ObjectPropertyValue -Object $telegramChannel -Name "probe"
      $probeOk = $null -eq $probe -or (Get-ObjectPropertyValue -Object $probe -Name "ok") -eq $true
      $configured = (Get-ObjectPropertyValue -Object $telegramChannel -Name "configured") -eq $true
      $running = (Get-ObjectPropertyValue -Object $telegramChannel -Name "running") -eq $true
      if ($configured -and $running -and $probeOk) {
        $Detail.Value = "Telegram channel ready."
        return $true
      }

      $Detail.Value = "Telegram channel is not ready yet."
      return $false
    }

    $enabledConfigured = @(
      $accounts |
        Where-Object {
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
    [int]$TimeoutSeconds = 300,
    [int]$ProbeIntervalSeconds = 5
  )

  $openClawCommandPath = Get-OpenClawCommandPath
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $detail = ""
  while ((Get-Date) -lt $deadline) {
    if (Test-OpenClawTelegramReady -OpenClawCommandPath $openClawCommandPath -Detail ([ref]$detail)) {
      Write-Host ("Telegram ready: " + $detail)
      return
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  throw ("Telegram did not become ready. Last status: " + $detail)
}

function Wait-OpenClawNodeRunning {
  param(
    [int]$TimeoutSeconds = 120,
    [int]$ProbeIntervalSeconds = 2,
    [int]$StableSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-OpenClawNodeRunning) {
      Start-Sleep -Seconds $StableSeconds
      if (Test-OpenClawNodeRunning) {
        Write-Host "Node ready: OpenClaw node host is running"
        return
      }
    }

    Start-Sleep -Seconds $ProbeIntervalSeconds
  }

  throw "OpenClaw node host did not become ready."
}

function Invoke-Schtasks {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $output = & schtasks.exe @Arguments 2>&1
  return @{
    ExitCode = $LASTEXITCODE
    Output = ($output | Out-String).Trim()
  }
}

function Reset-TextLog {
  param([Parameter(Mandatory = $true)][string]$Path)

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
  }

  for ($attempt = 1; $attempt -le 40; $attempt += 1) {
    try {
      Set-Content -LiteralPath $Path -Value "" -Encoding utf8
      return
    } catch {
      if ($attempt -ge 40) {
        throw
      }
      Start-Sleep -Milliseconds 250
    }
  }
}

function Get-TextLogTail {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Tail = 40
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return ""
  }

  try {
    return ((Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop | Out-String).Trim())
  } catch {
    return ""
  }
}

function Test-GatewayReadyLog {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  try {
    return [bool](Select-String -LiteralPath $Path -Pattern '\[gateway\]\s+ready\b' -Quiet)
  } catch {
    return $false
  }
}

function Stop-OpenClawProcesses {
  $patterns = @(
    'node_modules[\\/]+openclaw[\\/]+(?:dist[\\/]+index\.js|openclaw\.mjs).*\bgateway\b',
    'node_modules[\\/]+openclaw[\\/]+(?:dist[\\/]+index\.js|openclaw\.mjs).*\bnode\s+run\b',
    [regex]::Escape((Join-Path $rootDir "gateway.cmd")),
    [regex]::Escape((Join-Path $rootDir "node.cmd")),
    [regex]::Escape((Join-Path $rootDir "start-openclaw-node.ps1")),
    [regex]::Escape((Join-Path $rootDir "scripts\run-openclaw-gateway-with-media.ps1")),
    [regex]::Escape($gatewayHiddenLauncher),
    [regex]::Escape($nodeHiddenLauncher)
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

function Stop-TaskIfPresent {
  param([Parameter(Mandatory = $true)][string]$TaskName)

  $result = Invoke-Schtasks -Arguments @("/End", "/TN", $TaskName)
  if ($result.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($result.Output) -and $result.Output -notmatch "ERROR: The system cannot find the file specified") {
    Write-Host ("schtasks /End " + $TaskName + " exited " + $result.ExitCode + "; continuing...")
  }
}

function Enable-TaskIfPresent {
  param([Parameter(Mandatory = $true)][string]$TaskName)

  $result = Invoke-Schtasks -Arguments @("/Change", "/TN", $TaskName, "/ENABLE")
  if ($result.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($result.Output) -and $result.Output -notmatch "ERROR: The system cannot find the file specified") {
    Write-Host ("schtasks /Change /ENABLE " + $TaskName + " exited " + $result.ExitCode + "; continuing...")
  }
}

function Disable-TaskIfPresent {
  param([Parameter(Mandatory = $true)][string]$TaskName)

  $result = Invoke-Schtasks -Arguments @("/Change", "/TN", $TaskName, "/DISABLE")
  if ($result.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($result.Output) -and $result.Output -notmatch "ERROR: The system cannot find the file specified") {
    Write-Host ("schtasks /Change /DISABLE " + $TaskName + " exited " + $result.ExitCode + "; continuing...")
  }
}

function Start-HiddenPowerShellScript {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string]$StdoutLog = "",
    [string]$StderrLog = ""
  )

  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Cannot find startup script: $ScriptPath"
  }

  $startProcessParams = @{
    FilePath = $powershellExe
    ArgumentList = @("-NoLogo", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath)
    WindowStyle = "Hidden"
    PassThru = $true
  }

  if (-not [string]::IsNullOrWhiteSpace($StdoutLog)) {
    $startProcessParams.RedirectStandardOutput = $StdoutLog
  }
  if (-not [string]::IsNullOrWhiteSpace($StderrLog)) {
    $startProcessParams.RedirectStandardError = $StderrLog
  }

  return (Start-Process @startProcessParams)
}

function Start-OpenClawTaskOrHiddenScript {
  param(
    [Parameter(Mandatory = $true)][string]$TaskName,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$ExpectedProcessPatterns = @(),
    [string]$StdoutLog = "",
    [string]$StderrLog = ""
  )

  Enable-TaskIfPresent -TaskName $TaskName
  $runResult = Invoke-Schtasks -Arguments @("/Run", "/TN", $TaskName)
  if ($runResult.ExitCode -eq 0) {
    if ($ExpectedProcessPatterns.Count -eq 0 -or (Wait-ProcessCommandLinePattern -Patterns $ExpectedProcessPatterns -TimeoutSeconds 10)) {
      return $null
    }

    Write-Host ("schtasks /Run " + $TaskName + " returned success but no expected child process appeared; falling back to detached PowerShell launcher...")
  }

  if ($runResult.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($runResult.Output) -and $runResult.Output -notmatch "ERROR: The system cannot find the file specified") {
    Write-Host ("schtasks /Run " + $TaskName + " exited " + $runResult.ExitCode + "; falling back to detached PowerShell launcher...")
  }

  return (Start-HiddenPowerShellScript -ScriptPath $ScriptPath -StdoutLog $StdoutLog -StderrLog $StderrLog)
}

$urls = Resolve-GatewayUrls
$dashboardUrl = $urls.DashboardUrl
$healthUrl = $urls.HealthUrl
$gatewayReadyUrl = $dashboardUrl
$dashboardUri = [Uri]$dashboardUrl
$tcpReadySeen = $false
$gatewayReadyLogSeen = $false
$lastProbeError = $null
$healthyProbeCount = 0

Disable-TaskIfPresent -TaskName $watchdogTaskName
$watchdogDisabledByRestart = $true
Stop-TaskIfPresent -TaskName $nodeTaskName
Stop-TaskIfPresent -TaskName $gatewayTaskName
Stop-OpenClawProcesses
Start-Sleep -Seconds 2
Reset-TextLog -Path $gatewayStdoutLog
Reset-TextLog -Path $gatewayStderrLog
Reset-TextLog -Path $gatewayLauncherStdoutLog
Reset-TextLog -Path $gatewayLauncherStderrLog
Reset-TextLog -Path $nodeLauncherStdoutLog
Reset-TextLog -Path $nodeLauncherStderrLog

$gatewayProcessPatterns = @(
  [regex]::Escape($gatewayHiddenLauncher),
  [regex]::Escape((Join-Path $rootDir "scripts\run-openclaw-gateway-with-media.ps1")),
  'node_modules[\\/]+openclaw[\\/]+(?:dist[\\/]+index\.js|openclaw\.mjs).*\bgateway\b'
)
$nodeProcessPatterns = @(
  [regex]::Escape($nodeHiddenLauncher),
  [regex]::Escape((Join-Path $rootDir "start-openclaw-node.ps1")),
  'node_modules[\\/]+openclaw[\\/]+(?:dist[\\/]+index\.js|openclaw\.mjs).*\bnode\s+run\b'
)

Enable-TaskIfPresent -TaskName $gatewayTaskName
Write-Host ("Starting OpenClaw gateway with hidden launcher: " + $gatewayHiddenLauncher)
$gatewayLauncherProcess = Start-HiddenPowerShellScript -ScriptPath $gatewayHiddenLauncher -StdoutLog $gatewayLauncherStdoutLog -StderrLog $gatewayLauncherStderrLog

Start-Sleep -Seconds 2

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
$ready = $false

while ((Get-Date) -lt $deadline) {
  try {
    if ($null -ne $gatewayLauncherProcess) {
      $gatewayLauncherProcess.Refresh()
      if ($gatewayLauncherProcess.HasExited -and -not (Test-TcpEndpoint -HostName $dashboardUri.Host -Port $dashboardUri.Port)) {
        $lastProbeError = "Gateway launcher exited with code $($gatewayLauncherProcess.ExitCode) before the gateway port opened."
        break
      }
    }
  } catch {
  }

  if (Test-TcpEndpoint -HostName $dashboardUri.Host -Port $dashboardUri.Port) {
    $tcpReadySeen = $true
  }

  if (Test-GatewayReadyLog -Path $gatewayStdoutLog) {
    $gatewayReadyLogSeen = $true
  }

  if ($tcpReadySeen -and $gatewayReadyLogSeen) {
    $ready = $true
    break
  }

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $gatewayReadyUrl -TimeoutSec 5
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
      $healthyProbeCount += 1
      $lastProbeError = $null
      if ($healthyProbeCount -ge $RequiredHealthyProbes) {
        Start-Sleep -Seconds 3
        if (Test-HttpReachable -Url $gatewayReadyUrl -TimeoutSec 10) {
          $ready = $true
          break
        }
        $healthyProbeCount = 0
      }
    } else {
      $healthyProbeCount = 0
    }
  } catch {
    $healthyProbeCount = 0
    $lastProbeError = $_.Exception.Message
  }

  Start-Sleep -Seconds $ProbeIntervalSeconds
}

if (-not $ready) {
  $detail = ""
  if ($tcpReadySeen) {
    $detail = " TCP port is listening, but neither the ready log nor the HTTP gateway endpoint confirmed readiness."
  }
  if (-not [string]::IsNullOrWhiteSpace($lastProbeError)) {
    $detail += " Last probe error: $lastProbeError"
  }
  $launcherStdoutTail = Get-TextLogTail -Path $gatewayLauncherStdoutLog
  $launcherStderrTail = Get-TextLogTail -Path $gatewayLauncherStderrLog
  if (-not [string]::IsNullOrWhiteSpace($launcherStdoutTail)) {
    $detail += " Gateway launcher stdout tail: $launcherStdoutTail"
  }
  if (-not [string]::IsNullOrWhiteSpace($launcherStderrTail)) {
    $detail += " Gateway launcher stderr tail: $launcherStderrTail"
  }

  throw ("Gateway did not become ready after restart: " + $gatewayReadyUrl + $detail)
}

Enable-TaskIfPresent -TaskName $nodeTaskName
Write-Host ("Starting OpenClaw node with hidden launcher: " + $nodeHiddenLauncher)
Start-HiddenPowerShellScript -ScriptPath $nodeHiddenLauncher -StdoutLog $nodeLauncherStdoutLog -StderrLog $nodeLauncherStderrLog | Out-Null
Write-Host ("Gateway ready: " + $dashboardUrl)
Wait-HttpReady -Name "TTS" -Url "http://127.0.0.1:8000/health" -TimeoutSeconds 120
Wait-HttpReady -Name "STT" -Url "http://127.0.0.1:8001/health" -TimeoutSeconds 120
Wait-HttpReady -Name "Vision" -Url "http://127.0.0.1:8081/v1/models" -TimeoutSeconds 120
Wait-OpenClawNodeRunning -TimeoutSeconds 600
Write-Host "Telegram readiness will be checked by watchdog after the core stack is healthy."
Remove-Item -LiteralPath $telegramWatchdogStatePath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $restartMarker -Force -ErrorAction SilentlyContinue
Enable-TaskIfPresent -TaskName $watchdogTaskName
$watchdogDisabledByRestart = $false
Write-Host "OpenClaw stack ready: Vision, TTS, STT, Gateway, and Node are running. Telegram readiness is monitored by watchdog."
