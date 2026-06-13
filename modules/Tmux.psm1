# Tmux.psm1
# tmux-backed session persistence for Claude Code sessions. In the curation-main
# model a "session" is a named tmux session (cl-<project>-<name>) running
# `claude`, owned by the project's Linux user, rooted at the project's
# persistent main/ checkout. Closing the wt window detaches the tmux client; the
# per-user tmux server keeps the session alive for reattach.
#
# Lifecycle contract: persistence is across wt-window-CLOSE, not across distro
# SHUTDOWN. `wsl --shutdown` / distro stop / host reboot kills the per-user tmux
# server, so every previously-running session then resolves to status 'dead' —
# surfaced in the dashboard, never silently lost (the user's hard requirement).
#
# WSL2 argv safety: the launch command and the list format are pure-ASCII
# literals — the only interpolations are bash-single-quoted (ConvertTo-BashQuoted)
# slugs/paths, and the `#{...}` list format carries no '$' for the pwsh->wsl hop
# to mangle (gotcha #1 / #20).
#
# Public surface:
#   Get-TmuxSessionName     -Project -Name          — 'cl-<project>-<name>', sanitized to [A-Za-z0-9_-]
#   Get-TmuxLaunchCommand   -TmuxName [-InitScript]  — the `bash -lc` body (attach-or-create)
#   ConvertFrom-TmuxLs      -Raw                     — pure parser of `list-sessions -F` output
#   Test-TmuxAvailable      -DistroName              — `command -v tmux`
#   Install-Tmux            -DistroName              — apt-get install tmux (pre-existing distros)
#   Get-TmuxSessions        -DistroName [-User]      — live: @( @{ Name; Attached; Windows } )
#   Stop-TmuxSession        -DistroName -TmuxName [-User] — `tmux kill-session` (best-effort)
#   Resolve-SessionLiveness -Sessions -LiveTmux      — pure cross-join -> @{ Tracked; Untracked }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')

$Script:TmuxSessionPrefix = 'cl-'
# Custom -F format: pipe-delimited and parse-stable (avoids the human
# "N windows (created ...) (attached)" string). session_attached is a client
# count — 0 means detached, >0 attached.
$Script:TmuxListFormat = '#{session_name}|#{session_attached}|#{session_windows}'

function Get-TmuxSessionName {
    # Deterministic, collision-stable tmux session name for a (project, name)
    # pair. tmux treats ':' and '.' specially in target specifiers and
    # `new-session -A` uses the name as a target, so anything outside
    # [A-Za-z0-9_-] is folded to '_' — making the name an unambiguous target
    # regardless of the project/session characters.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Name
    )
    $slug = "$Project-$Name"
    $safe = ($slug -replace '[^A-Za-z0-9_-]', '_')
    return "$Script:TmuxSessionPrefix$safe"
}

function Get-TmuxLaunchCommand {
    # The string handed to `bash -lc` (through wsl.exe) to start OR reattach a
    # session. `new-session -A -s <name> claude` attaches if the session already
    # exists, else creates it — so reopening a session never spawns a duplicate.
    # `exec` replaces the login shell with the tmux client (shallow process
    # tree). For host sessions the per-project init.sh (PATH prepend) is sourced
    # from disk first; its $PATH stays on the bash side (gotcha #1 / #20).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TmuxName,
        [string]$InitScript
    )
    $qName  = ConvertTo-BashQuoted $TmuxName
    $launch = "tmux new-session -A -s $qName claude"
    if ($InitScript) {
        $qInit = ConvertTo-BashQuoted $InitScript
        return "source $qInit; exec $launch"
    }
    return "exec $launch"
}

function ConvertFrom-TmuxLs {
    # Pure parser for `tmux list-sessions -F '<name>|<attached>|<windows>'`
    # output. Skips blank / malformed lines (and any interleaved noise that
    # lacks a '|'). Returns @( @{ Name; Attached(bool); Windows(int) } ).
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Raw)
    $result = @()
    if (-not $Raw) { return ,$result }
    foreach ($line in ($Raw -split "`r?`n")) {
        $s = ([string]$line).Trim()
        if (-not $s) { continue }
        $f = $s -split '\|'
        if ($f.Count -lt 2) { continue }
        $name = $f[0].Trim()
        if (-not $name) { continue }
        $attachedN = if ($f[1].Trim() -match '^\d+$') { [int]$f[1].Trim() } else { 0 }
        $windows   = if ($f.Count -ge 3 -and $f[2].Trim() -match '^\d+$') { [int]$f[2].Trim() } else { 0 }
        $result += @{ Name = $name; Attached = ($attachedN -gt 0); Windows = $windows }
    }
    return ,$result
}

function Test-TmuxAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command 'command -v tmux >/dev/null 2>&1 && echo yes || echo no' -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return $false }
    return [bool]($r.Output | Where-Object { $_ -is [string] -and $_.Trim() -eq 'yes' })
}

function Install-Tmux {
    # On-demand install for distros provisioned before tmux joined the bootstrap
    # package list. No-op if tmux is already present.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    if (Test-TmuxAvailable -DistroName $DistroName) { return }
    $cmd = 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends tmux'
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd | Out-Null
}

