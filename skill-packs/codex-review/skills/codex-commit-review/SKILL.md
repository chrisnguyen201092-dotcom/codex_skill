---
name: codex-commit-review
description: Peer debate between Claude Code and Codex on commit message quality. Both sides review independently, then debate until consensus — no modifications made.
---

# Codex Commit Review

## Purpose
Use this skill to debate commit message quality before or after committing. Claude and Codex are equal analytical peers — Claude orchestrates the debate loop and final synthesis. No commit messages are modified.

## When to Use
After staging changes (draft mode) or after committing (last mode). Use to verify commit message quality and alignment with the actual diff before push.

## Prerequisites
- **Draft mode**: user provides draft commit message text. Staged changes available for alignment check.
- **Last mode**: recent commits exist (`git log -n N`). Repository has commit history.

## Runner

```bash
RUNNER="{{RUNNER_PATH}}"
SKILLS_DIR="{{SKILLS_DIR}}"
```

## Stdin Format

**JSON stdin** (`render`, `finalize`) — use heredoc with **quoted** delimiter:
```bash
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template draft-round1 --skills-dir "$SKILLS_DIR" <<'RENDER_EOF'
{"KEY":"value","OTHER":"value"}
RENDER_EOF
)
```
- Inside heredoc `<<'RENDER_EOF'`: characters `'`, `$`, `` ` `` are safe (shell does not expand)
- JSON values must be properly escaped: `"` → `\"`, `\` → `\\`, newline → `\n`, tab → `\t`
- **NEVER** use `echo '...'` — `'` characters in values will break shell quoting

**When JSON contains dynamic data** (COMMIT_MESSAGES, COMMIT_DIFFS, SESSION_CONTEXT, CLAUDE_ANALYSIS, etc.):
- Dynamic data MUST be JSON-escaped before embedding in heredoc
- Use Node.js one-liner: `ESCAPED=$(printf '%s' "$RAW" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')`
- Result `$ESCAPED` already includes outer quotes (`"..."`) → embed directly into JSON
- Use **unquoted** heredoc (`<<RENDER_EOF`) so shell expands `$ESCAPED`
- Full example:
```bash
MSGS_ESCAPED=$(printf '%s' "$COMMIT_MESSAGES" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
DIFFS_ESCAPED=$(printf '%s' "$COMMIT_DIFFS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template draft-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$MSGS_ESCAPED,"DIFF_CONTEXT":$DIFFS_ESCAPED}
RENDER_EOF
)
```
- If value is a simple literal (paths, fixed strings without `"`, `\`, newlines) → can inline directly in **quoted** heredoc (`<<'RENDER_EOF'`): `{"verdict":"consensus"}`

**Plain text stdin** (`start`, `resume`) — use `printf '%s'`, **NOT** `echo`:
```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```
- `echo` interprets `\n`, `\t`, `-n`, `-e` → corrupts output. `printf '%s'` preserves content.

**Forbidden characters in JSON values**: NULL byte (`\x00`) — truncates stdin.

## Workflow
1. **Collect inputs**: Auto-detect context and announce defaults before asking anything.
   - **mode**: Run `git diff --cached --quiet`; exit 1 → `draft` (staged changes); exit 0 → `last` (no staged); other → ask user.
   - **effort**: Default `medium` for commit-review (commits are typically small scope).
   - Announce: "Detected: mode=`$MODE`, effort=`medium`. Proceeding — reply to override."
   - Set `MODE` and `EFFORT`. For `draft` mode, ask for commit message text. For `last` mode, N=1 default.
2. Run pre-flight checks (see `references/workflow.md` §1.5).
3. **Init**: `node "$RUNNER" init --skill-name codex-commit-review --working-dir "$PWD"` → parse `SESSION_DIR`.
4. **Render Codex prompt** (mode-specific): pipe JSON via heredoc to `node "$RUNNER" render --skill codex-commit-review --template <template> --skills-dir "$SKILLS_DIR"` (template = `draft-round1` or `last-round1`; see Stdin Format — use Branch 2 for dynamic COMMIT_MESSAGES/DIFF_CONTEXT/SESSION_CONTEXT values; last-round1 also needs `"COMMIT_LIST":"..."`).
5. **Start Codex** (background): `printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"` → JSON. **Do NOT poll yet — proceed to Step 6.**
6. **Claude Independent Analysis** (BEFORE reading Codex output): Render Claude analysis prompt via `render --template claude-draft` or `claude-last`. Claude analyzes commit message(s) independently using format from `references/claude-analysis-template.md`. **INFORMATION BARRIER** — do NOT read any Codex output until analysis is complete. See `references/workflow.md` Step 2.5.
7. **Poll**: `node "$RUNNER" poll "$SESSION_DIR"` — returns JSON with `status`, `review.blocks`, `review.overall_assessment`, `review.verdict`, and `activities`. Report **specific activities** from the activities array. NEVER report generic "Codex is running" — always extract concrete details.
8. **Cross-Analysis**: Parse `review.blocks` and `review.overall_assessment` from poll JSON. Compare Claude's FINDING-{N} with Codex's ISSUE-{N}. Identify genuine agreements, genuine disagreements, and unique findings from each side. Use `review.raw_markdown` as fallback. See `references/workflow.md` Step 4.
9. **Render round 2+ prompt**: `render --template draft-round2+` or `last-round2+` with debate state.
10. **Resume**: `printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"` → validate JSON. **Go back to step 7 (Poll).** Repeat steps 7→8→9→10 until CONSENSUS, STALEMATE, or hard cap (5 rounds).
11. **Finalize**: pipe JSON via heredoc to `node "$RUNNER" finalize "$SESSION_DIR"` (see Stdin Format — use quoted heredoc for literal verdict/scope values). Present final consensus report. **NEVER propose revised commit messages.**
12. **Cleanup**: `node "$RUNNER" stop "$SESSION_DIR"`. Return final review summary and `$SESSION_DIR` path.

### Effort Level Guide
| Level    | Depth             | Best for                        | Typical time |
|----------|-------------------|---------------------------------|-------------|
| `low`    | Surface check     | Quick sanity check              | ~1-2 min |
| `medium` | Standard review   | Most day-to-day work            | ~3-5 min |
| `high`   | Deep analysis     | Important features              | ~5-10 min |
| `xhigh`  | Exhaustive        | Critical/security-sensitive     | ~10-15 min |

## Required References
- Detailed execution: `references/workflow.md`
- Prompt templates: `references/prompts.md`
- Output contract: `references/output-format.md`
- Claude analysis format: `references/claude-analysis-template.md`

## Rules
- **Safety**: NEVER run `git commit --amend`, `git rebase`, or any command that modifies commit history. This skill is debate-only.
- Both Claude and Codex are equal peers — no reviewer/implementer framing.
- **Information barrier**: Claude MUST complete independent analysis (Step 6) before reading Codex output. This prevents anchoring bias.
- **NEVER propose revised commit messages** — only debate quality. The final output is a consensus report, not a fix.
- Codex reviews message quality only; it does not review code.
- Discover project conventions before reviewing (see `references/workflow.md` §1.6).
- For `last` mode with N > 1: findings must reference specific commit SHA/subject in Evidence.
- If stalemate persists (same unresolved points for 2 consecutive rounds), present both sides and defer to user.
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
