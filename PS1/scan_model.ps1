<#
.SYNOPSIS
Scans local GGUF files and rebuilds model-index.json.

.DESCRIPTION
Looks for *.gguf files in the launcher root folder and writes a
json\model-index.json file compatible with Start_LCPP.ps1. Model paths are
written as absolute paths so the generated JSON can be copied elsewhere.
The first model in alphabetical order becomes the default model.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
        [Parameter(Mandatory = $true)]
        [string]$ModelPath
    )

    if (-not (Test-Path -LiteralPath $ModelPath)) {
        return $null
    }

    $Architecture = $null

    try {
        $Stream = [System.IO.File]::Open($ModelPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
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

    return $Architecture
}

function Test-MmprojFilePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $FileName = [System.IO.Path]::GetFileName($Path)
    return ($FileName -match '(?i)(^|[-_.])mmproj([-_.]|$)')
}

function Get-MmprojNameTokens {
    param([Parameter(Mandatory = $true)][string]$Text)

    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($Text).ToLowerInvariant()
    $BaseName = $BaseName -replace 'mmproj', ' '
    $Tokens = [regex]::Matches($BaseName, '[a-z0-9]+') | ForEach-Object { $_.Value }
    $StopTokens = @(
        "q2", "q3", "q4", "q5", "q6", "q7", "q8", "q9",
        "k", "m", "s", "l", "xl", "xs", "p", "0", "1",
        "f16", "fp16", "bf16", "gguf", "uncensored"
    )

    return @($Tokens | Where-Object { $_ -and ($StopTokens -notcontains $_) } | Select-Object -Unique)
}

function Get-MmprojTokenMatchScore {
    param(
        [Parameter(Mandatory = $true)][string]$ModelPath,
        [Parameter(Mandatory = $true)][string]$ProjectorPath
    )

    $ModelTokens = @(Get-MmprojNameTokens -Text $ModelPath)
    $ProjectorTokens = @(Get-MmprojNameTokens -Text $ProjectorPath)
    if ($ModelTokens.Count -eq 0 -or $ProjectorTokens.Count -eq 0) {
        return 0
    }

    $Score = 0
    foreach ($Token in $ModelTokens) {
        if ($ProjectorTokens -contains $Token) {
            $Score += 10
        }
    }

    $ModelName = ([System.IO.Path]::GetFileNameWithoutExtension($ModelPath)).ToLowerInvariant()
    $ProjectorName = ([System.IO.Path]::GetFileNameWithoutExtension($ProjectorPath)).ToLowerInvariant()
    $ProjectorName = $ProjectorName -replace '^mmproj[-_. ]*', ''
    $Limit = [Math]::Min($ModelName.Length, $ProjectorName.Length)
    for ($Index = 0; $Index -lt $Limit; $Index++) {
        if ($ModelName[$Index] -ne $ProjectorName[$Index]) {
            break
        }

        $Score += 1
    }

    return $Score
}

function Find-MmprojForModel {
    param([Parameter(Mandatory = $true)][string]$ModelPath)

    if ([string]::IsNullOrWhiteSpace($ModelPath) -or -not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
        return $null
    }
    if (Test-MmprojFilePath -Path $ModelPath) {
        return $null
    }

    $ModelDirectory = Split-Path -Parent $ModelPath
    if ([string]::IsNullOrWhiteSpace($ModelDirectory) -or -not (Test-Path -LiteralPath $ModelDirectory -PathType Container)) {
        return $null
    }

    $Projectors = @(Get-ChildItem -LiteralPath $ModelDirectory -File -Filter "*mmproj*.gguf" -ErrorAction SilentlyContinue)
    if ($Projectors.Count -eq 0) {
        return $null
    }

    $SelectedProjector = @(
        foreach ($Projector in $Projectors) {
            [pscustomobject]@{
                Path  = $Projector.FullName
                Score = Get-MmprojTokenMatchScore -ModelPath $ModelPath -ProjectorPath $Projector.FullName
            }
        }
    ) | Sort-Object Score -Descending | Select-Object -First 1

    if ($SelectedProjector -and $SelectedProjector.Score -gt 0) {
        return [string]$SelectedProjector.Path
    }

    return $null
}

