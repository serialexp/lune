//! Tests for `keyframeser.zig` — restore.
//!
//! Extracted verbatim from `keyframeser.zig`; bodies are unchanged.
//! Shared harness lives in `keyframeser_testutil.zig`.

const keyframeser = @import("keyframeser.zig");
const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const interp = @import("interp.zig");
const gc = @import("gc.zig");
const key_order = @import("key_order.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const diag = @import("diag.zig");
const trace = @import("trace.zig");
const Value = value.Value;
const GcHeader = object.GcHeader;
const Proto = bytecode.Proto;
const Vm = interp.Vm;
pub const schema = @import("gen/trace_schema.zig");
const testing = std.testing;
const mahina_parser = @import("parser.zig");
const mahina_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

const NativeRegistry = keyframeser.NativeRegistry;
const encodeSnapshot = keyframeser.encodeSnapshot;
const restore = keyframeser.restore;
const restoreSnapshot = keyframeser.restoreSnapshot;
const snapshot_format_version = keyframeser.snapshot_format_version;

const util = @import("keyframeser_testutil.zig");
const expectRestoreError = util.expectRestoreError;
const referenceRun = util.referenceRun;
const sBool = util.sBool;
const sFloat = util.sFloat;
const sInt = util.sInt;
const sNil = util.sNil;
const sRef = util.sRef;

// ---------------------------------------------------------------------------
// Restore (F2b) tests
// ---------------------------------------------------------------------------

/// Compile + run `source`, snapshot the final VM (`b0`), restore into a fresh VM,
/// re-snapshot it (`b1`), and assert `b0 == b1` byte-for-byte — the headline
/// guarantee that restore is the exact inverse of capture. The chunk is kept
/// alive across the restore (restored closures borrow its `*const Proto`s).
/// Returns the decoded object count so callers can add structural assertions.
fn expectRoundTrip(source: [:0]const u8) !void {
    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    const b1 = try encodeSnapshot(gpa, vm2);
    defer gpa.free(b1);

    try testing.expectEqualSlices(u8, b0, b1);
}

test "restore is the exact inverse of capture (byte-identical re-snapshot)" {
    // Each program leaves a different heap shape reachable from globals:
    // closures+upvalues, nested + string-keyed tables, a self-referential cycle,
    // multiple globals. A correct id-preserving restore must reproduce every one
    // byte-for-byte.
    try expectRoundTrip(
        \\local function adder(x) return function(y) return x + y end end
        \\g = {}
        \\g.add = adder(10)
        \\g[1] = 100
        \\g[2] = 200
        \\g.name = "mahina"
        \\g.self = g
    );
    try expectRoundTrip(
        \\config = { width = 640, height = 480, name = "mahina" }
        \\alpha = "a"; beta = "b"; gamma = "g"
    );
    try expectRoundTrip(
        \\local t = {}
        \\for i = 1, 8 do t[i] = i * i end
        \\t.tag = "squares"
        \\result = t
    );
    try expectRoundTrip(
        \\local function counter()
        \\  local n = 0
        \\  return function() n = n + 1; return n end
        \\end
        \\c = counter()
        \\first = c()
    );
    // The stdlib module tables (`string`, `io`) and `tonumber` are now in every
    // VM's globals as real heap tables/natives. Round-tripping a program that
    // references them confirms the module-table natives restore by their
    // qualified names without `UnknownNative`, and that the larger globals table
    // (which exposed the hash-layout fragility above) re-snapshots byte-identically.
    try expectRoundTrip(
        \\local s = string.format("%d-%s", 7, "x")
        \\result = { s = s, n = tonumber("42") }
    );
    // A table filled `t[2..K]` with no `t[1]` (the nsieve pattern) now triggers a
    // rehash that migrates the dense run into the array part, leaving a nil hole
    // at slot 1. Capture must serialize that array/hash split (holes included) and
    // restore must reproduce it verbatim — the rehash never runs on the restore
    // path, so a captured split round-trips byte-identically.
    try expectRoundTrip(
        \\local t = {}
        \\for i = 2, 40 do t[i] = i * 3 end
        \\t.tag = "sieve-shaped"
        \\result = t
    );
    // The literal nsieve fill: `t[2..K] = true`, all booleans, hole at 1. In memory
    // this packs into the *boolean* lane (~2 bits/slot), but capture emits logical
    // Values via `array.get`, so the snapshot bytes are independent of the lane — a
    // packed bool array and an unpacked `.value` array serialize identically. The
    // restored VM rebuilds the array in the `.value` lane (restore only appends,
    // never rehashes), and its re-capture is byte-identical to the original.
    try expectRoundTrip(
        \\local t = {}
        \\for i = 2, 64 do t[i] = true end
        \\t.tag = "bool-lane"
        \\result = t
    );
    // Metatables (chunk 2a): a table whose metatable is reachable ONLY through the
    // `metatable` edge (an anonymous `{ __index = ... }`), plus a function handler
    // that itself hangs off that metatable. The serializer must follow the
    // metatable edge into `objects[]` (just as `gc.blacken` marks it) or the
    // serialized `metatable_id` dangles and restore fails with `UnresolvedHeapRef`.
    // Restore rebinds `metatable_id` by id and re-derives the VM-level mm-name /
    // string-metatable roots, so the re-capture is byte-identical.
    try expectRoundTrip(
        \\local Obj = {}
        \\Obj.__index = Obj
        \\function Obj:val() return self.x end
        \\local o = setmetatable({ x = 7 }, Obj)
        \\local logged = setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v) end })
        \\result = { o = o, logged = logged }
    );
    // L-2: a live `load` closure reachable from globals. The keyframe carries the
    // chunk's source; restore recompiles it deterministically to the same proto/id,
    // so the serialized `HeapClosure.proto_id` resolves and the re-snapshot matches.
    // No string literals → nothing extra in the constant pool.
    try expectRoundTrip(
        \\f = load("return 6 * 7")
    );
    // L-2: a loaded chunk WITH a string-literal constant. The literal is interned
    // into the heap and is reachable through the closure's proto constants (the
    // walk mirrors `gc.markProtoConstants`), so it serializes as an object with its
    // own id. Restore re-interns the *same* bytes (pass 1a) BEFORE recompiling, so
    // the recompiled proto reuses that restored string rather than minting a new id
    // — the interning invariant (one String per byte-sequence) holds across restore.
    try expectRoundTrip(
        \\greet = load("return 'hello, mahina'")
    );
    // L-2: two loaded chunks, exercising the running `next_proto_id` offset across
    // chunks (chunk 2's ids start past chunk 1's). The second is vararg-bodied and
    // multi-proto (a nested function), so its proto subtree must also re-offset to
    // the identical id range on restore.
    try expectRoundTrip(
        \\a = load("return 1")
        \\b = load("local function inner(x) return x + ... end return inner")
    );
}

