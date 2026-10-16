#!/usr/bin/env bash
# Negative controls for prediction-protocol — the §10 fixture matrix of the
# design-spec plus the review findings of 2026-08-22. Every row is a concrete
# stdin / state / command and every assertion names what it expects. Offline.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$here/.." && pwd)"
gate="$P/hooks/predict-gate.sh"; predict="$P/bin/predict"; fired="$P/hooks/predict-fired.sh"; guard="$P/hooks/predict-state-guard.sh"
T="$(mktemp -d)"; trap 'cd /; rm -rf "$T"' EXIT
export PP_STATE_DIR="$T/state" PP_SESSION="test-session-A" PP_ENTRYPOINT=cli HOME="$T/home" PP_TEST=1; mkdir -p "$HOME"
unset PP_NOW CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID PP_HARNESS PLUGIN_ROOT CODEX_SESSION_ID
pass=0 fail=0
# credential-shaped strings are assembled at runtime so no tracked line carries one
fake_aws()    { printf 'AKIA%s' "ABCDEFGH" "" | tr -d ' '; printf '%s' "IJKLMNOP"; }
fake_bearer() { printf 'Bearer %s%s' "abcdefghijkl" "mnop123456"; }
fake_bearer2(){ printf 'Bearer %s%s' "zyxwvutsrqpo" "nmlk987654"; }
fake_pw()     { printf 'pass%s=%s' "word" "hunter22"; }
fake_json()   { printf '{"api_%s": "%s"}' "key" "zz9988776655"; }
AUTH="Authorization"
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $*"; }
check(){ if eval "$2"; then ok; else bad "$1"; fi; }
stdin(){ printf '{"session_id":"%s","tool_name":"Bash","tool_use_id":"%s"%s,"tool_input":{"command":%s}}' "$1" "${4:-t1}" "${3:-}" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")"; }
gate(){ OUT="$(stdin "$1" "$2" "${3:-}" "${4:-t1}" | bash "$gate" 2>"$T/err")"; GRC=$?; ERR="$(cat "$T/err")"; }
decision(){ printf '%s' "$OUT" | sed -n 's/.*"permissionDecision":"\([a-z]*\)".*/\1/p'; }
valid_json(){ printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }
is_deny(){ [ "$(decision)" = deny ] && [ "$GRC" -eq 2 ] && valid_json; }
is_ask(){ [ "$(decision)" = ask ] && [ "$GRC" -eq 0 ] && valid_json; }
is_silent(){ [ -z "$OUT" ] && [ "$GRC" -eq 0 ]; }
S="$PP_SESSION"

echo "# 1 classifier corpora"
bash "$here/classify-corpus.sh" >/dev/null && ok || bad "classify corpora"

echo "# 2 out of scope"
gate s0 'git push --force origin main';       check "oos interactive one-way → ask"   'is_ask'
gate s0 'ls -la';                              check "oos irrelevant → silent"         'is_silent'
PP_ENTRYPOINT=sdk-cli gate s0 'git push --force origin main'; check "oos headless one-way → silent" 'is_silent'
PP_ENTRYPOINT=sdk-cli gate s0 'git push --force origin main' ',"agent_id":"a1"'; check "oos headless subagent → silent (nobody to ask)" 'is_silent'
# delegated sessions: the human chose not to be asked — the interactive ask rows go silent, the deny rows stay
for pm in auto dontAsk bypassPermissions; do gate s0 'git push --force origin main' ",\"permission_mode\":\"$pm\""; check "oos permission_mode=$pm → silent (the platform decides)" 'is_silent'; done
for pm in default acceptEdits plan; do gate s0 'git push --force origin main' ",\"permission_mode\":\"$pm\""; check "oos permission_mode=$pm → ask" 'is_ask'; done
gate s0 'git push --force origin main' ',"permission_mode":"auto","agent_id":"a1"'; check "oos delegated subagent → silent" 'is_silent'
printf '{"type":"user","permissionMode":"default"}\n{"type":"permission-mode","permissionMode":"auto","sessionId":"x"}\n' > "$T/tr-auto.jsonl"
printf '{"type":"permission-mode","permissionMode":"auto","sessionId":"x"}\n{"type":"permission-mode","permissionMode":"default","sessionId":"x"}\n' > "$T/tr-back.jsonl"
gate s0 'git push --force origin main' ",\"permission_mode\":\"default\",\"transcript_path\":\"$T/tr-auto.jsonl\""; check "oos stdin default but transcript's last marker auto → silent" 'is_silent'
gate s0 'git push --force origin main' ",\"permission_mode\":\"default\",\"transcript_path\":\"$T/tr-back.jsonl\""; check "oos transcript toggled back to default → ask (last marker wins)" 'is_ask'
gate s0 'git push --force origin main' ",\"permission_mode\":\"default\",\"transcript_path\":\"$T/does-not-exist.jsonl\""; check "oos unreadable transcript → ask (not delegated)" 'is_ask'
OUT="$(stdin s0 'git push --force' | sed 's/"Bash"/"Read"/' | bash "$gate")"; check "non-Bash tool → silent" '[ -z "$OUT" ]'

echo "# 2b Codex harness: the ask cells deny (Codex has no hook ask), the rest of the table is unchanged"
CX=',"turn_id":"t-1","model":"gpt-6-astra"'
gate s0 'git push --force origin main' "$CX"; check "codex oos interactive one-way → deny (cannot ask), both channels" 'is_deny && printf "%s" "$OUT" | grep -q "cannot ask" && printf "%s" "$ERR" | grep -q "cannot ask"'
gate s0 'ls -la' "$CX"; check "codex oos irrelevant → silent" 'is_silent'
gate s0 'git push --force origin main' "$CX"',"permission_mode":"bypassPermissions"'; check "codex exec (approval never arrives as bypassPermissions) oos → silent" 'is_silent'
PLUGIN_ROOT=/x gate s0 'git push --force origin main'; check "PLUGIN_ROOT in the environment alone marks Codex → deny" 'is_deny'
PP_HARNESS=codex gate s0 'git push --force origin main'; check "PP_HARNESS=codex without markers → deny" 'is_deny'
PP_HARNESS=claude gate s0 'git push --force origin main' "$CX"; check "PP_HARNESS=claude overrides the markers → ask" 'is_ask'
CLAUDE_CODE_ENTRYPOINT=sdk-cli gate s0 'git push --force origin main' "$CX"; check "codex ignores an inherited CLAUDE_CODE_ENTRYPOINT=sdk-cli → still deny" 'is_deny'
PP_ENTRYPOINT=headless gate s0 'git push --force origin main' "$CX"; check "codex runner PP_ENTRYPOINT=headless oos → silent" 'is_silent'
gate s0 'git push --force origin main' "$CX"",\"permission_mode\":\"default\",\"transcript_path\":\"$T/tr-auto.jsonl\""; check "codex: transcript markers are content, not consulted → deny" 'is_deny'
gate s0 'git push --force origin main' "$CX"',"agent_id":"a1"'; check "codex subagent oos → deny" 'is_deny'
OUT="$(stdin s0 'git push --force origin main' "$CX" | sed 's/"Bash"/"Read"/' | bash "$gate")"; check "codex non-Bash tool → silent" '[ -z "$OUT" ]'

