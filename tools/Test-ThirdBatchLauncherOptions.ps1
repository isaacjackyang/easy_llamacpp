$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Test-SecondBatchLauncherOptions.ps1"

$Message = ([string][char]0x4E2D) + ' Please end "thinking" & answer 100% ! ^ | < > now'
$ThirdValues = @{ Seed='4294967295'; RepeatPenalty='1.1'; FrequencyPenalty='-0.25'; RepeatLastN='64'; ReasoningFormat='deepseek'; ReasoningBudgetMessage=$Message; CachePrompt='on'; CacheReuse='256'; ContextShift='off' }
$Config = Convert-ForwardArgsToMenuConfig @('--spec-type','none')
foreach ($Key in $ThirdValues.Keys) { $Config[$Key] = $ThirdValues[$Key] }
$Config.ExtraArgs = '--seed -1 --repeat-penalty 1 --frequency-penalty 0 --repeat-last-n 0 --reasoning-format none --reasoning-budget-message "old message" --no-cache-prompt --cache-reuse 0 --context-shift'
$Arguments = @(Convert-MenuConfigToForwardArgs $Config)
$Restored = Convert-ForwardArgsToMenuConfig $Arguments
$Snapshot = (Get-SavedLaunchProfileConfigSnapshot $Config) | ConvertTo-Json | ConvertFrom-Json
foreach ($Key in $ThirdValues.Keys) {
    Assert-Equal $Restored[$Key] $ThirdValues[$Key] "Third batch round trip $Key"
    Assert-Equal $Snapshot.$Key $ThirdValues[$Key] "Third batch saved $Key"
}
Assert-Equal $Config.ExtraArgs '' 'All explicit third batch fields override raw duplicates'
foreach ($Flag in @('--seed','--repeat-penalty','--frequency-penalty','--repeat-last-n','--reasoning-format','--reasoning-budget-message','--cache-prompt','--cache-reuse','--no-context-shift')) {
    Assert-Equal (@($Arguments | Where-Object { $_ -eq $Flag }).Count) 1 "Single flag $Flag"
}
$Alias = Convert-ForwardArgsToMenuConfig @('-s','42','--reasoning-budget-message=two words','--no-cache-prompt','--context-shift')
Assert-Equal $Alias.Seed '42' 'Seed short alias'
Assert-Equal $Alias.ReasoningBudgetMessage 'two words' 'Text equals syntax'
Assert-Equal $Alias.CachePrompt 'off' 'Negative prompt cache'
Assert-Equal $Alias.ContextShift 'on' 'Positive context shift'
$Legacy = Convert-ForwardArgsToMenuConfig @('--unknown-option','two words','--spec-type','none')
Assert-Equal (Split-ArgumentLine $Legacy.ExtraArgs)[1] 'two words' 'Unknown quoted values survive parsing'

$SeedOption = Get-ExtendedLaunchOptions | Where-Object Key -eq Seed
foreach ($Value in @('-1','0','2147483648','4294967295')) { Assert-ExtendedLaunchValue $SeedOption $Value }
foreach ($Value in @('-2','4294967296','1.5')) { Assert-Rejected { Assert-ExtendedLaunchValue $SeedOption $Value } "Invalid seed $Value" }
$Repeat = Get-ExtendedLaunchOptions | Where-Object Key -eq RepeatPenalty
foreach ($Value in @('0','-1','NaN','Infinity','1e99','1e-45')) { Assert-Rejected { Assert-ExtendedLaunchValue $Repeat $Value } "Invalid repeat penalty $Value" }
$Frequency = Get-ExtendedLaunchOptions | Where-Object Key -eq FrequencyPenalty
$Culture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    Assert-ExtendedLaunchValue $Frequency '-0.25'
    Assert-Rejected { Assert-ExtendedLaunchValue $Frequency '0,25' } 'Locale-independent decimal parsing'
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $Culture }

# Literal argument-like text is data, not an obsolete/unsupported CLI flag.
foreach ($Literal in @('--draft-max','--spec-type','--split-mode')) {
    $TextConfig = Convert-ForwardArgsToMenuConfig @('--spec-type','none')
    $TextConfig.LlamaBinDirectory = $script:DefaultBinRoot
    $TextConfig.ReasoningBudgetMessage = $Literal
    $null = Convert-MenuConfigToForwardArgs $TextConfig
}
Test-LlamaArgConflict @('--reasoning-budget-message','--model')
Assert-Rejected { Test-LlamaArgConflict @('--model','test.gguf') } 'Actual managed model argument still rejected'
$SearchText = Get-ArgumentSearchText @('--reasoning-budget-message','stop --fit off and --cache-ram 0')
if ($SearchText -match '--fit off|--cache-ram 0') { throw 'Prompt text affected memory tuning detection' }

