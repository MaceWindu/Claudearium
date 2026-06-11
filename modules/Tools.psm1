# Tools.psm1
# Catalog of installable CLI tools. Each entry is a hashtable of scriptblocks
# (TestInstalled / GetVersion / Install) plus a Description and an optional
# DependsOn list. The reconciler walks the dependency graph; bare `tools`
# verb surfaces a desired-vs-installed view backed by this registry.
#
# Current catalog (in $Script:ToolCatalog, [ordered]@{} so menu order is
# stable across pwsh sessions):
#   node, claudeCode, gh, glab, acli, dotnet, seqcli, pwsh
#
# To add a new tool, see docs/extending.md#how-to-add-a-new-tool-to-the-tools-catalog.
# Common install styles for inspiration:
#   - apt repo + key:           gh
#   - direct .deb:              glab
#   - upstream install.sh:      acli, glab
#   - system node tarball:      node (-> /opt/node, PATH via /etc/profile.d)
#   - npm global (system node): claudeCode (depends on node)
#   - system installer:         dotnet (dotnet-install.sh -> /usr/local/share/dotnet)
#   - .NET tool (--tool-path):  seqcli (depends on dotnet)
#   - Microsoft apt repo:       pwsh (note PATH prepend for /sbin — gotcha #8)
#
# node / claudeCode / dotnet / seqcli install SYSTEM-WIDE (as root, under /opt
# or /usr/local) and are exposed to every user via /etc/profile.d so agents
# running as any per-project user (cp-*) get them — see per-project user
# isolation. The apt-repo tools (gh/glab/acli/pwsh) were always system-wide.
#
# Public surface:
#   Get-ToolCatalog                                        — array of names
#   Get-ToolHandler   -Name                                — single entry from $ToolCatalog
#   Test-ToolInstalled -DistroName -Name                    — bool
#   Get-ToolVersion    -DistroName -Name                    — string or $null
#   Get-ToolLatestVersion -Name                             — runs the catalog's GetLatestVersion probe; string or $null
#   Compare-ToolVersion  -Installed -Latest                 — 'same' | 'update-available' | 'unknown'
#   Get-ToolVersionCore  -Raw                               — extract X.Y.Z core from a --version line
#   Install-Tool       -DistroName -Name [-Version]         — resolves deps eagerly
#   Get-ToolsActualFromDistro -DistroName                   — array of @{ name; installed; version }
#   Set-ToolInProfile / Remove-ToolFromProfile              — mutate the on-disk profile
#   Test-CommandInDistro / Get-ToolFirstLineVersion         — helpers reused by all handlers
#   Test-ToolHostAvailable -Name                            — @{ Available; ExePath } — probes Windows-host PATH
#                                                             for entries that declare HostExeNames (OAuth-pain tools)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')

# ---------- helpers ----------

function Get-ToolFirstLineVersion {
    # Wrap a 'tool --version' invocation, return the first non-empty stdout line
    # so wsl stderr noise (systemd warnings etc.) doesn't pollute the version.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Command
    )
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command $Command -AllowFail -CaptureOutput
    if ($r.ExitCode -ne 0) { return $null }
    $line = $r.Output |
        Where-Object { $_ -is [string] -and $_.Trim() -and ($_ -notmatch '^wsl: ') } |
        Select-Object -First 1
    if (-not $line) { return $null }
    return ([string]$line).Trim()
}

function Test-CommandInDistro {
    # 'command -v' is POSIX-portable. Returns $true if the command resolves
    # in a login shell (which is what 'bash -lc' gives us).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Command
    )
    $q = ConvertTo-BashQuoted $Command
    $r = Invoke-InDistro -Name $DistroName -User 'claude' -Command "command -v $q >/dev/null 2>&1" -AllowFail -CaptureOutput
    return ($r.ExitCode -eq 0)
}

# ---------- registry ----------

