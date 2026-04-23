[CmdletBinding()]
param(
    [string]$ModelPath,
    [string]$MmprojPath,
    [Alias("Host")]
    [string]$ListenHost = "127.0.0.1",
    [int]$Port = 8081,
    [int]$ContextSize = 8192,
    [int]$GpuLayers = 99,
    [int]$ReadyTimeoutSec = 360,
    [switch]$NoJinja,
    [switch]$NoMmprojOffload,
    [switch]$NoPause,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptHome = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = if ([string]::Equals([System.IO.Path]::GetFileName($ScriptHome), "PS1", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $ScriptHome
}
else {
    $ScriptHome
}

$LogRoot = Join-Path $ProjectRoot "logs"
$JsonRoot = Join-Path $ProjectRoot "json"
$ModelIndexPath = Join-Path $JsonRoot "model-index.json"
$ServerExe = Join-Path $ProjectRoot "bin\llama-server.exe"
$PidFile = Join-Path $LogRoot "vision-server.pid"
$StdOutLog = Join-Path $LogRoot "vision-server.stdout.log"
$StdErrLog = Join-Path $LogRoot "vision-server.stderr.log"

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)

    $quotedArguments = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            '"{0}"' -f $argument.Replace('"', '\"')
        }
        else {
            $argument
        }
    }

    return ($quotedArguments -join " ")
}

function Resolve-ExistingPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    try {
        return (Resolve-Path -LiteralPath $expandedPath -ErrorAction Stop).ProviderPath
    }
    catch {
        return $expandedPath
    }
}

function Invoke-HealthRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSec = 3
    )

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            return [pscustomobject]@{}
        }

        return ($response.Content | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-VisionModelName {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    if ($Text -match '(?i)mmproj') {
        return $false
    }

    return ($Text -match '(?i)(qwen3vl|qwen[\-_ ]?(?:2(?:\.5)?|3)?[\-_ ]?vl|vision|vlm|multimodal|multi[\-_ ]?modal|image|llava|internvl|pixtral|paligemma|minicpm(?:[\-_ ]?v)?|mllama|smolvlm|molmo|moondream|janus|omni|gemma[\-_ ]?[34])')
}

function Test-MmprojFilePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $fileName = [System.IO.Path]::GetFileName($Path)
    return ($fileName -match '(?i)(^|[-_.])mmproj([-_.]|$)')
}

function Get-NameTokens {
    param([Parameter(Mandatory = $true)][string]$Text)

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Text).ToLowerInvariant()
    $baseName = $baseName -replace 'mmproj', ' '
    $tokens = [regex]::Matches($baseName, '[a-z0-9]+') | ForEach-Object { $_.Value }
    $stopTokens = @(
        "q2", "q3", "q4", "q5", "q6", "q7", "q8", "q9",
        "k", "m", "s", "l", "xl", "xs", "0", "1",
        "f16", "fp16", "bf16", "gguf", "uncensored"
    )

    return @($tokens | Where-Object { $_ -and ($stopTokens -notcontains $_) } | Select-Object -Unique)
}

function Get-TokenMatchScore {
    param(
        [Parameter(Mandatory = $true)][string]$ModelPath,
        [Parameter(Mandatory = $true)][string]$ProjectorPath
    )

    $modelTokens = @(Get-NameTokens -Text $ModelPath)
    $projectorTokens = @(Get-NameTokens -Text $ProjectorPath)
    if ($modelTokens.Count -eq 0 -or $projectorTokens.Count -eq 0) {
        return 0
    }

    $score = 0
    foreach ($token in $modelTokens) {
        if ($projectorTokens -contains $token) {
            $score += 10
        }
    }

    $modelName = ([System.IO.Path]::GetFileNameWithoutExtension($ModelPath)).ToLowerInvariant()
    $projectorName = ([System.IO.Path]::GetFileNameWithoutExtension($ProjectorPath)).ToLowerInvariant()
    $limit = [Math]::Min($modelName.Length, $projectorName.Length)
    for ($index = 0; $index -lt $limit; $index++) {
        if ($modelName[$index] -ne $projectorName[$index]) {
            break
        }
        $score += 1
    }

    return $score
}

