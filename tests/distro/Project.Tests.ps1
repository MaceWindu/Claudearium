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
            -Args @{ Verb='project'; SubVerb='add'; Arg='distrotest-a'; Remote=$script:remoteUrl; DefaultBranch='master' }

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
        $claudearium = Get-ClaudeariumScriptPath
        $out = & $claudearium project list -Name $script:distro -ProfilePath $script:profilePath -NonInteractive *>&1
        ($out -join "`n") | Should -Match 'distrotest-a'
    }
}

Describe 'project enable / disable round-trip via reconcile' -Tag 'distro' {
    # Disable should tear down the materialized mirror but leave the profile
    # entry alone; re-enable should bring the mirror back. Drives reconcile
    # with -Force so the destructive confirmation doesn't block the test.
    BeforeAll {
        # Use a distinct name from the 'project add / remove' suite so order-
        # of-execution within the file doesn't matter.
        $script:p = 'distrotest-toggle'
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='add'; Arg=$script:p; Remote=$script:remoteUrl; DefaultBranch='master' }
        Import-Module (Join-Path $script:repoRoot 'modules\Projects.psm1') -Force
    }

    AfterAll {
        # Drop the mirror + profile entry in case any assertion bailed early.
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg=$script:p; Force=$true } -AllowFail | Out-Null
    }

    It 'tears down the bare mirror when enabled is flipped to false' {
        Set-ProjectEnabledInProfile -ProfilePath $script:profilePath -Name $script:p -Enabled $false | Should -BeTrue

        # -Force on reconcile bypasses the destructive-apply prompt so the
        # test doesn't need a stdin pump.
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='reconcile'; Force=$true } | Out-Null

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "test -d /home/claude/mirrors/$($script:p).git && echo present || echo gone" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'

        # Profile entry must survive — that's the whole point of disable vs remove.
        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $entry = @($spec.projects | Where-Object { $_.name -eq $script:p })[0]
        $entry | Should -Not -BeNullOrEmpty
        [bool]$entry.enabled | Should -BeFalse
    }

    It 'recreates the bare mirror when enabled flips back to true' {
        Set-ProjectEnabledInProfile -ProfilePath $script:profilePath -Name $script:p -Enabled $true | Should -BeTrue

        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='reconcile'; Force=$true } | Out-Null

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "test -d /home/claude/mirrors/$($script:p).git && echo present || echo gone" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'present'
    }
}

