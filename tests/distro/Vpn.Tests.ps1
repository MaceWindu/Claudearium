# Vpn.Tests.ps1 — payload install and wg-config transform against the
# ephemeral test distro. We bypass `vpn enable` deliberately: that verb's
# Reset-Vpn step (`systemctl restart claudearium-killswitch nftables
# wg-quick@wg0`) hangs on GitHub-hosted runners when the wg kernel module
# isn't loaded. The interesting side effects (payload deployment, wg0.conf
# split-AllowedIPs transform) happen BEFORE Reset-Vpn, so we drive them
# directly via Vpn.psm1 and assert on the deployed files.
#
# Full connectivity coverage runs only when a real -WgConfigPath is supplied
# (NeedsVpnReal=$true in the manifest), which the manual lane will add later.

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
    $script:cacheDir = Join-Path $repoRoot 'tests\.cache'
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
}

AfterAll {
    Remove-Item -LiteralPath $script:wgConfPath -ErrorAction SilentlyContinue
}

Describe 'Install-VpnPayload (module, not verb)' -Tag 'distro' {
    BeforeAll {
        Install-VpnPayload -DistroName $script:distro | Out-Host
    }

    It 'deploys the killswitch systemd unit' {
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

    It 'is idempotent (a second install leaves the files the same)' {
        $r1 = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'sha256sum /etc/systemd/system/claudearium-killswitch.service /etc/nftables.conf' `
            -CaptureOutput
        Install-VpnPayload -DistroName $script:distro | Out-Host
        $r2 = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'sha256sum /etc/systemd/system/claudearium-killswitch.service /etc/nftables.conf' `
            -CaptureOutput
        ($r2.Output -join "`n") | Should -Be ($r1.Output -join "`n")
    }
}

Describe 'Copy-WgConfig (module, not verb)' -Tag 'distro' {
    BeforeAll {
        Copy-WgConfig -DistroName $script:distro -SourcePath $script:wgConfPath | Out-Host
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
