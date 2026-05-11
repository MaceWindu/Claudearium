# State.psm1
# Per-distro state-file management at %LOCALAPPDATA%\claudearium\<distro>\state.json.
#
# State is the *actual* side of the profile-vs-state model (see
# docs/architecture.md). The user doesn't edit it directly — the tool owns it
# and uses it to track what has actually been provisioned, plus ephemeral
# metadata (sessions, recents, last-opened timestamps) that doesn't belong in
# the declarative profile.
#
# Public surface:
#   Get-StateRoot                                   — root dir under LOCALAPPDATA
#   Get-StatePath        -DistroName <s>            — full path to state.json
#   Test-State           -DistroName <s>            — does state exist?
#   Read-State           -DistroName <s>            — parse JSON -> hashtable
#   Write-State          -DistroName <s> -State <h> — atomic .tmp-then-Move
#   Initialize-State     -DistroName <s>            — fresh state shape
#   Remove-State         -DistroName <s>            — purge state dir
#   Add-Recent           -State <h> -Key <s> -Value <s> [-Max <n>]
#                                                   — dedup most-recent-wins, trim
#
# Schema invariants: schemaVersion is set on every Write-State; createdAt is
# set once at Initialize-State, updatedAt is bumped on every write.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:StateSchemaVersion = 1

function Get-StateRoot {
    [CmdletBinding()]
    param()
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; cannot resolve state root.' }
    return (Join-Path $env:LOCALAPPDATA 'claudearium')
}

function Get-StatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    return (Join-Path (Join-Path (Get-StateRoot) $DistroName) 'state.json')
}

function Test-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    return (Test-Path (Get-StatePath -DistroName $DistroName))
}

function Read-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $path = Get-StatePath -DistroName $DistroName
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 16 -AsHashtable)
}

function Write-State {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State
    )
    $path = Get-StatePath -DistroName $DistroName
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $State.schemaVersion = $Script:StateSchemaVersion
    $State.updatedAt     = (Get-Date).ToString('o')
    $tmp = "$path.tmp"
    $State | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Initialize-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $now = (Get-Date).ToString('o')
    return @{
        schemaVersion = $Script:StateSchemaVersion
        distro        = $DistroName
        createdAt     = $now
        updatedAt     = $now
        provisioned   = $false
    }
}

function Remove-State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $dir = Join-Path (Get-StateRoot) $DistroName
    if (Test-Path $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

function Add-Recent {
    # Push a value onto a recents list inside $State.recents.$Key. Deduplicates
    # (most-recent-wins) and trims to $Max entries.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value,
        [int]$Max = 5
    )
    if (-not $State.ContainsKey('recents')) { $State['recents'] = @{} }
    if (-not $State.recents.ContainsKey($Key)) { $State.recents[$Key] = @() }
    $cur = @($State.recents[$Key] | Where-Object { $_ -ne $Value })
    $merged = ,$Value + $cur
    $State.recents[$Key] = @($merged | Select-Object -First $Max)
}

Export-ModuleMember -Function `
    Get-StateRoot, `
    Get-StatePath, `
    Test-State, `
    Read-State, `
    Write-State, `
    Initialize-State, `
    Remove-State, `
    Add-Recent
