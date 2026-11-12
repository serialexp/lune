//! Inspecting a stopped program: threads, the stack, scopes and variables
//! (doc 86 §5.5, §7.1, §7.2). Everything here reads; nothing runs guest code,
//! allocates on the VM heap, or changes a counter, so a stopped program
//! looks the same after any amount of inspecting.
//!
//! A *reference* is a number the transport hands the client: a frame, a
//! scope, or an object whose children can be listed. References are
//! handles into `Inspector.handles`, which a resume clears (DAP's rule),
//! so a stale one is refused, never followed.
//!
//! Variables page without building an index (§7.2): the array part by
//! position, the hash part by slot range. A hash part over `group_size`
//! slots lists as groups, each a range of slots, and expanding one reads
//! only its slots.

const std = @import("std");
const interp = @import("../interp.zig");
const bytecode = @import("../bytecode.zig");
const compiler = @import("../compiler.zig");
const coroutine = @import("../coroutine.zig");
const eval = @import("eval.zig");
const function = @import("../function.zig");
const hash_part = @import("../hash_part.zig");
const io = @import("../io.zig");
const string = @import("../string.zig");
const table = @import("../table.zig");
const value_mod = @import("../value.zig");

const Allocator = std.mem.Allocator;
const Vm = interp.Vm;
const Value = value_mod.Value;
const Thread = coroutine.Thread;
const Table = table.Table;

/// Slots of a hash part that make one group.
pub const group_size = 100;
/// The most bytes of a string a variable's text shows.
pub const text_cap = 200;

pub const Error = Allocator.Error || error{
    /// The reference is not one the current stop handed out.
    InvalidReference,
    /// Every reference a `u32` can hold was given out: no more can be made
    /// without one aliasing a stale one.
    ReferencesExhausted,
    /// No thread has that id.
    UnknownThread,
};

pub const ThreadStatus = enum { running, normal, suspended };

pub const ThreadInfo = struct {
    /// DAP's `threadId`: 1 is the main stack, and a coroutine is its header
    /// id plus 1 (header ids start at 0, the globals table's).
    id: u32,
    name: []const u8,
    status: ThreadStatus,
};

pub const StackFrame = struct {
    /// A reference for `scopes` and `evaluate`.
    id: u32,
    name: []const u8,
    /// The chunk name, `[C]` for a native's frame.
    chunk: []const u8,
    /// 1-based, 0 when the frame has no source position.
    line: u32,
    /// 1-based, counted in bytes; 0 when the chunk's source is not held.
    column: u32,
    /// The instruction's span, as byte offsets into the chunk's source.
    start: u32,
    end: u32,
    /// The frame runs a native, or the VM's own code standing for one.
    native: bool,
    proto_id: u32,
};

pub const StackPage = struct {
    frames: []StackFrame,
    /// How many frames the thread has in all.
    total: u32,
};

pub const ScopeKind = enum { locals, upvalues, globals };

pub const ScopeInfo = struct {
    kind: ScopeKind,
    name: []const u8,
    ref: u32,
    /// Listing it costs more than a frame's own variables (the globals).
    expensive: bool,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    type_name: []const u8 = "",
    /// Non-zero when the value has children to list.
    ref: u32 = 0,
    /// A table's array part, as `filter: indexed` lists it.
    indexed: u32 = 0,
    /// A table's other children, as `filter: named` lists them.
    named: u32 = 0,
};

/// `variables`' `filter`.
pub const Filter = enum { all, indexed, named };

const FrameRef = struct {
    /// The coroutine whose stack holds the frame; null is the main stack.
    thread: ?*Thread,
    index: u32,
};

const Handle = union(enum) {
    frame: FrameRef,
    scope: struct { frame: FrameRef, kind: ScopeKind },
    varargs: FrameRef,
    /// A table, function or other value with children.
    object: Value,
    /// Hash-part slots `lo..hi` of a table.
    group: struct { table: *Table, lo: u32, hi: u32 },
};

