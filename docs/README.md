# Documentation

## User guides

For people running the tool. Start with the [main README](../README.md) for
the overview, requirements, and quick-start, then come here for depth.

| Doc | When to read |
|---|---|
| [usage.md](./usage.md) | Verb reference: every verb and subverb with flags, profile shapes, and examples. |
| [sessions.md](./sessions.md) | Running multiple parallel Claude Code sessions: the model, isolation, the launcher, Windows Terminal integration. |
| [cookbook.md](./cookbook.md) | End-to-end recipes (full setup, VPN with host services reachable, Claudelk hook wiring). |
| [troubleshooting.md](./troubleshooting.md) | Symptom-driven fixes for common issues. |
| [testing.md](./testing.md) | Running the test suite, understanding the lanes, and what to do when something fails in CI. |

## Developer docs

For people working *on* the tool, not just using it.

1. **[architecture.md](./architecture.md)** — how the pieces fit together.
   Module map, profile-vs-state model, verb dispatch flow. Start here.

2. **[design-decisions.md](./design-decisions.md)** — *why* each major choice
   was made, what alternatives were considered, and what trade-offs were
   accepted. Read this before changing something that looks "wrong" — it might
   be deliberate.

3. **[wsl2-gotchas.md](./wsl2-gotchas.md)** — concrete bugs hit during the
   build at the pwsh ↔ WSL2 ↔ systemd boundaries, each with symptom + cause +
   fix-as-applied. Read this before adding any code that crosses one of those
   boundaries. Cross-referenced from inline comments in the modules.

4. **[extending.md](./extending.md)** — how-to guides for the common cases:
   add a tool to the catalog, add a host-tool wrapper, add a profile block,
   add a verb, add a module. Idioms and patterns used throughout.

### Quick orientation

- **Entry points** are `claudearium.ps1` and `open-claudearium.ps1` at the
  repo root. They import all modules from `modules/`.
- **Modules** are organized one per capability:
  `{State,UI,Wsl,Profile,Projects,Sessions,Mounts,Tools,HostTools,Vpn,ClaudeSettings}.psm1`.
- **Payload files** under `payload/` get pushed into the distro at setup /
  reconcile time (nftables ruleset, systemd units, killswitch-prep script,
  wsl.conf).
- **Templates** under `templates/` are the JSON Schema + example profile.
- **Bootstrap** at `scripts/bootstrap-distro.sh` runs once as root inside the
  fresh distro at setup time (creates the `claude` user, installs base
  packages, enables systemd units).

### When to update which doc

| You're... | Update... |
|---|---|
| Adding a module / verb / profile block | `extending.md` if the pattern changes; `architecture.md`'s module map |
| Working around a new WSL2 / pwsh / systemd quirk | Add an entry to `wsl2-gotchas.md` with symptom + cause + fix; cross-link from the affected module header |
| Making a non-obvious design choice | Append to `design-decisions.md` with the alternatives you considered |
| Renaming a function / changing a signature | Update the module header's "Public surface" section |
| Adding a user-visible verb / changing UX | `usage.md` and `cookbook.md` |
