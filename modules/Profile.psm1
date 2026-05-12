# Profile.psm1
# Profile file (claudearium.profile.json) lifecycle. The profile is the *desired*
# side of the profile-vs-state model (see docs/architecture.md). Every module
# that owns a profile block (projects, mounts, tools, etc.) calls into the
# Get-*Diff functions here to compare desired against actual.
#
# Public surface:
#   Lifecycle
#     Get-DefaultProfilePath                          — %LOCALAPPDATA%\claudearium\claudearium.profile.json
#     Read-Profile  -Path [<switch>-Raw]              — -Raw preserves %ENV% tokens for mutation
#     Write-Profile -Path -Spec <h>                   — atomic .tmp-then-Move
#     Test-Profile  -Spec <h>                          — { IsValid; Errors[]; Warnings[] }
#     Get-ProfileFromState -State <h>                 — used by `profile export`
#   Diff functions, one per block:
#     Get-DistroBlockDiff -DesiredDistro    -CurrentState
#     Get-ProjectsDiff    -DesiredProjects  -ActualProjects
#     Get-HostMountsDiff  -DesiredMounts    -ActualMounts
#     Get-ToolsDiff       -DesiredTools     -ActualTools
#     Get-HostToolsDiff   -DesiredTools     -ActualTools
#                                                     — each returns @{ Changes; HasDestructive; CanApplyInPlace }
#     Format-Diff -Diff <h>                            — renders a Diff to console
#   Internals
#     Resolve-EnvTokens         — %FOO% -> $env:FOO via [Environment]::ExpandEnvironmentVariables
#     ConvertFrom-ProfileRaw    — recursive walk that expands %ENV% in string leaves
#
# Schema invariants: schemaVersion=1; distro is required (name+base+installPath
# all required, base in $Script:KnownDistroBases). Every other block is
# optional. claudeSettings.defaultEffort must be in $Script:KnownEffortLevels.
# tools.* names are checked against $Script:KnownToolNames (warning, not error).
#
# IMPORTANT: every array-typed field gets @()-wrapped on read because
# ConvertFrom-Json -AsHashtable unwraps single-element arrays. See
# docs/wsl2-gotchas.md#2.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProfileSchemaVersion = 1
$Script:KnownDistroBases     = @('debian-12')
$Script:KnownTopLevelKeys    = @('$schema', 'schemaVersion', 'distro', 'vpn', 'tools', 'projects', 'hostMounts', 'hostTools', 'claudeSettings', 'claudeFile')
$Script:KnownClaudeFileModes = @('host-copy', 'caveman-lite', 'custom-path')
$Script:KnownEffortLevels    = @('low', 'medium', 'high', 'xhigh')
$Script:KnownMountModes      = @('ro', 'rw')
# The set of tools the runtime knows how to install. Anything else in the
# profile.tools block becomes a validation warning (not an error — extending
# the catalog requires adding to this list).
$Script:KnownToolNames       = @('node', 'claudeCode', 'gh', 'glab', 'acli', 'dotnet', 'seqcli', 'pwsh')

function Get-DefaultProfilePath {
    # Default profile lives under LOCALAPPDATA alongside state. Users can override
    # via -ProfilePath. Edit it via 'profile edit' which knows this default.
    [CmdletBinding()] param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve profile path.' }
    return (Join-Path $env:LOCALAPPDATA 'claudearium\claudearium.profile.json')
}

function Resolve-EnvTokens {
    # Expand %ENV_VAR% tokens (Windows-style) inside a string.
    param([Parameter(Mandatory)][string]$Value)
    return [Environment]::ExpandEnvironmentVariables($Value)
}

function ConvertFrom-ProfileRaw {
    # Recursively walk a parsed hashtable and expand %ENV% in string leaves.
    # Returns a new structure; does not mutate input.
    param([Parameter(Mandatory)][AllowNull()]$Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        $copy = @{}
        foreach ($k in $Object.Keys) { $copy[$k] = ConvertFrom-ProfileRaw $Object[$k] }
        return $copy
    }
    if ($Object -is [System.Collections.IList] -and $Object -isnot [string]) {
        return @($Object | ForEach-Object { ConvertFrom-ProfileRaw $_ })
    }
    if ($Object -is [string]) {
        return Resolve-EnvTokens -Value $Object
    }
    return $Object
}

