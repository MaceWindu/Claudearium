# Usage — verb reference

Every verb that operates on multiple items has a bare-name interactive
dashboard. Subverbs are scriptable fallbacks for muscle-memory users or CI.

For end-to-end recipes see [cookbook.md](./cookbook.md). For symptoms and
fixes see [troubleshooting.md](./troubleshooting.md).

## `setup`

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

## `status`

Reports distro state (`Running` / `Stopped` / `Missing`), the state-file location, and the recorded provisioning info.

```
.\claudearium.ps1 status [-Name <distro>]
```

## `nuke`

Unregisters the distro and removes its state directory. Asks for confirmation unless `-Force`.

```
.\claudearium.ps1 nuke [-Name <distro>] [-Force] [-NonInteractive]
```

`nuke` deletes the WSL distro, its install directory, and the per-distro `state.json` (which holds `state.sessions` and `state.recents` — the latter is the recent-values rolodex for branches, config paths, profile paths, etc.). Your **user-owned profile** (`%LOCALAPPDATA%\claudearium\claudearium.profile.json`) — including every `projects[]` entry with its `tabColor` — is left untouched. Re-running `setup` rebuilds the distro and reseeds projects from the profile; `state.recents.branches` starts empty.

## `reconcile`

Reads the profile, diffs it against the recorded state, prints the diff, and prompts to apply. Each diffed block (distro, projects, mounts, tools, host-tools, claudeFile) has its own apply path; destructive `distro` changes (rename, install-path move) route through `nuke -Force` + `setup`. The `vpn` block isn't reconciled — apply VPN config changes explicitly via `vpn enable` / `vpn reload`.

```
.\claudearium.ps1 reconcile [-ProfilePath <path>] [-NonInteractive] [-Force]
```

## `project <subverb?>`

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

## `session <subverb?>`

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

See [sessions.md](./sessions.md) for the parallel-sessions deep dive (model, isolation table, launcher, `wt` integration).

## `mount <subverb?>`

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

### How mounts work

The sandbox's `/etc/wsl.conf` has `[automount] enabled=false` — no `/mnt/c/` tree at all. Instead, the sandbox owns a managed block inside `/etc/fstab`:

```
# === claudearium-managed-start ===
C:/src/acme /host/acme drvfs ro,metadata,uid=1000,gid=1000,umask=022 0 0
# === claudearium-managed-end ===
```

`mount add`/`remove`/`sync` rewrite this block atomically and run `mount -a`. `systemd-fstab-generator` picks it up at boot, so mounts survive distro restarts. Anything outside the managed block (your other fstab entries, if any) is left alone.

drvfs options the sandbox sets by default: `metadata,uid=1000,gid=1000,umask=022`. The `metadata` flag stores Linux-style permission bits in NTFS streams so file modes are preserved; uid/gid pin the mount to the `claude` user. Custom `-MountOptions` are appended.

## `claude-settings <subverb?>` — synthesize ~/.claude/settings.json

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

## `claudeFile` profile block — seed account-level CLAUDE.md

The per-user `CLAUDE.md` inside the distro at `/home/claude/.claude/CLAUDE.md` is the place Claude Code reads global preferences from on every session. `setup` offers an interactive prompt when the profile doesn't yet pin a mode:

1. **host-copy** — copy `$env:USERPROFILE\.claude\CLAUDE.md` from the host. Offered only when `claude` is on the host PATH **and** that file exists. Reconcile re-reads the host file on every run, so edits on the host propagate into the distro the next time you reconcile.
2. **caveman-lite** — write a literal `be brief.` one-liner. Same content forever; no source file to track.
3. **custom-path** — copy from a user-supplied Windows path. Reconcile re-reads it like host-copy.
4. **skip** — leave the distro file unmanaged; no profile entry written.

The choice is persisted to `profile.claudeFile`, so reconcile picks up drift after host-side edits.

**Profile shape:**

```jsonc
"claudeFile": { "mode": "caveman-lite" }
// or
"claudeFile": { "mode": "host-copy" }
// or
"claudeFile": { "mode": "custom-path", "path": "C:\\Users\\you\\my-claude.md" }
```

**Reconcile.** Unlike `claudeSettings`, `claudeFile` *is* part of `reconcile`'s diff — the file is a plain string, so drift is a simple compare. Absent block + file present in the distro is treated as "unmanaged" (reconcile will not delete a file you placed manually).

