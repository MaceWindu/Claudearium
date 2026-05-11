# Projects.psm1
# Project lifecycle: bare-mirror clones, profile mutation, smart-default
# remote/branch detection from a host git checkout.
#
# Each project owns a bare mirror at /home/claude/mirrors/<name>.git inside
# the distro. Sessions are worktrees off this mirror (see Sessions).
# See docs/design-decisions.md#5 for the bare-mirror-vs-full-clone rationale.
#
# Public surface:
#   Smart defaults (read from a host-side checkout)
#     Resolve-SmartRemote        -HostCheckout      — `git remote get-url origin`
#     Resolve-SmartDefaultBranch -HostCheckout      — `git symbolic-ref refs/remotes/origin/HEAD`
#     Resolve-SmartProjectName   -Remote            — last path segment of remote URL
#   Mirror lifecycle (in-distro git ops)
#     Test-ProjectMirrorExists  -DistroName -ProjectName
#     New-ProjectMirror         -DistroName -ProjectName -Remote     — git clone --mirror
#     Remove-ProjectMirror      -DistroName -ProjectName              — rm -rf mirror + sessions dir
#     Get-ProjectMirrorRemote   -DistroName -ProjectName              — read 'remote get-url origin'
#     Get-ProjectsActualFromDistro -DistroName                        — enumerate mirrors with strict .git$ filter
#   Profile mutation
#     Add-ProjectToProfile      -ProfilePath -ProjectSpec
#     Remove-ProjectFromProfile -ProfilePath -Name
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')

function Resolve-SmartRemote {
    # Auto-detect the 'origin' URL of a host-side git checkout. Used to suggest
    # a default when 'project add' runs without -Remote.
    [CmdletBinding()]
    param([string]$HostCheckout)
    $cwd = if ($HostCheckout) { $HostCheckout } else { (Get-Location).Path }
    if (-not (Test-Path $cwd)) { return $null }
    try {
        $out = & git -C $cwd remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ([string]$out).Trim() }
    } catch { }
    return $null
}

function Resolve-SmartDefaultBranch {
    # Returns the host checkout's tracked default branch, falling back to 'master'
    # (user preference) rather than 'main'.
    [CmdletBinding()]
    param([string]$HostCheckout)
    $cwd = if ($HostCheckout) { $HostCheckout } else { (Get-Location).Path }
    if (-not (Test-Path $cwd)) { return 'master' }
    try {
        $r = & git -C $cwd symbolic-ref refs/remotes/origin/HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $r) {
            return (([string]$r).Trim() -replace '^refs/remotes/origin/', '')
        }
    } catch { }
    return 'master'
}

function Resolve-SmartProjectName {
    # Pull a sane project name out of a remote URL.
    # Handles git@host:org/repo.git, https://host/org/repo.git, file paths.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Remote)
    $clean = $Remote -replace '\.git$', ''
    $normalised = $clean -replace ':', '/'
    $last = ($normalised -split '/' | Where-Object { $_ } | Select-Object -Last 1)
    return $last
}

function Test-ProjectMirrorExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName
    )
    $q = ConvertTo-BashQuoted "/home/claude/mirrors/$ProjectName.git"
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command "test -d $q" -AllowFail -CaptureOutput
    return ($r.ExitCode -eq 0)
}

function New-ProjectMirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$Remote
    )
    $qRemote = ConvertTo-BashQuoted $Remote
    $qName   = ConvertTo-BashQuoted "$ProjectName.git"
    $cmd = "mkdir -p /home/claude/mirrors && cd /home/claude/mirrors && git clone --mirror $qRemote $qName"
    Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd
}

function Remove-ProjectMirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName
    )
    $qMirror = ConvertTo-BashQuoted "/home/claude/mirrors/$ProjectName.git"
    $qProj   = ConvertTo-BashQuoted "/home/claude/projects/$ProjectName"
    Invoke-InDistro -Name $DistroName -User 'claude' -Command "rm -rf $qMirror $qProj"
}

function Get-ProjectMirrorRemote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName
    )
    $qPath = ConvertTo-BashQuoted "/home/claude/mirrors/$ProjectName.git"
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command "git -C $qPath remote get-url origin 2>/dev/null" -AllowFail -CaptureOutput
    if ($r.ExitCode -eq 0) { return (($r.Output -join "`n").Trim()) }
    return $null
}

function Get-ProjectsActualFromDistro {
    # Enumerate bare mirrors actually present in the distro and read their remotes.
    # Returns @( @{ name; remote } ) — the canonical 'actual' for the projects diff.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $cmd = '[ -d /home/claude/mirrors ] && find /home/claude/mirrors -maxdepth 1 -name "*.git" -type d -printf "%f\n" || true'
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return @() }
    # Strict: only lines that look like '<name>.git' are project names. This filters out
    # any wsl-stderr noise (e.g. systemd user-session warnings) captured by 2>&1.
    $names = @($r.Output |
        Where-Object { $_ -is [string] -and ($_.Trim() -match '^[^\\/\s]+\.git$') } |
        ForEach-Object { $_.Trim() -replace '\.git$', '' })
    $result = @()
    foreach ($n in $names) {
        $result += @{
            name   = $n
            remote = (Get-ProjectMirrorRemote -DistroName $DistroName -ProjectName $n)
        }
    }
    return ,$result
}

function Add-ProjectToProfile {
    # Insert/replace a project entry in the on-disk profile (raw, env-token preserving).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][hashtable]$ProjectSpec
    )
    $spec = if (Test-Path $ProfilePath) { Read-Profile -Path $ProfilePath -Raw } else {
        @{
            schemaVersion = 1
            distro        = @{ name = 'claudearium'; base = 'debian-12'; installPath = '%LOCALAPPDATA%\WSL\claudearium' }
        }
    }
    if (-not $spec.ContainsKey('projects') -or -not $spec.projects) { $spec['projects'] = @() }
    $name = [string]$ProjectSpec.name
    # @() forces array context — pwsh unwraps single-element JSON arrays on read.
    $existing = @($spec.projects)
    $kept = @($existing | Where-Object { [string]$_.name -ne $name })
    $spec.projects = @($kept) + @($ProjectSpec)
    Write-Profile -Path $ProfilePath -Spec $spec
}

function Remove-ProjectFromProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path $ProfilePath)) { return $false }
    $spec = Read-Profile -Path $ProfilePath -Raw
    if (-not $spec.ContainsKey('projects') -or -not $spec.projects) { return $false }
    $existing = @($spec.projects)
    $before = $existing.Count
    $spec.projects = @($existing | Where-Object { [string]$_.name -ne $Name })
    if (@($spec.projects).Count -eq $before) { return $false }
    Write-Profile -Path $ProfilePath -Spec $spec
    return $true
}

Export-ModuleMember -Function `
    Resolve-SmartRemote, `
    Resolve-SmartDefaultBranch, `
    Resolve-SmartProjectName, `
    Test-ProjectMirrorExists, `
    New-ProjectMirror, `
    Remove-ProjectMirror, `
    Get-ProjectMirrorRemote, `
    Get-ProjectsActualFromDistro, `
    Add-ProjectToProfile, `
    Remove-ProjectFromProfile
