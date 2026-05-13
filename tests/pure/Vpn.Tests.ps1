# Vpn.Tests.ps1 — pure tests for the AllowedIPs transforms and CIDR helpers.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) {
        $env:CLAUDEARIUM_REPO_ROOT
    } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1') -Force
}

Describe 'ConvertTo-SplitAllowedIPs' {
    It 'splits IPv4 0.0.0.0/0 into two /1s' {
        $cfg = "[Peer]`nAllowedIPs = 0.0.0.0/0`n"
        $out = ConvertTo-SplitAllowedIPs -WgConfigContent $cfg
        $out | Should -Match 'AllowedIPs\s*=\s*0\.0\.0\.0/1,\s*128\.0\.0\.0/1'
    }

    It 'splits IPv6 ::/0 into two halves and removes the original ::/0 token' {
        $cfg = "[Peer]`nAllowedIPs = 0.0.0.0/0, ::/0`n"
        $out = ConvertTo-SplitAllowedIPs -WgConfigContent $cfg
        $out | Should -Match '::/1,\s*8000::/1'
        # The original /0 routes must not survive in the output, otherwise
        # wg-quick will overwrite our policy routing and the killswitch
        # breaks. Bound the token so we don't false-positive on `::/1`.
        $out | Should -Not -Match '(?<!\d)::/0(?!\d)'
        $out | Should -Not -Match '(?<!\d)0\.0\.0\.0/0(?!\d)'
        # Regression guard: previously the combined IPv4-/0 + IPv6-::/0 case
        # produced `128.0.0.0/1,, ::/1, ...` (double comma). The IPv6
        # replacement now uses a lookbehind so the separator stays intact.
        $out | Should -Not -Match ',,'
    }

    It 'splits a lone IPv6 ::/0 (no IPv4 catch-all on the line)' {
        $cfg = "[Peer]`nAllowedIPs = ::/0`n"
        $out = ConvertTo-SplitAllowedIPs -WgConfigContent $cfg
        # No leading comma — the AllowedIPs value should start with `::/1,`.
        $out | Should -Match '(?m)^AllowedIPs = ::/1,\s*8000::/1\s*$'
    }

    It 'is case-insensitive on the AllowedIPs key' {
        $cfg = "[Peer]`nALLOWEDIPS = 0.0.0.0/0`n"
        $out = ConvertTo-SplitAllowedIPs -WgConfigContent $cfg
        $out | Should -Match '0\.0\.0\.0/1,\s*128\.0\.0\.0/1'
    }

    It 'leaves non-AllowedIPs lines untouched' {
        $cfg = "[Interface]`nAddress = 10.0.0.2/32`n"
        ConvertTo-SplitAllowedIPs -WgConfigContent $cfg | Should -Be $cfg
    }
}

Describe 'Get-IPv4UInt32 / Get-IPv4FromUInt32 round-trip' {
    It 'round-trips 0.0.0.0' {
        Get-IPv4FromUInt32 -Value (Get-IPv4UInt32 -Address '0.0.0.0') | Should -Be '0.0.0.0'
    }
    It 'round-trips 192.168.1.42' {
        Get-IPv4FromUInt32 -Value (Get-IPv4UInt32 -Address '192.168.1.42') | Should -Be '192.168.1.42'
    }
    It 'round-trips 255.255.255.255' {
        Get-IPv4FromUInt32 -Value (Get-IPv4UInt32 -Address '255.255.255.255') | Should -Be '255.255.255.255'
    }
    It 'rejects malformed input' {
        { Get-IPv4UInt32 -Address '1.2.3'     } | Should -Throw
        { Get-IPv4UInt32 -Address '256.0.0.0' } | Should -Throw
        { Get-IPv4UInt32 -Address 'not-an-ip' } | Should -Throw
    }
}

