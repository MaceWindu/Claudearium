# Sessions.psm1
# Session lifecycle: per-task git worktrees off a project's bare mirror.
#
# Sessions are tracked in state.json (NOT the profile) because they're
# ephemeral — created per ticket / per feature, destroyed when work lands.
# Profile entries are stable declarative infrastructure; sessions accumulate
# organically and the user shouldn't have to edit a config file to start work
# on a new branch.
#
# Each session has shape:
#   @{
#     project       = 'acme'                                    — parent project name
#     name          = 'feat-1234'                               — session id (unique within project)
#     branch        = 'feature/PROJ-1234-some-feature'          — git branch checked out
#     worktreePath  = '/home/claude/projects/acme/sessions/feat-1234'
#     createdAt     = ISO-8601 timestamp
#     lastOpenedAt  = ISO-8601 timestamp (updated by open-claudearium.ps1)
#     tabTitle      = '🔥 race-fix'  (optional)                — persisted wt tab title
#   }
#
# Public surface:
#   Get-Sessions              -State [-Project]            — filtered list from state
#   Test-SessionExists        -State -Project -Name
#   Get-SessionWorktreePath   -Project -Name               — pure path computation
#   Get-SessionDirtyFileCount -DistroName -Project -Name   — git status --porcelain | wc -l
#   New-Session               -DistroName -State -Project -Name -Branch [-NewBranch -BaseBranch]
#   Remove-Session            -DistroName -State -Project -Name [-Force]
#   Remove-SessionsForProject -State -Project               — bulk clean during 'project remove'
#   Update-SessionLastOpened  -State -Project -Name
#   Set-SessionTabTitle       -State -Project -Name -TabTitle
#   Get-RecentBranches        -DistroName -Project [-Limit 5]
#                                                          — `git for-each-ref --sort=-committerdate`
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
    Get-SessionWorktreePath, `
    Get-SessionDirtyFileCount, `
    New-Session, `
    Remove-Session, `
    Remove-SessionsForProject, `
    Update-SessionLastOpened, `
    Set-SessionTabTitle, `
    Get-RecentBranches, `
    ConvertTo-SessionNameSuggestion, `
    Get-MostRecentSession
