//! Kind proving / admission for tier-1b native codegen (split from
//! `nativegen.zig`, file-split pass): `proveKinds` walks a committed
//! trace's IR and either proves every SSA ref a native-lowerable `Kind`
//! (int/bool/float/ptr/... — see `nativegen_artifact.Kind`) or rejects
//! the trace back to tier-1a. Fail-closed: anything unproven bails.

const std = @import("std");
const value = @import("value.zig");
const table = @import("table.zig");
const gc = @import("gc.zig");
const stralloc = @import("stralloc.zig");
const fmath = @import("fmath.zig");
const trace_ir = @import("trace_ir.zig");
const trace = trace_ir;
const trace_code = @import("trace_code.zig");
const layout = @import("nativegen_layout.zig");
const Value = value.Value;
const Trace = trace_code.TraceCode;
const Kind = @import("nativegen_artifact.zig").Kind;
const laneKind = layout.laneKind;
const konstFitsLane = layout.konstFitsLane;
const VALUE_LANE = layout.VALUE_LANE;

/// Task #29: one bit per lane ordinal for the per-value `fits_mask`. Lane
/// ordinals are tiny (`arr.Lane` has < 16 members); anything outside [0, 15]
/// is malformed and yields null (fail closed).
fn laneBit(aux: i32) ?u16 {
    if (aux < 0 or aux > 15) return null;
    return @as(u16, 1) << @intCast(aux);
}

/// An untyped slot value may enter native code only as an boxed-value
/// copy: every semantic use must be the update of a slot-bound phi. No guard,
/// arithmetic, truthiness, heap operation, or internal phi may inspect it.
fn boxedPassThroughOnly(t: *const Trace, ref: usize) bool {
    if (t.instrs.len == 0) return false;
    const terminal = t.instrs[t.instrs.len - 1].op;
    if (terminal != .terminal and terminal != .link) return false;
    var copied = false;
    for (t.instrs, 0..) |ins, i| {
        if (i == ref) continue;
        if (ins.op == .phi and ins.aux >= 0 and ins.b == ref) {
            copied = true;
            continue;
        }
        const reads = operandReads(ins);
        if ((reads.a and ins.a == ref) or (reads.b and ins.b == ref)) return false;
        // phi.b is intentionally absent from operandReads because it is consumed
        // by the terminal shuffle. For a slot-bound phi, `a` is metadata (usually
        // zero; a peeled steady-phi association otherwise), not a value use. Only
        // internal phi init/update operands inspect a value.
        if (ins.op == .phi and (ins.b == ref or (ins.aux == trace.PHI_INTERNAL and ins.a == ref))) return false;
    }
    return copied;
}

/// Doc 45 D6: true iff `ref` (a slot_load in a PRECISE trace) has no semantic
/// use at all — no instruction operand reads it, no φ names it, no hidden
/// reader (dyn-href root, ternary `aux` ref) touches it. Such a load exists
/// only so full-window snapshots can reference a dead anchor slot; it is
/// admitted as kind `.none` and every exit materializer skips it. The hidden-
/// reader list mirrors `analyzeInner`'s liveness extensions — an op Pass B
/// accepts while reading a ref invisible to BOTH `operandReads` and this list
/// would be a soundness hole, so keep the two in lockstep.
fn snapshotOnlyLoad(t: *const Trace, ref: usize) bool {
    for (t.instrs, 0..) |ins, i| {
        if (i == ref) continue;
        const reads = operandReads(ins);
        if ((reads.a and ins.a == ref) or (reads.b and ins.b == ref)) return false;
        // A φ mentioning the ref anywhere (writeback `b`, internal init /
        // steady association `a`) is a use.
        if (ins.op == .phi and (ins.a == ref or ins.b == ref)) return false;
        // href's operandReads is {false,false} (seeded-slab discipline), but a
        // dynamically-rooted href DOES read its table root (`a`); count the
        // key (`b`) too, conservatively.
        if (ins.op == .href and (ins.a == ref or ins.b == ref)) return false;
        // Ternary ops whose third ref rides `aux` (the analyzeInner list).
        if ((ins.op == .ssub or ins.op == .scp or ins.op == .sfindp or ins.op == .smatch) and
            ins.aux >= 0 and @as(usize, @intCast(ins.aux)) == ref) return false;
    }
    return true;
}

