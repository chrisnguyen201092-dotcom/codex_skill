# Codebase Review Workflow

## 1) Collect Inputs

### Effort Level
Ask user: `low` | `medium` | `high` (default) | `xhigh`.

### Parallel Factor
Ask user: `1` (default, sequential) | `2` | `3`.
Sequential provides best context propagation. Parallel trades depth for speed.

### Focus Areas (optional)
User may specify: `security`, `performance`, `architecture`, `correctness`, `maintainability`.
Default: all categories.

### Scope
Full codebase only. For diff-based review → redirect to `/codex-impl-review`.

## 2) Discovery

### 2a) Detect Project Type

Check marker files in project root:

| Marker | Type | Source Roots |
|--------|------|-------------|
| `package.json` + `tsconfig.json` | TypeScript/Node | `src/`, `lib/`, `app/` |
| `package.json` (no tsconfig) | JavaScript/Node | `src/`, `lib/`, `app/` |
| `pyproject.toml` / `setup.py` | Python | `src/{pkg}/`, dirs with `__init__.py` |
| `go.mod` | Go | dirs containing `.go` files |
| `Cargo.toml` | Rust | `src/`, `crates/` |
| `pom.xml` / `build.gradle` | Java | `src/main/java/` |
| `*.csproj` | C# | `src/` |
| (none matched) | Generic | top-level dirs fallback |

### 2b) List Source Files

List all source files, excluding:
- `node_modules`, `.git`, `dist`, `build`, `vendor`, `__pycache__`, `target`, `.next`, `.nuxt`, `coverage`
- Binary files, images, fonts, lock files

```bash
find . -type f \( -name "*.js" -o -name "*.ts" -o -name "*.jsx" -o -name "*.tsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" -o -name "*.cs" \
  -o -name "*.rb" -o -name "*.php" -o -name "*.vue" -o -name "*.svelte" \) \
  | grep -v node_modules | grep -v .git | grep -v dist | grep -v build \
  | grep -v vendor | grep -v __pycache__ | grep -v target \
  | grep -v .next | grep -v .nuxt | grep -v coverage
```

Or use project-specific patterns from config files.

### 2c) Identify Module Boundaries

Group files by top-level directory under source root. Stop at depth 2.

Example for TypeScript project with `src/`:
```
src/
├── auth/          → module "auth"
├── api/           → module "api"
├── models/        → module "models"
├── utils/         → module "utils"
├── config/        → module "config"
└── index.ts       → module "root"
```

### 2d) Count Lines Per Module

```bash
wc -l <files_in_module> | tail -1
```

### 2e) Present Module Table

Display for user confirmation (effort >= medium):

```
## Discovered Modules
| # | Module | Files | Lines | Est. Chunks |
|---|--------|-------|-------|-------------|
| 1 | config | 3 | 150 | (merge) |
| 2 | models | 8 | 620 | 1 |
| 3 | auth | 12 | 1800 | 1 |
| 4 | api | 15 | 2400 | 2 |
| 5 | utils | 6 | 450 | (merge) |
| 6 | tests | 10 | 1200 | 1 |
| **Total** | | **54** | **6620** | **5-6** |
```

For `low` effort: skip confirmation, auto-proceed.

## 3) Chunking

### Target Size
500-2000 lines per chunk.

### Rules
- Module < 300 lines → merge with related module (config+types, utils+helpers).
- Module > 2500 lines → split by sub-directory.
- Ordering: config/types first → core/utils → features → tests last.

### Merge Strategy
1. Sort modules by line count ascending.
2. Small modules (< 300 lines) attempt to merge with thematically related neighbor.
3. Merged chunks must stay under 2000 lines.
4. Standalone files in root → merge into nearest thematic chunk.

### Split Strategy
For modules > 2500 lines:
1. Group by immediate sub-directory.
2. If a sub-directory is still > 2500 lines, split alphabetically into ~1500-line groups.
3. Suffix chunk names: `api-routes`, `api-middleware`, `api-controllers`.

### Present Chunk Plan

Display for user confirmation (effort >= medium):

```
## Chunk Plan
| # | Chunk Name | Modules/Files | Lines | Order |
|---|-----------|---------------|-------|-------|
| 1 | config-types | config/, types/ | 380 | 1st |
| 2 | models | models/ | 620 | 2nd |
| 3 | utils | utils/, helpers/ | 450 | 3rd |
| 4 | auth | auth/ | 1800 | 4th |
| 5 | api-routes | api/routes/ | 1200 | 5th |
| 6 | api-controllers | api/controllers/ | 1200 | 6th |
| 7 | tests | tests/ | 1200 | 7th |
```

