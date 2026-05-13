# Vpn.psm1
# WireGuard tunnel + nftables killswitch lifecycle. The killswitch is on
# whenever the payload is installed; the tunnel itself is opt-in (depends on
# the user supplying a wg0.conf via profile.vpn.wgConfigPath).
#
# When the killswitch is armed and the tunnel is down, the sandbox can reach:
#   - localhost
#   - the WSL2 NAT host subnet (so `host.internal` resolves to the Windows
#     gateway, keeping host services like Seq reachable)
#   - the WG peer endpoint (so the handshake to bring the tunnel up can occur)
# Everything else off eth0 drops. See payload/etc/nftables.conf for rules.
#
# Public surface:
#   Set-VpnPayloadRoot -Path                      — injected by the entry-point at startup
#   Send-RootFileToDistro -DistroName -Content -DestPath [-Mode]
#                                                 — base64-transport a file, root-owned
#   ConvertTo-SplitAllowedIPs -WgConfigContent    — 0.0.0.0/0 -> 0.0.0.0/1, 128.0.0.0/1
#                                                 — see docs/wsl2-gotchas.md#12
#   ConvertTo-InvertedAllowedIPs -LanCidr         — IPv4 CIDR list covering 0.0.0.0/0 minus the LAN
#   Set-AllowedIPs -WgConfigContent -AllowedIPs   — replace every AllowedIPs line with the given value
#   Get-HostPrimaryIPv4Subnet                     — detect Windows host's default-route IPv4 subnet
#   Get-TransformedWgConfig -SourcePath [-RoutingMode] [-LanCidr]
#                                                 — pure: read + transform; for preflighting bad input
#                                                   before arming the killswitch
#   Test-WgConfigHasDns   -SourcePath             — pure: returns $true iff a usable DNS = line exists
#                                                   in the [Interface] section. Caller warns the user
#                                                   when missing (nftables blocks port 53 to host gw).
#   Copy-WgConfig         -DistroName -SourcePath [-RoutingMode] [-LanCidr]
#                                                 — read + transform + install at /etc/wireguard/wg0.conf
#                                                   RoutingMode = 'from-config' (default, split-form only)
#                                                              or 'all-except-lan' (override AllowedIPs with inverted LAN)
#   Install-VpnPayload    -DistroName             — push nftables.conf, prep script, killswitch unit
#   Test-KillswitchActive -DistroName             — does 'table inet claudearium' exist?
#   Test-VpnActive        -DistroName             — does wg0 interface exist?
#   Enable-Vpn / Disable-Vpn / Reset-Vpn          — systemctl wrappers
#   Get-VpnStatus         -DistroName             — wg show + nft count + host.internal probe
#   Uninstall-Killswitch  -DistroName             — flush table + disable units (keep payload)
#
# Notable order: claudearium-killswitch.service has Before=nftables.service
# wg-quick@wg0.service so it generates /etc/nftables.conf.d/00-host.nft
# *before* the firewall loads and the tunnel comes up.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')

$Script:PayloadRoot = $null   # callers (the entry-point) inject this

function Set-VpnPayloadRoot {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $Script:PayloadRoot = $Path
}

function Send-RootFileToDistro {
    # Write $Content to $DestPath inside the distro as root, mode $Mode.
    # Uses the same base64 transport pattern as Send-FileToDistro in the
    # entry-point (root shell, single-line command, no shell-var interpolation
    # on the bash side).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$DestPath,
        [string]$Mode = '0644'
    )
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $parent = (Split-Path -Parent $DestPath) -replace '\\','/'
    $cmd = "set -e; mkdir -p '$parent'; printf '%s' '$b64' | base64 -d > '$DestPath'; chmod $Mode '$DestPath'"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Get-PayloadFileContent {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$RelativePath)
    if (-not $Script:PayloadRoot) { throw 'Vpn payload root not set. Call Set-VpnPayloadRoot first.' }
    $abs = Join-Path $Script:PayloadRoot $RelativePath
    if (-not (Test-Path $abs)) { throw "Vpn payload missing: $abs" }
    return Get-Content -LiteralPath $abs -Raw
}

