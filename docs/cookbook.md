# Cookbook

End-to-end recipes for common setups. For the per-verb reference see
[usage.md](./usage.md); for symptoms and fixes see
[troubleshooting.md](./troubleshooting.md).

## End-to-end setup

```powershell
# 1. Create the distro.
.\claudearium.ps1 setup

# 2. Wire your host SSH key so private-repo clones work (read-only mount).
.\claudearium.ps1 mount add "$env:USERPROFILE\.ssh" `
    -Guest /home/claude/.ssh -Mode ro -MountOptions 'umask=077' -NonInteractive

# 3. Install the toolchain.
.\claudearium.ps1 tools install claudeCode  # also pulls node
.\claudearium.ps1 tools install glab
.\claudearium.ps1 tools install acli
.\claudearium.ps1 tools install seqcli      # also pulls dotnet 10
.\claudearium.ps1 tools install pwsh

# 4. Tell Claude Code how to behave.
.\claudearium.ps1 claude-settings reconfigure   # walks the wizard

# 5. Set up the project + a session.
.\claudearium.ps1 project add -HostCheckout C:\src        # auto-detects remote
.\claudearium.ps1 session new default -Project acme -Branch master

# 6. Sign in to the CLIs.
.\claudearium.ps1 login claude
.\claudearium.ps1 login glab
.\claudearium.ps1 login acli-jira         # CLI-token auth for Jira
.\claudearium.ps1 login acli-confluence   # ... and Confluence (same acli install)

# 7. Open a Claude Code session.
.\open-claudearium.ps1                # interactive dashboard
```

## Authentication via host SSH keys

The easiest fix for the no-SSH-keys-in-sandbox problem is mounting your host's `~/.ssh` directly:

```powershell
.\claudearium.ps1 mount add "$env:USERPROFILE\.ssh" `
  -Guest /home/claude/.ssh `
  -Mode ro `
  -MountOptions 'umask=077'
```

SSH client refuses keys with permissions wider than 0600; `umask=077` here gives the mount group/other no access. After this, `git clone git@gitlab.example.com:...` works from inside the sandbox using your host key.

## VPN with host services still reachable

```powershell
# Edit your profile (or create one via `profile edit`):
#   "vpn": { "wgConfigPath": "C:\\Users\\you\\wireguard\\wg0.conf", "killswitch": true }

.\claudearium.ps1 vpn enable
.\claudearium.ps1 vpn status      # tunnel up, killswitch armed, host.internal reachable
```

From inside the sandbox, `curl http://host.internal:5341` still hits your host-side Seq even with the killswitch on.

Validate from inside: `curl https://api.ipify.org` should return your VPN endpoint's IP, and `curl http://host.internal:<port>` should still reach any host-side service.

## Split-tunnel: route everything through WG except your LAN

By default `vpn enable` respects the routes in your `wg0.conf`. If you want
the sandbox to tunnel all of its egress through WireGuard while still
reaching machines on your physical LAN (printers, NAS, router admin, any
service on the same `192.168.x.x` / `10.x.x.x` subnet your Windows host is
attached to), opt into `all-except-lan` routing:

```powershell
.\claudearium.ps1 vpn enable   # the first run prompts; pick "route all to WG except local network"
.\claudearium.ps1 vpn status
```

The first interactive run auto-detects your host's primary IPv4 subnet from
the lowest-metric default route and asks you to confirm. The choice
(`vpn.routingMode` and `vpn.lanCidr`) is saved back to the profile so
subsequent `vpn enable` / `reconcile` runs are silent.

Caveat: if a host-side VPN (Cisco AnyConnect, GlobalProtect, etc.) is
already routing your default route, the detection will pick *that*
adapter's subnet instead of your physical LAN. Decline the suggestion and
type the right CIDR manually, or set `vpn.lanCidr` in the profile up
front. To set both ahead of time:

```jsonc
"vpn": {
  "wgConfigPath": "C:\\Users\\you\\wireguard\\wg0.conf",
  "killswitch":   true,
  "routingMode":  "all-except-lan",
  "lanCidr":      "192.168.1.0/24"
}
```

This mode is IPv4-only — IPv6 routes in the source config are dropped
because the inversion would need to enumerate `::/0` slivers. Stay on
`routingMode = from-config` if you need IPv6.

## Wire Claudelk into Claude Code's hooks

```powershell
.\claudearium.ps1 host-tools add "C:\Tools\Claudelk\claudelk.exe" `
    -GuestCommand sb-claudelk -SmokeTest scan -NonInteractive

.\claudearium.ps1 hooks test       # confirms sb-claudelk responds

# Edit profile.claudeSettings.claudelk = true (or via wizard):
.\claudearium.ps1 claude-settings reconfigure
.\claudearium.ps1 claude-settings apply
```

The LED strip will now flash on `Stop` / `Notification` events from any Claude Code session inside the sandbox.

From inside the sandbox after the wrapper is installed:

```bash
sb-claudelk scan
sb-claudelk color "#ff8800"
```

## Use my Windows `gh` from inside the sandbox

Skip the in-WSL `gh auth login` browser-callback dance: attach the already-authenticated Windows `gh.exe` as a drop-in `gh` wrapper.

```powershell
# Detect what's available + offer attach for each:
.\claudearium.ps1 host-tools scan

# Or attach a single tool by name:
.\claudearium.ps1 tools attach gh
```

The wrapper lands at `/usr/local/bin/gh` (drop-in name, not `sb-gh`). `Test-Profile` refuses the profile if `tools.gh.enabled=true` is also set — pick one. Same recipe applies to `glab`, `acli`, `seqcli`.

Inside the sandbox:

```bash
gh auth status     # uses the host's auth — no re-login required
gh pr view 123
```

**Path arguments need translation** because the `.exe` runs on Windows and can't interpret WSL paths:

```bash
# stdin is the cleanest path for body files:
cat body.md | gh pr create -F -

# Or convert explicitly with wslpath -w:
gh pr create -F "$(wslpath -w body.md)"
gh release upload v1.0 "$(wslpath -w ./dist/app.zip)"

# Drvfs paths round-trip cleanly too:
gh repo clone foo "$(wslpath -w /mnt/c/work/foo)"
```

The cwd is auto-translated by WSL interop, so `gh pr view` from a `cd`-ed repo just works.

**Claude sees the gotcha automatically.** If you have `profile.claudeFile` set (caveman-lite / host-copy / custom-path), the attach also writes `~/.claude/host-tools/gh.md` with the full recipe and appends a one-line caveat block to `~/.claude/CLAUDE.md`. So Claude in WSL knows from the first session: "argv paths need `wslpath -w`; see the per-tool file for details."

## Stay current with the latest release

```powershell
.\claudearium.cmd update              # is a newer release out?
.\claudearium.cmd update apply        # download, swap, exit
.\claudearium.cmd                     # re-run; dashboard banner is gone
```

`update apply` backs up the current install to `%TEMP%\claudearium-backup-vX.Y.Z-<timestamp>.zip` first and preserves any files you added to the install dir (they're not in the release manifest, so the diff leaves them alone). It refuses in a git checkout — use `git pull` there instead.

## Run diagnostics when something's off

```powershell
.\claudearium.cmd diagnostics
```

Runs the shipped read-only diagnostic lane (`tests/diagnostic/`). The dashboard's `d` shortcut does the same thing. For pure or distro Pester tests, clone the repo — those lanes aren't in the release zip.
