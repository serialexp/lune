#!/usr/bin/env python3
"""lune frozen-output gate — pin every benchmark's stdout to a committed digest.

`bench/run.py` already proves the *cross-tier* half of lune's determinism
property: for each program, tier-0 / tier-1a / tier-1b stdout must be
byte-identical (reported as `cross=ok`). That catches a JIT that computes
something different from the interpreter.

It cannot catch a change that alters output *identically in every tier* — a
numeric-semantics slip, a formatting change, a table-iteration-order change.
For that you need output frozen against a reference from a known-good revision.
This script is that half.

    tools/hashgate.py                  # gate: re-run and diff vs the refs
    tools/hashgate.py --generate       # regenerate refs from the current binary
    tools/hashgate.py --filter nbody   # subset, same name matching as run.py

Refs live in `bench/refs/output-hashes.tsv`, one row per (program, mode):

    name <TAB> mode <TAB> argv <TAB> rc <TAB> sha256(stdout)

Modes are `bench/run.py`'s tiers — `t0` (bytecode), `trace` (tier-1a IR
interpreter), `jit` (tier-1b native). Programs are discovered by importing
run.py's `discover()`, so the corpus can never drift between the two tools.

Only stdout and the exit code are hashed. stderr carries diagnostics (`--time`
nanoseconds, JIT receipts) that are legitimately run-to-run variable.

`--generate` runs every configuration twice and refuses to write a ref for any
program whose own output is not reproducible, so an unstable program is caught
when the reference is made rather than as a mystery gate failure later.

COVERAGE HOLE, CLOSED 2026-08-26 — kept on file because of what was under it.
Five benchmarks (array3d and the four scimark kernels) used to print nothing, so
their digest was sha256("") and pinned only an exit code, and `bench/run.py`'s
cross-tier check was comparing "" == "" == "" while reporting `cross=ok` — on
the float/array kernels the JIT leans on hardest. All five now print an exact
integer checksum of their result state.

Closing it exposed a second defect the first had been hiding. `scimark_lib.lua`
selects its RNG with `if jit and jit.status and jit.status()`, and the two
branches are NOT equivalent generators — they agree on their first value and
then diverge. LuaJIT took one branch and lune the other, so the four scimark
kernels had been running on DIFFERENT INPUT DATA in the two engines, and their
`luajit=compatible` claim was not merely vacuous but unreachable. Nothing caught
it precisely because the programs printed nothing. The lib now forces the
portable branch (free: `rand` is setup-only for these kernels), and all four
verifiably match LuaJIT bit-for-bit.

`report_coverage` below stays. It is no longer describing a known defect — it is
a live tripwire, so that a benchmark added later with no output cannot silently
recreate this.

Assumes lune is built:  zig build -Doptimize=ReleaseFast  (or pass --lune).
"""

import argparse
import concurrent.futures
import hashlib
import importlib.util
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LUNE = os.path.join(ROOT, "zig-out", "bin", "lune")
DEFAULT_REFS = os.path.join(ROOT, "bench", "refs", "output-hashes.tsv")

# sha256 of the empty byte string — the digest of a program that prints nothing.
EMPTY_DIGEST = hashlib.sha256(b"").hexdigest()


