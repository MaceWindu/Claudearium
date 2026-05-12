# Diagnostic.psm1
# Orchestrates the read-only probes under tests/diagnostic/. Two entry
# points:
#   - Invoke-Diagnostic       runs all probes, prints to stdout
#   - Invoke-DiagnosticSnapshot writes a single combined file under
#                              tests/results/diag-*.txt
#
# Each tests/diagnostic/<area>.ps1 accepts -DistroName and writes via
# Write-Host. Nothing here mutates the distro — the dashboard's `d`
# option is safe against the user's real distro.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Script:DiagDir  = Join-Path $Script:RepoRoot 'tests\diagnostic'

function Get-DiagnosticAreas {
    return @('Distro', 'Profile', 'Vpn', 'Tools')
}

function Invoke-Diagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('real','test')][string]$Target,
        [Parameter(Mandatory)][string]$DistroName,
        [string[]]$Areas
    )
    if (-not $Areas -or $Areas.Count -eq 0) { $Areas = Get-DiagnosticAreas }

    Write-Host ''
    Write-Host "=== Diagnostic ($Target): $DistroName ===" -ForegroundColor Cyan
    foreach ($area in $Areas) {
        $script = Join-Path $Script:DiagDir "$area.ps1"
        if (-not (Test-Path $script)) {
            Write-Host "  [diag] unknown area '$area' (no $script)" -ForegroundColor Yellow
            continue
        }
        try { & $script -DistroName $DistroName }
        catch { Write-Host ("  [diag] {0}: {1}" -f $area, $_.Exception.Message) -ForegroundColor Red }
    }
}

function Invoke-DiagnosticSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [string]$OutPath
    )
    $snapshot = Join-Path $Script:DiagDir 'Snapshot.ps1'
    if ($OutPath) {
        return (& $snapshot -DistroName $DistroName -OutPath $OutPath)
    }
    return (& $snapshot -DistroName $DistroName)
}

Export-ModuleMember -Function Get-DiagnosticAreas, Invoke-Diagnostic, Invoke-DiagnosticSnapshot