# Category pagination must cover every card once at any terminal size.
$Items = @(Get-LaunchConfigItems)
$Groups = @(Get-LaunchConfigGroups)
Assert-Equal $Groups.Count 8 'Eight category shortcuts'
$AssignedKeys = @($Groups | ForEach-Object { $_.Keys })
foreach ($Item in $Items) { Assert-Equal (@($AssignedKeys | Where-Object { $_ -eq $Item.Key }).Count) 1 "Category assignment $($Item.Key)" }
foreach ($Size in @(1,6,18,1000)) {
    $Pages = @(Get-LaunchConfigPages $Items $Size)
    $Cards = @($Pages | ForEach-Object { $_.Items })
    Assert-Equal $Cards.Count $Items.Count "Page coverage at size $Size"
    foreach ($Page in $Pages) { if ($Page.Items.Count -lt 1 -or $Page.Items.Count -gt $Size) { throw 'Invalid page size' } }
    foreach ($Item in $Items) { Assert-Equal (@($Cards | Where-Object Key -eq $Item.Key).Count) 1 "Single card $($Item.Key)" }
}
$Future = [pscustomobject]@{ Key='FutureOption'; Type='text' }
$Fallback = @(Get-LaunchConfigPages @($Future) 6)
Assert-Equal $Fallback[0].Group 'Service' 'Unknown future cards remain visible'

# Reimport real functions overwritten by earlier command-builder isolation.
Import-FunctionsOnly (Join-Path $Root 'PS1/Start_LCPP.ps1')
function Test-IsMtpCapableModel { return $false }
function Test-UsesBuiltInMtpDraft { return $false }
function Get-LocalSpeculativeDraft { return $null }
foreach ($Directory in Get-ChildItem -LiteralPath $Root -Directory -Filter 'bin*') {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory.FullName 'llama-server.exe'))) { continue }
    $Capabilities = Get-LlamaServerCapabilities $Directory.FullName
    foreach ($Key in $ThirdValues.Keys) {
        $Actual = Convert-ForwardArgsToMenuConfig @('--spec-type','none')
        $Actual.LlamaBinDirectory = $Directory.FullName
        $Actual[$Key] = $ThirdValues[$Key]
        $Option = Get-ExtendedLaunchOptions | Where-Object Key -eq $Key
        $Flag = if ($Option.Kind -eq 'switch' -and $ThirdValues[$Key] -eq 'off') { $Option.NegativeFlag } else { $Option.Flag }
        if ($Capabilities.Flags.ContainsKey($Flag)) { $null = Convert-MenuConfigToForwardArgs $Actual }
        else { Assert-Rejected { Convert-MenuConfigToForwardArgs $Actual } "Third batch unsupported $Key in $Directory" }
    }
    Write-Output "PASS: third batch compatibility in $($Directory.Name)"
}

# Exercise a generated CMD launcher against an argument-capture stub, never a model.
$Config.ModelPath = Join-Path $Root 'test.gguf'
$Config.LlamaBinDirectory = $script:DefaultBinRoot
$Config.Port = '8080'
$Config.Threads = '1'
$Config.ThreadsBatch = '1'
$Config.ReadyTimeoutSec = '180'
$Config.GpuLayers = 'auto'
$Config.LaunchMode = 'Background Service'
$TestDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Lcpp-third-' + [guid]::NewGuid().ToString('N'))
$OriginalPs1Root = $script:Ps1Root
$OriginalCapture = $env:LCPP_TEST_CAPTURE
$StubPath = Join-Path $TestDirectory 'Start_LCPP.ps1'
$CommandPath = Join-Path $TestDirectory 'profile.cmd'
$CapturePath = Join-Path $TestDirectory 'capture.json'
try {
    [void](New-Item -ItemType Directory -Path $TestDirectory)
    $Stub = @'
param([string]$EncodedLlamaArgs, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
[IO.File]::WriteAllText($env:LCPP_TEST_CAPTURE, (ConvertTo-Json -InputObject @{ Payload=$EncodedLlamaArgs; Rest=$Rest } -Depth 5), [Text.Encoding]::UTF8)
'@
    [IO.File]::WriteAllText($StubPath, $Stub)
    $script:Ps1Root = $TestDirectory
    $env:LCPP_TEST_CAPTURE = $CapturePath
    [IO.File]::WriteAllText($CommandPath, (New-ProfileCommandFileContent $Config 'test'), (New-Object Text.UTF8Encoding($false)))
    & $env:ComSpec /d /c ('""' + $CommandPath + '" --seed 99"') | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $CapturePath)) { throw 'Generated CMD launcher failed' }
    $Captured = Get-Content -LiteralPath $CapturePath -Raw | ConvertFrom-Json
    $Decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Captured.Payload)) | ConvertFrom-Json
    $FromCmd = Convert-ForwardArgsToMenuConfig $Decoded
    Assert-Equal $FromCmd.ReasoningBudgetMessage $Message 'CMD preserves spaces, quotes and shell characters'
    Assert-Equal ($Captured.Rest[-2..-1] -join ' ') '--seed 99' 'CMD forwards runtime arguments'
    $Tokens=$null; $Errors=$null
    $Ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'PS1/Start_LCPP.ps1'),[ref]$Tokens,[ref]$Errors)
    $Decoder = $Ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if ($EncodedLlamaArgs)') } | Select-Object -First 1
    $DecoderText = $Decoder.Extent.Text
    $DecodedThroughLauncher = & {
        param($Payload,$Code)
        $EncodedLlamaArgs=$Payload; $LlamaArgs=@('--seed','99')
        . ([scriptblock]::Create($Code))
        return ,$LlamaArgs
    } $Captured.Payload $DecoderText
    Assert-Equal $DecodedThroughLauncher[-1] '99' 'Runtime overrides follow decoded profile'
    Assert-Equal (Convert-ForwardArgsToMenuConfig $DecodedThroughLauncher).ReasoningBudgetMessage $Message 'Launcher payload decoding'
    foreach ($BadJson in @('"scalar"','{"key":"value"}','[1]','[null]')) {
        $BadPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BadJson))
        Assert-Rejected {
            & { param($Payload,$Code) $EncodedLlamaArgs=$Payload; $LlamaArgs=@(); . ([scriptblock]::Create($Code)) } $BadPayload $DecoderText
        } "Invalid encoded payload $BadJson"
    }
    $SinglePayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('["--metrics"]'))
    $SingleDecoded = & {
        param($Payload,$Code) $EncodedLlamaArgs=$Payload; $LlamaArgs=@(); . ([scriptblock]::Create($Code)); return ,$LlamaArgs
    } $SinglePayload $DecoderText
    Assert-Equal $SingleDecoded[0] '--metrics' 'Singleton encoded array'
} finally {
    $script:Ps1Root = $OriginalPs1Root
    $env:LCPP_TEST_CAPTURE = $OriginalCapture
    foreach ($File in @($StubPath,$CommandPath,$CapturePath)) { if (Test-Path -LiteralPath $File) { Remove-Item -LiteralPath $File } }
    if (Test-Path -LiteralPath $TestDirectory) { Remove-Item -LiteralPath $TestDirectory }
}

