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

## 7a. `all-except-lan` routing as an inverted CIDR list

**Decision:** when the user opts into `vpn.routingMode = all-except-lan`, the
installed `AllowedIPs` is replaced with the IPv4 CIDR-list inversion of
`0.0.0.0/0 \ lanCidr` (e.g. `0.0.0.0/1, 128.0.0.0/2, …, 224.0.0.0/3` for a
`192.168.1.0/24` LAN). Computed in `ConvertTo-InvertedAllowedIPs` via a
standard recursive subtract algorithm.

**Why:** users want "everything via WG except my physical LAN" — printers,
NAS, router admin, any host-side service on the same subnet — and the
established `PostUp ip route add …` approach was already rejected in §7. An
inverted list keeps the implementation config-only, the AllowedIPs is never
catch-all so wg-quick never enables the fwmark/policy-routing trick (plain
main-table routes again), and the distro's eth0 default route naturally
handles the LAN slice via the WSL NAT → Windows host.

**Trade-offs:**

- IPv4-only — any IPv6 routes the user had are dropped in this mode. Users
  who need IPv6 stay on `from-config`.
- A /24 LAN produces 24 CIDRs; a /8 LAN produces 8. WireGuard handles
  these fine; the list is bounded by the LAN prefix length.
- Multi-peer configs get every `AllowedIPs` line replaced. This breaks
  legitimate site-to-site setups; multi-peer users should stay on
  `from-config`.

**Alternative considered:** add `PostUp = ip route add <LAN> via <gw> dev
eth0` to the config so wg-quick installs everything via wg0 but the LAN
gets a more-specific override. Rejected for the same reason as §7 — hooks
are wg-quick-version-sensitive and harder to reason about than a static
config-only transform.

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

## 21. Hybrid per-tool notes for host-attached CLIs

**Decision:** when a drop-in catalog host-tool is attached, claudearium
writes a per-tool markdown note at `~/.claude/host-tools/<tool>.md`
inside the distro AND appends a small managed block to
`~/.claude/CLAUDE.md` that contains the critical one-line caveat
("argv paths need `wslpath -w` or stdin") plus path references to the
per-tool files. The block is bracketed by
`<!-- claudearium-host-tools-begin -->` / `<!-- claudearium-host-tools-end -->`
markers and is rewritten by `Install-HostToolNotes` at the tail of
reconcile + after every host-tools / tools-attach mutation.

**Why hybrid (one-line caveat inline + path references) rather than
inlining the full per-tool notes or relying on pure paths:**

- Pure path references would mean Claude doesn't know there's even a
  gotcha to look up; it would only realize after a confusing failure.
