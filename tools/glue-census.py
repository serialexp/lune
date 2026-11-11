#!/usr/bin/env python3
"""Doc 87 Phase 0: the glue census over the bench board.

Runs every bench row once under `--trace --jit-native --glue-census` and
tabulates what tier 0 did between one loop's trace and the next (the
"glue" doc 87 wants to record). The census exists only in a jit-debug
build, so BIN must come from

    zig build -Doptimize=ReleaseFast -Djit-debug=true --prefix <dir>

`just glue-census` builds that binary and runs this.

usage: tools/glue-census.py BIN [--filter SUB] [--jobs N] [--tsv FILE]

Columns of the board table, per row:
  visits   loop traces entered from tier 0 (one per visit of a loop)
  midloop  visits that went on inside their loop: the trace left through
           a guard and tier 0 took the next trip
  lost     visits whose frame went away unseen (an error, a coroutine)
  inside   visits left by a `return` from inside the loop
  ended    visits whose loop ended with tier 0 watching (a window opened)
  ->hdr    windows whose first event is a loop header in the same
           function (the loop around this one goes round)
  ->call   windows whose first event is a call (the function goes on)
  ->ret    windows whose first event is a return: the loop-done exits
           that are followed by a return
  joined   ... of which reached another loop's trace within 8 events
  v1       ... of which are the two shapes doc 87 section 5 designs for:
           numeric `for` at both ends, one return and one call (RC, or
           RBC through the caller's own loop header), and none of the
           frame kinds section 7 leaves out
  for/for_in/while/repeat   `->ret` split by the kind of the loop that ended
The tables after it split `->ret` and `joined` further. A window's frame
kinds are those of every event in it, not of its first return alone.
"""
import argparse
import collections
import concurrent.futures
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
import run as R  # noqa: E402

LOOPS = ("for", "for_in", "while", "repeat")
KV = re.compile(r"(\w+)=(\S+)")
# The frame kinds section 7 keeps out of v1, as the census names them.
V1_FLAGS = (
    "ret_vararg", "ret_protected", "ret_all", "ret_dynamic", "ret_upvalues",
    "land_vararg", "land_protected", "call_vararg", "call_protected",
    "call_native", "meta", "host", "untracked",
)


class Row:
    def __init__(self, name):
        self.name = name
        self.rc = 0
        self.err = ""
        self.stats = collections.Counter()
        self.windows = []  # dicts: n, from, to, self, same_proto, shape, flags

    def count(self, pred):
        return sum(w["n"] for w in self.windows if pred(w))


def is_ret(w):
    return w["shape"].startswith("R")


def is_joined(w):
    return is_ret(w) and w["to"] in LOOPS


def is_v1(w):
    return (
        is_joined(w)
        and w["from"] == "for"
        and w["to"] == "for"
        and w["shape"] in ("RC", "RBC")
        and not w["flags"]
    )


def why_not_v1(w):
    """The first reason a joined window is outside section 7's v1."""
    if w["flags"]:
        return "frame:" + "+".join(sorted(w["flags"]))
    if w["from"] != "for" or w["to"] != "for":
        return f"kind:{w['from']}>{w['to']}"
    rets, calls = w["shape"].count("R"), w["shape"].count("C")
    if "O" in w["shape"]:
        return "one-shot trace between"
    if rets != 1 or calls != 1:
        return f"frames:{rets}R{calls}C"
    return "shape:" + w["shape"]


def parse(name, text):
    row = Row(name)
    for line in text.splitlines():
        if not line.startswith("[jit] glue: "):
            continue
        body = line[len("[jit] glue: "):]
        what, _, rest = body.partition(" ")
        kv = dict(KV.findall(rest))
        if what in ("visits", "armed"):
            for k, v in kv.items():
                row.stats[k] += int(v)
        elif what == "window":
            flags = kv["flags"]
            row.windows.append({
                "n": int(kv["n"]),
                "from": kv["from"],
                "to": kv["to"],
                "self": kv["self"] == "1",
                "same_proto": kv["same_proto"] == "1",
                "shape": "" if kv["shape"] == "-" else kv["shape"],
                "flags": frozenset() if flags == "-" else frozenset(flags.split("+")),
            })
    return row


