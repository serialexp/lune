//! `RegWindow` — the frame-relative storage seam for the VM register file.
//!
//! This is the access abstraction that lets the SoA register-file flip
//! (`docs/design/09-soa-register-file.md`) be a localized change rather than a
//! sweep. **Phase 1** (current): a window wraps the live `Vm.stack` `[]Value`
//! slice 1:1, and `get`/`set` inline to a plain index — byte-identical codegen,
//! so the cold consumers we route through it (the trace recorder, the tier-1a
//! `irinterp` executor) compile exactly as before. **Phase 2**: the backing
//! swaps to parallel `tags: []u8` + `payloads: []u64` base pointers and
//! `get`/`set` become gather/scatter; because every per-slot consumer already
//! addresses through this seam, that flip touches only the accessor bodies (plus
//! the hot interpreter arms, which are rewritten at the same time).
//!
//! A `RegWindow` is a value (pointer + length); it is passed by value and never
//! outlives the frame whose registers it views. It addresses **frame-relative**
//! slots (`R[slot]`); cross-frame / whole-stack access goes through the absolute
//! `Vm.regGet`/`Vm.regSet` accessors instead (same seam, base 0).

const std = @import("std");
const value = @import("value.zig");

const Value = value.Value;

pub const RegWindow = struct {
    /// Phase 1 backing: the live register slice `Vm.stack[base .. base + n]`.
    /// Phase 2 replaces this field with `tags`/`payloads` base pointers + length;
    /// the accessors below are the only code that reads it.
    slots: []Value,

    /// A window over an existing `[]Value` register slice (Phase 1: the whole of
    /// the storage seam is this wrap).
    pub inline fn of(slots: []Value) RegWindow {
        return .{ .slots = slots };
    }

    /// An empty window — for call sites that have no live registers (cold
    /// `onBackEdge` arming, hand-built tests).
    pub const empty: RegWindow = .{ .slots = @constCast(&[_]Value{}) };

    /// Read `R[slot]`. Phase 2: gather `tags[slot]` + `payloads[slot]` into a
    /// `Value` (raw payload bits — no float/NaN recanonicalization).
    pub inline fn get(self: RegWindow, slot: usize) Value {
        return self.slots[slot];
    }

    /// Write `R[slot]`. Phase 2: scatter `v.tag` → `tags[slot]`, `v` payload bits
    /// → `payloads[slot]`.
    pub inline fn set(self: RegWindow, slot: usize, v: Value) void {
        self.slots[slot] = v;
    }

    /// Number of registers the window spans.
    pub inline fn len(self: RegWindow) usize {
        return self.slots.len;
    }
};

test "RegWindow get/set round-trips over a backing slice" {
    var backing = [_]Value{ Value.int(10), Value.int(20), Value.nil() };
    const w = RegWindow.of(&backing);
    try std.testing.expectEqual(@as(usize, 3), w.len());
    try std.testing.expectEqual(@as(i64, 20), w.get(1).asInt());
    w.set(2, Value.boolean(true));
    try std.testing.expect(backing[2].isBool() and backing[2].asBool());
    // Writes are visible through both the window and the backing array.
    w.set(0, Value.int(99));
    try std.testing.expectEqual(@as(i64, 99), w.get(0).asInt());
}

test "RegWindow.empty has zero length" {
    try std.testing.expectEqual(@as(usize, 0), RegWindow.empty.len());
}
