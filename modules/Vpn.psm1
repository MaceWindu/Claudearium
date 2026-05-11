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
#   Copy-WgConfig         -DistroName -SourcePath — read + transform + install at /etc/wireguard/wg0.conf
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
    [CmdletBinding()] param([Parameter(Mandatory)][string]$WgConfigContent)
    $out = $WgConfigContent
    $out = [regex]::Replace($out, '(?im)^(AllowedIPs\s*=\s*)0\.0\.0\.0/0', '${1}0.0.0.0/1, 128.0.0.0/1')
    $out = [regex]::Replace($out, '(?im)^(AllowedIPs\s*=\s*[^\r\n]*?)\s*::/0',  '${1}, ::/1, 8000::/1')
    return $out
}

function Copy-WgConfig {
    # Read the user's wg0.conf from the host, apply the split-AllowedIPs
    # transform, and install at /etc/wireguard/wg0.conf with 0600.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$SourcePath
    )
    if (-not (Test-Path $SourcePath)) { throw "wg0.conf not found at: $SourcePath" }
    $raw = Get-Content -LiteralPath $SourcePath -Raw
    $transformed = ConvertTo-SplitAllowedIPs -WgConfigContent $raw
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

    Invoke-InDistro -Name $DistroName -User 'root' -Command 'systemctl daemon-reload && systemctl enable --now claudearium-killswitch.service && systemctl enable --now nftables.service'
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
    Invoke-InDistro -Name $DistroName -User 'root' -Command 'systemctl enable --now wg-quick@wg0.service'
}

function Disable-Vpn {
    # Brings wg0 down. The killswitch stays armed, so the sandbox is offline
    # (by design) until Enable-Vpn brings the tunnel back.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    Invoke-InDistro -Name $DistroName -User 'root' -Command 'systemctl stop wg-quick@wg0.service' -AllowFail | Out-Null
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

Export-ModuleMember -Function `
    Set-VpnPayloadRoot, `
    Send-RootFileToDistro, `
    ConvertTo-SplitAllowedIPs, `
    Copy-WgConfig, `
    Install-VpnPayload, `
    Test-KillswitchActive, `
    Test-VpnActive, `
    Enable-Vpn, `
    Disable-Vpn, `
    Reset-Vpn, `
    Get-VpnStatus, `
    Uninstall-Killswitch
