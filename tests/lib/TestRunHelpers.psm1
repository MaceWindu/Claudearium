# TestRunHelpers.psm1
# Shared helpers for tests/distro/* test files. Wraps the production
# `claudearium.ps1` so every invocation targets the ephemeral test distro
# AND an isolated test-only profile (never the user's real profile).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Script:ClaudeariumScript = Join-Path $Script:RepoRoot 'claudearium.ps1'

function New-IsolatedTestProfile {
    # Write a minimal profile to a per-file temp path so tests don't share
    # writeable state (and so they never touch the user's real profile under
    # %LOCALAPPDATA%\claudearium\claudearium.profile.json).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Tag,
        [string]$InstallPathOverride
    )
    $cacheDir = Join-Path $Script:RepoRoot 'tests\.cache'
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $path = Join-Path $cacheDir "profile-$Tag.json"
    $install = if ($InstallPathOverride) { $InstallPathOverride } else {
        Join-Path $env:LOCALAPPDATA (Join-Path 'WSL' $DistroName)
    }
    $spec = [ordered]@{
        schemaVersion = 1
        distro        = [ordered]@{
            name        = $DistroName
            base        = 'debian-12'
            installPath = $install
        }
    }
    ($spec | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-Claudearium {
    # Run `claudearium.ps1 <args>` against the test distro and the per-test
    # profile. Returns $LASTEXITCODE so tests can assert on the result.
    #
    # Args are passed as a hashtable and splatted into the call. This is the
    # only splat form that preserves named/switch parameter semantics:
    #   - Array splat `@array`  -> every element is positional, so `-Force`
    #     ends up as a positional string and pwsh rejects it.
    #   - Hashtable splat `@ht` -> each key becomes a named parameter, so
    #     `Force=$true` correctly binds to claudearium.ps1's [switch]$Force.
    #
    # Caller passes the verb/subverb/arg as named keys (claudearium.ps1's
    # positional params Verb / SubVerb / Arg accept named binding too):
    #
    #   Invoke-Claudearium -DistroName $d -ProfilePath $p -Args @{
    #       Verb='project'; SubVerb='remove'; Arg='foo'; Force=$true
    #   }
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Args,
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ProfilePath,
        [switch]$AllowFail
    )
    $h = @{} + $Args     # shallow copy so we don't mutate the caller's hashtable
    $h['Name']           = $DistroName
    $h['ProfilePath']    = $ProfilePath
    $h['NonInteractive'] = $true

    # Out-Host: the production script's wsl.exe / git stdout flows through the
    # pipeline; consuming it here keeps the test's pipeline clean.
    & $Script:ClaudeariumScript @h | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        $verb = if ($h.ContainsKey('Verb')) { [string]$h['Verb'] } else { '?' }
        $sub  = if ($h.ContainsKey('SubVerb')) { ' ' + [string]$h['SubVerb'] } else { '' }
        throw "claudearium.ps1 $verb$sub failed (exit $code)"
    }
    return $code
}

function Get-ClaudeariumScriptPath { return $Script:ClaudeariumScript }

function ConvertTo-ShareableContent {
    # Strip identifiers from a string so the resulting file is safe to attach
    # to a public bug report. Catches the common leaks: the account name in
    # paths, %USERPROFILE% / %LOCALAPPDATA% / %APPDATA% / the repo root, and
    # the machine name. Each sentinel is also matched in its JSON-escaped form
    # (`\\` for each `\`) and forward-slash form (`/` for each `\`), since
    # paths frequently round-trip through ConvertTo-Json or .NET path
    # normalization before reaching the file.
    [CmdletBinding()] param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return $Content }
    $out = $Content
    $pairs = @(
        @{ Value = $env:USERPROFILE;  Token = '<user-home>' }
        @{ Value = $env:LOCALAPPDATA; Token = '<localappdata>' }
        @{ Value = $env:APPDATA;      Token = '<appdata>' }
        @{ Value = $Script:RepoRoot;  Token = '<repo>' }
        @{ Value = $env:USERNAME;     Token = '<user>' }
        @{ Value = $env:COMPUTERNAME; Token = '<host>' }
    )
    foreach ($p in $pairs) {
        if (-not $p.Value) { continue }
        $variants = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$variants.Add($p.Value)
        if ($p.Value -match '\\') {
            # JSON-escaped form (each `\` -> `\\`) and forward-slash form
            # (each `\` -> `/`). Use String.Replace, not -replace: -replace
            # uses .NET regex replacement syntax, and although `\\\\` in a
            # replacement is literal `\\` in .NET (so the regex form would
            # actually work), the string-method form is unambiguous and
            # doesn't invite reviewers to second-guess the escape rules.
            [void]$variants.Add($p.Value.Replace('\', '\\'))
            [void]$variants.Add($p.Value.Replace('\', '/'))
        }
        foreach ($v in $variants) {
            $out = $out -replace ([regex]::Escape($v)), $p.Token
        }
    }
    return $out
}

Export-ModuleMember -Function `
    New-IsolatedTestProfile, Invoke-Claudearium, Get-ClaudeariumScriptPath, ConvertTo-ShareableContent
