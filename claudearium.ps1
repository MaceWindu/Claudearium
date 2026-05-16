#!/usr/bin/env pwsh
# Entry point for the Claude Code WSL2 sandbox tool.
# Verb dispatch for setup / status / nuke / reconcile / profile / project /
# session / mount / tools / login / vpn / host-tools / hooks / claude-settings.
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
    [string]$HostCheckout,
    [string]$HostPath,
    [string]$Guest,
    [string]$Mode,
    [string]$MountOptions,
    [string]$HostExe,
    [string]$GuestCommand,
    [string]$SmokeTest,
    [switch]$NewBranch,
    [switch]$Force,
    [switch]$NonInteractive,
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
Import-Module (Join-Path $Script:ModulesDir 'Projects.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Sessions.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'Mounts.psm1')   -Force
Import-Module (Join-Path $Script:ModulesDir 'Tools.psm1')    -Force
Import-Module (Join-Path $Script:ModulesDir 'Vpn.psm1')      -Force
Import-Module (Join-Path $Script:ModulesDir 'HostTools.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'ClaudeSettings.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'ClaudeFile.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'HostToolNotes.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'SelfUpdate.psm1') -Force
Import-Module (Join-Path $Script:ModulesDir 'ToolUpdates.psm1') -Force
Set-VpnPayloadRoot -Path $Script:PayloadDir

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

  profile validate <path>  Validate a profile (or the default profile if omitted).
  profile export -Out <p>  Write current state to a profile file at <p>.
  profile edit [<path>]    Open the profile in `$env:EDITOR (or VS Code, then notepad).
  profile show [<path>]    Pretty-print the parsed profile (with env-vars expanded).

  project                  Bare = interactive dashboard.
  project add [<name>]     Add a project to the profile + clone bare mirror.
                           Smart defaults: -HostCheckout / cwd's git origin URL.
  project list             Table of projects (profile + materialization status).
  project remove <name>    Delete bare mirror, sessions, and profile entry.
  project show <name>      Inspect a project's profile entry + mirror status.

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

  vpn                      Bare = status + interactive menu.
  vpn enable               Install payload (idempotent) and bring wg0 up.
  vpn disable              Bring wg0 down (killswitch stays armed; sandbox is offline).
  vpn reload               Restart killswitch-prep + nftables + wg-quick@wg0.
  vpn status               Print tunnel state, killswitch state, host.internal reachability.
  vpn test                 Quick connectivity probes (host.internal + via-wg).

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

  claude-settings show         Print /home/claude/.claude/settings.json.
  claude-settings apply        Apply profile.claudeSettings to the distro.
  claude-settings reconfigure  Interactive wizard, then apply.

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
  -HostCheckout <path>     Auto-detect remote/branch from a host git checkout
  -Project <name>          Project name (used by session verbs)
  -Branch <b>              Branch to check out (session new)
  -NewBranch               Create a new branch when starting the session
  -BaseBranch <b>          Base for -NewBranch (default: profile project's defaultBranch)
  -HostPath <path>         Windows path to mount (mount add)
  -Guest <path>            Linux mount point (default: /host/<basename>)
  -Mode <ro|rw>            Mount mode (default: ro)
  -MountOptions <opts>     Extra drvfs options appended after the defaults
  -NonInteractive          Don't prompt; use defaults / fail if input would be required.
  -Force                   Override safety checks.

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

        # Offer to seed the account-level CLAUDE.md. Only prompts when the
        # profile doesn't already pin a mode (so re-running setup with -Force
        # respects an earlier choice).
        $profileHasClaudeFile = $spec -and $spec.ContainsKey('claudeFile') -and $spec.claudeFile
        if (-not $profileHasClaudeFile -and -not $NonInteractive) {
            try { Invoke-ClaudeFileSetupPrompt -DistroName $Name }
            catch { Write-Host "  CLAUDE.md seed step failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        elseif ($profileHasClaudeFile) {
            try { Install-ClaudeFile -DistroName $Name -Spec $spec.claudeFile }
            catch { Write-Host "  Could not apply profile.claudeFile: $($_.Exception.Message)" -ForegroundColor Yellow }
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

function Invoke-ProjectsApply {
    # Apply a projects-block diff against a running distro. Mutates $State in
    # place (sessions get cleaned up when their project is removed).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Diff,
        [AllowNull()][object[]]$DesiredProjects
    )
    foreach ($c in $Diff.Changes) {
        $projectName = ($c.Path -replace '^projects\.', '') -replace '\.remote$', ''
        switch ($c.Action) {
            'add' {
                $desired = @($DesiredProjects | Where-Object { [string]$_.name -eq $projectName }) | Select-Object -First 1
                if (-not $desired) { continue }
                Write-Host "  cloning project '$projectName' ..."
                New-ProjectMirror -DistroName $DistroName -ProjectName $projectName -Remote ([string]$desired.remote)
                Add-Recent -State $State -Key 'projectNames' -Value $projectName
                Add-Recent -State $State -Key 'remotes'      -Value ([string]$desired.remote)
            }
            'remove' {
                Write-Host "  removing project '$projectName' (and its sessions) ..."
                Remove-ProjectMirror     -DistroName $DistroName -ProjectName $projectName
                Remove-SessionsForProject -State $State -Project $projectName
            }
            'modify' {
                Write-Host "  '$($c.Path)' changed: do 'project remove $projectName' then 'project add'." -ForegroundColor Yellow
            }
        }
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
    Write-Host '  Installing /home/claude/.claude/settings.json ...'
    Install-ClaudeSettings -DistroName $distro -Spec $spec.claudeSettings
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
    $modelChoices = @('claude-opus-4-7', 'claude-sonnet-4-6', 'claude-haiku-4-5')
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

    # 13. Default permission mode (under permissions.{})
    $modeChoices = @('default','acceptEdits','plan','bypassPermissions')
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
        Install-ClaudeSettings -DistroName $distro -Spec $current
        Write-Host '/home/claude/.claude/settings.json installed.' -ForegroundColor Green
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

function Set-ClaudeFileInProfile {
    # Insert/replace the claudeFile block on disk, env-token-preserving. When
    # the profile file doesn't exist yet (e.g. `setup -Name custom` on a host
    # that's never seen claudearium), seed the distro block from the actual
    # caller-supplied name + install path — NOT the hardcoded 'claudearium'
    # defaults — so subsequent `reconcile` runs target the right distro.
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
    $p['claudeFile'] = $Spec
    Write-Profile -Path $ProfilePath -Spec $p
}

function Invoke-ClaudeFileSetupPrompt {
    # Called once during setup (only when profile.claudeFile is absent) to ask
    # how the account-level CLAUDE.md should be seeded inside the distro:
    #   1. host-copy   — only offered when `claude` is on host PATH AND the host
    #                    file exists at $env:USERPROFILE\.claude\CLAUDE.md
    #   2. caveman-lite — literal "be brief." one-liner
    #   3. custom-path  — copy from a user-supplied Windows path
    #   4. skip        — leave the distro file unmanaged (no profile entry)
    # Choice is persisted to the profile so reconcile picks up host-side edits
    # later.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)

    if ($NonInteractive) { return }

    $hostPath = Get-HostClaudeFilePath
    $hostAvailable = (Test-HostClaudeAvailable) -and (Test-Path -LiteralPath $hostPath)

    Write-Host ''
    Write-Host '=== Seed account-level CLAUDE.md ===' -ForegroundColor Cyan
    Write-Host '  This is the per-user CLAUDE.md inside the distro at'
    Write-Host '  /home/claude/.claude/CLAUDE.md. Pick one of:'

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
    [void]$options.Add('Skip')
    [void]$modes.Add('skip')

    $choice = Read-Choice -Prompt 'Choice:' -Options $options.ToArray() -DefaultIndex ($options.Count - 1) -NonInteractive:$NonInteractive
    $mode   = $modes[$options.IndexOf($choice)]
    if ($mode -eq 'skip') {
        Write-Host '  Skipped — distro CLAUDE.md is unmanaged.' -ForegroundColor DarkGray
        return
    }

    $spec = @{ mode = $mode }
    if ($mode -eq 'custom-path') {
        while ($true) {
            $entry = (Read-Host '  Windows path to CLAUDE.md').Trim()
            if ([string]::IsNullOrWhiteSpace($entry)) {
                Write-Host '  Aborted.' -ForegroundColor Yellow
                return
            }
            if (Test-Path -LiteralPath $entry) {
                $spec['path'] = $entry
                break
            }
            Write-Host "  Not found: $entry" -ForegroundColor Yellow
        }
    }

    Set-ClaudeFileInProfile -ProfilePath (Resolve-ProfilePath) -Spec $spec `
        -SeedDistroName $DistroName -SeedInstallPath (Resolve-InstallPath)
    Write-Host '  Profile updated.' -ForegroundColor Green
    Install-ClaudeFile -DistroName $DistroName -Spec $spec
    Write-Host "  /home/claude/.claude/CLAUDE.md installed (mode: $mode)." -ForegroundColor Green
}

