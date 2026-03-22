# PR Review Workflow

## Smart Default Detection

**base-branch detection:**
```bash
BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
if [ -z "$BASE" ]; then
  # First-match semantics: remote refs preferred, then local
  if git show-ref --verify --quiet refs/remotes/origin/main; then BASE="main"
  elif git show-ref --verify --quiet refs/remotes/origin/master; then BASE="master"
  elif git show-ref --verify --quiet refs/heads/main; then BASE="main"
  elif git show-ref --verify --quiet refs/heads/master; then BASE="master"
  fi
fi
```

**effort detection** (after base is resolved):
```bash
FILES_CHANGED=$(git diff --name-only "$BASE"...HEAD 2>/dev/null | wc -l)
if [ "$FILES_CHANGED" -lt 10 ]; then EFFORT="medium"
elif [ "$FILES_CHANGED" -lt 50 ]; then EFFORT="high"
else EFFORT="xhigh"
fi
EFFORT=${EFFORT:-high}
```

Announce: `"Detected: base=main, effort=high (15 files changed). Proceeding — reply to override. PR title/description are optional."`

Block only if `$BASE` cannot be resolved (both auto-detection and fallback fail).

---

## 1) Collect Inputs
- **Base branch discovery:**
  1. Ask user for base branch, suggest default.
  2. Validate ref: `git rev-parse --verify <base>` — fail-fast if not found.
  3. Fallback order if user doesn't specify: remote HEAD (`git symbolic-ref refs/remotes/origin/HEAD`) → `origin/main` → `origin/master` → local `main` → local `master`.
  4. Confirm with user if using fallback.
- PR title and description (optional — user may not have written them yet).
- Branch diff: `git diff <base>...HEAD`.
- Commit log: `git log <base>..HEAD --oneline`.
- Commit list: `{COMMIT_LIST}` — formatted as `<SHA> <subject>` per commit.
- Commit count: `{COMMIT_COUNT}` — `git rev-list --count <base>..HEAD`.
- File stats: `git diff <base>...HEAD --stat`.
- Review effort level (`low|medium|high|xhigh`).

## 1.5) Pre-flight Checks
1. Verify inside a git repository: `git rev-parse --show-toplevel`. If not a git repo, abort.
2. Verify branch diff exists: `git diff <base>...HEAD --quiet` must FAIL (exit 1). If exit 0, there are no changes — abort with "no diff between current branch and base branch".
3. Verify commit history exists: `git rev-list --count <base>..HEAD` must be > 0. If 0, abort with "no commits ahead of base branch".

## 2) Start Round 1

### 2a) Initialize Session

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-pr-review --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate init output:** Verify `INIT_OUTPUT` starts with `CODEX_SESSION:`. If not, report error.

### 2b) Render Prompt

# SKILLS_DIR is declared in SKILL.md ## Runner block — use it directly, do NOT recompute.

