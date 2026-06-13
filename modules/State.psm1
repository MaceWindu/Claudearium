# State.psm1
# Per-distro state-file management at %LOCALAPPDATA%\claudearium\<distro>\state.json.
#
# State is the *actual* side of the profile-vs-state model (see
# docs/architecture.md). The user doesn't edit it directly — the tool owns it
# and uses it to track what has actually been provisioned, plus ephemeral
# metadata (sessions, recents, last-opened timestamps) that doesn't belong in
# the declarative profile.
#
# Public surface:
#   Get-StateRoot                                   — root dir under LOCALAPPDATA
#   Get-BackupRoot                                  — backups root (sibling of per-distro state dirs)
#   Get-BackupDir        -DistroName <s>            — per-distro backup dir (survives Remove-State)
#   Get-StatePath        -DistroName <s>            — full path to state.json
#   Test-State           -DistroName <s>            — does state exist?
#   Read-State           -DistroName <s>            — parse JSON -> hashtable (decrypts secrets)
#   Write-State          -DistroName <s> -State <h> — atomic .tmp-then-Move (encrypts secrets at rest)
#   Protect-StateSecret   -Plain <s>                — DPAPI (CurrentUser) -> 'dpapi:v1:<b64>', idempotent
#   Unprotect-StateSecret -Stored <s>              — inverse; passes legacy plaintext through
#   Initialize-State     -DistroName <s>            — fresh state shape
#   Remove-State         -DistroName <s>            — purge state dir
#   Add-Recent           -State <h> -Key <s> -Value <s> [-Max <n>]
#                                                   — dedup most-recent-wins, trim
#   Per-project-user records (the project<->Linux-user mapping; see
#   docs/design-decisions.md on per-project user isolation)
#     Get-ProjectUser        -State <h> -Project <s>           — record or $null
#     Set-ProjectUserRecord  -State <h> -Project <s> -Record <h>
#     Remove-ProjectUserRecord -State <h> -Project <s>         — drop mapping, bool
#     Get-AllProjectUsers    -State <h>                        — the users map (or @{})
#     New-ProjectUid         -State <h>                        — allocate + bump uidAllocator.next
#
# Schema invariants: schemaVersion is set on every Write-State; createdAt is
# set once at Initialize-State, updatedAt is bumped on every write. Schema v2
# adds `users` (project name -> { user; uid; gid; home; password (DPAPI-encrypted
# at rest as 'dpapi:v1:<b64>', transparently decrypted by Read-State); createdAt;
# and an optional `seededFrom`, present only after credential seeding — read it
# via ContainsKey, never assume it exists}) and `uidAllocator.next` (monotonic
# uid cursor starting at 30000).
# A state file still carrying schemaVersion 1 with provisioned=true marks the
# pre-isolation single-`claude`-user layout — the migration detector keys on it.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:StateSchemaVersion = 2

# Marker prefix on DPAPI-protected secret values in state.json. Read-State
# transparently decrypts these back to plaintext; Write-State encrypts plaintext
# secrets on the way out. A value lacking the prefix is treated as legacy
# plaintext (and gets encrypted on the next write).
$Script:SecretPrefix  = 'dpapi:v1:'
# App-scoped DPAPI entropy: decryption needs both the current Windows user's
# DPAPI key AND this constant, so a state.json copied to another account is
# undecryptable even there.
$Script:SecretEntropy = [System.Text.Encoding]::UTF8.GetBytes('claudearium-state-secret-v1')

# First uid handed to a project user. 30000 is clear of `claude` (uid 1000) and
# of Debian's default human-user range, and well under UID_MAX (60000). The
# allocator is monotonic and never reuses a uid even after a project is removed
# (avoids drvfs uid=/gid= ownership aliasing on a recycled number).
$Script:FirstProjectUid = 30000

function Get-StateRoot {
    [CmdletBinding()]
    param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve state root.' }
    return (Join-Path $env:LOCALAPPDATA 'claudearium')
}

function Get-StatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    return (Join-Path (Join-Path (Get-StateRoot) $DistroName) 'state.json')
}

function Get-BackupRoot {
    # Root for host-side backups, a *sibling* of the per-distro state dirs under
    # the state root: %LOCALAPPDATA%\claudearium\backups. Kept out of
    # %LOCALAPPDATA%\claudearium\<distro> on purpose so Remove-State (which wipes
    # that per-distro dir on nuke) leaves backups intact.
    [CmdletBinding()]
    param()
    return (Join-Path (Get-StateRoot) 'backups')
}

