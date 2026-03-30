# forgeplan MCP Server

A Model Context Protocol server that exposes forgeplan's deterministic operations (config loading, OpenProject API, git workflow, layer routing, pipeline checks) as tools callable by any MCP client. The client LLM handles all generative operations (code writing); the server handles everything else.

## Prerequisites

- Node.js 18+
- forgeplan config files in your project root (`forgeplan.config.json`, `.env` with `OP_API_KEY`)
- `git`, and `gh` (GitHub) or `glab` (GitLab) CLI installed

## Build

```bash
cd mcp-server
npm install
npm run build
```

## Client Configuration

### Claude Code (`~/.claude/settings.json` or project `.mcp.json`)

```json
{
  "mcpServers": {
    "forgeplan": {
      "command": "node",
      "args": ["/absolute/path/to/forgeplan/mcp-server/dist/bin/forgeplan-mcp.js"]
    }
  }
}
```

### Cursor (`.cursor/mcp.json`)

```json
{
  "mcpServers": {
    "forgeplan": {
      "command": "node",
      "args": ["/absolute/path/to/forgeplan/mcp-server/dist/bin/forgeplan-mcp.js"]
    }
  }
}
```

### Windsurf (`~/.codeium/windsurf/mcp_config.json`)

```json
{
  "mcpServers": {
    "forgeplan": {
      "command": "node",
      "args": ["/absolute/path/to/forgeplan/mcp-server/dist/bin/forgeplan-mcp.js"]
    }
  }
}
```

### Continue (`~/.continue/config.json`)

```json
{
  "experimental": {
    "modelContextProtocolServers": [
      {
        "transport": {
          "type": "stdio",
          "command": "node",
          "args": ["/absolute/path/to/forgeplan/mcp-server/dist/bin/forgeplan-mcp.js"]
        }
      }
    ]
  }
}
```

## Usage

Once the MCP server is configured in your client, you interact with it through natural language prompts. The LLM automatically discovers and calls the forgeplan tools on your behalf.

### Process a single work package

The fastest way to start is with the built-in `process_work_package` prompt. In any MCP-aware client:

**Claude Code:**
```
Use the process_work_package prompt with wpId 42
```

**Cursor / Windsurf / Continue:**
Select the `process_work_package` prompt from the MCP prompt picker and enter the work package ID.

This triggers the full pipeline: load config → fetch WP → quality gate → route → branch → generate code → checks → commit → PR → update OpenProject.

### Natural language examples

You can also drive individual steps or the full pipeline with plain prompts:

```
# Full pipeline
Process OpenProject work package #42

# Queue discovery
Show me what work packages are ready to pick up

# Single WP inspection
Fetch work package #105 and show me the quality gate results

# Health check
Run forgeplan doctor on this project

# Sprint overview
List all work packages in the "Sprint 14" milestone

# Rollback
Rollback work package #42 — close the PRs and delete the branches

# Code review before commit
Review the generated code for WP #42 in the backend layer
```

### Step-by-step (manual control)

If you prefer to drive each step yourself:

```
1. Load the forgeplan config for /path/to/my/project
2. Fetch work package #42 and show me the quality gate
3. Route WP #42 to the right layers
4. Prepare a git branch for the backend layer
5. (you write code or ask the LLM to generate it)
6. Run the layer checks for backend
7. Commit and push the backend layer for WP #42
8. Create a PR for the backend layer
9. Finish WP #42 and post the summary to OpenProject
```

Each step maps to a specific tool call. The LLM translates your intent into the right tool with the right parameters.

### Using prompts vs. tools directly

| Approach | When to use |
|----------|-------------|
| **`process_work_package` prompt** | Full autopilot — LLM runs the entire pipeline end-to-end |
| **`review_generation` prompt** | Pause before committing to review generated code |
| **Natural language** | Ad-hoc commands, partial pipelines, exploration |
| **Direct tool calls** | Scripting, automation, or debugging specific steps |

## Tools

