# Mount.Tests.ps1 — `mount add / list / sync / remove` against the ephemeral
# test distro. The drvfs target uses a host path we know exists (the runner's
# Windows directory) so the actual `mount -a` succeeds.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'mount'
    $script:hostPath    = $env:SystemRoot  # always exists, even in CI
    $script:guestPath   = '/host/winroot'
}

AfterAll {
    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
        -ScriptArgs @('mount', 'remove', $script:guestPath, '-Force') -AllowFail | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'mount add' -Tag 'distro' {
    It 'writes the fstab entry between managed-block markers' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('mount', 'add', $script:hostPath, '-Guest', $script:guestPath, '-Mode', 'ro')

        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'cat /etc/fstab' -CaptureOutput
        $txt = ($r.Output -join "`n")
        $txt | Should -Match 'claudearium:mounts:begin'
        $txt | Should -Match [regex]::Escape($script:guestPath)
        $txt | Should -Match 'claudearium:mounts:end'
    }

    It "actually mounts the host path inside the distro" {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "mountpoint -q '$script:guestPath' && echo ok || echo missing" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }
}

Describe 'mount sync (idempotency)' -Tag 'distro' {
    It 'does not duplicate fstab entries on repeat sync' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('mount', 'sync')
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('mount', 'sync')

        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "grep -c -F '$script:guestPath' /etc/fstab" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be '1'
    }
}

Describe 'mount remove' -Tag 'distro' {
    It 'drops the fstab entry and unmounts' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('mount', 'remove', $script:guestPath, '-Force')

        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "grep -c -F '$script:guestPath' /etc/fstab || true" -CaptureOutput
        # grep -c prints 0 when no matches; -F treats pattern as literal.
        ($r.Output -join "`n").Trim() | Should -Be '0'
    }
}
