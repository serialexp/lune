//! Doc 60 §6.1 stage 1: the H1 host-call entry (`mh_call` → `hostcallSlow`,
//! closure callees through `pushHostCall` + `runPushedFrame`) diffed against
//! the pre-H1 path (`capi.hostcallReference` → `runProtected` → `callValue`).
//!
//! Every test runs the same script and the same call sequence on two VMs:
//! leg 0 is H1, leg 1 the reference. The reference VM dispatches on the
//! original nine-condition predicate (`Vm.reference_dispatch`), so the two
//! legs cannot share a packed-word bug. After every call both VMs are
//! rendered into a normalized snapshot (`snap`) and the snapshots must be
//! identical. Heap values are rendered by first-seen ordinal (never by
//! address), shared across the whole snapshot so aliasing is compared, with
//! their content on first sight: string bytes, table entries and metatable,
//! a closure's proto and upvalue cells (open slot or closed value), a
//! native's name. Beyond values: status/results/`last_error`/`fatal`,
//! depth, `stack_top`, `native_reentry_depth`, the live registers, call and
//! safepoint sequences, the safepoint line index, the effect counters,
//! region context and every region activation (key and accumulator), open
//! upvalue cells (identity, slot, value), `final_cut`, `fast_block` and the
//! pending anchors and arm requests, an in-flight recording's kind and IR,
//! the frame-link arm counters, the heap's object count and id counter, the
//! host-call frame slot, and the parked values in order and with
//! multiplicity. The serialized effect log, committed traces and (where
//! host functions are not registered, doc 59 E6/E8) keyframe are compared
//! byte for byte. A host `peek()` takes the same snapshot mid-call, so
//! live frames, open cells and nested reentry are compared too.
//!
//! Every scenario runs on all three tiers: JIT off, the tier-1 IR
//! interpreter, and native code (`Tier`). The embedding has no record/replay
//! mode today (`createVm` keeps effects `.off`, doc 59 §3.7), so there is no
//! replay leg to run. Not covered here: `next_call_seq` exhaustion, which
//! panics in both legs through the same `pushFrameTrusted` (needs a
//! subprocess harness — doc 60 Outstanding).

const std = @import("std");
const testing = std.testing;
const capi = @import("capi.zig");
const mahina = @import("mahina");

const Value = mahina.Value;
const String = mahina.string.String;
const mh_value = capi.mh_value;
const mh_str = capi.mh_str;
const Status = capi.mh_status;

const Tier = enum { off, tier1, native };
const tiers = [_]Tier{ .off, .tier1, .native };

