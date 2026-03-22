---
name: codex-codebase-review
description: Review entire codebases (50-500+ files) by chunking into modules, reviewing each chunk in a separate Codex session, then synthesizing cross-cutting findings.
---

# Codex Codebase Review

## Purpose
Review large codebases (50-500+ files) that exceed single-session context limits. Splits codebase into module-based chunks, reviews each in an independent Codex session, then Claude synthesizes cross-cutting findings across modules.

## When to Use
For full codebase audit (50-500+ files). Not for incremental change review — use `/codex-impl-review` for that. Run periodically for architecture/quality sweeps or before major releases.

## Prerequisites
- Source files in working directory.

## Runner

```bash
RUNNER="{{RUNNER_PATH}}"
SKILLS_DIR="{{SKILLS_DIR}}"
```

## Stdin Format

**JSON stdin** (`render`, `finalize`) — use heredoc with **quoted** delimiter:
```bash
PROMPT=$(node "$RUNNER" render --skill codex-codebase-review --template chunk-review --skills-dir "$SKILLS_DIR" <<'RENDER_EOF'
{"KEY":"value","OTHER":"value"}
RENDER_EOF
)
```
- Inside heredoc `<<'RENDER_EOF'`: characters `'`, `$`, `` ` `` are safe (shell does not expand)
- JSON values must be properly escaped: `"` → `\"`, `\` → `\\`, newline → `\n`, tab → `\t`
- **NEVER** use `echo '...'` — `'` characters in values will break shell quoting

**When JSON contains dynamic data** (CHUNK_FILES, MODULE_NAME, SESSION_CONTEXT, CHUNK_FINDINGS, etc.):
- Dynamic data MUST be JSON-escaped before embedding in heredoc
- Use Node.js one-liner: `ESCAPED=$(printf '%s' "$RAW" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')`
- Result `$ESCAPED` already includes outer quotes (`"..."`) → embed directly into JSON
- Use **unquoted** heredoc (`<<RENDER_EOF`) so shell expands `$ESCAPED`
- Full example:
```bash
FILES_ESCAPED=$(printf '%s' "$CHUNK_FILES" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PWD_ESCAPED=$(printf '%s' "$PWD" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-codebase-review --template chunk-review --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"WORKING_DIR":$PWD_ESCAPED,"MODULE_NAME":"auth","CHUNK_FILES":$FILES_ESCAPED}
RENDER_EOF
)
```
- If value is a simple literal (paths, fixed strings without `"`, `\`, newlines) → can inline directly in **quoted** heredoc (`<<'RENDER_EOF'`): `{"verdict":"APPROVE"}`

**Plain text stdin** (`start`, `resume`) — use `printf '%s'`, **NOT** `echo`:
```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```
- `echo` interprets `\n`, `\t`, `-n`, `-e` → corrupts output. `printf '%s'` preserves content.

**Forbidden characters in JSON values**: NULL byte (`\x00`) — truncates stdin.

## Workflow
1. **Collect inputs**: Auto-detect effort and announce default before asking anything.
   - **effort**: Count source files `find . -type f -name '*.js' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.rb' -o -name '*.c' -o -name '*.cpp' -o -name '*.h' | wc -l` — <50 → `medium`, 50-200 → `high`, >200 → `xhigh`; default `high`.
   - Announce: "Detected: effort=`$EFFORT` (N files changed). Proceeding — reply to override."
   - Set `EFFORT`. Also ask: parallel factor (default 3 chunks), focus areas (optional).
2. **Discovery**: detect project type, list source files, identify module boundaries.
3. **Chunking**: group files into 500-2000 line chunks, present chunk plan.
4. **Review loop**: for each chunk — init session, render prompt via `render --template chunk-review`, pipe to `start`, poll JSON output, parse `review.blocks`. Each chunk has its own init/start/poll/finalize cycle. Use `status` to inspect any session at any time.
5. **Cross-cutting analysis**: Claude synthesizes all chunk findings — inconsistencies, API contracts, DRY violations, integration, architecture.
6. **Validation** (effort >= high): init new session, render validation prompt via `render --template validation`, start, poll, parse `RESPONSE-{N}` blocks from `review.format === "codebase-validation"`.
7. **Final report**: overview table, per-module findings, cross-cutting findings, action items. Create master session via init, finalize with aggregated stats.
8. **Cleanup**: stop ALL tracked SESSION_DIRs — always runs regardless of outcome. Each `stop` returns JSON confirmation.

### Effort Level Guide
| Level    | Discovery        | Cross-cutting    | Validation   | Typical time        |
|----------|------------------|------------------|--------------|---------------------|
| `low`    | Auto-detect only | Basic (2 cats)   | Skip         | ~10-20 min/chunk    |
| `medium` | Auto + confirm   | Standard (3 cats)| Skip         | ~15-30 min/chunk    |
| `high`   | Full + confirm   | Full (5 cats)    | 1 round      | ~20-40 min/chunk    |
| `xhigh`  | Full + suggest   | Full + arch      | 2 rounds     | ~30-60 min/chunk    |

## Required References
- Detailed orchestration: `references/workflow.md`
- Prompt templates: `references/prompts.md`
- Output contract: `references/output-format.md`

## Rules
- If invoked during Claude Code plan mode, exit plan mode first — this skill requires code editing.
- Codex reviews only; it does not edit files.
- No cross-contamination between chunk sessions — each chunk is independent.
- Context propagation: only high/critical findings from prior chunks, capped at ~2000 tokens.
- Cleanup always runs — stop every tracked SESSION_DIR regardless of outcome.
- Scope is full codebase only — for diff review use `/codex-impl-review`.
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
- **All runner commands return JSON** (except `version`, `init`, `render`) — always parse structured output, never scrape stderr.