echo "# 3 predict on / selftest / grammar"
mkdir -p "$T/repo" && git -C "$T/repo" init -q && cd "$T/repo"
"$predict" on DEV-1 --also 'make deploy' > "$T/on.out"; check "on prints active+selftest rc0" '[ $? -eq 0 ] && grep -q "predict-gate: active v" "$T/on.out"'
"$predict" on nightly --loop > "$T/on2.out"; check "on <name> --loop is a flag" '[ $? -eq 0 ] && grep -q "loops/evidence/nightly.md" "$T/on2.out"'
check "on prints exactly two lines (gate line + session line) — a runner parses this" '[ "$(wc -l < "$T/on2.out")" -eq 2 ] && ! grep -qx "0" "$T/on2.out"'
"$predict" on DEV-1 --task >/dev/null
"$predict" on 'bad name' 2>/dev/null; check "journal name validated" '[ $? -eq 2 ]'
PP_SESSION='../x' "$predict" status 2>/dev/null; check "session id validated" '[ $? -eq 2 ]'
"$predict" status >/dev/null; check "status rc0 when not halted" '[ $? -eq 0 ]'
cp -a "$P" "$T/broken"; : > "$T/broken/hooks/predict-gate.sh"
PP_STATE_DIR="$T/state2" "$T/broken/bin/predict" on DEV-9 > "$T/on3.out" 2>&1; check "broken hook → on refuses, session stays outside" '[ $? -eq 2 ] && grep -q "predict-gate: broken" "$T/on3.out" && ! grep -q "^active=1" "$T/state2/sessions/$S/state" 2>/dev/null'

echo "# 4 in scope, no receipt / subagent / wrappers"
gate "$S" 'git push --force origin main';  check "in-scope no receipt → deny with recipe (both channels)" 'is_deny && printf "%s" "$OUT" | grep -q "predict.* open --action" && printf "%s" "$ERR" | grep -q "open --action"'
printf '%s' "$OUT" | grep -qF "v$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$P/.claude-plugin/plugin.json")" && ok || bad "version in reason"
printf '%s' "$OUT" | grep -q "expect '<count=N" && ok || bad "recipe placeholder starts with count=N, not exit=N"
gate "$S" 'git push --force origin main' ',"agent_id":"a1"'; check "subagent → deny 'finding'" 'is_deny && printf "%s" "$OUT" | grep -q finding'
gate "$S" 'make deploy';                   check "--also wrapper → deny"            'is_deny'
gate "$S" 'sudo make deploy';              check "--also after sudo → deny"        'is_deny'
gate "$S" 'make test';                     check "plain make → silent"              'is_silent'
gate "$S" 'git push --force origin main # --help'; check "comment cannot exempt"   'is_deny'
gate "$S" "$(printf 'git push --force origin main\x1b')"; check "control byte → still valid deny JSON" 'is_deny'
gate "$S" '"$PREDICT" open --action '"'"'alembic upgrade head && systemctl restart api'"'"' --hypothesis h --observe ls --expect count=0'; check "predict CLI call is never classified" 'is_silent'
gate "$S" 'echo 1 > ~/.local/state/prediction-protocol/sessions/x/state'; check "state write via Bash → deny (state-tamper)" 'is_deny'
[ -s "$PP_STATE_DIR/sessions/$S/hook-seen" ] && ok || bad "hook-seen stamp written"

echo "# 5 open: grammar, triviality, read-only measurement, secrets"
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'ls' --expect 'nothing' 2>/dev/null;      check "bad claim refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'rm -rf ./b' --expect 'count=0' 2>/dev/null; check "observe==action refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'ls' --expect 'exit=0' 2>/dev/null;        check "exit-only refused for destructive" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'git push --force origin main' --expect 'count=0' 2>/dev/null; check "one-way --observe refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'make deploy' --expect 'count=0' 2>/dev/null; check "--also wrapper as --observe refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis "tok""en=abcdef1234567890abcd" --observe 'ls' --expect 'count=0' 2>/dev/null; check "secret shape in hypothesis refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis "$(printf 'a\nb')" --observe 'ls' --expect 'count=0' 2>/dev/null; check "newline in a field refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe "$(printf 'ls\n### predict x')" --expect 'count=0' 2>/dev/null; check "newline in --observe refused (no forged headers)" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis h --observe 'ls' --expect 'stdout==  ' 2>/dev/null;    check "blank literal refused" '[ $? -eq 2 ]'
"$predict" open --action 'rm -rf ./b' --hypothesis 'b is disposable' --observe 'ls -d b 2>/dev/null | wc -l' --expect 'count=0' > "$T/open.out"; check "good open" '[ $? -eq 0 ]'
ID1="$(sed -n 's/^predict \([0-9a-f-]*\) opened.*/\1/p' "$T/open.out")"; check "id is sha8-seq" '[[ "$ID1" =~ ^[0-9a-f]{8}-1$ ]]'

