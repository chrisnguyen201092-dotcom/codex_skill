# Commit Review Workflow

## Smart Default Detection

> **Context:** These detection commands run inside Claude Code where `git` is available. They assume a git repository. All `git` commands are wrapped in `2>/dev/null` to fail silently for non-git directories or edge cases (detached HEAD, no upstream tracking branch set). Detection is best-effort — if a command fails, the fallback default is used.

**mode detection:**
```bash
git diff --cached --quiet 2>/dev/null
EXIT=$?
if [ $EXIT -eq 1 ]; then MODE="draft"  # exit 1 = staged changes present
elif [ $EXIT -eq 0 ]; then MODE="last" # exit 0 = no staged changes
else MODE=""  # git error (not a repo, etc.) — leave unset, ask user
fi
```

If `draft`, ask user for the commit message text to review. If `last`, use N=1 default.

Announce: `"Detected: mode=draft, effort=medium. Proceeding — reply to override."`

---

## 1) Collect Inputs
- **Input source** (`draft` or `last`).
- **Draft mode**: user-provided commit message text. Run `git diff --cached` for staged changes context.
- **Last mode**: `git log -n "$N" --format='%H%n%B---'` to get message(s). For diff context: clamp N to available history (`MAX=$(git rev-list --count HEAD)`; if N > MAX, set N=MAX; if MAX is 0, abort with "no commits to review"). Use `git diff HEAD~"$N"..HEAD` when N < MAX. When N >= MAX (reviewing entire history including root commit), use `EMPTY_TREE=$(git hash-object -t tree /dev/null) && git diff "$EMPTY_TREE"..HEAD` to get a complete diff from empty tree.
- Review effort level (`low|medium|high|xhigh`).

## 1.5) Pre-flight Checks
1. Verify inside a git repository: `git rev-parse --show-toplevel`. If not a git repo, abort.
2. **Draft mode**: `git diff --cached --quiet` must FAIL (exit 1). If exit 0, there are no staged changes — abort with "no staged changes to verify message against". Note: `--quiet` implies `--exit-code`, so Git returns 1 when differences exist.
3. **Last mode**: Validate `N` is a positive integer. Verify `git rev-list --count HEAD` > 0 (history exists). Clamp N to available history. Warn if aggregate diff is empty (metadata-only commits).

## 1.6) Convention Discovery
Discover project commit conventions in priority order. Stop at first match:
1. **User instruction**: if user explicitly states conventions (e.g. "we use Conventional Commits"), use that.
2. **Repo config**: check `git config --local commit.template` for a repo-specific commit template file. Only consider templates that are local to the repo — ignore global/system git config.
3. **Repo tooling**: look for commitlint config (`.commitlintrc*`, `commitlint.config.*`), or commit conventions in `CONTRIBUTING.md`.
4. **Recent history heuristic**: scan last 20 commits (`git log -20 --format='%s'`). If 80%+ use `type:` or `type(scope):` prefix, assume Conventional Commits.
5. **Fallback**: use Git's general guideline — short subject line, blank line, optional body. Do NOT assume Conventional Commits without evidence.

Store result as `{PROJECT_CONVENTIONS}` for prompt injection.

## 2) Start Round 1

### 2a) Initialize Session

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-commit-review --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate init output:** Verify `INIT_OUTPUT` starts with `CODEX_SESSION:`. If not, report error.

### 2b) Render Codex Prompt

```bash
# SKILLS_DIR is declared in SKILL.md ## Runner block — use it directly, do NOT recompute.
```

For draft mode:
```bash
MSGS_ESCAPED=$(printf '%s' "$COMMIT_MESSAGES" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DIFF_ESCAPED=$(printf '%s' "$DIFF_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CONV_ESCAPED=$(printf '%s' "$PROJECT_CONVENTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template draft-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$MSGS_ESCAPED,"DIFF_CONTEXT":$DIFF_ESCAPED,"USER_REQUEST":$REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"PROJECT_CONVENTIONS":$CONV_ESCAPED}
RENDER_EOF
)
```

