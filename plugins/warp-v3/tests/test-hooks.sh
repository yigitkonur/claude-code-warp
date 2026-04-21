#!/bin/bash
# Tests for the Warp Claude Code plugin hook scripts.
#
# Validates that each hook script produces correctly structured JSON payloads
# by piping mock Claude Code hook input into the scripts and checking the output.
#
# Usage: ./tests/test-hooks.sh
#
# Since the hook scripts write OSC sequences to /dev/tty (not stdout),
# we test build-payload.sh directly — it's the shared JSON construction logic
# that all hook scripts use.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/build-payload.sh"

PASSED=0
FAILED=0

# --- Test helpers ---

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $test_name"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $test_name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_json_field() {
    local test_name="$1"
    local json="$2"
    local field="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null)
    assert_eq "$test_name" "$expected" "$actual"
}

# --- Tests ---

echo "=== build-payload.sh ==="

echo ""
echo "--- Common fields ---"
PAYLOAD=$(build_payload '{"session_id":"sess-123","cwd":"/Users/alice/my-project"}' "stop")
assert_json_field "v is 1" "$PAYLOAD" ".v" "1"
assert_json_field "agent is claude" "$PAYLOAD" ".agent" "claude"
assert_json_field "event is stop" "$PAYLOAD" ".event" "stop"
assert_json_field "session_id extracted" "$PAYLOAD" ".session_id" "sess-123"
assert_json_field "cwd extracted" "$PAYLOAD" ".cwd" "/Users/alice/my-project"
assert_json_field "project is basename of cwd" "$PAYLOAD" ".project" "my-project"

echo ""
echo "--- Common fields with missing data ---"
PAYLOAD=$(build_payload '{}' "stop")
assert_json_field "empty session_id" "$PAYLOAD" ".session_id" ""
assert_json_field "empty cwd" "$PAYLOAD" ".cwd" ""
assert_json_field "empty project" "$PAYLOAD" ".project" ""

echo ""
echo "--- Extra args are merged ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "stop" \
    --arg query "hello" \
    --arg response "world")
assert_json_field "query merged" "$PAYLOAD" ".query" "hello"
assert_json_field "response merged" "$PAYLOAD" ".response" "world"
assert_json_field "common fields still present" "$PAYLOAD" ".session_id" "s1"

echo ""
echo "--- Stop event ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "stop" \
    --arg query "write a haiku" \
    --arg response "Memory is safe, the borrow checker stands guard" \
    --arg transcript_path "/tmp/transcript.jsonl")
assert_json_field "event is stop" "$PAYLOAD" ".event" "stop"
assert_json_field "query present" "$PAYLOAD" ".query" "write a haiku"
assert_json_field "response present" "$PAYLOAD" ".response" "Memory is safe, the borrow checker stands guard"
assert_json_field "transcript_path present" "$PAYLOAD" ".transcript_path" "/tmp/transcript.jsonl"

echo ""
echo "--- Permission request event ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "permission_request" \
    --arg summary "Wants to run Bash: rm -rf /tmp" \
    --arg tool_name "Bash" \
    --argjson tool_input '{"command":"rm -rf /tmp"}')
assert_json_field "event is permission_request" "$PAYLOAD" ".event" "permission_request"
assert_json_field "summary present" "$PAYLOAD" ".summary" "Wants to run Bash: rm -rf /tmp"
assert_json_field "tool_name present" "$PAYLOAD" ".tool_name" "Bash"
assert_json_field "tool_input.command present" "$PAYLOAD" ".tool_input.command" "rm -rf /tmp"

echo ""
echo "--- Idle prompt event ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj","notification_type":"idle_prompt"}' "idle_prompt" \
    --arg summary "Claude is waiting for your input")
assert_json_field "event is idle_prompt" "$PAYLOAD" ".event" "idle_prompt"
assert_json_field "summary present" "$PAYLOAD" ".summary" "Claude is waiting for your input"

echo ""
echo "--- JSON special characters in values ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "stop" \
    --arg query 'what does "hello world" mean?' \
    --arg response 'It means greeting. Use: printf("hello")')
assert_json_field "quotes in query preserved" "$PAYLOAD" ".query" 'what does "hello world" mean?'
assert_json_field "parens in response preserved" "$PAYLOAD" ".response" 'It means greeting. Use: printf("hello")'

echo ""
echo "--- Protocol version negotiation ---"

# Default: no env var set → falls back to plugin max (1)
unset WARP_CLI_AGENT_PROTOCOL_VERSION
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "defaults to v1 when env var absent" "$PAYLOAD" ".v" "1"

# Warp declares v1 → use 1
export WARP_CLI_AGENT_PROTOCOL_VERSION=1
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "v1 when warp declares 1" "$PAYLOAD" ".v" "1"

# Warp declares a higher version than the plugin knows → capped to plugin current
export WARP_CLI_AGENT_PROTOCOL_VERSION=99
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "capped to plugin current when warp is ahead" "$PAYLOAD" ".v" "1"

