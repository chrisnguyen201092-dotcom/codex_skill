---
name: codex-impl-review
description: Have Codex CLI review uncommitted code changes or branch diff against a base branch. Claude applies valid fixes, rebuts invalid points, and iterates until consensus or user-approved stalemate.
---

# Codex Implementation Review

## Purpose
Use this skill to run adversarial review on uncommitted changes before commit, or on branch changes before merge.

## When to Use
After writing code, before committing. Use for uncommitted working-tree changes or comparing a branch against base. For security-sensitive code, run `/codex-security-review` alongside this.

## Prerequisites
- **Working-tree mode** (default): working tree has staged or unstaged changes.
- **Branch mode**: current branch differs from base branch (has commits not in base).

## Runner

```bash
RUNNER="{{RUNNER_PATH}}"
SKILLS_DIR="{{SKILLS_DIR}}"
```

## Stdin Format

**JSON stdin** (`render`, `finalize`) — use heredoc with **quoted** delimiter:
```bash
PROMPT=$(node "$RUNNER" render --skill codex-impl-review --template working-tree-round1 --skills-dir "$SKILLS_DIR" <<'RENDER_EOF'
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
PROMPT=$(node "$RUNNER" render --skill codex-impl-review --template working-tree-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
RENDER_EOF
)
```
- If value is a simple literal (paths, fixed strings without `"`, `\`, newlines) → can inline directly in **quoted** heredoc (`<<'RENDER_EOF'`): `{"BASE_BRANCH":"main","verdict":"APPROVE"}`

**Plain text stdin** (`start`, `resume`) — use `printf '%s'`, **NOT** `echo`:
```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```
- `echo` interprets `\n`, `\t`, `-n`, `-e` → corrupts output. `printf '%s'` preserves content.

**Forbidden characters in JSON values**: NULL byte (`\x00`) — truncates stdin.

## Workflow
1. **Collect inputs**: Auto-detect context and announce defaults before asking anything.
   - **scope** (detected first): Run `git status --short | grep -v '^??'` — non-empty output → `working-tree`. Else run `git rev-list @{u}..HEAD` — non-empty → `branch`. If both conditions true, use `working-tree`. If neither, ask user.
   - **effort** (adapts to detected scope): If scope=`branch`, count `git diff --name-only @{u}..HEAD`; else count `git diff --name-only`. Result <10 → `medium`, 10–50 → `high`, >50 → `xhigh`; default `high` if undetectable.
   - Announce: "Detected: scope=`$SCOPE`, effort=`$EFFORT` (N files changed). Proceeding — reply to override scope, effort, or both."
   - Set `SCOPE` and `EFFORT`. Only block for inputs that remain undetectable.
2. Run pre-flight checks (see `references/workflow.md` §1.5).
3. **Init session**: `node "$RUNNER" init --skill-name codex-impl-review --working-dir "$PWD"` → parse `SESSION_DIR` from output `CODEX_SESSION:<path>`.
4. **Render prompt**:
   ```bash
   USER_REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   PROMPT=$(node "$RUNNER" render --skill codex-impl-review --template <template> --skills-dir "$SKILLS_DIR" <<RENDER_EOF
   {"USER_REQUEST":$USER_REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
   RENDER_EOF
   )
   ```
   (template = `working-tree-round1` or `branch-round1`; for branch mode add `BASE_BRANCH_ESCAPED=$(printf '%s' "$BASE_BRANCH" | node -e '...')` and include `"BASE_BRANCH":$BASE_BRANCH_ESCAPED` in the JSON).
5. **Start**: `printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"` → validate JSON `{"status":"started","round":1}`.
6. **Poll**: `node "$RUNNER" poll "$SESSION_DIR"` → returns JSON with `status`, `review.blocks`, `review.verdict`, and `activities`. Report **specific activities** from the activities array (e.g. which files Codex is reading, what topic it is analyzing). NEVER report generic "Codex is running" — always extract concrete details.
7. **Apply/Rebut**: Read issues from poll JSON `review.blocks[]` — each has `id`, `title`, `severity`, `category`, `location`, `problem`, `evidence`, `suggested_fix`. Fix valid issues in code; rebut invalid findings with evidence. Use `review.raw_markdown` as fallback.
8. **Render rebuttal**:
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
   (or `rebuttal-branch` + `BASE_BRANCH_ESCAPED` and `"BASE_BRANCH":$BASE_BRANCH_ESCAPED` for branch mode).
9. **Resume**: `printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"` → validate JSON. **Go back to step 6 (Poll).** Repeat steps 6→7→8→9 until `review.verdict.status === "APPROVE"`, stalemate, or hard cap (5 rounds).
10. **Finalize**:
    ```bash
    node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
    {"verdict":"...","scope":"..."}
    FINALIZE_EOF
    ```
11. **Cleanup**: `node "$RUNNER" stop "$SESSION_DIR"`. Return final review summary, residual risks, and recommended next steps.

### Effort Level Guide
| Level    | Depth             | Best for                        | Typical time |
|----------|-------------------|---------------------------------|-------------|
| `low`    | Surface check     | Quick sanity check              | ~2-3 min |
| `medium` | Standard review   | Most day-to-day work            | ~5-8 min |
| `high`   | Deep analysis     | Important features              | ~10-15 min |
| `xhigh`  | Exhaustive        | Critical/security-sensitive     | ~20-30 min |

## Required References
- Detailed execution: `references/workflow.md`
- Prompt templates: `references/prompts.md`
- Output contract: `references/output-format.md`

## Rules
- If invoked during Claude Code plan mode, exit plan mode first — this skill requires code editing.
- Codex reviews only; it does not edit files.
- Preserve functional intent unless fix requires behavior change.
- Every accepted issue must map to a concrete code diff.
- If stalemate persists, present both sides and defer to user.
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