## `host-tools <subverb?>` — wrap Windows .exe utilities (Claudelk + friends)

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
| `host-tools` (bare) | Interactive dashboard with row actions. The table includes a **Version** column populated by a tiered probe: for drop-in catalog attaches (`gh`/`glab`/`acli`/`seqcli`/`node`/`claudeCode`/`dotnet`/`pwsh`) the canonical catalog `--version` probe runs through the wrapper; for arbitrary user-supplied wrappers the dashboard tries `<wrapper> --version` (5s timeout), then falls back to the Windows `.exe`'s `ProductVersion`. Rows with no resolvable version render blank. |
| `host-tools add [<exe>]` | Register a new wrapper. `-HostExe` / `-GuestCommand` / `-SmokeTest` flags; otherwise prompts. |
| `host-tools list` | Profile + actual-wrapper table (same Version column as the dashboard). |
| `host-tools remove <cmd>` | Drop wrapper + profile entry. |
| `host-tools sync` | Re-apply profile to the distro idempotently. |
| `host-tools scan` | Detect OAuth-pain catalog tools (`gh`, `glab`, `acli`, `seqcli`) on the Windows host PATH and offer to attach each as a drop-in wrapper. |
| `hooks test` | Run the registered `smokeTest` for each host-tool with one. |

**WSL interop binfmt** is auto-registered when you install your first host-tool, via a one-shot systemd unit (`claudearium-wsl-interop.service`). WSL2 + systemd doesn't register the `.exe` binfmt automatically, which is a known WSL bug — without our unit, running a Windows `.exe` from inside fails with "Exec format error".

### Drop-in attach for catalog tools

`gh`, `glab`, `acli`, and `seqcli` need OAuth or token-paste flows that are awkward inside WSL. If you already have them authenticated on Windows, the `tools` dashboard offers an `a <n>` action (and a scriptable `tools attach <name>`) that writes a `hostTools[]` entry with `guestCommand = <toolname>` — so you get plain `gh`, not `sb-gh`. `Test-Profile` refuses the same name appearing in both `tools.<name>.enabled=true` and `hostTools[].guestCommand` to avoid silent PATH shadowing.

**Per-tool notes for Claude.** When you attach a drop-in catalog tool, claudearium also writes a per-tool markdown note at `~/.claude/host-tools/<tool>.md` (gh, glab, acli, seqcli — sourced from `templates/host-tool-notes/`), and appends a small managed block to `~/.claude/CLAUDE.md` that always tells Claude about the `wslpath -w` / stdin caveat and points at the per-tool file for deep recipes. The block is bracketed by `<!-- claudearium-host-tools-begin -->` / `<!-- claudearium-host-tools-end -->` so re-applies replace in place, and detaching the tool strips both the per-tool file and the block entry. CLAUDE.md must already exist (set via `claudeFile` mode) — claudearium will not create it out of nowhere.

**Path-argument caveat.** The wrapper execs the `.exe` as-is — Windows sees raw argv strings and cannot auto-translate WSL paths. Use one of:

- **stdin where supported**: `cat body.md | gh pr create -F -` (the shell redirection happens on the WSL side, the `.exe` reads stdin).
- **`wslpath -w`** for explicit path args: `gh pr create -F "$(wslpath -w body.md)"`. Works for both `/home/...` (translates to a `\\wsl.localhost\<distro>\...` UNC path) and `/mnt/c/...` (translates back to `C:\...`).
- **Stage write-heavy work under `/mnt/c/...`** so paths round-trip trivially (e.g. `gh repo clone foo /mnt/c/work/foo`, then translate).

The current working directory is handled by WSL interop automatically — `gh pr view` from a WSL `cd` into a repo finds the repo without any translation step.

See [cookbook.md](./cookbook.md) for the Claudelk wiring recipe and the host-attach recipe.

## `vpn <subverb?>` — WireGuard + nftables killswitch

