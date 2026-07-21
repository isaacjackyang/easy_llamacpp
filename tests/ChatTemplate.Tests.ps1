$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'PS1\Start_LCPP.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

foreach ($name in @('Resolve-ScriptRelativePath', 'Get-ChatTemplateFiles', 'Select-ChatTemplateFile', 'Convert-ReasoningBudgetToThinkLevel', 'Convert-ThinkLevelToReasoningBudget', 'Get-SavedLaunchProfilePersistedKeys', 'Convert-ForwardArgsToMenuConfig', 'Convert-MenuConfigToForwardArgs')) {
    $definition = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Split-ArgumentLine { param([string]$Line) return @() }
function Test-IsMtpCapableModel { return $false }
function Format-BilingualText { param([string]$ChineseText, [string]$EnglishText) return $ChineseText }
function Show-ListMenu {
    param([string]$Title, [string]$Subtitle, [object[]]$Items, [int]$SelectedIndex)
    $script:CapturedTemplateItems = @($Items)
    return $Items[1].Value
}
$ScriptRoot = $root

$defaultConfig = Convert-ForwardArgsToMenuConfig -Arguments @()
if (-not [string]::IsNullOrEmpty($defaultConfig.ChatTemplate)) { throw 'Chat template must default to GGUF metadata' }

$parsed = Convert-ForwardArgsToMenuConfig -Arguments @('--chat-template', 'chatml')
if ($parsed.ChatTemplate -ne 'chatml') { throw '--chat-template must be parsed into the menu config' }
if ((Get-SavedLaunchProfilePersistedKeys) -notcontains 'ChatTemplate') { throw 'Saved profiles must persist the chat template' }

$parsed.ModelPath = ''
$parsed.MtpEnabled = $false
$args = @(Convert-MenuConfigToForwardArgs -Config $parsed)
$templateIndex = [Array]::IndexOf($args, '--chat-template')
if ($templateIndex -lt 0 -or $args[$templateIndex + 1] -ne 'chatml') { throw 'Configured chat template must be forwarded to llama.cpp' }

$templates = @(Get-ChatTemplateFiles)
$froggeric = $templates | Where-Object { $_.Name -eq 'froggeric-qwen-chat-template.jinja' } | Select-Object -First 1
if (-not $froggeric) { throw 'Downloaded froggeric template must appear in the chat template picker' }

$selection = Select-ChatTemplateFile -CurrentValue ''
if ($script:CapturedTemplateItems.Count -lt 2) { throw 'Chat template picker must include GGUF metadata and downloaded templates' }
if ($selection.Path -ne $froggeric.RelativePath) { throw 'Chat template picker must return the selected project-relative path' }

$fileConfig = Convert-ForwardArgsToMenuConfig -Arguments @('--chat-template-file', $froggeric.RelativePath)
$fileConfig.ModelPath = ''
$fileConfig.MtpEnabled = $false
$args = @(Convert-MenuConfigToForwardArgs -Config $fileConfig)
$templateFileIndex = [Array]::IndexOf($args, '--chat-template-file')
if ($templateFileIndex -lt 0 -or $args[$templateFileIndex + 1] -ne $froggeric.FullName) { throw 'Selected template files must use --chat-template-file with an absolute path' }

$defaultConfig.ModelPath = ''
$defaultConfig.MtpEnabled = $false
$args = @(Convert-MenuConfigToForwardArgs -Config $defaultConfig)
if ($args -contains '--chat-template') { throw 'Blank chat template must defer to GGUF metadata' }

$source = Get-Content -Raw -LiteralPath $sourcePath
if ($source -notmatch 'chat-template-file[\s\S]*?Add-DefaultLlamaArgument[\s\S]*?-Flag "--jinja"') { throw 'Template file launches must enable Jinja automatically' }

Write-Host 'Chat template tests passed.'