echo "# 6 receipt lifecycle"
gate "$S" 'rm -rf ./b';     check "receipt → ask with prediction" 'is_ask && printf "%s" "$OUT" | grep -q falsifier'
[ -e "$PP_STATE_DIR/sessions/$S/receipts/$ID1/consumed" ] && ok || bad "consumed mark written"
"$predict" close "$ID1" 2>/dev/null; check "close before fired → refused" '[ $? -eq 2 ]'
gate "$S" 'rm -rf ./b';     check "same command again while consumed-not-fired → deny 'withdraw or close'" 'is_deny && printf "%s" "$OUT" | grep -q withdraw'
stdin "$S" 'rm -rf ./b' '' t1 | bash "$fired"; [ -e "$PP_STATE_DIR/sessions/$S/receipts/$ID1/fired" ] && ok || bad "PostToolUse marks fired"
gate "$S" 'git push --force origin main'; check "other one-way while in flight → deny 'close first'" 'is_deny && printf "%s" "$OUT" | grep -q "close"'
mkdir -p b; rm -rf ./b
"$predict" close "$ID1" >/dev/null;  check "close → HIT rc0" '[ $? -eq 0 ]'
grep -q "^- gated: yes t1" docs/evidence/DEV-1.md && ok || bad "gated line rendered"
gate "$S" 'rm -rf ./b';     check "after close, same cmd → deny (one-shot)" 'is_deny'
# two receipts opened up front: firing the second then the first must hit 'in flight'
"$predict" open --action 'rm -rf ./c' --hypothesis h --observe 'ls -d c 2>/dev/null | wc -l' --expect 'count=0' >/dev/null; ID2="${ID1%-*}-2"
"$predict" open --action 'rm -rf ./d' --hypothesis h --observe 'ls -d d 2>/dev/null | wc -l' --expect 'count=0' >/dev/null; ID3="${ID1%-*}-3"
gate "$S" 'rm -rf ./d' '' t3; check "second receipt fires" 'is_ask'; stdin "$S" 'rm -rf ./d' '' t3 | bash "$fired"
gate "$S" 'rm -rf ./c'; check "first receipt while second in flight → deny" 'is_deny && printf "%s" "$OUT" | grep -q "in flight"'
"$predict" close "$ID3" >/dev/null
PP_ENTRYPOINT=sdk-cli gate "$S" 'rm -rf ./c' '' t2; check "headless with receipt → silent" 'is_silent'
stdin "$S" 'rm -rf ./c' '' t2 | bash "$fired"; "$predict" close "$ID2" >/dev/null
"$predict" open --action 'rm -rf ./e' --hypothesis h --observe 'ls -d e 2>/dev/null | wc -l' --expect 'count=0' >/dev/null; ID4="${ID1%-*}-4"
PP_NOW=$(( $(date +%s) + 1900 )) gate "$S" 'rm -rf ./e'; check "expired receipt → deny" 'is_deny && printf "%s" "$OUT" | grep -q older'
PP_TEST= "$predict" open --action 'rm -rf ./e2' --hypothesis h --observe 'ls' --expect 'count=0' >/dev/null 2>&1
check "PP_NOW ignored without PP_TEST" '[ "$(cat "$PP_STATE_DIR/sessions/$S/receipts/${ID1%-*}-5/opened")" -le "$(date +%s)" ]'
echo tampered > "$PP_STATE_DIR/sessions/$S/receipts/$ID4/hypothesis"
gate "$S" 'rm -rf ./e';     check "edited receipt → deny (sha)" 'is_deny && printf "%s" "$OUT" | grep -q sha'
"$predict" withdraw "$ID4" --reason 'test' >/dev/null; "$predict" withdraw "${ID1%-*}-5" --reason 'test' >/dev/null
gate "$S" 'rm -rf ./x' ',"agent_id":"a1"'; check "subagent with no receipt → deny" 'is_deny'
"$predict" open --action 'rm -rf ./f' --hypothesis h --observe 'ls' --expect 'count=0' >/dev/null; ID6="${ID1%-*}-6"
gate "$S" 'rm -rf ./f' ',"agent_id":"a1"'; check "subagent with receipt → deny, receipt untouched" 'is_deny && ! [ -e "$PP_STATE_DIR/sessions/$S/receipts/$ID6/consumed" ]'
"$predict" withdraw "$ID6" --reason 'test' >/dev/null

echo "# 7 halt at first miss"
echo 3 > n.txt
"$predict" open --action 'git push --force origin main' --hypothesis 'n is 4' --observe 'cat n.txt' --expect 'count=4' >/dev/null; ID7="${ID1%-*}-7"
gate "$S" 'git push --force origin main' '' t7 >/dev/null; stdin "$S" x '' t7 | bash "$fired"
"$predict" close "$ID7" > "$T/c.out"; check "close → MISS rc1, both runs recorded" '[ $? -eq 1 ] && grep -q "confirmed ×2 (run 2" docs/evidence/DEV-1.md'
"$predict" status >/dev/null 2>&1; check "status rc1 when halted" '[ $? -eq 1 ]'
gate "$S" 'rm -rf ./g';     check "halted → deny any one-way" 'is_deny && printf "%s" "$OUT" | grep -q halted'
"$predict" withdraw "$ID7" --reason x 2>/dev/null; check "withdraw on a MISS refused" '[ $? -eq 2 ]'
"$predict" retry "$ID7" 2>/dev/null;           check "retry on a MISS refused" '[ $? -eq 2 ]'
"$predict" on DEV-1 >/dev/null 2>&1;           check "predict on does not clear a halt" '[ $? -eq 1 ] && "$predict" status >/dev/null 2>&1; [ $? -eq 1 ]'
"$predict" open --scope advisory --action 'x' --hypothesis h --observe 'echo 1' --expect 'count=1' >/dev/null; "$predict" close "${ID1%-*}-8" >/dev/null; check "advisory HIT does not clear a halt" '! "$predict" status >/dev/null 2>&1'
"$predict" ack "$ID7" --refuted 'the push does not rewrite n.txt' 2>/dev/null; check "ack without --where refused" '[ $? -eq 2 ]'
"$predict" ack "$ID7" --refuted 'the push does not rewrite n.txt' --where 'n.txt, origin/main' >/dev/null; check "ack rc0" '[ $? -eq 0 ]'
check "REFUTED.md: one row, where column" '[ "$(grep -c "| $ID7 |" docs/evidence/REFUTED.md)" -eq 1 ] && grep -q "| n.txt, origin/main |" docs/evidence/REFUTED.md'
"$predict" ack "$ID7" --refuted x --where y 2>/dev/null; check "ack twice refused" '[ $? -eq 2 ]'
gate "$S" 'rm -rf ./g';     check "after ack → deny-without-receipt (not halted)" 'is_deny && ! printf "%s" "$OUT" | grep -q halted'
"$predict" open --action 'rm -rf ./h' --hypothesis h --observe 'no-such-cmd-zz' --expect 'count=1' >/dev/null; ID9="${ID1%-*}-9"
gate "$S" 'rm -rf ./h' '' t9 >/dev/null; stdin "$S" x '' t9 | bash "$fired"; "$predict" close "$ID9" >/dev/null; check "observe missing → INCONCLUSIVE rc1" '[ $? -eq 1 ]'
gate "$S" 'rm -rf ./i';     check "INCONCLUSIVE halts too" 'is_deny'
echo 1 > k.txt
"$predict" retry "$ID9" --observe 'cat k.txt' >/dev/null; check "retry --observe → HIT, halt cleared" '[ $? -eq 0 ] && "$predict" status >/dev/null 2>&1'
check "retried entry superseded" 'grep -q "^### predict $ID9 .*verdict=superseded" docs/evidence/DEV-1.md'
"$predict" open --action 'rm -rf ./j' --hypothesis h --observe 'echo 0; exit 1' --expect 'count=0' >/dev/null; ID11="${ID1%-*}-11"
gate "$S" 'rm -rf ./j' '' t11 >/dev/null; stdin "$S" x '' t11 | bash "$fired"; "$predict" close "$ID11" >/dev/null; check "non-zero exit on a stdout claim → INCONCLUSIVE (spec §3)" '[ $? -eq 1 ] && grep -q "^### predict $ID11 .*verdict=INCONCLUSIVE" docs/evidence/DEV-1.md'
"$predict" withdraw "$ID11" --reason 'bad measurement' >/dev/null; check "withdraw INCONCLUSIVE clears halt, rewrites header" '"$predict" status >/dev/null 2>&1 && [ "$(grep -c "^### predict $ID11 " docs/evidence/DEV-1.md)" -eq 1 ] && grep -q "^### predict $ID11 .*verdict=withdrawn" docs/evidence/DEV-1.md'
"$predict" open --action 'rm -rf ./k' --hypothesis h --observe 'echo 7' --expect 'stdout-in=5..9' >/dev/null; ID12="${ID1%-*}-12"
gate "$S" 'rm -rf ./k' '' t12 >/dev/null; stdin "$S" x '' t12 | bash "$fired"; "$predict" close "$ID12" >/dev/null; check "stdout-in grades" '[ $? -eq 0 ]'
"$predict" open --action 'rm -rf ./l' --hypothesis h --observe 'printf 000' --expect 'http=000' >/dev/null; ID13="${ID1%-*}-13"
gate "$S" 'rm -rf ./l' '' t13 >/dev/null; stdin "$S" x '' t13 | bash "$fired"; "$predict" close "$ID13" >/dev/null; check "http=000 → INCONCLUSIVE" '[ $? -eq 1 ]'; "$predict" withdraw "$ID13" --reason x >/dev/null