function Find-MmprojForModel {
    param([Parameter(Mandatory = $true)][string]$ResolvedModelPath)

    if (Test-MmprojFilePath -Path $ResolvedModelPath) {
        return $null
    }

    $modelDirectory = Split-Path -Parent $ResolvedModelPath
    if ([string]::IsNullOrWhiteSpace($modelDirectory) -or -not (Test-Path -LiteralPath $modelDirectory -PathType Container)) {
        return $null
    }

    $projectors = @(
        Get-ChildItem -LiteralPath $modelDirectory -File -Filter "*mmproj*.gguf" -ErrorAction SilentlyContinue
    )
    if ($projectors.Count -eq 0) {
        return $null
    }

    $selectedScore = @(
        foreach ($projector in $projectors) {
            [pscustomobject]@{
                Path = $projector.FullName
                Score = Get-TokenMatchScore -ModelPath $ResolvedModelPath -ProjectorPath $projector.FullName
            }
        }
    ) | Sort-Object Score -Descending | Select-Object -First 1

    if ($selectedScore -and $selectedScore.Score -gt 0) {
        return [string]$selectedScore.Path
    }

    return $null
}

function Get-OpenAiModelIdsFromPayload {
    param([AllowNull()]$Payload)

    if ($null -eq $Payload) {
        return @()
    }

    if ($Payload.PSObject.Properties["data"] -and $null -ne $Payload.data) {
        return @($Payload.data | ForEach-Object { if ($_.PSObject.Properties["id"]) { [string]$_.id } } | Where-Object { $_ })
    }
    if ($Payload.PSObject.Properties["models"] -and $null -ne $Payload.models) {
        return @(
            $Payload.models | ForEach-Object {
                if ($_.PSObject.Properties["id"]) {
                    [string]$_.id
                }
                elseif ($_.PSObject.Properties["model"]) {
                    [string]$_.model
                }
                elseif ($_.PSObject.Properties["name"]) {
                    [string]$_.name
                }
            } | Where-Object { $_ }
        )
    }

    return @()
}

