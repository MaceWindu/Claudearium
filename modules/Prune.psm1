# Prune.psm1
# Drift detection between state.json / profile.json / the distro filesystem.
# Each Find-* function reports what *exists* but *shouldn't* (or vice-versa);
# the verb's repair half lives in claudearium.ps1 and uses the existing
# Remove-/Invoke-MergedMountsApply primitives.
#
# Scopes:
#   sessions    — state.sessions records whose worktree no longer exists
#                 (either side); repair = drop the record.
#   worktrees   — bare-mirror or host-checkout `git worktree list` entries
#                 whose worktree dir is gone; repair = `git worktree prune`.
#   mounts      — fstab managed-block entries with no matching `type:'host'`
#                 session in state; repair = Invoke-MergedMountsApply.
#   artifacts   — heavy untracked dirs (node_modules / target / .next / dist /
#                 build / out / obj / bin) inside live session worktrees;
#                 repair = `rm -rf` (per dir, prompted).
#
# Public surface:
#   Find-OrphanedSessions   -State -DistroName                 — @( @{ Project; Name; Type; WorktreePath; HostWorktreePath } )
#   Find-StaleWorktrees     -DistroName -ProfileSpec           — @( @{ Location; Worktree; Side } )
#   Find-DanglingMounts     -DistroName -State -ProfileSpec    — @( @{ Guest; Host } ) — actual fstab minus merged-desired
#   Find-HeavyArtifacts     -DistroName -State                 — @( @{ Project; Session; Type; Path; ArtifactDir; Bytes } )
#   Format-Bytes            -Bytes                             — '1.2G' / '450M' / etc.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Sessions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Mounts.psm1')

# Single source of truth for which untracked subdirectories count as "build
# artifacts" worth surfacing. The verb prompts per-dir, but having them all
# here keeps the test fixture and the docs in sync.
$Script:KnownArtifactDirs = @('node_modules', 'target', '.next', 'dist', 'build', 'out', 'obj', 'bin')

function Format-Bytes {
    # Human-readable size. SI-style suffixes (G/M/K) at one decimal place.
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -lt 1024)      { return "$Bytes B" }
    if ($Bytes -lt 1MB)       { return ('{0:N1}K' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB)       { return ('{0:N1}M' -f ($Bytes / 1MB)) }
    return ('{0:N1}G' -f ($Bytes / 1GB))
}

function Find-OrphanedSessions {
    # state.sessions records whose worktree directory has vanished. For distro
    # sessions, that's a `test -d /home/claude/projects/<p>/sessions/<s>` in
    # the distro; for host sessions, Test-Path on hostWorktreePath (Windows
    # side). Either lookup can fail benignly (distro stopped, host path
    # mounted on a network drive that's currently offline) — we treat
    # failures as "exists" so we don't drop records we couldn't verify.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$DistroName
    )
    $orphans = New-Object System.Collections.Generic.List[hashtable]
    foreach ($s in (Get-Sessions -State $State)) {
        if (-not ($s -is [hashtable])) { continue }
        $type = Get-SessionType -Session $s
        $proj = [string]$s.project
        $name = [string]$s.name
        $missing = $false

        if ($type -eq 'host') {
            $hostWt = if ($s.ContainsKey('hostWorktreePath')) { [string]$s.hostWorktreePath } else { $null }
            if ($hostWt -and -not (Test-Path -LiteralPath $hostWt -PathType Container)) { $missing = $true }
        }
        else {
            $wt = if ($s.ContainsKey('worktreePath')) { [string]$s.worktreePath } else { $null }
            if ($wt) {
                $q = ConvertTo-BashQuoted $wt
                $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command "test -d $q && echo present || echo gone" -AllowFail -CaptureOutput
                if ($r.ExitCode -eq 0) {
                    $verdict = (($r.Output | Where-Object { $_ -is [string] -and ($_.Trim() -in @('present', 'gone')) } | Select-Object -Last 1) -as [string])
                    if ($verdict -and $verdict.Trim() -eq 'gone') { $missing = $true }
                }
            }
        }

        if ($missing) {
            $orphans.Add(@{
                Project          = $proj
                Name             = $name
                Type             = $type
                WorktreePath     = if ($s.ContainsKey('worktreePath')) { [string]$s.worktreePath } else { '' }
                HostWorktreePath = if ($s.ContainsKey('hostWorktreePath')) { [string]$s.hostWorktreePath } else { '' }
            })
        }
    }
    # Always return a plain enumerable: PowerShell unwraps a single-element
    # array at the call site, but callers wrap with `@(...)` to re-array-ify
    # — `,@(array)` from here would survive that wrap by getting nested,
    # which breaks the foreach iteration on the outer.
    return $orphans.ToArray()
}

