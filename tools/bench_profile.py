#!/usr/bin/env python3
"""Convert `bench/run.py --json` output into a Gothab V1 profile report.

The benchmark runner stays schema-agnostic (it emits its own rows verbatim);
this script owns everything Gothab-specific — measurement naming, the unit
vocabulary, and the contract.

Usage:
    python3 bench/run.py --json bench.json ...
    python3 tools/bench_profile.py bench.json profile.json

Units are restricted by the V1 schema to ms, s, bytes, 1/s, percent, count and
cores, so ratios are expressed as percentages: `spectral-norm.jit_vs_lj = 500`
means lune's native tier took 5.0x LuaJIT's wall-clock on that program.

## What the contract does and does not assert

The contract carries *correctness* invariants only:

  * every program's three lune tiers (tier-0, tier-1a, tier-1b) must agree
    byte-for-byte — that is the determinism property, not a speed target;
  * every program claiming LuaJIT parity must match LuaJIT byte-for-byte;
  * no program may fail to run; and
  * discovery must still find at least as many programs as it did when the
    threshold was last set, so a silently-broken glob fails loudly instead of
    reporting a suspiciously fast empty suite.

It deliberately carries **no timing thresholds**. Per the Gothab performance
profile guidance, thresholds are only meaningful once repeated runs on the same
hardware class establish that pool's normal run-to-run noise. Until then a
timing contract would either be so loose it never fires or so tight it fires on
noise, and both teach us nothing. The timings are still recorded as
measurements, which is what makes establishing that noise band possible.
"""

import json
import sys

# Bump when discovery legitimately grows; a drop below this fails the contract.
# 28 is what `bench/run.py` discovers today, and what tools/hashgate.py gates
# (84 digests = 28 programs x 3 modes).
MIN_BENCHMARKS = 28


def kb_to_bytes(kb):
    if kb is None or kb == "":
        return None
    return float(kb) * 1024.0


def num(value):
    if value is None or value == "":
        return None
    return float(value)


def build(blob):
    rows = blob["rows"]
    measurements = []

    def add(name, value, unit):
        if value is None:
            return
        measurements.append({"name": name, "value": value, "unit": unit})

    cross_mismatches = 0
    luajit_diffs = 0
    errors = 0
    jit_total_ms = 0.0

    for row in rows:
        name = row["name"]

        if row["cross"] == "ERR":
            errors += 1
            continue
        if row["cross"] != "ok":
            cross_mismatches += 1
        # "skip"/"n/a" mean parity was never claimed or LuaJIT was absent;
        # only an actual byte difference or a failed LuaJIT run is a defect.
        if row["luajit"] in ("DIFF", "ERR"):
            luajit_diffs += 1

        t0_ms = num(row["t0"])
        jit_ms = num(row["jit"])
        lj_ms = num(row["lj"])

        add(f"{name}.t0.wall", t0_ms, "ms")
        add(f"{name}.jit.wall", jit_ms, "ms")
        add(f"{name}.lj.wall", lj_ms, "ms")
        if jit_ms is not None and lj_ms:
            add(f"{name}.jit_vs_lj", 100.0 * jit_ms / lj_ms, "percent")
        if t0_ms is not None and lj_ms:
            add(f"{name}.t0_vs_lj", 100.0 * t0_ms / lj_ms, "percent")
        add(f"{name}.native_residency", num(row["res"]), "percent")
        add(f"{name}.t0.maxrss", kb_to_bytes(row["mem_t0"]), "bytes")
        add(f"{name}.jit.maxrss", kb_to_bytes(row["mem_jit"]), "bytes")
        add(f"{name}.lj.maxrss", kb_to_bytes(row["mem_lj"]), "bytes")

        if jit_ms is not None:
            jit_total_ms += jit_ms

    add("suite.benchmarks", float(len(rows)), "count")
    add("suite.cross_mismatches", float(cross_mismatches), "count")
    add("suite.luajit_diffs", float(luajit_diffs), "count")
    add("suite.errors", float(errors), "count")
    add("suite.jit_wall_total", jit_total_ms, "ms")

    rules = [
        {"measurement": "suite.cross_mismatches", "comparison": "lte",
         "value": 0, "unit": "count"},
        {"measurement": "suite.luajit_diffs", "comparison": "lte",
         "value": 0, "unit": "count"},
        {"measurement": "suite.errors", "comparison": "lte",
         "value": 0, "unit": "count"},
    ]
    # The discovery-count rule asserts "the glob still finds every program",
    # which only means anything when nothing was filtered out on purpose.
    if not blob.get("filter"):
        rules.append({"measurement": "suite.benchmarks", "comparison": "gte",
                      "value": MIN_BENCHMARKS, "unit": "count"})

    return {
        "schema_version": 1,
        "profile": "bench-suite",
        "workload": {
            "name": "lune-bench-suite",
            "parameters": {
                "rev": blob["rev"],
                "reps": blob["reps"],
                "mem_reps": blob["mem_reps"],
                "scale": blob["scale"],
                "have_luajit": blob["have_luajit"],
            },
        },
        "contract": {"rules": rules},
        "measurements": measurements,
    }


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: bench_profile.py <run.py --json output> <profile.json>")
    with open(sys.argv[1]) as fh:
        blob = json.load(fh)
    report = build(blob)
    with open(sys.argv[2], "w") as fh:
        json.dump(report, fh, indent=2)
        fh.write("\n")
    print(f"wrote {sys.argv[2]}: {len(report['measurements'])} measurements, "
          f"{len(report['contract']['rules'])} contract rules")


if __name__ == "__main__":
    main()
