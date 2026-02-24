---
name: codex-impl-review
description: Have Codex CLI review uncommitted code changes. Claude Code then fixes valid issues and rebuts invalid ones. Codex re-reviews. Repeat until consensus. Codex never touches code — it only reviews.
---

# Codex Implementation Review — Skill Guide

## Overview
This skill sends uncommitted changes to Codex CLI for **review only**. Codex reads the diff itself, finds bugs/edge cases/security issues, and reports back. Claude Code then evaluates the review — fixes what's valid, pushes back on what's not — and sends the updated diff back to Codex for re-review. This repeats until both sides agree the code is solid.

**Codex NEVER modifies code.** It only reads and reviews. All fixes are done by Claude Code.

**Flow:** Point Codex to the repo → Codex reads diff + plan → Codex reviews → Claude Code fixes & rebuts → Codex re-reviews → ... → Consensus → Done

## Prerequisites
- There must be uncommitted changes (staged or unstaged) in the working directory.
- The Codex CLI (`codex`) must be installed and available in PATH.

## Codex Runner Script

This skill uses `codex-runner.sh` to handle all Codex CLI execution. The script runs foreground, manages polling/extraction/cleanup internally, and outputs structured results.

### Bootstrap Logic (inline in every Bash call)

Every Bash call that invokes the runner must include this resolve block at the top:

```bash
RUNNER="${CODEX_RUNNER:-$HOME/.local/bin/codex-runner.sh}"
NEED_INSTALL=0
if [ -n "$CODEX_RUNNER" ] && test -x "$CODEX_RUNNER"; then
  if ! grep -q 'CODEX_RUNNER_VERSION="1"' "$CODEX_RUNNER" 2>/dev/null; then NEED_INSTALL=1; fi
elif ! test -x "$RUNNER"; then NEED_INSTALL=1
elif ! grep -q 'CODEX_RUNNER_VERSION="1"' "$RUNNER" 2>/dev/null; then NEED_INSTALL=1
fi
if [ "$NEED_INSTALL" = 1 ]; then
  mkdir -p "$HOME/.local/bin"
  TMP=$(mktemp "$HOME/.local/bin/codex-runner.XXXXXX")
  cat > "$TMP" <<'RUNNER_SCRIPT'
<EMBEDDED_SCRIPT_CONTENT>
RUNNER_SCRIPT
  chmod +x "$TMP"
  mv "$TMP" "$HOME/.local/bin/codex-runner.sh"
  RUNNER="$HOME/.local/bin/codex-runner.sh"
fi
```

Where `<EMBEDDED_SCRIPT_CONTENT>` is the full content of the codex-runner.sh script below:

```bash
#!/usr/bin/env bash
set -euo pipefail

# IMPORTANT: Bump CODEX_RUNNER_VERSION when changing this script.
# embed-runner.sh checks this version string across all embed locations.
CODEX_RUNNER_VERSION="1"

WORKING_DIR=""
EFFORT="high"
THREAD_ID=""
TIMEOUT=540
POLL_INTERVAL=15

EXIT_SUCCESS=0
EXIT_ERROR=1
EXIT_TIMEOUT=2
EXIT_TURN_FAILED=3
EXIT_STALLED=4
EXIT_CODEX_NOT_FOUND=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) shift 2 ;;  # accepted but ignored for backwards compatibility
    --working-dir) WORKING_DIR="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --thread-id) THREAD_ID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --version) echo "codex-runner $CODEX_RUNNER_VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit $EXIT_ERROR ;;
  esac
done

if [[ -z "$WORKING_DIR" ]]; then echo "Error: --working-dir is required" >&2; exit $EXIT_ERROR; fi
if ! command -v codex &>/dev/null; then echo "Error: codex CLI not found in PATH" >&2; exit $EXIT_CODEX_NOT_FOUND; fi

PROMPT=$(cat)
if [[ -z "$PROMPT" ]]; then echo "Error: no prompt provided on stdin" >&2; exit $EXIT_ERROR; fi

RUN_ID="$(date +%s)-$$"
JSONL_FILE="/tmp/codex-runner-${RUN_ID}.jsonl"
ERR_FILE="/tmp/codex-runner-${RUN_ID}.err"

cleanup() {
  local codex_pid_local="${CODEX_PID:-}"
  if [[ -n "$codex_pid_local" ]] && kill -0 "$codex_pid_local" 2>/dev/null; then
    kill "$codex_pid_local" 2>/dev/null || true
    wait "$codex_pid_local" 2>/dev/null || true
  fi
  rm -f "$JSONL_FILE" "$ERR_FILE"
}
trap cleanup EXIT

CODEX_PID=""
if [[ -n "$THREAD_ID" ]]; then
  # Resume mode: codex exec resume does not support --sandbox or -C flags.
  # The sandbox setting from the initial session is preserved automatically.
  cd "$WORKING_DIR"
  echo "$PROMPT" | codex exec --skip-git-repo-check --json resume "$THREAD_ID" > "$JSONL_FILE" 2>"$ERR_FILE" &
  CODEX_PID=$!
else
  echo "$PROMPT" | codex exec --skip-git-repo-check --json --sandbox read-only --config model_reasoning_effort="$EFFORT" -C "$WORKING_DIR" > "$JSONL_FILE" 2>"$ERR_FILE" &
  CODEX_PID=$!
fi

ELAPSED=0
STALL_COUNT=0
LAST_LINE_COUNT=0

while true; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Error: timeout after ${TIMEOUT}s" >&2
    kill "$CODEX_PID" 2>/dev/null || true
    exit $EXIT_TIMEOUT
  fi
  if ! kill -0 "$CODEX_PID" 2>/dev/null; then
    wait "$CODEX_PID" 2>/dev/null || true
    CODEX_PID=""
    break
  fi
  if [[ -f "$JSONL_FILE" ]]; then
    CURRENT_LINE_COUNT=$(wc -l < "$JSONL_FILE" 2>/dev/null || echo 0)
    CURRENT_LINE_COUNT=$(echo "$CURRENT_LINE_COUNT" | tr -d ' ')
  else
    CURRENT_LINE_COUNT=0
  fi
  if [[ "$CURRENT_LINE_COUNT" -eq "$LAST_LINE_COUNT" ]]; then
    STALL_COUNT=$((STALL_COUNT + 1))
  else
    STALL_COUNT=0
    LAST_LINE_COUNT=$CURRENT_LINE_COUNT
  fi
  if [[ $STALL_COUNT -ge 12 ]]; then
    echo "Error: stalled — no new output for ~3 minutes" >&2
    kill "$CODEX_PID" 2>/dev/null || true
    exit $EXIT_STALLED
  fi
  if [[ -f "$JSONL_FILE" ]]; then
    LAST_EVENT=$(tail -1 "$JSONL_FILE" 2>/dev/null || true)
    if [[ -n "$LAST_EVENT" ]]; then
      EVENT_TYPE=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('type',''))" 2>/dev/null || true)
      case "$EVENT_TYPE" in
        turn.completed) wait "$CODEX_PID" 2>/dev/null || true; CODEX_PID=""; break ;;
        turn.failed) ERROR_MSG=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('error',{}).get('message','unknown'))" 2>/dev/null || true); echo "Error: $ERROR_MSG" >&2; wait "$CODEX_PID" 2>/dev/null || true; exit $EXIT_TURN_FAILED ;;
        turn.started) echo "Codex is thinking..." >&2 ;;
        item.completed) ITEM_TYPE=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('type',''))" 2>/dev/null || true); case "$ITEM_TYPE" in reasoning) echo "Codex thinking: $(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('text',''))" 2>/dev/null || true)" >&2 ;; command_execution) echo "Codex ran: $(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('command',''))" 2>/dev/null || true)" >&2 ;; esac ;;
        item.started) ITEM_TYPE=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('type',''))" 2>/dev/null || true); if [[ "$ITEM_TYPE" == "command_execution" ]]; then echo "Codex running: $(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('command',''))" 2>/dev/null || true)" >&2; fi ;;
      esac
    fi
  fi
done

if [[ ! -f "$JSONL_FILE" ]]; then echo "Error: no output" >&2; test -f "$ERR_FILE" && cat "$ERR_FILE" >&2; exit $EXIT_ERROR; fi
if grep -q '"type":"turn.failed"' "$JSONL_FILE" 2>/dev/null; then ERROR_MSG=$(grep '"type":"turn.failed"' "$JSONL_FILE" | tail -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('error',{}).get('message','unknown'))" 2>/dev/null || true); echo "Error: Codex turn failed: $ERROR_MSG" >&2; exit $EXIT_TURN_FAILED; fi
if ! grep -q '"type":"turn.completed"' "$JSONL_FILE" 2>/dev/null; then echo "Error: no turn.completed" >&2; test -f "$ERR_FILE" && test -s "$ERR_FILE" && cat "$ERR_FILE" >&2; exit $EXIT_ERROR; fi

EXTRACTED_THREAD_ID=$(grep '"thread_id"' "$JSONL_FILE" 2>/dev/null | head -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('thread_id',''))" 2>/dev/null || true)
REVIEW_TEXT=$(grep '"type":"agent_message"' "$JSONL_FILE" 2>/dev/null | tail -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('text',''))" 2>/dev/null || true)
if [[ -z "$REVIEW_TEXT" ]]; then echo "Error: no agent_message" >&2; exit $EXIT_ERROR; fi
if [[ -z "$EXTRACTED_THREAD_ID" ]]; then echo "Error: no thread_id" >&2; exit $EXIT_ERROR; fi

REVIEW_JSON=$(THREAD_ID_VAL="$EXTRACTED_THREAD_ID" python3 -c "import sys,json,os; text=sys.stdin.read(); print(json.dumps({'thread_id':os.environ.get('THREAD_ID_VAL',''),'review':text,'status':'success'}))" <<< "$REVIEW_TEXT")
echo "CODEX_RESULT:${REVIEW_JSON}"
exit 0
```

