# HostToolNotes.psm1
# Wires the per-tool path-arg pitfalls into the in-distro Claude Code account:
#   - Per-tool notes land at /home/claude/.claude/host-tools/<tool>.md
#     (sourced from templates/host-tool-notes/<tool>.md).
#   - A managed block in /home/claude/.claude/CLAUDE.md contains the one-line
#     "argv paths need wslpath -w / stdin" caveat plus path references to the
#     per-tool files. Hybrid loading: critical rule is always in context;
#     deep recipes are lazy-loaded by Claude on demand via Read.
#
# Idempotency: the managed block is bracketed by
#   <!-- claudearium-host-tools-begin -->  ...  <!-- claudearium-host-tools-end -->
# so apply can strip-and-replace without touching the user's own CLAUDE.md
# content. Apply runs at the tail of reconcile (after claudeFile) and from the
# host-tools add / remove / sync / scan + tools attach flows.
#
# Only "drop-in" catalog host-tools get notes — a hostTools[] entry whose
# guestCommand matches a catalog tool name with HostExeNames declared
# (gh / glab / acli / seqcli today). Custom sb-prefixed wrappers are ignored.
#
# Public surface:
#   Get-CatalogHostAttached -Spec               — list of catalog tool names
#                                                  host-attached drop-in
#   Get-HostToolNoteTemplate -ToolName          — template file content (LF) or $null
#   ConvertTo-ManagedBlock -ToolNames           — managed CLAUDE.md fragment
#                                                  (or '' when no tools)
#   Edit-ClaudeFileWithBlock -Content -Block    — strip old block, append new
#                                                  (or just strip when -Block '')
#   Install-HostToolNotes -DistroName -Spec [-User -Home] [-Root -Owner -FileMode]
#                                                — main entry: writes per-tool files
#                                                  + updates CLAUDE.md under -Root
#                                                  (default <home>/.claude). Under
#                                                  the shared-store model the caller
#                                                  points -Root at the store and
#                                                  -Owner at root:claudeshared so the
#                                                  managed block is written ONCE, not
#                                                  fanned per user.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Tools.psm1')

$Script:BlockBegin = '<!-- claudearium-host-tools-begin -->'
$Script:BlockEnd   = '<!-- claudearium-host-tools-end -->'

function Get-CatalogHostAttached {
    # From a profile spec, return the names of catalog tools that are
    # host-attached under the drop-in convention (hostTools[].guestCommand
    # equals a catalog name AND the catalog entry has HostExeNames).
    # Custom sb-prefixed wrappers don't get notes — they're arbitrary tools.
    [CmdletBinding()]
    param([AllowNull()]$Spec)
    $names = @()
    if (-not $Spec -or -not ($Spec -is [hashtable])) { return ,$names }
    if (-not $Spec.ContainsKey('hostTools') -or -not $Spec.hostTools) { return ,$names }
    foreach ($ht in @($Spec.hostTools)) {
        if (-not ($ht -is [hashtable]) -or -not $ht.ContainsKey('guestCommand')) { continue }
        $gc = [string]$ht.guestCommand
        if (-not $gc) { continue }
        if (Test-ToolIsHostAttachable -Name $gc) {
            if ($names -notcontains $gc) { $names += $gc }
        }
    }
    return ,$names
}

function Get-HostToolNoteTemplate {
    # Load the LF-normalized note template for a catalog tool. Returns the
    # content string, or $null if the template file is absent.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolName)
    $templateRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\host-tool-notes'
    $path = Join-Path $templateRoot "$ToolName.md"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = [string](Get-Content -LiteralPath $path -Raw)
    # LF-normalize — gotcha #14 (assign before -replace inside a method-arg list).
    $normalized = $raw -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    return $normalized
}

