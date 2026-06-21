#!/usr/bin/env python3
"""lune benchmark-suite runner.

Discovers every `bench/**/*.lua` program carrying a `-- @bench` metadata line,
runs it across lune's execution tiers (tier-0 bytecode, tier-1a IR-interp,
tier-1b native) and — where the program stays inside LuaJIT's stdlib surface —
against LuaJIT, and reports two things at once:

  * correctness — do all of lune's tiers agree byte-for-byte (the determinism
    property), and does lune match LuaJIT where parity is claimed; and
  * how far behind LuaJIT we are — best-of-N wall-clock per engine plus the
    lune/LuaJIT slowdown ratio.

Each run also appends a row-per-program TSV under bench/results/ (timestamped +
git-rev stamped) so the suite accumulates a history.

Metadata line (anywhere in the file):

    -- @bench args="4000000" luajit=compatible
    -- @bench args="poison"   luajit=skip      name=repack

  args=       literal argv passed to the program (space-split; may be empty)
  luajit=     compatible → diff lune vs LuaJIT and time both;
              skip       → lune-only (5.4 surface LuaJIT lacks); cross-tier only
  luajit_src= optional alternate source (path relative to this file) that LuaJIT
              runs instead of this file, for when the lune file uses 5.4 syntax
              LuaJIT can't parse (e.g. native bitwise operators) but a
              semantically-equivalent LuaJIT-idiomatic source (the bit.* original)
              gives byte-identical output. lune always runs this file.
  name=       optional display name (defaults to the path stem)

Usage:
    python3 bench/run.py                 # whole suite, default sizes
    python3 bench/run.py --filter str    # only programs whose name contains 'str'
    python3 bench/run.py --reps 7        # best-of-7 timing (default 5)
    python3 bench/run.py --scale 0.1     # scale first integer arg (quick run)
    python3 bench/run.py --no-luajit     # skip LuaJIT entirely
    python3 bench/run.py --no-save       # don't write a results TSV

Assumes lune is built ReleaseFast:  zig build -Doptimize=ReleaseFast
"""

import argparse
import glob
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LUNE = os.path.join(ROOT, "zig-out", "bin", "lune")
DEFAULT_LUAJIT = os.path.expanduser("~/Projects/LuaJIT/src/luajit")

META_RE = re.compile(r"@bench\b(.*)$", re.MULTILINE)
KV_RE = re.compile(r'(\w+)\s*=\s*(?:"([^"]*)"|(\S+))')
EXECNS_RE = re.compile(r"executed in (\d+) ns")

# Lune tiers, as (label, extra-flags-before-the-script).
TIERS = {
    "t0": [],                 # tier-0 bytecode interpreter (no JIT)
    "trace": ["--trace"],     # tier-1a IR-interpreter
    "jit": ["--jit-native"],  # tier-1b native x86-64
}


class Bench:
    def __init__(self, path, name, argv, luajit, luajit_src=None):
        self.path = path
        self.name = name
        self.argv = argv          # list[str]
        self.luajit = luajit      # "compatible" | "skip"
        # Optional alternate source run on LuaJIT instead of `path`. Used when the
        # lune file uses 5.4 syntax LuaJIT (5.1) can't parse — e.g. native bitwise
        # operators — but a semantically-equivalent LuaJIT-idiomatic source (the
        # `bit.*` original) produces byte-identical output. lune still runs `path`.
        self.luajit_src = luajit_src

    def lj_path(self):
        return self.luajit_src or self.path


def discover(filter_sub, scale):
    benches = []
    for path in sorted(glob.glob(os.path.join(ROOT, "bench", "**", "*.lua"), recursive=True)):
        with open(path, "r") as fh:
            text = fh.read()
        m = META_RE.search(text)
        if not m:
            continue
        kv = {}
        for key, q, bare in KV_RE.findall(m.group(1)):
            kv[key] = q if q != "" or bare == "" else bare
        name = kv.get("name") or os.path.splitext(os.path.basename(path))[0]
        if filter_sub and filter_sub not in name:
            continue
        argv = kv.get("args", "").split()
        if scale != 1.0:
            argv = scale_argv(argv, scale)
        lj_src = kv.get("luajit_src")
        if lj_src:
            lj_src = os.path.normpath(os.path.join(os.path.dirname(path), lj_src))
        benches.append(Bench(path, name, argv, kv.get("luajit", "skip"), lj_src))
    return benches


