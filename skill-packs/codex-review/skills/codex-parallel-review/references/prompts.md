# Prompt Templates

## Working Tree Review Prompt (Phase 1)
```
## Your Role
You are Codex performing an independent code review. Another reviewer is reviewing the same changes separately. You will not see their findings until later — be thorough.

## How to Inspect Changes
- Read uncommitted diffs directly from the repository.
- Use plan context if available.

## User's Original Request
{USER_REQUEST}

## Session Context
{SESSION_CONTEXT}

## Instructions
1. Focus on correctness, regressions, edge cases, security, and maintainability.
2. Be exhaustive — your findings will be compared against another independent reviewer.
3. Do not modify code directly.
4. Use required output format exactly.

## Required Output Format
{OUTPUT_FORMAT}
```

## Branch Review Prompt (Phase 1)
```
## Your Role
You are Codex performing an independent code review. Another reviewer is reviewing the same changes separately. You will not see their findings until later — be thorough.

## How to Inspect Changes
- Read the branch diff from the repository (git diff {BASE}...HEAD).
- Read the commit log (git log {BASE}..HEAD).
- Use plan context if available.

## Base Branch
{BASE_BRANCH}

## User's Original Request
{USER_REQUEST}

## Session Context
{SESSION_CONTEXT}

## Instructions
1. Focus on correctness, regressions, edge cases, security, and maintainability.
2. Be exhaustive — your findings will be compared against another independent reviewer.
3. Do not modify code directly.
4. Use required output format exactly.

## Required Output Format
{OUTPUT_FORMAT}
```

## Debate Prompt (Phase 3)
```
## Context
You previously reviewed this codebase independently. Another reviewer (Claude) also reviewed it independently. Your findings have been compared. Below are the disagreements to resolve.

## Your Findings That Claude Disputes
{CODEX_ONLY_WITH_REBUTTALS}

## Findings Claude Raised That You Did Not
{CLAUDE_ONLY_FINDINGS}

## Contradictions (Both Found, Different Assessment)
{CONTRADICTIONS}

## Instructions
1. For each of your disputed findings: accept Claude's rebuttal OR provide new evidence to defend.
2. For each Claude-only finding: agree it is valid OR explain why you disagree.
3. For contradictions: defend your position with evidence OR concede with reasoning.
4. Use required output format exactly.

## Required Output Format
{OUTPUT_FORMAT}
```
