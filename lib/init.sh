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
    -u "apikey:${OP_API_KEY}" \
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
    -u "apikey:${OP_API_KEY}" \
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
    -u "apikey:${OP_API_KEY}" \
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
    (( ++i )) || true
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

# Suggestions populated by init_claude_suggest_statuses:
#   INIT_SUGGESTIONS[event_name] = 1-based status index
declare -A INIT_SUGGESTIONS

# ---------------------------------------------------------------------------
# init_claude_suggest_statuses
# Ask Claude Code to suggest a status number for each pipeline event based on
# the actual status names fetched from OpenProject. Falls back to empty (no
# suggestion) if Claude is unavailable or returns invalid output.
# ---------------------------------------------------------------------------
init_claude_suggest_statuses() {
  if ! command -v claude > /dev/null 2>&1; then
    return 0
  fi

  echo "Asking Claude to suggest status mappings..."

  # Build a numbered status list for the prompt
  local status_list=""
  local i
  for ((i = 0; i < STATUS_COUNT; i++)); do
    status_list+="$((i + 1)). ${STATUS_NAMES[$i]} (${STATUS_CLOSED[$i]})"$'\n'
  done

  local prompt
  prompt=$(cat <<PROMPT
You are configuring a CI/CD tool called forgeplan that integrates with OpenProject.
It needs to know which status to use for each pipeline event.

Available OpenProject statuses:
${status_list}
Pipeline events to map (return ONLY a JSON object, no explanation):
- pickup_status: tickets that are ready and waiting for forgeplan to start work
- in_progress_status: set while forgeplan is actively generating code
- success_status: set when code generation and build validation both succeed
- partial_status: set when code was generated but the build/validation failed
- failure_status: set when forgeplan produced no output at all (use 0 if none fits)

Return a single JSON object using the 1-based status numbers above, e.g.:
{"pickup_status":3,"in_progress_status":4,"success_status":5,"partial_status":5,"failure_status":0}
PROMPT
)

  local suggestion_json
  suggestion_json=$(claude -p "$prompt" --output-format text --max-turns 1 2>/dev/null \
    | grep -o '{[^}]*}' | head -1)

  if ! echo "$suggestion_json" | jq empty 2>/dev/null; then
    return 0
  fi

  for event in pickup_status in_progress_status success_status partial_status failure_status; do
    local val
    val=$(echo "$suggestion_json" | jq -r --arg e "$event" '.[$e] // empty')
    if [[ "$val" =~ ^[0-9]+$ ]]; then
      INIT_SUGGESTIONS["$event"]="$val"
    fi
  done

  echo "✅ Claude suggested mappings (press Enter on each to accept)"
  echo ""
}

# ---------------------------------------------------------------------------
# init_prompt_mapping <event_name> <label> <hint>
# Prompt user to pick a status. Shows Claude's suggestion as default.
# Press Enter to accept; enter 0 to skip (failure_status only).
# ---------------------------------------------------------------------------
init_prompt_mapping() {
  local event_name="$1"
  local label="$2"
  local hint="$3"

  local allow_none=false
  [[ "$event_name" == "failure_status" ]] && allow_none=true

  local suggested_num="${INIT_SUGGESTIONS[$event_name]:-}"
  # Treat 0 suggestion as "no change" for failure, empty for others
  if [[ "$suggested_num" == "0" ]]; then
    [[ "$allow_none" == "true" ]] && suggested_num="0" || suggested_num=""
  fi

  echo "→ ${label}"
  echo "  (${hint})"

  local prompt_text
  if [[ -n "$suggested_num" ]]; then
    if [[ "$suggested_num" == "0" ]]; then
      echo "  Suggested: no change (skip)"
    else
      printf "  Suggested: %d. %s\n" "$suggested_num" "${STATUS_NAMES[$((suggested_num - 1))]}"
    fi
    if [[ "$allow_none" == "true" ]]; then
      prompt_text="  Enter number [0-${STATUS_COUNT}], or press Enter to accept: "
    else
      prompt_text="  Enter number [1-${STATUS_COUNT}], or press Enter to accept: "
    fi
  else
    if [[ "$allow_none" == "true" ]]; then
      prompt_text="  Enter number [0-${STATUS_COUNT}] (0 = no change): "
    else
      prompt_text="  Enter number [1-${STATUS_COUNT}]: "
    fi
  fi

  local selection
  while true; do
    printf "%s" "$prompt_text"
    read -r selection

    # Accept suggestion on empty input
    if [[ -z "$selection" && -n "$suggested_num" ]]; then
      selection="$suggested_num"
    fi

    # Allow "0 = no change" only for failure_status
    if [[ "$allow_none" == "true" && "$selection" == "0" ]]; then
      INIT_MAP_NAMES["$event_name"]=""
      INIT_MAP_IDS["$event_name"]=""
      echo ""
      return 0
    fi

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || \
       [[ "$selection" -lt 1 || "$selection" -gt "$STATUS_COUNT" ]]; then
      echo "  Please enter a number between 1 and ${STATUS_COUNT}${allow_none:+, or 0 to skip}."
      continue
    fi

    local idx=$((selection - 1))
    INIT_MAP_NAMES["$event_name"]="${STATUS_NAMES[$idx]}"
    INIT_MAP_IDS["$event_name"]="${STATUS_IDS[$idx]}"
    echo ""
    return 0
  done
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
  local merged_ids="{}"
  local i
  for ((i = 0; i < STATUS_COUNT; i++)); do
    merged_ids=$(echo "$merged_ids" | jq \
      --arg name "${STATUS_NAMES[$i]}" \
      --argjson id "${STATUS_IDS[$i]}" \
      '. + {($name): $id}')
  done

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

  # Write config
  init_write_config
}
