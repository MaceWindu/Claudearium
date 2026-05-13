# acli (host-attached Windows binary, Atlassian CLI)

`acli` runs as a Windows `.exe` through a WSL wrapper. `argv` passes through
unchanged, so file-path arguments are not translated — Windows sees raw WSL
paths as literal strings.

## Mitigations

- **`wslpath -w` for any path argument:**
  `acli jira issue create -f "$(wslpath -w issue-body.md)"`
- **Inline body via `-b` (when supported)** to avoid file paths entirely.
- The current working directory **is** auto-translated by WSL interop, so
  acli config + state files (`~/.atlassian/`) are read from the Windows side
  (`%USERPROFILE%\.atlassian\`) — not the WSL `claude` home.

## Flags / commands that take paths

| Command / flag | Notes |
|---|---|
| `-f <file>` (issue / comment body) | Translate with `wslpath -w`. |
| Attachment upload commands | Translate the file path. |
| `--config-file <path>` (if used) | Translate. |

## What works as-is

- `acli config` / auth commands — config is stored in the Windows user
  profile (`%USERPROFILE%\.atlassian\`), so token setup done on the host
  is reused automatically.
- Environment variables (`ATLASSIAN_*`).
- Non-path arguments (issue keys, JQL, project IDs).
