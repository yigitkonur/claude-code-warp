#!/bin/bash
# Hook script for Claude Code PostToolUse event
# Emits tool_complete after every tool call so the sidebar clears any blocked
# state (permission approval, tool-in-flight). Without this running for ALL
# tools, approving a Read/Glob/Grep/WebFetch would leave the sidebar stuck on
# Blocked until the next Stop.
#
# The matcher in hooks.json is deliberately empty. State-transition tools
# (Bash/Edit/Write/MultiEdit/NotebookEdit/Agent) get a rich payload with a
# tool_preview; read-only tools get the skeleton.
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#posttooluse-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "PostToolUse" "$INPUT"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
BLOCKED_MARKER="${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.blocked"

# Decide whether to emit. A fresh tool_complete per tool call would flood
# Warp's `warp://cli-agent` buffer (warpdotdev/claude-code-warp#22 — upstream
# leaks 200+ GB over long sessions). Two cases justify emission:
#
#   1. A prior PermissionRequest left a .blocked marker — Warp's sidebar is
#      stuck on Blocked and needs tool_complete to move forward. (R1 fix.)
#   2. The tool is state-transition heavy (Bash/Edit/Write/MultiEdit/
#      NotebookEdit/Agent) — Warp renders a tool_preview and expects these.
#
# Read/Glob/Grep/WebFetch/LSP/WebSearch with no prior PermissionRequest are
# a no-op — they don't change sidebar state in any user-visible way.
SHOULD_EMIT=0
HAD_BLOCKED=0
if [ -n "$SESSION_ID" ] && [ -f "$BLOCKED_MARKER" ]; then
    rm -f "$BLOCKED_MARKER" 2>/dev/null || true
    SHOULD_EMIT=1
    HAD_BLOCKED=1
fi
case "$TOOL_NAME" in
    Bash|Edit|Write|MultiEdit|NotebookEdit|Agent) SHOULD_EMIT=1 ;;
esac

if [ "$SHOULD_EMIT" = "0" ]; then
    exit 0
fi

case "$TOOL_NAME" in
    Bash|Edit|Write|MultiEdit|NotebookEdit|Agent)
        TOOL_PREVIEW_RAW=$(echo "$INPUT" | jq -r '(.tool_input | if .command then .command elif .file_path then .file_path elif .url then .url elif .description then .description else "" end) // ""' 2>/dev/null)
        TOOL_PREVIEW=$(utf8_truncate "$TOOL_PREVIEW_RAW" 120)
        BODY=$(build_payload "$INPUT" "tool_complete" \
            --arg tool_name "$TOOL_NAME" \
            --arg tool_preview "$TOOL_PREVIEW" \
            --arg permission_mode "$PERMISSION_MODE")
        ;;
    *)
        # Skeleton payload for cheap tools — fires only when a prior
        # PermissionRequest left the sidebar in Blocked state.
        BODY=$(build_payload "$INPUT" "tool_complete" \
            --arg tool_name "$TOOL_NAME" \
            --arg permission_mode "$PERMISSION_MODE")
        ;;
esac

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
