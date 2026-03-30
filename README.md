# Forgeplan

**Forge Code from Plans** — Turn OpenProject work packages into production code using Claude Code.

Forgeplan is a Claude Code skill that connects to your OpenProject instance, reads a work package (bug, feature, epic, etc.), gathers full context (hierarchy, siblings, relations, comments, codebase structure), generates production code across one or more layers, and handles the entire git workflow: branch, commit, push, and PR creation — with a summary posted back to OpenProject.

---

## How It Works

```
OpenProject Work Package
        │
        ▼
  ┌─────────────────┐
  │   /forgeplan     │ ← Claude Code skill
  │                  │
  │  1. Fetch WP     │──── OpenProject API
  │  2. Gather       │
  │     context      │──── hierarchy, siblings, relations, comments
  │  3. Route to     │
  │     layer(s)     │──── category, tags, description keywords
  │  4. Per-layer:   │
  │     ┌──────────┐ │
  │     │ Generate  │ │──── Claude Code writes files
  │     │ Lint/Fmt  │ │──── auto-fix before commit
  │     │ Test      │ │──── full suite + transitive fix
  │     │ Commit    │ │──── sanitized message
  │     │ Push + PR │ │──── gh / glab CLI
  │     └──────────┘ │
  │  5. Cross-link   │──── PR ↔ PR references
  │  6. Feedback     │──── status + comment on WP
  └─────────────────┘
```

---

## Prerequisites

| Tool | Required | How to Install |
|------|----------|----------------|
| **Claude Code** | Yes | `npm i -g @anthropic-ai/claude-code` or `brew install claude-code` |
| **curl** | Yes | Pre-installed on most systems |
| **jq** | Yes | `brew install jq` or `apt install jq` |
| **git** | Yes | Pre-installed on most systems |
| **gh** | For GitHub PRs | `brew install gh` then `gh auth login` |
| **glab** | For GitLab MRs | `brew install glab` then `glab auth login` |
| **OpenProject** | Yes | Any deployment (cloud, VPS, Docker, SaaS) |

---

## Installation

### Option A: Install to your project (recommended)

```bash
mkdir -p .claude/skills
git clone https://github.com/tamzid958/forgeplan.git .claude/skills/forgeplan
```

### Option B: Install globally (all projects)

```bash
git clone https://github.com/tamzid958/forgeplan.git ~/.claude/skills/forgeplan
```

### Verify

Open Claude Code in your project and type:
```
/forgeplan doctor
```

---

## Quick Start

### Step 1: Set up your project

```
/forgeplan init
```

This walks you through interactive setup:

1. **OpenProject connection** — URL, API key, project slug → creates `.env`
2. **Layer paths** — comma-separated (e.g., `backend,frontend` or `.`)
3. **Repo detection** — auto-detects if layers live in separate git repos
4. **Toolchain discovery** — finds `dotnet`, `node`, `flutter`, etc. even if off-PATH
5. **Hook detection** — reads lefthook/husky/pre-commit config for branch naming, commit rules, test parity
6. **Test/lint/format commands** — auto-detected per layer from package.json, *.csproj, etc.
7. **Config generation** — builds `forgeplan.config.json` (shared) + `forgeplan.local.json` (machine-specific)
8. **CLAUDE.md** — generated per repo by analyzing each codebase
9. **Status mapping** — connects to OpenProject, discovers statuses, maps pipeline events

### Step 2: Verify setup

```
/forgeplan doctor
```

### Step 3: Process a work package

```
/forgeplan wp 123
```

---

## Usage

### Process a single work package

```
/forgeplan wp 123
```

### Dry run (preview without side effects)

```
/forgeplan wp 123 --dry-run
```

Shows target layers, branch name, and base branches without generating code or touching git/OpenProject.

### List work packages

```
/forgeplan list                  # current sprint, top 50
/forgeplan list --sprint "S-12"  # specific sprint
/forgeplan list 123              # WP detail with parent, siblings, children, relations
```

Sprint view shows a table with priority, type, status, assignee, and layer. Your assigned WPs appear first. Detail view shows the full hierarchy tree.

### Process multiple work packages

```
/forgeplan batch 123,124,125
```

Processes each WP sequentially. Prints a summary at the end.

### Queue mode

```
/forgeplan queue
```

