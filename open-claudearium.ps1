#!/usr/bin/env pwsh
# Interactive launcher for sandbox Claude Code sessions.
#
# Bare-name (no args) opens a dashboard: pick an existing session by number to
# launch it in a wt tab, or '+' creates a new session walking through a wizard
# (project -> branch -> session name -> tab title -> confirm). '-Last' opens
# the most-recently-used session immediately. '-Project'/'-Session' direct-open
# without the menu.
#
# wt.exe is preferred; if absent, falls back to attaching to the current
# console. Multiple parallel invocations open multiple tabs in the same wt
# window (so long as they share the same UAC elevation — see README).
[CmdletBinding()]
param(
    [string]$Name = 'claudearium',
    [string]$Project,
    [string]$Session,
    [string]$Title,
    [switch]$Last,
    [switch]$NewWindow,
    [switch]$NoTerminal,
    [string]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Inside a function $PSBoundParameters rebinds to that function's bound
# params, so script-level checks like `.ContainsKey('Name')` silently
# fail from inside Resolve-Distro. Capture once at script root and read
# $Script:RootBoundParams from the helpers below.
$Script:RootBoundParams = $PSBoundParameters

$Script:ScriptRoot = $PSScriptRoot
$Script:ModulesDir = Join-Path $Script:ScriptRoot 'modules'

# See claudearium.ps1 for the rationale — MOTW unblock on the install tree,
# gated on a one-time sentinel so we don't recurse the install on every
# launcher invocation. `update apply` removes the sentinel before swapping
# files, so the next launch re-unblocks the newly-extracted tree.
$Script:MotwSentinel = Join-Path $Script:ScriptRoot '.motw-unblocked'
if (-not (Test-Path -LiteralPath $Script:MotwSentinel -PathType Leaf)) {
    try {
        Get-ChildItem -LiteralPath $Script:ScriptRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $Script:MotwSentinel -Force -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

Import-Module (Join-Path $Script:ModulesDir 'State.psm1')    -Force
Import-Module (Join-Path $Script:ModulesDir 'UI.psm1')       -Force
Import-Module (Join-Path $Script:ModulesDir 'Wsl.psm1')      -Force
Import-Module (Join-Path $Script:ModulesDir 'Profile.psm1')  -Force
Import-Module (Join-Path $Script:ModulesDir 'Users.psm1')    -Force
Import-Module (Join-Path $Script:ModulesDir 'Projects.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Sessions.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Tmux.psm1')     -Force
Import-Module (Join-Path $Script:ModulesDir 'Mounts.psm1')   -Force
Import-Module (Join-Path $Script:ModulesDir 'HostShadows.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'WinTerminal.psm1') -Force

# Resolve once: callers (tests, automation) can override the profile file
# via -ProfilePath; otherwise the user's default profile under
# %LOCALAPPDATA% is used. Every Read-Profile call in this script goes
# through $Script:ProfilePath so test fixtures can isolate state.
$Script:ProfilePath = if ($ProfilePath) { $ProfilePath } else { Get-DefaultProfilePath }

# ---------- helpers ----------

function Resolve-Distro {
    if ($Script:RootBoundParams.ContainsKey('Name') -and $Name) { return $Name }
    if (Test-Path $Script:ProfilePath) {
        $spec = Read-Profile -Path $Script:ProfilePath
        if ($spec -and $spec.distro -and $spec.distro.name) { return [string]$spec.distro.name }
    }
    return $Name
}

function Get-SessionRow {
    # Look up a single session record from state by project + name.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $State.ContainsKey('sessions') -or -not $State.sessions) { return $null }
    return @($State.sessions | Where-Object { [string]$_.project -eq $Project -and [string]$_.name -eq $Name }) | Select-Object -First 1
}

function Format-Ago {
    [CmdletBinding()] param([string]$IsoTimestamp)
    if ([string]::IsNullOrWhiteSpace($IsoTimestamp)) { return '(never)' }
    try {
        $t = [DateTime]::Parse($IsoTimestamp)
        $delta = (Get-Date) - $t
        if ($delta.TotalSeconds -lt 60)  { return "$([int]$delta.TotalSeconds)s ago" }
        if ($delta.TotalMinutes -lt 60)  { return "$([int]$delta.TotalMinutes)m ago" }
        if ($delta.TotalHours -lt 48)    { return "$([int]$delta.TotalHours)h ago" }
        return "$([int]$delta.TotalDays)d ago"
    }
    catch { return $IsoTimestamp }
}

function Resolve-EffectiveTabColor {
    # Resolution: session.tabColor wins if present (even empty = explicit no-color);
    # otherwise inherit the project's tabColor from the profile; otherwise no color.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$SessionRecord)
    if ($SessionRecord.ContainsKey('tabColor')) { return [string]$SessionRecord.tabColor }
    try {
        $spec = Read-Profile -Path $Script:ProfilePath
        if ($spec -and $spec.ContainsKey('projects') -and $spec.projects) {
            $p = @($spec.projects | Where-Object { [string]$_.name -eq [string]$SessionRecord.project }) | Select-Object -First 1
            if ($p -and $p.ContainsKey('tabColor') -and $p.tabColor) { return [string]$p.tabColor }
        }
    } catch { }
    return ''
}

function Resolve-EffectiveWtProfile {
    # If the session's project sets an icon or backgroundImage, return the name of
    # the generated Windows Terminal profile (so the tab can launch with `-p`);
    # otherwise ''. Unlike tabColor, these visuals have no wt.exe CLI flag — they
    # live in a WT profile fragment that `reconcile` / `wt-profiles apply` writes.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$SessionRecord)
    try {
        $spec = Read-Profile -Path $Script:ProfilePath
        if ($spec -and $spec.ContainsKey('projects') -and $spec.projects) {
            $p = @($spec.projects | Where-Object { [string]$_.name -eq [string]$SessionRecord.project }) | Select-Object -First 1
            if ($p -and (Test-ProjectHasWtAppearance -ProjectSpec $p)) {
                return (Get-ProjectWtProfileName -Name ([string]$SessionRecord.project))
            }
        }
    } catch { }
    return ''
}

function Resolve-SessionUserHome {
    # Read-only project -> { User; Home } resolution from state. Falls back to the
    # legacy single 'claude' / '/home/claude' when the project has no user record
    # (pre-isolation distro), so launching old sessions keeps working.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Project)
    $rec = Get-ProjectUser -State $State -Project $Project
    if ($rec) { return @{ User = [string]$rec.user; Home = [string]$rec.home } }
    return @{ User = 'claude'; Home = '/home/claude' }
}

function Resolve-SessionBashCommand {
    # The string fed to `bash -lc`. Sessions run claude inside a named tmux
    # session (cl-<project>-<name>) via `new-session -A` — attach-or-create — so
    # closing the wt window detaches (the per-user tmux server keeps the session
    # alive) and reopening reattaches without spawning a duplicate. For host
    # sessions the per-project init.sh (which contains `export PATH=<bin>:$PATH`)
    # is sourced from disk first so its `$PATH` is preserved (putting it in the
    # wsl.exe argv would mangle it to '' — wsl2-gotchas.md #1 / #20). The launch
    # string is built by Tmux.Get-TmuxLaunchCommand as a pure-ASCII literal.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$SessionRecord,
        [string]$Home = '/home/claude'
    )
    $tmuxName = Get-SessionTmuxName -Session $SessionRecord
    if ((Get-SessionType -Session $SessionRecord) -eq 'host') {
        $initSh = Get-HostShadowInitScriptPath -ProjectName ([string]$SessionRecord.project) -Home $Home
        return (Get-TmuxLaunchCommand -TmuxName $tmuxName -InitScript $initSh)
    }
    return (Get-TmuxLaunchCommand -TmuxName $tmuxName)
}

function Open-SessionTab {
    # Spawn a Windows Terminal tab/window running `claude` inside the session's
    # worktree. Falls back to attaching the current console if wt.exe is missing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$SessionRecord,
        [string]$OverrideTitle
    )
    $tabTitle = if ($OverrideTitle) { $OverrideTitle }
                elseif ($SessionRecord.ContainsKey('tabTitle') -and $SessionRecord.tabTitle) { [string]$SessionRecord.tabTitle }
                else { [string]$SessionRecord.name }
    $tabColor = Resolve-EffectiveTabColor -SessionRecord $SessionRecord
    $wtProfile = Resolve-EffectiveWtProfile -SessionRecord $SessionRecord

    $wt = $null
    if (-not $NoTerminal) { $wt = Get-Command wt.exe -ErrorAction SilentlyContinue }

    # tmux backs session persistence; install on demand for distros provisioned
    # before tmux joined the bootstrap package list (no-op if already present).
    Install-Tmux -DistroName $DistroName

    # Stamp the open + commit state before launching the (asynchronous) wt window.
    $state = Read-State -DistroName $DistroName
    # Resolve which Linux user owns this project's session (legacy claude fallback).
    $pu = Resolve-SessionUserHome -State $state -Project ([string]$SessionRecord.project)
    # New model: the session opens into the project's persistent main/ checkout
    # (the curation launch pad). Legacy per-worktree records keep their path.
    $worktree = Get-SessionMainCwd -Session $SessionRecord -Home $pu.Home
    $bashCmd = Resolve-SessionBashCommand -SessionRecord $SessionRecord -Home $pu.Home
    Update-SessionLastOpened -State $state -Project $SessionRecord.project -Name $SessionRecord.name
    Update-SessionTmuxName   -State $state -Project $SessionRecord.project -Name $SessionRecord.name
    if ($OverrideTitle) { Set-SessionTabTitle -State $state -Project $SessionRecord.project -Name $SessionRecord.name -TabTitle $OverrideTitle }
    Add-Recent -State $state -Key 'tabTitles' -Value $tabTitle
    Write-State -DistroName $DistroName -State $state

    if ($wt) {
        $tabArgs = @()
        if (-not $NewWindow) { $tabArgs += @('-w', '0') }
        $tabArgs += @('nt', '--title', $tabTitle)
        # -p selects the generated WT profile (icon / background image / opacity);
        # the appended `-- wsl.exe …` still overrides the commandline. tabColor is
        # applied after so an explicit color wins over the profile's.
        if ($wtProfile) { $tabArgs += @('-p', $wtProfile) }
        if ($tabColor)  { $tabArgs += @('--tabColor', $tabColor) }
        $tabArgs += @(
            '--suppressApplicationTitle',
            '--',
            'wsl.exe',
            '-d', $DistroName,
            '-u', $pu.User,
            '--cd', $worktree,
            '--',
            'bash', '-lc', $bashCmd
        )
        $where = if ($NewWindow) { 'new wt window' } else { 'new wt tab' }
        $colorBit = if ($tabColor) { ", color: $tabColor" } else { '' }
        $profileBit = if ($wtProfile) { ", profile: $wtProfile" } else { '' }
        Write-Host "Opening '$($SessionRecord.project)/$($SessionRecord.name)' as $where (title: '$tabTitle'$colorBit$profileBit)" -ForegroundColor Cyan
        Start-Process -FilePath 'wt.exe' -ArgumentList $tabArgs
    }
    else {
        Write-Host "No wt.exe — running 'claude' in this console for $($SessionRecord.project)/$($SessionRecord.name)" -ForegroundColor Cyan
        & wsl.exe -d $DistroName -u $pu.User --cd $worktree -- bash -lc $bashCmd
    }
}

# ---------- new-session wizard ----------

function Invoke-PickProject {
    # Returns the project name (existing or freshly-added), or $null if cancelled.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)

    $pickState = if (Test-State -DistroName $DistroName) { Read-State -DistroName $DistroName } else { $null }
    $actual = Get-ProjectsActualFromDistro -DistroName $DistroName -State $pickState
    $names = @($actual | ForEach-Object { [string]$_.name } | Sort-Object -Unique)

    if ($names.Count -eq 0) {
        Write-Host 'No projects exist yet. Add one first.' -ForegroundColor Yellow
        $ok = Read-YesNo -Prompt 'Run project-add wizard now?' -Default $true
        if (-not $ok) { return $null }
        return Invoke-NewProjectWizard -DistroName $DistroName
    }

    Write-Host ''
    Write-Host 'Pick a project:'
    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), $names[$i]) }
    Write-Host '  +) add a new project'
    Write-Host '  q) cancel'

    while ($true) {
        $a = (Read-Host '  >').Trim()
        if ($a -eq 'q' -or $a -eq '') { return $null }
        if ($a -eq '+') { return (Invoke-NewProjectWizard -DistroName $DistroName) }
        if ($a -match '^\d+$') {
            $idx = [int]$a - 1
            if ($idx -ge 0 -and $idx -lt $names.Count) { return $names[$idx] }
        }
        Write-Host '  invalid.' -ForegroundColor Yellow
    }
}

