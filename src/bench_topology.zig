//! Doc 58 §4.8 — `zig build bench-topology` (ReleaseFast).
//!
//! Measures the region-topology rebuild boundary (`rebuildEdgeCache` +
//! `rebuildRegions`) on a closed cycle with k qualifying loop roots, the
//! shape the multi-root owner election runs on, as proto size n and root
//! count k grow (codex review of §4.8, finding 1). Each program is k
//! sequential numeric loops in a `repeat` body, each followed by a
//! continuation that links into the next loop's root, the last back into
//! the first — so every root is link-fed and the fallback tier must break a
//! k-way tie by dominance. `pad` straight-line statements before the `repeat`
//! grow n without growing k. `dom` is `bc_dom.compute` alone — a one-time
//! compile-time cost per proto (`Proto.dom`), never paid by a rebuild.
//!
//! Informational, not a gate (global Rule #22): it prints best and mean
//! per rebuild and checks that the election picked the first loop.

const std = @import("std");
const mahina = @import("mahina");

const bytecode = mahina.bytecode;
const trace = mahina.trace;
const Trace = trace.Trace;
const IrInstr = trace.IrInstr;
const ExitProvEntry = trace.ExitProvEntry;
const Proto = bytecode.Proto;

const reps = 20;

const RootCont = struct {
    root_i: [2]IrInstr,
    root_p: [1]ExitProvEntry,
    root: Trace,
    cont_i: [1]IrInstr,
    cont_p: [1]ExitProvEntry,
    cont: Trace,

    fn init(self: *RootCont, proto: *const Proto, fl: u32, link_to: u32, first_id: u32) void {
        const header = bytecode.loopHeaderOf(proto.code[fl], fl).?;
        self.root_i = .{ .{ .op = .guard_true, .a = 0, .aux = @intCast(fl + 1) }, .{ .op = .loop } };
        self.root_p = .{.{ .index = 0, .prov = .{ .guard = .{ .source_proto_id = 0, .source_pc = fl, .role = .loop_done, .operand = .none } } }};
        self.root = .{
            .code = .{ .anchor = .{ .proto = proto, .pc = header, .proto_id = proto.id }, .instrs = &self.root_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &self.root_p },
            .id = first_id,
        };
        self.cont_i = .{.{ .op = .link, .aux = @intCast(link_to) }};
        self.cont_p = .{.{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = proto.id, .source_pc = fl + 1, .inline_depth = 0 } } }};
        self.cont = .{
            .code = .{ .anchor = .{ .proto = proto, .pc = fl + 1, .proto_id = proto.id }, .instrs = &self.cont_i, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{}, .exit_prov = &self.cont_p },
            .id = first_id + 1,
        };
    }
};

fn source(gpa: std.mem.Allocator, pad: usize, k: usize) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "local s = 0\n");
    for (0..pad) |_| try out.appendSlice(gpa, "s = s + 1\n");
    try out.appendSlice(gpa, "repeat\n");
    for (0..k) |_| try out.appendSlice(gpa, "  for i = 1, 3 do s = s + i end\n  s = s + 1\n");
    try out.appendSlice(gpa, "until s > 100\nreturn s\n");
    return out.toOwnedSliceSentinel(gpa, 0);
}

const Row = struct { n: usize, dom_ns: u64, best_ns: u64, mean_ns: u64, ok: bool };

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn measure(gpa: std.mem.Allocator, io: std.Io, pad: usize, k: usize) !Row {
    const src = try source(gpa, pad, k);
    defer gpa.free(src);
    var diags = mahina.diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina.parser.parse(gpa, src, &diags);
    defer tree.deinit();
    var vm = try mahina.interp.Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina.compiler.compile(gpa, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();
    const proto = chunk.proto;

    var fls: std.ArrayListUnmanaged(u32) = .empty;
    defer fls.deinit(gpa);
    for (proto.code, 0..) |ins, pc| if (ins.op == .for_loop) try fls.append(gpa, @intCast(pc));
    std.debug.assert(fls.items.len == k);

    const rcs = try gpa.alloc(RootCont, k);
    defer gpa.free(rcs);
    for (rcs, 0..) |*rc, i| {
        const next = fls.items[(i + 1) % k];
        rc.init(proto, fls.items[i], bytecode.loopHeaderOf(proto.code[next], next).?, @intCast(2 * i + 1));
    }

    var dom_best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const t0 = now(io);
        const d = try mahina.bc_dom.compute(gpa, gpa, proto.code);
        const t1 = now(io);
        mahina.bc_dom.free(gpa, d);
        dom_best = @min(dom_best, @as(u64, @intCast(t1 - t0)));
    }

    var state = trace.TraceState.init(gpa);
    defer state.deinit();
    defer state.registry.detachAll();
    for (rcs) |*rc| {
        try state.registry.attach(&rc.root);
        try state.registry.attach(&rc.cont);
    }
    state.rebuildEdgeCache();
    state.rebuildRegions(); // first sight: mint

    var best: u64 = std.math.maxInt(u64);
    var total: u64 = 0;
    for (0..reps) |_| {
        const t0 = now(io);
        state.rebuildEdgeCache();
        state.rebuildRegions();
        const t1 = now(io);
        const ns: u64 = @intCast(t1 - t0);
        best = @min(best, ns);
        total += ns;
    }

    const first = bytecode.loopHeaderOf(proto.code[fls.items[0]], fls.items[0]).?;
    var ok = state.region_policy.region_defs.count() == 1;
    if (ok) {
        var it = state.region_policy.region_defs.valueIterator();
        const def = it.next().?;
        ok = def.armable and def.owner.pc == first;
    }
    return .{ .n = proto.code.len, .dom_ns = dom_best, .best_ns = best, .mean_ns = total / reps, .ok = ok };
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    mahina.io.print(
        \\region-topology rebuild with k link-fed roots (doc 58 §4.8; {d} rebuilds each)
        \\
        \\{s: >6} {s: >6} {s: >8} {s: >12} {s: >14} {s: >14} {s: >9}
        \\
    , .{ reps, "pad", "k", "n", "dom (us)", "rebuild best", "rebuild mean", "elected" });
    const pads = [_]usize{ 0, 20_000 };
    const ks = [_]usize{ 1, 2, 16, 128, 512, 2048 };
    for (pads) |pad| for (ks) |k| {
        const row = measure(gpa, io, pad, k) catch |e| {
            mahina.io.eprint("bench-topology: error: {s}\n", .{@errorName(e)});
            return 1;
        };
        mahina.io.print("{d: >6} {d: >6} {d: >8} {d: >12.1} {d: >11.1} us {d: >11.1} us {s: >9}\n", .{
            pad,
            k,
            row.n,
            us(row.dom_ns),
            us(row.best_ns),
            us(row.mean_ns),
            if (row.ok) "first" else "WRONG",
        });
    };
    return 0;
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}
