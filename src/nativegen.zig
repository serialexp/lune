//! Tier-1b native codegen — the IR-lowering half (the encoder is `x64.zig`).
//!
//! This module turns a hot integer trace into real x86-64 machine code, writes it
//! to an executable page, and hands back a callable function pointer. Commit 2 (this
//! file's first slice) is just the **executable-memory** plumbing + a smoke test;
//! the trace compiler (`compile`) lands in the next commit.
//!
//! ## Target-gating
//!
//! Native codegen is **x86-64 / Linux only** — it emits raw machine code and flips a
//! page to executable, neither of which exists in the `wasm32-freestanding` build
//! that also imports `root.zig`. Every OS-specific reference (`std.posix.mmap`,
//! `std.os.linux.mprotect`) lives inside a function guarded by
//! `if (comptime !is_x64_linux) return error.UnsupportedTarget;`, so on any other
//! target those branches are comptime-pruned and never analyzed. The `x64` encoder
//! itself is target-independent (a pure byte buffer) and compiles everywhere.

const std = @import("std");
const builtin = @import("builtin");
const x64 = @import("x64.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const trace = trace_ir;
const trace_exec = @import("trace_exec.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const fmath = @import("fmath.zig");
const gc = @import("gc.zig");
const stralloc = @import("stralloc.zig");
const string_mod = @import("string.zig");
const Value = value.Value;
const RegWindow = @import("regwindow.zig").RegWindow;
const Trace = trace_code.TraceCode;
const NativeSeedCtx = trace_code.NativeSeedCtx;


// ---------------------------------------------------------------------------
// Executable-memory plumbing lives in `nativegen_mcode.zig` (file-split
// pass). Re-exported here so every existing `nativegen.X` spelling keeps
// resolving and the move stays behaviour-free.
// ---------------------------------------------------------------------------

const mcode = @import("nativegen_mcode.zig");
pub const is_x64_linux = mcode.is_x64_linux;
pub const MapError = mcode.MapError;
pub const PatchError = mcode.PatchError;
pub const ExecPage = mcode.ExecPage;
pub const mapExecutable = mcode.mapExecutable;
pub const SPILL_MAX = mcode.SPILL_MAX;
pub const McodeArena = mcode.McodeArena;

// ---------------------------------------------------------------------------
// The integer-trace compiler
// ---------------------------------------------------------------------------

const Reg = x64.Reg;
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
// ---------------------------------------------------------------------------
// Frozen-layout constants + lane helpers live in `nativegen_layout.zig`
// (file-split pass). Aliased here so every existing spelling keeps
// resolving and the move stays behaviour-free.
// ---------------------------------------------------------------------------

const layout = @import("nativegen_layout.zig");
const ArrLayout = layout.ArrLayout;
const TAG_NIL = layout.TAG_NIL;
const TAG_INT = layout.TAG_INT;
const TAG_BOOL = layout.TAG_BOOL;
const TAG_FLOAT = layout.TAG_FLOAT;
const TAG_HEAP = layout.TAG_HEAP;
const VALUE_TAG_OFF = layout.VALUE_TAG_OFF;
const VALUE_PAYLOAD_OFF = layout.VALUE_PAYLOAD_OFF;
const TABLE_TYPE = layout.TABLE_TYPE;
const HEADER_TYPE_OFF = layout.HEADER_TYPE_OFF;
const METATABLE_OFF = layout.METATABLE_OFF;
const FUNCTION_TYPE = layout.FUNCTION_TYPE;
const CLOSURE_PROTO_OFF = layout.CLOSURE_PROTO_OFF;
const PROTO_ID_OFF = layout.PROTO_ID_OFF;
const NATIVE_TYPE = layout.NATIVE_TYPE;
const STRING_TYPE = layout.STRING_TYPE;
const NATIVE_RECORDED_OFF = layout.NATIVE_RECORDED_OFF;
const BOOL_LANE = layout.BOOL_LANE;
const I8_LANE = layout.I8_LANE;
const I16_LANE = layout.I16_LANE;
const I32_LANE = layout.I32_LANE;
const I64_LANE = layout.I64_LANE;
const U8_LANE = layout.U8_LANE;
const F64_LANE = layout.F64_LANE;
const GRID_LANE = layout.GRID_LANE;
pub const VALUE_LANE = layout.VALUE_LANE;
const HASH_SIZE_FROM_HEADER = layout.HASH_SIZE_FROM_HEADER;
const resolveHashCell = layout.resolveHashCell;
const laneKind = layout.laneKind;
const intLaneWidth = layout.intLaneWidth;
const konstFitsLane = layout.konstFitsLane;
const laneConsistent = layout.laneConsistent;

// ---------------------------------------------------------------------------
// Compiled-artifact types live in `nativegen_artifact.zig` (file-split
// pass). Re-exported here so every existing `nativegen.X` spelling keeps
// resolving and the move stays behaviour-free.
// ---------------------------------------------------------------------------

const artifact = @import("nativegen_artifact.zig");
pub const Kind = artifact.Kind;
pub const NativeResult = artifact.NativeResult;
pub const SilentStaging = artifact.SilentStaging;
pub const NativeResultLedgerLayout = artifact.NativeResultLedgerLayout;
pub const SilentSummaryCell = artifact.SilentSummaryCell;
pub const SilentExitMetadata = artifact.SilentExitMetadata;
pub const ExitPatchKind = artifact.ExitPatchKind;
pub const RET_CONT_SLOTS = artifact.RET_CONT_SLOTS;
pub const NATIVE_TRANSITION_SLOTS = artifact.NATIVE_TRANSITION_SLOTS;
pub const EXIT_NOP5 = artifact.EXIT_NOP5;
pub const ExitPatch = artifact.ExitPatch;
pub const SeedPlan = artifact.SeedPlan;
pub const CompiledTrace = artifact.CompiledTrace;
pub const NativeState = artifact.NativeState;

/// Try to compile `t` to native code. Returns `null` to **bail** — for any reason:
/// an off-target build, a value/op outside the proven-int/bool subset, malformed
/// IR, or an assembly/mapping failure. A `null` is never fatal: the caller falls
/// back to the tier-1a IR-interpreter. Success transfers ownership of an executable
/// page to the returned `CompiledTrace` (free it with `deinit`).
pub fn compile(gpa: std.mem.Allocator, t: *const Trace, trace_id: u32) ?CompiledTrace {
    return compileImpl(gpa, t, trace_id, null, null, null);
}

/// Test entry point for ALLOCATING traces (doc 24): like `compile` but with the
/// heap whose counters/`gc_stress` the `guard_gc` lowering and the `tostr_*`
/// callouts bake as absolute addresses. Without one, an allocating trace bails
/// (fail closed) — see `compileImpl`.
pub fn compileWithHeap(gpa: std.mem.Allocator, t: *const Trace, trace_id: u32, heap: *gc.Heap) ?CompiledTrace {
    return compileImpl(gpa, t, trace_id, null, null, heap);
}

/// Test entry point for SEEDED traces (doc 22 §B.2): like `compile` but with a
/// seeding ctx to bake into the entry prologue. A trace whose seed plan is
/// non-empty cannot compile without one (fail closed, §B.4).
pub fn compileSeeded(gpa: std.mem.Allocator, t: *const Trace, trace_id: u32, seed_ctx: *const NativeSeedCtx) ?CompiledTrace {
    return compileImpl(gpa, t, trace_id, null, seed_ctx, null);
}

/// Production entry point: compile `t` and co-locate its code in the shared `arena`
/// (P-D). Same bail semantics as `compile`; the only difference is where the mcode
/// lives (an arena slot vs a standalone `mmap`). `seed_ctx` is the per-VM seeding
/// context (doc 22 §B.1) a seeded trace's entry prologue bakes; nullable because
/// hand-built test TraceStates carry none — a seeded trace then bails to tier-1a.
pub fn compileInto(gpa: std.mem.Allocator, arena: *McodeArena, t: *const Trace, trace_id: u32, seed_ctx: ?*const NativeSeedCtx, heap: ?*gc.Heap) ?CompiledTrace {
    return compileImpl(gpa, t, trace_id, arena, seed_ctx, heap);
}

/// Shared compile body. `arena == null` maps a standalone owned page (test path);
/// non-null co-locates the code as an arena slot (production path).
fn compileImpl(gpa: std.mem.Allocator, t: *const Trace, trace_id: u32, arena: ?*McodeArena, seed_ctx: ?*const NativeSeedCtx, heap: ?*gc.Heap) ?CompiledTrace {
    if (comptime !is_x64_linux) return null;

    // Doc 45 D2/D6: native lowering of PRECISE traces (per-guard snapshot
    // flush + resume-pc exit ABI) is its own increment — until it lands, a
    // precise trace bails to tier-1a rather than compile exits that would
    // silently entry-replay past its snapshots.
    if (t.deopt_mode == .precise) return null;

    const n = t.instrs.len;
    // Doc 24 D5 fail-closed: an allocating body (`guard_gc` / `tostr_*`) bakes
    // the heap's counter and `gc_stress` addresses (and hands the heap to the
    // interning callouts) — without a heap it cannot be lowered soundly, so it
    // bails to tier-1a rather than compile a body that could never re-check
    // the budget. (Hand-built test TraceStates pass none unless they mean to.)
    if (heap == null) {
        for (t.instrs) |ins| {
            switch (ins.op) {
                .guard_gc, .tostr_int, .tostr_num, .ssub, .srev, .schar1, .srep2, .supper, .slower => return null,
                // Doc 30: the match/scratch class bakes `heap.match_scratch`
                // addresses (scap_int) or passes the heap to the shims
                // (smatch/sgmatch/scap_str). sfindp, str2num_* and sgm_setpos
                // are heap-free by design and deliberately absent.
                .smatch, .sgmatch, .scap_int, .scap_str => return null,
                else => {},
            }
        }
    }
    // A well-formed native-able trace is non-empty and ends in a terminal `loop`,
    // `link`, or `terminal` (doc 44 head close). Re-checked here because
    // `assertWellFormed` is gone in release builds (never trust the IR).
    if (n == 0 or n > 0xFFFF) return null;
    const terminal = t.instrs[n - 1].op;
    if (terminal != .loop and terminal != .link and terminal != .terminal) return null;

    const kinds = gpa.alloc(Kind, n) catch return null;
    defer gpa.free(kinds);
    const slot_of = gpa.alloc(i32, n) catch return null;
    defer gpa.free(slot_of);

    if (!proveKinds(gpa, t, kinds, slot_of)) return null;

    // cut-2: the register allocator + single-snapshot deopt. A `null` is a bail (the
    // trace runs on tier-1a) — e.g. a type-unstable carried slot the hoisted guard
    // can't catch.
    var alloc = analyze(gpa, t, kinds, slot_of) orelse return null;
    defer alloc.deinit(gpa);

    // Doc 22 §A.1b/§B.4: the page-owned seed plan. Needs the slot classes
    // (carried-heap discrimination), so it runs after `analyze`. `null` ⇒ more
    // inputs than the plan can name ⇒ bail (fail closed).
    const seed_plan = computeSeedPlan(t, kinds, alloc.slots, alloc.slot_id_of_ref) orelse return null;
    // Doc 22 §B.2/§B.4 fail-closed: an active plan needs a seeding ctx to bake into
    // the entry prologue. No ctx (hand-built test TraceState) ⇒ the seeded trace
    // cannot self-seed ⇒ bail to tier-1a. This is also what makes the §B.4 invariant
    // definitional: `lower` emits the prologue iff `seed_plan.nonEmpty()`, and this
    // bail guarantees the ctx it bakes exists.
    if (seed_plan.nonEmpty() and seed_ctx == null) return null;
    // B-v (doc 22 §A.1b + §B.6 redundant-seed row): the inactive-slot contract.
    // The seeding helper skips a plan-inactive seed, so its slab slot stays
    // UNWRITTEN at entry — the emitted body must never read it.
    //
    // This was a release `@panic` scanning every instr for an `href` OR a
    // `slot_load` naming the slot. The `href` half was unsatisfiable: it is the
    // exact negation of `computeSeedPlan`'s activation clause (same pure
    // predicate, same `kinds`/`slots`/`slot_id_of_ref`/`t.instrs`, nothing
    // mutated in between), evaluated inside `if (isActive) continue` — a literal
    // contradiction. It could never fire.
    //
    // The `slot_load` half rests on a real and separate fact, so it is kept as a
    // debug assert: `.hash_cell` is the only deactivatable kind, and a hash
    // cell's slot is consumed solely through `href.aux` — `recInputGet` is the
    // only site that emits a seed `slot_load` (and the only one that appends to
    // `entry_slots`), while `seedHashCell` stamps aux and emits none. Checking
    // `entry_slots` instead of every instr also makes it O(inputs x entry_slots).
    if (std.debug.runtime_safety) {
        for (t.inputs, 0..) |seed, i| {
            if (seed_plan.isActive(i)) continue;
            std.debug.assert(seed.kind == .hash_cell);
            for (t.entry_slots) |es| std.debug.assert(es != seed.slot);
        }
    }

    // Frameless production path (arena present): reserve the shared trampoline and
    // emit a body that `jmp`s to its shared_exit. Test path (arena == null) keeps the
    // self-framed ABI so the standalone-page unit tests are untouched — and gives a
    // built-in A/B of the two ABIs over the same lowered trace.
    var shared_exit: ?usize = null;
    var tramp_entry: ?usize = null;
    // Link-slot table (doc 17 Increment 2.3), exactly one usize per IR instr index.
    // Allocated only on the frameless production path (the self-framed test page has no
    // shared trampoline to default to and never chains). Every entry defaults to
    // `shared_exit`, so an unarmed exit behaves exactly like 2.1's direct jump — the
    // table is inert until `driveChain` arms a slot. Its address must be stable *before*
    // `lower` bakes `&slots[i]` as an imm64, so it is allocated here and handed in.
    // No reserved trailing cell: the loop-done ORDINARY deopt reaches `shared_exit`
    // through the memory-staged `NativeResult.exit_target` (it must bypass its own
    // `slot[ei]`, which is the EXCLUSIVE linked-materialized exit — P-C option (b)),
    // so `slots.len == n` and every index is a real IR exit slot that `armNativeLink`
    // may legitimately arm.
    var slots: []usize = &.{};
    var ret_cont_keys: []u32 = &.{};
    var metadata_cells: []usize = &.{};
    var patch_emissions: []?PatchEmission = &.{};
    if (arena) |ar| {
        // Boxed phi tags use one lowering-only spill each so every source tag is
        // snapshotted before parallel destination writes. Include those cells in
        // the fixed trampoline spill ceiling.
        var boxed_tag_spills: u32 = 0;
        for (t.instrs) |ins| if (ins.op == .phi and ins.aux >= 0 and kinds[ins.b] == .boxed) {
            boxed_tag_spills += 1;
        };
        if (alloc.spill_count + boxed_tag_spills > SPILL_MAX) return null;
        const tr = ar.ensureTrampoline() catch return null;
        shared_exit = tr.shared_exit;
        tramp_entry = tr.entry;
        // Five trailing cells are first-class physical links: four keyed
        // return-continuation targets and one continuation-to-head target.
        slots = gpa.alloc(usize, n + NATIVE_TRANSITION_SLOTS) catch return null;
        @memset(slots, tr.shared_exit);
        ret_cont_keys = gpa.alloc(u32, RET_CONT_SLOTS) catch {
            gpa.free(slots);
            return null;
        };
        @memset(ret_cont_keys, std.math.maxInt(u32));
        metadata_cells = gpa.alloc(usize, n) catch {
            gpa.free(ret_cont_keys);
            gpa.free(slots);
            return null;
        };
        @memset(metadata_cells, 0);
        patch_emissions = gpa.alloc(?PatchEmission, n) catch {
            gpa.free(metadata_cells);
            gpa.free(ret_cont_keys);
            gpa.free(slots);
            return null;
        };
        @memset(patch_emissions, null);
    }
    defer if (patch_emissions.len > 0) gpa.free(patch_emissions);
    var keep_ret_cont_keys = false;
    defer if (ret_cont_keys.len > 0 and !keep_ret_cont_keys) gpa.free(ret_cont_keys);

    var asm_buf = x64.Assembler.init(gpa);
    defer asm_buf.deinit();
    const entry_stubs = lower(gpa, t, trace_id, kinds, &alloc, &asm_buf, shared_exit, slots, ret_cont_keys, metadata_cells, patch_emissions, seed_ctx, seed_plan, heap) catch {
        if (metadata_cells.len > 0) gpa.free(metadata_cells);
        if (slots.len > 0) gpa.free(slots);
        return null;
    };
    asm_buf.resolve();

    var patch_count: usize = 0;
    for (patch_emissions) |p| if (p != null) {
        patch_count += 1;
    };
    var exit_patches: []ExitPatch = &.{};
    if (patch_count > 0) {
        exit_patches = gpa.alloc(ExitPatch, patch_count) catch {
            gpa.free(metadata_cells);
            gpa.free(slots);
            return null;
        };
        var pi: usize = 0;
        for (patch_emissions, 0..) |maybe, ei| if (maybe) |em| {
            const off = em.patch_off;
            if (off > asm_buf.code.items.len or asm_buf.code.items.len - off < 5) {
                gpa.free(exit_patches);
                gpa.free(metadata_cells);
                gpa.free(slots);
                return null;
            }
            var original: [5]u8 = undefined;
            @memcpy(&original, asm_buf.code.items[off..][0..5]);
            if ((em.kind == .deopt and original[0] != 0xE9) or
                (em.kind != .deopt and !std.mem.eql(u8, &original, &EXIT_NOP5)))
            {
                gpa.free(exit_patches);
                gpa.free(metadata_cells);
                gpa.free(slots);
                return null;
            }
            exit_patches[pi] = .{
                .kind = em.kind,
                .exit_instr = @intCast(ei),
                .patch_off = @intCast(off),
                .original = original,
                .epilogue_off = @intCast(asm_buf.labelOffset(em.epilogue)),
                .metadata_cell = &metadata_cells[ei],
            };
            pi += 1;
        };
    }

    const page = if (arena) |a|
        a.alloc(asm_buf.code.items) catch {
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        }
    else
        mapExecutable(asm_buf.code.items) catch {
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        };
    // Resolve the secondary-entry stubs' absolute addresses (base + byte offset). Both
    // live in the same mapped `page`, so they are freed with it — no extra owner.
    const base = @intFromPtr(page.code.ptr);
    const linked_entry: ?usize = if (entry_stubs.linked_entry) |off| blk: {
        if (off >= page.code.len) {
            var invalid_page = page;
            invalid_page.deinit();
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        }
        break :blk base + off;
    } else null;
    const ordinary_entry: ?usize = if (entry_stubs.ordinary_entry) |off| blk: {
        if (off >= page.code.len) {
            var invalid_page = page;
            invalid_page.deinit();
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        }
        break :blk base + off;
    } else null;
    // Wiring invariant (2.3b-0/2.3c-0): a frameless production body (arena present ⟺
    // shared_exit set) ALWAYS emits BOTH secondary entries; a self-framed test page
    // never does. Pins that the mechanism produces real secondary entries before an
    // increment arms a slot to them.
    std.debug.assert((arena != null) == (linked_entry != null));
    std.debug.assert((linked_entry != null) == (ordinary_entry != null));
    // Doc 22 §B.4: the plan (source of truth for "this page seeds at entry") and
    // the emitted prologue must agree. This used to be release-asserted over in
    // `stubEnterable`, described there as witnessed by "two independent facts".
    // They are not independent: `seed_hash_exit` is assigned only inside
    // `if (seed_plan.nonEmpty())`, and `stubs.seed_prologue = seed_hash_exit
    // != null` on the single path through `lower` — one fact routed through two
    // fields. As a result that check was a tautology on every real page and
    // could only ever fire on a hand-built test fixture, while costing a branch
    // in a predicate consulted at every arm attempt. Asserted HERE instead,
    // which is where a future conditional-emission path in `lower` would
    // actually break it.
    std.debug.assert(seed_plan.nonEmpty() == entry_stubs.seed_prologue);
    keep_ret_cont_keys = true;
    return .{
        .page = page,
        .trampoline_entry = tramp_entry,
        .slots = slots,
        .ret_cont_keys = ret_cont_keys,
        .gpa = gpa,
        .linked_entry = linked_entry,
        .ordinary_entry = ordinary_entry,
        .exit_patches = exit_patches,
        .metadata_cells = metadata_cells,
        .seed_plan = seed_plan,
        .seed_prologue = entry_stubs.seed_prologue,
        .has_hash_seed = hhs: {
            for (t.inputs, 0..) |seed, i| {
                if (seed_plan.isActive(i) and seed.kind == .hash_cell) break :hhs true;
            }
            break :hhs false;
        },
        .peeled = t.peeled,
    };
}

// ---------------------------------------------------------------------------
// Kind proving / admission lives in `nativegen_prove.zig` (file-split
// pass). Re-exported here so every existing `nativegen.X` spelling keeps
// resolving and the move stays behaviour-free.
// ---------------------------------------------------------------------------

const prove = @import("nativegen_prove.zig");
pub const proveKinds = prove.proveKinds;
const isNumKind = prove.isNumKind;
const operandReads = prove.operandReads;


// ---------------------------------------------------------------------------
// Register/slot allocation lives in `nativegen_alloc.zig` (file-split
// pass). Re-exported here so every existing spelling keeps resolving and
// the move stays behaviour-free.
// ---------------------------------------------------------------------------

const ngalloc = @import("nativegen_alloc.zig");
pub const SlotClass = ngalloc.SlotClass;
pub const Alloc = ngalloc.Alloc;
pub const regBit = ngalloc.regBit;
pub const analyze = ngalloc.analyze;
const Loc = ngalloc.Loc;
const SlotInfo = ngalloc.SlotInfo;
const CALLEE_SAVED_MASK = ngalloc.CALLEE_SAVED_MASK;
const XMM_SCRATCH0 = ngalloc.XMM_SCRATCH0;
const XMM_SCRATCH1 = ngalloc.XMM_SCRATCH1;
const isTransient = ngalloc.isTransient;
const isCommutative = ngalloc.isCommutative;
const locEql = ngalloc.locEql;
const isStringProducerOp = ngalloc.isStringProducerOp;
const isCoalescibleOp = ngalloc.isCoalescibleOp;
const pickReg = ngalloc.pickReg;
const pickRegFrom = ngalloc.pickRegFrom;
const Place = ngalloc.Place;
const locToPlace = ngalloc.locToPlace;
const slotHomePlace = ngalloc.slotHomePlace;
const placeOfRef = ngalloc.placeOfRef;
const ALLOC_ORDER = ngalloc.ALLOC_ORDER;
const XMM_ALLOC_ORDER = ngalloc.XMM_ALLOC_ORDER;
const isCarriedHeapRoot = ngalloc.isCarriedHeapRoot;
const isDynTableRoot = ngalloc.isDynTableRoot;
const opMayExitInBody = ngalloc.opMayExitInBody;
const BodyCallout = ngalloc.BodyCallout;
const calloutMayCollect = ngalloc.calloutMayCollect;
const bodyCalloutOf = ngalloc.bodyCalloutOf;
const computeSeedPlan = ngalloc.computeSeedPlan;


// ---------------------------------------------------------------------------
// Emission helpers live in `nativegen_emit.zig` (file-split pass).
// Aliased here so `lower`'s call sites stay unchanged and every existing
// `nativegen.X` spelling keeps resolving.
// ---------------------------------------------------------------------------

const emit = @import("nativegen_emit.zig");
const placeToReg = emit.placeToReg;
const regToPlace = emit.regToPlace;
const refBaseReg = emit.refBaseReg;
const ArrayBaseField = emit.ArrayBaseField;
const arrayFieldReg = emit.arrayFieldReg;
const refHomeBaseReg = emit.refHomeBaseReg;
const emitAluRegPlace = emit.emitAluRegPlace;
const emitBinAlu = emit.emitBinAlu;
const emitShift = emit.emitShift;
const emitCompare = emit.emitCompare;
const emitFloatCompare = emit.emitFloatCompare;
const floatOperandToXmm = emit.floatOperandToXmm;
const emitFloatBinOp = emit.emitFloatBinOp;
const boxedTagSpill = emit.boxedTagSpill;
const snapshotBoxedTags = emit.snapshotBoxedTags;
const flushBoxedSlot = emit.flushBoxedSlot;
const flushSlot = emit.flushSlot;
const movePlace = emit.movePlace;
const Move = emit.Move;
const emitParallelMove = emit.emitParallelMove;
const emitTeardown = emit.emitTeardown;
const emitReturn = emit.emitReturn;
const slotAddr = emit.slotAddr;
const emitLedgerAppend = emit.emitLedgerAppend;
const emitForcedYieldCheck = emit.emitForcedYieldCheck;
const emitSilentEpilogue = emit.emitSilentEpilogue;
const nativeExitLabel = emit.nativeExitLabel;
const jccNativeExit = emit.jccNativeExit;
const jmpNativeExit = emit.jmpNativeExit;
const nativeLinkedLoopDoneLabel = emit.nativeLinkedLoopDoneLabel;
const isNumericForLoopDoneGuard = emit.isNumericForLoopDoneGuard;
pub const isCompositeBridgeCandidate = emit.isCompositeBridgeCandidate;
const CALLOUT_SAVED_GP = emit.CALLOUT_SAVED_GP;
const emitCalloutSave = emit.emitCalloutSave;
const emitCalloutRestore = emit.emitCalloutRestore;
const emitFloatCallout = emit.emitFloatCallout;
const emitFloorCeilCallout = emit.emitFloorCeilCallout;
const emitIntDivMod = emit.emitIntDivMod;
const emitTostrCallout = emit.emitTostrCallout;
const emitSnewCallout = emit.emitSnewCallout;
const emitScpCallout = emit.emitScpCallout;
const emitMatchCallout = emit.emitMatchCallout;
const emitScapStrCallout = emit.emitScapStrCallout;
const emitStr2NumCallout = emit.emitStr2NumCallout;
const emitSgmSetposCallout = emit.emitSgmSetposCallout;
const emitHrefCallout = emit.emitHrefCallout;
const emitGuardAbsent = emit.emitGuardAbsent;
const emitHStore = emit.emitHStore;
const emitAStore = emit.emitAStore;
const emitGStore = emit.emitGStore;
const emitPhiValueFlush = emit.emitPhiValueFlush;
const emitLinkedLoopDoneSnapshot = emit.emitLinkedLoopDoneSnapshot;
const emitCompositeBridgeSnapshot = emit.emitCompositeBridgeSnapshot;

/// Byte offsets (from `page.code.ptr`) of the two frameless secondary entry stubs a
/// production body emits after its exit tables. Both `null` on the self-framed test
/// path (no shared trampoline → no chaining). `compileImpl` resolves them to absolute
/// addresses against the mapped page.
const EntryStubs = struct {
    linked_entry: ?usize = null,
    ordinary_entry: ?usize = null,
    /// Doc 22 §B.4: whether `lower` actually emitted the seed prologue at
    /// `body_entry`. Recorded from emission itself (`seed_hash_exit != null`),
    /// NOT recomputed from the plan, so `stubEnterable`'s release-assert
    /// `seed_plan.nonEmpty() == seed_prologue` checks two independent facts.
    seed_prologue: bool = false,
};

const PatchEmission = struct {
    kind: ExitPatchKind,
    patch_off: usize,
    epilogue: x64.Label,
};

/// Lower a proven trace to machine code (cut-2). ABI: rdi = tags base, rsi = payloads
/// base (the SoA register file's two lanes), rdx = native result out-param, rbx =
/// committed counter, rax/rcx = scratch. Loop-carried/invariant slots live in registers
/// across iterations (loaded + type-guarded once in the prologue); `regs[]` is written
/// only on a side-exit (the single snapshot) or for write-only slots at the back-edge.
fn lower(gpa: std.mem.Allocator, t: *const Trace, trace_id: u32, kinds: []const Kind, alloc: *const Alloc, a: *x64.Assembler, shared_exit: ?usize, slots: []usize, ret_cont_keys: []u32, metadata_cells: []usize, patch_emissions: []?PatchEmission, seed_ctx: ?*const NativeSeedCtx, seed_plan: SeedPlan, heap: ?*gc.Heap) !EntryStubs {
    const exit_labels = try gpa.alloc(?x64.Label, t.instrs.len);
    defer gpa.free(exit_labels);
    @memset(exit_labels, null);
    const linked_loop_done_labels = try gpa.alloc(?x64.Label, t.instrs.len);
    defer gpa.free(linked_loop_done_labels);
    @memset(linked_loop_done_labels, null);

    // Callee-saved registers we clobber — as a home OR as a transient — must be
    // preserved across the call. `used_callee_saved` already ORs both; iterate a fixed
    // order so push/pop pair up. (Homing only the slot homes here was a latent bug: a
    // linear-scan transient landing in rbp/r12–r15 was clobbered unsaved → SEGV on
    // return once the host actually relied on that register.)
    var callee: [ALLOC_ORDER.len]Reg = undefined;
    var callee_len: usize = 0;
    for (ALLOC_ORDER) |r| {
        if ((regBit(r) & CALLEE_SAVED_MASK) != 0 and (alloc.used_callee_saved & regBit(r)) != 0) {
            callee[callee_len] = r;
            callee_len += 1;
        }
    }

    // Frame = compacted spill area plus one cell per boxed source tag. These tags
    // must survive arbitrary body stores until a one-shot terminal snapshot.
    var boxed_tag_count: u32 = 0;
    for (kinds) |kind| if (kind == .boxed) {
        boxed_tag_count += 1;
    };
    const pushes = 1 + callee_len; // rbx + callee-saved homes
    const frame: i32 = @intCast(std.mem.alignForward(usize, pushes * 8 + (alloc.spill_count + boxed_tag_count) * 8, 16) - pushes * 8);

    // Prologue: save rbx + callee-saved homes, completed = 0, reserve the frame.
    // Frameless (production): the shared trampoline already saved ALL callee-saved,
    // zeroed rbx, and reserved SPILL_MAX*8 of spill area, so the body starts directly
    // at the hoisted guards below. `[rsp + idx*8]` spill addressing is identical
    // (idx < SPILL_MAX, guaranteed by the compileImpl bail); `frame`/`callee` are
    // computed above but used only by the self-framed epilogue.
    if (shared_exit == null) {
        try a.push(.rbx);
        for (callee[0..callee_len]) |r| try a.push(r);
        try a.xorRegReg(.rbx, .rbx);
        if (frame > 0) try a.subRegImm32(.rsp, frame);
    }

    // 2.3b-0 (doc 17): `body_entry` — the trace's real entry, reached fresh from the
    // trampoline (`page.code.ptr`) OR fallen-through from the `linked_entry` stub
    // emitted at the end (which presets `linked_loop_done` for a chained handoff).
    const body_entry = try a.label();
    a.bind(body_entry);
    // Snapshot the entry value of the `rbx` iteration counter into the result so the
    // Zig wrapper can recover this body's OWN committed count as
    // `completed − entry_rbx`. This is the first body instruction (rbx is already
    // zeroed — trampoline for frameless, the `xor` above for self-framed). A child
    // entered via `linked_entry` (2.3b-1) inherits the parent's cumulative `rbx` —
    // recorded here, subtracted out by the wrapper. rdx holds `*NativeResult` for the
    // whole body. Un-fused, rbx = 0, so this stores 0 and `local_completed ==
    // completed` (asserted in the wrapper).
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "entry_rbx"), .rbx);

    const loop_top = try a.label();
    const deopt_exit = try a.label();
    const prologue_fail = try a.label();

    // Doc 22 §B.2: the SEED PROLOGUE. A seeded page resolves its own entry inputs
    // (upvalue / global / hash_cell seeds) by calling the VM's C-ABI seeding twin
    // (`NativeSeedCtx.seed_fn` → interp.zig `nativeSeedFn`) before anything reads
    // the slab — the hoisted tag guards below ([RV-1]) read `tags[slot]` for the
    // seeded slots, so the callout MUST precede them. Emitted iff the plan is
    // non-empty (`compileImpl` bailed when the ctx was missing, so `seed_ctx.?` is
    // guaranteed here — the §B.4 invariant `plan.nonEmpty() ⟺ prologue-present` is
    // definitional). Every entry runs it: fresh trampoline entries AND fused hops
    // through LINKED_ENTRY/ORDINARY_ENTRY (both fall into `body_entry`) — inert for
    // the latter until B-iv opens the arm gates to seeded pages.
    //
    // Register bracket: at `body_entry` only rdi (tags), rsi (payloads) and rdx
    // (*NativeResult) are live caller-saved regs — no home is loaded yet, all XMM
    // are dead, and rbx (the cumulative counter) is callee-saved so the C call
    // preserves it. Three pushes take rsp from ≡8 (mod 16, the body's invariant —
    // see emitHrefCallout) to ≡0, so the call site is aligned with no fixup.
    var seed_hash_exit: ?x64.Label = null;
    var seed_capacity_exit: ?x64.Label = null;
    if (seed_plan.nonEmpty()) {
        const ctx = seed_ctx.?;
        const hash_l = try a.label();
        const cap_l = try a.label();
        const seed_ok = try a.label();
        try a.push(.rdi);
        try a.push(.rsi);
        try a.push(.rdx);
        // SysV args: rdi = &ctx (per-VM, heap-stable), rsi = &t (committed traces
        // are heap-allocated + immutable), rdx = the plan bitmap BY VALUE (the
        // returned CompiledTrace has no stable address to bake — see
        // `NativeSeedCtx.seed_fn`).
        try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(ctx))));
        try a.movRegImm64(.rsi, @bitCast(@as(u64, @intFromPtr(t))));
        try a.movRegImm64(.rdx, @bitCast(seed_plan.bits));
        // `seed_fn` is installed once at VM init and never reassigned — safe to
        // read at compile time and bake.
        try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(ctx.seed_fn))));
        try a.callReg(.rax);
        try a.pop(.rdx);
        try a.pop(.rsi);
        try a.pop(.rdi);
        // Tri-state result, fail closed: SEED_OK runs the body, SEED_HASH_DECLINE
        // takes the hash exit, and EVERYTHING else (SEED_CAPACITY_DECLINE or a
        // value outside the grammar) takes the capacity exit — whose consumer
        // moves to the next candidate, which is sound for any unexpected value.
        try a.cmpRegImm32(.rax, @intCast(NativeSeedCtx.SEED_OK));
        try a.jcc(.e, seed_ok);
        try a.cmpRegImm32(.rax, @intCast(NativeSeedCtx.SEED_HASH_DECLINE));
        try a.jcc(.e, hash_l);
        try a.jmp(cap_l);
        a.bind(seed_ok);
        seed_hash_exit = hash_l;
        seed_capacity_exit = cap_l;
    }

    // [RV-1] Hoisted type guards (all first → no home is live if one fails), then the
    // hoisted slot loads. A guard failure here returns 0 without touching regs[].
    // An int slot checks TAG_INT; a `.ptr` (table) slot checks TAG_HEAP (its
    // table-type + lane are verified below, after the pointer is loaded).
    for (alloc.slots) |s| {
        if (s.class == .write_only) continue;
        if (s.kind == .boxed) continue; // arbitrary tag is copied at terminal
        const tag: u8 = switch (s.kind) {
            .ptr, .func, .native => TAG_HEAP, // all invariant heap pointers
            // A carried-heap slot enters holding a table (TAG_HEAP). Its table-type/
            // metatable facts are NOT hoisted here — the dynamic in-body guard_table
            // re-checks the CURRENT table every iteration (doc 22 §A.1).
            .heap => TAG_HEAP,
            .float => TAG_FLOAT,
            else => TAG_INT,
        };
        // tag lane: `tags[slot]` at rdi+slot (scale-1, free).
        try a.cmpByteMemImm(.rdi, @as(i32, s.slot), tag);
        try a.jcc(.ne, prologue_fail);
    }
    // Boxed tags are immutable source state for the whole one-shot body. Taking
    // this snapshot only after every hoisted guard passed preserves the strict
    // prologue-failure contract: failed entry leaves regs[] byte-identical.
    try snapshotBoxedTags(a, t, kinds, alloc);
    for (alloc.slots) |s| {
        if (s.class == .write_only) continue;
        // payload lane: `payloads[slot]` at rsi+slot*8 (scale-8, free).
        const off: i32 = @as(i32, s.slot) * 8;
        switch (slotHomePlace(s)) {
            .reg => |r| try a.movRegMem(r, .rsi, off),
            .xmm => |x| try a.movsdRegMem(x, .rsi, off), // float slot: load the double
            .mem => |d| {
                // GP/spill raw 8-byte load (int/bool/ptr, and a spilled float — bits
                // are bits, so a spilled float reuses the raw round-trip).
                try a.movRegMem(.rax, .rsi, off);
                try a.movMemReg(.rsp, d, .rax);
            },
        }
    }
    // [C2-prologue] For each `.ptr` table slot the pointer is now in its home; verify
    // the object is a table and its array lane matches the recorded lane — once, here,
    // since neither changes within a native run (the read path never widens). A miss
    // returns 0 (regs[] untouched). The bool-lane is the only lane proveKinds admits.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .ptr) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, TABLE_TYPE);
        try a.jcc(.ne, prologue_fail);
        // [chunk 2a] The table must have NO metatable: recording aborted on a
        // metatable-bearing table, so a trace that reached here only models raw
        // array access. If `setmetatable` added one between trace entries, the
        // raw load/store would skip `__index`/`__newindex` — so side-exit to
        // tier-0 (full dispatch) when `metatable != null`. Checked once in the
        // prologue: a metamethod call is a trace barrier, so the metatable cannot
        // change *within* a single native run.
        try a.cmpQwordMemImm8(preg, METATABLE_OFF, 0);
        try a.jcc(.ne, prologue_fail);
        // Lane check only for array-accessed tables (s.lane >= 0). A hash-only table
        // (H1: href, no aref) has no pinned lane — skip it; the type + metatable checks
        // above already cover the hash path's validity, and the cell pointer was
        // resolved + validated per-entry by seedTraceInputs.
        if (s.lane >= 0) {
            try a.cmpByteMemImm(preg, ArrLayout.array_base + ArrLayout.lane, @intCast(s.lane));
            try a.jcc(.ne, prologue_fail);
        }
        // Grid table (doc 14): the lane check above already proved `array.lane ==
        // .grid` (s.lane == GRID_LANE). Additionally pin the cell element lane and the
        // row stride the recorder folded — gcell's flat-index math uses `stride` as an
        // immediate and gload/gstore use the `grid_elem` width, both sound for the run
        // only if these still match. A grow/widen between entries side-exits here.
        if (s.grid_elem >= 0) {
            try a.cmpByteMemImm(preg, ArrLayout.array_base + ArrLayout.grid_elem, @intCast(s.grid_elem));
            try a.jcc(.ne, prologue_fail);
            // stride is a usize field; the recorder aborted any stride > maxInt(i32),
            // so s.grid_stride fits an imm32 and the full-width compare is exact (a
            // runtime stride grown past i32 simply won't equal it → side-exit).
            try a.movRegMem(.rax, preg, ArrLayout.array_base + ArrLayout.stride);
            try a.cmpRegImm32(.rax, s.grid_stride);
            try a.jcc(.ne, prologue_fail);
        }
    }

    // [U1-prologue] For each `.func` slot the callee pointer is now in its home;
    // verify it is a Lua closure of the recorded `Proto.id` — the cross-frame
    // snapshot guard, checked once here (the upvalue/global cell is re-resolved and
    // re-seeded each entry, so it cannot change within a single native run; a
    // `set_upval`/`set_global` in the traced region aborts recording). A miss returns
    // 0 (regs[] untouched), side-exiting to tier-0 which really pushes the call frame
    // and re-runs the iteration. Byte-identical to irinterp's `guard_func` arm: heap
    // + type==function + `closure.proto.id == aux`.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .func) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        // header.type == function (the payload is a TAG_HEAP `*GcHeader`).
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, FUNCTION_TYPE);
        try a.jcc(.ne, prologue_fail);
        // proto = [closure + CLOSURE_PROTO_OFF]; then proto.id == recorded id. rax is
        // a free scratch here (never a home); it may also BE `preg` for a spilled home
        // (refHomeBaseReg loaded the closure into rax), and overwriting it with the
        // proto pointer is fine — the closure pointer is dead after this load.
        try a.movRegMem(.rax, preg, CLOSURE_PROTO_OFF);
        try a.cmpDwordMemImm(.rax, PROTO_ID_OFF, s.func_id);
        try a.jcc(.ne, prologue_fail);
    }

    // [guard_builtin prologue] For each `.native` slot the callee pointer is now in its
    // home; verify it is a host native carrying exactly the recorded `RecordedBuiltin` tag
    // — the pure-builtin identity guard, checked once here (the upvalue/global cell is
    // re-resolved + re-seeded each entry, so it cannot change within a native run; a
    // `set_upval`/`set_global` in the traced region aborts recording). A miss returns 0
    // (regs[] untouched), side-exiting to tier-0 which really pushes the call frame and
    // re-runs the iteration. Byte-identical to irinterp's `guard_builtin` arm: heap +
    // type==native + `native.recorded == @enumFromInt(tag)`. The `recorded` field is a 2-byte
    // `?RecordedBuiltin` laid out `[payload, has_value]`, so the non-null check is the flag
    // byte == 1 and the identity check is the payload byte == tag.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .native) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        // header.type == native (the payload is a TAG_HEAP `*GcHeader`).
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, NATIVE_TYPE);
        try a.jcc(.ne, prologue_fail);
        // `recorded` non-null (flag byte == 1) AND payload ordinal == recorded tag.
        try a.cmpByteMemImm(preg, NATIVE_RECORDED_OFF + 1, 1);
        try a.jcc(.ne, prologue_fail);
        try a.cmpByteMemImm(preg, NATIVE_RECORDED_OFF, @intCast(s.recorded_tag));
        try a.jcc(.ne, prologue_fail);
    }

    // [guard_string prologue — doc 24 c3 + doc 30 c4b] For each string-pinned
    // slot (a `guard_string`-covered `.heap` slot_load, tagged `is_string` by
    // analyzeInner — invariant OR carried) the pointer is now in its home; the
    // [RV-1] tag-lane check above proved TAG_HEAP, so this pins the object's
    // TYPE — byte-identical to irinterp's `guard_string` arm — once per entry.
    // For an INVARIANT slot that covers the whole run (read-only). For a
    // CARRIED slot it covers iteration 1 only, and iterations 2+ hold a
    // static string-producer result (the c4b classification proof), so
    // string-ness still holds with no per-iteration check. A miss returns 0
    // (regs[] untouched), side-exiting to tier-0 which re-observes and aborts
    // or re-guards.
    for (alloc.slots) |s| {
        if (s.class == .write_only or !s.is_string) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, STRING_TYPE);
        try a.jcc(.ne, prologue_fail);
    }

    // [Phase 2] Materialize the invariant array bases ONCE, now that each `.ptr` slot
    // is proven a table of the recorded lane. `data`/`present` pointers and `len` are
    // fixed for the whole native run (B5), so they live in dedicated registers and the
    // body reads them instead of re-loading `[tbreg+field]` per iteration. The table
    // pointer is fetched into a base register (its home, or rax for a spilled home);
    // each home is a callee-saved register (never rax), so it survives across the few
    // loads here. A slot with no reserved home keeps the per-iteration load.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .ptr) continue;
        if (s.data_home == null and s.present_home == null and s.len_home == null) continue;
        const tb = try refHomeBaseReg(a, s, .rax);
        if (s.data_home) |r| try a.movRegMem(r, tb, ArrLayout.array_base + ArrLayout.data);
        if (s.present_home) |r| try a.movRegMem(r, tb, ArrLayout.array_base + ArrLayout.present);
        if (s.len_home) |r| try a.movRegMem(r, tb, ArrLayout.array_base + ArrLayout.asize);
    }

    // Phase E1/E2: with a preheader marker the run-once region (instructions before
    // it) is emitted by the body loop below but lands physically *before* loop_top —
    // so the bind is deferred to the `.preheader` arm. Without a marker the whole
    // trace is the body and loop_top binds here (byte-identical to pre-E1).
    var marker_idx: ?usize = null;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .preheader) {
            marker_idx = i;
            break;
        }
    }
    if (marker_idx == null) a.bind(loop_top);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            // slot_load: hoisted to the prologue (loop-invariant). guard_int: either
            // hoisted (slot_load operand → one prologue tag-check) or a proven-int
            // derived guard that's statically redundant — both emit nothing here.
            // guard_table/guard_lane: hoisted to the prologue table checks (the lane
            // never changes within a native run) — nothing here either.
            // guard_float joins the hoisted/redundant no-ops: a guard on a slot_load is
            // the prologue TAG_FLOAT tag-check; a guard on a derived float is statically
            // discharged (proveKinds proved the kind) — both emit nothing here.
            // guard_func joins the hoisted no-ops: the closure identity check is in
            // the prologue (loop-invariant snapshot), so nothing here.
            // guard_hash (H1) joins the hoisted/redundant no-ops: the structural
            // recheck happens at entry in `seedTraceInputs` (a failed cell resolve
            // routes the entry to tier-1a, never native) and per-iteration in the
            // `hload` tag-check, so in the native body it emits nothing.
            // guard_builtin joins the hoisted no-ops: the native-identity check is in the
            // prologue (loop-invariant callee snapshot), so nothing here.
            // guard_grid/guard_stride (doc 14): the grid structural guards, hoisted to
            // the prologue grid-elem/stride checks (invariant within a native run) —
            // nothing here, exactly like guard_table/guard_lane.
            // guard_string (doc 24 c3) joins the hoisted/redundant no-ops: on a
            // slot_load it is the prologue `header.type == string` pin; on a
            // proven-string producer it is statically discharged — both emit
            // nothing here.
            .slot_load, .guard_int, .guard_float, .guard_builtin, .guard_grid, .guard_stride, .guard_string => {},
            // guard_lane: hoisted no-op for an invariant `.ptr` root (the prologue
            // compares the lane byte once). For a per-iteration `.heap` root —
            // doc 43 P3's hload'd table field — compare `array.lane` inline
            // against the recorded lane ordinal, side-exiting on mismatch (the
            // loaded table may be a different table each iteration, or the same
            // table rehashed to a different lane).
            .guard_lane => {
                if (isDynTableRoot(kinds, alloc.slots, alloc.slot_id_of_ref, ins.a)) {
                    const tbreg = try refBaseReg(a, alloc, ins.a, .rax);
                    try a.cmpByteMemImm(tbreg, ArrLayout.array_base + ArrLayout.lane, @intCast(ins.aux));
                    try jccNativeExit(a, exit_labels, i, .ne); // lane changed → side-exit
                }
                // else: `.ptr` → prologue-hoisted, no-op
            },
            // guard_func: hoisted no-op for the invariant `.func` callee snapshot
            // (prologue closure/proto-id check). For a `.heap`-kinded operand —
            // doc 43 P2's function-field hload — emit the per-iteration identity
            // check inline: GcHeader.type == function, then proto.id == aux (the
            // recorded stable id; ids survive keyframe restore, pointers do not).
            // Mirrors the prologue check (`stubEnterable`'s func arm) and the
            // dynamic guard_table below. Base resolves through scratch rcx so rax
            // stays free for the proto pointer.
            .guard_func => {
                if (kinds[ins.a] == .heap) {
                    const freg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.cmpByteMemImm(freg, HEADER_TYPE_OFF, FUNCTION_TYPE);
                    try jccNativeExit(a, exit_labels, i, .ne); // not a closure → side-exit
                    try a.movRegMem(.rax, freg, CLOSURE_PROTO_OFF);
                    try a.cmpDwordMemImm(.rax, PROTO_ID_OFF, @bitCast(ins.aux));
                    try jccNativeExit(a, exit_labels, i, .ne); // different proto → side-exit
                }
                // else: `.func` → prologue-hoisted, no-op
            },
            // guard_table: hoisted no-op for invariant `.ptr` operands (prologue
            // checks). For per-iteration roots — a `.heap`-kind VALUE_LANE aload
            // result, or a carried-heap slot whose home the back-edge φ shuffle
            // refreshes (doc 22 §A.1) — emit per-iteration type + metatable checks
            // against the CURRENT table.
            .guard_table => {
                if (isDynTableRoot(kinds, alloc.slots, alloc.slot_id_of_ref, ins.a)) {
                    const tbl_reg = try refBaseReg(a, alloc, ins.a, .rax);
                    // Check GcHeader.type == TABLE_TYPE
                    try a.cmpByteMemImm(tbl_reg, HEADER_TYPE_OFF, TABLE_TYPE);
                    try jccNativeExit(a, exit_labels, i, .ne);
                    // Check Table.metatable == null (metatable field is at a
                    // known offset from *GcHeader since header is the first field).
                    try a.cmpQwordMemImm8(tbl_reg, METATABLE_OFF, 0);
                    try jccNativeExit(a, exit_labels, i, .ne);
                }
                // else: .ptr → prologue-hoisted, no-op
            },
            // guard_hash: for an invariant `.ptr`-rooted href, the seed validation
            // covers it (no-op). For a dynamically-rooted href (`.heap` aload result
            // or carried-heap slot), emit the per-iteration hash.count() check.
            .guard_hash => {
                const href_ins = t.instrs[ins.a];
                if (isDynTableRoot(kinds, alloc.slots, alloc.slot_id_of_ref, href_ins.a)) {
                    // Load the element table's *GcHeader (the href's table operand).
                    const tbl_reg = try refBaseReg(a, alloc, href_ins.a, .rax);
                    // Compare hash.count() (u32) against the recorded population.
                    try a.cmpDwordMemImm(tbl_reg, HASH_SIZE_FROM_HEADER, @intCast(ins.aux));
                    try jccNativeExit(a, exit_labels, i, .ne);
                }
                // else: .ptr → seed-validated, no-op
            },
            .konst => {
                // H1: a `.none`-kind konst is an interned heap-string href key. href
                // reads the seeded cell, not the key, so the key carries no native
                // value — emit nothing (analyze gave it a dead Loc nothing reads).
                if (kinds[i] == .none) continue;
                const bits = t.consts[@intCast(ins.aux)].payload.bits;
                switch (placeOfRef(alloc, i)) {
                    .reg => |r| try a.movRegImm64(r, @bitCast(bits)),
                    // float konst: stage the raw bits in rax, then movq into the XMM home.
                    .xmm => |x| {
                        try a.movRegImm64(.rax, @bitCast(bits));
                        try a.movqXmmReg(x, .rax);
                    },
                    .mem => |d| {
                        // int or spilled-float konst: raw 8-byte store (bits are bits).
                        try a.movRegImm64(.rax, @bitCast(bits));
                        try a.movMemReg(.rsp, d, .rax);
                    },
                }
            },
            .add, .sub, .mul, .div, .band, .bor, .bxor => {
                if (kinds[i] == .float) {
                    // float add/sub/mul/div: SSE2 path with cvtsi2sd-promoted int operands.
                    // (div is ALWAYS float here; band/bor/bxor are always int → int branch.)
                    try emitFloatBinOp(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), kinds[ins.a], placeOfRef(alloc, ins.b), kinds[ins.b]);
                } else {
                    try emitBinAlu(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
                }
            },
            .shl, .shr, .sar => {
                // Always int (proveKinds pins both operands int). Full Lua/mahina semantics
                // via the branch-bracketed cl shift (emitShift); `.sar` adds the
                // sign-fill overflow leg.
                try emitShift(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
            },
            .neg, .bnot => {
                const dst = placeOfRef(alloc, i);
                const pa = placeOfRef(alloc, ins.a);
                switch (dst) {
                    .reg => |R| {
                        if (!(pa == .reg and pa.reg == R)) try placeToReg(a, R, pa);
                        if (ins.op == .neg) try a.negReg(R) else try a.notReg(R);
                    },
                    .mem => |D| {
                        if (Place.eql(pa, dst)) {
                            // In-place spilled home (win 2): neg/not via rcx round-trip
                            // (F7 has no [mem] form in this encoder).
                            try a.movRegMem(.rcx, .rsp, D);
                            if (ins.op == .neg) try a.negReg(.rcx) else try a.notReg(.rcx);
                            try a.movMemReg(.rsp, D, .rcx);
                        } else {
                            try placeToReg(a, .rax, pa);
                            if (ins.op == .neg) try a.negReg(.rax) else try a.notReg(.rax);
                            try a.movMemReg(.rsp, D, .rax);
                        }
                    },
                    .xmm => unreachable, // int neg/bnot only (float-neg is deferred)
                }
            },
            .eq, .ne, .lt, .le => {
                // proveKinds pins the operand pair to both-int or both-float; check one
                // operand to pick the path (float compare via ucomisd, int via cmp).
                if (kinds[ins.a] == .float) {
                    try emitFloatCompare(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
                } else {
                    try emitCompare(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
                }
            },
            // int_of_float: convert the float limit (in its float home) to an exact
            // i64, or side-exit. Mirrors `value.floatAsExactInt` via a cvttsd2si
            // round-trip: truncate to int, convert back, and compare for exact
            // equality. A non-integral value, an out-of-`[-2^63, 2^63)` value (whose
            // cvttsd2si yields the integer-indefinite 0x8000…), or a NaN all fail the
            // compare (NaN sets PF). The result lands in the op's int home.
            .int_of_float => {
                try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), .float);
                try a.cvttsd2siRegReg(.rax, XMM_SCRATCH0); // rax = (i64)trunc(f) or indefinite
                try a.cvtsi2sdRegReg(XMM_SCRATCH1, .rax); // back to double
                try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
                try jccNativeExit(a, exit_labels, i, .ne); // ordered & not equal → non-integral / out-of-range
                try jccNativeExit(a, exit_labels, i, .p); // unordered (NaN) → side-exit
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            // fsqrt: the inlined pure builtin. `@sqrt` ≡ `sqrtsd` bit-for-bit under the
            // default MXCSR (round-to-nearest-even, which mahina never changes) — including
            // `sqrt(-0.0) = -0.0`, `sqrt(x<0) = qNaN`, `sqrt(+inf) = +inf` — so this one
            // SSE instruction reproduces the tier-1a oracle's `Value.float(@sqrt(arg))`
            // exactly. The operand is a proven float; stage it into a scratch XMM, sqrt
            // in place, then move to the float home (xmm or spill). No side-exit: a stale
            // callee is caught by the hoisted `guard_builtin`, not here.
            .fsqrt => {
                // proveKinds pinned .float or .int; an int operand promotes here.
                try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
                try a.sqrtsdRegReg(XMM_SCRATCH0, XMM_SCRATCH0);
                switch (placeOfRef(alloc, i)) {
                    .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
                    .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
                    .reg => unreachable, // a float result never homes in a GP register
                }
            },
            // fsin/fcos/pow: a mid-body callout into THE shared noinline `fmath`
            // kernel (doc 23 D4) — never an inline SSE re-derivation, so every
            // tier runs the one compiled body and bit-identity holds by
            // construction. No side-exit (total functions of proven numerics).
            .fsin, .fcos, .pow => try emitFloatCallout(a, alloc, kinds, ins, i),
            // Doc 35: floor/ceil — integer-returning callout with sentinel check.
            .ffloor, .fceil => try emitFloorCeilCallout(a, alloc, kinds, ins, i, exit_labels),
            // Doc 25: int lane → inline cqo/idiv + floor adjust (side-exit
            // only on a zero divisor); float lane → the shared fmath kernel
            // callout (total, no exit).
            .mod, .idiv => if (ins.ty == .int)
                try emitIntDivMod(a, alloc, ins, i, exit_labels)
            else
                try emitFloatCallout(a, alloc, kinds, ins, i),
            // Doc 24 D5: allocating interned-string producers — mid-body
            // callouts into the shared `stralloc` bodies. Side-exit on OOM.
            .tostr_int, .tostr_num => try emitTostrCallout(a, alloc, kinds, heap.?, ins, i, exit_labels),
            // Doc 24 D4/c3: the snew class — mid-body callouts into the shared
            // `stralloc` shims (which run THE SAME cores as tier-0). Side-exit
            // on null (OOM or the collapsed tier-0 raise).
            .ssub, .srev, .schar1, .srep2, .supper, .slower => try emitSnewCallout(a, alloc, heap.?, ins, i, exit_labels),
            // Doc 26 D3/D4: string.codepoint — the non-allocating string
            // reader. No heap arg; −1 sentinel → side-exit (tier-0 replays
            // the call to its nil result).
            .scp => try emitScpCallout(a, alloc, ins, i, exit_labels),
            .guard_absent => try emitGuardAbsent(a, alloc, kinds, ins, i, exit_labels),
            // --- doc 30: the pattern/str2num callout class -------------------
            // (compileImpl bailed heapless traces containing the heap-needing
            // members, so `heap.?` cannot trip for smatch/sgmatch/scap_*.)
            .sfindp, .smatch, .sgmatch => try emitMatchCallout(a, alloc, t, heap, ins, i, exit_labels),
            .scap_str => try emitScapStrCallout(a, alloc, heap.?, ins, i, exit_labels),
            .str2num_i, .str2num_f => try emitStr2NumCallout(a, alloc, ins, i, exit_labels),
            .sgm_setpos => try emitSgmSetposCallout(a, alloc, ins, i, exit_labels),
            // scap_int: ONE baked absolute load of the int cell (word 2b) in
            // the heap's `match_scratch` — the guard_gc counter-load
            // discipline (the Heap lives at a stable address for the VM's
            // lifetime; compileImpl bailed without one). No call, no save
            // area, no exit — the dominating smatch/sgmatch status check
            // already proved the scratch is this iteration's fill.
            .scap_int => {
                const h = heap.?;
                const addr = @intFromPtr(&h.match_scratch.words[2 * @as(usize, ins.b)]);
                try a.movRegImm64(.rax, @bitCast(@as(u64, addr)));
                try a.movRegMem(.rax, .rax, 0);
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            // guard_sid (doc 30 §2a): interned-identity pin — equal bytes ⇔
            // same object within a heap, so one raw pointer compare against
            // the baked konst-pool string (stable: non-moving GC, consts
            // rooted by the trace) proves the operand IS the record-time
            // pattern. Mismatch → ordinary side-exit.
            .guard_sid => {
                try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
                const expected = t.consts[@intCast(ins.aux)].asHeap();
                try a.movRegImm64(.rcx, @bitCast(@as(u64, @intFromPtr(expected))));
                try a.cmpRegReg(.rax, .rcx);
                try jccNativeExit(a, exit_labels, i, .ne);
            },
            // Doc 24 D4: `#s` of a proven string — one load of the cached
            // `cp_len` (a usize field; every real string's count fits i63).
            .slen => {
                const sreg = try refBaseReg(a, alloc, ins.a, .rcx);
                try a.movRegMem(.rax, sreg, @offsetOf(string_mod.String, "cp_len"));
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            // Doc 24 D3: the allocation-budget entry guard —
            //   passes ⇔ !gc_stress ∧ object_count + A < next_gc.
            // The heap's field addresses are baked absolute (the Heap lives at
            // a stable address for the VM's lifetime; compileImpl bailed
            // without one). Value-less; an ordinary deopt exit on failure —
            // deliberately NOT chainable/hot-guard-counted (no exit PC).
            .guard_gc => {
                const h = heap.?;
                // gc_stress: a 1-byte bool (0/1). Non-zero → exit.
                try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&h.gc_stress))));
                try a.cmpByteMemImm(.rax, 0, 0);
                try jccNativeExit(a, exit_labels, i, .ne);
                // rcx = object_count + A (A is a stamped-positive i32; the sum
                // cannot wrap u64 for any real heap).
                try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&h.object_count))));
                try a.movRegMem(.rcx, .rax, 0);
                try a.addRegImm32(.rcx, @intCast(ins.aux));
                // rcx >= next_gc (unsigned) → exit.
                try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&h.next_gc))));
                try a.cmpRegMem(.rcx, .rax, 0);
                try jccNativeExit(a, exit_labels, i, .ae);
            },
            // --- hash-part field path (H1) --------------------------------------
            // href: load the loop-invariant value-cell pointer (`*Value`) from its
            // seeded slab slot `[rsi + aux*8]` into the href token's home. The cell was
            // resolved + validated once per entry by `seedTraceInputs` (writing it into
            // payload slot `ins.aux` tagged TAG_INT); the body reads it instead of
            // recomputing the hash lookup, exactly as `aref` reads an invariant base.
            .href => {
                if (isDynTableRoot(kinds, alloc.slots, alloc.slot_id_of_ref, ins.a)) {
                    // Per-iteration hash-cell resolution via call-out (the root is a
                    // `.heap`-kind aload result, or a carried-heap slot whose current
                    // table the seed cannot describe — its recorded seed, if any, is
                    // ignored). Save rdi/rsi (SoA bases) and all live caller-saved
                    // homes, call resolveHashCell, restore, check result.
                    std.debug.assert(alloc.callout_save_count != 0); // save area must be reserved
                    try emitHrefCallout(a, t, alloc, kinds, ins, i, exit_labels);
                } else {
                    // Loop-invariant: load seeded cell pointer from slab.
                    const off: i32 = @as(i32, @intCast(ins.aux)) * 8;
                    switch (placeOfRef(alloc, i)) {
                        .reg => |r| try a.movRegMem(r, .rsi, off),
                        .mem => |d| {
                            try a.movRegMem(.rax, .rsi, off);
                            try a.movMemReg(.rsp, d, .rax);
                        },
                        .xmm => unreachable, // a cell pointer is an int kind, never an XMM home
                    }
                }
            },
            // hload: a typed load from the cell. The dominating guard_hash + per-entry
            // seed validation pinned the cell's identity; here we tag-check `[cell+0]`
            // against the recorded field type (side-exit on a type change — the field
            // turned int↔float, bool→heap, etc. mid-loop) and load `[cell+8]`. For a
            // BOOL field this tag check is the field's ONLY strict type pin (the
            // recorder emits no consumer guard — doc 43 P1), same in tier-1a.
            .hload => {
                const creg = try refBaseReg(a, alloc, ins.a, .rcx);
                const want_tag: u8 = switch (kinds[i]) {
                    .float => TAG_FLOAT,
                    .bool => TAG_BOOL,
                    .heap => TAG_HEAP, // doc 43 P2: function/table field — payload is the *GcHeader
                    else => TAG_INT,
                };
                try a.cmpByteMemImm(creg, VALUE_TAG_OFF, want_tag);
                try jccNativeExit(a, exit_labels, i, .ne); // field type changed → drop to tier-1a/tier-0
                if (kinds[i] == .float) {
                    switch (placeOfRef(alloc, i)) {
                        .xmm => |x| try a.movsdRegMem(x, creg, VALUE_PAYLOAD_OFF),
                        .mem => |d| {
                            try a.movsdRegMem(XMM_SCRATCH0, creg, VALUE_PAYLOAD_OFF);
                            try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                        },
                        .reg => unreachable, // a float never homes in a GP register
                    }
                } else {
                    // int, bool, OR heap: raw 8-byte payload load. A bool cell's
                    // payload is the canonical full-width 0/1 (`Value.boolean`
                    // defines all 8 bytes); a heap cell's is the raw *GcHeader —
                    // both land their Kind's GP convention exactly.
                    try a.movRegMem(.rax, creg, VALUE_PAYLOAD_OFF);
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                }
            },
            // hstore: overwrite the present cell in place — tag byte then payload. The
            // present-key rule (record-time abort on an absent key) guarantees the cell
            // exists and a put never grows, so this is a pure in-place 16-byte write (we
            // touch only tag+payload; the 7 padding bytes are unobservable, matching the
            // oracle's struct-assign which also leaves them undefined). int → TAG_INT +
            // 8-byte payload; float → TAG_FLOAT + `movsd`. Heap values declined (proveKinds).
            .hstore => {
                try emitHStore(a, kinds, alloc, ins);
            },
            // --- closed-upvalue-cell path (doc 43 P5) ---------------------------
            // The u-family shares the hash-cell machinery: the seeded slab slot
            // holds a `*Value` (here `&cell.loc.closed`, resolved + alias-verified
            // once per entry by `seedTraceInputs`; any failure DECLINES the whole
            // entry to tier-0 — SEED_CAPACITY_DECLINE — so unlike href there is no
            // per-iteration callout twin, and no dynamic-root variant can exist).
            // uref: href's loop-invariant branch verbatim — load the cell pointer
            // from `[rsi + aux*8]` into the token's home.
            .uref => {
                const off: i32 = @as(i32, @intCast(ins.aux)) * 8;
                switch (placeOfRef(alloc, i)) {
                    .reg => |r| try a.movRegMem(r, .rsi, off),
                    .mem => |d| {
                        try a.movRegMem(.rax, .rsi, off);
                        try a.movMemReg(.rsp, d, .rax);
                    },
                    .xmm => unreachable, // a cell pointer is an int kind, never an XMM home
                }
            },
            // uload: hload minus the `.heap` arm (the recorder never routes a
            // heap-valued cell in v1; proveKinds fails closed). The fused tag
            // check IS the strict pin — for a bool cell it is the only one.
            .uload => {
                const creg = try refBaseReg(a, alloc, ins.a, .rcx);
                const want_tag: u8 = switch (kinds[i]) {
                    .float => TAG_FLOAT,
                    .bool => TAG_BOOL,
                    else => TAG_INT, // proveKinds admits only int/float/bool
                };
                try a.cmpByteMemImm(creg, VALUE_TAG_OFF, want_tag);
                try jccNativeExit(a, exit_labels, i, .ne); // cell type changed → drop to tier-1a/tier-0
                if (kinds[i] == .float) {
                    switch (placeOfRef(alloc, i)) {
                        .xmm => |x| try a.movsdRegMem(x, creg, VALUE_PAYLOAD_OFF),
                        .mem => |d| {
                            try a.movsdRegMem(XMM_SCRATCH0, creg, VALUE_PAYLOAD_OFF);
                            try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                        },
                        .reg => unreachable, // a float never homes in a GP register
                    }
                } else {
                    // int or bool: raw 8-byte payload load (bool payload is the
                    // canonical full-width 0/1 — `Value.boolean` defines all 8 bytes).
                    try a.movRegMem(.rax, creg, VALUE_PAYLOAD_OFF);
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                }
            },
            // ustore: hstore's in-place tag+payload overwrite, verbatim — a closed
            // cell is a bare `Value`, exactly the shape emitHStore writes.
            .ustore => {
                try emitHStore(a, kinds, alloc, ins);
            },
            // --- lane-aware array read path (B2, bool lane) ----------------------
            // aref: materialize idx0 = index (doc 18: identity mapping — logical key
            // IS the physical slot, no `- 1`) into the aref token's own location.
            // The table pointer is reached lazily by each consumer through `aref.a`
            // (the invariant table home), so aref itself touches only the index.
            .aref => {
                const dst = placeOfRef(alloc, i);
                const idxp = placeOfRef(alloc, ins.b);
                switch (dst) {
                    .reg => |R| {
                        try placeToReg(a, R, idxp);
                    },
                    .mem => |D| {
                        try placeToReg(a, .rax, idxp);
                        try a.movMemReg(.rsp, D, .rax);
                    },
                    .xmm => unreachable, // idx0 is an int (aref kind), never an XMM home
                }
            },
            // guard_bounds: idx0 <u asize, else side-exit. [I3] the single idx0 from aref
            // is shared by bounds/present/aload. [I4] precedes guard_present.
            .guard_bounds => {
                const aref_ins = t.instrs[ins.a];
                const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                // [Phase 2] compare against the hoisted `len` register if we have one
                // (reg-reg), else the per-iteration `[tbreg+len]` load.
                const sid = alloc.slot_id_of_ref[aref_ins.a];
                const lenhome: ?Reg = if (sid >= 0) alloc.slots[@intCast(sid)].len_home else null;
                if (lenhome) |lr| {
                    try a.cmpRegReg(ireg, lr);
                } else {
                    const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax);
                    try a.cmpRegMem(ireg, tbreg, ArrLayout.array_base + ArrLayout.asize);
                }
                try jccNativeExit(a, exit_labels, i, .ae); // idx0 >=u asize (unsigned: covers negative keys)
            },
            // guard_present: the slot must hold a value; a hole would read as nil,
            // which the int/bool kind can't hold. The hole test is lane-specific:
            //   - boolean lane: presence is in-band — the data byte is 0 for an
            //     absent slot, so `movzx rax, byte [data+idx0]; cmp; je` bails.
            //   - int/float lanes: a separate presence bitmap — `bt [present], idx0`.
            .guard_present => {
                const aref_ins = t.instrs[ins.a];
                if (aref_ins.aux == BOOL_LANE) {
                    // [Phase 2] data base from its hoisted home (or a per-iter load).
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.loadRegMemSib(.rax, datareg, ireg, 1, false, 0); // movzx rax, byte [data+idx0]
                    try a.cmpRegImm32(.rax, 0);
                    try jccNativeExit(a, exit_labels, i, .e); // byte==0 → hole → side-exit
                } else {
                    // [Phase 2] present-bitmap base from its hoisted home (or per-iter load).
                    const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.btMemReg(preg, 0, ireg);
                    try jccNativeExit(a, exit_labels, i, .ae); // CF==0 → hole → side-exit
                }
            },
            // aload: decode the packed slot the aref addresses into the aload's home.
            // Both lanes reach the table through `aref.a` (the invariant table home)
            // and use rax for the data pointer + rcx for idx0 — exactly the two
            // scratch registers, no third needed (the int load's dst reuses rax).
            .aload => {
                const aref_ins = t.instrs[ins.a];
                if (ins.aux == VALUE_LANE) {
                    // .value-lane aload — load a 16-byte tagged Value element, verify
                    // its tag matches the one recorded, and extract the payload.
                    //
                    // data + idx0*16: SIB can't scale by 16, so shl idx0 by 4 then
                    // add data. The element is a full Value: [tag(1) pad(7) payload(8)].
                    //
                    // The tag check is a FUSED producer-exit: there is no separate
                    // `guard_*` node, the exit identity rides the aload itself
                    // (`opMayExitInBody` reports every VALUE_LANE aload as exiting).
                    // The recorder still emits a `guard_table`/`guard_int`/`guard_float`
                    // after the load for the tier-1a oracle; `proveKinds` discharges it
                    // statically against the kind proven here, so it emits nothing.
                    //
                    // Three element shapes (doc 32): a table pointer (Phase 2,
                    // array-of-structs), an int, or a float. A hole reads back as an
                    // in-band nil `Value`, whose tag matches none of the three — so the
                    // absent `guard_present` (the .value lane has no presence bitmap)
                    // costs nothing: the tag check IS the presence check.
                    const want_tag: u8 = switch (kinds[i]) {
                        .heap => TAG_HEAP,
                        .int => TAG_INT,
                        .float => TAG_FLOAT,
                        else => unreachable, // proveKinds admitted only these three
                    };
                    // Address in rcx, NOT rax. `arrayFieldReg(…, .rax)` returns `.rax`
                    // itself whenever `data` was not hoisted into a register home
                    // (register pressure — `pickRegFrom` can fail), so the older
                    // "shl rax; add rax, datareg" sequence degenerated to
                    // `add rax, rax` and computed a garbage address. Consume the index
                    // into scratch rcx FIRST, then fetch the data base, then add: rcx
                    // is never a home (`BASE_HOME_ORDER` starts at r15) so nothing can
                    // alias it, and `arrayFieldReg`'s fallback only writes rax.
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.movRegReg(.rcx, ireg); // rcx = idx0
                    try a.shlRegImm8(.rcx, 4); // rcx = idx0 * 16
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    try a.addRegReg(.rcx, datareg); // rcx = &data[idx0] (Value*)
                    try a.cmpByteMemImm(.rcx, VALUE_TAG_OFF, want_tag);
                    try jccNativeExit(a, exit_labels, i, .ne); // type changed → side-exit
                    if (kinds[i] == .float) {
                        // The payload is the raw 8-byte double — `movsd` it into the
                        // aload's float home (xmm or spill cell). Byte-identical to
                        // tier-0's `decode`, which returns the stored Value verbatim;
                        // no FP rounding in a load, so 8-mode parity is inherited and
                        // NaN payloads survive.
                        switch (placeOfRef(alloc, i)) {
                            .xmm => |x| try a.movsdRegMem(x, .rcx, VALUE_PAYLOAD_OFF),
                            .mem => |d| {
                                try a.movsdRegMem(XMM_SCRATCH0, .rcx, VALUE_PAYLOAD_OFF);
                                try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                            },
                            .reg => unreachable, // a float never homes in a GP register
                        }
                    } else {
                        // .heap → the *GcHeader; .int → the i64. Same 8-byte payload
                        // load either way.
                        try a.movRegMem(.rax, .rcx, VALUE_PAYLOAD_OFF);
                        try regToPlace(a, placeOfRef(alloc, i), .rax);
                    }
                } else {
                    // Scalar lanes: data base from hoisted home (or per-iter load).
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    if (ins.aux == F64_LANE) {
                        // f64 lane: load the raw 8-byte double at `[data + idx0*8]` into
                        // the aload's float home (an xmm reg or a spill cell). No decode —
                        // tier-0's `array.decode` for `.f64` is a raw `@bitCast`, so `movsd`
                        // moves byte-identical bits (no FP rounding in a load → 8-mode
                        // parity inherited). `lea` the element address (datareg + idx0*8)
                        // into rax, then `movsd` from `[rax]`.
                        try a.leaRegMemSib(.rax, datareg, ireg, 8, 0); // rax = &data[idx0]
                        switch (placeOfRef(alloc, i)) {
                            .xmm => |x| try a.movsdRegMem(x, .rax, 0),
                            .mem => |d| {
                                try a.movsdRegMem(XMM_SCRATCH0, .rax, 0);
                                try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                            },
                            .reg => unreachable, // a float never homes in a GP register
                        }
                    } else {
                        if (ins.aux == BOOL_LANE) {
                            // bool lane: load the in-band byte (1=false, 2=true) and decode
                            // to a clean 0/1 boolean with `byte - 1`. The dominating
                            // guard_present already proved the byte is non-zero (a hole
                            // would be 0), so the result is exactly 0 or 1.
                            try a.loadRegMemSib(.rax, datareg, ireg, 1, false, 0); // movzx rax, byte [data+idx0]
                            try a.subRegImm32(.rax, 1); // 1→0 (false), 2→1 (true)
                        } else if (ins.aux == U8_LANE) {
                            // u8 lane: zero-extend the byte element at `[data + idx0]` into a
                            // full 64-bit int (range 0..255). `movzx` (signed=false), no
                            // `sub` — this is the only point u8 diverges from the signed int
                            // lanes, and it matches `array.decode`'s zero-extend exactly.
                            try a.loadRegMemSib(.rax, datareg, ireg, 1, false, 0); // movzx rax, byte [data+idx0]
                        } else {
                            // int lane (i8…i64): sign-extend the width-byte element at
                            // `[data + idx0*w]` into a full 64-bit int.
                            const w = intLaneWidth(ins.aux);
                            try a.loadRegMemSib(.rax, datareg, ireg, w, true, 0);
                        }
                        try regToPlace(a, placeOfRef(alloc, i), .rax);
                    }
                } // close outer `else` for scalar lanes
            },
            // guard_fits (B4b): range-check the int value (`a`) against the lane's
            // signed bounds and side-exit if it would overflow. Native stores at the
            // lane width and cannot widen the lane the way tier-0 would, so a value
            // that no longer fits must drop back to tier-1a (which then widens). i64
            // holds every int → no check. The compare clobbers only rax (scratch).
            .guard_fits => {
                if (ins.aux == F64_LANE) {
                    // f64-lane guard_fits is a tier-1a-only soundness guard: every
                    // 8-byte bit pattern is a valid double and the lane never narrows,
                    // so there is nothing to range-check. The value is already proven
                    // `.float` in proveKinds. (The oracle, which runs the raw trace,
                    // still re-checks `fits` — but native f64 stores can never widen.)
                } else if (ins.aux == BOOL_LANE) {
                    // Bool-lane guard_fits is a tier-1a-only soundness guard; the
                    // value is already proven `.bool` in proveKinds, so there is
                    // nothing to range-check here.
                } else if (ins.aux == U8_LANE) {
                    // u8 lane: range-check against the *unsigned-byte* bounds
                    // `[0,255]` (NOT the i8 `[-128,127]` the width-1 signed lane
                    // would imply). The value is a full untagged int in rax; the
                    // signed `cmp`+`jcc(.l/.g)` against 0 and 255 is exact (both
                    // bounds are small positive constants, no sign-bit ambiguity).
                    try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
                    try a.cmpRegImm32(.rax, 0);
                    try jccNativeExit(a, exit_labels, i, .l); // value < 0 → side-exit (widen)
                    try a.cmpRegImm32(.rax, 255);
                    try jccNativeExit(a, exit_labels, i, .g); // value > 255 → side-exit (widen)
                } else {
                    const w = intLaneWidth(ins.aux);
                    if (w < 8) {
                        const lo: i32 = switch (w) {
                            1 => std.math.minInt(i8),
                            2 => std.math.minInt(i16),
                            4 => std.math.minInt(i32),
                            else => unreachable,
                        };
                        const hi: i32 = switch (w) {
                            1 => std.math.maxInt(i8),
                            2 => std.math.maxInt(i16),
                            4 => std.math.maxInt(i32),
                            else => unreachable,
                        };
                        try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
                        try a.cmpRegImm32(.rax, lo);
                        try jccNativeExit(a, exit_labels, i, .l); // value < lane min → side-exit (signed)
                        try a.cmpRegImm32(.rax, hi);
                        try jccNativeExit(a, exit_labels, i, .g); // value > lane max → side-exit (signed)
                    }
                }
            },
            // --- lane-aware array write path (B3 bool / B4b int) -----------------
            // astore: write the value into the slot the aref addresses.
            // `idx0` (from the aref) is shared with the dominating guard_bounds [I3].
            .astore => {
                try emitAStore(a, t, kinds, alloc, ins);
            },
            // guard_append (B5-grow): the append precondition, the grow analogue of
            // guard_bounds. Three memory-relative checks, no extra register beyond the
            // two the array path already uses (idx0 in `ireg`, table in `tbreg`):
            //   (1) idx0 == asize — the exact append successor (doc 18 D2.3: the key IS
            //       the next slot under identity mapping).
            //   (2) idx0 <u cap   — room without a realloc. `asize == idx0` from (1), so
            //       comparing idx0 (not a reloaded len) against cap is equivalent and
            //       needs no third register.
            //   (3) hash.size == 0 — the hash is empty, so tier-0's `migrateFromHash`
            //       would be a no-op; a non-empty hash means a contiguous successor
            //       could live there, so side-exit and let tier-0 handle the migrate.
            // Any miss side-exits to tier-0, which reallocs / migrates and re-enters —
            // so the on-trace append (astore_append) never allocates [determinism: the
            // realloc only ever runs as this side-exit, identically across all tiers].
            .guard_append => {
                const aref_ins = t.instrs[ins.a];
                const ireg = try refBaseReg(a, alloc, ins.a, .rcx); // idx0
                const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax); // table ptr
                try a.cmpRegMem(ireg, tbreg, ArrLayout.array_base + ArrLayout.asize);
                try jccNativeExit(a, exit_labels, i, .ne); // idx0 != asize → not the append successor
                try a.cmpRegMem(ireg, tbreg, ArrLayout.array_base + ArrLayout.cap);
                try jccNativeExit(a, exit_labels, i, .ae); // idx0 (==asize) >=u cap → would realloc
                try a.cmpDwordMemImm(tbreg, ArrLayout.hash_size, 0);
                try jccNativeExit(a, exit_labels, i, .ne); // hash non-empty → migrate possible
            },
            // alen (doc 23 D3): the `#t` fast-case border, `max(asize−1, 0)`.
            // Re-verifies the same premises tier-1a checks — hash empty,
            // presence-bitmap lane, (asize ≤ 1 ∨ present(asize−1)) — with
            // memory-operand compares mirroring guard_append, side-exiting to
            // tier-0 (which owns the general border search) on any miss. The
            // bitmap-lane test is a single unsigned range compare: the bitmap
            // lanes are exactly the contiguous ordinals `i8..u8` (pinned by a
            // comptime assert against `Lane.usesPresenceBitmap` below).
            .alen => {
                comptime {
                    for (@typeInfo(arr.Lane).@"enum".field_values) |fv| {
                        const l: arr.Lane = @enumFromInt(fv);
                        const in_range = fv >= @intFromEnum(arr.Lane.i8) and fv <= @intFromEnum(arr.Lane.u8);
                        std.debug.assert(l.scalarPresenceLane() == in_range);
                    }
                }
                const tbreg = try refBaseReg(a, alloc, ins.a, .rax); // table ptr
                try a.cmpDwordMemImm(tbreg, ArrLayout.hash_size, 0);
                try jccNativeExit(a, exit_labels, i, .ne); // hash non-empty → general border
                try a.cmpByteMemImm(tbreg, ArrLayout.array_base + ArrLayout.lane, @intFromEnum(arr.Lane.i8));
                try jccNativeExit(a, exit_labels, i, .b); // below i8 → .value/.boolean (in-band)
                try a.cmpByteMemImm(tbreg, ArrLayout.array_base + ArrLayout.lane, @intFromEnum(arr.Lane.u8));
                try jccNativeExit(a, exit_labels, i, .a); // above u8 → grid
                try a.movRegMem(.rcx, tbreg, ArrLayout.array_base + ArrLayout.asize); // rcx = asize
                const skip_presence = try a.label();
                try a.cmpRegImm32(.rcx, 1);
                try a.jcc(.be, skip_presence); // asize ≤ 1 → border 0, nothing to probe
                try a.movRegMem(.rax, tbreg, ArrLayout.array_base + ArrLayout.present);
                try a.cmpRegImm32(.rax, 0);
                try jccNativeExit(a, exit_labels, i, .e); // no bitmap allocated → side-exit
                try a.subRegImm32(.rcx, 1); // rcx = asize − 1 (the border candidate)
                try a.btMemReg(.rax, 0, .rcx); // CF = present(asize−1)
                try jccNativeExit(a, exit_labels, i, .ae); // bit clear → trailing hole → tier-0
                const done = try a.label();
                try a.jmp(done);
                a.bind(skip_presence);
                try a.xorRegReg(.rcx, .rcx); // asize ≤ 1 → border 0
                a.bind(done);
                try regToPlace(a, placeOfRef(alloc, i), .rcx);
            },
            // astore_append (B5-grow): commit one boolean to `data[asize]` and bump asize.
            // guard_append proved `idx0 == asize < cap` and an empty hash, so this is the
            // bool-lane byte store (`1=false, 2=true`, value+1 — presence is in-band)
            // followed by an in-place `inc qword [tbl+len]`. len has NO register home
            // for an append trace (the home-reservation switch skips astore_append), so
            // the table struct stays the single source of truth: the bump is immediately
            // visible to ANY later guard's side-exit, with no register→regs[] writeback.
            // Later guards DO follow in the body (the loop's index guards / continuation
            // `guard_true`), and a side-exit there is sound: that guard's snapshot resumes
            // tier-0 *past* the already-committed store, so the append + len bump happen
            // exactly once — identical to a pure tier-0 run. (Even in the degenerate case
            // where an exit were to replay the store, len is already bumped, so it lands
            // as an idempotent in-bounds overwrite of the same slot, never a 2nd append.)
            // Were len instead register-homed and flushed only at the back-edge, a
            // post-bump exit would persist a STALE len — which is precisely why len lives
            // in memory here. The realloc a full `append` would do never appears on-trace
            // — it was peeled to the guard_append side-exit.
            //
            // Register discipline: rax/rcx are scratch and are never allocation homes
            // (ALLOC_ORDER excludes them), so no operand of this op is *homed* in rax/rcx
            // — the byte store may clobber rax freely, then `refBaseReg(table, .rax)`
            // re-materializes the table pointer (a callee-saved home reg is returned
            // as-is; a spilled home is reloaded fresh into rax) for the len bump.
            .astore_append => {
                const aref_ins = t.instrs[ins.a];
                if (ins.aux == BOOL_LANE) {
                    // bool-lane byte store, identical to the in-bounds astore bool path.
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.leaRegMemSib(.rax, datareg, ireg, 1, 0); // rax = &data[idx0]
                    try placeToReg(a, .rcx, placeOfRef(alloc, ins.b)); // value 0/1 → rcx
                    try a.incReg(.rcx); // 0→1 (false), 1→2 (true)
                    try a.storeMemReg(.rax, 1, 0, .rcx); // mov byte [rax], cl
                } else {
                    // int lane (i8…i64): identical to the in-bounds astore int path —
                    // width-truncating data store (guard_fits proved it fits) followed
                    // by the presence bit. Unlike the bool byte, the presence bitmap is
                    // a *separate* write, so this is two stores; both must land before
                    // the len bump publishes the slot as live.
                    const w = intLaneWidth(ins.aux);
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.leaRegMemSib(.rax, datareg, ireg, w, 0); // rax = &data[idx0]
                    try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
                    try a.storeMemReg(.rax, w, 0, .rcx); // [rax] = (lane-width) value
                    // presence bit: bts [present], idx0. [I5] commit point for the
                    // absent→present transition (recArraySet refuses nil/out-of-lane,
                    // so this never clears). Re-materialize present base + idx0 (the
                    // data store clobbered rax/rcx if they were the fallback homes).
                    const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
                    const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.btsMemReg(preg, 0, pireg);
                }
                // len += 1, in place in the table struct (no len_home for appends). The
                // table pointer is re-fetched into rax (the value/presence stores above
                // clobbered it). Bumping len LAST publishes the fully-written slot —
                // identical for both lanes, and the single point any later guard's
                // side-exit observes the append as already committed.
                const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax);
                try a.incMemQword(tbreg, ArrLayout.array_base + ArrLayout.asize);
            },
            // --- flattened-grid cell path (doc 14, Phase 8) ---------------------
            // garow: materialize row0 = row - 1 (the 0-based row) into the garow token's
            // home, exactly like `aref`'s idx0. The grid table is reached lazily by each
            // consumer through `garow.a`; garow itself touches only the row operand (b).
            .garow => {
                const dst = placeOfRef(alloc, i);
                const rowp = placeOfRef(alloc, ins.b);
                switch (dst) {
                    .reg => |R| {
                        try placeToReg(a, R, rowp);
                        try a.subRegImm32(R, 1);
                    },
                    .mem => |D| {
                        try placeToReg(a, .rax, rowp);
                        try a.subRegImm32(.rax, 1);
                        try a.movMemReg(.rsp, D, .rax);
                    },
                    .xmm => unreachable, // row0 is an int (aref kind), never an XMM home
                }
            },
            // gcell: materialize the FLAT cell index flat = row0*stride + (col - 1) into
            // the gcell token's home. `row0` is the garow value (a), `col` the column
            // (b), and `stride` is folded as an immediate from the grid table slot — the
            // prologue `guard_stride` proved it equals the runtime stride, so the folded
            // multiply is exact for the whole native run.
            .gcell => {
                const garow_ins = t.instrs[ins.a];
                const sid = alloc.slot_id_of_ref[garow_ins.a]; // table slot (always homed)
                const stridev: i32 = alloc.slots[@intCast(sid)].grid_stride;
                try placeToReg(a, .rax, placeOfRef(alloc, ins.a)); // rax = row0
                try a.movRegImm64(.rcx, stridev); // rcx = stride
                try a.imulRegReg(.rax, .rcx); // rax = row0*stride
                try placeToReg(a, .rcx, placeOfRef(alloc, ins.b)); // rcx = col
                try a.addRegReg(.rax, .rcx); // rax = row0*stride + col
                try a.subRegImm32(.rax, 1); // flat = row0*stride + (col - 1)
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            // guard_gcol: col in [1, stride], else side-exit. `col` is b; `stride` is
            // folded from the grid table slot (gcell.a = garow, garow.a = table slot).
            // Together with the garow's guard_bounds (row0 <u rows) this proves the flat
            // index lands inside the `cap*stride` buffer.
            .guard_gcol => {
                const gcell_ins = t.instrs[ins.a];
                const garow_ins = t.instrs[gcell_ins.a];
                const sid = alloc.slot_id_of_ref[garow_ins.a];
                const stridev: i32 = alloc.slots[@intCast(sid)].grid_stride;
                const colreg = try refBaseReg(a, alloc, ins.b, .rcx);
                try a.cmpRegImm32(colreg, 1);
                try jccNativeExit(a, exit_labels, i, .l); // col < 1 → side-exit (≤0 / grow)
                try a.cmpRegImm32(colreg, stridev);
                try jccNativeExit(a, exit_labels, i, .g); // col > stride → side-exit (grow)
            },
            // guard_gpresent: the cell must hold a value (a hole decodes as nil, which
            // the int cell kind can't carry). `bt [present], flat` against the per-cell
            // presence bitmap, indexed by the gcell flat index.
            .guard_gpresent => {
                const gcell_ins = t.instrs[ins.a];
                const garow_ins = t.instrs[gcell_ins.a];
                const preg = try arrayFieldReg(a, alloc, garow_ins.a, .present, .rax);
                const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
                try a.btMemReg(preg, 0, flatreg);
                try jccNativeExit(a, exit_labels, i, .ae); // CF==0 → hole → side-exit
            },
            // gload: load the grid cell at the flat index (gcell value) and decode by the
            // grid_elem width into the gload's home. Int lanes sign-extend (zero-extend
            // u8) into a GP home (matching `array.decodeGridCell`); the f64 lane `movsd`s
            // the raw 8-byte double at `[data + flat*8]` into an XMM/spill float home —
            // no decode/rounding (decodeGridCell for `.f64` is a raw `@bitCast`, so the
            // bits move byte-identically, 8-mode parity inherited). Mirrors the aload arm.
            .gload => {
                const gcell_ins = t.instrs[ins.a];
                const garow_ins = t.instrs[gcell_ins.a];
                const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
                const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
                if (ins.aux == F64_LANE) {
                    try a.leaRegMemSib(.rax, datareg, flatreg, 8, 0); // rax = &data[flat]
                    switch (placeOfRef(alloc, i)) {
                        .xmm => |x| try a.movsdRegMem(x, .rax, 0),
                        .mem => |d| {
                            try a.movsdRegMem(XMM_SCRATCH0, .rax, 0);
                            try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                        },
                        .reg => unreachable, // a float never homes in a GP register
                    }
                } else if (ins.aux == U8_LANE) {
                    try a.loadRegMemSib(.rax, datareg, flatreg, 1, false, 0); // movzx
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                } else {
                    const w = intLaneWidth(ins.aux);
                    try a.loadRegMemSib(.rax, datareg, flatreg, w, true, 0); // sign-extend
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                }
            },
            // gstore: write the cell at the flat index, then set the presence bit LAST
            // (the absent→present commit point). An int lane does a width-truncating
            // store (guard_fits proved the value fits grid_elem); the f64 lane stages
            // the value into a scratch XMM and `movsd`s the raw double at `[data+flat*8]`
            // (full-width, no truncation — `encodeGridCell` for `.f64` is a raw
            // `@bitCast`, so the bits commit byte-identically). Mirrors the in-bounds
            // `astore` int / f64 paths.
            .gstore => {
                try emitGStore(a, t, alloc, ins);
            },
            .guard_true => switch (kinds[ins.a]) {
                .nil => try jmpNativeExit(a, exit_labels, i),
                // Every non-bool proven value is statically truthy (only
                // nil/false are falsy in Lua) → guard always passes (no-op).
                .int, .float, .ptr, .func, .native, .heap => {},
                .bool => {
                    switch (placeOfRef(alloc, ins.a)) {
                        .reg => |r| try a.cmpRegImm32(r, 0),
                        .mem => |d| try a.cmpQwordMemImm8(.rsp, d, 0),
                        .xmm => unreachable, // a bool is never homed in an XMM
                    }
                    try jccNativeExit(a, exit_labels, i, .e); // false (0) → side-exit
                },
                .none, .aref, .href, .boxed => unreachable, // proveKinds restricts to inspected value kinds
            },
            .guard_false => switch (kinds[ins.a]) {
                .nil => {},
                // A non-bool proven value is never falsy → always side-exit.
                .int, .float, .ptr, .func, .native, .heap => try jmpNativeExit(a, exit_labels, i),
                .bool => {
                    switch (placeOfRef(alloc, ins.a)) {
                        .reg => |r| try a.cmpRegImm32(r, 0),
                        .mem => |d| try a.cmpQwordMemImm8(.rsp, d, 0),
                        .xmm => unreachable, // a bool is never homed in an XMM
                    }
                    try jccNativeExit(a, exit_labels, i, .ne); // true (≠0) → side-exit
                },
                .none, .aref, .href, .boxed => unreachable, // proveKinds restricts to inspected value kinds
            },
            .loop => {
                // [RV-2] write-only slots commit to regs[] BEFORE the shuffle, so the
                // shuffle can't clobber a write-only source that aliases a carried home.
                for (alloc.slots) |s| {
                    if (s.class != .write_only) continue;
                    // Commit the value at its store_ref location (the slot has no home).
                    // flushSlot tags by kind (TAG_FLOAT + movsd for a float store).
                    try flushSlot(a, @as(i32, s.slot), s.kind, placeOfRef(alloc, @intCast(s.store_ref)));
                }
                // PHI shuffle: carried home(slot) <- store_ref location. A win-2
                // coalesced slot already updated its home in place (the move would be a
                // self-move), so it is dropped from the parallel move entirely.
                var nmoves: usize = 0;
                for (alloc.slots) |s| {
                    // Doc 39: a steady-φ slot's entry home is dead post-run-once —
                    // its carried value rides the internal φ's move below (the
                    // entry home's register class may not even match the steady
                    // kind), so the slot-home move is skipped entirely.
                    if (s.class == .carried and !s.coalesced and s.steady_phi < 0) nmoves += 1;
                }
                // Internal φs (Phase E2): each updates its computed home from its
                // back-edge value `b` in this same parallel shuffle — the move set
                // spans both register files, so a φ↔slot cycle is broken correctly.
                for (t.instrs) |p| {
                    if (p.op == .phi and p.aux == trace.PHI_INTERNAL) nmoves += 1;
                }
                const moves = try gpa.alloc(Move, nmoves);
                defer gpa.free(moves);
                const done = try gpa.alloc(bool, nmoves);
                defer gpa.free(done);
                var mi: usize = 0;
                for (alloc.slots) |s| {
                    if (s.class != .carried or s.coalesced or s.steady_phi >= 0) continue;
                    moves[mi] = .{
                        .dst = slotHomePlace(s),
                        .src = placeOfRef(alloc, @intCast(s.store_ref)),
                        .is_float = s.kind == .float,
                    };
                    mi += 1;
                }
                for (t.instrs, 0..) |p, pi| {
                    if (p.op != .phi or p.aux != trace.PHI_INTERNAL) continue;
                    moves[mi] = .{
                        .dst = placeOfRef(alloc, pi), // the φ's computed home
                        .src = placeOfRef(alloc, @intCast(p.b)), // its back-edge update
                        .is_float = kinds[pi] == .float,
                    };
                    mi += 1;
                }
                try emitParallelMove(a, moves, done);
                try a.incReg(.rbx);
                try a.jmp(loop_top);
            },
            .link => {
                // Doc 39: peel is gated on `link_target == null` at recording, so a
                // peeled trace can never carry a `.link` terminal.
                std.debug.assert(!t.peeled);
                // A link-terminated continuation is a one-shot hand-off, not a loop
                // back-edge. Flush every slot-bound φ snapshot directly into regs[]
                // so the linked inner root sees exactly the same entry state as the
                // tier-1a `.link` arm's `flushPhiWriteback`.
                //
                // doc 34: use the STORE value's kind for the tag, not the slot's load
                // kind. In a `.link` trace, a carried slot may be type-unstable
                // (loaded float, stored int — e.g. spectral-norm's `a` accumulator
                // resets to int 0). The receiving trace's prologue re-checks the type,
                // so flushing with the true store type is correct.
                for (alloc.slots) |s| {
                    if (s.store_ref < 0) continue;
                    const ref: usize = @intCast(s.store_ref);
                    const flush_kind = kinds[ref];
                    if (flush_kind == .boxed) {
                        try flushBoxedSlot(a, @as(i32, s.slot), try boxedTagSpill(t, kinds, alloc, ref), placeOfRef(alloc, ref));
                    } else try flushSlot(a, @as(i32, s.slot), flush_kind, placeOfRef(alloc, ref));
                }
                try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
                try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), @intCast(i));
                if (shared_exit != null) {
                    const silent = try a.label();
                    patch_emissions[i] = .{ .kind = .link_terminal, .patch_off = a.code.items.len, .epilogue = silent };
                    try a.nop5();
                }
                // 2.3c-2a: record this `.link` transition (chain source C→I) before the
                // handoff. `exit_instr` = i is now in memory; `exit_reason` is the inherited
                // `.normal`.
                try emitLedgerAppend(a, trace_id, .link_terminal);
                // Chainable: the `.link` terminal is a single-contract hand-off, so
                // its exit jumps through slot[i] (default `shared_exit`, armed → child).
                try emitReturn(a, frame, callee[0..callee_len], shared_exit, trace_id, slotAddr(slots, i));
            },
            // Doc 44 P0: the one-shot head-trace close — `.link`'s flush
            // discipline with a plain (never chainable) exit. Flush every
            // slot-bound φ snapshot into regs[] with the STORE value's kind
            // (the `.link` doc-34 rule: tier-0 re-checks types at the resume
            // pc, so load/store instability is safe), publish the terminal's
            // instruction index, and return through `shared_exit` — no slot
            // indirection, no arm patch site: the dispatcher's terminal
            // consumer (doc 44) owns resumption at `terminal.aux`.
            .terminal => {
                std.debug.assert(!t.peeled); // head closes bypass peel
                for (alloc.slots) |s| {
                    if (s.store_ref < 0) continue;
                    const ref: usize = @intCast(s.store_ref);
                    const flush_kind = kinds[ref];
                    if (flush_kind == .boxed) {
                        try flushBoxedSlot(a, @as(i32, s.slot), try boxedTagSpill(t, kinds, alloc, ref), placeOfRef(alloc, ref));
                    } else try flushSlot(a, @as(i32, s.slot), flush_kind, placeOfRef(alloc, ref));
                }
                // Doc 44 D11: native frame push at the self-call terminal — a
                // LOWERING decision only (recording and tier-1a keep the interp
                // terminal; the ten-leg matrix keeps its D10 shape). The flush
                // above already materialized the caller window, including the
                // argument registers the callee layout reads. Call the runtime
                // push helper; on PUSH_OK it has pushed a REAL VM frame (real
                // `pushFrameVararg`: depth, stack_top, call_seq stream, region
                // context) and refreshed the episode ctx, so this page shifts
                // its lane pointers onto the pushed window (self-call ⇒ same
                // proto ⇒ compile-time `num_registers`) and re-enters its own
                // body: `entry_rbx` re-snapshots the unchanged rbx (harmless),
                // then the seed prologue + hoisted entry-type guards re-run
                // against the NEW activation — the ordinary_entry replica
                // (`linked_loop_done = 0`) keeps the materialization mode
                // clean. Any refusal falls through to the plain terminal exit
                // below, byte-identical to pre-D11 (tier-0 re-executes the
                // call generically, raising any overflow error itself).
                var no_push: ?x64.Label = null;
                const term = t.instrs[i];
                // Head pages descend into themselves. Continuation pages use
                // their dedicated `.call_head` trailing slot; if it is not
                // armed they leave the call to tier-0 unchanged.
                if (trace_code.anchorKind(t.anchor.pc) != .loop and
                    @as(trace.TerminalKind, @enumFromInt(@as(u16, @intCast(term.a)))) == .self_call_interp)
                {
                    if (seed_ctx) |ctx| if (ctx.self_call_push_fn) |push_fn| {
                        const decline = try a.label();
                        // A continuation performs the real push even while its
                        // call-head slot is unarmed.  On that first miss the
                        // committed `.call_push` final row returns to the
                        // dispatcher, which reloads the pushed frame at pc 0;
                        // consume-at-entry then learns the *actual* selected
                        // head page and arms this owner after hotguard evidence.
                        // Pre-gating the helper on an already-armed slot makes
                        // formation circular: no push => no final row => no
                        // pending arm.  This is the return-link twin's normal
                        // deterministic miss path, not an undo requirement.
                        // C-ABI bracket: verbatim the seed-prologue protocol.
                        // rdi/rsi/rdx are the only live caller-saved regs here
                        // (every home was just flushed to memory), rbx is
                        // callee-saved, and three pushes take rsp from ≡8
                        // (mod 16, the body invariant) to ≡0 — aligned call.
                        try a.push(.rdi);
                        try a.push(.rsi);
                        try a.push(.rdx);
                        // SysV args: rdi = &ctx (per-VM, heap-stable), rsi =
                        // &t (committed traces are heap-allocated + immutable),
                        // rdx = the terminal's resume pc (the `.call` index)
                        // BY VALUE. `push_fn` is installed once at VM init and
                        // never reassigned — safe to bake.
                        try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(ctx))));
                        try a.movRegImm64(.rsi, @bitCast(@as(u64, @intFromPtr(t))));
                        try a.movRegImm64(.rdx, @bitCast(@as(u64, @intCast(term.aux))));
                        try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(push_fn))));
                        try a.callReg(.rax);
                        try a.pop(.rdx);
                        try a.pop(.rsi);
                        try a.pop(.rdi);
                        // Two-state result, fail closed: PUSH_OK descends,
                        // EVERYTHING else (PUSH_DECLINE or a value outside the
                        // grammar) runs the plain terminal exit.
                        try a.cmpRegImm32(.rax, @intCast(NativeSeedCtx.PUSH_OK));
                        try a.jcc(.ne, decline);
                        // Count the push for the dispatcher's pushed-frame
                        // consumer (a successful push appends NO ledger row —
                        // only the eventual real exit publishes a terminal).
                        try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "pushed_frames"));
                        try a.addRegImm32(.rax, 1);
                        try a.movMemReg(.rdx, @offsetOf(NativeResult, "pushed_frames"), .rax);
                        const nreg: i32 = t.anchor.proto.num_registers;
                        if (trace_code.anchorKind(t.anchor.pc) == .head) {
                            // Shift onto the pushed callee and re-enter this head.
                            try a.addRegImm32(.rdi, nreg);
                            try a.addRegImm32(.rsi, nreg * 8);
                            try a.movMemImm32(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 0);
                            try a.jmp(body_entry);
                        } else if (shared_exit) |se| {
                            // A continuation push is committed only when its
                            // cross-page head link is live. Otherwise undo is
                            // impossible, so the helper must not have been called.
                            // (The pre-call target gate is emitted below.)
                            try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
                            try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), @intCast(i));
                            try emitLedgerAppend(a, trace_id, .call_push);
                            // A cap cut can return before the child stamps itself.
                            try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
                            try a.addRegImm32(.rdi, nreg);
                            try a.addRegImm32(.rsi, nreg * 8);
                            try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&slots[t.instrs.len + RET_CONT_SLOTS]))));
                            try a.movRegMem(.rax, .rax, 0);
                            try emitForcedYieldCheck(a, se);
                            try a.jmpReg(.rax);
                        }
                        no_push = decline;
                    };
                }
                // Doc 44 D12c: native frame pop at the return terminal — the
                // symmetric twin of the push above, and like it a LOWERING
                // decision only (recording and tier-1a keep the interp
                // terminal). The flush above materialized the callee window,
                // return-value registers included, so the runtime pop helper
                // can copy results into the parent slab window verbatim
                // opRet. The emitted preflight computes the episode's NET
                // pushed-frame count from the two motion counters and passes
                // it by value — the round-6 explicit floor (`net == 0`
                // declines inside the helper: an episode only pops frames IT
                // pushed; the entry frame's own return stays tier-0). POP_OK
                // exits through a DISTINCT `.ret_pop` ledger row (top frame =
                // the popped-into caller at its frozen cursor — the motion
                // consumer's resume contract); any decline falls through to
                // the plain `head_terminal` exit, byte-identical to pre-D12c
                // (tier-0 re-executes the `ret` generically).
                if (@as(trace.TerminalKind, @enumFromInt(@as(u16, @intCast(term.a)))) == .return_interp) {
                    if (seed_ctx) |ctx| if (ctx.self_ret_pop_fn) |pop_fn| {
                        const no_pop = try a.label();
                        // Same C-ABI bracket as the push: three pushes take
                        // rsp ≡8 → ≡0 (aligned call); rdi/rsi/rdx are the
                        // only live caller-saved regs (homes just flushed).
                        try a.push(.rdi);
                        try a.push(.rsi);
                        try a.push(.rdx);
                        // net = pushed - popped, read while rdx still holds
                        // the *NativeResult (before the arg loads clobber it).
                        try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "pushed_frames"));
                        try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "popped_frames"));
                        try a.subRegReg(.rcx, .rax);
                        // SysV args: rdi = &ctx, rsi = &t, rdx = the
                        // terminal's `.ret` pc BY VALUE, rcx = net (above).
                        try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(ctx))));
                        try a.movRegImm64(.rsi, @bitCast(@as(u64, @intFromPtr(t))));
                        try a.movRegImm64(.rdx, @bitCast(@as(u64, @intCast(term.aux))));
                        try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(pop_fn))));
                        try a.callReg(.rax);
                        try a.pop(.rdx);
                        try a.pop(.rsi);
                        try a.pop(.rdi);
                        // Two-state result, fail closed: POP_OK takes the
                        // `.ret_pop` exit, EVERYTHING else the plain terminal.
                        try a.cmpRegImm32(.rax, @intCast(NativeSeedCtx.POP_OK));
                        try a.jcc(.ne, no_pop);
                        try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "popped_frames"));
                        try a.addRegImm32(.rax, 1);
                        try a.movMemReg(.rdx, @offsetOf(NativeResult, "popped_frames"), .rax);
                        try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
                        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), @intCast(i));
                        try emitLedgerAppend(a, trace_id, .ret_pop);
                        // A miss/cap cut returns before a child stamps itself.
                        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
                        // Dynamic resume-PC dispatch. Keys and target cells are
                        // stable page-owned storage; publication writes the key
                        // before the target. A miss exits with the committed pop.
                        if (shared_exit) |se| {
                            const nreg: i32 = t.anchor.proto.num_registers;
                            for (ret_cont_keys, 0..) |*key, ki| {
                                const next = try a.label();
                                try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(ctx))));
                                try a.movRegMem32(.rax, .rax, @offsetOf(NativeSeedCtx, "ret_resume_pc"));
                                try a.movRegImm64(.rcx, @bitCast(@as(u64, @intFromPtr(key))));
                                // Keys are u32: a qword comparison also reads the
                                // next key (and reads past the final key).
                                try a.movRegMem32(.rcx, .rcx, 0);
                                try a.cmpRegReg(.rax, .rcx);
                                try a.jcc(.ne, next);
                                try a.movRegImm64(.rcx, @bitCast(@as(u64, @intFromPtr(&slots[t.instrs.len + ki]))));
                                try a.movRegMem(.rax, .rcx, 0);
                                try a.movRegImm64(.rcx, @bitCast(@as(u64, se)));
                                try a.cmpRegReg(.rax, .rcx);
                                try a.jcc(.e, next);
                                // Only a real armed hit changes lane ownership.
                                try a.subRegImm32(.rdi, nreg);
                                try a.subRegImm32(.rsi, nreg * 8);
                                try emitForcedYieldCheck(a, se);
                                try a.jmpReg(.rax);
                                a.bind(next);
                            }
                        }
                        try emitReturn(a, frame, callee[0..callee_len], shared_exit, trace_id, null);
                        a.bind(no_pop);
                    };
                }
                if (no_push) |l| a.bind(l);
                try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
                try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), @intCast(i));
                try emitLedgerAppend(a, trace_id, .head_terminal);
                try emitReturn(a, frame, callee[0..callee_len], shared_exit, trace_id, null);
            },
            // A φ emits no code in the body: a slot-bound φ's writeback is driven by
            // its slot's `.carried`/`.write_only` class above (the back-edge shuffle /
            // deopt flush read `store_ref`, which was set from this φ's `b` in
            // `analyzeInner`). An internal φ's home is seeded at the `.preheader` arm
            // and updated in the back-edge shuffle — also nothing here.
            .phi => {},
            // Phase E1/E2: the preheader marker. The run-once region (instructions
            // before it) was just emitted by the loop above, physically ahead of
            // loop_top. Seed each internal φ's computed home from its init (a run-once
            // value, already materialized), then bind loop_top so everything below
            // repeats each iteration. A preheader-less trace bound loop_top earlier.
            .preheader => {
                for (t.instrs, 0..) |p, pi| {
                    if (p.op != .phi or p.aux != trace.PHI_INTERNAL) continue;
                    try movePlace(a, placeOfRef(alloc, pi), placeOfRef(alloc, @intCast(p.a)));
                }
                a.bind(loop_top);
            },
            else => unreachable, // proveKinds rejected everything else
        }
    }

    // Per-guard side-exit stubs. Each writes the deterministic failing IR index, RESOLVES
    // its dispatch target into the memory-staged `NativeResult.exit_target`, then jumps to
    // the shared single-snapshot flush (`deopt_exit`), which flushes carried homes, writes
    // `completed`, and jumps `qword [rdx+exit_target]` (2.3c-0). The resolved target lives
    // in a `*NativeResult` field (not a register) because `flushSlot`'s spilled-payload
    // path clobbers rax — a register-staged holder would not survive the flush.
    //
    // Ordinary guard: resolve THROUGH its OWN `slot[ei]` (deref it now — arming only
    // happens between native runs, so the value is stable across the flush) — default
    // `shared_exit` (byte-identical to 2.1's direct jump), armed to a child body entry in
    // 2.3c-1. Loop-done guard: the `linked_loop_done != 0` case jumps to the linked-
    // materialized stub (mode 1); the ORDINARY fallthrough (mode 0) must bypass `slot[ei]`
    // — that slot is EXCLUSIVELY the linked exit (P-C option (b) invariant) — so it
    // resolves directly to `shared_exit`.
    for (exit_labels, 0..) |maybe_l, ei| {
        if (maybe_l) |l| {
            a.bind(l);
            try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), @intCast(ei));
            if (isNumericForLoopDoneGuard(t, ei)) {
                // [doc 30 §6 named coupling] Only emit the linked branch when the
                // snapshot walk can commit EVERY sunk store below the guard — a
                // range containing `sgm_setpos` (which the walk's closed inventory
                // does not commit) must never take the linked path. With the branch
                // unemitted this guard is mode-0-always: ordinary deopt, tier-0
                // replays the final iteration (replay-idempotent, sound). Tier-1a
                // declines through the same predicate in flushNumericForLoopDone.
                // Doc 39: a peeled trace never takes the linked-materialized path —
                // its snapshot walk has no notion of the run-once/steady split
                // (the φ snapshot would commit entry-class state). Mode-0-always:
                // ordinary deopt through `deopt_exit`, which carries the peeled
                // flush semantics.
                if (!t.peeled and t.loopDoneSnapshotSupported(ei)) {
                    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 0);
                    try a.jcc(.ne, try nativeLinkedLoopDoneLabel(a, linked_loop_done_labels, ei));
                }
                // mode 0 (ordinary loop-done deopt): bypass slot[ei] → `shared_exit`.
                if (shared_exit) |se| {
                    try a.movRegImm64(.rax, @bitCast(@as(u64, se)));
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                }
            } else if (shared_exit) |se| {
                if (isCompositeBridgeCandidate(t, ei)) {
                    // Part A-v: generic edge-4 bridge stub. The slot remains
                    // `shared_exit` throughout A-v, so execution always branches to
                    // `ordinary_mini`; the armed body is dead scaffolding until A-vii.
                    const ordinary_mini = try a.label();

                    // Stub head: unarmed slots take today's ordinary deopt path.
                    try a.movRegImm64(.rax, @bitCast(@as(u64, slotAddr(slots, ei).?)));
                    try a.movRegMem(.rax, .rax, 0);
                    try a.movRegImm64(.rcx, @bitCast(@as(u64, se)));
                    try a.cmpRegReg(.rax, .rcx);
                    try a.jcc(.e, ordinary_mini);

                    // Cap check FIRST, before any VM-state or result mutation beyond
                    // the legacy exit_instr write above. Reserve two ledger cells:
                    // this bridge receipt and the successor's terminal receipt.
                    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "ledger_len"));
                    try a.cmpRegImm32(.rax, @intCast(trace_exec.LEDGER_CAP - 2));
                    try a.jcc(.a, ordinary_mini);

                    try emitCompositeBridgeSnapshot(a, t, kinds, alloc, ei);
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
                    const silent = try a.label();
                    patch_emissions[ei] = .{ .kind = .region_bridge, .patch_off = a.code.items.len, .epilogue = silent };
                    try a.nop5();
                    try emitLedgerAppend(a, trace_id, .region_bridge);

                    // Re-resolve after the snapshot/append clobbered scratch regs,
                    // stage in the flush-immune result field, then hand off directly.
                    try a.movRegImm64(.rax, @bitCast(@as(u64, slotAddr(slots, ei).?)));
                    try a.movRegMem(.rax, .rax, 0);
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                    try a.jmpMem(.rdx, @offsetOf(NativeResult, "exit_target"));

                    // Shared fallback for BOTH unarmed and ledger-full cases. This is
                    // VM-state/output-equivalent to the pre-A-v mini-stub.
                    a.bind(ordinary_mini);
                    try a.movRegImm64(.rax, @bitCast(@as(u64, se)));
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                } else {
                    // Non-candidate ordinary guard: preserve the exact pre-A-v
                    // emission — resolve through its own slot (deref → stage).
                    try a.movRegImm64(.rax, @bitCast(@as(u64, slotAddr(slots, ei).?)));
                    try a.movRegMem(.rax, .rax, 0);
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                }
            }
            if (shared_exit != null and !isNumericForLoopDoneGuard(t, ei) and !isCompositeBridgeCandidate(t, ei)) {
                const silent = try a.label();
                patch_emissions[ei] = .{ .kind = .deopt, .patch_off = a.code.items.len, .epilogue = silent };
            }
            try a.jmp(deopt_exit);
        }
    }

    // LINKED_LOOP_DONE_EXIT: only used by `runLinkedLoopDone`. The ordinary native
    // side-exit path leaves the failing iteration for tier-0 replay; a native link
    // chain consumes the post-loop continuation instead, so it must commit the
    // post-guard stores and phi snapshot before returning.
    for (linked_loop_done_labels, 0..) |maybe_l, ei| {
        if (maybe_l) |l| {
            a.bind(l);
            try emitLinkedLoopDoneSnapshot(a, t, kinds, alloc, ei);
            try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
            if (shared_exit != null) {
                const silent = try a.label();
                patch_emissions[ei] = .{ .kind = .loop_done_linked, .patch_off = a.code.items.len, .epilogue = silent };
                try a.nop5();
            }
            // 2.3c-2a: record this loop-done transition (chain source I→C once 2.3c-2c
            // arms slot[ei]) before the handoff. `exit_instr` = ei was written into memory
            // by the mini-stub (its `jne` reached here); `exit_reason` is `.normal`.
            try emitLedgerAppend(a, trace_id, .loop_done_linked);
            // Chainable: the linked-loop-done stub commits the post-guard state, then
            // hands off through slot[ei] (default `shared_exit`, armed → continuation).
            try emitReturn(a, frame, callee[0..callee_len], shared_exit, trace_id, slotAddr(slots, ei));
        }
    }

    // DEOPT_EXIT: the single snapshot flush. Write each carried home back to regs[]
    // — invariant + write-only slots are already coherent. Then write `completed`
    // to the native result out-param and return.
    a.bind(deopt_exit);
    // Doc 39: a peeled trace that has completed ZERO local iterations must leave
    // regs[] untouched — the boxes still hold the int entry state, and tier-0
    // replays iterations 1–2 from the header in full int semantics (the
    // byte-identity core; mirrors irinterp's flush-only-at-`.loop` invariant).
    // The predicate is `rbx == entry_rbx`, NOT `rbx == 0`: rbx is
    // chain-cumulative, so a body entered through an armed link starts with
    // rbx > 0 and local completions are `rbx − entry_rbx`. rax is free here —
    // the mini-stubs staged `exit_target` in MEMORY precisely because this
    // flush block clobbers rax.
    var skip_flush: ?x64.Label = null;
    if (t.peeled) {
        const l = try a.label();
        try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "entry_rbx"));
        try a.cmpRegReg(.rbx, .rax);
        try a.jcc(.e, l);
        skip_flush = l;
    }
    for (alloc.slots) |s| {
        if (s.class != .carried) continue;
        // Boxed pass-through traces are one-shot. Before their terminal commit the
        // VM slot is still the entry Value byte-for-byte, so a guard exit must not
        // flush a typed approximation (or write anything at all).
        if (s.kind == .boxed) continue;
        // Re-box the carried home with its kind's tag: int homes write TAG_INT from a
        // GP reg / spill cell; a float home writes TAG_FLOAT + `movsd` from its XMM
        // (a register-homed float can't go through `movMemReg`). flushSlot dispatches.
        // Doc 39: a steady-φ slot re-boxes from the internal φ's computed home with
        // the STEADY kind — the entry home is stale after the run-once region.
        if (s.steady_phi >= 0) {
            try flushSlot(a, @as(i32, s.slot), s.steady_kind, placeOfRef(alloc, @intCast(s.steady_phi)));
        } else {
            try flushSlot(a, @as(i32, s.slot), s.kind, slotHomePlace(s));
        }
    }
    if (skip_flush) |l| a.bind(l);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    // 2.3c-2a: record this ordinary / loop-done-ordinary transition. The mini-stub wrote
    // `exit_instr` = ei into memory and staged `exit_target` (its own `slot[ei]`, which
    // 2.3c-1 can arm to a child, making THIS a chain source too); `exit_reason` is
    // `.normal`. The append clobbers rax/rcx but not the memory-staged `exit_target` the
    // dispatch below reads. Precedes the final_trace_id stamp — harmless, `t.id` is the
    // same value we pass as the ledger id.
    try emitLedgerAppend(a, trace_id, .deopt);
    // P-B: stamp the final trace id. `emitReturn` normally does this, but here the
    // dispatch target is the resolved value the mini-stub already staged into
    // `exit_target` (its own `slot[ei]`'s value, or `shared_exit` for a loop-done
    // ordinary exit), not a fixed address baked in this shared block — so inline the id
    // stamp + dispatch.
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    if (shared_exit) |se| {
        // 2.3c-0: frameless — dispatch through the memory-staged resolved target. The
        // mini-stub wrote `exit_target` BEFORE the flush ran, so the flush's rax clobber
        // (spilled-payload path) cannot destroy it. An unarmed ordinary `slot[ei]` holds
        // `shared_exit` (byte-identical to 2.1's direct jump); 2.3c-1 arms it to a child
        // body entry. 2.3c-2c: load the resolved target into rax and apply the forced-yield
        // cap (redirects an armed source-branch dispatch to `shared_exit` when the ledger is
        // full) before jumping.
        try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "exit_target"));
        try emitForcedYieldCheck(a, se);
        try a.jmpReg(.rax);
    } else {
        // Self-framed test page: no slot table, no shared trampoline — tear down the
        // per-trace frame and `ret` exactly as before (mini-stubs staged nothing here).
        try emitTeardown(a, frame, callee[0..callee_len]);
    }

    // PROLOGUE_FAIL: a hoisted type guard failed before this body committed any
    // iteration of its OWN loop. regs[] is untouched (the cut-1 EXIT would have
    // flushed half-initialized homes) and there is no per-body guard identity, so
    // `exit_instr = -1`. Not chainable outward (no child makes sense before the first
    // committed iteration), so it jumps straight to `shared_exit`.
    //
    // S3 (doc 17, 2.3b): write `completed = rbx`, NOT the literal 0. When this body
    // is entered fresh via the trampoline (`xor rbx,rbx`) — the only way it is
    // reached today, since nothing arms a link — rbx is provably 0 here (no `.loop`
    // back-edge `inc rbx` runs before the hoisted guards), so this is byte-identical
    // to the old `completed = 0`. Once a native parent `jmp`s into this body under
    // the shared frame (armed link, 2.3b), rbx already holds the PARENT's cumulative
    // iteration count; committing `rbx` here preserves that progress instead of
    // erasing it, so `completed = 0` at a chained child's entry-guard failure can no
    // longer wipe the chain's committed work. `movMemReg` is a full 64-bit store
    // (matching `deopt_exit`), so the `usize` field is fully written, not just its
    // low half.
    a.bind(prologue_fail);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), -1);
    // 2.3c-0b: stamp the reason so a consumer distinguishes THIS (native prologue-fail,
    // no local progress) from a tier-1a clean completion — both otherwise show
    // `exit_instr == maxInt`. Only this stub writes a non-`.normal` reason.
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(trace_exec.ExitReason.prologue_fail));
    // 2.3c-2a: record the prologue-fail as the terminal transition. `exit_instr` = -1 and
    // `exit_reason` = `.prologue_fail` are in memory; a chained child's entry-guard failure
    // after the parent committed thus shows up in the ledger with its own `trace_id` and
    // zero local progress. Terminal (jumps to `shared_exit`), so it is always the LAST
    // ledger entry — never a chain source, no cap needed.
    try emitLedgerAppend(a, trace_id, .prologue_fail);
    try emitReturn(a, frame, callee[0..callee_len], shared_exit, trace_id, null);

    // SEED DECLINE exits (doc 22 §B.2): the entry seed prologue's callout declined
    // before the body ran — cloned from `prologue_fail` above (same pre-commit
    // shape: `completed = rbx` preserves a fused predecessor's cumulative progress,
    // no guard identity so `exit_instr = -1`, reason stamped BEFORE the ledger
    // append so `emitLedgerAppend`'s memory reads see it, terminal so always the
    // LAST ledger entry — never a chain source, no cap needed). Two distinct
    // reasons because the consumers differ: a hash decline reruns THIS entry on
    // tier-1a (slab already holds the VM-seeding-equivalent state, including the
    // 0-bits cell slot); a capacity decline moves to the next candidate (nothing
    // was written). Present iff the seed prologue is (same `plan.nonEmpty()` gate).
    if (seed_hash_exit) |hash_l| {
        a.bind(hash_l);
        try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), -1);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(trace_exec.ExitReason.seed_hash_decline));
        try emitLedgerAppend(a, trace_id, .seed_hash_decline);
        try emitReturn(a, frame, callee[0..callee_len], shared_exit, trace_id, null);

        a.bind(seed_capacity_exit.?);
        try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), -1);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(trace_exec.ExitReason.seed_capacity_decline));
        try emitLedgerAppend(a, trace_id, .seed_capacity_decline);
        try emitReturn(a, frame, callee[0..callee_len], shared_exit, trace_id, null);
    }

    // B-3a: all silent epilogues live out of line in this same allocation. Their
    // metadata cells are null and no patch targets them yet, so they are unreachable
    // while the feature is off. Each kind's state materialization precedes its patch
    // point; ordinary deopt duplicates the shared carried-home flush here.
    if (shared_exit) |se| {
        for (patch_emissions, 0..) |maybe, ei| if (maybe) |em| {
            a.bind(em.epilogue);
            if (em.kind == .deopt) {
                // Doc 39: same zero-local-completion skip + steady-home flush as
                // the shared `deopt_exit` block above — this is its silent
                // duplicate and must stay semantically identical.
                var silent_skip: ?x64.Label = null;
                if (t.peeled) {
                    const l = try a.label();
                    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "entry_rbx"));
                    try a.cmpRegReg(.rbx, .rax);
                    try a.jcc(.e, l);
                    silent_skip = l;
                }
                for (alloc.slots) |s| {
                    if (s.class != .carried) continue;
                    if (s.kind == .boxed) continue;
                    if (s.steady_phi >= 0) {
                        try flushSlot(a, @as(i32, s.slot), s.steady_kind, placeOfRef(alloc, @intCast(s.steady_phi)));
                    } else {
                        try flushSlot(a, @as(i32, s.slot), s.kind, slotHomePlace(s));
                    }
                }
                if (silent_skip) |l| a.bind(l);
                try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
            }
            try emitSilentEpilogue(a, em.kind, &metadata_cells[ei], se, trace_id);
        };
    }

    // LINKED_ENTRY (doc 17, 2.3b-0): a secondary entry point for an armed native
    // `.link`-terminal handoff. A parent whose slot is armed into THIS trace targets
    // this stub instead of `body_entry` so a numeric-for loop-done inside this body
    // materializes in linked mode (commit the final iteration + phi snapshot, then
    // hand to its continuation) exactly as `runLinkedLoopDone` sets up. It presets
    // `linked_loop_done = 1` — `movMemImm32` is REX.W `C7 /0` (`mov qword …, imm32`,
    // sign-extended), so it stores the FULL u64 = 1, matching the reader
    // (`cmpQwordMemImm8 … , 0; jne`, a full-width nonzero test) — then falls through to
    // `body_entry` (which snapshots `entry_rbx` and runs the hoisted guards). Emitted
    // only on the frameless production path; self-framed test pages never chain, so
    // their `linked_entry` stays `null`. INERT until 2.3b-1 arms a slot to it.
    var stubs = EntryStubs{};
    // §B.4 record: the prologue was emitted iff its decline labels exist. Both
    // secondary entries below `jmp body_entry`, so a seeded page seeds on EVERY
    // entry kind — this bit is entry-kind-independent by construction.
    stubs.seed_prologue = seed_hash_exit != null;
    if (shared_exit != null) {
        const linked_entry = try a.label();
        a.bind(linked_entry);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 1);
        try a.jmp(body_entry);
        stubs.linked_entry = a.labelOffset(linked_entry);

        // ORDINARY_ENTRY (doc 17, 2.3c-0): the dual of `linked_entry`. Presets
        // `linked_loop_done = 0` then falls into `body_entry`. A fused handoff inherits
        // the shared `NativeResult.linked_loop_done`, which `linked_entry` may have left
        // at 1; the inner→continuation slot (2.3c-2) targets THIS entry so the
        // continuation runs in ordinary mode regardless of the flag it inherited.
        // `movMemImm32` is REX.W (`C7 /0`, sign-extended) → full u64 = 0, matching the
        // full-width reader. INERT until 2.3c-2 arms a slot to it.
        const ordinary_entry = try a.label();
        a.bind(ordinary_entry);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 0);
        try a.jmp(body_entry);
        stubs.ordinary_entry = a.labelOffset(ordinary_entry);
    }
    return stubs;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The test suite lives in sibling `*_test.zig` files (split by theme). Zig only
// analyses a file that is reachable by import, so this block is what makes them
// run under `zig build test`.

test {
    _ = @import("nativegen_core_test.zig");
    _ = @import("nativegen_float_test.zig");
    _ = @import("nativegen_lowering_test.zig");
    _ = @import("nativegen_arrayread_test.zig");
    _ = @import("nativegen_arraywrite_test.zig");
    _ = @import("nativegen_carriedheap_test.zig");
}
