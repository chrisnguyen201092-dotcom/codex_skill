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
json_esc() { printf '%s' "$1" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))'; }
```

## Stdin Format Rules
- **JSON** → `render`/`finalize`: heredoc. Literal-only → `<<'RENDER_EOF'`. Dynamic vars → escape with `json_esc`, use `<<RENDER_EOF` (unquoted).
- **json_esc output includes quotes** → embed directly: `{"KEY":$(json_esc "$VAL")}`.
- **Plain text** → `start`/`resume`: `printf '%s' "$PROMPT" | node "$RUNNER" ...` — NEVER `echo`.
- **NEVER** `echo '{...}'` for JSON. Forbidden: NULL bytes (`\x00`).

## Workflow

### 1. Collect Inputs
Auto-detect context and announce defaults before asking anything.

**Mode detection**: `git diff --cached --quiet 2>/dev/null` → exit 1 = `draft` (staged changes), exit 0 = `last`, other = ask user. Default effort: `medium`. If `draft`, ask for commit message text. If `last`, N=1 default.

Announce: `"Detected: mode=$MODE, effort=medium. Proceeding — reply to override."`

**Draft inputs**: user-provided commit message text, staged changes (`git diff --cached`).
**Last inputs**: `git log -n "$N" --format='%H%n%B---'` for messages. Clamp N to history (`MAX=$(git rev-list --count HEAD)`; N > MAX → N=MAX; MAX=0 → abort). Diff: `git diff HEAD~"$N"..HEAD` when N < MAX; entire history: `EMPTY_TREE=$(git hash-object -t tree /dev/null) && git diff "$EMPTY_TREE"..HEAD`.

### 2. Pre-flight Checks
Verify git repo (`git rev-parse --show-toplevel`). **Draft**: `git diff --cached --quiet` must FAIL (exit 1) — else abort "no staged changes". **Last**: validate N positive int, `git rev-list --count HEAD` > 0, clamp N, warn if diff empty.

### 3. Convention Discovery
Discover commit conventions (priority order, stop at first match): 1) **User instruction** (explicit). 2) **Repo config**: `git config --local commit.template` — local only. 3) **Repo tooling**: commitlint config (`.commitlintrc*`, `commitlint.config.*`), or `CONTRIBUTING.md`. 4) **Recent history**: `git log -20 --format='%s'` — 80%+ `type:` prefix → Conventional Commits. 5) **Fallback**: Git general guideline. Do NOT assume Conventional Commits without evidence. Store as `PROJECT_CONVENTIONS`.

### 4. Init Session
```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-commit-review --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```
Validate: `INIT_OUTPUT` must start with `CODEX_SESSION:`.

### 5. Render Codex Prompt

**Draft mode** (template `draft-round1`):
```bash
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template draft-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$(json_esc "$COMMIT_MESSAGES"),"DIFF_CONTEXT":$(json_esc "$DIFF_CONTEXT"),"USER_REQUEST":$(json_esc "$USER_REQUEST"),"SESSION_CONTEXT":$(json_esc "$SESSION_CONTEXT"),"PROJECT_CONVENTIONS":$(json_esc "$PROJECT_CONVENTIONS")}
RENDER_EOF
)
```

**Last mode** (template `last-round1` — add `COMMIT_LIST`):
```bash
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template last-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$(json_esc "$COMMIT_MESSAGES"),"DIFF_CONTEXT":$(json_esc "$DIFF_CONTEXT"),"COMMIT_LIST":$(json_esc "$COMMIT_LIST"),"USER_REQUEST":$(json_esc "$USER_REQUEST"),"SESSION_CONTEXT":$(json_esc "$SESSION_CONTEXT"),"PROJECT_CONVENTIONS":$(json_esc "$PROJECT_CONVENTIONS")}
RENDER_EOF
)
```

### 6. Start Round 1
```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```
Validate JSON: `{"status":"started","round":1}`. Error with `CODEX_NOT_FOUND` → tell user to install codex. **Do NOT poll yet — proceed to Step 7.**

### 7. Claude Independent Analysis

**INFORMATION BARRIER**: MUST NOT read any Codex output until analysis is complete.

**Draft** (template `claude-draft`):
```bash
CLAUDE_PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template claude-draft --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$(json_esc "$COMMIT_MESSAGES"),"DIFF_CONTEXT":$(json_esc "$DIFF_CONTEXT"),"PROJECT_CONVENTIONS":$(json_esc "$PROJECT_CONVENTIONS")}
RENDER_EOF
)
```

**Last** (template `claude-last` — add `COMMIT_LIST`):
```bash
CLAUDE_PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template claude-last --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"COMMIT_MESSAGES":$(json_esc "$COMMIT_MESSAGES"),"DIFF_CONTEXT":$(json_esc "$DIFF_CONTEXT"),"COMMIT_LIST":$(json_esc "$COMMIT_LIST"),"PROJECT_CONVENTIONS":$(json_esc "$PROJECT_CONVENTIONS")}
RENDER_EOF
)
```

Read rendered prompt → read diff/messages (draft: `git diff --cached`; last: `git show <SHA>` per commit + aggregate diff) → write FINDING-{N} per `references/claude-analysis-template.md` (last: Evidence MUST reference SHA+subject) → Overall Assessment (Quality, Convention compliance, Accuracy vs diff) → Strongest Positions. **CRITICAL**: Complete BEFORE Step 8.

### 8. Poll
```bash
POLL_JSON=$(node "$RUNNER" poll "$SESSION_DIR")
```
**Poll intervals**: Round 1: 60s, 60s, 30s, 15s+. Round 2+: 30s, 15s+.

Report **specific activities** from `activities` array (e.g. "Codex [45s]: reading git diff --cached, analyzing message structure"). NEVER report generic "Codex is running".

Continue while `status === "running"`. Stop on `completed|failed|timeout|stalled`.

### 9. Cross-Analysis
Parse `review.blocks` (each: `id`, `title`, `severity`, `category`, `location`, `problem`, `evidence`) and `review.overall_assessment` from poll JSON. Verdict in `review.verdict.status`. Fallback: `review.raw_markdown`.

**Compare** Claude FINDING-{N} vs Codex ISSUE-{N}:

| Classification | Meaning |
|---------------|---------|
| Agreement | Both independently found same issue |
| Disagreement | Opposing assessment |
| Claude-only | Claude found, Codex did not |
| Codex-only | Codex found, Claude did not |
| Same Direction, Different Severity | Both found, disagree on severity |

**Build response**: 1) Agreements — merged findings. 2) Disagreements — Claude's position + evaluation of Codex's. 3) New findings — Claude-only + evaluation of Codex-only. 4) Set status: CONTINUE/CONSENSUS/STALEMATE. **Claude orchestration is authoritative** — Codex VERDICT is advisory.

### 10. Render Rebuttal + Resume

**Draft** (template `draft-round2+`):
```bash
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template draft-round2+ --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"SESSION_CONTEXT":$(json_esc "$SESSION_CONTEXT"),"PROJECT_CONVENTIONS":$(json_esc "$PROJECT_CONVENTIONS"),"AGREED_POINTS":$(json_esc "$AGREED_POINTS"),"DISAGREED_POINTS":$(json_esc "$DISAGREED_POINTS"),"NEW_FINDINGS":$(json_esc "$NEW_FINDINGS"),"CONTINUE_OR_CONSENSUS_OR_STALEMATE":$(json_esc "$STATUS"),"DIFF_CONTEXT":$(json_esc "$DIFF_CONTEXT")}
RENDER_EOF
)
```

**Last** (template `last-round2+` — add `COMMIT_LIST`):
```bash
PROMPT=$(node "$RUNNER" render --skill codex-commit-review --template last-round2+ --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"SESSION_CONTEXT":$(json_esc "$SESSION_CONTEXT"),"PROJECT_CONVENTIONS":$(json_esc "$PROJECT_CONVENTIONS"),"AGREED_POINTS":$(json_esc "$AGREED_POINTS"),"DISAGREED_POINTS":$(json_esc "$DISAGREED_POINTS"),"NEW_FINDINGS":$(json_esc "$NEW_FINDINGS"),"CONTINUE_OR_CONSENSUS_OR_STALEMATE":$(json_esc "$STATUS"),"DIFF_CONTEXT":$(json_esc "$DIFF_CONTEXT"),"COMMIT_LIST":$(json_esc "$COMMIT_LIST")}
RENDER_EOF
)
```

Resume: `printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"` → validate JSON. **Go back to step 8 (Poll).** Repeat 8→9→10 until CONSENSUS, STALEMATE, or 5 rounds.

