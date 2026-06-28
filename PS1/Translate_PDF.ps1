[CmdletBinding()]
param(
    [string]$PdfPath = "",
    [ValidateSet("en", "zh-TW", "zh-CN")]
    [string]$SourceLanguage = "en",
    [ValidateSet("en", "zh-TW", "zh-CN")]
    [string]$TargetLanguage = "zh-TW",
    [ValidateSet("mono", "dual", "both")]
    [string]$OutputMode = "both",
    [string]$OutputDir = "",
    [string]$BaseUrl = "http://127.0.0.1:8080/v1",
    [string]$Model = "",
    [string]$Pages = "",
    [string]$WrapperPath = "",
    [switch]$UseLlmBatch,
    [switch]$Compatibility,
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
        $answer = $answer.Replace("１", "1").Replace("２", "2").Replace("３", "3")
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        if ($Choices.ContainsKey($answer)) { return $answer }
        Write-Host "無效選項，請重試。" -ForegroundColor Red
    }
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

if (-not $NonInteractive) {
    if ([string]::IsNullOrWhiteSpace($PdfPath)) {
        Write-Host "提示：可以把 PDF 拖進此視窗，再按 Enter。" -ForegroundColor DarkGray
        $PdfPath = (Read-Host "PDF 路徑").Trim().Trim('"')
    }

    $languageChoice = Read-Menu "翻譯方向" @{
        "1" = "英文 -> 繁體中文"
        "2" = "英文 -> 簡體中文"
        "3" = "繁體中文 -> 英文"
    } "1"
    switch ($languageChoice) {
        "1" { $SourceLanguage = "en"; $TargetLanguage = "zh-TW" }
        "2" { $SourceLanguage = "en"; $TargetLanguage = "zh-CN" }
        "3" { $SourceLanguage = "zh-TW"; $TargetLanguage = "en" }
    }

    $modeChoice = Read-Menu "輸出格式" @{
        "1" = "翻譯單語版 + 原文／譯文雙語版"
        "2" = "只輸出翻譯單語版"
        "3" = "只輸出原文／譯文雙語版"
    } "1"
    $OutputMode = @{ "1" = "both"; "2" = "mono"; "3" = "dual" }[$modeChoice]

    $batchChoice = Read-Menu "LLM Batch（翻譯速度／模型相容性）" @{
        "1" = "啟用 Batch：較快，模型需正確回傳批次 JSON"
        "2" = "停用 Batch：逐段翻譯，較慢但最穩定"
    } "1"
    $UseLlmBatch = ($batchChoice -eq "1")

    $compatibilityChoice = Read-Menu "PDF 排版相容性" @{
        "1" = "標準模式"
        "2" = "增強相容模式：遇到 PDF 閱讀器或樣式問題時使用"
    } "1"
    $Compatibility = ($compatibilityChoice -eq "2")

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

if ([string]::IsNullOrWhiteSpace($PdfPath)) { throw "必須指定 PDF 路徑。" }
$pdf = Get-Item -LiteralPath $PdfPath -ErrorAction Stop
if ($pdf.PSIsContainer -or $pdf.Extension -ne ".pdf") { throw "輸入必須是 PDF：$($pdf.FullName)" }

if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $models[0] }
if ($models -notcontains $Model) {
    throw "本機端點沒有模型 '$Model'。可用模型：$($models -join ', ')"
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
Write-Host "  LLM Batch：     $(if ($UseLlmBatch) { '啟用（較快）' } else { '停用（逐段 fallback）' })"
Write-Host "  PDF Compatibility：$(if ($Compatibility) { '增強' } else { '標準' })"
Write-Host ""

if (-not $NonInteractive -and -not $DryRun) {
    $confirm = Read-Host "按 Enter 開始，輸入 N 取消"
    if ($confirm -match "^[Nn]$") {
        Write-Host "已取消。"
        exit 0
    }
}

$arguments = @{
    PdfPath = $pdf.FullName
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
if (-not $UseLlmBatch) { $arguments.DisableLlmBatch = $true }
if ($Compatibility) { $arguments.Compatibility = $true }
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
    Write-Host ""
    Write-Host "翻譯完成。輸出資料夾：$OutputDir" -ForegroundColor Green
}
