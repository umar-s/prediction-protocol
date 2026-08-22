# Hook engineering — what the platform actually does, and the checklist

Verified on Claude Code 2.1.239 (2026-08-22) with a project-level
PreToolUse hook on `Bash` through `claude -p`, both with `--allowedTools
Bash` and with `--dangerously-skip-permissions`. Re-run
`tests/platform-probe.sh` at every release to see whether a row moved.

| hook output | effect |
|---|---|
| exit 0 + `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":…}}` | blocked; the reason is shown to the model |
| exit 0 + `permissionDecision: ask` | interactive: the permission prompt shows the reason **and stops on the human even in auto mode** (observed 2.1.239, 2026-08-22 — the classifier does not answer a hook's ask); headless: blocked (nobody to answer) |
| exit 2 + stderr | blocked; stderr shown to the model |
| exit 1 + stderr | **the command runs** |
| exit 0 + invalid JSON | **the command runs** |
| the hook overruns its `timeout` | **the command runs** |
| exit 0, empty stdout | no opinion; the normal permission flow decides (this is not an allow) |

So the platform is **fail-open on a broken hook**, and "fail-closed" has to
be built into the script: an outer wrapper that needs nothing but bash to
answer deny (missing `lib/`, missing `python3`/`jq`, missing `timeout` — a
bash watchdog replaces it), a pure-bash vocabulary pre-filter so a
token-free command depends on nothing that can fail, an `ERR` trap that
prints a deny and exits 2, an inner deadline shorter than the `timeout` in
`hooks.json` that turns an overrun into a deny, every control byte escaped
in the JSON (an unescaped 0x1b is invalid JSON — the command runs), and a
deny that blocks by BOTH channels: deny JSON on stdout and the reason on
stderr with exit 2. Decisions compose across hooks as most-restrictive-wins
(`deny` > `defer` > `ask` > `allow`); this gate never emits `allow` — with a
receipt it answers `ask` (interactive) or stays silent (headless, and in a
delegated session — auto mode, `dontAsk`, `bypassPermissions`), so the human
click on a one-way door is never removed by a hook where a human is answering,
and never forced where the human chose a classifier instead.

## What arrives on stdin

`session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode`,
`hook_event_name`, `tool_name`, `tool_input` (`command`, `description` for
Bash), `tool_use_id`; for a call made by a subagent also `agent_id` and
`agent_type` — session hooks **do** fire for subagent tool calls.
`permission_mode` carries `acceptEdits`, `dontAsk` and `bypassPermissions`
as set by `--permission-mode`, but reads `default` under the bare
`--dangerously-skip-permissions` flag **and under auto mode** (verified
2.1.240), so on its own it is not a mode signal. The platform's own record is:
the session transcript at `transcript_path` carries
`{"type":"permission-mode","permissionMode":"auto"}` lines (and
`permissionMode` on `user` entries), appended on every toggle — the last
marker is the current mode. `pp_delegated` reads both; an unreadable
transcript means "not delegated" (the failure is a visible prompt).

## Environment of the hook process

`CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`
(`cli` interactive, `sdk-cli` for `claude -p`), `CLAUDE_PLUGIN_ROOT` for
plugin hooks (also usable as a placeholder inside the `command` string).
The gate derives its context from these: `agent_id` present → subagent;
entrypoint starting with `sdk` → headless; otherwise interactive (unknown
entrypoints are treated as interactive — a visible prompt is the safer
failure); a delegated permission mode turns the interactive `ask` rows silent
and leaves every deny in place. No mode flag is exchanged between plugins.

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
- Parse stdin with `python3`, then `jq`; if neither is there and the call
  carries a one-way token, deny ("cannot parse") — never silent. Test with
  synthetic stdin: every decision-table cell, a fixture **with** `agent_id`,
  malformed JSON, a PATH without parsers, a PATH without `timeout`, a
  command with a control byte (pipe the output through a JSON parser).
- Every error path ends in deny JSON or exit 2 **when the command is
  one-way**; an irrelevant command on a broken gate stays silent so one
  bug does not lock every project the owner opens.
- The word `allow` does not appear in the hook (word-match lint grep,
  comments excluded).
- A liveness stamp: the hook touches `hook-seen` in the session's state dir
  when it exists, so `predict status`/`report` can say whether the platform
  ever fired it. `predict on`'s selftest proves the script, not the
  registration.
- The version is in every reason; the platform table above is re-verified
  with `tests/platform-probe.sh` before a release.
- `PostToolUse` cannot block or undo — grading lives in the CLI, not in a
  hook.
- `SessionStart` may append `export …` lines to `$CLAUDE_ENV_FILE`; they
  become the preamble of every later Bash call. That is how `PREDICT`
  reaches consumers (`hooks/session-env.sh`) — side-effect only, exit 0 always.