test "keyframe: a live grid deflates at capture and round-trips byte-identically (doc 14)" {
    // A matrix left *flattened* at final state must serialize as its logical nested
    // form — a grid is an in-memory optimisation, never written to the wire — and
    // re-snapshot byte-identically. `encodeSnapshot` deflates all grids up front;
    // restore only ever builds nested tables, so the re-capture matches.
    try expectRoundTrip(
        \\m = { {1,2,3}, {4,5,6} }
        \\m[1][1] = 10            -- inflate to a grid; still reachable from globals
    );
    // Reshaped (grown stride) + lane-widened, still a grid at capture; deflation
    // must reproduce the grown box and the widened cells as plain row tables.
    try expectRoundTrip(
        \\m = { {1,2}, {3,4} }
        \\m[1][1] = 9
        \\m[1][3] = 7             -- grow stride past 2
        \\m[2][1] = 1000000       -- widen the cell lane
        \\result = m
    );
    // A self-referential outer table that *also* holds a flattened matrix: the
    // matrix deflates, the cycle and the sibling string key round-trip unchanged.
    try expectRoundTrip(
        \\g = {}
        \\g.grid = { {1,2}, {3,4} }
        \\g.grid[2][2] = 40       -- inflate the inner matrix
        \\g.self = g
        \\g.name = "mahina"
    );
}

test "doc 49 P2b: hash-part physical layout diverges across restore; snapshot artifacts are layout-independent" {
    // The restore-boundary contract for the owned hash part (doc 49, codex
    // round-2): the map's PHYSICAL geometry — dead nodes, probe displacement,
    // `used` vs `live` — is deliberately NOT serialized. Capture walks live
    // entries in canonical order; restore rebuilds by fresh insertion. So a
    // history with deletions produces a pre-capture map with `used > live`,
    // while the restored twin is dead-node-free (`used == live`) — a REAL
    // layout divergence — yet the re-snapshot must be byte-identical, and a
    // second restore of the same bytes must reproduce the restored layout
    // slot-for-slot (artifacts and layout are pure functions of the logical
    // state, never of addresses or the mutation history).
    const gpa = testing.allocator;
    const source =
        \\t = { a1 = 1, a2 = 2, a3 = 3, a4 = 4, a5 = 5, a6 = 6 }
        \\t.a2 = nil
        \\t.a5 = nil
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    // Pre-capture: the deletions left dead nodes behind (Lua-style removal
    // never compacts), so the physical map is strictly bigger than the
    // logical one.
    const t1_val = vm.globals.get(try vm.heap.internValue("t"));
    try testing.expect(t1_val.isHeap() and t1_val.heapType() == .table);
    const t1 = table.Table.fromHeader(t1_val.asHeap());
    try testing.expectEqual(@as(u32, 4), t1.hash.live);
    try testing.expect(t1.hash.used > t1.hash.live);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // The serialized artifact must be UNCHANGED by the layout divergence:
    // capture reads the logical map (live entries, canonical order), never
    // the geometry. (Captured FIRST — probing keys below may intern strings
    // into vm2, which would legitimately change a later snapshot.)
    const b1 = try encodeSnapshot(gpa, vm2);
    defer gpa.free(b1);
    try testing.expectEqualSlices(u8, b0, b1);

    // Restored twin: fresh insertion of the live entries only — no dead
    // nodes. The physical layouts have genuinely diverged...
    const t2_val = vm2.globals.get(try vm2.heap.internValue("t"));
    try testing.expect(t2_val.isHeap() and t2_val.heapType() == .table);
    const t2 = table.Table.fromHeader(t2_val.asHeap());
    try testing.expectEqual(@as(u32, 4), t2.hash.live);
    try testing.expectEqual(t2.hash.live, t2.hash.used);
    try testing.expect(t2.hash.used != t1.hash.used);

    // ...while the logical content is identical.
    for ([_]struct { k: []const u8, v: i64 }{
        .{ .k = "a1", .v = 1 }, .{ .k = "a3", .v = 3 },
        .{ .k = "a4", .v = 4 }, .{ .k = "a6", .v = 6 },
    }) |kv| {
        try testing.expectEqual(kv.v, t2.get(try vm2.heap.internValue(kv.k)).asInt());
    }
    try testing.expect(t2.get(try vm2.heap.internValue("a2")).isNil());
    try testing.expect(t2.get(try vm2.heap.internValue("a5")).isNil());

    // Determinism from the restored state: a second restore of the same bytes
    // lands every key at the same (slot, mask) as the first — layout is a
    // pure function of the restored insertion history.
    const vm3 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm3.deinit();
        gpa.destroy(vm3);
    }
    const t3_val = vm3.globals.get(try vm3.heap.internValue("t"));
    const t3 = table.Table.fromHeader(t3_val.asHeap());
    for ([_][]const u8{ "a1", "a3", "a4", "a6" }) |k| {
        const s2 = t2.hashSlotOf(try vm2.heap.internValue(k)).?;
        const s3 = t3.hashSlotOf(try vm3.heap.internValue(k)).?;
        try testing.expectEqual(s2.slot, s3.slot);
        try testing.expectEqual(s2.mask, s3.mask);
    }
}

test "doc 62: a restored VM shares its protos' global slot hints with the original, and both read their own globals" {
    // Restore runs the original chunk's protos, so both VMs' `rd`/`wr` use
    // the same `Proto.global_slot_hints`. Their globals tables then diverge
    // (growth, deletion), and calls alternate between the VMs, so each
    // VM's first access sees a hint the other VM just moved.
    const gpa = testing.allocator;
    const source =
        \\x = 1
        \\function rd() return x end
        \\function wr(v) x = v end
        \\function grow(p, n) for i = 1, n do _G[p .. i] = i end end
        \\function shrink(p, n) for i = 1, n do _G[p .. i] = nil end end
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);
    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    const Side = struct {
        fn call(v: *Vm, name: []const u8, args: []const Value) !Value {
            const f = v.globals.get(try v.heap.internValue(name));
            var out: [1]Value = .{Value.nil()};
            _ = try v.callValue(f, args, out[0..]);
            return out[0];
        }
        fn expectX(v: *Vm, want: i64) !void {
            try testing.expectEqual(want, (try call(v, "rd", &.{})).asInt());
        }
    };
    const vms = [_]*Vm{ &vm, vm2 };

    try Side.expectX(&vm, 1);
    try Side.expectX(vm2, 1);
    for (0..6) |round| {
        // Diverge the layouts: one VM grows, the other grows then deletes.
        const grower = vms[round % 2];
        const other = vms[(round + 1) % 2];
        const p = try grower.heap.internValue(if (round % 2 == 0) "a" else "b");
        _ = try Side.call(grower, "grow", &.{ p, Value.int(@intCast(40 * (round + 1))) });
        const q = try other.heap.internValue("c");
        _ = try Side.call(other, "grow", &.{ q, Value.int(30) });
        _ = try Side.call(other, "shrink", &.{ q, Value.int(30) });

        const base: i64 = @intCast(100 * round);
        _ = try Side.call(&vm, "wr", &.{Value.int(base + 1)});
        _ = try Side.call(vm2, "wr", &.{Value.int(base + 2)});
        for (0..3) |_| {
            try Side.expectX(&vm, base + 1);
            try Side.expectX(vm2, base + 2);
        }
    }
}

