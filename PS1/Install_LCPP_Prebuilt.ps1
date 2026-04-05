<#
.SYNOPSIS
Downloads and installs the latest official prebuilt llama.cpp Windows package.

.DESCRIPTION
Downloads the latest official ggml-org/llama.cpp Windows release ZIP assets
(CUDA by default), expands them into a staging area, replaces the local bin
folder runtime files, and can optionally register the existing autostart task.

.PARAMETER Backend
Choose CUDA, CPU, or Vulkan. Default is CUDA.

.PARAMETER Platform
Choose x64 or arm64. Default is x64.

.PARAMETER CudaVersion
Optional CUDA asset version override such as 13.1 or 12.4.
Auto prefers the current CUDA_PATH version, then any locally installed CUDA
toolkit version that has a matching official Windows asset, and otherwise falls
back to the newest official Windows CUDA asset.

.PARAMETER InstallAutostart
After a successful install, also register the Windows scheduled task by calling
Install_LCPP_Autostart.ps1.

.PARAMETER TriggerMode
Trigger mode passed to Install_LCPP_Autostart.ps1 when InstallAutostart is used.

.PARAMETER RunAutostartNow
When InstallAutostart is also specified, start the scheduled task once after
installing it.

.PARAMETER SkipBackup
Do not back up the existing bin folder contents before replacing runtime files.

.PARAMETER SkipStop
Do not stop the currently tracked llama.cpp server before replacing binaries.

.PARAMETER ForceDownload
Always download the selected release ZIP assets again, even when matching cached
files for the resolved release already exist.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet("CUDA", "CPU", "Vulkan")]
    [string]$Backend = "CUDA",

    [ValidateSet("x64", "arm64")]
    [string]$Platform = "x64",

    [string]$CudaVersion = "Auto",

    [switch]$InstallAutostart,

    [ValidateSet("Startup", "Logon")]
    [string]$TriggerMode = "Startup",

    [switch]$RunAutostartNow,

    [switch]$SkipBackup,

    [switch]$SkipStop,

    [switch]$ForceDownload
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
$BinRoot = Join-Path $ProjectRoot "bin"
$BackupRoot = Join-Path $ProjectRoot "backup"
$ManagedRoot = Join-Path $ProjectRoot ".cache\llama.cpp-prebuilt"
$DownloadRoot = Join-Path $ManagedRoot "downloads"
$StageRoot = Join-Path $ManagedRoot "expanded"
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

function Test-CachedArchiveAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $Item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return $Item.Length -gt 0
    }
    catch {
        return $false
    }
}

function Get-LatestReleaseMetadata {
    return Invoke-RestMethod `
        -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" `
        -Headers (Get-GitHubHeaders)
}

function Get-SafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return ([regex]::Replace($Value, '[^A-Za-z0-9._-]+', '-')).Trim('-')
}

function Try-ConvertToVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    try {
        return [Version]$Value
    }
    catch {
        return $null
    }
}

function Get-CudaVersionFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -match 'CUDA\\v(?<version>\d+(?:\.\d+)+)') {
        return $Matches.version
    }

    $Leaf = Split-Path -Leaf $Path
    if ($Leaf -match '^v(?<version>\d+(?:\.\d+)+)$') {
        return $Matches.version
    }

    return $null
}