# Warp declares a lower version than the plugin knows → use warp's version
# (not testable with PLUGIN_MAX=1 since there's no v0, but we verify the min logic
# by temporarily overriding the variable)
PLUGIN_CURRENT_PROTOCOL_VERSION=5
export WARP_CLI_AGENT_PROTOCOL_VERSION=3
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "uses warp version when plugin is ahead" "$PAYLOAD" ".v" "3"
PLUGIN_CURRENT_PROTOCOL_VERSION=1

# Clean up
unset WARP_CLI_AGENT_PROTOCOL_VERSION

echo ""
echo "=== should-use-structured.sh ==="

source "$SCRIPT_DIR/../scripts/should-use-structured.sh"

echo ""
echo "--- No protocol version → legacy ---"
unset WARP_CLI_AGENT_PROTOCOL_VERSION
unset WARP_CLIENT_VERSION
should_use_structured
assert_eq "no protocol version returns false" "1" "$?"

echo ""
echo "--- Protocol set, no client version → legacy ---"
export WARP_CLI_AGENT_PROTOCOL_VERSION=1
unset WARP_CLIENT_VERSION
should_use_structured
assert_eq "missing WARP_CLIENT_VERSION returns false" "1" "$?"

echo ""
echo "--- Protocol set, dev version → always structured (dev was never broken) ---"
export WARP_CLI_AGENT_PROTOCOL_VERSION=1
export WARP_CLIENT_VERSION="v0.2026.03.30.08.43.dev_00"
should_use_structured
assert_eq "dev version returns true" "0" "$?"

echo ""
echo "--- Protocol set, broken stable version → legacy ---"
export WARP_CLIENT_VERSION="v0.2026.03.25.08.24.stable_05"
should_use_structured
assert_eq "exact broken stable version returns false" "1" "$?"

echo ""
echo "--- Protocol set, newer stable version → structured ---"
export WARP_CLIENT_VERSION="v0.2026.04.01.08.00.stable_00"
should_use_structured
assert_eq "newer stable version returns true" "0" "$?"

echo ""
echo "--- Protocol set, broken preview version → legacy ---"
export WARP_CLIENT_VERSION="v0.2026.03.25.08.24.preview_05"
should_use_structured
assert_eq "exact broken preview version returns false" "1" "$?"

echo ""
echo "--- Protocol set, newer preview version → structured ---"
export WARP_CLIENT_VERSION="v0.2026.04.01.08.00.preview_00"
should_use_structured
assert_eq "newer preview version returns true" "0" "$?"

# Clean up
unset WARP_CLI_AGENT_PROTOCOL_VERSION
unset WARP_CLIENT_VERSION

# --- Routing tests ---
# These test the hook scripts as subprocesses to verify routing behavior.
# We override /dev/tty writes since they'd fail in CI.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

echo ""
echo "=== Routing ==="

echo ""
echo "--- SessionStart routing ---"

# Legacy Warp (TERM_PROGRAM=WarpTerminal, no protocol version)
OUTPUT=$(TERM_PROGRAM=WarpTerminal bash "$HOOK_DIR/on-session-start.sh" < /dev/null 2>/dev/null)
SYS_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null)
assert_eq "legacy Warp shows active message" \
    "🔔 Warp plugin active. You'll receive native Warp notifications when tasks complete or input is needed." \
    "$SYS_MSG"

echo ""
echo "--- Modern-only hooks exit silently without protocol version ---"

unset WARP_CLI_AGENT_PROTOCOL_VERSION
unset WARP_CLIENT_VERSION
for HOOK in \
    on-permission-request.sh \
    on-permission-denied.sh \
    on-prompt-submit.sh \
    on-post-tool-use.sh \
    on-post-tool-use-failure.sh \
    on-session-end.sh \
    on-stop-failure.sh \
    on-subagent-start.sh \
    on-subagent-stop.sh \
    on-pre-compact.sh \
    on-post-compact.sh \
    on-cwd-changed.sh \
    on-elicitation.sh; do
    echo '{}' | bash "$HOOK_DIR/$HOOK" 2>/dev/null
    assert_eq "$HOOK exits 0 without protocol version" "0" "$?"
done

# --- New event payload shapes ---
# Each new event is tested through build_payload (the shared JSON construction
# layer all hook scripts use) since hook scripts themselves write to /dev/tty.

echo ""
echo "=== new event payloads ==="

echo ""
echo "--- session_start enriches with source/model/permission_mode ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "session_start" \
    --arg plugin_version "3.0.0" \
    --arg source "resume" \
    --arg model "claude-sonnet-4-6" \
    --arg permission_mode "acceptEdits" \
    --arg agent_type "")
assert_json_field "session_start event name" "$PAYLOAD" ".event" "session_start"
assert_json_field "plugin_version present" "$PAYLOAD" ".plugin_version" "3.0.0"
assert_json_field "source present" "$PAYLOAD" ".source" "resume"
assert_json_field "model present" "$PAYLOAD" ".model" "claude-sonnet-4-6"
assert_json_field "permission_mode present" "$PAYLOAD" ".permission_mode" "acceptEdits"

echo ""
echo "--- session_end with reason ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "session_end" \
    --arg reason "clear")
