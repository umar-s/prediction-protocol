# Hook engineering — what the platform actually does, and the checklist

Verified on Claude Code 2.1.239 (2026-08-22) with a project-level
PreToolUse hook on `Bash` through `claude -p`, both with `--allowedTools
Bash` and with `--dangerously-skip-permissions`. Re-run
`tests/platform-probe.sh` at every release to see whether a row moved.

| hook output | effect |
|---|---|
| exit 0 + `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":…}}` | blocked; the reason is shown to the model |
| exit 0 + `permissionDecision: ask` | interactive: the permission prompt shows the reason; headless: blocked (nobody to answer) |
| exit 2 + stderr | blocked; stderr shown to the model |
| exit 1 + stderr | **the command runs** |
| exit 0 + invalid JSON | **the command runs** |
| the hook overruns its `timeout` | **the command runs** |
| exit 0, empty stdout | no opinion; the normal permission flow decides (this is not an allow) |

So the platform is **fail-open on a broken hook**, and "fail-closed" has to
be built into the script: an `ERR` trap that prints a deny and exits 2, an
inner deadline shorter than the `timeout` in `hooks.json` that turns an
overrun into a deny, one explicit path to a silent exit 0, no network, no
locks. Decisions compose across hooks as most-restrictive-wins
(`deny` > `defer` > `ask` > `allow`); this gate never emits `allow` — with a
receipt it answers `ask` (interactive) or stays silent (headless), so the
human click on a one-way door is never removed by a hook.

## What arrives on stdin

`session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode`,
`hook_event_name`, `tool_name`, `tool_input` (`command`, `description` for
Bash), `tool_use_id`; for a call made by a subagent also `agent_id` and
`agent_type` — session hooks **do** fire for subagent tool calls.
`permission_mode` reads `default` even under `--dangerously-skip-permissions`,
so it is not a mode signal.

## Environment of the hook process

`CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`
(`cli` interactive, `sdk-cli` for `claude -p`), `CLAUDE_PLUGIN_ROOT` for
plugin hooks (also usable as a placeholder inside the `command` string).
The gate derives its context from these: `agent_id` present → subagent;
entrypoint starting with `sdk` → headless; otherwise interactive (unknown
entrypoints are treated as interactive — a visible prompt is the safer
failure). No mode flag is exchanged between plugins.

## Checklist for any hook in this line

- Matcher is the literal tool name (`Bash`); a matcher with `.`/`*` is an
  unanchored JavaScript regex. MCP tools are `mcp__<server>__<tool>` and
  carry no `command` — out of scope here, stated in the SKILL. The platform
  also has a `PowerShell` tool: Windows is unsupported, stated, not ignored.
- `timeout` set explicitly in `hooks.json`; the script's own deadline is
  shorter; the overrun path is tested (`PP_DEADLINE=1 PP_TEST_SLEEP=3`).
- `export LC_ALL=C` before any comparison — `tr_TR` breaks case folding.
- Reach the script through `${CLAUDE_PLUGIN_ROOT}`, never an install prefix;
  never depend on `cwd` for state (the session id is the key).
- Parse stdin with `python3`, then `jq`, else answer `ask` ("cannot parse") —
  never silent. Test with synthetic stdin: every decision-table cell, a
  fixture **with** `agent_id`, malformed JSON, an empty PATH for parsers.
- Every error path ends in deny JSON or exit 2 **when the command is
  one-way**; an irrelevant command on a broken gate stays silent so one
  bug does not lock every project the owner opens.
- The word `allow` does not appear in the hook (lint grep).
- The version is in every reason; the platform table above is re-verified
  with `tests/platform-probe.sh` before a release.
- `PostToolUse` cannot block or undo — grading lives in the CLI, not in a
  hook.
