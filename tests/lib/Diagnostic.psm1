# Diagnostic.psm1
# Read-only health probes for a distro (real or test). Step 1 ships a stub
# that prints the high-level state via existing primitives; Step 4 expands
# this into the per-area probes called out in the plan (distro, profile,
# vpn, tools, snapshot).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

Import-Module (Join-Path $Script:RepoRoot 'modules\Wsl.psm1')     -Force
Import-Module (Join-Path $Script:RepoRoot 'modules\Profile.psm1') -Force

function Invoke-Diagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('real','test')][string]$Target,
        [Parameter(Mandatory)][string]$DistroName
    )
    Write-Host ''
    Write-Host ("=== Diagnostic ({0}): {1} ===" -f $Target, $DistroName) -ForegroundColor Cyan

    $exists = Test-DistroExists -Name $DistroName
    Write-Host ("  Registered:    {0}" -f $exists)
    if ($exists) {
        Write-Host ("  WSL state:     {0}" -f (Get-DistroState -Name $DistroName))
    }

    $profilePath = Get-DefaultProfilePath
    Write-Host ("  Profile path:  {0}" -f $profilePath)
    if (Test-Path $profilePath) {
        try {
            $spec = Read-Profile -Path $profilePath
            $v = Test-Profile -Spec $spec
            $status = if ($v.IsValid) { 'valid' } else { "INVALID ($($v.Errors.Count) error(s))" }
            Write-Host ("  Profile state: {0}" -f $status)
            foreach ($e in $v.Errors)   { Write-Host "    error:   $e" -ForegroundColor Red }
            foreach ($w in $v.Warnings) { Write-Host "    warning: $w" -ForegroundColor DarkYellow }
        } catch {
            Write-Host ("  Profile state: ERROR reading: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    } else {
        Write-Host '  Profile state: (no profile written yet)'
    }

    Write-Host ''
    Write-Host '  (Full diagnostic probes land in Step 4 of the test-suite rollout.)' -ForegroundColor DarkGray
}

Export-ModuleMember -Function Invoke-Diagnostic