Describe 'project move (distro -> host -> distro round-trip)' -Tag 'distro' {
    # End-to-end: start as distroProject, move to host (mirror gone, bin dir
    # appears, profile entry rewrites), move back (bin dir gone, mirror
    # reappears, profile entry rewrites again). Asserts the user-facing fields
    # survive the round trip.
    BeforeAll {
        $script:moveProj  = 'distrotest-move'
        $script:moveBase  = Join-Path ([System.IO.Path]::GetTempPath()) ("move-test-" + [Guid]::NewGuid().ToString('N'))
        $script:hostCheck = Join-Path $script:moveBase 'checkout'
        [void][System.IO.Directory]::CreateDirectory($script:hostCheck)
        Push-Location $script:hostCheck
        try {
            & git init -q -b master
            & git config user.email t@t
            & git config user.name  t
            Set-Content -LiteralPath (Join-Path $script:hostCheck 'README.md') -Value 'hi' -Encoding UTF8
            & git add README.md
            & git commit -qm init
        } finally { Pop-Location }

        # Seed the distro side as a distroProject with a tabColor we can
        # assert is preserved across both moves.
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
            Verb='project'; SubVerb='add'; Arg=$script:moveProj
            Remote=$script:remoteUrl; DefaultBranch='master'
        }
        # Inject a tabColor directly — project add doesn't prompt for it in
        # non-interactive mode. Read raw, mutate, write back.
        $raw = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($p in @($raw.projects)) {
            if ($p -is [hashtable] -and $p.name -eq $script:moveProj) { $p['tabColor'] = '#abc123' }
        }
        ($raw | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $script:profilePath -Encoding UTF8
    }

    AfterAll {
        # Best-effort cleanup: try the verb first, then nuke residual dirs.
        try {
            Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
                -Args @{ Verb='project'; SubVerb='remove'; Arg=$script:moveProj; Force=$true } -AllowFail | Out-Null
        } catch {}
        $sessionsDir = $script:hostCheck + '-sessions'
        foreach ($p in @($sessionsDir, $script:moveBase)) {
            if ($p -and (Test-Path -LiteralPath $p)) {
                try { Remove-Item -LiteralPath $p -Recurse -Force } catch {}
            }
        }
        # Also delete any .bak-<stamp> snapshots the verb produced.
        $bakGlob = "$script:profilePath.bak-*"
        Get-ChildItem -LiteralPath (Split-Path -Parent $script:profilePath) -Filter (Split-Path -Leaf $bakGlob) -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    It 'moves distroProject -> hostProject: mirror gone, bin dir present, profile rewrites' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
            Verb='project'; SubVerb='move'; Arg=$script:moveProj
            To='host'; HostCheckout=$script:hostCheck; Force=$true
        }

        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput -AllowFail `
            -Command "test -d /home/claude/mirrors/$($script:moveProj).git && echo present || echo gone"
        ($r.Output -join "`n").Trim() | Should -Be 'gone'

        $r2 = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput -AllowFail `
            -Command "test -d /home/claude/host-projects/$($script:moveProj)/bin && echo present || echo gone"
        ($r2.Output -join "`n").Trim() | Should -Be 'present'

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $entry = @(@($spec.projects) | Where-Object { $_.name -eq $script:moveProj })[0]
        $entry                       | Should -Not -BeNullOrEmpty
        [string]$entry.type          | Should -Be 'host'
        [string]$entry.hostCheckout  | Should -Be $script:hostCheck
        # tabColor must survive the mutation.
        [string]$entry.tabColor      | Should -Be '#abc123'
        # remote must be gone — a hostProject with a `remote` is a schema error.
        $entry.ContainsKey('remote') | Should -BeFalse
    }

    It 'writes a timestamped .bak snapshot next to the profile during the move' {
        $bakName = (Split-Path -Leaf $script:profilePath) + '.bak-*'
        $baks = Get-ChildItem -LiteralPath (Split-Path -Parent $script:profilePath) -Filter $bakName -ErrorAction SilentlyContinue
        @($baks).Count | Should -BeGreaterThan 0
    }

    It 'moves hostProject -> distroProject: bin dir gone, mirror back, profile rewrites' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
            Verb='project'; SubVerb='move'; Arg=$script:moveProj
            To='distro'; Remote=$script:remoteUrl; Force=$true
        }

        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput -AllowFail `
            -Command "test -d /home/claude/host-projects/$($script:moveProj) && echo present || echo gone"
        ($r.Output -join "`n").Trim() | Should -Be 'gone'

        $r2 = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput -AllowFail `
            -Command "test -d /home/claude/mirrors/$($script:moveProj).git && echo present || echo gone"
        ($r2.Output -join "`n").Trim() | Should -Be 'present'

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $entry = @(@($spec.projects) | Where-Object { $_.name -eq $script:moveProj })[0]
        $entry                               | Should -Not -BeNullOrEmpty
        $entry.ContainsKey('type')           | Should -BeFalse   # distro = default
        $entry.ContainsKey('hostCheckout')   | Should -BeFalse
        $entry.ContainsKey('hostShadows')    | Should -BeFalse
        [string]$entry.remote                | Should -Be $script:remoteUrl
        [string]$entry.tabColor              | Should -Be '#abc123'
    }
}

Describe 'project remove' -Tag 'distro' {
    It 'deletes the bare mirror and drops the profile entry' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg='distrotest-a'; Force=$true }

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command 'test -d /home/claude/mirrors/distrotest-a.git && echo present || echo gone' -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        if ($spec.ContainsKey('projects') -and $spec.projects) {
            ($spec.projects | Where-Object { $_.name -eq 'distrotest-a' }) | Should -BeNullOrEmpty
        }
    }
}