fn s(bytes: []const u8) mh_str {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

// Deterministic host sources: both legs must see the same clock and seed.
var det_ctx: u8 = 0;
fn detClock(_: *anyopaque) i64 {
    return 1_000_000;
}
fn detSeed(_: *anyopaque) u64 {
    return 0x5eed_5eed;
}

/// The two entries under comparison. Leg 0 is the code under test.
fn entry(leg: usize, vm: ?*capi.VmBox, callee: mh_value, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: ?*usize) Status {
    return if (leg == 0)
        capi.mh_call(vm, callee, args, nargs, results, max_results, nresults)
    else
        capi.hostcallReference(vm, callee, args, nargs, results, max_results, nresults);
}

fn lastError(box: *capi.VmBox) []const u8 {
    const e = capi.mh_last_error(box);
    if (e.ptr) |p| return p[0..e.len];
    return "";
}

fn asValue(cv: *const mh_value) Value {
    return @as(*const Value, @ptrCast(cv)).*;
}

// ---------------------------------------------------------------------------
// normalized snapshot
// ---------------------------------------------------------------------------

const Dump = struct {
    gpa: std.mem.Allocator,
    /// Not walked: its contents are the keyframe's job (and huge).
    globals: *const mahina.object.GcHeader,
    buf: std.ArrayList(u8) = .empty,
    /// Object (and upvalue cell) address → first-seen ordinal, shared by
    /// every root in the snapshot, so aliasing is compared too.
    ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,

    fn deinit(self: *Dump) void {
        self.buf.deinit(self.gpa);
        self.ids.deinit(self.gpa);
    }

    fn p(self: *Dump, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.print(self.gpa, fmt, args);
    }

    /// The ordinal for `addr`, and whether this is its first sighting.
    fn ordinal(self: *Dump, addr: usize) !struct { id: u32, first: bool } {
        const gop = try self.ids.getOrPut(self.gpa, addr);
        if (!gop.found_existing) gop.value_ptr.* = self.ids.count() - 1;
        return .{ .id = gop.value_ptr.*, .first = !gop.found_existing };
    }

    fn val(self: *Dump, v: Value) anyerror!void {
        switch (v.tag) {
            .heap_ref => try self.obj(v),
            // A transient handle onto a grid row: the parent grid by identity
            // (and content, on its first sighting), then the row index.
            .row_view => {
                try self.p("row[", .{});
                try self.obj(Value.heap(v.rowViewParent()));
                try self.p("]#{d}", .{v.rowViewRow()});
            },
            else => try self.p("{s}:{x}", .{ @tagName(v.tag), v.payload.bits }),
        }
        try self.p(" ", .{});
    }

    /// A proto by first-seen ordinal (its `id` is unique only within one
    /// compiled chunk, and several chunks are live), with name and id on its
    /// first sighting: two `anonymous` closures never render alike.
    fn proto(self: *Dump, pr: *const mahina.bytecode.Proto) !void {
        const o = try self.ordinal(@intFromPtr(pr));
        try self.p("P{d}", .{o.id});
        if (o.first) try self.p(":{s}#{d}", .{ pr.name, pr.id });
    }

    /// A heap object by ordinal, never by address. The first sighting also
    /// prints its content, recursively (strings, table entries and
    /// metatable, a closure's proto and upvalue cells, a native's name);
    /// later sightings print the ordinal alone, which closes cycles.
    fn obj(self: *Dump, v: Value) anyerror!void {
        const h = v.asHeap();
        const o = try self.ordinal(@intFromPtr(h));
        try self.p("h{d}", .{o.id});
        if (!o.first) return;
        try self.p(":{s}", .{@tagName(v.heapType())});
        switch (v.heapType()) {
            .string => try self.p("\"{s}\"", .{String.fromHeader(h).bytes()}),
            .table => {
                if (h == self.globals) return self.p("(globals)", .{});
                const t = mahina.table.Table.fromHeader(h);
                try self.p("{{", .{});
                if (t.array.isGrid()) {
                    // Grid rows are virtual (keys `1..rows`, doc 18 D6): read
                    // every physical cell of every row directly, without
                    // minting row views.
                    const a = &t.array;
                    try self.p("grid rows={d} stride={d}", .{ a.gridRows(), a.stride });
                    for (0..a.gridRows()) |r| {
                        try self.p(" [len={d}:", .{a.gridRowLen(r)});
                        for (0..a.stride) |c| try self.val(a.gridGet(r, c));
                        try self.p("]", .{});
                    }
                } else {
                    // Dense keys `0..asize-1` (slot 0 is a hole for 1-based use).
                    for (0..t.array.asize) |i| try self.val(t.array.get(i));
                }
                try self.p("|", .{});
                var it = t.hash.iterator();
                while (it.next()) |e| {
                    try self.val(e.key_ptr.*);
                    try self.p("= ", .{});
                    try self.val(e.value_ptr.*);
                }
                if (t.metatable) |mt| {
                    try self.p("mt=", .{});
                    try self.val(Value.heap(&mt.header));
                }
                try self.p("}}", .{});
            },
            .function => {
                const cl = mahina.function.Closure.fromHeader(h);
                try self.p("<", .{});
                try self.proto(cl.proto);
                for (cl.upvalues) |u| {
                    const uo = try self.ordinal(@intFromPtr(u));
                    try self.p(" u{d}", .{uo.id});
                    if (!uo.first) continue;
                    switch (u.loc) {
                        .open => |slot| try self.p("=open@{d}", .{slot}),
                        .closed => |cv| {
                            try self.p("=", .{});
                            try self.val(cv);
                        },
                    }
                }
                try self.p(">", .{});
            },
            .native => try self.p("<{s}>", .{mahina.function.Native.fromHeader(h).name}),
            else => {},
        }
    }

    fn anchor(self: *Dump, k: ?mahina.trace.AnchorKey) !void {
        const a = k orelse return self.p("- ", .{});
        try self.proto(a.proto);
        try self.p("@{d} ", .{a.pc});
    }

    /// A serialized artifact: compared byte for byte (`Snap.blobs`); the text
    /// carries only its label and length, so a mismatch report stays short.
    fn blob(self: *Dump, blobs: *std.ArrayList(Blob), label: []const u8, bytes: []u8) !void {
        errdefer self.gpa.free(bytes);
        try self.p("{s}: len={d}\n", .{ label, bytes.len });
        try blobs.append(self.gpa, .{ .label = label, .bytes = bytes });
    }
};

const Blob = struct { label: []const u8, bytes: []u8 };

/// One leg's normalized state after a call: the text dump plus the
/// serialized artifacts (effect log, committed traces, keyframe).
const Snap = struct {
    text: []u8,
    blobs: []Blob,

    fn deinit(self: Snap, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        for (self.blobs) |b| gpa.free(b.bytes);
        gpa.free(self.blobs);
    }
};

fn lessThanStr(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn snap(gpa: std.mem.Allocator, box: *capi.VmBox, status: Status, results: []const mh_value, nres: usize, keyframe: bool) !Snap {
    const vm = &box.vm;
    var d: Dump = .{ .gpa = gpa, .globals = &vm.globals.header };
    defer d.deinit();
    var blobs: std.ArrayList(Blob) = .empty;
    errdefer {
        for (blobs.items) |b| gpa.free(b.bytes);
        blobs.deinit(gpa);
    }

    try d.p("status={s} nres={x}\nresults: ", .{ @tagName(status), nres });
    for (results[0..@min(nres, results.len)]) |*r| try d.val(asValue(r));
    try d.p("\nlast_error={s}\nfatal={}\n", .{ lastError(box), box.fatal });
    try d.p("depth={d} stack_top={d} reentry={d} reg_top_pending={}\nregs: ", .{ vm.depth, vm.stack_top, vm.native_reentry_depth, vm.reg_top_pending });
    for (0..vm.stack_top) |i| try d.val(vm.regGet(i));
    try d.p("\ncall_seq={d} safepoint_seq={d} committed_effects={d} effect_cursor={d}\n", .{ vm.next_call_seq, vm.safepoint_seq, vm.committed_effect_seq, vm.effect_cursor });
    // The replay driver's line index (filled only while it is switched on).
    try d.p("safepoint_lines: {any}\n", .{vm.safepoint_lines.items});
    try d.blob(&blobs, "effect_log", try mahina.effectser.encodeFile(gpa, vm.effect_log.items));
    const pol = &vm.trace.region_policy;
    try d.p("region: valid={} depth={d} seq={d}\nregion activations:", .{ pol.region_context_valid, pol.region_context.depth, pol.region_context.call_seq });
    {
        // Every live activation, key and accumulator, in a canonical order.
        var rows: std.ArrayList([]u8) = .empty;
        defer {
            for (rows.items) |r| gpa.free(r);
            rows.deinit(gpa);
        }
        var it = pol.region_profit.iterator();
        while (it.next()) |e| {
            const row = try std.fmt.allocPrint(gpa, " {any}={any}", .{ e.key_ptr.*, e.value_ptr.* });
            rows.append(gpa, row) catch |err| {
                gpa.free(row);
                return err;
            };
        }
        std.mem.sort([]u8, rows.items, {}, lessThanStr);
        for (rows.items) |r| try d.p("{s}", .{r});
    }
    // Open upvalue cells: identity (shared ordinals with the closures that
    // hold them), the slot they cover, and that slot's current value.
    try d.p("\nopen_upvalues: ", .{});
    for (vm.open_upvalues.items) |u| {
        const o = try d.ordinal(@intFromPtr(u.cell));
        try d.p("u{d}@{d}=", .{ o.id, u.index });
        try d.val(vm.regGet(u.index));
    }
    if (vm.final_cut) |fc| {
        try d.p("\nfinal_cut: base={d} count={d} top={d}\n", .{ fc.result_base, fc.result_count, fc.stack_top });
    } else try d.p("\nfinal_cut: -\n", .{});

    const ts = &vm.trace;
    try d.p("fast_block={x} recording={} ", .{ ts.fast_block, ts.isRecording() });
    if (ts.isRecording()) {
        // An in-flight recording, as far as it has got: its kind, anchor,
        // every IR instruction, and every constant by value (IR operands
        // name constants by pool index, so the pool itself must match).
        const rec = &ts.rec;
        try d.anchor(rec.anchor);
        try d.p("kind={s} abort={any}\nconsts: ", .{ @tagName(rec.kind), rec.abort_reason });
        for (rec.consts.items) |cv| try d.val(cv);
        try d.p("\nir:", .{});
        for (rec.instrs.items) |ins| try d.p(" {any}", .{ins});
    }
    try d.p("\nlink arms: ret_cont={d} call_head={d}", .{ ts.ret_cont_link_arms, ts.call_head_link_arms });
    try d.p("\npending: exit=", .{});
    try d.anchor(ts.pending_exit_anchor);
    try d.p("replay=", .{});
    try d.anchor(ts.pending_replay_anchor);
    if (ts.pending_call_anchor) |c| {
        try d.p("call=", .{});
        try d.proto(c.proto);
        try d.p("/{d}/{d} ", .{ c.base, c.call_seq });
    } else try d.p("call=- ", .{});
    if (ts.pending_ret_anchor) |r| {
        try d.p("ret=", .{});
        try d.proto(r.proto);
        try d.p("@{d}/{d}/{d} ", .{ r.resume_pc, r.base, r.call_seq });
    } else try d.p("ret=- ", .{});
    try d.p("ret_cont={any} call_head={any}\n", .{ ts.pending_ret_cont_arm, ts.pending_call_head_arm });
    {
        const recs = ts.registry.cache.items;
        const codes = try gpa.alloc(*const mahina.trace.TraceCode, recs.len);
        defer gpa.free(codes);
        for (recs, codes) |r, *c| c.* = &r.code;
        try d.p("traces={d} ", .{recs.len});
        try d.blob(&blobs, "committed", try mahina.traceser.encodeFile(gpa, codes));
    }
    try d.p("heap: objects={d} next_id={d}\n", .{ vm.heap.object_count, vm.heap.next_obj_id });
    if (vm.next_call_seq > 0) {
        // The host-call frame slot (every top-level call reuses frames[0]).
        const f = &vm.frames[0];
        try d.p("frame0: ", .{});
        try d.proto(f.closure.proto);
        try d.p(" seq={d} base={d} pc={d} ret={d}/{d} va={d}/{d} cache_gen={d}\n", .{ f.call_seq, f.base, f.pc, f.ret_dest, f.ret_count, f.varargs_base, f.varargs_count, f.code_cache_gen });
    }
    try d.p("park: ", .{});
    for (vm.parked_inline[0..vm.parked_inline_len]) |v| try d.val(v);
    try d.p("| ", .{});
    for (vm.parked_results.items) |v| try d.val(v);
    try d.p("\n", .{});
    if (keyframe and vm.depth == 0)
        try d.blob(&blobs, "keyframe", try mahina.keyframeser.encodeSnapshot(gpa, vm));
    const text = try d.buf.toOwnedSlice(gpa);
    errdefer gpa.free(text);
    return .{ .text = text, .blobs = try blobs.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// the two-VM pair
// ---------------------------------------------------------------------------

const Arg = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    nil,
    /// A string created through the API and rooted by a host ref.
    str: []const u8,
    /// A string created through the API and rooted ONLY by the park (the
    /// header's "arguments remain valid" contract). Created last, so at most
    /// one per call: a second API call would clear the park first.
    fresh: []const u8,
    /// A global's value (rooted by the globals table).
    global: []const u8,
    /// Raw C bits, for invalid-value tests.
    raw: mh_value,
};

const Callee = union(enum) {
    global: []const u8,
    raw: mh_value,
    /// The first result of evaluating `return <expr>`: rooted only by the
    /// park until the call re-parks it.
    eval: []const u8,
};

const CallSpec = struct {
    callee: Callee,
    args: []const Arg = &.{},
    /// This many extra `int 0` arguments after `args` (register-capacity
    /// tests: a host call can pass more arguments than the register file).
    fill_args: usize = 0,
    max_results: usize = 4,
    null_results: bool = false,
    null_args: bool = false,
    null_vm: bool = false,
    null_nresults: bool = false,
    /// `mh_collect` after the call, before the snapshot (results and
    /// parked arguments must have survived it).
    collect_after: bool = false,
};

const Pair = struct {
    fa: [2]std.testing.FailingAllocator,
    box: [2]*capi.VmBox,
    keyframes: bool,
    tier: Tier,
    /// Leg 0's status from the last `call` (the legs are equal by then).
    last_status: Status,

    /// In place: the failing allocators must have stable addresses.
    fn init(self: *Pair, tier: Tier) !void {
        self.keyframes = true;
        self.tier = tier;
        self.last_status = .ok;
        for (0..2) |leg| {
            self.fa[leg] = .init(testing.allocator, .{});
            const box = try capi.createVm(self.fa[leg].allocator(), .{ .jit = if (tier == .off) 2 else 0 });
            self.box[leg] = box;
            const vm = &box.vm;
            vm.clock_source = .{ .ctx = &det_ctx, .nowNs = &detClock };
            vm.random_seed_source = .{ .ctx = &det_ctx, .seed = &detSeed };
            if (tier == .tier1) vm.trace.config.native_codegen = false;
            if (tier != .off) {
                vm.trace.config.hotloop = 4;
                vm.trace.config.hotcall = 4;
            }
            vm.reference_dispatch = leg == 1;
        }
    }

    fn deinit(self: *Pair) void {
        for (self.box) |b| capi.destroyVm(b);
    }

    fn setGcStress(self: *Pair, on: bool) void {
        for (self.box) |b| b.vm.heap.gc_stress = on;
    }

    /// Fail the next allocation (and resize) on both legs, or with `null`
    /// stop failing.
    fn failNextAlloc(self: *Pair, on: bool) void {
        for (&self.fa) |*fa| {
            fa.fail_index = if (on) fa.alloc_index else std.math.maxInt(usize);
            fa.resize_fail_index = if (on) fa.resize_index else std.math.maxInt(usize);
        }
    }

    fn expectSame(self: *Pair, snaps: *const [2]Snap) !void {
        _ = self;
        testing.expectEqualStrings(snaps[1].text, snaps[0].text) catch |e| {
            std.debug.print("\n--- H1 (leg 0) ---\n{s}\n--- reference (leg 1) ---\n{s}\n", .{ snaps[0].text, snaps[1].text });
            return e;
        };
        // Equal text ⇒ the same blob labels in the same order.
        for (snaps[0].blobs, snaps[1].blobs) |a, b| {
            testing.expectEqualSlices(u8, b.bytes, a.bytes) catch |e| {
                std.debug.print("\n(serialized {s} differs)\n", .{a.label});
                return e;
            };
        }
    }

    fn eval(self: *Pair, src: []const u8) !void {
        var snaps: [2]Snap = undefined;
        var done: usize = 0;
        defer for (snaps[0..done]) |sn| sn.deinit(testing.allocator);
        for (0..2) |leg| {
            const box = self.box[leg];
            var results: [4]mh_value = @splat(.{});
            var n: usize = 0;
            const st = capi.mh_eval(box, s(src), s("diff"), &results, results.len, &n);
            snaps[leg] = try snap(testing.allocator, box, st, &results, n, self.keyframes);
            done += 1;
        }
        try self.expectSame(&snaps);
    }

    fn makeCallee(box: *capi.VmBox, c: Callee) !mh_value {
        return switch (c) {
            .raw => |r| r,
            .global => |name| blk: {
                var v: mh_value = .{};
                try testing.expectEqual(Status.ok, capi.mh_global_get(box, s(name), &v));
                break :blk v;
            },
            .eval => |expr| blk: {
                var buf: [256]u8 = undefined;
                const src = try std.fmt.bufPrint(&buf, "return {s}", .{expr});
                var r: [1]mh_value = .{.{}};
                var n: usize = 0;
                try testing.expectEqual(Status.ok, capi.mh_eval(box, s(src), s("callee"), &r, 1, &n));
                break :blk r[0];
            },
        };
    }

    fn makeArg(box: *capi.VmBox, a: Arg, refs: *std.ArrayList(u64)) !mh_value {
        return switch (a) {
            .int => |i| capi.mh_int(i),
            .float => |f| capi.mh_float(f),
            .boolean => |b| capi.mh_bool(@intFromBool(b)),
            .nil => capi.mh_nil(),
            .raw => |r| r,
            .global => |name| blk: {
                var v: mh_value = .{};
                try testing.expectEqual(Status.ok, capi.mh_global_get(box, s(name), &v));
                break :blk v;
            },
            .str, .fresh => |bytes| blk: {
                var v: mh_value = .{};
                try testing.expectEqual(Status.ok, capi.mh_string_new(box, s(bytes), &v));
                if (a == .str) {
                    var r: u64 = 0;
                    try testing.expectEqual(Status.ok, capi.mh_ref_create(box, v, &r));
                    try refs.append(testing.allocator, r);
                }
                break :blk v;
            },
        };
    }

    fn call(self: *Pair, spec: CallSpec) !void {
        var snaps: [2]Snap = undefined;
        var done: usize = 0;
        defer for (snaps[0..done]) |sn| sn.deinit(testing.allocator);
        for (0..2) |leg| {
            const box = self.box[leg];
            var refs: std.ArrayList(u64) = .empty;
            defer refs.deinit(testing.allocator);
            const callee = try makeCallee(box, spec.callee);
            const argv = try testing.allocator.alloc(mh_value, @max(16, spec.args.len + spec.fill_args));
            defer testing.allocator.free(argv);
            @memset(argv, .{});
            for (argv[spec.args.len..][0..spec.fill_args]) |*v| v.* = capi.mh_int(0);
            // Rooted and scalar arguments first, the park-only one last.
            for (spec.args, 0..) |a, i| if (a != .fresh) {
                argv[i] = try makeArg(box, a, &refs);
            };
            for (spec.args, 0..) |a, i| if (a == .fresh) {
                argv[i] = try makeArg(box, a, &refs);
            };
            var results: [16]mh_value = @splat(.{});
            var nres: usize = 0xdead;
            const st = entry(
                leg,
                if (spec.null_vm) null else box,
                callee,
                if (spec.null_args) null else argv.ptr,
                spec.args.len + spec.fill_args,
                if (spec.null_results) null else &results,
                spec.max_results,
                if (spec.null_nresults) null else &nres,
            );
            if (leg == 0) self.last_status = st;
            if (spec.collect_after) try testing.expectEqual(Status.ok, capi.mh_collect(box));
            snaps[leg] = try snap(testing.allocator, box, st, &results, nres, self.keyframes);
            done += 1;
            for (refs.items) |r| try testing.expectEqual(Status.ok, capi.mh_ref_free(box, r));
        }
        try self.expectSame(&snaps);
    }

    fn callGlobal(self: *Pair, name: []const u8, args: []const Arg) !void {
        try self.call(.{ .callee = .{ .global = name }, .args = args });
    }
};

/// Run `body` once per tier on a fresh pair.
fn eachTier(comptime body: fn (*Pair) anyerror!void) !void {
    for (tiers) |t| {
        var pair: Pair = undefined;
        try pair.init(t);
        defer pair.deinit();
        body(&pair) catch |e| {
            std.debug.print("\n(tier {s})\n", .{@tagName(t)});
            return e;
        };
    }
}

// ---------------------------------------------------------------------------
// scenarios
// ---------------------------------------------------------------------------

const shapes_src =
    \\function p0() return 7 end
    \\function p3(a, b, c) return a, b, c end
    \\function cat(a, b) return a .. b end
    \\function va(a, ...) local t = {...} return #t, a, ... end
    \\function vonly(...) return ... end
    \\function r4() return 1, 2, 3, 4 end
    \\function many() return "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8" end
    \\function wide(a, b, c, d, e, f, g, h, i)
    \\  local x1, x2, x3, x4, x5, x6, x7, x8 = 1, 2, 3, 4, 5, 6, 7, 8
    \\  return a, i, x8
    \\end
    \\function hot(n) local acc = 0 for i = 1, n do acc = acc + i end return acc end
    \\gs = "rooted-global-string"
    \\gt = {1, 2, 3}
;

test "hostcall diff: argument counts 0..9, fewer and more than the parameters" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            const ints = [_]Arg{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 }, .{ .int = 5 }, .{ .int = 6 }, .{ .int = 7 }, .{ .int = 8 }, .{ .int = 9 } };
            for (0..ints.len + 1) |n| {
                try pr.callGlobal("p0", ints[0..n]);
                try pr.callGlobal("p3", ints[0..n]);
                try pr.callGlobal("wide", ints[0..n]);
            }
            // Mixed scalar kinds and heap-valued arguments.
            try pr.callGlobal("p3", &.{ .{ .float = 2.5 }, .{ .boolean = true }, .nil });
            try pr.callGlobal("p3", &.{ .{ .global = "gs" }, .{ .global = "gt" }, .{ .str = "api-made" } });
            try pr.callGlobal("cat", &.{ .{ .str = "left-" }, .{ .fresh = "fresh-right" } });
        }
    }.run);
}

