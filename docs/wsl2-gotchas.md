# WSL2 + pwsh + systemd gotchas

Concrete bugs hit during the build, with symptom + cause + the fix as
applied. Read this when something unexplained is happening at the pwsh ↔ WSL
boundary, or before adding a new module that crosses that boundary.

Each entry follows the same shape: a one-line **symptom**, the **cause** (often
not obvious from the symptom), and the **fix as applied in this codebase** so
you can grep for the pattern.

---

## 1. `wsl.exe` argv mangles `$VAR` and strips backslashes

**Symptom:** `bash -c 'X=hello; echo "X=$X"'` invoked via `wsl.exe ... -- bash
-c <cmd>` prints `X=` instead of `X=hello`. Same script run inside the distro
manually works.

**Cause:** somewhere in the `pwsh → wsl.exe → WSL VM → bash` argv chain,
`$VAR` references get pre-expanded (to empty strings, since they reference
undefined Windows env vars or something similar) before bash sees them.
Backslash escapes get stripped too — `echo "\$LITERAL"` becomes `echo
"$LITERAL"` which bash expands to empty. We verified the pwsh-side bytes are
correct (hexdumped the pwsh string), so the mangling happens beyond pwsh.

**Fix as applied:** `Invoke-InDistroScript` in `Wsl.psm1` base64-encodes
the script on the pwsh side and decodes inside the distro. The wrapper that
passes through argv is pure ASCII (`printf '%s' '<b64>' | base64 -d | bash
-l`) so there's nothing to mangle. Script body reaches bash intact.

Use `Invoke-InDistro` only for short single-line commands without `$VAR`
references (`command -v X`, `nft list ...`, `apt install foo`). Use
`Invoke-InDistroScript` for anything multi-line or shell-variable-using.

---

## 2. `ConvertFrom-Json -AsHashtable` unwraps single-element JSON arrays

**Symptom:** `Test-Profile` rejects a freshly-written profile with "projects
must be an array" even though the JSON `"projects": [{...}]` clearly is one.

**Cause:** PowerShell's `ConvertFrom-Json -AsHashtable` returns the lone
element directly when an array has exactly one item, *not* a 1-element array
containing it. So `$spec.projects` is the project hashtable, not an array.

**Fix as applied:** every read path that touches a profile array wraps with
`@(...)`:

```powershell
$projects = @($Spec.projects)   # always an array, even if pwsh unwrapped
foreach ($p in $projects) { ... }
```

This is now ubiquitous in `Profile.psm1`, `Projects.psm1`,
`Mounts.psm1`, `HostTools.psm1`, and the entry-point.
Mechanical: when reading `.projects` / `.hostMounts` / `.hostTools` from a
profile, always `@()` it.

---

## 3. systemd-logind / dbus don't start without manual intervention

**Symptom:** every `wsl.exe -d <distro> -u <user> -- ...` invocation prints
`wsl: Failed to start the systemd user session for '<user>'. See journalctl
for more details.` on stderr. Functionality unaffected.

**Cause:** WSL tries to create a per-user systemd session on first
non-interactive login. That requires `systemd-logind` to be running, which
requires `dbus.service`. Neither auto-starts under WSL2's systemd integration.
The proper fix is `loginctl enable-linger <user>`, but `loginctl` itself
requires `logind` to be up — chicken-and-egg.

We tried `systemctl start dbus` followed by `systemctl start systemd-logind`.
`systemctl start` hangs intermittently in WSL2 (see gotcha #4).

**Fix as applied:** `Invoke-InDistro` and `Invoke-InDistroScript` in
`Wsl.psm1` filter the warning line out of both captured and streamed
output. The line is purely cosmetic; functionality is unaffected. Direct
`wsl.exe` calls for interactive stdio (the `login` verbs, the `wt` launch in
open-claudearium.ps1) still show it occasionally — accepted as the cost of not
breaking those interactive flows.

---

## 4. `systemctl --now` and `systemctl start` hang intermittently in WSL2

**Symptom:** `systemctl enable --now <unit>` or `systemctl start <unit>` from
inside the distro never returns. Sometimes works fine; sometimes hangs for
minutes.

**Cause:** systemd's per-unit start blocks on the unit's `ExecStart`, which in
turn may block on something WSL doesn't initialize cleanly (D-Bus, network
target, etc.). The exact trigger is fuzzy.

**Fix as applied:** for our payload services (`claudearium-killswitch.service`,
`claudearium-wsl-interop.service`), the install scripts split `enable --now` into
`enable` + a manual one-shot of the service's effect:

```bash
# in HostTools.Initialize-WslInteropService:
systemctl daemon-reload
systemctl enable claudearium-wsl-interop.service >/dev/null 2>&1
# Don't enable --now — manually register binfmt for the current session:
test -e /proc/sys/fs/binfmt_misc/WSLInterop || \
  echo ':WSLInterop:M::MZ::/init:PF' > /proc/sys/fs/binfmt_misc/register
```

The systemd unit takes effect at next boot. The manual command keeps the
current session usable.

---

## 5. WSLInterop binfmt isn't auto-registered under WSL2 systemd

**Symptom:** trying to exec a Windows `.exe` from inside the distro fails with
`Exec format error`. Manually running `/mnt/c/Windows/System32/notepad.exe`
fails the same way even though the file exists.

**Cause:** WSL's standard `/init` registers a `binfmt_misc` entry for `MZ` (PE
magic bytes) so the Linux kernel hands `.exe` execs to WSL's interop bridge.
Under WSL2 + systemd, that registration is skipped — systemd takes over PID 1
and WSL's `/init` doesn't get to do its usual binfmt setup. Known WSL bug.

**Fix as applied:** `HostTools.Initialize-WslInteropService` deploys a
`claudearium-wsl-interop.service` systemd unit that runs at every boot:

```ini
ExecStart=/bin/sh -c 'test -e /proc/sys/fs/binfmt_misc/WSLInterop || \
  echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'
```

It's idempotent (no-op if WSLInterop is already there) and bootstrap installs
+ enables it for fresh distros.

---

## 6. WSL's `[network] generateHosts = true` overwrites `/etc/hosts` at boot

