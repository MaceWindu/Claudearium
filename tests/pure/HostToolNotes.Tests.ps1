# HostToolNotes.Tests.ps1 — pure tests for the in-CLAUDE.md managed-block
# manipulation + the catalog-host-attached filter. The distro-side write +
# read paths live in tests/distro/HostToolNotes.Tests.ps1.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Tools.psm1')         -Force
    Import-Module (Join-Path $repoRoot 'modules\HostToolNotes.psm1') -Force
}

Describe 'Get-CatalogHostAttached' {
    It 'returns the catalog tool names that are host-attached drop-in' {
        $spec = @{
            hostTools = @(
                @{ name = 'gh';      windowsExe = 'C:\bin\gh.exe';   guestCommand = 'gh' }
                @{ name = 'glab';    windowsExe = 'C:\bin\glab.exe'; guestCommand = 'glab' }
            )
        }
        $r = Get-CatalogHostAttached -Spec $spec
        $r.Count | Should -Be 2
        ($r | Sort-Object) -join ',' | Should -Be 'gh,glab'
    }

    It 'ignores sb-prefixed entries (custom wrappers without a catalog template)' {
        $spec = @{
            hostTools = @(
                @{ name = 'claudelk'; windowsExe = 'C:\bin\claudelk.exe'; guestCommand = 'sb-claudelk' }
                @{ name = 'gh';       windowsExe = 'C:\bin\gh.exe';       guestCommand = 'gh' }
            )
        }
        $r = Get-CatalogHostAttached -Spec $spec
        $r.Count | Should -Be 1
        $r[0]    | Should -Be 'gh'
    }

    It 'ignores hostTools entries whose guestCommand is not a catalog tool name' {
        $spec = @{
            hostTools = @(
                @{ name = 'myutil'; windowsExe = 'C:\bin\myutil.exe'; guestCommand = 'myutil' }
            )
        }
        $r = Get-CatalogHostAttached -Spec $spec
        $r.Count | Should -Be 0
    }

    It 'returns an empty array (not $null) when the spec has no hostTools' {
        $r = Get-CatalogHostAttached -Spec @{ schemaVersion = 1 }
        $null -eq $r | Should -BeFalse
        $r.Count     | Should -Be 0
    }

    It 'returns an empty array when spec is $null' {
        $r = Get-CatalogHostAttached -Spec $null
        $null -eq $r | Should -BeFalse
        $r.Count     | Should -Be 0
    }
}

Describe 'ConvertTo-ManagedBlock' {
    It "returns '' when ToolNames is empty (caller will strip any existing block)" {
        ConvertTo-ManagedBlock -ToolNames @() | Should -Be ''
    }

    It 'wraps the block in the begin / end markers' {
        $b = ConvertTo-ManagedBlock -ToolNames @('gh')
        $b | Should -Match '<!-- claudearium-host-tools-begin -->'
        $b | Should -Match '<!-- claudearium-host-tools-end -->'
    }

    It 'sorts tool names and includes the hybrid one-line caveat plus per-tool references' {
        $b = ConvertTo-ManagedBlock -ToolNames @('glab', 'gh')
        # Sorted alphabetically:
        $ghIdx   = $b.IndexOf('host-tools/gh.md')
        $glabIdx = $b.IndexOf('host-tools/glab.md')
        $ghIdx   | Should -BeGreaterThan -1
        $glabIdx | Should -BeGreaterThan $ghIdx
        # One-line caveat present:
        $b | Should -Match 'wslpath -w'
        $b | Should -Match 'stdin'
        # cwd reminder so Claude doesn't translate paths that don't need it:
        $b | Should -Match '(?i)cwd|pwd'
    }

    It 'dedupes the ToolNames list' {
        $b = ConvertTo-ManagedBlock -ToolNames @('gh', 'gh', 'gh')
        $count = ([regex]::Matches($b, '`~/.claude/host-tools/gh.md`')).Count
        $count | Should -Be 1
    }
}