$Script:ToolCatalog = [ordered]@{
    'node' = @{
        Description = 'Node.js LTS (via nvm)'
        DependsOn   = @()
        TestInstalled = {
            param($Distro)
            # nvm puts node on PATH only after sourcing nvm.sh in a login shell.
            return (Test-CommandInDistro -DistroName $Distro -Command 'node')
        }
        GetVersion = {
            param($Distro)
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'node --version 2>/dev/null')
        }
        GetLatestVersion = {
            # nodejs.org/dist/index.json: array sorted newest-first. `lts` is
            # either the boolean `false` (current) or a codename string.
            $r = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 5 -Headers @{ 'User-Agent' = 'Claudearium' }
            $entry = @($r) | Where-Object { $_.lts -is [string] } | Select-Object -First 1
            if ($entry) { return [string]$entry.version }
            return $null
        }
        Install = {
            param($Distro, $Version)
            # System-wide Node under /opt/node, on PATH for EVERY user via
            # /etc/profile.d. Replaces the old per-user ~/.nvm install so agents
            # running as any project user (cp-*) get node — see per-project user
            # isolation (docs/design-decisions.md). Installed as root from the
            # official tarball (nvm is per-user by design; a fixed system LTS is
            # simpler + faster to source than a shared NVM_DIR).
            $verArg = if ($Version -in @('latest', 'lts', '', 'host-nvmrc') -or -not $Version) { '' } else { [string]$Version }
            $script = @"
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends xz-utils ca-certificates curl jq
ARCH=`$(dpkg --print-architecture)
case "`$ARCH" in amd64) NA=x64;; arm64) NA=arm64;; armhf) NA=armv7l;; *) NA="`$ARCH";; esac
REQ='$verArg'
if [ -n "`$REQ" ]; then
    case "`$REQ" in v*) VER="`$REQ";; *) VER="v`$REQ";; esac
