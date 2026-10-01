//! Doc 56 Phase 4: native exit adapter tests.
//!
//! The end-to-end parity legs live in `interp_exit_side_test.zig`. These
//! pin the builder itself on a real compiled trace: a rebuild reproduces the
//! published adapter, each refusal reason fires on the map shape that should
//! cause it, allocation failure is clean, and with the switch off a native
//! page carries no exit-side machinery at all.

const std = @import("std");
const testing = std.testing;
const interp = @import("interp.zig");
const nativegen = @import("nativegen.zig");
const util = @import("interp_testutil.zig");

const Vm = interp.Vm;
const TraceMode = util.TraceMode;
const adapter = nativegen.adapter;
const ExitLoc = nativegen.ExitLoc;
const ExitLocMap = nativegen.ExitLocMap;
const McodeArena = nativegen.McodeArena;
const TraceCode = @import("trace_code.zig").TraceCode;
const trace_mod = @import("trace.zig");

/// The Phase 3 sunk-store shape: its `i % 3` exit's adapter applies an
/// `astore` (whose constant index the store emitter encodes inline),
/// flushes two carried homes and restores snapshot slots.
const sunk_store_src =
    \\local t = {0.5}
    \\local s = 0
    \\for i = 1, 300 do
    \\  t[1] = t[1] + i
    \\  if i % 3 == 0 then s = s + t[1] else s = s - 1 end
    \\end
    \\print(s, t[1])
;
const sunk_store_out = "1530000\t45150.5\n";

/// Sunk hash stores, one storing the constant 7: the adapter stages that
/// constant into a spill word above the frame.
const konst_store_src =
    \\local t = {x = 0.5, y = 0}
    \\local s = 0
    \\for i = 1, 300 do
    \\  t.x = t.x + i
    \\  t.y = 7
    \\  if i % 3 == 0 then s = s + t.x + t.y else s = s - 1 end
    \\end
    \\print(s, t.x, t.y)
;
const konst_store_out = "1530700\t45150.5\t7\n";

/// Run `src` on the native leg (it must print `out`) and hand `check` the
/// first trace that published an adapter.
fn withAdapter(
    comptime src: [:0]const u8,
    comptime out: []const u8,
    comptime check: fn (vm: *Vm, t: *const TraceCode, id: u32, ct: *nativegen.CompiledTrace, gi: u32) anyerror!void,
) !void {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            std.debug.assert(mode == .record_execute_native);
            for (vm.trace.registry.cache.items) |t| switch (t.native) {
                .compiled => |*ct| {
                    if (ct.exit_adapters.items.len == 0) continue;
                    return check(vm, &t.code, t.id, ct, ct.exit_adapters.items[0].exit);
                },
                .unattempted, .unsupported => {},
            };
            return error.NoAdapterBuilt;
        }
    };
    var buf: [64]u8 = undefined;
    var sink = @import("io.zig").Writer.fixed(&buf);
    try util.runCapturedTuned(testing.allocator, src, &sink, false, .record_execute_native, .{ .exit_side_native = true, .inspect = Inspect.run });
    try testing.expectEqualStrings(out, sink.buffered());
}

fn expectRefused(want: adapter.Refusal, built: adapter.Built) !void {
    switch (built) {
        .adapter => |ad| {
            var owned = ad;
            owned.deinit();
            return error.TestExpectedRefusal;
        },
        .refused => |r| try testing.expectEqual(want, r.why),
    }
}

/// A heap copy of `map` the caller may edit (freed with `deinit`).
fn copyMap(map: *const ExitLocMap) !ExitLocMap {
    const gpa = testing.allocator;
    const values = try gpa.dupe(ExitLoc, map.values);
    errdefer gpa.free(values);
    const carried: []nativegen.CarriedHome = if (map.carried.len == 0) &.{} else try gpa.dupe(nativegen.CarriedHome, map.carried);
    return .{ .values = values, .carried = carried, .frame_words = map.frame_words };
}

