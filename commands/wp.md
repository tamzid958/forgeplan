# Process a Single Work Package

Process WP ID from the arguments. Parse optional `--dry-run` flag. Follow this pipeline exactly in order.

## Step 1: Load Configuration

Load `.env`, `forgeplan.config.json`, and `forgeplan.local.json` as described in the main SKILL.md. Validate config. Resolve tool paths.

## Step 2: Fetch Work Package

Fetch the WP from OpenProject:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}"
```

Extract and remember:
- `id`, `subject`, `lockVersion`
- `_links.type.title` → WP type (Bug, Feature, Task, Epic, User Story, Subtask)
- `_links.priority.title` → priority
- `_links.status.title` → current status
- `description.raw` → full description text
- `_links.category.title` → category (for layer routing)
- `_links.parent.href` → parent WP link (if any)
- `_links.assignee.href` → current assignee (if any)

## Step 3: Fetch Context

Gather all context in parallel where possible:

### Parent hierarchy
If the WP has a parent, fetch it. If the parent also has a parent, fetch that too (max 2 levels up).

### Siblings (shallow)
If the WP has a parent, extract `_links.children[]` from the parent response to get sibling WPs. For each sibling (excluding the current WP), note the `id` and `subject` only.

**Deep-fetch siblings only when WP type is `Subtask`** — subtasks share data structures and benefit from knowing sibling scope. For subtask siblings, also fetch `description.raw` and `_links.status.title`.

### Children
Extract `._links.children[].href` from the WP response and fetch each child's id, subject, type, and status.

### Relations
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/relations"
```
For each relation, note the type (blocks, relates, follows, etc.) and the related WP's subject and status.

### Comments
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}/activities"
```
Extract the last 5 entries where `comment.raw` is non-empty. Note the author and date.

## Step 4: Determine Target Layers

Route the WP to one or more layers:

1. Read `routing.field` from config (default: `category`)
2. Get the value of that field from the WP (e.g., the category title)
3. **If the value is non-null**, look it up in `routing.map`:
   - If found and it's a string → single layer `[layerName]`
   - If found and it's an array → multiple layers
4. **If the value is null or not found** (fallback heuristics):
   a. Try `routing.fallbackHeuristics.subjectTagPattern` against the WP subject. If a tag like `[Backend]` matches a key in `routing.map`, use that mapping.
   b. Scan the WP description for keywords defined in `routing.fallbackHeuristics.descriptionKeywords`. Score each layer by keyword hit count. Use layers with hits.
   c. If still no match, use `routing.defaultLayer` but **warn the user** and ask for confirmation before proceeding.
5. For each resolved layer, load its full config (path, techStack, buildCmd, repoRoot, testCmd, lintFixCmd, formatCmd).

## Step 5: Quality Gate and Clarification

Before claiming the WP or writing any code, evaluate whether the WP provides enough information to generate a correct implementation. This step prevents wasted work from vague requirements.

### 5a: Hard Blocks (STOP — cannot proceed)

Check for these conditions first. If ANY are true, tell the user and **do not proceed**:

- **Empty description**: description is null, empty, or whitespace-only
- **Placeholder text**: description matches common placeholders — "TBD", "TODO", "WIP", "Description goes here", "Fill in later", "...", "N/A"
- **Duplicate of another WP**: description is identical to a sibling's description (compare against siblings fetched in Step 3)

Present the issue and ask the user to either update the WP in OpenProject or provide the missing information in the conversation.

### 5b: Type-Specific Completeness Checks

Run the appropriate checks based on WP type. Each check produces a **warning** with a specific question. Collect all warnings before presenting them.

#### Bug
| Check | Condition | Question |
|-------|-----------|----------|
| Reproduction steps | Description lacks words like "steps", "reproduce", "when", "then", "expected", "actual" | "How do you reproduce this bug? What is the expected vs actual behavior?" |
| Error context | No error messages, stack traces, or log excerpts mentioned | "Are there any error messages, stack traces, or log output?" |
| Environment | No mention of environment, browser, version, or platform | "What environment does this occur in? (browser, OS, version, etc.)" |
| Affected area | Cannot determine which files/modules/endpoints are involved | "Which part of the system is affected? (endpoint, page, service, etc.)" |

#### Feature
| Check | Condition | Question |
|-------|-----------|----------|
| Acceptance criteria | No bullet list, numbered list, or phrases like "should", "must", "can" | "What are the acceptance criteria? What defines 'done' for this feature?" |
| Data model | Feature implies new data but no fields/types/schema mentioned | "What data does this feature handle? Any specific fields, types, or constraints?" |
| API contract | Feature implies an endpoint but no method/path/payload described | "What should the API look like? (method, path, request/response shape)" |
| UI behavior | Feature implies UI but no interaction flow described | "What should the user see and interact with? Any specific UI requirements?" |
| Auth/permissions | Feature touches user-facing functionality but no access control mentioned | "Who can access this? Any role or permission requirements?" |

#### User Story
| Check | Condition | Question |
|-------|-----------|----------|
| Acceptance criteria | Same as Feature | Same as Feature |
| User persona | No "As a ..." or clear indication of which user type | "Which user role/persona is this for?" |
| Happy path | No clear success scenario described | "What does the successful flow look like step by step?" |
| Edge cases | No mention of error states, empty states, or limits | "What happens when things go wrong? (invalid input, empty data, limits)" |

#### Epic
| Check | Condition | Question |
|-------|-----------|----------|
| Scope boundaries | No children listed AND description doesn't outline sub-components | "What are the main components/sub-features this epic covers?" |
| Shared contracts | No mention of interfaces, shared models, or API boundaries | "What shared interfaces or data models should the scaffolding define?" |
| Tech decisions | No architectural direction (e.g., which pattern, framework features to use) | "Any architectural decisions already made? (patterns, libraries, conventions)" |

#### Task
| Check | Condition | Question |
|-------|-----------|----------|
| Specificity | Description is under 100 characters | "Can you provide more detail on what exactly needs to be implemented?" |
| Expected output | No mention of files, endpoints, classes, or concrete deliverables | "What files or components should this produce?" |

#### Subtask
| Check | Condition | Question |
|-------|-----------|----------|
| Scope boundary | Cannot determine where this subtask's scope ends and siblings begin | "What is the exact boundary of this subtask vs its siblings?" |
| Dependencies | Subtask references work from a sibling but that sibling's status is not `closed`/`done` | "This depends on sibling WP #X which isn't done yet. Should I proceed anyway?" |

### 5c: General Checks (all types)

| Check | Condition | Question |
|-------|-----------|----------|
| Short description | Under 50 characters (but not empty/placeholder — those are hard blocks) | "The description is very brief. Can you elaborate on the requirements?" |
| Ambiguous scope | Description contains phrases like "maybe", "or we could", "not sure if", "TBD on" | "There are open questions in the description. Can you clarify: [quote the ambiguous parts]?" |
| External dependency | Description references an external service, API, or system not in the codebase | "This references [external system]. What are the integration details? (URL, auth, format)" |
| Breaking change | Description implies changing an existing public API, schema, or contract | "This looks like it changes an existing interface. Should I maintain backwards compatibility?" |

### 5d: Present and Resolve

If there are **no warnings**, proceed silently to Step 6.

If there are warnings:

1. Present a numbered list of questions, grouped under a header:

```
## Clarification Needed — WP #${WP_ID}

