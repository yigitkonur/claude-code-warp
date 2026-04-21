#!/bin/bash
# Hook script for Claude Code PermissionRequest event
# Sends a structured Warp notification when Claude needs permission to run a tool.
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#permissionrequest-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "PermissionRequest" "$INPUT"

# Drop a .blocked marker so the next PostToolUse emits tool_complete to clear
# Warp's Blocked state. Without the marker, PostToolUse skips emission — this
# prevents the 200+ GB Warp memory leak from firing tool_complete on every
# Read/Glob/Grep/etc (warpdotdev/claude-code-warp#22).
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$SESSION_ID" ]; then
    : > "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.blocked" 2>/dev/null || true
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
[ -z "$TOOL_INPUT" ] && TOOL_INPUT='{}'

TOOL_PREVIEW_RAW=$(echo "$INPUT" | jq -r '(.tool_input | if .command then .command elif .file_path then .file_path elif .url then .url elif .query then .query elif .pattern then .pattern else (tostring | .[0:80]) end) // ""' 2>/dev/null)
TOOL_PREVIEW=$(utf8_truncate "$TOOL_PREVIEW_RAW" 120)
SUMMARY="Wants to run $TOOL_NAME"
if [ -n "$TOOL_PREVIEW" ]; then
    SUMMARY="$SUMMARY: $TOOL_PREVIEW"
fi

PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)

BODY=$(build_payload "$INPUT" "permission_request" \
    --arg summary "$SUMMARY" \
    --arg tool_name "$TOOL_NAME" \
    --argjson tool_input "$TOOL_INPUT" \
    --arg permission_mode "$PERMISSION_MODE")

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
