# Changelog

All notable changes to this plugin. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). The single source of the version is
`plugins/prediction-protocol/.claude-plugin/plugin.json`.

## [1.2.0] — 2026-10-16

The deny record. A deny used to leave no trace a consumer could rely on, so
loop-foundry's runner parsed each harness's output for it — and on Codex a
hook deny is absent from `codex exec --json` and only in a stderr log whose
multi-line entries a command can imitate (loop-foundry 1.2.0's review,
five rounds, ended there). The fix belongs here, where the deny is decided.

### Added
- Every deny the gate or the state guard issues for a session whose state
  dir exists appends one line to `denies` in that dir: utc, class, and the
  command's base64 **as the stdin parser produced it** (never decoded and
  re-encoded: a shell decode drops trailing newlines); the state guard writes
  `state-guard` and the refused path; the outer wrapper writes `gate-error`
  when the gate overruns its deadline or fails, and an input that never
  parsed is recorded as `unclassified` — both keyed by a runner's
  `PP_SESSION`, which the gate now resolves before it reads stdin. The hooks
  run outside any sandbox; a Codex model in `workspace-write` cannot write
  the state (observed). `pp_note_deny` is best-effort and decision-neutral —
  an unwritable record never changes a deny (control).
- `predict status --json` returns them as `denies` — `[{ts, class,
  command_b64}]`: the command's exact bytes, and pure ASCII, so the JSON is
  valid whatever the file holds. The reader takes physical lines and splits
  on tabs itself; a line not in the shape `utc<TAB>class<TAB>base64` counts
  as class `corrupt` with its fields emptied — a deny is never dropped. The
  text status prints `denies=N`.
- `references/hook-engineering.md`: the deny record next to the liveness
  stamp; README / README.ru: loop-foundry reads a tick's denies from status.
- 21 controls (200): the record for a gate deny; byte-exact round trips of a
  command with a newline, a tab and quotes and of one ending in `\n\n`; the
  state guard keyed by `PP_SESSION`, by a compact stdin session id and by one
  spread over JSON whitespace; an unparsable input and a deadline overrun
  recorded under `PP_SESSION`; nothing written outside the protocol; damaged
  lines (tabs only, invalid UTF-8, bad base64, no tabs) counted as `corrupt` with the
  JSON intact; an unwritable record leaving the deny intact; a malformed
  `active` value; a pretty-printed `apply_patch` refused; a file of one NUL,
  a NUL inside the base64 and base64 outside the full grammar (`A`, `=`,
  `A==`, `YQ`) counted as `corrupt`. Lint pins each rule.

### Fixed
- The state guard matched `"file_path":"…"` and `"tool_name":"apply_patch"`
  only in compact JSON: a harness that put whitespace around the colon would
  have walked an edit of the protocol's state past it. It now accepts any
  JSON whitespace there (Claude Code and Codex 0.162.1 send compact JSON, so
  no observed run was affected).
- `predict status --json` printed the raw `active` value; anything but `0`
  or `1` (a hand-edited state) made the output invalid JSON. It now reads as
  `0` — not active.

### Known limitation (named, not fixed here)
- The state guard reads the target path from the stdin JSON text, not
  through a parser, so a symlink to the state or a JSON-escaped path passes
  it (a background security review of this release named it). It is a
  tripwire, not the boundary: on Codex the sandbox refuses the write anyway,
  and an unsandboxed Claude shell writes the state directly. A JSON parse
  with `realpath` resolution is a candidate for the next patch.

### Verified
- Live through Codex CLI 0.162.1 (`codex exec -s read-only`, the dev hooks
  trusted by hash in an isolated `CODEX_HOME`): `git push --force` under the
  protocol without a receipt was denied and `predict status --json` listed
  the deny with its class `vcs-force` and the exact command. `hooks.json` is
  unchanged — the Codex trust hashes of 1.1.0 still hold.

### Review record
Cross-reviewed by Codex through task-flow's `xreview.sh`. Round 1
(`4960708`, not ready): the reader and the gate's decode dropped trailing
newlines; tab-only lines were skipped and invalid UTF-8 broke the JSON; a
deny before stdin was parsed was not recorded though `PP_SESSION` was known;
the state guard's session regex took at most one space — all Required, all
fixed (the record keeps the parser's base64, `command_b64`, a tab-splitting
reader with `corrupt`, the early session dir, JSON whitespace in the guard,
which also exposed the compact-only path match above). The FYI on the
reader's cost is met by the single pass without per-field escaping. Round 2
(`74febc8`, not ready): bash `read` drops NUL, so a NUL-only file read as no
deny and a NUL inside the base64 was silently repaired; the base64 check
took the alphabet, not the grammar — both Required, fixed (bytes a record
never holds become \001 before the shell reads them, so the line is
`corrupt`; the full base64 grammar).

