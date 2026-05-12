# Dashboard.psm1
# Interactive selection dashboard for test-claudearium.ps1, plus the shared
# Invoke-TestRun entry point used by both the dashboard and the CLI flags.
#
# Mirrors the UX of Invoke-CentralDashboard in claudearium.ps1:
#   - while($true) loop, fresh status header each iteration
#   - single-letter shortcuts, 'q'/blank to quit
#   - the top-level menu uses Read-Host (matching the central dashboard's own
#     idiom); structured prompts (yes/no, choices, multi-select, tab color)
#     route through modules/UI.psm1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LibDir   = $PSScriptRoot
$Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Import-Module (Join-Path $Script:LibDir 'TestRegistry.psm1') -Force
Import-Module (Join-Path $Script:LibDir 'PesterRunner.psm1') -Force
Import-Module (Join-Path $Script:LibDir 'TestDistro.psm1')   -Force
Import-Module (Join-Path $Script:LibDir 'ManualTest.psm1')   -Force
Import-Module (Join-Path $Script:LibDir 'Diagnostic.psm1')   -Force
Import-Module (Join-Path $Script:RepoRoot 'modules\UI.psm1')      -Force
Import-Module (Join-Path $Script:RepoRoot 'modules\Wsl.psm1')     -Force
Import-Module (Join-Path $Script:RepoRoot 'modules\Profile.psm1') -Force

function Show-TestDashboard {
    [CmdletBinding()]
    param(
        [string]$TestDistroName = (Get-TestDistroDefaultName),
        [string]$WgConfigPath
    )
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: tests ===' -ForegroundColor Cyan
        Write-Host ("  Test distro:    {0}  (created+destroyed per run)" -f $TestDistroName)
        $vpnText = if ($WgConfigPath) { "real ($WgConfigPath)" } else { 'dummy (no -WgConfigPath) - connectivity probes will skip' }
        Write-Host ("  VPN config:     {0}" -f $vpnText)

        $auto   = Select-Tests -Kind 'auto'   -IncludeDistro -IncludeVpnReal:([bool]$WgConfigPath)
        $manual = Select-Tests -Kind 'manual' -IncludeDistro -IncludeVpnReal:([bool]$WgConfigPath)
        $autoEst = Format-Duration -Seconds (Get-EstSeconds -Tests $auto)
        $manEst  = Format-Duration -Seconds (Get-EstSeconds -Tests $manual)

        $resultsDir = Join-Path $Script:RepoRoot 'tests\results'
        $lastRun = $null
        if (Test-Path $resultsDir) {
            $lastRun = Get-ChildItem -Path $resultsDir -Filter 'run-*.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        $lastText = if ($lastRun) { $lastRun.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '(none)' }
        Write-Host ("  Last run:       {0}" -f $lastText)
        Write-Host ''
        Write-Host ('  a  run all automatic tests           (~{0}, {1} tests)' -f $autoEst, $auto.Count)
        Write-Host ('  m  run all manual tests              (~{0}, {1} prompts)' -f $manEst, $manual.Count)
        Write-Host '  s  select tests / groups             (interactive tree)'
        Write-Host '  d  diagnostics                       (read-only health probes)'
        Write-Host '  l  show last-run results'
        Write-Host '  q  quit'

        $a = (Read-Host '  >').Trim().ToLowerInvariant()
        if ($a -in @('q','')) { return }
        switch ($a) {
            'a' { [void](Invoke-TestRun -Tests $auto   -TestDistroName $TestDistroName -WgConfigPath $WgConfigPath) }
            'm' { [void](Invoke-TestRun -Tests $manual -TestDistroName $TestDistroName -WgConfigPath $WgConfigPath) }
            's' {
                $picked = Show-TestSelection -All (Get-TestManifest)
                if ($picked -and $picked.Count -gt 0) {
                    [void](Invoke-TestRun -Tests $picked -TestDistroName $TestDistroName -WgConfigPath $WgConfigPath)
                }
            }
            'd' { Invoke-DiagnosticMenu -TestDistroName $TestDistroName }
            'l' { Show-LastRunResults }
            default { Write-Host '  unknown command.' -ForegroundColor Yellow }
        }
    }
}

