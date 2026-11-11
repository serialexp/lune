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
};

/// Why the program stopped: DAP's `stopped` reasons the session produces.
pub const Reason = enum {
    /// The first stoppable point, with `Options.stop_on_entry`.
    entry,
    /// A `pause` request.
    pause,
    /// The program has returned, exited or died of an uncaught error
    /// (§5.5). The VM is idle; nothing runs after this stop.
    ended,
};

pub const Stop = struct {
    reason: Reason,
    /// How the program ended, for `.ended`: null when it returned.
    err: ?Error = null,
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
};

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
    vm: *Vm,
    driver: Driver,
    hooks: interp.DebugHooks,
    /// The position while the program is stopped, else null.
    stopped_at: ?Location = null,
    /// The next stop for `Flags.pause` reports `.entry`.
    entry_pending: bool = false,

    /// Attach to `vm`, which must be idle and not already debugged. The
    /// session must stay where it is until `detach` (the VM points at it).
    pub fn attach(self: *Session, vm: *Vm, driver: Driver, opts: Options) void {
        std.debug.assert(vm.debug == null);
        self.* = .{
            .vm = vm,
            .driver = driver,
            .hooks = .{ .ctx = self, .check = &check },
            .entry_pending = opts.stop_on_entry,
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
    }

    /// Run `proto` as the program, to its end, then make the end stop
    /// (§5.5). Returns what `Vm.run` returned, so a host can report it the
    /// way an undebugged run would; `Error.DebugTerminated` when the client
    /// ended the program, which makes no end stop.
    pub fn run(self: *Session, proto: *const Proto) Error!Value {
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
        if (f & Flags.pause != 0 and stoppable(proto)) {
            _ = self.hooks.flags.fetchAnd(~Flags.pause, .acq_rel);
            const reason: Reason = if (self.entry_pending) .entry else .pause;
            self.entry_pending = false;
            try self.stop(.{ .reason = reason }, .{ .proto = proto, .pc = pc });
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
