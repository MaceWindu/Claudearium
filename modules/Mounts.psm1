# Mounts.psm1
# Selective host-path mounts inside the distro via drvfs. Owns a managed block
# in /etc/fstab — entries between `# === claudearium-managed-start ===` and
# `# === claudearium-managed-end ===` markers. Outside that block, fstab is
# user/system owned and never touched.
#
# Public surface:
#   ConvertTo-DrvfsPath    -WindowsPath               — 'C:\foo\bar' -> 'C:/foo/bar'
#   ConvertFrom-DrvfsPath  -DrvfsPath                 — inverse, for display
#   Get-DefaultMountOptions -Mode [-Uid -Gid -Umask]  — 'ro,metadata,uid=1000,...'
#   Get-MountFstabLine     -Mount                     — assemble an fstab line
#   ConvertFrom-FstabLine  -Line                      — parse one back to a record
#   Get-HostMountsActualFromDistro -DistroName        — read the managed block
#   Set-HostMountsInDistro -DistroName -Mounts        — atomic rewrite + umount-removed + mount -a
#   Test-HostPathExists    -Path                       — Test-Path wrapper
#   Resolve-DefaultGuestPath -HostPath                — 'C:\Tools\Foo' -> '/host/foo'
#   Add-MountToProfile / Remove-MountFromProfile      — mutate the on-disk profile
#
# IMPORTANT: the awk that strips the managed block uses regex match
# (`/claudearium-managed-start/ {skip=1; next}`), not `-v var` assignment — the
# latter doesn't survive the pwsh -> wsl argv hop reliably. See
# docs/wsl2-gotchas.md#13.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')
Import-Module (Join-Path $PSScriptRoot 'State.psm1')

$Script:FstabStartMarker = '# === claudearium-managed-start ==='
$Script:FstabEndMarker   = '# === claudearium-managed-end ==='

# The shared account-level Claude store is a Windows host folder mounted into the
# distro (so it survives distro nuke). Host side: %LOCALAPPDATA%\claudearium\.claude
# (global — one folder shared by every distro, a sibling of state\<distro> and
# backups\ so Remove-State never touches it). Guest side: the literal below MUST
# match Get-ClaudeSharedStorePath in ClaudeShared.psm1.
$Script:ClaudeSharedGuestPath = '/opt/claudearium/claude-shared'
function Get-ClaudeSharedHostPath {
    # %LOCALAPPDATA%\claudearium\.claude — the host folder backing the store.
    # $env:CLAUDEARIUM_CLAUDE_SHARED_HOST overrides it: used by the distro tests to
    # point at a throwaway folder (so they don't mount/pollute the developer's real
    # store), and available as a power-user relocation hook.
    [CmdletBinding()] param()
    if ($env:CLAUDEARIUM_CLAUDE_SHARED_HOST) { return $env:CLAUDEARIUM_CLAUDE_SHARED_HOST }
    return (Join-Path (Get-StateRoot) '.claude')
}

function ConvertTo-DrvfsPath {
    # 'C:\Users\foo bar\.ssh' -> 'C:/Users/foo\040bar/.ssh' (drvfs/fstab syntax).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    return ($p -replace ' ', '\040')
}

function ConvertFrom-DrvfsPath {
    # Inverse of ConvertTo-DrvfsPath, for display ("show me what's mounted").
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DrvfsPath)
    $p = $DrvfsPath -replace '\\040', ' '
    return ($p -replace '/', '\')
}

function Get-DefaultMountOptions {
    # Sensible defaults for a drvfs mount. uid/gid default to 1000 (the legacy
    # single-user 'claude' account); under per-project user isolation the owning
    # project user's uid/gid are passed instead so the mount is presented as that
    # user, and umask 077 keeps it unreadable by other project users. Per-mount
    # custom options (e.g. umask=077 for ~/.ssh) are concatenated onto these.
    #
    # -Metadata defaults on (drvfs persists Linux uid/gid/mode in NTFS xattrs so
    # chmod/chown stick). The shared Claude store mount turns it OFF on purpose:
    # with metadata off the mount presents EVERY file with the uniform uid/gid/
    # umask below regardless of which user created it, which is exactly the
    # "any session user can read+write" property the store needs (the group/ACL
    # apparatus that used to provide this can't work on drvfs — see ClaudeShared).
    [CmdletBinding()]
    param(
        [string]$Mode  = 'ro',
        [int]$Uid      = 1000,
        [int]$Gid      = 1000,
        [string]$Umask = '022',
        [bool]$Metadata = $true
    )
    $meta = if ($Metadata) { 'metadata,' } else { '' }
    return "$Mode,${meta}uid=$Uid,gid=$Gid,umask=$Umask"
}

