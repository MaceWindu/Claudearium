# HostProjects.Tests.ps1 — end-to-end coverage for the hostProject lifecycle.
# Creates a real Windows-side git checkout in a temp dir, registers it as a
# hostProject, opens a session, and verifies the moving parts:
#   - profile entry shape (type=host, hostCheckout, hostShadows)
#   - per-project bin dir + init.sh deployed inside the distro
#   - sibling host worktree at `<checkout>-sessions/<name>` on the host
#   - fstab managed block contains the session mount
#   - cleanup is complete (no leftover worktree, no leftover mount, no
#     leftover bin dir after project remove)

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'hostproj'

    # Stand up a real working checkout on Windows. The test repo lives under
    # %TEMP%\hp-test-<guid>\, which double-acts as the hostCheckout for the
    # project under test and as a sandbox for `git worktree add` siblings.
    $script:projectSlug   = 'hpsamp'
    $script:hostBase      = Join-Path ([System.IO.Path]::GetTempPath()) ("hp-test-" + [Guid]::NewGuid().ToString('N'))
    $script:hostCheckout  = Join-Path $script:hostBase 'checkout'
    [void][System.IO.Directory]::CreateDirectory($script:hostCheckout)

    # The sessions-suffix dir (`<checkout>-sessions`) is what `git worktree
    # add` creates; we don't pre-create it but we DO need to remember the
    # path so AfterAll can scrub leftover dirs after a -Force teardown.
    $script:sessionsRoot = $script:hostCheckout + '-sessions'

    # Seed a single-commit master branch using the host's git. The session-new
    # path will worktree-add off this.
    Push-Location $script:hostCheckout
    try {
        & git init -q -b master
        & git config user.email 't@example.com'
        & git config user.name  'Test User'
        Set-Content -LiteralPath (Join-Path $script:hostCheckout 'README.md') -Value 'hi' -Encoding UTF8
        & git add README.md
        & git commit -qm init
    } finally {
        Pop-Location
    }
}

AfterAll {
    # Best-effort cleanup. The project-remove call should already have done
    # the heavy lifting; this is the safety net for tests that aborted
    # partway.
    try {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='project'; SubVerb='remove'; Arg=$script:projectSlug; Force=$true } -AllowFail | Out-Null
    } catch {}
    # Belt + suspenders: remove any leftover sessions-suffix dir.
    foreach ($path in @($script:sessionsRoot, $script:hostBase)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            try { Remove-Item -LiteralPath $path -Recurse -Force } catch {}
        }
    }
    if ($script:profilePath -and (Test-Path -LiteralPath $script:profilePath)) {
        Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
    }
}

Describe 'hostProject project add' -Tag 'distro' {
    It 'records type=host + hostCheckout + hostShadows in the profile' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
            Verb         = 'project'
            SubVerb      = 'add'
            Arg          = $script:projectSlug
            HostProject  = $true
            HostCheckout = $script:hostCheckout
            HostShadows  = @('pwsh', 'git')
        }

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $entry = @(@($spec.projects) | Where-Object { [string]$_.name -eq $script:projectSlug })[0]
        $entry                  | Should -Not -BeNullOrEmpty
        [string]$entry.type     | Should -Be 'host'
        [string]$entry.hostCheckout | Should -Be $script:hostCheckout
        @($entry.hostShadows)   | Should -Contain 'pwsh'
        @($entry.hostShadows)   | Should -Contain 'git'
    }

    It 'creates the per-project bin dir and init.sh inside the distro' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput `
            -Command "test -d /home/claude/host-projects/$($script:projectSlug)/bin && test -f /home/claude/host-projects/$($script:projectSlug)/init.sh && echo ok"
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'init.sh prepends the bin dir to PATH without mangling the PATH variable' {
        # The literal `$PATH` must survive into the file body. Reading the
        # file from disk (via cat over Invoke-InDistro) sidesteps the same
        # argv mangling that drove gotcha #20 in the first place.
        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput `
            -Command "cat /home/claude/host-projects/$($script:projectSlug)/init.sh"
        $body = ($r.Output -join "`n")
        $body | Should -Match 'export PATH='
        $body | Should -Match ([regex]::Escape("/home/claude/host-projects/$($script:projectSlug)/bin"))
        # Confirm `$PATH` is present as a literal token, not pre-expanded.
        $body | Should -Match ([regex]::Escape(':$PATH'))
    }
}

Describe 'hostProject session new' -Tag 'distro' {
    It 'creates a sibling host worktree and an fstab managed-block mount' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
            Verb    = 'session'
            SubVerb = 'new'
            Arg     = 'dev'
            Project = $script:projectSlug
            Branch  = 'master'
        }

        # Host-side worktree should exist as a sibling to the checkout.
        $expectedHostWt = Join-Path $script:sessionsRoot 'dev'
        Test-Path -LiteralPath $expectedHostWt | Should -BeTrue

        # The fstab managed block should now mention the guest mount path.
        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput `
            -Command "awk '/claudearium-managed-start/ {flag=1; next} /claudearium-managed-end/ {flag=0} flag' /etc/fstab"
        $fstabBody = ($r.Output -join "`n")
        $fstabBody | Should -Match ([regex]::Escape("/host/$($script:projectSlug)/dev"))
    }

    It 'mounts the host worktree at the per-session guest path with the seed file visible' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput `
            -Command "test -f /host/$($script:projectSlug)/dev/README.md && cat /host/$($script:projectSlug)/dev/README.md"
        ($r.Output -join "`n").Trim() | Should -Be 'hi'
    }
}

Describe 'hostProject session remove' -Tag 'distro' {
    It 'tears down the worktree and the mount, leaving the bin dir intact' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
            Verb    = 'session'
            SubVerb = 'remove'
            Arg     = 'dev'
            Project = $script:projectSlug
            Force   = $true
        }

        $expectedHostWt = Join-Path $script:sessionsRoot 'dev'
        Test-Path -LiteralPath $expectedHostWt | Should -BeFalse

        # The fstab managed block should no longer mention the mount.
        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput `
            -Command "awk '/claudearium-managed-start/ {flag=1; next} /claudearium-managed-end/ {flag=0} flag' /etc/fstab"
        ($r.Output -join "`n") | Should -Not -Match ([regex]::Escape("/host/$($script:projectSlug)/dev"))

        # The bin dir is project-scoped, not session-scoped — sessions come and
        # go but the wrappers stay until `project remove`.
        $b = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput `
            -Command "test -d /home/claude/host-projects/$($script:projectSlug)/bin && echo ok"
        ($b.Output -join "`n").Trim() | Should -Be 'ok'
    }
}

Describe 'hostProject project remove' -Tag 'distro' {
    It 'tears down the per-project bin dir but leaves the hostCheckout untouched' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath -Args @{
            Verb    = 'project'
            SubVerb = 'remove'
            Arg     = $script:projectSlug
            Force   = $true
        }

        # Profile no longer references the project.
        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        if ($spec.ContainsKey('projects') -and $spec.projects) {
            $hit = @(@($spec.projects) | Where-Object { [string]$_.name -eq $script:projectSlug })
            $hit.Count | Should -Be 0
        }

        # The distro-side bin dir is gone.
        $r = Invoke-InDistro -Name $script:distro -User 'claude' -CaptureOutput -AllowFail `
            -Command "test -d /home/claude/host-projects/$($script:projectSlug) && echo present || echo gone"
        ($r.Output -join "`n").Trim() | Should -Be 'gone'

        # The user's hostCheckout itself is untouched.
        Test-Path -LiteralPath $script:hostCheckout | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:hostCheckout 'README.md') | Should -BeTrue
    }
}
