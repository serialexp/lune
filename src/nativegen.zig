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
// doc 22 §A.1b: carried-heap roots and per-iteration table facts
//
// A *carried-heap* slot (class == .carried, kind == .heap) holds a table whose
// identity changes at every back-edge (`bi = b[i]`-shaped φ writeback). Any
// entry-time fact about that table — the seeded hash cell, the prologue's
// type/metatable/lane checks, a hoisted array base — describes only the FIRST
// iteration's table, so every table-rooted op on such a slot must use its
// dynamic in-body form (exactly the forms the `.heap`-kind aload roots already
// use). These predicates are the single decision point, shared by analysis
// (liveness, coalescing safety, save-area sizing) and lowering.

/// True iff `ref` is the slot_load of a carried-heap slot.
fn isCarriedHeapRoot(slots: []const SlotInfo, slot_id_of_ref: []const i32, ref: u16) bool {
    const sid = slot_id_of_ref[ref];
    if (sid < 0) return false;
    const s = slots[@intCast(sid)];
    return s.class == .carried and s.kind == .heap;
}

/// True iff a table-rooted op at `ref` cannot rely on entry-time facts: the root
/// is a per-iteration `.heap` value (VALUE_LANE aload result) or a carried-heap
/// slot. An href on such a root needs the `resolveHashCell` callout; its
/// guard_table/guard_hash need their dynamic in-body forms.
fn isDynTableRoot(kinds: []const Kind, slots: []const SlotInfo, slot_id_of_ref: []const i32, ref: u16) bool {
    return kinds[ref] == .heap or isCarriedHeapRoot(slots, slot_id_of_ref, ref);
}

/// Does lowering emit a mid-body side-exit for instruction `idx`? Home
/// coalescing must not order an in-place carried-home update before ANY of
/// these — the single-snapshot deopt flush would commit a partial iteration
/// (see the coalescing block in `analyzeInner`). This is the closed inventory
/// of every `jccNativeExit`/`jmpNativeExit` the body emitter can produce; when
/// adding a new side-exiting lowering, extend this switch in the same change.
///
/// [Rule #0.5] This replaces a hand-kept op list that had gone stale: it was
/// blind to the href-callout miss exit, the dynamic guard_table/guard_hash
/// forms, the VALUE_LANE aload heap-tag check, and the grid guards
/// guard_gcol/guard_gpresent — any of which, ordered after the last inventoried
/// guard, would have let a coalesced in-place update commit early.
fn opMayExitInBody(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
    idx: usize,
) bool {
    const ins = t.instrs[idx];
    return switch (ins.op) {
        .guard_true,
        .guard_false,
        .guard_bounds,
        .guard_present,
        .guard_absent,
        .guard_fits,
        .guard_append,
        .int_of_float,
        .ffloor,
        .fceil,
        .hload,
        // Doc 43 P5: uload tag-checks the cell per iteration and side-exits on
        // a type drift between entries — a body exit, exactly like hload.
        // (`uref` and `ustore` are exit-free: the cell is entry-proven and a
        // scalar overwrite cannot fail.)
        .uload,
        .guard_gcol,
        .guard_gpresent,
        .alen,
        // Doc 24: the budget guard exits when headroom is gone; the tostr and
        // snew callouts exit on a null return (OOM, or — snew — the collapsed
        // tier-0 raise: invalid codepoint / negative count).
        .guard_gc,
        .tostr_int,
        .tostr_num,
        .ssub,
        .srev,
        .schar1,
        .srep2,
        // Doc 26: the case producers exit on a null return (OOM); scp exits
        // on the −1 sentinel (empty range — tier-0 replays to nil).
        .supper,
        .slower,
        .scp,
        // Doc 30: the match callouts exit on a negative status (sfindp also
        // on 0 — matched index is ≥ 1); scap_str on null (OOM); str2num_* on
        // a kind mismatch / non-number; sgm_setpos on bad_layout; guard_sid
        // is a body identity guard. scap_int is the one exit-FREE member
        // (a baked scratch load) and is deliberately absent.
        .sfindp,
        .smatch,
        .sgmatch,
        .scap_str,
        .str2num_i,
        .str2num_f,
        .sgm_setpos,
        .guard_sid,
        => true,
        // Doc 25: only the INT lane exits (a zero divisor side-exits so
        // tier-0 raises DivisionByZero; the (minInt, -1) pair is computed
        // inline, NO exit). The float lane's fmath kernel is total.
        .mod, .idiv => ins.ty == .int,
        // A VALUE_LANE aload tag-checks TAG_HEAP and side-exits on mismatch;
        // scalar-lane aloads are exit-free (guard_present/guard_bounds dominate).
        .aload => ins.aux == VALUE_LANE,
        // The dynamic (per-iteration) table checks side-exit; the `.ptr` forms
        // are prologue-hoisted / seed-validated and emit nothing in the body.
        .guard_table => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        // doc 43 P3: a guard_lane on a `.heap`-kinded root (hload'd table
        // field) compares the lane byte per-iteration and side-exits on
        // mismatch; the `.ptr` form is prologue-hoisted and exit-free.
        .guard_lane => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        // doc 43 P2: a guard_func on a `.heap`-kinded hload (function field)
        // side-exits in the body; the `.func` callee-snapshot form is
        // prologue-hoisted and exit-free. Without this row, carried-home
        // coalescing could commit a resumable home before the identity check
        // and a failed method guard would deopt a partial iteration.
        .guard_func => kinds[ins.a] == .heap,
        // A dynamically-resolved href side-exits on callout miss (cell == 0).
        .href => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        .guard_hash => isDynTableRoot(kinds, slots, slot_id_of_ref, t.instrs[ins.a].a),
        else => false,
    };
}

// doc 22 §A.2 (HelperCaps), doc 24 D5 (the may_allocate/may_collect split): a
// heap φ keeps a raw `*GcHeader` in a register or spill cell across the whole
// body with no GC root. That is sound only while nothing in the body can
// trigger a COLLECTION — so every runtime helper the body may call out to is
// enumerated here with an explicit may-collect capability, and heap-φ
// admission refuses the trace if any callout could collect. Mere ALLOCATION
// (`tostr_*`) does not invalidate a φ-carried pointer: the GC is non-moving
// and allocation never collects in place (the single collect site is tier-0's
// dispatch prologue); its determinism cost is accounted by the `guard_gc`
// budget instead. A new callout MUST add a row (the exhaustive switch enforces
// it at compile time); claiming may_collect=false for a helper that can reach
// `Vm.collect` would be a soundness bug.

/// Every runtime helper a native body can call MID-ITERATION. The enum exists
/// solely to feed `calloutMayCollect`, i.e. to answer "can a heap φ be
/// invalidated across this call site", so membership is exactly "reachable from
/// `bodyCalloutOf`" — a variant no mapping ever returns is dead weight that
/// makes the GC audit look broader than it is.
///
/// Deliberately EXCLUDED, and why it needs no row: `NativeSeedCtx.seed_fn`
/// (doc 22 §B.2), the entry-prologue seeding callout that resolves
/// upvalue/global/hash-cell inputs into the trace's slab slots. It runs ONCE at
/// entry, before any heap φ is live, so it is outside this enum's question by
/// construction — not merely a `can_gc = false` answer to it. (For the record
/// it also allocates nothing: resolution and validation only — upvalue reads,
/// global-table lookups, hash-chain walks.)
const BodyCallout = enum {
    /// `resolveHashCell`: pure hash-chain walk over an existing table — reads
    /// the key, hashes, follows cells; allocates nothing.
    resolve_hash_cell,
    /// Full raw lookup, no mutation/allocation/collection.
    table_absent,
    /// `fmath.sinRuntime`: the shared noinline `math.sin` kernel (doc 23 D4) —
    /// a pure f64 → f64 function; allocates nothing.
    fsin,
    /// `fmath.cosRuntime`: likewise for `math.cos`.
    fcos,
    /// `fmath.floorRuntime` (doc 35): `@floor` + convert to i64; returns
    /// `FLOOR_CEIL_SENTINEL` on out-of-range/NaN/inf. Pure f64 → i64.
    ffloor,
    /// `fmath.ceilRuntime` (doc 35): likewise for `math.ceil`.
    fceil,
    /// `fmath.powRuntime`: the shared `^` kernel — pure (f64, f64) → f64;
    /// allocates nothing.
    fpow,
    /// `fmath.fmodRuntime` (doc 25): the shared float-`%` kernel
    /// (`x - floor(x/y)*y`) — pure (f64, f64) → f64, total (y == 0 → NaN);
    /// allocates nothing.
    fmod,
    /// `fmath.floordivRuntime` (doc 25): the shared float-`//` kernel
    /// (`floor(x/y)`) — pure (f64, f64) → f64, total; allocates nothing.
    ffloordiv,
    /// `stralloc.tostrIntRuntime` (doc 24): renders + interns an int's decimal
    /// string. **may_allocate = true** (at most ONE `Heap.link` per call — the
    /// D5 audit rule; an intern hit links zero), **may_collect = false**
    /// (allocation never collects in place — the ONLY collect site is the
    /// tier-0 dispatch prologue).
    tostr_int,
    /// `stralloc.tostrNumRuntime`: likewise for a float. Same
    /// may_allocate/may_collect split as `tostr_int`.
    tostr_num,
    /// `stralloc.ssubRuntime` (doc 24 c3): codepoint-range substring via the
    /// shared `subCore`. **may_allocate = true** (host scratch first, then at
    /// most ONE `Heap.link` at the final intern — the D5 audit rule; an intern
    /// hit links zero), **may_collect = false** (single collect site: tier-0's
    /// dispatch prologue).
    ssub,
    /// `stralloc.srevRuntime`: codepoint reversal via `reverseCore`. Same
    /// may_allocate/may_collect split as `ssub`.
    srev,
    /// `stralloc.schar1Runtime`: one-codepoint `string.char` via `char1Core`.
    /// Same split; an invalid codepoint returns null BEFORE any link.
    schar1,
    /// `stralloc.srep2Runtime`: separator-less `string.rep` via `rep2Core`.
    /// Same split; a negative/zero count resolves inside the core.
    srep2,
    /// `stralloc.supperRuntime` (doc 26): full-Unicode `string.upper` via the
    /// shared `caseCore`. **may_allocate = true** (host scratch first, then at
    /// most ONE `Heap.link` at the final intern — the D5 audit rule; an intern
    /// hit links zero), **may_collect = false** (single collect site: tier-0's
    /// dispatch prologue).
    supper,
    /// `stralloc.slowerRuntime`: likewise for `string.lower`. Same split.
    slower,
    /// `stralloc.scpRuntime` (doc 26): `string.codepoint` single-result read
    /// via the shared `codepointCore` — a pure (s, i, j) → i64 reader.
    /// Allocates NOTHING (the one non-allocating stralloc shim); −1 sentinel
    /// for the empty range (never a real codepoint — scalars are 0…0x10FFFF).
    scp,
    /// `stralloc.sfindpRuntime` (doc 30): plain-substring find — a pure
    /// (s, init, pat) → i64 reader. Allocates nothing, heap-free.
    sfindp,
    /// `stralloc.smatchRuntime` (doc 30): locate + scratch fill for
    /// find/match. Writes only the heap's `match_scratch` (host scratch,
    /// never GC state) — **may_allocate = false, may_collect = false**.
    smatch,
    /// `stralloc.sgmatchRuntime` (doc 30 §6): one composite gmatch-iterator
    /// step — READ-ONLY on the state table plus a `match_scratch` fill.
    /// Same non-allocating profile as `smatch`.
    sgmatch,
    /// `stralloc.scapStrRuntime` (doc 30): interns the span in a scratch
    /// slot. **may_allocate = true** (at most ONE `Heap.link` — the D5 audit
    /// rule; an intern hit links zero), **may_collect = false** (single
    /// collect site: tier-0's dispatch prologue).
    scap_str,
    /// `stralloc.str2numRuntime` (doc 30): `tonumber` on a string via the
    /// ONE `arith.toNumber` core — pure `*String` → {status, bits};
    /// allocates nothing.
    str2num,
    /// `stralloc.sgmSetposRuntime` (doc 30 §6): the deferred gmatch-cursor
    /// commit — one in-lane int-over-int cell write (no GC barrier needed);
    /// allocates nothing.
    sgm_setpos,
};

/// The doc-22 capability, renamed for the doc-24 may_allocate/may_collect
/// split: can this callout trigger a COLLECTION mid-body? That is the only
/// capability heap-φ admission cares about — the GC is non-moving and
/// allocation never collects in place (single collect site: tier-0's dispatch
/// prologue), so a callout that merely ALLOCATES (`tostr_*`) leaves every
/// φ-carried raw `*GcHeader` valid. Allocation capability is documented
/// per-row above and accounted by the `guard_gc` budget instead.
fn calloutMayCollect(c: BodyCallout) bool {
    return switch (c) {
        .resolve_hash_cell, .table_absent => false,
        .fsin, .fcos, .ffloor, .fceil, .fpow, .fmod, .ffloordiv => false,
        .tostr_int, .tostr_num => false,
        .ssub, .srev, .schar1, .srep2 => false,
        .supper, .slower, .scp => false,
        // Doc 30: the matchers/projection/parse/commit shims never reach
        // `Vm.collect` — scapStr's intern merely ALLOCATES (≤1 link, budgeted
        // by guard_gc); the rest touch only host scratch / one table cell.
        .sfindp, .smatch, .sgmatch, .scap_str, .str2num, .sgm_setpos => false,
    };
}

/// Which helper (if any) does instruction `idx` call out to in the body?
fn bodyCalloutOf(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
    idx: usize,
) ?BodyCallout {
    const ins = t.instrs[idx];
    return switch (ins.op) {
        .href => if (isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a)) .resolve_hash_cell else null,
        .guard_absent => .table_absent,
        .fsin => .fsin,
        .fcos => .fcos,
        .ffloor => .ffloor,
        .fceil => .fceil,
        .pow => .fpow,
        // doc 25: ONLY the float lane is a callout; the int lane lowers to
        // inline cqo/idiv (`emitIntDivMod`) with no callout save area.
        .mod => if (ins.ty == .float) .fmod else null,
        .idiv => if (ins.ty == .float) .ffloordiv else null,
        .tostr_int => .tostr_int,
        .tostr_num => .tostr_num,
        .ssub => .ssub,
        .srev => .srev,
        .schar1 => .schar1,
        .supper => .supper,
        .slower => .slower,
        .scp => .scp,
        .srep2 => .srep2,
        // Doc 30. scap_int is NOT here: it lowers to a baked absolute load,
        // no call, so it needs no save area and invalidates nothing.
        .sfindp => .sfindp,
        .smatch => .smatch,
        .sgmatch => .sgmatch,
        .scap_str => .scap_str,
        .str2num_i, .str2num_f => .str2num,
        .sgm_setpos => .sgm_setpos,
        else => null,
    };
}

/// Doc 22 §A.1b: compute the page's `SeedPlan` — which of `t.inputs` the
/// emitted body actually consumes at entry.
///
/// - `.upvalue` / `.global` seeds are always active: their slab slots are read
///   by ordinary `slot_load`s in the body.
/// - A `.hash_cell` seed is active iff some `href` names its slot (`aux ==
///   seed.slot`) AND that href's table root is *not* dynamic (`isDynTableRoot`
///   false). A dynamic-rooted href lowers to the per-iteration
///   `resolveHashCell` callout (aux forced to -1) and never reads the seeded
///   slab slot — seeding it would be dead work whose entry validation could
///   spuriously hash-decline the whole entry.
/// - `null` ⇒ compile bail (fail closed): more inputs than the 64-bit plan can
///   name. Real traces carry a handful; this is a structural bound, not a
///   tuning knob.
fn computeSeedPlan(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
) ?SeedPlan {
    if (t.inputs.len > 64) return null;
    var plan = SeedPlan{};
    for (t.inputs, 0..) |seed, i| {
        switch (seed.kind) {
            // Doc 43 P5: every `upvalue_cell` seed stays active — WRITER paths
            // feed `uref`'s slab load, and VERIFIER paths re-prove the alias
            // class at entry (deactivating one would skip that proof). A class
            // whose uref was DCE'd still validates (conservative: a failed
            // resolve declines an entry nothing would have read — matching
            // tier-1a's full-set resolution, and fail-closed).
            .upvalue, .global, .callee_upvalue, .callee_global, .upvalue_cell => plan.activate(i),
            .hash_cell => {
                for (t.instrs) |ins| {
                    if (ins.op != .href) continue;
                    if (ins.aux < 0) continue;
                    if (@as(u32, @intCast(ins.aux)) != seed.slot) continue;
                    if (!isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a)) {
                        plan.activate(i);
                        break;
                    }
                }
            },
        }
    }
    return plan;
}

// ---------------------------------------------------------------------------
// cut-2: register allocation + single-snapshot deopt — the analysis half
//
// `analyze` is a forward linear-scan over the linear SSA that (a) classifies each
// tier-0 slot the trace touches, (b) computes per-ref liveness, and (c) assigns
// every value a `Loc` (a CPU register or a frame spill slot). It is *pure analysis*:
// `lower` consumes its output in later commits. Landed first as a measured no-op so
// the risky logic rides under the existing differential oracle.
// ---------------------------------------------------------------------------

/// Where a value lives during the loop body.
const Loc = union(enum) {
    reg: Reg, // a general-purpose register (int/bool/ptr/aref)
    xmm: Reg, // an XMM register (float) — same 0..15 index space, disjoint pool
    spill: u32, // frame slot index; byte displacement = index * 8 (kind-agnostic 8-B cell)
};

/// How a slot participates in the loop, deciding its prologue/back-edge/EXIT handling.
pub const SlotClass = enum {
    /// slot_loaded AND in exit_stores: read+write loop-carried. Gets a home; flushed
    /// to regs[] on a side-exit; reassigned at the back-edge shuffle.
    carried,
    /// slot_loaded, NOT in exit_stores: read-only, loop-invariant. Loaded once into a
    /// home; never written back (untouched ⇒ coherent).
    invariant,
    /// in exit_stores, NOT slot_loaded (e.g. `flag = i<limit`). No home; committed to
    /// regs[] at the back-edge (cut-1 style); never touched at EXIT.
    write_only,
};

