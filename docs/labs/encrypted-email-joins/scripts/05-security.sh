#!/usr/bin/env bash
# Attacks, frequency analysis and the re-identification service checks.
set -uo pipefail
cd "$(dirname "$0")"
PY=../.venv/bin/python
R=../results
mkdir -p $R/attack $R/frequency $R/reid
for r in 1 2 3; do
  $PY attack_dictionary.py 10000000 > "$R/attack/dictionary-run$r.json" 2> "$R/attack/dictionary-run$r.err"
done
for r in 1 2 3; do
  $PY attack_phone.py "$r" > "$R/attack/phone-run$r.json" 2> "$R/attack/phone-run$r.err"
done
$PY frequency.py 3 > $R/frequency/frequency.json 2> $R/frequency/err.log
$PY test_reid.py 3 > $R/reid/reid.json 2> $R/reid/err.log
