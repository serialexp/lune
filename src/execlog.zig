//! Trace **execution log** — the in-memory recorder for the tier-1a IR-interpreter
//! (`irinterp.zig`). The executor runs *all* hot iterations of a cached trace in one
//! call and returns only a `completed` count; it records nothing. This module is the
//! observation layer the visualizer animates: for **every trace entry / exit ramp**
//! it captures the spinning iterations (capped) and the side-exit that ended them.
//!
//! It is the fourth record family after the trace cache (`traceser`), keyframes
//! (`keyframeser`), and the effect log (`effectser`) — an *observation* log, not a
//! replay input: nothing feeds it back, so it has no version/replay contract of its
//! own beyond the wire format (`execlogser.zig`).
//!
//! ## Recording shape
//!
//! One `TraceEntry` per `irinterp.execute` call (every exit ramp). Within an entry,
//! a flat `ExecEvent` stream: a `value` per non-guard instruction, a `guard_pass`
//! per surviving guard, a `commit` per loop close, and a terminal `exit` naming the
//! instruction that side-exited. Two caps keep it bounded (`02`/`04` "megabytes not
//! gigabytes"): `max_iters` truncates the per-entry detail (the `exit` is *always*
//! kept past the cap, and `iterations` stays accurate), and `max_entries` bounds how
//! many entries a single trace records. Both are surfaced as `capped` flags, never
//! silent.
//!
//! ## Zero cost when off
//!
//! The executor is `comptime`-specialized: `execute` (record=false) compiles with no
//! recorder calls at all (the JIT fast path is untouched); `executeTraced`
//! (record=true) drives an `*ExecLogRecorder`. So this module exists only on the
//! instrumented (viz/CLI) path.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

/// The kind of an `ExecEvent`. A guard *failure* is folded into `exit` (a failing
/// guard is exactly the instruction that side-exits), so a guard only ever emits
/// `guard_pass`; the terminal `exit` carries the faulting ref.
pub const ExecEventKind = enum(u8) {
    /// A non-guard instruction produced a value: `ref` = SSA index, `value` = result.
    value = 0,
    /// A guard survived: `ref` = guard's SSA index, `value` = the checked operand.
    guard_pass = 1,
    /// A loop back-edge committed (one iteration closed). `ref`/`value` unused.
    commit = 2,
    /// The entry side-exited: `ref` = the faulting instruction. Terminal for the
    /// entry. `value` is the failing guard's operand, or nil for an arith error.
    exit = 3,
};

/// Why an entry's loop terminated — the "exit ramp" classification, stored on the
/// `TraceEntry` for the summary view (the specific guard variant is recoverable from
/// `instrs[exit_ref].op`).
pub const ExitKind = enum(u8) {
    /// A type/truth guard failed (the common case: the loop-condition guard).
    guard = 0,
    /// An arithmetic error (integer `//`/`%` by zero) side-exited mid-iteration.
    arith = 1,
    /// The trace fell through without a `loop` close (a malformed trace; the
    /// executor's safety-net return). Should not happen for a committed trace.
    clean = 2,
};

/// One recorded execution event (in-memory; serialized to `schema.ExecEvent`, its
/// `value` mapped to an `EffectResult`).
pub const ExecEvent = struct {
    kind: ExecEventKind,
    ref: u32 = 0,
    value: Value = Value.nil(),
};

/// One trace entry = one `irinterp.execute` call: the iterations it spun and the
/// exit ramp that ended it. `events` is owned (freed by `TraceExecLog.deinit`).
pub const TraceEntry = struct {
    /// Iterations that committed cleanly (the executor's yield) — accurate even when
    /// `capped` truncated the per-iteration detail.
    iterations: u32 = 0,
    /// SSA index of the instruction that side-exited (faulting guard / arith op).
    exit_ref: u32 = 0,
    exit_kind: ExitKind = .clean,
    /// The per-entry `events` stream was truncated at `max_iters` (the `exit` event
    /// is still present).
    capped: bool = false,
    events: []ExecEvent = &.{},
};

/// All recorded entries for one cached trace, keyed by `trace_id` (the trace's index
/// in `TraceState.cache`, which is also the viz's selection key).
pub const TraceExecLog = struct {
    trace_id: u32,
    /// `max_entries` was reached; further entries for this trace were not recorded.
    entries_capped: bool = false,
    entries: std.ArrayListUnmanaged(TraceEntry) = .empty,

    pub fn deinit(self: *TraceExecLog, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*e| gpa.free(e.events);
        self.entries.deinit(gpa);
    }
};

