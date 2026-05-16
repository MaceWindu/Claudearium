# ToolUpdates.psm1
# Caches per-tool "latest upstream version" lookups and serves them to the
# `tools` dashboard, where they drive the Latest column and the yellow
# "update available" hint. A background refresh job (Start-ThreadJob) keeps
# the cache fresh without blocking dashboard render.
#
# Cache file: %LOCALAPPDATA%\claudearium\tool-versions.json
#   { checkedAt: <ISO-8601>, tools: { <name>: { latest: <str|null>, error: <str|null> } } }
# Lock file:  %LOCALAPPDATA%\claudearium\tool-versions.lock
#   ISO-8601 timestamp of an in-flight refresh; serves as dogpile suppression.
#
# Public surface:
#   Get-ToolUpdatesCachePath              — full path of the cache file
#   Get-ToolUpdatesLockPath               — full path of the lock file
#   Read-ToolUpdatesCache                 — hashtable | $null
#   Write-ToolUpdatesCache -Cache <h>     — atomic write (.tmp + Move-Item -Force)
#   Test-ToolUpdatesCacheStale [-TtlHours 6] [-Now]  — bool
#   Start-ToolUpdatesRefresh [-Force]     — fires a background ThreadJob; respects the lock
#   Invoke-ToolUpdatesRefreshSync         — synchronous refresh with progress lines
#   Get-ToolUpdateCount -Rows <obj[]>     — number of rows where Latest > Installed
#   Get-ToolUpdateStatus -Installed -Latest  — 'same' | 'update-available' | 'unknown' (delegates to Compare-ToolVersion)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Tools.psm1')

$Script:DefaultTtlHours        = 6
$Script:LockMaxAgeSeconds      = 600   # treat lock files older than this as stale (process died mid-refresh)

function Get-ToolUpdatesCachePath {
    [CmdletBinding()] param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve tool-updates cache path.' }
    return (Join-Path $env:LOCALAPPDATA 'claudearium\tool-versions.json')
}

function Get-ToolUpdatesLockPath {
    [CmdletBinding()] param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve tool-updates lock path.' }
    return (Join-Path $env:LOCALAPPDATA 'claudearium\tool-versions.lock')
}

function Read-ToolUpdatesCache {
    # Returns the parsed cache as a hashtable, or $null when absent / unparseable.
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-ToolUpdatesCachePath }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        $obj = $raw | ConvertFrom-Json -AsHashtable
        if ($obj -isnot [hashtable]) { return $null }
        # ConvertFrom-Json -AsHashtable parses ISO-8601 strings into [datetime];
        # reformat back so callers see a stable string. (SelfUpdate.psm1 hits
        # the same surprise — keep behavior consistent.)
        if ($obj.ContainsKey('checkedAt') -and $obj.checkedAt -is [datetime]) {
            $obj.checkedAt = $obj.checkedAt.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        return $obj
    } catch {
        return $null
    }
}

function Write-ToolUpdatesCache {
    # Atomic: serialize to .tmp, then Move-Item -Force.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [string]$Path
    )
    if (-not $Path) { $Path = Get-ToolUpdatesCachePath }
    $dir = Split-Path -Parent $Path
    [void][System.IO.Directory]::CreateDirectory($dir)
    $tmp = "$Path.tmp"
    $json = $Cache | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-ToolUpdatesCacheStale {
    # True when the cache is missing, undated, or older than $TtlHours.
    [CmdletBinding()]
    param(
        [int]$TtlHours = $Script:DefaultTtlHours,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$Path
    )
    $cache = Read-ToolUpdatesCache -Path $Path
    if (-not $cache -or -not $cache.ContainsKey('checkedAt') -or -not $cache.checkedAt) { return $true }
    try {
        $last = [datetime]::Parse(
            [string]$cache.checkedAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        return $true
    }
    return (($Now - $last).TotalHours -ge $TtlHours)
}

function Test-RefreshLockActive {
    # Returns $true when a recent lock file suggests another refresh is in
    # flight. The .lock contents are an ISO-8601 timestamp of the lock owner;
    # if the timestamp is older than LockMaxAgeSeconds we assume the holder
    # died and the lock can be ignored.
    [CmdletBinding()]
    param(
        [datetime]$Now = [datetime]::UtcNow,
        [string]$Path
    )
    if (-not $Path) { $Path = Get-ToolUpdatesLockPath }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $raw = (Get-Content -LiteralPath $Path -Raw).Trim()
        $ts = [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        return (($Now - $ts).TotalSeconds -lt $Script:LockMaxAgeSeconds)
    } catch {
        return $false
    }
}

function New-RefreshLock {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-ToolUpdatesLockPath }
    $dir = Split-Path -Parent $Path
    [void][System.IO.Directory]::CreateDirectory($dir)
    [System.IO.File]::WriteAllText($Path, [datetime]::UtcNow.ToString('o'), (New-Object System.Text.UTF8Encoding $false))
}

