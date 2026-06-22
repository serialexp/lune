//! Trace recorder + trace IR — the heart of the JIT (Phase 5).
//!
//! A tracing JIT works by watching tier-0 execute, noticing when a loop runs
//! *hot*, and **recording** one iteration of that loop into a linear,
//! single-assignment IR specialised to the types it actually observed. Later
//! tiers (Phase 6: IR-interpreter; Phase 8: native codegen) *execute* that IR;
//! this module only **records** it. Recording is deliberately *transparent* —
//! tier-0 still performs every operation, so a program's observable behaviour is
//! identical whether the recorder is on or off. That invariant is the recorder's
//! decisive correctness test (`interp.zig`, the `expectProgram` matrix).
//!
//! Two pieces live here:
//!   * the **trace IR** — `IrOp`/`IrInstr`/`Trace`, plus a disassembler. This is
//!     the cache-sensitive representation the architecture reserves for the JIT
//!     (docs/design/00-architecture.md §Value representation), kept separate from
//!     the tier-0 bytecode (`bytecode.zig`).
//!   * the **recorder** — `TraceState` (hotness counters, the trace cache, and
//!     the in-progress `Recorder`) and its state machine (`onBackEdge`).
//!
//! Policy is set by docs/design/01-trace-lifecycle.md. Phase 5a (this increment)
//! lands hotness detection, recording with type guards, and the abort policy;
//! executing traces, deopt/side-exit restore, blacklist backoff, side traces, and
//! cache invalidation are later phases (named there, not built here).

const std = @import("std");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const io = @import("io.zig");
const tropt = @import("tropt.zig");
const execlog = @import("execlog.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");

// ---------------------------------------------------------------------------
// Trace IR
// ---------------------------------------------------------------------------

/// An SSA value reference: an index into a trace's `instrs` array. Every IR
/// instruction defines exactly one value, named by its position.
pub const Ref = u16;

/// Index into the (future) per-guard snapshot table. A placeholder in Phase 5a —
/// the field exists from day one so the deopt machinery (Phase 6) is a body to
/// fill in, not a schema change. See docs/design/01-trace-lifecycle.md.
pub const SnapIdx = u32;

/// The type the recorder *observed* for a value, and therefore the type a guard
/// pins / the result type the recorder inferred. Drives guard insertion now and
/// type-narrowing in the Phase 6 optimizer.
pub const ObsType = enum(u8) { unknown, int, float, boolean, nil, heap };

/// Trace IR opcode. Mirrors the arithmetic/compare subset of the tier-0 ISA
/// (`bytecode.OpCode`) plus the constructs unique to a linear trace: value
/// *inputs* (`slot_load`/`konst`), *guards* (the runtime checks that keep the
/// straight-line trace valid), and the `loop` back-edge marker.
pub const IrOp = enum(u8) {
    // ---- inputs ----
    /// `aux` = tier-0 register read at trace entry (a loop-variant input).
    slot_load,
    /// `aux` = index into the trace's `consts` pool.
    konst,

    // ---- arithmetic / bitwise (R = a op b) ----
    add,
    sub,
    mul,
    div,
    idiv,
    mod,
    pow,
    band,
    bor,
    bxor,
    shl,
    shr,

    // ---- unary (R = op a) ----
    neg,
    not,
    bnot,

    // ---- comparisons (R = a cmp b → boolean). gt/ge normalise to lt/le with
    //      swapped operands, exactly as tier-0 does. ----
    eq,
    ne,
    lt,
    le,

    // ---- guards (check `a`; on failure the future executor side-exits to
    //      tier-0 via the snapshot). ----
    guard_int,
    guard_float,
    guard_number,
    guard_true,
    guard_false,

    // ---- lane-aware packed-array access (Phase B) ----
    //
    // These reach a table's dense array part (`array.zig`) directly, at its
    // current lane. The 3-input store (table, index, value) won't fit a 16-byte
    // `IrInstr`, so `aref` *pairs* the (table, index) addressing into one node and
    // `aload`/`astore` reference it plus at most one more operand. `aux` on every
    // op below is the `array.Lane` ordinal the access was recorded against.
    //
    /// `a`=table value ref, `b`=index ref → element address descriptor. Carries no
    /// usable `Value` (its operands are what `aload`/`astore` read); native kind
    /// is a raw pointer (`Kind.ptr`).
    aref,
    /// `a`=`aref` ref → decode the packed slot to a `Value` (int/boolean per lane).
    aload,
    /// `a`=`aref` ref, `b`=value ref → encode `b` into the packed slot (the FIRST
    /// mid-iteration heap mutation; see `02-determinism.md`). Effectful: never DCE'd
    /// and a CSE/alias barrier for later `aload`s. The recorder only emits it when
    /// the store is in-lane + in-bounds and its value does NOT depend on any prior
    /// `aload` (C1 deopt-replay idempotence), so re-running the iteration on a
    /// side-exit reproduces the same heap.
    astore,

    // ---- array-access guards (check via the referenced node; side-exit on miss) ----
    /// `a`=table value ref → the value is a heap table **with no metatable**.
    /// Recording aborts on a metatable-bearing table (`AbortReason.has_metatable`),
    /// so every trace assumes raw array access; the no-metatable half of this guard
    /// catches a `setmetatable` that lands between trace entries (chunk 2a) and
    /// side-exits to tier-0, which does full `__index`/`__newindex` dispatch.
    guard_table,
    /// `a`=table value ref, `aux`=lane → the table's array lane equals `aux`
    /// (bails if a monotonic widen moved it past the recorded lane).
    guard_lane,
    /// `a`=`aref` ref → the index is in the array part: `(index-1) <u len`.
    guard_bounds,
    /// `a`=`aref` ref → the slot is present (narrow-lane presence bit set); a hole
    /// would read as `nil`, which the native int/boolean path can't represent.
    guard_present,
    /// `a`=value ref, `aux`=lane → the int value fits the narrow int lane's signed
    /// range (i8/i16/i32). Emitted before an int-lane `astore` so that a value
    /// which would force a tier-0 lane WIDEN (an alloc+relayout native can't do
    /// mid-run) side-exits to tier-1a instead of being silently truncated. The
    /// bool lane and the i64 lane need no such guard — every value fits.
    guard_fits,

    // ---- close ----
    /// Loop back-edge: the end of the straight-line trace. Carries no operands;
    /// the loop-carried register writes are the slot-bound `phi` nodes (each
    /// `phi` with `aux >= 0` flushes its update to that register at the back-edge).
    loop,

    // ---- loop-carried value (Phase E) ----
    /// A first-class loop-carried value (a φ at the loop header). `b` = the value
    /// carried to the next iteration (the *update*; the body def — what an
    /// `exit_store.ref` used to name), `aux` = the tier-0 register `slot` this φ
    /// flushes to at commit/deopt (a *slot-bound* φ, `aux >= 0`), or **-1** for an
    /// *internal* φ that backs no register (strength-reduction's running
    /// accumulator). `ty` = carried scalar type.
    ///
    /// The *init* (the value on loop entry) differs by kind: a **slot-bound** φ's
    /// init is implicit — it is `regs[aux]`, read fresh each entry exactly as the
    /// matching `slot_load` does — so `a` is unused (kept 0). An **internal** φ has
    /// no register, so its init is an explicit ref: `a` = the preheader value
    /// (Phase E1's hoisted region), seeded once on the first iteration.
    ///
    /// A φ whose value is read in the body is *carried* (gets a home + the back-edge
    /// shuffle); a slot-bound φ never read is *write-only* (just flushed). `b` is the
    /// one operand allowed to reference a *later* node (the back-edge), exactly as
    /// `exit_store.ref` always could — well-formedness validates `b < last`, not
    /// `b < i`. Replaces the implicit `slot_load`+`exit_store` carry (a slot-bound φ
    /// + its `slot_load` is what an `exit_store`/`slot_load` pair was). Appended at
    /// the enum's end so `loop`'s ordinal stays stable for the wire format.
    phi,

    // ---- loop region boundary (Phase E1: LICM) ----
    /// Marks the end of the **preheader** region. Every instruction *before* this
    /// marker runs exactly **once** (on loop entry); every instruction *after* it
    /// (up to and including `loop`) runs **every iteration**. Carries no operands
    /// and produces no value — a pure structural boundary, the run-once analogue of
    /// the terminal `loop` marker. Synthesized only by the LICM pass (`tropt.zig`):
    /// a freshly-recorded trace has none, so its absence is the common case and the
    /// executor's `body_start == 0` fast path is byte-identical to pre-E1 behaviour.
    ///
    /// Linear SSA already guarantees a preheader instruction (index < marker) can
    /// only reference earlier instructions (all in the preheader) — the hoisted
    /// region is self-contained by construction. A `phi` never sits in the
    /// preheader (loop-carried values run every iteration); `assertWellFormed`
    /// enforces both that and the at-most-one-marker rule. Appended last so every
    /// prior ordinal (incl. `loop`/`phi`) stays stable for the wire format.
    preheader,

    // ---- float→int loop-limit specialization (numeric-for) ----
    /// `a` = a float value ref → its **exact integer value** (`ty == .int`), OR a
    /// side-exit if the float is not an integer representable in `[-2^63, 2^63)`
    /// (`value.floatAsExactInt` returns null). Both a value producer AND a guard.
    ///
    /// Emitted by `recForLoop` when a numeric-`for` has an int index+step but a
    /// **float** limit whose observed value is an exact integer: tier-0 compares the
    /// int index against the float limit EXACTLY (`compareIntFloat`), and for an
    /// integral limit `L` in range `idx <= L ⟺ idx <= (i64)L`, so converting the
    /// loop-invariant limit to an int once makes the body compare int-vs-int — which
    /// the native backend can lower (a mixed int/float compare bails). If a later
    /// entry's limit is non-integral the op side-exits at the loop header (completed
    /// unchanged) and tier-0 runs the loop with the exact mixed compare. `aux` carries
    /// the recording PC for exit-PC chaining, like the other side-exiting guards.
    /// Appended last so every prior op's wire ordinal stays stable.
    int_of_float,

    // ---- array-growth (append) store path (capacity-bounded grow) -------------
    /// `a` = `aref` ref → the append precondition guard, the grow analogue of
    /// `guard_bounds`. Side-exits to tier-0 unless ALL hold for the `aref`'s table
    /// at runtime: (1) the hash part is empty (so `Table.set`'s `migrateFromHash`
    /// would be a no-op — native/oracle skip it), (2) `idx == len+1` (the key is the
    /// exact append successor — the store lands at `data[len]`), and (3) `len < cap`
    /// (room to grow *without* a realloc). On a side-exit tier-0 runs the iteration:
    /// it `append`s — doubling `cap` via `ensureCapacity` when (3) fails, or absorbing
    /// a hash successor when (1) fails — then the loop re-enters. Because the realloc
    /// only ever happens on this side-exit (never on-trace), `len`/`cap`/`data` stay
    /// byte-identical across tier-0 / tier-1a / native (the B5 invariant, extended to
    /// growth: the array is never reallocated *on-trace*). Marks the `aref`
    /// bounds-checked (the store at `data[len]` is in-cap), like `guard_bounds`.
    /// Appended last so every prior op's wire ordinal stays stable.
    guard_append,
    /// `a` = `aref` ref, `b` = value ref → append the value as the new key `len+1`,
    /// writing `data[len]` in the lane encoding and bumping `len` by one. The grow
    /// analogue of `astore`: the FIRST mid-iteration *length-changing* heap mutation.
    /// Behind a dominating `guard_append` (room + shape + empty hash proven) and a
    /// `guard_fits` (value in-lane), so it neither reallocs, widens, nor migrates —
    /// `irinterp` lowers it to `ArrayPart.appendInCap`. Effectful (never DCE'd, an
    /// alias/CSE barrier, and — unlike `astore` — it *writes* `len`, so `guard_append`
    /// can never be hoisted above it). Produces no value. Boolean lane only in Phase A.
    /// Appended last so every prior op's wire ordinal stays stable.
    astore_append,
};

/// Sentinel `phi.aux` for an *internal* φ (strength-reduction accumulator) that
/// flushes to no tier-0 register. A slot-bound φ stores its register index (≥ 0).
pub const PHI_INTERNAL: i32 = -1;

/// One IR instruction. `a`/`b` are operand `Ref`s (or unused); `aux` carries a
/// slot index (`slot_load`) or const-pool index (`konst`); `ty` is the inferred
/// result / guarded type; `snap` is the deopt-snapshot index for guards.
pub const IrInstr = struct {
    op: IrOp,
    a: Ref = 0,
    b: Ref = 0,
    aux: i32 = 0,
    ty: ObsType = .unknown,
    snap: SnapIdx = 0,
};

/// The bytecode PC recorded in a guard's `aux`, or null if this op doesn't carry
/// one. ONLY `guard_int/float/number/true/false` stamp their recording PC into
/// `aux` (see `emit`); the array guards (`guard_lane`, `guard_fits`) reuse `aux`
/// for lane ordinals, and the rest leave it zero — so reading `aux` as a PC there
/// is a category error that can mis-key a guard-failure counter or, worse, chain
/// to an unrelated trace. Exit-PC chaining (`tryChainExit`) and guard-failure
/// counting MUST resolve the exit PC through this accessor — never read `.aux`
/// directly. Returns the PC for the five PC-carrying guards (which may legitimately
/// be 0); callers treat 0 as "no usable PC" since no loop-body guard sits at PC 0.
pub fn guardExitPc(ins: IrInstr) ?u32 {
    return switch (ins.op) {
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float => @intCast(ins.aux),
        else => null,
    };
}

/// A loop-carried writeback: at the back-edge, tier-0 register `slot` holds the
/// value produced by IR `ref`. The set of these is the trace's exit snapshot —
/// what a future executor copies back into the register file each iteration.
pub const SlotStore = struct { slot: u16, ref: Ref };

/// Identifies a trace anchor: a loop header at byte-`pc` within a `Proto`. Loop
/// headers are the only root-trace anchors in Phase 5a (hot side exits seed side
/// traces later).
///
/// The `proto` pointer is *borrowed*, not owned: a cached `Trace` keeps it live
/// only by assumption. In the VM that holds — a hot proto is reachable from a
/// live closure for as long as code can branch to its loop, so it outlives any
/// trace anchored in it. Tests that free the compiled chunk must therefore do so
/// *after* inspecting the cache (see `interp.zig`'s `runForTrace`). When cache
/// invalidation lands (a later phase) this is where proto liveness gets pinned
/// down properly.
pub const AnchorKey = struct { proto: *const Proto, pc: u32 };

/// Per-anchor cooldown record for the gate (`TraceState.gate`). An anchor that
/// thrashed (low-yield penalty maxed) or could not be traced (abort / commit
/// failure) is held off until its back-edge counter reaches `retry_at`. On the
/// retry it is given one more chance; a re-failure calls `gateAnchor` again,
/// which doubles `window` (capped at `config.backoff_max`) and bumps `strikes`.
/// At `config.max_strikes` the anchor is abandoned permanently. The schedule is
/// counted in the deterministic global back-edge `tick` (which advances on *every*
/// back-edge, including ones the hot-count pre-filter skips), so the cooldown keeps
/// elapsing while a gated anchor is being cheaply skipped, and is reproducible.
pub const Gate = struct {
    /// Global `tick` value at/after which the anchor becomes eligible again.
    retry_at: u64,
    /// Length of the *next* cooldown window (back-edges); doubles per escalation.
    window: u32,
    /// How many times this anchor has been gated; `>= max_strikes` ⇒ permanent.
    strikes: u32,
};

/// Identifies a guard-failure site: the trace anchor and the bytecode PC of the
/// failing guard instruction (stored in the guard's `aux` field by the per-guard
/// PC recording, step 2).  Used to count how often a specific guard fails, so
/// side-trace recording (step 4) can be triggered at the right threshold.
pub const GuardKey = struct { anchor: AnchorKey, exit_pc: u32 };

/// The kind of type a trace's entry guard enforces on a register.
pub const EntryGuardType = enum(u8) {
    int,
    float,
    number, // accepts both int and float (guard_number)
    table,
};

/// A register and the type it must have for this trace to be entered.
/// Pairs are computed from the trace's IR at commit time and stored as a
/// runtime-only fingerprint — not serialized.
pub const EntryGuard = struct { slot: u16, ty: EntryGuardType };

