//! Tests for `trace.zig` — entrypatch.
//!
//! Extracted verbatim from `trace.zig`; bodies are unchanged.
//! Shared harness lives in `trace_testutil.zig`.

const trace = @import("trace.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const tropt = @import("tropt.zig");
const execlog = @import("execlog.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const jitdbg = @import("jitdbg.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const testing = std.testing;

const AnchorKey = trace.AnchorKey;
const EntryGuard = trace.EntryGuard;
const ExitProvEntry = trace.ExitProvEntry;
const IrInstr = trace.IrInstr;
const Trace = trace.Trace;
const TraceState = trace.TraceState;

// ---- doc 20 Phase 0b: entry-patch substrate (inert) -------------------------

/// Hand-assembled proto with one numeric-for loop: header/anchor at pc=2,
/// `.for_loop` at pc=5 whose taken back-edge (target = 5 + 1 + (-4)) lands on
/// the anchor. pc=7 holds a second `.for_loop` some tests retarget to make the
/// anchor ambiguous.
fn entryPatchTestCode() [8]Instr {
    var code: [8]Instr = undefined;
    for (&code) |*c| c.* = Instr.op0(.ret);
    code[5] = .{ .op = .for_loop, .a = 3, .aux = -4 };
    return code;
}

fn entryPatchTestTrace(gpa: std.mem.Allocator, id: u32, proto: *const Proto, pc: u32) !*Trace {
    const t = try gpa.create(Trace);
    t.* = .{
        .code = .{
            .anchor = .{ .proto = proto, .pc = pc },
            .instrs = try gpa.alloc(IrInstr, 0),
            .consts = try gpa.alloc(Value, 0),
            .entry_slots = try gpa.alloc(u16, 0),
            .entry_guards = try gpa.alloc(EntryGuard, 0),
            .exit_prov = try gpa.alloc(ExitProvEntry, 0),
        },
        .id = id,
    };
    return t;
}

test "doc 20 §T7: no image → codeFor is canonical; resolvePatchPc unique/none/ambiguous" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = entryPatchTestCode();
    const proto = Proto{ .code = &code, .id = 7, .name = "t", .num_registers = 8 };

    // No images: canonical slice, pointer-identical (the count()==0 early-out).
    try testing.expectEqual(@as([*]const Instr, proto.code.ptr), state.codeFor(&proto).ptr);

    // Unique back-edge onto pc=2 resolves to the for_loop at pc=5.
    try testing.expectEqual(@as(?u32, 5), TraceState.resolvePatchPc(&proto, 2));
    // No for_loop targets pc=3 → fail closed.
    try testing.expectEqual(@as(?u32, null), TraceState.resolvePatchPc(&proto, 3));
    // Second for_loop retargeted onto the same anchor → ambiguous → fail closed.
    code[7] = .{ .op = .for_loop, .a = 3, .aux = -6 }; // 7 + 1 - 6 == 2
    try testing.expectEqual(@as(?u32, null), TraceState.resolvePatchPc(&proto, 2));
}

test "doc 20 Phase 3: resolve and lifecycle cover compiler while/repeat closers only" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Doc 58: a `while` loop is patched at its `loop` MARKER, which sits right
    // above the body start — so a marker at pc 1 is the back-edge of the loop
    // anchored at pc 2. Its `aux` is the exit offset (exit pc 8 here), not a
    // jump target, and the patch must preserve it.
    var while_code = entryPatchTestCode();
    while_code[5] = Instr.op0(.ret);
    while_code[1] = .{ .op = .loop, .b = @intFromEnum(bytecode.LoopKind.while_loop), .aux = 6 };
    const while_proto = Proto{ .code = &while_code, .id = 8, .name = "while", .num_registers = 8 };
    try testing.expectEqual(@as(?u32, 1), TraceState.resolvePatchPc(&while_proto, 2));
    const wt = try entryPatchTestTrace(gpa, 10, &while_proto, 2);
    try state.registry.cache.append(gpa, wt);
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(wt));
    try testing.expectEqual(OpCode.jloop, state.codeFor(&while_proto)[1].op);
    try testing.expectEqual(OpCode.loop, while_proto.code[1].op); // canonical stays virgin
    state.markEntryPatchPending(wt.entry_slot.?);
    state.drainEntryPatchWork();
    try testing.expectEqual(OpCode.loop, state.codeFor(&while_proto)[1].op);
    try testing.expect(state.registry.entry_registry.entry_patches.items[0].tombstone);
    // Two back-edges with the same header is ambiguous → no patch.
    while_code[7] = .{ .op = .for_loop, .a = 3, .aux = -6 };
    try testing.expectEqual(@as(?u32, null), TraceState.resolvePatchPc(&while_proto, 2));

    // A `repeat` marker is the same site with the other kind; `.b` (the kind)
    // and `.aux` survive the patch/unpatch transaction. NB the patch stores the
    // slot index in `.b` of the IMAGE instruction, so the canonical `.b` must
    // come back.
    var repeat_code = entryPatchTestCode();
    repeat_code[5] = Instr.op0(.ret);
    repeat_code[1] = .{ .op = .loop, .b = @intFromEnum(bytecode.LoopKind.repeat_loop), .aux = 6 };
    const repeat_proto = Proto{ .code = &repeat_code, .id = 9, .name = "repeat", .num_registers = 8 };
    try testing.expectEqual(@as(?u32, 1), TraceState.resolvePatchPc(&repeat_proto, 2));
    const rt = try entryPatchTestTrace(gpa, 11, &repeat_proto, 2);
    try state.registry.cache.append(gpa, rt);
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(rt));
    try testing.expectEqual(OpCode.jloop, state.codeFor(&repeat_proto)[1].op);
    try testing.expectEqual(@as(i32, 6), state.codeFor(&repeat_proto)[1].aux);
    state.markEntryPatchPending(rt.entry_slot.?);
    state.drainEntryPatchWork();
    try testing.expect(std.meta.eql(repeat_proto.code[1], state.codeFor(&repeat_proto)[1]));

    // Doc 58: the loop CLOSERS are no longer back-edges, so they are never
    // patched — not the `while`'s backward `jmp`, not the `repeat`'s backward
    // `jmp_if_false`, and not the conditional forms the compiler never emits
    // as closers.
    var skipped_code = entryPatchTestCode();
    skipped_code[5] = .{ .op = .jmp, .aux = -4 };
    const skipped_proto = Proto{ .code = &skipped_code, .id = 10, .name = "skipped", .num_registers = 8 };
    try testing.expectEqual(@as(?u32, null), TraceState.resolvePatchPc(&skipped_proto, 2));
    skipped_code[5] = .{ .op = .jmp_if_false, .a = 1, .aux = -4 };
    try testing.expectEqual(@as(?u32, null), TraceState.resolvePatchPc(&skipped_proto, 2));
    skipped_code[5].op = .jmp_if_true;
    try testing.expectEqual(@as(?u32, null), TraceState.resolvePatchPc(&skipped_proto, 2));
    skipped_code[5].op = .jmp_if_not_nil;
    try testing.expectEqual(@as(?u32, null), TraceState.resolvePatchPc(&skipped_proto, 2));
}