echo "# 8 secrets at the sink"
printf '%s: %s\n%s\n%s\n%s\n200\n' "$AUTH" "$(fake_bearer)" "$(fake_aws)" "$(fake_pw)" "$(fake_json)" > "$T/leaky.txt"
"$predict" open --scope advisory --action 'curl -s localhost:1/h' --hypothesis h --observe "cat $T/leaky.txt" --expect 'stdout~=200' > "$T/o14"; ID14="$(sed -n 's/^predict \([0-9a-f-]*\) opened.*/\1/p' "$T/o14")"
"$predict" close "$ID14" >/dev/null
check "actual redacted (Bearer, AKIA, password=, json key)" '! grep -q "mnop123456\|$(fake_aws)\|hunter22\|zz9988776655" docs/evidence/DEV-1.md'
"$predict" open --scope advisory --action 'curl -s localhost:1/h' --hypothesis h --observe "curl -s -H \"$AUTH: $(fake_bearer2)\" localhost:1/h; echo 200" --expect 'stdout~=200' 2>/dev/null; check "token in --observe refused at open" '[ $? -eq 2 ]'
"$predict" open --scope advisory --action 'curl -s localhost:1/h' --hypothesis h --observe 'curl -s -H "Authorization: Bearer $TOKEN" localhost:1/h; echo 200' --expect 'stdout~=200' > "$T/o15"; ID15="$(sed -n 's/^predict \([0-9a-f-]*\) opened.*/\1/p' "$T/o15")"
"$predict" close "$ID15" >/dev/null; check "env var reference kept as written" 'grep -q "Bearer \$TOKEN" docs/evidence/DEV-1.md'
check "lint is clean on the produced journal" '"$predict" lint docs/evidence/DEV-1.md >/dev/null'

echo "# 9 lint catches hand-written entries"
L="$T/bad.md"
h='### predict 0123abcd-1 · 2026-08-22T00:00:00Z · scope=destructive · verdict=HIT · contract=1'
printf '%s\n- hypothesis: h\n- action: `rm -rf x`\n- observe: `ls` → expect `count=0` (falsifier: count ≠ 0)\n- actual: `exit=0 stdout=0`\n- gated: yes\n\n' "$h" > "$L"; "$predict" lint "$L" > "$T/l.out" 2>&1; check "verdict without grader stamp fails" 'grep -q "no grader stamp" "$T/l.out"'
printf '%s\n- hypothesis: h\n- action: `rm -rf x`\n- observe: `rm -rf x` → expect `exit=0` (falsifier: exit ≠ 0)\n- actual: `exit=0 stdout=`\n- gated: yes\n- graded-by: predict v1.0.0 @ x · session zz\n\n' "$h" > "$L"; "$predict" lint "$L" > "$T/l.out" 2>&1; check "measures-itself + exit-only fail" 'grep -q "measures the action itself" "$T/l.out" && grep -q "only an exit code" "$T/l.out"'
printf '%s\n- hypothesis: h\n- action: `rm -rf x`\n- observe: `ls` → expect `count=0` (falsifier: count ≠ 0)\n- actual: `exit=0 stdout=1`\n- gated: yes\n- graded-by: predict v1.0.0 @ x · session zz\n\n' "${h/HIT/MISS}" > "$L"; "$predict" lint "$L" > "$T/l.out" 2>&1; check "MISS without ack fails" 'grep -q "without a refuted line" "$T/l.out"'
printf '%s\n- hypothesis: h\n- action: `curl x`\n- observe: `ls` → expect `stdout~=x` (falsifier: x)\n- actual: `exit=0 stdout=%s`\n- gated: no\n- graded-by: predict v1.0.0 @ x · session zz\n\n' "${h/destructive/advisory}" "$(fake_aws)" > "$L"; "$predict" lint "$L" > "$T/l.out" 2>&1; check "secret shape fails" 'grep -q "secret shape" "$T/l.out"'
printf '%s\n- graded-by: predict v1.0.0 @ x · session zz\n\n' "${h/contract=1/contract=2}" > "$L"; "$predict" lint "$L" > "$T/l.out" 2>&1; check "contract mismatch fails" 'grep -q "contract 2" "$T/l.out"'
printf '### predict loop_foo-1 · 2026-08-22T00:00:00Z · scope=destructive · verdict=HIT · contract=1\n- graded-by: x\n\n' > "$L"; "$predict" lint "$L" > "$T/l.out" 2>&1; check "non-hex id is a malformed header" 'grep -q "malformed header" "$T/l.out"'
printf '%s\n- hypothesis: h\n- action: `rm -rf x`\n- observe: `ls` → expect `count=0` (falsifier: count ≠ 0)\n- actual: `exit=0 stdout=0`\n- gated: no (close-without-gate)\n- graded-by: predict v1.0.0 @ x · session zz\n\n' "$h" > "$L"; "$predict" lint "$L" > "$T/l.out" 2>&1; check "destructive closed without the gate → warning" 'grep -q "WARNING destructive entry closed without passing the gate" "$T/l.out"'

echo "# 10 report"
R="$("$predict" report)"; check "report line shape incl. ungated and lint" 'printf "%s" "$R" | grep -Eq "^predictions: [0-9]+ HIT / [0-9]+ MISS / [0-9]+ INCONCLUSIVE / [0-9]+ bypass / [0-9]+ ungated / [0-9]+ open · scope=destructive [0-9]+/[0-9]+/[0-9]+ · n=[0-9]+ · rate=insufficient.*· lint=ok · gate: seen"'
RJ="$("$predict" report --json)"; check "report json: n = hit+miss+inconclusive, withdrawn/superseded excluded" 'printf "%s" "$RJ" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"n\"]==d[\"hit\"]+d[\"miss\"]+d[\"inconclusive\"]; assert d[\"withdrawn\"]>=3; assert d[\"inconclusive\"]==0, d; assert d[\"lint_failures\"]==0"'
cp docs/evidence/DEV-1.md "$T/bad2.md"; printf '%s\n- graded-by: x\n\n' "${h/contract=1/contract=2}" >> "$T/bad2.md"; "$predict" report --journal "$T/bad2.md" > "$T/r.out"; check "report runs lint and fails on findings" '[ $? -eq 1 ] && grep -q "lint=FAIL(" "$T/r.out"'