/// A completed, cached trace: the recorded IR plus the entry/exit snapshots that
/// connect it back to tier-0 register slots. Immutable once committed (Phase 5a
/// never invalidates a cached trace — see the lifecycle doc).
pub const Trace = struct {
    anchor: AnchorKey,
    /// The straight-line IR, terminated by a `loop` instruction.
    instrs: []IrInstr,
    /// Constants referenced by `konst` instructions (may include heap values, so
    /// the collector roots these — see `Vm.collect`).
    consts: []Value,
    /// Tier-0 registers read as inputs, in `slot_load` order (the entry snapshot).
    entry_slots: []u16,
    /// Entry type guards extracted from the IR at commit time: for each register
    /// this trace guards on entry, the type it must have.  Used by
    /// `matchesFingerprint` to skip non-matching traces without a trial entry.
    /// Runtime-only — not serialized.
    entry_guards: []EntryGuard,
    /// Tier-1b native-codegen cache (Phase 8): lazily compiled machine code for
    /// this trace, or a terminal `unsupported` verdict. `unattempted` until the
    /// first native dispatch (`TraceState.nativeFor`). Runtime-only — not part of
    /// the serialized trace; the page is freed in `destroy`.
    native: nativegen.NativeState = .unattempted,
    /// Runtime counter: how many times this trace has committed a useful
    /// number of iterations (>= `min_useful`).  Used by `findTrace` to
    /// return the most-successful trace first — a stable frequency-based
    /// priority that does not thrash on alternating types.
    hit_count: u64 = 0,

    /// Free a heap-allocated trace and its arrays.
    pub fn destroy(self: *Trace, gpa: std.mem.Allocator) void {
        self.native.deinit();
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        gpa.destroy(self);
    }

    /// Check whether the current register types match this trace's entry
    /// type guards (the fingerprint).  Returns true if all guarded slots
    /// have the expected type, or if the trace has no entry guards at all
    /// (hand-built test traces, traces without type guards).
    pub fn matchesFingerprint(self: *const Trace, regs: []const Value) bool {
        for (self.entry_guards) |g| {
            const v = regs[g.slot];
            switch (g.ty) {
                .int => if (!v.isInt()) return false,
                .float => if (!v.isFloat()) return false,
                .number => if (!v.isNumber()) return false,
                .table => if (!v.isHeap() or v.heapType() != .table) return false,
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Recorder + trace state
// ---------------------------------------------------------------------------

/// Why a recording was abandoned. Aborting discards the partial trace and leaves
/// tier-0 entirely untouched; the anchor may be retried later (penalty/blacklist
/// backoff is a later increment — see the lifecycle doc). `recordInstr` and the
/// state machine fill these in (Increment B).
pub const AbortReason = enum {
    /// An opcode the recorder does not yet model (tables, globals, concat, …).
    nyi_opcode,
    /// A `call`/`ret`/`halt` — cross-frame tracing is deferred.
    cross_frame,
    /// A host (`native`) call — always a trace barrier (`02-determinism.md`).
    host_barrier,
    /// The trace exceeded `maxrecord` instructions.
    too_long,
    /// An operand had a type the recorder cannot guard/model here.
    bad_type,
    /// An indexed/appended table carries a metatable, so the access may dispatch
    /// a `__index`/`__newindex` metamethod (chunk 2a). Recording aborts: the
    /// metamethod call would be a trace barrier anyway, and a present-slot raw
    /// read/store could silently skip a metamethod on a *later* iteration if the
    /// table's shape changes. Conservative and exact — these tables run tier-0,
    /// which does full metamethod dispatch. Lifting this needs a
    /// `guard_no_metatable` IR op (deferred perf follow-up).
    has_metatable,
    /// Allocation failed while building the trace.
    alloc,
};

/// Tunables for the recorder. Defaults track LuaJIT's where sensible; all are
/// overridable (tests use tiny thresholds, the CLI flips `enabled`).
pub const TraceConfig = struct {
    /// Master switch. Off by default: with this false the VM behaves exactly as
    /// it did before Phase 5 (no counting, no recording, no trace execution). The
    /// CLI `--trace` / `--dump-traces` flags and tests flip it on.
    enabled: bool = false,
    /// Whether cached traces are *executed* by the tier-1a IR-interpreter
    /// (`irinterp.zig`). On by default once `enabled`; tests set it false to get
    /// Phase-5a behaviour (record only, tier-0 executes everything) and isolate
    /// recorder bugs from executor bugs.
    execute: bool = true,
    /// Whether the trace optimizer (`tropt.zig`) rewrites a trace at commit time
    /// (constant folding, CSE, dead-code elimination). On by default; independent
    /// of `execute` (an unexecuted trace can still be optimized for inspection).
    /// Tests set it false to compare optimized vs raw IR and prove transparency.
    optimize: bool = true,
    /// Back-edge count at which a loop header becomes a trace anchor.
    hotloop: u32 = 56,
    /// Maximum IR instructions in one trace before aborting (`too_long`).
    maxrecord: u32 = 2000,
    /// A trace entry that commits at least this many iterations is "doing real
    /// work" and clears the anchor's re-entry penalty. Loops shorter than this per
    /// entry are exactly where a tracing JIT wins nothing, so retiring them to
    /// tier-0 (below) costs ~nothing.
    min_useful: u32 = 8,
    /// Minimum remaining numeric-`for` trip count for a trace *entry* to be worth
    /// it. At a `for_loop` back-edge whose computed remaining iteration count is
    /// below this, the dispatch loop declines to enter the trace and lets tier-0
    /// run the short loop. This keeps a loop that is profitable for some strides
    /// (the inner nsieve loop runs `m/i` times — huge for small `i`) but trivial
    /// for others (1–7 times for large `i`) from gating its shared anchor on the
    /// trivial runs: declining entry means no `onSideExit` penalty, so the
    /// profitable long runs stay traced. Only applies to `for_loop` (a clean,
    /// computable trip count); while/repeat loops are entered as before. Set to 0
    /// to disable. Heuristic — never affects output, only tiering.
    min_trip_entry: u32 = 24,
    /// After this many *low-yield* trace entries (each committing fewer than
    /// `min_useful` iterations) an anchor is gated off so tier-0 owns the loop —
    /// the brake against re-entry thrash on type-unstable / branchy loops.
    max_penalty: u32 = 8,
    /// Gate backoff (replaces the old permanent blacklist). When an anchor is
    /// gated (low-yield penalty maxed, a recording abort, or a commit failure) it
    /// is held off tier-1 for a *cooldown window* measured in back-edges, after
    /// which it is retried once. Each re-failure doubles the window — a
    /// temporarily-unstable loop recovers cheaply, a hopeless one is retried
    /// exponentially less often. The window is keyed on the deterministic
    /// per-anchor back-edge counter, never wall-clock or RNG, so the retry
    /// schedule is reproducible (lune determinism). `backoff_base` is the first
    /// window; it doubles up to `backoff_max`.
    backoff_base: u32 = 128,
    /// Cap on the doubling cooldown window (back-edges).
    backoff_max: u32 = 1 << 16,
    /// After this many gate escalations on one anchor, give up permanently (the
    /// loop has proven hopeless — e.g. a host call in the body that aborts every
    /// recording, or strict alternation no straight-line trace can amortize).
    max_strikes: u32 = 6,
    /// Guard-failure count at which a side trace is recorded for this
    /// `(anchor, exit_pc)` pair.  When a guard at PC X in a trace anchored
    /// at A fails this many times, the next back-edge to A arms a new
    /// recording that captures the alternate path through the loop body.
    hotguard: u32 = 50,
    /// Record a per-trace **execution log** (`execlog.zig`) for the visualizer's
    /// iteration animation. Off by default (zero cost on the JIT path — the executor
    /// is comptime-specialized); the wasm playground flips it on. Independent of
    /// `execute` (it observes the same executor run).
    record_exec_log: bool = false,
    /// Exec-log detail cap: per trace entry, stop recording per-iteration events once
    /// this many iterations have committed (the side-exit is still recorded; the
    /// entry's `iterations` stays accurate). Bounds the spinning detail.
    exec_log_max_iters: u32 = 16,
    /// Exec-log entry cap: stop recording new entries (exit ramps) for a trace beyond
    /// this many. Bounds total volume for an oft-entered trace.
    exec_log_max_entries: u32 = 64,
    /// Tier-1b: compile a hot trace to native x86-64 machine code (`nativegen.zig`)
    /// and run that instead of the tier-1a IR-interpreter. Off by default; the CLI
    /// `--jit-native` flips it on. x86-64/Linux only — elsewhere (incl. wasm) the
    /// compiler bails and the trace silently stays on tier-1a. Mutually exclusive
    /// with `record_exec_log` (the viz instrumentation observes the interpreter).
    native_codegen: bool = false,
};

/// Direct-mapped hot-count table size (a power of two). A back-edge hashes its
/// `(proto, pc)` into this many `u16` slots; the table is a cheap pre-filter that
/// lets a *gated* anchor skip the per-back-edge hashmap bookkeeping in
/// `onBackEdge` entirely (it just decrements a slot and bails). Sized generously
/// — any real program has a handful of hot loops, so collisions (two anchors
/// sharing a slot) are rare and, when they happen, only cost extra slow-path
/// visits, never correctness. 2^11 = 2048 slots = 4 KiB inline in `TraceState`.
const HOTCOUNT_BITS = 11;
const HOTCOUNT_SIZE = 1 << HOTCOUNT_BITS;
/// Skip window installed on a *gated* anchor: the number of back-edges its
/// hot-count slot suppresses before the slow path re-checks the gate. Kept modest
/// so a transiently-gated loop whose cooldown elapses still re-enters its trace
/// within a small, bounded number of iterations (recovery responsiveness) while
/// still cutting the per-back-edge cost of a permanently-dead loop by ~this factor.
const GATE_SKIP: u16 = 64;

/// Hash `(proto, pc)` into a hot-count slot. Pointer-based, like the existing
/// `AutoHashMap(AnchorKey, …)` keys — trace timing already varies across runs by
/// address, which is sound because the trace cache is runtime-only state (never
/// serialized) and traces are output-transparent (== tier-0). A collision only
/// changes *which* back-edges take the slow path, never the result.
inline fn hotIndex(proto: *const Proto, pc: u32) usize {
    var h: usize = @intFromPtr(proto);
    h ^= @as(usize, pc) *% 0x9E3779B97F4A7C15;
    h ^= h >> 29;
    return h & (HOTCOUNT_SIZE - 1);
}

/// All recorder state owned by a `Vm`: the hotness counters, the cache of
/// committed traces, and the single in-progress `Recorder`.
pub const TraceState = struct {
    gpa: std.mem.Allocator,
    config: TraceConfig = .{},
    /// Back-edge counters keyed by loop-header anchor. Only touched on the *slow*
    /// path (when the hot-count pre-filter trips), so for a non-gated anchor it
    /// still counts every back-edge (the pre-filter leaves un-gated slots at 0),
    /// preserving the arm-at-`hotloop` timing exactly. A gated anchor's count is
    /// coarse (the pre-filter skips most of its back-edges), which is fine — the
    /// gate's own cooldown is driven by `tick`, not this.
    counters: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Monotonic global back-edge tick. Incremented on *every* back-edge in the
    /// dispatch loop — including ones the hot-count pre-filter skips — so it is the
    /// one clock that never freezes. The gate's `retry_at` cooldown is measured in
    /// these ticks, which is why a transiently-gated loop's cooldown keeps elapsing
    /// while the pre-filter is cheaply skipping its back-edges. Deterministic.
    tick: u64 = 0,
    /// Direct-mapped hot-count pre-filter (see `hotIndex`/`HOTCOUNT_SIZE`). A slot
    /// holds the number of back-edges to skip cheaply before re-consulting the slow
    /// path for the anchor(s) that hash there. Zero ⇒ take the slow path now. Set
    /// to `GATE_SKIP` when an anchor is found gated, so a dead loop's millions of
    /// back-edges cost an array decrement instead of three hashmap probes apiece.
    hotcount: [HOTCOUNT_SIZE]u16 = @splat(0),
    /// Committed traces. A linear scan is fine — the cache is small in Phase 5a
    /// and never invalidated.
    cache: std.ArrayListUnmanaged(*Trace) = .empty,
    /// Anchors currently held off tier-1 with a doubling cooldown (`Gate`). Set
    /// when a recording aborts, a commit fails, or the low-yield re-entry penalty
    /// maxes out. Unlike the old permanent blacklist, an anchor here is *retried*
    /// once its cooldown window of back-edges elapses; a re-failure doubles the
    /// window, and after `config.max_strikes` escalations it is abandoned for
    /// good. A loop that was only *temporarily* unstable (type-unstable early,
    /// then settled) recovers; see `isGated` / `gateAnchor`.
    gate: std.AutoHashMapUnmanaged(AnchorKey, Gate) = .empty,
    /// Re-entry penalty per anchor: a low-yield trace entry bumps it, a useful one
    /// clears it; at `config.max_penalty` the anchor is gated off with a doubling
    /// cooldown (`onSideExit` → `gateAnchor`).
    penalty: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Total trace entries executed (incremented in the dispatch loop before each
    /// `irinterp.execute`/native run). Diagnostic only — used to confirm the gate
    /// entry-check actually halts re-entry on a thrashing anchor, and a cheap
    /// signal for benchmark analysis (entries ≫ committed-iterations means a
    /// low-yield loop the JIT can't amortize).
    entries: u64 = 0,
    /// The in-progress recording (at most one at a time in Phase 5a).
    rec: Recorder = .{},
    /// Reusable SSA-value scratch for the tier-1a executor (`irinterp.execute`),
    /// indexed by `Ref`. Grown to the longest trace executed and reused across
    /// every entry — never allocated per-iteration or per-entry. Not a GC root
    /// (the executor runs no safepoint; see `irinterp.zig`).
    values_scratch: std.ArrayListUnmanaged(Value) = .empty,
    /// Last guard-failure instruction index, written by the dispatch loop when a
    /// trace side-exits with zero iterations. Used for per-guard PC recording
    /// (exit-PC-aware chaining). `maxInt(u32)` means no guard failed (clean exit
    /// or arith error).
    last_exit_instr: u32 = std.math.maxInt(u32),
    /// Per-guard failure counters for side-trace recording (step 4).  Keyed by
    /// `(anchor, exit_pc)` — each entry tracks how many times a specific guard
    /// in traces at `anchor` has failed.  When a counter crosses `hotguard`,
    /// `wants_side_trace` is set and the next back-edge records a side trace.
    guard_failures: std.AutoHashMapUnmanaged(GuardKey, u32) = .empty,
    /// When non-null, the next back-edge to this anchor will arm a side-trace
    /// recording (even if a trace already exists there).  Set by
    /// `countGuardFailure` when a guard-failure crosses `hotguard`; cleared
    /// by `onBackEdge` when the side trace is armed.
    wants_side_trace: ?AnchorKey = null,
    /// Per-trace execution logs for the visualizer (`execlog.zig`), populated only
    /// when `config.record_exec_log`. Keyed by `trace_id` (cache index). Empty and
    /// untouched on the normal JIT path.
    exec_logs: std.ArrayListUnmanaged(execlog.TraceExecLog) = .empty,
    /// The recorder driving `exec_logs`, lazily created on first use so the off path
    /// allocates nothing. Reused (per-entry scratch retained) across every entry.
    exec_recorder: ?execlog.ExecLogRecorder = null,

    pub fn init(gpa: std.mem.Allocator) TraceState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TraceState) void {
        self.counters.deinit(self.gpa);
        self.gate.deinit(self.gpa);
        self.penalty.deinit(self.gpa);
        self.guard_failures.deinit(self.gpa);
        self.values_scratch.deinit(self.gpa);
        for (self.exec_logs.items) |*l| l.deinit(self.gpa);
        self.exec_logs.deinit(self.gpa);
        if (self.exec_recorder) |*r| r.deinit();
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.deinit(self.gpa);
        self.rec.deinit(self.gpa);
    }

    /// The `ExecLogRecorder` re-targeted at the execution log for `trace_id` (the
    /// trace's cache index), creating the recorder (lazily) and the per-trace log on
    /// first use. Returns null on OOM (the caller then runs the uninstrumented
    /// `execute`). Only called when `config.record_exec_log`.
    pub fn execRecorderFor(self: *TraceState, trace_id: u32) ?*execlog.ExecLogRecorder {
        if (self.exec_recorder == null) {
            self.exec_recorder = execlog.ExecLogRecorder.init(self.gpa, self.config.exec_log_max_iters, self.config.exec_log_max_entries);
        }
        const log = self.execLogFor(trace_id) catch return null;
        const rec = &self.exec_recorder.?;
        rec.retarget(log);
        return rec;
    }

    /// Find-or-create the `TraceExecLog` for `trace_id`. Linear scan — the cache is
    /// small and so is the set of executed traces.
    fn execLogFor(self: *TraceState, trace_id: u32) !*execlog.TraceExecLog {
        for (self.exec_logs.items) |*l| {
            if (l.trace_id == trace_id) return l;
        }
        try self.exec_logs.append(self.gpa, .{ .trace_id = trace_id });
        return &self.exec_logs.items[self.exec_logs.items.len - 1];
    }

    /// The trace cached for `(proto, pc)` with the highest hit count, or null.
    /// Frequency-based prioritisation: the trace that has committed the most
    /// useful iterations is returned first, so the common path is tried before
    /// rare alternatives.  Stable — does not thrash on alternating types.
    pub fn findTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            if (t.anchor.proto == proto and t.anchor.pc == pc) {
                if (best == null or t.hit_count > best_hits) {
                    best = t;
                    best_hits = t.hit_count;
                }
            }
        }
        return best;
    }

    /// Highest-`hit_count` trace at `(proto, pc)` that is not in `visited`, or
    /// null. Same-anchor walks (the dispatch trial loop and exit-PC chaining)
    /// use this with a growing `visited` set so they visit each candidate
    /// **exactly once** and always terminate: a single-`skip` cursor would make
    /// two equal-priority traces cycle `A→B→A→…` forever whenever both zero-exit
    /// on the same registers (e.g. two stale narrow-lane traces once the live
    /// array has widened past both — see widen-eviction).
    pub fn nextTraceExcluding(self: *const TraceState, proto: *const Proto, pc: u32, visited: []const *Trace) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        outer: for (self.cache.items) |t| {
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            for (visited) |v| {
                if (v == t) continue :outer;
            }
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// Is a trace already cached for this anchor? (Prevents re-arming.)
    pub fn hasTrace(self: *const TraceState, anchor: AnchorKey) bool {
        return self.findTrace(anchor.proto, anchor.pc) != null;
    }

    /// The cache index (`trace_id`) of a cached trace, or null if not present. This
    /// id is the exec-log key and the viz's trace-selection key. Linear scan (the
    /// cache is small; only the instrumented path calls this).
    pub fn traceIndex(self: *const TraceState, t: *const Trace) ?u32 {
        for (self.cache.items, 0..) |c, i| {
            if (c == t) return @intCast(i);
        }
        return null;
    }

    /// A reusable scratch slice of at least `n` `Value`s for the executor. Grows
    /// the backing buffer to the high-water mark and reuses it; never shrinks.
    pub fn valuesScratch(self: *TraceState, n: usize) ![]Value {
        if (self.values_scratch.items.len < n) {
            try self.values_scratch.resize(self.gpa, n);
        }
        return self.values_scratch.items[0..n];
    }

    /// Account for a trace entry that side-exited after committing `completed`
    /// iterations. A useful entry (>= `min_useful`) clears the anchor's penalty
    /// **and any gate** (the loop recovered — forget the backoff history) and
    /// bumps the trace's `hit_count` (frequency-based trace prioritisation); a
    /// low-yield one bumps the penalty, and at `max_penalty` the anchor is gated
    /// off with a doubling cooldown (`gateAnchor`).
    pub fn onSideExit(self: *TraceState, t: *Trace, completed: usize) void {
        const key = t.anchor;
        if (completed >= self.config.min_useful) {
            t.hit_count +|= 1;
            _ = self.penalty.remove(key);
            _ = self.gate.remove(key);
            return;
        }
        const gop = self.penalty.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.max_penalty) {
            self.gateAnchor(key);
        }
    }

    /// Exit-PC chaining (step 3): after trace `failed` side-exited with
    /// `exit_instr`, look for a trace at the guard's bytecode PC and try to
    /// execute it. Returns the number of committed iterations if a side trace
    /// succeeded, or null if no trace was found / all failed. `regs` is the
    /// current register window (coherent for the loop header). The caller
    /// should `continue :outer` on success.
    pub fn tryChainExit(
        self: *TraceState,
        failed: *const Trace,
        exit_instr: u32,
        proto: *const Proto,
        regs: []Value,
    ) ?usize {
        if (exit_instr == std.math.maxInt(u32)) return null;
        // Resolve the exit PC through the op-gated accessor: array guards store a
        // lane ordinal in `aux`, not a PC, so a first-iteration array-guard exit
        // must NOT be interpreted as a chain target (that could execute an
        // unrelated trace against incoherent registers).
        const exit_pc = guardExitPc(failed.instrs[exit_instr]) orelse return null;
        // Skip if no PC recorded (aux==0) or exit PC equals the anchor (same-
        // anchor chaining already tried all traces there).
        if (exit_pc == 0 or exit_pc == failed.anchor.pc) return null;

        // Visit each side trace at `exit_pc` exactly once (highest-hit first).
        // Using a growing `visited` set rather than a single-`skip` cursor is what
        // makes this terminate: two equal-priority side traces that both zero-exit
        // would otherwise cycle `A→B→A→…` forever.
        var visited: [8]*Trace = undefined;
        var nvisited: usize = 0;
        var st: ?*Trace = self.nextTraceExcluding(proto, exit_pc, visited[0..0]);
        while (st) |sct| : (st = if (nvisited < visited.len)
            self.nextTraceExcluding(proto, exit_pc, visited[0..nvisited])
        else
            null)
        {
            if (nvisited < visited.len) {
                visited[nvisited] = sct;
                nvisited += 1;
            }
            const sbuf = self.valuesScratch(sct.instrs.len) catch continue;
            const sresult = irinterp.execute(sct, regs, sbuf);
            if (sresult.completed > 0) {
                self.onSideExit(sct, sresult.completed);
                return sresult.completed;
            }
            self.onSideExit(sct, 0);
        }
        return null;
    }

    /// Count a guard failure at `exit_pc` within a trace anchored at `anchor`.
    /// When the counter crosses `config.hotguard`, sets `wants_side_trace` so
    /// the next back-edge records a side trace for the alternate path.
    /// Called from the dispatch loop after a zero-iteration guard failure.
    pub fn countGuardFailure(self: *TraceState, anchor: AnchorKey, exit_pc: u32) void {
        // Don't bother counting if we already have multiple traces here —
        // additional side traces beyond the first few have diminishing returns
        // and cause unbounded cache growth on alternating-type loops.
        if (self.countTracesAt(anchor) >= 2) return;

        const key = GuardKey{ .anchor = anchor, .exit_pc = exit_pc };
        const gop = self.guard_failures.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.hotguard and self.wants_side_trace == null) {
            self.wants_side_trace = anchor;
        }
    }

    /// Count a fingerprint miss: no cached trace at `anchor` matched the
    /// current register types.  Uses the same side-trace threshold
    /// (`config.hotguard`) as `countGuardFailure`, but the key has
    /// `exit_pc == 0` to distinguish it from real guard failures.
    /// Called from the dispatch loop when all traces are skipped by
    /// fingerprint mismatch.
    pub fn countFingerprintMiss(self: *TraceState, anchor: AnchorKey) void {
        if (self.countTracesAt(anchor) >= 2) return;
        // exit_pc == 0 marks this as a fingerprint miss, not a specific
        // guard failure.  Shares the same counter namespace for the
        // hotguard threshold.
        const key = GuardKey{ .anchor = anchor, .exit_pc = 0 };
        const gop = self.guard_failures.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* >= self.config.hotguard and self.wants_side_trace == null) {
            self.wants_side_trace = anchor;
        }
    }

    /// How many cached traces are at this anchor?
    fn countTracesAt(self: *const TraceState, anchor: AnchorKey) usize {
        var n: usize = 0;
        for (self.cache.items) |t| {
            if (t.anchor.proto == anchor.proto and t.anchor.pc == anchor.pc) n += 1;
        }
        return n;
    }

    /// Widen-eviction predicate: is trace `t` permanently dead because the live
    /// array its `guard_lane` pins has monotonically widened past the trace's
    /// recorded lane?  A trace specialises on `tbl.array.lane == aux`; lanes only
    /// ever widen (`array.zig`, `Lane.canWidenTo`) and never re-narrow, so once
    /// the live table sits on a lane that cannot reach the recorded lane, the
    /// guard can never pass again.  Re-derived from the live `regs` (not the
    /// failing-guard index), so it holds identically whether the trace ran on
    /// tier-1a or native — the native path doesn't report which guard failed.
    ///
    /// Returns true if *any* of `t`'s entry `guard_lane`s is now unsatisfiable.
    /// Reading a now-wider lane off a *different* table that happens to flow
    /// through the same anchor is a benign false positive: eviction only drops a
    /// cache entry (tier-0 stays the oracle and the trace simply re-records), it
    /// can never change observable output.
    pub fn laneWidenedPast(self: *const TraceState, t: *const Trace, regs: []const Value) bool {
        _ = self;
        for (t.instrs) |ins| {
            if (ins.op != .guard_lane) continue;
            // `guard_lane.a` indexes the table-producing instr; that is a
            // `slot_load` whose `aux` is the tier-0 register the table lives in.
            const ld_idx: usize = @intCast(ins.a);
            if (ld_idx >= t.instrs.len) continue;
            const ld = t.instrs[ld_idx];
            if (ld.op != .slot_load) continue;
            const reg: usize = @intCast(ld.aux);
            if (reg >= regs.len) continue;
            const v = regs[reg];
            if (!v.isHeap() or v.heapType() != .table) continue;
            const live_lane = table_mod.Table.fromHeader(v.asHeap()).array.lane;
            const trace_lane: arr.Lane = @enumFromInt(ins.aux);
            if (live_lane != trace_lane and !live_lane.canWidenTo(trace_lane)) return true;
        }
        return false;
    }

    /// Remove a trace from the cache and free it. Used by widen-eviction to
    /// retire a permanently-dead trace so its per-anchor slot frees up for the
    /// stabilised wider-lane trace. Cache entries are `*Trace`, so removing one
    /// never invalidates pointers to the others — but the caller must NOT be
    /// mid-iteration over the cache through this trace (see the dispatch loop,
    /// which defers eviction until after its same-anchor walk completes).
    pub fn removeTrace(self: *TraceState, t: *Trace) void {
        for (self.cache.items, 0..) |c, idx| {
            if (c == t) {
                const anchor = t.anchor;
                _ = self.cache.swapRemove(idx);
                t.destroy(self.gpa);
                // Reopen the anchor for re-recording. `onBackEdge` only arms when
                // its hot-counter *crosses* `hotloop` (a one-shot `==`), so an
                // anchor whose counter is already past that point would never
                // re-record after losing its trace — the loop would run the rest
                // fully tier-0. Resetting the counter lets the next `hotloop`
                // back-edges re-arm a recording, which now observes the
                // stabilised wider lane. Only do this once the anchor has no
                // traces left (a still-populated anchor re-records via its own
                // side-trace path and `hasTrace` would block re-arming anyway).
                // Bounded by the lattice depth: an anchor widens at most
                // value←i64←i32←i16←i8 / boolean / f64 times before it stabilises.
                if (self.countTracesAt(anchor) == 0) {
                    if (self.counters.getPtr(anchor)) |cnt| cnt.* = 0;
                }
                return;
            }
        }
    }

    /// Remove all guard-failure entries for `anchor`. Called after a side
    /// trace is armed so the counter resets and doesn't re-trigger infinitely.
    fn clearGuardFailures(self: *TraceState, anchor: AnchorKey) void {
        var to_remove: std.ArrayListUnmanaged(GuardKey) = .empty;
        var iter = self.guard_failures.keyIterator();
        while (iter.next()) |k| {
            if (k.anchor.proto == anchor.proto and k.anchor.pc == anchor.pc) {
                to_remove.append(self.gpa, k.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            _ = self.guard_failures.remove(k);
        }
        to_remove.deinit(self.gpa);
    }

    /// Resolve (and memoize) the tier-1b native compilation of `t`. Returns a
    /// runnable `CompiledTrace` to take the native path, or `null` to fall back to
    /// the tier-1a IR-interpreter. The first call compiles lazily; the verdict
    /// (`.compiled` page / `.unsupported`) is cached on the trace and never
    /// recomputed. Off-target builds (e.g. wasm) always memoize `.unsupported`.
    pub fn nativeFor(self: *TraceState, t: *Trace) ?*const nativegen.CompiledTrace {
        switch (t.native) {
            .compiled => return &t.native.compiled,
            .unsupported => return null,
            .unattempted => {
                if (nativegen.compile(self.gpa, t)) |ct| {
                    t.native = .{ .compiled = ct };
                    return &t.native.compiled;
                }
                t.native = .unsupported;
                return null;
            },
        }
    }

    /// True while a recording is in flight (the interpreter's recording hook
    /// gates on this).
    pub fn isRecording(self: *const TraceState) bool {
        return self.rec.active;
    }

    /// Is this anchor currently gated off tier-1? True while a cooldown window is
    /// still running (back-edge count below `retry_at`) or the anchor has been
    /// permanently abandoned (`strikes >= max_strikes`). False when no gate exists
    /// or its cooldown has elapsed (eligible for one retry). Gates both recording
    /// re-arm (`onBackEdge`) and trace entry (the dispatch loop).
    pub fn isGated(self: *const TraceState, anchor: AnchorKey) bool {
        const g = self.gate.get(anchor) orelse return false;
        if (g.strikes >= self.config.max_strikes) return true;
        return self.tick < g.retry_at;
    }

    /// Install or escalate the gate on `anchor`: start (or double) the cooldown
    /// window and bump the strike count. The next eligibility is `retry_at` =
    /// current global `tick` + window; the window then doubles (capped at
    /// `backoff_max`) so a repeatedly-failing anchor is retried exponentially
    /// less often, and after `max_strikes` it is abandoned for good. Deterministic
    /// — keyed only on the monotonic back-edge tick, which keeps advancing even
    /// while the hot-count pre-filter is skipping this anchor's back-edges.
    fn gateAnchor(self: *TraceState, anchor: AnchorKey) void {
        const gop = self.gate.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .retry_at = 0, .window = self.config.backoff_base, .strikes = 0 };
        }
        const g = gop.value_ptr;
        g.strikes +|= 1;
        g.retry_at = self.tick +| g.window;
        g.window = @min(g.window *| 2, self.config.backoff_max);
    }

    /// Back-edge count recorded for an anchor (0 if never seen). A loop is "hot"
    /// once this reaches `config.hotloop`.
    pub fn backEdgeCount(self: *const TraceState, anchor: AnchorKey) u32 {
        return self.counters.get(anchor) orelse 0;
    }

    // --- hot-count pre-filter ----------------------------------------------

    /// Cheap front gate for the dispatch back-edge handler. Always advances the
    /// global `tick` (so gate cooldowns keep elapsing), then asks: can this
    /// back-edge skip the expensive slow path (`onBackEdge` + trace-entry lookup)?
    ///
    /// Returns `true` (skip — fall straight back to tier-0) when the anchor's
    /// hot-count slot is still counting down. Returns `false` (take the slow path)
    /// when the slot has reached 0, or while a recording is in flight (recording
    /// must see every back-edge so it can close on its own anchor). Only gated /
    /// dead loops ever get a non-zero slot, so hot traced loops and warming loops
    /// always take the slow path and behave exactly as before the pre-filter.
    pub inline fn skipBackEdge(self: *TraceState, proto: *const Proto, pc: u32) bool {
        self.tick +%= 1;
        if (self.rec.active) return false;
        const slot = &self.hotcount[hotIndex(proto, pc)];
        if (slot.* > 0) {
            slot.* -= 1;
            return true;
        }
        return false;
    }

    /// Called after a back-edge took the slow path *without* entering a trace (the
    /// dispatch loop skips this when a trace entry succeeded). If the anchor is
    /// gated, arm its hot-count slot with a `GATE_SKIP` window so the next batch of
    /// back-edges skips the hashmap bookkeeping entirely. `tick` keeps advancing
    /// across the skip, so the gate's cooldown still elapses on schedule and the
    /// anchor is reconsidered when the window expires.
    pub fn afterBackEdge(self: *TraceState, proto: *const Proto, pc: u32) void {
        if (self.isGated(.{ .proto = proto, .pc = pc })) {
            self.hotcount[hotIndex(proto, pc)] = GATE_SKIP;
        }
    }

    /// Install a precise hot-count skip of `n` back-edges on `anchor`. Used by the
    /// dispatch loop when it declines to enter a numeric-`for` trace on trip-count
    /// grounds: the rest of that short invocation (exactly `trip - 1` back-edges —
    /// the final `for_loop` exits without one) should run on tier-0 without each
    /// back-edge re-paying full `onBackEdge` bookkeeping, but the window must NOT
    /// bleed past this invocation or it could skip the entry of a following
    /// profitable (long) invocation at the same anchor. Because the count is exact,
    /// it never bleeds. Unlike `GATE_SKIP` this does not imply the anchor is gated.
    pub fn armShortLoopSkip(self: *TraceState, proto: *const Proto, pc: u32, n: u64) void {
        self.hotcount[hotIndex(proto, pc)] = @intCast(@min(n, std.math.maxInt(u16)));
    }

    // --- state machine -----------------------------------------------------

    /// Called by the interpreter whenever a back-edge fires (a backward/self jump
    /// to `target_pc`). Drives the trace lifecycle:
    ///  * **recording, this anchor** → the iteration closed cleanly: commit.
    ///  * **recording, another anchor** → an inner-loop back-edge: keep going
    ///    (the `maxrecord` budget bounds inner-loop unrolling).
    ///  * **not recording** → count this back-edge; on *crossing* `hotloop` (and
    ///    if the anchor is neither already traced nor blacklisted), arm a fresh
    ///    recording that begins on the next loop iteration (at the anchor).
    pub fn onBackEdge(self: *TraceState, proto: *const Proto, target_pc: u32, regs: []const Value) void {
        if (self.rec.active) {
            if (self.rec.anchor.proto == proto and self.rec.anchor.pc == target_pc) {
                self.closeTrace(regs);
            }
            return;
        }
        const key = AnchorKey{ .proto = proto, .pc = target_pc };
        const gop = self.counters.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        const count = gop.value_ptr.*;
        // Arm a fresh recording when the anchor first becomes hot, or — if it was
        // gated off after an earlier failure — when its backoff cooldown elapses.
        // Each `==` fires exactly once at the crossing point, so we never re-arm
        // on every later iteration. A gated anchor whose cooldown is still running
        // (or that has exhausted `max_strikes`) is skipped by `isGated`.
        if (!self.hasTrace(key) and !self.isGated(key)) {
            // A gate entry that is no longer `isGated` means its `tick` cooldown has
            // just elapsed → take the one retry now. Arming starts a recording, so
            // the next back-edges are consumed by recording rather than re-arming;
            // we never loop re-arming. A fresh (un-gated) anchor arms on the exact
            // back-edge it first crosses `hotloop`.
            const arm_now = if (self.gate.contains(key))
                true // cooldown elapsed → one retry
            else
                count == self.config.hotloop; // first time crossing hot
            if (arm_now) self.arm(proto, target_pc);
        }
        // Side-trace arming (step 4): a guard inside a trace at this anchor
        // has failed enough times — arm a new recording on the next iteration,
        // even though a trace already exists here.  The side trace will capture
        // the alternate path through the loop body.
        if (self.wants_side_trace) |wanted| {
            if (wanted.proto == proto and wanted.pc == target_pc) {
                if (!self.isGated(key)) {
                    self.arm(proto, target_pc);
                    // Clear guard-failure counters for this anchor so we don't
                    // immediately re-trigger on the next outer-loop iteration.
                    self.clearGuardFailures(key);
                }
                self.wants_side_trace = null;
            }
        }
    }

    /// Begin recording at `target_pc`. Sizes the recorder's register map to the
    /// frame; recording proper begins at the next dispatch-loop iteration (which
    /// is the anchor instruction). On OOM we simply don't arm.
    fn arm(self: *TraceState, proto: *const Proto, target_pc: u32) void {
        self.rec.reset(self.gpa, .{ .proto = proto, .pc = target_pc }, proto.num_registers) catch return;
    }

    /// Abandon the in-flight recording: deactivate, remember why, and gate the
    /// anchor with exponential backoff so it is retried progressively less often
    /// (and abandoned after `max_strikes`). Tier-0 is untouched — nothing was ever
    /// executed from the trace.
    fn abort(self: *TraceState, reason: AbortReason) void {
        self.rec.abort_reason = reason;
        self.rec.active = false;
        self.gateAnchor(self.rec.anchor);
    }

    /// Finalise a cleanly-closed recording into a cached `Trace`. A build failure
    /// is treated like an abort (discard + gate-with-backoff) so we never thrash.
    fn closeTrace(self: *TraceState, regs: []const Value) void {
        _ = regs; // reserved: a richer exit snapshot will read live values here.
        self.commit() catch {
            self.gateAnchor(self.rec.anchor);
        };
        self.rec.active = false;
    }

    /// Copy the in-progress recording into an owned, cached `Trace`. The exit
    /// snapshot is every register the trace *defined* (its loop-carried writes).
    /// When `config.optimize`, the trace optimizer (`tropt.zig`) rewrites the IR
    /// first; an optimizer OOM falls back to caching the *unoptimized* trace
    /// (correct, just slower) rather than failing the commit.
    fn commit(self: *TraceState) !void {
        // The loop-carried writebacks, as slot-bound φ nodes (one per register the
        // trace defined, minus *dead temporaries*), spliced in just before the
        // terminal `loop`. A slot at/above `locals_watermark` is a compiler
        // expression temporary (set only by the anchoring numeric-`for`'s
        // `for_loop`; see `recForLoop`/`Recorder.locals_watermark`): dead at the
        // loop-header resume point on every path and after the loop, so tier-0
        // recomputes it on deopt and post-loop code never reads it — writing it
        // back is pure waste. The `entry_slots` (`readSlot`) guard is a safety net:
        // a slot the trace actually read is never dropped (it is `< watermark`
        // anyway). When the watermark is the `maxInt` sentinel (while / generic-
        // `for` / passed-through `for`), nothing is filtered.
        //
        // A slot-bound φ's init is implicit (`regs[slot]`, read each entry like the
        // matching `slot_load`), so `a` is 0; `b` is the body def (the update).
        // Flush the deferred read-modify-write stores (store-sinking) at the end of
        // the body, below every guard (the body guards + `recForLoop`'s continuation
        // `guard_true`, all already in the stream) and before the φ writebacks +
        // `.loop`. Sinking them below all side-exiting ops makes deopt-replay
        // idempotent: any guard failure leaves *all* of them un-executed, so tier-0
        // re-runs the whole iteration along the original source path and applies
        // exactly that path's stores once each. Flushed FRONT-TO-BACK in the recorded
        // (tier-0 bytecode) order — so two stores that alias the same slot land in the
        // VM's order and last-writer-wins matches tier-0 (`08-multi-store-sinking.md`).
        // This is exactly where inline (non-deferred) `astore`s sit — the body — so
        // the φ block stays contiguous before `.loop`. Gap B (doc 07) was the single
        // store; Gap C (doc 08) generalizes to an ordered set.
        for (self.rec.pending_stores[0..self.rec.pending_store_count]) |ps| {
            try self.rec.instrs.append(self.gpa, .{
                .op = .astore,
                .a = ps.aref,
                .b = ps.value,
                .aux = ps.lane_ord,
            });
        }
        for (self.rec.reg_map, 0..) |s, slot| {
            if (s.state != .def) continue;
            if (slot >= self.rec.locals_watermark and !self.readSlot(@intCast(slot))) continue;
            try self.rec.instrs.append(self.gpa, .{
                .op = .phi,
                .a = 0,
                .b = s.ref,
                .aux = @intCast(slot),
                .ty = self.rec.instrs.items[s.ref].ty,
            });
        }
        try self.rec.instrs.append(self.gpa, .{ .op = .loop });

        const instrs = self.rec.instrs.items;
        const consts = self.rec.consts.items;
        const entry = self.rec.entry_slots.items;

        const fields: tropt.Optimized = if (self.config.optimize)
            tropt.optimize(self.gpa, instrs, consts) catch |e| switch (e) {
                // Never fail a commit (or thrash the anchor) over an optimizer
                // allocation failure: cache the unoptimized trace instead.
                error.OutOfMemory => try tropt.dupe(self.gpa, instrs, consts, entry),
            }
        else
            try tropt.dupe(self.gpa, instrs, consts, entry);
        errdefer {
            self.gpa.free(fields.instrs);
            self.gpa.free(fields.consts);
            self.gpa.free(fields.entry_slots);
        }

        assertWellFormed(fields.instrs, fields.consts.len, self.rec.reg_map.len);

        // Compute the entry type fingerprint: for each guard_int/guard_float/
        // guard_number/guard_table that guards a slot_load, record the
        // (slot, type) pair.  This lets the dispatch loop skip non-matching
        // traces without a trial entry.
        var entry_guards: std.ArrayListUnmanaged(EntryGuard) = .empty;
        // Covers OOM during the append loop (and a failing `toOwnedSlice`, which
        // leaves the list intact). After `toOwnedSlice` succeeds the list owns
        // nothing, so the freed slice gets its own errdefer below.
        errdefer entry_guards.deinit(self.gpa);
        for (fields.instrs, 0..) |ins, i| {
            const egt: ?EntryGuardType = switch (ins.op) {
                .guard_int => .int,
                .guard_float => .float,
                .guard_number => .number,
                .guard_table => .table,
                else => null,
            };
            if (egt) |ty| {
                const ref: u32 = @intCast(ins.a);
                if (ref < i and fields.instrs[ref].op == .slot_load) {
                    const slot: u16 = @intCast(fields.instrs[ref].aux);
                    try entry_guards.append(self.gpa, .{ .slot = slot, .ty = ty });
                }
            }
        }
        const guards_owned = try entry_guards.toOwnedSlice(self.gpa);
        // Covers OOM in `create(Trace)` and the trailing `cache.append` (the
        // `fields` errdefer above frees the IR arrays; this frees the fingerprint).
        errdefer self.gpa.free(guards_owned);

        const t = try self.gpa.create(Trace);
        errdefer self.gpa.destroy(t);
        t.* = .{
            .anchor = self.rec.anchor,
            .instrs = fields.instrs,
            .consts = fields.consts,
            .entry_slots = fields.entry_slots,
            .entry_guards = guards_owned,
        };
        try self.cache.append(self.gpa, t);
    }

    /// Debug-only structural verifier for the invariants the tier-1a executor
    /// (`irinterp.zig`) relies on, so a recorder bug can never become a wild read
    /// at execution time. Compiled out in release builds (`std.debug.assert`).
    ///   * the trace is non-empty and terminates in exactly one `loop`;
    ///   * every operand `Ref` is defined earlier (linear SSA: ref < its index);
    ///   * `slot_load`/`konst` `aux` is in register / const-pool bounds;
    ///   * every `phi` update `b` precedes the `loop` and its `aux` slot is a
    ///     register (or the internal sentinel).
    fn assertWellFormed(instrs: []const IrInstr, consts_len: usize, num_registers: usize) void {
        std.debug.assert(instrs.len >= 1);
        const last = instrs.len - 1;
        std.debug.assert(instrs[last].op == .loop);
        for (instrs, 0..) |ins, i| {
            switch (ins.op) {
                .slot_load => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < num_registers),
                .konst => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len),
                .loop => std.debug.assert(i == last), // the only loop, and it is terminal
                // binary ops read both `a` and `b`.
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .eq, .ne, .lt, .le => {
                    std.debug.assert(ins.a < i and ins.b < i);
                },
                // unary ops and guards read `a` only.
                .neg, .not, .bnot, .guard_int, .guard_float, .guard_number, .guard_true, .guard_false => {
                    std.debug.assert(ins.a < i);
                },
                // `int_of_float` reads its sole float operand `a` (a prior node).
                .int_of_float => std.debug.assert(ins.a < i),
                // `aref` pairs (table, index) into an address descriptor;
                // `astore`/`astore_append` read the `aref` (`a`) and the value (`b`).
                .aref, .astore, .astore_append => std.debug.assert(ins.a < i and ins.b < i),
                // `aload` and the array-access guards read one prior node
                // (the table value, or the `aref`). `guard_append` reads the `aref`.
                .aload, .guard_table, .guard_lane, .guard_bounds, .guard_present, .guard_fits, .guard_append => {
                    std.debug.assert(ins.a < i);
                },
                // φ: the init `a` is an ordinary backward ref (a < i); the update
                // `b` is the back-edge value and may reference a *later* node, like
                // an `exit_store.ref` — only required to precede the `loop` marker.
                // `aux` is the flush slot (a valid register) or the internal sentinel.
                .phi => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < last);
                    std.debug.assert(ins.aux == PHI_INTERNAL or
                        (ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < num_registers));
                },
                // Preheader region boundary (Phase E1): a pure marker, no operands.
                // Structural invariants (at most one; before any φ) are asserted in
                // the global pass below.
                .preheader => {},
            }
        }
        // Preheader structural rules (Phase E1 / LICM): at most one marker, and no
        // `phi` may precede it (loop-carried values must run every iteration, but a
        // φ before the marker would be skipped on iterations 2+).
        var preheader_idx: ?usize = null;
        for (instrs, 0..) |ins, i| {
            if (ins.op == .preheader) {
                std.debug.assert(preheader_idx == null); // at most one
                preheader_idx = i;
            }
        }
        if (preheader_idx) |ph| {
            for (instrs[0..ph]) |ins| std.debug.assert(ins.op != .phi);
        }
    }

    // --- per-instruction recording ----------------------------------------

    /// Mirror one executed tier-0 instruction into the trace IR, reading
    /// *pre-execution* operand values from `regs` to choose type guards. Tier-0
    /// still executes the instruction itself (next, in the dispatch loop) — this
    /// only records. Unsupported opcodes / types abort the recording.
    /// `pc` is the *post-increment* program counter (already advanced past
    /// `instr`), matching what `applyJump(pc, aux)` expects — `recForLoop` uses it
    /// to resolve the `for_loop` back-edge target against the trace anchor.
    pub fn recordInstr(self: *TraceState, instr: Instr, regs: []const Value, proto: *const Proto, pc: u32) void {
        if (self.rec.instrs.items.len >= self.config.maxrecord) return self.abort(.too_long);
        self.rec.cur_pc = pc;
        self.recordOne(instr, regs, proto, pc) catch self.abort(.alloc);
    }

    fn recordOne(self: *TraceState, instr: Instr, regs: []const Value, proto: *const Proto, pc: u32) error{OutOfMemory}!void {
        switch (instr.op) {
            // loads & moves — define the destination, no guards.
            .load_nil => self.setReg(instr.a, try self.konst(Value.nil())),
            .load_bool => self.setReg(instr.a, try self.konst(Value.boolean(instr.b != 0))),
            .load_int => self.setReg(instr.a, try self.konst(Value.int(instr.aux))),
            .load_const => self.setReg(instr.a, try self.konst(proto.constants[instr.b])),
            .move => self.setReg(instr.a, try self.refOf(instr.b)),

            // arithmetic / bitwise / unary.
            .add => try self.recArith(.add, instr, regs),
            .sub => try self.recArith(.sub, instr, regs),
            .mul => try self.recArith(.mul, instr, regs),
            .div => try self.recArith(.div, instr, regs),
            .idiv => try self.recArith(.idiv, instr, regs),
            .mod => try self.recArith(.mod, instr, regs),
            .pow => try self.recArith(.pow, instr, regs),
            .band => try self.recBitwise(.band, instr, regs),
            .bor => try self.recBitwise(.bor, instr, regs),
            .bxor => try self.recBitwise(.bxor, instr, regs),
            .shl => try self.recBitwise(.shl, instr, regs),
            .shr => try self.recBitwise(.shr, instr, regs),
            .neg => try self.recNeg(instr, regs),
            .not => try self.recNot(instr),
            .bnot => try self.recBnot(instr, regs),

            // comparisons (gt/ge normalise to lt/le with swapped operands).
            .eq => try self.recEq(.eq, instr, regs),
            .ne => try self.recEq(.ne, instr, regs),
            .lt => try self.recCompare(.lt, false, instr, regs),
            .le => try self.recCompare(.le, false, instr, regs),
            .gt => try self.recCompare(.lt, true, instr, regs),
            .ge => try self.recCompare(.le, true, instr, regs),

            // control flow.
            .jmp => {}, // straight-line trace: control flow is implicit.
            .jmp_if_false, .jmp_if_true => try self.recBranch(instr, regs),
            .for_loop => try self.recForLoop(instr, regs, pc),

            // a host call is a trace barrier; a Lua call/return is cross-frame.
            .call => {
                const callee = regs[instr.a];
                if (callee.isHeap() and callee.heapType() == .native)
                    self.abort(.host_barrier)
                else
                    self.abort(.cross_frame);
            },
            .ret, .halt => self.abort(.cross_frame),

            // lane-aware packed-array read (Phase B): `t[k]` for an in-bounds
            // dense narrow-lane slot compiles; everything else aborts cleanly.
            .get_index => try self.recArrayGet(instr, regs),

            // lane-aware packed-array write (Phase B): `t[k]=v` for an in-bounds
            // in-lane dense slot whose stored value does not depend on any prior
            // packed-array read (the conservative C1 deopt-replay rule). Everything
            // else aborts cleanly.
            .set_index => try self.recArraySet(instr, regs),

            // tables, globals, upvalues, closures, concat, for_prep, len, …:
            // each pulls in heap-effect / cross-frame / invalidation machinery
            // that is later work. Abort cleanly.
            else => self.abort(.nyi_opcode),
        }
    }

    // --- recording helpers -------------------------------------------------

    /// Append an IR instruction, returning its SSA ref (its index).
    /// For simple type-guard ops (`guard_int`, `guard_float`, `guard_number`,
    /// `guard_true`, `guard_false`), the current bytecode PC is stored in
    /// `aux` so the executor can report which guard failed (per-guard PC
    /// recording for exit-PC chaining). Other ops keep their caller-set `aux`.
    fn emit(self: *TraceState, ins: IrInstr) !Ref {
        var ins_mut = ins;
        switch (ins_mut.op) {
            // `int_of_float` is value-producing but also side-exits, so it stamps
            // its PC for exit-PC chaining like the type guards (its `aux` is unused
            // for anything else — the result kind is `.int`, the operand is `a`).
            .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float => {
                ins_mut.aux = @intCast(self.rec.cur_pc);
            },
            else => {},
        }
        const ref: Ref = @intCast(self.rec.instrs.items.len);
        try self.rec.instrs.append(self.gpa, ins_mut);
        return ref;
    }

    /// Intern a constant into the trace's pool and emit a `konst` for it. A
    /// value seen before reuses its existing `konst` ref (and pool slot) — a
    /// `konst` is pure and operand-free, so sharing its ref is sound. This is
    /// what lets identical subexpressions (e.g. the two `i + 7` in
    /// `(i + 7) * (i + 7)`) end up with identical operand refs, so the
    /// optimizer's CSE can collapse them (see docs / TODO.md).
    fn konst(self: *TraceState, v: Value) !Ref {
        const key = konstKey(v);
        if (self.rec.konst_map.get(key)) |existing| return existing;
        const idx: i32 = @intCast(self.rec.consts.items.len);
        try self.rec.consts.append(self.gpa, v);
        const ref = try self.emit(.{ .op = .konst, .aux = idx, .ty = obsTypeOf(v) });
        try self.rec.konst_map.put(self.gpa, key, ref);
        return ref;
    }

    /// The SSA ref currently held by tier-0 register `slot`. The first read of a
    /// register emits a `slot_load` (a trace input) and records it in the entry
    /// snapshot.
    fn refOf(self: *TraceState, slot: u16) !Ref {
        const s = &self.rec.reg_map[slot];
        if (s.state != .undef) return s.ref;
        const ref = try self.emit(.{ .op = .slot_load, .aux = slot, .ty = .unknown });
        try self.rec.entry_slots.append(self.gpa, slot);
        s.* = .{ .ref = ref, .state = .input };
        return ref;
    }

    /// Record that tier-0 register `slot` now holds the value produced by `ref`
    /// (a loop-carried write — surfaces in the exit snapshot).
    fn setReg(self: *TraceState, slot: u16, ref: Ref) void {
        self.rec.reg_map[slot] = .{ .ref = ref, .state = .def };
    }

    /// Whether tier-0 register `slot` was *read* during this recording (i.e. it is
    /// in the entry snapshot). Used by `commit()` as a safety net so the dead-
    /// temporary filter never drops a slot the trace actually consumed.
    fn readSlot(self: *const TraceState, slot: u16) bool {
        return std.mem.indexOfScalar(u16, self.rec.entry_slots.items, slot) != null;
    }

    /// Emit a type guard for `ref` (deduplicated — an SSA value has one type).
    fn guard(self: *TraceState, ref: Ref, op: IrOp) !void {
        if (self.rec.guarded_refs.contains(ref)) return;
        try self.rec.guarded_refs.put(self.gpa, ref, {});
        _ = try self.emit(.{ .op = op, .a = ref });
    }

    fn guardInt(self: *TraceState, ref: Ref) !void {
        try self.guard(ref, .guard_int);
    }

    fn guardNum(self: *TraceState, ref: Ref, v: Value) !void {
        try self.guard(ref, if (v.isInt()) IrOp.guard_int else IrOp.guard_float);
    }

    fn recArith(self: *TraceState, op: IrOp, instr: Instr, regs: []const Value) !void {
        const vb = regs[instr.b];
        const vc = regs[instr.c];
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb);
        try self.guardNum(rc, vc);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = arithResultType(op, vb, vc) });
        self.setReg(instr.a, r);
    }

    fn recBitwise(self: *TraceState, op: IrOp, instr: Instr, regs: []const Value) !void {
        const vb = regs[instr.b];
        const vc = regs[instr.c];
        if (!vb.isInt() or !vc.isInt()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardInt(rb);
        try self.guardInt(rc);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .int });
        self.setReg(instr.a, r);
    }

    fn recNeg(self: *TraceState, instr: Instr, regs: []const Value) !void {
        const vb = regs[instr.b];
        if (!vb.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        try self.guardNum(rb, vb);
        const r = try self.emit(.{ .op = .neg, .a = rb, .ty = if (vb.isInt()) .int else .float });
        self.setReg(instr.a, r);
    }

    /// `not` works on any value via Lua truthiness, so it needs no type guard —
    /// the IR `not` is defined over truthiness, like tier-0.
    fn recNot(self: *TraceState, instr: Instr) !void {
        const rb = try self.refOf(instr.b);
        const r = try self.emit(.{ .op = .not, .a = rb, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    fn recBnot(self: *TraceState, instr: Instr, regs: []const Value) !void {
        const vb = regs[instr.b];
        if (!vb.isInt()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        try self.guardInt(rb);
        const r = try self.emit(.{ .op = .bnot, .a = rb, .ty = .int });
        self.setReg(instr.a, r);
    }

    fn recCompare(self: *TraceState, op: IrOp, swap: bool, instr: Instr, regs: []const Value) !void {
        const vb = regs[instr.b];
        const vc = regs[instr.c];
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        var rb = try self.refOf(instr.b);
        var rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb);
        try self.guardNum(rc, vc);
        if (swap) {
            const t = rb;
            rb = rc;
            rc = t;
        }
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    /// Record `t[k]` (`get_index`, `dst=a b=table c=key`) as a lane-aware packed-
    /// array read. Emits, in order: `guard_table` + `guard_lane` on the table ref,
    /// `guard_int` on the key, then `aref` (the element address) + `guard_bounds` +
    /// `guard_present` + `aload`. Aborts (leaving tier-0 untouched) unless the
    /// observed access is a *present, in-bounds, narrow-lane* slot — the only shape
    /// the native/oracle read path models:
    ///   * non-table container or non-int key → `.bad_type` (hash-part / metatable
    ///     territory, out of scope);
    ///   * `.value`-lane array → `.nyi_opcode` (the unpacked 16-B path is a
    ///     deferred scope cut — `.value` arrays stay on tier-0/1a);
    ///   * out-of-bounds or hole at record time → `.bad_type` (this iteration would
    ///     immediately side-exit, so the trace would never pay off).
    fn recArrayGet(self: *TraceState, instr: Instr, regs: []const Value) !void {
        // Deferred (sunk) stores must be the LAST array accesses in the trace: an
        // `aload` after any of them would read the pre-store value on-trace while
        // tier-0's deopt-replay (store-then-read) reads the post-store value —
        // divergence. Abort, exactly as the old C1 rule did (no regression). See
        // `docs/design/08-multi-store-sinking.md` §mechanism (and doc 07 §3.2).
        if (self.rec.pending_store_count > 0) return self.abort(.bad_type);
        const vtab = regs[instr.b];
        const vkey = regs[instr.c];
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (!vkey.isInt()) return self.abort(.bad_type);
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        // A metatable means an absent slot could fire `__index` (chunk 2a). Even a
        // present slot today could become a hole on a later iteration, so the only
        // sound conservative choice is to bail the whole trace to tier-0.
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const lane = tbl.array.lane;
        if (lane == .value) return self.abort(.nyi_opcode); // unpacked path deferred
        const idx = vkey.asInt();
        if (idx < 1 or idx > @as(i64, @intCast(tbl.array.len))) return self.abort(.bad_type);
        const loaded = tbl.getInt(idx);
        if (loaded.isNil()) return self.abort(.bad_type); // hole — not a profitable trace

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(instr.b);
        _ = try self.emit(.{ .op = .guard_table, .a = rtab });
        _ = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
        const rkey = try self.refOf(instr.c);
        try self.guardInt(rkey);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        _ = try self.emit(.{ .op = .guard_bounds, .a = ref });
        _ = try self.emit(.{ .op = .guard_present, .a = ref });
        const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
        self.setReg(instr.a, rload);
    }

    /// Record `t[k]=v` (`set_index`, `a=table b=key c=value`) as a lane-aware
    /// packed-array write. Emits, in order: `guard_table` + `guard_lane` on the
    /// table ref, `guard_int` on the key, then `aref` + `guard_bounds` + `astore`
    /// — the FIRST mid-iteration heap mutation in the system. Aborts (leaving
    /// tier-0 untouched) unless the store is a *present, in-bounds, in-lane*
    /// slot whose value is deopt-replay-safe:
    ///   * non-table container or non-int key → `.bad_type` (hash-part / metatable
    ///     territory, out of scope);
    ///   * `.value`-lane array → `.nyi_opcode` (unpacked 16-B path is deferred —
    ///     and a heap value would need a write barrier the native ABI lacks);
    ///   * out-of-bounds (`k>len` would *grow*, `k<1` is the hash part) → `.bad_type`;
    ///   * `nil` value → `.bad_type` (a hole-punch / delete, not a normal store; B3
    ///     models presence-creating writes only — keeps `astore creates presence`);
    ///   * out-of-lane value (a value the current narrow lane can't hold would
    ///     *widen* — a shape change / allocation the native store can't do) →
    ///     `.bad_type`;
    ///   * **C1 (deopt-replay idempotence):** *any* packed-array read (`aload`)
    ///     recorded earlier in this trace → `.bad_type`. On a side-exit, tier-0
    ///     re-runs the aborted iteration against the *already-mutated* heap, so a
    ///     write whose value — OR whose very occurrence (control flow) — was decided
    ///     by a read could double-apply. A *data*-only check is unsound: a guard on a
    ///     read picks the branch, so `if t[i] then t[i]=false else t[i]=true end`
    ///     stores a constant yet replays differently. In a straight-line trace every
    ///     prior guard dominates this store, and every read-derived decision flows
    ///     through a guard, so "no earlier `aload` at all" covers both the data and
    ///     control channels with one obviously-sound rule. nsieve's sieve-clearing
    ///     loop is a pure write of `false` (no `aload`), so the rule costs it nothing.
    fn recArraySet(self: *TraceState, instr: Instr, regs: []const Value) !void {
        // NB (Gap C): unlike the single-store original, a store arriving while other
        // stores are already deferred is NOT blanket-aborted here. An in-bounds RMW
        // store appends to `pending_stores` (the in-bounds path below); an *append*
        // store (which changes `len`) must still abort — handled in the append branch.
        // The `pending_store_count` checks live at those two sites, not at the top,
        // because we cannot tell append-vs-in-bounds until we know `idx`/`len` below.
        // See `docs/design/08-multi-store-sinking.md`.
        const vtab = regs[instr.a];
        const vkey = regs[instr.b];
        const vval = regs[instr.c];
        if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
        if (!vkey.isInt()) return self.abort(.bad_type);
        if (vval.isNil()) return self.abort(.bad_type); // hole-punch — out of scope
        const tbl = table_mod.Table.fromHeader(vtab.asHeap());
        // A metatable means an absent-key store could fire `__newindex` (chunk 2a);
        // the append path below stores to exactly such an absent key (`len+1`).
        // Abort the whole trace to tier-0, which does full `__newindex` dispatch.
        if (tbl.metatable != null) return self.abort(.has_metatable);
        const lane = tbl.array.lane;
        if (lane == .value) return self.abort(.nyi_opcode); // unpacked path deferred
        const idx = vkey.asInt();

        // Grow (append) store: `t[len+1] = v` extends the dense run by one. This is
        // the bulk of an array-fill loop (nsieve's `for i=2,m do p[i]=true end` after
        // its first rehash narrows to the boolean lane and drains the hash). Rather
        // than abort the whole trace (the historic behaviour — the fill then ran fully
        // tier-0), record an `astore_append` guarded so the realloc/migrate cases fall
        // back to tier-0 while the in-capacity common case runs native. Phase A: the
        // boolean lane (one in-band byte/slot) and the fixed-width int lanes
        // (i8…i64: width store + presence bit) — exactly the lanes the native
        // in-bounds `astore` lowers (`nativegen.laneKind`). `.f64` needs XMM stores
        // the array path does not yet emit, so it (and `.value`) still abort below.
        // The emitted IR sequence is lane-generic; `guard_fits` (below) supplies the
        // int lane's runtime range check, and the value's static `.int` kind comes
        // from its producing ref (the loop slot) — same as the in-bounds int store.
        if ((lane == .boolean or lane.isInt()) and
            idx == @as(i64, @intCast(tbl.array.len)) + 1 and
            tbl.hash.count() == 0 and
            tbl.array.fits(vval))
        {
            // Same C1 deopt-replay rule as `astore`: a prior packed-array read could
            // have steered this store's value or occurrence, and re-running the
            // iteration on a side-exit (against the now-longer array) would diverge.
            // (A non-empty `pending_stores` implies a prior `aload`, so this also
            // covers "append after a sunk store" — an append changes `len` and is
            // never deferred; `docs/design/08-multi-store-sinking.md` §soundness.)
            if (self.traceHasArrayLoad()) return self.abort(.bad_type);
            const rval = try self.refOf(instr.c);
            const lane_ord: i32 = @intFromEnum(lane);
            const rtab = try self.refOf(instr.a);
            _ = try self.emit(.{ .op = .guard_table, .a = rtab });
            _ = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
            const rkey = try self.refOf(instr.b);
            try self.guardInt(rkey);
            const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
            // guard_append: hash-empty + `idx==len+1` + `len<cap`. The grow analogue
            // of guard_bounds — side-exits to tier-0 (which reallocs/migrates) when
            // any precondition fails, so the on-trace append never allocates.
            _ = try self.emit(.{ .op = .guard_append, .a = ref });
            // guard_fits: the value still fits the narrow lane (the oracle re-checks a
            // free-variable store; native bool already proves `.bool`). Same as astore.
            _ = try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord });
            _ = try self.emit(.{ .op = .astore_append, .a = ref, .b = rval, .aux = lane_ord });
            return;
        }

        if (idx < 1 or idx > @as(i64, @intCast(tbl.array.len))) return self.abort(.bad_type);
        // The value must fit the current lane unchanged — an out-of-lane store
        // would widen the array (shape change / allocation) which the native ABI
        // cannot perform; the prologue `guard_lane` then stays sufficient.
        if (!tbl.array.fits(vval)) return self.abort(.bad_type);

        // C1 / store-sinking: if this trace has already read the packed array, an
        // inline store would be deopt-unsound — on a side-exit *after* the store,
        // tier-0 re-runs the whole iteration against the mutated heap and a
        // read-modify-write double-applies (the read steered this store's value or
        // its control flow). Instead of aborting, DEFER the store: emit its address
        // + guards inline here, but stash the `astore` node and flush it at trace
        // close (`commit`) below every guard — incl. the `for_loop` continuation
        // guard — so every side-exit leaves the store un-executed and replay stores
        // exactly once. Gap C sinks up to `MAX_PENDING_STORES` such stores (the FFT
        // butterfly writes four), flushed in recorded order; a trace wanting more
        // aborts cleanly here. The post-store invariant (no later `aload`/append, in
        // `recArrayGet` and the append branch) keeps the sunk stores the trace's last
        // array accesses. A pure-write store (no prior `aload`) is deopt-idempotent on
        // its own and emits inline as before. See `docs/design/08-multi-store-sinking.md`.
        const defer_store = self.traceHasArrayLoad();
        if (defer_store and self.rec.pending_store_count >= MAX_PENDING_STORES)
            return self.abort(.bad_type);
        const rval = try self.refOf(instr.c);

        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(instr.a);
        _ = try self.emit(.{ .op = .guard_table, .a = rtab });
        _ = try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord });
        const rkey = try self.refOf(instr.b);
        try self.guardInt(rkey);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        _ = try self.emit(.{ .op = .guard_bounds, .a = ref });
        // Guard at runtime that the value still fits the recorded narrow lane: a
        // later iteration storing an out-of-lane value (an out-of-range/non-int int
        // into an int lane, a non-bool into the bool lane, a non-float into f64)
        // would force tier-0 to WIDEN the lane (alloc + relayout), which the native
        // store can't do mid-run and which would trip the tier-1a oracle's in-place
        // `setInLane` encode (`assert(fits(val))`) — so `guard_fits` side-exits
        // instead and lets tier-0 re-run + widen. Every narrow lane needs this: the
        // `astore` value can be a free variable (a loop-carried slot), not just a
        // constant, so the recorder cannot assume it stays in-lane. (`.value` aborts
        // above, so `lane` here is always narrow.) For the bool lane native lowers
        // this to nothing — the value is already proven `.bool` at analysis time —
        // but the oracle, which runs the raw trace, still needs the runtime check.
        _ = try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord });
        // No `guard_present`: `astore` *creates* presence (the slot is in-bounds by
        // `guard_bounds`; storing a non-nil value sets the presence bit). The store
        // is effectful and not register-defining, so nothing is `setReg`'d.
        if (defer_store) {
            // Read-modify-write: stash the store; `commit()` flushes it (and any
            // siblings) below every guard, just before `.loop`, in this recorded
            // order. The guards above (table/lane/int/bounds/fits) stay inline and
            // continue to dominate the sunk store. The cap was checked above.
            self.rec.pending_stores[self.rec.pending_store_count] =
                .{ .aref = ref, .value = rval, .lane_ord = lane_ord };
            self.rec.pending_store_count += 1;
        } else {
            _ = try self.emit(.{ .op = .astore, .a = ref, .b = rval, .aux = lane_ord });
        }
    }

    /// C1 support: has *any* `aload` (packed-array read) been recorded so far in this
    /// trace? Used by `recArraySet` to refuse a write that follows a read. This is
    /// the conservative-sound C1 rule: in a straight-line trace any earlier read can
    /// influence a later write through its value (data) or through a guard that
    /// selected the path (control), and a side-exit replays the iteration against the
    /// already-mutated heap. Rejecting on the mere presence of an earlier read covers
    /// both channels without per-value taint reasoning. nsieve's write loop has no
    /// `aload`, so it is unaffected.
    fn traceHasArrayLoad(self: *const TraceState) bool {
        for (self.rec.instrs.items) |ins| {
            if (ins.op == .aload) return true;
        }
        return false;
    }

    /// `eq`/`ne`. First cut: numeric operands only (the common loop-condition
    /// case); other types abort.
    fn recEq(self: *TraceState, op: IrOp, instr: Instr, regs: []const Value) !void {
        const vb = regs[instr.b];
        const vc = regs[instr.c];
        if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
        const rb = try self.refOf(instr.b);
        const rc = try self.refOf(instr.c);
        try self.guardNum(rb, vb);
        try self.guardNum(rc, vc);
        const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
        self.setReg(instr.a, r);
    }

    /// `jmp_if_false`/`jmp_if_true`: pin the *observed* truthiness of the tested
    /// register. Which path the trace records is whatever tier-0 took; the guard
    /// is what keeps the straight-line trace valid.
    fn recBranch(self: *TraceState, instr: Instr, regs: []const Value) !void {
        const ra = try self.refOf(instr.a);
        const op: IrOp = if (regs[instr.a].isTruthy()) .guard_true else .guard_false;
        _ = try self.emit(.{ .op = op, .a = ra });
    }

    /// `for_loop` (numeric-for back-edge): record the increment and the
    /// loop-continuation guard, mirroring the opcode. The actual back-edge / close
    /// is handled by `onBackEdge`.
    fn recForLoop(self: *TraceState, instr: Instr, regs: []const Value, pc: u32) !void {
        const a = instr.a;

        // If *this* `for_loop` is the one whose back-edge defines the trace
        // anchor (its target == anchor.pc, computed exactly as the interpreter's
        // `applyJump`), then the trace re-enters / resumes at this numeric-`for`'s
        // body start. Its four control regs occupy `a..a+3` (idx, limit, step,
        // var), so every slot `>= a+4` is a compiler temporary — dead at the body
        // start on every resume path and after the loop. Record the watermark so
        // `commit()` can drop those slots from the exit snapshot. A `for_loop` the
        // trace merely passes through (different target) is ignored.
        const target: u32 = @intCast(@as(i64, pc) + instr.aux);
        if (target == self.rec.anchor.pc) self.rec.locals_watermark = @as(u32, a) + 4;
        const vidx = regs[a];
        const vlimit = regs[a + 1];
        const vstep = regs[a + 2];
        if (!vidx.isNumber() or !vlimit.isNumber() or !vstep.isNumber()) return self.abort(.bad_type);
        const ridx = try self.refOf(a);
        const rlimit = try self.refOf(a + 1);
        const rstep = try self.refOf(a + 2);
        try self.guardNum(ridx, vidx);
        try self.guardNum(rlimit, vlimit);
        try self.guardNum(rstep, vstep);

        // idx_next = idx + step
        const all_int = vidx.isInt() and vstep.isInt();
        const rnext = try self.emit(.{ .op = .add, .a = ridx, .b = rstep, .ty = if (all_int) .int else .float });

        // Float loop-limit specialization: when the index+step are int but the limit
        // is a **float** whose observed value is an exact integer, convert the
        // (loop-invariant) limit to an int once via `int_of_float`, so the body
        // compare is int-vs-int. tier-0 compares int-vs-float EXACTLY, and for an
        // integral limit `L` in i64 range `idx <= L ⟺ idx <= (i64)L` — so the trip
        // count and registers are byte-identical, while the native backend (which
        // bails on a mixed compare) can now lower it. A later non-integral limit
        // side-exits the op → tier-0 resumes the exact mixed compare. The `guard_float`
        // already emitted by `guardNum(rlimit, vlimit)` pins this trace to float-limit
        // entries. The limit is never written by the loop, so the exit snapshot is
        // unchanged. Only fires for an integral, in-range limit (else stays mixed,
        // bails to tier-1a as before).
        const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null)
            try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int })
        else
            rlimit;

        // loop continues while (ascending) idx_next <= limit, else limit <= idx_next.
        const ascending = vstep.toFloat() >= 0;
        const cmp = if (ascending)
            try self.emit(.{ .op = .le, .a = rnext, .b = rlimit_cmp, .ty = .boolean })
        else
            try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rnext, .ty = .boolean });
        _ = try self.emit(.{ .op = .guard_true, .a = cmp });

        // publish the stepped index and the loop variable (R[a+3]).
        self.setReg(a, rnext);
        self.setReg(a + 3, rnext);
    }
};