function Get-BackupDir {
    # Per-distro backup directory: %LOCALAPPDATA%\claudearium\backups\<distro>.
    # A distro literally named 'backups' would alias the backup root against its
    # own state dir — refuse it rather than silently tangle the two namespaces.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    if ($DistroName -eq 'backups') {
        throw "Distro name 'backups' collides with the backup root; rename the distro."
    }
    return (Join-Path (Get-BackupRoot) $DistroName)
}

function Test-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    return (Test-Path (Get-StatePath -DistroName $DistroName))
}

function Protect-StateSecret {
    # DPAPI-encrypt a plaintext secret to the marker form 'dpapi:v1:<base64>'.
    # Scope = CurrentUser so only the Windows account that wrote state.json can
    # read it back. Already-protected values pass through unchanged (idempotent).
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return $Plain }
    if ($Plain.StartsWith($Script:SecretPrefix)) { return $Plain }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $Script:SecretEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return $Script:SecretPrefix + [Convert]::ToBase64String($enc)
}

function Unprotect-StateSecret {
    # Inverse of Protect-StateSecret. A value lacking the marker is legacy
    # plaintext and returned as-is. A marked value that fails to decrypt (e.g.
    # the state file was copied from another Windows account) throws — we never
    # want to silently hand back ciphertext as if it were the password.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Stored)
    if ([string]::IsNullOrEmpty($Stored)) { return $Stored }
    if (-not $Stored.StartsWith($Script:SecretPrefix)) { return $Stored }
    $b64 = $Stored.Substring($Script:SecretPrefix.Length)
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String($b64), $Script:SecretEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($dec)
}

function Convert-StateSecrets {
    # Apply $Transform to every users[*].password in-place. Used to flip the
    # whole state between at-rest (encrypted) and in-memory (plaintext) forms.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][scriptblock]$Transform
    )
    if (-not ($State.ContainsKey('users') -and $State.users -is [hashtable])) { return }
    foreach ($proj in @($State.users.Keys)) {
        $rec = $State.users[$proj]
        if ($rec -is [hashtable] -and $rec.ContainsKey('password') -and $rec.password) {
            $rec.password = (& $Transform ([string]$rec.password))
        }
    }
}

function Read-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $path = Get-StatePath -DistroName $DistroName
    if (-not (Test-Path $path)) { return $null }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 16 -AsHashtable
    # Decrypt secrets on the way in so callers always see plaintext.
    Convert-StateSecrets -State $state -Transform { param($v) Unprotect-StateSecret -Stored $v }
    return $state
}

function Write-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State
    )
    $path = Get-StatePath -DistroName $DistroName
    $dir = Split-Path -Parent $path
    # .NET API (literal + idempotent); wsl2-gotchas #19.
    [void][System.IO.Directory]::CreateDirectory($dir)
    $State.schemaVersion = $Script:StateSchemaVersion
    $State.updatedAt     = (Get-Date).ToString('o')
    # Encrypt secrets at rest, then restore the caller's in-memory plaintext in
    # a finally so $State stays usable after the write. The encrypt is INSIDE the
    # try so that even a throw mid-encryption (e.g. DPAPI fails on the 2nd of N
    # users) is recovered: the finally's Unprotect leaves already-encrypted
    # values decrypted and passes still-plaintext ones through unchanged. The
    # state file is written and read single-threaded, so the transient in-place
    # mutation is safe.
    try {
        Convert-StateSecrets -State $State -Transform { param($v) Protect-StateSecret -Plain $v }
        $tmp = "$path.tmp"
        $State | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
    finally {
        Convert-StateSecrets -State $State -Transform { param($v) Unprotect-StateSecret -Stored $v }
    }
}

function Initialize-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $now = (Get-Date).ToString('o')
    return @{
        schemaVersion = $Script:StateSchemaVersion
        distro        = $DistroName
        createdAt     = $now
        updatedAt     = $now
        provisioned   = $false
        users         = @{}
        uidAllocator  = @{ next = $Script:FirstProjectUid }
        # Marks a distro provisioned under the per-project-user model. State
        # created before isolation lacks this key; the migration detector keys
        # on its absence. Write-State never touches it, so a pre-isolation distro
        # keeps prompting for migration until an actual nuke+setup writes a fresh
        # state that carries it.
        userModel     = 'per-project'
    }
}

