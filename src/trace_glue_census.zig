//! Doc 87 Phase 0: the glue census.
//!
//! A loop that a trace was running ends; tier 0 goes on until the next loop
//! trace is entered. The code between the two is the **glue** doc 87 wants
//! to record (§5.1). The census says what that code does to the frame
//! stack, for every such stretch of a run: how many returns, calls and loop
//! headers it passes, in which order, between which kinds of loop, and
//! whether any of the frames involved is one doc 87 §7 leaves out of v1
//! (vararg, protected, `all_results`, open upvalues).
//!
//! It watches tier 0 only. The interpreter reports five events (a loop
//! trace entered, a one-shot trace entered, a call, a return, a loop header
//! passed without entering a trace), each with the frame it happened in.
//! Nothing here reads a trace or a receipt, so the counts are the same
//! whichever executor ran the loops and whatever the dispatcher did between
//! them.
//!
//! The hooks that feed it are compiled only into `-Djit-debug` builds
//! (`jitdbg.enabled`): a call or a return in a normal build pays nothing.
//! This module itself has no build gate and is tested in every build.
//!
//! **A visit and its window.** Entering a loop trace starts a *visit* of
//! that loop in that frame. Tier 0 resumes inside the loop (a loop-done
//! exit replays the final trip from the header) and the visit stays
//! *armed* until tier 0 is seen outside the loop: the first event in the
//! visit's frame whose pc is outside the loop's static extent
//! (`bytecode.loopExtentFor`). That event opens the *window*, which then
//! records every event, in any frame, until the next loop trace is entered.
//! An armed visit that never gets there is counted by how it ended instead
//! (`Stats`).
//!
//! What the census cannot tell apart: a loop left by `break` and a loop
//! that ran to its end both put tier 0 past the loop's last instruction.

const std = @import("std");
const bytecode = @import("bytecode.zig");

const Allocator = std.mem.Allocator;
const Proto = bytecode.Proto;

/// The kind of loop a window starts at.
pub const LoopKind = enum(u4) {
    numeric_for,
    generic_for,
    while_loop,
    repeat_loop,

    pub fn name(self: LoopKind) []const u8 {
        return switch (self) {
            .numeric_for => "for",
            .generic_for => "for_in",
            .while_loop => "while",
            .repeat_loop => "repeat",
        };
    }
};

/// How a window closed. The first four are the kind of the loop whose
/// trace was entered, numbered as `LoopKind`.
pub const Outcome = enum(u4) {
    numeric_for,
    generic_for,
    while_loop,
    repeat_loop,
    /// A loop trace whose loop `loopExtentFor` does not recognise.
    other_loop,
    /// More than `max_steps` events: tier 0 went on, this is not a glue.
    long,
    /// The run ended with the window open.
    end,
    /// The next event came from another coroutine.
    context,

    pub fn ofKind(k: LoopKind) Outcome {
        return @enumFromInt(@intFromEnum(k));
    }

    pub fn name(self: Outcome) []const u8 {
        return switch (self) {
            .numeric_for => "for",
            .generic_for => "for_in",
            .while_loop => "while",
            .repeat_loop => "repeat",
            .other_loop => "other_loop",
            .long => "long",
            .end => "end",
            .context => "context",
        };
    }
};

/// One event of a window.
pub const Step = enum(u2) {
    /// A Lua frame returned.
    ret,
    /// A Lua frame was pushed.
    call,
    /// Tier 0 passed a loop header (entering the loop or repeating it)
    /// without entering a trace there.
    header,
    /// A one-shot trace (a function head or a continuation) was entered.
    one_shot,

    pub fn letter(self: Step) u8 {
        return switch (self) {
            .ret => 'R',
            .call => 'C',
            .header => 'B',
            .one_shot => 'O',
        };
    }
};

/// A window holds at most this many events; one more closes it as `.long`.
pub const max_steps = 8;

/// The events of a window, in order.
pub const Shape = struct {
    len: u8 = 0,
    /// Two bits a step, the first step lowest.
    bits: u16 = 0,

    /// The shape `text` spells with `Step.letter`s, e.g. `"RBC"`.
    pub fn of(comptime text: []const u8) Shape {
        var s: Shape = .{};
        inline for (text) |ch| s.push(switch (ch) {
            'R' => .ret,
            'C' => .call,
            'B' => .header,
            'O' => .one_shot,
            else => @compileError("not a step letter"),
        });
        return s;
    }

    fn push(self: *Shape, s: Step) void {
        std.debug.assert(self.len < max_steps);
        self.bits |= @as(u16, @intFromEnum(s)) << @intCast(2 * @as(u16, self.len));
        self.len += 1;
    }

    pub fn at(self: Shape, i: u8) Step {
        return @enumFromInt(@as(u2, @truncate(self.bits >> @intCast(2 * @as(u16, i)))));
    }

    /// The shape as letters; `-` for a window with no event.
    pub fn write(self: Shape, buf: *[max_steps]u8) []const u8 {
        if (self.len == 0) return "-";
        var i: u8 = 0;
        while (i < self.len) : (i += 1) buf[i] = self.at(i).letter();
        return buf[0..self.len];
    }
};

