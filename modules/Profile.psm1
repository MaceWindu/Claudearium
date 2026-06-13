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
$Script:KnownTopLevelKeys    = @('$schema', 'schemaVersion', 'distro', 'vpn', 'network', 'tools', 'projects', 'projectDefaults', 'hostMounts', 'hostTools', 'claudeSettings', 'claudeFile', 'claudeShared')
$Script:KnownClaudeFileModes = @('host-copy', 'caveman-lite', 'custom-path')
# claudeShared.claudeMd additionally accepts 'skip' (leave CLAUDE.md unmanaged).
$Script:KnownClaudeMdModes   = @('host-copy', 'caveman-lite', 'custom-path', 'skip')
$Script:KnownEffortLevels    = @('low', 'medium', 'high', 'xhigh')
$Script:KnownMountModes      = @('ro', 'rw')
$Script:KnownVpnRoutingModes = @('from-config', 'all-except-lan')
$Script:KnownPermissionModes = @('default', 'acceptEdits', 'plan', 'bypassPermissions', 'auto', 'dontAsk')
$Script:KnownAutoUpdateChannels = @('stable', 'latest')
$Script:KnownTuiModes        = @('fullscreen', 'default')
$Script:KnownDefaultShells   = @('bash', 'powershell')
$Script:KnownEditorModes     = @('normal', 'vim')
# Project entries default to 'distro' (bare mirror inside the distro, sessions
# are distro-side worktrees). 'host' is the Windows-resident variant: sessions
# are host-side `git worktree add` paths mounted into the distro. Profile.psm1
# keeps schema enforcement; module wiring lives in Projects/Sessions/Mounts.
$Script:KnownProjectTypes    = @('distro', 'host')
# Built-in catalog of host tools that can be auto-resolved when listed under
# projects[].hostShadows in string form. Anything outside this list still works
# via the explicit { name, windowsExe } form — we warn rather than error so
# users can extend without recompiling.
$Script:KnownHostShadowNames = @('pwsh', 'git')
# Tight IPv4-CIDR regex (octets 0..255, prefix 0..32). Keep the schema's
# `lanCidr` pattern and claudearium.ps1's interactive Read-Host loop in sync
# with this — there's no shared source of truth across PowerShell + JSON
# Schema, so the three callsites stay aligned by convention.
$Script:Ipv4CidrRegex        = '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}/(3[0-2]|[12]?[0-9])$'
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

function Test-ToolEntryEnabled {
    # Canonical "is this tools.<name> entry enabled?" check. Missing 'enabled'
    # field defaults to $true (matches Get-ToolRows / Get-ToolsDiff convention).
    # Kept in one place so the conflict check, the attach-from-host flow, and the
    # scan UX can't drift on the default.
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Entry)
    if ($null -eq $Entry -or -not ($Entry -is [hashtable])) { return $false }
    if (-not $Entry.ContainsKey('enabled')) { return $true }
    return [bool]$Entry.enabled
}

