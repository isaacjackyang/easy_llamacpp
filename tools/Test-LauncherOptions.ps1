$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Import-FunctionsOnly([string]$Path) {
    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw ($Errors | Out-String) }
    foreach ($Statement in $Ast.EndBlock.Statements) {
        if ($Statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create(($Statement.Extent.Text -replace '^function ', 'function script:')))
        }
    }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message : expected '$Expected', got '$Actual'" }
}

Import-FunctionsOnly (Join-Path $Root 'PS1/Start_LCPP.ps1')
$script:ManagedDefaultMaxOutputTokens = -1
$script:ScriptRoot = $Root
# Keep regression tests independent of local GGUF files and running servers.
function Test-IsMtpCapableModel { return $false }
function Test-UsesBuiltInMtpDraft { return $false }
function Get-LocalSpeculativeDraft { return $null }

$InputArgs = @('-ctk', 'q8_0', '--cache-type-v=f16', '-lzm', 'off', '--swa-checkpoints', '0', '-cms', '128', '--load-mode', 'auto', '--split-mode', 'tensor', '--spec-type', 'none')
$Config = Convert-ForwardArgsToMenuConfig -Arguments $InputArgs
$Config.VramAllocationStrategy = 'manual'
$Config.ExtraArgs = '--cache-type-k f16 --lazy-mode=on --checkpoint-min-step 256'
$OutputArgs = @(Convert-MenuConfigToForwardArgs -Config $Config)
$RoundTrip = Convert-ForwardArgsToMenuConfig -Arguments $OutputArgs
foreach ($Key in @('CacheTypeK', 'CacheTypeV', 'LazyMode', 'ContextCheckpoints', 'CheckpointMinStep', 'LoadMode', 'SplitMode')) {
    Assert-Equal $RoundTrip[$Key] $Config[$Key] "Round trip $Key"
}
$Snapshot = Get-SavedLaunchProfileConfigSnapshot -Config $Config
$Restored = ($Snapshot | ConvertTo-Json | ConvertFrom-Json)
Assert-Equal $Restored.ContextCheckpoints '0' 'Saved zero checkpoints'
Assert-Equal $Restored.LazyMode 'off' 'Saved lazy mode'
Sync-LaunchConfigLoadModeFields -Config $Config
Assert-Equal $Config.LoadMode 'auto' 'Load auto normalization'
$Default = Convert-ForwardArgsToMenuConfig -Arguments @('--spec-type', 'none')
$DefaultArgs = @(Convert-MenuConfigToForwardArgs -Config $Default)
foreach ($Flag in @('--cache-type-k', '--cache-type-v', '--lazy-mode', '--ctx-checkpoints', '--checkpoint-min-step')) {
    if ($DefaultArgs -contains $Flag) { throw "Blank setting unexpectedly emits $Flag" }
}
$Default.ExtraArgs = '--cache-type-k q4_0'
$LegacyArgs = @(Convert-MenuConfigToForwardArgs -Config $Default)
Assert-Equal (Convert-ForwardArgsToMenuConfig -Arguments $LegacyArgs).CacheTypeK 'q4_0' 'Legacy ExtraArgs preserved'
foreach ($Invalid in @('-1', 'x', '2147483648')) {
    $Config.CheckpointMinStep = $Invalid
    $Rejected = $false
    try { $null = Convert-MenuConfigToForwardArgs -Config $Config } catch { $Rejected = $true }
    if (-not $Rejected) { throw "Accepted invalid checkpoint spacing $Invalid" }
}

foreach ($Installer in @('Install_LCPP.ps1', 'Install_LCPP_Prebuilt.ps1')) {
    Import-FunctionsOnly (Join-Path $Root "PS1/$Installer")
    function Invoke-RestMethod {
        param($Uri, $Headers)
        if ($Uri -like '*/latest') { return $script:MockRelease }
        if ($Uri -eq 'https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b10809') {
            return [pscustomobject]@{ tag_name = 'b10809'; assets = @() }
        }
        throw "Unexpected URL $Uri"
    }
    function Invoke-WebRequest {
        param($Uri, $Headers, [switch]$UseBasicParsing)
        return [pscustomobject]@{ Content = $script:MockPointer }
    }
    $script:MockRelease = [pscustomobject]@{ tag_name = 'b10000'; assets = @() }
    Assert-Equal (Get-LatestReleaseMetadata).tag_name 'b10000' "$Installer legacy release"
    $script:MockRelease = [pscustomobject]@{ tag_name = 'v0.4.0'; assets = @([pscustomobject]@{ name = 'nightly-tag.txt'; browser_download_url = 'https://example.test/pointer' }) }
    foreach ($Pointer in @("b10809`n", [Text.Encoding]::UTF8.GetBytes("b10809`n"))) {
        $script:MockPointer = $Pointer
        Assert-Equal (Get-LatestReleaseMetadata).tag_name 'b10809' "$Installer nightly pointer"
    }
    $script:MockPointer = '../invalid'
    $Rejected = $false
    try { $null = Get-LatestReleaseMetadata } catch { $Rejected = $true }
    if (-not $Rejected) { throw "$Installer accepted malformed pointer" }
}
Write-Output 'PASS: launcher options, profile round trips, validation, and release resolution.'
