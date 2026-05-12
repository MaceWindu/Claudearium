# PesterRunner.psm1
# Thin wrapper around Invoke-Pester 5+. Auto-installs Pester to CurrentUser
# scope if only the legacy Pester 3 (shipped with Windows PowerShell 5.1) is
# available. All Pester configuration funnels through `Invoke-PesterTests`.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-Pester {
    [CmdletBinding()] param()
    $installed = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge [version]'5.0.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed) {
        Write-Host '  Pester 5+ not found. Installing to CurrentUser scope...' -ForegroundColor Yellow
        Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
        $installed = Get-Module -ListAvailable -Name Pester |
            Where-Object { $_.Version -ge [version]'5.0.0' } |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $installed) { throw 'Pester 5+ install failed.' }
    }
    Import-Module Pester -MinimumVersion 5.0.0 -Force
}

function Invoke-PesterTests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string]$ResultsXmlPath,
        [switch]$CI
    )
    Initialize-Pester
    $cfg = New-PesterConfiguration
    $cfg.Run.Path           = $Paths
    $cfg.Run.PassThru       = $true
    $cfg.Run.Exit           = $false
    $cfg.Output.Verbosity   = if ($CI) { 'Detailed' } else { 'Normal' }
    if ($ResultsXmlPath) {
        $cfg.TestResult.Enabled      = $true
        $cfg.TestResult.OutputPath   = $ResultsXmlPath
        $cfg.TestResult.OutputFormat = 'NUnitXml'
    }
    return (Invoke-Pester -Configuration $cfg)
}

Export-ModuleMember -Function Initialize-Pester, Invoke-PesterTests
