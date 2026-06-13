# State.Tests.ps1 — pure tests for modules/State.psm1's stateless helpers.
# Initialize-State and Add-Recent don't touch the filesystem; Get-StatePath /
# Read-State / Write-State are exercised by distro tests where they belong.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\State.psm1') -Force
}

Describe 'Initialize-State' {
    It 'returns a hashtable with schemaVersion=2 and provisioned=false' {
        $s = Initialize-State -DistroName 'test-x'
        $s.schemaVersion | Should -Be 2
        $s.distro        | Should -Be 'test-x'
        $s.provisioned   | Should -BeFalse
    }

    It 'sets createdAt and updatedAt to the same ISO-8601 timestamp' {
        $s = Initialize-State -DistroName 'test-x'
        $s.createdAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
        $s.updatedAt | Should -Be $s.createdAt
    }

    It 'seeds an empty users map and the uid allocator at 30000' {
        $s = Initialize-State -DistroName 'test-x'
        $s.users               | Should -BeOfType [hashtable]
        $s.users.Count         | Should -Be 0
        $s.uidAllocator.next   | Should -Be 30000
    }

    It 'marks the per-project user model' {
        (Initialize-State -DistroName 'test-x').userModel | Should -Be 'per-project'
    }
}

Describe 'Test-NeedsUserModelMigration' {
    It 'is false for a not-yet-provisioned distro' {
        Test-NeedsUserModelMigration -State (Initialize-State -DistroName 'x') | Should -BeFalse
    }

    It 'is false for a fresh provisioned distro (carries the userModel marker)' {
        $s = Initialize-State -DistroName 'x'; $s.provisioned = $true
        Test-NeedsUserModelMigration -State $s | Should -BeFalse
    }

    It 'is true for a provisioned distro whose state predates the userModel marker' {
        # Old-shape state: provisioned, no userModel key.
        $s = @{ schemaVersion = 1; distro = 'x'; provisioned = $true }
        Test-NeedsUserModelMigration -State $s | Should -BeTrue
    }

    It 'is false once userModel is per-project even on an otherwise old-shape state' {
        $s = @{ distro = 'x'; provisioned = $true; userModel = 'per-project' }
        Test-NeedsUserModelMigration -State $s | Should -BeFalse
    }
}

Describe 'Protect-StateSecret / Unprotect-StateSecret' {
    It 'round-trips a secret through DPAPI' {
        $enc = Protect-StateSecret -Plain 'hunter2-correct-horse'
        $enc | Should -Match '^dpapi:v1:'
        $enc | Should -Not -Match 'hunter2'
        Unprotect-StateSecret -Stored $enc | Should -Be 'hunter2-correct-horse'
    }

    It 'is idempotent — protecting an already-protected value is a no-op' {
        $enc  = Protect-StateSecret -Plain 'abc'
        $enc2 = Protect-StateSecret -Plain $enc
        $enc2 | Should -Be $enc
    }

    It 'passes legacy plaintext (no marker) through Unprotect unchanged' {
        Unprotect-StateSecret -Stored 'legacy-plaintext-pw' | Should -Be 'legacy-plaintext-pw'
    }

    It 'leaves empty strings alone in both directions' {
        Protect-StateSecret   -Plain  '' | Should -Be ''
        Unprotect-StateSecret -Stored '' | Should -Be ''
    }
}

Describe 'Read-State / Write-State secret-at-rest' {
    BeforeAll {
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $script:tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("state-sec-" + ([guid]::NewGuid().ToString('N').Substring(0,8)))
        [void][IO.Directory]::CreateDirectory($script:tmpRoot)
        $env:LOCALAPPDATA = $script:tmpRoot
    }
    AfterAll {
        $env:LOCALAPPDATA = $script:savedLocalAppData
        if (Test-Path -LiteralPath $script:tmpRoot) { Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force }
    }

    It 'encrypts the password on disk but Read-State returns plaintext' {
        $s = Initialize-State -DistroName 'sectest'
        $s.users['proj'] = @{ user = 'cp-proj'; uid = 30000; home = '/home/cp-proj'; password = 'S3cr3t-pw' }
        Write-State -DistroName 'sectest' -State $s

        $raw = Get-Content -LiteralPath (Get-StatePath -DistroName 'sectest') -Raw
        $raw | Should -Match 'dpapi:v1:'
        $raw | Should -Not -Match 'S3cr3t-pw'

        $back = Read-State -DistroName 'sectest'
        $back.users.proj.password | Should -Be 'S3cr3t-pw'
    }

    It 'leaves the caller''s in-memory state as plaintext after Write-State' {
        $s = Initialize-State -DistroName 'sectest2'
        $s.users['p'] = @{ user = 'cp-p'; uid = 30001; home = '/home/cp-p'; password = 'plain-after-write' }
        Write-State -DistroName 'sectest2' -State $s
        # The finally in Write-State must have restored plaintext in $s.
        $s.users.p.password | Should -Be 'plain-after-write'
    }

    It 'does not corrupt the in-memory state when encryption throws mid-write' {
        # The encrypt step is inside Write-State's try so the finally always
        # restores plaintext. Force Protect to fail and assert the caller's
        # $State still holds the original plaintext (not ciphertext / mixed).
        Mock -ModuleName State Protect-StateSecret { throw 'dpapi unavailable' }
        $s = Initialize-State -DistroName 'failenc'
        $s.users['p'] = @{ user = 'cp-p'; uid = 30000; home = '/home/cp-p'; password = 'still-plain' }
        { Write-State -DistroName 'failenc' -State $s } | Should -Throw
        $s.users.p.password | Should -Be 'still-plain'
    }

    It 'reads a legacy plaintext password file back unchanged' {
        # Hand-write a state file with a bare plaintext password (pre-encryption).
        $legacy = @{
            schemaVersion = 2; distro = 'legacy'; provisioned = $true; userModel = 'per-project'
            uidAllocator = @{ next = 30001 }
            users = @{ old = @{ user = 'cp-old'; uid = 30000; home = '/home/cp-old'; password = 'bare-legacy-pw' } }
        }
        $p = Get-StatePath -DistroName 'legacy'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $p))
        $legacy | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $p -Encoding UTF8

        (Read-State -DistroName 'legacy').users.old.password | Should -Be 'bare-legacy-pw'
    }
}

Describe 'Add-Recent' {
    It 'adds the first entry under the requested key' {
        $s = @{}
        Add-Recent -State $s -Key 'branches' -Value 'main'
        $s.recents.branches | Should -Be @('main')
    }

    It 'deduplicates with most-recent-wins ordering' {
        $s = @{}
        Add-Recent -State $s -Key 'branches' -Value 'main'
        Add-Recent -State $s -Key 'branches' -Value 'feat-1'
        Add-Recent -State $s -Key 'branches' -Value 'main'
        $s.recents.branches | Should -Be @('main', 'feat-1')
    }

    It 'trims to -Max entries (default 5)' {
        $s = @{}
        1..7 | ForEach-Object { Add-Recent -State $s -Key 'k' -Value "v$_" -Max 5 }
        $s.recents.k.Count | Should -Be 5
        $s.recents.k[0]    | Should -Be 'v7'
        $s.recents.k[-1]   | Should -Be 'v3'
    }
}