test "restore reanimates a live load closure that runs with the same result (L-2)" {
    const gpa = testing.allocator;
    const source =
        \\f = load("local a, b = ...\nreturn a * b + 1")
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    // Sanity: the live VM owns exactly the one loaded chunk.
    try testing.expectEqual(@as(usize, 1), vm.loaded_chunks.items.len);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // The loaded chunk was recompiled on restore.
    try testing.expectEqual(@as(usize, 1), vm2.loaded_chunks.items.len);

    // The restored closure is callable and computes the same vararg result:
    // (6 * 7) + 1 == 43.
    const key = try vm2.heap.internValue("f");
    const f = vm2.globals.get(key);
    try testing.expect(f.isHeap() and f.heapType() == .function);
    var out: [1]Value = undefined;
    const n = try vm2.callValue(f, &.{ Value.int(6), Value.int(7) }, out[0..]);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i64, 43), out[0].asInt());
}

test "restore rebuilds globals, ids, and a reachable value graph" {
    const gpa = testing.allocator;
    const source =
        \\local function adder(x) return function(y) return x + y end end
        \\g = {}
        \\g.add = adder(10)
        \\g.name = "mahina"
        \\g.self = g
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    // Decode the original to learn the object count + globals id for assertions.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try schema.SnapshotFile.decode(arena.allocator(), b0);
    var max_id: u32 = 0;
    for (decoded.keyframe.objects) |o| max_id = @max(max_id, o.id);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // Id space is reproduced exactly; the counter is restored VERBATIM from the
    // serialized `next_obj_id` (v5, H-2), and parked strictly past the max id. For
    // this garbage-free program the two coincide (`next_obj_id == max_id + 1`).
    try testing.expectEqual(@as(usize, decoded.keyframe.objects.len), vm2.heap.object_count);
    try testing.expectEqual(decoded.keyframe.next_obj_id, vm2.heap.next_obj_id);
    try testing.expect(vm2.heap.next_obj_id >= max_id + 1);
    try testing.expectEqual(decoded.keyframe.globals_id, vm2.globals.header.id);

    // Walk globals → g → name == "mahina"; interning an already-present key resolves
    // to the restored object (no new allocation).
    const g_val = vm2.globals.get(try vm2.heap.internValue("g"));
    try testing.expect(g_val.isHeap() and g_val.heapType() == .table);
    const g_tbl = table.Table.fromHeader(g_val.asHeap());

    const name_val = g_tbl.get(try vm2.heap.internValue("name"));
    try testing.expect(name_val.isHeap() and name_val.heapType() == .string);
    try testing.expectEqualStrings("mahina", string.String.fromHeader(name_val.asHeap()).bytes());

    // g.self is the same restored table object (cycle preserved).
    const self_val = g_tbl.get(try vm2.heap.internValue("self"));
    try testing.expect(self_val.isHeap() and self_val.asHeap() == &g_tbl.header);

    // g.add is a closure whose captured upvalue holds 10.
    const add_val = g_tbl.get(try vm2.heap.internValue("add"));
    try testing.expect(add_val.isHeap() and add_val.heapType() == .function);
    const add_cl = function.Closure.fromHeader(add_val.asHeap());
    try testing.expectEqual(@as(usize, 1), add_cl.upvalues.len);
    try testing.expectEqual(@as(i64, 10), vm2.upvalGet(add_cl.upvalues[0]).asInt());

    // print is still a native bound under its name.
    const print_val = vm2.globals.get(try vm2.heap.internValue("print"));
    try testing.expect(print_val.isHeap() and print_val.heapType() == .native);
    try testing.expectEqualStrings("print", function.Native.fromHeader(print_val.asHeap()).name);
}

test "H-2: next_obj_id survives pre-cut garbage (restored verbatim, not reconstructed from max id)" {
    const gpa = testing.allocator;
    // Under gc_stress the collector runs at every safepoint, so a dropped table is
    // swept before the next allocation. We allocate the survivors FIRST, then 20
    // throwaway tables that are all collected — each bumped `next_obj_id` (1:1 with
    // allocation) but left NO `objects` entry. This is the "pre-cut garbage" case
    // the serialized counter (v5, H-2) exists for: reconstructing it as max(id)+1
    // would drift it low and diverge every subsequent id (ids are observable via
    // table/`pairs` order), so restore must take the counter VERBATIM from the wire.
    const source =
        \\g = {}
        \\g.n = 42
        \\for i = 1, 20 do local junk = {} end
        \\for i = 1, 5 do end
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.heap.gc_stress = true; // collect at every safepoint → the junk is really swept
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    const sf = try encodeSnapshot(gpa, &vm);
    defer gpa.free(sf);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try schema.SnapshotFile.decode(arena.allocator(), sf);

    // Garbage really happened: allocation bumps the counter 1:1 and this program
    // makes no grid rows, so `next_obj_id == object_count` would hold with NO frees.
    // A counter strictly above the live count is the drift the fix captures.
    try testing.expect(decoded.keyframe.next_obj_id > decoded.keyframe.objects.len);

    // Restore reproduces the counter VERBATIM (a `max_id + 1` reconstruction would
    // land BELOW this), and the whole snapshot round-trips byte-identical.
    const vm2 = try restore(gpa, sf, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }
    try testing.expectEqual(decoded.keyframe.next_obj_id, vm2.heap.next_obj_id);
    const sf2 = try encodeSnapshot(gpa, vm2);
    defer gpa.free(sf2);
    try testing.expectEqualSlices(u8, sf, sf2);
}

