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
        Id           = 'pure/Profile'
        File         = 'tests/pure/Profile.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Profile'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 4
        Description  = 'Test-Profile validation: example profile, missing/bad schemaVersion, missing distro, duplicate projects, unknown base; env-token expansion in ConvertFrom-ProfileRaw'
    },
    @{
        Id           = 'pure/State'
        File         = 'tests/pure/State.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'State'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'Initialize-State shape + Add-Recent dedup and -Max trimming'
    },
    @{
        Id           = 'pure/Diff'
        File         = 'tests/pure/Diff.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Diff'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Per-block diff functions (distro, projects, host mounts, tools, host tools): Action / Severity / HasDestructive shape'
    },
    @{
        Id           = 'pure/BashQuoting'
        File         = 'tests/pure/BashQuoting.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Wsl'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'ConvertTo-BashQuoted: spaces, embedded quotes, empty input'
    },
    @{
        Id           = 'pure/Mounts'
        File         = 'tests/pure/Mounts.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Mounts'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Drvfs path encoding, fstab line round-trip, default mount options, /host suggestion'
    },
    @{
        Id           = 'pure/HostTools'
        File         = 'tests/pure/HostTools.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'HostTools'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'ConvertTo-GuestPath, Resolve-DefaultGuestCommand, ConvertTo-WrapperContent body shape'
    },
    @{
        Id           = 'pure/ClaudeSettings'
        File         = 'tests/pure/ClaudeSettings.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'ClaudeSettings'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Always + Opinionated layers, Merge-Settings array dedup, ConvertTo-ClaudeSettingsJson round-trip'
    },
    @{
        Id           = 'pure/Vpn'
        File         = 'tests/pure/Vpn.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Vpn'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'ConvertTo-SplitAllowedIPs: IPv4/IPv6 split routing, case-insensitive AllowedIPs key, non-AllowedIPs left alone'
    },
    @{
        Id           = 'pure/Sessions'
        File         = 'tests/pure/Sessions.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Sessions'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'ConvertTo-SessionNameSuggestion last-segment rule; Get-MostRecentSession ordering'
    },
    @{
        Id           = 'pure/UI'
        File         = 'tests/pure/Ui.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'UI'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'Read-YesNo / Read-Choice / Read-Multi / Read-TabColor NonInteractive paths'
    },
    @{
        Id           = 'distro/Setup'
        File         = 'tests/distro/Setup.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Setup'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 150
        Description  = 'claudearium.ps1 setup provisions a fresh distro: claude user, sudo, wsl.conf, interop binfmt'
    },
    @{
        Id           = 'distro/Project'
        File         = 'tests/distro/Project.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Project'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 30
        Description  = 'project add clones the bare mirror, project list shows it, project remove cleans up'
    },
    @{
        Id           = 'distro/Session'
        File         = 'tests/distro/Session.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Session'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 40
        Description  = 'session new (existing branch and -NewBranch), session remove with dirty refuse + -Force'
    },
    @{
        Id           = 'distro/Mount'
        File         = 'tests/distro/Mount.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Mount'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 25
        Description  = 'mount add writes fstab block + mounts; sync is idempotent (no duplicate lines); remove unmounts'
    },
    @{
        Id           = 'distro/Tools'
        File         = 'tests/distro/Tools.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Tools'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 10
        Description  = 'tools list reports the full catalog; enable/disable mutate the profile without installing'
    },
    @{
        Id           = 'distro/HostTools'
        File         = 'tests/distro/HostTools.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'HostTools'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 15
        Description  = 'host-tools add installs a wrapper under /usr/local/bin with the marker; remove deletes it'
    },
    @{
        Id           = 'distro/Vpn'
        File         = 'tests/distro/Vpn.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Vpn'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 25
        Description  = 'vpn enable installs payload + transforms wg0.conf (split AllowedIPs); vpn disable is idempotent'
    },
    @{
        Id           = 'distro/Reconcile'
        File         = 'tests/distro/Reconcile.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Reconcile'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 10
        Description  = "reconcile prints '(no changes...)' for a minimal profile post-bootstrap"
    },
    @{
        Id           = 'distro/ClaudeSettings'
        File         = 'tests/distro/ClaudeSettings.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'ClaudeSettings'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 15
        Description  = "claude-settings apply writes settings.json with merged always + opinionated layers"
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
