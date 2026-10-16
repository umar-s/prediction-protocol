#!/usr/bin/env bash
# common.sh — shared by hooks/predict-gate.sh and bin/predict. Sourced.
# Session state lives OUTSIDE the repository, keyed by the Claude Code session
# id, and is written only by bin/predict (plus the hook's `consumed` mark).
export LC_ALL=C
PP_VERSION="1.2.0"                      # lint: must equal .claude-plugin/plugin.json
PP_CONTRACT=1                           # journal header contract number
PP_TTL="${PP_TTL:-1800}"                # receipt lifetime, seconds
PP_K="${PP_K:-20}"                      # report: below this n the rate is "insufficient"
PP_STATE_ROOT="${PP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/prediction-protocol}"
PP_ACTUAL_LINES=5; PP_ACTUAL_BYTES=512

# PP_NOW is honoured only under PP_TEST=1 — a clock override in the model's own
# command line must not move a receipt's timestamps
pp_now() { if [ "${PP_TEST:-}" = 1 ] && [ -n "${PP_NOW:-}" ]; then printf '%s' "$PP_NOW"; else date +%s; fi; }
# run a command under a deadline: GNU timeout, gtimeout (macOS coreutils), else a bash watchdog
pp_with_deadline() {
  local n="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout -k 1 "$n" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout -k 1 "$n" "$@"; return $?; fi
  local in rc pid wd; in="$(cat)"
  printf '%s' "$in" | "$@" & pid=$!
  ( sleep "$n"; kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null ) & wd=$!
  wait "$pid"; rc=$?; kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  [ "$rc" -ge 128 ] && rc=124
  return "$rc"
}
# identifiers that become paths and regex anchors
pp_valid_session() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; }
pp_valid_id() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9]+$ ]]; }
pp_sid8() { printf '%s' "$1" | pp_sha | cut -c1-8; }
pp_utc_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
pp_utc() { pp_utc_of "$(pp_now)"; }
pp_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
# normalise a command for receipt matching: one line, single spaces, no trailing ; or space
pp_norm() { printf '%s' "$1" | tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/[ ;]+$//'; }
pp_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-16; else shasum -a 256 | cut -c1-16; fi; }
# JSON string literal (with quotes) from arbitrary text, no external parser.
# Every byte below 0x20 (and DEL) is escaped — an unescaped control character
# makes the whole decision invalid JSON, which the platform treats as no
# decision at all (verified: the command runs).
pp_json_str() {
  local s="$1" i h
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 127; do
    h="$(printf '\\u%04x' "$i")"; local b; b="$(printf "\\$(printf '%03o' "$i")")"
    [ -n "$b" ] && s="${s//"$b"/$h}"
  done
  printf '"%s"' "$s"
}
pp_session_dir() { printf '%s/sessions/%s' "$PP_STATE_ROOT" "$1"; }
# The deny record: one line per deny the hooks issue for a session that has a
# state dir — utc, class, base64 of the exact command as it arrived (the
# parser's own encoding, never decoded and re-encoded: a shell decode drops
# trailing newlines; base64 keeps a command with newlines or tabs one record).
# The hooks run outside any sandbox, a sandboxed model (Codex workspace-write)
# cannot write here, and a consumer reads it through `predict status --json`
# (`denies`), never from a log. It never changes a decision: no state dir →
# nothing written; any error ignored.
pp_note_deny() {   # sdir class command-base64
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  { printf '%s\t%s\t%s\n' "$(pp_utc)" "$2" "${3:-}" >> "$1/denies"; } 2>/dev/null || true
}
# key=value file helpers (values are single-line)
pp_kv_get() { [ -r "$1" ] || return 1; sed -n "s/^$2=//p" "$1" | head -1; }
pp_kv_set() {   # file key value
  local f="$1" k="$2" v="$3" tmp
  tmp="$f.tmp.$$"; { [ -r "$f" ] && grep -v "^$k=" "$f"; printf '%s=%s\n' "$k" "$v"; } > "$tmp" && mv -f "$tmp" "$f"
}
pp_kv_del() { local f="$1" k="$2" tmp="$1.tmp.$$"; [ -r "$f" ] || return 0; grep -v "^$k=" "$f" > "$tmp"; mv -f "$tmp" "$f"; }
# harness: which platform runs this hook. Decided from what each platform
# alone provides (verified Codex CLI 0.162.1 and Claude Code 2.1.283,
# 2026-10-15): Codex serialises `turn_id` and `model` into every PreToolUse
# stdin and sets PLUGIN_ROOT for plugin hooks; Claude Code does neither.
# Environment names such as CLAUDE_CODE_ENTRYPOINT are NOT a signal — a Codex
# started from a Claude shell inherits them. PP_HARNESS is the operator's
# override. Unknown → claude, the platform whose `ask` is known to work.
pp_harness() {   # $1 = 1 when stdin carried a Codex marker; prints claude|codex
  case "${PP_HARNESS:-}" in claude|codex) printf '%s' "$PP_HARNESS"; return ;; esac
  # PP_ENV_PLUGIN_ROOT is the environment's PLUGIN_ROOT, captured by the hook before it reuses that name for its own root
  if [ "${1:-}" = 1 ] || [ -n "${PP_ENV_PLUGIN_ROOT:-}" ]; then printf 'codex'; else printf 'claude'; fi
}
# the entrypoint the mode derives from: PP_ENTRYPOINT (a runner's word) on both
# platforms; CLAUDE_CODE_ENTRYPOINT only on Claude Code — on Codex it is a leak
pp_entrypoint() {   # $1 = harness
  if [ -n "${PP_ENTRYPOINT:-}" ]; then printf '%s' "$PP_ENTRYPOINT"
  elif [ "${1:-claude}" = claude ]; then printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-cli}"
  else printf 'cli'; fi
}
# execution context, decided from what the platform actually provides (verified
# on Claude Code 2.1.239): agent_id on stdin → subagent (Codex sends it for
# spawned subagents too); entrypoint "cli" → interactive; "sdk-cli" (claude -p)
# or "headless" → headless. Unknown → interactive (the safer failure: a prompt
# the human sees — or, on Codex, a deny — not a silent pass).
pp_mode() {   # $1 = agent_id (may be empty), $2 = harness
  if [ -n "$1" ]; then printf 'subagent'; return; fi
  local e; e="$(pp_entrypoint "${2:-claude}")"
  case "$e" in sdk*|headless*) printf 'headless' ;; *) printf 'interactive' ;; esac
}
# A delegated session is one where the human chose not to be asked: auto mode
# (a classifier answers), dontAsk, bypassPermissions. Two sources, either
# suffices: the stdin field `permission_mode` (auto arrives as `default` there,
# verified 2.1.240; Codex maps approval_policy=never to bypassPermissions and
# everything else to default) and, on Claude Code only, the platform's own
# record — the last `"permissionMode":"…"` marker in the session transcript,
# whose path arrives on stdin (a Codex rollout carries no such marker; text in
# it is content, not state). Unreadable or absent → 0: the failure is a prompt.
pp_delegated() {   # $1 = permission_mode from stdin, $2 = transcript_path, $3 = harness; prints 0|1
  local m="$1"
  if [ "${3:-claude}" = claude ] && [ -n "${2:-}" ] && [ -r "$2" ]; then
    local t; t="$(tail -c 262144 "$2" 2>/dev/null | grep -o '"permissionMode":"[A-Za-z]*"' | tail -1 | sed 's/.*:"//; s/"$//')" || t=""
    [ -n "$t" ] && m="$t"
  fi
  case "$m" in auto|dontAsk|bypassPermissions) printf '1' ;; *) printf '0' ;; esac
}
# The session a shell command belongs to, for the CLI: a runner's PP_SESSION,
# else the id the platform exports to the model's shell — CLAUDE_CODE_SESSION_ID
# (Claude Code) or CODEX_SESSION_ID (Codex; equal to the hook's session_id,
# verified 0.162.1). Both present = one harness started inside the other's
# shell; the caller must name the gate it is under. rc 0 ok · 1 none · 3 ambiguous
pp_session_from_env() {
  if [ -n "${PP_SESSION:-}" ]; then printf '%s' "$PP_SESSION"; return 0; fi
  local c="${CLAUDE_CODE_SESSION_ID:-}" x="${CODEX_SESSION_ID:-}"
  if [ -n "$c" ] && [ -n "$x" ]; then return 3; fi
  if [ -n "$c" ]; then printf '%s' "$c"; elif [ -n "$x" ]; then printf '%s' "$x"; else return 1; fi
}
pp_in_model_session() { [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ]; }
# built-in redaction — always applied to `actual`; gitleaks (ci/scan-text.sh) on top when present
pp_redact() {
  sed -E \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1 [REDACTED]/' \
    -e 's#://([^/@[:space:]]+):([^@[:space:]]+)@#://[REDACTED]@#g' \
    -e 's/([Aa]uthorization:[[:space:]]*(Bearer |Basic |Token |bearer )?)[^[:space:]$"\x27][^[:space:]"\x27]{7,}/\1[REDACTED]/g' \
    -e 's/(Bearer|Basic|Token|token)[[:space:]]+[A-Za-z0-9._~+\/=-]{8,}/\1 [REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/AKIA[REDACTED]/g' \
    -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}/\1[REDACTED]/g' \
    -e 's/(xox[baprs]-)[A-Za-z0-9-]{10,}/\1[REDACTED]/g' \
    -e 's/(sk|rk)(_live|_test)?[-_][A-Za-z0-9]{16,}/\1[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/[REDACTED JWT]/g' \
    -e 's/("[A-Za-z_]*([Pp][Aa][Ss][Ss][Ww]([Oo][Rr])?[Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii]_?[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss]_?[Kk][Ee][Yy]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee]_?[Kk][Ee][Yy])[A-Za-z_]*"[[:space:]]*:[[:space:]]*")[^"]*"/\1[REDACTED]"/g' \
    -e 's/([A-Za-z_]*([Pp][Aa][Ss][Ss][Ww]([Oo][Rr])?[Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii]_?[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss]_?[Kk][Ee][Yy]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee]_?[Kk][Ee][Yy])[A-Za-z_]*[[:space:]]*[=:][[:space:]]*)[^[:space:],;"]+/\1[REDACTED]/g'
}
# does the text still carry a secret shape after redaction? (lint)
pp_has_secret_shape() {
  printf '%s\n' "$1" | grep -Eq -e '-----BEGIN [A-Z ]*PRIVATE KEY' -e '://[^/@[:space:]]+:[^@[:space:]]+@' -e 'AKIA[0-9A-Z]{16}' -e '(gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}' -e 'xox[baprs]-[A-Za-z0-9-]{10,}' -e 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.' -e '[Aa]uthorization:[[:space:]]*(Bearer |Basic |Token |bearer )?[^[:space:]\[$]{8,}' -e '(sk|rk)(_live|_test)?[-_][A-Za-z0-9]{16,}' \
    -e '(Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+/=-]{8,}' -e '"?[A-Za-z_]*([Pp]assw(or)?d|[Ss]ecret|[Tt]oken|[Aa]pi_?[Kk]ey|[Aa]ccess_?[Kk]ey|[Pp]rivate_?[Kk]ey)[A-Za-z_]*"?[[:space:]]*[=:][[:space:]]*"?[^[:space:],;"\[]{4,}'
}
# expect-claim grammar: exit=N | stdout==LIT | stdout~=ERE | stdout-in=A..B | lines=N | http=NNN | count=N
pp_claim_ok() {
  [[ "$1" == *$'\n'* ]] && return 1
  [[ "$1" =~ ^exit=[0-9]+$ ]] || [[ "$1" =~ ^stdout==[[:space:]]*[^[:space:]].*$ ]] || [[ "$1" =~ ^stdout~=[^[:space:]].*$ ]] || \
  [[ "$1" =~ ^stdout-in=-?[0-9]+(\.[0-9]+)?\.\.-?[0-9]+(\.[0-9]+)?$ ]] || [[ "$1" =~ ^lines=[0-9]+$ ]] || \
  [[ "$1" =~ ^http=[0-9]{3}$ ]] || [[ "$1" =~ ^count=-?[0-9]+$ ]]
}
pp_falsifier() {   # the complement, on the same command
  case "$1" in
    exit=*) printf 'exit ≠ %s' "${1#exit=}" ;;
    stdout==*) printf 'stdout ≠ %s' "${1#stdout==}" ;;
    stdout~=*) printf 'stdout !~ /%s/' "${1#stdout~=}" ;;
    stdout-in=*) printf 'stdout outside %s' "${1#stdout-in=}" ;;
    lines=*) printf 'line count ≠ %s' "${1#lines=}" ;;
    http=*) printf 'status ≠ %s' "${1#http=}" ;;
    count=*) printf 'count ≠ %s' "${1#count=}" ;;
  esac
}
