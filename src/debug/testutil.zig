//! Test harness for the debugger core: a compiled program and a scripted
//! driver that logs every stop.

const std = @import("std");
const testing = std.testing;
const session_mod = @import("session.zig");
const interp = @import("../interp.zig");
const parser = @import("../parser.zig");
const compiler = @import("../compiler.zig");
const Diagnostics = @import("../diag.zig").Diagnostics;

const Vm = interp.Vm;
const Session = session_mod.Session;
const Stop = session_mod.Stop;
const Resume = session_mod.Resume;

/// A compiled program, kept alive for the run.
pub const Program = struct {
    tree: @import("../ast.zig").Ast,
    chunk: compiler.Chunk,

    pub fn init(gpa: std.mem.Allocator, vm: *Vm, source: [:0]const u8) !Program {
        var diags = Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        errdefer tree.deinit();
        try testing.expect(!diags.hasErrors());
        const chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        try testing.expect(!diags.hasErrors());
        return .{ .tree = tree, .chunk = chunk };
    }

    pub fn deinit(self: *Program) void {
        self.chunk.deinit();
        self.tree.deinit();
    }
};

/// One stop as the driver saw it.
pub const Seen = struct {
    reason: session_mod.Reason,
    line: u32,
    depth: u32,
    reentry: u16,
    /// The first breakpoint id the stop names, or 0.
    hit: u32 = 0,
    /// How many breakpoint ids it names.
    hits: usize = 0,
    /// The running coroutine's header id, 0 for the main stack.
    co: u32 = 0,
};

/// A scripted driver: it logs every stop, and for each one asks `decide`
/// what to do next (which may also request a pause, to step by
/// instruction).
pub const Script = struct {
    seen: std.ArrayList(Seen) = .empty,
    gpa: std.mem.Allocator,
    decide: *const fn (self: *Script, s: *Session, stop: Stop) Resume,
    /// Free for `decide`'s use.
    n: usize = 0,
    requests_taken: usize = 0,
    on_requests: ?*const fn (self: *Script, s: *Session) void = null,
    /// Every `breakpoint_changed` event, in order.
    changed: std.ArrayList(session_mod.Breakpoint) = .empty,
    /// When set, `driver` returns it (a test that adds callbacks).
    driver_override: ?session_mod.Driver = null,
    /// What `followPlan` answers, one entry per stop; `continue` once it
    /// runs out.
    plan: []const Resume = &.{},

    pub fn driver(self: *Script) session_mod.Driver {
        if (self.driver_override) |d| return d;
        return .{ .ctx = self, .stopped = &stopped, .requests = &requests, .breakpoint_changed = &breakpointChanged };
    }

    fn breakpointChanged(ctx: *anyopaque, _: *Session, bp: session_mod.Breakpoint) void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        self.changed.append(self.gpa, bp) catch @panic("OOM in a test driver");
    }

    /// The lines of the breakpoint stops, in order.
    pub fn breakpointLines(self: *const Script, buf: []u32) []u32 {
        var n: usize = 0;
        for (self.seen.items) |seen| {
            if (seen.reason != .breakpoint) continue;
            buf[n] = seen.line;
            n += 1;
        }
        return buf[0..n];
    }

    fn stopped(ctx: *anyopaque, s: *Session, stop: Stop) Resume {
        const self: *Script = @ptrCast(@alignCast(ctx));
        const line: u32 = if (s.stopped_at) |at| at.line() else 0;
        self.seen.append(self.gpa, .{
            .reason = stop.reason,
            .line = line,
            .depth = s.vm.depth,
            .reentry = s.vm.native_reentry_depth,
            .hit = if (stop.hits.len > 0) stop.hits[0] else 0,
            .hits = stop.hits.len,
            .co = if (s.vm.current) |t| t.header.id else 0,
        }) catch @panic("OOM in a test driver");
        return self.decide(self, s, stop);
    }

    fn requests(ctx: *anyopaque, s: *Session) void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        self.requests_taken += 1;
        if (self.on_requests) |f| f(self, s);
    }

    pub fn deinit(self: *Script) void {
        self.seen.deinit(self.gpa);
        self.changed.deinit(self.gpa);
    }
};

pub fn alwaysContinue(_: *Script, _: *Session, _: Stop) Resume {
    return .@"continue";
}

/// Answer each stop with the next entry of `Script.plan`.
pub fn followPlan(self: *Script, _: *Session, stop: Stop) Resume {
    if (stop.reason == .ended or self.n >= self.plan.len) return .@"continue";
    defer self.n += 1;
    return self.plan[self.n];
}
