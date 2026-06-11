# Temp.Tests.ps1 — end-to-end coverage for the `temp` verb. Stamps known
# files into each scratch dir, runs `temp clean -Scope all`, and asserts
# the wipe + preservation contract holds against a real ephemeral distro.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'temp'
}

AfterAll {
    if ($script:profilePath -and (Test-Path -LiteralPath $script:profilePath)) {
        Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
    }
}

Describe 'temp size + clean round-trip' -Tag 'distro' {
    BeforeAll {
        # Seed every scratch dir with a sentinel file + a couple of the
        # preserve-set subdirs in ~/.claude so the assertion has real
        # paths to check survival against. Single in-distro script so
        # setup is fast.
        Invoke-InDistroScript -Name $script:distro -User 'claude' -Script @'
set -e
mkdir -p /tmp/temptest && echo hi > /tmp/temptest/marker
mkdir -p /home/claude/.cache/temptest && echo hi > /home/claude/.cache/temptest/marker
mkdir -p /home/claude/.claude/projects/encoded && echo hi > /home/claude/.claude/projects/encoded/marker.jsonl
mkdir -p /home/claude/.claude/shell-snapshots && echo hi > /home/claude/.claude/shell-snapshots/marker.sh
mkdir -p /home/claude/.claude/todos && echo hi > /home/claude/.claude/todos/keep.json
mkdir -p /home/claude/.claude/plans && echo hi > /home/claude/.claude/plans/keep.md
mkdir -p /home/claude/.claude/host-tools && echo hi > /home/claude/.claude/host-tools/keep.txt
'@
    }

    It 'temp (bare) prints a four-line size table that mentions every scope' {
        $claudearium = Get-ClaudeariumScriptPath
        $out = & $claudearium temp -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        $txt = ($out -join "`n")
        $txt | Should -Match 'scope'
        $txt | Should -Match '\btmp\b'
        $txt | Should -Match '\bcache\b'
        $txt | Should -Match '\bclaude\b'
        $txt | Should -Match '\btotal\b'
    }

    It 'temp clean -Scope all -Force wipes the default set and preserves todos/plans/host-tools' {
        $claudearium = Get-ClaudeariumScriptPath
        & $claudearium temp clean -Scope all -Force `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1 | Out-Null

        # Wiped: use Invoke-InDistroScript (base64 transport) so `$p` in the
        # bash loop doesn't get mangled by the pwsh -> wsl.exe argv hop
        # (see wsl2-gotchas.md #1).
        $r = Invoke-InDistroScript -Name $script:distro -User 'claude' -CaptureOutput -AllowFail -Script @'
for p in /tmp/temptest /home/claude/.cache/temptest /home/claude/.claude/projects/encoded /home/claude/.claude/shell-snapshots/marker.sh; do
  [ -e "$p" ] && echo "$p: still here"
done
echo done
'@
        ($r.Output -join "`n") | Should -Not -Match 'still here'

        # Preserved:
        $r2 = Invoke-InDistroScript -Name $script:distro -User 'claude' -CaptureOutput -AllowFail -Script @'
for p in /home/claude/.claude/todos/keep.json /home/claude/.claude/plans/keep.md /home/claude/.claude/host-tools/keep.txt; do
  [ -f "$p" ] && echo "$p: ok" || echo "$p: MISSING"
done
'@
        $body = ($r2.Output -join "`n")
        $body | Should -Match '/home/claude/\.claude/todos/keep\.json: ok'
        $body | Should -Match '/home/claude/\.claude/plans/keep\.md: ok'
        $body | Should -Match '/home/claude/\.claude/host-tools/keep\.txt: ok'
    }

    It 'temp clean -Scope claude -IncludeTodos -IncludePlans wipes the extended set' {
        # Re-seed todos / plans so we have something to wipe in this test.
        Invoke-InDistroScript -Name $script:distro -User 'claude' -Script @'
set -e
mkdir -p /home/claude/.claude/todos /home/claude/.claude/plans
echo hi > /home/claude/.claude/todos/keep.json
echo hi > /home/claude/.claude/plans/keep.md
'@
        $claudearium = Get-ClaudeariumScriptPath
        & $claudearium temp clean -Scope claude -IncludeTodos -IncludePlans -Force `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1 | Out-Null

        $r = Invoke-InDistroScript -Name $script:distro -User 'claude' -CaptureOutput -AllowFail -Script @'
for p in /home/claude/.claude/todos/keep.json /home/claude/.claude/plans/keep.md; do
  [ -f "$p" ] && echo "$p: still here"
done
echo done
'@
        ($r.Output -join "`n") | Should -Not -Match 'still here'

        # host-tools/ should ALWAYS be preserved — we never expose a flag to
        # wipe it because the tool manages that tree itself.
        $r2 = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput -AllowFail `
            -Command "test -f /home/claude/.claude/host-tools/keep.txt && echo ok || echo missing"
        ($r2.Output -join "`n").Trim() | Should -Match '^ok'
    }
}

