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
const eval = @import("eval.zig");

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
    /// A step is under way (`Session.stepping`).
    pub const step: u32 = 1 << 4;
    /// The error in flight was seen (`DebugHooks.raise_seen`); the next
    /// prologue clears both.
    pub const raise_seen: u32 = interp.DebugHooks.flag_raise_seen;
};

/// Why the program stopped: DAP's `stopped` reasons the session produces.
pub const Reason = enum {
    /// The first stoppable point, with `Options.stop_on_entry`.
    entry,
    /// A `pause` request.
    pause,
    /// A line breakpoint (§5.2); `Stop.hits` names it.
    breakpoint,
    /// A step finished (§5.3).
    step,
    /// An error was raised that the exception filters admit (§5.4);
    /// `Stop.exception` describes it.
    exception,
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
    /// For `.exception`, the error. Valid during the stop only.
    exception: ?Exception = null,
};

/// An error stop's error (DAP's `exceptionInfo`).
pub const Exception = struct {
    /// The error as its catcher will see it: the message of a raised
    /// string, or the text of a runtime fault with its location. A raised
    /// table is rendered by type, since no `__tostring` may run.
    text: []const u8,
    /// Something will catch it (§5.4 `caught`), or nothing will.
    caught: bool,
    err: Error,
    /// The raised value, when one exists already (`error(v)`); a runtime
    /// fault's value is made by its catcher.
    value: ?Value,
};

/// `setExceptionBreakpoints`' two filters (§5.4).
pub const ExceptionFilters = struct {
    /// Uncaught errors, on by default.
    uncaught: bool = true,
    /// Errors something catches: `pcall`, `xpcall`, a coroutine's resume.
    caught: bool = false,
};

/// What the driver says to do when a stop returns.
pub const Resume = union(enum) {
    @"continue",
    /// Run until the step stops (§5.3). A breakpoint or a pause that comes
    /// first stops instead, and ends the step.
    step: Step,
    /// End the program, as `terminate` or `disconnect` does.
    terminate,
};

/// DAP's `stepIn`, `next` and `stepOut`.
pub const StepKind = enum { in, over, out };

/// DAP's `granularity`. A statement is a line here.
pub const Granularity = enum {
    /// Stop where a line visit begins (`LineVisits`).
    line,
    /// Stop at the next stoppable instruction, under the same rules.
    instruction,
};

pub const Step = struct {
    kind: StepKind,
    granularity: Granularity = .line,
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
    /// A message for the client's console (DAP's `output` event, category
    /// `console`): a breakpoint condition that cannot be evaluated.
    console: ?*const fn (ctx: *anyopaque, s: *Session, text: []const u8) void = null,
};

pub const BreakpointRequest = breakpoints.Request;
pub const Breakpoint = breakpoints.Breakpoint;

pub const Options = struct {
    /// Stop at the first stoppable point (DAP's `stopOnEntry`).
    stop_on_entry: bool = false,
};

/// A stopped program's position: the instruction about to run, or the
/// one that raised, in a frame of the running coroutine.
pub const Location = struct {
    proto: *const Proto,
    pc: usize,
    /// The frame's index in the running coroutine's frames: the top one,
    /// except at an error raised inside the VM's own code, where it is the
    /// topmost frame of the program's.
    frame: u32,

    /// The source line, or 0 for an instruction with no span.
    pub fn line(self: Location) u32 {
        return if (self.pc < self.proto.spans.len) self.proto.spans[self.pc].line else 0;
    }
};

