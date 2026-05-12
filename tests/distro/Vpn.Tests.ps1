# Vpn.Tests.ps1 — payload deployment and wg-config transform against the
# ephemeral test distro. We bypass BOTH the `vpn enable` verb AND the
# Install-VpnPayload helper, because each runs `systemctl enable --now`
# (wsl2-gotcha #4) which hangs indefinitely on GitHub-hosted runners when
# nftables / wg can't load. Instead we drop the payload files into place
# via Send-RootFileToDistro (no systemd involved) and assert on the
# resulting filesystem state.
#
# The connectivity / killswitch-armed coverage that requires the systemctl
# chain belongs in a separate lane gated on a real -WgConfigPath
# (NeedsVpnReal=$true in the manifest), which the manual lane will add.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1') -Force
    Set-VpnPayloadRoot -Path (Join-Path $repoRoot 'payload')

    $script:repoRoot = $repoRoot
    $script:distro   = $distro
    $script:payloadRoot = Join-Path $repoRoot 'payload'
}

Describe 'VPN payload files (deployed directly, no systemctl)' -Tag 'distro' {
    BeforeAll {
        # Read the three payload files from the repo and push them into the
        # test distro via Send-RootFileToDistro (one of the exports of
        # Vpn.psm1). This is exactly what Install-VpnPayload does, minus the
        # final `systemctl enable --now` chain that hangs on hosted runners.
        $script:nftBody    = Get-Content -LiteralPath (Join-Path $script:payloadRoot 'etc\nftables.conf') -Raw
        $script:prepBody   = Get-Content -LiteralPath (Join-Path $script:payloadRoot 'usr\local\bin\claudearium-killswitch-prep') -Raw
        $script:unitBody   = Get-Content -LiteralPath (Join-Path $script:payloadRoot 'etc\systemd\system\claudearium-killswitch.service') -Raw

        Send-RootFileToDistro -DistroName $script:distro `
            -Content $script:nftBody -DestPath '/etc/nftables.conf' -Mode '0644'
        Send-RootFileToDistro -DistroName $script:distro `
            -Content $script:prepBody -DestPath '/usr/local/bin/claudearium-killswitch-prep' -Mode '0755'
        Send-RootFileToDistro -DistroName $script:distro `
            -Content $script:unitBody -DestPath '/etc/systemd/system/claudearium-killswitch.service' -Mode '0644'
    }

    It 'deploys the killswitch systemd unit file' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'test -f /etc/systemd/system/claudearium-killswitch.service && echo ok' `
            -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'deploys /etc/nftables.conf' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'test -f /etc/nftables.conf && echo ok' -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'deploys /usr/local/bin/claudearium-killswitch-prep with the executable bit' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'stat -c "%a" /usr/local/bin/claudearium-killswitch-prep' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be '755'
    }
}

Describe 'Copy-WgConfig transform' -Tag 'distro' {
    BeforeAll {
        $script:cacheDir = Join-Path $script:repoRoot 'tests\.cache'
        if (-not (Test-Path $script:cacheDir)) { New-Item -ItemType Directory -Path $script:cacheDir -Force | Out-Null }
        $script:wgConfPath = Join-Path $script:cacheDir 'dummy-wg0.conf'
        $wgConf = @'
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.99.0.2/32

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=
Endpoint = 203.0.113.1:51820
AllowedIPs = 0.0.0.0/0
'@
        Set-Content -LiteralPath $script:wgConfPath -Value $wgConf -Encoding UTF8

        # Copy-WgConfig reads the source from the host, applies the split-
        # AllowedIPs transform, and writes 0600 to /etc/wireguard/wg0.conf.
        # No systemctl involved.
        Copy-WgConfig -DistroName $script:distro -SourcePath $script:wgConfPath
    }

    AfterAll {
        Remove-Item -LiteralPath $script:wgConfPath -ErrorAction SilentlyContinue
    }

    It 'applies the split-AllowedIPs transform to /etc/wireguard/wg0.conf' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'cat /etc/wireguard/wg0.conf' -CaptureOutput
        $txt = ($r.Output -join "`n")
        $txt | Should -Match '0\.0\.0\.0/1'
        $txt | Should -Match '128\.0\.0\.0/1'
        $txt | Should -Not -Match '(?im)^AllowedIPs\s*=\s*0\.0\.0\.0/0\b'
    }

    It 'writes the file with 0600 permissions owned by root' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'stat -c "%U %a" /etc/wireguard/wg0.conf' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'root 600'
    }
}
