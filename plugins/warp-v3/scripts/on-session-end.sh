#!/bin/bash
# Hook script for Claude Code SessionEnd event
# Emits session_end so Warp can archive the sidebar entry instead of leaving
# it stuck in its last known state (done / running / blocked) after termination.
#
# Also cleans up per-session temp files written by on-prompt-submit.sh and
# the per-session log file (unless WARP_KEEP_LOGS=1).
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#sessionend

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# R6: skip emission in headless mode (no tty → no Warp sidebar to archive).
# Still clean temp files so repeated -p runs don't accumulate .query/.t0/.log.
# _WARP_FORCE_NO_TTY=1 is an internal test hook — do not set in production.
if [ "${_WARP_FORCE_NO_TTY:-0}" = "1" ] || [ ! -w /dev/tty ]; then
    if [ -n "$SESSION_ID" ]; then
        rm -f "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.query" \
              "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.t0" 2>/dev/null || true
        if [ "${WARP_KEEP_LOGS:-0}" != "1" ]; then
            rm -f "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.log" 2>/dev/null || true
        fi
    fi
    exit 0
fi

log_hook "SessionEnd" "$INPUT"

# reason: "clear", "resume", "logout", "prompt_input_exit",
#         "bypass_permissions_disabled", "other"
REASON=$(echo "$INPUT" | jq -r '.reason // "other"' 2>/dev/null)

# R5: session_end is a v3-only event name. Current stable Warp drops it and
# leaves a zombie sidebar row. Only emit when the user has opted in.
if should_emit_v3_events; then
    BODY=$(build_payload "$INPUT" "session_end" \
        --arg reason "$REASON")
    "$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
fi

# Housekeeping — run LAST so log_hook/log_emit above had a chance to record
# SessionEnd. `.log` is preserved under WARP_KEEP_LOGS=1 for post-mortem.
if [ -n "$SESSION_ID" ]; then
    rm -f "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.query" \
          "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.t0" 2>/dev/null || true
    if [ "${WARP_KEEP_LOGS:-0}" != "1" ]; then
        rm -f "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.log" 2>/dev/null || true
    fi
fi
