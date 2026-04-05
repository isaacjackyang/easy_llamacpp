<#
.SYNOPSIS
Launches llama.cpp through an interactive menu or direct control switches.

.DESCRIPTION
By default the script opens an interactive launcher menu.
The first screen lets you choose Quick Start or Tune And Launch, then select a model
from model-index.json, review model capabilities, and launch either a background service
or the built-in Web UI. Direct control switches such as -Status, -Stop, and -LlamaHelp
still work without opening the menu. The script prefers llama.cpp binaries stored under
the bin subfolder. Script parameters are the wrapper's own options. Additional
llama-server.exe options can be passed through as trailing arguments.

.PARAMETER Port
TCP port used by llama-server.exe. Default is 8080.
Use a valid, free port number such as 8080 or 8081. In practice this should be 1-65535.

.PARAMETER GpuLayers
Value passed to --gpu-layers.
Allowed values are:
- auto
- all
- a non-negative integer string such as 0, 35, or 99
Default is auto. In auto mode, the wrapper leaves --gpu-layers unset so llama.cpp
can fit the model to the detected device memory.

.PARAMETER Threads
Value passed to --threads.
Use a positive integer to set it manually.
Default is -1, which means auto and resolves to logical CPU count minus 2, with a minimum of 1.

.PARAMETER ThreadsBatch
Value passed to --threads-batch.
Use a positive integer to set it manually.
Default is -1, which means auto and resolves to the logical CPU count.

.PARAMETER ModelPath
Path to the GGUF model file.
Accepts either an absolute path or a path relative to the launcher root.
When omitted, the launcher uses the default_model_id entry from json\model-index.json.

.PARAMETER ModelIndexPath
Path to the model index JSON file used by the interactive menu.
Accepts either an absolute path or a path relative to the launcher root.
Default is .\json\model-index.json.

.PARAMETER OpenPath
HTTP path opened in the browser after the server is ready.
Default is /v1/models. If you omit the leading slash, the script adds it automatically.

.PARAMETER ReadyTimeoutSec
Maximum time, in seconds, to wait before giving up on browser auto-open.
Default is 180. Use a positive integer such as 60, 120, or 300.

.PARAMETER Background
Starts llama-server.exe in the background and returns control to PowerShell immediately.

.PARAMETER Status
Shows the tracked server status, runtime settings, GPU offload summary, and log file paths.

.PARAMETER ShowGpuOffload
Compatibility alias for -Status. Kept so older shortcuts still work,
but GPU offload details now appear inside the main status view.

.PARAMETER ExtremeMode
Applies a more aggressive auto-fit strategy intended to push GPU VRAM harder.
This mainly matters when GpuLayers is auto. It uses a smaller fit target, fewer slots,
and a smaller prompt cache unless you override those options yourself.

.PARAMETER AutoTune
Learns a reusable per-model GPU tuning profile after a successful near-full-VRAM launch.
When a saved profile matches the same model, accelerator layout, and VRAM-relevant launch
arguments, later launches reuse the saved GPU layers, fit target, cache limit, and slots automatically.

.PARAMETER Stop
Stops the tracked llama.cpp server process and removes the PID file.

.PARAMETER NoBrowser
Prevents the script from opening a browser after the server becomes ready.

.PARAMETER NoPause
Prevents the script from waiting for Enter before exiting in foreground mode.

.PARAMETER LlamaHelp
Prints the underlying llama-server.exe help and exits.

.PARAMETER BypassMenu
Skips the interactive menu and uses the supplied parameters directly.
Useful for scheduled tasks, shortcuts, or automation.

.PARAMETER LlamaArgs
Any remaining arguments are forwarded directly to llama-server.exe.
Use this to access llama.cpp options that are not explicitly wrapped by this script.
Do not pass managed options such as --model, --port, --gpu-layers, --threads, or --threads-batch here.

.EXAMPLE
.\PS1\Start_LCPP.ps1
Opens the interactive launcher menu.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -Background -ModelPath "C:\Models\example.gguf"
Opens the interactive launcher and preloads the supplied values.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -Port 8081 -GpuLayers all -Threads 12 -ThreadsBatch 16
Starts the server on port 8081 and uses explicit CPU/GPU settings.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -Status
Shows the current tracked server status, runtime settings, and GPU offload summary.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -ShowGpuOffload
Compatibility alias for -Status.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -ExtremeMode
Starts the server with the aggressive auto-fit profile.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -AutoTune
Starts the server, evaluates the resulting VRAM usage, and saves a reusable tuning profile if it qualifies.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -Stop
Stops the tracked server.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -LlamaHelp
Shows the llama-server.exe help output.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -Background --ctx-size 4096 --metrics
Opens the interactive launcher and preloads additional llama-server.exe arguments.

.EXAMPLE
.\PS1\Start_LCPP.ps1 -BypassMenu -Background -NoBrowser -NoPause
Starts the server directly without opening the menu.

.NOTES
Before each launch, the script automatically stops older llama-server.exe processes
started from this workspace so stale GPU allocations do not linger.
When GpuLayers is left at auto, the script also detects available GPU VRAM and system RAM
to apply a smaller fit target, a bounded prompt cache, and fewer server slots on tighter systems.
ExtremeMode makes that auto-fit behavior more aggressive for users who want to push VRAM harder.
AutoTune can learn and reuse a per-model tuning profile when a launch fits fully in GPU memory
and lands near the target VRAM usage range.
The script stores the tracked PID in logs\llama-server.pid and writes logs to
logs\llama-server.stdout.log and logs\llama-server.stderr.log under the launcher root.
The preferred layout stores llama.cpp executables and DLLs in the bin subfolder.
For compatibility, the script can still use a legacy llama-server.exe beside the script if bin is not present.
ModelPath accepts absolute paths and paths relative to the launcher root.
ModelIndexPath accepts absolute paths and paths relative to the launcher root.
Status and Stop operate on the tracked server process recorded in the PID file.
The interactive menu is the default entry point for manual launches.
Use Get-Help .\PS1\Start_LCPP.ps1 -Detailed or Get-Help .\PS1\Start_LCPP.ps1 -Examples to view this help.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 8080,
    [ValidatePattern('^(auto|all|\d+)$')]
    [string]$GpuLayers = "auto",
    [int]$Threads = -1,
    [int]$ThreadsBatch = -1,
    [string]$ModelPath = $null,
    [string]$ModelIndexPath = ".\json\model-index.json",
    [string]$OpenPath = "/v1/models",
    [int]$ReadyTimeoutSec = 180,
    [switch]$Background,
    [switch]$Status,
    [switch]$ShowGpuOffload,
    [switch]$ExtremeMode,
    [switch]$AutoTune,
    [switch]$Stop,
    [switch]$LlamaHelp,
    [switch]$BypassMenu,
    [switch]$NoBrowser,
    [switch]$NoPause,
    [switch]$ReturnNonZeroOnError,
    [switch]$WrapperControlsPause,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$LlamaArgs
)

$ErrorActionPreference = "Stop"

$LauncherScriptHome = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ScriptRoot = if ([string]::Equals([System.IO.Path]::GetFileName($LauncherScriptHome), "PS1", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $LauncherScriptHome
}
else {
    $LauncherScriptHome
}
$Ps1Root = $LauncherScriptHome
$PreferredBinRoot = Join-Path $ScriptRoot "bin"
$LegacyBinRoot = $ScriptRoot
$LogRoot = Join-Path $ScriptRoot "logs"
$JsonRoot = Join-Path $ScriptRoot "json"
$LlamaBinRoot = if (Test-Path -LiteralPath (Join-Path $PreferredBinRoot "llama-server.exe")) {
    $PreferredBinRoot
}
elseif (Test-Path -LiteralPath (Join-Path $LegacyBinRoot "llama-server.exe")) {
    $LegacyBinRoot
}
else {
    $PreferredBinRoot
}
$ServerExe = Join-Path $LlamaBinRoot "llama-server.exe"
$LegacyServerExe = Join-Path $LegacyBinRoot "llama-server.exe"
$ServerExeCandidates = @(
    $ServerExe
    $LegacyServerExe
) | Select-Object -Unique
$LegacyPidFile = Join-Path $ScriptRoot "llama-server.pid"
$LegacyStdOutLog = Join-Path $ScriptRoot "llama-server.stdout.log"
$LegacyStdErrLog = Join-Path $ScriptRoot "llama-server.stderr.log"
$LegacyModelIndexFile = Join-Path $ScriptRoot "model-index.json"
$LegacyTuningProfileFile = Join-Path $ScriptRoot "model-tuning.json"
$LegacyModelSwitchTimingFile = Join-Path $ScriptRoot "model-switch-times.json"
$PidFile = Join-Path $LogRoot "llama-server.pid"
$StdOutLog = Join-Path $LogRoot "llama-server.stdout.log"
$StdErrLog = Join-Path $LogRoot "llama-server.stderr.log"
$TuningProfileFile = Join-Path $JsonRoot "model-tuning.json"
$ModelSwitchTimingFile = Join-Path $JsonRoot "model-switch-times.json"
# Edit this line to force model scanning from a specific GGUF folder on each interactive launch.
$ConfiguredModelScanPath = "E:\LLM Model"
$BaseUrl = "http://127.0.0.1:$Port"
$BrowserJob = $null
$UsedInteractiveMenu = $false
$EncounteredFatalError = $false
$LogicalThreads = [Environment]::ProcessorCount
$RawThreads = $Threads
$RawThreadsBatch = $ThreadsBatch
$script:ModelFileSizeBytesCache = @{}
$script:ModelFileSizeLabelCache = @{}
$script:ModelRepeatingLayerCountCache = @{}
$script:LastAutoTuneProfile = $null
$script:BackgroundStartupProgressLineLength = 0
$script:BackgroundStartupProgressLastText = $null
$ServerCleanupTimeoutSec = 20
$ServerCleanupSettleMs = 2000
$BackgroundStartupCheckSec = 20
$BackgroundStartupPollMs = 1000
$BackgroundExitGraceSec = 6
$StartupFailureLogLineCount = 40
$AutoTuneTargetUsagePercent = 95.0
$AutoTuneMinUsagePercent = 93.0
$AutoTuneMaxUsagePercent = 98.5
$AutoTuneReuseHeadroomMiB = 128

foreach ($DirectoryPath in @($LogRoot, $JsonRoot)) {
    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $DirectoryPath -Force)
    }
}

foreach ($Migration in @(
        [pscustomobject]@{ Legacy = $LegacyModelIndexFile; Preferred = (Join-Path $JsonRoot "model-index.json") },
        [pscustomobject]@{ Legacy = $LegacyTuningProfileFile; Preferred = $TuningProfileFile },
        [pscustomobject]@{ Legacy = $LegacyModelSwitchTimingFile; Preferred = $ModelSwitchTimingFile }
    )) {
    if ((Test-Path -LiteralPath $Migration.Legacy) -and -not (Test-Path -LiteralPath $Migration.Preferred)) {
        try {
            Move-Item -LiteralPath $Migration.Legacy -Destination $Migration.Preferred -Force
        }
        catch {
        }
    }
}

if (-not $OpenPath.StartsWith("/")) {
    $OpenPath = "/$OpenPath"
}

function Get-ServerArgs {
    param(
        $AutoTuning
    )

    $EffectiveGpuLayers = if ($AutoTuning -and -not [string]::IsNullOrWhiteSpace([string]$AutoTuning.EffectiveGpuLayers)) {
        [string]$AutoTuning.EffectiveGpuLayers
    }
    else {
        [string]$GpuLayers
    }

    $Arguments = New-Object System.Collections.Generic.List[string]
    $Arguments.Add("-m")
    $Arguments.Add($ModelPath)
    $Arguments.Add("--port")
    $Arguments.Add([string]$Port)

    if (-not $AutoTuning -or -not $AutoTuning.UseManagedGpuLayers) {
        $Arguments.Add("--gpu-layers")
        $Arguments.Add($EffectiveGpuLayers)
    }

    $Arguments.Add("--threads")
    $Arguments.Add([string]$Threads)
    $Arguments.Add("--threads-batch")
    $Arguments.Add([string]$ThreadsBatch)

    if ($AutoTuning) {
        if ($null -ne $AutoTuning.FitTargetMiB) {
            $Arguments.Add("--fit-target")
            $Arguments.Add([string]$AutoTuning.FitTargetMiB)
        }

        if ($null -ne $AutoTuning.CacheRamMiB) {
            $Arguments.Add("--cache-ram")
            $Arguments.Add([string]$AutoTuning.CacheRamMiB)
        }

        if ($null -ne $AutoTuning.ParallelSlots) {
            $Arguments.Add("--parallel")
            $Arguments.Add([string]$AutoTuning.ParallelSlots)
        }
    }

    foreach ($Argument in $LlamaArgs) {
        $Arguments.Add($Argument)
    }

    return @($Arguments)
}

function Test-LlamaArgConflict {
    param(
        [string[]]$Arguments
    )

    if (-not $Arguments) {
        return
    }

    $ManagedPatterns = @(
        '^-m$',
        '^--model$',
        '^-m=',
        '^--model=',
        '^--port$',
        '^--port=',
        '^-t$',
        '^--threads$',
        '^-t=',
        '^--threads=',
        '^-tb$',
        '^--threads-batch$',
        '^-tb=',
        '^--threads-batch=',
        '^-ngl$',
        '^--gpu-layers$',
        '^--n-gpu-layers$',
        '^-ngl=',
        '^--gpu-layers=',
        '^--n-gpu-layers='
    )

    foreach ($Argument in $Arguments) {
        foreach ($Pattern in $ManagedPatterns) {
            if ($Argument -match $Pattern) {
                throw "Do not pass managed llama-server arguments via trailing args: $Argument. Use the script parameters instead."
            }
        }
    }
}

function ConvertTo-ArgumentString {
    param(
        [string[]]$Arguments
    )

    $QuotedArguments = foreach ($Argument in $Arguments) {
        if ($Argument -match '[\s"]') {
            '"{0}"' -f $Argument.Replace('"', '\"')
        }
        else {
            $Argument
        }
    }

    return ($QuotedArguments -join " ")
}

function Get-ArgumentSearchText {
    param(
        [string[]]$Arguments
    )

    if (-not $Arguments) {
        return " "
    }

    return " " + (($Arguments | ForEach-Object { $_.Trim() }) -join " ") + " "
}

function Normalize-TuningText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    return $Text.Trim()
}

function Get-AcceleratorInventory {
    $Inventory = New-Object System.Collections.Generic.List[object]

    try {
        $DeviceOutput = & $ServerExe --list-devices 2>&1
        foreach ($Line in $DeviceOutput) {
            if ([string]$Line -match '^\s*(CUDA\d+):\s+(.+?)\s+\((\d+)\s+MiB,\s+(\d+)\s+MiB free\)') {
                $Inventory.Add([pscustomobject]@{
                    Id       = [string]$Matches[1].Trim()
                    Index    = [int]([regex]::Match($Matches[1], '\d+').Value)
                    Name     = [string]$Matches[2].Trim()
                    TotalMiB = [int]$Matches[3]
                    FreeMiB  = [int]$Matches[4]
                })
            }
        }
    }
    catch {
    }

    if ($Inventory.Count -gt 0) {
        return [object[]]$Inventory.ToArray()
    }

    try {
        $SmiOutput = & nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader,nounits 2>$null
        foreach ($Line in $SmiOutput) {
            if ([string]$Line -match '^\s*(\d+)\s*,\s*(.+?)\s*,\s*(\d+)\s*,\s*(\d+)\s*$') {
                $GpuIndex = [int]$Matches[1]
                $Inventory.Add([pscustomobject]@{
                    Id       = "CUDA$GpuIndex"
                    Index    = $GpuIndex
                    Name     = [string]$Matches[2].Trim()
                    TotalMiB = [int]$Matches[3]
                    FreeMiB  = [int]$Matches[4]
                })
            }
        }
    }
    catch {
    }

    return [object[]]$Inventory.ToArray()
}

function Get-AcceleratorSignature {
    param(
        [object[]]$Inventory
    )

    if (-not $Inventory -or $Inventory.Count -eq 0) {
        return ""
    }

    return (
        $Inventory |
            Sort-Object Index |
            ForEach-Object {
                "{0}:{1}:{2}" -f $_.Id.ToString().Trim().ToLowerInvariant(), $_.Name.ToString().Trim().ToLowerInvariant(), [int]$_.TotalMiB
            }
    ) -join "|"
}

function Get-PrimaryAcceleratorInfo {
    $Inventory = Get-AcceleratorInventory
    if (-not $Inventory -or $Inventory.Count -eq 0) {
        return $null
    }

    return [pscustomobject]@{
        Name     = [string]$Inventory[0].Name
        TotalMiB = [int]$Inventory[0].TotalMiB
        FreeMiB  = [int]$Inventory[0].FreeMiB
    }
}

function Get-SystemMemoryInfo {
    try {
        $Os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [pscustomobject]@{
            TotalMiB = [int][Math]::Floor($Os.TotalVisibleMemorySize / 1024)
            FreeMiB  = [int][Math]::Floor($Os.FreePhysicalMemory / 1024)
        }
    }
    catch {
        return $null
    }
}

function Get-AutoLaunchTuning {
    param(
        [string]$ResolvedModelPath,
        [string]$RequestedGpuLayers,
        [string[]]$Arguments,
        [bool]$UseExtremeMode,
        [bool]$EnableAutoTune
    )

    $ArgumentText = Get-ArgumentSearchText -Arguments $Arguments
    $UserProvidedFitTarget = $ArgumentText -match '(?:^|\s)(?:--fit-target|-fitt)(?:=|\s+)'
    $UserProvidedCacheRam = $ArgumentText -match '(?:^|\s)(?:--cache-ram|-cram)(?:=|\s+)'
    $UserProvidedParallel = $ArgumentText -match '(?:^|\s)(?:--parallel|-np)(?:=|\s+)'
    $UserDisabledFit = $ArgumentText -match '(?:^|\s)(?:--fit|-fit)(?:=|\s+)off(?:\s|$)'
    $UseManagedGpuLayers = ([string]::IsNullOrWhiteSpace($RequestedGpuLayers) -or $RequestedGpuLayers.Trim().ToLowerInvariant() -eq 'auto')

    $AcceleratorInventory = Get-AcceleratorInventory
    $AcceleratorInfo = if ($AcceleratorInventory -and $AcceleratorInventory.Count -gt 0) {
        [pscustomobject]@{
            Name     = [string]$AcceleratorInventory[0].Name
            TotalMiB = [int]$AcceleratorInventory[0].TotalMiB
            FreeMiB  = [int]$AcceleratorInventory[0].FreeMiB
        }
    }
    else {
        $null
    }
    $MemoryInfo = Get-SystemMemoryInfo
    $TuningContext = Get-LaunchTuningContext -ResolvedModelPath $ResolvedModelPath -Arguments $Arguments -UseExtremeMode $UseExtremeMode -AcceleratorInventory $AcceleratorInventory
    $CanApplySavedProfile = $UseManagedGpuLayers -and -not $UserDisabledFit -and -not $UserProvidedFitTarget -and -not $UserProvidedCacheRam -and -not $UserProvidedParallel
    $SavedProfileResult = if ($CanApplySavedProfile) {
        Get-SavedAutoTuneProfile -TuningContext $TuningContext
    }
    else {
        [pscustomobject]@{
            Profile    = $null
            SkipReason = ""
        }
    }

    if ($SavedProfileResult.Profile) {
        $SavedProfile = $SavedProfileResult.Profile
        return [pscustomobject]@{
            UseManagedGpuLayers = $false
            EffectiveGpuLayers  = [string]$SavedProfile.gpu_layers
            ExtremeMode         = [bool]$UseExtremeMode
            AcceleratorInfo     = $AcceleratorInfo
            AcceleratorInventory = @($AcceleratorInventory)
            MemoryInfo          = $MemoryInfo
            FitTargetMiB        = if ($null -ne $SavedProfile.fit_target_mib) { [int]$SavedProfile.fit_target_mib } else { $null }
            CacheRamMiB         = if ($null -ne $SavedProfile.cache_ram_mib) { [int]$SavedProfile.cache_ram_mib } else { $null }
            ParallelSlots       = if ($null -ne $SavedProfile.parallel_slots) { [int]$SavedProfile.parallel_slots } else { $null }
            Source              = "saved-profile"
            SourceLabel         = "saved auto-tune profile"
            AutoTuneEnabled     = [bool]$EnableAutoTune
            AutoTuneEligible    = [bool]$EnableAutoTune
            TuningContext       = $TuningContext
            TuningProfile       = $SavedProfile
            ProfileSkipReason   = ""
        }
    }

    $FitTargetMiB = $null
    if ($UseManagedGpuLayers -and -not $UserDisabledFit -and -not $UserProvidedFitTarget) {
        if ($AcceleratorInfo) {
            if ($UseExtremeMode) {
                if ($AcceleratorInfo.TotalMiB -le 6144 -or $AcceleratorInfo.FreeMiB -le 4096) {
                    $FitTargetMiB = 64
                }
                elseif ($AcceleratorInfo.TotalMiB -le 12288 -or $AcceleratorInfo.FreeMiB -le 8192) {
                    $FitTargetMiB = 128
                }
                elseif ($AcceleratorInfo.TotalMiB -le 20480 -or $AcceleratorInfo.FreeMiB -le 16384) {
                    $FitTargetMiB = 256
                }
                else {
                    $FitTargetMiB = 512
                }
            }
            elseif ($AcceleratorInfo.TotalMiB -le 6144 -or $AcceleratorInfo.FreeMiB -le 4096) {
                $FitTargetMiB = 128
            }
            elseif ($AcceleratorInfo.TotalMiB -le 12288 -or $AcceleratorInfo.FreeMiB -le 8192) {
                $FitTargetMiB = 256
            }
            elseif ($AcceleratorInfo.TotalMiB -le 20480 -or $AcceleratorInfo.FreeMiB -le 16384) {
                $FitTargetMiB = 512
            }
            else {
                $FitTargetMiB = 1024
            }
        }
        else {
            $FitTargetMiB = if ($UseExtremeMode) { 128 } else { 256 }
        }
    }

    $CacheRamMiB = $null
    if (-not $UserProvidedCacheRam -and $MemoryInfo) {
        $RamReserveMiB = [int][Math]::Max(2048, [Math]::Round($MemoryInfo.TotalMiB * 0.12))
        $CacheBudgetMiB = $MemoryInfo.FreeMiB - $RamReserveMiB
        if ($CacheBudgetMiB -le 0) {
            $CacheRamMiB = 0
        }
        else {
            $DefaultCacheRamMiB = [int][Math]::Min(2048, ([Math]::Floor(($CacheBudgetMiB / 2) / 256) * 256))
            if ($UseExtremeMode) {
                if ($MemoryInfo.FreeMiB -lt 8192) {
                    $CacheRamMiB = 0
                }
                elseif ($AcceleratorInfo -and $AcceleratorInfo.TotalMiB -le 6144) {
                    $CacheRamMiB = [int][Math]::Min(512, $DefaultCacheRamMiB)
                }
                elseif ($AcceleratorInfo -and $AcceleratorInfo.TotalMiB -le 12288) {
                    $CacheRamMiB = [int][Math]::Min(1024, $DefaultCacheRamMiB)
                }
                else {
                    $CacheRamMiB = [int][Math]::Min(1024, $DefaultCacheRamMiB)
                }
            }
            else {
                $CacheRamMiB = $DefaultCacheRamMiB
            }

            if ($CacheRamMiB -lt 256) {
                $CacheRamMiB = if ($UseExtremeMode) { 0 } else { 256 }
            }
        }
    }

    $ParallelSlots = $null
    if (-not $UserProvidedParallel) {
        if ($UseExtremeMode) {
            $ParallelSlots = 1
        }
        elseif (($AcceleratorInfo -and ($AcceleratorInfo.TotalMiB -le 6144 -or $AcceleratorInfo.FreeMiB -lt 4096)) -or ($MemoryInfo -and $MemoryInfo.FreeMiB -lt 8192)) {
            $ParallelSlots = 1
        }
        elseif (($AcceleratorInfo -and ($AcceleratorInfo.TotalMiB -le 12288 -or $AcceleratorInfo.FreeMiB -lt 8192)) -or ($MemoryInfo -and $MemoryInfo.FreeMiB -lt 12288)) {
            $ParallelSlots = 2
        }
    }

    return [pscustomobject]@{
        UseManagedGpuLayers = $UseManagedGpuLayers
        EffectiveGpuLayers = [string]$RequestedGpuLayers
        ExtremeMode        = [bool]$UseExtremeMode
        AcceleratorInfo     = $AcceleratorInfo
        AcceleratorInventory = @($AcceleratorInventory)
        MemoryInfo          = $MemoryInfo
        FitTargetMiB        = $FitTargetMiB
        CacheRamMiB         = $CacheRamMiB
        ParallelSlots       = $ParallelSlots
        Source              = "adaptive"
        SourceLabel         = "adaptive auto-fit"
        AutoTuneEnabled     = [bool]$EnableAutoTune
        AutoTuneEligible    = [bool]($EnableAutoTune -and $UseManagedGpuLayers -and -not $UserDisabledFit -and -not $UserProvidedFitTarget -and -not $UserProvidedCacheRam -and -not $UserProvidedParallel)
        TuningContext       = $TuningContext
        TuningProfile       = $null
        ProfileSkipReason   = [string]$SavedProfileResult.SkipReason
    }
}

function Resolve-ScriptRelativePath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot $Path))
}

function Resolve-ModelPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    # Resolve relative model paths from the launcher root so shortcuts and autostart use the same base path.
    return Resolve-ScriptRelativePath -Path $Path
}

