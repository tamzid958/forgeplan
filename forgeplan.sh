#!/usr/bin/env bash
# forgeplan — Forge Code from Plans
# OpenProject Work Package → Claude Code Generation Pipeline
set -euo pipefail

FP_INSTALL_DIR=__INSTALL_DIR__

# ---------------------------------------------------------------------------
# Resolve install dir for dev/uninstalled usage
# ---------------------------------------------------------------------------
if [[ "$FP_INSTALL_DIR" == "__INSTALL_DIR__" ]]; then
  FP_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
readonly FP_VERSION_FILE="$FP_INSTALL_DIR/VERSION"

show_version() {
  if [[ -f "$FP_VERSION_FILE" ]]; then
    echo "forgeplan $(cat "$FP_VERSION_FILE")"
  else
    echo "forgeplan (version unknown)"
  fi
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
  cat <<'USAGE'
forgeplan — Forge Code from Plans

Usage:
  forgeplan --init                    Interactive setup: discover statuses, map pipeline events
  forgeplan --init-project            Scaffold per-project config files from global templates
  forgeplan --doctor                  Run full health check diagnostic
  forgeplan --wp <ID>                 Process a single work package
  forgeplan --batch <ID1,ID2,ID3>    Process multiple work packages sequentially
  forgeplan --queue                   Auto-discover and process all ready WPs
  forgeplan --rollback <ID>           Undo a previous generation: close PR, delete branch, revert status

Options:
  --dry-run                Print all actions without executing
  --review                 Interactive diff review before committing
  --skip-pr                Skip PR creation
  --skip-push              Skip push and PR
  --skip-feedback          Skip OpenProject status/comment update
  --skip-validation        Skip running VALIDATION_CMD
  --skip-quality-gate      Skip WP description quality checks
  --force                  Override stale state/lock files
  --layer <name>           Override automatic layer routing
  --config <path>          Path to forgeplan.config.json
  --env <path>             Path to .env file
  --verbose                Enable debug logging
  --help                   Print this help message
  --version                Print version

Exit Codes:
  0  Success
  1  Partial success (code generated, validation failed)
  2  Generation failure (no output, quality gate rejection, or timeout)
  3  Configuration error
  4  Git/lock error
  5  OpenProject API error
USAGE
}

# ---------------------------------------------------------------------------
# --init-project handler
# ---------------------------------------------------------------------------
handle_init_project() {
  echo "forgeplan — Project Setup"
  echo "========================="
  echo ""

  # --- Step 1: Interactive .env setup ---
  if [[ -f ".env" ]]; then
    printf ".env already exists. Overwrite? [y/N] "
    local answer; read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      echo "Keeping existing .env."
    else
      _init_env_interactive
    fi
  else
    _init_env_interactive
  fi

  # --- Step 2: Generate forgeplan.config.json via Claude Code ---
  if [[ -f "forgeplan.config.json" ]]; then
    printf "forgeplan.config.json already exists. Regenerate? [y/N] "
    local answer; read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      echo "Keeping existing forgeplan.config.json."
    else
      _init_config_generate
    fi
  else
    _init_config_generate
  fi

  # --- Step 3: Generate CLAUDE.md if missing ---
  if [[ -f "CLAUDE.md" ]]; then
    echo "CLAUDE.md already exists, skipping."
  else
    _init_claude_md_generate
  fi

  # --- Step 4: Generate or update .gitignore ---
  if [[ -f ".gitignore" ]]; then
    echo ".gitignore already exists, ensuring forgeplan entries..."
    grep -qxF '.env' .gitignore 2>/dev/null || echo '.env' >> .gitignore
    grep -qxF 'logs/' .gitignore 2>/dev/null || echo 'logs/' >> .gitignore
    echo "✅ .gitignore updated"
  else
    _init_gitignore_generate
  fi

  echo ""
  echo "✅ Project initialized. Next step:"
  echo "   Run: forgeplan --init"
}

# ---------------------------------------------------------------------------
# Interactive .env builder
# ---------------------------------------------------------------------------
_init_env_interactive() {
  echo ""
  echo "--- OpenProject Connection ---"
  echo ""

  local op_base_url op_api_key op_project_id repo_root
  local git_host_type git_host_token git_host_repo reviewers
  local git_base_branch validation_cmd claude_model

  # Required fields
  printf "OpenProject URL (e.g., https://op.example.com): "
  read -r op_base_url
  if [[ -z "$op_base_url" ]]; then
    echo "ERROR: OpenProject URL is required." >&2
    exit 3
  fi
  # Strip trailing slash
  op_base_url="${op_base_url%/}"

  echo ""
  echo "You need an API token from OpenProject."
  echo "  → Log in → Avatar (top right) → My account → Access tokens → Generate → API"
  echo ""
  printf "OpenProject API key: "
  read -r op_api_key
  if [[ -z "$op_api_key" ]]; then
    echo "ERROR: API key is required." >&2
    exit 3
  fi

  printf "OpenProject project slug (from the URL, e.g., 'my-project'): "
  read -r op_project_id
  if [[ -z "$op_project_id" ]]; then
    echo "ERROR: Project ID is required." >&2
    exit 3
  fi

  # Default REPO_ROOT to current directory
  local default_root
  default_root=$(pwd)
  printf "Repository root path [${default_root}]: "
  read -r repo_root
  repo_root="${repo_root:-$default_root}"
  # Resolve to absolute path
  repo_root=$(cd "$repo_root" 2>/dev/null && pwd || echo "$repo_root")

  # Git hosting (optional)
  echo ""
  echo "--- Git Hosting (for automatic PR creation) ---"
  echo ""
  printf "Git hosting platform (github/gitlab/bitbucket) [skip]: "
  read -r git_host_type

  if [[ -n "$git_host_type" && "$git_host_type" != "skip" ]]; then
    printf "Personal access token for ${git_host_type}: "
    read -r git_host_token
    printf "Repository slug (e.g., org/repo-name): "
    read -r git_host_repo
    printf "PR reviewer usernames, comma-separated [skip]: "
    read -r reviewers
    [[ "$reviewers" == "skip" ]] && reviewers=""
  else
    git_host_type=""
  fi

  # Optional settings
  echo ""
  echo "--- Optional Settings (press Enter for defaults) ---"
  echo ""
  printf "Base branch for new feature branches [develop]: "
  read -r git_base_branch
  git_base_branch="${git_base_branch:-develop}"

  printf "Claude model [claude-sonnet-4-20250514]: "
  read -r claude_model
  claude_model="${claude_model:-claude-sonnet-4-20250514}"

  printf "Validation command after generation (e.g., 'npm run build') [none]: "
  read -r validation_cmd
  [[ "$validation_cmd" == "none" ]] && validation_cmd=""

  # Write .env
  cat > .env <<ENVFILE
# forgeplan — Environment Configuration (generated by --init-project)

# --- Required ---
OP_BASE_URL="${op_base_url}"
OP_API_KEY="${op_api_key}"
OP_PROJECT_ID="${op_project_id}"
REPO_ROOT="${repo_root}"

# --- Git ---
GIT_BASE_BRANCH="${git_base_branch}"
ENVFILE

  if [[ -n "$git_host_type" ]]; then
    cat >> .env <<ENVFILE

# --- Git Hosting (PR creation) ---
GIT_HOST_TYPE="${git_host_type}"
GIT_HOST_TOKEN="${git_host_token}"
GIT_HOST_REPO="${git_host_repo}"
ENVFILE
    [[ -n "$reviewers" ]] && echo "REVIEWERS=\"${reviewers}\"" >> .env
  fi

  cat >> .env <<ENVFILE

# --- Claude Code ---
CLAUDE_MODEL="${claude_model}"
ENVFILE

  if [[ -n "$validation_cmd" ]]; then
    echo "VALIDATION_CMD=\"${validation_cmd}\"" >> .env
  fi

  echo ""
  echo "✅ .env created"
}