function Invoke-ClaudeFileApply {
    # Apply profile.claudeFile to the distro idempotently. No-op when the block
    # is absent (we treat absence as "unmanaged" — never blow away a file the
    # user placed manually).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [AllowNull()]$Spec
    )
    if (-not $Spec) { return }
    Install-ClaudeFile -DistroName $DistroName -Spec $Spec
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

    $targetName = [string]$spec.distro.name
    Write-Host "  Target:    distro '$targetName'"

    if (-not (Test-State -DistroName $targetName)) {
        Write-Host ''
        Write-Host "  Distro '$targetName' has no recorded state — run 'setup' first." -ForegroundColor Yellow
        Write-Host "  (setup will use this profile automatically.)" -ForegroundColor Yellow
        return
    }
    $state = Read-State -DistroName $targetName

    $distroDiff = Get-DistroBlockDiff -DesiredDistro $spec.distro -CurrentState $state

    $actualProjects = @()
    if ((Get-DistroState -Name $targetName) -ne 'Missing') {
        $actualProjects = Get-ProjectsActualFromDistro -DistroName $targetName
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
    $desiredMounts = @()
    if ($spec.ContainsKey('hostMounts') -and $null -ne $spec.hostMounts) {
        $desiredMounts = @($spec.hostMounts)
    }
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

    # claudeFile *is* part of the diff — content is a plain string, so the
    # ordering caveat doesn't apply. We render the desired content up front so
    # Profile.psm1 stays free of cross-module deps (it only diffs two strings).
    $desiredClaudeFile = $null
    if ($spec.ContainsKey('claudeFile') -and $spec.claudeFile -is [hashtable]) { $desiredClaudeFile = $spec.claudeFile }
    $desiredClaudeFileContent = $null
    $claudeFileModeLabel = ''
    if ($desiredClaudeFile) {
        $claudeFileModeLabel = [string]$desiredClaudeFile.mode
        try {
            $desiredClaudeFileContent = Get-ClaudeFileDesiredContent -Spec $desiredClaudeFile
        } catch {
            Write-Host "  Cannot render desired CLAUDE.md ($($_.Exception.Message)) — skipping diff." -ForegroundColor Yellow
            $desiredClaudeFile = $null   # disable apply below for the failed-render case
        }
    }
    $actualClaudeFile = $null
    if ($null -ne $desiredClaudeFileContent -and (Get-DistroState -Name $targetName) -ne 'Missing') {
        $actualClaudeFile = Get-ClaudeFileActualFromDistro -DistroName $targetName
    }
    $claudeFileDiff = Get-ClaudeFileDiff -DesiredContent $desiredClaudeFileContent -ActualContent $actualClaudeFile -ModeLabel $claudeFileModeLabel

    $allChanges = @($distroDiff.Changes) + @($projectsDiff.Changes) + @($mountsDiff.Changes) + @($toolsDiff.Changes) + @($hostToolsDiff.Changes) + @($claudeFileDiff.Changes)
    $combined = @{ Changes = $allChanges; HasDestructive = ($distroDiff.HasDestructive -or $projectsDiff.HasDestructive) }

    Write-Host ''
    Write-Host 'Pending changes:'
    Format-Diff -Diff $combined

    Add-Recent -State $state -Key 'profilePaths' -Value $path
    Write-State -DistroName $targetName -State $state

    if ($allChanges.Count -eq 0) { return }

    Write-Host ''
    if ($distroDiff.HasDestructive) {
        Write-Host '  Distro-block changes require nuke+setup.' -ForegroundColor Yellow
        Write-Host '  All current sessions and bare mirrors will be lost.' -ForegroundColor Red
    }

    $apply = Read-YesNo -Prompt 'Apply these changes?' -Default $false -NonInteractive:$NonInteractive
    if (-not $apply) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }

    if ($distroDiff.HasDestructive) {
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
        if ($desiredClaudeFile) {
            Invoke-ClaudeFileApply -DistroName $targetName -Spec $desiredClaudeFile
        }
        # Per-tool host-tool notes — runs after claudeFile (it owns CLAUDE.md;
        # we only append a managed block) and host-tools (so the desired set
        # is in sync with the freshly-installed wrappers).
        try { Install-HostToolNotes -DistroName $targetName -Spec $spec }
        catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        Write-State -DistroName $targetName -State $state
    }
    else {
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
        if ($claudeFileDiff.Changes.Count -gt 0) {
            Invoke-ClaudeFileApply -DistroName $targetName -Spec $desiredClaudeFile
        }
        # Always re-sync host-tool notes: the managed block depends on the
        # hostTools set which the apply path may have just changed, AND on
        # the CLAUDE.md content which claudeFile apply may have just rewritten.
        try { Install-HostToolNotes -DistroName $targetName -Spec $spec }
        catch { Write-Host "  Host-tool notes update failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        Write-State -DistroName $targetName -State $state
    }
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

function Invoke-ProjectAdd {
    $distro      = Resolve-DistroForOps
    $remote      = $Remote
    $branch      = $DefaultBranch
    $projName    = $Arg

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
    if (-not $NonInteractive) {
        $tabColor = Read-TabColor -Prompt "Default wt tab color for '$projName' sessions" -Default ''
    }

    Write-Host ''
    Write-Host "  Project:        $projName"
    Write-Host "  Remote:         $remote"
    Write-Host "  Default branch: $branch"
    Write-Host "  Tab color:      $(if ($tabColor) { $tabColor } else { '(none)' })"
    Write-Host "  Profile:        $(Resolve-ProfilePath)"

    if (-not $NonInteractive) {
        $ok = Read-YesNo -Prompt 'Add this project?' -Default $true
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    $entry = @{ name = $projName; remote = $remote; defaultBranch = $branch }
    if ($tabColor) { $entry['tabColor'] = $tabColor }
    Add-ProjectToProfile -ProfilePath (Resolve-ProfilePath) -ProjectSpec $entry
    Write-Host "  Added to profile." -ForegroundColor Green

    if (-not (Test-DistroExists -Name $distro)) {
        Write-Host "  Distro '$distro' does not exist yet — clone will happen on next 'setup'/'reconcile'." -ForegroundColor Yellow
        return
    }
    if (Test-ProjectMirrorExists -DistroName $distro -ProjectName $projName) {
        Write-Host "  Bare mirror already present at /home/claude/mirrors/$projName.git" -ForegroundColor DarkGray
        return
    }
    Write-Host "  Cloning $remote -> /home/claude/mirrors/$projName.git ..."
    New-ProjectMirror -DistroName $distro -ProjectName $projName -Remote $remote
    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        Add-Recent -State $state -Key 'projectNames' -Value $projName
        Add-Recent -State $state -Key 'remotes'      -Value $remote
        Write-State -DistroName $distro -State $state
    }
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
        $actual = Get-ProjectsActualFromDistro -DistroName $DistroName
    }
    $actualByName = @{}; foreach ($p in $actual) { $actualByName[[string]$p.name] = $p }

    $rows = @()
    $seen = @{}
    foreach ($p in $profileProjects) {
        $name = [string]$p.name
        $seen[$name] = $true
        $rows += [PSCustomObject]@{
            Name          = $name
            Remote        = [string]$p.remote
            DefaultBranch = if ($p.ContainsKey('defaultBranch')) { [string]$p.defaultBranch } else { 'master' }
            TabColor      = if ($p.ContainsKey('tabColor')) { [string]$p.tabColor } else { '' }
            InProfile     = $true
            Materialized  = $actualByName.ContainsKey($name)
        }
    }
    foreach ($p in $actual) {
        if (-not $seen.ContainsKey([string]$p.name)) {
            $rows += [PSCustomObject]@{
                Name          = [string]$p.name
                Remote        = [string]$p.remote
                DefaultBranch = ''
                TabColor      = ''
                InProfile     = $false
                Materialized  = $true
            }
        }
    }
    return ,$rows
}

