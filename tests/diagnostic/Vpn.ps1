# Vpn.ps1 — read-only VPN health probes. Reports killswitch state, wg
# interface state, and host.internal reachability. Does not modify
# nftables / wireguard / systemd.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DistroName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1') -Force

Write-Host ''
Write-Host "== VPN (distro: $DistroName) ==" -ForegroundColor Cyan

if (-not (Test-DistroExists -Name $DistroName)) {
    Write-Host '  (distro not registered)' -ForegroundColor Yellow
    return
}

$ks = Test-KillswitchActive -DistroName $DistroName
$vpn = Test-VpnActive       -DistroName $DistroName
Write-Host ("  killswitch:       {0}" -f $(if ($ks) { 'ACTIVE' } else { 'inactive' }))
Write-Host ("  tunnel wg0:       {0}" -f $(if ($vpn) { 'UP' } else { 'DOWN' }))

# Get-VpnStatus already aggregates `wg show`, ip addr, nft, and host.internal probes.
$st = Get-VpnStatus -DistroName $DistroName
foreach ($line in $st.Output) { Write-Host "    $line" }