test "hostcall diff: vararg callees with and without surplus arguments" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            try pr.callGlobal("va", &.{});
            try pr.callGlobal("va", &.{.{ .int = 1 }});
            try pr.callGlobal("va", &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .global = "gt" }, .{ .str = "v4" }, .{ .int = 5 } });
            try pr.callGlobal("vonly", &.{});
            try pr.callGlobal("vonly", &.{ .{ .global = "gs" }, .{ .int = 2 }, .{ .fresh = "surplus-fresh" } });
        }
    }.run);
}

test "hostcall diff: result counts, truncation and null buffers" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            for ([_]usize{ 0, 1, 2, 4, 6 }) |m| {
                try pr.call(.{ .callee = .{ .global = "r4" }, .max_results = m });
            }
            // `results == NULL` is an empty buffer whatever `max_results` says.
            try pr.call(.{ .callee = .{ .global = "r4" }, .null_results = true, .max_results = 0 });
            try pr.call(.{ .callee = .{ .global = "r4" }, .null_results = true, .max_results = 3 });
            // `args == NULL` is valid with zero arguments, an API error otherwise.
            try pr.call(.{ .callee = .{ .global = "p0" }, .null_args = true });
            try pr.call(.{ .callee = .{ .global = "p3" }, .args = &.{ .{ .int = 1 }, .{ .int = 2 } }, .null_args = true });
            try pr.call(.{ .callee = .{ .global = "p0" }, .null_vm = true });
            try pr.call(.{ .callee = .{ .global = "p0" }, .null_nresults = true });
        }
    }.run);
}