def run_one(binary, b):
    p = subprocess.run(
        [binary, "--trace", "--jit-native", "--glue-census", b.path, *b.argv],
        cwd=os.path.dirname(b.path), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    text = p.stderr.decode(errors="replace")
    row = parse(b.name, text)
    row.rc = p.returncode
    if "has no effect in this binary" in text:
        row.err = "not a jit-debug build"
    elif p.returncode:
        row.err = " | ".join(text.strip().splitlines()[-2:])
    return row


def pct(part, whole):
    return "-" if whole == 0 else f"{100.0 * part / whole:.0f}%"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("binary")
    ap.add_argument("--filter", default=None, help="only rows whose name contains this")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--tsv", default=None, help="also write every window as a TSV line")
    args = ap.parse_args()
    # Each row runs in its program's directory.
    binary = os.path.abspath(args.binary)

    benches = list(R.discover(args.filter, 1.0))
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        rows = list(ex.map(lambda b: run_one(binary, b), benches))

    bad = [r for r in rows if r.err]
    for r in bad:
        print(f"FAILED {r.name}: rc={r.rc} {r.err}", file=sys.stderr)
    if any(r.err == "not a jit-debug build" for r in bad):
        sys.exit("the census needs a -Djit-debug=true build")

    head = ("row", "visits", "midloop", "lost", "inside", "ended",
            "->hdr", "->call", "->ret", "joined", "v1", *LOOPS)
    fmt_head = "{:24s}" + " {:>8s}" * 10 + " " + " {:>7s}" * 4
    fmt_row = "{:24s}" + " {:8d}" * 10 + " " + " {:7d}" * 4
    print(fmt_head.format(*head))
    total = collections.Counter()
    for r in rows:
        s = r.stats
        ret, joined, v1 = r.count(is_ret), r.count(is_joined), r.count(is_v1)
        kinds = [r.count(lambda w, k=k: is_ret(w) and w["from"] == k) for k in LOOPS]
        vals = (
            s["loop"],
            s["reentered"] + s["continued"] + s["superseded"],
            s["lost"] + s["unknown"],
            s["ret_inside"],
            s["opened"],
            r.count(lambda w: w["shape"].startswith("B")),
            r.count(lambda w: w["shape"].startswith("C")),
            ret, joined, v1, *kinds,
        )
        for k, v in zip(head[1:], vals):
            total[k] += v
        print(fmt_row.format(r.name, *vals))
    print(fmt_row.format("TOTAL", *(total[k] for k in head[1:])))

    print()
    print("windows that start with a return, by the frame kinds seen in them")
    print("(all rows; a window can show several):")
    kinds_seen = collections.Counter()
    plain = 0
    for r in rows:
        for w in r.windows:
            if not is_ret(w):
                continue
            if not w["flags"]:
                plain += w["n"]
            for f in w["flags"]:
                kinds_seen[f] += w["n"]
    print(f"  {plain:9d}  none")
    for f in V1_FLAGS:
        print(f"  {kinds_seen[f]:9d}  {f}")

    print()
    print("joined windows outside v1, by the first thing that keeps them out")
    print("(rows with at least 100 such windows; reasons under 1% of a row left out):")
    for r in rows:
        joined, v1 = r.count(is_joined), r.count(is_v1)
        if joined - v1 < 100:
            continue
        why = collections.Counter()
        for w in r.windows:
            if is_joined(w) and not is_v1(w):
                why[why_not_v1(w)] += w["n"]
        print(f"  {r.name}: joined={joined} v1={v1} ({pct(v1, joined)})")
        for reason, n in why.most_common():
            if n * 100 >= joined:
                print(f"      {n:9d} {pct(n, joined):>4s}  {reason}")

    print()
    print("frames a joined window crosses (returns, calls), all rows:")
    frames = collections.Counter()
    for r in rows:
        for w in r.windows:
            if is_joined(w):
                frames[(w["shape"].count("R"), w["shape"].count("C"))] += w["n"]
    all_joined = sum(frames.values())
    for (rets, calls), n in frames.most_common(12):
        print(f"  {n:9d} {pct(n, all_joined):>4s}  {rets} return(s), {calls} call(s)")

    print()
    print("returns after a loop that did not reach another loop (ret - joined), by how the window closed:")
    closed = collections.Counter()
    for r in rows:
        for w in r.windows:
            if is_ret(w) and not is_joined(w):
                closed[w["to"]] += w["n"]
    for to, n in closed.most_common():
        print(f"  {n:9d}  {to}")

    if args.tsv:
        with open(args.tsv, "w") as fh:
            fh.write("row\tn\tfrom\tto\tself\tsame_proto\tshape\tflags\n")
            for r in rows:
                for w in sorted(r.windows, key=lambda w: -w["n"]):
                    fh.write("\t".join((
                        r.name, str(w["n"]), w["from"], w["to"],
                        "1" if w["self"] else "0", "1" if w["same_proto"] else "0",
                        w["shape"] or "-", "+".join(sorted(w["flags"])) or "-",
                    )) + "\n")
    if bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