The `vpn` verb routes the sandbox's traffic through a user-supplied WireGuard tunnel, with an nftables killswitch that drops every off-host packet that didn't go through `wg0`. The killswitch **explicitly punches a hole for the WSL2 NAT subnet** so host-side services (Seq on the user's Windows host, IIS, etc.) remain reachable via the auto-managed `host.internal` hostname.

**Profile shape:**

```jsonc
"vpn": {
  "wgConfigPath": "C:\\Users\\you\\wireguard\\wg0.conf",
  "killswitch":   true,
  "routingMode":  "from-config",   // or "all-except-lan"
  "lanCidr":      "192.168.1.0/24" // only used by all-except-lan
}
```

`wgConfigPath` points to your WireGuard config on the Windows host. The sandbox copies it in at `vpn enable` time.

**Routing modes:**

| `routingMode` | What the installed `AllowedIPs` ends up as |
|---|---|
| `from-config` *(default)* | Your config, with `0.0.0.0/0` rewritten to `0.0.0.0/1, 128.0.0.0/1` — equivalent address space in [split-routing form](https://www.procustodibus.com/blog/2022/02/wireguard-allowedips-split/) so wg-quick installs plain main-table routes (not the fwmark/policy-routing trick that would otherwise swallow the eth0 → host-subnet route). Specific routes you supplied pass through unchanged. |
| `all-except-lan` | `AllowedIPs` is **replaced** with the inverted IPv4 CIDR list covering `0.0.0.0/0` minus `lanCidr`. Traffic to the LAN (printers, NAS, router, host services on your physical network) flows through eth0 → WSL NAT → Windows host; everything else tunnels. IPv4-only — IPv6 routes in your config are dropped in this mode, so stay on `from-config` if you need IPv6. |

If `routingMode` is unset in the profile, the first interactive `vpn enable` prompts and saves the choice. `vpn enable` also auto-detects the host's primary IPv4 subnet for `lanCidr` (lowest-metric IPv4 default route → assigned subnet on that interface). The detected value is shown for confirmation; manual entry is offered if detection fails or you're multi-homed / behind a host-side VPN that confuses the default route.

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

## `tools <subverb?>`

The sandbox bundles a small registry of CLI tools that Claude Code workflows lean on. Catalog: `node` (via nvm), `claudeCode`, `gh`, `glab`, `acli`, `dotnet` (per-user, via `dotnet-install.sh`), `seqcli` (.NET global tool — depends on `dotnet`), `pwsh` (Microsoft Debian apt repo).

> **Disk note.** `dotnet` adds ~500 MB to the distro; install it only if you actually run .NET builds in the sandbox. `seqcli` depends on `dotnet` and is auto-installed when you `tools install seqcli`. `pwsh` adds ~150 MB.

**`tools`** (no subverb) — interactive dashboard. Row-actions: `i <n>` install (or upgrade) one tool, `e <n>` enable in profile, `x <n>` disable, `s` sync (install everything enabled-but-missing), `u` update all (re-runs each tool's install handler at the profile-pinned version — for `latest` pins the handler fetches whatever upstream considers current, so this is the bulk-upgrade path; fixed pins reinstall in place), `r` force-refresh the latest-version cache, `q` quit. The dashboard adds a **Latest** column populated from a background cache of upstream registry probes; rows where the installed version differs from the cached latest are highlighted in yellow. The central dashboard shows a `(N updates)` chip after `t  tools` when any rows would flag, and prefixes the wt tab title with `*` so the indicator is visible from another wt window.

**`tools list`** — table of catalog tools with desired (profile) vs actual (installed) state plus the latest cached version. Yellow rows indicate `installed != latest`. Read-only.

**`tools install <name>`** — installs the named tool right now and marks it `enabled: true` in the profile. Dependencies are resolved eagerly (e.g. `tools install claudeCode` brings in `node` first if missing).

**`tools enable <name>`** / **`tools disable <name>`** — flip the profile flag without touching the distro. Disabling never uninstalls — that's deliberate (avoids surprising data loss in npm caches etc.). Re-enable + `tools sync` to bring back into use.

**`tools sync`** — applies the profile against the distro: installs everything enabled-but-missing in dependency order. Idempotent.

**`tools update`** — re-runs each installed catalog tool's install handler at the profile-pinned version. Because the default pin is `latest`, the handler typically re-resolves and fetches whatever upstream considers current — i.e. this is the bulk-upgrade path. Pinned-version entries (e.g. `node: host-nvmrc`, `dotnet: global-json`) reinstall in place without changing version. Use when the Latest column shows yellow rows.

**`tools refresh-latest`** — synchronously refreshes the latest-version cache (`%LOCALAPPDATA%\claudearium\tool-versions.json`). The dashboard normally refreshes in the background every 6 hours; this forces an immediate check.

```powershell
.\claudearium.ps1 tools install claudeCode        # also installs node (dependency)
.\claudearium.ps1 tools list
.\claudearium.ps1 tools sync                       # bulk install all enabled
.\claudearium.ps1 tools update                     # bulk upgrade for 'latest' pins; reinstall in place for fixed pins
```

### Tools-installs and the killswitch

`tools sync` and `tools install` need network reachability to package mirrors / GitHub / GitLab through whatever route the VPN allows. The `host.internal` exception keeps host-Seq style endpoints reachable separately.

## `login <subverb?>`

**`login`** (no subverb) — menu of supported auth flows, marked `ready` or `not installed`.

**`login claude`** — runs `claude` interactively (first-run kicks off OAuth via the host's default browser through WSL interop).

**`login gh`** / **`login glab`** — runs each CLI's own `auth login` flow. Stdio is passed straight through to your terminal, so device-flow URLs, token prompts, etc., all work as expected.

**`login acli-jira`** / **`login acli-confluence`** — runs `acli jira auth login` and `acli confluence auth login` respectively. The two were split because plain `acli auth login` is browser-OAuth only; the per-product variants are the CLI-token path. Bare `login acli` is rejected with a pointer to the two split subverbs.

Each login verb is **re-runnable** — designed for token rotation. The session ends when the underlying CLI exits.

## `update <subverb?>` — check for / apply a new release

**`update`** (or **`update check`**) — fetches the latest GitHub release tag, prints local vs latest, and persists the result so the dashboard banner uses fresh data. Runs every time you invoke it (no throttle). Inside a git checkout it prints a refusal pointing at `git pull`.

**`update apply`** — downloads the latest release zip, validates it, backs up the current install to `%TEMP%\claudearium-backup-vX.Y.Z-<timestamp>.zip`, removes managed files dropped in the new release, copies the new tree over, and exits. User-added files (anything not listed in the install's `manifest.txt`) are preserved. Refuses inside a git checkout.

**`update status`** — read-only: prints `Local version`, `Last seen latest`, `Last checked at` from `%LOCALAPPDATA%\claudearium\update-check.json`. No network call.

The dashboard (`claudearium.cmd` with no args) auto-runs `update check` once per week and prints `Update available: vX.Y.Z -> vA.B.C` above the menu when a newer release is out. Silent on network failure; silent in dev checkouts.

```powershell
.\claudearium.cmd update                # check + print
.\claudearium.cmd update apply          # download, swap, exit
.\claudearium.cmd update status         # cache info, no network
```

## `diagnostics` — read-only state inspection

Runs the shipped read-only diagnostic probes (under `tests/diagnostic/`) via `test-claudearium.ps1 -Diag`. Useful when something looks wrong and you want a quick health snapshot before opening an issue.

```powershell
.\claudearium.cmd diagnostics
```

Reachable from the dashboard as the `d` shortcut. If you want the deeper pure/distro lanes, clone the repo and run `.\test-claudearium.ps1 -Auto -Only pure` (or `-Auto -Only distro`) — the release zip ships only the diagnostic lane plus the runner deps.

## `profile <subverb>`

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

## Profile-driven setup

The profile is the declarative source of truth. Edit it, run `reconcile`, and the sandbox is brought in line.

**Location.** Default path is `%LOCALAPPDATA%\claudearium\claudearium.profile.json` — per-user, lives next to state. Override with `-ProfilePath`. The profile is never committed to a repo (it contains user-specific paths).

**Default workflow.** Each entry under `projects` describes **one git repository**; all day-to-day work for that project happens in **session worktrees** off the project's bare mirror — not in a shared checkout. Add a project once (`project add`), then spin up one session per task or branch (`session new`). The bare mirror is shared across sessions; the working tree, branch, and `.claude/` state are per-session. See [sessions.md](./sessions.md) for the full model and the launcher.

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

**Schema:** see `templates/claudearium.profile.schema.json` for the full JSON Schema, and `templates/claudearium.profile.example.json` for an annotated example. Top-level blocks: `distro`, `vpn`, `tools`, `projects` (with nested `hostMounts`, `hostTools`, `claudeSettings`), `claudeFile`.

`%ENV_VAR%` tokens in string values are expanded at read time. JSON `null` is allowed for fields the user wants to leave blank (no validation error).

**Reconcile semantics.** Most block changes apply in place (mounts, tools, projects, host-tools, vpn). The exception is the `distro` block — renaming the distro or moving its install path requires unregister + reimport (WSL can't do either in place), so those diffs are marked destructive and `reconcile` will offer to run `nuke -Force` and re-`setup` for you.

**Validation.** `profile validate` returns exit code 0 (OK + any warnings) or 1 (errors), so it slots into CI cleanly.

**Recents.** Every time `reconcile` or `setup-with-profile` consumes a profile, its absolute path is recorded in `state.recents.profilePaths` (most-recent first, dedup'd, trimmed to 5). Interactive pickers use this to pre-fill choices.

## Environment overrides

| Variable | Effect |
|---|---|
| `CLAUDEARIUM_WT_TITLE` | Overrides the Windows Terminal tab title used when `claudearium.cmd` / `open-claudearium.cmd` are invoked with no args (interactive dashboard). Default: `Claudearium`. Useful when running both launchers side by side or pinning a distinct title per shortcut. |
| `CLAUDEARIUM_DEBUG` | When non-empty, prints a script stack trace below the friendly error line on dashboard exceptions. |
