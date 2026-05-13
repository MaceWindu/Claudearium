# Tools.Tests.ps1 — pure tests for the catalog metadata + Windows-host PATH
# probe. Real install scriptblocks need a distro and live in tests/distro.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Tools.psm1') -Force
}

Describe 'Tool catalog HostExeNames metadata' {
    It 'flags exactly the OAuth-pain tools as host-attachable (gh, glab, acli, seqcli)' {
        $hostAttachable = @()
        foreach ($name in Get-ToolCatalog) {
            $h = Get-ToolHandler -Name $name
            if ($h.ContainsKey('HostExeNames') -and $h.HostExeNames) {
                $hostAttachable += $name
            }
        }
        ($hostAttachable | Sort-Object) | Should -Be (@('acli', 'gh', 'glab', 'seqcli') | Sort-Object)
    }

    It "does not mark non-OAuth tools (node, dotnet, pwsh, claudeCode) as host-attachable" {
        foreach ($name in @('node', 'dotnet', 'pwsh', 'claudeCode')) {
            $h = Get-ToolHandler -Name $name
            $h.ContainsKey('HostExeNames') | Should -BeFalse -Because "host-attach for '$name' has no auth-pain rationale and invites version drift"
        }
    }
}

Describe 'Test-ToolHostAvailable' {
    It 'returns Available=$false for tools without HostExeNames' {
        $r = Test-ToolHostAvailable -Name 'node'
        $r.Available | Should -BeFalse
        $r.ExePath   | Should -Be ''
    }

    It 'returns Available=$false for an unknown tool name' {
        $r = Test-ToolHostAvailable -Name 'not-a-real-tool-xyz'
        $r.Available | Should -BeFalse
    }

    It 'returns Available=$true with the resolved ExePath when Get-Command finds the host exe' {
        # Mock Get-Command inside the Tools module so the helper sees a hit.
        Mock -ModuleName Tools Get-Command {
            param($Name)
            if ($Name -eq 'gh.exe') {
                return [PSCustomObject]@{ Source = 'C:\Program Files\GitHub CLI\gh.exe' }
            }
            return $null
        }
        $r = Test-ToolHostAvailable -Name 'gh'
        $r.Available | Should -BeTrue
        $r.ExePath   | Should -Be 'C:\Program Files\GitHub CLI\gh.exe'
    }

    It 'returns Available=$false when none of the HostExeNames resolve' {
        Mock -ModuleName Tools Get-Command { return $null }
        $r = Test-ToolHostAvailable -Name 'gh'
        $r.Available | Should -BeFalse
        $r.ExePath   | Should -Be ''
    }
}
