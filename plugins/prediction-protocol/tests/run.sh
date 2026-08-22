#!/usr/bin/env bash
# Negative controls for prediction-protocol — the §10 fixture matrix of the
# design-spec. Every row is a concrete stdin / state / command, and every
# assertion names what it expects. Runs offline in a few seconds.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$here/.." && pwd)"
gate="$P/hooks/predict-gate.sh"; predict="$P/bin/predict"
T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
export PP_STATE_DIR="$T/state" PP_SESSION="abcdef12-test" PP_ENTRYPOINT=cli HOME="$T/home"; mkdir -p "$HOME"
unset PP_NOW CLAUDE_CODE_ENTRYPOINT
pass=0 fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $*"; }
check(){ if eval "$2"; then ok; else bad "$1"; fi; }
stdin(){ # session cmd [extra-json]
  printf '{"session_id":"%s","tool_name":"Bash","tool_use_id":"t1"%s,"tool_input":{"command":%s}}' "$1" "${3:-}" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")"; }
gate(){ # session cmd [extra] → stdout; GRC=exit
  OUT="$(stdin "$1" "$2" "${3:-}" | bash "$gate" 2>"$T/err")"; GRC=$?; }
decision(){ printf '%s' "$OUT" | sed -n 's/.*"permissionDecision":"\([a-z]*\)".*/\1/p'; }

echo "# 1 classifier corpora"
bash "$here/classify-corpus.sh" >/dev/null && ok || bad "classify corpora"

echo "# 2 out of scope"
gate s0 'git push --force origin main';           check "oos interactive one-way → ask"      '[ "$(decision)" = ask ] && [ $GRC -eq 0 ]'
gate s0 'ls -la';                                  check "oos irrelevant → silent exit 0"     '[ -z "$OUT" ] && [ $GRC -eq 0 ]'
PP_ENTRYPOINT=sdk-cli gate s0 'git push --force origin main'; check "oos headless one-way → silent exit 0" '[ -z "$OUT" ] && [ $GRC -eq 0 ]'
OUT="$(stdin s0 'git push --force' | sed 's/"Bash"/"Read"/' | bash "$gate")"; check "non-Bash tool → silent" '[ -z "$OUT" ]'

echo "# 3 predict on / selftest"
mkdir -p "$T/repo" && git -C "$T/repo" init -q && cd "$T/repo"
"$predict" on DEV-1 --also 'make deploy' > "$T/on.out"; check "on prints active+selftest" 'grep -q "predict-gate: active v" "$T/on.out"'
S="$PP_SESSION"
"$predict" status >/dev/null; check "status rc0 when not halted" '[ $? -eq 0 ]'

echo "# 4 in scope, no receipt / subagent / wrappers"
gate "$S" 'git push --force origin main';  check "in-scope no receipt → deny with recipe" '[ "$(decision)" = deny ] && printf "%s" "$OUT" | grep -q "predict.* open --action"'
printf '%s' "$OUT" | grep -q 'v1\.0\.0' && ok || bad "version in reason"
gate "$S" 'git push --force origin main' ',"agent_id":"a1"'; check "subagent → deny 'finding'" '[ "$(decision)" = deny ] && printf "%s" "$OUT" | grep -q "finding"'
gate "$S" 'make deploy';                   check "--also wrapper → deny"              '[ "$(decision)" = deny ]'
gate "$S" 'make test';                     check "plain make → silent"                '[ -z "$OUT" ]'
gate "$S" 'git push --force origin main # --help'; check "comment cannot exempt"     '[ "$(decision)" = deny ]'

echo "# 5 open: grammar and triviality"
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'ls' --expect 'nothing' 2>/dev/null;      check "bad claim refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'rm -rf ./b' --expect 'count=0' 2>/dev/null; check "observe==action refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'ls' --expect 'exit=0' 2>/dev/null;        check "exit-only refused for destructive" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis 'b is disposable' --observe 'ls -d b 2>/dev/null | wc -l' --expect 'count=0' >/dev/null; check "good open" '[ $? -eq 0 ]'
ID1="${S:0:8}-1"