/// Compile-time facts about one tier-0 slot.
const SlotInfo = struct {
    slot: u16,
    class: SlotClass,
    kind: Kind, // box tag at commit/flush (int/ptr for carried/invariant; store_ref's for write_only)
    home: Loc, // valid for carried/invariant
    load_ref: i32, // the slot_load ref, or -1
    store_ref: i32, // the exit_store ref feeding it, or -1
    /// For a `.ptr` (table) invariant slot: the bool-lane ordinal its `guard_lane`
    /// pins, checked once in the prologue. `-1` for non-`.ptr` slots.
    lane: i32,
    /// For a `.func` (cross-frame callee snapshot) invariant slot: the recorded
    /// `Proto.id` its covering `guard_func` pins, checked once in the prologue
    /// (closure type + this id). Unused (0) for non-`.func` slots.
    func_id: u32 = 0,
    /// For a `.native` (pure-builtin callee snapshot) invariant slot: the recorded
    /// `RecordedBuiltin` ordinal its covering `guard_builtin` pins, checked once in the
    /// prologue (native type + this tag's payload byte + the non-null flag). `-1` for
    /// non-`.native` slots.
    recorded_tag: i32 = -1,
    /// For a `.ptr` table accessed as a GRID (doc 14): the `grid_elem` lane ordinal
    /// (an int lane) its covering `guard_grid` pins and the `stride` its
    /// `guard_stride` pins, both checked once in the prologue (`array.grid_elem ==
    /// grid_elem ∧ array.stride == grid_stride`; `s.lane` is set to `GRID_LANE` so
    /// the shared lane check verifies `array.lane == .grid`). `-1` when the slot is
    /// not a grid table. `grid_stride` is also the folded immediate `gcell` uses for
    /// its `row*stride` multiply — sound because the prologue proved it equals the
    /// runtime stride and no traced store grows it (the recorder aborts a grow).
    grid_elem: i32 = -1,
    grid_stride: i32 = -1,
    /// doc 24 c3: an invariant `.heap` slot pinned by a covering `guard_string`
    /// (an observed-string input to the snew ops / `slen`). The prologue verifies
    /// `header.type == string` once — the slot is read-only in the trace (a
    /// carried string bails in classification), so the pin holds for the whole
    /// native run. `false` for every other slot.
    is_string: bool = false,
    /// win 2: the store_ref transient was allocated *into* home, so the op updates the
    /// home in place and the back-edge shuffle move for this slot self-elides. Only set
    /// for `carried` slots passing the safety predicate (see `analyzeInner`).
    coalesced: bool,
    /// Doc 39 (peeled trace): the ref of this slot's INTERNAL (steady-state) φ —
    /// the slot-bound φ's `a` association stamped by the recorder — or -1. When
    /// >= 0 the slot's post-run-once value lives in that φ's computed home, not in
    /// `home`: `home` holds the ENTRY value (iteration 1's class, used only by the
    /// run-once region), the back-edge shuffle skips the slot home entirely (the
    /// internal-φ move carries the value; the home's register class may not even
    /// match the steady kind), and every deopt flush re-boxes from the steady
    /// home with `steady_kind`. Only ever set for `t.peeled` traces.
    steady_phi: i32 = -1,
    /// Kind of the steady-state value (`kinds[steady_phi]`); equals `kind` for a
    /// type-stable carried slot, differs (int entry → float steady) for a widened
    /// one. `.none` when `steady_phi < 0`.
    steady_kind: Kind = .none,
    /// Phase 2 (invariant array-base hoisting): for a `.ptr` slot used as an
    /// `aref.a`, the loop-invariant array base pointers / length, materialized ONCE
    /// in the prologue into a dedicated register and reused across every iteration
    /// (instead of re-loading `[tbreg+field]` each time). `null` ⇒ not hoisted (no
    /// free register, or the field is unused) and the body keeps the per-iteration
    /// load — correctness never depends on seating. Valid for the whole native run
    /// by the B5 invariant: the read/write path never reallocates or lane-widens the
    /// array (`guard_fits` side-exits first). Pure invariant scratch — never written
    /// back to `regs[]` on exit.
    data_home: ?Reg = null, // [array_base + data]  (element pointer)
    present_home: ?Reg = null, // [array_base + present] (int-lane presence bitmap ptr)
    len_home: ?Reg = null, // [array_base + asize]   (slot count / bounds limit, for guard_bounds)
};

/// The allocator's output — the sole input `lower` needs (later commits).
pub const Alloc = struct {
    loc: []Loc, // [n] location of each ref's value (slot_load refs resolve to their home)
    last_use: []u32, // [n] index of the last instruction reading each ref
    slot_id_of_ref: []i32, // [n] slots[] index for a slot_load ref, else -1
    slots: []SlotInfo,
    spill_count: u32, // frame slots used (homes + transients); frame = spill_count*8
    used_callee_saved: u16, // bitmask of callee-saved GPRs used (must be push/pop'd)

    // --- callout save area (Phase 2, .value-lane href) ---
    // When a trace contains a .heap-rooted href (per-iteration hash-cell
    // resolution via `resolveHashCell`), the callout clobbers all SysV
    // caller-saved registers. Live homes in those registers must be saved
    // to the frame before the call and restored after. These fields describe
    // the save area appended to the spill region (slots callout_save_base ..
    // callout_save_base + callout_save_count - 1).
    callout_save_base: u32 = 0, // first spill-slot index of save area
    callout_save_count: u32 = 0, // number of 8-byte slots reserved

    // --- rdx park slot for the inline int mod/idiv lowering (doc 25 D1) ---
    // `idiv` clobbers rdx:rax unconditionally and rdx carries the live
    // `*NativeResult` all body long, so `emitIntDivMod` parks rdx here for
    // the duration of the instruction. An allocator-OWNED unique spill slot
    // (codex medium): consumed from `spill_count` wholly outside the callout
    // save region — never its alignment-padding slot — so it can't alias a
    // spilled operand or the callout's own saved rdx. Addressed `div_save*8`.
    div_save: ?u32 = null,

    pub fn deinit(self: *Alloc, gpa: std.mem.Allocator) void {
        gpa.free(self.loc);
        gpa.free(self.last_use);
        gpa.free(self.slot_id_of_ref);
        gpa.free(self.slots);
        self.* = undefined;
    }
};

/// 1<<reg as a 16-bit register-set bit.
pub fn regBit(r: Reg) u16 {
    return @as(u16, 1) << @intFromEnum(r);
}

/// Allocatable GPRs, in preference order: caller-saved first (no prologue save), then
/// callee-saved (push/pop'd). Excludes rax/rcx (scratch), rbx (completed), rsp, rdi
/// (tags base), rsi (payloads base), and rdx (native result out-param).
const ALLOC_ORDER = [_]Reg{ .r8, .r9, .r10, .r11, .rbp, .r12, .r13, .r14, .r15 };
const CALLEE_SAVED_MASK: u16 = regBit(.rbp) | regBit(.r12) | regBit(.r13) | regBit(.r14) | regBit(.r15);

/// Preference order for Phase-2 invariant array-base homes: `ALLOC_ORDER` reversed,
/// so base pointers claim the callee-saved tail (r15…r12, rbp) the body's linear
/// scan only reaches under register pressure. A low-pressure trace (e.g. nsieve)
/// therefore hoists its array bases without displacing any hot transient into a
/// spill; a high-pressure one simply leaves a base un-hoisted (per-iter load).
const BASE_HOME_ORDER = [_]Reg{ .r15, .r14, .r13, .r12, .rbp, .r11, .r10, .r9, .r8 };

/// Allocatable XMM registers (Phase D float homes/transients). xmm0/xmm1 are the
/// float scratch pair (the SSE analogue of rax/rcx) — never allocated; xmm2..xmm15
/// are the pool. On the SysV/Linux ABI every XMM is *caller-saved*, so a float home
/// needs no prologue save (the `fn([*]Value) callconv(.c)` target owns them all) —
/// hence no XMM analogue of `CALLEE_SAVED_MASK`. The `Reg` indices are reused for
/// XMM (same 0..15 ModRM/REX bits); a `Loc.xmm`/`Place.xmm` tag keeps them disjoint
/// from the identically-indexed GP registers.
const XMM_ALLOC_ORDER = [_]Reg{
    x64.xmm2,  x64.xmm3,  x64.xmm4,  x64.xmm5,  x64.xmm6,  x64.xmm7,
    x64.xmm8,  x64.xmm9,  x64.xmm10, x64.xmm11, x64.xmm12, x64.xmm13,
    x64.xmm14, x64.xmm15,
};
/// The float scratch pair (analogue of rax/rcx), reserved out of the pool above.
const XMM_SCRATCH0: Reg = x64.xmm0;
const XMM_SCRATCH1: Reg = x64.xmm1;

const AnalyzeError = std.mem.Allocator.Error || error{
    /// cut-2 cannot represent this trace (type-instability, etc.). The caller bails;
    /// the cut-1 stack-slot path (or tier-1a) handles it correctly.
    Bail,
};

/// True iff `op` produces a register-resident value that gets its own location (i.e. a
/// transient: konst / arithmetic / compare). slot_loads resolve to a slot home; guards
/// and the loop marker produce no value.
fn isTransient(op: trace_ir.IrOp) bool {
    return switch (op) {
        .konst, .add, .sub, .mul, .div, .band, .bor, .bxor, .shl, .shr, .sar, .neg, .bnot, .eq, .ne, .lt, .le => true,
        // aref materializes idx0 in a register; aload materializes the decoded bool.
        .aref, .aload => true,
        // int_of_float materializes the converted int limit in a register; alen
        // the border int.
        .int_of_float, .ffloor, .fceil, .alen => true,
        // fsqrt materializes the `@sqrt` result in a float home (XMM/spill);
        // fsin/fcos/pow materialize their `fmath` kernel callout's result
        // likewise.
        .fsqrt, .fsin, .fcos, .pow => true,
        // doc 25: int mod/idiv materialize the floor-adjusted idiv result in
        // a GP home; the float lane its fmath kernel callout result in a
        // float home.
        .mod, .idiv => true,
        // doc 24: tostr_* materialize the interned `*GcHeader` in a GP home;
        // slen the cp_len int. The snew class (c3) likewise materializes its
        // fresh-or-interned `*GcHeader` result in a GP home.
        .tostr_int, .tostr_num, .slen, .ssub, .srev, .schar1, .srep2 => true,
        // doc 26: the case producers materialize their `*GcHeader` in a GP
        // home like the snew class; scp its scalar codepoint int.
        .supper, .slower, .scp => true,
        // doc 30: the match/parse class materialize their status / index /
        // scratch word / `*GcHeader` / parsed number in a home. sgm_setpos
        // and guard_sid are value-less effects/guards — NOT here.
        .sfindp, .smatch, .sgmatch, .scap_int, .scap_str, .str2num_i, .str2num_f => true,
        // href materializes the seeded cell pointer in a register (like aref); hload
        // materializes the decoded scalar field value. hstore/guard_hash are effects.
        // Doc 43 P5: uref/uload are their closed-upvalue-cell twins (uref the
        // seeded cell pointer, uload the decoded scalar); ustore is an effect.
        .href, .hload, .uref, .uload => true,
        // grid (doc 14): garow materializes the row base (row0, like aref), gcell the
        // flat cell index, gload the decoded int cell. gstore/the grid guards are
        // effects/value-less.
        .garow, .gcell, .gload => true,
        else => false,
    };
}

/// True iff the op's two operands may be swapped without changing the result. Used
/// both for operand coalescing (either operand's dying register may be reused) and to
/// let the ALU emitter avoid a staging move when the in-register operand is `b`.
fn isCommutative(op: trace_ir.IrOp) bool {
    return switch (op) {
        .add, .mul, .band, .bor, .bxor, .eq, .ne => true,
        else => false, // sub, lt, le are order-sensitive
    };
}

// operandReads lives in nativegen_prove.zig (file-split pass); aliased below.

/// Whether two `Loc`s name the same physical home (register or spill slot).
fn locEql(x: Loc, y: Loc) bool {
    return Place.eql(locToPlace(x), locToPlace(y));
}

/// Ops whose result can be computed *into* a destination home in place (win 2). A
/// compare result is Bool, never carried (type-stability bails), and konst has no
/// operand to anchor the home — so only arithmetic/bitwise + unary qualify.
/// [doc 30 c4b] Ops whose result is BY CONSTRUCTION an interned `*String` —
/// the `is_string[i] = true` PRODUCER arms of proveKinds Pass B (tostr/snew/
/// case/scap_str classes; NOT the guard-derived sources: a string-guarded
/// slot_load or string konst proves only its own value, not a writeback).
/// Used by the carried-string classification arm: a slot may carry a `.heap`
/// value across iterations only when the φ writeback is one of these. Keep
/// this list a SUBSET of proveKinds' producer set — a missing op merely bails
/// a compilable trace (fail closed); an op here that proveKinds does not
/// treat as a string would be type confusion in the body's static string
/// facts (`slen`, snew operands).
fn isStringProducerOp(op: trace_ir.IrOp) bool {
    return switch (op) {
        .tostr_int, .tostr_num, .ssub, .srev, .schar1, .srep2, .supper, .slower, .scap_str => true,
        else => false,
    };
}

fn isCoalescibleOp(op: trace_ir.IrOp) bool {
    return switch (op) {
        .add, .sub, .mul, .band, .bor, .bxor, .neg, .bnot => true,
        else => false,
    };
}

/// Find a slot in the list or append a fresh (unclassified) entry; returns its index.
fn findOrAddSlot(slots: *std.ArrayListUnmanaged(SlotInfo), gpa: std.mem.Allocator, slot: u16) !usize {
    for (slots.items, 0..) |s, id| {
        if (s.slot == slot) return id;
    }
    try slots.append(gpa, .{
        .slot = slot,
        .class = undefined,
        .kind = .none,
        .home = undefined,
        .load_ref = -1,
        .store_ref = -1,
        .lane = -1,
        .coalesced = false,
    });
    return slots.items.len - 1;
}

/// See module header. Returns `null` to bail (cut-2 cannot compile this trace); the
/// caller falls back. Runs only on a `proveKinds`-accepted trace, so every op is in the
/// supported subset and `kinds`/`slot_of` are filled.
pub fn analyze(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) ?Alloc {
    return analyzeInner(gpa, t, kinds, slot_of) catch |e| switch (e) {
        error.Bail, error.OutOfMemory => null,
    };
}

