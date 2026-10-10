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
const string = @import("string.zig");
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

/// A recorded event value, detached from the VM heap (doc 61 §7.1 item 7). Trace
/// pools are not GC roots, so a string the log merely *referenced* could be swept
/// while the log still describes it; the log therefore copies string bytes at log
/// time and owns them. `string` is owned by whoever owns the enclosing `ExecEvent`
/// (the recorder's scratch, then the completed `TraceEntry`).
pub const LogValue = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    string: []u8,

    /// Detach `v` from the heap: scalars copy, a heap string dupes its bytes.
    /// Returns null for a value the log cannot represent (a non-string heap object
    /// or a grid row handle — intermediate IR artifacts the viz doesn't need) and
    /// for a failed byte copy; either way the caller drops the event.
    pub fn of(gpa: std.mem.Allocator, v: Value) ?LogValue {
        return switch (v.tag) {
            .nil => .nil,
            .boolean => .{ .boolean = v.asBool() },
            .int => .{ .int = v.asInt() },
            .float => .{ .float = v.asFloat() },
            .heap_ref => if (v.heapType() == .string)
                .{ .string = gpa.dupe(u8, string.String.fromHeader(v.asHeap()).bytes()) catch return null }
            else
                null,
            .row_view => null,
        };
    }

    pub fn deinit(self: LogValue, gpa: std.mem.Allocator) void {
        switch (self) {
            .string => |s| gpa.free(s),
            else => {},
        }
    }
};

/// One recorded execution event (in-memory; serialized to `schema.ExecEvent`, its
/// `value` mapped to an `EffectResult`). Owns `value`'s string bytes.
pub const ExecEvent = struct {
    kind: ExecEventKind,
    ref: u32 = 0,
    value: LogValue = .nil,
};

/// Free the events' owned string bytes (not the slice itself).
pub fn freeEventValues(gpa: std.mem.Allocator, events: []const ExecEvent) void {
    for (events) |ev| ev.value.deinit(gpa);
}

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

