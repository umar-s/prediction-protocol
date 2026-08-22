#!/usr/bin/env bash
# Runs lib/classify.sh over the corpora: one command per line in must-deny.txt /
# must-pass.txt, '---'-separated blocks in multiline-deny.txt / multiline-pass.txt.
# Exit 1 on any miss, printing each.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/classify.sh
. "$here/../lib/classify.sh"
fail=0 n=0
while IFS= read -r line; do
  [ -n "$line" ] && [ "${line:0:1}" != '#' ] || continue
  n=$((n+1)); pp_classify "$line" >/dev/null || { echo "MISSED  (must-deny): $line"; fail=$((fail+1)); }
done < "$here/corpus/must-deny.txt"
while IFS= read -r line; do
  [ -n "$line" ] && [ "${line:0:1}" != '#' ] || continue
  n=$((n+1)); if r="$(pp_classify "$line")"; then echo "FALSE+  (must-pass): $line  -> ${r%%	*}"; fail=$((fail+1)); fi
done < "$here/corpus/must-pass.txt"
blocks() { awk -v RS='\n---\n' 'NR>0 { sub(/^# [^\n]*\n/, ""); if (length($0)) print $0 "\x01" }' "$1" | tr '\n\001' '\002\n'; }
while IFS= read -r b; do b="$(printf '%s' "$b" | tr '\002' '\n')"; [ -n "$b" ] || continue
  n=$((n+1)); pp_classify "$b" >/dev/null || { echo "MISSED  (multiline-deny): $(printf '%s' "$b" | head -1) …"; fail=$((fail+1)); }
done < <(blocks "$here/corpus/multiline-deny.txt")
while IFS= read -r b; do b="$(printf '%s' "$b" | tr '\002' '\n')"; [ -n "$b" ] || continue
  n=$((n+1)); if r="$(pp_classify "$b")"; then echo "FALSE+  (multiline-pass): $(printf '%s' "$b" | head -1) … -> ${r%%	*}"; fail=$((fail+1)); fi
done < <(blocks "$here/corpus/multiline-pass.txt")
echo "classify-corpus: $n cases, $fail failures"
[ "$fail" -eq 0 ]
