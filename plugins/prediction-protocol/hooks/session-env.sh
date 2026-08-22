#!/usr/bin/env bash
# session-env.sh — SessionStart hook. Exports PREDICT (the absolute path of
# bin/predict) into the session's Bash environment through CLAUDE_ENV_FILE, so
# a consumer skill can call "${PREDICT:?}" before any deny has told it the
# path, and an unset PREDICT is an honest "plugin not installed". Side-effect
# only; never blocks; never fails the session start.
set -u
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -x "$root/bin/predict" ]; then
  printf 'export PREDICT=%q\n' "$root/bin/predict" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi
exit 0