test "chunk rooting: retained-chunk constants survive a snapshot straddle iff the host re-retains in the same order" {
    const gpa = testing.allocator;
    // docs/design/03 §"Chunk-constant rooting", restore path A. Three host chunks
    // X/Y/Z are compiled and RETAINED but never run — their only reachability is the
    // borrow list, so their distinctive literals "olx"/"oly"/"olz" enter the snapshot
    // via the .snapshot root walk (rooting retained chunks in BOTH walks is what makes
    // the ids survive). Because the snapshot serializes in root-DISCOVERY order and
    // that order is the retain order, byte-identity across the straddle requires the
    // host to re-compile + re-retain in the SAME order on restore. Re-retaining in a
    // different order re-serializes the same objects in different positions → the
    // bytes differ, which is exactly why `releaseChunk` uses `orderedRemove`.
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();

    const main_src: [:0]const u8 = "x = 1\n";
    const sx: [:0]const u8 = "print(\"olx\")\n";
    const sy: [:0]const u8 = "print(\"oly\")\n";
    const sz: [:0]const u8 = "print(\"olz\")\n";

    var vm = try Vm.init(gpa);
    defer vm.deinit();

    var tm = try mahina_parser.parse(gpa, main_src, &diags);
    defer tm.deinit();
    var cm = try mahina_compiler.compile(gpa, vm.heap, main_src, tm.root, &diags);
    defer cm.deinit();
    var tx = try mahina_parser.parse(gpa, sx, &diags);
    defer tx.deinit();
    var cx = try mahina_compiler.compile(gpa, vm.heap, sx, tx.root, &diags);
    defer cx.deinit();
    var ty = try mahina_parser.parse(gpa, sy, &diags);
    defer ty.deinit();
    var cy = try mahina_compiler.compile(gpa, vm.heap, sy, ty.root, &diags);
    defer cy.deinit();
    var tz = try mahina_parser.parse(gpa, sz, &diags);
    defer tz.deinit();
    var cz = try mahina_compiler.compile(gpa, vm.heap, sz, tz.root, &diags);
    defer cz.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(cm.proto);
    try vm.retainChunk(cx.proto);
    try vm.retainChunk(cy.proto);
    try vm.retainChunk(cz.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    // Restore path A: the host re-supplies its program image. We re-compile the three
    // chunks against the restored heap (interning reuses the reconstructed same-id
    // strings) and re-retain them. SAME order → byte-identical re-encode.
    {
        const vm2 = try restore(gpa, b0, cm.proto, NativeRegistry.base());
        defer {
            vm2.deinit();
            gpa.destroy(vm2);
        }
        var d2 = Diagnostics.init(gpa);
        defer d2.deinit();
        var rx = try mahina_compiler.compile(gpa, vm2.heap, sx, tx.root, &d2);
        defer rx.deinit();
        var ry = try mahina_compiler.compile(gpa, vm2.heap, sy, ty.root, &d2);
        defer ry.deinit();
        var rz = try mahina_compiler.compile(gpa, vm2.heap, sz, tz.root, &d2);
        defer rz.deinit();
        try testing.expect(!d2.hasErrors());
        try vm2.retainChunk(rx.proto);
        try vm2.retainChunk(ry.proto);
        try vm2.retainChunk(rz.proto);

        const b1 = try encodeSnapshot(gpa, vm2);
        defer gpa.free(b1);
        try testing.expectEqualSlices(u8, b0, b1);
    }

    // Re-retaining in REVERSED order re-serializes the same constants in different
    // discovery positions → the bytes must differ (guards the ordering contract).
    {
        const vm3 = try restore(gpa, b0, cm.proto, NativeRegistry.base());
        defer {
            vm3.deinit();
            gpa.destroy(vm3);
        }
        var d3 = Diagnostics.init(gpa);
        defer d3.deinit();
        var rx = try mahina_compiler.compile(gpa, vm3.heap, sx, tx.root, &d3);
        defer rx.deinit();
        var ry = try mahina_compiler.compile(gpa, vm3.heap, sy, ty.root, &d3);
        defer ry.deinit();
        var rz = try mahina_compiler.compile(gpa, vm3.heap, sz, tz.root, &d3);
        defer rz.deinit();
        try testing.expect(!d3.hasErrors());
        try vm3.retainChunk(rz.proto); // reversed
        try vm3.retainChunk(ry.proto);
        try vm3.retainChunk(rx.proto);

        const b2 = try encodeSnapshot(gpa, vm3);
        defer gpa.free(b2);
        try testing.expect(!std.mem.eql(u8, b0, b2));
    }
}

test "H-2/G-2: snapshot bytes are identical whether or not the JIT recorded (trace consts excluded from the snapshot walk)" {
    const gpa = testing.allocator;
    // A hot loop reads a constant string key `t.k`; the recorder captures the
    // interned "k" as a LIVE trace const (it is the key operand of `get_index`). `t`
    // is block-scoped and gone before the program ends, so at the FINAL snapshot
    // (`depth==0` — no frame closure roots the proto tree, `interp.zig:1612`) the
    // string "k" is rooted ONLY by the cached trace in a recording mode, and by
    // nothing at all under `.off`. Before the {gc,snapshot} split (doc 17 H-2/G-2)
    // the record-mode snapshot serialized "k" while `.off` did not → divergent
    // restored heaps. The split excludes trace consts from the snapshot walk, so the
    // serialized heap is byte-identical regardless of what the JIT recorded.
    // The hot loop lives inside `run` (a nested static proto) with all-local state —
    // a *global* accumulator would abort recording on the per-iteration store. After
    // `run` returns and then main returns, neither `run`'s closure nor `t` is
    // reachable, so at the final snapshot "k" is rooted only by the cached trace.
    const source =
        \\local function run()
        \\  local t = { k = 7 }
        \\  local sum = 0
        \\  for i = 1, 200 do sum = sum + t.k end
        \\  return sum
        \\end
        \\result = run()
    ;
    const H = struct {
        fn snap(a: std.mem.Allocator, src: [:0]const u8, jit: bool, stress: bool) ![]u8 {
            var diags = Diagnostics.init(a);
            defer diags.deinit();
            var tree = try mahina_parser.parse(a, src, &diags);
            defer tree.deinit();
            var vm = try Vm.init(a);
            defer vm.deinit();
            vm.heap.gc_stress = stress;
            vm.trace.config.enabled = jit;
            vm.trace.config.execute = jit;
            vm.trace.config.optimize = jit;
            vm.trace.config.hotloop = 4; // trace the short test loop
            var sink_buf: [64]u8 = undefined;
            var sink = io.Writer.fixed(&sink_buf);
            vm.out = &sink;
            var chunk = try mahina_compiler.compile(a, vm.heap, src, tree.root, &diags);
            defer chunk.deinit();
            try testing.expect(!diags.hasErrors());
            _ = try vm.run(chunk.proto);
            // Sanity: a recording mode must actually have committed a trace with "k"
            // in its const pool — otherwise this test proves nothing.
            if (jit) {
                var found_k = false;
                for (vm.trace.registry.cache.items) |t| {
                    for (t.code.consts) |v| {
                        if (v.isHeap() and v.heapType() == .string and
                            std.mem.eql(u8, string.String.fromHeader(v.asHeap()).bytes(), "k")) found_k = true;
                    }
                }
                try testing.expect(found_k);
            }
            return encodeSnapshot(a, &vm);
        }
    };
    inline for (.{ false, true }) |stress| {
        const off = try H.snap(gpa, source, false, stress);
        defer gpa.free(off);
        const rec = try H.snap(gpa, source, true, stress);
        defer gpa.free(rec);
        // Byte-identical snapshots ⇒ the trace-only "k" is NOT serialized in record
        // mode. (Load-bearing: reverting the `.snapshot` split to `.gc` reddens this.)
        try testing.expectEqualSlices(u8, off, rec);
    }
}

test "restore reanimates the package/require module system (searchers rebind, cache survives)" {
    const gpa = testing.allocator;
    // Two preloaded modules; only "a" is required (and cached) before the snapshot.
    // After restore: require("a") must hit the surviving cache, and require("b") must
    // run the searcher array — proving the `manual` searcher natives rebound by name
    // and the restored preload closures are still callable.
    const source =
        \\package.preload["a"] = function(n) return "A:" .. n end
        \\package.preload["b"] = function(n) return "B:" .. n end
        \\loaded_a = require("a")
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // package.searchers restored as a 2-element array of natives, rebound by name.
    const pkg_val = vm2.globals.get(try vm2.heap.internValue("package"));
    try testing.expect(pkg_val.isHeap() and pkg_val.heapType() == .table);
    const pkg = table.Table.fromHeader(pkg_val.asHeap());
    const searchers_val = pkg.get(try vm2.heap.internValue("searchers"));
    try testing.expect(searchers_val.isHeap() and searchers_val.heapType() == .table);
    const searchers = table.Table.fromHeader(searchers_val.asHeap());
    try testing.expect(searchers.getInt(1).heapType() == .native);
    try testing.expect(searchers.getInt(2).heapType() == .native);

    // The cached module "a" survived the snapshot (package.loaded.a == "A:a").
    const loaded_val = pkg.get(try vm2.heap.internValue("loaded"));
    const loaded = table.Table.fromHeader(loaded_val.asHeap());
    const cached_a = loaded.get(try vm2.heap.internValue("a"));
    try testing.expectEqualStrings("A:a", string.String.fromHeader(cached_a.asHeap()).bytes());

    // require still works on the restored VM: "a" from cache, "b" via the rebound
    // searcher + restored preload closure.
    const require_val = vm2.globals.get(try vm2.heap.internValue("require"));
    try testing.expect(require_val.isHeap() and require_val.heapType() == .native);
    var out: [1]Value = undefined;
    _ = try vm2.callValue(require_val, &.{try vm2.heap.internValue("a")}, out[0..]);
    try testing.expectEqualStrings("A:a", string.String.fromHeader(out[0].asHeap()).bytes());
    _ = try vm2.callValue(require_val, &.{try vm2.heap.internValue("b")}, out[0..]);
    try testing.expectEqualStrings("B:b", string.String.fromHeader(out[0].asHeap()).bytes());
}

test "doc 19 §R2: v8 schema boundary — version rejection + missing loaded literal trips the zero-allocation check" {
    // Replaces the H-2 "stamped dynamic after restore" test (the stamp is gone —
    // loaded chunks trace like static code). Pins the two v8 boundary properties:
    //   (a) a snapshot claiming any other version is rejected (UnsupportedVersion) —
    //       pre-rooting snapshots may legitimately omit dropped loaded-chunk
    //       literals, so they must never enter the v8 invariant domain;
    //   (b) a v8 snapshot that IS missing a loaded-proto literal (hand-corrupted
    //       here by deleting the string object) makes `recompileLoadedChunks`
    //       allocate — restore must reject it (`LoadedChunkRecompileAllocated`)
    //       rather than silently fork the allocation timeline.
    const gpa = testing.allocator;
    // The loaded chunk's closure is DROPPED before the cut: post-doc-19 its literal
    // ("victim") stays in the snapshot purely via the `loaded_chunks` root, with no
    // other serialized edge — so deleting that one object yields exactly the
    // pre-v8 "dropped closure" snapshot shape.
    const source =
        \\local f = load("local t = {victim=1} return t.victim")
        \\answer = f()
        \\f = nil
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expect(vm.loaded_chunks.items.len >= 1);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    // Sanity: the unmodified v8 snapshot restores, and the loaded-proto literal is
    // present as an object (the `.snapshot` root put it there despite the dropped
    // closure).
    {
        const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
        defer {
            vm2.deinit();
            gpa.destroy(vm2);
        }
        try testing.expect(vm2.loaded_chunks.items.len >= 1);
    }

    // (a) Version rejection: same bytes, version stamped 7.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var snap = try schema.SnapshotFile.decode(arena.allocator(), b0);
        snap.version = 7;
        try testing.expectError(error.UnsupportedVersion, restoreSnapshot(gpa, snap, chunk.proto, NativeRegistry.base()));
    }

    // (b) Zero-allocation check: same bytes, the "victim" string object deleted.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var snap = try schema.SnapshotFile.decode(arena.allocator(), b0);
        var kept = try arena.allocator().alloc(schema.HeapObject, snap.keyframe.objects.len);
        var n: usize = 0;
        var dropped: usize = 0;
        for (snap.keyframe.objects) |o| {
            const is_victim = o.body == .HeapString and std.mem.eql(u8, o.body.HeapString.bytes, "victim");
            if (is_victim) {
                dropped += 1;
                continue;
            }
            kept[n] = o;
            n += 1;
        }
        try testing.expectEqual(@as(usize, 1), dropped); // the literal WAS serialized
        snap.keyframe.objects = kept[0..n];
        try testing.expectError(error.LoadedChunkRecompileAllocated, restoreSnapshot(gpa, snap, chunk.proto, NativeRegistry.base()));
    }
}

