# Think-About Workflow

## 1) Inputs
- User question/topic.
- Scope and constraints.
- Relevant files or external facts.
- Reasoning effort level.

## 1.5) Pre-flight Checks
1. Verify `codex` CLI is in PATH: `command -v codex`. If not found, tell user to install.
2. Verify working directory is writable (for state directory creation).

## 1.8) Prompt Assembly

1. Read the Round 1 template from `references/prompts.md`.
2. Replace `{QUESTION}` with user's question or topic.
3. Replace `{PROJECT_CONTEXT}` with project description (or "Not specified — infer from codebase").
4. Replace `{RELEVANT_FILES}` with file list (or "None specified").
5. Replace `{CONSTRAINTS}` with scope constraints (or "None specified").
6. Replace `{OUTPUT_FORMAT}` by copying the entire fenced code block from `references/output-format.md`.

## 2) Start Round 1

Set `ROUND=1`.

```bash
STATE_OUTPUT=$(printf '%s' "$PROMPT" | node "$RUNNER" start --working-dir "$PWD" --effort "$EFFORT")
STATE_DIR=${STATE_OUTPUT#CODEX_STARTED:}
```

## 3) Poll

```bash
POLL_OUTPUT=$(node "$RUNNER" poll "$STATE_DIR")
```

Adaptive intervals — start slow, speed up:

**Round 1 (first review):**
- Poll 1: wait 60s
- Poll 2: wait 60s
- Poll 3: wait 30s
- Poll 4+: wait 15s

**Round 2+ (rebuttal rounds):**
- Poll 1: wait 30s
- Poll 2+: wait 15s

After each poll, parse the status lines and report **specific activities** to the user. NEVER say generic messages like "Codex is running" or "still waiting" — these provide no information.

**Poll output parsing guide:**

| Poll line pattern | Report to user |
|-------------------|---------------|
| `Codex thinking: "**topic**"` | Codex analyzing: {topic} |
| `Codex running: ... 'git diff ...'` | Codex reading repo diff |
| `Codex running: ... 'cat src/foo.ts'` | Codex reading file `src/foo.ts` |
| `Codex running: ... 'rg -n "pattern" ...'` | Codex searching for `pattern` in code |
| Multiple completed commands | Codex read {N} files, analyzing results |

**Report template:** "Codex [{elapsed}s]: {specific activity summary}" — always include elapsed time and concrete description.

Continue while status is `running`.
Stop on `completed|failed|timeout|stalled`.

**On `POLL:completed`:**
1. Extract thread ID from poll output: look for `THREAD_ID:<id>` line.
2. Read Codex output: `cat "$STATE_DIR/review.md"`.
3. Save for Round 2+: `THREAD_ID=<extracted id>`.

## 4) Claude Response
After `POLL:completed`:
1. Read Codex output from `$STATE_DIR/review.md`.
2. Parse Key Insights, Considerations, Recommendations, Open Questions, Confidence Level.
3. Parse Suggested Status (advisory) — use as a signal but Claude makes the final status decision.
4. List agreements with evidence.
5. List disagreements with rebuttals.
6. Add missing angles or new perspectives.
7. Set status: `CONTINUE`, `CONSENSUS`, or `STALEMATE`. Consider Codex's Suggested Status but override if evidence warrants a different assessment.

## 5) Resume Round 2+

Build Round 2+ prompt from `references/prompts.md` (Response Prompt template):
- Replace `{AGREED_POINTS}` with Claude's agreements from step 4.
- Replace `{DISAGREED_POINTS}` with Claude's rebuttals from step 4.
- Replace `{NEW_PERSPECTIVES}` with new angles from step 4.
- Replace `{CONTINUE_OR_CONSENSUS_OR_STALEMATE}` with status from step 4.
- Replace `{OUTPUT_FORMAT}` by copying the entire fenced code block from `references/output-format.md`.

```bash
STATE_OUTPUT=$(printf '%s' "$RESPONSE_PROMPT" | node "$RUNNER" start \
  --working-dir "$PWD" --thread-id "$THREAD_ID" --effort "$EFFORT")
STATE_DIR=${STATE_OUTPUT#CODEX_STARTED:}
```

**→ Go back to step 3 (Poll).** Increment `ROUND` counter. After poll completes, repeat step 4 and check stop conditions. If `ROUND >= 5`, force final synthesis — do NOT resume. Otherwise, continue until a stop condition is reached.

## 6) Stop Conditions
- Consensus reached.
- Stalemate detected (repeated claims with no new evidence for two rounds).
- Hard cap reached (5 rounds maximum).

## 7) Final User Output

**Note:** Per-round Codex output follows the schema in `references/output-format.md`. This final synthesis is Claude's user-facing summary of the debate result.

### Consensus Points
- {agreed points}

### Remaining Disagreements
| Point | Claude | Codex |
|-------|--------|-------|
| ... | ... | ... |

### Recommendations
- {actionable recommendations}

### Open Questions
- {unresolved questions}

### Confidence Level
- low | medium | high

## 8) Cleanup
```bash
node "$RUNNER" stop "$STATE_DIR"
```
Remove the state directory and kill any remaining Codex/watchdog processes. Always run this step, even if the debate ended due to failure or timeout.

## Error Handling

Runner `poll` returns status via output string `POLL:<status>:<elapsed>[:exit_code:details]`. Normally exits 0, but may exit non-zero when state dir is invalid or I/O error — handle both cases:

**Parse POLL string (exit 0):**
- `POLL:completed:...` → Success, read review.md from state dir.
- `POLL:failed:...:3:...` → Turn failed. Retry once. If still fails, report error.
- `POLL:timeout:...:2:...` → Timeout. Report partial results if review.md exists. Suggest retry with lower effort.
- `POLL:stalled:...:4:...` → Stalled. Report partial results. Suggest lower effort.

**Fallback when poll exits non-zero or output cannot be parsed:**
- Log error output, report infrastructure error to user, suggest retry.

Runner `start` may fail with exit code:
- 1 → Generic error (invalid args, I/O). Report error message.
- 5 → Codex CLI not found. Tell user to install.

Always run cleanup (step 8) regardless of error.

## Stalemate Handling

When stalemate detected (repeated claims with no new evidence for two rounds):
1. List specific deadlocked points.
2. Show each side's final argument for each point.
3. Recommend which perspective user should favor.
4. If `ROUND < 5`, ask user: accept current synthesis or force one more round. If `ROUND >= 5` (hard cap), force final synthesis — do NOT offer another round.
