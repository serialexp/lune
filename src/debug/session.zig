//! A debug session over one live VM (doc 86 §3, §3.1, §5).
//!
//! The session attaches to a VM through `Vm.debug`. From then on every
//! dispatch prologue may call the session's check, and a stop happens in
//! place: the check calls the driver's `stopped` on the VM's own stack and
//! returns when the driver says how to go on. Nothing unwinds the VM to
//! stop it, so a stop works inside a native's re-entry, a coroutine and an
//! embedded host's own call, all of which a keyframe suspend refuses.
//!
//! The session does no I/O. Its driver, the transport, is a pair of
//! callbacks: `stopped` while the program is stopped, and `requests` when
//! the transport has flagged requests that arrived while the program ran.
//! A transport on another thread signals through `requestPause`,
//! `requestTerminate` and `notifyRequests`, which only set atomic bits.
//!
//! A session holds the JIT suspended for as long as it is attached (D3,
//! §5.6): every dispatch then runs `.full`, where the check sits, and no
//! trace runs.

const std = @import("std");
const interp = @import("../interp.zig");
const bytecode = @import("../bytecode.zig");
const coroutine = @import("../coroutine.zig");
const breakpoints = @import("breakpoints.zig");

const Vm = interp.Vm;
const Proto = bytecode.Proto;
const Error = interp.Error;
const Value = @import("../value.zig").Value;

/// The bits of `DebugHooks.flags`. Any set bit makes every prologue call
/// the check, so a bit stays set only while its event is outstanding.
pub const Flags = struct {
    /// Stop at the next stoppable point (a `pause` request, or the entry
    /// stop).
    pub const pause: u32 = 1 << 0;
    /// End the program at the next prologue (`terminate`, `disconnect`).
    pub const terminate: u32 = 1 << 1;
    /// The transport holds requests that arrived while the program ran.
    pub const requests: u32 = 1 << 2;
    /// Some breakpoint is set, bound or pending: test every prologue's pc,
    /// and watch for chunks loading.
    pub const breakpoints: u32 = 1 << 3;
};

/// Why the program stopped: DAP's `stopped` reasons the session produces.
pub const Reason = enum {
    /// The first stoppable point, with `Options.stop_on_entry`.
    entry,
    /// A `pause` request.
    pause,
    /// A line breakpoint (§5.2); `Stop.hits` names it.
    breakpoint,
    /// The program has returned, exited or died of an uncaught error
    /// (§5.5). The VM is idle; nothing runs after this stop.
    ended,
};

pub const Stop = struct {
    reason: Reason,
    /// How the program ended, for `.ended`: null when it returned.
    err: ?Error = null,
    /// For `.breakpoint`, the ids of the breakpoints bound at this pc.
    /// Valid during the stop only.
    hits: []const u32 = &.{},
};

/// What the driver says to do when a stop returns.
pub const Resume = enum {
    @"continue",
    /// End the program, as `terminate` or `disconnect` does.
    terminate,
};

/// The transport's side of the session.
pub const Driver = struct {
    ctx: *anyopaque,
    /// The program is stopped in place. Inspect it through the session,
    /// then say how to go on; the VM waits until this returns.
    stopped: *const fn (ctx: *anyopaque, s: *Session, stop: Stop) Resume,
    /// `notifyRequests` was called while the program ran: take the
    /// requests that came in meanwhile. The program is between two
    /// instructions; nothing here may run guest code.
    requests: ?*const fn (ctx: *anyopaque, s: *Session) void = null,
    /// A breakpoint's binding changed without a `setBreakpoints`: a chunk
    /// with its source loaded, so a pending breakpoint is now verified
    /// (DAP's `breakpoint` event, reason `changed`).
    breakpoint_changed: ?*const fn (ctx: *anyopaque, s: *Session, bp: Breakpoint) void = null,
};

pub const BreakpointRequest = breakpoints.Request;
pub const Breakpoint = breakpoints.Breakpoint;

