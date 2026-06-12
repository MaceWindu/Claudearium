# Projects.psm1
# Project lifecycle: bare-mirror clones (distroProjects), host-side worktree
# checkouts (hostProjects), profile mutation, smart-default remote/branch
# detection from a host git checkout.
#
# A project is dual-capability: it may carry a distro half (`remote` -> a bare
# mirror at <home>/mirrors/<name>.git, sessions are worktrees off this mirror)
# and/or a host half (`hostCheckout` -> the user's Windows-side checkout is the
# authoritative source, sessions are `git worktree add` paths on the host
# mounted into the distro; see Sessions.New-HostSession). At least one half is
# required; a project with both lets the user create distro AND host sessions
# side by side. Capability derives from which fields are present, not a `type`
# field (the legacy `type` key is dropped on any half mutation).
# See docs/design-decisions.md#5 for the bare-mirror-vs-full-clone rationale.
#
# Public surface:
#   Smart defaults (read from a host-side checkout)
#     Resolve-SmartRemote        -HostCheckout      — `git remote get-url origin`
#     Resolve-SmartDefaultBranch -HostCheckout      — `git symbolic-ref refs/remotes/origin/HEAD`
#     Resolve-SmartProjectName   -Remote            — last path segment of remote URL
#   Mirror lifecycle (in-distro git ops, distroProjects only)
#     Test-ProjectMirrorExists  -DistroName -ProjectName [-User -Home]
#     New-ProjectMirror         -DistroName -ProjectName -Remote [-User -Home]   — git clone --mirror
#     Remove-ProjectMirror      -DistroName -ProjectName [-User -Home]           — rm -rf mirror + sessions dir
#     Get-ProjectMirrorRemote   -DistroName -ProjectName [-User -Home]           — read 'remote get-url origin'
#     Get-ProjectsActualFromDistro -DistroName [-State]               — enumerate per-project-user homes
#                                                                         (+ legacy /home/claude) for mirrors / host-project dirs
#
# -User/-Home default to the legacy single-user 'claude' / '/home/claude'. Under
# per-project user isolation the caller resolves the project's user record (via
# State.Get-ProjectUser) and passes that user + home so the mirror/sessions live
# inside the project user's 0700 home.
#   Host-checkout lifecycle (host half only)
#     Test-HostCheckout         -HostCheckout        — is it a directory containing a .git dir/file?
#     Get-ProjectType           -ProjectSpec        — legacy: 'distro' (default) / 'host' from the `type` key
#     Get-ProjectHalves         -ProjectSpec        — canonical: @{ Distro=$bool; Host=$bool } from field presence
#   Profile mutation
#     Add-ProjectToProfile         -ProfilePath -ProjectSpec
#     Remove-ProjectFromProfile    -ProfilePath -Name
#     Set-ProjectEnabledInProfile  -ProfilePath -Name -Enabled       — toggle `enabled` field, preserves %ENV%
#     Add-ProjectHalfInProfile     -ProfilePath -Name -Half
#                                  [-Remote -HostCheckout -HostShadows]  — non-destructively add a capability
#     Remove-ProjectHalfInProfile  -ProfilePath -Name -Half             — strip one half, keep the other
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')
Import-Module (Join-Path $PSScriptRoot 'State.psm1')

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
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $q = ConvertTo-BashQuoted "$Home/mirrors/$ProjectName.git"
    $r = Invoke-InDistro -Name $DistroName -User $User -Command "test -d $q" -AllowFail -CaptureOutput
    return ($r.ExitCode -eq 0)
}

function New-ProjectMirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$Remote,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $qDir    = ConvertTo-BashQuoted "$Home/mirrors"
    $qRemote = ConvertTo-BashQuoted $Remote
    $qName   = ConvertTo-BashQuoted "$ProjectName.git"
    # NB: the dubious-ownership guard that fires when a fresh cp-* user clones a
    # local-path remote owned by someone else is handled at user-provisioning
    # time (New-ProjectUserInDistro writes safe.directory=* into the user's
    # global gitconfig). It can't be fixed with `-c safe.directory` here — git
    # ignores that config from the command line for security.
    $cmd = "mkdir -p $qDir && cd $qDir && git clone --mirror $qRemote $qName"
    Invoke-InDistro -Name $DistroName -User $User -Command $cmd
}

function Remove-ProjectMirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $qMirror = ConvertTo-BashQuoted "$Home/mirrors/$ProjectName.git"
    $qProj   = ConvertTo-BashQuoted "$Home/projects/$ProjectName"
    Invoke-InDistro -Name $DistroName -User $User -Command "rm -rf $qMirror $qProj"
}