/// Result type of a recorded arithmetic op given its observed operands. Mirrors
/// `arith.zig`: `/` and `^` are always float; otherwise int iff both operands are
/// int (matching tier-0's int/float promotion).
fn arithResultType(op: IrOp, vb: Value, vc: Value) ObsType {
    if (op == .div or op == .pow) return .float;
    return if (vb.isInt() and vc.isInt()) .int else .float;
}

fn obsTypeOf(v: Value) ObsType {
    return switch (v.tag) {
        .nil => .nil,
        .boolean => .boolean,
        .int => .int,
        .float => .float,
        .heap_ref => .heap,
    };
}

/// State of a tier-0 register within the recording: `undef` (never touched →
/// next read emits a `slot_load`), `input` (holds a `slot_load` ref — read but
/// not written, loop-invariant), or `def` (holds a computed ref — a loop-carried
/// write that surfaces in the exit snapshot).
const SlotState = enum { undef, input, def };

/// The SSA ref currently held by a tier-0 register, with how it got there.
const RegSlot = struct { ref: Ref = 0, state: SlotState = .undef };

/// Key for interning constants in the recorder's const pool. Built from the tag
/// plus the meaningful payload bits — NOT the raw 16-byte `Value`, which has
/// uninitialised padding between `tag` and `payload`. Immediates compare by
/// value; a `heap_ref` const (always a string literal) compares by object
/// identity, which is conservative and sufficient: the same pooled literal is the
/// same heap object, and consts are GC roots for the recording's lifetime, so no
/// address is reused mid-recording.
const KonstKey = struct { tag: u8, bits: u64 };

