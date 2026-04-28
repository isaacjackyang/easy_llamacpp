Set-StrictMode -Version Latest

function Get-OpenClawSupportSafeName {
  param([Parameter(Mandatory = $true)][string]$Value)

  return ([regex]::Replace($Value, '[^A-Za-z0-9._-]+', '-')).Trim('-')
}

function Backup-OpenClawManagedTextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Suffix
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
  $safeSuffix = Get-OpenClawSupportSafeName -Value $Suffix
  $backupPath = "$Path.$safeSuffix.$stamp.bak"
  Copy-Item -LiteralPath $Path -Destination $backupPath -Force
  return $backupPath
}

function Write-OpenClawManagedUtf8NoBom {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  [System.IO.File]::WriteAllText(
    $Path,
    $Text,
    [System.Text.UTF8Encoding]::new($false)
  )
}

function Sync-OpenClawManagedTextFileFromTemplate {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [Parameter(Mandatory = $true)][string]$Description,
    [string]$BackupSuffix = "managed-startup-sync"
  )

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    return [pscustomobject]@{
      Description = $Description
      Path = $DestinationPath
      Status = "template-missing"
      Changed = $false
      BackupPath = $null
      SourcePath = $SourcePath
    }
  }

  $sourceText = Get-Content -LiteralPath $SourcePath -Raw
  $destinationExists = Test-Path -LiteralPath $DestinationPath
  $destinationText = if ($destinationExists) {
    Get-Content -LiteralPath $DestinationPath -Raw
  } else {
    $null
  }

  if ($destinationExists -and [string]::Equals($sourceText, $destinationText, [System.StringComparison]::Ordinal)) {
    return [pscustomobject]@{
      Description = $Description
      Path = $DestinationPath
      Status = "unchanged"
      Changed = $false
      BackupPath = $null
      SourcePath = $SourcePath
    }
  }

  $backupPath = if ($destinationExists) {
    Backup-OpenClawManagedTextFile -Path $DestinationPath -Suffix $BackupSuffix
  } else {
    $null
  }

  Write-OpenClawManagedUtf8NoBom -Path $DestinationPath -Text $sourceText

  return [pscustomobject]@{
    Description = $Description
    Path = $DestinationPath
    Status = $(if ($destinationExists) { "updated" } else { "created" })
    Changed = $true
    BackupPath = $backupPath
    SourcePath = $SourcePath
  }
}

function Get-OpenClawManagedGatewayCmdTemplate {
  param(
    [Parameter(Mandatory = $true)][string]$OpenClawRoot,
    [Parameter(Mandatory = $true)][string]$OpenClawConfigPath,
    [Parameter(Mandatory = $true)][string]$ManagedGatewayScriptPath,
    [Parameter(Mandatory = $true)][string]$EasyLlamacppRoot,
    [int]$GatewayPort = 29644
  )

  $escapedManagedGatewayScriptPath = $ManagedGatewayScriptPath -replace "'", "''"
  $escapedEasyLlamacppRoot = $EasyLlamacppRoot -replace "'", "''"

  return @"
@echo off
setlocal
set "OPENCLAW_HIDE_SERVICE_CONSOLE=1"
set "WSCRIPT_EXE=%SystemRoot%\System32\wscript.exe"
set "OPENCLAW_GATEWAY_LAUNCHER=%~dp0scripts\start-openclaw-gateway-hidden.vbs"

if not exist "%WSCRIPT_EXE%" (
  set "WSCRIPT_EXE=wscript.exe"
)

if not exist "%OPENCLAW_GATEWAY_LAUNCHER%" (
  echo Cannot find OpenClaw gateway hidden VBS launcher: "%OPENCLAW_GATEWAY_LAUNCHER%"
  exit /b 1
)

start "" "%WSCRIPT_EXE%" "%OPENCLAW_GATEWAY_LAUNCHER%"
endlocal & exit /b 0
"@
}

