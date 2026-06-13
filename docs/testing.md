# Testing

Claudearium ships a self-contained test runner at `test-claudearium.ps1`.
Run it with no args for the interactive dashboard, or with one of the mode
switches below for CI-style scripted invocation.

## Quick start

```powershell
.\test-claudearium.ps1               # interactive dashboard
.\test-claudearium.ps1 -ParseCheck   # parse all .ps1/.psm1 in the repo
.\test-claudearium.ps1 -Auto         # run every automatic test
.\test-claudearium.ps1 -Diag         # read-only diagnostic probes (stdout)
.\test-claudearium.ps1 -Snapshot     # diag + write tests/results/diag-*.txt for bug reports
.\test-claudearium.ps1 -Help
```

`-CI` implies `-NonInteractive`, prints concise output, and exits non-zero
on any failure — that's the form the GitHub Actions workflow uses.

## What the suite covers

| Lane | What it tests | Runs against | Wallclock |
|---|---|---|---|
| `pure`   | The bits of every module that don't touch `wsl.exe` — profile validation, diff calculation, drvfs/wrapper path transforms, the AllowedIPs split, the `Read-*` -NonInteractive paths in UI.psm1, plus static-analysis regressions for the documented [wsl2-gotchas](./wsl2-gotchas.md). | Nothing (host pwsh only). | ~3–5 s |
| `distro` | Every verb's happy path: setup, project add/list/remove, session new/remove (clean and dirty), mount add/sync/remove (idempotent fstab + actual mountpoint), tools list/enable/disable, host-tools add/remove with the wrapper marker, VPN payload + Copy-WgConfig (no systemctl chain), reconcile no-op, claude-settings apply, Install-ClaudeFile end-to-end, and the shared account-level Claude store (host folder drvfs-mounted at the store path, ~/.claude symlinks, cross-user two-way-sharing proof under the mount umask, migrate-once, backup/restore round-trip). Plus a gotcha pair: argv-mangling protection and the fstab inline-regex parser. | An **ephemeral** `claudearium-test` distro that the runner provisions and unregisters every run. Your real distro is never touched. | ~3–5 min |
| `manual` | UX checks that need human eyes: Windows Terminal tab color, `open-claudearium.ps1` launch, the four `login` subverbs, and (when `-WgConfigPath` is supplied) full VPN connectivity. **The runner automates the setup** — installs the tools each test needs (claudeCode for OpenSession; claudeCode/gh/glab/acli for Login), creates sentinel projects/sessions, launches the wt tabs / toggles the VPN, and only prompts for the human judgment ("is the tab red?", "do these IPs look right?"). On failure, the runner prompts for a free-text note and scrubs the JSON results file of usernames, home/AppData/repo paths, and the machine name before writing — safe to attach to a bug report. | The ephemeral test distro (same one the `distro` lane uses). Manual tests run against an isolated test profile and never touch your real distro or `%LOCALAPPDATA%\claudearium\claudearium.profile.json`. | ~10 min total (dominated by tool installs in `Login`/`OpenSession`) |
| `diag`   | Read-only probes you can run against your real distro for troubleshooting. Five areas: distro state, profile validity + per-block drift, VPN/killswitch, tools inventory, and a `Snapshot` orchestrator that dumps everything to `tests/results/diag-*.txt` for bug reports. | Either real or test distro (you pick). Strictly read-only. | ~10 s |

Headline numbers as of this writing — Pester `It`-block counts for
the auto lanes (the manifest entries are coarser; each entry is a
test *file* that typically contains 3–10 individual assertions):
**555 pure** + **~105 distro** = ~660 auto checks. The 5 **manual** entries
in the manifest aren't Pester `It` blocks — they're y/n prompts wired
through `Invoke-ManualTest` — bringing the suite total to ~665 checks. CI runs parse-check + pure on
every push to any branch; the distro lane runs on PRs and on `master`.
Manual is opt-in (never in CI); diag is on-demand.

The release zip ships the `diag` lane (`tests/diagnostic/` + `tests/lib/`)
plus `test-claudearium.ps1` so end users can run `claudearium diagnostics`
(or `.\test-claudearium.ps1 -Diag`) without cloning. The `pure`, `distro`,
and `manual` lanes are dev-only and excluded from the release zip.

After every run the runner prints an AUTO/MANUAL summary with per-test
status and the path to the results JSON. If anything failed it also
prints a "share with the maintainers" hint and the issues URL; the
JSON is scrubbed for common identifiers (usernames, home/AppData/repo
paths, machine name) before being written. The scrubber is not a
general secret redactor — if you typed tokens, API keys, or private
URLs into a manual-test Notes prompt, review the file before sharing.

## Running selectively

The dashboard's `s` option opens a checkbox list of every test in the
manifest, with `[AUTO]` / `[MANUAL]` tags and runtime estimates. Toggle by
number; Enter to run the selection.

CLI shortcut: `-Auto -Only <group>` restricts to a manifest group:

```powershell
.\test-claudearium.ps1 -Auto -Only pure        # ~3-5s
.\test-claudearium.ps1 -Auto -Only distro -CI  # full distro lane, CI mode
```

The `pure` lane has no preconditions — it'll run on any Windows machine
with pwsh 7+. The `distro` lane provisions an ephemeral WSL2 distro
(`claudearium-test` by default; override with `-TestDistroName`) and
unregisters it via `try { ... } finally { ... }`, so an interrupted run
still cleans up.

## Diagnostics

The `d` option in the dashboard, or the `-Diag` / `-Snapshot` flags from
the CLI, runs read-only probes:

```powershell
.\test-claudearium.ps1 -Diag                   # all probes, real distro, stdout only
.\test-claudearium.ps1 -Diag -Target test      # all probes, test distro
.\test-claudearium.ps1 -Snapshot               # diag + write a single file under tests/results/
.\test-claudearium.ps1 -Snapshot -SnapshotPath C:\path\to\out.txt
```

Six areas, all under `tests/diagnostic/`:

| Area | What it reports |
|---|---|
| Distro | WSL registration + state, `/etc/wsl.conf` contents, default user, interop binfmt registration, provisioned marker, `claude` user state |
| Profile | `Test-Profile` validity, per-block diff (projects / mounts / tools / host-tools / distro) without applying anything |
| Vpn | killswitch state, wg interface, host.internal reachability, nftables table count |
| Tools | desired-vs-installed table across the catalog |
| ToolUpdates | latest-version cache contents + age + staleness; per-tool installed-vs-latest comparison with probe-error column |
| Snapshot | runs every other probe + `wsl --list --verbose`, writes a single timestamped file under `tests/results/` — attach this to bug reports |

All probes are pure read operations against the distro. Running them
against your real `claudearium` won't modify anything.

## CI

`.github/workflows/test.yml` runs on every push to any branch and every
PR against master. Three jobs:

| Job | When | Hosted runner OK? |
|---|---|---|
| `parse-check` | every push + PR | Yes |
| `pure-tests`  | every push + PR | Yes |
| `distro-tests`| PR / `master`                     | Yes (uses hosted WSL2; allowed to fail with `continue-on-error: true` while we shake out runner quirks) |

The distro lane caches the downloaded rootfs across runs via
`actions/cache@v4` keyed on `scripts/bootstrap-distro.sh`. Cold runs take
~5 min; warm cache shaves the rootfs download.

## How the runner is wired

```
.github/workflows/test.yml          # CI: parse-check + pure + distro
test-claudearium.ps1                # entry point, mode dispatch
tests/
├── lib/
│   ├── TestRegistry.psm1           # static manifest (one entry per test file)
│   ├── TestDistro.psm1             # ephemeral distro lifecycle (refuses to clobber pre-existing)
│   ├── PesterRunner.psm1           # wraps Invoke-Pester; auto-installs Pester 5
│   ├── ManualTest.psm1             # Invoke-ManualTest primitive
│   ├── Diagnostic.psm1             # orchestrates tests/diagnostic/*.ps1
│   ├── TestRunHelpers.psm1         # Invoke-Claudearium hashtable-splat wrapper
│   └── Dashboard.psm1              # interactive UI + Invoke-TestRun
├── pure/*.Tests.ps1                # Pester, no WSL2
├── distro/*.Tests.ps1              # Pester against the test distro
├── manual/*.ps1                    # Invoke-ManualTest wrappers
└── diagnostic/*.ps1                # standalone read-only probes
```

The manifest in `tests/lib/TestRegistry.psm1` is the single source of
truth: every test file is registered with its group, kind (auto/manual),
distro requirement, VPN-real requirement, and runtime estimate. The
dashboard's selection tree and the `-Only` filter both read from it.

## Adding a new test

See [extending.md#adding-tests](./extending.md#adding-tests).

In short: pick the right directory based on what you need, register your
file in `tests/lib/TestRegistry.psm1`, and run it via the runner.

## Common gotchas

- **The `distro` lane provisions a real WSL2 distro.** It runs the same
  `claudearium.ps1 setup` you'd run by hand, just with `-Name
  claudearium-test`. Don't be surprised when `wsl --list` shows a
  `claudearium-test` entry mid-run.
- **`-Only` only filters `-Auto` and `-Manual`** — diag and the
  interactive dashboard ignore it.
- **VPN connectivity is opt-in.** Without `-WgConfigPath <wg0.conf>`, the
  distro VPN test exercises payload-install only and skips the
  connectivity probes; the manual VpnConnectivity test is filtered out
  entirely.
- **Manual tests run against the ephemeral test distro**, not your real
  distro. They share the test-distro provisioning with the `distro`
  lane — if you select manual + auto in the same run, the distro is
  provisioned once and unregistered at the end. Each manual test
  installs the tools it needs as part of setup (claudeCode for
  OpenSession; claudeCode/gh/glab/acli for Login), so a Login run takes
  several minutes on the first cold install.
- **Pester 5 auto-installs to `CurrentUser` scope** on first run if only
  the legacy Pester 3 (shipped with Windows PowerShell 5.1) is available.
  The runner tries without `-SkipPublisherCheck` first and falls back
  only on the publisher-mismatch error.
- **The runner uses hashtable splat** (`@{ Verb=...; Force=$true }`) to
  invoke the production script. Array splat clobbers named/switch params
  — see [wsl2-gotchas.md](./wsl2-gotchas.md) for the underlying rule.

## Replacing `CLAUDE.md`'s smoke-test checklist

The old four-step "Smoke-testing changes" recipe in `CLAUDE.md` is
subsumed by:

| Old step | Now run |
|---|---|
| Parse-check changed files | `.\test-claudearium.ps1 -ParseCheck` |
| Reconcile no-op after apply | covered by `tests/distro/Reconcile.Tests.ps1` |
| Idempotency (mount add/sync × 2) | covered by `tests/distro/Mount.Tests.ps1` |
| Cleanup path leaves no trace | covered by `tests/distro/*.Tests.ps1` AfterAll cleanup |
