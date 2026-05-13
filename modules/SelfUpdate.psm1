# SelfUpdate.psm1
# Compares the local install's VERSION against the latest GitHub release and,
# when invoked via the `update apply` verb, downloads and swaps in the new
# release while preserving user-added files via a manifest diff.
#
# Public surface:
#   Local detection
#     Get-LocalVersion [-Path]                — [version] | 'dev' | $null
#     Test-IsGitCheckout [-Path]              — $true if .git exists at install root
#     Get-GitCheckoutOriginUrl [-Path]        — origin url or $null
#     Test-IsOurRepo -Url <s>                 — permissive match against MaceWindu/Claudearium
#   Update-check state (global, not per-distro)
#     Get-UpdateCheckStatePath                — %LOCALAPPDATA%\claudearium\update-check.json
#     Get-UpdateCheckState                    — { lastCheckedAt; latestSeenVersion }
#     Set-UpdateCheckState -State <h>         — atomic .tmp + Move-Item -Force
#     Test-ShouldCheckForUpdates [-Now]       — $false in git checkout; throttle 7d
#   Remote lookup
#     Get-LatestReleaseInfo                   — { Version; Tag; DownloadUrl; Notes } | $null
#   Auto-check entry (dashboard banner)
#     Invoke-UpdateCheck                      — { Local; Latest; DownloadUrl; Notes } | $null
#   Manifest diff (pure helpers, exposed for testability)
#     Test-SafeManifestPath -Path <s>             — rejects absolute / traversal entries
#     Get-ManifestRemovals -Old <s[]> -New <s[]>  — paths in Old not in New
#   Apply (verb only, exits the process on success)
#     Invoke-SelfUpdate -DownloadUrl -Version
#   Verb handler
#     Invoke-Update                           — reads $Script:SubVerb (script scope) from claudearium.ps1
#
# Module install layout assumption: the module file lives at
# <install>/modules/SelfUpdate.psm1. Install-root resolution is always
# Split-Path -Parent (Split-Path -Parent $PSCommandPath) unless an explicit
# -Path is passed (for tests).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoOwner   = 'MaceWindu'
$Script:RepoName    = 'Claudearium'
$Script:LatestUrl   = "https://api.github.com/repos/$Script:RepoOwner/$Script:RepoName/releases/latest"
$Script:ThrottleDays = 7

function Get-InstallRoot {
    # Module lives at <install>/modules/SelfUpdate.psm1 — go up two levels.
    return (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
}

function Get-LocalVersion {
    # Returns:
    #   [version]   on a parseable VERSION file
    #   'dev'       when VERSION is absent / empty / whitespace / literally 'dev'
    #   $null       on malformed contents (so callers can distinguish from dev)
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path (Get-InstallRoot) 'VERSION' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'dev' }
    $raw = (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $raw) { return 'dev' }
    $s = $raw.Trim()
    if (-not $s) { return 'dev' }
    if ($s -ieq 'dev') { return 'dev' }
    if ($s -match '^\d{4}\.\d{1,2}\.\d+$') {
        try { return [version]$s } catch { return $null }
    }
    return $null
}

function Test-IsGitCheckout {
    # True if the install root looks like a git working tree. Accepts both a
    # .git directory and a .git file (worktree marker).
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-InstallRoot }
    return [bool](Test-Path -LiteralPath (Join-Path $Path '.git'))
}

function Get-GitCheckoutOriginUrl {
    # Best-effort read of `git config remote.origin.url` at the install root.
    # Returns $null if not a git checkout or git is unavailable.
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-InstallRoot }
    if (-not (Test-IsGitCheckout -Path $Path)) { return $null }
    try {
        $url = (& git -C $Path config remote.origin.url 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        $url = ($url | Out-String).Trim()
        if (-not $url) { return $null }
        return $url
    } catch {
        return $null
    }
}

function Test-IsOurRepo {
    # Permissive match against the canonical MaceWindu/Claudearium URL forms:
    #   https://github.com/MaceWindu/Claudearium[.git][/]
    #   git@github.com:MaceWindu/Claudearium[.git][/]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Url)
    if (-not $Url) { return $false }
    return [bool]($Url -match "(?i)github\.com[:/]$Script:RepoOwner/$Script:RepoName(\.git)?/?$")
}

