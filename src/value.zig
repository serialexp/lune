//! The universal runtime value: a 16-byte tagged slot.
//!
//! Decision (locked, see docs/design/00-architecture.md §Value representation):
//! a 16-byte tagged union — an explicit `Tag` plus an 8-byte payload — with
//! first-class `i64` *and* `f64`. Chosen over NaN-boxing because it is simple,
//! debuggable, and **self-describing**: a recorded value knows what it is with
//! no reconstruction, which is a direct gift to the trace format and the
//! time-travel visualiser. NaN-boxing stays available as a later density
//! optimisation for a narrower value set.
//!
//! The footprint cost (16 vs 8 bytes) is paid only on scattered heterogeneous
//! values; big homogeneous numeric arrays escape it via the unboxed
//! `TypedArray` in `object.zig`.

const std = @import("std");
const object = @import("object.zig");
const GcHeader = object.GcHeader;

/// The type tag. Coarse by design: every heap object is `heap_ref`, and its
/// concrete kind lives in the object header (`object.ObjectType`).
pub const Tag = enum(u8) {
    nil,
    boolean,
    /// 64-bit signed integer (first-class, not a float subtype).
    int,
    /// IEEE-754 double.
    float,
    /// Pointer to a GC object; payload is a `*GcHeader`.
    heap_ref,
};

/// The 8-byte payload. Untagged — the `Value.tag` selects the active field.
/// `extern union` for a defined, stable layout (the serializer reads `bits`).
pub const Payload = extern union {
    int: i64,
    float: f64,
    bits: u64,
    ptr: ?*GcHeader,
};

/// The 16-byte tagged value. `extern struct` pins `tag` at offset 0 and the
/// 8-byte payload at offset 8 (7 bytes padding between — the deliberate cost of
/// a self-describing slot).
pub const Value = extern struct {
    tag: Tag,
    payload: Payload,

    // ---- constructors ----

    pub fn nil() Value {
        return .{ .tag = .nil, .payload = .{ .bits = 0 } };
    }

    pub fn boolean(b: bool) Value {
        return .{ .tag = .boolean, .payload = .{ .bits = @intFromBool(b) } };
    }

    pub fn int(i: i64) Value {
        return .{ .tag = .int, .payload = .{ .int = i } };
    }

    pub fn float(f: f64) Value {
        return .{ .tag = .float, .payload = .{ .float = f } };
    }

    pub fn heap(ptr: *GcHeader) Value {
        return .{ .tag = .heap_ref, .payload = .{ .ptr = ptr } };
    }

    // ---- predicates ----

    pub fn isNil(self: Value) bool {
        return self.tag == .nil;
    }

    pub fn isBool(self: Value) bool {
        return self.tag == .boolean;
    }

    pub fn isInt(self: Value) bool {
        return self.tag == .int;
    }

    pub fn isFloat(self: Value) bool {
        return self.tag == .float;
    }

    pub fn isNumber(self: Value) bool {
        return self.tag == .int or self.tag == .float;
    }

    pub fn isHeap(self: Value) bool {
        return self.tag == .heap_ref;
    }

    /// Lua-shaped truthiness: only `nil` and `false` are falsy. `0`, `""`, and
    /// empty tables are truthy.
    pub fn isTruthy(self: Value) bool {
        return switch (self.tag) {
            .nil => false,
            .boolean => self.payload.bits != 0,
            else => true,
        };
    }

    // ---- accessors (debug-checked) ----

    pub fn asBool(self: Value) bool {
        std.debug.assert(self.tag == .boolean);
        return self.payload.bits != 0;
    }

    pub fn asInt(self: Value) i64 {
        std.debug.assert(self.tag == .int);
        return self.payload.int;
    }

    pub fn asFloat(self: Value) f64 {
        std.debug.assert(self.tag == .float);
        return self.payload.float;
    }

    pub fn asHeap(self: Value) *GcHeader {
        std.debug.assert(self.tag == .heap_ref);
        return self.payload.ptr.?;
    }

    /// Numeric value coerced to `f64` (for mixed arithmetic / comparison).
    /// Caller must ensure `isNumber()`.
    pub fn toFloat(self: Value) f64 {
        return switch (self.tag) {
            .int => @floatFromInt(self.payload.int),
            .float => self.payload.float,
            else => unreachable,
        };
    }

    /// Object kind for a heap value (one dereference). Caller must ensure
    /// `isHeap()`.
    pub fn heapType(self: Value) object.ObjectType {
        return self.asHeap().type;
    }

    /// Lua-style type name, for diagnostics (e.g. runtime-error messages:
    /// "attempt to perform arithmetic on a nil value"). Both closures and native
    /// functions report as "function"; tables and typed arrays as "table".
    pub fn typeName(self: Value) []const u8 {
        return switch (self.tag) {
            .nil => "nil",
            .boolean => "boolean",
            .int, .float => "number",
            .heap_ref => switch (self.heapType()) {
                .string => "string",
                .table, .typed_array => "table",
                .function, .native => "function",
                .upvalue => "upvalue",
                .host => "userdata",
                _ => "value",
            },
        };
    }

    // ---- equality ----

    /// `==` semantics. Numbers compare by mathematical value across the
    /// int/float boundary (`1 == 1.0`), exactly (no lossy `f64` conversion).
    /// Heap objects compare by their stable `GcHeader.id`, NOT by address.
    ///
    /// Within a single heap these are equivalent: every live object has a unique,
    /// never-reused id, and string interning means equal *content* is the same
    /// object (hence the same id). But identity-by-id is the load-bearing
    /// definition for deterministic replay (docs/design/02): after restoring a
    /// keyframe, the program image's proto constants still point into the heap
    /// they were compiled against, while their restored twins live in the new
    /// heap with a *different address but the same preserved id*. Address equality
    /// would make a resumed `get_global`/table lookup miss its own restored key;
    /// id equality resolves it. This also makes `eql` consistent with the
    /// id-based `table.ValueContext.hash` (an address would leak ASLR anyway).
    pub fn eql(self: Value, other: Value) bool {
        if (self.isNumber() and other.isNumber()) {
            return compareNumeric(self, other) == .eq;
        }
        if (self.tag != other.tag) return false;
        return switch (self.tag) {
            .nil => true,
            .boolean => self.asBool() == other.asBool(),
            .heap_ref => self.asHeap().id == other.asHeap().id,
            // numbers handled above
            .int, .float => unreachable,
        };
    }
};