echo "# 10b loops: close-without-gate is counted, ack/withdraw/off are the operator's"
PP_SESSION="lp-1" "$predict" on lp --loop >/dev/null
G="$(PP_SESSION="lp-1" "$predict" open --action 'git push --force origin main' --hypothesis h --observe 'echo 1' --expect count=1 | sed -n 's/^predict \([0-9a-f-]*\) .*/\1/p')"
PP_SESSION="lp-1" "$predict" close "$G" >/dev/null; check "destructive receipt closed without the gate → close-without-gate line (CLI path)" 'grep -q "^- gated: no (close-without-gate)" loops/evidence/lp.md'
PP_SESSION="lp-1" "$predict" report --json > "$T/lp.json"; check "report counts it as ungated" 'grep -q "\"ungated\":1" "$T/lp.json"'
M="$(PP_SESSION="lp-1" "$predict" open --scope advisory --action x --hypothesis h --observe 'echo 1' --expect count=2 | sed -n 's/^predict \([0-9a-f-]*\) .*/\1/p')"
PP_SESSION="lp-1" "$predict" close "$M" >/dev/null 2>&1; check "advisory receipt without the gate → gated: no (advisory), verdict MISS" 'grep -q "^- gated: no (advisory)" loops/evidence/lp.md && [ "$(PP_SESSION=lp-1 "$predict" status --json | sed -n "s/.*\"halted\":\"\([^\"]*\)\".*/\1/p")" = "$M" ]'
PP_SESSION="lp-1" CLAUDE_CODE_SESSION_ID=exec-1 "$predict" ack "$M" --refuted b --where w > "$T/lpa.out" 2>&1; check "loop: ack inside a Claude session is refused" '[ $? -eq 2 ] && grep -q "operator" "$T/lpa.out"'
PP_SESSION="lp-1" CLAUDE_CODE_SESSION_ID=exec-1 "$predict" withdraw "$M" --reason r >/dev/null 2>&1; check "loop: withdraw inside a Claude session is refused" '[ $? -eq 2 ]'
PP_SESSION="lp-1" CLAUDE_CODE_SESSION_ID=exec-1 "$predict" off --reason r >/dev/null 2>&1; check "loop: off inside a Claude session is refused" '[ $? -eq 2 ]'
PP_SESSION="lp-1" "$predict" status >/dev/null 2>&1; check "loop: still halted after the refused ack" '[ $? -eq 1 ]'
PP_SESSION="lp-1" "$predict" ack "$M" --refuted b --where w >/dev/null; check "loop: ack from a plain shell (the operator) works" '[ $? -eq 0 ]'
PP_SESSION="tk-1" "$predict" on TK-1 --task >/dev/null
N="$(PP_SESSION="tk-1" "$predict" open --scope advisory --action x --hypothesis h --observe 'echo 1' --expect count=2 | sed -n 's/^predict \([0-9a-f-]*\) .*/\1/p')"
PP_SESSION="tk-1" "$predict" close "$N" >/dev/null 2>&1
PP_SESSION="tk-1" CLAUDE_CODE_SESSION_ID=exec-1 "$predict" ack "$N" --refuted b --where w >/dev/null; check "task: ack inside a Claude session is the model's act (unchanged)" '[ $? -eq 0 ]'

echo "# 10c delegated session under the protocol: deny without a receipt, silent with one"
PP_SESSION="dl-1" "$predict" on DL-1 --task >/dev/null
PP_SESSION="dl-1" gate dl-1 'git push --force origin main' ',"permission_mode":"auto"'; check "delegated, under the protocol, no receipt → deny + recipe (the witness is required, the human is not)" 'is_deny && printf "%s" "$OUT" | grep -q "open --action"'
D="$(PP_SESSION="dl-1" "$predict" open --action 'rm -rf ./dl' --hypothesis h --observe 'ls -d dl 2>/dev/null | wc -l' --expect 'count=0' | sed -n 's/^predict \([0-9a-f-]*\) .*/\1/p')"
PP_SESSION="dl-1" gate dl-1 'rm -rf ./dl' ',"permission_mode":"auto"' td; check "delegated with a matching receipt → silent pass, receipt consumed" 'is_silent && [ -e "$PP_STATE_DIR/sessions/dl-1/receipts/$D/consumed" ]'
stdin dl-1 'rm -rf ./dl' '' td | PP_SESSION="dl-1" bash "$fired"; mkdir -p dl; rm -rf ./dl; PP_SESSION="dl-1" "$predict" close "$D" >/dev/null; check "delegated receipt closes → HIT" '[ $? -eq 0 ]'
PP_SESSION="dl-1" gate dl-1 'rm -rf ./dl' ',"permission_mode":"auto"'; check "delegated, receipt spent → deny again (one-shot)" 'is_deny'
PP_SESSION="dl-1" gate dl-1 'rm -rf ./dl' ',"permission_mode":"auto","agent_id":"a1"'; check "delegated subagent under the protocol → deny" 'is_deny'

echo "# 10d Codex under the protocol: deny without a receipt, silent pass with one"
PP_SESSION="cx-1" "$predict" on CX-1 --task >/dev/null
PP_SESSION="cx-1" gate cx-1 'git push --force origin main' "$CX"; check "codex interactive, under the protocol, no receipt → deny + recipe" 'is_deny && printf "%s" "$OUT" | grep -q "open --action"'
X="$(PP_SESSION="cx-1" "$predict" open --action 'rm -rf ./cx' --hypothesis h --observe 'ls -d cx 2>/dev/null | wc -l' --expect 'count=0' | sed -n 's/^predict \([0-9a-f-]*\) .*/\1/p')"
PP_SESSION="cx-1" gate cx-1 'rm -rf ./cx' "$CX" tx; check "codex interactive with a matching receipt → silent pass, receipt consumed (the receipt is the witness)" 'is_silent && [ -e "$PP_STATE_DIR/sessions/cx-1/receipts/$X/consumed" ]'
stdin cx-1 'rm -rf ./cx' "$CX" tx | PP_SESSION="cx-1" bash "$fired"; mkdir -p cx; rm -rf ./cx; PP_SESSION="cx-1" "$predict" close "$X" >/dev/null; check "codex receipt closes → HIT" '[ $? -eq 0 ]'
PP_SESSION="cx-1" gate cx-1 'rm -rf ./cx' "$CX"; check "codex: spent receipt → deny (one-shot)" 'is_deny'
PP_SESSION="cx-1" gate cx-1 'rm -rf ./cx' "$CX"',"agent_id":"a1"'; check "codex subagent under the protocol → deny" 'is_deny'
PP_SESSION="cx-1" gate cx-1 'git push --force origin main' "$CX"',"permission_mode":"bypassPermissions"'; check "codex exec under the protocol, no receipt → deny + recipe" 'is_deny && printf "%s" "$OUT" | grep -q "open --action"'
grep -nwi 'allow' "$gate" | grep -v ':[0-9]*:[[:space:]]*#' | grep -v 'never' >/dev/null && bad "the Codex deny text uses the word allow" || ok

