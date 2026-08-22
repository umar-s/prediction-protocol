# Changelog

All notable changes to this plugin. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). The single source of the version is
`plugins/prediction-protocol/.claude-plugin/plugin.json`.

## [1.0.0] — 2026-08-22

### Added
- `hooks/session-env.sh` — a `SessionStart` hook that exports
  `PREDICT=<plugin>/bin/predict` through `CLAUDE_ENV_FILE`, so consumers call
  `"${PREDICT:?}" on …` and an unset variable reads as "not installed".
- `hooks/predict-gate.sh` — a `PreToolUse` gate on the `Bash` tool. Classifies
  the command; outside the protocol a one-way command asks; under it a one-way
  command is denied unless an open, unexpired, unconsumed receipt names that
  exact command, in which case it asks with the prediction in the prompt
  (interactive) or stays silent (headless). Subagent calls are denied with an
  instruction to report, never to write a receipt. One receipt = one tool
  call; one receipt in flight; a halted session denies every one-way command.
  Structural fail-closed: `ERR` trap → deny, inner deadline → deny, parser
  missing → ask; the hook never emits `allow`.
- `bin/predict` — `on | off | status | open | close | ack | retry | withdraw |
  report | lint | classify | selftest`. Receipts are action-bound, stamped and
  hashed by the script in session state outside the repository; `close` runs
  the measurement, confirms a MISS with a second run, redacts and grades;
  `ack` writes `docs/evidence/REFUTED.md`; `report` is the only source of the
  `predictions:` line (`rate = HIT/(HIT+MISS+INCONCLUSIVE)`, `insufficient`
  below n=20).
- `lib/classify.sh` — a command-shaped one-way classifier (migration runners,
  SQL/KV clients with writes or opaque input, force-push/merge/release,
  kubectl/helm/terraform/docker/systemctl, remote exec, mutating HTTP off
  localhost, cloud/secret mutations, publish, recursive delete outside /tmp),
  with prefix stripping, compound-command splitting and `bash -c`/`eval`
  unwrapping; `predict on --also` adds a project's wrappers.
- Closed claim grammar (`exit= stdout== stdout~= stdout-in= lines= http=
  count=`) with derived falsifiers; destructive receipts must measure a
  different command than the action and predict more than an exit code.
- Journal entries with a machine-parsable header (`contract=1`), grader
  stamps, built-in secret masks plus `ci/scan-text.sh` when the repo carries
  ci-gate, and `predict lint` over all of it.
- `skills/prediction-protocol/SKILL.md` with `references/journal.md` and
  `references/hook-engineering.md` (platform facts verified on Claude Code
  2.1.239: exit 1 / invalid JSON / timeout all let the command run).
- `tests/run.sh` (65 negative controls over the decision table, the receipt
  lifecycle, halt, redaction, lint and the error paths),
  `tests/classify-corpus.sh` (100 must-deny / 100 must-pass lines),
  `tests/platform-probe.sh` (through Claude Code itself, manual at release),
  `scripts/lint.sh`, CI with lint + tests + gitleaks.

[1.0.0]: https://github.com/umar-s/prediction-protocol/releases/tag/v1.0.0