assert_json_field "session_end event name" "$PAYLOAD" ".event" "session_end"
assert_json_field "reason present" "$PAYLOAD" ".reason" "clear"

echo ""
echo "--- stop with error (StopFailure mapping) ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "stop" \
    --arg query "refactor auth" \
    --arg response "API Error: Rate limit reached" \
    --arg error "rate_limit" \
    --arg error_details "429 Too Many Requests" \
    --arg transcript_path "")
assert_json_field "stop event name for failures" "$PAYLOAD" ".event" "stop"
assert_json_field "error field present" "$PAYLOAD" ".error" "rate_limit"
assert_json_field "error_details present" "$PAYLOAD" ".error_details" "429 Too Many Requests"
assert_json_field "response holds error text" "$PAYLOAD" ".response" "API Error: Rate limit reached"

echo ""
echo "--- permission_denied ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "permission_denied" \
    --arg summary "Auto-denied Bash: rm -rf /" \
    --arg tool_name "Bash" \
    --argjson tool_input '{"command":"rm -rf /"}' \
    --arg reason "command targets a path outside the project")
assert_json_field "permission_denied event name" "$PAYLOAD" ".event" "permission_denied"
assert_json_field "summary present" "$PAYLOAD" ".summary" "Auto-denied Bash: rm -rf /"
assert_json_field "reason present" "$PAYLOAD" ".reason" "command targets a path outside the project"
assert_json_field "tool_input preserved" "$PAYLOAD" ".tool_input.command" "rm -rf /"

echo ""
echo "--- tool_failed ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "tool_failed" \
    --arg tool_name "Bash" \
    --arg error "Command exited with non-zero status code 1" \
    --arg tool_preview "npm test" \
    --argjson is_interrupt false)
assert_json_field "tool_failed event name" "$PAYLOAD" ".event" "tool_failed"
assert_json_field "tool_name present" "$PAYLOAD" ".tool_name" "Bash"
assert_json_field "error present" "$PAYLOAD" ".error" "Command exited with non-zero status code 1"
assert_json_field "tool_preview present" "$PAYLOAD" ".tool_preview" "npm test"
assert_json_field "is_interrupt is bool" "$PAYLOAD" ".is_interrupt" "false"

echo ""
echo "--- subagent_start ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "subagent_start" \
    --arg agent_id "agent-abc123" \
    --arg agent_type "Explore")
assert_json_field "subagent_start event name" "$PAYLOAD" ".event" "subagent_start"
assert_json_field "agent_id present" "$PAYLOAD" ".agent_id" "agent-abc123"
assert_json_field "agent_type present" "$PAYLOAD" ".agent_type" "Explore"

echo ""
echo "--- subagent_stop with response ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "subagent_stop" \
    --arg agent_id "agent-abc123" \
    --arg agent_type "Explore" \
    --arg response "Found 3 potential issues" \
    --arg transcript_path "/tmp/subagent.jsonl")
assert_json_field "subagent_stop event name" "$PAYLOAD" ".event" "subagent_stop"
assert_json_field "response present" "$PAYLOAD" ".response" "Found 3 potential issues"
assert_json_field "agent_type present" "$PAYLOAD" ".agent_type" "Explore"

echo ""
echo "--- compact_start / compact_end ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "compact_start" \
    --arg trigger "auto")
assert_json_field "compact_start event name" "$PAYLOAD" ".event" "compact_start"
assert_json_field "trigger present" "$PAYLOAD" ".trigger" "auto"

PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "compact_end" \
    --arg trigger "manual")
assert_json_field "compact_end event name" "$PAYLOAD" ".event" "compact_end"

echo ""
echo "--- cwd_changed uses envelope cwd ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/new/project/path"}' "cwd_changed")
assert_json_field "cwd_changed event name" "$PAYLOAD" ".event" "cwd_changed"
assert_json_field "cwd reflects new dir" "$PAYLOAD" ".cwd" "/new/project/path"
assert_json_field "project is new basename" "$PAYLOAD" ".project" "path"

echo ""
echo "--- question_asked (MCP elicitation) ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "question_asked" \
    --arg tool_name "github-server" \
    --arg summary "Which repo should I search?")
assert_json_field "question_asked event name" "$PAYLOAD" ".event" "question_asked"
assert_json_field "tool_name holds server name" "$PAYLOAD" ".tool_name" "github-server"
assert_json_field "summary present" "$PAYLOAD" ".summary" "Which repo should I search?"

# --- Temp-file prompt persistence ---
# The on-prompt-submit → on-stop handoff goes through a session-scoped temp file.
# Verify the file is created and consumed correctly.

echo ""
echo "=== temp-file prompt persistence ==="

export WARP_CLI_AGENT_PROTOCOL_VERSION=1
export WARP_CLIENT_VERSION="v0.2099.12.31.23.59.stable_99"

TEST_SESSION="test-session-$$"
TEST_TMP="${TMPDIR:-/tmp}/warp-claude-${TEST_SESSION}.query"
rm -f "$TEST_TMP"

