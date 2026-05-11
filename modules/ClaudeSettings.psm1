# ClaudeSettings.psm1
# Synthesizes Claude Code's /home/claude/.claude/settings.json from two layers
# merged together (see docs/design-decisions.md#9-profile-is-a-single-json-file):
#
#   1. ALWAYS-SET (Get-AlwaysSettings) — sandbox-invariant bits the user
#      doesn't get to override: cleanupPeriodDays, includeCoAuthoredBy=false,
#      env.CLAUDEARIUM_NAME/MODE, dangerous-Bash deny patterns.
#   2. OPINIONATED (Get-OpinionatedSettings) — from profile.claudeSettings:
#      model + effort bracket, theme, auto-approve buckets, claudelk hooks.
#
# Bash permission patterns use the current ` *` arg-suffix syntax (not the
# obsoleted `:*` form).
#
# Public surface:
#   Get-AlwaysSettings      -DistroName                     — immutable bits
#   Get-OpinionatedSettings -Spec <h>                       — translate profile.claudeSettings
#   Merge-Settings          -Always -Opinionated            — shallow merge w/ array concat+dedupe
#   ConvertTo-ClaudeSettingsJson -DistroName -Spec          — final JSON string
#   Install-ClaudeSettings  -DistroName -Spec               — write + chmod + chown
#   Get-ClaudeSettingsActualFromDistro -DistroName          — read + parse current settings.json
#   Test-ClaudeSettingsDrift -DistroName -DesiredSpec        — (unused by reconcile, see note below)
#
# Reconcile note: claudeSettings is deliberately NOT part of the reconciler's
# diff. Hashtable-key ordering through ConvertTo-Json varies across pwsh
# invocations, so a string-compare of two serializations of the same data
# isn't reliable. Users apply settings explicitly via
# `claude-settings apply` / `reconfigure`. See docs/design-decisions.md#10.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')

function Get-AlwaysSettings {
    # The non-negotiable parts of the sandbox's Claude Code config.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    return @{
        cleanupPeriodDays = 30
        includeCoAuthoredBy = $false
        env = @{
            CLAUDEARIUM_NAME = $DistroName
            CLAUDEARIUM_MODE = 'wsl2'
        }
        permissions = @{
            deny = @(
                'Bash(rm -rf /*)'
                'Bash(* | sh *)'
                'Bash(* | bash *)'
                'Bash(curl * | sh *)'
                'Bash(curl * | bash *)'
                'Bash(wget * | sh *)'
                'Bash(wget * | bash *)'
            )
            allow = @()
        }
    }
}

function Get-OpinionatedSettings {
    # Translate profile.claudeSettings -> a settings.json fragment that gets
    # merged on top of Get-AlwaysSettings.
    [CmdletBinding()] param([Parameter(Mandatory)][hashtable]$Spec)
    $r = @{
        permissions = @{ allow = @() }
        hooks = @{}
    }

    # Model + optional effort bracket.
    if ($Spec.ContainsKey('model') -and $Spec.model) {
        $m = [string]$Spec.model
        if ($Spec.ContainsKey('defaultEffort') -and $Spec.defaultEffort -and $m -notmatch '\[') {
            $m = "$m[$([string]$Spec.defaultEffort)]"
        }
        $r.model = $m
    }
    if ($Spec.ContainsKey('theme') -and $Spec.theme) {
        $r.theme = [string]$Spec.theme
    }

    # Auto-approve buckets — purely additive Allow entries.
    if ($Spec.ContainsKey('autoApproveReadOnlyBash') -and $Spec.autoApproveReadOnlyBash) {
        $r.permissions.allow += @(
            'Bash(git status *)'
            'Bash(git log *)'
            'Bash(git diff *)'
            'Bash(git show *)'
            'Bash(git branch *)'
            'Bash(ls *)'
            'Bash(cat *)'
            'Bash(head *)'
            'Bash(tail *)'
            'Bash(pwd)'
            'Bash(echo *)'
            'Bash(which *)'
            'Bash(whoami)'
            'Bash(gh *)'
            'Bash(glab *)'
            'Bash(acli *)'
            'Bash(seqcli *)'
        )
    }
    if ($Spec.ContainsKey('autoApproveProjectWrites') -and $Spec.autoApproveProjectWrites) {
        $r.permissions.allow += @('Edit', 'Write', 'Glob', 'Grep')
    }
    if ($Spec.ContainsKey('autoApproveBuildCommands') -and $Spec.autoApproveBuildCommands) {
        $r.permissions.allow += @(
            'Bash(dotnet build *)'
            'Bash(dotnet test *)'
            'Bash(dotnet restore *)'
            'Bash(dotnet run *)'
            'Bash(npm install *)'
            'Bash(npm run build *)'
            'Bash(npm run test *)'
            'Bash(npm ci *)'
        )
    }

    # Claudelk hooks — wired in based on the profile's claudelk flag + selected
    # events. Command is 'sb-claudelk <args>'; the host-tools subsystem is
    # responsible for installing the sb-claudelk wrapper.
    if ($Spec.ContainsKey('claudelk') -and $Spec.claudelk) {
        $events = @('Stop','Notification')
        if ($Spec.ContainsKey('claudelkEvents') -and $Spec.claudelkEvents) {
            $events = @($Spec.claudelkEvents)
        }
        foreach ($evt in $events) {
            $color = switch ($evt) {
                'Stop'         { '#00ff00' }
                'Notification' { '#ff8800' }
                'PreToolUse'   { '#0080ff' }
                'SessionStart' { '#ffffff' }
                default        { '#888888' }
            }
            if (-not $r.hooks.ContainsKey($evt)) { $r.hooks[$evt] = @() }
            $r.hooks[$evt] += @{
                matcher = '*'
                hooks   = @(@{
                    type    = 'command'
                    command = "sb-claudelk color '$color'"
                    async   = $true
                })
            }
        }
    }

    return $r
}

