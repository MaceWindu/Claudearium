# git (host-attached Windows Git for Windows)

`git` runs as a Windows `.exe` (Git for Windows) through a per-project
wrapper at `/home/claude/host-projects/<project>/bin/git`. The hostProject
session uses the host's `git` so the worktree's permissions and
filesystem semantics match what the user sees in Explorer. Distro git
(under `/usr/bin/git`) is unaffected and remains in use for every other
session.

## Why host git for hostProjects

- The session's working directory is `/host/<project>/<session>`, which
  is a drvfs mount of a Windows NTFS path. Linux git on drvfs has
  documented edge cases with hardlinks, case-sensitivity, and file mode
  bits; host git treats the path natively.
- `git worktree add` for the session itself is run on the host (via
  PowerShell) so the worktree metadata is consistent — same git binary
  that manages the worktree later also manages the parent checkout.
- The host's `~/.gitconfig`, credential helper, and SSH key state are
  reused. No re-`git config` dance inside the distro.

## Mitigations for path arguments

Most git invocations take refs / patterns, not paths, and those pass
through unchanged. For the cases that do take paths:

| Form | Notes |
|---|---|
| `git <cmd> -- <path>` | Relative paths from a cwd inside the mount work as-is — WSL interop auto-translates cwd. |
| `git clone <url> <dir>` | Translate `<dir>` with `wslpath -w` if you want to clone elsewhere on Windows. |
| `git -C <repo> ...` | Translate `<repo>` with `wslpath -w` for an absolute path. |
| `git apply <patch>` | Translate `<patch>` if it's an absolute Linux path; stdin (`git apply -`) is cleaner. |

## What works as-is

- All ref operations (`git log`, `git branch`, `git fetch`, `git push`,
  `git tag`, `git merge`, `git rebase`).
- `git status` / `git diff` from inside the worktree.
- Credential helpers (the host's `manager-core` / `gcm` is used).
- SSH keys in the host's `~/.ssh` (no need to mount them separately).
- `.gitconfig` aliases the user has on the host.

## What doesn't apply here

- `git fetch` populating a bare mirror — there is no bare mirror in the
  distro for a hostProject. Each session's worktree fetches against the
  parent checkout independently.
- Linux-style hooks under `.git/hooks/` — they'd be interpreted by host
  git, which expects Windows-line-endings shell scripts and a working
  `bash.exe` on PATH. If the repo ships `.sh` hooks, run them manually
  rather than via the host-git wrapper.
