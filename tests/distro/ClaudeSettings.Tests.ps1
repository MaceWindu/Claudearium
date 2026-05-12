# ClaudeSettings.Tests.ps1 — `claude-settings apply` writes the merged
# settings.json into /home/claude/.claude with the right shape + permissions.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot = $repoRoot
    $script:distro   = $distro

    # Write a profile with a claudeSettings block. Apply doesn't reconcile, so
    # we need the block already present.
    $script:cacheDir = Join-Path $repoRoot 'tests\.cache'
    $script:profilePath = Join-Path $script:cacheDir 'profile-claudesettings.json'
    $install = Join-Path $env:LOCALAPPDATA (Join-Path 'WSL' $distro)
    $spec = [ordered]@{
        schemaVersion = 1
        distro = [ordered]@{ name = $distro; base = 'debian-12'; installPath = $install }
        claudeSettings = [ordered]@{
            model         = 'claude-opus-4-7'
            defaultEffort = 'high'
            theme         = 'dark'
            autoApproveReadOnlyBash = $true
        }
    }
    ($spec | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $script:profilePath -Encoding UTF8
}

AfterAll {
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'claude-settings apply' -Tag 'distro' {
    BeforeAll {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('claude-settings', 'apply')
    }

    It 'writes /home/claude/.claude/settings.json owned by claude' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'stat -c "%U %a" /home/claude/.claude/settings.json' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'claude 644'
    }

    It "includes the bracketed model and the auto-approve allow-list" {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'cat /home/claude/.claude/settings.json' -CaptureOutput
        $txt = ($r.Output -join "`n")
        $txt | Should -Match 'claude-opus-4-7\[high\]'
        $txt | Should -Match 'Bash\(gh \*\)'
    }

    It 'embeds the distro name in env.CLAUDEARIUM_NAME (always-set layer)' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'cat /home/claude/.claude/settings.json' -CaptureOutput
        ($r.Output -join "`n") | Should -Match "CLAUDEARIUM_NAME.*$script:distro"
    }
}