test "doc 56 Phase 4 adapter: a rebuild from the stored map reproduces the published adapter" {
    const Check = struct {
        fn run(vm: *Vm, t: *const TraceCode, id: u32, ct: *nativegen.CompiledTrace, gi: u32) !void {
            const published = ct.exitAdapter(gi).?;
            const cell = ct.exitSideSlot(gi).?;
            const built = try adapter.build(testing.allocator, &vm.trace.registry.mcode_arena, t, id, &ct.exit_locs, gi, &ct.slots[cell], &ct.exit_side_metadata_cells[gi]);
            switch (built) {
                .refused => return error.RebuildRefused,
                .adapter => |ad| {
                    var owned = ad;
                    defer owned.deinit();
                    // Same instruction sequence (imm64 addresses aside).
                    try testing.expectEqual(published.page.code.len, owned.page.code.len);
                    try testing.expectEqual(gi, owned.exit);
                    // Phase 5: the exit-side cell lives past the ordinary and
                    // transition cells. It holds the trampoline exit, or —
                    // once an `.exit_side` arm is published (this program
                    // arms it) — exactly that arm's child entry.
                    try testing.expectEqual(ct.exit_side_cells.len + nativegen.NATIVE_TRANSITION_SLOTS + gi, cell);
                    var armed: ?*const trace_mod.Trace = null;
                    for (vm.trace.registry.native_physical.armedLinks()) |l| {
                        if (l.kind == .exit_side and l.parent.id == id and l.slot_index == gi) armed = l.child;
                    }
                    const want = if (armed) |ch| ch.native.compiled.ordinary_entry.? else vm.trace.registry.mcode_arena.trampoline_exit.?;
                    try testing.expectEqual(want, ct.slots[cell]);
                    try testing.expect(armed != null);
                },
            }
        }
    };
    try withAdapter(sunk_store_src, sunk_store_out, Check.run);
}

test "doc 56 Phase 4 adapter: every refusal reason fires on the map shape that causes it" {
    const Check = struct {
        fn run(vm: *Vm, t: *const TraceCode, id: u32, ct: *nativegen.CompiledTrace, gi: u32) !void {
            const gpa = testing.allocator;
            const arena = &vm.trace.registry.mcode_arena;
            const target = &ct.slots[ct.exitSideSlot(gi).?];

            // no_map: an empty map (a precise/peeled/snapshot-less trace's).
            try expectRefused(.no_map, try adapter.build(gpa, arena, t, id, &ExitLocMap{}, gi, target, null));

            // no_stub: publishing an exit the page has no stub for.
            const past: u32 = @intCast(ct.exit_side_cells.len);
            try testing.expectEqual(adapter.Refusal.no_stub, (try adapter.publish(arena, t, id, ct, past)).?.why);

            // not_held: a store operand whose life ended before the exit.
            {
                var m = try copyMap(&ct.exit_locs);
                defer m.deinit(gpa);
                var dropped = false;
                for (m.values) |*r| {
                    if (r.tag == .konst or r.tag == .none) continue;
                    r.live_until = @intCast(gi - 1);
                    r.live_from = 0;
                    dropped = true;
                }
                try testing.expect(dropped);
                const built = try adapter.build(gpa, arena, t, id, &m, gi, target, null);
                try expectRefused(.not_held, built);
                try testing.expect(built.refused.ref != null);
            }

            // kind: a carried home no slot flush can box.
            {
                var m = try copyMap(&ct.exit_locs);
                defer m.deinit(gpa);
                try testing.expect(m.carried.len != 0);
                m.carried[0].kind = .boxed;
                try expectRefused(.kind, try adapter.build(gpa, arena, t, id, &m, gi, target, null));
            }

            // spill: no room above the frame for the staged constant 7.
            {
                var m = try copyMap(&ct.exit_locs);
                defer m.deinit(gpa);
                m.frame_words = nativegen.SPILL_MAX;
                try expectRefused(.spill, try adapter.build(gpa, arena, t, id, &m, gi, target, null));
            }
        }
    };
    try withAdapter(konst_store_src, konst_store_out, Check.run);
}

