$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'PS1\Start_LCPP.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

foreach ($name in @('Get-SmartVramFitTargets', 'Get-SmartVramOomRetryAdjustment', 'Get-SmartVramBalanceAdjustment', 'Get-FittedGpuLayerCount')) {
    $definition = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message (expected '$Expected', got '$Actual')"
    }
}

$inventory = @(
    [pscustomobject]@{ Id = 'CUDA1'; FreeMiB = 15997; TotalMiB = 16303 },
    [pscustomobject]@{ Id = 'CUDA0'; FreeMiB = 15039; TotalMiB = 16303 }
)
$targets = @(Get-SmartVramFitTargets -SelectedInventory $inventory -BaseFitTargetMiB 256 -FixedPrimaryMiB 1108)
Assert-Equal '1364,256' ($targets -join ',') 'Primary fixed allocations must become fit headroom'

$plan = [pscustomobject]@{
    UsesFitManagedSplit = $true
    Devices             = @('CUDA1', 'CUDA0')
    FitTargetsMiB       = [int[]]@(1364, 256)
}
$log = @'
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 884.62 MiB on device 0: cudaMalloc failed: out of memory
alloc_tensor_range: failed to allocate CUDA0 buffer of size 927588992
'@
$retry = Get-SmartVramOomRetryAdjustment -Plan $plan -FailureLog $log
Assert-Equal 'CUDA0' $retry.FailedDevice 'OOM retry must identify the physical failed device'
Assert-Equal '885' $retry.RequiredMiB 'OOM retry must recover the failed allocation size'
Assert-Equal '1364,1397' $retry.FitTarget 'OOM retry must increase only the failed device reserve'

$unrelated = Get-SmartVramOomRetryAdjustment -Plan $plan -FailureLog 'server exited: invalid model metadata'
if ($null -ne $unrelated) { throw 'Non-OOM failures must not trigger Smart VRAM retries' }

$truncated = Get-SmartVramOomRetryAdjustment -Plan $plan -FailureLog 'GGML_ASSERT(buffer) failed'
Assert-Equal 'CUDA0' $truncated.FailedDevice 'Truncated allocator failures must choose the least-protected device'
Assert-Equal '1364,1280' $truncated.FitTarget 'Truncated allocator failures must add conservative fallback headroom'

$balancePlan = [pscustomobject]@{
    Devices     = @('CUDA1', 'CUDA0')
    TensorSplit = '48,52'
}
$balanceInventory = @(
    [pscustomobject]@{ Id = 'CUDA0'; FreeMiB = 304 },
    [pscustomobject]@{ Id = 'CUDA1'; FreeMiB = 3986 }
)
$balance = Get-SmartVramBalanceAdjustment -Plan $balancePlan -AcceleratorInventory $balanceInventory -ModelSizeMiB 22082.29
Assert-Equal 'CUDA0' $balance.LowDevice 'Balance correction must move tensors away from the fuller device'
Assert-Equal 'CUDA1' $balance.HighDevice 'Balance correction must move tensors toward the emptier device'
Assert-Equal '56.34,43.66' $balance.TensorSplit 'Balance correction must derive the split from measured free VRAM'

$fitted = Get-FittedGpuLayerCount -LogText 'load_tensors: offloaded 57/65 layers to GPU'
Assert-Equal '57' $fitted.GpuLayers 'Smart balancing must preserve the layer count selected by fit'
Assert-Equal '65' $fitted.TotalLayers 'Smart balancing must parse the total layer count'

$source = Get-Content -Raw -LiteralPath $sourcePath
if ($source -notmatch '\(-not \$AutoTuning\.SmartVramPlan\.UsesFitManagedSplit\).*--tensor-split') {
    throw 'Managed Smart VRAM launches must not emit a fixed tensor split'
}
if ($source -notmatch 'function Write-RuntimeOwnerState' -or $source -notmatch 'Write-RuntimeOwnerState -ServerPid') {
    throw 'Successful background launches must persist runtime ownership'
}
$statusFunction = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ServerStatus'
    }, $true) | Select-Object -First 1
if (-not $statusFunction -or $statusFunction.Extent.Text -match 'Invoke-WorkspaceRuntimeGuard') {
    throw 'Server status inspection must not invoke the destructive runtime guard'
}

Write-Host 'Smart VRAM tests passed.'
