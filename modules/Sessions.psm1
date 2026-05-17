# Sessions.psm1
# Session lifecycle: per-task git worktrees off a project's bare mirror
# (distroProject sessions) or off the user's Windows checkout (hostProject
# sessions).
#
# Sessions are tracked in state.json (NOT the profile) because they're
# ephemeral — created per ticket / per feature, destroyed when work lands.
# Profile entries are stable declarative infrastructure; sessions accumulate
# organically and the user shouldn't have to edit a config file to start work
# on a new branch.
#
# Each session has shape:
#   @{
#     project          = 'acme'                                       — parent project name
#     name             = 'feat-1234'                                  — session id (unique within project)
#     branch           = 'feature/PROJ-1234-some-feature'             — git branch checked out
#     type             = 'distro' | 'host'                            — optional, default 'distro'
#     worktreePath     = '/home/claude/projects/acme/sessions/feat-1234'  (distro)
#                      | '/host/<project>/<name>'                          (host)  — what `--cd` opens
#     hostWorktreePath = 'C:\src\acme-sessions\feat-1234'             — host only
#     createdAt        = ISO-8601 timestamp
#     lastOpenedAt     = ISO-8601 timestamp (updated by open-claudearium.ps1)
#     tabTitle         = '🔥 race-fix'  (optional)                    — persisted wt tab title
#     tabColor         = '#0078D7' | '' (optional)                    — '' = explicit "no color"
#                                                                       missing key = inherit project color
#   }
#
# Public surface:
#   Get-Sessions              -State [-Project]            — filtered list from state
#   Test-SessionExists        -State -Project -Name
#   Get-SessionType           -Session                      — 'distro' (default) / 'host'
#   Get-SessionWorktreePath   -Project -Name               — pure distro-path computation
#   Get-HostSessionGuestMountPath -Project -Name           — '/host/<project>/<name>'
#   Get-HostSessionWorktreePath  -HostCheckout -Name       — '<hostCheckout>-sessions\<name>'
#   Get-SessionDirtyFileCount -DistroName -Project -Name   — git status --porcelain | wc -l
#   New-Session               -DistroName -State -Project -Name -Branch [-NewBranch -BaseBranch]
#   New-HostSession           -State -ProjectSpec -Name -Branch [-NewBranch -BaseBranch]
#                                                          — host-side `git worktree add`; mount + shadow installation are caller's responsibility
#   Remove-Session            -DistroName -State -Project -Name [-Force]
#   Remove-HostSession        -State -ProjectSpec -Name [-Force]
#                                                          — host-side `git worktree remove`; mount teardown is caller's responsibility
#   Remove-SessionsForProject -State -Project               — bulk clean during 'project remove'
#   Update-SessionLastOpened  -State -Project -Name
#   Set-SessionTabTitle       -State -Project -Name -TabTitle
#   Set-SessionTabColor       -State -Project -Name -TabColor
#   Get-RecentBranches        -DistroName -Project [-Limit 5]
#                                                          — `git for-each-ref --sort=-committerdate`
#   Get-HostRecentBranches    -HostCheckout [-Limit 5]      — same, but reads from the host checkout
#   ConvertTo-SessionNameSuggestion -Branch                — 'feature/foo-bar' -> 'foo-bar' (last path segment)
#   Get-MostRecentSession     -State                        — by lastOpenedAt desc
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Projects.psm1')

function Get-Sessions {
    # Returns the sessions array from state, optionally filtered by project.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [string]$Project
    )
    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { return @() }
    $all = @($State.sessions)
    if ($Project) { $all = @($all | Where-Object { [string]$_.project -eq $Project }) }
    return ,$all
}

function Test-SessionExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name
    )
    return [bool]((Get-Sessions -State $State -Project $Project) | Where-Object { [string]$_.name -eq $Name })
}

function Get-SessionType {
    # Canonical 'distro' (default) / 'host' answer for a session record.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Session)
    if (-not $Session -or -not ($Session -is [hashtable])) { return 'distro' }
    if ($Session.ContainsKey('type') -and $Session.type) { return [string]$Session.type }
    return 'distro'
}

function Get-HostSessionGuestMountPath {
    # The Linux path the host worktree gets mounted under. Stable + computable
    # from (project, name) alone — so fstab teardown can reproduce it without
    # re-reading state.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name
    )
    return "/host/$Project/$Name"
}

