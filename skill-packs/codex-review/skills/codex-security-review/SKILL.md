---
name: codex-security-review
description: Security-focused code review using OWASP Top 10 and CWE patterns. Detects vulnerabilities, secrets, authentication issues, and security misconfigurations through static analysis.
---

# Codex Security Review

## Purpose
Use this skill to perform security-focused review of code changes, identifying vulnerabilities aligned with OWASP Top 10 2021 and common CWE patterns.

## When to Use
When changes touch auth, crypto, SQL queries, user input processing, file uploads, or external API calls. Use for security-focused pre-commit or pre-merge review. Complements `/codex-impl-review` — run both for sensitive code.

## Prerequisites
- Working directory with source code
- Optional: dependency manifest files (package.json, requirements.txt, go.mod) for supply chain analysis

## Runner

```bash
RUNNER="{{RUNNER_PATH}}"
SKILLS_DIR="{{SKILLS_DIR}}"
```

## Stdin Format

**JSON stdin** (`render`, `finalize`) — use heredoc with **quoted** delimiter:
```bash
PROMPT=$(node "$RUNNER" render --skill codex-security-review --template round1 --skills-dir "$SKILLS_DIR" <<'RENDER_EOF'
{"KEY":"value","OTHER":"value"}
RENDER_EOF
)
```
- Inside heredoc `<<'RENDER_EOF'`: characters `'`, `$`, `` ` `` are safe (shell does not expand)
- JSON values must be properly escaped: `"` → `\"`, `\` → `\\`, newline → `\n`, tab → `\t`
- **NEVER** use `echo '...'` — `'` characters in values will break shell quoting

