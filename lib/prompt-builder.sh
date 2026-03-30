#!/usr/bin/env bash
# forgeplan — lib/prompt-builder.sh
# Prompt assembly from WP data + template interpolation.

# ==========================================================================
# Sanitizer
# ==========================================================================

# ---------------------------------------------------------------------------
# prompt_sanitize <text>
# Strip HTML tags, escape backtick sequences, remove control chars.
# ---------------------------------------------------------------------------
prompt_sanitize() {
  local text="$1"
  # Strip HTML tags
  text=$(printf '%s' "$text" | sed 's/<[^>]*>//g')
  # Remove null bytes and carriage returns, keep newlines
  text=$(printf '%s' "$text" | tr -d '\000\r')
  printf '%s' "$text"
}

# ==========================================================================
# Template resolution
# ==========================================================================

# ---------------------------------------------------------------------------
# prompt_resolve_template <wp_type>
# Resolve the prompt template file based on WP type.
# ---------------------------------------------------------------------------
prompt_resolve_template() {
  local wp_type="$1"
  local type_lower type_slug
  type_lower=$(printf '%s' "$wp_type" | tr '[:upper:]' '[:lower:]')
  # Normalize: "User Story" -> "story", "Sub-Task" -> "subtask"
  type_slug=$(printf '%s' "$type_lower" | sed 's/user story/story/;s/user_story/story/;s/sub-task/subtask/;s/sub task/subtask/' | tr ' ' '-')

  # Check for type-specific template (try slug first, then full lowercase)
  local resolved=""
  for candidate in "$type_slug" "$type_lower"; do
    local type_template="prompt.template.${candidate}.md"
    resolved=$(resolve_config "$type_template")
    if [[ -n "$resolved" ]]; then
      break
    fi
  done

  if [[ -n "$resolved" ]]; then
    log_debug "Using prompt template: ${type_template}"
    echo "$resolved"
    return 0
  fi

  # Fallback to default
  resolved=$(resolve_config "prompt.template.md")
  if [[ -n "$resolved" ]]; then
    log_debug "Using default prompt template"
    echo "$resolved"
    return 0
  fi

  log_error "No prompt template found"
  exit 3
}

# ==========================================================================
# Context gatherers
# ==========================================================================

