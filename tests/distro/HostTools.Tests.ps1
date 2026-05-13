# HostTools.Tests.ps1 — `host-tools add / list / remove`. Uses a /host/...
# guest-style path so we don't need an actual Windows .exe on the host.

BeforeAll {
    $repoRoot = if ($env:CLAUDEARIUM_REPO_ROOT) { $env:CLAUDEARIUM_REPO_ROOT } else {
        Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    }
    $distro = if ($env:CLAUDEARIUM_TEST_DISTRO) { $env:CLAUDEARIUM_TEST_DISTRO } else { 'claudearium-test' }
    Import-Module (Join-Path $repoRoot 'modules\Wsl.psm1') -Force
    Import-Module (Join-Path $repoRoot 'tests\lib\TestRunHelpers.psm1') -Force
    $script:repoRoot    = $repoRoot
    $script:distro      = $distro
    $script:profilePath = New-IsolatedTestProfile -DistroName $distro -Tag 'hosttools'
    $script:exeGuest    = '/host/fakedir/sample.exe'
    $script:guestCmd    = 'sb-sample'
}

AfterAll {
    Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
        -Args @{ Verb='host-tools'; SubVerb='remove'; Arg=$script:guestCmd; Force=$true } -AllowFail | Out-Null
    Remove-Item -LiteralPath $script:profilePath -ErrorAction SilentlyContinue
}

Describe 'host-tools add' -Tag 'distro' {
    It 'installs an executable wrapper under /usr/local/bin' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='host-tools'; SubVerb='add'; HostExe=$script:exeGuest; GuestCommand=$script:guestCmd }

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "test -x /usr/local/bin/$script:guestCmd && echo ok" -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'embeds the claudearium-hosttool marker in the wrapper body' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "cat /usr/local/bin/$script:guestCmd" -CaptureOutput
        ($r.Output -join "`n") | Should -Match 'claudearium-hosttool: sample'
    }
}

Describe 'host-tools remove' -Tag 'distro' {
    It 'deletes the wrapper and clears the profile entry' {
        Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
            -Args @{ Verb='host-tools'; SubVerb='remove'; Arg=$script:guestCmd; Force=$true }

        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "test -e /usr/local/bin/$script:guestCmd && echo present || echo gone" -CaptureOutput
        ($r.Output -join "`n").Trim() | Should -Be 'gone'
    }
}

Describe 'Add-CatalogToolAsHostAttach (drop-in name)' -Tag 'distro' {
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'modules\Profile.psm1') -Force
        Import-Module (Join-Path $script:repoRoot 'modules\HostTools.psm1') -Force
        $script:attachExe  = '/host/fakedir/gh.exe'
        $script:attachName = 'gh'
    }
    AfterAll {
        Invoke-InDistro -Name $script:distro -User 'root' `
            -Command "rm -f /usr/local/bin/$script:attachName" -AllowFail | Out-Null
        Remove-HostToolFromProfile -ProfilePath $script:profilePath -GuestCommand $script:attachName | Out-Null
    }

    It 'writes a hostTools entry whose guestCommand is the bare tool name (not sb-prefixed)' {
        Add-CatalogToolAsHostAttach -ProfilePath $script:profilePath -ToolName $script:attachName -WindowsExe $script:attachExe
        $spec = Read-Profile -Path $script:profilePath -Raw
        ($spec.hostTools | Where-Object { $_.guestCommand -eq $script:attachName }).Count | Should -Be 1
    }

    It 'installs the wrapper at /usr/local/bin/<toolname> when applied to the live distro' {
        $spec = Read-Profile -Path $script:profilePath -Raw
        $entry = @($spec.hostTools | Where-Object { $_.guestCommand -eq $script:attachName })[0]
        Install-HostToolWrapper -DistroName $script:distro -ToolSpec $entry
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "test -x /usr/local/bin/$script:attachName && echo ok" -CaptureOutput -AllowFail
        ($r.Output -join "`n").Trim() | Should -Be 'ok'
    }

    It 'puts the managed-by marker on the drop-in wrapper too' {
        $r = Invoke-InDistro -Name $script:distro -User 'claude' `
            -Command "cat /usr/local/bin/$script:attachName" -CaptureOutput
        ($r.Output -join "`n") | Should -Match "claudearium-hosttool: $script:attachName"
    }
}
