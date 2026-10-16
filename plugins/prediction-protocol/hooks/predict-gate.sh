#!/usr/bin/env bash
# predict-gate.sh — PreToolUse hook on the Bash tool. Thin by design: it
# classifies the command, reads the session state that bin/predict maintains,
# and answers deny / ask / nothing. It never grades, never writes the journal;
# the only state it touches is the receipt's `consumed` mark and a liveness
# stamp.
#
# Fail-closed is STRUCTURAL here, because the platform is fail-open: a hook
# that exits 1, prints broken JSON or overruns its timeout lets the command
# run (verified on Claude Code 2.1.239). So: an outer wrapper that needs
# nothing but bash to answer deny, a vocabulary pre-filter so irrelevant
# commands never depend on anything that can fail, an inner run under its own
# deadline (GNU timeout, gtimeout, or a bash watchdog), an ERR trap that turns
# any unhandled error into a deny, and denies that block by BOTH channels —
# deny JSON on stdout and the reason on stderr with exit 2 — so a defect in one
# channel can never become an allow. The word allow never appears here.
#
# Two harnesses, one table: Codex CLI runs the same hook with the same JSON
# contract but has no PreToolUse `ask` (a hook that asks is marked failed and
# the command RUNS — verified 0.162.1), so where this gate would ask on Claude
# Code it denies on Codex, and with a matching receipt it passes silently —
# the receipt is the witness, as in a delegated session.
set -u -o pipefail
export LC_ALL=C
PP_ENV_PLUGIN_ROOT="${PLUGIN_ROOT:-}"   # Codex sets PLUGIN_ROOT for plugin hooks, Claude Code does not — read it before the name is reused below
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
PP_VERSION=unknown

# literal deny: plain ASCII only, no helpers, no sourced files. It records itself first
# (gate-error, command unknown) under a runner's PP_SESSION: every wrapper deny happens
# before or without the libraries, so the record is inlined — builtins and date only,
# best-effort, never fatal (${HOME:-}: an unset variable under set -u must not end the
# hook before its deny is printed).
deny_literal() {
  local s="${PP_SESSION:-}" d
  if [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then
    d="${PP_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/prediction-protocol}/sessions/$s"
    if [ -d "$d" ]; then { printf '%s\tgate-error\t\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$d/denies"; } 2>/dev/null || true; fi
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"prediction-protocol v%s: %s"}}\n' "$PP_VERSION" "$1"
  printf 'prediction-protocol v%s: %s\n' "$PP_VERSION" "$1" >&2
  exit 2
}

# ---- outer wrapper: self-sufficient, deadline, both deny channels ------------
if [ "${1:-}" != "--inner" ]; then
  trap 'deny_literal "gate error before evaluation (failing closed)"' ERR
  input="$(cat)" || deny_literal "cannot read stdin (failing closed)"
  [ -r "$here/../lib/classify.sh" ] || deny_literal "lib/classify.sh is missing: broken install (failing closed)"
  . "$here/../lib/classify.sh" || deny_literal "lib/classify.sh failed to load (failing closed)"
  # no vocabulary token anywhere in the call → nothing here can be one-way; say nothing, depend on nothing
  pp_prefilter "$input" || pp_prefilter_also "$input" || exit 0
  [ -r "$here/../lib/common.sh" ] || deny_literal "lib/common.sh is missing: broken install (failing closed)"
  . "$here/../lib/common.sh" || deny_literal "lib/common.sh failed to load (failing closed)"
  errf="$(mktemp "${TMPDIR:-/tmp}/pp-gate-err.XXXXXX" 2>/dev/null)" || errf=/dev/null
  if out="$(printf '%s' "$input" | pp_with_deadline "${PP_DEADLINE:-9}" bash "${BASH_SOURCE[0]}" --inner 2>"$errf")"; then rc=0; else rc=$?; fi
  err=""; [ "$errf" != /dev/null ] && { err="$(head -c 600 "$errf" 2>/dev/null || true)"; rm -f "$errf"; }
  case "$rc" in
    0) printf '%s' "$out"; [ -n "$out" ] && printf '\n'; exit 0 ;;
    2) printf '%s' "$out"; [ -n "$out" ] && printf '\n'; printf '%s\n' "$err" >&2; exit 2 ;;
    124|137|143) deny_literal "the gate exceeded its deadline on a command that carries a one-way token (failing closed). ${err//[^ -~]/ }" ;;
    *) deny_literal "gate error rc=$rc (failing closed). ${err//[^ -~]/ }" ;;
  esac
