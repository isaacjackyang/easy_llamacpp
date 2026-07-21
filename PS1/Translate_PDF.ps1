[CmdletBinding()]
param(
    [string]$PdfPath = "",
    [ValidateSet("en", "zh-TW", "zh-CN")]
    [string]$SourceLanguage = "en",
    [ValidateSet("en", "zh-TW", "zh-CN")]
    [string]$TargetLanguage = "zh-TW",
    [ValidateSet("mono", "dual", "both")]
    [string]$OutputMode = "both",
    [ValidateSet("layout", "scan", "compatibility", "manual", "stable", "fast")]
    [string]$ProcessingMode = "layout",
    [ValidateSet("auto", "off", "redraw")]
    [string]$ImageTextMode = "auto",
    [ValidateSet("auto", "paddle", "rapid")]
    [string]$OcrProvider = "auto",
    [string]$PaddleOcrBaseUrl = "http://127.0.0.1:8765",
    [string]$PaddleOcrProjectRoot = "",
    [ValidateSet("auto", "gpu", "cpu")]
    [string]$PaddleOcrDevice = "auto",
    [switch]$DisablePaddleAutoStart,
    [ValidateSet("auto", "off", "always")]
    [string]$StructureAssist = "auto",
    [string]$UnlimitedOcrBaseUrl = "",
    [string]$UnlimitedOcrModel = "",
    [string]$OutputDir = "",
    [string]$BaseUrl = "http://127.0.0.1:8080/v1",
    [string]$Model = "",
    [string]$Pages = "",
    [string]$WrapperPath = "",
    [switch]$UseLlmBatch,
    [switch]$Compatibility,
    [switch]$DisableRichTextTranslate,
    [switch]$DisableTableTextTranslation,
    [switch]$DisableAutoGlossary,
    [switch]$SkipScannedDetection,
    [switch]$OcrWorkaround,
    [switch]$AutoOcrWorkaround,
    [switch]$DisableGraphicElementProcess,
    [switch]$SkipFormRender,
    [switch]$SkipCurveRender,
    [switch]$KeepWatermark,
    [switch]$NonInteractive,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Title {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "  Local PDF Translator - llama.cpp + BabelDOC" -ForegroundColor Cyan
    Write-Host "  本機 PDF 翻譯器（資料不送往外部 API）" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Read-Default([string]$Prompt, [string]$Default) {
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().Trim('"')
}

function Read-Menu([string]$Prompt, [hashtable]$Choices, [string]$Default) {
    while ($true) {
        Write-Host $Prompt -ForegroundColor Yellow
        foreach ($key in ($Choices.Keys | Sort-Object)) {
            Write-Host "  $key) $($Choices[$key])"
        }
        $answer = (Read-Host "請選擇 [$Default]").Trim()
        $answer = $answer.Replace("１", "1").Replace("２", "2").Replace("３", "3").Replace("４", "4")
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        if ($Choices.ContainsKey($answer)) { return $answer }
        Write-Host "無效選項，請重試。" -ForegroundColor Red
    }
}

function Read-Toggle([string]$Prompt, [bool]$Default) {
    $DefaultChoice = if ($Default) { "1" } else { "2" }
    $Choice = Read-Menu $Prompt @{
        "1" = "開啟"
        "2" = "關閉"
    } $DefaultChoice
    return ($Choice -eq "1")
}

function Resolve-PdfProcessingPreset {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("layout", "scan", "compatibility", "manual", "stable", "fast")]
        [string]$Mode,
        [ValidateSet("auto", "off", "redraw")]
        [string]$RequestedImageTextMode = "auto"
    )

    # Keep older shortcuts working while routing the old all-purpose stable mode
    # to the new layout-preserving default. Fast remains a non-interactive legacy
    # preset because some existing automation may still rely on it.
    $NormalizedMode = if ($Mode -eq "stable") { "layout" } else { $Mode }
    $Preset = switch ($NormalizedMode) {
        "layout" {
            [ordered]@{
                Mode = "layout"
                UseLlmBatch = $false
                Compatibility = $false
                DisableRichTextTranslate = $false
                TranslateTableText = $true
                AutoExtractGlossary = $true
                SkipScannedDetection = $false
                OcrWorkaround = $false
                AutoOcrWorkaround = $true
                ProcessGraphics = $true
                RenderForms = $true
                RenderCurves = $true
                DefaultImageTextMode = "redraw"
            }
        }
        "scan" {
            [ordered]@{
                Mode = "scan"
                UseLlmBatch = $false
                Compatibility = $false
                DisableRichTextTranslate = $false
                TranslateTableText = $true
                AutoExtractGlossary = $true
                SkipScannedDetection = $false
                OcrWorkaround = $true
                AutoOcrWorkaround = $false
                ProcessGraphics = $true
                RenderForms = $true
                RenderCurves = $true
                DefaultImageTextMode = "redraw"
            }
        }
        "compatibility" {
            [ordered]@{
                Mode = "compatibility"
                UseLlmBatch = $false
                Compatibility = $true
                # BabelDOC --enhance-compatibility implies this option. Keep the
                # effective state explicit so the UI cannot claim Rich Text is on.
                DisableRichTextTranslate = $true
                TranslateTableText = $true
                AutoExtractGlossary = $true
                SkipScannedDetection = $false
                OcrWorkaround = $false
                AutoOcrWorkaround = $false
                ProcessGraphics = $true
                RenderForms = $true
                RenderCurves = $true
                DefaultImageTextMode = "off"
            }
        }
        "fast" {
            [ordered]@{
                Mode = "fast"
                UseLlmBatch = $true
                Compatibility = $false
                DisableRichTextTranslate = $false
                TranslateTableText = $true
                AutoExtractGlossary = $true
                SkipScannedDetection = $true
                OcrWorkaround = $false
                AutoOcrWorkaround = $false
                ProcessGraphics = $true
                RenderForms = $true
                RenderCurves = $true
                DefaultImageTextMode = "off"
            }
        }
        "manual" {
            # Manual mode starts from the safe layout preset before prompting.
            $ManualPreset = Resolve-PdfProcessingPreset -Mode "layout" -RequestedImageTextMode $RequestedImageTextMode
            $ManualPreset.Mode = "manual"
            return $ManualPreset
        }
    }

    $Preset.ImageTextMode = if ($RequestedImageTextMode -eq "auto") {
        $Preset.DefaultImageTextMode
    }
    else {
        $RequestedImageTextMode
    }
    [pscustomobject]$Preset
}

