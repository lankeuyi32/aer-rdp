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

$stamp = [guid]::NewGuid().ToString("N")
$localArchive = Join-Path ([System.IO.Path]::GetTempPath()) "aer-rdp-sync-$stamp.tgz"
$remoteArchive = "/tmp/aer-rdp-sync-$stamp.tgz"

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
mkdir -p $($cfg.RemoteDir)
tar -xzf $remoteArchive -C $($cfg.RemoteDir)
rm -f $remoteArchive
cd $($cfg.RemoteDir)
for f in scripts/*.sh; do
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
