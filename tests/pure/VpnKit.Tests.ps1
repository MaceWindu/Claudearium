# VpnKit.Tests.ps1 — pure tests for the wsl-vpnkit helper-distro logic
# (version-tag normalization, release URL, effective-config, reconcile diff,
# tarball download URL). No WSL2 / no network — Invoke-WebRequest is mocked.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\VpnKit.psm1') -Force
}

Describe 'ConvertTo-VpnKitVersionTag' {
    It 'prefixes a bare semver with v' {
        ConvertTo-VpnKitVersionTag -Version '0.4.1' | Should -Be 'v0.4.1'
    }
    It 'passes a v-prefixed semver through' {
        ConvertTo-VpnKitVersionTag -Version 'v0.4.1' | Should -Be 'v0.4.1'
    }
    It 'trims surrounding whitespace' {
        ConvertTo-VpnKitVersionTag -Version '  v1.2.3 ' | Should -Be 'v1.2.3'
    }
    It 'throws on garbage' {
        { ConvertTo-VpnKitVersionTag -Version 'latest' } | Should -Throw
        { ConvertTo-VpnKitVersionTag -Version '0.4' }    | Should -Throw
        { ConvertTo-VpnKitVersionTag -Version 'v0.4.x' } | Should -Throw
    }
}

Describe 'Get-VpnKitReleaseUrl' {
    It 'builds the exact release asset URL for a pinned version' {
        Get-VpnKitReleaseUrl -Version 'v0.4.1' |
            Should -Be 'https://github.com/sakai135/wsl-vpnkit/releases/download/v0.4.1/wsl-vpnkit.tar.gz'
    }
    It 'normalizes a bare version before building the URL' {
        Get-VpnKitReleaseUrl -Version '0.4.1' |
            Should -Be 'https://github.com/sakai135/wsl-vpnkit/releases/download/v0.4.1/wsl-vpnkit.tar.gz'
    }
}

Describe 'Get-EffectiveVpnKitConfig' {
    It 'defaults to disabled + the pinned version when the block is absent' {
        $cfg = Get-EffectiveVpnKitConfig -Spec @{}
        $cfg.Enabled | Should -BeFalse
        $cfg.Version | Should -Match '^v\d+\.\d+\.\d+$'
    }
    It 'tolerates a $null spec' {
        (Get-EffectiveVpnKitConfig -Spec $null).Enabled | Should -BeFalse
    }
    It 'reads enabled + version from the profile block (normalizing the tag)' {
        $cfg = Get-EffectiveVpnKitConfig -Spec @{ vpnkit = @{ enabled = $true; version = '0.5.0' } }
        $cfg.Enabled | Should -BeTrue
        $cfg.Version | Should -Be 'v0.5.0'
    }
    It 'keeps the pinned default version when only enabled is set' {
        $cfg = Get-EffectiveVpnKitConfig -Spec @{ vpnkit = @{ enabled = $true } }
        $cfg.Enabled | Should -BeTrue
        $cfg.Version | Should -Match '^v\d+\.\d+\.\d+$'
    }
}