test "hostcall diff: fallback callees (natives, __call) and non-callables" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src ++
                \\callable = setmetatable({}, {__call = function(self, x) return x, "via __call" end})
                \\plain = {}
            );
            try pr.callGlobal("type", &.{.{ .global = "gt" }});
            try pr.callGlobal("tostring", &.{.{ .int = 42 }});
            try pr.callGlobal("callable", &.{.{ .int = 5 }});
            try pr.callGlobal("plain", &.{.{ .int = 5 }});
            try pr.call(.{ .callee = .{ .raw = capi.mh_int(3) } });
            // Then a closure call right after each fallback.
            try pr.callGlobal("p3", &.{.{ .int = 1 }});
        }
    }.run);
}

test "hostcall diff: invalid values are rejected identically" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            try pr.call(.{ .callee = .{ .raw = .{ .tag = 0xFF } } });
            try pr.call(.{ .callee = .{ .raw = .{ .tag = 5 } } }); // row_view
            try pr.call(.{ .callee = .{ .raw = .{ .tag = 4, .payload = 0 } } }); // null heap pointer
            try pr.call(.{ .callee = .{ .global = "p3" }, .args = &.{ .{ .int = 1 }, .{ .raw = .{ .tag = 0xFF } } } });
            try pr.call(.{ .callee = .{ .global = "p3" }, .args = &.{.{ .raw = .{ .tag = 4, .payload = 0 } }} });
            try pr.callGlobal("p3", &.{.{ .int = 1 }});
        }
    }.run);
}

