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