For `low` effort: skip confirmation, auto-proceed.

## 4) Review Loop

### Setup

# SKILLS_DIR is declared in SKILL.md ## Runner block — use it directly, do NOT recompute.

Initialize an array to track all session directories for cleanup:

```bash
ALL_SESSION_DIRS=()
```

### Sequential Mode (parallel_factor=1)

For each chunk in order:

#### 4a) Initialize Session

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-codebase-review --working-dir "$PWD")
CHUNK_SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate init output:** Verify `INIT_OUTPUT` starts with `CODEX_SESSION:`. If not, report error.

Track CHUNK_SESSION_DIR:
```bash
ALL_SESSION_DIRS+=("$CHUNK_SESSION_DIR")
```

#### 4b) Render Prompt

```bash
FILES_ESCAPED=$(printf '%s' "$FILE_LIST" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CONTEXT_ESCAPED=$(printf '%s' "$CONTEXT_SUMMARY" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROJECT_TYPE_ESCAPED=$(printf '%s' "$PROJECT_TYPE" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
CHUNK_NAME_ESCAPED=$(printf '%s' "$CHUNK_NAME" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
FOCUS_AREAS_ESCAPED=$(printf '%s' "$FOCUS_AREAS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-codebase-review --template chunk-review --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"PROJECT_TYPE":$PROJECT_TYPE_ESCAPED,"CHUNK_NAME":$CHUNK_NAME_ESCAPED,"FOCUS_AREAS":$FOCUS_AREAS_ESCAPED,"FILE_LIST":$FILES_ESCAPED,"CONTEXT_SUMMARY":$CONTEXT_ESCAPED}
RENDER_EOF
)
```

Template variables:
- `PROJECT_TYPE`: detected project type from §2a
- `CHUNK_NAME`: name of this chunk (e.g., "auth", "api-routes")
- `FOCUS_AREAS`: comma-separated focus areas or "all"
- `FILE_LIST`: newline-separated list of files in this chunk
- `CONTEXT_SUMMARY`: high/critical findings from prior chunks (empty for first chunk)

#### 4c) Start Codex

```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$CHUNK_SESSION_DIR" --effort "$EFFORT"
```

**Validate start output (JSON):**
```json
{ "status": "started", "session_dir": "/path", "round": 1 }
```
If `status` is `"error"`, report to user.

#### 4d) Poll

```bash
POLL_JSON=$(node "$RUNNER" poll "$CHUNK_SESSION_DIR")
```

Adaptive intervals:
- Poll 1: wait 60s
- Poll 2: wait 60s
- Poll 3: wait 30s
- Poll 4+: wait 15s

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

Report **specific activities** from the `activities` array. Example: `"Chunk {N}/{TOTAL} [{name}] — Codex [{elapsed}s]: reading src/auth.js, analyzing auth flow"`. NEVER say generic messages like "Codex is running" or "still waiting" — always extract concrete details from activities.

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

#### 4e) Parse Results

Parse issues from the poll JSON `review.blocks` array:
- Each block has `id`, `prefix`, `title`, `category`, `severity`, `location`, `problem`, `evidence`, `suggested_fix`, and optionally `extra`.
- The verdict is in `review.verdict.status` (e.g., `"REVISE"`, `"APPROVE"`).
- `review.raw_markdown` is always available as fallback.

#### 4f) Context Propagation
After each chunk completes, extract high/critical findings into context summary:
```
- [{chunk_name}] {title}: {summary} ({severity}) in {file}
```
Cap at ~2000 tokens. Newest findings replace oldest if over cap.

#### 4g) Report Progress
```
Chunk {N}/{TOTAL} [{name}]: {issue_count} issues ({C}C/{H}H/{M}M/{L}L)
```

#### 4h) Finalize Chunk

```bash
node "$RUNNER" finalize "$CHUNK_SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"...","scope":"codebase"}
FINALIZE_EOF
```

**Validate finalize output (JSON):**
```json
{ "status": "finalized", "meta": { ... } }
```

#### 4i) Check Session Status (optional)

At any point, inspect a session's state:

```bash
node "$RUNNER" status "$CHUNK_SESSION_DIR"
```

Returns:
```json
{
  "status": "ok",
  "session_id": "codex-codebase-review-20260322-001",
  "skill": "codex-codebase-review",
  "round": 1,
  "effort": "high",
  "thread_id": "thread_abc",
  "rounds": [
    { "round": 1, "started_at": 1711100000, "completed_at": 1711100120, "elapsed_seconds": 120, "status": "completed", "verdict": "REVISE", "issues_found": 3 }
  ],
  "has_review": true,
  "has_meta": false
}
```

