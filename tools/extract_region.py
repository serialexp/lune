#!/usr/bin/env python3
"""One-shot extraction of trace.zig's leaf type + region-model blocks.

Moves two contiguous, dependency-free blocks out of `src/trace.zig` into leaf
modules, verbatim (comments included), and leaves behind a re-export block so
every existing reference keeps resolving:

  src/trace_types.zig   trace-graph identities (GuardProvenance, ExitProvenance,
                        StructuralEdgeId, AnchorKey, MAX_INLINE_DEPTH, ...)
  src/trace_region.zig  the region DATA MODEL (RegionId/Key/Accum/Def/InternMap,
                        the observer caches, the set builders)

Deliberately NOT moved: the ~25 region *policy* methods on `TraceState`
(flushRegionWindow, openRegion, accountRegionProfit, rebuildRegions, ...). At
this revision those reach straight into `penalty`, `gate`, `promoted_sets`,
`gateAnchor`, `condemnProvenanceEdgesAt` and `disarmAllLinks` — the region layer
IS the tiering policy layer, so there is no seam to cut along without changing
behaviour. Only the state-free data model comes out.

Default is a dry run; pass --apply to write.
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "trace.zig")

# 1-based inclusive line ranges in the source revision.
TYPES_BLOCK = (489, 777)     # GuardProvenance section header .. hashExit
REGION_BLOCK = (779, 1142)   # Region model header .. RegionSetBuilder
ANCHOR_BLOCK = (1352, 1363)  # AnchorKey + its doc comment
DEPTH_BLOCK = (13501, 13506)  # MAX_INLINE_DEPTH + its doc comment

# Private helpers that must become `pub` to stay reachable across the new boundary.
TYPES_PUBIFY = ["exitOrder", "exitProvEntryLess", "MAX_INLINE_DEPTH"]
REGION_PUBIFY = [
    "ObserverSpan", "ObserverFast", "ObserverHot", "freeRegionBridges",
    "cloneRegionBridges", "freeRegionSetMap", "RegionSetBuilder",
    "programPointsEqual", "appendUniqueSlot", "programPointLess",
]

# Symbols re-exported from trace.zig so callers (and `trace.X` users elsewhere in
# the tree) are unaffected by the move.
TYPES_EXPORTS = [
    "CallEdge", "Polarity", "GuardRole", "OperandDesig", "GuardProvenance",
    "LinkTerminalProvenance", "ExitProvenance", "ExitProvEntry", "ExitKey",
    "ProgramPoint", "StructuralEdgeId", "AnchorKey", "MAX_INLINE_DEPTH",
    "exitOrder", "exitProvEntryLess",
]
REGION_EXPORTS = [
    "RegionId", "RegionKey", "RegionAccum", "RegionDestination", "RegionContext",
    "RegionClassifier", "RegionBridgeDef", "RegionDef", "RegionInternMap",
    "ObserverSpan", "ObserverFast", "ObserverHot", "freeRegionBridges",
    "cloneRegionBridges", "freeRegionSetMap", "RegionSetBuilder",
    "programPointsEqual", "appendUniqueSlot", "programPointLess",
]

TYPES_HEADER = '''//! Trace-graph identities: the guest-logical names for a trace's exits, anchors
//! and structural edges.
//!
//! A leaf module by construction — it owns no runtime state and imports nothing
//! but `std` and `bytecode.Proto`. Both `trace.zig` (which re-exports every
//! public name here, so existing `trace.GuardProvenance` spellings still work)
//! and `trace_region.zig` depend on it; it depends on neither.
//!
//! Moved out of `trace.zig` verbatim. The doc comments are the substance — they
//! record why guard identity is keyed on guest provenance rather than IR
//! position, and why the order/hash functions are field-wise.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const Proto = bytecode.Proto;

'''

REGION_HEADER = '''//! The region data model: the types the region-accounting layer is built out of.
//!
//! A *region* is a strongly-connected component of the structural trace graph
//! that contains a cycle — the guest-logical unit the exit-branch-patching gate
//! reasons about. This module owns the vocabulary (identity, discovery output,
//! per-activation accumulator, observer caches) and nothing else.
//!
//! SCOPE, deliberately: the region *policy* — `openRegion`, `closeRegion`,
//! `flushRegionWindow`, `accountRegionProfit`, `rebuildRegions`,
//! `validateRegionBridge` and the rest — stays on `TraceState` in `trace.zig`.
//! Those functions reach into `penalty`, `gate`, `promoted_sets`, `gateAnchor`,
//! `condemnProvenanceEdgesAt` and `disarmAllLinks`; at this revision the region
//! layer IS the tiering policy layer, and there is no boundary to cut along
//! without changing behaviour. Extracting the state-free data model is the part
//! that can be done as a pure move, so it is the part that was done.

const std = @import("std");
const trace_types = @import("trace_types.zig");

const StructuralEdgeId = trace_types.StructuralEdgeId;
const ProgramPoint = trace_types.ProgramPoint;
const AnchorKey = trace_types.AnchorKey;

'''


def pubify(text, names):
    for n in names:
        text, k = re.subn(rf"^(const|fn) {n}\b", rf"pub \1 {n}", text, flags=re.M)
        if k == 0:
            sys.exit(f"pubify: no top-level decl found for {n!r}")
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    lines = open(SRC).read().split("\n")

    def grab(rng):
        a, b = rng
        return "\n".join(lines[a - 1:b])

    types_src = grab(TYPES_BLOCK)
    region_src = grab(REGION_BLOCK)
    anchor_src = grab(ANCHOR_BLOCK)
    depth_src = grab(DEPTH_BLOCK)

    # Sanity: the ranges must start/end where we think they do.
    checks = [
        (types_src, "GuardProvenance (doc 17", "hashExit"),
        (region_src, "Region model (doc 17", "RegionSetBuilder"),
        (anchor_src, "Identifies a trace anchor", "pub const AnchorKey"),
        (depth_src, "Maximum nesting of inlined", "const MAX_INLINE_DEPTH = 3;"),
    ]
    for text, head, tail in checks:
        if head not in text or tail not in text:
            sys.exit(f"range check failed: expected {head!r} and {tail!r}")

    types_out = TYPES_HEADER + pubify(
        types_src + "\n\n" + anchor_src + "\n\n" + depth_src, TYPES_PUBIFY) + "\n"
    region_out = REGION_HEADER + pubify(region_src, REGION_PUBIFY) + "\n"

    # The re-export block that replaces the moved code in trace.zig.
    alias = ['// ' + '-' * 73,
             '// Trace-graph identities and the region data model live in leaf modules now',
             '// (`trace_types.zig`, `trace_region.zig`). Re-exported here so every existing',
             '// `trace.X` spelling keeps resolving and the move stays behaviour-free.',
             '// ' + '-' * 73,
             '',
             'pub const trace_types = @import("trace_types.zig");',
             'pub const trace_region = @import("trace_region.zig");',
             '']
    for n in TYPES_EXPORTS:
        alias.append(f"pub const {n} = trace_types.{n};")
    alias.append("")
    for n in REGION_EXPORTS:
        alias.append(f"pub const {n} = trace_region.{n};")
    alias.append("")

    # Rewrite trace.zig: drop the moved ranges (highest first so indices hold),
    # and splice the alias block in where the first block was.
    out = list(lines)
    for a, b in sorted([DEPTH_BLOCK, ANCHOR_BLOCK], reverse=True):
        del out[a - 1:b]
    del out[TYPES_BLOCK[0] - 1:REGION_BLOCK[1]]
    out[TYPES_BLOCK[0] - 1:TYPES_BLOCK[0] - 1] = alias
    trace_out = "\n".join(out)

    print(f"trace.zig      {len(lines):>6} -> {len(out):>6} lines "
          f"({len(lines) - len(out):+d})")
    print(f"trace_types.zig       {len(types_out.split(chr(10))):>6} lines (new)")
    print(f"trace_region.zig      {len(region_out.split(chr(10))):>6} lines (new)")
    print(f"re-exports            {len(TYPES_EXPORTS) + len(REGION_EXPORTS):>6} symbols")

    if not args.apply:
        print("\ndry run — pass --apply to write")
        return 0

    open(os.path.join(ROOT, "src", "trace_types.zig"), "w").write(types_out)
    open(os.path.join(ROOT, "src", "trace_region.zig"), "w").write(region_out)
    open(SRC, "w").write(trace_out)
    print("\nwritten")
    return 0


if __name__ == "__main__":
    sys.exit(main())
