# SelfUpdate.Tests.ps1 — pure tests for modules/SelfUpdate.psm1.
# Covers the file-system, parsing, and pure-helper functions. The network-
# touching Get-LatestReleaseInfo path is exercised via Mock Invoke-RestMethod
# (so no real GitHub calls happen in CI). The verb handler (Invoke-Update) is
# integration territory and not exercised here.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\SelfUpdate.psm1') -Force
}

Describe 'Get-LocalVersion' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "su-test-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    }
    AfterEach {
        if ($script:tmp -and (Test-Path -LiteralPath $script:tmp)) {
            Remove-Item -LiteralPath $script:tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns a [version] for a well-formed YYYY.M.N file' {
        Set-Content -LiteralPath $script:tmp -Value '2026.5.1' -NoNewline
        $v = Get-LocalVersion -Path $script:tmp
        $v | Should -BeOfType ([version])
        $v.Major | Should -Be 2026
        $v.Minor | Should -Be 5
        $v.Build | Should -Be 1
    }

    It "returns 'dev' for a missing file" {
        # $script:tmp doesn't exist yet.
        Get-LocalVersion -Path $script:tmp | Should -Be 'dev'
    }

    It "returns 'dev' for an empty file" {
        Set-Content -LiteralPath $script:tmp -Value '' -NoNewline
        Get-LocalVersion -Path $script:tmp | Should -Be 'dev'
    }

    It "returns 'dev' for whitespace" {
        Set-Content -LiteralPath $script:tmp -Value "  `t`n  " -NoNewline
        Get-LocalVersion -Path $script:tmp | Should -Be 'dev'
    }

    It "returns 'dev' for the literal token 'dev'" {
        Set-Content -LiteralPath $script:tmp -Value 'dev' -NoNewline
        Get-LocalVersion -Path $script:tmp | Should -Be 'dev'
    }

    It 'returns $null for a malformed version string' {
        Set-Content -LiteralPath $script:tmp -Value 'banana' -NoNewline
        Get-LocalVersion -Path $script:tmp | Should -BeNullOrEmpty
    }

    It 'tolerates surrounding whitespace around a valid version' {
        Set-Content -LiteralPath $script:tmp -Value "  2026.12.42  " -NoNewline
        $v = Get-LocalVersion -Path $script:tmp
        $v | Should -BeOfType ([version])
        $v.Major | Should -Be 2026
        $v.Minor | Should -Be 12
        $v.Build | Should -Be 42
    }
}

Describe 'Test-IsOurRepo' {
    It 'accepts the canonical https url' {
        Test-IsOurRepo -Url 'https://github.com/MaceWindu/Claudearium' | Should -BeTrue
    }
    It 'accepts the https url with .git suffix' {
        Test-IsOurRepo -Url 'https://github.com/MaceWindu/Claudearium.git' | Should -BeTrue
    }
    It 'accepts the ssh form' {
        Test-IsOurRepo -Url 'git@github.com:MaceWindu/Claudearium.git' | Should -BeTrue
    }
    It 'accepts a trailing slash' {
        Test-IsOurRepo -Url 'https://github.com/MaceWindu/Claudearium/' | Should -BeTrue
    }
    It 'is case-insensitive on the owner/repo segment' {
        Test-IsOurRepo -Url 'https://GITHUB.com/MACEWINDU/CLAUDEARIUM.git' | Should -BeTrue
    }
    It 'rejects a fork under a different owner' {
        Test-IsOurRepo -Url 'https://github.com/SomeFork/Claudearium.git' | Should -BeFalse
    }
    It 'rejects a different repo under the same owner' {
        Test-IsOurRepo -Url 'https://github.com/MaceWindu/Other.git' | Should -BeFalse
    }
    It 'rejects an empty url' {
        Test-IsOurRepo -Url '' | Should -BeFalse
    }
    It 'rejects $null' {
        Test-IsOurRepo -Url $null | Should -BeFalse
    }
}

Describe 'Get-UpdateCheckState / Set-UpdateCheckState (round-trip)' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "su-state-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    }
    AfterEach {
        if ($script:tmp -and (Test-Path -LiteralPath $script:tmp)) {
            Remove-Item -LiteralPath $script:tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns defaults when the file is absent' {
        $s = Get-UpdateCheckState -Path $script:tmp
        $s.lastCheckedAt     | Should -BeNullOrEmpty
        $s.latestSeenVersion | Should -BeNullOrEmpty
    }

    It 'round-trips lastCheckedAt and latestSeenVersion through Set/Get' {
        $iso = [datetime]::UtcNow.ToString('o')
        Set-UpdateCheckState -State @{ lastCheckedAt = $iso; latestSeenVersion = '2026.5.7' } -Path $script:tmp
        $s = Get-UpdateCheckState -Path $script:tmp
        $s.lastCheckedAt     | Should -Be $iso
        $s.latestSeenVersion | Should -Be '2026.5.7'
    }

    It 'falls back to defaults when the JSON is corrupt' {
        Set-Content -LiteralPath $script:tmp -Value '{ not valid json' -NoNewline
        $s = Get-UpdateCheckState -Path $script:tmp
        $s.lastCheckedAt     | Should -BeNullOrEmpty
        $s.latestSeenVersion | Should -BeNullOrEmpty
    }
    It 'preserves $null for latestSeenVersion when the JSON value is null' {
        # Regression: casting [string]$null yields '', which silently breaks
        # the "?? '(never)'" fallback in `update status`.
        Set-Content -LiteralPath $script:tmp -Value '{"lastCheckedAt":null,"latestSeenVersion":null}' -NoNewline
        $s = Get-UpdateCheckState -Path $script:tmp
        $s.latestSeenVersion | Should -BeNullOrEmpty
        $null -eq $s.latestSeenVersion | Should -BeTrue
    }
}