function Invoke-NewProjectWizard {
    # Walks the user through `project add` interactively from inside the launcher,
    # returns the new project name on success or $null on cancel.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    Write-Host ''
    Write-Host '--- new project ---'
    $remote = (Read-Host 'Remote URL').Trim()
    if (-not $remote) { return $null }
    $derived = Resolve-SmartProjectName -Remote $remote
    $hintN = if ($derived) { " [$derived]" } else { '' }
    $nameEntry = (Read-Host "Project name$hintN").Trim()
    $projName = if ([string]::IsNullOrWhiteSpace($nameEntry)) { $derived } else { $nameEntry }
    if (-not $projName) { return $null }
    if ($projName -match '[\\/\s]') {
        Write-Host "Invalid project name: $projName" -ForegroundColor Red
        return $null
    }
    $branchEntry = (Read-Host 'Default branch [master]').Trim()
    $defaultBranch = if ([string]::IsNullOrWhiteSpace($branchEntry)) { 'master' } else { $branchEntry }

    $tabColor = Read-TabColor -Prompt "Default wt tab color for '$projName' sessions" -Default ''

    $entry = @{ name = $projName; remote = $remote; defaultBranch = $defaultBranch }
    if ($tabColor) { $entry['tabColor'] = $tabColor }
    Add-ProjectToProfile -ProfilePath $Script:ProfilePath -ProjectSpec $entry

    # Allocate + provision the project's dedicated Linux user, then clone the
    # mirror into its 0700 home (mirrors the reconcile 'add' path).
    $state = if (Test-State -DistroName $DistroName) { Read-State -DistroName $DistroName } else { Initialize-State -DistroName $DistroName }
    $rec = New-ProjectUserRecord -State $state -Project $projName -DistroName $DistroName
    Write-Host "  provisioning user '$($rec.user)' (uid $($rec.uid)) ..."
    New-ProjectUserInDistro -DistroName $DistroName -User ([string]$rec.user) -Uid ([int]$rec.uid) -Password ([string]$rec.password)
    Write-State -DistroName $DistroName -State $state

    Write-Host "  cloning $remote -> $($rec.home)/mirrors/$projName.git ..."
    New-ProjectMirror -DistroName $DistroName -ProjectName $projName -Remote $remote -User ([string]$rec.user) -Home ([string]$rec.home)

    Write-Host "  creating main/ checkout on '$defaultBranch' ..."
    New-ProjectMainCheckout -DistroName $DistroName -ProjectName $projName -Branch $defaultBranch -User ([string]$rec.user) -Home ([string]$rec.home)

    Add-Recent -State $state -Key 'projectNames' -Value $projName
    Add-Recent -State $state -Key 'remotes'      -Value $remote
    Write-State -DistroName $DistroName -State $state
    Write-Host "Project '$projName' ready." -ForegroundColor Green
    return $projName
}

