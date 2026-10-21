//! Doc 67 §5.3 (global Rule #20) — `zig build bench-facts` (ReleaseFast).
//!
//! Measures building a compiled page's slab fact tables
//! (`nativegen_factbuild.build`) and one `proves` over them, on one-shot
//! `.link` pages of S slots, up to the recorder's 2000-instruction cap. Each
//! slot is loaded, int-checked and written back, and each slot pair carries
//! a hoisted `guard_for_nov`, so the entry list is ~1.5 S facts and the
//! writeback list ~2.5 S. Columns:
//!
//! - `analyze`: `proveKinds` + `analyze` on the same page, for scale (the
//!   compile already pays it);
//! - `build`: the fact tables, best of `reps`;
//! - `proves`: the writeback list against the entry list, the arm-time check;
//! - `facts`/`bytes`: the table size, and whether it fit `BUDGET_BYTES`.
//!
//! Both passes are linear in exits × writes plus a sort per list, so `build`
//! must stay a small fraction of `analyze`. Informational, not a gate
//! (global Rule #22).

const std = @import("std");
const mahina = @import("mahina");

const value = mahina.value;
const bytecode = mahina.bytecode;
const trace = mahina.trace;
const nativegen = mahina.nativegen;
const factbuild = nativegen.factbuild;
const slab_facts = nativegen.slab_facts;
const Value = value.Value;
const I = trace.IrInstr;
const Trace = trace.TraceCode;
const Kind = nativegen.Kind;

const reps = 50;

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn oneshot(gpa: std.mem.Allocator, s: usize) ![]I {
    var out: std.ArrayListUnmanaged(I) = .empty;
    errdefer out.deinit(gpa);
    var loads = try gpa.alloc(u16, s);
    defer gpa.free(loads);
    for (0..s) |k| {
        loads[k] = @intCast(out.items.len);
        try out.append(gpa, .{ .op = .slot_load, .aux = @intCast(k) });
        try out.append(gpa, .{ .op = .guard_int, .a = loads[k] });
    }
    var k: usize = 0;
    while (k + 1 < s) : (k += 2) try out.append(gpa, .{ .op = .guard_for_nov, .a = loads[k], .b = loads[k + 1] });
    for (0..s) |j| try out.append(gpa, .{ .op = .phi, .b = loads[(j + 1) % s], .aux = @intCast(j) });
    try out.append(gpa, .{ .op = .link });
    return out.toOwnedSlice(gpa);
}

fn row(gpa: std.mem.Allocator, io: std.Io, s: usize) !void {
    const instrs = try oneshot(gpa, s);
    defer gpa.free(instrs);
    var code = [_]bytecode.Instr{.{ .op = .jmp }};
    var proto = bytecode.Proto{ .code = &code, .num_registers = @intCast(s), .name = "bench-facts" };
    const t = Trace{
        .anchor = .{ .proto = &proto, .pc = trace.FUNC_HEAD_PC, .proto_id = proto.id },
        .instrs = instrs,
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    const kinds = try gpa.alloc(Kind, instrs.len);
    defer gpa.free(kinds);
    const slot_of = try gpa.alloc(i32, instrs.len);
    defer gpa.free(slot_of);

    var best_an: i96 = std.math.maxInt(i96);
    var alloc: ?nativegen.Alloc = null;
    defer if (alloc) |*al| al.deinit(gpa);
    for (0..reps) |_| {
        if (alloc) |*al| al.deinit(gpa);
        const t0 = now(io);
        if (!nativegen.proveKinds(gpa, &t, kinds, slot_of)) return error.ProveFailed;
        alloc = nativegen.analyze(gpa, &t, kinds, slot_of);
        best_an = @min(best_an, now(io) - t0);
        if (alloc == null) {
            mahina.io.print("{d: >6} {d: >6}  analyze bails\n", .{ s, instrs.len });
            return;
        }
    }

    var best_build: i96 = std.math.maxInt(i96);
    var built: ?slab_facts.PageFacts = null;
    defer if (built) |*f| f.deinit(gpa);
    for (0..reps) |_| {
        if (built) |*f| f.deinit(gpa);
        const t0 = now(io);
        built = factbuild.build(gpa, &t, kinds, &alloc.?);
        best_build = @min(best_build, now(io) - t0);
    }

    var best_proves: i96 = std.math.maxInt(i96);
    var facts: usize = 0;
    var bytes: usize = 0;
    var verdict: []const u8 = "over budget";
    if (built) |*f| {
        facts = f.facts.len;
        bytes = f.bytes();
        const have = f.exitFacts(.writeback, @intCast(instrs.len - 1)).?;
        var ok = false;
        for (0..reps) |_| {
            const t0 = now(io);
            ok = slab_facts.proves(have, f.entry());
            best_proves = @min(best_proves, now(io) - t0);
        }
        // The rotation rewrites every slot from its neighbour, so the tags
        // survive and every nov dies.
        verdict = if (ok) "fits, proves" else "fits, refutes";
    }
    mahina.io.print("{d: >6} {d: >6} {d: >10.1} us {d: >10.1} us {d: >10.1} us {d: >7} {d: >8}  {s}\n", .{
        s,
        instrs.len,
        @as(f64, @floatFromInt(best_an)) / 1e3,
        @as(f64, @floatFromInt(best_build)) / 1e3,
        if (built != null) @as(f64, @floatFromInt(best_proves)) / 1e3 else 0,
        facts,
        bytes,
        verdict,
    });
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    mahina.io.print("bench-facts: one-shot pages, best of {d} (budget {d} bytes)\n", .{ reps, factbuild.BUDGET_BYTES });
    mahina.io.print("{s: >6} {s: >6} {s: >13} {s: >13} {s: >13} {s: >7} {s: >8}\n", .{ "slots", "instrs", "analyze", "build", "proves", "facts", "bytes" });
    for ([_]usize{ 8, 32, 128, 256, 400, 560 }) |s| row(gpa, io, s) catch |e| {
        mahina.io.eprint("bench-facts: error: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}
