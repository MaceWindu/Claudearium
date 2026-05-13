# Gotchas.Tests.ps1 — static-analysis regressions for known-bad
# patterns documented in docs/wsl2-gotchas.md. Each test ensures the
# corresponding bug class can't sneak back in via new code.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $script:repoRoot   = $repoRoot
    $script:modulesDir = Join-Path $repoRoot 'modules'
    $script:modules    = Get-ChildItem -Path $script:modulesDir -Filter '*.psm1' -File
    $script:psFiles    = Get-ChildItem -Path $script:modulesDir -File -Include '*.ps1','*.psm1' -Recurse
}

Describe 'Gotcha #2: profile array reads always wrap with @()' {
    It 'every .projects / .hostMounts / .hostTools read in Profile.psm1 is @()-wrapped' {
        # The fix pattern is `@($Spec.projects)` etc. — never bare `$Spec.projects`
        # inside a foreach. We grep for the bare form and expect zero hits in
        # production code.
        $body = Get-Content -LiteralPath (Join-Path $script:modulesDir 'Profile.psm1') -Raw
        # Look for `foreach .* in $Spec.<arrayKey>` without @(...). This is
        # heuristic — false positives are accepted as long as production code
        # follows the convention.
        $bad = $body -split "`n" | Where-Object {
            $_ -match 'foreach\s*\([^)]+in\s+\$Spec\.(projects|hostMounts|hostTools)\b' -and
            $_ -notmatch '@\('
        }
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Gotcha #10: child modules do not Import-Module -Force their deps' {
    It 'no .psm1 under modules/ uses -Force on Import-Module' {
        $bad = @()
        foreach ($f in $script:modules) {
            $body = Get-Content -LiteralPath $f.FullName -Raw
            if ($body -match '(?m)^[^#]*Import-Module\s[^#\n]*-Force') {
                $bad += $f.Name
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'cascading -Force re-imports invalidate the parent script''s -Force import (see docs/wsl2-gotchas.md#10)'
    }
}

Describe 'Gotcha #13: no awk -v anywhere in module sources' {
    It 'no .ps1/.psm1 in modules/ contains the string `awk -v`' {
        # `awk -v VAR=val` gets corrupted on the pwsh -> wsl.exe argv hop.
        # The replacement pattern uses inline /pattern/ literals.
        $hits = @()
        foreach ($f in $script:psFiles) {
            $body = Get-Content -LiteralPath $f.FullName -Raw
            # Match `awk` followed by `-v` somewhere — anywhere in the file, including comments.
            # Then exclude documentation/test files.
            if ($body -match '(?m)awk\s+-v\b' -and
                $f.FullName -notlike '*tests*Gotchas.Tests.ps1') {
                $hits += $f.Name
            }
        }
        $hits | Should -BeNullOrEmpty -Because 'awk -v with literal strings is flaky through the pwsh -> wsl argv chain (see docs/wsl2-gotchas.md#13)'
    }
}

Describe 'Gotcha #14: no inline -replace inside [Text.Encoding]::*::GetBytes' {
    It "no .psm1 calls GetBytes(`$x -replace ...) with both args inline" {
        # Pattern: `[Text.Encoding]::UTF8.GetBytes($foo -replace ..., ...)` —
        # pwsh parses this as TWO args, not one. The fix is to do the
        # -replace into a variable first.
        $bad = @()
        foreach ($f in $script:modules) {
            $body = Get-Content -LiteralPath $f.FullName -Raw
            # Match GetBytes( ... -replace ... , ... ) where the comma is the
            # second arg of -replace. Heuristic: GetBytes followed by -replace.
            if ($body -match '\bGetBytes\s*\(\s*\$[A-Za-z_][\w]*\s+-replace\b') {
                $bad += $f.Name
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'pwsh parses [...]::GetBytes($x -replace a, b) as a 2-arg call, not a 1-arg call (see docs/wsl2-gotchas.md#14)'
    }
}

Describe 'Gotcha #15: no Ensure-* function names (unapproved verb)' {
    It 'no `function Ensure-*` declarations under modules/ (exported or private)' {
        $bad = @()
        foreach ($f in $script:modules) {
            $body = Get-Content -LiteralPath $f.FullName -Raw
            $matches = [regex]::Matches($body, '(?m)^function\s+Ensure-[\w-]+')
            foreach ($m in $matches) { $bad += ($f.Name + ': ' + $m.Value) }
        }
        $bad | Should -BeNullOrEmpty -Because 'Ensure- is not on the approved verb list; use Initialize-/Set-/Install-/New-/Update- (see docs/wsl2-gotchas.md#15)'
    }
}

Describe 'Entry-point scripts capture script-root $PSBoundParameters before functions read it' {
    It 'claudearium.ps1 and open-claudearium.ps1 reference $Script:RootBoundParams (not bare $PSBoundParameters) inside functions' {
        # The bug this guards: inside a function with no params,
        # $PSBoundParameters rebinds to the FUNCTION's bound params (empty)
        # instead of the script's. So a check like
        # `$PSBoundParameters.ContainsKey('Name')` is silently always-false,
        # and `setup -Name claudearium-test` gets clobbered by the profile's
        # distro.name. Once wiped the user's real distro that way. The
        # fix pattern is to snapshot $PSBoundParameters at script root into
        # $Script:RootBoundParams and reference THAT from helpers.
        $entryScripts = @(
            (Join-Path $script:repoRoot 'claudearium.ps1'),
            (Join-Path $script:repoRoot 'open-claudearium.ps1')
        )
        foreach ($s in $entryScripts) {
            $body = Get-Content -LiteralPath $s -Raw
            # Must capture at script root.
            $body | Should -Match '\$Script:RootBoundParams\s*=\s*\$PSBoundParameters' `
                -Because "$([System.IO.Path]::GetFileName($s)) must snapshot script-root `$PSBoundParameters into `$Script:RootBoundParams"

            # No remaining bare `$PSBoundParameters.ContainsKey(` outside of
            # comments. We strip comment-only lines and `# ...` trailing
            # comments before scanning so the docs explaining this exact
            # bug-class don't trip the test.
            $codeLines = Get-Content -LiteralPath $s | ForEach-Object {
                if ($_ -match '^\s*#') { '' } else { $_ -replace '\s+#.*$', '' }
            }
            $bare = @()
            foreach ($line in $codeLines) {
                if ($line -match '(?<![A-Za-z:])\$PSBoundParameters\s*\.\s*ContainsKey\s*\(') {
                    $bare += $line
                }
            }
            $bare | Should -BeNullOrEmpty `
                -Because "$([System.IO.Path]::GetFileName($s)) has bare `$PSBoundParameters.ContainsKey(...) inside a function — use `$Script:RootBoundParams.ContainsKey(...) instead"
        }
    }
}

Describe 'Pester `It` descriptions: no `<word>` placeholders' {
    It "no test description under tests/ contains a Pester TestCases template placeholder" {
        # `<word>` in an It/Describe description is interpreted as a TestCases
        # template substitution. With no -TestCases, Pester evaluates `$word`
        # and under StrictMode it errors with "variable not set". We've stepped
        # on this twice — keep us honest going forward.
        $testFiles = Get-ChildItem -Path (Join-Path $script:repoRoot 'tests') -File -Include '*.ps1','*.psm1' -Recurse |
            Where-Object { $_.Name -notlike 'Gotchas.Tests.ps1' }
        $bad = @()
        foreach ($f in $testFiles) {
            # Match `It '...<word>...'` or `It "...<word>..."` and Describe with the same.
            # Be permissive with whitespace/parens.
            $body = Get-Content -LiteralPath $f.FullName -Raw
            $matchesFound = [regex]::Matches($body, "(?m)^\s*(?:It|Describe)\s+['""][^'""]*<[A-Za-z_]")
            foreach ($m in $matchesFound) { $bad += ($f.Name + ': ' + $m.Value.Trim()) }
        }
        $bad | Should -BeNullOrEmpty -Because 'Pester treats `<word>` in It/Describe descriptions as a TestCases placeholder — under StrictMode this errors with "variable not set"'
    }
}

Describe 'Gotcha #4: no `systemctl --now` or bare `systemctl start` in install paths' {
    It 'no .psm1 / entry-point uses `systemctl enable --now` or `systemctl start` outside Disable-/Reset-' {
        # `--now` and `start` can hang in WSL2. Install paths must use plain
        # `systemctl enable` and trigger the unit's effect inline (call the
        # binary directly, run the prep script, etc.).
        $targets = @(
            $script:modules.FullName
            (Join-Path $script:repoRoot 'claudearium.ps1')
            (Join-Path $script:repoRoot 'open-claudearium.ps1')
        )
        $bad = @()
        foreach ($path in $targets) {
            $name = [IO.Path]::GetFileName($path)
            $body = Get-Content -LiteralPath $path -Raw
            # `--now` is always a hazard.
            $nowHits = [regex]::Matches($body, '(?m)^[^#\n]*systemctl[\t ]+enable[\t ][^#\n]*--now')
            foreach ($m in $nowHits) { $bad += ($name + ': --now: ' + $m.Value.Trim()) }
            # `systemctl start <unit>` on a line that isn't part of stop/restart.
            # We allow `systemctl restart` (separately documented), `systemctl stop`,
            # and `systemctl daemon-reload`. We forbid bare `systemctl start`.
            $startHits = [regex]::Matches($body, '(?m)^[^#\n]*systemctl[\t ]+start[\t ]')
            foreach ($m in $startHits) { $bad += ($name + ': start: ' + $m.Value.Trim()) }
        }
        $bad | Should -BeNullOrEmpty -Because '`systemctl --now` and `systemctl start` hang intermittently in WSL2 — see docs/wsl2-gotchas.md#4'
    }
}

Describe 'Gotcha #19: no `New-Item -ItemType Directory` in modules or entry points' {
    It 'every directory create in production code uses [System.IO.Directory]::CreateDirectory' {
        # New-Item -Path doesn't take literal strings — wildcard glyphs ([, ], *)
        # in the path get interpreted by the provider. New-Item has no
        # -LiteralPath parameter. The .NET API is literal + idempotent.
        # Tests are excluded from the scan because they create paths under
        # TestDrive / GUID temp dirs with controlled (bracket-free) names.
        $targets = @(
            $script:modules.FullName
            (Join-Path $script:repoRoot 'claudearium.ps1')
            (Join-Path $script:repoRoot 'open-claudearium.ps1')
        )
        $bad = @()
        foreach ($path in $targets) {
            $name = [IO.Path]::GetFileName($path)
            $body = Get-Content -LiteralPath $path -Raw
            $hits = [regex]::Matches($body, '(?m)^[^#\n]*New-Item\s[^#\n]*-ItemType\s+Directory')
            foreach ($m in $hits) { $bad += ($name + ': ' + $m.Value.Trim()) }
        }
        $bad | Should -BeNullOrEmpty -Because 'use [System.IO.Directory]::CreateDirectory($dir) (literal + idempotent) — see docs/wsl2-gotchas.md#19'
    }
}

Describe 'Gotcha #2 (live): @() wrap is safe across both unwrap regimes' {
    It '@() always produces a 1-element array, regardless of pwsh version' {
        # Older pwsh (<7.6?): single-element JSON arrays come back unwrapped
        # as the lone element. Newer pwsh: they stay as 1-element arrays.
        # Either way, the @() wrap pattern used everywhere in Profile.psm1
        # produces a usable array. This test guards against a future pwsh
        # version regressing the array-shape promise.
        $json = '{ "projects": [ { "name": "only-one" } ] }'
        $hash = $json | ConvertFrom-Json -AsHashtable
        $projects = @($hash.projects)
        $projects.Count | Should -Be 1
        $projects[0].name | Should -Be 'only-one'
    }
}
