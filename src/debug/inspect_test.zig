//! Tests for inspecting a stopped program (doc 86 §5.5, §7.1, §7.2):
//! threads, the stack, scopes, variables and evaluate in any frame.

const std = @import("std");
const testing = std.testing;
const session_mod = @import("session.zig");
const inspect = @import("inspect.zig");
const testutil = @import("testutil.zig");
const interp = @import("../interp.zig");
const keyframeser = @import("../keyframeser.zig");

const Vm = interp.Vm;
const Session = session_mod.Session;
const Stop = session_mod.Stop;
const Resume = session_mod.Resume;
const Program = testutil.Program;
const Script = testutil.Script;

/// A scripted driver whose stops run `look`, which writes what it saw to
/// `text`. A failure inside `look` is kept in `failed` for the test to
/// report, because a driver's answer cannot carry an error.
const Rig = struct {
    script: Script,
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    look: *const fn (rig: *Rig, s: *Session) anyerror!void,
    failed: ?anyerror = null,
    /// Free for `look`.
    ref: u32 = 0,
    stops: usize = 0,

    fn init(gpa: std.mem.Allocator, look: *const fn (rig: *Rig, s: *Session) anyerror!void) Rig {
        return .{ .script = .{ .gpa = gpa, .decide = &decide }, .gpa = gpa, .look = look };
    }

    fn deinit(self: *Rig) void {
        self.script.deinit();
        self.text.deinit(self.gpa);
    }

    fn print(self: *Rig, comptime fmt: []const u8, args: anytype) !void {
        try self.text.print(self.gpa, fmt, args);
    }

    fn decide(script: *Script, s: *Session, stop: Stop) Resume {
        const rig: *Rig = @fieldParentPtr("script", script);
        if (stop.reason == .breakpoint) {
            rig.stops += 1;
            rig.look(rig, s) catch |e| {
                if (rig.failed == null) rig.failed = e;
            };
        }
        return .@"continue";
    }
};

fn breakAt(s: *Session, lines: []const u32) !void {
    var reqs: [8]session_mod.BreakpointRequest = undefined;
    var out: [8]session_mod.Breakpoint = undefined;
    for (lines, 0..) |l, i| reqs[i] = .{ .line = l };
    try s.setBreakpoints("main", reqs[0..lines.len], out[0..lines.len]);
}

/// Run `source` under `rig` with breakpoints at `lines`.
fn runRig(gpa: std.mem.Allocator, rig: *Rig, source: [:0]const u8, lines: []const u32, with_source: bool) !void {
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, rig.script.driver(), .{});
    defer s.detach();
    if (with_source) try s.addSource(&prog.chunk, source);
    try breakAt(&s, lines);
    _ = try s.run(prog.chunk.proto);
    if (rig.failed) |e| return e;
}

fn writeVars(rig: *Rig, vars: []const inspect.Variable, indent: []const u8) !void {
    for (vars) |v| {
        // A function's text carries its object id, which a test does not pin.
        if (std.mem.eql(u8, v.type_name, "function")) {
            try rig.print("{s}{s}=<function>\n", .{ indent, v.name });
        } else try rig.print("{s}{s}={s}\n", .{ indent, v.name, v.value });
    }
}

/// The running coroutine's stack, with each Lua frame's locals and upvalues.
fn lookStack(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    try rig.print("--\n", .{});
    const page = try s.stackTrace(a, inspect.threadId(s.vm.current), 0, 0);
    for (page.frames) |f| {
        try rig.print("{s}:{d}:{d}\n", .{ f.name, f.line, f.column });
        if (f.native) continue;
        const scopes = try s.scopes(a, f.id);
        try writeVars(rig, try s.variables(a, scopes[0].ref, .all, 0, 0), "  local ");
        try writeVars(rig, try s.variables(a, scopes[1].ref, .all, 0, 0), "  upvalue ");
    }
}

