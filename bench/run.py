#!/usr/bin/env python3
"""lune benchmark-suite runner.

Discovers every `bench/**/*.lua` program carrying a `-- @bench` metadata line,
runs it across lune's execution tiers (tier-0 bytecode, tier-1a IR-interp,
tier-1b native) and — where the program stays inside LuaJIT's stdlib surface —
against LuaJIT, and reports two things at once:

  * correctness — do all of lune's tiers agree byte-for-byte (the determinism
    property), and does lune match LuaJIT where parity is claimed; and
  * how far behind LuaJIT we are — best-of-N wall-clock per engine plus the
    lune/LuaJIT slowdown ratio, and peak memory (kernel max RSS) per engine
    from dedicated non-timed runs.

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
    python3 bench/run.py --json out.json # also emit the rows as JSON

Assumes lune is built ReleaseFast:  zig build -Doptimize=ReleaseFast
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
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


def run_once(cmd, want_time=False, cwd=None):
    """Run a command, returning (rc, stdout, exec_ns|None). exec_ns is lune's
    execute-only nanoseconds parsed from --time stderr, when want_time. `cwd` runs
    the child from that directory (so a bench's `require("x")` resolves `./x.lua`,
    like LuaJIT's run.sh which cd's into the bench dir); the bench path is
    absolute, so it is unaffected."""
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    exec_ns = None
    if want_time:
        m = EXECNS_RE.search(proc.stderr)
        if m:
            exec_ns = int(m.group(1))
    return proc.returncode, proc.stdout, proc.stderr, exec_ns


def time_best(cmd, reps, cwd=None):
    """Best-of-N full-process wall time in ms (min reduces scheduler noise).
    `cwd` runs each child from that directory (see run_once)."""
    best = None
    for _ in range(reps):
        t = time.perf_counter()
        subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
        dt = (time.perf_counter() - t) * 1000.0
        best = dt if best is None else min(best, dt)
    return best


TIME_BIN = "/usr/bin/time"  # GNU time; `%M` = child peak RSS in KB


def mem_best(cmd, reps, cwd=None):
    """Best-of-N (min) peak RSS in KB via a GNU `/usr/bin/time -f %M` trampoline
    — engine-agnostic, so lune and LuaJIT are measured identically. These are
    dedicated runs, deliberately separate from the timing reps: memory numbers
    never come from a timed process and vice versa.

    Why the trampoline instead of os.wait4/posix_spawn on a direct child: a
    child forked (or vforked) from this Python process briefly shares Python's
    ~12 MB address space before exec, which floors its ru_maxrss at the parent's
    RSS and makes every engine "cost" 12 MB. `time` execs first (tiny RSS) and
    only then forks the benchmark, so its wait4 sees the true child peak.
    `-o file` keeps the %M line out of the benchmark's own stderr. min-of-N
    because peak RSS is near-deterministic and the rare upward excursions are
    environment noise, same rationale as time_best. Returns None if GNU time is
    unavailable or the output is unparseable."""
    if not os.path.exists(TIME_BIN):
        return None
    best = None
    for _ in range(reps):
        tf = tempfile.NamedTemporaryFile(mode="r", suffix=".memrss", delete=False)
        try:
            subprocess.run([TIME_BIN, "-f", "%M", "-o", tf.name, "--", *cmd],
                           capture_output=True, text=True, cwd=cwd)
            line = tf.read().strip().splitlines()
            kb = int(line[-1]) if line and line[-1].isdigit() else None
        finally:
            tf.close()
            os.unlink(tf.name)
        if kb is not None:
            best = kb if best is None else min(best, kb)
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
    ap.add_argument("--mem-reps", type=int, default=3,
                    help="best-of-N dedicated memory (max-RSS) reps (default 3)")
    ap.add_argument("--scale", type=float, default=1.0, help="scale first integer arg")
    ap.add_argument("--lune", default=os.environ.get("LUNE", DEFAULT_LUNE))
    ap.add_argument("--luajit", default=os.environ.get("LUAJIT", DEFAULT_LUAJIT))
    ap.add_argument("--no-luajit", action="store_true", help="skip LuaJIT comparison")
    ap.add_argument("--no-save", action="store_true", help="do not write a results TSV")
    ap.add_argument("--no-jit-stats", action="store_true",
                    help="skip the per-bench --jit-stats run behind the res%% column")
    ap.add_argument("--json", default="", metavar="PATH",
                    help="also write the rows as JSON (machine-readable twin of the TSV)")
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
           f"{'t0 ms':>9} {'jit ms':>9} {'lj ms':>9} {'jit/lj':>7} {'t0/lj':>7} "
           f"{'res%':>6} "
           f"{'t0 MB':>7} {'jit MB':>7} {'lj MB':>7}")
    print(hdr)
    print("-" * len(hdr))

    for b in benches:
        # Run children from the bench's own directory so `require("x")` resolves
        # `./x.lua` (e.g. scimark's shared scimark_lib.lua), mirroring run.sh.
        bench_dir = os.path.dirname(b.path)
        # --- correctness: one run per tier, compare stdout ---
        outs = {}
        rc_bad = None
        for tier, flags in TIERS.items():
            rc, out, err, _ = run_once([args.lune, *flags, b.path, *b.argv], cwd=bench_dir)
            outs[tier] = out
            if rc != 0 and rc_bad is None:
                rc_bad = (tier, short(err or out))
        if rc_bad:
            print(f"{b.name:<16} ERROR in {rc_bad[0]}: {rc_bad[1]}")
            rows.append(dict(name=b.name, cross="ERR", luajit="-", t0="", jit="", lj="",
                             argv=" ".join(b.argv), execns_t0="", execns_jit="",
                             mem_t0="", mem_jit="", mem_lj="", res=""))
            continue
        cross_ok = outs["t0"] == outs["trace"] == outs["jit"]

        lj_status = "skip"
        lj_out = None
        if b.luajit == "compatible" and have_lj:
            rc, lj_out, lj_err, _ = run_once([args.luajit, b.lj_path(), *b.argv], cwd=bench_dir)
            if rc != 0:
                lj_status = "ERR"
            else:
                lj_status = "ok" if lj_out == outs["t0"] else "DIFF"
        elif b.luajit == "compatible" and not have_lj:
            lj_status = "n/a"

        # --- timing: best-of-N wall per engine + lune exec-only ns ---
        t0_ms = time_best([args.lune, b.path, *b.argv], args.reps, cwd=bench_dir)
        jit_ms = time_best([args.lune, "--jit-native", b.path, *b.argv], args.reps, cwd=bench_dir)
        lj_ms = None
        if b.luajit == "compatible" and have_lj:
            lj_ms = time_best([args.luajit, b.lj_path(), *b.argv], args.reps, cwd=bench_dir)
        # secondary: lune execute-only ns (parsed from --time)
        _, _, _, execns_t0 = run_once([args.lune, "--time", b.path, *b.argv], want_time=True, cwd=bench_dir)
        _, _, _, execns_jit = run_once([args.lune, "--time", "--jit-native", b.path, *b.argv], want_time=True, cwd=bench_dir)

        # --- memory: dedicated (non-timed) runs, kernel max RSS per engine ---
        mem_t0 = mem_best([args.lune, b.path, *b.argv], args.mem_reps, cwd=bench_dir)
        mem_jit = mem_best([args.lune, "--jit-native", b.path, *b.argv], args.mem_reps, cwd=bench_dir)
        mem_lj = None
        if b.luajit == "compatible" and have_lj:
            mem_lj = mem_best([args.luajit, b.lj_path(), *b.argv], args.mem_reps, cwd=bench_dir)

        # --- native residency (doc 31 D3): one dedicated --jit-stats run, never
        # timed. "res%" is the share of run TSC cycles spent executing native
        # trace code ("ran as a trace: X% of run"). A flat bench sitting at a
        # few % residency despite committed traces is the first suspect for a
        # gating/coverage pathology — this puts that signal on the board
        # artifact itself instead of behind a manual profiling session.
        res_pct = None
        if not args.no_jit_stats:
            _, _, stats_err, _ = run_once(
                [args.lune, "--trace", "--jit-native", "--jit-stats", b.path, *b.argv],
                cwd=bench_dir)
            m = re.search(r"ran as a trace:\s+([\d.]+)% of run", stats_err)
            if m:
                res_pct = float(m.group(1))

        jit_lj = f"{jit_ms / lj_ms:.1f}x" if lj_ms else "-"
        t0_lj = f"{t0_ms / lj_ms:.1f}x" if lj_ms else "-"
        cross_s = "ok" if cross_ok else "MISMATCH"
        mb = lambda kb: f"{kb / 1024:.1f}" if kb is not None else "-"
        res_s = f"{res_pct:.1f}" if res_pct is not None else "-"
        print(f"{b.name:<16} {cross_s:<7} {lj_status:<7} "
              f"{t0_ms:>9.1f} {jit_ms:>9.1f} "
              f"{(f'{lj_ms:.1f}' if lj_ms else '-'):>9} {jit_lj:>7} {t0_lj:>7} "
              f"{res_s:>6} "
              f"{mb(mem_t0):>7} {mb(mem_jit):>7} {mb(mem_lj):>7}")

        rows.append(dict(
            name=b.name, cross=cross_s, luajit=lj_status,
            t0=f"{t0_ms:.3f}", jit=f"{jit_ms:.3f}",
            lj=(f"{lj_ms:.3f}" if lj_ms else ""),
            argv=" ".join(b.argv),
            execns_t0=(execns_t0 or ""), execns_jit=(execns_jit or ""),
            mem_t0=mem_t0, mem_jit=mem_jit,
            mem_lj=(mem_lj if mem_lj is not None else ""),
            res=(f"{res_pct:.1f}" if res_pct is not None else ""),
        ))

    # --- history TSV ---
    if not args.no_save:
        os.makedirs(os.path.join(ROOT, "bench", "results"), exist_ok=True)
        rev = git_rev()
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = os.path.join(ROOT, "bench", "results", f"{stamp}-{rev}.tsv")
        cols = ["program", "args", "luajit_mode", "cross", "luajit_match",
                "lune_t0_ms", "lune_jit_ms", "luajit_ms", "lune_t0_execns", "lune_jit_execns",
                "lune_t0_maxrss_kb", "lune_jit_maxrss_kb", "luajit_maxrss_kb",
                "lune_jit_res_pct"]
        with open(path, "w") as fh:
            fh.write(f"# lune bench suite  rev={rev}  stamp={stamp}  reps={args.reps}  scale={args.scale}\n")
            fh.write("\t".join(cols) + "\n")
            for r in rows:
                fh.write("\t".join(str(x) for x in [
                    r["name"], r["argv"], "-", r["cross"], r["luajit"],
                    r["t0"], r["jit"], r["lj"], r["execns_t0"], r["execns_jit"],
                    r["mem_t0"], r["mem_jit"], r["mem_lj"], r["res"],
                ]) + "\n")
        # latest.tsv mirror for easy diffing
        latest = os.path.join(ROOT, "bench", "results", "latest.tsv")
        with open(path) as src, open(latest, "w") as dst:
            dst.write(src.read())
        print(f"\nwrote {os.path.relpath(path, ROOT)}  (+ bench/results/latest.tsv)")

    # --- machine-readable twin of the TSV ---
    #
    # Same rows, same units, no interpretation: consumers (e.g. the gothab
    # profile report emitted by tools/bench_profile.py) do their own mapping
    # rather than this runner growing knowledge of any one consumer's schema.
    if args.json:
        blob = {
            "rev": git_rev(),
            "reps": args.reps,
            "mem_reps": args.mem_reps,
            "scale": args.scale,
            "filter": args.filter,
            "have_luajit": have_lj,
            "rows": rows,
        }
        with open(args.json, "w") as fh:
            json.dump(blob, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"wrote {args.json}")

    # exit non-zero if any correctness check failed (usable as a gate)
    bad = [r for r in rows if r["cross"] not in ("ok",) or r["luajit"] in ("DIFF", "ERR")]
    if bad:
        print(f"\n{len(bad)} program(s) with a correctness flag: "
              + ", ".join(f"{r['name']}({r['cross']}/{r['luajit']})" for r in bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
