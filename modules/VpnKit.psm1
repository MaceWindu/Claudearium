# VpnKit.psm1
# Host-side management of the `wsl-vpnkit` helper distro (sakai135/wsl-vpnkit).
#
# On Windows 10 (no `networkingMode=mirrored`), a host WireGuard VPN with a kill
# switch (e.g. ProtonVPN) drops WSL2 NAT egress even when eth0 already has a
# valid address + default route. The block is at the host WFP/kill-switch layer,
# above routing — so the in-distro net-repair (Network.psm1) cannot fix it.
#
# wsl-vpnkit fixes it by tunneling WSL egress through a host-side userspace
# network stack (gvisor-tap-vsock + `wsl-gvproxy.exe`): WSL traffic is redirected
# to a tap device and forwarded to a Windows *host process*, which makes the real
# connections. Because egress is host-originated it passes the kill switch. It
# provides connectivity to ALL WSL2 distros, so it lives OUTSIDE the primary
# distro: it is imported as its own second distro named `wsl-vpnkit`.
#
# Model (user decision): reconcile manages *installation* (the helper distro
# imported or not, per the `vpnkit` profile block); the dashboard/verb manages
# *running* (the tunnel process up or down) ON DEMAND — no auto-start. A common
# flow is `vpnkit install` + `vpnkit start` BEFORE `setup`, so bootstrap's apt
# has egress — hence the installed-version record lives in a standalone host file
# (wsl-vpnkit.json), NOT in the primary distro's state.json (which may not exist
# yet, and is wiped by nuke while the helper distro persists).
#
# INVARIANT: the `wsl-vpnkit` distro is a *second* distro, separate from the
# primary `claudearium` distro. `nuke` must never touch it (it targets the
# primary only). Removal is only via `vpnkit remove` / reconcile `enabled=false`.
#
# This is UNRELATED to the in-distro WireGuard + killswitch (Vpn.psm1). The two
# compose fine: vpnkit provides the underlay egress; an in-distro tunnel rides
# over it (nested).
#
# Public surface:
#   Get-VpnKitDistroName                          — pure: the helper distro name (single source of truth)
#   ConvertTo-VpnKitVersionTag -Version           — pure: normalize 0.4.1 / v0.4.1 -> v0.4.1 (throws on garbage)
#   Get-VpnKitReleaseUrl -Version                 — pure: the wsl-vpnkit.tar.gz release URL
#   Get-EffectiveVpnKitConfig -Spec               — pure: @{ Enabled; Version } from profile.vpnkit
#   Get-VpnKitDiff -Desired -Actual               — pure: reconcile diff (add/modify/remove, all safe)
#   Get-VpnKitInstallPath                         — %LOCALAPPDATA%\WSL\wsl-vpnkit
#   Get-VpnKitPidFilePath                         — %LOCALAPPDATA%\claudearium\wsl-vpnkit.pid
#   Get-VpnKitStatePath                           — %LOCALAPPDATA%\claudearium\wsl-vpnkit.json
#   Get-VpnKitInstalledVersion                    — recorded installed version tag ($null if unknown)
#   Set-VpnKitInstalledVersion -Version           — record the installed version tag
#   Clear-VpnKitInstalledVersion                  — drop the version record
#   Test-VpnKitImported                           — is the helper distro registered?
#   Test-VpnKitRunning                            — is the tunnel up? (authoritative: wsl-gvproxy host process)
#   Get-VpnKitActual                              — @{ Imported; Version; Running }
#   Save-VpnKitTarball -Version -DestPath         — download the release tarball
#   Install-VpnKit -Version [-Reinstall]          — download + import the helper distro (idempotent)
#   Uninstall-VpnKit                              — stop + unregister the helper distro + clear version
#   Start-VpnKit                                  — launch the tunnel as a hidden background host process
#   Stop-VpnKit                                   — stop the tunnel (process + distro + gvproxy)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')    # Import-Distro / Unregister-Distro / Stop-Distro / Test-DistroExists
Import-Module (Join-Path $PSScriptRoot 'State.psm1')  # Get-StateRoot

