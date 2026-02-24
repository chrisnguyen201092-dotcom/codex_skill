#!/usr/bin/env bash
set -euo pipefail

# IMPORTANT: Bump CODEX_RUNNER_VERSION when changing this script.
# embed-runner.sh checks this version string across all embed locations.
CODEX_RUNNER_VERSION="1"

# --- Defaults ---
WORKING_DIR=""
EFFORT="high"
THREAD_ID=""
TIMEOUT=540
POLL_INTERVAL=15

# --- Exit codes ---
EXIT_SUCCESS=0
EXIT_ERROR=1
EXIT_TIMEOUT=2
EXIT_TURN_FAILED=3
EXIT_STALLED=4
EXIT_CODEX_NOT_FOUND=5

# --- Parse arguments ---
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

# --- Validate ---
if [[ -z "$WORKING_DIR" ]]; then
  echo "Error: --working-dir is required" >&2
  exit $EXIT_ERROR
fi
if ! command -v codex &>/dev/null; then
  echo "Error: codex CLI not found in PATH" >&2
  exit $EXIT_CODEX_NOT_FOUND
fi

# --- Read prompt from stdin ---
PROMPT=$(cat)
if [[ -z "$PROMPT" ]]; then
  echo "Error: no prompt provided on stdin" >&2
  exit $EXIT_ERROR
fi

# --- Temp files ---
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

# --- Build and launch Codex command ---
CODEX_PID=""

if [[ -n "$THREAD_ID" ]]; then
  # Resume mode: codex exec resume does not support --sandbox or -C flags.
  # The sandbox setting from the initial session is preserved automatically.
  cd "$WORKING_DIR"
  echo "$PROMPT" | codex exec --skip-git-repo-check --json resume "$THREAD_ID" \
    > "$JSONL_FILE" 2>"$ERR_FILE" &
  CODEX_PID=$!
else
  # Initial mode: use -C and --sandbox
  echo "$PROMPT" | codex exec --skip-git-repo-check --json \
    --sandbox read-only \
    --config model_reasoning_effort="$EFFORT" \
    -C "$WORKING_DIR" \
    > "$JSONL_FILE" 2>"$ERR_FILE" &
  CODEX_PID=$!
fi

# --- Poll loop ---
ELAPSED=0
STALL_COUNT=0
LAST_LINE_COUNT=0

while true; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  # Check timeout
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Error: timeout after ${TIMEOUT}s" >&2
    kill "$CODEX_PID" 2>/dev/null || true
    exit $EXIT_TIMEOUT
  fi

  # Check if process is still running
  if ! kill -0 "$CODEX_PID" 2>/dev/null; then
    # Process exited — check results below
    wait "$CODEX_PID" 2>/dev/null || true
    CODEX_PID=""
    break
  fi

  # Count lines for stall detection
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

  # Stall detection: 12 polls * 15s = 3 minutes
  if [[ $STALL_COUNT -ge 12 ]]; then
    echo "Error: stalled — no new output for ~3 minutes" >&2
    kill "$CODEX_PID" 2>/dev/null || true
    exit $EXIT_STALLED
  fi

  # Report progress to stderr
  if [[ -f "$JSONL_FILE" ]]; then
    LAST_EVENT=$(tail -1 "$JSONL_FILE" 2>/dev/null || true)
    if [[ -n "$LAST_EVENT" ]]; then
      EVENT_TYPE=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('type',''))" 2>/dev/null || true)

      case "$EVENT_TYPE" in
        turn.completed)
          # Codex finished — break out to extract
          wait "$CODEX_PID" 2>/dev/null || true
          CODEX_PID=""
          break
          ;;
        turn.failed)
          ERROR_MSG=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('error',{}).get('message','unknown error'))" 2>/dev/null || true)
          echo "Error: Codex turn failed: $ERROR_MSG" >&2
          wait "$CODEX_PID" 2>/dev/null || true
          CODEX_PID=""
          exit $EXIT_TURN_FAILED
          ;;
        turn.started)
          echo "Codex is thinking..." >&2
          ;;
        item.completed)
          ITEM_TYPE=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('type',''))" 2>/dev/null || true)
          case "$ITEM_TYPE" in
            reasoning)
              REASONING_TEXT=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('text',''))" 2>/dev/null || true)
              echo "Codex thinking: $REASONING_TEXT" >&2
              ;;
            command_execution)
              CMD=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('command',''))" 2>/dev/null || true)
              echo "Codex ran: $CMD" >&2
              ;;
          esac
          ;;
        item.started)
          ITEM_TYPE=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('type',''))" 2>/dev/null || true)
          if [[ "$ITEM_TYPE" == "command_execution" ]]; then
            CMD=$(echo "$LAST_EVENT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('command',''))" 2>/dev/null || true)
            echo "Codex running: $CMD" >&2
          fi
          ;;
      esac
    fi
  fi
done

# --- Process exited: check for turn.completed ---
if [[ ! -f "$JSONL_FILE" ]]; then
  echo "Error: no JSONL output file found" >&2
  if [[ -f "$ERR_FILE" ]]; then
    cat "$ERR_FILE" >&2
  fi
  exit $EXIT_ERROR
fi

# Check for turn.failed that we might have missed
if grep -q '"type":"turn.failed"' "$JSONL_FILE" 2>/dev/null; then
  ERROR_MSG=$(grep '"type":"turn.failed"' "$JSONL_FILE" | tail -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('error',{}).get('message','unknown error'))" 2>/dev/null || true)
  echo "Error: Codex turn failed: $ERROR_MSG" >&2
  exit $EXIT_TURN_FAILED
fi

# Check for turn.completed
if ! grep -q '"type":"turn.completed"' "$JSONL_FILE" 2>/dev/null; then
  echo "Error: Codex process exited without turn.completed" >&2
  if [[ -f "$ERR_FILE" ]] && [[ -s "$ERR_FILE" ]]; then
    echo "Stderr:" >&2
    cat "$ERR_FILE" >&2
  fi
  exit $EXIT_ERROR
fi

# --- Extract results ---
# Thread ID
EXTRACTED_THREAD_ID=$(grep '"thread_id"' "$JSONL_FILE" 2>/dev/null | head -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('thread_id',''))" 2>/dev/null || true)

# Review text: last agent_message
REVIEW_TEXT=$(grep '"type":"agent_message"' "$JSONL_FILE" 2>/dev/null | tail -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('item',{}).get('text',''))" 2>/dev/null || true)

if [[ -z "$REVIEW_TEXT" ]]; then
  echo "Error: no agent_message found in output" >&2
  exit $EXIT_ERROR
fi

if [[ -z "$EXTRACTED_THREAD_ID" ]]; then
  echo "Error: no thread_id found in output" >&2
  exit $EXIT_ERROR
fi

# --- Output structured result ---
# Escape review text for JSON embedding (pass thread_id via env to prevent injection)
REVIEW_JSON=$(THREAD_ID_VAL="$EXTRACTED_THREAD_ID" python3 -c "
import sys, json, os
text = sys.stdin.read()
print(json.dumps({'thread_id': os.environ.get('THREAD_ID_VAL', ''), 'review': text, 'status': 'success'}))
" <<< "$REVIEW_TEXT")

echo "CODEX_RESULT:${REVIEW_JSON}"
exit $EXIT_SUCCESS