function Get-ProjectMirrorRemote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $qPath = ConvertTo-BashQuoted "$Home/mirrors/$ProjectName.git"
    $r = Invoke-InDistro -Name $DistroName -User $User -Command "git -C $qPath remote get-url origin 2>/dev/null" -AllowFail -CaptureOutput
    if ($r.ExitCode -eq 0) { return (($r.Output -join "`n").Trim()) }
    return $null
}

function Get-ClaudeariumProjectUsers {
    # Enumerate claudearium-managed project users present in the distro: cp-*
    # accounts with a uid in the project-user range. Parsed in pwsh (not `awk
    # '$N'`) to avoid the wsl argv `$`-field mangling (gotcha #1 / #13).
    # Returns @( @{ user; uid; home } ).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command 'getent passwd' -AllowFail -CaptureOutput
    $out = @()
    if ($r.ExitCode -ne 0) { return ,$out }
    foreach ($line in $r.Output) {
        if ($null -eq $line) { continue }
        $f = ([string]$line) -split ':'
        if ($f.Count -lt 7) { continue }
        $u = $f[0]; $uid = $f[2]; $home = $f[5]
        if ($u -notmatch '^cp-') { continue }
        if ($uid -notmatch '^\d+$') { continue }
        $uidN = [int]$uid
        if ($uidN -lt 30000 -or $uidN -ge 60000) { continue }
        $out += @{ user = $u; uid = $uidN; home = $home }
    }
    return ,$out
}

function Get-ProjectsActualFromDistro {
    # Enumerate every project materialized in the distro. Two flavors:
    #   * distroProject: bare mirror under <home>/mirrors/<name>.git
    #     -> returned with the mirror's `remote get-url origin` value.
    #   * hostProject:   per-project bin dir under <home>/host-projects/<name>/
    #     -> returned with type='host' and empty `remote`.
    # Under per-project user isolation each project's <home> is its own user's
    # 0700 home, so we enumerate the cp-* users and probe each home. The legacy
    # single-user /home/claude tree is still scanned so a not-yet-migrated distro
    # continues to enumerate. When -State is supplied its users map gives the
    # exact project name for a user; otherwise the mirror/bin-dir leaf is used.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()][hashtable]$State
    )
    $result = @()

    # user -> exact project name, from state (reverse of the users map).
    $userToProject = @{}
    if ($State) {
        foreach ($kv in (Get-AllProjectUsers -State $State).GetEnumerator()) {
            if ($kv.Value -is [hashtable] -and $kv.Value.ContainsKey('user')) {
                $userToProject[[string]$kv.Value.user] = [string]$kv.Key
            }
        }
    }

    # Each scan target is a (user, home) pair: the legacy lobby plus every
    # cp-* project user. A project user owns exactly one project, but we probe
    # generically so a drifted/multi-mirror home is still surfaced.
    $targets = @(@{ user = 'claude'; home = '/home/claude' })
    # Capture-then-enumerate: piping the ,$out-wrapped return straight into a
    # pipeline feeds the whole array as one item (the Get-WslDistros trap,
    # Wsl.psm1:71-77). Assigning to a variable unwraps one level first.
    $cpUsers = Get-ClaudeariumProjectUsers -DistroName $DistroName
    foreach ($cu in $cpUsers) { $targets += @{ user = $cu.user; home = $cu.home } }

    foreach ($t in $targets) {
        $u = $t.user; $h = $t.home
        $qMirrors = ConvertTo-BashQuoted "$h/mirrors"
        $cmd = "[ -d $qMirrors ] && find $qMirrors -maxdepth 1 -name '*.git' -type d -printf '%f\n' || true"
        $r = Invoke-InDistro -Name $DistroName -User $u -Command $cmd -AllowFail -CaptureOutput
        if ($r.ExitCode -eq 0) {
            $names = @($r.Output |
                Where-Object { $_ -is [string] -and ($_.Trim() -match '^[^\\/\s]+\.git$') } |
                ForEach-Object { $_.Trim() -replace '\.git$', '' })
            foreach ($n in $names) {
                $projName = if ($userToProject.ContainsKey($u)) { $userToProject[$u] } else { $n }
                $result += @{
                    name   = $projName
                    type   = 'distro'
                    remote = (Get-ProjectMirrorRemote -DistroName $DistroName -ProjectName $n -User $u -Home $h)
                }
            }
        }

        $qHostProj = ConvertTo-BashQuoted "$h/host-projects"
        $hcmd = "[ -d $qHostProj ] && find $qHostProj -maxdepth 1 -mindepth 1 -type d -printf '%f\n' || true"
        $hr = Invoke-InDistro -Name $DistroName -User $u -Command $hcmd -AllowFail -CaptureOutput
        if ($hr.ExitCode -eq 0) {
            $hnames = @($hr.Output |
                Where-Object { $_ -is [string] -and ($_.Trim() -match '^[A-Za-z0-9._-]+$') } |
                ForEach-Object { $_.Trim() })
            foreach ($n in $hnames) {
                $projName = if ($userToProject.ContainsKey($u)) { $userToProject[$u] } else { $n }
                $result += @{ name = $projName; type = 'host'; remote = '' }
            }
        }
    }

    return ,$result
}