$Script:VpnKitDistroName = 'wsl-vpnkit'   # the SECOND helper distro — never the primary
$Script:VpnKitVersion    = 'v0.4.1'       # pinned known-good default (override via -Version / profile)
$Script:GvproxyProcName  = 'wsl-gvproxy'  # host-side userspace stack; Get-Process name (no .exe)

function Get-VpnKitDistroName {
    [CmdletBinding()] param()
    return $Script:VpnKitDistroName
}

function ConvertTo-VpnKitVersionTag {
    # Pure: normalize a version to the release-tag form `vMAJOR.MINOR.PATCH`.
    # Accepts `0.4.1` or `v0.4.1`; throws on anything else so a typo can't build
    # a bogus download URL.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Version)
    $v = $Version.Trim()
    if ($v -notmatch '^v?\d+\.\d+\.\d+$') {
        throw "Invalid wsl-vpnkit version '$Version' (expected e.g. v0.4.1)."
    }
    if (-not $v.StartsWith('v')) { $v = "v$v" }
    return $v
}

function Get-VpnKitReleaseUrl {
    # Pure: the release asset URL for a given version.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Version)
    $tag = ConvertTo-VpnKitVersionTag -Version $Version
    return "https://github.com/sakai135/wsl-vpnkit/releases/download/$tag/wsl-vpnkit.tar.gz"
}

function Get-EffectiveVpnKitConfig {
    # Pure: read profile.vpnkit into @{ Enabled; Version }. Defaults: disabled,
    # pinned version. Tolerates a missing block / $null / non-hashtable.
    [CmdletBinding()] param($Spec)
    $cfg = @{ Enabled = $false; Version = $Script:VpnKitVersion }
    if ($Spec -and ($Spec -is [hashtable]) -and $Spec.ContainsKey('vpnkit') -and ($Spec.vpnkit -is [hashtable])) {
        $v = $Spec.vpnkit
        if ($v.ContainsKey('enabled') -and ($v.enabled -is [bool])) { $cfg.Enabled = [bool]$v.enabled }
        if ($v.ContainsKey('version') -and $v.version)              { $cfg.Version = (ConvertTo-VpnKitVersionTag -Version ([string]$v.version)) }
    }
    return $cfg
}

function Get-VpnKitDiff {
    # Pure structural diff. Desired = Get-EffectiveVpnKitConfig output;
    # Actual = Get-VpnKitActual output. All changes are 'safe' (the helper distro
    # carries no user data): import when enabled-but-absent, re-import when the
    # tracked version drifts, unregister when disabled-but-present.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Desired,
        [Parameter(Mandatory)][hashtable]$Actual
    )
    $changes = [System.Collections.Generic.List[hashtable]]::new()
    if ($Desired.Enabled) {
        if (-not $Actual.Imported) {
            $changes.Add(@{
                Path     = 'vpnkit'
                Action   = 'add'
                Severity = 'safe'
                Note     = "import the wsl-vpnkit helper distro ($($Desired.Version))"
            })
        }
        # Only propose a re-import when the installed version is KNOWN and differs.
        # A $null actual version (e.g. installed out-of-band, or the record lost)
        # must not spuriously trigger a modify and churn the distro.
        elseif ($Actual.Version -and ($Actual.Version -ne $Desired.Version)) {
            $changes.Add(@{
                Path     = 'vpnkit.version'
                Action   = 'modify'
                Severity = 'safe'
                From     = $Actual.Version
                To       = $Desired.Version
                Note     = 're-import wsl-vpnkit at the pinned version'
            })
        }
    }
    elseif ($Actual.Imported) {
        $changes.Add(@{
            Path     = 'vpnkit'
            Action   = 'remove'
            Severity = 'safe'
            Note     = 'unregister the wsl-vpnkit helper distro'
        })
    }
    return @{
        Changes         = $changes
        HasDestructive  = $false
        CanApplyInPlace = $true
    }
}

function Get-VpnKitInstallPath {
    [CmdletBinding()] param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve the wsl-vpnkit install path.' }
    return (Join-Path $env:LOCALAPPDATA 'WSL\wsl-vpnkit')
}

