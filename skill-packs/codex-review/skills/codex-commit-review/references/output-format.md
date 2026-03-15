# Output Format Contract

Use this exact shape:

```markdown
### ISSUE-{N}: {Short title}
- Category: clarity | convention | scope | accuracy | structure
- Severity: low | medium | high | critical
- Commit: {SHA and subject — required for last mode, "draft" for draft mode}
- Problem: {clear statement}
- Evidence: {specific text or diff reference}
- Why it matters: {impact on readability, traceability, or team workflow}

### Overall Assessment
- Quality: poor | fair | good | excellent
- Convention compliance: yes | partial | no
- Accuracy vs diff: accurate | partially accurate | inaccurate

### VERDICT
- Status: CONSENSUS | CONTINUE | STALEMATE
- Reason: {short reason}
```

If no issues remain, return only `Overall Assessment` and `VERDICT` with `Status: CONSENSUS`.
