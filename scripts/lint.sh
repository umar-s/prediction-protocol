#!/usr/bin/env bash
# Repository-side invariants — the written rules of the spec, as greps.
set -u
cd "$(dirname "$0")/.."
P=plugins/prediction-protocol; fail=0
err() { echo "lint: $*"; fail=1; }
v_json="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' $P/.claude-plugin/plugin.json)"
v_lib="$(sed -n 's/^PP_VERSION="\([^"]*\)".*/\1/p' $P/lib/common.sh)"
[ "$v_json" = "$v_lib" ] || err "version drift: plugin.json $v_json vs lib/common.sh $v_lib"
grep -q "^## \[$v_json\]" CHANGELOG.md || err "CHANGELOG.md has no section for $v_json"
# the hook never answers allow, and its matcher is the literal Bash
grep -q '"allow"' $P/hooks/predict-gate.sh && err "the hook must never emit allow"
grep -q '"matcher": "Bash"' $P/hooks/hooks.json || err "hooks.json matcher must be the literal Bash"
grep -q '"timeout": 15' $P/hooks/hooks.json || err "hooks.json must set an explicit timeout"
grep -q 'trap on_err ERR' $P/hooks/predict-gate.sh || err "hook lost its ERR trap"
grep -q 'timeout -k 1 "${PP_DEADLINE:-9}"' $P/hooks/predict-gate.sh || err "hook lost its inner deadline"
grep -q 'export LC_ALL=C' $P/lib/common.sh && grep -q 'export LC_ALL=C' $P/lib/classify.sh || err "LC_ALL=C missing"
grep -q 'CLAUDE_PLUGIN_ROOT' $P/hooks/hooks.json || err "hooks.json must reach the script through CLAUDE_PLUGIN_ROOT"
# no network from the hook or the classifier
grep -nE '\b(curl|wget|nc|ssh)\b' $P/hooks/predict-gate.sh $P/lib/common.sh | grep -v '^[^:]*:[0-9]*:#' | grep -vE 'classify|one-way|reason|deny|ask ' >/dev/null && err "network verb in the hook or common.sh"
# SKILL contract: thin, names the three commands, the halt rule, the scope rule, platform limits
S=$P/skills/prediction-protocol/SKILL.md
for ph in 'predict on' 'predict open' 'predict close' 'predict ack' 'predict report' 'predict off' 'MISS' 'INCONCLUSIVE' 'Bash tool only' 'Wrapping is a bypass' 'never writes' 'advisory'; do grep -q -- "$ph" "$S" || err "SKILL.md lost: $ph"; done
grep -q 'CLAUDE_PLUGIN_ROOT' "$S" || err "SKILL.md must resolve the plugin root"
w=$(wc -w < "$S"); [ "$w" -le 1400 ] || err "SKILL.md weight $w words > 1400"
J=$P/skills/prediction-protocol/references/journal.md
for ph in 'contract=1' 'exit=N' 'stdout==' 'stdout~=' 'stdout-in=' 'lines=N' 'http=NNN' 'count=N' 'REFUTED.md' 'predictions:' 'insufficient' 'redaction:'; do grep -q -- "$ph" "$J" || err "journal.md lost: $ph"; done
H=$P/skills/prediction-protocol/references/hook-engineering.md
for ph in 'exit 1' 'timeout' 'agent_id' 'CLAUDE_CODE_ENTRYPOINT' 'LC_ALL=C' 'PowerShell' 'allow' 'synthetic stdin'; do grep -q -- "$ph" "$H" || err "hook-engineering.md lost: $ph"; done
# corpora carry every class at least once
for c in migrate sql-opaque-input sql-write kv-write vcs-force vcs-merge release infra service remote-exec http-write cloud-write secrets publish mail files opaque-exec; do
  grep -q "printf '$c'" $P/lib/classify.sh || err "classifier lost class $c"
done
# README pair parity (headings)
diff <(grep -E '^#{1,3} ' README.md | sed -E 's/[^#]//g') <(grep -E '^#{1,3} ' README.ru.md | sed -E 's/[^#]//g') >/dev/null || err "README.md / README.ru.md heading structure differs"
[ "$fail" = 0 ] && echo "lint: OK" || exit 1