function Sync-OpenClawManagedGatewayCmd {
  param(
    [Parameter(Mandatory = $true)][string]$GatewayCmdPath,
    [Parameter(Mandatory = $true)][string]$OpenClawRoot,
    [Parameter(Mandatory = $true)][string]$OpenClawConfigPath,
    [Parameter(Mandatory = $true)][string]$ManagedGatewayScriptPath,
    [Parameter(Mandatory = $true)][string]$EasyLlamacppRoot,
    [int]$GatewayPort = 29644,
    [string]$BackupSuffix = "managed-gateway-cmd"
  )

  $templateText = Get-OpenClawManagedGatewayCmdTemplate `
    -OpenClawRoot $OpenClawRoot `
    -OpenClawConfigPath $OpenClawConfigPath `
    -ManagedGatewayScriptPath $ManagedGatewayScriptPath `
    -EasyLlamacppRoot $EasyLlamacppRoot `
    -GatewayPort $GatewayPort

  $destinationExists = Test-Path -LiteralPath $GatewayCmdPath
  $destinationText = if ($destinationExists) {
    Get-Content -LiteralPath $GatewayCmdPath -Raw
  } else {
    $null
  }

  if ($destinationExists -and [string]::Equals($templateText, $destinationText, [System.StringComparison]::Ordinal)) {
    return [pscustomobject]@{
      Description = "managed gateway launcher"
      Path = $GatewayCmdPath
      Status = "unchanged"
      Changed = $false
      BackupPath = $null
      SourcePath = $null
    }
  }

  $backupPath = if ($destinationExists) {
    Backup-OpenClawManagedTextFile -Path $GatewayCmdPath -Suffix $BackupSuffix
  } else {
    $null
  }

  Write-OpenClawManagedUtf8NoBom -Path $GatewayCmdPath -Text $templateText

  return [pscustomobject]@{
    Description = "managed gateway launcher"
    Path = $GatewayCmdPath
    Status = $(if ($destinationExists) { "updated" } else { "created" })
    Changed = $true
    BackupPath = $backupPath
    SourcePath = $null
  }
}

function Sync-OpenClawManagedNodeCmdTelegramEnv {
  param(
    [Parameter(Mandatory = $true)][string]$NodeCmdPath,
    [string]$BackupSuffix = "managed-node-telegram-env"
  )

  if (-not (Test-Path -LiteralPath $NodeCmdPath)) {
    return [pscustomobject]@{
      Description = "node launcher Telegram network env"
      Path = $NodeCmdPath
      Status = "template-missing"
      Changed = $false
      BackupPath = $null
      SourcePath = $null
    }
  }

  $originalText = Get-Content -LiteralPath $NodeCmdPath -Raw
  $normalizedText = [regex]::Replace(
    $originalText,
    '(?m)^set "(?:EASY_LLAMACPP_ROOT|OPENCLAW_(?:HIDE_SERVICE_CONSOLE|PLUGIN_STAGE_DIR|SKIP_(?:BUNDLED_RUNTIME_DEPS|PLUGIN_SERVICES|STARTUP_MODEL_PREWARM)|TELEGRAM_(?:DISABLE_AUTO_SELECT_FAMILY|DNS_RESULT_ORDER|FORCE_IPV4|SKIP_NATIVE_COMMANDS)))=[^"]*"\r?\n',
    ''
  )
  $envLines = @(
    'set "OPENCLAW_HIDE_SERVICE_CONSOLE=1"',
    'set "EASY_LLAMACPP_ROOT=F:\Documents\GitHub\easy_llamacpp"',
    'set "OPENCLAW_PLUGIN_STAGE_DIR=%EASY_LLAMACPP_ROOT%\.openclaw-plugin-stage"',
    'set "OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS=1"',
    'set "OPENCLAW_SKIP_PLUGIN_SERVICES=1"',
    'set "OPENCLAW_SKIP_STARTUP_MODEL_PREWARM=1"',
    'set "OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY=1"',
    'set "OPENCLAW_TELEGRAM_DNS_RESULT_ORDER=ipv4first"',
    'set "OPENCLAW_TELEGRAM_FORCE_IPV4=1"',
    'set "OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS=1"'
  ) -join [Environment]::NewLine

  if ($normalizedText -match '(?m)^set "OPENCLAW_SERVICE_KIND=node"\r?$') {
    $updatedText = [regex]::Replace(
      $normalizedText,
      '(?m)^set "OPENCLAW_SERVICE_KIND=node"\r?$',
      "set `"OPENCLAW_SERVICE_KIND=node`"$([Environment]::NewLine)$envLines",
      1
    )
  } else {
    $updatedText = $normalizedText.TrimEnd() + [Environment]::NewLine + $envLines + [Environment]::NewLine
  }

  if ($updatedText -notmatch '(?m)^set "OPENCLAW_NODE_HIDDEN_LAUNCHER=') {
    $updatedText = [regex]::Replace(
      $updatedText,
      '(?m)^(set "OPENCLAW_NODE_WRAPPER=[^"]+")\r?$',
      "`$1$([Environment]::NewLine)set `"OPENCLAW_NODE_HIDDEN_LAUNCHER=%OPENCLAW_STATE_DIR%\scripts\start-openclaw-node-hidden.ps1`"",
      1
    )
  }

  $detachedNodeStart = @'
if not exist "%OPENCLAW_NODE_HIDDEN_LAUNCHER%" (
  echo Cannot find OpenClaw node hidden launcher: "%OPENCLAW_NODE_HIDDEN_LAUNCHER%"
  exit /b 1
)

set "OPENCLAW_NODE_HIDDEN_VBS=%OPENCLAW_STATE_DIR%\scripts\start-openclaw-node-hidden.vbs"
set "WSCRIPT_EXE=%SystemRoot%\System32\wscript.exe"
if not exist "%WSCRIPT_EXE%" (
  set "WSCRIPT_EXE=wscript.exe"
)

if exist "%OPENCLAW_NODE_HIDDEN_VBS%" (
  start "" "%WSCRIPT_EXE%" "%OPENCLAW_NODE_HIDDEN_VBS%"
) else (
  start "" "%POWERSHELL_EXE%" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%OPENCLAW_NODE_HIDDEN_LAUNCHER%"
)
endlocal & exit /b 0
'@

  $legacyDetachedNodeStart = @'
if not exist "%OPENCLAW_NODE_HIDDEN_LAUNCHER%" (
  echo Cannot find OpenClaw node hidden launcher: "%OPENCLAW_NODE_HIDDEN_LAUNCHER%"
  exit /b 1
)

start "" "%POWERSHELL_EXE%" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%OPENCLAW_NODE_HIDDEN_LAUNCHER%"
endlocal & exit /b 0
'@

  $updatedText = [regex]::Replace(
    $updatedText,
    '(?ms)^"%POWERSHELL_EXE%"\s+-NoLogo\s+-NoProfile.*?-File\s+"%OPENCLAW_NODE_WRAPPER%".*?^endlocal\s+&\s+exit\s+/b\s+%EXIT_CODE%\s*$',
    $detachedNodeStart.TrimEnd(),
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  $updatedText = $updatedText.Replace($legacyDetachedNodeStart, $detachedNodeStart)

  if ([string]::Equals($originalText, $updatedText, [System.StringComparison]::Ordinal)) {
    return [pscustomobject]@{
      Description = "node launcher Telegram network env"
      Path = $NodeCmdPath
      Status = "unchanged"
      Changed = $false
      BackupPath = $null
      SourcePath = $null
    }
  }

  $backupPath = Backup-OpenClawManagedTextFile -Path $NodeCmdPath -Suffix $BackupSuffix
  Write-OpenClawManagedUtf8NoBom -Path $NodeCmdPath -Text $updatedText

  return [pscustomobject]@{
    Description = "node launcher Telegram network env"
    Path = $NodeCmdPath
    Status = "updated"
    Changed = $true
    BackupPath = $backupPath
    SourcePath = $null
  }
}

function Sync-OpenClawManagedStartupAssets {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$OpenClawRoot,
    [string]$OpenClawConfigPath = $(Join-Path $OpenClawRoot "openclaw.json"),
    [int]$GatewayPort = 29644,
    [string]$EasyLlamacppRoot = $ProjectRoot
  )

  $templateDir = Join-Path $ProjectRoot "PS1\OpenClaw"
  $scriptsDir = Join-Path $OpenClawRoot "scripts"
  $managedGatewayScriptName = "run-openclaw-gateway-with-media.ps1"
  $visionStartupScriptName = "start-llama-cpp-vision.ps1"
  $gatewayHiddenLauncherName = "start-openclaw-gateway-hidden.ps1"
  $nodeHiddenLauncherName = "start-openclaw-node-hidden.ps1"
  $gatewayHiddenVbsName = "start-openclaw-gateway-hidden.vbs"
  $nodeHiddenVbsName = "start-openclaw-node-hidden.vbs"
  $watchdogHiddenVbsName = "watch-openclaw-stack-hidden.vbs"
  $watchdogScriptName = "watch-openclaw-stack.ps1"
  $restartScriptName = "restart-openclaw-gateway.ps1"
  $telegramProbeScriptName = "probe-openclaw-telegram-status.mjs"
  $sessionPatchScriptName = "patch-openclaw-session-display.mjs"
  $managedGatewayTemplatePath = Join-Path $templateDir $managedGatewayScriptName
  $visionStartupTemplatePath = Join-Path $templateDir $visionStartupScriptName
  $gatewayHiddenLauncherTemplatePath = Join-Path $templateDir $gatewayHiddenLauncherName
  $nodeHiddenLauncherTemplatePath = Join-Path $templateDir $nodeHiddenLauncherName
  $gatewayHiddenVbsTemplatePath = Join-Path $templateDir $gatewayHiddenVbsName
  $nodeHiddenVbsTemplatePath = Join-Path $templateDir $nodeHiddenVbsName
  $watchdogHiddenVbsTemplatePath = Join-Path $templateDir $watchdogHiddenVbsName
  $watchdogTemplatePath = Join-Path $templateDir $watchdogScriptName
  $restartTemplatePath = Join-Path $templateDir $restartScriptName
  $telegramProbeTemplatePath = Join-Path $templateDir $telegramProbeScriptName
  $sessionPatchTemplatePath = Join-Path $templateDir $sessionPatchScriptName
  $workspaceToolsTemplatePath = Join-Path $templateDir "TOOLS.md"
  $managedGatewayScriptPath = Join-Path $scriptsDir $managedGatewayScriptName
  $visionStartupScriptPath = Join-Path $scriptsDir $visionStartupScriptName
  $gatewayHiddenLauncherPath = Join-Path $scriptsDir $gatewayHiddenLauncherName
  $nodeHiddenLauncherPath = Join-Path $scriptsDir $nodeHiddenLauncherName
  $gatewayHiddenVbsPath = Join-Path $scriptsDir $gatewayHiddenVbsName
  $nodeHiddenVbsPath = Join-Path $scriptsDir $nodeHiddenVbsName
  $watchdogHiddenVbsPath = Join-Path $scriptsDir $watchdogHiddenVbsName
  $watchdogScriptPath = Join-Path $scriptsDir $watchdogScriptName
  $restartScriptPath = Join-Path $scriptsDir $restartScriptName
  $telegramProbeScriptPath = Join-Path $scriptsDir $telegramProbeScriptName
  $sessionPatchScriptPath = Join-Path $scriptsDir $sessionPatchScriptName
  $gatewayCmdPath = Join-Path $OpenClawRoot "gateway.cmd"
  $nodeCmdPath = Join-Path $OpenClawRoot "node.cmd"
  $workspaceToolsPaths = @(
    (Join-Path $OpenClawRoot "workspace\TOOLS.md"),
    (Join-Path $OpenClawRoot "workspace-worker1\TOOLS.md"),
    (Join-Path $OpenClawRoot "workspace-worker2\TOOLS.md")
  )

  $results = New-Object System.Collections.Generic.List[object]
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $managedGatewayTemplatePath `
    -DestinationPath $managedGatewayScriptPath `
    -Description "sidecar-aware gateway script" `
    -BackupSuffix "managed-gateway-script"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $visionStartupTemplatePath `
    -DestinationPath $visionStartupScriptPath `
    -Description "llama.cpp vision startup script" `
    -BackupSuffix "managed-vision-script"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $gatewayHiddenLauncherTemplatePath `
    -DestinationPath $gatewayHiddenLauncherPath `
    -Description "hidden gateway launcher" `
    -BackupSuffix "hidden-gateway-launcher"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $nodeHiddenLauncherTemplatePath `
    -DestinationPath $nodeHiddenLauncherPath `
    -Description "hidden node launcher" `
    -BackupSuffix "hidden-node-launcher"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $gatewayHiddenVbsTemplatePath `
    -DestinationPath $gatewayHiddenVbsPath `
    -Description "no-console gateway launcher" `
    -BackupSuffix "no-console-gateway-launcher"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $nodeHiddenVbsTemplatePath `
    -DestinationPath $nodeHiddenVbsPath `
    -Description "no-console node launcher" `
    -BackupSuffix "no-console-node-launcher"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $watchdogTemplatePath `
    -DestinationPath $watchdogScriptPath `
    -Description "OpenClaw watchdog script" `
    -BackupSuffix "openclaw-watchdog-script"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $watchdogHiddenVbsTemplatePath `
    -DestinationPath $watchdogHiddenVbsPath `
    -Description "OpenClaw no-console watchdog launcher" `
    -BackupSuffix "openclaw-watchdog-vbs"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $restartTemplatePath `
    -DestinationPath $restartScriptPath `
    -Description "OpenClaw restart script" `
    -BackupSuffix "openclaw-restart-script"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $telegramProbeTemplatePath `
    -DestinationPath $telegramProbeScriptPath `
    -Description "OpenClaw Telegram status probe" `
    -BackupSuffix "openclaw-telegram-probe"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $sessionPatchTemplatePath `
    -DestinationPath $sessionPatchScriptPath `
    -Description "control-ui session patch" `
    -BackupSuffix "control-ui-session-patch"))
  foreach ($workspaceToolsPath in $workspaceToolsPaths) {
    $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
      -SourcePath $workspaceToolsTemplatePath `
      -DestinationPath $workspaceToolsPath `
      -Description "compact workspace TOOLS.md" `
      -BackupSuffix "compact-tools-bootstrap"))
  }
  $results.Add((Sync-OpenClawManagedGatewayCmd `
    -GatewayCmdPath $gatewayCmdPath `
    -OpenClawRoot $OpenClawRoot `
    -OpenClawConfigPath $OpenClawConfigPath `
    -ManagedGatewayScriptPath $managedGatewayScriptPath `
    -EasyLlamacppRoot $EasyLlamacppRoot `
    -GatewayPort $GatewayPort))
  $results.Add((Sync-OpenClawManagedNodeCmdTelegramEnv `
    -NodeCmdPath $nodeCmdPath))

  return $results.ToArray()
}

