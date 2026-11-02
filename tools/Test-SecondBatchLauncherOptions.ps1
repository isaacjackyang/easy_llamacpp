$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Test-ExtendedLauncherOptions.ps1"

$SecondValues = @{ SpecDraftNMin='0'; SpecDraftUBatch='128'; SpecDraftSampling='probabilistic'; SpecDraftBackendSampling='off'; KvUnified='on'; KvUnifiedPerSlot='8192'; CacheIdleSlots='off'; SleepIdleSeconds='300' }
$Config = Convert-ForwardArgsToMenuConfig @('--spec-type','none')
foreach ($Key in $SecondValues.Keys) { $Config[$Key] = $SecondValues[$Key] }
$Config.ExtraArgs = '--spec-draft-n-min 2 --spec-draft-sampling greedy --spec-draft-backend-sampling -no-kvu --cache-idle-slots --sleep-idle-seconds -1 --seed 42'
$Arguments = @(Convert-MenuConfigToForwardArgs $Config)
$Restored = Convert-ForwardArgsToMenuConfig $Arguments
$Saved = (Get-SavedLaunchProfileConfigSnapshot $Config) | ConvertTo-Json | ConvertFrom-Json
Assert-Equal (Get-SavedLaunchProfileContextText ([pscustomobject]@{ config=$Saved })) '8192 per slot (server pool sizing)' 'Saved profile shows per-slot context'
foreach ($Key in $SecondValues.Keys) {
    Assert-Equal $Restored[$Key] $SecondValues[$Key] "Second batch round trip $Key"
    Assert-Equal $Saved.$Key $SecondValues[$Key] "Second batch persistence $Key"
}
foreach ($Flag in @('--no-spec-draft-backend-sampling','--kv-unified','--no-cache-idle-slots')) {
    Assert-Equal (@($Arguments | Where-Object { $_ -eq $Flag }).Count) 1 "Explicit switch $Flag"
}
if ($Config.ExtraArgs -ne '--seed 42') { throw "Stale ExtraArgs survived: $($Config.ExtraArgs)" }
$Aliases = Convert-ForwardArgsToMenuConfig @('-no-kvu','--no-cache-idle-slots','--no-spec-draft-backend-sampling','--spec-draft-n-ubatch=0','--sleep-idle-seconds=-1')
Assert-Equal $Aliases.KvUnified 'off' 'Negative short KV alias'
Assert-Equal $Aliases.SpecDraftUBatch '0' 'Draft UBatch follows main'
Assert-Equal $Aliases.SleepIdleSeconds '-1' 'Sleep disable'
$Aliases.KvUnified = 'on'
$Aliases.CacheIdleSlots = 'on'
$Aliases.SpecDraftBackendSampling = 'on'
$OnArgs = @(Convert-MenuConfigToForwardArgs $Aliases)
foreach ($Flag in @('--kv-unified','--cache-idle-slots','--spec-draft-backend-sampling')) {
    if ($OnArgs -notcontains $Flag) { throw "Missing positive switch $Flag" }
}
$Sleep = Get-ExtendedLaunchOptions | Where-Object Key -eq SleepIdleSeconds
Assert-Rejected { Assert-ExtendedLaunchValue $Sleep '0' } 'Sleep rejects zero'
$Enum = Get-ExtendedLaunchOptions | Where-Object Key -eq SpecDraftSampling
Assert-Rejected { Assert-ExtendedLaunchValue $Enum 'random' } 'Draft sampling rejects unknown enum'
$EnumItem = Get-LaunchConfigItems | Where-Object Key -eq SpecDraftSampling
Assert-Equal ($EnumItem.Choices -join ',') ',greedy,probabilistic' 'Menu enum choices'

$Removed = @('--draft','--draft-n','--draft-max','--draft-min','--draft-n-min','--spec-ngram-size-n','--spec-ngram-size-m','--spec-ngram-min-hits')
foreach ($Flag in $Removed) {
    Assert-Rejected { Assert-LlamaRemovedArguments @($Flag,'4') } "Removed $Flag"
    Assert-Rejected { Assert-LlamaRemovedArguments @("$Flag=4") } "Removed equals $Flag"
}
$LegacyCapabilities = [pscustomobject]@{ Flags=@{'--draft-max'=$true}; HelpText='--draft-max N   maximum draft length' }
Assert-LlamaRemovedArguments @('--draft-max','4') $LegacyCapabilities
$LegacyCapabilities.HelpText = "--draft-max N`n    the argument has been removed. use --spec-draft-n-max"
Assert-Rejected { Assert-LlamaRemovedArguments @('--draft-max','4') $LegacyCapabilities } 'Removed text on continuation line'