I can proceed with the information available, but answering these questions will improve the result:

1. [Question from check]
2. [Question from check]
...

Reply with answers, or say "proceed" to continue with what's available.
```

2. **Wait for the user's response.** Do not proceed until the user either:
   - Answers the questions (incorporate answers into the WP context for code generation)
   - Says "proceed", "skip", "continue", or equivalent (proceed with best-effort assumptions)
   - Says "stop" or "cancel" (abort the pipeline)

3. If the user provides answers, store them as additional context alongside the WP description for use in Step 8b (code generation). Do NOT update the WP description in OpenProject unless the user explicitly asks.

4. If proceeding with assumptions (user said "proceed"), log each assumption clearly:
```
[ASSUMPTION]: No auth requirements specified — implementing without access control
[ASSUMPTION]: No error response format specified — using existing API error conventions
```
These assumptions will be included in the PR body (Step 8h) so reviewers can verify them.

## Step 6: Claim Assignee and Update WP Status to In Progress

Using the `lockVersion` from Step 2, update the status to `in_progress_status` from config. Also claim the WP if not already assigned to the current user.

**Assignee resolution:** If `openproject.assigneeUserId` is set in `forgeplan.local.json`, use `/api/v3/users/<assigneeUserId>`. Otherwise fall back to `/api/v3/users/me` (note: `/api/v3/users/me` silently fails for assignee updates on some OpenProject instances).

```bash
curl -s -u "apikey:${OP_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/hal+json" \
  -X PATCH \
  --data "{\"lockVersion\": ${LOCK_VERSION}, \"_links\": {\"status\": {\"href\": \"/api/v3/statuses/${IN_PROGRESS_STATUS}\"}, \"assignee\": {\"href\": \"/api/v3/users/${ASSIGNEE_USER_ID}\"}}}" \
  "${OP_BASE_URL}/api/v3/work_packages/${WP_ID}"