function Test-OpenClawNodeContainsGraphitiReference {
  param([AllowNull()]$Node)

  if ($null -eq $Node) {
    return $false
  }

  if ($Node -is [string]) {
    return ($Node -match '(?i)graphiti')
  }

  try {
    $json = $Node | ConvertTo-Json -Depth 50 -Compress
    return ($json -match '(?i)graphiti')
  } catch {
    return $false
  }
}

function Set-OpenClawJsonNoteProperty {
  param(
    [Parameter(Mandatory = $true)][object]$Node,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()]$Value
  )

  if (-not ($Node -is [pscustomobject])) {
    return $false
  }

  if ($Node.PSObject.Properties.Name -contains $Name) {
    if ($Node.$Name -eq $Value) {
      return $false
    }

    $Node.$Name = $Value
    return $true
  }

  $Node | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  return $true
}

function Ensure-OpenClawTelegramNetworkConfig {
  param([Parameter(Mandatory = $true)][object]$Config)

  $changedKeys = New-Object System.Collections.Generic.List[string]

  if (-not ($Config.PSObject.Properties.Name -contains "channels") -or -not ($Config.channels -is [pscustomobject])) {
    $Config | Add-Member -NotePropertyName channels -NotePropertyValue ([pscustomobject]@{})
  }

  if (-not ($Config.channels.PSObject.Properties.Name -contains "telegram") -or -not ($Config.channels.telegram -is [pscustomobject])) {
    $Config.channels | Add-Member -NotePropertyName telegram -NotePropertyValue ([pscustomobject]@{})
  }

  if (-not ($Config.channels.telegram.PSObject.Properties.Name -contains "network") -or -not ($Config.channels.telegram.network -is [pscustomobject])) {
    $Config.channels.telegram | Add-Member -NotePropertyName network -NotePropertyValue ([pscustomobject]@{})
    $changedKeys.Add("channels.telegram.network")
  }

  if (Set-OpenClawJsonNoteProperty -Node $Config.channels.telegram.network -Name "autoSelectFamily" -Value $false) {
    $changedKeys.Add("channels.telegram.network.autoSelectFamily")
  }
  if (Set-OpenClawJsonNoteProperty -Node $Config.channels.telegram.network -Name "dnsResultOrder" -Value "ipv4first") {
    $changedKeys.Add("channels.telegram.network.dnsResultOrder")
  }
  if ($Config.channels.telegram.network.PSObject.Properties.Name -contains "forceIpv4") {
    [void]$Config.channels.telegram.network.PSObject.Properties.Remove("forceIpv4")
    $changedKeys.Add("channels.telegram.network.forceIpv4")
  }

  return $changedKeys.ToArray()
}