# ---------------------------------------------------------------------------
# Generate forgeplan.config.json via Claude Code
# ---------------------------------------------------------------------------
_init_config_generate() {
  echo ""

  # Check if Claude Code is available
  if ! command -v claude > /dev/null 2>&1; then
    echo "Claude Code CLI not found. Falling back to example template."
    local src_dir="$FP_INSTALL_DIR"
    if [[ -f "$src_dir/forgeplan.config.json.example" ]]; then
      cp "$src_dir/forgeplan.config.json.example" "forgeplan.config.json"
      echo "Created forgeplan.config.json from template. Edit it manually."
    else
      echo "ERROR: forgeplan.config.json.example not found in $src_dir" >&2
      exit 3
    fi
    return 0
  fi

  echo "Analyzing repository structure with Claude Code..."
  echo "(This may take 30-60 seconds)"
  echo ""

  # Write analysis prompt to temp file (avoids heredoc issues in bash 3.x)
  local tmp_prompt tmp_output
  tmp_prompt=$(mktemp)
  tmp_output=$(mktemp)

  cat > "$tmp_prompt" <<'PROMPT'
Analyze this repository and generate a forgeplan.config.json file. This file tells forgeplan how to route OpenProject work packages to the correct part of the codebase.

Output ONLY valid JSON (no markdown fences, no explanation) with this exact structure:
{
  "layers": {
    "<layer-name>": {
      "path": "<relative-dir-from-repo-root>",
      "techStack": "<frameworks, languages, key libraries>",
      "filePatterns": ["<glob-patterns-for-relevant-files>"],
      "buildCmd": "<build-or-lint-command>"
    }
  },
  "routingField": "category",
  "routingMap": {
    "<OP-category-value>": "<layer-name>",
    "<OP-category-value>": ["<layer1>", "<layer2>"]
  },
  "defaultLayer": "<most-common-layer>",
  "hooks": {}
}

Rules:
- Look at the directory structure, package files, and source code to identify distinct layers
- Each layer should map to a real directory in the repo
- techStack should list the actual frameworks/languages found
- filePatterns should match the source files in that layer
- buildCmd should be the actual build command found in package.json, Makefile, etc.
- routingMap keys should be reasonable OpenProject category names
- If it is a monorepo, create multiple layers. If single app, one layer is fine.
- Output raw JSON only. No markdown. No explanation.
PROMPT

  # Run Claude Code to analyze the repo
  local config_output
  if claude --print --output-format text --max-turns 10 \
    --prompt-file "$tmp_prompt" > "$tmp_output" 2>/dev/null; then

    # Extract JSON from output (strip any non-JSON wrapping)
    config_output=$(cat "$tmp_output" | sed -n '/^{/,/^}/p' | head -100)

    # Validate JSON
    if echo "$config_output" | jq empty 2>/dev/null; then
      echo "$config_output" | jq '.' > forgeplan.config.json
      echo "✅ forgeplan.config.json generated"
      echo ""
      echo "Detected layers:"
      jq -r '.layers | to_entries[] | "  - \(.key): \(.value.path) (\(.value.techStack))"' forgeplan.config.json
    else
      echo "Claude output wasn't valid JSON. Falling back to template."
      _init_config_fallback
    fi
  else
    echo "Claude Code analysis failed. Falling back to template."
    _init_config_fallback
  fi

  rm -f "$tmp_prompt" "$tmp_output"
}

_init_config_fallback() {
  local src_dir="$FP_INSTALL_DIR"
  if [[ -f "$src_dir/forgeplan.config.json.example" ]]; then
    cp "$src_dir/forgeplan.config.json.example" "forgeplan.config.json"
    echo "Created forgeplan.config.json from template. Edit it to match your project."
  fi
}

