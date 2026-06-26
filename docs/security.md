# Security model & threat coverage

Claudearium exists to give a coding agent a useful environment while keeping the
blast radius small. This doc states **what it isolates, what it deliberately
does not, and how well each control holds** — so you can reason about residual
risk instead of guessing. It is descriptive, not aspirational: every row below
maps to code that ships today.

The framing is borrowed from the way sandbox tools are usually evaluated
(filesystem reach, network egress, secret exposure, supply-chain), adapted to
this tool's WSL2 + WireGuard design. See [architecture.md](./architecture.md)
for *how* the pieces fit and [design-decisions.md](./design-decisions.md) for
*why*.

## Trust model

- **The agent is trusted-but-sandboxed.** Claude Code is assumed to act in good
  faith, but it can run arbitrary code, and the *repos it operates on* are not
  necessarily trustworthy (untrusted PRs, supply-chain payloads, prompt
  injection via repo content). The boundary that matters is therefore
  **distro → Windows host**: keep repo-driven execution inside the sandbox.
- **The host is the trust anchor.** The profile, VPN keys, and auth material
  live on Windows, outside every mount the agent can write. The agent cannot
  edit its own provisioning.
- **In-scope threats:** accidental or malicious file destruction outside the
  workspace; unrestricted network egress / data exfiltration; secret theft;
  supply-chain code execution escaping to the host.
- **Out of scope:** a hypervisor/WSL2 kernel escape; a compromised Windows host;
  the user deliberately punching holes (e.g. wide `hostMounts`). These are
  acknowledged, not defended.

## Isolation boundaries

| Boundary | Mechanism |
|---|---|
| Compute / kernel | Dedicated Debian 12 **WSL2** distro (lightweight Hyper-V VM, own kernel) — separate from the user's other distros and from Windows. |
| Identity | Each project runs as a **non-root project user**; `root` actions go through narrowly-scoped, per-project sudo (password encrypted at rest in `state.json`). |
| Filesystem | The agent sees the distro FS and its project clone. The Windows host FS is *not* mounted in unless the user adds an explicit `hostMount`. |
| Network | WireGuard tunnel + **nftables killswitch** (fail-closed `policy drop`): only the tunnel, the WSL2 host-LAN subnet, and the WG peer endpoint are reachable off `eth0`. |
| Projects | `distroProjects` are **bare-mirror git clones inside the distro**. Repo hooks / `direnv` / `mise` / build scripts execute *in the sandbox*, synced out only via `git push`. |

## Threat coverage matrix

Honest ratings — **full** (the design structurally prevents it), **partial**
(damage is contained to the VM but not prevented), **by-design hole** (a
deliberate, opt-in puncture of the boundary).

| Threat | Coverage | Notes |
|---|---|---|
| Stray file deletion outside the workspace | **full** | The host FS isn't mounted; the agent can only harm the distro + clone, which are reconstructible. |
| Unrestricted network egress / exfiltration | **partial → full when VPN armed** | Killswitch drops all non-allowed egress fail-closed. Without a `wg0.conf` the killswitch still blocks everything except host-LAN + peer. Allowed destinations are *not* domain-filtered (route/IP-level only). |
| Egress visibility | **partial** | Blocked egress is counted and rate-limit-logged; see [Egress audit](#egress-audit) below. Allowed traffic is not recorded. |
| Secret theft (VPN keys, host auth) | **full for host-side secrets** | They live on Windows, unreadable from the distro. In-distro credentials (Claude auth, per-project sudo) are reachable by the agent within its own user — contained, not hidden. |
| Supply-chain RCE from repo content | **full for `distroProjects`** | Hooks/`direnv`/`mise`/build steps run inside the sandbox, never on the host. |
| Supply-chain RCE reaching the host | **by-design hole for `hostProjects`** | See below. |

## The one deliberate host exposure: host-tool shadows

For `hostProjects` (projects whose checkout lives on the Windows side), a small
set of named commands — by default `git` and `pwsh` (`hostShadows`) — are thin
shims that **execute on the Windows host** against the host checkout. This is
intentional: it lets the agent use host Git (credential manager, signing,
SSH agent) and host PowerShell.

The trade-off: when the agent runs the `git` shadow and the repo ships
`.git/hooks/*`, **those hooks run on the host**. This is the single largest
host-exposure in the tool. It is mitigated by being:

- **opt-in per project** (a project is a `hostProject` only if the user gives it
  a `hostCheckout`),
- **scoped to named commands** (`hostShadows`, validated against the profile —
  repo content cannot add or rename a shadow),
- **documented** at the point of use (`templates/host-tool-notes/git.md`).

For untrusted repos, prefer `distroProjects` (clone-only, fully sandboxed) and
avoid the host `git` shadow. The agent is also told this directly via the
isolation-model block seeded into the shared `CLAUDE.md`
(`ClaudeShared.Get-IsolationModelBlock`).

The tool itself never fetches/pulls/checks-out a host checkout on the agent's
behalf, so it cannot be tricked into triggering host hooks — only the agent
explicitly invoking the shadow does. Branch refs passed to host
`git worktree add` are rejected if they start with `-` (argument-confusion
guard; argv is array-passed, so this is hardening, not an injection fix).

## Egress audit

The killswitch records what it blocks so a dropped connection can be
distinguished from a bug, and so unexpected egress attempts are visible:

- A non-terminating **counter** rule (`claudearium-egress-drop-count`) tallies
  every blocked egress packet — readable in `nft list table inet claudearium`.
- A **rate-limited log** rule (`limit 10/s burst 20`) emits a sampled
  `claudearium-egress-drop:` line to the kernel ring buffer.

Surface both from the host with **`vpn audit`** (or the `a` entry in the
interactive `vpn` menu), which reads the counter plus a `journalctl -k` tail.
Allowed traffic is not logged; this is an audit of *denials*, not a full
flow log. Adding domain-level allowlisting / full-flow logging would require a
filtering proxy and is out of scope today.

## What is explicitly not covered

- **Domain/SNI-level egress allowlisting.** Egress control is route/IP-level
  (WireGuard `AllowedIPs` + nftables), not "npm + PyPI + GitHub only".
- **Per-project network policy.** The killswitch/VPN is distro-wide.
- **A WSL2/hypervisor escape**, a compromised host, or user-authored holes
  (wide `hostMounts`, extra `hostShadows`).

These are real limits, listed so they aren't mistaken for guarantees.
