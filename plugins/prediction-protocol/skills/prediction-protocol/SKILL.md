---
name: prediction-protocol
description: Prediction before action — a fail-closed PreToolUse gate refuses one-way shell commands (migrations, force-push, merge, deploy, restart, remote exec, mutating HTTP, secrets, recursive delete) without a receipt for that exact command, and the `predict` CLI grades HIT / MISS / INCONCLUSIVE itself. Use when a Bash call was denied by "prediction-protocol", when the user says "predict first", "под протоколом прогнозов", "predict on", or when a skill's routing (task phases 5/7/8, loop-foundry runners) calls for receipts. Not for read-only commands, tests, builds or lint.
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
PREDICTED OBSERVABLE  a read-only measurement + a closed claim  --observe / --expect
FALSIFIER             derived: the claim's complement, same command
ACTION                the command the gate is about to pass      --action
ACTUAL · VERDICT      written by `predict close`, never by you
```

## Resolve the CLI once

The plugin's SessionStart hook exports `PREDICT` — the absolute path of
`bin/predict` — into the session's Bash environment. An unset `PREDICT` is an
honest "plugin not installed"; every deny reason also carries the path.
Resolve once in a bash step and use the value afterwards — the Read tool does
not expand `${…}`:

```bash
P="${PREDICT:?prediction-protocol not installed}"; "$P" version
ROOT="$(dirname "$(dirname "$P")")"      # for the references below
```

## The commands

```bash
"$P" on <journal> [--task | --loop] [--also 'make deploy']...   # session under the protocol → predict-gate: active|broken
"$P" open --action '<exact command>' --hypothesis '<one line>' \
          --observe '<read-only measurement, not the action>' --expect '<claim>' [--scope advisory] [--baseline]
