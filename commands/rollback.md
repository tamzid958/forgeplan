# Rollback a Work Package

Undo a previous forgeplan generation for WP ID from the arguments.

## Step 1: Find the Run

Read `logs/run-summary.jsonl` and find the entry matching the WP ID:
```bash
grep "\"wp_id\":${WP_ID}" logs/run-summary.jsonl | tail -1
```

Extract: `branch`, `pr_url`, `result`.

If no entry found, ask the user for the branch name manually.

## Step 2: Close the PR

If `pr_url` is set:

### GitHub
```bash
gh pr close "${PR_URL}" --comment "Rolled back by forgeplan"
```

### GitLab
```bash
glab mr close <MR_ID> --comment "Rolled back by forgeplan"
```

If the CLI tool is not available, print the URL and ask the user to close it manually.

## Step 3: Delete the Branch

```bash
# Delete remote branch
git push origin --delete "${BRANCH}"

# Switch to base branch
git checkout "$(git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||')"

# Delete local branch
git branch -D "${BRANCH}"
```

## Step 4: Revert OpenProject Status

Load config and update the WP status back to `pickup_status`:

```bash
# Fetch fresh lockVersion
WP_JSON=$(curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}")
LOCK_VERSION=$(echo "$WP_JSON" | jq '.lockVersion')
PICKUP_STATUS_ID=$(jq '.statuses._status_ids[.statuses.pickup_status]' forgeplan.config.json)

# Update status
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" -H "Accept: application/hal+json" \
  -X PATCH \
  --data "{\"lockVersion\":${LOCK_VERSION},\"_links\":{\"status\":{\"href\":\"/api/v3/statuses/${PICKUP_STATUS_ID}\"}}}" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}"
```

## Step 5: Post Rollback Comment

```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" -H "Accept: application/hal+json" \
  -X POST \
  --data '{"comment":{"raw":"Forgeplan rollback: Code generation reverted. Branch and PR deleted."}}' \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/activities"
```

Report the rollback result to the user.