echo "# 11 ids and journals"
PP_SESSION="nightly-2026-08-21" "$predict" on nightly --loop >/dev/null; PP_SESSION="nightly-2026-08-22" "$predict" on nightly --loop >/dev/null
A="$(PP_SESSION="nightly-2026-08-21" "$predict" open --scope advisory --action x --hypothesis h --observe 'echo 1' --expect count=1 | sed -n 's/^predict \([0-9a-f-]*\) .*/\1/p')"
B="$(PP_SESSION="nightly-2026-08-22" "$predict" open --scope advisory --action x --hypothesis h --observe 'echo 1' --expect count=1 | sed -n 's/^predict \([0-9a-f-]*\) .*/\1/p')"
check "sessions sharing a prefix get different ids" '[ "${A%-*}" != "${B%-*}" ]'
PP_SESSION="nightly-2026-08-21" "$predict" close "$A" >/dev/null; PP_SESSION="nightly-2026-08-22" "$predict" close "$B" >/dev/null
check "loop journal lint finds the repo ledger path" 'PP_SESSION="nightly-2026-08-22" "$predict" lint loops/evidence/nightly.md >/dev/null'
"$predict" ack '../../etc' --refuted x --where y 2>/dev/null; check "id validated as a path component" '[ $? -eq 2 ]'

echo "# 12 off / bypass"
"$predict" off 2>/dev/null; check "off without reason refused" '[ $? -eq 2 ]'
"$predict" off --reason 'incident' >/dev/null; check "off rc0" '[ $? -eq 0 ]'
gate "$S" 'git push --force origin main'; check "after off → ask (outside scope)" 'is_ask'
check "bypass entry in journal" 'grep -q "verdict=bypass" docs/evidence/DEV-1.md'
"$predict" open --action 'rm -rf ./z' --hypothesis h --observe 'ls' --expect 'count=0' 2>/dev/null; check "open refused when off" '[ $? -eq 2 ]'

echo "# 13 fail-closed error paths"
"$predict" on DEV-2 >/dev/null
OUT="$(echo '{not json' | bash "$gate" 2>/dev/null)"; GRC=$?; check "malformed stdin with no token → silent" 'is_silent'
OUT="$(printf '{"x": "git push --force"' | bash "$gate" 2>/dev/null)"; GRC=$?; check "malformed stdin with a token → deny" 'is_deny'
mkdir -p "$T/bin"; for b in bash cat sed timeout base64 date sha256sum shasum tr awk grep head tail mktemp basename dirname rm wc cut sleep mv cp ls git printf env iconv; do p="$(command -v $b 2>/dev/null)" && ln -sf "$p" "$T/bin/$b"; done
OUT="$(stdin "$S" 'git push --force origin main' | PATH="$T/bin" bash "$gate" 2>/dev/null)"; GRC=$?; check "no python3/jq on PATH + one-way → deny" 'is_deny'
OUT="$(stdin "$S" 'ls -la' | PATH="$T/bin" bash "$gate" 2>/dev/null)"; GRC=$?; check "no python3/jq + irrelevant → silent" 'is_silent'
rm "$T/bin/timeout"; ln -sf "$(command -v python3)" "$T/bin/python3"
OUT="$(stdin "$S" 'git push --force origin main' | PATH="$T/bin" bash "$gate" 2>/dev/null)"; GRC=$?; check "no timeout binary → watchdog fallback still denies" 'is_deny'
rm "$T/bin/grep"
OUT="$(stdin "$S" 'ls -la' | PATH="$T/bin" bash "$gate" 2>/dev/null)"; GRC=$?; check "no grep + irrelevant → silent (pure-bash prefilter)" 'is_silent'
OUT="$(stdin "$S" 'git push --force origin main' | PATH="$T/bin" bash "$gate" 2>/dev/null)"; GRC=$?; check "no grep + one-way → deny" 'is_deny'
OUT="$(stdin "$S" 'git push --force origin main' | PP_DEADLINE=1 PP_TEST_SLEEP=3 bash "$gate" 2>/dev/null)"; GRC=$?; check "deadline overrun → deny, exit 2" 'is_deny'
OUT="$(stdin "$S" 'ls' | PP_DEADLINE=1 PP_TEST_SLEEP=3 bash "$gate" 2>/dev/null)"; GRC=$?; check "deadline is never reached for a token-free command" 'is_silent'
chmod 000 "$PP_STATE_DIR/sessions/$S"; gate "$S" 'git push --force origin main'; chmod 755 "$PP_STATE_DIR/sessions/$S"; check "unreadable state + one-way → deny" 'is_deny'
chmod 000 "$PP_STATE_DIR/sessions/$S"; gate "$S" 'ls'; chmod 755 "$PP_STATE_DIR/sessions/$S"; check "unreadable state + irrelevant → silent" 'is_silent'
OUT="$(stdin "$S" 'git push --force origin main' | PP_NOW=notanumber bash "$gate" 2>/dev/null)"; GRC=$?; check "internal error on a one-way → deny" 'is_deny'
cp -a "$P" "$T/nolib"; rm "$T/nolib/lib/common.sh"; OUT="$(stdin "$S" 'git push --force origin main' | bash "$T/nolib/hooks/predict-gate.sh" 2>/dev/null)"; GRC=$?; check "missing lib/common.sh → deny (literal)" 'is_deny'
rm "$T/nolib/lib/classify.sh"; OUT="$(stdin "$S" 'ls' | bash "$T/nolib/hooks/predict-gate.sh" 2>/dev/null)"; GRC=$?; check "missing lib/classify.sh → deny even on ls (cannot pre-filter)" 'is_deny'
gate "" 'git push --force origin main'; check "empty session id + one-way → deny" 'is_deny'
grep -nwi 'allow' "$gate" "$P/lib/common.sh" | grep -v ':[0-9]*:#' | grep -v 'never' >/dev/null && bad "the word allow appears in the hook" || ok
"$predict" selftest >/dev/null; check "selftest rc0" '[ $? -eq 0 ]'

echo "# 14 corpora through the gate"
"$predict" on DEV-3 >/dev/null; miss=0
while IFS= read -r line; do [ -n "$line" ] && [ "${line:0:1}" != '#' ] || continue; gate "$S" "$line"; is_deny || { miss=$((miss+1)); echo "  gate let through: $line"; }; done < "$here/corpus/must-deny.txt"
check "every must-deny line is denied by the gate" '[ $miss -eq 0 ]'
miss=0
while IFS= read -r line; do [ -n "$line" ] && [ "${line:0:1}" != '#' ] || continue; gate "$S" "$line"; is_silent || { miss=$((miss+1)); echo "  gate spoke on: $line"; }; done < "$here/corpus/must-pass.txt"
check "every must-pass line is silent at the gate" '[ $miss -eq 0 ]'

