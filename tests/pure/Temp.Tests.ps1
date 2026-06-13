# Temp.Tests.ps1 — pure tests for modules/Temp.psm1. The actual in-distro
# du / rm steps are covered under tests/distro/Temp.Tests.ps1; here we pin
# the parse shape, the per-scope wipe-set logic, and the script-text
# generation for Clear-Scratch.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Temp.psm1') -Force
}

Describe 'Get-ScratchSizes' {
    It 'parses tab-separated du output for each scope and computes a total' {
        # Mock the in-distro probe to deliver the script-generated table.
        Mock -ModuleName Temp Invoke-InDistroScript {
            @{ ExitCode = 0; Output = @(
                "/tmp`t10485760"
                "/home/claude/.cache`t52428800"
                "/home/claude/.claude`t1048576"
            )}
        }
        $r = Get-ScratchSizes -DistroName 'd'
        $r.tmp    | Should -Be 10485760    # 10 MB
        $r.cache  | Should -Be 52428800    # 50 MB
        $r.claude | Should -Be 1048576     # 1 MB
        $r.total  | Should -Be (10485760 + 52428800 + 1048576)
    }

    It 'returns zeros when the in-distro probe fails' {
        Mock -ModuleName Temp Invoke-InDistroScript { @{ ExitCode = 1; Output = @() } }
        $r = Get-ScratchSizes -DistroName 'd'
        $r.tmp    | Should -Be 0
        $r.cache  | Should -Be 0
        $r.claude | Should -Be 0
        $r.total  | Should -Be 0
    }
}

Describe 'Clear-Scratch (claude scope)' {
    # We capture the script body fed to Invoke-InDistroScript so we can pin
    # which subdirs land in the wipe set under each combination of flags.
    BeforeEach {
        $script:capturedScript = $null
        Mock -ModuleName Temp Invoke-InDistroScript {
            param($Name, $User, $Script, $AllowFail)
            $script:capturedScript = $Script
            return @{ ExitCode = 0; Output = @('done') }
        } -ParameterFilter { $true }
    }

    It 'wipes projects/ + shell-snapshots/ by default, preserves todos / plans / host-tools' {
        $r = Clear-Scratch -DistroName 'd' -Scope claude
        $script:capturedScript | Should -Match '/home/claude/\.claude/projects'
        $script:capturedScript | Should -Match '/home/claude/\.claude/shell-snapshots'
        $script:capturedScript | Should -Not -Match '/home/claude/\.claude/todos'
        $script:capturedScript | Should -Not -Match '/home/claude/\.claude/plans'
        $script:capturedScript | Should -Not -Match '/home/claude/\.claude/host-tools'
        $r.PreservedNote       | Should -Match 'todos'
        $r.PreservedNote       | Should -Match 'plans'
        $r.PreservedNote       | Should -Match 'host-tools'
    }

    It '-IncludeTodos extends the wipe set to ~/.claude/todos/' {
        $r = Clear-Scratch -DistroName 'd' -Scope claude -IncludeTodos
        $script:capturedScript | Should -Match '/home/claude/\.claude/todos'
        $r.PreservedNote       | Should -Not -Match 'todos'
        # plans + host-tools are still preserved.
        $r.PreservedNote       | Should -Match 'plans'
        $r.PreservedNote       | Should -Match 'host-tools'
    }

    It '-IncludePlans extends the wipe set to ~/.claude/plans/' {
        $r = Clear-Scratch -DistroName 'd' -Scope claude -IncludePlans
        $script:capturedScript | Should -Match '/home/claude/\.claude/plans'
        $r.PreservedNote       | Should -Not -Match 'plans'
        $r.PreservedNote       | Should -Match 'todos'
    }
}

Describe 'Confirm-ScratchWipe' {
    It 'is silent when the wipe ran (exit 0 + done marker)' {
        $warnings = Confirm-ScratchWipe -Result @{ ExitCode = 0; Output = @('done') } -Scope 'tmp' 3>&1
        $warnings | Should -BeNullOrEmpty
    }

    It 'warns when the in-distro call failed (non-zero exit)' {
        $warnings = Confirm-ScratchWipe -Result @{ ExitCode = 1; Output = @() } -Scope 'cache' 3>&1
        ($warnings -join "`n") | Should -Match 'may not have completed'
    }

    It 'warns when the done marker is absent (script died before finishing)' {
        $warnings = Confirm-ScratchWipe -Result @{ ExitCode = 0; Output = @('partial output') } -Scope 'claude' 3>&1
        ($warnings -join "`n") | Should -Match 'may not have completed'
    }

    It 'warns when there is no result at all' {
        $warnings = Confirm-ScratchWipe -Result $null -Scope 'tmp' 3>&1
        ($warnings -join "`n") | Should -Match 'may not have completed'
    }
}

Describe 'Clear-Scratch (tmp / cache scopes)' {
    BeforeEach {
        $script:capturedScript = $null
        Mock -ModuleName Temp Invoke-InDistroScript {
            param($Name, $User, $Script, $AllowFail)
            $script:capturedScript = $Script
            return @{ ExitCode = 0; Output = @('done') }
        } -ParameterFilter { $true }
    }

    It 'tmp wipe preserves the /tmp mountpoint (uses -mindepth 1)' {
        Clear-Scratch -DistroName 'd' -Scope tmp | Out-Null
        $script:capturedScript | Should -Match '-mindepth 1'
        $script:capturedScript | Should -Match '/tmp'
    }

    It 'cache wipe targets ~/.cache contents (mindepth 1)' {
        Clear-Scratch -DistroName 'd' -Scope cache | Out-Null
        $script:capturedScript | Should -Match '-mindepth 1'
        $script:capturedScript | Should -Match '/home/claude/\.cache'
    }
}
