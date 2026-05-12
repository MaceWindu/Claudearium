# HostTools.Tests.ps1 — `host-tools add / list / remove`. Uses a /host/...
# guest-style path so we don't need an actual Windows .exe on the host.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'hosttools'
    $script:exeGuest    = '/host/fakedir/sample.exe'
    $script:guestCmd    = 'sb-sample'
}

AfterAll {
    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
        -ScriptArgs @('host-tools', 'remove', $script:guestCmd, '-Force') -AllowFail | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'host-tools add' -Tag 'distro' {
    It 'installs an executable wrapper under /usr/local/bin' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('host-tools', 'add', '-HostExe', $script:exeGuest, '-GuestCommand', $script:guestCmd)

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "test -x /usr/local/bin/$script:guestCmd && echo ok" -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'embeds the claudearium-hosttool marker in the wrapper body' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "cat /usr/local/bin/$script:guestCmd" -CaptureOutput
        ($r.Output -join "`n") | Should -Match 'claudearium-hosttool: sample'
    }
}

Describe 'host-tools remove' -Tag 'distro' {
    It 'deletes the wrapper and clears the profile entry' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('host-tools', 'remove', $script:guestCmd, '-Force')

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "test -e /usr/local/bin/$script:guestCmd && echo present || echo gone" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'
    }
}