Describe 'temp covers per-project-user homes' -Tag 'distro' {
    # Under per-project user isolation, cache + claude scratch lives in each
    # project user's 0700 home, not /home/claude. The temp verb must fan its
    # size + clean over every home (Get-ScratchHomes -> -Homes); regression for
    # the bug where `temp size` under-reported and `temp clean` silently skipped
    # every cp-* user's scratch.
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'modules\State.psm1') -Force

        # In-distro bare remote so `project add` clones with no network.
        Invoke-InDistroScript -Name $script:distro -User 'root' -Script @'
set -e
rm -rf /tmp/temp-remote.git /tmp/temp-seed
git init --bare /tmp/temp-remote.git >/dev/null
git -C /tmp/temp-remote.git symbolic-ref HEAD refs/heads/master >/dev/null
mkdir /tmp/temp-seed && cd /tmp/temp-seed
git init -q -b master
git config user.email t@t && git config user.name t
echo hi > README.md
git add . && git commit -qm init
git push -q /tmp/temp-remote.git master
'@ | Out-Null

        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='add'; Arg='temptest-iso'; Remote='file:///tmp/temp-remote.git'; DefaultBranch='master' }

        $script:projHome = Get-TestProjectUserHome -DistroName $script:distro -Project 'temptest-iso'
        $u = [string]$script:projHome.User
        $h = [string]$script:projHome.Home

        # Empty the lobby cache so the ONLY cache bytes are the 4 MB blob we plant
        # in the project user's 0700 home — makes the size assertion deterministic
        # (before the fix this row read "0 B" because the project home was ignored).
        Invoke-InDistroScript -Name $script:distro -User 'root' -Script @"
set -e
rm -rf /home/claude/.cache/* /home/claude/.cache/.[!.]* 2>/dev/null || true
install -d -o '$u' -g '$u' -m 700 '$h/.cache/temptest'
head -c 4194304 /dev/zero > '$h/.cache/temptest/blob'
chown -R '$u':'$u' '$h/.cache'
"@ | Out-Null
    }

    AfterAll {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg='temptest-iso'; Force=$true } -AllowFail | Out-Null
        # Reclaim a user a bailed assertion may have left behind.
        Invoke-InDistroScript -Name $script:distro -User 'root' -AllowFail -Script @'
for u in $(getent passwd | awk -F: '$1 ~ /^cp-temptest-iso/ {print $1}'); do
  pkill -KILL -u "$u" 2>/dev/null || true
  userdel -r "$u" 2>/dev/null || true
done
rm -rf /tmp/temp-remote.git /tmp/temp-seed
'@ | Out-Null
    }

    It 'temp size counts a project user .cache, not just /home/claude' {
        $claudearium = Get-ClaudeariumScriptPath
        $out = & $claudearium temp -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        $txt = ($out -join "`n")
        # The 4 MB blob lives only in the cp-* user's home; the cache row must
        # render in megabytes (it read "0 B" before per-project homes were wired).
        $txt | Should -Match 'cache\s+\d+\.\dM'
    }

    It 'temp clean -Scope cache -Force wipes the project user .cache' {
        $claudearium = Get-ClaudeariumScriptPath
        & $claudearium temp clean -Scope cache -Force `
            -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1 | Out-Null

        $r = Invoke-InDistro -Name $script:distro -User 'root' -CaptureOutput -AllowFail `
            -Command "test -e '$($script:projHome.Home)/.cache/temptest/blob' && echo 'still here' || echo gone"
        ($r.Output -join "`n").Trim() | Should -Be 'gone'
    }
}
