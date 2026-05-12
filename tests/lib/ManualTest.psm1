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

function Set-TestWtWindowName {
    # Rename the test's own wt window to a unique name so subsequent
    # `wt --window <name>` invocations land in THIS window specifically
    # — not whichever wt window happens to be focused (`-w 0` resolves
    # to most-recently-used, which can drift if the tester clicks away
    # before tabs spawn). Returns the chosen name. The rename is best-
    # effort: if wt.exe isn't installed or `-w 0` fails to find a
    # current window, returns 'last' as a fallback that wt accepts.
    [CmdletBinding()] param()
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wt) { return 'last' }
    $name = "claudearium-manual-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        # `rename-window <name>` requires wt 1.16+. Use the call
        # operator (not Start-Process -WindowStyle Hidden) so wt.exe
        # inherits the caller pwsh's WT_SESSION env var and forwards
        # to the parent window — Start-Process with -WindowStyle
        # Hidden was making wt spawn its own hidden window and rename
        # THAT instead of the test's window. The stderr redirect
        # swallows wt's "command line argument errors" if rename-window
        # isn't available on this wt version (older wt prints to
        # stderr and exits 0).
        & wt.exe -w 0 rename-window $name 2>$null
        # The rename is asynchronous from wt's perspective — give it a
        # beat to take effect before the caller uses the name.
        Start-Sleep -Milliseconds 500
        return $name
    } catch {
        return 'last'
    }
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
    $notes  = ''
    try {
        $passed = Read-YesNo -Prompt $Question -Default $true
        if (-not $passed) {
            # Ask the tester to describe what they saw so the failure is
            # actionable to a maintainer reading the results file. Enter
            # accepts an empty note. The text is included verbatim — the
            # runner scrubs known-sensitive substrings before writing.
            Write-Host ''
            Write-Host '  Help us debug: describe what went wrong (or press Enter to skip).' -ForegroundColor Yellow
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

Export-ModuleMember -Function Invoke-ManualTest, Set-TestWtWindowName
