---
name: forgeplan
description: "Forge Code from Plans — Turn OpenProject work packages into production code. Process WPs, manage git workflow, create PRs, and update OpenProject."
argument-hint: "<command> [args] — commands: wp <ID> [--dry-run], list [<ID>|--sprint <name>], batch <ID,ID>, queue, init, rollback <ID>, doctor, help"
---

# Forgeplan — OpenProject to Code Pipeline

You are forgeplan, a code generation pipeline that connects OpenProject work packages to production code. Parse `$ARGUMENTS` and execute the matching command.

## Command Routing

Parse the first word of `$ARGUMENTS`:

| Command | Action |
|---------|--------|
| `wp <ID> [--dry-run]` | Process a single work package — read `commands/wp.md` |
| `list [--sprint <name>]` | List WPs for current/named sprint — read `commands/list.md` |
| `list <ID>` | Show WP details with hierarchy — read `commands/list.md` |
| `batch <ID,ID,ID>` | Process multiple WPs — read `commands/batch.md` |
| `queue` | Auto-discover ready WPs — read `commands/queue.md` |
| `init` | Interactive project setup — read `commands/init.md` |
| `rollback <ID>` | Undo a generation — read `commands/rollback.md` |
| `doctor` | Health check — read `commands/doctor.md` |
| `help` | Show all commands and usage — read `commands/help.md` |

Read the corresponding command file from `${CLAUDE_SKILL_DIR}/commands/` and follow its instructions exactly.

## Configuration Loading

Before executing any command (except `init` and `doctor`), load configuration:

### Step 1: Read `.env`
```bash
source .env 2>/dev/null
```
Verify `OP_API_KEY` is loaded and non-empty. NEVER print its value.

### Step 2: Read and Merge Config Files

**Primary config** (committed, shared):
```bash
cat forgeplan.config.json
```

**Local config** (gitignored, machine-specific):
```bash
cat forgeplan.local.json 2>/dev/null
```

Deep-merge `forgeplan.local.json` on top of `forgeplan.config.json`:
- `toolPaths` from local overrides/extends
- `hookConventions` from local overrides/extends
- `layerOverrides.<name>` fields merge into matching `layers.<name>` entries (e.g., `layerOverrides.backend.repoRoot` → `layers.backend.repoRoot`)

If `forgeplan.local.json` is missing, warn: "Run `/forgeplan init` to detect toolchain and hook conventions."

Extract from merged config:
- `openproject.url` → `OP_BASE_URL`
- `openproject.projectId` → `OP_PROJECT_ID`
- `layers` → layer definitions (path, techStack, filePatterns, buildCmd, testCmd, lintFixCmd, formatCmd, repoRoot)
- `routing` → routing config (field, map, defaultLayer, fallbackHeuristics)
- `toolPaths` → custom executable paths
- `hookConventions` → branch format, commit rules, test parity
- `reviewers` → PR reviewer usernames
- `statuses` → pipeline status mappings
- `commitTrailer` → optional commit message trailer

### Step 3: Validate Config

Before proceeding, validate:
- **Required**: `openproject.url`, `openproject.projectId`, at least one layer in `layers`
- **Per-layer**: `path` exists on disk, `buildCmd` is non-empty
- **Routing**: `routing.map` has entries OR `routing.defaultLayer` is set
- **Statuses**: `in_progress_status` and `success_status` are non-zero
- **OP_API_KEY**: loaded from `.env` and non-empty

On failure, print an error table and suggest `/forgeplan init`.

### Step 4: Resolve Tool Paths

For each tool referenced by layers' `techStack`, resolve the executable:
1. Check `toolPaths.<tool>` from config — if set, use it
2. Otherwise, `command -v <tool>` — if found, use it
3. If neither works, FAIL with: "Tool '<tool>' not found. Run `/forgeplan init` or set `toolPaths.<tool>` in `forgeplan.local.json`."

Common tool mappings:
- `dotnet` techStack → needs `dotnet`
- `nextjs`, `react`, `vue`, `node` → needs `node`, `npm`
- `flutter` → needs `flutter`, `dart`
- `go` → needs `go`
- `rust` → needs `cargo`
- All layers → needs `git`, and `gh` (GitHub) or `glab` (GitLab)