function Assert-LocalEndpoint([string]$Url) {
    try { $uri = [Uri]$Url } catch { throw "無效的 API URL：$Url" }
    if ($uri.Scheme -notin @("http", "https")) { throw "API URL 必須使用 http 或 https。" }
    if ($uri.Host -notin @("127.0.0.1", "localhost", "::1")) {
        throw "此工具只允許本機 llama.cpp 端點（127.0.0.1、localhost 或 ::1）：$Url"
    }
}

function Get-LocalModels([string]$Url) {
    try {
        $response = Invoke-RestMethod -Uri ($Url.TrimEnd("/") + "/models") -Method Get -TimeoutSec 10
        return @($response.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    }
    catch {
        throw "無法連線本機 llama.cpp：$Url`n請先執行 Start.cmd 啟動模型。`n$($_.Exception.Message)"
    }
}

function Assert-LlamaVisionCapability([string]$Url) {
    $apiRoot = $Url.TrimEnd("/")
    if ($apiRoot -match "(?i)/v1$") {
        $apiRoot = $apiRoot.Substring(0, $apiRoot.Length - 3)
    }
    $propsUrl = $apiRoot.TrimEnd("/") + "/props"
    try {
        $props = Invoke-RestMethod -Uri $propsUrl -Method Get -TimeoutSec 10
    }
    catch {
        throw "無法從 llama.cpp /props 驗證目前模型的視覺能力：$propsUrl`n$($_.Exception.Message)"
    }
    if (-not $props.PSObject.Properties["modalities"] -or
        -not $props.modalities -or
        -not $props.modalities.PSObject.Properties["vision"]) {
        throw "目前 llama.cpp 未回報 modalities.vision，無法確認模型已掛載視覺 projector（mmproj）。"
    }
    if (-not [bool]$props.modalities.vision) {
        $loadedModel = if ($props.PSObject.Properties["model_alias"]) { [string]$props.model_alias } else { "目前模型" }
        throw "llama.cpp 目前載入的 '$loadedModel' 沒有視覺能力。請用 Start.cmd 重新啟動並掛載相符的 mmproj。"
    }
    return $props
}

function Assert-BabelDocPythonDependencies([string]$PythonPath) {
    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        throw "找不到 BabelDOC venv Python：$PythonPath"
    }
    $requirements = @(
        [pscustomobject]@{ Name = "PyMuPDF"; Module = "fitz"; Distribution = "PyMuPDF" },
        [pscustomobject]@{ Name = "Pillow"; Module = "PIL"; Distribution = "Pillow" },
        [pscustomobject]@{ Name = "OpenCV"; Module = "cv2"; Distribution = "opencv-python" },
        [pscustomobject]@{ Name = "NumPy"; Module = "numpy"; Distribution = "numpy" },
        [pscustomobject]@{ Name = "requests"; Module = "requests"; Distribution = "requests" },
        [pscustomobject]@{ Name = "RapidOCR"; Module = "rapidocr_onnxruntime"; Distribution = "rapidocr-onnxruntime" }
    )
    $result = @()
    $missing = @()
    foreach ($requirement in $requirements) {
        $probe = "import importlib, importlib.metadata as md; importlib.import_module('$($requirement.Module)'); print(md.version('$($requirement.Distribution)'))"
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $rawResult = @(& $PythonPath -c $probe 2>&1)
        $probeExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($probeExitCode -eq 0) {
            $result += [pscustomobject]@{ Name = $requirement.Name; Version = ([string]$rawResult[-1]).Trim() }
        }
        else {
            $missing += [pscustomobject]@{ Name = $requirement.Name; Error = ($rawResult -join [Environment]::NewLine) }
        }
    }
    if ($missing.Count -gt 0) {
        $details = $missing | ForEach-Object { "  - $($_.Name)：$($_.Error)" }
        throw "BabelDOC venv 缺少或無法載入必要套件：`n$($details -join [Environment]::NewLine)`nPython：$PythonPath"
    }
    return $result
}

