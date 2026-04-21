#!/bin/bash
# Hook script for Claude Code PermissionDenied event
# Fires when the auto-mode classifier silently denies a tool call. Without this
# hook, any prior permission_request that the classifier then denies leaves the
# sidebar stuck on "blocked-awaiting-permission" until the next Stop.
#
# Only fires in auto mode (--dangerously-skip-permissions,
# --permission-mode auto, etc). Manual denials do not fire this event.
#
# R5: `permission_denied` is a v3-only event name. Fall back to `tool_complete`
# when the user hasn't opted in — semantically imperfect but visually correct
# (clears the blocked state, which is what matters).
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#permissiondenied-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "PermissionDenied" "$INPUT"

# Permission was denied — the sidebar's Blocked state is resolved (negatively).
# Clear any .blocked marker so the next tool call doesn't re-fire tool_complete.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$SESSION_ID" ]; then
    rm -f "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.blocked" 2>/dev/null || true
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
[ -z "$TOOL_INPUT" ] && TOOL_INPUT='{}'
REASON=$(echo "$INPUT" | jq -r '.reason // "denied by auto mode classifier"' 2>/dev/null)

TOOL_PREVIEW_RAW=$(echo "$INPUT" | jq -r '(.tool_input | if .command then .command elif .file_path then .file_path elif .url then .url elif .query then .query elif .pattern then .pattern else (tostring | .[0:80]) end) // ""' 2>/dev/null)
TOOL_PREVIEW=$(utf8_truncate "$TOOL_PREVIEW_RAW" 120)
SUMMARY="Auto-denied $TOOL_NAME"
if [ -n "$TOOL_PREVIEW" ]; then
    SUMMARY="$SUMMARY: $TOOL_PREVIEW"
fi

if should_emit_v3_events; then
    BODY=$(build_payload "$INPUT" "permission_denied" \
        --arg summary "$SUMMARY" \
        --arg tool_name "$TOOL_NAME" \
        --argjson tool_input "$TOOL_INPUT" \
        --arg reason "$REASON")
else
    # Fallback: tool_complete clears the blocked-awaiting-permission state.
    # Warp v2 doesn't render "denied" distinctly but at least the sidebar moves.
    BODY=$(build_payload "$INPUT" "tool_complete" \
        --arg tool_name "$TOOL_NAME" \
        --arg tool_preview "$TOOL_PREVIEW")
fi

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