function Find-StaleWorktrees {
    # For each project, parse `git worktree list --porcelain` and report any
    # entries whose `worktree <path>` line points at a directory that no
    # longer exists. distroProjects: run against /home/claude/mirrors/<p>.git
    # inside the distro. hostProjects: run against hostCheckout on Windows
    # side. Both git invocations also surface `prunable` markers (worktrees
    # git itself already knows are stale) — those count regardless of whether
    # the dir is still on disk.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()][hashtable]$ProfileSpec
    )
    $result = New-Object System.Collections.Generic.List[hashtable]

    # ---- distroProjects (mirrors inside the distro) ----
    # Enumerate mirrors via the filesystem rather than the profile so we also
    # catch projects that were removed from the profile but whose mirrors
    # were edited manually (the same drift that motivates this verb).
    $listCmd = '[ -d /home/claude/mirrors ] && find /home/claude/mirrors -maxdepth 1 -name "*.git" -type d -printf "%f\n" || true'
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command $listCmd -AllowFail -CaptureOutput
    $mirrorNames = @()
    if ($r.ExitCode -eq 0) {
        $mirrorNames = @($r.Output |
            Where-Object { $_ -is [string] -and ($_.Trim() -match '^[^\\/\s]+\.git$') } |
            ForEach-Object { $_.Trim() -replace '\.git$', '' })
    }
    foreach ($projName in $mirrorNames) {
        $qPath = ConvertTo-BashQuoted "/home/claude/mirrors/$projName.git"
        $wtCmd = "git -C $qPath worktree list --porcelain 2>/dev/null || true"
        $wtR   = Invoke-InDistro -Name $DistroName -User 'claude' -Command $wtCmd -AllowFail -CaptureOutput
        if ($wtR.ExitCode -ne 0) { continue }
        $current = $null; $isPrunable = $false
        foreach ($line in @($wtR.Output)) {
            $s = [string]$line
            if ($s -match '^worktree\s+(.+)$') {
                # New record begins — flush the previous one first.
                if ($current) {
                    $exists = $true
                    $qWt = ConvertTo-BashQuoted $current
                    $exR = Invoke-InDistro -Name $DistroName -User 'claude' -Command "test -d $qWt && echo present || echo gone" -AllowFail -CaptureOutput
                    if ($exR.ExitCode -eq 0) {
                        $verdict = (($exR.Output | Where-Object { $_ -is [string] -and ($_.Trim() -in @('present','gone')) } | Select-Object -Last 1) -as [string])
                        if ($verdict -and $verdict.Trim() -eq 'gone') { $exists = $false }
                    }
                    if (-not $exists -or $isPrunable) {
                        $result.Add(@{
                            Side     = 'distro'
                            Location = "/home/claude/mirrors/$projName.git"
                            Worktree = $current
                            Reason   = if (-not $exists) { 'worktree-gone' } else { 'prunable' }
                        })
                    }
                }
                $current = $Matches[1].Trim()
                $isPrunable = $false
            }
            elseif ($s -match '^prunable\s') { $isPrunable = $true }
        }
        # flush last record
        if ($current) {
            $exists = $true
            $qWt = ConvertTo-BashQuoted $current
            $exR = Invoke-InDistro -Name $DistroName -User 'claude' -Command "test -d $qWt && echo present || echo gone" -AllowFail -CaptureOutput
            if ($exR.ExitCode -eq 0) {
                $verdict = (($exR.Output | Where-Object { $_ -is [string] -and ($_.Trim() -in @('present','gone')) } | Select-Object -Last 1) -as [string])
                if ($verdict -and $verdict.Trim() -eq 'gone') { $exists = $false }
            }
            # Bare mirrors include themselves as a "worktree" entry (the
            # mirror path itself); that entry obviously exists, so the
            # presence check above filters it out. We only emit non-existent
            # or git-flagged-prunable.
            if (-not $exists -or $isPrunable) {
                $result.Add(@{
                    Side     = 'distro'
                    Location = "/home/claude/mirrors/$projName.git"
                    Worktree = $current
                    Reason   = if (-not $exists) { 'worktree-gone' } else { 'prunable' }
                })
            }
        }
    }

    # ---- hostProjects (checkouts on the Windows side) ----
    if ($ProfileSpec -and $ProfileSpec.ContainsKey('projects')) {
        foreach ($p in @($ProfileSpec.projects)) {
            if (-not ($p -is [hashtable])) { continue }
            $ptype = 'distro'
            if ($p.ContainsKey('type') -and $p.type) { $ptype = [string]$p.type }
            if ($ptype -ne 'host') { continue }
            $hc = [string]$p.hostCheckout
            if (-not $hc -or -not (Test-Path -LiteralPath $hc -PathType Container)) { continue }
            $out = $null
            try {
                $out = & git -C $hc worktree list --porcelain 2>$null
            } catch {}
            if ($LASTEXITCODE -ne 0 -or -not $out) { continue }

            # `git worktree list --porcelain` emits one record per worktree,
            # records separated by a blank line, starting with `worktree <path>`
            # then optional fields including `prunable <reason>`. We accumulate
            # the current record as we walk lines and emit on each new
            # `worktree` header (and once at end-of-loop for the trailing
            # record). The emit-helper returns the entry directly via pipeline
            # rather than via a $script:-scope variable — sideband variables
            # silently leak state across iterations (gotcha-style).
            $processed = {
                param($wt, $prunable, $location)
                if (-not $wt) { return $null }
                $exists = Test-Path -LiteralPath $wt -PathType Container
                if (-not $exists -or $prunable) {
                    return @{
                        Side     = 'host'
                        Location = $location
                        Worktree = $wt
                        Reason   = if (-not $exists) { 'worktree-gone' } else { 'prunable' }
                    }
                }
                return $null
            }
            $current = $null; $isPrunable = $false
            foreach ($line in @($out)) {
                $s = [string]$line
                if ($s -match '^worktree\s+(.+)$') {
                    $entry = & $processed $current $isPrunable $hc
                    if ($entry) { $result.Add($entry) }
                    $current = $Matches[1].Trim()
                    $isPrunable = $false
                }
                elseif ($s -match '^prunable\s') { $isPrunable = $true }
            }
            $entry = & $processed $current $isPrunable $hc
            if ($entry) { $result.Add($entry) }
        }
    }

    return $result.ToArray()
}