foreach ($Directory in Get-ChildItem -LiteralPath $Root -Directory -Filter 'bin*') {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory.FullName 'llama-server.exe'))) { continue }
    $Capabilities = Get-LlamaServerCapabilities $Directory.FullName
    foreach ($Key in $SecondValues.Keys) {
        $Actual = Convert-ForwardArgsToMenuConfig @('--spec-type','none')
        $Actual.LlamaBinDirectory = $Directory.FullName
        $Actual[$Key] = $SecondValues[$Key]
        $Option = Get-ExtendedLaunchOptions | Where-Object Key -eq $Key
        $Flag = if ($Option.Kind -eq 'switch' -and $SecondValues[$Key] -eq 'off') { $Option.NegativeFlag } else { $Option.Flag }
        if ($Capabilities.Flags.ContainsKey($Flag)) { $null = Convert-MenuConfigToForwardArgs $Actual }
        else { Assert-Rejected { Convert-MenuConfigToForwardArgs $Actual } "Unsupported $Key in $Directory" }
    }
    $Actual = Convert-ForwardArgsToMenuConfig @('--spec-type','none')
    $Actual.LlamaBinDirectory = $Directory.FullName
    $Actual.ExtraArgs = '--draft-max=4'
    $OwnDescription = ($Capabilities.HelpText -split "`n" | Where-Object { $_ -match '^--draft,' }) -join ' '
    if ($OwnDescription -match 'removed' -or -not $Capabilities.Flags.ContainsKey('--draft-max')) {
        Assert-Rejected { Convert-MenuConfigToForwardArgs $Actual } "Obsolete ExtraArgs in $Directory"
    }
    Write-Output "PASS: second batch compatibility in $($Directory.Name)"
}

# Dedicated memory settings must invalidate learned GPU profiles.
$BaseFingerprint = (Get-LaunchTuningContext -ResolvedModelPath 'test.gguf' -Arguments @() -UseExtremeMode $false -AcceleratorInventory @()).Fingerprint
foreach ($Vector in @(@('--kv-unified-per-slot','8192'),@('--spec-draft-n-ubatch','128'),@('--batch-size','512'),@('--no-kv-unified'))) {
    $Changed = Get-LaunchTuningContext -ResolvedModelPath 'test.gguf' -Arguments $Vector -UseExtremeMode $false -AcceleratorInventory @()
    if ($Changed.Fingerprint -eq $BaseFingerprint) { throw "Tuning profile ignores $($Vector -join ' ')" }
}
$SleepFingerprint = (Get-LaunchTuningContext -ResolvedModelPath 'test.gguf' -Arguments @('--sleep-idle-seconds','300') -UseExtremeMode $false -AcceleratorInventory @()).Fingerprint
Assert-Equal $SleepFingerprint $BaseFingerprint 'Sleep does not change memory profile'

# Test the real final command builders while isolating model/GPU discovery.
function Resolve-LaunchMmprojPath { return '' }
function Test-MtpDefaultsEnabled { return $false }
function Get-ModelIndexEntryByPath { return $null }
function Get-ModelGenerationArgs { return @() }
function Resolve-LaunchConfigVisionMmprojPathForCommand { return [pscustomobject]@{ Path=''; AutoResolvedPath='' } }
function Resolve-RequestedThreads { return [pscustomobject]@{ Threads=1; ThreadsBatch=1 } }
function Get-AutoLaunchTuning { return [pscustomobject]@{ UseManagedGpuLayers=$true; FitTargetMiB=$null; CacheRamMiB=$null; ParallelSlots=1 } }
$script:ManagedDefaultContextSize = 131072
$script:ModelPath = Join-Path $Root 'test.gguf'
$script:Port = 8080
$script:Threads = 1
$script:ThreadsBatch = 1
$script:GpuLayers = 'all'
$script:LoadMode = 'mmap'
$script:ModelGenerationArgs = @()
$script:LlamaBinDirectory = $script:DefaultBinRoot
$Config = Convert-ForwardArgsToMenuConfig @('--spec-type','none')
$Config.LlamaBinDirectory = $script:DefaultBinRoot
$Config.ModelPath = $script:ModelPath
$Config.Port = '8080'
$Config.VramAllocationStrategy = 'auto'
foreach ($Case in @(@('','', '131072'),@('','8192',''),@('4096','8192','4096'),@('0','8192','0'))) {
    $Config.ContextSize = $Case[0]
    $Config.KvUnifiedPerSlot = $Case[1]
    $Exported = Get-LlamaServerArgsFromLaunchConfig $Config
    $script:LlamaArgs = @(Convert-MenuConfigToForwardArgs $Config)
    $Launched = @(Get-ServerArgs)
    foreach ($Vector in @($Exported.Arguments, $Launched)) {
        $Value = Get-LlamaArgumentValue -Arguments $Vector -Patterns @('^--ctx-size(?:=(.+))?$')
        Assert-Equal ([string]$Value) $Case[2] "Final context: total=$($Case[0]), per-slot=$($Case[1])"
    }
}
Write-Output 'PASS: second batch persistence, switches, boundaries, removed arguments, and final command builders.'
