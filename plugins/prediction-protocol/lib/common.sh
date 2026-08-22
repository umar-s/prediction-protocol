#!/usr/bin/env bash
# common.sh — shared by hooks/predict-gate.sh and bin/predict. Sourced.
# Session state lives OUTSIDE the repository, keyed by the Claude Code session
# id, and is written only by bin/predict (plus the hook's `consumed` mark).
export LC_ALL=C
PP_VERSION="1.0.0"                      # lint: must equal .claude-plugin/plugin.json
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
# key=value file helpers (values are single-line)
pp_kv_get() { [ -r "$1" ] || return 1; sed -n "s/^$2=//p" "$1" | head -1; }
pp_kv_set() {   # file key value
  local f="$1" k="$2" v="$3" tmp
  tmp="$f.tmp.$$"; { [ -r "$f" ] && grep -v "^$k=" "$f"; printf '%s=%s\n' "$k" "$v"; } > "$tmp" && mv -f "$tmp" "$f"
}
pp_kv_del() { local f="$1" k="$2" tmp="$1.tmp.$$"; [ -r "$f" ] || return 0; grep -v "^$k=" "$f" > "$tmp"; mv -f "$tmp" "$f"; }
# execution context, decided from what the platform actually provides (verified
# on Claude Code 2.1.239): agent_id on stdin → subagent; CLAUDE_CODE_ENTRYPOINT
# "cli" → interactive; "sdk-cli" (claude -p) → headless. Unknown → interactive
# (the safer failure: a prompt the human sees, not a silent pass).
pp_mode() {   # $1 = agent_id (may be empty)
  if [ -n "$1" ]; then printf 'subagent'; return; fi
  local e="${PP_ENTRYPOINT:-${CLAUDE_CODE_ENTRYPOINT:-cli}}"
  case "$e" in sdk*|headless*) printf 'headless' ;; *) printf 'interactive' ;; esac
}
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