Describe 'Get-IPv4PrefixMask' {
    It '/0  -> 0.0.0.0'         { Get-IPv4FromUInt32 -Value (Get-IPv4PrefixMask -Prefix 0)  | Should -Be '0.0.0.0' }
    It '/1  -> 128.0.0.0'       { Get-IPv4FromUInt32 -Value (Get-IPv4PrefixMask -Prefix 1)  | Should -Be '128.0.0.0' }
    It '/8  -> 255.0.0.0'       { Get-IPv4FromUInt32 -Value (Get-IPv4PrefixMask -Prefix 8)  | Should -Be '255.0.0.0' }
    It '/24 -> 255.255.255.0'   { Get-IPv4FromUInt32 -Value (Get-IPv4PrefixMask -Prefix 24) | Should -Be '255.255.255.0' }
    It '/32 -> 255.255.255.255' { Get-IPv4FromUInt32 -Value (Get-IPv4PrefixMask -Prefix 32) | Should -Be '255.255.255.255' }
    # Regression guard: 0xFFFFFFFF as a bare pwsh literal parses to int32 = -1,
    # which then refuses to cast to uint32 / uint64. If somebody "simplifies"
    # Get-IPv4PrefixMask back to that form, this fails loud.
    It '/32 yields a uint32 of value 4294967295 (not int32 -1)' {
        $m = Get-IPv4PrefixMask -Prefix 32
        $m | Should -BeOfType ([uint32])
        $m | Should -Be ([uint32]4294967295)
    }
}

Describe 'ConvertTo-InvertedAllowedIPs' {
    It 'throws when the LAN covers the whole address space (/0)' {
        # Would otherwise produce 'AllowedIPs = ' (empty), an invalid wg config
        # that bricks the tunnel while the killswitch stays armed.
        { ConvertTo-InvertedAllowedIPs -LanCidr '0.0.0.0/0' } | Should -Throw
    }

    It 'inverts /24 into exactly 24 ascending CIDRs that exclude the LAN' {
        $out = ConvertTo-InvertedAllowedIPs -LanCidr '192.168.1.0/24'
        $parts = $out -split ',\s*'
        $parts.Count | Should -Be 24
        $parts | Should -Not -Contain '192.168.1.0/24'
        $parts[0]                | Should -Be '0.0.0.0/1'
        $parts[$parts.Count - 1] | Should -Be '224.0.0.0/3'
    }

    It 'inverts /8 into exactly 8 entries excluding the LAN' {
        $out = ConvertTo-InvertedAllowedIPs -LanCidr '10.0.0.0/8'
        $parts = $out -split ',\s*'
        $parts.Count | Should -Be 8
        $parts | Should -Not -Contain '10.0.0.0/8'
    }

    It 'inverts /12 into exactly 12 entries excluding the LAN' {
        $out = ConvertTo-InvertedAllowedIPs -LanCidr '172.16.0.0/12'
        $parts = $out -split ',\s*'
        $parts.Count | Should -Be 12
        $parts | Should -Not -Contain '172.16.0.0/12'
    }

    It 'inverts a /1 top-half LAN (128.0.0.0/1) into a single 0.0.0.0/1' {
        ConvertTo-InvertedAllowedIPs -LanCidr '128.0.0.0/1' | Should -Be '0.0.0.0/1'
    }

    It 'inverts a /1 bottom-half LAN (0.0.0.0/1) into a single 128.0.0.0/1' {
        ConvertTo-InvertedAllowedIPs -LanCidr '0.0.0.0/1' | Should -Be '128.0.0.0/1'
    }

    It 'inverts a /32 single-host LAN into exactly 32 entries excluding the host' {
        $out = ConvertTo-InvertedAllowedIPs -LanCidr '10.0.0.1/32'
        $parts = $out -split ',\s*'
        $parts.Count | Should -Be 32
        $parts | Should -Not -Contain '10.0.0.1/32'
        # The sibling at the bottom level is the other /32 in the same /31.
        $parts | Should -Contain '10.0.0.0/32'
    }

    It 'normalizes a non-canonical CIDR (host bits set) to the network address' {
        $a = ConvertTo-InvertedAllowedIPs -LanCidr '192.168.1.42/24'
        $b = ConvertTo-InvertedAllowedIPs -LanCidr '192.168.1.0/24'
        $a | Should -Be $b
    }

    It 'rejects malformed CIDR' {
        { ConvertTo-InvertedAllowedIPs -LanCidr 'not-a-cidr'       } | Should -Throw
        { ConvertTo-InvertedAllowedIPs -LanCidr '192.168.1.0'      } | Should -Throw
        { ConvertTo-InvertedAllowedIPs -LanCidr '192.168.1.0/33'   } | Should -Throw
        { ConvertTo-InvertedAllowedIPs -LanCidr '999.0.0.0/8'      } | Should -Throw
    }
}

