# Rollback a Work Package

Undo a previous forgeplan generation for WP ID from the arguments.

## Step 1: Find the Run

Read `logs/run-summary.jsonl` and find the most recent entry matching the WP ID:
```bash
grep "\"wp_id\":${WP_ID}" logs/run-summary.jsonl | tail -1
```

Parse the entry. Handle two formats:

**Multi-layer format** (v2):
```json
{"wp_id": 123, "result": "SUCCESS", "layers": [{"name": "backend", "branch": "...", "pr_url": "...", "result": "SUCCESS"}, ...]}
```

**Legacy single-layer format** (v1):
```json
{"wp_id": 123, "result": "SUCCESS", "branch": "...", "pr_url": "..."}
```
Convert legacy to multi-layer: `[{"name": "unknown", "branch": "...", "pr_url": "..."}]`

If no entry found, ask the user for the branch name(s) manually.

## Step 2: Close PRs (per layer)

For each layer entry with a `pr_url`:

### GitHub
```bash
gh pr close "${PR_URL}" --comment "Rolled back by forgeplan"
```

### GitLab
```bash
glab mr close <MR_ID> --comment "Rolled back by forgeplan"
```

If the CLI tool is not available, print the URL and ask the user to close it manually.

## Step 3: Delete Branches (per layer)

For each layer entry, determine the repo root (from `layerOverrides.<name>.repoRoot` in config, or project root):

```bash
cd <repo_root>

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

# Update status back to pickup
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
  --data '{"comment":{"raw":"## forgeplan Rollback\n\nCode generation reverted. Branch(es) and PR(s) deleted."}}' \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/activities"
```

Report the rollback result to the user.