function Test-HostCheckout {
    # A hostProject's hostCheckout must be an existing directory whose `.git` is
    # present (either a `.git/` dir for a regular repo or a `.git` file for a
    # worktree linked to a parent). Test-Path checks both kinds via -Path.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostCheckout)
    if (-not (Test-Path -LiteralPath $HostCheckout -PathType Container)) { return $false }
    $dotGit = Join-Path $HostCheckout '.git'
    return [bool](Test-Path -LiteralPath $dotGit)
}

function Get-ProjectType {
    # Canonical 'is this distro or host' answer for a project profile entry.
    # Missing 'type' defaults to 'distro' — distroProjects predate the field.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$ProjectSpec)
    if (-not $ProjectSpec -or -not ($ProjectSpec -is [hashtable])) { return 'distro' }
    if ($ProjectSpec.ContainsKey('type') -and $ProjectSpec.type) { return [string]$ProjectSpec.type }
    return 'distro'
}

function Get-ProjectHalves {
    # Canonical capability accessor for a project entry. A project may have a
    # distro half (non-empty `remote`) and/or a host half (non-empty
    # `hostCheckout`); both, one, or — only for a malformed entry — neither.
    # Returns @{ Distro = $bool; Host = $bool }. Presence of the field is the
    # source of truth (the legacy `type` key is advisory and ignored here).
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$ProjectSpec)
    $hasDistro = $false
    $hasHost   = $false
    if ($ProjectSpec -is [hashtable]) {
        if ($ProjectSpec.ContainsKey('remote') -and -not [string]::IsNullOrWhiteSpace([string]$ProjectSpec.remote)) { $hasDistro = $true }
        if ($ProjectSpec.ContainsKey('hostCheckout') -and -not [string]::IsNullOrWhiteSpace([string]$ProjectSpec.hostCheckout)) { $hasHost = $true }
    }
    return @{ Distro = $hasDistro; Host = $hasHost }
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

function Set-ProjectEnabledInProfile {
    # Flip the `enabled` field on a profile project entry. Returns $true on a
    # successful mutation (entry exists), $false if the project wasn't found.
    # Reads + writes the profile in -Raw mode so %ENV% tokens stay intact.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Enabled
    )
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return $false }
    $spec = Read-Profile -Path $ProfilePath -Raw
    if (-not $spec.ContainsKey('projects') -or -not $spec.projects) { return $false }
    $existing = @($spec.projects)
    $found = $false
    foreach ($p in $existing) {
        if ($p -is [hashtable] -and [string]$p.name -eq $Name) {
            $p['enabled'] = $Enabled
            $found = $true
            break
        }
    }
    if (-not $found) { return $false }
    $spec.projects = $existing
    Write-Profile -Path $ProfilePath -Spec $spec
    return $true
}

function Get-ProjectEntryFromProfile {
    # Read the raw profile and return @{ Spec; Existing; Entry } for $Name, or
    # throw if the profile has no projects[] / the project is absent. Shared by
    # the half mutators so they don't each re-implement the lookup + @() wrap.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $ProfilePath)) { throw "Profile not found: $ProfilePath" }
    $spec = Read-Profile -Path $ProfilePath -Raw
    if (-not $spec.ContainsKey('projects') -or -not $spec.projects) {
        throw "Profile has no projects[] array."
    }
    $existing = @($spec.projects)
    $entry = $null
    foreach ($p in $existing) {
        if ($p -is [hashtable] -and [string]$p.name -eq $Name) { $entry = $p; break }
    }
    if (-not $entry) { throw "Project '$Name' not found in profile." }
    return @{ Spec = $spec; Existing = $existing; Entry = $entry }
}