<run the exact same command once>                               # the gate matches it to the receipt; PostToolUse marks it fired
"$P" close <id>                                                 # runs the measurement, grades, writes the journal
"$P" ack <id> --refuted '<the belief that was false>' --where '<paths or systems>'   # after a MISS: clears the halt, writes REFUTED.md
"$P" retry <id> [--observe '<fixed measurement>'] [--expect '…'] # after INCONCLUSIVE: re-measure (the old entry is superseded)
"$P" withdraw <id> --reason '<why>'                             # an open receipt whose action never ran, or an INCONCLUSIVE one
"$P" report                                                      # the only source of the predictions: line
"$P" off --reason '<why>'                                        # the bypass: recorded as such, never hidden
```

Claims are a closed grammar: `count=N` · `stdout==LIT` · `stdout~=ERE` ·
`http=NNN` · `lines=N` · `stdout-in=A..B` · `exit=N`. Anything else is
refused at `open`. For a destructive receipt (the default) the measurement
must be a **different, read-only command** than the action — the CLI
classifies `--observe` and refuses a one-way one — and the claim cannot be
only an exit code: "the action will exit 0" is a tautology. A secret-shaped
value in any field is refused; reference it as `$VAR`. Details and examples:
`Read "$ROOT/skills/prediction-protocol/references/journal.md"` (load it when
you write your first receipt in a session, not before).

## What the gate does

The hook sees the `Bash` tool only (MCP tools and PowerShell are outside 1.x,
stated, not assumed). It classifies the command by its verb after stripping
`sudo`/`env`/`VAR=`/`time`/`timeout`/`xargs`, splitting on `;`, `&&`, `||`,
`|`, `&` and newlines outside quotes, dropping heredoc bodies and unwrapping
`bash -c`/`su -c`/`eval`. A project's own wrappers (`make deploy`,
`bash scripts/release.sh`) are declared once with `predict on --also` from
the consuming `CLAUDE.md` bindings. Calls to `predict` itself are never
classified. Then:

| context | outside the protocol | under it, no receipt | receipt matches this exact command |
|---|---|---|---|
| interactive | **ask** — a human answers at the irreversible | **deny** + the `predict open …` recipe | **ask**, with the prediction in the prompt |
| subagent (`agent_id`) | ask | **deny**: report the command as a finding; do not write a receipt | deny — a subagent does not open one-way doors |
| headless (`claude -p`) | silent — the runner's permissions decide | deny + recipe | silent pass |

One receipt is one tool call: the gate marks it consumed, the PostToolUse hook
marks it fired, and `close` refuses a consumed receipt that never fired (you
declined the prompt, or another hook denied it — `withdraw` it). One receipt in
flight: any other one-way command while a consumed receipt is not closed is
denied. A receipt older than 30 minutes, edited after it was opened, or
opened by hand is denied; editing the state under
`~/.local/state/prediction-protocol/` through Edit/Write or Bash is itself
denied. A deny blocks by both channels (deny JSON and exit 2); every gate
error on a one-way command is a deny; the hook never emits `allow`.

## After the verdict

- **HIT** — continue.
- **MISS** (confirmed by a second measurement, both recorded) — every
  one-way action in the session is halted until `predict ack <id> --refuted
  '…' --where '…'` names the belief and where it held. Nothing else clears a
  MISS halt — not a later HIT, not `predict on`, not `off`.
- **INCONCLUSIVE** (the measurement exited non-zero, was not found, timed out,
  returned nothing comparable, or flapped between the two runs) — halts the
  same way until `predict retry <id> [--observe …]` re-measures or
  `predict withdraw <id> --reason '…'`. It counts in the denominator.

`predict report` prints `predictions: H HIT / M MISS / I INCONCLUSIVE / B
bypass / U ungated / O open · scope=destructive … · n=… · rate=… · lint=… ·
gate: seen <utc>`; below n=20 the rate is `insufficient`. Paste that line
verbatim where an evidence block asks for it — admissible only next to the
`predict-gate: active` line from `predict on`.

## Where receipts are required, advised, or noise

- **Required (the gate enforces):** migration runners; SQL/KV clients with
  writes or opaque input; force-push, branch delete, merge, release; kubectl
  / helm / terraform / docker / systemctl mutations; `ssh host <cmd>`,
  `docker|kubectl exec`, stdin-fed shells; mutating HTTP off localhost; cloud,
  grant and secret mutations; package publish; recursive delete outside `/tmp`.
- **Advisory (`--scope advisory`, no gate):** live verification, debugging,
  recovery — write the receipt **before** you look. In `task` phase 7 every
  `live` DoD item is one advisory cycle and the DoD grade cites `predict <id>`.
- **Noise (excluded):** read-only commands, tests, builds, lint, local edits,
  plain `git push`, dry runs, `--help`, `rm` inside `/tmp`.

**Wrapping is a bypass.** Moving a denied command into a script, a `make`
target or an `ssh`/`bash -c` string to dodge the classifier is `predict off`
without the record; the review reads the journal and the diff, and a script
that appeared for that reason is a finding. If you genuinely must act without
a prediction, `predict off --reason '…'`: written to the journal as `bypass`,
and one-way commands ask instead of requiring receipts until `predict on`.

## Discipline

- You author hypothesis, observable and claim; you never write `actual` or
  `verdict` — only entries with a grader stamp pass `predict lint`, and
  `close`/`report` run it.
- A denied command is not "permission denied" — it is a missing receipt: write
  it and re-issue the command once. A halt is the protocol working.
- `predict on` prints `predict-gate: active v… (selftest: …)` or refuses with
  `broken`. That line is the proof the gate exists in this session; `report`
  adds `gate: seen <utc>` once the platform has actually fired it.
- The journal (`docs/evidence/<journal>.md`; `loops/evidence/<loop>.md` for
  loops) and `docs/evidence/REFUTED.md` are committed with the task at close;
  open receipts never reach the repository. Read `REFUTED.md` before touching
  the paths it names — it is the one thing here that outlives a session.
- Headless runners: export one `PP_SESSION` around both `predict on` and
  `claude -p --session-id <uuid>` so the CLI and the hook key the same state.
  Under `on --loop`, `ack`, `withdraw` and `off` refuse to run inside a
  Claude session: in a loop they are the operator's acts, from a plain shell.
- Platform facts and the checklist for any hook in this line:
  `Read "$ROOT/skills/prediction-protocol/references/hook-engineering.md"`
  (only when editing or debugging the hook).