function ConvertTo-SplitAllowedIPs {
    # Replaces 'AllowedIPs = 0.0.0.0/0[, ...]' with split routing
    # (0.0.0.0/1, 128.0.0.0/1, ...). Same address space, but wg-quick installs
    # ordinary routes rather than the fwmark + policy-routing trick that swallows
    # more-specific routes — so the eth0 -> host-subnet route still wins.
    # IPv6 `::/0` gets the same treatment (`::/1, 8000::/1`).
    # The patterns tolerate leading horizontal whitespace on the AllowedIPs line
    # (wg config files permit indented key=value lines).
    [CmdletBinding()] param([Parameter(Mandatory)][string]$WgConfigContent)
    $out = $WgConfigContent
    $out = [regex]::Replace($out, '(?im)^([\t ]*AllowedIPs[\t ]*=[\t ]*)0\.0\.0\.0/0', '${1}0.0.0.0/1, 128.0.0.0/1')
    # IPv6: two passes so we cover both the start-of-value case and a `::/0`
    # later in the route list, without corrupting non-canonical addresses
    # like `2001::/0`. The captured prefix is re-emitted via ${1} so any
    # `, ` separator stays intact (the lookbehind earlier version produced
    # a double comma in the combined IPv4-/0 + IPv6-::/0 case).
    #
    #   Pass 1 — `::/0` is the first token: matches `AllowedIPs = ::/0` and
    #     `AllowedIPs=::/0` (no whitespace after `=`).
    #   Pass 2 — `::/0` later in the list: requires a `,` or whitespace
    #     immediately before, so the substring `::/0` inside `2001::/0` /
    #     `fd00::/0` doesn't match.
    $out = [regex]::Replace($out, '(?im)^([\t ]*AllowedIPs[\t ]*=[\t ]*)::/0(?!\d)',           '${1}::/1, 8000::/1')
    $out = [regex]::Replace($out, '(?im)^([\t ]*AllowedIPs[\t ]*=[^\r\n]*?[\s,])::/0(?!\d)',  '${1}::/1, 8000::/1')
    return $out
}

function Get-IPv4UInt32 {
    # Pure helper: '192.168.1.42' -> [uint32]0xC0A8012A.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Address)
    if ($Address -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
        throw "Not an IPv4 address: $Address"
    }
    $b1 = [int]$Matches[1]; $b2 = [int]$Matches[2]; $b3 = [int]$Matches[3]; $b4 = [int]$Matches[4]
    foreach ($b in @($b1, $b2, $b3, $b4)) {
        if ($b -lt 0 -or $b -gt 255) { throw "Not an IPv4 address: $Address" }
    }
    return [uint32]((([uint32]$b1) -shl 24) -bor (([uint32]$b2) -shl 16) -bor (([uint32]$b3) -shl 8) -bor ([uint32]$b4))
}

function Get-IPv4FromUInt32 {
    # Pure helper: [uint32]0xC0A8012A -> '192.168.1.42'.
    [CmdletBinding()] param([Parameter(Mandatory)][uint32]$Value)
    $b1 = [int](($Value -shr 24) -band 0xFF)
    $b2 = [int](($Value -shr 16) -band 0xFF)
    $b3 = [int](($Value -shr 8)  -band 0xFF)
    $b4 = [int]( $Value           -band 0xFF)
    return "$b1.$b2.$b3.$b4"
}