else
    VER=`$(curl -fsSL https://nodejs.org/dist/index.json | jq -r 'map(select(.lts != false)) | .[0].version')
fi
TMP=`$(mktemp -d); trap 'rm -rf "`$TMP"' EXIT
curl -fsSL "https://nodejs.org/dist/`$VER/node-`$VER-linux-`$NA.tar.xz" -o "`$TMP/node.tar.xz"
rm -rf "/opt/node-`$VER-linux-`$NA"
tar -xJf "`$TMP/node.tar.xz" -C /opt
ln -sfn "/opt/node-`$VER-linux-`$NA" /opt/node
printf '%s\n' 'export PATH=/opt/node/bin:`$PATH' > /etc/profile.d/claudearium-node.sh
chmod 0644 /etc/profile.d/claudearium-node.sh
"@
            Invoke-InDistroScript -Name $Distro -User 'root' -Script $script
        }
    }

    'claudeCode' = @{
        Description = 'Claude Code CLI (npm package @anthropic-ai/claude-code)'
        DependsOn   = @('node')
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'claude')
        }
        GetVersion = {
            param($Distro)
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'claude --version 2>/dev/null')
        }
        GetLatestVersion = {
            $r = Invoke-RestMethod -Uri 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest' -TimeoutSec 5 -Headers @{ 'User-Agent' = 'Claudearium' }
            if ($r -and $r.version) { return [string]$r.version }
            return $null
        }
        Install = {
            param($Distro, $Version)
            $pkg = if ($Version -in @('latest', '', $null)) { '@anthropic-ai/claude-code' } else { "@anthropic-ai/claude-code@$Version" }
            # Install into the system node (depends on 'node' -> /opt/node), as
            # root, so `claude` lands in /opt/node/bin and is on PATH for every
            # project user.
            $script = @"
set -e
export PATH=/opt/node/bin:`$PATH
npm install -g $pkg
"@
            Invoke-InDistroScript -Name $Distro -User 'root' -Script $script
        }
    }

    'gh' = @{
        Description   = 'GitHub CLI'
        DependsOn     = @()
        HostExeNames  = @('gh.exe')
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'gh')
        }
        GetVersion = {
            param($Distro)
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'gh --version 2>/dev/null')
        }
        GetLatestVersion = {
            $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -TimeoutSec 5 -Headers @{
                'User-Agent' = 'Claudearium'
                'Accept'     = 'application/vnd.github+json'
            }
            if ($r -and $r.tag_name) { return [string]$r.tag_name }
            return $null
        }
        Install = {
            param($Distro, $Version)
            $script = @'
set -e
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq gh
'@
            Invoke-InDistroScript -Name $Distro -User 'claude' -Script $script
        }
    }

    'glab' = @{
        Description   = 'GitLab CLI'
        DependsOn     = @()
        HostExeNames  = @('glab.exe')
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'glab')
        }
        GetVersion = {
            param($Distro)
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'glab --version 2>/dev/null')
        }
        GetLatestVersion = {
            $r = Invoke-RestMethod -Uri 'https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases?per_page=1' -TimeoutSec 5 -Headers @{ 'User-Agent' = 'Claudearium' }
            $first = @($r) | Select-Object -First 1
            if ($first -and $first.tag_name) { return [string]$first.tag_name }
            return $null
        }
        Install = {
            param($Distro, $Version)
            # Pull the .deb directly from GitLab's release downloads — Fury / the
            # upstream install.sh both 404'd at the time of writing (May 2026).
            $script = @'
set -e
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends curl
ARCH=$(dpkg --print-architecture)
VERSION=$(curl -fsSL https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases | head -c 4096 | grep -oP '"tag_name":"\K[^"]+' | head -1)
SHORT=${VERSION#v}
curl -fsSL -o /tmp/glab.deb "https://gitlab.com/gitlab-org/cli/-/releases/${VERSION}/downloads/glab_${SHORT}_linux_${ARCH}.deb"
sudo apt-get install -y -qq /tmp/glab.deb
rm /tmp/glab.deb
'@
            Invoke-InDistroScript -Name $Distro -User 'claude' -Script $script
        }
    }

    'acli' = @{
        Description   = 'Atlassian CLI (Jira/Confluence)'
        DependsOn     = @()
        HostExeNames  = @('acli.exe')
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'acli')
        }
        GetVersion = {
            param($Distro)
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'acli --version 2>/dev/null')
        }
        GetLatestVersion = {
            # The install.sh embeds the literal version near the top.
            $r = Invoke-WebRequest -Uri 'https://acli.atlassian.com/install.sh' -TimeoutSec 5 -UseBasicParsing -Headers @{ 'User-Agent' = 'Claudearium' }
            if ($r -and $r.Content -and $r.Content -match '(?im)^\s*VERSION\s*=\s*"?(\d+\.\d+(?:\.\d+)*)') { return $Matches[1] }
            return $null
        }
        Install = {
            param($Distro, $Version)
            # Atlassian's own install.sh handles arch detection and the correct
            # download URL.
            $script = @'
set -e
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends curl
curl -fsSL https://acli.atlassian.com/install.sh | sh
'@
            Invoke-InDistroScript -Name $Distro -User 'claude' -Script $script
        }
    }

    'dotnet' = @{
        Description = '.NET SDK (per-user via dotnet-install.sh)'
        DependsOn   = @()
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'dotnet')
        }
        GetVersion = {
            param($Distro)
            # `dotnet --version` returns the resolved SDK version for the cwd
            # (without a global.json that's the most recently installed SDK).
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'dotnet --version 2>/dev/null')
        }
        GetLatestVersion = {
            # The installer's 'latest' maps to --channel 10.0; probe the
            # matching latest.version file (plain text, single line).
            $r = Invoke-WebRequest -Uri 'https://dotnetcli.azureedge.net/dotnet/Sdk/10.0/latest.version' -TimeoutSec 5 -UseBasicParsing -Headers @{ 'User-Agent' = 'Claudearium' }
            if ($r -and $r.Content) {
                $v = ([string]$r.Content).Trim()
                if ($v) { return $v }
            }
            return $null
        }
        Install = {
            param($Distro, $Version)
            # 'latest' -> --channel 10.0 (current stable as of 2026-05); anything
            # matching N.N -> channel; anything else passes through as --version.
            $channelArg = if ($Version -in @('latest', '', $null)) { '--channel 10.0' }
                          elseif ($Version -match '^\d+\.\d+$')    { "--channel $Version" }
                          else                                       { "--version $Version" }
            # System-wide SDK under /usr/local/share/dotnet (root), on PATH +
            # DOTNET_ROOT for every user via /etc/profile.d. The tools dir is
            # included so `seqcli` (a global tool, see below) resolves too.
            $script = @"
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates libicu-dev
TMP=`$(mktemp -d)
trap 'rm -rf "`$TMP"' EXIT
curl -fsSL -o "`$TMP/dotnet-install.sh" https://dot.net/v1/dotnet-install.sh
chmod +x "`$TMP/dotnet-install.sh"
"`$TMP/dotnet-install.sh" $channelArg --install-dir /usr/local/share/dotnet
printf '%s\n' 'export DOTNET_ROOT=/usr/local/share/dotnet' 'export PATH="`$DOTNET_ROOT:`$DOTNET_ROOT/tools:`$PATH"' > /etc/profile.d/claudearium-dotnet.sh
chmod 0644 /etc/profile.d/claudearium-dotnet.sh
"@
            Invoke-InDistroScript -Name $Distro -User 'root' -Script $script
        }
    }

    'seqcli' = @{
        Description   = 'Seq CLI (.NET global tool — log queries against a Seq server)'
        DependsOn     = @('dotnet')
        HostExeNames  = @('seqcli.exe')
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'seqcli')
        }
        GetVersion = {
            param($Distro)
            # seqcli uses `version` (subcommand), not `--version`.
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'seqcli version 2>/dev/null')
        }
        GetLatestVersion = {
            $r = Invoke-RestMethod -Uri 'https://api.nuget.org/v3-flatcontainer/seqcli/index.json' -TimeoutSec 5 -Headers @{ 'User-Agent' = 'Claudearium' }
            if ($r -and $r.versions) {
                $arr = @($r.versions)
                if ($arr.Count -gt 0) { return [string]$arr[-1] }
            }
            return $null
        }
        Install = {
            param($Distro, $Version)
            # 'dotnet tool install' errors on a re-install; switch to 'update'
            # when seqcli is already on the tool list.
            $verArg = if ($Version -in @('latest', '', $null)) { '' } else { "--version $Version" }
            # Install to a shared --tool-path (NOT -g, which is per-user
            # $HOME/.dotnet/tools); the dir is on PATH for every user via the
            # dotnet profile.d entry. Run as root.
            $script = @"
set -e
export DOTNET_ROOT=/usr/local/share/dotnet
export PATH="`$DOTNET_ROOT:`$DOTNET_ROOT/tools:`$PATH"
TP=/usr/local/share/dotnet/tools
mkdir -p "`$TP"
if dotnet tool list --tool-path "`$TP" 2>/dev/null | awk 'NR>2 {print `$1}' | grep -qx 'seqcli'; then
    dotnet tool update seqcli --tool-path "`$TP" $verArg
else
    dotnet tool install seqcli --tool-path "`$TP" $verArg
fi
"@
            Invoke-InDistroScript -Name $Distro -User 'root' -Script $script
        }
    }

    'pwsh' = @{
        Description = 'PowerShell 7+ (Microsoft Debian apt repo)'
        DependsOn   = @()
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'pwsh')
        }
        GetVersion = {
            param($Distro)
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'pwsh --version 2>/dev/null')
        }
        GetLatestVersion = {
            # GitHub release tag tracks the absolute latest; the Microsoft apt
            # repo typically updates within days. Close enough for an indicator.
            $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -TimeoutSec 5 -Headers @{
                'User-Agent' = 'Claudearium'
                'Accept'     = 'application/vnd.github+json'
            }
            if ($r -and $r.tag_name) { return [string]$r.tag_name }
            return $null
        }
        Install = {
            param($Distro, $Version)
            # Microsoft ships a packages-microsoft-prod.deb per Debian release that
            # installs the apt repo; then apt install powershell pulls latest.
            # Note the PATH prepend: the 'claude' user's login PATH doesn't include
            # /sbin, and our sudoers config has !secure_path, so sudo inherits that
            # PATH. dpkg needs ldconfig/start-stop-daemon which live in /usr/sbin.
            $script = @'
set -e
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends wget ca-certificates gnupg
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. /etc/os-release
wget -q -O "$TMP/packages-microsoft-prod.deb" "https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb"
sudo dpkg -i "$TMP/packages-microsoft-prod.deb"
sudo apt-get update -qq
sudo apt-get install -y -qq powershell
'@
            Invoke-InDistroScript -Name $Distro -User 'claude' -Script $script
        }
    }
}