Describe 'Get-HostPrimaryIPv4Subnet (shape smoke test)' {
    # Full mock coverage of Get-NetRoute / Get-NetIPAddress is brittle (those
    # cmdlets are Windows-only and version-sensitive); the function itself
    # already returns $null on any failure. This test just proves: it doesn't
    # throw, and when it returns something it returns the documented shape.
    It 'returns either $null or @{ Cidr; Network; Prefix; InterfaceAlias }' {
        $r = Get-HostPrimaryIPv4Subnet
        if ($null -ne $r) {
            $r.ContainsKey('Cidr')           | Should -BeTrue
            $r.ContainsKey('Network')        | Should -BeTrue
            $r.ContainsKey('Prefix')         | Should -BeTrue
            $r.ContainsKey('InterfaceAlias') | Should -BeTrue
            $r.Cidr   | Should -Match '^\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}$'
            $r.Prefix | Should -BeOfType ([int])
        }
    }
}

Describe 'Get-HostPrimaryIPv4Subnet (mocked detection path)' {
    # Regression guard for the IPAddress vs IPv4Address bug: Get-NetIPAddress
    # exposes the IPv4 string as .IPAddress, not .IPv4Address. Without this
    # test, accessing the wrong field silently filters every row out and the
    # shape-smoke test trivially passes ($null path).
    It 'computes the network address from the assigned IP and prefix' {
        if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Get-NetRoute is Windows-only; mocked detection cannot run on this host'
            return
        }
        Mock -ModuleName Vpn Get-NetRoute {
            [pscustomobject]@{
                DestinationPrefix = '0.0.0.0/0'
                NextHop           = '192.168.1.1'
                InterfaceIndex    = 7
                InterfaceAlias    = 'Ethernet'
                RouteMetric       = 0
                InterfaceMetric   = 25
            }
        }
        Mock -ModuleName Vpn Get-NetIPAddress {
            [pscustomobject]@{
                IPAddress    = '192.168.1.42'
                PrefixLength = 24
                PrefixOrigin = 'Dhcp'
            }
        }
        $r = Get-HostPrimaryIPv4Subnet
        $r                | Should -Not -BeNullOrEmpty
        $r.Cidr           | Should -Be '192.168.1.0/24'
        $r.Network        | Should -Be '192.168.1.0'
        $r.Prefix         | Should -Be 24
        $r.InterfaceAlias | Should -Be 'Ethernet'
    }
}