function Get-IPv4PrefixMask {
    # /N -> uint32 netmask (e.g. /24 -> 0xFFFFFF00). /0 -> 0; /32 -> 0xFFFFFFFF.
    # NB: 0xFFFFFFFF as a bare literal parses as int32 = -1 in pwsh, which
    # then refuses to cast to uint32/uint64. Use decimal 4294967295 so the
    # parser treats it as int64 first, then the cast works.
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateRange(0,32)][int]$Prefix)
    if ($Prefix -eq 0)  { return [uint32]0 }
    if ($Prefix -eq 32) { return [uint32]4294967295 }
    $allOnes = [uint64]4294967295
    $shifted = [uint64]($allOnes -shl (32 - $Prefix))
    return [uint32]($shifted -band $allOnes)
}

function ConvertTo-InvertedAllowedIPs {
    # Returns a comma-separated IPv4 CIDR list covering 0.0.0.0/0 minus the
    # given LAN — for the 'all-except-lan' routing mode. The CIDR list is
    # never catch-all, so wg-quick installs plain main-table routes (no
    # fwmark/policy-routing trick), and the distro's eth0 default route
    # naturally handles traffic to the LAN via the WSL NAT to the host.
    #
    # Standard recursive-subtract algorithm, iterated with a stack:
    # walk from 0.0.0.0/0; for any block that equals the LAN, drop; for any
    # block that doesn't contain the LAN, emit; otherwise split into two
    # halves at one finer prefix and recurse.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$LanCidr)
    if ($LanCidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
        throw "Not a valid IPv4 CIDR: $LanCidr"
    }
    $lanPrefix = [int]$Matches[2]
    if ($lanPrefix -lt 0 -or $lanPrefix -gt 32) { throw "CIDR prefix out of range: $LanCidr" }
    if ($lanPrefix -eq 0) {
        # Excluding 0.0.0.0/0 leaves nothing — would produce 'AllowedIPs = ' (empty),
        # which is an invalid wg config and bricks the tunnel while the killswitch
        # stays armed. Fail loud instead.
        throw "LanCidr '$LanCidr' covers the entire address space; all-except-lan would tunnel nothing."
    }

    $lanU   = Get-IPv4UInt32   -Address $Matches[1]
    $lanMsk = Get-IPv4PrefixMask -Prefix $lanPrefix
    $lanNet = $lanU -band $lanMsk

    $result = [System.Collections.Generic.List[string]]::new()
    $stack  = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Net = [uint32]0; Prefix = 0 })

    while ($stack.Count -gt 0) {
        $b    = $stack.Pop()
        $bNet = [uint32]$b.Net
        $bPfx = [int]$b.Prefix

        if ($bPfx -eq $lanPrefix -and $bNet -eq $lanNet) { continue }

        $bMask = Get-IPv4PrefixMask -Prefix $bPfx
        if (($lanNet -band $bMask) -ne $bNet) {
            # Block doesn't contain the LAN — emit.
            $ipStr = Get-IPv4FromUInt32 -Value $bNet
            [void]$result.Add("$ipStr/$bPfx")
            continue
        }

        # Block contains the LAN and isn't equal to it. Split.
        $childPfx = $bPfx + 1
        $childBit = [uint32]([uint64]([uint64]1 -shl (32 - $childPfx)) -band [uint64]4294967295)
        $leftNet  = $bNet
        $rightNet = [uint32]($bNet -bor $childBit)
        # Push right first so DFS visits left first → ascending CIDR order.
        [void]$stack.Push(@{ Net = $rightNet; Prefix = $childPfx })
        [void]$stack.Push(@{ Net = $leftNet;  Prefix = $childPfx })
    }

    return ($result -join ', ')
}