function Get-ToolCatalog {
    [CmdletBinding()] param()
    return @($Script:ToolCatalog.Keys)
}

function Test-ToolIsHostAttachable {
    # True iff the catalog entry opts in to host-attach via a non-empty
    # HostExeNames list. Used to distinguish "no host-attach support" from
    # "host-attach supported but .exe not on PATH" — both currently surface
    # through Test-ToolHostAvailable returning Available=$false, but callers
    # need to print different messages.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $Script:ToolCatalog.Contains($Name)) { return $false }
    $h = $Script:ToolCatalog[$Name]
    if (-not $h.ContainsKey('HostExeNames')) { return $false }
    return (@($h.HostExeNames).Count -gt 0)
}

function Test-ToolHostAvailable {
    # Probe the Windows host PATH for a catalog tool flagged as host-attachable
    # (HostExeNames present). Tools without HostExeNames return Available=$false
    # so callers can dispatch uniformly without checking the catalog shape first
    # — callers that need to distinguish "not eligible" vs. "eligible but
    # missing" should call Test-ToolIsHostAttachable too.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-ToolIsHostAttachable -Name $Name)) { return @{ Available = $false; ExePath = '' } }
    $h = $Script:ToolCatalog[$Name]
    foreach ($candidate in @($h.HostExeNames)) {
        $c = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($c -and $c.Source) {
            return @{ Available = $true; ExePath = [string]$c.Source }
        }
    }
    return @{ Available = $false; ExePath = '' }
}

