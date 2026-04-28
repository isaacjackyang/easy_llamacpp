$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$logDir = Join-Path $rootDir "logs"
$watchdogLog = Join-Path $logDir "openclaw-watchdog.log"
$restartScript = Join-Path $scriptDir "restart-openclaw-gateway.ps1"
$telegramProbeScript = Join-Path $scriptDir "probe-openclaw-telegram-status.mjs"
$stopMarker = Join-Path $rootDir "openclaw.stop"
$restartMarker = Join-Path $rootDir "openclaw.restart"
$gatewayTcpStartupGraceMinutes = 10
$restartMarkerGraceMinutes = 12
$telegramStartupGraceSeconds = 420
$staleTelegramProbeAgeSeconds = 30
$failureStatePath = Join-Path $logDir "openclaw-watchdog-state.json"
$telegramStatePath = Join-Path $logDir "openclaw-watchdog-telegram-state.json"
$easyLlamacppRoot = if (-not [string]::IsNullOrWhiteSpace($env:EASY_LLAMACPP_ROOT)) { $env:EASY_LLAMACPP_ROOT } else { "F:\Documents\GitHub\easy_llamacpp" }
$pluginStageDir = Join-Path $easyLlamacppRoot ".openclaw-plugin-stage"
$transientDir = Join-Path $pluginStageDir "watchdog-tmp"
$coreFailureThreshold = 2
$telegramProbeIntervalSeconds = 60
$telegramProbeTimeoutSeconds = 60
$telegramFailureThreshold = 2
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe)) {
  $powershellExe = "powershell.exe"
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path $transientDir | Out-Null

if (Test-Path -LiteralPath $stopMarker) {
  exit 0
}

function Write-WatchdogLog {
  param([Parameter(Mandatory = $true)][string]$Message)

  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -LiteralPath $watchdogLog -Value ("[{0}] {1}" -f $stamp, $Message)
}

function Get-WatchdogFailureCounts {
  $counts = @{}
  if (-not (Test-Path -LiteralPath $failureStatePath)) {
    return $counts
  }

  try {
    $state = Get-Content -LiteralPath $failureStatePath -Raw | ConvertFrom-Json
    foreach ($property in @($state.PSObject.Properties)) {
      $counts[$property.Name] = [int]$property.Value
    }
  } catch {
  }

  return $counts
}

function Save-WatchdogFailureCounts {
  param([Parameter(Mandatory = $true)][hashtable]$Counts)

  $data = [ordered]@{}
  foreach ($name in @($Counts.Keys | Sort-Object)) {
    $value = [int]$Counts[$name]
    if ($value -gt 0) {
      $data[$name] = $value
    }
  }

  if ($data.Count -eq 0) {
    Remove-Item -LiteralPath $failureStatePath -Force -ErrorAction SilentlyContinue
    return
  }

  $data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $failureStatePath -Encoding utf8
}

function Test-ExternalRestartInProgress {
  return [bool](
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine -match 'restart-openclaw-gateway\.ps1'
      } |
      Select-Object -First 1
  )
}

function Test-RestartMarkerFresh {
  if (-not (Test-Path -LiteralPath $restartMarker)) {
    return $false
  }

  try {
    $marker = Get-Item -LiteralPath $restartMarker -ErrorAction Stop
    return ($marker.LastWriteTime -gt (Get-Date).AddMinutes(-1 * $restartMarkerGraceMinutes))
  } catch {
    return $false
  }
}

