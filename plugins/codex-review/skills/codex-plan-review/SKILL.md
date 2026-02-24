---
name: codex-plan-review
description: Debate implementation plans between Claude Code and Codex CLI. After Claude Code creates a plan, invoke this skill to have Codex review it. Both AIs debate through multiple rounds until reaching full consensus before implementation begins.
---

# Codex Plan Review — Skill Guide

## Overview
This skill orchestrates an adversarial debate between Claude Code and OpenAI Codex CLI to stress-test implementation plans. The goal is to catch flaws, blind spots, and improvements **before** any code is written.

**Flow:** Claude Code's plan → Codex reviews → Claude Code rebuts → Codex rebuts → ... → Consensus → Implement

## Prerequisites
- You (Claude Code) must already have a plan ready. If no plan exists yet, ask the user to create one first (e.g., via plan mode or `/plan`).
- The plan must be saved to a file that Codex can read (e.g., `plan.md`, `.claude/plan.md`, or the plan mode output file).
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

## Step 2: Prepare the Plan

1. Ensure the plan is saved to a file in the project directory. If the plan only exists in conversation, write it to a file first (e.g., `.claude/plan.md`).
2. Note the **absolute path** to the plan file — you will pass this path to Codex so it can read the file itself.
3. **Do NOT paste the plan content into the Codex prompt.** Codex will read the file directly.

## Prompt Construction Principle

**Only include in the Codex prompt what Codex cannot access on its own:**
- The path to the plan file (so Codex knows where to read it)
- The user's original request / task description
- Important context from the conversation: user comments, constraints, preferences, architectural decisions discussed verbally
- Any clarifications or special instructions the user gave

**Do NOT include:**
- The plan content itself (Codex reads the file)
- Code snippets Codex can read from the repo
- Information Codex can derive by reading files

## Step 3: Send Plan to Codex for Review (Round 1)

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
You are participating in a plan review debate with Claude Code (Claude Opus 4.6).

## Your Role
You are the REVIEWER. Your job is to critically evaluate an implementation plan. Be thorough, constructive, and specific.

## Plan Location
Read the implementation plan from: <ABSOLUTE_PATH_TO_PLAN_FILE>

## User's Original Request
<The user's original task/request that prompted this plan>

## Session Context
<Any important context from the conversation that Codex cannot access on its own>

(If there is no additional context beyond the plan file, write "No additional context — the plan file is self-contained.")

## Instructions
1. Read the plan file above.
2. Read any source files referenced in the plan to understand the current codebase state.
3. Analyze the plan and produce your review in the EXACT format below.

## Required Output Format

For each issue found, use this structure:

### ISSUE-{N}: {Short title}
- **Category**: Critical Issue | Improvement | Question
- **Severity**: CRITICAL | HIGH | MEDIUM | LOW
- **Plan Reference**: Step {X} / Section "{name}" / Decision "{name}"
- **Description**: What the problem is, in detail.
- **Why It Matters**: Concrete scenario showing how this causes a real failure, bug, or degraded outcome.
- **Suggested Fix**: Specific proposed change to the plan. (Required for Critical Issue and Improvement. Optional for Question.)

After all issues, provide:

### VERDICT
- **Result**: REJECT | APPROVE_WITH_CHANGES | APPROVE
- **Summary**: 2-3 sentence overall assessment.

Rules:
- Be specific: reference exact steps, file paths, or decisions in the plan.
- Do NOT rubber-stamp the plan. Your value comes from finding real problems.
- Do NOT raise vague concerns without concrete scenarios.
- Every Critical Issue MUST have a Suggested Fix.
```

**After receiving Codex's review**, summarize it for the user before proceeding.

## Step 4: Claude Code Rebuts (Round 1)

After receiving Codex's review, you (Claude Code) must:

1. **Carefully analyze** each ISSUE Codex raised.
2. **Accept valid criticisms** - If Codex found real issues, acknowledge them and update the plan file.
3. **Push back on invalid points** - If you disagree with Codex's assessment, explain why with evidence. Use your own knowledge, web search, or documentation to support your position.
4. **Update the plan file** with accepted changes (use Edit tool).
5. **Summarize** for the user what you accepted, what you rejected, and why.
6. **Immediately proceed to Step 5** — do NOT ask the user whether to continue. Always send the updated plan back to Codex for re-review.

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
This is Claude Code (Claude Opus 4.6) responding to your review.

## Issues Accepted & Fixed
<For each accepted issue, reference by ISSUE-{N} and describe what was changed in the plan>

## Issues Disputed
<For each disputed issue, reference by ISSUE-{N} and explain why with evidence>

## Your Turn
Re-read the plan file (same path as before) to see the updated plan, then re-review.
- Have your previous concerns been properly addressed?
- Do the changes introduce any NEW issues?
- Are there any remaining problems?

Use the same output format as before (ISSUE-{N} structure + VERDICT).
Verdict options: REJECT | APPROVE_WITH_CHANGES | APPROVE
```

