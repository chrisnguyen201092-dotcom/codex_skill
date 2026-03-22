# Parallel Review Workflow

## 1) Collect Inputs

### Mode Selection
Ask user: `full-codebase` (default), `working-tree`, or `branch`.

### Full-codebase mode (default):
- List all source files: `find . -type f \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.cs" \) | grep -v node_modules | grep -v .git | grep -v dist | grep -v build`
- Or use project-specific patterns (read `package.json`, `pyproject.toml`, etc. for source dirs).
- User request and acceptance criteria.
- Optional plan/docs files for context.

### Working-tree mode:
- Uncommitted changes (`git status`, `git diff`, `git diff --cached`).
- Optional plan file for intent alignment.

### Branch mode:
- **Base branch discovery:**
  1. Ask user for base branch, suggest default.
  2. Validate ref: `git rev-parse --verify <base>` — fail-fast if not found.
  3. Fallback order: `main` → `master` → remote HEAD.
  4. Confirm with user if using fallback.
  5. Bind variable: `BASE=<validated value>` — use this consistently in all subsequent steps.
- **Clean working tree required**: if dirty, tell user to commit/stash or switch to working-tree mode.
- Branch diff: `git diff <base>...HEAD`.

### Max Debate Rounds
Ask user for max debate rounds (default: 3). Store as `MAX_ROUNDS`.

### Prepare Context
Based on mode:
- **Full-codebase**: `FILES=$(find . ...)` — list all source files. No DIFF needed — reviewers read files directly.
- **Working-tree**: `DIFF=$(git diff && git diff --cached)`, `FILES=$(git diff --name-only)`
- **Branch**: `DIFF=$(git diff <base>...HEAD)`, `FILES=$(git diff --name-only <base>...HEAD)`

### Compute SKILLS_DIR

# SKILLS_DIR is declared in SKILL.md ## Runner block — use it directly, do NOT recompute.

## 2) Launch All 5 Reviewers Simultaneously

**CRITICAL**: Steps 2a and 2b MUST execute in the SAME message to achieve true parallelism.

### 2a) Start Codex via Runner

Initialize session:

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-parallel-review --working-dir "$PWD")
SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate init output:** Verify `INIT_OUTPUT` starts with `CODEX_SESSION:`. If not, report error.

Render prompt (choose template by mode):

For full-codebase mode:
```bash
REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-parallel-review --template full-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
RENDER_EOF
)
```

For working-tree mode:
```bash
REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-parallel-review --template working-tree-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED}
RENDER_EOF
)
```

For branch mode:
```bash
REQ_ESCAPED=$(printf '%s' "$USER_REQUEST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CTX_ESCAPED=$(printf '%s' "$SESSION_CONTEXT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
BASE_ESCAPED=$(printf '%s' "$BASE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-parallel-review --template branch-round1 --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"USER_REQUEST":$REQ_ESCAPED,"SESSION_CONTEXT":$CTX_ESCAPED,"BASE_BRANCH":$BASE_ESCAPED}
RENDER_EOF
)
```

`{OUTPUT_FORMAT}` is auto-injected by the render command from `references/output-format.md`.

Start Codex:

```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$SESSION_DIR" --effort "$EFFORT"
```

**Validate start output (JSON):**
```json
{ "status": "started", "session_dir": "/path", "round": 1 }
```
If `status` is `"error"`, report to user.

### 2b) Spawn 4 Claude Reviewer Agents

Use Claude Code's **native Agent tool** (built-in, no plugins needed) to spawn 4 parallel reviewers. Each uses `subagent_type: "code-reviewer"` with `run_in_background: true`.

**All 4 agents MUST be spawned in the same message as the Codex start command.**

#### Agent 1 — Correctness & Edge Cases

