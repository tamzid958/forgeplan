#!/usr/bin/env bash
# forgeplan — lib/config.sh
# Env loading, validation, defaults, layer routing, status mapping.

# Globals set by this module:
#   FP_LAYERS_JSON   — raw JSON content of forgeplan.config.json
#   FP_STATUS_MAP    — associative array: event_name -> status_name
#   FP_STATUS_IDS    — associative array: status_name -> numeric_id

declare -A FP_STATUS_MAP
declare -A FP_STATUS_IDS

# ---------------------------------------------------------------------------
# resolve_config <filename>
# Check CWD first, then FP_INSTALL_DIR. Returns path or empty string.
# ---------------------------------------------------------------------------
resolve_config() {
  local filename="$1"
  if [[ -f "${PWD}/${filename}" ]]; then
    echo "${PWD}/${filename}"
  elif [[ -f "${FP_INSTALL_DIR}/${filename}" ]]; then
    echo "${FP_INSTALL_DIR}/${filename}"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# config_load [env_path]
# Source .env file and validate required variables.
# ---------------------------------------------------------------------------
config_load() {
  local env_path="${1:-}"

  # Resolve .env path
  if [[ -z "$env_path" ]]; then
    env_path=$(resolve_config ".env")
  fi

  if [[ -z "$env_path" || ! -f "$env_path" ]]; then
    echo "ERROR: .env not found. Run forgeplan --init to scaffold config files." >&2
    exit 3
  fi

  # shellcheck disable=SC1090
  source "$env_path"

  # Validate OP_API_KEY (the only secret that must be in .env)
  if [[ -z "${OP_API_KEY:-}" ]]; then
    echo "ERROR: OP_API_KEY is required but not set in .env" >&2
    exit 3
  fi

  # Auto-detect REPO_ROOT from git if not set
  if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
      echo "ERROR: Not inside a git repository. Run forgeplan from your project directory." >&2
      exit 3
    fi
  fi

  export OP_API_KEY REPO_ROOT
}

# ---------------------------------------------------------------------------
# config_defaults
# Set defaults for optional variables (only if unset or empty).
# ---------------------------------------------------------------------------
config_defaults() {
  : "${GIT_REMOTE:=origin}"
  : "${GIT_BASE_BRANCH:=develop}"
  : "${CLAUDE_MODEL:=claude-sonnet-4-20250514}"
  : "${LOG_DIR:=./logs}"
  : "${DRY_RUN:=false}"
  : "${GENERATION_TIMEOUT:=600}"
  : "${VALIDATION_TIMEOUT:=120}"
  : "${PROMPT_MAX_TOKENS:=30000}"
  : "${CLAUDE_MAX_RETRIES:=3}"
  : "${CLAUDE_RETRY_DELAY:=10}"

  export GIT_REMOTE GIT_BASE_BRANCH CLAUDE_MODEL LOG_DIR DRY_RUN
  export GENERATION_TIMEOUT VALIDATION_TIMEOUT PROMPT_MAX_TOKENS
  export CLAUDE_MAX_RETRIES CLAUDE_RETRY_DELAY
}

# ---------------------------------------------------------------------------
# config_load_json [config_path]
# Parse and validate forgeplan.config.json. Stores in FP_LAYERS_JSON.
# ---------------------------------------------------------------------------
config_load_json() {
  local config_path="${1:-}"

  if [[ -z "$config_path" ]]; then
    config_path=$(resolve_config "forgeplan.config.json")
  fi

  if [[ -z "$config_path" || ! -f "$config_path" ]]; then
    echo "ERROR: forgeplan.config.json not found. Run forgeplan --init to scaffold config files." >&2
    exit 3
  fi

  # Validate JSON syntax
  if ! jq empty "$config_path" 2>/dev/null; then
    echo "ERROR: forgeplan.config.json is not valid JSON:" >&2
    jq empty "$config_path" 2>&1 >&2 || true
    exit 3
  fi

  FP_LAYERS_JSON=$(cat "$config_path")

  # Validate layers key exists and is a non-empty object
  local layer_count
  layer_count=$(echo "$FP_LAYERS_JSON" | jq '.layers | length')
  if [[ "$layer_count" -eq 0 ]]; then
    echo "ERROR: forgeplan.config.json must have at least one layer defined in 'layers'" >&2
    exit 3
  fi

  # Validate each layer has required fields
  local invalid_layers
  invalid_layers=$(echo "$FP_LAYERS_JSON" | jq -r '
    .layers | to_entries[]
    | select(.value.path == null or .value.techStack == null)
    | .key
  ')

  if [[ -n "$invalid_layers" ]]; then
    echo "ERROR: The following layers are missing required fields (path, techStack):" >&2
    echo "$invalid_layers" >&2
    exit 3
  fi

  # Load OpenProject config from JSON (top-level defaults)
  local op_url op_project
  op_url=$(echo "$FP_LAYERS_JSON" | jq -r '.openproject.url // empty')
  op_project=$(echo "$FP_LAYERS_JSON" | jq -r '.openproject.projectId // empty')

  if [[ -n "$op_url" ]]; then
    OP_BASE_URL="${op_url%/}"
    export OP_BASE_URL
  fi
  if [[ -n "$op_project" ]]; then
    OP_PROJECT_ID="$op_project"
    export OP_PROJECT_ID
  fi

  if [[ -z "${OP_BASE_URL:-}" ]]; then
    echo "ERROR: openproject.url is required in forgeplan.config.json" >&2
    exit 3
  fi
  if [[ -z "${OP_PROJECT_ID:-}" ]]; then
    echo "ERROR: openproject.projectId is required in forgeplan.config.json" >&2
    exit 3
  fi
}

# ---------------------------------------------------------------------------
# config_load_statuses
# Load status mappings from the "statuses" key in forgeplan.config.json
# (stored in FP_LAYERS_JSON). Populates FP_STATUS_MAP and FP_STATUS_IDS.
# ---------------------------------------------------------------------------
config_load_statuses() {
  # Read from the already-loaded FP_LAYERS_JSON
  local has_statuses
  has_statuses=$(echo "$FP_LAYERS_JSON" | jq 'has("statuses")')

  if [[ "$has_statuses" != "true" ]]; then
    echo "ERROR: Status mapping not found in forgeplan.config.json. Run forgeplan --init first." >&2
    exit 3
  fi

  local statuses_json
  statuses_json=$(echo "$FP_LAYERS_JSON" | jq '.statuses')

  # Validate required keys exist
  local required_keys=("pickup_status" "in_progress_status" "success_status" "partial_status")
  for key in "${required_keys[@]}"; do
    local val
    val=$(echo "$statuses_json" | jq -r --arg k "$key" '.[$k] // empty')
    if [[ -z "$val" ]]; then
      echo "ERROR: Missing required key '${key}' in forgeplan.config.json statuses. Run forgeplan --init" >&2
      exit 3
    fi
    FP_STATUS_MAP["$key"]="$val"
  done

  # failure_status can be null
  local failure_val
  failure_val=$(echo "$statuses_json" | jq -r '.failure_status // ""')
  FP_STATUS_MAP["failure_status"]="$failure_val"

  # Validate _status_ids exists and populate
  local ids_count
  ids_count=$(echo "$statuses_json" | jq '._status_ids | length')
  if [[ "$ids_count" -eq 0 ]]; then
    echo "ERROR: _status_ids is missing or empty in forgeplan.config.json statuses" >&2
    exit 3
  fi

  # Populate FP_STATUS_IDS associative array
  while IFS=$'\t' read -r name id; do
    FP_STATUS_IDS["$name"]="$id"
  done < <(echo "$statuses_json" | jq -r '._status_ids | to_entries[] | [.key, (.value|tostring)] | @tsv')
}

# ---------------------------------------------------------------------------
# config_get_status_id <event_name>
# Lookup: event -> status_name -> numeric_id.
# ---------------------------------------------------------------------------
config_get_status_id() {
  local event_name="$1"

  local status_name="${FP_STATUS_MAP[$event_name]:-}"

  # failure_status can be null/empty — return empty string
  if [[ "$event_name" == "failure_status" && -z "$status_name" ]]; then
    echo ""
    return 0
  fi

  if [[ -z "$status_name" ]]; then
    echo "ERROR: No status mapping found for event '${event_name}'" >&2
    exit 3
  fi

  local status_id="${FP_STATUS_IDS[$status_name]:-}"
  if [[ -z "$status_id" ]]; then
    echo "ERROR: Status '${status_name}' not found in cached IDs. Re-run forgeplan --init" >&2
    exit 3
  fi

  echo "$status_id"
}

# ---------------------------------------------------------------------------
# config_get_layers <routing_value>
# Resolve routing field value to layer name(s).
# ---------------------------------------------------------------------------
config_get_layers() {
  local routing_value="$1"

  # Lookup in routingMap
  local mapping
  mapping=$(echo "$FP_LAYERS_JSON" | jq -r --arg val "$routing_value" '.routingMap[$val] // null')

  if [[ "$mapping" != "null" ]]; then
    # Check if it's an array or string
    local map_type
    map_type=$(echo "$FP_LAYERS_JSON" | jq -r --arg val "$routing_value" '.routingMap[$val] | type')

    if [[ "$map_type" == "array" ]]; then
      echo "$FP_LAYERS_JSON" | jq -r --arg val "$routing_value" '.routingMap[$val] | join(" ")'
    else
      echo "$mapping"
    fi
    return 0
  fi

  # Try defaultLayer
  local default_layer
  default_layer=$(echo "$FP_LAYERS_JSON" | jq -r '.defaultLayer // null')
  if [[ "$default_layer" != "null" ]]; then
    echo "$default_layer"
    return 0
  fi

  # Fallback: return all layer names
  log_warn "No layer mapping for '${routing_value}'. Targeting all layers."
  echo "$FP_LAYERS_JSON" | jq -r '.layers | keys | join(" ")'
}

# ---------------------------------------------------------------------------
# config_get_layer_op_project <layer_name>
# Return the OpenProject project ID for a layer. Falls back to top-level.
# ---------------------------------------------------------------------------
config_get_layer_op_project() {
  local layer_name="$1"

  local layer_project
  layer_project=$(echo "$FP_LAYERS_JSON" | jq -r --arg l "$layer_name" '.layers[$l].openproject.projectId // empty')

  if [[ -n "$layer_project" ]]; then
    echo "$layer_project"
  else
    echo "${OP_PROJECT_ID}"
  fi
}

# ---------------------------------------------------------------------------
# _resolve_layer_git_dir <layer_name>
# Find the git root for a layer's path.
# ---------------------------------------------------------------------------
_resolve_layer_git_dir() {
  local layer_name="$1"

  local layer_path
  layer_path=$(echo "$FP_LAYERS_JSON" | jq -r --arg l "$layer_name" '.layers[$l].path // empty')

  local abs_path="${REPO_ROOT}/${layer_path}"
  if [[ ! -d "$abs_path" ]]; then
    abs_path="$REPO_ROOT"
  fi

  git -C "$abs_path" rev-parse --show-toplevel 2>/dev/null || echo "$REPO_ROOT"
}

# ---------------------------------------------------------------------------
# config_get_layer_repo <layer_name>
# Derive repo slug (org/repo) from git remote of the layer's path.
# ---------------------------------------------------------------------------
config_get_layer_repo() {
  local layer_name="$1"
  local git_dir
  git_dir=$(_resolve_layer_git_dir "$layer_name")

  local remote_url
  remote_url=$(git -C "$git_dir" remote get-url origin 2>/dev/null || echo "")

  if [[ -z "$remote_url" ]]; then
    echo ""
    return 1
  fi

  # git@github.com:org/repo.git -> org/repo
  # https://github.com/org/repo.git -> org/repo
  echo "$remote_url" | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#'
}

# ---------------------------------------------------------------------------
# config_get_layer_host_type <layer_name>
# Derive git host type (github/gitlab/bitbucket) from remote URL.
# ---------------------------------------------------------------------------
config_get_layer_host_type() {
  local layer_name="$1"
  local git_dir
  git_dir=$(_resolve_layer_git_dir "$layer_name")

  local remote_url
  remote_url=$(git -C "$git_dir" remote get-url origin 2>/dev/null || echo "")

  case "$remote_url" in
    *github.com*)    echo "github" ;;
    *gitlab.com*|*gitlab.*)  echo "gitlab" ;;
    *bitbucket.org*|*bitbucket.*) echo "bitbucket" ;;
    *) echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# config_get_layer_base_branch <layer_name>
