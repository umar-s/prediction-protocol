# prediction-protocol

[![release](https://img.shields.io/github/v/release/umar-s/prediction-protocol?display_name=tag&sort=semver)](https://github.com/umar-s/prediction-protocol/releases)
[![check](https://github.com/umar-s/prediction-protocol/actions/workflows/check.yml/badge.svg)](https://github.com/umar-s/prediction-protocol/actions/workflows/check.yml)

Prediction before action, as a plugin for Claude Code and Codex CLI. A `PreToolUse` gate
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
predict on DEV-512                      # the session is under the protocol; selftest prints predict-gate: active v1.0.3
predict open --action 'alembic upgrade head' \
  --hypothesis '0042 adds the index without touching rows' \
  --observe "psql -tAc 'select count(*) from orders'" --expect 'count=10422'
alembic upgrade head                    # the gate matches the command to the receipt → the permission prompt shows the prediction
predict close 3f9a1c20-1                # runs the measurement, grades, appends to docs/evidence/DEV-512.md
predict report                          # predictions: 1 HIT / 0 MISS / 0 INCONCLUSIVE / 0 bypass / 0 open · …
```

Without a receipt the command is **denied** — deny JSON on stdout and the
reason on stderr with exit 2, so a defect in one channel never becomes an
allow — with the exact `predict open …` recipe in the reason. Outside the protocol (no `predict on`) a one-way
command **asks** — the owner's "ask only at the irreversible" as a mechanism
rather than a prose rule. In headless runs and in a delegated session (auto
mode, `dontAsk`, `bypassPermissions`) the gate stays silent outside the
protocol and denies inside it — a hook's `ask` stops on the human even in auto
mode, and the human chose a classifier instead. Codex has no hook `ask` at all
(a hook that asks is marked failed and the command runs), so there the gate
**denies** where it would ask and passes a matching receipt silently — the
receipt is the witness, Codex's own approval flow still applies. Subagents
never open one-way doors: they are told to report the command as a finding.

| | outside the protocol | under it, no receipt | receipt matches |
|---|---|---|---|
| interactive, Claude Code | ask | deny + recipe | ask, prediction in the prompt |
| Codex, interactive | deny (cannot ask) | deny + recipe | silent pass |
| auto mode / `dontAsk` / `bypassPermissions` / `codex exec` | silent | deny + recipe | silent |
| subagent | ask (deny on Codex) | deny: report as a finding | deny |
| headless (`claude -p`) | silent | deny + recipe | silent |

A **MISS** (confirmed by a second measurement, both recorded) halts every
one-way action until `predict ack <id> --refuted '…' --where '…'` names the
belief and where it held, and writes it to `docs/evidence/REFUTED.md` — the
file the next session reads before touching the same paths; nothing else
clears that halt. **INCONCLUSIVE** (the measurement did not run cleanly, or
flapped) halts the same way until `predict retry` re-measures or `predict
withdraw`. One receipt is one tool call: the gate marks it consumed, a
PostToolUse hook marks it fired, and `close` refuses a receipt whose action
never ran. `predict off --reason '…'` is the bypass: recorded in the journal
as `bypass`, never hidden.

## What is gated

Classified from the command string by verb, after stripping `sudo`, `env`,
`VAR=…`, `time`, `timeout`, `xargs` and each tool's global options (`git -C`,
`kubectl -n`, `aws --profile`), splitting on `;`, `&&`, `||`, `|`, `&` and
newlines outside quotes, dropping heredoc bodies and lifting `$(…)`;
`bash -c`, `su -c` and `eval` are unwrapped, stdin-fed shells and
interpreters are opaque executors, clustered flags (`psql -tAc`, `curl -sX`)
are read, dry runs and `--help` pass. Migration runners (alembic, rails db:, artisan,
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
--also`; calls to `predict` itself are never classified; writes into the
protocol's own state are. The corpora in `tests/corpus/` are the contract
(`classify-corpus.sh` prints the count).

## Fail-closed, structurally

The platform is fail-open: a hook that exits 1, prints broken JSON or
overruns its timeout lets the command run (verified on Claude Code 2.1.239
and Codex CLI 0.162.1, `tests/platform-probe.sh [--codex]`). The gate therefore has an outer wrapper that
needs nothing but bash to answer deny, a pure-bash vocabulary pre-filter, an
`ERR` trap that answers deny, an inner deadline shorter than its
`hooks.json` timeout (GNU `timeout`, `gtimeout`, or a bash watchdog), every
control byte escaped in its JSON, no network, and never emits `allow`.
Receipt state lives outside the repository under
`~/.local/state/prediction-protocol/sessions/<session_id>/`, keyed by the
session id the platform passes to the hook (or the `PP_SESSION` a runner
exports around `claude -p --session-id` / `codex exec`) — no `TASK-ID`, no
`cwd` dependence, nothing to commit by accident, and nothing the model may
edit: Edit/Write into it (`apply_patch` on Codex) is denied by a second hook,
Bash writes are classified.

## Layout

```
plugins/prediction-protocol/
  skills/prediction-protocol/SKILL.md        # the protocol, scope, the three commands, discipline
  skills/prediction-protocol/references/journal.md          # claims, entry format, REFUTED.md, report line, lint
  skills/prediction-protocol/references/hook-engineering.md # platform facts + checklist for any hook in the line
  hooks/hooks.json · hooks/predict-gate.sh   # the gate (matcher "Bash", timeout 15)
  hooks/predict-fired.sh                     # PostToolUse: marks a consumed receipt as fired
  hooks/predict-state-guard.sh               # PreToolUse on Edit/Write (apply_patch on Codex): the state dir is not editable
  hooks/session-env.sh                       # SessionStart: PREDICT=<plugin>/bin/predict — env file on Claude Code, session context on Codex
  bin/predict                                # on | off | status | open | close | ack | retry | withdraw | report | lint | classify | selftest
  lib/classify.sh · lib/common.sh            # the classifier; state, claims, redaction
  tests/run.sh · tests/classify-corpus.sh · tests/platform-probe.sh · tests/corpus/
```

## Install

```
/plugin marketplace add umar-s/devpowers            # Claude Code
/plugin install prediction-protocol@devpowers

codex plugin marketplace add umar-s/devpowers       # Codex CLI — then /hooks → Trust, again after every update
codex plugin add prediction-protocol@devpowers
```

Linux, the `Bash` tool only (on Codex the shell tool, which the platform names
`Bash` to hooks); `python3` or `jq` for the hook's stdin (neither → a one-way
call is denied, never silent); GNU `timeout` or `gtimeout` preferred, a bash
watchdog otherwise. macOS is untested (the suite runs on Linux CI only). MCP
tools and PowerShell are outside 1.x by declaration. On Codex the plugin's
hooks run only after they are trusted in `/hooks`, and the trust is per
hash — after every plugin update, again; a runner passes
`--dangerously-bypass-hook-trust` instead.

## Consumers

- **task-flow `task`** — `predict on <TASK-ID>` at the start of phase 5 (the
  `predict-gate: active` line is the proof), receipts around state-changing
  implementation steps, one advisory cycle per `live` DoD item in phase 7,
  receipts for merge and deploy in phase 8 with the `predict report` line in
  the evidence block, `REFUTED.md` read in phase 0. Works without the plugin:
  the lines print `predict-gate: absent`.
- **loop-foundry** — the runner exports one `PP_SESSION=<uuid>`, runs
  `predict on <loop> --loop`, then `claude -p --session-id <uuid>` or
  `codex exec`; `predict
  report --json` is snapshotted before and after the executor and both land
  in the tick record (the loop journal is cumulative, so the tick is the
  difference), a second signal on the shadow → gated → autonomous ladder. A
  halt is a hook-enforced stop, and under `--loop` `ack`, `withdraw` and
  `off` refuse to run inside a model session — they are the operator's.
  Since 1.2.0 the tick's denies come from `predict status --json`
  (`denies`): the hooks record every deny of a session under the protocol —
  the command, or the path the state guard refused — where a sandboxed
  model cannot write, instead of the runner parsing each harness's output.

## Checks

```bash
bash scripts/lint.sh                                   # written rules as greps: versions, matcher, trap, deadline, no allow, SKILL/references pins, README parity
bash plugins/prediction-protocol/tests/classify-corpus.sh   # the classifier contract (single-line and multi-line corpora)
bash plugins/prediction-protocol/tests/run.sh          # negative controls: the decision table, receipt lifecycle, halt, redaction, lint, error paths, the corpora through the gate
bash plugins/prediction-protocol/tests/platform-probe.sh   # through Claude Code itself; manual, at release
bash plugins/prediction-protocol/tests/platform-probe.sh --codex   # through Codex CLI (isolated CODEX_HOME, read-only sandbox); manual, at release
claude plugin validate plugins/prediction-protocol
```

## License

MIT.
