//! Tables — lune's one structured data type (the basis for arrays, maps, and,
//! once shapes land in Phase 9, objects/structs).
//!
//! Classic Lua split storage: a contiguous **array part** for a dense run of
//! positive-integer keys `1..n` (the common list case, and what makes `#t` and
//! sequential access fast), plus a **hash part** for everything else. Keys are
//! normalised Lua-style — a float with an integral value maps to the same slot
//! as the equivalent integer (`t[1] == t[1.0]`), and `nil`/`NaN` keys are
//! rejected. String keys compare by pointer thanks to interning (`string.zig`).
//!
//! Phase 3 builds correct semantics; the shape/hidden-class pointer (for frozen
//! struct-like tables, Phase 9) is not here yet. There is no metatable dispatch
//! yet either. Growth allocates through an injected allocator (Z-4) — the table
//! does not cache one.

const std = @import("std");
const object = @import("object.zig");
const value = @import("value.zig");
const GcHeader = object.GcHeader;
const Value = value.Value;

/// 2^63 as f64 — the first power of two beyond `i64`'s range, used to bound the
/// float→int key normalisation.
const two_pow_63: f64 = 9223372036854775808.0;

pub const Table = struct {
    header: GcHeader,
    /// Dense array part: `array.items[i]` holds key `i + 1`.
    array: std.ArrayListUnmanaged(Value) = .empty,
    /// Hash part: every key not in the array part.
    hash: Map = .empty,

    pub const Map = std.HashMapUnmanaged(
        Value,
        Value,
        ValueContext,
        std.hash_map.default_max_load_percentage,
    );

    /// Errors from a store. A bad key is a `TypeError` (Lua: "table index is
    /// nil"/"is NaN"); growth can fail with `OutOfMemory`.
    pub const Error = error{ TypeError, OutOfMemory };

    /// Allocate an empty table. Raw allocation only — GC-linking is the heap's
    /// job (`gc.zig`); callers should use `Heap.newTable`.
    pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*Table {
        const self = try gpa.create(Table);
        self.* = .{ .header = GcHeader.init(.table) };
        return self;
    }

    pub fn destroy(self: *Table, gpa: std.mem.Allocator) void {
        self.array.deinit(gpa);
        self.hash.deinit(gpa);
        gpa.destroy(self);
    }

    /// Recover the concrete table from its embedded header (layout-independent).
    pub fn fromHeader(h: *GcHeader) *Table {
        // `@alignCast`: no-op on native, required wasm32 alignment assertion (see
        // `String.fromHeader`). The object is allocated at `@alignOf(Table)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    /// `t[key]`. Returns `nil` for an absent or `nil`/`NaN` key (reads never
    /// error).
    pub fn get(self: *const Table, key: Value) Value {
        const nk = normalizeKey(key);
        if (nk.isInt()) return self.getInt(nk.asInt());
        if (nk.isNil()) return Value.nil();
        return self.hash.get(nk) orelse Value.nil();
    }

    /// `t[i]` for an integer key (array part fast path).
    pub fn getInt(self: *const Table, i: i64) Value {
        if (i >= 1 and i <= @as(i64, @intCast(self.array.items.len))) {
            return self.array.items[@intCast(i - 1)];
        }
        return self.hash.get(Value.int(i)) orelse Value.nil();
    }

    /// `t[key] = val`. A `nil`/`NaN` key errors; storing `nil` deletes.
    pub fn set(self: *Table, gpa: std.mem.Allocator, key: Value, val: Value) Error!void {
        if (key.isNil()) return Error.TypeError;
        if (key.isFloat() and std.math.isNan(key.asFloat())) return Error.TypeError;

        const nk = normalizeKey(key);
        if (nk.isInt()) {
            const i = nk.asInt();
            const n: i64 = @intCast(self.array.items.len);
            if (i >= 1 and i <= n) {
                self.array.items[@intCast(i - 1)] = val;
                return;
            }
            if (i == n + 1 and !val.isNil()) {
                try self.array.append(gpa, val);
                try self.migrateFromHash(gpa);
                return;
            }
            // otherwise falls through to the hash part
        }

        if (val.isNil()) {
            _ = self.hash.remove(nk);
        } else {
            try self.hash.put(gpa, nk, val);
        }
    }

    /// Restore-only: insert a key/value straight into the **hash part**, bypassing
    /// `set`'s array-migration logic. The keyframe restorer (`keyframeser.zig`)
    /// uses this to reproduce a snapshot's *exact* array/hash split: a serialized
    /// hash-part entry whose key is an integer that happens to be contiguous with
    /// the already-rebuilt array part must NOT migrate into the array (or the
    /// restored table would re-serialize differently than it was captured). The
    /// array part is restored separately by appending into `array` directly, so
    /// this only ever handles genuine hash-part keys. The key is normalised (so
    /// `2.0` and `2` still collapse), and `nil`/`NaN` keys are rejected as in `set`.
    pub fn restoreEntry(self: *Table, gpa: std.mem.Allocator, key: Value, val: Value) Error!void {
        if (key.isNil()) return Error.TypeError;
        if (key.isFloat() and std.math.isNan(key.asFloat())) return Error.TypeError;
        try self.hash.put(gpa, normalizeKey(key), val);
    }

    /// After extending the array part, absorb any now-contiguous successor keys
    /// that were sitting in the hash part.
    fn migrateFromHash(self: *Table, gpa: std.mem.Allocator) Error!void {
        while (true) {
            const next = Value.int(@as(i64, @intCast(self.array.items.len)) + 1);
            const v = self.hash.get(next) orelse break;
            if (v.isNil()) break;
            try self.array.append(gpa, v);
            _ = self.hash.remove(next);
        }
    }

    /// A *border* `n` such that `t[n] ~= nil` and `t[n+1] == nil` (or `0`). Like
    /// Lua, with holes any valid border may be returned; this is `#t`.
    pub fn length(self: *const Table) i64 {
        var n: usize = self.array.items.len;
        // Trim trailing nils: if the array part ends in a nil, the border is the
        // last non-nil prefix and cannot extend past it.
        while (n > 0 and self.array.items[n - 1].isNil()) n -= 1;
        if (n < self.array.items.len) return @intCast(n);

        // Array part is non-nil through its end; the border may continue into the
        // hash part. Unbound-then-binary search, as luaH_getn does.
        if (self.hash.count() == 0) return @intCast(n);
        var i: i64 = @intCast(n); // getInt(i) non-nil (or i == 0)
        var j: i64 = i + 1;
        while (!self.getInt(j).isNil()) {
            i = j;
            if (j > @divFloor(std.math.maxInt(i64), 2)) {
                // Pathological: fall back to a linear scan from 1.
                var k: i64 = 1;
                while (!self.getInt(k).isNil()) k += 1;
                return k - 1;
            }
            j *= 2;
        }
        // getInt(i) non-nil, getInt(j) nil → binary search the border between.
        while (j - i > 1) {
            const m = @divFloor(i + j, 2);
            if (self.getInt(m).isNil()) j = m else i = m;
        }
        return i;
    }
};

/// Map key normalisation: a float with an exact integral value in `i64` range
/// becomes the equivalent integer key, so `t[2]` and `t[2.0]` are one slot.
/// Everything else is returned unchanged.
fn normalizeKey(key: Value) Value {
    if (key.isFloat()) {
        const f = key.asFloat();
        if (!std.math.isNan(f) and !std.math.isInf(f) and
            @floor(f) == f and f >= -two_pow_63 and f < two_pow_63)
        {
            return Value.int(@intFromFloat(f));
        }
    }
    return key;
}

/// Hash/equality for `Value` keys. Stateless (zero-sized), so the unmanaged map's
/// inferred-context convenience methods apply. Keys are always normalised before
/// they reach here, so equal keys (per `Value.eql`) share tag+payload bits and
/// therefore hash identically.
pub const ValueContext = struct {
    pub fn hash(_: ValueContext, v: Value) u64 {
        var h = std.hash.Wyhash.init(0);
        const tag_byte: u8 = @intFromEnum(v.tag);
        h.update(&.{tag_byte});
        if (v.isHeap()) {
            // Hash a heap key by its stable, deterministic object id — NOT
            // `payload.bits`, which is the object's *address*. An address is
            // ASLR-dependent, so hashing it makes the hash-map's slot layout (and
            // therefore its iteration order) vary run-to-run. That divergence is
            // invisible to a program today (no `pairs`/`next`), but it is real and
            // it surfaces the moment iteration order is observed — e.g. a keyframe
            // snapshot serializing the hash part (`keyframeser.zig`). Hashing by
            // `id` is consistent with `eql` (equal heap keys are the same interned
            // object, hence the same id) and is reproducible. See
            // docs/design/02-determinism.md §"Table iteration order".
            const id = v.asHeap().id;
            h.update(std.mem.asBytes(&id));
        } else {
            h.update(std.mem.asBytes(&v.payload.bits));
        }
        return h.final();
    }
    pub fn eql(_: ValueContext, a: Value, b: Value) bool {
        return a.eql(b);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "set/get across array and hash parts" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.int(1), Value.int(10));
    try t.set(gpa, Value.int(2), Value.int(20));
    try t.set(gpa, Value.int(100), Value.int(999)); // sparse → hash part

    try testing.expectEqual(@as(i64, 10), t.get(Value.int(1)).asInt());
    try testing.expectEqual(@as(i64, 20), t.get(Value.int(2)).asInt());
    try testing.expectEqual(@as(i64, 999), t.get(Value.int(100)).asInt());
    try testing.expect(t.get(Value.int(3)).isNil());
}

test "float keys with integral value alias integer keys" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.int(1), Value.int(42));
    try testing.expectEqual(@as(i64, 42), t.get(Value.float(1.0)).asInt());

    try t.set(gpa, Value.float(2.0), Value.int(7));
    try testing.expectEqual(@as(i64, 7), t.get(Value.int(2)).asInt());

    // a non-integral float is its own distinct key
    try t.set(gpa, Value.float(2.5), Value.int(8));
    try testing.expectEqual(@as(i64, 8), t.get(Value.float(2.5)).asInt());
    try testing.expectEqual(@as(i64, 7), t.get(Value.int(2)).asInt());
}

