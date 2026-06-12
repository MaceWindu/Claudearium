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

Import-Module (Join-Path $Script:LibDir 'TestRegistry.psm1')   -Force
Import-Module (Join-Path $Script:LibDir 'PesterRunner.psm1')   -Force
Import-Module (Join-Path $Script:LibDir 'TestDistro.psm1')     -Force
Import-Module (Join-Path $Script:LibDir 'ManualTest.psm1')     -Force
Import-Module (Join-Path $Script:LibDir 'Diagnostic.psm1')     -Force
Import-Module (Join-Path $Script:LibDir 'TestRunHelpers.psm1') -Force
# NOTE: no `-Force` on the modules/* imports. The dashboard's `d` shortcut
# in claudearium.ps1 calls `& test-claudearium.ps1 -Diag` in the same
# process; test-claudearium.ps1 imports this lib with -Force, and a -Force
# re-import of modules\*.psm1 from here would invalidate claudearium.ps1's
# earlier imports of those modules, breaking the next dashboard render
# (gotcha #10 in docs/wsl2-gotchas.md).
Import-Module (Join-Path $Script:RepoRoot 'modules\UI.psm1')
Import-Module (Join-Path $Script:RepoRoot 'modules\Wsl.psm1')
Import-Module (Join-Path $Script:RepoRoot 'modules\Profile.psm1')

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
    $targetChoice = Read-Choice -Prompt 'Diagnostics target:' -Options @(
        'real distro (your work distro)'
        'test distro (ephemeral)'
    ) -DefaultIndex 0
    $target = if ($targetChoice -like 'real*') { 'real' } else { 'test' }
    $distro = if ($target -eq 'real') { Get-RealDistroName } else { $TestDistroName }

    if ($target -eq 'test' -and -not (Test-DistroExists -Name $distro)) {
        Write-Host "  Test distro '$distro' isn't registered. Run an auto test first to provision it." -ForegroundColor Yellow
        return
    }

    $modeChoice = Read-Choice -Prompt 'What to do:' -Options @(
        'all probes (stdout)'
        'snapshot to file (paste into bug reports)'
        'pick one area'
    ) -DefaultIndex 0
    switch -Wildcard ($modeChoice) {
        'all*'      { Invoke-Diagnostic -Target $target -DistroName $distro }
        'snapshot*' { [void](Invoke-DiagnosticSnapshot -DistroName $distro) }
        'pick*' {
            $area = Read-Choice -Prompt 'Which area?' -Options (Get-DiagnosticAreas) -DefaultIndex 0
            Invoke-Diagnostic -Target $target -DistroName $distro -Areas @($area)
        }
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
    else {
        # Caller pointed at an explicit path; ensure its parent exists so
        # the final Set-Content doesn't blow up.
        $explicitParent = Split-Path -Parent $ResultsJsonPath
        if ($explicitParent -and -not (Test-Path $explicitParent)) {
            New-Item -ItemType Directory -Path $explicitParent -Force | Out-Null
        }
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
    # Refuse-to-clobber guard: if the distro already exists before this run,
    # Initialize-TestDistro will throw and the finally block should leave the
    # pre-existing distro alone. Capture that state up front.
    $distroPreexisted = $needsDistro -and (Test-DistroExists -Name $TestDistroName)
    # Snapshot env vars so the finally block restores what the caller had
    # set, rather than deleting whatever variables they happened to have.
    $envBackup = @{
        CLAUDEARIUM_TEST_DISTRO         = [Environment]::GetEnvironmentVariable('CLAUDEARIUM_TEST_DISTRO')
        CLAUDEARIUM_REPO_ROOT           = [Environment]::GetEnvironmentVariable('CLAUDEARIUM_REPO_ROOT')
        CLAUDEARIUM_TEST_WG_CONFIG      = [Environment]::GetEnvironmentVariable('CLAUDEARIUM_TEST_WG_CONFIG')
        # Initialize-TestDistro sets this to isolate the shared-store host folder.
        # Must be restored, else a same-session pure run sees the throwaway path
        # and the ClaudeShared host-path assertion fails.
        CLAUDEARIUM_CLAUDE_SHARED_HOST  = [Environment]::GetEnvironmentVariable('CLAUDEARIUM_CLAUDE_SHARED_HOST')
    }

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
            $r = $null
            if ($t.ContainsKey('File') -and $t.File) {
                # Each tests/manual/*.ps1 is self-contained: it imports
                # ManualTest.psm1 and returns the result object.
                $manualScript = Join-Path $Script:RepoRoot $t.File
                if (Test-Path $manualScript) {
                    $r = & $manualScript -NonInteractive:$skipManual
                }
            }
            if (-not $r) {
                # Fallback for manifest entries that don't have a backing file
                # (description-only stubs).
                $r = Invoke-ManualTest `
                    -Name $t.Id `
                    -Instructions $t.Description `
                    -Question 'Did the expected behavior occur?' `
                    -NonInteractive:$skipManual
            }
            $manualResults += $r
        }
    }
    finally {
        # Only tear down a distro this run actually provisioned. If
        # Initialize-TestDistro threw because the distro already existed
        # before we started ($distroPreexisted=$true), leave it alone —
        # destroying it would be a foot-gun for the caller. We still
        # clean up partial provisions where bootstrap registered the
        # distro then failed (Test-DistroExists true, $distroProvisioned
        # false, $distroPreexisted false).
        $shouldRemove = $distroProvisioned -or `
            ($needsDistro -and -not $distroPreexisted -and (Test-DistroExists -Name $TestDistroName))
        if ($shouldRemove) {
            Write-Host "  [run] Removing test distro '$TestDistroName'..."
            try { Remove-TestDistro -Name $TestDistroName }
            catch { Write-Host "  [run] Cleanup warning: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        # Restore env vars to whatever the caller had set (often $null), so
        # we never delete or overwrite variables we didn't put there.
        foreach ($name in @('CLAUDEARIUM_TEST_DISTRO','CLAUDEARIUM_REPO_ROOT','CLAUDEARIUM_TEST_WG_CONFIG','CLAUDEARIUM_CLAUDE_SHARED_HOST')) {
            [Environment]::SetEnvironmentVariable($name, $envBackup[$name])
        }
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
    $json = $summary | ConvertTo-Json -Depth 6
    $scrubbed = ConvertTo-ShareableContent -Content $json
    $scrubbed | Set-Content -LiteralPath $ResultsJsonPath -Encoding UTF8

    Write-Host ''
    Write-Host '=== Test run summary ===' -ForegroundColor Cyan
    Write-Host ("  Duration: {0}" -f (Format-Duration -Seconds $summary.durationSec))
    if ($autoSummary) {
        $autoColor = if ($autoSummary.ok) { 'Green' } else { 'Red' }
        Write-Host ("  AUTO:   {0} passed, {1} failed, {2} skipped (of {3})" -f `
            $autoSummary.passed, $autoSummary.failed, $autoSummary.skipped, $autoSummary.total) -ForegroundColor $autoColor
        if ($autoSummary.Contains('crashed') -and $autoSummary.crashed) {
            Write-Host ("    Pester crashed: {0}" -f $autoSummary.crashMessage) -ForegroundColor Red
        }
    }
    $ms = $summary.manualSummary
    if ($ms.total -gt 0) {
        $manualColor = if ($ms.failed -eq 0) { 'Green' } else { 'Red' }
        Write-Host ("  MANUAL: {0} passed, {1} failed, {2} skipped (of {3})" -f `
            $ms.passed, $ms.failed, $ms.skipped, $ms.total) -ForegroundColor $manualColor
        foreach ($e in $ms.entries) {
            if ($e.Skipped) {
                $status = '[SKIP]'; $color = 'Yellow'
            } elseif ($e.Passed) {
                $status = '[PASS]'; $color = 'Green'
            } else {
                $status = '[FAIL]'; $color = 'Red'
            }
            $line = "    $status $($e.Name)"
            if ($e.Notes) { $line += " — $($e.Notes)" }
            Write-Host $line -ForegroundColor $color
        }
    }
    Write-Host ("  Results JSON: {0}" -f $ResultsJsonPath) -ForegroundColor DarkGray

    $autoFailed   = if ($autoSummary) { [int]$autoSummary.failed } else { 0 }
    $manualFailed = [int]$ms.failed
    if (($autoFailed + $manualFailed) -gt 0) {
        Write-Host ''
        Write-Host '  One or more tests failed. The results JSON was scrubbed for common' -ForegroundColor Yellow
        Write-Host '  identifiers (usernames, home/AppData/repo paths, machine name), but' -ForegroundColor Yellow
        Write-Host '  not for arbitrary secrets — review the file for tokens / URLs you' -ForegroundColor Yellow
        Write-Host '  might have typed into manual-test Notes before sharing. Bug reports:' -ForegroundColor Yellow
        Write-Host '    https://github.com/MaceWindu/Claudearium/issues' -ForegroundColor Yellow
    }
    return $summary
}

Export-ModuleMember -Function `
    Show-TestDashboard, Show-TestSelection, Show-LastRunResults, `
    Invoke-DiagnosticMenu, Invoke-TestRun, Get-RealDistroName