function Get-MountFstabLine {
    # Assemble one fstab line. The $Mount record may carry optional uid/gid/umask
    # keys (stamped by Get-MergedDesiredMounts for per-project-user ownership);
    # absent, they fall back to the legacy 1000/1000/022 defaults.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Mount)
    $hostDrv = ConvertTo-DrvfsPath -WindowsPath ([string]$Mount.host)
    $guest   = ([string]$Mount.guest) -replace ' ', '\040'
    $mode    = if ($Mount.ContainsKey('mode') -and $Mount.mode) { [string]$Mount.mode } else { 'ro' }
    $uid     = if ($Mount.ContainsKey('uid')   -and $null -ne $Mount.uid)   { [int]$Mount.uid }   else { 1000 }
    $gid     = if ($Mount.ContainsKey('gid')   -and $null -ne $Mount.gid)   { [int]$Mount.gid }   else { 1000 }
    $umask   = if ($Mount.ContainsKey('umask') -and $Mount.umask)           { [string]$Mount.umask } else { '022' }
    $meta    = if ($Mount.ContainsKey('metadata') -and $null -ne $Mount.metadata) { [bool]$Mount.metadata } else { $true }
    $opts    = Get-DefaultMountOptions -Mode $mode -Uid $uid -Gid $gid -Umask $umask -Metadata $meta
    if ($Mount.ContainsKey('options') -and $Mount.options) {
        $opts = "$opts,$([string]$Mount.options)"
    }
    return "$hostDrv $guest drvfs $opts 0 0"
}

function ConvertFrom-FstabLine {
    # Parse a managed-block fstab line back into a mount record. Returns $null
    # for comments / blanks / non-drvfs entries.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line)
    $trim = $Line.Trim()
    if ($trim.StartsWith('#') -or [string]::IsNullOrWhiteSpace($trim)) { return $null }
    $parts = $trim -split '\s+'
    if ($parts.Length -lt 4 -or $parts[2] -ne 'drvfs') { return $null }
    $hostP    = ConvertFrom-DrvfsPath -DrvfsPath $parts[0]
    $guest    = $parts[1] -replace '\\040', ' '
    $optsList = ($parts[3] -split ',')
    $mode     = if ($optsList -contains 'rw') { 'rw' } else { 'ro' }
    $userOpts = $optsList | Where-Object {
        $_ -notin @('ro','rw','metadata') -and
        $_ -notmatch '^uid='   -and
        $_ -notmatch '^gid='   -and
        $_ -notmatch '^umask=' -and
        $_ -notmatch '^fmask='
    }
    return @{
        host    = $hostP
        guest   = $guest
        mode    = $mode
        options = if ($userOpts) { $userOpts -join ',' } else { '' }
    }
}

function Get-HostMountsActualFromDistro {
    # Read the managed block out of /etc/fstab and parse each entry.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    # Regex match instead of -v variable: simpler quoting through pwsh -> bash -> awk.
    $cmd = "awk '/claudearium-managed-start/ {flag=1; next} /claudearium-managed-end/ {flag=0} flag' /etc/fstab 2>/dev/null || true"
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command $cmd -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return @() }
    $result = @()
    foreach ($line in $r.Output) {
        if ($null -eq $line) { continue }
        $entry = ConvertFrom-FstabLine -Line ([string]$line)
        if ($entry) { $result += $entry }
    }
    return ,$result
}

