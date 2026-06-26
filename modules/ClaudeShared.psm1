# ClaudeShared.psm1
# The shared account-level Claude store. It holds CLAUDE.md + skills/ + agents/ +
# host-tools/ and is a WINDOWS HOST FOLDER (%LOCALAPPDATA%\claudearium\.claude,
# global across distros) drvfs-mounted into the distro at /opt/claudearium/
# claude-shared. Because it lives on the host it SURVIVES distro nuke/death — it
# sits outside the per-distro state dir, so Remove-State never touches it.
# Every session user's ~/.claude/{CLAUDE.md,skills,agents,host-tools} is a SYMLINK
# into the mounted store, so an edit by the agent in one project (a new skill, a
# memory append) is immediately visible to every other project — genuine two-way
# runtime sharing across the otherwise-isolated per-project Linux users.
#
# Why every user can read AND write under 0700 homes: the store mount is drvfs
# with metadata OFF + umask=000 (see Mounts.Get-MergedDesiredMounts), so the
# kernel presents EVERY file as world-rwx uniformly regardless of which user
# created it. drvfs does not support POSIX ACLs / setgid / chown (wsl2-gotchas),
# so the old root:claudeshared + setgid 2775 + default-ACL apparatus is gone —
# the mount umask provides the same "shared, writable" property and more simply.
#
# settings.json stays per-user (synthesized, see ClaudeSettings.psm1) and is NOT
# symlinked; nor are Claude's per-user mutable dirs (history/ todos/ projects/).
#
# Content is seed-once / import-on-demand, NOT continuously reconciled: reconcile
# manages structure (mount + dirs + symlinks) only, never overwriting store
# content from the host (that would clobber in-distro edits). Host import happens
# at setup (seed) and via the explicit `claude-shared import` verb.
#
# Public surface:
#   Get-ClaudeSharedStorePath                              — the guest mountpoint constant
#   Get-HostClaudeDirPath -Sub skills|agents               — %USERPROFILE%\.claude\<sub>
#   Initialize-ClaudeSharedStore -DistroName               — ensure the store subdirs exist (on the mount)
#   Set-ClaudeSharedSymlinks  -DistroName -User -Home      — migrate-once + symlink the four entries
#   Import-ClaudeSharedFromHost -DistroName -Spec [-Force]  — CLAUDE.md (modes) + skills/ + agents/ from host
#   Backup-ClaudeSharedStore  -DistroName -DestPath        — store -> host .tar.gz (bool: did it exist)
#   Restore-ClaudeSharedStore -DistroName -ArchivePath     — host .tar.gz -> store (replace)
#   Test-ClaudeSharedStoreReady -DistroName                — store mounted + subdirs present?
#   Get-ClaudeSharedSummary   -DistroName                  — { Ready; ClaudeMdBytes; SkillCount; AgentCount }
#   Get-WorktreeDisciplineBlock                            — pure: the managed CLAUDE.md fragment (curation-main / worktree rules)
#   Edit-ClaudeMdWithDisciplineBlock -Content              — pure: strip-and-replace the discipline block
#   Install-WorktreeDisciplineNote -DistroName             — write/refresh the discipline block in the store CLAUDE.md (once)
#   Get-IsolationModelBlock                                — pure: the managed CLAUDE.md fragment (sandbox-vs-host isolation model)
#   Edit-ClaudeMdWithIsolationBlock -Content               — pure: strip-and-replace the isolation-model block
#   Install-IsolationModelNote -DistroName                 — write/refresh the isolation-model block in the store CLAUDE.md (once)
#   Select-ExpiredBackups     -Files -Retain               — pure: backups beyond the newest N
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'ClaudeFile.psm1')

# Guest mountpoint. MUST match $Script:ClaudeSharedGuestPath in Mounts.psm1, which
# owns the drvfs mount of the host folder onto this path.
$Script:SharedStorePath = '/opt/claudearium/claude-shared'

function Get-ClaudeSharedStorePath { [CmdletBinding()] param() return $Script:SharedStorePath }

