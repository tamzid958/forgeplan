#!/usr/bin/env bash
# forgeplan — lib/openproject.sh
# OpenProject API v3 client: fetch, patch, comment.

# Globals set by this module:
#   OP_LAST_HTTP_CODE  — HTTP status code from the last op_request call
#   OP_LAST_RESPONSE   — response body from the last op_request call
#   WP_LOCK_VERSIONS   — associative array: wp_id -> lockVersion

declare -A WP_LOCK_VERSIONS
OP_LAST_HTTP_CODE=""
OP_LAST_RESPONSE=""

# ==========================================================================
# Internal helpers
# ==========================================================================

# ---------------------------------------------------------------------------
# op_request <method> <path> [body]
# Execute an HTTP request against the OpenProject API.
# Sets OP_LAST_HTTP_CODE and OP_LAST_RESPONSE globals.
# ---------------------------------------------------------------------------
op_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local url="${OP_BASE_URL}${path}"
  local tmp_body
  tmp_body=$(mktemp)

  local curl_args=(
    --silent --show-error --max-time 30
    -w '%{http_code}'
    -o "$tmp_body"
    -u "apikey:${OP_API_KEY}"
    -H "Content-Type: application/json"
    -H "Accept: application/hal+json"
    -X "$method"
  )

  if [[ -n "$body" && ( "$method" == "PATCH" || "$method" == "POST" || "$method" == "PUT" ) ]]; then
    curl_args+=(--data "$body")
  fi

  log_debug "OP API ${method} ${path} (body: ${#body} bytes)"

  OP_LAST_HTTP_CODE=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || true
  OP_LAST_RESPONSE=$(cat "$tmp_body")

  log_debug "OP API response: HTTP ${OP_LAST_HTTP_CODE} (body: ${#OP_LAST_RESPONSE} bytes)"

  rm -f "$tmp_body"
}

# ---------------------------------------------------------------------------
# op_handle_error <http_code> <response_body> <context_message>
# Map HTTP error codes to human-readable messages. Logs and returns message.
# ---------------------------------------------------------------------------
op_handle_error() {
  local http_code="$1"
  local response_body="$2"
  local context="$3"

  local op_message
  op_message=$(echo "$response_body" | jq -r '.message // empty' 2>/dev/null)

  local error_msg
  case "$http_code" in
    401) error_msg="Authentication failed. Check OP_API_KEY." ;;
    403) error_msg="Permission denied. Check API key permissions for this action." ;;
    404) error_msg="Resource not found." ;;
    409) error_msg="Update conflict. Resource was modified by another user." ;;
    422) error_msg="Validation error: ${op_message:-unknown}" ;;
    *)   error_msg="Unexpected error ${http_code}: ${op_message:-no details}" ;;
  esac

  log_error "${context}: ${error_msg}"
  echo "$error_msg"
}

# ==========================================================================
# Public API — Fetch functions
# ==========================================================================

# ---------------------------------------------------------------------------
# op_fetch_wp <wp_id>
# Fetch a single work package. Caches lockVersion. Exits 5 on error.
# Returns JSON via stdout.
# ---------------------------------------------------------------------------
op_fetch_wp() {
  local wp_id="$1"

  op_request GET "/api/v3/work_packages/${wp_id}"

  if [[ "$OP_LAST_HTTP_CODE" != "200" ]]; then
    op_handle_error "$OP_LAST_HTTP_CODE" "$OP_LAST_RESPONSE" "Fetching WP #${wp_id}" >/dev/null
    exit 5
  fi

  # Cache lockVersion
  local lock_version
  lock_version=$(echo "$OP_LAST_RESPONSE" | jq -r '.lockVersion // empty')
  if [[ -n "$lock_version" ]]; then
    WP_LOCK_VERSIONS["$wp_id"]="$lock_version"
  fi

  echo "$OP_LAST_RESPONSE"
}