function Invoke-ProjectList {
    $distro = Resolve-DistroForOps
    $rows = Get-ProjectListRows -DistroName $distro
    if ($rows.Count -eq 0) {
        Write-Host '  (no projects)' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host ('  {0,-20} {1,-50} {2,-12} {3,-10} {4}' -f 'Name','Remote','Default','InProfile','Mirror')
    Write-Host ('  {0,-20} {1,-50} {2,-12} {3,-10} {4}' -f '----','------','-------','---------','------')
    foreach ($r in $rows) {
        $mirror = if ($r.Materialized) { 'present' } else { 'missing' }
        Write-Host ('  {0,-20} {1,-50} {2,-12} {3,-10} {4}' -f $r.Name, $r.Remote, $r.DefaultBranch, $r.InProfile, $mirror)
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
    Write-Host "  Remote:         $($r.Remote)"
    Write-Host "  Default branch: $($r.DefaultBranch)"
    Write-Host "  Tab color:      $(if ($r.TabColor) { $r.TabColor } else { '(none)' })"
    Write-Host "  In profile:     $($r.InProfile)"
    Write-Host "  Materialized:   $($r.Materialized)"
    if ($r.Materialized) {
        Write-Host "  Mirror path:    /home/claude/mirrors/$($r.Name).git"
    }
    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        $sessions = Get-Sessions -State $state -Project $r.Name
        if ($sessions.Count -gt 0) {
            Write-Host "  Sessions:"
            foreach ($s in $sessions) { Write-Host ("    - {0,-20} branch={1}" -f $s.name, $s.branch) }
        }
    }
}

function Invoke-ProjectRemove {
    if (-not $Arg) { throw "project remove requires a project name." }
    $distro = Resolve-DistroForOps
    $name   = $Arg

    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Remove project '$name' (bare mirror + all sessions + profile entry)?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }

    if ((Test-DistroExists -Name $distro) -and (Test-ProjectMirrorExists -DistroName $distro -ProjectName $name)) {
        Write-Host "  Removing bare mirror /home/claude/mirrors/$name.git ..."
        Remove-ProjectMirror -DistroName $distro -ProjectName $name
    }
    if (Test-State -DistroName $distro) {
        $state = Read-State -DistroName $distro
        Remove-SessionsForProject -State $state -Project $name
        Write-State -DistroName $distro -State $state
    }
    $removed = Remove-ProjectFromProfile -ProfilePath (Resolve-ProfilePath) -Name $name
    if ($removed) { Write-Host "  Removed from profile." }
    Write-Host "Project '$name' removed." -ForegroundColor Green
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
            Write-Host ('  {0,-3} {1,-20} {2,-50} {3,-10} {4}' -f '#','Name','Remote','Default','Mirror')
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                $mirror = if ($r.Materialized) { 'present' } else { 'missing' }
                Write-Host ('  {0,-3} {1,-20} {2,-50} {3,-10} {4}' -f ($i + 1), $r.Name, $r.Remote, $r.DefaultBranch, $mirror)
            }
        }
        Write-Host ''
        Write-Host '  +  add new project'
        Write-Host '  s <n>  show project'
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
        if ($a -match '^([sd])\s+(\d+)$') {
            $cmd = $Matches[1]; $idx = [int]$Matches[2] - 1
            if ($idx -lt 0 -or $idx -ge $rows.Count) { Write-Host '  invalid #' -ForegroundColor Yellow; continue }
            $script:Arg = $rows[$idx].Name
            if ($cmd -eq 's') { Show-DashboardAction "project show $($script:Arg)"; Invoke-ProjectShow }
            else              { Show-DashboardAction "project remove $($script:Arg)"; Invoke-ProjectRemove }
            continue
        }
        Write-Host '  unknown command.' -ForegroundColor Yellow
    }
}

