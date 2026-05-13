# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`claudearium.ps1` is a PowerShell 7+ tool on Windows that provisions and manages a dedicated **Debian 12 WSL2 distro** for running Claude Code sessions, with optional WireGuard VPN + nftables killswitch and Windows-`.exe` wrappers via WSL interop. There is no compiled artifact and no package manifest — every `.ps1` / `.psm1` is interpreted directly. Tests live under `tests/` and run via `.\test-claudearium.ps1` (see [docs/testing.md](./docs/testing.md)).

Entry points: `claudearium.ps1` (verb dispatch + central dashboard) and `open-claudearium.ps1` (session launcher). Both `Import-Module -Force` everything under `modules/`.

## Read the design docs before non-trivial changes

Authoritative; do not duplicate their content into commits or new docs.

- `docs/architecture.md` — module map, profile-vs-state model, verb dispatch flow.
- `docs/design-decisions.md` — *why* puzzling choices were made; check before "fixing" something that looks wrong.
- `docs/wsl2-gotchas.md` — concrete bugs at the pwsh ↔ WSL2 ↔ systemd boundary, with symptom + cause + fix-as-applied. Read before adding any code that crosses that boundary.
- `docs/extending.md` — patterns for adding a tool / host-tool / profile block / verb / module.
- `docs/testing.md` — test runner, lanes, CI, diagnostic mode, how to add a test.

## Workflow for any non-trivial change

Apply in order. Each step is mandatory unless explicitly noted.

1. **Branch off `master`.** `git checkout master && git pull && git checkout -b <type>/<short-slug>`. Conventional prefixes: `feat/…`, `fix/…`, `docs/…`, `chore/…`. Never commit straight to `master`, even for solo work.

2. **Plan before coding** for anything ambiguous. Use plan mode (`/plan`) and write the plan to the plan file the harness gives you. Get the user's `ExitPlanMode` approval before editing production code.

3. **Tests first or alongside** — never after. For each kind of change:

   | Change | What to add / update |
   |---|---|
   | New / changed module function with pure logic | `tests/pure/<Module>.Tests.ps1` |
   | New / changed verb or subverb | `tests/distro/<Verb>.Tests.ps1` (happy path) |
   | UX behavior only a human can verify (wt color, OAuth flow, VPN egress) | `tests/manual/<Thing>.ps1` (automate setup; prompt only for the judgment call) |
   | Read-only state worth surfacing for debugging | `tests/diagnostic/<Area>.ps1` |
   | Working around a `wsl2-gotchas.md` entry | `tests/pure/Gotchas.Tests.ps1` static-analysis regression + a `wsl2-gotchas.md` entry if it's new |

   Register every new test file in `tests/lib/TestRegistry.psm1` so `-Only <group>` and the dashboard selection tree pick it up.

4. **Documentation pass.** Touch every doc your change makes wrong, and only those. Common candidates:

   | What you changed | Update |
   |---|---|
   | A new verb / subverb / flag, or changed UX | `docs/usage.md`, `docs/cookbook.md`, `README.md` if user-visible |
   | A function signature or module's public surface | The module header's "Public surface" section |
   | A new design choice or trade-off | `docs/design-decisions.md` |
   | A new WSL2/pwsh/systemd quirk you worked around | `docs/wsl2-gotchas.md` (and `docs/troubleshooting.md` if user-visible) |
   | A new test / new test directory / runner flag | `docs/testing.md` and `docs/extending.md` |

   When the test counts in `docs/testing.md` go out of date, update them too — Copilot review will flag stale numbers.

5. **Verify locally before pushing.**

   ```powershell
   .\test-claudearium.ps1 -ParseCheck             # ~1s
   .\test-claudearium.ps1 -Auto -Only pure -CI    # ~5s
   ```

   Run `-Auto -Only distro -CI` for any change that touches the distro path, or rely on CI for that lane (warm runs are ~3 min).

6. **Open the PR.** First push: `git push -u origin <branch>` then `gh pr create` with a concise title (<70 chars), a `## Summary` of bullets, and a `## Test plan` checklist. **Never include local filesystem paths** (`C:\Users\<account>\…`) in the PR body or commit messages — they leak the account name. Refer to local-only artifacts by short relative name or omit entirely.

   **PR titles are release notes.** The release workflow runs `gh release create --generate-notes`, which builds release notes from merged PR titles since the previous tag. Treat the title as the changelog line a user will read: start with a verb, present tense, plain English (`add self-update verb`, not `feat/self-update WIP` or `wip stuff`). If the scope drifts during review, rename via `gh pr edit <N> --title "<new>"` *before* merge — stale titles produce misleading release notes.