# ---------------------------------------------------------------------------
# Generate CLAUDE.md via Claude Code
# ---------------------------------------------------------------------------
_init_claude_md_generate() {
  echo ""

  if ! command -v claude > /dev/null 2>&1; then
    echo "Claude Code CLI not found. Creating minimal CLAUDE.md."
    _init_claude_md_fallback
    return 0
  fi

  echo "Generating CLAUDE.md by analyzing your codebase with Claude Code..."
  echo "(This may take 30-60 seconds)"
  echo ""

  local tmp_prompt tmp_output
  tmp_prompt=$(mktemp)
  tmp_output=$(mktemp)

  cat > "$tmp_prompt" <<'PROMPT'
Analyze this repository and generate a CLAUDE.md file. This file is read by Claude Code before every task to understand the project's conventions.

The CLAUDE.md should contain:
1. **Project overview** — one paragraph about what this project does and its architecture
2. **Tech stack** — languages, frameworks, key dependencies
3. **Code conventions** — naming patterns, file organization, module structure you observe
4. **Build & run** — how to build, test, lint, and run the project (from package.json, Makefile, etc.)
5. **Architecture patterns** — patterns used (repository pattern, MVC, clean architecture, etc.)
6. **Testing conventions** — test framework, naming patterns, where tests live
7. **Important rules** — anything a code generator must follow to produce consistent code

Look at the actual codebase: package.json, config files, source code structure, existing tests, README. Write conventions based on what you observe, not generic best practices.

Output ONLY the Markdown content for CLAUDE.md. No fences wrapping the whole output. Start directly with a heading.
PROMPT

  if claude --print --output-format text --max-turns 15 \
    --prompt-file "$tmp_prompt" > "$tmp_output" 2>/dev/null; then

    local content
    content=$(cat "$tmp_output")

    if [[ -n "$content" && ${#content} -gt 50 ]]; then
      printf '%s\n' "$content" > CLAUDE.md
      echo "✅ CLAUDE.md generated ($(wc -l < CLAUDE.md | tr -d ' ') lines)"
    else
      echo "Claude output was too short. Creating minimal CLAUDE.md."
      _init_claude_md_fallback
    fi
  else
    echo "Claude Code analysis failed. Creating minimal CLAUDE.md."
    _init_claude_md_fallback
  fi

  rm -f "$tmp_prompt" "$tmp_output"
}

_init_claude_md_fallback() {
  cat > CLAUDE.md <<'FALLBACK'
# Project Conventions

<!-- Generated by forgeplan --init-project -->
<!-- Edit this file with your project's actual conventions -->
<!-- Claude Code reads this before every task -->

## Build & Run

```bash
# TODO: Add your build commands
```

## Code Conventions

- Follow existing patterns in the codebase
- Match naming conventions you observe in existing files
- Keep files focused — one responsibility per file

## Testing

- Write tests alongside implementation
- Follow existing test patterns in the codebase
FALLBACK
  echo "✅ CLAUDE.md created (minimal template — edit it with your conventions)"
}

# ---------------------------------------------------------------------------
# Generate .gitignore via Claude Code or fallback
# ---------------------------------------------------------------------------
_init_gitignore_generate() {
  echo ""

  if ! command -v claude > /dev/null 2>&1; then
    echo "Claude Code CLI not found. Creating standard .gitignore."
    _init_gitignore_fallback
    return 0
  fi

  echo "Generating .gitignore by analyzing your project with Claude Code..."

  local tmp_prompt tmp_output
  tmp_prompt=$(mktemp)
  tmp_output=$(mktemp)

  cat > "$tmp_prompt" <<'PROMPT'
Analyze this repository and generate a .gitignore file appropriate for the project.

Look at the actual tech stack: package.json, requirements.txt, *.csproj, Cargo.toml, go.mod, etc. to determine which language/framework-specific patterns to include.

Always include these forgeplan-specific entries:
.env
logs/

Output ONLY the .gitignore content. No markdown fences. No explanation. One pattern per line with section comments.
PROMPT

  if claude --print --output-format text --max-turns 5 \
    --prompt-file "$tmp_prompt" > "$tmp_output" 2>/dev/null; then

    local content
    content=$(cat "$tmp_output")

    if [[ -n "$content" && ${#content} -gt 20 ]]; then
      # Ensure forgeplan entries are present
      printf '%s\n' "$content" > .gitignore
      grep -qxF '.env' .gitignore 2>/dev/null || echo '.env' >> .gitignore
      grep -qxF 'logs/' .gitignore 2>/dev/null || echo 'logs/' >> .gitignore
      echo "✅ .gitignore generated ($(wc -l < .gitignore | tr -d ' ') entries)"
    else
      _init_gitignore_fallback
    fi
  else
    _init_gitignore_fallback
  fi

  rm -f "$tmp_prompt" "$tmp_output"
}

_init_gitignore_fallback() {
  cat > .gitignore <<'GITIGNORE'
# forgeplan
.env
logs/

# Dependencies
node_modules/
vendor/
.venv/

# Build output
dist/
build/
bin/
obj/

# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db
GITIGNORE
  echo "✅ .gitignore created"
}

# ---------------------------------------------------------------------------
# Argument parsing (already complete from Phase 0)
# ---------------------------------------------------------------------------
parse_args() {
  COMMAND=""
  COMMAND_ARG=""

  FLAG_DRY_RUN=false
  FLAG_SKIP_PR=false
  FLAG_SKIP_PUSH=false
  FLAG_SKIP_FEEDBACK=false
  FLAG_SKIP_VALIDATION=false
  FLAG_SKIP_QUALITY_GATE=false
  FLAG_VERBOSE=false
  FLAG_REVIEW=false
  FLAG_FORCE=false

  FLAG_LAYER=""
  FLAG_CONFIG_PATH=""
  FLAG_ENV_PATH=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --init)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --init with --$COMMAND" >&2; exit 3; }
        COMMAND="init"; shift ;;
      --init-project)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --init-project with --$COMMAND" >&2; exit 3; }
        COMMAND="init_project"; shift ;;
      --doctor)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --doctor with --$COMMAND" >&2; exit 3; }
        COMMAND="doctor"; shift ;;
      --wp)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --wp with --$COMMAND" >&2; exit 3; }
        COMMAND="single"; COMMAND_ARG="${2:?ERROR: --wp requires a work package ID}"; shift 2 ;;
      --batch)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --batch with --$COMMAND" >&2; exit 3; }
        COMMAND="batch"; COMMAND_ARG="${2:?ERROR: --batch requires comma-separated WP IDs}"; shift 2 ;;
      --queue)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --queue with --$COMMAND" >&2; exit 3; }
        COMMAND="queue"; shift ;;
      --rollback)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --rollback with --$COMMAND" >&2; exit 3; }
        COMMAND="rollback"; COMMAND_ARG="${2:?ERROR: --rollback requires a work package ID}"; shift 2 ;;
      --dry-run)       FLAG_DRY_RUN=true; shift ;;
      --skip-pr)       FLAG_SKIP_PR=true; shift ;;
      --skip-push)     FLAG_SKIP_PUSH=true; shift ;;
      --skip-feedback) FLAG_SKIP_FEEDBACK=true; shift ;;
      --skip-validation)    FLAG_SKIP_VALIDATION=true; shift ;;
      --skip-quality-gate)  FLAG_SKIP_QUALITY_GATE=true; shift ;;
      --verbose)       FLAG_VERBOSE=true; shift ;;
      --review)        FLAG_REVIEW=true; shift ;;
      --force)         FLAG_FORCE=true; shift ;;
      --layer)  FLAG_LAYER="${2:?ERROR: --layer requires a layer name}"; shift 2 ;;
      --config) FLAG_CONFIG_PATH="${2:?ERROR: --config requires a file path}"; shift 2 ;;
      --env)    FLAG_ENV_PATH="${2:?ERROR: --env requires a file path}"; shift 2 ;;
      --help)    show_help; exit 0 ;;
      --version) show_version; exit 0 ;;
      *)
        echo "ERROR: Unknown argument: $1" >&2
        echo "Run 'forgeplan --help' for usage." >&2
        exit 3 ;;
    esac
  done

  if [[ -z "$COMMAND" ]]; then
    show_help; exit 3
  fi
}

