# TestRegistry.psm1
# Static manifest of every test the runner knows about. Each entry carries the
# metadata the dashboard needs to filter, estimate, render, and dispatch:
#   - Id           — stable identifier shown in the tree and results JSON
#   - File         — path under the repo root that holds the test body
#   - Group        — top-level bucket ('pure' | 'distro')
#   - SubGroup     — secondary bucket used by the selection tree
#   - Kind         — 'auto' (Pester) | 'manual' (Read-YesNo prompts)
#   - NeedsDistro  — if true, the ephemeral test distro is provisioned for the run
#   - NeedsVpnReal — if true, skipped unless --wg-config-path is supplied
#   - EstSeconds   — rough wallclock budget used for "select X tests, est Ym"
#   - Description  — one-line user-facing summary
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Manifest = @(
    @{
        Id           = 'pure/Profile/test-profile-validates-example'
        File         = 'tests/pure/Profile.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Profile'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 3
        Description  = 'Test-Profile reports IsValid on the example profile and rejects malformed ones'
    },
    @{
        Id           = 'distro/Setup/setup-creates-claude-user'
        File         = 'tests/distro/Setup.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Setup'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 150
        Description  = 'claudearium.ps1 setup provisions a fresh distro: claude user, sudo, wsl.conf, interop binfmt'
    }
)

function Get-TestManifest { return ,$Script:Manifest }

function Select-Tests {
    [CmdletBinding()]
    param(
        [string[]]$Groups,
        [string]$Kind,
        [string[]]$Ids,
        [switch]$IncludeDistro,
        [switch]$IncludeVpnReal
    )
    $items = $Script:Manifest
    if ($Ids)    { return @($items | Where-Object { $_.Id -in $Ids }) }
    if ($Groups) { $items = $items | Where-Object { $_.Group -in $Groups } }
    if ($Kind)   { $items = $items | Where-Object { $_.Kind -eq $Kind } }
    if (-not $IncludeDistro)  { $items = $items | Where-Object { -not $_.NeedsDistro } }
    if (-not $IncludeVpnReal) { $items = $items | Where-Object { -not $_.NeedsVpnReal } }
    return @($items)
}

function Get-EstSeconds {
    param([hashtable[]]$Tests)
    if (-not $Tests -or $Tests.Count -eq 0) { return 0 }
    return [int](($Tests | Measure-Object -Property EstSeconds -Sum).Sum)
}

function Format-Duration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "${Seconds}s" }
    $m = [int][math]::Floor($Seconds / 60)
    $s = $Seconds % 60
    if ($s -eq 0) { return "${m}m" }
    return ('{0}m{1:00}s' -f $m, $s)
}

Export-ModuleMember -Function Get-TestManifest, Select-Tests, Get-EstSeconds, Format-Duration