### Supply-chain self-check
`git diff v1.1.0..v1.2.0 -- plugins/`, added lines grepped for
`curl|wget|fetch|http`, `_API_KEY|process.env|~/.ssh`, `rm -rf`, `eval`,
`base64`. `rm -rf` — one hit, a command string the tests feed to the gate
(never executed). `eval` — one hit, `ast.literal_eval` in a test helper
reading an expected Python string literal. `base64` — fourteen hits, all
the deny record: the gate keeping the parser's encoding, the state guard
encoding a path, the reader's comments, the reference text, the tests. No
network, no credentials. The hooks now append to a file in the session's
own state dir — the only new write.

## [1.1.0] — 2026-10-15

The second harness. Codex CLI reads the same `hooks/hooks.json` with the
same JSON contract, so the plugin needed no second manifest — but four
platform facts differ, and each one is now a rule with a lint grep, a
negative control and a probe row.

### Added
- **Harness decision per call** (`pp_harness`): Codex serialises `turn_id`
  and `model` into every PreToolUse stdin and sets `PLUGIN_ROOT` for plugin
  hooks; Claude Code does neither. `PP_HARNESS=claude|codex` is the operator's
  override. `CLAUDE_*` environment names are deliberately not a signal — a
  Codex started from a Claude Code shell inherits them (observed:
  `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID` and more arrive in Codex's
  hooks and in its model's shell).
- **`apply_patch` through the state guard**: on Codex a file edit is
  `tool_name: apply_patch` with the patch in `tool_input.command`, selected by
  the existing `Edit|Write` matcher. The guard reads its `*** Add File:` /
  `*** Update File:` / `*** Delete File:` / `*** Move to:` headers — the
  target paths, never the content. The classifier does the same for a patch
  fed to `apply_patch` through the shell (`state-tamper`), two corpus blocks.
- **`PREDICT` without an environment file**: when `CLAUDE_ENV_FILE` is unset
  (Codex) `session-env.sh` prints a SessionStart `additionalContext` naming
  `bin/predict`; the SKILL falls back to a glob over both plugin caches.
- **Session id from either platform**: `predict` resolves `PP_SESSION`, else
  `CLAUDE_CODE_SESSION_ID` or `CODEX_SESSION_ID` (equal to the hook's
  `session_id`, verified); both set — one harness inside the other's shell —
  is refused until `PP_SESSION` names the gate. Loop operator-only acts
  recognise a Codex session too.
- `tests/platform-probe.sh --codex`: an isolated `CODEX_HOME`, the lab gate's
  trust written with the hash Codex computes (normalised identity → TOML →
  sorted JSON → SHA-256, reproduced from `codex-rs` and checked against live
  records), the fail-open matrix, then this checkout's real hooks as user
  hooks: force-push outside the protocol, without a receipt, with one;
  `apply_patch` into the state; SessionStart. Read-only sandbox by default
  (`PROBE_SANDBOX=workspace-write` to let the push itself run).
- `hook-engineering.md`: the Codex platform table, stdin, environment,
  `permission_mode` derivation, trust records and their hash, the pid
  namespace of the sandbox. README pair: Codex row, install, probe.

### Changed
- **The two `ask` cells deny on Codex.** Codex has no PreToolUse `ask`: a
  hook that asks is marked failed and *the command runs* (documented, and
  observed through the probe). Outside the protocol an interactive Codex
  session is therefore denied with the reason and the two ways out (a plain
  shell, or `predict on` + a receipt); with a matching receipt the gate passes
  silently — the receipt is the witness, as in a delegated session, and
  Codex's own approval flow still applies. Every other cell is unchanged;
  `codex exec` under `approval_policy=never` arrives as
  `permission_mode: bypassPermissions` and is a delegated session already.
- `pp_mode` ignores an inherited `CLAUDE_CODE_ENTRYPOINT` on Codex;
  `pp_delegated` consults the transcript on Claude Code only (a Codex rollout
  carries no `permissionMode` marker; its text is content).
- Version 1.1.0 in `plugin.json` and `PP_VERSION`; 179 controls, 329 corpus cases.

### Acceptance (Codex CLI 0.162.1, `tests/platform-probe.sh --codex`, 2026-10-15)
- The fail-open matrix through the platform: deny JSON and exit 2 block;
  `ask`, exit 1, invalid JSON and a timeout overrun are all marked Failed and
  **the command ran** — the `ask` row is the gap 1.1.0 closes.
- `codex exec` always runs with approval `never`: a `-c approval_policy=on-request`
  override still prints `approval: never` and reaches the hook as
  `permission_mode: bypassPermissions`. So every exec session is the delegated
  row (observed: a force-push outside the protocol passed the gate silently
  and the sandbox decided); the interactive row (`default`) exists only in the
  TUI/app and is covered by replaying the platform's own PreToolUse stdin
  with `permission_mode: default` through the gate → deny, "cannot ask".
- This checkout's real hooks as user hooks of an isolated `CODEX_HOME`: under
  the protocol without a receipt → deny + recipe reached the model
  ("Command blocked by PreToolUse hook: prediction-protocol v1.1.0 …"); with a
  receipt → silent pass, receipt consumed; `apply_patch` into the state
  directory → denied by the state guard, state unchanged; `session-env.sh`
  → `SessionStart Completed`.
- Stdin facts: `turn_id` and `model` on every PreToolUse; the model's shell has
  `CODEX_SESSION_ID` equal to the hook's `session_id`; a Codex started from a
  Claude Code shell inherits `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID`
  and the rest into its hooks and its model's shell (the reason the harness is
  decided from stdin and `PLUGIN_ROOT`); the sandbox is its own pid namespace.
  The trust-hash algorithm reproduced from `codex-rs` matched all six live
  records of another plugin before the probe relied on it.