test "doc 86 P2: the stack lists each frame with its line and column, and its locals and upvalues by name" {
    const gpa = testing.allocator;
    const source =
        \\local limit = 100
        \\local function inner(a, b)
        \\    local sum = a + b
        \\    local label = "total"
        \\    return sum + limit + #label + a + b
        \\end
        \\local x = 10
        \\local r = inner(x, 5)
        \\return r + x
    ;
    var rig = Rig.init(gpa, &lookStack);
    defer rig.deinit();
    try runRig(gpa, &rig, source, &.{5}, true);
    try testing.expectEqualStrings(
        \\--
        \\inner:5:18
        \\  local a=10
        \\  local b=5
        \\  local sum=15
        \\  local label="total"
        \\  upvalue limit=100
        \\main chunk:8:20
        \\  local limit=100
        \\  local inner=<unavailable>
        \\  local x=10
        \\
    , rig.text.items);
}

fn lookTable(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const page = try s.stackTrace(a, 1, 0, 1);
    const scopes = try s.scopes(a, page.frames[0].id);
    const locals = try s.variables(a, scopes[0].ref, .all, 0, 0);
    var t: inspect.Variable = undefined;
    for (locals) |v| {
        if (std.mem.eql(u8, v.name, "t")) t = v;
    }
    try testing.expectEqualStrings("table", t.type_name);
    try testing.expectEqual(@as(u32, 3), t.indexed);
    // `[metatable]`, `name`, `nested`.
    try testing.expectEqual(@as(u32, 3), t.named);

    try writeVars(rig, try s.variables(a, t.ref, .indexed, 0, 0), "i ");
    try writeVars(rig, try s.variables(a, t.ref, .indexed, 1, 1), "page ");
    const named = try s.variables(a, t.ref, .named, 0, 0);
    try testing.expectEqualStrings("[metatable]", named[0].name);
    var seen_name = false;
    var nested: ?inspect.Variable = null;
    for (named[1..]) |v| {
        if (std.mem.eql(u8, v.name, "name")) {
            seen_name = true;
            try testing.expectEqualStrings("\"box\"", v.value);
            try testing.expectEqualStrings("string", v.type_name);
            try testing.expectEqual(@as(u32, 0), v.ref);
        }
        if (std.mem.eql(u8, v.name, "nested")) nested = v;
    }
    try testing.expect(seen_name);
    try writeVars(rig, try s.variables(a, nested.?.ref, .all, 0, 0), "nested ");
    // A page of the named run.
    try testing.expectEqual(@as(usize, 1), (try s.variables(a, t.ref, .named, 2, 1)).len);
    // Both runs in one listing, the array part first.
    const all = try s.variables(a, t.ref, .all, 0, 0);
    try testing.expectEqual(@as(usize, 6), all.len);
    try testing.expectEqualStrings("[1]", all[0].name);
}

test "doc 86 P2: a table lists its array part by position, its named children, and its metatable, and pages both" {
    const gpa = testing.allocator;
    const source =
        \\local t = {10, 20, 30, name = "box", nested = {7}}
        \\setmetatable(t, {})
        \\local done = true
        \\return done, #t
    ;
    var rig = Rig.init(gpa, &lookTable);
    defer rig.deinit();
    try runRig(gpa, &rig, source, &.{3}, true);
    try testing.expectEqualStrings(
        \\i [1]=10
        \\i [2]=20
        \\i [3]=30
        \\page [2]=20
        \\nested [1]=7
        \\
    , rig.text.items);
}

