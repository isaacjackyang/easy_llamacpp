[CmdletBinding()]
param(
  [switch]$DeepTelegram,
  [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$openClawRoot = Join-Path $env:USERPROFILE ".openclaw"
$openClawConfigPath = Join-Path $openClawRoot "openclaw.json"
$telegramWatchdogStatePath = Join-Path $openClawRoot "logs\openclaw-watchdog-telegram-state.json"
$watchdogTaskName = "\OpenClaw Watchdog"
$repoRoot = Split-Path -Parent $PSScriptRoot
$codexTelegramWorker1Runner = Join-Path $repoRoot "PS1\CodexTelegramWorker1\run-codex-telegram-worker1-bridge.ps1"
$codexTelegramWorker1Bridge = Join-Path $repoRoot "PS1\CodexTelegramWorker1\codex-telegram-worker1-bridge.mjs"
$codexTelegramWorker1Inbox = Join-Path $repoRoot ".codex-telegram-worker1\inbox.jsonl"
$codexTelegramWorker1RunValueName = "CodexTelegramWorker1Bridge"

function Test-HttpReady {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSec = 5
  )

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
    return [pscustomobject]@{
      Ready = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
      Status = [int]$response.StatusCode
      Error = ""
    }
  } catch {
    return [pscustomobject]@{
      Ready = $false
      Status = $null
      Error = $_.Exception.Message
    }
  }
}

function Get-ModelIdFromUrl {
  param([Parameter(Mandatory = $true)][string]$Url)

  try {
    $response = Invoke-RestMethod -Uri $Url -TimeoutSec 5
    if ($null -ne $response.data -and @($response.data).Count -gt 0) {
      return [string](@($response.data)[0].id)
    }

    if ($null -ne $response.models -and @($response.models).Count -gt 0) {
      $first = @($response.models)[0]
      if ($first.PSObject.Properties.Name -contains "model") {
        return [string]$first.model
      }
      if ($first.PSObject.Properties.Name -contains "name") {
        return [string]$first.name
      }
    }
  } catch {
  }

  return ""
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

function Get-OpenClawCommandPath {
  $candidate = Get-Command openclaw.cmd -ErrorAction SilentlyContinue
  if (-not $candidate) {
    $candidate = Get-Command openclaw -ErrorAction SilentlyContinue
  }

  if (-not $candidate) {
    return ""
  }

  return [string]$candidate.Source
}

function Get-CodexTelegramWorker1BridgeStatus {
  $processRunning = [bool](
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        (
          $_.CommandLine -match [regex]::Escape($codexTelegramWorker1Runner) -or
          $_.CommandLine -match [regex]::Escape($codexTelegramWorker1Bridge)
        )
      } |
      Select-Object -First 1
  )

  $autostart = $false
  try {
    $runValue = Get-ItemProperty `
      -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
      -Name $codexTelegramWorker1RunValueName `
      -ErrorAction Stop
    $autostart = -not [string]::IsNullOrWhiteSpace([string]$runValue.$codexTelegramWorker1RunValueName)
  } catch {
  }

  $inboxText = "inbox=empty"
  if (Test-Path -LiteralPath $codexTelegramWorker1Inbox) {
    try {
      $inboxItem = Get-Item -LiteralPath $codexTelegramWorker1Inbox -ErrorAction Stop
      $inboxText = "inboxBytes=$($inboxItem.Length)"
    } catch {
      $inboxText = "inbox=present"
    }
  }

  $paused = (-not $processRunning -and -not $autostart)
  $modeText = if ($paused) { "paused" } else { "active" }

  return [pscustomobject]@{
    Ready = ($paused -or ($processRunning -and $autostart))
    Detail = ("mode={0}; process={1}; autostart={2}; {3}; automation=disabled" -f $modeText, $processRunning, $autostart, $inboxText)
  }
}

function Get-ConfiguredTelegramAccounts {
  if (-not (Test-Path -LiteralPath $openClawConfigPath)) {
    return @()
  }

  try {
    $config = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
    $telegram = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $config -Name "channels") -Name "telegram"
    if ($null -eq $telegram -or (Get-ObjectPropertyValue -Object $telegram -Name "enabled") -ne $true) {
      return @()
    }

    $accounts = Get-ObjectPropertyValue -Object $telegram -Name "accounts"
    if ($null -eq $accounts) {
      return @()
    }

    return @(
      foreach ($property in @($accounts.PSObject.Properties)) {
        $account = $property.Value
        if ($null -ne $account -and (Get-ObjectPropertyValue -Object $account -Name "enabled") -eq $true) {
          [pscustomobject]@{
            AccountId = [string]$property.Name
          }
        }
      }
    )
  } catch {
    return @()
  }
}

