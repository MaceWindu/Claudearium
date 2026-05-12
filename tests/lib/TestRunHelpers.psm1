# TestRunHelpers.psm1
# Shared helpers for tests/distro/* test files. Wraps the production
# `claudearium.ps1` so every invocation targets the ephemeral test distro
# AND an isolated test-only profile (never the user's real profile).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Script:ClaudearcumScript = Join-Path $Script:RepoRoot 'claudearium.ps1'

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
    & $Script:ClaudearcumScript @h | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        $verb = if ($h.ContainsKey('Verb')) { [string]$h['Verb'] } else { '?' }
        $sub  = if ($h.ContainsKey('SubVerb')) { ' ' + [string]$h['SubVerb'] } else { '' }
        throw "claudearium.ps1 $verb$sub failed (exit $code)"
    }
    return $code
}

function Get-ClaudearcumScriptPath { return $Script:ClaudearcumScript }

Export-ModuleMember -Function `
    New-IsolatedTestProfile, Invoke-Claudearium, Get-ClaudearcumScriptPath
