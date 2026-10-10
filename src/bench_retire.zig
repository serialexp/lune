//! Doc 61 §7.1 (Phase Q, global Rule #20) — `zig build bench-retire`
//! (ReleaseFast).
//!
//! Measures trace retirement at a collection — `Vm.collect` →
//! `invalidateDeadTraceConsts` → one `removeTraces` batch — over a closed
//! cycle of N linked traces (N/2 loop roots, each with a continuation that
//! links into the next root, the shape `bench_topology` uses), each naming
//! one heap string constant. A doomed trace's string is unreachable, a
//! survivor's is held by a global, so the collection dooms exactly the chosen
//! fraction. Columns:
//!
//! - `R(T)`: one `rebuildEdgeCache` + `rebuildRegions` over the full cache —
//!   the structural rebuild a batch pays exactly once;
//! - `gc base`: `Vm.collect` with nothing doomed (mark/sweep + the colour scan
//!   over every trace's heap constants, no retirement);
//! - `R(surv)`: the same rebuild over the survivors after the collection —
//!   the rebuild the batch actually paid;
//! - `collect`: `Vm.collect` that retires the doomed fraction in one batch;
//! - `teardown`: `collect - gc base - R(surv)`, the batch's own linear
//!   passes (link/proof/set/edge/want teardown, compaction, anchor reopen);
//! - `per-trace`: the pre-batch shape, `removeTrace` once per doomed trace
//!   (one rebuild each — Θ(doomed × R(T))), for contrast;
//! - `work`: the items the batch's teardown steps visited
//!   (`TraceRegistry.retire_work`), which must grow linearly with N.
//!
//! Two tables: `plain` traces are IR only; `native` traces are compiled to
//! code pages, linked root → continuation → next root, and every root has an
//! entry patch, so the teardown also resets links and marks patches.
//!
//! The batch must cost ≈ gc base + one R(T), independent of how many traces it
//! retires. `rebuilds` is the counted structural-rebuild delta (must be 1).
//! Informational, not a gate (global Rule #22).
//!
//! Reading the native `teardown` column: past a few thousand traces its time
//! per trace grows (≈100 ns at N = 1000, ≈225 ns at 4000, ≈520 ns at 16000)
//! while `work` and the retired instructions stay linear (perf, Oct 2026:
//! ≈1.2k instructions per retired trace at both 4000 and 16000). The growth is
//! dTLB misses — ×9 per ×4 N, tracking cycles — because each trace's record,
//! compiled state and tables are separate heap allocations spread across a
//! growing heap. That is locality, not a superlinear pass.

const std = @import("std");
const mahina = @import("mahina");

const bytecode = mahina.bytecode;
const trace = mahina.trace;
const Trace = trace.Trace;
const IrInstr = trace.IrInstr;
const ExitProvEntry = trace.ExitProvEntry;
const Value = mahina.value.Value;
const Vm = mahina.interp.Vm;

const reps = 5;

fn source(gpa: std.mem.Allocator, k: usize) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "local s = 0\nrepeat\n");
    for (0..k) |_| try out.appendSlice(gpa, "  for i = 1, 3 do s = s + i end\n  s = s + 1\n");
    try out.appendSlice(gpa, "until s > 100\nreturn s\n");
    return out.toOwnedSliceSentinel(gpa, 0);
}

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

const Mode = enum { collect, per_trace };

const Sample = struct {
    r_ns: u64,
    r_surv_ns: u64,
    op_ns: u64,
    retired: u64,
    rebuilds: u64,
    work: u64,
};

/// `plain`: IR-only traces. `native`: every trace compiled to a code page,
/// each root's loop-done exit linked to its continuation and each
/// continuation's `.link` to the next root, and an entry patch on every
/// root, so the teardown also resets links and marks patches.
const Shape = enum { plain, native };

/// Publish one owned trace naming `konst` (the registry owns and frees it).
fn publish(vm: *Vm, code: trace.TraceCode, shape: Shape) !*Trace {
    const t = try vm.trace.registry.allocate();
    t.code = code;
    if (shape == .native) {
        t.native = .{ .compiled = mahina.nativegen.compileInto(vm.trace.gpa, &vm.trace.registry.mcode_arena, &t.code, t.id, null, null) orelse
            return error.NativeBailed };
    }
    try vm.trace.registry.publish(t);
    return t;
}

/// The native root: a loop-done guard over two integer slots (exit 5).
const native_root = [_]IrInstr{
    .{ .op = .slot_load, .aux = 0 },
    .{ .op = .slot_load, .aux = 1 },
    .{ .op = .guard_int, .a = 0 },
    .{ .op = .guard_int, .a = 1 },
    .{ .op = .lt, .a = 0, .b = 1 },
    .{ .op = .guard_true, .a = 4, .aux = 2 },
    .{ .op = .loop },
};
const native_root_exit: u32 = 5;