/// Result of comparing two numbers. `unordered` only arises when a `NaN` is
/// involved (every IEEE comparison with `NaN` is false).
pub const NumOrder = enum { lt, eq, gt, unordered };

/// Exact ordering of two numeric values across the int/float boundary. Distinct
/// integers that round to the same `f64` are still ordered correctly, so we
/// avoid lossy conversion in the mixed case. Caller must ensure both are
/// numbers.
pub fn compareNumeric(a: Value, b: Value) NumOrder {
    if (a.tag == .int and b.tag == .int) {
        const x = a.asInt();
        const y = b.asInt();
        return if (x < y) .lt else if (x > y) .gt else .eq;
    }
    if (a.tag == .float and b.tag == .float) {
        const x = a.asFloat();
        const y = b.asFloat();
        if (std.math.isNan(x) or std.math.isNan(y)) return .unordered;
        return if (x < y) .lt else if (x > y) .gt else .eq;
    }
    // one int, one float: exact compare, oriented as (int ? float).
    if (a.tag == .int) {
        return compareIntFloat(a.asInt(), b.asFloat());
    } else {
        return reverse(compareIntFloat(b.asInt(), a.asFloat()));
    }
}

fn reverse(o: NumOrder) NumOrder {
    return switch (o) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
        .unordered => .unordered,
    };
}

/// The exact integer value of `f`, or `null` if `f` is not an integer that the
/// x86 `cvttsd2si` instruction can round-trip — i.e. not finite, not integral, or
/// outside `[-2^63, 2^63)`. This is the oracle for the trace JIT's `int_of_float`
/// op (`src/trace.zig`): the recorder only specializes a float loop-limit to an int
/// when this returns non-null, and the tier-1a executor side-exits exactly when it
/// returns null — so tier-1a matches the native lowering's `cvttsd2si`-round-trip
/// (`cvttsd2si; cvtsi2sd; ucomisd; jne/jp`) bit-for-bit. The `[-2^63, 2^63)` clamp
/// mirrors `compareIntFloat` above: `2^63` is representable as f64 but not i64, so
/// it (and anything larger, plus NaN/±inf) is rejected; `-2^63` is in range.
pub fn floatAsExactInt(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null; // NaN / ±inf
    if (@trunc(f) != f) return null; // has a fractional part
    if (f < -9223372036854775808.0 or f >= 9223372036854775808.0) return null;
    return @intFromFloat(f);
}

