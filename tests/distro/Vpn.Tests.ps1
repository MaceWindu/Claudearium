# Vpn.Tests.ps1 — `vpn enable / disable / status` against the ephemeral
# test distro with a synthetic wg0.conf. Connectivity probes are out of scope
# for this lane (the dummy peer is unreachable by design); we verify the
# payload-install + config-transform side effects that landed BEFORE the
# `Reset-Vpn` systemctl chain.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot = $repoRoot
    $script:distro   = $distro

    # Write a dummy wg0.conf with the obvious "open to all routes" AllowedIPs
    # so we can assert on the split-AllowedIPs transform after `vpn enable`.
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

    # Write a profile that points at the dummy config.
    $script:profilePath = Join-Path $script:cacheDir 'profile-vpn.json'
    $install = Join-Path $env:LOCALAPPDATA (Join-Path 'WSL' $distro)
    $spec = [ordered]@{
        schemaVersion = 1
        distro = [ordered]@{ name = $distro; base = 'debian-12'; installPath = $install }
        vpn    = [ordered]@{ wgConfigPath = $script:wgConfPath }
    }
    ($spec | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $script:profilePath -Encoding UTF8
}

AfterAll {
    # Best-effort: bring the tunnel down regardless of how the tests left it.
    Invoke-InDistro -Name $script:distro -User 'root' `
        -Command 'systemctl stop wg-quick@wg0.service 2>/dev/null || true' -AllowFail -CaptureOutput | Out-Null
    Remove-Item -LiteralPath $script:wgConfPath  -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'vpn enable' -Tag 'distro' {
    BeforeAll {
        # vpn enable may fail at the final `Reset-Vpn` step (no wg kernel
        # support / unreachable peer in CI). The payload-install + wg-config
        # copy steps that run BEFORE Reset-Vpn are what we're asserting.
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs vpn,enable -AllowFail | Out-Null
    }

    It 'installs the nftables killswitch unit file' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'test -f /etc/systemd/system/claudearium-killswitch.service && echo ok' `
            -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'installs the nftables.conf payload' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'test -f /etc/nftables.conf && echo ok' -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'writes /etc/wireguard/wg0.conf with the split-AllowedIPs transform applied' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'cat /etc/wireguard/wg0.conf' -CaptureOutput -AllowFail
        $txt = ($r.Output -join "`n")
        $txt | Should -Match '0\.0\.0\.0/1'
        $txt | Should -Match '128\.0\.0\.0/1'
        # The original /0 should no longer appear at the start of an AllowedIPs line.
        $txt | Should -Not -Match '(?im)^AllowedIPs\s*=\s*0\.0\.0\.0/0\b'
    }
}

Describe 'vpn disable' -Tag 'distro' {
    It 'returns success even when wg-quick@wg0 was never up' {
        # Disable-Vpn uses -AllowFail internally, so this should succeed even
        # when there's nothing to bring down (e.g., Reset-Vpn failed earlier).
        $rc = Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs vpn,disable
        $rc | Should -Be 0
    }
}
