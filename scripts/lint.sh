#!/usr/bin/env bash
# Repository-side invariants — the written rules of the spec and of the review
# round, as greps. Every rule here has a negative control in tests/run.sh or a
# corpus line; a rule that exists only in prose is protected only by memory.
set -u
cd "$(dirname "$0")/.."
P=plugins/prediction-protocol; fail=0
err() { echo "lint: $*"; fail=1; }
v_json="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' $P/.claude-plugin/plugin.json)"
v_lib="$(sed -n 's/^PP_VERSION="\([^"]*\)".*/\1/p' $P/lib/common.sh)"
[ "$v_json" = "$v_lib" ] || err "version drift: plugin.json $v_json vs lib/common.sh $v_lib"
grep -q "^## \[$v_json\]" CHANGELOG.md || err "CHANGELOG.md has no section for $v_json"
# the hook never answers allow (word match, comments excluded), matcher is the literal Bash, timeouts explicit
grep -nwi 'allow' $P/hooks/predict-gate.sh $P/lib/common.sh $P/hooks/predict-state-guard.sh | grep -v ':[0-9]*:[[:space:]]*#' | grep -v 'never' >/dev/null && err "the word allow appears in a hook"
grep -q '"matcher": "Bash"' $P/hooks/hooks.json || err "hooks.json: the gate matcher must be the literal Bash"
grep -q '"matcher": "Edit|Write|MultiEdit|NotebookEdit"' $P/hooks/hooks.json || err "hooks.json lost the state guard"
grep -q 'file_path|notebook_path' $P/hooks/predict-state-guard.sh && grep -q 'BASH_REMATCH' $P/hooks/predict-state-guard.sh || err "state guard must inspect the target path, not the whole input"
grep -q '"PostToolUse"' $P/hooks/hooks.json && grep -q 'predict-fired.sh' $P/hooks/hooks.json || err "hooks.json lost the PostToolUse fired hook"
grep -q '"SessionStart"' $P/hooks/hooks.json && grep -q 'session-env.sh' $P/hooks/hooks.json || err "hooks.json lost the SessionStart env hook"
grep -q '"timeout": 15' $P/hooks/hooks.json || err "hooks.json must set an explicit timeout on the gate"
python3 -c "import json; json.load(open('$P/hooks/hooks.json')); json.load(open('$P/.claude-plugin/plugin.json'))" 2>/dev/null || err "a manifest does not parse"
# structural fail-closed in the gate
grep -q 'trap on_err ERR' $P/hooks/predict-gate.sh || err "gate lost its inner ERR trap"
grep -q "trap 'deny_literal" $P/hooks/predict-gate.sh || err "gate lost its outer ERR trap"
grep -q 'pp_with_deadline "${PP_DEADLINE:-9}"' $P/hooks/predict-gate.sh || err "gate lost its inner deadline"
grep -q 'pp_prefilter "$input" || pp_prefilter_also "$input" || exit 0' $P/hooks/predict-gate.sh || err "gate lost the pre-filter"
grep -q 'deny_literal "lib/common.sh is missing' $P/hooks/predict-gate.sh || err "gate lost the missing-lib deny"
grep -q 'hook-seen' $P/hooks/predict-gate.sh || err "gate lost the liveness stamp"
# the deny record: every deny of a session with a state dir is written, by both hooks and the wrapper, and read back by status
grep -q '^deny() { pp_note_deny "${sdir:-}" "${CLS:-unclassified}" "${cmd_b64:-}";' $P/hooks/predict-gate.sh || err "gate deny() lost the deny record"
grep -qF 'sdir=""; if [ -n "${PP_SESSION:-}" ] && pp_valid_session "$PP_SESSION"; then sdir=' $P/hooks/predict-gate.sh || err "gate lost the early session dir (a deny before stdin is parsed must still be recorded)"
grep -qF "printf '%s\\t%s\\t%s\\n' \"\$ts\" gate-error \"\" 2>/dev/null > \"\$f\"" $P/hooks/predict-gate.sh && grep -qF 'd="${PP_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/prediction-protocol}/sessions/$s"' $P/hooks/predict-gate.sh || err "deny_literal lost its own gate-error record (every wrapper deny must be recorded, HOME-safe)"
grep -qF '${HOME:-}/.local/state}/prediction-protocol}/sessions/$s"' $P/hooks/predict-state-guard.sh || err "the state guard's record must not depend on HOME being set (set -u would end the hook before its deny)"
# the recorders that run before a deny prints are builtins only: an external process that hung would hold the deny past
# the platform's timeout. Neither a blacklist of command names (sleep, a second substitution), nor a pin of a function's
# text (a redefinition replaces it), nor a snapshot of the definitions after sourcing (code that runs later — a helper the
# gate calls — can redefine it then) can hold that. So every file the deny path executes is pinned whole: both hooks and
# the two libraries the gate sources (pp_note_deny lives in common.sh). Any edit fails here until the pin is updated on
# purpose, after tests/run.sh passes on the edited file (the deny-record and empty-PATH controls among it).
for pin in "$P/hooks/predict-gate.sh 3368c90c8de634568432e75b5d30dc7b3036468846ffef0bb184f22b15bef367" \
           "$P/hooks/predict-state-guard.sh 4505206925e7f71e8171ab33cfd72671cae18f34cf1d0ac0979b3b1833968942" \
           "$P/lib/common.sh 078f17e132f618faf73defc12ae57341af0a7bc9369a4f6daa7cf49bb08d6c61" \
           "$P/lib/classify.sh 463053600459fe19306a213b9d85a8bc007388a39b16a728c41156baa76d8b19"; do
  set -- $pin
  [ "$({ sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -c1-64)" = "$2" ] || err "$(basename "$1") changed — the deny path's recorders must stay builtins only; re-pin its sha256 here only after tests/run.sh passes"
done
for f in "$P/hooks/predict-gate.sh" "$P/hooks/predict-state-guard.sh"; do grep -qF "TZ=UTC0 printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1" "$f" || err "$(basename "$f") lost the builtin UTC timestamp"; done
grep -q "^IFS= read -r -d '' input || true" $P/hooks/predict-state-guard.sh && ! grep -qF '$(cat)' $P/hooks/predict-state-guard.sh || err "the state guard must read stdin with the builtin read, not cat"
grep -q '^  note "$1"$' $P/hooks/predict-state-guard.sh && grep -q 'state-guard' $P/hooks/predict-state-guard.sh || err "state guard lost the deny record"
grep -q 'never changes a decision' $P/lib/common.sh && grep -qF 'set -C; printf' $P/lib/common.sh || err "pp_note_deny must stay best-effort, decision-neutral and one file per record"
# one file per deny, created with noclobber, in every writer: concurrent long records in one appended file interleave
for f in $P/lib/common.sh $P/hooks/predict-gate.sh $P/hooks/predict-state-guard.sh; do
  grep -qF '/deny-${ts//[-:]/}-${BASHPID:-$$}-$RANDOM$RANDOM"' "$f" && grep -qF 'set -C; printf' "$f" || err "$(basename "$f") lost the one-file-per-deny record"
  grep -qE '>> *"[^"]*/denies' "$f" && err "$(basename "$f") appends to a shared denies file (records interleave)"
done
grep -qF 'for f in "$SDIR"/deny-*; do' $P/bin/predict && grep -qF 'an empty or unreadable record file is a deny whose writer died' $P/bin/predict || err "predict status lost the per-file reader or its empty-file rule"
grep -q '"denies":\[%s\]' $P/bin/predict && grep -q 'command_b64' $P/bin/predict && grep -q 'counted as class `corrupt`' $P/bin/predict || err "predict status lost the denies list"
grep -qF "tr '\000-\010\013-\037\177-\377' '[\001*]' < \"\$f\" 2>/dev/null)" $P/bin/predict || err "the status reader lost the byte mapping (NUL and foreign bytes must become a corrupt line, never vanish)"
[ "$(awk '/^cmd_status\(\)/,/^}/' $P/bin/predict | grep -cE '(^|[^_[:alnum:]])seen=')" -eq 1 ] || err "predict status assigns seen more than once — it holds gate_seen, and the reader's own flag of that name overwrote it"
grep -qF "([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\$'" $P/bin/predict && grep -q '"\$b64" =~ \$b64re' $P/bin/predict || err "the status reader lost the full base64 grammar"
grep -q 'pp_delegated "$permission_mode" "$transcript_path"' $P/hooks/predict-gate.sh && [ "$(grep -c '\[ "$delegated" = 0 \] || pass' $P/hooks/predict-gate.sh)" -eq 2 ] || err "gate lost the delegated-session rule (auto mode must not ask; both ask sites)"
grep -q 'auto|dontAsk|bypassPermissions' $P/lib/common.sh && grep -q '"permissionMode":"' $P/lib/common.sh || err "pp_delegated lost a mode or the transcript marker"
# the second harness: Codex has no hook ask — deny where Claude Code asks, silent pass with a receipt, apply_patch guarded, context instead of env file
grep -q '^pp_harness()' $P/lib/common.sh && grep -q 'harness="$(pp_harness "$codex_marker")"' $P/hooks/predict-gate.sh || err "gate lost the harness decision"
grep -q 'PP_ENV_PLUGIN_ROOT="${PLUGIN_ROOT:-}"' $P/hooks/predict-gate.sh || err "gate must capture the environment's PLUGIN_ROOT before reusing the name"
grep -q 'd.get("turn_id") or d.get("model")' $P/hooks/predict-gate.sh && grep -q '.turn_id//""' $P/hooks/predict-gate.sh || err "gate lost the Codex stdin markers in a parser"
grep -q 'cannot ask' $P/hooks/predict-gate.sh || err "gate lost the Codex deny-instead-of-ask"
[ "$(grep -c '\[ "$harness" = claude \] || pass' $P/hooks/predict-gate.sh)" -eq 1 ] || err "gate lost the Codex silent-pass-with-receipt rule (exactly one site)"
grep -q 'pp_mode "$agent_id" "$harness"' $P/hooks/predict-gate.sh && grep -q 'pp_delegated "$permission_mode" "$transcript_path" "$harness"' $P/hooks/predict-gate.sh || err "gate lost the harness argument on mode/delegated"
grep -q 'Add File|Update File|Delete File|Move to' $P/hooks/predict-state-guard.sh && grep -qF '"tool_name"[[:space:]]*:[[:space:]]*"apply_patch"' $P/hooks/predict-state-guard.sh || err "state guard lost the apply_patch headers"
grep -qF '"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"' $P/hooks/predict-state-guard.sh && grep -qF '\"session_id\"[[:space:]]*:[[:space:]]*' $P/hooks/predict-state-guard.sh || err "state guard must accept any JSON whitespace around a key's colon (path, tool name, session id)"
grep -q 'Add File|Update File|Delete File|Move to' $P/lib/classify.sh || err "classifier lost the apply_patch header rule"
grep -q 'additionalContext' $P/hooks/session-env.sh && grep -q 'CLAUDE_ENV_FILE' $P/hooks/session-env.sh || err "session-env lost a delivery path (env file / context)"
grep -q 'pp_session_from_env' $P/bin/predict && grep -q 'pp_in_model_session' $P/bin/predict && grep -q 'CODEX_SESSION_ID' $P/lib/common.sh || err "CLI lost the two-harness session resolution"
grep -q 'for i in 1 2 3 4 5 6 7 8 11 12 14 15' $P/lib/common.sh || err "pp_json_str lost the control-byte escaping"
grep -q 'gtimeout' $P/lib/common.sh || err "pp_with_deadline lost its fallback chain"
grep -q 'export LC_ALL=C' $P/lib/common.sh && grep -q 'export LC_ALL=C' $P/lib/classify.sh || err "LC_ALL=C missing"
grep -q 'CLAUDE_PLUGIN_ROOT' $P/hooks/hooks.json || err "hooks.json must reach the scripts through CLAUDE_PLUGIN_ROOT"
grep -q 'PP_TEST' $P/lib/common.sh || err "PP_NOW must be gated by PP_TEST"
# no network from the payload
grep -nE '\b(curl|wget|nc|ssh)\b' $P/hooks/*.sh $P/lib/common.sh $P/bin/predict | grep -vE ':[0-9]+:[[:space:]]*#' | grep -vE "classify|one-way|reason|deny|ask |'ssh|curl -s|\"\\\$P\"|Bearer|--observe|example" >/dev/null && err "network verb in a hook, common.sh or the CLI"
# CLI: grading stays with the script; measurements are read-only by construction
grep -q 'check_observe "$obs"' $P/bin/predict || err "open lost the read-only check on --observe"
grep -q 'pp_has_secret_shape "$f" && die' $P/bin/predict || err "open lost the secret-shape refusal"
grep -q 'was released to the gate but its action never ran' $P/bin/predict || err "close lost the fired requirement"
grep -q 'retry is for an INCONCLUSIVE receipt' $P/bin/predict || err "retry lost its INCONCLUSIVE-only rule"
grep -q -- '--where' $P/bin/predict || err "ack lost --where"
for v in ack withdraw off; do grep -q "loop_operator_only $v" $P/bin/predict || err "$v lost the loop operator-only rule"; done
grep -q 'gated="no (close-without-gate)"' $P/bin/predict || err "close lost the close-without-gate journal line"
grep -q 'with_lock' $P/bin/predict || err "journal mutations lost the lock"
grep -q 'umask 077' $P/bin/predict || err "CLI lost umask 077"
grep -q 'pp_valid_id' $P/bin/predict && grep -q 'pp_valid_session' $P/bin/predict || err "CLI lost id/session validation"
grep -q 'cmd_lint "$jp"' $P/bin/predict || err "close/report lost the implicit lint"
# classifier: the classes the corpora pin, and the exemptions
for c in migrate sql-opaque-input sql-write kv-write vcs-force vcs-merge release infra service remote-exec remote-write http-write cloud-write secrets publish mail files opaque-exec state-tamper; do
  grep -q "printf '$c'" $P/lib/classify.sh || err "classifier lost class $c"
done
grep -q '_pp_drop_heredocs' $P/lib/classify.sh && grep -q '_pp_lift_substitutions' $P/lib/classify.sh && grep -q '_pp_split' $P/lib/classify.sh || err "classifier lost a parsing stage"
grep -q 'bin/predict|predict)\[\[:space:\]\]+(on|off|open' $P/lib/classify.sh || err "classifier lost the predict-CLI exemption"
[ -s $P/tests/corpus/multiline-deny.txt ] && [ -s $P/tests/corpus/multiline-pass.txt ] || err "multi-line corpora missing"
# SKILL contract: thin, names the commands, the halt rule, the scope rule, platform limits
S=$P/skills/prediction-protocol/SKILL.md
for ph in '"$P" on' '"$P" open' '"$P" close' '"$P" ack' '"$P" report' '"$P" off' 'MISS' 'INCONCLUSIVE' '`Bash` tool only' 'Wrapping is a bypass' 'never write `actual`' 'advisory' 'PREDICT' 'gate: seen' 'PP_SESSION' '--where' '| auto mode' '| Codex' 'CODEX_SESSION_ID' '$prediction-protocol:prediction-protocol' '/hooks' 'apply_patch'; do grep -qF -- "$ph" "$S" || err "SKILL.md lost: $ph"; done
w=$(wc -w < "$S"); [ "$w" -le 1400 ] || err "SKILL.md weight $w words > 1400"
d=$(sed -n '/^description:/p' "$S" | wc -w); [ "$d" -le 90 ] || err "SKILL.md description is $d words (> 90) — it is loaded in every session"
J=$P/skills/prediction-protocol/references/journal.md
for ph in 'contract=1' 'exit=N' 'stdout==' 'stdout~=' 'stdout-in=' 'lines=N' 'http=NNN' 'count=N' 'REFUTED.md' 'predictions:' 'insufficient' 'redaction:' 'gated:' 'ungated' 'gate: seen' '--session-id' 'state-tamper'; do grep -qF -- "$ph" "$J" || err "journal.md lost: $ph"; done
H=$P/skills/prediction-protocol/references/hook-engineering.md
for ph in 'exit 1' 'timeout' 'agent_id' 'CLAUDE_CODE_ENTRYPOINT' 'LC_ALL=C' 'PowerShell' 'allow' 'synthetic stdin' 'control byte' 'watchdog' 'hook-seen' 'CLAUDE_ENV_FILE' 'permission_mode' 'transcript_path' 'permission-mode' 'turn_id' 'trusted_hash' 'apply_patch' 'PLUGIN_ROOT' 'CODEX_SESSION_ID' '--dangerously-bypass-hook-trust' 'bypassPermissions'; do grep -qF -- "$ph" "$H" || err "hook-engineering.md lost: $ph"; done
# house hygiene
grep -rnE '/home/[a-z]+/' $P README.md README.ru.md CHANGELOG.md CLAUDE.md scripts .github 2>/dev/null | grep -v 'tests/corpus' >/dev/null && err "personal absolute path in a tracked file"
grep -q 'claude plugin validate plugins/prediction-protocol' README.md && grep -q 'claude plugin validate plugins/prediction-protocol' README.ru.md && grep -q 'claude plugin validate plugins/prediction-protocol' CLAUDE.md || err "docs lost the correct validate command"
grep -q 'permissions:' .github/workflows/check.yml || err "check.yml has no permissions block"
grep -q '^| auto' README.md && grep -q '^| auto' README.ru.md || err "README pair lost the auto-mode row"
grep -q '^| Codex' README.md && grep -q '^| Codex' README.ru.md || err "README pair lost the Codex row"
grep -q 'codex plugin add prediction-protocol@devpowers' README.md && grep -q 'codex plugin add prediction-protocol@devpowers' README.ru.md || err "README pair lost the Codex install"
grep -q 'platform-probe.sh --codex' README.md && grep -q 'platform-probe.sh --codex' README.ru.md && grep -q -- '--codex' $P/tests/platform-probe.sh || err "the Codex probe is missing or undocumented"
# README pair parity (headings)
diff <(grep -E '^#{1,3} ' README.md | sed -E 's/[^#]//g') <(grep -E '^#{1,3} ' README.ru.md | sed -E 's/[^#]//g') >/dev/null || err "README.md / README.ru.md heading structure differs"
[ "$fail" = 0 ] && echo "lint: OK" || exit 1
