# WinTerminal.psm1
# Host-side Windows Terminal profile management. The `tabColor` per-project
# option works as a `wt.exe new-tab --tabColor` flag, but icon / background
# image / background-image opacity have NO wt.exe CLI equivalent — they exist
# only as Windows Terminal *profile* settings. So for any project that sets an
# icon or backgroundImage we generate a hidden WT profile and launch its
# sessions with `wt nt -p "<profile>"` (the appended `-- wsl.exe …` still
# overrides the commandline while the profile supplies the appearance).
#
# Delivery is a JSON *fragment* under WT's fixed fragments directory
# (%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\Claudearium\). We can't
# put it under claudearium's own settings folder — WT only scans its own
# fragment locations. Caveat: WT picks up fragment changes only on next launch
# (fragments are not hot-reloaded), so callers print a "restart Windows
# Terminal" note when Update-WtFragment reports a change.
#
# Public surface:
#   Get-WtFragmentPath                                   — the fragment file path
#   Get-ProjectWtProfileName       -Name                 — deterministic "Claudearium - <name>"
#   Test-ProjectHasWtAppearance    -ProjectSpec          — has a non-empty icon or backgroundImage?
#   Resolve-EffectiveBackgroundOpacity -ProjectSpec -ProfileDefaults
#                                                        — percent: project -> defaults -> 100
#   Build-WtFragment               -Spec                 — { profiles = @(…) } object (pure)
#   Update-WtFragment              -Spec [-Path]         — write/delete the fragment; returns
#                                                          @{ Changed; Path; ProfileCount; Removed }
#
# This module is intentionally free of cross-module deps: it operates on a
# profile hashtable handed in by the caller (it does not read the profile file
# itself) plus host file IO, so it stays unit-testable without WSL or state.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Source label baked into the fragment so WT derives a stable per-profile GUID
# from (source, name) across regenerations. Also used as the Fragments subdir.
$Script:WtFragmentAppName = 'Claudearium'

function Get-WtFragmentPath {
    # Path to the generated fragment. WT reads per-user fragments from this fixed
    # location regardless of Store vs unpackaged install.
    [CmdletBinding()] param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve the Windows Terminal fragment path.' }
    return (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\$Script:WtFragmentAppName\claudearium.json")
}

function Get-ProjectWtProfileName {
    # Deterministic WT profile name for a project. Project names match
    # ^[A-Za-z0-9._-]+$, so the result is safe both as a JSON value and as a
    # `-p` argument with no quoting surprises.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return "$Script:WtFragmentAppName - $Name"
}

function Test-ProjectHasWtAppearance {
    # A project gets a generated WT profile iff it sets an icon or a background
    # image. (Opacity alone is meaningless without a background image.)
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$ProjectSpec)
    if ($null -eq $ProjectSpec -or -not ($ProjectSpec -is [hashtable])) { return $false }
    $hasIcon = $ProjectSpec.ContainsKey('icon') -and -not [string]::IsNullOrWhiteSpace([string]$ProjectSpec.icon)
    $hasBg   = $ProjectSpec.ContainsKey('backgroundImage') -and -not [string]::IsNullOrWhiteSpace([string]$ProjectSpec.backgroundImage)
    return ($hasIcon -or $hasBg)
}

function Resolve-EffectiveBackgroundOpacity {
    # Resolve a project's background-image opacity PERCENT: per-project value
    # wins, else projectDefaults, else 100 (solid). First instance of the
    # global-default-with-per-project-override pattern in the codebase.
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$ProjectSpec,
        [Parameter()][AllowNull()]$ProfileDefaults
    )
    if ($ProjectSpec -is [hashtable] -and $ProjectSpec.ContainsKey('backgroundImageOpacity') -and $null -ne $ProjectSpec.backgroundImageOpacity) {
        return [int]$ProjectSpec.backgroundImageOpacity
    }
    if ($ProfileDefaults -is [hashtable] -and $ProfileDefaults.ContainsKey('backgroundImageOpacity') -and $null -ne $ProfileDefaults.backgroundImageOpacity) {
        return [int]$ProfileDefaults.backgroundImageOpacity
    }
    return 100
}

function Build-WtFragment {
    # Pure: turn a profile spec into a WT fragment object { profiles = @(…) }.
    # Emits one hidden profile per project that has an icon or backgroundImage.
    # backgroundImageOpacity is a WT float 0.0-1.0, so percent/100. useAcrylic is
    # forced off because background images don't render with acrylic on.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Spec)

    $defaults = if ($Spec.ContainsKey('projectDefaults')) { $Spec.projectDefaults } else { $null }
    $projects = @(); if ($Spec.ContainsKey('projects') -and $Spec.projects) { $projects = @($Spec.projects) }

    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $projects) {
        if (-not (Test-ProjectHasWtAppearance -ProjectSpec $p)) { continue }
        $entry = [ordered]@{
            name   = Get-ProjectWtProfileName -Name ([string]$p.name)
            hidden = $true
        }
        if ($p.ContainsKey('icon') -and -not [string]::IsNullOrWhiteSpace([string]$p.icon)) {
            $entry['icon'] = [string]$p.icon
        }
        if ($p.ContainsKey('backgroundImage') -and -not [string]::IsNullOrWhiteSpace([string]$p.backgroundImage)) {
            $pct = Resolve-EffectiveBackgroundOpacity -ProjectSpec $p -ProfileDefaults $defaults
            $entry['backgroundImage']        = [string]$p.backgroundImage
            $entry['useAcrylic']             = $false
            $entry['backgroundImageOpacity'] = [double]($pct / 100.0)
        }
        $profiles.Add([pscustomobject]$entry)
    }
    return @{ profiles = @($profiles) }
}

function Update-WtFragment {
    # Idempotently write (or delete) the fragment. Returns
    # @{ Changed; Path; ProfileCount; Removed }. When no project has appearance,
    # the fragment is deleted so stale profiles don't linger. -Path is for tests.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [string]$Path
    )
    if (-not $Path) { $Path = Get-WtFragmentPath }
    $fragment = Build-WtFragment -Spec $Spec
    # Null-safe: @($null).Count is 1, which would flip a delete into a write.
    $count    = if ($null -ne $fragment.profiles) { @($fragment.profiles).Count } else { 0 }

    $existing = ''
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = (Get-Content -LiteralPath $Path -Raw)
    }

    if ($count -eq 0) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Remove-Item -LiteralPath $Path -Force
            return @{ Changed = $true; Path = $Path; ProfileCount = 0; Removed = $true }
        }
        return @{ Changed = $false; Path = $Path; ProfileCount = 0; Removed = $false }
    }

    $json = $fragment | ConvertTo-Json -Depth 8
    if (($existing.Trim()) -eq ($json.Trim())) {
        return @{ Changed = $false; Path = $Path; ProfileCount = $count; Removed = $false }
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    # Atomic .tmp-then-Move (mirrors Write-Profile) so a kill mid-write can't
    # leave WT a truncated fragment.
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return @{ Changed = $true; Path = $Path; ProfileCount = $count; Removed = $false }
}

Export-ModuleMember -Function `
    Get-WtFragmentPath, `
    Get-ProjectWtProfileName, `
    Test-ProjectHasWtAppearance, `
    Resolve-EffectiveBackgroundOpacity, `
    Build-WtFragment, `
    Update-WtFragment