/// A chunk's source text, held for the columns of its spans and for its
/// folded `<const>`s.
const SourceEntry = struct { first: u32, count: u32, text: []const u8 };

/// One stack's frames and registers, in the running state or saved.
const StackView = struct {
    frames: []const interp.CallFrame,
    tags: []const u8,
    payloads: []const u64,
    /// The running stack, whose top frame is at the instruction about to run.
    live: bool,
};

fn stackOf(vm: *Vm, t: ?*Thread) StackView {
    if (t == vm.current) return .{ .frames = vm.frames[0..vm.depth], .tags = vm.tags, .payloads = vm.payloads, .live = true };
    const s = coroutine.savedOf(vm, t);
    return .{ .frames = s.frames[0..s.depth], .tags = s.tags, .payloads = s.payloads, .live = false };
}

const no_frames: StackView = .{ .frames = &.{}, .tags = &.{}, .payloads = &.{}, .live = false };

pub fn threadId(t: ?*const Thread) u32 {
    return if (t) |x| x.header.id + 1 else 1;
}

pub const Inspector = struct {
    gpa: Allocator,
    handles: std.ArrayList(Handle) = .empty,
    /// The reference of `handles[0]`. A resume moves it past every
    /// reference given out, so a stale one never names a new handle.
    first_ref: u32 = 1,
    /// `first_ref` could not move past the references given out. Nothing
    /// new is handed out: a wrapped reference would name a stale handle.
    exhausted: bool = false,
    /// The program has ended: the main stack lists no frames, though the VM
    /// may still hold the frames of the error that ended it.
    ended: bool = false,
    sources: std.ArrayList(SourceEntry) = .empty,

    pub fn init(gpa: Allocator) Inspector {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Inspector) void {
        self.handles.deinit(self.gpa);
        self.sources.deinit(self.gpa);
    }

    /// Forget every reference: the program resumes.
    pub fn clear(self: *Inspector) void {
        const len: u32 = @intCast(self.handles.items.len);
        if (std.math.add(u32, self.first_ref, len)) |next| self.first_ref = next else |_| self.exhausted = true;
        self.handles.clearRetainingCapacity();
    }

    /// Hold the source text of `chunk`, borrowed, for as long as the
    /// session lives. Chunks the VM compiled itself carry their own.
    pub fn addSource(self: *Inspector, chunk: *const compiler.Chunk, text: []const u8) Allocator.Error!void {
        try self.sources.append(self.gpa, .{ .first = chunk.proto.id, .count = chunk.proto_count, .text = text });
    }

    /// The source text of the chunk that holds proto `id`, if anything holds it.
    pub fn sourceOf(self: *const Inspector, vm: *const Vm, id: u32) ?[]const u8 {
        for (self.sources.items) |e| if (id >= e.first and id - e.first < e.count) return e.text;
        if (vm.loadedChunkIndexOf(id)) |i| return vm.loaded_chunks.items[i].source;
        if (vm.root_chunk) |rc| {
            const first = rc.chunk.proto.id;
            if (id >= first and id - first < rc.chunk.proto_count) return rc.source;
        }
        return null;
    }

    fn stackView(self: *const Inspector, vm: *Vm, t: ?*Thread) StackView {
        if (self.ended and t == null) return no_frames;
        return stackOf(vm, t);
    }

    fn add(self: *Inspector, h: Handle) Error!u32 {
        if (self.exhausted) return error.ReferencesExhausted;
        // The next reference, and the one after it, must exist in a `u32`.
        const next = std.math.add(u32, self.first_ref, @intCast(self.handles.items.len)) catch return error.ReferencesExhausted;
        try self.handles.append(self.gpa, h);
        return next;
    }

    fn get(self: *const Inspector, ref: u32) Error!Handle {
        if (self.exhausted or ref < self.first_ref) return error.InvalidReference;
        const i = ref - self.first_ref;
        if (i >= self.handles.items.len) return error.InvalidReference;
        return self.handles.items[i];
    }

    // ---- threads ---------------------------------------------------------

    /// The main stack, then each coroutine that has not died, by id.
    pub fn threads(_: *Inspector, vm: *Vm, arena: Allocator) Allocator.Error![]ThreadInfo {
        var list: std.ArrayList(ThreadInfo) = .empty;
        try list.append(arena, .{ .id = 1, .name = "main", .status = if (vm.current == null) .running else .normal });
        var it = vm.heap.objects;
        while (it) |h| : (it = h.next) {
            if (h.type != .thread) continue;
            const t = Thread.fromHeader(h);
            // `coroutine.running()` on the main stack makes a thread value
            // that stands for it, with no stack of its own.
            if (t == vm.main_thread) continue;
            const status: ThreadStatus = switch (t.status) {
                .dead => continue,
                .running => .running,
                .normal => .normal,
                .suspended => .suspended,
            };
            try list.append(arena, .{ .id = threadId(t), .name = try std.fmt.allocPrint(arena, "coroutine 0x{x}", .{h.id}), .status = status });
        }
        std.mem.sort(ThreadInfo, list.items[1..], {}, struct {
            fn lt(_: void, a: ThreadInfo, b: ThreadInfo) bool {
                return a.id < b.id;
            }
        }.lt);
        return list.items;
    }

    fn resolveThread(vm: *Vm, id: u32) Error!?*Thread {
        if (id == 1) return null;
        if (id == 0) return error.UnknownThread;
        var it = vm.heap.objects;
        while (it) |h| : (it = h.next) {
            if (h.type != .thread or h.id != id - 1) continue;
            const t = Thread.fromHeader(h);
            return if (t.status == .dead or t == vm.main_thread) error.UnknownThread else t;
        }
        return error.UnknownThread;
    }

    // ---- the stack -------------------------------------------------------

    /// Frames `start..start + levels` of `thread_id`'s stack, deepest first
    /// (`levels` 0 is all of them). The running coroutine's stack continues
    /// into its resumers' (§5.5).
    pub fn stackTrace(self: *Inspector, vm: *Vm, arena: Allocator, thread_id: u32, start: u32, levels: u32) Error!StackPage {
        const t = try resolveThread(vm, thread_id);
        var stacks: std.ArrayList(?*Thread) = .empty;
        if (t == vm.current) {
            var x: ?*Thread = t;
            while (true) {
                try stacks.append(arena, x);
                x = (x orelse break).resumer;
            }
        } else try stacks.append(arena, t);

        var total: u32 = 0;
        for (stacks.items) |s| total += @intCast(self.stackView(vm, s).frames.len);
        const end: u32 = if (levels == 0) total else @min(total, start +| levels);
        var out: std.ArrayList(StackFrame) = .empty;
        var base: u32 = 0;
        for (stacks.items) |s| {
            const view = self.stackView(vm, s);
            const n: u32 = @intCast(view.frames.len);
            defer base += n;
            if (base + n <= start or base >= end) continue;
            const rows = try arena.alloc(interp.FaultFrame, n);
            _ = vm.contextFrames(rows, view.frames, view.live, s);
            var g = @max(start, base);
            while (g < @min(end, base + n)) : (g += 1) {
                const row = g - base; // deepest first
                const index = n - 1 - row;
                try out.append(arena, try self.stackFrame(vm, arena, rows[row], .{ .thread = s, .index = index }));
            }
        }
        return .{ .frames = out.items, .total = total };
    }

    fn stackFrame(self: *Inspector, vm: *Vm, arena: Allocator, ff: interp.FaultFrame, at: FrameRef) Error!StackFrame {
        const name = if (ff.main_chunk)
            "main chunk"
        else if (ff.module.len != 0)
            try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ ff.module, ff.dot(), ff.name })
        else
            ff.name;
        return .{
            .id = try self.add(.{ .frame = at }),
            .name = name,
            .chunk = ff.chunk,
            .line = ff.line,
            .column = columnOf(self.sourceOf(vm, ff.proto_id), ff.start),
            .start = ff.start,
            .end = ff.end,
            .native = ff.native,
            .proto_id = ff.proto_id,
        };
    }

    fn columnOf(source: ?[]const u8, start: u32) u32 {
        const s = source orelse return 0;
        if (start > s.len) return 0;
        var i: u32 = start;
        while (i > 0 and s[i - 1] != '\n') i -= 1;
        return start - i + 1;
    }

    /// The scope frame `frame` evaluates in: its function, registers and pc.
    pub fn scopeOf(self: *Inspector, vm: *Vm, frame: u32) Error!eval.Scope {
        const h = try self.get(frame);
        if (h != .frame) return error.InvalidReference;
        return self.scopeAt(vm, h.frame);
    }

    fn scopeAt(self: *const Inspector, vm: *Vm, fr: FrameRef) eval.Scope {
        const sv = self.stackView(vm, fr.thread);
        var sc = eval.Scope.ofStack(sv.frames, sv.tags, sv.payloads, fr.index, sv.live);
        sc.source = self.sourceOf(vm, sc.proto.id);
        return sc;
    }

    // ---- scopes ----------------------------------------------------------

    /// A frame's scopes (§7.1): its locals, its upvalues, the globals.
    pub fn scopes(self: *Inspector, vm: *Vm, arena: Allocator, frame: u32) Error![]ScopeInfo {
        const h = try self.get(frame);
        if (h != .frame) return error.InvalidReference;
        const out = try arena.alloc(ScopeInfo, 3);
        out[0] = .{ .kind = .locals, .name = "Locals", .ref = try self.add(.{ .scope = .{ .frame = h.frame, .kind = .locals } }), .expensive = false };
        out[1] = .{ .kind = .upvalues, .name = "Upvalues", .ref = try self.add(.{ .scope = .{ .frame = h.frame, .kind = .upvalues } }), .expensive = false };
        out[2] = .{ .kind = .globals, .name = "Globals", .ref = try self.add(.{ .object = Value.heap(&vm.globals.header) }), .expensive = true };
        return out;
    }

    // ---- variables -------------------------------------------------------

    /// The children of `ref`: `start` and `count` page them (`count` 0 is
    /// all). `filter` splits a table's array part from its other children.
    pub fn variables(self: *Inspector, vm: *Vm, arena: Allocator, ref: u32, filter: Filter, start: u32, count: u32) Error![]Variable {
        const h = try self.get(ref);
        var out: std.ArrayList(Variable) = .empty;
        switch (h) {
            .frame => return error.InvalidReference,
            .scope => |s| {
                const all = switch (s.kind) {
                    .locals => try self.localsOf(vm, arena, s.frame),
                    .upvalues => try self.upvaluesOf(vm, arena, s.frame),
                    .globals => unreachable,
                };
                return pageOf(Variable, all, start, count);
            },
            .varargs => |fr| {
                const sv = self.stackView(vm, fr.thread);
                const f = &sv.frames[fr.index];
                const lo = @min(start, f.varargs_count);
                const hi = if (count == 0) f.varargs_count else @min(f.varargs_count, lo + count);
                var i = lo;
                while (i < hi) : (i += 1) {
                    const slot = f.varargs_base + i;
                    const v: Value = .{ .tag = @enumFromInt(sv.tags[slot]), .payload = .{ .bits = sv.payloads[slot] } };
                    try out.append(arena, try self.variable(arena, try std.fmt.allocPrint(arena, "[{d}]", .{i + 1}), v));
                }
            },
            .object => |v| try self.objectChildren(arena, v, filter, start, count, &out),
            .group => |g| {
                var skipped: u32 = 0;
                var n: u32 = 0;
                const nodes = g.table.hash.nodes orelse return out.items;
                var slot = g.lo;
                while (slot < g.hi) : (slot += 1) {
                    const node = &nodes[slot];
                    if (node.key_tag == .nil or node.value.isNil()) continue;
                    if (skipped < start) {
                        skipped += 1;
                        continue;
                    }
                    if (count != 0 and n == count) break;
                    n += 1;
                    try out.append(arena, try self.entry(arena, node));
                }
            },
        }
        return out.items;
    }

    fn pageOf(comptime T: type, all: []T, start: u32, count: u32) []T {
        const lo = @min(start, all.len);
        const hi = if (count == 0) all.len else @min(all.len, lo + count);
        return all[lo..hi];
    }

    /// A frame's locals visible at its pc (§4, §7.1): the later row wins a
    /// shared name, a dead register shows as unavailable, a folded
    /// `<const>` is its literal, and `...` lists the varargs.
    fn localsOf(self: *Inspector, vm: *Vm, arena: Allocator, fr: FrameRef) Error![]Variable {
        const sc = self.scopeAt(vm, fr);
        const rows = sc.proto.locals;
        var picked: std.ArrayList(usize) = .empty;
        var i = rows.len;
        while (i > 0) {
            i -= 1;
            if (!rows[i].visibleAt(sc.pc)) continue;
            var dup = false;
            for (picked.items) |p| {
                if (std.mem.eql(u8, rows[p].name, rows[i].name)) dup = true;
            }
            if (!dup) try picked.append(arena, i);
        }
        std.mem.reverse(usize, picked.items);
        var out: std.ArrayList(Variable) = .empty;
        for (picked.items) |p| {
            const lv = rows[p];
            switch (lv.loc) {
                .reg => |r| {
                    const live = sc.proto.reg_live;
                    if (live.available() and sc.pc < sc.proto.code.len and !live.liveIn(sc.pc, r)) {
                        try out.append(arena, .{ .name = lv.name, .value = "<unavailable>" });
                    } else {
                        try out.append(arena, try self.variable(arena, lv.name, sc.reg(r)));
                    }
                },
                .literal => |span| switch (try eval.foldedValue(arena, vm, sc, lv.name, span)) {
                    .ok => |v| try out.append(arena, try self.variableOfVal(arena, lv.name, v)),
                    .refused, .failed => |why| try out.append(arena, .{
                        .name = lv.name,
                        .value = try std.fmt.allocPrint(arena, "<unavailable: {s}>", .{why}),
                    }),
                },
            }
        }
        const sv = self.stackView(vm, fr.thread);
        const f = &sv.frames[fr.index];
        if (sc.proto.is_vararg and f.varargs_count > 0) {
            try out.append(arena, .{
                .name = "...",
                .value = try std.fmt.allocPrint(arena, "({d} values)", .{f.varargs_count}),
                .ref = try self.add(.{ .varargs = fr }),
                .indexed = @intCast(f.varargs_count),
            });
        }
        return out.items;
    }

    fn upvaluesOf(self: *Inspector, vm: *Vm, arena: Allocator, fr: FrameRef) Error![]Variable {
        const sc = self.scopeAt(vm, fr);
        const cl = sc.closure orelse return &.{};
        return self.closureUpvalues(arena, cl);
    }

    fn closureUpvalues(self: *Inspector, arena: Allocator, cl: *const function.Closure) Error![]Variable {
        var out: std.ArrayList(Variable) = .empty;
        for (cl.upvalues, 0..) |cell, i| {
            const v: Value = .{ .tag = @enumFromInt(cell.tag.*), .payload = .{ .bits = cell.payload.* } };
            try out.append(arena, try self.variable(arena, cl.proto.upvalName(i) orelse "?", v));
        }
        return out.items;
    }

    fn objectChildren(self: *Inspector, arena: Allocator, v: Value, filter: Filter, start: u32, count: u32, out: *std.ArrayList(Variable)) Error!void {
        if (v.isRowView() or !v.isHeap()) return;
        switch (v.heapType()) {
            .table => try self.tableChildren(arena, Table.fromHeader(v.asHeap()), filter, start, count, out),
            .function => {
                const all = try self.closureUpvalues(arena, function.Closure.fromHeader(v.asHeap()));
                try out.appendSlice(arena, pageOf(Variable, all, start, count));
            },
            else => {},
        }
    }

    /// The array part's positions 1..: a grid's rows, or the slots after
    /// slot 0 (key 0 is listed among the named children when it holds one).
    fn indexedCount(t: *const Table) u32 {
        if (t.array.isGrid()) return @intCast(t.array.gridRows());
        return @intCast(t.array.asize -| 1);
    }

    fn zeroKeyed(t: *const Table) bool {
        return !t.array.isGrid() and t.array.asize > 0 and !t.array.get(0).isNil();
    }

    fn grouped(t: *const Table) bool {
        return t.hash.capacity() > group_size;
    }

    fn groupCount(t: *const Table) u32 {
        return (t.hash.capacity() + group_size - 1) / group_size;
    }

    fn namedPrefix(t: *const Table) u32 {
        return @as(u32, if (t.metatable != null) 1 else 0) + @as(u32, if (zeroKeyed(t)) 1 else 0);
    }

    fn namedCount(t: *const Table) u32 {
        return namedPrefix(t) + if (grouped(t)) groupCount(t) else t.hash.count();
    }

    /// A table's children (§7.2). Positions: the array part, then the named
    /// ones (`[metatable]`, key 0, the hash part or its groups); `filter`
    /// picks one run, and `start`/`count` page within what it picks.
    fn tableChildren(self: *Inspector, arena: Allocator, t: *Table, filter: Filter, start: u32, count: u32, out: *std.ArrayList(Variable)) Error!void {
        const idx_n: u32 = indexedCount(t);
        const named_n: u32 = namedCount(t);
        const first_named: u32 = if (filter == .all) idx_n else 0;
        const total: u32 = switch (filter) {
            .all => idx_n + named_n,
            .indexed => idx_n,
            .named => named_n,
        };
        const lo = @min(start, total);
        const hi = if (count == 0) total else @min(total, lo +| count);

        if (filter != .named) {
            var j = lo;
            while (j < @min(hi, idx_n)) : (j += 1) {
                const key: i64 = @as(i64, j) + 1;
                try out.append(arena, try self.variable(arena, try std.fmt.allocPrint(arena, "[{d}]", .{key}), t.getInt(key)));
            }
        }
        if (filter == .indexed or hi <= first_named) return;

        // The live entries of a hash part that is not grouped, in slot order.
        var live: std.ArrayList(*const hash_part.Node) = .empty;
        if (!grouped(t)) {
            if (t.hash.nodes) |nodes| {
                var slot: u32 = 0;
                while (slot <= t.hash.mask) : (slot += 1) {
                    const node = &nodes[slot];
                    if (node.key_tag != .nil and !node.value.isNil()) try live.append(arena, node);
                }
            }
        }
        const prefix = namedPrefix(t);
        var n = @max(lo, first_named) - first_named;
        const stop_at = hi - first_named;
        while (n < stop_at) : (n += 1) {
            if (n < prefix) {
                // `[metatable]` first, then key 0.
                const meta_slot = t.metatable != null and n == 0;
                if (meta_slot) {
                    try out.append(arena, try self.variable(arena, "[metatable]", Value.heap(&t.metatable.?.header)));
                } else {
                    try out.append(arena, try self.variable(arena, "[0]", t.array.get(0)));
                }
                continue;
            }
            const g = n - prefix;
            if (grouped(t)) {
                const g_lo = g * group_size;
                const g_hi = @min(t.hash.capacity(), g_lo + group_size);
                try out.append(arena, .{
                    .name = try std.fmt.allocPrint(arena, "[slots {d}\u{2013}{d}]", .{ g_lo, g_hi - 1 }),
                    .value = "",
                    .ref = try self.add(.{ .group = .{ .table = t, .lo = g_lo, .hi = g_hi } }),
                });
            } else {
                try out.append(arena, try self.entry(arena, live.items[g]));
            }
        }
    }

    /// One hash node as a variable named by its key.
    fn entry(self: *Inspector, arena: Allocator, node: *const hash_part.Node) Error!Variable {
        const k = node.key();
        const name = if (!k.isRowView() and k.isHeap() and k.heapType() == .string)
            try textOf(arena, string.String.fromHeader(k.asHeap()).bytes(), false)
        else
            try std.fmt.allocPrint(arena, "[{s}]", .{try render(arena, k)});
        return self.variable(arena, name, node.value);
    }

    // ---- rendering -------------------------------------------------------

    fn variableOfVal(self: *Inspector, arena: Allocator, name: []const u8, v: eval.Val) Error!Variable {
        return switch (v) {
            .value => |x| self.variable(arena, name, x),
            .text => |bytes| .{ .name = name, .value = try textOf(arena, bytes, true), .type_name = "string" },
        };
    }

    /// `v` as a variable: its text and type, and a reference when it has
    /// children to list.
    fn variable(self: *Inspector, arena: Allocator, name: []const u8, v: Value) Error!Variable {
        var out: Variable = .{ .name = name, .value = try render(arena, v), .type_name = if (v.isRowView()) "table" else v.typeName() };
        if (v.isRowView() or !v.isHeap()) return out;
        switch (v.heapType()) {
            .table => {
                const t = Table.fromHeader(v.asHeap());
                out.ref = try self.add(.{ .object = v });
                out.indexed = indexedCount(t);
                out.named = namedCount(t);
            },
            .function => {
                const cl = function.Closure.fromHeader(v.asHeap());
                if (cl.upvalues.len != 0) {
                    out.ref = try self.add(.{ .object = v });
                    out.named = @intCast(cl.upvalues.len);
                }
            },
            else => {},
        }
        return out;
    }
};

