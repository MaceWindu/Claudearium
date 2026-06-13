# Network.Tests.ps1 — pure tests for the host-VPN eth0 net-repair logic
# (address derivation, env-file content, effective-config, reconcile diff).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Network.psm1') -Force
}

Describe 'Get-NetRepairHostAddress' {
    It 'derives the validated address for the live NAT gateway (172.22.208.1/20, offset 2)' {
        # This is the exact case validated on the live host: broadcast 172.22.223.255
        # minus offset 2 => 172.22.223.253. Keeps the PS helper in lockstep with the
        # bash arithmetic in payload/usr/local/bin/claudearium-net-repair.
        $r = Get-NetRepairHostAddress -Gateway '172.22.208.1' -Prefix 20 -HostOffset 2
        $r.Address | Should -Be '172.22.223.253'
        $r.Network | Should -Be '172.22.208.0'
        $r.Cidr    | Should -Be '172.22.223.253/20'
        $r.Prefix  | Should -Be 20
    }

    It 'defaults to /20 + offset 2' {
        (Get-NetRepairHostAddress -Gateway '172.22.208.1').Cidr | Should -Be '172.22.223.253/20'
    }

    It 'honors a different host offset' {
        (Get-NetRepairHostAddress -Gateway '172.22.208.1' -HostOffset 5).Address | Should -Be '172.22.223.250'
    }

    It 'works for a /24 gateway' {
        $r = Get-NetRepairHostAddress -Gateway '192.168.1.1' -Prefix 24 -HostOffset 2
        $r.Network | Should -Be '192.168.1.0'
        $r.Address | Should -Be '192.168.1.253'
    }

    It 'throws on a non-IPv4 gateway' {
        { Get-NetRepairHostAddress -Gateway 'not-an-ip' } | Should -Throw
        { Get-NetRepairHostAddress -Gateway '172.22.208' } | Should -Throw
    }

    It 'rejects an offset that does not fit the subnet' {
        { Get-NetRepairHostAddress -Gateway '10.0.0.1' -Prefix 30 -HostOffset 99 } | Should -Throw
    }

    It 'rejects an offset below 1' {
        { Get-NetRepairHostAddress -Gateway '10.0.0.1' -HostOffset 0 } | Should -Throw
    }
}

Describe 'ConvertTo-NetRepairEnvContent' {
    It 'emits no tunable keys when nothing is set (only the header comment)' {
        $out = ConvertTo-NetRepairEnvContent
        $out | Should -Not -Match 'CLAUDEARIUM_NET_MTU'
        $out | Should -Not -Match 'CLAUDEARIUM_NET_HOST_OFFSET'
        $out | Should -Match '^#'
    }

    It 'emits CLAUDEARIUM_NET_MTU only when MTU > 0' {
        ConvertTo-NetRepairEnvContent -Mtu 1280 | Should -Match '(?m)^CLAUDEARIUM_NET_MTU=1280$'
    }

    It 'emits the host-offset key when set' {
        ConvertTo-NetRepairEnvContent -HostOffset 3 | Should -Match '(?m)^CLAUDEARIUM_NET_HOST_OFFSET=3$'
    }

    It 'is LF-terminated (no CR)' {
        $out = ConvertTo-NetRepairEnvContent -Mtu 1400
        $out | Should -Not -Match "`r"
        $out.EndsWith("`n") | Should -BeTrue
    }
}

Describe 'Get-EffectiveNetworkConfig' {
    It 'defaults to disabled / no-clamp / offset 2 when the block is absent' {
        $cfg = Get-EffectiveNetworkConfig -Spec @{}
        $cfg.Enabled    | Should -BeFalse
        $cfg.Mtu        | Should -Be 0
        $cfg.HostOffset | Should -Be 2
    }

    It 'tolerates a $null spec' {
        (Get-EffectiveNetworkConfig -Spec $null).Enabled | Should -BeFalse
    }

    It 'reads enabled + mtu + hostOffset from the profile block' {
        $cfg = Get-EffectiveNetworkConfig -Spec @{ network = @{ enabled = $true; mtu = 1280; hostOffset = 4 } }
        $cfg.Enabled    | Should -BeTrue
        $cfg.Mtu        | Should -Be 1280
        $cfg.HostOffset | Should -Be 4
    }

    It 'leaves mtu at 0 when omitted even if enabled' {
        $cfg = Get-EffectiveNetworkConfig -Spec @{ network = @{ enabled = $true } }
        $cfg.Enabled | Should -BeTrue
        $cfg.Mtu     | Should -Be 0
    }
}

Describe 'Get-NetworkDiff' {
    It 'proposes an add when enabled but not installed' {
        $d = Get-NetworkDiff -Desired @{ Enabled = $true; Mtu = 0; HostOffset = 2 } `
                             -Actual  @{ Installed = $false; Enabled = $false; Mtu = $null }
        $d.Changes.Count        | Should -Be 1
        $d.Changes[0].Action    | Should -Be 'add'
        $d.Changes[0].Severity  | Should -Be 'safe'
        $d.HasDestructive       | Should -BeFalse
    }

    It 'proposes nothing when enabled + installed + MTU matches' {
        $d = Get-NetworkDiff -Desired @{ Enabled = $true; Mtu = 0; HostOffset = 2 } `
                             -Actual  @{ Installed = $true; Enabled = $true; Mtu = $null }
        $d.Changes.Count | Should -Be 0
    }

    It 'proposes a modify when the MTU override drifts' {
        $d = Get-NetworkDiff -Desired @{ Enabled = $true; Mtu = 1280; HostOffset = 2 } `
                             -Actual  @{ Installed = $true; Enabled = $true; Mtu = $null }
        $d.Changes.Count     | Should -Be 1
        $d.Changes[0].Action | Should -Be 'modify'
        $d.Changes[0].Path   | Should -Be 'network.mtu'
    }

    It 'proposes a remove when disabled but installed + enabled' {
        $d = Get-NetworkDiff -Desired @{ Enabled = $false; Mtu = 0; HostOffset = 2 } `
                             -Actual  @{ Installed = $true; Enabled = $true; Mtu = $null }
        $d.Changes.Count     | Should -Be 1
        $d.Changes[0].Action | Should -Be 'remove'
        $d.Changes[0].Severity | Should -Be 'safe'
    }

    It 'proposes nothing when disabled and not installed' {
        $d = Get-NetworkDiff -Desired @{ Enabled = $false; Mtu = 0; HostOffset = 2 } `
                             -Actual  @{ Installed = $false; Enabled = $false; Mtu = $null }
        $d.Changes.Count | Should -Be 0
    }
}
