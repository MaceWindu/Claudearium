# Temp.psm1
# Runtime scratch / cache cleanup. Three scopes, each independently sized
# and wipeable:
#
#   tmp     — /tmp (tmpfs). Fully safe to wipe; reboot does it anyway.
#   cache   — /home/claude/.cache (xdg cache). Safe but slow first-rebuild
#             (npm/pip/cargo redownloads).
#   claude  — /home/claude/.claude (Claude Code state). Destructive by
#             default for transcripts + shell-snapshots; preserves todos
#             + plans + host-tools unless -IncludeTodos / -IncludePlans
#             is set.
#
# Sizes come from a single in-distro `du -sb` invocation so the dashboard
# render budget stays sub-second.
#
# Public surface:
#   Get-ScratchSizes  -DistroName                          — @{ tmp, cache, claude, total }, bytes
#   Clear-Scratch     -DistroName -Scope [-IncludeTodos -IncludePlans]
#                                                          — wipe the named scope, return @{ Removed; PreservedNote }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')

# What `~/.claude/` paths the 'claude' scope wipes by default vs. preserves.
# The wipe set covers ephemeral stuff Claude Code regenerates on next run;
# the preserve set is in-flight user work (todos, plans) and our own managed
# tree (host-tools/). Both are arrays so the verb can render them in the
# preview before destruction.
$Script:ClaudeStateWipeDirs       = @('projects', 'shell-snapshots')
$Script:ClaudeStatePreservedDirs  = @('todos', 'plans', 'host-tools')

function Get-ScratchSizes {
    # Batched single in-distro call: one `du -sb` per dir, output parsed by
    # path. Missing dirs produce zero (so the cache score is honest even on
    # a fresh distro that hasn't run npm/pip yet). Each `du` is capped with
    # `timeout 3` so a cold page cache or a months-old ~/.claude transcript
    # tree can't block the dashboard render — on timeout we treat the size
    # as 0 and the caller is free to retry from the verb (which has no
    # such latency budget).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $cmd = @'
for d in /tmp /home/claude/.cache /home/claude/.claude; do
  if [ -d "$d" ]; then
    sz=$(timeout 3 du -sb "$d" 2>/dev/null | cut -f1)
    if [ -z "$sz" ]; then sz=0; fi
    printf '%s\t%s\n' "$d" "$sz"
  else
    printf '%s\t0\n' "$d"
  fi
done
'@
    $r = Invoke-InDistroScript -Name $DistroName -User 'claude' -Script $cmd -AllowFail -CaptureOutput
    $sizes = @{ tmp = 0L; cache = 0L; claude = 0L; total = 0L }
    if ($r.ExitCode -ne 0) { return $sizes }
    foreach ($line in @($r.Output)) {
        $s = [string]$line
        if ($s -match '^/tmp\s+(\d+)$')                       { $sizes.tmp    = [long]$Matches[1] }
        elseif ($s -match '^/home/claude/\.cache\s+(\d+)$')   { $sizes.cache  = [long]$Matches[1] }
        elseif ($s -match '^/home/claude/\.claude\s+(\d+)$')  { $sizes.claude = [long]$Matches[1] }
    }
    $sizes.total = $sizes.tmp + $sizes.cache + $sizes.claude
    return $sizes
}

function Clear-Scratch {
    # Wipe one scope and return what was done. Single in-distro script per
    # call so failures atomic (or at least scoped to one shell pipeline).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][ValidateSet('tmp','cache','claude')][string]$Scope,
        [switch]$IncludeTodos,
        [switch]$IncludePlans
    )
    switch ($Scope) {
        'tmp' {
            # mindepth 1 keeps the /tmp mountpoint itself.
            $script = 'find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; echo done'
            Invoke-InDistroScript -Name $DistroName -User 'claude' -Script $script -AllowFail | Out-Null
            return @{ Removed = '/tmp/*'; PreservedNote = 'reboot does this too — safe to wipe anytime' }
        }
        'cache' {
            $script = '[ -d /home/claude/.cache ] && find /home/claude/.cache -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; echo done'
            Invoke-InDistroScript -Name $DistroName -User 'claude' -Script $script -AllowFail | Out-Null
            return @{ Removed = '~/.cache/*'; PreservedNote = 'first-build penalty applies as npm/pip/cargo redownload' }
        }
        'claude' {
            # Build the wipe list dynamically so -IncludeTodos / -IncludePlans
            # add to it without us hard-coding two extra paths in the bash side.
            $wipeDirs = @($Script:ClaudeStateWipeDirs)
            if ($IncludeTodos) { $wipeDirs += 'todos' }
            if ($IncludePlans) { $wipeDirs += 'plans' }
            $removed = @()
            $body = ''
            foreach ($d in $wipeDirs) {
                $body += "[ -d /home/claude/.claude/$d ] && find /home/claude/.claude/$d -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null`n"
                $removed += "~/.claude/$d/*"
            }
            $body += "echo done`n"
            Invoke-InDistroScript -Name $DistroName -User 'claude' -Script $body -AllowFail | Out-Null
            $preservedDirs = $Script:ClaudeStatePreservedDirs | Where-Object { $_ -ne $null -and ($wipeDirs -notcontains $_) }
            $note = if ($preservedDirs) { "preserved: " + (($preservedDirs | ForEach-Object { "~/.claude/$_/" }) -join ', ') } else { 'every subdir wiped' }
            return @{ Removed = ($removed -join ', '); PreservedNote = $note }
        }
    }
}

Export-ModuleMember -Function `
    Get-ScratchSizes, `
    Clear-Scratch
