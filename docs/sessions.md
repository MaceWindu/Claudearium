# Parallel sessions

The sandbox supports **N parallel Claude Code sessions** in **different repos and/or different branches** of the same repo, all inside a single shared distro.

## The model

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

## How you'll use it

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

## What's shared, what's isolated

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

## Concurrency caveats

- **One shared WireGuard tunnel** carries all session traffic. That's intentional — you only configured one VPN — but bandwidth-heavy work in one session will affect others.
- **CPU/RAM share the WSL2 VM.** WSL2 sizes itself based on `%USERPROFILE%\.wslconfig` (`memory=...`, `processors=...`). For multiple heavy sessions, bump those before launching.
- **Disk:** each worktree adds disk usage. Sessions on the *same* project share git history (one bare mirror), so the per-session cost is just the working-tree files.
- **Don't run two sessions on the same branch.** Git allows it (`worktree add --force`) but you'll get checkout conflicts. Use distinct branches per session — that's the whole point.

## `open-claudearium.ps1` — interactive session launcher

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

## Windows Terminal (`wt.exe`) integration

`open-claudearium.ps1` prefers [Windows Terminal](https://github.com/microsoft/terminal) and tunes its launch line for it:

- **Default:** new tab in the current `wt` window — three parallel invocations stack as three tabs side-by-side.
- **`-Title <string>`:** sets the tab title at launch time. Overrides the per-session persisted title.
- **`-NewWindow`:** brand-new top-level window per invocation.
- **`-NoTerminal`:** skip `wt.exe` entirely, drop into the current console (legacy `conhost`, ISE, etc.) — useful for scripting or when you want `claude` to inherit the current terminal.
- **Fallback:** if `wt.exe` isn't on `PATH`, the script silently falls back to `wsl -d <distro> -u claude --cd <worktree> -- bash -lc claude` in the current console.

`wt.exe` also auto-discovers the sandbox distro in its dropdown profile list, so you can spawn a bare shell manually via Ctrl-Shift-T → `claudearium` without going through the script at all.

### Admin / elevated terminals

`wt.exe` cannot share a window across the UAC boundary. The combination matrix:

| Caller elevation | Existing `wt` window | Result |
|---|---|---|
| non-elevated | non-elevated | new tab in that window ✓ |
| elevated | elevated | new tab in that window ✓ |
| non-elevated | only elevated exists | new non-elevated window spawned |
| elevated | only non-elevated exists | new elevated window spawned |
| any | no existing window | new window matching caller's elevation |

The sandbox itself does **not** need admin (`wsl --import`/`--unregister` run as a normal user). Launch `open-claudearium.ps1` from a non-elevated terminal — that way all sessions stack as tabs in one non-elevated `wt` window. If you happen to be in an elevated shell, expect a separate elevated `wt` window to appear.