function ConvertTo-ManagedBlock {
    # Build the managed CLAUDE.md fragment (LF-normalized). Returns '' when
    # ToolNames is empty — caller treats '' as "no managed block desired" and
    # strips any existing block.
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][string[]]$ToolNames)
    $names = @($ToolNames | Where-Object { $_ } | Sort-Object -Unique)
    if ($names.Count -eq 0) { return '' }
    $lines = @()
    $lines += $Script:BlockBegin
    $lines += '## Host-attached CLI tools'
    $lines += ''
    $lines += 'The following CLIs run as Windows .exe through a WSL wrapper. argv passes'
    $lines += 'through unchanged, so file-path arguments are not translated. Translate'
    $lines += 'paths with `wslpath -w "$file"`, or use stdin when supported (e.g.'
    $lines += '`cat body.md | gh pr create -F -`). The cwd is auto-translated by WSL'
    $lines += 'interop, so commands that infer state from `pwd` work as-is.'
    $lines += ''
    $lines += 'Per-tool details:'
    foreach ($n in $names) {
        $lines += ('- {0} — see `~/.claude/host-tools/{0}.md`' -f $n)
    }
    $lines += $Script:BlockEnd
    return (($lines -join "`n") + "`n")
}

function Edit-ClaudeFileWithBlock {
    # Strip any existing managed block (including bordering blank lines) from
    # Content, then append the new Block. Pass Block='' to remove only. Returns
    # the new content (LF-normalized).
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Content,
        [Parameter()][AllowEmptyString()][string]$Block
    )
    $cur = if ($null -eq $Content) { '' } else { $Content }
    $cur = $cur -replace "`r`n", "`n"
    $cur = $cur -replace "`r", "`n"
    # Strip an existing managed block including bordering blank lines. Substitute
    # with '' (not "`n") so a file whose only content was the managed block
    # comes out as truly empty — not a lone newline that would reappear as
    # phantom drift on the next reconcile.
    $beginPat = [regex]::Escape($Script:BlockBegin)
    $endPat   = [regex]::Escape($Script:BlockEnd)
    $stripped = [regex]::Replace($cur, "(?ms)\n*$beginPat.*?$endPat\n*", '')
    # Normalize: if anything user-content-shaped remains, ensure exactly one
    # trailing newline. Whitespace-only -> truly empty.
    if (-not $stripped -or -not $stripped.Trim()) {
        $stripped = ''
    } else {
        $stripped = $stripped.TrimEnd("`n") + "`n"
    }
    if (-not $Block) { return $stripped }
    # Separate user content from the new block with one blank line for
    # readability, unless the file was empty.
    $sep = if ($stripped) { "`n" } else { '' }
    return ($stripped + $sep + $Block)
}