test "doc 56 Phase 4 adapter: allocation failure at any point is clean" {
    const Check = struct {
        fn buildOnce(gpa: std.mem.Allocator, arena: *McodeArena, t: *const TraceCode, id: u32, map: *const ExitLocMap, gi: u32, target: *const usize, cell: *usize) !void {
            switch (try adapter.build(gpa, arena, t, id, map, gi, target, cell)) {
                .adapter => |ad| {
                    var owned = ad;
                    owned.deinit();
                },
                .refused => return error.TestUnexpectedRefusal,
            }
        }
        fn run(vm: *Vm, t: *const TraceCode, id: u32, ct: *nativegen.CompiledTrace, gi: u32) !void {
            try testing.checkAllAllocationFailures(testing.allocator, buildOnce, .{ &vm.trace.registry.mcode_arena, t, id, &ct.exit_locs, gi, &ct.slots[ct.exitSideSlot(gi).?], &ct.exit_side_metadata_cells[gi] });
        }
    };
    try withAdapter(konst_store_src, konst_store_out, Check.run);
}

test "doc 56 Phase 4 adapter: with the switch off a native page carries no exit-side machinery" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            std.debug.assert(mode == .record_execute_native);
            var pages: usize = 0;
            var attachable: usize = 0;
            for (vm.trace.registry.cache.items) |t| switch (t.native) {
                .compiled => |*ct| {
                    pages += 1;
                    if (t.code.anyExitAttachable()) attachable += 1;
                    try testing.expectEqual(@as(usize, 0), ct.exit_side_cells.len);
                    try testing.expectEqual(@as(usize, 0), ct.exit_adapters.items.len);

                    // The production page has the feature-off layout. Pages
                    // embed heap cell addresses (imm64s), so two compiles
                    // never match byte for byte; the length pins the layout
                    // (the stubs and the widened lives add bytes).
                    const gpa = testing.allocator;
                    var arena = McodeArena.init(gpa);
                    defer arena.deinit();
                    var off = nativegen.compileIntoWith(gpa, &arena, &t.code, t.id, vm.trace.registry.native_seed_ctx, vm.trace.exec_heap, .{}) orelse return error.RecompileBailed;
                    defer off.deinit();
                    var on = nativegen.compileIntoWith(gpa, &arena, &t.code, t.id, vm.trace.registry.native_seed_ctx, vm.trace.exec_heap, .{ .exit_side = true }) orelse return error.RecompileBailed;
                    defer on.deinit();
                    try testing.expectEqual(off.page.code.len, ct.page.code.len);
                    try testing.expectEqual(@as(usize, 0), off.exit_side_cells.len);
                    // With the feature on, an attachable trace gets the stubs.
                    if (t.code.anyExitAttachable()) {
                        try testing.expect(on.exit_side_cells.len != 0);
                        try testing.expect(on.page.code.len > off.page.code.len);
                    }
                },
                .unattempted, .unsupported => {},
            };
            try testing.expect(pages > 0);
            try testing.expect(attachable > 0);
            try testing.expectEqual(@as(u64, 0), vm.trace.exit_adapter_builds);
            try testing.expectEqual(@as(u64, 0), vm.trace.exit_side_native_hops);
        }
    };
    var buf: [64]u8 = undefined;
    var sink = @import("io.zig").Writer.fixed(&buf);
    // The switch is on by default (doc 58 B2): this pins the ablation.
    try util.runCapturedTuned(testing.allocator, sunk_store_src, &sink, false, .record_execute_native, .{ .exit_side_native = false, .inspect = Inspect.run });
    try testing.expectEqualStrings(sunk_store_out, sink.buffered());
}