```json
{
  "subagent_type": "code-reviewer",
  "description": "Review correctness and edge cases",
  "run_in_background": true,
  "prompt": "You are an independent code reviewer. Another AI (Codex) is reviewing the same code separately — you will NOT see their findings. Be thorough.\n\nWorking directory: {WORKING_DIR}\nMode: {MODE}\nFiles to review: {FILE_LIST}\n\nFocus ONLY on:\n1. Correctness: logic errors, wrong return values, missing null checks, incorrect conditions, type mismatches, off-by-one\n2. Edge cases: boundary conditions, empty inputs, overflow, concurrent access, race conditions\n\nRead each file listed above. For each issue found, output:\n\n### FINDING-{N}: {title}\n- Category: bug | edge-case\n- Severity: low | medium | high | critical\n- File: {path}\n- Location: {line range or function name}\n- Problem: {description}\n- Suggested fix: {concrete fix}\n\n{DIFF_OR_EMPTY}\n\nIf no issues found in your categories, state that explicitly."
}
```

#### Agent 2 — Security (DEEP)

```json
{
  "subagent_type": "code-reviewer",
  "description": "Deep security review (OWASP Top 10)",
  "run_in_background": true,
  "prompt": "You are an independent SECURITY-FOCUSED code reviewer. Another AI (Codex) is reviewing the same code separately — you will NOT see their findings. Be exhaustive on security.\n\nWorking directory: {WORKING_DIR}\nMode: {MODE}\nFiles to review: {FILE_LIST}\n\nFocus ONLY on Security — cover ALL of the following:\n\n1. OWASP Top 10 2021:\n   - A01 Broken Access Control: missing authz checks, IDOR, path traversal, CORS misconfiguration, privilege escalation\n   - A02 Cryptographic Failures: weak algorithms (MD5/SHA1/DES), missing salt, hardcoded IVs, insecure random, missing HTTPS enforcement\n   - A03 Injection: SQL, NoSQL, command, XSS, LDAP, template, log injection\n   - A04 Insecure Design: missing rate limiting, insufficient input validation, business logic flaws\n   - A05 Security Misconfiguration: default credentials, verbose errors, unnecessary features, missing security headers (CSP, X-Frame-Options, HSTS)\n   - A06 Vulnerable Components: known CVEs in package.json/requirements.txt/go.mod, outdated deps with security patches\n   - A07 Auth Failures: weak passwords, missing MFA, session fixation, insecure session management, missing account lockout\n   - A08 Integrity Failures: insecure deserialization, missing integrity checks, unsigned code, CI/CD pipeline vulns\n   - A09 Logging Failures: missing security event logging, sensitive data in logs, insufficient audit trails\n   - A10 SSRF: unvalidated URLs, missing URL whitelist, internal service exposure, cloud metadata access\n\n2. Secrets & Credentials:\n   - Hardcoded API keys, tokens, passwords in source code\n   - .env files committed to git or exposed\n   - Credentials leaked in logs or error messages\n   - Sensitive data in URL query parameters\n\n3. Configuration Security:\n   - CORS policy (overly permissive origins, credentials)\n   - CSP headers (missing or weak)\n   - Cookie flags (HttpOnly, Secure, SameSite)\n   - TLS/HTTPS enforcement\n   - Security headers completeness\n\n4. Cryptography:\n   - Weak hash algorithms (MD5, SHA1 for passwords)\n   - Missing salt in password hashing\n   - Hardcoded encryption keys/IVs\n   - Insecure random number generation (Math.random for security)\n   - Deprecated crypto APIs\n\n5. Input & File Handling:\n   - Path traversal in file operations\n   - Unrestricted file upload (type, size, storage location)\n   - Command injection via user input to exec/spawn\n   - SSRF via user-controlled URLs\n   - Open redirects\n\n6. Dependency Security:\n   - Known CVEs in direct dependencies\n   - Outdated packages with security patches available\n   - Unmaintained dependencies\n   - Missing dependency integrity checks (lockfile)\n\n7. Rate Limiting & DoS:\n   - Missing throttle on authentication endpoints\n   - Missing rate limiting on public API endpoints\n   - Unbounded resource consumption (file size, query complexity)\n   - ReDoS (regex denial of service)\n\n8. Auth Flow & Session:\n   - JWT validation completeness (algorithm, expiration, issuer)\n   - Session management (fixation, hijacking, timeout)\n   - Privilege escalation paths\n   - Token storage security (localStorage vs httpOnly cookie)\n   - OAuth/OIDC misconfigurations\n\nFor each finding, output:\n\n### FINDING-{N}: {title}\n- Category: security\n- Subcategory: injection | broken-auth | sensitive-data | xxe | broken-access | security-config | xss | insecure-deserialization | logging | ssrf | crypto-failure | insecure-design | vulnerable-components | integrity-failure | rate-limiting | file-upload | secrets\n- Severity: low | medium | high | critical\n- Confidence: high | medium | low\n- CWE: CWE-{ID} ({Name})\n- OWASP: A{NN}:2021 - {Category Name}\n- File: {path}\n- Location: {line range or function name}\n- Problem: {description}\n- Attack Vector: {how an attacker could exploit this}\n- Suggested fix: {concrete secure code fix}\n\n{DIFF_OR_EMPTY}\n\nIf no security issues found, state that explicitly with a brief security posture summary."
}
```