```

**CRITICAL**: Capture the new `lockVersion` from the PATCH response body. Store it for Step 9.

If HTTP 409 (conflict), re-fetch the WP for a fresh `lockVersion` and retry once.

## Step 7: Derive Branch Name

1. Map WP type to branch type:

| WP Type | Branch Type |
|---------|-------------|
| Bug | `bug` |
| Feature | `feature` |
| Epic | `feature` |
| User Story | `feature` |
| Task | `task` |
| Subtask | `subtask` |

2. Generate slug from subject: lowercase, replace non-alphanumeric with `-`, collapse consecutive dashes, trim trailing dashes
3. Read `hookConventions.branchFormat` from config (default: `{type}/WP-{id}-{slug}`)
4. Read `hookConventions.commitSubjectMaxLength` (default: 72)
5. Substitute `{type}`, `{id}`, `{slug}` into the format. **Truncate the slug** so the total branch name does not exceed 80 characters.

Store the result as `BRANCH_NAME`.

**If `--dry-run` was specified**: Print a summary and STOP here.
```
DRY RUN — WP #${WP_ID}
  Subject:  ${SUBJECT}
  Type:     ${WP_TYPE} → branch type: ${BRANCH_TYPE}
  Layers:   ${LAYER_NAMES}
  Branch:   ${BRANCH_NAME}
  Per-layer base branches: ${BASE_BRANCHES}
```

## Step 8: Per-Layer Loop

For each target layer (from Step 4), execute Steps 8a through 8h. Track results in a `layerResults` map.

### Step 8a: Git Preflight and Branch (per-layer)

Determine the repo context:
- If `layer.repoRoot` is set, `cd` to that path
- Otherwise, use the project root

```bash
git status --porcelain
git fetch origin
```

Derive the base branch for this repo:
```bash
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's|refs/remotes/origin/||')
```

**Resume check**: Before creating a new branch, check if one already exists for this WP:
```bash
git branch --list "*WP-${WP_ID}*"
git branch -r --list "*WP-${WP_ID}*"
```
- If a local branch exists, check it out: `git checkout "${BRANCH_NAME}"`
- If only a remote branch exists, check it out: `git checkout -b "${BRANCH_NAME}" "origin/${BRANCH_NAME}"`
- If no branch exists, create from base: `git checkout -b "${BRANCH_NAME}" "origin/${BASE_BRANCH}"`

Also check `logs/run-summary.jsonl` for a previous entry for this WP. If a previous run recorded `SUCCESS` for this layer, skip it and move to the next layer.

### Step 8b: Generate Code

**This is where you implement the work package.** You ARE the code generator.

1. Read the project's `CLAUDE.md` for conventions (from this layer's repo root)
2. Read the target layer's directory structure to understand patterns
3. Read the generation rules from `${CLAUDE_SKILL_DIR}/prompts/`:
   a. **Always read `_base.md` first** — shared rules for all WP types
   b. Then read the type-specific delta file (inherits `_base.md`):
      - Bug → `bug-rules.md`
      - Feature → `feature-rules.md`
      - Epic → `epic-rules.md`
      - User Story → `story-rules.md`
      - Subtask → `subtask-rules.md`
      - Task / default → `task-rules.md`
4. Using ALL the context gathered (description, hierarchy, siblings, children, relations, comments, layer info), implement the work package
5. Write files using Edit/Write tools into the correct layer path
6. Follow every convention from CLAUDE.md
7. **If `hookConventions.testParityRequired` is true**: for every new source file generated, also generate a corresponding test file matching `hookConventions.testFilePattern`

### Step 8c: Auto-Fix and Pre-Commit Dry Run

Before committing, run formatting and linting to prevent hook failures:

1. If `layer.formatCmd` is set, run it on the generated/modified files
2. If `layer.lintFixCmd` is set, run it on the generated/modified files
3. Stage all changes: `git add -A`
4. If `hookConventions.manager` is set, run the pre-commit hooks:
   - **lefthook**: `lefthook run pre-commit`
   - **husky**: inspect `.husky/pre-commit` and run each command
   - **pre-commit**: `pre-commit run --all-files`
5. If the dry run fails:
   - Parse the error output
   - Formatting errors → re-run formatCmd
   - Lint errors → re-run lintFixCmd
   - Test parity errors → generate missing test files
   - Re-stage and retry (max 3 attempts)
6. If still failing after 3 attempts, classify this layer as `PARTIAL` and continue

### Step 8d: Run Full Test Suite

If `layer.testCmd` is set:

1. Run the full test suite: `cd <layer_path> && <testCmd>`
2. If tests fail:
   - If failure is in a file we modified → attempt to fix the code
   - If failure is in an unrelated file (transitive import breakage) → analyze the import chain, add missing mocks or fix the transitive dependency
   - Re-run tests (max 2 fix attempts)
3. If tests still fail after retries, classify this layer as `PARTIAL`

### Step 8e: Validate Build

If the layer has a `buildCmd`:
```bash
cd <layer_path> && <buildCmd>
```

Classify the result:
- **SUCCESS**: code generated AND build passes
- **PARTIAL**: code generated BUT build or tests fail
- **FAILURE**: no code generated or critical error

If PARTIAL, try to fix the build errors (max 2 attempts). If fixed, reclassify as SUCCESS.

### Step 8f: Sanitize Commit Message and Commit

1. Map WP type to conventional commit prefix:
   - Feature, User Story, Epic → `feat`
   - Bug → `fix`
   - Task, Subtask → `chore`

2. Build raw subject: `{prefix}(WP-{id}): {subject}`

3. Read `hookConventions.commitSubjectMaxLength` (default 72). If the raw subject exceeds this limit, truncate `{subject}` and append `...`

4. For PARTIAL results, prefix with `[WIP] `

5. Build commit body:
```
<subject line>