function Get-ToolHandler {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $Script:ToolCatalog.Contains($Name)) { throw "Unknown tool '$Name'. Catalog: $((Get-ToolCatalog) -join ', ')." }
    return $Script:ToolCatalog[$Name]
}

function Test-ToolInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Name
    )
    $h = Get-ToolHandler -Name $Name
    return [bool](& $h.TestInstalled $DistroName)
}

function Get-ToolVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Name
    )
    $h = Get-ToolHandler -Name $Name
    return (& $h.GetVersion $DistroName)
}

function Get-ToolVersionCore {
    # Extract the X.Y or X.Y.Z(.W) core from a tool --version output. Examples:
    #   'v22.5.1'                -> '22.5.1'
    #   'gh version 2.55.0 (..)' -> '2.55.0'
    #   'PowerShell 7.4.5'       -> '7.4.5'
    #   '1.0.42 (Claude Code)'   -> '1.0.42'
    # Returns $null if no version-shaped substring is present.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $m = [regex]::Match($Raw, '\d+\.\d+(?:\.\d+)*')
    if (-not $m.Success) { return $null }
    return $m.Value
}

function Compare-ToolVersion {
    # Tri-state comparison for "installed vs latest". Returns one of:
    #   'same'             — extracted cores are equal, or installed >= latest under [version]
    #   'update-available' — installed < latest (or cores differ but neither parses)
    #   'unknown'          — either side missing / no version core extractable
    # The UI uses 'update-available' to render the latest cell yellow; 'unknown'
    # is silent (no spurious flag while a probe is still pending or has failed).
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Installed,
        [AllowNull()][AllowEmptyString()][string]$Latest
    )
    if ([string]::IsNullOrWhiteSpace($Installed) -or [string]::IsNullOrWhiteSpace($Latest)) { return 'unknown' }
    $i = Get-ToolVersionCore -Raw $Installed
    $l = Get-ToolVersionCore -Raw $Latest
    if (-not $i -or -not $l) { return 'unknown' }
    if ($i -eq $l) { return 'same' }
    try {
        $iv = [version]$i
        $lv = [version]$l
        if ($iv -ge $lv) { return 'same' }
        return 'update-available'
    } catch {
        # Core strings differ and at least one didn't parse as [version] —
        # treat as an update prompt; false positives are acceptable for a hint.
        return 'update-available'
    }
}

