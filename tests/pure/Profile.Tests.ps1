# Profile.Tests.ps1 — pure tests for modules/Profile.psm1. No WSL2 needed.
# Step 1 ships a smoke set; Step 2 will expand into env-token expansion,
# round-tripping, per-block diff shape, and warning emission.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        # Fallback when Pester is invoked directly (not via test-claudearium.ps1):
        # tests/pure/Profile.Tests.ps1 -> repoRoot
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Profile.psm1') -Force
    $script:examplePath = Join-Path $repoRoot 'templates\claudearium.profile.example.json'
}

Describe 'Test-Profile' {
    It 'reports IsValid on the bundled example profile' {
        $spec = Read-Profile -Path $script:examplePath
        $r = Test-Profile -Spec $spec
        $r.IsValid | Should -BeTrue
        $r.Errors.Count | Should -Be 0
    }

    It 'rejects a profile with no schemaVersion' {
        $r = Test-Profile -Spec @{
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'schemaVersion is required'
    }

    It 'rejects a profile with an unsupported schemaVersion' {
        $r = Test-Profile -Spec @{
            schemaVersion = 999
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'is not supported'
    }

    It 'rejects a profile that omits the distro block entirely' {
        $r = Test-Profile -Spec @{ schemaVersion = 1 }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'distro block is required'
    }

    It 'flags duplicate project names as an error' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(
                @{ name = 'dup'; remote = 'git@host:a.git' }
                @{ name = 'dup'; remote = 'git@host:b.git' }
            )
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'duplicated'
    }

    It 'warns (does not error) on an unknown distro.base' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'ubuntu-22'; installPath = 'C:\x' }
        }
        $r.IsValid          | Should -BeTrue
        $r.Warnings.Count   | Should -BeGreaterThan 0
        ($r.Warnings -join "`n") | Should -Match 'ubuntu-22'
    }

    It 'rejects a profile that enables a tool in tools[] and host-attaches it under the same name' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            tools  = @{ gh = @{ enabled = $true; version = 'latest' } }
            hostTools = @(
                @{ name = 'gh'; windowsExe = 'C:\Program Files\GitHub CLI\gh.exe'; guestCommand = 'gh' }
            )
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match ([regex]::Escape("tools.gh is enabled AND hostTools[] guestCommand='gh'"))
    }

    It 'rejects the conflict even when the tools entry omits the enabled field (defaults to enabled)' {
        # Missing enabled = enabled by convention (Get-ToolRows / Get-ToolsDiff agree).
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            tools  = @{ gh = @{ version = 'latest' } }   # no 'enabled' key
            hostTools = @(
                @{ name = 'gh'; windowsExe = 'C:\Program Files\GitHub CLI\gh.exe'; guestCommand = 'gh' }
            )
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'gh is enabled'
    }

    It 'allows a hostTools entry alongside tools entry with enabled=false' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            tools  = @{ gh = @{ enabled = $false; version = 'latest' } }
            hostTools = @(
                @{ name = 'gh'; windowsExe = 'C:\Program Files\GitHub CLI\gh.exe'; guestCommand = 'gh' }
            )
        }
        $r.IsValid | Should -BeTrue
    }

    It 'allows a hostTools entry under a non-conflicting sb-prefixed name' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            tools  = @{ gh = @{ enabled = $true; version = 'latest' } }
            hostTools = @(
                @{ name = 'gh-host'; windowsExe = 'C:\Program Files\GitHub CLI\gh.exe'; guestCommand = 'sb-gh' }
            )
        }
        $r.IsValid | Should -BeTrue
    }

    It 'accepts a well-formed vpn block with routingMode and lanCidr' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            vpn    = @{ wgConfigPath = 'C:\wg0.conf'; routingMode = 'all-except-lan'; lanCidr = '192.168.1.0/24' }
        }
        $r.IsValid | Should -BeTrue
    }

    It 'rejects an unknown vpn.routingMode' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            vpn    = @{ routingMode = 'route-everything' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'routingMode'
    }

    It 'rejects vpn.lanCidr with out-of-range octets or prefix' {
        foreach ($bad in @('999.0.0.0/8', '192.168.1.0/33', '256.0.0.0/24', '10.0.0.0/40')) {
            $r = Test-Profile -Spec @{
                schemaVersion = 1
                distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
                vpn    = @{ lanCidr = $bad }
            }
            $r.IsValid | Should -BeFalse
            ($r.Errors -join "`n") | Should -Match 'lanCidr'
        }
    }

    It 'rejects non-string vpn.routingMode / vpn.lanCidr (falsy values bypass truthy-only checks)' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            vpn    = @{ routingMode = $false; lanCidr = 0 }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'routingMode must be a string'
        ($r.Errors -join "`n") | Should -Match 'lanCidr must be a string'
    }

    It 'accepts vpn.lanCidr at the boundaries (octet 0, 255; prefix 0, 32)' {
        foreach ($ok in @('0.0.0.0/0', '255.255.255.255/32', '192.168.1.0/24', '10.0.0.0/8')) {
            $r = Test-Profile -Spec @{
                schemaVersion = 1
                distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
                vpn    = @{ lanCidr = $ok }
            }
            $r.IsValid | Should -BeTrue
        }
    }

    It 'rejects routingMode=all-except-lan combined with lanCidr=0.0.0.0/0 (would route nothing at runtime)' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            vpn    = @{ routingMode = 'all-except-lan'; lanCidr = '0.0.0.0/0' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match "lanCidr '0\.0\.0\.0/0' is invalid when vpn\.routingMode = 'all-except-lan'"
    }

    It 'rejects bad enum values for the expanded claudeSettings surface' {
        $cases = @(
            @{ key = 'autoUpdatesChannel';            val = 'beta'      ; pat = 'autoUpdatesChannel' }
            @{ key = 'tui';                           val = 'split'     ; pat = 'tui' }
            @{ key = 'defaultShell';                  val = 'zsh'       ; pat = 'defaultShell' }
        )
        foreach ($c in $cases) {
            $r = Test-Profile -Spec @{
                schemaVersion = 1
                distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
                claudeSettings = @{ $c.key = $c.val }
            }
            $r.IsValid | Should -BeFalse
            ($r.Errors -join "`n") | Should -Match $c.pat
        }
    }

    It 'rejects a non-boolean alwaysThinkingEnabled / disableBypassPermissionsMode' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeSettings = @{ alwaysThinkingEnabled = 'yes' }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'alwaysThinkingEnabled must be a boolean'

        $r2 = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeSettings = @{ disableBypassPermissionsMode = 'on' }
        }
        $r2.IsValid | Should -BeFalse
        ($r2.Errors -join "`n") | Should -Match 'disableBypassPermissionsMode must be a boolean'
    }

    It 'rejects negative cleanupPeriodDays and non-numeric values' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeSettings = @{ cleanupPeriodDays = -3 }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match 'cleanupPeriodDays must be >= 0'

        $r2 = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeSettings = @{ cleanupPeriodDays = 'forever' }
        }
        $r2.IsValid | Should -BeFalse
        ($r2.Errors -join "`n") | Should -Match 'cleanupPeriodDays must be a non-negative integer'
    }

    It 'rejects an unknown permissions.defaultMode and non-string permission lists' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeSettings = @{ permissions = @{ defaultMode = 'wide-open' } }
        }
        $r.IsValid | Should -BeFalse
        ($r.Errors -join "`n") | Should -Match "permissions.defaultMode 'wide-open' must be one of"

        $r2 = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeSettings = @{ permissions = @{ additionalAllow = @('Bash(ok *)', 42) } }
        }
        $r2.IsValid | Should -BeFalse
        ($r2.Errors -join "`n") | Should -Match 'permissions.additionalAllow entries must be strings'
    }

    It 'accepts a fully-populated claudeSettings block from the expanded surface' {
        $r = Test-Profile -Spec @{
            schemaVersion = 1
            distro = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            claudeSettings = @{
                alwaysThinkingEnabled        = $true
                autoUpdatesChannel           = 'stable'
                disableBypassPermissionsMode = $true
                cleanupPeriodDays            = 14
                tui                          = 'fullscreen'
                defaultShell                 = 'bash'
                permissions = @{
                    additionalAllow       = @('Bash(rg *)')
                    additionalDeny        = @('Bash(rm /important/*)')
                    additionalDirectories = @('/home/claude/scratch')
                    defaultMode           = 'plan'
                }
            }
        }
        $r.IsValid | Should -BeTrue
        $r.Errors.Count | Should -Be 0
    }
}