function Read-Profile {
    # Default: returns a copy with %ENV% tokens expanded (for consumption).
    # Pass -Raw to get the on-disk form (for mutation + write-back so we don't
    # eat the user's env-var placeholders).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Raw
    )
    if (-not (Test-Path $Path)) { throw "Profile not found: $Path" }
    # NB: avoid $raw locally — PowerShell vars are case-insensitive so $raw would
    # alias the [switch] parameter and corrupt later assignments.
    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 32 -AsHashtable
    if ($Raw) { return $parsed }
    return (ConvertFrom-ProfileRaw $parsed)
}

function Write-Profile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Spec
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    $Spec | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-Profile {
    # Manual validation. Returns @{ IsValid; Errors[]; Warnings[] }.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Spec)
    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not $Spec.ContainsKey('schemaVersion')) {
        $errors.Add('schemaVersion is required (expected 1).')
    }
    elseif ($Spec.schemaVersion -ne $Script:ProfileSchemaVersion) {
        $errors.Add("schemaVersion '$($Spec.schemaVersion)' is not supported (expected $Script:ProfileSchemaVersion).")
    }

    if (-not $Spec.ContainsKey('distro')) {
        $errors.Add('distro block is required.')
    }
    else {
        $d = $Spec.distro
        if (-not ($d -is [hashtable])) {
            $errors.Add('distro must be an object.')
        }
        else {
            if (-not $d.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$d.name)) {
                $errors.Add('distro.name is required and must be non-empty.')
            }
            if (-not $d.ContainsKey('base') -or [string]::IsNullOrWhiteSpace([string]$d.base)) {
                $errors.Add('distro.base is required.')
            }
            elseif ($d.base -notin $Script:KnownDistroBases) {
                $warnings.Add("distro.base '$($d.base)' is not in the known set ($($Script:KnownDistroBases -join ', ')).")
            }
            if (-not $d.ContainsKey('installPath') -or [string]::IsNullOrWhiteSpace([string]$d.installPath)) {
                $errors.Add('distro.installPath is required.')
            }
        }
    }

    if ($Spec.ContainsKey('projects') -and $null -ne $Spec.projects) {
        # @(...) normalizes: PowerShell's ConvertFrom-Json -AsHashtable unwraps
        # single-element JSON arrays into the lone element, so we always wrap.
        $projects = @($Spec.projects)
        $seenNames = @{}
        for ($i = 0; $i -lt $projects.Count; $i++) {
            $p = $projects[$i]
            if (-not ($p -is [hashtable])) {
                $errors.Add("projects[$i] must be an object.")
                continue
            }
            if (-not $p.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$p.name)) {
                $errors.Add("projects[$i].name is required.")
            }
            else {
                $n = [string]$p.name
                if ($n -match '[\\/\s]') {
                    $errors.Add("projects[$i].name '$n' must not contain whitespace or path separators.")
                }
                if ($seenNames.ContainsKey($n)) {
                    $errors.Add("projects[$i].name '$n' is duplicated.")
                }
                else { $seenNames[$n] = $true }
            }
            if (-not $p.ContainsKey('remote') -or [string]::IsNullOrWhiteSpace([string]$p.remote)) {
                $errors.Add("projects[$i].remote is required.")
            }
            if ($p.ContainsKey('tabColor') -and -not [string]::IsNullOrEmpty([string]$p.tabColor)) {
                $tc = [string]$p.tabColor
                if ($tc -notmatch '^#[0-9A-Fa-f]{6}$') {
                    $errors.Add("projects[$i].tabColor '$tc' must be a hex color in the form '#RRGGBB'.")
                }
            }
        }
    }

    if ($Spec.ContainsKey('vpn') -and $null -ne $Spec.vpn) {
        if (-not ($Spec.vpn -is [hashtable])) {
            $errors.Add('vpn must be an object.')
        }
        else {
            $v = $Spec.vpn
            if ($v.ContainsKey('wgConfigPath') -and $v.wgConfigPath -and -not ($v.wgConfigPath -is [string])) {
                $errors.Add('vpn.wgConfigPath must be a string (Windows file path).')
            }
            if ($v.ContainsKey('killswitch') -and $null -ne $v.killswitch -and -not ($v.killswitch -is [bool])) {
                $errors.Add('vpn.killswitch must be a boolean.')
            }
        }
    }

    if ($Spec.ContainsKey('tools') -and $null -ne $Spec.tools) {
        if (-not ($Spec.tools -is [hashtable])) {
            $errors.Add('tools must be an object keyed by tool name.')
        }
        else {
            foreach ($k in $Spec.tools.Keys) {
                $entry = $Spec.tools[$k]
                if (-not ($entry -is [hashtable])) {
                    $errors.Add("tools.${k} must be an object with at least { enabled, version }.")
                    continue
                }
                if ($entry.ContainsKey('enabled') -and $null -ne $entry.enabled -and -not ($entry.enabled -is [bool])) {
                    $errors.Add("tools.${k}.enabled must be a boolean.")
                }
                if ($entry.ContainsKey('version') -and $entry.version -and -not ($entry.version -is [string])) {
                    $errors.Add("tools.${k}.version must be a string.")
                }
                if ($k -notin $Script:KnownToolNames) {
                    $warnings.Add("tools.${k}: unknown tool (will be ignored).")
                }
            }
        }
    }

    if ($Spec.ContainsKey('hostMounts') -and $null -ne $Spec.hostMounts) {
        $mounts = @($Spec.hostMounts)
        $seenGuests = @{}
        for ($i = 0; $i -lt $mounts.Count; $i++) {
            $m = $mounts[$i]
            if (-not ($m -is [hashtable])) {
                $errors.Add("hostMounts[$i] must be an object.")
                continue
            }
            if (-not $m.ContainsKey('host') -or [string]::IsNullOrWhiteSpace([string]$m.host)) {
                $errors.Add("hostMounts[$i].host is required.")
            }
            if (-not $m.ContainsKey('guest') -or [string]::IsNullOrWhiteSpace([string]$m.guest)) {
                $errors.Add("hostMounts[$i].guest is required.")
            }
            else {
                $g = [string]$m.guest
                if (-not $g.StartsWith('/')) {
                    $errors.Add("hostMounts[$i].guest '$g' must be an absolute Linux path.")
                }
                if ($seenGuests.ContainsKey($g)) {
                    $errors.Add("hostMounts[$i].guest '$g' is duplicated.")
                }
                else { $seenGuests[$g] = $true }
            }
            if ($m.ContainsKey('mode') -and $m.mode) {
                if ([string]$m.mode -notin $Script:KnownMountModes) {
                    $errors.Add("hostMounts[$i].mode '$($m.mode)' must be 'ro' or 'rw'.")
                }
            }
        }
    }

    if ($Spec.ContainsKey('claudeSettings') -and $null -ne $Spec.claudeSettings) {
        if (-not ($Spec.claudeSettings -is [hashtable])) {
            $errors.Add('claudeSettings must be an object.')
        }
        else {
            $cs = $Spec.claudeSettings
            if ($cs.ContainsKey('defaultEffort') -and $cs.defaultEffort -and ([string]$cs.defaultEffort) -notin $Script:KnownEffortLevels) {
                $errors.Add("claudeSettings.defaultEffort '$($cs.defaultEffort)' must be one of: $($Script:KnownEffortLevels -join ', ').")
            }
            foreach ($bf in @('autoApproveReadOnlyBash','autoApproveProjectWrites','autoApproveBuildCommands','claudelk')) {
                if ($cs.ContainsKey($bf) -and $null -ne $cs[$bf] -and -not ($cs[$bf] -is [bool])) {
                    $errors.Add("claudeSettings.${bf} must be a boolean.")
                }
            }
            foreach ($sf in @('model','theme')) {
                if ($cs.ContainsKey($sf) -and $cs[$sf] -and -not ($cs[$sf] -is [string])) {
                    $errors.Add("claudeSettings.${sf} must be a string.")
                }
            }
            if ($cs.ContainsKey('claudelkEvents') -and $null -ne $cs.claudelkEvents) {
                $evs = @($cs.claudelkEvents)
                foreach ($e in $evs) {
                    if (-not ($e -is [string])) { $errors.Add('claudeSettings.claudelkEvents entries must be strings (event names).') }
                }
            }
        }
    }

    if ($Spec.ContainsKey('claudeFile') -and $null -ne $Spec.claudeFile) {
        if (-not ($Spec.claudeFile -is [hashtable])) {
            $errors.Add('claudeFile must be an object.')
        }
        else {
            $cf = $Spec.claudeFile
            if (-not $cf.ContainsKey('mode') -or [string]::IsNullOrWhiteSpace([string]$cf.mode)) {
                $errors.Add('claudeFile.mode is required.')
            }
            elseif ([string]$cf.mode -notin $Script:KnownClaudeFileModes) {
                $errors.Add("claudeFile.mode '$($cf.mode)' must be one of: $($Script:KnownClaudeFileModes -join ', ').")
            }
            else {
                $mode = [string]$cf.mode
                $hasPath = $cf.ContainsKey('path') -and -not [string]::IsNullOrWhiteSpace([string]$cf.path)
                if ($mode -eq 'custom-path' -and -not $hasPath) {
                    $errors.Add('claudeFile.path is required when mode = custom-path.')
                }
                elseif ($mode -ne 'custom-path' -and $hasPath) {
                    $warnings.Add("claudeFile.path is set but mode = '$mode'; path will be ignored.")
                }
            }
        }
    }

    if ($Spec.ContainsKey('hostTools') -and $null -ne $Spec.hostTools) {
        $tools = @($Spec.hostTools)
        $seenCmds = @{}
        for ($i = 0; $i -lt $tools.Count; $i++) {
            $t = $tools[$i]
            if (-not ($t -is [hashtable])) {
                $errors.Add("hostTools[$i] must be an object.")
                continue
            }
            if (-not $t.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$t.name)) {
                $errors.Add("hostTools[$i].name is required.")
            }
            if (-not $t.ContainsKey('windowsExe') -or [string]::IsNullOrWhiteSpace([string]$t.windowsExe)) {
                $errors.Add("hostTools[$i].windowsExe is required.")
            }
            if (-not $t.ContainsKey('guestCommand') -or [string]::IsNullOrWhiteSpace([string]$t.guestCommand)) {
                $errors.Add("hostTools[$i].guestCommand is required.")
            }
            else {
                $gc = [string]$t.guestCommand
                if ($gc -match '[\\/\s]') {
                    $errors.Add("hostTools[$i].guestCommand '$gc' must be a bare filename (no slashes/whitespace).")
                }
                if ($seenCmds.ContainsKey($gc)) {
                    $errors.Add("hostTools[$i].guestCommand '$gc' is duplicated.")
                }
                else { $seenCmds[$gc] = $true }
            }
        }
    }

    foreach ($k in $Spec.Keys) {
        if ($k -notin $Script:KnownTopLevelKeys) { $warnings.Add("Unknown top-level key '$k' (ignored).") }
    }

    return @{
        IsValid  = ($errors.Count -eq 0)
        Errors   = $errors
        Warnings = $warnings
    }
}

