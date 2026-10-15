---
name: prediction-protocol
description: Prediction before action — a fail-closed PreToolUse gate refuses one-way shell commands (migrations, force-push, merge, deploy, restart, remote exec, mutating HTTP, secrets, recursive delete) without a receipt for that exact command, and the `predict` CLI grades HIT / MISS / INCONCLUSIVE itself. Use when a Bash call was denied by "prediction-protocol", when the user says "predict first", "под протоколом прогнозов", "predict on", or when a skill's routing (task phases 5/7/8, loop-foundry runners) calls for receipts. Not for read-only commands, tests, builds or lint.
---

# prediction-protocol

Every one-way action is an experiment: what you believe, how it is measured,
what would prove you wrong — written **before** the action. The harness
measures and grades; a miss names a false belief, stops the batch and goes
into a ledger the next session reads. Accuracy over time is a second signal
of "I understand this system" — never a switch that flips on its own.

```
HYPOTHESIS            what you believe about the system         --hypothesis
PREDICTED OBSERVABLE  a read-only measurement + a closed claim  --observe / --expect
FALSIFIER             derived: the claim's complement, same command
ACTION                the command the gate is about to pass      --action
ACTUAL · VERDICT      written by `predict close`, never by you
```

## Resolve the CLI once

`PREDICT` is the absolute path of `bin/predict`: Claude Code's SessionStart
hook exports it into the Bash environment; on Codex (no environment file) the
hook puts it into the session context and you export it in the shell step.
The plugin cache is the fallback. Resolve once in a bash step — the Read tool
does not expand `${…}`:

```bash
P="${PREDICT:-$(ls ~/.codex/plugins/cache/*/prediction-protocol/*/bin/predict ~/.claude/plugins/cache/*/prediction-protocol/*/bin/predict 2>/dev/null | sort -V | tail -1)}"
"${P:?prediction-protocol not installed}" version
ROOT="$(dirname "$(dirname "$P")")"      # for the references below
```

Receipts are keyed by the session id the platform exports to the shell
(`CLAUDE_CODE_SESSION_ID` or `CODEX_SESSION_ID`); with both set (nested
harnesses) `predict` refuses until `PP_SESSION` names the gate this shell is
under.

## The commands

```bash
"$P" on <journal> [--task | --loop] [--also 'make deploy']...   # → predict-gate: active|broken
"$P" open --action '<exact command>' --hypothesis '<one line>' \
          --observe '<read-only measurement, not the action>' --expect '<claim>' [--scope advisory] [--baseline]
<run the exact same command once>                               # the gate matches the receipt; PostToolUse marks it fired
"$P" close <id>                                                 # runs the measurement, grades, writes the journal
"$P" ack <id> --refuted '<the belief that was false>' --where '<paths or systems>'   # after a MISS: clears the halt, writes REFUTED.md
"$P" retry <id> [--observe '<fixed measurement>'] [--expect '…'] # after INCONCLUSIVE: re-measure
"$P" withdraw <id> --reason '<why>'                             # action never ran, or INCONCLUSIVE
"$P" report                                                      # the only source of the predictions: line
"$P" off --reason '<why>'                                        # the bypass, recorded
```

Claims are a closed grammar: `count=N` · `stdout==LIT` · `stdout~=ERE` ·
`http=NNN` · `lines=N` · `stdout-in=A..B` · `exit=N`; anything else is
refused at `open`. A destructive receipt (the default) needs a **different,
read-only** measurement than the action — the CLI classifies `--observe` and
refuses a one-way one — and a claim that is only an exit code is a tautology.
A secret-shaped value in any field is refused; reference it as `$VAR`. Details
and examples: `Read "$ROOT/skills/prediction-protocol/references/journal.md"`
(when you write the first receipt of a session, not before).

## What the gate does

