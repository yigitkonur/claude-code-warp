#!/bin/bash
# Builds a structured JSON notification payload for warp://cli-agent.
#
# Usage: source this file, then call build_payload with event-specific fields.
#
# Example:
#   source "$(dirname "${BASH_SOURCE[0]}")/build-payload.sh"
#   BODY=$(build_payload "$INPUT" "stop" \
#       --arg query "$QUERY" \
#       --arg response "$RESPONSE" \
#       --arg transcript_path "$TRANSCRIPT_PATH")
#
# The function extracts common fields (session_id, cwd, project) from the
# hook's stdin JSON (passed as $1), then merges any extra jq args you pass.
#
# Guarantees:
#   - Empty session_id → returns empty stdout. Callers must guard before emitting.
#   - Extra --arg/--argjson pairs with empty-string values are stripped from the
#     output (Warp interprets model:"" / permission_mode:"" as "still initializing"
#     and leaves the sidebar stuck in an in-progress state).
#   - Envelope fields (v, agent, event, session_id, cwd, project) are always
#     present; they never go through the empty-field strip.

# The current protocol version this plugin knows how to produce.
PLUGIN_CURRENT_PROTOCOL_VERSION=1

# Negotiate the protocol version with Warp.
# Uses min(plugin_current, warp_declared), falling back to 1 if Warp doesn't advertise a version.
negotiate_protocol_version() {
    local warp_version="${WARP_CLI_AGENT_PROTOCOL_VERSION:-1}"
    if [ "$warp_version" -lt "$PLUGIN_CURRENT_PROTOCOL_VERSION" ] 2>/dev/null; then
        echo "$warp_version"
    else
        echo "$PLUGIN_CURRENT_PROTOCOL_VERSION"
    fi
}

# Truncate a string to at most N codepoints (default 200), appending "..." when cut.
# UTF-8-safe because jq's string length + slice operate on codepoints, not bytes.
# Falls through to the raw value if jq is missing.
utf8_truncate() {
    local text="${1:-}"
    local maxlen="${2:-200}"
    [ -z "$text" ] && return 0
    jq -nr --arg text "$text" --argjson max "$maxlen" \
        'if ($text | length) > $max then ($text[0:($max - 3)] + "...") else $text end' 2>/dev/null \
        || printf '%s' "$text"
}

build_payload() {
    local input="$1"
    local event="$2"
    shift 2

    local protocol_version
    protocol_version=$(negotiate_protocol_version)

    # Extract common fields from the hook input
    local session_id cwd project
    session_id=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)

    # Guard: no session_id means we can't correlate this emission with the sidebar
    # row — worse, a stray emit could attach to the wrong session if Warp is running
    # multiple Claude instances. Exit silently rather than risk collision.
    if [ -z "$session_id" ]; then
        return 0
    fi

    cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
    project=""
    # WARP_PLUGIN_DISABLE_PROJECT=1 opts out of the auto-derived project label
    # (warpdotdev/claude-code-warp#23). Users driving their own tab title or
    # tmux window-name don't want `basename(cwd)` clobbering it on every hook.
    if [ -n "$cwd" ] && [ "${WARP_PLUGIN_DISABLE_PROJECT:-0}" != "1" ]; then
        project=$(basename "$cwd")
    fi

    # Envelope fields are explicit; $ARGS.named is filtered of empty strings so
    # enrichment defaults (model="", permission_mode="", agent_type="") don't
    # leak into the payload when the hook input didn't provide them.
    # When WARP_PLUGIN_DISABLE_PROJECT is set, the envelope's own empty
    # `project` is filtered out too — Warp then falls back to whatever tab
    # title is already set.
    jq -nc \
        --argjson v "$protocol_version" \
        --arg agent "claude" \
        --arg event "$event" \
        --arg session_id "$session_id" \
        --arg cwd "$cwd" \
        --arg project "$project" \
        "$@" \
        '({v:$v, agent:$agent, event:$event, session_id:$session_id, cwd:$cwd, project:$project}
          | to_entries | map(select(.key != "project" or .value != "")) | from_entries) +
         ($ARGS.named | to_entries | map(select(.value != null and .value != "")) | from_entries)'
}
