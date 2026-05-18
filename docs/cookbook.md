# Cookbook

End-to-end recipes for common setups. For the per-verb reference see
[usage.md](./usage.md); for symptoms and fixes see
[troubleshooting.md](./troubleshooting.md).

## End-to-end setup

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
.\claudearium.ps1 login acli-jira         # CLI-token auth for Jira
.\claudearium.ps1 login acli-confluence   # ... and Confluence (same acli install)

# 7. Open a Claude Code session.
.\open-claudearium.ps1                # interactive dashboard
```

## Authentication via host SSH keys

The easiest fix for the no-SSH-keys-in-sandbox problem is mounting your host's `~/.ssh` directly:

```powershell
.\claudearium.ps1 mount add "$env:USERPROFILE\.ssh" `
  -Guest /home/claude/.ssh `
  -Mode ro `
  -MountOptions 'umask=077'
```

SSH client refuses keys with permissions wider than 0600; `umask=077` here gives the mount group/other no access. After this, `git clone git@gitlab.example.com:...` works from inside the sandbox using your host key.

## VPN with host services still reachable

```powershell
# Edit your profile (or create one via `profile edit`):
#   "vpn": { "wgConfigPath": "C:\\Users\\you\\wireguard\\wg0.conf", "killswitch": true }

.\claudearium.ps1 vpn enable
.\claudearium.ps1 vpn status      # tunnel up, killswitch armed, host.internal reachable
```

From inside the sandbox, `curl http://host.internal:5341` still hits your host-side Seq even with the killswitch on.

Validate from inside: `curl https://api.ipify.org` should return your VPN endpoint's IP, and `curl http://host.internal:<port>` should still reach any host-side service.

## Split-tunnel: route everything through WG except your LAN

By default `vpn enable` respects the routes in your `wg0.conf`. If you want
the sandbox to tunnel all of its egress through WireGuard while still
reaching machines on your physical LAN (printers, NAS, router admin, any
service on the same `192.168.x.x` / `10.x.x.x` subnet your Windows host is
attached to), opt into `all-except-lan` routing:

```powershell
.\claudearium.ps1 vpn enable   # the first run prompts; pick "route all to WG except local network"
.\claudearium.ps1 vpn status
```

The first interactive run auto-detects your host's primary IPv4 subnet from
the lowest-metric default route and asks you to confirm. The choice
(`vpn.routingMode` and `vpn.lanCidr`) is saved back to the profile so
subsequent `vpn enable` runs are silent. (`reconcile` doesn't touch the
`vpn` block — VPN changes are applied explicitly via `vpn enable` /
`vpn reload`.)

Caveat: if a host-side VPN (Cisco AnyConnect, GlobalProtect, etc.) is
already routing your default route, the detection will pick *that*
adapter's subnet instead of your physical LAN. Decline the suggestion and
type the right CIDR manually, or set `vpn.lanCidr` in the profile up
front. To set both ahead of time:

```jsonc
"vpn": {
  "wgConfigPath": "C:\\Users\\you\\wireguard\\wg0.conf",
  "killswitch":   true,
  "routingMode":  "all-except-lan",
  "lanCidr":      "192.168.1.0/24"
}
```

This mode is IPv4-only — IPv6 routes in the source config are dropped
because the inversion would need to enumerate `::/0` slivers. Stay on
`routingMode = from-config` if you need IPv6.

## Wire Claudelk into Claude Code's hooks

```powershell
.\claudearium.ps1 host-tools add "C:\Tools\Claudelk\claudelk.exe" `
    -GuestCommand sb-claudelk -SmokeTest scan -NonInteractive

.\claudearium.ps1 hooks test       # confirms sb-claudelk responds

# Edit profile.claudeSettings.claudelk = true (or via wizard):
.\claudearium.ps1 claude-settings reconfigure
.\claudearium.ps1 claude-settings apply
```

The LED strip will now flash on `Stop` / `Notification` events from any Claude Code session inside the sandbox.

From inside the sandbox after the wrapper is installed:

```bash
sb-claudelk scan
sb-claudelk color "#ff8800"
```

## Use my Windows `gh` from inside the sandbox

Skip the in-WSL `gh auth login` browser-callback dance: attach the already-authenticated Windows `gh.exe` as a drop-in `gh` wrapper.

```powershell
# Detect what's available + offer attach for each:
.\claudearium.ps1 host-tools scan