Describe 'Set-AllowedIPs' {
    It 'replaces the AllowedIPs line with the supplied value' {
        $cfg = "[Interface]`nAddress = 10.0.0.2/32`n`n[Peer]`nAllowedIPs = 0.0.0.0/0`n"
        $out = Set-AllowedIPs -WgConfigContent $cfg -AllowedIPs '10.0.0.0/8, 172.16.0.0/12'
        $out | Should -Match 'AllowedIPs = 10\.0\.0\.0/8,\s*172\.16\.0\.0/12'
        $out | Should -Not -Match 'AllowedIPs = 0\.0\.0\.0/0'
    }

    It 'replaces every AllowedIPs line (multi-peer)' {
        $cfg = "[Peer]`nAllowedIPs = 10.0.0.0/8`n[Peer]`nAllowedIPs = 192.168.0.0/16`n"
        $out = Set-AllowedIPs -WgConfigContent $cfg -AllowedIPs '0.0.0.0/1'
        ([regex]::Matches($out, '(?im)^AllowedIPs = 0\.0\.0\.0/1\s*$')).Count | Should -Be 2
    }

    It 'preserves Interface and other non-AllowedIPs lines' {
        $cfg = "[Interface]`nPrivateKey = xxx`nAddress = 10.0.0.2/32`n`n[Peer]`nAllowedIPs = 0.0.0.0/0`nEndpoint = peer.example:51820`n"
        $out = Set-AllowedIPs -WgConfigContent $cfg -AllowedIPs 'something'
        $out | Should -Match 'PrivateKey = xxx'
        $out | Should -Match 'Address = 10\.0\.0\.2/32'
        $out | Should -Match 'Endpoint = peer\.example:51820'
    }

    It 'throws when no AllowedIPs line exists' {
        { Set-AllowedIPs -WgConfigContent "[Peer]`nEndpoint = peer:51820`n" -AllowedIPs '10.0.0.0/8' } | Should -Throw
    }

    It 'rejects an empty / whitespace -AllowedIPs value' {
        $cfg = "[Peer]`nAllowedIPs = 0.0.0.0/0`n"
        # '' is rejected by the PS parameter binder (no AllowEmptyString).
        { Set-AllowedIPs -WgConfigContent $cfg -AllowedIPs ''    } | Should -Throw
        # Whitespace-only passes the binder; our inner check throws with a clear message.
        { Set-AllowedIPs -WgConfigContent $cfg -AllowedIPs '   ' } | Should -Throw '*non-empty*'
    }

    It 'repairs an existing-but-empty AllowedIPs line (regex matches zero-or-more, not one-or-more)' {
        $cfg = "[Peer]`nAllowedIPs = `nEndpoint = peer.example:51820`n"
        $out = Set-AllowedIPs -WgConfigContent $cfg -AllowedIPs '10.0.0.0/8'
        $out | Should -Match '(?m)^AllowedIPs = 10\.0\.0\.0/8\s*$'
        $out | Should -Match 'Endpoint = peer\.example:51820'
    }

    It 'matches an indented AllowedIPs line (wg config tolerates leading whitespace)' {
        $cfg = "[Peer]`n  AllowedIPs = 0.0.0.0/0`n"
        $out = Set-AllowedIPs -WgConfigContent $cfg -AllowedIPs '10.0.0.0/8'
        $out | Should -Match '(?m)^\s*AllowedIPs = 10\.0\.0\.0/8'
        $out | Should -Not -Match '0\.0\.0\.0/0'
    }
}