fn analyzeInner(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) AnalyzeError!Alloc {
    const n = t.instrs.len;

    // Phase E1/E2: the preheader marker (if any) splits the trace into a run-once
    // region (index < marker) and the per-iteration body. Run-once value refs and
    // every internal φ get a *computed home* — a register/spill held across the whole
    // loop, written once in the prologue (an internal φ also updates at the back-edge),
    // and NEVER flushed at deopt (they back no tier-0 slot; tier-0 recomputes on replay).
    var marker_idx: ?usize = null;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .preheader) {
            marker_idx = i;
            break;
        }
    }

    var slots: std.ArrayListUnmanaged(SlotInfo) = .empty;
    errdefer slots.deinit(gpa);

    const slot_id_of_ref = try gpa.alloc(i32, n);
    errdefer gpa.free(slot_id_of_ref);
    @memset(slot_id_of_ref, -1);

    // --- classification: gather slot_loads, then slot-bound φ writebacks ---
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        const slot: u16 = @intCast(slot_of[i]); // validated >= 0 in proveKinds
        const id = try findOrAddSlot(&slots, gpa, slot);
        slots.items[id].load_ref = @intCast(i);
        slot_id_of_ref[i] = @intCast(id);
    }
    // A slot-bound φ (aux >= 0) is the loop-carried writeback the old exit_store was:
    // `aux` is the tier-0 slot, `b` is the body value carried to the next iteration.
    // Internal φs (aux == PHI_INTERNAL) back no slot — they get a computed home in a
    // later phase, not a slot class here.
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const id = try findOrAddSlot(&slots, gpa, @intCast(ins.aux));
        slots.items[id].store_ref = ins.b;
    }
    for (slots.items) |*s| {
        const loaded = s.load_ref >= 0;
        const stored = s.store_ref >= 0;
        if (loaded and stored and t.instrs[n - 1].op == .terminal) {
            // A one-shot root never feeds its snapshot back into its own
            // prologue. Keep the entry home immutable, independently of the
            // outgoing value's kind. Terminal lowering reads store_ref and
            // boxes that value separately; failed guards leave entry regs intact.
            s.class = .invariant;
            s.kind = kinds[@intCast(s.load_ref)];
        } else if (loaded and stored) {
            s.class = .carried;
            // A carried slot is treated as ONE boxable scalar kind end-to-end: the
            // prologue tag-checks it, the body keeps it in a same-class home, and the
            // deopt flush re-boxes it with that tag. Phase D widens the admissible set
            // from int to {int, float}; bool/ptr/aref carried still bail.
            const lk = kinds[@intCast(s.load_ref)];
            const sk = kinds[@intCast(s.store_ref)];
            if (lk == .ptr and (sk == .ptr or sk == .heap)) {
                // [doc 22 §A.1] Carried-heap: a guard_table-covered table slot whose φ
                // writeback is itself a table (`bi = b[i]` — a VALUE_LANE aload result,
                // or another table slot_load). The slot's kind becomes `.heap`, NOT
                // `.ptr`: every `.ptr`-keyed analysis and prologue hoist (lane/grid
                // pinning, C2 type+metatable checks, array-base homes) then skips it by
                // kind mismatch, because those entry-time facts describe only the first
                // iteration's table. The home is a GP register/spill holding the current
                // `*GcHeader`, refreshed by the back-edge φ shuffle; in-body table facts
                // come from the DYNAMIC forms (per-iteration guard_table/guard_hash, the
                // resolveHashCell href callout) via `isCarriedHeapRoot`, and both the
                // entry tag-check and every flush use TAG_HEAP. Structural bails below
                // refuse anything this cut cannot check per-iteration (array/grid roots).
                s.kind = .heap;
            } else if (lk == .heap and sk == .heap) {
                // [doc 30 c4b] Carried STRING: a `guard_string`-covered slot whose φ
                // writeback is a STATIC string producer — the gmatch for-in's loop
                // variable, where each iteration's `w` is the fresh `scap_str`
                // result. Soundness is split across the iterations exactly like
                // carried-heap tables, but with a STRONGER entry pin and a STRONGER
                // writeback proof, because the body's string facts (`slen`, snew
                // operands) are static — there are no per-iteration dynamic guards
                // to fall back on:
                //   * iteration 1 (the entry value): `is_string` makes the prologue
                //     keep the FULL guard_string pin — the [RV-1] TAG_HEAP tag-lane
                //     check plus `header.type == string`;
                //   * iterations 2+ (the carried value): the writeback must be a
                //     producer whose result is a `*String` by construction
                //     (`isStringProducerOp`), so string-ness holds with no check.
                // The home is a GP register/spill holding the current `*GcHeader`,
                // refreshed by the back-edge φ shuffle; every flush uses TAG_HEAP
                // (heap boxing is type-agnostic — the type lives in the header).
                // The [doc 22 §A.2] GC-admission sweep below already covers this
                // slot (keyed on kind `.heap`, any class), and the structural bails
                // refuse any table-shaped op rooted at it. An unpinned `.heap` load
                // or a non-producer writeback (e.g. a `.ptr` table masquerading
                // through kind `.heap`) fails closed.
                const lref: u16 = @intCast(s.load_ref);
                var pinned = false;
                for (t.instrs) |g| {
                    if (g.op == .guard_string and g.a == lref) {
                        pinned = true;
                        break;
                    }
                }
                if (!pinned) return error.Bail;
                if (!isStringProducerOp(t.instrs[@intCast(s.store_ref)].op)) return error.Bail;
                s.kind = .heap;
                s.is_string = true;
            } else if (lk == .boxed and sk == .boxed) {
                // One-shot boxed pass-through: the payload home is raw bits and
                // terminal writeback copies the tag lane separately. It is never
                // inspected or loop-carried (proveKinds gates both properties).
                s.kind = .boxed;
            } else {
                // [RV-4 / review P0] The *load* class fixes the prologue tag-check and the
                // home's register class. Outside the carried-heap and carried-string
                // cases above, a `.ptr` load carried would skip the table/lane checks
                // and reinterpret an int/float payload as a `*GcHeader` → type
                // confusion; only a boxable scalar may be carried.
                if (lk != .int and lk != .float) return error.Bail;
                // [RV-3] type-stability: the store class must match the load class in a
                // `.loop` trace. A slot loaded int but stored float (or vice versa)
                // would pass the once-hoisted prologue guard forever while the oracle
                // re-checks every iteration and deopts — and the home's register class
                // (GP vs XMM) would be wrong.
                //
                // doc 34: `.link` traces are exempt. Their phis write to `regs[]` and
                // then control transfers to a DIFFERENT trace (the link target) with
                // its own prologue and guards. The type of the phi writeback is
                // re-checked by the receiving trace's prologue, so type instability
                // between load and store is safe — the link trace never loops back
                // into its own body. The deopt flush re-boxes the value with whatever
                // tag it actually has, which is correct. The slot's home class follows
                // the LOAD type (the prologue pin). The `.link` terminal flush
                // (below) tags the store value with its own kind, not the slot's.
                if (sk != lk) {
                    if ((t.instrs[n - 1].op == .link or t.instrs[n - 1].op == .terminal) and isNumKind(lk) and isNumKind(sk)) {
                        // Accept: the slot homes as the load class; the φ writeback
                        // converts at the one-shot flush. Doc 44: a `.terminal`
                        // head close shares `.link`'s exemption verbatim — it
                        // never loops back into its own body either, and tier-0
                        // re-checks types at the resume pc.
                    } else if (t.peeled and isNumKind(lk) and isNumKind(sk)) {
                        // Doc 39: a peeled trace's widened carried slot (int entry,
                        // float steady state). Accepted iff the peeled post-pass
                        // below finds the slot-bound φ's steady-φ association —
                        // the entry home keeps the load class (the prologue keeps
                        // demanding TAG_INT, which is what fresh instances
                        // present); the steady value lives in the internal φ's
                        // computed home and every flush re-boxes from there.
                    } else {
                        return error.Bail;
                    }
                }
                s.kind = lk;
            }
        } else if (loaded) {
            s.class = .invariant;
            // int OR ptr (a guard_table-covered table slot, read-only loop-invariant).
            s.kind = kinds[@intCast(s.load_ref)];
        } else {
            s.class = .write_only;
            s.kind = kinds[@intCast(s.store_ref)];
        }
    }
    // Doc 39: peeled-trace steady-φ association. For every carried slot of a
    // peeled trace, connect the slot to its internal (steady-state) φ via the
    // slot-bound φ's `a` field (stamped by the recorder at commit;
    // assertWellFormed pins that a nonzero `a` points at a PHI_INTERNAL φ).
    // Post-run-once, the slot's live value rides that φ's computed home — the
    // entry home is DEAD after iteration 1 (all slot_load uses are in the
    // run-once region), so the back-edge shuffle skips it and the deopt flush
    // reads the steady home instead. Fail-closed rules:
    //   * widened slot (store kind ≠ load kind) with NO steady φ → Bail: the
    //     back-edge move into the load-class home would be class-mismatched and
    //     the flush tag wrong. (`a == 0` means the body pass never read the
    //     slot before writing it — a shape v1 does not home.)
    //   * steady φ present but its kind ≠ the store kind → Bail (malformed).
    //   * scalar carried only: the carried-heap/carried-string classes keep
    //     their own machinery (their per-iteration facts are body-anchored) —
    //     v1 refuses them in a peeled trace rather than reasoning about their
    //     run-once/steady split.
    if (t.peeled) {
        for (slots.items) |*s| {
            if (s.class != .carried) continue;
            if (s.kind == .heap or s.kind == .ptr) return error.Bail;
            const sk = kinds[@intCast(s.store_ref)];
            // Find this slot's slot-bound φ and read its steady association.
            var steady: i32 = -1;
            for (t.instrs) |p| {
                if (p.op == .phi and p.aux >= 0 and @as(u16, @intCast(p.aux)) == s.slot) {
                    if (p.a != 0) steady = @intCast(p.a);
                    break;
                }
            }
            if (steady >= 0) {
                if (kinds[@intCast(steady)] != sk) return error.Bail;
                s.steady_phi = steady;
                s.steady_kind = sk;
            } else if (sk != s.kind) {
                return error.Bail; // widened but write-only-in-body: no steady home
            }
        }
    }

    // [doc 22 §A.1, fail closed] Structural bails for carried-heap slots. The
    // `.ptr`-keyed lane/grid analyses below skip a carried-heap slot by kind
    // mismatch — which means an aref/garow rooted at one would otherwise compile
    // SILENTLY with no lane pin and a first-iteration-only base. Refuse instead:
    // this cut supports exactly the hash-path ops (href/guard_table/guard_hash),
    // whose dynamic in-body forms re-check the CURRENT table each iteration. And
    // those dynamic forms are only per-iteration if they sit in the body — a
    // placement before the preheader marker would run once, checking iteration
    // 1's table only, so that too is refused.
    for (slots.items) |s| {
        if (s.class != .carried or s.kind != .heap) continue;
        const lr: u16 = @intCast(s.load_ref);
        const ms: usize = marker_idx orelse 0;
        for (t.instrs, 0..) |g, gi| {
            switch (g.op) {
                // No entry-hoisted per-table fact may root at a per-iteration table.
                .aref, .garow, .guard_lane, .guard_grid, .guard_stride => {
                    if (g.a == lr) return error.Bail;
                },
                .guard_table, .href => if (g.a == lr and gi < ms) return error.Bail,
                .guard_hash => if (t.instrs[g.a].a == lr and gi < ms) return error.Bail,
                else => {},
            }
        }
    }
    // [doc 22 §A.2] Heap-φ GC admission: a `.heap`-kind slot (carried OR
    // write-only) keeps a raw `*GcHeader` unrooted in a register/spill across the
    // body, sound only while no body callout can trigger a collection. Check every
    // callout against the HelperCaps table; refuse the trace if any may GC.
    {
        var has_heap_phi = false;
        for (slots.items) |s| {
            if (s.kind == .heap) {
                has_heap_phi = true;
                break;
            }
        }
        if (has_heap_phi) {
            for (0..n) |ci| {
                if (bodyCalloutOf(t, kinds, slots.items, slot_id_of_ref, ci)) |c| {
                    if (calloutMayCollect(c)) return error.Bail;
                }
            }
        }
    }
    // A `.ptr` (table) invariant slot accessed as an ARRAY needs the lane its
    // `guard_lane` pins, so the prologue can check it once. Locate the guard_lane
    // covering the slot_load. A table accessed only via the HASH part (H1: `href`,
    // no `aref`) carries no array lane — the recorder emits `guard_table` but no
    // `guard_lane` — so `s.lane` stays -1 and the prologue skips the lane check (the
    // data/present/len array-base hoist is likewise keyed on aref usage, so a
    // hash-only slot gets none). A table used BOTH ways has the guard_lane and is
    // pinned normally. The table-type + metatable prologue checks cover the hash
    // path's validity regardless of lane.
    for (slots.items) |*s| {
        if (s.kind != .ptr) continue;
        if (s.class == .write_only) continue;
        const lr: u16 = @intCast(s.load_ref);
        // An aref on this slot REQUIRES a guard_lane (the recorder always emits both);
        // a malformed trace with array access but no lane would miscompile, so track it.
        var has_aref = false;
        for (t.instrs) |g| {
            if (g.op == .aref and g.a == lr) has_aref = true;
            if (g.op == .guard_lane and g.a == lr) s.lane = g.aux;
        }
        if (has_aref and s.lane < 0) return error.Bail; // array access without a pinned lane
    }
    // A `.ptr` table accessed as a GRID (doc 14) carries no `guard_lane`; instead a
    // `guard_grid` pins `lane == .grid ∧ grid_elem` and a `guard_stride` pins the row
    // width. Tag the slot with the meta-lane GRID_LANE plus the recorded grid_elem and
    // stride so the prologue can verify all three once per entry. A table is a grid OR
    // a scalar array at any instant — never both — so a slot already carrying a scalar
    // lane (set above) here is malformed; bail rather than miscompile.
    for (slots.items) |*s| {
        if (s.kind != .ptr) continue;
        if (s.class == .write_only) continue;
        const lr: u16 = @intCast(s.load_ref);
        var has_garow = false;
        var ge: i32 = -1;
        var gs: i32 = -1;
        for (t.instrs) |g| {
            if (g.op == .garow and g.a == lr) has_garow = true;
            if (g.op == .guard_grid and g.a == lr) ge = g.aux;
            if (g.op == .guard_stride and g.a == lr) gs = g.aux;
        }
        if (!has_garow) continue;
        if (s.lane >= 0 or ge < 0 or gs < 0) return error.Bail;
        s.lane = GRID_LANE;
        s.grid_elem = ge;
        s.grid_stride = gs;
    }
    // A `.func` (cross-frame callee snapshot) invariant slot carries the recorded
    // `Proto.id` from its covering `guard_func`, checked once in the prologue (the
    // upvalue/global cell is re-resolved + re-seeded each entry, so it cannot change
    // within a native run). Locate the guard_func and stash its id on the slot.
    for (slots.items) |*s| {
        if (s.kind != .func) continue;
        // Doc 44: a WRITE-ONLY `.func` slot (a head trace's φ writeback of the
        // callee closure into the child frame) is never prologue-checked — the
        // guard_func covers the LOADED snapshot slot, and the flush re-boxes
        // the already-verified pointer. No id to stash.
        if (s.load_ref < 0) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_func and g.a == lr) {
                if (found and @as(u32, @bitCast(g.aux)) != s.func_id) {
                    // Two guard_funcs on one snapshot with *different* recorded ids:
                    // the prologue checks one id, but the oracle re-checks each and
                    // would side-exit on the second — a divergence. The recorder never
                    // emits this (dedup → one synthetic slot → one resolved closure →
                    // one id), so it can only arise malformed. Bail, don't miscompile.
                    return error.Bail;
                }
                s.func_id = @bitCast(g.aux);
                found = true;
            }
        }
        // proveKinds only set .func via a guard_func, so one always exists.
        // Defensive: bail rather than miscompile.
        if (!found) return error.Bail;
    }
    // A `.native` (pure-builtin callee snapshot) invariant slot carries the recorded
    // `RecordedBuiltin` ordinal from its covering `guard_builtin`, checked once in the
    // prologue (the upvalue/global cell is re-resolved + re-seeded each entry, so it
    // cannot change within a native run). Locate the guard_builtin and stash its tag.
    for (slots.items) |*s| {
        if (s.kind != .native) continue;
        // Same write-only guard as the `.func` loop above: no load → no
        // prologue identity check → nothing to stash.
        if (s.load_ref < 0) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_builtin and g.a == lr) {
                if (found and g.aux != s.recorded_tag) {
                    // Two guard_builtins on one snapshot with *different* recorded tags:
                    // the prologue checks one, but the oracle re-checks each and would
                    // side-exit on the second — a divergence. The recorder never emits
                    // this (one seeded callee → one tag), so it can only arise malformed.
                    return error.Bail;
                }
                s.recorded_tag = g.aux;
                found = true;
            }
        }
        // proveKinds only set .native via a guard_builtin, so one always exists.
        if (!found) return error.Bail;
    }
    // A `.heap` INVARIANT slot (doc 24 c3) can only arise via a covering
    // `guard_string` (proveKinds' sole path to an invariant `.heap` slot_load);
    // tag it so the prologue emits the once-per-entry `header.type == string`
    // check. Defensive: bail rather than miscompile if no guard is found — an
    // unpinned invariant heap slot would let a table payload flow into the snew
    // callouts as a `*String`. (A CARRIED `.heap` string slot got the same
    // `is_string` tag — plus the writeback-producer proof — in the doc 30 c4b
    // classification arm above; this block is the invariant half only.)
    for (slots.items) |*s| {
        if (s.class != .invariant or s.kind != .heap) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_string and g.a == lr) {
                found = true;
                break;
            }
        }
        if (!found) return error.Bail;
        s.is_string = true;
    }

    // --- liveness: last_use, single backward pass; carried/write store_refs live to the marker ---
    const last_use = try gpa.alloc(u32, n);
    errdefer gpa.free(last_use);
    for (last_use, 0..) |*lu, i| lu.* = @intCast(i); // live at least at its own def
    {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const ins = t.instrs[i];
            const rd = operandReads(ins);
            if (rd.a and last_use[ins.a] < i) last_use[ins.a] = @intCast(i);
            if (rd.b and last_use[ins.b] < i) last_use[ins.b] = @intCast(i);
        }
    }
    // The value feeding ANY φ's back-edge update (slot-bound OR internal) must survive
    // to the shuffle/commit at the terminal `loop` (operandReads does not count φ.b, so
    // this explicit extension is its only liveness — exactly as the old exit_store had).
    for (t.instrs) |ins| {
        if (ins.op != .phi) continue;
        if (last_use[ins.b] < n - 1) last_use[ins.b] = @intCast(n - 1);
    }
    // A dynamically-rooted href reads ins.a (the per-iteration *GcHeader — a
    // VALUE_LANE aload result, or a carried-heap slot_load) but
    // `operandReads(.href)` returns {false, false} (the loop-invariant path reads
    // from the seeded slab slot, not from operand refs). Extend the root's
    // liveness here so it survives to the href and the guard_hash that follows it.
    // guard_hash also reads href_ins.a (the same root) to check hash population.
    // (For a carried-heap slot_load the extension is a no-op — its loc IS the
    // pinned slot home — but routing both roots through the one predicate keeps
    // analysis and lowering deciding identically.)
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .href and isDynTableRoot(kinds, slots.items, slot_id_of_ref, ins.a)) {
            if (last_use[ins.a] < i) last_use[ins.a] = @intCast(i);
        }
        if (ins.op == .guard_hash) {
            const href_ins = t.instrs[ins.a];
            if (isDynTableRoot(kinds, slots.items, slot_id_of_ref, href_ins.a)) {
                if (last_use[href_ins.a] < i) last_use[href_ins.a] = @intCast(i);
            }
        }
        // doc 43 P3: aref consumers reach the TABLE lazily through `aref.a`
        // (arrayFieldReg / the guard_bounds asize fallback), but operandReads
        // counts only the aref token — sound for a `.ptr` root (the table
        // lives in a pinned slot home for the whole trace), unsound for a
        // dynamic root (an hload'd table field / VALUE_LANE element), whose
        // SSA range would otherwise end at its last DIRECT use and hand the
        // consumers a recycled register as the "table". Extend the root's
        // liveness to every reach-through consumer, the dyn-href precedent.
        switch (ins.op) {
            .guard_bounds, .guard_present, .guard_append, .aload, .astore, .astore_append => {
                const aref_ins = t.instrs[ins.a];
                if (aref_ins.op == .aref and isDynTableRoot(kinds, slots.items, slot_id_of_ref, aref_ins.a)) {
                    if (last_use[aref_ins.a] < i) last_use[aref_ins.a] = @intCast(i);
                }
            },
            else => {},
        }
        // ssub (doc 24 c3) and scp (doc 26) read a THIRD operand — the
        // end-index ref in `aux` — which `operandReads`' two-field shape
        // cannot express. Extend its liveness here, exactly as the dyn-href
        // root above, so the end index survives to the callout's staging
        // (ssub → rcx, scp → rdx).
        if (ins.op == .ssub or ins.op == .scp or ins.op == .sfindp or ins.op == .smatch) {
            // Doc 30: sfindp/smatch join the ternary club — their PATTERN
            // ref rides `aux` and must survive to the callout staging.
            const ar: usize = @intCast(ins.aux);
            if (last_use[ar] < i) last_use[ar] = @intCast(i);
        }
    }

    // --- allocation: pin slot homes, then linear-scan the transients ---
    const loc = try gpa.alloc(Loc, n);
    errdefer gpa.free(loc);
    for (loc) |*l| l.* = .{ .spill = 0 }; // placeholder for value-less refs (guards/loop)

    var free: u16 = comptime blk: {
        var m: u16 = 0;
        for (ALLOC_ORDER) |r| m |= regBit(r);
        break :blk m;
    };
    // The disjoint XMM pool (Phase D). Bits are the same 0..15 index space; a float
    // home/transient draws from here, an int/bool/ptr from `free`.
    var free_xmm: u16 = comptime blk: {
        var m: u16 = 0;
        for (XMM_ALLOC_ORDER) |r| m |= regBit(r);
        break :blk m;
    };
    var spill_count: u32 = 0;
    var used_callee: u16 = 0;
    var home_reg_mask: u16 = 0;
    var home_xmm_mask: u16 = 0;

    for (slots.items) |*s| {
        if (s.class == .write_only) continue;
        if (s.kind == .float) {
            // Float home: draw from the XMM pool, else a shared 8-byte spill cell.
            if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                s.home = .{ .xmm = r };
                home_xmm_mask |= regBit(r);
            } else {
                s.home = .{ .spill = spill_count };
                spill_count += 1;
            }
        } else if (pickReg(&free)) |r| {
            s.home = .{ .reg = r };
            home_reg_mask |= regBit(r);
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
        } else {
            s.home = .{ .spill = spill_count };
            spill_count += 1;
        }
    }
    // Resolve slot_load refs to their slot home.
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        loc[i] = slots.items[@intCast(slot_id_of_ref[i])].home;
    }

    // --- computed homes (Phase E1/E2) ---
    // Pin a persistent home for every run-once value (preheader transient) and every
    // internal φ, drawing from the same pools as slot homes (so their registers are
    // reserved out of the body linear scan). The scan then skips these refs. A φ's home
    // is updated at the back-edge; a preheader value's is written once in the prologue.
    const is_computed = try gpa.alloc(bool, n);
    defer gpa.free(is_computed);
    @memset(is_computed, false);
    {
        const ms = marker_idx orelse 0;
        for (t.instrs, 0..) |ins, i| {
            const is_pre_val = marker_idx != null and i < ms and isTransient(ins.op);
            const is_int_phi = ins.op == .phi and ins.aux == trace.PHI_INTERNAL;
            if (!is_pre_val and !is_int_phi) continue;
            if (is_int_phi) {
                // The init must be a run-once value (a < marker), so the prologue
                // init-move reads a home already materialized before `loop_top`.
                if (marker_idx == null or ins.a >= ms) return error.Bail;
                // ... and one with a PERSISTENT location the seed move can read:
                // a run-once transient (computed home, this same block) or a
                // slot_load (slot home). LICM inits are always transients; a
                // peeled trace's init is an arbitrary iteration-1 ref, so
                // anything else (a scan-allocated non-transient producer whose
                // register may be reused) fails closed.
                const init_op = t.instrs[ins.a].op;
                if (!isTransient(init_op) and init_op != .slot_load) return error.Bail;
            }
            switch (kinds[i]) {
                .float => {
                    if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                        loc[i] = .{ .xmm = r };
                        home_xmm_mask |= regBit(r);
                    } else {
                        loc[i] = .{ .spill = spill_count };
                        spill_count += 1;
                    }
                },
                .int, .bool => {
                    if (pickReg(&free)) |r| {
                        loc[i] = .{ .reg = r };
                        home_reg_mask |= regBit(r);
                        used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                    } else {
                        loc[i] = .{ .spill = spill_count };
                        spill_count += 1;
                    }
                },
                // A computed home must carry a boxable scalar; anything else (a `.ptr`/
                // `.aref` hoisted into the preheader, or a mis-typed φ) cannot be homed.
                else => return error.Bail,
            }
            is_computed[i] = true;
        }
    }

    // --- Phase 2: reserve invariant array-base homes ---------------------------------
    // For each `.ptr` slot used as an `aref.a`, the array `data`/`present` pointers and
    // `len` are loop-invariant across a native run (B5: the path never reallocates or
    // lane-widens — `guard_fits` side-exits first). Materialize each *once* in the
    // prologue into a dedicated register instead of re-loading `[tbreg+field]` every
    // iteration. Only the fields the body actually reads are reserved, drawn from the
    // callee-saved tail (`BASE_HOME_ORDER`) so a low-pressure trace hoists for free
    // while a high-pressure one falls back to the per-iteration load (a `null` home).
    // Reserved here — after computed homes, before coalescing + the body linear scan —
    // so neither reuses these registers; folded into `home_reg_mask`/`used_callee` so
    // the disjointness assertions and prologue push/pop already cover them.
    {
        const ns = slots.items.len;
        const need_data = try gpa.alloc(bool, ns);
        defer gpa.free(need_data);
        const need_present = try gpa.alloc(bool, ns);
        defer gpa.free(need_present);
        const need_len = try gpa.alloc(bool, ns);
        defer gpa.free(need_len);
        @memset(need_data, false);
        @memset(need_present, false);
        @memset(need_len, false);

        // Which array base each consuming op needs, attributed to the `.ptr` slot its
        // address operand roots at. (guard_bounds → len; bool guard_present/aload/astore
        // → data; int guard_present → present; int astore/astore_append → data + present.)
        // astore_append also bumps len in memory, but via a re-fetched table pointer in
        // rax (no len_home for an append trace), so it needs no len reservation here.
        //
        // A scalar array op roots ONE hop (aref.a == table slot_load); a grid op
        // (doc 14) roots TWO hops (gcell.a == garow, garow.a == table slot_load). Its
        // grid guard_bounds is on the GAROW, whose `.a` is already the table slot_load,
        // so it falls into the one-hop arm below unchanged. The cell ops (gload/gstore/
        // guard_gpresent) carry the gcell and need the extra hop.
        for (t.instrs) |ins| {
            var sid_signed: i32 = -1;
            var is_bool = false;
            var is_value = false;
            switch (ins.op) {
                .guard_bounds, .guard_present, .aload, .astore, .astore_append => {
                    const aref_ins = t.instrs[@intCast(ins.a)];
                    sid_signed = slot_id_of_ref[aref_ins.a];
                    is_bool = aref_ins.aux == BOOL_LANE;
                    is_value = aref_ins.aux == VALUE_LANE;
                },
                .gload, .gstore, .guard_gpresent => {
                    const gcell_ins = t.instrs[@intCast(ins.a)];
                    const garow_ins = t.instrs[@intCast(gcell_ins.a)];
                    sid_signed = slot_id_of_ref[garow_ins.a]; // two hops to the table slot
                },
                else => continue,
            }
            if (sid_signed < 0) continue; // table operand isn't a slot home — leave per-iter
            const sid: usize = @intCast(sid_signed);
            switch (ins.op) {
                .guard_bounds => need_len[sid] = true,
                .guard_present => if (is_bool) {
                    need_data[sid] = true;
                } else {
                    need_present[sid] = true;
                },
                .aload => need_data[sid] = true,
                .astore, .astore_append => {
                    need_data[sid] = true;
                    // The bool lane carries presence in-band (one byte per slot) and the
                    // `.value` lane has no presence bitmap at all (`present` is null, nil
                    // is an in-band tag) — reserving a base register for either would be a
                    // wasted home, and for `.value` a load through a null pointer.
                    if (!is_bool and !is_value) need_present[sid] = true;
                },
                // Grid cells (doc 14) are int-lane only in this cut: a load needs the
                // data base; a store needs data + the presence bitmap; a presence guard
                // needs only the bitmap.
                .gload => need_data[sid] = true,
                .guard_gpresent => need_present[sid] = true,
                .gstore => {
                    need_data[sid] = true;
                    need_present[sid] = true;
                },
                else => unreachable,
            }
        }

        // An astore_append bumps `len` in memory only (no len_home writeback — see the
        // lowering), so a `len` register hoisted by a sibling guard_bounds on the same
        // table would go stale the moment the append commits. Don't hoist `len` for any
        // trace that contains an astore_append; guard_bounds then reloads `len` from the
        // table each iteration (always the committed value). A pure append fill has no
        // guard_bounds, so this costs it nothing.
        var has_append = false;
        for (t.instrs) |ins| {
            if (ins.op == .astore_append) {
                has_append = true;
                break;
            }
        }
        for (slots.items, 0..) |*s, sid| {
            if (s.class == .write_only) continue;
            if (need_data[sid]) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.data_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
            if (need_present[sid]) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.present_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
            if (need_len[sid] and !has_append) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.len_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
        }
    }

    // --- home coalescing (win 2): allocate a carried slot's store_ref transient INTO
    // the slot's home, so the op updates the home in place AND the back-edge shuffle
    // self-elides. Gated by a safety predicate (cuts-2's single-snapshot model assumes
    // homes are written only at the back-edge; an in-place update breaks that unless no
    // side-exit follows it). Must run BEFORE the linear scan so it sees loc[j] fixed.
    const is_coalesced_home = try gpa.alloc(bool, n);
    defer gpa.free(is_coalesced_home);
    @memset(is_coalesced_home, false);
    {
        // The last side-exiting instruction. An in-place home update that PRECEDES
        // any mid-body side-exit would be committed by the deopt flush even though
        // the iteration aborted — so home coalescing must be blocked past the last
        // of them. `opMayExitInBody` is the closed inventory of every exit the body
        // emitter can produce (the hoisted guards — guard_int/guard_lane and the
        // `.ptr` forms of guard_table/guard_hash — never exit mid-body; their
        // dynamic per-iteration forms and the href callout DO). Trace order is
        // straight-line, so index order == dominance: "after" == strictly greater
        // index.
        var last_body_guard: i64 = -1;
        for (0..n) |idx| {
            if (opMayExitInBody(t, kinds, slots.items, slot_id_of_ref, idx)) last_body_guard = @intCast(idx);
        }
        for (slots.items, 0..) |*s, sid| {
            if (s.class != .carried) continue;
            // Doc 39: never coalesce in a peeled trace. A steady-φ slot's entry
            // home is DEAD after the run-once region — pinning a body transient
            // into it would resurrect it with (potentially) the wrong register
            // class, and the back-edge shuffle deliberately skips these homes.
            if (s.steady_phi >= 0) continue;
            // [Phase D] Float coalescing is disabled in the first cut: SSE has no
            // `op [mem],xmm` store form and a float op always materializes into a
            // scratch XMM before writing its home, so there is no in-place win to
            // capture. Skip — the back-edge shuffle handles the float carry.
            if (s.kind == .float) continue;
            // doc 34: a type-unstable carried slot (`.link` exemption) homes as the
            // load kind, but its phi store_ref may be a different numeric kind.
            // Coalescing a float-kind store_ref into an int-kind GP home → unreachable
            // in the float lowering. Skip coalescing entirely for type-unstable slots.
            if (kinds[@intCast(s.store_ref)] != s.kind) continue;
            const j: usize = @intCast(s.store_ref);
            const def = t.instrs[j];
            if (!isCoalescibleOp(def.op)) continue;
            // (1) no side-exit follows the in-place update.
            if (@as(i64, @intCast(j)) <= last_body_guard) continue;
            // [RV] imul has no [mem],reg store form → a spilled-home mul can't go in place.
            if (def.op == .mul and s.home != .reg) continue;
            // (2) S's OLD value is fully dead by j: no slot_load(S) ref is read after j.
            // (The operand read at j itself has last_use == j ≤ j, which is fine.)
            var old_live = false;
            for (0..n) |r2| {
                if (slot_id_of_ref[r2] == @as(i32, @intCast(sid)) and last_use[r2] > j) {
                    old_live = true;
                    break;
                }
            }
            if (old_live) continue;
            // (3) home(S) holds an operand at the op: left operand is home (any op), or a
            // commutative op's right operand is home. Unary requires its sole operand.
            const a_home = operandReads(def).a and locEql(loc[def.a], s.home);
            const b_home = operandReads(def).b and locEql(loc[def.b], s.home);
            const op_ok = a_home or (b_home and isCommutative(def.op));
            if (!op_ok) continue;
            // Coalesce: pin the transient into the home, mark the slot, and extend the
            // transient's live range to the loop marker so the scan never frees the home
            // [RV: the coalesced value IS snapshot state from j onward].
            loc[j] = s.home;
            s.coalesced = true;
            is_coalesced_home[j] = true;
            if (last_use[j] < n - 1) last_use[j] = @intCast(n - 1);
        }
    }

    // Linear scan over transient defs in index order; active set ≤ pool size. A
    // second, parallel active set tracks the XMM pool (float transients) — the two
    // register files expire independently into `free` / `free_xmm`.
    var active: [ALLOC_ORDER.len]struct { reg: Reg, last: u32 } = undefined;
    var active_len: usize = 0;
    var active_xmm: [XMM_ALLOC_ORDER.len]struct { reg: Reg, last: u32 } = undefined;
    var active_xmm_len: usize = 0;
    for (t.instrs, 0..) |ins, i| {
        if (!isTransient(ins.op)) continue;
        // expire GP transients whose last use precedes i
        var w: usize = 0;
        for (active[0..active_len]) |e| {
            if (e.last < i) {
                free |= regBit(e.reg);
            } else {
                active[w] = e;
                w += 1;
            }
        }
        active_len = w;
        // expire XMM transients likewise
        var wx: usize = 0;
        for (active_xmm[0..active_xmm_len]) |e| {
            if (e.last < i) {
                free_xmm |= regBit(e.reg);
            } else {
                active_xmm[wx] = e;
                wx += 1;
            }
        }
        active_xmm_len = wx;

        // A win-2 transient is already pinned to its slot home — never reallocate it.
        if (is_coalesced_home[i]) continue;
        // A run-once preheader value already has a computed home (pinned above, its
        // register reserved out of the pool) — never reallocate or expire it.
        if (is_computed[i]) continue;

        // [Phase D] A float transient draws from the XMM pool. Operand coalescing
        // (win 1) is disabled for floats (the value always lands in a scratch XMM
        // first — see the win-2 skip above), so allocate a fresh XMM or a spill cell.
        if (kinds[i] == .float) {
            if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                loc[i] = .{ .xmm = r };
                active_xmm[active_xmm_len] = .{ .reg = r, .last = last_use[i] };
                active_xmm_len += 1;
            } else {
                loc[i] = .{ .spill = spill_count };
                spill_count += 1;
            }
            continue;
        }

        // --- operand coalescing (win 1): reuse a *dying* operand's register for the
        // result, emitting an in-place `op dst, b` instead of staging through rax.
        // The operand must (a) live in a register, (b) NOT be a slot home — reusing a
        // home would clobber a loop-carried value mid-iteration [RV: location-based,
        // not slot_id<0, so it stays correct once win-2 puts transients in homes] —
        // and (c) die exactly here (last_use == i). For commutative ops either operand
        // qualifies; otherwise only `a` (the destructive-write target).
        const rd = operandReads(ins);
        var coalesced: ?Reg = null;
        const cands = [2]struct { ref: usize, ok: bool }{
            .{ .ref = ins.a, .ok = rd.a },
            .{ .ref = ins.b, .ok = rd.b and isCommutative(ins.op) },
        };
        for (cands) |c| {
            if (!c.ok) continue;
            if (loc[c.ref] != .reg) continue;
            const r = loc[c.ref].reg;
            if (home_reg_mask & regBit(r) != 0) continue;
            if (last_use[c.ref] != i) continue;
            // Repurpose the operand's active entry for the result's live range.
            for (active[0..active_len]) |*e| {
                if (e.reg == r) {
                    e.last = last_use[i];
                    coalesced = r;
                    break;
                }
            }
            if (coalesced != null) break;
        }
        if (coalesced) |r| {
            loc[i] = .{ .reg = r };
        } else if (pickReg(&free)) |r| {
            loc[i] = .{ .reg = r };
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
            active[active_len] = .{ .reg = r, .last = last_use[i] };
            active_len += 1;
        } else {
            loc[i] = .{ .spill = spill_count };
            spill_count += 1;
        }
    }

    // --- invariant assertions (compiled out in release; the structural guardrail) ---
    if (std.debug.runtime_safety) {
        // homes are register-disjoint, tracked per register file (a GP reg and the
        // XMM of the same 0..15 index are physically distinct → never alias).
        var seen: u16 = 0;
        var seen_xmm: u16 = 0;
        for (slots.items) |s| {
            if (s.class == .write_only) continue;
            switch (s.home) {
                .reg => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                },
                .xmm => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen_xmm & b == 0);
                    seen_xmm |= b;
                },
                .spill => {},
            }
        }
        // Computed homes (preheader values + internal φs) are also register-disjoint
        // from slot homes and from each other (drawn from the same pools after slots).
        for (0..n) |i| {
            if (!is_computed[i]) continue;
            switch (loc[i]) {
                .reg => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                },
                .xmm => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen_xmm & b == 0);
                    seen_xmm |= b;
                },
                .spill => {},
            }
        }
        // [Phase 2] Invariant array-base homes are register-disjoint from slot homes,
        // computed homes, and each other (drawn from `free` after both, each pick
        // clearing its bit). They are GP-only and folded into `home_reg_mask`.
        for (slots.items) |s| {
            for ([_]?Reg{ s.data_home, s.present_home, s.len_home }) |maybe| {
                if (maybe) |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                    std.debug.assert(home_reg_mask & b != 0); // must be reserved out of the body
                }
            }
        }
        // no transient register aliases a home register (per file) — except a win-2
        // transient (pinned INTO its slot's home) or a computed home (pinned above).
        for (t.instrs, 0..) |ins, i| {
            if (!isTransient(ins.op)) continue;
            if (is_coalesced_home[i] or is_computed[i]) continue;
            switch (loc[i]) {
                .reg => |r| std.debug.assert(home_reg_mask & regBit(r) == 0),
                .xmm => |r| std.debug.assert(home_xmm_mask & regBit(r) == 0),
                .spill => {},
            }
        }
        // every slot-bound φ's back-edge update ref has a concrete location (always does)
        for (t.instrs) |ins| {
            if (ins.op != .phi or ins.aux < 0) continue;
            const l = loc[ins.b];
            std.debug.assert(l == .reg or l == .xmm or l == .spill);
        }
    }

    // --- callout save area (any BodyCallout in the body) ---
    // If any instruction in this trace lowers to a mid-body callout (a
    // dynamically-rooted href's `resolveHashCell`, an fsin/fcos `fmath` kernel
    // call, …), the callout clobbers all SysV caller-saved registers. Reserve
    // frame slots to save/restore live homes. The predicate is `bodyCalloutOf`
    // itself — the SAME mapping the lowering and the heap-φ GC audit dispatch
    // on — so a new callout can never silently miss its save area.
    var callout_save_base: u32 = 0;
    var callout_save_count: u32 = 0;
    {
        var needs_callout = false;
        for (t.instrs, 0..) |_, ci| {
            if (bodyCalloutOf(t, kinds, slots.items, slot_id_of_ref, ci) != null) {
                needs_callout = true;
                break;
            }
        }
        if (needs_callout) {
            callout_save_base = spill_count;
            // The callout clobbers ALL SysV caller-saved registers. We must save
            // not just slot homes but also transient registers that may be live
            // across the callout (e.g. a float hload result from a prior field
            // access in the same iteration, still alive at the second href).
            // Simplest correct approach: save ALL caller-saved GP and XMM
            // allocatable registers unconditionally, plus rdi/rsi (SoA bases)
            // and rdx (*NativeResult out-param, used at side-exits).
            var count: u32 = 3; // rdi + rsi + rdx
            // All allocatable caller-saved GPRs: r8, r9, r10, r11.
            count += 4;
            // All allocatable XMMs: xmm2–xmm15 (XMM_ALLOC_ORDER, 14 regs).
            count += XMM_ALLOC_ORDER.len;
            callout_save_count = count;
            // +1 for the alignment padding slot: the JIT body runs with
            // rsp % 16 == 8 (correct for the JIT's own return convention but
            // wrong for an outgoing SysV call). `emitHrefCallout` does
            // `sub rsp, 8` before the call and `add rsp, 8` after — the
            // extra slot ensures this doesn't underflow the frame.
            spill_count += count + 1;
        }
    }

    // --- rdx park slot for inline int mod/idiv (doc 25 D1) ---
    // Reserved AFTER the callout region so it can never alias it (codex
    // medium). One slot serves every int mod/idiv in the body — the park is
    // strictly instruction-local, never live across two of them.
    var div_save: ?u32 = null;
    for (t.instrs) |ins| {
        if ((ins.op == .mod or ins.op == .idiv) and ins.ty == .int) {
            div_save = spill_count;
            spill_count += 1;
            break;
        }
    }

    return .{
        .loc = loc,
        .last_use = last_use,
        .slot_id_of_ref = slot_id_of_ref,
        .slots = try slots.toOwnedSlice(gpa),
        .spill_count = spill_count,
        .used_callee_saved = used_callee,
        .callout_save_base = callout_save_base,
        .callout_save_count = callout_save_count,
        .div_save = div_save,
    };
}