function Get-HostClaudeDirPath {
    # The host source dir for an importable artifact: %USERPROFILE%\.claude\<sub>.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('skills','agents')][string]$Sub)
    if (-not $env:USERPROFILE) { throw 'USERPROFILE is not set; cannot resolve host ~/.claude.' }
    return (Join-Path $env:USERPROFILE ".claude\$Sub")
}

function Initialize-ClaudeSharedStore {
    # Idempotently ensure the store's subdirs exist on the mounted folder. The
    # store is a drvfs mount (host folder), so there is no group/ownership/ACL to
    # apply — the mount's umask=000 governs perms uniformly. Safe to re-run.
    # Assumes the mount is already established (callers mount before calling this).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $store = $Script:SharedStorePath
    $script = @"
set -euo pipefail
STORE='$store'
mkdir -p "`$STORE/skills" "`$STORE/agents" "`$STORE/host-tools"
"@
    Invoke-InDistroScript -Name $DistroName -Script $script -User 'root'
}

function Set-ClaudeSharedSymlinks {
    # Point a user's ~/.claude/{CLAUDE.md,skills,agents,host-tools} at the store.
    # Idempotent + migrate-once: a pre-existing REAL file/dir (e.g. an old
    # per-user CLAUDE.md from before the shared model) has its content folded into
    # the store the first time (first non-empty wins for CLAUDE.md — the old
    # per-user copies were byte-identical, so lossless; dirs union via `cp -an`)
    # and is then replaced by the symlink. A correct symlink is left alone; a
    # drifted one is repointed. The store dir targets are mkdir'd first so dir
    # links never dangle.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Home
    )
    $store = $Script:SharedStorePath
    $qUser = ConvertTo-BashQuoted $User
    $qHome = ConvertTo-BashQuoted $Home
    $script = @"
set -euo pipefail
U=$qUser
H=$qHome
STORE='$store'
CD="`$H/.claude"
if [ ! -d "`$CD" ]; then mkdir -p "`$CD"; chown "`$U":"`$U" "`$CD"; chmod 0700 "`$CD"; fi
mkdir -p "`$STORE/skills" "`$STORE/agents" "`$STORE/host-tools"
link_one() {
    nm="`$1"; kind="`$2"
    link="`$CD/`$nm"; target="`$STORE/`$nm"
    if [ -L "`$link" ]; then
        if [ "`$(readlink "`$link")" = "`$target" ]; then return 0; fi
        rm -f "`$link"
    fi
    if [ -e "`$link" ] && [ ! -L "`$link" ]; then
        if [ "`$kind" = "file" ]; then
            # Fold a pre-existing real file into the store once (perms come from
            # the mount umask — no chgrp/chmod needed on a drvfs mount).
            if [ ! -s "`$target" ] && [ -s "`$link" ]; then
                cp -a "`$link" "`$target"
            fi
            rm -f "`$link"
        else
            mkdir -p "`$target"
            cp -an "`$link"/. "`$target"/ 2>/dev/null || true
            rm -rf "`$link"
        fi
    fi
    ln -s "`$target" "`$link"
    chown -h "`$U":"`$U" "`$link"
}
link_one "CLAUDE.md" file
link_one "skills" dir
link_one "agents" dir
link_one "host-tools" dir
"@
    Invoke-InDistroScript -Name $DistroName -Script $script -User 'root'
}

