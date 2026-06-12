# ClaudeShared.psm1
# The shared, group-writable account-level Claude store. One store per distro at
# /opt/claudearium/claude-shared holds CLAUDE.md + skills/ + agents/ + host-tools/.
# Every session user's ~/.claude/{CLAUDE.md,skills,agents,host-tools} is a SYMLINK
# into the store, so an edit by the agent in one project (a new skill, a memory
# append) is immediately visible to every other project — genuine two-way runtime
# sharing across the otherwise-isolated per-project Linux users.
#
# Why group-writable works under 0700 homes: the store is owned root:claudeshared,
# mode 2775 (setgid on dirs), AND carries a default POSIX ACL
# (`setfacl -d -m g:claudeshared:rwx`). setgid alone is NOT enough — a default
# umask of 022 yields mode-644 (group-readable, not -writable) files; the default
# ACL is what makes agent-created files group-writable. `acl`/`setfacl` is not in
# the base image, so Initialize-ClaudeSharedStore installs it on demand.
#
# settings.json stays per-user (synthesized, see ClaudeSettings.psm1) and is NOT
# symlinked; nor are Claude's per-user mutable dirs (history/ todos/ projects/).
#
# Content is seed-once / import-on-demand, NOT continuously reconciled: reconcile
# manages structure (store + group + ACLs + symlinks) only, never overwriting
# store content from the host (that would clobber in-distro edits). Host import
# happens at setup (seed) and via the explicit `claude-shared import` verb.
#
# Public surface:
#   Get-ClaudeSharedStorePath / Get-ClaudeSharedGroupName  — the constants
#   Get-HostClaudeDirPath -Sub skills|agents               — %USERPROFILE%\.claude\<sub>
#   Initialize-ClaudeSharedStore -DistroName               — group + dirs + setgid + default ACLs (installs acl)
#   Add-UserToSharedGroup     -DistroName -User            — usermod -aG claudeshared
#   Set-ClaudeSharedSymlinks  -DistroName -User -Home      — migrate-once + symlink the four entries
#   Import-ClaudeSharedFromHost -DistroName -Spec [-Force]  — CLAUDE.md (modes) + skills/ + agents/ from host
#   Backup-ClaudeSharedStore  -DistroName -DestPath        — store -> host .tar.gz (bool: did it exist)
#   Restore-ClaudeSharedStore -DistroName -ArchivePath     — host .tar.gz -> store (replace) + re-normalize
#   Test-ClaudeSharedStoreReady -DistroName                — store dir + group + default ACL present?
#   Get-ClaudeSharedSummary   -DistroName                  — { Ready; ClaudeMdBytes; SkillCount; AgentCount; Members }
#   Select-ExpiredBackups     -Files -Retain               — pure: backups beyond the newest N
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'ClaudeFile.psm1')

$Script:SharedStorePath = '/opt/claudearium/claude-shared'
$Script:SharedGroup     = 'claudeshared'

function Get-ClaudeSharedStorePath { [CmdletBinding()] param() return $Script:SharedStorePath }
function Get-ClaudeSharedGroupName { [CmdletBinding()] param() return $Script:SharedGroup }

function Get-HostClaudeDirPath {
    # The host source dir for an importable artifact: %USERPROFILE%\.claude\<sub>.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('skills','agents')][string]$Sub)
    if (-not $env:USERPROFILE) { throw 'USERPROFILE is not set; cannot resolve host ~/.claude.' }
    return (Join-Path $env:USERPROFILE ".claude\$Sub")
}

function Initialize-ClaudeSharedStore {
    # Idempotently create the group + store dirs and apply the ownership/perms/ACL
    # invariants. Safe to re-run; also re-normalizes content written by import or
    # restore (chown -R is safe here — the store holds no symlinks, it's the
    # symlink *target*). Installs `acl` on demand for distros provisioned before
    # it was added to bootstrap.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $store = $Script:SharedStorePath
    $grp   = $Script:SharedGroup
    $script = @"
set -euo pipefail
STORE='$store'
GRP='$grp'
if ! command -v setfacl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq acl
fi
getent group "`$GRP" >/dev/null 2>&1 || groupadd "`$GRP"
mkdir -p "`$STORE/skills" "`$STORE/agents" "`$STORE/host-tools"
chown -R root:"`$GRP" "`$STORE"
# setgid on dirs (group inheritance); regular files just group-rw.
find "`$STORE" -type d -exec chmod 2775 {} +
find "`$STORE" -type f -exec chmod 0664 {} +
# The load-bearing bit: a default ACL so files agents create later are
# group-writable regardless of their umask.
setfacl -R    -m g:"`$GRP":rwx "`$STORE"
setfacl -R -d -m g:"`$GRP":rwx "`$STORE"
"@
    Invoke-InDistroScript -Name $DistroName -Script $script -User 'root'
}