/// Pop the first free register in `ALLOC_ORDER` preference, clearing its bit. Null if none.
fn pickReg(free: *u16) ?Reg {
    return pickRegFrom(free, &ALLOC_ORDER);
}

/// Pop the first free register in the given preference order, clearing its bit. Null
/// if none. Shared by the GP pool (`ALLOC_ORDER`) and the XMM pool (`XMM_ALLOC_ORDER`).
fn pickRegFrom(free: *u16, order: []const Reg) ?Reg {
    for (order) |r| {
        const b = regBit(r);
        if (free.* & b != 0) {
            free.* &= ~b;
            return r;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// cut-2: lowering helpers — a `Place` is where a value sits (a register or a frame
// slot at an rsp displacement). The body keeps slot homes in registers and transients
// in frame slots (commit B); commit C moves transients to registers too.
// ---------------------------------------------------------------------------

const Place = union(enum) {
    reg: Reg, // a general-purpose register
    xmm: Reg, // an XMM register (float). Distinct tag → a GP reg and the XMM of the
    // same 0..15 index never compare equal (they are physically distinct registers).
    mem: i32, // rsp-relative byte displacement (kind-agnostic 8-B cell)

    fn eql(x: Place, y: Place) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .reg => x.reg == y.reg,
            .xmm => x.xmm == y.xmm,
            .mem => x.mem == y.mem,
        };
    }
};

/// Map an allocation `Loc` to a `Place`: a register stays a register; a spill slot
/// becomes a frame displacement `[rsp + idx*8]`.
fn locToPlace(l: Loc) Place {
    return switch (l) {
        .reg => |r| .{ .reg = r },
        .xmm => |r| .{ .xmm = r },
        .spill => |idx| .{ .mem = @as(i32, @intCast(idx)) * 8 },
    };
}

/// The home of a carried/invariant slot: its assigned register or spill slot.
fn slotHomePlace(s: SlotInfo) Place {
    return locToPlace(s.home);
}

/// Where ref `r`'s value lives — its linear-scan-assigned register or frame slot.
/// A `slot_load` ref resolves to its slot home (its `loc` was set to that home).
fn placeOfRef(alloc: *const Alloc, r: usize) Place {
    return locToPlace(alloc.loc[r]);
}

fn placeToReg(a: *x64.Assembler, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| if (r != dst) try a.movRegReg(dst, r),
        .mem => |d| try a.movRegMem(dst, .rsp, d),
        .xmm => unreachable, // a GP destination never receives a float source
    }
}

fn regToPlace(a: *x64.Assembler, dst: Place, src: Reg) !void {
    switch (dst) {
        .reg => |r| if (r != src) try a.movRegReg(r, src),
        .mem => |d| try a.movMemReg(.rsp, d, src),
        .xmm => unreachable, // a GP source never targets a float home
    }
}

/// Ensure a ref's value is in a CPU register usable as a memory *base*, returning
/// that register. A register home is used directly; a spilled home is loaded into
/// `scratch` (rax). Used for the invariant table pointer at each array op.
fn refBaseReg(a: *x64.Assembler, alloc: *const Alloc, ref: usize, scratch: Reg) !Reg {
    switch (placeOfRef(alloc, ref)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
        .xmm => unreachable, // array-path operands are int/ptr, never float
    }
}

