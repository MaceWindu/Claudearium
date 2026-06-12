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

Reads the profile, diffs it against the recorded state, prints the diff, and prompts to apply. Each diffed block (distro, projects, mounts, tools, host-tools, claudeShared) has its own apply path; destructive `distro` changes (rename, install-path move) route through `nuke -Force` + `setup`. `claudeShared` is reconciled **structurally only** (store + symlinks), not by content. The `vpn` block isn't reconciled — apply VPN config changes explicitly via `vpn enable` / `vpn reload`; `claudeSettings` isn't either (apply via `claude-settings apply`).

```
.\claudearium.ps1 reconcile [-ProfilePath <path>] [-NonInteractive] [-Force]
```

## `project <subverb?>`

A project is **dual-capability**: it can carry a **distro half** (a `remote` → a bare mirror inside the distro; sessions are distro-side worktrees) and/or a **host half** (a `hostCheckout` → the user's Windows checkout is the source of truth; sessions are host-side `git worktree add` paths mounted into the distro, with a per-project bin dir on the session's `PATH` making selected host tools (`pwsh`, `git`, …) callable as bare commands). At least one half is required; a project with **both** lets you create distro *and* host sessions side by side. Which half(es) a project has is derived from the fields present (`remote` / `hostCheckout`) — there is no `type` field (a legacy `type` key is accepted but ignored, with a deprecation warning). Use a host half for Windows-specific repos (PowerShell, .NET-on-Windows) where tests have to run on the host anyway.

**`project`** (no subverb) — interactive dashboard listing projects with a **Types** column (`distro` / `host` / `distro+host`) and row-actions (`+` add, `s <n>` show, `t <n>` toggle enabled, `a <n>` add the missing half, `x <n>` drop a half, `d <n>` remove, `q` quit). The `Enabled` column reflects the profile entry's `enabled` field (default `yes`); `t <n>` flips it and prompts you to run `reconcile` to apply.

**`project add [<name>]`** — adds a project to the profile.

```powershell
# distro half: auto-detect remote/branch from a host checkout, clone a bare mirror.
.\claudearium.ps1 project add -HostCheckout C:\src

# distro half: fully scripted.
.\claudearium.ps1 project add acme `
  -Remote git@gitlab.example.com:acme/acme.git `
  -DefaultBranch master `
  -NonInteractive

# host half: register C:\GitHub\Claudearium directly; sessions live on the host.
.\claudearium.ps1 project add Claudearium `
  -HostProject `
  -HostCheckout C:\GitHub\Claudearium `
  -HostShadows pwsh,git
```

`project add` creates a project with a single half (a distro half by default, or a host half with `-HostProject`). To make a project **dual-capability**, add the other half later with `project add-distro` / `project add-host` (below).

Smart defaults pull from `-HostCheckout`'s `origin` URL (or the current working directory if it's a git checkout). A distro half falls back to `master` for the default branch. The repo name is derived from the URL's last path segment.

`-HostShadows` accepts a list of names known to the built-in catalog (currently `pwsh`, `git`) — each resolved via `where.exe` first, then well-known install paths. To pin an exact binary, use the explicit form in the profile: `hostShadows: [{ name: "pwsh", windowsExe: "C:\\Custom\\pwsh.exe" }]`. The default when `-HostProject` is passed without `-HostShadows` is `pwsh,git`.

Interactive `project add` also prompts for the session tab's **Windows Terminal appearance** — a tab color (`tabColor`), a tab **icon**, a **background image**, and the background-image **opacity** (`0` = fully transparent … `100` = solid). All four are optional and may be edited later in the profile. See [`wt-profiles`](#wt-profiles) for how icon / background / opacity are delivered, and [Per-project Windows Terminal appearance](#per-project-windows-terminal-appearance) for the field reference.

**`project list`** — table of projects with a **Types** column and profile-vs-materialized **State** (`present` / `partial` / `missing`, folded across both halves). Useful for noticing drift (a half materialized but not in profile, or vice-versa — both nudge you toward `reconcile`).