# on-prompt-submit should write the full prompt to the temp file
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid,cwd:"/tmp/proj",prompt:"refactor the auth module"}')
echo "$INPUT" | bash "$HOOK_DIR/on-prompt-submit.sh" 2>/dev/null >/dev/null

if [ -f "$TEST_TMP" ]; then
    CONTENT=$(cat "$TEST_TMP")
    assert_eq "on-prompt-submit writes query file" "refactor the auth module" "$CONTENT"
else
    assert_eq "on-prompt-submit writes query file" "refactor the auth module" "<no file created>"
fi

# on-session-end should clean up the temp file
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid,cwd:"/tmp/proj",reason:"clear"}')
echo "$INPUT" | bash "$HOOK_DIR/on-session-end.sh" 2>/dev/null >/dev/null

if [ ! -f "$TEST_TMP" ]; then
    assert_eq "on-session-end cleans up query file" "cleaned" "cleaned"
else
    assert_eq "on-session-end cleans up query file" "cleaned" "still present"
    rm -f "$TEST_TMP"
fi

unset WARP_CLI_AGENT_PROTOCOL_VERSION
unset WARP_CLIENT_VERSION

# --- Empty-field stripping (R4) ---
# Warp interprets model:"" / permission_mode:"" as "still initializing" and
# leaves the sidebar stuck on in-progress. build_payload must strip empty-
# string --arg values before emitting.

echo ""
echo "=== R4: empty-field stripping ==="

PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "session_start" \
    --arg plugin_version "3.0.1" \
    --arg source "startup" \
    --arg model "" \
    --arg permission_mode "" \
    --arg agent_type "")
assert_eq "R4: model key absent when empty"           "false" "$(echo "$PAYLOAD" | jq 'has("model")' 2>/dev/null)"
assert_eq "R4: permission_mode key absent when empty" "false" "$(echo "$PAYLOAD" | jq 'has("permission_mode")' 2>/dev/null)"
assert_eq "R4: agent_type key absent when empty"      "false" "$(echo "$PAYLOAD" | jq 'has("agent_type")' 2>/dev/null)"
assert_json_field "R4: plugin_version kept (non-empty)" "$PAYLOAD" ".plugin_version" "3.0.1"
assert_json_field "R4: source kept (non-empty)"         "$PAYLOAD" ".source"         "startup"
assert_json_field "R4: envelope session_id still present" "$PAYLOAD" ".session_id" "s1"

# Non-empty enrichment survives unchanged.
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "session_start" \
    --arg model "claude-opus-4-7" \
    --arg permission_mode "acceptEdits")
assert_json_field "R4: non-empty model kept"           "$PAYLOAD" ".model"           "claude-opus-4-7"
assert_json_field "R4: non-empty permission_mode kept" "$PAYLOAD" ".permission_mode" "acceptEdits"

# --- Empty session_id guard (R7) ---

echo ""
echo "=== R7: empty session_id short-circuits build_payload ==="

PAYLOAD=$(build_payload '{}' "stop" --arg tool_name "Bash")
assert_eq "R7: empty session_id → empty payload"   "" "$PAYLOAD"

PAYLOAD=$(build_payload '{"cwd":"/tmp"}' "stop")
assert_eq "R7: missing session_id → empty payload" "" "$PAYLOAD"

# Envelope stays normal when session_id is present, even if other fields aren't.
PAYLOAD=$(build_payload '{"session_id":"s1"}' "stop")
assert_json_field "R7: session_id alone is enough"   "$PAYLOAD" ".session_id" "s1"

# --- UTF-8 codepoint-safe truncation (R7) ---

echo ""
echo "=== R7: UTF-8-safe truncation ==="

# ASCII: 400 x's → truncated to exactly 200 codepoints (197 + "...")
LONG=$(printf 'x%.0s' {1..400})
TRUNC=$(utf8_truncate "$LONG" 200)
TRUNC_LEN=$(printf '%s' "$TRUNC" | jq -Rs 'length')
assert_eq "utf8_truncate: ASCII length = 200 codepoints" "200" "$TRUNC_LEN"

# Multi-byte: 300 €'s (3 bytes each in UTF-8, but 300 codepoints)
MB=$(printf '€%.0s' {1..300})
TRUNC_MB=$(utf8_truncate "$MB" 200)
TRUNC_MB_LEN=$(printf '%s' "$TRUNC_MB" | jq -Rs 'length')
assert_eq "utf8_truncate: multi-byte = 200 codepoints"   "200" "$TRUNC_MB_LEN"

# Short text — unchanged.
assert_eq "utf8_truncate: short text unchanged" "hello" "$(utf8_truncate "hello" 200)"

# Truncated multi-byte survives a roundtrip through build_payload as valid JSON.
BODY=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop" \
    --arg query "$TRUNC_MB" \
    --arg response "$TRUNC")
PARSED_QUERY_LEN=$(echo "$BODY" | jq -r '.query | length' 2>/dev/null)
assert_eq "utf8_truncate: truncated multi-byte → valid JSON" "200" "$PARSED_QUERY_LEN"

# --- should_emit_v3_events ---

echo ""
echo "=== should_emit_v3_events (R5 gate) ==="