function Get-UpdateCheckStatePath {
    [CmdletBinding()] param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve update-check state path.' }
    return (Join-Path $env:LOCALAPPDATA 'claudearium\update-check.json')
}

function Get-UpdateCheckState {
    # Returns a hashtable with lastCheckedAt (ISO-8601 string or $null) and
    # latestSeenVersion (string or $null). Falls back to defaults if the file
    # is missing or unparseable.
    [CmdletBinding()] param([string]$Path)
    if (-not $Path) { $Path = Get-UpdateCheckStatePath }
    $defaults = @{ lastCheckedAt = $null; latestSeenVersion = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $defaults }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        $obj = $raw | ConvertFrom-Json -AsHashtable
        if ($obj -isnot [hashtable]) { return $defaults }
        if ($obj.ContainsKey('lastCheckedAt')) {
            $v = $obj.lastCheckedAt
            # ConvertFrom-Json -AsHashtable auto-parses ISO-8601 strings into
            # [datetime]; the default ToString() is locale-formatted, which
            # corrupts the round-trip. Reformat back to ISO-8601 round-trip.
            if ($v -is [datetime]) {
                $defaults.lastCheckedAt = $v.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            } elseif ($v) {
                $defaults.lastCheckedAt = [string]$v
            }
        }
        if ($obj.ContainsKey('latestSeenVersion')) {
            $defaults.latestSeenVersion = [string]$obj.latestSeenVersion
        }
        return $defaults
    } catch {
        return $defaults
    }
}

function Set-UpdateCheckState {
    # Atomic write: ConvertTo-Json to a sibling .tmp, then Move-Item -Force.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [string]$Path
    )
    if (-not $Path) { $Path = Get-UpdateCheckStatePath }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    $json = $State | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-ShouldCheckForUpdates {
    # Decides whether the dashboard banner should hit the network.
    # Always $false in a git checkout (dev uses 'git pull').
    [CmdletBinding()]
    param(
        [datetime]$Now = [datetime]::UtcNow,
        [string]$Path
    )
    if (Test-IsGitCheckout) { return $false }
    $state = Get-UpdateCheckState -Path $Path
    if (-not $state.lastCheckedAt) { return $true }
    try {
        $last = [datetime]::Parse($state.lastCheckedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $true  # Unparseable timestamp — treat as stale.
    }
    return (($Now - $last).TotalDays -ge $Script:ThrottleDays)
}

function Get-LatestReleaseInfo {
    # GET /repos/<owner>/<repo>/releases/latest. Returns:
    #   @{ Version=[version]; Tag='vX.Y.Z'; DownloadUrl=<url>; Notes=<md> }
    # or $null on any error (network, 404, parse).
    [CmdletBinding()] param()
    try {
        $resp = Invoke-RestMethod -Uri $Script:LatestUrl -TimeoutSec 5 -Headers @{
            'User-Agent' = 'Claudearium-SelfUpdate'
            'Accept'     = 'application/vnd.github+json'
        }
        if (-not $resp -or -not $resp.tag_name) { return $null }
        $tag = [string]$resp.tag_name
        if ($tag -notmatch '^v(\d{4}\.\d{1,2}\.\d+)$') { return $null }
        $version = [version]$Matches[1]
        $asset = $null
        if ($resp.assets) {
            $asset = @($resp.assets) | Where-Object { $_.name -like 'claudearium-v*.zip' } | Select-Object -First 1
        }
        if (-not $asset) { return $null }
        return @{
            Version     = $version
            Tag         = $tag
            DownloadUrl = [string]$asset.browser_download_url
            Notes       = [string]$resp.body
        }
    } catch {
        return $null
    }
}

function Invoke-UpdateCheck {
    # Dashboard banner entry. Returns a hashtable describing an available
    # update, or $null when there's nothing to surface. Never throws — the
    # dashboard wraps this in try/catch out of paranoia, but the function
    # itself swallows internal errors so a transient network failure can't
    # block the menu.
    [CmdletBinding()] param()
    try {
        if (Test-IsGitCheckout) { return $null }
        if (-not (Test-ShouldCheckForUpdates)) { return $null }

        $local  = Get-LocalVersion
        $latest = Get-LatestReleaseInfo

        # Persist that we *attempted* a check, whether or not it succeeded —
        # this throttles repeated failures (offline, rate-limited, etc.).
        $state = Get-UpdateCheckState
        $state.lastCheckedAt = [datetime]::UtcNow.ToString('o')
        if ($latest) { $state.latestSeenVersion = $latest.Version.ToString() }
        Set-UpdateCheckState -State $state

        if (-not $latest) { return $null }
        if ($local -isnot [version]) { return $null }  # 'dev' or $null — nothing to compare
        if ($latest.Version -le $local) { return $null }

        return @{
            Local       = $local
            Latest      = $latest.Version
            DownloadUrl = $latest.DownloadUrl
            Notes       = $latest.Notes
        }
    } catch {
        return $null
    }
}

function Get-ManifestRemovals {
    # Pure: returns paths present in Old but missing from New. Both inputs are
    # arrays of forward-slashed relative paths from a manifest.txt file.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Old,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$New
    )
    $newSet = @{}
    foreach ($p in $New) { $newSet[$p] = $true }
    return @($Old | Where-Object { -not $newSet.ContainsKey($_) })
}

