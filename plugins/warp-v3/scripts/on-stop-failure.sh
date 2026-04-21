#!/bin/bash
# Hook script for Claude Code StopFailure event
# Fires instead of Stop when the turn ends because of an API error (rate limit,
# auth, billing, server). Without this hook, Warp's sidebar would stay in
# "running" state forever since `stop` never fires on errors.
#
# Emits the existing `stop` event (which Warp v2 knows) so the tab still
# transitions to done. The `error` field is attached only when the user has
# opted into v3 events — v2 Warp ignores the unknown field either way, but
# v3-aware builds render it as failed.
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#stopfailure-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "StopFailure" "$INPUT"

# error: "rate_limit", "authentication_failed", "billing_error",
#        "invalid_request", "server_error", "max_output_tokens", "unknown"
ERROR=$(echo "$INPUT" | jq -r '.error // "unknown"' 2>/dev/null)
ERROR_DETAILS=$(echo "$INPUT" | jq -r '.error_details // empty' 2>/dev/null)
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)

# Recover the last user prompt from the session-scoped temp file written by
# on-prompt-submit.sh. Provides context for "what was the user doing when this failed".
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
QUERY=""
if [ -n "$SESSION_ID" ]; then
    QUERY_FILE="${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.query"
    if [ -f "$QUERY_FILE" ]; then
        QUERY_RAW=$(cat "$QUERY_FILE" 2>/dev/null)
        QUERY=$(utf8_truncate "$QUERY_RAW" 200)
    fi
fi

# Compose a human-readable error line. `last_assistant_message` for StopFailure
# holds the rendered error text, not Claude's output — use it directly.
if [ -n "$LAST_MSG" ]; then
    RESPONSE_RAW="$LAST_MSG"
else
    RESPONSE_RAW="Error: $ERROR"
    [ -n "$ERROR_DETAILS" ] && RESPONSE_RAW="$RESPONSE_RAW — $ERROR_DETAILS"
fi
RESPONSE=$(utf8_truncate "$RESPONSE_RAW" 200)

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

ARGS=(--arg query "$QUERY"
      --arg response "$RESPONSE"
      --arg transcript_path "$TRANSCRIPT_PATH")
if should_emit_v3_events; then
    ARGS+=(--arg error "$ERROR" --arg error_details "$ERROR_DETAILS")
fi

BODY=$(build_payload "$INPUT" "stop" "${ARGS[@]}")

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"

# Best-effort cleanup: StopFailure is a terminal event for the turn; drop the
# .query and .t0 temp files so the next turn starts fresh.
if [ -n "$SESSION_ID" ]; then
    rm -f "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.query" \
          "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.t0" 2>/dev/null || true
fi