function Add-UserToSharedGroup {
    # Make a session user a member of claudeshared (supplementary group). Takes
    # effect on the user's next login shell — every `wsl -u <user>` is a fresh
    # login, so sessions pick it up immediately.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$User
    )
    $qUser = ConvertTo-BashQuoted $User
    $grp = $Script:SharedGroup
    $cmd = "getent group $grp >/dev/null 2>&1 || groupadd $grp; usermod -aG $grp $qUser"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
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
    $grp   = $Script:SharedGroup
    $qUser = ConvertTo-BashQuoted $User
    $qHome = ConvertTo-BashQuoted $Home
    $script = @"
set -euo pipefail
U=$qUser
H=$qHome
STORE='$store'
GRP='$grp'
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
            if [ ! -s "`$target" ] && [ -s "`$link" ]; then
                cp -a "`$link" "`$target"
                chgrp "`$GRP" "`$target" 2>/dev/null || true
                chmod g+rw "`$target" 2>/dev/null || true
            fi
            rm -f "`$link"
        else
            mkdir -p "`$target"
            cp -an "`$link"/. "`$target"/ 2>/dev/null || true
            chgrp -R "`$GRP" "`$target" 2>/dev/null || true
            chmod -R g+rwX "`$target" 2>/dev/null || true
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
    $grp   = $Script:SharedGroup
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
    printf '%s' '$b64' | base64 -d > "`$MD"
    chown root:$grp "`$MD"
    chmod 0664 "`$MD"
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
    # Structural readiness probe used by reconcile's diff: store dir present, the
    # group exists, and the default ACL is in place. Returns $false if the distro
    # can't be reached.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $store = $Script:SharedStorePath
    $grp   = $Script:SharedGroup
    $qStore = ConvertTo-BashQuoted $store
    $cmd = "if [ -d $qStore ] && getent group $grp >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && getfacl -p $qStore 2>/dev/null | grep -q '^default:group:${grp}:rwx'; then echo READY; else echo NOTREADY; fi"
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return $false }
    return ([bool](@($r.Output | ForEach-Object { [string]$_ }) -contains 'READY'))
}

function Get-ClaudeSharedSummary {
    # Read-only summary for the `claude-shared show` view.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $store = $Script:SharedStorePath
    $grp   = $Script:SharedGroup
    # `set -uo pipefail` WITHOUT -e on purpose: this is a read-only probe and the
    # find/wc/getent pipes are individually allowed to come up empty (a missing
    # skills/ dir, no group members) without aborting the whole summary.
    $script = @"
set -uo pipefail
STORE='$store'
GRP='$grp'
if [ ! -d "`$STORE" ]; then echo 'READY=0'; exit 0; fi
echo "READY=1"
if [ -f "`$STORE/CLAUDE.md" ]; then echo "CLAUDEMD=`$(wc -c < "`$STORE/CLAUDE.md" | tr -d ' ')"; else echo "CLAUDEMD=-1"; fi
echo "SKILLS=`$(find "`$STORE/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
echo "AGENTS=`$(find "`$STORE/agents" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "MEMBERS=`$(getent group "`$GRP" | cut -d: -f4)"
"@
    $r = Invoke-InDistroScript -Name $DistroName -Script $script -User 'root' -AllowFail -CaptureOutput
    $h = @{ Ready = $false; ClaudeMdBytes = -1; SkillCount = 0; AgentCount = 0; Members = '' }
    foreach ($line in @($r.Output | ForEach-Object { [string]$_ })) {
        if     ($line -match '^READY=(\d+)')      { $h.Ready = ($Matches[1] -eq '1') }
        elseif ($line -match '^CLAUDEMD=(-?\d+)') { $h.ClaudeMdBytes = [int]$Matches[1] }
        elseif ($line -match '^SKILLS=(\d+)')     { $h.SkillCount = [int]$Matches[1] }
        elseif ($line -match '^AGENTS=(\d+)')     { $h.AgentCount = [int]$Matches[1] }
        elseif ($line -match '^MEMBERS=(.*)')     { $h.Members = $Matches[1] }
    }
    return $h
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
    Get-ClaudeSharedGroupName, `
    Get-HostClaudeDirPath, `
    Initialize-ClaudeSharedStore, `
    Add-UserToSharedGroup, `
    Set-ClaudeSharedSymlinks, `
    Import-ClaudeSharedFromHost, `
    Backup-ClaudeSharedStore, `
    Restore-ClaudeSharedStore, `
    Test-ClaudeSharedStoreReady, `
    Get-ClaudeSharedSummary, `
    Select-ExpiredBackups