/// Forward type-proof over the linear SSA. Fills `kinds` (and `slot_of`, the
/// register slot of each `slot_load`) and returns `true` iff every value is a
/// proven supported value or a use-gated boxed pass-through.
pub fn proveKinds(gpa: std.mem.Allocator, t: *const Trace, kinds: []Kind, slot_of: []i32) bool {
    const n = t.instrs.len;
    @memset(kinds, .none);
    @memset(slot_of, -1);

    // Pass A: record each slot_load's register slot, and which slot_loads a
    // `guard_int` covers. A guard on a *slot_load* is the type check we hoist to a
    // single tag-check in the prologue (lowering reads the tag straight from
    // `regs[slot]`), so mark it. A guard on a *derived* value (e.g. an `add`/`mul`
    // result) is not hoisted: it is validated in Pass B against the value's
    // already-proven kind and lowered to nothing — a derived int (int-op-of-ints)
    // can never fail the guard. So we no longer bail on a non-slot_load operand.
    const guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(guarded);
    @memset(guarded, false);
    // Parallel to `guarded`, but for `guard_float` (Phase D): a slot_load it covers
    // is a float input → classified `.float`, hoisted to a single TAG_FLOAT prologue
    // check + a `movsd` slot load. A guard_float on a *derived* float (an arith
    // result) is validated in Pass B against the already-proven kind and lowers to
    // nothing — exactly like the derived guard_int relaxation.
    const float_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(float_guarded);
    @memset(float_guarded, false);
    // Parallel to `guarded`, but for `guard_table`: a slot_load it covers is the
    // table value → classified `.ptr` (invariant, loaded once).
    const table_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(table_guarded);
    @memset(table_guarded, false);
    // Parallel to `table_guarded`, but for `guard_func` (U1, cross-frame): a
    // slot_load it covers is the snapshot callee value → classified `.func`
    // (invariant closure pointer, identity-checked once in the prologue).
    const func_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(func_guarded);
    @memset(func_guarded, false);
    // Parallel to `func_guarded`, but for `guard_builtin` (the pure-builtin identity
    // guard): a slot_load it covers is the callee-snapshot value → classified
    // `.native` (invariant native pointer, identity-checked once in the prologue
    // against the recorded `RecordedBuiltin` tag).
    const pure_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(pure_guarded);
    @memset(pure_guarded, false);
    // Parallel to `table_guarded`, but for `guard_string` (doc 24 c3): a slot_load
    // it covers is an OBSERVED string input → classified `.heap` (an invariant raw
    // `*GcHeader`), with the type pinned once in the prologue (TAG_HEAP tag-lane
    // check + `header.type == string`) exactly as guard_table pins a table. The
    // slot is read-only in the trace (a carried string bails in classification),
    // so one prologue check covers the whole native run.
    const string_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(string_guarded);
    @memset(string_guarded, false);
    // Per-value string PROVENANCE (doc 24 c3): true iff the ref is statically a
    // string — a `tostr_*`/snew producer result or a string-guarded slot_load.
    // This is what `slen` and the snew string operands (`ssub.a`, `srev.a`,
    // `srep2.a`) require; kind `.heap` alone is NOT enough (a carried-heap slot's
    // `.heap` is a table).
    const is_string = gpa.alloc(bool, n) catch return false;
    defer gpa.free(is_string);
    @memset(is_string, false);
    // Per-aref: has a `guard_bounds` on this aref been proven before we reach a
    // `guard_present`/`aload`? [I4 / review] `present` is non-null only when
    // `len > 0`, which a passing `guard_bounds` (idx0 <u len) implies — so the
    // bitmap `bt` and the data load are memory-safe ONLY behind a dominating
    // bounds check. The recorder emits that order; this enforces it on the IR we
    // were handed (a malformed/deserialized trace must not segfault).
    const bounds_ok = gpa.alloc(bool, n) catch return false;
    defer gpa.free(bounds_ok);
    @memset(bounds_ok, false);
    // Per-value: which narrow int lanes has a `guard_fits` proven this value
    // fits? [B4b] An int-lane astore requires the EXACT lane's bit — native
    // cannot widen the lane mid-run (it has no allocate-and-repack path), so
    // the recorder emits a `guard_fits` ahead of every int-lane store and the
    // tier-1a oracle side-exits identically when the value would overflow the
    // lane. Without a covering same-lane guard_fits an int-lane astore bails
    // the whole trace to tier-1a. A BITSET (task #29, codex) rather than a
    // bool: with per-chain lanes one value may feed stores into arrays of
    // different widths, each store paired with its own width proof — a single
    // "last guard wins" cell would reject a legitimate order-dependent subset,
    // and a lane-blind bool would let an i64 proof cover an i8 store.
    const fits_mask = gpa.alloc(u16, n) catch return false;
    defer gpa.free(fits_mask);
    @memset(fits_mask, 0);
    // Per-gcell (doc 14): has a `guard_gcol` proven this cell's column in
    // `[1, stride]`? A grid `gload`/`gstore`/`guard_gpresent` touches `data`/
    // `present` at the flat index `gcell` computed (`row0*stride + col-1`), which
    // is in `[0, rows*stride)` — and thus inside the `cap*stride` buffer — only
    // when BOTH the row bound (`guard_bounds` on the `garow`) and this column bound
    // hold. Without a covering guard_gcol a grid memory op bails to tier-1a.
    const gcol_ok = gpa.alloc(bool, n) catch return false;
    defer gpa.free(gcol_ok);
    @memset(gcol_ok, false);
    // Per-konst: is this `.konst` ref used as the *key operand* of an `href` (H1)?
    // The key is the interned field-name string — a heap const, which the `.konst`
    // arm below would otherwise reject (`else => return false`). An href reads its
    // cell from the seeded slab slot, never from the key, so the key carries no
    // native value: a marked heap-key konst is accepted as `.none` and `lower`
    // emits nothing for it. Any OTHER use of a heap const (one feeding a non-href
    // op) stays unmarked and bails, exactly as before.
    const href_key = gpa.alloc(bool, n) catch return false;
    defer gpa.free(href_key);
    @memset(href_key, false);

    // Task #29 (codex): reject duplicate `slot_load`s of one VM slot. The
    // recorder deduplicates real inputs, so a dup only appears in a malformed
    // or handcrafted trace — and allocation keeps ONE `SlotInfo` per VM slot
    // (one prologue lane/type check), so two refs carrying independent
    // per-ref root bindings could disagree while only one is runtime-checked.
    var slot_seen: std.StaticBitSet(0x10000) = .empty;

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                if (slot_seen.isSet(@intCast(ins.aux))) return false;
                slot_seen.set(@intCast(ins.aux));
                slot_of[i] = ins.aux;
            },
            // H1: mark this href's key operand so the `.konst` arm accepts the
            // interned heap-string key (its only use). Full href validation is in
            // Pass B; here we only need the forward-collected key marking.
            .href => {
                const r = ins.b;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .konst) href_key[r] = true;
            },
            .guard_int => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .slot_load) guarded[r] = true;
                // Doc 40 (reverse peel): a numeric guard on an INTERNAL φ whose
                // init is a slot_load hoists through the φ onto that slot_load —
                // the same prologue-tag-check discipline, one step removed. The
                // shape is the reset-to-int glue (`k = n`): the run-once region
                // loads `n` with no guard of its own (tier-0's move is untyped),
                // and the steady body's guard on the φ is the ONLY check between
                // a differently-typed future entry and the int steady loop.
                // Hoisting it makes the init a proven entry input (prologue
                // check + home); the body guard then discharges against the
                // φ's proven kind exactly like any derived guard, because every
                // value the φ can carry — init (prologue-checked) and update
                // (kind-equality-checked below) — is proven. A future entry
                // whose slot fails the hoisted check takes prologue_fail →
                // tier-1a, where the φ guard is a real per-iteration check.
                if (t.instrs[r].op == .phi and t.instrs[r].aux == trace.PHI_INTERNAL) {
                    const init = t.instrs[r].a;
                    if (init < r and t.instrs[init].op == .slot_load) guarded[init] = true;
                }
            },
            .guard_float => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .slot_load) float_guarded[r] = true;
                // Doc 40: the float-direction twin of the guard_int φ-hoist.
                if (t.instrs[r].op == .phi and t.instrs[r].aux == trace.PHI_INTERNAL) {
                    const init = t.instrs[r].a;
                    if (init < r and t.instrs[init].op == .slot_load) float_guarded[init] = true;
                }
            },
            // doc 34: guard_fits on a narrow lane implies the scalar type.
            // `laneFits(.f64, v)` ⟹ `v.isFloat()`; `laneFits(.iN, v)` ⟹
            // `v.isInt()`. This is load-bearing for `.link` continuation
            // traces that store a `slot_load` value into a narrow-lane
            // array — the recorder emits `guard_fits` (not `guard_float`)
            // for narrow-lane stores, so without this arm the `slot_load`
            // is unguarded and `proveKinds` rejects the whole trace.
            .guard_fits => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .slot_load) {
                    const lk = laneKind(ins.aux) orelse continue; // .value → skip (no type implied)
                    switch (lk) {
                        .int => {
                            guarded[r] = true;
                        },
                        .float => {
                            float_guarded[r] = true;
                        },
                        // bool: no bool_guarded array exists; Pass B's
                        // guard_fits arm handles it.
                        else => {},
                    }
                }
            },
            .guard_table => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                // A table guard on a slot_load covers the table-bearing snapshot
                // slot; the native path hoists it to a prologue heap/type check.
                // A guard on anything else — an aload (Phase 2, .value-lane
                // element) or an hload (doc 43 P3, table-valued hash field) —
                // is a per-iteration body guard: accept it here but don't mark
                // table_guarded (no slot to pin for the prologue). Pass B
                // validates the operand is `.ptr`/`.heap`-kinded, so a guard on
                // a non-table producer still fails closed there.
                if (t.instrs[r].op == .slot_load) table_guarded[r] = true;
            },
            // guard_grid (doc 14): the grid analogue of guard_table+guard_lane. It
            // covers the grid table's slot_load (proven `.ptr`); the prologue
            // additionally verifies `lane == .grid ∧ grid_elem == aux`. Like
            // guard_table it only ever guards a table-bearing slot_load.
            .guard_grid => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op != .slot_load) return false;
                table_guarded[r] = true;
            },
            .guard_func => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                // On the callee-snapshot slot_load (a fresh synthetic input) the
                // native path hoists it to a prologue closure/proto-id check. On
                // anything else — doc 43 P2's `hload ty=.heap` function field —
                // Pass B validates the operand is `.heap`-kinded and the body
                // lowers a per-iteration type + proto-id check (the dynamic
                // guard_table precedent).
                if (t.instrs[r].op == .slot_load) func_guarded[r] = true;
            },
            .guard_builtin => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                // A pure guard only ever covers the callee-snapshot slot_load (the
                // recorder emits it on a fresh seeded upvalue/global input); the native
                // path hoists it to a prologue native/`RecordedBuiltin`-tag check.
                if (t.instrs[r].op != .slot_load) return false;
                pure_guarded[r] = true;
            },
            // guard_string (doc 24 c3): on a slot_load it pins the observed-string
            // input for the prologue (marked here); on anything else Pass B decides
            // — a guard on a proven-string producer discharges to nothing, any
            // other operand bails.
            .guard_string => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .slot_load) string_guarded[r] = true;
            },
            else => {},
        }
    }

    // Only exclusively-addressing keys may omit materialization. A shared
    // string constant consumed as a value must have a real heap location.
    for (t.instrs) |ins| {
        const reads = operandReads(ins);
        if (reads.a and ins.a < n) href_key[ins.a] = false;
        if (reads.b and ins.op != .href and ins.b < n) href_key[ins.b] = false;
        switch (ins.op) {
            .ssub, .scp, .sfindp, .smatch => {
                if (ins.aux >= 0 and ins.aux < n) href_key[@intCast(ins.aux)] = false;
            },
            .phi => if (ins.b < n) {
                href_key[ins.b] = false;
            },
            else => {},
        }
    }

    // Task #29 (per-chain lane binding, codex thread 01a09008): array lanes are
    // proven per ROOT and per ADDRESS CHAIN, not per trace. Each root ref (a
    // `.ptr`/`.heap` table) is bound by its own structural guards — `guard_lane`
    // binds a scalar lane; `guard_grid` + `guard_stride` jointly bind a grid
    // shape — and every address op must agree with ITS OWN root's binding
    // (`aref.aux == scalar lane`; `garow.aux == grid elem`), while every memory
    // op must agree with its own address op (`aload.aux == aref.aux`, etc.).
    // That is exactly the invariant the prologue/body checks verify at runtime
    // (each guard names its root; each load/store lowers at its own `aux`
    // width), so a trace may freely mix element widths across DIFFERENT arrays
    // — the old trace-global single-lane cell rejected e.g. sparse's
    // `vx[col[i]] * val[i]` (int-lane col + f64-lane vx/val) outright. A
    // scalar-bound root used as a grid (or vice versa), a conflicting
    // re-guard, or an address op with no dominating structural guard all fail
    // closed. Two DIFFERENT roots aliasing one runtime array are safe: the
    // array has one live lane, so one of the two runtime lane checks fails at
    // entry and the trace exits before any mismatched-width access.
    const RootBind = struct { scalar: ?i32 = null, grid_elem: ?i32 = null, grid_stride: ?i32 = null };
    const root_bind = gpa.alloc(RootBind, n) catch return false;
    defer gpa.free(root_bind);
    @memset(root_bind, .{});

    // Pass B: assign kinds, validating operands and constants as we go.
    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (guarded[i]) {
                    kinds[i] = .int;
                } else if (float_guarded[i]) {
                    kinds[i] = .float; // guard_float-covered → float input
                } else if (table_guarded[i]) {
                    kinds[i] = .ptr; // guard_table-covered → invariant table pointer
                } else if (func_guarded[i]) {
                    kinds[i] = .func; // guard_func-covered → invariant callee closure
                } else if (pure_guarded[i]) {
                    kinds[i] = .native; // guard_builtin-covered → invariant callee native
                } else if (string_guarded[i]) {
                    // guard_string-covered → invariant string pointer (doc 24 c3).
                    // Same `.heap` home/flush class as a producer result; the
                    // prologue pins TAG_HEAP + `header.type == string` once.
                    kinds[i] = .heap;
                    is_string[i] = true;
                } else if (boxedPassThroughOnly(t, i)) {
                    // Preserve both lanes without inventing a type. Allocation
                    // keeps payload and tag in their source slots; terminal
                    // writeback copies the complete boxed Value.
                    kinds[i] = .boxed;
                } else if (t.deopt_mode == .precise and snapshotOnlyLoad(t, i)) {
                    // Doc 45 D6: a PRECISE recording force-loads EVERY anchor-
                    // window register so full-window snapshots have a ref —
                    // including dead temporaries of arbitrary type. A load with
                    // no semantic use at all is admitted as `.none`: no home,
                    // no prologue check, nothing emitted; the exit
                    // materializers skip it because its slab slot is untouched
                    // by the native run (nothing writes it — that is exactly
                    // what `snapshotOnlyLoad` proved), hence already current.
                    kinds[i] = .none;
                } else {
                    return false; // unguarded typed/inspected use → bail
                }
            },
            .konst => {
                if (ins.aux < 0 or ins.aux >= t.consts.len) return false;
                kinds[i] = switch (t.consts[@intCast(ins.aux)].tag) {
                    .int => .int,
                    .boolean => .bool,
                    .float => .float, // Phase D: a float constant materializes via movq
                    // H1: a heap const serving as an href key (the interned
                    // field-name string) carries no native value — href reads the
                    // seeded cell, not the key — so accept it as `.none` and let
                    // `lower` emit nothing. Doc 30: any OTHER string konst is a
                    // first-class `.heap` value (the pattern operand of
                    // sfindp/smatch) — `payload.bits` IS the stable `*GcHeader`
                    // pointer (non-moving GC, consts rooted by the trace), so the
                    // existing raw-bits materialization emits it verbatim. A konst
                    // used BOTH as an href key and a value operand is excluded
                    // from href_key's metadata-only set and materializes normally.
                    // Non-string heap konsts stay unmarked → bail.
                    .heap_ref => if (href_key[i]) .none else if (t.consts[@intCast(ins.aux)].heapType() == .string) blk: {
                        is_string[i] = true;
                        break :blk .heap;
                    } else return false,
                    .nil => .nil,
                    else => return false,
                };
            },
            // Arithmetic: the recorder stamps the *result* type in `ins.ty`
            // (`arithResultType`: float iff div/pow or any operand float). Trust it
            // for the result kind and validate the operands are the matching class.
            //   - int result  → both operands proven int (the existing path).
            //   - float result → each operand int OR float; an int operand is
            //     promoted with `cvtsi2sd` at its use site. (band/bor/bxor are
            //     always int — they never carry `ins.ty == .float`.)
            .add, .sub, .mul => {
                if (ins.ty == .float) {
                    if (!isNumKind(kinds[ins.a]) or !isNumKind(kinds[ins.b])) return false;
                    // [review] Don't trust `ins.ty == .float` blindly: the oracle
                    // (arith.zig) computes int+int as a wrapping INTEGER and boxes
                    // TAG_INT, while a float lowering would cvtsi2sd both and box
                    // TAG_FLOAT — a divergence on side-exit. A genuine float result
                    // requires at least one float operand; a malformed/deserialized
                    // trace claiming otherwise bails to tier-1a.
                    if (kinds[ins.a] != .float and kinds[ins.b] != .float) return false;
                    kinds[i] = .float;
                } else {
                    if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                    kinds[i] = .int;
                }
            },
            .band, .bor, .bxor => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .int;
            },
            // shl/shr: both operands int, int result. The native lowering reproduces
            // Lua's full shift semantics (negative count → reverse direction, |count|
            // >= 64 → 0) with an explicit range bracket, so any int count is correct —
            // no masking assumption (`emitShift`).
            .shl, .shr, .sar => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .int;
            },
            // div is ALWAYS float (arithResultType stamps ins.ty == .float), even on
            // two int operands (3/2 == 1.5). The oracle computes a.toFloat()/b.toFloat()
            // under strict FP, where toFloat(int) == @floatFromInt == cvtsi2sd — so the
            // int/int case is bit-exact too (unlike a compare, this conversion is the
            // oracle's own path). No "≥1 float operand" gate: int/int div is genuinely
            // float here. NaN/inf (x/0.0, 0.0/0.0) fall out of IEEE divsd identically.
            .div => {
                if (!isNumKind(kinds[ins.a]) or !isNumKind(kinds[ins.b])) return false;
                kinds[i] = .float;
            },
            .neg, .bnot => {
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .int;
            },
            // int_of_float: the operand must be a proven float (a guard_float-covered
            // slot_load or a derived float); the result is the exact integer value
            // (or a side-exit). Lowers to a `cvttsd2si` round-trip check + convert.
            .int_of_float => {
                if (kinds[ins.a] != .float) return false;
                kinds[i] = .int;
            },
            // alen (doc 23 D3): the `#t` fast-case border. The operand is a
            // loop-invariant table home (`.ptr`, guard_table-covered slot_load) or
            // a per-iteration element table (`.heap`, .value-lane aload). The
            // lowered body re-verifies the whole fast case with memory-operand
            // compares (mirroring guard_append) and side-exits on any miss, so no
            // analysis-time table state is baked into the code. Result: the
            // border, an int.
            .alen => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                kinds[i] = .int;
            },
            .eq, .ne, .lt, .le => {
                // Two int operands → int compare (existing path). Two float operands →
                // float compare (F2, ucomisd). A MIXED int/float compare bails: the
                // oracle (value.compareNumeric) compares the int against the float
                // EXACTLY (compareIntFloat, no rounding), so a cvtsi2sd-then-ucomisd
                // lowering would diverge for ints not representable as f64. (Unlike F1
                // arith, where the oracle promotes via toFloat — there cvtsi2sd matches.)
                const ka = kinds[ins.a];
                const kb = kinds[ins.b];
                if (!((ka == .int and kb == .int) or (ka == .float and kb == .float))) return false;
                kinds[i] = .bool;
            },
            .guard_int => {
                // Passes trivially iff the operand is already proven int — a guarded
                // slot_load (set .int above) or a derived int (int-op-of-ints). Then
                // it is redundant and lowers to nothing. A guard on a .bool (e.g. a
                // compare result) or any unproven value can't be discharged → bail.
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .none;
            },
            .guard_float => {
                // Passes iff the operand is already proven float — a guard_float-
                // covered slot_load (set .float above) or a derived float (an arith
                // result with `ins.ty == .float`). Redundant then, lowers to nothing.
                // A guard_float on an int/bool/unproven value can't be discharged → bail.
                if (kinds[ins.a] != .float) return false;
                kinds[i] = .none;
            },
            .guard_true, .guard_false => {
                // Lua truthiness: ONLY nil/false are falsy. Every proven value
                // kind except `.bool` is therefore statically truthy — a
                // guard_true on it lowers to nothing and a guard_false to an
                // unconditional side-exit (the recorder saw a falsy value the
                // proof says can't recur; mirror the existing `.int` arms).
                // `.none`/`.aref`/`.href` are not values and stay a bail.
                const k = kinds[ins.a];
                if (k != .int and k != .bool and k != .float and k != .nil and
                    k != .ptr and k != .heap and k != .func and k != .native) return false;
                kinds[i] = .none;
            },
            // --- lane-aware array read path (B2) ---------------------------------
            // guard_table / guard_lane: cover the table slot_load (proven .ptr).
            // guard_lane additionally pins the lane; the native path only lowers
            // the bool lane, so any other lane bails here.
            .guard_table => {
                if (ins.a >= i) return false;
                // `.ptr` = loop-invariant table (prologue-hoisted, no-op in body).
                // `.heap` = per-iteration element table from .value-lane aload
                // (Phase 2) — body guard, NOT hoisted.
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                kinds[i] = .none;
            },
            // Absence consumes real runtime values, including materialized
            // string keys shared with href; a metadata-only .none is not a pointer.
            .guard_absent => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                if (kinds[ins.b] != .int and !(kinds[ins.b] == .heap and is_string[ins.b])) return false;
                kinds[i] = .none;
            },
            // guard_func (U1, cross-frame): covers the callee-snapshot slot_load
            // (proven `.func`) — pinned to a prologue identity check (closure type
            // + recorded `Proto.id`), lowering to nothing in the body, like
            // guard_table. OR (doc 43 P2) a `.heap`-kinded hload result (a
            // function field) — lowered as a per-iteration in-body type +
            // proto-id check, the dynamic-guard_table precedent.
            .guard_func => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .func and kinds[ins.a] != .heap) return false;
                kinds[i] = .none;
            },
            // guard_builtin (the pure-builtin identity guard): covers the callee-snapshot
            // slot_load (proven `.native`). Pinned to a prologue identity check (native
            // type + recorded `RecordedBuiltin` tag); lowers to nothing in the body, like
            // guard_func. The callee is a once-seeded loop-invariant upvalue/global, so
            // one prologue check covers the whole native run.
            .guard_builtin => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .native) return false;
                kinds[i] = .none;
            },
            // fsqrt: a leaf float producer computing `@sqrt` of its operand (the same
            // IEEE correctly-rounded sqrt as native `sqrtsd` under the default MXCSR).
            // The operand is a proven float, OR a proven int promoted by the same
            // operand-level `cvtsi2sd` the float binops use (`floatOperandToXmm`);
            // the result is a float. fsqrt lowers to a single `sqrtsd`; fsin/fcos
            // lower to a mid-body callout into the shared noinline `fmath` kernel
            // (doc 23 D4) — there is no bit-identical SSE instruction for them.
            .fsqrt, .fsin, .fcos => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .float and kinds[ins.a] != .int) return false;
                kinds[i] = .float;
            },
            // Doc 35: `ffloor`/`fceil` — same operand contract as fsin/fcos
            // (proven numeric), but the RESULT is an integer (Lua 5.4 semantics).
            .ffloor, .fceil => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .float and kinds[ins.a] != .int) return false;
                kinds[i] = .int;
            },
            // Doc 24 D4/D5: allocating interned-string producers. The operand is
            // the guard-pinned scalar; the result is a raw `*GcHeader` (an
            // interned String) — kind `.heap`, the same class as a carried-heap
            // value or a VALUE_LANE aload result, so the existing homes/flush
            // (TAG_HEAP re-box) apply. Lowered as a mid-body callout into the
            // shared `stralloc` body; side-exits on OOM (null return).
            //
            // Doc 26 (review M5): every allocating string producer also
            // fail-closes on a malformed result-`ty` stamp (`ins.ty` must be
            // `.heap` — that stamp is what the optimizer/liveness trusted; a
            // disagreeing instruction is corrupt IR, so refuse to compile it).
            .tostr_int => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .int) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            .tostr_num => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .float) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            // `#s` of a proven string: one 8-byte load of the cached `cp_len`
            // field. The operand must be a proven string producer's result
            // (`tostr_*` — kind `.heap` via the arms above); a `guard_string`-
            // pinned slot is NOT yet native (guard_string bails below, c3).
            .slen => {
                if (ins.a >= i) return false;
                // The operand must be statically a STRING (`is_string`): a
                // producer result (`tostr_*`/snew) or a guard_string-pinned
                // slot. Kind `.heap` alone is not enough — a carried-heap
                // slot's `.heap` is a TABLE (its `#` records as `alen`).
                if (!is_string[ins.a]) return false;
                kinds[i] = .int;
            },
            // guard_string (doc 24 c3): on a string-guarded slot_load (set
            // `.heap` + is_string above) it is the prologue type pin — lowers
            // to nothing in the body, like guard_table. On a proven-string
            // producer result it is statically redundant (the recorder never
            // emits that, but tolerate it). Anything else can't be discharged.
            .guard_string => {
                if (ins.a >= i) return false;
                if (!is_string[ins.a]) return false;
                kinds[i] = .none;
            },
            // --- snew class (doc 24 D4/c3): allocating string→string producers,
            // mid-body callouts into the shared `stralloc` shims. Each returns a
            // fresh-or-interned `*GcHeader` (kind `.heap`) or null — OOM *or* a
            // tier-0 raise (bad codepoint / negative count), both collapsing to
            // one clean side-exit (no `Heap.link` precedes the fallible step;
            // stralloc.zig's audit) — so each may exit in the body.
            .ssub => {
                // a = string, b = start (int), aux = end (int ref — a
                // three-operand op; assertWellFormed pins 0 ≤ aux < i).
                if (ins.a >= i or ins.b >= i) return false;
                if (ins.aux < 0 or ins.aux >= i) return false;
                if (!is_string[ins.a]) return false;
                if (kinds[ins.b] != .int) return false;
                if (kinds[@intCast(ins.aux)] != .int) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            .srev => {
                if (ins.a >= i) return false;
                if (!is_string[ins.a]) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            // Doc 26 D4: string.upper/lower — string→string case producers via
            // the shared Unicode `caseCore` (the FULL core, not an ASCII
            // special case — Z-6). Same shape as srev: one string operand,
            // fresh-or-interned `*GcHeader` result, null → side-exit (OOM).
            .supper, .slower => {
                if (ins.a >= i) return false;
                if (!is_string[ins.a]) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            .schar1 => {
                // a = the codepoint int (validated at runtime by the shared
                // core; an invalid one returns null → side-exit).
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .int) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            .srep2 => {
                if (ins.a >= i or ins.b >= i) return false;
                if (!is_string[ins.a]) return false;
                if (kinds[ins.b] != .int) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            // Doc 26 D3/D4: string.codepoint — the NON-allocating string
            // reader (`.pure3`; no guard_gc bound, no heap needed). a =
            // string, b = i (int), aux = j (int ref, ssub's encoding). Result
            // is a plain int: the scalar codepoint, or the −1 sentinel the
            // callout turns into a side-exit (empty range → tier-0 replays to
            // nil). Bounds precede EVERY kinds[]/is_string[] access.
            .scp => {
                if (ins.a >= i or ins.b >= i) return false;
                if (ins.aux < 0 or ins.aux >= i) return false;
                if (!is_string[ins.a]) return false;
                if (kinds[ins.b] != .int) return false;
                if (kinds[@intCast(ins.aux)] != .int) return false;
                if (ins.ty != .int) return false;
                kinds[i] = .int;
            },
            // --- doc 30: the pattern/str2num callout class -----------------
            // sfindp (plain find, heap-free) and smatch (matcher + scratch
            // fill) share ssub/scp's ternary encoding: a = string, b = init
            // (int), aux = pattern (a PROVEN-string ref — konst-pinned or
            // guard_sid-pinned). Result kind .int: sfindp's 1-based char
            // index (≥1; ≤0 → side-exit) / smatch's status (0; else exit).
            .sfindp, .smatch => {
                if (ins.a >= i or ins.b >= i) return false;
                if (ins.aux < 0 or ins.aux >= i) return false;
                if (!is_string[ins.a]) return false;
                if (kinds[ins.b] != .int) return false;
                if (!is_string[@intCast(ins.aux)]) return false;
                if (ins.ty != .int) return false;
                kinds[i] = .int;
            },
            // sgmatch: one composite gmatch-iterator step. a = the state
            // table (an invariant `.ptr` root or a per-iteration `.heap`
            // value — the shim re-checks the type and fails closed either
            // way), aux = the expected-pattern KONST-POOL id (an immediate,
            // resolved at emission to a baked `*GcHeader`). Status result.
            .sgmatch => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                if (ins.aux < 0 or ins.aux >= t.consts.len) return false;
                const pk = t.consts[@intCast(ins.aux)];
                if (pk.tag != .heap_ref or pk.heapType() != .string) return false;
                if (ins.ty != .int) return false;
                kinds[i] = .int;
            },
            // scap_int / scap_str: scratch-slot projections off a match token
            // (a = the smatch/sgmatch status result, kind .int — kept only
            // for SSA ordering; the lowering reads the BAKED scratch address,
            // never the operand home). b = the slot immediate (bounds pinned
            // by assertWellFormed; re-checked — never trust the IR).
            .scap_int => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .int) return false;
                if (ins.b >= gc.MatchScratch.n_slots) return false;
                if (ins.ty != .int) return false;
                kinds[i] = .int;
            },
            .scap_str => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .int) return false;
                if (ins.b >= gc.MatchScratch.n_slots) return false;
                if (ins.ty != .heap) return false;
                kinds[i] = .heap;
                is_string[i] = true;
            },
            // str2num_i/_f: `tonumber` on a heap operand via the ONE
            // arith.toNumber core. `.heap` (not is_string) deliberately: the
            // hot shape is `tonumber(t[i])` — a VALUE_LANE aload result with
            // no static string proof — and the core TYPE-CHECKS internally
            // (a non-string heap value → nil → status −1 → side-exit), so
            // admitting any proven-heap operand is sound. The recorder baked
            // the OBSERVED kind; a runtime kind mismatch likewise side-exits.
            .str2num_i => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .heap) return false;
                if (ins.ty != .int) return false;
                kinds[i] = .int;
            },
            .str2num_f => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .heap) return false;
                if (ins.ty != .float) return false;
                kinds[i] = .float;
            },
            // sgm_setpos: the deferred gmatch-cursor commit — value-less
            // effect, sunk below every guard by construction (doc 30 §6).
            // a = the state table, b = the new pos (int).
            .sgm_setpos => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                if (kinds[ins.b] != .int) return false;
                kinds[i] = .none;
            },
            // guard_sid: interned-identity pin against a konst-pool string
            // (doc 30 §2a) — the body-guard analogue of guard_string that
            // ALSO proves the exact string, so it upgrades `is_string` on
            // its operand (the dominating proof smatch/sfindp aux needs).
            .guard_sid => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .heap) return false;
                if (ins.aux < 0 or ins.aux >= t.consts.len) return false;
                const sk = t.consts[@intCast(ins.aux)];
                if (sk.tag != .heap_ref or sk.heapType() != .string) return false;
                is_string[ins.a] = true;
                kinds[i] = .none;
            },
            // Doc 24 D3: the allocation-budget entry guard. Value-less; lowered
            // to two loads of the baked heap counters + the gc_stress byte test.
            // `compileImpl` guaranteed `heap != null` for any trace containing it.
            .guard_gc => {
                // Bound A is stamped positive by finalize — except a PRECISE
                // body's eager guard_gc, which keeps aux == 0 when the body
                // allocates nothing (doc 45 D4). Lower it with A = 0 rather
                // than bail: the gc_stress arm must still exit identically to
                // tier-1a, so it cannot be elided.
                if (ins.aux < 0) return false;
                if (ins.aux == 0 and t.deopt_mode != .precise) return false;
                kinds[i] = .none;
            },
            // Doc 45 D6: precise-only table allocation — materializes the
            // fresh `*Table`'s `*GcHeader` in a GP home (`.heap`, the snew
            // producer discipline). Operand-free; fail closed outside a
            // precise trace (never trust the IR — finalize traps tnew there).
            .tnew => {
                if (t.deopt_mode != .precise) return false;
                kinds[i] = .heap;
            },
            // --- hash-part field path (H1) --------------------------------------
            // href: a value-cell pointer (`*Value`) for a constant string key into
            // a table's hash part. Two sub-paths:
            // - `.ptr` table (loop-invariant): cell resolved once per entry by
            //   `seedTraceInputs` into slab slot `ins.aux` ≥ 0.
            // - `.heap` table (Phase 2, per-iteration): cell resolved per iteration
            //   by a call-out to `resolveHashCell`; `ins.aux == -1` (no seed slot).
            // In both cases `b` is the interned key konst (marked an href_key above
            // → accepted `.none`). The result is a distinct `.href` kind.
            .href => {
                if (ins.a >= i or ins.b >= i) return false;
                if (t.instrs[ins.b].op != .konst) return false; // key is a constant
                if (kinds[ins.a] == .ptr) {
                    // Loop-invariant: seed slot must be valid.
                    if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                } else if (kinds[ins.a] == .heap) {
                    // Per-iteration: recorder sets aux = -1 (no seed).
                    if (ins.aux != -1) return false;
                } else {
                    return false;
                }
                kinds[i] = .href;
            },
            // guard_hash: the structural sentinel. The oracle re-resolves the cell and
            // re-checks `metatable==null ∧ getPtr(key)!=null ∧ hash.count()==recorded`
            // every iteration; native relies on the per-entry seed validation in
            // `seedTraceInputs` (a failed resolve routes the whole entry to tier-1a
            // instead of native) and the per-iteration `hload` tag-check, so in the
            // native body this guard lowers to nothing. Covers an href.
            .guard_hash => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .href) return false;
                kinds[i] = .none;
            },
            // hload: a typed load from the cell. `a` is the href; the recorder stamps
            // the observed field type in `ins.ty` (int/float carry a consumer
            // type-guard; bool's pin IS the hload tag check — doc 43 P1). Native
            // handles int/float/bool field values (a heap-valued field declines,
            // like the `.value` array lane); the load tag-checks `[cell+0]`
            // (side-exit on mismatch) then loads `[cell+8]`.
            .hload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .href) return false;
                kinds[i] = switch (ins.ty) {
                    .int => .int,
                    .float => .float,
                    .boolean => .bool, // payload is canonical 0/1 (Value.boolean) → Kind.bool convention
                    // doc 43 P2: a heap-valued field (function; table in P3). The
                    // payload is the raw *GcHeader — same `.heap` class as a
                    // VALUE_LANE heap aload result (transient, GC-safe while no
                    // body callout may collect — HelperCaps discipline).
                    .heap => .heap,
                    else => return false, // string/unknown field value → tier-1a
                };
            },
            // hstore: overwrite the present cell in place (no grow — the present-key
            // rule holds). `a` is the href, `b` the value; native lowers int/float/
            // bool values to a tag+payload store and declines a heap value. A `.bool`
            // value is a clean 0/1 GP by convention, so the 8-byte payload store
            // reproduces `Value.boolean`'s layout bit-for-bit. Produces nothing.
            .hstore => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .href) return false;
                const vk = kinds[ins.b];
                if (vk != .int and vk != .float and vk != .bool) return false; // heap value → tier-1a
                kinds[i] = .none;
            },
            // Doc 43 P5: the closed-upvalue-cell family mirrors href/hload/
            // hstore. `uref` loads the entry-seeded `*Value` cell pointer from
            // its slab slot — same `.href` kind, so the load/store twins share
            // the hash-cell emission verbatim. No per-iteration structural
            // guard exists (a closed cell can never re-open; the entry seeder
            // validated + verified the alias class, declining to tier-0 on any
            // failure), so unlike href there is no dynamic-root variant.
            .uref => {
                if (ins.aux < 0 or ins.aux > 0xFFFF) return false; // seed slot must be valid
                kinds[i] = .href;
            },
            // `uload`: typed load from the cell; the fused tag check IS the
            // strict pin (a bool's only one — the hload P1 discipline).
            // Heap-valued cells are never routed by the recorder (v1), so the
            // `.heap` arm is deliberately absent: fail closed.
            .uload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .href) return false;
                kinds[i] = switch (ins.ty) {
                    .int => .int,
                    .float => .float,
                    .boolean => .bool,
                    else => return false, // non-scalar ty: the recorder never emits it — fail closed
                };
            },
            // `ustore`: overwrite the cell in place — scalar values only (the
            // recorder pins them; heap values would need the write-barrier
            // ABI, doc 43 §8 deferred bullet).
            .ustore => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .href) return false;
                const vk = kinds[ins.b];
                if (vk != .int and vk != .float and vk != .bool) return false;
                kinds[i] = .none;
            },
            .guard_lane => {
                if (ins.a >= i) return false;
                // `.ptr` = invariant root, lane checked once in the prologue.
                // `.heap` (doc 43 P3) = per-iteration root; the body emits the
                // lane-byte compare inline (see the lowering arm).
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                // `.value` lane: accepted for Phase 2 (array-of-structs). The
                // prologue checks `array.lane == .value` the same way it checks
                // any other lane byte. No scalar lane-kind produced — the aload
                // arm handles the `.value` case separately.
                if (ins.aux != VALUE_LANE and laneKind(ins.aux) == null) return false;
                // Task #29: bind THIS root's scalar lane. A grid-bound root
                // re-guarded as scalar, or a conflicting scalar re-guard,
                // fails closed.
                const rb = &root_bind[ins.a];
                if (rb.grid_elem != null or rb.grid_stride != null) return false;
                if (rb.scalar) |l| {
                    if (l != ins.aux) return false;
                } else rb.scalar = ins.aux;
                kinds[i] = .none;
            },
            // aref pairs (table, index); its register carries idx0 = index-1. A
            // distinct `.aref` kind so it can neither feed arithmetic nor be flushed.
            // The root is an invariant `.ptr` (prologue-hoisted homes) OR — doc 43
            // P3 — a per-iteration `.heap` table (an hload'd table field / a
            // VALUE_LANE aload element): every consumer (guard_bounds,
            // guard_present, aload, astore) already resolves data/present/asize
            // through `arrayFieldReg`'s per-iteration fallback when the root has
            // no hoisted slot homes, so the dynamic root costs loads, not new
            // machinery. The lane pin for a dynamic root is guard_lane's in-body
            // form (below), never the prologue.
            .aref => {
                if (ins.a >= i or ins.b >= i) return false;
                if ((kinds[ins.a] != .ptr and kinds[ins.a] != .heap) or kinds[ins.b] != .int) return false;
                if (ins.aux != VALUE_LANE and laneKind(ins.aux) == null) return false;
                // Task #29: the aref's lane must be the one a DOMINATING
                // guard_lane on ITS root proved at runtime. An aref may never
                // establish the binding itself — that would prove internal
                // metadata consistency, not the live array's layout. A root
                // never guard_lane'd (or bound as a grid) fails closed.
                const rl = root_bind[ins.a].scalar orelse return false;
                if (rl != ins.aux) return false;
                kinds[i] = .aref;
            },
            // guard_bounds (idx0 <u len): the bounds proof for this aref. Marks the
            // aref bounds-checked so a later guard_present/aload may touch memory.
            .guard_bounds => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                bounds_ok[ins.a] = true;
                kinds[i] = .none;
            },
            // guard_present (bool: in-band byte ≠ 0; int/float: bt the presence
            // bitmap): only safe behind a dominating bounds check on the same aref
            // (else the data/presence load may be null / idx0 OOB).
            .guard_present => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!bounds_ok[ins.a]) return false; // [I4] bounds must dominate
                kinds[i] = .none;
            },
            // aload decodes the slot to a boolean (bool lane: movzx the in-band byte
            // then sub 1) or a sign-extended int (i8…i64). Likewise gated on a
            // dominating bounds check (the data load is indexed by idx0, which must
            // be proven in range).
            .aload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!bounds_ok[ins.a]) return false; // [I4] bounds must dominate
                // Task #29: direct chain equality — the load's width is the
                // one its own aref (and transitively that aref's guard_lane)
                // verified. Replaces the old transitive-via-global argument.
                if (ins.aux != t.instrs[ins.a].aux) return false;
                if (ins.aux == VALUE_LANE) {
                    // The .value lane holds full 16-byte tagged Values, so the
                    // element's kind comes from the recorded `ty`, not from the lane.
                    // Three shapes lower (the tag check is FUSED into the load — see
                    // the codegen arm and `opMayExitInBody`):
                    //   .heap  → a per-iteration *GcHeader for a table (Phase 2,
                    //            array-of-structs `bodies[i].x`);
                    //   .int   → TAG_INT payload into a GP register (doc 32);
                    //   .float → TAG_FLOAT payload into an XMM register (doc 32).
                    // Anything else (bool/string/unknown) still bails; the recorder
                    // does not emit those shapes, so this is defence in depth.
                    kinds[i] = switch (ins.ty) {
                        .heap => .heap,
                        .int => .int,
                        .float => .float,
                        else => return false,
                    };
                } else {
                    const lk = laneKind(ins.aux) orelse return false;
                    kinds[i] = lk; // bool → .bool; i8…i64/u8 → .int; f64 → .float
                }
            },
            // guard_fits: the value (`a`) still fits the recorded narrow lane.
            // For an int lane it marks the value so a following int-lane astore may
            // store it without widening; lowers to a range compare (i8/i16/i32) or
            // nothing (i64 — every i64 fits). For the bool lane it is a tier-1a-only
            // soundness guard (a free-variable non-bool store side-exits there);
            // native already proves the value is `.bool`, so it lowers to nothing.
            // For the f64 lane it likewise lowers to nothing (a double is never
            // narrowed). Only the `.value` lane bails (laneKind → null).
            .guard_fits => {
                if (ins.a >= i) return false;
                const lk = laneKind(ins.aux) orelse return false; // .value → tier-1a
                switch (lk) {
                    .int => {
                        if (kinds[ins.a] != .int) return false; // only int values are range-guarded
                        // Task #29: record the EXACT lane this proof covers;
                        // the consuming store requires its own lane's bit.
                        const bit = laneBit(ins.aux) orelse return false;
                        fits_mask[ins.a] |= bit;
                    },
                    // The bool lane's guard_fits exists only for the tier-1a oracle
                    // (it side-exits a free-variable non-bool store). Native already
                    // requires the astore value to be a proven `.bool`, so this guard
                    // lowers to nothing — just type-check it and drop it.
                    .bool => if (kinds[ins.a] != .bool) return false,
                    // The f64 lane's guard_fits, like the bool lane's, exists for the
                    // tier-1a oracle (it side-exits a free-variable non-float store).
                    // Native already requires the astore value to be a proven `.float`
                    // and a double is never width-truncated, so this lowers to nothing —
                    // just type-check it and drop it. Unlike the int lanes it does NOT
                    // mark `fits_ok`: an f64 astore is a full-width `movsd` that needs no
                    // range coverage, so it must compile even when tropt has folded this
                    // guard away (a constant store fits trivially → guard DCE'd).
                    .float => if (kinds[ins.a] != .float) return false,
                    else => return false,
                }
                kinds[i] = .none;
            },
            // astore encodes the value (`b`) into the lane slot addressed by the
            // aref (`a`). Like aload, the data write is indexed by idx0, so it
            // requires a dominating bounds check on the same aref [I1/P1] (else it
            // could write out of bounds). C1 — that the stored value not depend on
            // any prior `aload` — is enforced at record time (`recArraySet` aborts),
            // so by here the value is a guarded slot input or constant. astore
            // produces no value.
            .astore => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (ins.aux == VALUE_LANE) {
                    // doc 32: a `.value`-lane store writes a full tagged Value — tag
                    // byte + 8-byte payload, and NO presence bit (the lane has no
                    // bitmap; nil is in-band). Every value fits a type-erased lane, so
                    // unlike the narrow int lanes there is nothing to range-check and
                    // `fits_ok` is deliberately NOT required — the recorder emits
                    // `guardNum` instead of the vacuous `guard_fits`, and that guard is
                    // what proves the kind below. Only int/float are lowered; a heap
                    // value is the one shape that would need a real write barrier under
                    // a future generational/incremental collector.
                    // Task #29: chain equality with this store's own aref.
                    if (ins.aux != t.instrs[ins.a].aux) return false;
                    if (!bounds_ok[ins.a]) return false; // [I1/P1] bounds must dominate
                    if (kinds[ins.b] != .int and kinds[ins.b] != .float) return false;
                    kinds[i] = .none;
                    continue;
                }
                const lk = laneKind(ins.aux) orelse return false;
                if (ins.aux != t.instrs[ins.a].aux) return false; // task #29: chain equality
                if (!bounds_ok[ins.a]) return false; // [I1/P1] bounds must dominate
                switch (lk) {
                    .bool => {
                        if (kinds[ins.b] != .bool) return false; // bool lane stores a boolean
                    },
                    .int => {
                        // int lane (i8…i64): the value must be a proven int AND
                        // provably fit the lane width, so native may store it at the
                        // lane width without the widening tier-0 would otherwise do.
                        // Fit is established by a covering guard_fits (a free-variable
                        // store) OR, when tropt folded that guard away because the
                        // value is a constant that trivially fits, by re-deriving the
                        // static fit here (a const fill/init store) — mirrors the f64
                        // arm below.
                        if (kinds[ins.b] != .int) return false;
                        const bit = laneBit(ins.aux) orelse return false;
                        if (fits_mask[ins.b] & bit == 0 and !konstFitsLane(t, ins.b, ins.aux)) return false;
                    },
                    .float => {
                        // f64 lane: the value need only be a proven float. The store is
                        // a full-width `movsd` with no truncation, so EVERY double fits —
                        // there is nothing to range-check, hence no `fits_ok` requirement
                        // (mirrors the bool lane, NOT the narrow int lanes). This is what
                        // lets a constant-float fill (`a[k] = 2.0`) compile even though
                        // tropt folds the redundant guard_fits for the constant.
                        if (kinds[ins.b] != .float) return false;
                    },
                    else => return false, // laneKind yields .bool/.int/.float
                }
                kinds[i] = .none;
            },
            // guard_append (the grow precondition): like guard_bounds, it proves the
            // aref addresses a writable slot — here `data[len]`, the in-cap append
            // successor (idx==len+1, len<cap) into a migrate-free (empty-hash) table.
            // Marks the aref bounds-checked so the following astore_append may store.
            // bool + i8…i64 (the lanes the append path lowers); `.value` → tier-1a.
            // (`.f64` passes laneKind but the recorder never emits an f64 append —
            // the astore_append below bails it; see there.)
            .guard_append => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                const aref_ins = t.instrs[ins.a];
                if (laneKind(aref_ins.aux) == null) return false; // .value → tier-1a
                // Task #29: the aref's lane/root agreement was proven at its
                // own admission; nothing trace-global left to check here.
                bounds_ok[ins.a] = true;
                kinds[i] = .none;
            },
            // astore_append: append the value at `data[len]` and bump len. Like
            // astore, gated on a dominating bounds proof (guard_append) on the same
            // aref. Same lane/value rules as the in-bounds astore: bool lane stores a
            // proven boolean (in-band byte); int lanes store a proven int covered by a
            // dominating guard_fits (so the width-truncating native store is exact).
            .astore_append => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                // Validate the lane `lower()` actually switches on (`ins.aux`), exactly
                // like the in-bounds `astore` — and require it to EQUAL the aref's aux
                // directly (task #29): a trace whose astore_append.aux disagreed with
                // its aref is rejected rather than lowered with a mismatched width.
                const lk = laneKind(ins.aux) orelse return false; // .value → tier-1a
                if (ins.aux != t.instrs[ins.a].aux) return false; // task #29: chain equality, now direct
                if (!bounds_ok[ins.a]) return false; // guard_append must dominate
                switch (lk) {
                    .bool => if (kinds[ins.b] != .bool) return false,
                    .int => {
                        if (kinds[ins.b] != .int) return false;
                        // guard_fits ⇒ width store is exact; or a constant whose fit
                        // tropt proved and folded away (const fill append, `p[i]=0`).
                        const bit = laneBit(ins.aux) orelse return false;
                        if (fits_mask[ins.b] & bit == 0 and !konstFitsLane(t, ins.b, ins.aux)) return false;
                    },
                    // f64 append is intentionally not lowered in this cut: the recorder's
                    // append gate (`recArraySet`) excludes the f64 lane, so no f64
                    // astore_append is ever emitted. Should one appear, bail to tier-1a.
                    else => return false,
                }
                kinds[i] = .none;
            },
            // --- flattened-grid cell path (doc 14, Phase 8) ---------------------
            // guard_grid / guard_stride: cover the grid table's slot_load (proven
            // `.ptr`). Both are PROLOGUE-pinned structural guards — the prologue
            // checks `lane == .grid ∧ grid_elem == aux` (guard_grid) and
            // `stride == aux` (guard_stride) once per native entry, so in the body
            // they lower to nothing, exactly like guard_table/guard_lane. Sound
            // because grid_elem and stride are invariant across a native run: the
            // recorder aborts any growing/widening store, and a deflation only ever
            // happens on a bare access, which is never part of a recorded trace.
            .guard_grid => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr) return false;
                const lk = laneKind(ins.aux) orelse return false; // grid_elem lane
                if (lk != .int and lk != .float) return false; // int + f64 grid lanes
                // Task #29: bind THIS root's grid element lane. A scalar-bound
                // root re-guarded as a grid, or a conflicting elem re-guard,
                // fails closed.
                const rb = &root_bind[ins.a];
                if (rb.scalar != null) return false;
                if (rb.grid_elem) |e| {
                    if (e != ins.aux) return false;
                } else rb.grid_elem = ins.aux;
                kinds[i] = .none;
            },
            .guard_stride => {
                // `ins.aux` is the recorded stride VALUE (a row width), not a lane —
                // do not run laneKind on it. The prologue compares the live
                // `array.stride` against it; an enlarged grid side-exits there.
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr) return false;
                // Task #29: bind THIS root's stride; conflicting stride guards
                // on one root fail closed (allocation would otherwise take the
                // last matching metadata it scans).
                const rb = &root_bind[ins.a];
                if (rb.scalar != null) return false;
                if (rb.grid_stride) |s| {
                    if (s != ins.aux) return false;
                } else rb.grid_stride = ins.aux;
                kinds[i] = .none;
            },
            // garow pairs (grid table, row); its register carries the row base —
            // concretely row0 = row-1 (the 0-based row), exactly mirroring `aref`'s
            // idx0. Reuses the `.aref` kind so it composes with the existing
            // guard_bounds (row0 <u rows, since a grid's array length == its row
            // count) and the home-reservation machinery.
            .garow => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .ptr or kinds[ins.b] != .int) return false;
                const lk = laneKind(ins.aux) orelse return false;
                if (lk != .int and lk != .float) return false; // int + f64 grid lanes (bool never a grid)
                // Task #29: BOTH structural guards must dominate — guard_grid
                // (the elem lane this garow's aux must match) and guard_stride
                // (the imm32 the covering gcell folds). A garow may never
                // establish the binding itself.
                const rb = root_bind[ins.a];
                const ge = rb.grid_elem orelse return false;
                if (ge != ins.aux) return false;
                if (rb.grid_stride == null) return false;
                kinds[i] = .aref;
            },
            // gcell pairs (garow, col); its register carries the FLAT cell index
            // flat = row0*stride + (col-1), with `stride` folded as an imm32 from the
            // covering guard_stride. Also `.aref`-kind (it addresses one scalar cell,
            // just like an aref's idx0) so the gload/gstore/guard_gpresent arms below
            // treat it uniformly. The row-bounds proof lives on the `garow`
            // (guard_bounds), which the recorder emits before this gcell — require it
            // here so the flat index a memory op will dereference is row-safe.
            .gcell => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref or kinds[ins.b] != .int) return false;
                const lk = laneKind(ins.aux) orelse return false;
                if (lk != .int and lk != .float) return false;
                if (ins.aux != t.instrs[ins.a].aux) return false; // task #29: chain equality with the garow
                if (!bounds_ok[ins.a]) return false; // row bound must dominate the gcell
                kinds[i] = .aref;
            },
            // guard_gcol (col in [1, stride]): the column bound for this gcell, the
            // grid analogue of guard_bounds. `b` carries the column ref (kept live so
            // native can range-compare it). Marks the gcell column-checked so a
            // following gload/gstore/guard_gpresent may dereference the cell.
            .guard_gcol => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref or kinds[ins.b] != .int) return false;
                gcol_ok[ins.a] = true;
                kinds[i] = .none;
            },
            // guard_gpresent (cell present): bt the per-cell presence bitmap at the
            // flat index. Safe only behind BOTH the row bound (carried on the garow,
            // already required at the gcell) and the column bound (guard_gcol on this
            // gcell) — else the bit index is outside the buffer.
            .guard_gpresent => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!gcol_ok[ins.a]) return false; // column bound must dominate
                kinds[i] = .none;
            },
            // gload: a typed load from the grid cell addressed by the gcell. Gated on
            // the column proof; the row proof is already discharged at the gcell. An
            // int cell sign/zero-extends the grid_elem-width element into a GP home; an
            // f64 cell `movsd`s the raw double into an XMM home (kind `.float`).
            .gload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!gcol_ok[ins.a]) return false; // column bound must dominate
                const lk = laneKind(ins.aux) orelse return false;
                if (lk != .int and lk != .float) return false;
                if (ins.aux != t.instrs[ins.a].aux) return false; // task #29: chain equality with the gcell
                kinds[i] = lk; // int grid → .int (GP); f64 grid → .float (XMM)
            },
            // gstore: encode the value (`b`) into the grid cell addressed by the
            // gcell (`a`) and set its presence bit. Gated on the column proof; the
            // row proof is discharged at the gcell. The recorder emits a covering
            // guard_fits on the value and aborts a growing store, so for an int lane
            // the value is a proven int that fits grid_elem (store at the cell width);
            // for an f64 lane it is a proven float committed as a full-width `movsd`
            // (every double fits → no fits_ok requirement, mirroring the f64 astore).
            // Produces no value.
            .gstore => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!gcol_ok[ins.a]) return false; // column bound must dominate
                const lk = laneKind(ins.aux) orelse return false;
                if (ins.aux != t.instrs[ins.a].aux) return false; // task #29: chain equality with the gcell
                switch (lk) {
                    .int => {
                        if (kinds[ins.b] != .int) return false;
                        const bit = laneBit(ins.aux) orelse return false;
                        if (fits_mask[ins.b] & bit == 0) return false; // guard_fits ⇒ width store is exact
                    },
                    .float => {
                        if (kinds[ins.b] != .float) return false; // full-width movsd, no range check
                    },
                    else => return false,
                }
                kinds[i] = .none;
            },
            .loop => {
                if (i != n - 1) return false; // loop must be terminal
                kinds[i] = .none;
            },
            .link => {
                if (i != n - 1) return false; // link must be terminal
                kinds[i] = .none;
            },
            // Doc 44: the one-shot head-trace close. `a` is a TerminalKind tag
            // and `aux` the resume pc — neither is an operand ref. Value-less.
            .terminal => {
                if (i != n - 1) return false; // must be terminal
                kinds[i] = .none;
            },
            // Phase E1/E2: the preheader region boundary. A pure marker (no value);
            // everything before it is the run-once region the lowering emits ahead
            // of `loop_top`. `analyze` gives each run-once value a computed home.
            .preheader => {
                kinds[i] = .none;
            },
            // A loop-carried φ. `b` (the back-edge update) is the one operand allowed
            // to reference a *later* node, so it is only range-checked here (< n) and
            // kind-checked in the post-pass below (it may not be assigned yet on the
            // forward scan). A *slot-bound* φ (aux >= 0) records a writeback to
            // regs[aux]; the body reads the slot through its `slot_load`, never the φ
            // node, so the φ itself is value-less (.none) — exactly what the old
            // exit_store was. An *internal* φ (aux == PHI_INTERNAL) backs no register:
            // its init `a` is a real preheader ref (a < i) and its value carries the
            // recorded scalar type, since body uses reference the φ directly.
            .phi => {
                if (ins.b >= n) return false;
                if (ins.aux == trace.PHI_INTERNAL) {
                    if (ins.a >= i) return false; // init must precede the φ
                    kinds[i] = switch (ins.ty) {
                        .int => .int,
                        .float => .float,
                        .boolean => .bool,
                        // Doc 40: an unknown-ty internal φ — the recorder stamps
                        // φ ty from the init ref's ty, and an UNGUARDED slot_load
                        // init (the reset-to-int `k = n`) carries `.unknown`.
                        // Take the init's proven kind instead: Pass A hoisted the
                        // φ's own numeric guard onto that slot_load, so the init
                        // is prologue-checked; non-numeric stays a bail.
                        else => switch (kinds[@intCast(ins.a)]) {
                            .int => .int,
                            .float => .float,
                            else => return false,
                        },
                    };
                    // Doc 40 Phase 4 structural check (codex finding 5): the
                    // preheader seed move (`movePlace` init-home → φ-home) has
                    // no GP↔XMM path, and the φ-guard discharge above relies on
                    // the init being proven AS the φ's kind. Same-kind seam by
                    // construction (both peel directions and LICM); a mismatch
                    // is malformed/deserialized input — fail closed.
                    if (kinds[@intCast(ins.a)] != kinds[i]) return false;
                } else {
                    if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                    kinds[i] = .none;
                }
            },
            // pow: always a float producer (Lua `^`), evaluated by a two-arg
            // body callout into the shared `fmath.powRuntime` kernel — the same
            // body `arith.pow` runs in tier-0/tier-1a, so bit-identity holds by
            // construction. Operands are any proven numeric (an int promotes
            // via the shared `cvtsi2sd` discipline at the callout).
            .pow => {
                if (ins.a >= i or ins.b >= i) return false;
                if (ins.ty != .float) return false; // the oracle always boxes float
                if (!isNumKind(kinds[ins.a]) or !isNumKind(kinds[ins.b])) return false;
                kinds[i] = .float;
            },
            // mod/idiv (doc 25): the recorder stamps `.int` iff both operands
            // are int (`arithResultType`), `.float` otherwise. EXHAUSTIVE ty
            // switch (codex): a malformed/deserialized `.boolean`/`.nil` stamp
            // fails closed rather than riding the add/sub/mul arm's implicit
            // else-is-int. Explicit operand bounds: `assertWellFormed` is
            // debug-only and this is the release-mode fail-closed gate.
            //   - int lane  → inline cqo/idiv + floor adjust (`emitIntDivMod`);
            //     exits on a zero divisor (tier-0 re-raises DivisionByZero),
            //     materializes the defined (minInt, -1) result inline.
            //   - float lane → body callout to the shared fmath kernel
            //     (`fmodRuntime`/`floordivRuntime`), total, no exit. A genuine
            //     float result requires ≥1 float operand — the oracle computes
            //     int%int as an INTEGER, so a `.float` stamp on two int
            //     operands is malformed and bails (the add/sub/mul rationale).
            .mod, .idiv => {
                if (ins.a >= i or ins.b >= i) return false;
                switch (ins.ty) {
                    .int => {
                        if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                        kinds[i] = .int;
                    },
                    .float => {
                        if (!isNumKind(kinds[ins.a]) or !isNumKind(kinds[ins.b])) return false;
                        if (kinds[ins.a] != .float and kinds[ins.b] != .float) return false;
                        kinds[i] = .float;
                    },
                    else => return false,
                }
            },
            // Everything else (guard_number/float-neg) is deferred — bail to
            // tier-1a. (shl/shr, guard_float, guard_builtin and fsqrt are handled
            // above.)
            else => return false,
        }
    }

    // Every loop-carried writeback must reference a boxable value. A raw table
    // pointer is boxable as TAG_HEAP and is needed for compiler temporaries that
    // are write-only at a while-loop header. A `.heap` value (a per-iteration
    // table from a VALUE_LANE aload) is likewise TAG_HEAP-boxable and is the
    // carried-heap writeback of doc 22 §A.1 (`bi = b[i]`-shaped outer bodies) —
    // `analyze` classifies the slot and decides admissibility. An `.aref` is only
    // an addressing token and must never escape into the VM register file. This
    // runs after Pass B so a φ's forward-referencing `b` has its kind assigned.
    for (t.instrs, 0..) |p, i| {
        if (p.op != .phi) continue;
        if (p.b >= n) return false;
        const k = kinds[p.b];
        // `.func` is admissible (doc 44): a guard_func-covered closure is a raw
        // `*GcHeader` boxed TAG_HEAP exactly like `.ptr` — a head trace's φ rows
        // write the callee closure into the child call frame's slots. A carried
        // `.func` load still bails in `analyze` (lk must be numeric), so this
        // only ever feeds write-only flushes.
        if (k != .int and k != .bool and k != .float and k != .ptr and k != .heap and k != .func and k != .boxed and k != .nil) return false;
        // Doc 40: an internal φ's back-edge update must deliver the φ's own
        // kind — the other half of the φ-guard discharge (Pass B proved the
        // init; this proves iterations 2+). `b` is a forward ref, so the check
        // lives here, after every kind is assigned.
        if (p.aux == trace.PHI_INTERNAL and k != kinds[i]) return false;
    }
    return true;
}

