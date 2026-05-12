# VpnConnectivity.ps1 — toggle the VPN on/off, capture the egress IP
# from inside the distro before and after, and ask the tester to
# eyeball whether the with-VPN IP looks like their VPN provider's
# exit node. Requires the user's profile to point at a real
# wg0.conf (NeedsVpnReal=$true in the manifest, so the dashboard
# skips this test entirely unless -WgConfigPath was provided).
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$claudearium = Join-Path $repoRoot 'claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')      -Force
Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1')      -Force
Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')  -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force

$distro = Get-RealDistroForManualTest
if (-not (Test-RealDistroReady -DistroName $distro)) {
    return [pscustomobject]@{
        Name = 'manual/VpnConnectivity'; Passed = $false; Skipped = $true
        Notes = "real distro '$distro' is not registered"
    }
}

# Profile must reference a real wg0.conf for `vpn enable` to do anything.
$pp = Get-DefaultProfilePath
$wgPath = $null
if (Test-Path $pp) {
    try {
        $spec = Read-Profile -Path $pp
        if ($spec -and $spec.ContainsKey('vpn') -and $spec.vpn -and $spec.vpn.ContainsKey('wgConfigPath')) {
            $wgPath = [string]$spec.vpn.wgConfigPath
        }
    } catch { }
}
if (-not $wgPath -or -not (Test-Path $wgPath)) {
    return [pscustomobject]@{
        Name = 'manual/VpnConnectivity'; Passed = $false; Skipped = $true
        Notes = "profile.vpn.wgConfigPath isn't set to a readable file; supply -WgConfigPath when invoking the runner or edit the profile"
    }
}

# Get-IP probe — short timeout so a wedged tunnel doesn't hang the test.
$getIp = {
    param($DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'claude' `
        -Command "curl -m 6 -fsS https://api.ipify.org 2>/dev/null || echo (unreachable)" `
        -CaptureOutput -AllowFail
    return (($r.Output | Where-Object { $_ -is [string] }) -join '').Trim()
}

$wasEnabled = Test-VpnActive -DistroName $distro

return Invoke-ManualTest `
    -Name 'VPN routes egress; tunnel down means no egress' `
    -Instructions @"
This test will (in order):
  1. capture the egress IP with the VPN in whatever state you left it
  2. .\claudearium.ps1 vpn enable
  3. capture the egress IP again
  4. .\claudearium.ps1 vpn disable
  5. capture the egress IP a third time
  6. restore the VPN to whatever state it had at step 0

You then judge whether the captured IPs look right. Expected:
  - step 1: your real WAN IP (or VPN IP, if you had it on)
  - step 3: your VPN provider's exit IP
  - step 5: unreachable (killswitch armed, no route)
"@ `
    -Setup {
        $script:beforeIp = & $getIp $distro
        Write-Host "  IP before any change: $script:beforeIp" -ForegroundColor DarkGray

        & $claudearium vpn enable -NonInteractive | Out-Host
        Start-Sleep -Seconds 4
        $script:vpnIp = & $getIp $distro
        Write-Host "  IP with VPN enabled:  $script:vpnIp" -ForegroundColor DarkGray

        & $claudearium vpn disable -NonInteractive | Out-Host
        Start-Sleep -Seconds 2
        $script:offIp = & $getIp $distro
        Write-Host "  IP with VPN disabled: $script:offIp" -ForegroundColor DarkGray

        Write-Host ''
        Write-Host '  Summary:' -ForegroundColor Cyan
        Write-Host "    before: $script:beforeIp"
        Write-Host "    on:     $script:vpnIp"
        Write-Host "    off:    $script:offIp"
    } `
    -Question 'Do the IPs match the expected sequence (on = VPN exit, off = unreachable)?' `
    -Cleanup {
        # Restore whatever state the user had.
        try {
            if ($wasEnabled) {
                Write-Host '  Restoring VPN to enabled state...' -ForegroundColor DarkGray
                & $claudearium vpn enable -NonInteractive | Out-Host
            } else {
                Write-Host '  Leaving VPN disabled (it was off when we started).' -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  Restore warning: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } `
    -NonInteractive:$NonInteractive