function Test-OpenClawTelegramConfigured {
  param([Parameter(Mandatory = $true)][object]$Config)

  if (-not ($Config.PSObject.Properties.Name -contains "channels") -or
      -not ($Config.channels -is [pscustomobject]) -or
      -not ($Config.channels.PSObject.Properties.Name -contains "telegram") -or
      -not ($Config.channels.telegram -is [pscustomobject])) {
    return $false
  }

  $telegram = $Config.channels.telegram
  foreach ($propertyName in @("token", "botToken", "tokenFile")) {
    if ($telegram.PSObject.Properties.Name -contains $propertyName -and
        -not [string]::IsNullOrWhiteSpace([string]$telegram.$propertyName)) {
      return $true
    }
  }

  if ($telegram.PSObject.Properties.Name -contains "accounts" -and $telegram.accounts -is [pscustomobject]) {
    foreach ($accountName in $telegram.accounts.PSObject.Properties.Name) {
      $account = $telegram.accounts.$accountName
      if (-not ($account -is [pscustomobject])) {
        continue
      }

      foreach ($propertyName in @("token", "botToken", "tokenFile")) {
        if ($account.PSObject.Properties.Name -contains $propertyName -and
            -not [string]::IsNullOrWhiteSpace([string]$account.$propertyName)) {
          return $true
        }
      }
    }
  }

  return $false
}