function Show-TestSelection {
    param([Parameter(Mandatory)][hashtable[]]$All)
    if (-not $All -or $All.Count -eq 0) {
        Write-Host '  No tests registered.' -ForegroundColor Yellow
        return @()
    }
    $opts = @()
    foreach ($t in $All) {
        $tag  = if ($t.Kind -eq 'manual') { '[MANUAL]' } else { '[AUTO]  ' }
        $hint = '{0} {1} (~{2})' -f $tag, $t.Id, (Format-Duration -Seconds $t.EstSeconds)
        $opts += @{ Name = $t.Id; Selected = $false; Hint = $hint }
    }
    $picked = Read-Multi -Prompt 'Select tests (toggle by number; Enter=accept):' -Options $opts
    return @($All | Where-Object { $_.Id -in $picked })
}

function Get-RealDistroName {
    $path = Get-DefaultProfilePath
    if (Test-Path $path) {
        try {
            $spec = Read-Profile -Path $path
            if ($spec -and $spec.ContainsKey('distro') -and $spec.distro.ContainsKey('name')) {
                return [string]$spec.distro.name
            }
        } catch { }
    }
    return 'claudearium'
}

function Invoke-DiagnosticMenu {
    param([string]$TestDistroName)
    $choice = Read-Choice -Prompt 'Diagnostics target:' -Options @(
        'real distro (your work distro)'
        'test distro (ephemeral)'
    ) -DefaultIndex 0
    if ($choice -like 'real*') {
        Invoke-Diagnostic -Target 'real' -DistroName (Get-RealDistroName)
    } else {
        Invoke-Diagnostic -Target 'test' -DistroName $TestDistroName
    }
}

function Show-LastRunResults {
    $resultsDir = Join-Path $Script:RepoRoot 'tests\results'
    if (-not (Test-Path $resultsDir)) { Write-Host '  No prior runs.' -ForegroundColor Yellow; return }
    $latest = Get-ChildItem -Path $resultsDir -Filter 'run-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Write-Host '  No prior runs.' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host ("  Last results: {0}" -f $latest.FullName) -ForegroundColor DarkGray
    Get-Content -LiteralPath $latest.FullName | Write-Host
}

