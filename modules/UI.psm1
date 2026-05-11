# UI.psm1
# Lightweight prompt primitives for setup wizards. Pure pwsh, no deps.
#
# Public surface:
#   Read-YesNo  -Prompt <s> [-Default <bool>]              [-NonInteractive]
#   Read-Choice -Prompt <s> -Options <s[]> [-DefaultIndex] [-NonInteractive]
#   Read-Multi  -Prompt <s> -Options <hashtable[]>          [-NonInteractive]
#
# All three accept -NonInteractive; in that mode they return the default rather
# than prompting (so the same wizard code path works under -Force / scripted
# invocation). Read-Multi's Options entries are @{ Name = '...'; Selected =
# $true; Hint = '...' (optional) } — Selected is the initial state.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-YesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true,
        [switch]$NonInteractive
    )
    if ($NonInteractive) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host -Prompt "$Prompt $hint"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        $lc = $a.Trim().ToLowerInvariant()
        if ($lc -in @('y','yes')) { return $true }
        if ($lc -in @('n','no'))  { return $false }
        Write-Host '  please answer y or n.' -ForegroundColor Yellow
    }
}

function Read-Choice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Options,
        [int]$DefaultIndex = 0,
        [switch]$NonInteractive
    )
    if ($DefaultIndex -lt 0 -or $DefaultIndex -ge $Options.Length) {
        throw "DefaultIndex $DefaultIndex out of range (0..$($Options.Length-1))"
    }
    if ($NonInteractive) { return $Options[$DefaultIndex] }
    Write-Host ''
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Length; $i++) {
        $marker = if ($i -eq $DefaultIndex) { '*' } else { ' ' }
        Write-Host ('  {0} {1}) {2}' -f $marker, ($i + 1), $Options[$i])
    }
    while ($true) {
        $a = Read-Host -Prompt "  Choose [1-$($Options.Length)] (default $($DefaultIndex + 1))"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Options[$DefaultIndex] }
        if ($a -match '^\d+$') {
            $idx = [int]$a - 1
            if ($idx -ge 0 -and $idx -lt $Options.Length) { return $Options[$idx] }
        }
        Write-Host '  invalid choice.' -ForegroundColor Yellow
    }
}

function Read-Multi {
    [CmdletBinding()]
    param(
        # Each option: @{ Name = '...'; Selected = $true/$false; Hint = '...' (optional) }
        [Parameter(Mandatory)][hashtable[]]$Options,
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$NonInteractive
    )
    if ($NonInteractive) {
        return @($Options | Where-Object { $_.Selected } | ForEach-Object { $_.Name })
    }
    $sel = [System.Collections.Generic.List[bool]]::new()
    foreach ($o in $Options) { $sel.Add([bool]($o.Selected)) }

    while ($true) {
        Write-Host ''
        Write-Host $Prompt
        for ($i = 0; $i -lt $Options.Length; $i++) {
            $box  = if ($sel[$i]) { '[x]' } else { '[ ]' }
            $hint = if ($Options[$i].ContainsKey('Hint') -and $Options[$i].Hint) { "  ($($Options[$i].Hint))" } else { '' }
            Write-Host ('  {0} {1}) {2}{3}' -f $box, ($i + 1), $Options[$i].Name, $hint)
        }
        Write-Host "  Toggle by number (e.g. 3 or 1,3,5); 'a' = all, 'n' = none, Enter = accept"
        $a = (Read-Host -Prompt '  >').Trim()
        if ([string]::IsNullOrWhiteSpace($a)) { break }
        $lc = $a.ToLowerInvariant()
        if ($lc -eq 'a') {
            for ($i = 0; $i -lt $sel.Count; $i++) { $sel[$i] = $true }
        }
        elseif ($lc -eq 'n') {
            for ($i = 0; $i -lt $sel.Count; $i++) { $sel[$i] = $false }
        }
        elseif ($lc -match '^\d+(\s*,\s*\d+)*$') {
            foreach ($t in ($lc -split ',')) {
                $idx = [int]$t.Trim() - 1
                if ($idx -ge 0 -and $idx -lt $sel.Count) { $sel[$idx] = -not $sel[$idx] }
            }
        }
        else {
            Write-Host '  invalid input.' -ForegroundColor Yellow
        }
    }
    $result = @()
    for ($i = 0; $i -lt $sel.Count; $i++) { if ($sel[$i]) { $result += $Options[$i].Name } }
    return ,$result
}

Export-ModuleMember -Function Read-YesNo, Read-Choice, Read-Multi
