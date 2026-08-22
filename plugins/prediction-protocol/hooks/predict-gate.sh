#!/usr/bin/env bash
# predict-gate.sh — PreToolUse hook on the Bash tool. Thin by design: it
# classifies the command, reads the session state that bin/predict maintains,
# and answers deny / ask / nothing. It never grades, never writes the journal.
#
# Fail-closed is STRUCTURAL here, because the platform is fail-open: a hook
# that exits 1, prints broken JSON or overruns its timeout lets the command
# run (verified on Claude Code 2.1.239). So: one wrapper with its own deadline
# that turns a timeout into a deny; an ERR trap that turns any unhandled error
# into a deny; and a single explicit path to a silent exit 0.
set -u -o pipefail
export LC_ALL=C
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$here/.." && pwd)}"
. "$here/../lib/common.sh"

emit() {   # decision reason
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$1" "$(pp_json_str "$2")"
}
deny() { emit deny "prediction-protocol v$PP_VERSION: $1"; exit 0; }
ask()  { emit ask  "prediction-protocol v$PP_VERSION: $1"; exit 0; }
pass() { exit 0; }

# ---- outer wrapper: deadline ------------------------------------------------
if [ "${1:-}" != "--inner" ]; then
  input="$(cat)"
  out="$(printf '%s' "$input" | timeout -k 1 "${PP_DEADLINE:-9}" bash "${BASH_SOURCE[0]}" --inner 2>/tmp/pp-gate-err.$$)"; rc=$?
  err="$(cat /tmp/pp-gate-err.$$ 2>/dev/null | head -c 600)"; rm -f /tmp/pp-gate-err.$$
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then emit deny "prediction-protocol v$PP_VERSION: the gate exceeded its deadline — failing closed. ${err}"; exit 2; fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then emit deny "prediction-protocol v$PP_VERSION: gate error (rc=$rc) — failing closed. ${err}"; exit 2; fi
  printf '%s' "$out"; [ -n "$out" ] && printf '\n'
  exit "$rc"
fi

# ---- inner: the decision ------------------------------------------------------
ONEWAY=""; CLS=""
on_err() {
  trap - ERR
  case "$ONEWAY" in
    0) exit 0 ;;                                   # irrelevant command: never block the owner's other projects on a gate bug
    1) emit deny "prediction-protocol v$PP_VERSION: gate error while evaluating a one-way command (\`$CLS\`) — failing closed: $BASH_COMMAND"; exit 2 ;;
    *) emit ask  "prediction-protocol v$PP_VERSION: the gate could not evaluate this call (${BASH_COMMAND}); answer the prompt yourself and report the gate error."; exit 2 ;;
  esac
}
trap on_err ERR

input="$(cat)"
# stdin → fields (python3, then jq, else fail closed as 'cannot parse')
parse_py() { python3 -c '
import json,sys,base64
d=json.load(sys.stdin)
ti=d.get("tool_input") or {}
cmd=ti.get("command") or ""
print(d.get("session_id",""))
print(d.get("agent_id",""))
print(d.get("tool_name",""))
print(d.get("tool_use_id",""))
print(base64.b64encode(cmd.encode()).decode())
'; }
parse_jq() { jq -r '[.session_id, (.agent_id//""), (.tool_name//""), (.tool_use_id//""), ((.tool_input.command//"")|@base64)] | .[]'; }
if command -v python3 >/dev/null 2>&1; then fields="$(printf '%s' "$input" | parse_py 2>/dev/null)" || fields=""
fi
if [ -z "${fields:-}" ] && command -v jq >/dev/null 2>&1; then fields="$(printf '%s' "$input" | parse_jq 2>/dev/null)" || fields=""; fi
[ -n "${fields:-}" ] || ask "the gate cannot parse its input (no python3/jq, or malformed stdin). Answer the prompt yourself and report this."
session_id="$(printf '%s\n' "$fields" | sed -n 1p)"
agent_id="$(printf '%s\n' "$fields" | sed -n 2p)"
tool_name="$(printf '%s\n' "$fields" | sed -n 3p)"
tool_use_id="$(printf '%s\n' "$fields" | sed -n 4p)"
command="$(printf '%s\n' "$fields" | sed -n 5p | base64 -d 2>/dev/null)" || command=""
[ "$tool_name" = "Bash" ] || pass
[ -n "$command" ] || pass

. "$here/../lib/classify.sh"
sdir="$(pp_session_dir "${session_id:-unknown}")"
active="$(pp_kv_get "$sdir/state" active 2>/dev/null || true)"
# a session directory that exists but cannot be read is protocol state we cannot
# trust — inside the scope that is a deny, not a quiet "not under the protocol"
if [ -e "$sdir" ] && [ -z "$active" ] && ! [ -r "$sdir/state" ]; then STATE_BROKEN=1; else STATE_BROKEN=0; fi
[ -n "${PP_TEST_SLEEP:-}" ] && sleep "$PP_TEST_SLEEP"
cmd_norm="$(pp_norm "$command")"

# project-declared wrappers (predict on --also) count as one-way inside the scope
if [ "$active" = 1 ] && [ -r "$sdir/also" ]; then
  while IFS= read -r pfx; do
    [ -n "$pfx" ] || continue
    case "$cmd_norm" in "$pfx"*|*" | $pfx"*|*"&& $pfx"*|*"; $pfx"*) CLS="project:$pfx"; ONEWAY=1; break ;; esac
  done < "$sdir/also"
