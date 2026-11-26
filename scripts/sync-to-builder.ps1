Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_env.ps1")
$cfg = Import-AerRdpEnv
$repoRoot = $cfg.RepoRoot

Write-Host "Syncing $repoRoot -> $($cfg.Target):$($cfg.RemoteDir) ..."

$sshOpts = @(
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=20",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4"
)

$tarExcludes = @(
    "--exclude=.git",
    "--exclude=target",
    "--exclude=build",
    "--exclude=artifacts",
    "--exclude=.dart_tool",
    "--exclude=.gradle",
    "--exclude=android/.gradle",
    "--exclude=android/app/build",
    "--exclude=android/app/src/main/jniLibs",
    "--exclude=android/.cxx",
    "--exclude=ios/Pods",
    "--exclude=ios/.symlinks",
    "--exclude=ios/Flutter/ephemeral",
    "--exclude=.env.local",
    "--exclude=scripts/.env.local",
    "--exclude=*.apk",
    "--exclude=*.aab"
)

function ConvertTo-BashSingleQuoted {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

$stamp = [guid]::NewGuid().ToString("N")
$localArchive = Join-Path ([System.IO.Path]::GetTempPath()) "aer-rdp-sync-$stamp.tgz"
$remoteArchive = "/tmp/aer-rdp-sync-$stamp.tgz"
$remoteDirQuoted = ConvertTo-BashSingleQuoted $cfg.RemoteDir
$remoteArchiveQuoted = ConvertTo-BashSingleQuoted $remoteArchive

try {
    & tar.exe @tarExcludes -czf $localArchive -C $repoRoot .
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create sync archive (exit $LASTEXITCODE)"
    }

    & scp @sshOpts -P $cfg.Port -i $cfg.KeyPath $localArchive "$($cfg.Target):$remoteArchive"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload sync archive (exit $LASTEXITCODE)"
    }

    $remoteScript = @"
set -euo pipefail
REMOTE_DIR_RAW=$remoteDirQuoted
case "`$REMOTE_DIR_RAW" in
  "~") REMOTE_DIR="`$HOME" ;;
  "~/"*) REMOTE_DIR="`$HOME/`${REMOTE_DIR_RAW:2}" ;;
  *) REMOTE_DIR="`$REMOTE_DIR_RAW" ;;
esac
REMOTE_ARCHIVE=$remoteArchiveQuoted
MANIFEST_FILE=`$(mktemp)
trap 'rm -f "`$REMOTE_ARCHIVE" "`$MANIFEST_FILE"' EXIT

mkdir -p "`$REMOTE_DIR"
tar -tzf "`$REMOTE_ARCHIVE" | sed 's|^\./||; s|/`$||' > "`$MANIFEST_FILE"

cd "`$REMOTE_DIR"
find . \
  \( -path "./.git" \
     -o -path "./target" \
     -o -path "./build" \
     -o -path "./artifacts" \
     -o -path "./.dart_tool" \
     -o -path "./.gradle" \
     -o -path "./android/.gradle" \
     -o -path "./android/app/build" \
     -o -path "./android/app/src/main/jniLibs" \
     -o -path "./android/.cxx" \
     -o -path "./ios/Pods" \
     -o -path "./ios/.symlinks" \
     -o -path "./ios/Flutter/ephemeral" \
     -o -path "./.pub-cache" \
     -o -path "./.pub" \
     -o -path "./.idea" \
     -o -path "./.vscode" \) -prune -o \
  \( -type f -o -type l \) -print | sed 's|^\./||' | awk '
    NR == FNR { keep[`$0] = 1; next }
    `$0 == ".env.local" || `$0 == "scripts/.env.local" || `$0 == "android/local.properties" || `$0 == "ios/Flutter/Flutter.podspec" || `$0 == ".flutter-plugins" || `$0 == ".flutter-plugins-dependencies" || `$0 == ".packages" || `$0 ~ /\.(apk|aab|ipa)`$/ { next }
    !(`$0 in keep) { print }
  ' "`$MANIFEST_FILE" - | while IFS= read -r stale; do
    rm -f -- "`$stale"
  done

find . \
  \( -path "./.git" \
     -o -path "./target" \
     -o -path "./build" \
     -o -path "./artifacts" \
     -o -path "./.dart_tool" \
     -o -path "./.gradle" \
     -o -path "./android/.gradle" \
     -o -path "./android/app/build" \
     -o -path "./android/app/src/main/jniLibs" \
     -o -path "./android/.cxx" \
     -o -path "./ios/Pods" \
     -o -path "./ios/.symlinks" \
     -o -path "./ios/Flutter/ephemeral" \
     -o -path "./.pub-cache" \
     -o -path "./.pub" \
     -o -path "./.idea" \
     -o -path "./.vscode" \) -prune -o \
  -depth -type d -empty -delete 2>/dev/null || true

tar -xzf "`$REMOTE_ARCHIVE" -C "`$REMOTE_DIR"
for f in scripts/*.sh ios/Scripts/*.sh; do
  [ -f "`$f" ] || continue
  sed -i 's/\r`$//' "`$f"
  chmod +x "`$f"
done
"@ -replace "`r`n", "`n"

    $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($remoteScript + "`n"))
    & ssh @sshOpts -p $cfg.Port -i $cfg.KeyPath $cfg.Target "echo '$b64' | base64 -d | bash -s"
    if ($LASTEXITCODE -ne 0) {
        throw "Remote unpack failed (exit $LASTEXITCODE)"
    }
}
finally {
    if (Test-Path -LiteralPath $localArchive) {
        Remove-Item -LiteralPath $localArchive -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Sync completed."
