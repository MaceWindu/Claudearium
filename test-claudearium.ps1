#!/usr/bin/env pwsh
# Claudearium test runner. Single entry point for the unified test dashboard,
# automatic Pester runs, manual prompts, and read-only diagnostics. Run with no
# args for the dashboard; see docs/testing.md (added in Step 6) for full usage.
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$Manual,
    [switch]$Diag,
    [switch]$Snapshot,
    [switch]$ParseCheck,
    [string]$Only,
    [string]$Target,
    [string]$TestDistroName,
    [string]$WgConfigPath,
    [string]$ResultsJson,
    [string]$SnapshotPath,
    [switch]$CI,
    [switch]$NonInteractive,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoRoot = $PSScriptRoot

# CI mode implies NonInteractive — there's no human at the keyboard to answer prompts.
if ($CI) { $NonInteractive = $true }

Import-Module (Join-Path $Script:RepoRoot 'tests\lib\Dashboard.psm1')    -Force
Import-Module (Join-Path $Script:RepoRoot 'tests\lib\TestRegistry.psm1') -Force
Import-Module (Join-Path $Script:RepoRoot 'tests\lib\Diagnostic.psm1')   -Force
Import-Module (Join-Path $Script:RepoRoot 'tests\lib\TestDistro.psm1')   -Force

function Show-RunnerHelp {
    @"
test-claudearium.ps1 [options]

Run modes:
  (no args)            Interactive test dashboard.
  -Auto                Run all automatic tests, then exit.
  -Manual              Run all manual tests, then exit.
  -Diag                Run read-only diagnostics to stdout, then exit.
  -Snapshot            Write a combined diagnostic snapshot file
                       (tests/results/diag-*.txt by default; pass
                       -SnapshotPath to override). For sharing in bug
                       reports.
  -ParseCheck          Parse every .ps1/.psm1 under the repo; non-zero exit on errors.

Filtering:
  -Only <group>        Restrict the run to a manifest group. Valid
                       combinations:
                         -Auto   -Only pure | distro
                         -Manual -Only manual
                       Other combinations are rejected because they'd
                       match zero tests (e.g., `-Auto -Only manual`).
                       Ignored by -Diag / -Snapshot / -ParseCheck and
                       by the interactive dashboard.

Options:
  -Target <real|test>       For -Diag / -Snapshot: pick which distro to probe (default: real).
  -TestDistroName <name>    Ephemeral test distro name (default: 'claudearium-test').
  -WgConfigPath <path>      Real WireGuard config; enables full VPN connectivity tests.
  -ResultsJson <path>       Where to write the run summary JSON.
  -SnapshotPath <path>      Where to write the -Snapshot file (default: tests/results/diag-<stamp>.txt).
  -CI                       CI mode: NonInteractive, skip manual tests, non-zero on any failure.
  -NonInteractive           Suppress prompts; use defaults / skip manual tests.
  -Help                     Show this help.

Examples:
  .\test-claudearium.ps1
  .\test-claudearium.ps1 -Auto -Only pure
  .\test-claudearium.ps1 -CI -Only distro
  .\test-claudearium.ps1 -Diag -Target real
  .\test-claudearium.ps1 -Snapshot
  .\test-claudearium.ps1 -ParseCheck
"@
}

function Invoke-ParseCheck {
    Write-Host '  Parsing .ps1 and .psm1 files...' -ForegroundColor Cyan
    $files = Get-ChildItem -Path $Script:RepoRoot -Recurse -Include *.ps1,*.psm1 -File |
        Where-Object {
            $_.FullName -notmatch '\\tests\\\.cache\\' -and
            $_.FullName -notmatch '\\tests\\results\\'
        }
    $bad = 0
    foreach ($f in $files) {
        $errors = $null; $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors) {
            Write-Host "  FAIL: $($f.FullName)" -ForegroundColor Red
            foreach ($e in $errors) {
                Write-Host "    line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
            }
            $bad++
        }
    }
    if ($bad -eq 0) {
        Write-Host ("  OK: {0} files parsed cleanly." -f $files.Count) -ForegroundColor Green
        return 0
    }
    Write-Host ("  {0} file(s) failed to parse." -f $bad) -ForegroundColor Red
    return 1
}

if ($Help) { Show-RunnerHelp; exit 0 }

if ($ParseCheck) { exit (Invoke-ParseCheck) }

