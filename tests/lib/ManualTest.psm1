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
Import-Module (Join-Path $Script:RepoRoot 'modules\UI.psm1') -Force

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
            return [pscustomobject]@{
                Name = $Name; Passed = $false; Skipped = $true
                Notes = "setup failed: $($_.Exception.Message)"
            }
        }
    }

    $passed = $false
    try {
        $passed = Read-YesNo -Prompt $Question -Default $true
    }
    finally {
        if ($Cleanup) {
            try { & $Cleanup }
            catch { Write-Host "  Cleanup warning: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    return [pscustomobject]@{ Name = $Name; Passed = $passed; Skipped = $false; Notes = '' }
}

Export-ModuleMember -Function Invoke-ManualTest
