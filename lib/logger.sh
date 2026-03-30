#!/usr/bin/env bash
# forgeplan — lib/logger.sh
# Structured logging + redaction.

# Globals set by this module:
#   LOG_FILE — path to current run's log file

# ---------------------------------------------------------------------------
# log_redact <string>
# Replace sensitive token values with [REDACTED].
# ---------------------------------------------------------------------------
log_redact() {
  local text="$1"

  if [[ -n "${OP_API_KEY:-}" ]]; then
    # Escape special regex chars in the token value
    local escaped
    escaped=$(printf '%s\n' "$OP_API_KEY" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    text=$(printf '%s' "$text" | sed "s/${escaped}/[REDACTED]/g")
  fi

  if [[ -n "${GIT_HOST_TOKEN:-}" ]]; then
    local escaped
    escaped=$(printf '%s\n' "$GIT_HOST_TOKEN" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    text=$(printf '%s' "$text" | sed "s/${escaped}/[REDACTED]/g")
  fi

  printf '%s' "$text"
}

# ---------------------------------------------------------------------------
# log_init <wp_id>
# Create log directory and per-run log file.
# ---------------------------------------------------------------------------
log_init() {
  local wp_id="$1"
  local timestamp
  timestamp=$(date +"%Y%m%d-%H%M%S")

  mkdir -p "${LOG_DIR:-./ logs}"
  LOG_FILE="${LOG_DIR:-./logs}/wp-${wp_id}-${timestamp}.log"

  local iso_ts
  iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "=== forgeplan run: WP #${wp_id} at ${iso_ts} ===" > "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Internal: write a log line to file and optionally to a file descriptor.
# ---------------------------------------------------------------------------
_log_write() {
  local level="$1"
  local message="$2"
  local fd="${3:-}" # 1=stdout, 2=stderr, empty=file-only

  local time_str
  time_str=$(date +"%H:%M:%S")
  local redacted
  redacted=$(log_redact "$message")
  local line="[${level}][${time_str}] ${redacted}"

  # Write to log file if initialized
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$line" >> "$LOG_FILE"
  fi

  # Write to terminal
  if [[ "$fd" == "1" ]]; then
    echo "$line"
  elif [[ "$fd" == "2" ]]; then
    echo "$line" >&2
  fi
}

# ---------------------------------------------------------------------------
# log_info <message>
# ---------------------------------------------------------------------------
log_info() {
  _log_write "INFO" "$1" "1"
}

# ---------------------------------------------------------------------------
# log_warn <message>
# ---------------------------------------------------------------------------
log_warn() {
  _log_write "WARN" "$1" "2"
}

# ---------------------------------------------------------------------------
# log_error <message>
# ---------------------------------------------------------------------------
log_error() {
  _log_write "ERROR" "$1" "2"
}

# ---------------------------------------------------------------------------
# log_debug <message>
# Write to LOG_FILE always; to stderr only if FLAG_VERBOSE is true.
# ---------------------------------------------------------------------------
log_debug() {
  if [[ "${FLAG_VERBOSE:-false}" == "true" ]]; then
    _log_write "DEBUG" "$1" "2"
  else
    _log_write "DEBUG" "$1" ""
  fi
}

# ---------------------------------------------------------------------------
# log_summary <wp_id> <status> <duration_secs> <branch> <pr_url>
#             <files_created> <files_modified> <cost_usd>
# Append a JSON line to run-summary.jsonl.
# ---------------------------------------------------------------------------
log_summary() {
  local wp_id="$1"
  local status="$2"
  local duration="$3"
  local branch="${4:-}"
  local pr_url="${5:-}"
  local files_created="${6:-0}"
  local files_modified="${7:-0}"
  local cost_usd="${8:-0}"

  local iso_ts
  iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local summary_file="${LOG_DIR:-./logs}/run-summary.jsonl"

  mkdir -p "${LOG_DIR:-./logs}"

  jq -n -c \
    --argjson wp_id "$wp_id" \
    --arg status "$status" \
    --argjson duration "$duration" \
    --arg branch "$branch" \
    --arg pr_url "$pr_url" \
    --argjson files_created "$files_created" \
    --argjson files_modified "$files_modified" \
    --arg cost_usd "$cost_usd" \
    --arg timestamp "$iso_ts" \
    '{
      wp_id: $wp_id,
      status: $status,
      duration: $duration,
      branch: $branch,
      pr_url: $pr_url,
      files_created: $files_created,
      files_modified: $files_modified,
      cost_usd: $cost_usd,
      timestamp: $timestamp
    }' >> "$summary_file"
}