function New-ModelId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [hashtable]$UsedIds
    )

    $Slug = $Name.ToLowerInvariant()
    $Slug = [regex]::Replace($Slug, "[^a-z0-9]+", "_").Trim("_")

    if ([string]::IsNullOrWhiteSpace($Slug)) {
        $Slug = "model"
    }

    $Candidate = $Slug
    $Suffix = 2

    while ($UsedIds.ContainsKey($Candidate)) {
        $Candidate = "{0}_{1}" -f $Slug, $Suffix
        $Suffix++
    }

    $UsedIds[$Candidate] = $true
    return $Candidate
}

function Get-ExistingModelIndexPayload {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $Json = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($Json)) {
            return $null
        }

        return $Json | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-PreferredDefaultModelPath {
    param(
        [string]$IndexPath,
        [string]$PrimaryModelPath
    )

    $ResolvedPrimaryModelPath = Resolve-ModelPath -Path $PrimaryModelPath
    if (-not [string]::IsNullOrWhiteSpace($ResolvedPrimaryModelPath)) {
        return $ResolvedPrimaryModelPath
    }

    $IndexPayload = Get-ExistingModelIndexPayload -Path $IndexPath
    if (-not $IndexPayload) {
        return $null
    }

    $Models = @($IndexPayload.models)
    if ($Models.Count -eq 0) {
        return $null
    }

    if ($IndexPayload.PSObject.Properties["default_model_id"] -and -not [string]::IsNullOrWhiteSpace([string]$IndexPayload.default_model_id)) {
        foreach ($ModelEntry in $Models) {
            if ([string]$ModelEntry.id -eq [string]$IndexPayload.default_model_id) {
                $ResolvedDefaultPath = Resolve-ModelPath -Path $ModelEntry.path
                if (-not [string]::IsNullOrWhiteSpace($ResolvedDefaultPath)) {
                    return $ResolvedDefaultPath
                }
            }
        }
    }

    foreach ($ModelEntry in $Models) {
        $ResolvedModelPath = Resolve-ModelPath -Path $ModelEntry.path
        if (-not [string]::IsNullOrWhiteSpace($ResolvedModelPath)) {
            return $ResolvedModelPath
        }
    }

    return $null
}

function Get-ModelScanDirectoryCandidates {
    param(
        [string]$IndexPath,
        [string]$PrimaryModelPath
    )

    $Candidates = New-Object System.Collections.Generic.List[string]
    $SeenCandidates = @{}
    $AddCandidate = {
        param(
            [string]$CandidatePath
        )

        if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
            return
        }

        $ResolvedCandidate = Resolve-ScriptRelativePath -Path $CandidatePath
        if ([string]::IsNullOrWhiteSpace($ResolvedCandidate)) {
            return
        }

        $CandidateKey = $ResolvedCandidate.ToLowerInvariant()
        if ($SeenCandidates.ContainsKey($CandidateKey)) {
            return
        }

        $SeenCandidates[$CandidateKey] = $true
        [void]$Candidates.Add($ResolvedCandidate)
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredModelScanPath)) {
        & $AddCandidate $ConfiguredModelScanPath
    }

    $PreferredDefaultModelPath = Get-PreferredDefaultModelPath -IndexPath $IndexPath -PrimaryModelPath $PrimaryModelPath
    if (-not [string]::IsNullOrWhiteSpace($PreferredDefaultModelPath)) {
        & $AddCandidate ([System.IO.Path]::GetDirectoryName($PreferredDefaultModelPath))
    }

    $IndexPayload = Get-ExistingModelIndexPayload -Path $IndexPath
    if ($IndexPayload) {
        foreach ($ModelEntry in @($IndexPayload.models)) {
            $ResolvedModelPath = Resolve-ModelPath -Path $ModelEntry.path
            if (-not [string]::IsNullOrWhiteSpace($ResolvedModelPath)) {
                & $AddCandidate ([System.IO.Path]::GetDirectoryName($ResolvedModelPath))
            }
        }
    }

    & $AddCandidate $ScriptRoot
    return @($Candidates)
}

function Get-DefaultModelScanDirectory {
    param(
        [string]$IndexPath,
        [string]$PrimaryModelPath
    )

    $Candidates = @(Get-ModelScanDirectoryCandidates -IndexPath $IndexPath -PrimaryModelPath $PrimaryModelPath)
    foreach ($Candidate in $Candidates) {
        if (-not (Test-Path -LiteralPath $Candidate -PathType Container)) {
            continue
        }

        $ModelFiles = @(Get-ChildItem -LiteralPath $Candidate -Filter "*.gguf" -File -ErrorAction SilentlyContinue)
        if ($ModelFiles.Count -gt 0) {
            return $Candidate
        }
    }

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate -PathType Container) {
            return $Candidate
        }
    }

    return $null
}

function Refresh-ModelIndexFromDefaultScanPath {
    param(
        [string]$Path,
        [string]$PrimaryModelPath,
        [switch]$Quiet
    )

    $ScanDirectory = Get-DefaultModelScanDirectory -IndexPath $Path -PrimaryModelPath $PrimaryModelPath
    if ([string]::IsNullOrWhiteSpace($ScanDirectory)) {
        if (-not $Quiet) {
            Write-Warning "Could not determine a model scan directory. model-index.json was not changed."
        }

        return $false
    }

    $ModelFiles = @(Get-ChildItem -LiteralPath $ScanDirectory -Filter "*.gguf" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($ModelFiles.Count -eq 0) {
        if (-not $Quiet) {
            Write-Warning ("No GGUF files were found in {0}. model-index.json was not changed." -f $ScanDirectory)
        }

        return $false
    }

    $PreferredDefaultModelPath = Get-PreferredDefaultModelPath -IndexPath $Path -PrimaryModelPath $PrimaryModelPath
    $UsedIds = @{}
    $Models = @(
        foreach ($File in $ModelFiles) {
            $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            $ModelEntry = [pscustomobject]@{
                name = $BaseName
                path = $File.FullName
            }

            [ordered]@{
                id           = New-ModelId -Name $BaseName -UsedIds $UsedIds
                name         = $BaseName
                path         = $File.FullName
                capabilities = Resolve-ModelEntryCapabilities -ModelEntry $ModelEntry
                notes        = "Auto-generated by Start_LCPP.ps1 scan."
            }
        }
    )

    $DefaultModelId = $Models[0].id
    if (-not [string]::IsNullOrWhiteSpace($PreferredDefaultModelPath)) {
        foreach ($ModelEntry in $Models) {
            $ResolvedModelPath = Resolve-ModelPath -Path $ModelEntry.path
            if ([string]::Equals($ResolvedModelPath, $PreferredDefaultModelPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $DefaultModelId = $ModelEntry.id
                break
            }
        }
    }

    $IndexDirectory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($IndexDirectory) -and -not (Test-Path -LiteralPath $IndexDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $IndexDirectory -Force)
    }

    $IndexPayload = [ordered]@{
        default_model_id = $DefaultModelId
        models           = $Models
    }

    $IndexPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $true
}

function Read-GgufString {
    param(
        [System.IO.BinaryReader]$Reader
    )

    $Length = $Reader.ReadUInt64()
    if ($Length -eq 0) {
        return ""
    }

    $Bytes = $Reader.ReadBytes([int]$Length)
    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Read-GgufScalarValue {
    param(
        [System.IO.BinaryReader]$Reader,
        [uint32]$Type
    )

    switch ($Type) {
        0 { return $Reader.ReadByte() }
        1 { return $Reader.ReadSByte() }
        2 { return $Reader.ReadUInt16() }
        3 { return $Reader.ReadInt16() }
        4 { return $Reader.ReadUInt32() }
        5 { return $Reader.ReadInt32() }
        6 { return $Reader.ReadSingle() }
        7 { return $Reader.ReadBoolean() }
        8 { return Read-GgufString -Reader $Reader }
        10 { return $Reader.ReadUInt64() }
        11 { return $Reader.ReadInt64() }
        12 { return $Reader.ReadDouble() }
        default { throw "Unsupported GGUF metadata type: $Type" }
    }
}

function Skip-GgufValue {
    param(
        [System.IO.BinaryReader]$Reader,
        [uint32]$Type
    )

    switch ($Type) {
        0 { $Reader.BaseStream.Seek(1, [System.IO.SeekOrigin]::Current) | Out-Null }
        1 { $Reader.BaseStream.Seek(1, [System.IO.SeekOrigin]::Current) | Out-Null }
        2 { $Reader.BaseStream.Seek(2, [System.IO.SeekOrigin]::Current) | Out-Null }
        3 { $Reader.BaseStream.Seek(2, [System.IO.SeekOrigin]::Current) | Out-Null }
        4 { $Reader.BaseStream.Seek(4, [System.IO.SeekOrigin]::Current) | Out-Null }
        5 { $Reader.BaseStream.Seek(4, [System.IO.SeekOrigin]::Current) | Out-Null }
        6 { $Reader.BaseStream.Seek(4, [System.IO.SeekOrigin]::Current) | Out-Null }
        7 { $Reader.BaseStream.Seek(1, [System.IO.SeekOrigin]::Current) | Out-Null }
        8 { $null = Read-GgufString -Reader $Reader }
        9 {
            $ElementType = $Reader.ReadUInt32()
            $Length = $Reader.ReadUInt64()
            for ($Index = 0; $Index -lt [int]$Length; $Index++) {
                Skip-GgufValue -Reader $Reader -Type $ElementType
            }
        }
        10 { $Reader.BaseStream.Seek(8, [System.IO.SeekOrigin]::Current) | Out-Null }
        11 { $Reader.BaseStream.Seek(8, [System.IO.SeekOrigin]::Current) | Out-Null }
        12 { $Reader.BaseStream.Seek(8, [System.IO.SeekOrigin]::Current) | Out-Null }
        default { throw "Unsupported GGUF metadata type: $Type" }
    }
}

function Get-ModelRepeatingLayerCount {
    param(
        [string]$Path
    )

    $ResolvedPath = Resolve-ModelPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($ResolvedPath) -or -not (Test-Path -LiteralPath $ResolvedPath)) {
        return $null
    }

    if ($script:ModelRepeatingLayerCountCache.ContainsKey($ResolvedPath)) {
        return $script:ModelRepeatingLayerCountCache[$ResolvedPath]
    }

    $LayerCount = $null

    try {
        $Stream = [System.IO.File]::Open($ResolvedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $Reader = New-Object System.IO.BinaryReader($Stream)
            $Magic = [System.Text.Encoding]::ASCII.GetString($Reader.ReadBytes(4))
            if ($Magic -ne "GGUF") {
                throw "Unsupported model format."
            }

            $Version = $Reader.ReadUInt32()
            if ($Version -lt 2 -or $Version -gt 3) {
                throw "Unsupported GGUF version: $Version"
            }

            $null = $Reader.ReadUInt64()
            $MetadataCount = $Reader.ReadUInt64()

            for ($Index = 0; $Index -lt [int]$MetadataCount; $Index++) {
                $Key = Read-GgufString -Reader $Reader
                $Type = $Reader.ReadUInt32()

                if ($Key -match '(^|\.)(block_count|layer_count)$') {
                    $Value = Read-GgufScalarValue -Reader $Reader -Type $Type
                    if ($Value -is [ValueType] -and [int64]$Value -gt 0) {
                        $LayerCount = [int]$Value
                        break
                    }
                }
                else {
                    if ($Key -like 'tokenizer.*') {
                        break
                    }

                    Skip-GgufValue -Reader $Reader -Type $Type
                }
            }
        }
        finally {
            if ($Reader) {
                $Reader.Close()
            }
            $Stream.Close()
        }
    }
    catch {
        $LayerCount = $null
    }

    $script:ModelRepeatingLayerCountCache[$ResolvedPath] = $LayerCount
    return $LayerCount
}

function Convert-GpuLayersToRepeatingLayers {
    param(
        [string]$GpuLayers,
        [Nullable[int]]$RepeatingLayerCount
    )

    if ([string]::IsNullOrWhiteSpace($GpuLayers) -or $GpuLayers.Trim().ToLowerInvariant() -eq "auto") {
        return "auto"
    }

    if ($GpuLayers.Trim().ToLowerInvariant() -eq "all") {
        return "all"
    }

    if ($GpuLayers -notmatch '^\d+$') {
        return ""
    }

    $RequestedTotalLayers = [int]$GpuLayers
    $RequestedRepeatingLayers = [Math]::Max(0, $RequestedTotalLayers - 1)
    if ($null -ne $RepeatingLayerCount) {
        $RequestedRepeatingLayers = [Math]::Min($RequestedRepeatingLayers, $RepeatingLayerCount.Value)
    }

    return [string]$RequestedRepeatingLayers
}

function Convert-RepeatingLayersToGpuLayers {
    param(
        [string]$RepeatingLayers,
        [Nullable[int]]$RepeatingLayerCount
    )

    if ([string]::IsNullOrWhiteSpace($RepeatingLayers) -or $RepeatingLayers.Trim().ToLowerInvariant() -eq "auto") {
        return "auto"
    }

    if ($RepeatingLayers.Trim().ToLowerInvariant() -eq "all") {
        return "all"
    }

    if ($RepeatingLayers -notmatch '^\d+$') {
        throw "Repeating Layers must be auto, all, or a non-negative integer."
    }

    $RequestedRepeatingLayers = [int]$RepeatingLayers
    if ($null -ne $RepeatingLayerCount -and $RequestedRepeatingLayers -gt $RepeatingLayerCount.Value) {
        throw "Repeating Layers cannot be greater than $($RepeatingLayerCount.Value) for this model."
    }

    return [string]($RequestedRepeatingLayers + 1)
}

function Sync-LaunchConfigGpuFields {
    param(
        [System.Collections.IDictionary]$Config
    )

    $RepeatingLayerCount = Get-ModelRepeatingLayerCount -Path $Config.ModelPath
    $Config.ModelRepeatingLayerCount = $RepeatingLayerCount
    $Config.RepeatingLayers = Convert-GpuLayersToRepeatingLayers -GpuLayers ([string]$Config.GpuLayers) -RepeatingLayerCount $RepeatingLayerCount
}

function Get-GpuOffloadInfo {
    $TrackedProcess = Get-TrackedServerProcess
    $TrackedModelPath = Get-TrackedServerModelPath -Process $TrackedProcess
    $TrackedLogPaths = Get-TrackedLogPaths
    $TrackedStdErrLog = $TrackedLogPaths.StdErrLog
    $RequestedGpuLayers = $null

    if ($TrackedProcess) {
        try {
            $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($TrackedProcess.Id)" -ErrorAction SilentlyContinue
            if ($ProcessInfo -and $ProcessInfo.CommandLine) {
                $Match = [regex]::Match($ProcessInfo.CommandLine, '(?:^|\s)(?:--gpu-layers|-ngl)\s+(?:"([^"]+)"|(\S+))')
                if ($Match.Success) {
                    $RequestedGpuLayers = if ($Match.Groups[1].Success) { $Match.Groups[1].Value } else { $Match.Groups[2].Value }
                }
            }
        }
        catch {
        }
    }

    if (-not (Test-Path -LiteralPath $TrackedStdErrLog)) {
        return [pscustomobject]@{
            Running             = [bool]$TrackedProcess
            ModelPath           = $TrackedModelPath
            RequestedGpuLayers  = $RequestedGpuLayers
            RepeatingLayers     = $null
            OffloadedLayers     = $null
            TotalLayers         = $null
            GpuModelBufferMiB   = $null
            GpuModelBufferTotalMiB = $null
            CpuMappedModelBufferMiB = $null
            LogPath             = $TrackedStdErrLog
        }
    }

    $LogText = Get-Content -LiteralPath $TrackedStdErrLog -Raw -ErrorAction SilentlyContinue
    $RepeatingMatches = [regex]::Matches($LogText, 'load_tensors:\s+offloading\s+(\d+)\s+repeating layers to GPU')
    $OffloadedMatches = [regex]::Matches($LogText, 'load_tensors:\s+offloaded\s+(\d+)/(\d+)\s+layers to GPU')
    $BufferMatches = [regex]::Matches($LogText, 'load_tensors:\s+CUDA(?<id>\d+)\s+model buffer size =\s+(?<size>[0-9.]+)\s+MiB')
    $CpuMappedBufferMatches = [regex]::Matches($LogText, 'load_tensors:\s+CPU_Mapped model buffer size =\s+([0-9.]+)\s+MiB')

    $RepeatingLayers = if ($RepeatingMatches.Count -gt 0) { [int]$RepeatingMatches[$RepeatingMatches.Count - 1].Groups[1].Value } else { $null }
    $OffloadedLayers = if ($OffloadedMatches.Count -gt 0) { [int]$OffloadedMatches[$OffloadedMatches.Count - 1].Groups[1].Value } else { $null }
    $TotalLayers = if ($OffloadedMatches.Count -gt 0) { [int]$OffloadedMatches[$OffloadedMatches.Count - 1].Groups[2].Value } else { $null }
    $GpuModelBufferMiB = if ($BufferMatches.Count -gt 0) { [double]$BufferMatches[$BufferMatches.Count - 1].Groups["size"].Value } else { $null }
    $GpuModelBufferTotalMiB = $null
    if ($BufferMatches.Count -gt 0) {
        $GpuModelBufferTotalMiB = 0.0
        foreach ($BufferMatch in $BufferMatches) {
            $GpuModelBufferTotalMiB += [double]$BufferMatch.Groups["size"].Value
        }
    }
    $CpuMappedModelBufferMiB = if ($CpuMappedBufferMatches.Count -gt 0) { [double]$CpuMappedBufferMatches[$CpuMappedBufferMatches.Count - 1].Groups[1].Value } else { $null }

    return [pscustomobject]@{
        Running                = [bool]$TrackedProcess
        ModelPath              = $TrackedModelPath
        RequestedGpuLayers     = $RequestedGpuLayers
        RepeatingLayers        = $RepeatingLayers
        OffloadedLayers        = $OffloadedLayers
        TotalLayers            = $TotalLayers
        GpuModelBufferMiB      = $GpuModelBufferMiB
        GpuModelBufferTotalMiB = $GpuModelBufferTotalMiB
        CpuMappedModelBufferMiB = $CpuMappedModelBufferMiB
        LogPath                = $TrackedStdErrLog
    }
}

function Get-ObservedGpuUsage {
    param(
        [string]$LogPath,
        [object[]]$AcceleratorInventory
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return [pscustomobject]@{
            DeviceUsages             = @()
            AggregateUsedMiB         = $null
            AggregateCapacityMiB     = $null
            AggregateUsagePercent    = $null
            CpuMappedModelBufferMiB  = $null
            OffloadedLayers          = $null
            TotalLayers              = $null
        }
    }

    $LogText = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
    $UsageByDevice = @{}
    $InventoryById = @{}

    foreach ($Device in @($AcceleratorInventory)) {
        $InventoryById[$Device.Id.ToString().ToUpperInvariant()] = $Device
    }

    $Patterns = @(
        [pscustomobject]@{ Key = "ModelBufferMiB"; Pattern = 'load_tensors:\s+CUDA(?<id>\d+)\s+model buffer size =\s+(?<size>[0-9.]+)\s+MiB' },
        [pscustomobject]@{ Key = "KvBufferMiB"; Pattern = 'llama_kv_cache:\s+CUDA(?<id>\d+)\s+KV buffer size =\s+(?<size>[0-9.]+)\s+MiB' },
        [pscustomobject]@{ Key = "RecurrentBufferMiB"; Pattern = 'llama_memory_recurrent:\s+CUDA(?<id>\d+)\s+RS buffer size =\s+(?<size>[0-9.]+)\s+MiB' },
        [pscustomobject]@{ Key = "ComputeBufferMiB"; Pattern = 'sched_reserve:\s+CUDA(?<id>\d+)\s+compute buffer size =\s+(?<size>[0-9.]+)\s+MiB' },
        [pscustomobject]@{ Key = "OutputBufferMiB"; Pattern = 'llama_context:\s+CUDA(?<id>\d+)\s+output buffer size =\s+(?<size>[0-9.]+)\s+MiB' }
    )

    foreach ($Pattern in $Patterns) {
        foreach ($Match in [regex]::Matches($LogText, $Pattern.Pattern)) {
            $DeviceId = "CUDA{0}" -f $Match.Groups["id"].Value
            if (-not $UsageByDevice.ContainsKey($DeviceId)) {
                $InventoryDevice = if ($InventoryById.ContainsKey($DeviceId.ToUpperInvariant())) { $InventoryById[$DeviceId.ToUpperInvariant()] } else { $null }
                $UsageByDevice[$DeviceId] = [ordered]@{
                    DeviceId           = $DeviceId
                    Name               = if ($InventoryDevice) { [string]$InventoryDevice.Name } else { $DeviceId }
                    TotalMiB           = if ($InventoryDevice) { [double]$InventoryDevice.TotalMiB } else { $null }
                    LaunchFreeMiB      = if ($InventoryDevice) { [double]$InventoryDevice.FreeMiB } else { $null }
                    ModelBufferMiB     = 0.0
                    KvBufferMiB        = 0.0
                    RecurrentBufferMiB = 0.0
                    ComputeBufferMiB   = 0.0
                    OutputBufferMiB    = 0.0
                }
            }

            $UsageByDevice[$DeviceId][$Pattern.Key] = [double]$Match.Groups["size"].Value
        }
    }

    $OffloadedMatches = [regex]::Matches($LogText, 'load_tensors:\s+offloaded\s+(\d+)/(\d+)\s+layers to GPU')
    $CpuMappedMatches = [regex]::Matches($LogText, 'load_tensors:\s+CPU_Mapped model buffer size =\s+([0-9.]+)\s+MiB')

    $DeviceUsages = @(
        $UsageByDevice.Keys |
            Sort-Object |
            ForEach-Object {
                $Entry = $UsageByDevice[$_]
                $UsedMiB = [double]$Entry.ModelBufferMiB + [double]$Entry.KvBufferMiB + [double]$Entry.RecurrentBufferMiB + [double]$Entry.ComputeBufferMiB + [double]$Entry.OutputBufferMiB
                [pscustomobject]@{
                    DeviceId           = [string]$Entry.DeviceId
                    Name               = [string]$Entry.Name
                    TotalMiB           = if ($null -ne $Entry.TotalMiB) { [double]$Entry.TotalMiB } else { $null }
                    LaunchFreeMiB      = if ($null -ne $Entry.LaunchFreeMiB) { [double]$Entry.LaunchFreeMiB } else { $null }
                    ModelBufferMiB     = [double]$Entry.ModelBufferMiB
                    KvBufferMiB        = [double]$Entry.KvBufferMiB
                    RecurrentBufferMiB = [double]$Entry.RecurrentBufferMiB
                    ComputeBufferMiB   = [double]$Entry.ComputeBufferMiB
                    OutputBufferMiB    = [double]$Entry.OutputBufferMiB
                    UsedMiB            = [double]$UsedMiB
                    UsagePercent       = if ($null -ne $Entry.TotalMiB -and [double]$Entry.TotalMiB -gt 0) { [double](($UsedMiB / [double]$Entry.TotalMiB) * 100.0) } else { $null }
                }
            }
    )

    $AggregateUsedMiB = if ($DeviceUsages.Count -gt 0) { [double](($DeviceUsages | Measure-Object -Property UsedMiB -Sum).Sum) } else { $null }
    $AggregateCapacityMiB = if ($DeviceUsages.Count -gt 0) { [double](($DeviceUsages | Where-Object { $null -ne $_.TotalMiB } | Measure-Object -Property TotalMiB -Sum).Sum) } else { $null }
    $AggregateUsagePercent = if ($null -ne $AggregateUsedMiB -and $null -ne $AggregateCapacityMiB -and $AggregateCapacityMiB -gt 0) {
        [double](($AggregateUsedMiB / $AggregateCapacityMiB) * 100.0)
    }
    else {
        $null
    }

    return [pscustomobject]@{
        DeviceUsages             = $DeviceUsages
        AggregateUsedMiB         = $AggregateUsedMiB
        AggregateCapacityMiB     = $AggregateCapacityMiB
        AggregateUsagePercent    = $AggregateUsagePercent
        CpuMappedModelBufferMiB  = if ($CpuMappedMatches.Count -gt 0) { [double]$CpuMappedMatches[$CpuMappedMatches.Count - 1].Groups[1].Value } else { $null }
        OffloadedLayers          = if ($OffloadedMatches.Count -gt 0) { [int]$OffloadedMatches[$OffloadedMatches.Count - 1].Groups[1].Value } else { $null }
        TotalLayers              = if ($OffloadedMatches.Count -gt 0) { [int]$OffloadedMatches[$OffloadedMatches.Count - 1].Groups[2].Value } else { $null }
    }
}

function Test-AutoTuneQualification {
    param(
        $AutoTuning,
        $ObservedUsage
    )

    if (-not $AutoTuning.AutoTuneEnabled) {
        return [pscustomobject]@{ ShouldSave = $false; Reason = "" }
    }

    if (-not $AutoTuning.AutoTuneEligible) {
        return [pscustomobject]@{ ShouldSave = $false; Reason = "auto-tune only learns when GPU Layers stays on auto and managed tuning remains in control" }
    }

    if (-not $ObservedUsage -or -not $ObservedUsage.DeviceUsages -or $ObservedUsage.DeviceUsages.Count -eq 0) {
        return [pscustomobject]@{ ShouldSave = $false; Reason = "GPU usage data is not available in the startup log yet" }
    }

    if ($null -eq $ObservedUsage.OffloadedLayers -or $null -eq $ObservedUsage.TotalLayers) {
        return [pscustomobject]@{ ShouldSave = $false; Reason = "offloaded layer counts are missing from the startup log" }
    }

    if ($ObservedUsage.OffloadedLayers -ne $ObservedUsage.TotalLayers) {
        return [pscustomobject]@{ ShouldSave = $false; Reason = "the model did not fully fit in GPU memory on this launch" }
    }

    if ($null -ne $ObservedUsage.CpuMappedModelBufferMiB -and $ObservedUsage.CpuMappedModelBufferMiB -gt 64) {
        return [pscustomobject]@{ ShouldSave = $false; Reason = "part of the model still stayed CPU-mapped" }
    }

    if ($null -eq $ObservedUsage.AggregateUsagePercent) {
        return [pscustomobject]@{ ShouldSave = $false; Reason = "aggregate GPU usage could not be calculated" }
    }

    if ($ObservedUsage.AggregateUsagePercent -lt $AutoTuneMinUsagePercent) {
        return [pscustomobject]@{
            ShouldSave = $false
            Reason     = "GPU usage reached only {0:N1}% and did not get close enough to the {1:N0}% target" -f $ObservedUsage.AggregateUsagePercent, $AutoTuneTargetUsagePercent
        }
    }

    if ($ObservedUsage.AggregateUsagePercent -gt $AutoTuneMaxUsagePercent) {
        return [pscustomobject]@{
            ShouldSave = $false
            Reason     = "GPU usage hit {0:N1}%, which is tighter than the safe auto-tune window" -f $ObservedUsage.AggregateUsagePercent
        }
    }

    return [pscustomobject]@{
        ShouldSave = $true
        Reason     = "GPU usage reached {0:N1}% with a full GPU fit" -f $ObservedUsage.AggregateUsagePercent
    }
}

function Save-AutoTuneProfile {
    param(
        $AutoTuning,
        $ObservedUsage
    )

    $Qualification = Test-AutoTuneQualification -AutoTuning $AutoTuning -ObservedUsage $ObservedUsage
    if (-not $Qualification.ShouldSave) {
        return [pscustomobject]@{
            Saved   = $false
            Message = [string]$Qualification.Reason
            Profile = $null
        }
    }

    $Data = Get-TuningProfileData -Path $TuningProfileFile
    $ExistingProfile = @(
        $Data.profiles |
            Where-Object { $_.fingerprint -eq $AutoTuning.TuningContext.Fingerprint } |
            Select-Object -First 1
    )
    $CreatedAt = if ($ExistingProfile -and $ExistingProfile.Count -gt 0) { [string]$ExistingProfile[0].created_at } else { (Get-Date).ToString("o") }

    $Profile = [ordered]@{
        fingerprint                       = [string]$AutoTuning.TuningContext.Fingerprint
        model_path                        = [string]$AutoTuning.TuningContext.ModelPath
        accelerator_signature             = [string]$AutoTuning.TuningContext.AcceleratorSignature
        extreme_mode                      = [bool]$AutoTuning.ExtremeMode
        llama_args_key                    = [string]$AutoTuning.TuningContext.ArgumentFingerprint
        llama_args_preview                = [string]$AutoTuning.TuningContext.ArgumentPreview
        gpu_layers                        = "all"
        fit_target_mib                    = if ($null -ne $AutoTuning.FitTargetMiB) { [int]$AutoTuning.FitTargetMiB } else { $null }
        cache_ram_mib                     = if ($null -ne $AutoTuning.CacheRamMiB) { [int]$AutoTuning.CacheRamMiB } else { $null }
        parallel_slots                    = if ($null -ne $AutoTuning.ParallelSlots) { [int]$AutoTuning.ParallelSlots } else { $null }
        observed_gpu_usage_percent        = [Math]::Round([double]$ObservedUsage.AggregateUsagePercent, 2)
        observed_gpu_used_mib             = [int][Math]::Ceiling([double]$ObservedUsage.AggregateUsedMiB)
        observed_gpu_capacity_mib         = [int][Math]::Ceiling([double]$ObservedUsage.AggregateCapacityMiB)
        observed_cpu_mapped_model_mib     = if ($null -ne $ObservedUsage.CpuMappedModelBufferMiB) { [Math]::Round([double]$ObservedUsage.CpuMappedModelBufferMiB, 2) } else { $null }
        offloaded_layers                  = [int]$ObservedUsage.OffloadedLayers
        total_layers                      = [int]$ObservedUsage.TotalLayers
        observed_devices                  = @(
            $ObservedUsage.DeviceUsages |
                ForEach-Object {
                    [ordered]@{
                        device_id       = [string]$_.DeviceId
                        name            = [string]$_.Name
                        total_mib       = if ($null -ne $_.TotalMiB) { [int][Math]::Ceiling([double]$_.TotalMiB) } else { $null }
                        launch_free_mib = if ($null -ne $_.LaunchFreeMiB) { [int][Math]::Floor([double]$_.LaunchFreeMiB) } else { $null }
                        used_mib        = [int][Math]::Ceiling([double]$_.UsedMiB)
                        usage_percent   = if ($null -ne $_.UsagePercent) { [Math]::Round([double]$_.UsagePercent, 2) } else { $null }
                    }
                }
        )
        created_at                        = $CreatedAt
        updated_at                        = (Get-Date).ToString("o")
    }

    $Profiles = @(
        $Data.profiles |
            Where-Object { $_.fingerprint -ne $AutoTuning.TuningContext.Fingerprint }
    )
    $Profiles += [pscustomobject]$Profile
    Save-TuningProfileData -Path $TuningProfileFile -Profiles $Profiles
    $script:LastAutoTuneProfile = [pscustomobject]$Profile

    return [pscustomobject]@{
        Saved   = $true
        Message = "Saved auto-tune profile at {0:N1}% GPU usage." -f [double]$ObservedUsage.AggregateUsagePercent
        Profile = [pscustomobject]$Profile
    }
}

function Show-GpuOffload {
    $OffloadInfo = Get-GpuOffloadInfo

    Write-Host ("Status : {0}" -f $(if ($OffloadInfo.Running) { "running" } else { "stopped" })) -ForegroundColor $(if ($OffloadInfo.Running) { "Green" } else { "Yellow" })
    if ($OffloadInfo.ModelPath) {
        Write-Host "Model  : $($OffloadInfo.ModelPath)"
    }
    if ($OffloadInfo.RequestedGpuLayers) {
        Write-Host "Asked  : $($OffloadInfo.RequestedGpuLayers)"
    }

    if ($null -ne $OffloadInfo.RepeatingLayers -or $null -ne $OffloadInfo.OffloadedLayers) {
        if ($null -ne $OffloadInfo.RepeatingLayers) {
            Write-Host "Repeat : $($OffloadInfo.RepeatingLayers)"
        }
        if ($null -ne $OffloadInfo.OffloadedLayers -and $null -ne $OffloadInfo.TotalLayers) {
            Write-Host "Total  : $($OffloadInfo.OffloadedLayers)/$($OffloadInfo.TotalLayers) layers to GPU"
        }
        if ($null -ne $OffloadInfo.GpuModelBufferMiB) {
            Write-Host ("Buffer : {0:N2} MiB" -f $OffloadInfo.GpuModelBufferMiB)
        }
    }
    else {
        Write-Host "GPU offload information is not available yet." -ForegroundColor Yellow
    }

    Write-Host "Log    : $($OffloadInfo.LogPath)"
}

function ConvertTo-BoolFlag {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [bool]) {
        return $Value
    }

    $Normalized = $Value.ToString().Trim().ToLowerInvariant()
    return $Normalized -in @("1", "true", "yes", "y", "on")
}