Write-Title

if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
    $WrapperPath = Join-Path $env:LOCALAPPDATA "hermes\skills\babeldoc-pdf-translate\scripts\translate-pdf.ps1"
}
if (-not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) {
    throw "找不到 guarded BabelDOC wrapper：$WrapperPath"
}

Assert-LocalEndpoint $BaseUrl
$models = @(Get-LocalModels $BaseUrl)
if ($models.Count -eq 0) { throw "本機 llama.cpp 沒有回報任何模型。" }

$BabelDocProjectRoot = [Environment]::GetEnvironmentVariable("BABELDOC_PROJECT_ROOT")
if ([string]::IsNullOrWhiteSpace($BabelDocProjectRoot)) {
    $RepositoryParent = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $BabelDocProjectRoot = Join-Path $RepositoryParent "BabelDOC"
}
$ImagePython = Join-Path $BabelDocProjectRoot ".venv\Scripts\python.exe"

if (-not $NonInteractive) {
    if ([string]::IsNullOrWhiteSpace($PdfPath)) {
        Write-Host "提示：可以把 PDF 拖進此視窗，再按 Enter。" -ForegroundColor DarkGray
        $PdfPath = (Read-Host "PDF 路徑").Trim().Trim('"')
    }

    $processingChoice = Read-Menu "處理模式" @{
        "1" = "版面優先：Rich Text、圖片文字重繪、OCR 自動判斷（預設）"
        "2" = "掃描文件：PP-OCRv6 主辨識／RapidOCR 回退、強制 OCR 補救"
        "3" = "相容救援：增強 PDF 相容性、停用 Rich Text"
        "4" = "手動調參：逐項設定翻譯與 PDF 處理"
    } $(switch ($ProcessingMode) {
        "scan" { "2" }
        "compatibility" { "3" }
        "manual" { "4" }
        default { "1" }
    })
    $ProcessingMode = @{ "1" = "layout"; "2" = "scan"; "3" = "compatibility"; "4" = "manual" }[$processingChoice]

    $languageChoice = Read-Menu "翻譯方向" @{
        "1" = "英文 -> 繁體中文"
        "2" = "繁體中文 -> 英文"
    } "1"
    switch ($languageChoice) {
        "1" { $SourceLanguage = "en"; $TargetLanguage = "zh-TW" }
        "2" { $SourceLanguage = "zh-TW"; $TargetLanguage = "en" }
    }

    $modeChoice = Read-Menu "輸出格式" @{
        "1" = "翻譯單語版 + 原文／譯文雙語版"
        "2" = "只輸出翻譯單語版"
        "3" = "只輸出原文／譯文雙語版"
    } "1"
    $OutputMode = @{ "1" = "both"; "2" = "mono"; "3" = "dual" }[$modeChoice]

}

function Get-PaddleHealthUrl([string]$BaseUrl) {
    try { $uri = [Uri]$BaseUrl } catch { throw "無效的 Paddle OCR URL：$BaseUrl" }
    if ($uri.Scheme -ne "http" -or $uri.Host -notin @("127.0.0.1", "localhost", "::1")) {
        throw "Paddle OCR 自動啟動只允許本機 HTTP 端點：$BaseUrl"
    }
    $root = $BaseUrl.TrimEnd("/")
    if ($root -match "(?i)/v1$") { $root = $root.Substring(0, $root.Length - 3) }
    return $root.TrimEnd("/") + "/v1/health"
}

function Test-PaddleOcrHealth([string]$BaseUrl, [int]$TimeoutSeconds = 3) {
    try {
        $health = Invoke-RestMethod -Uri (Get-PaddleHealthUrl $BaseUrl) -Method Get -TimeoutSec $TimeoutSeconds
        return ($health.status -eq "ok")
    }
    catch { return $false }
}