function Get-InstalledCudaVersions {
    $Versions = @()
    $Seen = @{}
    $Candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($env:CUDA_PATH)) {
        $Candidates += $env:CUDA_PATH
    }

    $CudaEnvVars = Get-ChildItem Env:CUDA_PATH_V* -ErrorAction SilentlyContinue
    foreach ($CudaEnvVar in $CudaEnvVars) {
        if (-not [string]::IsNullOrWhiteSpace($CudaEnvVar.Value)) {
            $Candidates += $CudaEnvVar.Value
        }
    }

    $ToolkitRoot = Join-Path $env:ProgramFiles "NVIDIA GPU Computing Toolkit\CUDA"
    if (Test-Path -LiteralPath $ToolkitRoot -PathType Container) {
        $ToolkitDirs = Get-ChildItem -LiteralPath $ToolkitRoot -Directory -ErrorAction SilentlyContinue
        foreach ($ToolkitDir in $ToolkitDirs) {
            $Candidates += $ToolkitDir.FullName
        }
    }

    foreach ($Candidate in $Candidates) {
        $VersionText = Get-CudaVersionFromPath -Path $Candidate
        if ([string]::IsNullOrWhiteSpace($VersionText)) {
            continue
        }

        $VersionObject = Try-ConvertToVersion -Value $VersionText
        if (-not $VersionObject) {
            continue
        }

        if ($Seen.ContainsKey($VersionText)) {
            continue
        }

        $Seen[$VersionText] = $true
        $Versions += [pscustomobject]@{
            Version     = $VersionObject
            VersionText = $VersionText
        }
    }

    return ($Versions | Sort-Object -Property Version -Descending)
}

function Get-ReleaseAssetCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release
    )

    $Catalog = @()
    foreach ($Asset in $Release.assets) {
        $Name = [string]$Asset.name

        if ($Name -match '^llama-.*-bin-win-cuda-(?<version>\d+(?:\.\d+)+)-(?<platform>x64|arm64)\.zip$') {
            $Catalog += [pscustomobject]@{
                Kind               = "Main"
                Backend            = "CUDA"
                Platform           = $Matches.platform
                VersionText        = $Matches.version
                Version            = [Version]$Matches.version
                Name               = $Name
                BrowserDownloadUrl = $Asset.browser_download_url
            }
            continue
        }

        if ($Name -match '^cudart-llama-bin-win-cuda-(?<version>\d+(?:\.\d+)+)-(?<platform>x64|arm64)\.zip$') {
            $Catalog += [pscustomobject]@{
                Kind               = "Runtime"
                Backend            = "CUDA"
                Platform           = $Matches.platform
                VersionText        = $Matches.version
                Version            = [Version]$Matches.version
                Name               = $Name
                BrowserDownloadUrl = $Asset.browser_download_url
            }
            continue
        }

        if ($Name -match '^llama-.*-bin-win-cpu-(?<platform>x64|arm64)\.zip$') {
            $Catalog += [pscustomobject]@{
                Kind               = "Main"
                Backend            = "CPU"
                Platform           = $Matches.platform
                VersionText        = $null
                Version            = $null
                Name               = $Name
                BrowserDownloadUrl = $Asset.browser_download_url
            }
            continue
        }

        if ($Name -match '^llama-.*-bin-win-vulkan-(?<platform>x64|arm64)\.zip$') {
            $Catalog += [pscustomobject]@{
                Kind               = "Main"
                Backend            = "Vulkan"
                Platform           = $Matches.platform
                VersionText        = $null
                Version            = $null
                Name               = $Name
                BrowserDownloadUrl = $Asset.browser_download_url
            }
            continue
        }
    }

    return $Catalog
}

