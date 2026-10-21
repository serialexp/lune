#!/usr/bin/env bash
# Marginal instructions of one construct, mahina tier-0 against LuaJIT -joff.
#
# Each probe file defines `P.base` (`s = s + i` in a numeric for) and probes
# that add exactly one construct to it. The marginal cost of a probe is
#   per-iteration(probe) - per-iteration(base),
# where per-iteration is the instruction difference between runs at N and 2N
# (perf two-point: exact, unlike per-symbol sampling, whose skid misattributes
# across tail jumps).
#
# Usage (from the repo root):
#   bench/opprobe/measure.sh [probe-file] probe...
#   M=/path/to/mahina LJ=/path/to/luajit N=1000000 bench/opprobe/measure.sh bench/opprobe/ops3.lua pairs kint
# Build the binary ReleaseFast first (`just release`); a Debug binary is ~20x slow.
set -u
here=$(cd "$(dirname "$0")" && pwd)
M=${M:-$here/../../zig-out/bin/mahina}
LJ=${LJ:-$HOME/Projects/LuaJIT/src/luajit}
N=${N:-1000000}
P=$here/ops.lua
if [ $# -gt 0 ] && [ -f "$1" ]; then P=$1; shift; fi
probes=${*:-lt eq mod sub ifl fdiv fget fset aget aset call0 call1 native len newt cat}
ins() { perf stat -x, -e instructions:u -- "$@" 2>&1 >/dev/null | awk -F, '/instructions/ {print $1}'; }
per() { local a b; a=$(ins "$@" "$N"); b=$(ins "$@" $((2 * N))); awk -v a="$a" -v b="$b" -v n="$N" 'BEGIN{print (b-a)/n}'; }
# ops2.lua uses mahina-only syntax; LuaJIT cannot run it.
lj_ok=1
case $(basename "$P") in ops2.lua) lj_ok=0 ;; esac
mb=$(per "$M" "$P" base)
lb=0
[ $lj_ok = 1 ] && lb=$(per "$LJ" -joff "$P" base)
printf "%-8s %9s %9s %7s   (base: mahina %s, lj %s)\n" op mahina lj ratio "$mb" "$lb"
for p in $probes; do
  m=$(per "$M" "$P" "$p")
  l=$lb
  [ $lj_ok = 1 ] && l=$(per "$LJ" -joff "$P" "$p")
  awk -v p="$p" -v m="$m" -v l="$l" -v mb="$mb" -v lb="$lb" 'BEGIN{dm=m-mb; dl=l-lb; printf "%-8s %9.1f %9.1f %6.1fx\n", p, dm, dl, (dl>0?dm/dl:0)}'
done
