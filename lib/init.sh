#!/usr/bin/env bash
# forgeplan — lib/init.sh
# Interactive setup, status discovery, --init flow.

# Internal arrays populated by init_discover_statuses:
#   STATUS_NAMES[], STATUS_IDS[], STATUS_CLOSED[], STATUS_COUNT

# Mapping results populated by init_prompt_mapping:
declare -A INIT_MAP_NAMES  # event_name -> status_name
declare -A INIT_MAP_IDS    # event_name -> status_id

# ---------------------------------------------------------------------------
# init_validate_connection
# Test API connectivity and authentication.
# ---------------------------------------------------------------------------
init_validate_connection() {
  local tmp_body tmp_code
  tmp_body=$(mktemp)
  trap "rm -f '$tmp_body'" RETURN

  tmp_code=$(curl --fail-with-body --silent --show-error --max-time 15 \
    -w '%{http_code}' \
    -o "$tmp_body" \
    -H "Authorization: Bearer ${OP_API_KEY}" \
    -H "Accept: application/hal+json" \
    "${OP_BASE_URL}/api/v3" 2>/dev/null) || true

  if [[ "$tmp_code" == "000" ]]; then
    echo "ERROR: Cannot reach ${OP_BASE_URL}. Verify openproject.url in forgeplan.config.json" >&2
    exit 5
  fi

  if [[ "$tmp_code" == "401" ]]; then
    echo "ERROR: Authentication failed. Verify OP_API_KEY in .env or re-run forgeplan --init" >&2
    exit 5
  fi

  if [[ "$tmp_code" != "200" ]]; then
    echo "ERROR: Unexpected response (HTTP ${tmp_code}) from ${OP_BASE_URL}/api/v3" >&2
    exit 5
  fi

  local version
  version=$(jq -r '.coreVersion // "unknown"' "$tmp_body")
  echo "✅ Connected to OpenProject ${version} at ${OP_BASE_URL}"
}

# ---------------------------------------------------------------------------
# init_validate_project
# Verify the configured project exists and is accessible.
# ---------------------------------------------------------------------------
init_validate_project() {
  local tmp_body tmp_code
  tmp_body=$(mktemp)
  trap "rm -f '$tmp_body'" RETURN

  tmp_code=$(curl --fail-with-body --silent --show-error --max-time 15 \
    -w '%{http_code}' \
    -o "$tmp_body" \
    -H "Authorization: Bearer ${OP_API_KEY}" \
    -H "Accept: application/hal+json" \
    "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}" 2>/dev/null) || true

  if [[ "$tmp_code" == "404" ]]; then
    echo "ERROR: Project '${OP_PROJECT_ID}' not found. Verify openproject.projectId in forgeplan.config.json" >&2
    exit 5
  fi

  if [[ "$tmp_code" == "403" ]]; then
    echo "ERROR: No access to project '${OP_PROJECT_ID}'. Check API key permissions." >&2
    exit 5
  fi

  if [[ "$tmp_code" != "200" ]]; then
    echo "ERROR: Unexpected response (HTTP ${tmp_code}) fetching project '${OP_PROJECT_ID}'" >&2
    exit 5
  fi

  local project_name
  project_name=$(jq -r '.name // "unknown"' "$tmp_body")
  echo "✅ Project found: ${project_name}"
}