/// Exact ordering of integer `i` against double `f`.
fn compareIntFloat(i: i64, f: f64) NumOrder {
    if (std.math.isNan(f)) return .unordered;
    // 2^63 is representable as f64 but not as i64; clamp the out-of-range ends.
    if (f >= 9223372036854775808.0) return .lt; // i < 2^63 <= f
    if (f < -9223372036854775808.0) return .gt; // i >= -2^63 > f
    const t = @trunc(f); // integral part, now guaranteed in i64 range
    const fi: i64 = @intFromFloat(t);
    if (i < fi) return .lt;
    if (i > fi) return .gt;
    // integral parts equal; the fractional part of f breaks the tie.
    const frac = f - t;
    if (frac > 0) return .lt; // f = i + frac > i
    if (frac < 0) return .gt; // f = i + frac < i
    return .eq;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Value is a 16-byte, 8-aligned slot with tag at offset 0" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Value));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Value, "tag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Value, "payload"));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Payload));
}

test "floatAsExactInt: integral in-range accepts, else rejects" {
    const exp = std.testing.expectEqual;
    // Integral, in range → exact value.
    try exp(@as(?i64, 0), floatAsExactInt(0.0));
    try exp(@as(?i64, 0), floatAsExactInt(-0.0));
    try exp(@as(?i64, 5), floatAsExactInt(5.0));
    try exp(@as(?i64, -4), floatAsExactInt(-4.0));
    try exp(@as(?i64, 2560000), floatAsExactInt(2560000.0)); // an nsieve `m`
    // Integral above 2^53 but below 2^63 (exactly representable) → still exact.
    try exp(@as(?i64, 1 << 60), floatAsExactInt(@as(f64, @floatFromInt(@as(i64, 1) << 60))));
    // -2^63 is in range (representable as both); +2^63 is not (clamped out).
    try exp(@as(?i64, std.math.minInt(i64)), floatAsExactInt(-9223372036854775808.0));
    try exp(@as(?i64, null), floatAsExactInt(9223372036854775808.0));
    // Non-integral, NaN, ±inf → rejected.
    try exp(@as(?i64, null), floatAsExactInt(5.5));
    try exp(@as(?i64, null), floatAsExactInt(-0.5));
    try exp(@as(?i64, null), floatAsExactInt(std.math.nan(f64)));
    try exp(@as(?i64, null), floatAsExactInt(std.math.inf(f64)));
    try exp(@as(?i64, null), floatAsExactInt(-std.math.inf(f64)));
}

test "constructors and accessors round-trip" {
    try std.testing.expect(Value.nil().isNil());
    try std.testing.expectEqual(true, Value.boolean(true).asBool());
    try std.testing.expectEqual(@as(i64, -42), Value.int(-42).asInt());
    try std.testing.expectEqual(@as(f64, 3.5), Value.float(3.5).asFloat());

    var hdr = GcHeader.init(.string);
    const v = Value.heap(&hdr);
    try std.testing.expect(v.isHeap());
    try std.testing.expectEqual(object.ObjectType.string, v.heapType());
    try std.testing.expectEqual(&hdr, v.asHeap());
}

test "Lua truthiness: only nil and false are falsy" {
    try std.testing.expect(!Value.nil().isTruthy());
    try std.testing.expect(!Value.boolean(false).isTruthy());
    try std.testing.expect(Value.boolean(true).isTruthy());
    try std.testing.expect(Value.int(0).isTruthy());
    try std.testing.expect(Value.float(0.0).isTruthy());
}

test "eql: cross-type numeric equality by value" {
    try std.testing.expect(Value.int(1).eql(Value.float(1.0)));
    try std.testing.expect(Value.float(2.0).eql(Value.int(2)));
    try std.testing.expect(!Value.int(1).eql(Value.float(1.5)));
    try std.testing.expect(!Value.int(3).eql(Value.int(4)));
    try std.testing.expect(Value.nil().eql(Value.nil()));
    try std.testing.expect(!Value.nil().eql(Value.boolean(false)));
}

test "eql: large integers do not collide via f64 rounding" {
    // 2^53 and 2^53+1 both fit exactly... but 2^53+1 is NOT representable as
    // f64 (rounds to 2^53). Ensure int(2^53+1) != float(2^53).
    const big: i64 = (1 << 53) + 1;
    const as_f: f64 = @floatFromInt(@as(i64, 1) << 53); // 2^53 exactly
    try std.testing.expect(!Value.int(big).eql(Value.float(as_f)));
    // And the exactly-equal case still holds.
    try std.testing.expect(Value.int(@as(i64, 1) << 53).eql(Value.float(as_f)));
}

test "eql: i64 extremes vs f64 out of range" {
    const max = Value.int(std.math.maxInt(i64));
    // 2^63 as f64 is strictly greater than maxInt(i64); must not be equal.
    try std.testing.expect(!max.eql(Value.float(9223372036854775808.0)));
    try std.testing.expect(!Value.int(0).eql(Value.float(std.math.inf(f64))));
    try std.testing.expect(!Value.int(0).eql(Value.float(std.math.nan(f64))));
}