echo "# 6 receipt path"
gate "$S" 'rm -rf ./b';     check "receipt → ask with prediction" '[ "$(decision)" = ask ] && printf "%s" "$OUT" | grep -q "falsifier"'
[ -e "$PP_STATE_DIR/sessions/$S/receipts/$ID1/consumed" ] && ok || bad "consumed mark written"
gate "$S" 'rm -rf ./b';     check "second call → deny (in flight)"  '[ "$(decision)" = deny ] && printf "%s" "$OUT" | grep -q "close"'
gate "$S" 'git push --force origin main'; check "other one-way while in flight → deny" '[ "$(decision)" = deny ]'
PP_ENTRYPOINT=sdk-cli gate "$S" 'rm -rf ./b'; check "headless in flight → still deny" '[ "$(decision)" = deny ]'
mkdir -p b; rm -rf ./b
"$predict" close "$ID1" >/dev/null;  check "close → HIT rc0" '[ $? -eq 0 ]'
gate "$S" 'rm -rf ./b';     check "after close, same cmd → deny (one-shot)" '[ "$(decision)" = deny ]'
"$predict" open --action 'rm -rf ./c' --hypothesis h --observe 'ls -d c 2>/dev/null | wc -l' --expect 'count=0' >/dev/null; ID2="${S:0:8}-2"
PP_ENTRYPOINT=sdk-cli gate "$S" 'rm -rf ./c'; check "headless with receipt → silent exit 0" '[ -z "$OUT" ] && [ $GRC -eq 0 ]'
"$predict" close "$ID2" >/dev/null
"$predict" open --action 'rm -rf ./d' --hypothesis h --observe 'ls -d d 2>/dev/null | wc -l' --expect 'count=0' >/dev/null; ID3="${S:0:8}-3"
PP_NOW=$(( $(date +%s) + 1900 )) gate "$S" 'rm -rf ./d'; check "expired receipt → deny" '[ "$(decision)" = deny ] && printf "%s" "$OUT" | grep -q "older"'
echo tampered > "$PP_STATE_DIR/sessions/$S/receipts/$ID3/hypothesis"
gate "$S" 'rm -rf ./d';     check "edited receipt → deny (sha)" '[ "$(decision)" = deny ] && printf "%s" "$OUT" | grep -q "sha"'
"$predict" withdraw "$ID3" --reason 'test' >/dev/null

echo "# 7 halt at first miss"
echo 3 > n.txt
"$predict" open --action 'git push --force origin main' --hypothesis 'n is 4' --observe 'cat n.txt' --expect 'count=4' >/dev/null; ID4="${S:0:8}-4"
gate "$S" 'git push --force origin main' >/dev/null
"$predict" close "$ID4" >/dev/null; check "close → MISS rc1" '[ $? -eq 1 ]'
"$predict" status >/dev/null 2>&1; check "status rc1 when halted" '[ $? -eq 1 ]'
gate "$S" 'rm -rf ./e';     check "halted → deny any one-way" '[ "$(decision)" = deny ] && printf "%s" "$OUT" | grep -q "halted"'
"$predict" ack "$ID4" --refuted 'the push does not rewrite n.txt' >/dev/null; check "ack rc0" '[ $? -eq 0 ]'
check "REFUTED.md has exactly one row for the id" '[ "$(grep -c "| $ID4 |" docs/evidence/REFUTED.md)" -eq 1 ]'
check "journal entry got the refuted line" 'grep -q "^- refuted: the push" docs/evidence/DEV-1.md'
gate "$S" 'rm -rf ./e';     check "after ack → back to deny-without-receipt (not halted)" '! printf "%s" "$OUT" | grep -q halted'
"$predict" open --action 'rm -rf ./f' --hypothesis h --observe 'no-such-cmd-zz' --expect 'count=1' >/dev/null; ID5="${S:0:8}-5"
gate "$S" 'rm -rf ./f' >/dev/null; "$predict" close "$ID5" >/dev/null; check "observe missing → INCONCLUSIVE rc1" '[ $? -eq 1 ]'
gate "$S" 'rm -rf ./g';     check "INCONCLUSIVE halts too" '[ "$(decision)" = deny ]'
"$predict" withdraw "$ID5" --reason 'no cluster here' >/dev/null; check "withdraw clears halt" '"$predict" status >/dev/null 2>&1'
check "withdraw rewrote the header, no duplicate" '[ "$(grep -c "^### predict $ID5 " docs/evidence/DEV-1.md)" -eq 1 ] && grep -q "^### predict $ID5 .*verdict=withdrawn" docs/evidence/DEV-1.md'
"$predict" open --action 'rm -rf ./h' --hypothesis h --observe 'no-such-cmd-zz' --expect 'count=1' >/dev/null; ID6="${S:0:8}-6"
gate "$S" 'rm -rf ./h' >/dev/null; "$predict" close "$ID6" >/dev/null
echo 1 > k.txt; printf 'cat k.txt' > "$PP_STATE_DIR/sessions/$S/receipts/$ID6/observe"   # fix the measurement, then retry
"$predict" retry "$ID6" >/dev/null; check "retry → HIT rc0, halt cleared" '[ $? -eq 0 ] && "$predict" status >/dev/null 2>&1'
check "retried entry is superseded" 'grep -q "^### predict $ID6 .*verdict=superseded" docs/evidence/DEV-1.md && grep -q "^- superseded-by: ${S:0:8}-7" docs/evidence/DEV-1.md'

