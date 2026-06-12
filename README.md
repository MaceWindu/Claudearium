# Claude Code WSL2 Sandbox

A PowerShell-managed WSL2 sandbox for running [Claude Code](https://docs.claude.com/en/docs/claude-code/) in an isolated environment with optional VPN tunnelling (WireGuard + killswitch) and optional Bluetooth-LED hooks via [Claudelk](https://github.com/MaceWindu/Claudelk) running on the Windows host.

> Run `.\claudearium.ps1` (no args) for the interactive central dashboard, or any of the verbs directly.

## What this is

- A scripted way to create a **dedicated Debian 12 WSL2 distro** for Claude Code work, separate from your normal WSL distros.
- **Per-project isolation:** each project runs as its own dedicated Linux user with a `0700` home and password-required sudo, so a runaway agent in one project can't read another project's files, tokens, or work. Auth is per-project (with a `user seed` shortcut to reuse a login); toolchains are shared system-wide so every project gets them.
- **Optional:** all sandbox traffic routed through a user-supplied WireGuard tunnel, with an nftables killswitch that drops anything not going through the VPN — **except** host-subnet traffic, so local services like a host-side Seq instance remain reachable.
- **Optional:** Windows-only utilities (e.g. Claudelk for BLE LED strips) reachable from inside the sandbox via WSL's Windows-interop bridge — no `usbipd` passthrough required, no host-side listener daemon needed.
- **Optional:** already-authenticated host CLIs (`gh`, `glab`, `acli`, `seqcli`) attachable as drop-in wrappers so you keep your Windows-side browser OAuth instead of re-authenticating inside WSL.
- **Optional:** Windows-specific repos (PowerShell, .NET-on-Windows — including Claudearium itself) can run a **host half** — sessions backed by host-side `git worktree` paths with a per-session PATH that exposes host `pwsh` / `git` without disturbing parallel distro-side sessions. A project can have a distro half, a host half, or **both** at once (pick the session kind at `session new`).
- **Project-agnostic:** the same script bootstraps sandboxes for any project. Project layout, repo URL, mounts, tools, and Claude Code settings are all per-project configuration in a single declarative profile file.

## What this is *not*

- Not airgapped. Windows-interop is intentional — it's how the BLE bridge works. If you need true airgap, disable interop in `/etc/wsl.conf` (and lose Claudelk).
- Not a production deployment system.
- Not a replacement for your normal day-to-day WSL setup. It runs alongside.

## Requirements

| Requirement | Notes |
|---|---|
| Windows 10 build 1809+ or Windows 11 | bsdtar (`tar.exe`) ships in 1809+; needed to decompress the rootfs |
| WSL2 installed and enabled | `wsl --version` should report ≥ 2.0 |
| PowerShell 7+ | `pwsh` on `$PATH`; the script is pwsh-only |
| ~3 GB free disk in `%LOCALAPPDATA%\WSL\` | The default distro install path |
| Internet at first-run | To download the Debian 12 rootfs |
| **Optional:** a WireGuard `wg0.conf` | Any provider; user-supplied |
| **Optional:** `claudelk.exe` on the host | https://github.com/MaceWindu/Claudelk |

## Install

Download the latest `claudearium-vYYYY.M.N.zip` from
[Releases](https://github.com/MaceWindu/Claudearium/releases/latest), extract
anywhere, and run `claudearium.cmd` from the install directory. The first
launch unblocks the rest of the tree so future direct `.ps1` invocations also
work.

`claudearium.cmd` and `open-claudearium.cmd` wrap `pwsh -ExecutionPolicy
Bypass` so Mark-of-the-Web on downloaded zip files doesn't get in the way.

## Quick start

```powershell
.\claudearium.cmd setup
```

Default behavior:
- Downloads the latest Debian 12 rootfs from `images.linuxcontainers.org`.
- Decompresses (`tar.exe`-based) and imports as `claudearium`.
- Creates a passwordless `claude` user with NOPASSWD sudo.
- Installs base packages: `git`, `curl`, `jq`, `nftables`, `wireguard-tools`, `sudo`, `systemd`, locales.
- Marks the distro provisioned in `%LOCALAPPDATA%\claudearium\<distro>\state.json`.

Then:

```powershell
.\claudearium.cmd status
.\open-claudearium.cmd                   # launcher: drops you into a wsl shell
```

Stay current and troubleshoot:

```powershell
.\claudearium.cmd update         # check; 'update apply' to install the new release
.\claudearium.cmd diagnostics    # run the read-only diagnostic lane
```

The dashboard (run `claudearium.cmd` with no args) shows an `Update available`
banner once per week when a newer release is out, and has `u` / `d` shortcuts
for the two verbs above.

To tear everything down:

```powershell
.\claudearium.cmd nuke           # asks for confirmation
.\claudearium.cmd nuke -Force    # no confirmation
```

## Next steps

| You want to... | Read |
|---|---|
| Know what every verb does, with flags and examples | [docs/usage.md](./docs/usage.md) |
| Run multiple parallel Claude Code sessions in different repos / branches | [docs/sessions.md](./docs/sessions.md) |
| Follow an end-to-end setup recipe (host SSH keys, toolchain, first session, VPN, Claudelk) | [docs/cookbook.md](./docs/cookbook.md) |
| Diagnose a specific error message, or run the diagnostic snapshot | [docs/troubleshooting.md](./docs/troubleshooting.md) |
| Run the test suite (`.\test-claudearium.ps1`) or read what's covered | [docs/testing.md](./docs/testing.md) |
| Work *on* the tool (architecture, design decisions, WSL gotchas, extending) | [docs/](./docs/README.md) |

## License / attribution

MIT — see [LICENSE](./LICENSE). [Claudelk](https://github.com/MaceWindu/Claudelk) is © MaceWindu and the LED-strip wrappers integrate with it via [WSL Windows-interop](https://learn.microsoft.com/en-us/windows/wsl/filesystems#run-windows-tools-from-linux).
