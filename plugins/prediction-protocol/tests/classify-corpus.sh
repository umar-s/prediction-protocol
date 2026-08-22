#!/usr/bin/env bash
# Runs lib/classify.sh over both corpora. Exit 1 on any miss, printing each.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/classify.sh
. "$here/../lib/classify.sh"
fail=0 n=0
while IFS= read -r line; do
  [ -n "$line" ] && [ "${line:0:1}" != '#' ] || continue
  n=$((n+1))
  if ! r="$(pp_classify "$line")"; then echo "MISSED  (must-deny): $line"; fail=$((fail+1)); fi
done < "$here/corpus/must-deny.txt"
while IFS= read -r line; do
  [ -n "$line" ] && [ "${line:0:1}" != '#' ] || continue
  n=$((n+1))
  if r="$(pp_classify "$line")"; then echo "FALSE+  (must-pass): $line  -> ${r%%	*}"; fail=$((fail+1)); fi
done < "$here/corpus/must-pass.txt"
echo "classify-corpus: $n lines, $fail failures"
[ "$fail" -eq 0 ]