function Start-DetachedRestart {
  param([Parameter(Mandatory = $true)][string[]]$FailedChecks)

  if (-not (Test-Path -LiteralPath $restartScript)) {
    throw "Cannot find OpenClaw restart script: $restartScript"
  }

  $stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
  $stdoutPath = Join-Path $logDir ("watchdog-restart.{0}.stdout.log" -f $stamp)
  $stderrPath = Join-Path $logDir ("watchdog-restart.{0}.stderr.log" -f $stamp)

  Remove-Item -LiteralPath $telegramStatePath -Force -ErrorAction SilentlyContinue
  Set-Content -LiteralPath $restartMarker -Value ("watchdog restart requested at {0}; failed checks: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), ($FailedChecks -join ", ")) -Encoding utf8
  Write-WatchdogLog ("Dispatching detached restart for failed checks: {0}" -f ($FailedChecks -join ", "))
  try {
    Start-Process `
      -FilePath $powershellExe `
      -ArgumentList @("-NoLogo", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $restartScript) `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -WindowStyle Hidden `
      -PassThru | Out-Null
  } catch {
    Remove-Item -LiteralPath $restartMarker -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Test-HttpReady {
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

function Test-HttpReachable {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSec = 2
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

function Get-GatewayHostProcess {
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq "node.exe" -and
        $_.CommandLine -and
        $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+(?:dist[\\/]+index\.js|openclaw\.mjs)' -and
        $_.CommandLine -match '\bgateway\b'
      } |
      Sort-Object CreationDate -Descending |
      Select-Object -First 1
  )
}

function Get-CimProcessStartTime {
  param([Parameter(Mandatory = $true)]$Process)

  try {
    if ($null -ne $Process.CreationDate) {
      $value = [string]$Process.CreationDate
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($value)
      }
    }
  } catch {
  }

  try {
    return (Get-Process -Id ([int]$Process.ProcessId) -ErrorAction Stop).StartTime
  } catch {
    return $null
  }
}

function Test-GatewayWithinStartupGrace {
  $gatewayProcess = @(Get-GatewayHostProcess | Select-Object -First 1)
  if ($gatewayProcess.Count -eq 0) {
    return $false
  }

  try {
    $createdAt = Get-CimProcessStartTime -Process $gatewayProcess[0]
    if ($null -eq $createdAt) {
      return $false
    }
    return ($createdAt -gt (Get-Date).AddMinutes(-1 * $gatewayTcpStartupGraceMinutes))
  } catch {
    return $false
  }
}

function Test-GatewayWithinTelegramGrace {
  $gatewayProcess = @(Get-GatewayHostProcess | Select-Object -First 1)
  if ($gatewayProcess.Count -eq 0) {
    return $false
  }

  try {
    $createdAt = Get-CimProcessStartTime -Process $gatewayProcess[0]
    if ($null -eq $createdAt) {
      return $false
    }
    return ((Get-Date) - $createdAt).TotalSeconds -lt $telegramStartupGraceSeconds
  } catch {
    return $false
  }
}

function Test-GatewayReachable {
  if ((Test-TcpEndpoint -HostName "127.0.0.1" -Port 29644) -and (@(Get-GatewayHostProcess).Count -gt 0)) {
    return $true
  }

  if (Test-HttpReachable -Url "http://127.0.0.1:29644/" -TimeoutSec 2) {
    return $true
  }

  if ((Test-TcpEndpoint -HostName "127.0.0.1" -Port 29644) -and ((@(Get-GatewayHostProcess).Count -gt 0) -or (Test-GatewayWithinStartupGrace))) {
    return $true
  }

  return $false
}

function Test-NodeRunning {
  return [bool](
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq "node.exe" -and
        $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+dist[\\/]+index\.js' -and
        $_.CommandLine -match '\bnode\s+run\b'
      } |
      Select-Object -First 1
  )
}

function Get-OpenClawCommandPath {
  $candidate = Get-Command openclaw.cmd -ErrorAction SilentlyContinue
  if (-not $candidate) {
    $candidate = Get-Command openclaw -ErrorAction SilentlyContinue
  }

  if (-not $candidate) {
    return $null
  }

  return $candidate.Source
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
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    $process.WaitForExit(3000) | Out-Null
  } catch {
  }
}

function Stop-StaleTelegramStatusProbes {
  param([int]$MinimumAgeSeconds = 60)

  $now = Get-Date
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match 'channels\s+status' -and
      $_.CommandLine -match '--channel\s+telegram'
    } |
    ForEach-Object {
      $ageSeconds = 999999
      try {
        $createdAt = [System.Management.ManagementDateTimeConverter]::ToDateTime($_.CreationDate)
        $ageSeconds = ($now - $createdAt).TotalSeconds
      } catch {
      }

      if ($ageSeconds -ge $MinimumAgeSeconds) {
        Stop-ProcessTree -ProcessId ([int]$_.ProcessId)
      }
    }
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

function Get-NodeCommandPath {
  $candidate = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($candidate) {
    return [string]$candidate.Source
  }

  return "node.exe"
}