echo "# 8 secrets at the sink"
"$predict" open --scope advisory --action 'curl -s localhost:1/h' --hypothesis h --observe 'printf "Authorization: Bearer abcdefghijklmnop123456\nAKIAABCDEFGHIJKLMNOP\npassword=hunter22\n200\n"' --expect 'stdout~=200' >/dev/null; ID8="${S:0:8}-8"
"$predict" close "$ID8" >/dev/null
check "actual redacted (Bearer, AKIA, password=)" '! grep -q "abcdefghijklmnop123456\|AKIAABCDEFGHIJKLMNOP\|hunter22" docs/evidence/DEV-1.md'
"$predict" open --scope advisory --action 'curl -s localhost:1/h' --hypothesis h --observe 'curl -s -H "Authorization: Bearer zyxwvutsrqponmlk987654" localhost:1/h; echo 200' --expect 'stdout~=200' >/dev/null; ID9="${S:0:8}-9"
"$predict" close "$ID9" >/dev/null
check "token inside the measurement command is redacted in the journal" '! grep -q zyxwvutsrqponmlk987654 docs/evidence/DEV-1.md'
check "lint is clean on the produced journal" '"$predict" lint docs/evidence/DEV-1.md >/dev/null'

echo "# 9 lint catches hand-written entries"
L="$T/bad.md"; cp docs/evidence/DEV-1.md "$L"
printf '### predict zz-1 · 2026-08-22T00:00:00Z · scope=destructive · verdict=HIT · contract=1\n- hypothesis: h\n- action: `rm -rf x`\n- observe: `ls` → expect `count=0` (falsifier: count ≠ 0)\n- actual: `exit=0 stdout=0`\n\n' >> "$L"
"$predict" lint "$L" > "$T/l.out" 2>&1; check "verdict without grader stamp fails" 'grep -q "no grader stamp" "$T/l.out"'
cp docs/evidence/DEV-1.md "$L"; printf '### predict zz-2 · 2026-08-22T00:00:00Z · scope=destructive · verdict=HIT · contract=1\n- hypothesis: h\n- action: `rm -rf x`\n- observe: `rm -rf x` → expect `exit=0` (falsifier: exit ≠ 0)\n- actual: `exit=0 stdout=`\n- graded-by: predict v1.0.0 @ 2026-08-22T00:00:00Z · session zz\n\n' >> "$L"
"$predict" lint "$L" > "$T/l.out" 2>&1; check "measures-itself + exit-only fail" 'grep -q "measures the action itself" "$T/l.out" && grep -q "only an exit code" "$T/l.out"'
cp docs/evidence/DEV-1.md "$L"; printf '### predict zz-3 · 2026-08-22T00:00:00Z · scope=destructive · verdict=MISS · contract=1\n- hypothesis: h\n- action: `rm -rf x`\n- observe: `ls` → expect `count=0` (falsifier: count ≠ 0)\n- actual: `exit=0 stdout=1`\n- graded-by: predict v1.0.0 @ 2026-08-22T00:00:00Z · session zz\n\n' >> "$L"
"$predict" lint "$L" > "$T/l.out" 2>&1; check "MISS without ack fails" 'grep -q "without a refuted line" "$T/l.out"'
cp docs/evidence/DEV-1.md "$L"; printf '### predict zz-4 · 2026-08-22T00:00:00Z · scope=advisory · verdict=HIT · contract=1\n- hypothesis: h\n- action: `curl x`\n- observe: `ls` → expect `stdout~=x` (falsifier: x)\n- actual: `exit=0 stdout=AKIAABCDEFGHIJKLMNOP`\n- graded-by: predict v1.0.0 @ 2026-08-22T00:00:00Z · session zz\n\n' >> "$L"
"$predict" lint "$L" > "$T/l.out" 2>&1; check "secret shape fails" 'grep -q "secret shape" "$T/l.out"'
cp docs/evidence/DEV-1.md "$L"; printf '### predict zz-5 · 2026-08-22T00:00:00Z · scope=destructive · verdict=HIT · contract=2\n- graded-by: predict v1.0.0 @ x · session zz\n\n' >> "$L"
"$predict" lint "$L" > "$T/l.out" 2>&1; check "contract mismatch fails" 'grep -q "contract 2" "$T/l.out"'

