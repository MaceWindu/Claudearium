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

Describe 'Get-ProjectHalves' {
    It 'reports a distro-only project' {
        $h = Get-ProjectHalves -ProjectSpec @{ name = 'p1'; remote = 'git@host:p1.git' }
        $h.Distro | Should -BeTrue
        $h.Host   | Should -BeFalse
    }
    It 'reports a host-only project' {
        $h = Get-ProjectHalves -ProjectSpec @{ name = 'p1'; hostCheckout = 'C:\dev\p1' }
        $h.Distro | Should -BeFalse
        $h.Host   | Should -BeTrue
    }
    It 'reports a dual-capability project' {
        $h = Get-ProjectHalves -ProjectSpec @{ name = 'p1'; remote = 'git@host:p1.git'; hostCheckout = 'C:\dev\p1' }
        $h.Distro | Should -BeTrue
        $h.Host   | Should -BeTrue
    }
    It 'ignores empty-string fields and a null spec' {
        $h = Get-ProjectHalves -ProjectSpec @{ name = 'p1'; remote = ''; hostCheckout = '  ' }
        $h.Distro | Should -BeFalse
        $h.Host   | Should -BeFalse
        $hn = Get-ProjectHalves -ProjectSpec $null
        $hn.Distro | Should -BeFalse
        $hn.Host   | Should -BeFalse
    }
}

Describe 'Add-ProjectHalfInProfile' {
    It 'adds a host half to a distro-only project, keeping the distro half' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git'; tabColor = '#0078D7' })
        }
        try {
            Add-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'host' -HostCheckout 'C:\dev\p1'
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            [string]$e.remote       | Should -Be 'git@host:org/p1.git'   # distro half intact
            [string]$e.hostCheckout | Should -Be 'C:\dev\p1'
            @($e.hostShadows)       | Should -Contain 'pwsh'
            @($e.hostShadows)       | Should -Contain 'git'
            [string]$e.tabColor     | Should -Be '#0078D7'
            (Test-Profile -Spec $spec).IsValid | Should -BeTrue
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'adds a distro half to a host-only project, keeping the host half' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; hostCheckout = 'C:\dev\p1'; hostShadows = @('pwsh','git') })
        }
        try {
            Add-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'distro' -Remote 'git@host:org/p1.git'
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            [string]$e.remote       | Should -Be 'git@host:org/p1.git'
            [string]$e.hostCheckout | Should -Be 'C:\dev\p1'             # host half intact
            (Test-Profile -Spec $spec).IsValid | Should -BeTrue
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'accepts a custom -HostShadows list' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git' })
        }
        try {
            Add-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'host' -HostCheckout 'C:\dev\p1' -HostShadows @('pwsh')
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            @($e.hostShadows).Count | Should -Be 1
            @($e.hostShadows)[0]    | Should -Be 'pwsh'
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'preserves Windows Terminal appearance fields through a half mutation' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{
                name = 'p1'; remote = 'git@host:org/p1.git'
                icon = 'C:\icons\p1.ico'; backgroundImage = 'C:\bg\p1.png'; backgroundImageOpacity = 40
            })
        }
        try {
            Add-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'host' -HostCheckout 'C:\dev\p1'
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            [string]$e.icon                | Should -Be 'C:\icons\p1.ico'
            [string]$e.backgroundImage     | Should -Be 'C:\bg\p1.png'
            [int]$e.backgroundImageOpacity | Should -Be 40
            (Test-Profile -Spec $spec).IsValid | Should -BeTrue
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'drops a legacy type key on mutation' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; type = 'host'; hostCheckout = 'C:\dev\p1' })
        }
        try {
            Add-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'distro' -Remote 'git@host:org/p1.git'
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            $e.ContainsKey('type') | Should -BeFalse
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'throws when the half already exists' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git' })
        }
        try {
            { Add-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'distro' -Remote 'r' } |
                Should -Throw '*already has a distro half*'
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'throws when the project is not in the profile' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'r' })
        }
        try {
            { Add-ProjectHalfInProfile -ProfilePath $path -Name 'nope' -Half 'host' -HostCheckout 'C:\x' } |
                Should -Throw "*'nope' not found*"
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'throws when -Half host is missing -HostCheckout' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'r' })
        }
        try {
            { Add-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'host' } |
                Should -Throw '*requires -HostCheckout*'
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
}

Describe 'Remove-ProjectHalfInProfile' {
    It 'drops the host half and keeps the distro half' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git'; hostCheckout = 'C:\dev\p1'; hostShadows = @('pwsh','git'); tabColor = '#abcdef' })
        }
        try {
            Remove-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'host'
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            [string]$e.remote              | Should -Be 'git@host:org/p1.git'
            $e.ContainsKey('hostCheckout') | Should -BeFalse
            $e.ContainsKey('hostShadows')  | Should -BeFalse
            [string]$e.tabColor            | Should -Be '#abcdef'
            (Test-Profile -Spec $spec).IsValid | Should -BeTrue
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'drops the distro half and keeps the host half' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git'; hostCheckout = 'C:\dev\p1'; hostShadows = @('pwsh','git') })
        }
        try {
            Remove-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'distro'
            $spec = Read-Profile -Path $path -Raw
            $e = @($spec.projects | Where-Object { $_.name -eq 'p1' })[0]
            $e.ContainsKey('remote')       | Should -BeFalse
            [string]$e.hostCheckout        | Should -Be 'C:\dev\p1'
            (Test-Profile -Spec $spec).IsValid | Should -BeTrue
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'refuses to drop the last remaining half' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git' })
        }
        try {
            { Remove-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'distro' } |
                Should -Throw '*only a distro half*'
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }

    It 'throws when the requested half is absent' {
        $path = New-TempProfile -Spec @{
            schemaVersion = 1
            distro   = @{ name = 'x'; base = 'debian-12'; installPath = 'C:\x' }
            projects = @(@{ name = 'p1'; remote = 'git@host:org/p1.git' })
        }
        try {
            { Remove-ProjectHalfInProfile -ProfilePath $path -Name 'p1' -Half 'host' } |
                Should -Throw '*no host half*'
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
}