function Get-VpnKitPidFilePath {
    # A cross-session hint for Stop-VpnKit to target the exact wsl.exe client.
    # NOT a correctness dependency — Test-VpnKitRunning is process-based.
    [CmdletBinding()] param()
    return (Join-Path (Get-StateRoot) 'wsl-vpnkit.pid')
}

function Get-VpnKitStatePath {
    # Standalone version record — decoupled from the primary distro's state.json
    # so it survives nuke and works before the primary distro exists.
    [CmdletBinding()] param()
    return (Join-Path (Get-StateRoot) 'wsl-vpnkit.json')
}

function Get-VpnKitInstalledVersion {
    # The recorded installed version tag, or $null if unknown.
    [CmdletBinding()] param()
    $path = Get-VpnKitStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $rec = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($rec.version) { return [string]$rec.version }
    } catch { }
    return $null
}

function Set-VpnKitInstalledVersion {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Version)
    $path = Get-VpnKitStatePath
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    (@{ version = (ConvertTo-VpnKitVersionTag -Version $Version) } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $path -Encoding utf8
}

function Clear-VpnKitInstalledVersion {
    [CmdletBinding()] param()
    Remove-Item -LiteralPath (Get-VpnKitStatePath) -Force -ErrorAction SilentlyContinue
}

function Test-VpnKitImported {
    [CmdletBinding()] param()
    return (Test-DistroExists -Name (Get-VpnKitDistroName))
}

function Test-VpnKitRunning {
    # Authoritative "tunnel up?" signal: the host-side userspace stack process
    # exists. Independent of who started it and of any stored PID, so it works
    # across fresh pwsh sessions (the dashboard is a new process each run).
    [CmdletBinding()] param()
    return [bool](Get-Process -Name $Script:GvproxyProcName -ErrorAction SilentlyContinue)
}

function Get-VpnKitActual {
    # @{ Imported; Version; Running }. Cheap — no shelling into any distro; works
    # even when the primary distro is Missing.
    [CmdletBinding()] param()
    return @{
        Imported = (Test-VpnKitImported)
        Version  = (Get-VpnKitInstalledVersion)
        Running  = (Test-VpnKitRunning)
    }
}

function Save-VpnKitTarball {
    # Download the release tarball to $DestPath. Mirrors Save-Rootfs (Wsl.psm1);
    # adds a User-Agent (GitHub release redirects are picky about a missing one).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$DestPath
    )
    $url = Get-VpnKitReleaseUrl -Version $Version
    $dir = Split-Path -Parent $DestPath
    [void][System.IO.Directory]::CreateDirectory($dir)
    Write-Host "  Downloading $url"
    Write-Host "  -> $DestPath"
    Invoke-WebRequest -Uri $url -OutFile $DestPath -UseBasicParsing -Headers @{ 'User-Agent' = 'claudearium' }
}

function Install-VpnKit {
    # Download + import the wsl-vpnkit helper distro. Idempotent: if already
    # imported and -not -Reinstall, no-op (returns the tag without touching the
    # version record — an unknown recorded version is deliberately left unknown so
    # Get-VpnKitDiff won't churn). With -Reinstall (the version-drift 'modify'
    # case), unregister first then re-import. Returns the version tag.
    [CmdletBinding()]
    param(
        [string]$Version = $Script:VpnKitVersion,
        [switch]$Reinstall
    )
    $tag = ConvertTo-VpnKitVersionTag -Version $Version
    if ((Test-VpnKitImported) -and (-not $Reinstall)) {
        return $tag
    }
    if (Test-VpnKitImported) {
        Uninstall-VpnKit
    }
    $tarball = Join-Path (Get-StateRoot) "downloads\wsl-vpnkit-$tag.tar.gz"
    Save-VpnKitTarball -Version $tag -DestPath $tarball
    # wsl --import accepts a gzip tarball directly — no rootfs conversion needed.
    # Pipe to Out-Null: `wsl --import` prints "The operation completed
    # successfully." to the pipeline, which would otherwise pollute this
    # function's return value (CLAUDE.md: child native output leaks into the
    # caller's output stream).
    Import-Distro -Name (Get-VpnKitDistroName) -RootfsPath $tarball -InstallPath (Get-VpnKitInstallPath) | Out-Null
    Set-VpnKitInstalledVersion -Version $tag
    return $tag
}