echo "# 10 report"
R="$("$predict" report)"; check "report line shape" 'printf "%s" "$R" | grep -Eq "^predictions: [0-9]+ HIT / [0-9]+ MISS / [0-9]+ INCONCLUSIVE / [0-9]+ bypass / [0-9]+ open · scope=destructive [0-9]+/[0-9]+/[0-9]+ · n=[0-9]+ · rate=insufficient"'
RJ="$("$predict" report --json)"; check "report json counts inconclusive in n" 'printf "%s" "$RJ" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"n\"]==d[\"hit\"]+d[\"miss\"]+d[\"inconclusive\"]; assert d[\"contract\"]==1"'
check "superseded/withdrawn not counted in n" 'printf "%s" "$RJ" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"withdrawn\"]>=1; assert d[\"inconclusive\"]==0, d; assert d[\"n\"]==6, d"'

echo "# 11 off / bypass"
"$predict" off 2>/dev/null; check "off without reason refused" '[ $? -eq 2 ]'
"$predict" off --reason 'incident' >/dev/null; check "off rc0" '[ $? -eq 0 ]'
gate "$S" 'git push --force origin main'; check "after off → ask (outside scope)" '[ "$(decision)" = ask ]'
check "bypass entry in journal" 'grep -q "verdict=bypass" docs/evidence/DEV-1.md'
"$predict" open --action 'rm -rf ./z' --hypothesis h --observe 'ls' --expect 'count=0' 2>/dev/null; check "open refused when off" '[ $? -eq 2 ]'

echo "# 12 fail-closed error paths"
"$predict" on DEV-2 >/dev/null
OUT="$(echo '{not json' | bash "$gate")"; check "malformed stdin → ask" '[ "$(decision)" = ask ]'
# a PATH with coreutils but without python3 and jq
mkdir -p "$T/bin"; for b in bash cat sed timeout base64 date sha256sum shasum tr awk grep head tail mktemp basename dirname rm wc cut sleep mv cp ls git printf env; do p="$(command -v $b 2>/dev/null)" && ln -sf "$p" "$T/bin/$b"; done
OUT="$(stdin "$S" 'git push --force origin main' | PATH="$T/bin" bash "$gate" 2>/dev/null)"; check "no python3/jq in PATH → ask (cannot parse), never silent" '[ "$(decision)" = ask ]'
OUT="$(stdin "$S" 'git push --force origin main' | PP_DEADLINE=1 PP_TEST_SLEEP=3 bash "$gate" 2>/dev/null)"; GRC=$?; check "deadline overrun → deny, exit 2" '[ "$(decision)" = deny ] && [ $GRC -eq 2 ]'
OUT="$(stdin "$S" 'ls' | PP_DEADLINE=1 PP_TEST_SLEEP=3 bash "$gate" 2>/dev/null)"; GRC=$?; check "deadline overrun on an irrelevant command → still deny (the wrapper cannot know)" '[ "$(decision)" = deny ]'
chmod 000 "$PP_STATE_DIR/sessions/$S"; gate "$S" 'git push --force origin main'; chmod 755 "$PP_STATE_DIR/sessions/$S"; check "unreadable state + one-way → deny" '[ "$(decision)" = deny ]'
chmod 000 "$PP_STATE_DIR/sessions/$S"; gate "$S" 'ls'; chmod 755 "$PP_STATE_DIR/sessions/$S"; check "unreadable state + irrelevant → silent" '[ -z "$OUT" ]'
OUT="$(stdin "$S" 'git push --force origin main' | PP_NOW=notanumber bash "$gate" 2>/dev/null)"; GRC=$?; check "internal error on a one-way → deny" '[ "$(decision)" = deny ]'
grep -q '"allow"' "$gate" && bad "the word allow appears in the hook" || ok
"$predict" selftest >/dev/null; check "selftest rc0" '[ $? -eq 0 ]'

echo "# 13 session-env hook"
E="$T/env"; : > "$E"; CLAUDE_ENV_FILE="$E" CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/session-env.sh"; check "SessionStart exports PREDICT" 'grep -q "^export PREDICT=.*bin/predict$" "$E"'
( . "$E"; [ -x "$PREDICT" ] ) && ok || bad "exported PREDICT is executable"
CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/session-env.sh"; check "session-env without CLAUDE_ENV_FILE exits 0" '[ $? -eq 0 ]'

echo "tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