fn konstKey(v: Value) KonstKey {
    return .{
        .tag = @intFromEnum(v.tag),
        .bits = switch (v.tag) {
            .nil => 0,
            .boolean => @as(u64, @intFromBool(v.asBool())),
            .int => @bitCast(v.asInt()),
            .float => @bitCast(v.asFloat()),
            .heap_ref => @intFromPtr(v.asHeap()),
        },
    };
}

/// The in-progress recording buffer. `TraceState` owns it and drives every
/// mutation through its own methods (`emit`/`refOf`/`recordInstr`/…); this struct
/// is just storage + cleanup. While `active` is false the interpreter never calls
/// into it.
/// A deferred read-modify-write array store, sunk below every guard at trace
/// close. `aref`/`value` are IR refs already emitted inline (the address node and
/// the value to store); `lane_ord` is the packed-array `Lane` ordinal (the
/// `astore`'s `aux`). See `Recorder.pending_stores`.
const PendingStore = struct { aref: Ref, value: Ref, lane_ord: i32 };

/// Maximum number of read-modify-write stores a single trace may sink (Gap C,
/// `docs/design/08-multi-store-sinking.md`). Caps the simultaneously-live value
/// registers the store-sinking holds from computation to the trace-close flush —
/// bounding native XMM/GP pressure. 4 covers the FFT butterfly (`v[i],v[i+1]` and
/// `v[j],v[j+1]` per iteration) exactly; a trace that wants more aborts cleanly.
const MAX_PENDING_STORES = 4;