function Test-ProjectEnabled {
    # Canonical "is this projects[] entry enabled?" check. Missing 'enabled'
    # defaults to $true. Mirrors Test-ToolEntryEnabled so the projects diff,
    # the project dashboard's row renderer, and `project show` can't drift
    # on the default.
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Entry)
    if ($null -eq $Entry -or -not ($Entry -is [hashtable])) { return $false }
    if (-not $Entry.ContainsKey('enabled')) { return $true }
    return [bool]$Entry.enabled
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Profile not found: $Path" }
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
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        # Use the .NET API (not `New-Item`) so wildcard glyphs ([, ], *) in
        # the directory name aren't interpreted as a pattern by the provider.
        # New-Item lacks a -LiteralPath parameter; Directory.CreateDirectory
        # is literal by definition and idempotent (no-op if already exists).
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
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

            # Capability derives from field presence, not a `type` field: a
            # project may carry a distro half (`remote`) and/or a host half
            # (`hostCheckout`). At least one is required; both is a valid
            # dual-capability project. The legacy `type` key is still accepted
            # for old profiles but is advisory (we warn so the user removes it).
            $hasDistro = ($p.ContainsKey('remote') -and -not [string]::IsNullOrWhiteSpace([string]$p.remote))
            $hasHost   = ($p.ContainsKey('hostCheckout') -and -not [string]::IsNullOrWhiteSpace([string]$p.hostCheckout))

            if (-not $hasDistro -and -not $hasHost) {
                $errors.Add("projects[$i] needs at least one of: remote (distro half) or hostCheckout (host half).")
            }
            if ($p.ContainsKey('type') -and $p.type) {
                $projectType = [string]$p.type
                if ($projectType -notin $Script:KnownProjectTypes) {
                    $errors.Add("projects[$i].type '$projectType' must be one of: $($Script:KnownProjectTypes -join ', ').")
                }
                else {
                    $warnings.Add("projects[$i].type is deprecated and ignored; capability now derives from remote/hostCheckout presence. Remove the field.")
                }
            }

            # hostShadows configures the host half. Forbid it outright when there
            # is no host half; otherwise run the per-entry shape/catalog checks.
            if ($p.ContainsKey('hostShadows') -and $null -ne $p.hostShadows -and @($p.hostShadows).Count -gt 0 -and -not $hasHost) {
                $errors.Add("projects[$i].hostShadows requires hostCheckout (it configures the host half).")
            }
            elseif ($hasHost -and $p.ContainsKey('hostShadows') -and $null -ne $p.hostShadows) {
                $shadows = @($p.hostShadows)
                $seenShadowNames = @{}
                for ($j = 0; $j -lt $shadows.Count; $j++) {
                    $s = $shadows[$j]
                    $shadowName = $null
                    $isStringForm = $false
                    if ($s -is [string]) {
                        $isStringForm = $true
                        if ([string]::IsNullOrWhiteSpace($s)) {
                            $errors.Add("projects[$i].hostShadows[$j] is empty.")
                        }
                        else { $shadowName = $s }
                    }
                    elseif ($s -is [hashtable]) {
                        if (-not $s.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$s.name)) {
                            $errors.Add("projects[$i].hostShadows[$j].name is required.")
                        }
                        else { $shadowName = [string]$s.name }
                        if (-not $s.ContainsKey('windowsExe') -or [string]::IsNullOrWhiteSpace([string]$s.windowsExe)) {
                            $errors.Add("projects[$i].hostShadows[$j].windowsExe is required (use the string form to auto-resolve via PATH).")
                        }
                    }
                    else {
                        $errors.Add("projects[$i].hostShadows[$j] must be a string or { name, windowsExe } object.")
                    }
                    if ($shadowName) {
                        if ($shadowName -match '[\\/\s]') {
                            $errors.Add("projects[$i].hostShadows[$j] name '$shadowName' must be a bare command name (no slashes/whitespace).")
                        }
                        if ($seenShadowNames.ContainsKey($shadowName)) {
                            $errors.Add("projects[$i].hostShadows[$j] name '$shadowName' is duplicated.")
                        }
                        else { $seenShadowNames[$shadowName] = $true }
                        if ($isStringForm -and $shadowName -notin $Script:KnownHostShadowNames) {
                            $warnings.Add("projects[$i].hostShadows[$j] '$shadowName' is not in the built-in catalog ($($Script:KnownHostShadowNames -join ', ')); use the { name, windowsExe } form to pin a specific exe.")
                        }
                    }
                }
            }

            # The per-project `hostTools` form lands wrappers in shared
            # /usr/local/bin and leaks across all sessions — the conflict mode
            # the per-project bin dir (hostShadows) exists to avoid. Forbid it
            # only for a host-ONLY project; a project that also has a distro half
            # legitimately uses hostTools for its distro-side sessions.
            if ($hasHost -and -not $hasDistro -and $p.ContainsKey('hostTools') -and $null -ne $p.hostTools -and @($p.hostTools).Count -gt 0) {
                $errors.Add("projects[$i].hostTools is not allowed for a host-only project; use hostShadows so wrappers stay in a per-project bin dir.")
            }

            if ($p.ContainsKey('tabColor') -and -not [string]::IsNullOrEmpty([string]$p.tabColor)) {
                $tc = [string]$p.tabColor
                if ($tc -notmatch '^#[0-9A-Fa-f]{6}$') {
                    $errors.Add("projects[$i].tabColor '$tc' must be a hex color in the form '#RRGGBB'.")
                }
            }

            # Windows Terminal appearance (icon / backgroundImage / opacity). Strings
            # are stored verbatim — WT validates the actual path/glyph at launch — so
            # we only type-check. Opacity is a percent (0=transparent, 100=solid).
            foreach ($sf in @('icon', 'backgroundImage')) {
                if ($p.ContainsKey($sf) -and $null -ne $p[$sf] -and -not ($p[$sf] -is [string])) {
                    $errors.Add("projects[$i].${sf} must be a string.")
                }
            }
            if ($p.ContainsKey('backgroundImageOpacity') -and $null -ne $p.backgroundImageOpacity) {
                $bo = $p.backgroundImageOpacity
                if (-not (($bo -is [int]) -or ($bo -is [long]))) {
                    $errors.Add("projects[$i].backgroundImageOpacity must be an integer 0-100.")
                }
                elseif ([int]$bo -lt 0 -or [int]$bo -gt 100) {
                    $errors.Add("projects[$i].backgroundImageOpacity must be 0-100 (got $bo).")
                }
            }

            if ($p.ContainsKey('enabled') -and $p.enabled -isnot [bool]) {
                $errors.Add("projects[$i].enabled must be a boolean (true / false).")
            }
        }
    }

    if ($Spec.ContainsKey('projectDefaults') -and $null -ne $Spec.projectDefaults) {
        if (-not ($Spec.projectDefaults -is [hashtable])) {
            $errors.Add('projectDefaults must be an object.')
        }
        else {
            $pd = $Spec.projectDefaults
            if ($pd.ContainsKey('backgroundImageOpacity') -and $null -ne $pd.backgroundImageOpacity) {
                $bo = $pd.backgroundImageOpacity
                if (-not (($bo -is [int]) -or ($bo -is [long]))) {
                    $errors.Add('projectDefaults.backgroundImageOpacity must be an integer 0-100.')
                }
                elseif ([int]$bo -lt 0 -or [int]$bo -gt 100) {
                    $errors.Add("projectDefaults.backgroundImageOpacity must be 0-100 (got $bo).")
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
            if ($v.ContainsKey('routingMode') -and $null -ne $v.routingMode) {
                # Type check first — truthy-only checks would silently accept
                # `false`/`0`/`@{}` as "unset" and skip the enum validation.
                if (-not ($v.routingMode -is [string])) {
                    $errors.Add('vpn.routingMode must be a string.')
                }
                elseif ([string]$v.routingMode -notin $Script:KnownVpnRoutingModes) {
                    $errors.Add("vpn.routingMode '$($v.routingMode)' must be one of: $($Script:KnownVpnRoutingModes -join ', ').")
                }
            }
            if ($v.ContainsKey('lanCidr') -and $null -ne $v.lanCidr) {
                if (-not ($v.lanCidr -is [string])) {
                    $errors.Add('vpn.lanCidr must be a string.')
                }
                elseif ([string]$v.lanCidr -notmatch $Script:Ipv4CidrRegex) {
                    $errors.Add("vpn.lanCidr '$($v.lanCidr)' must be an IPv4 CIDR like '192.168.1.0/24' (octets 0-255, prefix 0-32).")
                }
            }
            # Cross-field: all-except-lan with a /0 lanCidr would throw at
            # runtime (ConvertTo-InvertedAllowedIPs rejects /0 — it would
            # produce 'AllowedIPs = ' which bricks the tunnel). Catch the
            # combination at profile-load time instead.
            if (($v.ContainsKey('routingMode') -and $v.routingMode -is [string] -and [string]$v.routingMode -eq 'all-except-lan') -and
                ($v.ContainsKey('lanCidr')     -and $v.lanCidr     -is [string] -and [string]$v.lanCidr     -match '^0\.0\.0\.0/0$')) {
                $errors.Add("vpn.lanCidr '0.0.0.0/0' is invalid when vpn.routingMode = 'all-except-lan' (would route nothing).")
            }
        }
    }

    # network: host-VPN connectivity repair for the distro's eth0 (separate from
    # the in-distro WireGuard `vpn` block above). All fields optional; defaults
    # are disabled + no MTU clamp. See modules/Network.psm1.
    if ($Spec.ContainsKey('network') -and $null -ne $Spec.network) {
        if (-not ($Spec.network -is [hashtable])) {
            $errors.Add('network must be an object.')
        }
        else {
            $n = $Spec.network
            if ($n.ContainsKey('enabled') -and $null -ne $n.enabled -and -not ($n.enabled -is [bool])) {
                $errors.Add('network.enabled must be a boolean.')
            }
            if ($n.ContainsKey('mtu') -and $null -ne $n.mtu) {
                if (-not ($n.mtu -is [int] -or $n.mtu -is [long])) {
                    $errors.Add('network.mtu must be an integer.')
                }
                elseif ([int]$n.mtu -lt 576 -or [int]$n.mtu -gt 65535) {
                    $errors.Add("network.mtu '$($n.mtu)' must be between 576 and 65535.")
                }
            }
            if ($n.ContainsKey('hostOffset') -and $null -ne $n.hostOffset) {
                if (-not ($n.hostOffset -is [int] -or $n.hostOffset -is [long])) {
                    $errors.Add('network.hostOffset must be an integer.')
                }
                elseif ([int]$n.hostOffset -lt 1 -or [int]$n.hostOffset -gt 4000) {
                    $errors.Add("network.hostOffset '$($n.hostOffset)' must be between 1 and 4000.")
                }
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
            # Check presence with $null (not truthiness): a present-but-empty
            # mode ('' / $false) is invalid and must surface an error rather than
            # being silently skipped and defaulted to 'ro' at apply time.
            if ($m.ContainsKey('mode') -and $null -ne $m.mode) {
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
            foreach ($bf in @('autoApproveReadOnlyBash','autoApproveProjectWrites','autoApproveBuildCommands','claudelk','alwaysThinkingEnabled','disableBypassPermissionsMode','disableWorkflows')) {
                if ($cs.ContainsKey($bf) -and $null -ne $cs[$bf] -and -not ($cs[$bf] -is [bool])) {
                    $errors.Add("claudeSettings.${bf} must be a boolean.")
                }
            }
            foreach ($sf in @('model','theme','outputStyle')) {
                if ($cs.ContainsKey($sf) -and $cs[$sf] -and -not ($cs[$sf] -is [string])) {
                    $errors.Add("claudeSettings.${sf} must be a string.")
                }
            }
            if ($cs.ContainsKey('editorMode') -and $cs.editorMode -and ([string]$cs.editorMode) -notin $Script:KnownEditorModes) {
                $errors.Add("claudeSettings.editorMode '$($cs.editorMode)' must be one of: $($Script:KnownEditorModes -join ', ').")
            }
            if ($cs.ContainsKey('claudelkEvents') -and $null -ne $cs.claudelkEvents) {
                $evs = @($cs.claudelkEvents)
                foreach ($e in $evs) {
                    if (-not ($e -is [string])) { $errors.Add('claudeSettings.claudelkEvents entries must be strings (event names).') }
                }
            }
            if ($cs.ContainsKey('autoUpdatesChannel') -and $cs.autoUpdatesChannel -and ([string]$cs.autoUpdatesChannel) -notin $Script:KnownAutoUpdateChannels) {
                $errors.Add("claudeSettings.autoUpdatesChannel '$($cs.autoUpdatesChannel)' must be one of: $($Script:KnownAutoUpdateChannels -join ', ').")
            }
            if ($cs.ContainsKey('tui') -and $cs.tui -and ([string]$cs.tui) -notin $Script:KnownTuiModes) {
                $errors.Add("claudeSettings.tui '$($cs.tui)' must be one of: $($Script:KnownTuiModes -join ', ').")
            }
            if ($cs.ContainsKey('defaultShell') -and $cs.defaultShell -and ([string]$cs.defaultShell) -notin $Script:KnownDefaultShells) {
                $errors.Add("claudeSettings.defaultShell '$($cs.defaultShell)' must be one of: $($Script:KnownDefaultShells -join ', ').")
            }
            if ($cs.ContainsKey('cleanupPeriodDays') -and $null -ne $cs.cleanupPeriodDays) {
                $n = $cs.cleanupPeriodDays
                if (-not (($n -is [int]) -or ($n -is [long]) -or ($n -is [double]))) {
                    $errors.Add('claudeSettings.cleanupPeriodDays must be a positive integer.')
                }
                elseif ([int]$n -lt 1) {
                    $errors.Add("claudeSettings.cleanupPeriodDays must be >= 1 (got $n).")
                }
            }
            if ($cs.ContainsKey('permissions') -and $null -ne $cs.permissions) {
                if (-not ($cs.permissions -is [hashtable])) {
                    $errors.Add('claudeSettings.permissions must be an object.')
                }
                else {
                    $sp = $cs.permissions
                    foreach ($af in @('additionalAllow','additionalDeny','additionalAsk','additionalDirectories')) {
                        if ($sp.ContainsKey($af) -and $null -ne $sp[$af]) {
                            $arr = @($sp[$af])
                            foreach ($v in $arr) {
                                if (-not ($v -is [string])) {
                                    $errors.Add("claudeSettings.permissions.${af} entries must be strings.")
                                    break
                                }
                            }
                        }
                    }
                    if ($sp.ContainsKey('defaultMode') -and $sp.defaultMode -and ([string]$sp.defaultMode) -notin $Script:KnownPermissionModes) {
                        $errors.Add("claudeSettings.permissions.defaultMode '$($sp.defaultMode)' must be one of: $($Script:KnownPermissionModes -join ', ').")
                    }
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
        if ($Spec.ContainsKey('claudeShared') -and $Spec.claudeShared) {
            $warnings.Add('Both claudeFile (deprecated) and claudeShared are set; claudeShared wins, claudeFile is ignored.')
        }
    }

    if ($Spec.ContainsKey('claudeShared') -and $null -ne $Spec.claudeShared) {
        if (-not ($Spec.claudeShared -is [hashtable])) {
            $errors.Add('claudeShared must be an object.')
        }
        else {
            $cs = $Spec.claudeShared
            if ($cs.ContainsKey('claudeMd') -and $null -ne $cs.claudeMd) {
                if (-not ($cs.claudeMd -is [hashtable])) {
                    $errors.Add('claudeShared.claudeMd must be an object.')
                }
                else {
                    $md = $cs.claudeMd
                    if (-not $md.ContainsKey('mode') -or [string]::IsNullOrWhiteSpace([string]$md.mode)) {
                        $errors.Add('claudeShared.claudeMd.mode is required.')
                    }
                    elseif ([string]$md.mode -notin $Script:KnownClaudeMdModes) {
                        $errors.Add("claudeShared.claudeMd.mode '$($md.mode)' must be one of: $($Script:KnownClaudeMdModes -join ', ').")
                    }
                    else {
                        $mdMode = [string]$md.mode
                        $hasMdPath = $md.ContainsKey('path') -and -not [string]::IsNullOrWhiteSpace([string]$md.path)
                        if ($mdMode -eq 'custom-path' -and -not $hasMdPath) {
                            $errors.Add('claudeShared.claudeMd.path is required when mode = custom-path.')
                        }
                        elseif ($mdMode -ne 'custom-path' -and $hasMdPath) {
                            $warnings.Add("claudeShared.claudeMd.path is set but mode = '$mdMode'; path will be ignored.")
                        }
                    }
                }
            }
            foreach ($boolKey in @('importSkills', 'importAgents')) {
                if ($cs.ContainsKey($boolKey) -and $null -ne $cs[$boolKey] -and -not ($cs[$boolKey] -is [bool])) {
                    $errors.Add("claudeShared.$boolKey must be true or false.")
                }
            }
            foreach ($pathKey in @('skillsPath', 'agentsPath')) {
                if ($cs.ContainsKey($pathKey) -and $null -ne $cs[$pathKey] -and -not ($cs[$pathKey] -is [string])) {
                    $errors.Add("claudeShared.$pathKey must be a string path.")
                }
            }
            if ($cs.ContainsKey('backup') -and $null -ne $cs.backup) {
                if (-not ($cs.backup -is [hashtable])) {
                    $errors.Add('claudeShared.backup must be an object.')
                }
                else {
                    $bk = $cs.backup
                    foreach ($boolKey in @('onNuke', 'restorePrompt')) {
                        if ($bk.ContainsKey($boolKey) -and $null -ne $bk[$boolKey] -and -not ($bk[$boolKey] -is [bool])) {
                            $errors.Add("claudeShared.backup.$boolKey must be true or false.")
                        }
                    }
                    if ($bk.ContainsKey('retain') -and $null -ne $bk.retain) {
                        $isInt = ($bk.retain -is [int]) -or ($bk.retain -is [long])
                        if (-not $isInt -or [int]$bk.retain -lt 0) {
                            $errors.Add('claudeShared.backup.retain must be an integer >= 0.')
                        }
                    }
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

    # Cross-block conflict: a hostTools wrapper with a drop-in name (e.g. 'gh')
    # would land in /usr/local/bin and shadow an apt-installed copy in /usr/bin
    # from tools.gh. Refuse the ambiguity rather than picking silently. Missing
    # 'enabled' defaults to $true — see Test-ToolEntryEnabled.
    $enabledTools = @{}
    if ($Spec.ContainsKey('tools') -and $Spec.tools -is [hashtable]) {
        foreach ($k in $Spec.tools.Keys) {
            if (Test-ToolEntryEnabled -Entry $Spec.tools[$k]) { $enabledTools[$k] = $true }
        }
    }
    if ($Spec.ContainsKey('hostTools') -and $null -ne $Spec.hostTools -and $enabledTools.Count -gt 0) {
        foreach ($ht in @($Spec.hostTools)) {
            if (-not ($ht -is [hashtable])) { continue }
            $gc = [string]$ht.guestCommand
            if ($gc -and $enabledTools.ContainsKey($gc)) {
                $errors.Add("Conflict: tools.$gc is enabled AND hostTools[] guestCommand='$gc'. Pick one — host-tool wrappers in /usr/local/bin would shadow the WSL install in /usr/bin.")
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
    # Compute the add / remove / remote-change set between desired
    # (profile.projects[]) and actual (state.projects[]), PER HALF. A project is
    # dual-capability: it may have a distro half (`remote` -> bare mirror) and/or
    # a host half (`hostCheckout` -> per-project bin dir + host worktrees), so
    # each half reconciles independently. Change Paths are suffixed with the half
    # (projects.<name>.distro / projects.<name>.host; modify keeps the historical
    # projects.<name>.remote form) and each change carries explicit Name + Half
    # fields so Invoke-ProjectsApply routes without re-parsing the Path.
    #
    # `enabled: false` on a profile entry is treated as "desired absent" for ALL
    # of its halves: the entry stays in the profile (so the user keeps tabColor /
    # defaultBranch / hostShadows / etc.), but reconcile tears the materialized
    # infrastructure down. Flipping back to `enabled: true` (or removing the
    # field) reverses the diff.
    #
    # Capability is detected inline (non-empty remote / hostCheckout) rather than
    # via Projects.Get-ProjectHalves — Projects.psm1 imports this module, so
    # calling back into it would be a circular dependency.
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

    # Desired halves of ENABLED entries, keyed "name|half". Disabled entry names
    # are tracked separately so their materialized halves drive removes.
    $desiredHalves = @{}
    $disabledNames = @{}
    foreach ($p in $desired) {
        $n = [string]$p.name
        if (-not (Test-ProjectEnabled -Entry $p)) { $disabledNames[$n] = $true; continue }
        if ($p.ContainsKey('remote') -and -not [string]::IsNullOrWhiteSpace([string]$p.remote)) {
            $desiredHalves["$n|distro"] = @{ name = $n; half = 'distro'; remote = [string]$p.remote }
        }
        if ($p.ContainsKey('hostCheckout') -and -not [string]::IsNullOrWhiteSpace([string]$p.hostCheckout)) {
            $desiredHalves["$n|host"] = @{ name = $n; half = 'host'; remote = '' }
        }
    }

    # Actual halves keyed "name|type"; type defaults to distro for records that
    # predate the field (and the pure-test fixtures that omit it).
    $actualHalves = @{}
    foreach ($p in $actual) {
        $n = [string]$p.name
        $t = if ($p.ContainsKey('type') -and $p.type) { [string]$p.type } else { 'distro' }
        $actualHalves["$n|$t"] = @{ name = $n; half = $t; remote = [string]$p.remote }
    }

    # Adds + remote-change modifies, driven by the desired halves.
    foreach ($key in $desiredHalves.Keys) {
        $dh = $desiredHalves[$key]
        if (-not $actualHalves.ContainsKey($key)) {
            $note = if ($dh.half -eq 'host') {
                'Will deploy the per-project bin dir (host shadows) into the distro.'
            } else {
                'Will git clone --mirror into the distro.'
            }
            $changes.Add(@{
                Path     = "projects.$($dh.name).$($dh.half)"
                Name     = $dh.name
                Half     = $dh.half
                Action   = 'add'
                Severity = 'safe'
                To       = [string]$dh.remote
                Note     = $note
            })
        }
        elseif ($dh.half -eq 'distro' -and [string]$dh.remote -ne [string]$actualHalves[$key].remote) {
            $changes.Add(@{
                Path     = "projects.$($dh.name).remote"
                Name     = $dh.name
                Half     = 'distro'
                Action   = 'modify'
                Severity = 'destructive'
                From     = [string]$actualHalves[$key].remote
                To       = [string]$dh.remote
                Note     = "Remote changed — remove the project and re-add it."
            })
        }
    }

    # Removes, driven by materialized halves that aren't desired. One loop covers
    # three cases: the whole project was deleted from the profile (drift), the
    # entry was disabled, or just this half was dropped (the other half stays).
    foreach ($key in $actualHalves.Keys) {
        if ($desiredHalves.ContainsKey($key)) { continue }
        $ah = $actualHalves[$key]
        $note = if ($disabledNames.ContainsKey($ah.name)) {
            'Disabled in profile — will delete the materialized infrastructure (mirror or per-project bin dir) AND every session of this half. Profile entry stays; re-enable to restore.'
        } else {
            'Will delete the materialized infrastructure (mirror or per-project bin dir) AND every session of this half.'
        }
        $changes.Add(@{
            Path     = "projects.$($ah.name).$($ah.half)"
            Name     = $ah.name
            Half     = $ah.half
            Action   = 'remove'
            Severity = 'destructive'
            From     = [string]$ah.remote
            Note     = $note
        })
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

function Get-EffectiveClaudeShared {
    # Resolve the effective claudeShared config from a profile spec, mapping the
    # deprecated `claudeFile` block ({mode,path}) onto claudeShared.claudeMd for
    # back-compat. Returns $null when neither block is present. claudeShared wins
    # when both exist. Used by setup / reconcile / the claude-shared verb so the
    # rest of the tool never has to special-case the legacy block.
    [CmdletBinding()]
    param([AllowNull()][hashtable]$Spec)
    if (-not $Spec) { return $null }
    if ($Spec.ContainsKey('claudeShared') -and $Spec.claudeShared -is [hashtable]) {
        return $Spec.claudeShared
    }
    if ($Spec.ContainsKey('claudeFile') -and $Spec.claudeFile -is [hashtable]) {
        $cf = $Spec.claudeFile
        $md = @{ mode = [string]$cf.mode }
        if ($cf.ContainsKey('path') -and $cf.path) { $md['path'] = [string]$cf.path }
        # Legacy claudeFile governed only CLAUDE.md; skills/agents import keeps its
        # own (true) default.
        return @{ claudeMd = $md }
    }
    return $null
}

function Get-ClaudeSharedDiff {
    # Structural diff for the shared account-level Claude store. Content is
    # deliberately NOT diffed: it is seed-once / import-on-demand and editable
    # in-distro (an agent's `#` memory append, a new skill), so comparing against
    # the host and overwriting would clobber those edits. The only thing reconcile
    # proposes is provisioning/repairing the store + group + symlinks when the
    # store isn't ready yet (the common first-run-after-upgrade case).
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Ready)
    $changes = [System.Collections.Generic.List[hashtable]]::new()
    if (-not $Ready) {
        $changes.Add(@{
            Path     = 'claudeShared'
            Action   = 'add'
            Severity = 'safe'
            Note     = 'provision shared account-level Claude store (CLAUDE.md + skills/ + agents/) + symlink into every project user'
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
    Test-ToolEntryEnabled, `
    Test-ProjectEnabled, `
    Get-ProfileFromState, `
    Get-DistroBlockDiff, `
    Get-ProjectsDiff, `
    Get-HostMountsDiff, `
    Get-ToolsDiff, `
    Get-HostToolsDiff, `
    Get-ClaudeFileDiff, `
    Get-EffectiveClaudeShared, `
    Get-ClaudeSharedDiff, `
    Format-Diff