fi

# ---- inner: the decision --------------------------------------------------------
. "$here/../lib/common.sh"
. "$here/../lib/classify.sh"
predict="\"$PLUGIN_ROOT/bin/predict\""
emit() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$1" "$(pp_json_str "$2")"; }
deny() { pp_note_deny "${sdir:-}" "${CLS:-unclassified}" "${cmd_b64:-}"; emit deny "prediction-protocol v$PP_VERSION: $1"; printf 'prediction-protocol v%s: %s\n' "$PP_VERSION" "$1" >&2; exit 2; }
ask()  {   # Claude Code: the permission prompt carries the reason. Codex: no hook ask exists — deny, and say why
  [ "${harness:-claude}" = claude ] || deny "$1 — this harness cannot ask: Codex has no PreToolUse ask (a hook that asks is marked failed and the command runs), so the gate denies instead. Either run the command yourself from a plain shell, or put the session under the protocol and open a receipt for it — then the receipt is the witness and the gate passes it silently."
  emit ask "prediction-protocol v$PP_VERSION: $1"; exit 0
}
pass() { exit 0; }

ONEWAY=""; CLS=""
on_err() {
  trap - ERR
  case "$ONEWAY" in
    0) exit 0 ;;
    *) deny "gate error while evaluating \`${CLS:-this call}\` (${BASH_COMMAND}) — failing closed. If this persists: $predict selftest" ;;
  esac
}
trap on_err ERR

