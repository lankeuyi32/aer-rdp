Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AerRdpRepoRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Import-AerRdpEnv {
    $repoRoot = Get-AerRdpRepoRoot
    $candidates = @(
        (Join-Path $repoRoot ".env.local"),
        (Join-Path $PSScriptRoot ".env.local")
    )

    foreach ($envFile in $candidates) {
        if (Test-Path -LiteralPath $envFile) {
            foreach ($rawLine in Get-Content -LiteralPath $envFile -Encoding UTF8) {
                $line = $rawLine.Trim()
                if ($line.Length -eq 0 -or $line.StartsWith("#")) {
                    continue
                }
                $eqIdx = $line.IndexOf("=")
                if ($eqIdx -lt 1) {
                    continue
                }
                $name = $line.Substring(0, $eqIdx).Trim()
                $val = $line.Substring($eqIdx + 1).Trim()
                if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                    if ($val.Length -ge 2) {
                        $val = $val.Substring(1, $val.Length - 2)
                    }
                }
                $existing = [Environment]::GetEnvironmentVariable($name, "Process")
                if ([string]::IsNullOrWhiteSpace($existing)) {
                    [Environment]::SetEnvironmentVariable($name, $val, "Process")
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:AER_RDP_BUILDER_PORT)) {
        $env:AER_RDP_BUILDER_PORT = "22"
    }
    if ([string]::IsNullOrWhiteSpace($env:AER_RDP_REMOTE_DIR)) {
        $env:AER_RDP_REMOTE_DIR = "~/aer-rdp"
    }

    $missing = @()
    foreach ($required in @("AER_RDP_BUILDER_HOST", "AER_RDP_BUILDER_USER", "AER_RDP_BUILDER_KEY", "AER_RDP_REMOTE_DIR")) {
        $v = [Environment]::GetEnvironmentVariable($required, "Process")
        if ([string]::IsNullOrWhiteSpace($v)) {
            $missing += $required
        }
    }

    if ($missing.Count -gt 0) {
        throw "Missing remote builder settings: $($missing -join ', '). Set environment variables or copy .env.local.example to .env.local and configure it."
    }

    if (-not (Test-Path -LiteralPath $env:AER_RDP_BUILDER_KEY)) {
        throw "AER_RDP_BUILDER_KEY file not found: $($env:AER_RDP_BUILDER_KEY)"
    }

    return [PSCustomObject]@{
        RepoRoot  = $repoRoot
        Host      = $env:AER_RDP_BUILDER_HOST
        Port      = $env:AER_RDP_BUILDER_PORT
        User      = $env:AER_RDP_BUILDER_USER
        KeyPath   = $env:AER_RDP_BUILDER_KEY
        RemoteDir = $env:AER_RDP_REMOTE_DIR
        Target    = "$($env:AER_RDP_BUILDER_USER)@$($env:AER_RDP_BUILDER_HOST)"
    }
}

function Test-LocalToolchainsAvailable {
    $required = @("flutter", "cargo", "cargo-ndk")
    foreach ($cmd in $required) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            return $false
        }
    }
    return $true
}
