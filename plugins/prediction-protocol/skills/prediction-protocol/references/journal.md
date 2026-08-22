# The journal — receipts, entries, the ledger, the report

## Where things live

| what | where | written by |
|---|---|---|
| session state: `state`, `also`, `receipts/<id>/…` | `${XDG_STATE_HOME:-~/.local/state}/prediction-protocol/sessions/<session_id>/` | `predict` (the hook adds `consumed`) |
| journal | `<repo>/docs/evidence/<journal>.md` · loops: `<repo>/loops/evidence/<loop>.md` | `predict close`, `off`, `withdraw`, `ack`, `retry` |
| refuted-beliefs ledger | `<repo>/docs/evidence/REFUTED.md` | `predict ack` only |

`<repo>` is `git rev-parse --show-toplevel` where `predict on` ran (or
`--root`). `<session_id>` comes from `CLAUDE_CODE_SESSION_ID`, which Claude
Code exports to the Bash tool and passes to the hook on stdin; `PP_SESSION`
overrides it for runners and tests. Open receipts never enter the
repository: the journal gets only graded, redacted entries.

## Claims

| claim | HIT when | falsifier (derived) |
|---|---|---|
| `exit=N` | the measurement exits N | exit ≠ N |
| `stdout==LIT` | trimmed stdout equals LIT | stdout ≠ LIT |
| `stdout~=ERE` | stdout matches the extended regex | stdout !~ /ERE/ |
| `stdout-in=A..B` | the first line is a number in [A, B] | outside A..B |
| `lines=N` | stdout has N lines | line count ≠ N |
| `http=NNN` | the first line is NNN (use `curl -s -o /dev/null -w '%{http_code}' URL`) | status ≠ NNN |
| `count=N` | the first line is the number N (`… \| wc -l`, `psql -tAc 'select count(*) …'`) | count ≠ N |

The measurement exiting non-zero with empty output, not being found, or
timing out is **INCONCLUSIVE**, not MISS. A MISS is confirmed by a second
run; a result that flaps is INCONCLUSIVE ("unstable"). Non-numeric output
under a numeric claim is INCONCLUSIVE.

Examples that carry information:

```bash
"$P" open --action 'alembic upgrade head' --hypothesis '0042 adds the index without touching rows' \
  --observe "psql -tAc 'select count(*) from orders'" --expect 'count=10422'
"$P" open --action 'gh pr merge 214 --squash' --hypothesis 'merge lands on main as one commit' \
  --observe 'gh pr view 214 --json state -q .state' --expect 'stdout==MERGED'
"$P" open --action 'kubectl rollout restart deploy/api' --hypothesis 'api comes back healthy within the rollout window' \
  --observe 'sleep 20; curl -s -o /dev/null -w "%{http_code}" https://dev.example.com/health' --expect 'http=200'
"$P" open --scope advisory --action 'live check of DoD-2' --hypothesis 'the new endpoint rejects an unauthenticated call' \
  --observe 'curl -s -o /dev/null -w "%{http_code}" https://dev.example.com/api/v2/orders' --expect 'http=401'
```

And the one that does not (refused at `open` for a destructive receipt):
`--observe 'alembic upgrade head' --expect 'exit=0'`. `--baseline` runs the
measurement before the action and stores it; `predict lint` warns when a
destructive HIT equals its baseline — the action changed nothing observable.

## Entry format (contract 1)

```
### predict <session8>-<seq> · <utc> · scope=<destructive|advisory|session> · verdict=<HIT|MISS|INCONCLUSIVE|withdrawn|superseded|bypass> · contract=1
- hypothesis: …
- action: `…`                       # redacted: a token in a header never reaches the repo
- observe: `…` → expect `…` (falsifier: …)
- actual: `exit=N stdout=…` [— confirmed ×2 | — unstable: …] · redaction: builtin[+gitleaks]
- baseline: `…`                     # only with --baseline
- retry-of: <id>                    # only on a retry
- graded-by: predict v<ver> @ <utc> · session <session8>
- refuted: … → REFUTED.md           # added by predict ack
- reason: …                         # bypass / withdrawn
- superseded-by: <id>               # the original of a retry
```

`actual` is the measurement's exit code plus at most 5 lines / 512 bytes of
stdout, through the built-in masks (Authorization headers, bearer/basic
tokens, `user:pass@` URLs, AWS/GitHub/Slack/Stripe key shapes, JWTs,
`password=`/`secret=`/`token=` pairs, private-key blocks) and, when the repo
carries ci-gate, through `ci/scan-text.sh`; `redaction:` says which ran.
Environment variable *values* never enter an entry — `$VAR` in a command is
stored as written.

Consumers do not parse this file. They call `predict report`; `contract=`
changes when the format does, and `predict lint` refuses another contract.

## REFUTED.md

```
| date | entry | belief | where |
|---|---|---|---|
| 2026-08-22 | 3f9a1c20-4 | migration 0042 is idempotent on a re-run | DEV-512 |
```

One row per acknowledged MISS; `predict lint` fails a MISS without exactly
one row. The reader is named: `task` phase 0 reads it and carries the rows
that touch this task's paths into the spec's Context pack; a loop reads it
in its Phase 0. Without a reader the ledger is write-only — that was the
donor's defect.

## The report line

```
predictions: 7 HIT / 1 MISS / 1 INCONCLUSIVE / 0 bypass / 0 open · scope=destructive 3/1/1 · n=9 · rate=insufficient (n<20) · window=DEV-512 · repro: predict report --journal <path>
```

`rate = HIT / (HIT + MISS + INCONCLUSIVE)`; withdrawn and superseded entries
are out of `n`; below `n=20` (`PP_K`) the rate prints as `insufficient`.
`--json` gives the same numbers for a runner's journal; `--last K` windows
the count. This is a **second signal**: a threshold proposes a promotion or
a demotion on the loop-foundry ladder, a human (or the loop's written policy)
decides.

## What `predict lint` checks

Header grammar and contract · a grader stamp on every graded entry
(hand-written verdicts fail) · a measurement command and a claim in the
grammar · `actual` present for HIT/MISS/INCONCLUSIVE · destructive entries
measure a different command than the action and predict more than an exit
code (advisory: a warning) · no secret shape left in the entry · every MISS
has a `refuted:` line and exactly one `REFUTED.md` row · bypass/withdrawn
carry a reason · superseded names its successor. Exit 0 clean, 1 findings,
2 no journal. `predict close` and `predict report` run it implicitly.
