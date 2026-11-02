$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Test-LauncherOptions.ps1"

function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $Rejected = $false
    try { & $Action } catch { $Rejected = $true }
    if (-not $Rejected) { throw "Expected rejection: $Message" }
}

$script:FixedLlamaServerParallelSlots = 1
$Values = @{ CpuMoe='on'; NCpuMoe='0'; MoeCacheMiB='2048'; NCpuFfn='4'; BatchSize='1024'; UBatchSize='256'; FitTarget='1024,512,256'; FitContext='4096'; CacheRam='-1' }
$Config = Convert-ForwardArgsToMenuConfig -Arguments @('--spec-type', 'none')
foreach ($Key in $Values.Keys) { $Config[$Key] = $Values[$Key] }
$Config.ContextSize = '0'
$Config.Slots = '-1'
$Config.ExtraArgs = '--batch-size=512 -ub 128 --fit-target 64 --cache-ram 0 --cpu-moe --seed 42'
$OutputArgs = @(Convert-MenuConfigToForwardArgs -Config $Config)
$RoundTrip = Convert-ForwardArgsToMenuConfig -Arguments $OutputArgs
$Snapshot = Get-SavedLaunchProfileConfigSnapshot -Config $Config
$Restored = $Snapshot | ConvertTo-Json | ConvertFrom-Json
foreach ($Key in $Values.Keys) {
    Assert-Equal $RoundTrip[$Key] $Values[$Key] "Extended round trip $Key"
    Assert-Equal $Restored.$Key $Values[$Key] "Extended persistence $Key"
}
Assert-Equal $RoundTrip.ContextSize '0' 'Auto context round trip'
Assert-Equal $RoundTrip.Slots '-1' 'Auto slots round trip'
Assert-Equal (Resolve-RequestedParallelSlots '-1') -1 'Auto slots resolution'
Assert-Equal (Resolve-RequestedParallelSlots '') 1 'Existing slots default'
Assert-Equal (@($OutputArgs | Where-Object { $_ -eq '--batch-size' }).Count) 1 'No duplicate batch size'
Assert-Equal $RoundTrip.Seed '42' 'CPU MoE cleanup preserved unrelated seed'
$Config.CacheRam = '0'
$Config.ExtraArgs = '-cram -1 --seed 42'
$NegativeOverride = @(Convert-MenuConfigToForwardArgs $Config)
if ($Config.ExtraArgs -match '(?:^|\s)-1(?:\s|$)' -or $NegativeOverride -contains '-cram') { throw 'Overridden negative cache value leaked into ExtraArgs' }
$Config.CacheRam = '-1'
$Items = @(Get-LaunchConfigItems)
Assert-Equal $Items[0].Key 'Model' 'Menu starts with model selection'
Assert-Equal $Items[-1].Key 'Back' 'Menu ends with back action'
foreach ($Option in Get-ExtendedLaunchOptions) {
    Assert-Equal (@($Items | Where-Object Key -eq $Option.Key).Count) 1 "Menu contains $($Option.Key) once"
}

$AliasArgs = @('-cmoe', '-ncmoe', '3', '-ncffn=2', '-b', '512', '-ub=128', '-fitt', '128,256', '-fitc=2048', '-cram', '0')
$Aliases = Convert-ForwardArgsToMenuConfig -Arguments $AliasArgs
foreach ($Pair in @(@('CpuMoe','on'),@('NCpuMoe','3'),@('NCpuFfn','2'),@('BatchSize','512'),@('UBatchSize','128'),@('FitTarget','128,256'),@('FitContext','2048'),@('CacheRam','0'))) {
    Assert-Equal $Aliases[$Pair[0]] $Pair[1] "Alias $($Pair[0])"
}
$Blank = Convert-ForwardArgsToMenuConfig -Arguments @('--spec-type', 'none')
$BlankArgs = @(Convert-MenuConfigToForwardArgs -Config $Blank)
foreach ($Option in Get-ExtendedLaunchOptions) {
    if ($BlankArgs -contains $Option.Flag) { throw "Blank emitted $($Option.Flag)" }
    $InvalidValues = switch ($Option.Kind) {
        'text' { @("invalid`nline") }
        'float' { @('NaN','Infinity','1e99') }
        'positiveFloat' { @('NaN','Infinity','0','-2','1e99') }
        default { @('oops','999999999999999999999','-2') }
    }
    foreach ($Invalid in $InvalidValues) {
        Assert-Rejected { Assert-ExtendedLaunchValue $Option $Invalid } "$($Option.Key)=$Invalid"
    }
}
foreach ($Key in @('BatchSize','UBatchSize','FitContext')) {
    $Option = Get-ExtendedLaunchOptions | Where-Object Key -eq $Key
    Assert-Rejected { Assert-ExtendedLaunchValue $Option '0' } "$Key=0"
}
$ListOption = Get-ExtendedLaunchOptions | Where-Object Key -eq FitTarget
foreach ($Invalid in @('1,',',2','1,,2','1,-1','1,2147483648')) {
    Assert-Rejected { Assert-ExtendedLaunchValue $ListOption $Invalid } "FitTarget=$Invalid"
}
Assert-Rejected { Resolve-RequestedParallelSlots '0' } 'Slots zero'
Assert-Rejected { Resolve-RequestedParallelSlots '-2' } 'Slots negative'
$Blank.ExtraArgs = '--cache-ram 0 --moe-cache-mib 512'
$Legacy = Convert-ForwardArgsToMenuConfig -Arguments @(Convert-MenuConfigToForwardArgs -Config $Blank)
Assert-Equal $Legacy.CacheRam '0' 'Legacy extra cache RAM'
Assert-Equal $Legacy.MoeCacheMiB '512' 'Legacy extra MoE cache'
$Blank.CpuMoe = 'off'
$Blank.ExtraArgs = '--cpu-moe --seed 42'
$OffArgs = @(Convert-MenuConfigToForwardArgs -Config $Blank)
if ($OffArgs -contains '--cpu-moe' -or $OffArgs -notcontains '--seed') { throw 'CPU MoE off handling failed' }

