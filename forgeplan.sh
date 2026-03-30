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
  forgeplan --init                    Full project setup: credentials, config, statuses — all in one
  forgeplan --remap-statuses          Re-run just the OpenProject status mapping
  forgeplan --doctor                  Run full health check diagnostic
  forgeplan --wp <ID>                 Process a single work package
  forgeplan --batch <ID1,ID2,ID3>    Process multiple work packages sequentially
  forgeplan --queue                   Auto-discover and process all ready WPs
  forgeplan --rollback <ID>           Undo a previous generation: close PR, delete branch, revert status
  forgeplan --update                  Update forgeplan to the latest version
  forgeplan --uninstall               Remove forgeplan from your system

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
# --uninstall handler
# ---------------------------------------------------------------------------
handle_uninstall() {
  local bindir datadir
  local self_path
  self_path="$(command -v forgeplan 2>/dev/null || echo "")"

  if [[ "$FP_INSTALL_DIR" != "__INSTALL_DIR__" && "$FP_INSTALL_DIR" != "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ]]; then
    # Installed via install.sh — derive paths from FP_INSTALL_DIR
    datadir="$FP_INSTALL_DIR"
    bindir="$(dirname "$datadir")/bin"
  elif [[ -n "$self_path" ]]; then
    bindir="$(dirname "$self_path")"
    datadir="$(dirname "$bindir")/share/forgeplan"
  else
    echo "ERROR: Cannot determine install location." >&2
    echo "If you installed manually, remove the 'forgeplan' binary and its share directory." >&2
    exit 3
  fi

  echo "Uninstalling forgeplan..."

  if [[ -f "${bindir}/forgeplan" ]]; then
    rm -f "${bindir}/forgeplan"
    echo "  Removed ${bindir}/forgeplan"
  else
    echo "  ${bindir}/forgeplan not found (already removed?)"
  fi

  if [[ -d "${datadir}" ]]; then
    rm -rf "${datadir}"
    echo "  Removed ${datadir}/"
  else
    echo "  ${datadir}/ not found (already removed?)"
  fi

  echo ""
  echo "✅ forgeplan uninstalled"
  echo "   Per-project files (.env, forgeplan.config.json) are NOT removed."
}

# ---------------------------------------------------------------------------
# --update handler
# ---------------------------------------------------------------------------
handle_update() {
  local repo_url="https://github.com/tamzid958/forgeplan.git"
  local bindir datadir prefix

  # Determine current install location
  if [[ "$FP_INSTALL_DIR" != "__INSTALL_DIR__" && "$FP_INSTALL_DIR" != "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" ]]; then
    datadir="$FP_INSTALL_DIR"
    bindir="$(dirname "$datadir")/bin"
    prefix="$(dirname "$datadir" | sed 's|/share$||')"
  else
    local self_path
    self_path="$(command -v forgeplan 2>/dev/null || echo "")"
    if [[ -n "$self_path" ]]; then
      bindir="$(dirname "$self_path")"
      prefix="$(dirname "$bindir")"
      datadir="${prefix}/share/forgeplan"
    else
      echo "ERROR: Cannot determine install location." >&2
      exit 3
    fi
  fi

  local old_version
  old_version="$(cat "$datadir/VERSION" 2>/dev/null || echo "unknown")"

  # Check latest version from remote before cloning
  echo "Checking for updates..."
  local remote_version
  remote_version="$(curl -fsSL "https://raw.githubusercontent.com/tamzid958/forgeplan/master/VERSION" 2>/dev/null || echo "")"

  if [[ -z "$remote_version" ]]; then
    echo "ERROR: Failed to check latest version." >&2
    exit 1
  fi

  if [[ "$old_version" == "$remote_version" ]]; then
    echo "✅ forgeplan is already up to date (${old_version})"
    return 0
  fi

  echo "New version available: ${old_version} → ${remote_version}"
  echo "Downloading..."

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" RETURN

  git clone --depth 1 "$repo_url" "$tmpdir" 2>/dev/null || {
    echo "ERROR: Failed to download latest version." >&2
    exit 1
  }

  # Re-run install from the downloaded copy
  mkdir -p "${bindir}" "${datadir}/lib"

  sed "s|FP_INSTALL_DIR=__INSTALL_DIR__|FP_INSTALL_DIR=${datadir}|" \
    "${tmpdir}/forgeplan.sh" > "${bindir}/forgeplan"
  chmod +x "${bindir}/forgeplan"

  cp "${tmpdir}"/lib/*.sh "${datadir}/lib/"
  cp "${tmpdir}"/prompt.template*.md "${datadir}/" 2>/dev/null || true
  cp "${tmpdir}/.env.example" "${datadir}/"
  cp "${tmpdir}/forgeplan.config.json.example" "${datadir}/"
  cp "${tmpdir}/VERSION" "${datadir}/"

  echo ""
  echo "✅ forgeplan updated: ${old_version} → ${remote_version}"
}

# ---------------------------------------------------------------------------
# --init handler
# ---------------------------------------------------------------------------
handle_init_project() {
  echo "forgeplan — Project Setup"
  echo "========================="
  echo ""

  local project_dir
  project_dir=$(pwd)
  echo "Working in: ${project_dir}"
  echo ""

  # --- Step 1: OpenProject connection ---
  echo "--- OpenProject Connection ---"
  echo ""

  local op_base_url op_api_key op_project_id

  printf "OpenProject URL (e.g., https://op.example.com): "
  read -r op_base_url
  if [[ -z "$op_base_url" ]]; then
    echo "ERROR: OpenProject URL is required." >&2; exit 3
  fi
  op_base_url="${op_base_url%/}"

  echo ""
  echo "You need an API token from OpenProject."
  echo "  → Log in → Avatar (top right) → My account → Access tokens → Generate → API"
  echo ""
  printf "OpenProject API key: "
  read -r op_api_key
  if [[ -z "$op_api_key" ]]; then
    echo "ERROR: API key is required." >&2; exit 3
  fi

  printf "Default OpenProject project slug (from the URL, e.g., 'my-project'): "
  read -r op_project_id
  if [[ -z "$op_project_id" ]]; then
    echo "ERROR: Project ID is required." >&2; exit 3
  fi

  # Write .env (secrets only)
  cat > .env <<ENVFILE
# forgeplan — Secrets (generated by --init)
OP_API_KEY="${op_api_key}"
ENVFILE
  echo ""
  echo "✅ .env created (secrets only)"

  # Export for status mapping later
  OP_BASE_URL="$op_base_url"
  OP_PROJECT_ID="$op_project_id"
  OP_API_KEY="$op_api_key"
  export OP_BASE_URL OP_PROJECT_ID OP_API_KEY

  # --- Step 2: Layers / projects ---
  echo ""
  echo "--- Project Layers ---"
  echo "A layer is a part of your codebase (backend, frontend, mobile, etc.)."
  echo "Layer name is derived from the path (e.g., iam → iam, src/backend → backend, . → app)."
  echo ""

  local layer_paths_input
  printf "Layer paths, comma-separated (e.g., iam,eims-flutter or .) [.]: "
  read -r layer_paths_input
  layer_paths_input="${layer_paths_input:-.}"

  # Parse comma-separated paths into array
  local path_arr=()
  IFS=',' read -ra path_arr <<< "$layer_paths_input"

  # Collect details for each layer
  local layers_json="{}"
  local routing_map="{}"
  local first_layer=""

  for raw_path in "${path_arr[@]}"; do
    # Trim whitespace
    local l_path
    l_path=$(echo "$raw_path" | xargs)
    l_path="${l_path:-.}"

    # Derive layer name from path
    local l_name
    if [[ "$l_path" == "." ]]; then
      l_name="app"
    else
      l_name=$(basename "$l_path")
    fi

    [[ -z "$first_layer" ]] && first_layer="$l_name"

    # Build layer JSON
    local layer_obj
    layer_obj=$(jq -n --arg p "$l_path" \
      '{path: $p, techStack: "", filePatterns: [], buildCmd: ""}')

    layers_json=$(echo "$layers_json" | jq --arg name "$l_name" --argjson obj "$layer_obj" '. + {($name): $obj}')
    routing_map=$(echo "$routing_map" | jq --arg key "$l_name" --arg val "$l_name" '. + {($key): $val}')
  done

  # --- Step 2b: Optional settings ---
  echo ""
  echo "--- Optional Settings ---"
  echo ""

  local reviewers claude_model validation_cmd

  printf "PR reviewer usernames, comma-separated [skip]: "
  read -r reviewers
  [[ "$reviewers" == "skip" ]] && reviewers=""

  echo "Claude model alias (e.g., sonnet, opus, haiku) or full model ID."
  printf "Claude model [sonnet]: "
  read -r claude_model
  claude_model="${claude_model:-sonnet}"

  printf "Validation command (e.g., 'npm run build') [none]: "
  read -r validation_cmd
  [[ "$validation_cmd" == "none" ]] && validation_cmd=""

  # Add optional settings to .env
  cat >> .env <<ENVFILE

# --- Claude Code ---
CLAUDE_MODEL="${claude_model}"
ENVFILE
  [[ -n "$validation_cmd" ]] && echo "VALIDATION_CMD=\"${validation_cmd}\"" >> .env

  # --- Step 3: Build forgeplan.config.json ---
  echo ""

  local config_json
  config_json=$(jq -n \
    --arg url "$op_base_url" \
    --arg pid "$op_project_id" \
    --argjson layers "$layers_json" \
    --argjson routing "$routing_map" \
    --arg default_layer "$first_layer" \
    '{
      openproject: {url: $url, projectId: $pid},
      layers: $layers,
      routingField: "category",
      routingMap: $routing,
      defaultLayer: $default_layer,
      hooks: {}
    }')

  # Add reviewers if provided
  if [[ -n "$reviewers" ]]; then
    local reviewers_json
    reviewers_json=$(echo "$reviewers" | tr ',' '\n' | jq -R . | jq -sc '.')
    config_json=$(echo "$config_json" | jq --argjson r "$reviewers_json" '. + {reviewers: $r}')
  fi

  echo "$config_json" | jq '.' > forgeplan.config.json
  local layer_count=${#path_arr[@]}
  echo "✅ forgeplan.config.json created with ${layer_count} layer(s)"

  # --- Step 3b: Enrich layers with Claude Code ---
  if command -v claude > /dev/null 2>&1; then
    echo ""
    printf "Use Claude Code to auto-detect tech stack, file patterns, and build commands? [Y/n]: "
    local enrich_answer
    read -r enrich_answer
    if [[ "$enrich_answer" != "n" && "$enrich_answer" != "N" ]]; then
      _init_enrich_layers
    fi
  fi

  # --- Step 4: Generate CLAUDE.md and .gitignore per layer repo ---
  echo ""
  local layer_names
  layer_names=$(echo "$config_json" | jq -r '.layers | keys[]')

  local seen_dirs=""
  for l_name in $layer_names; do
    local l_path
    l_path=$(echo "$config_json" | jq -r --arg l "$l_name" '.layers[$l].path')

    # Resolve absolute path (handle "." correctly)
    local abs_path
    if [[ "$l_path" == "." ]]; then
      abs_path="$project_dir"
    else
      abs_path="${project_dir}/${l_path}"
    fi

    # Find the git root for this layer (falls back to abs_path if not a repo)
    local target_dir
    target_dir=$(git -C "$abs_path" rev-parse --show-toplevel 2>/dev/null || echo "$abs_path")

    # Skip if we already processed this directory
    if echo "$seen_dirs" | grep -qxF "$target_dir"; then
      continue
    fi
    seen_dirs="${seen_dirs}${target_dir}
"

    echo "--- Setting up: ${target_dir} ---"

    # CLAUDE.md
    if [[ -f "${target_dir}/CLAUDE.md" ]]; then
      echo "  CLAUDE.md already exists, skipping."
    else
      local prev_dir; prev_dir=$(pwd)
      cd "$target_dir"
      _init_claude_md_generate
      cd "$prev_dir"
      echo "  ✅ CLAUDE.md created"
    fi

    # .gitignore
    if [[ -f "${target_dir}/.gitignore" ]]; then
      grep -qxF '.env' "${target_dir}/.gitignore" 2>/dev/null || echo '.env' >> "${target_dir}/.gitignore"
      grep -qxF 'logs/' "${target_dir}/.gitignore" 2>/dev/null || echo 'logs/' >> "${target_dir}/.gitignore"
      echo "  ✅ .gitignore updated"
    else
      local prev_dir; prev_dir=$(pwd)
      cd "$target_dir"
      _init_gitignore_generate
      cd "$prev_dir"
      echo "  ✅ .gitignore created"
    fi
  done

  # Ensure project root has .gitignore with .env (for multi-repo setups where root isn't a layer)
  if ! echo "$seen_dirs" | grep -qxF "$project_dir"; then
    if [[ -f "${project_dir}/.gitignore" ]]; then
      grep -qxF '.env' "${project_dir}/.gitignore" 2>/dev/null || echo '.env' >> "${project_dir}/.gitignore"
    else
      printf '.env\nlogs/\n' > "${project_dir}/.gitignore"
    fi
    echo "✅ Root .gitignore updated"
  fi

  # --- Step 6: Map OpenProject statuses ---
  echo ""
  echo "--- OpenProject Status Mapping ---"
  echo ""

  source "${FP_INSTALL_DIR}/lib/config.sh" 2>/dev/null || true
  source "${FP_INSTALL_DIR}/lib/init.sh" 2>/dev/null || true

  if type init_validate_connection &>/dev/null; then
    # REPO_ROOT may not be a git repo (e.g., mono-repo root where each layer
    # has its own .git). Set it explicitly so config_load skips git detection.
    export REPO_ROOT="$project_dir"
    config_load ""
    config_defaults

    init_validate_connection
    init_validate_project
    echo ""
    echo "Discovering statuses..."
    init_discover_statuses
    init_display_statuses

    # Ask Claude to suggest mappings from the real status names
    init_claude_suggest_statuses

    echo "Map your OpenProject statuses to forgeplan events."
    echo "Flow: [pickup] → forgeplan runs → [in_progress] → done → [success / partial / failure]"
    echo ""

    init_prompt_mapping "pickup_status" \
      "Tickets ready to work on" \
      "forgeplan picks up tickets in this status (--queue scans for these)"

    init_prompt_mapping "in_progress_status" \
      "Ticket is being worked on" \
      "forgeplan sets this while generating code — signals the ticket is taken"

    init_prompt_mapping "success_status" \
      "Code generated and build passed" \
      "forgeplan sets this after opening a PR and validation succeeds"

    init_prompt_mapping "partial_status" \
      "Code generated but build failed" \
      "forgeplan sets this when code was written but validation failed"

    init_prompt_mapping "failure_status" \
      "Generation produced no output  (0 = don't change status)" \
      "forgeplan sets this when it couldn't generate anything at all"

    init_write_config
  else
    echo "⚠️  Skipping status mapping (lib not available)."
    echo "   Run: forgeplan --remap-statuses"
  fi

  echo ""
  echo "✅ Project initialized."
}

# ---------------------------------------------------------------------------
# Enrich existing layers with Claude Code (techStack, filePatterns, buildCmd)
# ---------------------------------------------------------------------------
_init_enrich_layers() {
  echo "Analyzing layers with Claude Code..."
  echo "(This may take 30-60 seconds)"
  echo ""

  local tmp_prompt tmp_output
  tmp_prompt=$(mktemp)
  tmp_output=$(mktemp)

  local current_config
  current_config=$(cat forgeplan.config.json)

  cat > "$tmp_prompt" <<PROMPT
Analyze the repository and enrich the layer definitions in this config.
For each layer, fill in the techStack, filePatterns, and buildCmd based on what you find in the layer's path.

Current config:
${current_config}

Output ONLY valid JSON (no markdown fences, no explanation) with the same structure but with techStack, filePatterns, and buildCmd filled in for each layer.
Keep all other fields (openproject, routingField, routingMap, defaultLayer, hooks, reviewers) unchanged.

Rules:
- techStack: list actual frameworks/languages found (e.g., "Next.js 14, TypeScript, Tailwind CSS")
- filePatterns: glob patterns matching source files (e.g., ["**/*.ts", "**/*.tsx"])
- buildCmd: actual build command from package.json, Makefile, etc. (e.g., "npm run build")
- Output raw JSON only. No markdown. No explanation.
PROMPT

  if claude -p "$(cat "$tmp_prompt")" --output-format text --max-turns 10 \
    > "$tmp_output" 2>/dev/null; then

    local enriched
    enriched=$(cat "$tmp_output" | sed -n '/^\s*{/,/^\s*}/p' | head -200)

    if echo "$enriched" | jq empty 2>/dev/null; then
      echo "$enriched" | jq '.' > forgeplan.config.json
      echo "✅ Layers enriched with tech details"
      echo ""
      jq -r '.layers | to_entries[] | "  - \(.key): \(.value.path) (\(.value.techStack))"' forgeplan.config.json
    else
      echo "⚠️  Claude output wasn't valid JSON. Keeping manual config."
    fi
  else
    echo "⚠️  Claude Code analysis failed. Keeping manual config."
  fi

  rm -f "$tmp_prompt" "$tmp_output"
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

  if claude -p "$(cat "$tmp_prompt")" --output-format text --max-turns 15 \
    > "$tmp_output" 2>/dev/null; then

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

<!-- Generated by forgeplan --init -->
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

  if claude -p "$(cat "$tmp_prompt")" --output-format text --max-turns 5 \
    > "$tmp_output" 2>/dev/null; then

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
      --remap-statuses)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --remap-statuses with --$COMMAND" >&2; exit 3; }
        COMMAND="remap_statuses"; shift ;;
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
      --update)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --update with --$COMMAND" >&2; exit 3; }
        COMMAND="update"; shift ;;
      --uninstall)
        [[ -n "$COMMAND" ]] && { echo "ERROR: Cannot combine --uninstall with --$COMMAND" >&2; exit 3; }
        COMMAND="uninstall"; shift ;;
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
    [[ -z "${OP_API_KEY:-}" ]]    && missing_vars+=("OP_API_KEY (in .env)")
    [[ -z "${OP_BASE_URL:-}" ]]   && missing_vars+=("openproject.url (in forgeplan.config.json)")
    [[ -z "${OP_PROJECT_ID:-}" ]] && missing_vars+=("openproject.projectId (in forgeplan.config.json)")
    [[ -z "${REPO_ROOT:-}" ]]     && missing_vars+=("REPO_ROOT (auto-detected from git)")
    if [[ ${#missing_vars[@]} -eq 0 ]]; then
      _doc_ok "OP_API_KEY, openproject.url, openproject.projectId, REPO_ROOT"
    else
      _doc_fail "Missing: ${missing_vars[*]}"
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
      _doc_fail "Status mappings not found in forgeplan.config.json. Run: forgeplan --remap-statuses"
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
  elif [[ ! -d "${REPO_ROOT}/.git" ]]; then
    # Multi-repo setup: root is not a git repo, each layer has its own .git.
    # Automatic routing is unreliable — prompt the user to select a layer.
    local layer_list
    layer_list=$(echo "$FP_LAYERS_JSON" | jq -r '.layers | keys[]')
    local layer_arr=()
    while IFS= read -r l; do layer_arr+=("$l"); done <<< "$layer_list"
    local layer_count=${#layer_arr[@]}

    echo ""
    echo "WP #${wp_id}: ${wp_subject}"
    echo "Select layer to work in:"
    local li
    for ((li = 0; li < layer_count; li++)); do
      printf "  %d. %s\n" "$((li + 1))" "${layer_arr[$li]}"
    done
    echo ""

    local layer_sel=""
    while true; do
      printf "Layer number(s) [1-%d], comma-separated for multiple: " "$layer_count"
      read -r layer_sel

      # Validate all entries are in range
      local valid=true
      IFS=',' read -ra sel_parts <<< "$layer_sel"
      if [[ ${#sel_parts[@]} -eq 0 ]]; then valid=false; fi
      for part in "${sel_parts[@]}"; do
        part=$(echo "$part" | xargs)
        if ! [[ "$part" =~ ^[0-9]+$ ]] || \
           [[ "$part" -lt 1 || "$part" -gt "$layer_count" ]]; then
          valid=false; break
        fi
      done

      [[ "$valid" == "true" ]] && break
      echo "Invalid. Enter number(s) between 1 and ${layer_count}, e.g. 4 or 4,5"
    done

    # Build space-separated layer names from selections
    layers=""
    IFS=',' read -ra sel_parts <<< "$layer_sel"
    for part in "${sel_parts[@]}"; do
      part=$(echo "$part" | xargs)
      local lname="${layer_arr[$((part - 1))]}"
      layers="${layers:+$layers }$lname"
    done
    log_info "User selected layer(s): ${layers}"
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
  # In multi-repo setups REPO_ROOT is not a git repo — resolve git root from
  # the first selected layer so all git ops target the right repository.
  local first_layer
  first_layer=$(echo "$layers" | awk '{print $1}')
  local layer_git_root
  layer_git_root=$(_resolve_layer_git_dir "$first_layer")
  if [[ "$layer_git_root" != "$REPO_ROOT" ]]; then
    log_info "Using layer git root: ${layer_git_root}"
    REPO_ROOT="$layer_git_root"
    export REPO_ROOT
    # Re-derive GIT_BASE_BRANCH for this layer's repo (may differ from global default)
    local layer_ref
    layer_ref=$(git -C "$REPO_ROOT" symbolic-ref "refs/remotes/${GIT_REMOTE}/HEAD" 2>/dev/null || echo "")
    if [[ -n "$layer_ref" ]]; then
      GIT_BASE_BRANCH="${layer_ref##refs/remotes/${GIT_REMOTE}/}"
    else
      # Fall back to current branch if remote HEAD is not set
      GIT_BASE_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    fi
    export GIT_BASE_BRANCH
    log_info "Base branch for this layer: ${GIT_BASE_BRANCH}"
  fi

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
    # Derive git info from first active layer's path
    local pr_layer pr_repo_slug pr_host_type pr_base_branch
    pr_layer="${layers%% *}"
    pr_repo_slug="$(config_get_layer_repo "$pr_layer")"
    pr_host_type="$(config_get_layer_host_type "$pr_layer")"
    pr_base_branch="$(config_get_layer_base_branch "$pr_layer")"
    pr_create "$wp_id" "$wp_subject" "$CLAUDE_RESULT" "${GIT_BRANCH_NAME}" "${CLAUDE_CHANGED_FILES:-}" "$pr_repo_slug" "$pr_host_type" "$pr_base_branch" || true
    state_save "$wp_id" "pr" "done"
  fi

  # Compute duration once for feedback and logging
  local end_time duration
  end_time=$(date +%s)
  duration=$((end_time - start_time))

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
# Update check (daily, non-blocking)
# ===========================================================================
check_for_update() {
  local cache_file="${TMPDIR:-/tmp}/forgeplan-update-check"
  local cache_max_age=86400  # 24 hours

  # Skip for update/uninstall/version/help commands
  case "${COMMAND:-}" in
    update|uninstall) return ;;
  esac

  # Skip if VERSION file doesn't exist (dev/uninstalled mode)
  [[ -f "$FP_VERSION_FILE" ]] || return

  # Check cache age — skip if checked recently
  if [[ -f "$cache_file" ]]; then
    local cache_age
    local now
    now=$(date +%s)
    cache_age=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
    if (( now - cache_age < cache_max_age )); then
      # Show cached result if update was available
      local cached
      cached="$(cat "$cache_file")"
      if [[ -n "$cached" && "$cached" != "up-to-date" ]]; then
        echo "⬆  Update available: $(cat "$FP_VERSION_FILE") → ${cached} — run 'forgeplan --update'"
      fi
      return
    fi
  fi

  # Fetch remote version with short timeout (non-blocking on failure)
  local remote_version
  remote_version="$(curl -fsSL --max-time 3 "https://raw.githubusercontent.com/tamzid958/forgeplan/master/VERSION" 2>/dev/null || echo "")"

  if [[ -z "$remote_version" ]]; then
    return  # network issue, skip silently
  fi

  local local_version
  local_version="$(cat "$FP_VERSION_FILE")"

  if [[ "$local_version" != "$remote_version" ]]; then
    echo "$remote_version" > "$cache_file"
    echo "⬆  Update available: ${local_version} → ${remote_version} — run 'forgeplan --update'"
  else
    echo "up-to-date" > "$cache_file"
  fi
}

# ===========================================================================
# Main
# ===========================================================================

main() {
  parse_args "$@"
  trap _cleanup EXIT

  # Check for updates (daily, non-blocking)
  check_for_update

  # Source lib modules for commands that need them (requires bash 4+)
  case "$COMMAND" in
    init|remap_statuses|single|batch|queue|rollback|doctor)
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
    init)
      handle_init_project
      ;;

    remap_statuses)
      source "${FP_INSTALL_DIR}/lib/init.sh"
      config_load "${FLAG_ENV_PATH:-}"
      config_defaults
      config_load_json "${FLAG_CONFIG_PATH:-}"
      init_run
      ;;

    doctor)
      config_load "${FLAG_ENV_PATH:-}" 2>/dev/null || true
      config_defaults
      config_load_json "${FLAG_CONFIG_PATH:-}" 2>/dev/null || true
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

    update)
      handle_update
      ;;

    uninstall)
      handle_uninstall
      ;;
  esac
}

main "$@"