function Uninstall-VpnKit {
    # Stop (best-effort) then unregister the helper distro + clear the version
    # record. Guarded so it's a no-op when the distro isn't present, but the
    # version record is cleared regardless (so a stale record can't linger).
    [CmdletBinding()] param()
    if (Test-VpnKitImported) {
        try { Stop-VpnKit | Out-Null } catch { }
        Unregister-Distro -Name (Get-VpnKitDistroName)
    }
    Clear-VpnKitInstalledVersion
}

function Start-VpnKit {
    # Launch the tunnel as a hidden background host process:
    #   wsl.exe -d wsl-vpnkit --cd /app wsl-vpnkit
    # The command blocks (it stays alive to serve the tunnel), so we run it
    # detached via Start-Process and poll for the host-side gvproxy to appear.
    # No-op (with a flag) when a tunnel is already up.
    [CmdletBinding()] param()
    if (Test-VpnKitRunning) {
        return @{ Started = $true; AlreadyRunning = $true }
    }
    if (-not (Test-VpnKitImported)) {
        throw "wsl-vpnkit is not installed. Run 'claudearium vpnkit install' first."
    }
    $p = Start-Process -FilePath 'wsl.exe' `
        -ArgumentList '-d', (Get-VpnKitDistroName), '--cd', '/app', 'wsl-vpnkit' `
        -WindowStyle Hidden -PassThru
    $pidFile = Get-VpnKitPidFilePath
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $pidFile))
    (@{ pid = $p.Id; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $pidFile -Encoding utf8
    # Poll up to ~5s for the tunnel to come up. First launch may stall on a
    # Windows SmartScreen/Defender prompt on the unsigned wsl-gvproxy.exe —
    # -WindowStyle Hidden does not suppress that dialog, so the poll can time out
    # on the very first run until the user clicks through.
    for ($i = 0; $i -lt 10; $i++) {
        if (Test-VpnKitRunning) { return @{ Started = $true; Pid = $p.Id } }
        if ($p.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Test-VpnKitRunning) { return @{ Started = $true; Pid = $p.Id } }
    return @{ Started = $false; Pid = $p.Id; Exited = $p.HasExited }
}

function Stop-VpnKit {
    # Robust teardown, order matters:
    #   1. kill the tracked wsl.exe client (pidfile hint; guard against PID reuse)
    #   2. terminate the helper distro (kills the in-distro process tree)
    #   3. kill any lingering host-side gvproxy (this is what drops the tunnel)
    #   4. drop the pidfile
    # Works even if a different pwsh session started the tunnel (steps 2-3 don't
    # need the pidfile).
    [CmdletBinding()] param()
    $pidFile = Get-VpnKitPidFilePath
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $rec = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
            if ($rec.pid) {
                $proc = Get-Process -Id ([int]$rec.pid) -ErrorAction SilentlyContinue
                # Only kill if it's still a wsl client — dodge PID reuse.
                if ($proc -and $proc.ProcessName -eq 'wsl') {
                    Stop-Process -Id ([int]$rec.pid) -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }
    if (Test-VpnKitImported) {
        try { Stop-Distro -Name (Get-VpnKitDistroName) } catch { }
    }
    Get-Process -Name $Script:GvproxyProcName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return @{ Stopped = (-not (Test-VpnKitRunning)) }
}

Export-ModuleMember -Function `
    Get-VpnKitDistroName, `
    ConvertTo-VpnKitVersionTag, `
    Get-VpnKitReleaseUrl, `
    Get-EffectiveVpnKitConfig, `
    Get-VpnKitDiff, `
    Get-VpnKitInstallPath, `
    Get-VpnKitPidFilePath, `
    Get-VpnKitStatePath, `
    Get-VpnKitInstalledVersion, `
    Set-VpnKitInstalledVersion, `
    Clear-VpnKitInstalledVersion, `
    Test-VpnKitImported, `
    Test-VpnKitRunning, `
    Get-VpnKitActual, `
    Save-VpnKitTarball, `
    Install-VpnKit, `
    Uninstall-VpnKit, `
    Start-VpnKit, `
    Stop-VpnKit