Describe 'Get-VpnKitDiff' {
    It 'proposes an add when enabled but not imported' {
        $d = Get-VpnKitDiff -Desired @{ Enabled = $true; Version = 'v0.4.1' } `
                            -Actual  @{ Imported = $false; Version = $null; Running = $false }
        $d.Changes.Count       | Should -Be 1
        $d.Changes[0].Action   | Should -Be 'add'
        $d.Changes[0].Severity | Should -Be 'safe'
        $d.HasDestructive      | Should -BeFalse
    }
    It 'proposes nothing when enabled + imported + version matches' {
        $d = Get-VpnKitDiff -Desired @{ Enabled = $true; Version = 'v0.4.1' } `
                            -Actual  @{ Imported = $true; Version = 'v0.4.1'; Running = $true }
        $d.Changes.Count | Should -Be 0
    }
    It 'proposes a modify when the tracked version drifts' {
        $d = Get-VpnKitDiff -Desired @{ Enabled = $true; Version = 'v0.5.0' } `
                            -Actual  @{ Imported = $true; Version = 'v0.4.1'; Running = $false }
        $d.Changes.Count     | Should -Be 1
        $d.Changes[0].Action | Should -Be 'modify'
        $d.Changes[0].Path   | Should -Be 'vpnkit.version'
    }
    It 'does not churn when the actual version is unknown (null)' {
        # Guards the post-out-of-band-install case: unknown installed version must
        # NOT trigger a re-import.
        $d = Get-VpnKitDiff -Desired @{ Enabled = $true; Version = 'v0.5.0' } `
                            -Actual  @{ Imported = $true; Version = $null; Running = $false }
        $d.Changes.Count | Should -Be 0
    }
    It 'proposes a remove when disabled but imported' {
        $d = Get-VpnKitDiff -Desired @{ Enabled = $false; Version = 'v0.4.1' } `
                            -Actual  @{ Imported = $true; Version = 'v0.4.1'; Running = $false }
        $d.Changes.Count       | Should -Be 1
        $d.Changes[0].Action   | Should -Be 'remove'
        $d.Changes[0].Severity | Should -Be 'safe'
    }
    It 'proposes nothing when disabled and not imported' {
        $d = Get-VpnKitDiff -Desired @{ Enabled = $false; Version = 'v0.4.1' } `
                            -Actual  @{ Imported = $false; Version = $null; Running = $false }
        $d.Changes.Count | Should -Be 0
    }
    It 'never marks a vpnkit change destructive' {
        $d = Get-VpnKitDiff -Desired @{ Enabled = $false; Version = 'v0.4.1' } `
                            -Actual  @{ Imported = $true; Version = 'v0.4.1'; Running = $false }
        $d.HasDestructive  | Should -BeFalse
        $d.CanApplyInPlace | Should -BeTrue
    }
}

Describe 'Install-VpnKit return hygiene' {
    It 'returns the version tag as a scalar even when wsl --import chatters to the pipeline' {
        # Regression guard: Import-Distro runs `& wsl.exe --import`, which prints
        # "The operation completed successfully." to the pipeline. Without an
        # Out-Null on that call the string leaks into Install-VpnKit's return, so
        # $tag becomes an array. Assert a single scalar tag comes back.
        Mock -ModuleName VpnKit Test-VpnKitImported { $false }
        Mock -ModuleName VpnKit Save-VpnKitTarball { }
        Mock -ModuleName VpnKit Import-Distro { 'The operation completed successfully.' }
        Mock -ModuleName VpnKit Set-VpnKitInstalledVersion { }
        $tag = Install-VpnKit -Version 'v0.4.1'
        @($tag).Count | Should -Be 1
        $tag          | Should -Be 'v0.4.1'
    }
}

Describe 'Start-VpnKit registers WSLInterop before launching' {
    It 'calls Register-VpnKitInterop before starting the tunnel process' {
        # Regression guard: a freshly-imported helper distro lacks the WSLInterop
        # binfmt handler, so gvproxy.exe fails with "exec format error" and the
        # tunnel never comes up. Start-VpnKit must (re)register it on every start.
        # Guard call (#1) must be $false so it proceeds; poll call (#2) $true so
        # it returns immediately without the 5s wait.
        $script:tvrCalls = 0
        # Record call ORDER, not just occurrence: the whole point of the fix is
        # that interop is registered BEFORE the tunnel process is spawned. A
        # -Times assertion alone would still pass if a refactor moved the
        # registration after Start-Process (reintroducing the exec-format bug).
        $script:vkOrder = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VpnKit Test-VpnKitRunning { $script:tvrCalls++; return ($script:tvrCalls -gt 1) }
        Mock -ModuleName VpnKit Test-VpnKitImported { $true }
        Mock -ModuleName VpnKit Register-VpnKitInterop { $script:vkOrder.Add('register') }
        # Don't actually spawn wsl or write a pidfile.
        Mock -ModuleName VpnKit Start-Process { $script:vkOrder.Add('start'); [pscustomobject]@{ Id = 4242; HasExited = $false } }
        Mock -ModuleName VpnKit Set-Content { }
        Start-VpnKit | Out-Null
        Should -Invoke -ModuleName VpnKit Register-VpnKitInterop -Times 1
        @($script:vkOrder) | Should -Be @('register', 'start')
    }
}

Describe 'Save-VpnKitTarball' {
    It 'downloads the versioned release asset to the requested path' {
        $captured = $null
        Mock -ModuleName VpnKit Invoke-WebRequest { $script:capturedUrl = $Uri }
        $dest = Join-Path $TestDrive 'wsl-vpnkit.tar.gz'
        Save-VpnKitTarball -Version '0.4.1' -DestPath $dest
        Should -Invoke -ModuleName VpnKit Invoke-WebRequest -Times 1
        $script:capturedUrl | Should -Be 'https://github.com/sakai135/wsl-vpnkit/releases/download/v0.4.1/wsl-vpnkit.tar.gz'
    }
}