### 11. Completion + Stalemate

**Consensus definitions**: Full (no disagreements), Partial (overall matches but ≤2 minor disagreements, severity ≤ low), No Consensus (severity ≥ medium disagreements remain → continue or stalemate).

**Stop triggers**: Full/Partial Consensus; stalemate (same pairs 2 consecutive rounds, no new evidence); hard cap (5 rounds → forced STALEMATE); user stops.

`poll_json.convergence.stalemate === true` → present deadlocked issues with both sides' arguments. Round < 5 → ask user; round 5 → force final synthesis.

**Authority**: Claude orchestration is authoritative for stop/continue. Codex VERDICT is advisory.

### 12. Final Output

Present consensus report — **NEVER propose revised commit messages**.

| Metric | Value |
|--------|-------|
| Rounds | {N} |
| Verdict | CONSENSUS / STALEMATE |
| Claude Findings | {count} |
| Codex Issues | {count} |
| Agreed | {count} |
| Disagreed | {count} |

Present: Commit Message(s) Reviewed (verbatim, per-commit SHA for last mode), Consensus Points (FINDING↔ISSUE agreed), FINDING↔ISSUE Mapping table (Claude FINDING | Codex ISSUE | Classification | Status), Remaining Disagreements (Point | Claude | Codex), Overall Assessment table (Aspect: Quality/Convention compliance/Accuracy vs diff | Claude | Codex | Consensus).

