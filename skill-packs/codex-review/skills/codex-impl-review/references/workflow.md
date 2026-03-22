# Implementation Review Workflow

## Smart Default Detection

> **Context:** These detection commands run inside Claude Code where `git` is available. They assume a git repository. All `git` commands are wrapped in `2>/dev/null` to fail silently for non-git directories or edge cases (detached HEAD, no upstream tracking branch set). Detection is best-effort — if a command fails, the fallback default is used.

Before asking the user anything, auto-detect and announce:

**scope detection (FIRST):**
```bash
HAS_WORKING_CHANGES=$(git status --short 2>/dev/null | grep -v '^??' | wc -l)
HAS_BRANCH_COMMITS=$(git rev-list @{u}..HEAD 2>/dev/null | wc -l)
if [ "$HAS_WORKING_CHANGES" -gt 0 ]; then SCOPE="working-tree"
elif [ "$HAS_BRANCH_COMMITS" -gt 0 ]; then SCOPE="branch"
else SCOPE=""  # ask user
fi
```

**effort detection (AFTER scope — adapts to detected scope):**
```bash
if [ "$SCOPE" = "branch" ]; then
  FILES_CHANGED=$(git diff --name-only @{u}..HEAD 2>/dev/null | wc -l)
else
  FILES_CHANGED=$(git diff --name-only 2>/dev/null | wc -l)
fi
if [ "$FILES_CHANGED" -lt 10 ]; then EFFORT="medium"
elif [ "$FILES_CHANGED" -lt 50 ]; then EFFORT="high"
else EFFORT="xhigh"
fi
# Fallback: default high
EFFORT=${EFFORT:-high}
```

Announce: `"Detected: scope=working-tree, effort=high (23 files changed). Proceeding — reply to override."`

Only block execution for `$SCOPE` when both detection methods return 0 (no changes anywhere).

---

## 1) Collect Inputs

### Mode Selection
Ask user: `working-tree` (default) or `branch`.

### Working-tree mode:
- Working directory path.
- User request and acceptance criteria.
- Uncommitted changes (`git status`, `git diff`, `git diff --cached`).
- Optional plan file for intent alignment.

### Branch mode:
- **Base branch discovery:**
  1. Ask user for base branch, suggest default.
  2. Validate ref: `git rev-parse --verify <base>` — fail-fast if not found.
  3. Fallback order if user doesn't specify: `main` → `master` → remote HEAD (`git symbolic-ref refs/remotes/origin/HEAD`).
  4. Confirm with user if using fallback.
- **Clean working tree required**: run `git diff --quiet && git diff --cached --quiet`. If uncommitted changes exist, tell user to commit or stash first, or switch to working-tree mode.
- **Stale base warning**: If base branch is local-only, recommend `git fetch origin <base>` before review. Stale base can cause incorrect diff scope.
- Branch diff: `git diff <base>...HEAD`.
- Commit log: `git log <base>..HEAD --oneline`.
- Optional plan file for intent alignment.

## 1.5) Pre-flight Checks

Before starting Round 1:
1. Working-tree mode: verify working tree has changes: `git diff --quiet && git diff --cached --quiet` should FAIL (exit 1). If both succeed (exit 0), there are no changes — report to user and stop.
2. Branch mode: verify branch diff exists: `git diff <base>...HEAD --quiet` should FAIL. If no diff, report to user and stop.

## 2) Init Session

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-impl-review --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate:** `INIT_OUTPUT` must start with `CODEX_SESSION:`. If not, report error and stop.

## 3) Render Prompt

Use the `render` command to assemble the prompt from templates. The runner reads `references/prompts.md`, finds the template by heading, replaces placeholders from stdin JSON, and auto-injects `{OUTPUT_FORMAT}` from `references/output-format.md`.

For working-tree mode:
```bash
USER_REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-impl-review --template working-tree-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
RENDER_EOF
)
```

For branch mode:
```bash
USER_REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
BASE_BRANCH_ESCAPED=$(printf '%s' "$BASE_BRANCH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-impl-review --template branch-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"BASE_BRANCH":$BASE_BRANCH_ESCAPED}
RENDER_EOF
)
```