function Ensure-OpenClawTelegramEnabledConfig {
  param([Parameter(Mandatory = $true)][object]$Config)

  $changedKeys = New-Object System.Collections.Generic.List[string]

  if (-not (Test-OpenClawTelegramConfigured -Config $Config)) {
    return $changedKeys.ToArray()
  }

  if (-not ($Config.channels.telegram.PSObject.Properties.Name -contains "enabled") -or
      $Config.channels.telegram.enabled -ne $true) {
    Set-OpenClawJsonNoteProperty -Node $Config.channels.telegram -Name "enabled" -Value $true | Out-Null
    $changedKeys.Add("channels.telegram.enabled")
  }

  if ($Config.channels.telegram.PSObject.Properties.Name -contains "accounts" -and
      $Config.channels.telegram.accounts -is [pscustomobject]) {
    foreach ($accountName in $Config.channels.telegram.accounts.PSObject.Properties.Name) {
      $account = $Config.channels.telegram.accounts.$accountName
      if (-not ($account -is [pscustomobject])) {
        continue
      }

      $hasCredential = $false
      foreach ($propertyName in @("token", "botToken", "tokenFile")) {
        if ($account.PSObject.Properties.Name -contains $propertyName -and
            -not [string]::IsNullOrWhiteSpace([string]$account.$propertyName)) {
          $hasCredential = $true
          break
        }
      }

      if ($hasCredential -and
          (-not ($account.PSObject.Properties.Name -contains "enabled") -or $account.enabled -ne $true)) {
        Set-OpenClawJsonNoteProperty -Node $account -Name "enabled" -Value $true | Out-Null
        $changedKeys.Add("channels.telegram.accounts.$accountName.enabled")
      }
    }
  }

  if ($Config.PSObject.Properties.Name -contains "plugins" -and $Config.plugins -is [pscustomobject]) {
    if ($Config.plugins.PSObject.Properties.Name -contains "allow") {
      $allowedPlugins = @($Config.plugins.allow | ForEach-Object { [string]$_ })
      if ($allowedPlugins -notcontains "telegram") {
        $Config.plugins.allow = @($allowedPlugins + "telegram")
        $changedKeys.Add("plugins.allow")
      }
    }

    if ($Config.plugins.PSObject.Properties.Name -contains "entries" -and $Config.plugins.entries -is [pscustomobject]) {
      if (-not ($Config.plugins.entries.PSObject.Properties.Name -contains "telegram") -or
          -not ($Config.plugins.entries.telegram -is [pscustomobject])) {
        $Config.plugins.entries | Add-Member -NotePropertyName "telegram" -NotePropertyValue ([pscustomobject]@{}) -Force
        $changedKeys.Add("plugins.entries.telegram")
      }

      if (-not ($Config.plugins.entries.telegram.PSObject.Properties.Name -contains "enabled") -or
          $Config.plugins.entries.telegram.enabled -ne $true) {
        Set-OpenClawJsonNoteProperty -Node $Config.plugins.entries.telegram -Name "enabled" -Value $true | Out-Null
        $changedKeys.Add("plugins.entries.telegram.enabled")
      }
    }
  }

  return $changedKeys.ToArray()
}