Auto-discovers WPs with `pickup_status`. Shows assigned-to-you WPs first, then unassigned. Displays the queue and lets you choose which to process.

### Rollback

```
/forgeplan rollback 123
```

Undoes a previous generation across all layers:
- Closes PR(s)
- Deletes remote and local branch(es)
- Reverts the WP status in OpenProject
- Posts a rollback comment

### Health check

```
/forgeplan doctor
```

Checks dependencies, config files, toolchain, OpenProject connectivity, git repos, hooks, and auth status.

---

## Configuration

### Two-file config system

| File | Purpose | Git |
|------|---------|-----|
| `forgeplan.config.json` | Shared project config (layers, routing, statuses, reviewers) | Committed |
| `forgeplan.local.json` | Machine-specific (toolPaths, hookConventions, layer overrides) | Gitignored |
| `.env` | Secrets only (`OP_API_KEY`) | Gitignored |

`forgeplan.local.json` is deep-merged on top of `forgeplan.config.json` at load time. The `init` command generates both files.

### forgeplan.config.json

```json
{
  "openproject": { "url": "https://op.example.com", "projectId": "my-project" },
  "layers": {
    "backend": { "path": "src/backend", "techStack": "dotnet", "filePatterns": ["**/*.cs"], "buildCmd": "dotnet build" },
    "frontend": { "path": "src/frontend", "techStack": "nextjs", "filePatterns": ["**/*.tsx"], "buildCmd": "npm run build" }
  },
  "routing": {
    "field": "category",
    "map": { "Backend": "backend", "Frontend": "frontend", "Full-Stack": ["backend", "frontend"] },
    "defaultLayer": "backend",
    "fallbackHeuristics": {
      "subjectTagPattern": "\\[([A-Za-z-]+)\\]",
      "descriptionKeywords": { "backend": ["api", "endpoint"], "frontend": ["component", "modal"] }
    }
  },
  "reviewers": [],
  "statuses": { "pickup_status": 1, "in_progress_status": 7, "success_status": 19, "partial_status": 7, "failure_status": 0 },
  "commitTrailer": null
}
```

### forgeplan.local.json

```json
{
  "toolPaths": { "dotnet": "~/.dotnet/dotnet" },
  "hookConventions": {
    "manager": "lefthook",
    "branchFormat": "{type}/WP-{id}-{slug}",
    "commitSubjectMaxLength": 72,
    "testParityRequired": true,
    "testFilePattern": "__tests__/{path}/{name}.test.{ext}"
  },
  "layerOverrides": {
    "backend": { "repoRoot": "/path/to/backend-repo", "testCmd": "dotnet test", "lintFixCmd": "dotnet format" },
    "frontend": { "repoRoot": "/path/to/frontend-repo", "testCmd": "npm run test:coverage", "formatCmd": "npx prettier --write ." }
  }
}
```

---

## Multi-Repo Support

Forgeplan handles monorepos and multi-repo setups. If your layers live in separate git repos, `init` detects this and stores each layer's `repoRoot` in `forgeplan.local.json`. During `wp` processing, each layer gets its own branch, commit, push, and PR in its respective repo. PRs are cross-linked automatically.

---

## Hook Integration

Forgeplan reads your git hook configuration (lefthook, husky, pre-commit) during `init` and stores conventions in `forgeplan.local.json`. During code generation:

1. **Branch names** follow your hook's naming rules
2. **Commit messages** are sanitized to fit your format and length limits
3. **Formatting and linting** are auto-fixed before committing
4. **Test parity** — if your hooks require test files for new source files, forgeplan generates them alongside

---

## Pipeline Steps

When you run `/forgeplan wp <ID>`:

```
 1. Load config (shared + local + .env)
 2. Resolve tool paths
 3. Fetch WP + context (hierarchy, siblings, relations, comments)
 4. Determine target layer(s) via routing + fallback heuristics
 5. Quality gate (reject empty descriptions)
 6. Claim assignee + set WP status → IN PROGRESS
 7. Derive branch name from WP type + hook conventions
 8. Per-layer loop:
    8a. Git preflight + branch (resume if exists)
    8b. Generate code + tests
    8c. Auto-fix formatting/lint + pre-commit dry run
    8d. Run full test suite (fix transitive breakage)
    8e. Validate build
    8f. Sanitize commit message + commit
    8g. Push
    8h. Create PR
 9. Cross-link PRs across layers
10. Update OpenProject status + post summary comment
11. Log to run-summary.jsonl
```