- Inlining the full notes via `@import` would load ~30 lines × N tools
  into every session's context regardless of whether Claude actually
  touches the tools (Claude Code's `@import` is eager, not lazy).
- The hybrid block costs ~7 lines always — Claude reliably sees the
  critical rule — and the per-tool recipe is one `Read` away when
  Claude actually needs deeper detail (`gh release upload`'s asset
  paths, `seqcli ingest -i <file>` translation, etc.).

**Why a separate managed block + not modifying the source CLAUDE.md
file mode:** the existing `claudeFile` block owns the file contents
(host-copy mirrors the user's Windows-side ~/.claude/CLAUDE.md;
caveman-lite is literally "be brief."). Our notes apply runs *after*
`claudeFile` apply each reconcile so the block survives a re-mirror —
the source CLAUDE.md on the host isn't touched. If CLAUDE.md doesn't
exist at all (no `claudeFile` mode set), the notes apply only writes
the per-tool `.md` files and skips the CLAUDE.md write; we don't
create CLAUDE.md out of nowhere.

**Why drop-in tools only:** `sb-`-prefixed host-tools are arbitrary
user-added wrappers without a known path-arg shape; we have no template
to ship for them. The catalog filter in `Get-CatalogHostAttached`
limits the notes set to tools claudearium itself opts into
host-attach via `HostExeNames`. The pure test `has a shipped template
for every catalog tool that opts in to host-attach` keeps the templates
in lockstep with the catalog automatically.

## 22. hostProjects: host-side worktrees + per-session PATH shadowing

> **Superseded in part by §26.** The host-side-worktree + per-session
> PATH-shadowing *mechanism* described here is unchanged. What changed: a
> project is no longer *exclusively* a `distroProject` **or** a `hostProject`
> selected by a `type` field — it can have a distro half and/or a host half
> simultaneously, detected by which fields (`remote` / `hostCheckout`) are
> present. Read this section for the host mechanism; read §26 for the
> capability model that replaced the `type` field.

**Decision:** project entries carry a `type` field. `distroProject`
(default) keeps the existing bare-mirror-inside-the-distro model.
`hostProject` is a Windows-resident variant: the project owns no mirror
inside the distro; sessions are `git worktree add` paths created on the
host at `<hostCheckout>-sessions\<session>` and auto-mounted into the
distro at `/host/<project>/<session>` via the fstab managed block.
Host tools the project needs (`pwsh`, `git`, ...) are wrapped into a
per-project bin dir at `/home/claude/host-projects/<project>/bin/`,
which open-claudearium prepends to `PATH` only when launching sessions
of that hostProject.

**Why a new project type rather than reusing `hostMounts` + global
`hostTools`:** the user originally had to choose between

1. **Distro-resident worktree, mount the host checkout read-write.** Edits
   work, but tests still have to invoke host PowerShell somehow, and the
   global `hostTools` wrappers live in `/usr/local/bin` — they'd be on
   PATH for every other distroProject session too, silently shadowing the
   distro's `git` / `pwsh`. That's the conflict mode we promised to avoid.
2. **Just run Claude Code on Windows.** Loses the session model, the
   killswitch, the central dashboard, the per-project claudeSettings —
   everything claudearium gives you for free.

The new `hostProject` type lets the same distro host both kinds of
projects in parallel. Per-session PATH shadowing (option 1's failure mode
inverted) is the key invariant: distro-installed `git`/`pwsh` remain
authoritative for every shell *except* sessions belonging to a
hostProject that declared them as `hostShadows`.

**Why per-project (not global, not per-session) bin dirs:** global would
cross-talk into other projects; per-session would mean N copies of the
same wrapper for one project's N parallel sessions, plus a setup tax on
every session-create. Per-project is the natural scope — every session of
project X wants the same shadows — and the bin dir is wiped + rewritten
on `project add` / `reconcile`, so a profile edit (add/remove a shadow)
costs O(1) regardless of how many sessions of that project exist.

**Why PATH prepend lives in a per-project `init.sh` sourced by the
launcher, not in the wsl.exe argv directly:** `wsl.exe ... -- bash -lc
"export PATH=<bin>:$PATH; exec claude"` looks like the obvious form, but
gotcha #20 (variant of gotcha #1) silently mangles the literal `$PATH`
to an empty string before bash sees it. Routing the prepend through a
file bash reads from disk sidesteps the mangling entirely. Same
philosophy as `Invoke-InDistroScript`'s base64 transport.

**Why a `git worktree add` sibling to `hostCheckout` rather than under
`%LOCALAPPDATA%`:** the user asked for proximity ("will it work nice
with claude project permissions?"). Sibling worktrees show up in
Explorer next to the main checkout, are obvious to clean up by hand if
needed, and inherit the same Claude Code trust-prompt semantics as
distroProject sessions (each session worktree is a distinct directory
from Claude's POV, but profile-level `claudeSettings.permissions`
propagates uniformly).

**Why `hostTools` (the global block) is rejected at the project level
for hostProjects:** Test-Profile refuses a hostProject entry that
carries `hostTools: [...]`. The intent of `hostTools` is global
wrappers in `/usr/local/bin` — exactly the cross-talk vector we're
designing around. `hostShadows` is the project-scoped replacement.
Failing fast keeps users from accidentally building the conflict mode.

## 23. `enabled: false` for projects: preserve config, tear down infra

**Decision:** project entries carry an optional `enabled` boolean
(default `true`, mirroring `tools.<name>.enabled`). `enabled: false`
means *desired absent for reconcile* — the next `reconcile` removes the
materialized infrastructure (bare mirror or per-project bin dir + every
session of the project + any host fstab entries those sessions
contributed), but the profile entry stays put with all of its fields
(`tabColor`, `defaultBranch`, `hostShadows`, etc.) intact. Flipping the
field back to `true` (or deleting it) reverses the diff and re-creates
the materialized state on the next reconcile.

**Why not just `project remove` and `project add` again:** remove
discards the profile entry. For a hostProject the user would lose the
exact `hostShadows` list (including any explicit `{ name, windowsExe }`
pins); for a distroProject they'd lose `tabColor` and the
default-branch override. Disable lets the user temporarily reclaim the
disk those projects' mirrors and worktrees were using without
re-typing the configuration when they come back to them.

**Why disable removes sessions instead of preserving them:** the
sessions live under the mirror (`/home/claude/projects/<p>/sessions/<s>`)
or as host-side worktrees mounted into the distro. Both anchor points
go away on disable, so the sessions can't be kept around in any
meaningful sense — the `state.sessions` records would point at paths
that no longer exist. Treating disable as "remove sessions exactly like
a full remove would" keeps the mental model simple: re-enable is a
clean recreate, not a re-attach.

**Reconcile prompts before applying:** disable produces a
`Severity = destructive` change in the projects diff, so the operator
sees the per-project remove line in the rendered preview and has to
confirm (or pass `-Force` on a scripted reconcile run). Same gate as
deleting the entry outright.

## 24. `project move`: lossy by design

> **Superseded by §26.** `project move` (a lossy *convert* between the two
> exclusive types) was replaced by non-destructive `project add-distro` /
> `add-host` / `drop-distro` / `drop-host` once a project could hold both
> halves at once. The dirty-session guard and the profile-snapshot-before-
> mutation behaviour described below carry over to `drop-*`. Kept for history.

**Decision:** the `project move` verb migrates a project between
`distroProject` and `hostProject` in place. The profile entry is
rewritten — `type` toggles, `remote` ⇄ `hostCheckout` / `hostShadows`,
type-forbidden fields are dropped — but `tabColor`, `defaultBranch`,
`enabled`, `hostMounts`, `claudeSettings`, and `claudeFile` carry over.
Sessions of the project are torn down (worktrees, fstab entries, state
records) and the materialized side (bare mirror or per-project bin dir)
is recreated for the new type. The verb refuses if any session has
uncommitted work, unless `-DiscardDirty` (or `-Force`) is set.

**Why not preserve sessions across the move:** a distroProject session's
worktree lives at `/home/claude/projects/<p>/sessions/<s>` inside the
distro; its hostProject equivalent lives at `<hostCheckout>-sessions\<s>`
on the Windows filesystem. There is no useful way to translate one to
the other — different filesystem semantics, different path syntaxes,
different toolchain assumptions (a distro session expects `git` from
`/usr/bin`; a host session can expect host PowerShell on PATH). Trying
to keep sessions alive across the boundary would mean re-cloning each
one with a fresh `git worktree add` on the destination, which is exactly
what `session new` already does — but with more failure surface around
detached HEADs, branch-already-checked-out collisions, and dirty-tracking
state. Better to tear down cleanly and have the user run `session new`
per branch on the new side.

**Profile snapshot before mutation:** the verb copies
`claudearium.profile.json` to `claudearium.profile.json.bak-<stamp>`
before it touches anything. Move is multi-step (teardown → mutation →
re-provision) and any step can fail (`git clone --mirror` of a transient
URL, network glitch, file permissions); a backup means hand-recovery is
"copy the .bak file back over the live one" rather than "reconstruct the
old entry from memory."

**Smart-detect of `-Remote` on host → distro:** when the user runs
`project move acme -To distro` without `-Remote`, the verb reads the
existing `hostCheckout`'s `origin` URL via `Resolve-SmartRemote` (same
helper `project add -HostCheckout` already uses). If `origin` isn't set,
the verb errors out and asks for an explicit `-Remote` rather than
silently producing a remote-less distroProject (which would fail the
schema). distro → host has no symmetric inference — the user must pass
`-HostCheckout` because we can't synthesize a Windows checkout that
didn't exist before.

## 25. Per-project Linux users (filesystem isolation between projects)

**Decision:** each project gets its own dedicated Linux user (`cp-<slug>`, uid
allocated from 30000) with a `0700` home. Mirrors, sessions, `.claude` config,
and toolchain overrides live under that user's home, so a runaway agent in one
project session cannot read another project's files, tokens, or work. The
project→user mapping (username, uid, home, generated password) is tool-owned
*actual* state in `state.json` (`users` map + `uidAllocator`), keyed by the exact
project name; the derived name is only a proposal, disambiguated against existing
users on collision (`modules/Users.psm1`). This supersedes the single shared
`claude` user for project work; `claude` is retained as the `wsl.conf` default
("lobby") user for bare `wsl -d` entry and as the NOPASSWD-sudo admin/recovery
account that owns shared top-level mounts.

**Hard isolation via password sudo (amends §3).** §3's threat model was "isolate
the *host* from a runaway agent", for which sudo adds no defense. Inter-project
isolation is a new requirement, and there sudo *is* the boundary: a project user
with NOPASSWD sudo could `sudo cat` a sibling's home. So project users get
**password-required** sudo (membership in `sudo`, *no* `/etc/sudoers.d` drop-in —
Debian's default `%sudo` policy). The password is CSPRNG-generated and stored
host-side in `state.json`, which is **unreachable from inside the distro because
automount is off (§4)** — so the in-session agent cannot read it and cannot
escalate. All privileged provisioning is done by the orchestrator as root via
`wsl -u root`; the human retrieves the password for deliberate interactive
escalation via `user password <project>`. (`claude`, the lobby, keeps its §3
NOPASSWD sudo — it owns no project data.)

**Shared-base toolchains (amends §11).** §11 installed `node`/`dotnet` per-user
into `claude`'s home. Per-project users would each need their own copy — and,
critically, an agent running as `cp-*` wouldn't find `node`/`claude` at all. So
the base toolchains install **system-wide** (`node`→`/opt/node`,
`dotnet`→`/usr/local/share/dotnet`, `claudeCode` via the system node's `npm -g`,
`seqcli` via `dotnet tool install --tool-path`), exposed to every user through
`/etc/profile.d`. A `bash -lc` login shell (which all our distro invocations use)
sources profile.d, so the tools resolve for `claude` and every project user. The
apt-repo tools (`gh`/`glab`/`acli`/`pwsh`) were always system-wide. The per-user
*override* (a project pinning its own version into its home) is the remaining
half of the design and is a documented follow-up.

**Per-user config.** `claudeSettings`, `claudeFile` (`CLAUDE.md`), and host-tool
notes are written into **every** project user's `~/.claude` (the global
`claude-settings apply` / `claudeFile` / reconcile sites fan out across all
session-user homes; a freshly-added project user is seeded at `project add`).
Otherwise the agent — running as `cp-*` — would never see the synthesized config.

**Auth is per-project, seedable.** `login <tool> -Project <name>` authenticates
in that project user's home (`-Project claude` / no project targets the lobby).
`user seed <from> -To <to>` copies credential dirs between project users to avoid
re-authenticating from scratch; path-keyed Claude trust state and device-bound
tokens may not transfer (best-effort, verify after). A fresh cloning user trips
git's dubious-ownership guard on a local-path remote owned by someone else;
`git -c safe.directory` can't fix it (git ignores that config from the command
line), so the orchestrator writes `safe.directory=*` into each project user's
*global* gitconfig at provisioning — see [wsl2-gotchas.md](./wsl2-gotchas.md).