fn lookBig(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const page = try s.stackTrace(a, 1, 0, 1);
    const scopes = try s.scopes(a, page.frames[0].id);
    const locals = try s.variables(a, scopes[0].ref, .all, 0, 0);
    var big: inspect.Variable = undefined;
    for (locals) |v| {
        if (std.mem.eql(u8, v.name, "big")) big = v;
    }
    const groups = try s.variables(a, big.ref, .named, 0, 0);
    try testing.expect(groups.len > 1);
    try testing.expectEqualStrings("[slots 0\u{2013}99]", groups[0].name);
    var entries: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (groups, 0..) |g, gi| {
        try testing.expect(g.ref != 0);
        // The groups tile the slots: each is the next hundred.
        if (gi + 1 < groups.len) {
            const want = try std.fmt.allocPrint(a, "[slots {d}\u{2013}{d}]", .{ gi * inspect.group_size, gi * inspect.group_size + inspect.group_size - 1 });
            try testing.expectEqualStrings(want, g.name);
        }
        // A page of a group reads only its own slots (`lo..hi`, at most
        // 100 of them), so no group lists more than that.
        const children = try s.variables(a, g.ref, .all, 0, 0);
        try testing.expect(children.len <= inspect.group_size);
        entries += children.len;
        // Every entry is in exactly one group.
        for (children) |c| {
            const slot = try seen.getOrPut(a, c.name);
            try testing.expect(!slot.found_existing);
        }
        if (children.len > 2) {
            const part = try s.variables(a, g.ref, .all, 1, 2);
            try testing.expectEqual(@as(usize, 2), part.len);
            try testing.expectEqualStrings(children[1].name, part[0].name);
        }
    }
    try testing.expectEqual(@as(usize, 300), seen.count());
    try rig.print("{d}\n", .{entries});
}

test "doc 86 P2: a big hash part lists as slot-range groups, and the groups hold every entry once" {
    const gpa = testing.allocator;
    const source =
        \\local big = {}
        \\for i = 1, 300 do big["k" .. i] = i end
        \\local done = true
        \\return done, #big
    ;
    var rig = Rig.init(gpa, &lookBig);
    defer rig.deinit();
    try runRig(gpa, &rig, source, &.{3}, true);
    try testing.expectEqualStrings("300\n", rig.text.items);
}

fn lookFolded(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const page = try s.stackTrace(a, 1, 0, 1);
    const scopes = try s.scopes(a, page.frames[0].id);
    try writeVars(rig, try s.variables(a, scopes[0].ref, .all, 0, 0), "");
    const o = try s.evaluate("N + #S");
    switch (o) {
        .ok => |v| try rig.print("N + #S = {d}\n", .{v.value.asInt()}),
        .refused, .failed => |m| try rig.print("N + #S: {s}\n", .{m}),
    }
}

const folded_source =
    \\local N <const> = 42
    \\local S <const> = "hi"
    \\local live = 1
    \\return N + live
;

test "doc 86 P2: a folded <const> reads from the chunk's source, in scopes and in evaluate" {
    const gpa = testing.allocator;
    var rig = Rig.init(gpa, &lookFolded);
    defer rig.deinit();
    try runRig(gpa, &rig, folded_source, &.{4}, true);
    try testing.expectEqualStrings(
        \\N=42
        \\S="hi"
        \\live=1
        \\N + #S = 44
        \\
    , rig.text.items);
}

test "doc 86 P2: without the chunk's source a folded <const> is unavailable, with a reason" {
    const gpa = testing.allocator;
    var rig = Rig.init(gpa, &lookFolded);
    defer rig.deinit();
    try runRig(gpa, &rig, folded_source, &.{4}, false);
    try testing.expect(std.mem.indexOf(u8, rig.text.items, "N=<unavailable: 'N' is a folded <const>, and the source of its chunk is not available>") != null);
    try testing.expect(std.mem.indexOf(u8, rig.text.items, "live=1") != null);
}