For last mode:
```bash
MSGS_ESCAPED=$(printf '%s' "$COMMIT_MESSAGES" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DIFF_ESCAPED=$(printf '%s' "$DIFF_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
LIST_ESCAPED=$(printf '%s' "$COMMIT_LIST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CONV_ESCAPED=$(printf '%s' "$PROJECT_CONVENTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template last-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$MSGS_ESCAPED,"DIFF_CONTEXT":$DIFF_ESCAPED,"COMMIT_LIST":$LIST_ESCAPED,"USER_REQUEST":$REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"PROJECT_CONVENTIONS":$CONV_ESCAPED}
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

**PURPOSE**: Claude evaluates commit message(s) BEFORE seeing Codex output. This prevents anchoring bias and ensures genuine peer debate.

**INFORMATION BARRIER**: MUST NOT read any Codex output from the session directory.

### 2.5a) Render Claude Analysis Prompt

For draft mode:
```bash
MSGS_ESCAPED=$(printf '%s' "$COMMIT_MESSAGES" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DIFF_ESCAPED=$(printf '%s' "$DIFF_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CONV_ESCAPED=$(printf '%s' "$PROJECT_CONVENTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CLAUDE_PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template claude-draft --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$MSGS_ESCAPED,"DIFF_CONTEXT":$DIFF_ESCAPED,"PROJECT_CONVENTIONS":$CONV_ESCAPED}
RENDER_EOF
)
```

For last mode:
```bash
MSGS_ESCAPED=$(printf '%s' "$COMMIT_MESSAGES" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DIFF_ESCAPED=$(printf '%s' "$DIFF_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
LIST_ESCAPED=$(printf '%s' "$COMMIT_LIST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CONV_ESCAPED=$(printf '%s' "$PROJECT_CONVENTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CLAUDE_PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template claude-last --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$MSGS_ESCAPED,"DIFF_CONTEXT":$DIFF_ESCAPED,"COMMIT_LIST":$LIST_ESCAPED,"PROJECT_CONVENTIONS":$CONV_ESCAPED}
RENDER_EOF
)
```

`{CLAUDE_ANALYSIS_FORMAT}` is auto-injected by the render command from `references/claude-analysis-template.md`.

### 2.5b) Perform Analysis

**Instructions:**
1. Read the rendered Claude analysis prompt.
2. Claude reads the diff and commit messages:
   - **Draft mode**: Run `git diff --cached` to read the staged diff.
   - **Last mode**: Run `git show <SHA>` for EACH commit individually + run the diff command for aggregate context. Every FINDING's Evidence MUST reference a specific SHA and subject.
3. Claude writes FINDING-{N} findings following the format in `references/claude-analysis-template.md`.
4. Claude writes Overall Assessment (Quality, Convention compliance, Accuracy vs diff).
5. Claude writes Strongest Positions (positions to defend in debate).
6. **CRITICAL**: This step MUST be COMPLETED before proceeding to Step 3. Do not read Codex output until after independent analysis is finalized.

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
    { "time": 30, "type": "thinking", "detail": "analyzing commit message structure" },
    { "time": 35, "type": "command_started", "detail": "git diff --cached" }
  ]
}
```

Report **specific activities** from the `activities` array. Example: `"Codex [45s]: reading git diff --cached, analyzing commit message structure"`. NEVER say generic messages like "Codex is running" or "still waiting" — always extract concrete details from activities.

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
      { "id": 1, "prefix": "ISSUE", "title": "Missing scope prefix", "category": "convention", "severity": "medium", "location": "draft", "problem": "...", "evidence": "...", "suggested_fix": null, "extra": { "why_it_matters": "..." } }
    ],
    "verdict": { "status": "CONTINUE", "reason": "..." },
    "overall_assessment": { "quality": "good", "convention_compliance": "partial", "accuracy_vs_diff": "accurate" },
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

**Replaces the old "Apply/Rebut" step.** Claude and Codex are equal peers — no reviewer/implementer framing.

### 4a) Read Codex Output
- Parse `review.blocks` (each block has `id`, `prefix`, `title`, `category`, `severity`, `location`, `problem`, `evidence`, `extra`) and `review.overall_assessment` from poll JSON.
- The verdict is in `review.verdict.status` (e.g., `"CONTINUE"`, `"CONSENSUS"`, `"STALEMATE"`).
- `review.raw_markdown` is always available as fallback.

### 4b) Compare Findings (Side-by-Side)

Map Claude's FINDING-{N} to Codex's ISSUE-{N} using the Matching Protocol in `references/claude-analysis-template.md`.