/// What some event of a window involved.
pub const Flags = packed struct(u16) {
    /// A returning frame's function is vararg.
    ret_vararg: bool = false,
    /// A returning frame is the one a `pcall`/`xpcall` protects.
    ret_protected: bool = false,
    /// A return whose call site takes every result (`c = all_results`).
    ret_all: bool = false,
    /// A return of a dynamic count (`return f()`, `return ...`).
    ret_dynamic: bool = false,
    /// A return that closed open upvalues.
    ret_upvalues: bool = false,
    /// A return landed in a frame whose function is vararg.
    land_vararg: bool = false,
    /// A return landed in a protected frame.
    land_protected: bool = false,
    /// A called function is vararg.
    call_vararg: bool = false,
    /// A call through `pcall`/`xpcall`.
    call_protected: bool = false,
    /// A call a native made (a resumable native's callback).
    call_native: bool = false,
    /// A metamethod's frame was pushed or returned.
    meta: bool = false,
    /// A return to the host (`callValue`, the top level, a coroutine body).
    host: bool = false,
    /// An event came from a depth the window did not expect: frames moved
    /// where the census has no hook (an error unwinding, a host re-entry, a
    /// one-shot trace moving frames natively).
    untracked: bool = false,
    _pad: u3 = 0,

    pub fn merge(a: Flags, b: Flags) Flags {
        return @bitCast(@as(u16, @bitCast(a)) | @as(u16, @bitCast(b)));
    }

    pub fn none(self: Flags) bool {
        return @as(u16, @bitCast(self)) == 0;
    }

    const Name = struct { bit: u16, text: []const u8 };
    const names = [_]Name{
        .{ .bit = @bitCast(Flags{ .ret_vararg = true }), .text = "ret_vararg" },
        .{ .bit = @bitCast(Flags{ .ret_protected = true }), .text = "ret_protected" },
        .{ .bit = @bitCast(Flags{ .ret_all = true }), .text = "ret_all" },
        .{ .bit = @bitCast(Flags{ .ret_dynamic = true }), .text = "ret_dynamic" },
        .{ .bit = @bitCast(Flags{ .ret_upvalues = true }), .text = "ret_upvalues" },
        .{ .bit = @bitCast(Flags{ .land_vararg = true }), .text = "land_vararg" },
        .{ .bit = @bitCast(Flags{ .land_protected = true }), .text = "land_protected" },
        .{ .bit = @bitCast(Flags{ .call_vararg = true }), .text = "call_vararg" },
        .{ .bit = @bitCast(Flags{ .call_protected = true }), .text = "call_protected" },
        .{ .bit = @bitCast(Flags{ .call_native = true }), .text = "call_native" },
        .{ .bit = @bitCast(Flags{ .meta = true }), .text = "meta" },
        .{ .bit = @bitCast(Flags{ .host = true }), .text = "host" },
        .{ .bit = @bitCast(Flags{ .untracked = true }), .text = "untracked" },
    };

    /// Room for every name and the `+` between them.
    pub const text_cap = 160;

    /// The set flags joined by `+`; `-` for none.
    pub fn write(self: Flags, buf: *[text_cap]u8) []const u8 {
        const bits: u16 = @bitCast(self);
        var n: usize = 0;
        for (names) |nm| {
            if (bits & nm.bit == 0) continue;
            if (n != 0) {
                buf[n] = '+';
                n += 1;
            }
            @memcpy(buf[n..][0..nm.text.len], nm.text);
            n += nm.text.len;
        }
        return if (n == 0) "-" else buf[0..n];
    }
};

comptime {
    var total: usize = 0;
    for (Flags.names) |nm| total += nm.text.len + 1;
    std.debug.assert(total <= Flags.text_cap);
}

/// What the census counts windows by.
pub const WindowKey = packed struct(u64) {
    from: LoopKind,
    to: Outcome,
    /// The trace entered is the loop the window started at.
    self_ring: bool = false,
    /// The trace entered is in the function the window started in.
    same_proto: bool = false,
    /// How many nested loops had ended when the window opened (1 = the
    /// visited loop alone; saturates at 3).
    ended: u2 = 1,
    _pad: u4 = 0,
    shape_len: u8 = 0,
    _pad2: u8 = 0,
    shape_bits: u16 = 0,
    flags: Flags = .{},

    pub fn shape(self: WindowKey) Shape {
        return .{ .len = self.shape_len, .bits = self.shape_bits };
    }
};

/// A frame as the events name it.
pub const Frame = struct {
    /// `Vm.depth` with this frame on top.
    depth: usize,
    call_seq: u64,
    /// The coroutine it runs in (0 for the main context).
    ctx: usize,

    fn same(a: Frame, b: Frame) bool {
        return a.depth == b.depth and a.call_seq == b.call_seq and a.ctx == b.ctx;
    }
};

/// The pc of an event whose instruction the interpreter does not have at
/// hand (a metamethod's frame push). An armed visit takes it as inside the
/// loop.
pub const unknown_pc: u32 = std.math.maxInt(u32);

