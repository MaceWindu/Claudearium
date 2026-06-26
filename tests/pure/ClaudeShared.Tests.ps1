# ClaudeShared.Tests.ps1 — pure tests for modules/ClaudeShared.psm1, the
# claudeShared profile validation + Get-EffectiveClaudeShared / Get-ClaudeSharedDiff
# helpers in Profile.psm1, and the State backup-path helpers. No WSL2 needed.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')          -Force
    Import-Module (Join-Path $repoRoot 'modules\State.psm1')        -Force
    Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')      -Force
    Import-Module (Join-Path $repoRoot 'modules\ClaudeFile.psm1')   -Force
    Import-Module (Join-Path $repoRoot 'modules\ClaudeShared.psm1') -Force
    Import-Module (Join-Path $repoRoot 'modules\Mounts.psm1')       -Force

    $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("cs-tests-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null

    function New-BaseSpec { param([hashtable]$Extra)
        $s = @{ schemaVersion = 1; distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' } }
        if ($Extra) { foreach ($k in $Extra.Keys) { $s[$k] = $Extra[$k] } }
        return $s
    }
}

AfterAll {
    if (Test-Path $script:tmpDir) { Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Test-Profile claudeShared validation' {
    It 'accepts a well-formed claudeShared block' {
        $r = Test-Profile -Spec (New-BaseSpec @{ claudeShared = @{
            claudeMd = @{ mode = 'caveman-lite' }; importSkills = $true; importAgents = $false
            backup = @{ onNuke = $true; retain = 5; restorePrompt = $true }
        } })
        $r.IsValid | Should -BeTrue
    }

    It "accepts claudeMd mode 'skip'" {
        $r = Test-Profile -Spec (New-BaseSpec @{ claudeShared = @{ claudeMd = @{ mode = 'skip' } } })
        $r.IsValid | Should -BeTrue
    }

    It 'requires claudeMd.path when mode = custom-path' {
        $r = Test-Profile -Spec (New-BaseSpec @{ claudeShared = @{ claudeMd = @{ mode = 'custom-path' } } })
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'claudeMd.path is required'
    }

    It 'rejects an unknown claudeMd mode' {
        $r = Test-Profile -Spec (New-BaseSpec @{ claudeShared = @{ claudeMd = @{ mode = 'turbo' } } })
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'must be one of'
    }

    It 'rejects a non-boolean importSkills' {
        $r = Test-Profile -Spec (New-BaseSpec @{ claudeShared = @{ importSkills = 'yes' } })
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'importSkills must be true or false'
    }

    It 'rejects a negative backup.retain' {
        $r = Test-Profile -Spec (New-BaseSpec @{ claudeShared = @{ backup = @{ retain = -1 } } })
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'retain must be an integer'
    }

    It 'rejects a non-hashtable claudeShared' {
        $r = Test-Profile -Spec (New-BaseSpec @{ claudeShared = 'oops' })
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'claudeShared must be an object'
    }

    It 'warns when both claudeFile and claudeShared are set' {
        $r = Test-Profile -Spec (New-BaseSpec @{
            claudeFile   = @{ mode = 'caveman-lite' }
            claudeShared = @{ claudeMd = @{ mode = 'caveman-lite' } }
        })
        $r.IsValid | Should -BeTrue
        ($r.Warnings -join "`n") | Should -Match 'claudeShared wins'
    }
}

Describe 'Get-EffectiveClaudeShared' {
    It 'returns $null when neither block is present' {
        Get-EffectiveClaudeShared -Spec (New-BaseSpec) | Should -BeNullOrEmpty
    }

    It 'returns the claudeShared block verbatim when present' {
        $cs = @{ claudeMd = @{ mode = 'host-copy' }; importSkills = $true }
        $eff = Get-EffectiveClaudeShared -Spec (New-BaseSpec @{ claudeShared = $cs })
        $eff.claudeMd.mode | Should -Be 'host-copy'
        $eff.importSkills  | Should -BeTrue
    }

    It 'maps a legacy claudeFile block onto claudeMd' {
        $eff = Get-EffectiveClaudeShared -Spec (New-BaseSpec @{ claudeFile = @{ mode = 'custom-path'; path = 'C:\a\CLAUDE.md' } })
        $eff.claudeMd.mode | Should -Be 'custom-path'
        $eff.claudeMd.path | Should -Be 'C:\a\CLAUDE.md'
    }

    It 'prefers claudeShared when both are present' {
        $eff = Get-EffectiveClaudeShared -Spec (New-BaseSpec @{
            claudeFile   = @{ mode = 'caveman-lite' }
            claudeShared = @{ claudeMd = @{ mode = 'host-copy' } }
        })
        $eff.claudeMd.mode | Should -Be 'host-copy'
    }
}

Describe 'Get-ClaudeSharedDiff' {
    It 'reports no changes when the store is ready' {
        $d = Get-ClaudeSharedDiff -Ready $true
        $d.Changes.Count  | Should -Be 0
        $d.HasDestructive | Should -BeFalse
    }

    It 'reports a single safe add when the store is not ready' {
        $d = Get-ClaudeSharedDiff -Ready $false
        $d.Changes.Count     | Should -Be 1
        $d.Changes[0].Path   | Should -Be 'claudeShared'
        $d.Changes[0].Action | Should -Be 'add'
        $d.Changes[0].Severity | Should -Be 'safe'
        $d.HasDestructive    | Should -BeFalse
    }
}

Describe 'Select-ExpiredBackups' {
    BeforeAll {
        $script:files = @(
            'C:\b\claude-shared-20260101-000000.tar.gz'
            'C:\b\claude-shared-20260102-000000.tar.gz'
            'C:\b\claude-shared-20260103-000000.tar.gz'
            'C:\b\claude-shared-20260104-000000.tar.gz'
        )
    }

    It 'keeps everything when retain = 0 (unlimited)' {
        @(Select-ExpiredBackups -Files $script:files -Retain 0).Count | Should -Be 0
    }

    It 'keeps everything when count <= retain' {
        @(Select-ExpiredBackups -Files $script:files -Retain 4).Count | Should -Be 0
        @(Select-ExpiredBackups -Files $script:files -Retain 9).Count | Should -Be 0
    }

    It 'returns the oldest beyond the newest N' {
        $expired = @(Select-ExpiredBackups -Files $script:files -Retain 2)
        $expired.Count | Should -Be 2
        # Newest two (03, 04) kept; oldest two (01, 02) expired.
        @($expired | Where-Object { $_ -match '20260101' }).Count | Should -Be 1
        @($expired | Where-Object { $_ -match '20260102' }).Count | Should -Be 1
        @($expired | Where-Object { $_ -match '20260104' }).Count | Should -Be 0
    }

    It 'tolerates an empty / null input' {
        @(Select-ExpiredBackups -Files @() -Retain 5).Count | Should -Be 0
        @(Select-ExpiredBackups -Files $null -Retain 5).Count | Should -Be 0
    }
}

Describe 'State backup-path helpers' {
    It 'Get-BackupRoot lives under the state root' {
        (Get-BackupRoot) | Should -Be (Join-Path (Get-StateRoot) 'backups')
    }

    It 'Get-BackupDir nests the distro under the backup root' {
        (Get-BackupDir -DistroName 'demo') | Should -Be (Join-Path (Get-BackupRoot) 'demo')
    }

    It "refuses a distro literally named 'backups'" {
        { Get-BackupDir -DistroName 'backups' } | Should -Throw '*collides*'
    }
}

Describe 'ConvertTo-TarGzBase64' {
    It 'packs a directory into a valid gzip stream' {
        $src = Join-Path $script:tmpDir 'tree'
        New-Item -ItemType Directory -Path (Join-Path $src 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'a.md') -Value 'hello' -NoNewline
        Set-Content -LiteralPath (Join-Path $src 'sub\b.md') -Value 'world' -NoNewline
        $b64 = ConvertTo-TarGzBase64 -SourceDir $src
        $b64 | Should -Not -BeNullOrEmpty
        $bytes = [Convert]::FromBase64String($b64)
        # gzip magic number: 0x1f 0x8b.
        $bytes[0] | Should -Be 0x1f
        $bytes[1] | Should -Be 0x8b
    }

    It 'throws on a missing source directory' {
        { ConvertTo-TarGzBase64 -SourceDir (Join-Path $script:tmpDir 'nope') } | Should -Throw '*not found*'
    }
}

Describe 'Expand-TarGzToHostDir (shared-store host migration)' {
    It 'round-trips a packed tree back onto the host (pack -> write -> extract)' {
        $src = Join-Path $script:tmpDir 'mig-src'
        New-Item -ItemType Directory -Path (Join-Path $src 'skills\cs-x') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'CLAUDE.md') -Value 'hi' -NoNewline
        Set-Content -LiteralPath (Join-Path $src 'skills\cs-x\SKILL.md') -Value 'sk' -NoNewline

        $archive = Join-Path $script:tmpDir 'mig.tar.gz'
        [IO.File]::WriteAllBytes($archive, [Convert]::FromBase64String((ConvertTo-TarGzBase64 -SourceDir $src)))

        $dest = Join-Path $script:tmpDir 'mig-dest'
        Expand-TarGzToHostDir -ArchivePath $archive -DestDir $dest

        Get-Content -LiteralPath (Join-Path $dest 'CLAUDE.md') -Raw          | Should -Be 'hi'
        Get-Content -LiteralPath (Join-Path $dest 'skills\cs-x\SKILL.md') -Raw | Should -Be 'sk'
    }

    It 'throws on a missing archive' {
        { Expand-TarGzToHostDir -ArchivePath (Join-Path $script:tmpDir 'nope.tar.gz') -DestDir $script:tmpDir } |
            Should -Throw '*not found*'
    }
}

Describe 'ClaudeShared constants' {
    It 'exposes the guest store path' {
        Get-ClaudeSharedStorePath | Should -Be '/opt/claudearium/claude-shared'
    }

    It 'resolves host artifact dirs under %USERPROFILE%\.claude' {
        $prev = $env:USERPROFILE
        try {
            $env:USERPROFILE = 'C:\Users\demo'
            Get-HostClaudeDirPath -Sub 'skills' | Should -Be 'C:\Users\demo\.claude\skills'
            Get-HostClaudeDirPath -Sub 'agents' | Should -Be 'C:\Users\demo\.claude\agents'
        } finally { $env:USERPROFILE = $prev }
    }
}

Describe 'Shared store host mount (Mounts.psm1)' {
    It 'resolves the host folder under the state root (.claude)' {
        (Get-ClaudeSharedHostPath) | Should -Be (Join-Path (Get-StateRoot) '.claude')
    }

    It 'Get-MergedDesiredMounts always includes the host-mounted store' {
        $mounts = @(Get-MergedDesiredMounts -ProfileSpec $null -State $null)
        $store  = $mounts | Where-Object { [string]$_.guest -eq '/opt/claudearium/claude-shared' }
        $store                | Should -Not -BeNullOrEmpty
        [string]$store.host   | Should -Be (Get-ClaudeSharedHostPath)
        [string]$store.mode   | Should -Be 'rw'
        [string]$store.umask  | Should -Be '000'
        [bool]$store.metadata | Should -BeFalse
    }

    It 'emits the store fstab line world-writable with metadata OFF' {
        $line = Get-MountFstabLine -Mount @{
            host = 'C:\Users\demo\AppData\Local\claudearium\.claude'
            guest = '/opt/claudearium/claude-shared'; mode = 'rw'
            uid = 1000; gid = 1000; umask = '000'; metadata = $false
        }
        $line | Should -Match 'rw,'
        $line | Should -Match 'umask=000'
        $line | Should -Not -Match 'metadata'
        $line | Should -Match ([regex]::Escape('/opt/claudearium/claude-shared'))
    }

    It 'keeps metadata ON for ordinary mounts' {
        $line = Get-MountFstabLine -Mount @{ host = 'C:\Tools'; guest = '/host/tools'; mode = 'ro' }
        $line | Should -Match 'metadata'
    }
}

Describe 'Worktree-discipline managed block' {
    It 'wraps fixed guidance in the begin/end markers' {
        $b = Get-WorktreeDisciplineBlock
        $b | Should -Match 'claudearium-worktree-discipline-begin'
        $b | Should -Match 'claudearium-worktree-discipline-end'
        $b | Should -Match 'git worktree add'
        $b | Should -Match 'curation branch'
    }

    It 'appends the block to a file with no managed block (preserves user content)' {
        $out = Edit-ClaudeMdWithDisciplineBlock -Content "be brief.`n"
        $out | Should -Match '^be brief\.'
        $out | Should -Match 'claudearium-worktree-discipline-begin'
    }

    It 'is idempotent — re-applying replaces in place (one block only)' {
        $once  = Edit-ClaudeMdWithDisciplineBlock -Content "hello`n"
        $twice = Edit-ClaudeMdWithDisciplineBlock -Content $once
        $twice | Should -Be $once
        ([regex]::Matches($twice, 'claudearium-worktree-discipline-begin')).Count | Should -Be 1
    }

    It 'creates a block-only file from empty/null content' {
        $out = Edit-ClaudeMdWithDisciplineBlock -Content ''
        $out | Should -Match 'claudearium-worktree-discipline-begin'
        $outNull = Edit-ClaudeMdWithDisciplineBlock -Content $null
        $outNull | Should -Match 'claudearium-worktree-discipline-begin'
    }
}

Describe 'Isolation-model managed block' {
    It 'wraps fixed guidance in the begin/end markers' {
        $b = Get-IsolationModelBlock
        $b | Should -Match 'claudearium-isolation-model-begin'
        $b | Should -Match 'claudearium-isolation-model-end'
        $b | Should -Match 'WSL2'
        $b | Should -Match 'killswitch'
        $b | Should -Match 'host'
    }

    It 'appends the block to a file with no managed block (preserves user content)' {
        $out = Edit-ClaudeMdWithIsolationBlock -Content "be brief.`n"
        $out | Should -Match '^be brief\.'
        $out | Should -Match 'claudearium-isolation-model-begin'
    }

    It 'is idempotent — re-applying replaces in place (one block only)' {
        $once  = Edit-ClaudeMdWithIsolationBlock -Content "hello`n"
        $twice = Edit-ClaudeMdWithIsolationBlock -Content $once
        $twice | Should -Be $once
        ([regex]::Matches($twice, 'claudearium-isolation-model-begin')).Count | Should -Be 1
    }

    It 'coexists with the worktree-discipline block (both survive, one each)' {
        $withDisc = Edit-ClaudeMdWithDisciplineBlock -Content "be brief.`n"
        $withBoth = Edit-ClaudeMdWithIsolationBlock -Content $withDisc
        ([regex]::Matches($withBoth, 'claudearium-worktree-discipline-begin')).Count | Should -Be 1
        ([regex]::Matches($withBoth, 'claudearium-isolation-model-begin')).Count | Should -Be 1
        $withBoth | Should -Match '^be brief\.'
    }

    It 'creates a block-only file from empty/null content' {
        $out = Edit-ClaudeMdWithIsolationBlock -Content ''
        $out | Should -Match 'claudearium-isolation-model-begin'
        $outNull = Edit-ClaudeMdWithIsolationBlock -Content $null
        $outNull | Should -Match 'claudearium-isolation-model-begin'
    }
}