function Test-SafeManifestPath {
    # Manifest paths must stay under the install root. Reject:
    #   - empty / whitespace
    #   - drive prefix (`C:\...`, `c:foo`)
    #   - leading slash or backslash (absolute on either OS)
    #   - any `.` or `..` segment (traversal)
    # The manifest is generated by trusted CI, but we read it from a
    # downloaded zip which could in principle be tampered with; failing
    # closed on a malformed entry costs us nothing.
    [CmdletBinding()] param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    if ($Path -match '^[A-Za-z]:') { return $false }
    if ($Path -match '^[/\\]') { return $false }
    foreach ($seg in ($Path -split '[/\\]')) {
        if ($seg -eq '..' -or $seg -eq '.' -or $seg -eq '') { return $false }
    }
    return $true
}

function Read-ManifestFile {
    # Reads a manifest.txt and returns relative paths (forward slashes,
    # one per line, ignoring blank lines, sorted). Throws on any path that
    # would escape the install root — see Test-SafeManifestPath.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest file missing: $Path"
    }
    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_ -and ($_.Trim()) } | ForEach-Object { $_.Trim() })
    foreach ($p in $lines) {
        if (-not (Test-SafeManifestPath -Path $p)) {
            throw "Unsafe manifest entry refused: '$p'"
        }
    }
    return @($lines | Sort-Object)
}

