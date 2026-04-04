<#
.SYNOPSIS
Builds and installs the latest official llama.cpp for this launcher workspace.

.DESCRIPTION
Downloads the latest source archive from the official ggml-org/llama.cpp repository,
builds it with CMake on Windows, copies the resulting binaries into the local bin folder,
and can optionally register the existing autostart scheduled task.

.PARAMETER Source
Selects which official upstream source to build.
LatestRelease downloads the current GitHub "latest release".
Master downloads the current master branch snapshot.

.PARAMETER Ref
Optional explicit upstream ref to build, such as a tag or branch name.
When supplied, Ref overrides Source.

.PARAMETER Backend
Choose CPU, CUDA, Vulkan, or Auto.
Auto prefers CUDA when a CUDA toolkit is detected, then Vulkan when a Vulkan SDK/runtime
is detected, and otherwise falls back to CPU.

.PARAMETER Platform
Target Windows architecture for Visual Studio generators. Default is x64.

.PARAMETER Generator
Optional CMake generator override.
When omitted, the script uses "Visual Studio 17 2022" if it is installed.

.PARAMETER Jobs
Optional parallel build count passed to CMake with --parallel.
Use 0 to let CMake decide.

.PARAMETER InstallAutostart
After a successful build/install, also register the Windows scheduled task by calling
Install_LCPP_Autostart.ps1.

.PARAMETER TriggerMode
Trigger mode passed to Install_LCPP_Autostart.ps1 when InstallAutostart is used.

.PARAMETER RunAutostartNow
When InstallAutostart is also specified, start the scheduled task once after installing it.

.PARAMETER SkipBackup
Do not back up the existing bin folder contents before replacing runtime files.

.PARAMETER SkipStop
Do not stop the currently tracked llama.cpp server before replacing binaries.

.PARAMETER NoCudaRuntimeCopy
When building with CUDA, do not copy CUDA runtime DLLs from the locally installed toolkit.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet("LatestRelease", "Master")]
    [string]$Source = "LatestRelease",

    [string]$Ref = $null,

    [ValidateSet("Auto", "CPU", "CUDA", "Vulkan")]
    [string]$Backend = "Auto",

    [ValidateSet("x64", "arm64")]
    [string]$Platform = "x64",

    [string]$Generator = $null,

    [ValidateRange(0, 256)]
    [int]$Jobs = 0,

    [switch]$InstallAutostart,

    [ValidateSet("Startup", "Logon")]
    [string]$TriggerMode = "Startup",

    [switch]$RunAutostartNow,

    [switch]$SkipBackup,

    [switch]$SkipStop,

    [switch]$NoCudaRuntimeCopy
)

$ErrorActionPreference = "Stop"

trap {
    Write-Host ""
    Write-Host "Install failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

if ([enum]::IsDefined([Net.SecurityProtocolType], "Tls12")) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$ScriptHome = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = if ([string]::Equals([System.IO.Path]::GetFileName($ScriptHome), "PS1", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $ScriptHome
}
else {
    $ScriptHome
}
$Ps1Root = $ScriptHome
$BinRoot = Join-Path $ProjectRoot "bin"
$BackupRoot = Join-Path $ProjectRoot "backup"
$ManagedRoot = Join-Path $ProjectRoot ".cache\llama.cpp-install"
$DownloadRoot = Join-Path $ManagedRoot "downloads"
$SourceRoot = Join-Path $ManagedRoot "source"
$BuildRoot = Join-Path $ManagedRoot "build"
$LauncherScript = Join-Path $ProjectRoot "PS1\Start_LCPP.ps1"
$AutostartScript = Join-Path $ProjectRoot "PS1\Install_LCPP_Autostart.ps1"
$PowerShellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path -LiteralPath $LauncherScript)) {
    $LauncherScript = Join-Path $ProjectRoot "Start_LCPP.ps1"
}
if (-not (Test-Path -LiteralPath $AutostartScript)) {
    $AutostartScript = Join-Path $ProjectRoot "Install_LCPP_Autostart.ps1"
}
if (-not (Test-Path -LiteralPath $PowerShellExe)) {
    $PowerShellExe = "powershell.exe"
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

function Get-FullPathSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-ManagedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $ResolvedRoot = Get-FullPathSafe -Path $Root
    $ResolvedPath = Get-FullPathSafe -Path $Path
    if (-not $ResolvedPath.StartsWith($ResolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside managed workspace: $ResolvedPath"
    }
}

function Clear-ManagedDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    Assert-ManagedPath -Path $Path -Root $Root
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    [void](New-Item -ItemType Directory -Path $Path -Force)
}