function Get-ToolLatestVersion {
    # Runs the catalog's GetLatestVersion probe (if declared). Returns the
    # raw version string from upstream, or $null on probe absence / failure.
    # Never throws — the dashboard refresh job calls this in a loop and one
    # probe's outage must not stop the rest.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $h = Get-ToolHandler -Name $Name
    if (-not $h.ContainsKey('GetLatestVersion')) { return $null }
    try {
        $v = & $h.GetLatestVersion
        if ([string]::IsNullOrWhiteSpace([string]$v)) { return $null }
        return [string]$v
    } catch {
        return $null
    }
}

function Install-Tool {
    # Installs (or upgrades) a single tool. Resolves dependencies eagerly —
    # if 'claudeCode' is requested and 'node' isn't installed, node is
    # installed first.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][string]$Name,
        [string]$Version = 'latest'
    )
    $h = Get-ToolHandler -Name $Name
    foreach ($dep in @($h.DependsOn)) {
        if (-not (Test-ToolInstalled -DistroName $DistroName -Name $dep)) {
            Write-Host "  ($Name depends on $dep — installing dependency first)" -ForegroundColor DarkGray
            Install-Tool -DistroName $DistroName -Name $dep -Version 'latest'
        }
    }
    Write-Host "  installing $Name ($Version) ..." -ForegroundColor Cyan
    & $h.Install $DistroName $Version
}

function Get-ToolsActualFromDistro {
    # Snapshot of which catalog tools are present, with their reported versions.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DistroName)
    $result = @()
    foreach ($name in Get-ToolCatalog) {
        $installed = Test-ToolInstalled -DistroName $DistroName -Name $name
        $version   = if ($installed) { Get-ToolVersion -DistroName $DistroName -Name $name } else { $null }
        $result += @{
            name      = $name
            installed = $installed
            version   = $version
        }
    }
    return ,$result
}

# ---------- profile mutation ----------

function Set-ToolInProfile {
    # Insert/replace tools.<name> in the on-disk profile. Preserves env tokens.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Enabled,
        [string]$Version = 'latest'
    )
    $spec = if (Test-Path $ProfilePath) { Read-Profile -Path $ProfilePath -Raw } else {
        @{
            schemaVersion = 1
            distro        = @{ name = 'claudearium'; base = 'debian-12'; installPath = '%LOCALAPPDATA%\WSL\claudearium' }
        }
    }
    if (-not $spec.ContainsKey('tools') -or -not ($spec.tools -is [hashtable])) { $spec['tools'] = @{} }
    $spec.tools[$Name] = @{ enabled = $Enabled; version = $Version }
    Write-Profile -Path $ProfilePath -Spec $spec
}

function Remove-ToolFromProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path $ProfilePath)) { return $false }
    $spec = Read-Profile -Path $ProfilePath -Raw
    if (-not $spec.ContainsKey('tools') -or -not $spec.tools.ContainsKey($Name)) { return $false }
    $spec.tools.Remove($Name)
    Write-Profile -Path $ProfilePath -Spec $spec
    return $true
}

Export-ModuleMember -Function `
    Get-ToolCatalog, `
    Get-ToolHandler, `
    Test-ToolInstalled, `
    Get-ToolVersion, `
    Get-ToolLatestVersion, `
    Compare-ToolVersion, `
    Get-ToolVersionCore, `
    Install-Tool, `
    Get-ToolsActualFromDistro, `
    Set-ToolInProfile, `
    Remove-ToolFromProfile, `
    Test-CommandInDistro, `
    Get-ToolFirstLineVersion, `
    Test-ToolIsHostAttachable, `
    Test-ToolHostAvailable
