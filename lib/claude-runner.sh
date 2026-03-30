#!/usr/bin/env bash
# forgeplan — lib/claude-runner.sh
# Claude Code CLI invocation, timeout, retry, validation.

# Globals set by this module:
#   CLAUDE_EXIT_CODE         — exit code from Claude Code CLI
#   CLAUDE_OUTPUT_FILE       — path to raw output file
#   CLAUDE_COST_USD          — API cost from structured output
#   CLAUDE_DURATION_MS       — execution time from structured output
#   CLAUDE_NUM_TURNS         — agentic turns from structured output
#   CLAUDE_CHANGED_FILES     — newline-separated list of changed files
#   CLAUDE_FILES_CREATED     — count of new files
#   CLAUDE_FILES_MODIFIED    — count of modified files
#   CLAUDE_VALIDATION_OUTPUT — stdout+stderr from validation command
#   CLAUDE_VALIDATION_EXIT   — exit code from validation command
#   CLAUDE_RESULT            — SUCCESS | PARTIAL | FAILURE
#   CLAUDE_FAILURE_REASON    — no_output | generation_error | timeout (when FAILURE)
#   CLAUDE_ATTEMPTS          — number of execution attempts (with retries)

# ---------------------------------------------------------------------------
# Portable timeout wrapper (macOS doesn't have GNU timeout)
# ---------------------------------------------------------------------------
_fp_timeout() {
  local secs="$1"; shift
  if command -v timeout > /dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # Fallback: run in background, kill after timeout
    "$@" &
    local pid=$!
    (sleep "$secs" && kill "$pid" 2>/dev/null) &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
    # If killed by our watcher, return 124 (matches GNU timeout)
    if [[ $rc -eq 137 || $rc -eq 143 ]]; then
      return 124
    fi
    return $rc
  fi
}

CLAUDE_EXIT_CODE=""
CLAUDE_OUTPUT_FILE=""
CLAUDE_COST_USD=""
CLAUDE_DURATION_MS=""
CLAUDE_NUM_TURNS=""
CLAUDE_CHANGED_FILES=""
CLAUDE_FILES_CREATED=0
CLAUDE_FILES_MODIFIED=0
CLAUDE_VALIDATION_OUTPUT=""
CLAUDE_VALIDATION_EXIT=""
CLAUDE_RESULT=""
CLAUDE_FAILURE_REASON=""
CLAUDE_ATTEMPTS=0

# ==========================================================================
# Command builder
# ==========================================================================

# ---------------------------------------------------------------------------
# claude_build_command <prompt_file>
# Construct the Claude Code CLI command string.
# Sets CLAUDE_CMD global.
# ---------------------------------------------------------------------------
claude_build_command() {
  local prompt_file="$1"

  # Run interactively so the user can see Claude's progress and respond to
  # any questions. Output is shown live in the terminal.
  CLAUDE_CMD="claude --model ${CLAUDE_MODEL} --max-turns 50 --prompt-file ${prompt_file}"

  log_debug "Claude command: ${CLAUDE_CMD}"
}

# ==========================================================================
# Execution
# ==========================================================================

# ---------------------------------------------------------------------------
# claude_execute_with_timeout <timeout_seconds>
# Run the command built by claude_build_command with a timeout.
# Sets CLAUDE_EXIT_CODE, CLAUDE_OUTPUT_FILE.
# ---------------------------------------------------------------------------
claude_execute_with_timeout() {
  local timeout_seconds="$1"

  CLAUDE_OUTPUT_FILE=$(mktemp)
  local start_time
  start_time=$(date +%s)

  cd "$REPO_ROOT" || exit 4

  # Run interactively — output goes directly to the terminal so the user can
  # see Claude's progress and respond. Exit code is captured for retry logic.
  _fp_timeout "$timeout_seconds" bash -c "$CLAUDE_CMD"
  CLAUDE_EXIT_CODE=$?

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  log_info "Claude Code exited with code ${CLAUDE_EXIT_CODE} after ${elapsed}s"

  return "$CLAUDE_EXIT_CODE"
}