# ===========================================================================
# WP Quality Gate (I-3)
# ===========================================================================

# ---------------------------------------------------------------------------
# op_validate_wp_quality <wp_json>
# Validate WP has enough info for code generation.
# Returns 0 (ok/warn) or 1 (hard fail).
# Sets WP_QUALITY_NOTE if a soft warning was generated.
# ---------------------------------------------------------------------------
WP_QUALITY_NOTE=""

op_validate_wp_quality() {
  local wp_json="$1"
  local wp_id
  wp_id=$(echo "$wp_json" | jq -r '.id')

  local description
  description=$(echo "$wp_json" | jq -r '.description.raw // ""')
  # Strip whitespace for checks
  local trimmed
  trimmed=$(printf '%s' "$description" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  WP_QUALITY_NOTE=""

  # Empty description — hard fail
  if [[ -z "$trimmed" ]]; then
    local msg="WP #${wp_id} has no description. Add requirements before generating code."
    log_error "$msg"
    if [[ "${FLAG_DRY_RUN}" != "true" && "${FLAG_SKIP_FEEDBACK}" != "true" ]]; then
      op_post_comment "$wp_id" "❌ forgeplan skipped: ${msg}" || true
    fi
    return 1
  fi

  # Boilerplate — hard fail
  local lower_desc
  lower_desc=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')
  if echo "$lower_desc" | grep -qxE 'tbd|todo|na|placeholder|n/a|to be defined|see above|same as parent'; then
    local msg="WP #${wp_id} description appears to be a placeholder."
    log_error "$msg"
    if [[ "${FLAG_DRY_RUN}" != "true" && "${FLAG_SKIP_FEEDBACK}" != "true" ]]; then
      op_post_comment "$wp_id" "forgeplan skipped: ${msg}" || true
    fi
    return 1
  fi

  # Too short — soft warning
  local char_count=${#trimmed}
  if [[ $char_count -lt 50 ]]; then
    log_warn "WP #${wp_id} description is too short (${char_count} chars). Minimum 50 chars recommended."
    WP_QUALITY_NOTE="Note: The work package description is brief. Use the hierarchy and discussion context to fill in gaps."
  fi

  return 0
}

# ===========================================================================
# State management — Crash recovery (I-1)
# ===========================================================================

state_load() {
  local wp_id="$1"
  local state_file="${LOG_DIR}/wp-${wp_id}.state.json"

  if [[ ! -f "$state_file" ]]; then
    return 0
  fi

  # Check lock_pid
  local lock_pid
  lock_pid=$(jq -r '.lock_pid // empty' "$state_file")
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    log_error "WP #${wp_id} is being processed by PID ${lock_pid}. Use --force to override."
    exit 4
  fi

  log_info "Resuming WP #${wp_id} from last checkpoint"
}

state_save() {
  local wp_id="$1"
  local stage="$2"
  local status="$3"

  local state_file="${LOG_DIR}/wp-${wp_id}.state.json"
  local tmp_file="${state_file}.tmp"
  local iso_ts
  iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ -f "$state_file" ]]; then
    jq --arg stage "$stage" --arg status "$status" --arg ts "$iso_ts" \
      '.stages[$stage] = {status: $status, completed_at: $ts}' "$state_file" > "$tmp_file"
  else
    jq -n --argjson wp_id "$wp_id" --arg stage "$stage" --arg status "$status" \
      --arg ts "$iso_ts" --argjson pid "$$" \
      '{wp_id: $wp_id, started_at: $ts, lock_pid: $pid, stages: {($stage): {status: $status, completed_at: $ts}}}' > "$tmp_file"
  fi

  mv "$tmp_file" "$state_file"
}

state_clear() {
  local wp_id="$1"
  rm -f "${LOG_DIR}/wp-${wp_id}.state.json"
}

state_get_resume_stage() {
  local wp_id="$1"
  local state_file="${LOG_DIR}/wp-${wp_id}.state.json"
  local stages=("fetch" "branch" "prompt" "generate" "commit" "push" "pr" "feedback")

  if [[ ! -f "$state_file" ]]; then
    echo "fetch"
    return 0
  fi

  for stage in "${stages[@]}"; do
    local s
    s=$(jq -r --arg st "$stage" '.stages[$st].status // "pending"' "$state_file")
    if [[ "$s" != "done" ]]; then
      echo "$stage"
      return 0
    fi
  done

  echo "complete"
}

# ===========================================================================
# Concurrent execution lock (I-2)
# ===========================================================================

lock_acquire() {
  local wp_id="$1"
  local lock_file="${LOG_DIR}/.lock-wp-${wp_id}"

  mkdir -p "${LOG_DIR}"

  if [[ -f "$lock_file" ]]; then
    local lock_pid lock_host
    lock_pid=$(head -1 "$lock_file" 2>/dev/null || echo "")
    lock_host=$(tail -1 "$lock_file" 2>/dev/null || echo "")
    local my_host
    my_host=$(hostname)

    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      if [[ "$lock_host" == "$my_host" ]]; then
        log_error "WP #${wp_id} is locked by PID ${lock_pid} on this machine."
        exit 4
      else
        log_error "WP #${wp_id} is locked by ${lock_host}. If stale, delete ${lock_file}"
        exit 4
      fi
    else
      log_warn "Stale lock from dead PID ${lock_pid}. Overriding."
    fi
  fi

  echo "$$" > "$lock_file"
  hostname >> "$lock_file"
}

lock_release() {
  local wp_id="$1"
  rm -f "${LOG_DIR}/.lock-wp-${wp_id}"
}

# ===========================================================================
# Hook system (I-8)
# ===========================================================================

hooks_load() {
  declare -gA FP_HOOKS 2>/dev/null || true
  if [[ -z "${FP_LAYERS_JSON:-}" ]]; then
    return 0
  fi

  local hook_names
  hook_names=$(echo "$FP_LAYERS_JSON" | jq -r '.hooks // {} | keys[]' 2>/dev/null)

  for hook_name in $hook_names; do
    local script_path
    script_path=$(echo "$FP_LAYERS_JSON" | jq -r --arg h "$hook_name" '.hooks[$h]')
    if [[ -n "$script_path" ]]; then
      FP_HOOKS["$hook_name"]="$script_path"
      if [[ ! -x "${REPO_ROOT}/${script_path}" ]]; then
        log_warn "Hook '${hook_name}' script not executable: ${script_path}"
      fi
    fi
  done
}

