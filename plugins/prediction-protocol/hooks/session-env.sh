#!/usr/bin/env bash
# session-env.sh — SessionStart hook. Tells the session where `bin/predict`
# is, so a consumer skill can call "${PREDICT:?}" before any deny has told it
# the path, and an unset PREDICT is an honest "plugin not installed".
# Claude Code: `export PREDICT=…` appended to CLAUDE_ENV_FILE — the preamble of
# every later Bash call. Codex has no environment file: the same fact goes
# into the session context as `additionalContext` (verified 0.162.1), and the
# shell step exports it. Side-effect only; never blocks; never fails the start.
set -u
root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
p="$root/bin/predict"
[ -x "$p" ] || exit 0
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  grep -q '^export PREDICT=' "$CLAUDE_ENV_FILE" 2>/dev/null || printf 'export PREDICT=%q\n' "$p" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
  exit 0
fi
# JSON string: backslashes and quotes escaped, control bytes dropped (an unescaped one is invalid JSON → the hook is marked failed)
esc="$(printf '%s' "$p" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"prediction-protocol: the predict CLI of this session is %s. In every shell step that calls it, first run: export PREDICT=%s — receipts are keyed by the session id the platform exports to the shell (CODEX_SESSION_ID on Codex, CLAUDE_CODE_SESSION_ID on Claude Code); if predict reports nested harnesses, also export PP_SESSION with the id of the session whose gate this shell is under."}}\n' "$esc" "$esc"
exit 0
