# Plan Review Workflow

## Smart Default Detection

**plan-path detection** (matches spec: `plan.md`, `PLAN.md`, `docs/*plan*.md` only):
```bash
# Check exact names at CWD root level (collect all matches, not just first)
PLAN_ROOT=$(ls plan.md PLAN.md 2>/dev/null)
# Check docs/ subdirectory for any *plan*.md file (depth 3 to reach docs/sub/sub/)
PLAN_DOCS=$(find ./docs -maxdepth 3 -name "*plan*.md" 2>/dev/null | head -5)

# Count total candidates
ALL="$([ -n "$PLAN_ROOT" ] && echo "$PLAN_ROOT")
$PLAN_DOCS"
COUNT=$(echo "$ALL" | grep -v '^$' | wc -l)

if [ "$COUNT" -eq 1 ]; then
  PLAN_PATH=$(echo "$ALL" | grep -v '^$')
elif [ "$COUNT" -gt 1 ]; then
  echo "Multiple plan files found: $ALL"
  # Ask user: "Which plan file should I use?"
  PLAN_PATH="<user-chosen>"  # ← set after user selects
else
  # Ask user for path
  PLAN_PATH=""
fi
```

> **Scope:** Only searches `plan.md`/`PLAN.md` at CWD root, and `docs/` up to 3 levels deep (e.g. `docs/superpowers/plans/*.md`). Restricts to `.md` files to avoid false positives. Does NOT do full recursive search.

**effort detection:** Default `high` for plan review.

Announce: `"Detected: plan=docs/superpowers/plans/2026-03-18-example.md, effort=high. Proceeding — reply to override."`

---

## 1) Gather Inputs
- Plan file path (absolute). Must be a Markdown file.
- User request text (or default: "Review this plan for quality and completeness").
- Session context: constraints, assumptions, tech stack.
- Acceptance criteria (user-provided or derived from plan).
- Debate effort level (`low|medium|high|xhigh`).

## 1.5) Pre-flight Checks

Before starting Round 1:
1. Read the plan file and verify it is Markdown: must have `.md` extension AND contain at least one markdown heading (`#`). Reading the file here ensures fail-fast if the path is unreadable.
2. If acceptance criteria not provided by user, derive from plan: scan for headings like "Goals", "Outcomes", "Success criteria", "Expected results" and extract content.

> **Write failures**: If saving the updated plan file fails in step 4/7, report the error and ask user for an alternative writable path. No pre-flight write check is needed — Claude Code's write tool provides a clear error at save time.

## 2) Start Round 1

### 2a) Initialize Session

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-plan-review --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate init output:** Verify `INIT_OUTPUT` starts with `CODEX_SESSION:`. If not, report error.

### 2b) Render Prompt

Compute `SKILLS_DIR` from the runner path:

```bash
# SKILLS_DIR is declared in SKILL.md ## Runner block — use it directly, do NOT recompute.
```

This resolves to the directory containing all installed skill directories (e.g., `~/.claude/skills`).

```bash
USER_REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
AC_ESCAPED=$(printf '%s' "$ACCEPTANCE_CRITERIA" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PLAN_PATH_ESCAPED=$(printf '%s' "$PLAN_PATH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-plan-review --template round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"PLAN_PATH":$PLAN_PATH_ESCAPED,"USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"ACCEPTANCE_CRITERIA":$AC_ESCAPED}
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
    { "time": 30, "type": "thinking", "detail": "analyzing plan structure" },
    { "time": 35, "type": "command_started", "detail": "cat plan.md" }
  ]
}
```

Report **specific activities** from the `activities` array. Example: `"Codex [45s]: reading plan.md, analyzing section 3 structure"`. NEVER say generic messages like "Codex is running" or "still waiting" — always extract concrete details from activities.

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
      { "id": 1, "prefix": "ISSUE", "title": "Missing error handling section", "category": "completeness", "severity": "high", "location": "plan.md:section-3", "problem": "...", "evidence": "...", "suggested_fix": "...", "extra": {} }
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

## 4) Parse Review

Parse issues from the poll JSON `review.blocks` array:
- Each block has `id`, `prefix`, `title`, `category`, `severity`, `location`, `problem`, `evidence`, `suggested_fix`, and optionally `why_it_matters`, `extra`.
- The verdict is in `review.verdict.status` (e.g., `"REVISE"`, `"APPROVE"`).
- `review.raw_markdown` is always available as fallback.

For valid issues: apply fixes to the plan and **save the plan file** before resuming. Codex round 2+ will re-read it from the plan path.
For invalid issues: write rebuttal with concrete proof (reasoning, references, behavior).

Record the set of open (unresolved) ISSUE-{N} IDs for stalemate tracking.

> **Note:** Round tracking is automatic. The runner manages `rounds.json` — do NOT read or write it manually.

## 5) Resume (Round 2+)

### 5a) Render Rebuttal Prompt

```bash
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
FIXED_ESCAPED=$(printf '%s' "$FIXED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DISPUTED_ESCAPED=$(printf '%s' "$DISPUTED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PLAN_PATH_ESCAPED=$(printf '%s' "$PLAN_PATH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-plan-review --template rebuttal --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"PLAN_PATH":$PLAN_PATH_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"FIXED_ITEMS":$FIXED_ESCAPED,"DISPUTED_ITEMS":$DISPUTED_ESCAPED}
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

Then **go back to step 3 (Poll).** After poll completes, repeat step 4 (Parse) and check stop conditions below. If not met, resume again (step 5). Continue this loop until a stop condition is reached.

## 6) Stop Conditions
- Codex returns `VERDICT: APPROVE` (check `review.verdict.status === "APPROVE"` in poll JSON).
- Stalemate detected (see below).
- User stops debate.
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

## 7) Final Report

### Review Summary
| Metric | Value |
|--------|-------|
| Rounds | {N} |
| Verdict | {APPROVE/REVISE/STALEMATE} |
| Issues Found | {total} |
| Issues Fixed | {fixed_count} |
| Issues Disputed | {disputed_count} |

Then present:
- Accepted issues and plan edits made.
- Disputed issues with reasoning from both sides.
- Residual risks and unresolved assumptions.
- Recommended next steps before implementation.
- Final plan path.

## 8) Session Finalization

After the final round completes, finalize the session:

```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"APPROVE"}
FINALIZE_EOF
```

Optionally include issue tracking:
```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"APPROVE","issues":{"total_found":5,"total_fixed":3,"total_disputed":2}}
FINALIZE_EOF
```

The runner auto-computes `meta.json` with timing, round count, and session metadata.

Report `$SESSION_DIR` path to the user in the final summary.

## 9) Cleanup
```bash
node "$RUNNER" stop "$SESSION_DIR"
```
Kill any remaining Codex/watchdog processes. Always run this step, even if the debate ended due to failure or timeout.

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
- Claude NEVER writes files to the session directory — all session I/O is handled by runner commands.