function Invoke-PickBranch {
    # Returns @{ Branch; IsNew; BaseBranch } or $null if cancelled. For a host
    # session pass -HostCheckout so recent branches are read from the Windows
    # checkout (the distro mirror doesn't exist for the host half).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Project,
        [string]$DefaultBranch = 'master',
        [string]$HostCheckout
    )
    if ($HostCheckout) {
        $recents = Get-HostRecentBranches -HostCheckout $HostCheckout -Limit 5
    }
    else {
        $brState = if (Test-State -DistroName $DistroName) { Read-State -DistroName $DistroName } else { $null }
        $brPu = if ($brState) { Resolve-SessionUserHome -State $brState -Project $Project } else { @{ User = 'claude'; Home = '/home/claude' } }
        $recents = Get-RecentBranches -DistroName $DistroName -Project $Project -Limit 5 -User $brPu.User -Home $brPu.Home
    }
    Write-Host ''
    Write-Host "Branch (project '$Project'):"
    for ($i = 0; $i -lt $recents.Count; $i++) {
        $r = $recents[$i]
        Write-Host ('  {0}) {1,-50} {2}' -f ($i + 1), $r.Branch, "(commit $($r.LastCommit))")
    }
    $base = $recents.Count
    Write-Host "  c) custom branch name (existing)"
    Write-Host "  +) new branch from '$DefaultBranch'"
    Write-Host '  q) cancel'

    while ($true) {
        $a = (Read-Host '  >').Trim()
        if ($a -eq 'q' -or $a -eq '') { return $null }
        if ($a -match '^\d+$') {
            $idx = [int]$a - 1
            if ($idx -ge 0 -and $idx -lt $recents.Count) {
                return @{ Branch = $recents[$idx].Branch; IsNew = $false; BaseBranch = $null }
            }
        }
        if ($a -eq 'c') {
            $b = (Read-Host '  Branch name').Trim()
            if (-not $b) { continue }
            return @{ Branch = $b; IsNew = $false; BaseBranch = $null }
        }
        if ($a -eq '+') {
            $b = (Read-Host '  New branch name').Trim()
            if (-not $b) { continue }
            $entry = (Read-Host "  Base [$DefaultBranch]").Trim()
            $bb = if ([string]::IsNullOrWhiteSpace($entry)) { $DefaultBranch } else { $entry }
            return @{ Branch = $b; IsNew = $true; BaseBranch = $bb }
        }
        Write-Host '  invalid.' -ForegroundColor Yellow
    }
}