test "hostcall diff: guest errors, depth limit, fatal refusal" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src ++
                \\function boom(x) error("boom " .. x) end
                \\function deep(n) if n == 0 then return 0 end return deep(n - 1) + 1 end
                \\function alloc() return {} end
            );
            try pr.callGlobal("boom", &.{.{ .int = 1 }});
            try pr.callGlobal("p3", &.{.{ .int = 2 }});
            try pr.callGlobal("deep", &.{.{ .int = 50 }});
            try pr.callGlobal("deep", &.{.{ .int = 500 }}); // StackOverflow, catchable
            try pr.callGlobal("deep", &.{.{ .int = 10 }});
            // A non-catchable fault (OOM inside the guest) poisons the VM;
            // the next call is refused.
            pr.failNextAlloc(true);
            try pr.callGlobal("alloc", &.{});
            pr.failNextAlloc(false);
            pr.keyframes = false; // a fatal VM is not a capture point
            // Every API entry is refused now (`mh_global_get` too), and the
            // refusal precedes callee validation: any callee will do.
            try pr.call(.{ .callee = .{ .raw = capi.mh_nil() }, .args = &.{.{ .int = 3 }} });
        }
    }.run);
}

test "hostcall diff: final_cut from a top-level eval is cleared by the next call" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            try pr.eval("return 1, 2, 3");
            try pr.callGlobal("p3", &.{.{ .int = 1 }});
            try pr.eval("return gs");
            try pr.callGlobal("r4", &.{});
        }
    }.run);
}

test "hostcall diff: hot callees tier up across repeated calls" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            for (0..40) |i| {
                try pr.callGlobal("hot", &.{.{ .int = @intCast(10 + i % 7) }});
                try pr.callGlobal("p3", &.{ .{ .int = @intCast(i) }, .{ .global = "gs" } });
            }
        }
    }.run);
}

test "hostcall diff: a recording that raises mid-loop is aborted identically" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src ++
                \\function loopraise(n)
                \\  local s = 0
                \\  for i = 1, 100 do s = s + i if i == n then error("at " .. i) end end
                \\  return s
                \\end
            );
            for (0..6) |_| try pr.callGlobal("loopraise", &.{.{ .int = 30 }});
            try pr.callGlobal("loopraise", &.{.{ .int = 1000 }});
        }
    }.run);
}

// Put the same non-zero fast word on both VMs before a call: the H1 leg's
// `runPushedFrame` must take the `.full` branch, firing the hooks exactly
// as the reference does.
test "hostcall diff: fast word nonzero at entry (each anchor kind, arm requests, recording, line index)" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            // Eight of the nine conditions. The ninth, an armed suspend
            // trigger, is a precondition violation for any host call (both
            // `callValue` and `pushHostCall` assert `suspend_ctl == null`
            // before mutating anything); its bit is covered by
            // `interp_fastblock_test.zig`.
            const Setup = enum { exit_anchor, replay_anchor, call_anchor, ret_anchor, ret_cont_arm, call_head_arm, recording, safepoint_lines };
            for (std.enums.values(Setup)) |what| {
                for (pr.box) |b| {
                    const vm = &b.vm;
                    const ts = &vm.trace;
                    // An anchor at a pc the callee never reaches, so it waits.
                    const proto = vm.frames[0].closure.proto;
                    const key: mahina.trace.AnchorKey = .{ .proto = proto, .pc = 9999 };
                    switch (what) {
                        .exit_anchor => ts.setPendingExitAnchor(key),
                        .replay_anchor => ts.setPendingReplayAnchor(key),
                        .call_anchor => ts.setPendingCallAnchor(.{ .proto = proto, .base = 0, .call_seq = 1 << 40 }),
                        .ret_anchor => ts.setPendingRetAnchor(.{ .proto = proto, .resume_pc = 9999, .base = 0, .call_seq = 1 << 40 }),
                        .ret_cont_arm => ts.setPendingRetContArm(.{ .trace_id = 1 << 30, .exit_instr = 1 }),
                        .call_head_arm => ts.setPendingCallHeadArm(.{ .trace_id = 1 << 30, .exit_instr = 1 }),
                        .recording => try testing.expect(ts.startRecording(key, proto.num_registers)),
                        .safepoint_lines => vm.setRecordSafepointLines(true),
                    }
                }
                try pr.callGlobal("hot", &.{.{ .int = 5 }});
                try pr.callGlobal("p3", &.{ .{ .int = 1 }, .{ .global = "gs" } });
                for (pr.box) |b| {
                    b.vm.setRecordSafepointLines(false);
                    b.vm.trace.setPendingRetContArm(null);
                    b.vm.trace.setPendingCallHeadArm(null);
                    b.vm.trace.abortRaised();
                }
                try pr.callGlobal("p0", &.{});
            }
        }
    }.run);
}

/// Render `vals` (as a call's results) and return the snapshot text.
fn renderResults(box: *capi.VmBox, vals: []const mh_value) ![]u8 {
    const sn = try snap(testing.allocator, box, .ok, vals, vals.len, false);
    for (sn.blobs) |b| testing.allocator.free(b.bytes);
    testing.allocator.free(sn.blobs);
    return sn.text;
}

/// Two renders must differ (the snapshot sees the one thing that changed).
fn expectRenderDiffers(a: []const u8, b: []const u8) !void {
    try testing.expect(!std.mem.eql(u8, a, b));
}

