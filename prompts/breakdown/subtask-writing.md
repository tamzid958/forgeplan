# SubTask Writing Rules
> Inherits: _base.md

A SubTask is a **narrow execution step** under a Task. Only create when a Task spans multiple modules, has sequential phases, or involves distinct create-then-integrate steps.

**Do NOT create SubTasks** for every Task, as a to-do list, or for trivially small steps.

## Structure

```
Title: [exact target — file, class, function]
Type: SubTask
Parent Task: [Task title]
Priority: [same as parent]

## Objective
[One sentence: concrete result]

## Work Details
Layer: ${LAYER_NAME} (${TECH_STACK}) | Target files: [exact paths] | Pattern: [reference file]
[Steps referencing real code structures]

## Definition of Done
- [ ] [verifiable check]
- [ ] [verifiable check]

## Sibling Context
Previous: [what preceding SubTask delivers] | Next: [what following SubTask expects]
```

## Rules

1. Title names the exact target — file, class, function.
2. Objective is one sentence. Two = too broad.
3. Work Details reference real code paths.
4. Sibling Context prevents overlap.
5. Definition of Done: 1-3 checks. More = too broad.
6. Must have a parent Task.

## Clarification Questions

| Check | Condition | Question | Priority |
|-------|-----------|----------|----------|
| Scope boundaries | Can't determine where SubTasks divide | "For [Task X], distinct phases or components to track separately?" | Quality |
| Sequencing | Unclear if order matters | "For [Task X], sequential or parallel steps?" | Refinement |
| Shared interfaces | SubTasks interact but contract unclear | "Data/interface passed between [SubTask A] and [SubTask B]?" | Quality |

## Using Clarification Context

Scope → precise in/out per SubTask. Sequencing → `follows` relations or mark parallel. Interfaces → include contract in both SubTasks' Work Details.

## Project Context

Name exact file paths. Reference existing similar code as pattern. Note import/export chains.
