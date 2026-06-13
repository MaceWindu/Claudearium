#!/usr/bin/env pwsh
# Entry point for the Claude Code WSL2 sandbox tool.
# Verb dispatch for setup / status / nuke / reconcile / profile / project /
# session / mount / tools / login / vpn / host-tools / wt-profiles / hooks /
# claude-settings / claude-shared.
# Run with no args for the interactive central dashboard.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Verb,
    [Parameter(Position = 1)][string]$SubVerb,
    [Parameter(Position = 2)][string]$Arg,

    [string]$Name = 'claudearium',
    [string]$Base = 'debian-12',
    [string]$ProfilePath,
    [string]$RootfsPath,
    [string]$RootfsUrl,
    [string]$InstallPath,
    [string]$Out,
    [string]$Remote,
    [string]$DefaultBranch,
    [string]$Project,
    [string]$Branch,
    [string]$BaseBranch,
    [ValidateSet('distro','host')][string]$SessionType,
    [string]$HostCheckout,
    [string]$To,
    [string[]]$Tools,
    [switch]$DiscardDirty,
    [string]$Scope,
    [switch]$DryRun,
    [switch]$IncludeTodos,
    [switch]$IncludePlans,
    [string]$HostPath,
    [string]$Guest,
    [string]$Mode,
    [string]$MountOptions,
    [int]$Mtu,
    [string]$HostExe,
    [string]$GuestCommand,
    [string]$SmokeTest,
    [string[]]$HostShadows,
    [switch]$HostProject,
    [switch]$NewBranch,
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$NoBackup,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Snapshot the SCRIPT'S bound parameters. Inside a function `$PSBoundParameters`
# rebinds to that function's bound params, so a script-level check like
# `$PSBoundParameters.ContainsKey('Name')` is silently always-false from inside
# Invoke-Setup / Resolve-DistroForOps / etc. We capture once here and let the
# verb functions read $Script:RootBoundParams instead.
$Script:RootBoundParams = $PSBoundParameters

$Script:ScriptRoot = $PSScriptRoot
$Script:ModulesDir = Join-Path $Script:ScriptRoot 'modules'
$Script:PayloadDir = Join-Path $Script:ScriptRoot 'payload'
$Script:ScriptsDir = Join-Path $Script:ScriptRoot 'scripts'

