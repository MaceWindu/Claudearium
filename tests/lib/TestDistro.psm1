# TestDistro.psm1
# Ephemeral test-distro lifecycle. The runner delegates to the production
# `claudearium.ps1 setup` verb so distro tests exercise the same code paths
# users hit — this module only manages the surrounding lifecycle (rootfs
# caching, refuse-to-clobber check, teardown in a `finally`).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Script:CacheDir       = Join-Path $Script:RepoRoot 'tests\.cache'
$Script:RootfsXzPath   = Join-Path $Script:CacheDir 'rootfs.tar.xz'

Import-Module (Join-Path $Script:RepoRoot 'modules\Wsl.psm1') -Force

function Get-TestDistroDefaultName { 'claudearium-test' }

function Resolve-TestDistroInstallPath {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set.' }
    return (Join-Path $env:LOCALAPPDATA (Join-Path 'WSL' $Name))
}

function Initialize-TestDistroEnvironment {
    if (-not (Test-Path $Script:CacheDir)) {
        New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
    }
}

function Get-RootfsCachePath { return $Script:RootfsXzPath }

function Save-RootfsCache {
    # Idempotent: downloads the latest Debian 12 rootfs.tar.xz into the cache
    # if it isn't already present. The `setup` verb will accept this via
    # -RootfsPath and skip its own resolution/download.
    [CmdletBinding()] param()
    Initialize-TestDistroEnvironment
    if (Test-Path $Script:RootfsXzPath) { return $Script:RootfsXzPath }
    $url = Resolve-LatestDebianRootfsUrl
    Save-Rootfs -Url $url -DestPath $Script:RootfsXzPath
    return $Script:RootfsXzPath
}

function Test-TestDistroNameSafe {
    # Refuse to operate on anything that doesn't look like a test distro. This
    # is a foot-gun guard: someone passing -TestDistroName claudearium by
    # accident would otherwise have their real distro unregistered.
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -like 'claudearium-test*' -or $Name -like '*-test' -or $Name -like 'test-*')
}

function Initialize-TestDistro {
    # Full provisioning via the production setup verb. Refuses to overwrite a
    # pre-existing distro by the same name so a stale `claudearium-test` from
    # a crashed prior run is surfaced rather than silently wiped.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RootfsPath
    )
    if (-not (Test-TestDistroNameSafe -Name $Name)) {
        throw "Refusing to use '$Name' as a test distro — name must match 'claudearium-test*' / '*-test' / 'test-*'."
    }
    if (Test-DistroExists -Name $Name) {
        throw "Distro '$Name' already exists. Unregister it first (wsl --unregister $Name) or pass a different -TestDistroName."
    }
    if (-not $RootfsPath) {
        Write-Host '  [test-distro] Ensuring rootfs cache...' -ForegroundColor DarkGray
        $RootfsPath = Save-RootfsCache
    }
    $claudearium = Join-Path $Script:RepoRoot 'claudearium.ps1'
    if (-not (Test-Path $claudearium)) { throw "claudearium.ps1 not found at $claudearium" }
    Write-Host "  [test-distro] Running production setup for '$Name'..." -ForegroundColor DarkGray
    # Out-Host: setup streams `wsl.exe` stdout (bootstrap progress, debconf
    # warnings) through the pipeline. Without consuming it here, the strings
    # would bubble up into the caller's `$summary = Invoke-TestRun ...` and
    # turn the ordered-dict return value into an array, tripping StrictMode.
    & $claudearium setup -Force -Name $Name -RootfsPath $RootfsPath -NonInteractive | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "claudearium.ps1 setup failed (exit $LASTEXITCODE)" }
}

function Remove-TestDistro {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-TestDistroNameSafe -Name $Name)) {
        Write-Host "  [test-distro] Refusing to remove '$Name' — name does not look like a test distro." -ForegroundColor Red
        return
    }
    if (Test-DistroExists -Name $Name) {
        try { Unregister-Distro -Name $Name | Out-Host }
        catch { Write-Host "  [test-distro] Unregister warning: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    $install = Resolve-TestDistroInstallPath -Name $Name
    if (Test-Path $install) {
        try { Remove-Item -Path $install -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    # Also clear the per-distro state file so a re-run starts clean.
    $stateDir = Join-Path $env:LOCALAPPDATA (Join-Path 'claudearium' $Name)
    if (Test-Path $stateDir) {
        try { Remove-Item -Path $stateDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Export-ModuleMember -Function `
    Get-TestDistroDefaultName, Resolve-TestDistroInstallPath, Initialize-TestDistroEnvironment, `
    Get-RootfsCachePath, Save-RootfsCache, Test-TestDistroNameSafe, `
    Initialize-TestDistro, Remove-TestDistro