# ---------------------------------------------------------------------------
# claude_execute_with_retry <timeout_seconds>
# Wrap execution with exponential backoff retry logic.
# Sets CLAUDE_ATTEMPTS.
# ---------------------------------------------------------------------------
claude_execute_with_retry() {
  local timeout_seconds="$1"
  local max_retries="${CLAUDE_MAX_RETRIES:-3}"
  local base_delay="${CLAUDE_RETRY_DELAY:-10}"

  CLAUDE_ATTEMPTS=0
  local attempt=1

  while [[ $attempt -le $((max_retries + 1)) ]]; do
    CLAUDE_ATTEMPTS=$attempt

    claude_execute_with_timeout "$timeout_seconds" || true

    # Success — no retry needed
    if [[ "$CLAUDE_EXIT_CODE" -eq 0 ]]; then
      return 0
    fi

    # Timeout — do NOT retry
    if [[ "$CLAUDE_EXIT_CODE" -eq 124 ]]; then
      return 124
    fi

    # Non-zero exit — check if the exit code suggests a retryable error.
    # (Rate limit = 1 is common; network errors also exit non-zero)
    local retryable=false
    if [[ "$CLAUDE_EXIT_CODE" -eq 1 ]]; then
      retryable=true
    fi

    if [[ "$retryable" != "true" ]]; then
      # Non-retryable error
      return "$CLAUDE_EXIT_CODE"
    fi

    # Check if we have retries left
    if [[ $attempt -gt $max_retries ]]; then
      log_error "Claude Code failed after ${max_retries} attempts."
      return "$CLAUDE_EXIT_CODE"
    fi

    local delay=$(( base_delay * (1 << (attempt - 1)) ))
    log_warn "Attempt ${attempt} failed. Retrying in ${delay}s..."
    sleep "$delay"

    ((attempt++))
  done

  return "$CLAUDE_EXIT_CODE"
}

# ==========================================================================
# Output parser
# ==========================================================================

# ---------------------------------------------------------------------------
# claude_parse_output
# Parse the JSON output from Claude Code CLI.
# Sets CLAUDE_COST_USD, CLAUDE_DURATION_MS, CLAUDE_NUM_TURNS.
# ---------------------------------------------------------------------------
claude_parse_output() {
  # Running interactively — no structured output to parse.
  CLAUDE_COST_USD="unknown"
  CLAUDE_DURATION_MS="unknown"
  CLAUDE_NUM_TURNS="unknown"
}

# ==========================================================================
# Change detector
# ==========================================================================

# ---------------------------------------------------------------------------
# claude_check_changes <repo_root>
# Detect file modifications and new files.
# Sets CLAUDE_CHANGED_FILES, CLAUDE_FILES_CREATED, CLAUDE_FILES_MODIFIED.
# Returns 0 if changes exist, 1 if none.
# ---------------------------------------------------------------------------
claude_check_changes() {
  local repo_root="$1"

  local modified new_files
  modified=$(git -C "$repo_root" diff --name-only 2>/dev/null || true)
  new_files=$(git -C "$repo_root" ls-files --others --exclude-standard 2>/dev/null || true)

  CLAUDE_FILES_MODIFIED=0
  CLAUDE_FILES_CREATED=0
  CLAUDE_CHANGED_FILES=""

  if [[ -n "$modified" ]]; then
    CLAUDE_FILES_MODIFIED=$(echo "$modified" | wc -l | tr -d ' ')
    CLAUDE_CHANGED_FILES="$modified"
  fi

  if [[ -n "$new_files" ]]; then
    CLAUDE_FILES_CREATED=$(echo "$new_files" | wc -l | tr -d ' ')
    if [[ -n "$CLAUDE_CHANGED_FILES" ]]; then
      CLAUDE_CHANGED_FILES+=$'\n'"$new_files"
    else
      CLAUDE_CHANGED_FILES="$new_files"
    fi
  fi

  if [[ -n "$CLAUDE_CHANGED_FILES" ]]; then
    log_info "Changes detected: ${CLAUDE_FILES_MODIFIED} modified, ${CLAUDE_FILES_CREATED} created"
    return 0
  else
    log_info "No file changes detected"
    return 1
  fi
}

# ==========================================================================
# Validation runner
# ==========================================================================