Generated by forgeplan
Result: ${RESULT}
OpenProject: ${OP_BASE_URL}/work_packages/${WP_ID}
```

6. If `commitTrailer` is set in config, append it to the body

7. Commit:
```bash
git add -A
git commit -m "<full message>"
```

8. If commit fails (hook rejection), parse the error, fix, and retry (max 2 retries)

### Step 8g: Push

```bash
git push -u origin "${BRANCH_NAME}"
```

If push hooks fail, fix and retry (max 2 retries).

### Step 8h: Create PR

Use the platform CLI based on the git host type. **Always pass `--base` explicitly.**

#### GitHub
```bash
gh pr create \
  --title "${COMMIT_SUBJECT}" \
  --body "<PR body>" \
  --base "${BASE_BRANCH}" \
  --reviewer "${REVIEWERS}"
```

#### GitLab
```bash
glab mr create --title "..." --description "..." --target-branch "${BASE_BRANCH}"
```

PR body template:
```
## Auto-generated by forgeplan

**OpenProject WP:** #${WP_ID} — [View](${OP_BASE_URL}/work_packages/${WP_ID})
**Result:** ${RESULT}

### Files Changed
$(git diff --name-only origin/${BASE_BRANCH}...HEAD | sed 's/^/- /')

### Assumptions
$(if assumptions were logged in Step 5d, list each one here)
- [ASSUMPTION]: ...
- [ASSUMPTION]: ...

(If no assumptions were made, omit this section entirely.)

---
Generated by forgeplan (Claude Code skill)
```

Add labels if supported: `auto-generated`, `wp-${WP_ID}`

Store the PR URL in `layerResults[layerName].prUrl`.

## Step 8-post: PR Cross-Linking

After ALL layers have completed Steps 8a–8h, if multiple layers produced PRs:

For each PR, edit the body to append a "Related PRs" section:
```
### Related PRs
- **backend**: https://github.com/org/backend/pull/92
- **frontend**: https://github.com/org/frontend/pull/72
```

Use `gh pr edit <PR_URL> --body "..."` (GitHub) or `glab mr update` (GitLab).

## Step 9: Update OpenProject

Aggregate layer results:
- If ALL layers are SUCCESS → overall `SUCCESS`
- If ANY layer is PARTIAL → overall `PARTIAL`
- If ANY layer is FAILURE → overall `FAILURE` (unless at least one succeeded, then `PARTIAL`)

1. Update WP status based on overall result:
   - SUCCESS → `success_status`
   - PARTIAL → `partial_status`
   - FAILURE → `failure_status` (if not 0)

   Use the `lockVersion` captured from Step 6. **Capture the new lockVersion from the response.**

2. Post a summary comment:
```
## forgeplan Report

| Layer | Result | Branch | PR |
|-------|--------|--------|----|
| ${LAYER_NAME} | ${RESULT} | `${BRANCH_NAME}` | ${PR_URL} |
| ... | ... | ... | ... |

**Overall:** ${OVERALL_RESULT}

Generated by forgeplan (Claude Code skill)
```

## Step 10: Log Summary

```bash
mkdir -p logs
```

Append a JSON line to `logs/run-summary.jsonl`:
```json
{"wp_id": ${WP_ID}, "result": "${OVERALL_RESULT}", "layers": [{"name": "${LAYER_NAME}", "branch": "${BRANCH_NAME}", "pr_url": "${PR_URL}", "result": "${LAYER_RESULT}"}, ...], "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
```

Report the final result to the user.
