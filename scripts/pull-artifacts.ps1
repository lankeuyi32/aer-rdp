param(
    [switch]$IncludeGenerated,
    [string]$OutputName = "aer-rdp-debug.apk"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_env.ps1")
$cfg = Import-AerRdpEnv
$repoRoot = $cfg.RepoRoot

$sshOpts = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=20",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4"
)

$localApkPath = Join-Path $repoRoot $OutputName

Write-Host "Pulling installable APK from $($cfg.Target):$($cfg.RemoteDir)/build/app/outputs/flutter-apk/app-debug.apk -> $localApkPath ..."
& scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$($cfg.RemoteDir)/build/app/outputs/flutter-apk/app-debug.apk" $localApkPath
if ($LASTEXITCODE -ne 0) {
    throw "Failed to pull app-debug.apk (exit $LASTEXITCODE)"
}

$apkInfo = Get-Item -LiteralPath $localApkPath
Write-Host "Pulled APK: $($apkInfo.FullName) ($($apkInfo.Length) bytes)"

if ($IncludeGenerated) {
    Write-Host "Pulling generated Cargo.lock and FRB source bindings..."
    & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$($cfg.RemoteDir)/Cargo.lock" (Join-Path $repoRoot "Cargo.lock")
    if ($LASTEXITCODE -ne 0) { throw "Failed to pull Cargo.lock" }

    & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$($cfg.RemoteDir)/crates/rdp-ffi/src/frb_generated.rs" (Join-Path $repoRoot "crates\rdp-ffi\src\frb_generated.rs")
    if ($LASTEXITCODE -ne 0) { throw "Failed to pull frb_generated.rs" }

    $stamp = [guid]::NewGuid().ToString("N")
    $localRustTgz = Join-Path ([System.IO.Path]::GetTempPath()) "aer-rdp-rust-dart-$stamp.tgz"
    $remoteRustTgz = "/tmp/aer-rdp-rust-dart-$stamp.tgz"
    $localRustDartDir = Join-Path $repoRoot "lib\src\rust"
    New-Item -ItemType Directory -Force -Path $localRustDartDir | Out-Null

    try {
        $packCmd = "set -euo pipefail; tar -czf $remoteRustTgz -C $($cfg.RemoteDir)/lib/src/rust ."
        $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($packCmd + "`n"))
        & ssh @sshOpts -p $cfg.Port -i $cfg.KeyPath $cfg.Target "echo '$b64' | base64 -d | bash -s"
        if ($LASTEXITCODE -ne 0) { throw "Failed to pack lib/src/rust on remote" }

        & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$remoteRustTgz" $localRustTgz
        if ($LASTEXITCODE -ne 0) { throw "Failed to pull lib/src/rust archive" }

        & ssh @sshOpts -p $cfg.Port -i $cfg.KeyPath $cfg.Target "rm -f $remoteRustTgz"
        & tar.exe -xzf $localRustTgz -C $localRustDartDir
        if ($LASTEXITCODE -ne 0) { throw "Failed to extract lib/src/rust archive" }
    }
    finally {
        if (Test-Path -LiteralPath $localRustTgz) {
            Remove-Item -LiteralPath $localRustTgz -Force -ErrorAction SilentlyContinue
        }
    }
}
