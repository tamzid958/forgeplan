# Health Check

Run diagnostic checks and report pass/warn/fail for each. Do NOT load configuration via the standard pipeline — this command must handle missing/broken config gracefully.

## Check 1: Dependencies

Check each tool exists and report its version:

| Tool | Check | Required |
|------|-------|----------|
| curl | `curl --version` | Yes |
| jq | `jq --version` | Yes |
| git | `git --version` | Yes |
| gh | `gh --version` | No (needed for GitHub PRs) |
| glab | `glab --version` | No (needed for GitLab MRs) |

At least one of `gh`/`glab` must be present.

## Check 2: Config Validation

### .claude/forgeplan/forgeplan.config.json
- If missing: ✗ FAIL — "Run `/forgeplan init` to create config"
- If present: validate JSON syntax, then check required fields:
  - `openproject.url` — non-empty string
  - `openproject.projectId` — non-empty string
  - `layers` — at least one layer defined
  - Each layer: `path` exists on disk, `buildCmd` non-empty
  - `routing.defaultLayer` or `routing.map` — at least one must exist
  - `statuses.in_progress_status` and `statuses.success_status` — non-zero integers
- Report each field as ✓ or ✗ with reason

### .claude/forgeplan/forgeplan.local.json
- If missing: ⚠ WARN — "Run `/forgeplan init` to detect toolchain and hooks"
- If present: validate JSON syntax

### .claude/forgeplan/.env
- If `OP_API_KEY` is empty or unset: ✗ FAIL
- If set: ✓ (never print the value)

## Check 3: Toolchain

For each tool referenced in `toolPaths` (from `.claude/forgeplan/forgeplan.local.json`) or required by layers' `techStack`:

1. Resolve the path (config override → `command -v` → common paths)
2. If found: ✓ with version output
3. If not found: ✗ FAIL

Also check per-layer commands from `layerOverrides`:
- `buildCmd` — verify the command's tool is executable
- `testCmd` — if set, verify tool exists
- `lintFixCmd` — if set, verify tool exists
- `formatCmd` — if set, verify tool exists

## Check 4: OpenProject Connection

Test API connectivity:
```bash
curl -s -o /dev/null -w '%{http_code}' -u "apikey:${OP_API_KEY}" \
  -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3"
```
- 200 = ✓ connected
- 401/403 = ✗ FAIL (bad API key)
- 000 = ✗ FAIL (unreachable)

Verify project exists:
```bash
curl -s -o /dev/null -w '%{http_code}' -u "apikey:${OP_API_KEY}" \
  -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}"
```

## Check 5: Repository (per layer)

For each layer, determine its repo root (`layerOverrides.<name>.repoRoot` or project root):

1. Check the layer path exists on disk
2. Check it's inside a git repo: `git -C <path> rev-parse`
3. Check the remote exists: `git -C <path> remote get-url origin`
4. Check `CLAUDE.md` exists in the repo root: ✓ or ⚠ WARN
5. Check `.claude/forgeplan/.env` and `.claude/forgeplan/forgeplan.local.json` are in `.gitignore`: ✓ or ⚠ WARN

## Check 6: Hook Conventions

If `hookConventions.manager` is set in `.claude/forgeplan/forgeplan.local.json`:

1. Verify the manager is installed: `command -v <manager>`
2. Verify the config file exists: `hookConventions.configFile`
3. Report detected settings:
   - Branch format: `{branchFormat}`
   - Commit max length: `{commitSubjectMaxLength}`
   - Test parity required: `{testParityRequired}`

If not set: ⚠ WARN — "Run `/forgeplan init` to detect hook conventions"

## Check 7: Git Auth

Based on detected host type from repo remotes:

- GitHub: `gh auth status`
- GitLab: `glab auth status`

Report ✓ or ✗.

## Summary

Print a table:

```
forgeplan doctor
═══════════════════════════════════════════
  Dependencies     ✓ curl, jq, git, gh
  Config (shared)  ✓ .claude/forgeplan/forgeplan.config.json
  Config (local)   ✓ .claude/forgeplan/forgeplan.local.json
  API Key          ✓ loaded from .claude/forgeplan/.env
  Toolchain        ✓ dotnet (v10.0), node (v22.0)
  OpenProject      ✓ connected to my-project
  Repository       ✓ backend (github.com/org/backend)
                   ✓ frontend (github.com/org/frontend)
  Hooks            ✓ lefthook (branch, commit, tests)
  Git Auth         ✓ github.com (user: alice)
═══════════════════════════════════════════
  Result: 9/9 passed, 0 warnings, 0 failures
```