test "doc 19 §T3: restored load-driven program resumes with the JIT and traces its LOADED proto" {
    // Doc 19 testing item 3 (extends the doc-18 §R3 pattern): a program whose hot
    // loop lives in a `load`ed chunk is cut mid-run, restored (v8 recompiles the
    // chunk zero-allocation), and resumed with tracing + native codegen. Pins:
    //   (a) resumed output == uninterrupted tier-0 output;
    //   (b) a trace ANCHORED IN THE LOADED PROTO commits and dispatches post-restore
    //       (anchor proto id >= the static tree's proto_count) — the doc-19 unlock
    //       working across a snapshot boundary, not just in a fresh VM.
    const gpa = testing.allocator;
    const source =
        \\local f = load([[
        \\  local t = { victim = 1 }
        \\  local s = 0
        \\  for i = 1, 400 do s = s + t.victim end
        \\  return s
        \\]])
        \\local warm = f()
        \\local total = 0
        \\for r = 1, 40 do total = total + f() end
        \\print(warm + total)
    ;
    const ref = try referenceRun(gpa, source);
    defer ref.deinit(gpa);

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    // Cut mid-way: after the chunk is loaded and warm, inside the repeat loop.
    vm.setSuspendCtl(.{ .min_depth = 1, .after_safepoints = ref.total_safepoints / 4 });
    try testing.expect((try vm.start(chunk.proto)) == .suspended);
    const out_before = try gpa.dupe(u8, sink.buffered());
    defer gpa.free(out_before);
    const mid = try encodeSnapshot(gpa, &vm);
    defer gpa.free(mid);

    const vm_r = try restore(gpa, mid, chunk.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    try testing.expect(vm_r.loaded_chunks.items.len >= 1);

    const native = @import("nativegen.zig").is_x64_linux;
    vm_r.trace.config.enabled = true;
    vm_r.trace.config.execute = true;
    vm_r.trace.config.optimize = true;
    vm_r.trace.config.native_codegen = native;
    vm_r.trace.config.hotloop = 4;

    var buf_r: [64]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.setSuspendCtl(null);
    try testing.expect((try vm_r.exec()) == .finished);

    // (a) output equivalence vs the uninterrupted tier-0 reference.
    var combined: [128]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.full_out, combined[0 .. out_before.len + sink_r.buffered().len]);

    // (b) a committed trace anchored in the LOADED tree (static ids are
    // [0, chunk.proto_count); loaded protos sit above) that actually ran.
    try testing.expect(vm_r.trace.entries > 0);
    var saw_loaded_anchor = false;
    for (vm_r.trace.registry.cache.items) |t| {
        if (t.code.anchor.proto.id >= chunk.proto_count) saw_loaded_anchor = true;
    }
    try testing.expect(saw_loaded_anchor);
}