function Get-ProfileFromState {
    # Build a minimal profile from a state object — used by 'profile export'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [string]$Base = 'debian-12'
    )
    if (-not $State.ContainsKey('distro') -or -not $State.ContainsKey('installPath')) {
        throw "Cannot export profile: state is missing 'distro' or 'installPath'."
    }
    return @{
        schemaVersion = $Script:ProfileSchemaVersion
        distro        = @{
            name        = $State.distro
            base        = $Base
            installPath = $State.installPath
        }
    }
}

function Get-DistroBlockDiff {
    # Compare a desired profile distro block to a current state's distro info.
    # Returns @{ Changes; HasDestructive; CanApplyInPlace }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$DesiredDistro,
        [Parameter(Mandatory)][hashtable]$CurrentState
    )
    $changes = [System.Collections.Generic.List[hashtable]]::new()

    if ([string]$DesiredDistro.name -ne [string]$CurrentState.distro) {
        $changes.Add(@{
            Path             = 'distro.name'
            From             = $CurrentState.distro
            To               = $DesiredDistro.name
            Severity         = 'destructive'
            RequiresRecreate = $true
            Note             = "WSL distro rename can't happen in place; run 'nuke -Force' then 'setup'."
        })
    }
    $curInstall = if ($CurrentState.ContainsKey('installPath')) { [string]$CurrentState.installPath } else { '' }
    if ([string]$DesiredDistro.installPath -ne $curInstall) {
        $changes.Add(@{
            Path             = 'distro.installPath'
            From             = $curInstall
            To               = $DesiredDistro.installPath
            Severity         = 'destructive'
            RequiresRecreate = $true
            Note             = "Install path move requires unregister+import; run 'nuke -Force' then 'setup'."
        })
    }

    $destructive = [bool]($changes | Where-Object { $_.Severity -eq 'destructive' })
    return @{
        Changes         = $changes
        HasDestructive  = $destructive
        CanApplyInPlace = (-not $destructive)
    }
}

