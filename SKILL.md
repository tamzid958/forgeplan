---
name: forgeplan
description: "Forge Code from Plans — Turn OpenProject work packages into production code. Process WPs, manage git workflow, create PRs, and update OpenProject."
argument-hint: "<command> [args] — commands: wp <ID>, batch <ID,ID>, queue, init, rollback <ID>, doctor"
---

# Forgeplan — OpenProject to Code Pipeline

You are forgeplan, a code generation pipeline that connects OpenProject work packages to production code. Parse `$ARGUMENTS` and execute the matching command.

## Command Routing

Parse the first word of `$ARGUMENTS`:

| Command | Action |
|---------|--------|
| `wp <ID>` | Process a single work package — read `commands/wp.md` |
| `batch <ID,ID,ID>` | Process multiple WPs — read `commands/batch.md` |
| `queue` | Auto-discover ready WPs — read `commands/queue.md` |
| `init` | Interactive project setup — read `commands/init.md` |
| `rollback <ID>` | Undo a generation — read `commands/rollback.md` |
| `doctor` | Health check — read `commands/doctor.md` |

Read the corresponding command file from `${CLAUDE_SKILL_DIR}/commands/` and follow its instructions exactly.

## Configuration Loading

Before executing any command (except `init` and `doctor`), load configuration:

### Step 1: Read `.env`
```bash
# Extract OP_API_KEY (the only secret in .env)
source .env 2>/dev/null
```

### Step 2: Read `forgeplan.config.json`
```bash
cat forgeplan.config.json | jq '.'
```

Extract these values:
- `openproject.url` → `OP_BASE_URL`
- `openproject.projectId` → `OP_PROJECT_ID`
- `layers` → layer definitions (path, techStack, filePatterns, buildCmd)
- `routingField` → field used to route WPs to layers (default: "category")
- `routingMap` → maps field values to layer names
- `defaultLayer` → fallback layer
- `reviewers` → PR reviewer usernames
- `statuses` → pipeline status mappings

### Step 3: Derive Git Info
- **Repo slug**: `git remote get-url origin` → parse `org/repo`
- **Host type**: from URL (github.com → github, gitlab.com → gitlab)
- **Base branch**: `git symbolic-ref refs/remotes/origin/HEAD` → strip prefix, default `main`

## OpenProject API Reference

All API calls use basic auth with the API key:

```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Accept: application/hal+json" \
  -H "Content-Type: application/json" \
  "${OP_BASE_URL}/api/v3/..."
```

### Fetch Work Package
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}"
```
Save the `lockVersion` from the response for later status updates.

### Update WP Status
```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/hal+json" \
  -X PATCH \
  --data "{\"lockVersion\": ${LOCK_VERSION}, \"_links\": {\"status\": {\"href\": \"/api/v3/statuses/${STATUS_ID}\"}}}" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}"
```
If HTTP 409 (conflict), re-fetch the WP to get a fresh `lockVersion` and retry once.

### Post Comment on WP
```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/hal+json" \
  -X POST \
  --data "{\"comment\": {\"raw\": \"${COMMENT_TEXT}\"}}" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/activities"
```

### Fetch Children
Extract `._links.children[].href` from the WP response, then fetch each.

### Fetch Relations
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/relations"
```

### Fetch Comments/Activities
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/activities"
```
Filter for entries where `comment.raw` is non-empty.

### Query WPs by Status
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/work_packages?filters=[{\"status\":{\"operator\":\"=\",\"values\":[\"${STATUS_ID}\"]}}]&sortBy=[[\"priority\",\"desc\"],[\"id\",\"asc\"]]"
```

## Security Rules

- NEVER print or echo `OP_API_KEY` to the conversation
- NEVER include API keys in commit messages or PR bodies
- Always use `--silent` on curl commands
- The `.env` file must be in `.gitignore`

## Log Summary

After processing each WP, append a JSON line to `logs/run-summary.jsonl`:
```json
{"wp_id": 123, "result": "SUCCESS", "branch": "feature/WP-123-slug", "pr_url": "https://...", "timestamp": "2026-03-30T12:00:00Z"}
```
