# Projects.Tests.ps1 — pure tests for the profile-mutation helpers in
# modules/Projects.psm1. Worktree / mirror lifecycle that touches a real
# distro lives under tests/distro/.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')  -Force
    Import-Module (Join-Path $repoRoot 'modules\Projects.psm1') -Force

    # Pester 5 runs each `It` in its own scope; helpers must be defined inside
    # `BeforeAll` to be visible. A free-standing function at file scope is
    # discovered but unreachable from the It blocks.
    function New-TempProfile {
        param([Parameter(Mandatory)][hashtable]$Spec)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ("claudearium-move-test-" + [Guid]::NewGuid().ToString('N') + '.json')
        Write-Profile -Path $p -Spec $Spec
        return $p
    }
}

Describe 'Move-ProjectInProfile' {
    It 'rewrites a distroProject as a hostProject and preserves unrelated fields' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{
                name          = 'p1'
                remote        = 'git@host:org/p1.git'
                defaultBranch = 'master'
                tabColor      = '#0078D7'
                enabled       = $true
            })
        }
        try {
            Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'host' `
                -HostCheckout 'C:\dev\p1'

            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            [string]$e.type           | Should -Be 'host'
            [string]$e.hostCheckout   | Should -Be 'C:\dev\p1'
            @($e.hostShadows)         | Should -Contain 'pwsh'
            @($e.hostShadows)         | Should -Contain 'git'
            # remote stripped — must not survive on a hostProject.
            $e.ContainsKey('remote')  | Should -BeFalse
            # preserved fields:
            [string]$e.defaultBranch  | Should -Be 'master'
            [string]$e.tabColor       | Should -Be '#0078D7'
            [bool]$e.enabled          | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'rewrites a hostProject as a distroProject and preserves unrelated fields' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{
                name          = 'p1'
                type          = 'host'
                hostCheckout  = 'C:\dev\p1'
                hostShadows   = @('pwsh', 'git')
                defaultBranch = 'main'
                tabColor      = '#FFAA00'
            })
        }
        try {
            Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'distro' `
                -Remote 'git@host:org/p1.git'

            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            [string]$e.remote               | Should -Be 'git@host:org/p1.git'
            $e.ContainsKey('type')          | Should -BeFalse   # distro = default, omit
            $e.ContainsKey('hostCheckout')  | Should -BeFalse
            $e.ContainsKey('hostShadows')   | Should -BeFalse
            # preserved:
            [string]$e.defaultBranch        | Should -Be 'main'
            [string]$e.tabColor             | Should -Be '#FFAA00'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'drops hostTools when moving distro -> host (forbidden for hostProjects)' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{
                name      = 'p1'
                remote    = 'git@host:org/p1.git'
                hostTools = @(@{ name = 'foo'; windowsExe = 'C:\foo.exe'; guestCommand = 'foo' })
            })
        }
        try {
            Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'host' -HostCheckout 'C:\dev\p1'
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            $e.ContainsKey('hostTools') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'accepts a custom -HostShadows list (overrides the default pwsh/git pair)' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git' })
        }
        try {
            Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'host' `
                -HostCheckout 'C:\dev\p1' -HostShadows @('pwsh')
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            @($e.hostShadows).Count | Should -Be 1
            @($e.hostShadows)[0]    | Should -Be 'pwsh'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'throws when the project is not in the profile' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'r' })
        }
        try {
            { Move-ProjectInProfile -ProfilePath $path -Name 'nope' -ToType 'host' -HostCheckout 'C:\x' } |
                Should -Throw "*'nope' not found*"
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'throws when ToType=host without -HostCheckout' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'r' })
        }
        try {
            { Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'host' } |
                Should -Throw '*requires -HostCheckout*'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'throws when ToType=distro without -Remote' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; type = 'host'; hostCheckout = 'C:\x' })
        }
        try {
            { Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'distro' } |
                Should -Throw '*requires -Remote*'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'produces an entry that passes Test-Profile after a distro -> host round-trip' {
        # Regression: the mutation must keep the result schema-valid, otherwise
        # the next reconcile would refuse to read the profile.
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git'; tabColor = '#112233' })
        }
        try {
            Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'host' -HostCheckout 'C:\dev\p1'
            $spec1 = Read-Profile -Path $path -Raw
            (Test-Profile -Spec $spec1).IsValid | Should -BeTrue

            Move-ProjectInProfile -ProfilePath $path -Name 'p1' -ToType 'distro' -Remote 'git@host:org/p1.git'
            $spec2 = Read-Profile -Path $path -Raw
            (Test-Profile -Spec $spec2).IsValid | Should -BeTrue
            # tabColor must survive the round trip.
            $e = @($spec2.projects | Where-Object { $_.name -eq 'p1' })[0]
            [string]$e.tabColor | Should -Be '#112233'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }
}
