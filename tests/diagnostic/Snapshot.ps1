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

Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }

if (-not $OutPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutPath = Join-Path $resultsDir "diag-$stamp.txt"
}
else {
    # Caller pointed at an explicit path; mkdir its parent if needed so
    # Set-Content/Add-Content below don't blow up.
    $explicitParent = Split-Path -Parent $OutPath
    if ($explicitParent -and -not (Test-Path $explicitParent)) {
        New-Item -ItemType Directory -Path $explicitParent -Force | Out-Null
    }
}

# Stream-capture by redirecting all output channels to a file. The
# probes use Write-Host; *>&1 promotes that to Output, which |
# Set-Content can write.
$probes = @('Distro.ps1', 'Profile.ps1', 'Vpn.ps1', 'Tools.ps1')

$utcStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
$header = @(
    '# Claudearium diagnostic snapshot',
    "# Generated: $utcStamp",
    "# Distro:    $DistroName",
    "# Host:      $env:COMPUTERNAME (Windows)",
    '',
    '## wsl --list --verbose',
    ''
)
$header | Set-Content -LiteralPath $OutPath -Encoding UTF8

# wsl --list output goes to stdout; capture and append.
(& wsl.exe --list --verbose 2>&1) | Out-String | Add-Content -LiteralPath $OutPath -Encoding UTF8
# Explicit -Encoding UTF8 on every Add-Content above keeps PS 5.1 (where
# the default differs) from writing mixed UTF-8 / UTF-16 chunks into the
# same file.

foreach ($p in $probes) {
    $file = Join-Path $diagDir $p
    "" | Add-Content -LiteralPath $OutPath -Encoding UTF8
    "## $p" | Add-Content -LiteralPath $OutPath -Encoding UTF8
    "" | Add-Content -LiteralPath $OutPath -Encoding UTF8
    try {
        $captured = & $file -DistroName $DistroName *>&1 | Out-String
        $captured | Add-Content -LiteralPath $OutPath -Encoding UTF8
    }
    catch {
        "ERROR running $p`: $($_.Exception.Message)" | Add-Content -LiteralPath $OutPath -Encoding UTF8
    }
}

# Latest test-run JSON, if any. This is the manifest of what was tested
# and how it went — useful context when triaging "X is broken on my
# machine" reports.
$latestRun = Get-ChildItem -Path $resultsDir -Filter 'run-*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
"" | Add-Content -LiteralPath $OutPath -Encoding UTF8
'## latest run-*.json' | Add-Content -LiteralPath $OutPath -Encoding UTF8
"" | Add-Content -LiteralPath $OutPath -Encoding UTF8
if ($latestRun) {
    "Source: $($latestRun.FullName) (modified $($latestRun.LastWriteTime.ToString('o')))" |
        Add-Content -LiteralPath $OutPath -Encoding UTF8
    "" | Add-Content -LiteralPath $OutPath -Encoding UTF8
    Get-Content -LiteralPath $latestRun.FullName | Add-Content -LiteralPath $OutPath -Encoding UTF8
}
else {
    '(no prior run-*.json under tests/results/ — runner has not been invoked yet)' |
        Add-Content -LiteralPath $OutPath -Encoding UTF8
}

# Scrub identifying values out of the assembled file. The probes write
# things like `# Host: $env:COMPUTERNAME`, `Source: <full path to run-*.json>`,
# and Profile.ps1 prints the default-profile path under the user's
# %LOCALAPPDATA% — all of which would leak into a public bug report. The
# scrubber catches USERPROFILE / LOCALAPPDATA / APPDATA / repo-root /
# USERNAME / COMPUTERNAME in raw, JSON-escaped, and forward-slash forms.
$snapshotContent = Get-Content -LiteralPath $OutPath -Raw -Encoding UTF8
$scrubbed = ConvertTo-ShareableContent -Content $snapshotContent
$scrubbed | Set-Content -LiteralPath $OutPath -Encoding UTF8

Write-Host ''
Write-Host "  Snapshot written: $OutPath" -ForegroundColor Green
Write-Host '  Identifying values (username, paths, host name) have been scrubbed.' -ForegroundColor DarkGray
Write-Host '  Attach this file to bug reports.' -ForegroundColor DarkGray
return $OutPath
