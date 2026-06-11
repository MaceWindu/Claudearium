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
        Description  = 'Test-Profile validation: example profile, missing/bad schemaVersion, missing distro, duplicate projects, unknown base, tools/hostTools drop-in conflict; env-token expansion in ConvertFrom-ProfileRaw'
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
        Description  = 'Initialize-State shape (schema v2: users map + uid allocator) + Add-Recent dedup and -Max trimming'
    },
    @{
        Id           = 'pure/Users'
        File         = 'tests/pure/Users.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Users'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'ConvertTo-LinuxUserName sanitize/truncate/prefix; New-ProjectUserPassword length/charset/uniqueness; New-ProjectUid monotonic + drift seed; Resolve-ProjectUserName collision suffixing; New-ProjectUserRecord allocation + idempotency'
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
        Description  = 'ConvertTo-GuestPath, Resolve-DefaultGuestCommand, ConvertTo-WrapperContent body shape, Add-CatalogToolAsHostAttach drop-in naming'
    },
    @{
        Id           = 'pure/Tools'
        File         = 'tests/pure/Tools.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Tools'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'Catalog HostExeNames metadata (OAuth-pain tools only); Test-ToolHostAvailable returns Available + ExePath via Get-Command'
    },
    @{
        Id           = 'pure/ToolUpdates'
        File         = 'tests/pure/ToolUpdates.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'ToolUpdates'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Get-ToolVersionCore extraction; Compare-ToolVersion tri-state; cache round-trip + staleness math; lock-file dogpile suppression; Get-ToolUpdateCount counts only update-available rows; every catalog entry declares a GetLatestVersion scriptblock'
    },
    @{
        Id           = 'pure/HostShadows'
        File         = 'tests/pure/HostShadows.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'HostShadows'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'Resolve-HostShadow: explicit/path/catalog source priority, missing-exe handling, mismatch warning, unknown-name handling; Get-HostShadowBinDir traversal guard'
    },
    @{
        Id           = 'pure/HostToolNotes'
        File         = 'tests/pure/HostToolNotes.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'HostToolNotes'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'Per-tool notes: Get-CatalogHostAttached filter; ConvertTo-ManagedBlock + Edit-ClaudeFileWithBlock round-trip (idempotent insert/replace/remove, preserves user content)'
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
        Id           = 'pure/ClaudeFile'
        File         = 'tests/pure/ClaudeFile.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'ClaudeFile'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Get-ClaudeFileDesiredContent per mode, CRLF normalization, Get-ClaudeFileDiff shapes, Test-Profile claudeFile validation'
    },
    @{
        Id           = 'pure/Wsl'
        File         = 'tests/pure/Wsl.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Wsl'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'ConvertFrom-WslListVerbose parses --list output (header skip, default-* strip, two-col fallback, CRLF); Convert-RootfsToTar dispatches by extension; Resolve-LatestDebianRootfsUrl picks latest %3A-encoded timestamp (gotcha #17 regression)'
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
        Description  = 'ConvertTo-SplitAllowedIPs: IPv4/IPv6 split routing, case-insensitive AllowedIPs key, non-AllowedIPs left alone; Test-WgConfigHasDns detects missing/commented/empty DNS = lines'
    },
    @{
        Id           = 'pure/SelfUpdate'
        File         = 'tests/pure/SelfUpdate.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'SelfUpdate'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Get-LocalVersion parse, Test-IsOurRepo permissive matching, update-check state round-trip + throttle math, Get-LatestReleaseInfo via mocked Invoke-RestMethod, manifest-diff helper'
    },
    @{
        Id           = 'pure/Temp'
        File         = 'tests/pure/Temp.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Temp'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Get-ScratchSizes parses tab-separated du output; Clear-Scratch claude scope wipes projects + shell-snapshots by default, extends to todos / plans only with -IncludeTodos / -IncludePlans; tmp / cache wipe scripts use -mindepth 1 (preserve the mountpoint)'
    },
    @{
        Id           = 'pure/Prune'
        File         = 'tests/pure/Prune.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Prune'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Format-Bytes formatting; Find-DanglingMounts set-difference against mocked actual/desired; Find-OrphanedSessions detects missing host worktrees via Test-Path'
    },
    @{
        Id           = 'pure/Projects'
        File         = 'tests/pure/Projects.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Projects'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 2
        Description  = 'Profile-mutation helpers: Move-ProjectInProfile distro <-> host preserves tabColor/defaultBranch/enabled, drops type-mismatched fields, validates after round-trip; required-arg errors for missing HostCheckout / Remote'
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
        Id           = 'pure/Gotchas'
        File         = 'tests/pure/Gotchas.Tests.ps1'
        Group        = 'pure'
        SubGroup     = 'Gotchas'
        Kind         = 'auto'
        NeedsDistro  = $false
        NeedsVpnReal = $false
        EstSeconds   = 1
        Description  = 'Static-analysis regressions for docs/wsl2-gotchas.md anti-patterns (Ensure-, awk -v, child -Force imports, GetBytes -replace, @-wrap, ...)'
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
        Description  = 'host-tools add installs a wrapper under /usr/local/bin with the marker; remove deletes it; Add-CatalogToolAsHostAttach + Install-HostToolWrapper installs a drop-in /usr/local/bin/<tool> with the marker'
    },
    @{
        Id           = 'distro/HostProjects'
        File         = 'tests/distro/HostProjects.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'HostProjects'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 25
        Description  = 'hostProject end-to-end: project add registers type=host + hostShadows + bin dir + init.sh; session new creates sibling host worktree + fstab mount; session remove + project remove tear down without touching hostCheckout'
    },
    @{
        Id           = 'distro/HostToolNotes'
        File         = 'tests/distro/HostToolNotes.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'HostToolNotes'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 10
        Description  = 'Install-HostToolNotes writes per-tool .md + managed block in CLAUDE.md; idempotent re-apply; strips both on detach; respects CLAUDE.md absence'
    },
    @{
        Id           = 'distro/Vpn'
        File         = 'tests/distro/Vpn.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Vpn'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 40
        Description  = 'VPN payload deploy + wg-config split-AllowedIPs transform + killswitch ruleset behaviorally blocks egress to public IPs (no systemctl)'
    },
    @{
        Id           = 'distro/Temp'
        File         = 'tests/distro/Temp.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Temp'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 15
        Description  = 'temp size lists every scope; temp clean -Scope all -Force wipes /tmp, ~/.cache, ~/.claude/projects, ~/.claude/shell-snapshots while preserving ~/.claude/todos|plans|host-tools; -IncludeTodos / -IncludePlans extend the wipe set'
    },
    @{
        Id           = 'distro/Prune'
        File         = 'tests/distro/Prune.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Prune'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 25
        Description  = 'prune -Scope sessions detects + repairs orphaned state.sessions entries after a manual worktree wipe; -DryRun does not mutate state; -Scope all on a clean distro prints "Nothing to prune"'
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
    },
    @{
        Id           = 'distro/ClaudeFile'
        File         = 'tests/distro/ClaudeFile.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'ClaudeFile'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 10
        Description  = 'Install-ClaudeFile writes /home/claude/.claude/CLAUDE.md with correct content, owner, mode'
    },
    @{
        Id           = 'distro/Gotchas'
        File         = 'tests/distro/Gotchas.Tests.ps1'
        Group        = 'distro'
        SubGroup     = 'Gotchas'
        Kind         = 'auto'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 10
        Description  = 'Invoke-InDistroScript preserves $VAR; fstab inline-regex parser returns array shape (no awk -v)'
    },
    @{
        Id           = 'manual/TabColor'
        File         = 'tests/manual/TabColor.ps1'
        Group        = 'manual'
        SubGroup     = 'TabColor'
        Kind         = 'manual'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 60
        Description  = 'open-claudearium tab respects the per-project tabColor'
    },
    @{
        Id           = 'manual/OpenSession'
        File         = 'tests/manual/OpenSession.ps1'
        Group        = 'manual'
        SubGroup     = 'OpenSession'
        Kind         = 'manual'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 60
        Description  = 'open-claudearium.ps1 launches a wt tab in the session worktree with claude'
    },
    @{
        Id           = 'manual/Login'
        File         = 'tests/manual/Login.ps1'
        Group        = 'manual'
        SubGroup     = 'Login'
        Kind         = 'manual'
        NeedsDistro  = $true
        NeedsVpnReal = $false
        EstSeconds   = 120
        Description  = "the four 'login' subverbs each reach their interactive auth flow"
    },
    @{
        Id           = 'manual/VpnConnectivity'
        File         = 'tests/manual/VpnConnectivity.ps1'
        Group        = 'manual'
        SubGroup     = 'Vpn'
        Kind         = 'manual'
        NeedsDistro  = $true
        NeedsVpnReal = $true
        EstSeconds   = 120
        Description  = 'tunnel routes egress AND killswitch blocks non-wg egress when disabled'
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
