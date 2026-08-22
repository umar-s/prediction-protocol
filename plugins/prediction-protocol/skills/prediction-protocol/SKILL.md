---
name: prediction-protocol
description: Prediction before action. A PreToolUse gate refuses one-way shell commands (migrations, force-push, merge, deploy, restart, remote exec, mutating HTTP, grants/secrets, recursive delete) unless the session holds a receipt for that exact command — a hypothesis, a measurement command and a falsifiable claim — and the `predict` CLI opens the receipt, runs the measurement itself and grades HIT / MISS / INCONCLUSIVE into a journal with a refuted-beliefs ledger. Use when a Bash call was denied by "prediction-protocol", when the user says "predict first", "под протоколом прогнозов", "запиши прогноз", "predict on", or when a skill's routing (task phases 5/7/8, loop-foundry runners) calls for receipts. Not for read-only commands, tests, builds or lint — those are already predictions with a deterministic verdict.
---

# prediction-protocol

Every one-way action becomes an experiment. You write what you believe, how
it will be measured and what result would prove you wrong — **before** the
action. The harness runs the measurement and grades it. A miss names a false
belief and stops the batch; the belief goes into a ledger the next session
reads. Accuracy over time is a second signal of "I understand this system"
against "I got lucky" — never a switch that flips on its own.

```
HYPOTHESIS            what you believe about the system         --hypothesis
PREDICTED OBSERVABLE  a measurement command + a closed claim    --observe / --expect
FALSIFIER             derived: the claim's complement, same command
ACTION                the command the gate is about to pass      --action
ACTUAL · VERDICT      written by `predict close`, never by you
```

## Resolve the plugin root once

The plugin's SessionStart hook exports `PREDICT` — the absolute path of
`bin/predict` — into the session's Bash environment, so any skill can call
it without knowing where the plugin is installed; an unset `PREDICT` is an
honest "plugin not installed". Resolve once in a bash step and use the
resolved value afterwards — the Read tool and your memory do not expand
`${…}`:

```bash
P="${PREDICT:-${CLAUDE_PLUGIN_ROOT:-}/bin/predict}"; [ -x "$P" ] && "$P" version || echo "predict-gate: absent (PREDICT unset — prediction-protocol not installed)"
ROOT="$(dirname "$(dirname "$P")")"     # for the references below
```

Every deny reason also carries the absolute path to `predict`, so a session
that never loaded this file can still comply.

## The three commands (plus on/off)

```bash
"$P" on <journal> [--task DEV-512 | --loop <name>] [--also 'make deploy']   # put the session under the protocol; prints predict-gate: active|broken
"$P" open --action '<exact command>' --hypothesis '<one line>' \
          --observe '<measurement command, not the action>' --expect '<claim>' [--scope advisory] [--baseline]
<run the exact same command once>                                           # the gate matches it against the receipt
"$P" close <id>                                                             # runs the measurement, grades, writes the journal
"$P" ack <id> --refuted '<the belief that turned out false>'                # after a MISS — clears the halt, writes REFUTED.md
"$P" report                                                                  # the only source of the predictions: line
"$P" off --reason '<why>'                                                    # the bypass: recorded, not hidden
```

Claims are a closed grammar: `exit=N` · `stdout==LIT` · `stdout~=ERE` ·
`stdout-in=A..B` · `lines=N` · `http=NNN` · `count=N`. Anything else is
refused at `open`, not linted later. For a destructive receipt the
measurement must be a **different command** than the action and the claim
cannot be only an exit code — "the action will exit 0" is a tautology, not a
prediction about the system. Details, examples and the journal format:
`Read "$ROOT/skills/prediction-protocol/references/journal.md"` (load it
when you write your first receipt in a session, not before).

## What the gate does

The hook sees only the `Bash` tool (Bash tool only — MCP tools and
PowerShell are outside 1.x, stated, not assumed) and classifies the command
by its verb after stripping `sudo`/`env`/`VAR=`/`time`/`timeout` and
splitting on `;`, `&&`, `||`, `|`. A project's own wrappers (`make deploy`,
`bash scripts/release.sh`) are declared once with `predict on --also` from
the consuming `CLAUDE.md` bindings. Then:

| context | outside the protocol (`predict on` not run) | under the protocol, no receipt | receipt matches this exact command |
|---|---|---|---|
| interactive session | **ask** — the owner's rule: a human answers at the irreversible | **deny** + the `predict open …` recipe | **ask**, with the prediction in the prompt — the human click stays |
| subagent (`agent_id`) | ask | **deny**: report the command as a finding; do not write a receipt | deny — a subagent does not open one-way doors |
| headless (`claude -p`) | silent — the runner's permissions decide | deny + recipe | silent pass |

One receipt is one tool call: the gate marks it consumed; the same command
again needs a new `open`. One receipt in flight: another one-way command
while a consumed receipt is not closed is denied. A receipt older than 30
minutes, or edited after it was opened, is denied. Every gate error is a
deny (the platform itself is fail-open on a broken hook — the gate carries
its own trap and deadline). The hook never emits `allow`.

## After the verdict

- **HIT** — continue.
- **MISS** (confirmed by a second measurement) — every one-way action in the
  session is halted until `predict ack <id> --refuted '…'` names the belief
  in one line. Then fix the spec or your model of the system; the ack is what
  lets the next command through, the fix is what the review checks.
- **INCONCLUSIVE** (the measurement did not run or returned nothing
  comparable; or the result flapped between two runs) — halts the same way,
  until `predict retry <id>` (same receipt, new measurement) or
  `predict withdraw <id> --reason '…'`. It counts in the denominator.

`predict report` prints `predictions: H HIT / M MISS / I INCONCLUSIVE / B
bypass / O open · scope=destructive … · n=… · rate=…`; below n=20 the rate
is `insufficient`, not a percentage. Paste that line verbatim where an
evidence block asks for it — it is admissible only next to a
`predict-gate: active` line from `predict on`.

## Where receipts are required, advised, or noise

- **Required (the gate enforces):** migration runners and SQL clients with
  writes or opaque input, force-push / branch delete / merge / release,
  `kubectl`/`helm`/`terraform` mutations, service restart/stop, `ssh host
  <cmd>` and `docker|kubectl exec`, mutating HTTP off localhost, cloud and
  secret mutations, package publish, recursive delete outside `/tmp`.
- **Advisory (`--scope advisory`, no gate):** live verification, debugging,
  recovery, exploring an unknown system — write the receipt **before** you
  look. In `task` phase 7 every `live` DoD item is one advisory cycle and the
  DoD grade cites `predict <id>`; an item without an id is an item without
  evidence.
- **Noise (excluded):** read-only commands, tests, builds, lint, local edits,
  plain `git push`, `rm` inside `/tmp`. A test is already a prediction with a
  deterministic verdict.

**Wrapping is a bypass.** Moving a denied command into a script file, a
`make` target or an `ssh`/`bash -c` string to dodge the classifier is the
same as `predict off` without the record; the review reads the journal and
the diff, and a script that appeared for that reason is a finding. If you
genuinely must act without a prediction, `predict off --reason '…'` — it is
written to the journal as `bypass`, and one-way commands ask instead of
requiring receipts until `predict on` again.

## Discipline

- You author hypothesis, observable and claim. The CLI **never writes** them
  for you, and you never write `actual` or `verdict`: only entries with a
  grader stamp pass `predict lint`. Editing the session state under
  `~/.local/state/prediction-protocol/` by hand is a bypass, not a shortcut —
  the gate checks the receipt's hash.
- Report honestly: a denied command is not "permission denied" — it is a
  missing receipt; write it and re-issue the command once. A halt is not an
  error to work around; it is the protocol working.
- `predict on` prints `predict-gate: active v… (selftest: …)` or
  `broken …`. The line is the proof the gate exists in this session; without
  it, a `predictions:` line is a claim.
- The journal (`docs/evidence/<journal>.md`, `loops/evidence/<loop>.md` for
  loops) and `docs/evidence/REFUTED.md` are committed with the task at close.
  Open receipts never reach the repository. Read `REFUTED.md` before touching
  the paths it names — that ledger is the one thing here that outlives a
  session.
- Platform facts the gate relies on, and the checklist for any hook in this
  line: `Read "$ROOT/skills/prediction-protocol/references/hook-engineering.md"`
  (only when editing or debugging the hook).
