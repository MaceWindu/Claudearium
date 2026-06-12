# ClaudeSettings.psm1
# Synthesizes Claude Code's /home/claude/.claude/settings.json from two layers
# merged together (see docs/design-decisions.md#9-profile-is-a-single-json-file):
#
#   1. ALWAYS-SET (Get-AlwaysSettings) — sandbox-invariant bits the user
#      doesn't fully override: attribution (empty commit/pr byline — the
#      replacement for the deprecated includeCoAuthoredBy=false), env.CLAUDEARIUM_*,
#      dangerous-Bash deny patterns, and a 30-day cleanupPeriodDays default.
#   2. OPINIONATED (Get-OpinionatedSettings) — from profile.claudeSettings:
#      model (verbatim), effortLevel (top-level key), theme, auto-approve
#      buckets, claudelk hooks, permission extensions
#      (permissions.additionalAllow/Deny/Ask/Directories + defaultMode),
#      alwaysThinkingEnabled, autoUpdatesChannel, disableBypassPermissionsMode,
#      disableWorkflows, cleanupPeriodDays override, tui, defaultShell,
#      editorMode, outputStyle.
#
# Bash permission patterns use the current ` *` arg-suffix syntax (not the
# obsoleted `:*` form).
#
# Public surface:
#   Get-AlwaysSettings      -DistroName                     — immutable bits
#   Get-OpinionatedSettings -Spec <h>                       — translate profile.claudeSettings
#   Merge-Settings          -Always -Opinionated            — shallow merge w/ array concat+dedupe
#   ConvertTo-ClaudeSettingsJson -DistroName -Spec          — final JSON string
#   Install-ClaudeSettings  -DistroName -Spec [-User -Home]  — write + chmod + chown
#   Get-ClaudeSettingsActualFromDistro -DistroName [-User -Home] — read + parse current settings.json
#   Test-ClaudeSettingsDrift -DistroName -DesiredSpec [-Home] — (unused by reconcile, see note below)
#
# -User/-Home default to the legacy single 'claude' / '/home/claude'; under
# per-project user isolation the caller fans the apply out to each project
# user's home so the agent running as that user sees the settings.
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
    # cleanupPeriodDays carries a 30-day default that the profile can override
    # via claudeSettings.cleanupPeriodDays (see Get-OpinionatedSettings).
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    return @{
        cleanupPeriodDays = 30
        # attribution replaces the deprecated includeCoAuthoredBy boolean: empty
        # commit/pr strings suppress the "Generated with Claude Code" / co-authored-by
        # byline entirely, matching the old includeCoAuthoredBy=false behavior.
        attribution = @{
            commit = ''
            pr     = ''
        }
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

    # Model + effort. Effort is emitted as its own top-level effortLevel key
    # (the documented Claude Code setting) rather than folded into a
    # model[effort] bracket. A model string the user hand-bracketed still
    # passes through verbatim.
    if ($Spec.ContainsKey('model') -and $Spec.model) {
        $r.model = [string]$Spec.model
    }
    if ($Spec.ContainsKey('defaultEffort') -and $Spec.defaultEffort) {
        $r.effortLevel = [string]$Spec.defaultEffort
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

    # Permission extensions — free-form lists that layer on top of the
    # auto-approve buckets. additionalDeny gets merged with the hardcoded
    # sandbox denies (Merge-Settings concatenates + dedupes, and Claude Code's
    # permission engine has deny-wins-over-allow semantics — see
    # docs/usage.md#claude-settings for the precedence story).
    if ($Spec.ContainsKey('permissions') -and $Spec.permissions -is [hashtable]) {
        $sp = $Spec.permissions
        if ($sp.ContainsKey('additionalAllow') -and $sp.additionalAllow) {
            $r.permissions.allow += @($sp.additionalAllow | Where-Object { $_ -is [string] -and $_ })
        }
        if ($sp.ContainsKey('additionalDeny') -and $sp.additionalDeny) {
            $r.permissions.deny = @($sp.additionalDeny | Where-Object { $_ -is [string] -and $_ })
        }
        if ($sp.ContainsKey('additionalAsk') -and $sp.additionalAsk) {
            $r.permissions.ask = @($sp.additionalAsk | Where-Object { $_ -is [string] -and $_ })
        }
        if ($sp.ContainsKey('additionalDirectories') -and $sp.additionalDirectories) {
            $r.permissions.additionalDirectories = @($sp.additionalDirectories | Where-Object { $_ -is [string] -and $_ })
        }
        if ($sp.ContainsKey('defaultMode') -and $sp.defaultMode) {
            $r.permissions.defaultMode = [string]$sp.defaultMode
        }
    }

    # Behavior / safety knobs.
    if ($Spec.ContainsKey('alwaysThinkingEnabled') -and $null -ne $Spec.alwaysThinkingEnabled) {
        $r.alwaysThinkingEnabled = [bool]$Spec.alwaysThinkingEnabled
    }
    if ($Spec.ContainsKey('autoUpdatesChannel') -and $Spec.autoUpdatesChannel) {
        $r.autoUpdatesChannel = [string]$Spec.autoUpdatesChannel
    }
    if ($Spec.ContainsKey('disableBypassPermissionsMode') -and $null -ne $Spec.disableBypassPermissionsMode) {
        $r.disableBypassPermissionsMode = [bool]$Spec.disableBypassPermissionsMode
    }
    if ($Spec.ContainsKey('disableWorkflows') -and $null -ne $Spec.disableWorkflows) {
        $r.disableWorkflows = [bool]$Spec.disableWorkflows
    }

    # Misc / display.
    if ($Spec.ContainsKey('cleanupPeriodDays') -and $null -ne $Spec.cleanupPeriodDays) {
        $r.cleanupPeriodDays = [int]$Spec.cleanupPeriodDays
    }
    if ($Spec.ContainsKey('tui') -and $Spec.tui) {
        $r.tui = [string]$Spec.tui
    }
    if ($Spec.ContainsKey('defaultShell') -and $Spec.defaultShell) {
        $r.defaultShell = [string]$Spec.defaultShell
    }
    if ($Spec.ContainsKey('editorMode') -and $Spec.editorMode) {
        $r.editorMode = [string]$Spec.editorMode
    }
    if ($Spec.ContainsKey('outputStyle') -and $Spec.outputStyle) {
        $r.outputStyle = [string]$Spec.outputStyle
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
    # Writes the synthesized settings.json into a home's ~/.claude. -User/-Home
    # default to the legacy single 'claude' / '/home/claude'; under per-project
    # user isolation the caller applies to each project user's home (the content
    # is identical, only the destination + owner differ).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$Spec,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $json = ConvertTo-ClaudeSettingsJson -DistroName $DistroName -Spec $Spec
    $normalized = ($json -replace "`r`n", "`n")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $qDir = ConvertTo-BashQuoted "$Home/.claude"
    $qFile = ConvertTo-BashQuoted "$Home/.claude/settings.json"
    $owner = "${User}:${User}"
    # chown the dir + the file we wrote, NOT -R: ~/.claude now holds symlinks into
    # the shared store (CLAUDE.md, skills, agents, host-tools), which is a
    # drvfs-mounted host folder. A recursive chown is both unnecessary
    # (settings.json is the only thing we own here) and a footgun — it would
    # re-own the symlinks (and walk into the mount). Claude's own per-user dirs are
    # already user-owned.
    $cmd = "set -e; mkdir -p $qDir; " +
           "printf '%s' '$b64' | base64 -d > $qFile; " +
           "chown $owner $qDir $qFile; " +
           "chmod 0644 $qFile"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Get-ClaudeSettingsActualFromDistro {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$DistroName,
        [string]$User = 'claude',
        [string]$Home = '/home/claude'
    )
    $qFile = ConvertTo-BashQuoted "$Home/.claude/settings.json"
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command "cat $qFile 2>/dev/null || echo '{}'" -AllowFail -CaptureOutput
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
        [AllowNull()][hashtable]$DesiredSpec,
        [string]$Home = '/home/claude'
    )
    if (-not $DesiredSpec) { return $false }
    $desiredJson = ConvertTo-ClaudeSettingsJson -DistroName $DistroName -Spec $DesiredSpec
    $qFile = ConvertTo-BashQuoted "$Home/.claude/settings.json"
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command "cat $qFile 2>/dev/null" -AllowFail -CaptureOutput
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
