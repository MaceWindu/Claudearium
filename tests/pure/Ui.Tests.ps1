# Ui.Tests.ps1 — pure tests exercising the -NonInteractive paths of
# modules/UI.psm1. Interactive paths can't be unit-tested without stdin
# injection; they're indirectly covered by the manual tests.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\UI.psm1') -Force
}

Describe 'Read-YesNo (NonInteractive)' {
    It 'returns the Default value without prompting' {
        Read-YesNo -Prompt 'X?' -Default $true  -NonInteractive | Should -BeTrue
        Read-YesNo -Prompt 'X?' -Default $false -NonInteractive | Should -BeFalse
    }
}

Describe 'Read-Choice (NonInteractive)' {
    It 'returns Options[DefaultIndex]' {
        Read-Choice -Prompt 'pick' -Options @('a','b','c') -DefaultIndex 1 -NonInteractive | Should -Be 'b'
    }

    It 'throws when DefaultIndex is out of range' {
        { Read-Choice -Prompt 'pick' -Options @('a','b') -DefaultIndex 5 -NonInteractive } | Should -Throw
    }
}

Describe 'Read-Multi (NonInteractive)' {
    It 'returns the Selected=$true entries' {
        $picked = Read-Multi -Prompt 'pick' -Options @(
            @{ Name = 'a'; Selected = $true  }
            @{ Name = 'b'; Selected = $false }
            @{ Name = 'c'; Selected = $true  }
        ) -NonInteractive
        $picked | Should -Be @('a','c')
    }
}

Describe 'Read-TabColor (NonInteractive)' {
    It 'returns the Default value as-is' {
        Read-TabColor -Prompt 'color' -Default '#E81123' -NonInteractive | Should -Be '#E81123'
    }

    It 'handles the empty default (= no color)' {
        Read-TabColor -Prompt 'color' -Default '' -NonInteractive | Should -Be ''
    }

    It 'preserves the special inherit token when -AllowInherit is set' {
        # NB: this string is intentionally bracket-wrapped (the convention for
        # the "fall back to parent" color sentinel); avoid putting it in the
        # test name because Pester treats `<word>` in It descriptions as a
        # TestCases data placeholder.
        Read-TabColor -Prompt 'color' -Default '<inherit>' -AllowInherit -NonInteractive | Should -Be '<inherit>'
    }
}
