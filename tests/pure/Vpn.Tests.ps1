# Vpn.Tests.ps1 — pure tests for the AllowedIPs split-routing transform.
# This is the wg0.conf rewrite that prevents wg-quick from overriding the
# eth0 -> host-subnet route (so host.internal stays reachable with the
# killswitch armed).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1') -Force
}

Describe 'ConvertTo-SplitAllowedIPs' {
    It 'splits IPv4 0.0.0.0/0 into two /1s' {
        $cfg = "[Peer]`nAllowedIPs = 0.0.0.0/0`n"
        $out = ConvertTo-SplitAllowedIPs -WgConfigContent $cfg
        $out | Should -Match 'AllowedIPs\s*=\s*0\.0\.0\.0/1,\s*128\.0\.0\.0/1'
    }

    It 'splits IPv6 ::/0 into two halves' {
        $cfg = "[Peer]`nAllowedIPs = 0.0.0.0/0, ::/0`n"
        $out = ConvertTo-SplitAllowedIPs -WgConfigContent $cfg
        $out | Should -Match '::/1,\s*8000::/1'
    }

    It 'is case-insensitive on the AllowedIPs key' {
        $cfg = "[Peer]`nALLOWEDIPS = 0.0.0.0/0`n"
        $out = ConvertTo-SplitAllowedIPs -WgConfigContent $cfg
        $out | Should -Match '0\.0\.0\.0/1,\s*128\.0\.0\.0/1'
    }

    It 'leaves non-AllowedIPs lines untouched' {
        $cfg = "[Interface]`nAddress = 10.0.0.2/32`n"
        ConvertTo-SplitAllowedIPs -WgConfigContent $cfg | Should -Be $cfg
    }
}