hooks_run() {
  local hook_name="$1"; shift

  # FP_HOOKS may not be declared yet
  local script_path=""
  if declare -p FP_HOOKS &>/dev/null; then
    script_path="${FP_HOOKS[$hook_name]:-}"
  fi
  if [[ -z "$script_path" ]]; then
    return 0
  fi

  local full_path="${REPO_ROOT}/${script_path}"
  if [[ ! -x "$full_path" ]]; then
    log_warn "Hook '${hook_name}' not executable: ${script_path}"
    return 0
  fi

  log_debug "Running hook '${hook_name}': ${script_path}"

  local hook_output hook_exit
  hook_output=$(_fp_timeout 60 "$full_path" "$@" 2>&1) || true
  hook_exit=$?

  if [[ $hook_exit -eq 124 ]]; then
    log_warn "Hook '${hook_name}' timed out after 60s"
    hook_exit=1
  fi

  log_debug "Hook '${hook_name}' exited with code ${hook_exit}"

  # Blocking hooks (pre_*) can stop the pipeline
  if [[ "$hook_name" == pre_* && $hook_exit -ne 0 ]]; then
    log_warn "Hook '${hook_name}' blocked pipeline: ${hook_output}"
    return 1
  fi

  # Non-blocking hooks (post_*) just log warnings
  if [[ $hook_exit -ne 0 ]]; then
    log_warn "Hook '${hook_name}' failed (non-blocking): ${hook_output}"
  fi

  return 0
}

# Source _fp_timeout from claude-runner if not already defined
if ! declare -f _fp_timeout > /dev/null 2>&1; then
  _fp_timeout() {
    local secs="$1"; shift
    if command -v timeout > /dev/null 2>&1; then
      timeout "$secs" "$@"
    elif command -v gtimeout > /dev/null 2>&1; then
      gtimeout "$secs" "$@"
    else
      "$@" &
      local pid=$!
      (sleep "$secs" && kill "$pid" 2>/dev/null) &
      local watcher=$!
      wait "$pid" 2>/dev/null; local rc=$?
      kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
      if [[ $rc -eq 137 || $rc -eq 143 ]]; then return 124; fi
      return $rc
    fi
  }
fi

# ===========================================================================
# Doctor (I-10)
# ===========================================================================