| Tool | Params | Description |
|------|--------|-------------|
| `forgeplan_load_config` | `projectRoot` | Load and validate forgeplan configuration |
| `forgeplan_doctor` | `projectRoot` | Run diagnostic health checks |
| `forgeplan_fetch_wp` | `wpId` | Fetch WP with quality gate evaluation |
| `forgeplan_fetch_wp_context` | `wpId` | Fetch full context (parents, siblings, children, relations, comments) |
| `forgeplan_list_sprint` | `sprintName?` | List WPs for a sprint/version |
| `forgeplan_wp_detail` | `wpId` | Fetch WP with full hierarchy tree |
| `forgeplan_discover_queue` | — | Discover ready WPs (assigned first, then unassigned) |
| `forgeplan_claim_wp` | `wpId`, `lockVersion` | Claim WP (assign + set in_progress) |
| `forgeplan_update_wp_status` | `wpId`, `statusKey`, `lockVersion` | Update WP status |
| `forgeplan_post_wp_comment` | `wpId`, `markdown` | Post a markdown comment on a WP |
| `forgeplan_route_wp` | `wpId`, `wpType`, `category?`, `subject`, `description` | Route WP to target layers |
| `forgeplan_derive_branch` | `wpId`, `wpType`, `subject` | Derive branch name per layer |
| `forgeplan_git_prepare_branch` | `layerName`, `branchName` | Fetch + create/resume branch |
| `forgeplan_git_status` | `layerName` | Get git status for a layer |
| `forgeplan_git_commit_and_push` | `layerName`, `wpId`, `wpType`, `subject`, `result`, `branchName`, `assumptions?` | Stage, commit, push |
| `forgeplan_git_create_pr` | `layerName`, `wpId`, `subject`, `result`, `branchName`, `baseBranch`, `assumptions?` | Create PR |
| `forgeplan_git_crosslink_prs` | `prs[]` | Add Related PRs section to multi-layer PRs |
| `forgeplan_rollback` | `wpId` | Close PRs, delete branches, revert status |
| `forgeplan_run_layer_checks` | `layerName` | Run format, lint, test, build with retries |
| `forgeplan_log_run` | `wpId`, `result`, `layers[]` | Append to JSONL run log |
| `forgeplan_finish_wp` | `wpId`, `lockVersion`, `layerResults[]` | Aggregate results, update OP, post summary, log |

## Resources

| URI | MIME Type | Description |
|-----|-----------|-------------|
| `forgeplan://rules/{wpType}` | `text/markdown` | Generation rules for a WP type (bug, feature, epic, story, subtask, task) |
| `forgeplan://config` | `application/json` | Current merged config (sanitized) |
| `forgeplan://log` | `application/jsonl` | Run summary log |

## Prompts

| Name | Arguments | Description |
|------|-----------|-------------|
| `process_work_package` | `wpId` | Full pipeline walkthrough from config to finish |
| `review_generation` | `wpId`, `layerName` | Review generated code before committing |

## Publishing

### Install from npm

Once published, users can install globally and reference the binary directly:

```bash
npm install -g @forgeplan/mcp-server
```

Then use `forgeplan-mcp` as the command in client configs:

```json
{
  "mcpServers": {
    "forgeplan": {
      "command": "forgeplan-mcp"
    }
  }
}
```

Or use `npx` without installing:

```json
{
  "mcpServers": {
    "forgeplan": {
      "command": "npx",
      "args": ["-y", "@forgeplan/mcp-server"]
    }
  }
}
```

### Publishing workflow

The package is published to npm automatically via GitHub Actions when you push a version tag.

#### 1. Set up npm token (one-time)

Generate a token at [npmjs.com/settings/tokens](https://www.npmjs.com/settings/tokens) (type: **Automation**) and add it as a repository secret:

```bash
gh secret set NPM_TOKEN --body "npm_XXXXXXXXXX"
```

If publishing a scoped package for the first time, ensure the org exists on npm:

```bash
npm org create forgeplan
```

#### 2. Bump version and tag

```bash
cd mcp-server
npm version patch   # or minor / major
git add package.json
git commit -m "chore: release @forgeplan/mcp-server@$(node -p 'require(\"./package.json\").version')"
git tag "mcp-server@$(node -p 'require("./package.json").version')"
git push origin master --tags
```

This triggers the `.github/workflows/publish-mcp-server.yml` workflow which:
1. Checks out the repo
2. Installs dependencies (`npm ci`)
3. Builds TypeScript (`npm run build`)
4. Publishes to npm with provenance (`npm publish --provenance --access public`)

#### 3. Verify

```bash
npm info @forgeplan/mcp-server
```

### Manual publish (without CI)

```bash
cd mcp-server
npm run build
npm publish --access public
```

## Example Orchestration Flow

```
1. forgeplan_load_config({ projectRoot: "/path/to/project" })
2. forgeplan_fetch_wp({ wpId: 42 })
3. forgeplan_fetch_wp_context({ wpId: 42 })
4. forgeplan_route_wp({ wpId: 42, wpType: "Bug", subject: "...", description: "..." })
5. Read forgeplan://rules/bug
6. forgeplan_claim_wp({ wpId: 42, lockVersion: 1 })
7. forgeplan_derive_branch({ wpId: 42, wpType: "Bug", subject: "Fix login timeout" })
8. forgeplan_git_prepare_branch({ layerName: "backend", branchName: "bug/WP-42-fix-login-timeout" })
9. ... (LLM generates code) ...
10. forgeplan_run_layer_checks({ layerName: "backend" })
11. forgeplan_git_commit_and_push({ layerName: "backend", wpId: 42, ... })
12. forgeplan_git_create_pr({ layerName: "backend", wpId: 42, ... })
13. forgeplan_finish_wp({ wpId: 42, lockVersion: 2, layerResults: [...] })
```