Describe 'Test-ShouldCheckForUpdates' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "su-state-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    }
    AfterEach {
        if ($script:tmp -and (Test-Path -LiteralPath $script:tmp)) {
            Remove-Item -LiteralPath $script:tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns true when no state file exists' {
        # Outside a git checkout — but the test runner itself runs from a git
        # checkout, so we have to skip the in-checkout exit. The function reads
        # Test-IsGitCheckout from the install root (one level above the module
        # dir), so under tests this is the repo, which IS a git checkout.
        # We work around by mocking Test-IsGitCheckout for this Describe.
        Mock Test-IsGitCheckout { $false } -ModuleName SelfUpdate
        Test-ShouldCheckForUpdates -Path $script:tmp | Should -BeTrue
    }

    It 'returns false when last check was less than 7 days ago' {
        Mock Test-IsGitCheckout { $false } -ModuleName SelfUpdate
        $now  = [datetime]'2026-05-13T00:00:00Z'
        $last = $now.AddDays(-6).ToString('o')
        Set-UpdateCheckState -State @{ lastCheckedAt = $last; latestSeenVersion = $null } -Path $script:tmp
        Test-ShouldCheckForUpdates -Now $now -Path $script:tmp | Should -BeFalse
    }

    It 'returns true when last check was 8 days ago' {
        Mock Test-IsGitCheckout { $false } -ModuleName SelfUpdate
        $now  = [datetime]'2026-05-13T00:00:00Z'
        $last = $now.AddDays(-8).ToString('o')
        Set-UpdateCheckState -State @{ lastCheckedAt = $last; latestSeenVersion = $null } -Path $script:tmp
        Test-ShouldCheckForUpdates -Now $now -Path $script:tmp | Should -BeTrue
    }

    It 'returns false when running from a git checkout (no network probe needed)' {
        Mock Test-IsGitCheckout { $true } -ModuleName SelfUpdate
        Test-ShouldCheckForUpdates -Path $script:tmp | Should -BeFalse
    }
}

Describe 'Get-LatestReleaseInfo (mocked)' {
    It 'returns Version + DownloadUrl + Notes on a well-formed response' {
        Mock Invoke-RestMethod -ModuleName SelfUpdate {
            return [pscustomobject]@{
                tag_name = 'v2026.5.7'
                body     = 'release notes here'
                assets   = @(
                    [pscustomobject]@{
                        name                 = 'claudearium-v2026.5.7.zip'
                        browser_download_url = 'https://example/claudearium-v2026.5.7.zip'
                    }
                )
            }
        }
        $info = Get-LatestReleaseInfo
        $info                | Should -Not -BeNullOrEmpty
        $info.Version        | Should -Be ([version]'2026.5.7')
        $info.Tag            | Should -Be 'v2026.5.7'
        $info.DownloadUrl    | Should -Be 'https://example/claudearium-v2026.5.7.zip'
        $info.Notes          | Should -Be 'release notes here'
    }

    It 'returns $null when Invoke-RestMethod throws' {
        Mock Invoke-RestMethod -ModuleName SelfUpdate { throw 'network down' }
        Get-LatestReleaseInfo | Should -BeNullOrEmpty
    }

    It 'returns $null when the tag does not match vYYYY.M.N' {
        Mock Invoke-RestMethod -ModuleName SelfUpdate {
            return [pscustomobject]@{
                tag_name = 'release-2026-may'
                body     = ''
                assets   = @()
            }
        }
        Get-LatestReleaseInfo | Should -BeNullOrEmpty
    }

    It 'returns $null when no claudearium-v*.zip asset is present' {
        Mock Invoke-RestMethod -ModuleName SelfUpdate {
            return [pscustomobject]@{
                tag_name = 'v2026.5.7'
                body     = ''
                assets   = @(
                    [pscustomobject]@{
                        name                 = 'source-code.zip'
                        browser_download_url = 'https://example/source.zip'
                    }
                )
            }
        }
        Get-LatestReleaseInfo | Should -BeNullOrEmpty
    }
}