# ---------------------------------------------------------------------------
# claude_validate <repo_root>
# Run VALIDATION_CMD if set. Sets CLAUDE_VALIDATION_OUTPUT, CLAUDE_VALIDATION_EXIT.
# ---------------------------------------------------------------------------
claude_validate() {
  local repo_root="$1"

  if [[ -z "${VALIDATION_CMD:-}" ]]; then
    CLAUDE_VALIDATION_EXIT=0
    CLAUDE_VALIDATION_OUTPUT=""
    return 0
  fi

  if [[ "${FLAG_SKIP_VALIDATION:-false}" == "true" ]]; then
    CLAUDE_VALIDATION_EXIT=0
    CLAUDE_VALIDATION_OUTPUT="(skipped)"
    return 0
  fi

  log_info "Running validation: ${VALIDATION_CMD}"

  local val_timeout="${VALIDATION_TIMEOUT:-120}"
  CLAUDE_VALIDATION_OUTPUT=$(cd "$repo_root" && _fp_timeout "$val_timeout" bash -c "$VALIDATION_CMD" 2>&1) || true
  CLAUDE_VALIDATION_EXIT=$?

  # Handle timeout
  if [[ "$CLAUDE_VALIDATION_EXIT" -eq 124 ]]; then
    CLAUDE_VALIDATION_OUTPUT="Validation timed out after ${val_timeout}s"
  fi

  # Truncate to 2000 chars
  if [[ ${#CLAUDE_VALIDATION_OUTPUT} -gt 2000 ]]; then
    CLAUDE_VALIDATION_OUTPUT="${CLAUDE_VALIDATION_OUTPUT:0:2000}"
  fi

  if [[ "$CLAUDE_VALIDATION_EXIT" -eq 0 ]]; then
    log_info "Validation passed"
  else
    log_warn "Validation failed (exit ${CLAUDE_VALIDATION_EXIT})"
  fi

  return "$CLAUDE_VALIDATION_EXIT"
}

# ==========================================================================
# Result determination
# ==========================================================================

# ---------------------------------------------------------------------------
# claude_determine_result <generation_exit> <has_changes> <validation_exit>
# Apply the decision matrix. Sets CLAUDE_RESULT, CLAUDE_FAILURE_REASON.
#   has_changes: "true" or "false"
#   validation_exit: exit code or "skipped"
# ---------------------------------------------------------------------------
claude_determine_result() {
  local gen_exit="$1"
  local has_changes="$2"
  local val_exit="${3:-skipped}"

  CLAUDE_FAILURE_REASON=""

  # Timeout with no changes
  if [[ "$gen_exit" -eq 124 && "$has_changes" == "false" ]]; then
    CLAUDE_RESULT="FAILURE"
    CLAUDE_FAILURE_REASON="timeout"
    return 0
  fi

  # Timeout with partial changes — still FAILURE per spec but files committed
  if [[ "$gen_exit" -eq 124 && "$has_changes" == "true" ]]; then
    CLAUDE_RESULT="FAILURE"
    CLAUDE_FAILURE_REASON="timeout"
    return 0
  fi

  # Generation error (non-zero, non-timeout)
  if [[ "$gen_exit" -ne 0 ]]; then
    CLAUDE_RESULT="FAILURE"
    CLAUDE_FAILURE_REASON="generation_error"
    return 0
  fi

  # Generation succeeded (exit 0) but no changes
  if [[ "$has_changes" == "false" ]]; then
    CLAUDE_RESULT="FAILURE"
    CLAUDE_FAILURE_REASON="no_output"
    return 0
  fi

  # Generation succeeded + changes exist
  if [[ "$val_exit" == "skipped" || "$val_exit" -eq 0 ]]; then
    CLAUDE_RESULT="SUCCESS"
    return 0
  fi

  # Generation succeeded + changes + validation failed
  CLAUDE_RESULT="PARTIAL"
  return 0
}

# ==========================================================================
# Orchestrator
# ==========================================================================

# ---------------------------------------------------------------------------
# claude_run <prompt_file> <repo_root>
# Main entry point. Orchestrates the full invocation flow.
# ---------------------------------------------------------------------------
claude_run() {
  local prompt_file="$1"
  local repo_root="$2"

  # Validate claude CLI exists
  if ! which claude > /dev/null 2>&1; then
    log_error "Claude Code CLI not found."
    echo "ERROR: Claude Code CLI ('claude') not found on PATH." >&2
    echo "" >&2
    echo "Install using any method:" >&2
    echo "  npm:    npm install -g @anthropic-ai/claude-code" >&2
    echo "  brew:   brew install claude-code" >&2
    echo "  manual: https://docs.anthropic.com/en/docs/claude-code" >&2
    exit 2
  fi

  # Build command
  claude_build_command "$prompt_file"

  # Print a clear separator so the user knows Claude is now running
  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  Claude Code is running — you can see and respond below" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "" >&2
  log_info "Invoking Claude Code..."
  claude_execute_with_retry "${GENERATION_TIMEOUT:-600}" || true

  # Parse output
  claude_parse_output

  # Check for file changes
  local has_changes="false"
  if claude_check_changes "$repo_root"; then
    has_changes="true"
  fi

  # Run validation if changes exist and VALIDATION_CMD is set
  local val_exit="skipped"
  if [[ "$has_changes" == "true" && -n "${VALIDATION_CMD:-}" && "${FLAG_SKIP_VALIDATION:-false}" != "true" ]]; then
    claude_validate "$repo_root" || true
    val_exit="$CLAUDE_VALIDATION_EXIT"
  fi

  # Determine result
  claude_determine_result "$CLAUDE_EXIT_CODE" "$has_changes" "$val_exit"

  log_info "Generation result: ${CLAUDE_RESULT} (exit=${CLAUDE_EXIT_CODE}, changes=${has_changes}, validation=${val_exit})"
}
