#!/bin/bash
# Hook script for Claude Code UserPromptSubmit event
# Sends a structured Warp notification when the user submits a prompt,
# transitioning the session from idle/done → running.
#
# Writes two session-scoped temp files that downstream hooks consume:
#   .query — full prompt text, read by on-stop.sh for the completion summary
#   .t0    — turn-start timestamp (ms), read by on-stop.sh to compute duration_ms
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#userpromptsubmit-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)
log_hook "UserPromptSubmit" "$INPUT"

FULL_QUERY=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
QUERY=$(utf8_truncate "$FULL_QUERY" 200)

# session_title: short label for the sidebar row (first prompt normalized to
# one line, ~60 codepoints). Replacement of whitespace runs keeps it tidy.
SESSION_TITLE=""
if [ -n "$FULL_QUERY" ]; then
    NORMALIZED=$(printf '%s' "$FULL_QUERY" | jq -Rsr 'gsub("[\\n\\r\\t]";" ") | gsub("  +";" ")' 2>/dev/null)
    SESSION_TITLE=$(utf8_truncate "$NORMALIZED" 60)
fi

# CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 opts out of title-like emissions
# (warpdotdev/claude-code-warp#24). Users who drive their own tab title via
# shell hooks / kitty / tmux don't want the prompt overwriting it.
if [ "${CLAUDE_CODE_DISABLE_TERMINAL_TITLE:-0}" = "1" ]; then
    QUERY=""
    SESSION_TITLE=""
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$SESSION_ID" ]; then
    # Persist full prompt for on-stop.sh's completion summary.
    if [ -n "$FULL_QUERY" ]; then
        printf '%s' "$FULL_QUERY" > "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.query" 2>/dev/null || true
    fi
    # Stash turn-start timestamp (ms) for on-stop.sh's duration_ms.
    python3 -c 'import time; print(int(time.time() * 1000))' > "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.t0" 2>/dev/null || true
fi

PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)

# plugin_version is attached here (not at session_start, since we suppress
# startup emissions entirely). Warp's outdated-plugin banner reads this on
# the first prompt_submit of a session — same effective signal, later timing.
PLUGIN_VERSION=$(jq -r '.version // "unknown"' "$SCRIPT_DIR/../.claude-plugin/plugin.json" 2>/dev/null)

BODY=$(build_payload "$INPUT" "prompt_submit" \
    --arg query "$QUERY" \
    --arg session_title "$SESSION_TITLE" \
    --arg permission_mode "$PERMISSION_MODE" \
    --arg plugin_version "$PLUGIN_VERSION")

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
