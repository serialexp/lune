//! The canonical total order over table keys — the single source of truth shared
//! by snapshot serialization (`keyframeser.sortedHashEntries`) and the
//! `pairs`/`next` iterator (`stdlib/base.zig`).
//!
//! lune's table iteration order must be **deterministic and address-independent**
//! (docs/design/02-determinism.md): two runs that build the same key set in
//! different insertion orders must iterate identically, and a table restored from
//! a keyframe (rebuilt by one-by-one re-insertion, so `std.HashMap`'s raw probe
//! order differs) must iterate the same as the original. Both fall out of ordering
//! the hash part by this comparator instead of `std.HashMap`'s internal slot
//! order. Because snapshot bytes AND live `next` both key on it, a mid-iteration
//! keyframe resumes on exactly the same successor.
//!
//! This module imports only `value` — no `table`, no `interp` — so it stays a
//! leaf both `keyframeser` and the (future) `Table` next-cache can import without
//! a cycle.

const value = @import("value.zig");
const Value = value.Value;

/// A strict total order on *distinct* table keys, deterministic across runs and
/// across snapshot/restore. Keys order first by `Value.Tag` ordinal, then: heap
/// keys by their stable `GcHeader.id` (interning makes equal keys the same
/// object, so ids are unique per distinct key), non-heap keys (int/float/bool) by
/// raw payload bits. Distinct keys never tie. Address (`payload.bits` of a heap
/// ref) is never compared, so the order is ASLR-independent.
pub fn keyLessThan(a: Value, b: Value) bool {
    const ta = @intFromEnum(a.tag);
    const tb = @intFromEnum(b.tag);
    if (ta != tb) return ta < tb;
    if (a.isHeap()) return a.asHeap().id < b.asHeap().id;
    return a.payload.bits < b.payload.bits;
}

/// `std.mem.sort`-compatible wrapper (context-less) over `keyLessThan`.
pub fn less(_: void, a: Value, b: Value) bool {
    return keyLessThan(a, b);
}
