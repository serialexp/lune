//! Mutable lifecycle record for one committed trace.
//!
//! The immutable, owned `TraceCode` payload is embedded by value. Registry and
//! coordinator layers own `TraceRecord` allocations and may mutate the runtime
//! lifecycle fields without making code consumers depend on those layers.

const std = @import("std");
const nativegen = @import("nativegen.zig");
const trace_code = @import("trace_code.zig");
const trace_ir = @import("trace_ir.zig");
const value = @import("value.zig");

const TraceCode = trace_code.TraceCode;

/// Doc 20 (patched trace entry) §R4-2: per-trace entry-patch lifecycle.
/// Suppression is split by reason because the arms have different wake behaviour
/// (§R5-2, §R6-2): `.suppressed_incumbent` is woken only by its recorded
/// incumbent's tombstone; `.suppressed_capacity` by ANY tombstone;
/// `.suppressed_permanent` (not-`.compiled`, ambiguous patch pc — properties
/// that never change) is never woken, the trace simply keeps entering via the
/// walk.
pub const EntryPatchState = enum {
    eligible,
    pending,
    bound,
    suppressed_incumbent,
    suppressed_capacity,
    suppressed_permanent,
};

/// A completed, cached trace: the recorded IR plus the entry/exit snapshots that
/// connect it back to tier-0 register slots. The IR is immutable once
/// committed; a trace leaves the cache only wholesale (`removeTrace` /
/// `clearCache` — see the lifecycle doc).
pub const TraceRecord = struct {
    /// Stable, monotonically-assigned identity (P-B, doc 17). Unlike the cache
    /// index (`traceIndex`, which `swapRemove` shuffles), this is assigned once at
    /// finalize from `TraceState.registry.next_trace_id` and NEVER reused — so it can be
    /// baked into native exit code as `final_trace_id` and resolved back via
    /// `traceById` even after unrelated traces retire. Default 0 for hand-built test
    /// traces that never go through finalize (they don't chain, so id collisions are
    /// harmless — the dispatcher's id path only runs for real recorded traces).
    id: u32 = 0,
    /// Doc 20 §R7-2: back-reference to this trace's entry-patch registry slot
    /// while entry-patch-bound, else null. Lets `removeTrace` mark the slot
    /// (clear `live`, set pending) in O(1) BEFORE destruction, and lets
    /// qualification assert a trace never binds two slots.
    entry_slot: ?u16 = null,
    /// Doc 20 §R4-2: the per-trace entry-patch state machine. The receipt
    /// funnel (`accountTraceRun`) may make exactly ONE transition —
    /// `.eligible → .pending` — behind a single state compare, so a `.bound`
    /// trace's productive receipts cost one never-taken branch. Every other
    /// transition happens at the safe-point drain (`drainEntryPatchWork`) or
    /// an unpatch (`unpatchSlot`), all deterministic events.
    entry_patch: EntryPatchState = .eligible,
    /// Valid ONLY while `entry_patch == .suppressed_incumbent`: the registry
    /// slot index of the live incumbent that blocked this trace's install.
    /// Its tombstone (and only its) wakes this trace back to `.eligible`.
    entry_patch_incumbent: u16 = 0,
    /// Immutable, owned payload consumed by execution, serialization, and lowering.
    code: TraceCode,
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
    /// Consecutive native-prologue refusals for this candidate. Any body entry
    /// resets the streak; a maxed streak suppresses only this trace.
    consec_refusals: u32 = 0,

    /// B-iv.3 backoff: the exit whose composite-bridge arm pipeline last ran in
    /// full and declined because the child's page was not stub-enterable.
    /// `maybeArmCompositeExit` short-circuits on a hit, so a durably
    /// non-enterable child costs ONE full pipeline run per
    /// (activation x `region_defs_gen`) instead of one per terminal composite
    /// deopt. Purely an accelerator: it can only skip work that would have
    /// declined identically, never change an arm decision that would otherwise
    /// have been made. `maxInt` = no memo. Runtime-only — not serialized.
    bridge_decline_exit: u32 = std.math.maxInt(u32),
    /// `region_defs_gen` the memo was stamped under; 0 = never stamped.
    bridge_decline_gen: u32 = 0,
    /// `region_context.call_seq` the memo was stamped under.
    bridge_decline_seq: u64 = 0,

    /// Memo for `TraceState.anchorPopulation`: the `countTracesAt(anchor)` result as
    /// of `TraceState.registry.cache_gen == anchor_pop_gen`. Gen 0 = never computed (state
    /// gens start at 1). Pure accelerator — recomputed on any cache mutation.
    anchor_pop_gen: u32 = 0,
    anchor_pop: u32 = 0,

    /// Memo for `TraceState.hasNativeLoopDoneLink` — a pure function of this
    /// trace's instrs (fixed after commit), its dispatch proto (fixed: the
    /// anchor proto), and the trace cache contents (covered by
    /// `TraceState.registry.cache_gen`). Ran per NATIVE DISPATCH before; now one gen
    /// compare in steady state. Gen 0 = never computed.
    ldl_memo_gen: u32 = 0,
    ldl_memo: bool = false,

    /// Pall's per-snapshot exit hotcount (`snap->count`, lj_trace.c
    /// `trace_hotside`): one taken-exit counter per committed instruction index,
    /// bumped by `noteTakenExit` on EVERY taken exit through that instruction.
    /// `EXIT_COUNT_DONE` (255, LuaJIT's `SNAPCOUNT_DONE`) latches once a side
    /// trace triggered by this exit commits — the exit is never counted again.
    /// Alloc-once at commit (FAIL-SOFT: an OOM leaves it empty and
    /// `noteTakenExit` bounds-checks, costing hotness, never correctness — same
    /// rationale as `bridge_cand`); empty for hand-built test traces; owned;
    /// freed in `destroy`; never serialized. Per-receipt cost is one direct
    /// byte RMW — no hashing (the Part S lesson below: a per-receipt hashmap
    /// probe was a measured 15% regression).
    exit_counts: []u8 = &.{},

    /// Part S — the sibling-handoff watch, deliberately a THREE-SCALAR, one-slot,
    /// allocation-free counter rather than a `(trace, exit) -> u32` side map.
    ///
    /// The first cut of Part S kept a `sibling_counts` hashmap keyed by `ExitKey` and
    /// resolved its owner with a `traceById` linear scan, both executed on EVERY
    /// dispatcher burst terminal (472k times on nsieve N=9). Measured: the bookkeeping
    /// cost more than the handoff saved — a 26% burst reduction that came out 15%
    /// SLOWER on the clock. The counter therefore has to be free, not merely cheap:
    ///
    ///   * one watched exit at a time (`sibling_watch_exit`), so a receipt is a `u32`
    ///     compare and an increment — no hashing, no probe, no allocation;
    ///   * eligibility is only consulted when the watch MOVES, not per receipt;
    ///   * `sibling_arms` is a COUNT, and its only per-receipt job is the `== 0` fast
    ///     reject in `hasArmedSiblingHandoff`.
    ///
    /// A count rather than a bool because a trace can have several hot exits and each
    /// deserves its own handoff. The first cut latched a bool on the first arm, which
    /// silently capped nsieve at ONE arm: exit 9 fused, and exit 16 — still terminating
    /// 304k bursts, half the remaining seam — could never be watched again. After the
    /// arm the watch resets so the next exit can qualify; an exit that is already armed
    /// is rejected by `siblingHandoffEligible`, so it cannot re-arm.
    ///
    /// Determinism is unchanged: all three are pure functions of the receipt stream,
    /// in receipt order. The one-slot watch is *less* eager than a full per-exit map
    /// (two co-hot exits qualify one after the other, not simultaneously), which can
    /// only ever DELAY an arm — never arm something a map wouldn't have.
    sibling_watch_exit: u32 = std.math.maxInt(u32),
    sibling_watch_count: u32 = 0,
    sibling_arms: u32 = 0,
    /// Single-slot INELIGIBLE-exit memo for `noteSiblingTerminal`: the last exit
    /// whose `siblingHandoffEligible` came back false. Repeat receipts at that
    /// exit are one `u32` compare instead of a full eligibility re-scan (measured:
    /// nsieve terminated 84k bursts/run at one statically-ineligible exit, each
    /// re-running the armed-links scan + bridge memo + branch-source test — ~5%
    /// wall-clock). Sound because eligibility for a fixed `(trace, exit)` is
    /// static EXCEPT for the armed-slot exclusion, so the memo is cleared wherever
    /// the arm set touching this trace changes (`clearSiblingLatch`, a successful
    /// sibling arm).
    sibling_reject_exit: u32 = std.math.maxInt(u32),

    /// Freeze-after-qualify membership memo (task #70, the runtime-seam kill): the
    /// last `regionMemberPoint(rid, anchor)` answer for this trace, keyed by
    /// `(region_defs_gen, rid)`. `replayLedger`'s frozen fast path asks "is this
    /// row's owner anchored inside the live region's footprint" once per ROW; the
    /// answer is a pure function of the trace anchor (immutable) and the region
    /// def's `member_points`/`armable` (invalidated by bumping
    /// `TraceState.region_policy.region_defs_gen` at every `region_defs` mutation), so two
    /// scalars + a bool replace a per-row footprint scan. Gen 0 never matches
    /// (`region_defs_gen` starts at 1), so a fresh trace always recomputes.
    region_memo_rid: u64 = std.math.maxInt(u64),
    region_memo_gen: u32 = 0,
    region_memo_member: bool = false,

    /// Free a heap-allocated trace and its arrays.
    /// LuaJIT's `SNAPCOUNT_DONE` (lj_jit.h): a side trace for this exit has been
    /// committed — stop counting it. Saturation caps at `DONE - 1` so an exit can
    /// never drift into DONE by counting alone.
    pub const EXIT_COUNT_DONE: u8 = 255;

    pub fn destroy(self: *TraceRecord, gpa: std.mem.Allocator) void {
        // Native pages can contain references to code-owned metadata. Tear them
        // down before releasing the immutable payload.
        self.native.deinit();
        self.code.deinit(gpa);
        if (self.exit_counts.len != 0) gpa.free(self.exit_counts); // hotexit counters
        gpa.destroy(self);
    }
};

