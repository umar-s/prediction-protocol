# Changelog

All notable changes to this plugin. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). The single source of the version is
`plugins/prediction-protocol/.claude-plugin/plugin.json`.

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

[1.0.3]: https://github.com/umar-s/prediction-protocol/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/umar-s/prediction-protocol/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/umar-s/prediction-protocol/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/umar-s/prediction-protocol/releases/tag/v1.0.0
