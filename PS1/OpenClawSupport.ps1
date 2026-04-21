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

  $agentMemoryCmdPath = Join-Path $OpenClawRoot "agentmemory.cmd"

  return @"
@echo off
setlocal
set "TMPDIR=%TEMP%"
set "OPENCLAW_STATE_DIR=$OpenClawRoot"
set "OPENCLAW_CONFIG_PATH=$OpenClawConfigPath"
set "OPENCLAW_GATEWAY_PORT=$GatewayPort"
set "OPENCLAW_WINDOWS_TASK_NAME=OpenClaw Gateway"
set "OPENCLAW_SERVICE_MARKER=openclaw"
set "OPENCLAW_SERVICE_KIND=gateway"
set "EASY_LLAMACPP_ROOT=$EasyLlamacppRoot"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%POWERSHELL_EXE%" (
  set "POWERSHELL_EXE=powershell.exe"
)

if exist "$agentMemoryCmdPath" (
  powershell.exe -NoProfile -Command "try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3111/agentmemory/health' -TimeoutSec 2 | Out-Null; exit 0 } catch { exit 1 }" >nul 2>&1
  if errorlevel 1 cmd.exe /c start "" /min "$agentMemoryCmdPath"
)

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$ManagedGatewayScriptPath"
set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
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
  $sessionPatchScriptName = "patch-openclaw-session-display.mjs"
  $managedGatewayTemplatePath = Join-Path $templateDir $managedGatewayScriptName
  $sessionPatchTemplatePath = Join-Path $templateDir $sessionPatchScriptName
  $managedGatewayScriptPath = Join-Path $scriptsDir $managedGatewayScriptName
  $sessionPatchScriptPath = Join-Path $scriptsDir $sessionPatchScriptName
  $gatewayCmdPath = Join-Path $OpenClawRoot "gateway.cmd"

  $results = New-Object System.Collections.Generic.List[object]
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $managedGatewayTemplatePath `
    -DestinationPath $managedGatewayScriptPath `
    -Description "sidecar-aware gateway script" `
    -BackupSuffix "managed-gateway-script"))
  $results.Add((Sync-OpenClawManagedTextFileFromTemplate `
    -SourcePath $sessionPatchTemplatePath `
    -DestinationPath $sessionPatchScriptPath `
    -Description "control-ui session patch" `
    -BackupSuffix "control-ui-session-patch"))
  $results.Add((Sync-OpenClawManagedGatewayCmd `
    -GatewayCmdPath $gatewayCmdPath `
    -OpenClawRoot $OpenClawRoot `
    -OpenClawConfigPath $OpenClawConfigPath `
    -ManagedGatewayScriptPath $managedGatewayScriptPath `
    -EasyLlamacppRoot $EasyLlamacppRoot `
    -GatewayPort $GatewayPort))

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
