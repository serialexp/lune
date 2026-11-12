//! Line breakpoints (doc 86 §5.2): which pcs of which protos the session
//! stops at, and what each client breakpoint is bound to.
//!
//! A source is named by its chunk name (`Proto.chunk`), exactly as the
//! compiler recorded it; mapping a client's file path to that name is the
//! transport's job. Each chunk the session learns of is indexed once: the
//! first pc of every line in every proto, sorted by line. Binding a line
//! then costs a binary search, and the dispatch-time test is one bitset
//! probe in the current proto (`at`).
//!
//! A breakpoint on a line with no code moves to the next line that has
//! code in that chunk, and binds at every pc of that line in every proto
//! with code there (an outer function and a closure on one line both
//! stop). Which of those pcs stop is the session's line-visit test
//! (`session.LineVisits`): a breakpoint stops once per visit to its line,
//! so a one-line loop stops on every pass (Bart, 2026-11-11). A breakpoint
//! whose source has no chunk yet is pending (`verified = false`) until
//! `addChunk` indexes one with that name.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const eval = @import("eval.zig");

const Proto = bytecode.Proto;
const Allocator = std.mem.Allocator;

/// One breakpoint the client asks for on a source.
pub const Request = struct {
    line: u32,
    /// An expression for the pure-read evaluator (§7.3): the breakpoint
    /// stops only where it is truthy.
    condition: ?[]const u8 = null,
    /// DAP's `hitCondition`: `N` (the Nth hit), `>= N` (from the Nth on)
    /// or `% N` (every Nth). Hits count only where the condition holds.
    hit_condition: ?[]const u8 = null,
};

/// A breakpoint as the client sees it: `line` is the line it is bound to
/// once verified, else the line it asked for.
pub const Breakpoint = struct {
    id: u32,
    line: u32,
    verified: bool,
    /// Why it is not verified, when that is not a missing chunk.
    message: ?[]const u8 = null,
};

/// A parsed `hitCondition`.
pub const HitCondition = union(enum) {
    eq: u64,
    ge: u64,
    every: u64,

    /// Parse DAP's `hitCondition` text, or null when it is malformed.
    pub fn parse(text: []const u8) ?HitCondition {
        const t = std.mem.trim(u8, text, " \t");
        if (std.mem.startsWith(u8, t, ">=")) return .{ .ge = number(t[2..]) orelse return null };
        if (std.mem.startsWith(u8, t, "%")) {
            const n = number(t[1..]) orelse return null;
            return if (n == 0) null else .{ .every = n };
        }
        if (std.mem.startsWith(u8, t, "==")) return .{ .eq = number(t[2..]) orelse return null };
        return .{ .eq = number(t) orelse return null };
    }

    fn number(text: []const u8) ?u64 {
        return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t"), 10) catch null;
    }

    /// Whether the hit numbered `count` (from 1) stops.
    pub fn admits(self: HitCondition, count: u64) bool {
        return switch (self) {
            .eq => |n| count == n,
            .ge => |n| count >= n,
            .every => |n| count % n == 0,
        };
    }
};

pub const Entry = struct {
    id: u32,
    req_line: u32,
    line: u32,
    verified: bool,
    /// Owned by the table.
    condition: ?[]u8 = null,
    hit_condition: ?HitCondition = null,
    /// Set when the client's `hitCondition` does not parse; the
    /// breakpoint then never binds.
    invalid: ?[]const u8 = null,
    /// The hits so far where the condition held.
    hits: u64 = 0,
    /// The condition's evaluation failure was reported (it is reported
    /// once per breakpoint).
    condition_reported: bool = false,
    /// The condition, parsed at its first hit and kept.
    compiled: ?*eval.Condition = null,
    /// How many times `compiled` was parsed: once, however many hits.
    parses: u32 = 0,

    fn view(self: Entry) Breakpoint {
        return .{
            .id = self.id,
            .line = if (self.verified) self.line else self.req_line,
            .verified = self.verified,
            .message = self.invalid,
        };
    }

    fn deinit(self: *Entry, gpa: Allocator) void {
        if (self.condition) |c| gpa.free(c);
        if (self.compiled) |c| c.deinit(gpa);
    }
};

