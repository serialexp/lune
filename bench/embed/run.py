#!/usr/bin/env python3
"""mahina embedding-boundary benchmark runner (doc 59 E5).

The embedding analogue of bench/run.py: instead of guest programs across
mahina's tiers, it runs one HOST program per engine — the same C benchmark
driving the same guest code through each engine's embedding API — and reports
two things at once:

  * correctness — every op prints a checksum; all engines (and all reps) must
    agree, exactly like run.py's parity columns; and
  * boundary cost — best-of-N ns/op per crossing (host->guest call,
    guest->host callback, table get/set, iteration, ref churn, compile,
    eval), plus the mahina/LuaJIT and mahina/Lua 5.4 ratios.

Hosts (sources in this directory, built into .cache/):
  bench_mahina.c  -> include/mahina.h + libmahina.a (zig build lib, ReleaseFast)
  bench_lua.c     -> the Lua C API; compiled twice, against LuaJIT
                     (~/Projects/LuaJIT/src, override $LUAJIT_SRC/--luajit-src)
                     and Lua 5.4 (official tarball, downloaded + built into
                     .cache/ on first use)

Usage:
    python3 bench/embed/run.py             # all three engines, best-of-5
    python3 bench/embed/run.py --reps 9
    python3 bench/embed/run.py --no-lua54  # skip the Lua 5.4 column
    python3 bench/embed/run.py --no-luajit

Informational, never a gate (global Rule #22) — but it DOES exit non-zero on
a checksum mismatch or a failed host, so parity drift is loud.
"""

import argparse
import os
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CACHE = os.path.join(HERE, ".cache")

LUA_VERSION = "5.4.8"
LUA_URL = f"https://www.lua.org/ftp/lua-{LUA_VERSION}.tar.gz"

OPS = [
    ("call", "host->guest call"),
    ("callback", "guest->host callback"),
    ("table_get", "table get (string key)"),
    ("table_set", "table set (string key)"),
    ("iterate", "table iteration (10k hash)"),
    ("ref", "ref create+free"),
    ("compile", "compile small chunk"),
    ("eval", "eval 'return 1 + 2'"),
]


def run(cmd, **kw):
    print("  $", " ".join(cmd), file=sys.stderr)
    subprocess.run(cmd, check=True, **kw)


def build_mahina_host(cc):
    """zig build lib (ReleaseFast, own prefix so zig-out/ is untouched) + cc."""
    prefix = os.path.join(CACHE, "mahina-prefix")
    run(
        [
            "zig",
            "build",
            "lib",
            "-Doptimize=ReleaseFast",
            "--prefix",
            prefix,
        ],
        cwd=REPO,
    )
    exe = os.path.join(CACHE, "bench_mahina")
    run(
        [
            cc,
            "-O2",
            os.path.join(HERE, "bench_mahina.c"),
            "-I",
            os.path.join(prefix, "include"),
            os.path.join(prefix, "lib", "libmahina.a"),
            "-lm",
            "-lpthread",
            "-o",
            exe,
        ]
    )
    return exe


def build_luajit_host(cc, luajit_src):
    lib = os.path.join(luajit_src, "libluajit.a")
    if not os.path.exists(lib):
        sys.exit(
            f"error: {lib} not found — build LuaJIT first (make -C {os.path.dirname(luajit_src)}) "
            "or point --luajit-src/$LUAJIT_SRC elsewhere"
        )
    exe = os.path.join(CACHE, "bench_luajit")
    run([cc, "-O2", os.path.join(HERE, "bench_lua.c"), "-I", luajit_src, lib, "-lm", "-ldl", "-o", exe])
    return exe


def build_lua54_host(cc):
    """Fetch + build the official Lua tarball into .cache/ on first use (no
    system liblua5.4-dev needed; the runtime .so alone has no headers)."""
    src = os.path.join(CACHE, f"lua-{LUA_VERSION}", "src")
    lib = os.path.join(src, "liblua.a")
    if not os.path.exists(lib):
        tarball = os.path.join(CACHE, f"lua-{LUA_VERSION}.tar.gz")
        if not os.path.exists(tarball):
            print(f"  fetching {LUA_URL}", file=sys.stderr)
            urllib.request.urlretrieve(LUA_URL, tarball)
        run(["tar", "xf", tarball], cwd=CACHE)
        # Only the static lib ('a' target) — the lua binary would want readline.
        run(["make", "-C", src, "a", f"CC={cc}", "SYSCFLAGS=-DLUA_USE_LINUX"])
    exe = os.path.join(CACHE, "bench_lua54")
    run([cc, "-O2", os.path.join(HERE, "bench_lua.c"), "-I", src, lib, "-lm", "-ldl", "-o", exe])
    return exe