pub const CallFacts = struct {
    vararg: bool = false,
    protected: bool = false,
    native: bool = false,
    meta: bool = false,
};

pub const RetFacts = struct {
    vararg: bool = false,
    protected: bool = false,
    all: bool = false,
    dynamic: bool = false,
    upvalues: bool = false,
    meta: bool = false,
    host: bool = false,
    land_vararg: bool = false,
    land_protected: bool = false,
    /// The frame the return lands in and the pc it resumes at; null for a
    /// return to the host.
    land_proto: ?*const Proto = null,
    land_pc: u32 = 0,
};

/// How visits went, outside the windows.
pub const Stats = struct {
    /// Loop traces entered from tier 0 (a sibling walk's later candidates
    /// are the same visit).
    visits_loop: u64 = 0,
    /// One-shot traces entered.
    visits_one_shot: u64 = 0,
    /// Visits whose loop ended in tier 0: the windows.
    opened: u64 = 0,
    /// Visits followed by another entry of the same loop in the same frame
    /// (a side exit, then the next back-edge).
    reentered: u64 = 0,
    /// Visits whose loop went on in tier 0 (its header passed without an
    /// entry).
    continued: u64 = 0,
    /// Visits whose frame returned from inside the loop.
    ret_inside: u64 = 0,
    /// Visits replaced by another loop's visit before their loop ended.
    superseded: u64 = 0,
    /// Visits whose frame went away unseen (an error, a coroutine switch).
    lost: u64 = 0,
    /// Visits of a loop whose shape `loopExtentFor` does not recognise.
    unknown_extent: u64 = 0,
    /// Windows not counted because a table could not grow.
    dropped: u64 = 0,
};

const AnchorId = struct {
    proto: usize,
    header: u32,

    fn eql(a: AnchorId, b: AnchorId) bool {
        return a.proto == b.proto and a.header == b.header;
    }
};

const Ext = struct {
    start: u32,
    end: u32,
    header: u32,
    kind: LoopKind,

    fn holds(self: Ext, pc: u32) bool {
        return self.start <= pc and pc <= self.end;
    }
};

/// A loop and the loops around it, innermost first.
const Chain = struct {
    const cap = 4;
    ext: [cap]Ext = undefined,
    len: u8 = 0,

    /// How many of the loops, from the innermost out, do not hold `pc`.
    fn endedAt(self: *const Chain, pc: u32) u8 {
        if (pc == unknown_pc) return 0;
        var n: u8 = 0;
        while (n < self.len and !self.ext[n].holds(pc)) n += 1;
        return n;
    }

    /// Keep the `cap` smallest extents, smallest first.
    fn insert(self: *Chain, e: Ext) void {
        var i: usize = self.len;
        if (self.len < cap) self.len += 1 else if (size(e) >= size(self.ext[cap - 1])) return else i = cap - 1;
        while (i > 0 and size(self.ext[i - 1]) > size(e)) : (i -= 1) self.ext[i] = self.ext[i - 1];
        self.ext[i] = e;
    }

    fn size(e: Ext) u32 {
        return e.end - e.start;
    }
};

fn kindOf(proto: *const Proto, ext: bytecode.LoopExtent) ?LoopKind {
    return switch (ext.back_edge_op) {
        .for_loop => .numeric_for,
        .tfor_loop => .generic_for,
        .loop => switch (std.enums.fromInt(bytecode.LoopKind, proto.code[ext.back_edge_pc].b) orelse return null) {
            .while_loop => .while_loop,
            .repeat_loop => .repeat_loop,
        },
        else => null,
    };
}

/// The loop headed at `header` and the loops that enclose it. Empty when
/// the loop's shape is not recognised.
fn chainOf(proto: *const Proto, header: u32) Chain {
    var c: Chain = .{};
    const own = bytecode.loopExtentFor(proto, header) orelse return c;
    const own_kind = kindOf(proto, own) orelse return c;
    c.insert(.{ .start = own.start, .end = own.end, .header = header, .kind = own_kind });
    var h: u32 = 1;
    while (h < proto.code.len) : (h += 1) {
        if (h == header) continue;
        const e = bytecode.loopExtentFor(proto, h) orelse continue;
        if (!(e.start <= own.start and own.end <= e.end)) continue;
        const k = kindOf(proto, e) orelse continue;
        c.insert(.{ .start = e.start, .end = e.end, .header = h, .kind = k });
    }
    return c;
}

/// A loop windows started at.
pub const FromInfo = struct {
    proto: *const Proto,
    header: u32,
    kind: LoopKind,
    windows: u64 = 0,
    /// The distinct successors seen, up to `succ_cap`: where the first
    /// return landed, the events, and the loop entered.
    succ: [succ_cap]u64 = undefined,
    succ_len: u8 = 0,
    /// Windows whose successor was a further one.
    succ_more: u64 = 0,

    pub const succ_cap = 4;

    fn note(self: *FromInfo, s: u64) void {
        self.windows += 1;
        for (self.succ[0..self.succ_len]) |have| {
            if (have == s) return;
        }
        if (self.succ_len < succ_cap) {
            self.succ[self.succ_len] = s;
            self.succ_len += 1;
        } else self.succ_more += 1;
    }
};

