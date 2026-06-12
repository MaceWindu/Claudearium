# Architecture

How the pieces fit together. Read this first when joining the project or before
making structural changes. For the *why* behind specific choices see
[design-decisions.md](./design-decisions.md). For pwsh ↔ WSL2 quirks discovered
during the build see [wsl2-gotchas.md](./wsl2-gotchas.md).

## 30-second mental model

A PowerShell front-end on the Windows host drives a WSL2 Debian 12 distro that
hosts the user's Claude Code sessions. The host script never holds long-lived
state — the **profile** (a JSON file under `%LOCALAPPDATA%`) describes the
desired sandbox; the **distro filesystem + per-distro state.json** is the actual
sandbox. A `reconcile` verb diffs the two and applies changes.

```
Windows host                            │   WSL2 distro (Debian 12)
──────────────────────────────────────  │  ──────────────────────────────────
claudearium.ps1   (entry)            │   /home/claude/                  (lobby user)
open-claudearium.ps1      (session launcher) │   /home/cp-<project>/             (per-project user, 0700)
modules/*.psm1       (capabilities)     │   /home/cp-<project>/mirrors/<p>.git (bare clones)
                                        │   /home/cp-<project>/projects/<p>/sessions/<s>/ (worktrees)
payload/             (etc/, usr/...)    │   /etc/fstab                     (managed-block mounts)
scripts/             (bootstrap.sh)     │   /etc/wireguard/wg0.conf        (VPN, if enabled)
                                        │   /etc/nftables.conf             (killswitch)
%LOCALAPPDATA%\claudearium\          │   /usr/local/bin/sb-*            (host-tool wrappers)
  ├── claudearium.profile.json (desired)    │   /home/claude/.claude/settings.json  (synthesized)
  └── <distro>/state.json  (actual)     │
```