function Resolve-PaddleOcrProjectRoot([string]$RequestedRoot) {
    $baseRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $baseRoot = [IO.Path]::GetFullPath($RequestedRoot)
    }
    if ($null -eq $baseRoot) {
        $environmentRoot = [Environment]::GetEnvironmentVariable("PADDLEOCR_PROJECT_ROOT")
        if (-not [string]::IsNullOrWhiteSpace($environmentRoot)) {
            $baseRoot = [IO.Path]::GetFullPath($environmentRoot)
        }
    }
    if ($null -eq $baseRoot) {
        $repositoryParent = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $baseRoot = [IO.Path]::GetFullPath((Join-Path $repositoryParent "lazy_paddleocr"))
    }

    # A development checkout may also contain the complete built portable
    # bundle. Prefer that bundle because its runtime and 4+ GB model cache are
    # self-contained; using the checkout root would create a second cache and
    # make PaddleX download the same models again.
    $portableRoot = Join-Path $baseRoot "portable\LazyPaddleOCR"
    $portableReady = (
        (Test-Path -LiteralPath (Join-Path $portableRoot "runtime\python\python.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $portableRoot "scripts\start-server.ps1") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $portableRoot "model_cache\official_models\PP-OCRv6_medium_det") -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $portableRoot "model_cache\official_models\PP-OCRv6_medium_rec") -PathType Container)
    )
    return $(if ($portableReady) { [IO.Path]::GetFullPath($portableRoot) } else { $baseRoot })
}

function Stop-OwnedPaddleOcrService($Ownership) {
    if ($null -eq $Ownership) { return }
    $wrapper = $Ownership.WrapperProcess
    $descendantIds = @()
    if ($null -ne $wrapper) {
        $processSnapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $parentIds = @([int]$wrapper.Id)
        while ($parentIds.Count -gt 0) {
            $children = @($processSnapshot | Where-Object { $parentIds -contains [int]$_.ParentProcessId })
            if ($children.Count -eq 0) { break }
            $childIds = @($children | ForEach-Object { [int]$_.ProcessId })
            $descendantIds += $childIds
            $parentIds = $childIds
        }
    }
    $listenerPid = [int]$Ownership.ListenerPid
    if ($listenerPid -gt 0) {
        Stop-Process -Id $listenerPid -Force -ErrorAction SilentlyContinue
    }
    [array]::Reverse($descendantIds)
    foreach ($descendantId in $descendantIds) {
        Stop-Process -Id $descendantId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $wrapper) {
        try { $wrapper.Refresh() } catch {}
        if (-not $wrapper.HasExited) {
            Stop-Process -Id $wrapper.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-PaddleOcrServiceIfNeeded(
    [string]$BaseUrl,
    [string]$ProjectRoot,
    [string]$Device,
    [int]$ReadyTimeoutSeconds = 120
) {
    if (Test-PaddleOcrHealth $BaseUrl 4) {
        Write-Host "  [OK] Paddle OCR 已在運行：$BaseUrl" -ForegroundColor Green
        return $null
    }

    $resolvedRoot = Resolve-PaddleOcrProjectRoot $ProjectRoot
    $startScript = Join-Path $resolvedRoot "scripts\start-server.ps1"
    if (-not (Test-Path -LiteralPath $startScript -PathType Leaf)) {
        Write-Warning "找不到 Paddle OCR 啟動器：$startScript；影像階段將回退 RapidOCR。"
        return $null
    }

    $uri = [Uri]$BaseUrl
    $port = if ($uri.IsDefaultPort) { 80 } else { $uri.Port }
    Write-Host "[Paddle OCR] 服務未運行，正在自動啟動（device=$Device, port=$port）..." -ForegroundColor Cyan
    Write-Host "  runtime/model cache：$resolvedRoot" -ForegroundColor DarkGray
    $wrapper = $null
    $ownership = $null
    try {
        $quotedStartScript = '"' + $startScript + '"'
        $wrapper = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $quotedStartScript, "-Port", [string]$port,
            "-Device", $Device, "-NoBrowser"
        ) -PassThru -WindowStyle Hidden
        $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            $wrapper.Refresh()
            if ($wrapper.HasExited) {
                throw "Paddle OCR 啟動器提前結束（exit code $($wrapper.ExitCode)）。"
            }
            if (Test-PaddleOcrHealth $BaseUrl 10) {
                $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalAddress -in @("127.0.0.1", "0.0.0.0", "::1", "::") } |
                    Select-Object -First 1
                $ownership = [pscustomobject]@{
                    WrapperProcess = $wrapper
                    ListenerPid = if ($listener) { [int]$listener.OwningProcess } else { 0 }
                }
                Write-Host "  [OK] Paddle OCR ready：$BaseUrl" -ForegroundColor Green
                return $ownership
            }
            Start-Sleep -Seconds 2
        }
        throw "Paddle OCR 在 $ReadyTimeoutSeconds 秒內未 ready。"
    }
    catch {
        if ($null -eq $ownership -and $null -ne $wrapper) {
            $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalAddress -in @("127.0.0.1", "0.0.0.0", "::1", "::") } |
                Select-Object -First 1
            $listenerPid = if ($listener) { [int]$listener.OwningProcess } else { 0 }
            $ownership = [pscustomobject]@{
                WrapperProcess = $wrapper
                ListenerPid = $listenerPid
            }
        }
        Stop-OwnedPaddleOcrService $ownership
        Write-Warning "$($_.Exception.Message) 影像階段將回退 RapidOCR。"
        return $null
    }
}

