# pwsh (host-attached Windows PowerShell)

`pwsh` runs as a Windows `.exe` through a per-project wrapper at
`/home/claude/host-projects/<project>/bin/pwsh`. `argv` passes through
unchanged, so file-path arguments are not translated — Windows sees raw
WSL paths like `/host/foo/bar.ps1` as literal strings.

The bin dir is only on PATH for sessions of the hostProject that declared
`pwsh` in its `hostShadows`. Other distroProject sessions running in
parallel resolve `pwsh` to the apt-installed copy under `/usr/local/bin`
(if any), so behavior never crosses between project types.

## Mitigations

- The current working directory **is** auto-translated by WSL interop,
  so a relative path Just Works:
  `pwsh -File ./test-claudearium.ps1 -Auto -Only pure -CI`
- **`wslpath -w` (universal):** translate any absolute Linux path before
  handing it to pwsh:
  `pwsh -File "$(wslpath -w /host/Claudearium/dev/some.ps1)"`
- **stdin via `-Command -` or piped input:** for one-off snippets, pipe
  the script source rather than passing a path:
  `cat snippet.ps1 | pwsh -Command -`

## Flags / args that take paths

| Form | Notes |
|---|---|
| `pwsh -File <path>` | Translate absolute paths with `wslpath -w`; relative paths work as-is from a cwd inside the mount. |
| `pwsh -Command "& '<path>' ..."` | Same as above. |
| `Import-Module <path>` (inside the script) | Use `Join-Path` from the script's own `$PSScriptRoot` rather than passing a fixed WSL path. |
| `[IO.File]::ReadAllText('<path>')` inside the script | Always pass a Windows path; the script is running under Windows. |

## What works as-is

- `pwsh -c '$PSVersionTable'` — prints the host's PowerShell version.
- Environment variables set in the bash session before invoking pwsh
  propagate normally through WSL interop.
- Pipeline of stdin into pwsh (`echo hi | pwsh -Command "$input.ToUpper()"`)
- Profile execution from the user's host profile (`$HOME` resolves to
  the Windows user home, not the distro's `/home/claude`).

## Line endings

When editing `.ps1` files from a Linux mount, ensure the repo's
`.gitattributes` enforces CRLF for `*.ps1` (PowerShell itself accepts
LF, but downstream tools that ship .ps1 files to Windows users expect
CRLF). Claudearium itself relies on `.gitattributes` for this — the
shadow wrapper does not normalize line endings.