# a runner's session is known before stdin is parsed, so even an early deny (unparsable input) is recorded
sdir=""; if [ -n "${PP_SESSION:-}" ] && pp_valid_session "$PP_SESSION"; then sdir="$(pp_session_dir "$PP_SESSION")"; fi
input="$(cat)"
parse_py() { python3 -c '
import json,sys,base64
d=json.load(sys.stdin)
ti=d.get("tool_input") or {}
cmd=ti.get("command") or ""
print(d.get("session_id") or "")
print(d.get("agent_id") or "")
print(d.get("tool_name") or "")
print(d.get("tool_use_id") or "")
print(d.get("permission_mode") or "")
print(d.get("transcript_path") or "")
print(base64.b64encode(cmd.encode()).decode())
print("1" if (d.get("turn_id") or d.get("model")) else "")
'; }
parse_jq() { jq -r '[(.session_id//""), (.agent_id//""), (.tool_name//""), (.tool_use_id//""), (.permission_mode//""), (.transcript_path//""), ((.tool_input.command//"")|@base64), (if ((.turn_id//"")!="" or (.model//"")!="") then "1" else "" end)] | .[]'; }
fields=""
command -v python3 >/dev/null 2>&1 && fields="$(printf '%s' "$input" | parse_py 2>/dev/null)" || fields=""
[ -n "$fields" ] || { command -v jq >/dev/null 2>&1 && fields="$(printf '%s' "$input" | parse_jq 2>/dev/null)" || fields=""; }
[ -n "$fields" ] || deny "cannot parse the hook input (no python3 or jq on PATH, or malformed stdin) while the call carries a one-way token — failing closed. Install python3 or jq."
session_id="$(printf '%s\n' "$fields" | sed -n 1p)"
agent_id="$(printf '%s\n' "$fields" | sed -n 2p)"
tool_name="$(printf '%s\n' "$fields" | sed -n 3p)"
tool_use_id="$(printf '%s\n' "$fields" | sed -n 4p)"
permission_mode="$(printf '%s\n' "$fields" | sed -n 5p)"
transcript_path="$(printf '%s\n' "$fields" | sed -n 6p)"
cmd_b64="$(printf '%s\n' "$fields" | sed -n 7p)"   # the command's exact bytes, for the deny record (a decode below drops trailing newlines)
command="$(printf '%s\n' "$cmd_b64" | base64 -d 2>/dev/null)" || command=""
codex_marker="$(printf '%s\n' "$fields" | sed -n 8p)"   # turn_id / model: Codex serialises them, Claude Code does not
harness="$(pp_harness "$codex_marker")"
[ "$tool_name" = "Bash" ] || pass
[ -n "$command" ] || pass

# session key: a runner's PP_SESSION (exported around `claude -p`) wins, then the platform's stdin id
sess="${PP_SESSION:-$session_id}"; [ -n "$sess" ] || sess="${CLAUDE_CODE_SESSION_ID:-}"
sdir=""; [ -n "$sess" ] && pp_valid_session "$sess" && sdir="$(pp_session_dir "$sess")"
PP_ALSO=""; [ -n "$sdir" ] && [ -r "$sdir/also" ] && PP_ALSO="$(cat "$sdir/also")"; export PP_ALSO

if r="$(pp_classify "$command")"; then CLS="${r%%	*}"; ONEWAY=1
else rc=$?; if [ "$rc" -eq 2 ]; then CLS="unclassifiable"; ONEWAY=1; else ONEWAY=0; fi; fi
[ "$ONEWAY" = 1 ] || pass

[ -n "$sdir" ] || deny "\`$CLS\` is a one-way action and this call carries no usable session id (stdin session_id='${session_id:-}') — failing closed."
active=""; state_broken=0
if [ -e "$sdir" ]; then
  if [ -r "$sdir/state" ]; then active="$(pp_kv_get "$sdir/state" active || true)"; : > "$sdir/hook-seen" 2>/dev/null || true; pp_utc > "$sdir/hook-seen" 2>/dev/null || true
  else state_broken=1; fi
fi
[ -n "${PP_TEST_SLEEP:-}" ] && sleep "$PP_TEST_SLEEP"
[ "$state_broken" = 0 ] || deny "\`$CLS\` is a one-way action and this session's protocol state exists but cannot be read ($sdir/state) — failing closed. Fix the permissions or run $predict on again."

mode="$(pp_mode "$agent_id" "$harness")"
delegated="$(pp_delegated "$permission_mode" "$transcript_path" "$harness")"   # 1 = auto / dontAsk / bypassPermissions (Codex: approval never): the human chose a classifier or no prompts; an ask would stop on nobody
cmd_norm="$(pp_norm "$command")"
q="$(printf '%s' "$command" | sed "s/'/'\\\\''/g")"

# ---- outside the protocol's scope: the owner's rule, ask before the irreversible
if [ "$active" != 1 ]; then
  case "$mode" in
    headless) pass ;;                                 # the runner's permissions decide; a subagent in -p has nobody to ask either
    *) [ "$(pp_entrypoint "$harness")" = cli ] || pass
       [ "$delegated" = 0 ] || pass                    # delegated session: the platform decides, as the runner's permissions do in headless
       ask "\`$CLS\` is a one-way action and this session is not under the prediction protocol. Approve to run it as-is, or put the session under the protocol first: $predict on <journal-name> — then every one-way action needs a receipt ($predict open …)." ;;
  esac
fi

# ---- inside the scope -----------------------------------------------------------
halted="$(pp_kv_get "$sdir/state" halted 2>/dev/null || true)"
if [ -n "$halted" ]; then
  hv="$(cat "$sdir/receipts/$halted/verdict" 2>/dev/null || echo MISS)"; hh="$(cat "$sdir/receipts/$halted/hypothesis" 2>/dev/null || true)"
  case "$hv" in
    MISS) deny "session halted after MISS on predict $halted (hypothesis: $hh). One-way actions stay blocked until the belief is named: $predict ack $halted --refuted '<what turned out false, one line>' --where '<paths or systems>'. Then re-issue the command." ;;
    *) deny "session halted after $hv on predict $halted (hypothesis: $hh). Re-measure: $predict retry $halted [--observe '<fixed measurement>'] — or $predict withdraw $halted --reason '…'. Then re-issue the command." ;;
  esac
