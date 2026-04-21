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

PLUGIN_VERSION=$(jq -r '.version // "unknown"' "$SCRIPT_DIR/../.claude-plugin/plugin.json" 2>/dev/null)

# SessionStart context lets Warp disambiguate fresh starts from
# resumed / cleared / compacted sessions.
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"' 2>/dev/null)
MODEL=$(echo "$INPUT" | jq -r '.model // empty' 2>/dev/null)
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

# Build payload matching Gemini's Ready-state shape on a fresh tab:
# {v, agent, event, session_id, cwd, project, plugin_version} — exactly 7 fields.
# Omit source / model / permission_mode / agent_type on `source=startup` since
# Warp reads those as "agent has active context" and anchors the sidebar in
# In progress. Keep them on resume / clear / compact where context really is
# returning.
EXTRA_ARGS=(--arg plugin_version "$PLUGIN_VERSION")
if [ -n "$SOURCE" ] && [ "$SOURCE" != "startup" ]; then
    EXTRA_ARGS+=(--arg source "$SOURCE")
    [ -n "$MODEL" ]           && EXTRA_ARGS+=(--arg model "$MODEL")
    [ -n "$PERMISSION_MODE" ] && EXTRA_ARGS+=(--arg permission_mode "$PERMISSION_MODE")
    [ -n "$AGENT_TYPE" ]      && EXTRA_ARGS+=(--arg agent_type "$AGENT_TYPE")
fi

BODY=$(build_payload "$INPUT" "session_start" "${EXTRA_ARGS[@]}")
"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"

# Force the sidebar into "done" state by emitting a synthetic `stop` event
# right after `session_start`. Without this, Warp keeps a freshly-registered
# Claude Code session in its "running" default ("In progress" in the sidebar).
#
# The zero-emit approach we tried in v3.0.5 turned out to break sidebar
# registration entirely — unlike Gemini / Factory-Droid (which Warp
# auto-detects by binary name), Claude sessions need at least one
# `warp://cli-agent` OSC event for the sidebar row to appear.
#
# `stop` carries no user-visible notification when `query` and `response`
# are absent (build_payload strips empty-string args), so this doesn't
# fire a "task completed" toast on every new tab.
STOP_BODY=$(build_payload "$INPUT" "stop")
"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$STOP_BODY"
