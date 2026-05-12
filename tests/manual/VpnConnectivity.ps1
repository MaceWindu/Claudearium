# VpnConnectivity.ps1 — when the tester has supplied a real wg0.conf
# (via the runner's -WgConfigPath), confirm the tunnel actually carries
# traffic and the killswitch blocks non-tunnel egress.
#
# Without -WgConfigPath the dashboard skips this test entirely
# (NeedsVpnReal=$true in the manifest).
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

return Invoke-ManualTest `
    -Name 'VPN connectivity + killswitch' `
    -Instructions @"
Goal: tunnel is up AND the killswitch keeps non-wg egress closed.

Setup (skip if vpn is already enabled):
  .\claudearium.ps1 vpn enable

1. Bring up a wsl shell and check the egress IP:
     wsl -d claudearium -u claude -- curl -s https://api.ipify.org
   Expected: your VPN provider's exit-node IP, NOT your real WAN IP.

2. Confirm host.internal is still reachable (kill-switch should allow
   host-subnet traffic):
     wsl -d claudearium -u claude -- ping -c1 -W2 host.internal

3. Kill the tunnel and re-check egress:
     .\claudearium.ps1 vpn disable
     wsl -d claudearium -u claude -- curl -m 5 https://api.ipify.org
   Expected: curl FAILS (killswitch armed, no route).

4. Bring it back up:
     .\claudearium.ps1 vpn enable
"@ `
    -Question 'Did the IP switch via wg, host.internal stay reachable, and disabled tunnel block egress?' `
    -NonInteractive:$NonInteractive
