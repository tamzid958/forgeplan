# Breakdown — Decompose an Epic into Work Items

Break down an Epic work package into structured Tasks, SubTasks, and Bugs using project context. Creates child work items in OpenProject after user approval.

**Usage:** `breakdown <EPIC_ID> [--dry-run]`

- `<EPIC_ID>` — OpenProject work package ID of the Epic to decompose
- `--dry-run` — generate and display the breakdown without creating WPs in OpenProject

---

## Step 1: Load Configuration

Load `.env`, `forgeplan.config.json`, and `forgeplan.local.json` as described in SKILL.md. Validate config. Resolve tool paths.

## Step 2: Scan Project Context

**This step is critical.** Before touching OpenProject, build a complete picture of the codebase.

Read the breakdown rules from `${CLAUDE_SKILL_DIR}/prompts/breakdown/`:
1. **Always read `_base.md` first** — shared decomposition rules and project context scan procedure
2. Then read **`epic-writing.md`** — Epic validation and layer mapping

Follow the **Project Context Scan** procedure from `_base.md`:
- Read `CLAUDE.md` from project root and each layer root
- Read `forgeplan.config.json` for layer definitions and routing
- Scan directory structures per layer (top 3 levels)
- Identify existing patterns: API routes, models, components, tests
- Check dependency manifests (`package.json`, `*.csproj`, `go.mod`, etc.)

Store the result as the **project snapshot** — this informs all generated items.

## Step 3: Fetch the Epic

```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${EPIC_ID}"
```

Extract and remember:
- `id`, `subject`, `lockVersion`
- `_links.type.title` → must be `Epic`. If not, STOP: "WP #${EPIC_ID} is a ${TYPE}, not an Epic."
- `_links.priority.title`, `_links.status.title`
- `description.raw` → full description
- `_links.category.title`, `_links.version.title`, `_links.version.href`, `_links.project.href`

## Step 4: Fetch Context

### Existing children
Extract `._links.children[].href`. Fetch each child's `id`, `subject`, `_links.type.title`, `_links.status.title`, `description.raw`.

If children exist, ask:
```
This Epic already has ${COUNT} child work packages:
${CHILDREN_LIST}

Options:
1. Generate additional items (will not duplicate existing)
2. Regenerate all (ignores existing)
3. Cancel

Choose [1/2/3]:
```

### Relations and Comments
Fetch relations and last 5 non-empty comments (same as `commands/wp.md` Steps 3).

## Step 5: Validate and Assess Epic

Follow `${CLAUDE_SKILL_DIR}/prompts/breakdown/epic-writing.md`:

### Hard Blocks (STOP)
- Empty description (null, empty, whitespace-only)
- Placeholder text ("TBD", "TODO", "WIP", "Description goes here", "Fill in later", "...", "N/A")

### Epic Assessment
Run the four assessments from `epic-writing.md`:
1. **Outcome Clarity** — is the outcome measurable?
2. **Scope Grounding** — does it reference real parts of the system?
3. **Technical Feasibility** — does it conflict with current architecture?
4. **Decomposability** — can it be split along natural seams?

### Layer Impact Analysis
Map the Epic's scope to project layers using the codebase scan and routing config:
```
Layer Impact Analysis:
  backend  — [deliverables touching this layer]
  frontend — [deliverables touching this layer]
  shared   — [cross-cutting concerns]
```

### Clarification
Collect all warnings and present as numbered questions. Wait for user response. If proceeding with assumptions, tag each with `[ASSUMPTION]`.

## Step 6: Decompose

Read the type-specific writing rules from `${CLAUDE_SKILL_DIR}/prompts/breakdown/`:
- **`task-writing.md`** — for generating Task items
- **`story-writing.md`** — for generating User Story items
- **`subtask-writing.md`** — for generating SubTask items
- **`bug-writing.md`** — for generating Bug items

Using ALL context (Epic description, project snapshot, user answers, existing children, relations, comments), generate work items following each type's structure and rules.

### Ordering
Follow the dependency ordering from `_base.md`:
1. Schema / model / migration work
2. Backend API / service work
3. Frontend / UI work
4. Integration / cross-cutting work
5. Bugs (early if blocking)

### Deduplication
If existing children were found (Step 4, option 1), compare by subject similarity and scope overlap. Skip duplicates.

## Step 7: Present Breakdown

Display:

