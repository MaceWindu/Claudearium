---
name: copilot-fix
description: Drive a Copilot review loop on the current PR — request review, address every inline comment, resolve threads, commit + push, then repeat until Copilot reports zero new findings. Use when the user says "run copilot fix", "fix copilot comments", or after a push when they want the bot iteration handled autonomously.
---

# copilot-fix

Automate the Copilot review iteration loop described in `CLAUDE.md` § 8–9.
Goal: drive the PR to a state where Copilot has no remaining comments,
all review threads are resolved, and CI is green.

## When to use

The user is on a feature branch with an open PR, has just pushed, and
wants the bot iteration handled without manual prompting between rounds.
Each iteration auto-commits and auto-pushes — do not invoke if the user
wants to review fixes before they land.

## Preconditions

1. `gh auth status` shows you are logged in with `repo` scope.
2. Current branch has an open PR. Resolve it, and derive owner/repo from
   `gh repo view` so the skill works on forks and after transfers:
   ```powershell
   $pr   = gh pr view --json number,headRefName,url | ConvertFrom-Json
   $repo = gh repo view --json owner,name | ConvertFrom-Json
   $owner = $repo.owner.login
   $name  = $repo.name
   ```
   If `gh pr view` errors with "no pull requests found", stop and tell
   the user — the skill needs an existing PR to drive.
3. Working tree is clean (`git status --porcelain` empty) or the user
   has explicitly asked you to commit current changes first. Otherwise
   stop — a dirty tree mid-loop conflates Copilot fixes with unrelated
   work and pollutes the commit history.

## Loop

Repeat until **stop condition** is met. Cap at **5 iterations** — if
Copilot is still flagging on iteration 6, stop and surface the latest
comments to the user; something structural is wrong and another round
of the same playbook won't help.

### 1. Re-request Copilot review