// The differential tests are only as strong as `snap`: each case changes
// exactly one thing the snapshot claims to compare, and requires the
// rendered text to change with it.
test "snapshot self-test: closures by proto identity, recording constants by value, grid cells and row views" {
    const box = try capi.createVm(testing.allocator, .{ .jit = 2 });
    defer capi.destroyVm(box);
    const vm = &box.vm;
    var out: [3]mh_value = @splat(.{});
    var n: usize = 0;
    try testing.expectEqual(Status.ok, capi.mh_eval(box, s(shapes_src ++
        \\function pair(x) local y = {x} return function() return y end, function(v) y = v end, y end
        \\m = {{1, 2, 3}, {4, 5, 6}}
        \\return pair(1)
    ), s("self"), &out, out.len, &n));
    try testing.expectEqual(@as(usize, 3), n);

    // Two `anonymous` closures sharing one cell: swapped, they must render
    // differently (their protos differ, their names do not).
    {
        const fwd = try renderResults(box, &.{ out[0], out[1] });
        defer testing.allocator.free(fwd);
        const rev = try renderResults(box, &.{ out[1], out[0] });
        defer testing.allocator.free(rev);
        try expectRenderDiffers(fwd, rev);
    }

    // An in-flight recording's constant pool, by value.
    {
        const ts = &vm.trace;
        // The VM's own (tracking) allocator: the recorder frees with it.
        try ts.startRecordingForTest(ts.gpa, .{ .proto = vm.frames[0].closure.proto, .pc = 1 }, 4);
        defer ts.stopRecordingForTest();
        try ts.rec.consts.append(ts.gpa, Value.int(5));
        const before = try renderResults(box, &.{});
        defer testing.allocator.free(before);
        try testing.expect(std.mem.indexOf(u8, before, "consts: int:5") != null);
        ts.rec.consts.items[0] = Value.int(6);
        const after = try renderResults(box, &.{});
        defer testing.allocator.free(after);
        try expectRenderDiffers(before, after);
    }

    // A grid (inflated by the fused store path, doc 14): every cell is
    // rendered, so changing one changes the text; a row view renders its
    // parent grid by identity.
    {
        var mv: mh_value = .{};
        try testing.expectEqual(Status.ok, capi.mh_global_get(box, s("m"), &mv));
        const m = asValue(&mv);
        try vm.fusedStore(m, Value.int(1), Value.int(1), Value.int(9));
        try testing.expect(mahina.table.Table.fromHeader(m.asHeap()).array.isGrid());
        const before = try renderResults(box, &.{mv});
        defer testing.allocator.free(before);
        try testing.expect(std.mem.indexOf(u8, before, "grid rows=2") != null);
        try vm.fusedStore(m, Value.int(2), Value.int(3), Value.int(60));
        const after = try renderResults(box, &.{mv});
        defer testing.allocator.free(after);
        try expectRenderDiffers(before, after);

        const row = Value.rowView(m.asHeap(), 1);
        const rv = try renderResults(box, &.{@as(*const mh_value, @ptrCast(&row)).*});
        defer testing.allocator.free(rv);
        try testing.expect(std.mem.indexOf(u8, rv, "row[h") != null);
        try testing.expect(std.mem.indexOf(u8, rv, "grid rows=2") != null);
    }
}

/// A recording at `key` happened: still in flight, committed, or aborted
/// (the last needs `config.record_aborts`).
fn recordedAt(ts: *const mahina.trace.TraceState, key: mahina.trace.AnchorKey) bool {
    if (ts.rec.active and ts.rec.anchor.proto == key.proto and ts.rec.anchor.pc == key.pc) return true;
    for (ts.registry.cache.items) |r| {
        if (r.code.anchor.proto == key.proto and r.code.anchor.pc == key.pc) return true;
    }
    for (ts.abort_log.items) |a| {
        if (a.proto == key.proto and a.anchor_pc == key.pc) return true;
    }
    return false;
}

// The previous test's anchors never match, so they only wait or get
// discarded. Here each one matches the callee H1 is about to enter, so the
// host call itself must start the recording — through H1's `.full` branch,
// exactly as through the reference. (A ret anchor cannot match at a host
// entry: the callee's first prologue step consumes or discards it, which
// the previous test covers.)
test "hostcall diff: anchors that match the entered callee start their recording identically" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src ++
                \\function hx(n) local acc = 0 for i = 1, n do acc = acc + i end return acc end
                \\function hr(n) local acc = 0 for i = 1, n do acc = acc + i end return acc end
                \\function hc(n) local acc = 0 for i = 1, n do acc = acc + i end return acc end
            );
            const Kind = enum { exit_anchor, replay_anchor, call_anchor };
            for (std.enums.values(Kind)) |kind| {
                const name = switch (kind) {
                    .exit_anchor => "hx",
                    .replay_anchor => "hr",
                    .call_anchor => "hc",
                };
                var keys: [2]mahina.trace.AnchorKey = undefined;
                for (pr.box, &keys) |b, *key| {
                    const vm = &b.vm;
                    const ts = &vm.trace;
                    ts.config.record_aborts = true;
                    var cv: mh_value = .{};
                    try testing.expectEqual(Status.ok, capi.mh_global_get(b, s(name), &cv));
                    const callee_proto = mahina.function.Closure.fromHeader(asValue(&cv).asHeap()).proto;
                    switch (kind) {
                        // At the callee's first instruction.
                        .exit_anchor, .replay_anchor => {
                            key.* = .{ .proto = callee_proto, .pc = 0 };
                            if (kind == .exit_anchor) ts.setPendingExitAnchor(key.*) else ts.setPendingReplayAnchor(key.*);
                        },
                        // The very activation H1 pushes: base and call_seq.
                        .call_anchor => {
                            key.* = .{ .proto = callee_proto, .pc = mahina.trace.FUNC_HEAD_PC };
                            ts.setPendingCallAnchor(.{ .proto = callee_proto, .base = vm.stack_top, .call_seq = vm.next_call_seq });
                        },
                    }
                }
                try pr.callGlobal(name, &.{.{ .int = 6 }});
                if (pr.tier != .off) {
                    for (pr.box, keys) |b, key| try testing.expect(recordedAt(&b.vm.trace, key));
                }
                // Leave nothing pending for the next kind.
                for (pr.box) |b| {
                    b.vm.trace.abortRaised();
                    b.vm.trace.clearPendingExitAnchor();
                }
                try pr.callGlobal("p0", &.{});
            }
        }
    }.run);
}

// Arm requests with a VALID parent: a host-entered recursion forms its head,
// base and continuation traces, files ret-cont and call-head requests, and
// the dispatcher consumes them by arming real native links — all inside
// calls that came in through H1 (the snapshot compares the arm counters and
// the pending requests after every call). The earlier fixtures' requests name
// parents that never exist, so they only exercise the stale-parent drop.
test "hostcall diff: frame-link arm requests with live parents arm identically" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src ++
                \\function fib(n) if n < 2 then return 1 end return fib(n - 2) + fib(n - 1) end
            );
            for (0..4) |_| try pr.callGlobal("fib", &.{.{ .int = 16 }});
            if (pr.tier == .native and @import("builtin").cpu.arch == .x86_64) {
                for (pr.box) |b| {
                    try testing.expect(b.vm.trace.ret_cont_link_arms >= 1);
                    try testing.expect(b.vm.trace.call_head_link_arms >= 1);
                }
            }
        }
    }.run);
}