test "doc 20 Phase 3: jloop strike exhaustion policy restores canonical and cools to eligible" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Doc 58: a `while` loop's patch site is its `loop` marker at pc 1 (header
    // = the anchor pc 2).
    var code = entryPatchTestCode();
    code[5] = Instr.op0(.ret);
    code[1] = .{ .op = .loop, .b = @intFromEnum(bytecode.LoopKind.while_loop), .aux = 6 };
    const proto = Proto{ .code = &code, .id = 11, .name = "strike", .num_registers = 8 };
    const t = try entryPatchTestTrace(gpa, 12, &proto, 2);
    try state.registry.cache.append(gpa, t);
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(t));
    t.entry_patch = .bound;

    // The common patched-entry tail marks at `patch_strikes`; pin the policy's
    // resulting transaction independently of trace-entry shape.
    const slot = t.entry_slot.?;
    state.registry.entry_registry.entry_patches.items[slot].strikes = state.config.patch_strikes;
    state.markEntryPatchPending(slot);
    state.drainEntryPatchWork();
    try testing.expectEqual(OpCode.loop, state.codeFor(&proto)[1].op);
    try testing.expect(state.registry.entry_registry.entry_patches.items[slot].tombstone);
    try testing.expectEqual(trace.EntryPatchState.eligible, t.entry_patch);
    try testing.expectEqual(@as(?u16, null), t.entry_slot);
}