function Get-WatchdogTelegramState {
  if (-not (Test-Path -LiteralPath $telegramWatchdogStatePath)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $telegramWatchdogStatePath -Raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Format-TimeAgo {
  param([AllowNull()]$Timestamp)

  if ($null -eq $Timestamp) {
    return "unknown"
  }

  try {
    $at = [datetime]::Parse([string]$Timestamp)
    $span = (Get-Date) - $at
    if ($span.TotalSeconds -lt 90) {
      return ("{0:N0}s ago" -f [Math]::Max(0, $span.TotalSeconds))
    }
    if ($span.TotalMinutes -lt 90) {
      return ("{0:N0}m ago" -f $span.TotalMinutes)
    }
    return ("{0:N1}h ago" -f $span.TotalHours)
  } catch {
    return "unknown"
  }
}

function Get-FastTelegramAccountStatuses {
  param(
    [Parameter(Mandatory = $true)][bool]$GatewayReady,
    [Parameter(Mandatory = $true)][bool]$NodeRunning
  )

  $configuredAccounts = @(Get-ConfiguredTelegramAccounts)
  $watchdogState = Get-WatchdogTelegramState
  $cachedAccounts = @()
  if ($null -ne $watchdogState -and $null -ne $watchdogState.Accounts) {
    $cachedAccounts = @($watchdogState.Accounts)
  }

  if ($configuredAccounts.Count -eq 0) {
    return @([pscustomobject]@{
      AccountId = "default"
      Running = $false
      Connected = $null
      Deep = $false
      Detail = "telegram is not configured/enabled"
    })
  }

  if ($cachedAccounts.Count -gt 0) {
    $ageText = Format-TimeAgo -Timestamp $watchdogState.LastProbeAt
    return @(
      foreach ($account in $configuredAccounts) {
        $cached = @($cachedAccounts | Where-Object { $_.AccountId -eq $account.AccountId } | Select-Object -First 1)
        if ($cached.Count -eq 0) {
          [pscustomobject]@{
            AccountId = $account.AccountId
            Running = ($GatewayReady -and $NodeRunning)
            Connected = $null
            Deep = $false
            Detail = "watchdog has not cached this account yet"
          }
        } else {
          [pscustomobject]@{
            AccountId = $account.AccountId
            Running = ([bool]$cached[0].Running)
            Connected = ([bool]$cached[0].Connected)
            Deep = $true
            Detail = "watchdog telegram probe $ageText"
          }
        }
      }
    )
  }

  return @(
    foreach ($account in $configuredAccounts) {
      [pscustomobject]@{
        AccountId = $account.AccountId
        Running = ($GatewayReady -and $NodeRunning)
        Connected = $null
        Deep = $false
        Detail = "fast mode; connected not probed; use -DeepTelegram for API status"
      }
    }
  )
}

function Invoke-OpenClawTelegramStatusJson {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawCommandPath,
    [int]$TimeoutSeconds = 25
  )

  $stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMddHHmmssfff"), ([guid]::NewGuid().ToString("N"))
  $stdoutPath = Join-Path $env:TEMP ("openclaw-show-status-telegram-$stamp.stdout.log")
  $stderrPath = Join-Path $env:TEMP ("openclaw-show-status-telegram-$stamp.stderr.log")
  $openClawNpmRoot = Split-Path -Parent $OpenClawCommandPath
  $openClawEntry = Join-Path $openClawNpmRoot "node_modules\openclaw\openclaw.mjs"
  $telegramProbeScript = Join-Path $openClawRoot "scripts\probe-openclaw-telegram-status.mjs"
  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  $statusFilePath = $OpenClawCommandPath
  $statusArguments = @("channels", "status", "--channel", "telegram", "--json")

  if ($nodeCommand -and (Test-Path -LiteralPath $telegramProbeScript)) {
    $statusFilePath = $nodeCommand.Source
    $statusArguments = @($telegramProbeScript, "--timeout-ms", "30000")
  } elseif ($nodeCommand -and (Test-Path -LiteralPath $openClawEntry)) {
    $statusFilePath = $nodeCommand.Source
    $statusArguments = @($openClawEntry, "channels", "status", "--channel", "telegram", "--json")
  }

  $oldDisableAutoSelectFamily = $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY
  $oldDnsResultOrder = $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER
  $oldForceIpv4 = $env:OPENCLAW_TELEGRAM_FORCE_IPV4
  $oldPluginStageDir = $env:OPENCLAW_PLUGIN_STAGE_DIR
  $process = $null

  try {
    Stop-StaleTelegramStatusProbes -MinimumAgeSeconds 60
    $env:OPENCLAW_PLUGIN_STAGE_DIR = "F:\Documents\GitHub\easy_llamacpp\.openclaw-plugin-stage"
    $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = "1"
    $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = "ipv4first"
    $env:OPENCLAW_TELEGRAM_FORCE_IPV4 = "1"

    $process = Start-Process `
      -FilePath $statusFilePath `
      -ArgumentList $statusArguments `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -WindowStyle Hidden `
      -PassThru

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      Stop-ProcessTree -ProcessId $process.Id
      Stop-StaleTelegramStatusProbes -MinimumAgeSeconds 0
      return [pscustomobject]@{
        ExitCode = 124
        Output = ""
        Error = "telegram status timed out after ${TimeoutSeconds}s"
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
    $env:OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = $oldDisableAutoSelectFamily
    $env:OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = $oldDnsResultOrder
    $env:OPENCLAW_TELEGRAM_FORCE_IPV4 = $oldForceIpv4
    $env:OPENCLAW_PLUGIN_STAGE_DIR = $oldPluginStageDir
    Stop-StaleTelegramStatusProbes -MinimumAgeSeconds 60
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-TelegramAccountStatuses {
  param(
    [Parameter(Mandatory = $true)][bool]$GatewayReady,
    [Parameter(Mandatory = $true)][bool]$NodeRunning
  )

  if (-not $DeepTelegram) {
    return @(Get-FastTelegramAccountStatuses -GatewayReady $GatewayReady -NodeRunning $NodeRunning)
  }

  $openClawCommandPath = Get-OpenClawCommandPath
  if ([string]::IsNullOrWhiteSpace($openClawCommandPath)) {
    return @([pscustomobject]@{
      AccountId = "default"
      Running = $false
      Connected = $false
      Deep = $true
      Detail = "openclaw command not found"
    })
  }

  $result = Invoke-OpenClawTelegramStatusJson -OpenClawCommandPath $openClawCommandPath -TimeoutSeconds 45
  if ([int]$result.ExitCode -ne 0) {
    $detail = if (-not [string]::IsNullOrWhiteSpace($result.Error)) { $result.Error } else { $result.Output }
    return @([pscustomobject]@{
      AccountId = "default"
      Running = $false
      Connected = $false
      Deep = $true
      Detail = $detail
    })
  }

  $text = if ($null -ne $result -and $null -ne $result.Output) { [string]$result.Output } else { "" }
  $jsonStart = $text.IndexOf("{")
  $jsonEnd = $text.LastIndexOf("}")
  if ($jsonStart -lt 0 -or $jsonEnd -lt $jsonStart) {
    return @([pscustomobject]@{
      AccountId = "default"
      Running = $false
      Connected = $false
      Deep = $true
      Detail = "telegram status did not return JSON"
    })
  }

  try {
    $status = $text.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json
    $channelAccounts = Get-ObjectPropertyValue -Object $status -Name "channelAccounts"
    $telegramAccounts = @(Get-ObjectPropertyValue -Object $channelAccounts -Name "telegram")
    $enabledAccounts = @(
      $telegramAccounts |
        Where-Object {
          $null -ne $_ -and
          (Get-ObjectPropertyValue -Object $_ -Name "enabled") -eq $true -and
          (Get-ObjectPropertyValue -Object $_ -Name "configured") -eq $true
        }
    )

    if ($enabledAccounts.Count -eq 0) {
      return @([pscustomobject]@{
        AccountId = "default"
        Running = $false
        Connected = $false
        Deep = $true
        Detail = "no enabled configured telegram accounts"
      })
    }

    return @(
      foreach ($account in $enabledAccounts) {
        $accountId = [string](Get-ObjectPropertyValue -Object $account -Name "accountId")
        if ([string]::IsNullOrWhiteSpace($accountId)) {
          $accountId = "unknown"
        }

        [pscustomobject]@{
          AccountId = $accountId
          Running = ((Get-ObjectPropertyValue -Object $account -Name "running") -eq $true)
          Connected = ((Get-ObjectPropertyValue -Object $account -Name "connected") -eq $true)
          Deep = $true
          Detail = ""
        }
      }
    )
  } catch {
    return @([pscustomobject]@{
      AccountId = "default"
      Running = $false
      Connected = $false
      Deep = $true
      Detail = $_.Exception.Message
    })
  }
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

function Test-OpenClawGatewayRunning {
  return [bool](
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match 'node_modules[\\/]+openclaw[\\/]+(?:dist[\\/]+index\.js|openclaw\.mjs)' -and
        $_.CommandLine -match '\bgateway\s+run\b'
      } |
      Select-Object -First 1
  )
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

function Get-WatchdogStatus {
  $task = Get-ScheduledTask -TaskName "OpenClaw Watchdog" -ErrorAction SilentlyContinue
  if (-not $task) {
    return [pscustomobject]@{
      Ready = $false
      Detail = "not registered"
    }
  }

  $taskInfo = Get-ScheduledTaskInfo -TaskName "OpenClaw Watchdog" -ErrorAction SilentlyContinue

  $state = [string]$task.State
  $runtimeStatus = ""
  $lastResult = ""
  $nextRun = ""
  $repeat = ""

  if ($null -ne $taskInfo) {
    $lastResult = if ($null -ne $taskInfo.LastTaskResult) { [string]$taskInfo.LastTaskResult } else { "" }
    $nextRun = if ($null -ne $taskInfo.NextRunTime -and $taskInfo.NextRunTime -ne [datetime]::MinValue) { $taskInfo.NextRunTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
  }

  # Check if task is currently running by querying running tasks
  try {
    $runningTasks = Get-ScheduledTask -State Running -ErrorAction SilentlyContinue
    $isRunning = @($runningTasks | Where-Object { $_.TaskName -eq "OpenClaw Watchdog" }).Count -gt 0
    if ($isRunning) {
      $runtimeStatus = "Running"
    }
  } catch {
  }

  # Extract repeat interval from task settings
  try {
    if ($null -ne $task.Settings -and $task.Settings -is [object]) {
      $settingsProps = $task.Settings.PSObject.Properties
      if ($settingsProps.Name -contains "RepeatCount") {
        $repeatCount = $task.Settings.RepeatCount
        if ($repeatCount -gt 0) {
          $repeat = "configured"
        }
      }
    }
  } catch {
  }

  $ready = (
    $state -in @("Ready", "Running") -and (
      $runtimeStatus -eq "Running" -or
      $lastResult -eq "0" -or
      $lastResult -eq "267009"
    )
  )
  $parts = @()
  if (-not [string]::IsNullOrWhiteSpace($state)) { $parts += "state=$state" }
  if (-not [string]::IsNullOrWhiteSpace($runtimeStatus)) { $parts += "status=$runtimeStatus" }
  if (-not [string]::IsNullOrWhiteSpace($lastResult)) { $parts += "lastResult=$lastResult" }
  if (-not [string]::IsNullOrWhiteSpace($repeat)) { $parts += "repeat=$repeat" }
  if (-not [string]::IsNullOrWhiteSpace($nextRun)) { $parts += "next=$nextRun" }

  return [pscustomobject]@{
    Ready = $ready
    Detail = ($parts -join "; ")
  }
}

function Write-StatusLine {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Ready,
    [string]$Detail = ""
  )

  $state = if ($Ready) { "OK" } else { "DOWN" }
  $line = "{0,-24}: {1}" -f $Name, $state
  if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    $line += " - $Detail"
  }

  Write-Host $line
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
  Write-Host ""
  Write-Host "OpenClaw Stack Status"
  Write-Host ("Checked at: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
  Write-Host ("Config    : {0}" -f $openClawConfigPath)
  Write-Host ""

  $primary = Test-HttpReady -Url "http://127.0.0.1:8080/v1/models"
  $primaryModel = Get-ModelIdFromUrl -Url "http://127.0.0.1:8080/v1/models"
  Write-StatusLine -Name "Primary llama.cpp" -Ready $primary.Ready -Detail $(if ($primary.Ready) { "http 8080; model=$primaryModel" } else { $primary.Error })

  $vision = Test-HttpReady -Url "http://127.0.0.1:8081/v1/models"
  $visionModel = Get-ModelIdFromUrl -Url "http://127.0.0.1:8081/v1/models"
  Write-StatusLine -Name "Vision" -Ready $vision.Ready -Detail $(if ($vision.Ready) { "http 8081; model=$visionModel" } else { $vision.Error })

  $tts = Test-HttpReady -Url "http://127.0.0.1:8000/health"
  Write-StatusLine -Name "TTS" -Ready $tts.Ready -Detail $(if ($tts.Ready) { "http 8000/health" } else { $tts.Error })

  $stt = Test-HttpReady -Url "http://127.0.0.1:8001/health"
  Write-StatusLine -Name "STT" -Ready $stt.Ready -Detail $(if ($stt.Ready) { "http 8001/health" } else { $stt.Error })

  $gatewayHealth = Test-HttpReady -Url "http://127.0.0.1:29644/health"
  $gatewayRoot = Test-HttpReady -Url "http://127.0.0.1:29644/"
  $gatewayTcp = Test-TcpEndpoint -HostName "127.0.0.1" -Port 29644
  $gatewayProcess = Test-OpenClawGatewayRunning
  $gatewayReady = ($gatewayHealth.Ready -or $gatewayRoot.Ready -or ($gatewayTcp -and $gatewayProcess))
  $gatewayDetail = if ($gatewayHealth.Ready -or $gatewayRoot.Ready) {
    "http 29644; health=$($gatewayHealth.Status); webui=$($gatewayRoot.Status)"
  } elseif ($gatewayReady) {
    "tcp=listening; process=detected; http=busy"
  } else {
    if (-not [string]::IsNullOrWhiteSpace($gatewayHealth.Error)) { $gatewayHealth.Error } else { $gatewayRoot.Error }
  }
  Write-StatusLine -Name "OpenClaw Gateway/WebUI" -Ready $gatewayReady -Detail $gatewayDetail

  $nodeRunning = Test-OpenClawNodeRunning
  Write-StatusLine -Name "Node" -Ready $nodeRunning -Detail $(if ($nodeRunning) { "node host process detected" } else { "node host process not detected" })

  $telegramAccounts = @(Get-TelegramAccountStatuses -GatewayReady $gatewayReady -NodeRunning $nodeRunning)
  $defaultAccount = @($telegramAccounts | Where-Object { $_.AccountId -eq "default" } | Select-Object -First 1)
  if ($defaultAccount.Count -eq 0) {
    $defaultAccount = @($telegramAccounts | Select-Object -First 1)
  }

  foreach ($account in $defaultAccount) {
    $ready = if ($account.Deep) { ($account.Running -and $account.Connected) } else { [bool]$account.Running }
    $connectedText = if ($null -eq $account.Connected) { "not probed" } else { [string]$account.Connected }
    $detail = "running=$($account.Running); connected=$connectedText"
    if (-not [string]::IsNullOrWhiteSpace($account.Detail)) {
      $detail += "; $($account.Detail)"
    }
    Write-StatusLine -Name ("Telegram {0}" -f $account.AccountId) -Ready $ready -Detail $detail
  }

  $extraAccounts = @($telegramAccounts | Where-Object { $_.AccountId -ne "default" })
  foreach ($account in $extraAccounts) {
    $ready = if ($account.Deep) { ($account.Running -and $account.Connected) } else { [bool]$account.Running }
    $connectedText = if ($null -eq $account.Connected) { "not probed" } else { [string]$account.Connected }
    $detail = "running=$($account.Running); connected=$connectedText"
    if (-not [string]::IsNullOrWhiteSpace($account.Detail)) {
      $detail += "; $($account.Detail)"
    }
    Write-StatusLine -Name ("Telegram {0}" -f $account.AccountId) -Ready $ready -Detail $detail
  }

  $codexWorker1 = Get-CodexTelegramWorker1BridgeStatus
  Write-StatusLine -Name "Codex Telegram worker1" -Ready $codexWorker1.Ready -Detail $codexWorker1.Detail

  $watchdog = Get-WatchdogStatus
  Write-StatusLine -Name "Watchdog" -Ready $watchdog.Ready -Detail $watchdog.Detail

  Write-Host ""
} catch {
  Write-Host ""
  Write-Host "Error:"
  Write-Host $_.Exception.Message
  exit 1
} finally {
  Pause-BeforeExit
}
