# Changelog

All notable changes to this plugin. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). The single source of the version is
`plugins/prediction-protocol/.claude-plugin/plugin.json`.

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

[1.0.1]: https://github.com/umar-s/prediction-protocol/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/umar-s/prediction-protocol/releases/tag/v1.0.0
