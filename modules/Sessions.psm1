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
#   Get-SessionWorktreePath   -Project -Name [-Home]       — <home>/projects/<p>/sessions/<n>
#   Get-HostSessionGuestMountPath -Project -Name [-Home]   — <home>/host/<n> (or legacy /host/<p>/<n>)
#   Get-HostSessionWorktreePath  -HostCheckout -Name       — '<hostCheckout>-sessions\<name>'
#   Get-SessionDirtyFileCount -DistroName -Project -Name [-User -Home] — git status --porcelain | wc -l
#   New-Session               -DistroName -State -Project -Name -Branch [-NewBranch -BaseBranch -User -Home]
#   New-HostSession           -State -ProjectSpec -Name -Branch [-NewBranch -BaseBranch -Home]
#                                                          — host-side `git worktree add`; mount + shadow installation are caller's responsibility
#   Remove-Session            -DistroName -State -Project -Name [-Force -User -Home]
#   Remove-HostSession        -State -ProjectSpec -Name [-Force]
#                                                          — host-side `git worktree remove`; mount teardown is caller's responsibility
#   Remove-SessionByName      -DistroName -State -Project -Name [-ProjectSpec -ProfileSpec -Force -User -Home]
#                                                          — type-aware wrapper: distro → Remove-Session; host → Remove-HostSession + fstab refresh
#   Remove-SessionsForProject -State -Project               — bulk clean during 'project remove'
#   Update-SessionLastOpened  -State -Project -Name
#   Set-SessionTabTitle       -State -Project -Name -TabTitle
#   Set-SessionTabColor       -State -Project -Name -TabColor
#   Get-RecentBranches        -DistroName -Project [-Limit 5 -User -Home]
#                                                          — `git for-each-ref --sort=-committerdate`
#   Get-HostRecentBranches    -HostCheckout [-Limit 5]      — same, but reads from the host checkout
#   ConvertTo-SessionNameSuggestion -Branch                — 'feature/foo-bar' -> 'foo-bar' (last path segment)
#   Get-MostRecentSession     -State                        — by lastOpenedAt desc
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Projects.psm1')
Import-Module (Join-Path $PSScriptRoot 'Mounts.psm1')

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
    # The Linux path the host worktree gets mounted under. Under per-project user
    # isolation the mount lives inside the project user's 0700 home
    # (<home>/host/<name>) so a sibling project can't traverse to it; absent
    # -Home it falls back to the legacy shared /host/<project>/<name>. Either
    # form is computable from its inputs so fstab teardown can reproduce it
    # without re-reading state.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name,
        [string]$Home
    )
    if ($Home) { return "$Home/host/$Name" }
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
        [Parameter(Mandatory)][string]$Name,
        [string]$Home = '/home/claude'
    )
    return "$Home/projects/$Project/sessions/$Name"
}

function Get-SessionDirtyFileCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $path = Get-SessionWorktreePath -Project $Project -Name $Name -Home $Home
    $q    = ConvertTo-BashQuoted $path
    $cmd  = "[ -d $q ] && git -C $q status --porcelain 2>/dev/null | wc -l || echo 0"
    $r = Invoke-InDistro -Name $DistroName -User $User -Command $cmd -AllowFail -CaptureOutput
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
        [string]$BaseBranch,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    if ($Name -match '[\\/\s]') { throw "Session name '$Name' must not contain whitespace or path separators." }

    if (Test-SessionExists -State $State -Project $Project -Name $Name) {
        throw "Session '$Project/$Name' already exists."
    }
    if (-not (Test-ProjectMirrorExists -DistroName $DistroName -ProjectName $Project -User $User -Home $Home)) {
        throw "Project '$Project' has no bare mirror in the distro. Run 'project add' first."
    }

    $worktreePath = Get-SessionWorktreePath -Project $Project -Name $Name -Home $Home
    $qMirror = ConvertTo-BashQuoted "$Home/mirrors/$Project.git"
    $qWt     = ConvertTo-BashQuoted $worktreePath
    $qBranch = ConvertTo-BashQuoted $Branch

    $sessionsDir = "$Home/projects/$Project/sessions"
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
    Invoke-InDistro -Name $DistroName -User $User -Command $cmd

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
        [string]$BaseBranch,
        [string]$Home
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
    $guest  = if ($Home) {
        Get-HostSessionGuestMountPath -Project $project -Name $Name -Home $Home
    } else {
        Get-HostSessionGuestMountPath -Project $project -Name $Name
    }

    if (Test-Path -LiteralPath $hostWt) {
        throw "Host worktree path '$hostWt' already exists. Remove it first, or choose a different session name."
    }

    # git worktree add. -NewBranch creates a fresh branch off -BaseBranch (or
    # the same name when no base is supplied). For the existing-branch case
    # we have to defend against git's "branch already checked out elsewhere"
    # refusal: every hostCheckout is itself a worktree, so if the user's
    # main checkout sits on $Branch the plain `worktree add ... $Branch`
    # form fails with exit 128. Scan every existing worktree's branch and
    # fall back to `--detach` (session lands at the branch tip in detached
    # HEAD — user can `git switch -c <name>` inside if they want to commit).
    $argv = @('-C', $hostCheckout, 'worktree', 'add')
    if ($NewBranch) {
        $base = if ($BaseBranch) { $BaseBranch } else { $Branch }
        $argv += @('-b', $Branch, $hostWt, $base)
    } else {
        $branchInUse = $false
        try {
            $wtList = & git -C $hostCheckout worktree list --porcelain 2>$null
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in @($wtList)) {
                    $s = [string]$line
                    if ($s -match '^branch refs/heads/(.+)$' -and $Matches[1] -eq $Branch) {
                        $branchInUse = $true; break
                    }
                }
            }
        } catch {}
        if ($branchInUse) {
            Write-Host "  branch '$Branch' is already checked out by another worktree; using --detach for the session." -ForegroundColor DarkYellow
            $argv += @('--detach', $hostWt, $Branch)
        }
        else {
            $argv += @($hostWt, $Branch)
        }
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
    # NB: explicit foreach instead of `@(Get-Sessions … | Where-Object …)[0]`.
    # `Get-Sessions` returns `,$all`; piping that without parens delivers the
    # whole array as a single `$_` to Where-Object, the filter fails, and
    # `[0]` on the empty result throws under StrictMode (see CI failure on
    # HostProjects.Tests.ps1).
    $session = $null
    foreach ($s in (Get-Sessions -State $State -Project $project)) {
        if ($s -is [hashtable] -and [string]$s.name -eq $Name) { $session = $s; break }
    }
    if (-not $session) { throw "Session '$project/$Name' does not exist." }
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
        [switch]$Force,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    if (-not (Test-SessionExists -State $State -Project $Project -Name $Name)) {
        throw "Session '$Project/$Name' does not exist."
    }
    $dirty = Get-SessionDirtyFileCount -DistroName $DistroName -Project $Project -Name $Name -User $User -Home $Home
    if ($dirty -gt 0 -and -not $Force) {
        throw "Session '$Project/$Name' has $dirty uncommitted file(s). Pass -Force to remove anyway."
    }

    $worktreePath = Get-SessionWorktreePath -Project $Project -Name $Name -Home $Home
    $qMirror = ConvertTo-BashQuoted "$Home/mirrors/$Project.git"
    $qWt     = ConvertTo-BashQuoted $worktreePath
    # NB: use a distinct name from the [switch] parameter — pwsh vars are case-insensitive.
    $forceFlag = if ($Force) { '--force' } else { '' }
    $cmd       = "git -C $qMirror worktree remove $forceFlag $qWt"
    Invoke-InDistro -Name $DistroName -User $User -Command $cmd -AllowFail | Out-Null

    $State.sessions = @($State.sessions | Where-Object { -not ([string]$_.project -eq $Project -and [string]$_.name -eq $Name) })
}

