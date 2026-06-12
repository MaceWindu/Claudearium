# ClaudeFile.Tests.ps1 — the (now structure-vs-content-split) ClaudeFile.psm1
# renderer/writer. Install-ClaudeFile is no longer wired into the orchestration —
# the shared store (ClaudeShared.psm1) owns CLAUDE.md and symlinks it into each
# ~/.claude — but the module's content renderer + raw writer are still unit-worthy.
# We write into a THROWAWAY home (not /home/claude/.claude, which is now a symlink
# into the shared store) so this test never mutates the real shared store.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot = $repoRoot
    $script:distro   = $distro
    # Throwaway, non-symlinked home so we exercise the raw file write in isolation.
    $script:testHome = '/tmp/cf-test-home'
    Invoke-InDistro -Name $script:distro -User 'root' `
        -Command "rm -rf $($script:testHome)" -AllowFail | Out-Null
}

AfterAll {
    Invoke-InDistro -Name $script:distro -User 'root' `
        -Command "rm -rf $($script:testHome)" -AllowFail | Out-Null
}

Describe 'Install-ClaudeFile (caveman-lite)' -Tag 'distro' {
    # Exercise the raw writer directly: the unit that matters is the file write
    # (content, owner, mode). We target a throwaway home rather than the
    # shared-store-symlinked /home/claude/.claude.
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'modules\ClaudeFile.psm1') -Force
        Install-ClaudeFile -DistroName $script:distro -Spec @{ mode = 'caveman-lite' } `
            -User 'claude' -Home $script:testHome
    }

    It 'writes the .claude/CLAUDE.md under the target home owned by claude with mode 0644' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "stat -c '%U %a' $($script:testHome)/.claude/CLAUDE.md" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'claude 644'
    }

    It "stores exactly 'be brief.\n' for caveman-lite (incl trailing newline)" {
        # Binary-safe read via the production helper: a line-based cat capture
        # would silently strip the trailing newline and let this assertion lie.
        $actual = Get-ClaudeFileActualFromDistro -DistroName $script:distro -Home $script:testHome
        $actual | Should -Be "be brief.`n"
    }
}
