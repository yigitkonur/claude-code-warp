#!/bin/bash
# Hook script for Claude Code Stop event
# Sends a structured Warp notification when Claude completes a turn.
#
# Claude Code's Stop hook input now exposes `last_assistant_message` directly,
# so the previous 0.3s sleep + JSONL transcript parse is obsolete. The user's
# prompt is read from a session-scoped temp file written by on-prompt-submit.sh.
#
# duration_ms is computed from the .t0 timestamp stashed by on-prompt-submit.sh.
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#stop-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

# Legacy fallback for old Warp versions
if ! should_use_structured; then
    [ "$TERM_PROGRAM" = "WarpTerminal" ] && exec "$SCRIPT_DIR/legacy/on-stop.sh"
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "Stop" "$INPUT"

# stop_hook_active is true when this hook is re-running because a prior Stop
# hook returned decision:"block". Skip to avoid double-notifications.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Claude's final response — directly available in the hook input.
RESPONSE_RAW=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
RESPONSE=$(utf8_truncate "$RESPONSE_RAW" 200)

# User's last prompt — written by on-prompt-submit.sh to a session-scoped temp file.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
QUERY=""
if [ -n "$SESSION_ID" ]; then
    QUERY_FILE="${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.query"
    if [ -f "$QUERY_FILE" ]; then
        QUERY_RAW=$(cat "$QUERY_FILE" 2>/dev/null)
        QUERY=$(utf8_truncate "$QUERY_RAW" 200)
    fi
fi

# duration_ms: wall-clock time from UserPromptSubmit to Stop. Only attached
# when both t0 and t1 are available and positive.
DURATION_MS=0
if [ -n "$SESSION_ID" ]; then
    T0_FILE="${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.t0"
    if [ -f "$T0_FILE" ]; then
        T0=$(cat "$T0_FILE" 2>/dev/null)
        T1=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null)
        if [ -n "$T0" ] && [ -n "$T1" ] && [ "$T1" -gt "$T0" ] 2>/dev/null; then
            DURATION_MS=$((T1 - T0))
        fi
    fi
fi

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)

ARGS=(--arg query "$QUERY"
      --arg response "$RESPONSE"
      --arg transcript_path "$TRANSCRIPT_PATH"
      --arg permission_mode "$PERMISSION_MODE")
if [ "$DURATION_MS" -gt 0 ] 2>/dev/null; then
    ARGS+=(--argjson duration_ms "$DURATION_MS")
fi

BODY=$(build_payload "$INPUT" "stop" "${ARGS[@]}")

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