#### Agent 3 — Performance

```json
{
  "subagent_type": "code-reviewer",
  "description": "Review performance issues",
  "run_in_background": true,
  "prompt": "You are an independent code reviewer. Another AI (Codex) is reviewing the same code separately — you will NOT see their findings. Be thorough.\n\nWorking directory: {WORKING_DIR}\nMode: {MODE}\nFiles to review: {FILE_LIST}\n\nFocus ONLY on Performance:\n1. Algorithmic: O(n²)+ loops, unnecessary nested iterations, inefficient data structure choices\n2. Memory: unnecessary allocations, large object cloning, missing cleanup, memory leaks, unbounded caches\n3. I/O: blocking I/O in async context, missing connection pooling, sequential requests that could be parallel\n4. Database: N+1 queries, missing indexes (if schema visible), unoptimized queries, missing pagination\n5. Caching: missing caching for expensive operations, cache invalidation issues, redundant computations\n6. Bundle/Load: unused imports, large dependency imports where tree-shaking possible, missing lazy loading\n\nRead each file listed above. For each issue found, output:\n\n### FINDING-{N}: {title}\n- Category: performance\n- Subcategory: algorithmic | memory | io | database | caching | bundle\n- Severity: low | medium | high | critical\n- File: {path}\n- Location: {line range or function name}\n- Problem: {description}\n- Impact: {estimated performance impact}\n- Suggested fix: {concrete fix}\n\n{DIFF_OR_EMPTY}\n\nIf no performance issues found, state that explicitly."
}
```

#### Agent 4 — Maintainability & Architecture

```json
{
  "subagent_type": "code-reviewer",
  "description": "Review maintainability and architecture",
  "run_in_background": true,
  "prompt": "You are an independent code reviewer. Another AI (Codex) is reviewing the same code separately — you will NOT see their findings. Be thorough.\n\nWorking directory: {WORKING_DIR}\nMode: {MODE}\nFiles to review: {FILE_LIST}\n\nFocus ONLY on:\n1. Maintainability: naming clarity, DRY violations, missing error handling, overly complex logic, dead code, missing comments for complex logic\n2. Architecture: separation of concerns, module boundaries, API consistency, coupling issues\n\nRead each file listed above. For each issue found, output:\n\n### FINDING-{N}: {title}\n- Category: maintainability | architecture\n- Severity: low | medium | high | critical\n- File: {path}\n- Location: {line range or function name}\n- Problem: {description}\n- Suggested fix: {concrete fix}\n\n{DIFF_OR_EMPTY}\n\nIf no issues found in your categories, state that explicitly."
}
```

### Execution Timeline
```
T=0s   Start Codex + Spawn Agent 1 + Agent 2 + Agent 3 + Agent 4 (all in ONE message)
T=0-60s All 5 reviewers working simultaneously
T=60s  First poll of Codex. Agents may finish before or after Codex.
T=?    All complete → proceed to Merge
```

## 3) Poll Codex + Collect Agent Results

### Poll Codex
```bash
POLL_JSON=$(node "$RUNNER" poll "$SESSION_DIR")
```

Adaptive intervals:

**Round 1:**
- Poll 1: wait 60s
- Poll 2: wait 60s
- Poll 3: wait 30s
- Poll 4+: wait 15s

**Round 2+ (debate):**
- Poll 1: wait 30s
- Poll 2+: wait 15s

**Parse JSON output:**

