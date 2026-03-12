# Prompt Templates

## Placeholder Injection Guide

| Placeholder | Source | Required | Default |
|-------------|--------|----------|---------|
| `{QUESTION}` | User's question or topic | Yes | — |
| `{PROJECT_CONTEXT}` | Project description and tech stack | No | "Not specified — infer from codebase" |
| `{RELEVANT_FILES}` | Files relevant to the question | No | "None specified" |
| `{CONSTRAINTS}` | Scope and constraints | No | "None specified" |
| `{OUTPUT_FORMAT}` | Copy the entire fenced code block from `references/output-format.md` | Yes | — |

### Round 2+ Placeholders

| Placeholder | Source | Required |
|-------------|--------|----------|
| `{AGREED_POINTS}` | Claude's agreements from step 4 | Yes |
| `{DISAGREED_POINTS}` | Claude's rebuttals from step 4 | Yes |
| `{NEW_PERSPECTIVES}` | New angles introduced by Claude | Yes |
| `{CONTINUE_OR_CONSENSUS_OR_STALEMATE}` | Debate status from step 4 | Yes |
| `{OUTPUT_FORMAT}` | Copy the entire fenced code block from `references/output-format.md` | Yes |

---

## Round 1 Prompt
```
## Your Role
You are an equal analytical peer with Claude Code. You think independently; Claude orchestrates the debate loop and final synthesis.

## Question
{QUESTION}

## Project Context
{PROJECT_CONTEXT}

## Relevant Files
{RELEVANT_FILES}

## Known Constraints
{CONSTRAINTS}

## Instructions
1. Think independently.
2. Separate facts, assumptions, and recommendations.
3. Use required output format exactly.

## Required Output Format
{OUTPUT_FORMAT}
```

## Round 2+ Response Prompt
```
## Points I Agree With
{AGREED_POINTS}

## Points I Disagree With
{DISAGREED_POINTS}

## Additional Perspectives
{NEW_PERSPECTIVES}

## Current Status
{CONTINUE_OR_CONSENSUS_OR_STALEMATE}

## Your Turn
Respond in required output format and address disagreements directly.

## Required Output Format
{OUTPUT_FORMAT}
```
