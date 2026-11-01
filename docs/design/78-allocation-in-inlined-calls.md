# 78 — Allocation in inlined calls — Design

Status: parked (written 2026-11-02 at Bart's request; not reviewed, nothing
to implement until Bart picks it up)
Owner: Bart
Last updated: 2026-11-02

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

_(nothing yet)_

### Outstanding

- [ ] **Parked.** Bart decides when to pick this up; a review (Codex and
  Antigravity, as for doc 77) comes first.
- [ ] **Q1 — the exit model for an allocating inlined call** (§5): (A)
  multi-frame precise snapshots, (B) allocation rollback on a coarse exit,
  or both.
- [ ] **Phase 0 — baselines.** A plain allocating helper
  (`local function vec(x, y) return {x = x, y = y} end` in a loop), a
  constructor-heavy loop, and doc 77's conventional vector type
  (`__add` returning `setmetatable({...}, V)`); tier-0, JIT, LuaJIT; the
  abort chain each one hits today in `--dump-aborts`.
- [ ] **Phase 1 — constructors on fresh tables** (§4.1): record the
  inserts a constructor makes into a table the trace just created (doc 72
  P3's `set_list`, named fields, positional fields).
- [ ] **Phase 2 — the chosen exit model** (§5), so an allocating call can be
  inlined.
- [ ] **Phase 3 — `setmetatable` on a trace-born table** (§4.2), and doc 77
  §4.2's invariant restated to match.
- [ ] **Phase 4 — measured** on the pinned pool.

## 1. Why this exists

A loop that calls a small function that builds a table cannot be traced.
Three walls stand in the way, each enough on its own
(`trace_recorder.zig`):

1. `new_table` records only in a precise recording (~1877–1892; an ordinary
   recording cancels with `needs_precise` and retries precise), because an
   allocated table is visible mid-iteration and a coarse exit that re-runs
   the iteration would allocate it twice. A second allocation consumes a
   second object id, ids are serialized in keyframes and program-visible
   through `pairs` order (doc 24 §2, doc 45 §1), so the JIT modes would
   diverge from tier 0.
2. A precise recording refuses every inlined call (~4572–4577): its
   snapshots describe the anchor activation only (`trace_snapshot.zig`
   ~46–71 has no frame fields), and every exit-capable op must have one
   (`trace_finalize.zig` ~389–398), so a guard inside a callee has nowhere
   to resume (doc 45 D1, D3).
3. Even in a precise recording, a constructor's own stores do not record:
   a `set_field` on the fresh table is a hash insert, which aborts
   `bad_type` (~3454, ~3491); heap-valued fields abort (~3483); `set_list`
   is unrecorded (doc 72 P3). Only a bare `{}` records.

So `vec(x, y)` in a loop runs on tier 0. Doc 77 meets the same walls for a
metamethod that returns a new object (its §2.1, Q5), and Bart decided that
allocation in inlined calls gets one design for every inlined call rather
than a metamethod-specific one: this doc.

## 2. Goals

- An inlined call that builds and returns a table records and runs natively,
  whether it is a plain helper, a constructor function or a metamethod.
- Allocation stays deterministic: every JIT mode allocates exactly the
  objects tier 0 allocates, in the same order, with the same ids (doc 24).
- One exit model for inlined frames, not one per kind of callee.

## Non-goals

- Allocation sinking or dead-allocation elimination (LuaJIT's
  `lj_opt_sink`). Doc 24 excludes them: they change which ids exist.
- Closures and `concat` on trace (separate gaps).

## 3. What exists

- **Precise recordings** (doc 45): a per-bytecode snapshot of the full
  anchor window, exits that resume tier 0 at the bytecode (`precise_resume`)
  or raise there (`precise_error`), no sunk stores, no peel, no unroll, no
  link closes, no optimizer, native only for `.loop` traces. The exit ABI
  already carries `activation_base`/`activation_depth`, always 0 today
  (`interp.zig` ~7296, ~7324).
- **Deterministic on-trace allocation** (doc 24): `emitAlloc` and one
  `guard_gc` per iteration admitting the iteration's allocation count up
  front, so no collection falls due mid-iteration; the `tnew` shim allocates
  once, never collects, and turns out-of-memory into `precise_error`.
- **Frame writing from native code** (doc 54): the inline self-push writes a
  real `CallFrame` (closure, minted `call_seq`, base, pc, return window,
  zeroed `in_flight`/`ctl`) and moves `depth`/`stack_top`
  (`nativegen_emit.zig` ~1085–1230), with field offsets in
  `FrameMotionAbi` (`trace_code.zig` ~377–425).
- **Inline frames at record time**: `InlineFrame{base_off, ret_dest,
  ret_count, caller_proto_id, call_pc}`, callee slots as SSA refs above the
  anchor window (`trace_recorder.zig` ~520–533, ~4586–4627).
- **`setmetatable`**: untagged (`stdlib/basic.zig` ~302); checks the second
  argument, the `__metatable` protection, frozenness, then assigns. The
  native prologue's hoisted metatable-free check depends on no trace calling
  it (`nativegen.zig` ~1078; doc 77 §4.2).

## 4. The pieces every option needs

### 4.1 Constructors on a fresh table

A table the trace created this iteration is known to the recorder: its
`tnew` ref, its sizing (`new_table`'s array/hash hints), every key stored
into it so far, no metatable, not frozen, not yet visible to anything the
trace did not store it into. Inserts into such a table need none of the
checks an insert into an arbitrary table needs (no metatable, no
`__newindex`, no frozen bit, no unknown existing key), so they can record
as a dedicated op, `tins` (fresh-table insert: constant string key, or a
positional index for `set_list`), with the sizing hint guaranteeing no
rehash for a constructor's own fields. Doc 72's templated constructors are
the natural carrier. Heap-valued fields need the write barrier the shim
already runs (a no-op today).

### 4.2 `setmetatable` on a trace-born table

Doc 77 §4.2 keeps the prologue hoist sound by "no trace calls
`setmetatable`". A trace-born table never had a prologue check, so
recording `setmetatable(t, mt)` *only* when `t` is the trace's own `tnew`
ref keeps that invariant intact, restated as: no trace changes the
metatable of a table it did not create this iteration. The recorded form
guards `mt` (a table or nil) and skips the protection and frozen checks,
which a fresh table cannot trip. `setmetatable` on any other table stays a
barrier.

## 5. The exit model (Q1)

An allocating callee is inlined, so guards run inside it after its `tnew`.
Two models can make that sound.

### (A) Multi-frame precise snapshots

Extend doc 45's snapshot with frame records, as LuaJIT's
`snapshot_framelinks` does: per inlined frame, the closure (a ref), the
callee's base offset, its resume pc and its return window. A precise exit
inside a callee materializes the anchor window and each callee window, then
pushes the frames with doc 54's frame-writing code (fresh `call_seq`s in
tier-0 order) and resumes tier 0 at the innermost pc. Precise recordings
then admit inlined calls.

- Fits the existing precise model: allocation stays precise-only, every
  exit is resume-coherent, and doc 63's host calls (which need precise)
  could then also appear inside inlined calls.
- Costs: the snapshot format and its serialization (`traceser`), both
  executors' materializers, the native exit stubs (frame pushes per exit,
  the store budget), the `call_seq` minting order (it is deterministic
  state), and doc 45's remaining precise restrictions (no optimizer, no
  peel) still apply to every trace that allocates.

