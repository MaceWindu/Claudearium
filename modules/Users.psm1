# Users.psm1
# Per-project Linux users. The isolation model gives every project its own
# dedicated, password-having Linux user with a 0700 home, so a runaway agent in
# one project session cannot read another project's mirror, sessions, tokens, or
# work. See docs/design-decisions.md on per-project user isolation.
#
# Threat model recap (amends design-decision #3): the in-session agent runs as
# the project user *without* passwordless sudo — sudo is password-required
# (plain `%sudo` group membership, no NOPASSWD drop-in). The generated password
# lives host-side in state.json, which is unreachable from inside the distro
# because automount is disabled (design-decision #4), so the agent cannot read
# it and cannot escalate. All privileged provisioning is done by the orchestrator
# as root via `wsl -u root`; the human retrieves the password (via the `user`
# verb) only for deliberate interactive escalation.
#
# Public surface:
#   Derivation / generation (pure, host-side, unit-testable)
#     ConvertTo-LinuxUserName  -ProjectName <s>          — sanitized `cp-<slug>`
#     New-ProjectUserPassword  [-Length <n>]             — CSPRNG password
#     Resolve-ProjectUserName  -State <h> -ProjectName <s> [-DistroName <s>]
#                                                        — derive + collision-suffix
#     New-ProjectUserRecord    -State <h> -Project <s> [-DistroName <s>]
#                                                        — allocate uid + password,
#                                                          store in state, return record
#   In-distro provisioning (root)
#     New-ProjectUserInDistro    -DistroName -User -Uid -Password
#     Remove-ProjectUserInDistro -DistroName -User       — umount/pkill/userdel -r
#     Copy-ProjectUserCreds      -DistroName -FromUser -ToUser -Dirs
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'State.psm1')

# Linux usernames are stricter than project names (Debian NAME_REGEX is
# `^[a-z_][a-z0-9_-]*$`, 32-char ceiling). Prefix every project user with `cp-`
# (claudearium-project) so enumeration can find them and they never collide with
# system users or the `claude` lobby account. 28 chars leaves headroom for a
# `-NN` collision suffix under the 32-char limit.
$Script:UserNamePrefix    = 'cp-'
$Script:UserNameMaxLength = 28

function ConvertTo-LinuxUserName {
    # Pure: project name -> a valid, prefixed Linux username. Lossy by design
    # (case-folded, punctuation collapsed) — callers must disambiguate collisions
    # via Resolve-ProjectUserName, which is why the state record (not this
    # function) is the authoritative project<->user mapping.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectName)
    $body = $ProjectName.ToLowerInvariant()
    $body = ($body -replace '[^a-z0-9_-]', '-')   # kill '.', spaces, etc.
    $body = ($body -replace '-{2,}', '-')          # collapse runs
    $body = $body.Trim('-')
    $name = "$Script:UserNamePrefix$body"
    if ($name.Length -gt $Script:UserNameMaxLength) {
        $name = $name.Substring(0, $Script:UserNameMaxLength)
    }
    $name = $name.TrimEnd('-')
    # A name that sanitized down to nothing leaves the bare prefix ('cp'); that's
    # a legal username and collision-suffixing keeps multiples distinct.
    if ($name -eq $Script:UserNamePrefix.TrimEnd('-')) { return $name }
    return $name
}

function New-ProjectUserPassword {
    # CSPRNG password from an unambiguous alphabet (no 0/O/1/l/I). ~20 chars over
    # 54 symbols is ~115 bits — ample for a sandbox-escalation secret. A tiny
    # modulo bias is acceptable here (not a key); rejection sampling would be
    # overkill for the threat model.
    [CmdletBinding()]
    param([int]$Length = 20)
    $alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $sb = [System.Text.StringBuilder]::new($Length)
    foreach ($b in $bytes) { [void]$sb.Append($alphabet[$b % $alphabet.Length]) }
    return $sb.ToString()
}

function Resolve-ProjectUserName {
    # Derive a username for a project and disambiguate it against names already
    # in state (and, when -DistroName is given, against live distro users via
    # `id -u`). Returns a free username. With no -DistroName this is pure and
    # deterministic given the state — used by the unit tests.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$DistroName
    )
    $base = ConvertTo-LinuxUserName -ProjectName $ProjectName
    $taken = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@((Get-AllProjectUsers -State $State).Values |
            Where-Object { $_ -is [hashtable] -and $_.ContainsKey('user') } |
            ForEach-Object { [string]$_.user }),
        [System.StringComparer]::OrdinalIgnoreCase)

    $existsInDistro = {
        param($Name)
        if (-not $DistroName) { return $false }
        $q = ConvertTo-BashQuoted $Name
        $r = Invoke-InDistro -Name $DistroName -User 'root' -Command "id -u $q >/dev/null 2>&1" -AllowFail -CaptureOutput
        return ($r.ExitCode -eq 0)
    }

    $candidate = $base
    $suffix = 1
    while ($taken.Contains($candidate) -or (& $existsInDistro $candidate)) {
        $suffix++
        $tag = "-$suffix"
        $trim = $Script:UserNameMaxLength - $tag.Length
        $stem = if ($base.Length -gt $trim) { $base.Substring(0, $trim).TrimEnd('-') } else { $base }
        $candidate = "$stem$tag"
    }
    return $candidate
}