function Invoke-NewSessionWizard {
    # Returns the session record (looked up from state) on success, else $null.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)

    $projName = Invoke-PickProject -DistroName $DistroName
    if (-not $projName) { return $null }

    # Read the profile entry for defaults + capability (distro/host halves).
    $defaultBranch = 'master'
    $projTabColor  = ''
    $projEntry     = $null
    $spec          = $null
    try {
        $spec = Read-Profile -Path $Script:ProfilePath
        if ($spec -and $spec.ContainsKey('projects') -and $spec.projects) {
            $projEntry = @($spec.projects | Where-Object { [string]$_.name -eq $projName }) | Select-Object -First 1
            if ($projEntry) {
                if ($projEntry.ContainsKey('defaultBranch') -and $projEntry.defaultBranch) { $defaultBranch = [string]$projEntry.defaultBranch }
                if ($projEntry.ContainsKey('tabColor') -and $projEntry.tabColor) { $projTabColor = [string]$projEntry.tabColor }
            }
        }
    } catch { }

    # Resolve which kind of session to create. A dual-capability project prompts;
    # a single-half project (or a not-in-profile materialized one) is silent.
    $halves = Get-ProjectHalves -ProjectSpec $projEntry
    if ($halves.Distro -and $halves.Host) {
        $choice = (Read-Host "Session type for '$projName'? [distro/host]").Trim().ToLowerInvariant()
        if ($choice -notin @('distro','host')) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return $null }
        $sessType = $choice
    }
    elseif ($halves.Host) { $sessType = 'host' }
    else                  { $sessType = 'distro' }   # distro half, or not in profile
    $hostCheckout = if ($projEntry -and $projEntry.ContainsKey('hostCheckout')) { [string]$projEntry.hostCheckout } else { '' }

    if ($sessType -eq 'host') {
        # Host sessions still use the per-session-worktree flow (branch picker +
        # New-HostSession). Migrating host projects to the curation-main launch
        # pad is tracked separately — see the plan's Stage 6.
        return (Invoke-NewHostSessionWizard -DistroName $DistroName -ProjectName $projName `
                    -ProjectEntry $projEntry -ProfileSpec $spec -DefaultBranch $defaultBranch `
                    -HostCheckout $hostCheckout -ProjectTabColor $projTabColor)
    }

    # ---- distro curation-main flow ----
    # No branch is chosen at creation: the session opens into the project's
    # persistent main/ checkout (the curation branch). Feature work happens in
    # worktrees Claude creates during the session.
    $state = Read-State -DistroName $DistroName
    $pu = Resolve-SessionUserHome -State $state -Project $projName

    # Suggest a fresh, unique session label (the branch is no longer the source).
    # foreach, not `@(... | ForEach-Object)` — Get-Sessions emits the array as
    # one object, so a pipeline mangles it (wsl2-gotchas #25).
    $existing = @()
    foreach ($s in (Get-Sessions -State $state -Project $projName)) { $existing += [string]$s.name }
    $n = $existing.Count + 1
    while ($existing -contains "s$n") { $n++ }
    $suggested = "s$n"
    $entry = (Read-Host "Session name [$suggested]").Trim()
    $sessName = if ([string]::IsNullOrWhiteSpace($entry)) { $suggested } else { $entry }
    if ($sessName -match '[\\/\s.:]') {
        Write-Host "Invalid session name: $sessName (no whitespace, path separators, '.' or ':')" -ForegroundColor Red
        return $null
    }

    $tEntry = (Read-Host "wt tab title [$sessName]").Trim()
    $tabTitle = if ([string]::IsNullOrWhiteSpace($tEntry)) { $sessName } else { $tEntry }

    $colorPrompt = if ($projTabColor) { "wt tab color (project default: $projTabColor)" } else { 'wt tab color' }
    $tabColorChoice = Read-TabColor -Prompt $colorPrompt -Default '<inherit>' -AllowInherit

    Write-Host ''
    Write-Host "  Project:  $projName (distro session)"
    Write-Host "  Opens in: projects/$projName/main  (curation branch '$defaultBranch')"
    Write-Host "  Session:  $sessName"
    Write-Host "  wt title: $tabTitle"
    $colorSummary = switch ($tabColorChoice) {
        '<inherit>' { if ($projTabColor) { "$projTabColor (inherited)" } else { '(none)' } }
        ''          { '(none, overrides project)' }
        default     { $tabColorChoice }
    }
    Write-Host "  wt color: $colorSummary"
    $ok = Read-YesNo -Prompt 'Create session?' -Default $true
    if (-not $ok) { return $null }

    # Ensure the persistent main/ checkout exists before registering the session.
    if (-not (Test-ProjectMainCheckoutExists -DistroName $DistroName -ProjectName $projName -User $pu.User -Home $pu.Home)) {
        Write-Host "  creating main/ checkout on '$defaultBranch' ..."
        New-ProjectMainCheckout -DistroName $DistroName -ProjectName $projName -Branch $defaultBranch -User $pu.User -Home $pu.Home
    }
    Register-Session -State $state -Project $projName -Name $sessName -Type 'distro' | Out-Null
    Set-SessionTabTitle -State $state -Project $projName -Name $sessName -TabTitle $tabTitle
    if ($tabColorChoice -ne '<inherit>') {
        Set-SessionTabColor -State $state -Project $projName -Name $sessName -TabColor $tabColorChoice
    }
    Add-Recent -State $state -Key 'sessionNames' -Value $sessName
    Write-State -DistroName $DistroName -State $state

    return (Get-SessionRow -State $state -Project $projName -Name $sessName)
}

