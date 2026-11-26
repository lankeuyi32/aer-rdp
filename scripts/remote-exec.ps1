param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Command
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_env.ps1")
$cfg = Import-AerRdpEnv

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

$remoteDirQuoted = ConvertTo-BashSingleQuoted $cfg.RemoteDir
$normalizedCmd = ($Command -replace "`r`n", "`n").Trim()
$scriptBody = @"
set -euo pipefail
if [ -f "`$HOME/.aer-rdp-env.sh" ]; then
  . "`$HOME/.aer-rdp-env.sh"
fi
REMOTE_DIR_RAW=$remoteDirQuoted
case "`$REMOTE_DIR_RAW" in
  "~") REMOTE_DIR="`$HOME" ;;
  "~/"*) REMOTE_DIR="`$HOME/`${REMOTE_DIR_RAW:2}" ;;
  *) REMOTE_DIR="`$REMOTE_DIR_RAW" ;;
esac
cd "`$REMOTE_DIR"
$normalizedCmd
"@ -replace "`r`n", "`n"

$b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($scriptBody + "`n"))
& ssh @sshOpts -p $cfg.Port -i $cfg.KeyPath $cfg.Target "echo '$b64' | base64 -d | bash -s"
if ($LASTEXITCODE -ne 0) {
    throw "Remote command failed with exit code $LASTEXITCODE"
}