/// [Phase 2] The register holding an invariant array base pointer (`data` or
/// `present`) for the table referenced by `aref_a` (an aref token's table operand).
/// If `analyze` hoisted that field into a dedicated register home, return it directly
/// — no memory traffic. Otherwise fall back to the per-iteration load: fetch the table
/// pointer (its home, or `scratch`) and load `[tbreg + array_base + field]` into
/// `scratch`, returning `scratch`. Either way the returned register is a valid memory
/// base for the subsequent SIB element access. (`len` is a compare operand, handled
/// inline at `guard_bounds`.)
const ArrayBaseField = enum { data, present };
fn arrayFieldReg(a: *x64.Assembler, alloc: *const Alloc, aref_a: usize, field: ArrayBaseField, scratch: Reg) !Reg {
    const sid = alloc.slot_id_of_ref[aref_a];
    if (sid >= 0) {
        const s = alloc.slots[@intCast(sid)];
        const home: ?Reg = switch (field) {
            .data => s.data_home,
            .present => s.present_home,
        };
        if (home) |r| return r; // hoisted — already in a register, no load
    }
    const tb = try refBaseReg(a, alloc, aref_a, scratch);
    const fieldoff: i32 = switch (field) {
        .data => ArrLayout.data,
        .present => ArrLayout.present,
    };
    try a.movRegMem(scratch, tb, ArrLayout.array_base + fieldoff);
    return scratch;
}

/// Like `refBaseReg`, but for a slot's home `Place` (used for the prologue table
/// checks, where the slot is referenced by its home, not an SSA ref).
fn refHomeBaseReg(a: *x64.Assembler, s: SlotInfo, scratch: Reg) !Reg {
    switch (slotHomePlace(s)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
        .xmm => unreachable, // only `.ptr`/`.func`/`.native` heap-pointer slots reach here, never float
    }
}

/// Emit `dst <op> src` where `dst` is a register and `src` is a Place — reg→reg ALU
/// or the load-form `op r64, [mem]` when the operand is spilled (avoids staging it
/// through scratch). Only binary arithmetic/bitwise ops reach here.
fn emitAluRegPlace(a: *x64.Assembler, op: trace.IrOp, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| switch (op) {
            .add => try a.addRegReg(dst, r),
            .sub => try a.subRegReg(dst, r),
            .mul => try a.imulRegReg(dst, r),
            .band => try a.andRegReg(dst, r),
            .bor => try a.orRegReg(dst, r),
            .bxor => try a.xorRegReg(dst, r),
            else => unreachable,
        },
        .mem => |d| switch (op) {
            .add => try a.addRegMem(dst, .rsp, d),
            .sub => try a.subRegMem(dst, .rsp, d),
            .mul => try a.imulRegMem(dst, .rsp, d),
            .band => try a.andRegMem(dst, .rsp, d),
            .bor => try a.orRegMem(dst, .rsp, d),
            .bxor => try a.xorRegMem(dst, .rsp, d),
            else => unreachable,
        },
        .xmm => unreachable, // integer ALU never reads a float operand
    }
}

/// Lower a binary ALU op `dst = pa <op> pb` reading operands in place.
///   - register dst: keep `pa` in dst (elided when operand/home-coalesced so `pa==dst`)
///     then `op dst, pb`; a commutative op may instead keep the in-register `pb`.
///   - spilled dst: in-place store form `op [dst], pb_reg` when `pa==dst` (the win-2
///     coalesced home), else stage `a` in rax and write back. imul has no store form,
///     so a spilled in-place `mul` is never produced (analyze keeps such homes in regs).
fn emitBinAlu(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    switch (dst) {
        .reg => |R| {
            if (pa == .reg and pa.reg == R) {
                try emitAluRegPlace(a, op, R, pb);
            } else if (isCommutative(op) and pb == .reg and pb.reg == R) {
                try emitAluRegPlace(a, op, R, pa);
            } else {
                // R holds neither operand: materialize `a`, then `op R, b`. For
                // non-commutative ops `pb.reg == R` is impossible (a still-live operand
                // keeps its register), so the staging move never clobbers `b`.
                try placeToReg(a, R, pa);
                try emitAluRegPlace(a, op, R, pb);
            }
        },
        .mem => |D| {
            if (Place.eql(pa, dst)) {
                // In-place spilled home (win 2): `op [dst], b`. Load b to rcx if spilled.
                std.debug.assert(op != .mul); // no imul store form
                const src_reg: Reg = switch (pb) {
                    .reg => |r| r,
                    .mem => |bd| blk: {
                        try a.movRegMem(.rcx, .rsp, bd);
                        break :blk .rcx;
                    },
                    .xmm => unreachable,
                };
                switch (op) {
                    .add => try a.addMemReg(.rsp, D, src_reg),
                    .sub => try a.subMemReg(.rsp, D, src_reg),
                    .band => try a.andMemReg(.rsp, D, src_reg),
                    .bor => try a.orMemReg(.rsp, D, src_reg),
                    .bxor => try a.xorMemReg(.rsp, D, src_reg),
                    else => unreachable,
                }
            } else {
                // General spilled dst: compute in rax, write back.
                try placeToReg(a, .rax, pa);
                try emitAluRegPlace(a, op, .rax, pb);
                try a.movMemReg(.rsp, D, .rax);
            }
        },
        .xmm => unreachable, // integer ALU never writes a float home (see emitFloatBinOp)
    }
}

/// Lower a Lua/mahina shift `dst = pa <shift> pb` (`pb` = the count). Reproduces the
/// FULL operator semantics the oracle (`arith.shiftLeft`/`shiftRight`/`shiftRightArith`)
/// computes, making no assumption that the count is masked: a negative count shifts the
/// other direction, and an out-of-range positive count saturates — to `0` for the
/// logical shifts (`shl`/`shr`), or to the **sign fill** (`-1`/`0`) for the arithmetic
/// right shift (`sar`, the `~>>` operator). x86 `shl/shr/sar reg, cl` honour only the
/// low 6 bits of the count, so the out-of-`[0,63]` cases are handled with an explicit
/// branch bracket rather than a bare hardware shift (which would alias 64→0, 65→1, … and
/// mishandle a negative count). The value works in `W` (the dst register, or rax for a
/// spilled dst); the count lives in cl (rcx, a scratch reg) for the duration. Registers
/// used: `W` + rcx only — no extra temporary — so it fits the cut-2 allocator's two
/// scratch registers no matter how many homes are live.
fn emitShift(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    // Working register: the dst register itself, or rax when dst is spilled.
    const W: Reg = switch (dst) {
        .reg => |R| R,
        .mem => .rax,
        .xmm => unreachable, // a shift result is int, never a float home
    };
    // Load the count into rcx FIRST: pb's home may coincide with the dst register (the
    // linear scan can reuse a dying operand's reg as the result home), so reading the
    // count before W is overwritten with the value avoids clobbering it. (rcx is a
    // reserved scratch, never an operand home, so this never clobbers pa.)
    try placeToReg(a, .rcx, pb);
    // Then the value into W (the mov elides when pa is already in W).
    if (!(pa == .reg and pa.reg == W)) try placeToReg(a, W, pa);

    const neg_lbl = try a.label();
    const zero_lbl = try a.label();
    const done_lbl = try a.label();
    // sar's positive-overflow leg broadcasts the sign bit instead of zeroing; only
    // referenced/bound on the `.sar` path.
    const sign_lbl = if (op == .sar) try a.label() else undefined;

    // count < 0 → reverse-direction branch.
    try a.cmpRegImm32(.rcx, 0);
    try a.jcc(.s, neg_lbl);
    // count >= 64 → out of range. Logical shifts yield 0; arithmetic right shift
    // saturates to the sign fill (`sar W, 63`).
    try a.cmpRegImm32(.rcx, 64);
    if (op == .sar) try a.jcc(.ae, sign_lbl) else try a.jcc(.ae, zero_lbl);
    // 0 <= count < 64 → the op's primary direction.
    switch (op) {
        .shl => try a.shlRegCl(W),
        .shr => try a.shrRegCl(W),
        .sar => try a.sarRegCl(W),
        else => unreachable,
    }
    try a.jmp(done_lbl);

    a.bind(neg_lbl);
    // magnitude = -count; an out-of-range magnitude (incl. INT64_MIN, whose negation
    // stays INT64_MIN — huge as unsigned) → result 0 (the reverse is always logical).
    try a.negReg(.rcx);
    try a.cmpRegImm32(.rcx, 64);
    try a.jcc(.ae, zero_lbl);
    // Reverse direction by the magnitude (`x << -n` == `x >> n`; for sar the reverse is
    // a logical left, exactly as for shr).
    if (op == .shl) try a.shrRegCl(W) else try a.shlRegCl(W);
    try a.jmp(done_lbl);

    a.bind(zero_lbl);
    try a.xorRegReg(W, W);
    if (op == .sar) {
        // zero_lbl falls through to done unless sar's sign leg follows; jump past it.
        try a.jmp(done_lbl);
        a.bind(sign_lbl);
        try a.sarRegImm8(W, 63); // broadcast bit 63 → all-ones (-1) or all-zeros (0)
    }

    a.bind(done_lbl);
    // Spilled dst: write the computed value back to its stack home.
    if (dst == .mem) try a.movMemReg(.rsp, dst.mem, W);
}

/// Lower a comparison `dst = pa <cc> pb` reading operands in place. Needs a register
/// on the left of `cmp`; stages `a` through rax only when it is spilled. The Bool
/// result lands in `dst` via setcc+movzx.
fn emitCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    const lhs: Reg = switch (pa) {
        .reg => |r| r,
        .mem => |d| blk: {
            try a.movRegMem(.rax, .rsp, d);
            break :blk .rax;
        },
        .xmm => unreachable, // F1 admits only int compare operands (float compare is F2)
    };
    switch (pb) {
        .reg => |r| try a.cmpRegReg(lhs, r),
        .mem => |d| try a.cmpRegMem(lhs, .rsp, d),
        .xmm => unreachable, // F1 admits only int compare operands (float compare is F2)
    }
    const cc: x64.Cond = switch (op) {
        .eq => .e,
        .ne => .ne,
        .lt => .l,
        .le => .le,
        else => unreachable,
    };
    switch (dst) {
        .reg => |R| {
            try a.setcc(cc, R);
            try a.movzxRegReg8(R, R); // zero-extend the 0/1 byte to the full register
        },
        .mem => |D| {
            try a.setcc(cc, .rax);
            try a.movzxRegReg8(.rax, .rax);
            try a.movMemReg(.rsp, D, .rax);
        },
        .xmm => unreachable, // a comparison result is a bool, never homed in an XMM
    }
}

/// Lower a float comparison `dst = pa <cc> pb` (both operands proven `.float`; mixed
/// int/float compares bail in proveKinds). Stages operands into xmm0/xmm1, runs
/// `ucomisd`, and combines the NaN-aware flags into a clean 0/1 bool in rax, then to
/// `dst`. `ucomisd` sets only ZF/PF/CF (PF=1 ⇔ unordered/NaN); SF/OF are untouched, so
/// the unsigned-style conds (a/ae) + p/np are the correct readouts. Semantics mirror
/// `value.compareNumeric` for two f64s: a NaN operand makes lt/le/eq false and ne true.
///
/// [review] `ucomisd` (not `comisd`) is deliberate: it raises the invalid-operand flag
/// only for a *signaling* NaN, never a quiet one. The oracle short-circuits
/// `isNan(x) or isNan(y)`, so a qNaN lhs + sNaN rhs makes native touch the sNaN (setting
/// MXCSR.IE) where the oracle would not. This never diverges the boolean *result* — and
/// it is unobservable in mahina anyway: FP exceptions are masked (SysV default), there is
/// no MXCSR/feenableexcept seam, and a signaling NaN is unreachable from Lua source
/// (0.0/0.0 yields a quiet NaN; there is no sNaN literal).
fn emitFloatCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    try floatOperandToXmm(a, XMM_SCRATCH0, pa, .float); // lhs
    try floatOperandToXmm(a, XMM_SCRATCH1, pb, .float); // rhs
    switch (op) {
        // a < b: compare (rhs ? lhs); `seta` = CF==0 && ZF==0 = rhs>lhs = a<b. A NaN
        // sets CF=1 → seta=0 (false), as required.
        .lt => {
            try a.ucomisdRegReg(XMM_SCRATCH1, XMM_SCRATCH0);
            try a.setcc(.a, .rax);
            try a.movzxRegReg8(.rax, .rax);
        },
        // a <= b: `setae` = CF==0 = rhs>=lhs = a<=b. NaN sets CF=1 → 0 (false).
        .le => {
            try a.ucomisdRegReg(XMM_SCRATCH1, XMM_SCRATCH0);
            try a.setcc(.ae, .rax);
            try a.movzxRegReg8(.rax, .rax);
        },
        // a == b, NaN→false: ordered (np) AND equal (ZF). On NaN, ZF=1 but PF=1 → np=0.
        .eq => {
            try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
            try a.setcc(.e, .rax); // ZF: equal OR unordered
            try a.setcc(.np, .rcx); // ordered (not-parity)
            try a.movzxRegReg8(.rax, .rax);
            try a.movzxRegReg8(.rcx, .rcx);
            try a.andRegReg(.rax, .rcx);
        },
        // a != b, NaN→true: unordered (p) OR not-equal (!ZF). On NaN, ZF=1 → setne=0 but PF=1 → p=1.
        .ne => {
            try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
            try a.setcc(.ne, .rax); // !ZF
            try a.setcc(.p, .rcx); // unordered (parity)
            try a.movzxRegReg8(.rax, .rax);
            try a.movzxRegReg8(.rcx, .rcx);
            try a.orRegReg(.rax, .rcx);
        },
        else => unreachable,
    }
    try regToPlace(a, dst, .rax);
}

/// Materialize a numeric operand into a scratch XMM (`dst_xmm`). A `.float` operand is
/// moved with `movsd`; an `.int` operand is promoted with `cvtsi2sd` (round-to-nearest,
/// bit-matching `@floatFromInt` in the strict-FP oracle). Operand homes are XMM/spill
/// (float) or GP/spill (int) — never the cross combination.
fn floatOperandToXmm(a: *x64.Assembler, dst_xmm: Reg, place: Place, kind: Kind) !void {
    switch (kind) {
        .float => switch (place) {
            .xmm => |x| try a.movsdRegReg(dst_xmm, x),
            .mem => |d| try a.movsdRegMem(dst_xmm, .rsp, d),
            .reg => unreachable, // a float never lives in a GP register
        },
        .int => switch (place) {
            .reg => |r| try a.cvtsi2sdRegReg(dst_xmm, r),
            .mem => |d| try a.cvtsi2sdRegMem(dst_xmm, .rsp, d),
            .xmm => unreachable, // an int never lives in an XMM register
        },
        else => unreachable, // proveKinds admits only int/float operands to a float op
    }
}

/// Lower a float binary op `dst = pa <op> pb`. Both operands are staged into the reserved
/// scratch XMMs (xmm0 = lhs, xmm1 = rhs; an int operand is `cvtsi2sd`-promoted), the SSE
/// op runs in xmm0 preserving operand order (matters for sub/div), then the result moves
/// to the home. Float coalescing is disabled in the first cut, so `dst` is xmm2..15 or a
/// spill cell — never a scratch XMM — and staging through xmm0/xmm1 cannot clobber it
/// before both operands are read (so `x*x` and reused-register dsts are safe).
fn emitFloatBinOp(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, ka: Kind, pb: Place, kb: Kind) !void {
    try floatOperandToXmm(a, XMM_SCRATCH0, pa, ka);
    try floatOperandToXmm(a, XMM_SCRATCH1, pb, kb);
    switch (op) {
        .add => try a.addsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .sub => try a.subsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .mul => try a.mulsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .div => try a.divsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        else => unreachable,
    }
    switch (dst) {
        .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
        .reg => unreachable, // a float result never homes in a GP register
    }
}

/// Flush one slot's `Value` into the SoA register file: the 1-byte tag into
/// `tags[slot]` (rdi, scale-1) and the 8 payload bytes into `payloads[slot]` (rsi,
/// scale-8). The tag is written with a single-byte store (NOT the old 4-byte
/// `movMemImm32`, which under SoA would clobber the next three slots' tag bytes).
/// The payload source is a `Place`: a GP reg / spill cell raw-copies the 8 bytes
/// (int/bool); an XMM home stores the double with `movsd` (float). rax is the
/// scratch for a spilled payload.
fn boxedTagSpill(t: *const Trace, kinds: []const Kind, alloc: *const Alloc, ref: usize) !u32 {
    if (ref >= t.instrs.len or kinds[ref] != .boxed or t.instrs[ref].op != .slot_load) return error.Unsupported;
    var ordinal: u32 = 0;
    for (kinds[0..ref]) |kind| if (kind == .boxed) {
        ordinal += 1;
    };
    return alloc.spill_count + ordinal;
}

fn snapshotBoxedTags(a: *x64.Assembler, t: *const Trace, kinds: []const Kind, alloc: *const Alloc) !void {
    // Snapshot every admitted boxed source before *any* destination tag store:
    // phi writes are parallel, and reading tags during a swap/cycle would pair a
    // preserved payload with an already-overwritten tag.
    for (kinds, 0..) |kind, ref| {
        if (kind != .boxed) continue;
        const spill = try boxedTagSpill(t, kinds, alloc, ref);
        try a.movzxRegMem8(.rax, .rdi, t.instrs[ref].aux);
        try a.movMemReg(.rsp, @as(i32, @intCast(spill)) * 8, .rax);
    }
}

fn flushBoxedSlot(a: *x64.Assembler, dst_slot: i32, tag_spill: u32, payload: Place) !void {
    // Payload was loaded into its ordinary GP/spill home. The independent tag
    // came from the actual phi source and was snapshotted before destination
    // mutation, so write-only destinations and arbitrary parallel copies work.
    try a.movzxRegMem8(.rax, .rsp, @as(i32, @intCast(tag_spill)) * 8);
    try a.movByteMemReg(.rdi, dst_slot, .rax);
    const poff: i32 = dst_slot * 8;
    switch (payload) {
        .reg => |r| try a.movMemReg(.rsi, poff, r),
        .mem => |d| {
            try a.movRegMem(.rax, .rsp, d);
            try a.movMemReg(.rsi, poff, .rax);
        },
        .xmm => unreachable,
    }
}

fn flushSlot(a: *x64.Assembler, slot: i32, kind: Kind, payload: Place) !void {
    std.debug.assert(kind != .boxed);
    const tag: u8 = switch (kind) {
        .nil => @intFromEnum(value.Tag.nil),
        .bool => TAG_BOOL,
        .float => TAG_FLOAT,
        // `.ptr` (invariant table), `.heap` (per-iteration table — a carried-heap
        // slot's current value or a write-only VALUE_LANE aload result), and
        // `.func` (a guard_func-covered closure, flushed by a head trace's φ
        // writeback — doc 44) all hold a raw *GcHeader payload and re-box as a
        // heap ref.
        .ptr, .heap, .func => TAG_HEAP,
        else => TAG_INT,
    };
    const poff: i32 = slot * 8;
    try a.movByteMemImm(.rdi, slot, tag);
    switch (payload) {
        .reg => |r| try a.movMemReg(.rsi, poff, r),
        .xmm => |x| try a.movsdMemReg(.rsi, poff, x),
        .mem => |d| {
            try a.movRegMem(.rax, .rsp, d);
            try a.movMemReg(.rsi, poff, .rax);
        },
    }
}