Describe 'Edit-ClaudeFileWithBlock' {
    It 'appends the block to a file with no managed block (preserves user content)' {
        $original = "be brief.`n"
        $block    = ConvertTo-ManagedBlock -ToolNames @('gh')
        $new      = Edit-ClaudeFileWithBlock -Content $original -Block $block
        $new      | Should -Match '(?ms)^be brief\.$'
        $new      | Should -Match '<!-- claudearium-host-tools-begin -->'
        $new      | Should -Match '<!-- claudearium-host-tools-end -->'
    }

    It 'replaces an existing managed block in place (idempotent re-apply)' {
        $block1 = ConvertTo-ManagedBlock -ToolNames @('gh')
        $with1  = Edit-ClaudeFileWithBlock -Content "user content`n" -Block $block1
        $block2 = ConvertTo-ManagedBlock -ToolNames @('gh', 'glab')
        $with2  = Edit-ClaudeFileWithBlock -Content $with1 -Block $block2
        # User content still there:
        $with2 | Should -Match '(?ms)^user content$'
        # Exactly one begin / one end marker:
        ([regex]::Matches($with2, '<!-- claudearium-host-tools-begin -->')).Count | Should -Be 1
        ([regex]::Matches($with2, '<!-- claudearium-host-tools-end -->')).Count   | Should -Be 1
        # New tool present, old single-tool listing replaced:
        $with2 | Should -Match 'host-tools/gh.md'
        $with2 | Should -Match 'host-tools/glab.md'
    }

    It "strips the managed block entirely when Block is '' (no-tools-attached case)" {
        $block  = ConvertTo-ManagedBlock -ToolNames @('gh')
        $with   = Edit-ClaudeFileWithBlock -Content "be brief.`n" -Block $block
        $without = Edit-ClaudeFileWithBlock -Content $with -Block ''
        $without | Should -Not -Match 'claudearium-host-tools-begin'
        $without | Should -Match '(?ms)^be brief\.$'
    }

    It "returns truly empty (not '`n') when the file contained ONLY the managed block and Block is ''" {
        # Regression: substituting the matched block with "`n" left a lone
        # newline behind, which then re-appeared as phantom drift on the
        # next reconcile (and recreated CLAUDE.md as a 1-newline file after
        # detach). Now we replace with '' and normalize whitespace-only to ''.
        $only = ConvertTo-ManagedBlock -ToolNames @('gh')
        $r    = Edit-ClaudeFileWithBlock -Content $only -Block ''
        $r    | Should -Be ''
    }

    It 'collapses a whitespace-only file (only newlines around a stripped block) to empty' {
        $block = ConvertTo-ManagedBlock -ToolNames @('gh')
        $surrounded = "`n`n" + $block + "`n`n"
        $r    = Edit-ClaudeFileWithBlock -Content $surrounded -Block ''
        $r    | Should -Be ''
    }

    It 'leaves a file with no managed block unchanged when Block is empty' {
        $original = "be brief.`n"
        $result   = Edit-ClaudeFileWithBlock -Content $original -Block ''
        $result   | Should -Match '(?ms)^be brief\.$'
        $result   | Should -Not -Match 'claudearium-host-tools'
    }

    It 'handles $null Content (empty file equivalent)' {
        $block = ConvertTo-ManagedBlock -ToolNames @('gh')
        $r     = Edit-ClaudeFileWithBlock -Content $null -Block $block
        $r     | Should -Match '<!-- claudearium-host-tools-begin -->'
    }

    It 'normalizes CRLF to LF in the resulting content' {
        $crlfInput = "line1`r`nline2`r`n"
        $block     = ConvertTo-ManagedBlock -ToolNames @('gh')
        $r         = Edit-ClaudeFileWithBlock -Content $crlfInput -Block $block
        $r         | Should -Not -Match "`r"
    }
}

Describe 'Get-HostToolNoteTemplate' {
    It 'loads gh.md template (shipped) and includes the wslpath -w reminder' {
        $c = Get-HostToolNoteTemplate -ToolName 'gh'
        $null -eq $c | Should -BeFalse
        $c | Should -Match 'wslpath -w'
    }

    It 'returns $null for an unknown tool' {
        Get-HostToolNoteTemplate -ToolName 'not-a-real-tool' | Should -BeNullOrEmpty
    }

    It "normalizes line endings to LF" {
        $c = Get-HostToolNoteTemplate -ToolName 'gh'
        $c | Should -Not -Match "`r"
    }

    It 'has a shipped template for every catalog tool that opts in to host-attach (HostExeNames)' {
        # Keeps templates/host-tool-notes/ in lockstep with the catalog: if a
        # future tool gets HostExeNames added in Tools.psm1 without a matching
        # template, this test fails — Install-HostToolNotes would silently
        # write nothing for it otherwise.
        $missing = @()
        foreach ($name in Get-ToolCatalog) {
            if (Test-ToolIsHostAttachable -Name $name) {
                if ($null -eq (Get-HostToolNoteTemplate -ToolName $name)) {
                    $missing += $name
                }
            }
        }
        $missing | Should -BeNullOrEmpty -Because 'every host-attachable catalog tool needs a templates/host-tool-notes/<name>.md'
    }
}
