param(
    [switch]$IncludeGenerated,
    [ValidateSet("debug", "release")]
    [string]$Variant = "debug",
    [string]$OutputName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputName)) {
    $OutputName = if ($Variant -eq "release") { "aer-rdp.apk" } else { "aer-rdp-debug.apk" }
}
$remoteApkName = "app-$Variant.apk"

. (Join-Path $PSScriptRoot "_env.ps1")
$cfg = Import-AerRdpEnv
$repoRoot = $cfg.RepoRoot

$sshOpts = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=20",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4"
)

function ConvertTo-BashSingleQuoted {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

$stamp = [guid]::NewGuid().ToString("N")
$remoteStageLink = "/tmp/aer-rdp-pull-$stamp"
$remoteRustTgz = "/tmp/aer-rdp-rust-dart-$stamp.tgz"
$remoteDirQuoted = ConvertTo-BashSingleQuoted $cfg.RemoteDir
$remoteStageLinkQuoted = ConvertTo-BashSingleQuoted $remoteStageLink
$remoteRustTgzQuoted = ConvertTo-BashSingleQuoted $remoteRustTgz

$localApkPath = Join-Path $repoRoot $OutputName
$localRustTgz = Join-Path ([System.IO.Path]::GetTempPath()) "aer-rdp-rust-dart-$stamp.tgz"

try {
    $stageCmd = @"
set -euo pipefail
REMOTE_DIR_RAW=$remoteDirQuoted
case "`$REMOTE_DIR_RAW" in
  "~") REMOTE_DIR="`$HOME" ;;
  "~/"*) REMOTE_DIR="`$HOME/`${REMOTE_DIR_RAW:2}" ;;
  *) REMOTE_DIR="`$REMOTE_DIR_RAW" ;;
esac
if [ ! -d "`$REMOTE_DIR" ]; then
  echo "ERROR: remote directory not found: `$REMOTE_DIR" >&2
  exit 1
fi
ln -sfn "`$REMOTE_DIR" $remoteStageLinkQuoted
"@ -replace "`r`n", "`n"
    $stageB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stageCmd + "`n"))
    & ssh @sshOpts -p $cfg.Port -i $cfg.KeyPath $cfg.Target "echo '$stageB64' | base64 -d | bash -s"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve remote directory '$($cfg.RemoteDir)' (exit $LASTEXITCODE)"
    }

    Write-Host "Pulling installable APK from $($cfg.Target):$($cfg.RemoteDir)/build/app/outputs/flutter-apk/$remoteApkName -> $localApkPath ..."
    & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$remoteStageLink/build/app/outputs/flutter-apk/$remoteApkName" $localApkPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to pull $remoteApkName (exit $LASTEXITCODE)"
    }

    $apkInfo = Get-Item -LiteralPath $localApkPath
    Write-Host "Pulled APK: $($apkInfo.FullName) ($($apkInfo.Length) bytes)"

    if ($IncludeGenerated) {
        Write-Host "Pulling generated Cargo.lock and FRB source bindings..."
        & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$remoteStageLink/Cargo.lock" (Join-Path $repoRoot "Cargo.lock")
        if ($LASTEXITCODE -ne 0) { throw "Failed to pull Cargo.lock" }

        & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$remoteStageLink/crates/rdp-ffi/src/frb_generated.rs" (Join-Path $repoRoot "crates\rdp-ffi\src\frb_generated.rs")
        if ($LASTEXITCODE -ne 0) { throw "Failed to pull frb_generated.rs" }

        $localRustDartDir = Join-Path $repoRoot "lib\src\rust"
        New-Item -ItemType Directory -Force -Path $localRustDartDir | Out-Null

        $packCmd = @"
set -euo pipefail
tar -czf $remoteRustTgzQuoted -C "$remoteStageLink/lib/src/rust" .
"@ -replace "`r`n", "`n"
        $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($packCmd + "`n"))
        & ssh @sshOpts -p $cfg.Port -i $cfg.KeyPath $cfg.Target "echo '$b64' | base64 -d | bash -s"
        if ($LASTEXITCODE -ne 0) { throw "Failed to pack lib/src/rust on remote" }

        & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath "$($cfg.Target):$remoteRustTgz" $localRustTgz
        if ($LASTEXITCODE -ne 0) { throw "Failed to pull lib/src/rust archive" }

        & tar.exe -xzf $localRustTgz -C $localRustDartDir
        if ($LASTEXITCODE -ne 0) { throw "Failed to extract lib/src/rust archive" }
    }
}
finally {
    if (Test-Path -LiteralPath $localRustTgz) {
        Remove-Item -LiteralPath $localRustTgz -Force -ErrorAction SilentlyContinue
    }
    try {
        $cleanupCmd = "rm -f -- $remoteStageLinkQuoted $remoteRustTgzQuoted"
        $cleanupB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($cleanupCmd + "`n"))
        & ssh @sshOpts -p $cfg.Port -i $cfg.KeyPath $cfg.Target "echo '$cleanupB64' | base64 -d | bash -s" *> $null
    }
    catch {
        # Best-effort remote temp cleanup
    }
}
