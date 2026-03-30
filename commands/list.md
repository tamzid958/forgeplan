# List Work Packages

Display work packages from OpenProject. Two modes based on arguments:

- `list` or `list --sprint <name>` → **Sprint view**: show WPs for current/named sprint
- `list <ID>` → **Detail view**: show a single WP with full hierarchy

## Step 1: Load Configuration

Load `.env`, `forgeplan.config.json`, and `forgeplan.local.json` as described in SKILL.md.

---

## Mode A: Sprint View (`list` or `list --sprint <name>`)

### Step 2a: Query OpenProject

If `--sprint <name>` is provided, filter by sprint (called "version" in OpenProject API):

```bash
# Find the version ID by name
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/versions" \
  | jq '.._embedded.elements[] | select(.name == "<sprint_name>") | .id'

# Query WPs in that version
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/work_packages?filters=[{\"version\":{\"operator\":\"=\",\"values\":[\"${VERSION_ID}\"]}}]&sortBy=[[\"priority\",\"desc\"],[\"id\",\"asc\"]]&pageSize=50"
```

If no `--sprint` flag, find the current active sprint:

```bash
# Get versions, find the one with status "open" and closest endDate to today
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/versions"
```

Pick the version with `status == "open"` whose `endDate` is closest to (but not before) today. If no active sprint found, fall back to all open WPs (no version filter) with `pageSize=50`.

### Step 3a: Fetch Assignee Info

For the "assigned to you" indicator, fetch the current user:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/users/me"
```
Extract the user's `id` to compare with WP assignees.

### Step 4a: Display Sprint View

For each WP in the response, extract:
- `id`
- `subject` (truncate to 50 chars if needed)
- `_links.type.title`
- `_links.priority.title`
- `_links.status.title`
- `_links.assignee.title` (or "unassigned")
- `_links.category.title` → resolve to layer name via `routing.map`

Display as a table, sorted by: assigned-to-you first, then by priority:

```
forgeplan list — Sprint "S-12" (Mar 24 – Apr 7) — 23 work packages
══════════════════════════════════════════════════════════════════════════════
  #  │ WP     │ Pri    │ Type     │ Status       │ Assignee       │ Layer     │ Subject
─────┼────────┼────────┼──────────┼──────────────┼────────────────┼───────────┼──────────────────────────
  1  │ 16549  │ High   │ Task     │ IN PROGRESS  │ ★ You          │ iam       │ Module delete modal — va…
  2  │ 16550  │ High   │ Bug      │ TO DO        │ ★ You          │ frontend  │ Fix token expiry on refr…
  3  │ 16551  │ Normal │ Feature  │ TO DO        │ Alice          │ backend   │ Add export button to rep…
  4  │ 16552  │ Normal │ Task     │ IN PROGRESS  │ Bob            │ frontend  │ Update user profile form
  5  │ 16553  │ Low    │ Subtask  │ TO DO        │ (unassigned)   │ —         │ Write unit tests for aut…
  …  │  …     │  …     │    …     │      …       │      …         │     …     │        …
══════════════════════════════════════════════════════════════════════════════
  Showing 23 of 23 │ ★ 2 assigned to you │ 8 TO DO │ 5 IN PROGRESS │ 10 other
```

**Limits:**
- If total > 50, show only top 50 by priority and note: "Showing 50 of {total} — use `--sprint <name>` to narrow"
- Layer column shows "—" if category is null and no heuristic match

---

## Mode B: Detail View (`list <ID>`)

### Step 2b: Fetch the WP

```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}"
```

Extract all fields from Step 2 of `wp.md`.

### Step 3b: Fetch Hierarchy

**Parent chain** (up to 2 levels):
If `_links.parent.href` exists, fetch the parent. If the parent also has a parent, fetch that too.

**Siblings**:
If the WP has a parent, fetch the parent's `_links.children[]`. For each sibling (excluding current WP), fetch `id`, `subject`, `_links.type.title`, `_links.status.title`.

**Children**:
Extract `_links.children[].href` from the WP. Fetch each child's `id`, `subject`, `_links.type.title`, `_links.status.title`.

**Relations**:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/relations"
```
For each relation, fetch the related WP's `id`, `subject`, `_links.status.title`. Note the relation type.

### Step 4b: Display Detail View

```
forgeplan list #16549
══════════════════════════════════════════════════════════════════════

  WORK PACKAGE
  ────────────────────────────────────────────────────────────────────
  ID:          16549
  Subject:     [IAM] Delete modal — Validate active role dependencies
  Type:        Task
  Priority:    Normal
  Status:      IN PROGRESS
  Assignee:    Tamzid Ahmed
  Category:    —
  Sprint:      S-12
  Created:     2026-03-28
  Updated:     2026-03-30

  DESCRIPTION
  ────────────────────────────────────────────────────────────────────
  Update the Module delete confirmation modal to block deletion if
  the module has permissions attached to active Roles, and require a
  mandatory reason when deletion is permitted.
  [... truncated at 500 chars, full description available in OpenProject]

  HIERARCHY
  ────────────────────────────────────────────────────────────────────

  ▲ PARENT
  └─ #16461  Epic  │ TO DO │ Close Client-Reported Gaps Across IAM…

  ● CURRENT
  └─ #16549  Task  │ IN PROGRESS │ [IAM] Delete modal — Validate…

  ► SIBLINGS (under #16461)
  ├─ #16550  Bug   │ TO DO       │ Fix token expiry on refresh
  ├─ #16551  Task  │ TO DO       │ Add export button to reports
  ├─ #16552  Task  │ IN PROGRESS │ Update user profile form
  └─ #16553  Task  │ DONE        │ Fix pagination on user list

  ▼ CHILDREN
  (none)

  RELATIONS
  ────────────────────────────────────────────────────────────────────
  relates to  │ #16410 │ IN REVIEW  │ Permission panel refactor
  blocks      │ #16560 │ TO DO      │ Module cascade delete cleanup

══════════════════════════════════════════════════════════════════════
  View in OpenProject: ${OP_BASE_URL}/work_packages/16549
```

**Notes:**
- Description is truncated at 500 characters with a link to OpenProject for the full text
- Siblings list is capped at 20 entries. If more, show "... and N more siblings"
- If no parent, skip the PARENT and SIBLINGS sections
- If no children, show "(none)"
- If no relations, show "(none)"