$validGroups = @('pure','distro','manual')
if ($Only -and $Only -notin $validGroups) {
    Write-Host "Unknown -Only '$Only'. Known groups: $($validGroups -join ', ')" -ForegroundColor Red
    exit 64
}
if (-not $TestDistroName) { $TestDistroName = (Get-TestDistroDefaultName) }

$runAuto     = $Auto
$runManual   = $Manual
$runDiag     = $Diag
$runSnapshot = $Snapshot
$runDash     = -not ($runAuto -or $runManual -or $runDiag -or $runSnapshot)

# Combining mode switches is almost always a CLI mistake. Refuse rather
# than silently picking one. The two-step form below is intentional: a
# single `$a, $b, $c | Where-Object {...}` expression has ambiguous
# parser precedence (some reviewers read it as piping only $c), so we
# build the array first then filter it.
$modeFlags = @($runAuto, $runManual, $runDiag, $runSnapshot)
$modeCount = @($modeFlags | Where-Object { $_ }).Count
if ($modeCount -gt 1) {
    Write-Host 'Specify at most one of -Auto / -Manual / -Diag / -Snapshot (or none for the interactive dashboard).' -ForegroundColor Red
    exit 64
}

# -Only must match the kind of tests the chosen mode actually runs.
# -Auto selects Kind='auto' (pure or distro). -Manual selects
# Kind='manual'. A mismatched -Only would silently match zero tests.
if ($Only) {
    if ($runAuto -and $Only -eq 'manual') {
        Write-Host "-Auto runs Kind='auto' tests; -Only manual would match zero. Did you mean '-Manual -Only manual'?" -ForegroundColor Red
        exit 64
    }
    if ($runManual -and $Only -in @('pure','distro')) {
        Write-Host "-Manual runs Kind='manual' tests; -Only '$Only' would match zero. Did you mean '-Auto -Only $Only'?" -ForegroundColor Red
        exit 64
    }
}

if ($runDash) {
    if ($NonInteractive) { Show-RunnerHelp; exit 0 }
    Show-TestDashboard -TestDistroName $TestDistroName -WgConfigPath $WgConfigPath
    exit 0
}

if ($runDiag -or $runSnapshot) {
    if (-not $Target) { $Target = 'real' }
    if ($Target -notin @('real','test')) {
        Write-Host "Invalid -Target '$Target' (expected 'real' or 'test')." -ForegroundColor Red
        exit 64
    }
    $distroForDiag = if ($Target -eq 'test') { $TestDistroName } else { Get-RealDistroName }
    if ($runSnapshot) {
        # Snapshot writes a single timestamped file aggregating every
        # probe + wsl --list + the latest run JSON, for sharing in bug
        # reports.
        [void](Invoke-DiagnosticSnapshot -DistroName $distroForDiag -OutPath $SnapshotPath)
    }
    else {
        Invoke-Diagnostic -Target $Target -DistroName $distroForDiag
    }
    exit 0
}

# -Auto / -Manual
$kind = if ($runAuto) { 'auto' } else { 'manual' }
$tests = @(Select-Tests -Kind $kind -IncludeDistro -IncludeVpnReal:([bool]$WgConfigPath))
if ($Only) { $tests = @($tests | Where-Object { $_.Group -eq $Only }) }

if ($tests.Count -eq 0) {
    Write-Host '  No tests matched the given filters.' -ForegroundColor Yellow
    exit 0
}

$summary = Invoke-TestRun `
    -Tests $tests `
    -TestDistroName $TestDistroName `
    -CI:$CI `
    -NonInteractive:$NonInteractive `
    -ResultsJsonPath $ResultsJson `
    -WgConfigPath $WgConfigPath

$autoFailed = if ($summary -and $summary.autoSummary) { $summary.autoSummary.failed } else { 0 }
$manFailed  = if ($summary) { $summary.manualSummary.failed } else { 0 }

Write-Host ''
if ($summary -and $summary.autoSummary) {
    Write-Host ("  AUTO:   {0} passed, {1} failed, {2} skipped" -f `
        $summary.autoSummary.passed, $summary.autoSummary.failed, $summary.autoSummary.skipped)
}
if ($summary) {
    Write-Host ("  MANUAL: {0} passed, {1} failed, {2} skipped" -f `
        $summary.manualSummary.passed, $summary.manualSummary.failed, $summary.manualSummary.skipped)
}

if ($CI -and (($autoFailed + $manFailed) -gt 0)) { exit 1 }
exit 0