function Get-MergedDesiredMounts {
    # The set of mounts the distro's fstab managed block should contain. Two
    # sources:
    #   1. profile.hostMounts          — user-declared shared mounts.
    #   2. state.sessions (hostProject) — mechanical mounts that appear/disappear
    #      with `session new`/`session remove`:
    #        * launch-pad sessions (no per-session worktree) mount the hostCheckout
    #          itself at <home>/host/main (the curation launch pad), deduped;
    #        * legacy per-session work worktrees mount <hostWorktreePath> at
    #          <home>/host/<session>.
    # Callers (project add, session new, session remove, project remove,
    # reconcile) pass the result straight to Set-HostMountsInDistro.
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$ProfileSpec,
        [AllowNull()][hashtable]$State
    )
    $mounts = New-Object System.Collections.Generic.List[hashtable]
    if ($ProfileSpec -and $ProfileSpec.ContainsKey('hostMounts') -and $ProfileSpec.hostMounts) {
        foreach ($m in @($ProfileSpec.hostMounts)) {
            if ($m -is [hashtable]) { $mounts.Add($m) }
        }
    }
    # Project -> user record, for stamping per-project-user ownership on the
    # session mounts. Read directly off the state map (no State.psm1 dependency).
    $users = @{}
    if ($State -and $State.ContainsKey('users') -and ($State.users -is [hashtable])) {
        $users = $State.users
    }
    # Project -> hostCheckout, for the curation launch-pad mount (host sessions
    # that have no per-session worktree open into the hostCheckout itself).
    $hostCheckoutByProject = @{}
    if ($ProfileSpec -and $ProfileSpec.ContainsKey('projects') -and $ProfileSpec.projects) {
        foreach ($p in @($ProfileSpec.projects)) {
            if ($p -is [hashtable] -and $p.ContainsKey('hostCheckout') -and -not [string]::IsNullOrWhiteSpace([string]$p.hostCheckout)) {
                $hostCheckoutByProject[[string]$p.name] = [string]$p.hostCheckout
            }
        }
    }
    $launchPadGuests = @{}   # dedup: parallel launch-pad sessions share one mount
    if ($State -and $State.ContainsKey('sessions') -and $State.sessions) {
        foreach ($s in @($State.sessions)) {
            if (-not ($s -is [hashtable])) { continue }
            if (-not $s.ContainsKey('type'))             { continue }
            if ([string]$s.type -ne 'host')              { continue }
            $proj = [string]$s.project
            # Per-project-user ownership (umask 077 keeps siblings out). Resolve once.
            $rec = if ($users.ContainsKey($proj) -and ($users[$proj] -is [hashtable])) { $users[$proj] } else { $null }
            $home = if ($rec -and $rec.ContainsKey('home') -and $rec.home) { [string]$rec.home } else { '/home/claude' }

            if ($s.ContainsKey('hostWorktreePath') -and $s.ContainsKey('worktreePath')) {
                # Legacy per-session work worktree.
                $m = @{ host = [string]$s.hostWorktreePath; guest = [string]$s.worktreePath; mode = 'rw' }
                if ($rec) {
                    if ($rec.ContainsKey('uid')) { $m.uid = [int]$rec.uid }
                    if ($rec.ContainsKey('gid')) { $m.gid = [int]$rec.gid }
                    $m.umask = '077'
                }
                $mounts.Add($m)
            }
            else {
                # Curation launch-pad host session: mount the hostCheckout itself
                # at <home>/host/main (must match Sessions.Get-HostMainGuestPath).
                # Deduped so N parallel sessions of a project share one mount.
                if (-not $hostCheckoutByProject.ContainsKey($proj)) { continue }
                $guest = "$home/host/main"
                if ($launchPadGuests.ContainsKey($guest)) { continue }
                $launchPadGuests[$guest] = $true
                $m = @{ host = $hostCheckoutByProject[$proj]; guest = $guest; mode = 'rw' }
                if ($rec) {
                    if ($rec.ContainsKey('uid')) { $m.uid = [int]$rec.uid }
                    if ($rec.ContainsKey('gid')) { $m.gid = [int]$rec.gid }
                    $m.umask = '077'
                }
                $mounts.Add($m)
            }
        }
    }
    # 3. The shared account-level Claude store — a tool-owned mount of the global
    #    host folder. Always present so it survives 'mount -a' and managed-block
    #    rewrites. metadata=off + umask=000 makes every file present world-rwx so
    #    any session user (lobby + each cp-*) can read AND write the shared
    #    instructions, without the group/ACL apparatus that drvfs can't support.
    $mounts.Add(@{
        host     = (Get-ClaudeSharedHostPath)
        guest    = $Script:ClaudeSharedGuestPath
        mode     = 'rw'
        uid      = 1000
        gid      = 1000
        umask    = '000'
        metadata = $false
    })
    return ,@($mounts.ToArray())
}

