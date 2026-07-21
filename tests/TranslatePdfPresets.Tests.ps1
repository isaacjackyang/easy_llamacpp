$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'PS1\Translate_PDF.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

$definition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Resolve-PdfProcessingPreset'
    }, $true) | Select-Object -First 1
if (-not $definition) { throw 'Function not found: Resolve-PdfProcessingPreset' }
. ([scriptblock]::Create($definition.Extent.Text))

foreach ($functionName in @(
    'Get-PaddleHealthUrl',
    'Test-PaddleOcrHealth',
    'Resolve-PaddleOcrProjectRoot',
    'Stop-OwnedPaddleOcrService',
    'Start-PaddleOcrServiceIfNeeded'
)) {
    $functionDefinition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    if (-not $functionDefinition) { throw "Function not found: $functionName" }
    . ([scriptblock]::Create($functionDefinition.Extent.Text))
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message (expected '$Expected', got '$Actual')"
    }
}

$layout = Resolve-PdfProcessingPreset -Mode 'layout'
Assert-Equal 'layout' $layout.Mode 'Layout mode must remain the default preset'
Assert-Equal 'False' $layout.Compatibility 'Layout mode must not imply compatibility mode'
Assert-Equal 'False' $layout.DisableRichTextTranslate 'Layout mode must preserve Rich Text'
Assert-Equal 'True' $layout.AutoOcrWorkaround 'Layout mode must use automatic OCR detection'
Assert-Equal 'False' $layout.OcrWorkaround 'Layout mode must not force the white-background OCR workaround'
Assert-Equal 'redraw' $layout.ImageTextMode 'Layout mode must translate raster image text'

$scan = Resolve-PdfProcessingPreset -Mode 'scan'
Assert-Equal 'True' $scan.OcrWorkaround 'Scan mode must force the OCR workaround'
Assert-Equal 'False' $scan.AutoOcrWorkaround 'Forced and automatic OCR must be mutually exclusive'
Assert-Equal 'False' $scan.Compatibility 'Scan mode must not silently disable Rich Text through compatibility mode'

$compatibility = Resolve-PdfProcessingPreset -Mode 'compatibility'
Assert-Equal 'True' $compatibility.Compatibility 'Compatibility mode must enable enhanced compatibility'
Assert-Equal 'True' $compatibility.DisableRichTextTranslate 'Compatibility mode must expose the implied Rich Text state'
Assert-Equal 'off' $compatibility.ImageTextMode 'Compatibility mode must leave raster images untouched by default'
Assert-Equal 'False' $compatibility.OcrWorkaround 'Compatibility mode must not force OCR'
Assert-Equal 'False' $compatibility.AutoOcrWorkaround 'Compatibility mode must not auto-enable OCR'

$legacyStable = Resolve-PdfProcessingPreset -Mode 'stable'
Assert-Equal 'layout' $legacyStable.Mode 'Legacy stable mode must map to layout mode'
Assert-Equal 'False' $legacyStable.Compatibility 'Legacy stable mode must no longer disable Rich Text indirectly'

$legacyFast = Resolve-PdfProcessingPreset -Mode 'fast'
Assert-Equal 'True' $legacyFast.UseLlmBatch 'Legacy fast mode must retain batch translation'
Assert-Equal 'True' $legacyFast.SkipScannedDetection 'Legacy fast mode must retain scan-detection bypass'
Assert-Equal 'off' $legacyFast.ImageTextMode 'Legacy fast mode must retain its no-redraw behavior'

$manual = Resolve-PdfProcessingPreset -Mode 'manual'
Assert-Equal 'manual' $manual.Mode 'Manual mode must identify itself after inheriting safe defaults'
Assert-Equal 'True' $manual.AutoOcrWorkaround 'Manual mode must begin with automatic OCR defaults'

$noImageRedraw = Resolve-PdfProcessingPreset -Mode 'layout' -RequestedImageTextMode 'off'
Assert-Equal 'off' $noImageRedraw.ImageTextMode 'An explicit image text mode must override the preset default'

$source = Get-Content -Raw -LiteralPath $sourcePath
if ($source -notmatch '\[string\]\$ProcessingMode = "layout"') {
    throw 'The public CLI default must be layout mode'
}
if ($source -notmatch 'if \(\$ResolvedCompatibility\) \{ \$ResolvedDisableRichTextTranslate = \$true \}') {
    throw 'Effective Rich Text state must be synchronized with compatibility mode'
}
Assert-Equal 'http://127.0.0.1:8765/v1/health' `
    (Get-PaddleHealthUrl 'http://127.0.0.1:8765') `
    'Paddle root URL must map to its versioned health endpoint'
Assert-Equal 'http://127.0.0.1:8765/v1/health' `
    (Get-PaddleHealthUrl 'http://127.0.0.1:8765/v1') `
    'Paddle /v1 URL must not duplicate the version path'
if ($source -notmatch 'Start-PaddleOcrServiceIfNeeded') {
    throw 'The translation entry point must automatically start Paddle OCR when needed'
}
if ($source -notmatch 'finally\s*\{[\s\S]*Stop-OwnedPaddleOcrService') {
    throw 'An automatically started Paddle service must be stopped from a finally block'
}

Write-Host 'PDF translation preset tests passed.'