function Invoke-NewHostSessionWizard {
    # Host-session creation, curation-main model: a launch-pad session that opens
    # into the hostCheckout mount (host/main), tmux-wrapped, no branch picker and
    # no per-session worktree — mirroring the distro half. A work-branch worktree
    # is still available via the CLI (`session new -Project x -Name y -Branch z`).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName,
        [AllowNull()][hashtable]$ProjectEntry,
        [AllowNull()][hashtable]$ProfileSpec,
        [string]$DefaultBranch = 'master',
        [string]$HostCheckout,
        [string]$ProjectTabColor
    )
    if (-not $ProjectEntry) {
        Write-Host "Host session needs the project in the profile (hostCheckout)." -ForegroundColor Red
        return $null
    }
    $state = Read-State -DistroName $DistroName
    $pu = Resolve-SessionUserHome -State $state -Project $ProjectName

    $existing = @()
    foreach ($s in (Get-Sessions -State $state -Project $ProjectName)) { $existing += [string]$s.name }
    $n = $existing.Count + 1
    while ($existing -contains "s$n") { $n++ }
    $suggested = "s$n"
    $entry = (Read-Host "Session name [$suggested]").Trim()
    $sessName = if ([string]::IsNullOrWhiteSpace($entry)) { $suggested } else { $entry }
    if ($sessName -match '[\\/\s.:]') {
        Write-Host "Invalid session name: $sessName (no whitespace, path separators, '.' or ':')" -ForegroundColor Red
        return $null
    }

    $tEntry = (Read-Host "wt tab title [$sessName]").Trim()
    $tabTitle = if ([string]::IsNullOrWhiteSpace($tEntry)) { $sessName } else { $tEntry }

    $colorPrompt = if ($ProjectTabColor) { "wt tab color (project default: $ProjectTabColor)" } else { 'wt tab color' }
    $tabColorChoice = Read-TabColor -Prompt $colorPrompt -Default '<inherit>' -AllowInherit

    Write-Host ''
    Write-Host "  Project:  $ProjectName (host session)"
    Write-Host "  Opens in: host/main  (curation checkout '$HostCheckout')"
    Write-Host "  Session:  $sessName"
    Write-Host "  wt title: $tabTitle"
    $colorSummary = switch ($tabColorChoice) {
        '<inherit>' { if ($ProjectTabColor) { "$ProjectTabColor (inherited)" } else { '(none)' } }
        ''          { '(none, overrides project)' }
        default     { $tabColorChoice }
    }
    Write-Host "  wt color: $colorSummary"
    $ok = Read-YesNo -Prompt 'Create session?' -Default $true
    if (-not $ok) { return $null }

    # Cleanup ladder: once the record is registered, a later mount/shadow failure
    # must roll the record back so we don't leave a session with no mount.
    $sessionRegistered = $false
    try {
        Register-Session -State $state -Project $ProjectName -Name $sessName -Type 'host' | Out-Null
        $sessionRegistered = $true
        Set-SessionTabTitle -State $state -Project $ProjectName -Name $sessName -TabTitle $tabTitle
        if ($tabColorChoice -ne '<inherit>') {
            Set-SessionTabColor -State $state -Project $ProjectName -Name $sessName -TabColor $tabColorChoice
        }
        Add-Recent -State $state -Key 'sessionNames' -Value $sessName
        Write-State -DistroName $DistroName -State $state
        $freshState = Read-State -DistroName $DistroName
        Set-HostMountsInDistro -DistroName $DistroName -Mounts (Get-MergedDesiredMounts -ProfileSpec $ProfileSpec -State $freshState)
        Invoke-HostProjectApply -DistroName $DistroName -ProjectSpec $ProjectEntry -User $pu.User -Home $pu.Home
    }
    catch {
        Write-Host "Host session creation failed: $_" -ForegroundColor Red
        if ($sessionRegistered) {
            Write-Host "  rolling back..." -ForegroundColor Yellow
            $state.sessions = @($state.sessions | Where-Object { -not ([string]$_.project -eq $ProjectName -and [string]$_.name -eq $sessName) })
            try { Write-State -DistroName $DistroName -State $state } catch {
                Write-Host "    rollback warn (state): $_" -ForegroundColor DarkYellow
            }
            try {
                $rbState = Read-State -DistroName $DistroName
                Set-HostMountsInDistro -DistroName $DistroName -Mounts (Get-MergedDesiredMounts -ProfileSpec $ProfileSpec -State $rbState)
            } catch {
                Write-Host "    rollback warn (mounts): $_" -ForegroundColor DarkYellow
            }
        }
        return $null
    }

    return (Get-SessionRow -State $state -Project $ProjectName -Name $sessName)
}