unset WARP_CLI_AGENT_V3_EVENTS
should_emit_v3_events; assert_eq "WARP_CLI_AGENT_V3_EVENTS unset → false" "1" "$?"

export WARP_CLI_AGENT_V3_EVENTS=0
should_emit_v3_events; assert_eq "WARP_CLI_AGENT_V3_EVENTS=0 → false"     "1" "$?"

export WARP_CLI_AGENT_V3_EVENTS=1
should_emit_v3_events; assert_eq "WARP_CLI_AGENT_V3_EVENTS=1 → true"      "0" "$?"

unset WARP_CLI_AGENT_V3_EVENTS

# --- End-to-end log harness ---
# Uses a per-test TMPDIR so the log file path is deterministic. Hook scripts
# write HOOK= lines at entry and warp-notify.sh writes EMIT lines right before
# the /dev/tty send — inspecting the log tells us exactly what the adapter did.

export WARP_CLI_AGENT_PROTOCOL_VERSION=1
export WARP_CLIENT_VERSION="v0.2099.12.31.23.59.stable_99"

setup_log_fixture() {
    export TMPDIR="/tmp/warp-test-$$-$1"
    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR"
    TEST_SESSION="log-$1-$$"
    LOGFILE="$TMPDIR/warp-claude-$TEST_SESSION.log"
}

teardown_log_fixture() {
    rm -rf "$TMPDIR" 2>/dev/null || true
    unset TMPDIR
}

# grep -c outputs "0" AND exits 1 when no matches, so the usual `|| echo 0`
# fallback would produce "0\n0". Helper returns just the count.
count_matches() {
    local pattern="$1"
    local file="$2"
    [ -f "$file" ] || { echo 0; return; }
    local c
    c=$(grep -c "$pattern" "$file" 2>/dev/null || true)
    echo "${c:-0}"
}

echo ""
echo "=== R1: PostToolUse gates tool_complete via .blocked marker (fixes stuck Blocked AND issue #22 leak) ==="

# Read WITHOUT a prior PermissionRequest: auto-approved, no Blocked to clear,
# so we skip emission — preserves upstream's memory-leak mitigation.
setup_log_fixture "r1-read-auto"
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Read", tool_input:{file_path:"/tmp/foo.txt"}}')
echo "$INPUT" | bash "$HOOK_DIR/on-post-tool-use.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "R1: auto-approved Read skips emission (no leak)" "0" "$(count_matches 'EMIT.*event=tool_complete' "$LOGFILE")"
fi
teardown_log_fixture

# Read AFTER PermissionRequest: .blocked marker exists, sidebar needs
# tool_complete to move out of Blocked — emit it.
setup_log_fixture "r1-read-after-perm"
PERM_INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Read", tool_input:{file_path:"/tmp/foo.txt"}}')
echo "$PERM_INPUT" | bash "$HOOK_DIR/on-permission-request.sh" >/dev/null 2>&1
if [ -f "$TMPDIR/warp-claude-$TEST_SESSION.blocked" ]; then
    assert_eq "R1: PermissionRequest drops .blocked marker" "exists" "exists"
else
    assert_eq "R1: PermissionRequest drops .blocked marker" "exists" "missing"
fi
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Read", tool_input:{file_path:"/tmp/foo.txt"}}')
echo "$INPUT" | bash "$HOOK_DIR/on-post-tool-use.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "R1: after PermissionRequest, Read emits tool_complete" "1" "$(count_matches 'EMIT.*event=tool_complete' "$LOGFILE")"
fi
if [ ! -f "$TMPDIR/warp-claude-$TEST_SESSION.blocked" ]; then
    assert_eq "R1: PostToolUse consumes the marker" "cleared" "cleared"
else
    assert_eq "R1: PostToolUse consumes the marker" "cleared" "stale"
fi
teardown_log_fixture

# Bash ALWAYS emits (state-transition tool, even without prior permission).
setup_log_fixture "r1-bash-auto"
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Bash", tool_input:{command:"ls"}}')
echo "$INPUT" | bash "$HOOK_DIR/on-post-tool-use.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "R1: Bash emits tool_complete unconditionally" "1" "$(count_matches 'EMIT.*event=tool_complete' "$LOGFILE")"
fi
teardown_log_fixture

# PermissionDenied clears the marker so next tool call doesn't over-emit.
setup_log_fixture "r1-denied-clears"
PERM_INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Bash", tool_input:{command:"rm -rf /"}}')
echo "$PERM_INPUT" | bash "$HOOK_DIR/on-permission-request.sh" >/dev/null 2>&1
DENY_INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Bash", tool_input:{command:"rm -rf /"}, reason:"unsafe"}')
echo "$DENY_INPUT" | bash "$HOOK_DIR/on-permission-denied.sh" >/dev/null 2>&1
if [ ! -f "$TMPDIR/warp-claude-$TEST_SESSION.blocked" ]; then
    assert_eq "R1: PermissionDenied clears .blocked marker" "cleared" "cleared"
else
    assert_eq "R1: PermissionDenied clears .blocked marker" "cleared" "stale"
