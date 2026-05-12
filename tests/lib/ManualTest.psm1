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
Import-Module (Join-Path $Script:RepoRoot 'modules\UI.psm1')      -Force
Import-Module (Join-Path $Script:RepoRoot 'modules\Profile.psm1') -Force
Import-Module (Join-Path $Script:RepoRoot 'modules\Wsl.psm1')     -Force

function Get-RealDistroForManualTest {
    # Resolve the user's actual distro from their default profile so manual
    # tests can drive the production stack against real state (rather than
    # spinning up an ephemeral one — that's the job of NeedsDistro=$true in
    # the manifest, which manual tests should NOT use).
    [CmdletBinding()] param()
    $name = 'claudearium'
    $pp = Get-DefaultProfilePath
    if (Test-Path $pp) {
        try {
            $spec = Read-Profile -Path $pp
            if ($spec -and $spec.distro -and $spec.distro.name) {
                $name = [string]$spec.distro.name
            }
        } catch { }
    }
    return $name
}

function Test-RealDistroReady {
    # Returns $true if the user's real distro is registered and we can
    # proceed with a manual test that mutates it. Manual tests should
    # short-circuit to Skipped when this returns $false rather than try
    # to do anything destructive against a missing distro.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    return [bool](Test-DistroExists -Name $DistroName)
}

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

Export-ModuleMember -Function `
    Invoke-ManualTest, `
    Get-RealDistroForManualTest, `
    Test-RealDistroReady
