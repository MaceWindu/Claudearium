# Profile.Tests.ps1 — pure tests for modules/Profile.psm1. No WSL2 needed.
# Step 1 ships a smoke set; Step 2 will expand into env-token expansion,
# round-tripping, per-block diff shape, and warning emission.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        # Fallback when Pester is invoked directly (not via test-claudearium.ps1):
        # tests/pure/Profile.Tests.ps1 -> repoRoot
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Profile.psm1') -Force
    $script:examplePath = Join-Path $repoRoot 'templates\claudearium.profile.example.json'
}

Describe 'Test-Profile' {
    It 'reports IsValid on the bundled example profile' {
        $spec = Read-Profile -Path $script:examplePath
        $r = Test-Profile -Spec $spec
        $r.IsValid | Should -BeTrue
        $r.Errors.Count | Should -Be 0
    }

    It 'rejects a profile with no schemaVersion' {
        $r = Test-Profile -Spec @{
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'schemaVersion is required'
    }

    It 'rejects a profile with an unsupported schemaVersion' {
        $r = Test-Profile -Spec @{
            schemaVersion = 999
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'is not supported'
    }

    It 'rejects a profile that omits the distro block entirely' {
        $r = Test-Profile -Spec @{ schemaVersion = 1 }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'distro block is required'
    }
}