$Preset = Resolve-PdfProcessingPreset -Mode $ProcessingMode -RequestedImageTextMode $ImageTextMode
$ProcessingMode = $Preset.Mode
$ResolvedUseLlmBatch = $Preset.UseLlmBatch
$ResolvedCompatibility = $Preset.Compatibility
$ResolvedDisableRichTextTranslate = $Preset.DisableRichTextTranslate
$ResolvedTranslateTableText = $Preset.TranslateTableText
$ResolvedAutoExtractGlossary = $Preset.AutoExtractGlossary
$ResolvedSkipScannedDetection = $Preset.SkipScannedDetection
$ResolvedOcrWorkaround = $Preset.OcrWorkaround
$ResolvedAutoOcrWorkaround = $Preset.AutoOcrWorkaround
$ResolvedProcessGraphics = $Preset.ProcessGraphics
$ResolvedRenderForms = $Preset.RenderForms
$ResolvedRenderCurves = $Preset.RenderCurves
$ResolvedImageTextMode = $Preset.ImageTextMode

if (-not $NonInteractive) {
    if ($ProcessingMode -eq "manual") {
        $ResolvedUseLlmBatch = Read-Toggle "LLM Batch（快，但模型必須穩定回傳批次 JSON）" $false
        $ResolvedCompatibility = Read-Toggle "增強 PDF 相容性" $false
        if ($ResolvedCompatibility) {
            $ResolvedDisableRichTextTranslate = $true
            Write-Host "  相容模式會停用 Rich Text，以避免顯示與實際參數不一致。" -ForegroundColor DarkYellow
        }
        else {
            $ResolvedDisableRichTextTranslate = -not (Read-Toggle "Rich Text 翻譯（保留段落內樣式 placeholder）" $true)
        }
        $ResolvedTranslateTableText = Read-Toggle "表格文字翻譯（實驗性）" $true
        $ResolvedAutoExtractGlossary = Read-Toggle "自動術語擷取" $true

        $ocrChoice = Read-Menu "OCR workaround" @{
            "1" = "關閉：一般文字型 PDF"
            "2" = "自動：只在偵測到重度掃描文件時啟用"
            "3" = "強制：白底黑字遮罩補救，彩色背景慎用"
        } "2"
        $ResolvedOcrWorkaround = ($ocrChoice -eq "3")
        $ResolvedAutoOcrWorkaround = ($ocrChoice -eq "2")
        $ResolvedSkipScannedDetection = if ($ocrChoice -eq "1") { Read-Toggle "略過掃描文件偵測（非掃描 PDF 可加速）" $false } else { $false }

        $ResolvedProcessGraphics = Read-Toggle "處理圖形元素（graphic）" $true
        $ResolvedRenderForms = Read-Toggle "渲染 PDF forms" $true
        $ResolvedRenderCurves = Read-Toggle "渲染 PDF curves" $true
        $imageTextChoice = Read-Menu "圖片內文字" @{
            "1" = "翻譯並重繪：PP-OCRv6 主辨識、RapidOCR 回退、llama.cpp 翻譯"
            "2" = "不處理：保留原始圖片"
        } $(if ($ImageTextMode -eq "off") { "2" } else { "1" })
        $ResolvedImageTextMode = if ($imageTextChoice -eq "1") { "redraw" } else { "off" }
    }

    if ($models.Count -gt 1) {
        Write-Host "本機模型" -ForegroundColor Yellow
        for ($i = 0; $i -lt $models.Count; $i++) { Write-Host "  $($i + 1)) $($models[$i])" }
        while ($true) {
            $modelChoice = Read-Host "請選擇 [1]"
            if ([string]::IsNullOrWhiteSpace($modelChoice)) { $modelChoice = "1" }
            $index = 0
            if ([int]::TryParse($modelChoice, [ref]$index) -and $index -ge 1 -and $index -le $models.Count) {
                $Model = $models[$index - 1]
                break
            }
            Write-Host "無效選項，請重試。" -ForegroundColor Red
        }
    }

    $Pages = Read-Default "頁碼（all 或 1,3-5）" $(if ($Pages) { $Pages } else { "all" })
    if ($Pages -eq "all") { $Pages = "" }
}

# Explicit command-line switches override preset defaults. OCR choices are kept
# mutually exclusive so BabelDOC never receives contradictory scan flags.
if ($UseLlmBatch) { $ResolvedUseLlmBatch = $true }
if ($Compatibility) {
    $ResolvedCompatibility = $true
    $ResolvedDisableRichTextTranslate = $true
}
if ($DisableRichTextTranslate) { $ResolvedDisableRichTextTranslate = $true }
if ($DisableTableTextTranslation) { $ResolvedTranslateTableText = $false }
if ($DisableAutoGlossary) { $ResolvedAutoExtractGlossary = $false }
if ($DisableGraphicElementProcess) { $ResolvedProcessGraphics = $false }
if ($SkipFormRender) { $ResolvedRenderForms = $false }
if ($SkipCurveRender) { $ResolvedRenderCurves = $false }

