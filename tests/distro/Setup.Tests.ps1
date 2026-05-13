# Setup.Tests.ps1 — end-to-end post-conditions on the ephemeral distro provisioned
# by Invoke-TestRun. The runner has already executed `claudearium.ps1 setup -Force`
# against the test distro; this file asserts the bootstrap produced the expected
# user, sudo, wsl.conf, and interop binfmt state.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')   -Force
    Import-Module (Join-Path $repoRoot 'modules\State.psm1') -Force
    $script:repoRoot = $repoRoot
    $script:distro   = $distro
}

Describe 'Bootstrap post-conditions' -Tag 'distro' {
    It 'registered the distro in WSL' {
        Test-DistroExists -Name $script:distro | Should -BeTrue
    }

    It 'created a per-distro state file under %LOCALAPPDATA%\claudearium' {
        Test-State -DistroName $script:distro | Should -BeTrue
    }

    It 'created the claude user inside the distro' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' -Command 'id -u claude' -CaptureOutput -AllowFail
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n").Trim() | Should -Match '^\d+$'
    }

    It 'configured passwordless sudo for claude' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' -Command 'sudo -n true' -CaptureOutput -AllowFail
        $r.ExitCode | Should -Be 0
    }

    It 'wrote /etc/wsl.conf with [user] default=claude' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' -Command 'cat /etc/wsl.conf' -CaptureOutput
        ($r.Output -join "`n") | Should -Match '(?ms)\[user\][^\[]*default\s*=\s*claude'
    }

    It 'registered the WSL interop binfmt service' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' -Command 'systemctl is-enabled claudearium-wsl-interop.service' -CaptureOutput -AllowFail
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n").Trim() | Should -Be 'enabled'
    }

    It 'wrote the provisioned marker file' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' -Command 'cat /var/lib/claudearium/provisioned' -CaptureOutput -AllowFail
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n").Trim() | Should -Match '\d{4}-\d{2}-\d{2}T'
    }
}