**Placeholder values:**
- `USER_REQUEST`: User's original task description, or default "Review uncommitted changes for correctness and quality".
- `SESSION_CONTEXT`: Structured context block (see `references/prompts.md` § Placeholder Injection Guide for schema). If user provides no context, omit — the runner uses the default from prompts.md.
- `BASE_BRANCH`: Required for branch mode only. The validated base branch name.

**Validate:** `render` writes the rendered prompt to stdout. If stderr contains an error JSON with `"status":"error"`, report the error and stop.

## 4) Start Round 1

```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```

**Validate JSON output:**
```json
{ "status": "started", "session_dir": "/path", "round": 1 }
```
If `status` is `"error"`, check `code` field:
- `"CODEX_NOT_FOUND"` → tell user to install codex CLI.
- Other codes → report `error` message.

## 5) Poll

```bash
POLL_JSON=$(node "$RUNNER" poll "$SESSION_DIR")
```

Adaptive intervals — start slow, speed up:

**Round 1 (first review):**
- Poll 1: wait 60s
- Poll 2: wait 60s
- Poll 3: wait 30s
- Poll 4+: wait 15s

**Round 2+ (rebuttal rounds):**
- Poll 1: wait 30s
- Poll 2+: wait 15s

**Parse JSON output:**

Running:
```json
{
  "status": "running",
  "round": 1,
  "elapsed_seconds": 45,
  "activities": [
    { "time": 30, "type": "thinking", "detail": "analyzing auth flow" },
    { "time": 35, "type": "command_started", "detail": "cat src/auth.js" }
  ]
}
```

Report **specific activities** from the `activities` array. Example: `"Codex [45s]: reading src/auth.js, analyzing auth flow"`. NEVER say generic messages like "Codex is running" or "still waiting" — always extract concrete details from activities.

Continue while `status` is `"running"`.
Stop on `"completed"|"failed"|"timeout"|"stalled"`.

**Completed:**
```json
{
  "status": "completed",
  "round": 1,
  "elapsed_seconds": 120,
  "thread_id": "thread_abc",
  "review": {
    "format": "review",
    "blocks": [
      { "id": 1, "prefix": "ISSUE", "title": "Missing validation", "category": "security", "severity": "high", "location": "src/api.js:23", "problem": "...", "evidence": "...", "suggested_fix": "...", "extra": {} }
    ],
    "verdict": { "status": "REVISE", "reason": "..." },
    "overall_assessment": null,
    "raw_markdown": "..."
  },
  "activities": [...]
}
```

**Failed/Timeout/Stalled:**
```json
{
  "status": "failed|timeout|stalled",
  "round": 1,
  "elapsed_seconds": 3600,
  "exit_code": 2,
  "error": "Timeout after 3600s",
  "review": null,
  "activities": [...]
}
```

## 6) Apply/Rebut

Parse issues from the poll JSON `review.blocks` array:
- Each block has `id`, `prefix`, `title`, `category`, `severity`, `location`, `problem`, `evidence`, `suggested_fix`, and optionally `why_it_matters`, `extra`.
- The verdict is in `review.verdict.status` (e.g., `"REVISE"`, `"APPROVE"`).
- `review.raw_markdown` is always available as fallback.

For valid issues: edit code and record fix evidence.
For invalid issues: write rebuttal with concrete proof (paths, tests, behavior).

**Branch mode only**: after applying fixes, commit them (`git add` + `git commit`) before resuming. Codex reads `git diff <base>...HEAD` which only includes committed changes — uncommitted fixes will be invisible to Codex and cause repeated issues.

After applying fixes, verify with the narrowest relevant automated check:
- If test suite exists: run relevant tests.
- If type-checked language: run typecheck/compile.
- If no suitable automation: document manual fix evidence (diff + reasoning + affected paths).
- Do NOT claim an issue is fixed without some form of verification evidence.

Record the set of open (unresolved) ISSUE-{N} IDs for stalemate tracking.

> **Note:** Round tracking is automatic. The runner manages `rounds.json` — do NOT read or write it manually.

## 7) Resume Thread

### 7a) Render Rebuttal Prompt

For working-tree mode:
```bash
USER_REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
FIXED_ESCAPED=$(printf '%s' "$FIXED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DISPUTED_ESCAPED=$(printf '%s' "$DISPUTED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-impl-review --template rebuttal-working-tree --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"FIXED_ITEMS":$FIXED_ESCAPED,"DISPUTED_ITEMS":$DISPUTED_ESCAPED}
RENDER_EOF
)
```

