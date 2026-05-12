# Extending the sandbox

How to add common kinds of feature. Read [architecture.md](./architecture.md)
first for the module map and dataflow. Read
[wsl2-gotchas.md](./wsl2-gotchas.md) before writing any code that crosses the
pwsh ↔ WSL boundary.

## Idioms you'll keep reaching for

### Running bash in the distro

```powershell
# Short, single-line, no shell variables:
Invoke-InDistro -Name $distro -User claude -Command 'command -v gh >/dev/null 2>&1'

# Anything multi-line / using $VAR / using $(cmd):
$script = @'
set -e
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCHNAME=amd64 ;;
    aarch64) ARCHNAME=arm64 ;;
esac
curl -fsSL -o "/tmp/foo.tar.gz" "https://example.com/foo-${ARCHNAME}.tar.gz"
'@
Invoke-InDistroScript -Name $distro -User claude -Script $script
```

`Invoke-InDistroScript` base64-transports the body so `$VAR` references survive
the pwsh → wsl argv hop. See [wsl2-gotchas.md#1](./wsl2-gotchas.md#1-wslexe-argv-mangles-var-and-strips-backslashes).

### Capturing output

```powershell
$r = Invoke-InDistro -Name $distro -User claude -Command 'echo hi' -CaptureOutput -AllowFail
# $r.ExitCode   = 0
# $r.Output     = @('hi')   # already filtered for systemd noise
```

`-AllowFail` suppresses the throw-on-nonzero. Use it for probes (e.g. `command
-v X`, file-exists tests) where non-zero is a legitimate answer, not an error.

### Quoting values for bash

```powershell
$q = ConvertTo-BashQuoted "value with 'apostrophes'"
# $q = "'value with '\''apostrophes'\''"   (POSIX single-quote escape)

Invoke-InDistro -Name $distro -User claude -Command "echo $q"
```

Use whenever you splice a value into a bash command. Even paths that "shouldn't
ever have weird chars" eventually grow weird chars — quote unconditionally.

### Writing a file into the distro

For files that don't change at runtime (config, scripts, systemd units): put it
under `payload/` and copy via `Send-FileToDistro` (entry-point) or
`Send-RootFileToDistro` (Vpn). The destination ends up base64-encoded
in transit, so any byte content goes through intact (no CRLF surprises).

For content composed at runtime: build the string in pwsh, then:

```powershell
$normalized = ($content -replace "`r`n", "`n")    # parens! See gotcha #14.
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
$cmd = "set -e; mkdir -p '$parentDir'; " +
       "printf '%s' '$b64' | base64 -d > '$destPath'; " +
       "chmod $mode '$destPath'"
Invoke-InDistro -Name $distro -User root -Command $cmd
```

### Maintaining a recents list

```powershell
$state = Read-State -DistroName $distro
Add-Recent -State $state -Key 'projectNames' -Value $projName     # dedup, trim to 5
Add-Recent -State $state -Key 'remotes'      -Value $remote
Write-State -DistroName $distro -State $state
```

Any future interactive picker (per the design preference for interactive
dashboards) reads from `$state.recents.<Key>` to pre-suggest. Don't add to
recents for transient lookups, only when the user made a deliberate choice
(added a project, mounted a path, installed a tool).

## How to add a new tool to the tools catalog

`Tools.psm1` has an `[ordered]@{}` hashtable `$Script:ToolCatalog` where
each tool is a scriptblock-bearing entry. Add yours:

```powershell
$Script:ToolCatalog = [ordered]@{
    # ... existing entries
    'mytool' = @{
        Description = 'One-line description for the dashboard.'
        DependsOn   = @('node')   # array of other catalog tool names, or @()
        TestInstalled = {
            param($Distro)
            return (Test-CommandInDistro -DistroName $Distro -Command 'mytool')
        }
        GetVersion = {
            param($Distro)
            return (Get-ToolFirstLineVersion -DistroName $Distro -Command 'mytool --version 2>/dev/null')
        }
        Install = {
            param($Distro, $Version)
            $script = @'
set -e
# install commands using $-vars freely
'@
            Invoke-InDistroScript -Name $Distro -User 'claude' -Script $script
        }
    }
}
```

Then add the name to `Profile.KnownToolNames` so it doesn't trip the
"unknown tool" warning. The wizard, reconcile, and `tools` verb will pick it up
automatically.

**Cookbook for the Install scriptblock:**

| Install style | Example tool | Pattern |
|---|---|---|
| apt repo + key | `gh` | `sudo apt-get install ca-certificates curl gnupg`; add key + sources.list.d entry; `sudo apt-get install -y mytool` |
| Direct .deb | `glab` | `curl -fsSL -o /tmp/foo.deb <url>; sudo apt-get install -y /tmp/foo.deb; rm /tmp/foo.deb` |
| Tarball single binary | `acli` | `curl -fsSL <url> \| sudo bash` (vendor's install.sh), or extract + `sudo install -m 0755` |
| Per-user install | `node`, `dotnet` | Install to `$HOME/.something/`, append PATH export to `~/.profile`, source for current shell |
| .NET global tool | `seqcli` | `dotnet tool install -g <name>` on fresh install, `dotnet tool update -g <name>` if already present |
| Microsoft apt | `pwsh` | Download `packages-microsoft-prod.deb`, `sudo dpkg -i ...` (remember PATH prepend for sbin — gotcha #8) |

## How to add a new host-tool (wraps a Windows .exe)

Two paths:

**Profile-driven (recommended):** the user adds to `profile.hostTools[]`:

```jsonc
{
  "name":         "mytool",
  "windowsExe":   "C:\\Tools\\MyTool\\mytool.exe",
  "guestCommand": "sb-mytool",
  "smokeTest":    "--version"
}
```

`reconcile` picks it up; `Install-HostToolWrapper` generates `/usr/local/bin/sb-
mytool` and ensures the WSLInterop binfmt is registered.

**CLI:** the user runs `host-tools add C:\Tools\MyTool\mytool.exe -GuestCommand
sb-mytool -SmokeTest --version`.

If you need a smarter wrapper (e.g. argument translation, working-directory
manipulation, env passthrough), edit `ConvertTo-WrapperContent` in
`HostTools.psm1`. The marker line `# claudearium-hosttool: <name>`
must stay on line 2 — `Get-HostToolsActualFromDistro` reads it via `sed -n
'2,3p'` to enumerate what we own.

## How to add a new profile block

Three places to touch:

**1. Validation in `Profile.Test-Profile`:**

```powershell
if ($Spec.ContainsKey('myblock') -and $null -ne $Spec.myblock) {
    if (-not ($Spec.myblock -is [hashtable])) {
        $errors.Add('myblock must be an object.')
    }
    else {
        # ... field-level validation
    }
}
```

Add the key to `$Script:KnownTopLevelKeys` so it doesn't trip the
unknown-key warning.

**2. Diff function in `Profile.psm1`:**

```powershell
function Get-MyBlockDiff {
    [CmdletBinding()]
    param(
        [AllowNull()]$Desired,
        [AllowNull()]$Actual
    )
    # Build a $changes List of @{ Path; Action ('add'|'remove'|'modify'); Severity ('safe'|'destructive'); From; To; Note }
    # Return @{ Changes; HasDestructive; CanApplyInPlace }
}
```

Export it. The reconciler will use it.

**3. Apply helper in `claudearium.ps1`:**

```powershell
function Invoke-MyBlockApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Diff,
        [AllowNull()]$DesiredItems
    )
    foreach ($c in $Diff.Changes) {
        switch ($c.Action) {
            'add'    { ... install ... }
            'remove' { ... remove ... }
            'modify' { ... }
        }
    }
}
```

Wire into `Invoke-Reconcile`:

```powershell
# in the desired/actual gather block:
$actualMyBlock = @() ; if ((Get-DistroState ... ) -ne 'Missing') { $actualMyBlock = Get-MyBlockActualFromDistro ... }
$desiredMyBlock = @() ; if ($spec.ContainsKey('myblock')) { $desiredMyBlock = @($spec.myblock) }
$myBlockDiff = Get-MyBlockDiff -Desired $desiredMyBlock -Actual $actualMyBlock

# add to $allChanges
$allChanges = @($distroDiff.Changes) + ... + @($myBlockDiff.Changes)

# in the destructive / non-destructive branches:
if ($myBlockDiff.Changes.Count -gt 0) {
    Invoke-MyBlockApply -DistroName $targetName -State $state -Diff $myBlockDiff -DesiredItems $desiredMyBlock
}
```

**Don't forget:** update `templates/claudearium.profile.schema.json` and
`templates/claudearium.profile.example.json` with the new block's shape.

## How to add a new verb

In `claudearium.ps1`:

```powershell
function Invoke-Myverb {
    if (-not $SubVerb) { Invoke-MyverbDashboard; return }  # bare = interactive
    switch ($SubVerb.ToLowerInvariant()) {
        'foo' { Invoke-MyverbFoo }
        'bar' { Invoke-MyverbBar }
        default {
            Write-Host "Unknown myverb subverb: $SubVerb" -ForegroundColor Red
            exit 64
        }
    }
}

function Invoke-MyverbFoo { ... }
function Invoke-MyverbBar { ... }
function Invoke-MyverbDashboard {
    while ($true) {
        Write-Host ''
        Write-Host '=== Claudearium: myverb ===' -ForegroundColor Cyan
        # print state table
        Write-Host ''
        Write-Host '  +  add'
        Write-Host '  d <n>  remove'
        Write-Host '  q  quit'
        $a = (Read-Host '  >').Trim()
        if ($a -in @('q', '')) { return }
        # dispatch...
    }
}
```

Add to the final switch dispatch:

```powershell
switch ($Verb.ToLowerInvariant()) {
    ...
    'myverb' { Invoke-Myverb }
    ...
}
```

Update:
- `Show-Help`'s verb listing
- `Invoke-CentralDashboard`'s menu (give it a single-letter shortcut)
- README's verb table

If `myverb` mutates persistent state, also add it to the appropriate diff
function and reconcile path (see "add a profile block" above).

## How to add a new module

```powershell
# modules/Sandbox.Myfeature.psm1
# Short module-header explaining role and public contract.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Direct deps only — never -Force here (see wsl2-gotchas #10).
Import-Module (Join-Path $PSScriptRoot 'Wsl.psm1')
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1')

function Get-MyFeatureActualFromDistro { ... }   # actual state from distro
function Set-MyFeatureInDistro { ... }            # apply desired state
function Add-MyFeatureToProfile { ... }           # mutate profile (-Raw to preserve %ENV%)
function Remove-MyFeatureFromProfile { ... }

Export-ModuleMember -Function `
    Get-MyFeatureActualFromDistro, `
    Set-MyFeatureInDistro, `
    Add-MyFeatureToProfile, `
    Remove-MyFeatureFromProfile
```

Import from `claudearium.ps1`:

```powershell
Import-Module (Join-Path $Script:ModulesDir 'Sandbox.Myfeature.psm1') -Force
```

The entry-point uses `-Force` (single source of truth for module versions);
child modules don't (see wsl2-gotchas #10).

## How to add a payload file

Drop it under `payload/<distro-path>`. E.g. a systemd
unit goes at `payload/etc/systemd/system/myunit.service`.

In your module, push it:

```powershell
$content = Get-Content -LiteralPath (Join-Path $Script:PayloadRoot 'etc/systemd/system/myunit.service') -Raw
Send-RootFileToDistro -DistroName $distro -Content $content `
    -DestPath '/etc/systemd/system/myunit.service' -Mode '0644'
```

(`Send-RootFileToDistro` is exported from `Vpn.psm1`; if you don't
want to depend on Vpn, copy the 6-line implementation.)

For systemd units, follow up with `systemctl daemon-reload && systemctl enable
<unit>` — but use plain `enable` not `enable --now` because the latter hangs
intermittently in WSL2 (see wsl2-gotchas #4). Trigger the unit's effect
inline if you need immediate application.

## Testing conventions

There's a real test runner: `.\test-claudearium.ps1`. See
[testing.md](./testing.md) for the full surface (lanes, CI, diagnostic
mode). For *adding* tests, the rules of thumb are below.

### When you change production code

```powershell
.\test-claudearium.ps1 -ParseCheck             # cheap — 1s
.\test-claudearium.ps1 -Auto -Only pure -CI    # ~5s, no WSL2
.\test-claudearium.ps1 -Auto -Only distro -CI  # ~5min, ephemeral distro
```

CI runs parse-check + pure on every push to any branch; the distro
lane runs on PRs and on `master` (see `.github/workflows/test.yml`).

### Adding tests

Pick the right home based on what your test needs:

| Need | Dir | Kind |
|---|---|---|
| Pure pwsh logic (no WSL2 calls, no Windows side-effects beyond `%TEMP%`) | `tests/pure/<Module>.Tests.ps1` | Pester `auto`, fast |
| Exercise a verb end-to-end against a real distro | `tests/distro/<Verb>.Tests.ps1` | Pester `auto`, ephemeral distro |
| Visual / interactive check (wt colors, OAuth prompts) | `tests/manual/<Thing>.ps1` | `manual`, asks y/n, runs against ephemeral test distro |
| Read-only diagnostic probe (no mutation, ever) | `tests/diagnostic/<Area>.ps1` | `diag`, side-effect-free |
| Prevent a [wsl2-gotcha](./wsl2-gotchas.md) from coming back | `tests/pure/Gotchas.Tests.ps1` or `tests/distro/Gotchas.Tests.ps1` | static analysis or live exercise |

### How tests find each other

The manifest in `tests/lib/TestRegistry.psm1` is the single source of
truth. Every test file gets one entry with its group, kind, distro
requirement, and runtime estimate. Add your file there and it shows up in
both `-Only <group>` filtering and the dashboard's selection tree.

### Invoking `claudearium.ps1` from a distro test

Use the `Invoke-Claudearium` helper from `tests/lib/TestRunHelpers.psm1`:

```powershell
Invoke-Claudearium -DistroName $script:distro -ProfilePath $script:profilePath `
    -Args @{ Verb='project'; SubVerb='add'; Arg='demo'; Remote=$url; DefaultBranch='master' }
```

It splats a hashtable into the production script — the only splat form
that preserves named/switch parameter semantics (array splat treats
every element as positional, so `-Force` becomes a stray string the
binder rejects). Each test should also use a per-file isolated profile
via `New-IsolatedTestProfile`, never the user's real profile.

### Smoke-test promises the runner now enforces

The previously-documented "smoke-test checklist" steps are real
assertions now. When you add a feature, you don't have to remember to do
them by hand — but you DO need to make sure your new code keeps passing:

| Old smoke step | Where it lives now |
|---|---|
| Parse-check changed files | `-ParseCheck` mode (CI gate) |
| Reconcile no-op after apply | `tests/distro/Reconcile.Tests.ps1` |
| Idempotency (add/sync × 2) | `tests/distro/Mount.Tests.ps1`'s sync block |
| Cleanup path leaves no trace | `tests/distro/*` AfterAll blocks |

The user-facing [troubleshooting.md](./troubleshooting.md) captures
the symptoms a user would hit if any of these go wrong.
