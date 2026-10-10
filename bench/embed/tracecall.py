#!/usr/bin/env python3
"""Guest->host call cost per loop shape (doc 63 Phase 0).

Builds tracecall_probe.c against a ReleaseFast libmahina (the same cache
prefix run.py uses), then for every shape counts user-space instructions
with `perf stat` at 0 and N iterations, with the JIT on and off (MH_NOJIT).
Reports instructions per iteration, (count(N) - count(0)) / N. `nest`
makes one disturbing call (a long guest loop) at iteration 1000 and is
otherwise `nestq`; it is reported as the total cost of that one call,
count(nest, 1000) - count(nestq, 1000): both runs end right after it, so
nothing the call changes about the rest of the loop is counted. N must be
a multiple of 100 (`two` runs N // 100 rounds of 100 calls) and at least
2000.

Exits non-zero if the JIT-on and JIT-off checksums differ.

Usage:
    python3 bench/embed/tracecall.py               # every shape, N = 1000000
    python3 bench/embed/tracecall.py --iters 200000 min wide

Informational, never a gate (global Rule #22). Instruction counts, not
wall time, so one run per point is enough on a quiet machine.
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CACHE = os.path.join(HERE, ".cache")

SHAPES = [
    "min", "minl", "gid",
    "a0", "a4", "a8",
    "w4", "w8", "w16",
    "s1", "s4",
    "wide",
    "cb", "tw", "two", "fail",
    "nestq", "nest",
]

# The iteration on which `nest` makes its disturbing call (tracecall_probe.c).
NEST_AT = 1000


def run(cmd, **kw):
    print("  $", " ".join(cmd), file=sys.stderr)
    subprocess.run(cmd, check=True, **kw)


def build(cc):
    prefix = os.path.join(CACHE, "mahina-prefix")
    run(["zig", "build", "lib", "-Doptimize=ReleaseFast", "--prefix", prefix], cwd=REPO)
    exe = os.path.join(CACHE, "tracecall_probe")
    run([
        cc, "-O2", os.path.join(HERE, "tracecall_probe.c"),
        "-I", os.path.join(prefix, "include"),
        os.path.join(prefix, "lib", "libmahina.a"),
        "-lm", "-lpthread", "-o", exe,
    ])
    return exe


def count(exe, shape, iters, jit):
    """(user instructions, checksum line) for one run."""
    env = dict(os.environ)
    env.pop("MH_NOJIT", None)
    if not jit:
        env["MH_NOJIT"] = "1"
    p = subprocess.run(
        ["perf", "stat", "-x,", "-e", "instructions:u", exe, shape, str(iters)],
        env=env, capture_output=True, text=True, check=True,
    )
    instr = None
    for line in p.stderr.splitlines():
        fields = line.split(",")
        if len(fields) > 2 and fields[2].startswith("instructions"):
            instr = int(fields[0])
    if instr is None:
        sys.exit(f"no instruction count for {shape}: {p.stderr}")
    return instr, p.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cc", default=os.environ.get("CC", "cc"))
    ap.add_argument("--iters", type=int, default=1_000_000)
    ap.add_argument("shapes", nargs="*", default=SHAPES)
    args = ap.parse_args()
    n = args.iters
    if n < 2000 or n % 100 != 0:
        sys.exit("--iters must be a multiple of 100 and at least 2000")
    unknown = [s for s in args.shapes if s not in SHAPES]
    if unknown:
        sys.exit(f"unknown shapes: {' '.join(unknown)}")
    exe = build(args.cc)

    print(f"{'shape':8} {'jit off':>12} {'jit on':>12}   (instructions per iteration, N = {n})")
    bad = False
    for shape in args.shapes:
        row = {}
        sums = {}
        for jit in (False, True):
            if shape == "nest":
                # The one disturbing call, total. Both runs stop right after
                # it (the 1000th call), so nothing that follows it -- the
                # outer loop's later tiering -- lands in the difference.
                full, out = count(exe, "nest", NEST_AT, jit)
                calm, _ = count(exe, "nestq", NEST_AT, jit)
                row[jit] = full - calm
            else:
                base, _ = count(exe, shape, 0, jit)
                full, out = count(exe, shape, n, jit)
                row[jit] = (full - base) / n
            sums[jit] = out
        if sums[False] != sums[True]:
            print(f"CHECKSUM MISMATCH {shape}: jit off {sums[False]!r}, jit on {sums[True]!r}")
            bad = True
        if shape == "nest":
            print(f"{shape:8} {row[False]:12d} {row[True]:12d}   (the one disturbing call, total)")
        else:
            print(f"{shape:8} {row[False]:12.1f} {row[True]:12.1f}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