function Remove-OpenClawLegacyGraphitiPluginConfig {
  param([Parameter(Mandatory = $true)][object]$Config)

  $removedKeys = New-Object System.Collections.Generic.List[string]

  if (-not ($Config.PSObject.Properties.Name -contains "plugins") -or -not ($Config.plugins -is [pscustomobject])) {
    return $removedKeys.ToArray()
  }

  $plugins = $Config.plugins

  if ($plugins.PSObject.Properties.Name -contains "allow" -and $null -ne $plugins.allow) {
    $originalAllow = @($plugins.allow)
    $filteredAllow = @(
      $originalAllow | Where-Object {
        $text = [string]$_
        $keep = -not ($text -match '(?i)graphiti')
        if (-not $keep) {
          $removedKeys.Add("plugins.allow.$text")
        }
        $keep
      }
    )

    if ($filteredAllow.Count -ne $originalAllow.Count) {
      $plugins.allow = @($filteredAllow)
    }
  }

  if ($plugins.PSObject.Properties.Name -contains "entries" -and $plugins.entries -is [pscustomobject]) {
    foreach ($property in @($plugins.entries.PSObject.Properties)) {
      if (($property.Name -match '(?i)graphiti') -or (Test-OpenClawNodeContainsGraphitiReference -Node $property.Value)) {
        [void]$plugins.entries.PSObject.Properties.Remove($property.Name)
        $removedKeys.Add("plugins.entries.$($property.Name)")
      }
    }

    if (@($plugins.entries.PSObject.Properties).Count -eq 0) {
      [void]$plugins.PSObject.Properties.Remove("entries")
      $removedKeys.Add("plugins.entries")
    }
  }

  if ($plugins.PSObject.Properties.Name -contains "slots" -and $plugins.slots -is [pscustomobject]) {
    foreach ($property in @($plugins.slots.PSObject.Properties)) {
      $isLegacyContextEngineSlot = ($property.Name -eq "contextEngine") -and (Test-OpenClawNodeContainsGraphitiReference -Node $property.Value)
      $isLegacyGraphitiSlot = ($property.Name -match '(?i)graphiti') -or (Test-OpenClawNodeContainsGraphitiReference -Node $property.Value)
      if ($isLegacyContextEngineSlot -or $isLegacyGraphitiSlot) {
        [void]$plugins.slots.PSObject.Properties.Remove($property.Name)
        $removedKeys.Add("plugins.slots.$($property.Name)")
      }
    }

    if (@($plugins.slots.PSObject.Properties).Count -eq 0) {
      [void]$plugins.PSObject.Properties.Remove("slots")
      $removedKeys.Add("plugins.slots")
    }
  }

  return $removedKeys.ToArray()
}
