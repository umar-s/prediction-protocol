# prediction-protocol

[![release](https://img.shields.io/github/v/release/umar-s/prediction-protocol?display_name=tag&sort=semver)](https://github.com/umar-s/prediction-protocol/releases)
[![check](https://github.com/umar-s/prediction-protocol/actions/workflows/check.yml/badge.svg)](https://github.com/umar-s/prediction-protocol/actions/workflows/check.yml)

Prediction before action, as a Claude Code plugin. A `PreToolUse` gate
refuses one-way shell commands — migrations, force-push, merge, deploy,
restart, remote exec, mutating HTTP, grants and secrets, recursive delete —
unless the session holds a **receipt** for that exact command: a hypothesis,
a measurement command and a falsifiable claim, written before the action.
The `predict` CLI opens the receipt, runs the measurement itself and grades
**HIT / MISS / INCONCLUSIVE** into a journal with a ledger of refuted
beliefs. A miss halts the batch. No self-grading.

The idea comes from the ARC-AGI-3 skill that refused to send an action
without a written prediction of the next frame and graded it by code. Our
world is non-deterministic and partially observable, so the unit here is not
"the next frame" but a **measurement with a command** — a prediction without
one is an intention.

## How it works

```
predict on DEV-512                      # the session is under the protocol; selftest prints predict-gate: active v1.0.0
predict open --action 'alembic upgrade head' \
  --hypothesis '0042 adds the index without touching rows' \
  --observe "psql -tAc 'select count(*) from orders'" --expect 'count=10422'
alembic upgrade head                    # the gate matches the command to the receipt → the permission prompt shows the prediction
predict close 3f9a1c20-1                # runs the measurement, grades, appends to docs/evidence/DEV-512.md
predict report                          # predictions: 1 HIT / 0 MISS / 0 INCONCLUSIVE / 0 bypass / 0 open · …
```

Without a receipt the command is **denied** with the exact `predict open …`
recipe in the reason. Outside the protocol (no `predict on`) a one-way
command **asks** — the owner's "ask only at the irreversible" as a mechanism
rather than a prose rule. In headless runs the gate stays silent outside the
protocol and denies inside it. Subagents never open one-way doors: they are
told to report the command as a finding.

| | outside the protocol | under it, no receipt | receipt matches |
|---|---|---|---|
| interactive | ask | deny + recipe | ask, prediction in the prompt |
| subagent | ask | deny: report as a finding | deny |
| headless (`claude -p`) | silent | deny + recipe | silent |

A **MISS** (confirmed by a second measurement) halts every one-way action
until `predict ack <id> --refuted '…'` names the belief in one line and
writes it to `docs/evidence/REFUTED.md` — the file the next session reads
before touching the same paths. **INCONCLUSIVE** (the measurement did not
run, or flapped) halts the same way until `predict retry` or `predict
withdraw`. `predict off --reason '…'` is the bypass: recorded in the journal
as `bypass`, never hidden.

## What is gated

Classified from the command string by verb, after stripping `sudo`, `env`,
`VAR=…`, `time`, `timeout` and splitting on `;`, `&&`, `||`, `|`; `bash -c`
and `eval` are unwrapped. Migration runners (alembic, rails db:, artisan,
prisma, flyway, liquibase, manage.py, goose, …); SQL/KV clients with writes,
`-f`/`<`/heredoc input or a pipe; `git push --force*`/`--delete`, `branch
-D`, `gh pr merge`, `glab mr merge`, `gh release create`; `kubectl`, `helm`,
`terraform`, `pulumi`, `docker rm|prune|down`, `systemctl restart|stop`,
`pm2`; `ssh host <cmd>`, `docker|kubectl exec`; `curl`/`http`/`wget` with
a mutating method or body off localhost; `aws`/`gcloud`/`az`/`vault`/`gh
secret` mutations; `npm publish`, `twine upload`, `docker push`; `rm -r`
outside `/tmp`, `find -delete`, `dd of=/dev/`, `mkfs`. Read-only commands,
tests, builds, lint, plain `git push`, `git reset --hard`, `rm` in `/tmp`
pass. A project's own wrappers (`make deploy`) are declared with `predict on
--also`. The corpora in `tests/corpus/` are the contract — 100 must-deny and
100 must-pass lines.

## Fail-closed, structurally

The platform is fail-open: a hook that exits 1, prints broken JSON or
overruns its timeout lets the command run (verified on Claude Code 2.1.239,
`tests/platform-probe.sh`). The gate therefore carries an `ERR` trap that
answers deny, an inner deadline shorter than its `hooks.json` timeout, one
explicit path to a silent exit, no network, and never emits `allow`. Receipt
state lives outside the repository under
`~/.local/state/prediction-protocol/sessions/<session_id>/`, keyed by the
session id the platform passes to the hook — no `TASK-ID`, no `cwd`
dependence, nothing to commit by accident.

## Layout

```
plugins/prediction-protocol/
  skills/prediction-protocol/SKILL.md        # the protocol, scope, the three commands, discipline
  skills/prediction-protocol/references/journal.md          # claims, entry format, REFUTED.md, report line, lint
  skills/prediction-protocol/references/hook-engineering.md # platform facts + checklist for any hook in the line
  hooks/hooks.json · hooks/predict-gate.sh   # the gate (matcher "Bash", timeout 15)
  hooks/session-env.sh                       # SessionStart: exports PREDICT=<plugin>/bin/predict for consumers
  bin/predict                                # on | off | status | open | close | ack | retry | withdraw | report | lint | classify | selftest
  lib/classify.sh · lib/common.sh            # the classifier; state, claims, redaction
  tests/run.sh · tests/classify-corpus.sh · tests/platform-probe.sh · tests/corpus/
```

## Install

```
/plugin marketplace add umar-s/devpowers
/plugin install prediction-protocol@devpowers
```

Linux/macOS, the `Bash` tool only; `python3` or `jq` for the hook's stdin
(neither → the gate asks, never silent). MCP tools and PowerShell are
outside 1.x by declaration.

## Consumers

- **task-flow `task`** — `predict on <TASK-ID>` at the start of phase 5 (the
  `predict-gate: active` line is the proof), receipts around state-changing
  implementation steps, one advisory cycle per `live` DoD item in phase 7,
  receipts for merge and deploy in phase 8 with the `predict report` line in
  the evidence block, `REFUTED.md` read in phase 0. Works without the plugin:
  the lines print `predict-gate: absent`.
- **loop-foundry** — `predict on <loop> --loop` from `run.sh`, `predict
  report --json` merged into the tick record as a second signal on the
  shadow → gated → autonomous ladder, a halt as a hook-enforced stop.

## Checks

```bash
bash scripts/lint.sh                                   # written rules as greps: versions, matcher, trap, deadline, no allow, SKILL/references pins, README parity
bash plugins/prediction-protocol/tests/classify-corpus.sh
bash plugins/prediction-protocol/tests/run.sh          # 65 negative controls: the decision table, receipt lifecycle, halt, redaction, lint, error paths
bash plugins/prediction-protocol/tests/platform-probe.sh   # through Claude Code itself; manual, at release
```

## License

MIT.
