# Bug Writing Rules
> Inherits: _base.md

A Bug reports **incorrect behavior explicitly mentioned in the Epic**. Only for defects the Epic calls out — never invent bugs from code scanning or hypotheticals.

**Bug vs Task**: Bug = something is broken, fix it. Task = something doesn't exist, build it.

## Structure

```
Title: [symptom + location]
Type: Bug
Parent: Epic #${EPIC_ID}
Priority: [blocks others = High, else Normal]
Category: [routing.map layer]

## Summary
[What is broken, where, impact]

## Current Behavior
[What happens — quote Epic if available]

## Expected Behavior
[What should happen]

## Affected Area
Layer: ${LAYER_NAME} (${TECH_STACK}) | Likely files: [from scan] | Related: [upstream/downstream]

## Acceptance Criteria
- [ ] Defective behavior no longer occurs
- [ ] Correct behavior verified by test
- [ ] Regression test added

## Context from Epic
[Quote the Epic text describing this defect]
```

## Rules

1. Title = symptom, not fix action.
2. Current vs Expected mandatory.
3. Affected Area uses real file paths from scan.
4. Always include regression test criterion.
5. Quote the Epic — traceability.
6. Never invent bugs.

## Clarification Questions

| Check | Condition | Question | Priority |
|-------|-----------|----------|----------|
| Repro steps | Defect mentioned, no steps | "How to reproduce [defect X]?" | Blocking |
| Current vs expected | Only one side described | "For [defect X]: actual vs expected behavior?" | Blocking |
| Environment | No env/browser/version | "Environment for [defect X]?" | Quality |
| Error context | No errors/traces/logs | "Error messages or stack traces for [defect X]?" | Quality |
| Severity | Unclear impact | "How severe? Blocks users or minor?" | Refinement |

## Using Clarification Context

Repro → include in description. Current/expected → populate both sections. Environment → Affected Area. Errors → Summary. Severity → priority.

## Project Context

Reference existing test file for regression test. Match codebase error handling patterns. Identify likely root cause area from scan.