# ---------- dashboard ----------

function Show-ProjectWorktrees {
    # Per-project worktree table: the persistent main/ launch pad plus the work
    # worktrees Claude created during sessions (discovered live, never silently
    # abandoned). main/ is labelled and pinned; prunable/gone rows point at the
    # 'prune worktrees' verb.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State
    )
    # foreach over (Get-Sessions ...), not `@(... | ForEach-Object)`: Get-Sessions
    # emits the array as one object (the `,$all` idiom), so a pipeline would run
    # once with $_ = the whole array (wsl2-gotchas #25).
    $projNames = @()
    foreach ($s in (Get-Sessions -State $State)) { $projNames += [string]$s.project }
    $projects = @($projNames | Sort-Object -Unique)
    if ($projects.Count -eq 0) { Write-Host '  (no projects with sessions)' -ForegroundColor DarkGray; return }
    foreach ($proj in $projects) {
        $pu = Resolve-SessionUserHome -State $State -Project $proj
        $wts = @(); foreach ($w in (Get-ProjectWorktrees -DistroName $DistroName -Project $proj -User $pu.User -Home $pu.Home)) { $wts += $w }
        Write-Host ''
        Write-Host "  $proj" -ForegroundColor Cyan
        if ($wts.Count -eq 0) { Write-Host '    (no worktrees — main/ not yet created)' -ForegroundColor DarkGray; continue }
        Write-Host ('    {0,-28} {1,-9} {2,-7} {3}' -f 'Branch','Kind','Dirty','Path')
        foreach ($w in $wts) {
            $kind = if ($w.IsMain) { 'main' }
                    elseif ($w.Prunable) { 'prunable' }
                    elseif ($w.Detached) { 'detached' }
                    else { 'work' }
            $dirtyTxt = if ($w.Dirty -gt 0) { "$($w.Dirty)" } else { '-' }
            $branch = if ($w.Branch) { $w.Branch } else { '(detached)' }
            Write-Host ('    {0,-28} {1,-9} {2,-7} {3}' -f $branch, $kind, $dirtyTxt, $w.Path)
        }
    }
}