/// All recorded entries for one cached trace, keyed by `trace_id` — the trace's
/// stable `Trace.id`, which the trace wire file also carries so the viz joins logs
/// to trace records by id (doc 61 §7.1 item 7; cache positions reshuffle on retire).
pub const TraceExecLog = struct {
    trace_id: u32,
    /// `max_entries` was reached; further entries for this trace were not recorded.
    entries_capped: bool = false,
    entries: std.ArrayListUnmanaged(TraceEntry) = .empty,

    pub fn deinit(self: *TraceExecLog, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*e| {
            freeEventValues(gpa, e.events);
            gpa.free(e.events);
        }
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
        freeEventValues(self.gpa, self.scratch.items);
        self.scratch.deinit(self.gpa);
    }

    /// Drop the scratch events, freeing their owned bytes (an abandoned entry —
    /// one whose log was unpublished mid-entry, or whose finalize failed).
    fn discardScratch(self: *ExecLogRecorder) void {
        freeEventValues(self.gpa, self.scratch.items);
        self.scratch.clearRetainingCapacity();
    }

    /// Append one event whose value is detached from the heap. A value the log
    /// cannot represent, a failed byte copy, or a failed append drops the event
    /// without leaking (doc 61 §7.1 item 7).
    fn push(self: *ExecLogRecorder, kind: ExecEventKind, ref: usize, v: Value) void {
        const lv = LogValue.of(self.gpa, v) orelse return;
        self.scratch.append(self.gpa, .{ .kind = kind, .ref = @intCast(ref), .value = lv }) catch lv.deinit(self.gpa);
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
        self.discardScratch();
    }

    /// Record a non-guard instruction's result. Inert past the detail cap.
    /// Non-string heap values (tables, closures, …) and row handles are silently
    /// dropped (`LogValue.of`): the log can only represent scalars and strings,
    /// and the viz doesn't need intermediate pointers anyway. String bytes are
    /// copied — the log never borrows heap memory.
    pub fn value(self: *ExecLogRecorder, ref: usize, v: Value) void {
        if (!self.active or self.detail_done) return;
        self.push(.value, ref, v);
    }

    /// Record a surviving guard (its checked operand). Inert past the detail cap.
    /// Unrepresentable operands are dropped (same reasoning as `value`).
    pub fn guardPass(self: *ExecLogRecorder, ref: usize, operand: Value) void {
        if (!self.active or self.detail_done) return;
        self.push(.guard_pass, ref, operand);
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
    /// the exit ramp is never lost. Unrepresentable operands are replaced with nil
    /// (the exit event itself must survive — only the unserializable operand is
    /// lost); only an allocation failure (byte copy or append) drops it, and the
    /// entry's `exit_ref`/`exit_kind` still record the ramp.
    pub fn exit(self: *ExecLogRecorder, ref: usize, kind: ExitKind, operand: Value) void {
        if (!self.active) return;
        self.exit_ref = @intCast(ref);
        self.exit_kind = kind;
        const safe = if (isUnrepresentable(operand)) Value.nil() else operand;
        self.push(.exit, ref, safe);
    }

    fn isUnrepresentable(v: Value) bool {
        return switch (v.tag) {
            .heap_ref => v.heapType() != .string,
            .row_view => true,
            else => false,
        };
    }

    /// Finalize the entry with the executor's `completed` yield, copying the scratch
    /// events into an owned slice appended to the log. The events' string bytes
    /// transfer to the log on success; if the entry was not recorded (entry cap),
    /// the target log is gone (its trace retired mid-entry), or finalizing fails,
    /// the scratch bytes are freed instead.
    pub fn end(self: *ExecLogRecorder, completed: usize) void {
        if (!self.active) return;
        self.active = false;
        const log = self.log orelse return self.discardScratch();
        const events = self.gpa.dupe(ExecEvent, self.scratch.items) catch return self.discardScratch();
        log.entries.append(self.gpa, .{
            .iterations = @intCast(completed),
            .exit_ref = self.exit_ref,
            .exit_kind = self.exit_kind,
            .capped = self.detail_done,
            .events = events,
        }) catch {
            self.gpa.free(events);
            return self.discardScratch();
        };
        // Ownership moved into `events`; forget the scratch copies.
        self.scratch.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const gc = @import("gc.zig");

test "recorder drops non-string heap values from value/guardPass and nil-substitutes in exit" {
    const gpa = testing.allocator;

    var heap = gc.Heap.init(gpa);
    defer heap.deinit();

    // Create a table — a non-string heap value the encoder cannot serialize.
    const tbl = try heap.newTable();
    const heap_val = Value.heap(&tbl.header);

    // Scalar values the encoder CAN serialize.
    const int_val = Value.int(42);
    const float_val = Value.float(3.14);

    var log = TraceExecLog{ .trace_id = 0 };
    defer log.deinit(gpa);

    var rec = ExecLogRecorder{
        .gpa = gpa,
        .max_iters = 100,
        .max_entries = 100,
        .log = &log,
    };
    defer rec.deinit();

    rec.begin();

    // Scalar value — recorded.
    rec.value(0, int_val);
    // Heap value — silently dropped.
    rec.value(1, heap_val);
    // Scalar guardPass — recorded.
    rec.guardPass(2, float_val);
    // Heap guardPass — silently dropped.
    rec.guardPass(3, heap_val);
    // Commit (one iteration).
    rec.commit();
    // Exit with heap operand — event recorded, but operand replaced with nil.
    rec.exit(4, .guard, heap_val);

    rec.end(1);

    try testing.expectEqual(@as(usize, 1), log.entries.items.len);
    const events = log.entries.items[0].events;

    // Expected: value(0), guardPass(2), commit, exit(4) — two heap events dropped.
    try testing.expectEqual(@as(usize, 4), events.len);

    try testing.expectEqual(ExecEventKind.value, events[0].kind);
    try testing.expectEqual(@as(u32, 0), events[0].ref);
    try testing.expectEqual(LogValue{ .int = 42 }, events[0].value);

    try testing.expectEqual(ExecEventKind.guard_pass, events[1].kind);
    try testing.expectEqual(@as(u32, 2), events[1].ref);
    try testing.expectEqual(LogValue{ .float = 3.14 }, events[1].value);

    try testing.expectEqual(ExecEventKind.commit, events[2].kind);

    try testing.expectEqual(ExecEventKind.exit, events[3].kind);
    try testing.expectEqual(@as(u32, 4), events[3].ref);
    // Heap operand replaced with nil — the exit event survives but the
    // unserializable operand doesn't.
    try testing.expectEqual(LogValue.nil, events[3].value);
}

test "recorded string values own their bytes and outlive the heap string (doc 61 §7.1 item 7)" {
    const gpa = testing.allocator;

    var log = TraceExecLog{ .trace_id = 3 };
    defer log.deinit(gpa);
    var rec = ExecLogRecorder.init(gpa, 100, 100);
    defer rec.deinit();
    rec.retarget(&log);

    {
        // The heap — and with it the interned strings — dies before the log is read:
        // the shape of a sweep freeing a string a (non-rooting) trace still names.
        var heap = gc.Heap.init(gpa);
        defer heap.deinit();
        const s = try heap.internValue("hello");
        const g = try heap.internValue("guard");
        const x = try heap.internValue("exit");
        rec.begin();
        rec.value(0, s);
        rec.guardPass(1, g);
        rec.commit();
        rec.exit(2, .guard, x);
        rec.end(1);
    }

    const events = log.entries.items[0].events;
    try testing.expectEqual(@as(usize, 4), events.len);
    try testing.expectEqualStrings("hello", events[0].value.string);
    try testing.expectEqualStrings("guard", events[1].value.string);
    try testing.expectEqualStrings("exit", events[3].value.string);
}

test "an abandoned entry frees its scratch strings (log retired mid-entry, re-begin, deinit)" {
    const gpa = testing.allocator;
    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    const s = try heap.internValue("scratch");

    var log = TraceExecLog{ .trace_id = 0 };
    defer log.deinit(gpa);
    var rec = ExecLogRecorder.init(gpa, 100, 100);
    defer rec.deinit();

    // 1. The log is unpublished mid-entry (a retire nulls `rec.log`): `end` frees.
    rec.retarget(&log);
    rec.begin();
    rec.value(0, s);
    rec.log = null;
    rec.end(0);
    try testing.expectEqual(@as(usize, 0), rec.scratch.items.len);

    // 2. An entry that never reaches `end` (unwound executor): the next `begin` frees.
    rec.retarget(&log);
    rec.begin();
    rec.value(0, s);
    rec.begin();
    try testing.expectEqual(@as(usize, 0), rec.scratch.items.len);

    // 3. Still pending at teardown: `deinit` frees (leak-checked by testing.allocator).
    rec.value(0, s);
    try testing.expectEqual(@as(usize, 1), rec.scratch.items.len);
}

fn recordStringEntry(gpa: std.mem.Allocator, s: Value) !void {
    var log = TraceExecLog{ .trace_id = 0 };
    defer log.deinit(gpa);
    var rec = ExecLogRecorder.init(gpa, 100, 100);
    defer rec.deinit();
    rec.retarget(&log);
    rec.begin();
    rec.value(0, s);
    rec.guardPass(1, s);
    rec.commit();
    rec.exit(2, .guard, s);
    rec.end(1);
    // The recorder swallows allocation failure by design (events/entries drop);
    // this harness only needs *some* allocation to fail at each index, which the
    // dropped-event paths guarantee, so force the checker to see an error.
    if (log.entries.items.len == 0 or log.entries.items[0].events.len != 4) return error.OutOfMemory;
}

test "every allocation failure while logging strings drops cleanly with no leak" {
    var heap = gc.Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try heap.internValue("payload");
    try testing.checkAllAllocationFailures(testing.allocator, recordStringEntry, .{s});
}