const Landing = struct { proto: usize, pc: u32 };

const Armed = struct {
    id: AnchorId,
    frame: Frame,
    chain: Chain,
    /// `GlueCensus.seq` at the entry.
    seq: u64,
};

const Open = struct {
    from: AnchorId,
    from_proto: *const Proto,
    kind: LoopKind,
    ended: u8,
    /// The depth the next event is expected at.
    depth: usize,
    ctx: usize,
    shape: Shape = .{},
    flags: Flags = .{},
    land: ?Landing = null,
};

const Pending = struct {
    frame: Frame,
    proto: *const Proto,
    header: u32,
};

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x9E37_79B9_7F4A_7C15 +% 0x7F4A_7C15;
}

pub const GlueCensus = struct {
    gpa: Allocator,
    stats: Stats = .{},
    /// Windows by `WindowKey` (as its bits).
    windows: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    froms: std.AutoHashMapUnmanaged(AnchorId, FromInfo) = .empty,
    /// The chain of every loop anchor entered, computed once.
    chains: std.AutoHashMapUnmanaged(AnchorId, Chain) = .empty,
    state: union(enum) { idle, armed: Armed, open: Open } = .idle,
    /// A loop header tier 0 passed, held until the next event: an entry of
    /// that loop's trace right behind it means the pass was the entry.
    pending: ?Pending = null,
    /// Tier-0 events reported so far (calls, returns, header passes,
    /// one-shot entries). A loop entry with none since the last loop entry
    /// is another candidate of the same visit.
    seq: u64 = 0,

    pub fn init(gpa: Allocator) GlueCensus {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *GlueCensus) void {
        self.windows.deinit(self.gpa);
        self.froms.deinit(self.gpa);
        self.chains.deinit(self.gpa);
    }

    // ---- events ----

    /// A loop trace anchored at `header` of `proto` is entered in frame `f`.
    pub fn arriveLoop(self: *GlueCensus, f: Frame, proto: *const Proto, header: u32) void {
        if (self.pending) |p| {
            if (p.proto == proto and p.header == header and p.frame.same(f)) {
                self.pending = null;
            } else self.commitPending();
        }
        const id: AnchorId = .{ .proto = @intFromPtr(proto), .header = header };
        const chain = self.chainFor(proto, id);
        var same_visit = false;
        switch (self.state) {
            .idle => {},
            .armed => |a| {
                if (a.seq == self.seq) {
                    same_visit = true;
                } else if (a.id.eql(id) and a.frame.same(f)) {
                    self.stats.reentered += 1;
                } else self.stats.superseded += 1;
            },
            .open => |o| self.close(o, if (chain.len != 0) .ofKind(chain.ext[0].kind) else .other_loop, id),
        }
        if (!same_visit) self.stats.visits_loop += 1;
        if (chain.len == 0) {
            if (!same_visit) self.stats.unknown_extent += 1;
            self.state = .idle;
            return;
        }
        self.state = .{ .armed = .{ .id = id, .frame = f, .chain = chain, .seq = self.seq } };
    }

    /// A one-shot trace is entered in frame `f`, at bytecode `pc`.
    pub fn arriveOneShot(self: *GlueCensus, f: Frame, pc: u32) void {
        self.commitPending();
        self.seq += 1;
        self.stats.visits_one_shot += 1;
        self.step(.one_shot, f, pc, null, .{}, null);
    }

    /// Tier 0 passed the loop header `header` in frame `f`. Counted at the
    /// next event, unless that is an entry of the same loop.
    pub fn passHeader(self: *GlueCensus, f: Frame, proto: *const Proto, header: u32) void {
        self.commitPending();
        self.seq += 1;
        self.pending = .{ .frame = f, .proto = proto, .header = header };
    }

    /// Frame `f`, at the instruction `pc`, pushes a Lua frame.
    pub fn call(self: *GlueCensus, f: Frame, pc: u32, c: CallFacts) void {
        self.commitPending();
        self.seq += 1;
        self.step(.call, f, pc, null, .{
            .call_vararg = c.vararg,
            .call_protected = c.protected,
            .call_native = c.native,
            .meta = c.meta,
        }, null);
    }

    /// Frame `f` returns from the instruction `pc`.
    pub fn ret(self: *GlueCensus, f: Frame, pc: u32, r: RetFacts) void {
        self.commitPending();
        self.seq += 1;
        self.step(.ret, f, pc, null, .{
            .ret_vararg = r.vararg,
            .ret_protected = r.protected,
            .ret_all = r.all,
            .ret_dynamic = r.dynamic,
            .ret_upvalues = r.upvalues,
            .land_vararg = r.land_vararg,
            .land_protected = r.land_protected,
            .meta = r.meta,
            .host = r.host,
        }, if (r.land_proto) |p| .{ .proto = @intFromPtr(p), .pc = r.land_pc } else null);
    }

    /// The run is over: an open window closes as `.end`.
    pub fn finish(self: *GlueCensus) void {
        self.commitPending();
        switch (self.state) {
            .open => |o| self.close(o, .end, null),
            .idle, .armed => {},
        }
        self.state = .idle;
    }

    // ---- the state machine ----

    fn commitPending(self: *GlueCensus) void {
        const p = self.pending orelse return;
        self.pending = null;
        self.step(.header, p.frame, p.header, p.header, .{}, null);
    }

    fn chainFor(self: *GlueCensus, proto: *const Proto, id: AnchorId) Chain {
        if (self.chains.get(id)) |c| return c;
        const c = chainOf(proto, id.header);
        // A failed insert only means the scan runs again next time.
        self.chains.put(self.gpa, id, c) catch {};
        return c;
    }

    fn disarm(self: *GlueCensus, counter: *u64) void {
        counter.* += 1;
        self.state = .idle;
    }

    fn step(self: *GlueCensus, kind: Step, f: Frame, pc: u32, passed: ?u32, fl: Flags, land: ?Landing) void {
        switch (self.state) {
            .idle => return,
            .armed => |a| {
                if (f.ctx != a.frame.ctx) return self.disarm(&self.stats.lost);
                // A frame the replayed trip pushed.
                if (f.depth > a.frame.depth) return;
                if (f.depth < a.frame.depth or f.call_seq != a.frame.call_seq) return self.disarm(&self.stats.lost);
                const ended = a.chain.endedAt(pc);
                if (ended == 0) {
                    if (kind == .header and passed.? == a.id.header) return self.disarm(&self.stats.continued);
                    if (kind == .ret) return self.disarm(&self.stats.ret_inside);
                    return;
                }
                const from = a.chain.ext[ended - 1];
                self.stats.opened += 1;
                self.state = .{ .open = .{
                    .from = .{ .proto = a.id.proto, .header = from.header },
                    .from_proto = @ptrFromInt(a.id.proto),
                    .kind = from.kind,
                    .ended = ended,
                    .depth = f.depth,
                    .ctx = f.ctx,
                } };
            },
            .open => {},
        }
        const o = &self.state.open;
        if (f.ctx != o.ctx) return self.close(o.*, .context, null);
        if (o.shape.len == max_steps) return self.close(o.*, .long, null);
        if (f.depth != o.depth) {
            o.flags.untracked = true;
            o.depth = f.depth;
        }
        o.shape.push(kind);
        o.flags = o.flags.merge(fl);
        switch (kind) {
            .ret => {
                o.depth -|= 1;
                if (o.land == null) o.land = land;
            },
            .call => o.depth += 1,
            .header, .one_shot => {},
        }
    }

    fn close(self: *GlueCensus, o: Open, outcome: Outcome, to: ?AnchorId) void {
        self.state = .idle;
        const key: WindowKey = .{
            .from = o.kind,
            .to = outcome,
            .self_ring = if (to) |t| t.eql(o.from) else false,
            .same_proto = if (to) |t| t.proto == o.from.proto else false,
            .ended = @intCast(@min(o.ended, 3)),
            .shape_len = o.shape.len,
            .shape_bits = o.shape.bits,
            .flags = o.flags,
        };
        const w = self.windows.getOrPut(self.gpa, @bitCast(key)) catch {
            self.stats.dropped += 1;
            return;
        };
        if (!w.found_existing) w.value_ptr.* = 0;
        w.value_ptr.* += 1;
        const fi = self.froms.getOrPut(self.gpa, o.from) catch return;
        if (!fi.found_existing) fi.value_ptr.* = .{ .proto = o.from_proto, .header = o.from.header, .kind = o.kind };
        var s: u64 = mix(@intFromEnum(outcome), (@as(u64, o.shape.len) << 16) | o.shape.bits);
        if (to) |t| s = mix(mix(s, t.proto), t.header);
        if (o.land) |l| s = mix(mix(s, l.proto), l.pc);
        fi.value_ptr.note(s);
    }

    // ---- reading ----

    pub fn windowCount(self: *const GlueCensus, key: WindowKey) u64 {
        return self.windows.get(@bitCast(key)) orelse 0;
    }

    /// Windows from a `from` loop to `to` with exactly `shape`, whatever
    /// their flags and other key fields.
    pub fn countShape(self: *const GlueCensus, from: LoopKind, to: Outcome, shape: Shape) u64 {
        var n: u64 = 0;
        var it = self.windows.iterator();
        while (it.next()) |e| {
            const k: WindowKey = @bitCast(e.key_ptr.*);
            if (k.from == from and k.to == to and k.shape_len == shape.len and k.shape_bits == shape.bits) n += e.value_ptr.*;
        }
        return n;
    }

    pub fn totalWindows(self: *const GlueCensus) u64 {
        var n: u64 = 0;
        var it = self.windows.iterator();
        while (it.next()) |e| n += e.value_ptr.*;
        return n;
    }

    const WindowRow = struct { key: u64, n: u64 };

    fn windowRowBefore(_: void, a: WindowRow, b: WindowRow) bool {
        if (a.n != b.n) return a.n > b.n;
        return a.key < b.key;
    }

    fn fromBefore(_: void, a: FromInfo, b: FromInfo) bool {
        if (a.windows != b.windows) return a.windows > b.windows;
        if (a.proto.id != b.proto.id) return a.proto.id < b.proto.id;
        return a.header < b.header;
    }

    /// Close the run (`finish`) and write the census, one `glue:` line a
    /// fact, through `sink.line(comptime fmt, args)`. Lines are ordered by
    /// count and then by key, so two runs of one program print the same.
    pub fn report(self: *GlueCensus, sink: anytype) void {
        self.finish();
        const st = self.stats;
        sink.line("glue: visits loop={d} one_shot={d}", .{ st.visits_loop, st.visits_one_shot });
        sink.line("glue: armed opened={d} reentered={d} continued={d} ret_inside={d} superseded={d} lost={d} unknown={d} dropped={d}", .{
            st.opened,     st.reentered, st.continued,      st.ret_inside,
            st.superseded, st.lost,      st.unknown_extent, st.dropped,
        });

        const rows = self.gpa.alloc(WindowRow, self.windows.count()) catch {
            sink.line("glue: out of memory writing the windows", .{});
            return;
        };
        defer self.gpa.free(rows);
        var wi = self.windows.iterator();
        var i: usize = 0;
        while (wi.next()) |e| : (i += 1) rows[i] = .{ .key = e.key_ptr.*, .n = e.value_ptr.* };
        std.mem.sort(WindowRow, rows, {}, windowRowBefore);
        for (rows) |r| {
            const k: WindowKey = @bitCast(r.key);
            var sbuf: [max_steps]u8 = undefined;
            var fbuf: [Flags.text_cap]u8 = undefined;
            sink.line("glue: window n={d} from={s} to={s} self={d} same_proto={d} ended={d} shape={s} flags={s}", .{
                r.n,                           k.from.name(), k.to.name(),            @intFromBool(k.self_ring),
                @intFromBool(k.same_proto),    k.ended,       k.shape().write(&sbuf), k.flags.write(&fbuf),
            });
        }

        const froms = self.gpa.alloc(FromInfo, self.froms.count()) catch {
            sink.line("glue: out of memory writing the loops", .{});
            return;
        };
        defer self.gpa.free(froms);
        var fi = self.froms.iterator();
        i = 0;
        while (fi.next()) |e| : (i += 1) froms[i] = e.value_ptr.*;
        std.mem.sort(FromInfo, froms, {}, fromBefore);
        for (froms) |f| {
            sink.line("glue: from n={d} proto={s}#{d} pc={d} kind={s} successors={d} beyond={d}", .{
                f.windows, f.proto.name, f.proto.id, f.header, f.kind.name(), f.succ_len, f.succ_more,
            });
        }
    }
};