# Deterministic capability tests independent of installed binaries.
$OriginalCapabilities = ${function:Get-LlamaServerCapabilities}
try {
    function Get-LlamaServerCapabilities {
        return [pscustomobject]@{ Executable='test-old.exe'; Flags=@{'--load-mode'=$true; '--spec-type'=$true}; HelpText="--spec-type none,draft-simple`n--split-mode {none,layer,row}" }
    }
    $Old = Convert-ForwardArgsToMenuConfig -Arguments @('--spec-type','none')
    $Old.LlamaBinDirectory = 'test'
    $Old.MoeCacheMiB = '512'
    Assert-Rejected { Convert-MenuConfigToForwardArgs $Old } 'Unsupported MoE cache'
    $Old.MoeCacheMiB = ''
    $Old.ExtraArgs = '--moe-cache-mib=512'
    Assert-Rejected { Convert-MenuConfigToForwardArgs $Old } 'Unsupported legacy ExtraArgs'
    Assert-Rejected { Assert-LlamaLaunchCapabilities $Old @('--spec-type','draft-dflash') } 'Unsupported draft type'
    Assert-Rejected { Assert-LlamaLaunchCapabilities $Old @('--split-mode=tensor') } 'Unsupported tensor splitting'
    $Display = Get-LaunchConfigValueText $Old ([pscustomobject]@{ Key='MoeCacheMiB' })
    if ($Display -notmatch 'Unsupported') { throw 'Unsupported field not marked' }
    $Old.ExtraArgs = ''
    $null = Convert-MenuConfigToForwardArgs $Old
} finally { Set-Item Function:Get-LlamaServerCapabilities $OriginalCapabilities }

# Exercise the actual subprocess and cache on every installed variant; no model load.
$script:DefaultBinRoot = Join-Path $Root 'bin'
$script:LegacyServerExe = Join-Path $Root 'llama-server.exe'
foreach ($Directory in Get-ChildItem -LiteralPath $Root -Directory -Filter 'bin*') {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory.FullName 'llama-server.exe'))) { continue }
    $Capabilities = Get-LlamaServerCapabilities $Directory.FullName
    if (-not $Capabilities.Flags.ContainsKey('--batch-size')) { throw "Missing batch size: $Directory" }
    if (-not [object]::ReferenceEquals($Capabilities, (Get-LlamaServerCapabilities $Directory.FullName))) { throw 'Capability cache miss' }
    $Actual = Convert-ForwardArgsToMenuConfig -Arguments @('--spec-type','none','-b','512','-ub','128')
    $Actual.LlamaBinDirectory = $Directory.FullName
    $null = Convert-MenuConfigToForwardArgs $Actual
    $Actual.MoeCacheMiB = '512'
    if ($Capabilities.Flags.ContainsKey('--moe-cache-mib')) {
        $null = Convert-MenuConfigToForwardArgs $Actual
    } else {
        Assert-Rejected { Convert-MenuConfigToForwardArgs $Actual } "Actual MoE cache support in $Directory"
    }
    Write-Output "PASS: capabilities and export validation for $($Directory.Name)"
}
Write-Output 'PASS: extended tuning, aliases, persistence, precedence, auto values, and capability checks.'
