# Runner Protocol Reference

Shared protocol for all codex-review skills. Read on-demand when you need details on commands, polling, error handling, or conventions.

## Stdin Format Rules
- **JSON** -> `render`/`finalize`: heredoc. Literal-only -> `<<'RENDER_EOF'`. Dynamic vars -> escape with `json_esc`, use `<<RENDER_EOF` (unquoted).
- **json_esc output includes quotes** -> embed directly: `{"KEY":$(json_esc "$VAL")}`.
- **Plain text** -> `start`/`resume`: `printf '%s' "$PROMPT" | node "$RUNNER" ...` -- NEVER `echo`.
- **NEVER** `echo '{...}'` for JSON. Forbidden: NULL bytes (`\x00`).

## Session Init
```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name <skill-name> --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```
Validate: `INIT_OUTPUT` must start with `CODEX_SESSION:`. Abort if not.

## Start Round
```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```
Validate JSON: `{"status":"started","round":1}`. If error contains `CODEX_NOT_FOUND` -> tell user to install codex (`npm install -g @openai/codex`).

## Render Prompt
```bash
PROMPT=$(node "$RUNNER" render --skill <skill-name> --template <template> --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"KEY1":$(json_esc "$VAL1"),"KEY2":$(json_esc "$VAL2")}
RENDER_EOF
)
```

## Resume
```bash
printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"
```
Validate JSON. Sandbox mode persists via thread -- do NOT pass `--sandbox` on resume.

## Poll Protocol
```bash
POLL_JSON=$(node "$RUNNER" poll "$SESSION_DIR")
```
**Intervals**: Round 1: 60s, 60s, 30s, 15s+. Round 2+: 30s, 15s+.

Report **specific activities** from `activities` array (e.g. "Codex [45s]: reading src/auth.js"). NEVER report generic "Codex is running".

Continue while `status === "running"`. Stop on `completed|failed|timeout|stalled`.

**CRITICAL**: `status === "completed"` means Codex finished its turn -- it does NOT mean the debate is over. After `completed`, check the skill's Loop Decision table.

## Finalize + Cleanup
```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"..."}
FINALIZE_EOF
node "$RUNNER" stop "$SESSION_DIR"
```
Optionally include `"scope":"..."` and `"issues":{...}` in finalize JSON. Report `$SESSION_DIR` path to user.

**ALWAYS run `finalize` + `stop`**, even on failure/timeout.

## Error Handling
| Status | Action |
|--------|--------|
| `failed` | Retry once -- re-poll after 15s. |
| `timeout` | Report partial results from `review.raw_markdown`, suggest lower effort. Run cleanup. |
| `stalled` + `recoverable === true` | `stop` -> prepend recovery note -> `resume --recovery` -> poll (30s, 15s+). |
| `stalled` + `recoverable === false` | Report partial results, suggest lower effort. Run cleanup. |
| `CODEX_NOT_FOUND` | Tell user to install codex. |

**Cleanup sequencing**: Run `finalize` + `stop` ONLY after recovery resolves (success or second failure). Do NOT finalize before recovery attempt.

## Flavor Text Convention
Load `references/flavor-text.md` at skill start. Pick 1 random message per trigger from matching pool -- never repeat within session. Display as `> {emoji} {message}` blockquote. Replace `{N}`, `{TOTAL}`, `{CHUNK}`, `{ROUND}` with actual values. User can disable with "no flavor" or "skip humor". Only trigger on first poll per round (avoid spam).