# Mark-of-the-Web: files extracted from a downloaded zip carry a
# Zone.Identifier alternate data stream that triggers "is not digitally
# signed" under the default RemoteSigned execution policy. The first launch
# uses claudearium.cmd with -ExecutionPolicy Bypass to get us this far;
# unblock the rest of the install tree so future direct .ps1 invocations
# work too. Write a sentinel afterwards so subsequent launches skip the
# tree walk. The sentinel is deleted by `update apply` so freshly-extracted
# files get unblocked on the next launch.
$Script:MotwSentinel = Join-Path $Script:ScriptRoot '.motw-unblocked'
if (-not (Test-Path -LiteralPath $Script:MotwSentinel -PathType Leaf)) {
    try {
        Get-ChildItem -LiteralPath $Script:ScriptRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $Script:MotwSentinel -Force -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

Import-Module (Join-Path $Script:ModulesDir 'State.psm1')    -Force
Import-Module (Join-Path $Script:ModulesDir 'UI.psm1')       -Force
Import-Module (Join-Path $Script:ModulesDir 'Wsl.psm1')      -Force
Import-Module (Join-Path $Script:ModulesDir 'Profile.psm1')  -Force
Import-Module (Join-Path $Script:ModulesDir 'Users.psm1')    -Force
Import-Module (Join-Path $Script:ModulesDir 'Projects.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Sessions.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Tmux.psm1')     -Force
Import-Module (Join-Path $Script:ModulesDir 'Mounts.psm1')   -Force
Import-Module (Join-Path $Script:ModulesDir 'Tools.psm1')    -Force
Import-Module (Join-Path $Script:ModulesDir 'Vpn.psm1')      -Force
Import-Module (Join-Path $Script:ModulesDir 'HostTools.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'HostShadows.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'ClaudeSettings.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'ClaudeFile.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'ClaudeShared.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'HostToolNotes.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'SelfUpdate.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'ToolUpdates.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Prune.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Temp.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'WinTerminal.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Network.psm1') -Force
Set-VpnPayloadRoot -Path $Script:PayloadDir
Set-NetworkPayloadRoot -Path $Script:PayloadDir

# Snapshot the wt tab title so we can prefix it with '*' when tool updates are
# available (and restore the original when there are none). The .cmd launcher
# sets this via `wt --title` (claudearium.cmd:23); honor CLAUDEARIUM_WT_TITLE
# overrides by capturing whatever is current rather than hardcoding.
$Script:BaseWtTitle = $null
try { $Script:BaseWtTitle = [string]$Host.UI.RawUI.WindowTitle } catch { }

function Show-Help {
    @"
claudearium.ps1 <verb> [<sub-verb>] [<arg>] [options]
claudearium.ps1                   # bare = interactive central dashboard

Verbs:
  setup                    Create and provision the WSL2 sandbox distro.
  status                   Show distro and sandbox state.
  nuke                     Unregister the distro and remove all sandbox state.
  reconcile                Diff profile against state; prompt; apply.
  prune [-Scope <a>]       Drift detection + repair. -Scope sessions|worktrees|
                           mounts|artifacts|all. -DryRun to report only.
  temp                     Print scratch sizes (/tmp, ~/.cache, ~/.claude).
  temp size                Same as bare.
  temp clean -Scope <s>    Wipe a scratch scope. -Scope tmp|cache|claude|all.
                           claude scope keeps todos/plans by default; pass
                           -IncludeTodos / -IncludePlans to wipe those too.

  profile validate <path>  Validate a profile (or the default profile if omitted).
  profile export -Out <p>  Write current state to a profile file at <p>.
  profile edit [<path>]    Open the profile in `$env:EDITOR (or VS Code, then notepad).
  profile show [<path>]    Pretty-print the parsed profile (with env-vars expanded).

  project                  Bare = interactive dashboard.
  project add [<name>]     Add a project to the profile.
                           Default: distroProject — clones a bare mirror into the distro.
                           With -HostProject -HostCheckout C:\path: hostProject — uses
                           the Windows checkout directly, sessions are host-side
                           worktrees mounted into the distro, and -HostShadows
                           wraps host tools (default: pwsh, git) per-project.
                           Smart defaults: -HostCheckout / cwd's git origin URL.
  project list             Table of projects (types + profile + materialization status).
  project remove <name>    Delete every half's state (bare mirror and/or per-project
                           bin dir), sessions, the Linux user, and profile entry.
  project add-distro <name>  Add a distro half (-Remote <url>; auto-detected from an
                           existing hostCheckout when omitted) to an existing project.
  project add-host <name>  Add a host half (-HostCheckout <p> [-HostShadows ...]) to
                           an existing project. Both make the project dual-capability.
  project drop-distro <name> / drop-host <name>
                           Drop one half (its state + sessions), keep the other and the
                           Linux user. Refuses dirty sessions unless -DiscardDirty / -Force.
  project show <name>      Inspect a project's halves (remote / hostCheckout) + status.

  session                  Bare = interactive dashboard.
  session new <name>       Create a worktree. -Project required; -Branch or -NewBranch + -BaseBranch.
  session list             Table of sessions across all projects (filter with -Project).
  session remove <name>    Remove a session's worktree. -Project required; -Force for dirty.

  mount                    Bare = interactive dashboard.
  mount add [<host-path>]  Add a host folder mount via drvfs. -Guest, -Mode (ro|rw),
                           -MountOptions for extras (e.g. 'umask=077' for ~/.ssh).
  mount list               Table of mounts (profile + actual fstab state).
  mount remove <guest>     Drop a mount. Refuses if the mount is busy unless -Force.
  mount sync               Re-apply profile mounts to the distro idempotently.

  tools                    Bare = interactive dashboard.
  tools list               Desired-vs-installed table for catalog tools.
  tools install <name>     Install one tool now; also marks enabled in profile.
  tools attach <name>      Attach the Windows-host copy of an OAuth-pain CLI
                           (gh/glab/acli/seqcli) as a drop-in /usr/local/bin/<name>
                           wrapper — reuses host auth instead of re-logging in WSL.
  tools enable <name>      Mark tool enabled in profile + install if missing.
  tools disable <name>     Mark tool disabled in profile (does NOT uninstall).
  tools sync               Install every enabled-but-missing tool from the profile.

  login                    Bare = list available identity flows.
  login claude             Run 'claude' (first-run triggers OAuth).
  login gh                 'gh auth login'.
  login glab               'glab auth login'.
  login acli-jira          'acli jira auth login' (CLI-token Atlassian auth, Jira).
  login acli-confluence    'acli confluence auth login' (CLI-token Atlassian auth, Confluence).
                           -Project <name> logs in as that project's user (per-project
                           auth isolation); -Project claude targets the shared lobby.

  user                     Bare = list per-project Linux users.
  user list                Table of project -> Linux user / uid / home.
  user password <project>  Print that project user's generated sudo password.
  user seed <from> -To <to> [-Tools gh,claude,...]
                           Copy credential dirs from one project user to another
                           (avoids re-auth). Default: all known tools.
  user shell <project>     Open an interactive shell as that project's user.

  vpn                      Bare = status + interactive menu.
  vpn enable               Install payload (idempotent) and bring wg0 up.
  vpn disable              Bring wg0 down (killswitch stays armed; sandbox is offline).
  vpn reload               Restart killswitch-prep + nftables + wg-quick@wg0.
  vpn status               Print tunnel state, killswitch state, host.internal reachability.
  vpn test                 Quick connectivity probes (host.internal + via-wg).

  network                  Bare = status + interactive menu.
  network repair           Restore distro connectivity when a host VPN broke the
                           WSL NAT DHCP lease (assigns eth0 a static IP + default
                           route). Installs a boot-time auto-repair. -Mtu to clamp.
  network status           Print eth0 address/route/MTU + external reachability.

  host-tools               Bare = interactive dashboard.
  host-tools add [<exe>]   Register a Windows .exe as a guest command via WSL interop.
                           -HostExe / -GuestCommand / -SmokeTest flags.
  host-tools list          Profile + actual wrapper status.
  host-tools remove <cmd>  Drop the wrapper + profile entry.
  host-tools sync          Re-apply profile wrappers to the distro.
  host-tools scan          Detect OAuth-pain catalog CLIs (gh/glab/acli/seqcli) on
                           the Windows host PATH and offer to attach each as a
                           drop-in wrapper.

  hooks test               Run each registered host-tool's smokeTest.

  wt-profiles              Bare = show the generated Windows Terminal profiles
                           (per-project icon / background image / opacity).
  wt-profiles apply        Regenerate the WT profile fragment from the profile.
  wt-profiles clean        Delete the generated WT profile fragment.
                           (Restart Windows Terminal to apply fragment changes.)

  claude-settings show         Print /home/claude/.claude/settings.json.
  claude-settings apply        Apply profile.claudeSettings to the distro.
  claude-settings reconfigure  Interactive wizard, then apply.

  claude-shared            Bare = dashboard for the shared account-level Claude
                           store (CLAUDE.md + skills/ + agents/, shared across
                           all projects, symlinked into each ~/.claude).
  claude-shared show       Summarize the store (sizes, counts, group members).
  claude-shared import     Seed/refresh the store from host ~/.claude (-Force overwrites).
  claude-shared backup     Snapshot the store to %LOCALAPPDATA%\claudearium\backups\<distro>.
  claude-shared restore    Restore the newest snapshot (or -Arg <file>).
  claude-shared apply      Repair the store structure (group + ACLs + symlinks).

  update [check]           Compare local version against the latest GitHub release.
  update apply             Download + install the latest release (preserves user files).
  update status            Show cached version info; no network call.

  diagnostics              Run the read-only diagnostic test lane (troubleshooting).

Common options:
  -Name <distro>           Distro name (default: 'claudearium' or profile.distro.name)
  -Base <id>               Distro base (default: 'debian-12')
  -ProfilePath <path>      Profile JSON file (default: %LOCALAPPDATA%\claudearium\claudearium.profile.json)
  -InstallPath <path>      Where to install (default: %LOCALAPPDATA%\WSL\<Name>)
  -Out <path>              Output path (used by 'profile export')
  -RootfsPath / -RootfsUrl Override rootfs source for setup.
  -Remote <url>            Project remote URL (used by 'project add')
  -DefaultBranch <b>       Project default branch (default: master)
  -HostCheckout <path>     Auto-detect remote/branch from a host git checkout (distroProject),
                           or the working tree for a hostProject when combined with -HostProject.
  -HostProject             Register as a hostProject (sessions live on the host, not the distro).
  -HostShadows <names>     Host tools to wrap for a hostProject (default: pwsh,git).
  -Project <name>          Project name (used by session verbs)
  -Branch <b>              Branch to check out (session new)
  -NewBranch               Create a new branch when starting the session
  -BaseBranch <b>          Base for -NewBranch (default: profile project's defaultBranch)
  -HostPath <path>         Windows path to mount (mount add)
  -Guest <path>            Linux mount point (default: /host/<basename>)
  -Mode <ro|rw>            Mount mode (default: ro)
  -MountOptions <opts>     Extra drvfs options appended after the defaults
  -Mtu <n>                 eth0 MTU for 'network repair' (default: no clamp)
  -NonInteractive          Don't prompt; use defaults / fail if input would be required.
  -Force                   Override safety checks.
  -NoBackup                Skip the shared-store snapshot on 'nuke'.

Examples:
  .\claudearium.ps1 setup
  .\claudearium.ps1 status
  .\claudearium.ps1 reconcile
  .\claudearium.ps1 project add -HostCheckout C:\src
  .\claudearium.ps1 project list
  .\claudearium.ps1 session new feat-1234 -Project acme -Branch feature/PROJ-1234-some-feature -NewBranch -BaseBranch master
  .\claudearium.ps1 session list -Project acme
  .\claudearium.ps1 session remove feat-1234 -Project acme -Force
"@
}

function Resolve-ProfilePath {
    if ($ProfilePath) { return (Resolve-Path -LiteralPath $ProfilePath -ErrorAction SilentlyContinue)?.Path ?? $ProfilePath }
    return (Get-DefaultProfilePath)
}

function Get-Editor {
    # $env:EDITOR (POSIX-style) wins, then VS Code, then notepad.
    if ($env:EDITOR) { return $env:EDITOR }
    $code = Get-Command code -ErrorAction SilentlyContinue
    if ($code) { return $code.Source }
    $codeCmd = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($codeCmd) { return $codeCmd.Source }
    $np = Get-Command notepad.exe -ErrorAction SilentlyContinue
    if ($np) { return $np.Source }
    throw 'No editor found. Set $env:EDITOR or install VS Code (`code` on PATH).'
}

function Read-ProfileIfPresent {
    # Returns parsed+validated profile hashtable, or $null if no profile / invalid.
    # Prints warnings; throws on validation errors.
    $path = Resolve-ProfilePath
    if (-not (Test-Path $path)) { return $null }
    $spec = Read-Profile -Path $path
    $v = Test-Profile -Spec $spec
    foreach ($w in $v.Warnings) { Write-Host "  profile warn: $w" -ForegroundColor DarkYellow }
    if (-not $v.IsValid) {
        Write-Host "  Profile $path is invalid:" -ForegroundColor Red
        foreach ($e in $v.Errors) { Write-Host "    error: $e" -ForegroundColor Red }
        throw "Profile validation failed at $path"
    }
    return $spec
}

function Resolve-InstallPath {
    if ($InstallPath) { return $InstallPath }
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set.' }
    return (Join-Path $env:LOCALAPPDATA (Join-Path 'WSL' $Name))
}

function Get-PayloadFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $p = Join-Path $Script:PayloadDir $RelativePath
    if (-not (Test-Path $p)) { throw "Payload file missing: $p" }
    return $p
}

function Get-ScriptFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $p = Join-Path $Script:ScriptsDir $RelativePath
    if (-not (Test-Path $p)) { throw "Script file missing: $p" }
    return $p
}

function Send-FileToDistro {
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath,
        [string]$Mode = '0644'
    )
    # Transport via base64 in the command-line arg, not stdin. PowerShell's pipe to
    # native commands re-inserts CRLF on Windows even after we LF-normalize the
    # content — base64 is pure ASCII and survives that round-trip intact, and we
    # also strip CR on the bash side as a belt-and-braces guard for shell scripts.
    $bytes  = [IO.File]::ReadAllBytes($SourcePath)
    # Some text editors / git autocrlf leave CRLF in payload files; normalize on the
    # source side so the rest of the pipeline can stay binary-safe.
    if ($DestPath -like '*.sh' -or $DestPath -like '/etc/wsl.conf' -or $DestPath -like '/etc/*.conf') {
        $text  = [Text.Encoding]::UTF8.GetString($bytes)
        $text  = $text -replace "`r`n", "`n" -replace "`r", "`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    }
    $b64    = [Convert]::ToBase64String($bytes)
    $parent = (Split-Path -Parent $DestPath) -replace '\\','/'
    $cmd    = "set -e; mkdir -p '$parent'; printf '%s' '$b64' | base64 -d > '$DestPath'; chmod $Mode '$DestPath'"
    Invoke-InDistro -Name $DistroName -User 'root' -Command $cmd
}

function Invoke-Setup {
    # If a profile exists and the user didn't explicitly override on the CLI,
    # take distro.name / distro.installPath from it.
    $spec = Read-ProfileIfPresent
    if ($spec) {
        if (-not $Script:RootBoundParams.ContainsKey('Name'))        { $script:Name        = [string]$spec.distro.name }
        if (-not $Script:RootBoundParams.ContainsKey('InstallPath')) { $script:InstallPath = [string]$spec.distro.installPath }
        Write-Host "  Profile in use: $(Resolve-ProfilePath)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "=== Claudearium: setup '$Name' ===" -ForegroundColor Cyan

    $distroExists = Test-DistroExists -Name $Name
    $stateExists  = Test-State        -DistroName $Name

    if (($distroExists -or $stateExists) -and -not $Force) {
        Write-Host "  Distro '$Name' or its state already exists." -ForegroundColor Yellow
        Write-Host "  Re-run with -Force to wipe and re-setup, or pick a different -Name." -ForegroundColor Yellow
        return
    }
    if ($Force -and ($distroExists -or $stateExists)) {
        Write-Host "  -Force: removing existing distro and state for '$Name'."
        if ($distroExists) { Unregister-Distro -Name $Name }
        if ($stateExists)  { Remove-State -DistroName $Name }
    }

    $installDir = Resolve-InstallPath
    Write-Host "  Install path: $installDir"

    # Resolve rootfs
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) "claudearium-setup-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # .NET API (literal + idempotent); wsl2-gotchas #19.
    [void][System.IO.Directory]::CreateDirectory($tempDir)
    try {
        if ($RootfsPath) {
            # -LiteralPath on both Test-Path and Resolve-Path so a user-supplied
            # rootfs path containing wildcard glyphs ([, ], *) isn't expanded
            # by the provider; wsl2-gotchas #19.
            if (-not (Test-Path -LiteralPath $RootfsPath -PathType Leaf)) { throw "RootfsPath does not exist: $RootfsPath" }
            $srcRootfs = (Resolve-Path -LiteralPath $RootfsPath).Path
            Write-Host "  Using local rootfs: $srcRootfs"
        }
        else {
            $url = $RootfsUrl
            if (-not $url) {
                Write-Host "  Resolving latest Debian 12 rootfs from images.linuxcontainers.org..."
                $url = Resolve-LatestDebianRootfsUrl
            }
            $srcRootfs = Join-Path $tempDir 'rootfs.tar.xz'
            Save-Rootfs -Url $url -DestPath $srcRootfs
        }

        # WSL --import wants plain .tar; convert if compressed.
        $plainTar = Join-Path $tempDir 'rootfs.tar'
        Convert-RootfsToTar -SourcePath $srcRootfs -DestPath $plainTar

        Write-Host "  Importing distro (this can take a minute)..."
        Import-Distro -Name $Name -RootfsPath $plainTar -InstallPath $installDir

        Write-Host "  Pushing /etc/wsl.conf and bootstrap script..."
        Send-FileToDistro -DistroName $Name -SourcePath (Get-PayloadFile 'etc/wsl.conf')   -DestPath '/etc/wsl.conf'   -Mode '0644'
        Send-FileToDistro -DistroName $Name -SourcePath (Get-ScriptFile  'bootstrap-distro.sh') -DestPath '/root/bootstrap.sh' -Mode '0755'

        Write-Host "  Running bootstrap inside the distro (apt-get update + base packages)..."
        & wsl.exe -d $Name -u root -- bash -lc '/root/bootstrap.sh'
        if ($LASTEXITCODE -ne 0) { throw "bootstrap-distro.sh failed (exit $LASTEXITCODE)" }

        Write-Host "  Terminating distro to apply wsl.conf (default user = claude)..."
        Stop-Distro -Name $Name

        Write-Host "  Verifying default user..."
        $whoami = (& wsl.exe -d $Name -- whoami).Trim()
        if ($whoami -ne 'claude') {
            throw "Expected default user 'claude', got '$whoami'."
        }

        $state = Initialize-State -DistroName $Name
        $state.installPath = $installDir
        $state.provisioned = $true
        # If we consumed a profile, remember it for next time.
        $profPath = Resolve-ProfilePath
        if (Test-Path $profPath) { Add-Recent -State $state -Key 'profilePaths' -Value $profPath }
        Write-State -DistroName $Name -State $state

        # Shared account-level Claude store (CLAUDE.md + skills/ + agents/): the
        # store is a Windows host folder mounted into the distro, so it survives
        # nuke. Order matters: create the host folder + migrate any pre-mount ext4
        # content out FIRST, then apply the fstab mount (now carries the store
        # mount), then ensure the structure + symlinks, then seed/restore content.
        try {
            Invoke-ClaudeSharedHostMigration -DistroName $Name
            Set-HostMountsInDistro -DistroName $Name -Mounts (Get-MergedDesiredMounts -ProfileSpec $spec -State $state)
            Initialize-ClaudeSharedAllUsers -DistroName $Name
            Invoke-ClaudeSharedSeedOrRestore -DistroName $Name -Spec $spec
        }
        catch { Write-Host "  Shared Claude store setup step failed: $($_.Exception.Message)" -ForegroundColor Yellow }

        # Host-VPN connectivity repair (opt-in via profile.network.enabled). Installs
        # a boot-time eth0 net-repair so the distro has connectivity even when a host
        # VPN broke the NAT DHCP lease. No-op when disabled. Non-fatal on failure.
        $netCfg = Get-EffectiveNetworkConfig -Spec $spec
        if ($netCfg.Enabled) {
            try {
                Install-NetRepairPayload -DistroName $Name -Config @{ Mtu = $netCfg.Mtu; HostOffset = $netCfg.HostOffset }
                Write-Host "  Installed eth0 net-repair (host-VPN connectivity)." -ForegroundColor DarkGray
            }
            catch { Write-Host "  Net-repair install failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }

        # Offer to attach OAuth-pain catalog tools (gh/glab/acli/seqcli) from
        # the Windows host if they're detected on PATH. Saves the in-WSL re-auth
        # dance. Skip in NonInteractive — the user can always run
        # 'host-tools scan' later.
        if (-not $NonInteractive) {
            try { Invoke-HostToolsScan }
            catch { Write-Host "  Host-tools scan failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }

        Write-Host ""
        Write-Host "Setup complete. State: $(Get-StatePath -DistroName $Name)" -ForegroundColor Green
        Write-Host "Open a shell:   wsl -d $Name" -ForegroundColor Green
    }
    finally {
        if (Test-Path $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Status {
    Write-Host ""
    Write-Host "=== Claudearium: status '$Name' ===" -ForegroundColor Cyan

    $distroState = Get-DistroState -Name $Name
    $stateExists = Test-State -DistroName $Name
    $state       = if ($stateExists) { Read-State -DistroName $Name } else { $null }

    Write-Host ("  Distro:         {0}" -f $Name)
    Write-Host ("  WSL state:      {0}" -f $distroState)
    Write-Host ("  State file:     {0}" -f (Get-StatePath -DistroName $Name))
    Write-Host ("  State present:  {0}" -f $stateExists)
    if ($state) {
        Write-Host ("  Provisioned:    {0}" -f $state.provisioned)
        Write-Host ("  Install path:   {0}" -f ($state.installPath ?? '(unknown)'))
        Write-Host ("  Created at:     {0}" -f $state.createdAt)
        Write-Host ("  Updated at:     {0}" -f $state.updatedAt)
    }
    Write-Host ""
}

function Invoke-Nuke {
    Write-Host ""
    Write-Host "=== Claudearium: nuke '$Name' ===" -ForegroundColor Cyan

    $distroExists = Test-DistroExists -Name $Name
    $stateExists  = Test-State        -DistroName $Name
    $state        = if ($stateExists) { Read-State -DistroName $Name } else { $null }

    if (-not $distroExists -and -not $stateExists) {
        Write-Host "  Nothing to nuke." -ForegroundColor Yellow
        return
    }

    if (-not $Force) {
        $ok = Read-YesNo -Prompt "  Unregister distro '$Name' and delete all sandbox state?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host "  Aborted." -ForegroundColor Yellow; return }
    }

    # The shared account-level Claude store is a host-mounted folder, so it
    # survives this nuke inherently (it lives outside the per-distro state dir).
    # We still offer an optional point-in-time snapshot before wiping the distro,
    # but it's OFF by default now (claudeShared.backup.onNuke). Best-effort; never
    # blocks the nuke. The backup dir is a sibling of the state dir, so the
    # Remove-State below leaves it.
    if ($distroExists) {
        Backup-ClaudeSharedOnNuke -DistroName $Name -Spec (Read-ProfileIfPresent)
    }

    if ($distroExists) {
        Write-Host "  Unregistering distro..."
        Unregister-Distro -Name $Name
    }
    if ($state -and $state.installPath -and (Test-Path $state.installPath)) {
        Write-Host "  Removing install dir: $($state.installPath)"
        Remove-Item -LiteralPath $state.installPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($stateExists) {
        Write-Host "  Removing state..."
        Remove-State -DistroName $Name
    }
    Write-Host "Nuked." -ForegroundColor Green
}

function Resolve-ProjectUserHome {
    # Resolve a project's Linux user + home from state. With -Create, allocates a
    # fresh per-project user record (name + uid + password) when none exists yet.
    # Without a record and without -Create, falls back to the legacy single
    # 'claude' / '/home/claude' so pre-isolation distros keep working unchanged.
    # Returns @{ User; Home; Uid; Gid; Record } — Record is $null in the fallback.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Project,
        [string]$DistroName,
        [switch]$Create
    )
    $rec = Get-ProjectUser -State $State -Project $Project
    if (-not $rec -and $Create) {
        $rec = New-ProjectUserRecord -State $State -Project $Project -DistroName $DistroName
    }
    if ($rec) {
        return @{ User = [string]$rec.user; Home = [string]$rec.home; Uid = [int]$rec.uid; Gid = [int]$rec.gid; Record = $rec }
    }
    return @{ User = 'claude'; Home = '/home/claude'; Uid = 1000; Gid = 1000; Record = $null }
}

function Get-SessionUserHomes {
    # Every home that hosts Claude Code config: the lobby 'claude' plus each
    # provisioned project user. Global claudeSettings / claudeFile / host-tool
    # notes are fanned out across all of these so an edit reaches the agent that
    # actually runs as the project user.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $homes = @(@{ User = 'claude'; Home = '/home/claude' })
    foreach ($rec in (Get-AllProjectUsers -State $State).Values) {
        if ($rec -is [hashtable] -and $rec.ContainsKey('user')) {
            $homes += @{ User = [string]$rec.user; Home = [string]$rec.home }
        }
    }
    return ,$homes
}

function Get-StateForDistro {
    # Read state if present, else a fresh shape — used by the fan-out wrappers.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    if (Test-State -DistroName $DistroName) { return (Read-State -DistroName $DistroName) }
    return (Initialize-State -DistroName $DistroName)
}

function Get-ScratchHomes {
    # The home set that scratch (cache + claude) lives in: the lobby plus every
    # provisioned project user. Temp's Get-ScratchSizes / Clear-Scratch take this
    # via -Homes so `temp size` / `temp clean` cover per-project-user scratch, not
    # just /home/claude.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    # Unary comma so a single-home (lobby-only) result survives the return as a
    # 1-element array rather than unwrapping to a bare string — otherwise
    # $homes.Count / $homes[0] in Invoke-TempSize break under StrictMode.
    $homes = @((Get-SessionUserHomes -State (Get-StateForDistro -DistroName $DistroName)) |
        ForEach-Object { $_.Home })
    return ,$homes
}

function Install-ClaudeSettingsAllUsers {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName, [Parameter(Mandatory)][hashtable]$Spec)
    foreach ($h in (Get-SessionUserHomes -State (Get-StateForDistro -DistroName $DistroName))) {
        Install-ClaudeSettings -DistroName $DistroName -Spec $Spec -User $h.User -Home $h.Home
    }
}

function Initialize-ClaudeSharedHostDir {
    # Ensure the global host folder backing the shared store exists, with its
    # subdirs. The store is a drvfs mount of this folder; 'mount -a' fails the
    # whole fstab table if the source dir is missing, so this MUST run before the
    # store mount is applied. Returns the host folder path.
    [CmdletBinding()] param()
    $hostDir = Get-ClaudeSharedHostPath
    foreach ($sub in @('', 'skills', 'agents', 'host-tools')) {
        $p = if ($sub) { Join-Path $hostDir $sub } else { $hostDir }
        [void][System.IO.Directory]::CreateDirectory($p)
    }
    return $hostDir
}

function Invoke-ClaudeSharedHostMigration {
    # One-time migration of a pre-existing in-distro (ext4) store at the guest
    # mountpoint into the global host folder, BEFORE the store mount is applied —
    # mounting over the path would hide (shadow) the ext4 content, so the copy
    # must happen first. Marker-gated by '<hostDir>\.claudearium-migrated': once
    # set, every later run skips. This is correct for the global store — the first
    # distro migrates its content out; subsequent distros see a populated folder
    # and skip. Best-effort; never blocks setup/reconcile.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $hostDir = Initialize-ClaudeSharedHostDir
    $marker  = Join-Path $hostDir '.claudearium-migrated'
    if (Test-Path -LiteralPath $marker) { return }
    try {
        $store  = Get-ClaudeSharedStorePath
        $qStore = ConvertTo-BashQuoted $store
        # Migrate only if the path exists, is NOT already a mountpoint, and has
        # content. A mountpoint means we'd be reading the host copy, not ext4.
        $probe = @"
set -uo pipefail
STORE=$qStore
if mountpoint -q "`$STORE" 2>/dev/null || grep -q " `$STORE " /proc/mounts; then
    echo MOUNTED
elif [ -d "`$STORE" ] && [ -n "`$(ls -A "`$STORE" 2>/dev/null)" ]; then
    echo CONTENT
else
    echo EMPTY
fi
"@
        $r = Invoke-InDistroScript -Name $DistroName -Script $probe -User 'root' -AllowFail -CaptureOutput
        $verdict = (@($r.Output | ForEach-Object { [string]$_ }) | Where-Object { $_ }) -join ''
        if ($verdict -match 'CONTENT') {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("claudearium-shared-migrate-{0}.tar.gz" -f ([Guid]::NewGuid().ToString('N')))
            try {
                if (Receive-TreeFromDistro -DistroName $DistroName -SourceDir $store -DestArchivePath $tmp) {
                    Expand-TarGzToHostDir -ArchivePath $tmp -DestDir $hostDir
                    Write-Host "  Migrated in-distro Claude store -> $hostDir" -ForegroundColor Green
                }
            }
            finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    catch { Write-Host "  Shared-store host migration skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
    # Mark done regardless: a fresh/empty distro has nothing to migrate, and we
    # don't want to re-probe the distro on every setup/reconcile.
    Set-Content -LiteralPath $marker -Value 'migrated' -NoNewline
}

function Initialize-ClaudeSharedAllUsers {
    # Structural ensure for the shared account-level Claude store: ensure the
    # store subdirs exist (on the mounted host folder), then symlink every session
    # user's ~/.claude/{CLAUDE.md,skills,agents,host-tools} into it. Idempotent;
    # safe to re-run. Does NOT touch store *content* (that's import/seed only), so
    # it never clobbers in-distro edits. Assumes the store mount is already up —
    # callers run Initialize-ClaudeSharedHostMount before this.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    Initialize-ClaudeSharedStore -DistroName $DistroName
    foreach ($h in (Get-SessionUserHomes -State (Get-StateForDistro -DistroName $DistroName))) {
        Set-ClaudeSharedSymlinks -DistroName $DistroName -User $h.User -Home $h.Home
    }
    # Write/refresh the curation-main / worktree-discipline managed block in the
    # store CLAUDE.md (once — every user symlinks to it). A tool-owned managed
    # block, like the host-tool notes; it never touches content outside markers.
    Install-WorktreeDisciplineNote -DistroName $DistroName
}

function Import-ClaudeSharedSeed {
    # Ensure the store structure, then seed/refresh its content from the host
    # (CLAUDE.md + skills/ + agents/). Used at setup and by `claude-shared import`.
    # -Force overwrites in-distro content; default is non-destructive.
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()][hashtable]$Spec,        # the profile spec (any block shape)
        [switch]$Force
    )
    Initialize-ClaudeSharedAllUsers -DistroName $DistroName
    $effective = Get-EffectiveClaudeShared -Spec $Spec
    if ($effective) {
        Import-ClaudeSharedFromHost -DistroName $DistroName -Spec $effective -Force:$Force
    }
    # Re-link after import so a freshly-created store CLAUDE.md resolves through
    # the symlinks (no-op when links already point at it).
    foreach ($h in (Get-SessionUserHomes -State (Get-StateForDistro -DistroName $DistroName))) {
        Set-ClaudeSharedSymlinks -DistroName $DistroName -User $h.User -Home $h.Home
    }
}

function Install-HostToolNotesAllUsers {
    # Host-tool notes (per-tool .md files + the managed CLAUDE.md block) now live
    # in the shared store and are symlinked into every user's ~/.claude, so they
    # are written ONCE rather than fanned per user. The store is a drvfs-mounted
    # host folder, so owner/mode are moot (the mount umask governs); we pass
    # root:root for tidiness. (Name kept for the call sites that re-sync after a
    # hostTools / CLAUDE.md change.)
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName, [AllowNull()]$Spec)
    Install-HostToolNotes -DistroName $DistroName -Spec $Spec `
        -Root (Get-ClaudeSharedStorePath) -Owner 'root:root' -FileMode '0664'
}

function Initialize-ProjectUserClaudeConfig {
    # Seed a freshly-provisioned project user's ~/.claude from the profile so the
    # agent running as that user gets the same settings / CLAUDE.md / host-tool
    # notes as everyone else. No-op fields are skipped.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Home,
        [AllowNull()][hashtable]$Spec
    )
    # settings.json stays PER-USER (synthesized, not shared). Everything else —
    # CLAUDE.md + skills/ + agents/ + host-tool notes — lives in the shared store
    # and reaches this user via symlinks, so we just link.
    if ($Spec -and $Spec.ContainsKey('claudeSettings') -and $Spec.claudeSettings) {
        Install-ClaudeSettings -DistroName $DistroName -Spec $Spec.claudeSettings -User $User -Home $Home
    }
    # Defensive: ensure the store subdirs exist (setup establishes the mount; this
    # covers an odd state where a user is added before the store was provisioned).
    Initialize-ClaudeSharedStore -DistroName $DistroName
    Set-ClaudeSharedSymlinks -DistroName $DistroName -User $User -Home $Home
}

function Invoke-ProjectsApply {
    # Apply a projects-block diff against a running distro. Mutates $State in
    # place. The diff is PER HALF (Get-ProjectsDiff): each change carries Name +
    # Half so we route precisely — a distro half gets a bare-mirror clone, a host
    # half gets a shadow-bin-dir + init.sh deployment. A dual-capability project
    # may therefore see two 'add' (or two 'remove') changes in one reconcile.
    #
    # Each project owns ONE dedicated Linux user shared by both halves
    # (per-project isolation): on the first half's 'add' the user is allocated +
    # provisioned (idempotent for the second half); the mirror lives under
    # <home>/mirrors and the host bin dir under <home>/host-projects, so they
    # coexist. The user is deleted only after the WHOLE project is gone — see the
    # post-loop pass — so dropping one half of a dual project keeps the user.
    #
    # `remove` actions cover three cases: the entry was deleted from the profile
    # (drift, $desired null); the entry is disabled ($desired carries the spec,
    # used for a tidy host `git worktree remove`); or a single half was dropped
    # while the other stays enabled.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Diff,
        [AllowNull()][object[]]$DesiredProjects
    )
    $hostTeardownHappened = $false
    # name -> resolved user/home record, for projects that lost a half. The
    # post-loop pass decides per project whether to userdel (whole project gone)
    # or keep the user (the other half is still enabled).
    $removedFromProjects = @{}

    foreach ($c in $Diff.Changes) {
        $projectName = if ($c.ContainsKey('Name') -and $c.Name) { [string]$c.Name }
                       else { ($c.Path -replace '^projects\.', '') -replace '\.(remote|distro|host)$', '' }
        $half = if ($c.ContainsKey('Half') -and $c.Half) { [string]$c.Half } else { 'distro' }
        $desired = $null
        if ($DesiredProjects) {
            $desired = @(@($DesiredProjects) | Where-Object { [string]$_.name -eq $projectName })[0]
        }

        switch ($c.Action) {
            'add' {
                if (-not $desired) { continue }
                # Allocate + provision the project's dedicated Linux user, then
                # persist state before the (slow, failure-prone) clone so a retry
                # reuses the same uid/home. Idempotent for the second half:
                # Resolve returns the existing record and New-ProjectUserInDistro
                # no-ops when the user already exists.
                $r = Resolve-ProjectUserHome -State $State -Project $projectName -DistroName $DistroName -Create
                if ($r.Record) {
                    Write-Host "  provisioning user '$($r.User)' (uid $($r.Uid)) for '$projectName' ..."
                    New-ProjectUserInDistro -DistroName $DistroName -User $r.User -Uid $r.Uid -Password ([string]$r.Record.password)
                    Write-State -DistroName $DistroName -State $State
                }
                if ($half -eq 'host') {
                    # Host half: deploy the per-project bin dir + init.sh. No
                    # mirror clone; the host checkout is the source.
                    Write-Host "  registering host half of '$projectName' ..."
                    Invoke-HostProjectApply -DistroName $DistroName -ProjectSpec $desired -User $r.User -Home $r.Home
                    Add-Recent -State $State -Key 'projectNames' -Value $projectName
                } else {
                    Write-Host "  cloning distro half of '$projectName' ..."
                    New-ProjectMirror -DistroName $DistroName -ProjectName $projectName -Remote ([string]$desired.remote) -User $r.User -Home $r.Home
                    $db = if ($desired.ContainsKey('defaultBranch') -and $desired.defaultBranch) { [string]$desired.defaultBranch } else { 'master' }
                    Write-Host "  creating main/ checkout on '$db' ..."
                    New-ProjectMainCheckout -DistroName $DistroName -ProjectName $projectName -Branch $db -User $r.User -Home $r.Home
                    Add-Recent -State $State -Key 'projectNames' -Value $projectName
                    Add-Recent -State $State -Key 'remotes'      -Value ([string]$desired.remote)
                }
                # Seed the new user's ~/.claude (settings + CLAUDE.md + host-tool
                # notes) so the agent running as it gets the same config.
                if ($r.Record) {
                    Initialize-ProjectUserClaudeConfig -DistroName $DistroName -User $r.User -Home $r.Home -Spec (Read-ProfileIfPresent)
                }
            }
            'remove' {
                # Resolve the existing user/home (no -Create). User deletion is
                # deferred to the post-loop pass.
                $r = Resolve-ProjectUserHome -State $State -Project $projectName
                if ($half -eq 'host') {
                    Write-Host "  removing host half of '$projectName' (bin dir + host sessions, hostCheckout untouched) ..."
                    # Disable case ($desired present) → tidy per-session worktree
                    # removal first so Windows-side worktrees aren't orphaned.
                    if ($desired) {
                        $sessionNames = @()
                        foreach ($s in (Get-Sessions -State $State -Project $projectName)) {
                            if ($s -is [hashtable] -and $s.ContainsKey('name') -and (Get-SessionType -Session $s) -eq 'host') {
                                $sessionNames += [string]$s.name
                            }
                        }
                        foreach ($sname in $sessionNames) {
                            try {
                                Remove-HostSession -State $State -ProjectSpec $desired -Name $sname -Force
                            } catch {
                                Write-Host "    warn: could not remove session '$sname': $_" -ForegroundColor Yellow
                            }
                        }
                    }
                    Remove-HostShadowsForProject -DistroName $DistroName -ProjectName $projectName -User $r.User -Home $r.Home
                    Remove-SessionsForProject     -State $State -Project $projectName -Type host
                    $hostTeardownHappened = $true
                } else {
                    Write-Host "  removing distro half of '$projectName' (mirror + distro sessions) ..."
                    Remove-ProjectMirror      -DistroName $DistroName -ProjectName $projectName -User $r.User -Home $r.Home
                    Remove-SessionsForProject -State $State -Project $projectName -Type distro
                }
                if (-not $removedFromProjects.ContainsKey($projectName)) { $removedFromProjects[$projectName] = $r }
            }
            'modify' {
                Write-Host "  '$($c.Path)' changed: do 'project remove $projectName' then 'project add'." -ForegroundColor Yellow
            }
        }
    }

    # Delete the Linux user only for projects that lost a half AND retain no
    # enabled desired half (whole project removed or disabled). A single-half
    # drop on a still-enabled project keeps the user — the surviving half and its
    # sessions live in the same home.
    foreach ($projectName in $removedFromProjects.Keys) {
        $stillDesired = $false
        if ($DesiredProjects) {
            foreach ($p in @($DesiredProjects)) {
                if ([string]$p.name -ne $projectName) { continue }
                if (-not (Test-ProjectEnabled -Entry $p)) { continue }
                $h = Get-ProjectHalves -ProjectSpec $p
                if ($h.Distro -or $h.Host) { $stillDesired = $true }
            }
        }
        if ($stillDesired) { continue }
        $r = $removedFromProjects[$projectName]
        if ($r.Record) {
            Write-Host "  deleting project user '$($r.User)' ..."
            [void](Remove-ProjectUserInDistro -DistroName $DistroName -User $r.User)
            [void](Remove-ProjectUserRecord -State $State -Project $projectName)
            $hostTeardownHappened = $true
        }
    }

    # Refresh the fstab managed block when a host teardown happened. Persist
    # state first so Invoke-MergedMountsApply's Read-State sees the just-
    # cleared sessions and removes their mount entries.
    if ($hostTeardownHappened) {
        Write-State -DistroName $DistroName -State $State
        Invoke-MergedMountsApply -DistroName $DistroName
    }
}

function Set-ClaudeSettingsInProfile {
    # Insert/replace the claudeSettings block on disk, env-token-preserving.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][hashtable]$Spec
    )
    $p = if (Test-Path $ProfilePath) { Read-Profile -Path $ProfilePath -Raw } else {
        @{
            schemaVersion = 1
            distro        = @{ name = 'claudearium'; base = 'debian-12'; installPath = '%LOCALAPPDATA%\WSL\claudearium' }
        }
    }
    $p['claudeSettings'] = $Spec
    Write-Profile -Path $ProfilePath -Spec $p
}

function Invoke-ClaudeSettingsApply {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' missing." }
    $spec = Read-ProfileIfPresent
    if (-not $spec -or -not $spec.ContainsKey('claudeSettings') -or -not $spec.claudeSettings) {
        Write-Host "  No claudeSettings in profile. Run 'claude-settings reconfigure' first." -ForegroundColor Yellow
        return
    }
    Write-Host '  Installing ~/.claude/settings.json across all project users ...'
    Install-ClaudeSettingsAllUsers -DistroName $distro -Spec $spec.claudeSettings
    Write-Host 'Claude Code settings applied.' -ForegroundColor Green
}

function Invoke-ClaudeSettingsShow {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { Write-Host "Distro '$distro' missing." -ForegroundColor Yellow; return }
    Invoke-InDistro -Name $distro -User 'claude' -Command 'cat /home/claude/.claude/settings.json 2>/dev/null || echo "(no settings.json)"'
}

function Invoke-ClaudeSettingsReconfigure {
    $distro = Resolve-DistroForOps

    # Pre-populate from existing claudeSettings if present.
    $current = @{}
    $existing = $null
    try {
        $spec = Read-ProfileIfPresent
        if ($spec -and $spec.ContainsKey('claudeSettings') -and $spec.claudeSettings) { $existing = $spec.claudeSettings }
    } catch { }
    if ($existing) { foreach ($k in $existing.Keys) { $current[$k] = $existing[$k] } }

    Write-Host ''
    Write-Host '=== Claude Code settings wizard ===' -ForegroundColor Cyan

    # 1. Model
    $modelChoices = @('claude-opus-4-8', 'claude-sonnet-4-6', 'claude-haiku-4-5')
    $defModelIdx  = if ($current.ContainsKey('model') -and ($modelChoices -contains [string]$current.model)) {
        [Array]::IndexOf($modelChoices, [string]$current.model)
    } else { 0 }
    $model = Read-Choice -Prompt 'Default model:' -Options $modelChoices -DefaultIndex $defModelIdx -NonInteractive:$NonInteractive
    $current.model = $model

    # 2. Effort
    $effortChoices = @('low','medium','high','xhigh')
    $defEffortIdx  = if ($current.ContainsKey('defaultEffort') -and ($effortChoices -contains [string]$current.defaultEffort)) {
        [Array]::IndexOf($effortChoices, [string]$current.defaultEffort)
    } else { 3 } # 'xhigh' default for sandbox use
    $effort = Read-Choice -Prompt 'Default thinking effort (xhigh recommended for sandbox use):' -Options $effortChoices -DefaultIndex $defEffortIdx -NonInteractive:$NonInteractive
    $current.defaultEffort = $effort

    # 3. Theme
    $themeChoices = @('dark','light','system')
    $defThemeIdx  = if ($current.ContainsKey('theme') -and ($themeChoices -contains [string]$current.theme)) {
        [Array]::IndexOf($themeChoices, [string]$current.theme)
    } else { 0 }
    $current.theme = Read-Choice -Prompt 'Theme:' -Options $themeChoices -DefaultIndex $defThemeIdx -NonInteractive:$NonInteractive

    # 4-6. Auto-approve buckets
    $current.autoApproveReadOnlyBash = Read-YesNo -Prompt 'Auto-approve read-only Bash (git status, ls, cat, gh, glab, acli, ...)?' -Default ($(if ($current.ContainsKey('autoApproveReadOnlyBash')) { [bool]$current.autoApproveReadOnlyBash } else { $true })) -NonInteractive:$NonInteractive
    $current.autoApproveProjectWrites = Read-YesNo -Prompt 'Auto-approve project-scoped writes (Edit/Write/Glob/Grep)?' -Default ($(if ($current.ContainsKey('autoApproveProjectWrites')) { [bool]$current.autoApproveProjectWrites } else { $true })) -NonInteractive:$NonInteractive
    $current.autoApproveBuildCommands = Read-YesNo -Prompt 'Auto-approve build commands (dotnet build/test, npm install, ...)?' -Default ($(if ($current.ContainsKey('autoApproveBuildCommands')) { [bool]$current.autoApproveBuildCommands } else { $false })) -NonInteractive:$NonInteractive

    # 7. Claudelk
    $hasClaudelk = $false
    try {
        $spec = Read-ProfileIfPresent
        if ($spec -and $spec.ContainsKey('hostTools')) {
            $hasClaudelk = [bool](@($spec.hostTools) | Where-Object { [string]$_.guestCommand -eq 'sb-claudelk' })
        }
    } catch { }
    $claudelkDefault = if ($current.ContainsKey('claudelk')) { [bool]$current.claudelk } else { $hasClaudelk }
    $current.claudelk = Read-YesNo -Prompt 'Wire Claudelk LED hooks?' -Default $claudelkDefault -NonInteractive:$NonInteractive
    if ($current.claudelk) {
        $eventOptions = @(
            @{ Name = 'Stop';         Selected = $true;  Hint = 'session ends' }
            @{ Name = 'Notification'; Selected = $true;  Hint = 'attention needed' }
            @{ Name = 'PreToolUse';   Selected = $false; Hint = 'on every tool call (very noisy)' }
            @{ Name = 'SessionStart'; Selected = $false; Hint = 'on session start' }
        )
        # Pre-set selection from current.claudelkEvents
        if ($current.ContainsKey('claudelkEvents') -and $current.claudelkEvents) {
            $existingEvents = @($current.claudelkEvents | ForEach-Object { [string]$_ })
            foreach ($o in $eventOptions) { $o.Selected = ($existingEvents -contains $o.Name) }
        }
        $picked = Read-Multi -Prompt 'Which Claudelk events?' -Options $eventOptions -NonInteractive:$NonInteractive
        $current.claudelkEvents = @($picked)
    }

    # 8. Extended thinking on by default
    $current.alwaysThinkingEnabled = Read-YesNo -Prompt 'Always-on extended thinking (recommended with xhigh effort)?' -Default ($(if ($current.ContainsKey('alwaysThinkingEnabled')) { [bool]$current.alwaysThinkingEnabled } else { $true })) -NonInteractive:$NonInteractive

    # 9. Auto-updates channel
    $channelChoices = @('stable','latest')
    $defChannelIdx  = if ($current.ContainsKey('autoUpdatesChannel') -and ($channelChoices -contains [string]$current.autoUpdatesChannel)) {
        [Array]::IndexOf($channelChoices, [string]$current.autoUpdatesChannel)
    } else { 0 }
    $current.autoUpdatesChannel = Read-Choice -Prompt 'Claude Code release channel:' -Options $channelChoices -DefaultIndex $defChannelIdx -NonInteractive:$NonInteractive

    # 10. Bypass-permissions mode (--dangerously-skip-permissions)
    $current.disableBypassPermissionsMode = Read-YesNo -Prompt 'Forbid --dangerously-skip-permissions (recommended for sandbox)?' -Default ($(if ($current.ContainsKey('disableBypassPermissionsMode')) { [bool]$current.disableBypassPermissionsMode } else { $true })) -NonInteractive:$NonInteractive

    # 10b. Dynamic workflows
    $current.disableWorkflows = Read-YesNo -Prompt 'Disable dynamic workflows (recommended for sandbox)?' -Default ($(if ($current.ContainsKey('disableWorkflows')) { [bool]$current.disableWorkflows } else { $true })) -NonInteractive:$NonInteractive

    # 11. TUI renderer
    $tuiChoices = @('fullscreen','default')
    $defTuiIdx  = if ($current.ContainsKey('tui') -and ($tuiChoices -contains [string]$current.tui)) {
        [Array]::IndexOf($tuiChoices, [string]$current.tui)
    } else { 0 }
    $current.tui = Read-Choice -Prompt 'Terminal renderer:' -Options $tuiChoices -DefaultIndex $defTuiIdx -NonInteractive:$NonInteractive

    # 12. Default shell
    $shellChoices = @('bash','powershell')
    $defShellIdx  = if ($current.ContainsKey('defaultShell') -and ($shellChoices -contains [string]$current.defaultShell)) {
        [Array]::IndexOf($shellChoices, [string]$current.defaultShell)
    } else { 0 }
    $current.defaultShell = Read-Choice -Prompt 'Default shell for Claude Bash invocations:' -Options $shellChoices -DefaultIndex $defShellIdx -NonInteractive:$NonInteractive

    # 13. Editor mode (input-prompt key bindings)
    $editorChoices = @('normal','vim')
    $defEditorIdx  = if ($current.ContainsKey('editorMode') -and ($editorChoices -contains [string]$current.editorMode)) {
        [Array]::IndexOf($editorChoices, [string]$current.editorMode)
    } else { 0 }
    $current.editorMode = Read-Choice -Prompt 'Editor mode (input-prompt key bindings):' -Options $editorChoices -DefaultIndex $defEditorIdx -NonInteractive:$NonInteractive

    # 14. Default permission mode (under permissions.{})
    $modeChoices = @('default','acceptEdits','plan','bypassPermissions','auto','dontAsk')
    $currentMode = ''
    if ($current.ContainsKey('permissions') -and $current.permissions -is [hashtable] -and $current.permissions.ContainsKey('defaultMode')) {
        $currentMode = [string]$current.permissions.defaultMode
    }
    $defModeIdx = if ($currentMode -and ($modeChoices -contains $currentMode)) {
        [Array]::IndexOf($modeChoices, $currentMode)
    } else { 0 }
    $pickedMode = Read-Choice -Prompt 'Default permission mode:' -Options $modeChoices -DefaultIndex $defModeIdx -NonInteractive:$NonInteractive
    if (-not ($current.ContainsKey('permissions') -and $current.permissions -is [hashtable])) {
        $current.permissions = @{}
    }
    $current.permissions.defaultMode = $pickedMode

    Set-ClaudeSettingsInProfile -ProfilePath (Resolve-ProfilePath) -Spec $current
    Write-Host '  Profile updated.' -ForegroundColor Green

    if (Test-DistroExists -Name $distro) {
        Install-ClaudeSettingsAllUsers -DistroName $distro -Spec $current
        Write-Host '~/.claude/settings.json installed across all project users.' -ForegroundColor Green
    }
}

function Invoke-ClaudeSettings {
    if (-not $SubVerb) {
        Write-Host "claude-settings subverbs: show | apply | reconfigure" -ForegroundColor Yellow
        return
    }
    switch ($SubVerb.ToLowerInvariant()) {
        'show'        { Invoke-ClaudeSettingsShow }
        'apply'       { Invoke-ClaudeSettingsApply }
        'reconfigure' { Invoke-ClaudeSettingsReconfigure }
        default {
            Write-Host "Unknown claude-settings subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: show | apply | reconfigure"
            exit 64
        }
    }
}

function Invoke-ClaudeSharedShow {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    Write-Host ''
    Write-Host "=== claude-shared: '$DistroName' ===" -ForegroundColor Cyan
    $s = Get-ClaudeSharedSummary -DistroName $DistroName
    if (-not $s.Ready) {
        Write-Host '  Shared store not provisioned yet — run reconcile or `claude-shared apply`.' -ForegroundColor Yellow
        return
    }
    $md = if ($s.ClaudeMdBytes -lt 0) { '(unmanaged)' } else { "$($s.ClaudeMdBytes) bytes" }
    Write-Host ("  Store:     {0}" -f (Get-ClaudeSharedStorePath))
    Write-Host ("  CLAUDE.md: {0}" -f $md)
    Write-Host ("  skills:    {0}" -f $s.SkillCount)
    Write-Host ("  agents:    {0}" -f $s.AgentCount)
    Write-Host ("  host:      {0}" -f (Get-ClaudeSharedHostPath))
    Write-Host ''
    Write-Host '  Host-mounted + shared across all projects; symlinked into each ~/.claude.' -ForegroundColor DarkGray
    Write-Host '  Survives distro nuke (lives on the Windows host).' -ForegroundColor DarkGray
}

function Invoke-ClaudeSharedBackup {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $cfg = Get-ClaudeSharedBackupConfig -Spec (Read-ProfileIfPresent)
    $dir = Get-BackupDir -DistroName $DistroName
    [void][System.IO.Directory]::CreateDirectory($dir)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest = Join-Path $dir "claude-shared-$stamp.tar.gz"
    $did = Backup-ClaudeSharedStore -DistroName $DistroName -DestPath $dest
    if (-not $did) { Write-Host '  Nothing to back up (store empty or missing).' -ForegroundColor Yellow; return }
    Write-Host "  Backup written: $dest" -ForegroundColor Green
    foreach ($expired in (Select-ExpiredBackups -Files (Get-ClaudeSharedBackupFiles -DistroName $DistroName) -Retain $cfg.retain)) {
        Remove-Item -LiteralPath $expired -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ClaudeSharedRestore {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $files = @(Get-ClaudeSharedBackupFiles -DistroName $DistroName)
    if ($files.Count -eq 0) { Write-Host "  No backups for '$DistroName'." -ForegroundColor Yellow; return }
    # $Arg may name a specific backup (leaf or full path); default is newest.
    $target = $files[0]
    if ($Arg) {
        $match = @($files | Where-Object { (Split-Path -Leaf $_) -eq $Arg -or $_ -eq $Arg })
        if ($match.Count -eq 0) { throw "Backup not found: $Arg" }
        $target = $match[0]
    }
    Write-Host "  Restoring from: $target"
    if (-not $Force) {
        $ok = Read-YesNo -Prompt '  This replaces the current shared store. Continue?' -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host '  Aborted.' -ForegroundColor Yellow; return }
    }
    Restore-ClaudeSharedStore -DistroName $DistroName -ArchivePath $target
    foreach ($h in (Get-SessionUserHomes -State (Get-StateForDistro -DistroName $DistroName))) {
        Set-ClaudeSharedSymlinks -DistroName $DistroName -User $h.User -Home $h.Home
    }
    Write-Host '  Restored.' -ForegroundColor Green
}

function Invoke-ClaudeSharedDashboard {
    [CmdletBinding()] param()
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' does not exist — run 'setup' first." }
    while ($true) {
        Invoke-ClaudeSharedShow -DistroName $distro
        Write-Host ''
        Write-Host '  i  import from host        b  backup now'
        Write-Host '  r  restore from backup     a  apply (repair structure)'
        Write-Host '  q  back'
        $a = (Read-Host '  >').Trim().ToLowerInvariant()
        switch ($a) {
            'i' { Import-ClaudeSharedSeed -DistroName $distro -Spec (Read-ProfileIfPresent); Write-Host '  Imported.' -ForegroundColor Green }
            'b' { Invoke-ClaudeSharedBackup  -DistroName $distro }
            'r' { Invoke-ClaudeSharedRestore -DistroName $distro }
            'a' { Initialize-ClaudeSharedAllUsers -DistroName $distro; Write-Host '  Structure ensured.' -ForegroundColor Green }
            default { if ($a -in @('q','')) { return } }
        }
        Write-Host ''
    }
}

function Invoke-ClaudeShared {
    # `claude-shared` — manage the shared account-level Claude store
    # (CLAUDE.md + skills/ + agents/). Bare name => interactive dashboard.
    [CmdletBinding()] param()
    if (-not $SubVerb) { Invoke-ClaudeSharedDashboard; return }
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' does not exist — run 'setup' first." }
    switch ($SubVerb.ToLowerInvariant()) {
        'show'    { Invoke-ClaudeSharedShow -DistroName $distro }
        'apply'   {
            Initialize-ClaudeSharedAllUsers -DistroName $distro
            Write-Host '  Shared store structure ensured (store + group + symlinks).' -ForegroundColor Green
        }
        'import'  {
            Import-ClaudeSharedSeed -DistroName $distro -Spec (Read-ProfileIfPresent) -Force:$Force
            Write-Host '  Imported account-level instructions from host into the shared store.' -ForegroundColor Green
        }
        'backup'  { Invoke-ClaudeSharedBackup  -DistroName $distro }
        'restore' { Invoke-ClaudeSharedRestore -DistroName $distro }
        default {
            Write-Host "Unknown claude-shared subverb: $SubVerb" -ForegroundColor Red
            Write-Host 'Subverbs: show | import | backup | restore | apply'
            exit 64
        }
    }
}

function Set-ClaudeSharedInProfile {
    # Insert/replace the claudeShared block on disk, env-token-preserving. When
    # the profile file doesn't exist yet (e.g. `setup -Name custom` on a host
    # that's never seen claudearium), seed the distro block from the actual
    # caller-supplied name + install path — NOT the hardcoded 'claudearium'
    # defaults — so subsequent `reconcile` runs target the right distro. Drops any
    # legacy claudeFile block (claudeShared supersedes it).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][hashtable]$Spec,
        [string]$SeedDistroName,
        [string]$SeedInstallPath
    )
    $p = if (Test-Path $ProfilePath) { Read-Profile -Path $ProfilePath -Raw } else {
        $seedName    = if ($SeedDistroName)  { $SeedDistroName }  else { $Name }
        $seedInstall = if ($SeedInstallPath) { $SeedInstallPath } else { (Resolve-InstallPath) }
        @{
            schemaVersion = 1
            distro        = @{ name = $seedName; base = 'debian-12'; installPath = $seedInstall }
        }
    }
    $p['claudeShared'] = $Spec
    if ($p.ContainsKey('claudeFile')) { [void]$p.Remove('claudeFile') }
    Write-Profile -Path $ProfilePath -Spec $p
}

function Get-ClaudeSharedBackupConfig {
    # Resolve the effective backup settings, merging claudeShared.backup over the
    # defaults. onNuke defaults OFF now that the store is a host-mounted folder
    # that survives nuke inherently — backup/restore are optional point-in-time
    # snapshots, not the durability mechanism. restorePrompt stays on (it only
    # fires when a prior snapshot actually exists); retain keeps the newest 5.
    [CmdletBinding()]
    param([AllowNull()][hashtable]$Spec)
    $cfg = @{ onNuke = $false; retain = 5; restorePrompt = $true }
    $eff = Get-EffectiveClaudeShared -Spec $Spec
    if ($eff -and $eff.ContainsKey('backup') -and $eff.backup -is [hashtable]) {
        $bk = $eff.backup
        if ($bk.ContainsKey('onNuke')        -and $null -ne $bk.onNuke)        { $cfg.onNuke = [bool]$bk.onNuke }
        if ($bk.ContainsKey('restorePrompt') -and $null -ne $bk.restorePrompt) { $cfg.restorePrompt = [bool]$bk.restorePrompt }
        if ($bk.ContainsKey('retain')        -and $null -ne $bk.retain)        { $cfg.retain = [int]$bk.retain }
    }
    return $cfg
}

function Get-ClaudeSharedBackupFiles {
    # The distro's backup tarballs (newest first), or @() when none.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $dir = Get-BackupDir -DistroName $DistroName
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter 'claude-shared-*.tar.gz' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object { $_.FullName })
}

function Backup-ClaudeSharedOnNuke {
    # Snapshot the shared store before a nuke (best-effort; never blocks the nuke).
    # Honors claudeShared.backup.onNuke and the -NoBackup switch. Prunes to the
    # configured retention.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()][hashtable]$Spec
    )
    if ($NoBackup) { Write-Host '  -NoBackup: skipping shared-store snapshot.' -ForegroundColor DarkGray; return }
    $cfg = Get-ClaudeSharedBackupConfig -Spec $Spec
    if (-not $cfg.onNuke) { return }
    try {
        $dir = Get-BackupDir -DistroName $DistroName
        [void][System.IO.Directory]::CreateDirectory($dir)
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $dest = Join-Path $dir "claude-shared-$stamp.tar.gz"
        $did = Backup-ClaudeSharedStore -DistroName $DistroName -DestPath $dest
        if ($did) {
            Write-Host "  Backed up account-level instructions -> $dest" -ForegroundColor Green
            foreach ($expired in (Select-ExpiredBackups -Files (Get-ClaudeSharedBackupFiles -DistroName $DistroName) -Retain $cfg.retain)) {
                Remove-Item -LiteralPath $expired -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Host '  No shared store to back up.' -ForegroundColor DarkGray
        }
    }
    catch { Write-Host "  Shared-store backup failed (continuing with nuke): $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Invoke-ClaudeSharedSeedOrRestore {
    # During setup: optionally restore the newest backup (prompt), otherwise seed
    # the store from the host. When the profile already pins a claudeShared/
    # claudeFile mode we seed without prompting; otherwise prompt (skipped in
    # NonInteractive, which also never auto-restores).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()][hashtable]$Spec
    )
    $cfg = Get-ClaudeSharedBackupConfig -Spec $Spec
    if (-not $NonInteractive -and $cfg.restorePrompt) {
        $latest = @(Get-ClaudeSharedBackupFiles -DistroName $DistroName)[0]
        if ($latest) {
            $stamp = ([IO.Path]::GetFileName($latest)) -replace '^claude-shared-', '' -replace '\.tar\.gz$', ''
            $ok = Read-YesNo -Prompt "  Restore account-level instructions from backup ($stamp)?" -Default $true -NonInteractive:$NonInteractive
            if ($ok) {
                Restore-ClaudeSharedStore -DistroName $DistroName -ArchivePath $latest
                foreach ($h in (Get-SessionUserHomes -State (Get-StateForDistro -DistroName $DistroName))) {
                    Set-ClaudeSharedSymlinks -DistroName $DistroName -User $h.User -Home $h.Home
                }
                Write-Host '  Restored account-level instructions from backup.' -ForegroundColor Green
                return
            }
        }
    }

    $effective = Get-EffectiveClaudeShared -Spec $Spec
    if ($effective) {
        Import-ClaudeSharedSeed -DistroName $DistroName -Spec $Spec
        Write-Host '  Seeded shared account-level Claude store from host.' -ForegroundColor Green
    }
    elseif (-not $NonInteractive) {
        Invoke-ClaudeSharedSetupPrompt -DistroName $DistroName
    }
}

function Invoke-ClaudeSharedSetupPrompt {
    # Interactive seed when the profile has no claudeShared/claudeFile block: pick
    # how the shared CLAUDE.md is seeded, then whether to import host skills/agents.
    # Persisted to profile.claudeShared so future runs/reconcile know the choice.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    if ($NonInteractive) { return }

    $hostPath = Get-HostClaudeFilePath
    $hostAvailable = (Test-HostClaudeAvailable) -and (Test-Path -LiteralPath $hostPath)

    Write-Host ''
    Write-Host '=== Seed shared account-level Claude store ===' -ForegroundColor Cyan
    Write-Host '  One store (CLAUDE.md + skills/ + agents/) shared by every project,'
    Write-Host '  symlinked into each ~/.claude. First, the CLAUDE.md source:'

    $options = [System.Collections.Generic.List[string]]::new()
    $modes   = [System.Collections.Generic.List[string]]::new()
    if ($hostAvailable) {
        [void]$options.Add("Copy from host ($hostPath)")
        [void]$modes.Add('host-copy')
    }
    [void]$options.Add("Caveman-lite mode (just 'be brief.')")
    [void]$modes.Add('caveman-lite')
    [void]$options.Add('Provide a custom path')
    [void]$modes.Add('custom-path')
    [void]$options.Add('Skip (leave CLAUDE.md unmanaged)')
    [void]$modes.Add('skip')

    $choice = Read-Choice -Prompt 'Choice:' -Options $options.ToArray() -DefaultIndex ($options.Count - 1) -NonInteractive:$NonInteractive
    $mode   = $modes[$options.IndexOf($choice)]

    $mdSpec = @{ mode = $mode }
    if ($mode -eq 'custom-path') {
        while ($true) {
            $entry = (Read-Host '  Windows path to CLAUDE.md').Trim()
            if ([string]::IsNullOrWhiteSpace($entry)) {
                Write-Host '  Aborted.' -ForegroundColor Yellow
                return
            }
            if (Test-Path -LiteralPath $entry) { $mdSpec['path'] = $entry; break }
            Write-Host "  Not found: $entry" -ForegroundColor Yellow
        }
    }

    # Offer to import host skills/ and agents/ when those dirs exist.
    $importSkills = $false; $importAgents = $false
    $hostSkills = Get-HostClaudeDirPath -Sub 'skills'
    $hostAgents = Get-HostClaudeDirPath -Sub 'agents'
    if (Test-Path -LiteralPath $hostSkills -PathType Container) {
        $importSkills = Read-YesNo -Prompt "  Import host skills ($hostSkills)?" -Default $true -NonInteractive:$NonInteractive
    }
    if (Test-Path -LiteralPath $hostAgents -PathType Container) {
        $importAgents = Read-YesNo -Prompt "  Import host agents ($hostAgents)?" -Default $true -NonInteractive:$NonInteractive
    }

    $spec = @{ claudeMd = $mdSpec; importSkills = $importSkills; importAgents = $importAgents }
    Set-ClaudeSharedInProfile -ProfilePath (Resolve-ProfilePath) -Spec $spec `
        -SeedDistroName $DistroName -SeedInstallPath (Resolve-InstallPath)
    Write-Host '  Profile updated (claudeShared).' -ForegroundColor Green
    Import-ClaudeSharedSeed -DistroName $DistroName -Spec (Read-ProfileIfPresent)
    Write-Host "  Shared account-level Claude store seeded (CLAUDE.md mode: $mode)." -ForegroundColor Green
}

function Invoke-HostToolsApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Diff,
        [AllowNull()]$DesiredTools
    )
    $desiredByCmd = @{}
    foreach ($t in @($DesiredTools)) {
        if ($t) { $desiredByCmd[[string]$t.guestCommand] = $t }
    }
    foreach ($c in $Diff.Changes) {
        $gc = ($c.Path -replace '^hostTools\.', '') -replace '\.windowsExe$', ''
        switch ($c.Action) {
            'add'    {
                $t = $desiredByCmd[$gc]
                if (-not $t) { continue }
                Write-Host "  installing host-tool wrapper '$gc' -> $($t.windowsExe)"
                Install-HostToolWrapper -DistroName $DistroName -ToolSpec $t
                Add-Recent -State $State -Key 'hostExePaths' -Value ([string]$t.windowsExe)
            }
            'modify' {
                $t = $desiredByCmd[$gc]
                if (-not $t) { continue }
                Write-Host "  rewriting host-tool wrapper '$gc' -> $($t.windowsExe)"
                Install-HostToolWrapper -DistroName $DistroName -ToolSpec $t
                Add-Recent -State $State -Key 'hostExePaths' -Value ([string]$t.windowsExe)
            }
            'remove' {
                Write-Host "  removing host-tool wrapper '$gc'"
                Remove-HostToolWrapper -DistroName $DistroName -GuestCommand $gc
            }
        }
    }
}

function Invoke-ToolsApply {
    # Apply a tools-diff against a running distro. Walks dependency edges via
    # Install-Tool, which installs missing deps eagerly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Diff,
        [AllowNull()]$DesiredTools
    )
    if (-not $DesiredTools) { return }
    foreach ($c in $Diff.Changes) {
        if ($c.Action -ne 'add') { continue }  # only handles installs (no auto-uninstall)
        $name = ($c.Path -replace '^tools\.', '')
        $entry = $DesiredTools[$name]
        if (-not $entry) { continue }
        $ver = if ($entry.ContainsKey('version')) { [string]$entry.version } else { 'latest' }
        Install-Tool -DistroName $DistroName -Name $name -Version $ver
        Add-Recent -State $State -Key 'toolNames' -Value $name
    }
}

function Invoke-MountsApply {
    # Apply a hostMounts diff. All operations are non-destructive in-place
    # (just /etc/fstab + umount/mount). The destructive sense ("you lose data
    # inside a removed mount") is the user's call, not the kernel's.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()]$DesiredMounts
    )
    Set-HostMountsInDistro -DistroName $DistroName -Mounts $DesiredMounts
    # Recents: track recently used host paths for future interactive pickers.
    if ($DesiredMounts) {
        foreach ($m in @($DesiredMounts)) {
            Add-Recent -State $State -Key 'hostMountPaths' -Value ([string]$m.host)
        }
    }
}

function Get-MigrationDirtySessions {
    # Sessions with uncommitted work, across all projects — used to gate the
    # per-project-user migration rebuild. Distro sessions: git status via the
    # owning user's home; host sessions: git status on the Windows worktree.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State
    )
    $out = @()
    foreach ($s in (Get-Sessions -State $State)) {
        if (-not ($s -is [hashtable])) { continue }
        $type = Get-SessionType -Session $s
        $proj = [string]$s.project; $name = [string]$s.name
        $dirty = 0
        if ($type -eq 'host') {
            $hw = if ($s.ContainsKey('hostWorktreePath')) { [string]$s.hostWorktreePath } else { '' }
            if ($hw -and (Test-Path -LiteralPath $hw)) {
                try { $o = & git -C $hw status --porcelain 2>$null; if ($LASTEXITCODE -eq 0) { $dirty = @($o).Count } } catch {}
            }
        }
        else {
            $pu = Resolve-ProjectUserHome -State $State -Project $proj
            $dirty = Get-SessionDirtyFileCount -DistroName $DistroName -Project $proj -Name $name -User $pu.User -Home $pu.Home
        }
        if ($dirty -gt 0) { $out += [PSCustomObject]@{ Project = $proj; Name = $name; Dirty = $dirty } }
    }
    return ,$out
}

function Invoke-Reconcile {
    $path = Resolve-ProfilePath
    Write-Host ''
    Write-Host '=== Claudearium: reconcile ===' -ForegroundColor Cyan
    Write-Host "  Profile:   $path"

    if (-not (Test-Path $path)) {
        Write-Host "  Profile not found." -ForegroundColor Yellow
        Write-Host "  Create one with: .\claudearium.ps1 profile edit" -ForegroundColor Yellow
        return
    }

    $spec = Read-ProfileIfPresent
    if (-not $spec) { return }

    # Windows Terminal profile fragment is a host-side artifact, independent of
    # the distro and not part of the diff (icon/background/opacity don't touch
    # distro state). Sync it up front so an appearance-only profile edit applies
    # even when there are no distro changes (the common early-return path below).
    Update-WtProfilesFragment | Out-Null

    $targetName = [string]$spec.distro.name
    Write-Host "  Target:    distro '$targetName'"

    if (-not (Test-State -DistroName $targetName)) {
        Write-Host ''
        Write-Host "  Distro '$targetName' has no recorded state — run 'setup' first." -ForegroundColor Yellow
        Write-Host "  (setup will use this profile automatically.)" -ForegroundColor Yellow
        return
    }
    $state = Read-State -DistroName $targetName

    # A distro provisioned before per-project user isolation needs a rebuild to
    # move its projects into per-project users. Detected via the userModel marker
    # (absent on pre-isolation state). Routed through the same nuke+setup path as
    # a destructive distro-block change below.
    $needsUserMigration = ((Get-DistroState -Name $targetName) -ne 'Missing') -and (Test-NeedsUserModelMigration -State $state)

    $distroDiff = Get-DistroBlockDiff -DesiredDistro $spec.distro -CurrentState $state

    $actualProjects = @()
    if ((Get-DistroState -Name $targetName) -ne 'Missing') {
        $actualProjects = Get-ProjectsActualFromDistro -DistroName $targetName -State $state
    }
    $desiredProjects = @()
    if ($spec.ContainsKey('projects') -and $null -ne $spec.projects) {
        $desiredProjects = @($spec.projects)
    }
    $projectsDiff = Get-ProjectsDiff -DesiredProjects $desiredProjects -ActualProjects $actualProjects

    $actualMounts = @()
    if ((Get-DistroState -Name $targetName) -ne 'Missing') {
        $actualMounts = Get-HostMountsActualFromDistro -DistroName $targetName
    }
    # Diff against the merged set (profile mounts ∪ active hostProject session
    # mounts) so reconcile doesn't see session-derived fstab entries as "user
    # mounts that drifted out of profile" and unmount them.
    $desiredMounts = Get-MergedDesiredMounts -ProfileSpec $spec -State $state
    $mountsDiff = Get-HostMountsDiff -DesiredMounts $desiredMounts -ActualMounts $actualMounts

    $actualTools = @()
    if ((Get-DistroState -Name $targetName) -ne 'Missing') {
        $actualTools = Get-ToolsActualFromDistro -DistroName $targetName
    }
    $desiredTools = $null
    if ($spec.ContainsKey('tools') -and $spec.tools -is [hashtable]) { $desiredTools = $spec.tools }
    $toolsDiff = Get-ToolsDiff -DesiredTools $desiredTools -ActualTools $actualTools

    $actualHostTools = @()
    if ((Get-DistroState -Name $targetName) -ne 'Missing') {
        $actualHostTools = Get-HostToolsActualFromDistro -DistroName $targetName
    }
    $desiredHostTools = @()
    if ($spec.ContainsKey('hostTools') -and $null -ne $spec.hostTools) { $desiredHostTools = @($spec.hostTools) }
    $hostToolsDiff = Get-HostToolsDiff -DesiredTools $desiredHostTools -ActualTools $actualHostTools

    # claudeSettings is intentionally NOT part of reconcile's diff: hashtable-
    # key ordering through ConvertTo-Json makes drift detection unreliable, and
    # settings are user-preferences rather than infrastructure. Apply explicitly
    # via 'claude-settings apply' or 'claude-settings reconfigure'.

    # The shared account-level Claude store (CLAUDE.md + skills/ + agents/) is
    # reconciled STRUCTURALLY only. Its content is seed-once / import-on-demand
    # and editable in-distro (shared across projects), so reconcile never compares
    # or overwrites content — that would clobber agent edits. The diff proposes a
    # single safe change when the store isn't provisioned yet (first run after an
    # upgrade); the idempotent structural ensure runs in the apply phase.
    $sharedReady = ((Get-DistroState -Name $targetName) -ne 'Missing') -and (Test-ClaudeSharedStoreReady -DistroName $targetName)
    $claudeSharedDiff = Get-ClaudeSharedDiff -Ready ([bool]$sharedReady)

    # Host-VPN eth0 net-repair (opt-in). Structural: install/enable when desired,
    # update the MTU override on drift, or disable when turned off.
    $actualNetwork = @{ Installed = $false; Enabled = $false; Mtu = $null }
    if ((Get-DistroState -Name $targetName) -ne 'Missing') {
        $actualNetwork = Get-NetRepairActualFromDistro -DistroName $targetName
    }
    $desiredNetwork = Get-EffectiveNetworkConfig -Spec $spec
    $networkDiff = Get-NetworkDiff -Desired $desiredNetwork -Actual $actualNetwork

    $allChanges = @($distroDiff.Changes) + @($projectsDiff.Changes) + @($mountsDiff.Changes) + @($toolsDiff.Changes) + @($hostToolsDiff.Changes) + @($claudeSharedDiff.Changes) + @($networkDiff.Changes)
    if ($needsUserMigration) {
        $allChanges = @($allChanges) + @(@{
            Path     = 'distro (per-project user isolation)'
            Action   = 'migrate'
            Severity = 'destructive'
            Note     = 'rebuild: nuke + setup; existing projects re-clone under per-project users'
        })
    }
    # A rebuild (nuke+setup) is needed for a destructive distro-block change OR a
    # pre-isolation -> per-project-user migration.
    $rebuild = $distroDiff.HasDestructive -or $needsUserMigration
    $combined = @{ Changes = $allChanges; HasDestructive = ($rebuild -or $projectsDiff.HasDestructive) }

    Write-Host ''
    Write-Host 'Pending changes:'
    Format-Diff -Diff $combined

    Add-Recent -State $state -Key 'profilePaths' -Value $path
    Write-State -DistroName $targetName -State $state

    if ($allChanges.Count -eq 0) { return }

    # Dirty-session gate for the per-project-user migration: the rebuild loses
    # all sessions, so refuse if any has uncommitted work (unless -DiscardDirty / -Force).
    if ($needsUserMigration) {
        $dirty = @(Get-MigrationDirtySessions -DistroName $targetName -State $state)
        if ($dirty.Count -gt 0 -and -not $DiscardDirty -and -not $Force) {
            Write-Host ''
            Write-Host '  Sessions with uncommitted work (would be lost by the rebuild):' -ForegroundColor Yellow
            foreach ($d in $dirty) { Write-Host ('    {0}/{1}: {2} file(s)' -f $d.Project, $d.Name, $d.Dirty) -ForegroundColor Yellow }
            throw "Refusing to migrate to per-project users — commit/stash the above, or pass -DiscardDirty / -Force."
        }
    }

    Write-Host ''
    if ($needsUserMigration) {
        Write-Host '  This distro predates per-project user isolation — migrating rebuilds it.' -ForegroundColor Yellow
    }
    if ($rebuild) {
        Write-Host '  This requires nuke+setup.' -ForegroundColor Yellow
        Write-Host '  All current sessions and bare mirrors will be lost (projects re-clone).' -ForegroundColor Red
    }

    # -Force bypasses the confirmation. Documented as the explicit opt-in for
    # scripted reconcile runs (CI / tests); the rendered diff just above is
    # what the user / script reviewed before passing -Force.
    if ($Force) {
        Write-Host 'Apply these changes? -Force was set, applying without prompt.' -ForegroundColor DarkGray
        $apply = $true
    }
    else {
        $apply = Read-YesNo -Prompt 'Apply these changes?' -Default $false -NonInteractive:$NonInteractive
    }
    if (-not $apply) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }

    if ($rebuild) {
        $script:Name        = [string]$spec.distro.name
        $script:InstallPath = [string]$spec.distro.installPath
        $script:Force       = $true
        Invoke-Nuke
        Invoke-Setup
        # After fresh setup, everything in profile.{projects,hostMounts} is from scratch.
        $state = Read-State -DistroName $targetName
        if ($desiredProjects.Count -gt 0) {
            $allAddsDiff = Get-ProjectsDiff -DesiredProjects $desiredProjects -ActualProjects @()
            Invoke-ProjectsApply -DistroName $targetName -State $state -Diff $allAddsDiff -DesiredProjects $desiredProjects
        }
        if ($desiredMounts.Count -gt 0) {
            Invoke-MountsApply -DistroName $targetName -State $state -DesiredMounts $desiredMounts
        }
        if ($desiredTools) {
            $allAddsToolDiff = Get-ToolsDiff -DesiredTools $desiredTools -ActualTools @()
            Invoke-ToolsApply -DistroName $targetName -State $state -Diff $allAddsToolDiff -DesiredTools $desiredTools
        }
        if ($desiredHostTools.Count -gt 0) {
            $allAddsHt = Get-HostToolsDiff -DesiredTools $desiredHostTools -ActualTools @()
            Invoke-HostToolsApply -DistroName $targetName -State $state -Diff $allAddsHt -DesiredTools $desiredHostTools
        }
        # Shared store is provisioned + seeded by Invoke-Setup above (structure +
        # host seed / backup restore), so nothing extra to do here on rebuild.
        # Per-tool host-tool notes — runs after the shared store exists (it owns
        # the store CLAUDE.md; we only append a managed block) and host-tools (so
        # the desired set is in sync with the freshly-installed wrappers).
        try { Install-HostToolNotesAllUsers -DistroName $targetName -Spec $spec }
        catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        Write-State -DistroName $targetName -State $state
    }
    else {
        # Shared store is a host-mounted folder: migrate any pre-mount ext4 content
        # out and ensure the host dir exists BEFORE mounts are applied — mounting
        # over the guest path would shadow the ext4 content, and a missing host
        # source dir fails 'mount -a'. Marker-gated, so it's a no-op after the
        # first reconcile that performs the migration.
        try { Invoke-ClaudeSharedHostMigration -DistroName $targetName }
        catch { Write-Host "  Shared-store host migration failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($projectsDiff.Changes.Count -gt 0) {
            Invoke-ProjectsApply -DistroName $targetName -State $state -Diff $projectsDiff -DesiredProjects $desiredProjects
        }
        if ($mountsDiff.Changes.Count -gt 0) {
            Invoke-MountsApply -DistroName $targetName -State $state -DesiredMounts $desiredMounts
        }
        if ($toolsDiff.Changes.Count -gt 0) {
            Invoke-ToolsApply -DistroName $targetName -State $state -Diff $toolsDiff -DesiredTools $desiredTools
        }
        if ($hostToolsDiff.Changes.Count -gt 0) {
            Invoke-HostToolsApply -DistroName $targetName -State $state -Diff $hostToolsDiff -DesiredTools $desiredHostTools
        }
        # Shared account-level Claude store: idempotent STRUCTURAL ensure (store
        # subdirs on the mounted folder + per-user symlinks). Never touches
        # content, so existing in-distro edits / skills / agents are preserved.
        # This also repairs the store on the first reconcile after upgrading to the
        # host-mounted model (the $claudeSharedDiff 'add' above flags it).
        try { Initialize-ClaudeSharedAllUsers -DistroName $targetName }
        catch { Write-Host "  Shared Claude store ensure failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        # Host-VPN eth0 net-repair: apply the structural diff (install/enable,
        # MTU update, or disable). Non-fatal on failure.
        if ($networkDiff.Changes.Count -gt 0) {
            try { Invoke-NetworkApply -DistroName $targetName -Desired $desiredNetwork }
            catch { Write-Host "  Net-repair apply failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        # Always re-sync host-tool notes: the managed block depends on the
        # hostTools set which the apply path may have just changed. Written once
        # to the shared store (symlinked into every user).
        try { Install-HostToolNotesAllUsers -DistroName $targetName -Spec $spec }
        catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        Write-State -DistroName $targetName -State $state
    }
}

function Invoke-Prune {
    # Drift detection + repair. Four scopes:
    #   sessions   — state.sessions records whose worktree dir is gone; tmux-backed
    #                records whose session died (drop record); untracked cl-* tmux
    #                sessions with no record (kill)
    #   worktrees  — git's own worktree list flags `prunable`, or the dir is missing
    #                (the persistent main/ checkout is never reported / pruned)
    #   mounts     — fstab managed-block entries with no matching host session
    #   artifacts  — heavy untracked dirs (node_modules / target / .next / ...)
    #                inside live session worktrees
    # -DryRun reports what *would* happen and exits without mutating anything.
    # -Force skips per-item prompts on the destructive scopes (artifacts).
    # -Scope <name> narrows the run; default is 'all'.
    $scope = if ($Scope) { $Scope.ToLowerInvariant() } else { 'all' }
    $validScopes = @('all', 'sessions', 'worktrees', 'mounts', 'artifacts')
    if ($scope -notin $validScopes) {
        throw "prune: -Scope must be one of: $($validScopes -join ', ') (got '$Scope')."
    }
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) {
        throw "Distro '$distro' does not exist; nothing to prune."
    }
    $spec  = $null
    try { $spec = Read-ProfileIfPresent } catch { }
    $state = if (Test-State -DistroName $distro) { Read-State -DistroName $distro } else { Initialize-State -DistroName $distro }

    $runScope = { param([string]$Name) ($scope -eq 'all' -or $scope -eq $Name) }
    $anyAction = $false
    $stateMutated = $false

    Write-Host ''
    Write-Host "=== Claudearium prune (scope: $scope$(if ($DryRun) { ', dry-run' }))===" -ForegroundColor Cyan

    # ---- sessions scope ----
    if (& $runScope 'sessions') {
        Write-Host ''
        Write-Host '[sessions] Looking for state.sessions records whose worktree is gone ...'
        # @(...) wrap: Find-* helpers return `@()` for the no-results case,
        # which PowerShell unwraps to $null at the assignment boundary —
        # `$null.Count` then throws under StrictMode. The wrap converts the
        # unwrapped result back into an empty Object[].
        $orphans = @(Find-OrphanedSessions -State $state -DistroName $distro)
        if ($orphans.Count -eq 0) {
            Write-Host '  no orphaned sessions.' -ForegroundColor DarkGray
        }
        else {
            $anyAction = $true
            foreach ($o in $orphans) {
                $where = if ($o.Type -eq 'host') { $o.HostWorktreePath } else { $o.WorktreePath }
                Write-Host ("  orphan: {0,-16} {1,-22} ({2})   worktree gone at: {3}" -f $o.Project, $o.Name, $o.Type, $where) -ForegroundColor Yellow
            }
            if (-not $DryRun) {
                foreach ($o in $orphans) {
                    $state.sessions = @($state.sessions | Where-Object { -not ([string]$_.project -eq $o.Project -and [string]$_.name -eq $o.Name) })
                }
                $stateMutated = $true
                Write-Host "  removed $($orphans.Count) state record(s)." -ForegroundColor Green
            }
        }

        # Dead sessions: a tmux-backed record whose tmux session is gone (the
        # per-user server died, e.g. after `wsl --shutdown`). Not reattachable;
        # drop the record. Skip records already flagged as orphaned above.
        Write-Host ''
        Write-Host '[sessions] Looking for tmux-backed records whose session died ...'
        $orphanKeys = @{}; foreach ($o in $orphans) { $orphanKeys["$($o.Project)/$($o.Name)"] = $true }
        $dead = @(Find-DeadSessions -State $state -DistroName $distro | Where-Object { -not $orphanKeys.ContainsKey("$($_.Project)/$($_.Name)") })
        if ($dead.Count -eq 0) {
            Write-Host '  no dead sessions.' -ForegroundColor DarkGray
        }
        else {
            $anyAction = $true
            foreach ($d in $dead) {
                Write-Host ("  dead: {0,-16} {1,-22} (tmux '{2}' not running)" -f $d.Project, $d.Name, $d.TmuxName) -ForegroundColor Yellow
            }
            if (-not $DryRun) {
                foreach ($d in $dead) {
                    $state.sessions = @($state.sessions | Where-Object { -not ([string]$_.project -eq $d.Project -and [string]$_.name -eq $d.Name) })
                }
                $stateMutated = $true
                Write-Host "  removed $($dead.Count) dead session record(s)." -ForegroundColor Green
            }
        }

        # Untracked tmux sessions: live cl-* sessions with no state record. Kept
        # visible (never silently abandoned); kill on repair. The owning user is
        # unknown, so kill-session is attempted as each project user (it no-ops
        # on a server that doesn't hold the session).
        Write-Host ''
        Write-Host '[sessions] Looking for untracked cl-* tmux sessions ...'
        $untracked = @(Find-UntrackedTmuxSessions -State $state -DistroName $distro)
        if ($untracked.Count -eq 0) {
            Write-Host '  no untracked tmux sessions.' -ForegroundColor DarkGray
        }
        else {
            $anyAction = $true
            foreach ($t in $untracked) {
                $at = if ($t.Attached) { 'attached' } else { 'detached' }
                Write-Host ("  untracked: {0}  ({1})" -f $t.TmuxName, $at) -ForegroundColor Yellow
            }
            if (-not $DryRun) {
                $killUsers = New-Object System.Collections.Generic.List[string]
                $killUsers.Add('claude')
                if ($state.ContainsKey('users') -and ($state.users -is [hashtable])) {
                    foreach ($rec in $state.users.Values) {
                        if ($rec -is [hashtable] -and $rec.ContainsKey('user')) {
                            $uu = [string]$rec.user
                            if ($uu -and -not $killUsers.Contains($uu)) { $killUsers.Add($uu) }
                        }
                    }
                }
                foreach ($t in $untracked) {
                    foreach ($u in $killUsers) { Stop-TmuxSession -DistroName $distro -TmuxName ([string]$t.TmuxName) -User $u }
                }
                Write-Host "  killed $($untracked.Count) untracked tmux session(s)." -ForegroundColor Green
            }
        }
    }

    # ---- worktrees scope ----
    if (& $runScope 'worktrees') {
        Write-Host ''
        Write-Host '[worktrees] Looking for stale git worktree refs ...'
        $stale = @(Find-StaleWorktrees -DistroName $distro -ProfileSpec $spec)
        if ($stale.Count -eq 0) {
            Write-Host '  no stale worktree refs.' -ForegroundColor DarkGray
        }
        else {
            $anyAction = $true
            # Group by Location so we can batch `git worktree prune` per repo
            # (it cleans every stale ref in one pass; no per-worktree call).
            $byLocation = @{}
            foreach ($s in $stale) {
                if (-not $byLocation.ContainsKey($s.Location)) { $byLocation[$s.Location] = New-Object System.Collections.Generic.List[hashtable] }
                $byLocation[$s.Location].Add($s)
            }
            foreach ($loc in $byLocation.Keys) {
                Write-Host "  $loc :" -ForegroundColor Yellow
                foreach ($s in $byLocation[$loc]) {
                    Write-Host ("    {0}  ({1})" -f $s.Worktree, $s.Reason)
                }
            }
            if (-not $DryRun) {
                foreach ($loc in $byLocation.Keys) {
                    $first = $byLocation[$loc][0]
                    $side = $first.Side
                    if ($side -eq 'distro') {
                        # Run the prune as the mirror's owning user — under
                        # per-project isolation the mirror lives in a 0700 home
                        # and git refuses (dubious ownership) if run as anyone else.
                        $pruneUser = if ($first.ContainsKey('User') -and $first.User) { [string]$first.User } else { 'claude' }
                        $qLoc = ConvertTo-BashQuoted $loc
                        Invoke-InDistro -Name $distro -User $pruneUser -Command "git -C $qLoc worktree prune" -AllowFail | Out-Null
                    }
                    else {
                        # host side — run git on the Windows checkout directly.
                        & git -C $loc worktree prune 2>$null | Out-Null
                    }
                }
                Write-Host "  pruned $($stale.Count) stale ref(s) across $($byLocation.Keys.Count) repo(s)." -ForegroundColor Green
            }
        }
    }

    # ---- mounts scope ----
    if (& $runScope 'mounts') {
        Write-Host ''
        Write-Host '[mounts] Looking for dangling fstab entries (no matching host session) ...'
        $dangling = @(Find-DanglingMounts -DistroName $distro -State $state -ProfileSpec $spec)
        if ($dangling.Count -eq 0) {
            Write-Host '  no dangling fstab entries.' -ForegroundColor DarkGray
        }
        else {
            $anyAction = $true
            foreach ($d in $dangling) {
                Write-Host ("  dangling: {0,-32} {1}" -f $d.Guest, $d.Host) -ForegroundColor Yellow
            }
            if (-not $DryRun) {
                # Persist any prior state mutation first so Invoke-MergedMountsApply's
                # Read-State call sees the just-pruned sessions.
                if ($stateMutated) {
                    Write-State -DistroName $distro -State $state
                    $stateMutated = $false
                }
                Invoke-MergedMountsApply -DistroName $distro
                Write-Host "  fstab managed block rewritten." -ForegroundColor Green
            }
        }
    }

    # ---- artifacts scope ----
    if (& $runScope 'artifacts') {
        Write-Host ''
        Write-Host '[artifacts] Scanning session worktrees for heavy build dirs ...'
        $artifacts = @(Find-HeavyArtifacts -DistroName $distro -State $state)
        # Drop anything below a tiny threshold (5MB) — empty `bin/` and `obj/`
        # dirs from PowerShell modules add noise without real disk impact.
        $artifacts = @($artifacts | Where-Object { $_.Bytes -ge (5 * 1MB) })
        if ($artifacts.Count -eq 0) {
            Write-Host '  no heavy artifact dirs found.' -ForegroundColor DarkGray
        }
        else {
            $anyAction = $true
            $totalBytes = 0L; foreach ($a in $artifacts) { $totalBytes += [long]$a.Bytes }
            Write-Host "  found $($artifacts.Count) heavy dir(s); total $((Format-Bytes -Bytes $totalBytes))" -ForegroundColor Yellow
            foreach ($a in $artifacts) {
                Write-Host ("    {0,-7} {1,-16} {2,-22} {3,-16} {4}" -f (Format-Bytes -Bytes $a.Bytes), $a.Project, $a.Session, $a.ArtifactDir, $a.Path)
            }
            if (-not $DryRun) {
                foreach ($a in $artifacts) {
                    $label = "$($a.Project)/$($a.Session)/$($a.ArtifactDir)"
                    $delete = $Force
                    if (-not $delete) {
                        $delete = Read-YesNo -Prompt "Delete $label ($((Format-Bytes -Bytes $a.Bytes)))?" -Default $false -NonInteractive:$NonInteractive
                    }
                    if (-not $delete) {
                        Write-Host "    skipped $label." -ForegroundColor DarkGray
                        continue
                    }
                    if ($a.Type -eq 'host') {
                        $target = Join-Path $a.Path $a.ArtifactDir
                        try {
                            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                            Write-Host "    removed $label." -ForegroundColor Green
                        } catch {
                            Write-Host "    failed: $label — $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                    else {
                        $qTarget = ConvertTo-BashQuoted "$($a.Path)/$($a.ArtifactDir)"
                        $r = Invoke-InDistro -Name $distro -User 'claude' -Command "rm -rf $qTarget && echo ok || echo fail" -AllowFail -CaptureOutput
                        $verdict = ($r.Output | Where-Object { $_ -is [string] -and ($_.Trim() -in @('ok','fail')) } | Select-Object -Last 1) -as [string]
                        if ($verdict -and $verdict.Trim() -eq 'ok') {
                            Write-Host "    removed $label." -ForegroundColor Green
                        }
                        else {
                            Write-Host "    failed: $label" -ForegroundColor Red
                        }
                    }
                }
            }
        }
    }

    # ---- final state persistence ----
    if ($stateMutated -and -not $DryRun) {
        Write-State -DistroName $distro -State $state
    }
    Write-Host ''
    if (-not $anyAction) {
        Write-Host 'Nothing to prune.' -ForegroundColor Green
    }
    elseif ($DryRun) {
        Write-Host 'Dry-run complete — no changes made. Re-run without -DryRun to apply.' -ForegroundColor Cyan
    }
    else {
        Write-Host 'Prune complete.' -ForegroundColor Green
    }
}

function Invoke-Temp {
    # Scratch-space management. Three scopes — tmp / cache / claude — each
    # owns a chunk of disk that's safe to reclaim under different rules.
    # Subverbs:
    #   bare / (no subverb) → print sizes (cheap, no mutation)
    #   size                → same as bare
    #   clean -Scope <s>    → wipe the scope, prompt unless -Force
    #
    # claude-scope cleans transcripts + shell-snapshots by default; pass
    # -IncludeTodos / -IncludePlans to widen the wipe to those preserve dirs.
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) {
        throw "Distro '$distro' does not exist; nothing to size or wipe."
    }
    $sub = if ($SubVerb) { $SubVerb.ToLowerInvariant() } else { 'size' }
    switch ($sub) {
        'size'  { Invoke-TempSize  -DistroName $distro }
        'clean' { Invoke-TempClean -DistroName $distro }
        default {
            Write-Host "Unknown temp subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: size | clean (or bare 'temp' for sizes)"
            exit 64
        }
    }
}

function Invoke-TempSize {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $homes = Get-ScratchHomes -DistroName $DistroName
    $s = Get-ScratchSizes -DistroName $DistroName -Homes $homes
    # cache + claude are summed across every home (lobby + project users); reflect
    # that in the path column rather than implying a single /home/claude.
    $cachePath  = if ($homes.Count -gt 1) { "~/.cache  (× $($homes.Count) users)" }  else { "$($homes[0])/.cache" }
    $claudePath = if ($homes.Count -gt 1) { "~/.claude (× $($homes.Count) users)" } else { "$($homes[0])/.claude" }
    Write-Host ''
    Write-Host '=== Claudearium scratch sizes ===' -ForegroundColor Cyan
    Write-Host ('  {0,-9} {1,10}   {2}' -f 'scope','size','path')
    Write-Host ('  {0,-9} {1,10}   {2}' -f '-----','----','----')
    Write-Host ('  {0,-9} {1,10}   {2}' -f 'tmp',    (Format-Bytes -Bytes $s.tmp),    '/tmp')
    Write-Host ('  {0,-9} {1,10}   {2}' -f 'cache',  (Format-Bytes -Bytes $s.cache),  $cachePath)
    Write-Host ('  {0,-9} {1,10}   {2}' -f 'claude', (Format-Bytes -Bytes $s.claude), $claudePath)
    Write-Host ('  {0,-9} {1,10}' -f 'total',  (Format-Bytes -Bytes $s.total))
}

function Invoke-TempClean {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $scope = if ($Scope) { $Scope.ToLowerInvariant() } else { 'all' }
    $validScopes = @('tmp', 'cache', 'claude', 'all')
    if ($scope -notin $validScopes) {
        throw "temp clean: -Scope must be one of: $($validScopes -join ', ') (got '$Scope')."
    }
    $homes = Get-ScratchHomes -DistroName $DistroName
    # Always size first so the user sees what's about to go.
    $sizes = Get-ScratchSizes -DistroName $DistroName -Homes $homes
    $targets = if ($scope -eq 'all') { @('tmp','cache','claude') } else { @($scope) }

    Write-Host ''
    Write-Host "=== Claudearium temp clean (scope: $scope) ===" -ForegroundColor Cyan
    foreach ($t in $targets) {
        $sz = switch ($t) { 'tmp' { $sizes.tmp } 'cache' { $sizes.cache } 'claude' { $sizes.claude } }
        Write-Host ("  {0,-9} {1,10}" -f $t, (Format-Bytes -Bytes $sz))
    }
    if ($scope -in @('claude','all')) {
        $wipe = @('projects','shell-snapshots')
        if ($IncludeTodos) { $wipe += 'todos' }
        if ($IncludePlans) { $wipe += 'plans' }
        $preserved = @('todos','plans','host-tools') | Where-Object { $wipe -notcontains $_ }
        Write-Host ''
        Write-Host '  claude scope:'
        Write-Host ("    wipe:      " + (($wipe      | ForEach-Object { "~/.claude/$_/" }) -join ', '))
        if ($preserved) {
            Write-Host ("    preserved: " + (($preserved | ForEach-Object { "~/.claude/$_/" }) -join ', '))
        }
    }

    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Wipe the above?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    foreach ($t in $targets) {
        $extra = @{}
        if ($t -eq 'claude') {
            if ($IncludeTodos) { $extra.IncludeTodos = $true }
            if ($IncludePlans) { $extra.IncludePlans = $true }
        }
        $r = Clear-Scratch -DistroName $DistroName -Scope $t -Homes $homes @extra
        Write-Host ("  [$t] removed $($r.Removed) — $($r.PreservedNote)") -ForegroundColor Green
    }

    # Re-size after so the user gets the before/after delta in one go.
    $after = Get-ScratchSizes -DistroName $DistroName -Homes $homes
    $reclaimed = 0L
    foreach ($t in $targets) {
        $reclaimed += switch ($t) {
            'tmp'    { $sizes.tmp    - $after.tmp }
            'cache'  { $sizes.cache  - $after.cache }
            'claude' { $sizes.claude - $after.claude }
        }
    }
    if ($reclaimed -lt 0) { $reclaimed = 0 }
    Write-Host ''
    Write-Host "Reclaimed: $((Format-Bytes -Bytes $reclaimed))" -ForegroundColor Green
}

function Invoke-ProfileValidate {
    $path = if ($Arg) { $Arg } else { Resolve-ProfilePath }
    Write-Host ''
    Write-Host "Validating: $path"
    # -LiteralPath: wsl2-gotchas #19 (a user-supplied profile path can contain
    # wildcard glyphs that bare Test-Path would mis-interpret as a pattern).
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "  Profile not found." -ForegroundColor Red
        exit 1
    }
    try {
        $spec = Read-Profile -Path $path
    }
    catch {
        Write-Host "  JSON parse error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $v = Test-Profile -Spec $spec
    foreach ($w in $v.Warnings) { Write-Host "  warn:  $w" -ForegroundColor DarkYellow }
    foreach ($e in $v.Errors)   { Write-Host "  error: $e" -ForegroundColor Red }
    if ($v.IsValid) {
        Write-Host '  OK' -ForegroundColor Green
        exit 0
    }
    exit 1
}

function Invoke-ProfileExport {
    if (-not $Out) { throw "profile export requires -Out <path>" }
    if (-not (Test-State -DistroName $Name)) {
        throw "No state for distro '$Name' — run 'setup' first."
    }
    $state = Read-State -DistroName $Name
    $spec  = Get-ProfileFromState -State $state -Base $Base
    Write-Profile -Path $Out -Spec $spec
    Write-Host "Exported profile -> $Out" -ForegroundColor Green
}

function Invoke-ProfileEdit {
    $path = if ($Arg) { $Arg } else { Resolve-ProfilePath }
    # -LiteralPath: wsl2-gotchas #19 (user-supplied path may have wildcard glyphs).
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        # Seed from current state if any, else from example template.
        $example = Join-Path $Script:ScriptRoot 'templates\claudearium.profile.example.json'
        if (Test-State -DistroName $Name) {
            $state = Read-State -DistroName $Name
            $spec  = Get-ProfileFromState -State $state -Base $Base
            Write-Profile -Path $path -Spec $spec
            Write-Host "  Created profile from current state at: $path"
        }
        elseif (Test-Path $example) {
            $dir = Split-Path -Parent $path
            # .NET API (literal + idempotent); wsl2-gotchas #19.
            if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) }
            Copy-Item -LiteralPath $example -Destination $path -Force
            Write-Host "  Seeded profile from example template at: $path"
        }
        else {
            throw "Cannot seed profile: no state and no example template found."
        }
    }
    $editor = Get-Editor
    Write-Host "  Opening $path in $editor"
    # VS Code's `code` returns immediately even without -w; that's the intended UX
    # for standalone edit. Reconcile-driven edits will be handled separately.
    & $editor $path
}

function Invoke-ProfileShow {
    $path = if ($Arg) { $Arg } else { Resolve-ProfilePath }
    # -LiteralPath: wsl2-gotchas #19 (user-supplied path may have wildcard glyphs).
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "  Profile not found at: $path" -ForegroundColor Yellow
        return
    }
    $spec = Read-Profile -Path $path
    Write-Host ""
    Write-Host "Profile: $path"
    $spec | ConvertTo-Json -Depth 32
}

function Resolve-DistroForOps {
    # Project/session verbs operate on the distro named in the profile (if any).
    # An explicit -Name on the CLI always wins.
    if ($Script:RootBoundParams.ContainsKey('Name') -and $Name) { return $Name }
    try {
        $spec = Read-ProfileIfPresent
        if ($spec) { return [string]$spec.distro.name }
    } catch { }
    return $Name
}

function Invoke-MergedMountsApply {
    # Re-render the fstab managed block from profile.hostMounts ∪ all
    # hostProject session mounts in state. Called after any operation that
    # adds/removes a hostProject session, or when a hostProject is removed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName
    )
    $spec  = Read-ProfileIfPresent
    $state = if (Test-State -DistroName $DistroName) { Read-State -DistroName $DistroName } else { Initialize-State -DistroName $DistroName }
    $merged = Get-MergedDesiredMounts -ProfileSpec $spec -State $state
    Set-HostMountsInDistro -DistroName $DistroName -Mounts $merged
}

function Read-WtAppearanceInput {
    # Interactive prompts for the per-project Windows Terminal appearance fields
    # (tab icon / background image / background-image opacity). Returns a
    # hashtable holding only the keys the user actually set, ready to merge into
    # a project entry. Opacity is only asked when a background image is given.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectName)
    $fields = @{}
    $icon = (Read-Host "Tab icon for '$ProjectName' (file path, emoji, or glyph; Enter for none)").Trim()
    if ($icon) { $fields['icon'] = $icon }

    $bg = (Read-Host "Background image for '$ProjectName' (Windows path or URL; Enter for none)").Trim()
    if ($bg) {
        $fields['backgroundImage'] = $bg
        if (($bg -notmatch '^[a-z]+://') -and -not (Test-Path -LiteralPath $bg)) {
            Write-Host "  Warning: '$bg' not found; stored as-is." -ForegroundColor Yellow
        }
        $op = Read-OpacityPercent -Prompt "Background opacity % for '$ProjectName' (0 = transparent, 100 = solid; Enter = use default)"
        if ($null -ne $op) { $fields['backgroundImageOpacity'] = [int]$op }
    }
    return $fields
}

function Update-WtProfilesFragment {
    # Regenerate the Windows Terminal profile fragment from the current profile,
    # printing a restart-required note only when the on-disk fragment changed.
    # No-op when there's no profile yet. Returns the Update-WtFragment result.
    [CmdletBinding()]
    param([switch]$Quiet)
    $spec = $null
    try { $spec = Read-ProfileIfPresent } catch { return $null }
    if (-not $spec) { return $null }
    $r = $null
    try { $r = Update-WtFragment -Spec $spec }
    catch {
        Write-Host "  Warning: could not update Windows Terminal profiles: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
    if ($r.Changed -and -not $Quiet) {
        if ($r.Removed) {
            Write-Host "  Windows Terminal profiles cleared (no project sets an icon/background)." -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Windows Terminal profiles updated ($($r.ProfileCount)) - restart Windows Terminal to apply icon/background changes." -ForegroundColor Cyan
        }
    }
    return $r
}

function Invoke-ProjectAdd {
    $distro      = Resolve-DistroForOps
    $projName    = $Arg
    $isHost      = [bool]$HostProject

    if ($isHost) {
        # ---- hostProject branch ----
        $checkout = $HostCheckout
        if (-not $checkout) {
            if ($NonInteractive) { throw '-HostCheckout is required for a hostProject in non-interactive mode.' }
            $entry = Read-Host "Host checkout path (e.g. C:\src\acme)"
            $checkout = $entry.Trim()
        }
        if (-not $checkout) { throw 'Host checkout path is required for a hostProject.' }
        if (-not (Test-HostCheckout -HostCheckout $checkout)) {
            throw "Host checkout '$checkout' does not exist or is not a git working tree (no .git found)."
        }

        # Resolve-SmartRemote returns $null when the checkout has no `origin`
        # set (test fixtures, fresh `git init`, etc.). Resolve-SmartProjectName
        # has a mandatory non-empty -Remote, so guard the call rather than
        # passing $null through.
        $autoRemoteForName = Resolve-SmartRemote -HostCheckout $checkout
        $autoName = if ($autoRemoteForName) { Resolve-SmartProjectName -Remote $autoRemoteForName } else { $null }
        if (-not $projName) {
            $derived = if ($autoName) { $autoName } else { (Split-Path -Leaf $checkout) }
            if ($NonInteractive) { $projName = $derived }
            else {
                $hint = if ($derived) { " [$derived]" } else { '' }
                $entry = Read-Host "Project name$hint"
                $projName = if ([string]::IsNullOrWhiteSpace($entry)) { $derived } else { $entry.Trim() }
            }
        }
        if (-not $projName) { throw 'Project name is required.' }
        if ($projName -match '[\\/\s]') { throw "Project name '$projName' must not contain whitespace or path separators." }

        $shadowList = @('pwsh', 'git')
        if ($Script:RootBoundParams.ContainsKey('HostShadows')) {
            $shadowList = @($HostShadows)
        }

        $tabColor = ''
        $appearance = @{}
        if (-not $NonInteractive) {
            $tabColor = Read-TabColor -Prompt "Default wt tab color for '$projName' sessions" -Default ''
            $appearance = Read-WtAppearanceInput -ProjectName $projName
        }

        Write-Host ''
        Write-Host "  Project:        $projName (host)"
        Write-Host "  Host checkout:  $checkout"
        Write-Host "  Shadows:        $($shadowList -join ', ')"
        Write-Host "  Tab color:      $(if ($tabColor) { $tabColor } else { '(none)' })"
        Write-Host "  Icon:           $(if ($appearance.ContainsKey('icon')) { $appearance.icon } else { '(none)' })"
        Write-Host "  Background:     $(if ($appearance.ContainsKey('backgroundImage')) { "$($appearance.backgroundImage) @ $(if ($appearance.ContainsKey('backgroundImageOpacity')) { "$($appearance.backgroundImageOpacity)%" } else { 'default %' })" } else { '(none)' })"
        Write-Host "  Profile:        $(Resolve-ProfilePath)"

        if (-not $NonInteractive) {
            $ok = Read-YesNo -Prompt 'Add this hostProject?' -Default $true
            if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
        }

        # No `type` key — capability derives from field presence (hostCheckout
        # here makes this a host-only project until a distro half is added).
        $entry = @{
            name         = $projName
            hostCheckout = $checkout
            hostShadows  = @($shadowList)
        }
        if ($tabColor) { $entry['tabColor'] = $tabColor }
        foreach ($k in $appearance.Keys) { $entry[$k] = $appearance[$k] }
        Add-ProjectToProfile -ProfilePath (Resolve-ProfilePath) -ProjectSpec $entry
        Write-Host "  Added to profile." -ForegroundColor Green
        Update-WtProfilesFragment | Out-Null

        if (-not (Test-DistroExists -Name $distro)) {
            Write-Host "  Distro '$distro' does not exist yet — shadows will be installed on first 'setup'/'reconcile'." -ForegroundColor Yellow
            return
        }
        Write-Host "  Resolving host shadows..."
        $state = if (Test-State -DistroName $distro) { Read-State -DistroName $distro } else { Initialize-State -DistroName $distro }
        $r = Resolve-ProjectUserHome -State $state -Project $projName -DistroName $distro -Create
        if ($r.Record) {
            Write-Host "  provisioning user '$($r.User)' (uid $($r.Uid)) ..."
            New-ProjectUserInDistro -DistroName $distro -User $r.User -Uid $r.Uid -Password ([string]$r.Record.password)
            Write-State -DistroName $distro -State $state
        }
        Invoke-HostProjectApply -DistroName $distro -ProjectSpec $entry -User $r.User -Home $r.Home
        if ($r.Record) {
            Initialize-ProjectUserClaudeConfig -DistroName $distro -User $r.User -Home $r.Home -Spec (Read-ProfileIfPresent)
        }
        Add-Recent -State $state -Key 'projectNames' -Value $projName
        Write-State -DistroName $distro -State $state
        Write-Host "hostProject '$projName' added." -ForegroundColor Green
        return
    }

    # ---- distroProject branch (existing behavior) ----
    $remote      = $Remote
    $branch      = $DefaultBranch

    # Smart defaults from -HostCheckout or cwd.
    $autoRemote = Resolve-SmartRemote        -HostCheckout $HostCheckout
    $autoBranch = Resolve-SmartDefaultBranch -HostCheckout $HostCheckout
    $autoName   = if ($autoRemote) { Resolve-SmartProjectName -Remote $autoRemote } else { $null }

    if (-not $remote) {
        if ($NonInteractive) { $remote = $autoRemote }
        else {
            $hint  = if ($autoRemote) { " [$autoRemote]" } else { '' }
            $entry = Read-Host "Remote URL$hint"
            $remote = if ([string]::IsNullOrWhiteSpace($entry)) { $autoRemote } else { $entry.Trim() }
        }
    }
    if (-not $remote) { throw 'Remote URL is required (no auto-detect available).' }

    if (-not $projName) {
        $derived = if ($autoName) { $autoName } else { Resolve-SmartProjectName -Remote $remote }
        if ($NonInteractive) { $projName = $derived }
        else {
            $hint = if ($derived) { " [$derived]" } else { '' }
            $entry = Read-Host "Project name$hint"
            $projName = if ([string]::IsNullOrWhiteSpace($entry)) { $derived } else { $entry.Trim() }
        }
    }
    if (-not $projName) { throw 'Project name is required.' }
    if ($projName -match '[\\/\s]') { throw "Project name '$projName' must not contain whitespace or path separators." }

    if (-not $branch) {
        $defaultB = if ($autoBranch) { $autoBranch } else { 'master' }
        if ($NonInteractive) { $branch = $defaultB }
        else {
            $entry = Read-Host "Default branch [$defaultB]"
            $branch = if ([string]::IsNullOrWhiteSpace($entry)) { $defaultB } else { $entry.Trim() }
        }
    }

    $tabColor = ''
    $appearance = @{}
    if (-not $NonInteractive) {
        $tabColor = Read-TabColor -Prompt "Default wt tab color for '$projName' sessions" -Default ''
        $appearance = Read-WtAppearanceInput -ProjectName $projName
    }

    Write-Host ''
    Write-Host "  Project:        $projName"
    Write-Host "  Remote:         $remote"
    Write-Host "  Default branch: $branch"
    Write-Host "  Tab color:      $(if ($tabColor) { $tabColor } else { '(none)' })"
    Write-Host "  Icon:           $(if ($appearance.ContainsKey('icon')) { $appearance.icon } else { '(none)' })"
    Write-Host "  Background:     $(if ($appearance.ContainsKey('backgroundImage')) { "$($appearance.backgroundImage) @ $(if ($appearance.ContainsKey('backgroundImageOpacity')) { "$($appearance.backgroundImageOpacity)%" } else { 'default %' })" } else { '(none)' })"
    Write-Host "  Profile:        $(Resolve-ProfilePath)"

    if (-not $NonInteractive) {
        $ok = Read-YesNo -Prompt 'Add this project?' -Default $true
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    $entry = @{ name = $projName; remote = $remote; defaultBranch = $branch }
    if ($tabColor) { $entry['tabColor'] = $tabColor }
    foreach ($k in $appearance.Keys) { $entry[$k] = $appearance[$k] }
    Add-ProjectToProfile -ProfilePath (Resolve-ProfilePath) -ProjectSpec $entry
    Write-Host "  Added to profile." -ForegroundColor Green
    Update-WtProfilesFragment | Out-Null

    if (-not (Test-DistroExists -Name $distro)) {
        Write-Host "  Distro '$distro' does not exist yet — clone will happen on next 'setup'/'reconcile'." -ForegroundColor Yellow
        return
    }
    # Allocate + provision the project's dedicated Linux user before cloning into
    # its 0700 home (mirrors the reconcile 'add' path).
    $state = if (Test-State -DistroName $distro) { Read-State -DistroName $distro } else { Initialize-State -DistroName $distro }
    $r = Resolve-ProjectUserHome -State $state -Project $projName -DistroName $distro -Create
    if ($r.Record) {
        Write-Host "  provisioning user '$($r.User)' (uid $($r.Uid)) ..."
        New-ProjectUserInDistro -DistroName $distro -User $r.User -Uid $r.Uid -Password ([string]$r.Record.password)
        Write-State -DistroName $distro -State $state
    }
    if (Test-ProjectMirrorExists -DistroName $distro -ProjectName $projName -User $r.User -Home $r.Home) {
        Write-Host "  Bare mirror already present at $($r.Home)/mirrors/$projName.git" -ForegroundColor DarkGray
        return
    }
    Write-Host "  Cloning $remote -> $($r.Home)/mirrors/$projName.git ..."
    New-ProjectMirror -DistroName $distro -ProjectName $projName -Remote $remote -User $r.User -Home $r.Home
    Write-Host "  Creating main/ checkout on '$branch' (curation launch pad) ..."
    New-ProjectMainCheckout -DistroName $distro -ProjectName $projName -Branch $branch -User $r.User -Home $r.Home
    if ($r.Record) {
        Initialize-ProjectUserClaudeConfig -DistroName $distro -User $r.User -Home $r.Home -Spec (Read-ProfileIfPresent)
    }
    Add-Recent -State $state -Key 'projectNames' -Value $projName
    Add-Recent -State $state -Key 'remotes'      -Value $remote
    Write-State -DistroName $distro -State $state
    Write-Host "Project '$projName' added." -ForegroundColor Green
}

function Get-ProjectListRows([string]$DistroName) {
    if (-not $DistroName) { throw "Get-ProjectListRows: -DistroName is required." }
    $spec = $null
    try { $spec = Read-ProfileIfPresent } catch { }

    $profileProjects = @()
    if ($spec -and $spec.ContainsKey('projects') -and $null -ne $spec.projects) {
        # @() forces array shape regardless of pwsh's single-element-unwrap quirk.
        $profileProjects = @($spec.projects)
    }

    $actual = @()
    if (Test-DistroExists -Name $DistroName) {
        $listState = if (Test-State -DistroName $DistroName) { Read-State -DistroName $DistroName } else { $null }
        $actual = Get-ProjectsActualFromDistro -DistroName $DistroName -State $listState
    }
    # Fold the per-half actual records onto one entry per project name so a dual
    # project's distro + host halves don't clobber each other (they share a name).
    $actualByName = @{}
    foreach ($p in $actual) {
        $n = [string]$p.name
        $t = if ($p.ContainsKey('type') -and $p.type) { [string]$p.type } else { 'distro' }
        if (-not $actualByName.ContainsKey($n)) { $actualByName[$n] = @{ distro = $false; host = $false; remote = '' } }
        if ($t -eq 'host') { $actualByName[$n].host = $true }
        else { $actualByName[$n].distro = $true; if ([string]$p.remote) { $actualByName[$n].remote = [string]$p.remote } }
    }

    $rows = @()
    $seen = @{}
    foreach ($p in $profileProjects) {
        $name = [string]$p.name
        $seen[$name] = $true
        $halves = Get-ProjectHalves -ProjectSpec $p
        $am = if ($actualByName.ContainsKey($name)) { $actualByName[$name] } else { $null }
        $rows += [PSCustomObject]@{
            Name               = $name
            Remote             = [string]$p.remote
            HostCheckout       = if ($p.ContainsKey('hostCheckout')) { [string]$p.hostCheckout } else { '' }
            HasDistro          = $halves.Distro
            HasHost            = $halves.Host
            DefaultBranch      = if ($p.ContainsKey('defaultBranch')) { [string]$p.defaultBranch } else { 'master' }
            TabColor           = if ($p.ContainsKey('tabColor')) { [string]$p.tabColor } else { '' }
            InProfile          = $true
            Enabled            = (Test-ProjectEnabled -Entry $p)
            Materialized       = ($null -ne $am)
            DistroMaterialized = [bool]($am -and $am.distro)
            HostMaterialized   = [bool]($am -and $am.host)
        }
    }
    foreach ($n in $actualByName.Keys) {
        if (-not $seen.ContainsKey($n)) {
            $am = $actualByName[$n]
            $rows += [PSCustomObject]@{
                Name               = $n
                Remote             = [string]$am.remote
                HostCheckout       = ''
                HasDistro          = $am.distro
                HasHost            = $am.host
                DefaultBranch      = ''
                TabColor           = ''
                InProfile          = $false
                Enabled            = $false   # not in profile → can't be enabled
                Materialized       = $true
                DistroMaterialized = $am.distro
                HostMaterialized   = $am.host
            }
        }
    }
    return ,$rows
}

function Get-ProjectTypesLabel {
    # 'distro' / 'host' / 'distro+host' / '-' from a project list row's halves.
    [CmdletBinding()] param([Parameter(Mandatory)]$Row)
    $parts = @()
    if ($Row.HasDistro) { $parts += 'distro' }
    if ($Row.HasHost)   { $parts += 'host' }
    if ($parts.Count -eq 0) { return '-' }
    return ($parts -join '+')
}

function Get-ProjectStateLabel {
    # present / partial / missing — folds per-half materialization against the
    # halves the project declares (or, for not-in-profile rows, what's there).
    [CmdletBinding()] param([Parameter(Mandatory)]$Row)
    $expected = @()
    if ($Row.HasDistro) { $expected += [bool]$Row.DistroMaterialized }
    if ($Row.HasHost)   { $expected += [bool]$Row.HostMaterialized }
    if ($expected.Count -eq 0) {
        if ($Row.Materialized) { return 'present' } else { return 'missing' }
    }
    $have = @($expected | Where-Object { $_ }).Count
    if ($have -eq 0) { return 'missing' }
    if ($have -eq $expected.Count) { return 'present' }
    return 'partial'
}

function Invoke-ProjectList {
    $distro = Resolve-DistroForOps
    $rows = Get-ProjectListRows -DistroName $distro
    if ($rows.Count -eq 0) {
        Write-Host '  (no projects)' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host ('  {0,-18} {1,-12} {2,-44} {3,-10} {4,-8} {5}' -f 'Name','Types','Remote / Checkout','Default','Enabled','State')
    Write-Host ('  {0,-18} {1,-12} {2,-44} {3,-10} {4,-8} {5}' -f '----','-----','-----------------','-------','-------','-----')
    foreach ($r in $rows) {
        $enabled  = if (-not $r.InProfile) { '-' } elseif ($r.Enabled) { 'yes' } else { 'no' }
        $detail   = if ($r.Remote) { $r.Remote } elseif ($r.HostCheckout) { $r.HostCheckout } else { '' }
        Write-Host ('  {0,-18} {1,-12} {2,-44} {3,-10} {4,-8} {5}' -f $r.Name, (Get-ProjectTypesLabel -Row $r), $detail, $r.DefaultBranch, $enabled, (Get-ProjectStateLabel -Row $r))
    }
}

function Invoke-ProjectShow {
    if (-not $Arg) { throw "project show requires a project name." }
    $distro = Resolve-DistroForOps
    $rows = Get-ProjectListRows -DistroName $distro
    $r = $rows | Where-Object { $_.Name -eq $Arg } | Select-Object -First 1
    if (-not $r) {
        Write-Host "  Project '$Arg' not found." -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host "Project: $($r.Name)"
    Write-Host "  Types:          $(Get-ProjectTypesLabel -Row $r)"
    Write-Host "  Default branch: $($r.DefaultBranch)"
    Write-Host "  Tab color:      $(if ($r.TabColor) { $r.TabColor } else { '(none)' })"
    Write-Host "  In profile:     $($r.InProfile)"
    if ($r.InProfile) {
        $disabledHint = if (-not $r.Enabled) { '  (run reconcile to tear the materialized state down)' } else { '' }
        Write-Host "  Enabled:        $($r.Enabled)$disabledHint"
    }
    # Resolve the project's user/home so the displayed paths match where the
    # halves actually live (per-project-user isolation, legacy claude fallback).
    $pu = if (Test-State -DistroName $distro) {
        Resolve-ProjectUserHome -State (Read-State -DistroName $distro) -Project $r.Name
    } else { @{ Home = '/home/claude' } }
    if ($r.HasDistro -or $r.DistroMaterialized) {
        $dm = if ($r.DistroMaterialized) { 'present' } else { 'missing' }
        Write-Host "  Distro half:    remote=$($r.Remote)  [$dm]"
        if ($r.DistroMaterialized) {
            Write-Host "    mirror:       $($pu.Home)/mirrors/$($r.Name).git"
        }
    }
    if ($r.HasHost -or $r.HostMaterialized) {
        $hm = if ($r.HostMaterialized) { 'present' } else { 'missing' }
        $hc = if ($r.HostCheckout) { $r.HostCheckout } else { '(unknown — not in profile)' }
        Write-Host "  Host half:      hostCheckout=$hc  [$hm]"
        if ($r.HostMaterialized) {
            Write-Host "    bin dir:      $($pu.Home)/host-projects/$($r.Name)/bin"
        }
    }
    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        $sessions = Get-Sessions -State $state -Project $r.Name
        if ($sessions.Count -gt 0) {
            Write-Host "  Sessions:"
            foreach ($s in $sessions) {
                Write-Host ("    - {0,-20} [{1,-6}] branch={2}" -f $s.name, (Get-SessionType -Session $s), $s.branch)
            }
        }
    }
}

function Invoke-ProjectRemove {
    if (-not $Arg) { throw "project remove requires a project name." }
    $distro = Resolve-DistroForOps
    $name   = $Arg

    $spec    = Read-ProfileIfPresent
    $entry   = $null
    if ($spec -and $spec.ContainsKey('projects') -and $spec.projects) {
        # Wrap in @() before piping — gotcha #2: single-element JSON arrays
        # unwrap to the bare hashtable, which iterates as a string-keyed enum
        # under StrictMode if a caller ever switches to a `foreach` form.
        $entry = @(@($spec.projects) | Where-Object { [string]$_.name -eq $name })[0]
    }
    # A full project remove tears down EVERY half it has. For a drift entry
    # (absent from the profile) we don't know its shape, so attempt both
    # teardowns — Remove-ProjectMirror / Remove-HostShadowsForProject are rm -rf
    # and harmless when their target isn't present.
    $halves = if ($entry) { Get-ProjectHalves -ProjectSpec $entry } else { @{ Distro = $true; Host = $true } }
    $typeParts = @(); if ($halves.Distro) { $typeParts += 'distro' }; if ($halves.Host) { $typeParts += 'host' }
    $typesStr = if ($typeParts.Count) { $typeParts -join '+' } else { 'unknown' }

    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Remove project '$name' (${typesStr}: bare mirror and/or host bin dir + all sessions + profile entry)? hostCheckout itself stays untouched." -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    $state = if (Test-State -DistroName $distro) { Read-State -DistroName $distro } else { $null }
    $r = if ($state) { Resolve-ProjectUserHome -State $state -Project $name } else { @{ User = 'claude'; Home = '/home/claude'; Record = $null } }
    $distroExists = Test-DistroExists -Name $distro

    # ---- Host half teardown (worktree removals need the profile entry's hostCheckout) ----
    if ($halves.Host) {
        if ($state -and $entry) {
            $sessionNames = @()
            foreach ($s in (Get-Sessions -State $state -Project $name)) {
                if ($s -is [hashtable] -and $s.ContainsKey('name') -and (Get-SessionType -Session $s) -eq 'host') {
                    $sessionNames += [string]$s.name
                }
            }
            foreach ($sname in $sessionNames) {
                try { Remove-HostSession -State $state -ProjectSpec $entry -Name $sname -Force:$Force }
                catch { Write-Host "  warn: could not remove session '$sname': $_" -ForegroundColor Yellow }
            }
        }
        if ($distroExists) {
            Write-Host "  Removing host bin dir $($r.Home)/host-projects/$name ..."
            Remove-HostShadowsForProject -DistroName $distro -ProjectName $name -User $r.User -Home $r.Home
        }
    }

    # ---- Distro half teardown ----
    if ($halves.Distro -and $distroExists -and (Test-ProjectMirrorExists -DistroName $distro -ProjectName $name -User $r.User -Home $r.Home)) {
        Write-Host "  Removing bare mirror $($r.Home)/mirrors/$name.git ..."
        Remove-ProjectMirror -DistroName $distro -ProjectName $name -User $r.User -Home $r.Home
    }

    # ---- Sessions + user + profile ----
    if ($state) {
        Remove-SessionsForProject -State $state -Project $name   # clears any remaining session of either half
        if ($distroExists -and $r.Record) {
            Write-Host "  deleting project user '$($r.User)' ..."
            [void](Remove-ProjectUserInDistro -DistroName $distro -User $r.User)
            [void](Remove-ProjectUserRecord -State $state -Project $name)
        }
        Write-State -DistroName $distro -State $state
        # Drop the just-removed host sessions' mount entries from the fstab block.
        if ($halves.Host -and $distroExists) { Invoke-MergedMountsApply -DistroName $distro }
    }
    $removed = Remove-ProjectFromProfile -ProfilePath (Resolve-ProfilePath) -Name $name
    if ($removed) { Write-Host "  Removed from profile." }
    Write-Host "Project '$name' removed." -ForegroundColor Green
}

function Invoke-ProjectAddHalf {
    # Non-destructively add the distro or host capability to an existing project,
    # making it dual-capability (or simply giving a single-half project its other
    # side). Repurposes the old `project move` engine, minus the teardown: the
    # existing half is untouched, the new half is wired into the profile and then
    # materialized (clone mirror / deploy bin dir) under the project's existing
    # Linux user + home.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('distro','host')][string]$Half)
    if (-not $Arg) { throw "project add-$Half requires a project name." }
    $distro = Resolve-DistroForOps
    $name   = $Arg
    $profilePathLocal = Resolve-ProfilePath

    $spec = Read-ProfileIfPresent
    if (-not $spec -or -not $spec.ContainsKey('projects') -or -not $spec.projects) {
        throw "No projects in the profile."
    }
    $entry = @(@($spec.projects) | Where-Object { [string]$_.name -eq $name })[0]
    if (-not $entry) { throw "Project '$name' not found in profile. Use 'project add' to create it first." }
    $halves = Get-ProjectHalves -ProjectSpec $entry

    $targetRemote = $null; $targetHostCheckout = $null; $shadowOverride = $null
    if ($Half -eq 'host') {
        if ($halves.Host) { throw "Project '$name' already has a host half (hostCheckout '$([string]$entry.hostCheckout)')." }
        if (-not $HostCheckout) {
            throw "Adding a host half to '$name' requires -HostCheckout (the Windows path of the user's main checkout)."
        }
        if (-not (Test-HostCheckout -HostCheckout $HostCheckout)) {
            throw "HostCheckout '$HostCheckout' does not exist or is not a git working tree (no .git)."
        }
        $targetHostCheckout = $HostCheckout
        # `(if ...)` as an inline argument isn't valid PowerShell; bind first.
        if ($Script:RootBoundParams.ContainsKey('HostShadows')) { $shadowOverride = $HostShadows }
    }
    else {
        if ($halves.Distro) { throw "Project '$name' already has a distro half (remote '$([string]$entry.remote)')." }
        $targetRemote = $Remote
        if (-not $targetRemote -and $halves.Host) {
            # Derive the remote from the existing host checkout when possible.
            $hc = [string]$entry.hostCheckout
            $auto = if ($hc) { Resolve-SmartRemote -HostCheckout $hc } else { $null }
            if ($auto) {
                Write-Host "  smart-detected remote from hostCheckout: $auto" -ForegroundColor DarkGray
                $targetRemote = $auto
            }
        }
        if (-not $targetRemote) {
            throw "Adding a distro half to '$name' requires -Remote (couldn't smart-detect 'origin')."
        }
    }

    $distroExists = Test-DistroExists -Name $distro

    # ---- Profile mutation ----
    Add-ProjectHalfInProfile -ProfilePath $profilePathLocal -Name $name -Half $Half `
        -Remote $targetRemote -HostCheckout $targetHostCheckout -HostShadows $shadowOverride
    Write-Host "  Added $Half half to '$name' in the profile." -ForegroundColor Green

    if (-not $distroExists) {
        Write-Host "  Distro '$distro' doesn't exist yet — the new half will materialize on next setup/reconcile." -ForegroundColor Yellow
        return
    }

    # The new half shares the project's existing user/home. -Create covers the
    # edge case of a profile entry that was never materialized; New-ProjectUser
    # InDistro is idempotent for the already-provisioned case.
    #
    # Materialization (clone / bin-dir deploy) is fallible. Since the profile was
    # already mutated above, a failure here would leave the entry declaring a half
    # that isn't materialized. Roll the profile change back on failure so the verb
    # is re-runnable (the other half — always present, see the guards above —
    # means Remove-ProjectHalfInProfile won't hit its last-half refusal).
    try {
        $state = if (Test-State -DistroName $distro) { Read-State -DistroName $distro } else { Initialize-State -DistroName $distro }
        $r = Resolve-ProjectUserHome -State $state -Project $name -DistroName $distro -Create
        if ($r.Record) {
            New-ProjectUserInDistro -DistroName $distro -User $r.User -Uid $r.Uid -Password ([string]$r.Record.password)
            Write-State -DistroName $distro -State $state
        }
        $freshEntry = @(@((Read-ProfileIfPresent).projects) | Where-Object { [string]$_.name -eq $name })[0]
        if ($Half -eq 'host') {
            Write-Host "  Resolving host shadows + deploying bin dir ..."
            Invoke-HostProjectApply -DistroName $distro -ProjectSpec $freshEntry -User $r.User -Home $r.Home
        }
        else {
            Write-Host "  Cloning $targetRemote -> $($r.Home)/mirrors/$name.git ..."
            New-ProjectMirror -DistroName $distro -ProjectName $name -Remote $targetRemote -User $r.User -Home $r.Home
            $db = if ($freshEntry -and $freshEntry.ContainsKey('defaultBranch') -and $freshEntry.defaultBranch) { [string]$freshEntry.defaultBranch } else { 'master' }
            Write-Host "  Creating main/ checkout on '$db' ..."
            New-ProjectMainCheckout -DistroName $distro -ProjectName $name -Branch $db -User $r.User -Home $r.Home
        }
        if ($r.Record) {
            Initialize-ProjectUserClaudeConfig -DistroName $distro -User $r.User -Home $r.Home -Spec (Read-ProfileIfPresent)
        }
    }
    catch {
        Write-Host "  materialization failed; reverting the $Half half in the profile..." -ForegroundColor Yellow
        try { Remove-ProjectHalfInProfile -ProfilePath $profilePathLocal -Name $name -Half $Half } catch {
            Write-Host "    revert warn: $_ (remove the half's field from the profile by hand)" -ForegroundColor DarkYellow
        }
        throw
    }
    Write-Host "Project '$name' now has a $Half half. 'session new -Project $name' will prompt for the session type." -ForegroundColor Green
}

function Invoke-ProjectDropHalf {
    # Non-destructively remove one capability from a dual-capability project,
    # keeping the other half AND the project's Linux user/home. Tears down only
    # the dropped half's materialized state + its sessions (dirty-session
    # guarded, like the old `project move`). Refuses to drop the last half —
    # that's `project remove`, which also deletes the Linux user.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('distro','host')][string]$Half)
    if (-not $Arg) { throw "project drop-$Half requires a project name." }
    $distro = Resolve-DistroForOps
    $name   = $Arg
    $profilePathLocal = Resolve-ProfilePath

    $spec = Read-ProfileIfPresent
    if (-not $spec -or -not $spec.ContainsKey('projects') -or -not $spec.projects) {
        throw "No projects in the profile."
    }
    $entry = @(@($spec.projects) | Where-Object { [string]$_.name -eq $name })[0]
    if (-not $entry) { throw "Project '$name' not found in profile." }
    $halves = Get-ProjectHalves -ProjectSpec $entry
    if ($Half -eq 'host'   -and -not $halves.Host)   { throw "Project '$name' has no host half to drop." }
    if ($Half -eq 'distro' -and -not $halves.Distro) { throw "Project '$name' has no distro half to drop." }
    if (($Half -eq 'host' -and -not $halves.Distro) -or ($Half -eq 'distro' -and -not $halves.Host)) {
        throw "Project '$name' has only a $Half half; use 'project remove $name' to delete the whole project (that also removes its Linux user)."
    }

    $state = if (Test-State -DistroName $distro) { Read-State -DistroName $distro } else { $null }
    $r = if ($state) { Resolve-ProjectUserHome -State $state -Project $name } else { @{ User = 'claude'; Home = '/home/claude'; Record = $null } }
    $distroExists = Test-DistroExists -Name $distro

    # Dirty-session guard, scoped to the half being dropped.
    $dirtySessions = @()
    if ($state) {
        foreach ($s in (Get-Sessions -State $state -Project $name)) {
            if ((Get-SessionType -Session $s) -ne $Half) { continue }
            $dirty = 0
            if ($Half -eq 'host') {
                $hostWt = if ($s.ContainsKey('hostWorktreePath')) { [string]$s.hostWorktreePath } else { $null }
                if ($hostWt -and (Test-Path -LiteralPath $hostWt)) {
                    try {
                        $out = & git -C $hostWt status --porcelain 2>$null
                        if ($LASTEXITCODE -eq 0) { $dirty = @($out).Count }
                    } catch {}
                }
            }
            else {
                $dirty = Get-SessionDirtyFileCount -DistroName $distro -Project $name -Name ([string]$s.name) -User $r.User -Home $r.Home
            }
            if ($dirty -gt 0) { $dirtySessions += [PSCustomObject]@{ Name = [string]$s.name; Dirty = $dirty } }
        }
    }
    if ($dirtySessions.Count -gt 0 -and -not $DiscardDirty -and -not $Force) {
        Write-Host "  $Half sessions with uncommitted work:" -ForegroundColor Yellow
        foreach ($d in $dirtySessions) {
            Write-Host ("    {0,-22} {1} file(s)" -f $d.Name, $d.Dirty) -ForegroundColor Yellow
        }
        throw "Refusing to drop the $Half half of '$name' — commit/stash the above sessions first, or pass -DiscardDirty to lose the work."
    }

    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Drop the $Half half of '$name' (its materialized state + $Half sessions)? The other half stays." -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    # Profile snapshot for hand-recovery (millisecond precision so rapid retries
    # don't clobber an earlier snapshot — Copy-Item overwrites without error).
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $backupPath = "$profilePathLocal.bak-$stamp"
    Copy-Item -LiteralPath $profilePathLocal -Destination $backupPath -ErrorAction Stop
    Write-Host "  Snapshot saved: $(Split-Path -Leaf $backupPath)" -ForegroundColor DarkGray

    # ---- Teardown of the dropped half only ----
    if ($state) {
        if ($Half -eq 'host') {
            $sessionNames = @()
            foreach ($s in (Get-Sessions -State $state -Project $name)) {
                if ($s -is [hashtable] -and $s.ContainsKey('name') -and (Get-SessionType -Session $s) -eq 'host') {
                    $sessionNames += [string]$s.name
                }
            }
            foreach ($sname in $sessionNames) {
                try { Remove-HostSession -State $state -ProjectSpec $entry -Name $sname -Force }
                catch { Write-Host "    warn: could not remove session '$sname': $_" -ForegroundColor Yellow }
            }
            Remove-SessionsForProject -State $state -Project $name -Type host
            if ($distroExists) {
                Write-Host "  Removing host bin dir $($r.Home)/host-projects/$name ..."
                Remove-HostShadowsForProject -DistroName $distro -ProjectName $name -User $r.User -Home $r.Home
            }
        }
        else {
            if ($distroExists -and (Test-ProjectMirrorExists -DistroName $distro -ProjectName $name -User $r.User -Home $r.Home)) {
                Write-Host "  Removing bare mirror $($r.Home)/mirrors/$name.git ..."
                Remove-ProjectMirror -DistroName $distro -ProjectName $name -User $r.User -Home $r.Home
            }
            Remove-SessionsForProject -State $state -Project $name -Type distro
        }
        Write-State -DistroName $distro -State $state
        if ($Half -eq 'host' -and $distroExists) { Invoke-MergedMountsApply -DistroName $distro }
    }

    # ---- Profile mutation ----
    Remove-ProjectHalfInProfile -ProfilePath $profilePathLocal -Name $name -Half $Half
    Write-Host "Project '$name': $Half half dropped. The other half is unchanged." -ForegroundColor Green
}

function Invoke-ProjectDashboardAddHalf {
    # Dashboard 'a <n>' — interactively gather the inputs for the missing half
    # and delegate to Invoke-ProjectAddHalf (sets the script-scoped params it
    # reads: $Arg + $Remote / $HostCheckout).
    [CmdletBinding()] param([Parameter(Mandatory)]$Row)
    if (-not $Row.InProfile) {
        Write-Host "  '$($Row.Name)' is not in the profile; nothing to add a half to." -ForegroundColor Yellow
        return
    }
    if ($Row.HasDistro -and $Row.HasHost) {
        Write-Host "  '$($Row.Name)' already has both halves." -ForegroundColor Yellow
        return
    }
    $missing = if ($Row.HasDistro) { 'host' } else { 'distro' }
    $script:Arg = $Row.Name
    if ($missing -eq 'host') {
        $hc = (Read-Host "  Host checkout path for '$($Row.Name)' (e.g. C:\src\acme)").Trim()
        if (-not $hc) { Write-Host '  aborted (no checkout).' -ForegroundColor Yellow; return }
        $script:HostCheckout = $hc
        Show-DashboardAction "project add-host $($Row.Name)"
        Invoke-ProjectAddHalf -Half 'host'
    }
    else {
        $hint = if ($Row.HostCheckout) { Resolve-SmartRemote -HostCheckout $Row.HostCheckout } else { $null }
        $promptText = if ($hint) { "  Remote URL [$hint]" } else { "  Remote URL" }
        $rem = (Read-Host $promptText).Trim()
        if (-not $rem -and $hint) { $rem = $hint }
        if (-not $rem) { Write-Host '  aborted (no remote).' -ForegroundColor Yellow; return }
        $script:Remote = $rem
        Show-DashboardAction "project add-distro $($Row.Name)"
        Invoke-ProjectAddHalf -Half 'distro'
    }
}

function Invoke-ProjectDashboardDropHalf {
    # Dashboard 'x <n>' — pick which half to drop and delegate to
    # Invoke-ProjectDropHalf. Only valid for a dual-capability project.
    [CmdletBinding()] param([Parameter(Mandatory)]$Row)
    if (-not $Row.InProfile) {
        Write-Host "  '$($Row.Name)' is not in the profile." -ForegroundColor Yellow
        return
    }
    if (-not ($Row.HasDistro -and $Row.HasHost)) {
        Write-Host "  '$($Row.Name)' has a single half; use 'd' (remove project) instead." -ForegroundColor Yellow
        return
    }
    $which = (Read-Host "  Drop which half? [distro/host]").Trim().ToLowerInvariant()
    if ($which -notin @('distro','host')) { Write-Host '  aborted.' -ForegroundColor Yellow; return }
    $script:Arg = $Row.Name
    Show-DashboardAction "project drop-$which $($Row.Name)"
    Invoke-ProjectDropHalf -Half $which
}

function Invoke-ProjectDashboard {
    $distro = Resolve-DistroForOps
    Clear-Host
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: projects ===' -ForegroundColor Cyan
        $rows = Get-ProjectListRows -DistroName $distro
        if ($rows.Count -eq 0) {
            Write-Host '  (no projects)' -ForegroundColor DarkGray
        }
        else {
            Write-Host ('  {0,-3} {1,-18} {2,-12} {3,-40} {4,-10} {5,-8} {6}' -f '#','Name','Types','Remote / Checkout','Default','Enabled','State')
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                $enabled = if (-not $r.InProfile) { '-' } elseif ($r.Enabled) { 'yes' } else { 'no' }
                $detail  = if ($r.Remote) { $r.Remote } elseif ($r.HostCheckout) { $r.HostCheckout } else { '' }
                Write-Host ('  {0,-3} {1,-18} {2,-12} {3,-40} {4,-10} {5,-8} {6}' -f ($i + 1), $r.Name, (Get-ProjectTypesLabel -Row $r), $detail, $r.DefaultBranch, $enabled, (Get-ProjectStateLabel -Row $r))
            }
        }
        Write-Host ''
        Write-Host '  +  add new project'
        Write-Host '  s <n>  show project'
        Write-Host '  t <n>  toggle enabled (reconcile to apply)'
        Write-Host '  a <n>  add the missing half (distro/host)'
        Write-Host '  x <n>  drop a half (keeps the other)'
        Write-Host '  d <n>  remove project'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q','')) { return }
        if ($a -eq '+') {
            Show-DashboardAction 'project add'
            $script:Arg = $null
            Invoke-ProjectAdd
            continue
        }
        if ($a -match '^([sdtax])\s+(\d+)$') {
            $cmd = $Matches[1]; $idx = [int]$Matches[2] - 1
            if ($idx -lt 0 -or $idx -ge $rows.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $row = $rows[$idx]
            $script:Arg = $row.Name
            switch ($cmd) {
                's' { Show-DashboardAction "project show $($script:Arg)"; Invoke-ProjectShow }
                'd' { Show-DashboardAction "project remove $($script:Arg)"; Invoke-ProjectRemove }
                'a' { Invoke-ProjectDashboardAddHalf -Row $row }
                'x' { Invoke-ProjectDashboardDropHalf -Row $row }
                't' {
                    if (-not $row.InProfile) {
                        Write-Host "  '$($row.Name)' is not in the profile; nothing to toggle." -ForegroundColor Yellow
                        break
                    }
                    $newEnabled = -not $row.Enabled
                    $word = if ($newEnabled) { 'enable' } else { 'disable' }
                    Show-DashboardAction "project $word $($script:Arg)"
                    if (Set-ProjectEnabledInProfile -ProfilePath (Resolve-ProfilePath) -Name $row.Name -Enabled $newEnabled) {
                        $verb = if ($newEnabled) { 'enabled' } else { 'disabled' }
                        Write-Host "  '$($row.Name)' marked $verb. Run 'reconcile' to apply." -ForegroundColor Green
                    }
                    else {
                        Write-Host "  '$($row.Name)' not found in profile." -ForegroundColor Yellow
                    }
                }
            }
            continue
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

function Invoke-Project {
    if (-not $SubVerb) { Invoke-ProjectDashboard; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'add'         { Invoke-ProjectAdd }
        'list'        { Invoke-ProjectList }
        'remove'      { Invoke-ProjectRemove }
        'add-distro'  { Invoke-ProjectAddHalf  -Half 'distro' }
        'add-host'    { Invoke-ProjectAddHalf  -Half 'host' }
        'drop-distro' { Invoke-ProjectDropHalf -Half 'distro' }
        'drop-host'   { Invoke-ProjectDropHalf -Half 'host' }
        'show'        { Invoke-ProjectShow }
        default {
            Write-Host "Unknown project subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: add | list | remove | add-distro | add-host | drop-distro | drop-host | show (or bare 'project' for the dashboard)"
            exit 64
        }
    }
}

function Invoke-SessionNew {
    if (-not $Arg)     { throw "session new requires a session name." }
    if (-not $Project) { throw "session new requires -Project." }
    # -Branch is required only for host sessions (still per-session worktrees).
    # Distro sessions open into the project's persistent main/ checkout — no
    # branch is chosen at creation; Claude creates worktrees for work branches.

    $distro = Resolve-DistroForOps
    $state = Read-State -DistroName $distro

    # Look up the project's profile entry to decide distro-vs-host wiring.
    $spec = Read-ProfileIfPresent
    $projectEntry = $null
    if ($spec -and $spec.ContainsKey('projects') -and $spec.projects) {
        $projectEntry = @(@($spec.projects) | Where-Object { [string]$_.name -eq $Project })[0]
    }
    # Capability-by-presence: a project may offer a distro half, a host half, or
    # both. Resolve which kind of session to create.
    $halves = Get-ProjectHalves -ProjectSpec $projectEntry
    if (-not $halves.Distro -and -not $halves.Host) {
        throw "Project '$Project' is not in the profile (or declares no half). Run 'project add' first."
    }
    $projType = $null
    if ($SessionType) {
        $projType = $SessionType
        if ($projType -eq 'host'   -and -not $halves.Host)   { throw "Project '$Project' has no host half; cannot create a host session. Add one with 'project add-host'." }
        if ($projType -eq 'distro' -and -not $halves.Distro) { throw "Project '$Project' has no distro half; cannot create a distro session. Add one with 'project add-distro'." }
    }
    elseif ($halves.Distro -and $halves.Host) {
        if ($NonInteractive) { throw "Project '$Project' offers both a distro and a host half; pass -SessionType <distro|host>." }
        $choice = (Read-Host "  Session type for '$Project'? [distro/host]").Trim().ToLowerInvariant()
        if ($choice -notin @('distro','host')) { throw "Expected 'distro' or 'host' (got '$choice')." }
        $projType = $choice
    }
    else {
        $projType = if ($halves.Host) { 'host' } else { 'distro' }
    }
    # Resolve the project's dedicated user/home (legacy claude fallback when the
    # project predates the users map).
    $pu = Resolve-ProjectUserHome -State $state -Project $Project

    $defaultBranch = if ($projectEntry -and $projectEntry.ContainsKey('defaultBranch') -and $projectEntry.defaultBranch) {
        [string]$projectEntry.defaultBranch
    } else { 'master' }

    Write-Host ''
    Write-Host "  Project:  $Project ($projType session)"
    Write-Host "  Session:  $Arg"
    if ($projType -eq 'host' -and $Branch) { Write-Host "  Branch:   $Branch  (work worktree)" }
    elseif ($projType -eq 'host')          { Write-Host "  Opens in: host/main  (curation checkout)" }
    else { Write-Host "  Opens in: projects/$Project/main  (curation branch '$defaultBranch')" }

    if ($projType -eq 'host' -and -not $Branch) {
        # Curation launch-pad host session: opens into the hostCheckout mount
        # (host/main); no per-session worktree. For a work branch, pass -Branch
        # to create a sibling work worktree instead (the legacy path below).
        if (-not $projectEntry) { throw "hostProject '$Project' is not in the profile." }
        # Cleanup ladder (CLAUDE.md § Recurring traps: cleanup belongs in finally):
        # the record is committed before the mount/shadow apply, so a later failure
        # must drop the record + re-apply mounts so we don't leave a session with
        # no mount.
        $sessionRegistered = $false
        try {
            Register-Session -State $state -Project $Project -Name $Arg -Type 'host' | Out-Null
            $sessionRegistered = $true
            Add-Recent -State $state -Key 'sessionNames' -Value $Arg
            Write-State -DistroName $distro -State $state
            # Mount the hostCheckout at host/main + ensure the per-project bin dir / shadows.
            Invoke-MergedMountsApply -DistroName $distro
            Invoke-HostProjectApply -DistroName $distro -ProjectSpec $projectEntry -User $pu.User -Home $pu.Home
            $sessionRegistered = $false   # success: skip rollback
            $guest = Get-HostMainGuestPath -Home $pu.Home
            Write-Host "Session '$Project/$Arg' created; opens into the curation checkout at $guest" -ForegroundColor Green
        }
        finally {
            if ($sessionRegistered) {
                Write-Host "  session-new failed mid-flight; rolling back..." -ForegroundColor Yellow
                $state.sessions = @($state.sessions | Where-Object { -not ([string]$_.project -eq $Project -and [string]$_.name -eq $Arg) })
                try { Write-State -DistroName $distro -State $state } catch {
                    Write-Host "    rollback warn (state): $_" -ForegroundColor DarkYellow
                }
                try { Invoke-MergedMountsApply -DistroName $distro } catch {
                    Write-Host "    rollback warn (mounts): $_" -ForegroundColor DarkYellow
                }
            }
        }
        return
    }

    if ($projType -eq 'host') {
        if (-not $projectEntry) { throw "hostProject '$Project' is not in the profile." }
        # Cleanup ladder: if any step after the worktree creation throws, the
        # `finally` rolls the host-side state back so we don't leave a session
        # record + an orphaned worktree + no mount (CLAUDE.md § Recurring
        # traps: cleanup belongs in finally, always).
        $sessionRegistered = $false
        try {
            if ($NewBranch) {
                $b = if ($BaseBranch) { $BaseBranch } else { $defaultBranch }
                Write-Host "  New branch off: $b"
                New-HostSession -State $state -ProjectSpec $projectEntry -Name $Arg -Branch $Branch -NewBranch -BaseBranch $b -Home $pu.Home
            } else {
                New-HostSession -State $state -ProjectSpec $projectEntry -Name $Arg -Branch $Branch -Home $pu.Home
            }
            $sessionRegistered = $true
            Add-Recent -State $state -Key 'sessionNames' -Value $Arg
            Add-Recent -State $state -Key 'branches'     -Value $Branch
            Write-State -DistroName $distro -State $state
            # Mount the new host worktree into the distro.
            Invoke-MergedMountsApply -DistroName $distro
            # Make sure the per-project bin dir + shadows are present (idempotent).
            # When project add was run on a non-existent distro, the shadows are
            # deferred to first session — apply them here.
            Invoke-HostProjectApply -DistroName $distro -ProjectSpec $projectEntry -User $pu.User -Home $pu.Home
            $sessionRegistered = $false   # success: skip rollback
            $guest = Get-HostSessionGuestMountPath -Project $Project -Name $Arg -Home $pu.Home
            Write-Host "Session '$Project/$Arg' created; host worktree mounted at $guest" -ForegroundColor Green
        }
        finally {
            if ($sessionRegistered) {
                Write-Host "  session-new failed mid-flight; rolling back..." -ForegroundColor Yellow
                try { Remove-HostSession -State $state -ProjectSpec $projectEntry -Name $Arg -Force } catch {
                    Write-Host "    rollback warn (worktree): $_" -ForegroundColor DarkYellow
                }
                try { Write-State -DistroName $distro -State $state } catch {
                    Write-Host "    rollback warn (state): $_" -ForegroundColor DarkYellow
                }
                try { Invoke-MergedMountsApply -DistroName $distro } catch {
                    Write-Host "    rollback warn (mounts): $_" -ForegroundColor DarkYellow
                }
            }
        }
        return
    }

    if ($Branch -or $NewBranch) {
        Write-Host "  note: -Branch/-NewBranch is ignored for distro sessions — open into main/ and 'git worktree add' for work branches." -ForegroundColor DarkYellow
    }
    # Ensure the persistent main/ checkout exists (curation launch pad), then
    # register a tmux-backed launch-pad session (no per-session worktree).
    if (-not (Test-ProjectMainCheckoutExists -DistroName $distro -ProjectName $Project -User $pu.User -Home $pu.Home)) {
        Write-Host "  creating main/ checkout on '$defaultBranch' ..."
        New-ProjectMainCheckout -DistroName $distro -ProjectName $Project -Branch $defaultBranch -User $pu.User -Home $pu.Home
    }
    Register-Session -State $state -Project $Project -Name $Arg -Type 'distro' | Out-Null
    Add-Recent -State $state -Key 'sessionNames' -Value $Arg
    Write-State -DistroName $distro -State $state
    Write-Host "Session '$Project/$Arg' created; opens into $($pu.Home)/projects/$Project/main" -ForegroundColor Green
}

function Get-SessionRows {
    # Session rows with tmux liveness Status (attached | detached | dead). The
    # branch/dirty columns are gone: a session no longer owns a worktree (it
    # opens into the project's main/ checkout and Claude creates worktrees for
    # work — see 'prune worktrees' / the launcher's worktree view).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName, [string]$ProjectFilter)
    if (-not (Test-State -DistroName $DistroName)) { return @() }
    $state = Read-State -DistroName $DistroName
    # Materialize via foreach (Get-Sessions returns through the `,$all` idiom;
    # @()-wrapping it nests the whole array as a single element).
    $sessions = @(); foreach ($s in (Get-Sessions -State $state -Project $ProjectFilter)) { $sessions += $s }
    $live = Get-LiveTmuxForState -DistroName $DistroName -State $state
    $liveness = Resolve-SessionLiveness -Sessions $sessions -LiveTmux $live
    $statusByKey = @{}
    foreach ($t in $liveness.Tracked) { $statusByKey["$($t.Project)/$($t.Name)"] = [string]$t.Status }
    $rows = @()
    foreach ($s in $sessions) {
        $status = $statusByKey["$([string]$s.project)/$([string]$s.name)"]
        if (-not $status) { $status = 'dead' }
        $rows += [PSCustomObject]@{
            Project       = [string]$s.project
            Name          = [string]$s.name
            Type          = (Get-SessionType -Session $s)
            Status        = $status
            CreatedAt     = [string]$s.createdAt
            LastOpenedAt  = if ($s.ContainsKey('lastOpenedAt')) { [string]$s.lastOpenedAt } else { '' }
        }
    }
    return ,$rows
}

function Invoke-SessionList {
    $distro = Resolve-DistroForOps
    $rows = Get-SessionRows -DistroName $distro -ProjectFilter $Project
    if ($rows.Count -eq 0) {
        Write-Host '  (no sessions)' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host ('  {0,-16} {1,-20} {2,-7} {3,-10} {4}' -f 'Project','Session','Type','Status','Created')
    Write-Host ('  {0,-16} {1,-20} {2,-7} {3,-10} {4}' -f '-------','-------','----','------','-------')
    foreach ($r in $rows) {
        Write-Host ('  {0,-16} {1,-20} {2,-7} {3,-10} {4}' -f $r.Project, $r.Name, $r.Type, $r.Status, $r.CreatedAt)
    }
}

function Invoke-SessionRemove {
    if (-not $Arg)     { throw "session remove requires a session name." }
    if (-not $Project) { throw "session remove requires -Project." }
    $distro = Resolve-DistroForOps
    $state = Read-State -DistroName $distro

    $spec = Read-ProfileIfPresent
    $projectEntry = $null
    if ($spec -and $spec.ContainsKey('projects') -and $spec.projects) {
        $projectEntry = @(@($spec.projects) | Where-Object { [string]$_.name -eq $Project })[0]
    }
    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Remove session '$Project/$Arg'?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    # The helper returns the type it actually torn down — using that for the
    # success message keeps the profile-vs-session-record paths from
    # disagreeing on the orphan-cleanup case.
    $pu = Resolve-ProjectUserHome -State $state -Project $Project
    $result = Remove-SessionByName -DistroName $distro -State $state -Project $Project -Name $Arg `
        -ProjectSpec $projectEntry -ProfileSpec $spec -Force:$Force -User $pu.User -Home $pu.Home
    Write-State -DistroName $distro -State $state
    if ($result.Type -eq 'host') {
        Write-Host "Session '$Project/$Arg' removed (host worktree + mount)." -ForegroundColor Green
    }
    else {
        Write-Host "Session '$Project/$Arg' removed." -ForegroundColor Green
    }
}

function Invoke-SessionDashboard {
    $distro = Resolve-DistroForOps
    Clear-Host
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: sessions ===' -ForegroundColor Cyan
        $rows = Get-SessionRows -DistroName $distro -ProjectFilter $Project
        if ($rows.Count -eq 0) {
            Write-Host '  (no sessions)' -ForegroundColor DarkGray
        }
        else {
            Write-Host ('  {0,-3} {1,-16} {2,-20} {3,-7} {4,-10} {5}' -f '#','Project','Session','Type','Status','Last opened')
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                $lo = if ($r.LastOpenedAt) { $r.LastOpenedAt } else { '(never)' }
                Write-Host ('  {0,-3} {1,-16} {2,-20} {3,-7} {4,-10} {5}' -f ($i + 1), $r.Project, $r.Name, $r.Type, $r.Status, $lo)
            }
        }
        Write-Host ''
        Write-Host '  d <n>  remove session'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q','')) { return }
        if ($a -match '^d\s+(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -lt 0 -or $idx -ge $rows.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $script:Arg     = $rows[$idx].Name
            $script:Project = $rows[$idx].Project
            Show-DashboardAction "session remove $($script:Project)/$($script:Arg)"
            Invoke-SessionRemove
            continue
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

function Invoke-Session {
    if (-not $SubVerb) { Invoke-SessionDashboard; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'new'    { Invoke-SessionNew }
        'list'   { Invoke-SessionList }
        'remove' { Invoke-SessionRemove }
        default {
            Write-Host "Unknown session subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: new | list | remove (or bare 'session' for the dashboard)"
            exit 64
        }
    }
}

function Get-MountRows {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $spec = $null
    try { $spec = Read-ProfileIfPresent } catch { }

    $desired = @()
    if ($spec -and $spec.ContainsKey('hostMounts') -and $null -ne $spec.hostMounts) {
        $desired = @($spec.hostMounts)
    }
    $actual = @()
    if (Test-DistroExists -Name $DistroName) {
        $actual = Get-HostMountsActualFromDistro -DistroName $DistroName
    }
    $actualByGuest = @{}; foreach ($a in $actual) { $actualByGuest[[string]$a.guest] = $a }

    $rows = @()
    $seen = @{}
    foreach ($m in $desired) {
        $g = [string]$m.guest
        $seen[$g] = $true
        $rows += [PSCustomObject]@{
            Guest        = $g
            HostPath     = [string]$m.host
            Mode         = if ($m.ContainsKey('mode') -and $m.mode) { [string]$m.mode } else { 'ro' }
            Options      = if ($m.ContainsKey('options') -and $m.options) { [string]$m.options } else { '' }
            InProfile    = $true
            Materialized = $actualByGuest.ContainsKey($g)
        }
    }
    foreach ($a in $actual) {
        $g = [string]$a.guest
        if (-not $seen.ContainsKey($g)) {
            $rows += [PSCustomObject]@{
                Guest        = $g
                HostPath     = [string]$a.host
                Mode         = [string]$a.mode
                Options      = if ($a.ContainsKey('options') -and $a.options) { [string]$a.options } else { '' }
                InProfile    = $false
                Materialized = $true
            }
        }
    }
    return ,$rows
}

function Invoke-MountAdd {
    $distro    = Resolve-DistroForOps
    $hostP     = if ($HostPath) { $HostPath } else { $Arg }
    $guestP    = $Guest
    $modeP     = $Mode
    $extraOpts = $MountOptions

    if (-not $hostP) {
        if ($NonInteractive) { throw "mount add requires a host path (positional or -HostPath)." }
        $hostP = (Read-Host 'Host path').Trim()
        if (-not $hostP) { throw 'Host path is required.' }
    }
    if (-not (Test-HostPathExists -Path $hostP)) {
        Write-Host "  Host path does not exist: $hostP" -ForegroundColor Yellow
        if (-not $NonInteractive) {
            $ok = Read-YesNo -Prompt 'Add anyway (mount -a will fail until path exists)?' -Default $false
            if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
        }
    }

    if (-not $guestP) {
        $derived = Resolve-DefaultGuestPath -HostPath $hostP
        if ($NonInteractive) { $guestP = $derived }
        else {
            $entry = Read-Host "Guest path [$derived]"
            $guestP = if ([string]::IsNullOrWhiteSpace($entry)) { $derived } else { $entry.Trim() }
        }
    }
    if (-not $guestP.StartsWith('/')) { throw "Guest path '$guestP' must be absolute." }

    if (-not $modeP) {
        if ($NonInteractive) { $modeP = 'ro' }
        else {
            $entry = Read-Host 'Mode [ro/rw] (default: ro)'
            $modeP = if ([string]::IsNullOrWhiteSpace($entry)) { 'ro' } else { $entry.Trim().ToLowerInvariant() }
        }
    }
    if ($modeP -notin @('ro','rw')) { throw "Mode must be 'ro' or 'rw'." }

    if (-not $extraOpts) {
        if (-not $NonInteractive) {
            $entry = Read-Host 'Extra drvfs options (e.g. umask=077 for ~/.ssh; blank to skip)'
            if (-not [string]::IsNullOrWhiteSpace($entry)) { $extraOpts = $entry.Trim() }
        }
    }

    Write-Host ''
    Write-Host "  Host:    $hostP"
    Write-Host "  Guest:   $guestP"
    Write-Host "  Mode:    $modeP"
    if ($extraOpts) { Write-Host "  Options: $extraOpts" }

    if (-not $NonInteractive) {
        $ok = Read-YesNo -Prompt 'Add this mount?' -Default $true
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    $entry = @{ host = $hostP; guest = $guestP; mode = $modeP }
    if ($extraOpts) { $entry.options = $extraOpts }

    Add-MountToProfile -ProfilePath (Resolve-ProfilePath) -MountSpec $entry
    Write-Host "  Added to profile." -ForegroundColor Green

    if (-not (Test-DistroExists -Name $distro)) {
        Write-Host "  Distro '$distro' does not exist yet — mount will apply on next 'setup'/'reconcile'." -ForegroundColor Yellow
        return
    }

    # Merge profile mounts with session-derived host-project mounts so this
    # apply doesn't wipe live host-session mounts out of fstab.
    Invoke-MergedMountsApply -DistroName $distro

    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        Add-Recent -State $state -Key 'hostMountPaths' -Value $hostP
        Write-State -DistroName $distro -State $state
    }
    Write-Host "Mount '$guestP' added." -ForegroundColor Green
}

function Invoke-MountList {
    $distro = Resolve-DistroForOps
    $rows = Get-MountRows -DistroName $distro
    if ($rows.Count -eq 0) {
        Write-Host '  (no mounts)' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host ('  {0,-30} {1,-50} {2,-4} {3,-10} {4}' -f 'Guest','Host','Mode','InProfile','Mounted')
    Write-Host ('  {0,-30} {1,-50} {2,-4} {3,-10} {4}' -f '-----','----','----','---------','-------')
    foreach ($r in $rows) {
        Write-Host ('  {0,-30} {1,-50} {2,-4} {3,-10} {4}' -f $r.Guest, $r.HostPath, $r.Mode, $r.InProfile, $r.Materialized)
    }
}

function Invoke-MountRemove {
    if (-not $Arg) { throw "mount remove requires a guest path." }
    $distro = Resolve-DistroForOps
    $g      = $Arg

    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Remove mount '$g' (umount + drop fstab entry + profile entry)?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    $removed = Remove-MountFromProfile -ProfilePath (Resolve-ProfilePath) -Guest $g
    if ($removed) { Write-Host "  Removed from profile." }

    if (Test-DistroExists -Name $distro) {
        # Merge with session-derived mounts so removing a profile-level mount
        # doesn't unmount live hostProject session worktrees.
        Invoke-MergedMountsApply -DistroName $distro
    }
    Write-Host "Mount '$g' removed." -ForegroundColor Green
}

function Invoke-MountSync {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) {
        Write-Host "Distro '$distro' does not exist; nothing to sync." -ForegroundColor Yellow
        return
    }
    # Always merge: a plain `mount sync` rebuilds fstab from profile +
    # session-derived mounts so the live host-session mounts survive.
    Invoke-MergedMountsApply -DistroName $distro
    $spec = Read-ProfileIfPresent
    $profileCount = if ($spec -and $spec.ContainsKey('hostMounts') -and $spec.hostMounts) { @($spec.hostMounts).Count } else { 0 }
    Write-Host "Mounts synced (profile entries: $profileCount; plus any hostProject session mounts)." -ForegroundColor Green
}

function Invoke-MountDashboard {
    $distro = Resolve-DistroForOps
    Clear-Host
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: mounts ===' -ForegroundColor Cyan
        $rows = Get-MountRows -DistroName $distro
        if ($rows.Count -eq 0) {
            Write-Host '  (no mounts)' -ForegroundColor DarkGray
        }
        else {
            Write-Host ('  {0,-3} {1,-30} {2,-50} {3,-4} {4}' -f '#','Guest','Host','Mode','Mounted')
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                Write-Host ('  {0,-3} {1,-30} {2,-50} {3,-4} {4}' -f ($i + 1), $r.Guest, $r.HostPath, $r.Mode, $r.Materialized)
            }
        }
        Write-Host ''
        Write-Host '  +  add new mount'
        Write-Host '  d <n>  remove mount'
        Write-Host '  s  sync to distro'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q','')) { return }
        if ($a -eq '+') {
            Show-DashboardAction 'mount add'
            $script:Arg = $null; $script:HostPath = $null; $script:Guest = $null; $script:Mode = $null; $script:MountOptions = $null
            Invoke-MountAdd
            continue
        }
        if ($a -eq 's') { Show-DashboardAction 'mount sync'; Invoke-MountSync; continue }
        if ($a -match '^d\s+(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -lt 0 -or $idx -ge $rows.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $script:Arg = $rows[$idx].Guest
            Show-DashboardAction "mount remove $($script:Arg)"
            Invoke-MountRemove
            continue
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

function Invoke-Mount {
    if (-not $SubVerb) { Invoke-MountDashboard; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'add'    { Invoke-MountAdd }
        'list'   { Invoke-MountList }
        'remove' { Invoke-MountRemove }
        'sync'   { Invoke-MountSync }
        default {
            Write-Host "Unknown mount subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: add | list | remove | sync (or bare 'mount' for the dashboard)"
            exit 64
        }
    }
}

function Get-ToolRows {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $spec = $null
    try { $spec = Read-ProfileIfPresent } catch { }
    $profileTools = @{}
    if ($spec -and $spec.ContainsKey('tools') -and $spec.tools -is [hashtable]) { $profileTools = $spec.tools }
    # Drop-in host-attach: a hostTools entry whose guestCommand matches the
    # catalog name shadows the in-WSL install. Build a set for quick lookup.
    $attachedAsHost = @{}
    if ($spec -and $spec.ContainsKey('hostTools') -and $null -ne $spec.hostTools) {
        foreach ($ht in @($spec.hostTools)) {
            if ($ht -is [hashtable] -and $ht.ContainsKey('guestCommand')) {
                $attachedAsHost[[string]$ht.guestCommand] = $true
            }
        }
    }

    # Latest-version cache (populated by the background ThreadJob). Reading it
    # once up front avoids touching disk per-row inside the loop.
    $cache = $null
    try { $cache = Read-ToolUpdatesCache } catch { }
    $cacheTools = @{}
    if ($cache -and $cache.ContainsKey('tools') -and $cache.tools -is [hashtable]) {
        $cacheTools = $cache.tools
    }

    $rows = @()
    foreach ($name in Get-ToolCatalog) {
        $installed = $false; $version = $null
        if (Test-DistroExists -Name $DistroName) {
            $installed = Test-ToolInstalled -DistroName $DistroName -Name $name
            if ($installed) { $version = Get-ToolVersion -DistroName $DistroName -Name $name }
        }
        $enabled = $false; $desiredVersion = ''
        if ($profileTools.ContainsKey($name)) {
            $entry = $profileTools[$name]
            $enabled = if ($entry.ContainsKey('enabled')) { [bool]$entry.enabled } else { $true }
            $desiredVersion = if ($entry.ContainsKey('version')) { [string]$entry.version } else { 'latest' }
        }
        $probe = Test-ToolHostAvailable -Name $name
        $latest = $null
        if ($cacheTools.ContainsKey($name)) {
            $entry = $cacheTools[$name]
            if ($entry -is [hashtable] -and $entry.ContainsKey('latest') -and $entry.latest) {
                $latest = [string]$entry.latest
            }
        }
        $updateStatus = Compare-ToolVersion -Installed $version -Latest $latest
        $rows += [PSCustomObject]@{
            Name           = $name
            InProfile      = $profileTools.ContainsKey($name)
            Enabled        = $enabled
            DesiredVersion = $desiredVersion
            Installed      = $installed
            Version        = $version
            Latest         = $latest
            UpdateStatus   = $updateStatus
            HostAvailable  = [bool]$probe.Available
            HostExePath    = [string]$probe.ExePath
            AttachedAsHost = [bool]$attachedAsHost.ContainsKey($name)
        }
    }
    return ,$rows
}

function Update-ToolsBadgeTitle {
    # Set the wt tab title to "* <base>" when there are pending tool updates,
    # otherwise restore the captured base title. Silent if WindowTitle access
    # fails (some host UIs don't expose RawUI).
    [CmdletBinding()] param([int]$Count = 0)
    if ($null -eq $Script:BaseWtTitle) { return }
    try {
        $base = [string]$Script:BaseWtTitle
        $Host.UI.RawUI.WindowTitle = if ($Count -gt 0) { "* $base" } else { $base }
    } catch { }
}

function Get-ToolUpdateCountFromRows {
    [CmdletBinding()] param([AllowNull()]$Rows)
    if (-not $Rows) { return 0 }
    return (Get-ToolUpdateCount -Rows $Rows)
}

function Invoke-ToolsList {
    $distro = Resolve-DistroForOps
    # Trigger a background refresh if the cache is stale — the next list/
    # dashboard render will pick up the fresh values. Non-blocking.
    if (Test-ToolUpdatesCacheStale) { try { [void](Start-ToolUpdatesRefresh) } catch { } }
    $rows = Get-ToolRows -DistroName $distro
    Write-Host ''
    Write-Host ('  {0,-12} {1,-10} {2,-12} {3,-10} {4,-22} {5}' -f 'Tool','Enabled','Desired','Installed','Version','Latest')
    Write-Host ('  {0,-12} {1,-10} {2,-12} {3,-10} {4,-22} {5}' -f '----','-------','-------','---------','-------','------')
    foreach ($r in $rows) {
        $en = if ($r.InProfile) { $r.Enabled } else { '(none)' }
        $ver = if ($r.Installed) { $r.Version } else { '' }
        $latest = if ($r.Latest) { $r.Latest } else { '' }
        $line = ('  {0,-12} {1,-10} {2,-12} {3,-10} {4,-22} {5}' -f $r.Name, $en, $r.DesiredVersion, $r.Installed, $ver, $latest)
        if ($r.UpdateStatus -eq 'update-available') {
            Write-Host $line -ForegroundColor Yellow
        } else {
            Write-Host $line
        }
    }
}

function Invoke-ToolsInstall {
    if (-not $Arg) { throw "tools install requires a tool name. Catalog: $((Get-ToolCatalog) -join ', ')." }
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' does not exist. Run 'setup' first." }

    $version = 'latest'
    $spec = Read-ProfileIfPresent
    if ($spec -and $spec.ContainsKey('tools') -and $spec.tools.ContainsKey($Arg)) {
        $entry = $spec.tools[$Arg]
        if ($entry.ContainsKey('version')) { $version = [string]$entry.version }
    }

    Install-Tool -DistroName $distro -Name $Arg -Version $version
    Set-ToolInProfile -ProfilePath (Resolve-ProfilePath) -Name $Arg -Enabled $true -Version $version
    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        Add-Recent -State $state -Key 'toolNames' -Value $Arg
        Write-State -DistroName $distro -State $state
    }
    Write-Host "Tool '$Arg' installed and enabled in profile." -ForegroundColor Green
}

function Invoke-ToolsEnable {
    if (-not $Arg) { throw "tools enable requires a tool name." }
    [void](Get-ToolHandler -Name $Arg)   # validates name against catalog
    Set-ToolInProfile -ProfilePath (Resolve-ProfilePath) -Name $Arg -Enabled $true -Version ($(if ($MountOptions) { $MountOptions } else { 'latest' }))
    Write-Host "Tool '$Arg' marked enabled in profile." -ForegroundColor Green
    $distro = Resolve-DistroForOps
    if ((Test-DistroExists -Name $distro) -and -not (Test-ToolInstalled -DistroName $distro -Name $Arg)) {
        Write-Host "  (not installed yet — run '.\claudearium.ps1 tools install $Arg' to install now, or 'reconcile'.)" -ForegroundColor Yellow
    }
}

function Invoke-ToolsDisable {
    if (-not $Arg) { throw "tools disable requires a tool name." }
    [void](Get-ToolHandler -Name $Arg)
    Set-ToolInProfile -ProfilePath (Resolve-ProfilePath) -Name $Arg -Enabled $false -Version 'latest'
    Write-Host "Tool '$Arg' marked disabled in profile (not uninstalled)." -ForegroundColor Green
}

function Invoke-ToolsUpdate {
    # Bulk-upgrade. Re-runs the install handler for every installed tool that
    # is also enabled in the profile, at its profile-pinned version (defaulting
    # to 'latest'). Skips:
    #   - disabled tools (enabled=false in profile) — they're leftover installs;
    #     `tools disable` doesn't auto-uninstall, so don't auto-upgrade either
    #   - tools not yet installed — `sync` covers the install-missing case
    # Cache state (UpdateStatus) is intentionally NOT used as a filter — when
    # the cache is cold (first launch) every row reads 'unknown', and that
    # would silently turn the update verb into a no-op.
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' does not exist. Run 'setup' first." }
    $spec = Read-ProfileIfPresent
    $profileTools = @{}
    if ($spec -and $spec.ContainsKey('tools') -and $spec.tools -is [hashtable]) { $profileTools = $spec.tools }
    $rows = Get-ToolRows -DistroName $distro
    $targets = @($rows | Where-Object { $_.Installed -and $_.InProfile -and $_.Enabled })
    if (-not $targets) {
        Write-Host '  (no installed + enabled tools to update.)' -ForegroundColor DarkGray
        return
    }
    Write-Host ('  updating {0} installed tool(s)...' -f $targets.Count) -ForegroundColor Cyan
    foreach ($r in $targets) {
        $version = 'latest'
        if ($profileTools.ContainsKey($r.Name)) {
            $entry = $profileTools[$r.Name]
            if ($entry.ContainsKey('version') -and $entry.version) { $version = [string]$entry.version }
        }
        try {
            Install-Tool -DistroName $distro -Name $r.Name -Version $version
        } catch {
            Write-Host ("  {0}: update failed — {1}" -f $r.Name, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    # Refresh latest-version cache synchronously so the post-update dashboard
    # render reflects "same" rather than stale "update-available".
    try { [void](Invoke-ToolUpdatesRefreshSync) } catch { }
    Write-Host 'Tools update complete.' -ForegroundColor Green
}

function Invoke-ToolsSync {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' does not exist. Run 'setup' first." }
    $spec = Read-ProfileIfPresent
    if (-not $spec -or -not $spec.ContainsKey('tools') -or -not ($spec.tools -is [hashtable])) {
        Write-Host '  (no tools section in profile)' -ForegroundColor DarkGray
        return
    }
    $actual = Get-ToolsActualFromDistro -DistroName $distro
    $diff = Get-ToolsDiff -DesiredTools $spec.tools -ActualTools $actual
    if ($diff.Changes.Count -eq 0) {
        Write-Host '  (tools already in sync)' -ForegroundColor DarkGray
        return
    }
    $state = Read-State -DistroName $distro
    Invoke-ToolsApply -DistroName $distro -State $state -Diff $diff -DesiredTools $spec.tools
    Write-State -DistroName $distro -State $state
    Write-Host 'Tools sync complete.' -ForegroundColor Green
}

function Invoke-ToolsAttachFromHost {
    # Attach a catalog tool from the Windows host using the bare tool name as
    # guestCommand. If tools.<name> is enabled in the profile, Test-Profile
    # would refuse the resulting state — prompt to disable it first (or, under
    # -NonInteractive, throw instead of blocking on a hidden prompt).
    if (-not $Arg) { throw "tools attach requires a tool name." }
    [void](Get-ToolHandler -Name $Arg)   # validates name against catalog
    if (-not (Test-ToolIsHostAttachable -Name $Arg)) {
        $eligible = @(Get-ToolCatalog | Where-Object { Test-ToolIsHostAttachable -Name $_ })
        Write-Host "  '$Arg' is not eligible for host attach (no HostExeNames declared in the catalog)." -ForegroundColor Yellow
        Write-Host "  Eligible: $($eligible -join ', ')." -ForegroundColor DarkGray
        return
    }
    $probe = Test-ToolHostAvailable -Name $Arg
    if (-not $probe.Available) {
        Write-Host "  '$Arg' is host-attachable but no $($Arg).exe was found on the Windows host PATH." -ForegroundColor Yellow
        return
    }

    $profilePath = Resolve-ProfilePath
    $spec = Read-ProfileIfPresent
    if ($spec -and $spec.ContainsKey('tools') -and $spec.tools -is [hashtable] -and $spec.tools.ContainsKey($Arg)) {
        $entry = $spec.tools[$Arg]
        if (Test-ToolEntryEnabled -Entry $entry) {
            if ($NonInteractive) {
                throw "tools attach $Arg refused: tools.$Arg is enabled (would collide on PATH). Run 'tools disable $Arg' first, or use the interactive dashboard."
            }
            Write-Host "  '$Arg' is enabled for in-WSL install (tools.$Arg)." -ForegroundColor Yellow
            $disable = Read-YesNo -Prompt "  A drop-in host wrapper would collide on PATH. Disable the WSL install first?" -Default $false
            if (-not $disable) { Write-Host '  attach cancelled.' -ForegroundColor Yellow; return }
            Set-ToolInProfile -ProfilePath $profilePath -Name $Arg -Enabled $false -Version ($(if ($entry.ContainsKey('version')) { [string]$entry.version } else { 'latest' }))
        }
    }

    Add-CatalogToolAsHostAttach -ProfilePath $profilePath -ToolName $Arg -WindowsExe ([string]$probe.ExePath)
    Write-Host "  profile updated: hostTools[] += { name=$Arg; guestCommand=$Arg; windowsExe=$($probe.ExePath) }" -ForegroundColor DarkGray

    $distro = Resolve-DistroForOps
    if (Test-DistroExists -Name $distro) {
        $toolSpec = @{ name = $Arg; windowsExe = [string]$probe.ExePath; guestCommand = $Arg }
        Install-HostToolWrapper -DistroName $distro -ToolSpec $toolSpec
        Write-Host "Tool '$Arg' attached from host (wrapper at /usr/local/bin/$Arg)." -ForegroundColor Green
        # Drop-in catalog attach gets a per-tool note + managed-block update.
        try { Install-HostToolNotesAllUsers -DistroName $distro -Spec (Read-ProfileIfPresent) }
        catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "Tool '$Arg' added to profile. Run 'setup' or 'host-tools sync' once the distro exists." -ForegroundColor Green
    }
}

function Invoke-ToolsDashboard {
    $distro = Resolve-DistroForOps
    # Kick off a background refresh on first entry so the Latest column gets
    # populated within ~10s. The render path itself is non-blocking — it just
    # reads whatever is currently in the cache.
    if (Test-ToolUpdatesCacheStale) { try { [void](Start-ToolUpdatesRefresh) } catch { } }
    Clear-Host
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: tools ===' -ForegroundColor Cyan
        $rows = Get-ToolRows -DistroName $distro
        Update-ToolsBadgeTitle -Count (Get-ToolUpdateCountFromRows -Rows $rows)
        Write-Host ('  {0,-3} {1,-12} {2,-7} {3,-8} {4,-12} {5,-10} {6,-22} {7}' -f '#','Tool','Host','Enabled','Desired','Installed','Version','Latest')
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $en = if ($r.AttachedAsHost) { 'host' } elseif ($r.InProfile) { $r.Enabled } else { '(none)' }
            $hostCol = if ($r.AttachedAsHost) { 'attach' } elseif ($r.HostAvailable) { 'avail' } else { '-' }
            $ver = if ($r.Installed) { $r.Version } else { '' }
            $latest = if ($r.Latest) { $r.Latest } else { '' }
            $line = ('  {0,-3} {1,-12} {2,-7} {3,-8} {4,-12} {5,-10} {6,-22} {7}' -f ($i + 1), $r.Name, $hostCol, $en, $r.DesiredVersion, $r.Installed, $ver, $latest)
            if ($r.UpdateStatus -eq 'update-available') {
                Write-Host $line -ForegroundColor Yellow
            } else {
                Write-Host $line
            }
        }
        Write-Host ''
        Write-Host '  i <n>  install/upgrade tool (in WSL)'
        Write-Host '  a <n>  attach tool from Windows host (drop-in wrapper)'
        Write-Host '  e <n>  enable in profile'
        Write-Host '  x <n>  disable in profile'
        Write-Host '  s  sync (install all enabled-but-missing)'
        Write-Host '  u  update all (re-runs install per tool; ''latest'' pins fetch current upstream)'
        Write-Host '  r  refresh latest-version cache now'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q','')) { return }
        if ($a -eq 's') { Show-DashboardAction 'tools sync';   Invoke-ToolsSync;   continue }
        if ($a -eq 'u') { Show-DashboardAction 'tools update'; Invoke-ToolsUpdate; continue }
        if ($a -eq 'r') {
            Show-DashboardAction 'tools refresh-latest'
            try { [void](Invoke-ToolUpdatesRefreshSync -Progress) }
            catch { Write-Host ("  refresh failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
            continue
        }
        if ($a -match '^([iexa])\s+(\d+)$') {
            $cmd = $Matches[1]; $idx = [int]$Matches[2] - 1
            if ($idx -lt 0 -or $idx -ge $rows.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $script:Arg = $rows[$idx].Name
            switch ($cmd) {
                'i' { Show-DashboardAction "tools install $($script:Arg)"; Invoke-ToolsInstall }
                'e' { Show-DashboardAction "tools enable $($script:Arg)";  Invoke-ToolsEnable }
                'x' { Show-DashboardAction "tools disable $($script:Arg)"; Invoke-ToolsDisable }
                'a' { Show-DashboardAction "tools attach $($script:Arg)";  Invoke-ToolsAttachFromHost }
            }
            continue
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

function Invoke-Tools {
    if (-not $SubVerb) { Invoke-ToolsDashboard; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'list'    { Invoke-ToolsList }
        'install' { Invoke-ToolsInstall }
        'enable'  { Invoke-ToolsEnable }
        'disable' { Invoke-ToolsDisable }
        'sync'    { Invoke-ToolsSync }
        'update'  { Invoke-ToolsUpdate }
        'refresh-latest' { [void](Invoke-ToolUpdatesRefreshSync -Progress) }
        'attach'  { Invoke-ToolsAttachFromHost }
        default {
            Write-Host "Unknown tools subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: list | install | attach | enable | disable | sync | update | refresh-latest (or bare 'tools' for the dashboard)"
            exit 64
        }
    }
}

function Get-HostToolRows {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $spec = $null
    try { $spec = Read-ProfileIfPresent } catch { }
    $desired = @()
    if ($spec -and $spec.ContainsKey('hostTools') -and $null -ne $spec.hostTools) { $desired = @($spec.hostTools) }
    $actual = @()
    if (Test-DistroExists -Name $DistroName) { $actual = Get-HostToolsActualFromDistro -DistroName $DistroName }
    $actualByCmd = @{}; foreach ($a in $actual) { $actualByCmd[[string]$a.guestCommand] = $a }

    $rows = @()
    $seen = @{}
    foreach ($t in $desired) {
        $gc = [string]$t.guestCommand
        $seen[$gc] = $true
        $installed = $actualByCmd.ContainsKey($gc)
        $version = if ($installed) {
            Get-HostToolVersion -DistroName $DistroName -GuestCommand $gc -WindowsExe ([string]$t.windowsExe)
        } else { $null }
        $rows += [PSCustomObject]@{
            Name         = [string]$t.name
            GuestCommand = $gc
            WindowsExe   = [string]$t.windowsExe
            SmokeTest    = if ($t.ContainsKey('smokeTest') -and $t.smokeTest) { [string]$t.smokeTest } else { '' }
            InProfile    = $true
            Installed    = $installed
            Version      = if ($version) { [string]$version } else { '' }
        }
    }
    foreach ($a in $actual) {
        $gc = [string]$a.guestCommand
        if (-not $seen.ContainsKey($gc)) {
            $version = Get-HostToolVersion -DistroName $DistroName -GuestCommand $gc -WindowsExe ([string]$a.windowsExe)
            $rows += [PSCustomObject]@{
                Name         = [string]$a.name
                GuestCommand = $gc
                WindowsExe   = [string]$a.windowsExe
                SmokeTest    = ''
                InProfile    = $false
                Installed    = $true
                Version      = if ($version) { [string]$version } else { '' }
            }
        }
    }
    return ,$rows
}

function Invoke-HostToolsAdd {
    $distro = Resolve-DistroForOps
    $exe   = if ($HostExe) { $HostExe } else { $Arg }
    $gc    = $GuestCommand
    $smoke = $SmokeTest
    $name  = $null

    if (-not $exe) {
        if ($NonInteractive) { throw "host-tools add requires -HostExe (or positional Windows exe path)." }
        $exe = (Read-Host 'Windows .exe path').Trim()
        if (-not $exe) { throw 'Windows exe path is required.' }
    }
    # Test-Path the exe only when the user gave us a host-side path (looks Windows-y);
    # for guest paths like '/host/...' we trust the user has the mount in place.
    if ($exe -match '^[A-Za-z]:' -and -not (Test-Path $exe)) {
        Write-Host "  Note: '$exe' does not exist on the host. Wrapper will fail at invocation time." -ForegroundColor Yellow
        if (-not $NonInteractive) {
            $ok = Read-YesNo -Prompt 'Continue anyway?' -Default $false
            if (-not $ok) { return }
        }
    }

    if (-not $gc) {
        $derived = Resolve-DefaultGuestCommand -WindowsExe $exe
        if ($NonInteractive) { $gc = $derived }
        else {
            $entry = (Read-Host "Guest command [$derived]").Trim()
            $gc = if ([string]::IsNullOrWhiteSpace($entry)) { $derived } else { $entry }
        }
    }
    if ($gc -match '[\\/\s]') { throw "Guest command '$gc' must be a bare filename." }

    $name = [IO.Path]::GetFileNameWithoutExtension($exe)
    if (-not $smoke -and -not $NonInteractive) {
        $entry = (Read-Host 'smokeTest args (optional, for `hooks test`; blank = none)').Trim()
        if ($entry) { $smoke = $entry }
    }

    Write-Host ''
    Write-Host "  Name:         $name"
    Write-Host "  Guest command: $gc"
    Write-Host "  Windows exe:  $exe"
    if ($smoke) { Write-Host "  Smoke test:   $smoke" }

    if (-not $NonInteractive) {
        $ok = Read-YesNo -Prompt 'Add this host-tool?' -Default $true
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    $entry = @{ name = $name; guestCommand = $gc; windowsExe = $exe }
    if ($smoke) { $entry.smokeTest = $smoke }

    Add-HostToolToProfile -ProfilePath (Resolve-ProfilePath) -ToolSpec $entry
    Write-Host "  Added to profile." -ForegroundColor Green

    if (-not (Test-DistroExists -Name $distro)) {
        Write-Host "  Distro '$distro' missing — wrapper will be created on next reconcile." -ForegroundColor Yellow
        return
    }
    Install-HostToolWrapper -DistroName $distro -ToolSpec $entry
    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        Add-Recent -State $state -Key 'hostExePaths' -Value $exe
        Write-State -DistroName $distro -State $state
    }
    Write-Host "Wrapper /usr/local/bin/$gc installed." -ForegroundColor Green

    # Refresh per-tool notes — drop-in catalog attaches get a /home/claude/
    # .claude/host-tools/<tool>.md and the managed block in CLAUDE.md.
    try { Install-HostToolNotesAllUsers -DistroName $distro -Spec (Read-ProfileIfPresent) }
    catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Invoke-HostToolsList {
    $distro = Resolve-DistroForOps
    $rows = Get-HostToolRows -DistroName $distro
    if ($rows.Count -eq 0) {
        Write-Host '  (no host-tools)' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host ('  {0,-16} {1,-14} {2,-50} {3,-10} {4,-10} {5}' -f 'Name','GuestCmd','WindowsExe','InProfile','Installed','Version')
    Write-Host ('  {0,-16} {1,-14} {2,-50} {3,-10} {4,-10} {5}' -f '----','--------','----------','---------','---------','-------')
    foreach ($r in $rows) {
        Write-Host ('  {0,-16} {1,-14} {2,-50} {3,-10} {4,-10} {5}' -f $r.Name, $r.GuestCommand, $r.WindowsExe, $r.InProfile, $r.Installed, $r.Version)
    }
}

function Invoke-HostToolsRemove {
    if (-not $Arg) { throw 'host-tools remove requires a guestCommand.' }
    $distro = Resolve-DistroForOps
    $gc = $Arg
    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Remove host-tool '$gc' (wrapper + profile entry)?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }
    Remove-HostToolFromProfile -ProfilePath (Resolve-ProfilePath) -GuestCommand $gc | Out-Null
    if (Test-DistroExists -Name $distro) {
        Remove-HostToolWrapper -DistroName $distro -GuestCommand $gc
        # Refresh notes — orphan .md (and the managed-block line for $gc) get
        # cleaned up by Install-HostToolNotes since $gc is no longer in profile.
        try { Install-HostToolNotesAllUsers -DistroName $distro -Spec (Read-ProfileIfPresent) }
        catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    Write-Host "Host-tool '$gc' removed." -ForegroundColor Green
}

function Invoke-HostToolsSync {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' missing." }
    $spec = Read-ProfileIfPresent
    $desired = @()
    if ($spec -and $spec.ContainsKey('hostTools') -and $null -ne $spec.hostTools) { $desired = @($spec.hostTools) }
    $actual = Get-HostToolsActualFromDistro -DistroName $distro
    $diff = Get-HostToolsDiff -DesiredTools $desired -ActualTools $actual
    if ($diff.Changes.Count -eq 0) {
        Write-Host '  (host-tools already in sync)' -ForegroundColor DarkGray
        return
    }
    $state = Read-State -DistroName $distro
    Invoke-HostToolsApply -DistroName $distro -State $state -Diff $diff -DesiredTools $desired
    Write-State -DistroName $distro -State $state
    Write-Host 'Host-tools sync complete.' -ForegroundColor Green
    try { Install-HostToolNotesAllUsers -DistroName $distro -Spec $spec }
    catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Get-HostAttachableDetections {
    # Probe every catalog tool flagged with HostExeNames for presence on the
    # Windows host PATH. Cross-references the profile so callers can show what
    # is "available but not attached" vs. "already attached" vs. "enabled in WSL".
    # Returns an array of [PSCustomObject] records with Name / ExePath /
    # AttachedAsHost / EnabledInTools — PSCustomObject (not hashtable) so the
    # downstream `... | Where-Object` filters can't accidentally enumerate
    # DictionaryEntries (see the PSCustomObject note below).
    [CmdletBinding()] param()
    $spec = $null
    try { $spec = Read-ProfileIfPresent } catch { }
    $attachedAsHost = @{}
    if ($spec -and $spec.ContainsKey('hostTools') -and $null -ne $spec.hostTools) {
        foreach ($ht in @($spec.hostTools)) {
            if ($ht -is [hashtable] -and $ht.ContainsKey('guestCommand')) {
                $attachedAsHost[[string]$ht.guestCommand] = $true
            }
        }
    }
    $enabledTools = @{}
    if ($spec -and $spec.ContainsKey('tools') -and $spec.tools -is [hashtable]) {
        foreach ($k in $spec.tools.Keys) {
            if (Test-ToolEntryEnabled -Entry $spec.tools[$k]) { $enabledTools[$k] = $true }
        }
    }
    # PSCustomObject (not hashtable) — hashtables auto-enumerate to DictionaryEntry
    # when piped, which breaks the `$detections | Where-Object` filters downstream
    # if the wrapper array ever gets unwrapped to a lone element. Matches the
    # convention in Get-ToolRows.
    $results = @()
    foreach ($name in Get-ToolCatalog) {
        $probe = Test-ToolHostAvailable -Name $name
        if (-not $probe.Available) { continue }
        $results += [PSCustomObject]@{
            Name           = $name
            ExePath        = [string]$probe.ExePath
            AttachedAsHost = [bool]$attachedAsHost.ContainsKey($name)
            EnabledInTools = [bool]$enabledTools.ContainsKey($name)
        }
    }
    return ,$results
}

function Invoke-HostToolsScan {
    # Scan Windows host PATH for catalog tools flagged as host-attachable
    # (gh / glab / acli / seqcli today) and offer to attach each. Idempotent —
    # already-attached entries are listed but skipped from the prompt.
    $detections = Get-HostAttachableDetections
    Write-Host ''
    Write-Host '=== Claudearium: host-tools scan ===' -ForegroundColor Cyan
    if ($detections.Count -eq 0) {
        Write-Host '  No host-attachable tools detected on Windows PATH.' -ForegroundColor DarkGray
        Write-Host '  (Only catalog entries with HostExeNames are scanned — currently gh, glab, acli, seqcli.)' -ForegroundColor DarkGray
        return
    }
    Write-Host '  Detected on Windows host PATH:'
    foreach ($d in $detections) {
        $status = if ($d.AttachedAsHost) { '[already attached]' }
                  elseif ($d.EnabledInTools) { '[enabled in WSL — would conflict]' }
                  else { '[not attached]' }
        Write-Host ('    {0,-8} {1}  {2}' -f $d.Name, $d.ExePath, $status)
    }
    $candidates = @($detections | Where-Object { -not $_.AttachedAsHost })
    if ($candidates.Count -eq 0) {
        Write-Host '  Nothing to do.' -ForegroundColor DarkGray
        return
    }
    if ($NonInteractive) {
        Write-Host ''
        Write-Host '  -NonInteractive: skipping attach prompt. Run without -NonInteractive or use `tools attach <name>` per tool.' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host "  Attach which? Enter names (comma-separated), 'all', or empty to skip:" -NoNewline
    $ans = (Read-Host).Trim()
    if (-not $ans) { Write-Host '  skipped.' -ForegroundColor DarkGray; return }
    $selected = if ($ans -eq 'all') {
        @($candidates | ForEach-Object { $_.Name })
    } else {
        @($ans -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    foreach ($name in $selected) {
        $match = $candidates | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $match) {
            Write-Host "  skipping '$name' (not in detections or already attached)" -ForegroundColor Yellow
            continue
        }
        $script:Arg = $name
        try { Invoke-ToolsAttachFromHost } catch { Write-Host "  attach failed for '$name': $($_.Exception.Message)" -ForegroundColor Red }
    }
}

function Invoke-HostToolsDashboard {
    $distro = Resolve-DistroForOps
    Clear-Host
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: host-tools ===' -ForegroundColor Cyan
        $rows = Get-HostToolRows -DistroName $distro
        if ($rows.Count -eq 0) {
            Write-Host '  (no host-tools)' -ForegroundColor DarkGray
        }
        else {
            Write-Host ('  {0,-3} {1,-16} {2,-14} {3,-50} {4,-10} {5}' -f '#','Name','GuestCmd','WindowsExe','Installed','Version')
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                Write-Host ('  {0,-3} {1,-16} {2,-14} {3,-50} {4,-10} {5}' -f ($i + 1), $r.Name, $r.GuestCommand, $r.WindowsExe, $r.Installed, $r.Version)
            }
        }
        Write-Host ''
        Write-Host '  +  add new host-tool'
        Write-Host '  d <n>  remove host-tool'
        Write-Host '  f  find catalog tools (gh/glab/acli/seqcli) on Windows host PATH'
        Write-Host '  s  sync to distro'
        Write-Host '  t  hooks test'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim().ToLowerInvariant()
        if ($a -in @('q','')) { return }
        if ($a -eq '+') {
            Show-DashboardAction 'host-tools add'
            $script:Arg = $null; $script:HostExe = $null; $script:GuestCommand = $null; $script:SmokeTest = $null
            Invoke-HostToolsAdd
            continue
        }
        if ($a -eq 'f') { Show-DashboardAction 'host-tools scan';  Invoke-HostToolsScan; continue }
        if ($a -eq 's') { Show-DashboardAction 'host-tools sync';  Invoke-HostToolsSync; continue }
        if ($a -eq 't') { Show-DashboardAction 'host-tools hooks test'; Invoke-HooksTest; continue }
        if ($a -match '^d\s+(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -lt 0 -or $idx -ge $rows.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $script:Arg = $rows[$idx].GuestCommand
            Show-DashboardAction "host-tools remove $($script:Arg)"
            Invoke-HostToolsRemove
            continue
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

function Invoke-HostTools {
    if (-not $SubVerb) { Invoke-HostToolsDashboard; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'add'    { Invoke-HostToolsAdd }
        'list'   { Invoke-HostToolsList }
        'remove' { Invoke-HostToolsRemove }
        'sync'   { Invoke-HostToolsSync }
        'scan'   { Invoke-HostToolsScan }
        default {
            Write-Host "Unknown host-tools subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: add | list | remove | sync | scan (or bare 'host-tools' for the dashboard)"
            exit 64
        }
    }
}

function Invoke-HooksTest {
    $distro = Resolve-DistroForOps
    $spec = $null
    try { $spec = Read-ProfileIfPresent } catch { }
    if (-not $spec -or -not $spec.ContainsKey('hostTools') -or -not $spec.hostTools) {
        Write-Host '  (no host-tools in profile)' -ForegroundColor DarkGray
        return
    }
    $tools = @($spec.hostTools)
    foreach ($t in $tools) {
        $gc = [string]$t.guestCommand
        if (-not $t.ContainsKey('smokeTest') -or -not $t.smokeTest) {
            Write-Host ("  {0,-14} (no smokeTest)" -f $gc) -ForegroundColor DarkGray
            continue
        }
        $smoke = [string]$t.smokeTest
        Write-Host ("  {0,-14} -> {1} {2}" -f $gc, $gc, $smoke) -ForegroundColor Cyan
        $cmd = "$gc $smoke 2>&1 | head -5"
        $r = Invoke-InDistro -Name $distro -User 'claude' -Command $cmd -AllowFail -CaptureOutput
        $status = if ($r.ExitCode -eq 0) { 'OK' } else { "FAIL (exit $($r.ExitCode))" }
        Write-Host ("    {0}" -f $status) -ForegroundColor $(if ($r.ExitCode -eq 0) { 'Green' } else { 'Red' })
        foreach ($l in @($r.Output | Select-Object -First 3)) { Write-Host "      $l" }
    }
}

function Invoke-Hooks {
    if (-not $SubVerb) {
        Write-Host "hooks subverbs: test" -ForegroundColor Yellow
        return
    }
    switch ($SubVerb.ToLowerInvariant()) {
        'test' { Invoke-HooksTest }
        default {
            Write-Host "Unknown hooks subverb: $SubVerb" -ForegroundColor Red
            exit 64
        }
    }
}

function Invoke-Diagnostics {
    # Thin wrapper that drives the diagnostic lane via test-claudearium.ps1's
    # -Diag mode (which exists alongside -Auto / -Manual / -Snapshot). Shipped
    # to end users so they can self-diagnose without remembering the runner
    # command (and reachable from the dashboard's 'd' shortcut).
    $runner = Join-Path $Script:ScriptRoot 'test-claudearium.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        Write-Host '  test-claudearium.ps1 is not alongside the install — diagnostics unavailable.' -ForegroundColor Yellow
        Write-Host '  Clone https://github.com/MaceWindu/Claudearium for the full test runner.' -ForegroundColor Yellow
        return
    }
    & $runner -Diag | Out-Host
    Write-Host ''
    Write-Host "  Need deeper checks? Clone https://github.com/MaceWindu/Claudearium and run" -ForegroundColor DarkGray
    Write-Host "  '.\test-claudearium.ps1 -Auto -Only pure' or '-Auto -Only distro' against your install." -ForegroundColor DarkGray
}

function Invoke-VpnEnable {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { throw "Distro '$distro' does not exist. Run 'setup' first." }
    $spec = Read-ProfileIfPresent
    if (-not $spec -or -not $spec.ContainsKey('vpn') -or -not $spec.vpn) {
        Write-Host "  No 'vpn' block in profile. Edit the profile and set vpn.wgConfigPath." -ForegroundColor Yellow
        return
    }
    $wgPath = if ($spec.vpn.ContainsKey('wgConfigPath')) { [string]$spec.vpn.wgConfigPath } else { '' }
    if (-not $wgPath) { throw 'profile.vpn.wgConfigPath is required.' }
    # -LiteralPath so a wgConfigPath containing [, ], or * isn't glob-expanded.
    if (-not (Test-Path -LiteralPath $wgPath -PathType Leaf)) { throw "wg config not found: $wgPath" }

    # Resolve effective routing mode (profile -> interactive prompt -> default).
    # See modules/Vpn.psm1: 'from-config' = current behavior (catch-all split
    # rewrite only); 'all-except-lan' = override AllowedIPs with inverted
    # IPv4 list covering 0.0.0.0/0 minus the local LAN.
    $mode = if ($spec.vpn.ContainsKey('routingMode') -and $spec.vpn.routingMode) { [string]$spec.vpn.routingMode } else { $null }
    $lanCidr = if ($spec.vpn.ContainsKey('lanCidr') -and $spec.vpn.lanCidr) { [string]$spec.vpn.lanCidr } else { $null }
    $persistMode = $false
    $persistLan  = $false

    if (-not $mode) {
        if ($NonInteractive) {
            $mode = 'from-config'
        }
        else {
            $labelFromConfig  = 'use routes from config (apply catch-all split-form rewrite only)'
            $labelAllExceptLan = 'route all to WG except local network'
            $choice = Read-Choice -Prompt 'WireGuard routing mode:' -Options @($labelFromConfig, $labelAllExceptLan) -DefaultIndex 0 -NonInteractive:$NonInteractive
            $mode = if ($choice -eq $labelAllExceptLan) { 'all-except-lan' } else { 'from-config' }
            $persistMode = $true
        }
    }

    if ($mode -eq 'all-except-lan' -and -not $lanCidr) {
        $detected = Get-HostPrimaryIPv4Subnet
        if ($detected) {
            Write-Host ("  Detected local network: {0} (interface '{1}')" -f $detected.Cidr, $detected.InterfaceAlias) -ForegroundColor Cyan
            if ($NonInteractive) {
                $lanCidr = $detected.Cidr
            }
            else {
                $ok = Read-YesNo -Prompt '  Use this CIDR for the LAN exemption?' -Default $true -NonInteractive:$NonInteractive
                if ($ok) { $lanCidr = $detected.Cidr }
            }
        }
        if (-not $lanCidr) {
            if ($NonInteractive) { throw "Could not detect host LAN; set profile.vpn.lanCidr manually." }
            # Same tight regex as Profile.psm1's Ipv4CidrRegex / the schema —
            # reject bad input before Install-VpnPayload arms the killswitch.
            $cidrPattern = '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}/(3[0-2]|[12]?[0-9])$'
            while (-not $lanCidr) {
                $a = (Read-Host '  Enter local LAN CIDR (e.g. 192.168.1.0/24)').Trim()
                if ($a -match $cidrPattern) { $lanCidr = $a }
                else { Write-Host '  invalid CIDR (octets 0-255, prefix 0-32).' -ForegroundColor Yellow }
            }
        }
        $persistLan = $true
    }

    # Pre-flight the FULL wg-config transform (read source, run mode-specific
    # rewrite) before Install-VpnPayload arms the killswitch. Catches: missing
    # / unreadable source, /0 LAN, source missing the AllowedIPs key in
    # all-except-lan mode. Without this, a bad transform throws after the
    # killswitch is on, leaving the distro armed with no tunnel.
    try { [void](Get-TransformedWgConfig -SourcePath $wgPath -RoutingMode $mode -LanCidr $lanCidr) }
    catch { throw "vpn enable: $($_.Exception.Message)" }

    # Warn (don't block) when the wg config has no `DNS =` line. The killswitch
    # blocks port 53 to the Windows host gateway (which is WSL2's default
    # resolv.conf nameserver) to prevent silent DNS leaks. Without `DNS =`,
    # wg-quick leaves resolv.conf pointing at the host gateway and name
    # resolution will fail through the tunnel — confusing if unexpected.
    if (-not (Test-WgConfigHasDns -SourcePath $wgPath)) {
        Write-Host '  Warning: wg config has no `DNS =` line. The killswitch blocks DNS' -ForegroundColor Yellow
        Write-Host '           to the Windows host (leak prevention), so name resolution' -ForegroundColor Yellow
        Write-Host '           will fail in the tunnel. Add `DNS = <wg0-side resolver>`' -ForegroundColor Yellow
        Write-Host ('           in the [Interface] section of {0}.' -f $wgPath) -ForegroundColor Yellow
    }

    Write-Host "  Installing nftables killswitch payload..."
    Install-VpnPayload -DistroName $distro
    $modeNote = if ($mode -eq 'all-except-lan') { "all-except-lan, LAN=$lanCidr" } else { 'from-config (split-form rewrite only)' }
    Write-Host "  Copying wg0.conf (routing: $modeNote) ..."
    Copy-WgConfig -DistroName $distro -SourcePath $wgPath -RoutingMode $mode -LanCidr $lanCidr
    Write-Host "  Restarting killswitch-prep + nftables + wg-quick@wg0 ..."
    Reset-Vpn -DistroName $distro

    if ($persistMode -or $persistLan) {
        # Best-effort: the tunnel is already up and the killswitch is armed.
        # If we can't write the choice back (read-only profile, JSON parse
        # error, transient IO error, ...) the user-visible state is still
        # correct — just surface a warning and move on so a write-back
        # failure doesn't turn a successful enable into a fatal error.
        try {
            $profilePath = Resolve-ProfilePath
            if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
                $p = Read-Profile -Path $profilePath -Raw
                if (-not $p.ContainsKey('vpn') -or -not ($p.vpn -is [hashtable])) { $p.vpn = @{} }
                if ($persistMode) { $p.vpn.routingMode = $mode }
                if ($persistLan -and $lanCidr) { $p.vpn.lanCidr = $lanCidr }
                Write-Profile -Path $profilePath -Spec $p
                Write-Host "  Saved routing choice to profile." -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "  warn: could not save routing choice to profile: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "        VPN is up; you can set vpn.routingMode / vpn.lanCidr manually."  -ForegroundColor Yellow
        }
    }

    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        Add-Recent -State $state -Key 'wgConfigPaths' -Value $wgPath
        Write-State -DistroName $distro -State $state
    }
    Write-Host 'VPN enabled.' -ForegroundColor Green
}

function Invoke-VpnDisable {
    $distro = Resolve-DistroForOps
    Disable-Vpn -DistroName $distro
    Write-Host 'VPN disabled. Killswitch remains armed — sandbox is offline until you re-enable.' -ForegroundColor Yellow
}

function Invoke-VpnReload {
    $distro = Resolve-DistroForOps
    Reset-Vpn -DistroName $distro
    Write-Host 'VPN reloaded.' -ForegroundColor Green
}

function Invoke-VpnStatus {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { Write-Host "Distro '$distro' missing." -ForegroundColor Yellow; return }
    $killswitch = Test-KillswitchActive -DistroName $distro
    $vpn        = Test-VpnActive        -DistroName $distro
    Write-Host ''
    Write-Host '=== Claudearium: vpn status ===' -ForegroundColor Cyan
    Write-Host ("  Killswitch:  {0}" -f $(if ($killswitch) { 'ACTIVE' } else { 'inactive' }))
    Write-Host ("  Tunnel wg0:  {0}" -f $(if ($vpn) { 'UP' } else { 'DOWN' }))
    Write-Host ''
    $s = Get-VpnStatus -DistroName $distro
    foreach ($line in $s.Output) { Write-Host "  $line" }
}

function Invoke-VpnTest {
    $distro = Resolve-DistroForOps
    Write-Host ''
    Write-Host 'Probing host.internal ...'
    $r1 = Invoke-InDistro -Name $distro -User 'claude' -Command 'ping -c1 -W2 host.internal 2>&1 | head -2 || true' -AllowFail -CaptureOutput
    foreach ($l in $r1.Output) { Write-Host "  $l" }
    Write-Host ''
    Write-Host 'Probing external (via wg0) ...'
    $r2 = Invoke-InDistro -Name $distro -User 'claude' -Command 'curl -m 5 -fsS -o /dev/null -w "http_code=%{http_code}\n" https://1.1.1.1 2>&1 || true' -AllowFail -CaptureOutput
    foreach ($l in $r2.Output) { Write-Host "  $l" }
}

function Invoke-VpnMenu {
    $distro = Resolve-DistroForOps
    Clear-Host
    while ($true) {
        Invoke-VpnStatus
        Write-Host ''
        Write-Host '  e  enable / refresh'
        Write-Host '  d  disable'
        Write-Host '  r  reload (restart all VPN services)'
        Write-Host '  t  connectivity test'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q','')) { return }
        switch ($a.ToLowerInvariant()) {
            'e' { Show-DashboardAction 'vpn enable';  Invoke-VpnEnable }
            'd' { Show-DashboardAction 'vpn disable'; Invoke-VpnDisable }
            'r' { Show-DashboardAction 'vpn reload';  Invoke-VpnReload }
            't' { Show-DashboardAction 'vpn test';    Invoke-VpnTest }
            default { Write-Host '  unknown.' -ForegroundColor Yellow }
        }
    }
}

function Invoke-Vpn {
    if (-not $SubVerb) { Invoke-VpnMenu; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'enable'  { Invoke-VpnEnable }
        'disable' { Invoke-VpnDisable }
        'reload'  { Invoke-VpnReload }
        'status'  { Invoke-VpnStatus }
        'test'    { Invoke-VpnTest }
        default {
            Write-Host "Unknown vpn subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: enable | disable | reload | status | test (or bare 'vpn' for the menu)"
            exit 64
        }
    }
}

function Invoke-NetworkApply {
    # Apply the host-VPN net-repair diff: install/enable when desired, or
    # uninstall when disabled. Install is idempotent and also re-applies the
    # MTU override, so it covers the 'modify' case too.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$Desired
    )
    if ($Desired.Enabled) {
        Install-NetRepairPayload -DistroName $DistroName -Config @{ Mtu = $Desired.Mtu; HostOffset = $Desired.HostOffset }
    }
    else {
        Uninstall-NetRepair -DistroName $DistroName
    }
}

function Resolve-NetworkConfigForOps {
    # Effective net-repair config for the on-demand 'network' verb: profile
    # values, with an explicit -Mtu CLI flag overriding. Enabled is forced true
    # here — running 'network repair' is itself the opt-in.
    $cfg = @{ Enabled = $true; Mtu = 0; HostOffset = 2 }
    try {
        $spec = Read-ProfileIfPresent
        if ($spec) {
            $eff = Get-EffectiveNetworkConfig -Spec $spec
            $cfg.Mtu        = $eff.Mtu
            $cfg.HostOffset = $eff.HostOffset
        }
    } catch { }
    if ($Script:RootBoundParams.ContainsKey('Mtu') -and $Mtu) { $cfg.Mtu = [int]$Mtu }
    return $cfg
}

function Invoke-NetworkStatus {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { Write-Host "Distro '$distro' missing." -ForegroundColor Yellow; return }
    $actual = Get-NetRepairActualFromDistro -DistroName $distro
    $state  = if ($actual.Installed -and $actual.Enabled) { 'installed + enabled (runs at boot)' }
              elseif ($actual.Installed)                   { 'installed (not enabled)' }
              else                                         { 'not installed' }
    Write-Host ''
    Write-Host '=== Claudearium: network status ===' -ForegroundColor Cyan
    Write-Host ("  eth0 net-repair: {0}" -f $state)
    if ($actual.Mtu) { Write-Host ("  MTU override:    {0}" -f $actual.Mtu) }
    Write-Host ''
    $s = Get-NetworkStatus -DistroName $distro
    foreach ($line in $s.Output) { Write-Host "  $line" }
}

function Invoke-NetworkRepair {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) { Write-Host "Distro '$distro' missing." -ForegroundColor Yellow; return }
    $cfg = Resolve-NetworkConfigForOps
    Write-Host ''
    Write-Host '=== Claudearium: network repair ===' -ForegroundColor Cyan
    Write-Host '  Installing/refreshing eth0 net-repair and running it now...'
    Install-NetRepairPayload -DistroName $distro -Config $cfg
    $r = Invoke-NetRepairNow -DistroName $distro
    foreach ($l in $r.Output) { Write-Host "  $l" }
    Invoke-NetworkStatus
}

function Invoke-NetworkMenu {
    $distro = Resolve-DistroForOps
    Clear-Host
    while ($true) {
        Invoke-NetworkStatus
        Write-Host ''
        Write-Host '  r  repair now (install + run eth0 net-repair)'
        Write-Host '  s  status'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q','')) { return }
        switch ($a.ToLowerInvariant()) {
            'r' { Show-DashboardAction 'network repair'; Invoke-NetworkRepair }
            's' { Show-DashboardAction 'network status'; Invoke-NetworkStatus }
            default { Write-Host '  unknown.' -ForegroundColor Yellow }
        }
    }
}

function Invoke-Network {
    if (-not $SubVerb) { Invoke-NetworkMenu; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'repair' { Invoke-NetworkRepair }
        'status' { Invoke-NetworkStatus }
        default {
            Write-Host "Unknown network subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: repair | status (or bare 'network' for the menu)"
            exit 64
        }
    }
}

function Invoke-LoginRun {
    # Runs an interactive command inside the distro with stdio passed through.
    # -User selects whose home the credentials land in (per-project isolation);
    # defaults to the legacy lobby 'claude'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$Command,
        [string]$User = 'claude'
    )
    if (-not (Test-ToolInstalled -DistroName $DistroName -Name $ToolName)) {
        Write-Host "  '$ToolName' is not installed yet — run '.\claudearium.ps1 tools install $ToolName' first." -ForegroundColor Yellow
        return
    }
    Write-Host "Launching '$Command' as '$User' inside '$DistroName' (interactive)..." -ForegroundColor Cyan
    # Use wsl.exe directly so stdio is fully passed through. Force
    # PSNativeCommandArgumentPassing='Standard' so a multi-word
    # $Command (e.g. 'acli auth login') is passed as a single argv
    # element to wsl.exe → bash -lc, not space-collapsed and re-split
    # by wsl into 'acli', 'auth', 'login' (which would make bash run
    # bare 'acli' with the rest as positional params). Default is
    # 'Standard' in PowerShell 7.3+; older 7.x defaults to 'Legacy'
    # and exhibits the bug — gh/glab happen to tolerate it because
    # `gh auth login` and bare `gh` show similar prompts, but acli
    # fails loudly with "authentication failed".
    $oldArgPass = $null
    $hasNativeArgPref = $null -ne (Get-Variable -Name 'PSNativeCommandArgumentPassing' -Scope Global -ErrorAction SilentlyContinue)
    try {
        if ($hasNativeArgPref) {
            $oldArgPass = $global:PSNativeCommandArgumentPassing
            $global:PSNativeCommandArgumentPassing = 'Standard'
        }
        & wsl.exe -d $DistroName -u $User -- bash -lc $Command
    } finally {
        if ($hasNativeArgPref) { $global:PSNativeCommandArgumentPassing = $oldArgPass }
    }
}

$Script:LoginEntries = @(
    @{ Subverb='claude';          Tool='claudeCode'; Command='claude' }
    @{ Subverb='gh';              Tool='gh';         Command='gh auth login' }
    @{ Subverb='glab';            Tool='glab';       Command='glab auth login' }
    @{ Subverb='acli-jira';       Tool='acli';       Command='acli jira auth login' }
    @{ Subverb='acli-confluence'; Tool='acli';       Command='acli confluence auth login' }
)

# Per-tool credential directories (home-relative), shared by `user seed`. These
# are best-effort: tokens bound to a hostname/device won't transfer, and
# ~/.claude carries absolute-path-keyed trust state that won't apply to a
# different user's worktree paths (see docs).
$Script:CredentialDirs = [ordered]@{
    claude = @('.claude', '.claude.json')
    gh     = @('.config/gh')
    glab   = @('.config/glab-cli')
    acli   = @('.config/acli', '.config/jira', '.config/confluence')
}

function Resolve-LoginTargetUser {
    # Decide whose home a login writes into. -Project picks that project's user
    # ('claude' selects the shared lobby). Without -Project: if the distro has
    # project users, require a choice (interactive pick; non-interactive errors);
    # otherwise fall back to the lobby. Returns @{ User; Home }.
    [CmdletBinding()] param([Parameter(Mandatory)][string]$DistroName)
    $state = if (Test-State -DistroName $DistroName) { Read-State -DistroName $DistroName } else { $null }
    if ($Project) {
        if ($Project -eq 'claude') { return @{ User = 'claude'; Home = '/home/claude' } }
        if (-not $state) { throw "No state for '$DistroName' — run setup first." }
        $rec = Get-ProjectUser -State $state -Project $Project
        if (-not $rec) { throw "Project '$Project' has no provisioned user — run 'project add'/'reconcile' first." }
        return @{ User = [string]$rec.user; Home = [string]$rec.home }
    }
    $projUsers = if ($state) { Get-AllProjectUsers -State $state } else { @{} }
    if ($projUsers.Count -eq 0) { return @{ User = 'claude'; Home = '/home/claude' } }
    if ($NonInteractive) {
        throw "This distro has per-project users — pass -Project <name> (or -Project claude for the shared lobby) to choose whose credentials to set."
    }
    $names = @($projUsers.Keys | Sort-Object)
    Write-Host ''
    Write-Host 'Log in for which project user?'
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ('  {0}) {1}  ({2})' -f ($i + 1), $names[$i], $projUsers[$names[$i]].user)
    }
    Write-Host ('  {0}) claude (shared lobby)' -f ($names.Count + 1))
    $a = (Read-Host '  >').Trim()
    if ($a -notmatch '^\d+$') { throw 'Cancelled.' }
    $idx = [int]$a - 1
    if ($idx -eq $names.Count) { return @{ User = 'claude'; Home = '/home/claude' } }
    if ($idx -lt 0 -or $idx -ge $names.Count) { throw 'invalid selection.' }
    $rec = $projUsers[$names[$idx]]
    return @{ User = [string]$rec.user; Home = [string]$rec.home }
}

function Invoke-LoginMenu {
    $distro = Resolve-DistroForOps
    Clear-Host
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: login ===' -ForegroundColor Cyan
        for ($i = 0; $i -lt $Script:LoginEntries.Count; $i++) {
            $e = $Script:LoginEntries[$i]
            $ok = if (Test-DistroExists -Name $distro) { Test-ToolInstalled -DistroName $distro -Name $e.Tool } else { $false }
            $marker = if ($ok) { 'ready' } else { 'not installed' }
            Write-Host ('  {0}) {1,-18}  ({2})' -f ($i + 1), $e.Subverb, $marker)
        }
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q','')) { return }
        if ($a -match '^\d+$') {
            $idx = [int]$a - 1
            if ($idx -lt 0 -or $idx -ge $Script:LoginEntries.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $script:SubVerb = $Script:LoginEntries[$idx].Subverb
            Show-DashboardAction "login $($script:SubVerb)"
            Invoke-Login
            continue
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

function Invoke-Login {
    if (-not $SubVerb) { Invoke-LoginMenu; return }
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) {
        Write-Host "Distro '$distro' does not exist. Run 'setup' first." -ForegroundColor Yellow
        return
    }
    $sv = $SubVerb.ToLowerInvariant()
    # Bare 'acli' was the single login subverb until we discovered that
    # `acli auth login` is browser-OAuth-only; CLI-token auth requires
    # `acli jira auth login` and `acli confluence auth login` separately.
    # Catch the old shorthand and point at the new subverbs.
    if ($sv -eq 'acli') {
        Write-Host "'login acli' was split into 'login acli-jira' and 'login acli-confluence'." -ForegroundColor Yellow
        Write-Host "  Pick one — the underlying tool is the same install." -ForegroundColor DarkGray
        exit 64
    }
    $entry = $Script:LoginEntries | Where-Object { $_.Subverb -eq $sv } | Select-Object -First 1
    if ($entry) {
        $target = Resolve-LoginTargetUser -DistroName $distro
        Invoke-LoginRun -DistroName $distro -ToolName $entry.Tool -Command $entry.Command -User $target.User
    }
    else {
        Write-Host "Unknown login subverb: $SubVerb" -ForegroundColor Red
        Write-Host ("Subverbs: " + (($Script:LoginEntries | ForEach-Object { $_.Subverb }) -join ' | ') + " (or bare 'login' for the menu)")
        exit 64
    }
}

function Invoke-User {
    # Per-project Linux user management. Bare 'user' lists; subverbs:
    #   list                       — project -> username / uid / home
    #   password <project>         — print the generated sudo password (on request)
    #   seed <from> -To <to> [-Tools gh,claude,...]
    #                              — copy credential dirs from one project user to another
    #   shell <project>            — open an interactive shell as that project user
    if (-not $SubVerb) { Invoke-UserList; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'list'     { Invoke-UserList }
        'password' { Invoke-UserPassword }
        'seed'     { Invoke-UserSeed }
        'shell'    { Invoke-UserShell }
        default {
            Write-Host "Unknown user subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: list | password <project> | seed <from> -To <to> [-Tools ...] | shell <project>"
            exit 64
        }
    }
}

function Invoke-UserList {
    $distro = Resolve-DistroForOps
    if (-not (Test-State -DistroName $distro)) { Write-Host '  (no state)' -ForegroundColor DarkGray; return }
    $state = Read-State -DistroName $distro
    $users = Get-AllProjectUsers -State $state
    if ($users.Count -eq 0) { Write-Host '  (no per-project users yet)' -ForegroundColor DarkGray; return }
    Write-Host ''
    Write-Host ('  {0,-24} {1,-22} {2,-8} {3}' -f 'Project','User','Uid','Home')
    Write-Host ('  {0,-24} {1,-22} {2,-8} {3}' -f '-------','----','---','----')
    foreach ($proj in ($users.Keys | Sort-Object)) {
        $r = $users[$proj]
        Write-Host ('  {0,-24} {1,-22} {2,-8} {3}' -f $proj, [string]$r.user, [string]$r.uid, [string]$r.home)
    }
    Write-Host ''
    Write-Host "  'user password <project>' prints the generated sudo password." -ForegroundColor DarkGray
}

function Invoke-UserPassword {
    if (-not $Arg) { throw "user password requires a project name." }
    $distro = Resolve-DistroForOps
    if (-not (Test-State -DistroName $distro)) { throw "No state for '$distro'." }
    $state = Read-State -DistroName $distro
    $rec = Get-ProjectUser -State $state -Project $Arg
    if (-not $rec) { throw "Project '$Arg' has no provisioned user." }
    if (-not ($rec.ContainsKey('password') -and $rec.password)) { throw "No password recorded for '$Arg'." }
    Write-Host ''
    Write-Host "  Project '$Arg' — Linux user '$([string]$rec.user)' (uid $([string]$rec.uid))" -ForegroundColor Cyan
    Write-Host "  sudo password: $([string]$rec.password)" -ForegroundColor Yellow
    Write-Host "  (This is the host-side secret for interactive escalation; the in-session agent does not have it.)" -ForegroundColor DarkGray
}

function Invoke-UserSeed {
    # Copy credential dirs from one project user's home into another's.
    if (-not $Arg) { throw "user seed requires a source project: user seed <from> -To <to>." }
    if (-not $To)  { throw "user seed requires -To <to-project>." }
    $distro = Resolve-DistroForOps
    if (-not (Test-State -DistroName $distro)) { throw "No state for '$distro'." }
    $state = Read-State -DistroName $distro
    $fromRec = Get-ProjectUser -State $state -Project $Arg
    $toRec   = Get-ProjectUser -State $state -Project $To
    if (-not $fromRec) { throw "Source project '$Arg' has no provisioned user." }
    if (-not $toRec)   { throw "Target project '$To' has no provisioned user." }

    $selected = if ($Tools) { @($Tools) } else { @($Script:CredentialDirs.Keys) }
    $dirs = @()
    foreach ($t in $selected) {
        $key = ([string]$t).ToLowerInvariant()
        if (-not $Script:CredentialDirs.Contains($key)) {
            Write-Host "  unknown tool '$t' (known: $(($Script:CredentialDirs.Keys) -join ', ')) — skipping." -ForegroundColor Yellow
            continue
        }
        $dirs += @($Script:CredentialDirs[$key])
    }
    if ($dirs.Count -eq 0) { throw "No credential dirs resolved for the requested tools." }

    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Copy [$(($selected) -join ', ')] credentials from '$Arg' to '$To' (overwrites existing)?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }
    Copy-ProjectUserCreds -DistroName $distro -FromUser ([string]$fromRec.user) -ToUser ([string]$toRec.user) -Dirs $dirs
    # Record provenance.
    $toRec['seededFrom'] = [string]$fromRec.user
    Set-ProjectUserRecord -State $state -Project $To -Record $toRec
    Write-State -DistroName $distro -State $state
    Write-Host "Seeded $(($selected) -join ', ') credentials: '$Arg' -> '$To'." -ForegroundColor Green
    Write-Host "  Verify inside the target (e.g. 'gh auth status'); path-keyed Claude trust + device-bound tokens may not transfer." -ForegroundColor DarkGray
}

function Invoke-UserShell {
    if (-not $Arg) { throw "user shell requires a project name." }
    $distro = Resolve-DistroForOps
    if (-not (Test-State -DistroName $distro)) { throw "No state for '$distro'." }
    $state = Read-State -DistroName $distro
    $rec = Get-ProjectUser -State $state -Project $Arg
    if (-not $rec) { throw "Project '$Arg' has no provisioned user." }
    Write-Host "Opening a shell as '$([string]$rec.user)' (project '$Arg')..." -ForegroundColor Cyan
    & wsl.exe -d $distro -u ([string]$rec.user) --cd ([string]$rec.home) -- bash -l
}

function Invoke-Profile {
    if (-not $SubVerb) {
        Write-Host "profile subverbs: validate | export | edit | show" -ForegroundColor Yellow
        return
    }
    switch ($SubVerb.ToLowerInvariant()) {
        'validate' { Invoke-ProfileValidate }
        'export'   { Invoke-ProfileExport }
        'edit'     { Invoke-ProfileEdit }
        'show'     { Invoke-ProfileShow }
        default {
            Write-Host "Unknown profile subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: validate | export | edit | show"
            exit 64
        }
    }
}

function Invoke-CentralDashboard {
    Clear-Host
    # Kick off a background tool-latest-version refresh if the cache is stale.
    # The first iteration of the loop reads whatever the cache currently
    # holds; subsequent iterations see fresher data without the user having
    # to leave the dashboard.
    if (Test-ToolUpdatesCacheStale) { try { [void](Start-ToolUpdatesRefresh) } catch { } }
    # When the previous action was a sub-dashboard or a long-running flow,
    # the screen is full of its output by the time control returns here.
    # Re-rendering the central menu directly on top of that leaves the user
    # scrolling to find it. Set $clearOnNext at the end of those branches so
    # the next iteration starts on a fresh screen. Print-and-return actions
    # (status, diagnostics, help) leave $clearOnNext alone so the user can
    # still read what they asked for.
    $clearOnNext = $false
    while ($true) {
        if ($clearOnNext) { Clear-Host; $clearOnNext = $false }
        $distro = Resolve-DistroForOps
        Write-Host ''
        Write-Host '=== Claudearium ===' -ForegroundColor Cyan
        # Throttled (weekly) update check. Silent in dev checkouts and on
        # network failure; never blocks the menu.
        try {
            $upd = Invoke-UpdateCheck
            if ($upd) {
                Write-Host ("  Update available: v{0} -> v{1}  (run '.\claudearium.cmd update apply')" -f $upd.Local, $upd.Latest) -ForegroundColor Yellow
            }
        } catch { }
        # Tool-update badge. Counts cached "latest > installed" rows so the
        # tools menu line can carry a "(N updates)" chip and the wt tab gets
        # a leading '*'. Cheap — no network I/O on this path.
        $toolUpdateCount = 0
        try {
            $toolRowsForBadge = Get-ToolRows -DistroName $distro
            $toolUpdateCount = Get-ToolUpdateCountFromRows -Rows $toolRowsForBadge
        } catch { }
        Update-ToolsBadgeTitle -Count $toolUpdateCount

        # One wsl --list --verbose call per render, reused for both
        # existence and state. The previous double-call cost ~200-500ms on
        # warm WSL, ~1s+ cold.
        $distroRecord = Get-WslDistros | Where-Object { $_.Name -eq $distro } | Select-Object -First 1

        if (-not $distroRecord) {
            Write-Host ("  Distro '{0}' is not set up yet." -f $distro) -ForegroundColor Yellow
            Write-Host '  Pick (i) to run setup, or (q) to quit.'
        }
        else {
            $state = $distroRecord.State
            $stateExists = Test-State -DistroName $distro
            $sessionCount = 0
            if ($stateExists) {
                $st = Read-State -DistroName $distro
                if ($st.ContainsKey('sessions') -and $st.sessions) { $sessionCount = @($st.sessions).Count }
            }
            # VPN/killswitch probes shell into the distro via wsl.exe, which
            # *wakes* a stopped distro for the call. On a cold distro each
            # probe costs 1-3s — dominating dashboard render time, and silently
            # restarting the distro the user just stopped. Only probe when the
            # distro is already running.
            if ($state -eq 'Running') {
                $vpnUp   = Test-VpnActive        -DistroName $distro
                $kill    = Test-KillswitchActive -DistroName $distro
                $vpnText = if ($vpnUp) { 'connected' } elseif ($kill) { 'Killswitch' } else { 'N/A' }
            } else {
                $vpnText = '-'
            }
            # Scratch sizes are one short `du -sb` in-distro — fast on a
            # running distro, skipped when it's stopped to avoid waking it.
            $scratchLine = '-'
            if ($state -eq 'Running') {
                try {
                    $sz = Get-ScratchSizes -DistroName $distro -Homes (Get-ScratchHomes -DistroName $distro)
                    $scratchLine = ("{0}  (tmp {1}, cache {2}, claude {3})" -f `
                        (Format-Bytes -Bytes $sz.total), (Format-Bytes -Bytes $sz.tmp),
                        (Format-Bytes -Bytes $sz.cache), (Format-Bytes -Bytes $sz.claude))
                } catch { $scratchLine = '?' }
            }
            Write-Host ("  Distro:    {0,-20} ({1})" -f $distro, $state)
            Write-Host ("  VPN:       {0}" -f $vpnText)
            Write-Host ("  Sessions:  {0}" -f $sessionCount)
            Write-Host ("  Scratch:   {0}" -f $scratchLine)
            Write-Host ("  Profile:   {0}" -f (Resolve-ProfilePath))
        }
        Write-Host ''
        Write-Host '  s  status (detailed)        v  vpn'
        Write-Host '  p  projects                 c  claude-settings show'
        Write-Host '  o  open-claude (sessions)   r  reconcile'
        Write-Host '  m  mounts                   l  login'
        # Render the tools line with a "(N updates)" chip when applicable.
        # Build the chip and padding separately so the chip can be colored
        # independently of the surrounding plain text.
        $chip = if ($toolUpdateCount -gt 0) {
            ' ({0} update{1})' -f $toolUpdateCount, ($(if ($toolUpdateCount -eq 1) { '' } else { 's' }))
        } else { '' }
        $leadWidth = 20   # width of "  t  tools" + padding to second column
        $pad = [Math]::Max(1, $leadWidth - $chip.Length)
        Write-Host '  t  tools' -NoNewline
        if ($chip) { Write-Host $chip -ForegroundColor Yellow -NoNewline }
        Write-Host ((' ' * $pad) + 'h  host-tools')
        Write-Host '  i  setup (re-provision)     d  diagnostics'
        Write-Host '  b  claude-shared (backup)   u  update'
        Write-Host '  n  nuke                     ?  full help'
        Write-Host '  g  network                  q  quit'

        $a = (Read-Host '  >').Trim().ToLowerInvariant()
        if ($a -in @('q', '')) { return }

        # Bare sub-dispatchers expect $SubVerb / $Arg in script scope — clear them
        # so the dashboard doesn't accidentally carry over previous values.
        $script:SubVerb = $null
        $script:Arg     = $null

        # Wrap each menu action so a `throw` inside a verb prints a friendly
        # line instead of a stack trace and the dashboard keeps running.
        try {
            switch ($a) {
                's' { Show-DashboardAction 'status';               Invoke-Status }
                'p' { Show-DashboardAction 'projects';             Invoke-Project;   $clearOnNext = $true }
                'o' {
                    Show-DashboardAction 'open-claude (sessions)'
                    $openScript = Join-Path $Script:ScriptRoot 'open-claudearium.ps1'
                    if (Test-Path $openScript) {
                        & $openScript
                        $clearOnNext = $true
                    }
                    else {
                        Write-Host '  open-claudearium.ps1 not found.' -ForegroundColor Yellow
                    }
                }
                'm' { Show-DashboardAction 'mounts';               Invoke-Mount;     $clearOnNext = $true }
                't' { Show-DashboardAction 'tools';                Invoke-Tools;     $clearOnNext = $true }
                'h' { Show-DashboardAction 'host-tools';           Invoke-HostTools; $clearOnNext = $true }
                'v' { Show-DashboardAction 'vpn';                  Invoke-Vpn;       $clearOnNext = $true }
                'g' { Show-DashboardAction 'network';              Invoke-Network;   $clearOnNext = $true }
                'c' { Show-DashboardAction 'claude-settings show'; $script:SubVerb = 'show'; Invoke-ClaudeSettings }
                'b' { Show-DashboardAction 'claude-shared';        Invoke-ClaudeSharedDashboard; $clearOnNext = $true }
                'r' { Show-DashboardAction 'reconcile';            Invoke-Reconcile; $clearOnNext = $true }
                'l' { Show-DashboardAction 'login';                Invoke-Login;     $clearOnNext = $true }
                'i' { Show-DashboardAction 'setup (re-provision)'; Invoke-Setup;     $clearOnNext = $true }
                'd' { Show-DashboardAction 'diagnostics';          Invoke-Diagnostics }
                'u' { Show-DashboardAction 'update';               Invoke-Update -SubVerb '' }
                'n' { Show-DashboardAction 'nuke';                 Invoke-Nuke;      $clearOnNext = $true }
                '?' { Show-DashboardAction 'help';                 Show-Help }
                default { Write-Host '  unknown command.' -ForegroundColor Yellow }
            }
        } catch {
            Write-Host ("  Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
            if ($env:CLAUDEARIUM_DEBUG) {
                Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
            }
        }
    }
}

if ($Help) { Show-Help; exit 0 }
if (-not $Verb) {
    if ($NonInteractive) { Show-Help; exit 0 }
    Invoke-CentralDashboard
    exit 0
}

function Invoke-WtProfiles {
    # Manage the generated Windows Terminal profile fragment that carries each
    # project's icon / background image / background-image opacity. Bare = show;
    # 'apply' regenerates from the profile; 'clean' deletes it. WT only picks up
    # fragment changes after a restart.
    $sub = if ($SubVerb) { $SubVerb.ToLowerInvariant() } else { 'show' }
    switch ($sub) {
        'apply' {
            $r = Update-WtProfilesFragment
            if (-not $r) { Write-Host 'No profile found - nothing to generate.' -ForegroundColor Yellow; return }
            if (-not $r.Changed) {
                Write-Host "  Windows Terminal profiles already up to date ($($r.ProfileCount))." -ForegroundColor DarkGray
            }
            return
        }
        'clean' {
            $path = Get-WtFragmentPath
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
                Write-Host "  Removed $path" -ForegroundColor Green
                Write-Host "  Restart Windows Terminal to drop the generated profiles." -ForegroundColor Cyan
            }
            else {
                Write-Host "  No fragment to remove ($path)." -ForegroundColor DarkGray
            }
            return
        }
        'show' {
            $path = Get-WtFragmentPath
            Write-Host ''
            Write-Host '=== Windows Terminal profiles ===' -ForegroundColor Cyan
            Write-Host "  Fragment: $path"
            $spec = $null
            try { $spec = Read-ProfileIfPresent } catch { }
            if (-not $spec) { Write-Host '  (no profile found)' -ForegroundColor Yellow; return }
            $profiles = @((Build-WtFragment -Spec $spec).profiles)
            $onDisk = Test-Path -LiteralPath $path -PathType Leaf
            Write-Host "  On disk:  $(if ($onDisk) { 'yes' } else { 'no (run ''wt-profiles apply'' or ''reconcile'')' })"
            if ($profiles.Count -eq 0) {
                Write-Host '  No project sets an icon or background image.' -ForegroundColor DarkGray
                return
            }
            Write-Host ''
            foreach ($p in $profiles) {
                $names = @($p.PSObject.Properties.Name)
                Write-Host ("  {0}" -f $p.name) -ForegroundColor White
                if ($names -contains 'icon') { Write-Host ("      icon:       {0}" -f $p.icon) }
                if ($names -contains 'backgroundImage') {
                    Write-Host ("      background: {0}" -f $p.backgroundImage)
                    Write-Host ("      opacity:    {0}%" -f [int]([Math]::Round([double]$p.backgroundImageOpacity * 100)))
                }
            }
            if ($onDisk) {
                Write-Host ''
                Write-Host '  Note: Windows Terminal picks up fragment changes only after a restart.' -ForegroundColor DarkYellow
            }
            return
        }
        default {
            throw "wt-profiles: unknown subverb '$SubVerb' (use: apply | clean | show)."
        }
    }
}

# Top-level verb dispatch: any `throw` from a verb bubbles up here and would
# otherwise print a PowerShell stack trace. Catch and reduce to a one-line
# red error + exit 1; set $env:CLAUDEARIUM_DEBUG to see the trace.
try {
    switch ($Verb.ToLowerInvariant()) {
        'setup'     { Invoke-Setup }
        'status'    { Invoke-Status }
        'nuke'      { Invoke-Nuke }
        'reconcile' { Invoke-Reconcile }
        'prune'     { Invoke-Prune }
        'temp'      { Invoke-Temp }
        'profile'   { Invoke-Profile }
        'project'   { Invoke-Project }
        'session'   { Invoke-Session }
        'mount'     { Invoke-Mount }
        'tools'     { Invoke-Tools }
        'login'     { Invoke-Login }
        'user'      { Invoke-User }
        'vpn'       { Invoke-Vpn }
        'network'   { Invoke-Network }
        'host-tools'{ Invoke-HostTools }
        'wt-profiles' { Invoke-WtProfiles }
        'hooks'     { Invoke-Hooks }
        'claude-settings' { Invoke-ClaudeSettings }
        'claude-shared'   { Invoke-ClaudeShared }
        'diagnostics' { Invoke-Diagnostics }
        'update'    { Invoke-Update -SubVerb $SubVerb }
        default     {
            Write-Host "Unknown verb: $Verb" -ForegroundColor Red
            Show-Help
            exit 64
        }
    }
} catch {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($env:CLAUDEARIUM_DEBUG) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}

# Any non-zero $LASTEXITCODE bubbled up from internal native-command calls
# (e.g. `command -v` checks inside Test-ToolInstalled, which return 1 when
# the tool isn't installed) shouldn't be reported as a script failure.
# Verbs that *want* to fail call exit 1 explicitly inside their handlers.
exit 0