test "doc 20 Phase 0b: install publishes a .jfor_loop image; canonical untouched; incumbent wins" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = entryPatchTestCode();
    const proto = Proto{ .code = &code, .id = 7, .name = "t", .num_registers = 8 };
    const t = try entryPatchTestTrace(gpa, 1, &proto, 2);
    try state.registry.cache.append(gpa, t);
    const sibling = try entryPatchTestTrace(gpa, 2, &proto, 2);
    try state.registry.cache.append(gpa, sibling);

    const gen0 = state.registry.entry_registry.image_gen;
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(t));
    try testing.expect(state.registry.entry_registry.image_gen != gen0); // frames re-resolve at back-edge
    try testing.expectEqual(@as(?u16, 0), t.entry_slot);

    // Image: `.jfor_loop` at the patch pc, operands preserved, `.b` = slot.
    const img = state.codeFor(&proto);
    try testing.expect(img.ptr != proto.code.ptr);
    try testing.expectEqual(OpCode.jfor_loop, img[5].op);
    try testing.expectEqual(@as(u16, 3), img[5].a);
    try testing.expectEqual(@as(i32, -4), img[5].aux);
    try testing.expectEqual(@as(u16, 0), img[5].b);
    // Everything else byte-identical; canonical NEVER touched.
    for (img, proto.code, 0..) |gi, ci, i| {
        if (i == 5) continue;
        try testing.expect(std.meta.eql(gi, ci));
    }
    try testing.expectEqual(OpCode.for_loop, proto.code[5].op);

    // §R3-1 rule 2: a live incumbent wins — the sibling's install is refused.
    try testing.expectEqual(TraceState.InstallResult{ .incumbent = 0 }, state.installEntryPatch(sibling));
    try testing.expectEqual(@as(?u16, null), sibling.entry_slot);

    // Unpatch: mark (allocation-free) then drain restores in place + tombstones.
    state.markEntryPatchPending(0);
    try testing.expect(!state.registry.entry_registry.entry_patches.items[0].live);
    state.drainEntryPatchWork();
    try testing.expectEqual(OpCode.for_loop, state.codeFor(&proto)[5].op);
    try testing.expect(state.registry.entry_registry.entry_patches.items[0].tombstone);
    try testing.expectEqual(@as(?u16, null), t.entry_slot);

    // The freed slot index is reused by the next install (free-list pop).
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(sibling));
    try testing.expectEqual(@as(?u16, 0), sibling.entry_slot);
    try testing.expectEqual(@as(u16, 0), state.codeFor(&proto)[5].b);
    try testing.expectEqual(@as(usize, 1), state.registry.entry_registry.entry_patches.items.len);
}

test "doc 20 §R7-2: removeTrace marks the slot pre-destroy; drain survives the dropped trace" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = entryPatchTestCode();
    const proto = Proto{ .code = &code, .id = 7, .name = "t", .num_registers = 8 };
    const t = try entryPatchTestTrace(gpa, 1, &proto, 2);
    try state.registry.cache.append(gpa, t);
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(t));

    // removeTrace destroys `t`; the hook must have marked slot 0 first.
    state.removeTrace(t);
    const p = state.registry.entry_registry.entry_patches.items[0];
    try testing.expect(!p.live and p.pending_unpatch);
    // Drain after destroy: traceById(1) → null (dropped), restore + tombstone,
    // and `p.trace` is never dereferenced.
    state.drainEntryPatchWork();
    try testing.expect(p.tombstone);
    try testing.expectEqual(OpCode.for_loop, state.codeFor(&proto)[5].op);
}

test "doc 20 §R2-2: clearCache drops images + registry wholesale (epoch boundary)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = entryPatchTestCode();
    const proto = Proto{ .code = &code, .id = 7, .name = "t", .num_registers = 8 };
    const t = try entryPatchTestTrace(gpa, 1, &proto, 2);
    try state.registry.cache.append(gpa, t);
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(t));
    try testing.expect(state.registry.entry_registry.code_images.count() == 1);

    const gen0 = state.registry.entry_registry.image_gen;
    state.clearCache();
    try testing.expectEqual(@as(usize, 0), state.registry.entry_registry.code_images.count());
    try testing.expectEqual(@as(usize, 0), state.registry.entry_registry.entry_patches.items.len);
    try testing.expectEqual(@as(usize, 0), state.registry.entry_registry.entry_patch_free.items.len);
    try testing.expectEqual(@as(u32, 0), state.registry.entry_registry.entry_patch_dirty);
    try testing.expect(state.registry.entry_registry.image_gen != gen0); // live frames re-resolve to canonical
    try testing.expectEqual(@as([*]const Instr, proto.code.ptr), state.codeFor(&proto).ptr);
}