function Get-ModelCapabilities {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModelName,

        [Parameter(Mandatory = $true)]
        [string]$ModelPath
    )

    $Architecture = Get-GgufArchitectureHint -ModelPath $ModelPath
    $SearchText = @($ModelName, $ModelPath, $Architecture) -join " "
    $Normalized = $SearchText.ToLowerInvariant()
    $NormalizedArchitecture = if ($Architecture) { $Architecture.ToLowerInvariant() } else { "" }

    $VisionPattern = '(?<![a-z0-9])(vision|vlm|qwen3vl|qwen[\-_ ]?2(?:\.5)?[\-_ ]?vl|qwen[\-_ ]?vl|qvq|llava(?:[\-_ ]?(?:next|onevision))?|bakllava|internvl|pixtral|paligemma|minicpm(?:[\-_ ]?v)?|gemma[\-_ ]?3|mllama|llama[\-_ ]?3\.2[\-_ ]?vision|phi[\-_ ]?(?:3\.5|4)[\-_ ]?(?:vision|multimodal)|glm[\-_ ]?4(?:[\._-]1)?v|cogvlm|smolvlm|molmo|moondream|janus|omni|multimodal|multi[\-_ ]modal|image)(?![a-z0-9])'
    $ReasoningPattern = '(?<![a-z0-9])(reason|reasoning|think|thinking|chain[\-_ ]?of[\-_ ]?thought|cot|qwq|r1)(?![a-z0-9])'
    $VideoPattern = '(?<![a-z0-9])(video|movie|temporal|video[\-_ ]?chat|video[\-_ ]?llm|qwen[\-_ ]?omni|omni[\-_ ]?video)(?![a-z0-9])'
    $VoicePattern = '(?<![a-z0-9])(voice|audio|speech|spoken|tts|stt|asr|whisper|wav2vec|bark|speecht5|qwen[\-_ ]?audio|qwen[\-_ ]?omni|omni[\-_ ]?audio)(?![a-z0-9])'
    $ToolsPattern = '(?<![a-z0-9])(tool|tools|function|functions|function[\-_ ]?call(?:ing)?|tool[\-_ ]?use|agent)(?![a-z0-9])'
    $RerankPattern = '(?<![a-z0-9])(rerank|reranker|re[\-_ ]?rank|cross[\-_ ]?encoder|bge[\-_ ]?reranker|jina[\-_ ]?reranker)(?![a-z0-9])'
    $EmbeddingPattern = '(?<![a-z0-9])(embed|embedding|embeddings|text[\-_ ]?embedding|nomic[\-_ ]?embed|jina[\-_ ]?embeddings?|bge|e5|gte)(?![a-z0-9])'
    $ArchitectureVisionPattern = '^(qwen2vl|mllama|gemma3|minicpmv|llava|llava_next|pixtral|internvl|paligemma|glm4v|cogvlm|smolvlm|molmo|moondream|janus)$'

    $IsRerank = $Normalized -match $RerankPattern
    $IsEmbedding = (-not $IsRerank) -and ($Normalized -match $EmbeddingPattern)
    $IsVision = ($Normalized -match $VisionPattern) -or ($NormalizedArchitecture -match $ArchitectureVisionPattern) -or (-not [string]::IsNullOrWhiteSpace((Find-MmprojForModel -ModelPath $ModelPath)))
    $IsReasoning = $Normalized -match $ReasoningPattern
    $IsVideo = $Normalized -match $VideoPattern
    $IsVoice = $Normalized -match $VoicePattern
    $IsTools = $Normalized -match $ToolsPattern
    $IsChat = -not ($IsEmbedding -or $IsRerank)

    return [ordered]@{
        chat      = [bool]$IsChat
        reasoning = [bool]$IsReasoning
        vision    = [bool]$IsVision
        video     = [bool]$IsVideo
        voice     = [bool]$IsVoice
        tools     = [bool]$IsTools
        embedding = [bool]$IsEmbedding
        rerank    = [bool]$IsRerank
    }
}

$ScriptHome = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = if ([string]::Equals([System.IO.Path]::GetFileName($ScriptHome), "PS1", [System.StringComparison]::OrdinalIgnoreCase)) {
    Split-Path -Parent $ScriptHome
}
else {
    $ScriptHome
}
$JsonRoot = Join-Path -Path $ProjectRoot -ChildPath "json"
if (-not (Test-Path -LiteralPath $JsonRoot -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $JsonRoot -Force)
}

$IndexPath = Join-Path -Path $JsonRoot -ChildPath "model-index.json"
$ExistingByPath = @{}
if (Test-Path -LiteralPath $IndexPath -PathType Leaf) {
    try {
        $ExistingIndex = Get-Content -LiteralPath $IndexPath -Raw | ConvertFrom-Json
        foreach ($ExistingModel in @($ExistingIndex.models)) {
            if ($ExistingModel.PSObject.Properties["path"]) {
                $ExistingByPath[[string]$ExistingModel.path.ToLowerInvariant()] = $ExistingModel
            }
        }
    }
    catch {
    }
}

$ModelFiles = @(
    Get-ChildItem -LiteralPath $ProjectRoot -Filter "*.gguf" -File |
        Where-Object { -not (Test-MmprojFilePath -Path $_.FullName) } |
        Sort-Object Name
)

if ($ModelFiles.Count -eq 0) {
    Write-Warning ("No GGUF files were found in {0}. model-index.json was not changed." -f $ProjectRoot)
    exit 1
}

$UsedIds = @{}
$Models = @(
    foreach ($File in $ModelFiles) {
        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        $MmprojPath = Find-MmprojForModel -ModelPath $File.FullName

        $Entry = [ordered]@{
            id           = New-ModelId -Name $BaseName -UsedIds $UsedIds
            name         = $BaseName
            path         = $File.FullName
        }
        if (-not [string]::IsNullOrWhiteSpace($MmprojPath)) {
            $Entry["mmproj_path"] = $MmprojPath
        }

        $Entry["capabilities"] = Get-ModelCapabilities -ModelName $BaseName -ModelPath $File.FullName
        $ExistingKey = $File.FullName.ToLowerInvariant()
        if ($ExistingByPath.ContainsKey($ExistingKey)) {
            $ExistingEntry = $ExistingByPath[$ExistingKey]
            if ($ExistingEntry.PSObject.Properties["generation"]) {
                $Entry["generation"] = $ExistingEntry.generation
            }
        }
        $Entry["notes"] = "Auto-generated by scan_model.ps1."
        $Entry
    }
)

$IndexData = [ordered]@{
    default_model_id = $Models[0].id
    models           = $Models
}

$IndexData |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $IndexPath -Encoding UTF8

Write-Host ("Wrote {0} model(s) to {1}" -f $Models.Count, $IndexPath) -ForegroundColor Green