Running:
```json
{
  "status": "running",
  "round": 1,
  "elapsed_seconds": 45,
  "activities": [
    { "time": 30, "type": "thinking", "detail": "analyzing auth flow" },
    { "time": 35, "type": "command_started", "detail": "cat src/auth.js" }
  ]
}
```

Report **specific activities** from the `activities` array. Example: `"Codex [45s]: reading src/auth.js, analyzing auth flow"`. NEVER say generic messages like "Codex is running" or "still waiting" — always extract concrete details from activities.

Continue while `status` is `"running"`.
Stop on `"completed"|"failed"|"timeout"|"stalled"`.

**Completed:**
```json
{
  "status": "completed",
  "round": 1,
  "elapsed_seconds": 120,
  "thread_id": "thread_abc",
  "review": {
    "format": "review",
    "blocks": [
      { "id": 1, "prefix": "ISSUE", "title": "Missing validation", "category": "security", "severity": "high", "location": "src/api.js:23", "problem": "...", "evidence": "...", "suggested_fix": "...", "extra": {} }
    ],
    "verdict": { "status": "REVISE", "reason": "..." },
    "overall_assessment": null,
    "raw_markdown": "..."
  },
  "activities": [...]
}
```

**Failed/Timeout/Stalled:**
```json
{
  "status": "failed|timeout|stalled",
  "round": 1,
  "elapsed_seconds": 3600,
  "exit_code": 2,
  "error": "Timeout after 3600s",
  "review": null,
  "activities": [...]
}
```

### Collect Agent Results
After Codex completes (or during polling if agents finish first), read results from all 4 background agents. Each agent returns its FINDING-{N} blocks.

**If an agent fails**: log the error, continue with remaining agents' findings. Partial coverage is better than no coverage.

## 4) Merge Findings

After all reviewers complete:

### 4a) Deduplicate Claude Findings
Across the 4 agents, some findings may overlap (e.g., Agent 1 flags a null check, Agent 4 flags same code as poor error handling). Deduplicate:
- Same file + overlapping line range → keep the higher-severity one
- Renumber all Claude findings sequentially: FINDING-1, FINDING-2, ...

### 4b) Cross-match Claude vs Codex
1. Parse Codex `review.blocks` from poll JSON for `ISSUE-{N}` blocks. Use `review.raw_markdown` as fallback.
2. Match using heuristic:
   - **Same file + overlapping location + same category** → `agreed`
   - **Same file + same category + different location** → check if same root cause → `agreed` or `unique`
   - **No match in other set** → `claude-only` or `codex-only`
   - **Same file + same location + contradictory assessment** → `contradiction`
3. Prefer false-negatives over false-positives (mark as unique if unsure).

### 4c) Present Merge Summary
```
## Merge Results
| Source | Findings |
|--------|----------|
| Claude (4 agents, deduplicated) | {N} |
| Codex | {M} |
| **Agreed** | {A} |
| **Claude-only** | {C} |
| **Codex-only** | {X} |
| **Contradictions** | {D} |
```

## 5) Apply Agreed + Debate Disagreements

### Agreed Findings
Claude applies fixes immediately. Record fix evidence.
- **Branch mode**: commit fixes before debate (`git add` + `git commit`).

### Debate Loop (max `MAX_ROUNDS` rounds)

For each round:

1. Render debate prompt:
   ```bash
   CODEX_ESCAPED=$(printf '%s' "$CODEX_ONLY_WITH_REBUTTALS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   CLAUDE_ESCAPED=$(printf '%s' "$CLAUDE_ONLY_FINDINGS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   CONTRA_ESCAPED=$(printf '%s' "$CONTRADICTIONS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
   PROMPT=$(node "$RUNNER" render --skill codex-parallel-review --template debate --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"CODEX_ONLY_WITH_REBUTTALS":$CODEX_ESCAPED,"CLAUDE_ONLY_FINDINGS":$CLAUDE_ESCAPED,"CONTRADICTIONS":$CONTRA_ESCAPED}
RENDER_EOF
   )
   ```
   - Include codex-only findings Claude disagrees with + rebuttals.
   - Include claude-only findings for Codex to evaluate.
   - Include contradictions with both arguments.
   - Exclude already-resolved items.

