# gh (host-attached Windows binary)

`gh` runs as a Windows `.exe` through a WSL wrapper. `argv` passes through
unchanged, so file-path arguments are not translated — Windows sees raw WSL
paths like `/home/claude/proj/body.md` as literal strings.

## Mitigations

- **stdin (cleanest, no translation needed):** `cat body.md | gh pr create -F -`
- **`wslpath -w` (universal):** `gh pr create -F "$(wslpath -w body.md)"`
- The current working directory **is** auto-translated by WSL interop, so
  `gh pr view 42` from inside a `cd`-ed repo works without flags.

## Flags / commands that take paths

| Command / flag | Notes |
|---|---|
| `-F` / `--body-file <file>` | PR / issue / release body. Prefer `-F -` (stdin). |
| `gh repo clone <repo> <dir>` | `<dir>` is a destination — translate with `wslpath -w`. |
| `gh release create <tag> <files...>` | Asset paths — translate each. |
| `gh release upload <tag> <files...>` | Same. |
| `gh gist create <files...>` | Gist file paths — translate. |
| `gh extension install <path>` | Local extension dir — translate. |
| `gh attestation verify <artifact>` | Artifact path — translate. |

## What works as-is

- `gh auth status` / `gh auth login` / `gh auth logout` — uses the Windows
  credential store, so the host login is reused.
- stdin redirection (`-F -`, `--with-token`, etc.)
- environment variables (`GH_TOKEN`, `GITHUB_TOKEN`, …)
- cwd-based repo detection (`gh pr view`, `gh status`)
- non-path arguments (refs, URLs, numbers, flags)