| Classification | Meaning |
|---------------|---------|
| **Genuine Agreement** | Both independently found the same issue |
| **Genuine Disagreement** | Opposing assessment (e.g., Claude thinks message is clear, Codex thinks it's not) |
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

## 5) Resume Round 2+

### 5a) Render Response Prompt

For draft mode:
```bash
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CONV_ESCAPED=$(printf '%s' "$PROJECT_CONVENTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
AGREED_ESCAPED=$(printf '%s' "$AGREED_POINTS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DISAGREED_ESCAPED=$(printf '%s' "$DISAGREED_POINTS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
NEW_ESCAPED=$(printf '%s' "$NEW_FINDINGS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
STATUS_ESCAPED=$(printf '%s' "$CONTINUE_OR_CONSENSUS_OR_STALEMATE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DIFF_ESCAPED=$(printf '%s' "$DIFF_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template draft-round2+ --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"SESSION_CONTEXT":$CTX_ESCAPED,"PROJECT_CONVENTIONS":$CONV_ESCAPED,"AGREED_POINTS":$AGREED_ESCAPED,"DISAGREED_POINTS":$DISAGREED_ESCAPED,"NEW_FINDINGS":$NEW_ESCAPED,"CONTINUE_OR_CONSENSUS_OR_STALEMATE":$STATUS_ESCAPED,"DIFF_CONTEXT":$DIFF_ESCAPED}
RENDER_EOF
)
```

For last mode:
```bash
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CONV_ESCAPED=$(printf '%s' "$PROJECT_CONVENTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
AGREED_ESCAPED=$(printf '%s' "$AGREED_POINTS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DISAGREED_ESCAPED=$(printf '%s' "$DISAGREED_POINTS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
NEW_ESCAPED=$(printf '%s' "$NEW_FINDINGS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
STATUS_ESCAPED=$(printf '%s' "$CONTINUE_OR_CONSENSUS_OR_STALEMATE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DIFF_ESCAPED=$(printf '%s' "$DIFF_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
LIST_ESCAPED=$(printf '%s' "$COMMIT_LIST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template last-round2+ --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"SESSION_CONTEXT":$CTX_ESCAPED,"PROJECT_CONVENTIONS":$CONV_ESCAPED,"AGREED_POINTS":$AGREED_ESCAPED,"DISAGREED_POINTS":$DISAGREED_ESCAPED,"NEW_FINDINGS":$NEW_ESCAPED,"CONTINUE_OR_CONSENSUS_OR_STALEMATE":$STATUS_ESCAPED,"DIFF_CONTEXT":$DIFF_ESCAPED,"COMMIT_LIST":$LIST_ESCAPED}
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

Then **go back to step 3 (Poll).** After poll completes, repeat step 4 (Cross-Analysis) and check stop conditions. If round >= 5, force final output — do NOT resume. Otherwise, continue until a stop condition is reached.

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
- User explicitly stops.

### Authority Rule
Claude orchestration is the authoritative source for stop/continue decisions. Codex VERDICT is advisory input — Claude considers it but may override if evidence warrants.

## 7) Final Output

Present a consensus report — **NEVER propose revised commit messages**.

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

### Commit Message(s) Reviewed
{original messages — verbatim, per-commit SHA for last mode}

### Consensus Points
- FINDING-1/ISSUE-2: {description} — Both agree: {assessment}
- ...

### FINDING↔ISSUE Mapping
| Claude FINDING | Codex ISSUE | Classification | Status |
|---------------|-------------|----------------|--------|
| FINDING-1     | ISSUE-2     | Agreement      | Agreed |
| FINDING-2     | —           | Claude-only    | Noted  |
| —             | ISSUE-1     | Codex-only     | Agreed |

### Remaining Disagreements
| Point | Claude | Codex |
|-------|--------|-------|
| Clarity of subject line | Good — concise and descriptive | Fair — missing scope prefix |
| ... | ... | ... |

### Overall Assessment
| Aspect | Claude | Codex | Consensus |
|--------|--------|-------|-----------|
| Quality | good | fair | — |
| Convention compliance | yes | partial | — |
| Accuracy vs diff | accurate | accurate | ✓ |
```

## 8) Session Finalization

After the final round completes, finalize the session:

```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"CONSENSUS","scope":"draft"}
FINALIZE_EOF
```

For last mode, use `"scope":"last"`. Optionally include issue tracking:
```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"CONSENSUS","scope":"draft","issues":{"total_found":3,"total_agreed":2,"total_disagreed":1}}
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
4. If round < 5, ask user: accept current assessment or force one more round. If round >= 5 (hard cap), force final output — do NOT offer another round.
