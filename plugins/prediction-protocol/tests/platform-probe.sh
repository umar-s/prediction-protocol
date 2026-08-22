#!/usr/bin/env bash
# platform-probe.sh — the one test that goes THROUGH Claude Code instead of
# feeding the hook synthetic stdin. It proves what the offline suite cannot:
# that the platform blocks on our deny/ask JSON and runs the command on a
# broken hook (so our structural fail-closed is load-bearing). Costs a few
# cheap API calls; run it by hand at release time, not in CI.
#
#   bash tests/platform-probe.sh          # needs `claude` on PATH and auth
set -u
here="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/.claude"
cat > "$W/.claude/gate.sh" <<'G'
#!/usr/bin/env bash
mode="$(cat "$(dirname "$0")/MODE" 2>/dev/null || echo none)"
case "$mode" in
  deny) printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"PROBE-DENY"}}\n' ;;
  ask)  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"PROBE-ASK"}}\n' ;;
  exit2) echo "PROBE-EXIT2" >&2; exit 2 ;;
  exit1) echo "PROBE-EXIT1" >&2; exit 1 ;;
  badjson) echo '{"hookSpecificOutput": {"permissionDecision": "deny"'; ;;
  sleep) sleep 8 ;;
esac
exit 0
G
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \\"$CLAUDE_PROJECT_DIR/.claude/gate.sh\\"","timeout":3}]}]}}\n' > "$W/.claude/settings.json"
P='Run this exact bash command using the Bash tool: echo PROBE-OK-$((40+2)). Reply with ONLY the command output verbatim, or the single word BLOCKED if the tool call was denied or failed.'
cd "$W"
expect() { # mode expected-substring
  echo "$1" > .claude/MODE
  local out; out="$(timeout 120 claude -p "$P" --model "${PROBE_MODEL:-claude-haiku-4-5-20251001}" --allowedTools Bash 2>&1 | tail -1)"
  if printf '%s' "$out" | grep -q "$2"; then echo "ok    $1 → $out"; else echo "FAIL  $1 → $out (expected *$2*)"; fail=1; fi
}
fail=0
expect deny BLOCKED; expect ask BLOCKED; expect exit2 BLOCKED
expect exit1 PROBE-OK-42; expect badjson PROBE-OK-42; expect sleep PROBE-OK-42
echo "platform-probe: the last three rows RAN — the platform is fail-open on a broken hook; the gate's own trap/deadline is what keeps it closed."
exit $fail