test "doc 20 triggers: anchor gate and side-arm want both mark the patch pending" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = entryPatchTestCode();
    const proto = Proto{ .code = &code, .id = 7, .name = "t", .num_registers = 8 };
    const anchor = AnchorKey{ .proto = &proto, .pc = 2 };
    const t = try entryPatchTestTrace(gpa, 1, &proto, 2);
    try state.registry.cache.append(gpa, t);

    // Gate trigger: gating the anchor marks its live slot pending.
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(t));
    state.gateNativeUnsupported(anchor);
    try testing.expect(state.registry.entry_registry.entry_patches.items[0].pending_unpatch);
    state.drainEntryPatchWork();
    try testing.expect(state.registry.entry_registry.entry_patches.items[0].tombstone);
    try testing.expectEqual(@as(?u16, null), t.entry_slot);

    // Doc 31 D1: while the anchor is still (dispatch-)gated from the trigger
    // above, want PRODUCTION is barred — crossing hotguard must NOT create a
    // want (it would unpatch the entry on every qualifying exit forever).
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(t));
    var i: u32 = 0;
    while (i < state.config.hotguard) : (i += 1) state.countGuardFailure(anchor, 4);
    try testing.expect(state.wants_side_trace == null);

    // Side-arm trigger: with the gate cleared, `wants_side_trace` crossing
    // hotguard marks pending. (The counter kept saturating while barred, so
    // one more failure is enough — doc 31 §3: hotness is not lost.)
    _ = state.gate.remove(anchor);
    state.countGuardFailure(anchor, 4);
    try testing.expect(state.wants_side_trace != null);
    const p = state.registry.entry_registry.entry_patches.items[t.entry_slot.?];
    try testing.expect(p.pending_unpatch);
    state.drainEntryPatchWork();
    try testing.expectEqual(OpCode.for_loop, state.codeFor(&proto)[5].op);
}

test "doc 31 D1: a record gate leaves the entry patch live and blocks want production" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = entryPatchTestCode();
    const proto = Proto{ .code = &code, .id = 7, .name = "t", .num_registers = 8 };
    const anchor = AnchorKey{ .proto = &proto, .pc = 2 };
    const t = try entryPatchTestTrace(gpa, 1, &proto, 2);
    try state.registry.cache.append(gpa, t);
    try testing.expectEqual(TraceState.InstallResult.installed, state.installEntryPatch(t));

    // Recording failures land in `record_gate`: dispatch stays open
    // (`isGated` false) and the healthy trace's entry patch is NOT marked
    // pending — a record gate never unpatches (doc 31 §3).
    state.gateRecordAnchor(anchor, .record_abort);
    try testing.expect(state.isRecordGated(anchor));
    try testing.expect(!state.isGated(anchor));
    try testing.expect(state.recordingBarred(anchor));
    try testing.expect(!state.registry.entry_registry.entry_patches.items[0].pending_unpatch);

    // Want PRODUCTION is barred while record-gated (review B3): crossing
    // hotguard neither creates a want nor unpatches the entry — without
    // this, every qualifying hot exit would re-unpatch the healthy trace
    // for as long as the record gate stands.
    var i: u32 = 0;
    while (i < state.config.hotguard) : (i += 1) state.countGuardFailure(anchor, 4);
    try testing.expect(state.wants_side_trace == null);
    try testing.expect(!state.registry.entry_registry.entry_patches.items[0].pending_unpatch);

    // After the record cooldown elapses, the saturated counter re-creates
    // the want on the next failure — hotness was never lost.
    state.tick = state.record_gate.get(anchor).?.retry_at;
    state.countGuardFailure(anchor, 4);
    try testing.expect(state.wants_side_trace != null);

    // Record-abandonment survives trace retirement (the penalty_pc analog):
    // the record gate is keyed on the anchor, not the trace.
    state.removeTrace(t);
    try testing.expect(state.record_gate.contains(anchor));
}

test "doc 31 D1 amendment: record-gated anchor arms GATE_SKIP only when no trace exists" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    var code = entryPatchTestCode();
    const proto = Proto{ .code = &code, .id = 7, .name = "t", .num_registers = 8 };
    var code2 = entryPatchTestCode();
    const proto2 = Proto{ .code = &code2, .id = 8, .name = "u", .num_registers = 8 };

    // Record-gated, NO committed trace: the slow path can do nothing here
    // (recording barred, nothing to enter) — the skip must arm, else every
    // back-edge of an abort-blacklisted hot loop pays full `onBackEdge`
    // bookkeeping forever (measured on the first post-split board: tbl_ops
    // +40%, euler14-bit +55%, nsieve-bit-fp +57% jit-vs-t0 drag).
    state.gateRecordAnchor(.{ .proto = &proto, .pc = 2 }, .record_abort);
    state.afterBackEdge(&proto, 2);
    try testing.expect(state.skipBackEdge(&proto, 2));

    // Record-gated WITH a committed trace (separate proto so the hot-count
    // slots cannot collide): the slow path is exactly what enters the trace —
    // must NOT skip (dispatch starvation, review B3).
    const t = try entryPatchTestTrace(gpa, 1, &proto2, 2);
    try state.registry.cache.append(gpa, t);
    state.gateRecordAnchor(t.code.anchor, .record_abort);
    state.afterBackEdge(&proto2, 2);
    try testing.expect(!state.skipBackEdge(&proto2, 2));
}
