param(
    [switch]$ForceRemote,
    [switch]$PullGenerated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_env.ps1")
$repoRoot = Get-AerRdpRepoRoot

if (-not $ForceRemote -and (Test-LocalToolchainsAvailable)) {
    Write-Host "Local toolchains detected; running verification locally..."
    Push-Location $repoRoot
    try {
        & bash "./scripts/verify-m1.sh"
        if ($LASTEXITCODE -ne 0) {
            throw "Local verification failed with exit code $LASTEXITCODE"
        }
        $builtApk = Join-Path $repoRoot "build\app\outputs\flutter-apk\app-debug.apk"
        if (Test-Path -LiteralPath $builtApk) {
            Copy-Item -LiteralPath $builtApk -Destination (Join-Path $repoRoot "aer-rdp-debug.apk") -Force
        }
    }
    finally {
        Pop-Location
    }
    exit 0
}

Write-Host "Running M1 verification via remote builder..."
& (Join-Path $PSScriptRoot "sync-to-builder.ps1")
& (Join-Path $PSScriptRoot "remote-exec.ps1") -Command "./scripts/verify-m1.sh"
if ($PullGenerated) {
    & (Join-Path $PSScriptRoot "pull-artifacts.ps1") -IncludeGenerated
} else {
    & (Join-Path $PSScriptRoot "pull-artifacts.ps1")
}
Write-Host "Remote verification and APK pull completed successfully."
