# Tools.ps1 — installed-tool inventory. Cross-references the profile's
# enabled set against the distro's actual installed set; flags drift.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$DistroName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Import-Module (Join-Path $repoRoot 'modules\Profile.psm1') -Force
Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')    -Force
Import-Module (Join-Path $repoRoot 'modules\Tools.psm1')  -Force

Write-Host ''
Write-Host "== Tools (distro: $DistroName) ==" -ForegroundColor Cyan

if (-not (Test-DistroExists -Name $DistroName)) {
    Write-Host '  (distro not registered)' -ForegroundColor Yellow
    return
}

$desired = @{}
$path = Get-DefaultProfilePath
if (Test-Path $path) {
    try {
        $spec = Read-Profile -Path $path
        if ($spec.ContainsKey('tools')) { $desired = $spec.tools }
    } catch { }
}

$actual = Get-ToolsActualFromDistro -DistroName $DistroName
$actualByName = @{}; foreach ($a in $actual) { $actualByName[[string]$a.name] = $a }

Write-Host ('  {0,-12} {1,-10} {2,-10} {3}' -f 'Tool','Enabled','Installed','Version')
Write-Host ('  {0,-12} {1,-10} {2,-10} {3}' -f '----','-------','---------','-------')
foreach ($name in (Get-ToolCatalog)) {
    $en = if ($desired.ContainsKey($name) -and $desired[$name].enabled) { 'yes' } else { 'no' }
    $a  = if ($actualByName.ContainsKey($name)) { $actualByName[$name] } else { $null }
    $inst = if ($a -and $a.installed) { 'yes' } else { 'no' }
    $ver  = if ($a -and $a.version) { [string]$a.version } else { '' }
    $line = '  {0,-12} {1,-10} {2,-10} {3}' -f $name, $en, $inst, $ver
    $color = if ($en -eq 'yes' -and $inst -eq 'no') { 'Yellow' } else { 'Gray' }
    Write-Host $line -ForegroundColor $color
}