const Source = struct {
    name: []u8,
    entries: std.ArrayList(Entry) = .empty,
};

/// A pc of `line` in `proto`.
const Site = struct {
    line: u32,
    proto: *const Proto,
    pc: u32,
};

const Chunk = struct {
    root: *const Proto,
    /// Sorted by line, then proto, then pc.
    sites: []Site,
};

/// One bound breakpoint at a pc.
const Hit = struct {
    pc: u32,
    id: u32,
};

/// The breakpoints bound in one proto.
const ProtoPcs = struct {
    bits: std.DynamicBitSetUnmanaged,
    /// Sorted by pc; several breakpoints may share a pc.
    hits: std.ArrayList(Hit) = .empty,
    /// The ids at one pc, the slice `at` returns.
    fn idsAt(self: *const ProtoPcs, pc: u32, out: *std.ArrayList(u32), gpa: Allocator) !void {
        const first = std.sort.lowerBound(Hit, self.hits.items, pc, cmpHitPc);
        for (self.hits.items[first..]) |h| {
            if (h.pc != pc) break;
            try out.append(gpa, h.id);
        }
    }

    fn cmpHitPc(pc: u32, h: Hit) std.math.Order {
        return std.math.order(pc, h.pc);
    }
};

pub const Table = struct {
    gpa: Allocator,
    next_id: u32 = 1,
    sources: std.ArrayList(Source) = .empty,
    chunks: std.ArrayList(Chunk) = .empty,
    by_proto: std.AutoHashMapUnmanaged(*const Proto, ProtoPcs) = .empty,
    /// The ids `at` last returned; reused, so a hit allocates nothing once
    /// it has grown.
    hit_ids: std.ArrayList(u32) = .empty,
    /// The last proto `at` looked up, and its entry (null for none). Any
    /// change to `by_proto` clears it.
    cache_proto: ?*const Proto = null,
    cache: ?*const ProtoPcs = null,

    pub fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Table) void {
        for (self.sources.items) |*s| {
            self.gpa.free(s.name);
            for (s.entries.items) |*e| e.deinit(self.gpa);
            s.entries.deinit(self.gpa);
        }
        self.sources.deinit(self.gpa);
        for (self.chunks.items) |c| self.gpa.free(c.sites);
        self.chunks.deinit(self.gpa);
        self.clearBound();
        self.by_proto.deinit(self.gpa);
        self.hit_ids.deinit(self.gpa);
    }

    /// Whether any breakpoint is set, bound or pending.
    pub fn isEmpty(self: *const Table) bool {
        for (self.sources.items) |s| if (s.entries.items.len != 0) return false;
        return true;
    }

    pub fn hasChunk(self: *const Table, root: *const Proto) bool {
        for (self.chunks.items) |c| if (c.root == root) return true;
        return false;
    }

    /// Index a chunk (its root proto), and bind the breakpoints of its
    /// source in it. `changed` gets each breakpoint whose binding this
    /// changed: a pending one now verified. The chunk must outlive the
    /// table. A chunk of the VM's own code (`system`) is never indexed.
    pub fn addChunk(self: *Table, root: *const Proto, changed: ?*std.ArrayList(Breakpoint)) !void {
        if (root.system or self.hasChunk(root)) return;
        const sites = try indexChunk(self.gpa, root);
        self.chunks.append(self.gpa, .{ .root = root, .sites = sites }) catch |err| {
            self.gpa.free(sites);
            return err;
        };
        // From here the table owns `sites`. A failure while binding leaves
        // the chunk indexed and the table consistent, with some breakpoints
        // unbound until the next `set` binds them all again.
        const s = self.findSourceMut(root.chunk) orelse return;
        const chunk = self.chunks.items[self.chunks.items.len - 1];
        for (s.entries.items) |*e| {
            const was = e.view();
            try self.bindIn(e, chunk);
            if (changed) |out| if (!std.meta.eql(was, e.view())) try out.append(self.gpa, e.view());
        }
    }

    /// Replace the breakpoints of `source` with `requests`, and write each
    /// one's binding to `out` (same length, same order). A request for a
    /// line that already had a breakpoint keeps that breakpoint's id and
    /// its hit count.
    pub fn set(self: *Table, source: []const u8, requests: []const Request, out: []Breakpoint) !void {
        std.debug.assert(out.len == requests.len);
        const s = try self.sourceFor(source);
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(self.gpa);
            entries.deinit(self.gpa);
        }
        try entries.ensureTotalCapacity(self.gpa, requests.len);
        var reused: std.DynamicBitSetUnmanaged = try .initEmpty(self.gpa, s.entries.items.len);
        defer reused.deinit(self.gpa);
        for (requests) |r| {
            // An empty condition is none: clients send "" for a breakpoint
            // that has none.
            const cond_text: ?[]const u8 = if (r.condition) |c| (if (std.mem.trim(u8, c, " \t").len == 0) null else c) else null;
            // The breakpoint it was: the one asked for at this line, else
            // the one that was bound to this line (a client sends back the
            // line a breakpoint moved to).
            const old_ix = findOld(s.entries.items, &reused, r.line);
            const condition = if (cond_text) |c| try self.gpa.dupe(u8, c) else null;
            errdefer if (condition) |c| self.gpa.free(c);
            var e: Entry = .{ .id = 0, .req_line = r.line, .line = 0, .verified = false, .condition = condition };
            if (old_ix) |i| {
                const old = &s.entries.items[i];
                reused.set(i);
                e.id = old.id;
                e.hits = old.hits;
                // The same condition keeps its parse, and its report.
                if (old.condition != null and condition != null and std.mem.eql(u8, old.condition.?, condition.?)) {
                    e.compiled = old.compiled;
                    old.compiled = null;
                    e.parses = old.parses;
                    e.condition_reported = old.condition_reported;
                }
            } else {
                e.id = self.next_id;
                self.next_id += 1;
            }
            if (r.hit_condition) |text| {
                if (std.mem.trim(u8, text, " \t").len != 0) {
                    e.hit_condition = HitCondition.parse(text);
                    if (e.hit_condition == null) e.invalid = "the hit condition is not N, >= N or % N";
                }
            }
            entries.appendAssumeCapacity(e);
        }
        for (s.entries.items) |*e| e.deinit(self.gpa);
        s.entries.deinit(self.gpa);
        s.entries = entries;
        // The source owns them now. A failing `rebind` leaves them unbound,
        // not freed.
        entries = .empty;
        try self.rebind();
        for (s.entries.items, out) |e, *o| o.* = e.view();
    }

    /// The breakpoint of `old` that a request for `line` continues: the one
    /// that asked for this line, else the one bound to it. Taken ones are
    /// skipped.
    fn findOld(old: []const Entry, taken: *const std.DynamicBitSetUnmanaged, line: u32) ?usize {
        for (old, 0..) |e, i| if (!taken.isSet(i) and e.req_line == line) return i;
        for (old, 0..) |e, i| if (!taken.isSet(i) and e.verified and e.line == line) return i;
        return null;
    }

    /// The breakpoint `id`, while it is set. The pointer lives until the
    /// next `set`.
    pub fn entry(self: *Table, id: u32) ?*Entry {
        for (self.sources.items) |*s| {
            for (s.entries.items) |*e| if (e.id == id) return e;
        }
        return null;
    }

    /// The ids of the breakpoints bound at `pc` of `proto`, or null for
    /// none. The slice lives until the next call.
    pub fn at(self: *Table, proto: *const Proto, pc: usize) !?[]const u32 {
        if (self.cache_proto != proto) {
            self.cache_proto = proto;
            self.cache = self.by_proto.getPtr(proto);
        }
        const pcs = self.cache orelse return null;
        if (pc >= pcs.bits.bit_length or !pcs.bits.isSet(pc)) return null;
        self.hit_ids.clearRetainingCapacity();
        try pcs.idsAt(@intCast(pc), &self.hit_ids, self.gpa);
        return self.hit_ids.items;
    }

    fn findSourceMut(self: *Table, name: []const u8) ?*Source {
        for (self.sources.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    fn sourceFor(self: *Table, name: []const u8) !*Source {
        if (self.findSourceMut(name)) |s| return s;
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.sources.append(self.gpa, .{ .name = owned });
        return &self.sources.items[self.sources.items.len - 1];
    }

    fn clearBound(self: *Table) void {
        var it = self.by_proto.valueIterator();
        while (it.next()) |p| {
            p.bits.deinit(self.gpa);
            p.hits.deinit(self.gpa);
        }
        self.by_proto.clearRetainingCapacity();
        self.cache_proto = null;
        self.cache = null;
    }

    /// Bind every breakpoint again, over every chunk.
    fn rebind(self: *Table) !void {
        self.clearBound();
        for (self.sources.items) |*s| {
            for (s.entries.items) |*e| {
                e.verified = false;
                e.line = 0;
                for (self.chunks.items) |c| {
                    if (std.mem.eql(u8, c.root.chunk, s.name)) try self.bindIn(e, c);
                }
            }
        }
    }

    /// Bind `e` in `chunk`, whose source it is: at the first line at or
    /// after the one asked for that has code. The first chunk to bind it
    /// fixes the line it reports.
    fn bindIn(self: *Table, e: *Entry, chunk: Chunk) !void {
        if (e.invalid != null) return;
        const first = std.sort.lowerBound(Site, chunk.sites, e.req_line, cmpLine);
        if (first == chunk.sites.len) return;
        const line = chunk.sites[first].line;
        var i = first;
        while (i < chunk.sites.len and chunk.sites[i].line == line) : (i += 1) {
            try self.bindPc(chunk.sites[i].proto, chunk.sites[i].pc, e.id);
        }
        if (!e.verified) {
            e.verified = true;
            e.line = line;
        }
    }

    fn cmpLine(line: u32, site: Site) std.math.Order {
        return std.math.order(line, site.line);
    }

    fn bindPc(self: *Table, proto: *const Proto, pc: u32, id: u32) !void {
        self.cache_proto = null;
        self.cache = null;
        const gop = try self.by_proto.getOrPut(self.gpa, proto);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .bits = std.DynamicBitSetUnmanaged.initEmpty(self.gpa, proto.code.len) catch |err| {
                _ = self.by_proto.remove(proto);
                return err;
            } };
        }
        const pcs = gop.value_ptr;
        var at_ix: usize = pcs.hits.items.len;
        while (at_ix > 0 and pcs.hits.items[at_ix - 1].pc > pc) at_ix -= 1;
        try pcs.hits.insert(self.gpa, at_ix, .{ .pc = pc, .id = id });
        pcs.bits.set(pc);
    }
};