# ---------------------------------------------------------------------------
# op_fetch_wp_children <wp_id>
# Fetch all child WPs. Returns JSON array of child objects.
# ---------------------------------------------------------------------------
op_fetch_wp_children() {
  local wp_id="$1"

  local wp_json
  wp_json=$(op_fetch_wp "$wp_id")

  # Extract children hrefs
  local children_hrefs
  children_hrefs=$(echo "$wp_json" | jq -r '._links.children[]?.href // empty' 2>/dev/null)

  if [[ -z "$children_hrefs" ]]; then
    echo "[]"
    return 0
  fi

  # Fetch each child
  local results="["
  local first=true
  while IFS= read -r href; do
    [[ -z "$href" ]] && continue

    op_request GET "$href"

    if [[ "$OP_LAST_HTTP_CODE" == "200" ]]; then
      local child_obj
      child_obj=$(echo "$OP_LAST_RESPONSE" | jq -c '{
        id: .id,
        subject: .subject,
        type: ._links.type.title,
        status: ._links.status.title
      }')

      if [[ "$first" == "true" ]]; then
        first=false
      else
        results+=","
      fi
      results+="$child_obj"
    fi
  done <<< "$children_hrefs"

  results+="]"
  echo "$results"
}

# ---------------------------------------------------------------------------
# op_fetch_wp_relations <wp_id>
# Fetch all relations for a WP. Returns JSON array of relation objects.
# ---------------------------------------------------------------------------
op_fetch_wp_relations() {
  local wp_id="$1"

  op_request GET "/api/v3/work_packages/${wp_id}/relations"

  if [[ "$OP_LAST_HTTP_CODE" != "200" ]]; then
    echo "[]"
    return 0
  fi

  local relations_data="$OP_LAST_RESPONSE"
  local elements_count
  elements_count=$(echo "$relations_data" | jq '._embedded.elements | length')

  if [[ "$elements_count" -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  # Process each relation
  local results="["
  local first=true
  local i
  for ((i = 0; i < elements_count; i++)); do
    local rel_type from_href to_href
    rel_type=$(echo "$relations_data" | jq -r "._embedded.elements[$i].type")
    from_href=$(echo "$relations_data" | jq -r "._embedded.elements[$i]._links.from.href")
    to_href=$(echo "$relations_data" | jq -r "._embedded.elements[$i]._links.to.href")

    # Determine which is the "other" WP
    local related_href
    if [[ "$from_href" == *"/work_packages/${wp_id}" ]]; then
      related_href="$to_href"
    else
      related_href="$from_href"
    fi

    # Extract related WP ID from href
    local related_wp_id
    related_wp_id=$(echo "$related_href" | grep -o '[0-9]*$')

    # Fetch related WP for subject and status
    op_request GET "$related_href"

    local related_subject related_status
    if [[ "$OP_LAST_HTTP_CODE" == "200" ]]; then
      related_subject=$(echo "$OP_LAST_RESPONSE" | jq -r '.subject // "unknown"')
      related_status=$(echo "$OP_LAST_RESPONSE" | jq -r '._links.status.title // "unknown"')
    else
      related_subject="unknown"
      related_status="unknown"
    fi

    local rel_obj
    rel_obj=$(jq -n -c \
      --arg relation_type "$rel_type" \
      --argjson related_wp_id "$related_wp_id" \
      --arg related_wp_subject "$related_subject" \
      --arg related_wp_status "$related_status" \
      '{
        relation_type: $relation_type,
        related_wp_id: $related_wp_id,
        related_wp_subject: $related_wp_subject,
        related_wp_status: $related_wp_status
      }')

    if [[ "$first" == "true" ]]; then
      first=false
    else
      results+=","
    fi
    results+="$rel_obj"
  done

  results+="]"
  echo "$results"
}

# ---------------------------------------------------------------------------
# op_fetch_wp_activities <wp_id>
# Fetch comments (activities with non-empty comment.raw). Returns JSON array.
# ---------------------------------------------------------------------------
op_fetch_wp_activities() {
  local wp_id="$1"

  op_request GET "/api/v3/work_packages/${wp_id}/activities"

  if [[ "$OP_LAST_HTTP_CODE" != "200" ]]; then
    echo "[]"
    return 0
  fi

  echo "$OP_LAST_RESPONSE" | jq -c '[
    ._embedded.elements[]
    | select(.comment.raw != null and .comment.raw != "")
    | {
        comment: .comment.raw,
        author: ._links.user.title,
        created_at: .createdAt
      }
  ] | sort_by(.created_at) | reverse'
}

# ---------------------------------------------------------------------------
# op_fetch_wp_attachments <wp_id>
# Fetch attachment metadata. Returns JSON array (no file download).
# ---------------------------------------------------------------------------
op_fetch_wp_attachments() {
  local wp_id="$1"

  op_request GET "/api/v3/work_packages/${wp_id}/attachments"

  if [[ "$OP_LAST_HTTP_CODE" != "200" ]]; then
    echo "[]"
    return 0
  fi

  echo "$OP_LAST_RESPONSE" | jq -c '[
    ._embedded.elements[]
    | {
        fileName: .fileName,
        contentType: .contentType,
        fileSize: .fileSize,
        downloadUrl: ._links.downloadLocation.href
      }
  ]'
}

