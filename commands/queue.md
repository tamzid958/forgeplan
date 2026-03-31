# Queue Mode — Auto-Discover and Process Ready WPs

Find work packages ready for processing, prioritizing those assigned to the current user.

## Step 1: Load Configuration

Load config from `.claude/forgeplan/` as described in SKILL.md. Extract `pickup_status` from `statuses`.

## Step 2: Query OpenProject (Assigned First)

Use `--data-urlencode` with `-G` (GET) to properly encode filter JSON in the URL.

### Query 1: WPs assigned to the current user
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" -G \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/work_packages" \
  --data-urlencode 'filters=[{"assignee":{"operator":"=","values":["me"]}},{"status":{"operator":"=","values":["'"${PICKUP_STATUS_ID}"'"]}}]' \
  --data-urlencode 'sortBy=[["priority","desc"],["id","asc"]]' \
  --data-urlencode 'pageSize=50'
```

### Query 2: All unassigned WPs
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" -G \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/work_packages" \
  --data-urlencode 'filters=[{"assignee":{"operator":"!*","values":[]}},{"status":{"operator":"=","values":["'"${PICKUP_STATUS_ID}"'"]}}]' \
  --data-urlencode 'sortBy=[["priority","desc"],["id","asc"]]' \
  --data-urlencode 'pageSize=50'
```

Merge results: assigned WPs first, then unassigned. Deduplicate by ID.

## Step 3: Display Queue

If no WPs found, report "No work packages ready for processing."

Otherwise, display the queue to the user before processing:

```
forgeplan queue — ${TOTAL} work package(s) found
═══════════════════════════════════════════════════
  #  | WP ID  | Priority | Type    | Subject              | Assigned
  1  | 16549  | High     | Task    | Module delete modal   | ★ You
  2  | 16550  | Normal   | Bug     | Fix token expiry      | ★ You
  3  | 16551  | Normal   | Feature | Add export button     | (unassigned)
═══════════════════════════════════════════════════
```

Ask the user: "Process all, or enter specific WP IDs to process (comma-separated)?"

## Step 4: Process

Process each selected WP following `commands/wp.md`.

Between each WP, for each layer's repo root:
- Switch back to the base branch
- Ensure clean working tree

## Step 5: Summary

Print the same batch summary as `commands/batch.md`.
