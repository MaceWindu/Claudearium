# Design decisions

Major choices, with the reasoning at the time and the alternatives considered.
Read this when a decision looks puzzling — there's usually a "but X is simpler"
that looked tempting and got ruled out for a concrete reason.

For *what* the tool does, see [architecture.md](./architecture.md). For *gotchas
that drove some of these decisions*, see [wsl2-gotchas.md](./wsl2-gotchas.md).

## 1. PowerShell on the host, not inside the distro

**Decision:** the orchestrator is `claudearium.ps1` running on Windows. The
distro is a passive target.

**Why:** The tool's job is *to manage WSL distros*, which is fundamentally a
host-side operation. `wsl --import`, `wsl --unregister`, distro filesystem path
resolution, Windows Terminal launching — none of that is reachable from inside
a distro.

**Alternative considered:** ship a tiny pwsh inside the distro and have it call
`wsl.exe` reflexively. Rejected: requires `pwsh` to be in the bootstrap (chicken
and egg with the tools registry), adds a hop, and gets confused about distro
identity (which one am I managing if I'm inside one?).

## 2. Debian 12 (not Ubuntu)

**Decision:** default base is `debian-12` (bookworm).

**Why:** maintainer preference. Nothing in the base package set is
Ubuntu-only.

**Alternative considered:** Ubuntu 24.04. It's Microsoft's reference WSL distro
and has slightly newer base packages (glibc 2.39 vs Debian 12's 2.36). For
`.NET 10` preview SDKs occasionally that matters. We avoided it because: (a) the
user prefers Debian, (b) every tool we install has working Debian apt packages
or upstream installers, (c) Debian 12 is leaner on disk.

**If you need Ubuntu:** in theory just change `Profile.psm1`'s
`KnownDistroBases` plus the rootfs URL resolver in `Wsl.psm1`. Not
tested.

## 3. Passwordless `claude` user with NOPASSWD sudo

**Decision:** the default user is `claude` with `passwd -d` (no password) and
`/etc/sudoers.d/claude` granting `NOPASSWD: ALL`.

**Why:** *don't add security ceremony where the threat model doesn't justify
it*. The sandbox's threat model is "this isolates the host from a runaway
agent". Sudo prompts add no defense against
that threat — they only friction the human operator.

**Alternative considered:** require sudo password on every elevated operation.
Rejected as making the tool unpleasant to use for no real security gain in this
context.

## 4. `[automount] enabled = false` + selective drvfs mounts

**Decision:** `wsl.conf` disables WSL's automatic `/mnt/c`, `/mnt/d` tree.
A managed block in `/etc/fstab` mounts only paths the user explicitly
declares via `mount add`.

**Why:** the sandbox is meant to isolate from the host. Default automount
exposes *everything* on every drive. Selective mounts force the user to think
about each path they want reachable — which is also how the [`~/.ssh` mount
cookbook](./cookbook.md#authentication-via-host-ssh-keys) works for private-repo cloning.

**Alternative considered:** keep automount on and just rely on Linux file
permissions to restrict access. Rejected: trivial to write a tool that bypasses
file perms via `ls`-and-`cat` over `/mnt/c`, and "what's reachable" should be
explicit.

## 5. Bare-mirror clones + per-session git worktrees

**Decision:** one project = one bare mirror at `/home/claude/mirrors/<p>.git`,
shared across N sessions. Each session is a `git worktree add` from that
mirror.

**Why:**
- Disk efficient — fetch deduplicates across sessions.
- `git fetch` once per project, not once per session.
- Sessions can be on different branches simultaneously without checkout
  conflicts.
- Removing a session removes just one working tree; the bare clone (with the
  remote's full history) persists for other sessions.

**Alternative considered:** a separate full clone per session. Rejected because
disk usage and fetch redundancy grow linearly; the per-session cost goes from
~50 MB (a worktree) to ~2 GB (a full clone) for multi-GB monorepos.

## 6. Base64 transport for multi-line bash scripts

**Decision:** `Invoke-InDistroScript` base64-encodes the script body on the
pwsh side and decodes inside the distro. Used by every tool installer, the
killswitch payload deploy, the host-tools wrapper installer, the claudeSettings
writer, and `Send-FileToDistro`.

**Why:** discovered the hard way that `pwsh → wsl.exe → bash` argv passing
pre-expands `$VAR` references to empty strings before bash sees them, and also
strips backslash escapes. The wrapper command is pure ASCII (`printf '%s'
'<b64>' | base64 -d | bash -l`), so argv-mangling has nothing to munge. Full
detail in [wsl2-gotchas.md#1-wslexe-argv-mangles-var-and-strips-backslashes](./wsl2-gotchas.md#1-wslexe-argv-mangles-var-and-strips-backslashes).

**Alternative considered:** carefully escape every `$` in the bash side. Tried
it; fragile, error-prone, and produces inscrutable bash. Base64 is one obvious
boundary.

## 7. WireGuard `AllowedIPs` split-routing transform

**Decision:** `Copy-WgConfig` rewrites `AllowedIPs = 0.0.0.0/0` to
`AllowedIPs = 0.0.0.0/1, 128.0.0.0/1` (same address space, equivalent routing)
before installing the config.

**Why:** `wg-quick` with `0.0.0.0/0` enables a fwmark + policy-routing trick
that intercepts traffic to the default route via `wg0`. The problem: it also
swallows the `eth0 → host-subnet` route, breaking `host.internal` access while
the tunnel is up. The split form installs ordinary routes in the main table
instead, so a more-specific route to the host subnet wins naturally. The
upstream community calls this the "[procustodibus split](https://www.procustodibus.com/blog/2022/02/wireguard-allowedips-split/)".

**Alternative considered:** keep `0.0.0.0/0` and add a `PostUp` hook to inject
the host-subnet route into wg-quick's policy-routing table (51820). Rejected:
hooks are wg-quick-version-sensitive and harder to reason about; the split form
is config-only.

## 8. `iifname "wg0"` not `iif wg0` in nftables

**Decision:** the killswitch ruleset uses `iifname "wg0"` (string-matched at
packet-eval time) rather than `iif wg0` (resolved to interface index at
rule-load time).

**Why:** at boot, the nftables ruleset loads *before* `wg-quick@wg0` brings up
the interface (so the killswitch is armed before any traffic flows). With `iif`,
nft errors out with `Interface does not exist`. With `iifname` the rule loads
fine and matches when packets arrive on the interface, whenever that comes to be.

**Alternative considered:** load the ruleset *after* wg0 is up. Rejected
because that creates a window — between systemd-networkd starting eth0 and
wg-quick starting — when the killswitch isn't armed yet.

## 9. Profile is a single JSON file, reconcile is the operator

**Decision:** one `claudearium.profile.json` per machine; every block (distro, vpn,
tools, projects, mounts, hostTools, claudeSettings) lives there. `reconcile`
reads the profile + queries the distro for actual state + applies the diff.

**Why:** declarative > imperative. The profile is the SoT; the user edits a
file and runs one verb. Diffing makes the apply step trivially idempotent.

**Alternative considered:** per-block config files (`vpn.conf`, `tools.json`,
etc.). Rejected: forces the user to remember 6 file locations and edit order;
makes `profile export` from current state harder to do atomically.

## 10. `claudeSettings` excluded from reconcile's diff

**Decision:** `reconcile` diffs everything *except* claudeSettings. Apply
explicitly via `claude-settings apply` or `reconfigure`.

**Why:** ConvertTo-Json output order over a `[hashtable]` is hash-bucket-
dependent and varies across pwsh runs. String comparison of two JSON
serializations of the same data sometimes says they differ. Drift detection
would have false positives.

**Alternative considered:** canonical JSON (sort keys, normalize whitespace,
hash). Doable but adds ~50 lines of code for a feature whose value is mostly
"user knows when their settings drifted". Easier to make the user opt in via
the explicit verb.

## 11. Per-user (`$HOME/.dotnet`, `$HOME/.nvm`) toolchain installs

**Decision:** `dotnet` and `node` install under `$HOME/.dotnet` and
`$HOME/.nvm` respectively, not `/usr/share/dotnet` / system-wide nvm.

**Why:**
- No sudo required for installs.
- `nvm` is per-user by upstream convention.
- Multiple sandbox versions / chained `update` invocations don't fight over the
  system location.
- `~/.profile` exports `PATH=$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH` for
  `.dotnet/tools` (where `dotnet tool install -g` lands seqcli, etc.).

**Alternative considered:** `/usr/share/dotnet` system-wide. Reject for sudo-
required installs + the seqcli installs-as-claude tension.

## 12. Filter the systemd-warning instead of fixing it

**Decision:** `Invoke-InDistro` strips the `wsl: Failed to start the systemd
user session for '<user>'. See journalctl for more details.` line out of every
output stream. We don't try to make logind / dbus come up.

**Why:** the "proper fix" is `loginctl enable-linger <user>`, which requires
`systemd-logind` running, which requires `dbus.service`, which require
`systemctl start` invocations that *intermittently hang* in WSL2 + systemd.
Filtering at the boundary is mechanically simple and provably correct.

**Alternative considered:** create a systemd unit that explicitly starts dbus +
logind early in boot. Tested it; hangs as described. The full fix isn't worth
the complexity for what's a purely cosmetic warning.

## 13. Pwsh `Invoke-InDistro` + `Invoke-InDistroScript` split

**Decision:** two primitives in `Wsl.psm1`. The first sends a
single-line command through argv (cheap). The second base64-transports a
multi-line script body intact (safe but ~20× the bytes on the wire).

**Why:** distinct use cases, distinct trade-offs:
- `command -v X`, `nft list table inet claudearium`, `apt-get install foo` — fine
  through argv.
- `set -e; ARCH=$(uname -m); case "$ARCH" in ... esac` — needs base64 or
  it'll silently break.

The cost of `-Script` is real (every script goes through base64 + a sub-`bash`
spawn), so we don't use it for one-liners.

**Alternative considered:** always use base64. Reject: extra latency per call,
and most calls are trivially argv-safe.

## 14. Default user is set in `wsl.conf` before claude exists

**Decision:** `wsl.conf` says `[user] default = claude` and is copied in
*before* the bootstrap script runs to create the user.

**Why:** WSL falls back to root if the default user doesn't exist yet. So the
order is:
1. Copy `wsl.conf` (root user, since claude doesn't exist).
2. Run bootstrap (root) — creates `claude`.
3. `wsl --terminate` to apply `wsl.conf`.
4. Subsequent `wsl -d <distro>` opens as `claude`.

**Alternative considered:** create `claude` first, then copy `wsl.conf`. Doable
but adds an extra step and doesn't change anything observable.

## 15. Reconcile applies destructive distro-block changes via `nuke + setup`

**Decision:** if profile.distro.name or .installPath differs from state, the
diff marks it `Severity = 'destructive'` and reconcile asks "this will nuke and
re-setup; continue?". On yes, it runs `Invoke-Nuke` then `Invoke-Setup`, then
*re-applies projects + mounts + tools + host-tools from the profile* since the
fresh distro has none of them.

**Why:** WSL doesn't support renaming or moving an existing distro in place.
The only path is unregister + re-import. The reconciler hides this from the
user — they just see "this is destructive, proceed?".

**Alternative considered:** error out and tell the user to nuke+setup manually.
Rejected as worse UX for the same end state.

## 16. Hostname is the Windows machine name, not templated

**Decision:** the distro's hostname (returned by `hostname`, used by `$HOSTNAME`)
is whatever WSL inherits from the Windows host — *not* `claudearium` or
similar.

**Why:** the deployed `wsl.conf` deliberately omits `[network] hostname =
...` to avoid hardcoding the distro name. With multiple distros hypothetically
(different `-Name` values), we'd want per-distro values, which requires
templating `wsl.conf` on copy-in. Worth doing eventually; never blocked
anything.

**Workaround if you need a distinct hostname today:** add `[network] hostname =
foo` to `payload/etc/wsl.conf` and `wsl --terminate` your distro to reapply.
Future setups bake the change in automatically.

## 17. `master` as default branch suggestion

**Decision:** wherever the tool suggests a default branch name (project add
wizard, fallback when smart-detection fails, example profile), it's `master`,
not `main`.

**Why:** maintainer preference; `master` is the more conservative default
and matches the maintainer's primary projects.

**Smart detection still wins:** if the user has a host-side checkout, the
wizard reads `git symbolic-ref refs/remotes/origin/HEAD` and uses that, falling
back to `master` only when detection fails.

## 18. No MCP servers; CLI invocation via Bash

**Decision:** the tool installs `gh`, `glab`, `acli`, `seqcli` as binaries on
PATH and lets Claude Code invoke them via the `Bash` tool. No `mcpServers`
config in the synthesized settings.json.

**Why:** maintainer preference for invoking CLIs over MCP — it keeps the
surface area small, troubleshooting identical to a human shell user, and the
dependency graph trivial.
