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

# See claudearium.ps1 for the rationale — MOTW unblock on the install tree.
try {
    Get-ChildItem -LiteralPath $Script:ScriptRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue
} catch { }

Import-Module (Join-Path $Script:ModulesDir 'State.psm1')    -Force
Import-Module (Join-Path $Script:ModulesDir 'UI.psm1')       -Force
Import-Module (Join-Path $Script:ModulesDir 'Wsl.psm1')      -Force
Import-Module (Join-Path $Script:ModulesDir 'Profile.psm1')  -Force
Import-Module (Join-Path $Script:ModulesDir 'Projects.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Sessions.psm1') -Force

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

function Open-SessionTab {
    # Spawn a Windows Terminal tab/window running `claude` inside the session's
    # worktree. Falls back to attaching the current console if wt.exe is missing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$SessionRecord,
        [string]$OverrideTitle
    )
    $worktree = [string]$SessionRecord.worktreePath
    $tabTitle = if ($OverrideTitle) { $OverrideTitle }
                elseif ($SessionRecord.ContainsKey('tabTitle') -and $SessionRecord.tabTitle) { [string]$SessionRecord.tabTitle }
                else { [string]$SessionRecord.name }
    $tabColor = Resolve-EffectiveTabColor -SessionRecord $SessionRecord

    $wt = $null
    if (-not $NoTerminal) { $wt = Get-Command wt.exe -ErrorAction SilentlyContinue }

    # Stamp the open + commit state before launching the (asynchronous) wt window.
    $state = Read-State -DistroName $DistroName
    Update-SessionLastOpened -State $state -Project $SessionRecord.project -Name $SessionRecord.name
    if ($OverrideTitle) { Set-SessionTabTitle -State $state -Project $SessionRecord.project -Name $SessionRecord.name -TabTitle $OverrideTitle }
    Add-Recent -State $state -Key 'tabTitles' -Value $tabTitle
    Write-State -DistroName $DistroName -State $state

    if ($wt) {
        $tabArgs = @()
        if (-not $NewWindow) { $tabArgs += @('-w', '0') }
        $tabArgs += @('nt', '--title', $tabTitle)
        if ($tabColor) { $tabArgs += @('--tabColor', $tabColor) }
        $tabArgs += @(
            '--suppressApplicationTitle',
            '--',
            'wsl.exe',
            '-d', $DistroName,
            '-u', 'claude',
            '--cd', $worktree,
            '--',
            'bash', '-lc', 'claude'
        )
        $where = if ($NewWindow) { 'new wt window' } else { 'new wt tab' }
        $colorBit = if ($tabColor) { ", color: $tabColor" } else { '' }
        Write-Host "Opening '$($SessionRecord.project)/$($SessionRecord.name)' as $where (title: '$tabTitle'$colorBit)" -ForegroundColor Cyan
        Start-Process -FilePath 'wt.exe' -ArgumentList $tabArgs
    }
    else {
        Write-Host "No wt.exe — running 'claude' in this console for $($SessionRecord.project)/$($SessionRecord.name)" -ForegroundColor Cyan
        & wsl.exe -d $DistroName -u 'claude' --cd $worktree -- bash -lc 'claude'
    }
}

# ---------- new-session wizard ----------

function Invoke-PickProject {
    # Returns the project name (existing or freshly-added), or $null if cancelled.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)

    $actual = Get-ProjectsActualFromDistro -DistroName $DistroName
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

    Write-Host "  cloning $remote -> /home/claude/mirrors/$projName.git ..."
    New-ProjectMirror -DistroName $DistroName -ProjectName $projName -Remote $remote

    if (Test-State -DistroName $DistroName) {
        $state = Read-State -DistroName $DistroName
        Add-Recent -State $state -Key 'projectNames' -Value $projName
        Add-Recent -State $state -Key 'remotes'      -Value $remote
        Write-State -DistroName $DistroName -State $state
    }
    Write-Host "Project '$projName' ready." -ForegroundColor Green
    return $projName
}