function Add-ProjectHalfInProfile {
    # Non-destructively add a capability ("half") to an existing project entry:
    # the distro half (`remote` -> bare mirror) or the host half (`hostCheckout`
    # + `hostShadows` -> per-project worktrees). The other half, if present, is
    # left intact — this is how a project becomes dual-capability. Throws if the
    # requested half already exists or the project is absent. Drops the legacy
    # `type` key (capability now derives from field presence).
    #
    # This is the profile-mutation half of `project add-distro`/`add-host`; the
    # verb owns the re-provision (clone mirror or install bin dir).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('distro','host')][string]$Half,
        [string]$Remote,                  # required for Half=distro
        [string]$HostCheckout,            # required for Half=host
        [AllowNull()][object[]]$HostShadows
    )
    $ctx      = Get-ProjectEntryFromProfile -ProfilePath $ProfilePath -Name $Name
    $entry    = $ctx.Entry
    $halves   = Get-ProjectHalves -ProjectSpec $entry

    if ($Half -eq 'distro') {
        if ($halves.Distro) { throw "Project '$Name' already has a distro half (remote '$([string]$entry.remote)')." }
        if (-not $Remote)   { throw "Add-ProjectHalfInProfile -Half distro requires -Remote." }
        $entry['remote'] = $Remote
    }
    else {
        if ($halves.Host)       { throw "Project '$Name' already has a host half (hostCheckout '$([string]$entry.hostCheckout)')." }
        if (-not $HostCheckout) { throw "Add-ProjectHalfInProfile -Half host requires -HostCheckout." }
        $entry['hostCheckout'] = $HostCheckout
        $shadows = if ($HostShadows) { @($HostShadows) } else { @('pwsh', 'git') }
        $entry['hostShadows']  = $shadows
    }
    # Capability derives from which fields are present now; a stale `type` key
    # would misrepresent a dual entry, so drop it on any half mutation.
    if ($entry.ContainsKey('type')) { [void]$entry.Remove('type') }

    $ctx.Spec.projects = $ctx.Existing
    Write-Profile -Path $ProfilePath -Spec $ctx.Spec
}

function Remove-ProjectHalfInProfile {
    # Non-destructively strip one capability from a project entry, keeping the
    # other. Refuses to remove the last remaining half — that's `project remove`,
    # which also deletes the project's Linux user. Cross-type fields (tabColor,
    # defaultBranch, enabled, hostMounts, claudeSettings, claudeFile) survive.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('distro','host')][string]$Half
    )
    $ctx    = Get-ProjectEntryFromProfile -ProfilePath $ProfilePath -Name $Name
    $entry  = $ctx.Entry
    $halves = Get-ProjectHalves -ProjectSpec $entry

    if ($Half -eq 'distro') {
        if (-not $halves.Distro) { throw "Project '$Name' has no distro half to remove." }
        if (-not $halves.Host)   { throw "Project '$Name' has only a distro half; use 'project remove' to delete the whole project." }
        # `hostTools` is a distro-half-only field; drop it alongside `remote`.
        foreach ($k in @('remote','hostTools')) { if ($entry.ContainsKey($k)) { [void]$entry.Remove($k) } }
    }
    else {
        if (-not $halves.Host)   { throw "Project '$Name' has no host half to remove." }
        if (-not $halves.Distro) { throw "Project '$Name' has only a host half; use 'project remove' to delete the whole project." }
        foreach ($k in @('hostCheckout','hostShadows')) { if ($entry.ContainsKey($k)) { [void]$entry.Remove($k) } }
    }
    if ($entry.ContainsKey('type')) { [void]$entry.Remove('type') }

    $ctx.Spec.projects = $ctx.Existing
    Write-Profile -Path $ProfilePath -Spec $ctx.Spec
}

Export-ModuleMember -Function `
    Resolve-SmartRemote, `
    Resolve-SmartDefaultBranch, `
    Resolve-SmartProjectName, `
    Test-ProjectMirrorExists, `
    New-ProjectMirror, `
    Remove-ProjectMirror, `
    Get-ProjectMirrorRemote, `
    Get-ClaudeariumProjectUsers, `
    Get-ProjectsActualFromDistro, `
    Test-HostCheckout, `
    Get-ProjectType, `
    Get-ProjectHalves, `
    Add-ProjectToProfile, `
    Remove-ProjectFromProfile, `
    Set-ProjectEnabledInProfile, `
    Get-ProjectEntryFromProfile, `
    Add-ProjectHalfInProfile, `
    Remove-ProjectHalfInProfile