Useful for debugging or when tracking multiple parallel sessions.

### Parallel Mode (parallel_factor=2-3)

#### Batch Formation
Group chunks into batches of `parallel_factor` size.
Example with 7 chunks, factor 2: [1,2], [3,4], [5,6], [7].

#### Per Batch
1. Start ALL chunks in batch simultaneously (multiple init/render/start calls).
2. Poll round-robin across all active CHUNK_SESSION_DIRs.
3. Context propagation occurs BETWEEN batches only (not within a batch).
4. After all chunks in batch complete → extract context → finalize each → proceed to next batch.

#### Polling Round-Robin
```
while any_chunk_running:
  for each active CHUNK_SESSION_DIR:
    poll once (JSON)
    if completed/failed → mark done, parse results
  sleep interval (same adaptive schedule)
```

#### Tracking Parallel Sessions

Use `status` to inspect any session without interfering:
```bash
node "$RUNNER" status "$CHUNK_SESSION_DIR"
```

## 5) Cross-cutting Analysis (Claude-only)

After ALL chunks reviewed, Claude synthesizes findings.

### Categories by Effort Level

| Category | low | medium | high | xhigh |
|----------|-----|--------|------|-------|
| Pattern inconsistencies across modules | Yes | Yes | Yes | Yes |
| DRY violations across modules | Yes | Yes | Yes | Yes |
| API contract violations between modules | No | Yes | Yes | Yes |
| Integration concerns (circular deps, error propagation, races) | No | No | Yes | Yes |
| Architecture assessment (coupling, cohesion, missing abstractions) | No | No | Yes | Yes |

### Process
1. Collect ALL ISSUE-{N} findings from ALL chunks.
2. Group by file, by category, by severity.
3. Look for patterns that span multiple modules.
4. Generate CROSS-{N} findings (see `references/output-format.md`).

### Examples of Cross-cutting Findings
- Same validation logic duplicated in `auth/` and `api/middleware/`.
- `models/user.ts` exports interface but `api/routes/user.ts` redefines it inline.
- Error handling: `auth/` throws custom errors, `api/` uses generic Error — inconsistent.
- Circular import: `utils/` imports from `models/`, `models/` imports from `utils/`.

## 6) Validation (Optional)

Only run when effort >= `high`.

### 6a) Initialize Validation Session

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-codebase-review --working-dir "$PWD")
VALIDATION_SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
```

**Validate init output:** Verify `INIT_OUTPUT` starts with `CODEX_SESSION:`. If not, report error.

Track VALIDATION_SESSION_DIR:
```bash
ALL_SESSION_DIRS+=("$VALIDATION_SESSION_DIR")
```

### 6b) Render Validation Prompt

```bash
CROSS_ESCAPED=$(printf '%s' "$CROSS_FINDINGS" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))')
PROMPT=$(node "$RUNNER" render --skill codex-codebase-review --template validation --skills-dir "$SKILLS_DIR" <<RENDER_EOF
{"CROSS_FINDINGS":$CROSS_ESCAPED}
RENDER_EOF
)
```

### 6c) Start + Poll

```bash
printf '%s' "$PROMPT" | node "$RUNNER" start "$VALIDATION_SESSION_DIR" --effort "$EFFORT"
```

**Validate start output (JSON):**
```json
{ "status": "started", "session_dir": "/path", "round": 1 }
```
If `status` is `"error"`, report to user.

Poll using same adaptive intervals and JSON parsing as chunk review (§4d).

**Completed validation poll JSON:**
```json
{
  "status": "completed",
  "round": 1,
  "elapsed_seconds": 180,
  "thread_id": "thread_xyz",
  "review": {
    "format": "codebase-validation",
    "blocks": [
      { "id": 1, "prefix": "RESPONSE", "title": "Re: Inconsistent error handling", "action": "accept", "reason": "...", "extra": {} }
    ],
    "verdict": { "status": "APPROVE", "reason": "..." },
    "overall_assessment": null,
    "raw_markdown": "..."
  },
  "activities": [...]
}
```

### 6d) Parse Responses

Parse `review.blocks` from poll JSON — each block has `id`, `prefix` (`"RESPONSE"`), `title`, `action`, `reason`, and optionally `extra`:
- `action: "accept"` → keep CROSS-{N} finding as-is.
- `action: "reject"` → remove or downgrade.
- `action: "revise"` → update finding with Codex's revision.

Use `review.raw_markdown` as fallback if structured parsing misses edge cases.

### 6e) Rounds
- effort `high`: 1 validation round max.
- effort `xhigh`: up to 2 validation rounds.

### 6f) Finalize Validation

```bash
node "$RUNNER" finalize "$VALIDATION_SESSION_DIR" <<'FINALIZE_EOF'
{"verdict":"...","scope":"codebase"}
FINALIZE_EOF
```

## 7) Final Report

```markdown
## Codebase Review Report