$script:GgufArchitectureCache = @{}
$script:ResolvedModelCapabilityCache = @{}

function New-EmptyModelCapabilities {
    return [ordered]@{
        chat      = $false
        reasoning = $false
        vision    = $false
        tools     = $false
        embedding = $false
        rerank    = $false
    }
}

function ConvertTo-ModelCapabilities {
    param(
        $Source
    )

    $Capabilities = New-EmptyModelCapabilities

    if ($null -eq $Source) {
        return $Capabilities
    }

    foreach ($CapabilityName in @("chat", "reasoning", "vision", "tools", "embedding", "rerank")) {
        $Value = $null

        if ($Source -is [System.Collections.IDictionary] -and $Source.Contains($CapabilityName)) {
            $Value = $Source[$CapabilityName]
        }
        elseif ($Source.PSObject.Properties[$CapabilityName]) {
            $Value = $Source.$CapabilityName
        }

        $Capabilities[$CapabilityName] = ConvertTo-BoolFlag $Value
    }

    return $Capabilities
}

function Read-GgufString {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.BinaryReader]$Reader
    )

    $Length = $Reader.ReadUInt64()
    if ($Length -eq 0) {
        return ""
    }

    if ($Length -gt [uint64][int]::MaxValue) {
        throw "GGUF string metadata is unexpectedly large."
    }

    $ByteCount = [int]$Length
    $Bytes = $Reader.ReadBytes($ByteCount)
    if ($Bytes.Length -ne $ByteCount) {
        throw "Unexpected end of GGUF metadata."
    }

    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function Skip-GgufValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.BinaryReader]$Reader,

        [Parameter(Mandatory = $true)]
        [uint32]$Type
    )

    switch ($Type) {
        0 { [void]$Reader.ReadByte() }
        1 { [void]$Reader.ReadSByte() }
        2 { [void]$Reader.ReadUInt16() }
        3 { [void]$Reader.ReadInt16() }
        4 { [void]$Reader.ReadUInt32() }
        5 { [void]$Reader.ReadInt32() }
        6 { [void]$Reader.ReadSingle() }
        7 { [void]$Reader.ReadBoolean() }
        8 { [void](Read-GgufString -Reader $Reader) }
        9 {
            $ArrayType = $Reader.ReadUInt32()
            $ArrayLength = $Reader.ReadUInt64()
            $FixedWidth = switch ($ArrayType) {
                0 { 1 }
                1 { 1 }
                2 { 2 }
                3 { 2 }
                4 { 4 }
                5 { 4 }
                6 { 4 }
                7 { 1 }
                10 { 8 }
                11 { 8 }
                12 { 8 }
                default { $null }
            }

            if ($null -ne $FixedWidth) {
                $BytesToSkip = [int64]($ArrayLength * [uint64]$FixedWidth)
                [void]$Reader.BaseStream.Seek($BytesToSkip, [System.IO.SeekOrigin]::Current)
                return
            }

            for ($Index = 0; $Index -lt $ArrayLength; $Index++) {
                Skip-GgufValue -Reader $Reader -Type $ArrayType
            }
        }
        10 { [void]$Reader.ReadUInt64() }
        11 { [void]$Reader.ReadInt64() }
        12 { [void]$Reader.ReadDouble() }
        default { throw "Unsupported GGUF metadata type: $Type" }
    }
}

function Get-GgufArchitectureHint {
    param(
        [string]$ModelPath
    )

    if ([string]::IsNullOrWhiteSpace($ModelPath)) {
        return $null
    }

    $ResolvedPath = Resolve-ModelPath -Path $ModelPath
    if ([string]::IsNullOrWhiteSpace($ResolvedPath) -or -not (Test-Path -LiteralPath $ResolvedPath)) {
        return $null
    }

    if ($script:GgufArchitectureCache.ContainsKey($ResolvedPath)) {
        return $script:GgufArchitectureCache[$ResolvedPath]
    }

    $Architecture = $null

    try {
        $Stream = [System.IO.File]::Open($ResolvedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $Reader = New-Object System.IO.BinaryReader($Stream)
            try {
                $MagicBytes = $Reader.ReadBytes(4)
                if ($MagicBytes.Length -ne 4 -or [System.Text.Encoding]::ASCII.GetString($MagicBytes) -ne "GGUF") {
                    throw "The file is not a GGUF model."
                }

                [void]$Reader.ReadUInt32()
                [void]$Reader.ReadUInt64()
                $MetadataCount = $Reader.ReadUInt64()

                for ($Index = 0; $Index -lt $MetadataCount; $Index++) {
                    $Key = Read-GgufString -Reader $Reader
                    $Type = $Reader.ReadUInt32()

                    if ($Key -eq "general.architecture") {
                        if ($Type -eq 8) {
                            $Architecture = Read-GgufString -Reader $Reader
                        }
                        else {
                            Skip-GgufValue -Reader $Reader -Type $Type
                        }

                        break
                    }

                    Skip-GgufValue -Reader $Reader -Type $Type
                }
            }
            finally {
                if ($Reader) {
                    $Reader.Dispose()
                }
            }
        }
        finally {
            if ($Stream) {
                $Stream.Dispose()
            }
        }
    }
    catch {
    }

    $script:GgufArchitectureCache[$ResolvedPath] = $Architecture
    return $Architecture
}

