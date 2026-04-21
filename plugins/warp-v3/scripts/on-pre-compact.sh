#!/bin/bash
# Hook script for Claude Code PreCompact event
# Emits compact_start so the sidebar can show "compacting..." instead of
# letting the session appear frozen while context compaction runs.
#
# R5: `compact_start` is a v3-only event. Current stable Warp drops it, so
# under the default (WARP_CLI_AGENT_V3_EVENTS unset) we no-op rather than
# send a payload Warp will silently ignore.
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#precompact

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "PreCompact" "$INPUT"

if ! should_emit_v3_events; then
    exit 0
fi

# trigger: "manual" (user ran /compact) or "auto" (context limit hit)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)

BODY=$(build_payload "$INPUT" "compact_start" \
    --arg trigger "$TRIGGER")

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