function Get-HostSessionWorktreePath {
    # The Windows path used for `git worktree add` on a hostProject session.
    # Siblings to the user's main checkout (per design-decisions.md).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostCheckout,
        [Parameter(Mandatory)][string]$Name
    )
    $trimmed = $HostCheckout.TrimEnd('\','/')
    return "$trimmed-sessions\$Name"
}

function Get-SessionWorktreePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name
    )
    return "/home/claude/projects/$Project/sessions/$Name"
}

function Get-SessionDirtyFileCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name
    )
    $path = Get-SessionWorktreePath -Project $Project -Name $Name
    $q    = ConvertTo-BashQuoted $path
    $cmd  = "[ -d $q ] && git -C $q status --porcelain 2>/dev/null | wc -l || echo 0"
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return 0 }
    # Pick the integer line (last numeric output), ignoring any wsl/stderr noise.
    $digit = $r.Output | Where-Object { $_ -is [string] -and $_.Trim() -match '^\d+$' } | Select-Object -Last 1
    if (-not $digit) { return 0 }
    return [int]([string]$digit).Trim()
}

function New-Session {
    # Creates a worktree under the project's bare mirror and records the session in $State.
    # When -NewBranch is set, a fresh branch is created off -BaseBranch (or the project's default).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$NewBranch,
        [string]$BaseBranch
    )
    if ($Name -match '[\\/\s]') { throw "Session name '$Name' must not contain whitespace or path separators." }

    if (Test-SessionExists -State $State -Project $Project -Name $Name) {
        throw "Session '$Project/$Name' already exists."
    }
    if (-not (Test-ProjectMirrorExists -DistroName $DistroName -ProjectName $Project)) {
        throw "Project '$Project' has no bare mirror in the distro. Run 'project add' first."
    }

    $worktreePath = Get-SessionWorktreePath -Project $Project -Name $Name
    $qMirror = ConvertTo-BashQuoted "/home/claude/mirrors/$Project.git"
    $qWt     = ConvertTo-BashQuoted $worktreePath
    $qBranch = ConvertTo-BashQuoted $Branch

    $sessionsDir = "/home/claude/projects/$Project/sessions"
    $qSessionsDir = ConvertTo-BashQuoted $sessionsDir

    if ($NewBranch) {
        $base = if ($BaseBranch) { $BaseBranch } else { $Branch }   # caller supplies sensible base
        $qBase = ConvertTo-BashQuoted $base
        # Note: -b creates the new branch and checks it out at the new worktree.
        $cmd = "mkdir -p $qSessionsDir && git -C $qMirror worktree add -b $qBranch $qWt $qBase"
    }
    else {
        $cmd = "mkdir -p $qSessionsDir && git -C $qMirror worktree add $qWt $qBranch"
    }
    Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd

    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { $State['sessions'] = @() }
    $now = (Get-Date).ToString('o')
    $State.sessions = @($State.sessions) + @(@{
        project       = $Project
        name          = $Name
        branch        = $Branch
        worktreePath  = $worktreePath
        createdAt     = $now
        lastOpenedAt  = $now
    })
}

function New-HostSession {
    # hostProject counterpart to New-Session. The bare-mirror dance is skipped
    # entirely — the user's Windows checkout owns the .git, and `git worktree
    # add` runs on the host (we're already in pwsh). The caller is responsible
    # for the mount + per-project shadow bin dir; this function only owns the
    # host worktree and the session record.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$ProjectSpec,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Branch,
        [switch]$NewBranch,
        [string]$BaseBranch
    )
    if ($Name -match '[\\/\s]') { throw "Session name '$Name' must not contain whitespace or path separators." }
    $project = [string]$ProjectSpec.name
    if (Test-SessionExists -State $State -Project $project -Name $Name) {
        throw "Session '$project/$Name' already exists."
    }
    $hostCheckout = [string]$ProjectSpec.hostCheckout
    if (-not $hostCheckout) { throw "Project '$project' is missing hostCheckout (not a hostProject?)." }
    if (-not (Test-Path -LiteralPath $hostCheckout -PathType Container)) {
        throw "hostCheckout '$hostCheckout' does not exist."
    }

    $hostWt = Get-HostSessionWorktreePath -HostCheckout $hostCheckout -Name $Name
    $guest  = Get-HostSessionGuestMountPath -Project $project -Name $Name

    if (Test-Path -LiteralPath $hostWt) {
        throw "Host worktree path '$hostWt' already exists. Remove it first, or choose a different session name."
    }

    # git worktree add. -NewBranch creates a fresh branch off -BaseBranch (or
    # the same name when no base is supplied).
    $argv = @('-C', $hostCheckout, 'worktree', 'add')
    if ($NewBranch) {
        $base = if ($BaseBranch) { $BaseBranch } else { $Branch }
        $argv += @('-b', $Branch, $hostWt, $base)
    } else {
        $argv += @($hostWt, $Branch)
    }
    & git @argv
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for '$project/$Name' (exit $LASTEXITCODE)." }

    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { $State['sessions'] = @() }
    $now = (Get-Date).ToString('o')
    $State.sessions = @($State.sessions) + @(@{
        project          = $project
        name             = $Name
        branch           = $Branch
        type             = 'host'
        worktreePath     = $guest
        hostWorktreePath = $hostWt
        createdAt        = $now
        lastOpenedAt     = $now
    })
}

