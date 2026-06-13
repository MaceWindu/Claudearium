# Network.Tests.ps1 — host-VPN eth0 net-repair payload deployment + lifecycle
# against the ephemeral test distro.
#
# On a CI distro DHCP works (no host VPN), so the net-repair script early-exits
# (a no-op for routing) and merely applies the MTU override — which is exactly
# the "transparent when DHCP already worked" contract. We assert on the deployed
# artifacts, the reported actual-state, MTU application, idempotency, and the
# uninstall path. The real no-DHCP repair is exercised manually on a host with a
# live VPN (see docs/cookbook.md).
#
# Unlike the VPN payload, plain `systemctl enable` (no --now) is used, so this
# exercises Install-NetRepairPayload directly (no hang risk — gotcha #4 is about
# --now / start).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Network.psm1') -Force
    Set-NetworkPayloadRoot -Path (Join-Path $repoRoot 'payload')
    $script:distro = $distro
}

Describe 'Net-repair payload install' -Tag 'distro' {
    BeforeAll {
        Install-NetRepairPayload -DistroName $script:distro -Config @{ Mtu = 1280; HostOffset = 2 }
        $script:actual = Get-NetRepairActualFromDistro -DistroName $script:distro
    }

    AfterAll {
        # Hygiene if the distro is reused: disable + drop the env, restore MTU.
        Uninstall-NetRepair -DistroName $script:distro
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'rm -f /usr/local/bin/claudearium-net-repair; ip link set eth0 mtu 1500 2>/dev/null || true' `
            -AllowFail -CaptureOutput | Out-Null
    }

    It 'deploys the net-repair script with the executable bit' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'stat -c "%a" /usr/local/bin/claudearium-net-repair' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be '755'
    }

    It 'deploys the systemd unit file' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'test -f /etc/systemd/system/claudearium-net-repair.service && echo ok' -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'writes the env file with the MTU override' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'cat /etc/claudearium/net-repair.env' -CaptureOutput
        ($r.Output -join "`n") | Should -Match '(?m)^CLAUDEARIUM_NET_MTU=1280$'
    }

    It 'reports installed + enabled + the MTU via Get-NetRepairActualFromDistro' {
        $script:actual.Installed | Should -BeTrue
        $script:actual.Enabled   | Should -BeTrue
        $script:actual.Mtu       | Should -Be 1280
    }

    It 'applied the MTU to eth0 (script ran inline at install)' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'cat /sys/class/net/eth0/mtu' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be '1280'
    }

    It 'leaves eth0 with a working default route on a DHCP distro (no-op repair)' {
        # On CI DHCP works, so the script early-exits without touching routing.
        $s = Get-NetworkStatus -DistroName $script:distro
        ($s.Output -join "`n") | Should -Match 'default via'
    }

    It 'is idempotent (a second install does not error and keeps state)' {
        { Install-NetRepairPayload -DistroName $script:distro -Config @{ Mtu = 1280; HostOffset = 2 } } | Should -Not -Throw
        (Get-NetRepairActualFromDistro -DistroName $script:distro).Enabled | Should -BeTrue
    }
}

Describe 'Net-repair uninstall' -Tag 'distro' {
    BeforeAll {
        Install-NetRepairPayload -DistroName $script:distro -Config @{ Mtu = 1280 }
        Uninstall-NetRepair -DistroName $script:distro
        $script:after = Get-NetRepairActualFromDistro -DistroName $script:distro
    }

    AfterAll {
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'rm -f /usr/local/bin/claudearium-net-repair; ip link set eth0 mtu 1500 2>/dev/null || true' `
            -AllowFail -CaptureOutput | Out-Null
    }

    It 'disables the unit and drops the env file (keeps the script)' {
        $script:after.Enabled | Should -BeFalse
        $script:after.Mtu     | Should -BeNullOrEmpty
        # Script is intentionally kept so a later 'network repair' re-enables.
        $script:after.Installed | Should -BeTrue
    }
}