test "hostcall diff: the parking contract under GC stress" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src ++
                \\function clobber(a, b)
                \\  a = nil b = nil
                \\  local junk = {}
                \\  for i = 1, 30 do junk[i] = {i} end
                \\  return #junk
                \\end
                \\function one(a) local junk = {} for i = 1, 20 do junk[i] = {} end return 1 end
            );
            pr.setGcStress(true);
            // An overwritten heap parameter whose only root is the park.
            try pr.call(.{ .callee = .{ .global = "clobber" }, .args = &.{ .{ .str = "kept" }, .{ .fresh = "park-only-param" } }, .collect_after = true });
            // A surplus heap argument to a non-vararg callee, discarded by
            // the bind: still parked.
            try pr.call(.{ .callee = .{ .global = "one" }, .args = &.{ .{ .int = 1 }, .{ .fresh = "park-only-surplus" } }, .collect_after = true });
            // An otherwise unrooted callee (only the park holds it).
            try pr.call(.{ .callee = .{ .eval = "function(x) local t = {} for i = 1, 10 do t[i] = {} end return x .. '!' end" }, .args = &.{.{ .str = "unrooted-callee" }}, .collect_after = true });
            // Heap results survive a collection after return.
            try pr.call(.{ .callee = .{ .global = "many" }, .max_results = 8, .collect_after = true });
            pr.setGcStress(false);
        }
    }.run);
}

fn spendFn(vm: ?*capi.VmBox, _: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, _: ?[*]mh_value, _: usize, nresults: *usize) callconv(.c) Status {
    // Mint and park `args[0]` fresh strings from inside the guest run (the
    // VM is not idle, so nothing clears the park): uses up inline slots.
    var n: i64 = 0;
    if (nargs > 0) _ = capi.mh_value_int(args.?[0], &n);
    var buf: [32]u8 = undefined;
    for (0..@intCast(n)) |i| {
        const bytes = std.fmt.bufPrint(&buf, "spent-{d}", .{i}) catch unreachable;
        var v: mh_value = .{};
        const st = capi.mh_string_new(vm, s(bytes), &v);
        if (st != .ok) return st;
    }
    nresults.* = 0;
    return .ok;
}

test "hostcall diff: park overflow on input and on results, and the idle clear of the overflow" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            pr.keyframes = false; // host functions registered (doc 59 E6/E8)
            for (pr.box) |b| try testing.expectEqual(Status.ok, capi.mh_register_fn(b, s("spend"), &spendFn, null, null));
            try pr.eval(shapes_src ++
                \\function spendthenmany(n) spend(n) return many() end
            );
            // Input: callee + 7 heap arguments overflow the 6 inline slots.
            try pr.callGlobal("vonly", &.{ .{ .str = "i1" }, .{ .str = "i2" }, .{ .str = "i3" }, .{ .str = "i4" }, .{ .str = "i5" }, .{ .str = "i6" }, .{ .str = "i7" } });
            // Results: 8 heap results overflow.
            try pr.call(.{ .callee = .{ .global = "many" }, .max_results = 8 });
            // An idle call empties the overflow list first.
            try pr.callGlobal("p0", &.{});
            // A callback uses up the inline park before the outer call
            // parks its heap results.
            try pr.call(.{ .callee = .{ .global = "spendthenmany" }, .args = &.{.{ .int = 5 }}, .max_results = 8 });
            try pr.callGlobal("p0", &.{});
        }
    }.run);
}

test "hostcall diff: park OOM on input and in the result-park overflow" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            try pr.eval(shapes_src);
            // Result overflow OOM: execution completed, `*nresults` stays 0,
            // the VM is not fatal, and the next call works.
            pr.failNextAlloc(true);
            try pr.call(.{ .callee = .{ .global = "many" }, .max_results = 8 });
            pr.failNextAlloc(false);
            try pr.callGlobal("p3", &.{.{ .int = 1 }});
            // Input overflow OOM (fresh pair state: the overflow list was
            // cleared, but its capacity retained — so drop it first).
            for (pr.box) |b| {
                b.vm.parked_results.clearAndFree(b.vm.gpa);
            }
            try pr.callGlobal("vonly", &.{ .{ .str = "j1" }, .{ .str = "j2" }, .{ .str = "j3" }, .{ .str = "j4" }, .{ .str = "j5" }, .{ .str = "j6" } });
            for (pr.box) |b| b.vm.parked_results.clearAndFree(b.vm.gpa);
            pr.failNextAlloc(true);
            try pr.call(.{ .callee = .{ .global = "vonly" }, .args = &.{ .{ .global = "gs" }, .{ .global = "gt" }, .{ .global = "gs" }, .{ .global = "gt" }, .{ .global = "gs" }, .{ .global = "gt" } } });
            pr.failNextAlloc(false);
            try pr.callGlobal("p0", &.{});
        }
    }.run);
}

fn errText(box: *capi.VmBox) []const u8 {
    const e = capi.mh_last_error(box);
    return if (e.ptr) |p| p[0..e.len] else "";
}

const ReenterCtx = struct { leg: usize };

fn reenterFn(vm: ?*capi.VmBox, ud: ?*anyopaque, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: *usize) callconv(.c) Status {
    // reenter(f, n): call f(n - 1) back through the leg's own entry and
    // return its result + 1. A failing nested call fails the callback.
    const ctx: *ReenterCtx = @ptrCast(@alignCast(ud.?));
    std.debug.assert(nargs == 2);
    const a = args.?;
    var n: i64 = 0;
    _ = capi.mh_value_int(a[1], &n);
    const arg = [_]mh_value{capi.mh_int(n - 1)};
    var out: [1]mh_value = .{.{}};
    var got: usize = 0;
    const st = entry(ctx.leg, vm, a[0], &arg, 1, &out, 1, &got);
    if (st != .ok) {
        capi.mh_error_set(vm, s("nested call failed"));
        return st;
    }
    var r: i64 = 0;
    if (got == 1) _ = capi.mh_value_int(out[0], &r);
    if (max_results > 0) results.?[0] = capi.mh_int(r + 1);
    nresults.* = @min(max_results, 1);
    return .ok;
}

const PeekCtx = struct {
    snaps: std.ArrayList(Snap) = .empty,

    fn deinit(self: *PeekCtx) void {
        for (self.snaps.items) |sn| sn.deinit(testing.allocator);
        self.snaps.deinit(testing.allocator);
    }
};

fn peekFn(vm: ?*capi.VmBox, ud: ?*anyopaque, _: ?[*]const mh_value, _: usize, _: ?[*]mh_value, _: usize, nresults: *usize) callconv(.c) Status {
    // peek(): snapshot the VM mid-call — guest frames, open upvalue cells
    // and region activations live — for comparison with the other leg's
    // peeks once the calls are done.
    const ctx: *PeekCtx = @ptrCast(@alignCast(ud.?));
    const sn = snap(testing.allocator, vm.?, .ok, &.{}, 0, false) catch return .err_oom;
    ctx.snaps.append(testing.allocator, sn) catch {
        sn.deinit(testing.allocator);
        return .err_oom;
    };
    nresults.* = 0;
    return .ok;
}