function Remove-HostSession {
    # hostProject counterpart to Remove-Session. Runs `git worktree remove` on
    # the host and drops the session record. Mount teardown belongs to the
    # caller (Mounts.Set-HostMountsInDistro with the new merged set).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$ProjectSpec,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force
    )
    $project = [string]$ProjectSpec.name
    if (-not (Test-SessionExists -State $State -Project $project -Name $Name)) {
        throw "Session '$project/$Name' does not exist."
    }
    $session = @(Get-Sessions -State $State -Project $project | Where-Object { [string]$_.name -eq $Name })[0]
    $hostWt = if ($session.ContainsKey('hostWorktreePath') -and $session.hostWorktreePath) {
        [string]$session.hostWorktreePath
    } else {
        Get-HostSessionWorktreePath -HostCheckout ([string]$ProjectSpec.hostCheckout) -Name $Name
    }

    if (Test-Path -LiteralPath $hostWt) {
        $hostCheckout = [string]$ProjectSpec.hostCheckout
        # NB: distinct variable name from the [switch] (PowerShell vars are
        # case-insensitive; reusing $force as a string would clobber it).
        $forceFlag = if ($Force) { '--force' } else { $null }
        $argv = @('-C', $hostCheckout, 'worktree', 'remove')
        if ($forceFlag) { $argv += $forceFlag }
        $argv += $hostWt
        & git @argv
        if ($LASTEXITCODE -ne 0 -and -not $Force) {
            throw "git worktree remove failed for '$project/$Name' (uncommitted changes?). Pass -Force to discard."
        }
        # Belt-and-suspenders: if --force was supplied and git left the dir
        # behind (rare), nuke it. Without -Force we trust git's refusal.
        if ($Force -and (Test-Path -LiteralPath $hostWt)) {
            Remove-Item -LiteralPath $hostWt -Recurse -Force
        }
    }

    $State.sessions = @($State.sessions | Where-Object { -not ([string]$_.project -eq $project -and [string]$_.name -eq $Name) })
}

function Get-HostRecentBranches {
    # Read the most-recently-active branches from a hostProject's checkout.
    # Returns @( @{ Branch; LastCommit } ).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostCheckout,
        [int]$Limit = 5
    )
    if (-not (Test-Path -LiteralPath $HostCheckout)) { return @() }
    $fmt = '%(refname:short)|%(committerdate:relative)'
    $out = & git -C $HostCheckout for-each-ref --sort=-committerdate refs/heads --format=$fmt 2>$null |
        Select-Object -First $Limit
    if ($LASTEXITCODE -ne 0) { return @() }
    $result = @()
    foreach ($line in @($out)) {
        $s = [string]$line
        if ($s -match '^([^|]+)\|(.+)$') {
            $result += @{ Branch = $Matches[1].Trim(); LastCommit = $Matches[2].Trim() }
        }
    }
    return ,$result
}

