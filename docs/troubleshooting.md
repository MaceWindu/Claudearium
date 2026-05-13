# Troubleshooting

Symptom-driven. If your problem isn't here and looks like it's at the
pwsh ↔ WSL2 boundary, also check [wsl2-gotchas.md](./wsl2-gotchas.md).

## Running diagnostics

First stop for any "something's wrong":

```powershell
.\claudearium.cmd diagnostics
```

(or `d` from the central dashboard). This runs the shipped read-only diagnostic lane and prints a one-liner pointing at the deeper lanes for cases where the diagnostic output doesn't reveal anything.

Before filing a bug report, grab a full snapshot:

```powershell
# CLI form — writes tests/results/diag-YYYYMMDD-HHmmss.txt against the
# real distro and exits. Attach this file to bug reports.
.\test-claudearium.ps1 -Snapshot

# Print probes to stdout without writing a file:
.\test-claudearium.ps1 -Diag

# Interactive form — pick target (real vs ephemeral test distro) and
# choose between all probes / snapshot file / single area.
.\test-claudearium.ps1
# then 'd' from the dashboard.
```

The snapshot file aggregates WSL state, profile validity, per-block
drift, VPN/killswitch state, the installed-tool inventory, and the
latest test-runner output. Read-only against your real distro. The
file is scrubbed for common identifiers (paths, username, hostname)
before being written, but the scrubber is not a general secret
redactor — skim it for tokens / API keys / private URLs that may
have leaked through probe output or manual-test notes before
attaching it to a bug report. See [testing.md](./testing.md) for the
full diagnostic surface.

**`...is not digitally signed. You cannot run this script on the current system.`** — Mark-of-the-Web on files extracted from a downloaded zip vs. PowerShell's default `RemoteSigned` execution policy. Run the install via the wrapper: `.\claudearium.cmd` (or `.\open-claudearium.cmd`) instead of the `.ps1`. The wrapper invokes `pwsh -ExecutionPolicy Bypass` and the script then runs `Unblock-File` over the whole install tree, so subsequent direct `.ps1` invocations work too.

**`tar.exe not found on PATH`** — Windows 10 1809+ ships it. Confirm with `where tar`. If missing, install Git for Windows (provides bsdtar) or pre-decompress and pass `-RootfsPath plain.tar`.

**`wsl --import failed`** — usually one of: distro name already exists (pick another or `-Force`), install path is on a network drive (use a local path), Hyper-V/WSL2 not enabled. Run `wsl --version` to verify.

**`Could not resolve latest rootfs timestamp`** — `images.linuxcontainers.org` listing changed format or is unreachable. Workaround: download a rootfs manually and pass `-RootfsPath`.

**Default user is `root` after setup** — bootstrap didn't run or `wsl.conf` wasn't applied. Run `wsl -t <distro>` to terminate, then `wsl -d <distro>` again. If the issue persists, check `cat /etc/wsl.conf` inside the distro.

**Multi-line bash scripts produce empty output for `$VAR` references** — known WSL pipe quirk: `wsl.exe -d <distro> -- bash -lc <script>` pre-expands `$VAR` references in argv to empty before bash sees them. The tool transports anything multi-line through base64 (`Invoke-InDistroScript`) to bypass this. If you write your own scripts that talk to the distro, use the same pattern, or escape `$` very carefully.

**`wsl: Failed to start the systemd user session for ...`** — harmless. WSL2 + systemd needs `loginctl enable-linger` for the systemd-logind / dbus chain to come up, but that itself requires logind running (chicken-and-egg). The tool filters this warning out of all `Invoke-InDistro` output; if you see it from a direct `wsl.exe` call, ignore it. Functionality is unaffected.

**`Exec format error` running a Windows .exe wrapper** — the WSL `.exe` binfmt isn't registered. The host-tools subsystem installs a systemd unit (`claudearium-wsl-interop.service`) to fix this at every boot. Force it now: `wsl -d <distro> -u root -- bash -c 'echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'`.

**`nft: Interface does not exist`** — the older `iif wg0` form requires the interface to exist at rule-load time. The tool's ruleset uses `iifname "wg0"` (string match, late-resolved) instead. If you've manually edited `/etc/nftables.conf`, prefer `iifname`.

**`apt-get install /tmp/foo.deb` fails finding ldconfig** — sudo with `!secure_path` inherits the `claude` user's login PATH, which lacks `/sbin`. The tool's `dpkg`-using install scripts (pwsh handler) prepend `/usr/local/sbin:/usr/sbin:/sbin:$PATH` before calling dpkg. Do the same in your own scripts.