// ---------------------------------------------------------------- tests ----

const testing = std.testing;
const Instr = bytecode.Instr;

/// `for_prep; body; for_loop; ret`: one numeric `for` with header 1 and
/// extent [1, 2]; pc 3 is past it.
const one_for = [_]Instr{
    Instr.opAx(.for_prep, 0, 1),
    Instr.opAx(.load_int, 4, 0),
    Instr.opAx(.for_loop, 0, -2),
    Instr.op0(.ret),
};

/// Two nested numeric `for`s: the outer has header 1 and extent [1, 5],
/// the inner header 2 and extent [2, 3]; pc 4 is in the outer loop only
/// and pc 6 is past both.
const nested_for = [_]Instr{
    Instr.opAx(.for_prep, 0, 4), // 0 -> for_loop at 5
    Instr.opAx(.for_prep, 4, 1), // 1 -> for_loop at 3
    Instr.opAx(.load_int, 8, 0), // 2
    Instr.opAx(.for_loop, 4, -2), // 3 -> 2
    Instr.opAx(.load_int, 9, 0), // 4
    Instr.opAx(.for_loop, 0, -5), // 5 -> 1
    Instr.op0(.ret), // 6
};

fn frame(depth: usize, call_seq: u64) Frame {
    return .{ .depth = depth, .call_seq = call_seq, .ctx = 0 };
}

