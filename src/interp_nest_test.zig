//! Doc 64 (heavy-iteration loop nests): end-to-end shape tests.
//!
//! Step 1 of doc 64 §10 pinned the behaviour on the nsieve-bit-fp kernel,
//! so each later step has a before/after: the assertions state the current
//! reading, and the step that changes it flips them (step 2 flipped the
//! gate).
//! Shared harness lives in `interp_testutil.zig`.

const std = @import("std");
const interp = @import("interp.zig");
const testing = std.testing;
const trace = @import("trace.zig");
const io = @import("io.zig");
const bytecode = @import("bytecode.zig");

const Vm = interp.Vm;
const util = @import("interp_testutil.zig");
const TraceMode = util.TraceMode;

/// The nsieve-bit-fp kernel (vendored LuaJIT `bench/nsieve-bit-fp.lua`) at
/// the board's smallest size, m = 160000, in the main chunk. Smaller m does
/// NOT reproduce the gate: at m <= 80000 the `for k` region still strikes
/// windows but its owner never reaches `max_penalty` (doc 64 §11).
const nsieve_bit_fp_src =
    \\local floor, ceil = math.floor, math.ceil
    \\local m = 160000
    \\local p = {}
    \\local cm = ceil(m/50)
    \\for i=0,cm do p[i] = 2^50-1 end
    \\local count, idx, bit = 0, 2, 2
    \\for i=2,m do
    \\  local r = p[idx] / bit
    \\  if r - floor(r) >= 0.5 then
    \\    local kidx, kbit = idx, bit
    \\    for k=i+i,m,i do
    \\      kidx = kidx + i
    \\      while kidx >= cm do kidx = kidx - cm; kbit = kbit + kbit end
    \\      local x = p[kidx]
    \\      local r = x / kbit
    \\      if r - floor(r) >= 0.5 then p[kidx] = x - kbit*0.5 end
    \\    end
    \\    count = count + 1
    \\  end
    \\  idx = idx + 1
    \\  if idx >= cm then idx = 0; bit = bit + bit end
    \\end
    \\print(count)
;