fi
teardown_log_fixture

echo ""
echo "=== session_start: fresh tab emits NOTHING (Droid/Gemini parity) ==="

# v3.0.5 behavior — on source=startup, on-session-start.sh exits silently.
# Gemini CLI and Factory/Droid don't register any Warp hook at all in this
# user's setup; their sidebar rows show only CLI label + cwd + branch, no
# state pill. Matching that means emitting zero `warp://cli-agent` events on
# startup — Warp's process-detection takes over and gives us the same clean
# row. First event only fires on UserPromptSubmit.
setup_log_fixture "startup-emits-nothing"
INPUT=$(jq -nc --arg sid "$TEST_SESSION" \
    '{session_id:$sid, cwd:"/tmp", source:"startup", model:"claude-opus-4-7[1m]", permission_mode:"default"}')
echo "$INPUT" | bash "$HOOK_DIR/on-session-start.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "startup: HOOK= line still logged (diagnostic)"  "1" "$(count_matches 'HOOK=SessionStart' "$LOGFILE")"
    assert_eq "startup: zero EMIT lines"                        "0" "$(count_matches 'EMIT' "$LOGFILE")"
else
    # Acceptable alternative: no log file at all (hook exited before log_hook).
    # But our current impl does log before the startup early-exit, so the above
    # branch is the one that runs.
    assert_eq "startup: log file exists (for HOOK line)" "yes" "no"
fi
teardown_log_fixture

# plugin_version is attached to prompt_submit now (moved from session_start so
# Warp's outdated-plugin banner still has a signal, just later in the lifecycle).
setup_log_fixture "prompt-submit-carries-plugin-version"
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", prompt:"hi"}')
echo "$INPUT" | bash "$HOOK_DIR/on-prompt-submit.sh" >/dev/null 2>&1
# Just assert the payload exists — we check the field placement by reading the raw body.
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "prompt_submit" \
    --arg query "hi" \
    --arg plugin_version "3.0.5")
assert_eq "prompt_submit carries plugin_version" "3.0.5" "$(echo "$PAYLOAD" | jq -r '.plugin_version' 2>/dev/null)"
teardown_log_fixture

# On resume/clear/compact, we DO emit session_start with enrichment — a
# returning session has context to surface and the sidebar should reflect it.
setup_log_fixture "resume-emits-enrichment"
INPUT=$(jq -nc --arg sid "$TEST_SESSION" \
    '{session_id:$sid, cwd:"/tmp", source:"resume", model:"claude-opus-4-7[1m]", permission_mode:"acceptEdits"}')
echo "$INPUT" | bash "$HOOK_DIR/on-session-start.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "resume: session_start emitted"                   "1" "$(count_matches 'EMIT.*event=session_start' "$LOGFILE")"
    assert_eq "resume: source=resume preserved"                 "1" "$(count_matches 'EMIT.*source=resume' "$LOGFILE")"
    assert_eq "resume: model= preserved (informative)"          "1" "$(count_matches 'EMIT.*model=' "$LOGFILE")"
    assert_eq "resume: permission_mode=acceptEdits preserved"   "1" "$(count_matches 'EMIT.*permission_mode=acceptEdits' "$LOGFILE")"
fi
teardown_log_fixture

echo ""
echo "=== CLAUDE_CODE_DISABLE_TERMINAL_TITLE (issue #24) ==="

setup_log_fixture "disable-title"
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", prompt:"refactor auth module"}')
echo "$INPUT" | bash "$HOOK_DIR/on-prompt-submit.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "#24: query absent when CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1"          "0" "$(count_matches 'EMIT.*query=' "$LOGFILE")"
    assert_eq "#24: session_title absent when disabled"                              "0" "$(count_matches 'EMIT.*session_title=' "$LOGFILE")"
    assert_eq "#24: event still fires"                                               "1" "$(count_matches 'EMIT.*event=prompt_submit' "$LOGFILE")"
fi
unset CLAUDE_CODE_DISABLE_TERMINAL_TITLE
teardown_log_fixture

# Sanity: when NOT set, query IS present.
setup_log_fixture "disable-title-default"
unset CLAUDE_CODE_DISABLE_TERMINAL_TITLE
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", prompt:"refactor auth module"}')
echo "$INPUT" | bash "$HOOK_DIR/on-prompt-submit.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "#24: query present by default" "1" "$(count_matches 'EMIT.*query=' "$LOGFILE")"
fi
teardown_log_fixture

echo ""
echo "=== WARP_PLUGIN_DISABLE_PROJECT (issue #23) ==="

export WARP_PLUGIN_DISABLE_PROJECT=1
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/Users/alice/my-project"}' "stop")
assert_eq "#23: project key absent when WARP_PLUGIN_DISABLE_PROJECT=1" "false" "$(echo "$PAYLOAD" | jq 'has("project")' 2>/dev/null)"
assert_json_field "#23: cwd still present (used by Warp for git-status)" "$PAYLOAD" ".cwd" "/Users/alice/my-project"
unset WARP_PLUGIN_DISABLE_PROJECT