fi
if [ -z "$CLS" ]; then
  if r="$(pp_classify "$command")"; then CLS="${r%%	*}"; ONEWAY=1
  else rc=$?; if [ "$rc" -eq 2 ]; then CLS="unclassifiable"; ONEWAY=1; else ONEWAY=0; fi; fi
fi
[ "$ONEWAY" = 1 ] || pass
[ "$STATE_BROKEN" = 0 ] || deny "\`$CLS\` is a one-way action and this session's protocol state exists but cannot be read ($sdir/state) — failing closed. Fix the permissions or run predict on again."

mode="$(pp_mode "$agent_id")"
predict="\"$PLUGIN_ROOT/bin/predict\""
q="$(printf '%s' "$command" | sed "s/'/'\\\\''/g")"

# ---- outside the protocol's scope: the owner's rule, ask before the irreversible
if [ "$active" != 1 ]; then
  case "$mode" in
    headless) pass ;;
    *) ask "\`$CLS\` is a one-way action and this session is not under the prediction protocol. Approve to run it as-is, or put the session under the protocol first: $predict on <journal-name> (then every one-way action needs a receipt: $predict open …)." ;;
  esac
fi

# ---- inside the scope -----------------------------------------------------------
halted="$(pp_kv_get "$sdir/state" halted 2>/dev/null || true)"
if [ -n "$halted" ]; then
  hv="$(cat "$sdir/receipts/$halted/verdict" 2>/dev/null || echo MISS)"
  hh="$(cat "$sdir/receipts/$halted/hypothesis" 2>/dev/null || true)"
  deny "session halted after $hv on predict $halted (hypothesis: $hh). One-way actions stay blocked until the belief is named: $predict ack $halted --refuted '<what turned out false, one line>' — or $predict retry $halted / $predict withdraw $halted --reason '…'. Then re-issue the command."
fi
if [ "$mode" = subagent ]; then
  deny "\`$CLS\` is a one-way action and this call comes from a subagent (agent_id $agent_id). Subagents do not open one-way doors: report this command as a finding to the orchestrator; do not write a receipt."
fi

recipe="Write the prediction first, then re-issue the SAME command once:
  $predict open --action '$q' --hypothesis '<what you believe about the system, one line>' --observe '<a measurement command, not the action>' --expect '<exit=N | stdout==X | stdout~=ERE | count=N | http=NNN | lines=N | stdout-in=A..B>'
After the command ran: $predict close <id>  (it runs the measurement and grades HIT/MISS/INCONCLUSIVE itself; a MISS halts further one-way actions until $predict ack <id> --refuted '…')."

match=""; inflight=""; expired=""
if [ -d "$sdir/receipts" ]; then
  for d in "$sdir/receipts"/*/; do
    [ -d "$d" ] || continue
    [ -e "$d/closed" ] && continue
    id="$(basename "$d")"
    if [ -e "$d/consumed" ]; then inflight="$id"; continue; fi
    [ "$(cat "$d/action_norm" 2>/dev/null)" = "$cmd_norm" ] || continue
    opened="$(cat "$d/opened" 2>/dev/null || echo 0)"
    if [ $(( $(pp_now) - opened )) -gt "$PP_TTL" ]; then expired="$id"; continue; fi
    sha_now="$(cat "$d/action_norm" "$d/hypothesis" "$d/observe" "$d/expect" 2>/dev/null | pp_sha)"
    [ "$sha_now" = "$(cat "$d/sha" 2>/dev/null)" ] || { deny "receipt $id was edited after it was opened (sha mismatch) — open a new one. $recipe"; }
    match="$id"; break
  done
fi
[ -z "$inflight" ] || deny "receipt $inflight is consumed but not closed — one receipt in flight: $predict close $inflight first (then open a new receipt for this command)."
if [ -z "$match" ]; then
  [ -z "$expired" ] || deny "receipt $expired for this command is older than $((PP_TTL/60)) minutes — open a fresh one. $recipe"
  deny "\`$CLS\` is a one-way action and this session is under the prediction protocol ($(pp_kv_get "$sdir/state" journal 2>/dev/null || echo '?')), but no open receipt names this exact command. $recipe"
fi

# consume: one receipt = one tool call
printf '%s %s\n' "$(pp_now)" "${tool_use_id:-?}" > "$sdir/receipts/$match/consumed"
hyp="$(cat "$sdir/receipts/$match/hypothesis")"; obs="$(cat "$sdir/receipts/$match/observe")"; exp="$(cat "$sdir/receipts/$match/expect")"
case "$mode" in
  headless) pass ;;
  *) ask "predict $match — hypothesis: $hyp · observe: \`$obs\` → expect $exp (falsifier: $(pp_falsifier "$exp")). Approve to fire \`$cmd_norm\`; afterwards: $predict close $match." ;;
esac