Describe 'Test-ToolEntryEnabled' {
    It 'returns $true for a hashtable with enabled=$true' {
        Test-ToolEntryEnabled -Entry @{ enabled = $true; version = '1.0' } | Should -BeTrue
    }
    It 'returns $true for a hashtable without an enabled field (default-enabled convention)' {
        Test-ToolEntryEnabled -Entry @{ version = '1.0' } | Should -BeTrue
    }
    It 'returns $false for a hashtable with enabled=$false' {
        Test-ToolEntryEnabled -Entry @{ enabled = $false } | Should -BeFalse
    }
    It 'returns $false for $null or non-hashtable input' {
        Test-ToolEntryEnabled -Entry $null    | Should -BeFalse
        Test-ToolEntryEnabled -Entry 'string' | Should -BeFalse
    }
}

Describe 'Read-Profile / Write-Profile bracket-path safety' {
    # Regression guard: Test-Path inside Read-Profile / Write-Profile and the
    # New-Item directory creation must use -LiteralPath so a profile path
    # containing wildcard glyphs ([, ], *) is handled correctly. Bracket-named
    # profile paths are rare but possible via custom -ProfilePath / a user
    # folder with brackets in the name.
    It 'reads and round-trips a profile saved at a path containing wildcard glyphs' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cla [bracket] " + [Guid]::NewGuid().ToString('N') + ".json")
        try {
            $spec = @{
                schemaVersion = 1
                distro        = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            }
            Write-Profile -Path $tmp -Spec $spec
            $back = Read-Profile -Path $tmp -Raw
            $back.distro.name | Should -Be 'x'
        }
        finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        }
    }

    It 'creates a missing parent directory whose name contains wildcard glyphs' {
        # Exercises Write-Profile's New-Item branch with a bracket-named
        # parent directory that doesn't exist yet — without -LiteralPath the
        # provider would glob-expand and either no-op or create the wrong dir.
        $parent = Join-Path ([System.IO.Path]::GetTempPath()) ("cla [parent] " + [Guid]::NewGuid().ToString('N'))
        $tmp    = Join-Path $parent 'profile.json'
        try {
            $spec = @{
                schemaVersion = 1
                distro        = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            }
            Write-Profile -Path $tmp -Spec $spec
            Test-Path -LiteralPath $parent -PathType Container | Should -BeTrue
            Test-Path -LiteralPath $tmp    -PathType Leaf      | Should -BeTrue
            (Read-Profile -Path $tmp -Raw).distro.name | Should -Be 'x'
        }
        finally {
            if (Test-Path -LiteralPath $parent) { Remove-Item -LiteralPath $parent -Recurse -Force }
        }
    }
}

Describe 'Profile env-token expansion' {
    It 'expands %LOCALAPPDATA% in string leaves' {
        $expanded = ConvertFrom-ProfileRaw @{
            distro = @{ installPath = '%LOCALAPPDATA%\WSL\cla' }
        }
        $expanded.distro.installPath | Should -Be (Join-Path $env:LOCALAPPDATA 'WSL\cla')
    }

    It 'recurses into nested arrays and hashtables' {
        $expanded = ConvertFrom-ProfileRaw @{
            list = @(
                @{ path = '%LOCALAPPDATA%\a' }
                @{ path = '%LOCALAPPDATA%\b' }
            )
        }
        $expanded.list[0].path | Should -Be (Join-Path $env:LOCALAPPDATA 'a')
        $expanded.list[1].path | Should -Be (Join-Path $env:LOCALAPPDATA 'b')
    }

    It 'leaves unknown tokens untouched (Windows ExpandEnvironmentVariables semantics)' {
        Resolve-EnvTokens -Value '%THIS_DOES_NOT_EXIST_LIKELY%' | Should -Be '%THIS_DOES_NOT_EXIST_LIKELY%'
    }
}