function Get-InferredModelCapabilities {
    param(
        [string]$ModelName,
        [string]$ModelPath,
        [string]$Architecture
    )

    $SearchText = (@($ModelName, $ModelPath, $Architecture) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "
    $Normalized = $SearchText.ToLowerInvariant()
    $NormalizedArchitecture = if ($Architecture) { $Architecture.ToLowerInvariant() } else { "" }

    $VisionPattern = '(?<![a-z0-9])(vision|vlm|qwen[\-_ ]?2(?:\.5)?[\-_ ]?vl|qwen[\-_ ]?vl|qvq|llava(?:[\-_ ]?(?:next|onevision))?|bakllava|internvl|pixtral|paligemma|minicpm(?:[\-_ ]?v)?|gemma[\-_ ]?3|mllama|llama[\-_ ]?3\.2[\-_ ]?vision|phi[\-_ ]?(?:3\.5|4)[\-_ ]?(?:vision|multimodal)|glm[\-_ ]?4(?:[\._-]1)?v|cogvlm|smolvlm|molmo|moondream|janus|omni|multimodal|multi[\-_ ]modal|image)(?![a-z0-9])'
    $ReasoningPattern = '(?<![a-z0-9])(reason|reasoning|think|thinking|chain[\-_ ]?of[\-_ ]?thought|cot|qwq|r1)(?![a-z0-9])'
    $ToolsPattern = '(?<![a-z0-9])(tool|tools|function|functions|function[\-_ ]?call(?:ing)?|tool[\-_ ]?use|agent)(?![a-z0-9])'
    $RerankPattern = '(?<![a-z0-9])(rerank|reranker|re[\-_ ]?rank|cross[\-_ ]?encoder|bge[\-_ ]?reranker|jina[\-_ ]?reranker)(?![a-z0-9])'
    $EmbeddingPattern = '(?<![a-z0-9])(embed|embedding|embeddings|text[\-_ ]?embedding|nomic[\-_ ]?embed|jina[\-_ ]?embeddings?|bge|e5|gte)(?![a-z0-9])'
    $ArchitectureVisionPattern = '^(qwen2vl|mllama|gemma3|minicpmv|llava|llava_next|pixtral|internvl|paligemma|glm4v|cogvlm|smolvlm|molmo|moondream|janus)$'

    $IsRerank = $Normalized -match $RerankPattern
    $IsEmbedding = (-not $IsRerank) -and ($Normalized -match $EmbeddingPattern)
    $IsVision = ($Normalized -match $VisionPattern) -or ($NormalizedArchitecture -match $ArchitectureVisionPattern)
    $IsReasoning = $Normalized -match $ReasoningPattern
    $IsTools = $Normalized -match $ToolsPattern
    $IsChat = -not ($IsEmbedding -or $IsRerank)

    return [ordered]@{
        chat      = [bool]$IsChat
        reasoning = [bool]$IsReasoning
        vision    = [bool]$IsVision
        tools     = [bool]$IsTools
        embedding = [bool]$IsEmbedding
        rerank    = [bool]$IsRerank
    }
}

function Resolve-ModelEntryCapabilities {
    param(
        $ModelEntry
    )

    if (-not $ModelEntry) {
        return [pscustomobject](New-EmptyModelCapabilities)
    }

    $ModelName = if ($ModelEntry.PSObject.Properties["name"]) { [string]$ModelEntry.name } else { "" }
    $ModelPath = if ($ModelEntry.PSObject.Properties["path"]) { [string]$ModelEntry.path } else { "" }
    $ExplicitCapabilities = ConvertTo-ModelCapabilities -Source $(if ($ModelEntry.PSObject.Properties["capabilities"]) { $ModelEntry.capabilities } else { $null })
    $CapabilitySignature = ($ExplicitCapabilities.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ";"
    $CacheKey = "{0}|{1}|{2}" -f $ModelName, $ModelPath, $CapabilitySignature

    if ($script:ResolvedModelCapabilityCache.ContainsKey($CacheKey)) {
        return $script:ResolvedModelCapabilityCache[$CacheKey]
    }

    $Architecture = Get-GgufArchitectureHint -ModelPath $ModelPath
    $InferredCapabilities = Get-InferredModelCapabilities -ModelName $ModelName -ModelPath $ModelPath -Architecture $Architecture
    $ResolvedCapabilities = New-EmptyModelCapabilities

    $ResolvedCapabilities.reasoning = $ExplicitCapabilities.reasoning -or $InferredCapabilities.reasoning
    $ResolvedCapabilities.vision = $ExplicitCapabilities.vision -or $InferredCapabilities.vision
    $ResolvedCapabilities.tools = $ExplicitCapabilities.tools -or $InferredCapabilities.tools
    $ResolvedCapabilities.embedding = $ExplicitCapabilities.embedding -or $InferredCapabilities.embedding
    $ResolvedCapabilities.rerank = $ExplicitCapabilities.rerank -or $InferredCapabilities.rerank

    $ChatCandidate = $ExplicitCapabilities.chat -or $InferredCapabilities.chat
    if (-not $ChatCandidate -and -not $ResolvedCapabilities.embedding -and -not $ResolvedCapabilities.rerank) {
        $ChatCandidate = $true
    }

    $ResolvedCapabilities.chat = $ChatCandidate -and -not ($ResolvedCapabilities.embedding -or $ResolvedCapabilities.rerank)

    $ResolvedObject = [pscustomobject]$ResolvedCapabilities
    $script:ResolvedModelCapabilityCache[$CacheKey] = $ResolvedObject
    return $ResolvedObject
}

function Ensure-ModelSwitchTimingFile {
    param(
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        return
    }

    $Bootstrap = [ordered]@{
        version = 1
        records = @()
    }

    $Bootstrap | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ModelSwitchTimingData {
    param(
        [string]$Path
    )

    Ensure-ModelSwitchTimingFile -Path $Path
    $Json = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return [pscustomobject]@{
            version = 1
            records = @()
        }
    }

    $Data = $Json | ConvertFrom-Json
    if (-not $Data.records) {
        $Data | Add-Member -NotePropertyName records -NotePropertyValue @() -Force
    }

    $NormalizedRecords = @(
        foreach ($Record in @($Data.records)) {
            if (-not $Record) {
                continue
            }

            $ResolvedModelPath = Resolve-ModelPath -Path ([string]$Record.model_path)
            if ([string]::IsNullOrWhiteSpace($ResolvedModelPath)) {
                continue
            }

            $NormalizedRecord = [ordered]@{
                model_path               = $ResolvedModelPath
                last_switch_duration_ms  = if ($Record.PSObject.Properties["last_switch_duration_ms"]) { $Record.last_switch_duration_ms } else { $null }
                last_switched_at         = if ($Record.PSObject.Properties["last_switched_at"]) { [string]$Record.last_switched_at } else { $null }
                last_previous_model_path = if ($Record.PSObject.Properties["last_previous_model_path"]) { Resolve-ModelPath -Path ([string]$Record.last_previous_model_path) } else { $null }
                pending_started_at       = if ($Record.PSObject.Properties["pending_started_at"]) { [string]$Record.pending_started_at } else { $null }
                pending_previous_model_path = if ($Record.PSObject.Properties["pending_previous_model_path"]) { Resolve-ModelPath -Path ([string]$Record.pending_previous_model_path) } else { $null }
                pending_launch_pid       = if ($Record.PSObject.Properties["pending_launch_pid"] -and $null -ne $Record.pending_launch_pid -and [string]$Record.pending_launch_pid -match '^\d+$') { [int]$Record.pending_launch_pid } else { $null }
            }

            if ($NormalizedRecord.pending_launch_pid -and -not (Get-Process -Id $NormalizedRecord.pending_launch_pid -ErrorAction SilentlyContinue)) {
                $NormalizedRecord.pending_started_at = $null
                $NormalizedRecord.pending_previous_model_path = $null
                $NormalizedRecord.pending_launch_pid = $null
            }

            [pscustomobject]$NormalizedRecord
        }
    )

    return [pscustomobject]@{
        version = 1
        records = $NormalizedRecords
    }
}

function Save-ModelSwitchTimingData {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $Payload = [ordered]@{
        version = 1
        records = @($Records)
    }

    $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ModelSwitchTimingRecord {
    param(
        [string]$ModelPath,
        [string]$Path = $ModelSwitchTimingFile
    )

    $ResolvedModelPath = Resolve-ModelPath -Path $ModelPath
    if ([string]::IsNullOrWhiteSpace($ResolvedModelPath)) {
        return $null
    }

    $Data = Get-ModelSwitchTimingData -Path $Path
    return @(
        $Data.records |
            Where-Object { [string]::Equals($_.model_path, $ResolvedModelPath, [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
    )
}

function Set-ModelSwitchTimingPending {
    param(
        [string]$TargetModelPath,
        [string]$PreviousModelPath,
        [datetime]$StartedAt,
        [Nullable[int]]$LaunchPid = $null
    )

    $ResolvedTargetModelPath = Resolve-ModelPath -Path $TargetModelPath
    if ([string]::IsNullOrWhiteSpace($ResolvedTargetModelPath)) {
        return $null
    }

    $ResolvedPreviousModelPath = Resolve-ModelPath -Path $PreviousModelPath
    $Data = Get-ModelSwitchTimingData -Path $ModelSwitchTimingFile
    $UpdatedRecords = New-Object System.Collections.Generic.List[object]
    $Matched = $false
    $UpdatedRecord = $null

    foreach ($Record in @($Data.records)) {
        if ([string]::Equals($Record.model_path, $ResolvedTargetModelPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $UpdatedRecord = [pscustomobject][ordered]@{
                model_path               = $ResolvedTargetModelPath
                last_switch_duration_ms  = if ($Record.PSObject.Properties["last_switch_duration_ms"]) { $Record.last_switch_duration_ms } else { $null }
                last_switched_at         = if ($Record.PSObject.Properties["last_switched_at"]) { [string]$Record.last_switched_at } else { $null }
                last_previous_model_path = if ($Record.PSObject.Properties["last_previous_model_path"]) { Resolve-ModelPath -Path ([string]$Record.last_previous_model_path) } else { $null }
                pending_started_at       = $StartedAt.ToString("o")
                pending_previous_model_path = $ResolvedPreviousModelPath
                pending_launch_pid       = if ($LaunchPid.HasValue) { [int]$LaunchPid.Value } else { $null }
            }
            $UpdatedRecords.Add($UpdatedRecord)
            $Matched = $true
        }
        else {
            $UpdatedRecords.Add($Record)
        }
    }

    if (-not $Matched) {
        $UpdatedRecord = [pscustomobject][ordered]@{
            model_path               = $ResolvedTargetModelPath
            last_switch_duration_ms  = $null
            last_switched_at         = $null
            last_previous_model_path = $null
            pending_started_at       = $StartedAt.ToString("o")
            pending_previous_model_path = $ResolvedPreviousModelPath
            pending_launch_pid       = if ($LaunchPid.HasValue) { [int]$LaunchPid.Value } else { $null }
        }
        $UpdatedRecords.Add($UpdatedRecord)
    }

    Save-ModelSwitchTimingData -Path $ModelSwitchTimingFile -Records $UpdatedRecords.ToArray()
    return $UpdatedRecord
}

function Complete-ModelSwitchTimingMeasurement {
    param(
        [string]$TargetModelPath,
        [string]$PreviousModelPath,
        [datetime]$StartedAt,
        [datetime]$CompletedAt,
        [Nullable[int]]$LaunchPid = $null
    )

    $ResolvedTargetModelPath = Resolve-ModelPath -Path $TargetModelPath
    if ([string]::IsNullOrWhiteSpace($ResolvedTargetModelPath)) {
        return $null
    }

    $ResolvedPreviousModelPath = Resolve-ModelPath -Path $PreviousModelPath
    $DurationMs = [int][Math]::Max(0, [Math]::Round(($CompletedAt.ToUniversalTime() - $StartedAt.ToUniversalTime()).TotalMilliseconds))
    $Data = Get-ModelSwitchTimingData -Path $ModelSwitchTimingFile
    $UpdatedRecords = New-Object System.Collections.Generic.List[object]
    $Matched = $false
    $UpdatedRecord = $null

    foreach ($Record in @($Data.records)) {
        if ([string]::Equals($Record.model_path, $ResolvedTargetModelPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ExistingPendingPid = if ($Record.PSObject.Properties["pending_launch_pid"] -and $null -ne $Record.pending_launch_pid -and [string]$Record.pending_launch_pid -match '^\d+$') { [int]$Record.pending_launch_pid } else { $null }
            if ($LaunchPid.HasValue -and $null -ne $ExistingPendingPid -and $ExistingPendingPid -ne $LaunchPid.Value) {
                $UpdatedRecords.Add($Record)
                $Matched = $true
                continue
            }

            $UpdatedRecord = [pscustomobject][ordered]@{
                model_path               = $ResolvedTargetModelPath
                last_switch_duration_ms  = $DurationMs
                last_switched_at         = $CompletedAt.ToString("o")
                last_previous_model_path = $ResolvedPreviousModelPath
                pending_started_at       = $null
                pending_previous_model_path = $null
                pending_launch_pid       = $null
            }
            $UpdatedRecords.Add($UpdatedRecord)
            $Matched = $true
        }
        else {
            $UpdatedRecords.Add($Record)
        }
    }

    if (-not $Matched) {
        $UpdatedRecord = [pscustomobject][ordered]@{
            model_path               = $ResolvedTargetModelPath
            last_switch_duration_ms  = $DurationMs
            last_switched_at         = $CompletedAt.ToString("o")
            last_previous_model_path = $ResolvedPreviousModelPath
            pending_started_at       = $null
            pending_previous_model_path = $null
            pending_launch_pid       = $null
        }
        $UpdatedRecords.Add($UpdatedRecord)
    }

    Save-ModelSwitchTimingData -Path $ModelSwitchTimingFile -Records $UpdatedRecords.ToArray()
    return $UpdatedRecord
}

function Clear-ModelSwitchTimingPending {
    param(
        [string]$TargetModelPath,
        [Nullable[int]]$LaunchPid = $null
    )

    $ResolvedTargetModelPath = Resolve-ModelPath -Path $TargetModelPath
    if ([string]::IsNullOrWhiteSpace($ResolvedTargetModelPath)) {
        return
    }

    $Data = Get-ModelSwitchTimingData -Path $ModelSwitchTimingFile
    $UpdatedRecords = New-Object System.Collections.Generic.List[object]

    foreach ($Record in @($Data.records)) {
        if ([string]::Equals($Record.model_path, $ResolvedTargetModelPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ExistingPendingPid = if ($Record.PSObject.Properties["pending_launch_pid"] -and $null -ne $Record.pending_launch_pid -and [string]$Record.pending_launch_pid -match '^\d+$') { [int]$Record.pending_launch_pid } else { $null }
            if ($LaunchPid.HasValue -and $null -ne $ExistingPendingPid -and $ExistingPendingPid -ne $LaunchPid.Value) {
                $UpdatedRecords.Add($Record)
                continue
            }

            $UpdatedRecords.Add([pscustomobject][ordered]@{
                model_path               = $ResolvedTargetModelPath
                last_switch_duration_ms  = if ($Record.PSObject.Properties["last_switch_duration_ms"]) { $Record.last_switch_duration_ms } else { $null }
                last_switched_at         = if ($Record.PSObject.Properties["last_switched_at"]) { [string]$Record.last_switched_at } else { $null }
                last_previous_model_path = if ($Record.PSObject.Properties["last_previous_model_path"]) { Resolve-ModelPath -Path ([string]$Record.last_previous_model_path) } else { $null }
                pending_started_at       = $null
                pending_previous_model_path = $null
                pending_launch_pid       = $null
            })
        }
        else {
            $UpdatedRecords.Add($Record)
        }
    }

    Save-ModelSwitchTimingData -Path $ModelSwitchTimingFile -Records $UpdatedRecords.ToArray()
}

function New-ModelSwitchTimingContext {
    param(
        [string]$PreviousModelPath,
        [string]$TargetModelPath,
        [datetime]$SwitchStartedAt
    )

    $ResolvedPreviousModelPath = Resolve-ModelPath -Path $PreviousModelPath
    $ResolvedTargetModelPath = Resolve-ModelPath -Path $TargetModelPath
    if ([string]::IsNullOrWhiteSpace($ResolvedPreviousModelPath) -or [string]::IsNullOrWhiteSpace($ResolvedTargetModelPath)) {
        return $null
    }

    if ([string]::Equals($ResolvedPreviousModelPath, $ResolvedTargetModelPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return [pscustomobject]@{
        PreviousModelPath = $ResolvedPreviousModelPath
        TargetModelPath   = $ResolvedTargetModelPath
        SwitchStartedAt   = $SwitchStartedAt
    }
}

function Start-ModelSwitchTimingRecorderDetached {
    param(
        [string]$TargetModelPath,
        [string]$PreviousModelPath,
        [datetime]$StartedAt,
        [string]$ServerBaseUrl,
        [int]$TimeoutSec,
        [Nullable[int]]$ExpectedLaunchPid = $null,
        [string]$TrackingPidFile = $null
    )

    $PowerShellExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($PowerShellExe) -or -not (Test-Path -LiteralPath $PowerShellExe)) {
        return
    }

    $EncodeUtf8 = {
        param([string]$Text)
        $SafeText = if ($null -eq $Text) { "" } else { $Text }
        [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SafeText))
    }

    $EncodedTargetModelPath = & $EncodeUtf8 $TargetModelPath
    $EncodedPreviousModelPath = & $EncodeUtf8 $PreviousModelPath
    $EncodedStartedAt = & $EncodeUtf8 $StartedAt.ToString("o")
    $EncodedServerBaseUrl = & $EncodeUtf8 $ServerBaseUrl
    $EncodedTimingPath = & $EncodeUtf8 $ModelSwitchTimingFile
    $EncodedTrackingPidFile = & $EncodeUtf8 $TrackingPidFile
    $ExpectedLaunchPidText = if ($ExpectedLaunchPid.HasValue) { [string]$ExpectedLaunchPid.Value } else { "" }

    $RecorderScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
function Decode-Text([string]`$Base64Text) {
    if ([string]::IsNullOrWhiteSpace(`$Base64Text)) {
        return ''
    }

    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$Base64Text))
}
function Ensure-TimingFile([string]`$Path) {
    if (Test-Path -LiteralPath `$Path) {
        return
    }

    ([ordered]@{ version = 1; records = @() } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath `$Path -Encoding UTF8
}
function Load-TimingData([string]`$Path) {
    Ensure-TimingFile -Path `$Path
    `$Json = Get-Content -LiteralPath `$Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace(`$Json)) {
        return [pscustomobject]@{ version = 1; records = @() }
    }

    `$Data = `$Json | ConvertFrom-Json
    if (-not `$Data.records) {
        `$Data | Add-Member -NotePropertyName records -NotePropertyValue @() -Force
    }

    return `$Data
}
function Save-TimingData([string]`$Path, [object[]]`$Records) {
    ([ordered]@{ version = 1; records = @(`$Records) } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath `$Path -Encoding UTF8
}
function Update-TimingRecord([string]`$Path, [string]`$TargetModelPath, [string]`$PreviousModelPath, [datetime]`$StartedAt, [Nullable[int]]`$ExpectedLaunchPid, [switch]`$Complete, [switch]`$ClearPending) {
    `$Data = Load-TimingData -Path `$Path
    `$UpdatedRecords = New-Object System.Collections.Generic.List[object]
    `$Matched = `$false

    foreach (`$Record in @(`$Data.records)) {
        if (-not [string]::Equals([string]`$Record.model_path, `$TargetModelPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            `$UpdatedRecords.Add(`$Record)
            continue
        }

        `$ExistingPendingPid = if (`$Record.PSObject.Properties['pending_launch_pid'] -and `$null -ne `$Record.pending_launch_pid -and [string]`$Record.pending_launch_pid -match '^\d+$') { [int]`$Record.pending_launch_pid } else { `$null }
        if (`$ExpectedLaunchPid.HasValue -and `$null -ne `$ExistingPendingPid -and `$ExistingPendingPid -ne `$ExpectedLaunchPid.Value) {
            `$UpdatedRecords.Add(`$Record)
            `$Matched = `$true
            continue
        }

        if (`$Complete) {
            `$CompletedAt = Get-Date
            `$DurationMs = [int][Math]::Max(0, [Math]::Round((`$CompletedAt.ToUniversalTime() - `$StartedAt.ToUniversalTime()).TotalMilliseconds))
            `$UpdatedRecords.Add([pscustomobject][ordered]@{
                model_path               = `$TargetModelPath
                last_switch_duration_ms  = `$DurationMs
                last_switched_at         = `$CompletedAt.ToString('o')
                last_previous_model_path = `$PreviousModelPath
                pending_started_at       = `$null
                pending_previous_model_path = `$null
                pending_launch_pid       = `$null
            })
        }
        elseif (`$ClearPending) {
            `$UpdatedRecords.Add([pscustomobject][ordered]@{
                model_path               = `$TargetModelPath
                last_switch_duration_ms  = if (`$Record.PSObject.Properties['last_switch_duration_ms']) { `$Record.last_switch_duration_ms } else { `$null }
                last_switched_at         = if (`$Record.PSObject.Properties['last_switched_at']) { [string]`$Record.last_switched_at } else { `$null }
                last_previous_model_path = if (`$Record.PSObject.Properties['last_previous_model_path']) { [string]`$Record.last_previous_model_path } else { `$null }
                pending_started_at       = `$null
                pending_previous_model_path = `$null
                pending_launch_pid       = `$null
            })
        }

        `$Matched = `$true
    }

    if (-not `$Matched -and `$Complete) {
        `$CompletedAt = Get-Date
        `$DurationMs = [int][Math]::Max(0, [Math]::Round((`$CompletedAt.ToUniversalTime() - `$StartedAt.ToUniversalTime()).TotalMilliseconds))
        `$UpdatedRecords.Add([pscustomobject][ordered]@{
            model_path               = `$TargetModelPath
            last_switch_duration_ms  = `$DurationMs
            last_switched_at         = `$CompletedAt.ToString('o')
            last_previous_model_path = `$PreviousModelPath
            pending_started_at       = `$null
            pending_previous_model_path = `$null
            pending_launch_pid       = `$null
        })
    }

    Save-TimingData -Path `$Path -Records `$UpdatedRecords.ToArray()
}
`$TargetModelPath = Decode-Text '$EncodedTargetModelPath'
`$PreviousModelPath = Decode-Text '$EncodedPreviousModelPath'
`$StartedAt = [datetime]::Parse((Decode-Text '$EncodedStartedAt'))
`$ServerBaseUrl = Decode-Text '$EncodedServerBaseUrl'
`$TimingPath = Decode-Text '$EncodedTimingPath'
`$TrackingPidFile = Decode-Text '$EncodedTrackingPidFile'
`$ExpectedLaunchPid = if ('$ExpectedLaunchPidText' -match '^\d+$') { [Nullable[int]][int]'$ExpectedLaunchPidText' } else { [Nullable[int]]`$null }
`$Deadline = (Get-Date).AddSeconds($([Math]::Max(30, $TimeoutSec)))
`$ReadyUrls = @("`$ServerBaseUrl/health", "`$ServerBaseUrl/v1/models")

while ((Get-Date) -lt `$Deadline) {
    if (`$ExpectedLaunchPid.HasValue) {
        if (-not (Get-Process -Id `$ExpectedLaunchPid.Value -ErrorAction SilentlyContinue)) {
            Update-TimingRecord -Path `$TimingPath -TargetModelPath `$TargetModelPath -PreviousModelPath `$PreviousModelPath -StartedAt `$StartedAt -ExpectedLaunchPid `$ExpectedLaunchPid -ClearPending
            exit 0
        }

        if (-not [string]::IsNullOrWhiteSpace(`$TrackingPidFile) -and (Test-Path -LiteralPath `$TrackingPidFile)) {
            `$TrackedPidText = ((Get-Content -LiteralPath `$TrackingPidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
            if (`$TrackedPidText -match '^\d+$' -and [int]`$TrackedPidText -ne `$ExpectedLaunchPid.Value) {
                Update-TimingRecord -Path `$TimingPath -TargetModelPath `$TargetModelPath -PreviousModelPath `$PreviousModelPath -StartedAt `$StartedAt -ExpectedLaunchPid `$ExpectedLaunchPid -ClearPending
                exit 0
            }
        }
    }

    foreach (`$ReadyUrl in `$ReadyUrls) {
        try {
            `$Response = Invoke-WebRequest -Uri `$ReadyUrl -UseBasicParsing -TimeoutSec 5
            if (`$Response.StatusCode -ge 200 -and `$Response.StatusCode -lt 300) {
                Update-TimingRecord -Path `$TimingPath -TargetModelPath `$TargetModelPath -PreviousModelPath `$PreviousModelPath -StartedAt `$StartedAt -ExpectedLaunchPid `$ExpectedLaunchPid -Complete
                exit 0
            }
        }
        catch {
        }
    }

    Start-Sleep -Seconds 2
}

Update-TimingRecord -Path `$TimingPath -TargetModelPath `$TargetModelPath -PreviousModelPath `$PreviousModelPath -StartedAt `$StartedAt -ExpectedLaunchPid `$ExpectedLaunchPid -ClearPending
"@

    $EncodedRecorderScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($RecorderScript))
    Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList @("-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $EncodedRecorderScript) `
        -WindowStyle Hidden | Out-Null
}

function Format-ElapsedDuration {
    param(
        $DurationMs
    )

    if ($null -eq $DurationMs) {
        return $null
    }

    $Duration = [TimeSpan]::FromMilliseconds([double]$DurationMs)
    if ($Duration.TotalSeconds -lt 10) {
        return "{0:N1}s" -f $Duration.TotalSeconds
    }

    if ($Duration.TotalSeconds -lt 60) {
        return "{0:N0}s" -f $Duration.TotalSeconds
    }

    if ($Duration.TotalHours -lt 1) {
        return "{0}m {1:00}s" -f [int][Math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    }

    return "{0}h {1:00}m {2:00}s" -f [int][Math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds
}

function Get-ModelPathLabel {
    param(
        [string]$Path
    )

    $ResolvedPath = Resolve-ModelPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($ResolvedPath)) {
        return $null
    }

    if ([System.IO.Path]::HasExtension($ResolvedPath)) {
        return [System.IO.Path]::GetFileNameWithoutExtension($ResolvedPath)
    }

    return Split-Path -Path $ResolvedPath -Leaf
}

function Get-ModelFileSizeLabel {
    param(
        [string]$Path
    )

    $ResolvedPath = Resolve-ModelPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($ResolvedPath)) {
        return "[--]"
    }

    $SizeBytes = Get-ModelFileSizeBytes -Path $ResolvedPath
    if ($script:ModelFileSizeLabelCache.ContainsKey($ResolvedPath)) {
        return $script:ModelFileSizeLabelCache[$ResolvedPath]
    }

    $Label = "[--]"

    try {
        if ($SizeBytes -ge 0) {
            $ScaledSize = [double]$SizeBytes
            $Units = @("B", "KB", "MB", "GB", "TB", "PB")
            $UnitIndex = 0

            while ($ScaledSize -ge 1024 -and $UnitIndex -lt ($Units.Count - 1)) {
                $ScaledSize /= 1024
                $UnitIndex++
            }

            $Precision = if ($UnitIndex -eq 0) { 0 } else { 2 }
            $SizeText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:N$Precision}", $ScaledSize)
            $Label = "[{0} {1}]" -f $SizeText, $Units[$UnitIndex]
        }
    }
    catch {
    }

    $script:ModelFileSizeLabelCache[$ResolvedPath] = $Label
    return $Label
}

function Get-ModelFileSizeBytes {
    param(
        [string]$Path
    )

    $ResolvedPath = Resolve-ModelPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($ResolvedPath)) {
        return -1L
    }

    if ($script:ModelFileSizeBytesCache.ContainsKey($ResolvedPath)) {
        return [int64]$script:ModelFileSizeBytesCache[$ResolvedPath]
    }

    $SizeBytes = -1L

    try {
        if (Test-Path -LiteralPath $ResolvedPath) {
            $FileInfo = Get-Item -LiteralPath $ResolvedPath -ErrorAction Stop
            $SizeBytes = [int64]$FileInfo.Length
        }
    }
    catch {
    }

    $script:ModelFileSizeBytesCache[$ResolvedPath] = $SizeBytes
    return $SizeBytes
}

function Get-ModelSwitchTimingSummary {
    param(
        $ModelEntry
    )

    if (-not $ModelEntry) {
        return $null
    }

    $SwitchTiming = if ($ModelEntry.PSObject.Properties["switch_timing"]) { $ModelEntry.switch_timing } else { Get-ModelSwitchTimingRecord -ModelPath $ModelEntry.path }
    if (-not $SwitchTiming) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$SwitchTiming.pending_started_at)) {
        $FromLabel = Get-ModelPathLabel -Path $SwitchTiming.pending_previous_model_path
        if ($FromLabel) {
            return "Switch: measuring from {0}" -f $FromLabel
        }

        return "Switch: measuring..."
    }

    $DurationText = Format-ElapsedDuration -DurationMs $SwitchTiming.last_switch_duration_ms
    if (-not $DurationText) {
        return $null
    }

    $Summary = "Switch: {0}" -f $DurationText
    $FromLabel = Get-ModelPathLabel -Path $SwitchTiming.last_previous_model_path
    if ($FromLabel) {
        $Summary += " from $FromLabel"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$SwitchTiming.last_switched_at)) {
        try {
            $Summary += " @ " + ([datetime]$SwitchTiming.last_switched_at).ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
        }
    }

    return $Summary
}

function Get-ModelSwitchTimingDetailLines {
    param(
        $ModelEntry
    )

    if (-not $ModelEntry) {
        return @("Last Switch  : no recorded switch yet")
    }

    $SwitchTiming = if ($ModelEntry.PSObject.Properties["switch_timing"]) { $ModelEntry.switch_timing } else { Get-ModelSwitchTimingRecord -ModelPath $ModelEntry.path }
    if (-not $SwitchTiming) {
        return @("Last Switch  : no recorded switch yet")
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$SwitchTiming.pending_started_at)) {
        $Lines = @("Last Switch  : measuring current load")
        $FromLabel = Get-ModelPathLabel -Path $SwitchTiming.pending_previous_model_path
        if ($FromLabel) {
            $Lines += "Switch From  : $FromLabel"
        }
        return $Lines
    }

    $DurationText = Format-ElapsedDuration -DurationMs $SwitchTiming.last_switch_duration_ms
    if (-not $DurationText) {
        return @("Last Switch  : no recorded switch yet")
    }

    $Lines = @("Last Switch  : $DurationText")
    $FromLabel = Get-ModelPathLabel -Path $SwitchTiming.last_previous_model_path
    if ($FromLabel) {
        $Lines += "Switch From  : $FromLabel"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$SwitchTiming.last_switched_at)) {
        try {
            $Lines += "Switched At  : " + ([datetime]$SwitchTiming.last_switched_at).ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
        }
    }

    return $Lines
}

function Ensure-ModelIndexFile {
    param(
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        return
    }

    if (Refresh-ModelIndexFromDefaultScanPath -Path $Path -PrimaryModelPath $ModelPath -Quiet) {
        return
    }

    $BootstrapModelPath = Resolve-ModelPath -Path $ModelPath
    $Bootstrap = [ordered]@{
        default_model_id = $null
        models           = @()
    }

    if (-not [string]::IsNullOrWhiteSpace($BootstrapModelPath)) {
        $Bootstrap.default_model_id = "default"
        $Bootstrap.models = @(
            [ordered]@{
                id           = "default"
                name         = [System.IO.Path]::GetFileNameWithoutExtension($BootstrapModelPath)
                path         = $BootstrapModelPath
                capabilities = $null
                notes        = "Bootstrap entry created by Start_LCPP.ps1."
            }
        )

        $Bootstrap.models[0].capabilities = Resolve-ModelEntryCapabilities -ModelEntry ([pscustomobject]$Bootstrap.models[0])
    }

    $Bootstrap | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Initialize-JsonWorkspaceFiles {
    param(
        [string]$IndexPath
    )

    Ensure-TuningProfileFile -Path $TuningProfileFile
    Ensure-ModelSwitchTimingFile -Path $ModelSwitchTimingFile
    Ensure-ModelIndexFile -Path $IndexPath
}

function Get-ModelIndexData {
    param(
        [string]$Path
    )

    Ensure-ModelIndexFile -Path $Path
    $Json = Get-Content -LiteralPath $Path -Raw
    $Data = $Json | ConvertFrom-Json

    if (-not $Data.models -or $Data.models.Count -eq 0) {
        throw "The model index is empty: $Path. Add GGUF models to the scan folder or edit json\model-index.json."
    }

    $SwitchTimingByPath = @{}
    foreach ($Record in @(Get-ModelSwitchTimingData -Path $ModelSwitchTimingFile).records) {
        if ($Record -and -not [string]::IsNullOrWhiteSpace([string]$Record.model_path)) {
            $SwitchTimingByPath[$Record.model_path.ToLowerInvariant()] = $Record
        }
    }

    foreach ($Model in @($Data.models)) {
        $ResolvedCapabilities = Resolve-ModelEntryCapabilities -ModelEntry $Model
        if ($Model.PSObject.Properties["capabilities"]) {
            $Model.capabilities = $ResolvedCapabilities
        }
        else {
            $Model | Add-Member -NotePropertyName "capabilities" -NotePropertyValue $ResolvedCapabilities
        }

        $ResolvedModelPath = Resolve-ModelPath -Path $Model.path
        $SwitchTiming = if ($ResolvedModelPath -and $SwitchTimingByPath.ContainsKey($ResolvedModelPath.ToLowerInvariant())) { $SwitchTimingByPath[$ResolvedModelPath.ToLowerInvariant()] } else { $null }
        if ($Model.PSObject.Properties["switch_timing"]) {
            $Model.switch_timing = $SwitchTiming
        }
        else {
            $Model | Add-Member -NotePropertyName "switch_timing" -NotePropertyValue $SwitchTiming
        }
    }

    return $Data
}

function Resolve-LaunchModelPath {
    param(
        [string]$IndexPath,
        [string]$RequestedModelPath
    )

    $ResolvedRequestedModelPath = Resolve-ModelPath -Path $RequestedModelPath
    if (-not [string]::IsNullOrWhiteSpace($ResolvedRequestedModelPath)) {
        return $ResolvedRequestedModelPath
    }

    Ensure-ModelIndexFile -Path $IndexPath
    $DefaultModelPath = Get-PreferredDefaultModelPath -IndexPath $IndexPath -PrimaryModelPath $null
    if (-not [string]::IsNullOrWhiteSpace($DefaultModelPath)) {
        return $DefaultModelPath
    }

    throw "Could not determine a default model from $IndexPath. Set -ModelPath or update json\model-index.json."
}

function Format-ModelCapabilities {
    param(
        $ModelEntry
    )

    if (-not $ModelEntry) {
        return "Chat:N | Reasoning:N | Vision:N | Tools:N | Embedding:N | Rerank:N"
    }

    $Capabilities = Resolve-ModelEntryCapabilities -ModelEntry $ModelEntry
    $Flags = @(
        "Chat:{0}" -f $(if (ConvertTo-BoolFlag $Capabilities.chat) { "Y" } else { "N" }),
        "Reasoning:{0}" -f $(if (ConvertTo-BoolFlag $Capabilities.reasoning) { "Y" } else { "N" }),
        "Vision:{0}" -f $(if (ConvertTo-BoolFlag $Capabilities.vision) { "Y" } else { "N" }),
        "Tools:{0}" -f $(if (ConvertTo-BoolFlag $Capabilities.tools) { "Y" } else { "N" }),
        "Embedding:{0}" -f $(if (ConvertTo-BoolFlag $Capabilities.embedding) { "Y" } else { "N" }),
        "Rerank:{0}" -f $(if (ConvertTo-BoolFlag $Capabilities.rerank) { "Y" } else { "N" })
    )

    return ($Flags -join " | ")
}

function Split-ArgumentLine {
    param(
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return @()
    }

    $Matches = [regex]::Matches($Line, '(?:"((?:[^"\\]|\\.)*)"|(\S+))')
    $Tokens = foreach ($Match in $Matches) {
        if ($Match.Groups[1].Success) {
            $Match.Groups[1].Value.Replace('\"', '"')
        }
        else {
            $Match.Groups[2].Value
        }
    }

    return @($Tokens)
}

function Convert-ForwardArgsToMenuConfig {
    param(
        [string[]]$Arguments
    )

    $Config = [ordered]@{
        ContextSize = ""
        Host        = "127.0.0.1"
        Metrics     = $false
        ApiKey      = ""
        Device      = ""
        SplitMode   = ""
        TensorSplit = ""
        Fit         = ""
        ExtraArgs   = ""
    }

    if (-not $Arguments) {
        return $Config
    }

    $Remaining = New-Object System.Collections.Generic.List[string]

    for ($Index = 0; $Index -lt $Arguments.Count; $Index++) {
        $Argument = $Arguments[$Index]

        switch -Regex ($Argument) {
            '^--ctx-size(?:=(.+))?$' {
                $Config.ContextSize = if ($Matches[1]) { $Matches[1] } else { $Arguments[++$Index] }
            }
            '^--host(?:=(.+))?$' {
                $Config.Host = if ($Matches[1]) { $Matches[1] } else { $Arguments[++$Index] }
            }
            '^--metrics$' {
                $Config.Metrics = $true
            }
            '^--api-key(?:=(.+))?$' {
                $Config.ApiKey = if ($Matches[1]) { $Matches[1] } else { $Arguments[++$Index] }
            }
            '^--device(?:=(.+))?$' {
                $Config.Device = if ($Matches[1]) { $Matches[1] } else { $Arguments[++$Index] }
            }
            '^--split-mode(?:=(.+))?$' {
                $Config.SplitMode = if ($Matches[1]) { $Matches[1] } else { $Arguments[++$Index] }
            }
            '^--tensor-split(?:=(.+))?$' {
                $Config.TensorSplit = if ($Matches[1]) { $Matches[1] } else { $Arguments[++$Index] }
            }
            '^--fit(?:=(.+))?$' {
                $Config.Fit = if ($Matches[1]) { $Matches[1] } else { $Arguments[++$Index] }
            }
            default {
                $Remaining.Add($Argument)
            }
        }
    }

    $Config.ExtraArgs = ($Remaining -join " ")
    return $Config
}

function Convert-MenuConfigToForwardArgs {
    param(
        [System.Collections.IDictionary]$Config
    )

    $Arguments = New-Object System.Collections.Generic.List[string]

    if ($Config.ContextSize) {
        $Arguments.Add("--ctx-size")
        $Arguments.Add([string]$Config.ContextSize)
    }

    if ($Config.Host) {
        $Arguments.Add("--host")
        $Arguments.Add([string]$Config.Host)
    }

    if ($Config.Metrics) {
        $Arguments.Add("--metrics")
    }

    if ($Config.ApiKey) {
        $Arguments.Add("--api-key")
        $Arguments.Add([string]$Config.ApiKey)
    }

    if ($Config.Device) {
        $Arguments.Add("--device")
        $Arguments.Add([string]$Config.Device)
    }

    if ($Config.SplitMode) {
        $Arguments.Add("--split-mode")
        $Arguments.Add([string]$Config.SplitMode)
    }

    if ($Config.TensorSplit) {
        $Arguments.Add("--tensor-split")
        $Arguments.Add([string]$Config.TensorSplit)
    }

    if ($Config.Fit) {
        $Arguments.Add("--fit")
        $Arguments.Add([string]$Config.Fit)
    }

    foreach ($ExtraArgument in (Split-ArgumentLine -Line $Config.ExtraArgs)) {
        $Arguments.Add($ExtraArgument)
    }

    return @($Arguments)
}

function Get-ArgumentFingerprint {
    param(
        [string[]]$Arguments
    )

    if (-not $Arguments -or $Arguments.Count -eq 0) {
        return ""
    }

    return (($Arguments | ForEach-Object { $_.Trim() }) -join [char]31).ToLowerInvariant()
}

function Ensure-TuningProfileFile {
    param(
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        return
    }

    $Bootstrap = [ordered]@{
        version  = 1
        profiles = @()
    }

    $Bootstrap | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-TuningProfileData {
    param(
        [string]$Path
    )

    Ensure-TuningProfileFile -Path $Path
    $Json = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return [pscustomobject]@{
            version  = 1
            profiles = @()
        }
    }

    $Data = $Json | ConvertFrom-Json
    if (-not $Data.profiles) {
        $Data | Add-Member -NotePropertyName profiles -NotePropertyValue @() -Force
    }

    return $Data
}

function Save-TuningProfileData {
    param(
        [string]$Path,
        [object[]]$Profiles
    )

    $Payload = [ordered]@{
        version  = 1
        profiles = @($Profiles)
    }

    $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-LaunchTuningContext {
    param(
        [string]$ResolvedModelPath,
        [string[]]$Arguments,
        [bool]$UseExtremeMode,
        [object[]]$AcceleratorInventory
    )

    $ForwardConfig = Convert-ForwardArgsToMenuConfig -Arguments $Arguments
    $RelevantArgs = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$ForwardConfig.ContextSize)) {
        $RelevantArgs.Add("--ctx-size")
        $RelevantArgs.Add([string]$ForwardConfig.ContextSize)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ForwardConfig.Device)) {
        $RelevantArgs.Add("--device")
        $RelevantArgs.Add([string]$ForwardConfig.Device)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ForwardConfig.SplitMode)) {
        $RelevantArgs.Add("--split-mode")
        $RelevantArgs.Add([string]$ForwardConfig.SplitMode)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ForwardConfig.TensorSplit)) {
        $RelevantArgs.Add("--tensor-split")
        $RelevantArgs.Add([string]$ForwardConfig.TensorSplit)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ForwardConfig.Fit)) {
        $RelevantArgs.Add("--fit")
        $RelevantArgs.Add([string]$ForwardConfig.Fit)
    }
    foreach ($ExtraArgument in (Split-ArgumentLine -Line ([string]$ForwardConfig.ExtraArgs))) {
        $RelevantArgs.Add($ExtraArgument)
    }

    $ArgumentFingerprint = Get-ArgumentFingerprint -Arguments $RelevantArgs.ToArray()
    $ArgumentPreview = ConvertTo-ArgumentString -Arguments $RelevantArgs.ToArray()
    $AcceleratorSignature = Get-AcceleratorSignature -Inventory $AcceleratorInventory
    $FingerprintParts = @(
        (Normalize-TuningText -Text $ResolvedModelPath).ToLowerInvariant()
        $AcceleratorSignature
        ("extreme={0}" -f [bool]$UseExtremeMode)
        ("args={0}" -f $ArgumentFingerprint)
    )

    return [pscustomobject]@{
        ModelPath            = $ResolvedModelPath
        ExtremeMode          = [bool]$UseExtremeMode
        ArgumentFingerprint  = $ArgumentFingerprint
        ArgumentPreview      = $ArgumentPreview
        AcceleratorSignature = $AcceleratorSignature
        AcceleratorInventory = @($AcceleratorInventory)
        Fingerprint          = ($FingerprintParts -join "|")
    }
}

