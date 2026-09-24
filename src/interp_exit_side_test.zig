//! Doc 56 (exit-started side traces): end-to-end shape tests.
//!
//! Phase 0 pins TODAY's behaviour on the fft bit-reverse reduction, so each
//! later phase has a measured before/after. The residency assertion below
//! states the current (bad) reading on purpose; the phase that makes the
//! loop run as traces flips it to the doc 56 §9 target (≥ 90% traced).
//! Shared harness lives in `interp_testutil.zig`.

const std = @import("std");
const interp = @import("interp.zig");
const testing = std.testing;

const Vm = interp.Vm;

const util = @import("interp_testutil.zig");
const expectProgramTuned = util.expectProgramTuned;
const TraceMode = util.TraceMode;

/// The fft_bitreverse kernel (`bench/luajit/scimark_lib.lua:178`) at the
/// bench's size, n = 1024. Smaller n does NOT reproduce the fft shape: at
/// n <= 128 the outer loop still reaches ~40–50% traced, because there are
/// fewer inner trip counts, and so fewer whole-iteration sibling shapes (doc
/// 55 §3 "Finding"). The data are floats, as in fft. 30 bit-reversals is an
/// even count, so the vector ends where it started.
const bitreverse_src =
    \\local function bitreverse(v, n)
    \\  local j = 0
    \\  for i = 0, 2 * n - 4, 2 do
    \\    if i < j then
    \\      v[i+1], v[i+2], v[j+1], v[j+2] = v[j+1], v[j+2], v[i+1], v[i+2]
    \\    end
    \\    local k = n
    \\    while k <= j do j = j - k; k = k / 2 end
    \\    j = j + k
    \\  end
    \\end
    \\local n = 1024
    \\local v = {}
    \\for i = 1, 2 * n do v[i] = i * 0.5 end
    \\for rep = 1, 30 do bitreverse(v, n) end
    \\print(v[1], v[2 * n])
;

test "doc 56 Phase 0: fft bit-reverse is byte-identical and (today) barely runs traced" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            var anchors: u32 = 0;
            var it = vm.trace.coverage.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.proto.name, "bitreverse")) continue;
                const traced = entry.value_ptr.traced;
                const total = traced + entry.value_ptr.interp;
                if (total < 1000) continue; // not one of the two hot loop anchors
                anchors += 1;
                // TODAY (doc 55 §3): both the outer `for` and the inner
                // `while` anchor run under 10% of their iterations traced.
                // Doc 56 flips this to the §9 target once side traces attach.
                try testing.expect(traced * 10 < total);
            }
            try testing.expectEqual(@as(u32, 2), anchors);
        }
    };
    try expectProgramTuned(bitreverse_src, "0.5\t1024\n", .{ .coverage = true, .inspect = Inspect.run });
}