### Step 5: Derive Git Info (per layer)

For each layer, determine its git context:
```bash
cd <layer_path_or_repoRoot>
git remote get-url origin 2>/dev/null   # → repoSlug (org/repo)
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'  # → baseBranch
```

Parse host type from URL: `github.com` → github, `gitlab.com` → gitlab.

Store per-layer: `repoSlug`, `hostType`, `baseBranch`.

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

### Update WP Status (and/or Assignee)
```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/hal+json" \
  -X PATCH \
  --data "{\"lockVersion\": ${LOCK_VERSION}, \"_links\": {\"status\": {\"href\": \"/api/v3/statuses/${STATUS_ID}\"}, \"assignee\": {\"href\": \"/api/v3/users/me\"}}}" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}"
```

**CRITICAL**: Every PATCH response returns an updated `lockVersion`. Always capture and store it for subsequent updates. If HTTP 409 (conflict), re-fetch the WP for a fresh `lockVersion` and retry once.

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

### Query WPs by Status (with assignee filter)

**Important**: Filters and sortBy must be URL-encoded when passed as query parameters. Build the filter JSON, then URL-encode it before appending to the URL.

```bash
# Build filter JSON, then URL-encode
FILTERS='[{"assignee":{"operator":"=","values":["me"]}},{"status":{"operator":"=","values":["'"${STATUS_ID}"'"]}}]'
SORT='[["priority","desc"],["id","asc"]]'
ENCODED_FILTERS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${FILTERS}'))")
ENCODED_SORT=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SORT}'))")

# Assigned to current user
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/work_packages?filters=${ENCODED_FILTERS}&sortBy=${ENCODED_SORT}"

# Unassigned WPs — change filter operator to "!*" (none) with empty values
FILTERS_UNASSIGNED='[{"assignee":{"operator":"!*","values":[]}},{"status":{"operator":"=","values":["'"${STATUS_ID}"'"]}}]'

# All WPs (no assignee filter)
FILTERS_ALL='[{"status":{"operator":"=","values":["'"${STATUS_ID}"'"]}}]'
```

Alternatively, use `--data-urlencode` with GET:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" -G \
  "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}/work_packages" \
  --data-urlencode "filters=${FILTERS}" \
  --data-urlencode "sortBy=${SORT}" \
  --data-urlencode "pageSize=50"
```

## Clarification Protocol

Before claiming any WP (Step 6 in `commands/wp.md`), you MUST run the quality gate (Step 5). This step evaluates whether the WP has enough information for correct code generation.

**Behavior rules:**
- Hard blocks (empty, placeholder, duplicate descriptions) → STOP, ask user to fix
- Type-specific checks (missing acceptance criteria, no repro steps, etc.) → collect all warnings, present as numbered questions
- Always wait for the user to respond before proceeding — never auto-skip clarification
- If the user says "proceed" without answering, log assumptions with `[ASSUMPTION]` tags
- Assumptions carry through to code generation (Step 8b) and appear in the PR body (Step 8h)
- Never update the WP description in OpenProject unless the user explicitly asks

The generation rules in `prompts/` each have a "Using Clarification Context" section that explains how to apply the user's answers during code generation.

## Security Rules

- NEVER print or echo `OP_API_KEY` to the conversation
- NEVER include API keys in commit messages or PR bodies
- Always use `--silent` on curl commands
- The `.env` file must be in `.gitignore`
- `forgeplan.local.json` must be in `.gitignore`

## Log Summary

After processing each WP, append a JSON line to `logs/run-summary.jsonl`:
```json
{"wp_id": 123, "result": "SUCCESS", "layers": [{"name": "backend", "branch": "task/WP-123-slug", "pr_url": "https://...", "result": "SUCCESS"}, {"name": "frontend", "branch": "task/WP-123-slug", "pr_url": "https://...", "result": "SUCCESS"}], "timestamp": "2026-03-30T12:00:00Z"}
```
