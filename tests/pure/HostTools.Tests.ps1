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

Describe 'Add-CatalogToolAsHostAttach' {
    BeforeEach {
        $script:tmpProfile = Join-Path ([IO.Path]::GetTempPath()) ("claudearium-test-prof-{0}.json" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        @{
            schemaVersion = 1
            distro        = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:tmpProfile -Encoding UTF8
    }
    AfterEach {
        if (Test-Path $script:tmpProfile) { Remove-Item -LiteralPath $script:tmpProfile -Force }
    }

    It 'writes a hostTools entry with the bare tool name as guestCommand (drop-in, not sb-prefixed)' {
        Add-CatalogToolAsHostAttach -ProfilePath $script:tmpProfile -ToolName 'gh' -WindowsExe 'C:\Program Files\GitHub CLI\gh.exe'
        $spec = Read-Profile -Path $script:tmpProfile -Raw
        $spec.hostTools.Count | Should -Be 1
        $spec.hostTools[0].name         | Should -Be 'gh'
        $spec.hostTools[0].guestCommand | Should -Be 'gh'
        $spec.hostTools[0].windowsExe   | Should -Be 'C:\Program Files\GitHub CLI\gh.exe'
    }

    It 'replaces an existing hostTools entry with the same guestCommand' {
        Add-CatalogToolAsHostAttach -ProfilePath $script:tmpProfile -ToolName 'gh' -WindowsExe 'C:\old\gh.exe'
        Add-CatalogToolAsHostAttach -ProfilePath $script:tmpProfile -ToolName 'gh' -WindowsExe 'C:\new\gh.exe'
        $spec = Read-Profile -Path $script:tmpProfile -Raw
        $spec.hostTools.Count | Should -Be 1
        $spec.hostTools[0].windowsExe | Should -Be 'C:\new\gh.exe'
    }
}
