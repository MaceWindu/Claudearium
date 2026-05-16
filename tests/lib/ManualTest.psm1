# ManualTest.psm1
# Manual-test DSL. Wraps Read-YesNo from modules/UI.psm1 to render an
# instruction block, optional setup/cleanup scriptblocks, and a final
# yes/no prompt. Returns a structured result that the runner folds into
# the results JSON alongside Pester output.
#
# Step 1 ships a single primitive: Invoke-ManualTest. Step 4 will add a
# more expressive DSL on top of it (Setup / Instruct / Expect-YesNo /
# Cleanup blocks).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
# NOTE: no `-Force` — see Dashboard.psm1 for the cascade-invalidation
# rationale (gotcha #10).
Import-Module (Join-Path $Script:RepoRoot 'modules\UI.psm1')

function Invoke-ManualTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Question,
        [string]$Instructions,
        [scriptblock]$Setup,
        [scriptblock]$Cleanup,
        [switch]$NonInteractive
    )
    Write-Host ''
    Write-Host "=== Manual test: $Name ===" -ForegroundColor Cyan
    if ($Instructions) { Write-Host $Instructions }

    if ($NonInteractive) {
        Write-Host '  (NonInteractive: marking as skipped)' -ForegroundColor DarkGray
        return [pscustomobject]@{
            Name = $Name; Passed = $false; Skipped = $true
            Notes = 'manual test skipped in non-interactive mode'
        }
    }

    if ($Setup) {
        try { & $Setup }
        catch {
            Write-Host "  Setup failed: $($_.Exception.Message)" -ForegroundColor Red
            # Skipped=$false on purpose: setup failure means the test
            # *should* have run but couldn't — that's a real failure, not
            # a "we opted out" skip. The summary counts non-skipped !Passed
            # entries as failed, so this bubbles up to the CI exit code.
            return [pscustomobject]@{
                Name = $Name; Passed = $false; Skipped = $false
                Notes = "setup failed: $($_.Exception.Message)"
            }
        }
    }

    $passed = $false
    $notes  = ''
    try {
        $passed = Read-YesNo -Prompt $Question -Default $true
        if (-not $passed) {
            # Ask the tester to describe what they saw so the failure is
            # actionable to a maintainer reading the results file. Enter
            # accepts an empty note. The text is included VERBATIM in the
            # results JSON — the runner only scrubs known identifiers
            # (paths / username / hostname), NOT arbitrary secrets. Warn
            # the tester explicitly so OAuth tokens / API keys / private
            # URLs don't slip into a file destined for an issue tracker.
            Write-Host ''
            Write-Host '  Help us debug: describe what went wrong (or press Enter to skip).' -ForegroundColor Yellow
            Write-Host '  Your notes are saved verbatim. The runner scrubs paths / username /' -ForegroundColor DarkGray
            Write-Host '  hostname, but NOT tokens, API keys, or URLs — keep them out of your reply.' -ForegroundColor DarkGray
            $notes = (Read-Host '  Notes').Trim()
        }
    }
    finally {
        if ($Cleanup) {
            try { & $Cleanup }
            catch { Write-Host "  Cleanup warning: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    return [pscustomobject]@{ Name = $Name; Passed = $passed; Skipped = $false; Notes = $notes }
}

Export-ModuleMember -Function Invoke-ManualTest
