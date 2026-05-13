# seqcli (host-attached Windows binary, Seq CLI)

`seqcli` runs as a Windows `.exe` through a WSL wrapper. `argv` passes through
unchanged, so file-path arguments are not translated — Windows sees raw WSL
paths as literal strings. seqcli is unusually path-heavy (ingest, templates).

## Mitigations

- **`wslpath -w` for every `-i` / `-o` path:**
  ```bash
  seqcli ingest -i "$(wslpath -w ./logs/app.clef)"
  seqcli template export -o "$(wslpath -w ./templates)"
  ```
- **Pipe content via stdin** for ad-hoc ingests (when the command supports it):
  `cat events.clef | seqcli ingest`
- The current working directory **is** auto-translated by WSL interop, so
  configuration in `%USERPROFILE%\AppData\Roaming\Seq\` (set via
  `seqcli config -k …` on Windows) is reused — no WSL re-setup needed.

## Flags / commands that take paths

| Command / flag | Notes |
|---|---|
| `seqcli ingest -i <file>` | Log file ingest — translate. |
| `seqcli template import -i <dir>` | Source dir — translate. |
| `seqcli template export -o <dir>` | Destination — translate. |
| `--output <file>` (any subcommand) | Translate. |

## What works as-is

- `seqcli config` — stores server URL + API key on the Windows side, so the
  host-side setup is reused.
- Environment variables.
- Non-path arguments (queries, signal IDs, time ranges).
