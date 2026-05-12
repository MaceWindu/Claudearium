# Diff.Tests.ps1 — pure tests for the per-block diff functions in
# modules/Profile.psm1. These produce the change-set the reconciler displays
# and applies; getting the Severity/Action shape wrong means destructive
# operations could be silently swallowed.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Profile.psm1') -Force
}

Describe 'Get-DistroBlockDiff' {
    It 'reports no changes when desired matches current' {
        $r = Get-DistroBlockDiff `
            -DesiredDistro @{ name = 'cla'; base = 'debian-12'; installPath = 'C:\WSL\cla' } `
            -CurrentState  @{ distro = 'cla'; installPath = 'C:\WSL\cla' }
        $r.Changes.Count   | Should -Be 0
        $r.HasDestructive  | Should -BeFalse
        $r.CanApplyInPlace | Should -BeTrue
    }

    It 'flags a distro rename as destructive + requires recreate' {
        $r = Get-DistroBlockDiff `
            -DesiredDistro @{ name = 'cla2'; base = 'debian-12'; installPath = 'C:\WSL\cla' } `
            -CurrentState  @{ distro = 'cla';  installPath = 'C:\WSL\cla' }
        $r.HasDestructive       | Should -BeTrue
        $r.Changes[0].Path      | Should -Be 'distro.name'
        $r.Changes[0].Severity  | Should -Be 'destructive'
        $r.Changes[0].RequiresRecreate | Should -BeTrue
    }

    It 'flags an installPath change as destructive' {
        $r = Get-DistroBlockDiff `
            -DesiredDistro @{ name = 'cla'; base = 'debian-12'; installPath = 'D:\elsewhere' } `
            -CurrentState  @{ distro = 'cla'; installPath = 'C:\WSL\cla' }
        $r.HasDestructive | Should -BeTrue
        ($r.Changes | Where-Object { $_.Path -eq 'distro.installPath' }).Severity | Should -Be 'destructive'
    }
}

Describe 'Get-ProjectsDiff' {
    It 'reports add when a project is in desired but not actual' {
        $r = Get-ProjectsDiff `
            -DesiredProjects @(@{ name = 'p1'; remote = 'git@host:p1.git' }) `
            -ActualProjects  @()
        $r.Changes.Count       | Should -Be 1
        $r.Changes[0].Action   | Should -Be 'add'
        $r.Changes[0].Severity | Should -Be 'safe'
    }

    It 'reports remove (destructive) when a project is in actual but not desired' {
        $r = Get-ProjectsDiff `
            -DesiredProjects @() `
            -ActualProjects  @(@{ name = 'gone'; remote = 'git@host:gone.git' })
        $r.HasDestructive | Should -BeTrue
        $r.Changes[0].Action | Should -Be 'remove'
    }

    It 'reports modify (destructive) when remote URL changes' {
        $r = Get-ProjectsDiff `
            -DesiredProjects @(@{ name = 'p1'; remote = 'git@new:p1.git' }) `
            -ActualProjects  @(@{ name = 'p1'; remote = 'git@old:p1.git' })
        $r.Changes[0].Action | Should -Be 'modify'
        $r.Changes[0].Path   | Should -Be 'projects.p1.remote'
        $r.HasDestructive    | Should -BeTrue
    }
}

Describe 'Get-HostMountsDiff' {
    It 'flags an added mount as safe' {
        $r = Get-HostMountsDiff `
            -DesiredMounts @(@{ host = 'C:\foo'; guest = '/host/foo'; mode = 'ro' }) `
            -ActualMounts  @()
        $r.Changes[0].Action   | Should -Be 'add'
        $r.Changes[0].Severity | Should -Be 'safe'
        $r.HasDestructive      | Should -BeFalse
    }

    It 'flags a mode change as modify (safe)' {
        $r = Get-HostMountsDiff `
            -DesiredMounts @(@{ host = 'C:\foo'; guest = '/host/foo'; mode = 'rw' }) `
            -ActualMounts  @(@{ host = 'C:\foo'; guest = '/host/foo'; mode = 'ro' })
        $r.Changes[0].Action | Should -Be 'modify'
    }

    It 'flags removal as safe (host mounts can always be reapplied)' {
        $r = Get-HostMountsDiff `
            -DesiredMounts @() `
            -ActualMounts  @(@{ host = 'C:\foo'; guest = '/host/foo'; mode = 'ro' })
        $r.Changes[0].Action   | Should -Be 'remove'
        $r.HasDestructive      | Should -BeFalse
    }
}

Describe 'Get-ToolsDiff' {
    It 'adds an enabled-but-missing tool' {
        $r = Get-ToolsDiff `
            -DesiredTools @{ gh = @{ enabled = $true; version = 'latest' } } `
            -ActualTools  @(@{ name = 'gh'; installed = $false; version = '' })
        $r.Changes[0].Path     | Should -Be 'tools.gh'
        $r.Changes[0].Action   | Should -Be 'add'
        $r.Changes[0].Severity | Should -Be 'safe'
    }

    It 'flags a disabled-but-installed tool as modify (no auto-uninstall)' {
        $r = Get-ToolsDiff `
            -DesiredTools @{ gh = @{ enabled = $false; version = 'latest' } } `
            -ActualTools  @(@{ name = 'gh'; installed = $true; version = '2.0.0' })
        $r.Changes[0].Action | Should -Be 'modify'
        $r.Changes[0].To     | Should -Be '(disabled)'
    }

    It 'returns empty changes when desired tools is $null' {
        $r = Get-ToolsDiff -DesiredTools $null -ActualTools @()
        $r.Changes.Count | Should -Be 0
    }
}

Describe 'Get-HostToolsDiff' {
    It 'adds a host tool present in desired but not actual' {
        $r = Get-HostToolsDiff `
            -DesiredTools @(@{ guestCommand = 'sb-foo'; windowsExe = 'C:\foo.exe' }) `
            -ActualTools  @()
        $r.Changes[0].Action | Should -Be 'add'
    }

    It 'modifies a host tool whose windowsExe changed' {
        $r = Get-HostToolsDiff `
            -DesiredTools @(@{ guestCommand = 'sb-foo'; windowsExe = 'C:\foo-v2.exe' }) `
            -ActualTools  @(@{ guestCommand = 'sb-foo'; windowsExe = 'C:\foo-v1.exe' })
        $r.Changes[0].Action | Should -Be 'modify'
    }
}
