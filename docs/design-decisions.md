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

## 19. Distribution: zipped GitHub releases, CI-auto-tagged

**Decision:** end users install Claudearium by downloading a zip from GitHub
Releases, not by cloning the repo. Every push to `master` triggers
`.github/workflows/release.yml`, which mints a `vYYYY.M.N` tag and publishes a
release with the zipped tool plus auto-generated notes. The in-tool `update`
verb (and the dashboard's weekly auto-check) compares the local `VERSION`
file against the latest release tag and can apply an update in place.

**Why each sub-choice:**

- **Zip release, not `git clone`:** end users shouldn't need git or a working
  tree just to run the tool. The dev workflow (this repo) and the user
  workflow (a directory of files) diverge cleanly. Dev checkouts are detected
  by the presence of `.git` and exempted from in-tool updates — they use
  `git pull` instead.
- **`vYYYY.M.N` versioning, no semver:** the tool's surface area is the
  user-facing verbs + profile shape. We don't promise API stability the way
  semver implies, and breaking-vs-non-breaking maps poorly onto an
  orchestrator that mutates external WSL state. A monotonic date-scoped scheme
  is enough to answer "is mine older?" and skips bikeshedding about whether
  a profile schema bump is major or minor. `M` has no leading zero (matches
  how humans read months); `N` resets implicitly each month because no
  prior-month tags match the new `vYYYY.M.*` pattern.
- **Weekly auto-check cadence:** every-run checks add startup latency for
  little gain; never-check leaves users on stale versions. Once a week
  balances freshness vs. friction and stays well under GitHub's unauthenticated
  rate limit (60/hr per IP). State is persisted in
  `%LOCALAPPDATA%\claudearium\update-check.json` (global, not per-distro).
- **CI auto-tags on merge — no manual release step:** removes a step that's
  easy to forget and ensures every merged change is reachable via a tagged
  release. PR titles drive `gh release create --generate-notes`, so PR titles
  must be release-notes-friendly (enforced via [CLAUDE.md](../CLAUDE.md)).
- **Manifest-diff updates, not blast-everything:** each release ships a
  `manifest.txt` listing every managed file. On update, `OLD - NEW` gives the
  set of files to delete; the new tree is then copied over. Files the user
  adds (notes, scripts, extra config) are in neither manifest and are
  preserved. Without a manifest, we'd either leave orphaned old files behind
  or wipe legitimate user additions.
- **Test lanes shipped: `diagnostic` + `lib` + runner; `pure`/`distro`/`manual`
  excluded:** end users in trouble need read-only state inspection
  (`tests/diagnostic/`), not the developer test matrix. Shipping
  `pure`/`distro`/`manual` would require Pester on every user machine and
  pollute the install with code they shouldn't run. The dashboard exposes a
  one-key `Run diagnostics` shortcut so the user doesn't have to remember the
  runner command.

**Alternative considered for distribution:** install via `git clone` + a
README pointing at `master`. Rejected because (a) most target users are
Windows admins who don't use git as a package manager, (b) it makes update
prompting harder (we'd compare commit hashes, not versions), and (c) `git
clone` of a public repo over corp networks frequently fails where
`Invoke-WebRequest` against `github.com/.../releases/latest/download/...`
succeeds.

**Alternative considered for versioning:** semver. Rejected — see above.
Date-scoped is also self-documenting in user-facing release banners.

## 20. Drop-in naming for host-attached catalog tools (`gh`, not `sb-gh`)

**Decision:** when the user attaches a catalog OAuth-pain tool (`gh`,
`glab`, `acli`, `seqcli`) from the Windows host, the wrapper is named
exactly like the tool itself (`/usr/local/bin/gh`), not under the
`sb-<name>` namespace used for `claudelk`-style host helpers. `Test-Profile`
rejects any profile where the same name is enabled in both `tools.<name>`
and `hostTools[]` (drop-in `guestCommand`).

**Why drop-in:** the entire motivation is to avoid re-authenticating
inside WSL when the user already has a working Windows-side login.
That only pays off if existing scripts, muscle memory, and tutorials
(`gh pr create -F …`, `glab mr view`) just work. A `sb-gh` indirection
would force users to remember the prefix or set up shell aliases —
both eliminate the ergonomic win.

**Why refuse the conflict** rather than letting one shadow the other:
`/usr/local/bin` is earlier in PATH than `/usr/bin`, so a host-attached
`gh` would silently win over an apt-installed `gh`. Either outcome is
defensible, but neither is what the *other* config implies the user
wanted. Refusing forces the user to pick — cheaper than debugging
"why is my `gh` calling the wrong binary?" later.

**Known limitation: path arguments don't auto-translate.** The wrapper
is a 5-line `exec '/mnt/c/.../gh.exe' "$@"`. Windows sees raw argv
strings and cannot interpret WSL paths. The user is expected to either
use stdin (`gh pr create -F -`) or wrap with `wslpath -w`. Auto-
translation is rejected as a per-call feature: a smart wrapper would
need a per-tool path-arg allowlist that ages badly as upstream CLIs
evolve, and false positives (URL paths, refs, regex args that start
with `/`) would silently corrupt commands. The cwd is auto-translated
by WSL interop, which covers the most common case (`gh pr view` from
inside a repo).

**Why only OAuth-pain tools** (`HostExeNames` opt-in): `node`, `dotnet`,
`pwsh`, `claudeCode` have no auth pain inside WSL, and the host version
may not match what we want inside the distro (Node LTS pin, .NET
channel, etc.). Attaching them invites silent version drift between
"works on host" and "works in WSL." OAuth-pain tools are version-agnostic
in practice (the user only cares that `auth status` succeeds).
