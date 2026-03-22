---
name: codex-parallel-review
description: Parallel independent review by both Claude (4 agents) and Codex, followed by merge, debate on disagreements, and consensus report. No external plugins required.
---

# Codex Parallel Review

## Purpose
5 reviewers analyze the same codebase simultaneously: 4 Claude Code agents (via native Agent tool) + 1 Codex subprocess. Findings are merged, disagreements debated, consensus reported.

## When to Use
When you want independent dual-reviewer analysis. Produces higher-confidence findings than single-reviewer skills because findings are cross-validated between Claude agents and Codex before being reported.

## Prerequisites
- **Full-codebase mode** (default): repository has source files to review.
- **Working-tree mode**: working tree has staged or unstaged changes.
- **Branch mode**: current branch differs from base branch.
- **No external plugins required** — Agent tool is built into Claude Code.

## Runner

```bash
RUNNER="{{RUNNER_PATH}}"
SKILLS_DIR="{{SKILLS_DIR}}"
```

## Stdin Format

**JSON stdin** (`render`, `finalize`) — use heredoc with **quoted** delimiter:
```bash
PROMPT=$(node "$RUNNER" render --skill codex-parallel-review --template full-round1 --skills-dir "$SKILLS_DIR" <<'RENDER_EOF'
{"KEY":"value","OTHER":"value"}
RENDER_EOF
)
```
- Inside heredoc `<<'RENDER_EOF'`: characters `'`, `$`, `` ` `` are safe (shell does not expand)
- JSON values must be properly escaped: `"` → `\"`, `\` → `\\`, newline → `\n`, tab → `\t`
- **NEVER** use `echo '...'` — `'` characters in values will break shell quoting

**When JSON contains dynamic data** (USER_REQUEST, SESSION_CONTEXT, DIFF_CONTEXT, CLAUDE_ANALYSIS, CODEX_FINDINGS, AGREED_ITEMS, DISPUTED_ITEMS, CODEX_ONLY_WITH_REBUTTALS, CLAUDE_ONLY_FINDINGS, CONTRADICTIONS, etc.):
- Dynamic data MUST be JSON-escaped before embedding in heredoc
- Use Node.js one-liner: `ESCAPED=$(printf '%s' "$RAW" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')`
- Result `$ESCAPED` already includes outer quotes (`"..."`) → embed directly into JSON
- Use **unquoted** heredoc (`<<RENDER_EOF`) so shell expands `$ESCAPED`
- Full example:
```bash
REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-parallel-review --template full-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
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
1. **Collect inputs**: Auto-detect effort and announce default.
   - **effort**: Depends on mode. `full-codebase`: count source files (`find . -type f -name '*.js' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.java' -o -name '*.rb' -o -name '*.c' -o -name '*.cpp' -o -name '*.h' | wc -l`) — <50 → `medium`, 50–200 → `high`, >200 → `xhigh`. `working-tree`/`branch`: use `git diff --name-only | wc -l` — <10 → `medium`, 10–50 → `high`, >50 → `xhigh`; default `high`.
   - Announce: "Detected: effort=`$EFFORT` (N files changed). Proceeding — reply to override effort. Review mode: `full-codebase` (default) / `working-tree` / `branch`."
   - Set `EFFORT`. Ask `MODE` only if user doesn't confirm default.
2. **Launch all 5 reviewers in ONE message** (true parallelism):
   - Init session: `INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-parallel-review --working-dir "$PWD")`, extract `SESSION_DIR`.
   - Render Codex prompt: use heredoc with dynamic JSON escaping (USER_REQUEST, SESSION_CONTEXT are dynamic) — see `## Stdin Format` above. Template depends on mode: `full-round1`, `working-tree-round1`, or `branch-round1` (branch-round1 also needs `"BASE_BRANCH":"main"` in JSON).
   - Start Codex: `printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"` — validates JSON output `{ "status": "started" }`.
   - Spawn 4 `code-reviewer` agents via Agent tool with `run_in_background: true` (see `references/workflow.md` Step 2b for exact Agent tool JSON).
3. **Poll Codex + collect agent results**: `node "$RUNNER" poll "$SESSION_DIR"` — returns JSON with `status`, `review.blocks`, `review.verdict`, and `activities`. Report **specific activities** from the activities array. NEVER report generic "Codex is running". Collect agent results as they finish.
4. **Merge**: deduplicate Claude agents' findings, cross-match vs Codex. Codex issues from `poll_json.review.blocks[]`. Categorize: agreed / claude-only / codex-only / contradictions.
5. **Apply agreed issues**: fix agreed issues in code.
6. **Render debate prompt**: use heredoc with dynamic JSON escaping (CODEX_ONLY_WITH_REBUTTALS, CLAUDE_ONLY_FINDINGS, CONTRADICTIONS are dynamic) — see `## Stdin Format` above. Template: `debate`.
7. **Resume**: `printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"` → validate JSON. **Go back to step 3 (Poll).** Repeat steps 3→4→5→6→7 until resolved, stalemate, or `MAX_ROUNDS` (default 3).
8. **Final Report + Finalize**: consensus report with review stats. Finalize: `node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"...","scope":"..."}
FINALIZE_EOF`.
9. **Cleanup**: `node "$RUNNER" stop "$SESSION_DIR"` — returns JSON. Always run regardless of outcome.

### Effort Level Guide
| Level    | Depth             | Best for                        | Typical time |
|----------|-------------------|---------------------------------|--------------|
| `low`    | Surface check     | Quick sanity check              | ~5-10 min    |
| `medium` | Standard review   | Most day-to-day work            | ~10-20 min   |
| `high`   | Deep analysis     | Important features              | ~20-30 min   |
| `xhigh`  | Exhaustive        | Critical/security-sensitive     | ~30-45 min   |

## Required References
- Detailed execution + Agent tool JSON: `references/workflow.md`
- Prompt templates: `references/prompts.md`
- Output contract: `references/output-format.md`

## Rules
- All 4 Claude agents and Codex review independently — no cross-contamination before merge.
- Codex reviews only; it does not edit files.
- Claude applies fixes for agreed and accepted issues.
- Max debate rounds enforced (default 3); user can override.
- On stalemate, present both sides and defer to user.
- If agents or Codex fail, degrade gracefully (see workflow.md Error Handling).
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
