#!/usr/bin/env bash
# predict-state-guard.sh — PreToolUse hook on Edit/Write/MultiEdit/NotebookEdit:
# the session state under …/prediction-protocol/sessions/ is written only by
# bin/predict and the gate. An edit there through the file tools is a bypass
# by construction — deny. (Bash writes to the same path are classified as
# `state-tamper` by lib/classify.sh.) Exit 0 with no output for every other path.
set -u; export LC_ALL=C
input="$(cat)" || exit 0
case "$input" in
  *prediction-protocol/sessions/*|*"${PP_STATE_DIR:-/nonexistent-state-root}/sessions/"*)
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"prediction-protocol: the session state under prediction-protocol/sessions/ is written only by the predict CLI and the gate; editing it is a bypass. Use predict ack / retry / withdraw / off instead."}}\n'
    printf 'prediction-protocol: editing the protocol state is a bypass\n' >&2
    exit 2 ;;
esac
exit 0