/// Drives recording for one cached trace. Owned by `TraceState`; re-targeted at the
/// trace's `TraceExecLog` before each `executeTraced` call. The per-entry `scratch`
/// buffer is reused across entries (capacity retained) so steady-state recording
/// allocates nothing per event beyond amortized growth.
pub const ExecLogRecorder = struct {
    gpa: std.mem.Allocator,
    /// Detail cap: stop appending iteration events once this many iterations have
    /// committed in the current entry (the `exit` is still recorded).
    max_iters: u32,
    /// Entry cap: stop recording new entries for a trace beyond this many.
    max_entries: u32,

    /// The log the current/next entry appends to (set by `retarget`).
    log: ?*TraceExecLog = null,
    /// Per-entry event scratch, reused across entries.
    scratch: std.ArrayListUnmanaged(ExecEvent) = .empty,
    /// True while the current entry is being recorded (false if the entry cap was
    /// hit at `begin`, in which case all event calls are no-ops).
    active: bool = false,
    /// Committed-iteration counter for the current entry (drives `max_iters`).
    iters: u32 = 0,
    /// Detail truncated for the current entry (`iters >= max_iters`).
    detail_done: bool = false,
    exit_ref: u32 = 0,
    exit_kind: ExitKind = .clean,

    pub fn init(gpa: std.mem.Allocator, max_iters: u32, max_entries: u32) ExecLogRecorder {
        return .{ .gpa = gpa, .max_iters = max_iters, .max_entries = max_entries };
    }

    pub fn deinit(self: *ExecLogRecorder) void {
        self.scratch.deinit(self.gpa);
    }

    /// Point the recorder at `log` for the next entry.
    pub fn retarget(self: *ExecLogRecorder, log: *TraceExecLog) void {
        self.log = log;
    }

    /// Start a new entry. If the trace already has `max_entries`, the entry is not
    /// recorded (the log is flagged `entries_capped`) and event calls are inert.
    pub fn begin(self: *ExecLogRecorder) void {
        const log = self.log orelse return;
        if (log.entries.items.len >= self.max_entries) {
            log.entries_capped = true;
            self.active = false;
            return;
        }
        self.active = true;
        self.iters = 0;
        self.detail_done = false;
        self.exit_ref = 0;
        self.exit_kind = .clean;
        self.scratch.clearRetainingCapacity();
    }

    /// Record a non-guard instruction's result. Inert past the detail cap.
    pub fn value(self: *ExecLogRecorder, ref: usize, v: Value) void {
        if (!self.active or self.detail_done) return;
        self.scratch.append(self.gpa, .{ .kind = .value, .ref = @intCast(ref), .value = v }) catch {};
    }

    /// Record a surviving guard (its checked operand). Inert past the detail cap.
    pub fn guardPass(self: *ExecLogRecorder, ref: usize, operand: Value) void {
        if (!self.active or self.detail_done) return;
        self.scratch.append(self.gpa, .{ .kind = .guard_pass, .ref = @intCast(ref), .value = operand }) catch {};
    }

    /// Record a loop close (one iteration committed). Counts toward the detail cap;
    /// the `commit` event itself is dropped once truncated, but `iterations` keeps
    /// counting so the entry's yield stays accurate.
    pub fn commit(self: *ExecLogRecorder) void {
        if (!self.active) return;
        if (!self.detail_done) self.scratch.append(self.gpa, .{ .kind = .commit }) catch {};
        self.iters += 1;
        if (self.iters >= self.max_iters) self.detail_done = true;
    }

    /// Record the terminal side-exit. Always appended (even past the detail cap), so
    /// the exit ramp is never lost.
    pub fn exit(self: *ExecLogRecorder, ref: usize, kind: ExitKind, operand: Value) void {
        if (!self.active) return;
        self.exit_ref = @intCast(ref);
        self.exit_kind = kind;
        self.scratch.append(self.gpa, .{ .kind = .exit, .ref = @intCast(ref), .value = operand }) catch {};
    }

    /// Finalize the entry with the executor's `completed` yield, copying the scratch
    /// events into an owned slice appended to the log. A no-op if the entry was not
    /// recorded (entry cap) or there is no target log.
    pub fn end(self: *ExecLogRecorder, completed: usize) void {
        if (!self.active) return;
        self.active = false;
        const log = self.log orelse return;
        const events = self.gpa.dupe(ExecEvent, self.scratch.items) catch return;
        log.entries.append(self.gpa, .{
            .iterations = @intCast(completed),
            .exit_ref = self.exit_ref,
            .exit_kind = self.exit_kind,
            .capped = self.detail_done,
            .events = events,
        }) catch {
            self.gpa.free(events);
        };
    }
};
