# Hook engineering — what the platform actually does, and the checklist

Verified on Claude Code 2.1.239 (2026-08-22) with a project-level
PreToolUse hook on `Bash` through `claude -p`, both with `--allowedTools
Bash` and with `--dangerously-skip-permissions`; re-verified unchanged on
2.1.300 (2026-10-15). Re-run `tests/platform-probe.sh` at every release to
see whether a row moved; the Codex table is further down.

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
- A deny record: every deny the gate or the state guard issues for a
  session whose state dir exists appends one line to `denies` there (utc,
  class, and the command's base64 exactly as the stdin parser produced it —
  a shell decode would drop trailing newlines; or `state-guard` and the
  refused path; or `gate-error` from the wrapper, and `unclassified` for an
  input that never parsed, both keyed by a runner's `PP_SESSION`).
  `predict status --json` returns them as `denies`: `[{ts, class,
  command_b64}]` — base64 keeps the bytes exact and the JSON pure ASCII; a
  line not in that shape counts as class `corrupt`. A deny leaves no trace
  in the platform's own output that a consumer can rely on — on Codex it is
  absent from `codex exec --json` and only in a log whose framing a command
  can imitate — so a loop's `gate_denies` comes from here. The hooks run
  outside the sandbox and a Codex model in `workspace-write` cannot write
  the state; an unsandboxed Claude shell can, as it can the rest of the
  state. Best-effort and decision-neutral: an unwritable record never
  changes a deny.
- The version is in every reason; the platform table above is re-verified
  with `tests/platform-probe.sh` before a release.
- `PostToolUse` cannot block or undo — grading lives in the CLI, not in a
  hook.
- `SessionStart` may append `export …` lines to `$CLAUDE_ENV_FILE`; they
  become the preamble of every later Bash call. That is how `PREDICT`
  reaches consumers (`hooks/session-env.sh`) — side-effect only, exit 0 always.
- On Codex an `ask` is a fail-open: never emit it there. The gate decides the
  harness per call (`pp_harness`: `turn_id`/`model` on stdin, `PLUGIN_ROOT`
  in the environment, `PP_HARNESS` as the override) and denies instead; a
  matching receipt passes silently. A file-edit guard matches `Edit|Write`
  on both platforms; on Codex the paths are the patch headers in
  `tool_input.command`, never the content.

## Codex CLI 0.162.1 (verified 2026-10-15, `tests/platform-probe.sh --codex`)

Same files, same JSON contract — the plugin's `hooks/hooks.json` is read as
is and matchers see the tool name and its aliases — different platform facts:

| hook output | effect |
|---|---|
| exit 0 + deny JSON | blocked; the reason reaches the model as "Command blocked by PreToolUse hook: …" |
| exit 0 + `permissionDecision: ask` | **not supported**: the run is marked Failed and **the command runs** |
| exit 2 + stderr | blocked; stderr is the reason |
| exit 1 · invalid JSON · exit 2 without stderr | Failed, **the command runs** |
| exit 0 + `hookSpecificOutput.additionalContext` (PreToolUse, SessionStart) | added to the model's context; plain stdout on SessionStart too |
| the hook overruns its `timeout` | Failed, **the command runs** (default 600 s when unset) |

**Stdin.** Common: `session_id`, `transcript_path` (the rollout `.jsonl`, may
be `null`), `cwd`, `hook_event_name`, `model`, `permission_mode`. PreToolUse
adds `turn_id` — a Codex extension and the gate's harness marker, Claude Code
never sends it — `tool_name`, `tool_use_id`, `tool_input`; `agent_id` and
`agent_type` arrive for spawned subagents. `permission_mode` is derived from
the approval policy: `never` → `bypassPermissions`, everything else →
`default`. `codex exec` always runs with approval `never` — a
`-c approval_policy=on-request` override still prints `approval: never` and
arrives as `bypassPermissions` (observed) — so every exec session is a
delegated session (silent outside the protocol, deny without a receipt,
silent with one); `default` arrives only from the TUI and the app, where the
gate's deny-instead-of-ask applies. The probe replays the platform's own
stdin with `permission_mode: default` through the gate for that row. Tool names:
the shell tool is `Bash` (`exec_command` too); a file edit is `apply_patch`
with `tool_input.command` = the patch text, selected by matchers
`apply_patch`, `Edit` or `Write`; MCP tools are `mcp__<server>__<tool>`;
`spawn_agent` also matches `Agent`.

**Environment of a plugin hook.** `PLUGIN_ROOT`, `PLUGIN_DATA`, and
`CLAUDE_PLUGIN_ROOT` / `CLAUDE_PLUGIN_DATA` for compatibility; no
`CLAUDE_ENV_FILE`, no entrypoint, no session id. Everything else is inherited
from the process that started `codex`: a Codex started from a Claude Code
shell carries `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID` and the rest
into its hooks and into the model's shell — which is why the harness is
decided from stdin and `PLUGIN_ROOT`, never from a `CLAUDE_*` name, and why
`pp_entrypoint` ignores `CLAUDE_CODE_ENTRYPOINT` on Codex. The model's shell
gets `CODEX_SESSION_ID` (equal to the hook's `session_id`), `CODEX_THREAD_ID`
and, inside the sandbox, `CODEX_SANDBOX_NETWORK_DISABLED=1`; nothing adds the
plugin's `bin/` to PATH — hence the context line from `session-env.sh`. The
sandbox is its own pid namespace (PID 1 is `codex`), so a shell cannot find
its session by process ancestry.

**Trust.** A non-managed hook runs only after `/hooks` → Trust. The record is
`[hooks.state."<plugin>@<marketplace>:hooks/hooks.json:<event>:<group>:<handler>"]
trusted_hash = "sha256:…"` in `~/.codex/config.toml` (user hooks are keyed
by the absolute path of their `hooks.json`), and the hash covers the
normalised identity, not the file: `{event_name: "pre_tool_use", matcher,
hooks: [{type, command as written (placeholders unexpanded), timeout
(default 600), async, statusMessage}]}` serialised as TOML, then JSON with
sorted keys, then SHA-256. A changed command, matcher or timeout is a new
hash: after every plugin update the hooks are silently skipped until trusted
again, which `predict report` shows as `gate: never`. Automation that
installed the plugin itself passes `--dangerously-bypass-hook-trust`; the
probe writes the records for its own lab home with the same algorithm.

Not observed on Codex: macOS; a Windows `commandWindows` handler.