function Import-ClaudeSharedFromHost {
    # Seed/refresh the store from the Windows host: CLAUDE.md (via claudeMd.mode,
    # reusing ClaudeFile's renderer) + skills/ + agents/ trees from
    # %USERPROFILE%\.claude (or claudeShared.skillsPath/agentsPath). Without
    # -Force this is non-destructive: CLAUDE.md is written only if the store copy
    # is absent/empty, and trees merge (no clobber). -Force overwrites. Re-applies
    # the store ownership/ACL invariants afterward.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()][hashtable]$Spec,
        [switch]$Force
    )
    $store = $Script:SharedStorePath
    $cfg = if ($Spec) { $Spec } else { @{} }

    # 1) CLAUDE.md — render per mode, then write to the store.
    $mdSpec = $null
    if ($cfg.ContainsKey('claudeMd') -and $cfg.claudeMd -is [hashtable]) { $mdSpec = $cfg.claudeMd }
    if ($mdSpec -and -not [string]::IsNullOrWhiteSpace([string]$mdSpec.mode) -and ([string]$mdSpec.mode -ne 'skip')) {
        $content = $null
        try { $content = Get-ClaudeFileDesiredContent -Spec $mdSpec }
        catch { Write-Host "  CLAUDE.md import skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($null -ne $content) {
            $qMd = ConvertTo-BashQuoted "$store/CLAUDE.md"
            $payload = $content
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
            $forceFlag = if ($Force) { '1' } else { '0' }
            $script = @"
set -euo pipefail
MD=$qMd
FORCE=$forceFlag
if [ "`$FORCE" = "1" ] || [ ! -s "`$MD" ]; then
    # Perms come from the store mount umask — no chown/chmod on a drvfs mount.
    printf '%s' '$b64' | base64 -d > "`$MD"
fi
"@
            Invoke-InDistroScript -Name $DistroName -Script $script -User 'root'
        }
    }

    # 2) skills/ and agents/ trees.
    $artifacts = @(
        @{ Enable = 'importSkills'; PathKey = 'skillsPath'; Sub = 'skills' },
        @{ Enable = 'importAgents'; PathKey = 'agentsPath'; Sub = 'agents' }
    )
    foreach ($a in $artifacts) {
        $want = $true
        if ($cfg.ContainsKey($a.Enable)) { $want = [bool]$cfg[$a.Enable] }
        if (-not $want) { continue }
        $hostDir = if ($cfg.ContainsKey($a.PathKey) -and $cfg[$a.PathKey]) { [string]$cfg[$a.PathKey] }
                   else { Get-HostClaudeDirPath -Sub $a.Sub }
        if (-not (Test-Path -LiteralPath $hostDir -PathType Container)) { continue }
        $hasFiles = @(Get-ChildItem -LiteralPath $hostDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0
        if (-not $hasFiles) { continue }
        Send-TreeToDistro -DistroName $DistroName -SourceDir $hostDir -DestDir "$store/$($a.Sub)" -Merge:(-not $Force)
    }

    # Re-normalize ownership/perms/ACL over everything just written.
    Initialize-ClaudeSharedStore -DistroName $DistroName
}

function Backup-ClaudeSharedStore {
    # Snapshot the store to a host .tar.gz. Returns $true if the store existed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$DestPath
    )
    return (Receive-TreeFromDistro -DistroName $DistroName -SourceDir $Script:SharedStorePath -DestArchivePath $DestPath)
}

function Restore-ClaudeSharedStore {
    # Replace the store with the contents of a host .tar.gz, then re-normalize.
    # The caller re-runs Set-ClaudeSharedSymlinks afterward so links resolve.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ArchivePath
    )
    Initialize-ClaudeSharedStore -DistroName $DistroName   # ensure store dir + group exist first
    Expand-ArchiveToDistro -DistroName $DistroName -ArchivePath $ArchivePath -DestDir $Script:SharedStorePath -Clean
    Initialize-ClaudeSharedStore -DistroName $DistroName
}

function Test-ClaudeSharedStoreReady {
    # Structural readiness probe used by reconcile's diff: the store is mounted
    # (the host folder is drvfs-mounted at the guest path) and its subdirs exist.
    # Returns $false if the distro can't be reached. `mountpoint -q` is from
    # util-linux (in the Debian base); fall back to grepping /proc/mounts if it's
    # somehow absent.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $store  = $Script:SharedStorePath
    $qStore = ConvertTo-BashQuoted $store
    # Both $qStore and the bare $store below are PowerShell-interpolated at build
    # time (no shell $VAR survives to bash), so this is argv-safe (gotcha #1). The
    # /proc/mounts grep is a fallback for the (unlikely) absence of `mountpoint`.
    $cmd = "if { mountpoint -q $qStore 2>/dev/null || grep -q ' $store ' /proc/mounts; } && [ -d $qStore/skills ] && [ -d $qStore/agents ] && [ -d $qStore/host-tools ]; then echo READY; else echo NOTREADY; fi"
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return $false }
    return ([bool](@($r.Output | ForEach-Object { [string]$_ }) -contains 'READY'))
}

