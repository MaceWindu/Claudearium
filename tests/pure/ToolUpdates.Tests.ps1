# ToolUpdates.Tests.ps1 — pure tests for the latest-version cache and helpers.
# Cache I/O goes through temp paths so the real %LOCALAPPDATA% cache is never
# touched. Compare-ToolVersion / Get-ToolVersionCore live in Tools.psm1 but
# are exercised here too since they're load-bearing for the Latest column.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Tools.psm1')       -Force
    Import-Module (Join-Path $repoRoot 'modules\ToolUpdates.psm1') -Force
}

Describe 'Get-ToolVersionCore' {
    It "extracts X.Y.Z from a 'v22.5.1' style string" {
        Get-ToolVersionCore -Raw 'v22.5.1' | Should -Be '22.5.1'
    }
    It "extracts the version from 'gh version 2.55.0 (2024-XX-XX)'" {
        Get-ToolVersionCore -Raw 'gh version 2.55.0 (2024-01-01)' | Should -Be '2.55.0'
    }
    It "extracts from 'PowerShell 7.4.5'" {
        Get-ToolVersionCore -Raw 'PowerShell 7.4.5' | Should -Be '7.4.5'
    }
    It "extracts from '1.0.42 (Claude Code)'" {
        Get-ToolVersionCore -Raw '1.0.42 (Claude Code)' | Should -Be '1.0.42'
    }
    It 'returns $null for null / empty / whitespace' {
        Get-ToolVersionCore -Raw $null   | Should -BeNullOrEmpty
        Get-ToolVersionCore -Raw ''      | Should -BeNullOrEmpty
        Get-ToolVersionCore -Raw '   '   | Should -BeNullOrEmpty
    }
    It 'returns $null for a string with no version-shaped substring' {
        Get-ToolVersionCore -Raw 'no version here' | Should -BeNullOrEmpty
    }
    It 'extracts the first version-shaped substring when multiples are present' {
        Get-ToolVersionCore -Raw 'foo 1.2.3 then 4.5.6' | Should -Be '1.2.3'
    }
}

Describe 'Compare-ToolVersion' {
    It "returns 'unknown' when either side is null/empty" {
        Compare-ToolVersion -Installed $null  -Latest '1.0.0' | Should -Be 'unknown'
        Compare-ToolVersion -Installed '1.0.0' -Latest $null  | Should -Be 'unknown'
        Compare-ToolVersion -Installed ''     -Latest ''      | Should -Be 'unknown'
    }
    It "returns 'unknown' when no version core can be extracted" {
        Compare-ToolVersion -Installed 'unknown' -Latest 'unknown' | Should -Be 'unknown'
    }
    It "returns 'same' when extracted cores are byte-equal" {
        Compare-ToolVersion -Installed 'v22.5.1' -Latest '22.5.1'           | Should -Be 'same'
        Compare-ToolVersion -Installed 'gh version 2.55.0' -Latest 'v2.55.0' | Should -Be 'same'
    }
    It "returns 'update-available' when installed < latest under [version]" {
        Compare-ToolVersion -Installed '1.0.0' -Latest '1.0.1' | Should -Be 'update-available'
        Compare-ToolVersion -Installed 'v22.5.0' -Latest 'v22.5.1' | Should -Be 'update-available'
    }
    It "returns 'same' when installed >= latest (e.g. user manually installed a newer build)" {
        Compare-ToolVersion -Installed '2.0.0' -Latest '1.9.9' | Should -Be 'same'
    }
    It "returns 'update-available' when cores differ but neither parses as [version]" {
        # [version] only accepts 2-4 parts; a 5-segment string like 1.2.3.4.5
        # matches the regex (so a core is extracted) but fails the [version]
        # cast, exercising the catch-block fallback that compares strings.
        Compare-ToolVersion -Installed '1.2.3.4.5' -Latest '1.2.3.4.6' | Should -Be 'update-available'
    }
    It "drops pre-release suffixes when extracting cores (1.0.0-alpha == 1.0.0-beta as 'same')" {
        # Documenting current behavior: pre-release tags don't influence the
        # comparison. False negatives are acceptable for a status hint.
        Compare-ToolVersion -Installed '1.0.0-alpha' -Latest '1.0.0-beta' | Should -Be 'same'
    }
}

Describe 'Tool catalog: every entry declares a GetLatestVersion probe' {
    It 'has GetLatestVersion on each of the 8 catalog tools' {
        foreach ($name in Get-ToolCatalog) {
            $h = Get-ToolHandler -Name $name
            $h.ContainsKey('GetLatestVersion') | Should -BeTrue -Because "tool '$name' must declare a GetLatestVersion scriptblock"
            $h.GetLatestVersion | Should -BeOfType ([scriptblock])
        }
    }
}

