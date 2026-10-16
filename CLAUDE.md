# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

`prediction-protocol` — a Claude Code **plugin** in the devpowers line
(`plugins/prediction-protocol/`, one plugin per repo, tags `vX.Y.Z`). The
deliverable is a PreToolUse hook, a bash CLI and Markdown; no package
manager, no runtime dependencies beyond bash, coreutils and `python3` or
`jq` for the hook's stdin. Design and premortem live in the task-flow repo:
`docs/superpowers/specs/2026-08-22-prediction-protocol-design.md` and
`docs/premortem/2026-08-22-prediction-protocol-premortem.md`.

## Commands

```bash
bash scripts/lint.sh                                        # written rules as greps; must stay green
bash plugins/prediction-protocol/tests/classify-corpus.sh   # the classifier contract
bash plugins/prediction-protocol/tests/run.sh               # negative controls (offline, seconds)
bash plugins/prediction-protocol/tests/platform-probe.sh    # through `claude -p`; manual, before a release
claude plugin validate plugins/prediction-protocol           # the plugin lives in plugins/, the repo root has no manifest
```

## Invariants (each one has a lint grep or a negative control — add both when adding a rule)

- **The hook never emits `allow`.** With a receipt it asks (interactive) or
  stays silent (headless); the human click on a one-way door is never
  removed by this plugin. A deny blocks by both channels (JSON + exit 2).
- **Fail-closed is structural.** The platform runs the command when a hook
  exits 1, prints broken JSON or overruns its timeout. The outer wrapper
  answers deny with nothing but bash; the pure-bash pre-filter keeps
  token-free commands independent of anything that can fail; every error
  path on a one-way command ends in deny; control bytes are escaped; the
  inner deadline is shorter than the `hooks.json` timeout and falls back to
  a bash watchdog; no network, no locks in the hook. An irrelevant command
  on a broken gate stays silent — one bug must not lock every project the
  owner opens.
- **The deny path is pinned whole.** Both hooks and both libraries the gate
  sources (`lib/common.sh`, `lib/classify.sh`) carry a sha256 in
  `scripts/lint.sh`: their recorders run builtins only, and no grep or
  snapshot can hold that against a later redefinition. Any edit fails lint
  until re-pinned — only after `tests/run.sh` passes on the edited file
  (a vocabulary change to `classify.sh` included).
- **The classifier's object is a shell command string**, never a file's
  content (that is ci-gate/migration-guard) and never prose. Two corpora are
  the contract; a new class needs a must-deny line and a must-pass neighbour.
- **The CLI owns grading.** The model authors hypothesis/observe/expect; only
  `predict close` writes `actual` and `verdict`, with a stamp `predict lint`
  requires. Receipts live in session state outside the repo, keyed by the
  session id the platform provides; the repo gets only graded, redacted
  entries.
- **Consumers call commands, not formats.** `predict on` / `predict report`
  are the contract; the journal header carries `contract=N` and lint refuses
  another.
- SKILL.md stays a thin orchestrator (lint caps it at 1400 words); method
  lives in `references/`, loaded lazily through `$ROOT` resolved in a bash
  step — the Read tool does not expand `${CLAUDE_PLUGIN_ROOT}`.
- README.md and README.ru.md move in lockstep (lint compares headings).
- No `Co-Authored-By` trailers.

## Release

The devpowers ritual (the catalog's own CLAUDE.md): supply-chain
self-check over `git diff <prev-tag>..HEAD -- plugins/`, bump `plugin.json`
(and `PP_VERSION` in `lib/common.sh` — lint checks they match), a CHANGELOG
section (edit, never rewrite), annotated tag `vX.Y.Z`, `gh release create
--notes-file … --verify-tag`. Re-run `tests/platform-probe.sh` before tagging
— the platform table in `hook-engineering.md` is a verified fact, not a
belief.
