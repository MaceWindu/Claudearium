# WinTerminal.Tests.ps1 — pure tests for modules/WinTerminal.psm1: the WT
# fragment builder, opacity resolution, profile-name derivation, and the
# write/delete lifecycle of Update-WtFragment (against a temp path, no real WT).

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\WinTerminal.psm1') -Force

    function New-TempFragmentPath {
        return (Join-Path ([System.IO.Path]::GetTempPath()) ("claudearium-wt-" + [Guid]::NewGuid().ToString('N') + '.json'))
    }
}

Describe 'Get-ProjectWtProfileName' {
    It 'derives a deterministic Claudearium-prefixed profile name' {
        Get-ProjectWtProfileName -Name 'acme' | Should -Be 'Claudearium - acme'
    }
}

Describe 'Test-ProjectHasWtAppearance' {
    It 'is true when icon is set' {
        Test-ProjectHasWtAppearance -ProjectSpec @{ name = 'p'; icon = '🚀' } | Should -BeTrue
    }
    It 'is true when backgroundImage is set' {
        Test-ProjectHasWtAppearance -ProjectSpec @{ name = 'p'; backgroundImage = 'C:\x.png' } | Should -BeTrue
    }
    It 'is false for a bare project, empty strings, or null' {
        Test-ProjectHasWtAppearance -ProjectSpec @{ name = 'p' }                       | Should -BeFalse
        Test-ProjectHasWtAppearance -ProjectSpec @{ name = 'p'; icon = '  '; backgroundImage = '' } | Should -BeFalse
        Test-ProjectHasWtAppearance -ProjectSpec $null                                 | Should -BeFalse
    }
}

Describe 'Resolve-EffectiveBackgroundOpacity' {
    It 'prefers the per-project value' {
        Resolve-EffectiveBackgroundOpacity -ProjectSpec @{ backgroundImageOpacity = 40 } -ProfileDefaults @{ backgroundImageOpacity = 80 } | Should -Be 40
    }
    It 'falls back to projectDefaults when the project has none' {
        Resolve-EffectiveBackgroundOpacity -ProjectSpec @{ name = 'p' } -ProfileDefaults @{ backgroundImageOpacity = 80 } | Should -Be 80
    }
    It 'falls back to 100 when neither is set' {
        Resolve-EffectiveBackgroundOpacity -ProjectSpec @{ name = 'p' } -ProfileDefaults $null | Should -Be 100
    }
    It 'treats an explicit 0 as a real value (not "unset")' {
        Resolve-EffectiveBackgroundOpacity -ProjectSpec @{ backgroundImageOpacity = 0 } -ProfileDefaults @{ backgroundImageOpacity = 80 } | Should -Be 0
    }
}

Describe 'Build-WtFragment' {
    It 'emits a profile only for projects with an icon or background image' {
        $spec = @{
            projects = @(
                @{ name = 'plain';  remote = 'r' }
                @{ name = 'iconed'; remote = 'r'; icon = '🚀' }
                @{ name = 'bg';     remote = 'r'; backgroundImage = 'C:\x.png' }
            )
        }
        $frag = Build-WtFragment -Spec $spec
        $names = @($frag.profiles | ForEach-Object { $_.name })
        $names.Count | Should -Be 2
        $names | Should -Contain 'Claudearium - iconed'
        $names | Should -Contain 'Claudearium - bg'
        $names | Should -Not -Contain 'Claudearium - plain'
    }

    It 'converts opacity percent to a 0.0-1.0 float and forces useAcrylic off for images' {
        $spec = @{
            projectDefaults = @{ backgroundImageOpacity = 80 }
            projects = @(
                @{ name = 'a'; backgroundImage = 'C:\a.png'; backgroundImageOpacity = 40 }
                @{ name = 'b'; backgroundImage = 'C:\b.png' }  # inherits default 80
            )
        }
        $frag = Build-WtFragment -Spec $spec
        $a = $frag.profiles | Where-Object { $_.name -eq 'Claudearium - a' }
        $b = $frag.profiles | Where-Object { $_.name -eq 'Claudearium - b' }
        [double]$a.backgroundImageOpacity | Should -Be 0.4
        [double]$b.backgroundImageOpacity | Should -Be 0.8
        $a.useAcrylic | Should -BeFalse
        $a.hidden     | Should -BeTrue
    }

    It 'omits backgroundImageOpacity / useAcrylic for an icon-only project' {
        $frag = Build-WtFragment -Spec @{ projects = @(@{ name = 'i'; icon = 'C:\i.ico' }) }
        $p = $frag.profiles | Where-Object { $_.name -eq 'Claudearium - i' }
        $names = @($p.PSObject.Properties.Name)
        $names | Should -Contain 'icon'
        $names | Should -Not -Contain 'backgroundImage'
        $names | Should -Not -Contain 'backgroundImageOpacity'
        $names | Should -Not -Contain 'useAcrylic'
    }

    It 'returns an empty profiles list when no project has appearance' {
        $frag = Build-WtFragment -Spec @{ projects = @(@{ name = 'p'; remote = 'r' }) }
        @($frag.profiles).Count | Should -Be 0
    }
}

Describe 'Update-WtFragment' {
    It 'writes the fragment, is idempotent, and reports change state' {
        $path = New-TempFragmentPath
        try {
            $spec = @{ projects = @(@{ name = 'a'; icon = '🚀' }) }
            $r1 = Update-WtFragment -Spec $spec -Path $path
            $r1.Changed      | Should -BeTrue
            $r1.ProfileCount | Should -Be 1
            Test-Path -LiteralPath $path | Should -BeTrue

            $r2 = Update-WtFragment -Spec $spec -Path $path
            $r2.Changed | Should -BeFalse   # same content -> no rewrite
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'deletes the fragment when no project has appearance' {
        $path = New-TempFragmentPath
        try {
            Update-WtFragment -Spec @{ projects = @(@{ name = 'a'; icon = '🚀' }) } -Path $path | Out-Null
            Test-Path -LiteralPath $path | Should -BeTrue

            $r = Update-WtFragment -Spec @{ projects = @(@{ name = 'a'; remote = 'r' }) } -Path $path
            $r.Changed | Should -BeTrue
            $r.Removed | Should -BeTrue
            Test-Path -LiteralPath $path | Should -BeFalse
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'produces JSON that round-trips back to the same profile names' {
        $path = New-TempFragmentPath
        try {
            Update-WtFragment -Spec @{ projects = @(@{ name = 'a'; backgroundImage = 'C:\a.png'; backgroundImageOpacity = 50 }) } -Path $path | Out-Null
            $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            @($parsed.profiles).Count | Should -Be 1
            $parsed.profiles[0].name  | Should -Be 'Claudearium - a'
            [double]$parsed.profiles[0].backgroundImageOpacity | Should -Be 0.5
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
}