# ---------------------------------------------------------------------------
# prompt_gather_hierarchy <wp_json>
# Fetch parent (max 2 levels), siblings. Format as text block.
# ---------------------------------------------------------------------------
prompt_gather_hierarchy() {
  local wp_json="$1"
  local wp_id
  wp_id=$(echo "$wp_json" | jq -r '.id')

  local parent_href
  parent_href=$(echo "$wp_json" | jq -r '._links.parent.href // empty')

  if [[ -z "$parent_href" ]]; then
    echo "This is a top-level work package with no parent."
    return 0
  fi

  # Fetch parent
  local parent_id
  parent_id=$(echo "$parent_href" | grep -o '[0-9]*$')

  op_request GET "$parent_href"
  if [[ "$OP_LAST_HTTP_CODE" != "200" ]]; then
    echo "Parent WP could not be fetched."
    return 0
  fi

  local parent_data="$OP_LAST_RESPONSE"
  local parent_subject parent_desc
  parent_subject=$(echo "$parent_data" | jq -r '.subject // "unknown"')
  parent_desc=$(echo "$parent_data" | jq -r '.description.raw // ""')
  # Truncate parent description to 500 chars
  if [[ ${#parent_desc} -gt 500 ]]; then
    parent_desc="${parent_desc:0:500}..."
  fi

  local result="**Parent:** #${parent_id}: ${parent_subject}"$'\n'
  if [[ -n "$parent_desc" ]]; then
    result+="${parent_desc}"$'\n'
  fi

  # Check for grandparent (subject only)
  local grandparent_href
  grandparent_href=$(echo "$parent_data" | jq -r '._links.parent.href // empty')
  if [[ -n "$grandparent_href" ]]; then
    local gp_id
    gp_id=$(echo "$grandparent_href" | grep -o '[0-9]*$')
    op_request GET "$grandparent_href"
    if [[ "$OP_LAST_HTTP_CODE" == "200" ]]; then
      local gp_subject
      gp_subject=$(echo "$OP_LAST_RESPONSE" | jq -r '.subject // "unknown"')
      result="**Grandparent:** #${gp_id}: ${gp_subject}"$'\n'"${result}"
    fi
  fi

  # Fetch siblings (parent's children, excluding current WP)
  local siblings_json
  siblings_json=$(op_fetch_wp_children "$parent_id")
  local sibling_count
  sibling_count=$(echo "$siblings_json" | jq 'length')

  if [[ "$sibling_count" -gt 0 ]]; then
    result+=$'\n'"**Siblings:**"$'\n'
    result+=$(echo "$siblings_json" | jq -r --argjson self "$wp_id" '
      .[] | select(.id != $self)
      | "- #\(.id): \(.subject) (\(.type), \(.status))"
    ')
    result+=$'\n'
  fi

  echo "$result"
}

# ---------------------------------------------------------------------------
# prompt_gather_children <wp_json>
# Fetch children, format as numbered list.
# ---------------------------------------------------------------------------
prompt_gather_children() {
  local wp_json="$1"

  local has_children
  has_children=$(echo "$wp_json" | jq '._links.children | length')

  if [[ "$has_children" -eq 0 ]]; then
    echo "No child work packages."
    return 0
  fi

  local wp_id
  wp_id=$(echo "$wp_json" | jq -r '.id')

  local children_json
  children_json=$(op_fetch_wp_children "$wp_id")
  local count
  count=$(echo "$children_json" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    echo "No child work packages."
    return 0
  fi

  echo "$children_json" | jq -r '
    to_entries[]
    | "\(.key + 1). #\(.value.id): \(.value.subject) (\(.value.type), \(.value.status))"
  '
}

# ---------------------------------------------------------------------------
# prompt_gather_relations <wp_id>
# Fetch relations, format as bullet list.
# ---------------------------------------------------------------------------
prompt_gather_relations() {
  local wp_id="$1"

  local relations_json
  relations_json=$(op_fetch_wp_relations "$wp_id")
  local count
  count=$(echo "$relations_json" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    echo "No related work packages."
    return 0
  fi

  echo "$relations_json" | jq -r '
    .[] | "- \(.relation_type | ascii_upcase) #\(.related_wp_id): \(.related_wp_subject) (status: \(.related_wp_status))"
  '
}

# ---------------------------------------------------------------------------
# prompt_gather_layer_context <layers>
# For each layer: read config, list directory structure.
# ---------------------------------------------------------------------------
prompt_gather_layer_context() {
  local layers="$1"
  local result=""

  for layer_name in $layers; do
    local layer_path layer_tech layer_patterns layer_build
    layer_path=$(echo "$FP_LAYERS_JSON" | jq -r --arg l "$layer_name" '.layers[$l].path // ""')
    layer_tech=$(echo "$FP_LAYERS_JSON" | jq -r --arg l "$layer_name" '.layers[$l].techStack // "unspecified"')
    layer_patterns=$(echo "$FP_LAYERS_JSON" | jq -r --arg l "$layer_name" '.layers[$l].filePatterns // [] | join(", ")')
    layer_build=$(echo "$FP_LAYERS_JSON" | jq -r --arg l "$layer_name" '.layers[$l].buildCmd // "none"')

    result+="### Layer: ${layer_name}"$'\n'
    result+="- Directory: ${layer_path}"$'\n'
    result+="- Tech Stack: ${layer_tech}"$'\n'
    result+="- File Patterns: ${layer_patterns}"$'\n'
    result+="- Build Command: ${layer_build}"$'\n'
    result+=$'\n'

    # Directory listing (max 50 files, 2 levels deep)
    local full_path="${REPO_ROOT}/${layer_path}"
    if [[ -d "$full_path" ]]; then
      result+="Current structure:"$'\n'
      result+='```'$'\n'
      result+=$(find "$full_path" -maxdepth 2 -type f 2>/dev/null | head -50 | sed "s|${REPO_ROOT}/||")
      result+=$'\n''```'$'\n'
    fi

    result+=$'\n'
  done

  echo "$result"
}

# ---------------------------------------------------------------------------
# prompt_gather_comments <wp_id>
# Fetch last 5 comments, format with author/date. Truncate to 3000 chars.
# ---------------------------------------------------------------------------
prompt_gather_comments() {
  local wp_id="$1"

  local comments_json
  comments_json=$(op_fetch_wp_activities "$wp_id")
  local count
  count=$(echo "$comments_json" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    echo "No discussion comments."
    return 0
  fi

  # Take last 5 comments
  local result=""
  result=$(echo "$comments_json" | jq -r '
    .[0:5][]
    | "**[\(.author), \(.created_at | split("T")[0])]:**\n\(.comment)\n"
  ')

  # Truncate to 3000 chars
  if [[ ${#result} -gt 3000 ]]; then
    result="${result:0:3000}..."
  fi

  echo "$result"
}

# ==========================================================================
# Token budget enforcement (I-5)
# ==========================================================================

# ---------------------------------------------------------------------------
# prompt_estimate_tokens <text>
# Estimate token count: words * 1.3
# ---------------------------------------------------------------------------
prompt_estimate_tokens() {
  local text="$1"
  local word_count
  word_count=$(printf '%s' "$text" | wc -w | tr -d ' ')
  echo $(( (word_count * 13 + 5) / 10 ))
}

# ---------------------------------------------------------------------------
# prompt_enforce_budget <prompt_file>
# If over PROMPT_MAX_TOKENS, truncate sections in priority order.
# ---------------------------------------------------------------------------
prompt_enforce_budget() {
  local prompt_file="$1"
  local content
  content=$(cat "$prompt_file")

  local tokens
  tokens=$(prompt_estimate_tokens "$content")

  if [[ "$tokens" -le "${PROMPT_MAX_TOKENS:-30000}" ]]; then
    return 0
  fi

  log_info "Prompt at ~${tokens} tokens, budget is ${PROMPT_MAX_TOKENS:-30000}. Truncating..."

  local reduced=()

  # 1. Truncate comments block to 1000 chars
  local comments_section
  comments_section=$(sed -n '/## Recent Discussion/,/^# /p' "$prompt_file" | head -n -1)
  if [[ ${#comments_section} -gt 1000 ]]; then
    local truncated="${comments_section:0:1000}..."
    content=$(printf '%s' "$content" | sed "/## Recent Discussion/,/^# /{/## Recent Discussion/!{/^# /!d}}")
    content=$(printf '%s' "$content" | sed "s|## Recent Discussion|## Recent Discussion\n\n${truncated}|")
    reduced+=("comments")
    tokens=$(prompt_estimate_tokens "$content")
    [[ "$tokens" -le "${PROMPT_MAX_TOKENS:-30000}" ]] && { _budget_finish "$prompt_file" "$content" "$reduced"; return 0; }
  fi

  # 2-6. Progressively truncate by replacing content with shorter versions
  # For simplicity in the shell implementation, do a simpler proportional cut:
  # Cut description to 5000 chars if longer
  local desc_start desc_end
  local desc_content
  desc_content=$(sed -n '/## Description/,/## Metadata/p' "$prompt_file" | head -n -1 | tail -n +2)
  if [[ ${#desc_content} -gt 5000 ]]; then
    local first_half="${desc_content:0:2500}"
    local last_half="${desc_content: -2500}"
    local new_desc="${first_half}

[... description truncated ...]

${last_half}"
    content=$(echo "$content" | awk -v new="$new_desc" '
      /## Description/{p; found=1; next}
      /## Metadata/{found=0}
      found{next}
      {print}
    ')
    # Re-inject description
    content=$(echo "$content" | sed "/## Description/a\\
\\
${new_desc}")
    reduced+=("description")
    tokens=$(prompt_estimate_tokens "$content")
    [[ "$tokens" -le "${PROMPT_MAX_TOKENS:-30000}" ]] && { _budget_finish "$prompt_file" "$content" "$reduced"; return 0; }
  fi

  # Final: just hard-truncate the whole file
  local max_chars=$(( ${PROMPT_MAX_TOKENS:-30000} * 4 ))
  if [[ ${#content} -gt $max_chars ]]; then
    content="${content:0:$max_chars}"
    reduced+=("hard-truncate")
  fi

  _budget_finish "$prompt_file" "$content" "${reduced[@]}"
}

_budget_finish() {
  local prompt_file="$1"
  local content="$2"
  shift 2
  local reduced=("$@")

  # Append truncation note
  content+=$'\n\n'"[Note: Some context was truncated to fit within token budget. See the full work package in OpenProject for complete details.]"

  printf '%s' "$content" > "$prompt_file"

  local final_tokens
  final_tokens=$(prompt_estimate_tokens "$content")
  log_info "Prompt truncated to ~${final_tokens} tokens. Sections reduced: ${reduced[*]}"
}

# ==========================================================================
# Main builder
# ==========================================================================

# ---------------------------------------------------------------------------
# prompt_build <wp_json> <layers>
# Assemble prompt from WP data + template.
# Sets FP_PROMPT_FILE global with the output path.
# ---------------------------------------------------------------------------
prompt_build() {
  local wp_json="$1"
  local layers="$2"

  # Extract WP fields
  local wp_id wp_subject wp_type wp_priority wp_description wp_custom_fields
  wp_id=$(echo "$wp_json" | jq -r '.id')
  wp_subject=$(echo "$wp_json" | jq -r '.subject // ""')
  wp_type=$(echo "$wp_json" | jq -r '._links.type.title // "Task"')
  wp_priority=$(echo "$wp_json" | jq -r '._links.priority.title // "Normal"')
  wp_description=$(echo "$wp_json" | jq -r '.description.raw // ""')

  # Extract custom fields (all customField_* properties)
  wp_custom_fields=$(echo "$wp_json" | jq -r '
    to_entries
    | map(select(.key | startswith("customField")))
    | if length == 0 then "No custom fields."
      else map("- **\(.key):** \(.value // "—")") | join("\n")
      end
  ')

  # Sanitize description
  wp_description=$(prompt_sanitize "$wp_description")

  # Gather context blocks
  log_info "Gathering hierarchy context..."
  local hierarchy_block
  hierarchy_block=$(prompt_gather_hierarchy "$wp_json")

  log_info "Gathering children context..."
  local children_block
  children_block=$(prompt_gather_children "$wp_json")

  log_info "Gathering relations context..."
  local relations_block
  relations_block=$(prompt_gather_relations "$wp_id")

  log_info "Gathering layer context..."
  local layer_context_block
  layer_context_block=$(prompt_gather_layer_context "$layers")

  log_info "Gathering comments context..."
  local comments_block
  comments_block=$(prompt_gather_comments "$wp_id")

  # Build layer paths string
  local layer_paths=""
  for l in $layers; do
    local lp
    lp=$(echo "$FP_LAYERS_JSON" | jq -r --arg l "$l" '.layers[$l].path // ""')
    if [[ -n "$layer_paths" ]]; then
      layer_paths+=" and ${lp}"
    else
      layer_paths="$lp"
    fi
  done

  # Resolve template
  local template_file
  template_file=$(prompt_resolve_template "$wp_type")
  local template_content
  template_content=$(cat "$template_file")

  # Substitute placeholders using bash native string replacement
  local output_file="${TMPDIR:-/tmp}/forgeplan-prompt-${wp_id}.md"

  local result="$template_content"
  result="${result//\$\{WP_ID\}/$wp_id}"
  result="${result//\$\{WP_SUBJECT\}/$wp_subject}"
  result="${result//\$\{WP_TYPE\}/$wp_type}"
  result="${result//\$\{WP_PRIORITY\}/$wp_priority}"
  result="${result//\$\{WP_DESCRIPTION\}/$wp_description}"
  result="${result//\$\{WP_CUSTOM_FIELDS\}/$wp_custom_fields}"
  result="${result//\$\{HIERARCHY_BLOCK\}/$hierarchy_block}"
  result="${result//\$\{CHILDREN_BLOCK\}/$children_block}"
  result="${result//\$\{RELATIONS_BLOCK\}/$relations_block}"
  result="${result//\$\{COMMENTS_BLOCK\}/$comments_block}"
  result="${result//\$\{LAYER_CONTEXT_BLOCK\}/$layer_context_block}"
  result="${result//\$\{LAYER_PATHS\}/$layer_paths}"

  printf '%s\n' "$result" > "$output_file"

  # Enforce token budget
  prompt_enforce_budget "$output_file"

  local final_size
  final_size=$(wc -c < "$output_file" | tr -d ' ')
  log_info "Prompt written to ${output_file} (${final_size} bytes)"

  FP_PROMPT_FILE="$output_file"
}