function Resolve-PrebuiltAssetSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,

        [Parameter(Mandatory = $true)]
        [string]$RequestedBackend,

        [Parameter(Mandatory = $true)]
        [string]$RequestedPlatform,

        [Parameter(Mandatory = $true)]
        [string]$RequestedCudaVersion
    )

    $Catalog = Get-ReleaseAssetCatalog -Release $Release
    $MainCandidates = $Catalog | Where-Object {
        $_.Kind -eq "Main" -and
        $_.Backend -eq $RequestedBackend -and
        $_.Platform -eq $RequestedPlatform
    }

    if (-not $MainCandidates) {
        throw "No official Windows $RequestedBackend asset was found for release $($Release.tag_name) on platform $RequestedPlatform."
    }

    if ($RequestedBackend -ne "CUDA") {
        $SelectedMain = $MainCandidates | Select-Object -First 1
        return [pscustomobject]@{
            MainAsset          = $SelectedMain
            AdditionalAssets   = @()
            AssetDisplay       = $SelectedMain.Name
            SelectedVersion    = $null
            SelectedVersionTag = $null
        }
    }

    $RuntimeCandidates = $Catalog | Where-Object {
        $_.Kind -eq "Runtime" -and
        $_.Backend -eq "CUDA" -and
        $_.Platform -eq $RequestedPlatform
    }

    $SelectedVersionText = $null
    if (-not [string]::IsNullOrWhiteSpace($RequestedCudaVersion) -and $RequestedCudaVersion -ne "Auto") {
        $RequestedVersionObject = Try-ConvertToVersion -Value $RequestedCudaVersion
        if (-not $RequestedVersionObject) {
            throw "Invalid -CudaVersion value: $RequestedCudaVersion"
        }

        $SelectedVersionText = $RequestedCudaVersion
    }
    else {
        $PreferredVersionTexts = @()

        if (-not [string]::IsNullOrWhiteSpace($env:CUDA_PATH)) {
            $CurrentCudaVersion = Get-CudaVersionFromPath -Path $env:CUDA_PATH
            if (-not [string]::IsNullOrWhiteSpace($CurrentCudaVersion)) {
                $PreferredVersionTexts += $CurrentCudaVersion
            }
        }

        foreach ($InstalledVersion in (Get-InstalledCudaVersions)) {
            $PreferredVersionTexts += $InstalledVersion.VersionText
        }

        $SeenVersionTexts = @{}
        foreach ($PreferredVersionText in $PreferredVersionTexts) {
            if ($SeenVersionTexts.ContainsKey($PreferredVersionText)) {
                continue
            }

            $SeenVersionTexts[$PreferredVersionText] = $true
            $MatchedCandidate = $MainCandidates | Where-Object { $_.VersionText -eq $PreferredVersionText } | Select-Object -First 1
            if ($MatchedCandidate) {
                $SelectedVersionText = $PreferredVersionText
                break
            }
        }

        if (-not $SelectedVersionText) {
            $SelectedVersionText = ($MainCandidates | Sort-Object -Property Version -Descending | Select-Object -First 1).VersionText
        }
    }

    $SelectedMain = $MainCandidates | Where-Object { $_.VersionText -eq $SelectedVersionText } | Select-Object -First 1
    if (-not $SelectedMain) {
        $AvailableVersionTexts = $MainCandidates | Sort-Object -Property Version -Descending | ForEach-Object { $_.VersionText }
        throw "No official Windows CUDA asset matching version $SelectedVersionText was found for release $($Release.tag_name). Available versions: $($AvailableVersionTexts -join ', ')"
    }

    $SelectedRuntime = $RuntimeCandidates | Where-Object { $_.VersionText -eq $SelectedVersionText } | Select-Object -First 1
    $AdditionalAssets = @()
    if ($SelectedRuntime) {
        $AdditionalAssets += $SelectedRuntime
    }

    return [pscustomobject]@{
        MainAsset          = $SelectedMain
        AdditionalAssets   = $AdditionalAssets
        AssetDisplay       = $SelectedMain.Name
        SelectedVersion    = $SelectedMain.Version
        SelectedVersionTag = $SelectedMain.VersionText
    }
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

Ensure-Directory -Path $ManagedRoot
Ensure-Directory -Path $DownloadRoot
Ensure-Directory -Path $StageRoot
Ensure-Directory -Path $BinRoot

$Release = Get-LatestReleaseMetadata
$Selection = Resolve-PrebuiltAssetSelection `
    -Release $Release `
    -RequestedBackend $Backend `
    -RequestedPlatform $Platform `
    -RequestedCudaVersion $CudaVersion

$SelectedAssets = @()
$SelectedAssets += $Selection.MainAsset
if ($Selection.AdditionalAssets) {
    $SelectedAssets += $Selection.AdditionalAssets
}
$SafeReleaseLabel = Get-SafeName -Value $Release.tag_name
$SafeBackendLabel = $Backend.ToLowerInvariant()
$SafePlatformLabel = $Platform.ToLowerInvariant()
$StageDirectory = Join-Path $StageRoot ("{0}-{1}-{2}" -f $SafeReleaseLabel, $SafeBackendLabel, $SafePlatformLabel)