### 13. Finalize + Cleanup
```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"...","scope":"draft"}
FINALIZE_EOF
```
For last mode: `"scope":"last"`. Optionally include `"issues":{"total_found":N,"total_agreed":N,"total_disagreed":N}`. Report `$SESSION_DIR` path.

```bash
node "$RUNNER" stop "$SESSION_DIR"
```
**Always run cleanup**, even on failure/timeout.

**Errors**: Poll `failed` → retry once; `timeout`/`stalled` → report partial results from `review.raw_markdown`, suggest lower effort; `error` → report to user. Start/resume `error` with `CODEX_NOT_FOUND` → tell user to install codex. Always run cleanup.

## Rules
- **Safety**: NEVER run `git commit --amend`, `git rebase`, or any command that modifies commit history. This skill is debate-only.
- Both Claude and Codex are equal peers — no reviewer/implementer framing.
- **Information barrier**: Claude MUST complete independent analysis (Step 7) before reading Codex output. This prevents anchoring bias.
- **NEVER propose revised commit messages** — only debate quality. The final output is a consensus report, not a fix.
- Codex reviews message quality only; it does not review code.
- Discover project conventions before reviewing (Step 3).
- For `last` mode with N > 1: findings must reference specific commit SHA/subject in Evidence.
- If stalemate persists (same unresolved points for 2 consecutive rounds), present both sides and defer to user.
- **Runner manages all session state** — do NOT manually read/write `rounds.json`, `meta.json`, or `prompt.txt` in the session directory.