function Set-HostMountsInDistro {
    # Atomically rewrite the managed block, umount entries that were removed,
    # ensure guest directories exist, then 'mount -a' for any new entries.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()]$Mounts
    )
    $mountList = @(); if ($Mounts) { $mountList = @($Mounts) }

    # Find what's mounted today to compute umount set.
    $current = Get-HostMountsActualFromDistro -DistroName $DistroName
    $newByGuest = @{}; foreach ($m in $mountList) { $newByGuest[[string]$m.guest] = $true }
    $toUmount = @()
    foreach ($c in $current) {
        if (-not $newByGuest.ContainsKey([string]$c.guest)) { $toUmount += [string]$c.guest }
    }

    # Build the fresh managed block as a base64 payload (line endings + markers
    # survive intact through wsl interop).
    $lines = @($Script:FstabStartMarker)
    foreach ($m in $mountList) { $lines += Get-MountFstabLine -Mount $m }
    $lines += $Script:FstabEndMarker
    $blockText = ($lines -join "`n") + "`n"
    $blockB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($blockText))

    # Compose umount + mkdir commands.
    $umountSection = ''
    foreach ($g in $toUmount) {
        $qg = ConvertTo-BashQuoted $g
        $umountSection += "sudo umount $qg 2>/dev/null || sudo umount -l $qg 2>/dev/null || true`n"
    }
    $mkdirSection = ''
    foreach ($m in $mountList) {
        $qg = ConvertTo-BashQuoted ([string]$m.guest)
        $mkdirSection += "sudo mkdir -p $qg`n"
    }

    # Regex-based strip rather than -v var assignment — fewer escape surfaces.
    $script = @"
set -e
$umountSection
# Stage in /tmp (owned by 'claude') so we don't need sudo for the writes.
sudo cat /etc/fstab | awk '/claudearium-managed-start/ {skip=1; next} /claudearium-managed-end/ {skip=0; next} !skip' > /tmp/claudearium-fstab.new
printf '%s' '$blockB64' | base64 -d >> /tmp/claudearium-fstab.new
sudo install -m 0644 /tmp/claudearium-fstab.new /etc/fstab
rm -f /tmp/claudearium-fstab.new
$mkdirSection
sudo systemctl daemon-reload || true
sudo mount -a
"@
    # Multi-line script — must go through Invoke-InDistroScript (base64 transport)
    # rather than Invoke-InDistro -Command, per CLAUDE.md "Talking to the distro" /
    # wsl2-gotchas.md #1 (wsl.exe argv mangles $VAR and strips backslashes for
    # multi-line content).
    Invoke-InDistroScript -Name $DistroName -User 'claude' -Script $script
}

function Test-HostPathExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [bool](Test-Path -LiteralPath $Path)
}

function Resolve-DefaultGuestPath {
    # Suggest /host/<basename> as the default guest path for a host folder.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostPath)
    $leaf = Split-Path -Path $HostPath -Leaf
    if (-not $leaf) { return '/host/mount' }
    # Lowercase the leaf for unix conventions; user can override.
    return "/host/$($leaf.ToLowerInvariant())"
}

function Add-MountToProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][hashtable]$MountSpec
    )
    $spec = if (Test-Path $ProfilePath) { Read-Profile -Path $ProfilePath -Raw } else {
        @{
            schemaVersion = 1
            distro        = @{ name = 'claudearium'; base = 'debian-12'; installPath = '%LOCALAPPDATA%\WSL\claudearium' }
        }
    }
    if (-not $spec.ContainsKey('hostMounts') -or -not $spec.hostMounts) { $spec['hostMounts'] = @() }
    $existing = @($spec.hostMounts)
    $guest = [string]$MountSpec.guest
    $kept = @($existing | Where-Object { [string]$_.guest -ne $guest })
    $spec.hostMounts = @($kept) + @($MountSpec)
    Write-Profile -Path $ProfilePath -Spec $spec
}

function Remove-MountFromProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Guest
    )
    if (-not (Test-Path $ProfilePath)) { return $false }
    $spec = Read-Profile -Path $ProfilePath -Raw
    if (-not $spec.ContainsKey('hostMounts') -or -not $spec.hostMounts) { return $false }
    $existing = @($spec.hostMounts)
    $before = $existing.Count
    $spec.hostMounts = @($existing | Where-Object { [string]$_.guest -ne $Guest })
    if (@($spec.hostMounts).Count -eq $before) { return $false }
    Write-Profile -Path $ProfilePath -Spec $spec
    return $true
}

Export-ModuleMember -Function `
    ConvertTo-DrvfsPath, `
    ConvertFrom-DrvfsPath, `
    Get-DefaultMountOptions, `
    Get-MountFstabLine, `
    ConvertFrom-FstabLine, `
    Get-HostMountsActualFromDistro, `
    Get-MergedDesiredMounts, `
    Get-ClaudeSharedHostPath, `
    Set-HostMountsInDistro, `
    Test-HostPathExists, `
    Resolve-DefaultGuestPath, `
    Add-MountToProfile, `
    Remove-MountFromProfile