doctor_run() {
  echo "forgeplan doctor — checking setup..."
  echo ""

  local critical_fail=0
  local warnings=0
  local checks_pass=0
  local total=0

  _doc_ok()   { echo "  ✅ $1"; ((checks_pass++)) || true; ((total++)) || true; }
  _doc_warn() { echo "  ⚠️  $1"; ((warnings++)) || true; ((total++)) || true; }
  _doc_fail() { echo "  ❌ $1"; ((critical_fail++)) || true; ((total++)) || true; }

  # --- Dependencies ---
  echo "Dependencies:"
  [[ "${BASH_VERSINFO[0]}" -ge 4 ]] && _doc_ok "bash ${BASH_VERSION}" || _doc_fail "bash >= 4.0 required (have ${BASH_VERSION})"
  command -v curl > /dev/null 2>&1 && _doc_ok "curl $(curl --version 2>/dev/null | head -1 | cut -d' ' -f2)" || _doc_fail "curl not found"
  command -v jq > /dev/null 2>&1 && _doc_ok "jq $(jq --version 2>&1)" || _doc_fail "jq not found"
  command -v git > /dev/null 2>&1 && _doc_ok "git $(git --version | cut -d' ' -f3)" || _doc_fail "git not found"
  command -v claude > /dev/null 2>&1 && _doc_ok "claude (found)" || _doc_warn "claude not found (required at runtime)"

  # --- Configuration ---
  echo ""
  echo "Configuration:"
  local env_path
  env_path=$(resolve_config ".env")
  [[ -n "$env_path" ]] && _doc_ok ".env loaded from ${env_path}" || _doc_fail ".env not found"

  if [[ -n "$env_path" ]]; then
    local missing_vars=()
    [[ -z "${OP_BASE_URL:-}" ]]   && missing_vars+=("OP_BASE_URL")
    [[ -z "${OP_API_KEY:-}" ]]    && missing_vars+=("OP_API_KEY")
    [[ -z "${OP_PROJECT_ID:-}" ]] && missing_vars+=("OP_PROJECT_ID")
    [[ -z "${REPO_ROOT:-}" ]]     && missing_vars+=("REPO_ROOT")
    if [[ ${#missing_vars[@]} -eq 0 ]]; then
      _doc_ok "Required vars: OP_BASE_URL, OP_API_KEY, OP_PROJECT_ID, REPO_ROOT"
    else
      _doc_fail "Missing required vars: ${missing_vars[*]}"
    fi
  fi

  local config_path
  config_path=$(resolve_config "forgeplan.config.json")
  if [[ -n "$config_path" ]]; then
    local layer_count
    layer_count=$(jq '.layers | length' "$config_path" 2>/dev/null || echo 0)
    local layer_names
    layer_names=$(jq -r '.layers | keys | join(", ")' "$config_path" 2>/dev/null || echo "?")
    _doc_ok "forgeplan.config.json: ${layer_count} layers (${layer_names})"
  else
    _doc_fail "forgeplan.config.json not found"
  fi

  if [[ -n "$config_path" ]]; then
    local has_statuses
    has_statuses=$(jq 'has("statuses")' "$config_path" 2>/dev/null || echo "false")
    if [[ "$has_statuses" == "true" ]]; then
      local mapping_count
      mapping_count=$(jq '[.statuses.pickup_status, .statuses.in_progress_status, .statuses.success_status, .statuses.partial_status] | map(select(. != null)) | length' "$config_path" 2>/dev/null || echo 0)
      _doc_ok "Status mappings: ${mapping_count} configured in forgeplan.config.json"
    else
      _doc_fail "Status mappings not found in forgeplan.config.json. Run: forgeplan --init"
    fi
  fi

  # --- OpenProject ---
  echo ""
  echo "OpenProject:"
  if [[ -n "${OP_BASE_URL:-}" && -n "${OP_API_KEY:-}" ]]; then
    local op_code
    op_code=$(curl --silent --max-time 10 -w '%{http_code}' -o /dev/null \
      -H "Authorization: Bearer ${OP_API_KEY}" \
      "${OP_BASE_URL}/api/v3" 2>/dev/null) || op_code="000"
    if [[ "$op_code" == "200" ]]; then
      _doc_ok "Connected to ${OP_BASE_URL}"
      _doc_ok "Authenticated (HTTP 200)"
    elif [[ "$op_code" == "401" ]]; then
      _doc_fail "Authentication failed (HTTP 401). Check OP_API_KEY."
    elif [[ "$op_code" == "000" ]]; then
      _doc_fail "Cannot reach ${OP_BASE_URL}"
    else
      _doc_fail "Unexpected response (HTTP ${op_code}) from ${OP_BASE_URL}"
    fi

    if [[ -n "${OP_PROJECT_ID:-}" && "$op_code" == "200" ]]; then
      local proj_code
      proj_code=$(curl --silent --max-time 10 -w '%{http_code}' -o /dev/null \
        -H "Authorization: Bearer ${OP_API_KEY}" \
        "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}" 2>/dev/null) || proj_code="000"
      [[ "$proj_code" == "200" ]] && _doc_ok "Project '${OP_PROJECT_ID}' accessible" || _doc_fail "Project '${OP_PROJECT_ID}' not found (HTTP ${proj_code})"
    fi
  else
    _doc_fail "OP_BASE_URL or OP_API_KEY not set"
  fi

  # --- Repository ---
  echo ""
  echo "Repository:"
  if [[ -n "${REPO_ROOT:-}" && -d "${REPO_ROOT}" ]]; then
    [[ -d "${REPO_ROOT}/.git" ]] && _doc_ok "REPO_ROOT: ${REPO_ROOT} (.git found)" || _doc_fail "REPO_ROOT: ${REPO_ROOT} (no .git)"
    [[ -f "${REPO_ROOT}/CLAUDE.md" ]] && _doc_ok "CLAUDE.md found" || _doc_warn "CLAUDE.md not found"
    if [[ -n "${GIT_REMOTE:-}" ]]; then
      git -C "${REPO_ROOT}" remote get-url "${GIT_REMOTE}" > /dev/null 2>&1 \
        && _doc_ok "Remote '${GIT_REMOTE}' → $(git -C "${REPO_ROOT}" remote get-url "${GIT_REMOTE}" 2>/dev/null)" \
        || _doc_warn "Remote '${GIT_REMOTE}' not found"
    fi
    if [[ -f "${REPO_ROOT}/.gitignore" ]]; then
      grep -qxF '.env' "${REPO_ROOT}/.gitignore" 2>/dev/null \
        && _doc_ok ".env in .gitignore" \
        || _doc_warn ".env is NOT in .gitignore — add it to protect secrets"
    else
      _doc_warn "No .gitignore found"
    fi
  elif [[ -n "${REPO_ROOT:-}" ]]; then
    _doc_fail "REPO_ROOT directory does not exist: ${REPO_ROOT}"
  fi

  # --- Summary ---
  echo ""
  local passed=$((total - critical_fail - warnings))
  echo "Result: ${passed}/${total} checks passed, ${warnings} warning(s), ${critical_fail} failure(s)"

  if [[ $critical_fail -gt 0 ]]; then
    exit 3
  fi
}

# ===========================================================================
# Comment builder
# ===========================================================================

build_wp_comment() {
  local wp_id="$1"
  local result="$2"
  local branch="${3:-N/A}"
  local pr_url="${4:-N/A}"
  local duration="${5:-0}"
  local cost="${6:-unknown}"
  local turns="${7:-unknown}"
  local files_list="${8:-}"
  local validation="${9:-PASSED}"

  local icon
  if [[ "$result" == "SUCCESS" ]]; then
    icon="[OK]"
  elif [[ "$result" == "PARTIAL" ]]; then
    icon="[WARN]"
  else
    icon="[FAIL]"
  fi

  local comment="${icon} **forgeplan Generation Report**

**Result:** ${result}
**Branch:** \`${branch}\`
**PR:** ${pr_url}
**Duration:** ${duration}s | **Cost:** \$${cost}
**Model:** ${CLAUDE_MODEL:-unknown} | **Turns:** ${turns}"

  if [[ -n "$files_list" ]]; then
    comment+="

### Files Changed
\`\`\`
${files_list}
\`\`\`"
  fi

  comment+="

### Validation
${validation}"

  echo "$comment"
}

# ===========================================================================
# Core pipeline: process_wp
# ===========================================================================

process_wp() {
  local wp_id="$1"
  local start_time
  start_time=$(date +%s)

  # --- Step 1: Initialize logging ---
  log_init "$wp_id"
  log_info "Processing WP #${wp_id}"

  # --- Force flag clears state ---
  if [[ "${FLAG_FORCE}" == "true" ]]; then
    state_clear "$wp_id"
  fi

  # --- State & lock ---
  state_load "$wp_id"
  lock_acquire "$wp_id"
  trap "lock_release '$wp_id'" EXIT

  # --- Step 2: Fetch WP ---
  if ! hooks_run "pre_fetch" "$wp_id"; then
    log_warn "Hook 'pre_fetch' blocked WP #${wp_id}"
    state_clear "$wp_id"
    return 2
  fi

  log_info "Fetching WP #${wp_id}..."
  local wp_json
  wp_json=$(op_fetch_wp "$wp_id")
  state_save "$wp_id" "fetch" "done"

  local wp_subject wp_type
  wp_subject=$(echo "$wp_json" | jq -r '.subject // "unknown"')
  wp_type=$(echo "$wp_json" | jq -r '._links.type.title // "Task"')
  log_info "WP #${wp_id}: ${wp_subject} (${wp_type})"

  hooks_run "post_fetch" "$wp_id" "$wp_type" "$wp_subject" || true

  # --- Step 3: Determine layers ---
  local layers
  if [[ -n "${FLAG_LAYER}" ]]; then
    layers="${FLAG_LAYER}"
    log_info "Layer override: ${layers}"
  else
    local routing_field routing_value
    routing_field=$(echo "$FP_LAYERS_JSON" | jq -r '.routingField // "category"')
    routing_value=$(echo "$wp_json" | jq -r --arg f "$routing_field" '._links[$f].title // .[$f] // empty' 2>/dev/null)
    if [[ -z "$routing_value" ]]; then
      routing_value=$(echo "$wp_json" | jq -r --arg f "$routing_field" '.[$f] // empty' 2>/dev/null)
    fi
    layers=$(config_get_layers "${routing_value:-}")
    log_info "Routed to layer(s): ${layers}"
  fi

  # --- Step 4: Quality gate ---
  if [[ "${FLAG_SKIP_QUALITY_GATE}" != "true" ]]; then
    if ! op_validate_wp_quality "$wp_json"; then
      state_clear "$wp_id"
      return 2
    fi
  fi

  # --- Step 5: Set in_progress status ---
  if [[ "${FLAG_SKIP_FEEDBACK}" != "true" && "${FLAG_DRY_RUN}" != "true" ]]; then
    local ip_status_id
    ip_status_id=$(config_get_status_id "in_progress_status")
    if [[ -n "$ip_status_id" ]]; then
      op_update_wp_status "$wp_id" "$ip_status_id" || true
    fi
  elif [[ "${FLAG_DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would set WP #${wp_id} status to IN PROGRESS"
  fi

  # --- Step 6: Git preflight & branch ---
  if [[ "${FLAG_DRY_RUN}" != "true" ]]; then
    git_preflight "$REPO_ROOT"
    git_create_branch "$wp_id" "$wp_subject"
    state_save "$wp_id" "branch" "done"
  else
    local dry_slug
    dry_slug=$(_git_slugify "$wp_subject")
    log_info "[DRY RUN] Would create branch: feature/WP-${wp_id}-${dry_slug}"
  fi

  # --- Step 7: Build prompt ---
  log_info "Building prompt..."
  prompt_build "$wp_json" "$layers"
  state_save "$wp_id" "prompt" "done"
  log_info "Prompt ready: ${FP_PROMPT_FILE}"

  if [[ "${FLAG_DRY_RUN}" == "true" ]]; then
    local prompt_size
    prompt_size=$(wc -c < "$FP_PROMPT_FILE" | tr -d ' ')
    log_info "[DRY RUN] Prompt written to ${FP_PROMPT_FILE} (${prompt_size} bytes)"
    log_info "[DRY RUN] Would invoke: claude --model ${CLAUDE_MODEL} --print --output-format json --prompt-file ${FP_PROMPT_FILE}"
    log_info "[DRY RUN] Skipping: generation, commit, push, PR, feedback"
    state_clear "$wp_id"
    return 0
  fi

  # --- Step 8: Pre-generate hook ---
  if ! hooks_run "pre_generate" "$wp_id" "$FP_PROMPT_FILE" "$layers"; then
    log_warn "Hook 'pre_generate' blocked code generation for WP #${wp_id}"
    op_post_comment "$wp_id" "⚠️ Hook 'pre_generate' blocked code generation." || true
    state_clear "$wp_id"
    return 2
  fi

  # --- Step 9: Invoke Claude Code ---
  log_info "Invoking Claude Code..."
  claude_run "$FP_PROMPT_FILE" "$REPO_ROOT"
  state_save "$wp_id" "generate" "done"

  hooks_run "post_generate" "$wp_id" "$CLAUDE_RESULT" "${CLAUDE_FILES_CREATED:-0}" || true

  # --- Step 10: Interactive review ---
  if [[ "${FLAG_REVIEW}" == "true" && ("$CLAUDE_RESULT" == "SUCCESS" || "$CLAUDE_RESULT" == "PARTIAL") ]]; then
    if ! git_interactive_review "$REPO_ROOT"; then
      CLAUDE_RESULT="FAILURE"
      CLAUDE_FAILURE_REASON="rejected_by_reviewer"
      log_info "Changes rejected by reviewer"
    fi
  fi

  # --- Step 11: Commit ---
  if [[ "$CLAUDE_RESULT" != "FAILURE" || ("${CLAUDE_FAILURE_REASON:-}" == "timeout" && -n "$CLAUDE_CHANGED_FILES") ]]; then
    # Pre-commit hook
    hooks_run "pre_commit" "$wp_id" "${GIT_BRANCH_NAME:-}" "$CLAUDE_CHANGED_FILES" || {
      log_warn "Hook 'pre_commit' blocked commit for WP #${wp_id}"
      op_post_comment "$wp_id" "⚠️ Hook 'pre_commit' blocked commit." || true
      CLAUDE_RESULT="FAILURE"
    }

    if [[ "$CLAUDE_RESULT" != "FAILURE" ]]; then
      git_stage_and_commit "$wp_id" "$wp_subject" "$CLAUDE_RESULT" "${CLAUDE_VALIDATION_OUTPUT:-}"
      state_save "$wp_id" "commit" "done"
      hooks_run "post_commit" "$wp_id" "${GIT_BRANCH_NAME}" "${GIT_COMMIT_SHA}" || true
    fi
  fi

  # --- Step 12: Push ---
  if [[ "$CLAUDE_RESULT" != "FAILURE" && "${FLAG_SKIP_PUSH}" != "true" ]]; then
    git_push || true
    state_save "$wp_id" "push" "done"
    hooks_run "post_push" "$wp_id" "${GIT_BRANCH_NAME}" "${PR_URL:-}" || true
  fi

  # --- Step 13: Create PR ---
  if [[ "$CLAUDE_RESULT" != "FAILURE" && "${FLAG_SKIP_PR}" != "true" && "${FLAG_SKIP_PUSH}" != "true" ]]; then
    pr_create "$wp_id" "$wp_subject" "$CLAUDE_RESULT" "${GIT_BRANCH_NAME}" "${CLAUDE_CHANGED_FILES:-}" || true
    state_save "$wp_id" "pr" "done"
  fi

  # --- Step 14: Update OP status + post comment ---
  if [[ "${FLAG_SKIP_FEEDBACK}" != "true" ]]; then
    local final_status_id=""
    case "$CLAUDE_RESULT" in
      SUCCESS) final_status_id=$(config_get_status_id "success_status") ;;
      PARTIAL) final_status_id=$(config_get_status_id "partial_status") ;;
      FAILURE) final_status_id=$(config_get_status_id "failure_status") ;;
    esac

    if [[ -n "$final_status_id" ]]; then
      op_update_wp_status "$wp_id" "$final_status_id" || true
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    local validation_text="PASSED"
    if [[ "$CLAUDE_RESULT" == "PARTIAL" ]]; then
      validation_text="${CLAUDE_VALIDATION_OUTPUT:-FAILED}"
    elif [[ "$CLAUDE_RESULT" == "FAILURE" ]]; then
      validation_text="N/A (${CLAUDE_FAILURE_REASON:-unknown})"
    fi

    local comment
    comment=$(build_wp_comment "$wp_id" "$CLAUDE_RESULT" "${GIT_BRANCH_NAME:-}" "${PR_URL:-N/A}" \
      "$duration" "${CLAUDE_COST_USD:-unknown}" "${CLAUDE_NUM_TURNS:-unknown}" \
      "${CLAUDE_CHANGED_FILES:-}" "$validation_text")
    op_post_comment "$wp_id" "$comment" || true

    state_save "$wp_id" "feedback" "done"
  fi

  # --- Step 15: Log summary ---
  local end_time duration
  end_time=$(date +%s)
  duration=$((end_time - start_time))

  log_summary "$wp_id" "$CLAUDE_RESULT" "$duration" "${GIT_BRANCH_NAME:-}" "${PR_URL:-}" \
    "${CLAUDE_FILES_CREATED:-0}" "${CLAUDE_FILES_MODIFIED:-0}" "${CLAUDE_COST_USD:-0}"

  hooks_run "post_complete" "$wp_id" "$CLAUDE_RESULT" "$duration" "${PR_URL:-}" || true

  # --- Cleanup state ---
  state_clear "$wp_id"

  # --- Return code ---
  case "$CLAUDE_RESULT" in
    SUCCESS) return 0 ;;
    PARTIAL) return 1 ;;
    *)       return 2 ;;
  esac
}

# ===========================================================================
# Execution mode handlers
# ===========================================================================

handle_single() {
  local wp_id="$1"
  process_wp "$wp_id"
}

handle_batch() {
  local id_list="$1"
  local success=0 partial=0 failure=0 total=0

  IFS=',' read -ra wp_ids <<< "$id_list"
  total=${#wp_ids[@]}

  for wp_id in "${wp_ids[@]}"; do
    wp_id=$(echo "$wp_id" | tr -d ' ')
    log_info "=== Batch: processing WP #${wp_id} (${success}+${partial}+${failure}/${total}) ==="
    local rc=0
    process_wp "$wp_id" || rc=$?
    case $rc in
      0) ((success++)) || true ;;
      1) ((partial++)) || true ;;
      *) ((failure++)) || true ;;
    esac
  done

  echo ""
  echo "Batch complete: ${success} success, ${partial} partial, ${failure} failed out of ${total}"

  if [[ $failure -gt 0 ]]; then
    return 2
  elif [[ $partial -gt 0 ]]; then
    return 1
  fi
  return 0
}

handle_queue() {
  local pickup_status_id
  pickup_status_id=$(config_get_status_id "pickup_status")

  if [[ -z "$pickup_status_id" ]]; then
    log_error "Could not resolve pickup_status ID"
    exit 3
  fi

  local pickup_name="${FP_STATUS_MAP[pickup_status]:-unknown}"
  log_info "Querying WPs with status '${pickup_name}' (ID: ${pickup_status_id})..."

  local wp_ids
  wp_ids=$(op_query_wps_by_status "$pickup_status_id")

  if [[ -z "$wp_ids" ]]; then
    log_info "No work packages with status '${pickup_name}' found. Nothing to do."
    return 0
  fi

  local success=0 partial=0 failure=0 total=0

  for wp_id in $wp_ids; do
    ((total++)) || true
    log_info "=== Queue: processing WP #${wp_id} (${success}+${partial}+${failure}/${total}) ==="
    local rc=0
    process_wp "$wp_id" || rc=$?
    case $rc in
      0) ((success++)) || true ;;
      1) ((partial++)) || true ;;
      *) ((failure++)) || true ;;
    esac
  done

  echo ""
  echo "Queue complete: ${success} success, ${partial} partial, ${failure} failed out of ${total}"

  if [[ $failure -gt 0 ]]; then
    return 2
  elif [[ $partial -gt 0 ]]; then
    return 1
  fi
  return 0
}

# ===========================================================================
# Cleanup trap
# ===========================================================================

_cleanup() {
  rm -f "${TMPDIR:-/tmp}"/forgeplan-prompt-*.md 2>/dev/null || true
  rm -f "${CLAUDE_OUTPUT_FILE:-}" 2>/dev/null || true
}

# ===========================================================================
# Main
# ===========================================================================

main() {
  parse_args "$@"
  trap _cleanup EXIT

  # Source lib modules for commands that need them (requires bash 4+)
  case "$COMMAND" in
    init|single|batch|queue|rollback|doctor)
      if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        echo "ERROR: forgeplan requires bash >= 4.0 (you have ${BASH_VERSION})" >&2
        echo "On macOS: brew install bash" >&2
        exit 3
      fi
      source "${FP_INSTALL_DIR}/lib/logger.sh"
      source "${FP_INSTALL_DIR}/lib/config.sh"
      source "${FP_INSTALL_DIR}/lib/openproject.sh"
      source "${FP_INSTALL_DIR}/lib/prompt-builder.sh"
      source "${FP_INSTALL_DIR}/lib/claude-runner.sh"
      source "${FP_INSTALL_DIR}/lib/git-ops.sh"
      source "${FP_INSTALL_DIR}/lib/pr-creator.sh"
      ;;
  esac

  case "$COMMAND" in
    init_project)
      handle_init_project
      ;;

    init)
      source "${FP_INSTALL_DIR}/lib/init.sh"
      config_load "${FLAG_ENV_PATH:-}"
      config_defaults
      init_run
      ;;

    doctor)
      config_load "${FLAG_ENV_PATH:-}" 2>/dev/null || true
      config_defaults
      doctor_run
      ;;

    single)
      config_load "${FLAG_ENV_PATH:-}"
      config_defaults
      config_load_json "${FLAG_CONFIG_PATH:-}"
      config_load_statuses
      config_validate_all
      hooks_load
      handle_single "$COMMAND_ARG"
      ;;

    batch)
      config_load "${FLAG_ENV_PATH:-}"
      config_defaults
      config_load_json "${FLAG_CONFIG_PATH:-}"
      config_load_statuses
      config_validate_all
      hooks_load
      handle_batch "$COMMAND_ARG"
      ;;

    queue)
      config_load "${FLAG_ENV_PATH:-}"
      config_defaults
      config_load_json "${FLAG_CONFIG_PATH:-}"
      config_load_statuses
      config_validate_all
      hooks_load
      handle_queue
      ;;

    rollback)
      config_load "${FLAG_ENV_PATH:-}"
      config_defaults
      config_load_json "${FLAG_CONFIG_PATH:-}"
      config_load_statuses
      handle_rollback "$COMMAND_ARG"
      ;;
  esac
}

main "$@"