# ==========================================================================
# Public API — Query functions
# ==========================================================================

# ---------------------------------------------------------------------------
# op_query_wps_by_status <status_id> [sort_by]
# Find all WPs in the project matching a status. Returns space-separated IDs.
# ---------------------------------------------------------------------------
op_query_wps_by_status() {
  local status_id="$1"
  local sort_by="${2:-}"

  # Build filter
  local filters
  filters=$(jq -n -c --arg sid "$status_id" \
    '[{"status":{"operator":"=","values":[$sid]}}]')

  # Build sort
  local sort_json
  if [[ -n "$sort_by" ]]; then
    sort_json="$sort_by"
  else
    sort_json='[["priority","desc"],["id","asc"]]'
  fi

  # URL-encode parameters
  local encoded_filters encoded_sort
  encoded_filters=$(printf '%s' "$filters" | jq -sRr @uri)
  encoded_sort=$(printf '%s' "$sort_json" | jq -sRr @uri)

  local all_ids=""
  local offset=1
  local page_size=100

  while true; do
    local path="/api/v3/projects/${OP_PROJECT_ID}/work_packages?filters=${encoded_filters}&sortBy=${encoded_sort}&pageSize=${page_size}&offset=${offset}"

    op_request GET "$path"

    if [[ "$OP_LAST_HTTP_CODE" != "200" ]]; then
      op_handle_error "$OP_LAST_HTTP_CODE" "$OP_LAST_RESPONSE" "Querying WPs by status" >/dev/null
      break
    fi

    # Extract IDs from this page
    local page_ids
    page_ids=$(echo "$OP_LAST_RESPONSE" | jq -r '._embedded.elements[].id')

    if [[ -n "$page_ids" ]]; then
      if [[ -n "$all_ids" ]]; then
        all_ids+=$'\n'"$page_ids"
      else
        all_ids="$page_ids"
      fi
    fi

    # Check if there are more pages
    local total count
    total=$(echo "$OP_LAST_RESPONSE" | jq '.total')
    count=$(echo "$OP_LAST_RESPONSE" | jq '._embedded.elements | length')

    if [[ $((offset + count - 1)) -ge "$total" ]]; then
      break
    fi

    offset=$((offset + count))
  done

  # Return as space-separated list
  echo "$all_ids" | tr '\n' ' ' | sed 's/ $//'
}

# ==========================================================================
# Public API — Write functions
# ==========================================================================

