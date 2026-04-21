#!/bin/bash
# Warp notification utility using OSC escape sequences
# Usage: warp-notify.sh <title> <body>
#
# For structured Warp notifications, title should be "warp://cli-agent"
# and body should be a JSON string matching the cli-agent notification schema.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/should-use-structured.sh"

# Only emit notifications when we've confirmed the Warp build can render them.
if ! should_use_structured; then
    exit 0
fi

TITLE="${1:-Notification}"
BODY="${2:-}"

# Skip when the caller bailed (e.g. build_payload returned empty because the
# hook input had no session_id). Emitting an empty OSC would still clutter
# Warp's parser and the log.
[ -z "$BODY" ] && exit 0

# Record what we're about to emit BEFORE the tty write so the log captures the
# payload even if the tty write fails (e.g. headless / -p mode with no tty).
source "$SCRIPT_DIR/warp-log.sh"
log_emit "$TITLE" "$BODY"

# Find a writable TTY by walking the parent process chain (warpdotdev/
# claude-code-warp#19). Claude Code's hook subprocess frequently has no
# controlling terminal — writing to /dev/tty fails with
# "Device not configured" and the notification is silently lost.
# Walking PPID finds an ancestor that does have a real TTY (the user's
# actual terminal), typically 1–3 hops away.
_find_tty() {
    local pid=${PPID:-$$}
    local tty_val ppid_val dev
    local hops=0
    while [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 10 ]; do
        # Read tty and ppid in one ps call; trim all whitespace.
        read -r tty_val ppid_val < <(ps -o tty=,ppid= -p "$pid" 2>/dev/null)
        tty_val=$(printf '%s' "$tty_val" | tr -d '[:space:]')
        ppid_val=$(printf '%s' "$ppid_val" | tr -d '[:space:]')
        case "$tty_val" in
            ''|'?'|'??')
                ;;  # No usable tty at this level; keep climbing.
            /dev/*)
                dev="$tty_val"
                [ -w "$dev" ] && { printf '%s' "$dev"; return 0; }
                ;;
            *)
                dev="/dev/$tty_val"
                [ -w "$dev" ] && { printf '%s' "$dev"; return 0; }
                ;;
        esac
        [ -z "$ppid_val" ] && break
        pid=$ppid_val
        hops=$((hops + 1))
    done
    # Fallback — /dev/tty may or may not work, but we've exhausted options.
    printf '/dev/tty'
}

TTY_DEV=$(_find_tty)

# OSC 777 format: \033]777;notify;<title>;<body>\007
# Subshell ensures bash's own "Device not configured" complaint on a bad
# /dev/tty handle gets suppressed along with the printf's stderr.
( printf '\033]777;notify;%s;%s\007' "$TITLE" "$BODY" > "$TTY_DEV" ) 2>/dev/null || true
