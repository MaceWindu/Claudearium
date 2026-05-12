# HostTools.Tests.ps1 — pure transforms used by `host-tools add` to translate
# a Windows .exe path into a guest path and wrapper script.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\HostTools.psm1') -Force
}

Describe 'ConvertTo-GuestPath' {
    It 'converts C:\... to /mnt/c/...' {
        ConvertTo-GuestPath -Path 'C:\Tools\claudelk.exe' | Should -Be '/mnt/c/Tools/claudelk.exe'
    }

    It 'lowercases the drive letter only' {
        ConvertTo-GuestPath -Path 'D:\Foo\Bar.exe' | Should -Be '/mnt/d/Foo/Bar.exe'
    }

    It 'passes /-prefixed paths through unchanged' {
        ConvertTo-GuestPath -Path '/mnt/c/already-guest' | Should -Be '/mnt/c/already-guest'
    }
}

Describe 'Resolve-DefaultGuestCommand' {
    It "prefixes the stripped basename with 'sb-'" {
        Resolve-DefaultGuestCommand -WindowsExe 'C:\Tools\Claudelk\claudelk.exe' | Should -Be 'sb-claudelk'
    }

    It 'lowercases and strips non-alphanumerics from the basename' {
        Resolve-DefaultGuestCommand -WindowsExe 'C:\Foo\My_Tool-V2.exe' | Should -Be 'sb-mytool-v2'
    }
}

Describe 'ConvertTo-WrapperContent' {
    It 'includes the managed-by marker and exec line with the guest path' {
        $body = ConvertTo-WrapperContent -ToolSpec @{
            name       = 'claudelk'
            windowsExe = 'C:\Tools\Claudelk\claudelk.exe'
        }
        $body | Should -Match '#!/usr/bin/env bash'
        $body | Should -Match 'claudearium-hosttool: claudelk'
        $body.Contains('# windowsExe: C:\Tools\Claudelk\claudelk.exe') | Should -BeTrue
        # Single-quoted to avoid pwsh variable interpolation on `$@`.
        $body.Contains('exec ''/mnt/c/Tools/Claudelk/claudelk.exe'' "$@"') | Should -BeTrue
    }
}
