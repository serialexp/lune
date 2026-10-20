//! Doc 64 (heavy-iteration loop nests): end-to-end shape tests.
//!
//! Step 1 of doc 64 §10 pins TODAY's behaviour on the nsieve-bit-fp kernel,
//! so each later step has a before/after. The assertions below state the
//! current (bad) reading on purpose; the step that changes it flips them.
//! Shared harness lives in `interp_testutil.zig`.

const std = @import("std");
const interp = @import("interp.zig");
const testing = std.testing;
const trace = @import("trace.zig");
const io = @import("io.zig");

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

test "doc 64 step 1: the `for k` region closes when its loop ends and region decay gates its owner" {
    // Doc 64 §11's finding. The `for k` loop's cross-trace cycle is a region
    // owned by its header. Each activation is one whole `for k` loop, and it
    // closes when tier-0 reaches the code after the loop (a `departure`
    // close): the loop finished. For every prime above m/8 the loop has
    // fewer than `min_useful` steps, so the activation never fills a window
    // and the close strikes the owner. Once the penalty saturates, every
    // further strike gates the owner again and runs `disarmAllLinks`; the
    // gate reaches `max_strikes` early and the anchor stays gated for the
    // rest of the run.
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
            const g = ts.gate.get(.{ .proto = proto, .pc = k_header, .proto_id = proto.id }) orelse
                return error.TestUnexpectedResult;
            try testing.expect(g.strikes >= ts.config.max_strikes); // gated for good
            try testing.expect(ts.dispatch_gates.get(.region_decay) >= 500);
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