### Runner Output Format

The runner outputs a single line on stdout prefixed with `CODEX_RESULT:` followed by JSON:
```
CODEX_RESULT:{"thread_id":"...","review":"...","status":"success"}
```

Progress updates go to stderr (visible to user in Bash tool output).

### Exit Codes
- `0` = success
- `1` = general error
- `2` = timeout (540s default)
- `3` = codex turn failed
- `4` = codex stalled (~3 min no output)
- `5` = codex not found in PATH

## Step 1: Gather Configuration

Ask the user (via `AskUserQuestion`) **only one question**:
- Which reasoning effort to use (`xhigh`, `high`, `medium`, or `low`)

**Do NOT ask** which model to use — always use Codex's default model (no `-m` flag).
**Do NOT ask** how many rounds — the loop runs automatically until consensus.

## Step 2: Collect Uncommitted Changes

1. Run `git status --porcelain` to detect ALL changes including untracked (new) files.
2. If there are no changes at all, inform the user and stop.
3. **Detect if HEAD exists** — run `git rev-parse --verify HEAD 2>/dev/null`. If it fails (exit code non-zero), this is a fresh repo with no commits. Use `git diff --cached` and `git diff --cached --stat` (to capture staged changes) **plus** `git diff` and `git diff --stat` (to capture unstaged changes). If HEAD exists, use `git diff HEAD` and `git diff --stat HEAD` as normal (which covers both staged and unstaged).
4. **Stage untracked files for diffing** — if there are untracked files (`??` in porcelain output), run `git add -N <file>` (intent-to-add) for each one so they appear in git diff. This does NOT actually stage the files for commit — it only makes them visible to diff.
5. Run the appropriate `git diff --stat` command (with or without `HEAD` per step 3) to get a summary of all changed files.
6. If the number of changed files is very large, ask the user which files to focus on, or split into multiple review sessions.
7. **Locate the plan file** — check for the implementation plan that guided these changes. Common locations:
   - `.claude/plan.md`
   - `plan.md`
   - The plan mode output file
   - Ask the user if the plan file location is unclear.
   If no plan file exists, proceed without it (but having one significantly improves review quality).

## Prompt Construction Principle

**Only include in the Codex prompt what Codex cannot access on its own:**
- The path to the plan file (so Codex can cross-reference the implementation intent)
- The user's original request / task description
- Important context from the conversation: user comments, constraints, preferences, architectural decisions discussed verbally
- Clarifications or special instructions the user gave
- Which specific files to focus on (if the user specified)

