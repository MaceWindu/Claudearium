# Snapshot.ps1 — full diagnostic dump for inclusion in bug reports.
# Captures the output of every other diagnostic probe (Distro, Profile,
# Vpn, Tools) plus the WSL list and the run JSON manifest. Writes to a
# file under tests/results/diag-YYYYMMDD-HHmmss.txt by default and
# returns the path.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DistroName,
    [string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$diagDir    = Join-Path $repoRoot 'tests\diagnostic'
$resultsDir = Join-Path $repoRoot 'tests\results'
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }

if (-not $OutPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutPath = Join-Path $resultsDir "diag-$stamp.txt"
}

# Stream-capture by redirecting all output channels to a file. The
# probes use Write-Host; *>&1 promotes that to Output, which |
# Set-Content can write.
$probes = @('Distro.ps1', 'Profile.ps1', 'Vpn.ps1', 'Tools.ps1')

$header = @(
    '# Claudearium diagnostic snapshot',
    "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ssZ')",
    "# Distro:    $DistroName",
    "# Host:      $env:COMPUTERNAME (Windows)",
    '',
    '## wsl --list --verbose',
    ''
)
$header | Set-Content -LiteralPath $OutPath -Encoding UTF8

# wsl --list output goes to stdout; capture and append.
(& wsl.exe --list --verbose 2>&1) | Out-String | Add-Content -LiteralPath $OutPath -Encoding UTF8

foreach ($p in $probes) {
    $file = Join-Path $diagDir $p
    "" | Add-Content -LiteralPath $OutPath
    "## $p" | Add-Content -LiteralPath $OutPath
    "" | Add-Content -LiteralPath $OutPath
    try {
        $captured = & $file -DistroName $DistroName *>&1 | Out-String
        $captured | Add-Content -LiteralPath $OutPath -Encoding UTF8
    }
    catch {
        "ERROR running $p`: $($_.Exception.Message)" | Add-Content -LiteralPath $OutPath -Encoding UTF8
    }
}

Write-Host ''
Write-Host "  Snapshot written: $OutPath" -ForegroundColor Green
Write-Host '  Attach this file to bug reports.' -ForegroundColor DarkGray
return $OutPath