# Derive default branch from git remote HEAD.
# ---------------------------------------------------------------------------
config_get_layer_base_branch() {
  local layer_name="$1"
  local git_dir
  git_dir=$(_resolve_layer_git_dir "$layer_name")

  local ref
  ref=$(git -C "$git_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo "")

  if [[ -n "$ref" ]]; then
    echo "${ref##refs/remotes/origin/}"
  else
    echo "main"
  fi
}

# ---------------------------------------------------------------------------
# config_validate_all
# Final validation after all config is loaded.
# ---------------------------------------------------------------------------
config_validate_all() {
  # Verify REPO_ROOT is a git repo
  if [[ ! -d "${REPO_ROOT}/.git" ]]; then
    echo "ERROR: ${REPO_ROOT} is not a Git repository (no .git directory)" >&2
    exit 3
  fi

  # Verify .env is in .gitignore
  local gitignore="${REPO_ROOT}/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qxF '.env' "$gitignore" 2>/dev/null; then
      echo "ERROR: .env file is tracked by Git. Add it to .gitignore to protect secrets." >&2
      exit 3
    fi
  else
    echo "ERROR: .env file is tracked by Git. Add it to .gitignore to protect secrets." >&2
    exit 3
  fi

  # Verify GIT_HOST_TOKEN exists (needed for PR creation)
  if [[ -z "${GIT_HOST_TOKEN:-}" ]]; then
    log_warn "GIT_HOST_TOKEN not set. PR creation will be skipped."
  fi

  # Warn if CLAUDE.md is missing (non-fatal)
  if [[ ! -f "${REPO_ROOT}/CLAUDE.md" ]]; then
    log_warn "CLAUDE.md not found in REPO_ROOT. Run 'forgeplan --init' to generate one, or create it manually."
  fi
}