Describe 'Get-TransformedWgConfig (preflight)' {
    BeforeAll {
        $script:tmpFromConfig = New-TemporaryFile
        @"
[Interface]
Address = 10.0.0.2/32

[Peer]
AllowedIPs = 0.0.0.0/0
Endpoint = peer.example:51820
"@ | Set-Content -LiteralPath $script:tmpFromConfig -Encoding UTF8

        $script:tmpNoAllowedIPs = New-TemporaryFile
        @"
[Interface]
Address = 10.0.0.2/32

[Peer]
Endpoint = peer.example:51820
"@ | Set-Content -LiteralPath $script:tmpNoAllowedIPs -Encoding UTF8
    }
    AfterAll {
        foreach ($p in @($script:tmpFromConfig, $script:tmpNoAllowedIPs)) {
            if ($p -and (Test-Path $p)) { Remove-Item -LiteralPath $p -Force }
        }
    }

    It 'returns the split-form rewrite for from-config mode' {
        $out = Get-TransformedWgConfig -SourcePath $script:tmpFromConfig
        $out | Should -Match 'AllowedIPs = 0\.0\.0\.0/1,\s*128\.0\.0\.0/1'
    }

    It 'returns the inverted-LAN list for all-except-lan mode' {
        $out = Get-TransformedWgConfig -SourcePath $script:tmpFromConfig -RoutingMode 'all-except-lan' -LanCidr '192.168.1.0/24'
        $out | Should -Match 'AllowedIPs = 0\.0\.0\.0/1,'
        $out | Should -Not -Match '192\.168\.1\.0/24'
    }

    It 'throws on a source with no AllowedIPs line in all-except-lan mode (catches preflight before Install-VpnPayload)' {
        { Get-TransformedWgConfig -SourcePath $script:tmpNoAllowedIPs -RoutingMode 'all-except-lan' -LanCidr '192.168.1.0/24' } | Should -Throw
    }

    It 'throws when SourcePath does not exist' {
        { Get-TransformedWgConfig -SourcePath 'C:\does\not\exist.conf' } | Should -Throw
    }

    It 'accepts a path containing wildcard glyphs (Test-Path uses -LiteralPath)' {
        $bracketPath = Join-Path ([System.IO.Path]::GetTempPath()) ("wg [test] " + [Guid]::NewGuid().ToString('N') + ".conf")
        Set-Content -LiteralPath $bracketPath -Value "[Peer]`nAllowedIPs = 0.0.0.0/0`n" -Encoding UTF8
        try {
            { Get-TransformedWgConfig -SourcePath $bracketPath } | Should -Not -Throw
            Get-TransformedWgConfig -SourcePath $bracketPath | Should -Match 'AllowedIPs = 0\.0\.0\.0/1'
        }
        finally {
            if (Test-Path -LiteralPath $bracketPath) { Remove-Item -LiteralPath $bracketPath -Force }
        }
    }
}

Describe 'Copy-WgConfig routing-mode dispatch' {
    BeforeAll {
        # Snapshot Send-RootFileToDistro inside the Vpn module so Copy-WgConfig
        # writes to a capture variable instead of hitting the distro.
        $script:capture = $null
        Mock -ModuleName Vpn Send-RootFileToDistro {
            param($DistroName, $Content, $DestPath, $Mode)
            $script:capture = @{ Content = $Content; DestPath = $DestPath; Mode = $Mode }
        }
        $script:tmp = New-TemporaryFile
        # AllowedIPs has the catch-all so we can prove the two modes diverge.
        @"
[Interface]
Address = 10.0.0.2/32

[Peer]
AllowedIPs = 0.0.0.0/0
Endpoint = peer.example:51820
"@ | Set-Content -LiteralPath $script:tmp -Encoding UTF8
    }
    AfterAll {
        if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item -LiteralPath $script:tmp -Force }
    }

    It 'from-config (default) applies the catch-all split-form rewrite' {
        $script:capture = $null
        Copy-WgConfig -DistroName 'dummy' -SourcePath $script:tmp
        $script:capture.DestPath | Should -Be '/etc/wireguard/wg0.conf'
        $script:capture.Mode     | Should -Be '0600'
        $script:capture.Content  | Should -Match 'AllowedIPs = 0\.0\.0\.0/1,\s*128\.0\.0\.0/1'
        $script:capture.Content  | Should -Not -Match '(?<!\d)0\.0\.0\.0/0(?!\d)'
    }

    It 'all-except-lan overrides AllowedIPs with the inverted LAN list' {
        $script:capture = $null
        Copy-WgConfig -DistroName 'dummy' -SourcePath $script:tmp -RoutingMode 'all-except-lan' -LanCidr '192.168.1.0/24'
        $script:capture.Content | Should -Not -Match '(?<!\d)0\.0\.0\.0/0(?!\d)'
        $script:capture.Content | Should -Not -Match '192\.168\.1\.0/24'
        # First and last CIDRs of the inversion must appear on the AllowedIPs line.
        $script:capture.Content | Should -Match 'AllowedIPs = 0\.0\.0\.0/1,'
        $script:capture.Content | Should -Match '(?m)^AllowedIPs = .*224\.0\.0\.0/3\s*$'
    }

    It 'all-except-lan requires -LanCidr' {
        { Copy-WgConfig -DistroName 'dummy' -SourcePath $script:tmp -RoutingMode 'all-except-lan' } | Should -Throw
    }
}