function Get-SavedAutoTuneProfile {
    param(
        $TuningContext,
        [int]$ReuseHeadroomMiB = $AutoTuneReuseHeadroomMiB
    )

    $Data = Get-TuningProfileData -Path $TuningProfileFile
    $Profile = @(
        $Data.profiles |
            Where-Object { $_.fingerprint -eq $TuningContext.Fingerprint } |
            Sort-Object updated_at -Descending |
            Select-Object -First 1
    )

    if (-not $Profile -or $Profile.Count -eq 0) {
        return [pscustomobject]@{
            Profile    = $null
            SkipReason = ""
        }
    }

    $MatchedProfile = $Profile[0]
    $CurrentInventoryById = @{}
    foreach ($Device in @($TuningContext.AcceleratorInventory)) {
        $CurrentInventoryById[$Device.Id.ToString().ToUpperInvariant()] = $Device
    }

    foreach ($ObservedDevice in @($MatchedProfile.observed_devices)) {
        $DeviceId = $ObservedDevice.device_id.ToString().ToUpperInvariant()
        if (-not $CurrentInventoryById.ContainsKey($DeviceId)) {
            return [pscustomobject]@{
                Profile    = $null
                SkipReason = "saved profile expects $DeviceId, but that device is not currently available"
            }
        }

        $CurrentDevice = $CurrentInventoryById[$DeviceId]
        $RequiredFreeMiB = [int][Math]::Ceiling([double]$ObservedDevice.used_mib + $ReuseHeadroomMiB)
        if ([int]$CurrentDevice.FreeMiB -lt $RequiredFreeMiB) {
            return [pscustomobject]@{
                Profile    = $null
                SkipReason = "saved profile needs about $RequiredFreeMiB MiB free on $DeviceId, but only $($CurrentDevice.FreeMiB) MiB is free now"
            }
        }
    }

    return [pscustomobject]@{
        Profile    = $MatchedProfile
        SkipReason = ""
    }
}

function Test-InteractiveConsole {
    try {
        $null = $Host.UI.RawUI.WindowSize
        return [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected)
    }
    catch {
        return $false
    }
}

function Get-ConsoleWidth {
    try {
        return [Math]::Max(80, $Host.UI.RawUI.WindowSize.Width)
    }
    catch {
        return 100
    }
}

function Get-FitText {
    param(
        [string]$Text,
        [int]$Width
    )

    $SafeText = if ($null -eq $Text) { "" } else { [string]$Text }
    if ($Width -lt 4) {
        return $SafeText
    }

    if ($SafeText.Length -le $Width) {
        return $SafeText
    }

    return $SafeText.Substring(0, $Width - 3) + "..."
}

function Read-ConsoleKey {
    return $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Show-MenuHeader {
    param(
        [string]$Title,
        [string]$Subtitle
    )

    Clear-Host
    Write-Host $Title -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host $Subtitle -ForegroundColor DarkGray
    }
    Write-Host ("".PadLeft([Math]::Min((Get-ConsoleWidth) - 1, 72), "=")) -ForegroundColor DarkGray
}

function Show-ListMenu {
    param(
        [string]$Title,
        [string]$Subtitle,
        [object[]]$Items,
        [int]$SelectedIndex = 0
    )

    if (-not $Items -or $Items.Count -eq 0) {
        return $null
    }

    $Index = [Math]::Max(0, [Math]::Min($SelectedIndex, $Items.Count - 1))

    while ($true) {
        Show-MenuHeader -Title $Title -Subtitle $Subtitle

        for ($ItemIndex = 0; $ItemIndex -lt $Items.Count; $ItemIndex++) {
            $Item = $Items[$ItemIndex]
            $IsSelected = $ItemIndex -eq $Index
            $Prefix = if ($IsSelected) { ">" } else { " " }
            $Color = if ($IsSelected) { "Black" } else { "Gray" }
            $Background = if ($IsSelected) { "DarkCyan" } else { "Black" }
            $Name = Get-FitText -Text $Item.Name -Width ([Math]::Max(20, (Get-ConsoleWidth) - 6))
            Write-Host ("{0} {1}" -f $Prefix, $Name) -ForegroundColor $Color -BackgroundColor $Background
            if ($Item.Description) {
                Write-Host ("    {0}" -f $Item.Description) -ForegroundColor DarkGray
            }
        }

        Write-Host ""
        Write-Host "Use Up/Down to move. Press Enter or Space to confirm. Esc returns." -ForegroundColor Yellow
        $Key = Read-ConsoleKey

        switch ($Key.VirtualKeyCode) {
            38 { $Index = if ($Index -le 0) { $Items.Count - 1 } else { $Index - 1 } }
            40 { $Index = if ($Index -ge ($Items.Count - 1)) { 0 } else { $Index + 1 } }
            13 { return $Items[$Index].Value }
            32 { return $Items[$Index].Value }
            27 { return $null }
            default {
                if ($Key.Character -match '^\d$') {
                    $HotIndex = [int]$Key.Character.ToString() - 1
                    if ($HotIndex -ge 0 -and $HotIndex -lt $Items.Count) {
                        return $Items[$HotIndex].Value
                    }
                }
            }
        }
    }
}

function Select-ModelEntry {
    param(
        [string]$IndexPath,
        [string]$CurrentModelPath
    )

    $ResolvedCurrentPath = Resolve-ModelPath -Path $CurrentModelPath

    while ($true) {
        $IndexData = Get-ModelIndexData -Path $IndexPath
        $Models = @(
            $IndexData.models |
                Sort-Object `
                    @{ Expression = { Get-ModelFileSizeBytes -Path $_.path }; Descending = $true }, `
                    @{ Expression = { [string]$_.name }; Descending = $false }
        )
        $SelectedIndex = 0

        if ($ResolvedCurrentPath) {
            for ($Index = 0; $Index -lt $Models.Count; $Index++) {
                $CandidatePath = Resolve-ModelPath -Path $Models[$Index].path
                if ([string]::Equals($CandidatePath, $ResolvedCurrentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $SelectedIndex = $Index
                    break
                }
            }
        }
        elseif ($IndexData.default_model_id) {
            for ($Index = 0; $Index -lt $Models.Count; $Index++) {
                if ($Models[$Index].id -eq $IndexData.default_model_id) {
                    $SelectedIndex = $Index
                    break
                }
            }
        }

        while ($true) {
            Show-MenuHeader -Title "Select Model" -Subtitle "Choose a model from the index. Press E to edit the index file."

            for ($Index = 0; $Index -lt $Models.Count; $Index++) {
                $Model = $Models[$Index]
                $IsSelected = $Index -eq $SelectedIndex
                $ModelPathResolved = Resolve-ModelPath -Path $Model.path
                $Exists = Test-Path -LiteralPath $ModelPathResolved
                $SizeLabel = Get-ModelFileSizeLabel -Path $Model.path
                $Prefix = if ($IsSelected) { ">" } else { " " }
                $Foreground = if ($IsSelected) { "Black" } else { "Gray" }
                $Background = if ($IsSelected) { "DarkCyan" } else { "Black" }
                $StateText = if ($Exists) { "OK" } else { "Missing" }
                $Summary = "{0} {1} [{2}] {3}" -f $SizeLabel, $Model.name, $StateText, (Format-ModelCapabilities -ModelEntry $Model)
                Write-Host ("{0} {1}" -f $Prefix, (Get-FitText -Text $Summary -Width ([Math]::Max(30, (Get-ConsoleWidth) - 6)))) -ForegroundColor $Foreground -BackgroundColor $Background
                if ($Model.notes) {
                    Write-Host ("    {0}" -f $Model.notes) -ForegroundColor DarkGray
                }
                $SwitchSummary = Get-ModelSwitchTimingSummary -ModelEntry $Model
                if ($SwitchSummary) {
                    Write-Host ("    {0}" -f $SwitchSummary) -ForegroundColor DarkGray
                }
            }

            $SelectedModel = $Models[$SelectedIndex]
            $SelectedModelPath = Resolve-ModelPath -Path $SelectedModel.path
            Write-Host ""
            Write-Host ("Name         : {0}" -f $SelectedModel.name) -ForegroundColor Cyan
            Write-Host ("Path         : {0}" -f $SelectedModelPath)
            Write-Host ("Size         : {0}" -f ((Get-ModelFileSizeLabel -Path $SelectedModel.path).TrimStart("[").TrimEnd("]")))
            Write-Host ("Capabilities : {0}" -f (Format-ModelCapabilities -ModelEntry $SelectedModel))
            foreach ($DetailLine in @(Get-ModelSwitchTimingDetailLines -ModelEntry $SelectedModel)) {
                Write-Host $DetailLine
            }
            if ($SelectedModel.notes) {
                Write-Host ("Notes        : {0}" -f $SelectedModel.notes) -ForegroundColor DarkGray
            }
            Write-Host ""
            Write-Host "Use Up/Down to move. Enter or Space confirms. E edits model-index.json. Esc returns." -ForegroundColor Yellow

            $Key = Read-ConsoleKey
            switch ($Key.VirtualKeyCode) {
                38 { $SelectedIndex = if ($SelectedIndex -le 0) { $Models.Count - 1 } else { $SelectedIndex - 1 } }
                40 { $SelectedIndex = if ($SelectedIndex -ge ($Models.Count - 1)) { 0 } else { $SelectedIndex + 1 } }
                13 { return $SelectedModel }
                32 { return $SelectedModel }
                27 { return $null }
                default {
                    if ($Key.Character -match '^[Ee]$') {
                        Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $IndexPath) -Wait
                        return Select-ModelEntry -IndexPath $IndexPath -CurrentModelPath $CurrentModelPath
                    }
                }
            }
        }
    }
}

function Show-LaunchModeMenu {
    $Options = @(
        [pscustomobject]@{ Name = "Background Service"; Description = "Start llama-server.exe in the background without opening a browser."; Value = "Background Service" },
        [pscustomobject]@{ Name = "Open Web UI"; Description = "Start the server and open the built-in Web UI in your browser."; Value = "Open Web UI" },
        [pscustomobject]@{ Name = "Back"; Description = "Return to the previous menu."; Value = "Back" }
    )

    return Show-ListMenu -Title "Launch Mode" -Subtitle "Choose how you want to start the server." -Items $Options
}

function Show-MainLauncherMenu {
    $Options = @(
        [pscustomobject]@{ Name = "Quick Start"; Description = "Pick a model, then choose background service or Web UI."; Value = "QuickStart" },
        [pscustomobject]@{ Name = "Tune And Launch"; Description = "Pick a model, edit a parameter matrix, then start."; Value = "TuneLaunch" },
        [pscustomobject]@{ Name = "Server Status"; Description = "Show tracked server status, runtime settings, and GPU offload summary."; Value = "Status" },
        [pscustomobject]@{ Name = "Stop Running Server"; Description = "Stop the currently tracked llama.cpp server."; Value = "Stop" },
        [pscustomobject]@{ Name = "llama-server Help"; Description = "Show the exact --help output from the installed llama-server.exe."; Value = "Help" },
        [pscustomobject]@{ Name = "Exit"; Description = "Leave the launcher without changing anything."; Value = "Exit" }
    )

    return Show-ListMenu -Title "llama.cpp Launcher" -Subtitle "First choose Quick Start or Tune And Launch. Utility actions stay here too." -Items $Options
}

function New-LaunchConfig {
    param(
        $ModelEntry,
        [System.Collections.IDictionary]$ForwardConfig
    )

    if (-not $ForwardConfig) {
        $ForwardConfig = Convert-ForwardArgsToMenuConfig -Arguments @()
    }

    $Config = [ordered]@{
        ModelName       = $ModelEntry.name
        ModelPath       = Resolve-ModelPath -Path $ModelEntry.path
        ModelCapabilities = Format-ModelCapabilities -ModelEntry $ModelEntry
        LaunchMode      = if ($NoBrowser) { "Background Service" } else { "Open Web UI" }
        Port            = [string]$Port
        GpuLayers       = [string]$GpuLayers
        RepeatingLayers = ""
        ModelRepeatingLayerCount = $null
        ExtremeMode     = [bool]$ExtremeMode
        AutoTune        = [bool]$AutoTune
        Threads         = [string]$RawThreads
        ThreadsBatch    = [string]$RawThreadsBatch
        ReadyTimeoutSec = [string]$ReadyTimeoutSec
        OpenPath        = if ($OpenPath) { $OpenPath } else { "/" }
        ContextSize     = [string]$ForwardConfig.ContextSize
        Host            = if ($ForwardConfig.Host) { [string]$ForwardConfig.Host } else { "127.0.0.1" }
        Metrics         = [bool]$ForwardConfig.Metrics
        ApiKey          = [string]$ForwardConfig.ApiKey
        Device          = [string]$ForwardConfig.Device
        SplitMode       = [string]$ForwardConfig.SplitMode
        TensorSplit     = [string]$ForwardConfig.TensorSplit
        Fit             = [string]$ForwardConfig.Fit
        ExtraArgs       = [string]$ForwardConfig.ExtraArgs
    }

    Sync-LaunchConfigGpuFields -Config $Config
    return $Config
}

function Get-LaunchConfigItems {
    return @(
        [pscustomobject]@{ Key = "Model"; Label = "Model"; Type = "model" },
        [pscustomobject]@{ Key = "LaunchMode"; Label = "Launch"; Type = "choice"; Choices = @("Background Service", "Open Web UI") },
        [pscustomobject]@{ Key = "Port"; Label = "Port"; Type = "number"; Hint = "1-65535" },
        [pscustomobject]@{ Key = "OpenPath"; Label = "Open Path"; Type = "text"; Hint = "For Web UI use /" },
        [pscustomobject]@{ Key = "GpuLayers"; Label = "GPU Layers"; Type = "text"; Hint = "auto, all, or number" },
        [pscustomobject]@{ Key = "RepeatingLayers"; Label = "Repeating Layers"; Type = "text"; Hint = "auto, all, or number of repeating layers" },
        [pscustomobject]@{ Key = "ExtremeMode"; Label = "Extreme VRAM"; Type = "bool" },
        [pscustomobject]@{ Key = "AutoTune"; Label = "Auto Tune"; Type = "bool" },
        [pscustomobject]@{ Key = "Threads"; Label = "Threads"; Type = "number"; Hint = "-1 or positive integer" },
        [pscustomobject]@{ Key = "ThreadsBatch"; Label = "Threads Batch"; Type = "number"; Hint = "-1 or positive integer" },
        [pscustomobject]@{ Key = "ReadyTimeoutSec"; Label = "Ready Timeout"; Type = "number"; Hint = "seconds" },
        [pscustomobject]@{ Key = "ContextSize"; Label = "Context Size"; Type = "numberOrBlank"; Hint = "blank uses llama.cpp default" },
        [pscustomobject]@{ Key = "Host"; Label = "Host"; Type = "text"; Hint = "127.0.0.1 or 0.0.0.0" },
        [pscustomobject]@{ Key = "Metrics"; Label = "Metrics"; Type = "bool" },
        [pscustomobject]@{ Key = "ApiKey"; Label = "API Key"; Type = "text" },
        [pscustomobject]@{ Key = "Device"; Label = "Device"; Type = "text"; Hint = "blank uses auto; example: CUDA0,CUDA1" },
        [pscustomobject]@{ Key = "SplitMode"; Label = "Split Mode"; Type = "choice"; Choices = @("", "layer", "row", "none") },
        [pscustomobject]@{ Key = "TensorSplit"; Label = "Tensor Split"; Type = "text"; Hint = "blank uses auto; example: 3,2" },
        [pscustomobject]@{ Key = "Fit"; Label = "Fit"; Type = "choice"; Choices = @("", "on", "off") },
        [pscustomobject]@{ Key = "ExtraArgs"; Label = "Extra Args"; Type = "text"; Hint = "blank means no extra args" },
        [pscustomobject]@{ Key = "Start"; Label = "Start Launch"; Type = "actionStart" },
        [pscustomobject]@{ Key = "Back"; Label = "Back"; Type = "actionBack" }
    )
}

function Get-LaunchConfigDefaultText {
    param(
        [System.Collections.IDictionary]$Config,
        [string]$Key
    )

    switch ($Key) {
        "OpenPath" {
            if ($Config.LaunchMode -eq "Open Web UI") {
                return "/"
            }

            return "/v1/models"
        }
        "RepeatingLayers" {
            if ($null -ne $Config.ModelRepeatingLayerCount) {
                return "auto, all, or 0-$($Config.ModelRepeatingLayerCount)"
            }

            return "auto, all, or number"
        }
        "AutoTune" { return "off" }
        "Threads" { return "auto -> $([Math]::Max(1, $LogicalThreads - 2))" }
        "ThreadsBatch" { return "auto -> $LogicalThreads" }
        "ContextSize" { return "llama.cpp default" }
        "ApiKey" { return "none" }
        "Device" { return "auto" }
        "SplitMode" { return "llama.cpp default" }
        "TensorSplit" { return "auto" }
        "Fit" { return "llama.cpp default" }
        "ExtraArgs" { return "none" }
        default { return "(default)" }
    }
}

function Get-LaunchConfigValueText {
    param(
        [System.Collections.IDictionary]$Config,
        $Item
    )

    switch ($Item.Key) {
        "Model" { return [string]$Config.ModelName }
        "Metrics" { return $(if ($Config.Metrics) { "On" } else { "Off" }) }
        "ExtremeMode" { return $(if ($Config.ExtremeMode) { "On" } else { "Off" }) }
        "AutoTune" { return $(if ($Config.AutoTune) { "On" } else { "Off" }) }
        "RepeatingLayers" {
            if ([string]::IsNullOrWhiteSpace([string]$Config.RepeatingLayers) -or [string]$Config.RepeatingLayers -eq "auto") {
                return "auto -> derived from GPU Layers"
            }

            if ([string]$Config.RepeatingLayers -eq "all") {
                if ($null -ne $Config.ModelRepeatingLayerCount) {
                    return "all -> $($Config.ModelRepeatingLayerCount)"
                }

                return "all"
            }

            if ($null -ne $Config.ModelRepeatingLayerCount) {
                return "{0} / {1}" -f [string]$Config.RepeatingLayers, [string]$Config.ModelRepeatingLayerCount
            }

            return [string]$Config.RepeatingLayers
        }
        "Threads" {
            if ([string]$Config.Threads -eq "-1") {
                return Get-LaunchConfigDefaultText -Config $Config -Key $Item.Key
            }

            return [string]$Config.Threads
        }
        "ThreadsBatch" {
            if ([string]$Config.ThreadsBatch -eq "-1") {
                return Get-LaunchConfigDefaultText -Config $Config -Key $Item.Key
            }

            return [string]$Config.ThreadsBatch
        }
        "ApiKey" {
            if ([string]::IsNullOrWhiteSpace($Config.ApiKey)) {
                return Get-LaunchConfigDefaultText -Config $Config -Key $Item.Key
            }

            return ("*" * [Math]::Min(12, $Config.ApiKey.Length))
        }
        "SplitMode" {
            if ([string]::IsNullOrWhiteSpace($Config.SplitMode)) {
                return Get-LaunchConfigDefaultText -Config $Config -Key $Item.Key
            }

            return [string]$Config.SplitMode
        }
        "Fit" {
            if ([string]::IsNullOrWhiteSpace($Config.Fit)) {
                return Get-LaunchConfigDefaultText -Config $Config -Key $Item.Key
            }

            return [string]$Config.Fit
        }
        "Start" { return "Launch now" }
        "Back" { return "Return" }
        default {
            $Value = $Config[$Item.Key]
            if ([string]::IsNullOrWhiteSpace([string]$Value)) {
                return Get-LaunchConfigDefaultText -Config $Config -Key $Item.Key
            }

            return [string]$Value
        }
    }
}

function Read-ConfigInput {
    param(
        [string]$Label,
        [string]$CurrentValue,
        [string]$CurrentDisplayValue,
        [string]$Hint
    )

    Write-Host ""
    Write-Host ("Editing {0}" -f $Label) -ForegroundColor Cyan
    if ($Hint) {
        Write-Host ("Hint: {0}" -f $Hint) -ForegroundColor DarkGray
    }
    if ([string]::IsNullOrWhiteSpace($CurrentValue)) {
        Write-Host ("Current: {0}" -f $CurrentDisplayValue) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("Current: {0}" -f $CurrentDisplayValue) -ForegroundColor DarkGray
    }
    $InputText = Read-Host "New value (leave blank to clear)"
    return $InputText
}