test "metatable edge to the id-0 object survives round-trip (1-based encoding)" {
    // Regression: `metatable_id` is a 1-based optional id (`header.id + 1`, 0 =
    // none), NOT a bare id with 0 = none. Id 0 IS a live object — the first heap
    // allocation (`globals`) gets it — so the bare-id encoding would serialize a
    // metatable pointing at the id-0 object as `0` and restore would drop the edge.
    // Crucially, byte-identity round-trip CANNOT catch this (encode writes 0, the
    // restored table has no metatable, re-encode writes 0 → b0==b1 holds while the
    // edge silently vanished). The only sound check is to assert the restored
    // pointer directly.
    const gpa = testing.allocator;
    const source = "g = {}";

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    // `globals` is the first allocation, so it holds id 0 — the value that the old
    // bare-id encoding overloaded as the "none" sentinel.
    try testing.expectEqual(@as(u32, 0), vm.globals.header.id);

    // Point g's metatable at the id-0 object (globals). Reachable only via the
    // metatable edge from g's perspective, so a dropped edge is observable.
    const g_val0 = vm.globals.get(try vm.heap.internValue("g"));
    try testing.expect(g_val0.isHeap() and g_val0.heapType() == .table);
    table.Table.fromHeader(g_val0.asHeap()).metatable = vm.globals;

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // The edge must come back pointing at the restored id-0 object — not null.
    const g_val = vm2.globals.get(try vm2.heap.internValue("g"));
    try testing.expect(g_val.isHeap() and g_val.heapType() == .table);
    const g_mt = table.Table.fromHeader(g_val.asHeap()).metatable;
    try testing.expect(g_mt != null);
    try testing.expectEqual(@as(u32, 0), g_mt.?.header.id);
    try testing.expect(g_mt.? == vm2.globals);

    // And re-capture is byte-identical (the 1-based id survives both directions).
    const b1 = try encodeSnapshot(gpa, vm2);
    defer gpa.free(b1);
    try testing.expectEqualSlices(u8, b0, b1);
}

test "restore preserves a multi-result native's projection and multi fn" {
    // A multi-return native (`math.modf`) serializes by name only (`HeapNative`),
    // so the restore path must reattach BOTH its single-result `func` projection
    // and its `multi` fn from the registry entry — otherwise a snapshot taken
    // mid-program would come back single-return and `local i, f = math.modf(x)`
    // would silently lose its second result after replay.
    const gpa = testing.allocator;
    const source = "m = math.modf"; // make the native reachable from a global

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    const b0 = try encodeSnapshot(gpa, &vm);
    defer gpa.free(b0);

    const vm2 = try restore(gpa, b0, chunk.proto, NativeRegistry.base());
    defer {
        vm2.deinit();
        gpa.destroy(vm2);
    }

    // Walk both routes to the restored native: the direct global `m`, and the
    // `math` table's `modf` field — both must resolve to a `math.modf` native.
    const via_global = vm2.globals.get(try vm2.heap.internValue("m"));
    const math_tbl_val = vm2.globals.get(try vm2.heap.internValue("math"));
    try testing.expect(math_tbl_val.isHeap() and math_tbl_val.heapType() == .table);
    const via_field = table.Table.fromHeader(math_tbl_val.asHeap()).get(try vm2.heap.internValue("modf"));

    for ([_]Value{ via_global, via_field }) |nv| {
        try testing.expect(nv.isHeap() and nv.heapType() == .native);
        const n = function.Native.fromHeader(nv.asHeap());
        try testing.expectEqualStrings("math.modf", n.name);
        try testing.expect(n.effect == null); // modf is pure, not an effect native
        try testing.expect(n.multi != null); // …and its multi projection survived

        // The single-result projection still yields the integral part…
        const ip = try n.func(undefined, &.{Value.float(3.5)});
        try testing.expect(ip.isFloat() and ip.asFloat() == 3.0);

        // …and the multi fn still writes both integral + fractional parts.
        var out: [2]Value = .{ Value.nil(), Value.nil() };
        const produced = try n.multi.?(undefined, &.{Value.float(3.5)}, &out);
        try testing.expectEqual(@as(usize, 2), produced);
        try testing.expect(out[0].asFloat() == 3.0);
        try testing.expect(out[1].asFloat() == 0.5);
    }
}

