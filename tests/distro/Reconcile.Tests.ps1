# Reconcile.Tests.ps1 — the no-op assertion from CLAUDE.md's smoke-test
# checklist promoted to a real Pester check. After bootstrap, a profile that
# only declares the distro block should produce zero diffs.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'reconcile'
}

AfterAll {
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'reconcile no-op' -Tag 'distro' {
    It "prints '(no changes — profile matches state)' for a minimal profile" {
        # `*>&1` merges the Information stream (where Write-Host lands) into
        # Output so we can grep on the rendered text.
        $claudearium = Get-ClaudeariumScriptPath
        $out = & $claudearium reconcile `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        $txt = ($out -join "`n")
        # The exact wording from CLAUDE.md's smoke-test step #2.
        $txt | Should -Match 'no changes'
    }
}