function Get-WatchdogTelegramState {
  if (-not (Test-Path -LiteralPath $telegramStatePath)) {
    return [pscustomobject]@{
      LastProbeAt = $null
      Ready = $false
      FailureCount = 0
      Summary = "never probed"
      Accounts = @()
    }
  }

  try {
    return (Get-Content -LiteralPath $telegramStatePath -Raw | ConvertFrom-Json)
  } catch {
    return [pscustomobject]@{
      LastProbeAt = $null
      Ready = $false
      FailureCount = 0
      Summary = "invalid state file"
      Accounts = @()
    }
  }
}

function Save-WatchdogTelegramState {
  param(
    [Parameter(Mandatory = $true)][bool]$Ready,
    [Parameter(Mandatory = $true)][int]$FailureCount,
    [Parameter(Mandatory = $true)][string]$Summary,
    [object[]]$Accounts = @()
  )

  [ordered]@{
    LastProbeAt = (Get-Date).ToString("o")
    Ready = $Ready
    FailureCount = $FailureCount
    Summary = $Summary
    Accounts = @($Accounts)
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $telegramStatePath -Encoding utf8
}

function Test-TelegramProbeDue {
  param([Parameter(Mandatory = $true)]$State)

  if ($null -eq $State.LastProbeAt) {
    return $true
  }

  try {
    $lastProbeAt = [datetime]::Parse([string]$State.LastProbeAt)
    return ((Get-Date) - $lastProbeAt).TotalSeconds -ge $telegramProbeIntervalSeconds
  } catch {
    return $true
  }
}

function Invoke-TelegramConnectedProbe {
  if (-not (Test-Path -LiteralPath $telegramProbeScript)) {
    return [pscustomobject]@{
      Ready = $false
      Summary = "missing Telegram probe script: $telegramProbeScript"
      Accounts = @()
    }
  }

  $nodeExe = Get-NodeCommandPath
  $stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMddHHmmssfff"), ([guid]::NewGuid().ToString("N"))
  $stdoutPath = Join-Path $transientDir ("openclaw-watchdog-telegram-$stamp.stdout.log")
  $stderrPath = Join-Path $transientDir ("openclaw-watchdog-telegram-$stamp.stderr.log")
  $oldSkipDeps = $env:OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS
  $oldSkipPluginServices = $env:OPENCLAW_SKIP_PLUGIN_SERVICES
  $oldSkipPrewarm = $env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM
  $oldSkipNativeCommands = $env:OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS
  $oldDisableAutoSelectFamily = $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY
  $oldDnsResultOrder = $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER
  $oldForceIpv4 = $env:OPENCLAW_TELEGRAM_FORCE_IPV4
  $oldPluginStageDir = $env:OPENCLAW_PLUGIN_STAGE_DIR
  $process = $null

  try {
    $env:OPENCLAW_PLUGIN_STAGE_DIR = $pluginStageDir
    $env:OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS = "1"
    $env:OPENCLAW_SKIP_PLUGIN_SERVICES = "1"
    $env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = "1"
    $env:OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS = "1"
    $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = "1"
    $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = "ipv4first"
    $env:OPENCLAW_TELEGRAM_FORCE_IPV4 = "1"

    $process = Start-Process `
      -FilePath $nodeExe `
      -ArgumentList @($telegramProbeScript, "--timeout-ms", "30000") `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -WindowStyle Hidden `
      -PassThru

    if (-not $process.WaitForExit($telegramProbeTimeoutSeconds * 1000)) {
      Stop-ProcessTree -ProcessId $process.Id
      return [pscustomobject]@{
        Ready = $false
        Summary = "Telegram connected probe timed out after ${telegramProbeTimeoutSeconds}s"
        Accounts = @()
      }
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
    if ($null -eq $stdout) { $stdout = "" }
    if ($null -eq $stderr) { $stderr = "" }
    if ([int]$process.ExitCode -ne 0) {
      $detail = if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr.Trim() } else { "exit code $($process.ExitCode)" }
      return [pscustomobject]@{
        Ready = $false
        Summary = $detail
        Accounts = @()
      }
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
      return [pscustomobject]@{
        Ready = $false
        Summary = "Telegram connected probe returned empty output"
        Accounts = @()
      }
    }

    $payload = $stdout.Trim() | ConvertFrom-Json
    $telegramAccounts = @(
      Get-ObjectPropertyValue `
        -Object (Get-ObjectPropertyValue -Object $payload -Name "channelAccounts") `
        -Name "telegram"
    ) | Where-Object {
      $null -ne $_ -and
      (Get-ObjectPropertyValue -Object $_ -Name "enabled") -eq $true -and
      (Get-ObjectPropertyValue -Object $_ -Name "configured") -eq $true
    }

    if ($telegramAccounts.Count -eq 0) {
      return [pscustomobject]@{
        Ready = $false
        Summary = "no enabled configured telegram accounts"
        Accounts = @()
      }
    }

    $accounts = @(
      foreach ($account in $telegramAccounts) {
        [pscustomobject]@{
          AccountId = [string](Get-ObjectPropertyValue -Object $account -Name "accountId")
          Running = ((Get-ObjectPropertyValue -Object $account -Name "running") -eq $true)
          Connected = ((Get-ObjectPropertyValue -Object $account -Name "connected") -eq $true)
        }
      }
    )
    $notReady = @($accounts | Where-Object { -not ($_.Running -and $_.Connected) })
    $summary = ($accounts | ForEach-Object { "{0}(running={1}, connected={2})" -f $_.AccountId, $_.Running, $_.Connected }) -join "; "

    return [pscustomobject]@{
      Ready = ($notReady.Count -eq 0)
      Summary = $summary
      Accounts = $accounts
    }
  } catch {
    return [pscustomobject]@{
      Ready = $false
      Summary = $_.Exception.Message
      Accounts = @()
    }
  } finally {
    $env:OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS = $oldSkipDeps
    $env:OPENCLAW_SKIP_PLUGIN_SERVICES = $oldSkipPluginServices
    $env:OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = $oldSkipPrewarm
    $env:OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS = $oldSkipNativeCommands
    $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = $oldDisableAutoSelectFamily
    $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = $oldDnsResultOrder
    $env:OPENCLAW_TELEGRAM_FORCE_IPV4 = $oldForceIpv4
    $env:OPENCLAW_PLUGIN_STAGE_DIR = $oldPluginStageDir
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Test-TelegramProviderRestartNeeded {
  param(
    [object[]]$Accounts = @(),
    [string]$Summary = ""
  )

  $accountList = @($Accounts | Where-Object { $null -ne $_ })
  if ($accountList.Count -gt 0) {
    return [bool](
      $accountList |
        Where-Object { (Get-ObjectPropertyValue -Object $_ -Name "Running") -eq $false } |
        Select-Object -First 1
    )
  }

  return ($Summary -match 'running=False')
}

function Update-TelegramWatchdogState {
  if (Test-GatewayWithinTelegramGrace) {
    Remove-Item -LiteralPath $telegramStatePath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      Probed = $false
      Ready = $false
      RestartRequired = $false
      Summary = "gateway startup grace"
      FailureCount = 0
    }
  }

  $state = Get-WatchdogTelegramState
  if (-not (Test-TelegramProbeDue -State $state)) {
    return [pscustomobject]@{
      Probed = $false
      Ready = [bool]$state.Ready
      RestartRequired = $false
      Summary = [string]$state.Summary
      FailureCount = [int]$state.FailureCount
    }
  }

  $probe = Invoke-TelegramConnectedProbe
  if ($probe.Ready) {
    Save-WatchdogTelegramState -Ready $true -FailureCount 0 -Summary $probe.Summary -Accounts @($probe.Accounts)
    return [pscustomobject]@{
      Probed = $true
      Ready = $true
      RestartRequired = $false
      Summary = $probe.Summary
      FailureCount = 0
    }
  }

  $providerRestartNeeded = Test-TelegramProviderRestartNeeded -Accounts @($probe.Accounts) -Summary $probe.Summary
  $previousFailureCount = if ($null -ne $state.FailureCount) { [int]$state.FailureCount } else { 0 }
  $failureCount = if ($providerRestartNeeded) { $previousFailureCount + 1 } else { 0 }
  Save-WatchdogTelegramState -Ready $false -FailureCount $failureCount -Summary $probe.Summary -Accounts @($probe.Accounts)
  if ($providerRestartNeeded) {
    Write-WatchdogLog ("Telegram provider check failed ({0}/{1}): {2}" -f $failureCount, $telegramFailureThreshold, $probe.Summary)
  } else {
    Write-WatchdogLog ("Telegram connected probe is not ready, but provider restart is not required: {0}" -f $probe.Summary)
  }

  return [pscustomobject]@{
    Probed = $true
    Ready = $false
    RestartRequired = ($providerRestartNeeded -and $failureCount -ge $telegramFailureThreshold)
    Summary = $probe.Summary
    FailureCount = $failureCount
  }
}

$mutex = New-Object System.Threading.Mutex($false, "Local\OpenClawStackWatchdog")
$lockAcquired = $false

try {
  try {
    $lockAcquired = $mutex.WaitOne(0, $false)
  } catch [System.Threading.AbandonedMutexException] {
    $lockAcquired = $true
  }

  if (-not $lockAcquired) {
    exit 0
  }

  if (Test-ExternalRestartInProgress) {
    exit 0
  }

  if (Test-RestartMarkerFresh) {
    exit 0
  }

  Stop-StaleTelegramStatusProbes -MinimumAgeSeconds $staleTelegramProbeAgeSeconds

  $checks = [ordered]@{
    Primary = Test-HttpReady -Url "http://127.0.0.1:8080/v1/models"
    TTS = Test-HttpReady -Url "http://127.0.0.1:8000/health"
    STT = Test-HttpReady -Url "http://127.0.0.1:8001/health"
    Vision = Test-HttpReady -Url "http://127.0.0.1:8081/v1/models"
    Gateway = Test-GatewayReachable
    Node = Test-NodeRunning
  }

  $telegramStatus = $null
  if ($checks.Gateway -and $checks.Node) {
    $telegramStatus = Update-TelegramWatchdogState
  }

  $failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
  if ($null -ne $telegramStatus -and $telegramStatus.RestartRequired) {
    $failed += "Telegram"
  }
  if ($failed.Count -eq 0) {
    Remove-Item -LiteralPath $restartMarker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $failureStatePath -Force -ErrorAction SilentlyContinue
    exit 0
  }

  if (Test-Path -LiteralPath $restartMarker) {
    if ((Test-ExternalRestartInProgress) -or (Test-RestartMarkerFresh)) {
      exit 0
    }

    Write-WatchdogLog "Removing stale restart marker; no restart process is active and checks are still failing."
    Remove-Item -LiteralPath $restartMarker -Force -ErrorAction SilentlyContinue
  }

  $failureCounts = Get-WatchdogFailureCounts
  foreach ($name in @($checks.Keys)) {
    if ($checks[$name]) {
      $failureCounts[$name] = 0
    } else {
      $previousCount = if ($failureCounts.ContainsKey($name)) { [int]$failureCounts[$name] } else { 0 }
      $failureCounts[$name] = $previousCount + 1
    }
  }
  Save-WatchdogFailureCounts -Counts $failureCounts

  $restartFailures = @(
    $failed |
      Where-Object {
        $_ -ne "Telegram" -and [int]$failureCounts[$_] -ge $coreFailureThreshold
      }
  )
  if ($null -ne $telegramStatus -and $telegramStatus.RestartRequired) {
    $restartFailures += "Telegram"
  }

  if ($restartFailures.Count -eq 0) {
    $details = @(
      $failed |
        Where-Object { $_ -ne "Telegram" } |
        ForEach-Object {
          "{0}({1}/{2})" -f $_, [int]$failureCounts[$_], $coreFailureThreshold
        }
    )
    Write-WatchdogLog ("Observed failing checks below restart threshold: {0}" -f ($details -join ", "))
    exit 0
  }

  $failed = $restartFailures

  Write-WatchdogLog ("Restarting OpenClaw stack because these checks failed: {0}" -f ($failed -join ", "))
  Start-DetachedRestart -FailedChecks $failed
  exit 0
} catch {
  Write-WatchdogLog ("Watchdog failed: {0}" -f $_.Exception.Message)
  throw
} finally {
  if ($lockAcquired) {
    try {
      $mutex.ReleaseMutex()
    } catch {
    }
  }

  $mutex.Dispose()
}