test "appending pulls contiguous successors out of the hash part" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    // Insert 2 and 3 first (land in hash), then 1 (extends array → migrate).
    try t.set(gpa, Value.int(2), Value.int(2));
    try t.set(gpa, Value.int(3), Value.int(3));
    try testing.expectEqual(@as(i64, 0), t.length()); // no border yet (1 missing)
    try t.set(gpa, Value.int(1), Value.int(1));
    try testing.expectEqual(@as(i64, 3), t.length()); // 1,2,3 now contiguous
}

test "length border and deletion" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    var i: i64 = 1;
    while (i <= 5) : (i += 1) try t.set(gpa, Value.int(i), Value.int(i * i));
    try testing.expectEqual(@as(i64, 5), t.length());

    // Delete the tail; the border shrinks.
    try t.set(gpa, Value.int(5), Value.nil());
    try testing.expectEqual(@as(i64, 4), t.length());
    try testing.expect(t.get(Value.int(5)).isNil());
}

test "nil and NaN keys are rejected; missing keys read nil" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try testing.expectError(Table.Error.TypeError, t.set(gpa, Value.nil(), Value.int(1)));
    try testing.expectError(Table.Error.TypeError, t.set(gpa, Value.float(std.math.nan(f64)), Value.int(1)));
    try testing.expect(t.get(Value.nil()).isNil());
    try testing.expect(t.get(Value.boolean(true)).isNil());
}

test "boolean and (interned-style) pointer keys live in the hash part" {
    const t = try Table.create(testing.allocator);
    defer t.destroy(testing.allocator);
    const gpa = testing.allocator;

    try t.set(gpa, Value.boolean(true), Value.int(1));
    try t.set(gpa, Value.boolean(false), Value.int(2));
    try testing.expectEqual(@as(i64, 1), t.get(Value.boolean(true)).asInt());
    try testing.expectEqual(@as(i64, 2), t.get(Value.boolean(false)).asInt());
}