/// `dst <- src` between two Places. A mem→mem move routes through rax (raw 8 bytes —
/// kind-agnostic, so it serves int and float spill cells alike). A parallel-move cycle is
/// always single-class (a move connects xmm↔xmm/mem or reg↔reg/mem, never xmm↔reg — see
/// `analyze`), so the float/int endpoint combinations below are the only ones that occur.
fn movePlace(a: *x64.Assembler, dst: Place, src: Place) !void {
    if (Place.eql(dst, src)) return;
    switch (dst) {
        .reg => |r| try placeToReg(a, r, src),
        .xmm => |dx| switch (src) {
            .xmm => |sx| try a.movsdRegReg(dx, sx),
            .mem => |sd| try a.movsdRegMem(dx, .rsp, sd),
            .reg => unreachable, // a float src never lives in a GP register
        },
        .mem => |d| switch (src) {
            .reg => |sr| try a.movMemReg(.rsp, d, sr),
            .xmm => |sx| try a.movsdMemReg(.rsp, d, sx),
            .mem => |sd| {
                try a.movRegMem(.rax, .rsp, sd);
                try a.movMemReg(.rsp, d, .rax);
            },
        },
    }
}

/// One PHI back-edge move. `is_float` records the carried slot's class so the cycle
/// breaker picks the matching scratch (xmm1 for float, rcx for int) — needed because a
/// `.mem` (spill) endpoint alone does not reveal the value's class.
const Move = struct { dst: Place, src: Place, is_float: bool = false };

/// Emit a parallel move (the back-edge PHI shuffle): all `dst <- src` happen as if
/// simultaneously. Acyclic moves go first (Kahn); each remaining disjoint cycle is
/// broken with rcx (saving the cycle's start value), fully, before the next. rax is
/// the mem↔mem scratch inside `movePlace`; the two never collide.
fn emitParallelMove(a: *x64.Assembler, moves: []Move, done: []bool) !void {
    @memset(done, false);
    var left = moves.len;

    var progress = true;
    while (progress and left > 0) {
        progress = false;
        for (moves, 0..) |m, i| {
            if (done[i]) continue;
            var blocked = false;
            for (moves, 0..) |o, j| {
                if (done[j] or j == i) continue;
                if (Place.eql(o.src, m.dst)) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            try movePlace(a, m.dst, m.src);
            done[i] = true;
            left -= 1;
            progress = true;
        }
    }

    for (moves, 0..) |_, start| {
        if (done[start]) continue;
        // Save the cycle's start value in a scratch matching the cycle's class (a cycle
        // is wholly int or wholly float). float → xmm1 (movsd), int → rcx (raw bytes,
        // works for both reg and spill endpoints).
        const fcycle = moves[start].is_float;
        if (fcycle) {
            switch (moves[start].dst) {
                .xmm => |x| try a.movsdRegReg(XMM_SCRATCH1, x),
                .mem => |d| try a.movsdRegMem(XMM_SCRATCH1, .rsp, d),
                .reg => unreachable,
            }
        } else {
            try placeToReg(a, .rcx, moves[start].dst);
        }
        var cur = start;
        while (true) {
            const m = moves[cur];
            done[cur] = true;
            left -= 1;
            var nxt: ?usize = null;
            for (moves, 0..) |o, j| {
                if (done[j]) continue;
                if (Place.eql(o.dst, m.src)) {
                    nxt = j;
                    break;
                }
            }
            if (nxt) |j| {
                try movePlace(a, m.dst, m.src);
                cur = j;
            } else {
                // m.src is the (clobbered) cycle start; restore from the saved scratch.
                if (fcycle) {
                    switch (m.dst) {
                        .xmm => |x| try a.movsdRegReg(x, XMM_SCRATCH1),
                        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH1),
                        .reg => unreachable,
                    }
                } else {
                    try regToPlace(a, m.dst, .rcx);
                }
                break;
            }
        }
    }
    std.debug.assert(left == 0);
}

/// Restore the stack/callee-saved state and return. Self-framed epilogue.
fn emitTeardown(a: *x64.Assembler, frame: i32, callee: []const Reg) !void {
    if (frame > 0) try a.addRegImm32(.rsp, frame);
    var k = callee.len;
    while (k > 0) {
        k -= 1;
        try a.pop(callee[k]);
    }
    try a.pop(.rbx);
    try a.ret();
}

/// Emit a trace's return path. Self-framed (`shared_exit == null`, test path): tear
/// down the per-trace frame + callee-saved and `ret`. Frameless (`shared_exit` set,
/// production path): the shared trampoline owns the frame, so just leave to its
/// teardown. rax is dead scratch at every exit site (the slot flush + result writes
/// are already done), so it is free to hold the target address.
///
/// `slot_addr` (doc 17 Increment 2.3) is the absolute address of this exit's link
/// slot when the exit is *chainable* (the `.link` terminal / a linked-loop-done
/// stub). When set (frameless only), the exit becomes an indirect
/// `movabs rax, slot_addr; jmp qword [rax]` — the slot holds `shared_exit` by default
/// (byte-identical to the direct jump) and a child body entry once `driveChain` arms
/// it. When null, the exit jumps directly to `shared_exit` as in 2.1 (used by the
/// non-chainable `deopt_exit` fallback and `prologue_fail`).
fn emitReturn(a: *x64.Assembler, frame: i32, callee: []const Reg, shared_exit: ?usize, trace_id: u32, slot_addr: ?usize) !void {
    // P-B (doc 17): stamp the final trace's stable id into the result. rdx still holds
    // the *NativeResult at every exit site (it is reserved for the whole body). Baked
    // as an imm32 (the trace's own id here; a linked child overwrites it in 2.3).
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    if (shared_exit) |se| {
        if (slot_addr) |sa| {
            // Indirect through the link slot: load the slot's current target VALUE
            // (default `shared_exit`, or an armed child body entry) into rax, apply the
            // 2.3c-2c forced-yield cap (redirects an armed dispatch to `shared_exit` when
            // the ledger is full), then jump. Loading the value (vs. the old `jmp [slot]`
            // through memory) is what lets the cap inspect and, if needed, override it.
            try a.movRegImm64(.rax, @bitCast(@as(u64, sa)));
            try a.movRegMem(.rax, .rax, 0);
            try emitForcedYieldCheck(a, se);
            try a.jmpReg(.rax);
        } else {
            try a.movRegImm64(.rax, @bitCast(@as(u64, se)));
            try a.jmpReg(.rax);
        }
    } else {
        try emitTeardown(a, frame, callee);
    }
}

/// Absolute address of the link slot for IR instruction `idx`, or null when there is
/// no slot table (self-framed test page). Baked into the exit as an imm64 so the
/// `jmp qword [rax]` reaches the slot regardless of where the heap array lives.
fn slotAddr(slots: []usize, idx: usize) ?usize {
    if (slots.len == 0) return null;
    return @intFromPtr(&slots[idx]);
}

/// 2.3c-2a (doc 17): append one per-transition entry to `NativeResult`'s ledger at
/// index `ledger_len`, then bump the length — the mechanism that lets a fused native
/// span (`C→I→C→…` chained under the shared frame) recover the HIDDEN intermediate
/// exits its single returned `NativeResult` would otherwise drop. Records the cumulative
/// `rbx` counter (`ledger_cum`, scale-8) plus `trace_id` (imm) and the already-in-memory
/// `exit_instr` / `exit_reason` (scale-4 parallel arrays). EVERY exit site calls this
/// AFTER it has written `NativeResult.exit_instr` and `NativeResult.exit_reason` (so the
/// reads below see THIS exit's values — `exit_reason` stays the wrapper-init `.normal`
/// at every site except `prologue_fail`, which writes it first, and `prologue_fail` is
/// terminal so it never rides mid-span) and BEFORE it dispatches (so a chain-source exit
/// records itself before jumping into the child). Clobbers rax (index) and rcx (staging)
/// — both dead scratch at every exit; rbx is the live cumulative counter, rdx the
/// `*NativeResult`.
///
/// Bounds-guarded: when the ledger is at `LEDGER_CAP` the entry is DROPPED (span
/// continues). That is inert while nothing forms a native cycle — 2.3c-2a/b spans are a
/// handful of hops, far below the cap — and 2.3c-2c replaces the drop at chain-SOURCE
/// sites with a forced yield to `shared_exit` so a closed cycle can never silently lose
/// a hop.
fn emitLedgerAppend(a: *x64.Assembler, trace_id: u32, kind: trace_exec.LedgerKind) !void {
    const full = try a.label();
    // rax = ledger_len; drop the entry if already at capacity (unreachable pre-cycle).
    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "ledger_len"));
    try a.cmpRegImm32(.rax, @intCast(trace_exec.LEDGER_CAP));
    try a.jcc(.ae, full);
    // ledger_cum[rax] = rbx  (usize lane, SIB scale 8)
    try a.storeMemSibReg(.rdx, .rax, 8, @offsetOf(NativeResult, "ledger_cum"), .rbx);
    // ledger_id[rax] = trace_id  (u32 lane; imm staged in rcx, scale 4)
    try a.movRegImm64(.rcx, @intCast(trace_id));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_id"), .rcx);
    // ledger_exit[rax] = NativeResult.exit_instr  (8-byte load, low 32 stored)
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "exit_instr"));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_exit"), .rcx);
    // ledger_reason[rax] = NativeResult.exit_reason
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "exit_reason"));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_reason"), .rcx);
    // 2.3c-2c: ledger_kind[rax] = kind  (u32 lane; per-site compile-time constant).
    try a.movRegImm64(.rcx, @intCast(@intFromEnum(kind)));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_kind"), .rcx);
    // 2.3c-2c: ledger_outcome[rax] = .normal (0). A chain-source forced yield
    // (`emitForcedYieldCheck`) overwrites this entry to `.yielded` when the ledger is
    // full; otherwise it stays `.normal` (dispatched-or-terminal, positionally resolved).
    try a.movRegImm64(.rcx, @intCast(@intFromEnum(trace_exec.LedgerOutcome.normal)));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_outcome"), .rcx);
    // ledger_len = rax + 1
    try a.incReg(.rax);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "ledger_len"), .rax);
    a.bind(full);
}

/// 2.3c-2c (doc 17): the forced-yield cap. Emitted at every frameless chain-source
/// dispatch, AFTER `emitLedgerAppend` and BEFORE the `jmp`. On entry `rax` holds the
/// resolved dispatch target — an armed child body entry, or `shared_exit` when the
/// slot is unarmed. Contract:
///   * unarmed (`rax == shared_exit`)         → leave `rax`, fall through (natural terminal / plain deopt);
///   * armed + ledger has room (`len < CAP`)  → leave `rax`, fall through (dispatch into the child);
///   * armed + ledger FULL (`len == CAP`)     → mark the just-appended terminal entry
///       `.yielded` and rewrite `rax = shared_exit`, so a closed native cycle returns to
///       the driver instead of running an unrecordable hop.
/// Leaves `rax` = the (possibly rewritten) jmp target; the caller does `jmp rax`.
/// Clobbers `rcx` (dead scratch — `emitLedgerAppend` just clobbered it). `rbx` (live
/// cumulative counter) and `rdx` (`*NativeResult`) are untouched.
///
/// DEAD until 2.3c-2e closes the `I→C` cycle: pre-cycle every span is ≤2 entries « CAP
/// (32), so the ledger never fills and the yield branch never executes — byte-identical.
fn emitForcedYieldCheck(a: *x64.Assembler, shared_exit: usize) !void {
    const do_jmp = try a.label();
    // rcx = shared_exit. Unarmed target (rax == shared_exit) → nothing to cap.
    try a.movRegImm64(.rcx, @bitCast(@as(u64, shared_exit)));
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.e, do_jmp);
    // Armed. Room left in the ledger (ledger_len < CAP) → dispatch into the child.
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "ledger_len"), @intCast(trace_exec.LEDGER_CAP));
    try a.jcc(.b, do_jmp);
    // Armed AND full → forced yield. Mark the just-appended terminal entry (index
    // ledger_len − 1) `.yielded`, then redirect the dispatch to `shared_exit`.
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "ledger_len"));
    try a.subRegImm32(.rcx, 1);
    // Stage the `.yielded` code in rax (free — reloaded with shared_exit right after),
    // store it into ledger_outcome[rcx] (u32 lane, scale 4).
    try a.movRegImm64(.rax, @intCast(@intFromEnum(trace_exec.LedgerOutcome.yielded)));
    try a.storeMemSibReg(.rdx, .rcx, 4, @offsetOf(NativeResult, "ledger_outcome"), .rax);
    try a.movRegImm64(.rax, @bitCast(@as(u64, shared_exit)));
    a.bind(do_jmp);
}

/// B-3a's unreachable silent tail. `metadata_cell` is a stable compile-time-owned
/// pointer cell; B-3b publishes a `*SilentExitMetadata` into it before patching.
fn emitSilentEpilogue(a: *x64.Assembler, kind: ExitPatchKind, metadata_cell: *usize, shared_exit: usize, trace_id: u32) !void {
    const can_silence = try a.label();
    const owned = try a.label();
    const qualified_done = try a.label();
    const zero_done = try a.label();
    const reset_zero = try a.label();
    const exhausted = try a.label();

    // A reporting prefix cannot be represented by the silent ABI. Continue at the
    // exact original reporting target whenever this span has emitted any row. This
    // also prevents re-entering silence after an off-cycle reporting suffix begins.
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(metadata_cell))));
    try a.movRegMem(.rax, .rax, 0);
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "ledger_len"), 0);
    try a.jcc(.e, can_silence);
    try a.movRegMem(.rax, .rax, @offsetOf(SilentExitMetadata, "reporting_target"));
    try a.jmpReg(.rax);
    a.bind(can_silence);

    // Final round-5 ordering: kind-specific materialization is complete before this
    // store, and every promoted epilogue publishes the exact cumulative rbx baseline.
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_cum"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "silent_active"), 1);

    // rax = *SilentExitMetadata (loaded above).
    // First-cell ownership: preserve the first promoted edge observed in this call.
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "silent_cell"), 0);
    try a.jcc(.ne, owned);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_cell"), .rax);
    a.bind(owned);

    // r8 = dynamic local = current rbx - this body's entry rbx; rcx = edge cell.
    try a.movRegReg(.r8, .rbx);
    try a.subRegMem(.r8, .rdx, @offsetOf(NativeResult, "entry_rbx"));
    try a.movRegMem(.rcx, .rax, @offsetOf(SilentExitMetadata, "summary"));
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_local"), .r8);

    // Round-6 exactness: every firing records ITSELF — its count, its ordinal, and
    // that it was the most recent edge to fire. Zig then indexes the summary by
    // measurement rather than by `(first_phase + t) % len` arithmetic, which is only
    // sound for a single live ring in which every trace owns exactly one phase.
    // r9 = this firing's one-based silent-transition ordinal (the counter at
    // `silent_transitions` is bumped at the tail, after the kind switch).
    try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "firings"));
    try a.movRegMem(.r9, .rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.incReg(.r9);
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_ordinal"), .r9);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_last_cell"), .rax);

    // Preserve dynamic progress evidence independently from aggregated work.
    // Provenance verdict merging needs occurrence count, not merely a sum that
    // could have come from a different number of firings.
    const not_productive = try a.label();
    try a.cmpRegImm32(.r8, 0);
    try a.jcc(.e, not_productive);
    try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "productive_firings"));
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_productive_ordinal"), .r9);
    a.bind(not_productive);

    switch (kind) {
        .deopt => {
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "region_work"), .r8);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.cmpRegImm32(.r8, 0);
            try a.jcc(.ne, reset_zero);
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
        .loop_done_linked => {
            // region_work += 1; selection_work += max(local, 1).
            try a.movRegImm64(.r9, 1);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "region_work"), .r9);
            try a.cmpRegImm32(.r8, 0);
            const local_nonzero = try a.label();
            try a.jcc(.ne, local_nonzero);
            try a.movRegImm64(.r8, 1);
            a.bind(local_nonzero);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.jmp(reset_zero);
        },
        .link_terminal => {
            // Structural only: no work cells; a zero-work link advances the barren run.
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
        .region_bridge => {
            // Structural region work is zero, but selection charges max(local, 1).
            // Zero region work advances the barren run even when local is nonzero.
            try a.cmpRegImm32(.r8, 0);
            const local_nonzero = try a.label();
            try a.jcc(.ne, local_nonzero);
            try a.movRegImm64(.r8, 1);
            a.bind(local_nonzero);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
    }
    a.bind(reset_zero);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "cur_zero_run"), 0);
    a.bind(zero_done);

    try a.incMemQword(.rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.movRegMem(.r8, .rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.cmpRegMem(.r8, .rdx, @offsetOf(NativeResult, "silent_budget"));
    try a.jcc(.ae, exhausted);
    try a.movRegMem(.r8, .rdx, @offsetOf(NativeResult, "cur_zero_run"));
    // Final round-5 barren comparison is absolute: cur_zero_run >= max_barren_run,
    // with max_barren_run staged directly in barren_budget.
    try a.cmpRegMem(.r8, .rdx, @offsetOf(NativeResult, "barren_budget"));
    try a.jcc(.ae, exhausted);

    // Continue through the same per-exit slot as the reporting path.
    try a.movRegMem(.rax, .rax, @offsetOf(SilentExitMetadata, "slot"));
    try a.movRegMem(.rax, .rax, 0);
    try a.jmpReg(.rax);

    a.bind(exhausted);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    try a.movRegImm64(.rax, @bitCast(@as(u64, shared_exit)));
    try a.jmpReg(.rax);
}

fn nativeExitLabel(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize) !x64.Label {
    if (exit_labels[instr_idx]) |l| return l;
    const l = try a.label();
    exit_labels[instr_idx] = l;
    return l;
}

fn jccNativeExit(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize, cc: x64.Cond) !void {
    try a.jcc(cc, try nativeExitLabel(a, exit_labels, instr_idx));
}

fn jmpNativeExit(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize) !void {
    try a.jmp(try nativeExitLabel(a, exit_labels, instr_idx));
}

fn nativeLinkedLoopDoneLabel(a: *x64.Assembler, linked_loop_done_labels: []?x64.Label, instr_idx: usize) !x64.Label {
    if (linked_loop_done_labels[instr_idx]) |l| return l;
    const l = try a.label();
    linked_loop_done_labels[instr_idx] = l;
    return l;
}

fn isNumericForLoopDoneGuard(t: *const Trace, instr_idx: usize) bool {
    return t.isNumericForLoopDoneGuard(instr_idx);
}

/// Part A-v (doc 17 §A2.1/§A2.3): true for a trace-local composite outer-loop
/// re-test whose bridge has at least one dominance-safe slot update to commit.
///
/// "Same-proto outer re-test" is represented without region metadata: committed
/// guard provenance must identify a source-level branch condition owned by the
/// anchor proto, and its post-fetch PC must precede this continuation's anchor.
/// This excludes inlined-callee guards, forward branches, and numeric-for
/// loop-done guards. The dominance-scoped set E is the slot-bound phi set whose
/// update ref was defined before the guard; a slot-bound phi is precisely a value
/// live at the trace successor/back-edge. Internal phis do not name VM slots and
/// are excluded.
pub fn isCompositeBridgeCandidate(t: *const Trace, instr_idx: usize) bool {
    return t.classifyBridgeCandidate(instr_idx);
}

/// The caller-saved GPRs every body callout must preserve (rax/rcx are the
/// JIT's scratch pair and deliberately excluded — a callout result rides
/// through the restore in one of them).
const CALLOUT_SAVED_GP = [_]Reg{ .r8, .r9, .r10, .r11 };

/// Save every SysV caller-saved home the JIT body may keep live across a
/// mid-body callout — rdi/rsi (SoA bases), rdx (*NativeResult), r8–r11, and
/// all allocatable XMMs (xmm2–xmm15) — into the pre-reserved
/// `callout_save_base` frame area. Shared by every `BodyCallout` lowering
/// (doc 23 D4 generalized this out of the href callout); paired with
/// `emitCalloutRestore`.
fn emitCalloutSave(a: *x64.Assembler, alloc: *const Alloc) !void {
    std.debug.assert(alloc.callout_save_count != 0); // save area must be reserved
    var off: u32 = alloc.callout_save_base;
    // rdi (tags base), rsi (payloads base), rdx (*NativeResult).
    try a.movMemReg(.rsp, @intCast(off * 8), .rdi);
    off += 1;
    try a.movMemReg(.rsp, @intCast(off * 8), .rsi);
    off += 1;
    try a.movMemReg(.rsp, @intCast(off * 8), .rdx);
    off += 1;
    // ALL caller-saved GP registers (r8–r11), not just homes — transients in
    // these registers may be live across the callout.
    for (CALLOUT_SAVED_GP) |r| {
        try a.movMemReg(.rsp, @intCast(off * 8), r);
        off += 1;
    }
    // ALL allocatable XMMs (xmm2–xmm15): same reasoning — a transient float
    // live across the callout would be clobbered.
    for (XMM_ALLOC_ORDER) |r| {
        try a.movsdMemReg(.rsp, @intCast(off * 8), r);
        off += 1;
    }
    // Sanity: we used exactly the reserved number of slots.
    std.debug.assert(off == alloc.callout_save_base + alloc.callout_save_count);
}

/// Restore everything `emitCalloutSave` saved, in reverse order. Deliberately
/// never touches rax/rcx (GP scratch) or xmm0/xmm1 (float scratch): a callout
/// stashes its result there so it survives the restore. Restore must happen
/// BEFORE any result check that can side-exit — the deopt flush at
/// `jccNativeExit` relies on slot homes being correct.
fn emitCalloutRestore(a: *x64.Assembler, alloc: *const Alloc) !void {
    var off: u32 = alloc.callout_save_base + alloc.callout_save_count;
    {
        var ri: usize = XMM_ALLOC_ORDER.len;
        while (ri > 0) {
            ri -= 1;
            off -= 1;
            try a.movsdRegMem(XMM_ALLOC_ORDER[ri], .rsp, @intCast(off * 8));
        }
    }
    {
        var ri: usize = CALLOUT_SAVED_GP.len;
        while (ri > 0) {
            ri -= 1;
            off -= 1;
            try a.movRegMem(CALLOUT_SAVED_GP[ri], .rsp, @intCast(off * 8));
        }
    }
    off -= 1;
    try a.movRegMem(.rdx, .rsp, @intCast(off * 8));
    off -= 1;
    try a.movRegMem(.rsi, .rsp, @intCast(off * 8));
    off -= 1;
    try a.movRegMem(.rdi, .rsp, @intCast(off * 8));
    std.debug.assert(off == alloc.callout_save_base);
}

/// Emit the mid-body callout for a float-kernel producer (`fsin`/`fcos`
/// unary; `pow` and doc 25's float `mod`/`idiv` binary — doc 23 D4). The native body calls THE SAME noinline
/// `fmath` kernel tier-0 and tier-1a execute — never an inline SSE
/// re-derivation — so cross-tier bit-identity holds by construction (there is
/// exactly one compiled body of each kernel in the process). SysV float call:
/// operands in xmm0(/xmm1), result in xmm0; the restore only touches xmm2–xmm15 /
/// r8–r11 / rdi/rsi/rdx, so the result rides through it in xmm0. No side-exit:
/// the operand is a proven numeric (dominating `guard_float`/`guard_int`) and
/// the kernel is total (NaN in → NaN out).
fn emitFloatCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
) !void {
    try emitCalloutSave(a, alloc);

    // arg0: the proven-numeric operand into xmm0 (== XMM_SCRATCH0); a proven
    // int promotes via the shared cvtsi2sd discipline. The two-arg kernels
    // (`pow`, and doc 25's float mod/idiv) additionally stage their second
    // operand into xmm1 — staging order is safe because operand homes are
    // never the scratch XMMs.
    const is_binary = ins.op == .pow or ins.op == .mod or ins.op == .idiv;
    try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
    if (is_binary)
        try floatOperandToXmm(a, XMM_SCRATCH1, placeOfRef(alloc, ins.b), kinds[ins.b]);

    // Call the fmath kernel via an absolute address in rax. Same alignment
    // dance as emitHrefCallout: the body runs with rsp % 16 == 8, SysV wants
    // rsp % 16 == 0 at the call.
    const kernel: usize = switch (ins.op) {
        .fsin => @intFromPtr(&fmath.sinRuntime),
        .fcos => @intFromPtr(&fmath.cosRuntime),
        .pow => @intFromPtr(&fmath.powRuntime),
        .mod => @intFromPtr(&fmath.fmodRuntime),
        .idiv => @intFromPtr(&fmath.floordivRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(kernel));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // Result is in xmm0; restore (which leaves xmm0 alone), then home it.
    try emitCalloutRestore(a, alloc);
    switch (placeOfRef(alloc, i)) {
        .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
        .reg => unreachable, // a float result never homes in a GP register
    }
}

/// Doc 35: emit the mid-body callout for `ffloor`/`fceil`. Unlike
/// `emitFloatCallout` (which produces a float in xmm0), these kernels
/// return an i64 in rax (SysV integer return convention). The caller
/// then checks for the out-of-range sentinel (`FLOOR_CEIL_SENTINEL =
/// minInt(i64)`) and side-exits if hit. Result lands in a GP register
/// home, not an XMM.
fn emitFloorCeilCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // arg0: the proven-numeric operand into xmm0.
    try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);

    // Call the fmath kernel (f64→i64, result in rax).
    const kernel: usize = switch (ins.op) {
        .ffloor => @intFromPtr(&fmath.floorRuntime),
        .fceil => @intFromPtr(&fmath.ceilRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(kernel));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // Restore callee-saved regs (rax is the return value, not clobbered
    // by the restore — the restore touches only r8–r11/rdi/rsi/rdx/xmm2+).
    try emitCalloutRestore(a, alloc);

    // Sentinel check: rax == minInt(i64) → side-exit. Use `movabs rcx, sentinel`
    // + `cmp rax, rcx` → je exit. rcx is a scratch register.
    const sentinel: i64 = fmath.FLOOR_CEIL_SENTINEL;
    try a.movRegImm64(.rcx, @bitCast(sentinel));
    try a.cmpRegReg(.rax, .rcx);
    try jccNativeExit(a, exit_labels, i, .e); // equal → out-of-range → side-exit

    // Home the result (an integer) in the allocated GP register or spill.
    try regToPlace(a, placeOfRef(alloc, i), .rax);
}

