# Tools.Tests.ps1 — `tools` verb against the ephemeral test distro.
# Breadth-first: skip `tools install` (each tool is 30s-2min) and assert on
# the catalog + profile-mutation paths only.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Tools.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'tools'
}

AfterAll {
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'tools catalog' -Tag 'distro' {
    It 'exposes the expected tool set via Get-ToolCatalog' {
        # Note: the `tools list` verb only writes to the host (Write-Host) so
        # its stdout can't be captured from a pwsh pipeline. We assert on the
        # underlying catalog instead, then sanity-check that `tools list`
        # exits 0.
        $catalog = Get-ToolCatalog
        foreach ($t in 'node','claudeCode','gh','glab','acli','dotnet','seqcli','pwsh') {
            $catalog | Should -Contain $t
        }
    }

    It "the 'tools list' verb runs cleanly against the test distro" {
        $rc = Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='tools'; SubVerb='list' }
        $rc | Should -Be 0
    }
}

Describe 'tools enable / disable' -Tag 'distro' {
    It 'enable writes the profile entry without installing' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='tools'; SubVerb='enable'; Arg='gh' }

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $spec.tools.gh.enabled | Should -BeTrue
    }

    It 'disable flips the profile entry but does not uninstall' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='tools'; SubVerb='disable'; Arg='gh' }

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $spec.tools.gh.enabled | Should -BeFalse
    }
}