function Invoke-SelfUpdate {
    # Apply path: download release zip, validate, back up the current install,
    # apply the manifest diff (delete removed managed files; copy NEW tree over),
    # print re-run instructions, and exit. Refuses to run inside a git checkout.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DownloadUrl,
        [Parameter(Mandatory)][string]$Version
    )

    if (Test-IsGitCheckout) {
        $url = Get-GitCheckoutOriginUrl
        Write-Host ("  Running from git checkout at {0}." -f ($url ?? '<unknown origin>')) -ForegroundColor Yellow
        Write-Host "  Self-update is disabled for dev checkouts — use 'git pull' instead." -ForegroundColor Yellow
        return
    }

    $installRoot = Get-InstallRoot
    $oldManifestPath = Join-Path $installRoot 'manifest.txt'
    if (-not (Test-Path -LiteralPath $oldManifestPath -PathType Leaf)) {
        Write-Host "  No manifest.txt at $installRoot — refusing to update." -ForegroundColor Red
        Write-Host "  This install predates the manifest convention. Download the latest release" -ForegroundColor Red
        Write-Host "  zip from https://github.com/$Script:RepoOwner/$Script:RepoName/releases and replace by hand." -ForegroundColor Red
        return
    }

    $guid = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $zipPath    = Join-Path $env:TEMP "claudearium-update-$guid.zip"
    $extractDir = Join-Path $env:TEMP "claudearium-update-$guid"

    try {
        Write-Host "  Downloading $DownloadUrl ..."
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120

        Write-Host "  Extracting..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        # Sanity: required structure + VERSION matches what we were promised.
        foreach ($req in @('claudearium.ps1', 'modules', 'VERSION', 'manifest.txt')) {
            $p = Join-Path $extractDir $req
            if (-not (Test-Path -LiteralPath $p)) {
                throw "Downloaded zip is missing required entry: $req"
            }
        }
        $extractedVersion = ((Get-Content -LiteralPath (Join-Path $extractDir 'VERSION') -Raw) ?? '').Trim()
        if ($extractedVersion -ne $Version) {
            throw "Downloaded zip's VERSION ($extractedVersion) does not match expected ($Version)."
        }

        # Backup the current install before mutating anything.
        $currentLocal = Get-LocalVersion
        $currentTag = if ($currentLocal -is [version]) { $currentLocal.ToString() } else { 'dev' }
        $ts = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $backupZip = Join-Path $env:TEMP "claudearium-backup-v$currentTag-$ts.zip"
        Write-Host "  Backing up current install to $backupZip ..."
        if (Test-Path -LiteralPath $backupZip) { Remove-Item -LiteralPath $backupZip -Force }
        Compress-Archive -Path (Join-Path $installRoot '*') -DestinationPath $backupZip -CompressionLevel Optimal

        # Manifest diff: remove managed files that the new release dropped.
        $oldManifest = Read-ManifestFile -Path $oldManifestPath
        $newManifest = Read-ManifestFile -Path (Join-Path $extractDir 'manifest.txt')
        $removals = Get-ManifestRemovals -Old $oldManifest -New $newManifest

        if ($removals.Count -gt 0) {
            Write-Host ("  Removing {0} managed file(s) no longer in the new release." -f $removals.Count)
            foreach ($rel in $removals) {
                $abs = Join-Path $installRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
                if (Test-Path -LiteralPath $abs) {
                    Remove-Item -LiteralPath $abs -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Write-Host "  Copying new files into place..."
        Copy-Item -Path (Join-Path $extractDir '*') -Destination $installRoot -Recurse -Force

        # Prune any now-empty managed directories left by the removals.
        $managedDirs = @($oldManifest | ForEach-Object {
            $parent = Split-Path -Parent $_
            if ($parent) { $parent }
        } | Sort-Object -Unique -Descending)
        foreach ($rel in $managedDirs) {
            $abs = Join-Path $installRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
            if ((Test-Path -LiteralPath $abs -PathType Container) -and -not (Get-ChildItem -LiteralPath $abs -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $abs -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host ''
        Write-Host ("  Updated to v$Version.") -ForegroundColor Green
        Write-Host ("  Backup of the previous install: $backupZip") -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Re-run claudearium.cmd (or claudearium.ps1) to use the new version.' -ForegroundColor Cyan
        exit 0
    } finally {
        # Best-effort cleanup of the staging artifacts. The backup zip stays.
        if (Test-Path -LiteralPath $zipPath)    { Remove-Item -LiteralPath $zipPath    -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Update {
    # Verb handler for `claudearium update [check|apply|status]`.
    # The entry-point script passes its $SubVerb param explicitly because
    # this function lives in a module — $Script:SubVerb would resolve to
    # the module's own scope, not the caller's.
    [CmdletBinding()]
    param([string]$SubVerb)
    $sub = if ($SubVerb) { $SubVerb } else { 'check' }

    switch ($sub.ToLowerInvariant()) {
        'check' {
            $local = Get-LocalVersion
            Write-Host ''
            Write-Host '=== Claudearium update ===' -ForegroundColor Cyan
            Write-Host ("  Local:  {0}" -f (Format-VersionString $local))
            if (Test-IsGitCheckout) {
                $url = Get-GitCheckoutOriginUrl
                Write-Host ("  Running from git checkout at {0}." -f ($url ?? '<unknown origin>')) -ForegroundColor Yellow
                Write-Host "  Self-update is disabled for dev checkouts — use 'git pull' instead." -ForegroundColor Yellow
                return
            }
            $latest = Get-LatestReleaseInfo
            if (-not $latest) {
                Write-Host '  Latest: (unavailable — network or rate limit)' -ForegroundColor DarkYellow
                return
            }
            Write-Host ("  Latest: v{0}" -f $latest.Version)

            # Persist the result (and refresh lastCheckedAt) so the dashboard
            # banner doesn't immediately try again.
            $state = Get-UpdateCheckState
            $state.lastCheckedAt     = [datetime]::UtcNow.ToString('o')
            $state.latestSeenVersion = $latest.Version.ToString()
            Set-UpdateCheckState -State $state

            if ($local -isnot [version]) {
                Write-Host "  Local version is unknown ('$local'); cannot compare." -ForegroundColor DarkYellow
                return
            }
            if ($latest.Version -gt $local) {
                Write-Host "  Update available. Run 'claudearium update apply' to install." -ForegroundColor Green
            } else {
                Write-Host '  Up to date.' -ForegroundColor Green
            }
        }
        'apply' {
            if (Test-IsGitCheckout) {
                $url = Get-GitCheckoutOriginUrl
                Write-Host ("  Running from git checkout at {0}." -f ($url ?? '<unknown origin>')) -ForegroundColor Yellow
                Write-Host "  Self-update is disabled for dev checkouts — use 'git pull' instead." -ForegroundColor Yellow
                return
            }
            $local = Get-LocalVersion
            $latest = Get-LatestReleaseInfo
            if (-not $latest) {
                Write-Host '  Could not reach the GitHub releases API. Try again later.' -ForegroundColor Red
                return
            }
            if ($local -is [version] -and $latest.Version -le $local) {
                Write-Host "  Already on v$local (latest is v$($latest.Version)). Nothing to do." -ForegroundColor Green
                return
            }
            Write-Host ''
            Write-Host ("  Local:  {0}" -f (Format-VersionString $local))
            Write-Host ("  Latest: v{0}" -f $latest.Version)
            $proceed = Read-YesNo -Prompt "  Install v$($latest.Version)?" -Default $true
            if (-not $proceed) { return }
            Invoke-SelfUpdate -DownloadUrl $latest.DownloadUrl -Version $latest.Version.ToString()
        }
        'status' {
            $local = Get-LocalVersion
            $state = Get-UpdateCheckState
            Write-Host ''
            Write-Host '=== Claudearium update status ===' -ForegroundColor Cyan
            Write-Host ("  Local version:      {0}" -f (Format-VersionString $local))
            Write-Host ("  Last seen latest:   {0}" -f ($state.latestSeenVersion ?? '(never)'))
            Write-Host ("  Last checked at:    {0}" -f ($state.lastCheckedAt ?? '(never)'))
            if (Test-IsGitCheckout) {
                Write-Host '  Mode:               git checkout (self-update disabled)' -ForegroundColor DarkGray
            }
        }
        default {
            Write-Host "Unknown update subverb: $sub" -ForegroundColor Red
            Write-Host "Use: claudearium update [check|apply|status]"
            exit 64
        }
    }
}

function Format-VersionString {
    # Helper for printing — turns [version] into v2026.5.1 and leaves
    # 'dev' / $null as readable strings.
    param([AllowNull()]$Version)
    if ($null -eq $Version) { return '(unknown)' }
    if ($Version -is [version]) { return "v$Version" }
    return [string]$Version
}

Export-ModuleMember -Function `
    Get-LocalVersion, Test-IsGitCheckout, Get-GitCheckoutOriginUrl, Test-IsOurRepo, `
    Get-UpdateCheckStatePath, Get-UpdateCheckState, Set-UpdateCheckState, `
    Test-ShouldCheckForUpdates, Get-LatestReleaseInfo, Invoke-UpdateCheck, `
    Test-SafeManifestPath, Read-ManifestFile, Get-ManifestRemovals, `
    Invoke-SelfUpdate, Invoke-Update, Format-VersionString
