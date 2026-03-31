# Epic Validation Rules
> Inherits: _base.md — run before decomposition begins.

## Assessment

Evaluate the Epic on four dimensions. Flag issues as clarification questions.

| Dimension | Check | If weak |
|-----------|-------|---------|
| **Outcome clarity** | Measurable end state? Not just activity? | Ask for success criteria |
| **Scope grounding** | References real system parts? Maps to layers? | Ask which modules it touches |
| **Technical feasibility** | Fits current stack? Conflicts with architecture? | Flag: "Epic assumes [X], codebase uses [Y]" |
| **Decomposability** | Natural seams for independent Tasks? | Suggest split boundaries |

## Layer Mapping

Before decomposing, map Epic scope to layers and report:
1. Match requirements to layers via `routing.map` and codebase scan.
2. Note cross-cutting concerns → separate Tasks with dependency links.
3. Present to user:
```
Layer Impact:  backend — [deliverables]  |  frontend — [deliverables]  |  shared — [cross-cutting]
```

## Clarification Questions

| Check | Condition | Question | Priority |
|-------|-----------|----------|----------|
| Problem | No problem/motivation | "What problem does this Epic solve?" | Blocking |
| Outcome | No success criteria | "What does success look like? How measured?" | Blocking |
| Scope | No in/out of scope | "What is in scope and out of scope?" | Blocking |
| Personas | No target users | "Who are the target users/roles?" | Quality |
| Contracts | No shared interfaces/models | "What shared interfaces or data models across components?" | Quality |
| Tech decisions | No architectural direction | "Any architecture decisions made? (patterns, libraries)" | Quality |
| Dependencies | External refs without detail | "External dependencies? (APIs, teams, timelines)" | Quality |
| Breaking changes | Implies changing public APIs/schemas | "Breaking changes? Backwards compatibility needed?" | Refinement |
| Rollout | No shipping strategy | "Rollout preference? (feature flag, phased, all-at-once)" | Refinement |

## Using Clarification Context

| Answer | Apply to |
|--------|----------|
| Problem → | Anchor every child item's Summary |
| Outcome → | Derive top-level acceptance criteria across children |
| Scope → | Enforce in/out of scope; reject out-of-scope items |
| Personas → | Pass to Story "As a [role]" statements |
| Contracts → | Create interface/model Tasks at top of dependency chain |
| Tech decisions → | Embed in Technical Context of every child |
| Dependencies → | Flag in relevant items' Dependencies |
| Breaking changes → | Add backwards-compat criteria where needed |
| Rollout → | Add feature flag / phased rollout Tasks if needed |

## Project Context Enrichment

- Find **analogous features** in codebase → use as breakdown template.
- Split along **existing module boundaries**, not arbitrary lines.
- APIs → one Task per resource/endpoint group.
- New data → schema Task first.
- UI → split by page or feature module.