/// True iff `k` is a numeric scalar (int or float) — i.e. a valid operand to a
/// float arithmetic op (an int is `cvtsi2sd`'d at its use site).
// pub for nativegen.zig's analyze/exit classification (file-split pass).
pub fn isNumKind(k: Kind) bool {
    return k == .int or k == .float;
}

/// The operand refs an instruction reads (matching `proveKinds`/`lower` exactly).
pub fn operandReads(ins: trace_ir.IrInstr) struct { a: bool, b: bool } {
    return switch (ins.op) {
        .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .sar, .eq, .ne, .lt, .le => .{ .a = true, .b = true },
        .neg, .bnot, .guard_int, .guard_true, .guard_false => .{ .a = true, .b = false },
        // int_of_float reads its sole float operand (a); alen its sole table
        // operand (a).
        .int_of_float, .alen => .{ .a = true, .b = false },
        // aref reads table (a, an invariant home) + index (b). aload/guards reach the
        // table through aref.a, so they read only the aref token (a). astore reads
        // the aref token (a) plus the value to write (b). astore_append is the grow
        // analogue (aref token + value).
        .aref, .astore, .astore_append, .guard_absent => .{ .a = true, .b = true },
        .aload, .guard_bounds, .guard_present, .guard_table, .guard_lane => .{ .a = true, .b = false },
        // guard_func reads the callee-snapshot value it identity-checks (a).
        .guard_func => .{ .a = true, .b = false },
        // guard_builtin reads the callee-snapshot native it identity-checks (a);
        // fsqrt/fsin/fcos read their sole float operand (a).
        .guard_builtin, .fsqrt, .fsin, .fcos, .ffloor, .fceil => .{ .a = true, .b = false },
        // doc 24: tostr_* read their guard-pinned scalar (a); slen its string
        // (a). guard_gc reads NOTHING (`a` unused, aux = the bound A).
        .tostr_int, .tostr_num, .slen => .{ .a = true, .b = false },
        .guard_gc => .{ .a = false, .b = false },
        // doc 24 c3 (snew): ssub reads string (a) + start (b) — its END index
        // ref rides in `aux`, which this two-operand shape cannot express;
        // `analyzeInner` extends the aux ref's liveness explicitly (the
        // dyn-href precedent). srep2 reads string (a) + count (b); srev reads
        // its string (a), schar1 its codepoint (a). guard_string reads the
        // string it type-pins (a) — hoisted to the prologue for a slot_load,
        // statically discharged on a producer, but liveness must still hold.
        // doc 26: scp reads string (a) + start index (b) — its END index ref
        // rides `aux` (the ssub encoding), extended in `analyzeInner` exactly
        // like ssub's. supper/slower read only their string (a), like srev.
        .ssub, .srep2, .scp => .{ .a = true, .b = true },
        .srev, .schar1, .guard_string, .supper, .slower => .{ .a = true, .b = false },
        // doc 30: sfindp/smatch read string (a) + init (b) — their pattern
        // ref rides `aux` (the ssub encoding), extended in `analyzeInner`.
        // sgm_setpos stages state (a) + pos (b) into arg registers. sgmatch,
        // str2num_* and guard_sid read their sole ref (a) — sgmatch's aux is
        // a konst-pool IMMEDIATE, baked at emission, never a ref. The scap
        // projections read NEITHER operand: the lowering reads the BAKED
        // `match_scratch` address (a is only the SSA-ordering token, b the
        // slot immediate) — the href precedent.
        .sfindp, .smatch, .sgm_setpos => .{ .a = true, .b = true },
        .sgmatch, .str2num_i, .str2num_f, .guard_sid => .{ .a = true, .b = false },
        .scap_int, .scap_str => .{ .a = false, .b = false },
        // guard_fits reads the value it range-checks (a); guard_append reads the aref
        // token (a) and reaches len/cap/hash through aref.a — no second operand.
        .guard_fits, .guard_append => .{ .a = true, .b = false },
        // href reads NEITHER operand: the cell pointer comes from the seeded slab slot
        // (`ins.aux`), not from the table (a) or key konst (b). hload reaches the cell
        // through the href token (a). hstore reads the href token (a) plus the value to
        // write (b). guard_hash reads the href token (a) it is anchored on (lowers to
        // nothing, but operand liveness must keep the href live across it).
        .href => .{ .a = false, .b = false },
        .hload, .guard_hash => .{ .a = true, .b = false },
        .hstore => .{ .a = true, .b = true },
        // Doc 43 P5: uref reads nothing (the cell pointer comes from the
        // seeded slab slot, `ins.aux` — the href discipline); uload reaches
        // the cell through the uref token (a); ustore reads token + value.
        .uref => .{ .a = false, .b = false },
        .uload => .{ .a = true, .b = false },
        .ustore => .{ .a = true, .b = true },
        // grid (doc 14): garow reads table (a) + row (b); gcell reads the garow token
        // (a) + col (b); gstore reads the gcell token (a) + value (b); guard_gcol reads
        // the gcell token (a) + the column ref (b) it range-checks. gload reaches the
        // cell through the gcell token (a). guard_gpresent reads the gcell token (a).
        // guard_grid/guard_stride reach the table through their slot_load operand (a).
        .garow, .gcell, .gstore, .guard_gcol => .{ .a = true, .b = true },
        .gload, .guard_gpresent, .guard_grid, .guard_stride => .{ .a = true, .b = false },
        else => .{ .a = false, .b = false },
    };
}