echo "# 15 hooks: session-env, fired, state guard"
E="$T/env"; : > "$E"; CLAUDE_ENV_FILE="$E" CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/session-env.sh"; check "SessionStart exports PREDICT" 'grep -q "^export PREDICT=.*bin/predict$" "$E"'
CLAUDE_ENV_FILE="$E" CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/session-env.sh"; check "SessionStart is idempotent" '[ "$(grep -c "^export PREDICT=" "$E")" -eq 1 ]'
CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/session-env.sh" >/dev/null; check "session-env without CLAUDE_ENV_FILE exits 0" '[ $? -eq 0 ]'
OUT="$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/sessions/%s/state","content":"x"}}' "$PP_STATE_DIR" "$S" | bash "$guard" 2>/dev/null)"; GRC=$?; check "Write into the state dir → deny" 'is_deny'
OUT="$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}' | bash "$guard")"; GRC=$?; check "Write elsewhere → silent" 'is_silent'
OUT="$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/doc.md","content":"state lives under ~/.local/state/prediction-protocol/sessions/<uuid>/ and %s/sessions/x"}}' "$PP_STATE_DIR" | bash "$guard")"; GRC=$?; check "Write elsewhere whose CONTENT names the state dir → silent (path, not content)" 'is_silent'
OUT="$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s/sessions/%s/state.ipynb"}}' "$PP_STATE_DIR" "$S" | bash "$guard" 2>/dev/null)"; GRC=$?; check "NotebookEdit into the state dir → deny" 'is_deny'
OUT="$(printf '{"tool_name":"MultiEdit","tool_input":{"edits":[{"old_string":"a","new_string":"b"}],"file_path":"%s/sessions/%s/state"}}' "$PP_STATE_DIR" "$S" | bash "$guard" 2>/dev/null)"; GRC=$?; check "MultiEdit with file_path after other keys → deny" 'is_deny'
echo '{not json' | bash "$fired"; check "fired hook never fails" '[ $? -eq 0 ]'

