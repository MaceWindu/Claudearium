# glab (host-attached Windows binary)

`glab` runs as a Windows `.exe` through a WSL wrapper. `argv` passes through
unchanged, so file-path arguments are not translated — Windows sees raw WSL
paths like `/home/claude/proj/body.md` as literal strings.

## Mitigations

- **stdin:** `cat body.md | glab mr create -F -`
- **`wslpath -w`:** `glab mr create -F "$(wslpath -w body.md)"`
- The current working directory **is** auto-translated by WSL interop, so
  `glab mr view` from inside a `cd`-ed repo works without flags.

## Flags / commands that take paths

| Command / flag | Notes |
|---|---|
| `-F` / `--body-file <file>` | MR / issue / release body. Prefer `-F -` (stdin). |
| `glab repo clone <repo> <dir>` | Destination — translate with `wslpath -w`. |
| `glab release upload <tag> <files...>` | Asset paths — translate each. |
| `glab snippet create -f <file>` | Snippet content — translate. |

## What works as-is

- `glab auth status` / `glab auth login` — uses the Windows config store.
- stdin redirection, environment variables (`GITLAB_TOKEN`).
- cwd-based repo detection (`glab mr view`, `glab issue list`).
- non-path arguments.
