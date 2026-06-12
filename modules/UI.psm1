# UI.psm1
# Lightweight prompt primitives for setup wizards. Pure pwsh, no deps.
#
# Public surface:
#   Read-YesNo           -Prompt <s> [-Default <bool>]              [-NonInteractive]
#   Read-Choice          -Prompt <s> -Options <s[]> [-DefaultIndex] [-NonInteractive]
#   Read-Multi           -Prompt <s> -Options <hashtable[]>          [-NonInteractive]
#   Read-TabColor        -Prompt <s> [-Default <hex|''|'<inherit>'>] [-AllowInherit] [-NonInteractive]
#   Show-DashboardAction -Label <s>  — clear-host + print '> <label>' header; used by
#                                       dashboard dispatch so prior action output stays
#                                       on screen until the user picks the next command
#
# All accept -NonInteractive; in that mode they return the default rather
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

function Read-TabColor {
    # Prompt for a Windows Terminal tab color and return one of:
    #   - a '#RRGGBB' hex string  — explicit color
    #   - '' (empty string)        — explicit "no color"
    #   - '<inherit>'              — only when -AllowInherit is passed (means: fall back
    #                                to a parent/project color at apply time)
    # -Default may be any of those forms; Enter on the prompt returns it unchanged.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [AllowNull()][AllowEmptyString()][string]$Default = '',
        [switch]$AllowInherit,
        [switch]$NonInteractive
    )
    if ($NonInteractive) { return $Default }

    $palette = @(
        @{ Name = 'red';     Hex = '#E81123' }
        @{ Name = 'orange';  Hex = '#FF8C00' }
        @{ Name = 'yellow';  Hex = '#FFEB3B' }
        @{ Name = 'green';   Hex = '#16C60C' }
        @{ Name = 'teal';    Hex = '#00B7C3' }
        @{ Name = 'blue';    Hex = '#0078D7' }
        @{ Name = 'purple';  Hex = '#886CE4' }
        @{ Name = 'magenta'; Hex = '#E81F76' }
        @{ Name = 'gray';    Hex = '#5D5D5D' }
    )

    $defLabel = if ($Default -eq '<inherit>')        { 'inherit project default' }
                elseif ([string]::IsNullOrEmpty($Default)) { 'none' }
                else                                       { $Default }

    Write-Host ''
    Write-Host "$Prompt (Enter = $defLabel):"
    for ($i = 0; $i -lt $palette.Count; $i++) {
        Write-Host ('  {0,2}) {1,-8} {2}' -f ($i + 1), $palette[$i].Name, $palette[$i].Hex)
    }
    $next = $palette.Count + 1
    $inheritIdx = $null
    if ($AllowInherit) { Write-Host ('  {0,2}) inherit project default' -f $next); $inheritIdx = $next; $next++ }
    $noneIdx   = $next; Write-Host ('  {0,2}) none (no color)'      -f $next); $next++
    $customIdx = $next; Write-Host ('  {0,2}) custom hex #RRGGBB'   -f $next)

    while ($true) {
        $a = (Read-Host '  >').Trim()
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        if ($a -match '^\d+$') {
            $idx = [int]$a
            if ($idx -ge 1 -and $idx -le $palette.Count)            { return $palette[$idx - 1].Hex }
            if ($inheritIdx -and $idx -eq $inheritIdx)              { return '<inherit>' }
            if ($idx -eq $noneIdx)                                   { return '' }
            if ($idx -eq $customIdx) {
                $h = (Read-Host '  Hex (#RRGGBB)').Trim()
                if ([string]::IsNullOrWhiteSpace($h)) { continue }
                if ($h -match '^#[0-9A-Fa-f]{6}$') { return $h }
                Write-Host '  invalid hex; expected #RRGGBB.' -ForegroundColor Yellow
                continue
            }
        }
        if ($a -match '^#[0-9A-Fa-f]{6}$') { return $a }
        Write-Host '  invalid choice.' -ForegroundColor Yellow
    }
}

function Read-OpacityPercent {
    # Prompt for an opacity percent 0-100 (0 = fully transparent, 100 = solid).
    # Returns an [int] in range, or $null when the user presses Enter (meaning
    # "use the default" — the caller decides what that is). Re-prompts on junk.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$NonInteractive
    )
    if ($NonInteractive) { return $null }
    Write-Host ''
    Write-Host "$Prompt"
    while ($true) {
        $a = (Read-Host '  > (0-100, Enter to skip)').Trim()
        if ([string]::IsNullOrWhiteSpace($a)) { return $null }
        if ($a -match '^\d+$' -and [int]$a -ge 0 -and [int]$a -le 100) { return [int]$a }
        Write-Host '  invalid; enter a whole number 0-100.' -ForegroundColor Yellow
    }
}

function Show-DashboardAction {
    # Clear the screen and print a short header naming the action that is about
    # to run. Called from dashboard dispatch after the user picks a menu item:
    # the user's previous action's output stays on screen until the next pick,
    # then this wipes it and labels what's coming so the user isn't disoriented.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Label)
    Clear-Host
    Write-Host ("  > {0}" -f $Label) -ForegroundColor DarkGray
    Write-Host ''
}

Export-ModuleMember -Function Read-YesNo, Read-Choice, Read-Multi, Read-TabColor, Read-OpacityPercent, Show-DashboardAction
