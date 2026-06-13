# Mounts.Tests.ps1 — drvfs path encoding and fstab line round-tripping.
# These transforms underpin every `mount add/list/sync` invocation; getting
# the space-escape `\040` wrong silently breaks mounts with spaces in paths.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Mounts.psm1') -Force
}

Describe 'ConvertTo-DrvfsPath / ConvertFrom-DrvfsPath' {
    It 'converts backslashes to forward slashes' {
        ConvertTo-DrvfsPath -WindowsPath 'C:\Tools\Foo' | Should -Be 'C:/Tools/Foo'
    }

    It 'escapes spaces as \040 (drvfs convention)' {
        ConvertTo-DrvfsPath -WindowsPath 'C:\path with spaces' | Should -Be 'C:/path\040with\040spaces'
    }

    It 'round-trips through ConvertFrom-DrvfsPath' {
        $orig = 'C:\Users\foo bar\.ssh'
        ConvertFrom-DrvfsPath -DrvfsPath (ConvertTo-DrvfsPath -WindowsPath $orig) | Should -Be $orig
    }
}

Describe 'Get-DefaultMountOptions' {
    It 'defaults to ro,metadata,uid=1000,gid=1000,umask=022' {
        Get-DefaultMountOptions | Should -Be 'ro,metadata,uid=1000,gid=1000,umask=022'
    }

    It 'swaps in rw when requested' {
        Get-DefaultMountOptions -Mode 'rw' | Should -Be 'rw,metadata,uid=1000,gid=1000,umask=022'
    }

    It 'stamps a per-project-user uid/gid/umask when supplied' {
        Get-DefaultMountOptions -Mode 'rw' -Uid 30000 -Gid 30000 -Umask '077' |
            Should -Be 'rw,metadata,uid=30000,gid=30000,umask=077'
    }
}

Describe 'Get-MountFstabLine / ConvertFrom-FstabLine' {
    It 'produces a drvfs line ending with " 0 0"' {
        $m = @{ host = 'C:\foo'; guest = '/host/foo'; mode = 'ro' }
        $line = Get-MountFstabLine -Mount $m
        $line | Should -Match '^C:/foo /host/foo drvfs ro,metadata,uid=1000,gid=1000,umask=022 0 0$'
    }

    It 'appends custom options after the defaults' {
        $m = @{ host = 'C:\foo'; guest = '/host/foo'; mode = 'ro'; options = 'umask=077' }
        (Get-MountFstabLine -Mount $m) | Should -Match 'umask=022,umask=077 0 0$'
    }

    It 'honors per-mount uid/gid/umask keys (per-project-user ownership)' {
        $m = @{ host = 'C:\foo'; guest = '/home/cp-acme/host/feat-1'; mode = 'rw'; uid = 30000; gid = 30000; umask = '077' }
        (Get-MountFstabLine -Mount $m) |
            Should -Match '^C:/foo /home/cp-acme/host/feat-1 drvfs rw,metadata,uid=30000,gid=30000,umask=077 0 0$'
    }

    It 'still round-trips a per-user mount (uid/gid/umask stripped from parsed options)' {
        $m = @{ host = 'C:\foo'; guest = '/home/cp-acme/host/feat-1'; mode = 'rw'; uid = 30000; gid = 30000; umask = '077' }
        $parsed = ConvertFrom-FstabLine -Line (Get-MountFstabLine -Mount $m)
        $parsed.mode    | Should -Be 'rw'
        $parsed.options | Should -Be ''
    }

    It 'parses a drvfs line back into a record' {
        $orig = @{ host = 'C:\foo bar'; guest = '/host/foo bar'; mode = 'rw'; options = $null }
        $line = Get-MountFstabLine -Mount $orig
        $parsed = ConvertFrom-FstabLine -Line $line
        $parsed.host  | Should -Be 'C:\foo bar'
        $parsed.guest | Should -Be '/host/foo bar'
        $parsed.mode  | Should -Be 'rw'
    }

    It 'returns $null for comment lines' {
        ConvertFrom-FstabLine -Line '# managed-block' | Should -Be $null
    }

    It 'returns $null for non-drvfs lines' {
        ConvertFrom-FstabLine -Line 'tmpfs /tmp tmpfs defaults 0 0' | Should -Be $null
    }
}