def run_host(exe, reps):
    """Best-of-N ns/op per op; checksums must agree across reps."""
    best = {}
    checksums = {}
    maxrss = None
    for _ in range(reps):
        out = subprocess.run([exe], capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit(f"error: {exe} failed:\n{out.stdout}{out.stderr}")
        for line in out.stdout.splitlines():
            parts = line.split()
            if parts[0] == "bench":
                op, ns, ck = parts[1], float(parts[2]), int(parts[3])
                if op in checksums and checksums[op] != ck:
                    sys.exit(f"error: {exe} op {op}: checksum varies across reps")
                checksums[op] = ck
                best[op] = min(best.get(op, float("inf")), ns)
            elif parts[0] == "maxrss_kb":
                maxrss = int(parts[1])
    return best, checksums, maxrss


def fmt_ns(ns):
    if ns is None:
        return "-"
    if ns >= 10000:
        return f"{ns / 1000:.1f}us"
    return f"{ns:.0f}ns"


def fmt_ratio(a, b):
    if a is None or b is None or b == 0:
        return "-"
    return f"{a / b:.1f}x"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--reps", type=int, default=5, help="best-of-N (default 5)")
    ap.add_argument("--cc", default=os.environ.get("CC", "cc"))
    ap.add_argument(
        "--luajit-src",
        default=os.environ.get("LUAJIT_SRC", os.path.expanduser("~/Projects/LuaJIT/src")),
    )
    ap.add_argument("--no-luajit", action="store_true")
    ap.add_argument("--no-lua54", action="store_true")
    args = ap.parse_args()

    os.makedirs(CACHE, exist_ok=True)

    engines = {}  # name -> (best, checksums, maxrss)
    print("building hosts...", file=sys.stderr)
    mh_exe = build_mahina_host(args.cc)
    lj_exe = None if args.no_luajit else build_luajit_host(args.cc, args.luajit_src)
    l54_exe = None
    if not args.no_lua54:
        try:
            l54_exe = build_lua54_host(args.cc)
        except Exception as e:  # network/toolchain missing — degrade, loudly
            print(f"warning: Lua 5.4 host unavailable ({e}); skipping column", file=sys.stderr)

    print(f"running (best of {args.reps})...", file=sys.stderr)
    engines["mahina"] = run_host(mh_exe, args.reps)
    if lj_exe:
        engines["luajit"] = run_host(lj_exe, args.reps)
    if l54_exe:
        engines["lua5.4"] = run_host(l54_exe, args.reps)

    # Parity: every engine must print the same checksum per op.
    mismatch = False
    for op, _ in OPS:
        seen = {name: e[1].get(op) for name, e in engines.items() if op in e[1]}
        if len(set(seen.values())) > 1:
            print(f"CHECKSUM MISMATCH on {op}: {seen}", file=sys.stderr)
            mismatch = True

    name_w = max(len(label) for _, label in OPS) + 2
    cols = ["mahina", "luajit", "lua5.4"]
    print()
    print(f"{'op':<{name_w}} {'mahina':>9} {'luajit':>9} {'lua5.4':>9} {'mh/lj':>7} {'mh/5.4':>8}")
    for op, label in OPS:
        vals = {c: engines[c][0].get(op) if c in engines else None for c in cols}
        print(
            f"{label:<{name_w}} {fmt_ns(vals['mahina']):>9} {fmt_ns(vals['luajit']):>9} "
            f"{fmt_ns(vals['lua5.4']):>9} {fmt_ratio(vals['mahina'], vals['luajit']):>7} "
            f"{fmt_ratio(vals['mahina'], vals['lua5.4']):>8}"
        )
    rss = {c: engines[c][2] if c in engines else None for c in cols}
    rss_fmt = lambda v: f"{v / 1024:.0f}MB" if v is not None else "-"
    print(
        f"{'peak RSS':<{name_w}} {rss_fmt(rss['mahina']):>9} {rss_fmt(rss['luajit']):>9} "
        f"{rss_fmt(rss['lua5.4']):>9}"
    )
    print()
    print("ns/op = best-of-N amortized cost of one boundary crossing; lower is better.")
    print("mahina's compile row retains chunks for the VM lifetime by design (load()")
    print("ownership, doc 59 §3.2) — that is most of its peak-RSS gap.")

    if mismatch:
        sys.exit(1)


if __name__ == "__main__":
    main()
