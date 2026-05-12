# ClaudeFile.Tests.ps1 — `reconcile` picks up profile.claudeFile and installs
# /home/claude/.claude/CLAUDE.md with the right content + ownership.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot = $repoRoot
    $script:distro   = $distro

    $script:cacheDir = Join-Path $repoRoot 'tests\.cache'
    if (-not (Test-Path $script:cacheDir)) { New-Item -ItemType Directory -Path $script:cacheDir -Force | Out-Null }
    $script:profilePath = Join-Path $script:cacheDir 'profile-claudefile.json'
    $install = Join-Path $env:LOCALAPPDATA (Join-Path 'WSL' $distro)
    $spec = [ordered]@{
        schemaVersion = 1
        distro        = [ordered]@{ name = $distro; base = 'debian-12'; installPath = $install }
        claudeFile    = [ordered]@{ mode = 'caveman-lite' }
    }
    ($spec | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $script:profilePath -Encoding UTF8

    # Pre-clean so this test doesn't depend on the order it runs in vs other
    # distro tests that may already have placed something at that path.
    Invoke-InDistro -Name $script:distro -User 'root' `
        -Command 'rm -f /home/claude/.claude/CLAUDE.md' -AllowFail | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
    Invoke-InDistro -Name $script:distro -User 'root' `
        -Command 'rm -f /home/claude/.claude/CLAUDE.md' -AllowFail | Out-Null
}

Describe 'Install-ClaudeFile (caveman-lite)' -Tag 'distro' {
    # We exercise Install-ClaudeFile directly rather than driving `reconcile`
    # via Invoke-Claudearium: reconcile's apply gate is a Read-YesNo with
    # Default=$false, which returns $false under -NonInteractive — so the
    # apply step never runs. The unit that matters here is the file write
    # itself (content, owner, mode), which Install-ClaudeFile is exactly.
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'modules\ClaudeFile.psm1') -Force
        Install-ClaudeFile -DistroName $script:distro -Spec @{ mode = 'caveman-lite' }
    }

    It 'writes /home/claude/.claude/CLAUDE.md owned by claude with mode 0644' {
        $r = Invoke-InDistro -Name $script:distro -User 'root' `
            -Command 'stat -c "%U %a" /home/claude/.claude/CLAUDE.md' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'claude 644'
    }

    It "stores exactly 'be brief.\n' for caveman-lite" {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'cat /home/claude/.claude/CLAUDE.md' -CaptureOutput
        ($r.Output -join "`n") | Should -Be 'be brief.'
    }
}