/// Doc 86 §5.3: where a *line visit* begins. A stoppable pc starts one
/// when the previous instruction its activation ran was on another line,
/// or was a back-edge (at or past this pc, as in `for i = 1, 3 do f(i)
/// end`, where each pass is a new visit). A breakpoint stops at the start
/// of a visit to its line, and so will a step.
///
/// The test sees only the prologues the check runs at, so `reset` must be
/// called whenever the check stops running at every prologue (all flags
/// cleared): the next observation then falls back to the static
/// predecessor, as it does when a call returns into the frame.
pub const LineVisits = struct {
    /// The activation (`CallFrame.call_seq`, plus its proto, which a tail
    /// call replaces in place) and pc of the last prologue observed.
    last_seq: u64 = 0,
    last_proto: ?*const Proto = null,
    last_pc: usize = 0,

    pub fn reset(self: *LineVisits) void {
        self.last_proto = null;
    }

    /// Observe the prologue of `pc` in activation `seq`, and say whether
    /// it starts a visit to its line.
    pub fn observe(self: *LineVisits, seq: u64, proto: *const Proto, pc: usize) bool {
        const line = lineOf(proto, pc);
        const same = self.last_proto == proto and self.last_seq == seq;
        const fresh = if (line == 0)
            false
        else if (same)
            pc <= self.last_pc or lineOf(proto, self.last_pc) != line
        else
            // Entered the frame (pc 0), or came back to it from a call, a
            // resumed coroutine's yield, or an unobserved stretch: the
            // instruction before this one is its predecessor.
            pc == 0 or lineOf(proto, pc - 1) != line;
        self.last_seq = seq;
        self.last_proto = proto;
        self.last_pc = pc;
        return fresh;
    }

    fn lineOf(proto: *const Proto, pc: usize) u32 {
        return if (pc < proto.spans.len) proto.spans[pc].line else 0;
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
    visits: LineVisits = .{},
    /// The evaluator's scratch, reset at every evaluation.
    eval_arena: std.heap.ArenaAllocator,
    /// The ids of the breakpoints that stop at this pc.
    passing: std.ArrayList(u32) = .empty,
    /// The step under way, while `Flags.step` is set.
    stepping: ?Stepping = null,
    exception_filters: ExceptionFilters = .{},
    /// The protected calls made in Zig that are running
    /// (`DebugHooks.protect_enter`), innermost last.
    protects: std.ArrayList(Protect) = .empty,
    /// An error stop's text, reset at each one.
    stop_arena: std.heap.ArenaAllocator,

    /// A protected call made in Zig: on coroutine `co` (a header id, 0 for
    /// the main stack), entered at frame depth `depth`.
    const Protect = struct { co: u32, depth: u32 };

    /// Where a step started (§5.3): the coroutine `C` and the depth `D` of
    /// its frame. `C` is named by its header id, 0 for the main stack, so
    /// the step never holds a pointer to a coroutine that may die and be
    /// collected before the step ends.
    const Stepping = struct {
        step: Step,
        co: u32,
        depth: usize,
    };

    /// Attach to `vm`, which must be idle and not already debugged. The
    /// session must stay where it is until `detach` (the VM points at it).
    /// `gpa` holds the session's own tables, never the VM heap.
    pub fn attach(self: *Session, gpa: std.mem.Allocator, vm: *Vm, driver: Driver, opts: Options) void {
        std.debug.assert(vm.debug == null);
        self.* = .{
            .gpa = gpa,
            .vm = vm,
            .driver = driver,
            .hooks = .{
                .ctx = self,
                .check = &check,
                .raise = &raise,
                .protect_enter = &protectEnter,
                .protect_leave = &protectLeave,
            },
            .entry_pending = opts.stop_on_entry,
            .breakpoints = .init(gpa),
            .eval_arena = .init(gpa),
            .stop_arena = .init(gpa),
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
        self.eval_arena.deinit();
        self.passing.deinit(self.gpa);
        std.debug.assert(self.protects.items.len == 0);
        self.protects.deinit(self.gpa);
        self.stop_arena.deinit();
    }

    /// Set which errors stop (`setExceptionBreakpoints`). While stopped, or
    /// from `Driver.requests`.
    pub fn setExceptionFilters(self: *Session, filters: ExceptionFilters) void {
        self.exception_filters = filters;
    }

    /// Evaluate `expression` in the stopped program's frame (§7.3): the
    /// stop's, or the top one while a breakpoint's condition is tested.
    /// The outcome's text lives until the next evaluation.
    pub fn evaluate(self: *Session, expression: []const u8) Error!eval.Outcome {
        _ = self.eval_arena.reset(.retain_capacity);
        const scope: eval.Scope = if (self.stopped_at) |at| .ofFrame(self.vm, at.frame) else .top(self.vm);
        return eval.evaluate(self.eval_arena.allocator(), self.vm, scope, expression);
    }

    /// Run `proto` as the program, to its end, then make the end stop
    /// (§5.5). Returns what `Vm.run` returned, so a host can report it the
    /// way an undebugged run would; `Error.DebugTerminated` when the client
    /// ended the program, which makes no end stop.
    pub fn run(self: *Session, proto: *const Proto) Error!Value {
        try self.addChunk(proto);
        const result = self.vm.run(proto);
        // A terminate the client chose at an error stop (`raise`) that no
        // prologue came to act on: the error ended the run first.
        const terminated = if (result) |_| false else |err| err == Error.DebugTerminated;
        if (terminated or self.hooks.flags.load(.acquire) & Flags.terminate != 0) {
            // The terminate is spent; the VM is idle and may run again.
            self.hooks.flags.store(0, .release);
            self.hooks.raise_seen = false;
            self.stepping = null;
            return Error.DebugTerminated;
        }
        if (result) |_| {
            _ = self.stopAtEnd(null);
        } else |err| {
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
        // The run is over, so a pause, terminate or step asked for late
        // has nothing left to act on.
        self.hooks.flags.store(0, .release);
        self.hooks.raise_seen = false;
        self.stepping = null;
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
        if (f & Flags.raise_seen != 0) {
            // Guest code runs again: an error raised from here on is new.
            self.hooks.raise_seen = false;
            _ = self.hooks.flags.fetchAnd(~Flags.raise_seen, .acq_rel);
            f &= ~Flags.raise_seen;
        }
        if (f & Flags.requests != 0) {
            // Cleared before the drain, so a request that arrives during it
            // sets the bit again and is taken at the next prologue.
            _ = self.hooks.flags.fetchAnd(~Flags.requests, .acq_rel);
            if (self.driver.requests) |take| take(self.driver.ctx, self);
            f = self.hooks.flags.load(.acquire);
        }
        if (f & Flags.terminate != 0) {
            self.stepping = null;
            return Error.DebugTerminated;
        }
        defer if (self.hooks.flags.load(.acquire) == 0) self.visits.reset();
        std.debug.assert(vm.depth > 0 and vm.frames[vm.depth - 1].closure.proto == proto);
        const fresh = self.visits.observe(vm.frames[vm.depth - 1].call_seq, proto, pc);
        if (!stoppable(proto)) return;
        var hits: ?[]const u32 = null;
        if (f & Flags.breakpoints != 0) {
            if (self.chunks_seen != vm.loaded_chunks.items.len) try self.syncChunks();
            if (fresh) if (try self.breakpoints.at(proto, pc)) |ids| {
                hits = try self.admit(ids);
            };
        }
        const stepped = f & Flags.step != 0 and self.stepDone(fresh);
        // One stop per prologue: a breakpoint here also answers a pause or
        // ends a step, and a pause ends a step.
        if (hits != null or f & Flags.pause != 0 or stepped) {
            if (f & Flags.pause != 0) _ = self.hooks.flags.fetchAnd(~Flags.pause, .acq_rel);
            const reason: Reason = if (hits != null)
                .breakpoint
            else if (f & Flags.pause != 0)
                (if (self.entry_pending) .entry else .pause)
            else
                .step;
            self.entry_pending = false;
            try self.stop(.{ .reason = reason, .hits = hits orelse &.{} }, .{ .proto = proto, .pc = pc, .frame = vm.depth - 1 });
        }
    }

    /// The header id of the running coroutine, 0 for the main stack.
    fn runningId(vm: *const Vm) u32 {
        return if (vm.current) |t| t.header.id else 0;
    }

    /// Whether coroutine `id` is on the running chain: it runs, or it is
    /// `normal`, waiting on a coroutine it resumed. Walks the live chain
    /// only, so it never touches a coroutine that has died.
    fn onChain(vm: *const Vm, id: u32) bool {
        if (id == 0) return true; // the main stack is the chain's root
        var t = vm.current;
        while (t) |th| : (t = th.resumer) {
            if (th.header.id == id) return true;
        }
        return false;
    }

    /// Whether the step under way stops at this stoppable pc (§5.3).
    /// `fresh` says whether the pc starts a line visit.
    fn stepDone(self: *Session, fresh: bool) bool {
        const s = self.stepping orelse return false;
        const vm = self.vm;
        const visit = fresh or s.step.granularity == .instruction;
        if (runningId(vm) != s.co) {
            // C yielded, finished or died out to its resumer: stop at the
            // first stoppable pc, so a step never turns into a continue.
            if (!onChain(vm, s.co)) return true;
            // C waits on a coroutine it resumed, as a call deeper down.
            return s.step.kind == .in and visit;
        }
        // The step's frame returned, or an error unwound past it: stop at
        // the first stoppable pc in the frame below.
        if (vm.depth < s.depth) return true;
        return switch (s.step.kind) {
            .in => visit,
            .over => visit and vm.depth == s.depth,
            .out => false,
        };
    }

    /// The breakpoints among `ids` that stop: those whose condition holds
    /// and whose hit condition admits this hit. Null for none.
    fn admit(self: *Session, ids: []const u32) Error!?[]const u32 {
        self.passing.clearRetainingCapacity();
        for (ids) |id| {
            const e = self.breakpoints.entry(id) orelse continue;
            if (e.condition) |c| {
                const holds = switch (try self.evaluate(c)) {
                    .ok => |v| v.truthy(),
                    .refused, .failed => |msg| blk: {
                        // Counts as false, and is reported once (§5.2).
                        if (!e.condition_reported) {
                            e.condition_reported = true;
                            if (self.driver.console) |f| {
                                const text = try std.fmt.allocPrint(self.eval_arena.allocator(), "breakpoint condition `{s}`: {s}", .{ c, msg });
                                f(self.driver.ctx, self, text);
                            }
                        }
                        break :blk false;
                    },
                };
                if (!holds) continue;
            }
            e.hits += 1;
            if (e.hit_condition) |hc| if (!hc.admits(e.hits)) continue;
            try self.passing.append(self.gpa, id);
        }
        return if (self.passing.items.len == 0) null else self.passing.items;
    }

    fn protectEnter(ctx: *anyopaque, vm: *Vm) Error!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        try self.protects.append(self.gpa, .{ .co = runningId(vm), .depth = vm.depth });
    }

    fn protectLeave(ctx: *anyopaque, _: *Vm) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        _ = self.protects.pop().?;
    }

    /// §5.4: a catchable error is leaving an instruction or a native, its
    /// frames still live. Stop if the filters admit it.
    fn raise(ctx: *anyopaque, vm: *Vm, err: Error, value: ?Value) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        std.debug.assert(vm == self.vm);
        const filters = self.exception_filters;
        if (!filters.caught and !filters.uncaught) return;
        const caught = self.raiseCaught();
        if (!(if (caught) filters.caught else filters.uncaught)) return;
        // The topmost frame of the program's own code: an error a native
        // raises from inside the VM's code (a coroutine's native body)
        // stops at its caller. With none on this stack, there is nowhere
        // to stop.
        const fi: u32 = blk: {
            var i = vm.depth;
            while (i > 0) {
                i -= 1;
                if (stoppable(vm.frames[i].closure.proto)) break :blk i;
            }
            return;
        };
        const fr = &vm.frames[fi];
        _ = self.stop_arena.reset(.retain_capacity);
        const a = self.stop_arena.allocator();
        const text = (if (value) |v| Vm.renderErrorValue(v, a) else vm.faultText(err, a)) catch "(out of memory describing the error)";
        const ex: Exception = .{ .text = text, .caught = caught, .err = err, .value = value orelse vm.pending_error };
        self.stop(.{ .reason = .exception, .exception = ex }, .{ .proto = fr.closure.proto, .pc = fr.pc, .frame = fi }) catch |e| {
            // The client ended the program. The catchers run as they would
            // undebugged; the next prologue, or `run`, ends it.
            std.debug.assert(e == Error.DebugTerminated);
            self.requestTerminate();
        };
    }

    /// Whether something will catch the error in flight (§5.4). It walks
    /// the running chain from the running coroutine to the main stack:
    /// a protected frame (`pcall`/`xpcall` from an instruction) or a
    /// protected call made in Zig on a stack catches it. A coroutine with
    /// neither dies of it, and its resume returns it, which is a catch;
    /// a `wrap` function raises it again in the resumer, where the walk
    /// goes on. Reads frames only.
    fn raiseCaught(self: *Session) bool {
        const vm = self.vm;
        var ctx: ?*coroutine.Thread = vm.current;
        while (true) {
            const id: u32 = if (ctx) |t| t.header.id else 0;
            const frames: []const interp.CallFrame = if (ctx == vm.current)
                vm.frames[0..vm.depth]
            else blk: {
                const sv = coroutine.savedOf(vm, ctx);
                break :blk sv.frames[0..sv.depth];
            };
            // From the raise down, so the nearest catcher ends the walk.
            var i = frames.len;
            while (i > 0) {
                i -= 1;
                if (frames[i].ctl.protect != .none) return true;
            }
            var k = self.protects.items.len;
            while (k > 0) {
                k -= 1;
                const pr = self.protects.items[k];
                if (pr.co == id and pr.depth <= frames.len) return true;
            }
            const t = ctx orelse return false;
            if (!t.wrapped) return true;
            ctx = t.resumer;
        }
    }

    fn stop(self: *Session, s: Stop, at: Location) Error!void {
        // Any stop ends the step under way.
        self.stepping = null;
        _ = self.hooks.flags.fetchAnd(~Flags.step, .acq_rel);
        self.stopped_at = at;
        const r = self.driver.stopped(self.driver.ctx, self, s);
        self.stopped_at = null;
        switch (r) {
            .@"continue" => {},
            .step => |st| {
                self.stepping = .{ .step = st, .co = runningId(self.vm), .depth = self.vm.depth };
                _ = self.hooks.flags.fetchOr(Flags.step, .acq_rel);
            },
            .terminate => return Error.DebugTerminated,
        }
    }
};