function Set-AllowedIPs {
    # Replace every 'AllowedIPs = …' line with the given value. Throws if the
    # config has no AllowedIPs line — that would produce a silently-broken
    # tunnel rather than the explicit error the caller wants. Anything after
    # `AllowedIPs =` (including a trailing inline `# comment`) is consumed by
    # the replacement — wg-quick only treats `#` as a comment on lines that
    # *start* with it, so this is parse-safe but does drop annotations the
    # user may have written next to the routes.
    # An empty/whitespace -AllowedIPs is rejected (would write
    # `AllowedIPs = ` which is an invalid wg config). Callers in this module
    # already ensure non-empty values; the explicit reject keeps this helper
    # safe for future callers.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WgConfigContent,
        [Parameter(Mandatory)][string]$AllowedIPs
    )
    if ([string]::IsNullOrWhiteSpace($AllowedIPs)) {
        throw "Set-AllowedIPs: -AllowedIPs must be a non-empty value."
    }
    # `*` (not `+`) so an existing-but-empty `AllowedIPs =` line still matches
    # and gets repaired with our value rather than misleadingly looking like
    # the key is missing. `[\t ]*` (not `\s*`) on both sides of `=` so the
    # match can't bleed past the newline into the next line when the value
    # is empty. Leading `[\t ]*` before `AllowedIPs` so an indented config
    # line (wg-quick tolerates them) isn't reported as missing.
    $pattern = '(?im)^([\t ]*AllowedIPs[\t ]*=[\t ]*)[^\r\n]*'
    if (-not [regex]::IsMatch($WgConfigContent, $pattern)) {
        throw "wg config has no AllowedIPs line to replace."
    }
    # Escape `$` in the replacement so a value like `$1` or `${name}` isn't
    # interpreted by .NET regex as a backreference or named-group lookup.
    # `$$` is the documented literal-`$` escape in regex replacement strings.
    $escaped = $AllowedIPs.Replace('$', '$$')
    return [regex]::Replace($WgConfigContent, $pattern, ('${1}' + $escaped))
}

function Get-HostPrimaryIPv4Subnet {
    # Best-effort detection of the Windows host's primary IPv4 LAN subnet:
    # find the lowest-metric IPv4 default route, then read the assigned
    # IPv4 address + prefix on that interface, then compute the network
    # address. Returns @{ Cidr; Network; Prefix; InterfaceAlias } or $null
    # (no default route, cmdlets unavailable, anything else — fall back to
    # asking the user).
    [CmdletBinding()] param()
    try {
        if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) { return $null }
        $defaults = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
                      Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' })
        if (-not $defaults) { return $null }
        $best = $defaults | Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | Select-Object -First 1
        # Get-NetIPAddress exposes the address as $_.IPAddress (string),
        # NOT $_.IPv4Address — guarding on the wrong field would silently
        # filter every row out and make detection always return $null.
        $ipEntry = Get-NetIPAddress -InterfaceIndex $best.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                   Where-Object { $_.IPAddress -and $_.PrefixOrigin -ne 'WellKnown' } |
                   Select-Object -First 1
        if (-not $ipEntry) { return $null }
        $prefix = [int]$ipEntry.PrefixLength
        $u      = Get-IPv4UInt32     -Address $ipEntry.IPAddress
        $mask   = Get-IPv4PrefixMask -Prefix  $prefix
        $netStr = Get-IPv4FromUInt32 -Value ($u -band $mask)
        return @{
            Cidr           = "$netStr/$prefix"
            Network        = $netStr
            Prefix         = $prefix
            InterfaceAlias = [string]$best.InterfaceAlias
        }
    }
    catch {
        return $null
    }
}

function Test-WgConfigHasDns {
    # Returns $true iff the wg config at -SourcePath has a usable `DNS = …`
    # line in the [Interface] section. Used by Invoke-VpnEnable to warn the
    # user when DNS will leak: the killswitch blocks port 53 to the Windows
    # host gateway (which WSL2's default resolv.conf points at), so without
    # `DNS =` the wg-quick session can't resolve names.
    # Pure: takes a path, returns a bool. Empty/missing path -> $false.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath)
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return $false }
    $raw = Get-Content -LiteralPath $SourcePath -Raw
    # Match `DNS = <non-empty value>` on a non-comment line; comments may be
    # whole-line `#`/`;` or trailing `# ...` after the value.
    return [bool]([regex]::IsMatch($raw, '(?im)^[\t ]*DNS[\t ]*=[\t ]*[^\s#;].*$'))
}

