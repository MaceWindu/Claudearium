# Sessions

A **session** is a named, tmux-backed Claude Code instance running inside the
distro, rooted at a project's persistent **`main/` checkout** (the curation
branch). You can run **N parallel sessions** across different projects (and
several on the same project), all inside one shared distro.

## The model

```
one WSL2 distro (claudearium)
  └── /home/cp-<project>/                      # one Linux user per project (0700 home)
        ├── mirrors/
        │   └── acme.git/                       # one bare mirror per project, shared by all worktrees
        └── projects/
            └── acme/
                ├── main/                        # persistent worktree on the CURATION branch — every session opens here
                └── worktrees/
                    ├── feat-1234/               # worktree Claude created for a work branch
                    └── feat-5678/               # another work worktree
```

- **`main/`** is the project's persistent checkout of the **curation branch** —
  the branch that holds the latest Claude instructions. It is created once at
  `project add` (and on the first session if missing). Every session opens into
  it; it is a shared launch pad, **not** owned by any single session.
- **Sessions don't own worktrees.** A session is a tmux session
  (`cl-<project>-<name>`) whose shell starts in `main/`. The curation branch is
  writable: a session may read and **improve the Claude instructions and push
  them from `main/`**.
- **Work happens in worktrees Claude creates.** For any feature/bug branch,
  Claude runs `git worktree add ../worktrees/<branch> -b <branch>` and works
  there. These worktrees are **discovered live** (`git worktree list`), not
  tracked in `state.json`, and surface in the dashboard + `prune worktrees`.

Because every session roots on the same curation branch, and git refuses to
check out one branch in two worktrees, parallel sessions of a project **share
the single `main/`**. That's fine when only one session curates at a time
(others immediately move into their own work worktrees); the dashboard's dirty
view makes shared `main/` state visible rather than silent.

The bare mirror is shared, so `git fetch` is deduplicated and you only pay disk
for working trees, not another full clone.

## Persistence & reattach (tmux)

Sessions run `claude` inside tmux via `tmux new-session -A -s <name> claude`
(attach-or-create):

- **Closing the wt window detaches** — the per-user tmux server keeps the
  session alive. **Reopening reattaches** to the same running `claude` (no
  duplicate, conversation intact).
- Persistence is **across window-close, not across distro shutdown.**
  `wsl --shutdown` / a host reboot kills the per-user tmux server; those
  sessions then show as **`dead`** in the dashboard (never silently lost) and
  `prune` drops the stale records.

The dashboard classifies every session by tmux liveness:

| Status | Meaning |
|---|---|
| `attached` | a client (wt tab) is currently attached |
| `detached` | running, no client — reattach by opening it |
| `dead` | tracked record, but no live tmux session (server died) |
| `untracked` | a `cl-*` tmux session with no state record (drift) |

Nothing is hidden: dead records and untracked sessions are surfaced and cleaned
via `prune` (or the dashboard's kill action).

## How you'll use it

```powershell
# One-time per project (clones the mirror + creates main/ on the curation branch)
.\claudearium.ps1 project add -Name acme -Remote git@gitlab.example.com:acme/acme.git -DefaultBranch master

# Create sessions (no branch is chosen — they open into main/)
.\claudearium.ps1 session new -Project acme -Name s1
.\claudearium.ps1 session new -Project acme -Name s2

# Open / reattach in a wt tab
.\open-claudearium.ps1 -Project acme -Session s1
.\open-claudearium.ps1 -Last
```

Inside a session, the account-level `CLAUDE.md` (shared store) carries the
worktree discipline: stay on the curation branch in `main/`, commit instruction
updates there, and `git worktree add ../worktrees/<branch>` for any other work.

## `open-claudearium.ps1` — interactive launcher

**Bare-name dashboard** lists every session with its project / name / **status**
/ last-opened, plus any untracked tmux sessions:

```
=== Claudearium: open ===
  #   Project          Session                Status     Last opened
  --- -------          -------                ------     -----------
  1   acme             s1                     attached   2h ago
  2   acme             s2                     detached   yesterday
  3   Claudelk         mainline               dead       3d ago

  pick a #  open / reattach in wt tab
  l         open last-used session
  +         new session
  n         new project
  w         show worktrees per project
  d <#>     remove session (kills its tmux session)
  q         quit
```

`w` shows each project's worktrees (`main` plus Claude-created work worktrees)
with branch / dirty / kind. Direct-open and `-Last` work as before.

## What's shared, what's isolated

| Resource | Shared | Isolated |
|---|---|---|
| The Debian distro + tool installs | yes | — |
| Bare-mirror git data | yes (one fetch serves all) | — |
| `main/` checkout (curation branch) | yes (per project) | — |
| Work worktree (a Claude-created branch) | — | per worktree |
| Claude Code conversation/state | — | per tmux session (`.claude/`) |
| tmux server | per Linux user | — |

## Concurrency caveats

- **Shared `main/`.** Two sessions editing instructions in `main/` at once will
  collide on the same working tree — curate from one session at a time.
- **One shared WireGuard tunnel** carries all session traffic.
- **CPU/RAM share the WSL2 VM** — size it via `%USERPROFILE%\.wslconfig`.
- **Don't run two work worktrees on the same branch** — git refuses; use a
  distinct branch per worktree.

## Windows Terminal integration

`open-claudearium.ps1` prefers Windows Terminal: new tab in the current window
by default, `-NewWindow` for a fresh window, `-NoTerminal` to drop into the
current console. Per-project tab color / icon / background and the
`-Title` override all still apply. The fallback (no `wt.exe`) runs the same
tmux launch line in the current console; `Ctrl-b d` detaches.

> **Host-checkout projects** follow the same launch-pad model: a host `session new`
> (no `-Branch`) mounts your Windows `hostCheckout` at `<home>/host/main` and opens
> there (the curation checkout), tmux-wrapped. A work branch is explicit —
> `session new -Project x -Name y -Branch z` creates the sibling worktree
> (`<hostCheckout>-sessions\<branch>`) and mounts it in. See
> [design-decisions.md §29](./design-decisions.md).
