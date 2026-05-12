# ClaudeFile.Tests.ps1 — pure tests for modules/ClaudeFile.psm1 and the
# Get-ClaudeFileDiff helper in Profile.psm1. No WSL2 needed.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')        -Force
    Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')    -Force
    Import-Module (Join-Path $repoRoot 'modules\ClaudeFile.psm1') -Force

    $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("cf-tests-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
}

AfterAll {
    if (Test-Path $script:tmpDir) { Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-ClaudeFileDesiredContent' {
    It "returns 'be brief.\n' for caveman-lite" {
        $r = Get-ClaudeFileDesiredContent -Spec @{ mode = 'caveman-lite' }
        $r | Should -Be "be brief.`n"
    }

    It 'normalizes CRLF to LF when reading from a custom path' {
        $src = Join-Path $script:tmpDir 'crlf.md'
        # Bytes: "line 1\r\nline 2\r\n" — explicit CRLF that Set-Content -NoNewline preserves.
        [IO.File]::WriteAllBytes($src, [byte[]](0x6c,0x69,0x6e,0x65,0x20,0x31,0x0d,0x0a,0x6c,0x69,0x6e,0x65,0x20,0x32,0x0d,0x0a))
        $r = Get-ClaudeFileDesiredContent -Spec @{ mode = 'custom-path'; path = $src }
        $r | Should -Be "line 1`nline 2`n"
        $r | Should -Not -Match "`r"
    }

    It 'throws when mode = custom-path but path is missing' {
        { Get-ClaudeFileDesiredContent -Spec @{ mode = 'custom-path' } } | Should -Throw '*path is required*'
    }

    It 'throws when mode = custom-path and path does not exist' {
        $bogus = Join-Path $script:tmpDir 'does-not-exist.md'
        { Get-ClaudeFileDesiredContent -Spec @{ mode = 'custom-path'; path = $bogus } } | Should -Throw '*not found*'
    }

    It 'throws on an unknown mode' {
        { Get-ClaudeFileDesiredContent -Spec @{ mode = 'bogus' } } | Should -Throw '*not valid*'
    }
}

Describe 'Get-ClaudeFileDiff' {
    It 'returns no changes when desired content is $null (block absent)' {
        $d = Get-ClaudeFileDiff -DesiredContent $null -ActualContent $null
        $d.Changes.Count | Should -Be 0
        $d.HasDestructive | Should -BeFalse
        $d.CanApplyInPlace | Should -BeTrue
    }

    It "emits one 'add' change when the distro file is absent" {
        $d = Get-ClaudeFileDiff -DesiredContent "be brief.`n" -ActualContent $null -ModeLabel 'caveman-lite'
        $d.Changes.Count | Should -Be 1
        $d.Changes[0].Action | Should -Be 'add'
        $d.Changes[0].Path   | Should -Be 'claudeFile'
        $d.Changes[0].To     | Should -Match 'caveman-lite'
    }

    It "emits one 'modify' change when content differs" {
        $d = Get-ClaudeFileDiff -DesiredContent "be brief.`n" -ActualContent 'something else'
        $d.Changes.Count | Should -Be 1
        $d.Changes[0].Action | Should -Be 'modify'
    }

    It 'returns no changes when content matches' {
        $d = Get-ClaudeFileDiff -DesiredContent "be brief.`n" -ActualContent "be brief.`n"
        $d.Changes.Count | Should -Be 0
    }

    It "treats an empty distro file as 'modify' (not 'add') when content differs" {
        $d = Get-ClaudeFileDiff -DesiredContent "be brief.`n" -ActualContent ''
        $d.Changes.Count | Should -Be 1
        $d.Changes[0].Action | Should -Be 'modify'
    }
}

Describe 'Test-Profile claudeFile validation' {
    It 'accepts a well-formed caveman-lite block' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeFile = @{ mode = 'caveman-lite' }
        }
        $r.IsValid | Should -BeTrue
    }

    It 'accepts a well-formed custom-path block' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeFile = @{ mode = 'custom-path'; path = 'C:\some\CLAUDE.md' }
        }
        $r.IsValid | Should -BeTrue
    }

    It 'rejects an unknown mode' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeFile = @{ mode = 'turbo' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'must be one of'
    }

    It 'requires path when mode = custom-path' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeFile = @{ mode = 'custom-path' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'path is required'
    }

    It 'warns when path is set for a non-custom-path mode' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeFile = @{ mode = 'caveman-lite'; path = 'C:\some.md' }
        }
        $r.IsValid | Should -BeTrue
        ($r.Warnings -join "`n") | Should -Match 'will be ignored'
    }

    It 'rejects a non-hashtable claudeFile' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeFile = 'oops'
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'claudeFile must be an object'
    }
}
