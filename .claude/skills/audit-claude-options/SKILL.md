---
name: audit-claude-options
description: Audit Claudearium's managed Claude Code option surface against the current official Claude Code settings docs — report New/Changed/Removed options and offer to apply each fix across the files that must move together. Use when the user says "audit claude options", "/audit-claude-options", or after a Claude Code release to check the tool hasn't fallen behind.
---

# audit-claude-options

Claudearium hardcodes a slice of **Claude Code's own option surface**: every
`settings.json` key it emits, plus the enum values it accepts (model ids, effort
levels, permission modes, hook events, auto-approve command buckets). When
Anthropic ships a new Claude Code release that surface drifts — options are
**added**, **renamed/changed**, or **removed** — and the tool silently falls
behind (a new `settings.json` key it never emits, or a removed enum value the
wizard still offers).

This skill automates the audit that catches that drift: enumerate what the tool
manages today, fetch the current option set from the official docs, diff them,
report **New / Changed / Removed**, then offer to apply each fix across the files
that must move together.

## When to use

Run it after a Claude Code release, or any time the user wants to confirm the
tool hasn't fallen behind. The skill is **read-only through Step 4** — it only
edits files after the user confirms in Step 5.

## Step 1 — Enumerate the managed surface

The **code is the source of truth** for "what we manage today" — re-derive the
inventory each run by reading these six spots. Do not trust the table below as a
value list; it tells you *where to look*, not *what's there*.

| Concern | File | What to read |
|---|---|---|
| Keys emitted into settings.json | `modules/ClaudeSettings.psm1` | `Get-AlwaysSettings` (always-set invariants: `cleanupPeriodDays`, `includeCoAuthoredBy`, `env`, `permissions.deny`) and `Get-OpinionatedSettings` (every `profile.claudeSettings` → settings.json translation: `model`, `theme`, `permissions.*`, `alwaysThinkingEnabled`, `autoUpdatesChannel`, `disableBypassPermissionsMode`, `cleanupPeriodDays`, `tui`, `defaultShell`, `hooks`, and the auto-approve command buckets) |
| Accepted enum values | `modules/Profile.psm1` | the `$Script:Known*` constants (`KnownEffortLevels`, `KnownAutoUpdateChannels`, `KnownTuiModes`, `KnownDefaultShells`, `KnownPermissionModes`) and `Test-Profile`'s `claudeSettings` validation block |
| Schema | `templates/claudearium.profile.schema.json` | the `claudeSettings` block with its per-key `enum` constraints |
| Example | `templates/claudearium.profile.example.json` | the annotated `claudeSettings` sample |
| Interactive wizard | `claudearium.ps1` | `Invoke-ClaudeSettingsReconfigure` — the model list and the effort/theme/channel/tui/shell/permission-mode choices and claudelk-event multi-select |
| Tests | `tests/pure/ClaudeSettings.Tests.ps1` | the expected synthesized settings.json structure the assertions encode |

Build a single inventory: every settings.json key emitted, every enum value
accepted, every model id offered. `Grep` for `Get-OpinionatedSettings` and the
`$Script:Known*` constants rather than eyeballing — the list moves between
releases.

## Step 2 — Fetch the current Claude Code option set

`WebFetch` the official settings reference:

```
https://docs.claude.com/en/docs/claude-code/settings
```

If that 404s or redirects, do a `WebSearch` for `Claude Code settings.json
reference` and follow the canonical `docs.claude.com` link. Extract the full
list of `settings.json` keys, their types, and any enumerated values (effort
levels, permission modes, update channels, etc.). Record the doc URL and the
date fetched — you'll cite both in the report so the audit is reproducible.

## Step 3 — Diff

Compare the Step-1 inventory against the Step-2 option set and sort findings into
three groups:

- **New** — keys or enum values present in the docs but not managed by
  Claudearium. For each, decide and state where it belongs:
  - *opinionated* — user-configurable via `claudeSettings` (most knobs),
  - *always-set* — a sandbox invariant we'd force regardless of profile, or
  - *intentionally ignored* — note why (e.g. desktop-only, or a capability
    Claudearium deliberately rejects).
- **Changed** — a key renamed, type changed, enum value added/removed, or default
  changed. Show old vs new.
- **Removed** — keys or enum values Claudearium still references that the docs no
  longer list. These are deprecation candidates; map each to its replacement if
  one exists, mirroring the existing `claudeFile` → `claudeShared.claudeMd`
  deprecation pattern in `Profile.psm1` (`Get-EffectiveClaudeShared`).

**Filter out non-findings** so they don't reappear every run:
- MCP servers — Claudearium deliberately installs CLIs on PATH instead (see
  CLAUDE.md "No MCP servers"). Never propose adding `mcpServers`.
- `includeCoAuthoredBy` is intentionally forced to `false` in `Get-AlwaysSettings`
  — a docs default of `true` is not a "Changed" finding.

## Step 4 — Report

Emit a grouped summary — **New**, **Changed**, **Removed** — where each finding
carries:
- the option name (and old→new for Changed),
- the classification (opinionated / always-set / ignored, or deprecate→replacement),
- a one-line proposed change, and
- the **exact files to edit** from the Step-1 map.

Close with the doc URL and fetch date. Stop here unless the user wants changes.

## Step 5 — Offer to apply

Ask the user which findings to apply (per-item or per-group). For each accepted
**New** or **Changed** option, walk the **entire** file set so the change lands
consistently — a half-applied option is worse than none:

1. `modules/ClaudeSettings.psm1` — emit logic in `Get-OpinionatedSettings` (or
   `Get-AlwaysSettings` for an invariant).
2. `modules/Profile.psm1` — `Test-Profile` validation, plus a new `$Script:Known*`
   constant if the option is an enum.
3. `templates/claudearium.profile.schema.json` — the key + any `enum`.
4. `templates/claudearium.profile.example.json` — an annotated sample value.
5. `claudearium.ps1` — a choice in `Invoke-ClaudeSettingsReconfigure` if the
   option is user-configurable.
6. `tests/pure/ClaudeSettings.Tests.ps1` — an assertion for the new emitted shape.

For a **Removed** option, add a deprecation warning in `Test-Profile` (and map to
the replacement) rather than hard-deleting, so existing profiles don't break.

Then hand off to the standard CLAUDE.md workflow — branch, tests first/alongside,
`.\test-claudearium.ps1 -Auto -Only pure -CI`, the documentation pass
(`docs/usage.md`, schema/example are already covered above), the `code-reviewer`
subagent, and the PR. **Do not commit autonomously.**

## Hard rules

- **Read-only through Step 4.** Never edit a file before the user confirms in
  Step 5.
- **Code is the source of truth** for the managed inventory — re-derive it each
  run from `Get-OpinionatedSettings` and the `$Script:Known*` constants; don't
  trust this file's prose table for values.
- **All-or-nothing per option.** Applying a New/Changed option means touching
  every file in the Step-5 list together (e.g. schema *and* validation *and*
  wizard) — never a partial landing.
- **Don't propose options Claudearium intentionally rejects** — MCP servers, or
  `includeCoAuthoredBy: true`.
