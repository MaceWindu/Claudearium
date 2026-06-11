# HostShadows.psm1
# Resolves and installs per-project Windows-host tool wrappers for hostProjects.
# A "shadow" is a host-side `pwsh`/`git`/etc. wrapper installed into a
# per-project bin dir at /home/claude/host-projects/<project>/bin/. The dir is
# prepended to PATH by open-claudearium.ps1 only for sessions of that
# hostProject — distro-installed tools at /usr/bin and /usr/local/bin stay
# visible to every other session, preserving zero cross-talk between hostProject
# and distroProject sessions.
#
# Public surface:
#   Catalog
#     Get-HostShadowCatalog       — built-in map of known shadows
#   Resolution (Windows-side, pure logic)
#     Resolve-HostShadow          — name -> @{ Name; WindowsExe; Source; Warnings }
#     Find-HostShadowOnPath       — where.exe <exe> -> first hit or $null
#   Bin-dir helpers (live)
#     Get-HostShadowBinDir        [-Home] — '<home>/host-projects/<p>/bin'
#     Install-HostShadowsForProject [-User -Home] — reconcile wrappers in the bin dir
#     Remove-HostShadowsForProject  [-User -Home] — delete the project's bin dir + parent
#
# -User/-Home default to the legacy 'claude' / '/home/claude'. Under per-project
# user isolation the project's own user owns its host-projects tree.
#
# Design notes:
#   * `Resolve-HostShadow` is intentionally side-effect-free and accepts
#     `-Catalog` / `-PathOverride` so pure tests can drive it without real
#     Windows binaries.
#   * The catalog `exeName` field is what we search for on PATH (`pwsh.exe`,
#     `git.exe`). The `name` the user types in their profile is the bash command
#     they'll use inside the distro (`pwsh`, `git`). The two diverge only by
#     the `.exe` suffix today but could differ in the future.
#   * Resolution prefers PATH over catalog because that's what the user runs
#     in their own shell. On mismatch (PATH ≠ catalog candidate that exists),
#     we warn so they can pin via the { name, windowsExe } form if they
#     actually wanted the other one.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'HostTools.psm1')

$Script:HostShadowCatalog = @{
    pwsh = @{
        exeName    = 'pwsh.exe'
        candidates = @(
            "${env:ProgramFiles}\PowerShell\7\pwsh.exe"
            # Bracketed in advance for the eventual 8.x install layout.
            "${env:ProgramFiles}\PowerShell\8\pwsh.exe"
        )
        notes = 'host-tool-notes/pwsh.md'
    }
    git = @{
        exeName    = 'git.exe'
        candidates = @(
            "${env:ProgramFiles}\Git\cmd\git.exe"
            "${env:ProgramFiles}\Git\bin\git.exe"
            "${env:ProgramFiles(x86)}\Git\cmd\git.exe"
        )
        notes = 'host-tool-notes/git.md'
    }
}

function Get-HostShadowCatalog {
    [CmdletBinding()] param()
    # Hand back a copy so callers can't mutate the module-private map.
    $copy = @{}
    foreach ($k in $Script:HostShadowCatalog.Keys) {
        $entry = $Script:HostShadowCatalog[$k]
        $copy[$k] = @{
            exeName    = [string]$entry.exeName
            candidates = @($entry.candidates)
            notes      = [string]$entry.notes
        }
    }
    return $copy
}

function Find-HostShadowOnPath {
    # Look up a Windows executable name on PATH via where.exe. Returns the first
    # hit or $null. Wrapped in a function so tests can stub it via
    # Resolve-HostShadow -PathOverride.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExeName)
    try {
        # 2>$null on where.exe also swallows the "INFO: Could not find files"
        # message that goes to stdout with a non-zero exit. We rely on the
        # exit code, not absence of output.
        $hits = @(& where.exe $ExeName 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $first = $hits | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
            if ($first) { return $first.Trim() }
        }
    } catch { }
    return $null
}