function Invoke-Dashboard {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: open ===' -ForegroundColor Cyan
        if (-not (Test-State -DistroName $DistroName)) {
            Write-Host "  No state for distro '$DistroName' — run setup first." -ForegroundColor Yellow
            return
        }
        $state = Read-State -DistroName $DistroName
        # Materialize via foreach (Get-Sessions returns the array through the
        # `,$all` idiom; @()-wrapping it nests the whole array as one element).
        $sessions = @(); foreach ($s in (Get-Sessions -State $state)) { $sessions += $s }
        # Resolve tmux liveness once per render (one `tmux ls` per project user).
        $live = Get-LiveTmuxForState -DistroName $DistroName -State $state
        $liveness = Resolve-SessionLiveness -Sessions $sessions -LiveTmux $live
        $statusByKey = @{}
        foreach ($t in $liveness.Tracked) { $statusByKey["$($t.Project)/$($t.Name)"] = [string]$t.Status }
        $untracked = @($liveness.Untracked)

        if ($sessions.Count -eq 0) {
            Write-Host '  (no sessions)' -ForegroundColor DarkGray
        }
        else {
            Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-10} {4}' -f '#','Project','Session','Status','Last opened')
            Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-10} {4}' -f '---','-------','-------','------','-----------')
            for ($i = 0; $i -lt $sessions.Count; $i++) {
                $s = $sessions[$i]
                $status = $statusByKey["$($s.project)/$($s.name)"]
                if (-not $status) { $status = 'dead' }
                $lo = if ($s.ContainsKey('lastOpenedAt')) { Format-Ago -IsoTimestamp $s.lastOpenedAt } else { '(never)' }
                $color = switch ($status) { 'attached' { 'Green' } 'detached' { 'Cyan' } 'dead' { 'DarkGray' } default { 'Gray' } }
                Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-10} {4}' -f ($i + 1), $s.project, $s.name, $status, $lo) -ForegroundColor $color
            }
        }
        if ($untracked.Count -gt 0) {
            Write-Host ''
            Write-Host '  Untracked tmux sessions (no state record):' -ForegroundColor Yellow
            for ($u = 0; $u -lt $untracked.Count; $u++) {
                $at = if ($untracked[$u].Attached) { 'attached' } else { 'detached' }
                Write-Host ('    u{0}  {1}  ({2})' -f ($u + 1), $untracked[$u].TmuxName, $at)
            }
        }
        Write-Host ''
        Write-Host '  pick a #  open / reattach in wt tab'
        Write-Host '  l         open last-used session'
        Write-Host '  +         new session'
        Write-Host '  n         new project'
        Write-Host '  w         show worktrees per project'
        Write-Host '  d <#>     remove session (kills its tmux session)'
        if ($untracked.Count -gt 0) { Write-Host '  k <u#>    kill an untracked tmux session' }
        Write-Host '  q         quit'

        $a = (Read-Host '  >').Trim()
        if ($a -eq 'q' -or $a -eq '') { return }
        if ($a -eq 'w') {
            Show-ProjectWorktrees -DistroName $DistroName -State $state
            continue
        }
        if ($a -match '^k\s+u?(\d+)$') {
            $ui = [int]$Matches[1] - 1
            if ($ui -lt 0 -or $ui -ge $untracked.Count) { Write-Host '  invalid untracked #' -ForegroundColor Yellow; continue }
            $tn = [string]$untracked[$ui].TmuxName
            $ok = Read-YesNo -Prompt "Kill untracked tmux session '$tn'?" -Default $false
            if ($ok) {
                # The owning user is unknown for an untracked session; kill-session
                # is a no-op on a server that doesn't hold it, so try each user.
                $usersToTry = New-Object System.Collections.Generic.List[string]
                $usersToTry.Add('claude')
                if ($state.ContainsKey('users') -and ($state.users -is [hashtable])) {
                    foreach ($rec in $state.users.Values) {
                        if ($rec -is [hashtable] -and $rec.ContainsKey('user')) {
                            $uu = [string]$rec.user
                            if ($uu -and -not $usersToTry.Contains($uu)) { $usersToTry.Add($uu) }
                        }
                    }
                }
                foreach ($u in $usersToTry) { Stop-TmuxSession -DistroName $DistroName -TmuxName $tn -User $u }
                Write-Host '  killed.' -ForegroundColor Green
            }
            continue
        }
        if ($a -eq 'l') {
            $s = Get-MostRecentSession -State $state
            if ($s) { Open-SessionTab -DistroName $DistroName -SessionRecord $s; return }
            Write-Host '  no recent session.' -ForegroundColor Yellow
            continue
        }
        if ($a -eq '+') {
            $s = Invoke-NewSessionWizard -DistroName $DistroName
            if ($s) { Open-SessionTab -DistroName $DistroName -SessionRecord $s; return }
            continue
        }
        if ($a -eq 'n') {
            [void](Invoke-NewProjectWizard -DistroName $DistroName)
            continue
        }
        if ($a -match '^d\s+(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -lt 0 -or $idx -ge $sessions.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $sToDel = $sessions[$idx]
            $ok = Read-YesNo -Prompt "Remove session '$($sToDel.project)/$($sToDel.name)'?" -Default $false
            if ($ok) {
                $state2 = Read-State -DistroName $DistroName
                # Resolve the project entry so Remove-SessionByName can pick the
                # right teardown path (distro vs host). Profile may be missing
                # in test fixtures; the helper falls back to the session record
                # in that case.
                $spec2 = $null
                $projectEntry = $null
                if (Test-Path -LiteralPath $Script:ProfilePath) {
                    try {
                        $spec2 = Read-Profile -Path $Script:ProfilePath
                        if ($spec2 -and $spec2.ContainsKey('projects') -and $spec2.projects) {
                            $projectEntry = @(@($spec2.projects) | Where-Object { [string]$_.name -eq [string]$sToDel.project })[0]
                        }
                    } catch { }
                }
                try {
                    # Remove-SessionByName kills the session's tmux session (as
                    # its owning user) before dropping the record, so nothing is
                    # stranded. Discard the return-value hashtable so it doesn't
                    # render under the success line on the interactive dashboard.
                    $puDel = Resolve-SessionUserHome -State $state2 -Project ([string]$sToDel.project)
                    $null = Remove-SessionByName -DistroName $DistroName -State $state2 `
                        -Project $sToDel.project -Name $sToDel.name `
                        -ProjectSpec $projectEntry -ProfileSpec $spec2 -Force `
                        -User $puDel.User -Home $puDel.Home
                    Write-State -DistroName $DistroName -State $state2
                    Write-Host "  removed." -ForegroundColor Green
                }
                catch {
                    Write-Host "  failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            continue
        }
        if ($a -match '^\d+$') {
            $idx = [int]$a - 1
            if ($idx -lt 0 -or $idx -ge $sessions.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            Open-SessionTab -DistroName $DistroName -SessionRecord $sessions[$idx] -OverrideTitle $Title
            return
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

# ---------- entry ----------

$distro = Resolve-Distro
if (-not (Test-DistroExists -Name $distro)) {
    Write-Host "Distro '$distro' does not exist. Run: .\claudearium.ps1 setup" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-State -DistroName $distro)) {
    Write-Host "No state for '$distro'. Run: .\claudearium.ps1 setup" -ForegroundColor Yellow
    exit 1
}

if ($Last) {
    $state = Read-State -DistroName $distro
    $s = Get-MostRecentSession -State $state
    if (-not $s) { Write-Host 'No sessions yet — run open-claudearium.ps1 with no flags to use the dashboard.' -ForegroundColor Yellow; exit 1 }
    Open-SessionTab -DistroName $distro -SessionRecord $s -OverrideTitle $Title
    exit 0
}

if ($Project -and $Session) {
    $state = Read-State -DistroName $distro
    $s = Get-SessionRow -State $state -Project $Project -Name $Session
    if (-not $s) {
        Write-Host "Session '$Project/$Session' not found." -ForegroundColor Yellow
        exit 1
    }
    Open-SessionTab -DistroName $distro -SessionRecord $s -OverrideTitle $Title
    exit 0
}

Invoke-Dashboard -DistroName $distro
exit 0