function Get-GitHubHeaders {
    return @{
        "Accept"     = "application/vnd.github+json"
        "User-Agent" = "easy-llamacpp-installer"
    }
}

function Get-SafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return ([regex]::Replace($Value, '[^A-Za-z0-9._-]+', '-')).Trim('-')
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$WorkingDirectory = $null
    )

    $CommandLine = if ($Arguments -and $Arguments.Count -gt 0) {
        "$FilePath $($Arguments -join ' ')"
    }
    else {
        $FilePath
    }

    Write-Host $CommandLine -ForegroundColor DarkGray

    $PreviousLocation = $null
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $PreviousLocation = Get-Location
        Set-Location -LiteralPath $WorkingDirectory
    }

    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $CommandLine"
        }
    }
    finally {
        if ($PreviousLocation) {
            Set-Location $PreviousLocation
        }
    }
}

function Get-LatestReleaseMetadata {
    return Invoke-RestMethod `
        -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" `
        -Headers (Get-GitHubHeaders)
}

function Get-SourceMetadata {
    if (-not [string]::IsNullOrWhiteSpace($Ref)) {
        return [pscustomobject]@{
            Label       = $Ref
            Summary     = "ref $Ref"
            ArchiveUrl  = "https://api.github.com/repos/ggml-org/llama.cpp/zipball/$([uri]::EscapeDataString($Ref))"
            SourcePage  = "https://github.com/ggml-org/llama.cpp/tree/$([uri]::EscapeDataString($Ref))"
            PublishedAt = $null
        }
    }

    if ($Source -eq "Master") {
        return [pscustomobject]@{
            Label       = "master"
            Summary     = "master branch"
            ArchiveUrl  = "https://api.github.com/repos/ggml-org/llama.cpp/zipball/master"
            SourcePage  = "https://github.com/ggml-org/llama.cpp/tree/master"
            PublishedAt = $null
        }
    }

    $Release = Get-LatestReleaseMetadata
    return [pscustomobject]@{
        Label       = $Release.tag_name
        Summary     = "latest release $($Release.tag_name)"
        ArchiveUrl  = $Release.zipball_url
        SourcePage  = $Release.html_url
        PublishedAt = $Release.published_at
    }
}

function Resolve-Backend {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedBackend
    )

    if ($RequestedBackend -ne "Auto") {
        return $RequestedBackend
    }

    $CudaBin = Get-CudaBinDirectory
    if ($CudaBin) {
        return "CUDA"
    }

    if (($env:VULKAN_SDK -and (Test-Path -LiteralPath $env:VULKAN_SDK)) -or (Get-Command vulkaninfo.exe -ErrorAction SilentlyContinue)) {
        return "Vulkan"
    }

    return "CPU"
}

function Get-CudaBinDirectory {
    if ($env:CUDA_PATH) {
        $CudaPathBin = Join-Path $env:CUDA_PATH "bin"
        if (Test-Path -LiteralPath $CudaPathBin -PathType Container) {
            return $CudaPathBin
        }
    }

    $Nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
    if ($Nvcc -and $Nvcc.Source) {
        $NvccBin = Split-Path -Parent $Nvcc.Source
        if (Test-Path -LiteralPath $NvccBin -PathType Container) {
            return $NvccBin
        }
    }

    return $null
}