test "hostcall diff: fresh tables and capturing closures, and mid-call state under reentry" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            pr.keyframes = false; // host functions registered (doc 59 E6/E8)
            var reent = [2]ReenterCtx{ .{ .leg = 0 }, .{ .leg = 1 } };
            var peeks = [2]PeekCtx{ .{}, .{} };
            defer for (&peeks) |*pk| pk.deinit();
            for (pr.box, &reent, &peeks) |b, *rc, *pk| {
                try testing.expectEqual(Status.ok, capi.mh_register_fn(b, s("reenter"), &reenterFn, rc, null));
                try testing.expectEqual(Status.ok, capi.mh_register_fn(b, s("peek"), &peekFn, pk, null));
            }
            try pr.eval(shapes_src ++
                \\function mk(n)
                \\  local t = {n, "x", k = {n}}
                \\  t.self = t
                \\  setmetatable(t, {__index = gt})
                \\  return t, t.k
                \\end
                \\function counter(start) local c = start return function() c = c + 1 return c end end
                \\function pair(x) local y = {x} return function() return y end, function(v) y = v end, y end
                \\function live(n)
                \\  local x = {n, "live"}
                \\  local f = function() x[1] = x[1] + 1 return x end
                \\  peek() f() peek()
                \\  return f, x
                \\end
                \\function outer(n)
                \\  local z = {n}
                \\  local h = function() return z end
                \\  peek()
                \\  local r = reenter(live, n)
                \\  peek()
                \\  return r, h, z
                \\end
                \\gm = {{1, 2, 3}, {4, 5, 6}}
                \\function gridpeek(k)
                \\  local g = gm
                \\  peek()
                \\  g[2][3] = g[2][3] + k
                \\  return g[1][2], g[2][3]
                \\end
            );
            // The same grid on both legs (fused-store inflation, doc 14),
            // held in a register at a peek. The peek comes first: a plain
            // tier-0 `g[i]` read may deflate the grid back into row tables
            // (identically on both legs, and the later peeks compare that).
            for (pr.box) |b| {
                var gv: mh_value = .{};
                try testing.expectEqual(Status.ok, capi.mh_global_get(b, s("gm"), &gv));
                try b.vm.fusedStore(asValue(&gv), Value.int(1), Value.int(1), Value.int(9));
                try testing.expect(mahina.table.Table.fromHeader(asValue(&gv).asHeap()).array.isGrid());
            }
            for (0..6) |i| {
                const n: i64 = @intCast(i);
                try pr.callGlobal("mk", &.{.{ .int = n }});
                try pr.callGlobal("counter", &.{.{ .int = n }});
                try pr.callGlobal("pair", &.{.{ .str = "p" }});
                try pr.callGlobal("live", &.{.{ .int = n }});
                try pr.call(.{ .callee = .{ .global = "outer" }, .args = &.{.{ .int = n }}, .collect_after = true });
                try pr.callGlobal("gridpeek", &.{.{ .int = n }});
            }
            // 2 peeks per `live`, 4 per `outer` (its own 2 + the nested
            // `live`), 1 per `gridpeek`.
            try testing.expectEqual(@as(usize, 6 * 7), peeks[0].snaps.items.len);
            try testing.expectEqual(peeks[0].snaps.items.len, peeks[1].snaps.items.len);
            for (peeks[0].snaps.items, peeks[1].snaps.items) |a, b| try pr.expectSame(&[2]Snap{ a, b });
            // The peeks really saw the deep state: a closure over an open
            // cell, the cell in the open list, and a table's contents...
            const mid = peeks[0].snaps.items[1].text;
            for ([_][]const u8{ "=open@", "open_upvalues: u", ":table{" }) |needle|
                try testing.expect(std.mem.indexOf(u8, mid, needle) != null);
            // ...and, in the first `gridpeek`, a grid's cells (row views are
            // pinned by the snapshot self-test).
            try testing.expect(std.mem.indexOf(u8, peeks[0].snaps.items[6].text, "grid rows=2") != null);
        }
    }.run);
}

test "hostcall diff: re-entrant calls, up to and past the reentry and depth limits" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            pr.keyframes = false;
            var ctxs = [2]ReenterCtx{ .{ .leg = 0 }, .{ .leg = 1 } };
            for (pr.box, &ctxs) |b, *c| try testing.expectEqual(Status.ok, capi.mh_register_fn(b, s("reenter"), &reenterFn, c, null));
            try pr.eval(
                \\function chain(n) if n <= 0 then return 0 end return reenter(chain, n) end
                \\function chain2(n) if n <= 0 then return 0 end return (function() return reenter(chain2, n) end)() end
            );
            try pr.callGlobal("chain", &.{.{ .int = 3 }});
            try pr.callGlobal("chain", &.{.{ .int = 150 }});
            // One guest frame per level: the reentry limit trips first.
            try pr.callGlobal("chain", &.{.{ .int = 260 }});
            try pr.callGlobal("chain", &.{.{ .int = 2 }});
            // Two guest frames per level: the depth limit trips at a host entry.
            try pr.callGlobal("chain2", &.{.{ .int = 150 }});
            try pr.callGlobal("chain2", &.{.{ .int = 2 }});
        }
    }.run);
}

test "hostcall diff: register capacity, at the outer entry and at a nested host entry" {
    try eachTier(struct {
        fn run(pr: *Pair) !void {
            pr.keyframes = false;
            var ctxs = [2]ReenterCtx{ .{ .leg = 0 }, .{ .leg = 1 } };
            for (pr.box, &ctxs) |b, *c| try testing.expectEqual(Status.ok, capi.mh_register_fn(b, s("reenter"), &reenterFn, c, null));
            try pr.eval(shapes_src ++
                \\function w40(a)
                \\  local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
                \\  local c1, c2, c3, c4, c5, c6, c7, c8, c9, c10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
                \\  local d1, d2, d3, d4, d5, d6, d7, d8, d9, d10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
                \\  local e1, e2, e3, e4, e5, e6, e7, e8, e9 = 1, 2, 3, 4, 5, 6, 7, 8, 9
                \\  return a
                \\end
                \\function big(...) return reenter(w40, 2) end
            );
            // The register file is `stack_slots` (1 << 16) wide and the depth
            // limit caps frames at 200, so only a host call's argument count
            // reaches capacity. Sweeping it across the boundary hits both
            // checks in `bindAndPushClosure`: the vararg layout of the outer
            // call itself, and — once the outer window just fits — the
            // ordinary layout of `w40` entered from the `reenter` callback.
            const cap: usize = 1 << 16;
            var outer_overflow = false;
            var nested_overflow = false;
            var fill: usize = cap - 64;
            while (fill <= cap + 2) : (fill += 2) {
                try pr.call(.{ .callee = .{ .global = "vonly" }, .fill_args = fill, .max_results = 1 });
                if (pr.last_status != .ok) outer_overflow = true;
                try pr.call(.{ .callee = .{ .global = "big" }, .fill_args = fill });
                if (pr.last_status != .ok and
                    std.mem.indexOf(u8, errText(pr.box[0]), "nested call failed") != null)
                    nested_overflow = true;
            }
            // The sweep must have exercised both checks, not just one.
            try testing.expect(outer_overflow);
            try testing.expect(nested_overflow);
            // Both legs recover: the next calls run normally.
            try pr.callGlobal("big", &.{});
            try pr.callGlobal("p3", &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } });
        }
    }.run);
}