**`project show <name>`** — detailed view of one project: each present half (distro: remote + mirror path; host: hostCheckout + bin dir) with its materialization state, plus any sessions tracked against it (each tagged `distro` / `host`).

**`project add-distro <name> -Remote <url>`** / **`project add-host <name> -HostCheckout <path> [-HostShadows <list>]`** — non-destructively add the missing half to an existing project, making it dual-capability. The existing half is untouched; the new half is wired into the profile and then materialized (clone the mirror / deploy the bin dir) under the project's existing Linux user. `add-distro` auto-detects the `origin` URL from an existing `hostCheckout` when `-Remote` is omitted. Errors if that half already exists. (The dashboard exposes these as `a <n>`.)

**`project drop-distro <name>`** / **`project drop-host <name> [-DiscardDirty] [-Force]`** — non-destructively remove one half from a dual-capability project, keeping the other half **and** the project's Linux user. Tears down only the dropped half's materialized state (mirror, or bin dir + mounts) and its sessions. Refuses to drop the last remaining half (use `project remove` for that). Refuses if a session of that half has uncommitted work unless `-DiscardDirty` / `-Force`. A timestamped profile snapshot (`claudearium.profile.json.bak-<stamp>`) is written before the mutation. (The dashboard exposes these as `x <n>`.)

**`project remove <name>`** — deletes **every** half's materialized state (bare mirror and/or per-project bin dir), every session of the project, the project's Linux user, and the profile entry. The `hostCheckout` itself is **never** deleted. Asks for confirmation unless `-Force`.

### Per-project Windows Terminal appearance

Each project entry can theme its session tabs in Windows Terminal:

| Field | Where it works | Notes |
|---|---|---|
| `tabColor` | `wt.exe --tabColor` (CLI) | `#RRGGBB`. Applied directly at launch; no profile needed. |
| `icon` | WT profile | Tab icon: a file path, emoji, `ms-appdata:///…`, or built-in glyph. |
| `backgroundImage` | WT profile | A Windows file path, URL, or the literal `desktopWallpaper`. |
| `backgroundImageOpacity` | WT profile | Percent `0` (transparent) … `100` (solid). Overrides `projectDefaults.backgroundImageOpacity`. Needs a `backgroundImage` to have any effect. |

`backgroundImageOpacity` defaults to the top-level **`projectDefaults.backgroundImageOpacity`** (itself defaulting to `100`) when a project sets a background image but no per-project opacity:

```json
{
  "projectDefaults": { "backgroundImageOpacity": 80 },
  "projects": [
    { "name": "acme", "remote": "…", "icon": "🚀",
      "backgroundImage": "C:\\Users\\me\\Pictures\\acme.png",
      "backgroundImageOpacity": 40 }
  ]
}
```

