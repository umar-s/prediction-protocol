#!/usr/bin/env bash
# predict-fired.sh — PostToolUse hook on Bash (side effect only; it cannot
# block). When the tool call that consumed a receipt has actually executed,
# mark the receipt `fired`; `predict close` refuses a gated receipt without
# it — a declined prompt or a sibling hook's deny must not turn into a graded
# verdict for an action that never ran. Exit 0 always.
set -u; export LC_ALL=C
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/../lib/common.sh" 2>/dev/null || exit 0
input="$(cat)" || exit 0
fields=""
if command -v python3 >/dev/null 2>&1; then fields="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("session_id") or ""); print(d.get("tool_use_id") or "")' 2>/dev/null)"; fi
[ -n "$fields" ] || { command -v jq >/dev/null 2>&1 && fields="$(printf '%s' "$input" | jq -r '[(.session_id//""),(.tool_use_id//"")]|.[]' 2>/dev/null)"; }
[ -n "$fields" ] || exit 0
session_id="$(printf '%s\n' "$fields" | sed -n 1p)"; tool_use_id="$(printf '%s\n' "$fields" | sed -n 2p)"
sess="${PP_SESSION:-$session_id}"; [ -n "$sess" ] && pp_valid_session "$sess" || exit 0
[ -n "$tool_use_id" ] || exit 0
sdir="$(pp_session_dir "$sess")"; [ -d "$sdir/receipts" ] || exit 0
for d in "$sdir/receipts"/*/; do
  [ -e "$d/consumed" ] || continue; [ -e "$d/closed" ] && continue
  case "$(cat "$d/consumed" 2>/dev/null)" in *" $tool_use_id") pp_utc > "$d/fired" 2>/dev/null; break ;; esac
done
exit 0