test "restore the hand-built edge corpus (cycles, open+closed upvalues, frames)" {
    const gpa = testing.allocator;

    // A stub proto tree carrying the ids the corpus closures reference (1 and 42),
    // so `findProto` resolves them. Restore borrows these `*const Proto`s.
    var p1 = Proto{ .code = &.{}, .name = "p1", .id = 1 };
    var p42 = Proto{ .code = &.{}, .name = "p42", .id = 42 };
    var rootp = Proto{ .code = &.{}, .name = "root", .id = 0, .protos = &.{ &p1, &p42 } };

    const file: schema.SnapshotFile = .{
        .version = snapshot_format_version,
        .keyframe = .{
            .globals_id = 2,
            .string_metatable_id = 0,
            .next_obj_id = 8,
            .objects = &.{
                .{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a\x00b\xff\xfe" } } },
                .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "" } } },
                .{
                    .id = 2,
                    .obj_type = 1,
                    .body = .{
                        .HeapTable = .{
                            .array = &.{ sInt(10), sFloat(2.5), sBool(true) },
                            .entries = &.{
                                .{ .key = sRef(0), .val = sRef(3) },
                                .{ .key = sInt(7), .val = sRef(2) }, // self-ref
                            },
                            .metatable_id = 0,
                        },
                    },
                },
                .{ .id = 3, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 42, .upvalue_ids = &.{ 4, 5 } } } },
                .{ .id = 6, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 1, .upvalue_ids = &.{} } } },
                .{ .id = 4, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 1, .value = sInt(99) } } },
                .{ .id = 5, .obj_type = 4, .body = .{ .HeapUpvalue = .{ .closed = 0, .value = sRef(2) } } },
                .{ .id = 7, .obj_type = 3, .body = .{ .HeapNative = .{ .name = "print" } } },
            },
            .stack = &.{ sRef(2), sInt(-1) },
            // Both stub protos have num_registers == 0, so contiguity wants base 0
            // for both frames (this corpus exercises structural restore, not resume).
            .frames = &.{
                .{ .closure_id = 3, .pc = 0, .base = 0, .ret_dest = 0, .ret_count = 0, .varargs_base = 0, .varargs_count = 0 },
                .{ .closure_id = 6, .pc = 0, .base = 0, .ret_dest = 0, .ret_count = 0, .varargs_base = 0, .varargs_count = 0 },
            },
            .open_upvalues = &.{.{ .stack_index = 0, .upvalue_id = 5 }},
            .loaded_chunks = &.{},
        },
    };

    const vm = try restoreSnapshot(gpa, file, &rootp, NativeRegistry.base());
    defer {
        vm.deinit();
        gpa.destroy(vm);
    }

    // 8 objects restored with their exact ids; counter parked past id 7.
    try testing.expectEqual(@as(usize, 8), vm.heap.object_count);
    try testing.expectEqual(@as(u32, 8), vm.heap.next_obj_id);

    // globals is the table id 2; its self-ref entry (key 7) points back at it.
    try testing.expectEqual(@as(u32, 2), vm.globals.header.id);
    const self_ref = vm.globals.get(Value.int(7));
    try testing.expect(self_ref.isHeap() and self_ref.asHeap() == &vm.globals.header);
    // Array part round-tripped (v7 positional 0-based: key 0 == 10,
    // key 1 == 2.5, key 2 == true).
    try testing.expectEqual(@as(i64, 10), vm.globals.get(Value.int(0)).asInt());
    try testing.expectEqual(@as(f64, 2.5), vm.globals.get(Value.int(1)).asFloat());

    // Frames rebound (depth 2; frame 0 = closure 3, frame 1 = closure 6, which
    // has zero upvalues — exercising both the N- and 0-upvalue closure shapes).
    try testing.expectEqual(@as(u32, 2), vm.depth);
    try testing.expectEqual(@as(u32, 3), vm.frames[0].closure.header.id);
    try testing.expectEqual(@as(u32, 6), vm.frames[1].closure.header.id);
    try testing.expectEqual(@as(usize, 2), vm.frames[0].closure.upvalues.len);
    try testing.expectEqual(@as(usize, 0), vm.frames[1].closure.upvalues.len);
    // The two-upvalue closure's closed cell (id 4) holds 99.
    try testing.expectEqual(@as(i64, 99), vm.upvalGet(vm.frames[0].closure.upvalues[0]).asInt());

    // Closed upvalue id 4 holds 99; open upvalue id 5 was rebound over stack[0]
    // and therefore reads the table ref now living there.
    try testing.expectEqual(@as(usize, 1), vm.open_upvalues.items.len);
    // Doc 54 P1: restore republishes the ceiling through the centralized
    // append (stack_index 0 ⇒ ceiling 1).
    try testing.expectEqual(@as(usize, 1), vm.open_upvalue_ceiling);
    const open_cell = vm.open_upvalues.items[0].cell;
    try testing.expectEqual(@as(u32, 5), open_cell.header.id);
    try testing.expectEqual(@as(usize, 0), open_cell.loc.open);
    try testing.expect(vm.upvalGet(open_cell).isHeap() and vm.upvalGet(open_cell).asHeap() == &vm.globals.header);

    // Stack window restored.
    try testing.expectEqual(@as(usize, 2), vm.stack_top);
    try testing.expectEqual(@as(i64, -1), vm.regGet(1).asInt());
}

test "v7 validation: an array-covered hash key (int or float-spelled) is rejected" {
    var rootp = Proto{ .code = &.{}, .name = "root", .id = 0 };

    // Integer key 0 while the array covers slots 0..1 → shadowed → reject.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 1,
        .objects = &.{.{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{ sInt(10), sInt(11) },
            .entries = &.{.{ .key = sInt(0), .val = sInt(99) }},
            .metatable_id = 0,
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.ArrayResidentKeyInHash);

    // Float-spelled 0.0 normalizes to integer 0 → same rejection.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 1,
        .objects = &.{.{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{sInt(10)},
            .entries = &.{.{ .key = sFloat(0.0), .val = sInt(99) }},
            .metatable_id = 0,
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.ArrayResidentKeyInHash);

    // A key just past the extent (== asize) is a legitimate hash resident.
    {
        const gpa = testing.allocator;
        const vm = try restoreSnapshot(gpa, .{ .version = snapshot_format_version, .keyframe = .{
            .globals_id = 0,
            .string_metatable_id = 0,
            .next_obj_id = 1,
            .objects = &.{.{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
                .array = &.{sInt(10)},
                .entries = &.{.{ .key = sInt(1), .val = sInt(99) }},
                .metatable_id = 0,
            } } }},
            .stack = &.{},
            .frames = &.{},
            .open_upvalues = &.{},
            .loaded_chunks = &.{},
        } }, &rootp, NativeRegistry.base());
        defer {
            vm.deinit();
            gpa.destroy(vm);
        }
        try testing.expectEqual(@as(i64, 10), vm.globals.get(Value.int(0)).asInt());
        try testing.expectEqual(@as(i64, 99), vm.globals.get(Value.int(1)).asInt());
        try testing.expectEqual(@as(usize, 1), vm.globals.hash.count()); // split preserved
    }
}

test "restore: bulk lane rebuild — a slot-0-hole narrow run repacks + freezes; heap-bearing stays .value" {
    const gpa = testing.allocator;
    var rootp = Proto{ .code = &.{}, .name = "root", .id = 0 };

    // [nil, true, false, true]: a leading hole would defeat append's eager
    // commit, so without the bulk rebuild this stays `.value` — untraceable.
    {
        const vm = try restoreSnapshot(gpa, .{ .version = snapshot_format_version, .keyframe = .{
            .globals_id = 0,
            .string_metatable_id = 0,
            .next_obj_id = 1,
            .objects = &.{.{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
                .array = &.{ sNil(), sBool(true), sBool(false), sBool(true) },
                .entries = &.{},
                .metatable_id = 0,
            } } }},
            .stack = &.{},
            .frames = &.{},
            .open_upvalues = &.{},
            .loaded_chunks = &.{},
        } }, &rootp, NativeRegistry.base());
        defer {
            vm.deinit();
            gpa.destroy(vm);
        }
        const arrp = &vm.globals.array;
        try testing.expectEqual(@import("array.zig").Lane.boolean, arrp.lane);
        try testing.expect(arrp.frozen); // monotonic from here (widen-only)
        try testing.expect(arrp.get(0).isNil()); // the hole survived the repack
        try testing.expectEqual(true, arrp.get(1).asBool());
        try testing.expectEqual(false, arrp.get(2).asBool());
    }
    // A heap-bearing array must stay `.value` and unfrozen (a later rehash may
    // still narrow if the contents settle).
    {
        const vm = try restoreSnapshot(gpa, .{ .version = snapshot_format_version, .keyframe = .{
            .globals_id = 0,
            .string_metatable_id = 0,
            .next_obj_id = 2,
            .objects = &.{
                .{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
                    .array = &.{ sNil(), sRef(1) },
                    .entries = &.{},
                    .metatable_id = 0,
                } } },
                .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "s" } } },
            },
            .stack = &.{},
            .frames = &.{},
            .open_upvalues = &.{},
            .loaded_chunks = &.{},
        } }, &rootp, NativeRegistry.base());
        defer {
            vm.deinit();
            gpa.destroy(vm);
        }
        try testing.expectEqual(@import("array.zig").Lane.value, vm.globals.array.lane);
        try testing.expect(!vm.globals.array.frozen);
    }
}