function Remove-Session {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force
    )
    if (-not (Test-SessionExists -State $State -Project $Project -Name $Name)) {
        throw "Session '$Project/$Name' does not exist."
    }
    $dirty = Get-SessionDirtyFileCount -DistroName $DistroName -Project $Project -Name $Name
    if ($dirty -gt 0 -and -not $Force) {
        throw "Session '$Project/$Name' has $dirty uncommitted file(s). Pass -Force to remove anyway."
    }

    $worktreePath = Get-SessionWorktreePath -Project $Project -Name $Name
    $qMirror = ConvertTo-BashQuoted "/home/claude/mirrors/$Project.git"
    $qWt     = ConvertTo-BashQuoted $worktreePath
    # NB: use a distinct name from the [switch] parameter — pwsh vars are case-insensitive.
    $forceFlag = if ($Force) { '--force' } else { '' }
    $cmd       = "git -C $qMirror worktree remove $forceFlag $qWt"
    Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd -AllowFail | Out-Null

    $State.sessions = @($State.sessions | Where-Object { -not ([string]$_.project -eq $Project -and [string]$_.name -eq $Name) })
}

function Remove-SessionsForProject {
    # Bulk removal when a project itself is being deleted. Doesn't run git
    # worktree remove (the bare clone is going with it); just clears state.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project
    )
    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { return }
    $State.sessions = @($State.sessions | Where-Object { [string]$_.project -ne $Project })
}

function Update-SessionLastOpened {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { return }
    foreach ($s in $State.sessions) {
        if ([string]$s.project -eq $Project -and [string]$s.name -eq $Name) {
            $s.lastOpenedAt = (Get-Date).ToString('o')
        }
    }
}

function Set-SessionTabTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TabTitle
    )
    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { return }
    foreach ($s in $State.sessions) {
        if ([string]$s.project -eq $Project -and [string]$s.name -eq $Name) {
            $s['tabTitle'] = $TabTitle
        }
    }
}

function Set-SessionTabColor {
    # Pass '' to record an explicit "no color" override (distinct from missing
    # the key, which falls back to the project's tabColor). Anything else is
    # stored verbatim and validated by Open-SessionTab at apply time.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TabColor
    )
    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { return }
    foreach ($s in $State.sessions) {
        if ([string]$s.project -eq $Project -and [string]$s.name -eq $Name) {
            $s['tabColor'] = $TabColor
        }
    }
}

function Get-RecentBranches {
    # Pull the top-N branches from a project's bare mirror, newest commit first.
    # Output: @( @{ Branch; LastCommit } ).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Project,
        [int]$Limit = 5
    )
    $qPath = ConvertTo-BashQuoted "/home/claude/mirrors/$Project.git"
    $cmd = "git -C $qPath for-each-ref --sort=-committerdate refs/heads --format='%(refname:short)|%(committerdate:relative)' 2>/dev/null | head -$Limit"
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return @() }
    $result = @()
    foreach ($line in $r.Output) {
        $s = [string]$line
        if ($s -match '^([^|]+)\|(.+)$') {
            $result += @{
                Branch     = $Matches[1].Trim()
                LastCommit = $Matches[2].Trim()
            }
        }
    }
    return ,$result
}

function ConvertTo-SessionNameSuggestion {
    # 'feature/some-thing-here' -> 'some-thing-here'  (last path segment)
    # 'master'                  -> 'master'
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Branch)
    $parts = $Branch -split '/'
    return ([string]$parts[-1])
}

function Get-MostRecentSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { return $null }
    $sessions = @($State.sessions)
    if ($sessions.Count -eq 0) { return $null }
    # Sort by lastOpenedAt desc, fall back to createdAt for sessions never opened.
    $sorted = $sessions | Sort-Object -Property `
        @{ Expression = {
            if ($_.ContainsKey('lastOpenedAt') -and $_.lastOpenedAt) { [string]$_.lastOpenedAt }
            elseif ($_.ContainsKey('createdAt') -and $_.createdAt)   { [string]$_.createdAt }
            else { '' }
        }; Descending = $true }
    return $sorted | Select-Object -First 1
}

Export-ModuleMember -Function `
    Get-Sessions, `
    Test-SessionExists, `
    Get-SessionType, `
    Get-SessionWorktreePath, `
    Get-HostSessionGuestMountPath, `
    Get-HostSessionWorktreePath, `
    Get-SessionDirtyFileCount, `
    New-Session, `
    New-HostSession, `
    Remove-Session, `
    Remove-HostSession, `
    Remove-SessionsForProject, `
    Update-SessionLastOpened, `
    Set-SessionTabTitle, `
    Set-SessionTabColor, `
    Get-RecentBranches, `
    Get-HostRecentBranches, `
    ConvertTo-SessionNameSuggestion, `
    Get-MostRecentSession
