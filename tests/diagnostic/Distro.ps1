# Distro.ps1 — read-only distro health probes. Reports WSL registration
# state, /etc/wsl.conf contents, current /etc/wsl.conf-vs-running default
# user, interop binfmt registration, and the provisioned marker.
#
# All probes are side-effect-free. Run as part of the dashboard's `d`
# (diagnostics) option against either the real or test distro.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DistroName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')

Write-Host ''
Write-Host "== Distro: $DistroName ==" -ForegroundColor Cyan

if (-not (Test-DistroExists -Name $DistroName)) {
    Write-Host '  (distro not registered)' -ForegroundColor Yellow
    return
}

Write-Host ("  WSL state:        {0}" -f (Get-DistroState -Name $DistroName))

# /etc/wsl.conf — full contents, since users often need to paste this.
$conf = Invoke-InDistro -Name $DistroName -User 'root' -Command 'cat /etc/wsl.conf 2>/dev/null || echo "(missing)"' -CaptureOutput -AllowFail
Write-Host '  /etc/wsl.conf:'
foreach ($line in $conf.Output) { Write-Host "    $line" }

# Default user is whatever wsl.exe lands you in by default.
$who = Invoke-InDistro -Name $DistroName -Command 'whoami' -CaptureOutput -AllowFail
Write-Host ("  default user:     {0}" -f (($who.Output -join '').Trim()))

# Interop binfmt — needed for Windows .exe wrappers (host-tools).
$binfmt = Invoke-InDistro -Name $DistroName -User 'root' -Command 'test -e /proc/sys/fs/binfmt_misc/WSLInterop && echo registered || echo missing' -CaptureOutput -AllowFail
Write-Host ("  WSL interop binfmt: {0}" -f (($binfmt.Output -join '').Trim()))

# Provisioned marker — written by bootstrap-distro.sh on first setup.
$prov = Invoke-InDistro -Name $DistroName -User 'root' -Command 'cat /var/lib/claudearium/provisioned 2>/dev/null || echo "(not provisioned)"' -CaptureOutput -AllowFail
Write-Host ("  provisioned at:   {0}" -f (($prov.Output -join '').Trim()))

# claude user — bootstrap must have created this.
$idc = Invoke-InDistro -Name $DistroName -User 'root' -Command 'id claude 2>/dev/null || echo "(missing)"' -CaptureOutput -AllowFail
Write-Host ("  claude user:      {0}" -f (($idc.Output -join '').Trim()))