function Invoke-Project {
    if (-not $SubVerb) { Invoke-ProjectDashboard; return }
    switch ($SubVerb.ToLowerInvariant()) {
        'add'    { Invoke-ProjectAdd }
        'list'   { Invoke-ProjectList }
        'remove' { Invoke-ProjectRemove }
        'show'   { Invoke-ProjectShow }
        default {
            Write-Host "Unknown project subverb: $SubVerb" -ForegroundColor Red
            Write-Host "Subverbs: add | list | remove | show (or bare 'project' for the dashboard)"
            exit 64
        }
    }
}

function Invoke-SessionNew {
    if (-not $Arg)     { throw "session new requires a session name." }
    if (-not $Project) { throw "session new requires -Project." }
    if (-not $Branch)  { throw "session new requires -Branch (use -NewBranch to create one)." }

    $distro = Resolve-DistroForOps
    $state = Read-State -DistroName $distro

    Write-Host ''
    Write-Host "  Project:  $Project"
    Write-Host "  Session:  $Arg"
    Write-Host "  Branch:   $Branch"
    if ($NewBranch) {
        $b = if ($BaseBranch) { $BaseBranch } else {
            # Pull project's defaultBranch from profile if available
            try {
                $spec = Read-ProfileIfPresent
                $p = $null
                if ($spec -and $spec.ContainsKey('projects')) {
                    $p = @($spec.projects | Where-Object { [string]$_.name -eq $Project }) | Select-Object -First 1
                }
                if ($p -and $p.ContainsKey('defaultBranch')) { [string]$p.defaultBranch } else { 'master' }
            } catch { 'master' }
        }
        Write-Host "  New branch off: $b"
        New-Session -DistroName $distro -State $state -Project $Project -Name $Arg -Branch $Branch -NewBranch -BaseBranch $b
    }
    else {
        New-Session -DistroName $distro -State $state -Project $Project -Name $Arg -Branch $Branch
    }
    Add-Recent -State $state -Key 'sessionNames' -Value $Arg
    Add-Recent -State $state -Key 'branches'     -Value $Branch
    Write-State -DistroName $distro -State $state
    Write-Host "Session '$Project/$Arg' created at /home/claude/projects/$Project/sessions/$Arg" -ForegroundColor Green
}