function Get-ProjectsDiff {
    # Compute add / remove / remote-change set between desired (profile.projects[])
    # and actual (state.projects[]). Returns the same shape as Get-DistroBlockDiff.
    [CmdletBinding()]
    param(
        [AllowNull()]$DesiredProjects,
        [AllowNull()]$ActualProjects
    )
    # Always force-wrap; pwsh JSON-array-of-1 unwrap means callers can hand us
    # a bare hashtable instead of a 1-element array.
    $desired = @(); if ($DesiredProjects) { $desired = @($DesiredProjects) }
    $actual  = @(); if ($ActualProjects)  { $actual  = @($ActualProjects)  }

    $changes = [System.Collections.Generic.List[hashtable]]::new()
    $desiredByName = @{}; foreach ($p in $desired) { $desiredByName[[string]$p.name] = $p }
    $actualByName  = @{}; foreach ($p in $actual)  { $actualByName[[string]$p.name]  = $p }

    foreach ($name in $desiredByName.Keys) {
        if (-not $actualByName.ContainsKey($name)) {
            $changes.Add(@{
                Path     = "projects.$name"
                Action   = 'add'
                Severity = 'safe'
                To       = [string]$desiredByName[$name].remote
                Note     = 'Will git clone --mirror into the distro.'
            })
        }
        else {
            $desired = $desiredByName[$name]
            $actual  = $actualByName[$name]
            if ([string]$desired.remote -ne [string]$actual.remote) {
                $changes.Add(@{
                    Path     = "projects.$name.remote"
                    Action   = 'modify'
                    Severity = 'destructive'
                    From     = [string]$actual.remote
                    To       = [string]$desired.remote
                    Note     = "Remote changed — remove the project and re-add it."
                })
            }
        }
    }
    foreach ($name in $actualByName.Keys) {
        if (-not $desiredByName.ContainsKey($name)) {
            $changes.Add(@{
                Path     = "projects.$name"
                Action   = 'remove'
                Severity = 'destructive'
                From     = [string]$actualByName[$name].remote
                Note     = 'Will delete the bare mirror AND every session of this project.'
            })
        }
    }

    return @{
        Changes         = $changes
        HasDestructive  = [bool]($changes | Where-Object { $_.Severity -eq 'destructive' })
        CanApplyInPlace = $true   # add/remove apply in place; remote-change requires user action
    }
}