/// A value as text, capped, and never through `__tostring` or `__name`
/// (D6): a string is quoted, anything else is `io.writeValue`'s form.
pub fn render(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    if (!v.isRowView() and v.isHeap() and v.heapType() == .string)
        return textOf(arena, string.String.fromHeader(v.asHeap()).bytes(), true);
    var buf: [128]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    io.writeValue(&w, v) catch {};
    return arena.dupe(u8, w.buffered());
}

/// `bytes` cut to `text_cap` (at a character boundary), with an ellipsis
/// when cut, in quotes when `quoted`.
fn textOf(arena: Allocator, bytes: []const u8, quoted: bool) Allocator.Error![]const u8 {
    var n = @min(bytes.len, text_cap);
    if (n < bytes.len) while (n > 0 and bytes[n] & 0xC0 == 0x80) : (n -= 1) {};
    const cut = n < bytes.len;
    const q: []const u8 = if (quoted) "\"" else "";
    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ q, bytes[0..n], if (cut) "\u{2026}" else "", q });
}

test "doc 86 P2: references are never reused, and running out is an error, not a wrap" {
    var ins = Inspector.init(std.testing.allocator);
    defer ins.deinit();
    ins.first_ref = std.math.maxInt(u32) - 2;
    const a = try ins.add(.{ .object = Value.nil() });
    const b = try ins.add(.{ .object = Value.nil() });
    try std.testing.expect(a != b and b > a);
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, b);
    // `maxInt(u32)` is still a reference; the one after would wrap.
    const c = try ins.add(.{ .object = Value.nil() });
    try std.testing.expectEqual(std.math.maxInt(u32), c);
    try std.testing.expectError(error.ReferencesExhausted, ins.add(.{ .object = Value.nil() }));
    _ = try ins.get(a);
    // A resume moves past them: nothing new may be named, and the old are gone.
    ins.clear();
    try std.testing.expectError(error.ReferencesExhausted, ins.add(.{ .object = Value.nil() }));
    try std.testing.expectError(error.InvalidReference, ins.get(a));
    try std.testing.expectError(error.InvalidReference, ins.get(c));
    try std.testing.expectError(error.InvalidReference, ins.get(0));
}
