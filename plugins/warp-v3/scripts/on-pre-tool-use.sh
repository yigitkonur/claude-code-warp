#!/bin/bash
# Hook script for Claude Code PreToolUse event
# Emits tool_start so the sidebar shows per-tool progress before any permission
# prompt or completion. Paired with on-post-tool-use.sh's tool_complete.
#
# Unconditional — the matcher in hooks.json is empty so every tool fires this,
# regardless of whether Warp renders `tool_start` as a distinct state. Worst
# case Warp drops unknown events; there's no sidebar regression.
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#pretooluse-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "PreToolUse" "$INPUT"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Pick the most visible field from tool_input as a preview ("Edit: src/foo.ts").
TOOL_PREVIEW_RAW=$(echo "$INPUT" | jq -r '(.tool_input | if .command then .command elif .file_path then .file_path elif .url then .url elif .query then .query elif .pattern then .pattern elif .description then .description else "" end) // ""' 2>/dev/null)
TOOL_PREVIEW=$(utf8_truncate "$TOOL_PREVIEW_RAW" 120)

PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)

BODY=$(build_payload "$INPUT" "tool_start" \
    --arg tool_name "$TOOL_NAME" \
    --arg tool_preview "$TOOL_PREVIEW" \
    --arg permission_mode "$PERMISSION_MODE")

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