pub const Recorder = struct {
    active: bool = false,
    anchor: AnchorKey = .{ .proto = undefined, .pc = 0 },
    abort_reason: ?AbortReason = null,
    instrs: std.ArrayListUnmanaged(IrInstr) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    entry_slots: std.ArrayListUnmanaged(u16) = .empty,
    /// Refs already covered by a type guard, so we emit each at most once.
    guarded_refs: std.AutoHashMapUnmanaged(Ref, void) = .empty,
    /// Interns constants: a recurring literal reuses its `konst` instruction's
    /// ref (and pool slot) instead of emitting a fresh one, so identical
    /// subexpressions get identical operand refs and the optimizer's CSE can
    /// merge them. See `TraceState.konst`.
    konst_map: std.AutoHashMapUnmanaged(KonstKey, Ref) = .empty,
    /// Current SSA ref + state for each tier-0 register, sized to the recording
    /// frame's `num_registers`.
    reg_map: []RegSlot = &.{},
    /// Lowest register slot that is a *compiler temporary* at this trace's loop
    /// header — the live-locals watermark. Set only by the `for_loop` whose
    /// back-edge targets this trace's anchor (so it describes the loop the trace
    /// actually re-enters): for a numeric-`for` the control regs occupy
    /// `base..base+3`, so every slot `>= base+4` is an expression temporary, dead
    /// at every statement boundary (`compiler.zig:8-9`) and after the loop
    /// (`freeTo(base)`). `commit()` drops such slots from the exit snapshot — they
    /// are recomputed by tier-0 on deopt and never read post-loop. The `maxInt`
    /// sentinel means "unknown" (while / generic-`for` / a passed-through `for`),
    /// so nothing is filtered and behavior is unchanged.
    locals_watermark: u32 = std.math.maxInt(u32),
    /// Bytecode PC of the instruction currently being recorded. Set by
    /// `recordInstr` before `recordOne`; `emit` stores it in the `aux`
    /// field of guard instructions so the executor can report *which*
    /// guard failed (per-guard PC recording for exit-PC chaining).
    cur_pc: u32 = 0,
    /// Deferred (sunk) array stores: in-bounds `astore`s that follow an `aload` (a
    /// read-modify-write). Rather than abort the trace (the old C1 rule),
    /// `recArraySet` records each store's address + guards inline but stashes the
    /// `astore` node itself here; `commit()` flushes them — *front-to-back, in the
    /// recorded (tier-0 bytecode) order* — *after* every guard (incl. the `for_loop`
    /// continuation guard), just before the `.loop` terminator. Sinking them below
    /// all side-exits makes deopt-replay idempotent: any guard failure leaves *all*
    /// of them un-executed, so tier-0 re-runs the iteration along the original source
    /// path and applies exactly that path's stores once each. Flushing in recorded
    /// order keeps last-writer-wins identical between the trace and tier-0 even if two
    /// stores alias. See `docs/design/08-multi-store-sinking.md` (Gap C); doc 07 is
    /// the single-store original (Gap B).
    ///
    /// While `pending_store_count > 0`, any further *read* (`aload`) or *append*
    /// (`astore_append`) aborts the trace — the sunk stores must be the trace's last
    /// array accesses (no store-then-read divergence; append changes `len`). A further
    /// in-bounds RMW `astore` instead *appends* here, up to `MAX_PENDING_STORES`;
    /// exceeding the cap aborts. `count == 0` ⇒ no deferred store (the common case:
    /// pure-write loops emit inline as before).
    pending_stores: [MAX_PENDING_STORES]PendingStore = undefined,
    pending_store_count: usize = 0,

    pub fn deinit(self: *Recorder, gpa: std.mem.Allocator) void {
        self.instrs.deinit(gpa);
        self.consts.deinit(gpa);
        self.entry_slots.deinit(gpa);
        self.guarded_refs.deinit(gpa);
        self.konst_map.deinit(gpa);
        if (self.reg_map.len != 0) gpa.free(self.reg_map);
    }

    /// Clear the buffer and arm a fresh recording for `anchor` over a frame with
    /// `num_registers` registers. Reuses retained capacity; only (re)allocates
    /// `reg_map` when the register count changes.
    pub fn reset(self: *Recorder, gpa: std.mem.Allocator, anchor: AnchorKey, num_registers: u16) !void {
        self.instrs.clearRetainingCapacity();
        self.consts.clearRetainingCapacity();
        self.entry_slots.clearRetainingCapacity();
        self.guarded_refs.clearRetainingCapacity();
        self.konst_map.clearRetainingCapacity();
        if (self.reg_map.len != num_registers) {
            if (self.reg_map.len != 0) gpa.free(self.reg_map);
            self.reg_map = try gpa.alloc(RegSlot, num_registers);
        }
        @memset(self.reg_map, .{});
        self.anchor = anchor;
        self.abort_reason = null;
        self.locals_watermark = std.math.maxInt(u32);
        self.pending_store_count = 0;
        self.active = true;
    }
};