function Edit-LaunchConfigItem {
    param(
        [System.Collections.IDictionary]$Config,
        $Item,
        [string]$IndexPath
    )

    switch ($Item.Type) {
        "model" {
            $SelectedModel = Select-ModelEntry -IndexPath $IndexPath -CurrentModelPath $Config.ModelPath
            if ($SelectedModel) {
                $Config.ModelName = $SelectedModel.name
                $Config.ModelPath = Resolve-ModelPath -Path $SelectedModel.path
                $Config.ModelCapabilities = Format-ModelCapabilities -ModelEntry $SelectedModel
                Sync-LaunchConfigGpuFields -Config $Config
            }
        }
        "choice" {
            $Choices = @($Item.Choices)
            $CurrentIndex = [Array]::IndexOf($Choices, [string]$Config[$Item.Key])
            if ($CurrentIndex -lt 0) {
                $CurrentIndex = 0
            }

            $NextIndex = ($CurrentIndex + 1) % $Choices.Count
            $Config[$Item.Key] = $Choices[$NextIndex]

            if ($Item.Key -eq "LaunchMode") {
                if ($Config.LaunchMode -eq "Open Web UI" -and ($Config.OpenPath -eq "/v1/models" -or [string]::IsNullOrWhiteSpace($Config.OpenPath))) {
                    $Config.OpenPath = "/"
                }
                elseif ($Config.LaunchMode -eq "Background Service" -and ($Config.OpenPath -eq "/" -or [string]::IsNullOrWhiteSpace($Config.OpenPath))) {
                    $Config.OpenPath = "/v1/models"
                }
            }
        }
        "bool" {
            $Config[$Item.Key] = -not [bool]$Config[$Item.Key]
        }
        "text" {
            $Hint = if ($Item.Key -eq "RepeatingLayers") {
                Get-LaunchConfigDefaultText -Config $Config -Key $Item.Key
            }
            else {
                $Item.Hint
            }
            $Value = Read-ConfigInput `
                -Label $Item.Label `
                -CurrentValue ([string]$Config[$Item.Key]) `
                -CurrentDisplayValue (Get-LaunchConfigValueText -Config $Config -Item $Item) `
                -Hint $Hint
            if ($Item.Key -eq "GpuLayers") {
                if ($Value -and $Value -notmatch '^(auto|all|\d+)$') {
                    throw "GPU Layers must be auto, all, or a non-negative integer."
                }
                $Config[$Item.Key] = if ([string]::IsNullOrWhiteSpace($Value)) { "auto" } else { $Value }
                Sync-LaunchConfigGpuFields -Config $Config
                return $null
            }
            if ($Item.Key -eq "RepeatingLayers") {
                $Config.GpuLayers = Convert-RepeatingLayersToGpuLayers -RepeatingLayers $Value -RepeatingLayerCount $Config.ModelRepeatingLayerCount
                Sync-LaunchConfigGpuFields -Config $Config
                return $null
            }
            if ($Item.Key -eq "OpenPath" -and $Value -and -not $Value.StartsWith("/")) {
                $Value = "/$Value"
            }
            $Config[$Item.Key] = $Value
        }
        "number" {
            $Value = Read-ConfigInput `
                -Label $Item.Label `
                -CurrentValue ([string]$Config[$Item.Key]) `
                -CurrentDisplayValue (Get-LaunchConfigValueText -Config $Config -Item $Item) `
                -Hint $Item.Hint
            if ($Value -notmatch '^-?\d+$') {
                throw "{0} must be an integer." -f $Item.Label
            }

            switch ($Item.Key) {
                "Port" {
                    if ([int]$Value -lt 1 -or [int]$Value -gt 65535) {
                        throw "Port must be between 1 and 65535."
                    }
                }
                "Threads" {
                    if ([int]$Value -ne -1 -and [int]$Value -lt 1) {
                        throw "Threads must be -1 or a positive integer."
                    }
                }
                "ThreadsBatch" {
                    if ([int]$Value -ne -1 -and [int]$Value -lt 1) {
                        throw "Threads Batch must be -1 or a positive integer."
                    }
                }
                "ReadyTimeoutSec" {
                    if ([int]$Value -lt 1) {
                        throw "Ready Timeout must be a positive integer."
                    }
                }
            }

            $Config[$Item.Key] = [string]$Value
        }
        "numberOrBlank" {
            $Value = Read-ConfigInput `
                -Label $Item.Label `
                -CurrentValue ([string]$Config[$Item.Key]) `
                -CurrentDisplayValue (Get-LaunchConfigValueText -Config $Config -Item $Item) `
                -Hint $Item.Hint
            if ([string]::IsNullOrWhiteSpace($Value)) {
                $Config[$Item.Key] = ""
                return $null
            }

            if ($Value -notmatch '^\d+$' -or [int]$Value -lt 1) {
                throw "{0} must be blank or a positive integer." -f $Item.Label
            }

            $Config[$Item.Key] = [string]$Value
        }
    }

    return $null
}

function Show-LaunchConfigGrid {
    param(
        [System.Collections.IDictionary]$Config,
        [string]$IndexPath
    )

    $Items = Get-LaunchConfigItems
    $SelectedIndex = 0

    while ($true) {
        Show-MenuHeader -Title "Tune And Launch" -Subtitle "Use arrow keys to move. Press Enter or Space to edit the selected cell."
        $Width = Get-ConsoleWidth
        $CellWidth = [Math]::Max(36, [Math]::Floor(($Width - 6) / 2))
        $RowCount = [Math]::Ceiling($Items.Count / 2)

        for ($Row = 0; $Row -lt $RowCount; $Row++) {
            for ($Column = 0; $Column -lt 2; $Column++) {
                $ItemIndex = ($Row * 2) + $Column
                if ($ItemIndex -ge $Items.Count) {
                    continue
                }

                $Item = $Items[$ItemIndex]
                $CellText = "{0}: {1}" -f $Item.Label, (Get-LaunchConfigValueText -Config $Config -Item $Item)
                $DisplayText = " " + (Get-FitText -Text $CellText -Width ($CellWidth - 1)).PadRight($CellWidth - 1)
                $IsSelected = $ItemIndex -eq $SelectedIndex
                $Foreground = if ($IsSelected) { "Black" } else { "Gray" }
                $Background = if ($IsSelected) { "DarkCyan" } else { "Black" }
                Write-Host $DisplayText -NoNewline -ForegroundColor $Foreground -BackgroundColor $Background
                if ($Column -eq 0) {
                    Write-Host "  " -NoNewline
                }
            }
            Write-Host ""
        }

        Write-Host ""
        Write-Host ("Model        : {0}" -f $Config.ModelName) -ForegroundColor Cyan
        Write-Host ("Capabilities : {0}" -f $Config.ModelCapabilities)
        Write-Host ("Model Path   : {0}" -f (Get-FitText -Text $Config.ModelPath -Width ([Math]::Max(40, $Width - 16))))
        Write-Host ""
        Write-Host "Esc returns to the main menu. Start Launch begins with the current settings." -ForegroundColor Yellow

        $Key = Read-ConsoleKey
        switch ($Key.VirtualKeyCode) {
            37 {
                if (($SelectedIndex % 2) -eq 1) {
                    $SelectedIndex--
                }
            }
            39 {
                if (($SelectedIndex % 2) -eq 0 -and ($SelectedIndex + 1) -lt $Items.Count) {
                    $SelectedIndex++
                }
            }
            38 {
                if (($SelectedIndex - 2) -ge 0) {
                    $SelectedIndex -= 2
                }
            }
            40 {
                if (($SelectedIndex + 2) -lt $Items.Count) {
                    $SelectedIndex += 2
                }
            }
            13 {
                $SelectedItem = $Items[$SelectedIndex]
                if ($SelectedItem.Type -eq "actionStart") {
                    return $Config
                }
                if ($SelectedItem.Type -eq "actionBack") {
                    return $null
                }

                try {
                    Edit-LaunchConfigItem -Config $Config -Item $SelectedItem -IndexPath $IndexPath | Out-Null
                }
                catch {
                    Write-Host ""
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
            32 {
                $SelectedItem = $Items[$SelectedIndex]
                if ($SelectedItem.Type -eq "actionStart") {
                    return $Config
                }
                if ($SelectedItem.Type -eq "actionBack") {
                    return $null
                }

                try {
                    Edit-LaunchConfigItem -Config $Config -Item $SelectedItem -IndexPath $IndexPath | Out-Null
                }
                catch {
                    Write-Host ""
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
            27 {
                return $null
            }
        }
    }
}

function Resolve-RequestedThreads {
    param(
        [int]$RequestedThreads,
        [int]$RequestedThreadsBatch
    )

    $ResolvedThreads = if ($RequestedThreads -lt 1) { [Math]::Max(1, $LogicalThreads - 2) } else { $RequestedThreads }
    $ResolvedThreadsBatch = if ($RequestedThreadsBatch -lt 1) { $LogicalThreads } else { $RequestedThreadsBatch }

    return [pscustomobject]@{
        Threads      = $ResolvedThreads
        ThreadsBatch = $ResolvedThreadsBatch
    }
}

function Apply-LaunchSelection {
    param(
        [System.Collections.IDictionary]$Config
    )

    $script:ModelPath = Resolve-ModelPath -Path $Config.ModelPath
    $script:Port = [int]$Config.Port
    $script:GpuLayers = [string]$Config.GpuLayers
    $script:ExtremeMode = [bool]$Config.ExtremeMode
    $script:AutoTune = [bool]$Config.AutoTune
    $script:RawThreads = [int]$Config.Threads
    $script:RawThreadsBatch = [int]$Config.ThreadsBatch
    $script:ReadyTimeoutSec = [int]$Config.ReadyTimeoutSec
    $script:OpenPath = if ($Config.OpenPath) { [string]$Config.OpenPath } else { "/" }
    $script:Background = $true
    $script:NoPause = $true
    $script:NoBrowser = $Config.LaunchMode -eq "Background Service"
    if (-not $script:NoBrowser -and ($script:OpenPath -eq "/v1/models" -or [string]::IsNullOrWhiteSpace($script:OpenPath))) {
        $script:OpenPath = "/"
    }

    $script:LlamaArgs = Convert-MenuConfigToForwardArgs -Config $Config
    $script:BaseUrl = "http://127.0.0.1:$script:Port"
}

function Wait-MenuContinue {
    Write-Host ""
    Write-Host "Press Enter to return to the launcher..." -ForegroundColor Yellow
    Read-Host | Out-Null
}

function Stop-TrackedServer {
    $TrackedProcess = Get-TrackedServerProcess
    if (-not $TrackedProcess) {
        Write-Host "No tracked llama.cpp server is running." -ForegroundColor Yellow
        return
    }

    Stop-Process -Id $TrackedProcess.Id -Force
    $RemainingIds = Wait-ForProcessExit -ProcessIds @([int]$TrackedProcess.Id) -TimeoutSec $ServerCleanupTimeoutSec
    Remove-TrackedPidFiles
    if ($RemainingIds.Count -gt 0) {
        throw "Tracked llama.cpp server is still shutting down: $($RemainingIds -join ', ')"
    }

    if (-not (Wait-ForPortRelease -TimeoutSec $ServerCleanupTimeoutSec)) {
        $Listener = Test-PortInUse
        throw "Port $Port is still in use by PID $($Listener.OwningProcess) after stopping the tracked server."
    }

    Start-Sleep -Milliseconds $ServerCleanupSettleMs
    Write-Host "Stopped llama.cpp server. PID: $($TrackedProcess.Id)" -ForegroundColor Green
}

function Invoke-InteractiveLauncher {
    param(
        [string]$IndexPath
    )

    if (-not (Test-InteractiveConsole)) {
        throw "The interactive launcher needs a real console. Use -BypassMenu for automation or non-interactive runs."
    }

    while ($true) {
        $MainAction = Show-MainLauncherMenu

        switch ($MainAction) {
            "QuickStart" {
                $ModelEntry = Select-ModelEntry -IndexPath $IndexPath -CurrentModelPath $ModelPath
                if (-not $ModelEntry) {
                    continue
                }

                $LaunchMode = Show-LaunchModeMenu
                if (-not $LaunchMode -or $LaunchMode -eq "Back") {
                    continue
                }

                $ForwardConfig = Convert-ForwardArgsToMenuConfig -Arguments $LlamaArgs
                $Config = New-LaunchConfig -ModelEntry $ModelEntry -ForwardConfig $ForwardConfig
                $Config.LaunchMode = $LaunchMode
                if ($LaunchMode -eq "Open Web UI") {
                    $Config.OpenPath = "/"
                }

                Apply-LaunchSelection -Config $Config
                return $true
            }
            "TuneLaunch" {
                $ModelEntry = Select-ModelEntry -IndexPath $IndexPath -CurrentModelPath $ModelPath
                if (-not $ModelEntry) {
                    continue
                }

                $ForwardConfig = Convert-ForwardArgsToMenuConfig -Arguments $LlamaArgs
                $Config = New-LaunchConfig -ModelEntry $ModelEntry -ForwardConfig $ForwardConfig
                if ($Config.LaunchMode -eq "Open Web UI" -and $Config.OpenPath -eq "/v1/models") {
                    $Config.OpenPath = "/"
                }

                $EditedConfig = Show-LaunchConfigGrid -Config $Config -IndexPath $IndexPath
                if (-not $EditedConfig) {
                    continue
                }

                Apply-LaunchSelection -Config $EditedConfig
                return $true
            }
            "Status" {
                Show-MenuHeader -Title "Server Status" -Subtitle "Current tracked server state."
                Show-ServerStatus
                Wait-MenuContinue
            }
            "Stop" {
                Show-MenuHeader -Title "Stop Running Server" -Subtitle "Stopping the tracked llama.cpp server if one exists."
                Stop-TrackedServer
                Wait-MenuContinue
            }
            "Help" {
                Clear-Host
                & $ServerExe --help
                Wait-MenuContinue
            }
            "Exit" {
                return $false
            }
            default {
                return $false
            }
        }
    }
}

function Get-TrackedPidFileCandidates {
    return @(
        $PidFile
        $LegacyPidFile
    ) | Select-Object -Unique
}

function Remove-TrackedPidFiles {
    foreach ($CandidatePath in @(Get-TrackedPidFileCandidates)) {
        Remove-Item -LiteralPath $CandidatePath -ErrorAction SilentlyContinue
    }
}

function Get-TrackedServerRecord {
    foreach ($CandidatePath in @(Get-TrackedPidFileCandidates)) {
        if (-not (Test-Path -LiteralPath $CandidatePath)) {
            continue
        }

        $PidText = ((Get-Content -LiteralPath $CandidatePath -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        if ($PidText -notmatch '^\d+$') {
            Remove-Item -LiteralPath $CandidatePath -ErrorAction SilentlyContinue
            continue
        }

        $Process = Get-Process -Id ([int]$PidText) -ErrorAction SilentlyContinue
        if (-not $Process) {
            Remove-Item -LiteralPath $CandidatePath -ErrorAction SilentlyContinue
            continue
        }

        try {
            $MatchesServerPath = $false
            foreach ($CandidateExe in $ServerExeCandidates) {
                if ([string]::Equals($Process.Path, $CandidateExe, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $MatchesServerPath = $true
                    break
                }
            }

            if (-not $MatchesServerPath) {
                continue
            }
        }
        catch {
            continue
        }

        return [pscustomobject]@{
            Process     = $Process
            PidFilePath = $CandidatePath
        }
    }

    return $null
}

function Get-TrackedPidFilePath {
    $TrackedRecord = Get-TrackedServerRecord
    if ($TrackedRecord) {
        return [string]$TrackedRecord.PidFilePath
    }

    return $null
}

function Get-TrackedLogPaths {
    $TrackedPidFilePath = Get-TrackedPidFilePath
    $PreferLegacyPaths = -not [string]::IsNullOrWhiteSpace($TrackedPidFilePath) -and [string]::Equals($TrackedPidFilePath, $LegacyPidFile, [System.StringComparison]::OrdinalIgnoreCase)

    $ResolveLogPath = {
        param(
            [string]$PreferredPath,
            [string]$LegacyPath
        )

        if ($PreferLegacyPaths) {
            if (Test-Path -LiteralPath $LegacyPath) {
                return $LegacyPath
            }

            return $PreferredPath
        }

        if (Test-Path -LiteralPath $PreferredPath) {
            return $PreferredPath
        }

        if (Test-Path -LiteralPath $LegacyPath) {
            return $LegacyPath
        }

        return $PreferredPath
    }

    return [pscustomobject]@{
        StdOutLog = & $ResolveLogPath $StdOutLog $LegacyStdOutLog
        StdErrLog = & $ResolveLogPath $StdErrLog $LegacyStdErrLog
    }
}

function Get-TrackedServerProcess {
    $TrackedRecord = Get-TrackedServerRecord
    if ($TrackedRecord) {
        return $TrackedRecord.Process
    }

    return $null
}

function Get-TrackedServerModelPath {
    param(
        [System.Diagnostics.Process]$Process
    )

    if (-not $Process) {
        return $null
    }

    try {
        $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
        if (-not $ProcessInfo -or [string]::IsNullOrWhiteSpace($ProcessInfo.CommandLine)) {
            return $null
        }

        $Match = [regex]::Match($ProcessInfo.CommandLine, '(?:^|\s)-m\s+(?:"([^"]+)"|(\S+))')
        if (-not $Match.Success) {
            return $null
        }

        $TrackedModelPath = if ($Match.Groups[1].Success) {
            $Match.Groups[1].Value
        }
        else {
            $Match.Groups[2].Value
        }

        return Resolve-ModelPath -Path $TrackedModelPath
    }
    catch {
        return $null
    }
}

function Get-TrackedServerLaunchSettings {
    param(
        [System.Diagnostics.Process]$Process
    )

    if (-not $Process) {
        return $null
    }

    try {
        $ProcessInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
        if (-not $ProcessInfo -or [string]::IsNullOrWhiteSpace($ProcessInfo.CommandLine)) {
            return $null
        }

        $Tokens = @(Split-ArgumentLine -Line $ProcessInfo.CommandLine)
        $Arguments = if ($Tokens.Count -gt 1) { @($Tokens[1..($Tokens.Count - 1)]) } else { @() }
        $Settings = [ordered]@{
            CommandLine      = [string]$ProcessInfo.CommandLine
            ModelPath        = ""
            Port             = ""
            ContextSize      = ""
            Host             = ""
            GpuLayers        = ""
            Threads          = ""
            ThreadsBatch     = ""
            ParallelSlots    = ""
            FitTarget        = ""
            CacheRam         = ""
            Metrics          = $false
            ApiKey           = $false
            Device           = ""
            SplitMode        = ""
            TensorSplit      = ""
            Temperature      = ""
            TopK             = ""
            TopP             = ""
            MinP             = ""
            PresencePenalty  = ""
            FrequencyPenalty = ""
            RepeatPenalty    = ""
            RepeatLastN      = ""
            Seed             = ""
            Stream           = $null
            ExtraArgs        = ""
        }
        $Remaining = New-Object System.Collections.Generic.List[string]

        for ($Index = 0; $Index -lt $Arguments.Count; $Index++) {
            $Argument = $Arguments[$Index]

            switch -Regex ($Argument) {
                '^(?:-m|--model)(?:=(.+))?$' {
                    $Settings.ModelPath = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--port(?:=(.+))?$' {
                    $Settings.Port = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--ctx-size(?:=(.+))?$' {
                    $Settings.ContextSize = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--host(?:=(.+))?$' {
                    $Settings.Host = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^(?:--gpu-layers|--n-gpu-layers|-ngl)(?:=(.+))?$' {
                    $Settings.GpuLayers = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--threads(?:=(.+))?$' {
                    $Settings.Threads = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--threads-batch(?:=(.+))?$' {
                    $Settings.ThreadsBatch = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--parallel(?:=(.+))?$' {
                    $Settings.ParallelSlots = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--fit-target(?:=(.+))?$' {
                    $Settings.FitTarget = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--cache-ram(?:=(.+))?$' {
                    $Settings.CacheRam = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--device(?:=(.+))?$' {
                    $Settings.Device = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--split-mode(?:=(.+))?$' {
                    $Settings.SplitMode = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--tensor-split(?:=(.+))?$' {
                    $Settings.TensorSplit = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--temp(?:erature)?(?:=(.+))?$' {
                    $Settings.Temperature = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--top-k(?:=(.+))?$' {
                    $Settings.TopK = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--top-p(?:=(.+))?$' {
                    $Settings.TopP = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--min-p(?:=(.+))?$' {
                    $Settings.MinP = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--presence-penalty(?:=(.+))?$' {
                    $Settings.PresencePenalty = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--frequency-penalty(?:=(.+))?$' {
                    $Settings.FrequencyPenalty = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--repeat-penalty(?:=(.+))?$' {
                    $Settings.RepeatPenalty = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--repeat-last-n(?:=(.+))?$' {
                    $Settings.RepeatLastN = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--seed(?:=(.+))?$' {
                    $Settings.Seed = if ($Matches[1]) { $Matches[1] } elseif (($Index + 1) -lt $Arguments.Count) { $Arguments[++$Index] } else { "" }
                }
                '^--stream$' {
                    $Settings.Stream = $true
                }
                '^--no-stream$' {
                    $Settings.Stream = $false
                }
                '^--metrics$' {
                    $Settings.Metrics = $true
                }
                '^--api-key(?:=(.+))?$' {
                    $Settings.ApiKey = $true
                    if (-not $Matches[1] -and (($Index + 1) -lt $Arguments.Count)) {
                        $null = $Arguments[++$Index]
                    }
                }
                default {
                    $Remaining.Add($Argument)
                }
            }
        }

        $Settings.ExtraArgs = ($Remaining -join " ")
        return [pscustomobject]$Settings
    }
    catch {
        return $null
    }
}

function Get-TrackedServerRuntimeProperties {
    param(
        [string]$ServerBaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($ServerBaseUrl)) {
        return $null
    }

    try {
        return Invoke-RestMethod -Uri "$ServerBaseUrl/props" -TimeoutSec 3
    }
    catch {
        return $null
    }
}

function Format-TrackedServerScalarValue {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool]) {
        return $(if ($Value) { "on" } else { "off" })
    }

    if ($Value -is [float] -or $Value -is [double] -or $Value -is [decimal]) {
        $Rounded = [Math]::Round([double]$Value, 6)
        return $Rounded.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {
        return [string]$Value
    }

    $Text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return $Text
}

function Get-TrackedServerGenerationSettings {
    param(
        $TrackedSettings,
        $RuntimeProperties
    )

    $RuntimeParams = $null
    try {
        if ($RuntimeProperties -and $RuntimeProperties.default_generation_settings -and $RuntimeProperties.default_generation_settings.params) {
            $RuntimeParams = $RuntimeProperties.default_generation_settings.params
        }
    }
    catch {
    }

    $ResolveValue = {
        param(
            [string]$RuntimeName,
            [string]$TrackedName
        )

        if ($RuntimeParams -and $RuntimeParams.PSObject.Properties[$RuntimeName]) {
            return $RuntimeParams.$RuntimeName
        }

        if ($TrackedSettings -and $TrackedSettings.PSObject.Properties[$TrackedName]) {
            return $TrackedSettings.$TrackedName
        }

        return $null
    }

    $SamplerChain = $null
    if ($RuntimeParams -and $RuntimeParams.PSObject.Properties["samplers"] -and $RuntimeParams.samplers) {
        $SamplerChain = (@($RuntimeParams.samplers) | ForEach-Object { [string]$_ }) -join " -> "
    }

    return [pscustomobject]@{
        Temperature      = (& $ResolveValue "temperature" "Temperature")
        TopK             = (& $ResolveValue "top_k" "TopK")
        TopP             = (& $ResolveValue "top_p" "TopP")
        MinP             = (& $ResolveValue "min_p" "MinP")
        PresencePenalty  = (& $ResolveValue "presence_penalty" "PresencePenalty")
        FrequencyPenalty = (& $ResolveValue "frequency_penalty" "FrequencyPenalty")
        RepeatPenalty    = (& $ResolveValue "repeat_penalty" "RepeatPenalty")
        RepeatLastN      = (& $ResolveValue "repeat_last_n" "RepeatLastN")
        Seed             = (& $ResolveValue "seed" "Seed")
        Stream           = (& $ResolveValue "stream" "Stream")
        SamplerChain     = $SamplerChain
    }
}

function Format-TrackedServerContextValue {
    param(
        $TrackedSettings,
        $RuntimeProperties
    )

    $ExplicitContextSize = if ($TrackedSettings) { [string]$TrackedSettings.ContextSize } else { "" }
    $RuntimeContextSize = ""

    try {
        if ($RuntimeProperties -and $RuntimeProperties.default_generation_settings -and $RuntimeProperties.default_generation_settings.n_ctx) {
            $RuntimeContextSize = [string]$RuntimeProperties.default_generation_settings.n_ctx
        }
    }
    catch {
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitContextSize)) {
        return $ExplicitContextSize
    }

    if (-not [string]::IsNullOrWhiteSpace($RuntimeContextSize)) {
        return "$RuntimeContextSize (server default)"
    }

    return "server default"
}

function Format-TrackedServerGpuValue {
    param(
        $TrackedSettings,
        $GpuOffloadInfo
    )

    $RequestedGpuLayers = if ($TrackedSettings -and -not [string]::IsNullOrWhiteSpace([string]$TrackedSettings.GpuLayers)) {
        [string]$TrackedSettings.GpuLayers
    }
    elseif ($GpuOffloadInfo -and -not [string]::IsNullOrWhiteSpace([string]$GpuOffloadInfo.RequestedGpuLayers)) {
        [string]$GpuOffloadInfo.RequestedGpuLayers
    }
    else {
        "auto / not set"
    }

    $Details = New-Object System.Collections.Generic.List[string]

    if ($GpuOffloadInfo -and $null -ne $GpuOffloadInfo.OffloadedLayers -and $null -ne $GpuOffloadInfo.TotalLayers) {
        $Details.Add(("{0}/{1} layers to GPU" -f $GpuOffloadInfo.OffloadedLayers, $GpuOffloadInfo.TotalLayers))
    }

    if ($GpuOffloadInfo -and $null -ne $GpuOffloadInfo.RepeatingLayers) {
        $Details.Add(("repeat {0}" -f $GpuOffloadInfo.RepeatingLayers))
    }

    if ($Details.Count -gt 0) {
        return "{0} (requested {1})" -f ($Details -join ", "), $RequestedGpuLayers
    }

    return $RequestedGpuLayers
}

function Format-TrackedServerSlotsValue {
    param(
        $TrackedSettings,
        $RuntimeProperties
    )

    $ExplicitSlots = if ($TrackedSettings) { [string]$TrackedSettings.ParallelSlots } else { "" }
    $RuntimeSlots = ""

    try {
        if ($RuntimeProperties -and $RuntimeProperties.total_slots) {
            $RuntimeSlots = [string]$RuntimeProperties.total_slots
        }
    }
    catch {
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSlots)) {
        if (-not [string]::IsNullOrWhiteSpace($RuntimeSlots) -and $RuntimeSlots -ne $ExplicitSlots) {
            return "$RuntimeSlots active request slots (requested $ExplicitSlots via --parallel)"
        }

        return "$ExplicitSlots active request slots (--parallel)"
    }

    if (-not [string]::IsNullOrWhiteSpace($RuntimeSlots)) {
        return "$RuntimeSlots active request slots (server default)"
    }

    return $null
}

function Format-TrackedServerBufferValue {
    param(
        $GpuOffloadInfo
    )

    if (-not $GpuOffloadInfo) {
        return $null
    }

    $Parts = New-Object System.Collections.Generic.List[string]

    if ($null -ne $GpuOffloadInfo.GpuModelBufferTotalMiB) {
        $Parts.Add(("GPU model buffers {0:N2} MiB total" -f [double]$GpuOffloadInfo.GpuModelBufferTotalMiB))
    }
    elseif ($null -ne $GpuOffloadInfo.GpuModelBufferMiB) {
        $Parts.Add(("GPU model buffer {0:N2} MiB" -f [double]$GpuOffloadInfo.GpuModelBufferMiB))
    }

    if ($null -ne $GpuOffloadInfo.CpuMappedModelBufferMiB) {
        $Parts.Add(("CPU-mapped {0:N2} MiB" -f [double]$GpuOffloadInfo.CpuMappedModelBufferMiB))
    }

    if ($Parts.Count -eq 0) {
        return $null
    }

    return ($Parts -join " + ")
}

function Format-TrackedServerSettingValue {
    param(
        [AllowEmptyString()]
        [string]$Value,

        [string]$WhenMissing = "not set"
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $WhenMissing
    }

    return $Value
}

function Wait-ForProcessExit {
    param(
        [int[]]$ProcessIds,
        [int]$TimeoutSec = $ServerCleanupTimeoutSec
    )

    $RemainingIds = @(
        $ProcessIds |
            Where-Object { $_ -gt 0 } |
            Select-Object -Unique
    )

    if ($RemainingIds.Count -eq 0) {
        return @()
    }

    $Deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($RemainingIds.Count -gt 0 -and (Get-Date) -lt $Deadline) {
        $RemainingIds = @(
            $RemainingIds |
                Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
        )

        if ($RemainingIds.Count -eq 0) {
            break
        }

        Start-Sleep -Milliseconds 500
    }

    return @(
        $RemainingIds |
            Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
    )
}

function Get-WorkspaceServerProcesses {
    param(
        [string]$TargetModelPath = $null
    )

    $ServerPathPatterns = @($ServerExeCandidates | ForEach-Object { [regex]::Escape($_) })
    $TargetModelPattern = if (-not [string]::IsNullOrWhiteSpace($TargetModelPath)) {
        [regex]::Escape($TargetModelPath)
    }
    else {
        $null
    }

    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $WorkspaceProcess = $_
                $MatchesExecutablePath = $false
                foreach ($CandidateExe in $ServerExeCandidates) {
                    if ($WorkspaceProcess.ExecutablePath -and [string]::Equals($WorkspaceProcess.ExecutablePath, $CandidateExe, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $MatchesExecutablePath = $true
                        break
                    }
                }

                $MatchesCommandLine = $false
                if ($WorkspaceProcess.CommandLine) {
                    foreach ($PathPattern in $ServerPathPatterns) {
                        if ($WorkspaceProcess.CommandLine -match $PathPattern) {
                            $MatchesCommandLine = $true
                            break
                        }
                    }
                }

                $MatchesTargetModel = $true
                if ($TargetModelPattern) {
                    $MatchesTargetModel = $WorkspaceProcess.CommandLine -and ($WorkspaceProcess.CommandLine -match $TargetModelPattern)
                }

                ($MatchesExecutablePath -or $MatchesCommandLine) -and $MatchesTargetModel
            }
    )
}

function Stop-WorkspaceServerProcesses {
    $TrackedProcess = Get-TrackedServerProcess
    $TrackedModelPath = Get-TrackedServerModelPath -Process $TrackedProcess
    $WorkspaceServerProcesses = @(Get-WorkspaceServerProcesses)

    if (-not $WorkspaceServerProcesses) {
        Remove-TrackedPidFiles
        return [pscustomobject]@{
            HadRunningServer = $false
            PreviousModelPath = $TrackedModelPath
            UnloadedAt = $null
        }
    }

    $TargetIds = @(
        $WorkspaceServerProcesses |
            ForEach-Object { [int]$_.ProcessId } |
            Select-Object -Unique
    )
    $StoppedIds = New-Object System.Collections.Generic.List[int]
    foreach ($WorkspaceServerProcess in $WorkspaceServerProcesses) {
        try {
            Stop-Process -Id $WorkspaceServerProcess.ProcessId -Force -ErrorAction Stop
            $StoppedIds.Add([int]$WorkspaceServerProcess.ProcessId)
        }
        catch {
        }
    }

    Remove-TrackedPidFiles

    if ($StoppedIds.Count -gt 0) {
        Write-Host "Cleaned old llama.cpp server process(es): $($StoppedIds -join ', ')" -ForegroundColor Yellow
    }

    $RemainingIds = Wait-ForProcessExit -ProcessIds $TargetIds -TimeoutSec $ServerCleanupTimeoutSec
    if ($RemainingIds.Count -gt 0) {
        throw "Some old llama.cpp server process(es) did not exit cleanly: $($RemainingIds -join ', ')"
    }

    $UnloadedAt = Get-Date

    if (-not (Wait-ForPortRelease -TimeoutSec $ServerCleanupTimeoutSec)) {
        $Listener = Test-PortInUse
        throw "Port $Port is still in use by PID $($Listener.OwningProcess) after cleaning old llama.cpp processes."
    }

    if ($TargetIds.Count -gt 0) {
        Start-Sleep -Milliseconds $ServerCleanupSettleMs
    }

    return [pscustomobject]@{
        HadRunningServer = [bool]($TargetIds.Count -gt 0)
        PreviousModelPath = $TrackedModelPath
        UnloadedAt = $UnloadedAt
    }
}

function Reset-BackgroundServerLogs {
    foreach ($LogPath in @($StdOutLog, $StdErrLog)) {
        try {
            if (Test-Path -LiteralPath $LogPath) {
                Remove-Item -LiteralPath $LogPath -Force -ErrorAction Stop
            }

            [void](New-Item -ItemType File -Path $LogPath -Force)
            Set-Content -LiteralPath $LogPath -Value "" -Encoding ASCII
        }
        catch {
            throw "Could not reset background log file: $LogPath. Make sure no old llama-server.exe process is still using it."
        }
    }
}

function Test-PortInUse {
    $Listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    return $Listener
}

function Get-ListeningWorkspaceServerProcess {
    param(
        [string]$TargetModelPath = $null
    )

    $Listener = Test-PortInUse
    if (-not $Listener) {
        return $null
    }

    $WorkspaceServerProcesses = @(Get-WorkspaceServerProcesses -TargetModelPath $TargetModelPath)
    foreach ($WorkspaceServerProcess in $WorkspaceServerProcesses) {
        if ([int]$WorkspaceServerProcess.ProcessId -eq [int]$Listener.OwningProcess) {
            return $WorkspaceServerProcess
        }
    }

    return $null
}

function Get-BackgroundServerCandidate {
    param(
        [int[]]$BaselineProcessIds = @(),
        [Nullable[int]]$ExpectedLaunchPid = $null,
        [string]$TargetModelPath = $null
    )

    $WorkspaceServerProcesses = @(Get-WorkspaceServerProcesses -TargetModelPath $TargetModelPath)
    if ($WorkspaceServerProcesses.Count -eq 0) {
        return $null
    }

    $ListeningProcess = Get-ListeningWorkspaceServerProcess -TargetModelPath $TargetModelPath
    if ($ListeningProcess) {
        return $ListeningProcess
    }

    if ($ExpectedLaunchPid -and $ExpectedLaunchPid.Value -gt 0) {
        foreach ($WorkspaceServerProcess in $WorkspaceServerProcesses) {
            if ([int]$WorkspaceServerProcess.ProcessId -eq $ExpectedLaunchPid.Value) {
                return $WorkspaceServerProcess
            }
        }
    }

    foreach ($WorkspaceServerProcess in $WorkspaceServerProcesses) {
        if ($BaselineProcessIds -notcontains ([int]$WorkspaceServerProcess.ProcessId)) {
            return $WorkspaceServerProcess
        }
    }

    return $WorkspaceServerProcesses | Select-Object -First 1
}

function Wait-ForPortRelease {
    param(
        [int]$TimeoutSec = $ServerCleanupTimeoutSec
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $Deadline) {
        if (-not (Test-PortInUse)) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    return (-not (Test-PortInUse))
}

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$LineCount = $StartupFailureLogLineCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $Lines = @(Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction SilentlyContinue)
    if ($Lines.Count -eq 0) {
        return $null
    }

    return ($Lines -join [Environment]::NewLine).Trim()
}

function Test-StartupLogsCaptured {
    return (-not [string]::IsNullOrWhiteSpace((Get-LogTailText -Path $StdErrLog))) -or (-not [string]::IsNullOrWhiteSpace((Get-LogTailText -Path $StdOutLog)))
}

function Get-BackgroundStartupProgressInfo {
    param(
        [string]$LogPath,
        [switch]$ServerReady
    )

    $Info = [ordered]@{
        DiskState         = "waiting"
        DiskDetail        = $null
        MemoryState       = "waiting"
        MemoryDetail      = $null
        GpuState          = "waiting"
        GpuDetail         = $null
        ServiceState      = "waiting"
        ServiceDetail     = $null
        HasServerListening = $false
    }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        if ($ServerReady) {
            $Info.DiskState = "done"
            $Info.MemoryState = "done"
            $Info.GpuState = "skipped"
            $Info.ServiceState = "done"
        }

        return [pscustomobject]$Info
    }

    $LogText = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($LogText)) {
        if ($ServerReady) {
            $Info.DiskState = "done"
            $Info.MemoryState = "done"
            $Info.GpuState = "skipped"
            $Info.ServiceState = "done"
        }

        return [pscustomobject]$Info
    }

    $HasMetadata = $LogText -match 'llama_model_loader:\s+loaded meta data with'
    $HasTensorLoad = $LogText -match 'load_tensors:\s+loading model tensors'
    $CpuMappedMatches = [regex]::Matches($LogText, 'load_tensors:\s+CPU_Mapped model buffer size =\s+([0-9.]+)\s+MiB')
    $CpuMappedModelBufferMiB = if ($CpuMappedMatches.Count -gt 0) { [double]$CpuMappedMatches[$CpuMappedMatches.Count - 1].Groups[1].Value } else { $null }
    $HasContextConstruction = $LogText -match 'llama_context:\s+constructing llama_context'
    $HasKvCache = $LogText -match 'llama_kv_cache:'
    $HasWarmup = $LogText -match 'common_init_from_params:\s+warming up'
    $HasSlotInitialization = $LogText -match 'srv\s+load_model:'
    $HasModelLoaded = $LogText -match 'main:\s+model loaded'
    $HasServerListening = $LogText -match 'main:\s+server is listening on '
    $Info.HasServerListening = $HasServerListening

    $GpuBufferMatches = [regex]::Matches($LogText, 'load_tensors:\s+(?!CPU(?:_Mapped)?)(?<device>[A-Za-z0-9_]+)\s+model buffer size =\s+(?<size>[0-9.]+)\s+MiB')
    $OffloadingMatches = [regex]::Matches($LogText, 'load_tensors:\s+offloading\s+(\d+)\s+repeating layers to GPU')
    $OffloadedMatches = [regex]::Matches($LogText, 'load_tensors:\s+offloaded\s+(\d+)/(\d+)\s+layers to GPU')
    $HasGpuActivity = ($GpuBufferMatches.Count -gt 0) -or ($OffloadingMatches.Count -gt 0) -or ($OffloadedMatches.Count -gt 0)

    if ($HasMetadata -or $HasTensorLoad) {
        $Info.DiskState = "loading"
    }
    if ($null -ne $CpuMappedModelBufferMiB) {
        $Info.DiskState = "done"
        $Info.DiskDetail = ("{0:N2} MiB mapped" -f $CpuMappedModelBufferMiB)
    }
    elseif ($HasContextConstruction -or $HasWarmup -or $HasModelLoaded -or $HasServerListening -or $ServerReady) {
        $Info.DiskState = "done"
    }

    if ($null -ne $CpuMappedModelBufferMiB) {
        $Info.MemoryState = "loading"
        $Info.MemoryDetail = ("{0:N2} MiB mapped" -f $CpuMappedModelBufferMiB)
    }
    if ($HasContextConstruction -or $HasKvCache -or $HasWarmup -or $HasModelLoaded -or $HasServerListening -or $ServerReady) {
        $Info.MemoryState = "done"
    }

    if ($HasGpuActivity) {
        $Info.GpuState = "loading"

        if ($GpuBufferMatches.Count -gt 0) {
            $TotalGpuModelBufferMiB = 0.0
            foreach ($GpuBufferMatch in $GpuBufferMatches) {
                $TotalGpuModelBufferMiB += [double]$GpuBufferMatch.Groups["size"].Value
            }

            $Info.GpuDetail = ("{0:N2} MiB buffers" -f $TotalGpuModelBufferMiB)
        }

        if ($OffloadingMatches.Count -gt 0) {
            $Info.GpuDetail = ("repeat {0} layers" -f [int]$OffloadingMatches[$OffloadingMatches.Count - 1].Groups[1].Value)
        }

        if ($OffloadedMatches.Count -gt 0) {
            $Info.GpuState = "done"
            $Info.GpuDetail = ("{0}/{1} layers" -f [int]$OffloadedMatches[$OffloadedMatches.Count - 1].Groups[1].Value, [int]$OffloadedMatches[$OffloadedMatches.Count - 1].Groups[2].Value)
        }
        elseif ($HasModelLoaded -or $HasServerListening -or $ServerReady) {
            $Info.GpuState = "done"
        }
    }
    elseif ($HasModelLoaded -or $HasServerListening -or $ServerReady) {
        $Info.GpuState = "skipped"
    }

    if ($HasWarmup -or $HasSlotInitialization -or $HasModelLoaded) {
        $Info.ServiceState = "loading"
    }
    if ($HasWarmup) {
        $Info.ServiceDetail = "warmup"
    }
    elseif ($HasSlotInitialization) {
        $Info.ServiceDetail = "initializing slots"
    }
    elseif ($HasModelLoaded) {
        $Info.ServiceDetail = "binding HTTP listener"
    }

    if ($HasServerListening -or $ServerReady) {
        $Info.ServiceState = "done"
        $Info.ServiceDetail = "ready"
    }

    if ($ServerReady) {
        if ($Info.DiskState -eq "waiting") {
            $Info.DiskState = "done"
        }
        if ($Info.MemoryState -eq "waiting") {
            $Info.MemoryState = "done"
        }
        if ($Info.GpuState -eq "waiting") {
            $Info.GpuState = "skipped"
        }
    }

    return [pscustomobject]$Info
}

function Format-BackgroundStartupStageSegment {
    param(
        [string]$Label,
        [string]$State,
        [string]$Detail = $null
    )

    $StateText = switch ($State) {
        "done" { "done" }
        "loading" { "loading" }
        "skipped" { "skipped" }
        default { "waiting" }
    }

    $Segment = "{0}:{1}" -f $Label, $StateText
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $Segment += " ({0})" -f $Detail
    }

    return $Segment
}