For branch mode:
```bash
USER_REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
FIXED_ESCAPED=$(printf '%s' "$FIXED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DISPUTED_ESCAPED=$(printf '%s' "$DISPUTED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
BASE_BRANCH_ESCAPED=$(printf '%s' "$BASE_BRANCH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-impl-review --template rebuttal-branch --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"FIXED_ITEMS":$FIXED_ESCAPED,"DISPUTED_ITEMS":$DISPUTED_ESCAPED,"BASE_BRANCH":$BASE_BRANCH_ESCAPED}
RENDER_EOF
)
```

**Placeholder values for rebuttals:**
- `FIXED_ITEMS`: List of fixed issues with evidence (e.g., "ISSUE-1: Fixed — added input validation at src/api.js:25").
- `DISPUTED_ITEMS`: List of disputed issues with rebuttal reasoning.

### 7b) Resume Codex

```bash
printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"
```

**Validate resume output (JSON):**
```json
{ "status": "started", "session_dir": "/path", "round": 2, "thread_id": "thread_abc" }
```

Then **go back to step 5 (Poll).** After poll completes, repeat step 6 (Apply/Rebut) and check completion criteria below. If not met, resume again (step 7). Continue this loop until a completion criterion is reached.

## 8) Completion Criteria
- Codex returns `VERDICT: APPROVE` (check `review.verdict.status === "APPROVE"` in poll JSON).
- Or user accepts a documented stalemate.
- **Hard cap: 5 rounds.** At cap, force final synthesis with unresolved issues listed as residual risks.

## Stalemate Detection

Stalemate occurs when the set of unresolved ISSUE-{N} IDs is identical across 2 consecutive rounds:
- Track: after each round, record the set of open (not fixed, not withdrawn) issue IDs.
- If round N and round N-1 have the same open set AND Codex proposed no new issues, declare stalemate.
- Issue renaming or splitting counts as a new issue (different ID).

At stalemate:
1. List specific deadlocked points with both sides' final arguments.
2. Recommend which side to favor based on evidence strength.
3. If current round < 5, ask user: accept current state or force one more round.
4. If current round = 5 (hard cap), do NOT offer another round. Force final synthesis.

## 9) Final Output

### Review Summary
| Metric | Value |
|--------|-------|
| Rounds | {N} |
| Verdict | {APPROVE/REVISE/STALEMATE} |
| Issues Found | {total} |
| Issues Fixed | {fixed_count} |
| Issues Disputed | {disputed_count} |

Then present:
- Fixed defects by severity.
- Disputed items and rationale.
- Residual risks and unresolved assumptions.
- Recommended next steps.

## 10) Session Finalization

After the final round completes, finalize the session:

```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"APPROVE","scope":"working-tree"}
FINALIZE_EOF
```

For branch mode, use `"scope":"branch"`. Optionally include issue tracking:
```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"APPROVE","scope":"working-tree","issues":{"total_found":5,"total_fixed":3,"total_disputed":2}}
FINALIZE_EOF
```

The runner auto-computes `meta.json` with timing, round count, and session metadata.

Report `$SESSION_DIR` path to the user in the final summary.

## 11) Cleanup
```bash
node "$RUNNER" stop "$SESSION_DIR"
```
Kill any remaining Codex/watchdog processes. Always run this step, even if the review ended due to failure or timeout.

## Error Handling

### Poll Errors
Poll returns JSON. Parse `status` field:
- `"completed"` → success, review data in `review` field.
- `"failed"` (exit_code 3) → turn failed. Retry once. If still failing, report error to user.
- `"timeout"` (exit_code 2) → timeout. Report partial results from `review.raw_markdown` if available. Suggest retry with lower effort.
- `"stalled"` (exit_code 4) → stalled. Report partial results. Suggest lower effort.
- `"error"` → infrastructure error. Report `error` field to user.

### Start/Resume Errors
Start and resume return JSON. If `status` is `"error"`:
- Check `code` field: `"CODEX_NOT_FOUND"` → tell user to install codex. Other codes → report `error` message.

### General Rules
- Always run cleanup (step 11) regardless of error.
- Use `review.raw_markdown` as fallback if structured parsing misses edge cases.