// ---------------------------------------------------------------------------
// Disassembly — same spirit as `bytecode.writeProto`. Invaluable for `--dump-
// traces` and for asserting trace shape in tests.
// ---------------------------------------------------------------------------

/// Write one IR instruction in a fixed columnar form (no trailing newline).
pub fn writeIrInstr(w: *io.Writer, ins: IrInstr) io.Writer.Error!void {
    try w.print("{s:<13}", .{@tagName(ins.op)});
    switch (ins.op) {
        .slot_load => try w.print("r{d}", .{ins.aux}),
        .konst => try w.print("k{d}", .{ins.aux}),
        .neg,
        .not,
        .bnot,
        .guard_int,
        .guard_float,
        .guard_number,
        .guard_true,
        .guard_false,
        .aload,
        .guard_table,
        .guard_lane,
        .guard_bounds,
        .guard_present,
        .guard_fits,
        .int_of_float,
        => try w.print("%{d}", .{ins.a}),
        .loop, .preheader => {},
        // φ: a slot-bound φ prints `update=%b → r{slot}` (init is implicit
        // `regs[slot]`); an internal φ prints `init=%a update=%b → internal`.
        .phi => {
            if (ins.aux == PHI_INTERNAL) {
                try w.print("init=%{d} update=%{d} -> internal", .{ ins.a, ins.b });
            } else {
                try w.print("update=%{d} -> r{d}", .{ ins.b, ins.aux });
            }
        },
        else => try w.print("%{d}  %{d}", .{ ins.a, ins.b }),
    }
}

