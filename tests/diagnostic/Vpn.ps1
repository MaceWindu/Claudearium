# Vpn.ps1 — read-only VPN health probes. Reports killswitch state, wg
# interface state, and host.internal reachability. Does not modify
# nftables / wireguard / systemd.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DistroName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')
Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1')

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

# Egress audit: blocked-egress counter + recent rate-limited drop samples.
if ($ks) {
    Write-Host '  egress audit:' -ForegroundColor Cyan
    $audit = Get-EgressAuditLog -DistroName $DistroName -Lines 10
    foreach ($line in $audit.Output) { Write-Host "    $line" }
}
