# ClaudeShared.Tests.ps1 — the shared account-level Claude store, now a Windows
# host folder drvfs-mounted into the distro: mount invariants (mounted + host
# folder present + subdirs), per-user symlinks, the two-way-sharing proof (the
# empirical gate that the mount's umask=000 lets DIFFERENT Linux users both read
# AND write/create — there is no longer a group/ACL to rely on), migrate-once
# symlink folding, the backup/restore round-trip, and symlink repair. Runs against
# the ephemeral test distro (whose store host folder is isolated via
# $env:CLAUDEARIUM_CLAUDE_SHARED_HOST — see tests/lib/TestDistro.psm1).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')          -Force
    Import-Module (Join-Path $repoRoot 'modules\Users.psm1')        -Force
    Import-Module (Join-Path $repoRoot 'modules\ClaudeShared.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Mounts.psm1')       -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force -ErrorAction SilentlyContinue
    $script:repoRoot = $repoRoot
    $script:distro   = $distro
    $script:store    = '/opt/claudearium/claude-shared'
    $script:hostDir  = Get-ClaudeSharedHostPath

    # Throwaway member users for the sharing assertions (uids well clear of the
    # 30000+ project-user allocator so we don't collide with real state).
    $script:userA = 'cp-csa'
    $script:userB = 'cp-csb'
    $script:userC = 'cp-csc'

    # The store mount is established by `setup`; just ensure the subdirs exist and
    # symlink two throwaway members in (no group membership in the host-mounted
    # model — the mount umask governs sharing). Idempotent.
    Initialize-ClaudeSharedStore -DistroName $script:distro
    New-ProjectUserInDistro -DistroName $script:distro -User $script:userA -Uid 59001 -Password (New-ProjectUserPassword)
    New-ProjectUserInDistro -DistroName $script:distro -User $script:userB -Uid 59002 -Password (New-ProjectUserPassword)
    foreach ($u in @('claude', $script:userA, $script:userB)) {
        Set-ClaudeSharedSymlinks -DistroName $script:distro -User $u -Home "/home/$u"
    }
    # Clean any leftover test skill from a prior run.
    Invoke-InDistro -Name $script:distro -User 'root' -Command "rm -rf $($script:store)/skills/cs-foo $($script:store)/skills/cs-bar" -AllowFail | Out-Null
}

AfterAll {
    foreach ($u in @($script:userA, $script:userB, $script:userC)) {
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "id -u $u >/dev/null 2>&1 && userdel -r $u 2>/dev/null || true" -AllowFail | Out-Null
    }
    Invoke-InDistro -Name $script:distro -User 'root' -Command "rm -rf $($script:store)/skills/cs-foo $($script:store)/skills/cs-bar" -AllowFail | Out-Null
}

Describe 'shared store invariants' -Tag 'distro' {
    It 'is a live drvfs mountpoint inside the distro' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "mountpoint -q $($script:store) && echo MOUNTED || echo NO" -CaptureOutput
        ($r.Output -join '').Trim() | Should -Be 'MOUNTED'
    }

    It 'is backed by the host folder (which exists on the Windows side)' {
        Test-Path -LiteralPath $script:hostDir | Should -BeTrue
    }

    It 'has the skills/agents/host-tools subdirs' {
        foreach ($sub in @('skills', 'agents', 'host-tools')) {
            $r = Invoke-InDistro -Name $script:distro -User 'root' `
                -Command "test -d $($script:store)/$sub && echo OK" -AllowFail -CaptureOutput
            ($r.Output -join '').Trim() | Should -Be 'OK'
        }
    }
}

Describe 'per-user symlinks' -Tag 'distro' {
    It 'symlinks ~/.claude/{CLAUDE.md,skills,agents,host-tools} into the store' {
        foreach ($name in @('CLAUDE.md', 'skills', 'agents', 'host-tools')) {
            $r = Invoke-InDistro -Name $script:distro -User 'root' `
                -Command "readlink /home/$($script:userA)/.claude/$name" -AllowFail -CaptureOutput
            ($r.Output -join '').Trim() | Should -Be "$($script:store)/$name"
        }
    }
}

Describe 'two-way runtime sharing' -Tag 'distro' {
    # The crux of the feature AND the empirical gate for the chosen mount options:
    # a skill an agent creates as one project user must be readable AND writable by
    # a DIFFERENT project user, and a third must be able to create a brand-new file
    # — all on the drvfs mount, where the only thing granting cross-user access is
    # the mount's umask=000 (no group/ACL). If the mount options were wrong this is
    # what fails.
    It 'lets user A create a skill that user B can read and modify' {
        $mk = "runuser -u $($script:userA) -- bash -lc 'mkdir -p ~/.claude/skills/cs-foo && printf A > ~/.claude/skills/cs-foo/SKILL.md'"
        Invoke-InDistro -Name $script:distro -User 'root' -Command $mk | Out-Null

        $read = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "runuser -u $($script:userB) -- bash -lc 'cat ~/.claude/skills/cs-foo/SKILL.md'" -CaptureOutput
        ($read.Output -join '').Trim() | Should -Be 'A'

        # The write that would fail on a non-world-writable (644) file.
        $append = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "runuser -u $($script:userB) -- bash -lc 'printf B >> ~/.claude/skills/cs-foo/SKILL.md'" -AllowFail -CaptureOutput
        $append.ExitCode | Should -Be 0

        $after = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "cat $($script:store)/skills/cs-foo/SKILL.md" -CaptureOutput
        ($after.Output -join '').Trim() | Should -Be 'AB'
    }

    It 'lets a different user create a brand-new file in the store' {
        $mk = "runuser -u $($script:userB) -- bash -lc 'printf X > ~/.claude/skills/cs-bar'"
        $r  = Invoke-InDistro -Name $script:distro -User 'root' -Command $mk -AllowFail -CaptureOutput
        $r.ExitCode | Should -Be 0

        $seen = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "cat $($script:store)/skills/cs-bar" -CaptureOutput
        ($seen.Output -join '').Trim() | Should -Be 'X'
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