/// doc 25 D1: inline int `%` / `//`. `cqo`/`idiv` + the floor adjustment
/// reproduce `@mod`/`@divFloor` exactly for every non-special pair; the two
/// specials are handled without ever reaching the (trapping) hardware
/// instruction: a ZERO divisor side-exits at this instruction (tier-0
/// re-raises `DivisionByZero` from the same exit snapshot tier-1a errors
/// at), and `(minInt, -1)` materializes the oracle's DEFINED value inline
/// (`mod` → 0, `idiv` → minInt) and CONTINUES — tier-1a doesn't exit there,
/// so native must not either (codex blocker, doc 25). `idiv` clobbers
/// rdx:rax, and rdx carries the live `*NativeResult`, so rdx is parked in
/// the allocator-owned `div_save` frame slot for the duration; rax/rcx are
/// body scratch. The result canonically ends in rax on every path.
fn emitIntDivMod(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    const save_disp: i32 = @as(i32, @intCast(alloc.div_save.?)) * 8;
    // Park rdx. The mov leaves rdx itself intact, so the zero-divisor exit
    // below still runs with a valid *NativeResult in rdx.
    try a.movMemReg(.rsp, save_disp, .rdx);
    try placeToReg(a, .rax, placeOfRef(alloc, ins.a)); // dividend
    try placeToReg(a, .rcx, placeOfRef(alloc, ins.b)); // divisor
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // y == 0 → tier-0 raises
    // (minInt, -1) probe. rdx is clobbered from here on — no exit until it
    // is restored at the end.
    const go = try a.label();
    const done = try a.label();
    try a.movRegImm64(.rdx, @bitCast(@as(u64, 0x8000_0000_0000_0000)));
    try a.xorRegReg(.rdx, .rax); // 0 iff dividend == minInt
    try a.jcc(.ne, go);
    try a.cmpRegImm32(.rcx, -1);
    try a.jcc(.ne, go);
    // The pair: mod → 0; idiv → minInt (rax already holds the dividend).
    if (ins.op == .mod) try a.xorRegReg(.rax, .rax);
    try a.jmp(done);
    a.bind(go);
    try a.cqo();
    try a.idivReg(.rcx); // rax = trunc quotient, rdx = trunc remainder
    // Floor adjust: rem != 0 and sign(rem) != sign(divisor).
    if (ins.op == .mod) {
        // Result = remainder (+ divisor when adjusting), canonicalized into
        // rax; the truncated quotient is dead → xor scratch.
        const move = try a.label();
        try a.cmpRegImm32(.rdx, 0);
        try a.jcc(.e, move);
        try a.movRegReg(.rax, .rdx);
        try a.xorRegReg(.rax, .rcx);
        try a.jcc(.ns, move); // same signs → no adjust
        try a.addRegReg(.rdx, .rcx); // rem += divisor
        a.bind(move);
        try a.movRegReg(.rax, .rdx);
    } else {
        // Result = quotient (already rax); the remainder is dead after the
        // sign test → clobber it.
        try a.cmpRegImm32(.rdx, 0);
        try a.jcc(.e, done);
        try a.xorRegReg(.rdx, .rcx);
        try a.jcc(.ns, done); // same signs → no adjust
        try a.subRegImm32(.rax, 1); // quot -= 1
    }
    a.bind(done);
    try regToPlace(a, placeOfRef(alloc, i), .rax); // home is never rax/rcx/rdx
    try a.movRegMem(.rdx, .rsp, save_disp); // unpark
}

/// Emit the mid-body callout for an allocating interned-string producer
/// (`tostr_int`/`tostr_num` — doc 24 D5). Same shape as `emitHrefCallout`:
/// save, SysV args (rdi = the baked `*Heap`; the guarded scalar in rsi for the
/// int body, xmm0 for the float body), call the shared noinline `stralloc`
/// body through an absolute pointer, stash the result across the restore, then
/// test-and-exit. A null return is OOM with a CLEAN id stream (no `Heap.link`
/// preceded the fallible step — stralloc.zig's audit): the ordinary deopt exit
/// resumes tier-0 at the header and the replay re-raises the same OOM at the
/// same logical point. On success the `*GcHeader` (kind `.heap`) lands in the
/// op's home; the restore leaves rcx/rax/xmm0 untouched so it rides through.
fn emitTostrCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    heap: *gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // Stage the operand BEFORE overwriting rdi (a `.mem` home reads via rsp,
    // untouched by the save; a `.reg` home is r8–r11, also untouched).
    if (ins.op == .tostr_int) {
        try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
    } else {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
    }
    // arg0: the Heap, baked absolute (stable for the VM's lifetime).
    try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap))));

    // Call the stralloc body via an absolute address in rax. Same alignment
    // dance as emitHrefCallout (body runs with rsp % 16 == 8).
    const body: usize = switch (ins.op) {
        .tostr_int => @intFromPtr(&stralloc.tostrIntRuntime),
        .tostr_num => @intFromPtr(&stralloc.tostrNumRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(body));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax = the interned *GcHeader, or 0 on OOM. The result check must come
    // AFTER the restore (the deopt flush relies on slot homes being correct),
    // so stash it in rcx — scratch, never a home, untouched by the restore.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // 0 → OOM → side-exit
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for a snew-class producer (`ssub`/`srev`/
/// `schar1`/`srep2` — doc 24 D4/c3 — and, doc 26, the case producers
/// `supper`/`slower`, which ride srev's exact arg shape). Same shape as
/// `emitTostrCallout`: save,
/// SysV args (rdi = the baked `*Heap`, then the op's operands), call the
/// shared noinline `stralloc` shim — which calls THE SAME core tier-0 runs —
/// through an absolute pointer, stash the result across the restore, then
/// test-and-exit. A null return collapses BOTH D5 failure arms (OOM, or the
/// tier-0 raise: invalid codepoint / negative count) with a CLEAN id stream
/// (no `Heap.link` preceded the fallible step — stralloc.zig's audit): the
/// ordinary deopt exit resumes tier-0 at the header and the replay re-raises
/// the identical error (or re-hits the OOM) at the same logical point. On
/// success the fresh-or-interned `*GcHeader` (kind `.heap`) lands in the op's
/// home.
///
/// Operand staging is hazard-free in any order: homes are r8–r11 / rbp /
/// r12–r15 / rsp-relative spills — never rsi/rdx/rcx (reserved) — and the
/// save wrote rdi/rsi/rdx to the frame already. rcx doubles as ssub's fourth
/// arg AND the post-call result stash; the call consumes the arg before the
/// stash is written, so there is no conflict.
fn emitSnewCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    heap: *gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // arg1 (rsi): the string `*GcHeader` (ssub/srev/srep2) or the codepoint
    // int (schar1) — `ins.a` in every shape.
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
    switch (ins.op) {
        // ssub(heap, s, i, j): start in rdx, end in rcx (the aux ref — the one
        // three-operand op; analyzeInner extended its liveness to here).
        .ssub => {
            try placeToReg(a, .rdx, placeOfRef(alloc, ins.b));
            try placeToReg(a, .rcx, placeOfRef(alloc, @intCast(ins.aux)));
        },
        // srep2(heap, s, n): count in rdx.
        .srep2 => try placeToReg(a, .rdx, placeOfRef(alloc, ins.b)),
        .srev, .schar1, .supper, .slower => {},
        else => unreachable,
    }
    // arg0: the Heap, baked absolute (stable for the VM's lifetime).
    try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap))));

    // Call the stralloc shim via an absolute address in rax. Same alignment
    // dance as emitHrefCallout (body runs with rsp % 16 == 8).
    const body: usize = switch (ins.op) {
        .ssub => @intFromPtr(&stralloc.ssubRuntime),
        .srev => @intFromPtr(&stralloc.srevRuntime),
        .schar1 => @intFromPtr(&stralloc.schar1Runtime),
        .srep2 => @intFromPtr(&stralloc.srep2Runtime),
        .supper => @intFromPtr(&stralloc.supperRuntime),
        .slower => @intFromPtr(&stralloc.slowerRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(body));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax = the result *GcHeader, or 0 (OOM / tier-0-raise, collapsed). The
    // result check must come AFTER the restore (the deopt flush relies on
    // slot homes being correct), so stash it in rcx — scratch, never a home,
    // untouched by the restore.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // 0 → side-exit, tier-0 replays
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for `scp` (`string.codepoint`, single result —
/// doc 26 D4). A SEPARATE emitter, not a mode flag on `emitSnewCallout`,
/// because the shape differs on every axis that matters: no heap argument
/// (`scpRuntime` is the one non-allocating stralloc shim — args (s, i, j) in
/// rdi/rsi/rdx), an int result rather than a `*GcHeader`, and the failure
/// sentinel is −1 rather than null — compared FULL-WIDTH signed (`cmp r64,
/// imm32` sign-extends, so this is a 64-bit compare; a real codepoint is
/// 0…0x10FFFF and can never alias it). −1 (empty range) side-exits and tier-0
/// replays the call to its nil result — through whatever continuation follows
/// (nil-consuming or raising), which native never needs to know.
///
/// Operand staging is hazard-free: homes are r8–r11 / rbp / r12–r15 /
/// rsp-relative spills — never rdi/rsi/rdx — and `emitCalloutSave` wrote
/// rdi/rsi (the SoA bases) to the frame already, so loading the three arg
/// registers in any order clobbers no unread source.
fn emitScpCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // scpRuntime(s, i, j): the string `*GcHeader` in rdi, start index in rsi,
    // end index in rdx (the aux ref — analyzeInner extended its liveness).
    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));
    try placeToReg(a, .rdx, placeOfRef(alloc, @intCast(ins.aux)));

    // Call the shim via an absolute address in rax. Same alignment dance as
    // emitHrefCallout (body runs with rsp % 16 == 8).
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.scpRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax = the codepoint, or −1 (empty range). The result check must come
    // AFTER the restore (the deopt flush relies on slot homes being correct),
    // so stash it in rcx — scratch, never a home, untouched by the restore.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, -1);
    try jccNativeExit(a, exit_labels, i, .e); // −1 → side-exit, tier-0 replays to nil
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for a doc 30 match op (`sfindp`/`smatch`/
/// `sgmatch`) — the status-result class. One emitter for the three because
/// they share the whole protocol and differ only in arg staging and the
/// success predicate: save, SysV args, call the shared noinline `stralloc`
/// shim (the SAME core every tier runs — P3), stash the i64 result across the
/// restore in rcx (scratch, never a home), then test-and-exit:
///
/// - `sfindp(s, init, pat)` — heap-FREE. Success is a 1-based char index
///   ≥ 1; every failure status is negative and 0 is never returned, so
///   `result ≤ 0 → exit` (full-width signed — `cmp r64, imm32`).
/// - `smatch(heap, s, init, pat)` — fills `heap.match_scratch`. Success is
///   exactly 0 (`≠ 0 → exit`; positives are never returned).
/// - `sgmatch(heap, state, expected_pat)` — one composite gmatch-iterator
///   step, read-only on the state. `expected_pat` is the record-time pattern
///   konst (`t.consts[aux]`), resolved HERE at emission to a baked
///   `*GcHeader` (stable: non-moving GC, consts rooted by the trace) — the
///   shim's identity check replaces `guard_sid` on this path (round-2 B02).
///   Success is exactly 0; a no-match end-of-iteration is a negative status
///   → side-exit, and tier-0's replay produces the loop-ending nil itself.
///
/// Every negative status (doc 30 M03: no_match, malformed, …, bad_init)
/// side-exits with a CLEAN id stream — none of the three shims links — and
/// tier-0 replays the iteration, re-raising any matcher error itself at the
/// same logical point.
///
/// Operand staging is hazard-free in any order: homes are r8–r11 / rbp /
/// r12–r15 / rsp-relative spills — never the arg registers — and the save
/// wrote rdi/rsi/rdx to the frame already. rcx doubles as smatch's fourth
/// arg AND the result stash (the ssub precedent): the call consumes the arg
/// before the stash is written.
fn emitMatchCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    t: *const Trace,
    heap: ?*gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    switch (ins.op) {
        // sfindpRuntime(s, init, pat): heap-free three-arg shape.
        .sfindp => {
            try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
            try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));
            try placeToReg(a, .rdx, placeOfRef(alloc, @intCast(ins.aux)));
        },
        // smatchRuntime(heap, s, init, pat): heap first, pattern in rcx.
        .smatch => {
            try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
            try placeToReg(a, .rdx, placeOfRef(alloc, ins.b));
            try placeToReg(a, .rcx, placeOfRef(alloc, @intCast(ins.aux)));
            try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap.?))));
        },
        // sgmatchRuntime(heap, state, expected_pat): the pattern is baked.
        .sgmatch => {
            try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
            const pat = t.consts[@intCast(ins.aux)].asHeap();
            try a.movRegImm64(.rdx, @bitCast(@as(u64, @intFromPtr(pat))));
            try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap.?))));
        },
        else => unreachable,
    }

    const body: usize = switch (ins.op) {
        .sfindp => @intFromPtr(&stralloc.sfindpRuntime),
        .smatch => @intFromPtr(&stralloc.smatchRuntime),
        .sgmatch => @intFromPtr(&stralloc.sgmatchRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(body));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // The result check must come AFTER the restore (the deopt flush relies on
    // slot homes being correct), so stash the status in rcx.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    if (ins.op == .sfindp)
        try jccNativeExit(a, exit_labels, i, .le) // ≤ 0 → side-exit
    else
        try jccNativeExit(a, exit_labels, i, .ne); // ≠ 0 → side-exit
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for `scap_str` (doc 30): intern the span in
/// scratch slot `ins.b`. The snew protocol verbatim — save, args (rdi = the
/// baked `*Heap`, rsi = the slot IMMEDIATE), call `scapStrRuntime`, stash the
/// `*GcHeader` across the restore, null → side-exit (OOM; no `Heap.link`
/// preceded the failure, so the id stream is clean and tier-0 re-hits the
/// same OOM on replay). Emitted even when the capture is dead (B02: `.alloc`
/// ops execute for id-stream fidelity — tropt never DCEs it).
fn emitScapStrCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    heap: *gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    try a.movRegImm64(.rsi, @as(i64, ins.b));
    try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap))));

    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.scapStrRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // null → side-exit (OOM)
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for `str2num_i`/`str2num_f` (doc 30): the ONE
/// `arith.toNumber` core on a proven-string operand. `str2numRuntime` returns
/// the two-eightbyte `Str2NumResult` in rax (status) : rdx (raw value bits) —
/// SysV small-struct return. Both must survive the restore, and the restore
/// overwrites rdx (the parked `*NativeResult`), so the stash is: status →
/// rcx, value bits → rax (neither is touched by the restore). The recorder
/// baked the OBSERVED kind into the op — status ≠ expected (wrong kind, or
/// −1 = not a number) side-exits, and tier-0's replay produces the other
/// kind / the nil / the raise itself. Heap-free, pure, no id-stream impact.
fn emitStr2NumCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));

    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.str2numRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    try a.movRegReg(.rcx, .rax); // status
    try a.movRegReg(.rax, .rdx); // raw value bits
    try emitCalloutRestore(a, alloc);
    const expected: i32 = if (ins.op == .str2num_i) 0 else 1;
    try a.cmpRegImm32(.rcx, expected);
    try jccNativeExit(a, exit_labels, i, .ne); // kind mismatch / non-number → exit
    // Home the value: int → GP/spill via the shared path; float → the raw
    // f64 bits movq into the XMM home (or a raw 8-byte spill store — bits
    // are bits). A float result never homes in a GP register.
    if (ins.op == .str2num_i) {
        try regToPlace(a, placeOfRef(alloc, i), .rax);
    } else switch (placeOfRef(alloc, i)) {
        .xmm => |x| try a.movqXmmReg(x, .rax),
        .mem => |d| try a.movMemReg(.rsp, d, .rax),
        .reg => unreachable,
    }
}

