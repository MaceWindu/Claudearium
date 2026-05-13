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
3. `.tar.xz` — try `7z.exe` (most dev machines have 7-Zip), then `xz.exe`,
   then `python -c "import lzma..."`, then error informatively.

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
under `C:\Users\d.lukashenko\AppData\Local\claudearium\test-[bracket]\`.
The parent dir didn't exist, so `Write-Profile` tried to `mkdir` it — but
the operation reported the path as missing even though the create call had
just run.

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
| `awk -v` matches nothing | [#13](#13-awk--v-varval-with-literal-strings-flaky-through-pwsh--wsl) |
| `Could not resolve latest rootfs timestamp` | [#17](#17-imageslinuxcontainersorg-url-encodes--as-3a) |
| `wsl --import` fails on .tar.xz | [#11](#11-wsl---import-wants-an-uncompressed-tar-or-needs-decompression-help) |
| `host.internal` resets to nothing on reboot | [#6](#6-wsls-network-generatehosts--true-overwrites-etchosts-at-boot) |
| `setup -Name foo` wipes the wrong distro | [#18](#18-psboundparameters-inside-a-function-is-the-functions-bound-params-not-the-scripts) |
| `Could not find a part of the path` from `New-Item` on a `[bracket]` dir | [#19](#19-new-item--itemtype-directory--path-dir-interprets-wildcards-in-the-directory-name) |