function Get-TransformedWgConfig {
    # Pure: read the source wg0.conf and apply the requested AllowedIPs
    # transform. Returns the transformed content as a string. Throws on a
    # missing source file, an empty/invalid LanCidr in 'all-except-lan' mode,
    # or a source missing the AllowedIPs key in 'all-except-lan'. Pulled out
    # of Copy-WgConfig so Invoke-VpnEnable can preflight bad input *before*
    # arming the killswitch.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [ValidateSet('from-config','all-except-lan')][string]$RoutingMode = 'from-config',
        [string]$LanCidr
    )
    # -LiteralPath so a wg-config path containing wildcard glyphs ([, ], *)
    # isn't misinterpreted by the provider.
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "wg0.conf not found at: $SourcePath" }
    $raw = Get-Content -LiteralPath $SourcePath -Raw

    switch ($RoutingMode) {
        'all-except-lan' {
            if ([string]::IsNullOrWhiteSpace($LanCidr)) {
                throw "RoutingMode 'all-except-lan' requires -LanCidr."
            }
            $inverted = ConvertTo-InvertedAllowedIPs -LanCidr $LanCidr
            return Set-AllowedIPs -WgConfigContent $raw -AllowedIPs $inverted
        }
        default {
            return ConvertTo-SplitAllowedIPs -WgConfigContent $raw
        }
    }
}

function Copy-WgConfig {
    # Read the user's wg0.conf from the host, apply the requested AllowedIPs
    # transform, and install at /etc/wireguard/wg0.conf with 0600.
    #
    # RoutingMode 'from-config' (default): only rewrites the catch-all
    # 0.0.0.0/0 / ::/0 tokens into split form for the wg-quick / host-subnet
    # workaround (see ConvertTo-SplitAllowedIPs); specific routes pass through
    # untouched.
    #
    # RoutingMode 'all-except-lan': replaces every AllowedIPs line with the
    # inverted IPv4 CIDR list covering 0.0.0.0/0 minus -LanCidr. IPv6 routes
    # in the user's config are dropped in this mode (IPv4-only by design;
    # users with IPv6 needs should stay on 'from-config').
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$SourcePath,
        [ValidateSet('from-config','all-except-lan')][string]$RoutingMode = 'from-config',
        [string]$LanCidr
    )
    $transformed = Get-TransformedWgConfig -SourcePath $SourcePath -RoutingMode $RoutingMode -LanCidr $LanCidr
    Send-RootFileToDistro -DistroName $DistroName -Content $transformed -DestPath '/etc/wireguard/wg0.conf' -Mode '0600'
}