fn lookCoroutines(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const threads = try s.threads(a);
    try rig.print("{d} threads: {s} {s}\n", .{ threads.len, threads[0].name, @tagName(threads[0].status) });
    try testing.expectEqual(@as(u32, 1), threads[0].id);
    try testing.expectEqual(inspect.ThreadStatus.suspended, threads[1].status);
    // The suspended coroutine's stack, at its yield; evaluate in its frame.
    const page = try s.stackTrace(a, threads[1].id, 0, 0);
    for (page.frames) |f| try rig.print("{s}:{d}\n", .{ f.name, f.line });
    var body: ?inspect.StackFrame = null;
    for (page.frames) |f| {
        if (!f.native and body == null) body = f;
    }
    inline for (.{ "inside", "a + 1" }) |e| {
        switch (try s.evaluateIn(body.?.id, e)) {
            .ok => |v| try rig.print("{s} = {d}\n", .{ e, v.value.asInt() }),
            .refused, .failed => |m| try rig.print("{s}: {s}\n", .{ e, m }),
        }
    }
    // The running (main) stack is untouched by that.
    const main = try s.stackTrace(a, 1, 0, 0);
    try rig.print("main {d} {s}\n", .{ main.total, main.frames[0].name });
    // An id no thread has.
    try testing.expectError(error.UnknownThread, s.stackTrace(a, 999, 0, 0));
}

test "doc 86 P2: threads list the coroutines, and a suspended one's stack evaluates in its own frames" {
    const gpa = testing.allocator;
    const source =
        \\local co = coroutine.create(function(a)
        \\    local inside = a * 2
        \\    coroutine.yield(inside)
        \\    return inside + a
        \\end)
        \\coroutine.resume(co, 21)
        \\local after = 1
        \\return after
    ;
    var rig = Rig.init(gpa, &lookCoroutines);
    defer rig.deinit();
    try runRig(gpa, &rig, source, &.{7}, true);
    try testing.expect(std.mem.startsWith(u8, rig.text.items, "2 threads: main running\n"));
    try testing.expect(std.mem.indexOf(u8, rig.text.items, "inside = 42\n") != null);
    try testing.expect(std.mem.indexOf(u8, rig.text.items, "a + 1 = 22\n") != null);
    try testing.expect(std.mem.indexOf(u8, rig.text.items, "main 1 main chunk\n") != null);
}

fn lookInside(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const threads = try s.threads(a);
    try rig.print("{s} {s}\n", .{ threads[0].name, @tagName(threads[0].status) });
    try rig.print("{s}\n", .{@tagName(threads[1].status)});
    // The running coroutine's stack continues into its resumer's.
    const page = try s.stackTrace(a, threads[1].id, 0, 0);
    for (page.frames) |f| try rig.print("{s}:{d}\n", .{ f.name, f.line });
    // Paging: the last frame alone.
    const last = try s.stackTrace(a, threads[1].id, page.total - 1, 5);
    try testing.expectEqual(@as(usize, 1), last.frames.len);
    try testing.expectEqualStrings(page.frames[page.total - 1].name, last.frames[0].name);
    // The main stack lists its own frames only.
    const main = try s.stackTrace(a, 1, 0, 0);
    try testing.expect(main.total < page.total);
}

test "doc 86 P2: inside a coroutine the running stack continues into the resumer's, and the main thread is normal" {
    const gpa = testing.allocator;
    const source =
        \\local co = coroutine.wrap(function()
        \\    local inside = 1
        \\    return inside
        \\end)
        \\return co()
    ;
    var rig = Rig.init(gpa, &lookInside);
    defer rig.deinit();
    try runRig(gpa, &rig, source, &.{3}, true);
    try testing.expect(std.mem.startsWith(u8, rig.text.items, "main normal\nrunning\n"));
    try testing.expect(std.mem.indexOf(u8, rig.text.items, "main chunk:5\n") != null);
}

fn lookTwice(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    if (rig.stops == 1) {
        const page = try s.stackTrace(a, 1, 0, 0);
        rig.ref = page.frames[0].id;
        _ = try s.scopes(a, rig.ref);
    } else {
        // A reference from before the resume is refused, though the number
        // is one this stop could have handed out.
        try testing.expectError(error.InvalidReference, s.scopes(a, rig.ref));
        try testing.expectError(error.InvalidReference, s.variables(a, rig.ref, .all, 0, 0));
        try testing.expectError(error.InvalidReference, s.evaluateIn(rig.ref, "1"));
        try testing.expectError(error.InvalidReference, s.variables(a, 0, .all, 0, 0));
        const page = try s.stackTrace(a, 1, 0, 0);
        try testing.expect(page.frames[0].id != rig.ref);
    }
}