function Get-HostMountsDiff {
    # add / remove / modify diff between desired (profile.hostMounts) and actual (fstab).
    # Key on guest path. Modify covers host/mode/options drift.
    [CmdletBinding()]
    param(
        [AllowNull()]$DesiredMounts,
        [AllowNull()]$ActualMounts
    )
    $desired = @(); if ($DesiredMounts) { $desired = @($DesiredMounts) }
    $actual  = @(); if ($ActualMounts)  { $actual  = @($ActualMounts)  }

    $changes = [System.Collections.Generic.List[hashtable]]::new()
    $desiredByGuest = @{}; foreach ($m in $desired) { $desiredByGuest[[string]$m.guest] = $m }
    $actualByGuest  = @{}; foreach ($m in $actual)  { $actualByGuest[[string]$m.guest]  = $m }

    foreach ($g in $desiredByGuest.Keys) {
        $d = $desiredByGuest[$g]
        if (-not $actualByGuest.ContainsKey($g)) {
            $changes.Add(@{
                Path     = "hostMounts.$g"
                Action   = 'add'
                Severity = 'safe'
                To       = "$([string]$d.host) ($($d.mode))"
                Note     = "Will add to /etc/fstab and run 'mount -a'."
            })
        }
        else {
            $a = $actualByGuest[$g]
            $dHost  = [string]$d.host
            $aHost  = [string]$a.host
            $dMode  = if ($d.ContainsKey('mode') -and $d.mode) { [string]$d.mode } else { 'ro' }
            $aMode  = if ($a.ContainsKey('mode') -and $a.mode) { [string]$a.mode } else { 'ro' }
            $dOpts  = if ($d.ContainsKey('options') -and $d.options) { [string]$d.options } else { '' }
            $aOpts  = if ($a.ContainsKey('options') -and $a.options) { [string]$a.options } else { '' }
            if ($dHost -ne $aHost -or $dMode -ne $aMode -or $dOpts -ne $aOpts) {
                $changes.Add(@{
                    Path     = "hostMounts.$g"
                    Action   = 'modify'
                    Severity = 'safe'
                    From     = "$aHost ($aMode) $aOpts".Trim()
                    To       = "$dHost ($dMode) $dOpts".Trim()
                    Note     = 'Will umount + replace fstab entry + remount.'
                })
            }
        }
    }
    foreach ($g in $actualByGuest.Keys) {
        if (-not $desiredByGuest.ContainsKey($g)) {
            $changes.Add(@{
                Path     = "hostMounts.$g"
                Action   = 'remove'
                Severity = 'safe'
                From     = [string]$actualByGuest[$g].host
                Note     = 'Will umount and drop the fstab entry.'
            })
        }
    }
    return @{
        Changes         = $changes
        HasDestructive  = $false
        CanApplyInPlace = $true
    }
}

