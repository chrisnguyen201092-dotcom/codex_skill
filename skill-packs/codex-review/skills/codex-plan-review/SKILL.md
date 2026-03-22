---
name: codex-plan-review
description: Review/debate plans before implementation between Claude Code and Codex CLI.
---

# Codex Plan Review

## Purpose
Use this skill to adversarially review a plan before implementation starts.

## When to Use
After creating a plan but before implementing code. Reviews plan quality — not a substitute for `/codex-impl-review` code review. Typical flow: plan → `/codex-plan-review` → refine → implement.

## Prerequisites
- A Markdown plan file exists (e.g. `plan.md`) with headings for sections, steps, or phases.

## Runner

```bash
RUNNER="{{RUNNER_PATH}}"
SKILLS_DIR="{{SKILLS_DIR}}"
```

## Stdin Format

**JSON stdin** (`render`, `finalize`) — use heredoc with **quoted** delimiter:
```bash
PROMPT=$(node "$RUNNER" render --skill codex-plan-review --template round1 --skills-dir "$SKILLS_DIR" <<'RENDER_EOF'
{"KEY":"value","OTHER":"value"}
RENDER_EOF
)
```
- Inside heredoc `<<'RENDER_EOF'`: characters `'`, `$`, `` ` `` are safe (shell does not expand)
- JSON values must be properly escaped: `"` → `\"`, `\` → `\\`, newline → `\n`, tab → `\t`
- **NEVER** use `echo '...'` — `'` characters in values will break shell quoting

**When JSON contains dynamic data** (USER_REQUEST, SESSION_CONTEXT, FIXED_ITEMS, DISPUTED_ITEMS, etc.):
- Dynamic data MUST be JSON-escaped before embedding in heredoc
- Use Node.js one-liner: `ESCAPED=$(printf '%s' "$RAW" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')`
- Result `$ESCAPED` already includes outer quotes (`"..."`) → embed directly into JSON
- Use **unquoted** heredoc (`<<RENDER_EOF`) so shell expands `$ESCAPED`
- Full example:
```bash
USER_REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-plan-review --template round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"PLAN_PATH":"/abs/path","USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
RENDER_EOF
)
```
- If value is a simple literal (paths, fixed strings without `"`, `\`, newlines) → can inline directly in **quoted** heredoc (`<<'RENDER_EOF'`): `{"PLAN_PATH":"/abs/path","verdict":"APPROVE"}`

**Plain text stdin** (`start`, `resume`) — use `printf '%s'`, **NOT** `echo`:
```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```
- `echo` interprets `\n`, `\t`, `-n`, `-e` → corrupts output. `printf '%s'` preserves content.

**Forbidden characters in JSON values**: NULL byte (`\x00`) — truncates stdin.

## Workflow
1. **Collect inputs**: Auto-detect context and announce defaults before asking anything.
   - **plan-path**: Scan CWD for `plan.md`, `PLAN.md`; also search `docs/` up to 3 levels for `*plan*.md`. If single match → use it. If multiple → list and ask user. If none → ask user for path.
   - **effort**: Default `high` for plan review (plans typically cover significant scope).
   - Announce detected plan path and effort. Proceeding — reply to override.
   - Set `PLAN_PATH` and `EFFORT`. Block only if plan file cannot be found or resolved.
2. Run pre-flight checks (see `references/workflow.md` §1.5).
3. Init session: `node "$RUNNER" init --skill-name codex-plan-review --working-dir "$PWD"` → parse `SESSION_DIR`.
4. Render prompt:
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
5. Start round 1: `printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"` → validate JSON output.
6. Poll: `node "$RUNNER" poll "$SESSION_DIR"` — returns JSON with `status`, `review.blocks`, `review.verdict`, and `activities`. Report **specific activities** from the activities array (e.g. which files Codex is reading, what topic it is analyzing). NEVER report generic "Codex is running" — always extract concrete details.
7. Parse `review.blocks` from poll JSON — each block has `id`, `category`, `severity`, `location`, `problem`, `evidence`, `suggested_fix`. Use `review.raw_markdown` as fallback.
8. Apply valid fixes to the plan, **save the plan file**, rebut invalid points with evidence.
9. Render rebuttal:
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
10. **Resume**: `printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"` → validate JSON. **Go back to step 6 (Poll).** Repeat steps 6→7→8→9→10 until `APPROVE`, stalemate, or hard cap (5 rounds).
11. Finalize:
    ```bash
    node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
    {"verdict":"..."}
    FINALIZE_EOF
    ```
12. Cleanup: `node "$RUNNER" stop "$SESSION_DIR"`. Return final debate summary, residual risks, and final plan path.

### Effort Level Guide
| Level    | Depth             | Best for                        | Typical time |
|----------|-------------------|---------------------------------|--------------|
| `low`    | Surface check     | Quick sanity check              | ~2-3 min     |
| `medium` | Standard review   | Most day-to-day work            | ~5-8 min     |
| `high`   | Deep analysis     | Important features              | ~10-15 min   |
| `xhigh`  | Exhaustive        | Critical/security-sensitive     | ~20-30 min   |

## Required References
- Detailed execution steps: `references/workflow.md`
- Prompt templates: `references/prompts.md`
- Output contract: `references/output-format.md`

## Rules
- If Claude Code plan mode is active, stay in plan mode during the debate. Otherwise, operate normally.
- Do not implement code in this skill.
- Do not claim consensus without explicit `VERDICT: APPROVE` or user-accepted stalemate.
- Preserve traceability: each accepted issue maps to a concrete plan edit.
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
- **No manual file I/O** — Claude NEVER writes files to the session directory. All session state is managed by runner commands (`init`, `start`, `poll`, `resume`, `finalize`, `stop`).
