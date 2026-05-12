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

Describe 'Gotcha #13: no awk -v in InDistro commands' {
    It 'no .ps1/.psm1 in modules/ uses `awk -v` inside Invoke-InDistro* calls' {
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
    It 'no exported function name starts with Ensure-' {
        $bad = @()
        foreach ($f in $script:modules) {
            $body = Get-Content -LiteralPath $f.FullName -Raw
            $matches = [regex]::Matches($body, '(?m)^function\s+Ensure-[\w-]+')
            foreach ($m in $matches) { $bad += ($f.Name + ': ' + $m.Value) }
        }
        $bad | Should -BeNullOrEmpty -Because 'Ensure- is not on the approved verb list; use Initialize-/Set-/Install-/New-/Update- (see docs/wsl2-gotchas.md#15)'
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
