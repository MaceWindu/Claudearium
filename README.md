# Claude Code WSL2 Sandbox

A PowerShell-managed WSL2 sandbox for running [Claude Code](https://docs.claude.com/en/docs/claude-code/) in an isolated environment with optional VPN tunnelling (WireGuard + killswitch) and optional Bluetooth-LED hooks via [Claudelk](https://github.com/MaceWindu/Claudelk) running on the Windows host.

> Run `.\claudearium.ps1` (no args) for the interactive central dashboard, or any of the verbs below directly.

## What this is

- A scripted way to create a **dedicated Debian 12 WSL2 distro** for Claude Code work, separate from your normal WSL distros.
- **Optional:** all sandbox traffic routed through a user-supplied WireGuard tunnel, with an nftables killswitch that drops anything not going through the VPN — **except** host-subnet traffic, so local services like a host-side Seq instance remain reachable.
- **Optional:** Windows-only utilities (e.g. Claudelk for BLE LED strips) reachable from inside the sandbox via WSL's Windows-interop bridge — no `usbipd` passthrough required, no host-side listener daemon needed.
- **Project-agnostic:** the same script bootstraps sandboxes for any project. Project layout, repo URL, mounts, tools, and Claude Code settings are all per-project configuration in a single declarative profile file.

## What this is *not*

- Not airgapped. Windows-interop is intentional — it's how the BLE bridge works. If you need true airgap, disable interop in `/etc/wsl.conf` (and lose Claudelk).
- Not a production deployment system.
- Not a replacement for your normal day-to-day WSL setup. It runs alongside.

## Requirements

| Requirement | Notes |
|---|---|
| Windows 10 build 1809+ or Windows 11 | bsdtar (`tar.exe`) ships in 1809+; needed to decompress the rootfs |
| WSL2 installed and enabled | `wsl --version` should report ≥ 2.0 |
| PowerShell 7+ | `pwsh` on `$PATH`; the script is pwsh-only |
| ~3 GB free disk in `%LOCALAPPDATA%\WSL\` | The default distro install path |
| Internet at first-run | To download the Debian 12 rootfs |
| **Optional:** a WireGuard `wg0.conf` | Any provider; user-supplied |
| **Optional:** `claudelk.exe` on the host | https://github.com/MaceWindu/Claudelk |

## Quick start

```powershell
.\claudearium.ps1 setup
```

Default behavior:
- Downloads the latest Debian 12 rootfs from `images.linuxcontainers.org`.
- Decompresses (`tar.exe`-based) and imports as `claudearium`.
- Creates a passwordless `claude` user with NOPASSWD sudo.
- Installs base packages: `git`, `curl`, `jq`, `nftables`, `wireguard-tools`, `sudo`, `systemd`, locales.
- Marks the distro provisioned in `%LOCALAPPDATA%\claudearium\<distro>\state.json`.

Then:

```powershell
.\claudearium.ps1 status
.\open-claudearium.ps1                   # launcher: drops you into a wsl shell
```

To tear everything down:

```powershell
.\claudearium.ps1 nuke           # asks for confirmation
.\claudearium.ps1 nuke -Force    # no confirmation
```

## Running multiple sessions concurrently

The sandbox supports **N parallel Claude Code sessions** in **different repos and/or different branches** of the same repo, all inside a single shared distro.

### The model

```
one WSL2 distro (claudearium)
  └── /home/claude/
        ├── mirrors/                       # one bare clone per project, shared across sessions
        │   ├── acme.git/
        │   └── otherproject.git/
        └── projects/
            ├── acme/
            │   └── sessions/
            │       ├── default/           # worktree on master
            │       ├── feat-1234/         # worktree on feature/PROJ-1234-...
            │       └── feat-5678/         # worktree on feature/PROJ-5678-...
            └── otherproject/
                └── sessions/
                    └── feature-foo/       # worktree on feature/foo
```

Each session is an independent `git worktree` off the project's bare mirror. Worktrees do not interfere — every session has its own checkout, its own branch, and its own Claude Code state under `.claude/`. The bare mirror is **shared**, so `git fetch` is deduplicated and you only pay disk cost for the working tree (typically a few hundred MB) rather than another full clone (typically a few GB).

### How you'll use it

```powershell
# One-time per project
.\claudearium.ps1 project add -Name acme          -Remote git@gitlab.example.com:acme/acme.git       -DefaultBranch master
.\claudearium.ps1 project add -Name otherproject  -Remote git@github.com:you/otherproject.git       -DefaultBranch main

# Spin up sessions
.\claudearium.ps1 session new -Project acme         -Name feat-1234 -Branch feature/PROJ-1234-some-feature
.\claudearium.ps1 session new -Project acme         -Name feat-5678 -Branch feature/PROJ-5678-other-feature
.\claudearium.ps1 session new -Project otherproject -Name feature-foo -Branch feature/foo

# Open three Claude Code sessions, each in its own terminal window
.\open-claudearium.ps1 -Project acme         -Session feat-1234
.\open-claudearium.ps1 -Project acme         -Session feat-5678
.\open-claudearium.ps1 -Project otherproject -Session feature-foo
```

Each `open-claudearium.ps1` invocation launches Windows Terminal (falling back to a plain `wsl` console) with `wsl -d claudearium -u claude --cd <session-worktree> -- claude`. They run **simultaneously**: WSL2 routes commands per-session, the kernel scheduler shares CPU/RAM fairly, and each session sees only its own worktree's filesystem changes.

### What's shared, what's isolated

| Resource | Shared across sessions | Isolated per session |
|---|---|---|
| The Debian distro itself | yes | — |
| Tool installs (`.NET`, `node`, `gh`, `glab`, `acli`, `seqcli`) | yes — installed once | — |
| Bare-mirror git data | yes — one fetch serves all sessions of the same project | — |
| Working tree (your edits) | — | per-session worktree directory |
| Git branch | — | each session is on a different branch |
| Claude Code conversation/state | — | per-worktree `.claude/` |
| WireGuard tunnel + killswitch | yes — one tunnel for the whole distro | — |
| `host.internal` access (e.g. Seq on the host) | yes | — |

### Concurrency caveats

- **One shared WireGuard tunnel** carries all session traffic. That's intentional — you only configured one VPN — but bandwidth-heavy work in one session will affect others.
- **CPU/RAM share the WSL2 VM.** WSL2 sizes itself based on `%USERPROFILE%\.wslconfig` (`memory=...`, `processors=...`). For multiple heavy sessions, bump those before launching.
- **Disk:** each worktree adds disk usage. Sessions on the *same* project share git history (one bare mirror), so the per-session cost is just the working-tree files.
- **Don't run two sessions on the same branch.** Git allows it (`worktree add --force`) but you'll get checkout conflicts. Use distinct branches per session — that's the whole point.

### `open-claudearium.ps1` — interactive session launcher

`open-claudearium.ps1` is the primary way to start a Claude Code session in the sandbox. Three modes:

**1. Bare-name dashboard.** `./open-claudearium.ps1` shows a table of every recorded session with project / session-name / branch / last-opened / dirty-state, plus row actions:

```
=== Claudearium: open ===
  #   Project          Session                Branch                           Last opened   Dirty
  --- -------          -------                ------                           -----------   -----
  1   acme             feat-1234              feature/PROJ-1234-some-feature   2h ago        3 files
  2   acme             feat-5678              feature/PROJ-5678-other-feature  yesterday     clean
  3   Claudelk         mainline               master                           30m ago       clean

  pick a #  open in wt tab
  l         open last-used session
  +         new session
  n         new project
  d <#>     remove session
  q         quit
```

Pick a number → spawns a new `wt` tab with `claude` running in that session's worktree. Pick `+` → walks the new-session wizard. Pick `l` → opens the most recently used session. `q` quits without launching anything.

**2. Direct-open by flags.** Skip the menu entirely:

```powershell
.\open-claudearium.ps1 -Project acme -Session feat-1234
.\open-claudearium.ps1 -Last                              # most recently used
.\open-claudearium.ps1 -Project foo -Session bar -Title 'urgent'   # override tab title
```

**3. New-session wizard.** From the dashboard's `+` action (or by running into an empty sessions list), the wizard walks:

1. **Pick project** — choose from existing projects, or `+` to add a new one (asks remote URL, project name, default branch; clones the bare mirror).
2. **Pick branch** — top-5 most recently committed branches from the project's bare mirror are listed with relative commit ages; pick one, type a custom existing branch name, or `+` to create a new branch off the project's default. The mirror is consulted via `git for-each-ref --sort=-committerdate`.
3. **Session name** — defaults to the last path segment of the branch (e.g. `feature/foo-bar` → `foo-bar`).
4. **wt tab title** — defaults to the session name; override to anything memorable (`🔥 race-fix`). Persisted per-session in state so re-opening reuses it.
5. Confirm → creates the worktree (`git worktree add ...`) and opens it in a new wt tab.

### Windows Terminal (`wt.exe`) integration

`open-claudearium.ps1` prefers [Windows Terminal](https://github.com/microsoft/terminal) and tunes its launch line for it:

- **Default:** new tab in the current `wt` window — three parallel invocations stack as three tabs side-by-side.
- **`-Title <string>`:** sets the tab title at launch time. Overrides the per-session persisted title.
- **`-NewWindow`:** brand-new top-level window per invocation.
- **`-NoTerminal`:** skip `wt.exe` entirely, drop into the current console (legacy `conhost`, ISE, etc.) — useful for scripting or when you want `claude` to inherit the current terminal.
- **Fallback:** if `wt.exe` isn't on `PATH`, the script silently falls back to `wsl -d <distro> -u claude --cd <worktree> -- bash -lc claude` in the current console.

`wt.exe` also auto-discovers the sandbox distro in its dropdown profile list, so you can spawn a bare shell manually via Ctrl-Shift-T → `claudearium` without going through the script at all.

#### Admin / elevated terminals

`wt.exe` cannot share a window across the UAC boundary. The combination matrix:

| Caller elevation | Existing `wt` window | Result |
|---|---|---|
| non-elevated | non-elevated | new tab in that window ✓ |
| elevated | elevated | new tab in that window ✓ |
| non-elevated | only elevated exists | new non-elevated window spawned |
| elevated | only non-elevated exists | new elevated window spawned |
| any | no existing window | new window matching caller's elevation |

The sandbox itself does **not** need admin (`wsl --import`/`--unregister` run as a normal user). Launch `open-claudearium.ps1` from a non-elevated terminal — that way all sessions stack as tabs in one non-elevated `wt` window. If you happen to be in an elevated shell, expect a separate elevated `wt` window to appear.

## Verbs

### `setup`

Creates the distro from scratch.

```
.\claudearium.ps1 setup [-Name <distro>] [-RootfsPath <path>] [-RootfsUrl <url>]
                           [-InstallPath <dir>] [-Force] [-NonInteractive]
```

| Flag | Default | Meaning |
|---|---|---|
| `-Name` | `claudearium` | WSL distro name |
| `-RootfsPath` | *(download)* | Local path to a `.tar` / `.tar.xz` / `.tar.gz` rootfs |
| `-RootfsUrl` | *(latest from linuxcontainers)* | Override the rootfs URL |
| `-InstallPath` | `%LOCALAPPDATA%\WSL\<Name>` | Where the distro VHDX lives |
| `-Force` | off | Wipe and re-setup if an existing distro of this name is found |
| `-NonInteractive` | off | Fail rather than prompt |

### `status`

Reports distro state (`Running` / `Stopped` / `Missing`), the state-file location, and the recorded provisioning info.

```
.\claudearium.ps1 status [-Name <distro>]
```

### `nuke`

Unregisters the distro and removes its state directory. Asks for confirmation unless `-Force`.

```
.\claudearium.ps1 nuke [-Name <distro>] [-Force] [-NonInteractive]
```

### `reconcile`

Reads the profile, diffs it against the recorded state, prints the diff, and prompts to apply. Each block (distro, projects, mounts, tools, host-tools, vpn) has its own diff/apply path; destructive `distro` changes (rename, install-path move) route through `nuke -Force` + `setup`.

```
.\claudearium.ps1 reconcile [-ProfilePath <path>] [-NonInteractive] [-Force]
```

### `project <subverb?>`

**`project`** (no subverb) — interactive dashboard listing projects with row-actions (`+` add, `s <n>` show, `d <n>` remove, `q` quit).

**`project add [<name>]`** — adds a project to the profile and clones its bare mirror inside the distro. Smart defaults pull from `-HostCheckout`'s `origin` URL (or the current working directory if it's a git checkout). Falls back to `master` for the default branch. The repo name is derived from the URL's last path segment.

```powershell
# Auto-detect from the host checkout (recommended; the wizard's defaults are pre-filled).
.\claudearium.ps1 project add -HostCheckout C:\src

# Fully scripted.
.\claudearium.ps1 project add acme `
  -Remote git@gitlab.example.com:acme/acme.git `
  -DefaultBranch master `
  -NonInteractive
```

**`project list`** — table of projects with profile-vs-materialized status. Useful for noticing drift (mirror present but not in profile, or vice-versa — both nudge you toward `reconcile`).

**`project show <name>`** — detailed view of one project, including any sessions tracked against it.

**`project remove <name>`** — deletes bare mirror, every session of this project, and the profile entry. Asks for confirmation unless `-Force`.

### `session <subverb?>`

**`session`** (no subverb) — interactive dashboard of all sessions across all projects (filter with `-Project`). Row-actions: `d <n>` remove, `q` quit.

**`session new <name>`** — creates a git worktree under the project's bare mirror.

```powershell
# Check out an existing branch:
.\claudearium.ps1 session new mainline -Project Claudelk -Branch master

# Create a new branch off the project's default branch:
.\claudearium.ps1 session new feat-1234 -Project acme -Branch feature/PROJ-1234-some-feature -NewBranch -BaseBranch master
```

Sessions live at `/home/claude/projects/<project>/sessions/<session>` inside the distro and share the bare mirror at `/home/claude/mirrors/<project>.git` with every other session of the same project. Subsequent `git fetch`es from any session populate the mirror once for all of them.

**`session list [-Project <p>]`** — table with project / session / branch / dirty state / created-at.

**`session remove <name> -Project <p>`** — removes the worktree (and prunes the bare mirror's worktree metadata). Refuses if the worktree has uncommitted files unless `-Force`.

### Authentication via host SSH keys

The easiest fix for the no-SSH-keys-in-sandbox problem is mounting your host's `~/.ssh` directly:

```powershell
.\claudearium.ps1 mount add "$env:USERPROFILE\.ssh" `
  -Guest /home/claude/.ssh `
  -Mode ro `
  -MountOptions 'umask=077'
```

SSH client refuses keys with permissions wider than 0600; `umask=077` here gives the mount group/other no access. After this, `git clone git@gitlab.example.com:...` works from inside the sandbox using your host key.

### `mount <subverb?>`

**`mount`** (no subverb) — interactive dashboard of mounts with row actions (`+` add, `d <n>` remove, `s` sync, `q` quit).

**`mount add [<host-path>]`** — adds a drvfs mount of a Windows path into the sandbox. Smart default for `-Guest`: `/host/<basename>` (lowercased). Default mode is `ro`. `-MountOptions` lets you append drvfs options (e.g. `umask=077` for `~/.ssh`).

```powershell
# Mount a host folder read-only at /host/src:
.\claudearium.ps1 mount add C:\src -Guest /host/src -Mode ro -NonInteractive

# Read-write a scratch exchange folder:
.\claudearium.ps1 mount add "$env:USERPROFILE\claudearium-exchange" -Guest /host/exchange -Mode rw
```

**`mount list`** — table of mounts. Shows whether each is in the profile, in the distro's `/etc/fstab`, and currently mounted.

**`mount remove <guest>`** — drops the mount. Tries `umount`, falls back to `umount -l` (lazy) if busy, then strips the fstab entry and the profile entry.

**`mount sync`** — re-applies whatever's in the profile to the distro. Useful after a manual `/etc/fstab` edit or when reconcile feels heavyweight.

### `claude-settings <subverb?>` — synthesize ~/.claude/settings.json

The `claude-settings` verb generates Claude Code's user-level settings file from two sources merged together:

1. **Always-set sandbox defaults** (immutable, not asked):
   - `cleanupPeriodDays: 30`
   - `includeCoAuthoredBy: false`
   - `env.CLAUDEARIUM_NAME` / `env.CLAUDEARIUM_MODE`
   - `permissions.deny` for known-dangerous shell patterns (`rm -rf /`, `curl | sh`, etc.)
2. **Opinionated from `profile.claudeSettings`** (asked by the wizard or set in the profile):
   - `model` — e.g. `claude-opus-4-7` (effort bracket auto-appended from `defaultEffort`)
   - `defaultEffort` — `low` / `medium` / `high` / **`xhigh`** (recommended for sandbox use)
   - `theme` — `dark` / `light` / `system`
   - `autoApproveReadOnlyBash` — pre-approves `git status|log|diff|show|branch`, `ls`, `cat`, `head`, `tail`, `pwd`, `echo`, `which`, `whoami`, `gh:*`, `glab:*`, `acli:*`, `seqcli:*`
   - `autoApproveProjectWrites` — pre-approves `Edit`, `Write`, `Glob`, `Grep`
   - `autoApproveBuildCommands` — pre-approves `dotnet build/test/restore/run`, `npm install/run`
   - `claudelk` (bool) + `claudelkEvents` ([Stop, Notification, ...]) — wires hooks that call `sb-claudelk color '#XXXXXX'` on the selected events

**Verbs:**

| Subverb | Effect |
|---|---|
| `claude-settings show` | `cat /home/claude/.claude/settings.json` |
| `claude-settings apply` | Render profile.claudeSettings → write `/home/claude/.claude/settings.json` |
| `claude-settings reconfigure` | Interactive wizard (pre-populated from current profile), then apply |

**Reconcile note.** The settings file is **not** part of `reconcile`'s diff — hashtable-key ordering through `ConvertTo-Json` makes drift detection unreliable, and settings are user preferences rather than infrastructure. Run `claude-settings apply` explicitly after editing the profile (or use `reconfigure` for an interactive walkthrough).

**Profile shape:**

```jsonc
"claudeSettings": {
  "model":                    "claude-opus-4-7",
  "defaultEffort":            "xhigh",
  "theme":                    "dark",
  "autoApproveReadOnlyBash":  true,
  "autoApproveProjectWrites": true,
  "autoApproveBuildCommands": false,
  "claudelk":                 true,
  "claudelkEvents":           ["Stop", "Notification"]
}
```

### `host-tools <subverb?>` — wrap Windows .exe utilities (Claudelk + friends)

The original goal: invoke [Claudelk](https://github.com/MaceWindu/Claudelk) (a Windows-only BLE LED-strip controller) from inside the sandbox without rebuilding it for Linux. The `host-tools` system is the generalized solution — it produces small bash wrappers in `/usr/local/bin/` that `exec` a Windows `.exe` through WSL's binfmt interop bridge. The wrappers carry a managed-by marker so the tool can enumerate and clean up what it owns.

**Profile shape:**

```jsonc
"hostTools": [
  {
    "name":         "claudelk",
    "windowsExe":   "C:\\Tools\\Claudelk\\claudelk.exe",
    "guestCommand": "sb-claudelk",
    "smokeTest":    "scan"
  }
]
```

`windowsExe` accepts either a Windows path (`C:\Tools\Claudelk\claudelk.exe` — auto-converted to `/mnt/c/Tools/Claudelk/claudelk.exe`) or a guest path (`/host/claudelk/claudelk.exe`, when you've added a selective mount for it via the `mount` verb). `guestCommand` is the bare filename you'll invoke from inside (no slashes).

**Verbs:**

| Subverb | Effect |
|---|---|
| `host-tools` (bare) | Interactive dashboard with row actions. |
| `host-tools add [<exe>]` | Register a new wrapper. `-HostExe` / `-GuestCommand` / `-SmokeTest` flags; otherwise prompts. |
| `host-tools list` | Profile + actual-wrapper table. |
| `host-tools remove <cmd>` | Drop wrapper + profile entry. |
| `host-tools sync` | Re-apply profile to the distro idempotently. |
| `hooks test` | Run the registered `smokeTest` for each host-tool with one. |

**Cookbook — Claudelk:**

```powershell
.\claudearium.ps1 host-tools add "C:\Tools\Claudelk\claudelk.exe" `
  -GuestCommand sb-claudelk `
  -SmokeTest scan `
  -NonInteractive

# Inside the sandbox now:
sb-claudelk scan
sb-claudelk color "#ff8800"
```

Claude Code hooks in `~/.claude/settings.json` use the wrapper directly — this is wired up automatically via the `claudeSettings.claudelk` flag in the profile.

**WSL interop binfmt** is auto-registered when you install your first host-tool, via a one-shot systemd unit (`claudearium-wsl-interop.service`). WSL2 + systemd doesn't register the `.exe` binfmt automatically, which is a known WSL bug — without our unit, running a Windows `.exe` from inside fails with "Exec format error".

### `vpn <subverb?>` — WireGuard + nftables killswitch

The `vpn` verb routes the sandbox's traffic through a user-supplied WireGuard tunnel, with an nftables killswitch that drops every off-host packet that didn't go through `wg0`. The killswitch **explicitly punches a hole for the WSL2 NAT subnet** so host-side services (Seq on the user's Windows host, IIS, etc.) remain reachable via the auto-managed `host.internal` hostname.

**Profile shape:**

```jsonc
"vpn": {
  "wgConfigPath": "C:\\Users\\you\\wireguard\\wg0.conf",
  "killswitch":   true
}
```

`wgConfigPath` points to your WireGuard config on the Windows host. The sandbox copies it in at `vpn enable` time and applies an [**AllowedIPs split-routing transform**](https://www.procustodibus.com/blog/2022/02/wireguard-allowedips-split/) — `0.0.0.0/0` → `0.0.0.0/1, 128.0.0.0/1` — so wg-quick installs plain routes in the main table instead of the policy-routing trick that would otherwise swallow more-specific routes (including the eth0 → host-subnet route).

**Verbs:**

| Subverb | Effect |
|---|---|
| `vpn` (bare) | Status snapshot + interactive menu (e/d/r/t/q). |
| `vpn enable` | Push payload (idempotent), copy + transform `wg0.conf` to `/etc/wireguard/wg0.conf`, restart killswitch-prep + nftables + `wg-quick@wg0`. |
| `vpn disable` | Stop `wg-quick@wg0`. **The killswitch stays armed** — the sandbox is offline until re-enabled. That's intentional: no leak. |
| `vpn reload` | Restart the three units to apply config changes (`wg0.conf` edits, etc.). |
| `vpn status` | Killswitch on/off, tunnel up/down, `wg show`, `host.internal` reachability. |
| `vpn test` | Quick connectivity probes (`ping host.internal`, `curl https://1.1.1.1`). |

**What's running inside the distro:**

```
claudearium-killswitch.service   # oneshot, Before=nftables.service wg-quick@wg0.service
                             # Generates /etc/nftables.conf.d/00-host.nft with
                             # HOST_SUBNET / WG_PEER_IP / WG_PEER_PORT defines.
                             # Also writes 'host.internal -> <gateway>' into /etc/hosts.
nftables.service             # Loads /etc/nftables.conf (includes 00-host.nft).
wg-quick@wg0.service         # Brings up wg0 via the user's transformed config.
```

The order is enforced by systemd `Before=` / `After=` directives so the killswitch is armed **before** the tunnel comes up at boot.

**Quick start, given a wg0.conf on the host:**

```powershell
.\claudearium.ps1 profile edit
# add the vpn block (above)
.\claudearium.ps1 vpn enable
.\claudearium.ps1 vpn status
```

Then validate from inside the sandbox: `curl https://api.ipify.org` should return your VPN endpoint's IP, and `curl http://host.internal:5341` should still reach a host-side Seq.

### `tools <subverb?>`

The sandbox bundles a small registry of CLI tools that Claude Code workflows lean on. Catalog: `node` (via nvm), `claudeCode`, `gh`, `glab`, `acli`, `dotnet` (per-user, via `dotnet-install.sh`), `seqcli` (.NET global tool — depends on `dotnet`), `pwsh` (Microsoft Debian apt repo).

> **Disk note.** `dotnet` adds ~500 MB to the distro; install it only if you actually run .NET builds in the sandbox. `seqcli` depends on `dotnet` and is auto-installed when you `tools install seqcli`. `pwsh` adds ~150 MB.

**`tools`** (no subverb) — interactive dashboard. Row-actions: `i <n>` install (or upgrade) one tool, `e <n>` enable in profile, `x <n>` disable, `s` sync (install everything enabled-but-missing), `q` quit.

**`tools list`** — table of catalog tools with desired (profile) vs actual (installed) state. Read-only.

**`tools install <name>`** — installs the named tool right now and marks it `enabled: true` in the profile. Dependencies are resolved eagerly (e.g. `tools install claudeCode` brings in `node` first if missing).

**`tools enable <name>`** / **`tools disable <name>`** — flip the profile flag without touching the distro. Disabling never uninstalls — that's deliberate (avoids surprising data loss in npm caches etc.). Re-enable + `tools sync` to bring back into use.

**`tools sync`** — applies the profile against the distro: installs everything enabled-but-missing in dependency order. Idempotent.

```powershell
.\claudearium.ps1 tools install claudeCode        # also installs node (dependency)
.\claudearium.ps1 tools list
.\claudearium.ps1 tools sync                       # bulk install all enabled
```

### `login <subverb?>`

**`login`** (no subverb) — menu of supported auth flows, marked `ready` or `not installed`.

**`login claude`** — runs `claude` interactively (first-run kicks off OAuth via the host's default browser through WSL interop).

**`login gh`** / **`login glab`** — runs each CLI's own `auth login` flow. Stdio is passed straight through to your terminal, so device-flow URLs, token prompts, etc., all work as expected.

**`login acli`** — runs `acli` for its interactive setup flow.

Each login verb is **re-runnable** — designed for token rotation. The session ends when the underlying CLI exits.

### Tools-installs and the killswitch

`tools sync` and `tools install` need network reachability to package mirrors / GitHub / GitLab through whatever route the VPN allows. The `host.internal` exception keeps host-Seq style endpoints reachable separately.

### How mounts work

The sandbox's `/etc/wsl.conf` has `[automount] enabled=false` — no `/mnt/c/` tree at all. Instead, the sandbox owns a managed block inside `/etc/fstab`:

```
# === claudearium-managed-start ===
C:/src/acme /host/acme drvfs ro,metadata,uid=1000,gid=1000,umask=022 0 0
# === claudearium-managed-end ===
```

`mount add`/`remove`/`sync` rewrite this block atomically and run `mount -a`. `systemd-fstab-generator` picks it up at boot, so mounts survive distro restarts. Anything outside the managed block (your other fstab entries, if any) is left alone.

drvfs options the sandbox sets by default: `metadata,uid=1000,gid=1000,umask=022`. The `metadata` flag stores Linux-style permission bits in NTFS streams so file modes are preserved; uid/gid pin the mount to the `claude` user. Custom `-MountOptions` are appended.

### `profile <subverb>`

`validate <path?>` — schema check; warnings + errors; exit 0/1. Path defaults to the default profile path.

`export -Out <path>` — write current state as a profile file at `<path>`.

`edit <path?>` — opens the profile in `$env:EDITOR` / VS Code / notepad. Seeds a profile from current state (or from the example template) if none exists yet.

`show <path?>` — pretty-prints the parsed profile with env vars expanded.

```
.\claudearium.ps1 profile validate
.\claudearium.ps1 profile export -Out C:\backup\claudearium.profile.json
.\claudearium.ps1 profile edit
.\claudearium.ps1 profile show
```

## Layout

```
├── claudearium.ps1            # entry point
├── open-claudearium.ps1               # session launcher
├── modules/
│   ├── State.psm1        # state.json read/write + recents helper
│   ├── UI.psm1           # Read-Choice / YesNo / Multi
│   ├── Wsl.psm1          # distro lifecycle, rootfs handling, Invoke-InDistro
│   ├── Profile.psm1      # profile read/write/validate/diff
│   ├── Projects.psm1     # bare-mirror lifecycle + profile mutation
│   ├── Sessions.psm1     # git-worktree-based session lifecycle
│   ├── Mounts.psm1       # selective drvfs host mounts via /etc/fstab
│   ├── Tools.psm1        # tools registry + per-tool install handlers
│   ├── Vpn.psm1          # WireGuard + nftables killswitch lifecycle
│   ├── HostTools.psm1    # WSL-interop wrappers for Windows .exe
│   └── ClaudeSettings.psm1 # Claude Code settings.json synthesis
├── payload/
│   └── etc/wsl.conf              # written to /etc/wsl.conf
├── scripts/
│   └── bootstrap-distro.sh       # runs as root in the fresh distro
├── templates/
│   └── claudearium.profile.example.json
└── README.md
```

State (per-distro):

```
%LOCALAPPDATA%\claudearium\<distro>\state.json
```

## Profile-driven setup

The profile is the declarative source of truth. Edit it, run `reconcile`, and the sandbox is brought in line.

**Location.** Default path is `%LOCALAPPDATA%\claudearium\claudearium.profile.json` — per-user, lives next to state. Override with `-ProfilePath`. The profile is never committed to a repo (it contains user-specific paths).

**Lifecycle:**

```powershell
.\claudearium.ps1 profile edit             # opens (and seeds if missing) the default profile
.\claudearium.ps1 profile show             # pretty-print parsed profile with env vars expanded
.\claudearium.ps1 profile validate         # validate the default profile
.\claudearium.ps1 profile validate <path>  # validate a specific file
.\claudearium.ps1 profile export -Out <p>  # serialise current state into a new profile file
.\claudearium.ps1 reconcile                # show diff, prompt, apply
.\claudearium.ps1 setup                    # if a profile exists, its distro block overrides -Name/-InstallPath
```

**Schema:** see `templates/claudearium.profile.schema.json` for the full JSON Schema, and `templates/claudearium.profile.example.json` for an annotated example. Top-level blocks: `distro`, `vpn`, `tools`, `projects` (with nested `hostMounts`, `hostTools`, `claudeSettings`).

`%ENV_VAR%` tokens in string values are expanded at read time. JSON `null` is allowed for fields the user wants to leave blank (no validation error).

**Reconcile semantics.** Most block changes apply in place (mounts, tools, projects, host-tools, vpn). The exception is the `distro` block — renaming the distro or moving its install path requires unregister + reimport (WSL can't do either in place), so those diffs are marked destructive and `reconcile` will offer to run `nuke -Force` and re-`setup` for you.

**Edit flow:**

```
.\claudearium.ps1 profile edit       # opens in $env:EDITOR (or VS Code, or notepad)
# edit ...
.\claudearium.ps1 reconcile           # see diff + apply
```

**Validation.** `profile validate` returns exit code 0 (OK + any warnings) or 1 (errors), so it slots into CI cleanly.

**Recents.** Every time `reconcile` or `setup-with-profile` consumes a profile, its absolute path is recorded in `state.recents.profilePaths` (most-recent first, dedup'd, trimmed to 5). Interactive pickers use this to pre-fill choices.

**Example profile:** `templates/claudearium.profile.example.json` shows the full shape.

## Architecture notes

**Why `wsl --import` not Store install.** Store distros come with first-run user-creation prompts and aren't great for automation. `--import` plus a custom rootfs gives full control and is reproducible across machines.

**Why `tar.exe`-based decompression.** WSL2's `--import` historically wants an uncompressed `.tar`. `tar.exe` (bsdtar) on Windows 1809+ handles `.tar.xz` natively via libarchive. We extract to a staging dir, repack as plain `.tar`, and import.

**Passwordless `claude` user.** This sandbox isolates the host from a runaway agent, not the human user from themselves. Sudo prompts add no defense against the in-scope threat model, only friction.

## Cookbook

### End-to-end setup

```powershell
# 1. Create the distro.
.\claudearium.ps1 setup

# 2. Wire your host SSH key so private-repo clones work (read-only mount).
.\claudearium.ps1 mount add "$env:USERPROFILE\.ssh" `
    -Guest /home/claude/.ssh -Mode ro -MountOptions 'umask=077' -NonInteractive

# 3. Install the toolchain.
.\claudearium.ps1 tools install claudeCode  # also pulls node
.\claudearium.ps1 tools install glab
.\claudearium.ps1 tools install acli
.\claudearium.ps1 tools install seqcli      # also pulls dotnet 10
.\claudearium.ps1 tools install pwsh

# 4. Tell Claude Code how to behave.
.\claudearium.ps1 claude-settings reconfigure   # walks the wizard

# 5. Set up the project + a session.
.\claudearium.ps1 project add -HostCheckout C:\src        # auto-detects remote
.\claudearium.ps1 session new default -Project acme -Branch master

# 6. Sign in to the CLIs.
.\claudearium.ps1 login claude
.\claudearium.ps1 login glab
.\claudearium.ps1 login acli

# 7. Open a Claude Code session.
.\open-claudearium.ps1                # interactive dashboard
```

### "I want VPN with Seq still working"

```powershell
# Edit your profile (or create one via `profile edit`):
#   "vpn": { "wgConfigPath": "C:\\Users\\you\\wireguard\\wg0.conf", "killswitch": true }

.\claudearium.ps1 vpn enable
.\claudearium.ps1 vpn status      # tunnel up, killswitch armed, host.internal reachable
```

From inside the sandbox, `curl http://host.internal:5341` still hits your host-side Seq even with the killswitch on.

### "Wire Claudelk into Claude Code's hooks"

```powershell
.\claudearium.ps1 host-tools add "C:\Tools\Claudelk\claudelk.exe" `
    -GuestCommand sb-claudelk -SmokeTest scan -NonInteractive

.\claudearium.ps1 hooks test       # confirms sb-claudelk responds

# Edit profile.claudeSettings.claudelk = true (or via wizard):
.\claudearium.ps1 claude-settings reconfigure
.\claudearium.ps1 claude-settings apply
```

The LED strip will now flash on `Stop` / `Notification` events from any Claude Code session inside the sandbox.

## Troubleshooting

**`tar.exe not found on PATH`** — Windows 10 1809+ ships it. Confirm with `where tar`. If missing, install Git for Windows (provides bsdtar) or pre-decompress and pass `-RootfsPath plain.tar`.

**`wsl --import failed`** — usually one of: distro name already exists (pick another or `-Force`), install path is on a network drive (use a local path), Hyper-V/WSL2 not enabled. Run `wsl --version` to verify.

**`Could not resolve latest rootfs timestamp`** — `images.linuxcontainers.org` listing changed format or is unreachable. Workaround: download a rootfs manually and pass `-RootfsPath`.

**Default user is `root` after setup** — bootstrap didn't run or `wsl.conf` wasn't applied. Run `wsl -t <distro>` to terminate, then `wsl -d <distro>` again. If the issue persists, check `cat /etc/wsl.conf` inside the distro.

**Multi-line bash scripts produce empty output for `$VAR` references** — known WSL pipe quirk: `wsl.exe -d <distro> -- bash -lc <script>` pre-expands `$VAR` references in argv to empty before bash sees them. The tool transports anything multi-line through base64 (`Invoke-InDistroScript`) to bypass this. If you write your own scripts that talk to the distro, use the same pattern, or escape `$` very carefully.

**`wsl: Failed to start the systemd user session for ...`** — harmless. WSL2 + systemd needs `loginctl enable-linger` for the systemd-logind / dbus chain to come up, but that itself requires logind running (chicken-and-egg). The tool filters this warning out of all `Invoke-InDistro` output; if you see it from a direct `wsl.exe` call, ignore it. Functionality is unaffected.

**`Exec format error` running a Windows .exe wrapper** — the WSL `.exe` binfmt isn't registered. The host-tools subsystem installs a systemd unit (`claudearium-wsl-interop.service`) to fix this at every boot. Force it now: `wsl -d <distro> -u root -- bash -c 'echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'`.

**`nft: Interface does not exist`** — the older `iif wg0` form requires the interface to exist at rule-load time. The tool's ruleset uses `iifname "wg0"` (string match, late-resolved) instead. If you've manually edited `/etc/nftables.conf`, prefer `iifname`.

**`apt-get install /tmp/foo.deb` fails finding ldconfig** — sudo with `!secure_path` inherits the `claude` user's login PATH, which lacks `/sbin`. The tool's `dpkg`-using install scripts (pwsh handler) prepend `/usr/local/sbin:/usr/sbin:/sbin:$PATH` before calling dpkg. Do the same in your own scripts.

## Design documentation

For people working *on* the tool (not just using it), the `docs/` subfolder
covers architecture, design decisions, WSL2 / pwsh gotchas hit during the
build, and how to extend each subsystem. Start at
[`docs/`](./docs/README.md).

| Doc | When to read |
|---|---|
| [`docs/architecture.md`](./docs/architecture.md) | First — module map, profile-vs-state model, verb dispatch |
| [`docs/design-decisions.md`](./docs/design-decisions.md) | Before changing something that looks "wrong" — it might be deliberate |
| [`docs/wsl2-gotchas.md`](./docs/wsl2-gotchas.md) | Before adding code that crosses the pwsh ↔ WSL ↔ systemd boundary |
| [`docs/extending.md`](./docs/extending.md) | When adding a new tool / host-tool / profile block / verb / module |

## License / attribution

MIT — see [LICENSE](./LICENSE). [Claudelk](https://github.com/MaceWindu/Claudelk) is © MaceWindu and the LED-strip wrappers integrate with it via [WSL Windows-interop](https://learn.microsoft.com/en-us/windows/wsl/filesystems#run-windows-tools-from-linux).
