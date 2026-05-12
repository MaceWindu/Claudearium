# Project.Tests.ps1 — happy-path coverage for the `project` verbs.
# Uses an in-distro bare repo as the "remote" so the test has zero network
# dependencies. Profile mutations land in a per-file temp profile, never the
# user's real %LOCALAPPDATA%\claudearium\claudearium.profile.json.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot = $repoRoot
    $script:distro   = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'project'

    # Set up an in-distro bare repo as the remote.
    Invoke-InDistroScript -Name $distro -User 'claude' -Script @'
set -e
rm -rf /tmp/test-remote.git /tmp/test-seed
git init --bare /tmp/test-remote.git >/dev/null
git -C /tmp/test-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/test-seed && cd /tmp/test-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo hi > README.md
git add . && git commit -qm init
git push -q /tmp/test-remote.git master
'@
    $script:remoteUrl = 'file:///tmp/test-remote.git'
}

AfterAll {
    Invoke-InDistro -Name $script:distro -User 'claude' `
        -Command 'rm -rf /tmp/test-remote.git /tmp/test-seed /home/claude/mirrors/distrotest-*.git' `
        -AllowFail -CaptureOutput | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'project add' -Tag 'distro' {
    It 'clones the bare mirror into /home/claude/mirrors and writes the profile entry' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('project', 'add', 'distrotest-a', '-Remote', $script:remoteUrl, '-DefaultBranch', 'master')

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -d /home/claude/mirrors/distrotest-a.git && echo ok' -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        ($spec.projects | Where-Object { $_.name -eq 'distrotest-a' }).remote | Should -Be $script:remoteUrl
    }
}

Describe 'project list' -Tag 'distro' {
    It 'lists the added project as materialized' {
        # `*>&1` merges Write-Host's Information stream into Output so we can
        # capture the rendered table. Plain `&` returns only Output, which is
        # empty for a verb that writes via Write-Host (the common case).
        $claudearium = Get-ClaudearcumScriptPath
        $out = & $claudearium project list -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        ($out -join "`n") | Should -Match 'distrotest-a'
    }
}

Describe 'project remove' -Tag 'distro' {
    It 'deletes the bare mirror and drops the profile entry' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs @('project', 'remove', 'distrotest-a', '-Force')

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -d /home/claude/mirrors/distrotest-a.git && echo present || echo gone' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        if ($spec.ContainsKey('projects') -and $spec.projects) {
            ($spec.projects | Where-Object { $_.name -eq 'distrotest-a' }) | Should -BeNullOrEmpty
        }
    }
}
