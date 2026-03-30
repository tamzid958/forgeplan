# Project Setup

Set up forgeplan for this project interactively.

## Step 1: OpenProject Connection

Ask the user for:
1. **OpenProject URL** (e.g., `https://op.example.com`)
2. **OpenProject API key** — tell them: "Log in → Avatar → My account → Access tokens → Generate → API"
3. **Default project slug** (from the OpenProject URL)

Write `.env` with only the secret:
```
OP_API_KEY=<key>
```

## Step 2: Layer Paths

Ask: "Layer paths, comma-separated (e.g., `backend,frontend` or `.` for single-repo)"

For each path:
- Derive the layer name from `basename` of the path (`.` → `app`)
- Analyze the directory to detect `techStack`, `filePatterns`, and `buildCmd`
  - Look at package.json, *.csproj, pubspec.yaml, go.mod, Cargo.toml, etc.
  - Identify frameworks, languages, and build commands from what you find

## Step 2b: Repo Root Detection

For each layer path, detect which git repo it belongs to:
```bash
git -C <layer_path> rev-parse --show-toplevel 2>/dev/null
```

Group layers by repo root. If layers are in different repos, record the `repoRoot` for each layer. If all layers share the same repo root, `repoRoot` stays `null`.

## Step 3: Optional Settings

Ask for:
- **PR reviewers** — comma-separated usernames, or skip
- **Commit trailer** — e.g., `Co-Authored-By: bot <bot@noreply>`, or skip (null)

## Step 3b: Toolchain Discovery

For each layer's `techStack`, identify required CLI tools and probe their locations:

| techStack | Required tools |
|-----------|---------------|
| `dotnet` | `dotnet` |
| `nextjs`, `react`, `vue`, `node` | `node`, `npm` |
| `flutter` | `flutter`, `dart` |
| `go` | `go` |
| `rust` | `cargo` |

For each tool:
1. Check `command -v <tool>` — if found, record as `null` (on PATH, no override needed)
2. If not found, probe common locations:
   - `~/.dotnet/dotnet`
   - `~/.nvm/current/bin/node`
   - `/usr/local/bin/<tool>`
   - `~/flutter/bin/flutter`
3. If found off-PATH, record the absolute path
4. If not found at all, ask the user for the path

Also detect platform CLI:
- `gh` for GitHub repos
- `glab` for GitLab repos

Store results in `toolPaths`.

## Step 3c: Hook Convention Discovery

For each unique repo root, scan for git hook managers:

```bash
# Check for hook managers
ls lefthook.yml lefthook-local.yml 2>/dev/null          # lefthook
ls .husky/pre-commit 2>/dev/null                         # husky
ls .pre-commit-config.yaml 2>/dev/null                   # pre-commit
grep -l '"lint-staged"' package.json 2>/dev/null         # lint-staged
```

If a hook manager is found:
1. Read the config file
2. Extract **branch naming regex** → convert to `branchFormat` template
3. Extract **commit message rules** → determine `commitSubjectMaxLength`
4. Detect **test parity checks** (e.g., lefthook `check-tests` script) → set `testParityRequired`
5. If test parity is required, detect the test file pattern:
   - Look for `__tests__/` → `__tests__/{path}/{name}.test.{ext}`
   - Look for `*.test.*` alongside source → `{dir}/{name}.test.{ext}`
   - Look for `*.spec.*` alongside source → `{dir}/{name}.spec.{ext}`
   - Look at existing test files for the convention

Store results in `hookConventions`.

## Step 3d: Test/Lint/Format Command Discovery

For each layer, detect available commands:

**Node.js layers** (nextjs, react, vue, etc.):
```bash
# Read package.json scripts
cat <layer_path>/package.json | jq '.scripts'
```
- `testCmd`: `npm run test:coverage` or `npm test` if script exists
- `lintFixCmd`: `npx eslint --fix .` if eslint is a devDependency
- `formatCmd`: `npx prettier --write .` if prettier is a devDependency

**.NET layers**:
- `testCmd`: find `*.Tests.csproj` or `*.Test.csproj` → `dotnet test <path> --filter "FullyQualifiedName!~Integration"`
- `lintFixCmd`: `dotnet format`
- `formatCmd`: `null` (dotnet format handles both)

**Flutter layers**:
- `testCmd`: `flutter test`
- `lintFixCmd`: `dart fix --apply`
- `formatCmd`: `dart format .`

**Go layers**:
- `testCmd`: `go test ./...`
- `lintFixCmd`: `golangci-lint run --fix` if installed
- `formatCmd`: `gofmt -w .`

Store results in `layerOverrides.<name>`.

## Step 4: Write Config Files

### forgeplan.config.json (shared, committed)

Assemble from Steps 1–3:
```json
{
  "openproject": { "url": "<url>", "projectId": "<slug>" },
  "layers": { ... },
  "routing": {
    "field": "category",
    "map": { "<name>": "<name>" },
    "defaultLayer": "<first layer>",
    "fallbackHeuristics": {
      "subjectTagPattern": "\\[([A-Za-z-]+)\\]",
      "descriptionKeywords": {}
    }
  },
  "reviewers": [...],
  "statuses": { ... },
  "commitTrailer": "<if provided>"
}
```

Ask the user: "Would you like to configure keyword-based routing? (For when WPs don't have a category set)" If yes, for each layer ask for 3–5 keywords that indicate that layer (e.g., "api, endpoint, controller" for backend).

### forgeplan.local.json (machine-specific, gitignored)

Assemble from Steps 3b–3d:
```json
{
  "toolPaths": { ... },
  "hookConventions": { ... },
  "layerOverrides": { ... }
}
```

## Step 5: Per-Repo Setup

For each unique git repo found across the layers:

### CLAUDE.md
If missing, analyze the codebase and generate a `CLAUDE.md` with:
- Tech stack and framework versions
- Naming conventions observed
- File/folder structure patterns
- Build and test commands
- Architectural patterns (e.g., repository pattern, clean architecture)
- Error handling conventions

### .gitignore
Ensure these are in `.gitignore`:
- `.env`
- `forgeplan.local.json`
- `logs/`

## Step 6: OpenProject Status Mapping

1. Test the connection:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3"
```

2. Fetch all statuses:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3/statuses"
```

3. Display the numbered status list to the user

4. Based on the status names, suggest mappings:
   - `pickup_status` — the "ready/todo" status
   - `in_progress_status` — the "in progress" status
   - `success_status` — the "in review" or "done" status
   - `partial_status` — the "in progress" status (or similar)
   - `failure_status` — 0 for no change, or a specific status

5. Ask the user to confirm or override each mapping

6. Merge the `statuses` section into `forgeplan.config.json`

## Done

Print a summary of everything created and next steps:
```
✓ forgeplan.config.json — shared project config
✓ forgeplan.local.json  — local toolchain + hooks
✓ .env                  — API key (gitignored)
✓ .gitignore            — updated

Next steps:
  /forgeplan doctor     # verify setup
  /forgeplan wp 123     # process a work package
  /forgeplan queue      # auto-discover ready WPs
```