**When JSON contains dynamic data** (USER_REQUEST, SESSION_CONTEXT, SCOPE_SPECIFIC_INSTRUCTIONS, FIXED_ITEMS, DISPUTED_ITEMS, etc.):
- Dynamic data MUST be JSON-escaped before embedding in heredoc
- Use Node.js one-liner: `ESCAPED=$(printf '%s' "$RAW" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')`
- Result `$ESCAPED` already includes outer quotes (`"..."`) → embed directly into JSON
- Use **unquoted** heredoc (`<<RENDER_EOF`) so shell expands `$ESCAPED`
- Full example:
```bash
SCOPE_ESCAPED=$(printf '%s' "$SCOPE_INSTRUCTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PWD_ESCAPED=$(printf '%s' "$PWD" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
SCOPE_VAL_ESCAPED=$(printf '%s' "$SCOPE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-security-review --template round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"WORKING_DIR":$PWD_ESCAPED,"SCOPE":$SCOPE_VAL_ESCAPED,"SCOPE_SPECIFIC_INSTRUCTIONS":$SCOPE_ESCAPED}
RENDER_EOF
)
```
- If value is a simple literal (paths, fixed strings without `"`, `\`, newlines) → can inline directly in **quoted** heredoc (`<<'RENDER_EOF'`): `{"verdict":"APPROVE"}`

**Nested render** (security-review only): When embedding render output into JSON of another render, MUST JSON-escape first:
```bash
ESCAPED=$(printf '%s' "$RAW_VALUE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
```
Use **unquoted** heredoc (`<<RENDER_EOF`) for the outer render to expand `$ESCAPED`.

**Plain text stdin** (`start`, `resume`) — use `printf '%s'`, **NOT** `echo`:
```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```
- `echo` interprets `\n`, `\t`, `-n`, `-e` → corrupts output. `printf '%s'` preserves content.

**Forbidden characters in JSON values**: NULL byte (`\x00`) — truncates stdin.

## Workflow
1. **Collect inputs**: Auto-detect context and announce defaults before asking anything.
   - **scope** (detected first): Run `git status --short | grep -v '^??'` — non-empty output → `working-tree`. Else run `git rev-list @{u}..HEAD` — non-empty → `branch`. If both conditions true, use `working-tree`. If neither, ask user (offer `full` as option).
   - **effort** (adapts to detected scope): If scope=`branch`, count `git diff --name-only @{u}..HEAD`; else count `git diff --name-only`. Result <10 → `medium`, 10–50 → `high`, >50 → `xhigh`; default `high` if undetectable. For scope=`full`, default `high`.
   - Announce: "Detected: scope=`$SCOPE`, effort=`$EFFORT` (N files changed). Proceeding — reply to override scope, effort, or both."
   - Set `SCOPE` and `EFFORT`. Only block for inputs that remain undetectable.
2. Run pre-flight checks (see `references/workflow.md` §1.5).
3. Render prompt: First render scope-specific template to get scope instructions, then JSON-escape and render round1:
   ```bash
   # Step 1: Render scope instructions
   if [ "$SCOPE" = "branch" ]; then
     BASE_BRANCH_ESCAPED=$(printf '%s' "$BASE_BRANCH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
     SCOPE_INSTRUCTIONS=$(node "$RUNNER" render --skill codex-security-review --template "$SCOPE" --skills-dir "$SKILLS_DIR" <<SCOPE_EOF
   {"BASE_BRANCH":$BASE_BRANCH_ESCAPED}
   SCOPE_EOF
     )
   else
     SCOPE_INSTRUCTIONS=$(node "$RUNNER" render --skill codex-security-review --template "$SCOPE" --skills-dir "$SKILLS_DIR" <<'SCOPE_EOF'
   {}
   SCOPE_EOF
     )
   fi

   # Step 2: JSON-escape rendered output (may contain quotes, newlines)
   ESCAPED_SCOPE=$(printf '%s' "$SCOPE_INSTRUCTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')

   # Step 3: Render round1 — unquoted heredoc to expand $ESCAPED_SCOPE
   PWD_ESCAPED=$(printf '%s' "$PWD" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   SCOPE_VAL_ESCAPED=$(printf '%s' "$SCOPE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   EFFORT_ESCAPED=$(printf '%s' "$EFFORT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   BASE_BRANCH_ESCAPED=$(printf '%s' "$BASE_BRANCH" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   PROMPT=$(node "$RUNNER" render --skill codex-security-review --template round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
   {"WORKING_DIR":$PWD_ESCAPED,"SCOPE":$SCOPE_VAL_ESCAPED,"EFFORT":$EFFORT_ESCAPED,"BASE_BRANCH":$BASE_BRANCH_ESCAPED,"SCOPE_SPECIFIC_INSTRUCTIONS":$ESCAPED_SCOPE}
   RENDER_EOF
   )
   ```
4. Start round 1: `node "$RUNNER" init` → pipe rendered prompt with `printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR"`.
5. Poll: `node "$RUNNER" poll "$SESSION_DIR"` — returns JSON with `status`, `review.blocks`, `review.verdict`, and `activities`. Report **specific activities** from the activities array (e.g. which files Codex is scanning, what vulnerability patterns it's checking). NEVER report generic "Codex is running" — always extract concrete details.
6. Parse `review.blocks` from poll JSON — each block has `id`, `prefix`, `title`, `category`, `severity`, `confidence`, `cwe`, `owasp`, `problem`, `evidence`, `attack_vector`, `suggested_fix`. The verdict includes `risk_summary` with severity counts. Use `review.raw_markdown` as fallback.
7. Fix valid vulnerabilities in code; rebut false positives with evidence.
8. **Render rebuttal**:
   ```bash
   FIXED_ESCAPED=$(printf '%s' "$FIXED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   DISPUTED_ESCAPED=$(printf '%s' "$DISPUTED_ITEMS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   PROMPT=$(node "$RUNNER" render --skill codex-security-review --template round2+ --skills-dir "$SKILLS_DIR" <<RENDER_EOF
   {"FIXED_ITEMS":$FIXED_ESCAPED,"DISPUTED_ITEMS":$DISPUTED_ESCAPED}
   RENDER_EOF
   )
   ```
9. **Resume**: `printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"` → validate JSON. **Go back to step 5 (Poll).** Repeat steps 5→6→7→8→9 until `review.verdict.status === "APPROVE"`, stalemate, or hard cap (5 rounds).
10. **Finalize**:
    ```bash
    node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
    {"verdict":"...","scope":"..."}
    FINALIZE_EOF
    ```
11. **Cleanup**: `node "$RUNNER" stop "$SESSION_DIR"`. Return final security assessment with risk summary and recommended next steps.

### Effort Level Guide
| Level    | Depth             | Best for                        | Typical time |
|----------|-------------------|---------------------------------|--------------|
| `low`    | Common patterns   | Quick security sanity check     | ~3-5 min     |
| `medium` | OWASP Top 10      | Standard security review        | ~8-12 min    |
| `high`   | Deep analysis     | Pre-production security audit   | ~15-20 min   |
| `xhigh`  | Exhaustive        | Critical/regulated systems      | ~25-40 min   |

### Scope Guide
| Scope          | Coverage                           | Best for                    |
|----------------|------------------------------------|-----------------------------|
| `working-tree` | Uncommitted changes only           | Pre-commit security check   |
| `branch`       | Branch diff vs base                | Pre-merge security review   |
| `full`         | Entire codebase                    | Security audit              |

## Required References
- Detailed execution: `references/workflow.md`
- Prompt templates: `references/prompts.md`
- Output contract (incl. Security Categories, Output Format, OWASP coverage): `references/output-format.md`

## Rules
- If invoked during Claude Code plan mode, exit plan mode first — this skill requires code editing.
- Codex reviews only; it does not edit files.
- Mark all findings with confidence level (high/medium/low).
- Provide CWE and OWASP mappings for all vulnerabilities.
- Include attack vector explanation for each finding.
- Every accepted issue must map to a concrete code diff.
- If stalemate persists, present both sides and defer to user.
- Never claim 100% security coverage — static analysis has limits.
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