test "doc 64 steps 1-2: the `for k` region closes when its loop ends, and since step 2 its owner is never gated" {
    // Doc 64 §11's finding. The `for k` loop's cross-trace cycle is a region
    // owned by its header. Each activation is one whole `for k` loop, and it
    // closes when tier-0 reaches the code after the loop (a `departure`
    // close): the loop finished. Before step 2, the `while` exit's chains
    // that ended at the `for k` loop-done guard counted as misses, the exit
    // gave up and lost its arm, the activations stopped filling a window,
    // and region decay gated the owner for good (754 gates, `max_strikes`
    // reached early). Step 2 (doc 64 §12) makes those chains natural stops;
    // the exit stays attached and the owner is never struck.
    //
    // This is the production machine: no coverage, so entry patches are on
    // (`--jit-stats` runs the unpatched machine, doc 20 §R1-9, and does not
    // show these gates). Counts are deterministic, so the thresholds are
    // real, not timing.
    const gpa = testing.allocator;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            _ = mode;
            const ts = &vm.trace;
            // The `for k` header: the one numeric `for` whose body sits
            // inside another numeric `for`'s body.
            if (ts.registry.cache.items.len == 0) return error.TestUnexpectedResult;
            const proto = ts.registry.cache.items[0].code.anchor.proto; // the main chunk: no functions
            var ranges: [8][2]u32 = undefined;
            var n: usize = 0;
            for (proto.code, 0..) |ins, pc| if (ins.op == .for_loop) {
                const header: u32 = @intCast(@as(i64, @intCast(pc)) + 1 + ins.aux);
                ranges[n] = .{ header, @intCast(pc) };
                n += 1;
            };
            var inner: ?u32 = null;
            for (ranges[0..n], 0..) |r, a| for (ranges[0..n], 0..) |o, b| {
                if (a != b and o[0] < r[0] and r[1] < o[1]) inner = r[0];
            };
            const k_header = inner orelse return error.TestUnexpectedResult;
            if (ts.gate.get(.{ .proto = proto, .pc = k_header, .proto_id = proto.id })) |g|
                try testing.expectEqual(@as(@TypeOf(g.strikes), 0), g.strikes);
            try testing.expect(ts.dispatch_gates.get(.region_decay) <= 1);
            try testing.expectEqual(@as(u64, 0), ts.dispatch_gates.get(.legacy_thrash));
            // Region activations end because a loop finished, not because a
            // receipt left the region.
            const closes = ts.region_closes;
            try testing.expect(closes.get(.departure) >= 5000);
            try testing.expect(closes.get(.departure) > 4 * closes.get(.source_outside));
        }
    };
    try util.runCapturedTuned(gpa, nsieve_bit_fp_src, &sink, false, .record_execute_native, .{
        .hotloop = (trace.TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
    try testing.expectEqualStrings("14683\n", sink.buffered());
}

test "doc 64 step 2: an exit-side chain that ends by leaving its enclosing loop is a natural stop, not a misfit" {
    // Doc 64 §12. The `while`'s exit resumes at `P` in the `for k` body; the
    // continuation there runs to the `for k` loop-done guard whenever the
    // loop finishes — for most primes, within a few steps. Before step 2
    // each of those chains counted as a miss, and after `tryside` of them
    // the exit gave up for good. Now they are natural stops: neutral.
    const gpa = testing.allocator;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            _ = mode;
            try testing.expect(vm.trace.exit_side_natural_stops >= 500);
        }
    };
    try util.runCapturedTuned(gpa, nsieve_bit_fp_src, &sink, false, .record_execute_native, .{
        .hotloop = (trace.TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
    try testing.expectEqualStrings("14683\n", sink.buffered());
}

test "doc 64 step 3: a loop root committed behind a marker takes over the exit a composite served" {
    // Doc 64 §13. The `while` needs 0 trips at first, so the `for` root is
    // recorded without it; its `while` exit resumes at the `.loop` marker.
    // When trips start, that exit binds to a composite continuation at the
    // marker (one trip, then `.link`). Only later does the `while` get a
    // root of its own. Its commit releases the composite's arm, the next
    // firing routes, finds the root first, and arms the exit straight into
    // it: the exit's bound entry and the armed child are the root.
    const gpa = testing.allocator;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            _ = mode;
            const ts = &vm.trace;
            try testing.expect(ts.exit_side_root_retargets >= 1);
            try testing.expect(ts.exit_side_root_routes >= 1);
            var root_arms: usize = 0;
            for (ts.registry.native_physical.armedLinks()) |l| {
                if (l.kind != .exit_side) continue;
                const n = l.child.code.instrs.len;
                if (l.child.code.instrs[n - 1].op != .loop) continue;
                const h = l.child.code.anchor.pc;
                // The root sits behind a marker, and the topology follows it.
                try testing.expectEqual(bytecode.OpCode.loop, l.child.code.anchor.proto.code[h - 1].op);
                try testing.expectEqual(h, l.parent.exit_side_entry[l.slot_index]);
                root_arms += 1;
            }
            try testing.expect(root_arms >= 1);
        }
    };
    try util.runCapturedTuned(gpa,
        \\local s = 0
        \\for i = 1, 40000 do
        \\  local j = i
        \\  while j >= 4000 do j = j - 4000 end
        \\  s = s + j
        \\end
        \\print(s)
    , &sink, false, .record_execute_native, .{
        .hotloop = (trace.TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
    try testing.expectEqualStrings("79980000\n", sink.buffered());
}

test "doc 64 step 2: natural stops never give an exit up; misfits do, and the next .link commit at P revives it" {
    // White-box: take a real attached exit and the `.link` continuation at
    // its resume point, then drive the outcome accounting directly.
    const gpa = testing.allocator;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            _ = mode;
            const ts = &vm.trace;
            const Found = struct { parent: *trace.Trace, exit: u32, child: *trace.Trace };
            const found: Found = blk: for (ts.registry.cache.items) |parent| {
                for (parent.exit_side, 0..) |s, e| {
                    if (s != .attached) continue;
                    const p = parent.code.exitResumePc(@intCast(e)) orelse continue;
                    for (ts.registry.cache.items) |c| {
                        const n = c.code.instrs.len;
                        if (c.code.anchor.proto != parent.code.anchor.proto or c.code.anchor.pc != p) continue;
                        if (n == 0 or c.code.instrs[n - 1].op != .link) continue;
                        break :blk .{ .parent = parent, .exit = @intCast(e), .child = c };
                    }
                }
            } else return error.TestUnexpectedResult;
            const parent = found.parent;
            const e = found.exit;
            const tryside = ts.config.tryside;

            // Natural stops are neutral, however many.
            const stops0 = ts.exit_side_natural_stops;
            for (0..2 * @as(usize, tryside)) |_| ts.noteExitSideChain(parent, e, .natural_stop);
            try testing.expect(parent.exitSideAt(e) == .attached);
            try testing.expectEqual(stops0 + 2 * @as(u64, tryside), ts.exit_side_natural_stops);

            // `tryside` misfits give it up and file it under `P`.
            const waiting0 = ts.exit_side_waiting.items.len;
            for (0..tryside) |_| ts.noteExitSideChain(parent, e, .misfit);
            try testing.expect(parent.exitSideAt(e) == .gave_up);
            try testing.expectEqual(waiting0 + 1, ts.exit_side_waiting.items.len);

            // A `.link` commit at `P` revives it, once: the entry is consumed.
            const revivals0 = ts.exit_side_revivals;
            ts.reviveExitSideAt(found.child);
            try testing.expect(parent.exitSideAt(e) == .none);
            try testing.expectEqual(revivals0 + 1, ts.exit_side_revivals);
            try testing.expectEqual(waiting0, ts.exit_side_waiting.items.len);
            ts.reviveExitSideAt(found.child);
            try testing.expectEqual(revivals0 + 1, ts.exit_side_revivals);
        }
    };
    // Doc 64's `while` inside a `for`: the while's exit attaches to the
    // post-while continuation.
    try util.runCapturedTuned(gpa,
        \\local s = 0
        \\for i = 1, 3000 do
        \\  local j = i * 13
        \\  for k = 1, 2 do
        \\    while j >= 7 do j = j - 7 end
        \\    s = s + j
        \\    j = j + i
        \\  end
        \\end
        \\print(s)
    , &sink, false, .record_execute, .{ .inspect = Inspect.run });
    try testing.expectEqualStrings("9006\n", sink.buffered());
}