def _load_bench_runner():
    """Import bench/run.py as a module so the corpus definition has one owner."""
    path = os.path.join(ROOT, "bench", "run.py")
    spec = importlib.util.spec_from_file_location("bench_run", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BR = _load_bench_runner()


def run_digest(lune, bench, flags):
    """Run one (program, mode) and return (rc, sha256-of-stdout).

    Runs from the program's own directory so `require("x")` resolves `./x.lua`,
    matching run.py and LuaJIT's run.sh.
    """
    cmd = [lune, *flags, bench.path, *bench.argv]
    proc = subprocess.run(cmd, capture_output=True, cwd=os.path.dirname(bench.path))
    return proc.returncode, hashlib.sha256(proc.stdout).hexdigest(), proc.stderr


def read_refs(path):
    refs = {}
    if not os.path.exists(path):
        return refs
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            name, mode, argv, rc, digest = line.split("\t")
            refs[(name, mode)] = (argv, int(rc), digest)
    return refs


def write_refs(path, rows, lune):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rev = BR.git_rev()
    with open(path, "w") as fh:
        fh.write("# lune frozen benchmark output digests — see tools/hashgate.py\n")
        fh.write(f"# generated from {os.path.relpath(lune, ROOT)} at rev {rev}\n")
        fh.write("# name\tmode\targv\trc\tsha256(stdout)\n")
        for name, mode, argv, rc, digest in rows:
            fh.write(f"{name}\t{mode}\t{argv}\t{rc}\t{digest}\n")


def main():
    ap = argparse.ArgumentParser(description="lune frozen-output gate")
    ap.add_argument("--generate", action="store_true",
                    help="regenerate the reference digests instead of gating")
    ap.add_argument("--filter", default="", help="only programs whose name contains this")
    ap.add_argument("--refs", default=DEFAULT_REFS)
    ap.add_argument("--lune", default=os.environ.get("LUNE", DEFAULT_LUNE))
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) // 2),
                    help="parallel program runs (timing is never measured here)")
    args = ap.parse_args()

    if not os.path.exists(args.lune):
        sys.exit(f"lune binary not found at {args.lune}\n"
                 f"  build it: zig build -Doptimize=ReleaseFast")

    benches = BR.discover(args.filter, 1.0)
    if not benches:
        sys.exit("no @bench programs found")

    jobs = [(b, mode, flags) for b in benches for mode, flags in BR.TIERS.items()]
    reps = 2 if args.generate else 1

    def work(job):
        b, mode, flags = job
        results = [run_digest(args.lune, b, flags) for _ in range(reps)]
        return job, results

    observed = {}
    unstable, errored = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for (b, mode, _), results in pool.map(work, jobs):
            rc, digest, err = results[0]
            if rc != 0:
                errored.append((b.name, mode, rc, BR.short(err.decode("utf-8", "replace"))))
            if any((r[0], r[1]) != (rc, digest) for r in results[1:]):
                unstable.append((b.name, mode))
            observed[(b.name, mode)] = (" ".join(b.argv), rc, digest)

    if errored:
        print("programs exiting non-zero (recorded, but check these are intentional):")
        for name, mode, rc, err in sorted(errored):
            print(f"  {name:<20} {mode:<6} rc={rc}  {err}")

    if unstable:
        print("\nnon-reproducible output — refusing to treat these as a reference:")
        for name, mode in sorted(unstable):
            print(f"  {name:<20} {mode}")
        return 2

    if args.generate:
        rows = [(name, mode, *observed[(name, mode)])
                for name, mode in sorted(observed, key=lambda k: (k[0], k[1]))]
        write_refs(args.refs, rows, args.lune)
        print(f"wrote {len(rows)} digests to {os.path.relpath(args.refs, ROOT)}")
        return 0

    refs = read_refs(args.refs)
    if not refs:
        sys.exit(f"no references at {args.refs} — generate them first:\n"
                 f"  tools/hashgate.py --generate")

    mismatched, missing, extra = [], [], []
    for key, (argv, rc, digest) in sorted(observed.items()):
        if key not in refs:
            extra.append(key)
            continue
        ref_argv, ref_rc, ref_digest = refs[key]
        if (argv, rc, digest) != (ref_argv, ref_rc, ref_digest):
            mismatched.append((key, (ref_argv, ref_rc, ref_digest), (argv, rc, digest)))
    if not args.filter:
        missing = [k for k in refs if k not in observed]

    for (name, mode), want, got in mismatched:
        print(f"MISMATCH {name} [{mode}]")
        print(f"    ref  argv={want[0]!r} rc={want[1]} {want[2]}")
        print(f"    got  argv={got[0]!r} rc={got[1]} {got[2]}")
    for name, mode in sorted(extra):
        print(f"NO REF   {name} [{mode}] — new program? re-run with --generate")
    for name, mode in sorted(missing):
        print(f"MISSING  {name} [{mode}] — program disappeared from the corpus")

    checked = len(observed) - len(extra)
    if mismatched or extra or missing:
        print(f"\nhashgate FAILED: {len(mismatched)} mismatched, "
              f"{len(extra)} unreferenced, {len(missing)} missing "
              f"({checked} checked)")
        return 1
    print(f"hashgate ok: {checked} digests match "
          f"({len(benches)} programs x {len(BR.TIERS)} modes)")
    report_coverage(observed)
    return 0


def report_coverage(observed):
    """Say plainly how much of the corpus the digests actually constrain.

    A program that prints nothing hashes to sha256("") in every mode, so its
    rows pin the exit code and nothing else. Reported every run so the headline
    count is never read as more coverage than it is (see the module docstring).
    """
    silent = sorted({name for (name, _), (_, _, d) in observed.items()
                     if d == EMPTY_DIGEST})
    if not silent:
        return
    rows = sum(1 for v in observed.values() if v[2] == EMPTY_DIGEST)
    print(f"  note: {rows}/{len(observed)} digests are of EMPTY stdout — "
          f"{len(silent)} pure-timing program(s) pin only their exit code:")
    print(f"        {', '.join(silent)}")


if __name__ == "__main__":
    sys.exit(main())