**Symptom:** the killswitch-prep script writes `host.internal -> <gateway>`
into `/etc/hosts`. After a distro restart, the entry is gone.

**Cause:** WSL regenerates `/etc/hosts` from a template at every boot when
`generateHosts = true` (default). Our entry isn't part of the template, so it
gets stripped.

**Fix as applied:** the prep script runs at every boot (it's a
`Before=nftables.service` oneshot), AFTER WSL has done its `generateHosts`
work, and appends to whatever's there. The order ensures our entry survives
each reboot.

If you want to opt out of WSL's regeneration entirely, set `[network]
generateHosts = false` in `wsl.conf`. We didn't — losing WSL's default
localhost / hostname entries felt worse than the regen-each-boot cycle.

---

## 7. `nft iif wg0` fails before wg0 exists

**Symptom:** at boot, `systemctl status nftables.service` shows
`/etc/nftables.conf: Error: Interface does not exist` on the `iif wg0` /
`oif wg0` lines.

**Cause:** `iif` / `oif` in nftables resolve the interface name to an interface
*index* at rule-load time. If the interface doesn't exist yet (boot order:
nftables is supposed to load *before* wg-quick brings up wg0), index lookup
fails and the whole ruleset is rejected.

**Fix as applied:** use `iifname "wg0"` / `oifname "wg0"` (string-matched at
packet-eval time) in `payload/etc/nftables.conf`. Loads cleanly regardless of
whether wg0 exists yet. When wg0 comes up, matching starts working naturally.

---

## 8. `sudo` with `!secure_path` inherits a PATH missing /sbin

**Symptom:** `sudo dpkg -i /tmp/foo.deb` fails with `dpkg: warning: 'ldconfig'
not found in PATH` — even though dpkg, ldconfig, etc. are all installed.

**Cause:** the `claude` user's login PATH (set by `/etc/profile`) doesn't
include `/sbin`, `/usr/sbin`, `/usr/local/sbin`. Our `/etc/sudoers.d/claude`
sets `!secure_path` so sudo inherits the user's PATH rather than sanitizing it.
dpkg's post-install scripts call `ldconfig` (which lives in `/sbin`), can't
find it, and bail.

**Fix as applied:** in `Tools.Install-Pwsh`, the install script
prepends sbin paths at the top:

```bash
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
sudo apt-get update -qq
# ... apt-get install / dpkg -i continues with sbin paths available
```

For tools that don't use `dpkg -i` directly (apt-get install handles its own
PATH), this isn't needed. Apply the prepend in any new handler that calls
`dpkg` directly.

---

## 9. PowerShell variables are case-insensitive — lowercase locals shadow [switch] params

**Symptom:** a function declares `[switch]$Force`, the body has `$force = ...
'--force' ...`, and calling the function fails with *Cannot convert "--force"
to type SwitchParameter*.

**Cause:** PowerShell variable names are case-insensitive. Inside the function,
`$force` and `$Force` are the SAME variable. The local assignment overwrites
the [switch] parameter with a string, and the next reference (e.g. passing
through to another function expecting [switch]) trips type coercion.

**Fix as applied:** never use a lowercase local with the same name as a
[switch] parameter. Rename one of them. In `Sessions.Remove-Session`:

```powershell
# WRONG (lowercase $force shadows [switch]$Force):
$force = if ($Force) { '--force' } else { '' }