**Do NOT include:**
- The diff content (Codex runs `git diff HEAD` itself)
- The plan content (Codex reads the file itself)
- Code snippets Codex can read from the repo
- Information Codex can derive by reading files

## Step 3: Send Changes to Codex for Review (Round 1)

Run the codex-runner with the bootstrap block. Use the Bash tool with `timeout: 600000`:

```bash
RUNNER="${CODEX_RUNNER:-$HOME/.local/bin/codex-runner.sh}"
NEED_INSTALL=0
if [ -n "$CODEX_RUNNER" ] && test -x "$CODEX_RUNNER"; then
  if ! grep -q 'CODEX_RUNNER_VERSION="1"' "$CODEX_RUNNER" 2>/dev/null; then NEED_INSTALL=1; fi
elif ! test -x "$RUNNER"; then NEED_INSTALL=1
elif ! grep -q 'CODEX_RUNNER_VERSION="1"' "$RUNNER" 2>/dev/null; then NEED_INSTALL=1
fi
if [ "$NEED_INSTALL" = 1 ]; then
  mkdir -p "$HOME/.local/bin"
  TMP=$(mktemp "$HOME/.local/bin/codex-runner.XXXXXX")
  cat > "$TMP" <<'RUNNER_SCRIPT'
<PASTE FULL SCRIPT FROM ABOVE>
RUNNER_SCRIPT
  chmod +x "$TMP"
  mv "$TMP" "$HOME/.local/bin/codex-runner.sh"
  RUNNER="$HOME/.local/bin/codex-runner.sh"
fi
"$RUNNER" --working-dir <WORKING_DIR> --effort <EFFORT> <<'EOF'
<REVIEW_PROMPT>
EOF
```

**IMPORTANT**: Use `timeout: 600000` in the Bash tool call (10 min max). The script runs foreground — no `run_in_background` needed.

Save the `thread_id` from the output JSON — you will need it for subsequent rounds.

### Parsing the Output

The last line of stdout will be:
```
CODEX_RESULT:{"thread_id":"...","review":"...","status":"success"}
```

Extract the JSON after `CODEX_RESULT:` prefix. Get `thread_id` for resume and `review` for the review text.

### Review Prompt Template

```
You are participating in a code review with Claude Code (Claude Opus 4.6).

## Your Role
You are the CODE REVIEWER. You review ONLY — you do NOT modify any code. Your job is to inspect uncommitted changes and report bugs, missing edge cases, error handling gaps, security vulnerabilities, and code quality issues. Be thorough, specific, and constructive. Claude Code will handle all fixes based on your feedback.

## How to Inspect Changes
1. Run `git status --porcelain` to see all changes including untracked files.
2. Check if HEAD exists: `git rev-parse --verify HEAD 2>/dev/null`. If it fails, use `git diff --cached --stat` and `git diff --cached` (for staged changes) plus `git diff --stat` and `git diff` (for unstaged changes). If it succeeds, use `git diff --stat HEAD` and `git diff HEAD`.
3. Run the appropriate git diff command to see the full diff. (Note: untracked files have already been marked with `git add -N` so they appear in the diff.)
4. Read any relevant source files for additional context if needed.

## Implementation Plan
Read the plan file for context on what these changes are supposed to achieve: <ABSOLUTE_PATH_TO_PLAN_FILE>
(If no plan file exists, write: "No plan file available — review the diff based on code quality alone.")

## User's Original Request
<The user's original task/request>

## Session Context
<Any important context from the conversation that Codex cannot access on its own>

(If there is no additional context, write "No additional context.")

## Instructions
1. Read the diff using the git commands above.
2. If a plan file is provided, read it and cross-reference: does the implementation match the plan? Are there deviations?
3. Analyze every changed file and produce your review in the EXACT format below.

## Required Output Format

For each issue found, use this structure:

### ISSUE-{N}: {Short title}
- **Category**: Bug | Edge Case | Error Handling | Security | Code Quality | Plan Deviation
- **Severity**: CRITICAL | HIGH | MEDIUM | LOW
- **File**: `{file_path}:{line_number or line_range}`
- **Description**: What the problem is, in detail.
- **Why It Matters**: Concrete scenario or example showing how this causes a real failure.
- **Suggested Fix**: Specific code change or approach to fix this. (Required for CRITICAL and HIGH severity. Recommended for others.)

After all issues, provide:

### VERDICT
- **Result**: REJECT | APPROVE_WITH_CHANGES | APPROVE
- **Summary**: 2-3 sentence overall assessment.
- **Plan Alignment**: Does the implementation correctly follow the plan? Note any deviations. (Skip if no plan file.)

Rules:
- Reference exact files and line numbers/hunks in the diff.
- Explain WHY each issue is a problem with a concrete scenario.
- Do NOT rubber-stamp the code. Your value comes from finding real problems.
- Do NOT nitpick style or formatting unless it causes actual issues.
- Do NOT attempt to fix or modify any files. Report issues only.
- Every CRITICAL or HIGH severity issue MUST have a Suggested Fix.
```