test "glue census: chainOf lists a loop and the loops around it" {
    const p = Proto{ .code = &nested_for };
    const inner = chainOf(&p, 2);
    try testing.expectEqual(@as(u8, 2), inner.len);
    try testing.expectEqual(Ext{ .start = 2, .end = 3, .header = 2, .kind = .numeric_for }, inner.ext[0]);
    try testing.expectEqual(Ext{ .start = 1, .end = 5, .header = 1, .kind = .numeric_for }, inner.ext[1]);
    try testing.expectEqual(@as(u8, 0), inner.endedAt(2));
    try testing.expectEqual(@as(u8, 1), inner.endedAt(4));
    try testing.expectEqual(@as(u8, 2), inner.endedAt(6));
    try testing.expectEqual(@as(u8, 0), inner.endedAt(unknown_pc));
    const outer = chainOf(&p, 1);
    try testing.expectEqual(@as(u8, 1), outer.len);
    // pc 0 is the `for_prep`, not a header.
    try testing.expectEqual(@as(u8, 0), chainOf(&p, 0).len);
}

test "glue census: a return and a call between two loops is one RC window" {
    // Named apart: two identical constants may share one address.
    const f = Proto{ .code = &one_for, .name = "f", .id = 1 };
    const g = Proto{ .code = &one_for, .name = "g", .id = 2 };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    // f's loop is entered at depth 2; its replayed trip calls nothing.
    c.arriveLoop(frame(2, 10), &f, 1);
    // f returns from pc 3, past the loop, into the caller at depth 1.
    c.ret(frame(2, 10), 3, .{});
    // The caller calls g, whose loop is entered at depth 2.
    c.call(frame(1, 5), 7, .{});
    c.arriveLoop(frame(2, 11), &g, 1);
    try testing.expectEqual(@as(u64, 1), c.totalWindows());
    try testing.expectEqual(@as(u64, 1), c.windowCount(.{
        .from = .numeric_for,
        .to = .numeric_for,
        .shape_len = 2,
        .shape_bits = Shape.of("RC").bits,
    }));
    try testing.expectEqual(@as(u64, 2), c.stats.visits_loop);
    try testing.expectEqual(@as(u64, 1), c.stats.opened);
    // The second visit is armed, not a window.
    c.finish();
    try testing.expectEqual(@as(u64, 1), c.totalWindows());
}