```
## Epic Breakdown — #${EPIC_ID}: ${SUBJECT}
══════════════════════════════════════════════════════════════════════

### Project Context
  Layers:    ${LAYER_NAMES} (${TECH_STACKS})
  Patterns:  ${KEY_PATTERNS_FOUND}
  Similar:   ${ANALOGOUS_FEATURES_IF_ANY}

### Summary Table

| #  | Type    | Layer    | Title                                    | Parent       | Depends On |
|----|---------|----------|------------------------------------------|--------------|------------|
| 1  | Task    | backend  | Add retry endpoint to verification API   | Epic #${ID}  | —          |
| 2  | SubTask | backend  | Add retryCount to UserVerification model | Task #1      | —          |
| 3  | SubTask | backend  | Implement retry validation in AuthService| Task #1      | #2         |
| 4  | Story   | frontend | Retry failed email verification          | Epic #${ID}  | #1         |
| 5  | Task    | backend  | Implement retry rate limiting            | Epic #${ID}  | #1         |
| 6  | Bug     | backend  | Email link expires after 5min not 24h    | Epic #${ID}  | —          |

### Detailed Items

[Full details for each item per its type-specific writing rules]

══════════════════════════════════════════════════════════════════════
Total: ${TASK_COUNT} Tasks, ${STORY_COUNT} Stories, ${SUBTASK_COUNT} SubTasks, ${BUG_COUNT} Bugs
Layers touched: ${LAYERS_WITH_COUNTS}

${ASSUMPTIONS_SECTION}
```

Ask the user:
```
Options:
1. Create all items in OpenProject
2. Edit items first (tell me what to change)
3. Create selected items only (e.g., "1,2,4")
4. Cancel
```

**If `--dry-run`**: Display and STOP.

## Step 8: Resolve OpenProject Metadata

Before creating items, fetch type and priority IDs:

```bash
# Types available in this project
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/types"

# Priority levels
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/priorities"
```

Map type names → IDs: look for "Task", "User Story"/"User story", "Sub-Task"/"Subtask", "Bug" in `._embedded.elements[]`.
Map priority names → IDs: "Low", "Normal", "High", "Immediate", "Urgent".

If a required type is missing, warn and skip items of that type.

## Step 9: Create Work Items

Process in dependency order — parent Tasks before their SubTasks.

### Create WP
```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/hal+json" \
  -X POST \
  --data '{
    "subject": "${TITLE}",
    "description": { "raw": "${DESCRIPTION_BODY}" },
    "_links": {
      "type": { "href": "/api/v3/types/${TYPE_ID}" },
      "status": { "href": "/api/v3/statuses/${PICKUP_STATUS}" },
      "priority": { "href": "/api/v3/priorities/${PRIORITY_ID}" },
      "parent": { "href": "/api/v3/work_packages/${PARENT_ID}" },
      "project": { "href": "${PROJECT_HREF}" },
      "version": { "href": "${VERSION_HREF}" }
    }
  }' \
  "${OP_BASE_URL}/api/v3/work_packages"
```

- **Task/Bug**: `parent` = Epic ID
- **SubTask**: `parent` = newly created parent Task ID (from this session)
- **Version**: inherit from Epic if set
- **Category**: set from routing map if the layer maps to a category

Capture each created WP's `id`.

### Build Description Body

Use the structure defined in each type's writing rules. The description is the full body generated in Step 6, plus a footer:

```markdown
---
Generated by forgeplan breakdown from Epic #${EPIC_ID}
```

## Step 10: Create Relations

For each dependency identified in the breakdown:

```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/hal+json" \
  -X POST \
  --data '{
    "_links": {
      "from": { "href": "/api/v3/work_packages/${DEPENDENT_ID}" },
      "to": { "href": "/api/v3/work_packages/${DEPENDENCY_ID}" }
    },
    "_type": "Relation",
    "type": "follows"
  }' \
  "${OP_BASE_URL}/api/v3/relations"
```

## Step 11: Post Summary and Report

### Comment on Epic
```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/hal+json" \
  -X POST \
  --data "{\"comment\": {\"raw\": \"${SUMMARY_TABLE}\"}}" \
  "${OP_BASE_URL}/api/v3/work_packages/${EPIC_ID}/activities"
```

### Display Result
```
forgeplan breakdown — Epic #${EPIC_ID}: ${SUBJECT}
══════════════════════════════════════════════════════════════════════

  CREATED
  ────────────────────────────────────────────────────────────────────
  Tasks: ${TASK_COUNT}  Stories: ${STORY_COUNT}  SubTasks: ${SUBTASK_COUNT}  Bugs: ${BUG_COUNT}
  Relations: ${RELATION_COUNT}

  | Type    | WP     | Layer    | Title                              |
  |---------|--------|---------|------------------------------------|
  | Task    | #${ID} | backend | ${TITLE}                           |
  | SubTask | #${ID} | backend | ${TITLE}                           |
  | Bug     | #${ID} | backend | ${TITLE}                           |

══════════════════════════════════════════════════════════════════════
  View in OpenProject: ${OP_BASE_URL}/work_packages/${EPIC_ID}
```

## Error Handling

- **API failures**: report but continue. List failures at the end.
- **Type not found**: warn and skip items of that type.
- **Rate limiting (429)**: wait 2 seconds, retry once.
- **Partial creation**: post partial summary noting what succeeded and failed.