**After receiving Codex's review**, summarize the findings for the user, grouped by severity.

## Step 4: Claude Code Responds (Round 1)

After receiving Codex's review, you (Claude Code) must:

1. **Analyze each ISSUE-{N}** against the actual code.
2. **Fix valid issues** - If Codex found real bugs, edge cases, or security issues:
   - Apply the fixes directly to the code files using Edit tool.
   - Keep fixes minimal and focused — don't refactor surrounding code.
3. **Push back on invalid points** - If Codex flagged something incorrectly:
   - Explain why it's not actually a problem (e.g., the edge case is handled upstream, the framework guarantees safety, etc.)
   - Use evidence: read the relevant code, check documentation, web search if needed.
4. **Summarize for the user**: What you fixed, what you disputed, and why.
5. **Immediately proceed to Step 5** — do NOT ask the user whether to continue. Always send the updated code back to Codex for re-review.

## Step 5: Continue the Debate (Rounds 2+)

Run the runner again with `--thread-id` for resume:

```bash
RUNNER="${CODEX_RUNNER:-$HOME/.local/bin/codex-runner.sh}"
NEED_INSTALL=0
if [ -n "$CODEX_RUNNER" ] && test -x "$CODEX_RUNNER"; then
  if ! grep -q 'CODEX_RUNNER_VERSION="1"' "$CODEX_RUNNER" 2>/dev/null; then NEED_INSTALL=1; fi
elif ! test -x "$RUNNER"; then NEED_INSTALL=1
elif ! grep -q 'CODEX_RUNNER_VERSION="1"' "$RUNNER" 2>/dev/null; then NEED_INSTALL=1
fi
if [ "$NEED_INSTALL" = 1 ]; then
  mkdir -p "$HOME/.local/bin"
  TMP=$(mktemp "$HOME/.local/bin/codex-runner.XXXXXX")
  cat > "$TMP" <<'RUNNER_SCRIPT'
<PASTE FULL SCRIPT FROM ABOVE>
RUNNER_SCRIPT
  chmod +x "$TMP"
  mv "$TMP" "$HOME/.local/bin/codex-runner.sh"
  RUNNER="$HOME/.local/bin/codex-runner.sh"
fi
"$RUNNER" --working-dir <WORKING_DIR> --effort <EFFORT> --thread-id <THREAD_ID> <<'EOF'
<REBUTTAL_PROMPT>
EOF
```

### Rebuttal Prompt Template

```
This is Claude Code (Claude Opus 4.6) responding to your review. I have applied fixes and want you to re-review.

## Issues Fixed
<For each fixed issue, reference by ISSUE-{N} and describe the specific change made>

## Issues Disputed
<For each disputed issue, reference by ISSUE-{N} and explain why with evidence>

## Your Turn
Run `git diff HEAD` again to see the updated changes (or `git diff --cached` plus `git diff` if this is a fresh repo with no commits), then re-review.
- Have your previous concerns been properly addressed?
- Do the fixes introduce any NEW issues?
- Are there any remaining problems you still see?

Use the same output format as before (ISSUE-{N} structure + VERDICT).
Verdict options: REJECT | APPROVE_WITH_CHANGES | APPROVE
```

