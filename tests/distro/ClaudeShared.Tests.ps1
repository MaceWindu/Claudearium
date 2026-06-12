# ClaudeShared.Tests.ps1 — the shared, group-writable account-level Claude store:
# store invariants (acl + owner/mode + default ACL), group membership, symlinks,
# the two-way-sharing proof (catches the umask-644 regression), migrate-once, and
# the backup/restore round-trip. Runs against the ephemeral test distro.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')          -Force
    Import-Module (Join-Path $repoRoot 'modules\Users.psm1')        -Force
    Import-Module (Join-Path $repoRoot 'modules\ClaudeShared.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force -ErrorAction SilentlyContinue
    $script:repoRoot = $repoRoot
    $script:distro   = $distro
    $script:store    = '/opt/claudearium/claude-shared'
    $script:grp      = 'claudeshared'

    # Throwaway member users for the sharing assertions (uids well clear of the
    # 30000+ project-user allocator so we don't collide with real state).
    $script:userA = 'cp-csa'
    $script:userB = 'cp-csb'
    $script:userC = 'cp-csc'

    # Provision the store + two members. Idempotent: setup already did most of
    # this, but the test must not depend on prior tests' ordering.
    Initialize-ClaudeSharedStore -DistroName $script:distro
    New-ProjectUserInDistro -DistroName $script:distro -User $script:userA -Uid 59001 -Password (New-ProjectUserPassword)
    New-ProjectUserInDistro -DistroName $script:distro -User $script:userB -Uid 59002 -Password (New-ProjectUserPassword)
    foreach ($u in @('claude', $script:userA, $script:userB)) {
        Add-UserToSharedGroup    -DistroName $script:distro -User $u
        Set-ClaudeSharedSymlinks -DistroName $script:distro -User $u -Home "/home/$u"
    }
    # Clean any leftover test skill from a prior run.
    Invoke-InDistro -Name $script:distro -User 'root' -Command "rm -rf $($script:store)/skills/cs-foo" -AllowFail | Out-Null
}

AfterAll {
    foreach ($u in @($script:userA, $script:userB, $script:userC)) {
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "id -u $u >/dev/null 2>&1 && userdel -r $u 2>/dev/null || true" -AllowFail | Out-Null
    }
    Invoke-InDistro -Name $script:distro -User 'root' -Command "rm -rf $($script:store)/skills/cs-foo" -AllowFail | Out-Null
}

Describe 'shared store invariants' -Tag 'distro' {
    It 'has the acl tools installed' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' -Command 'command -v setfacl >/dev/null 2>&1 && echo OK' -AllowFail -CaptureOutput
        ($r.Output -join '').Trim() | Should -Be 'OK'
    }

    It 'is owned root:claudeshared, mode 2775' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' -Command "stat -c '%U:%G %a' $($script:store)" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'root:claudeshared 2775'
    }

    It 'carries a default group:claudeshared:rwx ACL' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "getfacl -p $($script:store) 2>/dev/null | grep -c '^default:group:claudeshared:rwx'" -CaptureOutput
        ([int](($r.Output -join '').Trim())) | Should -BeGreaterThan 0
    }
}