function Invoke-TestRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Tests,
        [string]$TestDistroName = (Get-TestDistroDefaultName),
        [string]$WgConfigPath,
        [switch]$CI,
        [switch]$NonInteractive,
        [string]$ResultsJsonPath
    )
    if (-not $Tests -or $Tests.Count -eq 0) {
        Write-Host '  No tests selected.' -ForegroundColor Yellow
        return $null
    }

    $resultsDir = Join-Path $Script:RepoRoot 'tests\results'
    if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }
    if (-not $ResultsJsonPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $ResultsJsonPath = Join-Path $resultsDir "run-$stamp.json"
    }

    $auto   = @($Tests | Where-Object { $_.Kind -eq 'auto'   })
    $manual = @($Tests | Where-Object { $_.Kind -eq 'manual' })
    $needsDistro = @($Tests | Where-Object { $_.NeedsDistro }).Count -gt 0

    $started = Get-Date
    $autoResult = $null
    $autoCrashed = $false
    $autoCrashMessage = $null
    $manualResults = @()
    $distroProvisioned = $false

    try {
        if ($needsDistro) {
            Write-Host ''
            Write-Host "  [run] Provisioning ephemeral test distro '$TestDistroName'..."
            # Inside the try so a setup failure still hits the finally cleanup
            # below. Initialize-TestDistro may register the distro and then
            # fail in bootstrap; without this guard the partial distro
            # survives across runs.
            Initialize-TestDistro -Name $TestDistroName
            $distroProvisioned = $true
        }

        $env:CLAUDEARIUM_TEST_DISTRO = $TestDistroName
        $env:CLAUDEARIUM_REPO_ROOT   = $Script:RepoRoot
        if ($WgConfigPath) { $env:CLAUDEARIUM_TEST_WG_CONFIG = $WgConfigPath }

        if ($auto.Count -gt 0) {
            $files = @($auto | ForEach-Object { Join-Path $Script:RepoRoot $_.File } | Select-Object -Unique)
            $xml = Join-Path $resultsDir ("pester-{0}.xml" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            try {
                $autoResult = Invoke-PesterTests -Paths $files -ResultsXmlPath $xml -CI:$CI
            } catch {
                # Don't swallow silently: a Pester invocation crash (module load
                # failure, malformed test file, etc.) is itself a test failure
                # and should propagate to the CI exit code via the summary's
                # ok=false / failed=1 fields below.
                $autoCrashed     = $true
                $autoCrashMessage = $_.Exception.Message
                Write-Host "  [run] Pester invocation failed: $autoCrashMessage" -ForegroundColor Red
            }
        }

        $skipManual = $CI -or $NonInteractive
        foreach ($t in $manual) {
            $r = Invoke-ManualTest `
                -Name $t.Id `
                -Instructions $t.Description `
                -Question 'Did the expected behavior occur?' `
                -NonInteractive:$skipManual
            $manualResults += $r
        }
    }
    finally {
        # Always attempt teardown if Initialize-TestDistro got far enough to
        # register the distro — even if bootstrap itself failed, the WSL
        # registration survives and would block the next run.
        if ($distroProvisioned -or ($needsDistro -and (Test-DistroExists -Name $TestDistroName))) {
            Write-Host "  [run] Removing test distro '$TestDistroName'..."
            try { Remove-TestDistro -Name $TestDistroName }
            catch { Write-Host "  [run] Cleanup warning: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        Remove-Item Env:CLAUDEARIUM_TEST_DISTRO     -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEARIUM_REPO_ROOT       -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDEARIUM_TEST_WG_CONFIG  -ErrorAction SilentlyContinue
    }

    $ended = Get-Date
    $autoSummary = if ($autoResult) {
        [ordered]@{
            total   = [int]$autoResult.TotalCount
            passed  = [int]$autoResult.PassedCount
            failed  = [int]$autoResult.FailedCount
            skipped = [int]$autoResult.SkippedCount
            ok      = ([int]$autoResult.FailedCount -eq 0)
        }
    }
    elseif ($autoCrashed) {
        # Synthetic failure record so CI exit logic and the JSON consumer can
        # tell "Pester crashed" from "no auto tests were selected" (both leave
        # $autoResult null but only the former should fail the run).
        [ordered]@{
            total    = 0
            passed   = 0
            failed   = 1
            skipped  = 0
            ok       = $false
            crashed  = $true
            crashMessage = $autoCrashMessage
        }
    }
    else { $null }

    $summary = [ordered]@{
        startedAt    = $started.ToString('o')
        endedAt      = $ended.ToString('o')
        durationSec  = [int]($ended - $started).TotalSeconds
        autoSummary  = $autoSummary
        manualSummary = [ordered]@{
            total   = $manualResults.Count
            passed  = @($manualResults | Where-Object { $_.Passed -and -not $_.Skipped }).Count
            failed  = @($manualResults | Where-Object { -not $_.Passed -and -not $_.Skipped }).Count
            skipped = @($manualResults | Where-Object { $_.Skipped }).Count
            entries = $manualResults
        }
    }
    ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ResultsJsonPath -Encoding UTF8
    Write-Host ''
    Write-Host ("  Results JSON: {0}" -f $ResultsJsonPath) -ForegroundColor DarkGray
    return $summary
}

Export-ModuleMember -Function `
    Show-TestDashboard, Show-TestSelection, Show-LastRunResults, `
    Invoke-DiagnosticMenu, Invoke-TestRun, Get-RealDistroName
