# Forgeplan

**Forge Code from Plans** — Turn OpenProject work packages into production code using Claude Code.

Forgeplan connects to your OpenProject instance, reads a work package (bug, feature, epic, etc.), builds a rich prompt with full context (hierarchy, relations, comments, codebase structure), feeds it to Claude Code CLI, and handles the entire git workflow: branch, commit, push, and PR creation — with a summary posted back to OpenProject.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [.env File](#env-file)
  - [Layer Config](#layer-config-forgeplansconfigjson)
  - [Status Mapping](#status-mapping---init)
- [Usage](#usage)
  - [Process a Single Work Package](#process-a-single-work-package)
  - [Process Multiple Work Packages](#process-multiple-work-packages)
  - [Queue Mode (CI/Automation)](#queue-mode-ciautomation)
  - [Dry Run](#dry-run)
  - [Interactive Review](#interactive-review)
  - [Rollback](#rollback)
  - [Health Check](#health-check)
- [How the Pipeline Works](#how-the-pipeline-works)
- [Prompt Templates](#prompt-templates)
- [Hooks](#hooks)
- [Troubleshooting](#troubleshooting)
- [Environment Variable Reference](#environment-variable-reference)
- [CLI Reference](#cli-reference)

---

## How It Works

```
OpenProject Work Package
        │
        ▼
  ┌─────────────┐
  │  forgeplan   │
  │              │
  │  1. Fetch WP │──── OpenProject API
  │  2. Build    │
  │     prompt   │──── WP description, hierarchy, relations,
  │              │     comments, layer context, codebase structure
  │  3. Run      │
  │     Claude   │──── Claude Code CLI (reads CLAUDE.md, edits files)
  │     Code     │
  │  4. Git      │──── branch, commit, push
  │  5. PR       │──── GitHub / GitLab / Bitbucket
  │  6. Feedback │──── Status update + comment on WP
  └─────────────┘
```

---

## Supported Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| **Linux** (Ubuntu, Debian, Fedora, Arch, etc.) | Fully supported | Native environment |
| **macOS** (Intel + Apple Silicon) | Fully supported | Requires `brew install bash` for bash 4+ |
| **Windows via WSL** | Fully supported | WSL is Linux under the hood |
| **Windows via Docker** | Supported | Use the provided Dockerfile |
| **Windows native** | Not supported | No POSIX shell — use WSL or Docker |

### Windows Users

Forgeplan is a Bash tool and requires a POSIX shell. On Windows, you have two options:

**Option 1: WSL (recommended)**
```powershell
# Install WSL if you haven't
wsl --install

# Then inside WSL, follow the normal Linux install steps
```

**Option 2: Docker**
```powershell
docker build -t forgeplan .
docker run -it --rm -v "%cd%:/workspace" forgeplan --wp 16500
```

---

## Prerequisites

Before installing forgeplan, make sure you have:

| Tool | Version | How to Install |
|------|---------|----------------|
| **Bash** | 4.0+ | macOS: `brew install bash` (default macOS bash is 3.x) |
| **Claude Code CLI** | Latest | See install options below |
| **curl** | Any | Pre-installed on most systems |
| **jq** | 1.6+ | `brew install jq` or `apt install jq` |
| **git** | 2.30+ | Pre-installed on most systems |
| **OpenProject** | 13.0+ | Any deployment (cloud, VPS, Docker, SaaS) |

### Installing Claude Code CLI

Claude Code is the AI engine that forgeplan uses to generate code. Install it using **any** of these methods:

```bash
# npm (most common)
npm install -g @anthropic-ai/claude-code

# Homebrew
brew install claude-code

# Or download from:
# https://docs.anthropic.com/en/docs/claude-code
```

After installing, authenticate once:
```bash
claude
# Follow the login prompts — this is a one-time setup
```

Forgeplan just needs the `claude` command on your PATH. It doesn't matter which method you used to install it.

### Important for macOS Users

macOS ships with bash 3.x. Forgeplan requires bash 4+:

```bash
brew install bash
```

After installing, either:
- Run forgeplan with the full path: `/opt/homebrew/bin/bash forgeplan.sh --wp 123`
- Or add `/opt/homebrew/bin/bash` to `/etc/shells` and set it as your default shell

---

## Installation

### Option A: One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/tamzid958/forgeplan/master/install.sh | sudo bash
```

Install to home directory (no sudo needed):
```bash
curl -fsSL https://raw.githubusercontent.com/tamzid958/forgeplan/master/install.sh | bash -s -- --prefix ~/.local
```

### Option B: Clone & Install

```bash
git clone https://github.com/tamzid958/forgeplan.git
cd forgeplan
sudo ./install.sh
```

No sudo needed with `--prefix`:
```bash
./install.sh --prefix ~/.local
```

### Verify Installation

```bash
forgeplan --version
# forgeplan 0.1.0

# Or check dependencies separately:
./install.sh --check-deps
# ✅ bash 5.2.15 (/opt/homebrew/bin/bash)
# ✅ curl 8.7.1
# ✅ jq jq-1.7
# ✅ git 2.39.2
# ✅ claude (found)
```

### Uninstall

```bash
forgeplan --uninstall
```

---

## Quick Start

Here's the fastest path from zero to generating code:

### Step 1: Set up your project

```bash
cd /path/to/your-project
forgeplan --init
```

This runs an interactive setup that does everything in one go:

1. **Credentials** — prompts you for OpenProject URL, API key, git hosting, etc. → creates `.env`
2. **Layer config** — Claude Code analyzes your repo → generates `forgeplan.config.json`
3. **CLAUDE.md** — Claude Code analyzes your codebase conventions → generates `CLAUDE.md`
4. **.gitignore** — generates a project-appropriate `.gitignore` (if one doesn't exist)
5. **Status mapping** — connects to OpenProject, discovers statuses, maps pipeline events

```
--- OpenProject Connection ---

OpenProject URL (e.g., https://op.example.com): https://op.mycompany.com
OpenProject API key: opapi-xxxxxxxxxxxx
OpenProject project slug (from the URL, e.g., 'my-project'): earn-lged

--- PR Creation ---
Git host, repo, and base branch are auto-derived from git remote.
Auth uses CLI tools (gh auth login, glab auth login).

PR reviewer usernames, comma-separated [skip]: alice,bob

✅ .env created

Analyzing repository structure with Claude Code...
✅ forgeplan.config.json generated

--- OpenProject Status Mapping ---

✅ Connected to OpenProject 14.2.0 at https://your-openproject.example.com
✅ Project found: My Project

Available statuses:
   1. BLOCKED (open)
   2. TO DO (open)
   3. IN PROGRESS (open)
   4. IN REVIEW (open)
   5. DONE (closed)

Which status marks a WP as ready for code generation?
Select status number [1-5]: 2

Which status should be set when the tool starts processing?
Select status number [1-5]: 3
...

✅ Project initialized.
```

**What is a "layer"?** A layer is a part of your codebase (backend, frontend, mobile, etc.). Forgeplan uses the work package's category (or another field) to decide which layer(s) to target. Claude Code figures out your layers by looking at your actual project structure, package files, and source code.

> **Tip:** To re-run just the status mapping later (e.g., after adding new statuses in OpenProject), use `forgeplan --remap-statuses`.

### Step 2: Run the health check

```bash
forgeplan --doctor
```

This verifies everything is set up correctly. Fix any failures before proceeding.

### Step 3: Generate code!

```bash
# Preview what would happen (safe, no changes)
forgeplan --wp 16500 --dry-run

# Actually generate code
forgeplan --wp 16500
```

---

## Configuration

### .env File

The `.env` file stores **secrets only** — never committed to git. All project config lives in `forgeplan.config.json`.

| Variable | Required | Description |
|----------|----------|-------------|
| `OP_API_KEY` | Yes | OpenProject API token |
| `CLAUDE_MODEL` | No | Claude model alias or ID (default: `sonnet`) |
| `VALIDATION_CMD` | No | Command to run after generation (e.g., `npm run build`) |

OpenProject URL and project ID are in `forgeplan.config.json`. Git host, repo slug, and base branch are **auto-derived** from the git remote. Auth tokens are resolved from CLI tools (`gh auth login`, `glab auth login`).

See [.env.example](.env.example) for the complete list with descriptions.

### Project Config (`forgeplan.config.json`)

This is the **single config file** for your project. It contains layers, routing, hooks, and status mappings — everything in one place.

`forgeplan --init` generates the layers/routing section (via Claude Code) and maps the statuses section. Here's what a complete file looks like:

```json
{
  "openproject": {
    "url": "https://op.example.com",
    "projectId": "my-project"
  },
  "layers": {
    "backend": {
      "path": "src/backend",
      "techStack": "ASP.NET 8, C#, Entity Framework Core",
      "filePatterns": ["**/*.cs", "**/*.csproj"],
      "buildCmd": "dotnet build"
    },
    "frontend": {
      "path": "src/frontend",
      "techStack": "Next.js 14, TypeScript, Tailwind CSS",
      "filePatterns": ["**/*.tsx", "**/*.ts"],
      "buildCmd": "npm run build",
      "openproject": {
        "projectId": "frontend-project"
      }
    },
    "mobile": {
      "path": "src/mobile",
      "techStack": "Flutter 3, Dart",
      "filePatterns": ["**/*.dart"],
      "buildCmd": "flutter analyze"
    }
  },
  "routingField": "category",
  "routingMap": {
    "Backend": "backend",
    "Frontend": "frontend",
    "Mobile": "mobile",
    "Full-Stack": ["backend", "frontend"]
  },
  "defaultLayer": "backend",
  "reviewers": ["alice", "bob"],
  "hooks": {
    "pre_commit": "./hooks/format-code.sh",
    "post_push": "./hooks/notify-slack.sh"
  },
  "statuses": {
    "pickup_status": "TO DO",
    "in_progress_status": "IN PROGRESS",
    "success_status": "IN REVIEW",
    "partial_status": "IN PROGRESS",
    "failure_status": null,
    "_status_ids": {
      "BLOCKED": 1,
      "ON HOLD": 2,
      "TO DO": 3,
      "IN PROGRESS": 4,
      "IN REVIEW": 5,
      "IN DEPLOY": 6,
      "DONE": 7
    }
  }
}
```

#### Section breakdown

| Section | What It Does | Set By |
|---------|-------------|--------|
| **`openproject`** | OpenProject URL and project ID (per-layer override supported) | `--init` |
| **`layers`** | Maps parts of your codebase — directory, tech stack, file patterns, build command | `--init` (auto-generated by Claude Code) |
| **`routingField`** | Which WP field determines the target layer (`"category"`, `"type"`, or a custom field) | `--init` |
| **`routingMap`** | Maps routing field values to layer names (string for one layer, array for multiple) | `--init` |
| **`defaultLayer`** | Fallback layer when the WP's routing field doesn't match any entry | `--init` |
| **`hooks`** | Custom scripts that run at pipeline stages (see [Hooks](#hooks)) | Manual edit |
| **`statuses`** | OpenProject status mappings + cached status IDs | `--init` or `--init` |

#### Status mappings (`statuses` section)

Run `forgeplan --remap-statuses` to populate this section. It connects to OpenProject, discovers all available statuses, and asks you to map each pipeline event:

| Key | What It Means |
|-----|---------------|
| **`pickup_status`** | "This WP is ready for code generation" (used by `--queue` to find work) |
| **`in_progress_status`** | "Forgeplan is currently working on this" |
| **`success_status`** | "Code generated and validation passed" |
| **`partial_status`** | "Code generated but validation failed" |
| **`failure_status`** | "Generation produced no output" (`null` = don't change status) |
| **`_status_ids`** | Cached mapping of every status name to its numeric ID in OpenProject |

---

## Usage

### Process a Single Work Package

```bash
forgeplan --wp 16500
```

What happens:
1. Fetches WP #16500 from OpenProject (description, hierarchy, relations, comments)
2. Sets status to "IN PROGRESS"
3. Creates branch `feature/WP-16500-fix-clone-validation-bug`
4. Builds a rich prompt with all context
5. Invokes Claude Code to generate/edit files
6. Runs your validation command (if configured)
7. Commits, pushes, creates PR
8. Updates WP status and posts a summary comment

### Process Multiple Work Packages

```bash
forgeplan --batch 16500,16501,16502
```

Processes each WP sequentially. Prints a summary at the end:
```
Batch complete: 2 success, 1 partial, 0 failed out of 3
```

### Queue Mode (CI/Automation)

```bash
forgeplan --queue
```

Automatically discovers all WPs with your `pickup_status` (e.g., "TO DO"), sorted by priority, and processes them one by one. Perfect for CI pipelines or cron jobs.

### Dry Run

```bash
forgeplan --wp 16500 --dry-run
```

Shows exactly what forgeplan **would** do without making any changes:
- Fetches the WP (read-only)
- Builds the prompt (you can inspect it)
- Prints `[DRY RUN] Would create branch: ...`
- Prints `[DRY RUN] Would invoke: claude ...`
- No git changes, no status updates, no API calls

**Always do a dry run first** when trying forgeplan on a new project.

### Interactive Review

```bash
forgeplan --wp 16500 --review
```

After Claude generates code, forgeplan pauses and shows you the diff:

```
=== Generated Changes ===
 3 files changed, 142 insertions(+)
 src/backend/Controllers/UserController.cs | 45 +++
 src/backend/Services/UserService.cs        | 62 +++
 src/backend/Program.cs                     | 35 +++

Review complete. Choose an action:
  [a] Accept — commit and continue pipeline
  [e] Edit   — open $EDITOR to make changes, then re-review
  [r] Reject — discard all changes, skip this WP
  [s] Shell  — drop to a shell, return to this prompt when done
Choice [a/e/r/s]:
```

### Rollback

Made a mistake? Undo everything with one command:

```bash
forgeplan --rollback 16500
```

This will:
- Close the PR on GitHub/GitLab/Bitbucket
- Delete the remote and local branch
- Revert the WP status in OpenProject
- Post a rollback comment on the WP

### Health Check

```bash
forgeplan --doctor
```

Runs 15+ diagnostic checks:
```
forgeplan doctor — checking setup...

Dependencies:
  ✅ bash 5.2.15
  ✅ curl 7.88.1
  ✅ jq jq-1.7
  ✅ git 2.39.2
  ✅ claude (found)

Configuration:
  ✅ .env loaded from ./.env
  ✅ Required vars: OP_BASE_URL, OP_API_KEY, OP_PROJECT_ID, REPO_ROOT
  ✅ forgeplan.config.json: 2 layers (backend, frontend)
  ✅ Status mappings: 4 configured in forgeplan.config.json

OpenProject:
  ✅ Connected to https://op.example.com
  ✅ Authenticated (HTTP 200)
  ✅ Project 'my-project' accessible

Repository:
  ✅ REPO_ROOT: /home/dev/repo (.git found)
  ✅ CLAUDE.md found
  ✅ Remote 'origin' → git@github.com:org/repo.git
  ✅ .env in .gitignore

Result: 15/15 checks passed, 0 warning(s), 0 failure(s)
```

---

## How the Pipeline Works

When you run `forgeplan --wp <ID>`, this is the full pipeline:

```
1.  Acquire lock (prevents duplicate processing)
2.  Fetch WP from OpenProject API
3.  Quality gate (reject empty/placeholder descriptions)
4.  Set WP status → IN PROGRESS
5.  Git preflight (clean tree, remote exists)
6.  Create branch: feature/WP-<ID>-<slug>
7.  Build prompt (template + WP data + codebase context)
8.  Invoke Claude Code CLI (with retry on rate limits)
9.  [Optional] Interactive review
10. Commit changes
11. Push branch
12. Create PR (GitHub/GitLab/Bitbucket)
13. Update WP status (SUCCESS → IN REVIEW, PARTIAL → IN PROGRESS)
14. Post summary comment on WP
15. Release lock, write log summary
```

### Result Types

| Result | What Happened | Git | WP Status |
|--------|--------------|-----|-----------|
| **SUCCESS** | Code generated, validation passed | Commit + push + PR | `success_status` |
| **PARTIAL** | Code generated, validation failed | `[WIP]` commit + push + PR | `partial_status` |
| **FAILURE** | No code generated, or error | No commit | `failure_status` (or unchanged) |

### Crash Recovery

If forgeplan crashes mid-run (network issue, terminal closed, etc.), just run the same command again:

```bash
forgeplan --wp 16500
# Resuming WP #16500 from stage 'generate'
```

It detects the previous state file and picks up where it left off. To force a fresh start:

```bash
forgeplan --wp 16500 --force
```

---

## Prompt Templates

Forgeplan selects a prompt template based on the WP type:

| WP Type | Template | Generation Focus |
|---------|----------|-----------------|
| **Task** | `prompt.template.task.md` | Complete implementation |
| **Bug** | `prompt.template.bug.md` | Root cause fix + regression test |
| **Feature** | `prompt.template.feature.md` | Full feature with patterns |
| **Epic** | `prompt.template.epic.md` | Scaffolding only, no child implementations |
| **User Story** | `prompt.template.story.md` | User-facing behavior |
| **Subtask** | `prompt.template.subtask.md` | Scoped to subtask only |
| Other | `prompt.template.md` | Default rules |

### Customizing Templates

Drop a custom template in your project root to override the default:

```bash
# Override just the bug template for this project
cp /usr/local/share/forgeplan/prompt.template.bug.md ./prompt.template.bug.md
# Edit to your needs
vim prompt.template.bug.md
```

Forgeplan checks the project directory first, then falls back to the global install.

### CLAUDE.md

`CLAUDE.md` is the file Claude Code reads before every task to understand your project's conventions. **This is the most important file for generation quality.**

`forgeplan --init` automatically generates it by having Claude Code analyze your codebase — it detects your tech stack, naming patterns, architecture, build commands, and testing conventions from the actual code.

```
Generating CLAUDE.md by analyzing your codebase with Claude Code...
(This may take 30-60 seconds)

✅ CLAUDE.md generated (45 lines)
```

If Claude Code isn't installed, it creates a minimal template you can edit.

**Tip:** Review and refine the generated `CLAUDE.md` — the more specific it is, the better the generated code will be. Add things like:
- Specific naming conventions (`UserService`, not `user_service`)
- Architecture patterns (repository pattern, clean architecture, etc.)
- Error handling standards
- What NOT to do

---

## Hooks

Hooks let you run custom scripts at specific pipeline stages. Configure them in `forgeplan.config.json`:

```json
{
  "hooks": {
    "pre_generate": "./hooks/cost-check.sh",
    "post_generate": "./hooks/security-scan.sh",
    "pre_commit": "./hooks/format-code.sh",
    "post_push": "./hooks/notify-slack.sh",
    "post_complete": "./hooks/update-dashboard.sh"
  }
}
```

| Hook | When | Can Block? |
|------|------|-----------|
| `pre_fetch` | Before fetching WP from API | Yes |
| `post_fetch` | After WP data is fetched | No |
| `pre_generate` | Before invoking Claude Code | Yes |
| `post_generate` | After Claude Code completes | No |
| `pre_commit` | Before git commit | Yes |
| `post_commit` | After commit is created | No |
| `post_push` | After branch is pushed | No |
| `post_complete` | After full pipeline completes | No |

**Blocking hooks** (`pre_*`): If the script exits with a non-zero code, the pipeline stops and a comment is posted on the WP explaining why.

**Non-blocking hooks** (`post_*`): Failures are logged as warnings but don't stop the pipeline.

All hooks have a 60-second timeout.

---

## Troubleshooting

### "forgeplan requires bash >= 4.0"

macOS ships with bash 3.x. Install a modern bash:
```bash
brew install bash
```

### "ERROR: .env not found"

Run `forgeplan --init` in your project directory to scaffold config files.

### "ERROR: Status mapping not found in forgeplan.config.json"

Your `forgeplan.config.json` is missing the `statuses` section. Run `forgeplan --remap-statuses` to add it:

```bash
forgeplan --remap-statuses
```

This connects to OpenProject, shows you all available statuses, and adds a `"statuses": { ... }` section to your existing `forgeplan.config.json`. See the [full JSON example](#project-config-forgeplanconfigjson) above.

### "ERROR: Authentication failed"

Your `OP_API_KEY` is invalid or expired. Generate a new one in OpenProject → My Account → Access Tokens.

### "Claude Code CLI not found"

The `claude` command isn't on your PATH. Install it using any method:
```bash
npm install -g @anthropic-ai/claude-code
# or
brew install claude-code
```

Then authenticate: `claude` (follow the login prompts once).

If you installed `claude` in bash but use **zsh** as your default shell, add the npm/brew bin to your zsh PATH:

```bash
# Find where claude is installed
bash -lc "which claude"
# e.g. /opt/homebrew/bin/claude or ~/.npm-global/bin/claude

# Add that directory to your ~/.zshrc
echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### "Working tree has uncommitted changes"

Forgeplan requires a clean git working tree. Commit or stash your changes first:
```bash
git stash
forgeplan --wp 16500
git stash pop
```

### "WP description is too short"

Forgeplan rejects work packages with empty or placeholder descriptions. Add at least 50 characters of requirements to the WP, then re-run. Or bypass with `--skip-quality-gate`.

### Claude generates wrong code

Improve your `CLAUDE.md` file with more specific conventions and patterns. Use `--review` to inspect generated code before committing. Use `--rollback` to undo a bad generation.

### Checking logs

All runs are logged to `./logs/`:
```bash
# View the latest run log
ls -t logs/wp-*.log | head -1 | xargs cat

# View run history
cat logs/run-summary.jsonl | jq .
```

---

## Environment Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OP_API_KEY` | Yes | — | OpenProject API token |
| `CLAUDE_MODEL` | No | `claude-sonnet-4-20250514` | Claude model identifier |
| `GENERATION_TIMEOUT` | No | `600` | Max seconds for Claude Code |
| `VALIDATION_CMD` | No | — | Post-generation validation command |
| `VALIDATION_TIMEOUT` | No | `120` | Max seconds for validation |
| `PROMPT_MAX_TOKENS` | No | `30000` | Max tokens for assembled prompt |
| `CLAUDE_MAX_RETRIES` | No | `3` | Retry attempts on API errors |
| `CLAUDE_RETRY_DELAY` | No | `10` | Initial retry delay (seconds, doubles each retry) |
| `LOG_DIR` | No | `./logs` | Log directory |
| `DRY_RUN` | No | `false` | Print actions without executing |

---

## CLI Reference

### Commands

| Command | Description |
|---------|-------------|
| `forgeplan --init` | Full project setup: credentials, config, statuses — all in one |
| `forgeplan --remap-statuses` | Re-run just the OpenProject status mapping |
| `forgeplan --doctor` | Run diagnostic health check |
| `forgeplan --wp <ID>` | Process a single work package |
| `forgeplan --batch <ID,ID,ID>` | Process multiple WPs sequentially |
| `forgeplan --queue` | Auto-discover and process all ready WPs |
| `forgeplan --rollback <ID>` | Undo: close PR, delete branch, revert status |
| `forgeplan --update` | Update forgeplan to the latest version |
| `forgeplan --uninstall` | Remove forgeplan from your system |
| `forgeplan --help` | Print help |
| `forgeplan --version` | Print version |

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview all actions without executing |
| `--review` | Interactive diff review before committing |
| `--skip-pr` | Skip PR creation (branch and push only) |
| `--skip-push` | Skip push and PR (local branch and commit only) |
| `--skip-feedback` | Skip OpenProject status/comment updates |
| `--skip-validation` | Skip running `VALIDATION_CMD` |
| `--skip-quality-gate` | Skip WP description quality checks |
| `--force` | Override stale state/lock files |
| `--layer <name>` | Override automatic layer routing |
| `--config <path>` | Custom path to `forgeplan.config.json` |
| `--env <path>` | Custom path to `.env` file |
| `--verbose` | Enable debug logging |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Partial success (code generated, validation failed) |
| 2 | Generation failure (no output, quality gate rejection, or timeout) |
| 3 | Configuration error |
| 4 | Git/lock error |
| 5 | OpenProject API error |

---

## License

MIT