fi
if [ "$mode" = subagent ]; then
  deny "\`$CLS\` is a one-way action and this call comes from a subagent (agent_id $agent_id). Subagents do not open one-way doors: report this command as a finding to the orchestrator; do not write a receipt."
fi

recipe="Write the prediction first, then re-issue the SAME command once:
  $predict open --action '$q' --hypothesis '<what you believe about the system, one line>' --observe '<a read-only measurement command, different from the action>' --expect '<count=N | stdout==X | stdout~=ERE | http=NNN | lines=N | stdout-in=A..B>'
(destructive by default: the claim cannot be only exit=N; use --scope advisory for an observation without an action.)
After the command ran: $predict close <id> — it runs the measurement and grades HIT/MISS/INCONCLUSIVE itself. A MISS halts further one-way actions until $predict ack <id> --refuted '…' --where '…'."

# pass 1: anything in flight?
inflight=""
if [ -d "$sdir/receipts" ]; then
  for d in "$sdir/receipts"/*/; do
    [ -d "$d" ] || continue; [ -e "$d/closed" ] && continue
    [ -e "$d/consumed" ] && { inflight="$(basename "$d")"; break; }
  done
fi
if [ -n "$inflight" ]; then
  if [ -e "$sdir/receipts/$inflight/fired" ]; then deny "receipt $inflight is consumed but not closed — one receipt in flight: $predict close $inflight first, then open a new receipt for this command."
  else deny "receipt $inflight was released to the gate but its action never ran (declined, or blocked by another hook). If the command did not run: $predict withdraw $inflight --reason 'not fired' and open a new receipt; if it did run: $predict close $inflight."; fi
fi
# pass 2: a matching, fresh, untampered receipt
match=""; expired=""
if [ -d "$sdir/receipts" ]; then
  for d in "$sdir/receipts"/*/; do
    [ -d "$d" ] || continue; [ -e "$d/closed" ] && continue; [ -e "$d/consumed" ] && continue
    [ "$(cat "$d/action_norm" 2>/dev/null)" = "$cmd_norm" ] || continue
    id="$(basename "$d")"
    opened="$(cat "$d/opened" 2>/dev/null || echo 0)"
    if [ $(( $(pp_now) - opened )) -gt "$PP_TTL" ] || [ "$opened" -gt "$(pp_now)" ]; then expired="$id"; continue; fi
    sha_now="$(cat "$d/action_norm" "$d/hypothesis" "$d/observe" "$d/expect" "$d/opened" 2>/dev/null | pp_sha)"
    [ "$sha_now" = "$(cat "$d/sha" 2>/dev/null)" ] || deny "receipt $id was edited after it was opened (sha mismatch) — open a new one. $recipe"
    match="$id"; break
  done
fi
if [ -z "$match" ]; then
  [ -z "$expired" ] || deny "receipt $expired for this command is older than $((PP_TTL/60)) minutes (or stamped in the future) — open a fresh one. $recipe"
  deny "\`$CLS\` is a one-way action and this session is under the prediction protocol ($(pp_kv_get "$sdir/state" journal 2>/dev/null || echo '?')), but no open receipt names this exact command. $recipe"
fi

# consume: one receipt = one tool call; PostToolUse marks it fired once the command actually ran
printf '%s %s\n' "$(pp_now)" "${tool_use_id:-?}" > "$sdir/receipts/$match/consumed"
hyp="$(cat "$sdir/receipts/$match/hypothesis")"; obs="$(cat "$sdir/receipts/$match/observe")"; exp="$(cat "$sdir/receipts/$match/expect")"
case "$mode" in
  headless) pass ;;
  *) [ "$delegated" = 0 ] || pass                      # delegated session: the receipt is the witness, there is no one to show it to
     [ "$harness" = claude ] || pass                    # Codex: no hook ask exists — the receipt is the witness; the platform's own approval flow still runs
     ask "predict $match — hypothesis: $hyp · observe: \`$obs\` → expect $exp (falsifier: $(pp_falsifier "$exp")). Approve to fire \`$cmd_norm\`; afterwards: $predict close $match. If you decline: $predict withdraw $match --reason 'not fired'." ;;
esac