test "restore surfaces specific errors for malformed snapshots" {
    var rootp = Proto{ .code = &.{}, .name = "root", .id = 0 };

    // A dangling HeapRef in a table value.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 1,
        .objects = &.{.{ .id = 0, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{},
            .entries = &.{.{ .key = sInt(1), .val = sRef(77) }},
            .metatable_id = 0,
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnresolvedHeapRef);

    // A closure naming a proto id the program image does not contain.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 1,
        .objects = &.{.{ .id = 0, .obj_type = 2, .body = .{ .HeapClosure = .{ .proto_id = 99, .upvalue_ids = &.{} } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnknownProto);

    // A native whose name is not in the registry.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 1,
        .objects = &.{.{ .id = 0, .obj_type = 3, .body = .{ .HeapNative = .{ .name = "nope" } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnknownNative);

    // globals_id resolves to a string, not a table.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 1,
        .objects = &.{.{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "x" } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.GlobalsNotATable);

    // Two objects sharing an id.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 5,
        .string_metatable_id = 0,
        .next_obj_id = 6,
        .objects = &.{
            .{ .id = 5, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "a" } } },
            .{ .id = 5, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "b" } } },
        },
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.DuplicateId);

    // A wrong-version file is rejected outright.
    try expectRestoreError(.{ .version = snapshot_format_version + 1, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 1,
        .objects = &.{},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.UnsupportedVersion);

    // L-2: two HeapStrings carrying identical bytes under distinct ids. A valid
    // snapshot interns one String per byte-sequence, so this is corrupt — restore
    // must reject it rather than overwrite the interning map and leave both linked.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = 2,
        .objects = &.{
            .{ .id = 0, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "dup" } } },
            .{ .id = 1, .obj_type = 0, .body = .{ .HeapString = .{ .bytes = "dup" } } },
        },
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.DuplicateInternedString);

    // L-2: the restored id space is exhausted (an object names the top *genuine*
    // id — the reserved high half is for phantom grid rows, doc 14 Phase 7) AND the
    // snapshot carries a loaded chunk to recompile — recompiling would allocate
    // fresh interned strings that wrap the counter into the restored range. Reject.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 0,
        .string_metatable_id = 0,
        .next_obj_id = gc.reserved_grid_id_base,
        .objects = &.{.{ .id = gc.reserved_grid_id_base - 1, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{},
            .entries = &.{},
            .metatable_id = 0,
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{.{ .source = "return 1", .name = "(load)" }},
    } }, &rootp, error.IdSpaceExhausted);

    // H-2 (v5): `next_obj_id` at/below a restored id is corrupt — a live object
    // cannot hold an id the counter has not handed out yet. Here object id 5 sits
    // above `next_obj_id == 3`, so restore must reject rather than mint a counter
    // that would re-issue id 5 to a fresh allocation.
    try expectRestoreError(.{ .version = snapshot_format_version, .keyframe = .{
        .globals_id = 5,
        .string_metatable_id = 0,
        .next_obj_id = 3,
        .objects = &.{.{ .id = 5, .obj_type = 1, .body = .{ .HeapTable = .{
            .array = &.{},
            .entries = &.{},
            .metatable_id = 0,
        } } }},
        .stack = &.{},
        .frames = &.{},
        .open_upvalues = &.{},
        .loaded_chunks = &.{},
    } }, &rootp, error.NextObjIdBelowObjects);
}

test "doc 32: a heterogeneous `.value` array survives round-trip and still records post-restore" {
    // Doc 32's snapshot constraint, pinned. `keyframeser.zig` repacks a
    // `.value` array back down to a narrow lane on restore when its elements
    // are homogeneous, so a test that seeded an all-int array would silently
    // stop testing `.value` the moment it crossed the boundary. `a` is
    // deliberately HETEROGENEOUS (199 ints and one float), which is exactly
    // the case the repack must decline — so the restored VM really is reading
    // a `.value` lane.
    //
    // Pins (a) resumed output == uninterrupted tier-0 output, and (b) the
    // restored VM commits a trace at all. (b) matters because restore builds a
    // fresh VM with an empty trace cache: nothing carries over, so the loop
    // has to re-record from scratch against the restored array. If `.value`
    // scalar reads regressed to `.nyi_opcode`, (a) would still pass and only
    // (b) would catch it.
    const gpa = testing.allocator;
    const source =
        \\local a = {}
        \\for i = 1, 200 do a[i] = i end
        \\a[7] = 0.5
        \\local s = 0.0
        \\for r = 1, 40 do
        \\  for i = 1, 200 do s = s + a[i] end
        \\end
        \\print(s)
    ;
    const ref = try referenceRun(gpa, source);
    defer ref.deinit(gpa);

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    // Cut a quarter of the way in: the array is fully built and already
    // erased to `.value`, and the accumulation loop is mid-flight.
    vm.setSuspendCtl(.{ .min_depth = 0, .after_safepoints = ref.total_safepoints / 4 });
    try testing.expect((try vm.start(chunk.proto)) == .suspended);
    const out_before = try gpa.dupe(u8, sink.buffered());
    defer gpa.free(out_before);
    const mid = try encodeSnapshot(gpa, &vm);
    defer gpa.free(mid);

    const vm_r = try restore(gpa, mid, chunk.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }

    const native = @import("nativegen.zig").is_x64_linux;
    vm_r.trace.config.enabled = true;
    vm_r.trace.config.execute = true;
    vm_r.trace.config.optimize = true;
    vm_r.trace.config.native_codegen = native;
    vm_r.trace.config.hotloop = 4;

    var buf_r: [64]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.setSuspendCtl(null);
    try testing.expect((try vm_r.exec()) == .finished);

    var combined: [128]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.full_out, combined[0 .. out_before.len + sink_r.buffered().len]);

    try testing.expect(vm_r.trace.entries > 0);
}