function Install-HostToolNotes {
    # Main entry. For each catalog tool host-attached, write
    # /home/claude/.claude/host-tools/<tool>.md from the bundled template.
    # Remove orphans (files for tools no longer attached). Update the managed
    # block in /home/claude/.claude/CLAUDE.md — skip if the file doesn't
    # exist (we don't create CLAUDE.md out of nowhere; claudeFile owns that).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()]$Spec,
        [string]$User = 'claude',
        [string]$Home = '/home/claude',
        [string]$Root,
        [string]$Owner,
        [string]$FileMode = '0644'
    )
    # -Root is the dir holding CLAUDE.md + host-tools/ (default <home>/.claude).
    # Under the shared-store model the caller passes the store path + a
    # root:claudeshared owner + a group-writable 0664 mode, so notes are written
    # once to the shared location every user symlinks to.
    $root  = if ($Root)  { $Root }  else { "$Home/.claude" }
    $owner = if ($Owner) { $Owner } else { "${User}:${User}" }
    # No @() wrap — Get-CatalogHostAttached uses `return ,$names`, so the
    # caller already receives the array. An extra @() would double-wrap into a
    # 1-element array containing the array, and `foreach ($name in $desired)`
    # would bind $name to the inner array (string-cast crash downstream).
    $desired = Get-CatalogHostAttached -Spec $Spec

    # 1) Sync per-tool .md files in <root>/host-tools/.
    #    Always reachable even if CLAUDE.md isn't managed by us — Claude can
    #    still find them on disk.
    $notesDir = "$root/host-tools"
    $qNotesDir = ConvertTo-BashQuoted $notesDir
    # Enumerate existing .md files in the notes dir (if any). Root so it can
    # read inside a 0700 per-project-user home.
    $r = Invoke-InDistro -Name $DistroName -User 'root' `
        -Command "ls -1 $qNotesDir 2>/dev/null | grep -E '\.md$' || true" -AllowFail -CaptureOutput
    $actual = @()
    if ($r.ExitCode -eq 0) {
        $actual = @($r.Output | Where-Object { $_ -is [string] -and $_.Trim() } |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -match '\.md$' })
    }
    $desiredFiles = @($desired | ForEach-Object { "$_.md" })

    # Add / refresh desired notes. Each write chowns ONLY the file it just
    # wrote (not -R over /home/claude/.claude — that would re-walk the whole
    # tree per tool and bog down reconcile / attach on a populated home).
    # mkdir -p is cheap on existing dirs and we mkdir + chown the notes dir
    # once below.
    $wroteAny = $false
    foreach ($name in $desired) {
        $content = Get-HostToolNoteTemplate -ToolName $name
        if ($null -eq $content) {
            Write-Host "  (no host-tool note template for '$name' — skipping)" -ForegroundColor DarkGray
            continue
        }
        $payload = $content
        $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $dest = "$notesDir/$name.md"
        $qDest = ConvertTo-BashQuoted $dest
        $cmd  = "set -e; mkdir -p $qNotesDir; printf '%s' '$b64' | base64 -d > $qDest; " +
                "chown $owner $qDest; chmod $FileMode $qDest"
        Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd | Out-Null
        $wroteAny = $true
    }

    # Remove orphan .md files (notes for tools no longer attached).
    foreach ($file in $actual) {
        if ($desiredFiles -notcontains $file) {
            $qDest = ConvertTo-BashQuoted "$notesDir/$file"
            Invoke-InDistro -Name $DistroName -User 'root' -Command "rm -f $qDest" -AllowFail | Out-Null
        }
    }

    # If we created notesDir for the first time via mkdir above, also ensure
    # its ownership is correct. Cheap one-shot (not recursive).
    if ($wroteAny) {
        Invoke-InDistro -Name $DistroName -User 'root' `
            -Command "chown $owner $qNotesDir 2>/dev/null || true" -AllowFail | Out-Null
    }

    # 2) Update the managed block in <root>/CLAUDE.md.
    #    Skip when CLAUDE.md is absent — we don't own the file, the shared store
    #    seed (claudeShared) does.
    $qClaudeMd = ConvertTo-BashQuoted "$root/CLAUDE.md"
    $checkR = Invoke-InDistro -Name $DistroName -User 'root' `
        -Command "test -f $qClaudeMd" -AllowFail -CaptureOutput
    if ($checkR.ExitCode -ne 0) { return }

    # Read current content (base64 transport so trailing newline survives).
    $readR = Invoke-InDistro -Name $DistroName -User 'root' `
        -Command "base64 -w0 $qClaudeMd; echo" -AllowFail -CaptureOutput
    if ($readR.ExitCode -ne 0) { return }
    $b64 = (@($readR.Output | ForEach-Object { [string]$_ }) -join '').Trim()
    $current = if ($b64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) } else { '' }

    $block = ConvertTo-ManagedBlock -ToolNames $desired
    $new   = Edit-ClaudeFileWithBlock -Content $current -Block $block

    if ($new -eq $current) { return }   # no drift

    $payload = $new
    $b64Out  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $cmd = "set -e; printf '%s' '$b64Out' | base64 -d > $qClaudeMd; " +
           "chown $owner $qClaudeMd; chmod $FileMode $qClaudeMd"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd | Out-Null
}

Export-ModuleMember -Function `
    Get-CatalogHostAttached, `
    Get-HostToolNoteTemplate, `
    ConvertTo-ManagedBlock, `
    Edit-ClaudeFileWithBlock, `
    Install-HostToolNotes
