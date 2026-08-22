#!/usr/bin/env bash
# predict-state-guard.sh — PreToolUse hook on Edit/Write/MultiEdit/NotebookEdit:
# the session state under …/prediction-protocol/sessions/ is written only by
# bin/predict and the gate. An edit there through the file tools is a bypass
# by construction — deny. (Bash writes to the same path are classified as
# `state-tamper` by lib/classify.sh.) Only the target path is inspected —
# `file_path` / `notebook_path` — never the content: a document that *mentions*
# the state directory is not an edit of it. Exit 0 with no output otherwise.
set -u; export LC_ALL=C
input="$(cat)" || exit 0
re='"(file_path|notebook_path)":"([^"]*)"'
while [[ "$input" =~ $re ]]; do
  p="${BASH_REMATCH[2]}"; input="${input#*"${BASH_REMATCH[0]}"}"
  case "$p" in
    *prediction-protocol/sessions/*|*"${PP_STATE_DIR:-/nonexistent-state-root}/sessions/"*)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"prediction-protocol: the session state under prediction-protocol/sessions/ is written only by the predict CLI and the gate; editing it is a bypass. Use predict ack / retry / withdraw / off instead."}}\n'
      printf 'prediction-protocol: editing the protocol state is a bypass\n' >&2
      exit 2 ;;
  esac
done
exit 0