Describe 'Cache read/write round-trip' {
    BeforeEach {
        $script:cachePath = Join-Path ([IO.Path]::GetTempPath()) ("claudearium-tu-test-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:cachePath) { Remove-Item -LiteralPath $script:cachePath -Force -ErrorAction SilentlyContinue }
    }
    It 'returns $null when the cache file does not exist' {
        Read-ToolUpdatesCache -Path $script:cachePath | Should -BeNullOrEmpty
    }
    It 'round-trips a cache hashtable through write -> read' {
        $cache = @{
            checkedAt = ([datetime]::UtcNow).ToString('o')
            tools     = @{
                node = @{ latest = 'v22.5.1'; error = $null }
                gh   = @{ latest = $null;     error = 'probe failed: 404' }
            }
        }
        Write-ToolUpdatesCache -Cache $cache -Path $script:cachePath
        $loaded = Read-ToolUpdatesCache -Path $script:cachePath
        $loaded | Should -Not -BeNullOrEmpty
        $loaded.tools.node.latest | Should -Be 'v22.5.1'
        $loaded.tools.gh.error    | Should -Be 'probe failed: 404'
    }
    It 'returns $null on unparseable cache contents (and does not throw)' {
        [System.IO.File]::WriteAllText($script:cachePath, '{ not valid json', (New-Object System.Text.UTF8Encoding $false))
        Read-ToolUpdatesCache -Path $script:cachePath | Should -BeNullOrEmpty
    }
}

Describe 'Test-ToolUpdatesCacheStale' {
    BeforeEach {
        $script:cachePath = Join-Path ([IO.Path]::GetTempPath()) ("claudearium-tu-stale-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:cachePath) { Remove-Item -LiteralPath $script:cachePath -Force -ErrorAction SilentlyContinue }
    }
    It 'is stale when the cache file is missing' {
        Test-ToolUpdatesCacheStale -Path $script:cachePath | Should -BeTrue
    }
    It 'is stale when checkedAt is older than the TTL' {
        $cache = @{ checkedAt = ([datetime]::UtcNow.AddHours(-12)).ToString('o'); tools = @{} }
        Write-ToolUpdatesCache -Cache $cache -Path $script:cachePath
        Test-ToolUpdatesCacheStale -TtlHours 6 -Path $script:cachePath | Should -BeTrue
    }
    It 'is fresh when checkedAt is within the TTL' {
        $cache = @{ checkedAt = ([datetime]::UtcNow.AddMinutes(-30)).ToString('o'); tools = @{} }
        Write-ToolUpdatesCache -Cache $cache -Path $script:cachePath
        Test-ToolUpdatesCacheStale -TtlHours 6 -Path $script:cachePath | Should -BeFalse
    }
    It 'is stale when the checkedAt field is malformed' {
        $cache = @{ checkedAt = 'not a date'; tools = @{} }
        Write-ToolUpdatesCache -Cache $cache -Path $script:cachePath
        Test-ToolUpdatesCacheStale -Path $script:cachePath | Should -BeTrue
    }
}

Describe 'Lock-file dogpile suppression' {
    BeforeEach {
        $script:lockPath = Join-Path ([IO.Path]::GetTempPath()) ("claudearium-tu-lock-{0}.lock" -f ([Guid]::NewGuid().ToString('N')))
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:lockPath) { Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue }
    }
    It 'reports inactive when no lock file exists' {
        Test-RefreshLockActive -Path $script:lockPath | Should -BeFalse
    }
    It 'reports active for a fresh lock' {
        New-RefreshLock -Path $script:lockPath
        Test-RefreshLockActive -Path $script:lockPath | Should -BeTrue
    }
    It 'reports inactive for a stale lock (treated as a dead refresh holder)' {
        $old = [datetime]::UtcNow.AddHours(-1).ToString('o')
        [System.IO.File]::WriteAllText($script:lockPath, $old, (New-Object System.Text.UTF8Encoding $false))
        Test-RefreshLockActive -Path $script:lockPath | Should -BeFalse
    }
    It 'Remove-RefreshLock deletes an existing lock' {
        New-RefreshLock -Path $script:lockPath
        Remove-RefreshLock -Path $script:lockPath
        Test-Path -LiteralPath $script:lockPath | Should -BeFalse
    }
}

Describe 'Get-ToolUpdateCount' {
    It 'returns 0 for null / empty rows' {
        Get-ToolUpdateCount -Rows $null | Should -Be 0
        Get-ToolUpdateCount -Rows @()   | Should -Be 0
    }
    It "counts only rows where Compare-ToolVersion is 'update-available'" {
        $rows = @(
            [PSCustomObject]@{ Name='a'; Installed='1.0.0'; Latest='1.0.1' }   # update-available
            [PSCustomObject]@{ Name='b'; Installed='2.0.0'; Latest='2.0.0' }   # same
            [PSCustomObject]@{ Name='c'; Installed=$null;  Latest='3.0.0' }    # unknown
            [PSCustomObject]@{ Name='d'; Installed='4.0.0'; Latest=$null }     # unknown
            [PSCustomObject]@{ Name='e'; Installed='5.0.0'; Latest='5.0.2' }   # update-available
        )
        Get-ToolUpdateCount -Rows $rows | Should -Be 2
    }
    It 'accepts hashtable rows as well as PSCustomObject' {
        $rows = @(
            @{ Name='x'; Installed='v22.5.0'; Latest='v22.5.1' }
            @{ Name='y'; Installed='v22.5.1'; Latest='v22.5.1' }
        )
        Get-ToolUpdateCount -Rows $rows | Should -Be 1
    }
}