/// Disassemble a whole trace: header + entry slots + numbered IR (the slot-bound
/// `phi` rows are the loop-carried writebacks that `exit_stores` used to list).
pub fn writeTrace(w: *io.Writer, t: *const Trace) io.Writer.Error!void {
    try w.print("trace {s}:{d}  entry=[", .{ t.anchor.proto.name, t.anchor.pc });
    for (t.entry_slots, 0..) |s, i| {
        if (i != 0) try w.writeAll(" ");
        try w.print("r{d}", .{s});
    }
    try w.writeAll("]\n");
    for (t.instrs, 0..) |ins, i| {
        try w.print("  %{d:0>3}  ", .{i});
        try writeIrInstr(w, ins);
        try w.writeAll("\n");
    }
}

/// Test helper: splice slot-bound `phi` nodes for a `carry` spec (tier-0 register
/// `slot` ← body update `ref`) into a `body` that ends in `.loop`, placing them
/// just before the terminator. This mirrors exactly what `commit()` builds, so
/// hand-built test traces (in `nativegen`/`irinterp`/`interp`) can keep expressing
/// loop carry as a `SlotStore` list. Body refs are *stable* — only `loop` shifts
/// down by `carry.len`, and nothing references `loop` by index, so every operand
/// ref in `body` stays valid.
///
/// `body` / `carry` are `*const [N]…` (pointers to fixed-size arrays): the array
/// *lengths* are comptime (so the return type is a sized array) while the element
/// *values* may be runtime — tropt's tests build instrs with a runtime `op`.
pub fn withPhis(
    body: anytype,
    carry: anytype,
) [
    @typeInfo(@typeInfo(@TypeOf(body)).pointer.child).array.len +
        @typeInfo(@typeInfo(@TypeOf(carry)).pointer.child).array.len
]IrInstr {
    const nbody = @typeInfo(@typeInfo(@TypeOf(body)).pointer.child).array.len;
    const ncarry = @typeInfo(@typeInfo(@TypeOf(carry)).pointer.child).array.len;
    const last = nbody - 1;
    std.debug.assert(body[last].op == .loop);
    var out: [nbody + ncarry]IrInstr = undefined;
    for (0..last) |i| out[i] = body[i];
    for (carry, 0..) |st, j| {
        // Slot-bound φ: implicit init (`regs[slot]`, so `a` = 0), update `b`.
        out[last + j] = .{ .op = .phi, .a = 0, .b = st.ref, .aux = @intCast(st.slot), .ty = body[st.ref].ty };
    }
    out[last + ncarry] = .{ .op = .loop };
    return out;
}

// ---------------------------------------------------------------------------
// Tests (Increment A): IR shape + disassembler + hotness counting.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "IrInstr stays small" {
    // Cache-sensitive representation; keep it compact. Not serialised here (the
    // wire format is binschema, Phase 5b) — just guard against accidental bloat.
    try testing.expect(@sizeOf(IrInstr) <= 16);
}

test "writeTrace renders a hand-built counting-loop trace" {
    // A stand-in for `for i=lo,hi do acc = acc + i end`'s recorded body:
    //   %0 = slot_load r0   (acc)
    //   %1 = slot_load r1   (i)
    //   %2 = guard_int %0
    //   %3 = guard_int %1
    //   %4 = add %0 %1
    //   loop  (acc<-%4, i<-%1)
    const proto = Proto{ .code = &.{}, .name = "main" };
    var instrs = withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int },
        .{ .op = .slot_load, .aux = 1, .ty = .int },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .loop },
    }, &[_]SlotStore{ .{ .slot = 0, .ref = 4 }, .{ .slot = 1, .ref = 1 } });
    var entry = [_]u16{ 0, 1 };
    const t = Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry,
        .entry_guards = &.{},
    };

    var buf: [512]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    try writeTrace(&w, &t);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "trace main:5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "entry=[r0 r1]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "slot_load") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    // The two loop-carried writebacks now render as slot-bound φ rows.
    try testing.expect(std.mem.indexOf(u8, text, "update=%4 -> r0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "update=%1 -> r1") != null);
}

test "onBackEdge counts back-edges per anchor" {
    var state = TraceState.init(testing.allocator);
    defer state.deinit();
    state.config.hotloop = 1000; // high enough that nothing arms — pure counting

    const proto = Proto{ .code = &.{}, .name = "t" };
    const hot = AnchorKey{ .proto = &proto, .pc = 3 };
    const cold = AnchorKey{ .proto = &proto, .pc = 99 };

    var i: u32 = 0;
    while (i < 10) : (i += 1) state.onBackEdge(&proto, 3, &.{});
    state.onBackEdge(&proto, 99, &.{}); // a single, cold back-edge elsewhere

    try testing.expectEqual(@as(u32, 10), state.backEdgeCount(hot));
    try testing.expectEqual(@as(u32, 1), state.backEdgeCount(cold));
    try testing.expectEqual(@as(usize, 0), state.cache.items.len); // never armed
}

test "crossing the hotness threshold arms a recording" {
    var state = TraceState.init(testing.allocator);
    defer state.deinit();
    state.config.hotloop = 3;

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    try testing.expect(!state.isRecording());
    state.onBackEdge(&proto, 7, &.{}); // 1
    state.onBackEdge(&proto, 7, &.{}); // 2 — not yet hot
    try testing.expect(!state.isRecording());
    state.onBackEdge(&proto, 7, &.{}); // 3 == hotloop → arm
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(u32, 7), state.rec.anchor.pc);
}

test "recArrayGet: t[k] on a bool lane records the full guarded read sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    // nsieve's bool sieve → a narrow boolean lane.
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (3) ; `get_index r0, r1, r2`  →  r0 = t[3]
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);

    try testing.expect(state.isRecording()); // a clean record — no abort
    const ops = state.rec.instrs.items;
    // slot_load(table), guard_table, guard_lane, slot_load(key), guard_int,
    // aref, guard_bounds, guard_present, aload.
    try testing.expectEqual(@as(usize, 9), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_table, ops[1].op);
    try testing.expectEqual(IrOp.guard_lane, ops[2].op);
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[2].aux);
    try testing.expectEqual(IrOp.slot_load, ops[3].op);
    try testing.expectEqual(IrOp.guard_int, ops[4].op);
    try testing.expectEqual(IrOp.aref, ops[5].op);
    try testing.expectEqual(ops[0].a, ops[5].a); // aref.table == the table slot_load... (ref check below)
    try testing.expectEqual(@as(Ref, 0), ops[5].a); // table ref
    try testing.expectEqual(@as(Ref, 3), ops[5].b); // key ref
    try testing.expectEqual(IrOp.guard_bounds, ops[6].op);
    try testing.expectEqual(@as(Ref, 5), ops[6].a); // guards the aref
    try testing.expectEqual(IrOp.guard_present, ops[7].op);
    try testing.expectEqual(@as(Ref, 5), ops[7].a);
    try testing.expectEqual(IrOp.aload, ops[8].op);
    try testing.expectEqual(@as(Ref, 5), ops[8].a); // loads through the aref
    try testing.expectEqual(ObsType.boolean, ops[8].ty); // bool lane → boolean
}

test "recArrayGet aborts: non-table container, non-int key, hole, and out-of-bounds" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };

    const Case = struct { tab: Value, key: Value, why: AbortReason };
    const cases = [_]Case{
        .{ .tab = Value.int(7), .key = Value.int(3), .why = .bad_type }, // not a table
        .{ .tab = Value.heap(&t.header), .key = Value.boolean(true), .why = .bad_type }, // non-int key
        .{ .tab = Value.heap(&t.header), .key = Value.int(1), .why = .bad_type }, // hole at 1
        .{ .tab = Value.heap(&t.header), .key = Value.int(9999), .why = .bad_type }, // out of bounds
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), c.tab, c.key };
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);
        try testing.expect(!state.isRecording()); // aborted
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "recArrayGet aborts on a .value-lane (unpacked) array — deferred scope cut" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    // A heap value can only live in the (unpacked) .value lane — eager commit
    // leaves it there (laneForValue of a heap ref is .value) — exactly the path
    // the native/oracle read does not model.
    try t.set(gpa, Value.int(1), Value.heap(&t.header));
    try testing.expectEqual(arr.Lane.value, t.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    var state = TraceState.init(gpa);
    defer state.deinit();
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(1) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.nyi_opcode, state.rec.abort_reason.?);
}

test "recArrayGet/recArraySet abort on a metatable-bearing table (chunk 2a)" {
    const gpa = testing.allocator;
    // A dense boolean array — exactly the shape the recorder would otherwise
    // trace (`recArrayGet`/`recArraySet` lower it) — but carrying a metatable.
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    const mt = try table_mod.Table.create(gpa);
    defer mt.destroy(gpa);
    t.metatable = mt; // the metatable edge the access might dispatch through

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };

    // get_index: present, in-bounds, bool-lane — would record without a metatable.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3) };
        state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
    // set_index in-bounds in-lane store.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&t.header), Value.int(3), Value.boolean(false) };
        state.recordInstr(Instr.opABC(.set_index, 0, 1, 2), &regs, &proto, 0);
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
    // set_index append store (`t[len+1]=true`) — the path that would fire
    // `__newindex` on an absent key.
    {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ Value.heap(&t.header), Value.int(33), Value.boolean(true) };
        state.recordInstr(Instr.opABC(.set_index, 0, 1, 2), &regs, &proto, 0);
        try testing.expect(!state.isRecording());
        try testing.expectEqual(AbortReason.has_metatable, state.rec.abort_reason.?);
    }
}

test "recArraySet: t[k]=false on a bool lane records the full guarded write sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (3), r0 = value (false); `set_index a=1 b=2 c=0` → t[3]=false.
    var regs = [_]Value{ Value.boolean(false), Value.heap(&t.header), Value.int(3) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), &regs, &proto, 0);

    try testing.expect(state.isRecording()); // clean record — no abort
    const ops = state.rec.instrs.items;
    // value resolved first (for the C1 taint scan): slot_load(value), then
    // slot_load(table), guard_table, guard_lane, slot_load(key), guard_int, aref,
    // guard_bounds, guard_fits, astore. No guard_present — astore creates presence.
    // guard_fits is now emitted for the bool lane too (value-stability: a non-bool
    // free-variable store side-exits to tier-0 instead of tripping the oracle).
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op); // value (r0)
    try testing.expectEqual(IrOp.slot_load, ops[1].op); // table (r1)
    try testing.expectEqual(IrOp.guard_table, ops[2].op);
    try testing.expectEqual(IrOp.guard_lane, ops[3].op);
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[3].aux);
    try testing.expectEqual(IrOp.slot_load, ops[4].op); // key (r2)
    try testing.expectEqual(IrOp.guard_int, ops[5].op);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(@as(Ref, 1), ops[6].a); // table ref
    try testing.expectEqual(@as(Ref, 4), ops[6].b); // key ref
    try testing.expectEqual(IrOp.guard_bounds, ops[7].op);
    try testing.expectEqual(@as(Ref, 6), ops[7].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[8].op);
    try testing.expectEqual(@as(Ref, 0), ops[8].a); // range-checks the false slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[8].aux);
    try testing.expectEqual(IrOp.astore, ops[9].op);
    try testing.expectEqual(@as(Ref, 6), ops[9].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 0), ops[9].b); // value = the false slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[9].aux);
}

test "recArraySet: a bool-lane append (t[len+1]=true) records the guarded grow sequence" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    // Fill 2..32 (index 1 stays a hole) so the table rehashes to the boolean lane and
    // drains its hash — exactly nsieve's init-loop steady state. len is the high-water
    // mark (32); the next store t[33] is the append successor (idx == len+1).
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);
    try testing.expectEqual(@as(usize, 0), t.hash.count()); // hash drained → migrate is a no-op
    const len_before = t.array.len;
    const append_key: i64 = @as(i64, @intCast(len_before)) + 1;

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key (len+1), r0 = value (true); `set_index a=1 b=2 c=0`.
    var regs = [_]Value{ Value.boolean(true), Value.heap(&t.header), Value.int(append_key) };
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), &regs, &proto, 0);

    try testing.expect(state.isRecording()); // clean record — the append path, no abort
    const ops = state.rec.instrs.items;
    // Same prologue as the in-bounds store, but guard_bounds → guard_append and
    // astore → astore_append: slot_load(value), slot_load(table), guard_table,
    // guard_lane, slot_load(key), guard_int, aref, guard_append, guard_fits,
    // astore_append.
    try testing.expectEqual(@as(usize, 10), ops.len);
    try testing.expectEqual(IrOp.aref, ops[6].op);
    try testing.expectEqual(IrOp.guard_append, ops[7].op);
    try testing.expectEqual(@as(Ref, 6), ops[7].a); // guards the aref
    try testing.expectEqual(IrOp.guard_fits, ops[8].op);
    try testing.expectEqual(IrOp.astore_append, ops[9].op);
    try testing.expectEqual(@as(Ref, 6), ops[9].a); // stores through the aref
    try testing.expectEqual(@as(Ref, 0), ops[9].b); // value = the true slot_load
    try testing.expectEqual(@intFromEnum(arr.Lane.boolean), ops[9].aux);

    // The recorder must NOT have mutated the table — recording is side-effect free.
    try testing.expectEqual(len_before, t.array.len);
}

test "recArraySet aborts: non-table, non-int key, OOB, out-of-lane value, .value lane" {
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    // A separate .value-lane table: a heap value can only live in the .value lane
    // (eager commit leaves it there — laneForValue of a heap ref is .value).
    const tv = try table_mod.Table.create(gpa);
    defer tv.destroy(gpa);
    try tv.set(gpa, Value.int(1), Value.heap(&tv.header));
    try testing.expectEqual(arr.Lane.value, tv.array.lane);

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    const Case = struct { tab: Value, key: Value, val: Value, why: AbortReason };
    const cases = [_]Case{
        // not a table container.
        .{ .tab = Value.int(7), .key = Value.int(3), .val = Value.boolean(false), .why = .bad_type },
        // non-int key (hash-part territory).
        .{ .tab = Value.heap(&t.header), .key = Value.boolean(true), .val = Value.boolean(false), .why = .bad_type },
        // out of bounds (k > len would grow the array).
        .{ .tab = Value.heap(&t.header), .key = Value.int(9999), .val = Value.boolean(false), .why = .bad_type },
        // out-of-lane value (an int into a bool lane would widen → shape change).
        .{ .tab = Value.heap(&t.header), .key = Value.int(3), .val = Value.int(5), .why = .bad_type },
        // nil value — a hole-punch / delete, out of B3 scope.
        .{ .tab = Value.heap(&t.header), .key = Value.int(3), .val = Value.nil(), .why = .bad_type },
        // .value-lane array — deferred scope cut.
        .{ .tab = Value.heap(&tv.header), .key = Value.int(1), .val = Value.int(20), .why = .nyi_opcode },
    };
    for (cases) |c| {
        var state = TraceState.init(gpa);
        defer state.deinit();
        try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);
        var regs = [_]Value{ c.val, c.tab, c.key };
        state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), &regs, &proto, 0);
        try testing.expect(!state.isRecording());
        try testing.expectEqual(c.why, state.rec.abort_reason.?);
    }
}

test "recArraySet defers an RMW store (store-sinking) instead of aborting" {
    // The old C1 rule aborted any store that followed a packed read. Store-sinking
    // (Gap B) instead DEFERS the single store and flushes it below every guard at
    // trace close, so a read-modify-write records and runs native. See
    // `docs/design/07-rmw-store-sinking.md`.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key. First: r0 = t[r2] (a packed read → aload). The recorder's
    // get_index executes against the live table; r0 then logically holds t[3] = true.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.nil() };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);
    try testing.expect(state.isRecording()); // the read records cleanly

    // Now t[k] = (the value just read), an RMW. The store defers (sinks) rather
    // than aborting: the trace stays live and `pending_store` is armed.
    regs[0] = Value.boolean(true); // r0 = t[3], a boolean
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), &regs, &proto, 0);
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_store_count);
    try testing.expectEqual(@as(i32, @intFromEnum(arr.Lane.boolean)), state.rec.pending_stores[0].lane_ord);
    // The store is deferred — NOT yet in the instruction stream (it lands at commit).
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);

    // A subsequent packed read must abort: the sunk store has to be the LAST array
    // access (else on-trace store-then-read would diverge from tier-0 replay).
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
}