function Format-BackgroundStartupProgressLine {
    param(
        [psobject]$ProgressInfo,
        [int]$Tick,
        [switch]$Ready
    )

    $SpinnerFrames = @("|", "/", "-", "\")
    $Prefix = if ($Ready) { "Ready     " } else { "Loading {0}" -f $SpinnerFrames[$Tick % $SpinnerFrames.Count] }
    $Segments = @(
        (Format-BackgroundStartupStageSegment -Label "Disk" -State $ProgressInfo.DiskState -Detail $ProgressInfo.DiskDetail),
        (Format-BackgroundStartupStageSegment -Label "RAM" -State $ProgressInfo.MemoryState -Detail $ProgressInfo.MemoryDetail),
        (Format-BackgroundStartupStageSegment -Label "GPU" -State $ProgressInfo.GpuState -Detail $ProgressInfo.GpuDetail),
        (Format-BackgroundStartupStageSegment -Label "Server" -State $ProgressInfo.ServiceState -Detail $ProgressInfo.ServiceDetail)
    )

    return "{0}  {1}" -f $Prefix, ($Segments -join " | ")
}

function Write-BackgroundStartupProgressLine {
    param(
        [string]$Text,
        [switch]$Complete
    )

    if (-not (Test-InteractiveConsole)) {
        if ($Complete -or $Text -ne $script:BackgroundStartupProgressLastText) {
            Write-Host $Text
            $script:BackgroundStartupProgressLastText = $Text
        }
        return
    }

    $DisplayText = Get-FitText -Text $Text -Width ([Math]::Max(40, (Get-ConsoleWidth) - 1))
    $PaddingLength = [Math]::Max(0, $script:BackgroundStartupProgressLineLength - $DisplayText.Length)
    $PaddedText = $DisplayText + (" " * $PaddingLength)

    Write-Host ("`r{0}" -f $PaddedText) -NoNewline
    $script:BackgroundStartupProgressLineLength = [Math]::Max($script:BackgroundStartupProgressLineLength, $DisplayText.Length)
    $script:BackgroundStartupProgressLastText = $DisplayText

    if ($Complete) {
        Write-Host ""
        $script:BackgroundStartupProgressLineLength = 0
        $script:BackgroundStartupProgressLastText = $null
    }
}

function Wait-ForBackgroundServerReadyWithProgress {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ServerBaseUrl,
        [int[]]$BaselineProcessIds = @(),
        [string]$TargetModelPath = $null,
        [int]$TimeoutSec = 0
    )

    $ExpectedLaunchPid = [Nullable[int]]$null
    if ($Process) {
        try {
            $ExpectedLaunchPid = [Nullable[int]]$Process.Id
        }
        catch {
        }
    }

    $Deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { $null }
    $Tick = 0

    while ($true) {
        $CandidateProcess = Get-BackgroundServerCandidate -BaselineProcessIds $BaselineProcessIds -ExpectedLaunchPid $ExpectedLaunchPid -TargetModelPath $TargetModelPath
        $ProgressInfo = Get-BackgroundStartupProgressInfo -LogPath $StdErrLog
        $ShouldCheckReady = $ProgressInfo.HasServerListening -or ($Tick -eq 0) -or (($Tick % 5) -eq 0)
        $ServerReady = $false

        if ($ShouldCheckReady) {
            $ServerReady = Test-ServerReady -ServerBaseUrl $ServerBaseUrl
        }

        if ($ServerReady) {
            $ProgressInfo = Get-BackgroundStartupProgressInfo -LogPath $StdErrLog -ServerReady
            Write-BackgroundStartupProgressLine -Text (Format-BackgroundStartupProgressLine -ProgressInfo $ProgressInfo -Tick $Tick -Ready) -Complete
            return [pscustomobject]@{
                State     = "Ready"
                ProcessId = if ($CandidateProcess) { [int]$CandidateProcess.ProcessId } elseif ($ExpectedLaunchPid) { $ExpectedLaunchPid.Value } else { $null }
            }
        }

        Write-BackgroundStartupProgressLine -Text (Format-BackgroundStartupProgressLine -ProgressInfo $ProgressInfo -Tick $Tick)

        try {
            $Process.Refresh()
        }
        catch {
        }

        if (($Process -and $Process.HasExited) -and -not $CandidateProcess) {
            Write-BackgroundStartupProgressLine -Text (Format-BackgroundStartupProgressLine -ProgressInfo $ProgressInfo -Tick $Tick) -Complete

            $FailureLog = Get-LogTailText -Path $StdErrLog
            if (-not $FailureLog) {
                $FailureLog = Get-LogTailText -Path $StdOutLog
            }

            if (-not $FailureLog) {
                $FailureLog = "No startup log output was captured."
            }

            Remove-TrackedPidFiles
            throw "llama.cpp exited during model startup (PID $($Process.Id)). Last log lines:`n$FailureLog"
        }

        if ($Deadline -and (Get-Date) -ge $Deadline) {
            Write-BackgroundStartupProgressLine -Text (Format-BackgroundStartupProgressLine -ProgressInfo $ProgressInfo -Tick $Tick) -Complete
            return [pscustomobject]@{
                State     = "Loading"
                ProcessId = if ($CandidateProcess) { [int]$CandidateProcess.ProcessId } elseif ($ExpectedLaunchPid) { $ExpectedLaunchPid.Value } else { $null }
            }
        }

        Start-Sleep -Milliseconds $BackgroundStartupPollMs
        $Tick++
    }
}

function Test-ServerReady {
    param(
        [string]$ServerBaseUrl
    )

    $ReadyUrls = @(
        "$ServerBaseUrl/health",
        "$ServerBaseUrl/v1/models"
    )

    foreach ($ReadyUrl in $ReadyUrls) {
        try {
            $Response = Invoke-WebRequest -Uri $ReadyUrl -UseBasicParsing -TimeoutSec 5
            if ($Response.StatusCode -ge 200 -and $Response.StatusCode -lt 300) {
                return $true
            }
        }
        catch {
        }
    }

    return $false
}

function Wait-ForServerReady {
    param(
        [string]$ServerBaseUrl,
        [int]$TimeoutSec
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $Deadline) {
        if (Test-ServerReady -ServerBaseUrl $ServerBaseUrl) {
            return $true
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

function Wait-ForBackgroundServerStartup {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ServerBaseUrl,
        [int]$TimeoutSec = $BackgroundStartupCheckSec,
        [int[]]$BaselineProcessIds = @(),
        [string]$TargetModelPath = $null
    )

    $ExpectedLaunchPid = [Nullable[int]]$null
    if ($Process) {
        try {
            $ExpectedLaunchPid = [Nullable[int]]$Process.Id
        }
        catch {
        }
    }

    $ObservedExitedProcess = $false
    $ObservedExitCodeLabel = "unknown"
    $Deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $Deadline) {
        $CandidateProcess = Get-BackgroundServerCandidate -BaselineProcessIds $BaselineProcessIds -ExpectedLaunchPid $ExpectedLaunchPid -TargetModelPath $TargetModelPath

        if (Test-ServerReady -ServerBaseUrl $ServerBaseUrl) {
            return [pscustomobject]@{
                State     = "Ready"
                ProcessId = if ($CandidateProcess) { [int]$CandidateProcess.ProcessId } elseif ($ExpectedLaunchPid) { $ExpectedLaunchPid.Value } else { $null }
            }
        }

        try {
            $Process.Refresh()
        }
        catch {
        }

        if ($Process.HasExited) {
            $ObservedExitedProcess = $true
            try {
                $ObservedExitCodeLabel = [string]$Process.ExitCode
            }
            catch {
            }
        }

        Start-Sleep -Milliseconds $BackgroundStartupPollMs
    }

    $CandidateProcess = Get-BackgroundServerCandidate -BaselineProcessIds $BaselineProcessIds -ExpectedLaunchPid $ExpectedLaunchPid -TargetModelPath $TargetModelPath
    if ($CandidateProcess) {
        return [pscustomobject]@{
            State     = "Loading"
            ProcessId = [int]$CandidateProcess.ProcessId
        }
    }

    if ($ObservedExitedProcess) {
        $FailureLog = Get-LogTailText -Path $StdErrLog
        if (-not $FailureLog) {
            $FailureLog = Get-LogTailText -Path $StdOutLog
        }

        if (-not $FailureLog) {
            $FailureLog = "No startup log output was captured."
        }

        Remove-TrackedPidFiles
        throw "llama.cpp exited during model startup (PID $($Process.Id), exit code $ObservedExitCodeLabel). Last log lines:`n$FailureLog"
    }

    return [pscustomobject]@{
        State     = "Loading"
        ProcessId = if ($ExpectedLaunchPid) { $ExpectedLaunchPid.Value } else { $null }
    }
}

function Open-BrowserWhenReady {
    if ($NoBrowser) {
        return
    }

    if (Wait-ForServerReady -ServerBaseUrl $BaseUrl -TimeoutSec $ReadyTimeoutSec) {
        Start-Process "$BaseUrl$OpenPath"
    }
    else {
        Write-Host "Server started, but browser auto-open timed out after $ReadyTimeoutSec seconds." -ForegroundColor Yellow
    }
}

function Start-BrowserWhenReadyDetached {
    if ($NoBrowser) {
        return
    }

    $PowerShellExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($PowerShellExe) -or -not (Test-Path -LiteralPath $PowerShellExe)) {
        Open-BrowserWhenReady
        return
    }

    $EncodedBaseUrl = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($BaseUrl))
    $EncodedOpenPath = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($OpenPath))
    $ReadyScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$ServerBaseUrl = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$EncodedBaseUrl'))
`$BrowserPath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$EncodedOpenPath'))
`$Deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
`$ReadyUrls = @(
    "`$ServerBaseUrl/health",
    "`$ServerBaseUrl/v1/models"
)