function Find-DanglingMounts {
    # fstab managed-block entries whose guest path is not in the merged
    # desired set (profile.hostMounts ∪ state.sessions for host projects).
    # Repair is Invoke-MergedMountsApply, which rewrites the block from the
    # desired set unconditionally.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()][hashtable]$ProfileSpec
    )
    $actual  = Get-HostMountsActualFromDistro -DistroName $DistroName
    $desired = Get-MergedDesiredMounts -ProfileSpec $ProfileSpec -State $State
    $desiredByGuest = @{}
    foreach ($m in @($desired)) { if ($m) { $desiredByGuest[[string]$m.guest] = $true } }
    $dangling = New-Object System.Collections.Generic.List[hashtable]
    foreach ($a in @($actual)) {
        if (-not $a) { continue }
        $g = [string]$a.guest
        if (-not $desiredByGuest.ContainsKey($g)) {
            $dangling.Add(@{ Guest = $g; Host = [string]$a.host })
        }
    }
    return $dangling.ToArray()
}

function Find-HeavyArtifacts {
    # Inspect each live session's worktree for the known build-output dirs
    # and report their sizes. Distro sessions: `du -sb` (bytes) inside the
    # distro. Host sessions: PowerShell directory walk on Windows side.
    # Both can be slow for large trees — callers should set expectations.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State
    )
    $result = New-Object System.Collections.Generic.List[hashtable]
    foreach ($s in (Get-Sessions -State $State)) {
        if (-not ($s -is [hashtable])) { continue }
        $type    = Get-SessionType -Session $s
        $project = [string]$s.project
        $name    = [string]$s.name
        if ($type -eq 'host') {
            $hostWt = if ($s.ContainsKey('hostWorktreePath')) { [string]$s.hostWorktreePath } else { '' }
            if (-not $hostWt -or -not (Test-Path -LiteralPath $hostWt -PathType Container)) { continue }
            foreach ($dirName in $Script:KnownArtifactDirs) {
                $candidate = Join-Path $hostWt $dirName
                if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
                # Recursive size on Windows. Slow on giant node_modules trees
                # (multi-second), but accurate and offline.
                $bytes = 0L
                try {
                    $sum = Get-ChildItem -LiteralPath $candidate -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum
                    if ($sum -and $sum.Sum) { $bytes = [long]$sum.Sum }
                } catch {}
                $result.Add(@{
                    Project     = $project
                    Session     = $name
                    Type        = 'host'
                    Path        = $hostWt
                    ArtifactDir = $dirName
                    Bytes       = $bytes
                })
            }
        }
        else {
            $wt = Get-SessionWorktreePath -Project $project -Name $name
            # Single `du -sb` per candidate. Probe existence first so missing
            # dirs don't produce noise on stderr.
            foreach ($dirName in $Script:KnownArtifactDirs) {
                # Plain string concat — Linux paths use '/'; Join-Path would
                # emit '\' on a Windows host and break the in-distro shell.
                $qDir = ConvertTo-BashQuoted "$wt/$dirName"
                # `cut -f1` keeps just the byte count from `du -sb`'s two-column
                # output. Plain pipe + cut sidesteps the variable-mangling
                # concerns in gotchas #1 and #13 — no shell vars in flight.
                $cmd = "[ -d $qDir ] && du -sb $qDir 2>/dev/null | cut -f1 || echo absent"
                $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd -AllowFail -CaptureOutput
                if ($r.ExitCode -ne 0) { continue }
                $line = $r.Output | Where-Object { $_ -is [string] -and ($_.Trim() -match '^\d+$' -or $_.Trim() -eq 'absent') } | Select-Object -Last 1
                if (-not $line) { continue }
                $t = ([string]$line).Trim()
                if ($t -eq 'absent') { continue }
                $bytes = [long]$t
                $result.Add(@{
                    Project     = $project
                    Session     = $name
                    Type        = 'distro'
                    Path        = $wt
                    ArtifactDir = $dirName
                    Bytes       = $bytes
                })
            }
        }
    }
    return $result.ToArray()
}

Export-ModuleMember -Function `
    Format-Bytes, `
    Find-OrphanedSessions, `
    Find-StaleWorktrees, `
    Find-DanglingMounts, `
    Find-HeavyArtifacts