def scale_argv(argv, scale):
    """Scale the first all-digit token by `scale` (min 1). Non-numeric argv
    (e.g. repack's "poison" mode) is left untouched."""
    out = []
    scaled = False
    for tok in argv:
        if not scaled and tok.isdigit():
            out.append(str(max(1, round(int(tok) * scale))))
            scaled = True
        else:
            out.append(tok)
    return out


def run_once(cmd, want_time=False):
    """Run a command, returning (rc, stdout, exec_ns|None). exec_ns is lune's
    execute-only nanoseconds parsed from --time stderr, when want_time."""
    proc = subprocess.run(cmd, capture_output=True, text=True)
    exec_ns = None
    if want_time:
        m = EXECNS_RE.search(proc.stderr)
        if m:
            exec_ns = int(m.group(1))
    return proc.returncode, proc.stdout, proc.stderr, exec_ns


def time_best(cmd, reps):
    """Best-of-N full-process wall time in ms (min reduces scheduler noise)."""
    best = None
    for _ in range(reps):
        t = time.perf_counter()
        subprocess.run(cmd, capture_output=True, text=True)
        dt = (time.perf_counter() - t) * 1000.0
        best = dt if best is None else min(best, dt)
    return best


def short(s, n=120):
    s = s.strip().replace("\n", " / ")
    return s if len(s) <= n else s[: n - 1] + "…"


