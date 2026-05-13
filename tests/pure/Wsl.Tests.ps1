# Wsl.Tests.ps1 — pure tests for the Wsl.psm1 helpers that don't actually
# touch wsl.exe. The bash-in-distro primitives (Invoke-InDistro,
# Invoke-InDistroScript) live in the distro lane.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
}

Describe 'ConvertFrom-WslListVerbose' {
    It 'parses a normal multi-distro listing' {
        # Typical `wsl --list --verbose` output after WSL_UTF8=1.
        $raw = @"
  NAME              STATE           VERSION
* claudearium       Running         2
  debian            Stopped         2
  Ubuntu-22.04      Stopped         2
"@
        $rows = ConvertFrom-WslListVerbose -Raw $raw
        $rows.Count | Should -Be 3
        $rows[0].Name    | Should -Be 'claudearium'
        $rows[0].State   | Should -Be 'Running'
        $rows[0].Version | Should -Be '2'
        $rows[1].Name    | Should -Be 'debian'
        $rows[1].State   | Should -Be 'Stopped'
        $rows[2].Name    | Should -Be 'Ubuntu-22.04'
    }

    It 'skips the NAME-STATE header even when surrounded by blank lines' {
        $raw = "`n  NAME    STATE    VERSION`n* foo    Running  2`n"
        $rows = ConvertFrom-WslListVerbose -Raw $raw
        $rows.Count | Should -Be 1
        $rows[0].Name  | Should -Be 'foo'
        $rows[0].State | Should -Be 'Running'
    }

    It 'strips the leading `*` from the default distro' {
        $raw = "  NAME    STATE    VERSION`n* claudearium    Running    2`n"
        $rows = ConvertFrom-WslListVerbose -Raw $raw
        $rows[0].Name | Should -Be 'claudearium'
    }

    It 'returns an empty array on empty input' {
        # @()-wrap on the call site: ConvertFrom-WslListVerbose returns @() and
        # PowerShell unwraps that to nothing through the call expression, so a
        # bare `.Count` would throw PropertyNotFoundException. Same pattern as
        # other pure tests in this repo.
        $a = @(ConvertFrom-WslListVerbose -Raw '')
        $a.Count | Should -Be 0
        $b = @(ConvertFrom-WslListVerbose -Raw $null)
        $b.Count | Should -Be 0
    }

    It 'returns an empty array when input is only the header' {
        $raw = "  NAME    STATE    VERSION`n"
        $a = @(ConvertFrom-WslListVerbose -Raw $raw)
        $a.Count | Should -Be 0
    }

    It 'leaves the Version field empty when the listing has only two columns' {
        # Older WSL releases didn't include a VERSION column. Be tolerant.
        $raw = "  NAME    STATE`n* foo    Running`n"
        $rows = ConvertFrom-WslListVerbose -Raw $raw
        $rows[0].Version | Should -Be ''
    }

    It 'handles CRLF line endings' {
        $raw = "  NAME    STATE    VERSION`r`n* foo    Running    2`r`n  bar    Stopped    2`r`n"
        $rows = ConvertFrom-WslListVerbose -Raw $raw
        $rows.Count   | Should -Be 2
        $rows[1].Name | Should -Be 'bar'
    }
}

Describe 'Convert-RootfsToTar' {
    BeforeAll {
        $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("wsl-rootfs-" + ([guid]::NewGuid().ToString('N').Substring(0,8)))
        [void][IO.Directory]::CreateDirectory($script:tmpDir)
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:tmpDir) { Remove-Item -LiteralPath $script:tmpDir -Recurse -Force }
    }

    It 'copies through a plain `.tar` (no decompression)' {
        $src = Join-Path $script:tmpDir 'rootfs.tar'
        $dst = Join-Path $script:tmpDir 'copied.tar'
        'tar-payload' | Set-Content -LiteralPath $src -Encoding UTF8
        Convert-RootfsToTar -SourcePath $src -DestPath $dst
        Test-Path -LiteralPath $dst | Should -BeTrue
        Get-Content -LiteralPath $dst -Raw | Should -Match 'tar-payload'
    }

    It 'no-ops when source and destination paths are the same .tar' {
        $src = Join-Path $script:tmpDir 'inplace.tar'
        'payload' | Set-Content -LiteralPath $src -Encoding UTF8
        { Convert-RootfsToTar -SourcePath $src -DestPath $src } | Should -Not -Throw
        Get-Content -LiteralPath $src -Raw | Should -Match 'payload'
    }

    It 'throws on an unsupported extension' {
        $src = Join-Path $script:tmpDir 'rootfs.zst'
        'payload' | Set-Content -LiteralPath $src -Encoding UTF8
        { Convert-RootfsToTar -SourcePath $src -DestPath (Join-Path $script:tmpDir 'out.tar') } | Should -Throw -ExpectedMessage 'Unsupported rootfs extension*'
    }
}

Describe 'Resolve-LatestDebianRootfsUrl' {
    It 'picks the lexicographically-latest %3A-encoded timestamp and re-uses it in the download URL' {
        # Captured snippet shape from images.linuxcontainers.org. Hrefs URL-encode `:` as %3A.
        # Two timestamps: one older, one newer. The function should pick the newer
        # and return its rootfs.tar.xz URL with the %3A intact.
        $fakeHtml = @{
            Content = @"
<html><body>
<a href="20260101_05%3A24/">20260101_05:24/</a>
<a href="20260513_11%3A02/">20260513_11:02/</a>
</body></html>
"@
        }
        Mock -ModuleName Wsl Invoke-WebRequest { return $fakeHtml }
        $url = Resolve-LatestDebianRootfsUrl
        $url | Should -Match '20260513_11%3[Aa]02'
        $url | Should -Match 'rootfs\.tar\.xz$'
        # And the older timestamp must NOT have been picked.
        $url | Should -Not -Match '20260101_05%3[Aa]24'
    }

    It 'tolerates lowercase `%3a` (encoder-dependent)' {
        # The captured regex used [Aa] in the character class. Lowercase encoding
        # should still resolve.
        $fakeHtml = @{
            Content = '<a href="20260513_11%3a02/">…</a>'
        }
        Mock -ModuleName Wsl Invoke-WebRequest { return $fakeHtml }
        $url = Resolve-LatestDebianRootfsUrl
        $url | Should -Match '20260513_11%3a02'
    }

    It 'throws when no timestamp directories are present' {
        $fakeHtml = @{ Content = '<html><body><a href="../">..</a></body></html>' }
        Mock -ModuleName Wsl Invoke-WebRequest { return $fakeHtml }
        { Resolve-LatestDebianRootfsUrl } | Should -Throw -ExpectedMessage 'Could not resolve latest rootfs timestamp*'
    }
}