function Remove-RefreshLock {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-ToolUpdatesLockPath }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { }
    }
}

function Invoke-ToolUpdatesRefreshSync {
    # Synchronous refresh. Walks every catalog tool, runs its GetLatestVersion
    # probe, and writes the cache. Emits one progress line per tool when
    # -Verbose or -Progress is requested. Returns the final cache hashtable.
    [CmdletBinding()]
    param(
        [switch]$Progress,
        [string]$CachePath,
        [string]$LockPath
    )
    if (-not $CachePath) { $CachePath = Get-ToolUpdatesCachePath }
    if (-not $LockPath)  { $LockPath  = Get-ToolUpdatesLockPath }
    New-RefreshLock -Path $LockPath
    try {
        $tools = @{}
        foreach ($name in Get-ToolCatalog) {
            if ($Progress) { Write-Host ("  probing {0,-12} ..." -f $name) -ForegroundColor DarkGray -NoNewline }
            $latest = $null; $err = $null
            try {
                $latest = Get-ToolLatestVersion -Name $name
                if (-not $latest) { $err = 'probe returned no version' }
            } catch {
                $err = $_.Exception.Message
            }
            $tools[$name] = @{ latest = $latest; error = $err }
            if ($Progress) {
                if ($latest) { Write-Host (" {0}" -f $latest) -ForegroundColor Gray }
                else         { Write-Host '' }
            }
        }
        $cache = @{
            checkedAt = [datetime]::UtcNow.ToString('o')
            tools     = $tools
        }
        Write-ToolUpdatesCache -Cache $cache -Path $CachePath
        return $cache
    } finally {
        Remove-RefreshLock -Path $LockPath
    }
}

function Start-ToolUpdatesRefresh {
    # Fires a background ThreadJob that refreshes the cache. Idempotent:
    # respects an active lock unless -Force is passed. Returns the job object
    # (or $null when no refresh was launched).
    [CmdletBinding()]
    param(
        [switch]$Force,
        [string]$CachePath,
        [string]$LockPath
    )
    if (-not $Force -and (Test-RefreshLockActive -Path $LockPath)) { return $null }
    if (-not $CachePath) { $CachePath = Get-ToolUpdatesCachePath }
    if (-not $LockPath)  { $LockPath  = Get-ToolUpdatesLockPath }
    # The thread job runs in a fresh runspace — it needs the module path.
    # Resolve to an absolute path from the *current* module location so a
    # caller running from a different CWD still finds the module.
    $modulePath = $PSCommandPath
    Import-Module ThreadJob -ErrorAction SilentlyContinue
    return (Start-ThreadJob -ScriptBlock {
        param($ModulePath, $CachePath, $LockPath)
        Import-Module $ModulePath
        try { Invoke-ToolUpdatesRefreshSync -CachePath $CachePath -LockPath $LockPath } catch { }
    } -ArgumentList $modulePath, $CachePath, $LockPath)
}

function Get-ToolUpdateStatus {
    # Thin wrapper so callers don't need to import Tools too.
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Installed,
        [AllowNull()][AllowEmptyString()][string]$Latest
    )
    return (Compare-ToolVersion -Installed $Installed -Latest $Latest)
}

function Get-ToolUpdateCount {
    # Given an array of row-like objects with .Name and .Installed and .Latest
    # properties (matching Get-ToolRows output), return the number of rows
    # whose Compare-ToolVersion is 'update-available'. Unknowns and 'same'
    # do not contribute — we never want to bother the user when we can't be
    # sure there's actually a newer version available.
    [CmdletBinding()]
    param([AllowNull()]$Rows)
    if (-not $Rows) { return 0 }
    $n = 0
    foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        # Accept either a hashtable or a PSCustomObject — Get-ToolRows currently
        # returns PSCustomObject, but tests construct hashtables.
        $installed = $null; $latest = $null
        if ($r -is [hashtable]) {
            if ($r.ContainsKey('Installed')) { $installed = [string]$r['Installed'] }
            if ($r.ContainsKey('Latest'))    { $latest    = [string]$r['Latest'] }
        } else {
            if ($r.PSObject.Properties.Match('Installed').Count -gt 0) { $installed = [string]$r.Installed }
            if ($r.PSObject.Properties.Match('Latest').Count -gt 0)    { $latest    = [string]$r.Latest }
        }
        if ((Compare-ToolVersion -Installed $installed -Latest $latest) -eq 'update-available') { $n++ }
    }
    return $n
}

Export-ModuleMember -Function `
    Get-ToolUpdatesCachePath, `
    Get-ToolUpdatesLockPath, `
    Read-ToolUpdatesCache, `
    Write-ToolUpdatesCache, `
    Test-ToolUpdatesCacheStale, `
    Test-RefreshLockActive, `
    New-RefreshLock, `
    Remove-RefreshLock, `
    Invoke-ToolUpdatesRefreshSync, `
    Start-ToolUpdatesRefresh, `
    Get-ToolUpdateStatus, `
    Get-ToolUpdateCount