function Get-ClaudeSharedSummary {
    # Read-only summary for the `claude-shared show` view.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $store = $Script:SharedStorePath
    # `set -uo pipefail` WITHOUT -e on purpose: this is a read-only probe and the
    # find/wc pipes are individually allowed to come up empty (a missing skills/
    # dir) without aborting the whole summary.
    $script = @"
set -uo pipefail
STORE='$store'
if [ ! -d "`$STORE" ]; then echo 'READY=0'; exit 0; fi
echo "READY=1"
if [ -f "`$STORE/CLAUDE.md" ]; then echo "CLAUDEMD=`$(wc -c < "`$STORE/CLAUDE.md" | tr -d ' ')"; else echo "CLAUDEMD=-1"; fi
echo "SKILLS=`$(find "`$STORE/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
echo "AGENTS=`$(find "`$STORE/agents" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
"@
    $r = Invoke-InDistroScript -Name $DistroName -Script $script -User 'root' -AllowFail -CaptureOutput
    $h = @{ Ready = $false; ClaudeMdBytes = -1; SkillCount = 0; AgentCount = 0 }
    foreach ($line in @($r.Output | ForEach-Object { [string]$_ })) {
        if     ($line -match '^READY=(\d+)')      { $h.Ready = ($Matches[1] -eq '1') }
        elseif ($line -match '^CLAUDEMD=(-?\d+)') { $h.ClaudeMdBytes = [int]$Matches[1] }
        elseif ($line -match '^SKILLS=(\d+)')     { $h.SkillCount = [int]$Matches[1] }
        elseif ($line -match '^AGENTS=(\d+)')     { $h.AgentCount = [int]$Matches[1] }
    }
    return $h
}

$Script:WtBlockBegin = '<!-- claudearium-worktree-discipline-begin -->'
$Script:WtBlockEnd   = '<!-- claudearium-worktree-discipline-end -->'

function Get-WorktreeDisciplineBlock {
    # The managed CLAUDE.md fragment teaching the curation-main / worktree
    # discipline. Fixed content (LF), bracketed by the markers so it can be
    # strip-and-replaced idempotently without touching the user's own content.
    [CmdletBinding()] param()
    $lines = @(
        $Script:WtBlockBegin
        '## Branches & worktrees (claudearium)'
        ''
        'Your shell starts in `projects/<project>/main` — the project''s persistent'
        '**curation branch** checkout, the launch pad every session opens into.'
        ''
        '- You MAY read and improve the Claude instructions on this branch: commit and'
        '  push instruction updates from `main/`.'
        '- Do NOT `git checkout` / `git switch` to another branch in `main/`, and do NOT'
        '  do feature work here.'
        '- For any feature/bug/other work, create a worktree and work inside it:'
        '  `git worktree add ../worktrees/<branch> -b <branch>` (drop `-b` for an'
        '  existing branch). From `main/` that lands under `projects/<project>/worktrees/`.'
        '- Claudearium tracks worktrees: abandoned ones surface in the session dashboard'
        '  and `prune worktrees`. Remove a finished one with `git worktree remove`.'
        $Script:WtBlockEnd
    )
    return (($lines -join "`n") + "`n")
}

function Edit-ClaudeMdWithDisciplineBlock {
    # Strip any existing discipline block (with bordering blank lines) from
    # Content, then append the current block. Pure + idempotent. Mirrors
    # HostToolNotes.Edit-ClaudeFileWithBlock but with the worktree markers.
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Content)
    $cur = if ($null -eq $Content) { '' } else { $Content }
    $cur = $cur -replace "`r`n", "`n"
    $cur = $cur -replace "`r", "`n"
    $beginPat = [regex]::Escape($Script:WtBlockBegin)
    $endPat   = [regex]::Escape($Script:WtBlockEnd)
    $stripped = [regex]::Replace($cur, "(?ms)\n*$beginPat.*?$endPat\n*", '')
    if (-not $stripped -or -not $stripped.Trim()) { $stripped = '' }
    else { $stripped = $stripped.TrimEnd("`n") + "`n" }
    $block = Get-WorktreeDisciplineBlock
    $sep = if ($stripped) { "`n" } else { '' }
    return ($stripped + $sep + $block)
}

function Install-WorktreeDisciplineNote {
    # Write/refresh the worktree-discipline managed block in the shared store's
    # CLAUDE.md (/opt/claudearium/claude-shared/CLAUDE.md). Written ONCE to the
    # store (every project user symlinks to it), idempotent. Creates the store
    # CLAUDE.md if absent (the discipline applies even when claudeMd.mode = skip).
    # Does not touch content outside the markers.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $qMd = ConvertTo-BashQuoted "$Script:SharedStorePath/CLAUDE.md"
    # Read current content (base64 transport so a trailing newline survives).
    $readR = Invoke-InDistro -Name $DistroName -User 'root' `
        -Command "[ -f $qMd ] && base64 -w0 $qMd && echo || true" -AllowFail -CaptureOutput
    $b64 = (@($readR.Output | ForEach-Object { [string]$_ }) -join '').Trim()
    $current = if ($b64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) } else { '' }
    $new = Edit-ClaudeMdWithDisciplineBlock -Content $current
    if ($new -eq $current) { return }
    $b64Out = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($new))
    # Perms come from the store mount umask — no chown/chmod on a drvfs mount.
    Invoke-InDistro -Name $DistroName -User 'root' -Command "printf '%s' '$b64Out' | base64 -d > $qMd" | Out-Null
}

$Script:IsoBlockBegin = '<!-- claudearium-isolation-model-begin -->'
$Script:IsoBlockEnd   = '<!-- claudearium-isolation-model-end -->'

function Get-IsolationModelBlock {
    # The managed CLAUDE.md fragment giving the agent its isolation mental model:
    # what is sandboxed vs. what reaches the Windows host. Fixed content (LF),
    # bracketed by markers so it can be strip-and-replaced idempotently without
    # touching the user's own content. Mirrors Get-WorktreeDisciplineBlock.
    [CmdletBinding()] param()
    $lines = @(
        $Script:IsoBlockBegin
        '## Where you are running (claudearium)'
        ''
        'You run inside a dedicated **Debian WSL2 distro**, as a non-root project user —'
        'not on the Windows host. Keep this boundary in mind:'
        ''
        '- **Filesystem:** you see the distro''s filesystem and the project clone, not the'
        '  Windows host. There is no general access to the host''s `C:\` or the user''s home.'
        '- **Network:** when the killswitch/VPN is armed, egress is filtered — only the'
        '  tunnel, host LAN services, and the WG peer are reachable; everything else off'
        '  `eth0` is dropped (and recorded — see `vpn audit` on the host). A failed network'
        '  call may be the killswitch, not a bug. Do not try to disable or route around it.'
        '- **Projects are isolated clones.** Most projects are bare-mirror git clones inside'
        '  the distro: git hooks, `direnv`, `mise`, and build scripts run *here*, in the'
        '  sandbox — not on the host. Sync work out via `git push`, never by reaching for'
        '  host files.'
        '- **Host tools are the exception.** For some projects a few named commands (e.g.'
        '  `git`, `pwsh`) are thin shims that execute on the **Windows host** against a host'
        '  checkout. When you run those, repo-supplied git hooks run on the host. Treat'
        '  untrusted repo content accordingly and prefer the in-distro git for routine work.'
        '- **Secrets** live in the distro user''s home; the host holds VPN/auth material you'
        '  cannot read. Don''t attempt to exfiltrate or relocate credentials.'
        $Script:IsoBlockEnd
    )
    return (($lines -join "`n") + "`n")
}

function Edit-ClaudeMdWithIsolationBlock {
    # Strip any existing isolation-model block (with bordering blank lines) from
    # Content, then append the current block. Pure + idempotent. Mirrors
    # Edit-ClaudeMdWithDisciplineBlock but with the isolation markers.
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Content)
    $cur = if ($null -eq $Content) { '' } else { $Content }
    $cur = $cur -replace "`r`n", "`n"
    $cur = $cur -replace "`r", "`n"
    $beginPat = [regex]::Escape($Script:IsoBlockBegin)
    $endPat   = [regex]::Escape($Script:IsoBlockEnd)
    $stripped = [regex]::Replace($cur, "(?ms)\n*$beginPat.*?$endPat\n*", '')
    if (-not $stripped -or -not $stripped.Trim()) { $stripped = '' }
    else { $stripped = $stripped.TrimEnd("`n") + "`n" }
    $block = Get-IsolationModelBlock
    $sep = if ($stripped) { "`n" } else { '' }
    return ($stripped + $sep + $block)
}

function Install-IsolationModelNote {
    # Write/refresh the isolation-model managed block in the shared store's
    # CLAUDE.md (/opt/claudearium/claude-shared/CLAUDE.md). Written ONCE to the
    # store (every project user symlinks to it), idempotent. Creates the store
    # CLAUDE.md if absent. Does not touch content outside the markers. Mirrors
    # Install-WorktreeDisciplineNote.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $qMd = ConvertTo-BashQuoted "$Script:SharedStorePath/CLAUDE.md"
    $readR = Invoke-InDistro -Name $DistroName -User 'root' `
        -Command "[ -f $qMd ] && base64 -w0 $qMd && echo || true" -AllowFail -CaptureOutput
    $b64 = (@($readR.Output | ForEach-Object { [string]$_ }) -join '').Trim()
    $current = if ($b64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) } else { '' }
    $new = Edit-ClaudeMdWithIsolationBlock -Content $current
    if ($new -eq $current) { return }
    $b64Out = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($new))
    Invoke-InDistro -Name $DistroName -User 'root' -Command "printf '%s' '$b64Out' | base64 -d > $qMd" | Out-Null
}

function Select-ExpiredBackups {
    # Pure: given backup file paths named claude-shared-<stamp>.tar.gz (so a
    # lexical sort is chronological), return those beyond the newest -Retain.
    # Retain <= 0 keeps everything.
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$Files,
        [Parameter(Mandatory)][int]$Retain
    )
    # Plain array return (no unary-comma wrap): every caller iterates with foreach
    # or wraps in @(), both of which want the elements unrolled, not a nested array.
    $list = @(@($Files) | Where-Object { $_ })
    if ($Retain -le 0 -or $list.Count -le $Retain) { return @() }
    $sorted = @($list | Sort-Object -Property @{ Expression = { Split-Path -Leaf $_ } } -Descending)
    return @($sorted | Select-Object -Skip $Retain)
}

Export-ModuleMember -Function `
    Get-ClaudeSharedStorePath, `
    Get-HostClaudeDirPath, `
    Initialize-ClaudeSharedStore, `
    Set-ClaudeSharedSymlinks, `
    Import-ClaudeSharedFromHost, `
    Backup-ClaudeSharedStore, `
    Restore-ClaudeSharedStore, `
    Test-ClaudeSharedStoreReady, `
    Get-ClaudeSharedSummary, `
    Get-WorktreeDisciplineBlock, `
    Edit-ClaudeMdWithDisciplineBlock, `
    Install-WorktreeDisciplineNote, `
    Get-IsolationModelBlock, `
    Edit-ClaudeMdWithIsolationBlock, `
    Install-IsolationModelNote, `
    Select-ExpiredBackups