function Get-SessionRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName, [string]$ProjectFilter)
    if (-not (Test-State -DistroName $DistroName)) { return @() }
    $state = Read-State -DistroName $DistroName
    $sessions = Get-Sessions -State $state -Project $ProjectFilter
    $rows = @()
    foreach ($s in $sessions) {
        $dirty = Get-SessionDirtyFileCount -DistroName $DistroName -Project $s.project -Name $s.name
        $rows += [PSCustomObject]@{
            Project       = [string]$s.project
            Name          = [string]$s.name
            Branch        = [string]$s.branch
            CreatedAt     = [string]$s.createdAt
            LastOpenedAt  = if ($s.ContainsKey('lastOpenedAt')) { [string]$s.lastOpenedAt } else { '' }
            DirtyFiles    = $dirty
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
    Write-Host ('  {0,-16} {1,-22} {2,-40} {3,-8} {4}' -f 'Project','Session','Branch','Dirty','Created')
    Write-Host ('  {0,-16} {1,-22} {2,-40} {3,-8} {4}' -f '-------','-------','------','-----','-------')
    foreach ($r in $rows) {
        $dirty = if ($r.DirtyFiles -gt 0) { "$($r.DirtyFiles) files" } else { 'clean' }
        Write-Host ('  {0,-16} {1,-22} {2,-40} {3,-8} {4}' -f $r.Project, $r.Name, $r.Branch, $dirty, $r.CreatedAt)
    }
}

function Invoke-SessionRemove {
    if (-not $Arg)     { throw "session remove requires a session name." }
    if (-not $Project) { throw "session remove requires -Project." }
    $distro = Resolve-DistroForOps
    $state = Read-State -DistroName $distro
    if (-not $Force) {
        $ok = Read-YesNo -Prompt "Remove session '$Project/$Arg'?" -Default $false -NonInteractive:$NonInteractive
        if (-not $ok) { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    }
    Remove-Session -DistroName $distro -State $state -Project $Project -Name $Arg -Force:$Force
    Write-State -DistroName $distro -State $state
    Write-Host "Session '$Project/$Arg' removed." -ForegroundColor Green
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
            Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-40} {4}' -f '#','Project','Session','Branch','Dirty')
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                $dirty = if ($r.DirtyFiles -gt 0) { "$($r.DirtyFiles) files" } else { 'clean' }
                Write-Host ('  {0,-3} {1,-16} {2,-22} {3,-40} {4}' -f ($i + 1), $r.Project, $r.Name, $r.Branch, $dirty)
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

    $spec = Read-ProfileIfPresent
    $desired = @($spec.hostMounts)
    Set-HostMountsInDistro -DistroName $distro -Mounts $desired

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
        $spec = Read-ProfileIfPresent
        $desired = @()
        if ($spec -and $spec.ContainsKey('hostMounts')) { $desired = @($spec.hostMounts) }
        Set-HostMountsInDistro -DistroName $distro -Mounts $desired
    }
    Write-Host "Mount '$g' removed." -ForegroundColor Green
}