function Get-VswherePath {
    $Candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
        (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    return $Candidates | Select-Object -First 1
}

function Resolve-CMakeGenerator {
    param(
        [string]$RequestedGenerator
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedGenerator)) {
        return $RequestedGenerator
    }

    $VswherePath = Get-VswherePath
    if ($VswherePath) {
        $InstallationPath = & $VswherePath `
            -latest `
            -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -version "[17.0,18.0)" `
            -property installationPath

        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($InstallationPath)) {
            return "Visual Studio 17 2022"
        }
    }

    throw "Cannot find a usable Visual Studio 2022 / Build Tools 2022 C++ toolchain. Install Visual Studio 2022 or Build Tools 2022 with the 'Desktop development with C++' workload, then run install_all.cmd again. If you already have another working CMake toolchain, pass -Generator explicitly."
}

function Get-BuildArtifactDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory
    )

    $ServerBinary = Get-ChildItem -LiteralPath $BuildDirectory -Filter "llama-server.exe" -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $ServerBinary) {
        throw "Could not find llama-server.exe under build output: $BuildDirectory"
    }

    return Split-Path -Parent $ServerBinary.FullName
}

function Backup-BinDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }

    $ExistingContent = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ExistingContent) {
        return $null
    }

    Ensure-Directory -Path $BackupRoot
    $BackupPath = Join-Path $BackupRoot ("bin-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Copy-Item -LiteralPath $Path -Destination $BackupPath -Recurse -Force
    return $BackupPath
}

function Remove-StaleRuntimeFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    foreach ($Pattern in @("*.exe", "*.dll", "*.lib", "*.exp", "*.pdb", "*.manifest")) {
        $Matches = Get-ChildItem -LiteralPath $Path -Filter $Pattern -File -ErrorAction SilentlyContinue
        foreach ($Match in $Matches) {
            Remove-Item -LiteralPath $Match.FullName -Force
        }
    }
}

function Copy-CudaRuntimeFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CudaBinDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    $Patterns = @(
        "cudart*.dll",
        "cublas*.dll",
        "cublasLt*.dll",
        "curand*.dll",
        "cusparse*.dll",
        "cufft*.dll",
        "nvrtc*.dll",
        "nvJitLink*.dll"
    )

    $Copied = New-Object System.Collections.Generic.List[string]
    $Seen = @{}

    foreach ($Pattern in $Patterns) {
        $Matches = Get-ChildItem -LiteralPath $CudaBinDirectory -Filter $Pattern -File -ErrorAction SilentlyContinue
        foreach ($Match in $Matches) {
            if ($Seen.ContainsKey($Match.Name)) {
                continue
            }

            Copy-Item -LiteralPath $Match.FullName -Destination (Join-Path $DestinationDirectory $Match.Name) -Force
            $Seen[$Match.Name] = $true
            [void]$Copied.Add($Match.Name)
        }
    }

    return $Copied
}

function Stop-TrackedServerBestEffort {
    if ($SkipStop) {
        return
    }

    if (-not (Test-Path -LiteralPath $LauncherScript)) {
        return
    }

    try {
        Write-Step "Stopping any currently tracked llama.cpp server..."
        Invoke-ExternalCommand `
            -FilePath $PowerShellExe `
            -Arguments @(
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $LauncherScript,
                "-Stop"
            )
    }
    catch {
        Write-Warning "Could not stop the tracked server automatically. Continuing with the install. Details: $($_.Exception.Message)"
    }
}

function Install-AutostartBestEffort {
    if (-not $InstallAutostart) {
        return
    }

    if (-not (Test-Path -LiteralPath $AutostartScript)) {
        throw "Cannot find autostart installer script: $AutostartScript"
    }

    Write-Step "Registering the Windows autostart scheduled task..."

    $AutostartArgs = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $AutostartScript,
        "-TriggerMode", $TriggerMode
    )

    if ($RunAutostartNow) {
        $AutostartArgs += "-RunNow"
    }

    Invoke-ExternalCommand -FilePath $PowerShellExe -Arguments $AutostartArgs
}

if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue) -and -not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw "Cannot find cmake.exe. Install Visual Studio 2022 / Build Tools 2022 with CMake support first."
}

$CMakeExe = (Get-Command cmake.exe -ErrorAction SilentlyContinue)
if (-not $CMakeExe) {
    $CMakeExe = Get-Command cmake -ErrorAction Stop
}
$CMakePath = $CMakeExe.Source

Ensure-Directory -Path $ManagedRoot
Ensure-Directory -Path $DownloadRoot
Ensure-Directory -Path $SourceRoot
Ensure-Directory -Path $BuildRoot
Ensure-Directory -Path $BinRoot

$SourceInfo = Get-SourceMetadata
$ResolvedBackend = Resolve-Backend -RequestedBackend $Backend
$ResolvedGenerator = Resolve-CMakeGenerator -RequestedGenerator $Generator

$SafeSourceLabel = Get-SafeName -Value $SourceInfo.Label
$SafeBackendLabel = $ResolvedBackend.ToLowerInvariant()
$SafePlatformLabel = $Platform.ToLowerInvariant()

$ArchivePath = Join-Path $DownloadRoot ("llama.cpp-{0}.zip" -f $SafeSourceLabel)
$ExpandedRoot = Join-Path $SourceRoot $SafeSourceLabel
$BuildDirectory = Join-Path $BuildRoot ("{0}-{1}-{2}" -f $SafeSourceLabel, $SafeBackendLabel, $SafePlatformLabel)

Write-Host "llama.cpp installer" -ForegroundColor Green
Write-Host "Project : $ProjectRoot"
Write-Host "Source  : $($SourceInfo.Summary)"
if ($SourceInfo.PublishedAt) {
    Write-Host "Date    : $($SourceInfo.PublishedAt)"
}
Write-Host "Backend : $ResolvedBackend"
Write-Host "CMake   : $ResolvedGenerator"
Write-Host "Bin     : $BinRoot"

Write-Step "Downloading official llama.cpp source archive..."
if (Test-Path -LiteralPath $ArchivePath) {
    Remove-Item -LiteralPath $ArchivePath -Force
}
Invoke-WebRequest -Uri $SourceInfo.ArchiveUrl -Headers (Get-GitHubHeaders) -OutFile $ArchivePath

Write-Step "Expanding source archive..."
Clear-ManagedDirectory -Path $ExpandedRoot -Root $ManagedRoot
Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExpandedRoot

    $ExpandedChildren = @(Get-ChildItem -LiteralPath $ExpandedRoot -Directory -ErrorAction Stop)
if ($ExpandedChildren.Count -ne 1) {
    throw "Expected one top-level folder after expanding $ArchivePath, found $($ExpandedChildren.Count)."
}
$SourceDirectory = $ExpandedChildren[0].FullName

Write-Step "Configuring CMake..."
Clear-ManagedDirectory -Path $BuildDirectory -Root $ManagedRoot

$ConfigureArgs = @(
    "-S", $SourceDirectory,
    "-B", $BuildDirectory,
    "-G", $ResolvedGenerator,
    "-DLLAMA_BUILD_TESTS=OFF"
)

if ($ResolvedGenerator -like "Visual Studio*") {
    $ConfigureArgs += @("-A", $Platform)
}

switch ($ResolvedBackend) {
    "CUDA" {
        $ConfigureArgs += "-DGGML_CUDA=ON"
    }
    "Vulkan" {
        $ConfigureArgs += "-DGGML_VULKAN=ON"
    }
}

Invoke-ExternalCommand -FilePath $CMakePath -Arguments $ConfigureArgs

Write-Step "Building llama.cpp..."
$BuildArgs = @(
    "--build", $BuildDirectory,
    "--config", "Release"
)

if ($Jobs -gt 0) {
    $BuildArgs += @("--parallel", $Jobs.ToString())
}

Invoke-ExternalCommand -FilePath $CMakePath -Arguments $BuildArgs

$ArtifactDirectory = Get-BuildArtifactDirectory -BuildDirectory $BuildDirectory
$ArtifactFiles = @(Get-ChildItem -LiteralPath $ArtifactDirectory -File -ErrorAction Stop)
if (-not $ArtifactFiles) {
    throw "No files found in build artifact directory: $ArtifactDirectory"
}

Stop-TrackedServerBestEffort

$BackupPath = $null
if (-not $SkipBackup) {
    Write-Step "Backing up the existing bin folder..."
    $BackupPath = Backup-BinDirectory -Path $BinRoot
}

Write-Step "Installing freshly built binaries into bin..."
Ensure-Directory -Path $BinRoot
Remove-StaleRuntimeFiles -Path $BinRoot

foreach ($ArtifactFile in $ArtifactFiles) {
    Copy-Item -LiteralPath $ArtifactFile.FullName -Destination (Join-Path $BinRoot $ArtifactFile.Name) -Force
}

$CudaRuntimeFiles = @()
if ($ResolvedBackend -eq "CUDA" -and -not $NoCudaRuntimeCopy) {
    $CudaBinDirectory = Get-CudaBinDirectory
    if ($CudaBinDirectory) {
        Write-Step "Copying CUDA runtime DLLs from the local toolkit..."
        $CudaRuntimeFiles = Copy-CudaRuntimeFiles -CudaBinDirectory $CudaBinDirectory -DestinationDirectory $BinRoot
        if ($CudaRuntimeFiles.Count -eq 0) {
            Write-Warning "No CUDA runtime DLLs matched the copy patterns under $CudaBinDirectory. The build may still work if CUDA is already on PATH."
        }
    }
    else {
        Write-Warning "CUDA backend was selected, but no CUDA toolkit bin directory was found for runtime DLL copy."
    }
}

$InstalledServerPath = Join-Path $BinRoot "llama-server.exe"
if (-not (Test-Path -LiteralPath $InstalledServerPath)) {
    throw "Install completed the copy step, but bin\\llama-server.exe is still missing."
}

Install-AutostartBestEffort

Write-Host ""
Write-Host "Install completed." -ForegroundColor Green
Write-Host "Source  : $($SourceInfo.SourcePage)"
Write-Host "Backend : $ResolvedBackend"
Write-Host "Build   : $BuildDirectory"
Write-Host "Output  : $ArtifactDirectory"
Write-Host "Server  : $InstalledServerPath"
if ($BackupPath) {
    Write-Host "Backup  : $BackupPath"
}
if ($CudaRuntimeFiles.Count -gt 0) {
    Write-Host "CUDA DLL: copied $($CudaRuntimeFiles.Count) runtime files"
}
if ($InstallAutostart) {
    Write-Host "Autostart: installed ($TriggerMode)"
}