test "recArraySet sinks a read-steered const store (control channel) instead of aborting" {
    // `if t[i] then t[i]=false else t[i]=true end`: a guard on a read picks the
    // branch, so even a *constant* store could replay differently after a deopt.
    // Store-sinking handles this too — the store sits below the branch guard, so on
    // any side-exit the store has not executed and tier-0 re-runs the read+branch
    // cleanly. The trace records (deferred), no longer aborts.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key. r0 = t[r2] (a packed read).
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(false) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);
    try testing.expect(state.isRecording());
    // Branch on the read (a guard), then store a *constant* false (r3). The store
    // sinks below the branch guard — still recording, store deferred.
    state.recordInstr(Instr.opABC(.jmp_if_true, 0, 0, 0), &regs, &proto, 0);
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), &regs, &proto, 0);
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 1), state.rec.pending_store_count);
}

test "recArraySet sinks multiple RMW stores (Gap C: butterfly shape)" {
    // All reads precede all stores (the FFT butterfly shape): read t[3], read t[4],
    // then store t[3], store t[4]. Both stores are RMW (follow reads) → both defer
    // and sink, so `pending_store_count == 2` and neither `astore` is in the stream
    // yet (they flush at commit, in this recorded order). Under Gap B's single-store
    // rule the SECOND store aborted; Gap C records it. See `docs/design/08-...`.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 8 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key 3, r3 = key 4. r0 = t[3], r4 = t[4] (both reads first).
    var regs = [_]Value{
        Value.nil(),         Value.heap(&t.header), Value.int(3), Value.int(4),
        Value.boolean(true), Value.nil(),           Value.nil(),  Value.nil(),
    };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0); // r0 = t[3]
    state.recordInstr(Instr.opABC(.get_index, 4, 1, 3), &regs, &proto, 0); // r4 = t[4]
    try testing.expect(state.isRecording());

    // Tier-0 would have loaded the read values into r0/r4; mirror that so the
    // RMW stores below carry in-lane (boolean) values, not the initial nils.
    regs[0] = Value.boolean(true); // r0 = t[3]
    regs[4] = Value.boolean(true); // r4 = t[4]

    // Now write both back: t[3] = r0, t[4] = r4. Both defer.
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 0), &regs, &proto, 0);
    state.recordInstr(Instr.opABC(.set_index, 1, 3, 4), &regs, &proto, 0);
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(usize, 2), state.rec.pending_store_count);
    // Recorded order preserved: store #0 → key 3's aref, store #1 → key 4's aref.
    try testing.expect(state.rec.pending_stores[0].aref != state.rec.pending_stores[1].aref);
    // Neither store is in the stream yet — they flush at commit.
    for (state.rec.instrs.items) |ins| try testing.expect(ins.op != .astore);
}

test "recArraySet aborts when sunk stores exceed MAX_PENDING_STORES" {
    // One read arms deferral; then MAX_PENDING_STORES in-bounds RMW stores defer, and
    // the next one exceeds the cap and aborts cleanly (no regression — it aborted
    // under Gap B too, just one store sooner). Guards the bounded buffer.
    const gpa = testing.allocator;
    const t = try table_mod.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 1;
    while (i <= 32) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    var state = TraceState.init(gpa);
    defer state.deinit();
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 4 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r1 = table, r2 = key, r3 = bool value. One read to arm deferral.
    var regs = [_]Value{ Value.nil(), Value.heap(&t.header), Value.int(3), Value.boolean(true) };
    state.recordInstr(Instr.opABC(.get_index, 0, 1, 2), &regs, &proto, 0);
    try testing.expect(state.isRecording());

    // MAX_PENDING_STORES deferred stores (distinct in-bounds keys 3..3+MAX-1) record.
    var k: i64 = 3;
    while (k < 3 + @as(i64, MAX_PENDING_STORES)) : (k += 1) {
        regs[2] = Value.int(k);
        state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), &regs, &proto, 0);
        try testing.expect(state.isRecording());
    }
    try testing.expectEqual(@as(usize, MAX_PENDING_STORES), state.rec.pending_store_count);

    // One more store exceeds the cap → abort.
    regs[2] = Value.int(3 + @as(i64, MAX_PENDING_STORES));
    state.recordInstr(Instr.opABC(.set_index, 1, 2, 3), &regs, &proto, 0);
    try testing.expect(!state.isRecording());
    try testing.expectEqual(AbortReason.bad_type, state.rec.abort_reason.?);
}

test "per-guard PC recording: guard_int aux carries the bytecode PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // A 3-register frame: r0=r1+r2, both ints, at PC 42.
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 3 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    const regs = [_]Value{ Value.nil(), Value.int(10), Value.int(20) };
    state.recordInstr(Instr.opABC(.add, 0, 1, 2), &regs, &proto, 42);

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // Expected: slot_load(r1), slot_load(r2), guard_int(r1), guard_int(r2), add
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.slot_load, ops[1].op);
    try testing.expectEqual(IrOp.guard_int, ops[2].op);
    try testing.expectEqual(@as(i32, 42), ops[2].aux); // PC stored in aux
    try testing.expectEqual(IrOp.guard_int, ops[3].op);
    try testing.expectEqual(@as(i32, 42), ops[3].aux); // PC stored in aux
    try testing.expectEqual(IrOp.add, ops[4].op);
    try testing.expectEqual(@as(i32, 0), ops[4].aux); // add doesn't use aux
}

test "per-guard PC recording: guard_true aux carries the branch PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    try state.rec.reset(gpa, .{ .proto = &proto, .pc = 0 }, proto.num_registers);

    // r0 is truthy (int 1), so jmp_if_false emits guard_true at PC 7.
    const regs = [_]Value{ Value.int(1), Value.nil() };
    state.recordInstr(Instr.opABC(.jmp_if_false, 0, 0, 0), &regs, &proto, 7);

    try testing.expect(state.isRecording());
    const ops = state.rec.instrs.items;
    // Expected: slot_load(r0), guard_true
    try testing.expectEqual(@as(usize, 2), ops.len);
    try testing.expectEqual(IrOp.slot_load, ops[0].op);
    try testing.expectEqual(IrOp.guard_true, ops[1].op);
    try testing.expectEqual(@as(i32, 7), ops[1].aux); // PC stored in aux
}

test "tryChainExit: chains to a trace at the guard's exit PC" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Trace A at PC 10: a guard that will "fail" (we fake the failure by
    // calling tryChainExit directly).  Its guard_int has aux=20 to point
    // at Trace B's anchor.
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .guard_int, .a = 0, .aux = 20 }, // %1: guard r0, aux=exit PC 20
        .{ .op = .loop }, // %2
    };
    const consts_a = [_]Value{};
    var trace_a = try gpa.create(Trace);
    trace_a.* = .{
        .anchor = .{ .proto = undefined, .pc = 10 },
        .instrs = @constCast(&instrs_a),
        .consts = @constCast(&consts_a),
        .entry_slots = &entry_a,
        .entry_guards = &.{},
    };

    // Trace B at PC 20: a simple counting loop (r0 from 0 to 3).
    var entry_b = [_]u16{ 0, 1 };
    const instrs_b = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 (counter)
        .{ .op = .slot_load, .aux = 1 }, // %1: r1 (limit)
        .{ .op = .guard_int, .a = 0, .aux = 20 }, // %2
        .{ .op = .guard_int, .a = 1, .aux = 20 }, // %3
        .{ .op = .konst, .aux = 0 }, // %4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // %5: r0 + 1
        .{ .op = .lt, .a = 5, .b = 1 }, // %6: (r0+1) < limit
        .{ .op = .guard_true, .a = 6, .aux = 20 }, // %7
        .{ .op = .phi, .a = 0, .b = 5, .aux = 0, .ty = .int }, // %8: r0 ← r0+1
        .{ .op = .loop }, // %9
    };
    const consts_b = [_]Value{Value.int(1)};
    var trace_b = try gpa.create(Trace);
    trace_b.* = .{
        .anchor = .{ .proto = undefined, .pc = 20 },
        .instrs = @constCast(&instrs_b),
        .consts = @constCast(&consts_b),
        .entry_slots = &entry_b,
        .entry_guards = &.{},
    };

    // Put both traces in the cache.
    try state.cache.append(gpa, trace_a);
    try state.cache.append(gpa, trace_b);

    // Set proto on anchors (needed for findTrace lookup).
    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    trace_a.anchor.proto = &proto;
    trace_b.anchor.proto = &proto;

    // Regs: r0=0, r1=4 → Trace B should run 3 iterations (0,1,2;
    // iteration 3 computes 3<4 which is true, runs, then 4<4 fails).
    var regs = [_]Value{ Value.int(0), Value.int(4) };

    // Fake a guard failure in Trace A at instr index 1 (the guard_int).
    const chained = state.tryChainExit(trace_a, 1, &proto, &regs);
    try testing.expect(chained != null);
    try testing.expectEqual(@as(usize, 3), chained.?); // Trace B ran 3 iters
    try testing.expectEqual(@as(i64, 3), regs[0].asInt()); // r0 carried to 3

    // Remove traces from cache before deinit — they have stack-allocated
    // arrays that must not be freed by destroy().
    state.cache.clearRetainingCapacity();
    // Free the Trace heap allocations ourselves (instrs/consts/entry_slots
    // are stack memory, so skip those fields by not calling destroy).
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

test "tryChainExit: an array-guard exit does NOT chain on its lane ordinal" {
    // Regression: `guard_lane`/`guard_fits` store a lane ordinal in `aux`, not a
    // bytecode PC. A first-iteration array-guard exit must resolve to "no chain"
    // via `guardExitPc` — never be interpreted as a PC. Here the failing guard is
    // a `guard_lane` whose `aux` (lane ordinal 2) collides with a real decoy trace
    // anchored at pc 2; without the op gate, tryChainExit would execute the decoy
    // against incoherent registers and silently miscompute.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };

    // Trace A: the failing trace. Its instr index 1 is a guard_lane with aux=2
    // (a lane ordinal that happens to equal the decoy's anchor pc).
    var entry_a = [_]u16{0};
    const instrs_a = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0 (the table)
        .{ .op = .guard_lane, .a = 0, .aux = 2 }, // %1: lane ordinal 2 — NOT a PC
        .{ .op = .loop }, // %2
    };
    const consts_a = [_]Value{};
    const trace_a = try gpa.create(Trace);
    trace_a.* = .{
        .anchor = .{ .proto = &proto, .pc = 10 },
        .instrs = @constCast(&instrs_a),
        .consts = @constCast(&consts_a),
        .entry_slots = &entry_a,
        .entry_guards = &.{},
    };

    // Decoy trace anchored at pc 2 — a plain counting loop that, if (wrongly)
    // entered, would commit iterations and mutate r0.
    var entry_b = [_]u16{ 0, 1 };
    const instrs_b = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // %0: r0
        .{ .op = .slot_load, .aux = 1 }, // %1: r1
        .{ .op = .konst, .aux = 0 }, // %2: 1
        .{ .op = .add, .a = 0, .b = 2 }, // %3: r0+1
        .{ .op = .lt, .a = 3, .b = 1 }, // %4: (r0+1) < r1
        .{ .op = .guard_true, .a = 4, .aux = 2 }, // %5
        .{ .op = .phi, .a = 0, .b = 3, .aux = 0, .ty = .int }, // %6: r0 ← r0+1
        .{ .op = .loop }, // %7
    };
    const consts_b = [_]Value{Value.int(1)};
    const trace_b = try gpa.create(Trace);
    trace_b.* = .{
        .anchor = .{ .proto = &proto, .pc = 2 }, // collides with the lane ordinal
        .instrs = @constCast(&instrs_b),
        .consts = @constCast(&consts_b),
        .entry_slots = &entry_b,
        .entry_guards = &.{},
    };

    try state.cache.append(gpa, trace_a);
    try state.cache.append(gpa, trace_b);

    var regs = [_]Value{ Value.int(0), Value.int(4) };
    // The guard_lane is at instr index 1. It must NOT chain to the decoy at pc 2.
    const chained = state.tryChainExit(trace_a, 1, &proto, &regs);
    try testing.expect(chained == null);
    try testing.expectEqual(@as(i64, 0), regs[0].asInt()); // r0 untouched — no decoy ran

    state.cache.clearRetainingCapacity();
    gpa.destroy(trace_a);
    gpa.destroy(trace_b);
}

test "matchesFingerprint: empty fingerprint always matches" {
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    var regs = [_]Value{ Value.int(1), Value.float(3.14), Value.nil() };
    try testing.expect(t.matchesFingerprint(&regs));
}

test "nextTraceExcluding: visits each anchor trace once, highest-hit first, then null" {
    // The dispatch walk's termination guarantee: with the visited set growing by
    // one each step, `nextTraceExcluding` returns hit-count-descending and never
    // repeats — so two equal-priority traces can't cycle `A→B→A→…`. We pin both
    // the ordering and the terminating `null`.
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 0 };
    const loop_only = [_]IrInstr{.{ .op = .loop }};

    // Three traces at the same anchor (pc 10) with distinct hit counts, plus a
    // decoy at a different anchor (pc 99) that must never be returned.
    var traces: [4]*Trace = undefined;
    const specs = [_]struct { pc: u32, hits: u64 }{
        .{ .pc = 10, .hits = 5 },
        .{ .pc = 10, .hits = 1 },
        .{ .pc = 10, .hits = 3 },
        .{ .pc = 99, .hits = 100 },
    };
    for (&traces, specs) |*slot, spec| {
        const tr = try gpa.create(Trace);
        tr.* = .{
            .anchor = .{ .proto = &proto, .pc = spec.pc },
            .instrs = @constCast(&loop_only),
            .consts = &.{},
            .entry_slots = &.{},
            .entry_guards = &.{},
            .hit_count = spec.hits,
        };
        slot.* = tr;
        try state.cache.append(gpa, tr);
    }
    defer {
        state.cache.clearRetainingCapacity();
        for (traces) |tr| gpa.destroy(tr);
    }

    var visited: [8]*Trace = undefined;
    var n: usize = 0;
    // Expected visit order at pc 10: hits 5, then 3, then 1; pc 99 never appears.
    const expect_hits = [_]u64{ 5, 3, 1 };
    for (expect_hits) |h| {
        const next = state.nextTraceExcluding(&proto, 10, visited[0..n]) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(h, next.hit_count);
        visited[n] = next;
        n += 1;
    }
    // All three visited → the walk terminates.
    try testing.expect(state.nextTraceExcluding(&proto, 10, visited[0..n]) == null);
}

test "matchesFingerprint: matching types" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .int },
        .{ .slot = 1, .ty = .float },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    var regs = [_]Value{ Value.int(42), Value.float(3.14) };
    try testing.expect(t.matchesFingerprint(&regs));
}

test "matchesFingerprint: mismatched int/float" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .int },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    // Register holds a float, but the trace expects int.
    var regs = [_]Value{Value.float(2.5)};
    try testing.expect(!t.matchesFingerprint(&regs));
}

test "matchesFingerprint: guard_number accepts both int and float" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .number },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    try testing.expect(t.matchesFingerprint(&[_]Value{Value.int(1)}));
    try testing.expect(t.matchesFingerprint(&[_]Value{Value.float(1.5)}));
    try testing.expect(!t.matchesFingerprint(&[_]Value{Value.nil()}));
    try testing.expect(!t.matchesFingerprint(&[_]Value{Value.boolean(true)}));
}

test "matchesFingerprint: guard_table" {
    const entry_guards = [_]EntryGuard{
        .{ .slot = 0, .ty = .table },
    };
    const t = Trace{ .anchor = undefined, .instrs = &.{}, .consts = &.{}, .entry_slots = &.{}, .entry_guards = @constCast(&entry_guards) };
    try testing.expect(!t.matchesFingerprint(&[_]Value{Value.int(1)}));
    try testing.expect(!t.matchesFingerprint(&[_]Value{Value.float(1.0)}));
}
