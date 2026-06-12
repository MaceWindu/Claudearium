# ClaudeSettings.Tests.ps1 — pure synthesis of settings.json from the
# always-set layer + the opinionated profile.claudeSettings block.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\ClaudeSettings.psm1') -Force
}

Describe 'Get-AlwaysSettings' {
    It 'embeds the distro name in env.CLAUDEARIUM_NAME' {
        (Get-AlwaysSettings -DistroName 'cla-x').env.CLAUDEARIUM_NAME | Should -Be 'cla-x'
    }

    It 'forces includeCoAuthoredBy=false' {
        (Get-AlwaysSettings -DistroName 'x').includeCoAuthoredBy | Should -BeFalse
    }

    It 'lists the dangerous-bash deny patterns' {
        $s = Get-AlwaysSettings -DistroName 'x'
        $s.permissions.deny | Should -Contain 'Bash(rm -rf /*)'
        $s.permissions.deny | Should -Contain 'Bash(curl * | sh *)'
    }
}

Describe 'Get-OpinionatedSettings' {
    It 'emits effortLevel from defaultEffort, leaving the model unbracketed' {
        $s = Get-OpinionatedSettings -Spec @{ model = 'claude-opus-4-7'; defaultEffort = 'xhigh' }
        $s.model       | Should -Be 'claude-opus-4-7'
        $s.effortLevel | Should -Be 'xhigh'
    }

    It 'passes a hand-bracketed model string through verbatim' {
        $s = Get-OpinionatedSettings -Spec @{ model = 'claude-opus-4-7[low]' }
        $s.model | Should -Be 'claude-opus-4-7[low]'
    }

    It 'allows the read-only bash bucket' {
        $s = Get-OpinionatedSettings -Spec @{ autoApproveReadOnlyBash = $true }
        $s.permissions.allow | Should -Contain 'Bash(git status *)'
        $s.permissions.allow | Should -Contain 'Bash(gh *)'
    }

    It 'allows the project-writes bucket' {
        $s = Get-OpinionatedSettings -Spec @{ autoApproveProjectWrites = $true }
        $s.permissions.allow | Should -Contain 'Edit'
        $s.permissions.allow | Should -Contain 'Write'
    }

    It 'wires claudelk hooks for the requested events' {
        $s = Get-OpinionatedSettings -Spec @{ claudelk = $true; claudelkEvents = @('Stop') }
        $s.hooks.ContainsKey('Stop') | Should -BeTrue
        $s.hooks.Stop[0].hooks[0].command | Should -Match "sb-claudelk color '#00ff00'"
    }

    It 'appends permissions.additionalAllow on top of the existing bucket' {
        $s = Get-OpinionatedSettings -Spec @{
            autoApproveReadOnlyBash = $true
            permissions = @{ additionalAllow = @('Bash(rg *)','Bash(jq *)') }
        }
        $s.permissions.allow | Should -Contain 'Bash(git status *)'
        $s.permissions.allow | Should -Contain 'Bash(rg *)'
        $s.permissions.allow | Should -Contain 'Bash(jq *)'
    }

    It 'records permissions.additionalDeny so Merge-Settings can union with sandbox denies' {
        $s = Get-OpinionatedSettings -Spec @{ permissions = @{ additionalDeny = @('Bash(rmdir /etc/*)') } }
        $s.permissions.deny | Should -Contain 'Bash(rmdir /etc/*)'
    }

    It 'maps permissions.additionalAsk onto permissions.ask' {
        $s = Get-OpinionatedSettings -Spec @{ permissions = @{ additionalAsk = @('Bash(git push *)') } }
        $s.permissions.ask | Should -Contain 'Bash(git push *)'
    }

    It 'maps editorMode and outputStyle verbatim' {
        $s = Get-OpinionatedSettings -Spec @{ editorMode = 'vim'; outputStyle = 'Explanatory' }
        $s.editorMode  | Should -Be 'vim'
        $s.outputStyle | Should -Be 'Explanatory'
    }

    It 'sets permissions.additionalDirectories and defaultMode' {
        $s = Get-OpinionatedSettings -Spec @{
            permissions = @{ additionalDirectories = @('/home/claude/scratch'); defaultMode = 'acceptEdits' }
        }
        $s.permissions.additionalDirectories | Should -Contain '/home/claude/scratch'
        $s.permissions.defaultMode | Should -Be 'acceptEdits'
    }

    It 'maps the new boolean and enum keys verbatim' {
        $s = Get-OpinionatedSettings -Spec @{
            alwaysThinkingEnabled        = $true
            autoUpdatesChannel           = 'latest'
            disableBypassPermissionsMode = $true
            cleanupPeriodDays            = 60
            tui                          = 'default'
            defaultShell                 = 'powershell'
        }
        $s.alwaysThinkingEnabled        | Should -BeTrue
        $s.autoUpdatesChannel           | Should -Be 'latest'
        $s.disableBypassPermissionsMode | Should -BeTrue
        $s.cleanupPeriodDays            | Should -Be 60
        $s.tui                          | Should -Be 'default'
        $s.defaultShell                 | Should -Be 'powershell'
    }
}