**After each Codex response:**
1. Summarize Codex's response for the user.
2. If Codex's verdict is `APPROVE` → proceed to Step 6.
3. If Codex's verdict is `APPROVE_WITH_CHANGES` → address the suggestions, then **automatically** send one more round to Codex for confirmation. Do NOT ask the user.
4. If Codex's verdict is `REJECT` → address the issues and **automatically** continue to next round. Do NOT ask the user.

**IMPORTANT**: The debate loop is fully automatic. After fixing issues or updating the plan, ALWAYS send it back to Codex without asking the user. The loop only stops when Codex returns `APPROVE`. The user is only consulted at the very end (Step 6) or if a stalemate is detected.

### Early Termination & Round Extension

- **Early termination**: If Codex returns `APPROVE`, end the debate immediately and proceed to Step 6.
- **Round extension**: There is no hard round limit. Continue the fix → re-review loop until either:
  - Codex returns `APPROVE`, OR
  - The same points go back and forth without progress for 2 consecutive rounds (stalemate detected) → present the disagreement to the user and let them decide.

**Repeat** Steps 4-5 until consensus or stalemate.

## Step 6: Finalize and Report

After the debate concludes, present the user with a **Debate Summary**:

```
## Debate Summary

### Rounds: X
### Final Verdict: [CONSENSUS REACHED / STALEMATE - USER DECISION NEEDED]

### Key Changes from Debate:
1. [Change 1 - accepted from Codex]
2. [Change 2 - accepted from Codex]
...

### Points Where Claude Prevailed:
1. [Point 1 - Claude's position was maintained]
...

### Points Where Codex Prevailed:
1. [Point 1 - Codex's position was accepted]
...

### Final Plan:
<Path to the updated plan file>
```

Then ask the user (via `AskUserQuestion`):
- **Approve & Implement** - Proceed with the final plan
- **Request more rounds** - Continue debating specific points
- **Modify manually** - User wants to make their own adjustments before implementing

## Step 7: Implementation

If the user approves:
1. Exit plan mode if still in it.
2. Begin implementing the final debated plan.
3. The plan has been stress-tested — implement with confidence.

## Important Rules

1. **Codex reads the plan file itself** - Do NOT paste plan content into the prompt. Just give Codex the file path.
2. **Only send what Codex can't access** - The prompt should contain: file paths, user's original request, session context. NOT: file contents, diffs, code snippets.
3. **Always use heredoc (`<<'EOF'`) for prompts** - Never use `echo "<prompt>" |`. Heredoc with single-quoted delimiter prevents shell expansion.
4. **No `-m` flag** - Always use Codex's default model.
5. **Resume by thread ID** - Use the `thread_id` from the runner output JSON for subsequent rounds.
6. **Never skip the user summary** - After each round, tell the user what happened before continuing.
7. **Be genuinely adversarial** - Don't just accept everything Codex says. Push back when you have good reason to.
8. **Don't rubber-stamp** - If you think Codex missed something, point it out in your rebuttal.
9. **Track the plan evolution** - Update the plan file after each round so Codex always reads the latest version.
10. **Require structured output** - If Codex's response doesn't follow the ISSUE-{N} format, ask it to reformat in the resume prompt.

## Error Handling

- If the runner exits with code `2` (timeout), inform the user and ask if they want to retry with a longer timeout.
- If the runner exits with code `3` (turn failed), report the error message from stderr to the user.
- If the runner exits with code `4` (stalled), ask the user whether to retry or abort.
- If the runner exits with code `5` (codex not found), tell the user to install the Codex CLI.
- If the debate stalls (same points going back and forth without resolution), present the disagreement to the user and let them decide.