# Or attach a single tool by name:
.\claudearium.ps1 tools attach gh
```

The wrapper lands at `/usr/local/bin/gh` (drop-in name, not `sb-gh`). `Test-Profile` refuses the profile if `tools.gh.enabled=true` is also set — pick one. Same recipe applies to `glab`, `acli`, `seqcli`.

Inside the sandbox:

```bash
gh auth status     # uses the host's auth — no re-login required
gh pr view 123
```

**Path arguments need translation** because the `.exe` runs on Windows and can't interpret WSL paths:

```bash
# stdin is the cleanest path for body files:
cat body.md | gh pr create -F -

# Or convert explicitly with wslpath -w:
gh pr create -F "$(wslpath -w body.md)"
gh release upload v1.0 "$(wslpath -w ./dist/app.zip)"

# Drvfs paths round-trip cleanly too:
gh repo clone foo "$(wslpath -w /mnt/c/work/foo)"
```

The cwd is auto-translated by WSL interop, so `gh pr view` from a `cd`-ed repo just works.

**Claude sees the gotcha automatically.** If you have `profile.claudeFile` set (caveman-lite / host-copy / custom-path), the attach also writes `~/.claude/host-tools/gh.md` with the full recipe and appends a one-line caveat block to `~/.claude/CLAUDE.md`. So Claude in WSL knows from the first session: "argv paths need `wslpath -w`; see the per-tool file for details."

## Work on a Windows-specific project (e.g. Claudearium itself) as a hostProject

Some repos can't be developed entirely from inside the distro — their tests
need PowerShell on Windows, or they invoke `wsl.exe`, or they target
.NET-on-Windows. Claudearium handles these as **hostProjects**: the
checkout lives on Windows, sessions are host-side `git worktree add` paths
mounted into the distro, and selected host tools (`pwsh`, `git`) are
exposed in the session via a per-project bin dir on `PATH`. Claude Code
edits files in the mount, but `pwsh -File .\test-foo.ps1` actually runs on
the host.

```powershell
# 1. Register Claudearium itself as a hostProject.
.\claudearium.ps1 project add Claudearium `
    -HostProject `
    -HostCheckout C:\GitHub\Claudearium `
    -HostShadows pwsh,git

# 2. Create a session. The worktree appears at C:\GitHub\Claudearium-sessions\dev
# on the host, and at /host/Claudearium/dev inside the distro.
.\claudearium.ps1 session new dev -Project Claudearium -Branch master

# 3. Launch.
.\open-claudearium.ps1 -Project Claudearium -Session dev
```

Inside the new tab:

```bash
pwd                                # /host/Claudearium/dev
which pwsh                         # /home/claude/host-projects/Claudearium/bin/pwsh
which git                          # /home/claude/host-projects/Claudearium/bin/git
echo "$PATH" | tr ':' '\n' | head  # bin dir first, then the usual /usr/local/bin, /usr/bin, ...

# Run the host-side test suite without leaving the session:
pwsh -File ./test-claudearium.ps1 -Auto -Only pure -CI
```

A parallel distroProject session opened in another wt tab still resolves
`pwsh` and `git` to the distro's `/usr/bin` copies — the bin-dir prepend
is bash-local to the host session.

Cleanup:

```powershell
.\claudearium.ps1 session remove dev -Project Claudearium
# C:\GitHub\Claudearium-sessions\dev is gone; the mount is gone.

.\claudearium.ps1 project remove Claudearium -Force
# Per-project bin dir is gone. C:\GitHub\Claudearium itself is untouched.
```

### Get a quick read on scratch sizes — and reclaim them

The central dashboard's `Scratch:` row gives a one-line summary; the verb
prints the detailed table:

```powershell
.\claudearium.ps1 temp                     # size table only, no mutation
.\claudearium.ps1 temp clean -Scope tmp -Force          # safe — tmpfs
.\claudearium.ps1 temp clean -Scope cache -Force        # safe — slow first build
.\claudearium.ps1 temp clean -Scope claude -Force       # transcripts + shell snapshots only
.\claudearium.ps1 temp clean -Scope claude -IncludeTodos -IncludePlans -Force  # also wipes in-flight work
.\claudearium.ps1 temp clean -Scope all -Force          # everything except ~/.claude/host-tools (we manage that)
```

The `claude` scope is selectively destructive: by default it wipes
`~/.claude/projects/` (transcripts) and `~/.claude/shell-snapshots/`, but
preserves `~/.claude/todos/`, `~/.claude/plans/`, and `~/.claude/host-tools/`.
`-IncludeTodos` and `-IncludePlans` opt into wiping the active-work
directories too; `host-tools/` is always preserved because the tool owns
that tree.