function Invoke-MountSync {
    $distro = Resolve-DistroForOps
    if (-not (Test-DistroExists -Name $distro)) {
        Write-Host "Distro '$distro' does not exist; nothing to sync." -ForegroundColor Yellow
        return
    }
    $spec = Read-ProfileIfPresent
    $desired = @()
    if ($spec -and $spec.ContainsKey('hostMounts')) { $desired = @($spec.hostMounts) }
    Set-HostMountsInDistro -DistroName $distro -Mounts $desired
    Write-Host "Mounts synced (count: $($desired.Count))." -ForegroundColor Green
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
        try { Install-HostToolNotes -DistroName $distro -Spec (Read-ProfileIfPresent) }
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
        Write-Host '  u  update all (re-install every installed tool at its profile version)'
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
        $rows += [PSCustomObject]@{
            Name         = [string]$t.name
            GuestCommand = $gc
            WindowsExe   = [string]$t.windowsExe
            SmokeTest    = if ($t.ContainsKey('smokeTest') -and $t.smokeTest) { [string]$t.smokeTest } else { '' }
            InProfile    = $true
            Installed    = $actualByCmd.ContainsKey($gc)
        }
    }
    foreach ($a in $actual) {
        $gc = [string]$a.guestCommand
        if (-not $seen.ContainsKey($gc)) {
            $rows += [PSCustomObject]@{
                Name         = [string]$a.name
                GuestCommand = $gc
                WindowsExe   = [string]$a.windowsExe
                SmokeTest    = ''
                InProfile    = $false
                Installed    = $true
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
    try { Install-HostToolNotes -DistroName $distro -Spec (Read-ProfileIfPresent) }
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
    Write-Host ('  {0,-16} {1,-14} {2,-50} {3,-10} {4}' -f 'Name','GuestCmd','WindowsExe','InProfile','Installed')
    Write-Host ('  {0,-16} {1,-14} {2,-50} {3,-10} {4}' -f '----','--------','----------','---------','---------')
    foreach ($r in $rows) {
        Write-Host ('  {0,-16} {1,-14} {2,-50} {3,-10} {4}' -f $r.Name, $r.GuestCommand, $r.WindowsExe, $r.InProfile, $r.Installed)
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
        try { Install-HostToolNotes -DistroName $distro -Spec (Read-ProfileIfPresent) }
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
    try { Install-HostToolNotes -DistroName $distro -Spec $spec }
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
            Write-Host ('  {0,-3} {1,-16} {2,-14} {3,-50} {4}' -f '#','Name','GuestCmd','WindowsExe','Installed')
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                Write-Host ('  {0,-3} {1,-16} {2,-14} {3,-50} {4}' -f ($i + 1), $r.Name, $r.GuestCommand, $r.WindowsExe, $r.Installed)
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

function Invoke-LoginRun {
    # Runs an interactive command inside the distro with stdio passed through.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$Command
    )
    if (-not (Test-ToolInstalled -DistroName $DistroName -Name $ToolName)) {
        Write-Host "  '$ToolName' is not installed yet — run '.\claudearium.ps1 tools install $ToolName' first." -ForegroundColor Yellow
        return
    }
    Write-Host "Launching '$Command' inside '$DistroName' (interactive)..." -ForegroundColor Cyan
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
        & wsl.exe -d $DistroName -u 'claude' -- bash -lc $Command
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
        Invoke-LoginRun -DistroName $distro -ToolName $entry.Tool -Command $entry.Command
    }
    else {
        Write-Host "Unknown login subverb: $SubVerb" -ForegroundColor Red
        Write-Host ("Subverbs: " + (($Script:LoginEntries | ForEach-Object { $_.Subverb }) -join ' | ') + " (or bare 'login' for the menu)")
        exit 64
    }
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
    while ($true) {
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
            Write-Host ("  Distro:    {0,-20} ({1})" -f $distro, $state)
            Write-Host ("  VPN:       {0}" -f $vpnText)
            Write-Host ("  Sessions:  {0}" -f $sessionCount)
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
        Write-Host '  u  update                   ?  full help'
        Write-Host '  n  nuke                     q  quit'

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
                'p' { Show-DashboardAction 'projects';             Invoke-Project }
                'o' {
                    Show-DashboardAction 'open-claude (sessions)'
                    $openScript = Join-Path $Script:ScriptRoot 'open-claudearium.ps1'
                    if (Test-Path $openScript) { & $openScript }
                    else { Write-Host '  open-claudearium.ps1 not found.' -ForegroundColor Yellow }
                }
                'm' { Show-DashboardAction 'mounts';               Invoke-Mount }
                't' { Show-DashboardAction 'tools';                Invoke-Tools }
                'h' { Show-DashboardAction 'host-tools';           Invoke-HostTools }
                'v' { Show-DashboardAction 'vpn';                  Invoke-Vpn }
                'c' { Show-DashboardAction 'claude-settings show'; $script:SubVerb = 'show'; Invoke-ClaudeSettings }
                'r' { Show-DashboardAction 'reconcile';            Invoke-Reconcile }
                'l' { Show-DashboardAction 'login';                Invoke-Login }
                'i' { Show-DashboardAction 'setup (re-provision)'; Invoke-Setup }
                'd' { Show-DashboardAction 'diagnostics';          Invoke-Diagnostics }
                'u' { Show-DashboardAction 'update';               Invoke-Update -SubVerb '' }
                'n' { Show-DashboardAction 'nuke';                 Invoke-Nuke }
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

# Top-level verb dispatch: any `throw` from a verb bubbles up here and would
# otherwise print a PowerShell stack trace. Catch and reduce to a one-line
# red error + exit 1; set $env:CLAUDEARIUM_DEBUG to see the trace.
try {
    switch ($Verb.ToLowerInvariant()) {
        'setup'     { Invoke-Setup }
        'status'    { Invoke-Status }
        'nuke'      { Invoke-Nuke }
        'reconcile' { Invoke-Reconcile }
        'profile'   { Invoke-Profile }
        'project'   { Invoke-Project }
        'session'   { Invoke-Session }
        'mount'     { Invoke-Mount }
        'tools'     { Invoke-Tools }
        'login'     { Invoke-Login }
        'vpn'       { Invoke-Vpn }
        'host-tools'{ Invoke-HostTools }
        'hooks'     { Invoke-Hooks }
        'claude-settings' { Invoke-ClaudeSettings }
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