function New-ProjectUserRecord {
    # Idempotently obtain the project's user record: returns the existing record
    # if one is already mapped, otherwise derives a name, allocates a uid (=gid),
    # generates a password, stores the record in $State.users, and returns it.
    # Mutates $State; the caller persists via Write-State.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [string]$DistroName
    )
    $existing = Get-ProjectUser -State $State -Project $Project
    if ($existing) { return $existing }

    $name = Resolve-ProjectUserName -State $State -ProjectName $Project -DistroName $DistroName
    $uid  = New-ProjectUid -State $State
    $record = @{
        user      = $name
        uid       = $uid
        gid       = $uid
        home      = "/home/$name"
        password  = (New-ProjectUserPassword)
        createdAt = (Get-Date).ToString('o')
    }
    Set-ProjectUserRecord -State $State -Project $Project -Record $record
    return $record
}

function New-ProjectUserInDistro {
    # Create (idempotently) the project's Linux user as root: matching primary
    # group so uid==gid, password set via chpasswd stdin (never argv), 0700 home,
    # and `sudo` group membership. Crucially there is NO /etc/sudoers.d drop-in,
    # so the user falls back to Debian's password-required `%sudo` policy.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][int]$Uid,
        [Parameter(Mandatory)][string]$Password
    )
    $qUser = ConvertTo-BashQuoted $User
    $qHome = ConvertTo-BashQuoted "/home/$User"
    $qPw   = ConvertTo-BashQuoted $Password
    # Values are baked as single-quoted literals into a base64-transported body;
    # the password never appears on any argv (Invoke-InDistroScript), and bash
    # `$VAR` references are backtick-escaped so pwsh leaves them intact.
    $script = @"
set -euo pipefail
U=$qUser
UID_N=$Uid
HOME_D=$qHome
PW=$qPw
getent group "`$UID_N" >/dev/null 2>&1 || groupadd -g "`$UID_N" "`$U"
if ! id -u "`$U" >/dev/null 2>&1; then
    useradd -m -d "`$HOME_D" -u "`$UID_N" -g "`$UID_N" -s /bin/bash -G sudo "`$U"
fi
printf '%s:%s' "`$U" "`$PW" | chpasswd
usermod -U "`$U" >/dev/null 2>&1 || true
chmod 0700 "`$HOME_D"
chown "`$U":"`$U" "`$HOME_D"
"@
    Invoke-InDistroScript -Name $DistroName -Script $script -User 'root'
}

function Remove-ProjectUserInDistro {
    # Tear down a project user as root: unmount anything under its home (a live
    # drvfs mount would break `userdel -r`'s rm -rf), kill its processes, then
    # `userdel -r` (force fallback). Returns $true once the user is gone.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$User
    )
    $qUser = ConvertTo-BashQuoted $User
    $qHome = ConvertTo-BashQuoted "/home/$User"
    $script = @"
set -uo pipefail
U=$qUser
HOME_D=$qHome
# Unmount any mounts nested under the home, deepest first.
cut -d' ' -f2 /proc/mounts | grep -F "`$HOME_D/" | sort -r | while read -r mp; do
    umount -l "`$mp" 2>/dev/null || true
done
if id -u "`$U" >/dev/null 2>&1; then
    pkill -KILL -u "`$U" 2>/dev/null || true
    sleep 1
    userdel -r "`$U" 2>/dev/null || userdel -f -r "`$U" 2>/dev/null || true
fi
if id -u "`$U" >/dev/null 2>&1; then echo STILL_EXISTS; else echo GONE; fi
"@
    $r = Invoke-InDistroScript -Name $DistroName -Script $script -User 'root' -AllowFail -CaptureOutput
    return ([bool](@($r.Output) -contains 'GONE'))
}

function Copy-ProjectUserCreds {
    # Seed credentials from one project user's home into another's (root: reads a
    # 0700 source home, chowns into the dest). $Dirs are home-relative paths
    # (e.g. '.config/gh'). Best-effort per dir; missing source dirs are skipped.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$FromUser,
        [Parameter(Mandatory)][string]$ToUser,
        [Parameter(Mandatory)][string[]]$Dirs
    )
    $qFrom = ConvertTo-BashQuoted "/home/$FromUser"
    $qTo   = ConvertTo-BashQuoted "/home/$ToUser"
    $qToU  = ConvertTo-BashQuoted $ToUser
    $relList = (($Dirs | ForEach-Object { ConvertTo-BashQuoted $_ }) -join ' ')
    $script = @"
set -uo pipefail
SRC=$qFrom
DST=$qTo
DST_USER=$qToU
for rel in $relList; do
    if [ -e "`$SRC/`$rel" ]; then
        mkdir -p "`$(dirname "`$DST/`$rel")"
        rm -rf "`$DST/`$rel"
        cp -a "`$SRC/`$rel" "`$DST/`$rel"
        chown -R "`$DST_USER":"`$DST_USER" "`$DST/`$rel"
    fi
done
"@
    Invoke-InDistroScript -Name $DistroName -Script $script -User 'root'
}

Export-ModuleMember -Function `
    ConvertTo-LinuxUserName, `
    New-ProjectUserPassword, `
    Resolve-ProjectUserName, `
    New-ProjectUserRecord, `
    New-ProjectUserInDistro, `
    Remove-ProjectUserInDistro, `
    Copy-ProjectUserCreds
