# VpnConnectivity.ps1 — toggle the VPN on/off against the ephemeral
# test distro and capture the egress IP each step so the tester can
# eyeball whether the with-VPN IP looks like their provider's exit
# node and whether the killswitch blocks egress when disabled.
# Requires -WgConfigPath on the runner (NeedsVpnReal=$true).
[CmdletBinding()]
param([switch]$NonInteractive)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$claudearium = Join-Path $repoRoot 'claudearium.ps1'

Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1')          -Force
Import-Module (Join-Path $repoRoot 'modules\Vpn.psm1')          -Force
Import-Module (Join-Path $repoRoot 'modules\Profile.psm1')      -Force
Import-Module (Join-Path $repoRoot 'tests\lib\ManualTest.psm1') -Force
Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force

$distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
if (-not (Test-DistroExists -Name $distro)) {
    return [pscustomobject]@{
        Name = 'manual/VpnConnectivity'; Passed = $false; Skipped = $true
        Notes = "test distro '$distro' is not registered (Invoke-TestRun should have provisioned it)"
    }
}

$wgPath = $env:CLAUDEARIUM_TEST_WG_CONFIG
if (-not $wgPath -or -not (Test-Path $wgPath)) {
    return [pscustomobject]@{
        Name = 'manual/VpnConnectivity'; Passed = $false; Skipped = $true
        Notes = "no readable wg config; invoke the runner with -WgConfigPath <path-to-wg0.conf>"
    }
}

# Isolated profile with vpn.wgConfigPath set, so the production verbs
# see a real config without touching the user's profile.
$profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'manual-vpn'
$spec = Read-Profile -Path $profilePath -Raw
$spec.vpn = [ordered]@{ wgConfigPath = $wgPath }
Write-Profile -Path $profilePath -Spec $spec

$getIp = {
    param($DistroName)
    $r = Invoke-InDistro -Name $DistroName -User 'claude' `
        -Command "curl -m 6 -fsS https://api.ipify.org 2>/dev/null || echo (unreachable)" `
        -CaptureOutput -AllowFail
    return (($r.Output | Where-Object { $_ -is [string] }) -join '').Trim()
}

return Invoke-ManualTest `
    -Name 'VPN routes egress; tunnel down means no egress' `
    -Instructions @"
This test will (against the ephemeral test distro '$distro'):
  1. capture the egress IP with no VPN
  2. .\claudearium.ps1 vpn enable
  3. capture the egress IP again
  4. .\claudearium.ps1 vpn disable
  5. capture the egress IP a third time

You then judge whether the captured IPs look right. Expected:
  - step 1: your real WAN IP (test distro starts with no tunnel)
  - step 3: your VPN provider's exit IP
  - step 5: unreachable (killswitch armed, no route)
"@ `
    -Setup {
        $script:beforeIp = & $getIp $distro
        Write-Host "  IP before any change: $script:beforeIp" -ForegroundColor DarkGray

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='vpn'; SubVerb='enable'
        } | Out-Null
        Start-Sleep -Seconds 4
        $script:vpnIp = & $getIp $distro
        Write-Host "  IP with VPN enabled:  $script:vpnIp" -ForegroundColor DarkGray

        Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -Args @{
            Verb='vpn'; SubVerb='disable'
        } | Out-Null
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
        try {
            Invoke-Claudearium -DistroName $distro -ProfilePath $profilePath -AllowFail -Args @{
                Verb='vpn'; SubVerb='disable'
            } | Out-Null
        } catch { }
        Remove-Item -LiteralPath $profilePath -ErrorAction SilentlyContinue
    } `
    -NonInteractive:$NonInteractive
