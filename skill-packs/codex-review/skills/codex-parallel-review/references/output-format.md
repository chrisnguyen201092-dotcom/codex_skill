# Output Format Contract

## Initial Review (Phase 1)

Use this exact shape:

```markdown
### ISSUE-{N}: {Short title}
- Category: bug | edge-case | security | performance | maintainability
- Severity: low | medium | high | critical
- Problem: {clear statement}
- Evidence: {where/how observed}
- Suggested fix: {concrete fix path}

### VERDICT
- Status: APPROVE | REVISE
- Reason: {short reason}
```

## Debate Response (Phase 3)

For each disputed item, add response blocks before VERDICT:

```markdown
### RESPONSE-{N}: Re: {original finding title}
- Action: accept | reject | revise
- Reason: {evidence-based reasoning}

### VERDICT
- Status: APPROVE | REVISE
- Reason: {short reason}
```

If no issues remain, return only `VERDICT` with `Status: APPROVE`.
