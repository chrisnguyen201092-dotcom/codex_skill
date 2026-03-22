---
name: codex-pr-review
description: Peer debate between Claude Code and Codex on PR quality and merge readiness. Both sides review independently, then debate until consensus — no code modifications made.
---

# Codex PR Review

## Purpose
Use this skill to run peer debate on branch changes before merge — covering code quality, PR description, commit hygiene, scope, and merge readiness. Claude and Codex are equal analytical peers — Claude orchestrates the debate loop and final synthesis. No code is modified.

## When to Use
Before opening or merging a pull request. Covers branch diff, commit history, and PR description together in one pass — more thorough than `/codex-impl-review` for pre-merge scenarios.

## Prerequisites
- Current branch differs from base branch (has commits not in base).
- `git diff <base>...HEAD` produces output.

## Runner

```bash
RUNNER="{{RUNNER_PATH}}"
SKILLS_DIR="{{SKILLS_DIR}}"
```

## Stdin Format

**JSON stdin** (`render`, `finalize`) — use heredoc with **quoted** delimiter:
```bash
PROMPT=$(node "$RUNNER" render --skill codex-pr-review --template round1 --skills-dir "$SKILLS_DIR" <<'RENDER_EOF'
{"KEY":"value","OTHER":"value"}
RENDER_EOF
)
```
- Inside heredoc `<<'RENDER_EOF'`: characters `'`, `$`, `` ` `` are safe (shell does not expand)
- JSON values must be properly escaped: `"` → `\"`, `\` → `\\`, newline → `\n`, tab → `\t`
- **NEVER** use `echo '...'` — `'` characters in values will break shell quoting

**When JSON contains dynamic data** (USER_REQUEST, SESSION_CONTEXT, DIFF_CONTEXT, PR_DESCRIPTION, COMMIT_MESSAGES, CLAUDE_ANALYSIS, FIXED_ITEMS, DISPUTED_ITEMS, etc.):
- Dynamic data MUST be JSON-escaped before embedding in heredoc
- Use Node.js one-liner: `ESCAPED=$(printf '%s' "$RAW" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')`
- Result `$ESCAPED` already includes outer quotes (`"..."`) → embed directly into JSON
- Use **unquoted** heredoc (`<<RENDER_EOF`) so shell expands `$ESCAPED`
- Full example:
```bash
DESC_ESCAPED=$(printf '%s' "$PR_DESCRIPTION" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PWD_ESCAPED=$(printf '%s' "$PWD" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-pr-review --template round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"WORKING_DIR":$PWD_ESCAPED,"PR_DESCRIPTION":$DESC_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
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
1. **Collect inputs**: Auto-detect context and announce defaults before asking anything.
   - **effort**: Run `git diff --name-only <base>...HEAD | wc -l` — result <10 → `medium`, 10–50 → `high`, >50 → `xhigh`; default `high` if undetectable.
   - **base-branch**: Check `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null` (strip `refs/remotes/origin/` prefix); fallback to checking existence of `main` then `master`. If found, announce as detected default.
   - Announce: "Detected: base=`$BASE`, effort=`$EFFORT` (N files changed). Proceeding — reply to override. PR title/description optional."
   - Set `BASE` and `EFFORT`. Only block if base branch cannot be resolved.
2. Run pre-flight checks (see `references/workflow.md` §1.5).
3. Init session: `node "$RUNNER" init --skill-name codex-pr-review --working-dir "$PWD"` → parse `SESSION_DIR`.
4. Render Codex prompt: use heredoc with dynamic JSON escaping (PR_DESCRIPTION, USER_REQUEST, SESSION_CONTEXT, COMMIT_LIST are dynamic) — see `## Stdin Format` above. Template: `round1`.
5. Start Codex (background): `printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"` → JSON. **Do NOT poll yet — proceed to step 6.**
6. **Claude Independent Analysis**: Render Claude analysis prompt using heredoc with dynamic JSON escaping (PR_DESCRIPTION, COMMIT_LIST are dynamic). Template: `claude-analysis`. **INFORMATION BARRIER** — do NOT read Codex output until Claude's analysis is complete. See `references/workflow.md` Step 2.5.
7. Poll: `node "$RUNNER" poll "$SESSION_DIR"` — returns JSON with `status`, `review.blocks`, `review.overall_assessment`, `review.verdict`, and `activities`. Report **specific activities** from the activities array. NEVER report generic "Codex is running" — always extract concrete details.
8. **Cross-Analysis**: Parse `review.blocks` and `review.overall_assessment` from poll JSON. Compare Claude's FINDING-{N} with Codex's ISSUE-{N}. Identify genuine agreements, genuine disagreements, and unique findings from each side. See `references/workflow.md` Step 4.
9. Render round2+ prompt: use heredoc with dynamic JSON escaping (SESSION_CONTEXT, AGREED_POINTS, DISAGREED_POINTS, NEW_FINDINGS are dynamic). Template: `round2+`.
10. **Resume**: `printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"` → validate JSON. **Go back to step 7 (Poll).** Repeat steps 7→8→9→10 until consensus, stalemate, or hard cap (5 rounds).
11. Finalize: `node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"...","scope":"branch"}
FINALIZE_EOF`. Present consensus report + **Merge Readiness Scorecard** + **MERGE / REVISE / REJECT** recommendation. **NEVER edit code.**
12. Cleanup: `node "$RUNNER" stop "$SESSION_DIR"`. Return final review summary, residual risks, and recommended next steps.

### Effort Level Guide
| Level    | Depth             | Best for                        | Typical time |
|----------|-------------------|---------------------------------|--------------|
| `low`    | Surface check     | Quick sanity check              | ~2-4 min     |
| `medium` | Standard review   | Most day-to-day work            | ~5-10 min    |
| `high`   | Deep analysis     | Important features              | ~10-15 min   |
| `xhigh`  | Exhaustive        | Critical/security-sensitive     | ~20-30 min   |

## Required References
- Detailed execution: `references/workflow.md`
- Prompt templates: `references/prompts.md`
- Output contract: `references/output-format.md`
- Claude analysis format: `references/claude-analysis-template.md`

## Rules
- **Safety**: NEVER run `git commit`, `git add`, `git rebase`, or any command that modifies code or history. This skill is debate-only.
- Both Claude and Codex are equal peers — no reviewer/implementer framing.
- **Information barrier**: Claude MUST complete independent analysis (Step 6) before reading Codex output. This prevents anchoring bias.
- **NEVER edit code or create commits** — only debate quality and assess merge readiness. The final output is a consensus report + merge readiness scorecard, not a fix.
- Codex reviews only; it does not edit files.
- If stalemate persists (same unresolved points for 2 consecutive rounds), present both sides, produce Merge Readiness Scorecard from agreed findings, and defer to user.
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
