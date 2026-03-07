# Output Format Contract

## ISSUE-{N} (Per Chunk — Codex output)

Each chunk review produces zero or more ISSUE blocks:

```markdown
### ISSUE-{N}: {Short title}
- Category: bug | edge-case | security | performance | maintainability
- Severity: low | medium | high | critical
- File: {path}
- Location: {line range or function name}
- Problem: {clear statement}
- Evidence: {where/how observed}
- External deps: {imports/references outside this module, or "none"}
- Suggested fix: {concrete fix}
```

Followed by a single VERDICT block:

```markdown
### VERDICT
- Status: APPROVE | REVISE
- Reason: {short reason}
```

## CROSS-{N} (Cross-cutting — Claude-generated)

Claude synthesizes chunk findings into cross-module patterns:

```markdown
### CROSS-{N}: {title}
- Category: inconsistency | api-contract | dry-violation | integration | architecture
- Severity: low | medium | high | critical
- Modules affected: {comma-separated list}
- Problem: {description}
- Evidence: {file:line references across modules}
- Suggested fix: {recommendation}
```

## RESPONSE-{N} (Validation — Codex output)

Codex validates CROSS-{N} findings:

```markdown
### RESPONSE-{N}: Re: {original CROSS-{N} title}
- Action: accept | reject | revise
- Reason: {evidence-based reasoning}
- Revised finding (if Action is revise): {updated description}
```

Followed by a single VERDICT block.