function Get-ToolsDiff {
    # Diff profile.tools (desired) against actual-installed list. Treats it
    # as install/skip — no version-drift upgrades, and no auto-remove for
    # disabled tools (we just warn).
    [CmdletBinding()]
    param(
        [AllowNull()]$DesiredTools,    # hashtable: name -> { enabled, version }
        [AllowNull()]$ActualTools      # array of @{ name; version; installed }
    )
    $changes = [System.Collections.Generic.List[hashtable]]::new()
    if (-not $DesiredTools -or -not ($DesiredTools -is [hashtable])) { return @{ Changes = $changes; HasDestructive = $false; CanApplyInPlace = $true } }

    $actualByName = @{}
    foreach ($a in @($ActualTools)) { if ($a) { $actualByName[[string]$a.name] = $a } }

    foreach ($name in $DesiredTools.Keys) {
        $entry  = $DesiredTools[$name]
        if (-not $entry) { continue }
        $enabled = if ($entry.ContainsKey('enabled')) { [bool]$entry.enabled } else { $true }
        $version = if ($entry.ContainsKey('version')) { [string]$entry.version } else { 'latest' }
        $actualInstalled = $actualByName.ContainsKey($name) -and $actualByName[$name].installed

        if ($enabled -and -not $actualInstalled) {
            $changes.Add(@{
                Path     = "tools.$name"
                Action   = 'add'
                Severity = 'safe'
                To       = "$version"
                Note     = "Will install $name."
            })
        }
        elseif (-not $enabled -and $actualInstalled) {
            $changes.Add(@{
                Path     = "tools.$name"
                Action   = 'modify'
                Severity = 'safe'
                From     = ($actualByName[$name].version)
                To       = '(disabled)'
                Note     = "$name is installed but disabled in profile. The tool does not auto-uninstall — remove manually if you want."
            })
        }
    }

    return @{
        Changes         = $changes
        HasDestructive  = $false
        CanApplyInPlace = $true
    }
}

function Get-HostToolsDiff {
    # Diff profile.hostTools against actual /usr/local/bin wrappers, keyed on
    # guestCommand. add/remove/modify (when windowsExe or smokeTest changes).
    [CmdletBinding()]
    param(
        [AllowNull()]$DesiredTools,
        [AllowNull()]$ActualTools
    )
    $desired = @(); if ($DesiredTools) { $desired = @($DesiredTools) }
    $actual  = @(); if ($ActualTools)  { $actual  = @($ActualTools)  }

    $changes = [System.Collections.Generic.List[hashtable]]::new()
    $desiredByCmd = @{}; foreach ($t in $desired) { $desiredByCmd[[string]$t.guestCommand] = $t }
    $actualByCmd  = @{}; foreach ($t in $actual)  { $actualByCmd[[string]$t.guestCommand]  = $t }

    foreach ($gc in $desiredByCmd.Keys) {
        $d = $desiredByCmd[$gc]
        if (-not $actualByCmd.ContainsKey($gc)) {
            $changes.Add(@{
                Path     = "hostTools.$gc"
                Action   = 'add'
                Severity = 'safe'
                To       = [string]$d.windowsExe
                Note     = "Will create /usr/local/bin/$gc."
            })
            continue
        }
        $a = $actualByCmd[$gc]
        $dExe = [string]$d.windowsExe
        $aExe = [string]$a.windowsExe
        if ($dExe -ne $aExe) {
            $changes.Add(@{
                Path     = "hostTools.$gc.windowsExe"
                Action   = 'modify'
                Severity = 'safe'
                From     = $aExe
                To       = $dExe
                Note     = 'Will rewrite the wrapper.'
            })
        }
    }
    foreach ($gc in $actualByCmd.Keys) {
        if (-not $desiredByCmd.ContainsKey($gc)) {
            $changes.Add(@{
                Path     = "hostTools.$gc"
                Action   = 'remove'
                Severity = 'safe'
                From     = [string]$actualByCmd[$gc].windowsExe
                Note     = "Will delete /usr/local/bin/$gc."
            })
        }
    }
    return @{
        Changes         = $changes
        HasDestructive  = $false
        CanApplyInPlace = $true
    }
}

