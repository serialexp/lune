//! Tests for `interp.zig` — replay.
//!
//! Extracted verbatim from `interp.zig`; bodies are unchanged.
//! Shared harness lives in `interp_testutil.zig`.

const interp = @import("interp.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const execlog = @import("execlog.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

const Vm = interp.Vm;

const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;
const runCaptured = util.runCaptured;

// ---------------------------------------------------------------------------
// v8 — replay-to-k core: the safepoint-line recorder + the stateless
// "replay to safepoint k" model the in-browser step-debugger drives.
//
// The browser never holds a live VM: to show the program at step k it
// re-compiles and re-runs forward to the k-th instruction-boundary safepoint
// (suspend_ctl.after_safepoints = k), then snapshots. These tests prove the two
// properties that make that sound and useful: (1) re-running to the same k is
// *consistent* (same pending line + same stdout-so-far every time — the
// determinism payoff), and (2) running past the last safepoint reproduces the
// uninterrupted full run exactly (no off-by-one swallows or duplicates the tail).
// The line index `safepoint_lines` underpins the UI's line-grain stepping.
// ---------------------------------------------------------------------------

/// The state observed at a single replay stop: the pending source line, a copy
/// of stdout-so-far, the live call depth, and whether the program had already
/// finished before reaching `stop_after`.
const ReplayProbe = struct {
    line: u32,
    stdout: []u8,
    depth: u32,
    finished: bool,
    fn deinit(self: ReplayProbe, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Compile `source` and run it forward to safepoint `stop_after`, returning the
/// pending line + stdout-so-far + depth at that point (or the final state, with
/// `finished = true`, if the program completed first). A fresh VM each call —
/// exactly the stateless "replay to k" the browser driver performs.
fn replayProbe(gpa: std.mem.Allocator, source: [:0]const u8, stop_after: u64) !ReplayProbe {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [1024]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.suspend_ctl = .{ .after_safepoints = stop_after };

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    const outcome = try vm.start(chunk.proto);
    var line: u32 = 0;
    var finished = false;
    switch (outcome) {
        .suspended => {
            const frame = &vm.frames[vm.depth - 1];
            const proto = frame.closure.proto;
            if (frame.pc < proto.spans.len) {
                line = compiler.lineFromOffset(source, proto.spans[frame.pc].start);
            }
        },
        .finished => finished = true,
    }
    return .{
        .line = line,
        .stdout = try gpa.dupe(u8, sink.buffered()),
        .depth = vm.depth,
        .finished = finished,
    };
}

/// Run `source` to completion with the safepoint-line recorder on, returning the
/// per-safepoint line index (owned). Its length is the total safepoint count.
fn recordSafepointLines(gpa: std.mem.Allocator, source: [:0]const u8) ![]u32 {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [1024]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.source = source;
    vm.record_safepoint_lines = true;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    return gpa.dupe(u32, vm.safepoint_lines.items);
}

test "replay: re-running to the same safepoint k is consistent (line + stdout-so-far)" {
    const gpa = testing.allocator;
    const source: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 5 do
        \\  s = s + i
        \\  print(s)
        \\end
        \\print("done")
    ;
    // Probe every k from 1 up to a generous bound and assert a second probe to
    // the same k reproduces the identical (line, stdout-so-far, depth) tuple.
    var k: u64 = 1;
    while (k <= 80) : (k += 1) {
        const a = try replayProbe(gpa, source, k);
        defer a.deinit(gpa);
        const b = try replayProbe(gpa, source, k);
        defer b.deinit(gpa);
        try testing.expectEqual(a.line, b.line);
        try testing.expectEqual(a.depth, b.depth);
        try testing.expectEqual(a.finished, b.finished);
        try testing.expectEqualStrings(a.stdout, b.stdout);
    }
}

test "replay: stdout-so-far grows monotonically and the pending line stays in range" {
    const gpa = testing.allocator;
    const source: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 3 do
        \\  s = s + i
        \\  print(s)
        \\end
    ;
    var prev_len: usize = 0;
    var k: u64 = 1;
    while (k <= 60) : (k += 1) {
        const p = try replayProbe(gpa, source, k);
        defer p.deinit(gpa);
        // stdout-so-far is a prefix-growing log: it never shrinks as k advances.
        try testing.expect(p.stdout.len >= prev_len);
        prev_len = p.stdout.len;
        // A pending line (when suspended) lies within the 4-line source.
        if (!p.finished) try testing.expect(p.line >= 1 and p.line <= 4);
    }
}

test "replay: running past the last safepoint reproduces the uninterrupted full run" {
    const gpa = testing.allocator;
    const programs = [_][:0]const u8{
        \\local s = 0
        \\for i = 1, 10 do s = s + i end
        \\print(s)
        ,
        \\local function f(x) return x * 2 end
        \\for i = 1, 4 do print(f(i)) end
        ,
    };
    inline for (programs) |source| {
        const lines = try recordSafepointLines(gpa, source);
        defer gpa.free(lines);
        const total: u64 = lines.len;
        try testing.expect(total > 0);
        // Every recorded line is a real, in-range source line (1-based).
        for (lines) |ln| try testing.expect(ln >= 1);

        // Replaying to total+1 never trips the suspend (max safepoint_seq == total),
        // so it runs to completion — byte-identical stdout to the full run.
        const replayed = try replayProbe(gpa, source, total + 1);
        defer replayed.deinit(gpa);
        try testing.expect(replayed.finished);

        // And a separate uninterrupted run prints the same thing.
        var ref_buf: [1024]u8 = undefined;
        var ref_sink = io.Writer.fixed(&ref_buf);
        try runCaptured(gpa, source, &ref_sink, false, .off);
        try testing.expectEqualStrings(ref_sink.buffered(), replayed.stdout);
    }
}

test "replay: backtraceFrames reports a deepest-first chain at a suspend inside a call" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source: [:0]const u8 =
        \\local function inner(x)
        \\  local y = x + 1
        \\  return y
        \\end
        \\local function outer(n)
        \\  return inner(n)
        \\end
        \\print(outer(7))
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    // Suspend the first time we are at least 3 frames deep (main → outer → inner).
    vm.suspend_ctl = .{ .min_depth = 3, .after_safepoints = 0 };

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    const outcome = try vm.start(chunk.proto);
    try testing.expect(outcome == .suspended);
    try testing.expectEqual(@as(u32, 3), vm.depth);

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const frames = try vm.backtraceFrames(source, arena_inst.allocator());
    // Deepest-first: inner (leaf), outer, main.
    try testing.expectEqual(@as(usize, 3), frames.len);
    try testing.expectEqualStrings("inner", frames[0].name);
    try testing.expectEqualStrings("outer", frames[1].name);
    try testing.expectEqualStrings("main", frames[2].name);
}

test "top-level re-entry on a suspended (dirty) VM fails closed (doc 17 H-3 / 9-A(ii))" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    const source =
        \\local function inner() return 1 end
        \\local function outer() return inner() end
        \\print(outer())
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.suspend_ctl = .{ .min_depth = 3, .after_safepoints = 0 };

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    // Suspend mid-execution: frames stay live, so `depth != 0`.
    const outcome = try vm.start(chunk.proto);
    try testing.expect(outcome == .suspended);
    try testing.expect(vm.depth != 0);
    const sentinel: trace.RegionKey = .{
        .region_id = @enumFromInt(0xA603),
        .activation = 999_999,
    };
    try vm.trace.region_policy.region_profit.put(gpa, sentinel, .{
        .outer_traversals = 3,
        .root_frame_depth = vm.depth,
        .root_call_seq = sentinel.activation,
    });

    // A fresh top-level entry through the wrong door (`start`/`run` rather than
    // resuming via `exec()`) must be rejected BEFORE mutating any epoch state — a
    // bare assert would vanish under ReleaseFast, so this is a returned error.
    try testing.expectError(error.DirtyTopLevelEntry, vm.start(chunk.proto));
    try testing.expectError(error.DirtyTopLevelEntry, vm.run(chunk.proto));
    try testing.expect(vm.trace.region_policy.region_profit.contains(sentinel));

    // The suspended epoch is still intact and resumes normally to completion
    // (clear the trigger first, else it re-suspends at the same depth).
    vm.suspend_ctl = null;
    switch (try vm.exec()) {
        .finished => {},
        .suspended => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("1\n", sink.buffered());
}

test "H-3: a clean fresh top-level epoch clears region_profit wholesale" {
    const gpa = testing.allocator;
    const source: [:0]const u8 = "return 1";
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    try testing.expectEqual(@as(u32, 0), vm.depth);
    try vm.trace.region_policy.region_profit.put(gpa, .{
        .region_id = @enumFromInt(0xA604),
        .activation = 42,
    }, .{
        .outer_traversals = 5,
        .root_frame_depth = 1,
        .root_call_seq = 42,
    });
    try testing.expectEqual(@as(usize, 1), vm.trace.regionProfitCount());

    _ = try vm.run(chunk.proto);
    try testing.expectEqual(@as(usize, 0), vm.trace.regionProfitCount());
}

test "e2e: recursion, loop, locals — fib and a summing loop" {
    try expectProgram(
        \\local function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n - 1) + fib(n - 2)
        \\end
        \\local total = 0
        \\for i = 1, 10 do total = total + i end
        \\print(fib(10), total)
    , "55\t55\n"); // fib(10) == 55, sum 1..10 == 55
}

test "e2e: multi-return — native (math.modf) and closure, with adjustment rules" {
    try expectProgram(
        \\local i, f = math.modf(3.5)
        \\print(i, f)                  -- 3  0.5
        \\local x = math.modf(3.5)
        \\print(x)                     -- 3   (nwanted=1 truncates the second result)
        \\local a, b, c = math.modf(3.5)
        \\print(a, b, c)               -- 3  0.5  nil   (extra target nil-padded)
        \\local p, q = math.modf(3.5), 9
        \\print(p, q)                  -- 3  9   (call not in last position ⇒ no expand)
        \\local g, h = 0, 0
        \\g, h = math.modf(-3.25)
        \\print(g, h)                  -- -3  -0.25 (multi-target assignment)
        \\local m, n = (function() return 11, 22 end)()
        \\print(m, n)                  -- 11  22  (closure multret via the same ABI)
        \\local r, s, t = (function() return 1, 2 end)()
        \\print(r, s, t)               -- 1  2  nil
    ,
        "3\t0.5\n3\n3\t0.5\tnil\n3\t9\n-3\t-0.25\n11\t22\n1\t2\tnil\n",
    );
}

test "e2e: dynamic multret — call-arg and return position expand (all_results)" {
    // Exercises the `all_results` sentinel through `expectProgram`, which runs all
    // five modes *and* stress GC (collect at every safepoint). The safepoint
    // between a multret producer and its consumer is gated by `reg_top_pending`,
    // so stress mode here is the real test that transient results above
    // `num_registers` are never collected and `reg_top` never leaks into a
    // snapshot.
    try expectProgram(
        \\local function f() return 1, 2, 3 end
        \\print(f())                              -- call-arg expands: 1 2 3
        \\print(0, f())                           -- last arg expands, earlier kept: 0 1 2 3
        \\print(f(), 9)                           -- non-last call truncates to 1: 1 9
        \\local g = function() return f() end      -- `return f()` forwards all
        \\print(g())                              -- 1 2 3
        \\print((function() return f() end)())     -- nested forward: 1 2 3
        \\print(f(f()))                           -- inner f feeds outer f: 1 2 3
        \\local function h() return end            -- zero results
        \\print("x", h())                         -- zero-expand: x
        \\local o = { go = function(self, n) return n, n + 1 end }
        \\print(o:go(10))                         -- method-call expand: 10 11
        \\print(o:go(f()))                        -- method + multret last arg: self,1 → 1 2
    ,
        "1\t2\t3\n0\t1\t2\t3\n1\t9\n1\t2\t3\n1\t2\t3\n1\t2\t3\nx\n10\t11\n1\t2\n",
    );
}

test "e2e: table library — unpack/pack/insert/remove/concat/move" {
    // Drives `stdlib/table.zig` through all five modes + stress GC. `unpack` is a
    // multi native, so `print(table.unpack(t))` also re-exercises the `all_results`
    // path end-to-end via the library (not just the closure/`math.modf` cases).
    try expectProgram(
        \\local function f() return 1, 2, 3 end
        \\print(table.unpack({10, 20, 30}))            -- multret call-arg: 10 20 30
        \\print(table.unpack({10, 20, 30, 40}, 2, 3))  -- sub-range: 20 30
        \\local a, b = table.unpack({7, 8, 9})         -- fixed truncation: 7 8
        \\print(a, b)
        \\local p = table.pack(f())                    -- pack multret: n=3
        \\print(p.n, p[1], p[2], p[3])
        \\print(table.pack().n)                        -- empty pack: 0
        \\local t = {1, 2, 3}
        \\table.insert(t, 4)                           -- append
        \\table.insert(t, 1, 0)                        -- positional insert
        \\print(table.concat(t, ","))                  -- 0,1,2,3,4
        \\local r1 = table.remove(t)                   -- remove tail → 4
        \\local r2 = table.remove(t, 1)                -- remove head → 0
        \\print(r1, r2, table.concat(t, ","))          -- 4 0 1,2,3
        \\print(table.concat({9, 8, 7, 6}, "-", 2, 3)) -- ranged concat: 8-7
        \\local m = {1, 2, 3, 4, 5}
        \\table.move(m, 1, 3, 3)                        -- overlap-up copy
        \\print(table.concat(m, ","))                  -- 1,2,1,2,3
        \\local dst = {0, 0, 0, 0, 0}
        \\table.move({1, 2, 3}, 1, 3, 2, dst)          -- copy into another table
        \\print(table.concat(dst, ","))                -- 0,1,2,3,0
    ,
        "10\t20\t30\n20\t30\n7\t8\n3\t1\t2\t3\n0\n0,1,2,3,4\n4\t0\t1,2,3\n8-7\n1,2,1,2,3\n0,1,2,3,0\n",
    );
}

test "e2e: generic-for + pairs/ipairs/next" {
    // Drives `compileGenericFor` + `stdlib/base.zig` through all five modes +
    // stress GC. Covers: ipairs (array, ascending), ipairs stops at the first nil
    // hole, pairs over a string-keyed hash (canonical interning-id order),
    // n=1 `for k in pairs` (the `func` primary-projection path), mixed array+hash,
    // `false` values continue (only nil stops), break, empty table (zero
    // iterations), and a user-defined stateless 3-value iterator (`tri, nil, 0`).
    try expectProgram(
        \\local a = {10, 20, 30}
        \\for i, v in ipairs(a) do print(i, v) end
        \\local h = {1, 2, nil, 4}
        \\for i, v in ipairs(h) do print("h", i, v) end
        \\local t = {}
        \\t.x = 1
        \\t.y = 2
        \\t.z = 3
        \\for k, v in pairs(t) do print(k, v) end
        \\for k in pairs(t) do print(k) end
        \\local m = {100, 200}
        \\m.tag = 9
        \\for k, v in pairs(m) do print("m", k, v) end
        \\local ft = {}
        \\ft.p = false
        \\local c = 0
        \\for k, v in pairs(ft) do c = c + 1 end
        \\print("false-count", c)
        \\for i, v in ipairs({5, 6, 7, 8}) do
        \\  if v == 7 then break end
        \\  print("br", i, v)
        \\end
        \\for k, v in pairs({}) do print("nope") end
        \\print("empty-ok")
        \\local function tri(s, j)
        \\  j = j + 1
        \\  if j > 2 then return nil end
        \\  return j, j * 2, j * 3
        \\end
        \\for x, y, z in tri, nil, 0 do print("tri", x, y, z) end
    ,
        "1\t10\n2\t20\n3\t30\n" ++
            "h\t1\t1\nh\t2\t2\n" ++
            "x\t1\ny\t2\nz\t3\n" ++
            "x\ny\nz\n" ++
            "m\t1\t100\nm\t2\t200\nm\ttag\t9\n" ++
            "false-count\t1\n" ++
            "br\t1\t5\nbr\t2\t6\n" ++
            "empty-ok\n" ++
            "tri\t1\t2\t3\ntri\t2\t4\t6\n",
    );
}

test "e2e: generic-for delete current key during traversal (Lua-legal)" {
    // Deleting the key currently being visited is allowed; the strictly-greater
    // successor search in `next` continues correctly without crash or repeat.
    // Build a 3-key hash, delete each key as we visit it, assert all three are
    // seen exactly once and the table ends empty.
    try expectProgram(
        \\local t = {}
        \\t.a = 1
        \\t.b = 2
        \\t.c = 3
        \\local count = 0
        \\for k, v in pairs(t) do
        \\  count = count + v
        \\  t[k] = nil
        \\end
        \\print(count)
        \\local left = 0
        \\for k, v in pairs(t) do left = left + 1 end
        \\print(left)
    , "6\n0\n");
}

test "e2e: repeat/until across all modes" {
    // Post-test loop driven through every execution + GC mode. Covers: body runs
    // before the test, `until` referencing a body-local, a nested repeat, and
    // break. The accumulation is numeric so the trace recorder has a hot loop to
    // chew on without heap churn.
    try expectProgram(
        \\local i = 0
        \\local sum = 0
        \\repeat
        \\  i = i + 1
        \\  sum = sum + i
        \\  local stop = 100
        \\until sum >= stop
        \\print(i, sum)
        \\local outer = 0
        \\local total = 0
        \\repeat
        \\  outer = outer + 1
        \\  local inner = 0
        \\  repeat
        \\    inner = inner + 1
        \\    total = total + 1
        \\  until inner >= 3
        \\until outer >= 4
        \\print(outer, total)
        \\local k = 0
        \\repeat
        \\  k = k + 1
        \\  if k == 5 then break end
        \\until k >= 100
        \\print(k)
    , "14\t105\n4\t12\n5\n");
}

test "e2e: T3 hook-elision handoff — a hot loop records then runs native, byte-identical across modes" {
    // Exercises the T3 fast/slow dispatch seam end to end. `.off` (always `.fast`,
    // pure tier-0) is the oracle. The recording modes drive both transitions:
    // `.fast`→`.full` when the hotcount arms a recording at a back-edge (the next
    // instruction needs the recording mirror that `.fast` elides), then
    // `.full`→`.fast` once the trace compiles and runs as native steady state. A
    // handoff that mis-parks `pc` (the bug that hung the gate) would either
    // diverge from the oracle here or fail to terminate. The loop count is modest
    // so the GC-stress arms (which collect every instruction) finish quickly.
    try expectProgram(
        \\local acc = 0
        \\for i = 1, 300 do acc = acc + i end
        \\print(acc)
    , "45150\n");
}

test "e2e: LICM hoists a loop-invariant subexpression, transparently (all modes)" {
    // `a * b` is recomputed in the loop body every iteration, but `a` and `b`
    // are loop-invariant locals → the recorder sees an invariant `mul`, which
    // E1 LICM hoists into the preheader (computed once). The `.off` (tier-0)
    // arm is the real correctness gate: it never runs the optimizer, so its
    // output proves the hoisted optimized/native arms didn't change the value.
    // A second invariant chain (`a + b`, also hoistable) exercises a >1-deep
    // preheader cone. 1000 iters: acc = 1000*(12 + 7) = 19000.
    try expectProgram(
        \\local a = 3
        \\local b = 4
        \\local acc = 0
        \\for i = 1, 1000 do
        \\  acc = acc + a * b + (a + b)
        \\end
        \\print(acc)
    , "19000\n");
}

test "e2e: varargs spread, destructure, and nil-padding across all modes" {
    // Bare `...`: forward (`print(...)`), single-value (`local x = ...`),
    // destructure with surplus and with nil-padding (`local a, b = ...`), a
    // leading fixed param plus tail spread (`f(x, ...)`), and the empty case
    // (`...` with no surplus args). Driven through every execution + GC mode.
    try expectProgram(
        \\local function fwd(...)
        \\  print(...)
        \\end
        \\local function head(...)
        \\  local x = ...
        \\  return x
        \\end
        \\local function first2(...)
        \\  local a, b = ...
        \\  return a, b
        \\end
        \\local function tailcat(x, ...)
        \\  print(x, ...)
        \\end
        \\fwd(1, 2, 3)
        \\fwd()
        \\print(head(7, 8))
        \\print(first2(10, 20, 30))
        \\print(first2(5))
        \\tailcat(1, 2, 3)
        \\tailcat(9)
    , "1\t2\t3\n\n7\n10\t20\n5\tnil\n1\t2\t3\n9\n");
}

test "e2e: varargs forwarding through return and nested calls, method spread" {
    // `return ...` forwards all values; a nested `f(g(...))` chains two spreads;
    // a method `obj:m(...)` carries `self` plus the spread tail.
    try expectProgram(
        \\local function g(...)
        \\  return ...
        \\end
        \\local function f(...)
        \\  print(g(...))
        \\end
        \\f(1, 2)
        \\f(3, 4, 5)
        \\local obj = { name = "mahina" }
        \\obj.greet = function(self, ...)
        \\  print(self.name, ...)
        \\end
        \\obj:greet("a", "b")
        \\obj:greet()
    , "1\t2\n3\t4\t5\nmahina\ta\tb\nmahina\n");
}

test "e2e: parenthesized varargs truncate to a single value" {
    // `(...)` is the Lua paren-truncation rule: even in a tail position it yields
    // exactly one value (the first), so `return (...)` and `f((...))` are single.
    try expectProgram(
        \\local function pick(...)
        \\  return (...)
        \\end
        \\local function wrap(...)
        \\  print((...), "end")
        \\end
        \\print(pick(10, 20, 30))
        \\print(pick())
        \\wrap(1, 2, 3)
    , "10\nnil\n1\tend\n");
}

test "e2e: tables and string concat" {
    try expectProgram(
        \\local t = {}
        \\t.name = "mahina"
        \\t.answer = 40 + 2
        \\print("hello, " .. t.name)
        \\print("answer=" .. t.answer)
    , "hello, mahina\nanswer=42\n");
}

test "e2e: basic + string stdlib are byte-identical across all modes" {
    // Exercises the S1/S2 pure natives, including string ops called inside a hot
    // loop (so recording + native compilation cross a native call). Output must be
    // identical across {off, record_only, noopt, record_execute, native} × stress.
    try expectProgram(
        \\for i = 1, 3 do
        \\  print(string.format("%d:%s", i, string.rep("ab", i)))
        \\end
        \\print(type("x"), math.type(1), math.type(1.5), _VERSION)
        \\print(select("#", 1, 2, 3), select(2, "a", "b"))
        \\print(string.sub("hello", 2, 4), string.codepoint("A"))
    ,
        "1:ab\n2:abab\n3:ababab\n" ++
            "string\tinteger\tfloat\tmahina 0.0.0\n" ++
            "3\tb\n" ++
            "ell\t65\n",
    );
}

test "e2e: string pattern matching is byte-identical across all modes" {
    // find/match/gmatch/gsub through the VM. The 50-iteration loop calling a
    // pattern native makes the recorder cross a native call in a hot loop; the
    // gmatch generic-for exercises the state-table iterator. Output must be
    // identical across {off, record_only, noopt, record_execute, native} × stress.
    try expectProgram(
        \\local c = 0
        \\for i = 1, 50 do
        \\  if string.find("hello world", "world") then c = c + 1 end
        \\end
        \\print(c, string.match("k=v", "(%w+)=(%w+)"))
        \\print(string.find("abcabc", "b", 3))
        \\local n = 0
        \\for w in string.gmatch("a b c d", "%a") do n = n + 1 end
        \\print(n, (string.gsub("hello", "l", "L")))
    ,
        "50\tk\tv\n" ++
            "5\t5\n" ++
            "4\theLLo\n",
    );
}

test "e2e: code-point-native strings are byte-identical across all modes" {
    // S-B (design doc 06): #, sub, reverse, char, codepoint, codes, %c, %.Ns and
    // \u{} all index by Unicode code point, not byte. All of these run tier-0 (the
    // recorder aborts on `len`, and the rest are native string calls), so the
    // output must be identical across {off, record_only, noopt, record_execute,
    // native} × stress.
    try expectProgram(
        \\print(#"héllo", #"ab😀")
        \\print(("héllo"):sub(2, 2), ("héllo"):sub(2))
        \\print(("ab😀"):reverse())
        \\print(string.char(0x1F600), string.char(72, 0xE9))
        \\print(("héllo"):codepoint(2), string.codepoint("ab😀", 3))
        \\local idx, cps = "", ""
        \\for i, c in ("aé"):codes() do idx = idx .. i; cps = cps .. c .. " " end
        \\print(idx, cps)
        \\print(string.format("%c%c", 0x41, 0x1F600))
        \\print(string.format("%.2s", "héllo"))
        \\print("\u{E9}" == "é", "\u{1F600}" == "😀")
    ,
        "5\t3\n" ++
            "é\téllo\n" ++
            "😀ba\n" ++
            "😀\tHé\n" ++
            "233\t128512\n" ++
            "12\t97 233 \n" ++
            "A😀\n" ++
            "hé\n" ++
            "true\ttrue\n",
    );
}

test "e2e: closures capture per-iteration bindings; higher-order print" {
    try expectProgram(
        \\local function adder(x)
        \\  return function(y) return x + y end
        \\end
        \\local add10 = adder(10)
        \\local add20 = adder(20)
        \\print(add10(1), add20(1), add10(add20(0)))
    , "11\t21\t30\n"); // 11, 21, add10(20) == 30
}

test "e2e: while loop with a table accumulator" {
    try expectProgram(
        \\local t = {}
        \\local i = 1
        \\while i <= 3 do
        \\  t[i] = i * i
        \\  i = i + 1
        \\end
        \\print(t[1], t[2], t[3], #t)
    , "1\t4\t9\t3\n");
}
