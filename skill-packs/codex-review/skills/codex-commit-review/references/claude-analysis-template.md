# Claude Independent Analysis Template

Use this exact format for Claude's independent commit message analysis.

```markdown
### FINDING-{N}: {Short title}
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

### Strongest Positions
- {positions Claude is most confident about — defend these in debate}
```

If no findings, write only `Overall Assessment` and `Strongest Positions`.

## FINDING-{N} vs ISSUE-{N}

Claude uses `FINDING-{N}` to distinguish from Codex's `ISSUE-{N}` during cross-analysis and final report. This prevents ID collisions in the mapping table.

## Matching Protocol (FINDING to ISSUE)

When cross-analyzing in Step 4, map Claude's FINDING-{N} with Codex's ISSUE-{N}:

1. **Semantic match**: Same Category + same commit/diff area referenced = match. Wording does not need to be identical — only the same underlying problem.
2. **1-to-many**: If 1 FINDING maps to multiple ISSUEs (or vice versa), note the mapping explicitly (e.g., `FINDING-1 <> ISSUE-2, ISSUE-3`).
3. **Split/merge**: If Codex splits 1 issue into 2, or merges 2 into 1, record the new mapping and keep IDs stable. Do not renumber.
4. **Unmatched**: A FINDING or ISSUE with no counterpart is classified as "Claude-only" or "Codex-only".
5. **Mapping table**: Maintain one mapping table across all rounds. Each round updates the table — do not recreate from scratch.

```markdown
| Claude FINDING | Codex ISSUE | Classification | Status |
|---------------|-------------|----------------|--------|
| FINDING-1     | ISSUE-2     | Agreement      | Agreed |
| FINDING-2     | —           | Claude-only    | Pending |
| —             | ISSUE-1     | Codex-only     | Disputed |
```
