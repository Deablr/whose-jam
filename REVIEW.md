# Code review — agent instructions

How an agent reviews a pull request on `Deablr/whose-jam`. Read `CLAUDE.md` and
`docs/prd.md` first; the conventions and contracts there are the standard the
code is held to.

The review runs in four phases: **gather → review (many agents) → vote → post**.
One orchestrating agent owns the PR conversation; reviewer and voter agents
never post to GitHub directly.

---

## 0. Setup

```sh
# All gh calls act as Ryxians (JaredDeanFP has no access to this repo).
export GH_TOKEN=$(gh auth token --user Ryxians)
export REPO=Deablr/whose-jam
export PR=<number>

# Mix is installed via mise; point at its home so Hex is found.
export MIX_HOME=$HOME/.local/share/mise/installs/elixir/1.20.2-otp-28/.mix
```

Review the PR's head commit, not whatever happens to be checked out:

```sh
HEAD_SHA=$(gh pr view $PR --repo $REPO --json headRefOid --jq .headRefOid)
git fetch origin pull/$PR/head
git worktree add /tmp/review-$PR $HEAD_SHA   # isolated checkout; never touch the user's tree
cd /tmp/review-$PR && mix deps.get
```

The worktree is the **only** git mutation allowed during review (it leaves the
user's branch and working tree alone). Remove it at the end with
`git worktree remove /tmp/review-$PR`. Never commit, push, rebase, or check out
in the main checkout.

---

## 1. Gather context (orchestrator)

Collect this once and hand it to every reviewer:

```sh
gh pr view $PR --repo $REPO --json title,body,author,baseRefName,headRefName,files,commits
gh pr diff $PR --repo $REPO > /tmp/review-$PR.diff

# Every review thread, with resolution state and line anchors
gh api graphql -F owner=Deablr -F repo=whose-jam -F pr=$PR -f query='
  query($owner:String!, $repo:String!, $pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          nodes { id isResolved isOutdated path line
                  comments(first:20) { nodes { author { login } body createdAt } } }
        }
        comments(first:100) { nodes { author { login } body createdAt } }
      }
    }
  }'
```

Also run the checks (step 2) here so every reviewer sees the same results.

### PR hygiene (part of the review)

- **Title:** imperative, specific, under ~70 characters; describes the change, not the ticket.
- **Description:** says *what* changed and *why*, lists user-visible behaviour changes, notes migrations/config/env changes, and has a **Testing** section saying what was actually run. Flag claims the diff doesn't support.
- **Scope:** one coherent change. Flag unrelated drive-by edits.
- **Comments:** for each existing thread, note whether it's resolved, unresolved-but-addressed by this head, or still open.

---

## 2. Lint, test, build (orchestrator, in the worktree)

Run all of these and record pass/fail with the relevant output:

| Step | Command | Fails the review if… |
| --- | --- | --- |
| Compile (lint) | `mix compile --warnings-as-errors --force` | any warning |
| Format | `mix format --check-formatted` | any unformatted file **in the diff** (pre-existing ones are noted, not blamed) |
| Unused deps | `mix deps.unlock --check-unused` | the lockfile has unused deps |
| Tests | `mix test` | any failure |
| Assets build | `mix assets.build` | Tailwind/esbuild errors |
| Release build (only if `Dockerfile`, `rel/`, `config/runtime.exs`, or `mix.exs` changed) | `docker build -t whose-jam-review .` | build fails |

Never run `mix ecto.reset` / `ecto.drop`; the dev database is shared. If a step
can't run (e.g. no Docker), say so in the review instead of skipping silently.

---

## 3. Review (parallel agents)

Spawn **one reviewer per lens**, in parallel. Each gets: the diff, the PR
metadata and threads, the check results, and the worktree path. Each reads the
**full changed files**, not just the hunks.

| Agent | Lens | Look for |
| --- | --- | --- |
| `bugs` | Correctness | Logic errors, wrong state transitions in `Game.Server`, race conditions and timer leaks (`Process.send_after` without cancel), nil/missing-key crashes, off-by-one, broken pattern-match clauses, LiveView assigns used before they're set, JS hook lifecycle mistakes. |
| `quality` | Code quality & conventions | Violations of `CLAUDE.md`: pure modules staying pure, the shared domain shapes, runtime state never persisted, no new deps, `req`/`eqrcode` only. Naming, dead code, duplicated logic, comments that don't match the code, code that doesn't read like its surroundings. |
| `simplicity` | Over-engineering | Abstractions with one caller, config nobody sets, speculative extensibility, layers that could be a function, long `cond`/`case` trees that could be a clause. **Prefer the simpler solution**; propose the concrete simpler version. |
| `security` | Vulnerabilities | See the checklist below. |
| `tests` | Coverage | New behaviour without tests, tests asserting internals rather than the public contract, flaky timing (sleeps instead of `assert_receive`), missing edge cases. Respect the PRD rule: no LiveView/Spotify/Registry tests in v1. |
| `pr` | PR hygiene | Title, description accuracy, scope, status of existing comments (from step 1). |

### Security checklist

- Secrets: nothing hard-coded; Spotify credentials only via `System.get_env/1` at runtime; tokens never logged or rendered.
- The Spotify **access token** must only reach the host view (`host_state`), never the public broadcast or the player view.
- HTML injection: any `raw/1`, `Phoenix.HTML.raw`, or string-built `style`/`href`/`src` attribute fed by user or Spotify data (song names, album-art URLs, display names).
- OAuth: `state` is signed and verified, the redirect URI is fixed, and errors redirect safely.
- Player session tokens: signed `Phoenix.Token`, sensible max age, can't be replayed against another room.
- Input: lengths and types validated on every `handle_event` (names, room codes, choices, config overrides); invalid input never crashes the GenServer.
- Authorization: host-only actions (start, skip, settings, play again) — note when a route exposes them to anyone who knows the code.
- Dependencies or `Dockerfile` changes: pinned versions, no new network fetches at runtime.

### Finding format (every reviewer returns only this)

```json
{
  "id": "bugs-1",
  "lens": "bugs",
  "severity": "blocker | major | minor | nit",
  "file": "lib/whose_jam/game/server.ex",
  "line": 612,
  "side": "RIGHT",
  "title": "Safety timer not cancelled when countdown starts",
  "detail": "What's wrong, the concrete failure scenario (inputs → wrong outcome), and why.",
  "suggestion": "The smallest fix, as code if possible.",
  "confidence": 0.0
}
```

Rules for reviewers:
- `line` must be a line **in the diff on the PR head** (RIGHT side), or the comment can't be anchored. Findings outside the diff go in the summary only.
- Every finding needs a concrete failure scenario. "Could be cleaner" without a reason is not a finding.
- Don't report what the checks in step 2 already caught; reference the check instead.
- Don't post anything to GitHub.

---

## 4. Vote and condense (parallel agents)

1. **Merge:** the orchestrator pools all findings and dedupes ones that point at the same root cause (keep the clearest write-up, merge the evidence).
2. **Vote:** spawn **three voter agents** in parallel. Each gets the pooled findings plus the diff and worktree, and judges **every** finding independently:
   - `keep` — real, reproducible from the code, worth the author's time
   - `downgrade` — real but lower severity (give the new severity)
   - `drop` — wrong, speculative, duplicate, or style-only preference

   Voters must re-read the cited code rather than trust the reviewer, and give a one-line reason per vote.
3. **Tally:** keep a finding if **at least 2 of 3** voters keep or downgrade it. Use the median severity. Dropped findings are discarded silently.
4. **Condense:** one final agent turns the surviving findings into the review:
   - group related findings, lead with blockers
   - one inline comment per surviving finding, written for the author: problem, failure scenario, suggested fix
   - a short summary body: verdict, check results table, PR-hygiene notes, findings that couldn't be anchored inline, and anything notably done well (one or two lines, not filler)

The verdict is **Request changes** if any blocker survives or any step-2 check
failed; **Comment** if only major/minor issues survive; **Approve** if nothing
above `nit` survives and all checks passed.

---

## 5. Post to GitHub (orchestrator only)

### Inline comments + summary as one review

Build a JSON payload and submit a single review (so the author gets one
notification):

```sh
cat > /tmp/review-$PR.json <<'EOF'
{
  "commit_id": "<HEAD_SHA>",
  "event": "REQUEST_CHANGES",
  "body": "<summary markdown>",
  "comments": [
    { "path": "lib/whose_jam/game/server.ex", "line": 612, "side": "RIGHT",
      "body": "**[major] Safety timer not cancelled…**\n\n<detail>\n\n```suggestion\n<fix>\n```" }
  ]
}
EOF
gh api repos/$REPO/pulls/$PR/reviews --method POST --input /tmp/review-$PR.json
```

- `event` is `REQUEST_CHANGES`, `COMMENT`, or `APPROVE` per the verdict. GitHub rejects approve/request-changes on your own PR. If the reviewing account authored the PR, use `COMMENT` and state the verdict in the body.
- Use ```` ```suggestion ```` blocks only when the replacement is exact and complete for the anchored line(s). For multi-line ranges add `"start_line"` and `"start_side"`.
- Prefix each comment body with its severity: `[blocker]`, `[major]`, `[minor]`, `[nit]`.

### Resolve addressed threads

For each **unresolved** thread from step 1, decide whether the PR head addresses
it (re-read the current code at that path/line and the thread's request). If it
does:

```sh
# Reply with how it was addressed, then resolve
gh api repos/$REPO/pulls/$PR/comments/<comment_id>/replies --method POST \
  -f body="Addressed in ${HEAD_SHA:0:7}: <one line on what changed>."

gh api graphql -f threadId=<thread_node_id> -f query='
  mutation($threadId:ID!) { resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } } }'
```

Only resolve a thread when the fix is verifiable in the code. If it's partially
addressed or you're unsure, leave it open and say why in the summary. Never
resolve threads that ask a question the author hasn't answered.

### Clean up

```sh
cd - && git worktree remove /tmp/review-$PR
```

Report back to the user: the PR URL, the verdict, the check results, and the
number of inline comments posted and threads resolved.