### (B) Allocation rollback on a coarse exit

Keep ordinary (coarse, entry-replay) recordings and make allocation
replay-safe instead: on a coarse exit, undo the iteration's allocations, so
the replay on tier 0 allocates them again with the same ids.

The argument: on a coarse exit, everything the failed iteration did is
discarded — its SSA values, its sunk stores (never flushed), its register
writes. An object it allocated is reachable only from those, so it is
garbage, and nothing outside the trace can have observed its id. Undoing
it means: unlink the objects allocated since the iteration began (they are
the most recent on the allocation list), rewind `next_obj_id` and
`object_count` to the iteration's start, free them. The replay then
reproduces tier 0 exactly.

- Keeps the optimizer, peeling, unrolling and the coarse exit model for
  allocating traces; inlining works as it does today, because no exit
  inside a callee needs a frame.
- Needs a precise statement of "reachable only from discarded state": any
  effect that publishes a fresh object before the trace tail (a non-sunk
  store, a host call, a precise-only effect) ends rollback eligibility for
  that iteration, so a trace that does one must be precise. The `guard_gc`
  admission already guarantees no collection ran in between, so no GC state
  refers to the objects.
- Costs: an iteration-start mark (allocation list head, id counter, object
  count) taken per iteration in allocating traces; the undo path in both
  executors; a proof in doc 24's terms that the rewound counters leave the
  keyframe identical.

### Comparison

| | (A) multi-frame precise | (B) rollback |
|---|---|---|
| allocating traces optimized | no (precise is dupe-only until doc 45's outstanding item) | yes |
| new snapshot/exit machinery | frame records, frame pushes at exit | iteration mark and undo |
| effects that publish mid-iteration (host calls) | supported | still need precise |
| LuaJIT precedent | yes (framelinks) | no (LuaJIT sinks instead, which doc 24 forbids) |
| future: precise exits inside callees for other reasons | provided | not provided |

The two compose: (B) for the common case of pure constructors, (A) when an
inlined call must publish mid-iteration.

## 6. Phasing

Phase 0 baselines; Phase 1 constructors on fresh tables (useful on its own
for precise traces that build tables at depth 0); Phase 2 the exit model
Bart picks; Phase 3 trace-born `setmetatable`, after which doc 77's
conventional vector type records; Phase 4 measured.

## 7. Open questions

- **Q1** — exit model: (A), (B) or both (§5).
- **Q2** — `tins` as its own op, or the existing hash/array store ops with a
  "fresh table" provenance that elides their checks.
- **Q3** — whether trace-born `setmetatable` belongs here or in doc 77's
  follow-up.

## References

- Doc 10 (cross-frame tracing, no multi-frame snapshots), doc 24
  (deterministic allocation), doc 45 (precise deopt, D1–D6), doc 54 (inline
  frame motion), doc 63 (host calls need precise), doc 72 (table
  constructors, P3), doc 77 (§2.1, Q5).
- LuaJIT `lj_snap.c` (`snapshot_framelinks`, `lj_snap_restore`),
  `lj_opt_sink.c` (the technique doc 24 excludes).