Describe 'group membership + symlinks' -Tag 'distro' {
    It 'puts the lobby and project users in claudeshared' {
        foreach ($u in @('claude', $script:userA, $script:userB)) {
            $r = Invoke-InDistro -Name $script:distro -User 'root' -Command "id -nG $u" -CaptureOutput
            ($r.Output -join ' ') | Should -Match '\bclaudeshared\b'
        }
    }

    It 'symlinks ~/.claude/{CLAUDE.md,skills,agents,host-tools} into the store' {
        foreach ($name in @('CLAUDE.md', 'skills', 'agents', 'host-tools')) {
            $r = Invoke-InDistro -Name $script:distro -User 'root' `
                -Command "readlink /home/$($script:userA)/.claude/$name" -AllowFail -CaptureOutput
            ($r.Output -join '').Trim() | Should -Be "$($script:store)/$name"
        }
    }
}

Describe 'two-way runtime sharing' -Tag 'distro' {
    # The crux of the feature: a skill an agent creates as one project user must
    # be readable AND writable by another. If only setgid (not the default ACL)
    # were in place, userB's append would fail with mode-644 — this is the guard.
    It 'lets user A create a skill that user B can read and modify' {
        $mk = "runuser -u $($script:userA) -- bash -lc 'mkdir -p ~/.claude/skills/cs-foo && printf A > ~/.claude/skills/cs-foo/SKILL.md'"
        Invoke-InDistro -Name $script:distro -User 'root' -Command $mk | Out-Null

        $read = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "runuser -u $($script:userB) -- bash -lc 'cat ~/.claude/skills/cs-foo/SKILL.md'" -CaptureOutput
        ($read.Output -join '').Trim() | Should -Be 'A'

        # The write that fails under a non-group-writable (644) file.
        $append = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "runuser -u $($script:userB) -- bash -lc 'printf B >> ~/.claude/skills/cs-foo/SKILL.md'" -AllowFail -CaptureOutput
        $append.ExitCode | Should -Be 0

        $after = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "cat $($script:store)/skills/cs-foo/SKILL.md" -CaptureOutput
        ($after.Output -join '').Trim() | Should -Be 'AB'
    }
}

Describe 'migrate-once' -Tag 'distro' {
    It 'folds a pre-existing real CLAUDE.md into the (empty) store and replaces it with a symlink' {
        # Fresh user with a REAL ~/.claude/CLAUDE.md and an empty store CLAUDE.md.
        New-ProjectUserInDistro -DistroName $script:distro -User $script:userC -Uid 59003 -Password (New-ProjectUserPassword)
        $seed = @"
rm -f $($script:store)/CLAUDE.md
mkdir -p /home/$($script:userC)/.claude
printf 'MIGRATED\n' > /home/$($script:userC)/.claude/CLAUDE.md
chown -R $($script:userC):$($script:userC) /home/$($script:userC)/.claude
"@
        Invoke-InDistroScript -Name $script:distro -Script $seed -User 'root' | Out-Null

        Set-ClaudeSharedSymlinks -DistroName $script:distro -User $script:userC -Home "/home/$($script:userC)"

        # Store now holds the migrated content...
        $store = Invoke-InDistro -Name $script:distro -User 'root' -Command "cat $($script:store)/CLAUDE.md" -CaptureOutput
        ($store.Output -join "`n").Trim() | Should -Be 'MIGRATED'
        # ...and the user's file is now a symlink into the store.
        $link = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "readlink /home/$($script:userC)/.claude/CLAUDE.md" -AllowFail -CaptureOutput
        ($link.Output -join '').Trim() | Should -Be "$($script:store)/CLAUDE.md"
    }
}

Describe 'backup / restore round-trip' -Tag 'distro' {
    It 'snapshots the store and restores it after the content is destroyed' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cs-backup-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tar.gz')
        try {
            # Ensure there's something to back up.
            Invoke-InDistro -Name $script:distro -User 'root' `
                -Command "mkdir -p $($script:store)/skills/cs-foo && printf A > $($script:store)/skills/cs-foo/SKILL.md" | Out-Null

            (Backup-ClaudeSharedStore -DistroName $script:distro -DestPath $tmp) | Should -BeTrue
            Test-Path -LiteralPath $tmp | Should -BeTrue

            # Destroy the skill, then restore.
            Invoke-InDistro -Name $script:distro -User 'root' -Command "rm -rf $($script:store)/skills/cs-foo" | Out-Null
            Restore-ClaudeSharedStore -DistroName $script:distro -ArchivePath $tmp

            $r = Invoke-InDistro -Name $script:distro -User 'root' `
                -Command "cat $($script:store)/skills/cs-foo/SKILL.md" -AllowFail -CaptureOutput
            $r.ExitCode | Should -Be 0
            ($r.Output -join '').Trim() | Should -Be 'A'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'symlink repair' -Tag 'distro' {
    It 'repoints a drifted ~/.claude symlink back at the store' {
        # Break the skills symlink: replace it with a bogus one.
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "rm -f /home/$($script:userA)/.claude/skills && ln -s /tmp/bogus /home/$($script:userA)/.claude/skills" | Out-Null

        Set-ClaudeSharedSymlinks -DistroName $script:distro -User $script:userA -Home "/home/$($script:userA)"

        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "readlink /home/$($script:userA)/.claude/skills" -CaptureOutput
        ($r.Output -join '').Trim() | Should -Be "$($script:store)/skills"
    }
}