Use `gh pr edit --add-reviewer` (GraphQL path with the bot's user-login).
The REST `requested_reviewers` endpoint silently no-ops when Copilot
already reviewed an earlier commit — see `CLAUDE.md` § 8.

```powershell
gh pr edit $pr.number --add-reviewer copilot-pull-request-reviewer
```

### 2. Wait for the review to land

Poll `gh pr view --json reviews,latestReviews` every 30s, up to ~10
minutes. A new Copilot review is one whose `submittedAt` is newer than
the previous iteration's snapshot (capture it before step 1). On the
first iteration, "new" means "any Copilot review submitted after the
latest commit's `committedAt`".

```powershell
$reviews = gh pr view $pr.number --json reviews | ConvertFrom-Json
$copilot = $reviews.reviews | Where-Object { $_.author.login -match 'copilot' } |
           Sort-Object submittedAt -Descending | Select-Object -First 1
```

If no new review appears within the window, **stop** and tell the user
that Copilot didn't respond — possible bot outage or queue backup.

#### 2a. Detect and retry Copilot's internal-error reviews

Copilot occasionally posts a review whose body indicates the bot itself
failed to analyze the PR (typical phrasings: "encountered an internal
error", "Copilot encountered an error", "couldn't review", etc., posted
as `COMMENTED` with no inline comments). When you see this, the review
is not a real verdict — retry by re-requesting Copilot.

```powershell
$body = [string]$copilot.body
$isInternalError = $body -match '(?i)(internal error|encountered an error|couldn''t review|failed to review)'
```

Retry up to **3 times** for the same commit SHA: re-run step 1
(`gh pr edit --add-reviewer copilot-pull-request-reviewer`), poll
step 2 again, check 2a again. If still erroring after 3 attempts,
**stop** and surface the error body to the user — pushing more commits
in this state would just stack errors.

Reset the retry counter when a new commit is pushed (i.e., the retry
budget is per-commit, not per-skill-invocation).

**The 2a retries do NOT consume the outer 5-iteration cap from step 4.**
Only a successful (non-error) Copilot review advances the outer counter.
A round in which Copilot returned only internal errors and we re-requested
counts as zero outer iterations. Otherwise three consecutive internal
errors could burn the whole budget without reviewing any code.

### 3. Fetch inline comments

Scope the fetch to comments belonging to **this** Copilot review
(`pull_request_review_id -eq $copilot.id`) so prior rounds' comments
don't reappear in `$open` and trigger redundant fix-or-decline cycles.

```powershell
$comments = gh api "repos/$owner/$name/pulls/$($pr.number)/comments" |
            ConvertFrom-Json
$open = $comments | Where-Object {
    $_.user.login -match 'copilot' -and
    $_.pull_request_review_id -eq $copilot.id -and
    -not $_.in_reply_to_id  # ignore replies, only top-level threads
}
```

Cross-reference with `gh pr view --json reviews,latestReviews` for the
review-level overview message — Copilot sometimes flags issues only in
the summary, not as inline comments.

### 4. Evaluate stop condition

Maintain `$declinedBodies` at the loop header (empty list at first
entry, accumulated across iterations) to track comments the user
intentionally pushed back on. Each iteration's loop ends by appending
to it the bodies of comments we declined this round.

**Stop** if any of:

- `$open` is empty AND the latest Copilot review state is `APPROVED`
  or `COMMENTED` with no actionable summary.
- Every comment in `$open` has a body that already appears in
  `$declinedBodies` — Copilot re-flagged the same line(s) we declined
  in a prior round; don't loop on the same comment twice.
- Outer iteration count reaches 5 (per section 2a, internal-error
  retry rounds do NOT advance this counter).

On stop, report: iteration count, total comments addressed, total
comments declined (with rationale), and the final review state.

### 5. Address each open comment

For every comment in `$open`, decide:

- **Fix in code** — the comment names a real bug or convention
  violation. Edit the file, citing `CLAUDE.md` / `wsl2-gotchas.md` if
  applicable. Use the local rules (recurring traps, distro-call rules,
  approved-verb rules) — Copilot is not aware of all of them and may
  suggest changes that conflict with our conventions. When that
  happens, decline (see below) rather than introduce a regression.
- **Decline with rationale** — the comment is wrong, conflicts with
  a project convention, or is a stylistic nitpick we don't follow.
  Reply on the thread:
  ```powershell
  gh api -X POST `
    "repos/$owner/$name/pulls/$($pr.number)/comments/$($c.id)/replies" `
    -f body="<short rationale, cite CLAUDE.md or docs/<file>.md#N>"
  ```

Do not silently ignore comments — every open thread gets either a code
fix or a reply.

### 6. Run tests

After fixes:

```powershell
.\test-claudearium.ps1 -ParseCheck
.\test-claudearium.ps1 -Auto -Only pure -CI
```

If a test fails, fix it before continuing — pushing a red branch wastes
the next Copilot round on noise. Run `-Only distro -CI` too if the
changes touched the distro path.

### 7. Code-reviewer subagent pass

Per `CLAUDE.md` § 6, every commit needs a code-reviewer pass.
Spawn `Agent` with `subagent_type='code-reviewer'`. Address Critical
findings before the commit; note declined Important findings in the
commit body.

### 8. Commit + push

One commit per iteration. Message format:

```
address Copilot review round <N>

<one-line summary of what changed>

<optional: declined comments with rationale>
```

```powershell
git add <paths>
git commit -m "<message>"
git push
```

### 9. Resolve threads

GitHub does not auto-resolve threads when a follow-up commit addresses
the line. Resolve every thread you fixed (skip declined ones — leave
those for the user to resolve after reading your reply).

```powershell
$threads = gh api graphql -f query=@'
query($owner:String!,$name:String!,$num:Int!) {
  repository(owner:$owner,name:$name) {
    pullRequest(number:$num) {
      reviewThreads(first:50) {
        nodes { id isResolved path line comments(first:1){nodes{body author{login}}} }
      }
    }
  }
}
'@ -f owner=$owner -f name=$name -F num=$pr.number | ConvertFrom-Json
```

For each `node` where `isResolved` is false and the comment was
authored by Copilot AND you fixed it this round:

```powershell
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=$threadId
```

Resolve mutations are independent — issue them in parallel.

### 10. Loop

Go back to step 1 with the new commit SHA as the baseline.

## Hard rules

- **Never force-push.** If a commit needs amending, create a new
  commit instead. `CLAUDE.md` Git Safety Protocol.
- **Never skip hooks** (`--no-verify`).
- **Never include local paths** (`C:\Users\<account>\…`) in commit
  messages or reply bodies. `CLAUDE.md` § 7.
- **Never merge the PR.** The user does that. `CLAUDE.md` § 11.
- **Stop at iteration 5.** Surface remaining comments rather than
  loop indefinitely.

## Final report

When the loop stops, print:

```
Copilot fix loop: <stop reason>
Iterations: <N>
Comments addressed: <count>  (commits: <sha1>, <sha2>, …)
Comments declined: <count>   (see replies on threads <id>, <id>)
Final review state: <APPROVED | COMMENTED | CHANGES_REQUESTED | none>
CI: <green | red | pending>  (run: <url>)
```