test "trace record teardown owns record and code arrays" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const record = try gpa.create(TraceRecord);
    errdefer gpa.destroy(record);

    const instrs = try gpa.alloc(trace_ir.IrInstr, 1);
    errdefer gpa.free(instrs);
    @memset(instrs, std.mem.zeroes(trace_ir.IrInstr));

    const consts = try gpa.alloc(value.Value, 1);
    errdefer gpa.free(consts);
    @memset(consts, std.mem.zeroes(value.Value));

    const entry_slots = try gpa.alloc(u16, 1);
    errdefer gpa.free(entry_slots);
    @memset(entry_slots, 0);

    const entry_guards = try gpa.alloc(trace_code.EntryGuard, 1);
    errdefer gpa.free(entry_guards);
    @memset(entry_guards, std.mem.zeroes(trace_code.EntryGuard));

    const exit_counts = try gpa.alloc(u8, 1);
    errdefer gpa.free(exit_counts);
    @memset(exit_counts, 0);

    record.* = .{
        .code = .{
            .anchor = undefined,
            .instrs = instrs,
            .consts = consts,
            .entry_slots = entry_slots,
            .entry_guards = entry_guards,
        },
        .native = .unattempted,
        .exit_counts = exit_counts,
    };
    errdefer record.destroy(gpa);

    record.destroy(gpa);
}