Write-Host "llama.cpp installer" -ForegroundColor Green
Write-Host "Project : $ProjectRoot"
Write-Host "Source  : latest official Windows release"
Write-Host "Release : $($Release.tag_name)"
Write-Host "Date    : $($Release.published_at)"
Write-Host "Backend : $Backend"
if ($Selection.SelectedVersionTag) {
    Write-Host "CUDA    : $($Selection.SelectedVersionTag)"
}
Write-Host "Asset   : $($Selection.AssetDisplay)"
Write-Host "Bin     : $BinRoot"

Write-Step "Downloading official llama.cpp Windows package..."
Clear-ManagedDirectory -Path $StageDirectory -Root $ManagedRoot

$ExpandedAssetDirectories = @()
foreach ($SelectedAsset in $SelectedAssets) {
    $ArchivePath = Join-Path $DownloadRoot $SelectedAsset.Name
    if (-not $ForceDownload -and (Test-CachedArchiveAvailable -Path $ArchivePath)) {
        Write-Host "Using cached package: $ArchivePath" -ForegroundColor DarkGray
    }
    else {
        if (Test-Path -LiteralPath $ArchivePath) {
            Remove-Item -LiteralPath $ArchivePath -Force
        }

        Invoke-WebRequest -Uri $SelectedAsset.BrowserDownloadUrl -Headers (Get-GitHubHeaders) -OutFile $ArchivePath
    }

    $ExpandedAssetDirectory = Join-Path $StageDirectory ([System.IO.Path]::GetFileNameWithoutExtension($SelectedAsset.Name))
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExpandedAssetDirectory -Force
    $ExpandedAssetDirectories += $ExpandedAssetDirectory
}

$ExpandedFiles = @()
foreach ($ExpandedAssetDirectory in $ExpandedAssetDirectories) {
    $ExpandedFiles += @(Get-ChildItem -LiteralPath $ExpandedAssetDirectory -File -Recurse -ErrorAction Stop)
}

if (-not $ExpandedFiles) {
    throw "No files were found after expanding the official Windows release assets."
}

Stop-TrackedServerBestEffort

$BackupPath = $null
if (-not $SkipBackup) {
    Write-Step "Backing up the existing bin folder..."
    $BackupPath = Backup-BinDirectory -Path $BinRoot
}

Write-Step "Installing official Windows binaries into bin..."
Ensure-Directory -Path $BinRoot
Remove-StaleRuntimeFiles -Path $BinRoot

$InstalledFileNames = @()
$SeenFileNames = @{}
foreach ($ExpandedFile in $ExpandedFiles) {
    $DestinationPath = Join-Path $BinRoot $ExpandedFile.Name
    Copy-Item -LiteralPath $ExpandedFile.FullName -Destination $DestinationPath -Force

    if (-not $SeenFileNames.ContainsKey($ExpandedFile.Name)) {
        $SeenFileNames[$ExpandedFile.Name] = $true
        $InstalledFileNames += $ExpandedFile.Name
    }
}

if ($Backend -eq "CUDA" -and -not ($InstalledFileNames | Where-Object { $_ -like "cudart*.dll" -or $_ -like "cublas*.dll" })) {
    Write-Warning "The selected CUDA package did not include bundled CUDA runtime DLLs. You may need to install a matching CUDA toolkit or use install_latest.cmd instead."
}

Install-AutostartBestEffort

Write-Host ""
Write-Host "Install complete." -ForegroundColor Green
Write-Host "Release : $($Release.tag_name)"
Write-Host "Asset   : $($SelectedAssets.Name -join ', ')"
Write-Host "Files   : $($InstalledFileNames.Count) installed to $BinRoot"
if ($BackupPath) {
    Write-Host "Backup  : $BackupPath"
}
