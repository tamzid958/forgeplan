# User Story Writing Rules
> Inherits: _base.md

A Story describes **user-facing behavior** from a specific role's perspective. Use instead of Task when work is defined by what the user experiences, not system internals.

**Story vs Task**: Story = user behavior + persona + Given/When/Then. Task = technical implementation + system state.

## Structure

```
Title: [what the user can do after completion]
Type: User Story
Parent: Epic #${EPIC_ID}
Priority: [from user impact]
Category: [routing.map layer]

## User Story
As a [role], I want to [action] so that [benefit].

## Summary
[1-2 sentences: what + connection to Epic outcome]

## Acceptance Criteria
- [ ] Given [precondition], when [action], then [result]
- [ ] Given [precondition], when [action], then [result]
- [ ] [additional criteria]

## Scope
In: [behaviors, screens, flows]
Out: [what siblings handle]

## Technical Context
Layer(s): ${LAYER_NAMES} (${TECH_STACKS}) | Key files: [from scan] | UI pattern: [existing] | API pattern: [existing]

## Edge Cases
[invalid input | empty state | error | limits]

## Dependencies
[Other breakdown items, or "None"]
```

## Rules

1. Title = user action, not implementation.
2. Must include "As a / I want / So that". No persona? → `[ASSUMPTION]`.
3. Given/When/Then for acceptance criteria.
4. Edge cases mandatory: invalid input, empty state, error.
5. Scope references real components from scan.
6. Min 3 acceptance criteria.

## Clarification Questions

| Check | Condition | Question | Priority |
|-------|-----------|----------|----------|
| Persona | No user role indicated | "Which user roles/personas?" | Blocking |
| Flows | Outcomes only, no interactions | "Key user flows step by step?" | Blocking |
| Done criteria | No user-perspective success conditions | "What can the user do when done?" | Quality |
| Happy path | No success scenario | "Ideal flow end-to-end?" | Quality |
| Edge cases | No error/empty/limit states | "What happens when things go wrong?" | Quality |
| UI behavior | Implies UI, no details | "UI requirements? (layout, interactions)" | Refinement |
| Accessibility | No a11y mention | "Accessibility requirements beyond defaults?" | Refinement |

## Using Clarification Context

Persona → "As a [role]". Flows → one Story per flow. Done criteria → Given/When/Then. Happy path → primary criteria. Edge cases → Edge Cases section. UI → Technical Context. A11y → acceptance criteria.

## Project Context

Reference existing UI components, analogous flows, API contracts, E2E test locations. Apply a11y conventions from CLAUDE.md.