while ((Get-Date) -lt `$Deadline) {
    foreach (`$ReadyUrl in `$ReadyUrls) {
        try {
            `$Response = Invoke-WebRequest -Uri `$ReadyUrl -UseBasicParsing -TimeoutSec 5
            if (`$Response.StatusCode -ge 200 -and `$Response.StatusCode -lt 300) {
                Start-Process -FilePath ("`$ServerBaseUrl`$BrowserPath")
                exit 0
            }
        }
        catch {
        }
    }

    Start-Sleep -Seconds 2
}
"@

    $EncodedReadyScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ReadyScript))
    Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList @("-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $EncodedReadyScript) `
        -WindowStyle Hidden | Out-Null
}

function Show-ServerStatus {
    $TrackedProcess = Get-TrackedServerProcess
    $Listener = Test-PortInUse

    if ($TrackedProcess) {
        $TrackedSettings = Get-TrackedServerLaunchSettings -Process $TrackedProcess
        $TrackedLogPaths = Get-TrackedLogPaths
        $TrackedModelPath = Get-TrackedServerModelPath -Process $TrackedProcess
        if (-not $TrackedModelPath -and $TrackedSettings -and -not [string]::IsNullOrWhiteSpace($TrackedSettings.ModelPath)) {
            $TrackedModelPath = Resolve-ModelPath -Path $TrackedSettings.ModelPath
        }
        $TrackedPort = if ($TrackedSettings -and $TrackedSettings.Port -match '^\d+$') { [int]$TrackedSettings.Port } else { $Port }
        $TrackedBaseUrl = "http://127.0.0.1:$TrackedPort"
        $TrackedRuntimeProperties = Get-TrackedServerRuntimeProperties -ServerBaseUrl $TrackedBaseUrl
        $TrackedGpuOffloadInfo = Get-GpuOffloadInfo
        Write-Host "Status : running" -ForegroundColor Green
        Write-Host "PID    : $($TrackedProcess.Id)"
        Write-Host "URL    : $TrackedBaseUrl"
        Write-Host "Port   : $TrackedPort"
        Write-Host "Server : $ServerExe"
        if ($TrackedModelPath) {
            Write-Host "Model  : $TrackedModelPath"
        }
        if ($TrackedRuntimeProperties -and -not [string]::IsNullOrWhiteSpace([string]$TrackedRuntimeProperties.model_alias)) {
            Write-Host "Alias  : $($TrackedRuntimeProperties.model_alias) (runtime model alias)"
        }
        if ($TrackedSettings) {
            $GenerationSettings = Get-TrackedServerGenerationSettings -TrackedSettings $TrackedSettings -RuntimeProperties $TrackedRuntimeProperties
            Write-Host "Ctx    : $(Format-TrackedServerContextValue -TrackedSettings $TrackedSettings -RuntimeProperties $TrackedRuntimeProperties)"
            Write-Host "GPU    : $(Format-TrackedServerGpuValue -TrackedSettings $TrackedSettings -GpuOffloadInfo $TrackedGpuOffloadInfo)"
            if ($TrackedGpuOffloadInfo) {
                $BufferSummary = Format-TrackedServerBufferValue -GpuOffloadInfo $TrackedGpuOffloadInfo
                if (-not [string]::IsNullOrWhiteSpace($BufferSummary)) {
                    Write-Host "Buffer : $BufferSummary"
                }
            }
            Write-Host "Threads: $(Format-TrackedServerSettingValue -Value $TrackedSettings.Threads -WhenMissing 'server default') CPU threads for token generation (--threads)"
            Write-Host "Batch  : $(Format-TrackedServerSettingValue -Value $TrackedSettings.ThreadsBatch -WhenMissing 'server default') CPU threads for batch/prefill (--threads-batch)"
            if (-not [string]::IsNullOrWhiteSpace($TrackedSettings.Host)) {
                Write-Host "Host   : $($TrackedSettings.Host) bind address (--host)"
            }
            $SlotsSummary = Format-TrackedServerSlotsValue -TrackedSettings $TrackedSettings -RuntimeProperties $TrackedRuntimeProperties
            if (-not [string]::IsNullOrWhiteSpace($SlotsSummary)) {
                Write-Host "Slots  : $SlotsSummary"
            }
            if (-not [string]::IsNullOrWhiteSpace($TrackedSettings.FitTarget)) {
                Write-Host "Fit    : $($TrackedSettings.FitTarget) MiB target free-VRAM margin (--fit-target)"
            }
            if (-not [string]::IsNullOrWhiteSpace($TrackedSettings.CacheRam)) {
                Write-Host "Cache  : $($TrackedSettings.CacheRam) MiB prompt cache RAM limit (--cache-ram)"
            }
            if (-not [string]::IsNullOrWhiteSpace($TrackedSettings.Device)) {
                Write-Host "Device : $($TrackedSettings.Device) target accelerator selection (--device)"
            }
            if (-not [string]::IsNullOrWhiteSpace($TrackedSettings.SplitMode)) {
                Write-Host "Split  : $($TrackedSettings.SplitMode) multi-GPU split mode (--split-mode)"
            }
            if (-not [string]::IsNullOrWhiteSpace($TrackedSettings.TensorSplit)) {
                Write-Host "Tensor : $($TrackedSettings.TensorSplit) tensor distribution (--tensor-split)"
            }
            Write-Host "Metrics: $(if ($TrackedSettings.Metrics) { 'on' } else { 'off' }) (Prometheus /metrics endpoint)"
            if ($TrackedSettings.ApiKey) {
                Write-Host "API Key: set (request authentication enabled)"
            }
            $SamplingParts = New-Object System.Collections.Generic.List[string]
            $TemperatureText = Format-TrackedServerScalarValue -Value $GenerationSettings.Temperature
            if (-not [string]::IsNullOrWhiteSpace($TemperatureText)) {
                $SamplingParts.Add("temp $TemperatureText")
            }
            $TopKText = Format-TrackedServerScalarValue -Value $GenerationSettings.TopK
            if (-not [string]::IsNullOrWhiteSpace($TopKText)) {
                $SamplingParts.Add("top-k $TopKText")
            }
            $TopPText = Format-TrackedServerScalarValue -Value $GenerationSettings.TopP
            if (-not [string]::IsNullOrWhiteSpace($TopPText)) {
                $SamplingParts.Add("top-p $TopPText")
            }
            $MinPText = Format-TrackedServerScalarValue -Value $GenerationSettings.MinP
            if (-not [string]::IsNullOrWhiteSpace($MinPText)) {
                $SamplingParts.Add("min-p $MinPText")
            }
            if ($SamplingParts.Count -gt 0) {
                Write-Host "Sample : $($SamplingParts -join ' | ')"
            }

            $PenaltyParts = New-Object System.Collections.Generic.List[string]
            $PresencePenaltyText = Format-TrackedServerScalarValue -Value $GenerationSettings.PresencePenalty
            if (-not [string]::IsNullOrWhiteSpace($PresencePenaltyText)) {
                $PenaltyParts.Add("presence $PresencePenaltyText")
            }
            $FrequencyPenaltyText = Format-TrackedServerScalarValue -Value $GenerationSettings.FrequencyPenalty
            if (-not [string]::IsNullOrWhiteSpace($FrequencyPenaltyText)) {
                $PenaltyParts.Add("frequency $FrequencyPenaltyText")
            }
            $RepeatPenaltyText = Format-TrackedServerScalarValue -Value $GenerationSettings.RepeatPenalty
            if (-not [string]::IsNullOrWhiteSpace($RepeatPenaltyText)) {
                $RepeatLastNText = Format-TrackedServerScalarValue -Value $GenerationSettings.RepeatLastN
                if (-not [string]::IsNullOrWhiteSpace($RepeatLastNText)) {
                    $PenaltyParts.Add("repeat $RepeatPenaltyText over last $RepeatLastNText tokens")
                }
                else {
                    $PenaltyParts.Add("repeat $RepeatPenaltyText")
                }
            }
            if ($PenaltyParts.Count -gt 0) {
                Write-Host "Penalty: $($PenaltyParts -join ' | ')"
            }

            $SeedText = Format-TrackedServerScalarValue -Value $GenerationSettings.Seed
            if (-not [string]::IsNullOrWhiteSpace($SeedText)) {
                Write-Host "Seed   : $SeedText RNG seed"
            }

            $StreamText = Format-TrackedServerScalarValue -Value $GenerationSettings.Stream
            if (-not [string]::IsNullOrWhiteSpace($StreamText)) {
                Write-Host "Stream : $StreamText token streaming"
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$GenerationSettings.SamplerChain)) {
                Write-Host "Sampler: $($GenerationSettings.SamplerChain)"
            }
            if (-not [string]::IsNullOrWhiteSpace($TrackedSettings.ExtraArgs)) {
                Write-Host "Extra  : $($TrackedSettings.ExtraArgs)"
            }
        }
        if ($TrackedRuntimeProperties) {
            Write-Host "Web UI : $(if ($TrackedRuntimeProperties.webui) { 'on' } else { 'off' }) (built-in browser UI)"
            Write-Host "State  : $(if ($TrackedRuntimeProperties.is_sleeping) { 'sleeping' } else { 'awake' })"
            if (-not [string]::IsNullOrWhiteSpace([string]$TrackedRuntimeProperties.build_info)) {
                Write-Host "Build  : $($TrackedRuntimeProperties.build_info) (llama.cpp build)"
            }
        }
        Write-Host "Logs   : $($TrackedLogPaths.StdOutLog)"
        Write-Host "Error  : $($TrackedLogPaths.StdErrLog)"
        return
    }

    if ($Listener) {
        Write-Host "Status : port in use by PID $($Listener.OwningProcess), but not tracked by this script." -ForegroundColor Yellow
        Write-Host "Port   : $Port"
        return
    }

    Write-Host "Status : stopped" -ForegroundColor Yellow
}

$PendingSwitchTimingContext = $null
$PendingSwitchTimingLaunchPid = [Nullable[int]]$null
$SwitchTimingCompleted = $false

try {
    $ModelIndexPath = Resolve-ScriptRelativePath -Path $ModelIndexPath
    if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
        $ModelPath = Resolve-ModelPath -Path $ModelPath
    }
    Initialize-JsonWorkspaceFiles -IndexPath $ModelIndexPath
    Test-LlamaArgConflict -Arguments $LlamaArgs

    if (-not (Test-Path -LiteralPath $ServerExe)) {
        throw "Cannot find llama-server.exe: $ServerExe. Put llama.cpp binaries in '$PreferredBinRoot'."
    }

    if ($LlamaHelp) {
        & $ServerExe --help
        return
    }

    if ($Status) {
        Show-ServerStatus
        return
    }

    if ($ShowGpuOffload) {
        Write-Host "Note   : -ShowGpuOffload now routes to the richer -Status view." -ForegroundColor Yellow
        Show-ServerStatus
        return
    }

    if ($Stop) {
        Stop-TrackedServer
        return
    }

    if (-not $BypassMenu) {
        [void](Refresh-ModelIndexFromDefaultScanPath -Path $ModelIndexPath -PrimaryModelPath $ModelPath)
        $UsedInteractiveMenu = $true
        $LaunchRequested = Invoke-InteractiveLauncher -IndexPath $ModelIndexPath
        if (-not $LaunchRequested) {
            return
        }
    }

    if ($GpuLayers -notmatch '^(auto|all|\d+)$') {
        throw "GpuLayers must be auto, all, or a non-negative integer."
    }

    $ModelPath = Resolve-LaunchModelPath -IndexPath $ModelIndexPath -RequestedModelPath $ModelPath

    $ResolvedThreads = Resolve-RequestedThreads -RequestedThreads $RawThreads -RequestedThreadsBatch $RawThreadsBatch
    $Threads = $ResolvedThreads.Threads
    $ThreadsBatch = $ResolvedThreads.ThreadsBatch
    $BaseUrl = "http://127.0.0.1:$Port"

    Write-Host "Checking files..." -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $ModelPath)) {
        throw "Cannot find model file: $ModelPath"
    }

    $ServerStopInfo = Stop-WorkspaceServerProcesses
    $SwitchTimingContext = if ($ServerStopInfo -and $ServerStopInfo.UnloadedAt) {
        New-ModelSwitchTimingContext -PreviousModelPath $ServerStopInfo.PreviousModelPath -TargetModelPath $ModelPath -SwitchStartedAt $ServerStopInfo.UnloadedAt
    }
    else {
        $null
    }

    $Listener = Test-PortInUse
    if ($Listener) {
        throw "Port $Port is already in use by PID $($Listener.OwningProcess)."
    }

    $AutoLaunchTuning = Get-AutoLaunchTuning -ResolvedModelPath $ModelPath -RequestedGpuLayers $GpuLayers -Arguments $LlamaArgs -UseExtremeMode $ExtremeMode -EnableAutoTune $AutoTune

    Write-Host "Starting llama.cpp server..." -ForegroundColor Green
    Write-Host "Server : $ServerExe"
    Write-Host "Model  : $ModelPath"
    Write-Host "Port   : $Port"
    Write-Host "Mode   : $(if ($ExtremeMode) { 'extreme' } else { 'standard' })"
    Write-Host "Tune   : $($AutoLaunchTuning.SourceLabel)"
    if ($AutoLaunchTuning.AutoTuneEnabled) {
        Write-Host "Learn  : on"
    }
    if ($AutoLaunchTuning.Source -eq "adaptive" -and -not [string]::IsNullOrWhiteSpace($AutoLaunchTuning.ProfileSkipReason)) {
        Write-Host "Saved  : skipped for this run ($($AutoLaunchTuning.ProfileSkipReason))" -ForegroundColor Yellow
    }
    if ($AutoLaunchTuning.UseManagedGpuLayers) {
        Write-Host "GPU    : auto (wrapper-managed fit)"
    }
    else {
        Write-Host "GPU    : $($AutoLaunchTuning.EffectiveGpuLayers)"
    }
    Write-Host "Threads: $Threads"
    Write-Host "Batch  : $ThreadsBatch"
    if ($AutoLaunchTuning.AcceleratorInfo) {
        Write-Host "VRAM   : $($AutoLaunchTuning.AcceleratorInfo.Name) free $($AutoLaunchTuning.AcceleratorInfo.FreeMiB) MiB / total $($AutoLaunchTuning.AcceleratorInfo.TotalMiB) MiB"
    }
    if ($AutoLaunchTuning.MemoryInfo) {
        Write-Host "RAM    : free $($AutoLaunchTuning.MemoryInfo.FreeMiB) MiB / total $($AutoLaunchTuning.MemoryInfo.TotalMiB) MiB"
    }
    if ($null -ne $AutoLaunchTuning.FitTargetMiB) {
        Write-Host "Fit    : target margin $($AutoLaunchTuning.FitTargetMiB) MiB"
    }
    if ($null -ne $AutoLaunchTuning.CacheRamMiB) {
        Write-Host "Cache  : prompt cache limit $($AutoLaunchTuning.CacheRamMiB) MiB"
    }
    if ($null -ne $AutoLaunchTuning.ParallelSlots) {
        Write-Host "Slots  : $($AutoLaunchTuning.ParallelSlots)"
    }
    if ($LlamaArgs) {
        Write-Host "Extra  : $($LlamaArgs -join ' ')"
    }
    Write-Host "Open   : $BaseUrl$OpenPath"
    Write-Host ""

    $ServerArgs = Get-ServerArgs -AutoTuning $AutoLaunchTuning

    if ($Background) {
        $ArgumentString = ConvertTo-ArgumentString -Arguments $ServerArgs
        $StartupCheckSec = [Math]::Min($BackgroundStartupCheckSec, [Math]::Max(10, $ReadyTimeoutSec))
        $BaselineWorkspaceServerIds = @(
            Get-WorkspaceServerProcesses |
                ForEach-Object { [int]$_.ProcessId } |
                Select-Object -Unique
        )
        $BackgroundProcess = $null
        $TrackedBackgroundPid = $null
        $BackgroundAttemptCount = 0
        $LastBackgroundStartupError = $null

        while ($BackgroundAttemptCount -lt 2) {
            $BackgroundAttemptCount++
            Reset-BackgroundServerLogs
            $BackgroundProcess = Start-Process `
                -FilePath $ServerExe `
                -ArgumentList $ArgumentString `
                -WorkingDirectory $ScriptRoot `
                -RedirectStandardOutput $StdOutLog `
                -RedirectStandardError $StdErrLog `
                -WindowStyle Hidden `
                -PassThru

            Set-Content -LiteralPath $PidFile -Value $BackgroundProcess.Id -Encoding ASCII
            if ($SwitchTimingContext) {
                Set-ModelSwitchTimingPending -TargetModelPath $SwitchTimingContext.TargetModelPath -PreviousModelPath $SwitchTimingContext.PreviousModelPath -StartedAt $SwitchTimingContext.SwitchStartedAt -LaunchPid $BackgroundProcess.Id | Out-Null
                $PendingSwitchTimingContext = $SwitchTimingContext
                $PendingSwitchTimingLaunchPid = [Nullable[int]]$BackgroundProcess.Id
            }

            try {
                if ($WrapperControlsPause) {
                    Write-Host "Waiting for the server to finish loading..." -ForegroundColor Cyan
                    $StartupResult = Wait-ForBackgroundServerReadyWithProgress -Process $BackgroundProcess -ServerBaseUrl $BaseUrl -BaselineProcessIds $BaselineWorkspaceServerIds -TargetModelPath $ModelPath
                }
                else {
                    $StartupResult = Wait-ForBackgroundServerStartup -Process $BackgroundProcess -ServerBaseUrl $BaseUrl -TimeoutSec $StartupCheckSec -BaselineProcessIds $BaselineWorkspaceServerIds -TargetModelPath $ModelPath
                }

                $StartupState = $StartupResult.State
                $TrackedBackgroundPid = $StartupResult.ProcessId
                if ($TrackedBackgroundPid) {
                    Set-Content -LiteralPath $PidFile -Value $TrackedBackgroundPid -Encoding ASCII
                }
                $LastBackgroundStartupError = $null
                break
            }
            catch {
                $LastBackgroundStartupError = $_.Exception
                $HasStartupLogs = Test-StartupLogsCaptured
                $RetryBackgroundStart = ($BackgroundAttemptCount -lt 2) -and (-not $HasStartupLogs)
                if (-not $RetryBackgroundStart) {
                    throw
                }

                Write-Host "Background start exited before any logs were captured. Retrying once..." -ForegroundColor Yellow
                Remove-TrackedPidFiles
                Start-Sleep -Seconds 2
            }
        }

        if ($LastBackgroundStartupError) {
            throw $LastBackgroundStartupError
        }

        $AutoTuneSaveResult = $null

        if ($AutoLaunchTuning.AutoTuneEnabled -and $StartupState -ne "Ready") {
            $RemainingReadyWaitSec = [Math]::Max(1, $ReadyTimeoutSec - $StartupCheckSec)
            Write-Host "AutoTune: waiting for the server to finish loading before evaluating the learned profile..." -ForegroundColor Cyan
            if (Wait-ForServerReady -ServerBaseUrl $BaseUrl -TimeoutSec $RemainingReadyWaitSec) {
                $StartupState = "Ready"
            }
            else {
                $AutoTuneSaveResult = [pscustomobject]@{
                    Saved   = $false
                    Message = "Auto-tune could not save a profile because the server was not ready within $ReadyTimeoutSec seconds."
                    Profile = $null
                }
            }
        }

        if ($AutoLaunchTuning.AutoTuneEnabled -and $StartupState -eq "Ready" -and -not $AutoTuneSaveResult) {
            $ObservedUsage = Get-ObservedGpuUsage -LogPath $StdErrLog -AcceleratorInventory $AutoLaunchTuning.AcceleratorInventory
            $AutoTuneSaveResult = Save-AutoTuneProfile -AutoTuning $AutoLaunchTuning -ObservedUsage $ObservedUsage
        }

        if ($SwitchTimingContext) {
            if ($StartupState -eq "Ready") {
                $CompletedLaunchPid = if ($TrackedBackgroundPid) { [int]$TrackedBackgroundPid } else { $BackgroundProcess.Id }
                Complete-ModelSwitchTimingMeasurement -TargetModelPath $SwitchTimingContext.TargetModelPath -PreviousModelPath $SwitchTimingContext.PreviousModelPath -StartedAt $SwitchTimingContext.SwitchStartedAt -CompletedAt (Get-Date) -LaunchPid $CompletedLaunchPid | Out-Null
                $SwitchTimingCompleted = $true
                $PendingSwitchTimingContext = $null
                $PendingSwitchTimingLaunchPid = [Nullable[int]]$null
            }
            else {
                $ExpectedLaunchPid = if ($TrackedBackgroundPid) { [int]$TrackedBackgroundPid } else { $BackgroundProcess.Id }
                Start-ModelSwitchTimingRecorderDetached -TargetModelPath $SwitchTimingContext.TargetModelPath -PreviousModelPath $SwitchTimingContext.PreviousModelPath -StartedAt $SwitchTimingContext.SwitchStartedAt -ServerBaseUrl $BaseUrl -TimeoutSec ([Math]::Max($ReadyTimeoutSec, 600)) -ExpectedLaunchPid $ExpectedLaunchPid -TrackingPidFile $PidFile
            }
        }

        Write-Host "Background server started." -ForegroundColor Green
        Write-Host "PID    : $(if ($TrackedBackgroundPid) { $TrackedBackgroundPid } else { $BackgroundProcess.Id })"
        Write-Host "State  : $(if ($StartupState -eq 'Ready') { 'ready' } else { "loading (process alive after $StartupCheckSec seconds)" })"
        Write-Host "URL    : $BaseUrl"
        Write-Host "Logs   : $StdOutLog"
        Write-Host "Error  : $StdErrLog"
        if ($AutoLaunchTuning.Source -eq "saved-profile") {
            Write-Host "Saved  : reused learned profile from $TuningProfileFile" -ForegroundColor Cyan
        }
        if ($AutoTuneSaveResult) {
            if ($AutoTuneSaveResult.Saved) {
                Write-Host "AutoTune: $($AutoTuneSaveResult.Message)" -ForegroundColor Green
            }
            elseif (-not [string]::IsNullOrWhiteSpace($AutoTuneSaveResult.Message)) {
                Write-Host "AutoTune: $($AutoTuneSaveResult.Message)" -ForegroundColor Yellow
            }
        }
        if (-not $NoBrowser) {
            if ($StartupState -eq "Ready") {
                Write-Host "Browser: server is ready. Opening the Web UI now." -ForegroundColor Cyan
                Start-Process "$BaseUrl$OpenPath"
            }
            else {
                Write-Host "Browser: the Web UI will open automatically when the server is ready." -ForegroundColor Cyan
                Start-BrowserWhenReadyDetached
            }
        }
        if ($WrapperControlsPause) {
            Write-Host "Server is ready. Closing the launcher window..." -ForegroundColor Cyan
        }
        else {
            Write-Host "You can close this PowerShell window." -ForegroundColor Cyan
        }
        return
    }

    if (-not $NoBrowser) {
        $BrowserJob = Start-Job -ScriptBlock {
            param(
                [string]$ServerBaseUrl,
                [string]$BrowserPath,
                [int]$TimeoutSec
            )

            $Deadline = (Get-Date).AddSeconds($TimeoutSec)
            $ReadyUrls = @(
                "$ServerBaseUrl/health",
                "$ServerBaseUrl/v1/models"
            )

            while ((Get-Date) -lt $Deadline) {
                foreach ($ReadyUrl in $ReadyUrls) {
                    try {
                        $Response = Invoke-WebRequest -Uri $ReadyUrl -UseBasicParsing -TimeoutSec 5
                        if ($Response.StatusCode -ge 200 -and $Response.StatusCode -lt 300) {
                            Start-Process "$ServerBaseUrl$BrowserPath"
                            return
                        }
                    }
                    catch {
                    }
                }

                Start-Sleep -Seconds 2
            }
        } -ArgumentList $BaseUrl, $OpenPath, $ReadyTimeoutSec
    }

    if ($SwitchTimingContext) {
        Set-ModelSwitchTimingPending -TargetModelPath $SwitchTimingContext.TargetModelPath -PreviousModelPath $SwitchTimingContext.PreviousModelPath -StartedAt $SwitchTimingContext.SwitchStartedAt | Out-Null
        $PendingSwitchTimingContext = $SwitchTimingContext
        Start-ModelSwitchTimingRecorderDetached -TargetModelPath $SwitchTimingContext.TargetModelPath -PreviousModelPath $SwitchTimingContext.PreviousModelPath -StartedAt $SwitchTimingContext.SwitchStartedAt -ServerBaseUrl $BaseUrl -TimeoutSec ([Math]::Max($ReadyTimeoutSec, 600))
    }

    & $ServerExe @ServerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "llama.cpp exited with code $LASTEXITCODE."
    }
}
catch {
    $EncounteredFatalError = $true
    if ($PendingSwitchTimingContext -and -not $SwitchTimingCompleted) {
        Clear-ModelSwitchTimingPending -TargetModelPath $PendingSwitchTimingContext.TargetModelPath -LaunchPid $PendingSwitchTimingLaunchPid
    }
    Write-Host ""
    Write-Host "Error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    if ($BrowserJob) {
        if ($BrowserJob.State -eq "Running") {
            Stop-Job -Job $BrowserJob -Force | Out-Null
        }

        Remove-Job -Job $BrowserJob -Force -ErrorAction SilentlyContinue
    }

    $ShouldPause = (-not $NoPause) -and (-not $WrapperControlsPause) -and (-not $Status) -and (-not $ShowGpuOffload) -and (-not $Stop) -and (-not $LlamaHelp) -and ($EncounteredFatalError -or ((-not $Background) -and (-not $UsedInteractiveMenu)))
    if ($ShouldPause) {
        Write-Host ""
        Write-Host "Press Enter to exit..." -ForegroundColor Yellow
        Read-Host | Out-Null
    }

    if ($EncounteredFatalError -and $ReturnNonZeroOnError) {
        exit 1
    }
}