2. Resume Codex thread:
   ```bash
   printf '%s' "$PROMPT" | node "$RUNNER" resume "$SESSION_DIR" --effort "$EFFORT"
   ```

   **Validate resume output (JSON):**
   ```json
   { "status": "started", "session_dir": "/path", "round": 2, "thread_id": "thread_abc" }
   ```

3. Poll (Round 2+ intervals: 30s/15s...).

4. Parse Codex response from `review.blocks` (`RESPONSE-{N}` blocks):
   - `Action: accept` → resolved, Claude applies fix if needed.
   - `Action: reject` with new evidence → Claude reconsiders.
   - `Action: revise` → Codex offers modified position; Claude evaluates.
   - Use `review.raw_markdown` as fallback if structured parsing misses edge cases.

5. Track per-finding resolution. Remove resolved items from next round prompt.

6. Check exit conditions:
   - All disagreements resolved → stop debate.
   - Round limit (`MAX_ROUNDS`) reached → stop, report unresolved.
   - Stalemate: same arguments repeated 2 consecutive rounds → stop.

### Branch Mode Note
Commit fixes before each resume. Codex reads `git diff <base>...HEAD` — uncommitted fixes are invisible.

## 6) Final Report + Finalize

### Final Report

```
## Parallel Review Report

### Review Stats
| Metric | Value |
|--------|-------|
| Reviewers | 5 (4 Claude agents + Codex) |
| Claude findings (deduplicated) | {N} |
| Codex findings | {M} |
| Agreed | {A} |
| Resolved via debate | {R} |
| Unresolved | {U} |
| Debate rounds | {D}/{MAX_ROUNDS} |
| Verdict | CONSENSUS / PARTIAL / STALEMATE |

### Consensus Issues (both AI systems agree)
{list with fixes applied, grouped by severity}

### Resolved Disagreements
{list with resolution: who conceded, why, what changed}

### Unresolved Disagreements
| # | Finding | Claude's Position | Codex's Position | Recommendation |
|---|---------|-------------------|-------------------|----------------|
{table — present both sides, recommend action}

### Risk Assessment
{residual risk from unresolved items}
```

### Session Finalization

After the final report, finalize the session:

```bash
node "$RUNNER" finalize "$SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"CONSENSUS","scope":"full-codebase","issues":{"total_found":10,"total_fixed":7,"total_disputed":3}}
FINALIZE_EOF
```

For working-tree mode, use `"scope":"working-tree"`. For branch mode, use `"scope":"branch"`.

The runner auto-computes `meta.json` with timing, round count, and session metadata.

Report `$SESSION_DIR` path to the user in the final summary.

## 7) Cleanup

```bash
node "$RUNNER" stop "$SESSION_DIR"
```
Always run regardless of outcome (success, failure, timeout, stalemate).

## Error Handling

### Poll Errors
Poll returns JSON. Parse `status` field:
- `"completed"` → success, review data in `review` field.
- `"failed"` (exit_code 3) → turn failed. Retry once. If still failing, report error to user.
- `"timeout"` (exit_code 2) → timeout. Report partial results from `review.raw_markdown` if available. Suggest retry with lower effort.
- `"stalled"` (exit_code 4) → stalled. Report partial results. Suggest lower effort.
- `"error"` → infrastructure error. Report `error` field to user.

### Start/Resume Errors
Start and resume return JSON. If `status` is `"error"`:
- Check `code` field: `"CODEX_NOT_FOUND"` → tell user to install codex. Other codes → report `error` message.

### Claude Agent Errors
- Agent fails to return → log error, exclude from merge, note in report.
- Agent returns no findings → valid result (clean code for that category).
- All 4 agents fail → fall back to inline Claude review (single-reviewer mode).

### Fallback Mode
If Codex fails AND all agents fail: Claude performs inline review covering all categories (correctness, security, performance, maintainability), produces FINDING-{N} blocks, presents results without debate.

### General Rules
- Always run cleanup (step 7) regardless of error.
- Use `review.raw_markdown` as fallback if structured parsing misses edge cases.

## Stalemate Handling

When stalemate detected (same unresolved points for 2 consecutive rounds):
1. List specific deadlocked points.
2. Show each side's final argument.
3. Recommend which side to favor based on evidence strength.
4. Ask user: accept current state or force one more round.