function Remove-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $dir = Join-Path (Get-StateRoot) $DistroName
    if (Test-Path $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

function Add-Recent {
    # Push a value onto a recents list inside $State.recents.$Key. Deduplicates
    # (most-recent-wins) and trims to $Max entries.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [int]$Max = 5
    )
    if (-not $State.ContainsKey('recents')) { $State['recents'] = @{} }
    if (-not $State.recents.ContainsKey($Key)) { $State.recents[$Key] = @() }
    $cur = @($State.recents[$Key] | Where-Object { $_ -ne $Value })
    $merged = ,$Value + $cur
    $State.recents[$Key] = @($merged | Select-Object -First $Max)
}

# --- Per-project-user records ------------------------------------------------
# These are pure hashtable accessors over $State.users / $State.uidAllocator.
# They tolerate a state read off an older (v1) file that has neither key yet,
# so callers never have to guard for the absence themselves.

function Get-AllProjectUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.ContainsKey('users') -or -not ($State.users -is [hashtable])) {
        return @{}
    }
    return $State.users
}

function Get-ProjectUser {
    # Resolve the Linux-user record for a project, or $null if none is mapped.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project
    )
    $users = Get-AllProjectUsers -State $State
    if ($users.ContainsKey($Project)) { return $users[$Project] }
    return $null
}

function Set-ProjectUserRecord {
    # Insert/replace the record for a project (keyed by the exact project name).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][hashtable]$Record
    )
    if (-not $State.ContainsKey('users') -or -not ($State.users -is [hashtable])) {
        $State['users'] = @{}
    }
    $State.users[$Project] = $Record
}

function Remove-ProjectUserRecord {
    # Drop a project's user mapping. Returns $true if an entry was removed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project
    )
    $users = Get-AllProjectUsers -State $State
    if ($users.ContainsKey($Project)) {
        [void]$users.Remove($Project)
        return $true
    }
    return $false
}

function Test-NeedsUserModelMigration {
    # True when a provisioned distro predates per-project user isolation (its
    # state was created before the `userModel` marker existed). Drives reconcile's
    # offer to rebuild (nuke + setup) so existing projects move into per-project
    # users. A not-yet-provisioned distro never needs migration (fresh setup
    # builds the new model directly).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not ($State.ContainsKey('provisioned') -and $State.provisioned)) { return $false }
    return -not ($State.ContainsKey('userModel') -and $State.userModel -eq 'per-project')
}

function New-ProjectUid {
    # Allocate the next uid from the monotonic cursor and bump it. Initializes
    # the allocator (and seeds it past any uid already recorded in users) when
    # reading off an older state file.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.ContainsKey('uidAllocator') -or -not ($State.uidAllocator -is [hashtable])) {
        $State['uidAllocator'] = @{ next = $Script:FirstProjectUid }
    }
    if (-not $State.uidAllocator.ContainsKey('next')) {
        $State.uidAllocator['next'] = $Script:FirstProjectUid
    }
    # Never hand back a uid at or below one already assigned (covers a state
    # file whose allocator drifted behind its own users map).
    $next = [int]$State.uidAllocator.next
    foreach ($rec in (Get-AllProjectUsers -State $State).Values) {
        if ($rec -is [hashtable] -and $rec.ContainsKey('uid') -and ([int]$rec.uid -ge $next)) {
            $next = [int]$rec.uid + 1
        }
    }
    if ($next -lt $Script:FirstProjectUid) { $next = $Script:FirstProjectUid }
    $State.uidAllocator.next = $next + 1
    return $next
}

Export-ModuleMember -Function `
    Get-StateRoot, `
    Get-BackupRoot, `
    Get-BackupDir, `
    Get-StatePath, `
    Test-State, `
    Read-State, `
    Write-State, `
    Protect-StateSecret, `
    Unprotect-StateSecret, `
    Initialize-State, `
    Remove-State, `
    Add-Recent, `
    Get-AllProjectUsers, `
    Get-ProjectUser, `
    Set-ProjectUserRecord, `
    Remove-ProjectUserRecord, `
    Test-NeedsUserModelMigration, `
    New-ProjectUid