if ($OcrWorkaround) {
    $ResolvedOcrWorkaround = $true
    $ResolvedAutoOcrWorkaround = $false
    $ResolvedSkipScannedDetection = $false
}
elseif ($AutoOcrWorkaround) {
    $ResolvedOcrWorkaround = $false
    $ResolvedAutoOcrWorkaround = $true
    $ResolvedSkipScannedDetection = $false
}
elseif ($SkipScannedDetection) {
    $ResolvedOcrWorkaround = $false
    $ResolvedAutoOcrWorkaround = $false
    $ResolvedSkipScannedDetection = $true
}

# Compatibility always disables Rich Text inside BabelDOC. Mirror that implied
# behavior explicitly for command construction and truthful status reporting.
if ($ResolvedCompatibility) { $ResolvedDisableRichTextTranslate = $true }

Write-Host "啟動檢查" -ForegroundColor Yellow
if ($ResolvedImageTextMode -eq "redraw") {
    $llamaProps = Assert-LlamaVisionCapability $BaseUrl
    $loadedModelLabel = if ($llamaProps.PSObject.Properties["model_alias"]) { [string]$llamaProps.model_alias } else { $models[0] }
    Write-Host "  [OK] llama.cpp 視覺能力：$loadedModelLabel（modalities.vision = true）" -ForegroundColor Green
    $dependencyStatus = @(Assert-BabelDocPythonDependencies $ImagePython)
    foreach ($dependency in $dependencyStatus) {
        Write-Host "  [OK] $($dependency.name) $($dependency.version)" -ForegroundColor Green
    }
    Write-Host "  BabelDOC Python：$ImagePython" -ForegroundColor DarkGray
}
else {
    Write-Host "  [OK] 圖片文字重繪已停用；略過視覺模型與 OCR 檢查。" -ForegroundColor Green
}
Write-Host ""

if ([string]::IsNullOrWhiteSpace($PdfPath)) { throw "必須指定 PDF 路徑。" }
$pdf = Get-Item -LiteralPath $PdfPath -ErrorAction Stop
if ($pdf.PSIsContainer -or $pdf.Extension -ne ".pdf") { throw "輸入必須是 PDF：$($pdf.FullName)" }