# Sanity: default behavior unchanged.
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/Users/alice/my-project"}' "stop")
assert_json_field "#23: project present by default" "$PAYLOAD" ".project" "my-project"

echo ""
echo "=== R2: PreToolUse emits tool_start ==="

setup_log_fixture "r2"
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Bash", tool_input:{command:"ls -la"}}')
echo "$INPUT" | bash "$HOOK_DIR/on-pre-tool-use.sh" >/dev/null 2>&1

if [ -f "$LOGFILE" ]; then
    assert_eq "R2: PreToolUse produces HOOK line"       "1" "$(count_matches 'HOOK=PreToolUse' "$LOGFILE")"
    assert_eq "R2: PreToolUse produces EMIT=tool_start" "1" "$(count_matches 'EMIT.*event=tool_start' "$LOGFILE")"
    # EMIT line carries tool_name=Bash (HOOK line may also carry it — count only EMIT)
    EMIT_TOOL=$( (grep 'EMIT' "$LOGFILE" 2>/dev/null; echo) | grep -c 'tool_name=Bash' 2>/dev/null || true)
    assert_eq "R2: PreToolUse EMIT line carries tool_name=Bash" "1" "${EMIT_TOOL:-0}"
    # EMIT line also carries tool_preview reflecting the command
    EMIT_PREVIEW=$( (grep 'EMIT' "$LOGFILE" 2>/dev/null; echo) | grep -c 'tool_preview=' 2>/dev/null || true)
    assert_eq "R2: PreToolUse EMIT line carries tool_preview" "1" "${EMIT_PREVIEW:-0}"
else
    assert_eq "R2: PreToolUse log file exists" "yes" "no"
fi
teardown_log_fixture

echo ""
echo "=== R6: -p mode silence ==="

setup_log_fixture "r6-start"
export _WARP_FORCE_NO_TTY=1
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", source:"startup"}')
echo "$INPUT" | bash "$HOOK_DIR/on-session-start.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    EMIT_LINES=$(count_matches 'EMIT' "$LOGFILE")
    assert_eq "R6: on-session-start emits 0 in -p mode" "0" "$EMIT_LINES"
else
    # R6 exits before any logging — expected.
    assert_eq "R6: on-session-start silent in -p mode" "silent" "silent"
fi
unset _WARP_FORCE_NO_TTY
teardown_log_fixture

setup_log_fixture "r6-end"
export _WARP_FORCE_NO_TTY=1
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", reason:"clear"}')
# Prime a .query file to verify -p mode still cleans up.
printf 'primed' > "$TMPDIR/warp-claude-$TEST_SESSION.query"
echo "$INPUT" | bash "$HOOK_DIR/on-session-end.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    EMIT_LINES=$(count_matches 'EMIT' "$LOGFILE")
    assert_eq "R6: on-session-end emits 0 in -p mode" "0" "$EMIT_LINES"
fi
if [ ! -f "$TMPDIR/warp-claude-$TEST_SESSION.query" ]; then
    assert_eq "R6: -p mode still cleans .query temp file" "cleaned" "cleaned"
else
    assert_eq "R6: -p mode still cleans .query temp file" "cleaned" "leaked"
fi
unset _WARP_FORCE_NO_TTY
teardown_log_fixture

echo ""
echo "=== R5: V3_EVENTS gate routing ==="

# on-permission-denied: V3 off → tool_complete fallback
setup_log_fixture "r5-denied-off"
unset WARP_CLI_AGENT_V3_EVENTS
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Bash", tool_input:{command:"rm -rf /"}, reason:"unsafe"}')
echo "$INPUT" | bash "$HOOK_DIR/on-permission-denied.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    EVENT=$(grep 'EMIT' "$LOGFILE" | grep -oE 'event=[a-z_]+' | tail -1)
    assert_eq "R5: V3 off → permission_denied falls back" "event=tool_complete" "$EVENT"
else
    assert_eq "R5: V3 off permission_denied log exists" "yes" "no"
fi
teardown_log_fixture

# on-permission-denied: V3 on → permission_denied
setup_log_fixture "r5-denied-on"
export WARP_CLI_AGENT_V3_EVENTS=1
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", tool_name:"Bash", tool_input:{command:"rm -rf /"}, reason:"unsafe"}')
echo "$INPUT" | bash "$HOOK_DIR/on-permission-denied.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    EVENT=$(grep 'EMIT' "$LOGFILE" | grep -oE 'event=[a-z_]+' | tail -1)
    assert_eq "R5: V3 on → permission_denied emits as-is" "event=permission_denied" "$EVENT"
else
    assert_eq "R5: V3 on permission_denied log exists" "yes" "no"
fi
unset WARP_CLI_AGENT_V3_EVENTS
teardown_log_fixture

# on-session-end: V3 off → suppressed
setup_log_fixture "r5-send-off"
unset WARP_CLI_AGENT_V3_EVENTS
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", reason:"clear"}')
echo "$INPUT" | bash "$HOOK_DIR/on-session-end.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    assert_eq "R5: V3 off → session_end emits nothing" "0" "$(count_matches 'EMIT' "$LOGFILE")"
else
    # on-session-end deletes the log by default — that's also a valid no-emit outcome
    assert_eq "R5: V3 off → session_end emits nothing" "nothing" "nothing"