### Result Types

| Result | What Happened | Git | WP Status |
|--------|--------------|-----|-----------|
| **SUCCESS** | Code generated, all checks passed | Commit + push + PR | `success_status` |
| **PARTIAL** | Code generated, some checks failed | `[WIP]` commit + push + PR | `partial_status` |
| **FAILURE** | No code generated | No commit | `failure_status` |

---

## Generation Rules

Forgeplan applies type-specific rules based on the WP type:

| WP Type | Focus |
|---------|-------|
| **Task** | Complete implementation |
| **Bug** | Root cause fix + regression test |
| **Feature** | Full feature with existing patterns |
| **Epic** | Scaffolding only, no child implementations |
| **User Story** | User-facing behavior |
| **Subtask** | Scoped to subtask boundaries only |

Rules are in `prompts/`. Customize them to change generation behavior.

---

## Project Structure

```
forgeplan/
  SKILL.md                        # Dispatcher + config loading + API reference
  commands/
    wp.md                         # Core multi-layer WP pipeline
    list.md                       # List sprint WPs / WP detail with hierarchy
    batch.md                      # Process multiple WPs
    queue.md                      # Auto-discover ready WPs (assigned first)
    init.md                       # Interactive project setup + discovery
    rollback.md                   # Undo a generation (multi-layer)
    doctor.md                     # Health check
    help.md                       # Command reference
  prompts/
    task-rules.md                 # Default generation rules
    bug-rules.md                  # Bug fix rules
    feature-rules.md              # Feature rules
    epic-rules.md                 # Epic/scaffold rules
    story-rules.md                # User story rules
    subtask-rules.md              # Subtask rules
  forgeplan.config.json.example   # Shared config template
  forgeplan.local.json.example    # Local config template
  README.md
```

---

## Command Reference

| Command | Description |
|---------|-------------|
| `/forgeplan help` | Show all commands and usage |
| `/forgeplan init` | Interactive project setup + toolchain/hook discovery |
| `/forgeplan doctor` | Health check (config, tools, connectivity, hooks) |
| `/forgeplan list` | List WPs for current sprint (top 50, yours first) |
| `/forgeplan list --sprint "S-12"` | List WPs for a specific sprint |
| `/forgeplan list <ID>` | Show WP details with parent, siblings, children, relations |
| `/forgeplan wp <ID>` | Process a single work package (multi-layer) |
| `/forgeplan wp <ID> --dry-run` | Preview routing and branch without side effects |
| `/forgeplan batch <ID,ID,ID>` | Process multiple WPs sequentially |
| `/forgeplan queue` | Auto-discover and process ready WPs (assigned first) |
| `/forgeplan rollback <ID>` | Undo: close PR(s), delete branch(es), revert status |

---

## Troubleshooting

### "OP_API_KEY not found"
Create a `.env` file with your API key, or run `/forgeplan init`.

### "forgeplan.config.json not found"
Run `/forgeplan init` to generate it.

### "forgeplan.local.json not found"
Run `/forgeplan init` to detect toolchain and hook conventions.

### "Tool 'dotnet' not found"
The tool isn't on PATH. Set `toolPaths.dotnet` in `forgeplan.local.json` or run `/forgeplan init` to re-detect.

### "Cannot reach OpenProject"
Check `openproject.url` in `forgeplan.config.json`. Verify the server is reachable.

### "Authentication failed"
Your `OP_API_KEY` is invalid or expired. Generate a new one in OpenProject → My Account → Access Tokens.

### "Commit blocked by hook"
Forgeplan auto-fixes formatting/lint and retries up to 3 times. If still failing, check the hook output for the specific rule violation. Run `/forgeplan init` to re-detect hook conventions.

### "No auth token for PR creation"
Run `gh auth login` (GitHub) or `glab auth login` (GitLab).

### Claude generates wrong code
Improve your `CLAUDE.md` with more specific conventions. Use `/forgeplan rollback <ID>` to undo.

### Checking logs
```bash
cat logs/run-summary.jsonl | jq .
```

---

## License

MIT