# ---------------------------------------------------------------------------
# op_update_wp_status <wp_id> <status_id>
# PATCH work package status. Handles lockVersion conflicts with one retry.
# Returns 0 on success, 1 on failure (non-fatal).
# ---------------------------------------------------------------------------
op_update_wp_status() {
  local wp_id="$1"
  local status_id="$2"

  # Get cached lockVersion or fetch fresh
  local lock_version="${WP_LOCK_VERSIONS[$wp_id]:-}"
  if [[ -z "$lock_version" ]]; then
    op_fetch_wp "$wp_id" > /dev/null
    lock_version="${WP_LOCK_VERSIONS[$wp_id]:-}"
    if [[ -z "$lock_version" ]]; then
      log_error "Cannot determine lockVersion for WP #${wp_id}"
      return 1
    fi
  fi

  local body
  body=$(jq -n -c \
    --argjson lv "$lock_version" \
    --arg sid "/api/v3/statuses/${status_id}" \
    '{lockVersion: $lv, _links: {status: {href: $sid}}}')

  op_request PATCH "/api/v3/work_packages/${wp_id}" "$body"

  # Success
  if [[ "$OP_LAST_HTTP_CODE" == "200" ]]; then
    local new_lock
    new_lock=$(echo "$OP_LAST_RESPONSE" | jq -r '.lockVersion // empty')
    if [[ -n "$new_lock" ]]; then
      WP_LOCK_VERSIONS["$wp_id"]="$new_lock"
    fi
    log_info "Status updated for WP #${wp_id}"
    return 0
  fi

  # Conflict — retry once with fresh lockVersion
  if [[ "$OP_LAST_HTTP_CODE" == "409" ]]; then
    log_warn "Lock conflict on WP #${wp_id}. Refreshing lockVersion and retrying..."

    op_fetch_wp "$wp_id" > /dev/null
    lock_version="${WP_LOCK_VERSIONS[$wp_id]:-}"

    body=$(jq -n -c \
      --argjson lv "$lock_version" \
      --arg sid "/api/v3/statuses/${status_id}" \
      '{lockVersion: $lv, _links: {status: {href: $sid}}}')

    op_request PATCH "/api/v3/work_packages/${wp_id}" "$body"

    if [[ "$OP_LAST_HTTP_CODE" == "200" ]]; then
      local new_lock
      new_lock=$(echo "$OP_LAST_RESPONSE" | jq -r '.lockVersion // empty')
      if [[ -n "$new_lock" ]]; then
        WP_LOCK_VERSIONS["$wp_id"]="$new_lock"
      fi
      log_info "Status updated for WP #${wp_id} (retry after conflict)"
      return 0
    fi

    log_warn "Could not update status for WP #${wp_id} after retry."
    return 1
  fi

  # Other errors
  op_handle_error "$OP_LAST_HTTP_CODE" "$OP_LAST_RESPONSE" "Updating status for WP #${wp_id}" >/dev/null
  return 1
}

# ---------------------------------------------------------------------------
# op_post_comment <wp_id> <markdown_text>
# Post a comment on a work package. Returns 0 on success, 1 on error.
# ---------------------------------------------------------------------------
op_post_comment() {
  local wp_id="$1"
  local markdown_text="$2"

  # Truncate to 10000 characters
  if [[ ${#markdown_text} -gt 10000 ]]; then
    markdown_text="${markdown_text:0:10000}"
    log_warn "Comment truncated to 10000 characters for WP #${wp_id}"
  fi

  local body
  body=$(jq -n -c --arg text "$markdown_text" '{comment: {raw: $text}}')

  op_request POST "/api/v3/work_packages/${wp_id}/activities" "$body"

  if [[ "$OP_LAST_HTTP_CODE" == "200" || "$OP_LAST_HTTP_CODE" == "201" ]]; then
    local activity_id
    activity_id=$(echo "$OP_LAST_RESPONSE" | jq -r '.id // "?"')
    log_info "Comment posted on WP #${wp_id} (activity #${activity_id})"
    return 0
  fi

  op_handle_error "$OP_LAST_HTTP_CODE" "$OP_LAST_RESPONSE" "Posting comment on WP #${wp_id}" >/dev/null
  return 1
}
