# Security Review Workflow

## Smart Default Detection

> **Context:** These detection commands run inside Claude Code where `git` is available. They assume a git repository. All `git` commands are wrapped in `2>/dev/null` to fail silently for non-git directories or edge cases (detached HEAD, no upstream tracking branch set). Detection is best-effort — if a command fails, the fallback default is used.

Before asking the user anything, auto-detect and announce:

**scope detection (FIRST):**
```bash
HAS_WORKING_CHANGES=$(git status --short 2>/dev/null | grep -v '^??' | wc -l)
HAS_BRANCH_COMMITS=$(git rev-list @{u}..HEAD 2>/dev/null | wc -l)
if [ "$HAS_WORKING_CHANGES" -gt 0 ]; then SCOPE="working-tree"
elif [ "$HAS_BRANCH_COMMITS" -gt 0 ]; then SCOPE="branch"
else SCOPE=""  # ask user — offer "full" as additional option
fi
```

**effort detection (AFTER scope — adapts to detected scope):**
```bash
if [ "$SCOPE" = "branch" ]; then
  FILES_CHANGED=$(git diff --name-only @{u}..HEAD 2>/dev/null | wc -l)
elif [ "$SCOPE" = "full" ]; then
  FILES_CHANGED=50  # default to high for full codebase
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
Ask user: `working-tree` (default), `branch`, or `full`.

### Working-tree mode:
- Working directory path.
- Uncommitted changes (`git status`, `git diff`, `git diff --cached`).

### Branch mode:
- **Base branch discovery:**
  1. Ask user for base branch, suggest default.
  2. Validate ref: `git rev-parse --verify <base>` — fail-fast if not found.
  3. Fallback order if user doesn't specify: `main` → `master` → remote HEAD (`git symbolic-ref refs/remotes/origin/HEAD`).
  4. Confirm with user if using fallback.
  5. Bind variable: `BASE_BRANCH=<validated value>` — use this consistently in all subsequent steps.
- **Clean working tree required**: run `git diff --quiet && git diff --cached --quiet`. If uncommitted changes exist, tell user to commit or stash first, or switch to working-tree mode.
- Branch diff: `git diff <base>...HEAD`.
- Commit log: `git log <base>..HEAD --oneline`.

### Full mode:
- Working directory path.
- No git diff checks needed (scans entire codebase).
- Identify high-risk areas: auth, database, external APIs, file operations, crypto.

## 1.5) Pre-flight Checks

Before starting Round 1:
1. Working-tree mode: verify working tree has changes: `git diff --quiet && git diff --cached --quiet` should FAIL (exit 1). If both succeed (exit 0), there are no changes — report to user and stop.
2. Branch mode: verify branch diff exists: `git diff <base>...HEAD --quiet` should FAIL. If no diff, report to user and stop.
3. Full mode: no pre-flight checks needed (scans entire codebase).

## 2) Start Round 1

### 2a) Initialize Session

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-security-review --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate init output:** Verify `INIT_OUTPUT` starts with `CODEX_SESSION:`. If not, report error.

### 2b) Render Prompt

# SKILLS_DIR is declared in SKILL.md ## Runner block — use it directly, do NOT recompute.

**Step 1: Render scope-specific instructions:**

For working-tree mode:
```bash
SCOPE_INSTRUCTIONS=$(node "$RUNNER" render --skill codex-security-review --template working-tree --skills-dir "$SKILLS_DIR" <<'SCOPE_EOF'
{}
SCOPE_EOF
)
```

For branch mode:
```bash
BASE_BRANCH_ESCAPED=$(printf '%s' "$BASE_BRANCH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
SCOPE_INSTRUCTIONS=$(node "$RUNNER" render --skill codex-security-review --template branch --skills-dir "$SKILLS_DIR" <<SCOPE_EOF
{"BASE_BRANCH":$BASE_BRANCH_ESCAPED}
SCOPE_EOF
)
```

For full mode:
```bash
SCOPE_INSTRUCTIONS=$(node "$RUNNER" render --skill codex-security-review --template full --skills-dir "$SKILLS_DIR" <<'SCOPE_EOF'
{}
SCOPE_EOF
)
```

**Step 2: JSON-escape scope instructions and render round1 prompt:**
```bash
ESCAPED_SCOPE=$(printf '%s' "$SCOPE_INSTRUCTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PWD_ESCAPED=$(printf '%s' "$PWD" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
SCOPE_VAL_ESCAPED=$(printf '%s' "$SCOPE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
EFFORT_ESCAPED=$(printf '%s' "$EFFORT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
BASE_BRANCH_ESCAPED=$(printf '%s' "$BASE_BRANCH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-security-review --template round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"WORKING_DIR":$PWD_ESCAPED,"SCOPE":$SCOPE_VAL_ESCAPED,"EFFORT":$EFFORT_ESCAPED,"BASE_BRANCH":$BASE_BRANCH_ESCAPED,"SCOPE_SPECIFIC_INSTRUCTIONS":$ESCAPED_SCOPE}
RENDER_EOF
)
```

`{OUTPUT_FORMAT}` is auto-injected by the render command from `references/output-format.md`.

### 2c) Start Codex

```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```

**Validate start output (JSON):**
```json
{ "status": "started", "session_dir": "/path", "round": 1 }
```
If `status` is `"error"`, report to user.

## 3) Poll

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
    { "time": 30, "type": "thinking", "detail": "analyzing authentication flow for broken access control" },
    { "time": 35, "type": "command_started", "detail": "cat src/auth.js" }
  ]
}
```

Report **specific activities** from the `activities` array. Example: `"Codex [45s]: scanning for SQL injection patterns in database queries"`. NEVER say generic messages like "Codex is running" or "still waiting" — always extract concrete details from activities.

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
    "format": "security-review",
    "blocks": [
      { "id": 1, "prefix": "ISSUE", "title": "SQL Injection in user search", "category": "injection", "severity": "critical", "confidence": "high", "cwe": "CWE-89", "owasp": "A03:2021", "problem": "...", "evidence": "...", "attack_vector": "...", "suggested_fix": "...", "extra": {} }
    ],
    "verdict": { "status": "REVISE", "reason": "...", "risk_summary": { "critical": 1, "high": 0, "medium": 2, "low": 1 } },
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

## 4) Apply/Rebut

Parse issues from the poll JSON `review.blocks` array:
- Each block has `id`, `prefix`, `title`, `category`, `severity`, `confidence`, `cwe`, `owasp`, `problem`, `evidence`, `attack_vector`, `suggested_fix`, and optionally `extra`.
- The verdict is in `review.verdict.status` (e.g., `"REVISE"`, `"APPROVE"`).
- The `review.verdict.risk_summary` contains severity counts: `{ "critical": N, "high": N, "medium": N, "low": N }`.
- `review.raw_markdown` is always available as fallback.

Present findings grouped by severity:
```markdown
# Security Review Results - Round 1

**Verdict**: REVISE
**Risk Level**: CRITICAL (1 critical, 0 high, 2 medium, 1 low)

## Critical Issues (1)
- ISSUE-1: SQL injection in user search

## Medium Issues (2)
- ISSUE-2: Missing security headers
- ISSUE-3: Weak password requirements

## Low Issues (1)
- ISSUE-4: Verbose error messages
```

For valid issues: edit code and record fix evidence.
For false positives: write rebuttal with concrete proof (paths, tests, mitigating controls).
For severity disputes: acknowledge issue, explain why severity should differ with context.

**Branch mode only**: after applying fixes, commit them (`git add` + `git commit`) before resuming. Codex reads `git diff <base>...HEAD` which only includes committed changes — uncommitted fixes will be invisible to Codex and cause repeated issues.

After applying fixes, verify with the narrowest relevant automated check:
- If test suite exists: run relevant tests.
- If type-checked language: run typecheck/compile.
- If no suitable automation: document manual fix evidence (diff + reasoning + affected paths).
- Do NOT claim an issue is fixed without some form of verification evidence.

Record the set of open (unresolved) ISSUE-{N} IDs for stalemate tracking.

> **Note:** Round tracking is automatic. The runner manages `rounds.json` — do NOT read or write it manually.

## 5) Resume Thread

### 5a) Render Rebuttal Prompt

```bash
FIXED_ESCAPED=$(printf '%s' "$FIXED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DISPUTED_ESCAPED=$(printf '%s' "$DISPUTED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-security-review --template round2+ --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"FIXED_ITEMS":$FIXED_ESCAPED,"DISPUTED_ITEMS":$DISPUTED_ESCAPED}
RENDER_EOF
)
```

### 5b) Resume Codex

```bash
printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"
```

**Validate resume output (JSON):**
```json
{ "status": "started", "session_dir": "/path", "round": 2, "thread_id": "thread_abc" }
```

Then **go back to step 3 (Poll).** After poll completes, repeat step 4 (Apply/Rebut) and check completion criteria below. If not met, resume again (step 5). Continue this loop until a completion criterion is reached.

## 6) Completion Criteria
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

## 7) Final Output

### Security Review Summary
| Metric | Value |
|--------|-------|
| Rounds | {N} |
| Verdict | {APPROVE/REVISE/STALEMATE} |
| Risk Level | {CRITICAL/HIGH/MEDIUM/LOW} |
| Issues Found | {total} |
| Issues Fixed | {fixed_count} |
| Issues Disputed | {disputed_count} |

### Risk Summary
- Critical: {count} ({fixed} fixed, {open} open)
- High: {count} ({fixed} fixed, {open} open)
- Medium: {count} ({fixed} fixed, {open} open)
- Low: {count} ({fixed} fixed, {open} open)

Then present:
- Fixed vulnerabilities by severity.
- Disputed items and rationale.
- Residual risks and unresolved assumptions.
- Blocking issues (must fix before merge).
- Advisory issues (should fix, not blocking).
- Recommended next steps (dynamic testing, penetration testing, etc.).

## 8) Session Finalization

After the final round completes, finalize the session:

```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"APPROVE","scope":"working-tree"}
FINALIZE_EOF
```

For branch mode, use `"scope":"branch"`. For full mode, use `"scope":"full"`. Optionally include issue tracking:
```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"APPROVE","scope":"working-tree","issues":{"total_found":5,"total_fixed":3,"total_disputed":2}}
FINALIZE_EOF
```

The runner auto-computes `meta.json` with timing, round count, and session metadata.

Report `$SESSION_DIR` path to the user in the final summary.

## 9) Cleanup
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
- Always run cleanup (step 9) regardless of error.
- Use `review.raw_markdown` as fallback if structured parsing misses edge cases.