function Remove-SessionByName {
    # Type-aware session removal. For distroProject sessions this is a plain
    # delegate to Remove-Session; for hostProject sessions it also rebuilds
    # the fstab managed block so the just-removed worktree's mount entry
    # doesn't dangle. Both call sites (claudearium.ps1's Invoke-SessionRemove
    # and open-claudearium.ps1's dashboard 'd <n>' handler) route through here
    # so the dashboard isn't a second place that has to remember the host
    # cleanup steps.
    #
    # -ProjectSpec is REQUIRED for host sessions (we need hostCheckout to run
    # `git worktree remove`). For distro sessions it can be $null. -ProfileSpec
    # is only used by the post-removal mount rebuild; pass $null if there is
    # no profile (in which case the rebuild only emits session-derived mounts).
    #
    # Returns @{ Type = 'host' | 'distro' } describing what was actually torn
    # down — callers use this to render an accurate completion message rather
    # than recomputing type from a profile lookup that may disagree with the
    # session record (orphan-cleanup case where the project is already gone).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][hashtable]$ProjectSpec,
        [AllowNull()][hashtable]$ProfileSpec,
        [switch]$Force,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    # Resolve type from the profile entry when present; otherwise fall back to
    # the session record (covers orphan-session-cleanup scenarios where the
    # project was already pruned from the profile).
    $type = if ($ProjectSpec) {
        Get-ProjectType -ProjectSpec $ProjectSpec
    }
    else {
        $session = $null
        foreach ($s in (Get-Sessions -State $State -Project $Project)) {
            if ($s -is [hashtable] -and [string]$s.name -eq $Name) { $session = $s; break }
        }
        Get-SessionType -Session $session
    }

    if ($type -eq 'host') {
        if (-not $ProjectSpec) {
            throw "hostProject '$Project' is missing from the profile; cannot remove its session safely (need hostCheckout to run 'git worktree remove')."
        }
        Remove-HostSession -State $State -ProjectSpec $ProjectSpec -Name $Name -Force:$Force
        # Refresh fstab now, before the caller persists state — uses the
        # mutated in-memory state so the removed mount drops out of the merged
        # set even if Write-State hasn't run yet.
        $merged = Get-MergedDesiredMounts -ProfileSpec $ProfileSpec -State $State
        Set-HostMountsInDistro -DistroName $DistroName -Mounts $merged
        return @{ Type = 'host' }
    }

    Remove-Session -DistroName $DistroName -State $State -Project $Project -Name $Name -Force:$Force -User $User -Home $Home
    return @{ Type = 'distro' }
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
        [int]$Limit = 5,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $qPath = ConvertTo-BashQuoted "$Home/mirrors/$Project.git"
    $cmd = "git -C $qPath for-each-ref --sort=-committerdate refs/heads --format='%(refname:short)|%(committerdate:relative)' 2>/dev/null | head -$Limit"
    $r = Invoke-InDistro -Name $DistroName -User $User -Command $cmd -AllowFail -CaptureOutput
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
    Remove-SessionByName, `
    Remove-SessionsForProject, `
    Update-SessionLastOpened, `
    Set-SessionTabTitle, `
    Set-SessionTabColor, `
    Get-RecentBranches, `
    Get-HostRecentBranches, `
    ConvertTo-SessionNameSuggestion, `
    Get-MostRecentSession