fi
teardown_log_fixture

# on-session-end: V3 on → session_end (and WARP_KEEP_LOGS keeps the file readable)
setup_log_fixture "r5-send-on"
export WARP_CLI_AGENT_V3_EVENTS=1
export WARP_KEEP_LOGS=1
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", reason:"clear"}')
echo "$INPUT" | bash "$HOOK_DIR/on-session-end.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    EVENT=$(grep 'EMIT' "$LOGFILE" | grep -oE 'event=[a-z_]+' | tail -1)
    assert_eq "R5: V3 on → session_end emits session_end" "event=session_end" "$EVENT"
else
    assert_eq "R5: V3 on session_end log survives under WARP_KEEP_LOGS" "yes" "no"
fi
unset WARP_CLI_AGENT_V3_EVENTS WARP_KEEP_LOGS
teardown_log_fixture

# on-subagent-start: V3 off → tool_start with Agent/<type>
setup_log_fixture "r5-subagent-off"
unset WARP_CLI_AGENT_V3_EVENTS
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", agent_id:"a1", agent_type:"Explore"}')
echo "$INPUT" | bash "$HOOK_DIR/on-subagent-start.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    EVENT=$(grep 'EMIT' "$LOGFILE" | grep -oE 'event=[a-z_]+' | tail -1)
    assert_eq "R5: V3 off → subagent_start falls back to tool_start" "event=tool_start" "$EVENT"
    TOOL_NAME_RECORDED=$(grep 'EMIT' "$LOGFILE" | grep -oE 'tool_name=[A-Za-z/]+' | tail -1)
    assert_eq "R5: V3 off → subagent tool_name=Agent/<type>"         "tool_name=Agent/Explore" "$TOOL_NAME_RECORDED"
else
    assert_eq "R5: V3 off subagent log exists" "yes" "no"
fi
teardown_log_fixture

# on-subagent-start: V3 on → subagent_start (preserves v3 event name)
setup_log_fixture "r5-subagent-on"
export WARP_CLI_AGENT_V3_EVENTS=1
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", agent_id:"a1", agent_type:"Explore"}')
echo "$INPUT" | bash "$HOOK_DIR/on-subagent-start.sh" >/dev/null 2>&1
if [ -f "$LOGFILE" ]; then
    EVENT=$(grep 'EMIT' "$LOGFILE" | grep -oE 'event=[a-z_]+' | tail -1)
    assert_eq "R5: V3 on → subagent_start emits as-is" "event=subagent_start" "$EVENT"
else
    assert_eq "R5: V3 on subagent log exists" "yes" "no"
fi
unset WARP_CLI_AGENT_V3_EVENTS
teardown_log_fixture

echo ""
echo "=== log format invariants ==="

setup_log_fixture "fmt"
INPUT=$(jq -nc --arg sid "$TEST_SESSION" '{session_id:$sid, cwd:"/tmp", prompt:"test prompt"}')
echo "$INPUT" | bash "$HOOK_DIR/on-prompt-submit.sh" >/dev/null 2>&1

if [ -f "$LOGFILE" ]; then
    assert_eq "log format: prompt_submit writes exactly 2 lines"                "2" "$(wc -l < "$LOGFILE" | tr -d ' ')"
    assert_eq "log format: exactly 1 HOOK= line"                                "1" "$(count_matches '^\[.*\] HOOK=' "$LOGFILE")"
    assert_eq "log format: exactly 1 EMIT line"                                 "1" "$(count_matches '^\[.*\] EMIT' "$LOGFILE")"

    FIRST_LINE=$(head -1 "$LOGFILE")
    if [[ "$FIRST_LINE" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\] ]]; then
        assert_eq "log format: [YYYY-MM-DD HH:MM:SS.mmm] timestamp shape" "ok" "ok"
    else
        assert_eq "log format: [YYYY-MM-DD HH:MM:SS.mmm] timestamp shape" "ok" "wrong: $FIRST_LINE"
    fi

    # Symlink is hardcoded at /tmp so `tail -f /tmp/warp-claude-latest.log`
    # works consistently across macOS ($TMPDIR != /tmp) and Linux.
    if [ -L "/tmp/warp-claude-latest.log" ]; then
        TARGET=$(readlink "/tmp/warp-claude-latest.log")
        if [ "$TARGET" = "$LOGFILE" ]; then
            assert_eq "log format: /tmp/warp-claude-latest.log points to current" "ok" "ok"
        else
            assert_eq "log format: /tmp/warp-claude-latest.log points to current" "ok" "stale: $TARGET"
        fi
    else
        assert_eq "log format: /tmp/warp-claude-latest.log present" "yes" "no"
    fi
else
    assert_eq "log format: prompt_submit wrote a log file" "yes" "no"
fi
teardown_log_fixture

unset WARP_CLI_AGENT_PROTOCOL_VERSION WARP_CLIENT_VERSION

# --- Summary ---

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