The hook sees the `Bash` tool only (Codex names its shell tool `Bash` to
hooks; MCP tools and PowerShell are outside 1.x). It
classifies the command by its verb — after stripping `sudo`/`env`/`VAR=`/
`time`/`timeout`/`xargs`, splitting on `;`, `&&`, `||`, `|`, `&` and newlines
outside quotes, dropping heredoc bodies, unwrapping `bash -c`/`su -c`/`eval`.
A project's wrappers (`make deploy`) are declared once with `predict on
--also`; calls to `predict` itself are never classified. Then:

| context | outside the protocol | under it, no receipt | receipt matches the exact command |
|---|---|---|---|
| interactive, Claude Code | **ask** — a human answers at the irreversible | **deny** + the `predict open …` recipe | **ask**, with the prediction in the prompt |
| Codex, interactive | **deny** — no hook `ask` on Codex: a plain shell, or the protocol | deny + recipe | silent pass — the receipt is the witness |
| auto mode, `dontAsk`, `bypassPermissions`, `codex exec` | silent (delegated) | deny + recipe | silent |
| subagent (`agent_id`) | ask (deny on Codex) | **deny**: report the command as a finding, write no receipt | deny — subagents do not open one-way doors |
| headless (`claude -p`, `PP_ENTRYPOINT=headless`) | silent — the runner decides | deny + recipe | silent pass |

One receipt is one tool call: the gate marks it consumed, the PostToolUse hook
marks it fired, and `close` refuses a consumed receipt that never fired
(`withdraw` it). While a consumed
receipt is not closed, every other one-way command is denied. A receipt older
than 30 minutes, edited after opening, or opened by hand is denied; editing
the state under `~/.local/state/prediction-protocol/` through Edit/Write
(`apply_patch` on Codex) or Bash is itself denied. A deny blocks by both
channels (deny JSON and exit 2); every gate error on a one-way command is a
deny; the hook never emits `allow`.

## After the verdict

- **HIT** — continue.
- **MISS** (confirmed by a second measurement, both recorded) — every
  one-way action in the session is halted until `predict ack <id> --refuted
  '…' --where '…'` names the belief and where it held; nothing else clears
  it — not a later HIT, not `predict on`, not `off`.
- **INCONCLUSIVE** (the measurement failed, timed out, returned nothing
  comparable, or flapped between the two runs) — halts the same way until
  `predict retry <id> [--observe …]` re-measures or `predict withdraw <id>
  --reason '…'`. It counts in the denominator.

`predict report` prints `predictions: H HIT / M MISS / I INCONCLUSIVE / B
bypass / U ungated / O open · … · gate: seen <utc>`; below n=20 the rate is
`insufficient`. Paste it verbatim where an evidence block asks — admissible
only next to the `predict-gate: active` line from `predict on`.

## Where receipts are required, advised, or noise

- **Required (the gate enforces):** migration runners; SQL/KV clients with
  writes or opaque input; force-push, branch delete, merge, release; kubectl
  / helm / terraform / docker / systemctl mutations; `ssh host <cmd>`,
  `docker|kubectl exec`, stdin-fed shells; mutating HTTP off localhost; cloud,
  grant and secret mutations; package publish; recursive delete outside `/tmp`.
- **Advisory (`--scope advisory`, no gate):** live verification, debugging,
  recovery — write the receipt **before** you look; in `task` phase 7 each
  `live` DoD item is one advisory cycle citing `predict <id>`.
- **Noise:** read-only commands, tests, builds, lint, local edits, plain
  `git push`, dry runs, `--help`, `rm` inside `/tmp`.

**Wrapping is a bypass.** Moving a denied command into a script, a `make`
target or an `ssh`/`bash -c` string to dodge the classifier is `predict off`
without the record; the review reads the journal and the diff, and such a
script is a finding. If you must act without a prediction, `predict off
--reason '…'`: journaled as `bypass`; one-way commands then ask (deny on
Codex) until `predict on`.

## Discipline

- You author hypothesis, observable and claim; you never write `actual` or
  `verdict` — only entries with a grader stamp pass `predict lint`, which
  `close`/`report` run.
- A denied command is not "permission denied" but a missing receipt: write it
  and re-issue the command once. A halt is the protocol working.
- `predict on` prints `predict-gate: active v… (selftest: …)` or refuses with
  `broken` — the proof the gate exists in this session; `report` adds
  `gate: seen <utc>` once the platform has fired it.
- The journal (`docs/evidence/<journal>.md`; `loops/evidence/<loop>.md` for
  loops) and `docs/evidence/REFUTED.md` are committed at close; open receipts
  never reach the repository. Read `REFUTED.md` before touching the paths it
  names — it outlives the session.
- Headless runners: one `PP_SESSION` exported around `predict on` and the
  executor (`claude -p --session-id <uuid>` or `codex exec`) keys the CLI and
  the hook to the same state. Under `on --loop`, `ack`, `withdraw` and `off`
  refuse to run inside a model session — they are the operator's.
- Codex: skill `$prediction-protocol:prediction-protocol`; plugin hooks run
  only after `/hooks` → Trust, again after every update — `gate: never` in
  `predict report` means the hook never fired; runners pass
  `--dangerously-bypass-hook-trust`.
- Platform facts and the hook checklist:
  `Read "$ROOT/skills/prediction-protocol/references/hook-engineering.md"`
  (only when editing or debugging the hook).