**After each Codex response:**
1. Summarize Codex's response for the user.
2. If verdict is `APPROVE` → proceed to Step 6.
3. If verdict is `APPROVE_WITH_CHANGES` → evaluate suggestions, apply if valid, then **automatically** send one more round to Codex for confirmation. Do NOT ask the user.
4. If verdict is `REJECT` → fix remaining issues and **automatically** continue to next round. Do NOT ask the user.

**IMPORTANT**: The debate loop is fully automatic. After fixing issues, ALWAYS send the updated code back to Codex without asking the user. The loop only stops when Codex returns `APPROVE`. The user is only consulted at the very end (Step 6) or if a stalemate is detected.

### Early Termination & Round Extension

- **Early termination**: If Codex returns `APPROVE`, end the debate immediately and proceed to Step 6.
- **Round extension**: There is no hard round limit. Continue the fix → re-review loop until either:
  - Codex returns `APPROVE`, OR
  - The same points go back and forth without progress for 2 consecutive rounds (stalemate detected) → present the disagreement to the user and let them decide.

**Repeat** Steps 4-5 until consensus or stalemate.

## Step 6: Finalize and Report

Present the user with a **Code Review Debate Summary**:

```
## Code Review Debate Summary

### Rounds: X
### Final Verdict: [CONSENSUS REACHED / STALEMATE - USER DECISION NEEDED]

### Bugs Fixed:
1. [Bug description - file:line]
...

### Edge Cases Added:
1. [Edge case - file:line]
...

### Error Handling Improved:
1. [What was added - file:line]
...

### Security Issues Resolved:
1. [Issue - file:line]
...

### Plan Deviations Found:
1. [Deviation - context]
...

### Disputed Points (Claude's position maintained):
1. [Point - reasoning]
...

### Remaining Concerns (if stalemate):
1. [Unresolved issue - context]
...
```

Then ask the user (via `AskUserQuestion`):
- **Accept & Commit** - Code is ready, user can commit
- **Request more rounds** - Continue debating specific concerns
- **Review changes manually** - User wants to inspect the fixes themselves before deciding

## Important Rules

1. **Codex reads the diff and plan itself** - Do NOT paste diff content or plan content into the prompt. Just give Codex the plan file path and instruct it to run `git diff`.
2. **Only send what Codex can't access** - The prompt should contain: file paths, user's original request, session context. NOT: diffs, file contents, code snippets.
3. **Always `git add -N` untracked files first** - So new files appear in `git diff`.
4. **Always use heredoc (`<<'EOF'`) for prompts** - Heredoc with single-quoted delimiter prevents shell expansion.
5. **Always provide the plan file path** - So Codex can cross-reference implementation against intent. If no plan exists, explicitly state that.
6. **No `-m` flag** - Always use Codex's default model.
7. **Resume by thread ID** - Use the `thread_id` from the runner output JSON for subsequent rounds.
8. **Handle repos with no HEAD** - Before running `git diff HEAD`, check `git rev-parse --verify HEAD`. If HEAD doesn't exist, use `git diff --cached` + `git diff` instead.
9. **Claude Code does all the fixing** - Codex identifies issues, Claude Code applies fixes.
10. **Be genuinely adversarial** - Don't blindly accept all of Codex's findings. Push back with evidence when Codex is wrong.
11. **Don't over-fix** - Only fix what's actually broken or risky. Don't add defensive code for impossible scenarios.
12. **Summarize after every round** - The user should always know what happened before the next round begins.
13. **Respect the diff boundary** - Only review and fix code within the uncommitted changes.
14. **Require structured output** - If Codex's response doesn't follow the ISSUE-{N} format, ask it to reformat in the resume prompt.

## Error Handling

- If `git status --porcelain` shows no changes, inform the user and stop.
- If `git rev-parse --verify HEAD` fails, use `git diff --cached` + `git diff` instead of `git diff HEAD`.
- If the runner exits with code `2` (timeout), inform the user and ask if they want to retry.
- If the runner exits with code `3` (turn failed), report the error from stderr.
- If the runner exits with code `4` (stalled), ask the user whether to retry or abort.
- If the runner exits with code `5` (codex not found), tell the user to install the Codex CLI.
- If the diff is too large for a single prompt, suggest splitting by file or directory.
- If the debate stalls on a point, present both positions to the user and let them decide.
