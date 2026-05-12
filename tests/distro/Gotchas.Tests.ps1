# Gotchas.Tests.ps1 — regression tests for wsl2-gotchas that need a real
# distro to exercise the pwsh -> wsl.exe -> bash argv chain.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    $script:distro = $distro
}

Describe 'Gotcha #1: Invoke-InDistroScript preserves $VAR references through argv' -Tag 'distro' {
    It 'a multi-line bash script with $VAR references actually sees the values' {
        # If this test fails, base64 transport in Invoke-InDistroScript was
        # broken or pwsh started pre-expanding `$X` on its way through.
        # See docs/wsl2-gotchas.md#1.
        $script = @'
X=hello
Y=world
printf '%s\n' "$X $Y"
'@
        $r = Invoke-InDistroScript -Name $script:distro -User 'claude' -Script $script -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'hello world'
    }

    It 'backslash escapes survive the round-trip' {
        # A literal $FOO with a leading backslash should reach bash intact
        # so bash can decide whether to expand it.
        $script = @'
LITERAL='$FOO'
printf '%s\n' "$LITERAL"
'@
        $r = Invoke-InDistroScript -Name $script:distro -User 'claude' -Script $script -CaptureOutput
        # The output should be the literal "$FOO", not an empty expansion.
        ($r.Output -join "`n").Trim() | Should -Be '$FOO'
    }
}

Describe 'Gotcha #13: fstab managed-block markers parsed via inline regex' -Tag 'distro' {
    It 'Get-HostMountsActualFromDistro returns an array even when fstab is empty' {
        # The bug this guards: awk -v VAR=val for marker matching used to
        # silently match nothing through the pwsh -> wsl hop. We rewrote it
        # as inline /pattern/. This test asserts the path works end-to-end
        # against a real (post-bootstrap, empty-managed-block) fstab.
        Import-Module (Join-Path $env:CLAUDEARIUM_REPO_ROOT 'modules\Mounts.psm1') -Force
        $result = Get-HostMountsActualFromDistro -DistroName $script:distro
        # Either empty array (no managed block yet) or an array of hashtables.
        # Critically: must NOT throw, must NOT return a non-array (which the
        # awk -v failure could produce if it returned $null after a parse error).
        ,$result | Should -BeOfType [Array]
    }
}
