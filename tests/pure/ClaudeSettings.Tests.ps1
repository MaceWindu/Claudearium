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
    It 'brackets model with defaultEffort' {
        $s = Get-OpinionatedSettings -Spec @{ model = 'claude-opus-4-7'; defaultEffort = 'xhigh' }
        $s.model | Should -Be 'claude-opus-4-7[xhigh]'
    }

    It "doesn't double-bracket if the model already carries one" {
        $s = Get-OpinionatedSettings -Spec @{ model = 'claude-opus-4-7[low]'; defaultEffort = 'xhigh' }
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
