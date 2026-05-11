# Design documentation

This folder is for people who are going to work on the tool, not just use it.
For user-facing docs see the [main README](../README.md).

## Read order

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

## Quick orientation

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

## What's NOT in the design docs

- Per-verb help text — see `claudearium.ps1 -Help` or the verb tables in
  the main README.
- User workflows / cookbook entries — see the
  [Cookbook section in the main README](../README.md#cookbook).
- Troubleshooting symptoms a user might hit — see the
  [Troubleshooting section in the main README](../README.md#troubleshooting).
  (`wsl2-gotchas.md` is for *developers* of the tool; the README's
  Troubleshooting is for *users*.)

## When to update which doc

| You're... | Update... |
|---|---|
| Adding a module / verb / profile block | `extending.md` if the pattern changes; `architecture.md`'s module map |
| Working around a new WSL2 / pwsh / systemd quirk | Add an entry to `wsl2-gotchas.md` with symptom + cause + fix; cross-link from the affected module header |
| Making a non-obvious design choice | Append to `design-decisions.md` with the alternatives you considered |
| Renaming a function / changing a signature | Update the module header's "Public surface" section |
| Adding a user-visible verb / changing UX | Main README's verb section + Cookbook |
