# Task Writing Rules
> Inherits: _base.md

A Task is a **completable unit of work** delivering a concrete part of the Epic outcome. After completion, something observable has changed.

## Structure

```
Title: [action-oriented, references real modules]
Type: Task
Parent: Epic #${EPIC_ID}
Priority: [blocking = High, leaf = Normal]
Category: [routing.map layer]

## Summary
[1-2 sentences: what + why for the Epic outcome]

## Expected Outcome
[Observable, verifiable state after completion]

## Scope
In: [files/modules/behaviors to create or modify]
Out: [what sibling Tasks handle]

## Technical Context
Layer: ${LAYER_NAME} (${TECH_STACK}) | Key files: [from scan] | Pattern: [existing pattern to match]

## Acceptance Criteria
- [ ] [testable criterion]
- [ ] [testable criterion]

## Dependencies
[Other breakdown items, or "None"]
```

## Rules

1. Title references real modules — not generic.
2. Summary connects to Epic outcome.
3. Expected Outcome must be verifiable.
4. Scope uses real paths from codebase scan.
5. Technical Context names layer, techStack, files.
6. Min 2 acceptance criteria.

## Clarification Questions

| Check | Condition | Question | Priority |
|-------|-----------|----------|----------|
| Deliverables | No specific files/endpoints/components | "What concrete deliverables? (endpoints, pages, services, migrations)" | Blocking |
| Done criteria | No "should"/"must" or success conditions | "What defines 'done'?" | Quality |
| Data model | Implies new data, no schema detail | "What data? Fields, types, constraints?" | Quality |
| API contract | Implies endpoints, no spec | "API shape? (method, path, request/response)" | Quality |
| Tech approach | No architectural direction | "Preferred patterns or libraries?" | Refinement |
| Auth | User-facing, no access control | "Role or permission requirements?" | Refinement |

## Using Clarification Context

Deliverables → one Task per item. Done criteria → acceptance criteria. Data model → schema/migration Task. API contract → exact spec in scope. Tech approach → Technical Context. Auth → permission criteria.

## Project Context

Match existing API patterns, data models, test conventions. Embed CLAUDE.md conventions in Technical Context.