Describe 'ConvertTo-ClaudeSettingsJson with expanded surface' {
    It 'preserves sandbox hardcoded denies even when the profile sets additionalDeny' {
        $json = ConvertTo-ClaudeSettingsJson -DistroName 'x' -Spec @{
            permissions = @{ additionalDeny = @('Bash(custom-bad)') }
        }
        $obj = $json | ConvertFrom-Json
        $obj.permissions.deny | Should -Contain 'Bash(rm -rf /*)'
        $obj.permissions.deny | Should -Contain 'Bash(curl * | sh *)'
        $obj.permissions.deny | Should -Contain 'Bash(custom-bad)'
    }

    It 'lets profile cleanupPeriodDays override the 30-day default' {
        $json = ConvertTo-ClaudeSettingsJson -DistroName 'x' -Spec @{ cleanupPeriodDays = 90 }
        ($json | ConvertFrom-Json).cleanupPeriodDays | Should -Be 90
    }

    It 'preserves the 30-day default when profile omits cleanupPeriodDays' {
        $json = ConvertTo-ClaudeSettingsJson -DistroName 'x' -Spec @{ model = 'claude-opus-4-7' }
        ($json | ConvertFrom-Json).cleanupPeriodDays | Should -Be 30
    }
}

Describe 'Merge-Settings' {
    It 'concatenates and dedupes nested array values' {
        $a = @{ permissions = @{ allow = @('x','y'); deny = @('z') } }
        $b = @{ permissions = @{ allow = @('y','w') } }
        $m = Merge-Settings -Always $a -Opinionated $b
        ($m.permissions.allow | Sort-Object) | Should -Be (@('w','x','y') | Sort-Object)
        $m.permissions.deny | Should -Be @('z')
    }

    It 'lets Opinionated override scalar keys' {
        $a = @{ model = 'a'; theme = 'light' }
        $b = @{ model = 'b' }
        $m = Merge-Settings -Always $a -Opinionated $b
        $m.model | Should -Be 'b'
        $m.theme | Should -Be 'light'
    }
}

Describe 'ConvertTo-ClaudeSettingsJson' {
    It 'produces valid JSON that round-trips through ConvertFrom-Json' {
        $json = ConvertTo-ClaudeSettingsJson -DistroName 'x' -Spec @{ model = 'claude-opus-4-7' }
        $obj = $json | ConvertFrom-Json
        $obj.env.CLAUDEARIUM_NAME | Should -Be 'x'
        $obj.model               | Should -Be 'claude-opus-4-7'
        $obj.permissions.deny    | Should -Contain 'Bash(rm -rf /*)'
    }
}
