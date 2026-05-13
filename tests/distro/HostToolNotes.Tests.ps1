# HostToolNotes.Tests.ps1 — end-to-end: attaching a drop-in catalog tool
# from the host puts a per-tool note at /home/claude/.claude/host-tools/<tool>.md
# and adds the managed block to /home/claude/.claude/CLAUDE.md. Detaching
# (Remove-HostToolFromProfile + Install-HostToolNotes) cleans both up.
#
# Uses a fabricated 'gh' host-tool entry pointing at a fake /host/... exe;
# we exercise the notes plumbing, not the wrapper-via-binfmt path (covered
# in HostTools.Tests.ps1).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')           -Force
    Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')       -Force
    Import-Module (Join-Path $repoRoot 'modules\HostTools.psm1')     -Force
    Import-Module (Join-Path $repoRoot 'modules\ClaudeFile.psm1')    -Force
    Import-Module (Join-Path $repoRoot 'modules\HostToolNotes.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force

    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'hosttoolnotes'

    # Seed CLAUDE.md to the caveman-lite content so the managed block has a
    # target. Without an existing CLAUDE.md, Install-HostToolNotes skips the
    # CLAUDE.md write (intentional — see module docs).
    Install-ClaudeFile -DistroName $distro -Spec @{ mode = 'caveman-lite' }
}

AfterAll {
    # Clean up: ensure no host-tools entries and run Install-HostToolNotes to
    # strip the managed block + remove per-tool note files.
    try {
        $spec = Read-Profile -Path $script:profilePath -Raw
        if ($spec.ContainsKey('hostTools')) { $spec.hostTools = @() }
        Write-Profile -Path $script:profilePath -Spec $spec
        Install-HostToolNotes -DistroName $script:distro -Spec $spec
    } catch { }
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'Install-HostToolNotes — drop-in attach round-trip' -Tag 'distro' {
    It 'writes /home/claude/.claude/host-tools/gh.md when gh is host-attached' {
        $spec = Read-Profile -Path $script:profilePath -Raw
        if (-not $spec.ContainsKey('hostTools')) { $spec['hostTools'] = @() }
        $spec.hostTools = @(@{ name = 'gh'; windowsExe = '/host/fakedir/gh.exe'; guestCommand = 'gh' })
        Write-Profile -Path $script:profilePath -Spec $spec

        Install-HostToolNotes -DistroName $script:distro -Spec $spec
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -f /home/claude/.claude/host-tools/gh.md && echo ok' -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'puts the managed block into /home/claude/.claude/CLAUDE.md' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'cat /home/claude/.claude/CLAUDE.md' -CaptureOutput
        $body = ($r.Output -join "`n")
        $body | Should -Match 'claudearium-host-tools-begin'
        $body | Should -Match 'claudearium-host-tools-end'
        $body | Should -Match 'host-tools/gh.md'
        # The pre-existing caveman-lite content survives:
        $body | Should -Match '(?ms)^be brief\.$'
    }

    It 'leaves the gh.md content matching the shipped template' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'cat /home/claude/.claude/host-tools/gh.md' -CaptureOutput
        ($r.Output -join "`n") | Should -Match 'wslpath -w'
    }

    It 'is idempotent — re-running does not duplicate the managed block' {
        $spec = Read-Profile -Path $script:profilePath -Raw
        Install-HostToolNotes -DistroName $script:distro -Spec $spec
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "grep -c 'claudearium-host-tools-begin' /home/claude/.claude/CLAUDE.md" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be '1'
    }

    It 'removes the per-tool .md and strips the managed block when the host-tool is detached' {
        $spec = Read-Profile -Path $script:profilePath -Raw
        $spec.hostTools = @()
        Write-Profile -Path $script:profilePath -Spec $spec
        Install-HostToolNotes -DistroName $script:distro -Spec $spec

        # gh.md gone:
        $r1 = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -e /home/claude/.claude/host-tools/gh.md && echo present || echo gone' -CaptureOutput
        ($r1.Output -join "`n").Trim() | Should -Be 'gone'

        # Managed block stripped, caveman-lite content preserved:
        $r2 = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'cat /home/claude/.claude/CLAUDE.md' -CaptureOutput
        $body = ($r2.Output -join "`n")
        $body | Should -Not -Match 'claudearium-host-tools-begin'
        $body | Should -Match '(?ms)^be brief\.$'
    }

    It 'does not touch CLAUDE.md if it is absent' {
        # Remove CLAUDE.md, re-attach gh, run apply — should write the note
        # file but NOT create CLAUDE.md.
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'rm -f /home/claude/.claude/CLAUDE.md' | Out-Null
        $spec = Read-Profile -Path $script:profilePath -Raw
        $spec.hostTools = @(@{ name = 'gh'; windowsExe = '/host/fakedir/gh.exe'; guestCommand = 'gh' })
        Write-Profile -Path $script:profilePath -Spec $spec
        Install-HostToolNotes -DistroName $script:distro -Spec $spec

        # The per-tool note IS written:
        $r1 = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -f /home/claude/.claude/host-tools/gh.md && echo ok' -CaptureOutput -AllowFail
        ($r1.Output -join "`n").Trim() | Should -Be 'ok'

        # But CLAUDE.md is NOT recreated:
        $r2 = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -e /home/claude/.claude/CLAUDE.md && echo present || echo absent' -CaptureOutput
        ($r2.Output -join "`n").Trim() | Should -Be 'absent'

        # Re-seed CLAUDE.md so the per-Describe AfterAll cleanup has something
        # to work with, and so other tests in the same distro lane that
        # depend on /home/claude/.claude/CLAUDE.md aren't affected.
        Install-ClaudeFile -DistroName $script:distro -Spec @{ mode = 'caveman-lite' }
    }
}