def git_rev():
    try:
        return subprocess.check_output(
            ["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], text=True
        ).strip()
    except Exception:
        return "nogit"


def main():
    ap = argparse.ArgumentParser(description="lune benchmark-suite runner")
    ap.add_argument("--filter", default="", help="only run programs whose name contains this")
    ap.add_argument("--reps", type=int, default=5, help="best-of-N timing reps (default 5)")
    ap.add_argument("--scale", type=float, default=1.0, help="scale first integer arg")
    ap.add_argument("--lune", default=os.environ.get("LUNE", DEFAULT_LUNE))
    ap.add_argument("--luajit", default=os.environ.get("LUAJIT", DEFAULT_LUAJIT))
    ap.add_argument("--no-luajit", action="store_true", help="skip LuaJIT comparison")
    ap.add_argument("--no-save", action="store_true", help="do not write a results TSV")
    args = ap.parse_args()

    if not os.path.exists(args.lune):
        sys.exit(f"lune binary not found at {args.lune}\n  build it: zig build -Doptimize=ReleaseFast")
    have_lj = (not args.no_luajit) and os.path.exists(args.luajit)
    if not args.no_luajit and not have_lj:
        print(f"note: LuaJIT not found at {args.luajit} — parity columns skipped\n", file=sys.stderr)

    benches = discover(args.filter, args.scale)
    if not benches:
        sys.exit("no @bench programs found")

    rows = []
    print(f"lune  = {args.lune}")
    print(f"luajit= {args.luajit if have_lj else '(disabled)'}")
    print(f"reps  = {args.reps}   scale = {args.scale}\n")
    hdr = (f"{'program':<16} {'cross':<7} {'luajit':<7} "
           f"{'t0 ms':>9} {'jit ms':>9} {'lj ms':>9} {'jit/lj':>7} {'t0/lj':>7}")
    print(hdr)
    print("-" * len(hdr))

    for b in benches:
        # --- correctness: one run per tier, compare stdout ---
        outs = {}
        rc_bad = None
        for tier, flags in TIERS.items():
            rc, out, err, _ = run_once([args.lune, *flags, b.path, *b.argv])
            outs[tier] = out
            if rc != 0 and rc_bad is None:
                rc_bad = (tier, short(err or out))
        if rc_bad:
            print(f"{b.name:<16} ERROR in {rc_bad[0]}: {rc_bad[1]}")
            rows.append(dict(name=b.name, cross="ERR", luajit="-", t0="", jit="", lj="",
                             argv=" ".join(b.argv), execns_t0="", execns_jit=""))
            continue
        cross_ok = outs["t0"] == outs["trace"] == outs["jit"]

        lj_status = "skip"
        lj_out = None
        if b.luajit == "compatible" and have_lj:
            rc, lj_out, lj_err, _ = run_once([args.luajit, b.lj_path(), *b.argv])
            if rc != 0:
                lj_status = "ERR"
            else:
                lj_status = "ok" if lj_out == outs["t0"] else "DIFF"
        elif b.luajit == "compatible" and not have_lj:
            lj_status = "n/a"

        # --- timing: best-of-N wall per engine + lune exec-only ns ---
        t0_ms = time_best([args.lune, b.path, *b.argv], args.reps)
        jit_ms = time_best([args.lune, "--jit-native", b.path, *b.argv], args.reps)
        lj_ms = None
        if b.luajit == "compatible" and have_lj:
            lj_ms = time_best([args.luajit, b.lj_path(), *b.argv], args.reps)
        # secondary: lune execute-only ns (parsed from --time)
        _, _, _, execns_t0 = run_once([args.lune, "--time", b.path, *b.argv], want_time=True)
        _, _, _, execns_jit = run_once([args.lune, "--time", "--jit-native", b.path, *b.argv], want_time=True)

        jit_lj = f"{jit_ms / lj_ms:.1f}x" if lj_ms else "-"
        t0_lj = f"{t0_ms / lj_ms:.1f}x" if lj_ms else "-"
        cross_s = "ok" if cross_ok else "MISMATCH"
        print(f"{b.name:<16} {cross_s:<7} {lj_status:<7} "
              f"{t0_ms:>9.1f} {jit_ms:>9.1f} "
              f"{(f'{lj_ms:.1f}' if lj_ms else '-'):>9} {jit_lj:>7} {t0_lj:>7}")

        rows.append(dict(
            name=b.name, cross=cross_s, luajit=lj_status,
            t0=f"{t0_ms:.3f}", jit=f"{jit_ms:.3f}",
            lj=(f"{lj_ms:.3f}" if lj_ms else ""),
            argv=" ".join(b.argv),
            execns_t0=(execns_t0 or ""), execns_jit=(execns_jit or ""),
        ))

    # --- history TSV ---
    if not args.no_save:
        os.makedirs(os.path.join(ROOT, "bench", "results"), exist_ok=True)
        rev = git_rev()
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = os.path.join(ROOT, "bench", "results", f"{stamp}-{rev}.tsv")
        cols = ["program", "args", "luajit_mode", "cross", "luajit_match",
                "lune_t0_ms", "lune_jit_ms", "luajit_ms", "lune_t0_execns", "lune_jit_execns"]
        with open(path, "w") as fh:
            fh.write(f"# lune bench suite  rev={rev}  stamp={stamp}  reps={args.reps}  scale={args.scale}\n")
            fh.write("\t".join(cols) + "\n")
            for r in rows:
                fh.write("\t".join(str(x) for x in [
                    r["name"], r["argv"], "-", r["cross"], r["luajit"],
                    r["t0"], r["jit"], r["lj"], r["execns_t0"], r["execns_jit"],
                ]) + "\n")
        # latest.tsv mirror for easy diffing
        latest = os.path.join(ROOT, "bench", "results", "latest.tsv")
        with open(path) as src, open(latest, "w") as dst:
            dst.write(src.read())
        print(f"\nwrote {os.path.relpath(path, ROOT)}  (+ bench/results/latest.tsv)")

    # exit non-zero if any correctness check failed (usable as a gate)
    bad = [r for r in rows if r["cross"] not in ("ok",) or r["luajit"] in ("DIFF", "ERR")]
    if bad:
        print(f"\n{len(bad)} program(s) with a correctness flag: "
              + ", ".join(f"{r['name']}({r['cross']}/{r['luajit']})" for r in bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
