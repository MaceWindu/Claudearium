# VpnKit.Tests.ps1 — wsl-vpnkit helper-distro install/uninstall lifecycle.
#
# HEAVY + GATED: this downloads the real wsl-vpnkit release tarball from GitHub
# and imports it as a SECOND WSL distro named `wsl-vpnkit` (separate from the
# ephemeral test distro). It therefore:
#   * needs egress to github.com — skipped when the release URL isn't reachable;
#   * must NOT clobber a real `wsl-vpnkit` a developer already has installed —
#     skipped entirely when the distro pre-exists, and on a fresh install it
#     unregisters ONLY what this test created (finally/AfterAll).
# The tunnel process (Start-VpnKit) and real egress are NOT exercised here — that
# needs a live host VPN and belongs in a manual test.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')    -Force
    Import-Module (Join-Path $repoRoot 'modules\State.psm1')  -Force
    Import-Module (Join-Path $repoRoot 'modules\VpnKit.psm1') -Force

    # Snapshot pre-existing state so cleanup never touches a real install.
    $script:preExisting = Test-VpnKitImported

    # Reachability probe (short timeout) — the release URL, HEAD only.
    $script:reachable = $false
    try {
        $url = Get-VpnKitReleaseUrl -Version 'v0.4.1'
        Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 8 -UseBasicParsing `
            -Headers @{ 'User-Agent' = 'claudearium' } | Out-Null
        $script:reachable = $true
    } catch { $script:reachable = $false }

    $script:canRun = (-not $script:preExisting) -and $script:reachable
}

Describe 'wsl-vpnkit install/uninstall lifecycle' -Tag 'distro' {

    AfterAll {
        # Only remove what this test created; leave a developer's real install alone.
        if ($script:canRun -and (Test-VpnKitImported)) {
            try { Uninstall-VpnKit } catch { }
        }
    }

    It 'imports the helper distro and records the version' {
        if (-not $script:canRun) {
            Set-ItResult -Skipped -Because $(if ($script:preExisting) { 'wsl-vpnkit already installed on this host' } else { 'github.com release URL not reachable' })
            return
        }
        $tag = Install-VpnKit -Version 'v0.4.1'
        $tag | Should -Be 'v0.4.1'
        Test-VpnKitImported          | Should -BeTrue
        Get-VpnKitInstalledVersion   | Should -Be 'v0.4.1'
    }

    It 'is idempotent (a second install without -Reinstall is a no-op)' {
        if (-not $script:canRun) { Set-ItResult -Skipped -Because 'gated'; return }
        { Install-VpnKit -Version 'v0.4.1' } | Should -Not -Throw
        Test-VpnKitImported | Should -BeTrue
    }

    It 'uninstalls: unregisters the distro and clears the version record' {
        if (-not $script:canRun) { Set-ItResult -Skipped -Because 'gated'; return }
        Uninstall-VpnKit
        Test-VpnKitImported        | Should -BeFalse
        Get-VpnKitInstalledVersion | Should -BeNullOrEmpty
    }
}