function Test-VisionHealthMatchesSelection {
    param(
        [AllowNull()]$Health,
        [Parameter(Mandatory = $true)][string]$SelectedModelPath
    )

    $ModelIds = @(Get-OpenAiModelIdsFromPayload -Payload $Health)
    if ($ModelIds.Count -eq 0) {
        return $false
    }

    $TargetFileName = [System.IO.Path]::GetFileName($SelectedModelPath)
    $TargetBaseName = [System.IO.Path]::GetFileNameWithoutExtension($SelectedModelPath)
    foreach ($ModelId in $ModelIds) {
        if ([string]::Equals($ModelId, $SelectedModelPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($ModelId, $TargetFileName, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($ModelId, $TargetBaseName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-ModelIndexEntries {
    if (-not (Test-Path -LiteralPath $ModelIndexPath)) {
        return @()
    }

    try {
        $data = Get-Content -LiteralPath $ModelIndexPath -Raw | ConvertFrom-Json
        return @($data.models)
    }
    catch {
        Write-Warn "Could not read model index: $ModelIndexPath"
        return @()
    }
}

function Resolve-VisionModelSelection {
    param(
        [AllowNull()][string]$RequestedModelPath,
        [AllowNull()][string]$RequestedMmprojPath
    )

    $resolvedModelPath = Resolve-ExistingPath -Path $RequestedModelPath
    $resolvedMmprojPath = Resolve-ExistingPath -Path $RequestedMmprojPath

    if ([string]::IsNullOrWhiteSpace($resolvedModelPath)) {
        $candidates = @(
            foreach ($entry in Get-ModelIndexEntries) {
                $entryPathRaw = if ($entry.PSObject.Properties["path"]) { [string]$entry.path } else { "" }
                $entryPath = Resolve-ExistingPath -Path $entryPathRaw
                if ([string]::IsNullOrWhiteSpace($entryPath) -or -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
                    continue
                }
                if (Test-MmprojFilePath -Path $entryPath) {
                    continue
                }

                $explicitProjectorPath = if ($entry.PSObject.Properties["mmproj_path"]) { Resolve-ExistingPath -Path ([string]$entry.mmproj_path) } else { $null }
                $projectorPath = if (-not [string]::IsNullOrWhiteSpace($explicitProjectorPath) -and (Test-Path -LiteralPath $explicitProjectorPath -PathType Leaf)) {
                    $explicitProjectorPath
                }
                else {
                    Find-MmprojForModel -ResolvedModelPath $entryPath
                }
                $entryName = if ($entry.PSObject.Properties["name"]) { [string]$entry.name } else { "" }
                $nameText = "{0} {1}" -f $entryName, $entryPath
                if (-not $projectorPath -and -not (Test-VisionModelName -Text $nameText)) {
                    continue
                }

                $score = 0
                if ($entry.PSObject.Properties["capabilities"] -and $null -ne $entry.capabilities -and $entry.capabilities.PSObject.Properties["vision"] -and $entry.capabilities.vision) {
                    $score += 100
                }
                if ($projectorPath) {
                    $score += 1000 + (Get-TokenMatchScore -ModelPath $entryPath -ProjectorPath $projectorPath)
                }

                [pscustomobject]@{
                    ModelPath = $entryPath
                    MmprojPath = $projectorPath
                    Score = $score
                }
            }
        )

        $selected = @($candidates | Sort-Object Score -Descending | Select-Object -First 1)
        if ($selected.Count -gt 0) {
            $resolvedModelPath = $selected[0].ModelPath
            if ([string]::IsNullOrWhiteSpace($resolvedMmprojPath)) {
                $resolvedMmprojPath = $selected[0].MmprojPath
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedModelPath)) {
        throw "No vision model was selected. Pass -ModelPath or set LCPP_VISION_MODEL_PATH."
    }
    if (-not (Test-Path -LiteralPath $resolvedModelPath -PathType Leaf)) {
        throw "Vision model was not found: $resolvedModelPath"
    }

    if ([string]::IsNullOrWhiteSpace($resolvedMmprojPath)) {
        $resolvedMmprojPath = Find-MmprojForModel -ResolvedModelPath $resolvedModelPath
    }
    if ([string]::IsNullOrWhiteSpace($resolvedMmprojPath)) {
        throw "No mmproj file was found for $resolvedModelPath. Pass -MmprojPath or set LCPP_VISION_MMPROJ_PATH."
    }
    if (-not (Test-Path -LiteralPath $resolvedMmprojPath -PathType Leaf)) {
        throw "Vision mmproj was not found: $resolvedMmprojPath"
    }

    return [pscustomobject]@{
        ModelPath = $resolvedModelPath
        MmprojPath = $resolvedMmprojPath
    }
}

function Get-VisionServerProcesses {
    param([int]$VisionPort = 8081)

    $trackedIds = New-Object System.Collections.Generic.HashSet[int]
    if (Test-Path -LiteralPath $PidFile) {
        $pidText = ((Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1) | Out-String).Trim()
        if ($pidText -match '^\d+$') {
            [void]$trackedIds.Add([int]$pidText)
        }
    }

    $serverPathPattern = [regex]::Escape($ServerExe)
    $portPattern = "(?i)(?:--port(?:\s+|=)$VisionPort\b|-p(?:\s+|=)$VisionPort\b)"

    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'llama-server.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $commandLine = [string]$_.CommandLine
                $isTracked = $trackedIds.Contains([int]$_.ProcessId)
                $isVisionCommand = $commandLine -match $serverPathPattern -and
                    $commandLine -match '(?i)--mmproj' -and
                    $commandLine -match $portPattern

                $isTracked -or $isVisionCommand
            }
    ) | Sort-Object ProcessId -Unique
}

function Stop-StaleVisionServers {
    param([int]$VisionPort = 8081)

    $processes = @(Get-VisionServerProcesses -VisionPort $VisionPort)
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
        catch {
        }
    }

    if ($processes.Count -gt 0) {
        Write-Warn "Stopped stale vision server process(es): $($processes.ProcessId -join ', ')"
        Start-Sleep -Seconds 1
    }
}

function Wait-VisionServerReady {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [int]$TimeoutSec = 360
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max(10, $TimeoutSec))
    $modelsUrl = "$BaseUrl/v1/models"
    $healthUrl = "$BaseUrl/health"

    while ((Get-Date) -lt $deadline) {
        try {
            $Process.Refresh()
            if ($Process.HasExited) {
                break
            }
        }
        catch {
            break
        }

        foreach ($url in @($healthUrl, $modelsUrl)) {
            $payload = Invoke-HealthRequest -Url $url -TimeoutSec 3
            if ($null -ne $payload) {
                return $payload
            }
        }

        Start-Sleep -Seconds 2
    }

    $stdoutTail = ""
    $stderrTail = ""
    if (Test-Path -LiteralPath $StdOutLog) {
        $stdoutTail = (Get-Content -LiteralPath $StdOutLog -Tail 80 | Out-String).Trim()
    }
    if (Test-Path -LiteralPath $StdErrLog) {
        $stderrTail = (Get-Content -LiteralPath $StdErrLog -Tail 80 | Out-String).Trim()
    }

    if ($stdoutTail) {
        Write-Host ""
        Write-Host "[vision stdout tail]"
        Write-Host $stdoutTail
    }
    if ($stderrTail) {
        Write-Host ""
        Write-Host "[vision stderr tail]"
        Write-Host $stderrTail
    }

    throw "Vision llama-server did not become ready in time."
}

function Pause-BeforeExit {
    if ($NoPause) {
        return
    }
    if (-not [Environment]::UserInteractive) {
        return
    }

    try {
        Read-Host "Press Enter to close this window" | Out-Null
    }
    catch {
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($ModelPath) -and -not [string]::IsNullOrWhiteSpace($env:LCPP_VISION_MODEL_PATH)) {
        $ModelPath = $env:LCPP_VISION_MODEL_PATH
    }
    if ([string]::IsNullOrWhiteSpace($MmprojPath) -and -not [string]::IsNullOrWhiteSpace($env:LCPP_VISION_MMPROJ_PATH)) {
        $MmprojPath = $env:LCPP_VISION_MMPROJ_PATH
    }
    if ($PSBoundParameters.ContainsKey("Port") -eq $false -and $env:LCPP_VISION_PORT -match '^\d+$') {
        $Port = [int]$env:LCPP_VISION_PORT
    }

    if (-not (Test-Path -LiteralPath $ServerExe -PathType Leaf)) {
        throw "Cannot find llama-server.exe: $ServerExe"
    }

    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

    $selection = Resolve-VisionModelSelection -RequestedModelPath $ModelPath -RequestedMmprojPath $MmprojPath
    if ($PSBoundParameters.ContainsKey("ListenHost") -eq $false -and -not [string]::IsNullOrWhiteSpace($env:LCPP_VISION_HOST)) {
        $ListenHost = $env:LCPP_VISION_HOST
    }

    $baseUrl = "http://$ListenHost`:$Port"
    $existingHealth = Invoke-HealthRequest -Url "$baseUrl/v1/models" -TimeoutSec 3
    if ($null -ne $existingHealth) {
        if (Test-VisionHealthMatchesSelection -Health $existingHealth -SelectedModelPath $selection.ModelPath) {
            Write-Ok "Vision llama-server is already reachable at $baseUrl"
            Write-Host "Model : $($selection.ModelPath)"
            Write-Host "Mmproj: $($selection.MmprojPath)"
            Write-Host "Logs  : $LogRoot"
            return
        }

        $existingModels = @(Get-OpenAiModelIdsFromPayload -Payload $existingHealth)
        Write-Warn "Vision llama-server at $baseUrl is serving a different model: $($existingModels -join ', '). Restarting it."
    }

    Stop-StaleVisionServers -VisionPort $Port
    Set-Content -LiteralPath $StdOutLog -Value "" -Encoding UTF8
    Set-Content -LiteralPath $StdErrLog -Value "" -Encoding UTF8

    $serverArgs = @(
        "-m", $selection.ModelPath,
        "--mmproj", $selection.MmprojPath,
        "--host", $ListenHost,
        "--port", [string]$Port,
        "-c", [string]$ContextSize,
        "-ngl", [string]$GpuLayers
    )
    if (-not $NoJinja) {
        $serverArgs += "--jinja"
    }
    if ($NoMmprojOffload) {
        $serverArgs += "--no-mmproj-offload"
    }
    if ($ExtraArgs) {
        $serverArgs += @($ExtraArgs)
    }

    $argumentString = ConvertTo-ArgumentString -Arguments $serverArgs

    Write-Info "Starting vision llama-server on $baseUrl"
    Write-Host "Model : $($selection.ModelPath)"
    Write-Host "Mmproj: $($selection.MmprojPath)"

    $process = Start-Process `
        -FilePath $ServerExe `
        -ArgumentList $argumentString `
        -WorkingDirectory $ProjectRoot `
        -RedirectStandardOutput $StdOutLog `
        -RedirectStandardError $StdErrLog `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ASCII
    Write-Ok "Vision llama-server started with PID $($process.Id)"

    [void](Wait-VisionServerReady -Process $process -BaseUrl $baseUrl -TimeoutSec $ReadyTimeoutSec)
    Write-Ok "Vision llama-server is ready at $baseUrl"
    Write-Host "API   : $baseUrl/v1/chat/completions"
    Write-Host "Logs  : $LogRoot"
}
catch {
    Write-Host ""
    Write-Host "Error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    Pause-BeforeExit
}