- Not observed: the TUI itself (the deny-instead-of-ask row through a live
  interactive Codex session — first interactive run to confirm); macOS.

### Supply-chain self-check (`git diff v1.0.3..HEAD -- plugins/`)
- Network verbs: none added (`curl|wget|fetch|http` hits are the existing
  classifier vocabulary and corpus lines). Credentials: `tests/platform-probe.sh`
  copies the user's own `~/.codex/auth.json` into its temporary lab home
  (mode 0600, removed on exit) so the probe can run `codex exec` in an
  isolated `CODEX_HOME` — named here, not silent. `rm -rf`: the probe's
  `trap 'rm -rf "$W"'` on its own `mktemp -d`, as before, and fixture command
  strings in `tests/run.sh` (`rm -rf ./cx`, like the existing rows). `eval`:
  none added; `base64`: the gate's existing stdin transport.

## [1.0.3] — 2026-08-22

### Fixed
- The gate's `ask` — outside the protocol, and with a matching receipt —
  **stopped on the human even in auto mode**: the platform shows a hook's
  `ask` as "Hook PreToolUse:Bash requires confirmation" and the classifier
  does not answer it (observed on 2.1.239 in the first interactive session
  with the plugin installed — the item 1.0.2 left "not yet observed"). For a
  long autonomous task that is a stop at every force-push and merge. The gate
  now recognises a **delegated** session — auto mode, `dontAsk`,
  `bypassPermissions` — and treats it like headless: silent outside the
  protocol (the platform's classifier decides), **deny + recipe** under the
  protocol without a receipt (the witness is still required), silent pass with
  one. Every deny is unchanged; `default` and `acceptEdits` still ask.
- Detection: auto mode arrives on stdin as `permission_mode: "default"`
  (verified 2.1.240 — `acceptEdits`, `dontAsk`, `bypassPermissions` arrive as
  set), so `pp_delegated` also reads the platform's own record: the last
  `"permissionMode":"…"` marker in the session transcript (`transcript_path`
  from stdin; `{"type":"permission-mode",…}` lines are appended on every
  toggle). An unreadable transcript means "not delegated" — the failure is a
  visible prompt, never a silent pass.
- `tests/platform-probe.sh` now also checks that `permission_mode` arrives
  under `--permission-mode dontAsk` (the `-p` path cannot reach auto mode).

A running session keeps the plugin version it started with (hooks and the
exported `PREDICT`): the fix applies to sessions started after the update.

### Acceptance (interactive auto-mode session, Claude Code 2.1.240, plugin installed from the catalog)
- The transcript carries `{"type":"permission-mode","permissionMode":"auto"}`
  before every turn (offsets 233 … 189493 of a 197 KB file), so the 256 KB
  tail window in `pp_delegated` keeps the marker; stdin still says
  `permission_mode: "default"`.
- Outside the protocol a `git push --force` to a local bare origin ran
  silently — no "requires confirmation" stop. The same hook input replayed by
  hand with this session's transcript → empty output, exit 0; with a
  marker-less transcript → `ask`.
- `predict on` → `predict-gate: active v1.0.3`; the same force-push without a
  receipt → deny + recipe; with a receipt for the exact command → silent pass,
  PostToolUse marked it fired, `close` → HIT, `report` with `gate: seen`;
  `off` recorded as a bypass.
- Observed, not changed: under the protocol a read-only look at the state
  directory from Bash (`ls …/sessions/<id> 2>/dev/null`, `cat …/state`) is
  denied as `state-tamper` — `lib/classify.sh` flags the path together with
  `cat` in its verb list or any `>` (a `2>/dev/null` counts). `predict report`
  is the sanctioned view; a narrower rule is a 1.0.4 candidate.
- Still not observed: macOS; a real runner user on a separate host.

## [1.0.2] — 2026-08-22

### Fixed
- A destructive receipt closed without ever passing the gate now writes
  `- gated: no (close-without-gate)` into the journal (it used to write the
  advisory wording, so `report`'s `ungated` counter and the lint warning could
  never fire — the line was only ever produced by a hand-written test fixture).
  An advisory receipt writes `- gated: no (advisory)`.
- `hooks/predict-state-guard.sh` inspected the whole hook input, so a `Write`
  of a document that merely *mentions* `prediction-protocol/sessions/` was
  denied as state tampering. It now inspects only `file_path` /
  `notebook_path`. Found while writing loop-foundry's `predictions.md`.

### Added
- Under `predict on … --loop`, `ack`, `withdraw` and `off` refuse to run when
  `CLAUDE_CODE_SESSION_ID` is set: in a loop they are the operator's acts
  (from a plain shell as the runner user, with `PP_SESSION=<uuid>`), never the
  executor session's — an executor that acknowledges its own miss is grading
  its own homework. `--task` sessions are unchanged. Both found by the
  loop-foundry 1.1.0 review panel.

## [1.0.1] — 2026-08-22

### Fixed
- `predict on` printed a stray `0` line after the session line when no
  `--also` wrapper was given (`grep -c` prints its count *and* exits 1 on zero
  matches, so the `|| echo 0` fallback fired too). Found by the loop-foundry
  runner acceptance, which parses that output; a control in `tests/run.sh`
  now pins "exactly two lines".

## [1.0.0] — 2026-08-22

### Added
- `hooks/session-env.sh` — a `SessionStart` hook that exports
  `PREDICT=<plugin>/bin/predict` through `CLAUDE_ENV_FILE`, so consumers call
  `"${PREDICT:?}" on …` and an unset variable reads as "not installed".
- `hooks/predict-gate.sh` — a `PreToolUse` gate on the `Bash` tool. Classifies
  the command; outside the protocol a one-way command asks; under it a one-way
  command is denied unless an open, unexpired, untampered, unconsumed receipt
  names that exact command, in which case it asks with the prediction in the
  prompt (interactive) or stays silent (headless). Subagent calls are denied
  with an instruction to report, never to write a receipt. One receipt = one
  tool call; one receipt in flight; a halted session denies every one-way
  command. Structural fail-closed: an outer wrapper that answers deny with
  nothing but bash, a pure-bash vocabulary pre-filter, `ERR` trap → deny,
  inner deadline (GNU `timeout`, `gtimeout`, or a bash watchdog) → deny,
  parser missing → deny, every control byte escaped, deny by both channels
  (JSON + stderr, exit 2); the hook never emits `allow`. A liveness stamp
  (`hook-seen`) tells `status`/`report` whether the platform ever fired it.
- `hooks/predict-fired.sh` — `PostToolUse` on Bash: marks the consumed
  receipt as fired once its command actually ran; `close` refuses a gated
  receipt that never fired. `hooks/predict-state-guard.sh` — `PreToolUse` on
  Edit/Write/MultiEdit/NotebookEdit: the session state is not editable.
- `bin/predict` — `on | off | status | open | close | ack | retry | withdraw |
  report | lint | classify | selftest`. Receipts are action-bound, stamped and
  hashed by the script in session state outside the repository (ids
  `<sha8(session)>-<seq>`); `open` refuses a one-way or wrapper `--observe`, a
  secret-shaped field and multi-line fields; `close` runs the measurement,
  confirms a MISS with a second run (both recorded), redacts then truncates,
  renders a `gated:` line and lints; a MISS halt clears only through `ack
  --refuted --where`, an INCONCLUSIVE one through `retry [--observe]` or
  `withdraw`; `ack` writes `docs/evidence/REFUTED.md` (one ledger per repo,
  `where` column); `report` is the only source of the `predictions:` line
  (`rate = HIT/(HIT+MISS+INCONCLUSIVE)`, `insufficient` below n=20, `ungated`
  and `lint=` and `gate: seen`); journal mutations are serialised with
  `flock`; `--task`/`--loop` are kind flags, the journal name is positional;
  a runner keys both halves with one `PP_SESSION`.
- `lib/classify.sh` — a command-shaped one-way classifier (migration runners,
  SQL/KV clients with writes or opaque input, force-push/merge/release,
  kubectl/helm/terraform/docker/systemctl, remote exec and stdin-fed shells,
  mutating HTTP off localhost, cloud/secret mutations, publish, recursive
  delete outside /tmp, writes into the protocol's own state), with a
  vocabulary pre-filter, quote-aware splitting, heredoc-body dropping, `$(…)`
  lifting, prefix and per-tool global-option stripping, token dequoting,
  clustered short flags, `bash -c`/`su -c`/`eval` unwrapping, dry-run and
  positional `--help` exemptions; `predict on --also` adds a project's
  wrappers; calls to `predict` itself are never classified.
- Closed claim grammar (`exit= stdout== stdout~= stdout-in= lines= http=
  count=`) with derived falsifiers; destructive receipts must measure a
  different command than the action and predict more than an exit code.
- Journal entries with a machine-parsable header (`contract=1`), grader
  stamps, built-in secret masks plus `ci/scan-text.sh` when the repo carries
  ci-gate, and `predict lint` over all of it.
- `skills/prediction-protocol/SKILL.md` with `references/journal.md` and
  `references/hook-engineering.md` (platform facts verified on Claude Code
  2.1.239: exit 1 / invalid JSON / timeout all let the command run).
- `tests/run.sh` (negative controls over the decision table, the receipt
  lifecycle, halt rules, redaction, lint, the error paths, the hooks and both
  corpora through the gate), `tests/classify-corpus.sh` (single-line and
  multi-line corpora), `tests/platform-probe.sh` (through Claude Code itself,
  manual at release), `scripts/lint.sh`, CI with lint + tests + a pinned
  gitleaks over the change range, `permissions: contents: read`.
- Reviewed before release by a clean-context panel (6 dimensions → 3
  refuters → critic): record in task-flow's
  `docs/premortem/2026-08-22-prediction-protocol-premortem.md`.

### Supply-chain self-check (devpowers release ritual)
- Network verbs in the payload: none. `base64` in `hooks/predict-gate.sh` is
  the stdin-field transport between the python/jq parser and bash (`base64
  -d` of the command text only). `rm -rf` in `bin/predict` removes its own
  `mktemp -d` directories. `eval`/`rm -rf`/`curl` strings in
  `lib/classify.sh` and `tests/corpus/` are the classifier's vocabulary and
  fixtures, never executed.
- Acceptance through the installed plugin (`claude -p`, Claude Code 2.1.239):
  deny with recipe → the model opened the receipt → PostToolUse marked it
  fired → `close` HIT → `report` with `gate: seen`. `permissionDecision: ask`
  in an **interactive** session is asserted from the documentation, not yet
  observed — first interactive run to confirm.

[1.2.0]: https://github.com/umar-s/prediction-protocol/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/umar-s/prediction-protocol/compare/v1.0.3...v1.1.0
[1.0.3]: https://github.com/umar-s/prediction-protocol/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/umar-s/prediction-protocol/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/umar-s/prediction-protocol/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/umar-s/prediction-protocol/releases/tag/v1.0.0