**Migration is a rebuild (reuses §15).** An existing distro provisioned before
isolation keeps working in the shared-user model. Reconcile detects it via the
`userModel` state marker (absent on pre-isolation state) and offers the same
destructive `nuke + setup` path §15 uses for distro-block changes, re-cloning
projects under fresh per-project users — gated on a dirty-session check. Sessions
are lost (consistent with §24's lossy `project move`).

**Alternatives considered:** (a) keep one user, rely on Linux file perms within
it — rejected: same uid means no real boundary. (b) Drop sudo entirely from
project users — rejected: the agent can't `apt install` and the human loses
in-session escalation; the password lever is strictly more capable. (c) Per-user
toolchain copies — rejected for disk + the cold-start cost on every new project;
system-base is shared and fast.

## 26. Dual-capability projects: capability by field presence, not a `type`

**Decision:** a single project entry can carry a **distro half** (`remote` → a
bare mirror inside the distro) **and/or** a **host half** (`hostCheckout` +
`hostShadows` → host-side worktrees mounted in). At least one half is required;
both is allowed. Capability is derived from which fields are present — the
`Get-ProjectHalves` accessor (`modules/Projects.psm1`) is the canonical reader —
**not** from the old `type` field, which is now accepted but ignored (with a
deprecation warning) for backward compatibility. Each *session* still carries
its own `type` (`distro` / `host`); the session layer was already type-aware, so
it needed almost no change.

**Why capability-by-presence over a `type` enum (supersedes §22's `type`
field):** the user wanted one logical project to run distro *and* host sessions
side by side (edit in the distro, run the Windows-PowerShell test suite on the
host). An exclusive `type` forced an either/or and a lossy *convert* (§24) to
switch. Keying capability off `remote` / `hostCheckout` presence makes "has both"
the natural representation, keeps the project **name** as the single identity key
(sessions, the per-project Linux user from §25, state, mounts all stay keyed on
name with zero churn), and lets one project user's `0700` home hold both a
`mirrors/<p>.git` subtree and a `host-projects/<p>/` subtree without collision.

**Why a shared Linux user across both halves:** §25 keys the per-project user on
the project name, and host worktrees already mount *into* that user's home. One
home, one user, one mount root per project is the natural fit; splitting a dual
project across two users would reintroduce the name-collision problem §25 avoids.
The user is deleted only when the **whole** project is removed — dropping a single
half leaves the user (and the surviving half's sessions) intact.

**Why `move` became `add-half` / `drop-half` (supersedes §24):** with both halves
representable at once, a *convert* is just *add the other half* followed by *drop
the original* — except neither step needs to be destructive. `add-distro` /
`add-host` are non-destructive (the existing half is untouched); `drop-distro` /
`drop-host` tear down only the named half's materialized state + its sessions
(dirty-guarded, snapshot-first, same safety rails §24 established), and refuse to
drop the last half (that's `project remove`, which also deletes the Linux user).
Reconcile follows suit: `Get-ProjectsDiff` emits **per-half** add/remove changes
(`projects.<name>.distro` / `projects.<name>.host`), so a hand-edited profile that
adds or drops one half reconciles that half alone.

**Why `hostTools` is now allowed on a dual project but still forbidden on a
host-only one (amends §22):** the §22 ban existed because a host-only project has
no distro-side sessions that could legitimately want global `/usr/local/bin`
wrappers — `hostShadows` (per-project bin dir) is the correct tool there. A
project that *also* has a distro half does have distro sessions that may use
`hostTools`, so the ban is narrowed to host-*only* projects.