```bash
REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DESC_ESCAPED=$(printf '%s' "$PR_DESCRIPTION" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
COMMITS_ESCAPED=$(printf '%s' "$COMMIT_LIST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
BASE_ESCAPED=$(printf '%s' "$BASE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
COMMIT_COUNT_ESCAPED=$(printf '%s' "$COMMIT_COUNT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-pr-review --template round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"PR_TITLE":"...","PR_DESCRIPTION":$DESC_ESCAPED,"BASE_BRANCH":$BASE_ESCAPED,"COMMIT_COUNT":$COMMIT_COUNT_ESCAPED,"COMMIT_LIST":$COMMITS_ESCAPED,"USER_REQUEST":$REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
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

**Do NOT poll yet. Proceed to Step 2.5.**

## 2.5) Claude Independent Analysis

**PURPOSE**: Claude evaluates the PR BEFORE seeing Codex output. This prevents anchoring bias and ensures genuine peer debate.

**INFORMATION BARRIER**: MUST NOT read any Codex output.

### Render Claude Analysis Prompt

```bash
DESC_ESCAPED=$(printf '%s' "$PR_DESCRIPTION" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
COMMITS_ESCAPED=$(printf '%s' "$COMMIT_LIST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
BASE_ESCAPED=$(printf '%s' "$BASE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
COMMIT_COUNT_ESCAPED=$(printf '%s' "$COMMIT_COUNT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CLAUDE_PROMPT=$(node "$RUNNER" render --skill codex-pr-review --template claude-analysis --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"PR_TITLE":"...","PR_DESCRIPTION":$DESC_ESCAPED,"BASE_BRANCH":$BASE_ESCAPED,"COMMIT_COUNT":$COMMIT_COUNT_ESCAPED,"COMMIT_LIST":$COMMITS_ESCAPED}
RENDER_EOF
)
```

`{CLAUDE_ANALYSIS_FORMAT}` is auto-injected by the render command from `references/claude-analysis-template.md`.

### Instructions
1. Read the rendered Claude analysis prompt.
2. Claude reads the diff, commits, and PR metadata:
   - Run `git diff <base>...HEAD` to read the branch diff.
   - Run `git log <base>..HEAD --oneline` to read commit history.
   - Run `git show <SHA>` for individual commits as needed.
   - Run `git diff <base>...HEAD --stat` for file stats.
   - Review PR title and description for accuracy.
3. Claude writes FINDING-{N} findings following the format in `references/claude-analysis-template.md`.
4. Claude writes Overall Assessment (Code quality, PR description accuracy, Commit hygiene, Scope appropriateness).
5. Claude writes Merge Readiness Pre-Assessment (Must-pass criteria status, Blocking issues, Initial recommendation).
6. Claude writes Strongest Positions (positions to defend in debate).
7. **CRITICAL**: This step MUST be COMPLETED before proceeding to Step 3. Do not read Codex output until after independent analysis is finalized.

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

**Round 2+ (response rounds):**
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
    { "time": 30, "type": "thinking", "detail": "analyzing commit hygiene" },
    { "time": 35, "type": "command_started", "detail": "git diff main...HEAD" }
  ]
}
```

Report **specific activities** from the `activities` array. Example: `"Codex [60s]: reading branch diff, analyzing commit hygiene"`. NEVER say generic messages like "Codex is running" or "still waiting" — always extract concrete details from activities.

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
    "format": "commit-pr-review",
    "blocks": [
      { "id": 1, "prefix": "ISSUE", "title": "Missing validation", "category": "security", "severity": "high", "location": "src/api.js:23", "problem": "...", "evidence": "...", "suggested_fix": "...", "extra": {} }
    ],
    "verdict": { "status": "CONTINUE", "reason": "..." },
    "overall_assessment": {
      "code_quality": "good",
      "pr_description_accuracy": "accurate",
      "commit_hygiene": "clean",
      "scope_appropriateness": "focused"
    },
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

## 4) Cross-Analysis

Claude and Codex are equal peers — no reviewer/implementer framing.

### 4a) Read Codex Output
- Parse `review.blocks` for ISSUE-{N} blocks from poll JSON.
- Parse `review.overall_assessment` for Overall Assessment.
- Parse `review.verdict` for VERDICT (Status + Reason).
- Use `review.raw_markdown` as fallback if structured parsing misses edge cases.

### 4b) Compare Findings (Side-by-Side)

Map Claude's FINDING-{N} to Codex's ISSUE-{N} using the Matching Protocol in `references/claude-analysis-template.md`.

| Classification | Meaning |
|---------------|---------|
| **Genuine Agreement** | Both independently found the same issue |
| **Genuine Disagreement** | Opposing assessment (e.g., Claude thinks code is correct, Codex sees a bug) |
| **Claude-only Finding** | Claude found it, Codex did not |
| **Codex-only Finding** | Codex found it, Claude did not |
| **Same Direction, Different Severity** | Both found the issue but disagree on severity level |

### 4c) Build Response
1. **Agreements**: Merged findings with reference to the mapping table.
2. **Disagreements**: Claude's position + why Codex's position does or doesn't change Claude's assessment.
3. **New findings**: Claude-only findings + evaluation of Codex-only findings on their merits.
4. **Set status**: CONTINUE, CONSENSUS, or STALEMATE. **Claude orchestration is authoritative** — Codex VERDICT is advisory input. Claude considers Codex's suggested status but overrides if evidence warrants.

### 4d) Determine Next Action
- If CONSENSUS → proceed to Step 7 (Final Output).
- If STALEMATE → proceed to Step 7 (Final Output).
- If CONTINUE → proceed to Step 5 (Resume Round 2+).

> **Note:** Round tracking is automatic. The runner manages `rounds.json` — do NOT read or write it manually.

## 5) Resume Round 2+

### 5a) Render Response Prompt

```bash
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
AGREED_ESCAPED=$(printf '%s' "$AGREED_POINTS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DISAGREED_ESCAPED=$(printf '%s' "$DISAGREED_POINTS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
NEW_ESCAPED=$(printf '%s' "$NEW_FINDINGS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
COMMITS_ESCAPED=$(printf '%s' "$COMMIT_LIST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
BASE_ESCAPED=$(printf '%s' "$BASE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
COMMIT_COUNT_ESCAPED=$(printf '%s' "$COMMIT_COUNT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-pr-review --template round2+ --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"SESSION_CONTEXT":$CTX_ESCAPED,"PR_TITLE":"...","BASE_BRANCH":$BASE_ESCAPED,"COMMIT_COUNT":$COMMIT_COUNT_ESCAPED,"COMMIT_LIST":$COMMITS_ESCAPED,"AGREED_POINTS":$AGREED_ESCAPED,"DISAGREED_POINTS":$DISAGREED_ESCAPED,"NEW_FINDINGS":$NEW_ESCAPED,"CONTINUE_OR_CONSENSUS_OR_STALEMATE":"..."}
RENDER_EOF
)
```

`{OUTPUT_FORMAT}` is auto-injected by the render command from `references/output-format.md`.

### 5b) Resume Codex

```bash
printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"
```

**Validate resume output (JSON):**
```json
{ "status": "started", "session_dir": "/path", "round": 2, "thread_id": "thread_abc" }
```

Then **go back to step 3 (Poll).** After poll completes, repeat step 4 (Cross-Analysis) and check stop conditions. If not met, resume again (step 5). Continue this loop until a stop condition is reached.

## 6) Stop Conditions

### Consensus Definitions

Three levels of consensus (encoded via the `Reason` field — no additional status values):

- **Full Consensus**: No remaining disagreed findings — both agree on all findings AND Overall Assessment. Verdict = `CONSENSUS`, Reason = "Full consensus — no remaining disagreements".
- **Partial Consensus**: Overall Assessment matches but 1-2 minor disagreed findings remain (severity ≤ low). Verdict = `CONSENSUS`, Reason = "Partial — N minor disagreements remain (see Remaining Disagreements)". List remaining minor disagreements.
- **No Consensus**: Disagreed findings with severity ≥ medium remain. Must continue or declare stalemate.

### Stop Triggers
- Full or Partial Consensus reached.
- Stalemate detected: same disagreed FINDING↔ISSUE pairs for 2 consecutive rounds with no new evidence.
- Hard cap reached (5 rounds maximum). If hard cap is reached without consensus, verdict is forced to STALEMATE (Reason: "Hard cap reached — N disagreements remain").
- User explicitly stops. Map to STALEMATE with Reason: "Stopped by user at round N".

### Authority Rule
Claude orchestration is the authoritative source for stop/continue decisions. Codex VERDICT is advisory input — Claude considers it but may override if evidence warrants.

## 7) Final Output

Present a consensus report + merge readiness assessment — **NEVER edit code or create commits**.

### 7a) Review Summary
```markdown
### Review Summary
| Metric | Value |
|--------|-------|
| Rounds | {N} |
| Verdict | CONSENSUS / STALEMATE |
| Claude Findings | {count} |
| Codex Issues | {count} |
| Agreed | {count} |
| Disagreed | {count} |
```

### 7b) FINDING↔ISSUE Mapping
```markdown
### FINDING↔ISSUE Mapping
| Claude FINDING | Codex ISSUE | Classification | Status |
|---------------|-------------|----------------|--------|
| FINDING-1     | ISSUE-2     | Agreement      | Agreed |
| FINDING-2     | —           | Claude-only    | Noted  |
| —             | ISSUE-1     | Codex-only     | Agreed |
```

### 7c) Consensus Points
```markdown
### Consensus Points
- FINDING-1/ISSUE-2: {description} — Both agree: {assessment}
- ...
```

### 7d) Remaining Disagreements
```markdown
### Remaining Disagreements
| Point | Claude | Codex |
|-------|--------|-------|
| {description} | {Claude's position} | {Codex's position} |
| ... | ... | ... |
```

### 7e) Overall Assessment
```markdown
### Overall Assessment
| Aspect | Claude | Codex | Consensus |
|--------|--------|-------|-----------|
| Code quality | good | fair | — |
| PR description accuracy | accurate | accurate | ✓ |
| Commit hygiene | clean | acceptable | — |
| Scope appropriateness | focused | focused | ✓ |
```

### 7f) Merge Readiness Scorecard

Derive scorecard from **agreed findings only**:

```markdown
### Merge Readiness Scorecard
| Criterion | Must-pass? | Claude | Codex | Consensus | Status |
|-----------|-----------|--------|-------|-----------|--------|
| Code correctness (bug) | ✅ Yes | pass | pass | pass | ✅ |
| Edge case handling | ⚠️ If high+ | pass | concern | pass | ✅ |
| Security | ✅ Yes | pass | pass | pass | ✅ |
| Performance | ❌ Unless critical | pass | pass | pass | ✅ |
| Maintainability | ❌ No | concern | pass | concern | ℹ️ |
| PR description | ❌ No | pass | fail | concern | ℹ️ |
| Commit hygiene | ❌ No | pass | pass | pass | ✅ |
| Scope appropriateness | ❌ No | pass | pass | pass | ✅ |
```

**Scorecard derivation (per criterion row):**
- **pass**: No agreed finding severity ≥ medium in this category
- **concern**: Agreed finding severity = medium in this category (non-blocking)
- **fail**: Agreed finding severity ≥ high in this category

### 7g) Merge Recommendation

Decision table (priority top-to-bottom, stop at first match):

| # | Condition | Recommendation |
|---|-----------|---------------|
| 1 | Any agreed finding severity=**critical** in must-pass (bug, security) | **REJECT** ❌ |
| 2 | ≥3 agreed findings severity=**high** in must-pass | **REJECT** ❌ |
| 3 | Any agreed finding severity=**high** in must-pass | **REVISE** ⚠️ |
| 4 | Any agreed finding severity=**high** in edge-case | **REVISE** ⚠️ |
| 5 | ≥3 agreed findings severity=**medium** in must-pass | **REVISE** ⚠️ |
| 6 | All remaining (findings ≤ medium non-must-pass, or ≤ low) | **MERGE** ✅ |

Must-pass categories: `bug`, `security`. Conditional must-pass: `edge-case` (severity ≥ high → must-pass, else non-blocking).

**Disagreement handling**: Disagreed findings do NOT block merge recommendation. If a disagreed finding could change the recommendation, note: "⚠️ If {point} is confirmed, recommendation would change to {REVISE/REJECT}."

```markdown
### Merge Recommendation
**MERGE ✅** / **REVISE ⚠️** / **REJECT ❌**

Reason: {rationale based on scorecard and agreed findings}

{If disagreed findings could change recommendation:}
⚠️ If {disagreed point} is confirmed, recommendation would change to {REVISE/REJECT}.
```

## 8) Session Finalization

After the final round completes, finalize the session:

```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"CONSENSUS","scope":"branch"}
FINALIZE_EOF
```

Optionally include issue tracking:
```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"CONSENSUS","scope":"branch","issues":{"total_found":5,"agreed":3,"disagreed":2}}
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

## Stalemate Handling

When stalemate detected (same disagreed FINDING↔ISSUE pairs for 2 consecutive rounds with no new evidence):
1. List specific deadlocked points.
2. Show each side's final argument for each point.
3. Present both sides' assessments and let user judge.
4. Still produce Merge Readiness Scorecard from agreed findings — disagreed findings do not block the scorecard.
5. If current round < 5, ask user: accept current assessment or force one more round. If current round = 5 (hard cap), force final output — do NOT offer another round.
