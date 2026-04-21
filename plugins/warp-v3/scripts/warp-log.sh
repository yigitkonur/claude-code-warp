#!/bin/bash
# Per-session OSC event log — lets you `tail -f /tmp/warp-claude-latest.log`
# and cross-reference Warp's sidebar against what the adapter actually emitted.
#
# Every hook script calls:
#     log_hook <hook_name> <input_json>   # at entry, right after reading stdin
# and warp-notify.sh calls:
#     log_emit <title> <body_json>        # as its final step before /dev/tty
#
# Log file:
#   ${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.log
#   Falls back to warp-claude-no-session.log if session_id is empty.
#   /tmp/warp-claude-latest.log is a symlink kept pointed at the most recent
#   log file — hardcoded at /tmp (not $TMPDIR) because on macOS $TMPDIR is
#   a per-user path under /var/folders/... and `tail -f /tmp/warp-claude-latest.log`
#   would otherwise not resolve.
#
# Line format — two shapes, both start with a fixed-width timestamp:
#   [YYYY-MM-DD HH:MM:SS.mmm] HOOK=<name> session_id=... key=value ...
#   [YYYY-MM-DD HH:MM:SS.mmm] EMIT  event=... key=value ...
#
# Cleanup: on-session-end.sh deletes the .log unless WARP_KEEP_LOGS=1 is set.

# Sub-second timestamp. Python3 is ubiquitous on macOS + modern Linux; if
# absent we fall through to second-precision so logs still land on disk.
_warp_log_ts() {
    python3 -c 'from datetime import datetime
now = datetime.now()
print("[" + now.strftime("%Y-%m-%d %H:%M:%S.") + f"{now.microsecond // 1000:03d}]")' 2>/dev/null \
        || date +'[%Y-%m-%d %H:%M:%S.000]'
}

# Resolve the log file path from a JSON blob carrying session_id.
_warp_log_file_for() {
    local input="${1:-}"
    local sid=""
    if [ -n "$input" ]; then
        sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
    fi
    [ -z "$sid" ] && sid="no-session"
    printf '%s/warp-claude-%s.log' "${TMPDIR:-/tmp}" "$sid"
}

_warp_log_update_symlink() {
    # Non-atomic but harmless — debug-only, worst case two racing hooks see the
    # symlink briefly missing and ln -sf recreates it.
    # Symlink sits at /tmp (not $TMPDIR) so the README's documented
    # `tail -f /tmp/warp-claude-latest.log` resolves across macOS and Linux.
    ln -sf "$1" "/tmp/warp-claude-latest.log" 2>/dev/null || true
}

# log_hook <hook_name> <input_json>
log_hook() {
    local hook="${1:-unknown}"
    local input="${2:-}"
    local logfile ts fields
    logfile=$(_warp_log_file_for "$input")
    ts=$(_warp_log_ts)
    fields=$(printf '%s' "$input" | jq -r '
        [
            ("session_id=" + (.session_id // "")),
            (if (.source // "") != "" then "source=" + .source else empty end),
            (if (.model // "") != "" then "model=" + .model else empty end),
            (if (.tool_name // "") != "" then "tool_name=" + .tool_name else empty end),
            (if (.prompt // "") != "" then "prompt=" + (.prompt | tojson) else empty end),
            (if (.reason // "") != "" then "reason=" + .reason else empty end),
            (if (.trigger // "") != "" then "trigger=" + .trigger else empty end),
            (if (.notification_type // "") != "" then "notification_type=" + .notification_type else empty end),
            (if (.agent_type // "") != "" then "agent_type=" + .agent_type else empty end),
            (if (.permission_mode // "") != "" then "permission_mode=" + .permission_mode else empty end),
            (if .stop_hook_active != null then "stop_hook_active=" + (.stop_hook_active | tostring) else empty end),
            (if (.last_assistant_message // "") != "" then "last_assistant_message=" + (.last_assistant_message[0:60] | tojson) else empty end),
            (if (.error // "") != "" then "error=" + (.error | tojson) else empty end)
        ] | join(" ")
    ' 2>/dev/null)
    [ -z "$fields" ] && fields="session_id="
    printf '%s HOOK=%s %s\n' "$ts" "$hook" "$fields" >> "$logfile" 2>/dev/null || true
    _warp_log_update_symlink "$logfile"
}

# log_emit <title> <body_json>
log_emit() {
    local body="${2:-}"
    local logfile ts fields
    logfile=$(_warp_log_file_for "$body")
    ts=$(_warp_log_ts)
    fields=$(printf '%s' "$body" | jq -r '
        [
            (if (.event // "") != "" then "event=" + .event else empty end),
            (if (.source // "") != "" then "source=" + .source else empty end),
            (if (.model // "") != "" then "model=" + .model else empty end),
            (if (.tool_name // "") != "" then "tool_name=" + .tool_name else empty end),
            (if (.tool_preview // "") != "" then "tool_preview=" + (.tool_preview | tojson) else empty end),
            (if (.query // "") != "" then "query=" + (.query | tojson) else empty end),
            (if (.summary // "") != "" then "summary=" + (.summary | tojson) else empty end),
            (if (.reason // "") != "" then "reason=" + .reason else empty end),
            (if (.trigger // "") != "" then "trigger=" + .trigger else empty end),
            (if (.permission_mode // "") != "" then "permission_mode=" + .permission_mode else empty end),
            (if (.error // "") != "" then "error=" + (.error | tojson) else empty end),
            (if (.session_title // "") != "" then "session_title=" + (.session_title | tojson) else empty end),
            (if .duration_ms != null then "duration_ms=" + (.duration_ms | tostring) else empty end)
        ] | join(" ")
    ' 2>/dev/null)
    [ -z "$fields" ] && fields="event="
    printf '%s EMIT  %s\n' "$ts" "$fields" >> "$logfile" 2>/dev/null || true
    _warp_log_update_symlink "$logfile"
}