`tabColor` is set as a `wt.exe` flag at launch, but `wt.exe` has **no** CLI flag for icon / background / opacity — those exist only as Windows Terminal *profile* settings. So for any project that sets an `icon` or `backgroundImage`, claudearium generates a hidden WT profile named `Claudearium - <project>` and launches its sessions with `wt -p "<profile>"`. See [`wt-profiles`](#wt-profiles).

## `wt-profiles`

Manages the generated Windows Terminal profile fragment that carries each project's `icon` / `backgroundImage` / `backgroundImageOpacity`.

```
.\claudearium.ps1 wt-profiles            # show the generated profiles (bare)
.\claudearium.ps1 wt-profiles apply      # regenerate the fragment from the profile
.\claudearium.ps1 wt-profiles clean      # delete the fragment
```

The fragment is written to `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\Claudearium\claudearium.json` — Windows Terminal only scans its own fragment locations, so it can't live in claudearium's settings folder. It's regenerated automatically by `reconcile` and by `project add`; `wt-profiles apply` is the explicit/manual path.

> **Restart caveat:** Windows Terminal reads fragments only at startup, so a new or changed icon / background / opacity applies the next time you launch Windows Terminal. claudearium prints a "restart Windows Terminal to apply" note whenever the fragment changes.

## `temp [size | clean -Scope <area> [-IncludeTodos] [-IncludePlans] [-Force]]`

Runtime scratch / cache size + cleanup. Three scopes: `tmp` (`/tmp`, shared), `cache` (`~/.cache`), and `claude` (`~/.claude`). Under per-project user isolation `cache` and `claude` live in each project user's home, so both `size` and `clean` fan out across the lobby `claude` user **and** every provisioned `cp-*` project user (`/tmp` is shared and counted once).

- Bare `temp` (or `temp size`) prints a per-scope size table; the `cache` / `claude` rows are summed across all of those homes.
- `temp clean -Scope <tmp|cache|claude|all>` wipes the named scope. `tmp` is always safe (tmpfs, wiped on reboot). `cache` is safe but a first-build penalty applies. `claude` defaults to wiping `~/.claude/projects/` (transcripts) and `~/.claude/shell-snapshots/` — `~/.claude/todos/`, `~/.claude/plans/`, and `~/.claude/host-tools/` are **preserved**. Pass `-IncludeTodos` / `-IncludePlans` to widen the wipe. `host-tools/` is never wiped (the tool owns that tree).
- `-Force` skips the confirmation prompt; useful for scripted cleanup.

The central dashboard's status block also surfaces the sizes so you can see disk pressure at a glance.

## `prune [-Scope <area>] [-DryRun] [-Force]`

Detect drift between state, profile, and the distro filesystem; repair (or, with `-DryRun`, just report). `-Scope` narrows the run to one area — defaults to `all`:

| Scope | Detects | Repair |
|---|---|---|
| `sessions`  | state.sessions records whose worktree directory is gone | drop the orphaned records from state |
| `worktrees` | `git worktree list --porcelain` entries with `prunable` set or pointing at a missing dir | `git worktree prune` per mirror / host checkout |
| `mounts`    | `/etc/fstab` managed-block entries with no matching host session | rebuild the managed block from the merged-desired set |
| `artifacts` | heavy untracked build dirs (`node_modules`, `target`, `.next`, `dist`, `build`, `out`, `obj`, `bin`) inside live session worktrees, ≥ 5 MB each | `rm -rf` per dir, prompts unless `-Force` |
| `all`       | every scope above | every repair above |

`-DryRun` prints the diagnosis and exits without mutating anything; safe to run anytime. `-Force` skips the per-item confirmation in the `artifacts` scope. The other scopes apply en masse — there's nothing reversible there beyond what `git` and `wsl --shutdown` already give you.

**Disabling a project without removing it.** Edit the profile entry to add `"enabled": false`, or use the dashboard's `t <n>` toggle. The next `reconcile` tears down the materialized infrastructure (mirror or per-project bin dir + every session of the project), but leaves the profile entry alone so the `tabColor`, `defaultBranch`, `hostShadows`, etc. survive. Flip back to `"enabled": true` (or remove the field) and re-reconcile to recreate everything. Disable is destructive for sessions exactly like a full remove — uncommitted work in worktrees is lost.

## `session <subverb?>`

**`session`** (no subverb) — interactive dashboard of all sessions across all projects (filter with `-Project`), with a **Type** column tagging each session `distro` / `host`. Row-actions: `d <n>` remove, `q` quit.

**`session new <name>`** — creates a git worktree. Each session is itself `distro` or `host`. When the project offers **both** halves, pass `-SessionType <distro|host>` (or, interactively, answer the prompt); in non-interactive mode a dual project requires `-SessionType`. When the project has a single half, that type is used silently. The wiring depends on the session type:

- **distro session** — `git worktree add` runs inside the distro off the project's bare mirror. The worktree lives at `<home>/projects/<project>/sessions/<session>` and shares the mirror at `<home>/mirrors/<project>.git` with every other session. Subsequent `git fetch`es from any session populate the mirror once for all of them.
- **host session** — `git worktree add` runs on the Windows side against the project's `hostCheckout`. The worktree lands at `<hostCheckout>-sessions\<session>` (e.g. `C:\GitHub\Claudearium-sessions\dev`). The distro auto-mounts that Windows path under the project user's home via the fstab managed block, and `open-claudearium.ps1` opens the session with that mount as the working directory.

```powershell
# distro session: existing branch
.\claudearium.ps1 session new mainline -Project Claudelk -Branch master

# distro session: new branch off master
.\claudearium.ps1 session new feat-1234 -Project acme -Branch feature/PROJ-1234-some-feature -NewBranch -BaseBranch master

# host session on a dual project (must disambiguate with -SessionType)
.\claudearium.ps1 session new dev -Project Claudearium -Branch master -SessionType host
```

**`session list [-Project <p>]`** — table with project / session / **type** / branch / dirty state / created-at.

**`session remove <name> -Project <p>`** — removes the worktree (type resolved from the session record: prunes the bare mirror's worktree metadata for a distro session, or unmounts + removes the host worktree for a host session). Refuses if there are uncommitted files unless `-Force`.

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
   - `cleanupPeriodDays: 30` (overridable from the profile — see below)
   - `includeCoAuthoredBy: false`
   - `env.CLAUDEARIUM_NAME` / `env.CLAUDEARIUM_MODE`
   - `permissions.deny` for known-dangerous shell patterns (`rm -rf /`, `curl | sh`, etc.) — profile additions concatenate; the hardcoded patterns can never be removed.
2. **Opinionated from `profile.claudeSettings`** (asked by the wizard or set in the profile):
   - `model` — e.g. `claude-opus-4-7` (passed through verbatim)
   - `defaultEffort` — `low` / `medium` / `high` / **`xhigh`** (recommended for sandbox use); emitted as the top-level `effortLevel` setting
   - `theme` — `dark` / `light` / `system`
   - `autoApproveReadOnlyBash` — pre-approves `git status|log|diff|show|branch`, `ls`, `cat`, `head`, `tail`, `pwd`, `echo`, `which`, `whoami`, `gh:*`, `glab:*`, `acli:*`, `seqcli:*`
   - `autoApproveProjectWrites` — pre-approves `Edit`, `Write`, `Glob`, `Grep`
   - `autoApproveBuildCommands` — pre-approves `dotnet build/test/restore/run`, `npm install/run`
   - `claudelk` (bool) + `claudelkEvents` ([Stop, Notification, ...]) — wires hooks that call `sb-claudelk color '#XXXXXX'` on the selected events
   - `alwaysThinkingEnabled` (bool) — enables extended thinking by default; pairs naturally with `defaultEffort: xhigh`
   - `autoUpdatesChannel` — `stable` / `latest` for the sandbox copy of Claude Code
   - `disableBypassPermissionsMode` (bool) — forbids `--dangerously-skip-permissions`; recommended for the sandbox
   - `cleanupPeriodDays` (int, ≥ 0) — overrides the always-set 30-day default when present
   - `tui` — `fullscreen` / `default` terminal renderer
   - `defaultShell` — `bash` / `powershell` for Claude Code's Bash invocations
   - `editorMode` — `normal` / `vim` key bindings for the input prompt
   - `outputStyle` — named output style that adjusts the system prompt (e.g. `Explanatory`)
   - `permissions` (object) — free-form extensions layered on top of the auto-approve buckets:
     - `additionalAllow` (string[]) — extra allow patterns concatenated with the buckets
     - `additionalDeny` (string[]) — extra deny patterns; sandbox hardcoded denies always win
     - `additionalAsk` (string[]) — patterns Claude must ask before running (emitted as `permissions.ask`)
     - `additionalDirectories` (string[]) — extra directories Claude can read beyond the session worktree
     - `defaultMode` — `default` / `acceptEdits` / `plan` / `bypassPermissions`

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
  "model":                        "claude-opus-4-7",
  "defaultEffort":                "xhigh",
  "theme":                        "dark",
  "autoApproveReadOnlyBash":      true,
  "autoApproveProjectWrites":     true,
  "autoApproveBuildCommands":     false,
  "claudelk":                     true,
  "claudelkEvents":               ["Stop", "Notification"],
  "alwaysThinkingEnabled":        true,
  "autoUpdatesChannel":           "stable",
  "disableBypassPermissionsMode": true,
  "tui":                          "fullscreen",
  "defaultShell":                 "bash",
  "editorMode":                   "normal",
  "outputStyle":                  "default",
  // "cleanupPeriodDays": 30,           // omit to use the always-set default
  "permissions": {
    "additionalAllow":       [],
    "additionalDeny":        [],
    "additionalAsk":         [],
    "additionalDirectories": [],
    "defaultMode":           "default"
  }
}
```

## `claude-shared <subverb?>` — shared account-level instructions (CLAUDE.md + skills + agents)

The account-level Claude instructions — `CLAUDE.md`, `skills/`, `agents/`, and the host-tool notes — live in **one shared store per distro** at `/opt/claudearium/claude-shared`, symlinked into every project user's `~/.claude`. It's **group-writable by all projects**, so it's genuinely shared at runtime: a skill or `CLAUDE.md` edit an agent makes in one project is immediately visible (and editable) from every other project. `settings.json` stays per-user (see `claude-settings`). See [design-decisions #28](./design-decisions.md#28-shared-group-writable-account-level-claude-store).

| Command | Effect |
|---|---|
| `claude-shared` | Interactive dashboard (summary + import / backup / restore / apply). |
| `claude-shared show` | Summarize the store: CLAUDE.md size, skill/agent counts, group members. |
| `claude-shared import` | Seed/refresh the store from the host `~/.claude` (CLAUDE.md per `claudeMd.mode`, plus `skills/` + `agents/`). Non-destructive merge; pass `-Force` to overwrite in-distro content. |
| `claude-shared backup` | Snapshot the store to `%LOCALAPPDATA%\claudearium\backups\<distro>\claude-shared-<stamp>.tar.gz` (prunes to `backup.retain`). |
| `claude-shared restore` | Restore the newest snapshot (or `-Arg <file>`) into the store, then re-link. |
| `claude-shared apply` | Repair the store structure (group + ACLs + symlinks) without touching content. |

**Setup seeding.** When the profile doesn't yet pin a mode, `setup` prompts for how to seed the shared `CLAUDE.md` (host-copy / caveman-lite / custom-path / skip) and whether to import host `skills/` and `agents/`. If a backup exists, `setup` first offers to **restore** it instead. The choice is persisted to `profile.claudeShared`.

**Backup across `nuke`.** Before `nuke` wipes the distro, the store is snapshotted to the host backup dir (a sibling of the per-distro state dir, so it survives the wipe). `setup` later offers to restore it. Opt out of the snapshot with `nuke -NoBackup` or `claudeShared.backup.onNuke = false`.

**Profile shape (`claudeShared`):**

```jsonc
"claudeShared": {
  "claudeMd":     { "mode": "caveman-lite" },   // or host-copy / custom-path / skip
  "importSkills": true,                          // import %USERPROFILE%\.claude\skills
  "importAgents": true,                          // import %USERPROFILE%\.claude\agents
  "skillsPath":   "C:\\Users\\you\\.claude\\skills",   // optional override
  "backup":       { "onNuke": true, "retain": 5, "restorePrompt": true }
}
```

The deprecated `claudeFile` block (`{ "mode": ... }`) is still read and mapped onto `claudeShared.claudeMd` for back-compat; `claudeShared` wins when both are present.

**Reconcile.** Reconcile manages the store **structure only** (store + group + ACLs + symlinks) — it never overwrites store *content* from the host, since the store is editable in-distro and that would clobber agent edits. Pull host content explicitly with `claude-shared import`.

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

**Per-tool notes for Claude.** When you attach a drop-in catalog tool, claudearium also writes a per-tool markdown note at `~/.claude/host-tools/<tool>.md` (gh, glab, acli, seqcli — sourced from `templates/host-tool-notes/`), and appends a small managed block to `~/.claude/CLAUDE.md` that always tells Claude about the `wslpath -w` / stdin caveat and points at the per-tool file for deep recipes. The block is bracketed by `<!-- claudearium-host-tools-begin -->` / `<!-- claudearium-host-tools-end -->` so re-applies replace in place, and detaching the tool strips both the per-tool file and the block entry. The per-tool files and CLAUDE.md block are written **once** into the shared store (symlinked into every `~/.claude`), not per-user. The managed block is only injected when the store CLAUDE.md exists (set via `claudeShared.claudeMd` mode) — claudearium will not create it out of nowhere.

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

The sandbox bundles a small registry of CLI tools that Claude Code workflows lean on. Catalog: `node` (system-wide at `/opt/node`), `claudeCode`, `gh`, `glab`, `acli`, `dotnet` (system-wide at `/usr/local/share/dotnet`), `seqcli` (.NET tool — depends on `dotnet`), `pwsh` (Microsoft Debian apt repo). All install system-wide and are exposed to every project user via `/etc/profile.d`, so an agent running as a `cp-*` project user finds them on PATH.

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

**Per-project auth (`-Project <name>`).** Each project runs as its own Linux user with its own `~/.claude`, `~/.config/gh`, etc., so a login lands in exactly one project's home. Pass `-Project <name>` to authenticate as that project's user; `-Project claude` (or no `-Project` when the distro has no project users yet) targets the shared lobby. Without `-Project` on a distro that *does* have project users, the login picks one interactively (or errors under `-NonInteractive`). To avoid re-authenticating every project from scratch, log in once and copy the credentials across with `user seed` (below).

## `user <subverb?>` — per-project Linux users

Each project is isolated under its own `cp-<project>` Linux user (0700 home, password-required sudo). This verb inspects and manages those users.

**`user`** (or **`user list`**) — table of `project → Linux user / uid / home`.

**`user password <project>`** — prints that project user's generated sudo password (the host-side secret used for interactive escalation; the in-session agent never has it). Printed only on this explicit request.

**`user seed <from> -To <to> [-Tools gh,claude,glab,acli]`** — copies credential directories from one project user's home to another's so you don't re-authenticate every project. Defaults to all known tools. Best-effort: tokens bound to a device, and Claude's absolute-path-keyed trust state, may not transfer — verify with e.g. `gh auth status` afterward. Prompts before overwriting unless `-Force`.

**`user shell <project>`** — opens an interactive `bash -l` as that project's user (handy for manual debugging / running `sudo` with the password from `user password`).

```powershell
.\claudearium.cmd user                          # list project users
.\claudearium.cmd login gh -Project acme         # auth gh as acme's user
.\claudearium.cmd user seed acme -To widget -Tools gh   # reuse the gh token
.\claudearium.cmd user password acme             # show acme's sudo password
```

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

**Schema:** see `templates/claudearium.profile.schema.json` for the full JSON Schema, and `templates/claudearium.profile.example.json` for an annotated example. Top-level blocks: `distro`, `vpn`, `tools`, `projects` (with nested `hostMounts`, `hostTools`, `claudeSettings`), `claudeShared` (and the deprecated `claudeFile`, mapped onto `claudeShared.claudeMd`).

`%ENV_VAR%` tokens in string values are expanded at read time. JSON `null` is allowed for fields the user wants to leave blank (no validation error).

**Reconcile semantics.** Most block changes apply in place (mounts, tools, projects, host-tools, vpn). The exception is the `distro` block — renaming the distro or moving its install path requires unregister + reimport (WSL can't do either in place), so those diffs are marked destructive and `reconcile` will offer to run `nuke -Force` and re-`setup` for you.

**Validation.** `profile validate` returns exit code 0 (OK + any warnings) or 1 (errors), so it slots into CI cleanly.

**Recents.** Every time `reconcile` or `setup-with-profile` consumes a profile, its absolute path is recorded in `state.recents.profilePaths` (most-recent first, dedup'd, trimmed to 5). Interactive pickers use this to pre-fill choices.

## Environment overrides

| Variable | Effect |
|---|---|
| `CLAUDEARIUM_WT_TITLE` | Overrides the Windows Terminal tab title used when `claudearium.cmd` / `open-claudearium.cmd` are invoked with no args (interactive dashboard). Default: `Claudearium`. Useful when running both launchers side by side or pinning a distinct title per shortcut. |
| `CLAUDEARIUM_DEBUG` | When non-empty, prints a script stack trace below the friendly error line on dashboard exceptions. |