Each project runs as its own dedicated Linux user (`cp-<project>`) with a `0700`
home, so projects are isolated from each other on the filesystem; `claude`
remains the default "lobby" user. The project→user mapping lives in `state.json`.
See [design-decisions.md §25](./design-decisions.md#25-per-project-linux-users-filesystem-isolation-between-projects).

The host script reaches into the distro through `wsl.exe -d <name> -u <user>
-- bash -lc <command>`. For multi-line scripts that use shell variables, the
command is base64-encoded on the pwsh side and decoded inside the distro to
sidestep argv mangling — see [wsl2-gotchas.md](./wsl2-gotchas.md#1-wslexe-argv-mangles-var-and-strips-backslashes).

## Code layout

```
├── claudearium.ps1            # entry-point: verb dispatch + bare-name dashboard
├── open-claudearium.ps1               # session launcher: dashboard, wizard, direct-open
├── modules/                      # capabilities, loaded by both entry-points
│   ├── State.psm1            # per-distro state.json (recents, sessions, install paths, project users)
│   ├── Users.psm1           # per-project Linux users: derive/allocate, provision (useradd/chpasswd), seed creds
│   ├── UI.psm1               # Read-YesNo / Read-Choice / Read-Multi / Read-TabColor / Read-OpacityPercent
│   ├── Wsl.psm1              # distro lifecycle + Invoke-InDistro{Script}
│   ├── Profile.psm1          # profile read/write/validate + Get-*Diff per block
│   ├── Projects.psm1         # bare-mirror clones + profile mutation (per-half: Get-ProjectHalves, Add/Remove-ProjectHalfInProfile)
│   ├── Sessions.psm1         # git-worktree-per-session + Get-RecentBranches
│   ├── Mounts.psm1           # drvfs host mounts via /etc/fstab managed block
│   ├── Prune.psm1            # drift detection (orphan sessions, stale worktrees, dangling mounts, heavy artifacts)
│   ├── Temp.psm1             # scratch / cache sizing + scope-aware wipe (/tmp, ~/.cache, ~/.claude)
│   ├── Tools.psm1            # tool catalog (handler registry)
│   ├── ToolUpdates.psm1      # latest-upstream-version cache + background refresh
│   ├── HostTools.psm1        # WSL-interop wrappers for Windows .exe
│   ├── HostToolNotes.psm1    # per-tool note authoring + managed CLAUDE.md block
│   ├── Vpn.psm1              # WireGuard + nftables killswitch
│   ├── ClaudeSettings.psm1   # synthesize per-user ~/.claude/settings.json
│   ├── ClaudeFile.psm1       # render CLAUDE.md content (host-copy / caveman-lite / custom-path) — pure renderer
│   ├── ClaudeShared.psm1     # shared group-writable account store (CLAUDE.md+skills+agents) symlinked into every ~/.claude; host import; backup/restore
│   ├── WinTerminal.psm1      # generate the WT profile fragment (per-project icon / background image / opacity)
│   └── SelfUpdate.psm1       # local VERSION vs latest release; manifest-diff apply
├── payload/                      # files pushed into the distro at setup / reconcile
│   ├── etc/wsl.conf
│   ├── etc/nftables.conf
│   ├── etc/systemd/system/claudearium-killswitch.service
│   └── usr/local/bin/claudearium-killswitch-prep
├── scripts/
│   └── bootstrap-distro.sh       # runs as root inside the fresh distro at setup
├── templates/
│   ├── claudearium.profile.example.json
│   ├── claudearium.profile.schema.json
│   └── host-tool-notes/         # per-tool CLAUDE.md notes (acli/gh/glab/seqcli)
└── docs/                         # you are here
```

## The two-state model: profile vs state

The whole tool is built around a strict separation:

| | **Profile** | **State** |
|---|---|---|
| Path | `%LOCALAPPDATA%\claudearium\claudearium.profile.json` | `%LOCALAPPDATA%\claudearium\<distro>\state.json` |
| Owner | user (edit by hand or via wizard) | the tool (read-only from user's perspective) |
| Role | *desired* state — what should exist | *actual* state — what does exist (+ ephemeral metadata) |
| Contents | distro / vpn / tools / projects / projectDefaults / hostMounts / hostTools / claudeSettings / claudeFile | recents, sessions, install path, provisioning timestamps |
| Survives `nuke` | yes | no |

Reconcile is the operator that brings the distro's *actual* state in line with
the profile's *desired* state. For each profile block, `Profile.psm1`
provides a `Get-*Diff` function returning add / remove / modify changes; the
entry-point's `Invoke-Reconcile` assembles them into a combined diff, prompts
the user, then dispatches to per-block `Invoke-*Apply` helpers.

Notable exceptions to the diff/apply model:

- **`claudeSettings`** is intentionally out of reconcile's diff. Hashtable key
  ordering through `ConvertTo-Json` makes drift detection unreliable, and
  settings are user preferences rather than infrastructure. Apply explicitly via
  `claude-settings apply` / `reconfigure`.
- **Distro-block changes (rename, install-path move)** can't apply in place — WSL
  doesn't support either operation on a live distro. Reconcile routes those
  through `nuke -Force` + `setup` (rebuilds from scratch, then re-applies
  projects + mounts + tools + host-tools).
- **The Windows Terminal profile fragment** (per-project `icon` /
  `backgroundImage` / `backgroundImageOpacity`, with the global
  `projectDefaults.backgroundImageOpacity` fallback) is a host-side artifact, not
  distro state. It isn't part of the diff: reconcile (and `project add`)
  unconditionally regenerate it via `WinTerminal.psm1`'s `Update-WtFragment`,
  which rewrites idempotently and only reports a change when the on-disk content
  actually differs. See design-decisions §27.

## Module dependency graph

```
                ┌── State ──┐
                │                   │
UI ─────┤                   ├── Wsl ──┐
                │                   │                 │
claudearium.profile ┤                   │                 ├── Vpn
                │                   │                 │
                │                   │                 ├── Mounts
                │                   │                 │
                │                   │                 ├── Tools
                │                   │                 │
                │                   │                 ├── Projects
                │                   │                 │   ├── (uses claudearium.profile for Add/Remove)
                │                   │                 │   └── (uses Wsl  for git clone via Invoke-InDistro)
                │                   │                 │
                │                   │                 ├── Sessions
                │                   │                 │   └── (uses Projects)
                │                   │                 │
                │                   │                 ├── HostTools
                │                   │                 │
                │                   │                 └── ClaudeSettings
                │                   │
                └───────────────────┴── claudearium.ps1 + open-claudearium.ps1
```

`Wsl` is the foundation for any module that touches the distro.
`claudearium.profile` is the foundation for any module that mutates configuration.
The entry-points import everything; modules import only their direct
dependencies (and never with `-Force`, see
[wsl2-gotchas.md](./wsl2-gotchas.md#10-cascading-import-module--force-invalidates-script-scope-imports)).

## Verb dispatch

The entry-point's structure:

```powershell
param([Position=0]$Verb, [Position=1]$SubVerb, [Position=2]$Arg, <flags...>)

# Module imports

# Helpers (Show-Help, Resolve-ProfilePath, Resolve-DistroForOps, etc.)

# Per-verb handler functions: Invoke-<Verb> + Invoke-<Verb><SubVerb>
#   - Each verb has a dashboard (bare-name) + flag-driven subverbs
#   - Per-block reconcile helper: Invoke-<Block>Apply

# Central dashboard (Invoke-CentralDashboard) for bare-name invocation

# Final switch:
if ($Help) { Show-Help; exit 0 }
if (-not $Verb) { Invoke-CentralDashboard; exit 0 }
switch ($Verb) { ... 'tools' { Invoke-Tools }; 'vpn' { Invoke-Vpn }; ... }
exit 0   # avoid $LASTEXITCODE leak from internal `command -v` probes
```

### Verb categories (10 total)

| Category | Verbs |
|---|---|
| Lifecycle | `setup`, `status`, `nuke`, `update {check\|apply\|status}`, `diagnostics` |
| Declarative | `reconcile`, `prune {sessions\|worktrees\|mounts\|artifacts\|all}`, `temp {size\|clean -Scope tmp\|cache\|claude\|all}`, `profile {validate\|export\|edit\|show}` |
| Repo work | `project {add\|list\|remove\|move\|show}` (+ bare dashboard), `session {new\|list\|remove}` (+ bare dashboard) |
| Distro plumbing | `mount {add\|list\|remove\|sync}` (+ bare dashboard) |
| Toolchain | `tools {list\|install\|enable\|disable\|sync\|attach}` (+ bare dashboard) |
| Identity | `login {claude\|gh\|glab\|acli-jira\|acli-confluence}` (+ bare menu) |
| Network | `vpn {enable\|disable\|reload\|status\|test}` (+ bare menu) |
| Host bridge | `host-tools {add\|list\|remove\|sync\|scan}` (+ bare dashboard), `hooks test` |
| Editor config | `claude-settings {show\|apply\|reconfigure}` |
| Bare name | central dashboard with shortcuts to everything above |

Every verb that operates on multiple items has a **bare-name interactive
dashboard** (per the design preference for interactive dashboards). Subverbs are scriptable
fallbacks for muscle-memory users / CI invocations.

## How a typical operation flows

Example: `claudearium.ps1 mount add C:\Users\you\.ssh -Guest /home/claude/.ssh -Mode ro -MountOptions umask=077`.

1. **Entry point** parses positional + flag args. `Verb='mount'`, `SubVerb='add'`,
   `Arg='C:\Users\you\.ssh'`, plus `-Guest`, `-Mode`, `-MountOptions`.
2. Imports load all modules; module-level scripts wire up cross-module deps.
3. Verb dispatch hits `Invoke-Mount` → `Invoke-MountAdd`.
4. The handler reads the profile, resolves smart defaults for unset fields,
   prompts (skipped here because flags cover everything), calls
   `Add-MountToProfile` (mutates `claudearium.profile.json` raw — `%ENV%` tokens
   preserved), then calls `Set-HostMountsInDistro`.
5. `Set-HostMountsInDistro` (in `Mounts.psm1`):
   - reads current managed block from `/etc/fstab` via awk
   - computes umount set (entries in actual but not desired)
   - builds the new managed block as text, base64-encodes it
   - runs a single-line bash command via `Invoke-InDistro -User root`:
     `umount removed`, rewrite fstab atomically (`awk` + `install -m`), `mkdir`
     new mount points, `systemctl daemon-reload`, `mount -a`.
6. `Add-Recent -State $state -Key 'hostMountPaths' -Value $host` updates the
   recents list, then `Write-State` persists.

Every step is idempotent. Running the same `mount add` twice is a no-op.

## Cross-cutting infra

### Pwsh ↔ WSL communication

Every distro-side operation goes through one of three primitives in
`Wsl.psm1`:

| Primitive | When to use |
|---|---|
| `Invoke-InDistro -Command <single-line>` | Short bash commands without shell variables (e.g. `command -v X`, `nft list table`, `apt install foo`). Argv-safe. |
| `Invoke-InDistroScript -Script <multi-line>` | Anything with `$VAR` references, command substitution as assignments, multi-line constructs. Base64-transports the script body intact. |
| `& wsl.exe -d <distro> -- ...` (direct) | Interactive stdio passthrough only (the `login` verbs, `open-claudearium.ps1`'s wt launch). Everything else should use one of the above. |

Both `Invoke-InDistro` and `Invoke-InDistroScript` filter the cosmetic
`wsl: Failed to start the systemd user session ...` warning out of both
captured and streamed output.

### State persistence

`State.psm1`:
- `Read-State` / `Write-State`: atomic file replace (write to `.tmp`, then
  `Move-Item -Force`).
- `Add-Recent -Key <name>`: deduplicated most-recent-wins list, trimmed to
  `-Max` (default 5).
- `Initialize-State`: fresh state shape with `schemaVersion`, `createdAt`,
  `provisioned: $false`.

State is per-distro: `%LOCALAPPDATA%\claudearium\<distro>\state.json`. Two
sandboxes (different `-Name`) get fully isolated state.

### Profile mutation

Every module that needs to change the profile uses the same pattern:

```powershell
$spec = Read-Profile -Path $path -Raw     # raw = preserve %ENV% tokens
# mutate $spec
Write-Profile -Path $path -Spec $spec
```

The `-Raw` flag bypasses `Resolve-EnvTokens` so we don't accidentally write
expanded paths back to disk. Use `Read-Profile` without `-Raw` for consumption
(reconcile, apply, show).

### Self-update

`SelfUpdate.psm1` is the entry-point for the `update` verb and the dashboard's weekly auto-check. Local version is read from a `VERSION` file at the install root (written by CI into the release zip; gitignored, so dev checkouts naturally report `dev`). Remote version comes from `https://api.github.com/repos/MaceWindu/Claudearium/releases/latest`. Auto-check throttle state is **global** (not per-distro): `%LOCALAPPDATA%\claudearium\update-check.json` with `lastCheckedAt` + `latestSeenVersion`.

Apply mode (`update apply`) is manifest-driven: each release ships a `manifest.txt` listing every shipped file. On update we read the install's OLD manifest, the extracted NEW manifest, delete the set difference (managed files dropped between versions), and copy the new tree over — files the user added to the install dir aren't in either manifest and survive. The previous install is zipped to `%TEMP%` first as a backup. Inside a git checkout, every subverb refuses with a pointer at `git pull` instead.

The release zip ships the diagnostic test lane (`tests/diagnostic/`) plus runner deps so end users can run `claudearium diagnostics` (also reachable from the dashboard's `d` shortcut) without cloning. Pure/distro/manual lanes are dev-only.

### Output filtering

`Invoke-InDistro` filters one line pattern out of every output stream:

```
wsl: Failed to start the systemd user session for '...'. See journalctl for more details.
```

This is a harmless cosmetic side-effect of WSL2 + systemd not auto-starting
systemd-logind / dbus. Filtering at the boundary keeps every higher-level verb
output clean. See [wsl2-gotchas.md#3-systemd-logind--dbus-dont-start-without-manual-intervention](./wsl2-gotchas.md#3-systemd-logind--dbus-dont-start-without-manual-intervention).

## What runs inside the distro at boot

Two systemd units the tool installs, in dependency order:

1. **`claudearium-killswitch.service`** (oneshot, `Before=nftables.service
   wg-quick@wg0.service`)
   - Runs `/usr/local/bin/claudearium-killswitch-prep`
   - Detects current `eth0` subnet + WG peer endpoint
   - Writes `/etc/nftables.conf.d/00-host.nft` with `define HOST_SUBNET`,
     `WG_PEER_IP`, `WG_PEER_PORT`
   - Updates `/etc/hosts` `host.internal` entry to the WSL2 NAT gateway
2. **`claudearium-wsl-interop.service`** (oneshot)
   - Registers `WSLInterop` binfmt if missing — fixes "Exec format error" when
     a host-tool wrapper tries to exec a Windows `.exe` (WSL2 + systemd doesn't
     register the binfmt automatically — known WSL bug).

Then `nftables.service` (loads `/etc/nftables.conf` with includes) and
`wg-quick@wg0.service` (brings up the tunnel) run if enabled.

`/etc/fstab` has a managed block (between `# === claudearium-managed-start ===` and
`# === claudearium-managed-end ===`) holding the user's selective `drvfs` mounts;
systemd-fstab-generator parses it at boot.