function Get-ClaudeFileDiff {
    # Plain string-compare between the desired CLAUDE.md content (caller
    # pre-renders it via Get-ClaudeFileDesiredContent from ClaudeFile.psm1) and
    # the file in the distro. No hashtable-ordering caveat like claudeSettings,
    # so this *is* included in reconcile's diff. Absent-block + present-in-
    # distro is treated as 'unmanaged' (no change) — we never blow away a file
    # the user placed manually.
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()]$DesiredContent,   # string or $null
        [AllowNull()][AllowEmptyString()]$ActualContent,    # string or $null
        [string]$ModeLabel = ''
    )
    $changes = [System.Collections.Generic.List[hashtable]]::new()
    if ($null -eq $DesiredContent) {
        return @{ Changes = $changes; HasDestructive = $false; CanApplyInPlace = $true }
    }
    $desired = [string]$DesiredContent
    $modeHint = if ($ModeLabel) { "mode: $ModeLabel, " } else { '' }

    if ($null -eq $ActualContent) {
        $changes.Add(@{
            Path     = 'claudeFile'
            Action   = 'add'
            Severity = 'safe'
            To       = "($modeHint$($desired.Length) chars)"
            Note     = 'Will write /home/claude/.claude/CLAUDE.md.'
        })
    }
    elseif ([string]$ActualContent -ne $desired) {
        $preview = if ($desired.Length -gt 60) { $desired.Substring(0, 60) + '...' } else { $desired }
        $preview = $preview -replace "`n", '\n'
        $actLen = ([string]$ActualContent).Length
        $changes.Add(@{
            Path     = 'claudeFile'
            Action   = 'modify'
            Severity = 'safe'
            From     = "($actLen chars)"
            To       = "($modeHint$($desired.Length) chars) '$preview'"
            Note     = 'Will rewrite /home/claude/.claude/CLAUDE.md.'
        })
    }
    return @{
        Changes         = $changes
        HasDestructive  = $false
        CanApplyInPlace = $true
    }
}

function Format-Diff {
    # Render a diff result as colored text. Caller has already printed a header.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Diff)
    if ($Diff.Changes.Count -eq 0) {
        Write-Host '  (no changes — profile matches state)' -ForegroundColor DarkGray
        return
    }
    foreach ($c in $Diff.Changes) {
        $action = if ($c.ContainsKey('Action')) { [string]$c.Action } else { 'modify' }
        $marker = switch ($action) {
            'add'    { '++' }
            'remove' { '--' }
            default  { '~~' }
        }
        $color  = if ($c.Severity -eq 'destructive') { 'Red' } else { 'Yellow' }
        Write-Host ('  {0} {1}' -f $marker, $c.Path) -ForegroundColor $color
        if ($c.ContainsKey('From') -and $null -ne $c.From) { Write-Host ('     from:  {0}' -f $c.From) }
        if ($c.ContainsKey('To')   -and $null -ne $c.To)   { Write-Host ('     to:    {0}' -f $c.To) }
        if ($c.ContainsKey('Note') -and $c.Note)           { Write-Host ('     note:  {0}' -f $c.Note) -ForegroundColor DarkYellow }
    }
}

Export-ModuleMember -Function `
    Get-DefaultProfilePath, `
    Resolve-EnvTokens, `
    ConvertFrom-ProfileRaw, `
    Read-Profile, `
    Write-Profile, `
    Test-Profile, `
    Get-ProfileFromState, `
    Get-DistroBlockDiff, `
    Get-ProjectsDiff, `
    Get-HostMountsDiff, `
    Get-ToolsDiff, `
    Get-HostToolsDiff, `
    Get-ClaudeFileDiff, `
    Format-Diff
