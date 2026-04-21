#!/bin/bash
# Hook script for Claude Code SessionStart event
# Emits session_start with plugin version, Claude Code model, permission mode,
# and the source that triggered the start (startup, resume, clear, compact).
#
# https://docs.anthropic.com/en/docs/claude-code/hooks#sessionstart-input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

# Legacy fallback for old Warp versions
if ! should_use_structured; then
    exec "$SCRIPT_DIR/legacy/on-session-start.sh"
fi

if ! command -v jq &>/dev/null; then
    cat << 'EOF'
{
  "systemMessage": "🚨 Warp notifications require jq! Install it with your system package manager (e.g. brew install jq, apt install jq) 🚨"
}
EOF
    exit 0
fi

# R6: headless (`-p`) sessions emitting SessionStart create sidebar flicker
# with no session to track. Skip when there's no tty to write to.
# _WARP_FORCE_NO_TTY=1 is an internal test hook — do not set in production.
if [ "${_WARP_FORCE_NO_TTY:-0}" = "1" ] || [ ! -w /dev/tty ]; then
    exit 0
fi

source "$SCRIPT_DIR/warp-log.sh"
source "$SCRIPT_DIR/build-payload.sh"

INPUT=$(cat)

# Clear any leftover per-session temp files from a previous run that ended
# abruptly. Runs BEFORE log_hook so the fresh log for this session starts clean.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$SESSION_ID" ]; then
    rm -f "${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}".* 2>/dev/null || true
fi

log_hook "SessionStart" "$INPUT"

SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"' 2>/dev/null)

# On a fresh tab (source=startup) we emit NOTHING. This matches what the user
# observes with Gemini CLI and Factory/Droid: those CLIs don't register any
# Warp hook at all, so no `warp://cli-agent` OSC ever arrives, and Warp's
# sidebar shows the pane with just the CLI label + cwd + branch — no state pill.
#
# Any session_start payload we emit (even the minimal Gemini-shape 7 fields)
# causes Warp to attach a state label to the row. For `agent: "claude"` the
# default label is "In progress" — worse than no label. Emitting a follow-up
# `stop` forces it to "Done", which is also worse than no label since the turn
# hasn't happened yet.
#
# By emitting nothing on startup, the sidebar row comes up clean via Warp's
# process-detection path, and only gets a state pill when the user actually
# submits a prompt (`prompt_submit` → "running"). Subsequent `stop` → "done".
#
# The plugin_version signal for Warp's outdated-plugin banner is re-attached
# to on-prompt-submit.sh, so Warp still learns our version on first use.
if [ "$SOURCE" = "startup" ]; then
    exit 0
fi

# For resume / clear / compact: a returning session has genuine state to
# surface (context restored, cwd may have changed). Emit session_start with
# source + enrichment so Warp can refresh the sidebar label.
PLUGIN_VERSION=$(jq -r '.version // "unknown"' "$SCRIPT_DIR/../.claude-plugin/plugin.json" 2>/dev/null)
MODEL=$(echo "$INPUT" | jq -r '.model // empty' 2>/dev/null)
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

EXTRA_ARGS=(--arg plugin_version "$PLUGIN_VERSION" --arg source "$SOURCE")
[ -n "$MODEL" ]           && EXTRA_ARGS+=(--arg model "$MODEL")
[ -n "$PERMISSION_MODE" ] && EXTRA_ARGS+=(--arg permission_mode "$PERMISSION_MODE")
[ -n "$AGENT_TYPE" ]      && EXTRA_ARGS+=(--arg agent_type "$AGENT_TYPE")

BODY=$(build_payload "$INPUT" "session_start" "${EXTRA_ARGS[@]}")
"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