function Merge-Settings {
    # Shallow merge of two settings hashtables. Permission/env hashtables get
    # one extra level of merging (arrays concatenated, scalars overwritten).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Always,
        [Parameter(Mandatory)][hashtable]$Opinionated
    )
    $out = @{}
    foreach ($k in $Always.Keys) { $out[$k] = $Always[$k] }
    foreach ($k in $Opinionated.Keys) {
        if ($out.ContainsKey($k) -and $out[$k] -is [hashtable] -and $Opinionated[$k] -is [hashtable]) {
            $sub = @{}
            foreach ($kk in $out[$k].Keys) { $sub[$kk] = $out[$k][$kk] }
            foreach ($kk in $Opinionated[$k].Keys) {
                $aVal = if ($sub.ContainsKey($kk)) { $sub[$kk] } else { $null }
                $bVal = $Opinionated[$k][$kk]
                if ($aVal -is [System.Collections.IList] -and $bVal -is [System.Collections.IList]) {
                    # Concat + dedupe for permission lists, etc.
                    $sub[$kk] = @(@($aVal) + @($bVal) | Select-Object -Unique)
                }
                else {
                    $sub[$kk] = $bVal
                }
            }
            $out[$k] = $sub
        }
        else {
            $out[$k] = $Opinionated[$k]
        }
    }
    return $out
}

function ConvertTo-ClaudeSettingsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$Spec
    )
    $always = Get-AlwaysSettings -DistroName $DistroName
    $opinionated = Get-OpinionatedSettings -Spec $Spec
    $merged = Merge-Settings -Always $always -Opinionated $opinionated
    return ($merged | ConvertTo-Json -Depth 16)
}

function Install-ClaudeSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$Spec
    )
    $json = ConvertTo-ClaudeSettingsJson -DistroName $DistroName -Spec $Spec
    $normalized = ($json -replace "`r`n", "`n")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $cmd = "set -e; mkdir -p /home/claude/.claude; " +
           "printf '%s' '$b64' | base64 -d > /home/claude/.claude/settings.json; " +
           "chown -R claude:claude /home/claude/.claude; " +
           "chmod 0644 /home/claude/.claude/settings.json"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Get-ClaudeSettingsActualFromDistro {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command 'cat /home/claude/.claude/settings.json 2>/dev/null || echo "{}"' -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return $null }
    $jsonLines = @($r.Output | Where-Object { $_ -is [string] -and ($_.Trim() -ne '') })
    $json = $jsonLines -join "`n"
    if (-not $json -or $json.Trim() -eq '{}') { return $null }
    try { return ($json | ConvertFrom-Json -Depth 16 -AsHashtable) } catch { return $null }
}

function Test-ClaudeSettingsDrift {
    # Cheap drift check: stringify the desired and actual hashtables and
    # compare. Used by reconcile to decide whether to re-apply.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()][hashtable]$DesiredSpec
    )
    if (-not $DesiredSpec) { return $false }
    $desiredJson = ConvertTo-ClaudeSettingsJson -DistroName $DistroName -Spec $DesiredSpec
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command 'cat /home/claude/.claude/settings.json 2>/dev/null' -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return $true } # not present -> drifted
    $actualJson = @($r.Output | Where-Object { $_ -is [string] }) -join "`n"
    return ($desiredJson.Trim() -ne $actualJson.Trim())
}

Export-ModuleMember -Function `
    Get-AlwaysSettings, `
    Get-OpinionatedSettings, `
    Merge-Settings, `
    ConvertTo-ClaudeSettingsJson, `
    Install-ClaudeSettings, `
    Get-ClaudeSettingsActualFromDistro, `
    Test-ClaudeSettingsDrift
