# Prune.Tests.ps1 — pure tests for modules/Prune.psm1. Anything that needs a
# real distro or a real git checkout lives under tests/distro/Prune.Tests.ps1.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Prune.psm1') -Force
}

Describe 'Format-Bytes' {
    It 'returns plain bytes under 1KB' {
        Format-Bytes -Bytes 0    | Should -Be '0 B'
        Format-Bytes -Bytes 512  | Should -Be '512 B'
        Format-Bytes -Bytes 1023 | Should -Be '1023 B'
    }
    It 'uses K for >=1KB and <1MB' {
        Format-Bytes -Bytes 1024     | Should -Be '1.0K'
        Format-Bytes -Bytes (50KB)   | Should -Be '50.0K'
    }
    It 'uses M for >=1MB and <1GB' {
        Format-Bytes -Bytes (1MB)     | Should -Be '1.0M'
        Format-Bytes -Bytes (250MB)   | Should -Be '250.0M'
    }
    It 'uses G for >=1GB' {
        Format-Bytes -Bytes (1GB)     | Should -Be '1.0G'
        Format-Bytes -Bytes (2500MB)  | Should -Be '2.4G'
    }
}

Describe 'Find-DanglingMounts' {
    # Pure-ish: mocks the in-distro fstab read and the merged-desired computer.
    It 'returns mounts present in actual but missing from desired' {
        Mock -ModuleName Prune Get-HostMountsActualFromDistro {
            ,@(
                @{ guest = '/host/keep';      host = 'C:\keep' }
                @{ guest = '/host/dangling';  host = 'C:\old'  }
            )
        }
        Mock -ModuleName Prune Get-MergedDesiredMounts {
            ,@( @{ guest = '/host/keep'; host = 'C:\keep' } )
        }
        $r = Find-DanglingMounts -DistroName 'd' -State @{} -ProfileSpec @{}
        @($r).Count | Should -Be 1
        $r[0].Guest | Should -Be '/host/dangling'
    }

    It 'returns an empty array when actual is a subset of desired' {
        Mock -ModuleName Prune Get-HostMountsActualFromDistro {
            ,@( @{ guest = '/host/a'; host = 'C:\a' } )
        }
        Mock -ModuleName Prune Get-MergedDesiredMounts {
            ,@(
                @{ guest = '/host/a'; host = 'C:\a' }
                @{ guest = '/host/b'; host = 'C:\b' }
            )
        }
        @(Find-DanglingMounts -DistroName 'd' -State @{} -ProfileSpec @{}).Count | Should -Be 0
    }
}

Describe 'Find-OrphanedSessions (host-side check)' {
    # Pure for host sessions because Test-Path is the only filesystem touch
    # and we can point it at a path we know doesn't exist. Distro sessions
    # need the in-distro test path which lives under tests/distro/.
    It 'reports a host session whose hostWorktreePath has been deleted' {
        $missingPath = Join-Path ([System.IO.Path]::GetTempPath()) ("prune-test-missing-" + [Guid]::NewGuid().ToString('N'))
        $state = @{
            sessions = @(@{
                project          = 'p1'
                name             = 's1'
                type             = 'host'
                hostWorktreePath = $missingPath
                worktreePath     = '/host/p1/s1'
            })
        }
        # The function still consults the distro for any distro-type sessions
        # in the list — none here, so Invoke-InDistro is never called. Mock
        # to fail loudly if that assumption breaks.
        Mock -ModuleName Prune Invoke-InDistro { throw 'unexpected distro probe' }
        $r = Find-OrphanedSessions -State $state -DistroName 'd'
        @($r).Count       | Should -Be 1
        $r[0].Project     | Should -Be 'p1'
        $r[0].Name        | Should -Be 's1'
        $r[0].Type        | Should -Be 'host'
    }

    It 'does NOT report a host session whose hostWorktreePath still exists' {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("prune-test-present-" + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempDir)
        try {
            $state = @{
                sessions = @(@{
                    project          = 'p1'
                    name             = 's1'
                    type             = 'host'
                    hostWorktreePath = $tempDir
                    worktreePath     = '/host/p1/s1'
                })
            }
            Mock -ModuleName Prune Invoke-InDistro { throw 'unexpected distro probe' }
            @(Find-OrphanedSessions -State $state -DistroName 'd').Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