# RIGHT:
$forceFlag = if ($Force) { '--force' } else { '' }
```

Same applies in `Profile.Read-Profile` (renamed `$raw` to `$parsed` to
avoid shadowing the `[switch]$Raw` param).

---

## 10. Cascading `Import-Module -Force` invalidates script-scope imports

**Symptom:** Get-ProjectListRows calls `Test-DistroExists` (exported from
`Wsl`); the script imports Wsl with `-Force` at the top.
Calling the function fails with *The term 'Test-DistroExists' is not
recognized*.

**Cause:** `Projects.psm1` and `Sessions.psm1` each had
`Import-Module ... Wsl.psm1 -Force` inside the module. When the parent
script imports Projects (also with `-Force`), Projects re-imports Wsl with
`-Force`, which **invalidates the parent script's earlier Wsl import**.
Subsequent function calls in the script can't find Wsl's exports.

**Fix as applied:** child modules don't use `-Force` on their dependency
imports. The parent script's `-Force` import is the source of truth; child
modules just need *any* version loaded:

```powershell
# child module (Projects.psm1):
Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')      # NO -Force
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')  # NO -Force
```

The parent script's `-Force` makes the whole module re-load each invocation;
no need to repeat it in cascades.

The same applies to anything reachable from `claudearium.ps1`'s session
via the dashboard's `d` shortcut (which shells out to
`& test-claudearium.ps1 -Diag` in the same process):

- `tests/diagnostic/*.ps1` — invoked directly by `-Diag`.
- `tests/lib/*.psm1` — imported by `test-claudearium.ps1` itself (and by
  `Dashboard.psm1` from within the lib tree). A `-Force` re-import of
  `modules\Wsl.psm1` from one of these libs still cascades and
  invalidates `claudearium.ps1`'s earlier import — same failure mode
  (`Get-WslDistros is not recognized`), one level further up. PR #13
  fixed only the diagnostic-script case and the user hit the crash
  again from the lib path.

Drop `-Force` on every `modules\*.psm1` import under both trees; the
static check in `tests/pure/Gotchas.Tests.ps1` enforces both.

---

## 11. `wsl --import` wants an uncompressed `.tar` (or needs decompression help)

**Symptom:** `wsl --import` of a `.tar.xz` rootfs fails. Or works on one
machine, fails on another.

**Cause:** historically, `wsl --import` only accepted uncompressed `.tar`.
Modern WSL versions handle some compressed formats, but coverage varies by WSL
2.x release and what compression utilities Windows has registered. Windows 10's
`tar.exe` (bsdtar via libarchive) supports `.tar.xz` natively for *extract*
operations, but not all builds include the xz codec.

**Fix as applied:** `Wsl.Convert-RootfsToTar` accepts `.tar` /
`.tar.xz` / `.tar.gz`. Tries decompression strategies in priority order:
1. `.tar` — copy as-is.
2. `.tar.gz` — native .NET `GZipStream`.
3. `.tar.xz` — try `7z.exe` (most dev machines have 7-Zip), then `python`'s
   `lzma` module, then a **pure-managed decoder** (`Expand-XzManaged`).

The managed decoder (`Wsl.psm1`'s embedded `Claudearium.XzDecoder`, compiled on
demand with `Add-Type`) is the guaranteed path: it decodes the xz container +
LZMA2 stream in managed code, so setup never depends on an external xz codec
being installed. 7-Zip and Python are kept only as faster accelerators when
present. A prior version *ended* the chain at `python -c "import lzma..."` with
no managed fallback — but Python is an **optional** dependency, so a machine
without it (and without 7-Zip) failed setup outright. Don't assume optional host
tooling exists; the final, guaranteed tier must be PowerShell Core only
(`Add-Type` ships with PowerShell 7). The
managed output is verified byte-for-byte against python-lzma on the real Debian
`rootfs.tar.xz`; `tests/pure/Wsl.Tests.ps1` pins a small fixture. The managed
decoder is much slower than the native codecs — measured on the ~450 MB rootfs:
7-Zip ~1.2 s, native liblzma ~14 s, managed ~36 s (~30x slower than 7-Zip). It's
a one-time `setup` cost dwarfed by the download + provisioning, which is why the
native paths stay as accelerators when installed and the managed path is only the
guaranteed fallback.

Note: Windows' bundled `tar.exe` (bsdtar/libarchive) does *not* include the xz
codec — it shells out to a missing `xz -d` and errors — so it is not a fallback.

The result is always a plain `.tar` for `wsl --import`.

---

## 12. `0.0.0.0/0` in AllowedIPs swallows more-specific routes

**Symptom:** with WG tunnel up, the host's `host.internal` becomes unreachable
even though we have explicit nftables `accept oif eth0 ip daddr $HOST_SUBNET`
rules.

**Cause:** `wg-quick` with `AllowedIPs = 0.0.0.0/0` enables a fwmark +
policy-routing dance: a rule says "not from packets with fwmark X → use
routing table 51820"; table 51820 has a single default route via wg0. The
nftables rule allows the packet, but the routing decision sends it via wg0
anyway because policy routing intercepts before the main table is consulted.

**Fix as applied:** `Vpn.ConvertTo-SplitAllowedIPs` rewrites the
incoming `wg0.conf` before installing it:

```
AllowedIPs = 0.0.0.0/0       →    AllowedIPs = 0.0.0.0/1, 128.0.0.0/1
```

Same address space, but technically not `default`, so wg-quick installs
ordinary routes in the main table. More-specific routes (eth0 subnet) win
naturally, and `host.internal` stays reachable.

Same handling for IPv6 (`::/0` → `::/1, 8000::/1`).

---

## 13. `awk -v VAR=val` with literal strings flaky through pwsh → wsl

**Symptom:** `awk -v s='# === claudearium-managed-start ===' ... '$0 == s {skip=1}
$0 == e {skip=0; next} !skip'` matches *nothing* when invoked through
`Invoke-InDistro`. The same awk run by hand inside the distro works.

**Cause:** never fully isolated; suspect it's another argv-mangling artifact
where the `-v` assignment gets corrupted. Adding `--%` (pwsh stop-parsing
token) didn't help. Wrapping the whole awk script in a here-string didn't help.

**Fix as applied:** switch from `-v var` matching to inline regex matching:

```awk
# was: awk -v s='# === claudearium-managed-start ===' '$0 == s {skip=1} ...'
# now: awk '/claudearium-managed-start/ {skip=1; next} /claudearium-managed-end/ {skip=0; next} !skip'
```

Used in `Mounts.Set-HostMountsInDistro` and `Get-HostMountsActual
FromDistro`. The regex form is robust through every layer of the call chain.

---

## 14. `[Text.Encoding]::GetBytes($s -replace a, b)` parses as 2 args, not 1

**Symptom:** `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content
-replace "\`r\`n", "\`n"))` fails with *Cannot find an overload for "GetBytes"
and the argument count: "2"*.

**Cause:** pwsh parses `Method($a -op $b, $c)` as `Method(<$a-op-$b>, <$c>)`
— two args, not one. The `-replace` argument list (pattern, replacement) gets
treated as positional args to the method.

**Fix as applied:** explicit parens around the `-replace` expression:

```powershell
# WRONG:
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content -replace "`r`n", "`n"))

# RIGHT:
$normalized = ($content -replace "`r`n", "`n")
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
```

Most modules in this codebase already follow this pattern via the
`$normalized` intermediate.

---

## 15. `Ensure-` is not a PowerShell-approved verb

**Symptom:** every `Import-Module` of `HostTools.psm1` printed
*WARNING: The names of some imported commands from the module 'HostTools'
include unapproved verbs that might make them less discoverable.*

**Cause:** PowerShell maintains an "approved verbs" list (`Get-Verb`). `Ensure-`
isn't on it. Functions using unapproved verbs trigger the warning unless the
caller passes `Import-Module -DisableNameChecking`.

**Fix as applied:** renamed `Ensure-WslInteropService` to
`Initialize-WslInteropService` (Initialize *is* approved). Same semantics, no
warning.

When adding new functions:
```powershell
Get-Verb | Select-Object -ExpandProperty Verb   # check before naming
```

Approved alternatives for the "idempotent setup" use case: `Initialize-`,
`Set-`, `Install-`, `New-`, `Update-`.

---

## 16. `$LASTEXITCODE` from internal native commands leaks to the script's exit code

**Symptom:** `claudearium.ps1 tools list` reports the right info but the
script exits with code 1. Wrapping invocations in CI says "tools list failed".

**Cause:** `Test-CommandInDistro` uses `command -v <x>` to check if a tool is
installed. When the tool isn't there, `command -v` returns 1, and pwsh sets
`$LASTEXITCODE = 1`. The script falls off the bottom; pwsh uses
`$LASTEXITCODE` as the script's exit code.

**Fix as applied:** the entry-point ends with an explicit `exit 0`:

```powershell
switch ($Verb.ToLowerInvariant()) { ... }

# Any non-zero $LASTEXITCODE bubbled up from internal native-command calls
# (e.g. `command -v` checks inside Test-ToolInstalled, which return 1 when
# the tool isn't installed) shouldn't be reported as a script failure.
# Verbs that *want* to fail call exit 1 explicitly inside their handlers.
exit 0
```

Verbs that legitimately want non-zero exits (`profile validate` on failure,
unknown-verb dispatch) call `exit 1` / `exit 64` *inside* their handler before
control returns.

---

## 17. `images.linuxcontainers.org` URL-encodes `:` as `%3A`

**Symptom:** the rootfs URL resolver returned "Could not resolve latest
rootfs timestamp" even though the listing page clearly had timestamp dirs.

**Cause:** the directory listing's HTML uses URL-encoded paths in `href`
attributes: `<a href="20260511_05%3A24/">`. Our regex looked for the literal
`:` character.

**Fix as applied:** regex matches the URL-encoded form:

```powershell
$stamps = [regex]::Matches($html.Content, 'href="(\d{8}_\d{2}%3[Aa]\d{2})/"')
```

The captured `%3A` form goes back into the download URL unchanged; HTTP
clients decode it on the way out.

---

## 18. `$PSBoundParameters` inside a function is the FUNCTION's bound params, not the script's

**Symptom:** `claudearium.ps1 setup -Force -Name claudearium-test` silently wipes
and re-bootstraps the user's *real* `claudearium` distro instead of creating
the requested `claudearium-test`. State file under
`%LOCALAPPDATA%\claudearium\claudearium\state.json` is overwritten; session
worktrees inside the old distro are gone. Took out a real user's distro before
we caught it.

**Cause:** the verb dispatcher had:

```powershell
function Invoke-Setup {
    $spec = Read-ProfileIfPresent
    if ($spec) {
        if (-not $PSBoundParameters.ContainsKey('Name'))        { $script:Name        = [string]$spec.distro.name }
        if (-not $PSBoundParameters.ContainsKey('InstallPath')) { $script:InstallPath = [string]$spec.distro.installPath }
    }
    ...
}
```

The intent: "if the user didn't pass `-Name` on the CLI, fall back to the
profile's `distro.name`." The bug: inside a function, `$PSBoundParameters` is
the **function's** bound parameters (Invoke-Setup takes no params → empty
hashtable), not the script-root's. The check is therefore always false, the
fallback always runs, and the explicit `-Name` is silently overridden by the
profile's `distro.name`. Same bug in `Resolve-DistroForOps` and
`open-claudearium.ps1`'s `Resolve-Distro`.

**Fix as applied:** snapshot `$PSBoundParameters` at script root into a
script-scoped variable and read THAT from the helpers:

```powershell
# Top of claudearium.ps1, immediately after Set-StrictMode:
$Script:RootBoundParams = $PSBoundParameters

function Invoke-Setup {
    $spec = Read-ProfileIfPresent
    if ($spec) {
        if (-not $Script:RootBoundParams.ContainsKey('Name'))        { ... }
        if (-not $Script:RootBoundParams.ContainsKey('InstallPath')) { ... }
    }
}
```

A pure regression test (`tests/pure/Gotchas.Tests.ps1`) parses each entry-point
script and fails if it (a) doesn't assign `$Script:RootBoundParams =
$PSBoundParameters` at top level, or (b) has a bare `$PSBoundParameters.ContainsKey(`
in non-comment code. Belt-and-braces: `Initialize-TestDistro` also writes a
dedicated test-only profile and passes `-ProfilePath` to `setup`, so even if
this bug regresses, the test path can't reach the user's real profile.

---

## 19. `New-Item -ItemType Directory -Path $dir` interprets wildcards in the directory name

**Symptom:** `Write-Profile` failed with
*"Could not find a part of the path"* when called against a profile path
under a `%LOCALAPPDATA%\claudearium\test-[bracket]\` directory whose
name contained `[` and `]`. The parent dir didn't exist, so
`Write-Profile` tried to `mkdir` it — but the operation reported the
path as missing even though the create call had just run.

**Cause:** `New-Item -Path` (without `-LiteralPath`) feeds the path through
the PowerShell provider's wildcard expansion. `[bracket]` is parsed as a
character class. There is no `-LiteralPath` on `New-Item -ItemType
Directory`, so there's no clean way to ask the cmdlet to take the string
verbatim. Same hazard applies anywhere a user-provided install path can
contain `[`, `]`, or `*`.

**Fix as applied:** switched every directory create on a path that can
contain user-controlled segments to the .NET API. Sites: `Write-Profile`,
`Write-State`, `Save-Rootfs`, `Import-Distro`, `Expand-Xz` (7-Zip
branch), `Set-UpdateCheckState`, plus two entry-point sites — `setup`'s
rootfs-staging temp dir and `profile edit`'s seed-from-template path:

```powershell
[void][System.IO.Directory]::CreateDirectory($dir)
```

`[System.IO.Directory]::CreateDirectory` takes a literal string and is
idempotent — no-op if the directory already exists, so the surrounding
`Test-Path` guard is unnecessary. `[void]` suppresses the `DirectoryInfo`
return value (which would otherwise pollute the pipeline).

A pure regression test in `tests/pure/Profile.Tests.ps1` exercises the
`[bracket]`-named parent branch.

---

## 20. Putting `$PATH` in the `wsl.exe -- bash -lc <cmd>` argv makes PATH empty

**Symptom:** A hostProject session's `open-claudearium.ps1` tab launches but
`claude` can't be found, or any tool invocation fails with "command not
found." Tracing shows `echo "$PATH"` inside the new shell prints just
`/home/claude/host-projects/<project>/bin:` — no `/usr/bin`, no `/bin`, no
anything else.

**Cause:** This is gotcha #1 striking again under a new disguise. The session
launcher built the bash command as a single argv string —
`export PATH='/home/claude/host-projects/<p>/bin':$PATH; exec claude` — then
passed it to `wsl.exe -d <distro> -u claude --cd <wt> -- bash -lc <cmd>`.
The `$PATH` substring goes through the same `pwsh → wsl.exe → WSL VM → bash`
argv chain as gotcha #1, so it is silently pre-expanded to an empty Windows
environment variable before bash ever reads it. Result: the prepend wins
against an empty tail, and the entire system PATH disappears.

**Fix as applied:** the PATH prepend lives in a per-project file inside the
distro, written by `Install-HostShadowsForProject`:

```bash
# /home/claude/host-projects/<project>/init.sh
export PATH='/home/claude/host-projects/<project>/bin':$PATH
```

`open-claudearium.ps1`'s `Resolve-SessionBashCommand` returns a string that
*sources* that file: `source '/home/claude/host-projects/<p>/init.sh'; exec
claude`. No `$VAR` in the wsl.exe argv. Bash reads the script from disk —
where `$PATH` is just text bytes — so the prepend composes correctly with
whatever PATH the login shell set up. Same fix philosophy as gotcha #1:
keep argv pure-ASCII and route the dynamic content through a file/pipe.

A regression test in `tests/pure/HostShadows.Tests.ps1` pins
`Get-HostShadowInitScriptPath` to the on-disk path the launcher expects;
the distro lane (`tests/distro/HostProjects.Tests.ps1`) end-to-end verifies
PATH contains both the bin dir and `/usr/bin` after a host-session open.

---

## 21. `git -c safe.directory=*` on the command line is ignored — and a fresh project user trips dubious-ownership

**Symptom:** under per-project user isolation, `project add` provisions the
`cp-*` user fine, then the mirror clone dies with `fatal: detected dubious
ownership in repository at '/tmp/...remote.git'` / `Could not read from remote
repository`. The obvious fix — passing `git -c safe.directory='*' clone --mirror
…` — does **not** work; git still refuses (see cause).

**Cause:** two things compounding. (1) The clone now runs as a freshly-created
`cp-*` user, but a *local-path* remote (a `file://` path, common in tests and for
local repos) is owned by a *different* user (`claude`/`root`), so git's
dubious-ownership guard fires. (2) Git **deliberately ignores `safe.directory`
supplied via `-c` on the command line** (and via env) — only `system`/`global`
config is honored — specifically so a malicious repo can't trust itself. So the
`-c` form is a no-op.

**Fix as applied:** write `safe.directory=*` into the **project user's global
gitconfig** at provisioning time (`New-ProjectUserInDistro`, as that user via
`runuser`):

```bash
runuser -u "$U" -- git config --global --add safe.directory '*'
```

Honored from global config, this lets the user clone a local-path remote owned
by anyone. The resulting mirror is owned by the cloning user, so subsequent
`git -C <mirror> …` operations (run as that user) never re-trip the guard. Real
`https`/`ssh` remotes never hit this — it's only filesystem-path remotes.

Related, same area: `userdel -r` of a project user fails if a drvfs mount is
still live under its home, so `Remove-ProjectUserInDistro` unmounts everything
under the home (and `pkill -KILL -u`) *before* `userdel`. And the generated sudo
password is passed to `chpasswd` via **stdin** (`printf … | chpasswd`), never on
argv — it's baked into the base64-transported script body as a
`ConvertTo-BashQuoted` literal, so it never appears in `ps`/history.

---

## 22. setgid alone doesn't make a shared dir group-*writable* — you need a default ACL (and `acl` isn't in the base image)

> **OBSOLETE as of the host-mount migration.** The shared store is no longer an
> in-distro ext4 dir with a `claudeshared` group + default ACL — it's a drvfs-mounted
> Windows host folder whose perms come from the mount `umask` (see [#24](#24-drvfs-mounts-ignore-chmod--chgrp--setfacl--perms-come-from-the-mount-umask) and
> [design-decisions #28](./design-decisions.md#28-shared-group-writable-account-level-claude-store)).
> Kept for history — the ACL reasoning below is why the *old* model needed `setfacl`.

**Symptom:** the shared account-level Claude store (`/opt/claudearium/claude-shared`,
[design-decisions #28](./design-decisions.md#28-shared-group-writable-account-level-claude-store))
is owned `root:claudeshared` mode `2775` (setgid) and every project user is in
`claudeshared`, yet project B can *read* a skill project A's agent created but
gets `Permission denied` trying to *edit* it.

**Cause:** setgid on a directory makes new entries inherit the *group*, but their
*mode* still comes from the creating process's umask. The default umask is `022`,
so an agent-created file lands mode-`644` — group-readable, **not**
group-writable. setgid solves ownership, not the write bit.

**Fix as applied:** put a **default POSIX ACL** on the store so every file created
under it is group-`rwx` regardless of umask, and re-assert it on the existing
tree:

```bash
setfacl -R    -m g:claudeshared:rwx /opt/claudearium/claude-shared   # existing
setfacl -R -d -m g:claudeshared:rwx /opt/claudearium/claude-shared   # future (default)
```

Two sub-traps: (1) **`acl`/`setfacl` is not in the Debian base image** — it's now
in `bootstrap-distro.sh`, and `Initialize-ClaudeSharedStore` `apt-get install`s it
on demand for distros provisioned before that. (2) A user added to a new
supplementary group (`usermod -aG claudeshared`) only sees it in a **fresh login
shell**; every `wsl -u <user> -- bash -lc …` is a fresh login, so sessions pick it
up immediately — but a long-lived interactive shell won't until re-login.

---

## 23. `chown -R` over a dir that holds symlinks-into-a-shared-store re-owns the targets

**Symptom:** after writing per-user `settings.json`, the shared store's
`CLAUDE.md` / `skills` / `agents` flip from `root:claudeshared` to the project
user, silently breaking cross-project group-write.

**Cause:** `~/.claude` now contains *symlinks* into the shared store. A broad
`chown -R <user>:<user> ~/.claude` walks them; depending on the traversal flags it
can re-own the symlink **targets**, not just the per-user files. (Still applies in
the host-mounted model: the targets now sit on a drvfs mount where `chown` is a
no-op, so a recursive chown is harmless-but-pointless churn there — but it can
still mangle ownership of any *real* per-user file under `~/.claude`.)

**Fix as applied:** never `chown -R` over `~/.claude`. `Install-ClaudeSettings`
chowns exactly the dir + the one file it wrote (`chown $owner $dir $file`), and
the symlinks are owned via `chown -h` when created (`Set-ClaudeSharedSymlinks`).
Claude's own per-user dirs (`history/`, `todos/`, …) are already user-owned, so
there's nothing else to recurse over.

Related: transporting directory *trees* (skills/agents) host↔distro uses
gzip-`tar` + **base64** (`Send-TreeToDistro` / `Receive-TreeFromDistro`), the same
base64 hop as the single-file writers (#6 / [design-decisions #6](./design-decisions.md#6-base64-transport-for-multi-line-bash-scripts))
— a raw tar through the pwsh→wsl pipe would get CRLF-mangled.

---

## 24. drvfs mounts ignore `chmod` / `chgrp` / `setfacl` — perms come from the mount `umask`

**Symptom:** you move a shared, multi-user-writable dir (the account-level Claude
store, [design-decisions #28](./design-decisions.md#28-shared-group-writable-account-level-claude-store))
onto a Windows host folder mounted via drvfs and try to make it group-writable the
old way (`chown root:claudeshared`, `chmod 2775`, `setfacl -d -m g:…:rwx`). Nothing
sticks — `getfacl` shows no ACL, the group never takes, and a second Linux user
still can't write.

**Cause:** a drvfs/9p mount is a *presentation* of a Windows filesystem, not real
Linux storage. With `metadata` **off** (the default unless you opt in), the kernel
synthesises every file's owner/group/mode from the mount's `uid`/`gid`/`umask`
options — uniformly, for every file — and `chmod`/`chgrp`/`setfacl` are silently
ignored (POSIX ACLs aren't supported on drvfs at all). So the entire setgid +
default-ACL apparatus that made the in-distro store group-writable ([#22](#22-setgid-alone-doesnt-make-a-shared-dir-group-writable--you-need-a-default-acl-and-acl-isnt-in-the-base-image))
is a no-op here.

**Fix as applied:** stop fighting it — let the mount options *be* the permission
model. The store mount is `rw,umask=000` with metadata off, so every file presents
world-`rwx` and any session user can read/write/create. No group, no `setfacl`, no
setgid. The mount record is injected once in `Get-MergedDesiredMounts`
(`Mounts.psm1`); `Get-MountFstabLine` suppresses `metadata` when a mount sets
`metadata = $false`. To share a host folder among *specific* Linux users instead,
you'd use `gid=<shared>,umask=002` with metadata **on** — but that reintroduces a
shared group, which is exactly what the store dropped.

A related trap: drvfs `mount -a` fails the **whole** fstab table if any mount's
host source dir is missing, so the host folder must be created (host-side) *before*
the mount is applied — `Initialize-ClaudeSharedHostDir` does this at setup/reconcile.

---

## Quick-reference table

| If you see... | Look at gotcha |
|---|---|
| `Exec format error` running a `.exe` wrapper | [#5](#5-wslinterop-binfmt-isnt-auto-registered-under-wsl2-systemd) |
| `Interface does not exist` from `nft` | [#7](#7-nft-iif-wg0-fails-before-wg0-exists) |
| `Failed to start the systemd user session` | [#3](#3-systemd-logind--dbus-dont-start-without-manual-intervention) |
| `Cannot find an overload for "GetBytes" and the argument count: "2"` | [#14](#14-textencodinggetbytes-replace-a-b-parses-as-2-args-not-1) |
| `dpkg: warning: 'ldconfig' not found in PATH` | [#8](#8-sudo-with-secure_path-inherits-a-path-missing-sbin) |
| `Cannot convert "--force" to type SwitchParameter` | [#9](#9-powershell-variables-are-case-insensitive--lowercase-locals-shadow-switch-params) |
| `unsupported arch:` from acli install | [#1](#1-wslexe-argv-mangles-var-and-strips-backslashes) |
| `projects must be an array` despite valid JSON | [#2](#2-convertfrom-json--ashashtable-unwraps-single-element-json-arrays) |
| `Test-DistroExists is not recognized` mid-script | [#10](#10-cascading-import-module--force-invalidates-script-scope-imports) |
| `systemctl --now` hangs | [#4](#4-systemctl---now-and-systemctl-start-hang-intermittently-in-wsl2) |
| WARNING about unapproved verbs | [#15](#15-ensure--is-not-a-powershell-approved-verb) |
| Verb works but script exits non-zero | [#16](#16-lastexitcode-from-internal-native-commands-leaks-to-the-scripts-exit-code) |
| `host.internal` not reachable through VPN | [#12](#12-0000-in-allowedips-swallows-more-specific-routes) |
| `detected dubious ownership` cloning a project mirror | [#21](#21-git--c-safedirectory-on-the-command-line-is-ignored--and-a-fresh-project-user-trips-dubious-ownership) |
| `awk -v` matches nothing | [#13](#13-awk--v-varval-with-literal-strings-flaky-through-pwsh--wsl) |
| `Could not resolve latest rootfs timestamp` | [#17](#17-imageslinuxcontainersorg-url-encodes--as-3a) |
| `wsl --import` fails on .tar.xz | [#11](#11-wsl---import-wants-an-uncompressed-tar-or-needs-decompression-help) |
| `host.internal` resets to nothing on reboot | [#6](#6-wsls-network-generatehosts--true-overwrites-etchosts-at-boot) |
| `setup -Name foo` wipes the wrong distro | [#18](#18-psboundparameters-inside-a-function-is-the-functions-bound-params-not-the-scripts) |
| `Could not find a part of the path` from `New-Item` on a `[bracket]` dir | [#19](#19-new-item--itemtype-directory--path-dir-interprets-wildcards-in-the-directory-name) |
| Host session opens with PATH = just the bin dir (no /usr/bin) | [#20](#20-putting-path-in-the-wslexe----bash-lc-cmd-argv-makes-path-empty) |
| Shared skill readable but not writable by another project (old in-distro store) | [#22](#22-setgid-alone-doesnt-make-a-shared-dir-group-writable--you-need-a-default-acl-and-acl-isnt-in-the-base-image) (obsolete) |
| `chown -R ~/.claude` re-owns symlink targets | [#23](#23-chown--r-over-a-dir-that-holds-symlinks-into-a-shared-store-re-owns-the-targets) |
| `chmod`/`setfacl` on a drvfs-mounted dir does nothing | [#24](#24-drvfs-mounts-ignore-chmod--chgrp--setfacl--perms-come-from-the-mount-umask) |
| distro has no internet (no eth0 IP) when a host VPN is up | [#26](#26-eth0-gets-no-dhcp-lease-no-ipv4-no-default-route-when-a-host-vpn-is-up-on-win10) |
| `vpnkit` tunnel won't start; gvproxy fails `exec format error` | [#27](#27-a-freshly-imported-distro-can-boot-without-the-wslinterop-binfmt-so-a-windows-exe-fails-with-exec-format-error) |
| distro has no egress under `vpnkit` despite the tunnel being up (wrong default route) | [#28](#28-wsl-vpnkits-tap-is-visible-in-every-distro-but-only-its-own-default-route-uses-it) |
| dashboard / `vpn`/`network`/`vpnkit`/`tools`/`host-tools` status hangs ~20s and restarts a stopped distro | [#29](#29-wslexe--d-distro--wakes-a-stopped-distro--read-only-statuslist-verbs-must-gate-on-running) |

## 25. The tmux server dies with the distro, not with the window — and `@(Get-Sessions)` nests

Two related traps from the curation-`main/` + tmux session model
([design-decisions.md #29](./design-decisions.md)).

**Symptom (lifecycle):** a detached session that survived closing its wt tab
vanishes after `wsl --shutdown` (or a host reboot / WSL idle timeout). **Cause:**
the per-user tmux server is an ordinary forked process inside the distro, not a
systemd unit — it survives a SIGHUP from the closing PTY (so window-close =
detach), but dies when the distro VM stops. **Fix-as-applied:** this is a
contract, not a bug — persistence is *across window-close, not across distro
shutdown*. `Resolve-SessionLiveness` reports such sessions as `dead` so they're
visible in the dashboard and removed by `prune sessions`; we don't try to make
the server outlive the distro.

**Symptom (array nesting):** `@(Get-Sessions -State $s).Count` returns `1` for a
multi-session state, and the single element is itself an `Object[]`. **Cause:**
`Get-Sessions` returns the array via the `,$all` unary-comma idiom (to preserve
shape for the empty/single case). Wrapping that in `@(...)` does **not** flatten
it — it nests the whole array as one element. **Fix-as-applied:** consume
`Get-Sessions` with `foreach ($s in (Get-Sessions ...))` or a bare assignment
(`$x = Get-Sessions ...`), never `@(Get-Sessions ...)`. When an always-array is
needed, materialize with `$a = @(); foreach ($s in (Get-Sessions ...)) { $a += $s }`.
(Get-Sessions also returns `$null` — not `@()` — for the empty case, so functions
taking the result into a `[object[]]` parameter must allow null or normalize it.)

---

## 26. eth0 gets no DHCP lease (no IPv4, no default route) when a host VPN is up on Win10

**Symptom:** with a host-side VPN running on Windows (observed with ProtonVPN — a
WireGuard tunnel that owns the host default route), the distro comes up with `eth0`
having **no IPv4 address** (only `lo`) and **no default route** — `ip route` is
empty and every destination is "Network is unreachable". The host's `vEthernet
(WSL)` NAT adapter is healthy (`172.22.208.1/20`), and `/etc/resolv.conf` still
holds `nameserver 172.22.208.1` (the NAT gateway). The exact same distro works the
moment the host VPN is disconnected.

**Cause:** the host VPN's firewall/killswitch disrupts the WSL2 Hyper-V NAT
vSwitch's DHCP, so the distro never receives a lease. This is a layer-3 failure
(no address / no route), **not** DNS — so WSL's `dnsTunneling` / `autoProxy`
settings don't help. `networkingMode=mirrored` (which shares the host stack and
sidesteps the NAT entirely) is the clean cure but **requires Windows 11**; on
Windows 10 you're stuck with NAT mode. Validation showed that the host *does*
carry the WSL subnet out through the VPN once eth0 is addressable — only the lease
delivery is broken — so a static address + route fully restores connectivity, and
the distro then egresses through the host VPN automatically (no leak).

**Fix as applied:** an opt-in in-distro **net-repair** (`modules/Network.psm1` +
`payload/usr/local/bin/claudearium-net-repair` + its systemd unit). At boot (and
on demand via `network repair`), if `eth0` has no default route it parses the NAT
gateway from the `nameserver` line of `/etc/resolv.conf` (reliable even when the
lease failed), assigns `eth0` a **high** static address in the gateway's /20
(broadcast − offset, to dodge a late DHCP lease), and installs `default via
<gateway>`. It is a deliberate **no-op when DHCP already worked** (the no-VPN
case), so it's transparent with the VPN on or off. MTU is left at the WSL default
(a 12 MB transfer at MTU 1500 through the tunnel was healthy in testing); an
optional `network.mtu` clamp is available for tunnels that need it.

**Setup-time corollary:** `bootstrap-distro.sh` runs `apt-get` during `setup`, so
provisioning *itself* needs egress — with a host VPN up, bootstrap failed with
`Temporary failure resolving deb.debian.org` and the whole `setup` aborted before
the net-repair unit could ever be enabled. So `setup` now runs the same net-repair
script **inline and transiently right before bootstrap** (the base rootfs ships
`ip`/`awk`). No-op when DHCP works; leaves no artifact (run via the base64 path,
not deployed), so net-repair's installed state stays owned by the `network` verb.
The distro lane gets the same one-shot repair *after* setup
(`TestDistro.Repair-TestDistroConnectivity`), since the `wsl --terminate` that
applies `wsl.conf` drops the static config and the VPN re-breaks DHCP on restart.

Note this is **separate** from the in-distro WireGuard + killswitch (gotcha #12,
`Vpn.psm1`), which routes the distro through its *own* tunnel. See
[design-decisions.md #30](./design-decisions.md#30-in-distro-net-repair-for-host-vpn-no-dhcp).

---

## 27. A freshly-imported distro can boot without the WSLInterop binfmt, so a Windows `.exe` fails with `exec format error`

**Symptom:** the `vpnkit` helper distro (`wsl-vpnkit`, imported from upstream's
release tarball) starts but its tunnel never comes up. `Start-VpnKit` reports
"Tunnel did not come up" and `Get-Process wsl-gvproxy` finds nothing. The
foreground command's stderr shows the real cause:

```
level=error msg="cannot connect to host: fork/exec /app/wsl-gvproxy.exe: exec format error"
```

`cat /proc/sys/fs/binfmt_misc/WSLInterop` in that distro returns *No such file or
directory* — the interop handler simply isn't registered.

**Cause:** WSL registers the `WSLInterop` binfmt handler (which lets Linux exec a
Windows PE binary via `/init`) as part of a distro's normal boot, but a minimal
imported distro (wsl-vpnkit is Alpine-based) can come up **without** it — there's
no systemd/boot unit doing the registration, and it isn't inherited from the
primary distro. wsl-vpnkit's whole mechanism is to `fork/exec` the *Windows*
`wsl-gvproxy.exe` from inside Linux, so with no WSLInterop handler the kernel
can't recognize the PE image and returns `exec format error`. (Our *primary*
distro avoids this via `claudearium-wsl-interop.service`, installed at bootstrap;
the helper distro never got that.)

**Fix as applied:** `VpnKit.Register-VpnKitInterop` registers the handler
(idempotent) in the helper distro immediately before `Start-VpnKit` launches the
tunnel — `test -e …/WSLInterop || echo ":WSLInterop:M::MZ::/init:PF" >
…/register` (mounting `binfmt_misc` first if needed). It runs on **every** start,
not just at install, because `binfmt_misc` registrations don't survive a `wsl
--terminate`. The command is issued via `sh -c` (busybox — the helper distro has
no bash, so `Invoke-InDistro`'s `bash -lc` can't be used) and is argv-safe, so it
survives the pwsh→wsl hop. Regression-guarded by a pure test asserting
`Start-VpnKit` calls `Register-VpnKitInterop` before spawning the process.

---

## 28. wsl-vpnkit's tap is visible in every distro, but only its own default route uses it

**Symptom:** with the `vpnkit` tunnel up and healthy (its own checks pass, host
`wsl-gvproxy` running), a *different* distro — e.g. a freshly-imported
`claudearium` during `setup` — still can't reach the internet: `apt` times out,
`ping 1.1.1.1` is 100% loss. Inside that distro `ip addr` shows a `wsltap`
interface (`192.168.127.2`) — wsl-vpnkit's tap — yet `ip route` shows
`default via 172.22.208.1 dev eth0` (the WSL NAT gateway), and routing the default
`via 192.168.127.1 dev wsltap` by hand instantly restores egress.

**Cause:** WSL 2 distros share one network namespace, so wsl-vpnkit's `wsltap`
appears in all of them — but each distro's **default route** is set independently
by its own DHCP (and, here, by claudearium's inline net-repair), which points at
the NAT gateway that the kill-switch host VPN black-holes. wsl-vpnkit only rewrites
the default route in the distro it runs *in*; it does not (and can't portably)
re-point every other distro's default route. So the tap is present but unused.

**Fix as applied:** `net-repair` (gotcha #26, `payload/usr/local/bin/claudearium-net-repair`)
now checks for `wsltap` **first** — before its "no-op when DHCP worked" early-exit
— and, when present, does `ip route replace default via 192.168.127.1 dev wsltap`
and exits. It must precede the early-exit because a DHCP-supplied (broken) NAT
default already exists and must be *overridden*, not left in place. `setup` runs
net-repair inline before bootstrap, so the fresh distro egresses through the tap;
with `network.enabled` the boot-time unit re-applies it every start. Tap/gateway
are overridable via `CLAUDEARIUM_VPNKIT_TAP` / `CLAUDEARIUM_VPNKIT_GW`. See
[design-decisions.md #30](./design-decisions.md#30-in-distro-net-repair-for-host-vpn-no-dhcp)
and [#33](./design-decisions.md#33-vpnkit--a-host-side-userspace-tunnel-for-kill-switch-host-vpns).

---

## 29. `wsl.exe -d <distro> ...` wakes a *stopped* distro — read-only status/list verbs must gate on Running

**Symptom:** opening the central dashboard, or running a read-only verb like
`vpn status`, `network status`, `vpnkit status`, `vpn audit`, `tools` /
`tools list`, or `host-tools` / `host-tools list`, hangs for many seconds (a cold
distro boot measured at **~21s** on one host) before printing — and silently
*restarts* a distro the user had just stopped.

**Cause:** every one of those verbs shells into the distro (`wsl -d <distro> -- …`
via `Invoke-InDistro`, e.g. `Test-KillswitchActive`, `Test-ToolInstalled`,
`Get-HostToolsActualFromDistro`, `Get-NetworkStatus`) to report live in-distro
state. Any `wsl -d` command **boots the distro if it's stopped** — WSL has no
"run only if already running" mode — so a read-only status query pays a full cold
boot and leaves the distro running afterward. Guarding on `Test-DistroExists`
(true for both `Running` and `Stopped`) does **not** prevent this; only a
`Running`-state check does. `Get-DistroState` / `Get-WslDistros` themselves are
host-only (`wsl.exe --list --verbose`) and safe — they never wake a distro.

**Fix as applied:** read-only status/list paths resolve `Get-DistroState` once and
skip the in-distro probes unless the state is `Running`, printing a concise
"distro stopped" line instead (mirrors the values that would be reported anyway —
an in-distro service is inactive when the distro is down). Applied to the central
dashboard (VPN/scratch/tool-badge), `Invoke-VpnStatus`, `Invoke-VpnAudit`,
`Invoke-NetworkStatus`, `Invoke-VpnKitStatus`, and the shared row builders
`Get-ToolRows` / `Get-HostToolRows` (which also dropped a redundant per-row
`wsl --list`). Actions that legitimately need the distro (`vpn enable`, `tools
install`/`tools update`, `login`, sessions) still wake it — that's expected;
`Get-ToolRows -ForceProbe` is the opt-out the update verb uses to probe real
state even when stopped. A `Gotchas.Tests.ps1` static guard asserts each status
verb's `Running` gate precedes its in-distro probe.