function Resolve-HostShadow {
    # Resolve a hostShadow entry (string or { name, windowsExe }) to a concrete
    # Windows .exe path. Resolution order:
    #   1. ExplicitExe (object-form pin) — must exist.
    #   2. PATH lookup via where.exe <exeName> — what the user runs day-to-day.
    #   3. Built-in catalog candidates (well-known install paths).
    # Returns @{ Name; WindowsExe; Source; Warnings } where Source is one of
    # 'explicit' / 'path' / 'catalog' / 'unresolved'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ExplicitExe,
        [hashtable]$Catalog,
        # Test seam: when supplied, replaces the where.exe call. Maps
        # exeName -> path (or $null to simulate "not on PATH").
        [hashtable]$PathOverride
    )
    if (-not $Catalog) { $Catalog = $Script:HostShadowCatalog }
    $warnings = New-Object System.Collections.Generic.List[string]

    if ($ExplicitExe) {
        if (Test-Path -LiteralPath $ExplicitExe -PathType Leaf) {
            return @{
                Name       = $Name
                WindowsExe = $ExplicitExe
                Source     = 'explicit'
                Warnings   = $warnings.ToArray()
            }
        }
        $warnings.Add("explicit windowsExe '$ExplicitExe' does not exist or is not a file.")
        return @{ Name = $Name; WindowsExe = $null; Source = 'unresolved'; Warnings = $warnings.ToArray() }
    }

    $entry = $null
    if ($Catalog.ContainsKey($Name)) { $entry = $Catalog[$Name] }
    $exeName = if ($entry -and $entry.exeName) { [string]$entry.exeName } else {
        if ($Name -like '*.exe') { $Name } else { "$Name.exe" }
    }

    $pathHit = $null
    if ($PathOverride) {
        # Treat presence with $null value as "intentionally not on PATH".
        if ($PathOverride.ContainsKey($exeName)) { $pathHit = $PathOverride[$exeName] }
    }
    else {
        $pathHit = Find-HostShadowOnPath -ExeName $exeName
    }

    $catalogHit = $null
    if ($entry) {
        foreach ($c in @($entry.candidates)) {
            if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $catalogHit = $c; break }
        }
    }

    if ($pathHit) {
        if ($catalogHit -and ($pathHit -ne $catalogHit)) {
            $warnings.Add("Shadow '$Name' resolved from PATH to '$pathHit' but a different install also exists at '$catalogHit'. Using the PATH version — pin via { name, windowsExe } to silence.")
        }
        return @{ Name = $Name; WindowsExe = $pathHit; Source = 'path'; Warnings = $warnings.ToArray() }
    }
    if ($catalogHit) {
        return @{ Name = $Name; WindowsExe = $catalogHit; Source = 'catalog'; Warnings = $warnings.ToArray() }
    }

    if ($entry) {
        $candCount = @($entry.candidates).Count
        $warnings.Add("Could not resolve '$Name'. Tried PATH ($exeName) and $candCount catalog candidate(s). Install $Name on the host or pin via { name, windowsExe }.")
    }
    else {
        $warnings.Add("'$Name' is not in the built-in catalog and was not found on PATH as '$exeName'. Use the { name, windowsExe } form to pin an explicit path.")
    }
    return @{ Name = $Name; WindowsExe = $null; Source = 'unresolved'; Warnings = $warnings.ToArray() }
}

function Get-HostShadowBinDir {
    # Per-project bin dir layout. Project name must be a bare slug (validated
    # via Test-Profile at profile-load time, so a clean spec never lands here
    # with traversal characters). The defensive throw catches direct callers.
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$Home = '/home/claude'
    )
    if ($ProjectName -match '[\\/\s]') {
        throw "Project name '$ProjectName' must be a bare slug (no slashes/whitespace)."
    }
    return "$Home/host-projects/$ProjectName/bin"
}

