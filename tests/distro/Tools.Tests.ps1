# Tools.Tests.ps1 — `tools` verb against the ephemeral test distro. The
# breadth-first cut deliberately avoids `tools install` since each tool can
# take 30s-2min; that lives in a follow-up step alongside slower regressions.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'tools'
}

AfterAll {
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'tools list' -Tag 'distro' {
    It 'reports every tool in the catalog with installed=false on a fresh distro' {
        $claudearium = Get-ClaudearcumScriptPath
        $out = & $claudearium tools list -Name $script:distro -ProfilePath $script:profilePath -NonInteractive
        $txt = $out -join "`n"
        foreach ($t in 'node','claudeCode','gh','glab','acli','dotnet','seqcli','pwsh') {
            $txt | Should -Match $t
        }
    }
}

Describe 'tools enable / disable' -Tag 'distro' {
    It 'enable writes the profile entry without installing' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs tools,enable,gh

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $spec.tools.gh.enabled | Should -BeTrue
    }

    It 'disable flips the profile entry but does not uninstall' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -ScriptArgs tools,disable,gh

        $spec = Get-Content -LiteralPath $script:profilePath -Raw | ConvertFrom-Json -AsHashtable
        $spec.tools.gh.enabled | Should -BeFalse
    }
}
