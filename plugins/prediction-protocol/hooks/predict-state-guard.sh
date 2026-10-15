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
input="$(cat)" || exit 0
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"prediction-protocol: the session state under prediction-protocol/sessions/ is written only by the predict CLI and the gate; editing it is a bypass. Use predict ack / retry / withdraw / off instead."}}\n'
  printf 'prediction-protocol: editing the protocol state is a bypass\n' >&2
  exit 2
}
is_state() { case "$1" in *prediction-protocol/sessions/*|*"${PP_STATE_DIR:-/nonexistent-state-root}/sessions/"*) return 0 ;; esac; return 1; }
re='"(file_path|notebook_path)":"([^"]*)"'
rest="$input"
while [[ "$rest" =~ $re ]]; do
  p="${BASH_REMATCH[2]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"
  is_state "$p" && deny
done
case "$input" in *'"tool_name":"apply_patch"'*|*'"tool_name": "apply_patch"'*)
  # a header starts a line of the patch: in the JSON text that is a literal backslash-n (or the opening quote) before the stars;
  # a content line carries its own leading +/-/space, so a header-shaped line inside the content never matches
  re='(\\n|")\*\*\* (Add File|Update File|Delete File|Move to): ([^"\\]*)'
  rest="$input"
  while [[ "$rest" =~ $re ]]; do
    p="${BASH_REMATCH[3]}"; rest="${rest#*"${BASH_REMATCH[0]}"}"
    is_state "${p%"${p##*[![:space:]]}"}" && deny
  done ;;
esac
exit 0
