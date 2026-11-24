param(
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$BundleId = 'com.example.myiphoneapp'
)

$ErrorActionPreference = 'Stop'
$downloadFolder = Join-Path (Split-Path -Parent $PSScriptRoot) 'downloads'
$devicePython = Join-Path $downloadFolder 'device-tools\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $devicePython)) {
    throw 'Install the Windows USB log tool in downloads\device-tools as described in README.md.'
}

$logFile = Join-Path $downloadFolder 'commute.log'
$temporaryFile = Join-Path $downloadFolder ([guid]::NewGuid().ToString() + '.log')
try {
    & $devicePython -m pymobiledevice3 apps pull --documents $BundleId /Documents/commute.log $temporaryFile
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryFile)) {
        throw 'Could not read commute.log. Unlock the iPhone, confirm computer trust, and check the installed app Bundle ID.'
    }
    Move-Item -LiteralPath $temporaryFile -Destination $logFile -Force
    Get-Item -LiteralPath $logFile
} finally {
    if (Test-Path -LiteralPath $temporaryFile) {
        Remove-Item -LiteralPath $temporaryFile
    }
}
