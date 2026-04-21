# warp-v3

Side-by-side v3 testing fork of `warp@claude-code-warp`. Extends upstream with live per-tool state visibility (`PreToolUse` → `tool_start`), an always-firing `PostToolUse` that clears sidebar-blocked state for every tool, and a capability-gated path for v3-only event names so current stable Warp doesn't zombie-out on unknown events.

## What's different from upstream v2

| Fix | What it addresses |
|---|---|
| `session_start` emits minimal Gemini-shape payload on fresh tabs + follow-up synthetic `stop` | Warp's default state for a Claude Code `session_start` is "running" / In progress. Emitting a follow-up `stop` (with no `query` / `response` — build_payload strips empties so no "task completed" toast fires) transitions the row to "Done" instead. For resume / clear / compact, we send `session_start` with full enrichment since context is actually returning. **Note:** we tried zero-emission in v3.0.5 for parity with Gemini + Factory/Droid (which Warp auto-detects by binary name) — that broke Claude sidebar registration entirely because `agent:"claude"` has no built-in auto-detection path, so we need at least one OSC event to register the row. |
| `PostToolUse` gated on a `.blocked` marker | **R1 fix for stuck Blocked without re-introducing `#22`'s memory leak.** PermissionRequest drops a `$TMPDIR/warp-claude-$SID.blocked` marker; PostToolUse emits `tool_complete` only when the marker exists (clearing Blocked) or for state-transition tools (Bash/Edit/Write/MultiEdit/NotebookEdit/Agent). Auto-approved Read/Glob/Grep don't flood Warp with notifications. |
| New `PreToolUse` emits `tool_start` | Sidebar had no live per-tool signal between prompt and completion. |
| `build-payload.sh` strips empty enrichment fields | Warp interpreted `model:""` / `permission_mode:""` as "still initializing" and left the sidebar in-progress right after SessionStart. |
| TTY detection walks parent PID chain | Claude Code hook subprocesses frequently lack a controlling terminal — writing to `/dev/tty` failed with "Device not configured". Ports [`warpdotdev/claude-code-warp#19`](https://github.com/warpdotdev/claude-code-warp/pull/19) into the fork. |
| Hooks.json quotes `${CLAUDE_PLUGIN_ROOT}` | Paths with spaces (Windows `C:\Users\First Last\...`) previously broke every hook. Ports [`#26`](https://github.com/warpdotdev/claude-code-warp/pull/26). |
| Respects `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` | Users managing their own tab titles (kitty, tmux, shell hooks) no longer get overwritten by `prompt_submit`. Ports [`#24`](https://github.com/warpdotdev/claude-code-warp/issues/24). |
| `WARP_PLUGIN_DISABLE_PROJECT=1` opt-out | Skip the auto-derived `basename(cwd)` project label. Ports [`#23`](https://github.com/warpdotdev/claude-code-warp/pull/23). |
| `WARP_CLI_AGENT_V3_EVENTS=1` opt-in for v3 event names | Current stable Warp drops `session_end`, `tool_failed`, `permission_denied`, `subagent_*`, `compact_*`, `cwd_changed`. When unset, the adapter emits v2-compatible fallbacks so the sidebar state still moves. |
| Per-session OSC event log | Debuggable audit of every hook input and every OSC emit, cross-referenceable with the sidebar. |
| `-p` (headless) skips SessionStart/SessionEnd | Avoided sidebar flicker / premature archive for one-shot `claude -p` runs. |
| Stop / StopFailure / SubagentStop no longer `async:true` | Claude Code killed async hooks mid-execution in `-p` mode, so `tool_complete` / `stop` emissions silently dropped. |
| UTF-8-safe truncation | `query` / `response` / `tool_preview` truncations are now codepoint-aware, so a multi-byte char at the cut point doesn't produce invalid UTF-8. |
| `session_title` on `prompt_submit` | Sidebar row label reflects the actual first prompt instead of a generic "Claude Code". |
| `duration_ms` on `stop` | Wall-clock turn duration, computed from the UserPromptSubmit timestamp. |

## Installation

```bash
# From within Claude Code
/plugin marketplace add yigitkonur/claude-code-warp@testing/side-by-side-marketplace
/plugin install warp-v3@claude-code-warp-v3-testing
```

Runs side-by-side with `warp@claude-code-warp`. Disable one to avoid duplicate notifications:

```bash
/plugin disable warp@claude-code-warp
```

To roll back:

```bash
/plugin disable warp-v3@claude-code-warp-v3-testing
/plugin enable warp@claude-code-warp
```

## Configuration

Environment variables (all optional):

| Variable | Default | What it does |
|---|---|---|
| `WARP_CLI_AGENT_V3_EVENTS` | unset | Set to `1` once you've confirmed your Warp build understands v3 event names. When unset, v3-only events fall back to v2-compatible shapes (see below). |
| `WARP_KEEP_LOGS` | unset | Set to `1` to preserve per-session event logs past SessionEnd (for post-mortem). Default deletes them. |
| `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` | unset | Set to `1` to opt out of sending the prompt as a title-like field. Prevents the plugin from overwriting titles you manage yourself (kitty, tmux, shell hooks). Ports [`#24`](https://github.com/warpdotdev/claude-code-warp/issues/24). |
| `WARP_PLUGIN_DISABLE_PROJECT` | unset | Set to `1` to skip the auto-derived `project = basename(cwd)` field. Warp falls back to whatever tab title is already set. Ports [`#23`](https://github.com/warpdotdev/claude-code-warp/pull/23). |

### R5 fallback mapping (when `WARP_CLI_AGENT_V3_EVENTS` is unset)

| v3 event | v2 fallback |
|---|---|
| `session_end` | *(suppressed — accept v2's zombie-row behavior)* |
| `tool_failed` | `tool_complete` + `error` field |
| `permission_denied` | `tool_complete` (clears Blocked; semantically imperfect, visually correct) |
| `subagent_start` | `tool_start` with `tool_name: "Agent/<type>"` |
| `subagent_stop` | `tool_complete` with `tool_name: "Agent/<type>"` |
| `compact_start` / `compact_end` | *(suppressed)* |
| `cwd_changed` | *(suppressed — envelope's `project` field still updates on the next tool_complete)* |
| `tool_start` | *(emitted unconditionally — worst case Warp drops it, no regression)* |

## Debugging the sidebar

Every hook invocation writes a line to `${TMPDIR:-/tmp}/warp-claude-${SESSION_ID}.log`, and `/tmp/warp-claude-latest.log` is symlinked at the most recent file. `tail -f` that symlink to see live what the adapter emitted to Warp.

```bash
# terminal 1 — watch the event stream
tail -f /tmp/warp-claude-latest.log

# terminal 2 — drive Claude Code normally
claude
> read /tmp/foo.txt then edit it
```

Expected output shape, each line sub-second-timestamped:

```
[2026-04-21 10:20:15.125] HOOK=SessionStart    session_id=abc source=startup model=claude-opus-4-7
[2026-04-21 10:20:15.127] EMIT  event=session_start source=startup model=claude-opus-4-7
[2026-04-21 10:20:17.500] HOOK=UserPromptSubmit prompt="read /tmp/foo.txt then edit it"
[2026-04-21 10:20:17.502] EMIT  event=prompt_submit query="read /tmp/foo.txt then edit it" session_title="read /tmp/foo.txt then edit it"
[2026-04-21 10:20:18.100] HOOK=PreToolUse      tool_name=Read
[2026-04-21 10:20:18.102] EMIT  event=tool_start tool_name=Read tool_preview="/tmp/foo.txt"
[2026-04-21 10:20:18.800] HOOK=PermissionRequest tool_name=Read
[2026-04-21 10:20:18.802] EMIT  event=permission_request tool_name=Read summary="Wants to run Read: /tmp/foo.txt"
[2026-04-21 10:20:21.400] HOOK=PostToolUse     tool_name=Read
[2026-04-21 10:20:21.402] EMIT  event=tool_complete tool_name=Read
[2026-04-21 10:20:21.900] HOOK=PreToolUse      tool_name=Edit
[2026-04-21 10:20:21.902] EMIT  event=tool_start tool_name=Edit tool_preview="/tmp/foo.txt"
[2026-04-21 10:20:23.500] HOOK=PostToolUse     tool_name=Edit
[2026-04-21 10:20:23.502] EMIT  event=tool_complete tool_name=Edit tool_preview="/tmp/foo.txt"
[2026-04-21 10:20:24.100] HOOK=Stop
[2026-04-21 10:20:24.103] EMIT  event=stop query="..." duration_ms=6603
[2026-04-21 10:20:24.500] HOOK=SessionEnd      reason=logout
```

Cross-reference what you see in Warp's sidebar against what actually hit the stream. A missing `EMIT` line for a state you expected to see change indicates where the adapter dropped the event — a matcher filter, an early exit, a capability gate.

Pass `WARP_KEEP_LOGS=1` to keep logs past SessionEnd for post-mortem.

## Tests

```bash
cd plugins/warp-v3
bash tests/test-hooks.sh
```

Covers payload shape, protocol negotiation, routing, temp-file handoff, R4 empty-field stripping, R5 V3_EVENTS gate fallbacks, R7 UTF-8 truncation + session_id guard, R6 `-p` silence, log format, and the end-to-end event sequence for every new hook.

## License

MIT — see repo root.
