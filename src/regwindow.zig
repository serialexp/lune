//! `RegWindow` — the frame-relative storage seam for the VM register file.
//!
//! This is the access abstraction that lets the SoA register-file flip
//! (`docs/design/09-soa-register-file.md`) be a localized change rather than a
//! sweep. **Phase 2** (current): the register file is struct-of-arrays —
//! parallel `tags: []u8` (the `Value.Tag` discriminant) + `payloads: []u64` (the
//! raw 8-byte `Value.payload.bits`). A window holds the two base pointers for a
//! frame's slots; `get`/`set` gather/scatter a `Value`, and the hot interpreter
//! arms use the direct `tagAt`/`bitsAt`/`setInt`/… accessors so an arithmetic
//! body never materializes a 16-byte `Value`. Payload bits round-trip **raw** —
//! no float/NaN recanonicalization — so every result is byte-identical to the
//! AoS layout (the determinism gate).
//!
//! A `RegWindow` is a value (two pointers + length); it is passed by value and
//! never outlives the frame whose registers it views. It addresses
//! **frame-relative** slots (`R[slot]`); cross-frame / whole-stack access goes
//! through the absolute `Vm.regGet`/`Vm.regSet` accessors instead (same SoA
//! arrays, base 0).

const std = @import("std");
const value = @import("value.zig");

const Value = value.Value;
const Tag = value.Tag;

pub const RegWindow = struct {
    /// The frame's tag lane: `tags[slot]` is `@intFromEnum(R[slot].tag)`.
    tags: [*]u8,
    /// The frame's payload lane: `payloads[slot]` is `R[slot].payload.bits` (raw).
    payloads: [*]u64,
    /// Number of registers the window spans.
    n: usize,

    /// A window over a frame's tag + payload slices (must be equal length).
    pub inline fn of(tags: []u8, payloads: []u64) RegWindow {
        std.debug.assert(tags.len == payloads.len);
        return .{ .tags = tags.ptr, .payloads = payloads.ptr, .n = tags.len };
    }

    /// An empty window — for call sites that have no live registers (cold
    /// `onBackEdge` arming, hand-built tests). The pointers are never
    /// dereferenced (`n == 0` guards every access).
    pub const empty: RegWindow = .{
        .tags = @constCast(&[_]u8{}),
        .payloads = @constCast(&[_]u64{}),
        .n = 0,
    };

    /// Read `R[slot]` — gather `tags[slot]` + `payloads[slot]` into a `Value`
    /// (raw payload bits, no recanonicalization).
    pub inline fn get(self: RegWindow, slot: usize) Value {
        return .{ .tag = @enumFromInt(self.tags[slot]), .payload = .{ .bits = self.payloads[slot] } };
    }

    /// Write `R[slot]` — scatter `v.tag` → `tags[slot]`, raw payload bits →
    /// `payloads[slot]`.
    pub inline fn set(self: RegWindow, slot: usize, v: Value) void {
        self.tags[slot] = @intFromEnum(v.tag);
        self.payloads[slot] = v.payload.bits;
    }

    /// Number of registers the window spans.
    pub inline fn len(self: RegWindow) usize {
        return self.n;
    }

    // ---- direct lane accessors (the hot arms; no `Value` materialization) ----

    /// The tag of `R[slot]` without building a `Value`.
    pub inline fn tagAt(self: RegWindow, slot: usize) Tag {
        return @enumFromInt(self.tags[slot]);
    }

    /// The raw 8-byte payload bits of `R[slot]` (caller knows the tag).
    pub inline fn bitsAt(self: RegWindow, slot: usize) u64 {
        return self.payloads[slot];
    }

    /// `R[slot] = i` (an integer Value) writing both lanes directly.
    pub inline fn setInt(self: RegWindow, slot: usize, i: i64) void {
        self.tags[slot] = @intFromEnum(Tag.int);
        self.payloads[slot] = @bitCast(i);
    }

    /// `R[slot] = f` (a float Value) writing both lanes directly.
    pub inline fn setFloat(self: RegWindow, slot: usize, f: f64) void {
        self.tags[slot] = @intFromEnum(Tag.float);
        self.payloads[slot] = @bitCast(f);
    }

    /// `R[slot] = b` (a boolean Value) writing both lanes directly.
    pub inline fn setBool(self: RegWindow, slot: usize, b: bool) void {
        self.tags[slot] = @intFromEnum(Tag.boolean);
        self.payloads[slot] = @intFromBool(b);
    }

    /// `R[slot] = nil` (tag nil, payload zero — mirrors `Value.nil()`).
    pub inline fn setNil(self: RegWindow, slot: usize) void {
        self.tags[slot] = @intFromEnum(Tag.nil);
        self.payloads[slot] = 0;
    }

    /// `R[dst] = R[src]` copying both lanes directly (the `move` opcode).
    pub inline fn copy(self: RegWindow, dst: usize, src: usize) void {
        self.tags[dst] = self.tags[src];
        self.payloads[dst] = self.payloads[src];
    }
};

test "RegWindow get/set round-trips over backing lanes" {
    var tags = [_]u8{ 0, 0, 0 };
    var pays = [_]u64{ 0, 0, 0 };
    const w = RegWindow.of(&tags, &pays);
    w.set(0, Value.int(10));
    w.set(1, Value.int(20));
    w.set(2, Value.nil());
    try std.testing.expectEqual(@as(usize, 3), w.len());
    try std.testing.expectEqual(@as(i64, 20), w.get(1).asInt());
    w.set(2, Value.boolean(true));
    try std.testing.expect(w.get(2).isBool() and w.get(2).asBool());
    w.set(0, Value.int(99));
    try std.testing.expectEqual(@as(i64, 99), w.get(0).asInt());
}

test "RegWindow direct lane accessors match Value round-trip" {
    var tags = [_]u8{ 0, 0, 0, 0 };
    var pays = [_]u64{ 0, 0, 0, 0 };
    const w = RegWindow.of(&tags, &pays);
    w.setInt(0, -7);
    w.setFloat(1, 2.5);
    w.setBool(2, true);
    w.setNil(3);
    try std.testing.expectEqual(value.Tag.int, w.tagAt(0));
    try std.testing.expectEqual(@as(i64, -7), @as(i64, @bitCast(w.bitsAt(0))));
    try std.testing.expectEqual(@as(f64, 2.5), w.get(1).asFloat());
    try std.testing.expect(w.get(2).asBool());
    try std.testing.expect(w.get(3).isNil());
    // copy moves both lanes
    w.copy(3, 1);
    try std.testing.expectEqual(@as(f64, 2.5), w.get(3).asFloat());
}

test "RegWindow.empty has zero length" {
    try std.testing.expectEqual(@as(usize, 0), RegWindow.empty.len());
}

// Raw payload bits must survive a NaN round-trip with no recanonicalization —
// the determinism contract the snapshot serializer depends on.
test "RegWindow preserves a signaling-NaN payload bit-for-bit" {
    var tags = [_]u8{0};
    var pays = [_]u64{0};
    const w = RegWindow.of(&tags, &pays);
    const snan_bits: u64 = 0x7ff0_0000_0000_0001; // a signaling NaN
    w.set(0, .{ .tag = .float, .payload = .{ .bits = snan_bits } });
    try std.testing.expectEqual(snan_bits, w.get(0).payload.bits);
    try std.testing.expectEqual(snan_bits, w.bitsAt(0));
}
