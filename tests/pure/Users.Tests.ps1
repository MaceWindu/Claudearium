# Users.Tests.ps1 — pure tests for modules/Users.psm1's host-side helpers
# (derivation, password generation, name collision, record allocation). The
# in-distro provisioning functions (New/Remove-ProjectUserInDistro,
# Copy-ProjectUserCreds) are exercised by tests/distro/Users.Tests.ps1.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\State.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Users.psm1') -Force
}

Describe 'ConvertTo-LinuxUserName' {
    It 'lowercases and replaces dots with dashes' {
        ConvertTo-LinuxUserName -ProjectName 'Triggre.Web' | Should -Be 'cp-triggre-web'
    }

    It 'prefixes with cp- and keeps digits, dashes, underscores' {
        ConvertTo-LinuxUserName -ProjectName 'acme_v2-x' | Should -Be 'cp-acme_v2-x'
    }

    It 'collapses runs of separators and trims trailing dashes' {
        ConvertTo-LinuxUserName -ProjectName 'a...b   c' | Should -Be 'cp-a-b-c'
    }

    It 'truncates to at most 28 characters' {
        $n = ConvertTo-LinuxUserName -ProjectName ('z' * 60)
        $n.Length | Should -BeLessOrEqual 28
        $n        | Should -BeLike 'cp-*'
    }

    It 'never ends in a dash even after truncation' {
        $n = ConvertTo-LinuxUserName -ProjectName ('ab-' * 20)
        $n.EndsWith('-') | Should -BeFalse
    }

    It 'degrades a punctuation-only name to the bare prefix' {
        ConvertTo-LinuxUserName -ProjectName '...' | Should -Be 'cp'
    }

    It 'always starts with a letter (valid Linux username leading char)' {
        foreach ($p in @('123', '_x', '-weird', '9lives')) {
            (ConvertTo-LinuxUserName -ProjectName $p) | Should -Match '^[a-z]'
        }
    }
}

Describe 'New-ProjectUserPassword' {
    It 'returns the requested length' {
        (New-ProjectUserPassword -Length 20).Length | Should -Be 20
        (New-ProjectUserPassword -Length 32).Length | Should -Be 32
    }

    It 'uses only the unambiguous alphabet (no 0 O 1 l I, no symbols)' {
        $pw = New-ProjectUserPassword -Length 200
        $pw | Should -Match '^[a-zA-Z2-9]+$'
        # Case-sensitive: the alphabet legitimately keeps lowercase i and
        # uppercase L; only 0 O 1 l I are excluded (-match is case-insensitive).
        ($pw -cmatch '[0O1lI]') | Should -BeFalse
    }

    It 'produces distinct values across calls' {
        $a = New-ProjectUserPassword
        $b = New-ProjectUserPassword
        $a | Should -Not -Be $b
    }
}

Describe 'New-ProjectUid' {
    It 'allocates from 30000 and bumps monotonically' {
        $s = Initialize-State -DistroName 'tu'
        (New-ProjectUid -State $s) | Should -Be 30000
        (New-ProjectUid -State $s) | Should -Be 30001
        $s.uidAllocator.next       | Should -Be 30002
    }

    It 'seeds past a uid already present in users (allocator drift)' {
        $s = Initialize-State -DistroName 'tu'
        $s.users['x'] = @{ user = 'cp-x'; uid = 30005; gid = 30005; home = '/home/cp-x' }
        (New-ProjectUid -State $s) | Should -Be 30006
    }

    It 'initializes the allocator on a v1-shaped state without one' {
        $s = @{ distro = 'tu' }   # no uidAllocator / users keys
        (New-ProjectUid -State $s) | Should -Be 30000
    }
}

Describe 'Resolve-ProjectUserName' {
    It 'returns the base name when nothing collides' {
        $s = Initialize-State -DistroName 'tu'
        Resolve-ProjectUserName -State $s -ProjectName 'Acme' | Should -Be 'cp-acme'
    }

    It 'appends -2, -3 when the derived name is already taken in state' {
        # 'Foo.Bar', 'Foo-Bar', 'Foo--Bar' all sanitize to the same 'cp-foo-bar'
        # base (an underscore, by contrast, is preserved and would NOT collide).
        $s = Initialize-State -DistroName 'tu'
        $s.users['Foo.Bar'] = @{ user = 'cp-foo-bar'; uid = 30000; gid = 30000; home = '/home/cp-foo-bar' }
        Resolve-ProjectUserName -State $s -ProjectName 'Foo-Bar' | Should -Be 'cp-foo-bar-2'
        $s.users['Foo-Bar'] = @{ user = 'cp-foo-bar-2'; uid = 30001; gid = 30001; home = '/home/cp-foo-bar-2' }
        Resolve-ProjectUserName -State $s -ProjectName 'Foo--Bar' | Should -Be 'cp-foo-bar-3'
    }

    It 'keeps the suffixed name within the 32-char username ceiling' {
        $s = Initialize-State -DistroName 'tu'
        $long = ('w' * 40)
        $base = Resolve-ProjectUserName -State $s -ProjectName $long
        $s.users['a'] = @{ user = $base; uid = 30000; gid = 30000; home = "/home/$base" }
        $suffixed = Resolve-ProjectUserName -State $s -ProjectName $long
        $suffixed.Length | Should -BeLessOrEqual 32
        $suffixed        | Should -Not -Be $base
    }
}

Describe 'New-ProjectUserRecord' {
    It 'builds a complete record and stores it in state' {
        $s = Initialize-State -DistroName 'tu'
        $rec = New-ProjectUserRecord -State $s -Project 'Acme'
        $rec.user      | Should -Be 'cp-acme'
        $rec.uid       | Should -Be 30000
        $rec.gid       | Should -Be 30000
        $rec.home      | Should -Be '/home/cp-acme'
        $rec.password  | Should -Match '^[a-zA-Z2-9]+$'
        $rec.createdAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
        (Get-ProjectUser -State $s -Project 'Acme').user | Should -Be 'cp-acme'
    }

    It 'is idempotent: a second call returns the same record without a new uid' {
        $s = Initialize-State -DistroName 'tu'
        $first  = New-ProjectUserRecord -State $s -Project 'Acme'
        $second = New-ProjectUserRecord -State $s -Project 'Acme'
        $second.uid      | Should -Be $first.uid
        $second.password | Should -Be $first.password
        $s.uidAllocator.next | Should -Be 30001
    }

    It 'allocates distinct users + uids for distinct projects' {
        $s = Initialize-State -DistroName 'tu'
        $a = New-ProjectUserRecord -State $s -Project 'A'
        $b = New-ProjectUserRecord -State $s -Project 'B'
        $a.user | Should -Not -Be $b.user
        $a.uid  | Should -Not -Be $b.uid
    }
}

Describe 'State project-user accessors tolerate a v1-shaped state' {
    It 'Get-ProjectUser returns null when there is no users map' {
        Get-ProjectUser -State @{ distro = 'x' } -Project 'p' | Should -BeNullOrEmpty
    }

    It 'Set then Remove round-trips and reports removal' {
        $s = @{ distro = 'x' }
        Set-ProjectUserRecord -State $s -Project 'p' -Record @{ user = 'cp-p'; uid = 30000 }
        (Get-ProjectUser -State $s -Project 'p').user | Should -Be 'cp-p'
        (Remove-ProjectUserRecord -State $s -Project 'p') | Should -BeTrue
        (Remove-ProjectUserRecord -State $s -Project 'p') | Should -BeFalse
    }
}