echo "# 15b Codex: apply_patch through the state guard, the context path, the CLI's session"
ap(){ printf '{"session_id":"s","tool_name":"apply_patch","tool_input":{"command":%s},"tool_use_id":"ap1"}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")"; }
OUT="$(ap "$(printf '*** Begin Patch\n*** Update File: %s/sessions/%s/state\n@@\n-active=1\n+active=0\n*** End Patch' "$PP_STATE_DIR" "$S")" | bash "$guard" 2>/dev/null)"; GRC=$?; check "apply_patch Update File into the state dir → deny" 'is_deny'
OUT="$(ap "$(printf '*** Begin Patch\n*** Add File: %s/sessions/%s/receipts/x/closed\n+1\n*** End Patch' "$PP_STATE_DIR" "$S")" | bash "$guard" 2>/dev/null)"; GRC=$?; check "apply_patch Add File into the state dir → deny" 'is_deny'
OUT="$(ap "$(printf '*** Begin Patch\n*** Update File: notes.md\n*** Move to: %s/sessions/%s/state\n@@\n-a\n+b\n*** End Patch' "$PP_STATE_DIR" "$S")" | bash "$guard" 2>/dev/null)"; GRC=$?; check "apply_patch Move to the state dir → deny" 'is_deny'
OUT="$(ap "$(printf '*** Begin Patch\n*** Delete File: ~/.local/state/prediction-protocol/sessions/x/state\n*** End Patch')" | bash "$guard" 2>/dev/null)"; GRC=$?; check "apply_patch Delete File under the default state root → deny" 'is_deny'
OUT="$(ap "$(printf '*** Begin Patch\n*** Add File: docs/notes.md\n+state lives under %s/sessions/x/state\n+*** Update File: %s/sessions/x/state\n*** End Patch' "$PP_STATE_DIR" "$PP_STATE_DIR")" | bash "$guard")"; GRC=$?; check "apply_patch elsewhere whose CONTENT names the state dir, even as a header-shaped line → silent (headers, not content)" 'is_silent'
OUT="$(ap "$(printf '*** Begin Patch\n*** Add File: probe.txt\n+hi\n*** End Patch')" | bash "$guard")"; GRC=$?; check "apply_patch elsewhere → silent" 'is_silent'
OUT="$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"*** Update File: %s/sessions/%s/state"}}' "$PP_STATE_DIR" "$S" | bash "$guard")"; GRC=$?; check "Write elsewhere whose content carries a patch header → silent (headers count for apply_patch only)" 'is_silent'
OUT="$(env -u CLAUDE_ENV_FILE CLAUDE_PLUGIN_ROOT="$P" bash "$P/hooks/session-env.sh")"; GRC=$?; check "session-env without an env file → SessionStart additionalContext naming bin/predict, valid JSON" '[ $GRC -eq 0 ] && valid_json && printf "%s" "$OUT" | grep -q "additionalContext" && printf "%s" "$OUT" | grep -q "$P/bin/predict"'
OUT="$(env -u CLAUDE_ENV_FILE -u CLAUDE_PLUGIN_ROOT PLUGIN_ROOT="$P" bash "$P/hooks/session-env.sh")"; GRC=$?; check "session-env resolves the plugin root from PLUGIN_ROOT (Codex)" 'valid_json && printf "%s" "$OUT" | grep -q "$P/bin/predict"'
( unset PP_SESSION; CODEX_SESSION_ID=cx-1 "$predict" status >/dev/null 2>&1 ); check "CLI: CODEX_SESSION_ID alone resolves the session" '[ $? -eq 0 ]'
( unset PP_SESSION; CLAUDE_CODE_SESSION_ID=dl-1 CODEX_SESSION_ID=cx-1 "$predict" status > "$T/nest.out" 2>&1 ); check "CLI: both ids set → refused as nested harnesses (rc 2)" '[ $? -eq 2 ] && grep -q "nested" "$T/nest.out"'
( unset PP_SESSION; CLAUDE_CODE_SESSION_ID=dl-1 CODEX_SESSION_ID=cx-1 PP_SESSION=cx-1 "$predict" status >/dev/null 2>&1 ); check "CLI: PP_SESSION wins over both" '[ $? -eq 0 ]'
( unset PP_SESSION; "$predict" status >/dev/null 2>&1 ); check "CLI: no id at all → rc 2" '[ $? -eq 2 ]'
PP_SESSION="lp-1" CODEX_SESSION_ID=cx-9 "$predict" off --reason r > "$T/lpo.out" 2>&1; check "loop: off inside a Codex session is refused (the operator's act)" '[ $? -eq 2 ] && grep -q "operator" "$T/lpo.out"'

echo "# 18 the deny record: every deny the hooks issue for a session with a state dir, read back through predict status --json"
dis() {   # session index class command-as-python-literal → 0 when that deny matches ('*' = any class)
  PP_SESSION="$1" "$predict" status --json | python3 -c '
import json,sys,base64,ast
d=json.load(sys.stdin)["denies"][int(sys.argv[1])]
c=base64.b64decode(d["command_b64"]).decode("utf-8","surrogateescape")
sys.exit(0 if (sys.argv[2] in ("*", d["class"]) and c==ast.literal_eval(sys.argv[3])) else 1)' "$2" "$3" "$4" 2>/dev/null
}
dn() { PP_SESSION="$1" "$predict" status --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["denies"]))'; }
PP_SESSION="dr-1" "$predict" on DR-1 --task >/dev/null
PP_SESSION="dr-1" gate dr-1 'git push --force origin main'; dis dr-1 0 vcs-force "'git push --force origin main'"; r=$?
check "a deny under the protocol is recorded: class and the exact command" 'is_deny && [ $r -eq 0 ]'
PP_SESSION="dr-1" gate dr-1 "$(printf 'rm -rf ./a\n\techo "x"')"; dis dr-1 1 '*' "'rm -rf ./a\\n\\techo \"x\"'"; r=$?
check "a command with a newline, a tab and quotes comes back byte for byte" 'is_deny && [ $r -eq 0 ]'
C2=$'git push --force origin main\n\n'; PP_SESSION="dr-1" gate dr-1 "$C2"; dis dr-1 2 vcs-force "'git push --force origin main\\n\\n'"; r=$?
check "trailing newlines survive: the record keeps the parser's own base64, never a shell decode" 'is_deny && [ $r -eq 0 ]'
OUT="$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/sessions/dr-1/state","content":"x"}}' "$PP_STATE_DIR" | PP_SESSION="dr-1" bash "$guard" 2>/dev/null)"; GRC=$?; dis dr-1 3 state-guard "'$PP_STATE_DIR/sessions/dr-1/state'"; r=$?
check "a state-guard deny is recorded as state-guard with the refused path" 'is_deny && [ $r -eq 0 ]'
OUT="$(ap "$(printf '*** Begin Patch\n*** Update File: %s/sessions/dr-1/state\n@@\n-active=1\n+active=0\n*** End Patch' "$PP_STATE_DIR")" | sed 's/"session_id":"s"/"session_id":"dr-1"/' | env -u PP_SESSION bash "$guard" 2>/dev/null)"; GRC=$?
check "an apply_patch state-guard deny is keyed by the stdin session id when no PP_SESSION is set" 'is_deny && [ "$(dn dr-1)" = 5 ]'
OUT="$(printf '{"session_id" :\t\n "dr-1", "tool_name": "Write", "tool_input": {"file_path": "%s/sessions/dr-1/state"}}' "$PP_STATE_DIR" | env -u PP_SESSION bash "$guard" 2>/dev/null)"; GRC=$?
check "the state guard finds the stdin session id across any JSON whitespace" 'is_deny && [ "$(dn dr-1)" = 6 ]'
OUT="$(printf '{"tool_name" : "apply_patch", "tool_input" : {"command" : "*** Begin Patch\\n*** Update File: %s/sessions/x/state\\n*** End Patch"}}' "$PP_STATE_DIR" | env -u PP_SESSION bash "$guard" 2>/dev/null)"; GRC=$?
check "spaced JSON (a harness that pretty-prints) cannot walk an apply_patch past the state guard" 'is_deny'
OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"' | PP_SESSION="dr-1" bash "$gate" 2>/dev/null)"; GRC=$?; dis dr-1 6 unclassified "''"; r=$?
check "an early deny (unparsable input) is recorded under a runner's PP_SESSION, command unknown" 'is_deny && [ $r -eq 0 ]'
OUT="$(stdin dr-1 'git push --force origin main' | PP_SESSION="dr-1" PP_DEADLINE=1 PP_TEST_SLEEP=3 bash "$gate" 2>/dev/null)"; GRC=$?; dis dr-1 7 gate-error "''"; r=$?
check "a deadline overrun is recorded by the wrapper as gate-error, command unknown" 'is_deny && [ $r -eq 0 ]'
PP_SESSION="dr-0" gate dr-0 'git push --force origin main' "$CX"; check "outside the protocol (no state dir) a deny writes nothing" 'is_deny && [ ! -e "$PP_STATE_DIR/sessions/dr-0" ]'
printf '\t\t\n\377\376\tvcs-force\tAAAA\n2026-10-16T00:00:00Z\tvcs-force\t%%%%not-base64\nno tabs at all\n' >> "$PP_STATE_DIR/sessions/dr-1/denies"
check "damaged lines (tabs only, invalid UTF-8, bad base64, no tabs) each count as corrupt, and the JSON stays JSON" '[ "$(PP_SESSION=dr-1 "$predict" status --json | python3 -c "import json,sys; d=json.load(sys.stdin)[\"denies\"]; print(len(d), [x[\"class\"] for x in d[-4:]])")" = "12 ['"'"'corrupt'"'"', '"'"'corrupt'"'"', '"'"'corrupt'"'"', '"'"'corrupt'"'"']" ]'
check "the text status names the count" 'PP_SESSION=dr-1 "$predict" status | grep -q "denies=12"'
PP_SESSION="dr-2" "$predict" on DR-2 --task >/dev/null
one() { PP_SESSION=dr-2 "$predict" status --json | python3 -c 'import json,sys; d=json.load(sys.stdin)["denies"]; print(len(d), d[0]["class"] if d else "-", d[0]["command_b64"] if d else "-")'; }
printf '\000' > "$PP_STATE_DIR/sessions/dr-2/denies"; check "a file of one NUL (no newline) is one corrupt record, not none" '[ "$(one)" = "1 corrupt " ]'
printf '2026-10-16T00:00:00Z\tvcs-force\tY\000Q==\n' > "$PP_STATE_DIR/sessions/dr-2/denies"; check "a NUL inside the base64 makes the line corrupt, never a repaired command" '[ "$(one)" = "1 corrupt " ]'
for b in A '=' 'A==' 'YQ'; do printf '2026-10-16T00:00:00Z\tvcs-force\t%s\n' "$b" > "$PP_STATE_DIR/sessions/dr-2/denies"; check "base64 '$b' (not the full grammar) is corrupt" '[ "$(one)" = "1 corrupt " ]'; done
printf '2026-10-16T00:00:00Z\tvcs-force\tYQ==\n' > "$PP_STATE_DIR/sessions/dr-2/denies"; check "a well-formed line passes as itself" '[ "$(one)" = "1 vcs-force YQ==" ]'
chmod 000 "$PP_STATE_DIR/sessions/dr-1/denies"; PP_SESSION="dr-1" gate dr-1 'git push --force origin main'; chmod 644 "$PP_STATE_DIR/sessions/dr-1/denies"
check "an unwritable record never changes the decision" 'is_deny'
PP_SESSION="dr-1" "$predict" status --json >/dev/null; sed -i 's/^active=1$/active=x/' "$PP_STATE_DIR/sessions/dr-1/state"
check "a malformed active value reads as 0 and the JSON stays JSON" '[ "$(PP_SESSION=dr-1 "$predict" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"active\"])")" = 0 ]'

echo "tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