pub const Options = struct {
    /// Stop at the first stoppable point (DAP's `stopOnEntry`).
    stop_on_entry: bool = false,
};

/// A stopped program's position: the instruction about to run, in the
/// running coroutine's top frame.
pub const Location = struct {
    proto: *const Proto,
    pc: usize,

    /// The source line, or 0 for an instruction with no span.
    pub fn line(self: Location) u32 {
        return if (self.pc < self.proto.spans.len) self.proto.spans[self.pc].line else 0;
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    vm: *Vm,
    driver: Driver,
    hooks: interp.DebugHooks,
    /// The position while the program is stopped, else null.
    stopped_at: ?Location = null,
    /// The next stop for `Flags.pause` reports `.entry`.
    entry_pending: bool = false,
    breakpoints: breakpoints.Table,
    /// How many of `vm.loaded_chunks` the breakpoint table has indexed.
    /// Every chunk the VM compiles at runtime, a keyframe restore's
    /// included, is appended there (`Vm.appendLoadedChunk`), so a longer
    /// list is the signal that a chunk loaded.
    chunks_seen: usize = 0,
    /// Scratch for the bindings a chunk load changed.
    changed: std.ArrayList(Breakpoint) = .empty,

    /// Attach to `vm`, which must be idle and not already debugged. The
    /// session must stay where it is until `detach` (the VM points at it).
    /// `gpa` holds the session's own tables, never the VM heap.
    pub fn attach(self: *Session, gpa: std.mem.Allocator, vm: *Vm, driver: Driver, opts: Options) void {
        std.debug.assert(vm.debug == null);
        self.* = .{
            .gpa = gpa,
            .vm = vm,
            .driver = driver,
            .hooks = .{ .ctx = self, .check = &check },
            .entry_pending = opts.stop_on_entry,
            .breakpoints = .init(gpa),
        };
        if (opts.stop_on_entry) self.hooks.flags.store(Flags.pause, .release);
        vm.trace.raiseSuspend();
        vm.debug = &self.hooks;
    }

    /// Detach from the VM, which then runs undebugged again. Not while the
    /// program is stopped.
    pub fn detach(self: *Session) void {
        std.debug.assert(self.stopped_at == null);
        std.debug.assert(self.vm.debug == &self.hooks);
        self.vm.debug = null;
        self.vm.trace.lowerSuspend();
        self.breakpoints.deinit();
        self.changed.deinit(self.gpa);
    }

    /// Run `proto` as the program, to its end, then make the end stop
    /// (§5.5). Returns what `Vm.run` returned, so a host can report it the
    /// way an undebugged run would; `Error.DebugTerminated` when the client
    /// ended the program, which makes no end stop.
    pub fn run(self: *Session, proto: *const Proto) Error!Value {
        try self.addChunk(proto);
        const result = self.vm.run(proto);
        if (result) |_| {
            _ = self.stopAtEnd(null);
        } else |err| {
            if (err == Error.DebugTerminated) {
                // The terminate is spent; the VM is idle and may run again.
                self.hooks.flags.store(0, .release);
                return err;
            }
            _ = self.stopAtEnd(err);
        }
        return result;
    }

    /// Ask the program to stop at its next stoppable point. Safe from any
    /// thread.
    pub fn requestPause(self: *Session) void {
        _ = self.hooks.flags.fetchOr(Flags.pause, .acq_rel);
    }

    /// Ask the program to end at its next prologue. Safe from any thread.
    pub fn requestTerminate(self: *Session) void {
        _ = self.hooks.flags.fetchOr(Flags.terminate, .acq_rel);
    }

    /// Tell the session the transport holds requests for it, which it
    /// takes at the next prologue (`Driver.requests`). Safe from any
    /// thread.
    pub fn notifyRequests(self: *Session) void {
        _ = self.hooks.flags.fetchOr(Flags.requests, .acq_rel);
    }

    /// Replace the line breakpoints of `source` (a chunk name, §5.2) and
    /// write each one's binding to `out`, which is as long as `requests`.
    /// While stopped, or from `Driver.requests`.
    pub fn setBreakpoints(self: *Session, source: []const u8, requests: []const BreakpointRequest, out: []Breakpoint) Error!void {
        try self.syncChunks();
        try self.breakpoints.set(source, requests, out);
        if (self.breakpoints.isEmpty())
            _ = self.hooks.flags.fetchAnd(~Flags.breakpoints, .acq_rel)
        else
            _ = self.hooks.flags.fetchOr(Flags.breakpoints, .acq_rel);
    }

    /// Index one chunk for the breakpoint table, and report the
    /// breakpoints it binds.
    fn addChunk(self: *Session, root: *const Proto) Error!void {
        if (self.breakpoints.hasChunk(root)) return;
        self.changed.clearRetainingCapacity();
        try self.breakpoints.addChunk(root, &self.changed);
        if (self.driver.breakpoint_changed) |f| {
            for (self.changed.items) |bp| f(self.driver.ctx, self, bp);
        }
    }

    /// Index the chunks the VM has compiled since the last call.
    fn syncChunks(self: *Session) Error!void {
        if (self.vm.root_chunk) |rc| try self.addChunk(rc.chunk.proto);
        const loaded = self.vm.loaded_chunks.items;
        while (self.chunks_seen < loaded.len) : (self.chunks_seen += 1) {
            try self.addChunk(loaded[self.chunks_seen].chunk.proto);
        }
    }

    fn stopAtEnd(self: *Session, err: ?Error) Resume {
        // The run is over, so a pause or terminate asked for late has
        // nothing left to act on.
        self.hooks.flags.store(0, .release);
        return self.driver.stopped(self.driver.ctx, self, .{ .reason = .ended, .err = err });
    }

    /// A point the program may stop at (§5.1): any prologue outside the
    /// VM's own code. A native's re-entry is stoppable, because a stop is
    /// in place; a keyframe suspend's `canSuspendHere` is not the test.
    fn stoppable(proto: *const Proto) bool {
        return !proto.system and proto.id != coroutine.native_body_proto_id;
    }

    fn check(ctx: *anyopaque, vm: *Vm, proto: *const Proto, pc: usize) Error!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        std.debug.assert(vm == self.vm);
        var f = self.hooks.flags.load(.acquire);
        if (f & Flags.requests != 0) {
            // Cleared before the drain, so a request that arrives during it
            // sets the bit again and is taken at the next prologue.
            _ = self.hooks.flags.fetchAnd(~Flags.requests, .acq_rel);
            if (self.driver.requests) |take| take(self.driver.ctx, self);
            f = self.hooks.flags.load(.acquire);
        }
        if (f & Flags.terminate != 0) return Error.DebugTerminated;
        if (!stoppable(proto)) return;
        var hits: ?[]const u32 = null;
        if (f & Flags.breakpoints != 0) {
            if (self.chunks_seen != vm.loaded_chunks.items.len) try self.syncChunks();
            hits = try self.breakpoints.at(proto, pc);
        }
        // One stop per prologue: a breakpoint here also answers a pause.
        if (hits != null or f & Flags.pause != 0) {
            if (f & Flags.pause != 0) _ = self.hooks.flags.fetchAnd(~Flags.pause, .acq_rel);
            const reason: Reason = if (hits != null) .breakpoint else if (self.entry_pending) .entry else .pause;
            self.entry_pending = false;
            try self.stop(.{ .reason = reason, .hits = hits orelse &.{} }, .{ .proto = proto, .pc = pc });
        }
    }

    fn stop(self: *Session, s: Stop, at: Location) Error!void {
        self.stopped_at = at;
        const r = self.driver.stopped(self.driver.ctx, self, s);
        self.stopped_at = null;
        switch (r) {
            .@"continue" => {},
            .terminate => return Error.DebugTerminated,
        }
    }
};
