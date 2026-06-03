[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$ServerExe,
    [Parameter(Mandatory = $true)]
    [string]$ServerArgsBase64,
    [Parameter(Mandatory = $true)]
    [string]$StdOutLog,
    [Parameter(Mandatory = $true)]
    [string]$StdErrLog,
    [Parameter(Mandatory = $true)]
    [string]$PidFile,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeOwnerStateFile,
    [Parameter(Mandatory = $true)]
    [string]$SupervisorPidFile,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogPidFile,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogLog,
    [Parameter(Mandatory = $true)]
    [string]$WatchdogScriptPath,
    [Parameter(Mandatory = $true)]
    [string]$SessionId,
    [ValidateSet("background", "foreground")]
    [string]$LaunchMode = "background",
    [int]$Port = 8080,
    [string]$ModelPath = $null,
    [string]$MmprojPath = $null,
    [int]$WatchdogIntervalSec = 15
)

$ErrorActionPreference = "Stop"

function ConvertTo-Base64Json {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $Json = $Value | ConvertTo-Json -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Json))
}

if (-not (Test-Path -LiteralPath $WatchdogScriptPath)) {
    throw "Cannot find unified watchdog script: $WatchdogScriptPath"
}

$ServerExeCandidates = @(
    $ServerExe
    (Join-Path $ProjectRoot "bin\llama-server.exe")
    (Join-Path $ProjectRoot "llama-server.exe")
) | Select-Object -Unique

$WatchdogArgs = @(
    "-NoLogo"
    "-NoProfile"
    "-ExecutionPolicy"
    "Bypass"
    "-File"
    $WatchdogScriptPath
    "-ProjectRoot"
    $ProjectRoot
    "-RuntimeOwnerStateFile"
    $RuntimeOwnerStateFile
    "-PidFile"
    $PidFile
    "-SupervisorPidFile"
    $SupervisorPidFile
    "-WatchdogPidFile"
    $WatchdogPidFile
    "-WatchdogLog"
    $WatchdogLog
    "-ServerExeCandidatesBase64"
    (ConvertTo-Base64Json -Value @($ServerExeCandidates))
    "-Mode"
    "launch"
    "-ServerExe"
    $ServerExe
    "-ServerArgsBase64"
    $ServerArgsBase64
    "-StdOutLog"
    $StdOutLog
    "-StdErrLog"
    $StdErrLog
    "-SessionId"
    $SessionId
    "-LaunchMode"
    $LaunchMode
    "-Port"
    ([string]$Port)
    "-IntervalSec"
    ([string]$WatchdogIntervalSec)
)

if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
    $WatchdogArgs += @(
        "-ModelPath"
        $ModelPath
    )
}

if (-not [string]::IsNullOrWhiteSpace($MmprojPath)) {
    $WatchdogArgs += @(
        "-MmprojPath"
        $MmprojPath
    )
}

& powershell.exe @WatchdogArgs
exit $LASTEXITCODE
