#!/usr/bin/env bash
# predict-state-guard.sh — PreToolUse hook on Edit/Write/MultiEdit/NotebookEdit:
# the session state under …/prediction-protocol/sessions/ is written only by
# bin/predict and the gate. An edit there through the file tools is a bypass
# by construction — deny. (Bash writes to the same path are classified as
# `state-tamper` by lib/classify.sh.) Only the target path is inspected —
# `file_path` / `notebook_path` on Claude Code; on Codex a file edit arrives as
# tool_name `apply_patch` (the matcher aliases `Edit|Write` select it) with the
# patch in `tool_input.command`, and the targets are its `*** Add File:` /
# `*** Update File:` / `*** Delete File:` / `*** Move to:` headers — never the
# content: a document that *mentions* the state directory, even in a line that
# looks like a header, is not an edit of it. Exit 0 with no output otherwise.
set -u; export LC_ALL=C
IFS= read -r -d '' input || true   # builtin: the hook must not depend on an external process to see its input
# the deny record (lib/common.sh pp_note_deny), inlined: this hook stays minimal and sources nothing,
# and runs no external process before its deny prints — one that hung would let the hook's timeout
# pass the edit. Session as the gate keys it: a runner's PP_SESSION, else the platform's stdin id.
b64() {   # base64 of $1 in pure bash (LC_ALL=C: one character is one byte)
  local s="$1" t='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' o="" i a b c n len=${#1}
  for ((i = 0; i < len; i += 3)); do
    printf -v a '%d' "'${s:i:1}"; b=0; c=0
    ((i + 1 < len)) && printf -v b '%d' "'${s:i+1:1}"
    ((i + 2 < len)) && printf -v c '%d' "'${s:i+2:1}"
    n=$(( ((a & 255) << 16) | ((b & 255) << 8) | (c & 255) ))
    o+="${t:n>>18&63:1}${t:n>>12&63:1}"
    if ((i + 1 < len)); then o+="${t:n>>6&63:1}"; else o+="="; fi
    if ((i + 2 < len)); then o+="${t:n&63:1}"; else o+="="; fi
  done
  printf '%s' "$o"
}
note() {
  local s="${PP_SESSION:-}" d ts=""
  if [ -z "$s" ] && [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then s="${BASH_REMATCH[1]}"; fi   # any JSON whitespace around the colon
  [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || return 0
  d="${PP_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/prediction-protocol}/sessions/$s"   # ${HOME:-}: set -u must not end the hook before its deny
  [ -d "$d" ] || return 0
  TZ=UTC0 printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null || ts=""
  { printf '%s\tstate-guard\t%s\n' "$ts" "$(b64 "$1")" >> "$d/denies"; } 2>/dev/null || true
}
deny() {
  note "$1"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"prediction-protocol: the session state under prediction-protocol/sessions/ is written only by the predict CLI and the gate; editing it is a bypass. Use predict ack / retry / withdraw / off instead."}}\n'
  printf 'prediction-protocol: editing the protocol state is a bypass\n' >&2
  exit 2
}
is_state() { case "$1" in *prediction-protocol/sessions/*|*"${PP_STATE_DIR:-/nonexistent-state-root}/sessions/"*) return 0 ;; esac; return 1; }
re='"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"([^"]*)"'   # any JSON whitespace around the colon
rest="$input"
while [[ "$rest" =~ $re ]]; do
  p="${BASH_REMATCH[2]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"
  is_state "$p" && deny "$p"
done
ap_re='"tool_name"[[:space:]]*:[[:space:]]*"apply_patch"'
if [[ "$input" =~ $ap_re ]]; then
  # a header starts a line of the patch: in the JSON text that is a literal backslash-n (or the opening quote) before the stars;
  # a content line carries its own leading +/-/space, so a header-shaped line inside the content never matches
  re='(\\n|")\*\*\* (Add File|Update File|Delete File|Move to): ([^"\\]*)'
  rest="$input"
  while [[ "$rest" =~ $re ]]; do
    p="${BASH_REMATCH[3]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"
    is_state "${p%"${p##*[![:space:]]}"}" && deny "${p%"${p##*[![:space:]]}"}"
  done
fi
exit 0