test "glue census: events inside the loop do not open a window" {
    const f = Proto{ .code = &one_for };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    c.arriveLoop(frame(2, 10), &f, 1);
    // The replayed trip calls a helper from pc 1 and it returns.
    c.call(frame(2, 10), 1, .{});
    c.ret(frame(3, 11), 0, .{});
    // A metamethod's frame, pc unknown.
    c.call(frame(2, 10), unknown_pc, .{ .meta = true });
    c.ret(frame(3, 12), 0, .{ .meta = true });
    try testing.expectEqual(@as(u64, 0), c.stats.opened);
    // The loop goes on in tier 0.
    c.passHeader(frame(2, 10), &f, 1);
    c.call(frame(2, 10), 1, .{});
    try testing.expectEqual(@as(u64, 1), c.stats.continued);
    try testing.expectEqual(@as(u64, 0), c.totalWindows());
}

test "glue census: a header pass right before the entry is the entry" {
    const f = Proto{ .code = &one_for };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    c.arriveLoop(frame(2, 10), &f, 1);
    // A side exit, then the back-edge enters the trace again.
    c.passHeader(frame(2, 10), &f, 1);
    c.arriveLoop(frame(2, 10), &f, 1);
    // A sibling candidate of the same entry.
    c.arriveLoop(frame(2, 10), &f, 1);
    try testing.expectEqual(@as(u64, 2), c.stats.visits_loop);
    try testing.expectEqual(@as(u64, 1), c.stats.reentered);
    try testing.expectEqual(@as(u64, 0), c.stats.continued);
    // The frame returns from inside the loop.
    c.ret(frame(2, 10), 2, .{});
    try testing.expectEqual(@as(u64, 1), c.stats.ret_inside);
    try testing.expectEqual(@as(u64, 0), c.totalWindows());
}

test "glue census: a ring through the caller's own loop is RBC, and a self ring is marked" {
    const drv = Proto{ .code = &one_for, .name = "drv", .id = 1 };
    const f = Proto{ .code = &one_for, .name = "f", .id = 2 };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    var round: u64 = 0;
    while (round < 3) : (round += 1) {
        c.arriveLoop(frame(2, 10 + round), &f, 1);
        c.ret(frame(2, 10 + round), 3, .{ .land_proto = &drv, .land_pc = 2 });
        c.passHeader(frame(1, 1), &drv, 1);
        c.call(frame(1, 1), 1, .{});
    }
    c.finish();
    const key: WindowKey = .{
        .from = .numeric_for,
        .to = .numeric_for,
        .self_ring = true,
        .same_proto = true,
        .shape_len = 3,
        .shape_bits = Shape.of("RBC").bits,
    };
    try testing.expectEqual(@as(u64, 2), c.windowCount(key));
    try testing.expectEqual(@as(u64, 1), c.countShape(.numeric_for, .end, Shape.of("RBC")));
    // One loop, two distinct successors: itself, and the end of the run.
    try testing.expectEqual(@as(u32, 1), c.froms.count());
    var it = c.froms.iterator();
    const info = it.next().?.value_ptr.*;
    try testing.expectEqual(@as(u64, 3), info.windows);
    try testing.expectEqual(@as(u8, 2), info.succ_len);
}