function Get-TmuxSessions {
    # Live enumeration of one project user's tmux sessions. tmux servers are
    # per-user (one socket per cp-* home), so this MUST run as the owning user —
    # running as root would not see the user's socket. `list-sessions` exits
    # non-zero with "no server running" when the user has no server; `|| true`
    # normalizes that to an empty, exit-0 result.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [string]$User = 'claude'
    )
    # `timeout 5` so a wedged per-user tmux server (rare, but seen under WSL2
    # systemd) returns an empty list instead of blocking the dashboard forever —
    # 2>/dev/null doesn't help a hang. timeout's 124 exit is normalized by `|| true`.
    $cmd = "timeout 5 tmux list-sessions -F '$Script:TmuxListFormat' 2>/dev/null || true"
    $r = Invoke-InDistro -Name $DistroName -User $User -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return ,@() }
    $raw = (@($r.Output | ForEach-Object { [string]$_ }) -join "`n")
    return (ConvertFrom-TmuxLs -Raw $raw)
}

function Get-LiveTmuxForState {
    # Flatten the live tmux session set across every project user in the state's
    # users map plus the legacy 'claude' lobby. Session names are globally unique
    # (the project name is baked in), so the flat list is enough for
    # Resolve-SessionLiveness. Querying ALL project users — not only those with
    # state records — is what lets untracked sessions surface. Reads $State.users
    # directly (no State.psm1 dependency), mirroring Mounts.Get-MergedDesiredMounts.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State
    )
    $users = New-Object System.Collections.Generic.List[string]
    $users.Add('claude')
    if ($State.ContainsKey('users') -and ($State.users -is [hashtable])) {
        foreach ($rec in $State.users.Values) {
            if ($rec -is [hashtable] -and $rec.ContainsKey('user')) {
                $u = [string]$rec.user
                if ($u -and -not $users.Contains($u)) { $users.Add($u) }
            }
        }
    }
    $all = New-Object System.Collections.Generic.List[hashtable]
    foreach ($u in $users) {
        foreach ($t in (Get-TmuxSessions -DistroName $DistroName -User $u)) {
            if ($t -is [hashtable]) { $all.Add($t) }
        }
    }
    return ,$all.ToArray()
}

function Stop-TmuxSession {
    # Best-effort `tmux kill-session`. Idempotent: a missing session / no server
    # is normalized to success so callers can use it during teardown without
    # guarding existence first.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$TmuxName,
        [string]$User = 'claude'
    )
    $q = ConvertTo-BashQuoted $TmuxName
    Invoke-InDistro -Name $DistroName -User $User -Command "tmux kill-session -t $q 2>/dev/null || true" -AllowFail | Out-Null
}

function Resolve-SessionLiveness {
    # Pure cross-join of tracked sessions (state.json) against the live tmux set
    # (flattened across all project users — names are globally unique because the
    # project name is baked into them). This is what makes persistence non-silent:
    # every tracked session is classified, and every stray cl-* tmux session is
    # surfaced as untracked.
    #
    # Returns @{
    #   Tracked   = @( @{ Project; Name; TmuxName; Status } )   # attached | detached | dead
    #   Untracked = @( @{ TmuxName; Attached } )                # cl-* with no state record
    # }
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$LiveTmux
    )
    # Get-Sessions / Get-LiveTmuxForState return $null (not @()) when empty —
    # normalize so the cross-join is uniform.
    if ($null -eq $Sessions) { $Sessions = @() }
    if ($null -eq $LiveTmux) { $LiveTmux = @() }
    $byName = @{}
    foreach ($t in $LiveTmux) {
        if ($t -is [hashtable] -and $t.ContainsKey('Name')) { $byName[[string]$t.Name] = $t }
    }
    $tracked    = New-Object System.Collections.Generic.List[hashtable]
    $claimed    = @{}
    foreach ($s in $Sessions) {
        if (-not ($s -is [hashtable])) { continue }
        $proj = [string]$s.project
        $name = [string]$s.name
        $tmuxName = if ($s.ContainsKey('tmux') -and $s.tmux) { [string]$s.tmux } else { Get-TmuxSessionName -Project $proj -Name $name }
        $status = 'dead'
        if ($byName.ContainsKey($tmuxName)) {
            $claimed[$tmuxName] = $true
            $status = if ($byName[$tmuxName].Attached) { 'attached' } else { 'detached' }
        }
        $tracked.Add(@{ Project = $proj; Name = $name; TmuxName = $tmuxName; Status = $status })
    }
    $untracked = New-Object System.Collections.Generic.List[hashtable]
    foreach ($t in $LiveTmux) {
        if (-not ($t -is [hashtable]) -or -not $t.ContainsKey('Name')) { continue }
        $n = [string]$t.Name
        if ($claimed.ContainsKey($n)) { continue }
        if ($n -notmatch '^cl-') { continue }
        $untracked.Add(@{ TmuxName = $n; Attached = [bool]$t.Attached })
    }
    return @{ Tracked = $tracked.ToArray(); Untracked = $untracked.ToArray() }
}

Export-ModuleMember -Function `
    Get-TmuxSessionName, `
    Get-TmuxLaunchCommand, `
    ConvertFrom-TmuxLs, `
    Test-TmuxAvailable, `
    Install-Tmux, `
    Get-TmuxSessions, `
    Get-LiveTmuxForState, `
    Stop-TmuxSession, `
    Resolve-SessionLiveness