### Overview
| Metric | Value |
|--------|-------|
| Project type | {type} |
| Total files | {N} |
| Total lines | {L} |
| Chunks reviewed | {C}/{TOTAL} |
| Total issues | {I} |
| Cross-cutting findings | {X} |

### Per-Module Findings
#### [{chunk_name}] ({files} files, {lines} lines)
{ISSUE-{N} blocks, grouped by severity}

### Cross-cutting Findings
{CROSS-{N} blocks, grouped by category}

### Architecture Assessment (effort >= high)
{coupling analysis, cohesion, missing abstractions}

### Action Items
| Priority | Item | Module(s) | Severity |
|----------|------|-----------|----------|
| P0 | {critical items} | {modules} | critical |
| P1 | {high items} | {modules} | high |
| P2 | {medium items} | {modules} | medium |

### Statistics
| Chunk | Files | Lines | Issues | C | H | M | L | Time |
|-------|-------|-------|--------|---|---|---|---|------|
{per-chunk stats}
| **Total** | **{N}** | **{L}** | **{I}** | {C} | {H} | {M} | {L} | {T} |
```

## 7.5) Session Finalization

Create a master session directory to store the synthesized report:

```bash
INIT_OUTPUT=$(node "$RUNNER" init --skill-name codex-codebase-review --working-dir "$PWD")
MASTER_SESSION_DIR=${INIT_OUTPUT#CODEX_SESSION:}
ALL_SESSION_DIRS+=("$MASTER_SESSION_DIR")
```

Finalize with aggregated stats (compute counters from chunk reviews before calling):
```bash
# Aggregate counters from chunk review results before finalize
# TOTAL_FOUND, TOTAL_FIXED, TOTAL_DISPUTED must be integers computed from chunk sessions
node "$RUNNER" finalize "$MASTER_SESSION_DIR" <<FINALIZE_EOF
{"verdict":"...","scope":"codebase","issues":{"total_found":$TOTAL_FOUND,"total_fixed":$TOTAL_FIXED,"total_disputed":$TOTAL_DISPUTED}}
FINALIZE_EOF
```

The runner auto-computes `meta.json` with timing, round count, and session metadata.

Chunk sessions are preserved individually for traceability. Report `$MASTER_SESSION_DIR` path to the user.

## 8) Cleanup

```bash
for SESSION_DIR in "${ALL_SESSION_DIRS[@]}"; do
  node "$RUNNER" stop "$SESSION_DIR"
done
```

Each `stop` returns JSON:
```json
{ "status": "stopped", "session_dir": "/path" }
```

Stop ALL tracked session directories (chunk sessions, validation session, master session). Always run regardless of outcome (success, failure, timeout, partial).

## 9) Error Handling

### Chunk Failure
- Poll returns `status: "failed"` → retry chunk 1 time.
- Still fails → skip chunk, note in report as "SKIPPED: {reason}".
- If partial `review.raw_markdown` exists → use partial results.

### Threshold: >50% Chunks Failed
- Warn user: "More than half of chunks failed. Results may be incomplete."
- Ask user: continue with partial results or abort.

### All Chunks Failed
- Claude performs inline review of top 5 priority chunks (by module importance).
- Report as "Fallback: Claude-only review (Codex unavailable)".

### Validation Failure
- Skip validation, report cross-cutting findings as-is.
- Note: "Validation skipped due to Codex error".

### Runner Exit Codes
| Code | Meaning | Action |
|------|---------|--------|
| 0 | Success | Continue |
| 2 | Timeout | Use partial results |
| 3 | Turn failed | Retry once |
| 4 | Stalled | Use partial results |
| 5 | Codex not found | Fail immediately, tell user to install |

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

### Stop Errors
Stop returns JSON. If `status` is `"error"`:
- Log warning but do not abort cleanup — continue stopping remaining sessions.

### General Rules
- Always run cleanup (step 8) regardless of error.
- Use `review.raw_markdown` as fallback if structured parsing misses edge cases.
- All runner commands return JSON (except `version`, `init`, `render`) — parse structured output, never scrape stderr.