function Invoke-PickBranch {
    # Returns @{ Branch; IsNew; BaseBranch } or $null if cancelled.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Project,
        [string]$DefaultBranch = 'master'
    )
    $recents = Get-RecentBranches -DistroName $DistroName -Project $Project -Limit 5
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

    # Read the profile's defaultBranch + tabColor for this project, if known.
    $defaultBranch = 'master'
    $projTabColor  = ''
    try {
        $spec = Read-Profile -Path $Script:ProfilePath
        if ($spec -and $spec.ContainsKey('projects') -and $spec.projects) {
            $p = @($spec.projects | Where-Object { [string]$_.name -eq $projName }) | Select-Object -First 1
            if ($p -and $p.ContainsKey('defaultBranch') -and $p.defaultBranch) {
                $defaultBranch = [string]$p.defaultBranch
            }
            if ($p -and $p.ContainsKey('tabColor') -and $p.tabColor) {
                $projTabColor = [string]$p.tabColor
            }
        }
    } catch { }

    $bRes = Invoke-PickBranch -DistroName $DistroName -Project $projName -DefaultBranch $defaultBranch
    if (-not $bRes) { return $null }
    $branch = $bRes.Branch

    $suggested = ConvertTo-SessionNameSuggestion -Branch $branch
    $entry = (Read-Host "Session name [$suggested]").Trim()
    $sessName = if ([string]::IsNullOrWhiteSpace($entry)) { $suggested } else { $entry }
    if ($sessName -match '[\\/\s]') {
        Write-Host "Invalid session name: $sessName" -ForegroundColor Red
        return $null
    }

    $tEntry = (Read-Host "wt tab title [$sessName]").Trim()
    $tabTitle = if ([string]::IsNullOrWhiteSpace($tEntry)) { $sessName } else { $tEntry }

    # Project default: '<inherit>' (Enter) keeps that. User can pick a hex
    # override or 'none' to explicitly drop the project's color for this session.
    $colorPrompt = if ($projTabColor) { "wt tab color (project default: $projTabColor)" } else { 'wt tab color' }
    $tabColorChoice = Read-TabColor -Prompt $colorPrompt -Default '<inherit>' -AllowInherit

    Write-Host ''
    Write-Host "  Project:  $projName"
    Write-Host "  Branch:   $branch$(if ($bRes.IsNew) { " (new, off $($bRes.BaseBranch))" })"
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

    $state = Read-State -DistroName $DistroName
    if ($bRes.IsNew) {
        New-Session -DistroName $DistroName -State $state -Project $projName -Name $sessName -Branch $branch -NewBranch -BaseBranch $bRes.BaseBranch
    }
    else {
        New-Session -DistroName $DistroName -State $state -Project $projName -Name $sessName -Branch $branch
    }
    Set-SessionTabTitle -State $state -Project $projName -Name $sessName -TabTitle $tabTitle
    if ($tabColorChoice -ne '<inherit>') {
        Set-SessionTabColor -State $state -Project $projName -Name $sessName -TabColor $tabColorChoice
    }
    Add-Recent -State $state -Key 'sessionNames' -Value $sessName
    Add-Recent -State $state -Key 'branches'     -Value $branch
    Write-State -DistroName $DistroName -State $state

    return (Get-SessionRow -State $state -Project $projName -Name $sessName)
}

# ---------- dashboard ----------

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
        $sessions = @(Get-Sessions -State $state)
        if ($sessions.Count -eq 0) {
            Write-Host '  (no sessions)' -ForegroundColor DarkGray
        }
        else {
            Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-32} {4,-13} {5}' -f '#','Project','Session','Branch','Last opened','Dirty')
            Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-32} {4,-13} {5}' -f '---','-------','-------','------','-----------','-----')
            for ($i = 0; $i -lt $sessions.Count; $i++) {
                $s = $sessions[$i]
                $dirty = Get-SessionDirtyFileCount -DistroName $DistroName -Project $s.project -Name $s.name
                $dirtyTxt = if ($dirty -gt 0) { "$dirty files" } else { 'clean' }
                $lo = if ($s.ContainsKey('lastOpenedAt')) { Format-Ago -IsoTimestamp $s.lastOpenedAt } else { '(never)' }
                Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-32} {4,-13} {5}' -f ($i + 1), $s.project, $s.name, $s.branch, $lo, $dirtyTxt)
            }
        }
        Write-Host ''
        Write-Host '  pick a #  open in wt tab'
        Write-Host '  l         open last-used session'
        Write-Host '  +         new session'
        Write-Host '  n         new project'
        Write-Host '  d <#>     remove session'
        Write-Host '  q         quit'

        $a = (Read-Host '  >').Trim()
        if ($a -eq 'q' -or $a -eq '') { return }
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
                try {
                    Remove-Session -DistroName $DistroName -State $state2 -Project $sToDel.project -Name $sToDel.name -Force
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