Describe 'Resolve-DefaultGuestPath' {
    It 'lowercases the path leaf into a /host prefix' {
        Resolve-DefaultGuestPath -HostPath 'C:\Tools\MyTool' | Should -Be '/host/mytool'
    }

    It 'handles deeply nested paths' {
        Resolve-DefaultGuestPath -HostPath 'C:\a\b\c\Final' | Should -Be '/host/final'
    }
}

Describe 'Get-MergedDesiredMounts host launch-pad' {
    It 'mounts the hostCheckout at the host/main launch pad for a launch-pad host session' {
        $prof = @{ projects = @(@{ name = 'acme'; hostCheckout = 'C:\src\acme' }) }
        $state = @{
            users    = @{ acme = @{ user = 'cp-acme'; uid = 30001; gid = 30001; home = '/home/cp-acme' } }
            sessions = @(@{ project = 'acme'; name = 's1'; type = 'host'; tmux = 'cl-acme-s1' })
        }
        # Bare assignment, not @(...): Get-MergedDesiredMounts returns via the
        # `,$arr` idiom, and @()-wrapping nests it (wsl2-gotchas #25).
        $mounts = Get-MergedDesiredMounts -ProfileSpec $prof -State $state
        $lp = @($mounts | Where-Object { [string]$_.guest -eq '/home/cp-acme/host/main' })
        $lp.Count   | Should -Be 1
        $lp[0].host | Should -Be 'C:\src\acme'
        $lp[0].mode | Should -Be 'rw'
        $lp[0].uid  | Should -Be 30001
        $lp[0].umask | Should -Be '077'
    }

    It 'dedupes the launch-pad mount across parallel sessions of the same project' {
        $prof = @{ projects = @(@{ name = 'acme'; hostCheckout = 'C:\src\acme' }) }
        $state = @{
            users    = @{ acme = @{ user = 'cp-acme'; uid = 30001; gid = 30001; home = '/home/cp-acme' } }
            sessions = @(
                @{ project = 'acme'; name = 's1'; type = 'host' }
                @{ project = 'acme'; name = 's2'; type = 'host' }
            )
        }
        # Bare assignment, not @(...): Get-MergedDesiredMounts returns via the
        # `,$arr` idiom, and @()-wrapping nests it (wsl2-gotchas #25).
        $mounts = Get-MergedDesiredMounts -ProfileSpec $prof -State $state
        @($mounts | Where-Object { [string]$_.guest -eq '/home/cp-acme/host/main' }).Count | Should -Be 1
    }

    It 'still mounts a legacy per-session host worktree at its own guest path' {
        $prof = @{ projects = @(@{ name = 'acme'; hostCheckout = 'C:\src\acme' }) }
        $state = @{
            users    = @{ acme = @{ user = 'cp-acme'; uid = 30001; gid = 30001; home = '/home/cp-acme' } }
            sessions = @(@{ project = 'acme'; name = 'feat'; type = 'host'; hostWorktreePath = 'C:\src\acme-sessions\feat'; worktreePath = '/home/cp-acme/host/feat' })
        }
        # Bare assignment, not @(...): Get-MergedDesiredMounts returns via the
        # `,$arr` idiom, and @()-wrapping nests it (wsl2-gotchas #25).
        $mounts = Get-MergedDesiredMounts -ProfileSpec $prof -State $state
        @($mounts | Where-Object { [string]$_.guest -eq '/home/cp-acme/host/feat' }).Count | Should -Be 1
        # No launch-pad mount for a pure work-worktree session.
        @($mounts | Where-Object { [string]$_.guest -eq '/home/cp-acme/host/main' }).Count | Should -Be 0
    }
}
