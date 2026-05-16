# ToolUpdates.ps1 — latest-version cache inventory. Prints what the
# %LOCALAPPDATA%\claudearium\tool-versions.json cache currently holds plus
# its age, and flags rows where the installed version differs from the
# cached latest. Read-only — does not refresh.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DistroName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')
Import-Module (Join-Path $repoRoot 'modules\Tools.psm1')
Import-Module (Join-Path $repoRoot 'modules\ToolUpdates.psm1')

Write-Host ''
Write-Host "== Tool updates cache (distro: $DistroName) ==" -ForegroundColor Cyan

$cachePath = Get-ToolUpdatesCachePath
$lockPath  = Get-ToolUpdatesLockPath
Write-Host ("  cache path: {0}" -f $cachePath) -ForegroundColor DarkGray
Write-Host ("  lock path:  {0}" -f $lockPath)  -ForegroundColor DarkGray

$cache = Read-ToolUpdatesCache
if (-not $cache) {
    Write-Host '  (cache file is missing or unparseable)' -ForegroundColor Yellow
    Write-Host '  Run `.\claudearium.ps1 tools refresh-latest` to seed it.' -ForegroundColor DarkGray
    return
}
$age = $null
if ($cache.ContainsKey('checkedAt') -and $cache.checkedAt) {
    try {
        $checkedAt = [datetime]::Parse([string]$cache.checkedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $age = ([datetime]::UtcNow - $checkedAt)
    } catch { }
}
$ageLabel = if ($age) { ('{0:0}h{1:00}m ago' -f $age.TotalHours, $age.Minutes) } else { '(unknown)' }
$stale = Test-ToolUpdatesCacheStale
Write-Host ("  checkedAt: {0}  ({1})" -f ($cache.checkedAt), $ageLabel) -ForegroundColor DarkGray
Write-Host ("  stale:     {0}" -f $stale) -ForegroundColor (if ($stale) { 'Yellow' } else { 'DarkGray' })

if (-not $cache.ContainsKey('tools') -or -not ($cache.tools -is [hashtable]) -or $cache.tools.Count -eq 0) {
    Write-Host '  (no per-tool entries in cache)' -ForegroundColor Yellow
    return
}

$installedByName = @{}
if (Test-DistroExists -Name $DistroName) {
    foreach ($a in (Get-ToolsActualFromDistro -DistroName $DistroName)) {
        $installedByName[[string]$a.name] = $a
    }
}

Write-Host ''
Write-Host ('  {0,-12} {1,-22} {2,-22} {3,-18} {4}' -f 'Tool','Installed','Latest','Status','Probe error')
Write-Host ('  {0,-12} {1,-22} {2,-22} {3,-18} {4}' -f '----','---------','------','------','-----------')
foreach ($name in (Get-ToolCatalog)) {
    $latest = $null; $err = $null
    if ($cache.tools.ContainsKey($name)) {
        $entry = $cache.tools[$name]
        if ($entry.ContainsKey('latest')) { $latest = [string]$entry.latest }
        if ($entry.ContainsKey('error'))  { $err    = [string]$entry.error }
    }
    $inst = $null
    if ($installedByName.ContainsKey($name) -and $installedByName[$name].installed) {
        $inst = [string]$installedByName[$name].version
    }
    $status = Compare-ToolVersion -Installed $inst -Latest $latest
    $color = switch ($status) {
        'update-available' { 'Yellow' }
        'unknown'          { 'DarkGray' }
        default            { 'Gray' }
    }
    $line = '  {0,-12} {1,-22} {2,-22} {3,-18} {4}' -f $name, ($inst ?? ''), ($latest ?? ''), $status, ($err ?? '')
    Write-Host $line -ForegroundColor $color
}
