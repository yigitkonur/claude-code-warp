#!/bin/bash
# Hook script for Claude Code PostToolUseFailure event
# Distinguishes failed tool calls (red) from successful ones (green) in the
# sidebar. Without this hook a tool failure looks identical to success —
# both just transition state.
#
# R5: `tool_failed` is a v3-only event name. When the user hasn't opted in,
# fall back to emitting `tool_complete` with an `error` field attached; Warp
# v2 ignores the unknown field but at least clears the blocked/running state.
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#posttoolusefailure-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "PostToolUseFailure" "$INPUT"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
ERROR_RAW=$(echo "$INPUT" | jq -r '.error // empty' 2>/dev/null)
ERROR=$(utf8_truncate "$ERROR_RAW" 200)
IS_INTERRUPT=$(echo "$INPUT" | jq -r '.is_interrupt // false' 2>/dev/null)

TOOL_PREVIEW_RAW=$(echo "$INPUT" | jq -r '(.tool_input | if .command then .command elif .file_path then .file_path elif .url then .url elif .description then .description else "" end) // ""' 2>/dev/null)
TOOL_PREVIEW=$(utf8_truncate "$TOOL_PREVIEW_RAW" 120)

if should_emit_v3_events; then
    BODY=$(build_payload "$INPUT" "tool_failed" \
        --arg tool_name "$TOOL_NAME" \
        --arg error "$ERROR" \
        --arg tool_preview "$TOOL_PREVIEW" \
        --argjson is_interrupt "$IS_INTERRUPT")
else
    # Fallback: `tool_complete` clears the blocked state in Warp v2. Attach the
    # error field so v2.5+ can still render it as failed if it knows to look.
    BODY=$(build_payload "$INPUT" "tool_complete" \
        --arg tool_name "$TOOL_NAME" \
        --arg error "$ERROR" \
        --arg tool_preview "$TOOL_PREVIEW")
fi

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