7. **Request Copilot review explicitly after every push.** Copilot's automatic trigger is unreliable — it sometimes doesn't fire on follow-up pushes. After each `git push`, request a review and then check for comments:

   ```powershell
   # Explicitly re-request Copilot review (idempotent; safe to re-run).
   # The reviewer slug is the capitalised 'Copilot' (the bot's app name) —
   # 'copilot-pull-request-reviewer' (the username on inline comments) is
   # not accepted here as it's not a collaborator.
   gh api -X POST repos/MaceWindu/Claudearium/pulls/<N>/requested_reviewers `
       -F 'reviewers[]=Copilot'

   # Inline thread bodies:
   gh api repos/MaceWindu/Claudearium/pulls/<N>/comments
   # Review-level overview:
   gh pr view <N> --json reviews,latestReviews
   ```

   For each comment: fix the code or reply with a short rationale via `gh api .../comments/<id>/replies`. Do not stack new work on top of unresolved review comments.

8. **Resolve review threads on GitHub** after fixing. GitHub doesn't auto-resolve when a follow-up commit addresses the line:

   ```powershell
   # List unresolved threads:
   gh api graphql -f query='query { repository(owner: "MaceWindu", name: "Claudearium") { pullRequest(number: <N>) { reviewThreads(first: 50) { nodes { id isResolved path comments(first: 1) { nodes { body } } } } } } }'
   # Resolve each:
   gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<id>"}) { thread { isResolved } } }'
   ```

   Resolve mutations are independent — run them in parallel.

9. **Iterate until CI is green and review is clean.** Wait for the three workflow jobs (parse-check, pure-tests, distro-tests) to complete before declaring done. The distro lane is `continue-on-error: true` while we shake out hosted-runner WSL2 quirks, but you should still investigate failures there.

10. **Do not merge the PR autonomously.** Leave that to the user. The branch can stack many commits — the final review is what matters.

### Release process

Every push to `master` triggers `.github/workflows/release.yml`, which mints a `vYYYY.M.N` tag and publishes a GitHub release with the zipped tool and auto-generated notes. `YYYY`/`M` are UTC year/month at the time of merge; `N` is the next sequence within that month. There is **no manual tagging or release step** — merging is the release. See [design-decisions.md §19](./docs/design-decisions.md) for the rationale.

### Recurring traps from prior sessions

These are mistakes that were made and corrected at least once; keep the corrections in mind so they don't reappear.

- **Array splat clobbers named parameters.** When invoking `claudearium.ps1` from a test, use `Invoke-Claudearium -Args @{ Verb='…'; Force=$true }` (hashtable splat). `@('verb', '-Force')` passes everything as positional — `-Force` becomes a stray string.
- **`Write-Host` doesn't go to the pipeline.** Capturing `& script.ps1 …` output yields empty when the script writes via `Write-Host`. Use `*>&1` to merge Information into Output.
- **`& script.ps1 …` from a function leaks the child script's pipeline output into the function's return value.** Pipe to `| Out-Host` (or `| Out-Null` if you don't need to see it) when you don't want it accumulated.
- **`<word>` in Pester `It` descriptions is a TestCases template placeholder.** Under StrictMode it errors with "variable not set". Avoid `<…>` in test names.
- **`[regex]::Escape($x)` as a bare argument is parsed as a type literal + extra positional arg.** Wrap in parens: `Should -Match ([regex]::Escape($x))`.
- **PR descriptions and commit messages must never reference `C:\Users\<account>\…` paths.** They leak the user's account name; GitHub keeps an edit history of PR bodies. Use short relative names or omit local artifacts entirely.
- **Cleanup belongs in `finally`, always.** Distro tests, manual tests, and anything that mutates real state must clean up even on Ctrl+C / failure. Use the `Initialize-TestDistro` pattern: snapshot pre-existing state at start so cleanup can leave it alone if it was already there.
- **`$PSBoundParameters` inside a function is the FUNCTION's bound params, not the script's.** Functions with no `param()` block see an empty hashtable, so a check like `$PSBoundParameters.ContainsKey('Name')` from inside `Invoke-Setup` is silently always-false — and `setup -Name foo` is silently overridden by the profile's `distro.name`. Use `$Script:RootBoundParams` (captured at script root) instead — see [wsl2-gotchas.md #18](./docs/wsl2-gotchas.md). Once cost a real user's distro before the regression test landed.

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

## Testing changes

There's a real test runner now: `.\test-claudearium.ps1`. After editing:

```powershell
.\test-claudearium.ps1 -ParseCheck       # parses every .ps1/.psm1
.\test-claudearium.ps1 -Auto -Only pure  # ~5s, no WSL2 needed
.\test-claudearium.ps1 -Auto -Only distro -CI  # ~5min, ephemeral test distro
```

`.github/workflows/test.yml` runs parse-check + pure on every push to
any branch; the distro lane runs on PRs and on `master`. Full details
and what's covered live in [docs/testing.md](./docs/testing.md).

The previously-documented smoke-test cases are now real assertions:
- Parse-check → `tests/pure/` (also `-ParseCheck` mode runs in CI)
- Reconcile no-op → `tests/distro/Reconcile.Tests.ps1`
- Idempotency (mount/sync × 2) → `tests/distro/Mount.Tests.ps1`
- Cleanup path → per-verb AfterAll blocks under `tests/distro/`

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

Per-verb help and full recipes live under `docs/usage.md`, `docs/cookbook.md`, `docs/troubleshooting.md`. The root `README.md` is overview + quick-start only.

## Conventions to keep

- **Interactive-first UX:** every verb that operates on multiple items has a bare-name dashboard (`.\claudearium.ps1 project`, `.\claudearium.ps1 session`, etc.). Subverbs (`project add`, `session new`) are scriptable fallbacks.
- **`master`, not `main`,** as the default-branch fallback (durable user preference; smart detection from a host checkout still wins when available).
- **No MCP servers** — CLIs (`gh`, `glab`, `acli`, `seqcli`) are installed on PATH and invoked via the `Bash` tool. Don't add `mcpServers` to the synthesized `settings.json`.
- **`payload/` files are deployed via base64.** When adding a new payload, push it through `Send-FileToDistro` / `Send-RootFileToDistro` rather than constructing a here-doc on the bash side.
- **Use plain `systemctl enable`, not `enable --now`,** in install scripts — the latter hangs intermittently in WSL2 (gotcha #4). Trigger the unit's effect inline if the current session needs it.
