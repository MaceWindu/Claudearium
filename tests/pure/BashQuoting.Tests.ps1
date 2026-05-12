# BashQuoting.Tests.ps1 — modules/Wsl.psm1::ConvertTo-BashQuoted is the splice
# primitive used everywhere a host string ends up inside a bash command line.
# Anywhere it gets it wrong, every distro-touching verb breaks subtly.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
}

Describe 'ConvertTo-BashQuoted' {
    It 'wraps an ordinary string in single quotes' {
        ConvertTo-BashQuoted -Value 'hello' | Should -Be "'hello'"
    }

    It 'preserves spaces and other shell metachars verbatim inside the quotes' {
        ConvertTo-BashQuoted -Value 'a b $c | d' | Should -Be "'a b `$c | d'"
    }

    It "escapes embedded single quotes with the standard '\\'' form" {
        ConvertTo-BashQuoted -Value "it's" | Should -Be "'it'\''s'"
    }

    It 'returns just an empty quoted string for empty input' {
        ConvertTo-BashQuoted -Value '' | Should -Be "''"
    }
}