# ---------------------------------------------------------------------------
# init_discover_statuses
# Fetch all statuses from OpenProject and store in indexed arrays.
# ---------------------------------------------------------------------------
init_discover_statuses() {
  local tmp_body tmp_code
  tmp_body=$(mktemp)
  trap "rm -f '$tmp_body'" RETURN

  tmp_code=$(curl --fail-with-body --silent --show-error --max-time 15 \
    -w '%{http_code}' \
    -o "$tmp_body" \
    -H "Authorization: Bearer ${OP_API_KEY}" \
    -H "Accept: application/hal+json" \
    "${OP_BASE_URL}/api/v3/statuses" 2>/dev/null) || true

  if [[ "$tmp_code" != "200" ]]; then
    echo "ERROR: Failed to fetch statuses (HTTP ${tmp_code})" >&2
    exit 5
  fi

  # Parse statuses sorted by position
  STATUS_COUNT=$(jq '[._embedded.elements[]] | sort_by(.position) | length' "$tmp_body")

  if [[ "$STATUS_COUNT" -eq 0 ]]; then
    echo "ERROR: No statuses found in OpenProject instance" >&2
    exit 5
  fi

  local i=0
  while IFS=$'\t' read -r id name is_closed; do
    STATUS_IDS[$i]="$id"
    STATUS_NAMES[$i]="$name"
    STATUS_CLOSED[$i]="$is_closed"
    ((i++))
  done < <(jq -r '
    [._embedded.elements[]] | sort_by(.position)
    | .[] | [(.id|tostring), .name, (if .isClosed then "closed" else "open" end)]
    | @tsv
  ' "$tmp_body")
}

# ---------------------------------------------------------------------------
# init_display_statuses
# Print numbered list of discovered statuses.
# ---------------------------------------------------------------------------
init_display_statuses() {
  echo ""
  echo "Available statuses:"
  local i
  for ((i = 0; i < STATUS_COUNT; i++)); do
    printf "  %2d. %s (%s)\n" "$((i + 1))" "${STATUS_NAMES[$i]}" "${STATUS_CLOSED[$i]}"
  done
  echo ""
}

# ---------------------------------------------------------------------------
# init_prompt_mapping <event_name> <description>
# Prompt user to select a status for a pipeline event.
# ---------------------------------------------------------------------------
init_prompt_mapping() {
  local event_name="$1"
  local description="$2"
  local allow_none=false
  local min_val=1

  if [[ "$event_name" == "failure_status" ]]; then
    allow_none=true
    min_val=0
  fi

  echo "$description"
  local prompt_text
  if [[ "$allow_none" == "true" ]]; then
    prompt_text="Select status number [0-${STATUS_COUNT}], 0=no change: "
  else
    prompt_text="Select status number [1-${STATUS_COUNT}]: "
  fi

  local attempts=0
  local selection
  while [[ $attempts -lt 3 ]]; do
    printf "%s" "$prompt_text"
    read -r selection

    # Validate numeric
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
      echo "Invalid input. Please enter a number."
      ((attempts++))
      continue
    fi

    # Validate range
    if [[ "$selection" -lt "$min_val" || "$selection" -gt "$STATUS_COUNT" ]]; then
      echo "Out of range. Please enter ${min_val}-${STATUS_COUNT}."
      ((attempts++))
      continue
    fi

    # Handle "no change" for failure_status
    if [[ "$selection" -eq 0 ]]; then
      INIT_MAP_NAMES["$event_name"]=""
      INIT_MAP_IDS["$event_name"]=""
      return 0
    fi

    # Map 1-based selection to 0-based index
    local idx=$((selection - 1))
    INIT_MAP_NAMES["$event_name"]="${STATUS_NAMES[$idx]}"
    INIT_MAP_IDS["$event_name"]="${STATUS_IDS[$idx]}"
    return 0
  done

  echo "ERROR: Too many invalid attempts. Aborting." >&2
  exit 3
}

# ---------------------------------------------------------------------------
# init_write_config
# Merge status mappings into forgeplan.config.json under "statuses" key.
# ---------------------------------------------------------------------------
init_write_config() {
  local config_file
  config_file=$(resolve_config "forgeplan.config.json")

  if [[ -z "$config_file" || ! -f "$config_file" ]]; then
    echo "ERROR: forgeplan.config.json not found. Run forgeplan --init first." >&2
    exit 3
  fi

  # Build the _status_ids object from all discovered statuses
  local ids_json="{"
  local i
  for ((i = 0; i < STATUS_COUNT; i++)); do
    [[ $i -gt 0 ]] && ids_json+=","
    ids_json+="$(jq -n --arg name "${STATUS_NAMES[$i]}" --argjson id "${STATUS_IDS[$i]}" '{($name): $id}' | jq -c '.')"
  done
  ids_json="}"

  # Merge individual objects into one
  local merged_ids
  merged_ids=$(printf '%s' "$ids_json" | sed 's/}{/,/g')

  # Build failure_status value (null or string)
  local failure_val="null"
  if [[ -n "${INIT_MAP_NAMES[failure_status]:-}" ]]; then
    failure_val="\"${INIT_MAP_NAMES[failure_status]}\""
  fi

  # Build statuses object
  local statuses_obj
  statuses_obj=$(jq -n \
    --arg pickup "${INIT_MAP_NAMES[pickup_status]}" \
    --arg in_progress "${INIT_MAP_NAMES[in_progress_status]}" \
    --arg success "${INIT_MAP_NAMES[success_status]}" \
    --arg partial "${INIT_MAP_NAMES[partial_status]}" \
    --argjson failure "$failure_val" \
    --argjson ids "$merged_ids" \
    '{
      pickup_status: $pickup,
      in_progress_status: $in_progress,
      success_status: $success,
      partial_status: $partial,
      failure_status: $failure,
      _status_ids: $ids
    }')

  # Merge into existing config.json
  local tmp_config
  tmp_config=$(mktemp)
  jq --argjson statuses "$statuses_obj" '. + {statuses: $statuses}' "$config_file" > "$tmp_config"
  mv "$tmp_config" "$config_file"

  echo ""
  echo "✅ Status mapping saved to forgeplan.config.json"
  printf "   %-20s → %s\n" "pickup_status" "${INIT_MAP_NAMES[pickup_status]}"
  printf "   %-20s → %s\n" "in_progress_status" "${INIT_MAP_NAMES[in_progress_status]}"
  printf "   %-20s → %s\n" "success_status" "${INIT_MAP_NAMES[success_status]}"
  printf "   %-20s → %s\n" "partial_status" "${INIT_MAP_NAMES[partial_status]}"
  if [[ -n "${INIT_MAP_NAMES[failure_status]:-}" ]]; then
    printf "   %-20s → %s\n" "failure_status" "${INIT_MAP_NAMES[failure_status]}"
  else
    printf "   %-20s → %s\n" "failure_status" "(no change)"
  fi
}

# ---------------------------------------------------------------------------
# init_run
# Main entry point for --init. Orchestrates full setup flow.
# ---------------------------------------------------------------------------
init_run() {
  echo "forgeplan — Interactive Setup"
  echo "============================="
  echo ""

  # Check for existing status mapping in config.json
  local existing_config
  existing_config=$(resolve_config "forgeplan.config.json")
  if [[ -n "$existing_config" ]] && jq -e '.statuses' "$existing_config" > /dev/null 2>&1; then
    printf "Status mapping already exists in forgeplan.config.json. Overwrite? [y/N] "
    local answer
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi
    echo ""
  fi

  # Validate connection and project
  init_validate_connection
  init_validate_project

  # Discover statuses
  echo ""
  echo "Discovering statuses..."
  init_discover_statuses
  init_display_statuses

  # Prompt for each pipeline event
  init_prompt_mapping "pickup_status" \
    "Which status marks a WP as ready for code generation? (used by --queue to find work)"

  init_prompt_mapping "in_progress_status" \
    "Which status should be set when the tool starts processing a WP?"

  init_prompt_mapping "success_status" \
    "Which status should be set when code generation and validation both pass?"

  init_prompt_mapping "partial_status" \
    "Which status should be set when code is generated but validation fails?"

  init_prompt_mapping "failure_status" \
    "Which status should be set when generation produces no output? (enter 0 for no change)"

  # Write config
  init_write_config
}
