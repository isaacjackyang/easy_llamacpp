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
$ModelFiles = @(Get-ChildItem -LiteralPath $ProjectRoot -Filter "*.gguf" -File | Sort-Object Name)

if ($ModelFiles.Count -eq 0) {
    Write-Warning ("No GGUF files were found in {0}. model-index.json was not changed." -f $ProjectRoot)
    exit 1
}

$UsedIds = @{}
$Models = @(
    foreach ($File in $ModelFiles) {
        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)

        [ordered]@{
            id           = New-ModelId -Name $BaseName -UsedIds $UsedIds
            name         = $BaseName
            path         = $File.FullName
            capabilities = Get-ModelCapabilities -ModelName $BaseName -ModelPath $File.FullName
            notes        = "Auto-generated by scan_model.ps1."
        }
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