test "glue census: an inner loop's visit that ends past the outer loop starts at the outer loop" {
    const p = Proto{ .code = &nested_for, .name = "p", .id = 1 };
    const g = Proto{ .code = &one_for, .name = "g", .id = 2 };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    // Entered at the inner loop; the episode ran on natively and tier 0
    // next shows up returning from pc 6, past both loops.
    c.arriveLoop(frame(2, 10), &p, 2);
    c.ret(frame(2, 10), 6, .{ .vararg = true, .all = true });
    c.call(frame(1, 1), 4, .{ .protected = true });
    c.arriveLoop(frame(2, 11), &g, 1);
    try testing.expectEqual(@as(u64, 1), c.windowCount(.{
        .from = .numeric_for,
        .to = .numeric_for,
        .ended = 2,
        .shape_len = 2,
        .shape_bits = Shape.of("RC").bits,
        .flags = .{ .ret_vararg = true, .ret_all = true, .call_protected = true },
    }));
    // The window belongs to the outer loop, header 1.
    var it = c.froms.iterator();
    try testing.expectEqual(@as(u32, 1), it.next().?.value_ptr.header);

    // Entered at the inner loop again; this time the outer loop goes on in
    // tier 0 and the inner loop is entered for the next outer trip.
    c.arriveLoop(frame(2, 12), &p, 2);
    c.passHeader(frame(2, 12), &p, 1);
    c.arriveLoop(frame(2, 12), &p, 2);
    try testing.expectEqual(@as(u64, 1), c.windowCount(.{
        .from = .numeric_for,
        .to = .numeric_for,
        .self_ring = true,
        .same_proto = true,
        .ended = 1,
        .shape_len = 1,
        .shape_bits = Shape.of("B").bits,
    }));
}

test "glue census: a window that runs on closes as long, and an unexpected depth is flagged" {
    const f = Proto{ .code = &one_for };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    c.arriveLoop(frame(2, 10), &f, 1);
    c.ret(frame(2, 10), 3, .{});
    var i: usize = 0;
    while (i < max_steps) : (i += 1) c.passHeader(frame(1, 1), &f, 1);
    c.call(frame(1, 1), 3, .{});
    try testing.expectEqual(@as(u64, 1), c.countShape(.numeric_for, .long, Shape.of("RBBBBBBB")));
    try testing.expectEqual(@as(u64, 1), c.totalWindows());

    // A window whose second event comes from a depth no event explains.
    c.arriveLoop(frame(2, 20), &f, 1);
    c.ret(frame(2, 20), 3, .{});
    c.call(frame(4, 30), 0, .{});
    c.finish();
    try testing.expectEqual(@as(u64, 1), c.windowCount(.{
        .from = .numeric_for,
        .to = .end,
        .shape_len = 2,
        .shape_bits = Shape.of("RC").bits,
        .flags = .{ .untracked = true },
    }));
}

test "glue census: an armed visit whose frame is gone is lost, another coroutine closes a window" {
    const f = Proto{ .code = &one_for };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    // An error unwound the visit's frame: the next event is below it.
    c.arriveLoop(frame(3, 10), &f, 1);
    c.call(frame(2, 5), 0, .{});
    try testing.expectEqual(@as(u64, 1), c.stats.lost);
    // The same depth, another activation.
    c.arriveLoop(frame(3, 11), &f, 1);
    c.call(frame(3, 12), 3, .{});
    try testing.expectEqual(@as(u64, 2), c.stats.lost);
    // A window open when a coroutine takes over.
    c.arriveLoop(frame(2, 20), &f, 1);
    c.ret(frame(2, 20), 3, .{});
    c.call(.{ .depth = 1, .call_seq = 40, .ctx = 0x1000 }, 0, .{});
    try testing.expectEqual(@as(u64, 1), c.countShape(.numeric_for, .context, Shape.of("R")));
}

const TestSink = struct {
    out: std.ArrayList(u8) = .empty,

    pub fn line(self: *TestSink, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(testing.allocator, fmt ++ "\n", args) catch return;
        defer testing.allocator.free(s);
        self.out.appendSlice(testing.allocator, s) catch {};
    }
};

test "glue census: the report is ordered by count" {
    const f = Proto{ .code = &one_for, .name = "f", .id = 3 };
    const g = Proto{ .code = &one_for, .name = "g", .id = 4 };
    var c = GlueCensus.init(testing.allocator);
    defer c.deinit();
    var round: u64 = 0;
    while (round < 2) : (round += 1) {
        c.arriveLoop(frame(2, 10 + 2 * round), &f, 1);
        c.ret(frame(2, 10 + 2 * round), 3, .{});
        c.call(frame(1, 1), 4, .{});
        c.arriveLoop(frame(2, 11 + 2 * round), &g, 1);
        c.ret(frame(2, 11 + 2 * round), 3, .{ .upvalues = true });
        c.passHeader(frame(1, 1), &f, 1);
        c.call(frame(1, 1), 2, .{});
    }
    var sink: TestSink = .{};
    defer sink.out.deinit(testing.allocator);
    c.report(&sink);
    try testing.expectEqualStrings(
        \\glue: visits loop=4 one_shot=0
        \\glue: armed opened=4 reentered=0 continued=0 ret_inside=0 superseded=0 lost=0 unknown=0 dropped=0
        \\glue: window n=2 from=for to=for self=0 same_proto=0 ended=1 shape=RC flags=-
        \\glue: window n=1 from=for to=for self=0 same_proto=0 ended=1 shape=RBC flags=ret_upvalues
        \\glue: window n=1 from=for to=end self=0 same_proto=0 ended=1 shape=RBC flags=ret_upvalues
        \\glue: from n=2 proto=f#3 pc=1 kind=for successors=1 beyond=0
        \\glue: from n=2 proto=g#4 pc=1 kind=for successors=2 beyond=0
        \\
    , sink.out.items);
}