Describe 'Test-SafeManifestPath' {
    It 'accepts a normal relative path with forward slashes' {
        Test-SafeManifestPath -Path 'modules/SelfUpdate.psm1' | Should -BeTrue
    }
    It 'accepts a top-level file' {
        Test-SafeManifestPath -Path 'VERSION' | Should -BeTrue
    }
    It 'rejects empty input' {
        Test-SafeManifestPath -Path '' | Should -BeFalse
    }
    It 'rejects whitespace-only input' {
        Test-SafeManifestPath -Path '   '   | Should -BeFalse
        Test-SafeManifestPath -Path "`t`n " | Should -BeFalse
    }
    It 'rejects a Windows drive prefix' {
        Test-SafeManifestPath -Path 'C:\Users\victim\file.txt' | Should -BeFalse
        Test-SafeManifestPath -Path 'c:foo'                    | Should -BeFalse
    }
    It 'rejects a leading slash (POSIX-absolute)' {
        Test-SafeManifestPath -Path '/etc/passwd' | Should -BeFalse
    }
    It 'rejects a leading backslash' {
        Test-SafeManifestPath -Path '\Windows\System32\bad.dll' | Should -BeFalse
    }
    It 'rejects a parent-traversal segment' {
        Test-SafeManifestPath -Path '../outside'           | Should -BeFalse
        Test-SafeManifestPath -Path 'modules/../../outside'| Should -BeFalse
    }
    It 'rejects a current-dir segment' {
        Test-SafeManifestPath -Path './sneaky' | Should -BeFalse
    }
    It 'rejects an empty segment (double slash)' {
        Test-SafeManifestPath -Path 'modules//file' | Should -BeFalse
    }
}

Describe 'Read-ManifestFile' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) "su-manifest-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    }
    AfterEach {
        if ($script:tmp -and (Test-Path -LiteralPath $script:tmp)) {
            Remove-Item -LiteralPath $script:tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns sorted entries from a well-formed manifest' {
        # Read-ManifestFile uses `return ,$result` to preserve array shape; the
        # function emits one pipeline item (the array). Compare via .Count and
        # -join, NOT via `Func | Should -Be @(...)` (Should sees one Actual,
        # not N piped items, and array-to-array equality fails).
        @('modules/B.psm1', 'A.txt', 'modules/A.psm1') | Set-Content -LiteralPath $script:tmp
        $r = Read-ManifestFile -Path $script:tmp
        $r.Count       | Should -Be 3
        ($r -join ',') | Should -Be 'A.txt,modules/A.psm1,modules/B.psm1'
    }
    It 'ignores blank lines' {
        @('foo', '', '   ', 'bar') | Set-Content -LiteralPath $script:tmp
        $r = Read-ManifestFile -Path $script:tmp
        $r.Count       | Should -Be 2
        ($r -join ',') | Should -Be 'bar,foo'
    }
    It 'throws on an unsafe entry (traversal)' {
        @('modules/ok.psm1', '../escape.txt') | Set-Content -LiteralPath $script:tmp
        { Read-ManifestFile -Path $script:tmp } | Should -Throw -ExpectedMessage '*Unsafe manifest entry*'
    }
    It 'throws on an unsafe entry (drive prefix)' {
        @('C:\Users\victim\file') | Set-Content -LiteralPath $script:tmp
        { Read-ManifestFile -Path $script:tmp } | Should -Throw -ExpectedMessage '*Unsafe manifest entry*'
    }
    It 'throws when the file is missing' {
        { Read-ManifestFile -Path 'X:\\never-exists\\manifest.txt' } | Should -Throw -ExpectedMessage '*Manifest file missing*'
    }
}

Describe 'Get-ManifestRemovals' {
    # The function uses `return ,$result` to preserve array shape across the
    # function boundary — without that, an empty pipeline result is collected
    # as $null by the caller and `$null.Count` throws under StrictMode
    # (the v2026.5.2 → v2026.5.3 `update apply` failure). Tests below assert
    # the returned shape directly; don't add an outer @() wrap (it would
    # then double-wrap into a 1-element array containing the result).

    It 'returns paths in Old that are absent from New' {
        $r = Get-ManifestRemovals -Old @('a','b','c','d') -New @('a','c')
        $r.Count | Should -Be 2
        ($r -join ',') | Should -Be 'b,d'
    }

    It 'returns an empty array (not $null) when New is a superset' {
        $r = Get-ManifestRemovals -Old @('a','b') -New @('a','b','c')
        $null -eq $r | Should -BeFalse
        $r.Count     | Should -Be 0
    }

    It 'returns Old verbatim when New is empty' {
        $r = Get-ManifestRemovals -Old @('a','b') -New @()
        $r.Count       | Should -Be 2
        ($r -join ',') | Should -Be 'a,b'
    }

    It 'returns empty (not $null) when both inputs are empty' {
        # Regression for the update failure: this is the path Invoke-Update
        # hits on a no-removals upgrade (the common case for a small bump).
        $r = Get-ManifestRemovals -Old @() -New @()
        $null -eq $r | Should -BeFalse -Because 'function must return [], not $null, so the caller''s $r.Count cannot throw under StrictMode'
        $r.Count     | Should -Be 0
    }
}