if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $models[0] }
if ($models -notcontains $Model) {
    $RequestedModelFile = [IO.Path]::GetFileName($Model)
    $FileNameMatches = @($models | Where-Object {
        [IO.Path]::GetFileName([string]$_) -eq $RequestedModelFile
    })
    if ($FileNameMatches.Count -eq 1) {
        $Model = $FileNameMatches[0]
    }
    elseif ($FileNameMatches.Count -gt 1) {
        throw "模型檔名 '$RequestedModelFile' 對應多個本機模型，請指定完整模型 ID：$($FileNameMatches -join ', ')"
    }
    else {
        throw "本機端點沒有模型 '$Model'。可用模型：$($models -join ', ')"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $pdf.DirectoryName ($pdf.BaseName + "_" + $TargetLanguage)
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)

Write-Host ""
Write-Host "工作摘要" -ForegroundColor Green
Write-Host "  PDF：   $($pdf.FullName)"
Write-Host "  語言：  $SourceLanguage -> $TargetLanguage"
Write-Host "  模型：  $Model"
Write-Host "  API：   $BaseUrl（本機）"
Write-Host "  輸出：  $OutputDir"
Write-Host "  模式：  $OutputMode"
$ProcessingModeLabel = switch ($ProcessingMode) {
    "layout" { "layout（版面優先）" }
    "scan" { "scan（掃描文件）" }
    "compatibility" { "compatibility（相容救援）" }
    "manual" { "manual（手動調參）" }
    "fast" { "fast（舊版相容）" }
    default { $ProcessingMode }
}
Write-Host "  處理模式：      $ProcessingModeLabel"
Write-Host "  LLM Batch：     $(if ($ResolvedUseLlmBatch) { '啟用（較快）' } else { '停用（逐段 fallback）' })"
Write-Host "  PDF Compatibility：$(if ($ResolvedCompatibility) { '增強' } else { '標準' })"
$RichTextSummary = if ($ResolvedCompatibility) {
    "停用（PDF Compatibility 隱含設定）"
}
elseif ($ResolvedDisableRichTextTranslate) {
    "停用"
}
else {
    "啟用"
}
Write-Host "  Rich Text：     $RichTextSummary"
Write-Host "  表格翻譯：      $(if ($ResolvedTranslateTableText) { '啟用（實驗性）' } else { '停用' })"
Write-Host "  自動術語：      $(if ($ResolvedAutoExtractGlossary) { '啟用' } else { '停用' })"
$ImageTextSummary = if ($ResolvedImageTextMode -eq 'redraw') {
    $AssistSummary = if ($StructureAssist -eq 'off') { '不補強' } else { "PP-StructureV3 $StructureAssist" }
    "PP-OCRv6 主辨識、RapidOCR 回退、$AssistSummary"
}
else { '不處理' }
Write-Host "  圖片文字：      $ImageTextSummary"
if ($ResolvedImageTextMode -eq 'redraw') {
    $AutoStartSummary = if ($DisablePaddleAutoStart) { "手動" } else { "自動啟動/$PaddleOcrDevice" }
    Write-Host "  Paddle OCR：    $PaddleOcrBaseUrl（provider=$OcrProvider；$AutoStartSummary）"
    if ($UnlimitedOcrBaseUrl) {
        Write-Host "  Unlimited-OCR： $UnlimitedOcrBaseUrl（只讀取補漏；Paddle 重新定位）"
    }
}
$OcrSummary = if ($ResolvedOcrWorkaround) { "強制" } elseif ($ResolvedAutoOcrWorkaround) { "自動" } elseif ($ResolvedSkipScannedDetection) { "關閉並略過掃描偵測" } else { "關閉" }
Write-Host "  OCR workaround：$OcrSummary"
Write-Host "  Graphic/Form/Curve：$(if ($ResolvedProcessGraphics) { 'on' } else { 'off' }) / $(if ($ResolvedRenderForms) { 'on' } else { 'off' }) / $(if ($ResolvedRenderCurves) { 'on' } else { 'off' })"
Write-Host ""

if (-not $NonInteractive -and -not $DryRun) {
    $confirm = Read-Host "按 Enter 開始，輸入 N 取消"
    if ($confirm -match "^[Nn]$") {
        Write-Host "已取消。"
        exit 0
    }
}

$PaddleServiceOwnership = $null
try {
if (
    $ResolvedImageTextMode -eq "redraw" -and
    -not $DryRun -and
    $OcrProvider -ne "rapid" -and
    -not $DisablePaddleAutoStart
) {
    $PaddleServiceOwnership = Start-PaddleOcrServiceIfNeeded `
        -BaseUrl $PaddleOcrBaseUrl `
        -ProjectRoot $PaddleOcrProjectRoot `
        -Device $PaddleOcrDevice
}

$TranslationPdfPath = $pdf.FullName
$ImageStagePdf = $null
if ($ResolvedImageTextMode -eq "redraw") {
    $ImageToolPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\tools\translate_pdf_images.py"))
    if (-not (Test-Path -LiteralPath $ImageToolPath -PathType Leaf)) {
        throw "找不到圖片文字重繪工具：$ImageToolPath"
    }
    if (-not (Test-Path -LiteralPath $ImagePython -PathType Leaf)) {
        throw "找不到 BabelDOC venv Python：$ImagePython"
    }

    $ImageWorkDir = Join-Path $OutputDir ".image-translation-work"
    $ImageCacheDir = Join-Path $OutputDir ".image-translation-cache"
    $ImageReportPath = Join-Path $ImageWorkDir ($pdf.BaseName + ".report.json")
    $ImageArguments = @(
        $ImageToolPath,
        "--input-pdf", $pdf.FullName,
        "--base-url", $BaseUrl,
        "--model", $Model,
        "--source-language", $SourceLanguage,
        "--target-language", $TargetLanguage,
        "--cache-dir", $ImageCacheDir,
        "--report-json", $ImageReportPath,
        "--ocr-provider", $OcrProvider,
        "--paddle-ocr-base-url", $PaddleOcrBaseUrl,
        "--structure-assist", $StructureAssist
    )
    if ($UnlimitedOcrBaseUrl) {
        if ([string]::IsNullOrWhiteSpace($UnlimitedOcrModel)) {
            throw "設定 UnlimitedOcrBaseUrl 時也必須提供 UnlimitedOcrModel。"
        }
        $ImageArguments += @(
            "--unlimited-ocr-base-url", $UnlimitedOcrBaseUrl,
            "--unlimited-ocr-model", $UnlimitedOcrModel
        )
    }
    if ($Pages) { $ImageArguments += @("--pages", $Pages) }

    Write-Host "[圖片文字] 正在掃描圖表與截圖..." -ForegroundColor Cyan
    if ($DryRun) {
        $ImageArguments += "--dry-run"
    }
    else {
        New-Item -ItemType Directory -Force -Path $ImageWorkDir | Out-Null
        $ImageStagePdf = Join-Path $ImageWorkDir $pdf.Name
        if (Test-Path -LiteralPath $ImageStagePdf) { Remove-Item -LiteralPath $ImageStagePdf -Force }
        $ImageArguments += @("--output-pdf", $ImageStagePdf)
    }

    & $ImagePython @ImageArguments
    if ($LASTEXITCODE -ne 0) {
        throw "圖片文字翻譯與重繪失敗；尚未啟動 BabelDOC。"
    }
    if (-not $DryRun) {
        $TranslationPdfPath = $ImageStagePdf
        # A fully scanned document has no paragraph layer for BabelDOC to process.
        # The hybrid OCR stage already translated and redrew its text, so finalize that PDF
        # directly and create a side-by-side original/translation dual version.
        $ScannedFinalizer = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\tools\finalize_scanned_pdf.py"))
        & $ImagePython $ScannedFinalizer `
            --original $pdf.FullName `
            --translated $ImageStagePdf `
            --output-dir $OutputDir `
            --target-language $TargetLanguage `
            --output-mode $OutputMode `
            --report-json $ImageReportPath
        $FinalizeExitCode = $LASTEXITCODE
        if ($FinalizeExitCode -eq 0) {
            Remove-Item -LiteralPath $ImageStagePdf -Force -ErrorAction SilentlyContinue
            Write-Host ""
            Write-Host "翻譯完成。輸出資料夾：$OutputDir" -ForegroundColor Green
            exit 0
        }
        if ($FinalizeExitCode -ne 3) {
            throw "掃描 PDF 輸出收尾失敗（exit code $FinalizeExitCode）。"
        }
        # The raster text has already been handled. Skip scan detection only when
        # BabelDOC's OCR workaround is not explicitly active.
        if (-not $ResolvedOcrWorkaround -and -not $ResolvedAutoOcrWorkaround) {
            $ResolvedSkipScannedDetection = $true
        }
    }
}

$arguments = @{
    PdfPath = $TranslationPdfPath
    SourceLanguage = $SourceLanguage
    TargetLanguage = $TargetLanguage
    OutputMode = $OutputMode
    OutputDir = $OutputDir
    BaseUrl = $BaseUrl
    Model = $Model
    Qps = 1
    MaxAttempts = 3
    TimeoutMinutes = 240
}
if ($Pages) { $arguments.Pages = $Pages }
if (-not $ResolvedUseLlmBatch) { $arguments.DisableLlmBatch = $true }
if ($ResolvedCompatibility) { $arguments.Compatibility = $true }
if ($ResolvedDisableRichTextTranslate) { $arguments.DisableRichTextTranslate = $true }
if ($ResolvedTranslateTableText) { $arguments.TranslateTableText = $true }
if ($ResolvedAutoExtractGlossary) { $arguments.AutoExtractGlossary = $true }
if ($ResolvedSkipScannedDetection) { $arguments.SkipScannedDetection = $true }
if ($ResolvedOcrWorkaround) { $arguments.OcrWorkaround = $true }
if ($ResolvedAutoOcrWorkaround) { $arguments.AutoEnableOcrWorkaround = $true }
if (-not $ResolvedProcessGraphics) { $arguments.DisableGraphicElementProcess = $true }
if (-not $ResolvedRenderForms) { $arguments.SkipFormRender = $true }
if (-not $ResolvedRenderCurves) { $arguments.SkipCurveRender = $true }
if (-not $KeepWatermark) { $arguments.NoWatermark = $true }
if ($DryRun) { $arguments.DryRun = $true }

Write-Host "[已啟動] 正在執行 BabelDOC；大型文件可能需要數十分鐘。" -ForegroundColor Cyan
Write-Host "[第一階段] 版面分析通常需要 1-5 分鐘，期間沒有百分比進度。" -ForegroundColor Yellow
Write-Host "只要持續看到 'BabelDOC active'（約每 30 秒）就代表仍在工作。" -ForegroundColor DarkGray
Write-Host "請保留此視窗，勿重複啟動同一份 PDF。" -ForegroundColor DarkGray
Write-Host ""

& $WrapperPath @arguments
$exitCode = $LASTEXITCODE
if ($null -eq $exitCode) { $exitCode = if ($?) { 0 } else { 1 } }

if ($exitCode -ne 0) {
    Write-Host "翻譯失敗（exit code $exitCode）。請查看上方顯示的 log 路徑。" -ForegroundColor Red
    exit $exitCode
}

if ($DryRun) {
    Write-Host "Dry run 完成；未執行翻譯。" -ForegroundColor Green
} else {
    if ($ImageStagePdf -and (Test-Path -LiteralPath $ImageStagePdf)) {
        Remove-Item -LiteralPath $ImageStagePdf -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Write-Host "翻譯完成。輸出資料夾：$OutputDir" -ForegroundColor Green
}
}
finally {
    if ($null -ne $PaddleServiceOwnership) {
        Write-Host "[Paddle OCR] 正在停止本次自動啟動的服務..." -ForegroundColor DarkGray
        Stop-OwnedPaddleOcrService $PaddleServiceOwnership
    }
}
