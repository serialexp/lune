#!/usr/bin/env bash
# Instruction-count A/B over every @bench program: BASE vs NEW binary, tier-0
# and JIT (`--trace --jit-native`). Instruction counts, not wall time, so it
# is usable on a loaded machine; still interleave and re-run a row that moves.
#
# Usage (from the repo root): bench/opprobe/abench.sh BASE_BIN NEW_BIN
# Build both ReleaseFast. For a baseline tree use `just shadow` (CLAUDE.md).
set -u
B=$1
N=$2
ins() { perf stat -x, -e instructions:u -- "$@" 2>&1 >/dev/null | awk -F, '/instructions/ {print $1}'; }
printf "%-28s %14s %14s %8s   %14s %14s %8s\n" bench t0-base t0-new d% jit-base jit-new d%
for f in $(grep -rl "@bench" bench --include='*.lua' | sort); do
  args=$(grep -m1 "@bench" "$f" | sed -n 's/.*args="\([^"]*\)".*/\1/p')
  name=$(basename "$f" .lua)
  d=$(dirname "$f"); bf=$(basename "$f")
  tb=$(cd "$d" && ins "$B" "$bf" $args); tn=$(cd "$d" && ins "$N" "$bf" $args)
  jb=$(cd "$d" && ins "$B" --trace --jit-native "$bf" $args); jn=$(cd "$d" && ins "$N" --trace --jit-native "$bf" $args)
  awk -v n="$name" -v tb="$tb" -v tn="$tn" -v jb="$jb" -v jn="$jn" 'BEGIN{printf "%-28s %14d %14d %+7.2f%%   %14d %14d %+7.2f%%\n", n, tb, tn, (tn-tb)*100/tb, jb, jn, (jn-jb)*100/jb}'
done