# Check literal flag text through final launch/export normalization too.
function Resolve-LaunchMmprojPath { return '' }
function Test-MtpDefaultsEnabled { return $false }
function Get-ModelIndexEntryByPath { return $null }
function Get-ModelGenerationArgs { return @() }
function Resolve-LaunchConfigVisionMmprojPathForCommand { return [pscustomobject]@{ Path=''; AutoResolvedPath='' } }
function Resolve-RequestedThreads { return [pscustomobject]@{ Threads=1; ThreadsBatch=1 } }
function Get-AutoLaunchTuning { return [pscustomobject]@{ UseManagedGpuLayers=$true; FitTargetMiB=$null; CacheRamMiB=$null; ParallelSlots=1 } }
$Config.VramAllocationStrategy='auto'
$script:LlamaBinDirectory=$script:DefaultBinRoot
$script:ModelPath=$Config.ModelPath
foreach ($Literal in @('--spec-type','--parallel','--cache-type-k','--draft-max')) {
    $Config.ReasoningBudgetMessage=$Literal
    $Exported=Get-LlamaServerArgsFromLaunchConfig $Config
    $script:LlamaArgs=@(Convert-MenuConfigToForwardArgs $Config)
    $Launched=@(Get-ServerArgs)
    foreach ($Vector in @($Exported.Arguments,$Launched)) {
        $ReadMessage=Get-LlamaArgumentValue -Arguments $Vector -Patterns @('^--reasoning-budget-message(?:=(.+))?$')
        Assert-Equal $ReadMessage $Literal 'Literal flag text survives final command building'
    }
}
$Config.ReasoningBudgetMessage=$Message

# Drive the actual menu loop with simulated console keys and a silent renderer.
function Get-ConsoleWidth { return 120 }
function Get-ConsoleHeight { return 60 }
function Write-Host { param([Parameter(ValueFromRemainingArguments=$true)]$Rest) }
function Show-MenuHeader { param($Title,$Subtitle) $script:MenuHeaders.Add($Subtitle) }
function Get-LaunchConfigCardLines { param($Item,$Config,$Width,$Selected) return $Item.Key }
function Show-LaunchConfigItemHelp { }
function Edit-LaunchConfigItem { param($Config,$Item,$IndexPath) $script:EditedKey=$Item.Key }
function Read-ConsoleKey {
    if ($script:KeyPosition -ge $script:TestKeys.Count) { throw 'Menu consumed unexpected keys' }
    $Code=$script:TestKeys[$script:KeyPosition++]; return [pscustomobject]@{ VirtualKeyCode=$Code }
}
$script:MenuHeaders = New-Object 'Collections.Generic.List[string]'
$script:TestKeys=@(116,13,9,27); $script:KeyPosition=0
$null=Show-LaunchConfigGrid $Config ''
Assert-Equal $script:EditedKey 'Temperature' 'F5 jumps directly to sampling'
if ($script:MenuHeaders[-1] -notmatch 'Reasoning') { throw 'Tab failed to reach next category' }
$script:TestKeys=@(119,39,40,40,13); $script:KeyPosition=0
$LaunchResult=Show-LaunchConfigGrid $Config ''
if (-not [object]::ReferenceEquals($LaunchResult,$Config)) { throw 'F8 action page failed to launch current config' }
Write-Output 'PASS: third batch values, CMD export, categories, keyboard navigation, and version compatibility.'