/// Every pc of every proto of the chunk at `root`, sorted by line, then
/// proto, then pc. Instructions with no line (span line 0) are not
/// breakable.
fn indexChunk(gpa: Allocator, root: *const Proto) ![]Site {
    var all: std.ArrayList(Site) = .empty;
    errdefer all.deinit(gpa);
    try collect(gpa, &all, root);
    std.mem.sortUnstable(Site, all.items, {}, lessSite);
    return all.toOwnedSlice(gpa);
}

fn collect(gpa: Allocator, out: *std.ArrayList(Site), proto: *const Proto) !void {
    if (proto.system) return;
    const n = @min(proto.code.len, proto.spans.len);
    try out.ensureUnusedCapacity(gpa, n);
    for (proto.spans[0..n], 0..) |span, pc| {
        if (span.line == 0) continue;
        out.appendAssumeCapacity(.{ .line = span.line, .proto = proto, .pc = @intCast(pc) });
    }
    for (proto.protos) |child| try collect(gpa, out, child);
}

fn lessSite(_: void, a: Site, b: Site) bool {
    if (a.line != b.line) return a.line < b.line;
    if (a.proto.id != b.proto.id) return a.proto.id < b.proto.id;
    if (a.proto != b.proto) return @intFromPtr(a.proto) < @intFromPtr(b.proto);
    return a.pc < b.pc;
}
