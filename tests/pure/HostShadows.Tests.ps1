# HostShadows.Tests.ps1 — pure tests for modules/HostShadows.psm1. No WSL2.
# Covers Resolve-HostShadow (the testable core), Get-HostShadowBinDir, and
# the catalog accessor. The live wrapper installers are exercised in the
# distro lane (tests/distro/HostProjects.Tests.ps1).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\HostShadows.psm1') -Force

    # Create real temp .exe files so Test-Path inside the resolver succeeds.
    # Using $TestDrive would be cleaner but the resolver checks paths with
    # Test-Path -LiteralPath, which $TestDrive: doesn't always honor across
    # Pester versions. A throwaway temp dir is portable and we clean up below.
    $script:fakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("hs-test-" + [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:fakeDir)

    function New-FakeExe([string]$Leaf) {
        $p = Join-Path $script:fakeDir $Leaf
        # 1-byte file is enough — Test-Path -LiteralPath only checks existence.
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(0x4d))
        return $p
    }

    $script:fakePwshPath    = New-FakeExe 'pwsh.exe'
    $script:fakePwshAlt     = New-FakeExe 'pwsh-alt.exe'
    $script:fakeGitPath     = New-FakeExe 'git.exe'
}

AfterAll {
    if ($script:fakeDir -and (Test-Path -LiteralPath $script:fakeDir)) {
        Remove-Item -LiteralPath $script:fakeDir -Recurse -Force
    }
}

Describe 'Resolve-HostShadow' {
    It "returns Source='explicit' when ExplicitExe points to an existing file" {
        $r = Resolve-HostShadow -Name 'pwsh' -ExplicitExe $script:fakePwshPath
        $r.Source     | Should -Be 'explicit'
        $r.WindowsExe | Should -Be $script:fakePwshPath
        $r.Warnings.Count | Should -Be 0
    }

    It "returns Source='unresolved' with a warning when ExplicitExe is missing" {
        $missing = Join-Path $script:fakeDir 'does-not-exist.exe'
        $r = Resolve-HostShadow -Name 'pwsh' -ExplicitExe $missing
        $r.Source     | Should -Be 'unresolved'
        $r.WindowsExe | Should -BeNullOrEmpty
        ($r.Warnings -join "`n") | Should -Match 'does not exist'
    }

    It "prefers PATH hit over catalog candidates (Source='path')" {
        $catalog = @{
            pwsh = @{
                exeName    = 'pwsh.exe'
                candidates = @($script:fakePwshAlt)   # exists, but PATH wins
            }
        }
        $r = Resolve-HostShadow -Name 'pwsh' -Catalog $catalog -PathOverride @{ 'pwsh.exe' = $script:fakePwshPath }
        $r.Source     | Should -Be 'path'
        $r.WindowsExe | Should -Be $script:fakePwshPath
        # PATH-vs-catalog mismatch should produce a warning so the user can pin.
        ($r.Warnings -join "`n") | Should -Match 'different install'
    }

    It "does not warn when PATH and catalog candidate are the same path" {
        $catalog = @{
            pwsh = @{ exeName = 'pwsh.exe'; candidates = @($script:fakePwshPath) }
        }
        $r = Resolve-HostShadow -Name 'pwsh' -Catalog $catalog -PathOverride @{ 'pwsh.exe' = $script:fakePwshPath }
        $r.Source     | Should -Be 'path'
        $r.Warnings.Count | Should -Be 0
    }

    It "falls back to catalog candidates (Source='catalog') when PATH has no hit" {
        $catalog = @{
            git = @{ exeName = 'git.exe'; candidates = @($script:fakeGitPath) }
        }
        # PathOverride with the key explicitly $null = "intentionally not on PATH".
        $r = Resolve-HostShadow -Name 'git' -Catalog $catalog -PathOverride @{ 'git.exe' = $null }
        $r.Source     | Should -Be 'catalog'
        $r.WindowsExe | Should -Be $script:fakeGitPath
    }

    It "returns Source='unresolved' when neither PATH nor catalog yields a file" {
        $catalog = @{
            pwsh = @{ exeName = 'pwsh.exe'; candidates = @((Join-Path $script:fakeDir 'nope-1.exe'), (Join-Path $script:fakeDir 'nope-2.exe')) }
        }
        $r = Resolve-HostShadow -Name 'pwsh' -Catalog $catalog -PathOverride @{ 'pwsh.exe' = $null }
        $r.Source     | Should -Be 'unresolved'
        $r.WindowsExe | Should -BeNullOrEmpty
        ($r.Warnings -join "`n") | Should -Match 'Could not resolve'
    }

    It "handles names outside the catalog by falling through to PATH lookup with the .exe suffix" {
        $r = Resolve-HostShadow -Name 'mytool' -Catalog @{} -PathOverride @{ 'mytool.exe' = $script:fakePwshPath }
        $r.Source     | Should -Be 'path'
        $r.WindowsExe | Should -Be $script:fakePwshPath
    }

    It "produces a helpful warning when an unknown name is not on PATH" {
        $r = Resolve-HostShadow -Name 'mytool' -Catalog @{} -PathOverride @{ 'mytool.exe' = $null }
        $r.Source | Should -Be 'unresolved'
        ($r.Warnings -join "`n") | Should -Match 'not in the built-in catalog'
    }
}

Describe 'Get-HostShadowBinDir' {
    It "returns the per-project path under /home/claude/host-projects" {
        Get-HostShadowBinDir -ProjectName 'Claudearium' | Should -Be '/home/claude/host-projects/Claudearium/bin'
    }

    It "rejects a project name with slashes or whitespace (traversal guard)" {
        { Get-HostShadowBinDir -ProjectName '../escape' } | Should -Throw
        { Get-HostShadowBinDir -ProjectName 'with space' } | Should -Throw
        { Get-HostShadowBinDir -ProjectName 'a\b' }       | Should -Throw
    }
}

Describe 'Get-HostShadowCatalog' {
    It "returns the built-in catalog with at least pwsh and git" {
        $cat = Get-HostShadowCatalog
        $cat.ContainsKey('pwsh') | Should -BeTrue
        $cat.ContainsKey('git')  | Should -BeTrue
        $cat.pwsh.exeName        | Should -Be 'pwsh.exe'
        $cat.git.exeName         | Should -Be 'git.exe'
    }

    It "returns a copy — mutating it does not affect future calls" {
        $cat = Get-HostShadowCatalog
        $cat.Remove('pwsh') | Out-Null
        $again = Get-HostShadowCatalog
        $again.ContainsKey('pwsh') | Should -BeTrue
    }
}