function Get-HostShadowInitScriptPath {
    # The per-project init script open-claudearium sources before exec'ing
    # claude. Putting `export PATH=<bin>:$PATH` in a sourced file (read by
    # bash from disk) sidesteps wsl2-gotchas.md #1: `wsl.exe` argv mangles
    # any literal `$PATH` to an empty string before bash sees it, so the
    # PATH prepend cannot live in the launch argv directly.
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$Home = '/home/claude'
    )
    if ($ProjectName -match '[\\/\s]') {
        throw "Project name '$ProjectName' must be a bare slug (no slashes/whitespace)."
    }
    return "$Home/host-projects/$ProjectName/init.sh"
}

function Install-HostShadowsForProject {
    # Reconcile wrappers in the project's per-session bin dir against the
    # supplied ResolvedShadows list. Wipes-and-rewrites the dir (it's small
    # and contents are deterministic from inputs). Idempotent: running twice
    # with the same input is a no-op.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName,
        # Array of @{ Name; WindowsExe } — already resolved by Resolve-HostShadow.
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ResolvedShadows,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    Initialize-WslInteropService -DistroName $DistroName

    $binDir = Get-HostShadowBinDir -ProjectName $ProjectName -Home $Home
    $parent = (Split-Path -Parent $binDir).Replace('\', '/')
    $owner  = "${User}:${User}"

    # Step 1: ensure the parent tree exists, owned by the project user. Wipe the
    # bin dir so removed shadows actually go away on re-apply.
    $setup = @(
        "set -e",
        "mkdir -p '$parent'",
        "chown -R $owner '$parent'",
        "rm -rf '$binDir'",
        "mkdir -p '$binDir'",
        "chown $owner '$binDir'"
    ) -join '; '
    Invoke-InDistro -Name $DistroName -User 'root' -Command $setup

    # Step 2: write the init.sh that open-claudearium sources. Constructed
    # with `'<bin>':` + `$PATH` joined as separate string fragments so we
    # never interpolate the empty pwsh `$PATH` here, only emit the literal.
    $initContent = "export PATH='$binDir':" + '$PATH' + "`n"
    $initNormalized = ($initContent -replace "`r`n", "`n")
    $initB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($initNormalized))
    $initPath = Get-HostShadowInitScriptPath -ProjectName $ProjectName -Home $Home
    $writeInit = "set -e; printf '%s' '$initB64' | base64 -d > '$initPath'; chmod 0644 '$initPath'; chown $owner '$initPath'"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $writeInit

    if ($ResolvedShadows.Count -eq 0) { return }

    # Step 3: write each wrapper. Reuse ConvertTo-WrapperContent from HostTools
    # so the marker line and exec form stay identical to the global wrappers.
    foreach ($s in $ResolvedShadows) {
        if (-not $s.Name -or -not $s.WindowsExe) { continue }
        $spec = @{ name = [string]$s.Name; windowsExe = [string]$s.WindowsExe; guestCommand = [string]$s.Name }
        $content    = ConvertTo-WrapperContent -ToolSpec $spec
        $normalized = ($content -replace "`r`n", "`n")
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
        $dest = "$binDir/$([string]$s.Name)"
        $cmd  = "set -e; printf '%s' '$b64' | base64 -d > '$dest'; chmod 0755 '$dest'; chown $owner '$dest'"
        Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
    }
}

function Remove-HostShadowsForProject {
    # Tear down /home/claude/host-projects/<project>/. Called from
    # `project remove` for hostProjects. Safe to call when the dir is absent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    if ($ProjectName -match '[\\/\s]') {
        throw "Project name '$ProjectName' must be a bare slug (no slashes/whitespace)."
    }
    $projectRoot = "$Home/host-projects/$ProjectName"
    Invoke-InDistro -Name $DistroName -User 'root' -Command "rm -rf '$projectRoot'" -AllowFail | Out-Null
}

Export-ModuleMember -Function `
    Get-HostShadowCatalog, `
    Find-HostShadowOnPath, `
    Resolve-HostShadow, `
    Get-HostShadowBinDir, `
    Get-HostShadowInitScriptPath, `
    Install-HostShadowsForProject, `
    Remove-HostShadowsForProject