/// Emit the mid-body callout for `sgm_setpos` (doc 30 §6): commit the gmatch
/// cursor into the state's slot 3 — the deferred store, sunk below every
/// guard, so reaching it means the iteration is committed. `sgmSetposRuntime`
/// re-verifies the B03 cell shape (in-lane `.value` int cell) and writes an
/// int over an int — no GC barrier, no allocation. 0 = written; a negative
/// status (bad_layout — the shape raced away) side-exits with NOTHING
/// written, and tier-0 replays the whole iteration. Value-less: no home.
fn emitSgmSetposCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));

    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.sgmSetposRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .ne); // bad_layout → side-exit
}

/// Emit the per-iteration hash-cell resolution call-out for a `.heap`-rooted href.
/// The sequence saves all live caller-saved homes (rdi/rsi SoA bases + GP + XMM)
/// into the pre-reserved frame area, sets up SysV ABI arguments, calls
/// `resolveHashCell`, restores, checks the result, and stores the cell pointer in
/// the href's home. On a 0 return (cell not found) the trace side-exits.
fn emitHrefCallout(
    a: *x64.Assembler,
    t: *const Trace,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    _ = kinds;

    // 1. Save all caller-saved homes into the reserved frame area.
    try emitCalloutSave(a, alloc);

    // 2. Set up SysV ABI arguments:
    //    rdi = *GcHeader (from the aload's home — the .heap table pointer)
    //    rsi = key tag bits (compile-time constant from the trace's const pool)
    //    rdx = key payload bits (compile-time constant)
    //
    // The href's ins.b is a konst instruction; the konst's aux indexes t.consts.
    const konst_ins = t.instrs[ins.b];
    const key = t.consts[@intCast(konst_ins.aux)];
    const key_tag: u64 = @intFromEnum(key.tag);
    const key_payload: u64 = key.payload.bits;

    // Load the table *GcHeader into rdi (arg0). The aload result (ins.a) might be
    // in a register home, a spill, or might have been clobbered if its home was rdi
    // — but we already saved rdi, and refBaseReg uses .rax as scratch, which is fine
    // since we haven't loaded args into it yet.
    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));

    // Key tag and payload are compile-time constants.
    try a.movRegImm64(.rsi, @bitCast(key_tag));
    try a.movRegImm64(.rdx, @bitCast(key_payload));

    // 3. Call resolveHashCell via an absolute address in rax.
    // The JIT body runs with rsp % 16 == 8 (return-address push from the
    // C-ABI entry call). SysV requires rsp % 16 == 0 at a `call` site, so
    // bump the stack by 8 to fix alignment, then undo after the call.
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@intFromPtr(&resolveHashCell)));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax now holds the cell pointer (or 0 on miss). The result check must
    // come AFTER the restore (the deopt flush at jccNativeExit relies on slot
    // homes being correct), so stash rax in rcx — scratch, not a home, and
    // emitCalloutRestore never touches it — then restore, then test rcx.
    try a.movRegReg(.rcx, .rax);

    // 5. Restore everything saved in step 1 (rcx/xmm0 untouched).
    try emitCalloutRestore(a, alloc);

    // 6. Check the result (stashed in rcx). 0 = cell not found → side-exit.
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // ZF=1 → rcx==0 → miss

    // 7. Store the cell pointer (in rcx) into the href's home.
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// `guard_absent` (doc 45 D7): prove the runtime raw lookup `t[k]` is still nil,
/// side-exiting when a value (or a metatable, or a non-table) has appeared.
///
/// The common numeric shape is INLINED — every check reads the table's LIVE
/// layout through the header pointer (lane, asize, data/present, hash size);
/// nothing is pinned to the recording's addresses, so lane widening, growth and
/// rehash between iterations are all observed truthfully:
///
///   1. `header.type == .table` and `metatable == null` — else the guard fails
///      (a metatable would dispatch `__index`; absence may not suppress it).
///   2. grid lane → full-lookup callout (virtual rows are never nil).
///   3. `key <u asize` (LuaJIT-style unsigned compare — rejects negative keys
///      via wrap, same as `ArrayPart.inArray`): in-array absence is the lane's
///      own nil encoding — bool lane in-band byte 0, `.value` lane nil tag,
///      numeric lanes a CLEAR presence-bitmap bit. All reads are behind the
///      bounds check; the bitmap is only dereferenced for bitmap lanes.
///   4. out of array: an EMPTY hash (live-entry count 0) proves absence with
///      no lookup at all — the binary-trees leaf shape `t[2]` on `{item}`.
///      A non-empty hash falls back to the callout (the key may be resident).
///
/// String keys always take the full-lookup callout (interning gives them no
/// cheap inline test). The callout is `table_runtime.isAbsent` — the SAME
/// predicate tier-1a runs, so every tier agrees by construction. The callout
/// preserves live homes via the shared save/restore ABI (`bodyCalloutOf` maps
/// this op, so the save area is reserved whenever the trace contains one —
/// even though the inline path usually skips the call).
fn emitGuardAbsent(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    const is_int_key = kinds[ins.b] == .int;
    const pass = try a.label();
    const callout = try a.label();

    if (is_int_key) {
        const lane_off: i32 = ArrLayout.array_base + ArrLayout.lane;
        // rax = table header. rax/rcx are the body scratch pair (never homes).
        try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
        // 1. type + metatable (no qword cmp-mem-imm encoder → load and test).
        try a.cmpByteMemImm(.rax, HEADER_TYPE_OFF, TABLE_TYPE);
        try jccNativeExit(a, exit_labels, i, .ne); // not a table → guard fails
        try a.movRegMem(.rcx, .rax, METATABLE_OFF);
        try a.cmpRegImm32(.rcx, 0);
        try jccNativeExit(a, exit_labels, i, .ne); // metatable appeared → guard fails
        // 2. grid meta-lane → full lookup.
        try a.cmpByteMemImm(.rax, lane_off, @intCast(GRID_LANE));
        try a.jcc(.e, callout);
        // 3. bounds: key <u asize?
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.cmpRegMem(.rcx, .rax, ArrLayout.array_base + ArrLayout.asize);
        const in_array = try a.label();
        try a.jcc(.b, in_array);
        // 4. out of array: empty hash proves absence; else the callout decides.
        try a.cmpDwordMemImm(.rax, HASH_SIZE_FROM_HEADER, 0);
        try a.jcc(.ne, callout);
        try a.jmp(pass);

        a.bind(in_array);
        const bool_lane = try a.label();
        const value_lane = try a.label();
        try a.cmpByteMemImm(.rax, lane_off, @intCast(BOOL_LANE));
        try a.jcc(.e, bool_lane);
        try a.cmpByteMemImm(.rax, lane_off, @intCast(VALUE_LANE));
        try a.jcc(.e, value_lane);
        // Numeric lanes (i8…i64/u8/f64): presence bitmap — a SET bit means the
        // slot holds a value, so the absence guard fails.
        try a.movRegMem(.rax, .rax, ArrLayout.array_base + ArrLayout.present);
        try a.btMemReg(.rax, 0, .rcx);
        try jccNativeExit(a, exit_labels, i, .b); // CF=1 → present → guard fails
        try a.jmp(pass);

        a.bind(bool_lane); // in-band encoding: 0 = absent, 1 = false, 2 = true
        try a.movRegMem(.rax, .rax, ArrLayout.array_base + ArrLayout.data);
        try a.loadRegMemSib(.rax, .rax, .rcx, 1, false, 0); // movzx byte
        try a.cmpRegImm32(.rax, 0);
        try jccNativeExit(a, exit_labels, i, .ne); // non-zero byte → present
        try a.jmp(pass);

        a.bind(value_lane); // 16-byte tagged Values, nil in-band → tag probe
        try a.movRegMem(.rax, .rax, ArrLayout.array_base + ArrLayout.data);
        try a.shlRegImm8(.rcx, 4); // idx*16 (SIB can't scale by 16)
        try a.addRegReg(.rcx, .rax); // rcx = &data[idx]
        try a.cmpByteMemImm(.rcx, VALUE_TAG_OFF, TAG_NIL);
        try jccNativeExit(a, exit_labels, i, .ne); // non-nil tag → present
        try a.jmp(pass);
    }

    // Slow path (string keys unconditionally; int keys on grid / non-empty-hash
    // fallback): the shared full semantic lookup, THE predicate tier-1a runs.
    a.bind(callout);
    try emitCalloutSave(a, alloc);
    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));
    const runtime = @import("table_runtime.zig");
    const helper = if (is_int_key) @intFromPtr(&runtime.absentInt) else @intFromPtr(&runtime.absentString);
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, helper)));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // helper says "not absent" → guard fails
    a.bind(pass);
}

fn emitHStore(a: *x64.Assembler, kinds: []const Kind, alloc: *const Alloc, ins: trace.IrInstr) !void {
    if (kinds[ins.b] == .float) {
        // Stage the value into XMM_SCRATCH0 first (independent of rax/rcx), then
        // write tag + payload through the cell pointer.
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const creg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.movByteMemImm(creg, VALUE_TAG_OFF, TAG_FLOAT);
        try a.movsdMemReg(creg, VALUE_PAYLOAD_OFF, XMM_SCRATCH0);
    } else {
        // int OR bool (doc 43 P1). Load the value before resolving the cell
        // pointer: a spilled href resolves through rcx (never rax), and value
        // homes are outside rax/rcx. A `.bool` value is a clean 0/1 GP by
        // convention, so the raw 8-byte payload store reproduces
        // `Value.boolean`'s full-width layout bit-for-bit (as the int arm does
        // `Value.int`'s).
        try placeToReg(a, .rax, placeOfRef(alloc, ins.b));
        const creg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.movByteMemImm(creg, VALUE_TAG_OFF, if (kinds[ins.b] == .bool) TAG_BOOL else TAG_INT);
        try a.storeMemReg(creg, 8, VALUE_PAYLOAD_OFF, .rax);
    }
}

fn emitAStore(a: *x64.Assembler, t: *const Trace, kinds: []const Kind, alloc: *const Alloc, ins: trace.IrInstr) !void {
    const aref_ins = t.instrs[ins.a];
    if (ins.aux == VALUE_LANE) {
        // doc 32: `.value`-lane store — write a full tagged Value (tag byte + 8-byte
        // payload) and **no presence bit**; the lane has no bitmap (nil is in-band,
        // and the recorder aborts a nil store). Every value fits a type-erased lane,
        // so unlike the narrow lanes there is no width/range concern: the tag is what
        // preserves integer-vs-float identity, exactly as `emitHStore` does for a hash
        // cell. The seven padding bytes are left untouched — nothing observes them
        // (equality compares semantic fields; keyframe capture goes through
        // `array.get`), and tier-0's `encode` does not define them either.
        //
        // Address in rcx, computed index-first for the same reason as the VALUE_LANE
        // aload: `arrayFieldReg(…, .rax)` may return `.rax`, so the data base must be
        // fetched only after the index is already parked in scratch rcx.
        if (kinds[ins.b] == .float) {
            // Stage the value into XMM_SCRATCH0 before touching rax/rcx.
            try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
            const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
            try a.movRegReg(.rcx, ireg);
            try a.shlRegImm8(.rcx, 4);
            const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
            try a.addRegReg(.rcx, datareg); // rcx = &data[idx0] (Value*)
            try a.movByteMemImm(.rcx, VALUE_TAG_OFF, TAG_FLOAT);
            try a.movsdMemReg(.rcx, VALUE_PAYLOAD_OFF, XMM_SCRATCH0);
        } else {
            const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
            try a.movRegReg(.rcx, ireg);
            try a.shlRegImm8(.rcx, 4);
            const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
            try a.addRegReg(.rcx, datareg); // rcx = &data[idx0] (Value*)
            // Load the value into rax only now — the data base is already consumed,
            // and rcx (the address) is scratch so no value home can alias it.
            try placeToReg(a, .rax, placeOfRef(alloc, ins.b));
            try a.movByteMemImm(.rcx, VALUE_TAG_OFF, TAG_INT);
            try a.storeMemReg(.rcx, 8, VALUE_PAYLOAD_OFF, .rax);
        }
        return;
    }
    if (ins.aux == F64_LANE) {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, 8, 0);
        try a.movsdMemReg(.rax, 0, XMM_SCRATCH0);
        const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
        const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.btsMemReg(preg, 0, pireg);
    } else if (ins.aux == BOOL_LANE) {
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, 1, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.incReg(.rcx);
        try a.storeMemReg(.rax, 1, 0, .rcx);
    } else {
        const w = intLaneWidth(ins.aux);
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, w, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.storeMemReg(.rax, w, 0, .rcx);

        const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
        const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.btsMemReg(preg, 0, pireg);
    }
}

fn emitGStore(a: *x64.Assembler, t: *const Trace, alloc: *const Alloc, ins: trace.IrInstr) !void {
    const gcell_ins = t.instrs[ins.a];
    const garow_ins = t.instrs[gcell_ins.a];
    if (ins.aux == F64_LANE) {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
        const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, flatreg, 8, 0);
        try a.movsdMemReg(.rax, 0, XMM_SCRATCH0);
    } else {
        const w = intLaneWidth(ins.aux);
        const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
        const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, flatreg, w, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.storeMemReg(.rax, w, 0, .rcx);
    }
    const preg = try arrayFieldReg(a, alloc, garow_ins.a, .present, .rax);
    const pflat = try refBaseReg(a, alloc, ins.a, .rcx);
    try a.btsMemReg(preg, 0, pflat);
}

fn emitPhiValueFlush(a: *x64.Assembler, t: *const Trace, kinds: []const Kind, alloc: *const Alloc, p: trace.IrInstr) !void {
    const ref: usize = @intCast(p.b);
    const kind = kinds[ref];
    if (kind == .boxed) {
        try flushBoxedSlot(a, @as(i32, @intCast(p.aux)), try boxedTagSpill(t, kinds, alloc, ref), placeOfRef(alloc, ref));
    } else {
        try flushSlot(a, @as(i32, @intCast(p.aux)), kind, placeOfRef(alloc, ref));
    }
}

fn emitLinkedLoopDoneSnapshot(
    a: *x64.Assembler,
    t: *const Trace,
    kinds: []const Kind,
    alloc: *const Alloc,
    exit_instr: usize,
) !void {
    // Doc 39: unreachable for a peeled trace — the linked branch that creates
    // this stub's label is gated on `!t.peeled` in `lower`.
    std.debug.assert(!t.peeled);
    var si = exit_instr + 1;
    while (si < t.instrs.len) : (si += 1) {
        const p = t.instrs[si];
        switch (p.op) {
            .astore => try emitAStore(a, t, kinds, alloc, p),
            .hstore => try emitHStore(a, kinds, alloc, p),
            // Doc 43 P5: a loop-done-sunk closed-cell store — same Value-cell
            // shape as hstore, same emitter.
            .ustore => try emitHStore(a, kinds, alloc, p),
            .gstore => try emitGStore(a, t, alloc, p),
            .phi, .loop, .link => break,
            // Defensive belt: the linked branch is only emitted when
            // `loopDoneSnapshotSupported` accepted the range — now a closed
            // whitelist of exactly the store arms above — so ANY other op here
            // means the gate and this walk drifted apart. Fail the compile
            // rather than emit a snapshot that silently skips a store (the
            // sgm_setpos un-advanced-cursor bug class, generalized).
            else => return error.UnsupportedLoopDoneStore,
        }
    }

    const guard = t.instrs[exit_instr];
    const for_ins = t.anchor.proto.code[trace.guardSourcePc(guard).?];
    const visible_var_slot: i32 = @as(i32, @intCast(for_ins.a)) + 3;
    for (t.instrs) |p| {
        if (p.op != .phi or p.aux == trace.PHI_INTERNAL) continue;
        if (p.aux == visible_var_slot) continue;
        try emitPhiValueFlush(a, t, kinds, alloc, p);
    }
}

/// Part A-v (doc 17 §A2.1): materialize the bridge's compile-time set E.
/// Slot-bound phis are the trace successor's live VM-slot writebacks; only an
/// update defined before `exit_instr` dominates that guard. Post-guard phis and
/// internal optimizer phis are deliberately excluded.
fn emitCompositeBridgeSnapshot(
    a: *x64.Assembler,
    t: *const Trace,
    kinds: []const Kind,
    alloc: *const Alloc,
    exit_instr: usize,
) !void {
    var emitted = t.bridgeEmissions(exit_instr);
    while (emitted.next()) |p| {
        try emitPhiValueFlush(a, t, kinds, alloc, p);
    }
}

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