function Install-VpnPayload {
    # Push the three payload files + enable systemd units. Idempotent.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)

    Send-RootFileToDistro -DistroName $DistroName `
        -Content (Get-PayloadFileContent -RelativePath 'etc/nftables.conf') `
        -DestPath '/etc/nftables.conf' -Mode '0644'

    Send-RootFileToDistro -DistroName $DistroName `
        -Content (Get-PayloadFileContent -RelativePath 'usr/local/bin/claudearium-killswitch-prep') `
        -DestPath '/usr/local/bin/claudearium-killswitch-prep' -Mode '0755'

    Send-RootFileToDistro -DistroName $DistroName `
        -Content (Get-PayloadFileContent -RelativePath 'etc/systemd/system/claudearium-killswitch.service') `
        -DestPath '/etc/systemd/system/claudearium-killswitch.service' -Mode '0644'

    # systemctl --now / systemctl start can hang in WSL2 (wsl2-gotchas #4) —
    # enable for persistence, then trigger each service's effect inline via
    # its own command. Matches HostTools.Initialize-WslInteropService.
    $cmd = 'set -e; ' +
           'systemctl daemon-reload; ' +
           'systemctl enable claudearium-killswitch.service >/dev/null 2>&1; ' +
           'systemctl enable nftables.service >/dev/null 2>&1; ' +
           '/usr/local/bin/claudearium-killswitch-prep; ' +
           'nft -f /etc/nftables.conf'
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Test-KillswitchActive {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command "nft list table inet claudearium >/dev/null 2>&1" -AllowFail -CaptureOutput
    return ($r.ExitCode -eq 0)
}

function Test-VpnActive {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command "ip link show wg0 >/dev/null 2>&1" -AllowFail -CaptureOutput
    return ($r.ExitCode -eq 0)
}

function Enable-Vpn {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    # systemctl --now / start can hang in WSL2 (wsl2-gotchas #4) — enable for
    # persistence, then bring the tunnel up directly via wg-quick. From
    # systemd's perspective the unit stays `inactive`, so Disable-Vpn below
    # also bypasses systemd and calls `wg-quick down` directly to match.
    $cmd = 'set -e; ' +
           'systemctl enable wg-quick@wg0.service >/dev/null 2>&1; ' +
           'wg-quick up wg0'
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Disable-Vpn {
    # Brings wg0 down. The killswitch stays armed, so the sandbox is offline
    # (by design) until Enable-Vpn brings the tunnel back.
    # Tries `wg-quick down` first (matches Enable-Vpn's systemd-bypass path);
    # falls back to `systemctl stop` so we still tear down a tunnel that was
    # started by the systemd unit (e.g., at boot via Reset-Vpn).
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $cmd = 'wg-quick down wg0 2>/dev/null || systemctl stop wg-quick@wg0.service'
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd -AllowFail | Out-Null
}

function Reset-Vpn {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    Invoke-InDistro -Name $DistroName -User 'root' -Command 'systemctl restart claudearium-killswitch.service && systemctl restart nftables.service && systemctl restart wg-quick@wg0.service'
}

function Get-VpnStatus {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $cmd = 'echo "--- wg ---"; wg show 2>&1 || true; echo "--- ip addr wg0 ---"; ip -4 addr show wg0 2>&1 || true; echo "--- nft sandbox table count ---"; nft list table inet claudearium 2>/dev/null | wc -l; echo "--- host.internal hosts entry ---"; grep "host.internal" /etc/hosts 2>/dev/null || echo "(none)"; echo "--- host.internal ping ---"; ping -c1 -W1 host.internal 2>&1 | head -2 || true'
    $r = Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd -AllowFail -CaptureOutput
    return @{
        ExitCode = $r.ExitCode
        Output   = $r.Output
    }
}

function Uninstall-Killswitch {
    # Flushes our nftables table without uninstalling the systemd payload —
    # 'vpn enable' will reload it cleanly. Used when profile.vpn.killswitch
    # is flipped to false.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    Invoke-InDistro -Name $DistroName -User 'root' -Command 'nft delete table inet claudearium 2>/dev/null || true; systemctl disable --now claudearium-killswitch.service nftables.service' -AllowFail | Out-Null
}

Export-ModuleMember -Function Set-VpnPayloadRoot, `
    Send-RootFileToDistro, `
    ConvertTo-SplitAllowedIPs, `
    ConvertTo-InvertedAllowedIPs, `
    Set-AllowedIPs, `
    Get-IPv4UInt32, `
    Get-IPv4FromUInt32, `
    Get-IPv4PrefixMask, `
    Get-HostPrimaryIPv4Subnet, `
    Get-TransformedWgConfig, `
    Test-WgConfigHasDns, `
    Copy-WgConfig, `
    Install-VpnPayload, `
    Test-KillswitchActive, `
    Test-VpnActive, `
    Enable-Vpn, `
    Disable-Vpn, `
    Reset-Vpn, `
    Get-VpnStatus, `
    Uninstall-Killswitch