fn ownedCode(gpa: std.mem.Allocator, anchor: trace.AnchorKey, instrs: []const IrInstr, prov: ExitProvEntry, konst: Value) !trace.TraceCode {
    const heap_consts = try gpa.alloc(u32, 1);
    heap_consts[0] = 0;
    return .{
        .anchor = anchor,
        .instrs = try gpa.dupe(IrInstr, instrs),
        .consts = try gpa.dupe(Value, &.{konst}),
        .heap_consts = heap_consts,
        .entry_slots = try gpa.alloc(u16, 0),
        .entry_guards = try gpa.alloc(trace.EntryGuard, 0),
        .exit_prov = try gpa.dupe(ExitProvEntry, &.{prov}),
    };
}

/// `doom_every`: 0 = nothing doomed, 1 = everything, 10 = every tenth trace.
fn measureOnce(gpa: std.mem.Allocator, io: std.Io, k: usize, doom_every: usize, mode: Mode, shape: Shape) !Sample {
    const src = try source(gpa, k);
    defer gpa.free(src);
    var diags = mahina.diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina.parser.parse(gpa, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina.compiler.compile(gpa, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();
    const proto = chunk.proto;

    var fls: std.ArrayListUnmanaged(u32) = .empty;
    defer fls.deinit(gpa);
    for (proto.code, 0..) |ins, pc| if (ins.op == .for_loop) try fls.append(gpa, @intCast(pc));
    std.debug.assert(fls.items.len == k);

    const traces = try gpa.alloc(*Trace, 2 * k);
    defer gpa.free(traces);
    var name_buf: [32]u8 = undefined;
    var idx: usize = 0;
    var doomed: u64 = 0;
    for (fls.items, 0..) |fl, i| {
        const header = bytecode.loopHeaderOf(proto.code[fl], fl).?;
        const next = fls.items[(i + 1) % k];
        const next_header = bytecode.loopHeaderOf(proto.code[next], next).?;
        for (0..2) |half| {
            const name = try std.fmt.bufPrint(&name_buf, "retire-k{d}", .{idx});
            const konst = try vm.heap.internValue(name);
            const dies = doom_every != 0 and idx % doom_every == 0;
            if (dies) doomed += 1 else try vm.globals.set(vm.gpa, konst, Value.boolean(true));
            const root_prov: ExitProvEntry = .{ .index = if (shape == .native) native_root_exit else 0, .prov = .{ .guard = .{ .source_proto_id = 0, .source_pc = fl, .role = .loop_done, .operand = .none } } };
            const code = if (half == 0)
                try ownedCode(gpa, .{ .proto = proto, .pc = header }, switch (shape) {
                    .plain => &.{
                        .{ .op = .guard_true, .a = 0, .aux = @intCast(fl + 1) },
                        .{ .op = .loop },
                    },
                    .native => &native_root,
                }, root_prov, konst)
            else
                try ownedCode(gpa, .{ .proto = proto, .pc = fl + 1 }, &.{
                    .{ .op = .link, .aux = @intCast(next_header) },
                }, .{ .index = 0, .prov = .{ .link_terminal = .{ .source_proto_id = proto.id, .source_pc = fl + 1, .inline_depth = 0 } } }, konst);
            traces[idx] = try publish(&vm, code, shape);
            idx += 1;
        }
    }
    const ts = &vm.trace;
    if (shape == .native) {
        for (0..k) |i| {
            const root = traces[2 * i];
            const cont = traces[2 * i + 1];
            const next_root = traces[(2 * i + 2) % (2 * k)];
            if (!try ts.armNativeLink(root, native_root_exit, cont, .loop_done_linked)) return error.LinkRefused;
            if (!try ts.armNativeLink(cont, 0, next_root, .link_terminal)) return error.LinkRefused;
            if (ts.installEntryPatch(root) != .installed) return error.PatchRefused;
        }
    }
    ts.rebuildEdgeCache();
    ts.rebuildRegions(); // first sight: mint

    const r0 = now(io);
    ts.rebuildEdgeCache();
    ts.rebuildRegions();
    const r1 = now(io);

    const retired0 = ts.retired_traces;
    const rebuilds0 = ts.region_rebuilds;
    const work0 = totalWork(ts.registry.retire_work);
    var op_ns: u64 = undefined;
    switch (mode) {
        .collect => {
            const t0 = now(io);
            vm.collect();
            const t1 = now(io);
            op_ns = @intCast(t1 - t0);
        },
        .per_trace => {
            var list: std.ArrayListUnmanaged(*Trace) = .empty;
            defer list.deinit(gpa);
            for (ts.registry.cache.items, 0..) |t, i| {
                if (doom_every != 0 and i % doom_every == 0) try list.append(gpa, t);
            }
            const t0 = now(io);
            for (list.items) |t| ts.removeTrace(t);
            const t1 = now(io);
            op_ns = @intCast(t1 - t0);
        },
    }
    const retired = ts.retired_traces - retired0;
    if (retired != doomed) {
        mahina.io.eprint("bench-retire: retired {d}, expected {d}\n", .{ retired, doomed });
        return error.WrongRetirement;
    }
    const rebuilds = ts.region_rebuilds - rebuilds0;
    const work = totalWork(ts.registry.retire_work) - work0;
    // R over the survivors: the rebuild the batch actually paid, so
    // `collect - gc base - R(surv)` is the batch's own teardown cost.
    const s0 = now(io);
    ts.rebuildEdgeCache();
    ts.rebuildRegions();
    const s1 = now(io);
    return .{ .r_ns = @intCast(r1 - r0), .r_surv_ns = @intCast(s1 - s0), .op_ns = op_ns, .retired = retired, .rebuilds = rebuilds, .work = work };
}

/// Items visited over every retirement step (`TraceRegistry.retire_work`).
fn totalWork(w: trace.RetireWork) u64 {
    var sum: u64 = 0;
    for (w.values) |n| sum += n;
    return sum;
}

const Best = struct { r_ns: u64, r_surv_ns: u64, op_ns: u64, retired: u64, rebuilds: u64, work: u64 };

fn measure(gpa: std.mem.Allocator, io: std.Io, k: usize, doom_every: usize, mode: Mode, shape: Shape) !Best {
    var best: Best = .{ .r_ns = std.math.maxInt(u64), .r_surv_ns = std.math.maxInt(u64), .op_ns = std.math.maxInt(u64), .retired = 0, .rebuilds = 0, .work = 0 };
    for (0..reps) |_| {
        const s = try measureOnce(gpa, io, k, doom_every, mode, shape);
        best.r_ns = @min(best.r_ns, s.r_ns);
        best.r_surv_ns = @min(best.r_surv_ns, s.r_surv_ns);
        best.op_ns = @min(best.op_ns, s.op_ns);
        best.retired = s.retired;
        best.rebuilds = s.rebuilds;
        best.work = s.work;
    }
    return best;
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    for ([_]Shape{ .plain, .native }) |shape| {
        if (shape == .native and !mahina.nativegen.is_x64_linux) continue;        table(gpa, io, shape) catch |e| return fail(e);
    }
    return 0;
}

fn table(gpa: std.mem.Allocator, io: std.Io, shape: Shape) !void {
    mahina.io.print(
        \\
        \\trace retirement at a collection, {s} traces (doc 61 Phase Q; best of {d})
        \\
        \\{s: >6} {s: >7} {s: >12} {s: >12} {s: >12} {s: >12} {s: >12} {s: >14} {s: >8} {s: >9} {s: >8}
        \\
    , .{ @tagName(shape), reps, "N", "doomed", "R(T)", "R(surv)", "gc base", "collect", "teardown", "per-trace", "retired", "rebuilds", "work" });
    const ns = [_]usize{ 250, 1000, 4000 };
    for (ns) |n| {
        const k = n / 2;
        const base = try measure(gpa, io, k, 0, .collect, shape);
        for ([_]usize{ 10, 1 }) |every| {
            const batch = try measure(gpa, io, k, every, .collect, shape);
            // The per-trace contrast is Θ(doomed × R(T)); run it on the 10%
            // rows only, where it stays affordable at N = 4000.
            const per: ?Best = if (every == 10) try measure(gpa, io, k, every, .per_trace, shape) else null;
            var per_buf: [24]u8 = undefined;
            const per_txt = if (per) |p| std.fmt.bufPrint(&per_buf, "{d:.1} us", .{us(p.op_ns)}) catch "?" else "-";
            // Signed: at small N the residual is within run-to-run noise.
            const teardown = us(batch.op_ns) - us(base.op_ns) - us(batch.r_surv_ns);
            mahina.io.print("{d: >6} {s: >7} {d: >9.1} us {d: >9.1} us {d: >9.1} us {d: >9.1} us {d: >9.1} us {s: >14} {d: >8} {d: >9} {d: >8}\n", .{
                n,
                if (every == 1) "100%" else "10%",
                us(batch.r_ns),
                us(batch.r_surv_ns),
                us(base.op_ns),
                us(batch.op_ns),
                teardown,
                per_txt,
                batch.retired,
                batch.rebuilds,
                batch.work,
            });
        }
    }
}

fn fail(e: anyerror) u8 {
    mahina.io.eprint("bench-retire: error: {s}\n", .{@errorName(e)});
    return 1;
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}
