# Profile.ps1 — read-only profile health probes. Validates the user's
# default profile and computes per-block diff against the distro's
# current state without applying anything.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DistroName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')
Import-Module (Join-Path $repoRoot 'modules\State.psm1')
Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')
Import-Module (Join-Path $repoRoot 'modules\Mounts.psm1')
Import-Module (Join-Path $repoRoot 'modules\Tools.psm1')
Import-Module (Join-Path $repoRoot 'modules\Projects.psm1')
Import-Module (Join-Path $repoRoot 'modules\HostTools.psm1')

Write-Host ''
Write-Host "== Profile (distro: $DistroName) ==" -ForegroundColor Cyan

$path = Get-DefaultProfilePath
Write-Host ("  path:             {0}" -f $path)
if (-not (Test-Path $path)) {
    Write-Host '  (no profile written yet)' -ForegroundColor Yellow
    return
}

try {
    $spec = Read-Profile -Path $path
}
catch {
    Write-Host ("  ERROR reading profile: {0}" -f $_.Exception.Message) -ForegroundColor Red
    return
}

$v = Test-Profile -Spec $spec
$validity = if ($v.IsValid) { 'valid' } else { "INVALID ($($v.Errors.Count) error(s))" }
Write-Host ("  validation:       {0}" -f $validity)
foreach ($e in $v.Errors)   { Write-Host "    error:   $e"   -ForegroundColor Red }
foreach ($w in $v.Warnings) { Write-Host "    warning: $w" -ForegroundColor DarkYellow }

if (-not $v.IsValid) { return }
if (-not (Test-DistroExists -Name $DistroName)) {
    Write-Host '  (distro missing — skipping per-block diff)' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host '  Per-block diff (desired vs actual):'

# Distro block: compare against state.json
$state = if (Test-State -DistroName $DistroName) { Read-State -DistroName $DistroName } else { @{ distro = ''; installPath = '' } }
$distroDiff = Get-DistroBlockDiff -DesiredDistro $spec.distro -CurrentState $state
$distroChangeCount = ($distroDiff.Changes | Measure-Object).Count
Write-Host ("    distro:         {0} change(s){1}" -f $distroChangeCount, $(if ($distroDiff.HasDestructive) { ' [DESTRUCTIVE]' } else { '' }))
foreach ($c in $distroDiff.Changes) { Write-Host ("      {0}: {1}" -f $c.Path, $c.Note) -ForegroundColor DarkYellow }

# Projects
$desiredProjects = @(); if ($spec.ContainsKey('projects') -and $spec.projects) { $desiredProjects = @($spec.projects) }
$actualProjects = Get-ProjectsActualFromDistro -DistroName $DistroName
$projectsDiff = Get-ProjectsDiff -DesiredProjects $desiredProjects -ActualProjects $actualProjects
$projChangeCount = ($projectsDiff.Changes | Measure-Object).Count
Write-Host ("    projects:       {0} change(s)" -f $projChangeCount)
foreach ($c in $projectsDiff.Changes) { Write-Host ("      {0}: {1}" -f $c.Path, $c.Action) -ForegroundColor DarkYellow }

# Mounts
$desiredMounts = @(); if ($spec.ContainsKey('hostMounts') -and $spec.hostMounts) { $desiredMounts = @($spec.hostMounts) }
$actualMounts = Get-HostMountsActualFromDistro -DistroName $DistroName
$mountsDiff = Get-HostMountsDiff -DesiredMounts $desiredMounts -ActualMounts $actualMounts
$mountChangeCount = ($mountsDiff.Changes | Measure-Object).Count
Write-Host ("    host mounts:    {0} change(s)" -f $mountChangeCount)
foreach ($c in $mountsDiff.Changes) { Write-Host ("      {0}: {1}" -f $c.Path, $c.Action) -ForegroundColor DarkYellow }

# Tools
$desiredTools = if ($spec.ContainsKey('tools')) { $spec.tools } else { @{} }
$actualTools = Get-ToolsActualFromDistro -DistroName $DistroName
$toolsDiff = Get-ToolsDiff -DesiredTools $desiredTools -ActualTools $actualTools
$toolsChangeCount = ($toolsDiff.Changes | Measure-Object).Count
Write-Host ("    tools:          {0} change(s)" -f $toolsChangeCount)
foreach ($c in $toolsDiff.Changes) { Write-Host ("      {0}: {1}" -f $c.Path, $c.Action) -ForegroundColor DarkYellow }

# Host tools
$desiredHostTools = @(); if ($spec.ContainsKey('hostTools') -and $spec.hostTools) { $desiredHostTools = @($spec.hostTools) }
$actualHostTools = Get-HostToolsActualFromDistro -DistroName $DistroName
$htDiff = Get-HostToolsDiff -DesiredTools $desiredHostTools -ActualTools $actualHostTools
$htChangeCount = ($htDiff.Changes | Measure-Object).Count
Write-Host ("    host tools:     {0} change(s)" -f $htChangeCount)
foreach ($c in $htDiff.Changes) { Write-Host ("      {0}: {1}" -f $c.Path, $c.Action) -ForegroundColor DarkYellow }
