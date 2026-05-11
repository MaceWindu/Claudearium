# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`claudearium.ps1` is a PowerShell 7+ tool on Windows that provisions and manages a dedicated **Debian 12 WSL2 distro** for running Claude Code sessions, with optional WireGuard VPN + nftables killswitch and Windows-`.exe` wrappers via WSL interop. There is no compiled artifact, no test suite, no package manifest — every `.ps1` / `.psm1` is interpreted directly.

Entry points: `claudearium.ps1` (verb dispatch + central dashboard) and `open-claudearium.ps1` (session launcher). Both `Import-Module -Force` everything under `modules/`.

## Read the design docs before non-trivial changes

Authoritative; do not duplicate their content into commits or new docs.

- `docs/architecture.md` — module map, profile-vs-state model, verb dispatch flow.
- `docs/design-decisions.md` — *why* puzzling choices were made; check before "fixing" something that looks wrong.
- `docs/wsl2-gotchas.md` — concrete bugs at the pwsh ↔ WSL2 ↔ systemd boundary, with symptom + cause + fix-as-applied. Read before adding any code that crosses that boundary.
- `docs/extending.md` — patterns for adding a tool / host-tool / profile block / verb / module.

## Working with PowerShell modules

- **Only the entry-point scripts use `Import-Module -Force`.** Child modules import their dependencies *without* `-Force` — cascading `-Force` invalidates the parent's earlier imports and breaks function lookups mid-script (gotcha #10).
- **Use approved verbs only** (`Get-Verb`). `Ensure-` triggers a load-time warning; use `Initialize-` / `Set-` / `Install-` / `New-` / `Update-` for idempotent-setup functions (gotcha #15).
- **Don't shadow `[switch]` params with lowercase locals.** PowerShell variable names are case-insensitive, so `$force = '--force'` *overwrites* `[switch]$Force` with a string and breaks downstream switch-typed calls (gotcha #9).
- **Wrap profile arrays with `@(...)` on read.** `ConvertFrom-Json -AsHashtable` unwraps single-element arrays, so `$spec.projects` may be the lone item, not a 1-element array (gotcha #2).

## Talking to the distro

Three primitives in `modules/Wsl.psm1`:

| Primitive | When to use |
|---|---|
| `Invoke-InDistro -Command <single-line>` | Short argv-safe commands, no `$VAR` expansion needed. |
| `Invoke-InDistroScript -Script <multi-line>` | Anything with `$VAR`, `$(cmd)`, or multi-line constructs. Base64-transports the body to sidestep argv mangling. |
| `& wsl.exe -d ... -- ...` direct | Interactive stdio passthrough only (the `login` verbs, `open-claudearium.ps1`'s wt launch). |

`wsl.exe` argv mangles `$VAR` to empty strings and strips backslash escapes before bash sees them (gotcha #1). If your one-liner uses shell variables, switch to `Invoke-InDistroScript`. `awk -v var=val` is also flaky through the pwsh→wsl hop — use inline regex matching instead (gotcha #13).

When splicing values into a bash command, run them through `ConvertTo-BashQuoted` first.

When writing composed content into the distro, `[Text.Encoding]::UTF8.GetBytes($content -replace ...)` is parsed as a 2-arg method call; assign the `-replace` result to a variable first (gotcha #14).

## Profile vs state

`%LOCALAPPDATA%\claudearium\claudearium.profile.json` is *desired* state (user-owned). `%LOCALAPPDATA%\claudearium\<distro>\state.json` is *actual* state (tool-owned). The `reconcile` verb diffs them per-block and applies.

When mutating the profile programmatically, always use `Read-Profile -Raw` (preserves `%ENV%` tokens) and `Write-Profile`. `claudeSettings` is intentionally excluded from reconcile's diff (hashtable JSON ordering is non-deterministic — gotcha-adjacent design decision #10); apply it via `claude-settings apply` explicitly.

Adding a new profile block touches three places: `Profile.Test-Profile` validation + `KnownTopLevelKeys`, a `Get-<Block>Diff` in `Profile.psm1`, an `Invoke-<Block>Apply` in `claudearium.ps1`, and the templates under `templates/`. See `docs/extending.md`.

## Smoke-testing changes

There is no formal test harness. After editing:

1. **Parse-check** changed files:
   ```powershell
   $files = Get-ChildItem -Recurse -Include *.ps1,*.psm1
   foreach ($f in $files) {
       $errors = $null; $tokens = $null
       [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
       if ($errors) { Write-Host "FAIL: $($f.Name)"; $errors | ForEach-Object { Write-Host "  line $($_.Extent.StartLineNumber): $($_.Message)" } }
   }
   ```
2. **Reconcile no-op** after apply — running `.\claudearium.ps1 reconcile` a second time should print `(no changes — profile matches state)`.
3. **Idempotency** — running your add/apply twice should produce the same end state (no duplicate fstab entries, no double-installed packages).
4. **Cleanup path** — `remove` must leave no trace (managed-block markers in `/etc/fstab`, wrappers in `/usr/local/bin/`, etc.).

`claudearium.ps1` ends with explicit `exit 0` to suppress `$LASTEXITCODE` leakage from internal `command -v` probes (gotcha #16). Verbs that legitimately want non-zero exits call `exit 1` / `exit 64` inside their handlers.

## Common verbs

```powershell
.\claudearium.ps1                          # interactive central dashboard
.\claudearium.ps1 setup                    # create + provision the distro
.\claudearium.ps1 status
.\claudearium.ps1 reconcile                # diff profile vs state, prompt, apply
.\claudearium.ps1 profile edit             # open profile in editor (seeds if missing)
.\claudearium.ps1 nuke -Force              # unregister + delete state
```

Per-verb help and the full Cookbook / Troubleshooting tables live in `README.md`.

## Conventions to keep

- **Interactive-first UX:** every verb that operates on multiple items has a bare-name dashboard (`.\claudearium.ps1 project`, `.\claudearium.ps1 session`, etc.). Subverbs (`project add`, `session new`) are scriptable fallbacks.
- **`master`, not `main`,** as the default-branch fallback (durable user preference; smart detection from a host checkout still wins when available).
- **No MCP servers** — CLIs (`gh`, `glab`, `acli`, `seqcli`) are installed on PATH and invoked via the `Bash` tool. Don't add `mcpServers` to the synthesized `settings.json`.
- **`payload/` files are deployed via base64.** When adding a new payload, push it through `Send-FileToDistro` / `Send-RootFileToDistro` rather than constructing a here-doc on the bash side.
- **Use plain `systemctl enable`, not `enable --now`,** in install scripts — the latter hangs intermittently in WSL2 (gotcha #4). Trigger the unit's effect inline if the current session needs it.
