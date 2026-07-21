$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'PS1\Start_LCPP.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

foreach ($name in @('Convert-ReasoningBudgetToThinkLevel', 'Convert-ThinkLevelToReasoningBudget', 'Sync-LaunchConfigReasoningFields', 'Get-SavedLaunchProfilePersistedKeys', 'Convert-ForwardArgsToMenuConfig', 'Convert-MenuConfigToForwardArgs')) {
    $definition = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Split-ArgumentLine { param([string]$Line) return @() }
function Test-IsMtpCapableModel { return $false }

$parsedDefault = Convert-ForwardArgsToMenuConfig -Arguments @()
if (-not $parsedDefault.ReasoningPreserve) { throw 'Reasoning preservation must default to enabled' }

$legacyConfig = [ordered]@{ ReasoningMode = 'auto'; ThinkLevel = 'Auto' }
Sync-LaunchConfigReasoningFields -Config $legacyConfig
if (-not $legacyConfig.ReasoningPreserve) { throw 'Legacy saved profiles must default preservation to enabled' }
if ((Get-SavedLaunchProfilePersistedKeys) -notcontains 'ReasoningPreserve') { throw 'Saved profiles must persist reasoning preservation' }

$parsedOff = Convert-ForwardArgsToMenuConfig -Arguments @('--no-reasoning-preserve')
if ($parsedOff.ReasoningPreserve) { throw '--no-reasoning-preserve must disable preservation' }

$parsedOn = Convert-ForwardArgsToMenuConfig -Arguments @('--reasoning-preserve')
if (-not $parsedOn.ReasoningPreserve) { throw '--reasoning-preserve must enable preservation' }

$config = Convert-ForwardArgsToMenuConfig -Arguments @('--reasoning', 'on', '--reasoning-budget', '4096')
$config.ModelPath = ''
$config.MtpEnabled = $false
$args = @(Convert-MenuConfigToForwardArgs -Config $config)
if ($args -notcontains '--reasoning-preserve') { throw 'Enabled preservation must emit --reasoning-preserve' }
if ($args -contains '--no-reasoning-preserve') { throw 'Enabled preservation must not emit the disabling flag' }

$config.ReasoningPreserve = $false
$args = @(Convert-MenuConfigToForwardArgs -Config $config)
if ($args -notcontains '--no-reasoning-preserve') { throw 'Disabled preservation must emit --no-reasoning-preserve' }

Write-Host 'Reasoning preservation tests passed.'
