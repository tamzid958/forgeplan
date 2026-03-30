# Queue Mode — Auto-Discover and Process Ready WPs

Find all work packages with the `pickup_status` and process them.

## Step 1: Load Configuration

Load `.env` and `forgeplan.config.json`. Extract the `pickup_status` name and its numeric ID from `statuses._status_ids`.

## Step 2: Query OpenProject

```bash
STATUS_ID=$(jq '.statuses._status_ids[.statuses.pickup_status]' forgeplan.config.json)

curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/work_packages?filters=[{\"status\":{\"operator\":\"=\",\"values\":[\"${STATUS_ID}\"]}}]&sortBy=[[\"priority\",\"desc\"],[\"id\",\"asc\"]]"
```

Extract all WP IDs from `._embedded.elements[].id`.

## Step 3: Process

If no WPs found, report "No work packages ready for processing."

Otherwise, tell the user how many were found and process each one following `commands/wp.md`.

Between each WP, switch back to base branch and ensure clean state.

## Step 4: Summary

Print the same batch summary as `commands/batch.md`.
