# Vpn.Tests.ps1 — payload deployment, wg-config transform, and killswitch
# behavioral check against the ephemeral test distro. We bypass BOTH the
# `vpn enable` verb AND the Install-VpnPayload helper because each runs
# `systemctl enable --now` (wsl2-gotcha #4) which hangs indefinitely on
# GitHub-hosted runners when nftables / wg can't load. Instead we drop
# the payload files into place via Send-RootFileToDistro (no systemd
# involved) and assert on the resulting filesystem state, then load the
# nftables ruleset directly via `nft -f` to verify the killswitch
# actually blocks egress.
#
# The full systemd activation + real-tunnel egress check still lives in
# the manual lane (tests/manual/VpnConnectivity.ps1, gated on a real
# -WgConfigPath).

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

Describe 'Killswitch ruleset blocks egress when armed (no systemd activation)' -Tag 'distro' {
    BeforeAll {
        # The payload files were deployed in the previous Describe's
        # BeforeAll; Pester runs Describes top-to-bottom in a single file
        # but each Describe has its own scope, so re-read the payload from
        # the host and re-push. Cheap (three small files) and makes this
        # Describe independently runnable via `Invoke-Pester -FullName`.
        $payloadRoot = $script:payloadRoot
        $nftBody  = Get-Content -LiteralPath (Join-Path $payloadRoot 'etc\nftables.conf') -Raw
        $prepBody = Get-Content -LiteralPath (Join-Path $payloadRoot 'usr\local\bin\claudearium-killswitch-prep') -Raw
        Send-RootFileToDistro -DistroName $script:distro `
            -Content $nftBody  -DestPath '/etc/nftables.conf' -Mode '0644'
        Send-RootFileToDistro -DistroName $script:distro `
            -Content $prepBody -DestPath '/usr/local/bin/claudearium-killswitch-prep' -Mode '0755'
    }

    AfterEach {
        # Safety net: even if the It block below leaves nftables armed
        # (early throw, assertion failure mid-script), flush the ruleset
        # so subsequent tests in this run still have network. Cheap
        # no-op when no rules are loaded.
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'nft flush ruleset 2>/dev/null || true' `
            -AllowFail -CaptureOutput | Out-Null
    }

    It 'arming /etc/nftables.conf blocks egress to a public IP' {
        # End-to-end behavioral check: pre-generate the host/wg defines,
        # load the killswitch ruleset directly (bypassing the systemctl
        # chain that hangs on hosted runners — wsl2-gotcha #4), and
        # confirm egress to a non-host public IP is dropped. The wg-peer
        # placeholder is 0.0.0.0:0 because no wg0.conf is in place yet,
        # so the only outbound exception left is host.internal. Anything
        # to the public internet must drop.
        #
        # Probe via bash /dev/tcp (no curl, no TLS, no extra packages):
        # GHA Windows runners started failing-fast on `curl https://1.1.1.1`
        # mid-May 2026 — TLS / edge filtering, not timeout — and dragged
        # this lane red on PR #14 even though the lane is unrelated to
        # this fix. /dev/tcp probes raw TCP reachability, which is what
        # nftables filters anyway, and tries multiple endpoints so a
        # single Cloudflare/Google ACL change can't take the lane down.
        # If NO endpoint is reachable from the runner, the test skips
        # (exit 75) instead of failing — without working egress there
        # is nothing for the killswitch to block.
        $bashScript = @'
set -e

# Returns 0 if any TCP target is reachable within the per-attempt
# timeout. Tries multiple endpoints so we don't depend on a single
# anycast provider remaining reachable from GHA's WSL2 NAT path.
probe_egress() {
    for target in '1.1.1.1/443' '8.8.8.8/443' '1.1.1.1/53' '8.8.8.8/53'; do
        if timeout 4 bash -c "exec 3<>/dev/tcp/$target" 2>/dev/null; then
            echo "  probe ok: $target" >&2
            return 0
        fi
    done
    return 1
}

# Baseline: prove we have egress before arming. Without this, a
# transient outage would let the "blocked after arming" check pass
# for the wrong reason. Retry the whole probe set twice in case the
# WSL2 NAT path is briefly unsettled right after distro provision.
preconditionOk=0
for attempt in 1 2; do
    if probe_egress; then
        preconditionOk=1
        break
    fi
    sleep 2
done
if [ "$preconditionOk" != 1 ]; then
    echo "PRECONDITION: no public TCP egress reachable from the runner before arming the killswitch" >&2
    exit 75
fi

# Generate /etc/nftables.conf.d/00-host.nft (HOST_SUBNET / WG_PEER_IP /
# WG_PEER_PORT defines). Without this the include in /etc/nftables.conf
# is undefined and nft -f errors out before loading anything.
/usr/local/bin/claudearium-killswitch-prep

# Arm the killswitch. `nft -f` exits non-zero on parse / load errors.
nft -f /etc/nftables.conf

# Now TCP to 1.1.1.1 must drop (no eth0 path past host.internal, no
# wg0 interface). Short per-attempt timeout — we expect a fast drop,
# not a settle.
if timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
    echo "LEAK: TCP to 1.1.1.1:443 succeeded with killswitch armed" >&2
    exit 1
fi

# Sanity: assert OUR table is actually loaded. With nftables an
# empty ruleset means egress is allowed (kernel default = accept),
# so a silent `nft -f` failure would actually let the second probe
# succeed and fail the test for the right reason anyway — but if
# some unrelated nftables config dropped egress, the test would
# pass without proving WE blocked it. `nft list table inet
# claudearium` returning non-zero would signal that the wrong
# component is responsible for the observed drop.
nft list table inet claudearium >/dev/null

echo ok
'@
        $r = Invoke-InDistroScript -Name $script:distro -User 'root' -Script $bashScript -CaptureOutput -AllowFail
        if ($r.ExitCode -eq 75) {
            # Hosted runner has no public TCP egress from WSL2 — without
            # working egress there's nothing for the killswitch to block,
            # so the assertion would be vacuous. Skip with the captured
            # probe output so a real regression doesn't hide behind a
            # skip in CI.
            $reason = "No public TCP egress reachable from WSL2 on this runner; killswitch arming was not exercised. Probe output:`n$(($r.Output -join "`n").Trim())"
            Set-ItResult -Skipped -Because $reason
            return
        }
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n").Trim() | Should -Match 'ok$'
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