### Reclaim disk and resync after manual edits with `prune`

When you've been editing things outside the tool — `rm -rf` on a worktree,
hand-editing `/etc/fstab`, building a heavy `node_modules` directory inside
a session — `prune` reports the drift and offers to repair it. Start with
a dry run to see what's there:

```powershell
.\claudearium.ps1 prune -DryRun                  # everything, report only
.\claudearium.ps1 prune -Scope artifacts -DryRun # just the build-bloat scan
```

Then re-run without `-DryRun` to apply. The destructive scope is `artifacts`
(it `rm -rf`s `node_modules` / `target` / etc.); it prompts per directory
unless you pass `-Force`. The other scopes (`sessions`, `worktrees`,
`mounts`) are state / fstab edits — fast and reversible by re-running
`reconcile` or `session new`.

```powershell
.\claudearium.ps1 prune -Scope artifacts -Force  # nuke all heavy build dirs
.\claudearium.ps1 prune                          # run everything interactively
```

### Convert a project between distro-resident and host-resident

When a repo's needs change — say, you originally cloned it as a `distroProject`
but it turns out to need host PowerShell for the test suite — flip the type
without re-typing the configuration:

```powershell
# distroProject -> hostProject: provide the Windows checkout the worktrees will sit beside.
.\claudearium.ps1 project move acme -To host -HostCheckout C:\src\acme

# hostProject -> distroProject: -Remote is auto-detected from the existing
# hostCheckout's `origin` URL, but you can override it.
.\claudearium.ps1 project move acme -To distro
.\claudearium.ps1 project move acme -To distro -Remote git@gitlab.example.com:acme/acme.git
```

Move tears down every session of the project (worktrees on one side don't
translate to the other — different filesystems, different paths, different
toolchain), so commit / stash anything you care about first or pass
`-DiscardDirty`. The profile entry survives the swap: `tabColor`,
`defaultBranch`, `enabled`, `hostMounts`, `claudeSettings`, and `claudeFile`
all carry over. A timestamped `claudearium.profile.json.bak-<stamp>` is
written next to the live profile before the mutation, so a hand-rollback is
always available.

### Temporarily disable a project without losing its config

When a project is dormant — say, a release is shipped and the worktrees + bare
mirror are eating disk you'd like back — flip `enabled` to `false` in the
profile entry (or hit `t <n>` in the `project` dashboard). The next `reconcile`
tears down the mirror or per-project bin dir and removes every session of the
project, but the profile entry, with its `tabColor` / `defaultBranch` /
`hostShadows`, stays intact. Re-enable later and reconcile recreates everything.

```jsonc
"projects": [
  {
    "name": "old-thing",
    "remote": "git@example.com:org/old-thing.git",
    "tabColor": "#888888",
    "enabled": false        // <- next reconcile wipes the mirror; entry stays
  }
]
```

Disable is destructive in the same way `project remove` is: uncommitted work
in any session worktree is lost. If you need to keep it, commit/stash first or
just leave the project enabled.

A few practical notes:

- The session's working directory in the distro maps to a path on `/mnt/c`-style
  drvfs storage. Git operations are slower than against a Linux-native worktree.
  For Claudearium that's fine — the repo is small.
- The `hostShadows` PATH prepend doesn't auto-translate path arguments.
  When passing `.ps1` paths to host `pwsh`, the cwd is auto-translated by
  WSL interop (so relative paths just work), but absolute Linux paths to
  files need `wslpath -w` first. See `templates/host-tool-notes/pwsh.md`.
- Don't list a shadow in `hostShadows` AND install the same tool inside the
  distro via `tools.<name>` — the per-session bin dir wins on PATH for that
  session, so you'd silently never use the distro copy. Pick one home.

## Stay current with the latest release

```powershell
.\claudearium.cmd update              # is a newer release out?
.\claudearium.cmd update apply        # download, swap, exit
.\claudearium.cmd                     # re-run; dashboard banner is gone
```

`update apply` backs up the current install to `%TEMP%\claudearium-backup-vX.Y.Z-<timestamp>.zip` first and preserves any files you added to the install dir (they're not in the release manifest, so the diff leaves them alone). It refuses in a git checkout — use `git pull` there instead.

## Run diagnostics when something's off

```powershell
.\claudearium.cmd diagnostics
```

Runs the shipped read-only diagnostic lane (`tests/diagnostic/`). The dashboard's `d` shortcut does the same thing. For pure or distro Pester tests, clone the repo — those lanes aren't in the release zip.