test "doc 86 P2: a reference does not outlive the stop that handed it out" {
    const gpa = testing.allocator;
    var rig = Rig.init(gpa, &lookTwice);
    defer rig.deinit();
    try runRig(gpa, &rig, "local a = 1\nlocal b = 2\nreturn a + b", &.{ 1, 2 }, true);
    try testing.expectEqual(@as(usize, 2), rig.stops);
}

fn lookEverything(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const threads = try s.threads(a);
    for (threads) |th| {
        const page = try s.stackTrace(a, th.id, 0, 0);
        for (page.frames) |f| {
            const scopes = try s.scopes(a, f.id);
            for (scopes[0..2]) |sc| _ = try s.variables(a, sc.ref, .all, 0, 0);
            // The globals are the biggest table there is.
            const globals = try s.variables(a, scopes[2].ref, .all, 0, 0);
            for (globals) |g| {
                if (g.ref != 0) _ = try s.variables(a, g.ref, .all, 0, 0);
            }
            _ = try s.evaluateIn(f.id, "1 + 1");
        }
    }
}

test "doc 86 P2: inspecting everything at every stop changes neither the step count nor the final snapshot" {
    const gpa = testing.allocator;
    const source =
        \\local t = {}
        \\for i = 1, 20 do t[i] = "v" .. i end
        \\local co = coroutine.wrap(function(x)
        \\    local y = x + 1
        \\    coroutine.yield(y)
        \\    return y
        \\end)
        \\local r = co(1) + co() + #t
        \\return r
    ;
    var ref_vm = try Vm.init(gpa);
    defer ref_vm.deinit();
    var ref_prog = try Program.init(gpa, &ref_vm, source);
    defer ref_prog.deinit();
    const want = try ref_vm.run(ref_prog.chunk.proto);
    const want_snap = try keyframeser.encodeSnapshot(gpa, &ref_vm);
    defer gpa.free(want_snap);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var prog = try Program.init(gpa, &vm, source);
    defer prog.deinit();
    var rig = Rig.init(gpa, &lookEverything);
    defer rig.deinit();
    var s: Session = undefined;
    s.attach(gpa, &vm, rig.script.driver(), .{});
    try s.addSource(&prog.chunk, source);
    try breakAt(&s, &.{ 2, 4, 8 });
    const got = try s.run(prog.chunk.proto);
    s.detach();
    try testing.expectEqual(@as(?anyerror, null), rig.failed);
    try testing.expect(rig.stops >= 3);
    try testing.expectEqual(want.asInt(), got.asInt());
    try testing.expectEqual(ref_vm.safepoint_seq, vm.safepoint_seq);
    const got_snap = try keyframeser.encodeSnapshot(gpa, &vm);
    defer gpa.free(got_snap);
    try testing.expectEqualSlices(u8, want_snap, got_snap);
}

fn lookRunning(rig: *Rig, s: *Session) !void {
    var arena_inst = std.heap.ArenaAllocator.init(rig.gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const threads = try s.threads(a);
    try rig.print("{d}\n", .{threads.len});
    for (threads) |th| {
        const page = try s.stackTrace(a, th.id, 0, 0);
        try rig.print("{d}:{d}\n", .{ th.id, page.total });
    }
}

test "doc 86 P2: coroutine.running() on the main stack does not make a second thread" {
    const gpa = testing.allocator;
    const source =
        \\local main = coroutine.running()
        \\local x = 1
        \\return x, main
    ;
    var rig = Rig.init(gpa, &lookRunning);
    defer rig.deinit();
    try runRig(gpa, &rig, source, &.{2}, true);
    try testing.expectEqualStrings("1\n1:1\n", rig.text.items);
}
