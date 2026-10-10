# 63 — Traces call host functions directly — Design

Status: draft, not yet implemented. Revision 6, approved by Codex and
Antigravity (confirmation round 6, receipts `docs/reviews/doc63/*-rev6.md`).
Q1–Q5 decided by Bart (2026-10-10; §9). Review history in §11–§15.
Prerequisites A and B landed; implementation phases not started.
Owner: Bart
Last updated: 2026-10-11

## Implementation status

Tracking the gap between this design and what's on master. Tick items as
they land; move whole phases to Done once everything inside them is
checked. Every phase lands behind `just test`, the `-Djit-debug` gate,
`just hashgate` and `just embed-test`.

### Done

- [x] **Decision Q1 — amend the "a host call is a trace barrier"
  commitment.** Yes (Bart, 2026-10-10). The doc 00/02 amendments land
  with Phase 2c (Docs item).
- [x] **Decision Q2 — callbacks from a trace-called or recorded host call
  run with the JIT suspended** in v1. Yes (Bart, 2026-10-10).
- [x] **Decision Q3 — leaf host functions.** Part of this plan, as Phase
  4 (Bart, 2026-10-10).
- [x] **Decision Q4 — disturbance threshold.** Like LuaJIT: a native
  stops being traced after its first disturbing call; threshold 1
  (Bart, 2026-10-10).
- [x] **Decision Q5 — multret host calls.** Deferred past v1; tracked in
  TODO.md (Bart, 2026-10-10).
- [x] **Prerequisite A — precise allocation-helper failures retry
  (pre-existing bug).** In a precise trace a failing string helper exited
  `.precise_resume` and tier-0 retried the allocation, against doc 45
  D5's "never an OOM retry" (§5.4). Fixed 2026-10-10: the allocating
  stralloc shims return a one-word `StrResult` (pointer, OOM `Status`, or
  decline), and precise traces raise the OOM as `.precise_error` in tier-1a
  (`irinterp.zig` `strFailure`) and native (the precise exit stub's
  `isStrAllocOp` split). Injected-OOM tests per helper in both tiers, plus
  a decline test. The reviews found a second pre-existing bug on the way,
  also fixed: native register liveness kept a precise snapshot's refs
  alive only to guards and `tnew`, not to every op that can exit, so a
  helper exit could flush a recycled register. It now follows
  `opMayExitInBody`, and `requiresPreciseSnapshot` covers every
  exit-capable body op.
- [x] **Prerequisite B — doc 61 Phase Q (weak trace pools, invalidate on
  sweep) lands.** Landed in `f1ea468` with follow-ups through `b462369`;
  doc 61 Phase 1 (the masked root walk) followed in `0225b4d`. §5.10.1
  records what the landed code changes for this design.

### Outstanding

- [ ] **Phase 0 — benchmark and budget.** A host-call benchmark through the
  C API, exact instruction counts, today's numbers, and the shapes in §8.
  Fix the budget.
- [ ] **Phase 1 — epoch, disturbance and suspension (inert).**
  `Heap.host_epoch` bumped at every §5.6 site; `Native.disturbs`
  maintained by `callHostNative` on success and failure (§5.9);
  `TraceState.suspend_depth` honoured by every §5.9 gate. No reader of
  any of them outside tests yet. A test per site and per gate.
- [ ] **Phase 2a — slab-coherent snapshots and the host statuses (inert).**
  The snapshot form, its validation, finalize placement rules, admission,
  both executors and both dispatcher consumers (§5.2); the status
  ordinals (§5.8). Tested with hand-built IR before any recording emits
  them.
- [ ] **Phase 2b — GC lifetime across a callback.** Native constants in
  the weak pools; Phase Q's transaction split into logical invalidation
  and deferred physical work, released only when no suspension and no
  entry lease remain, at the entry wrapper or at the end of a
  recording-time host call; the published `executing` borrow; precise
  results consumed through it (§5.8, §5.10). Seeds are left above
  `stack_top` with a debug check that they survive an epoch-clean call
  (§5.5).
- [ ] **Phase 2c — recording and tier-1a.** `guard_native`, `call_host`,
  `guard_host_epoch`, `host_result` (§5.1); host calls force precise
  recording (§5.3); the tier-1a arms; exactly-once tests across the ten
  equivalence legs and every route in §5.4.
- [ ] **Phase 3 — native lowering.** The same four ops in nativegen: inline
  pre-call materialization reusing the precise materializer, the C-ABI
  shim as a body callout, the post-call epoch and budget checks, the
  `host_result` tag checks and loads, the coherent exits, the call-site
  rooting rule in `nativegen_alloc` (§5.7). Budget met (§8).
- [ ] **Phase 4 — leaf host functions** (§5.12; Q3: part of this plan).
- [ ] **Docs.** Amend doc 00, doc 02 and doc 59 (§3.5, E6) with Phase 2c;
  doc 45's error contract (the host statuses, the coherent snapshot);
  doc 61 §1 ("trace code never calls `callValue`") and Phase Q's F1/F3
  (§5.10); doc 04 if the snapshot record is serialized (§5.2).
- [ ] **Later — host calls in optimized traces.** Depends on doc 45's
  outstanding "optimizer integration" item (precise traces leaving the
  dupe path). Not part of v1 (§7.4).
- [ ] **Later — host calls in head-anchored precise traces.** Tier-1a
  runs them today; native does not. v1 admits host calls only where
  native can follow (§3, §5.3).
- [ ] **Later — lift suspension** (episode-owned accounting) if Phase 0
  or users show nested JIT matters under trace-called hosts (§5.9).

## 1. Why this exists

Every loop that calls a host function runs on the tier-0 interpreter.
The recorder aborts at the call with `host_barrier`
(`trace_recorder.zig:4101`), the anchor gates after six aborts, and the
whole loop body, not just the call, stays interpreted.

The callback loop `for i = 1, n do s = s + host_id(i) end`, where
`host_id` is a C function returning its argument, measured by
callgrind on 2026-10-09 (instructions per iteration):

| Shape | JIT | instructions |
|---|---|---:|
| Host call | on (gated) | 740 |
| Host call | off | 664 |
| Guest function `gid(i)` | on (traced, inlined) | 15 |
| Guest function `gid(i)` | off | 833 |

A guest call in a trace is 55× cheaper than in tier-0, while a host call
never leaves tier-0 at all. The call itself (`cHostCall` plus the C
function) is about 80 of the 740. The rest is tier-0 dispatch around it:
the loop, the global lookup, the arithmetic and the call setup. All of it
would compile if the call did not end the trace.

Bart's goal for the embedding API is "option 3": compiled code calls
host functions directly. The tier-0 work (doc 62 slot hints, the gated
back-edge skip in commit ba6ce32, the private host results buffer in
commit 4fed40b) shaved the interpreted path. This doc removes the
barrier itself.

## 2. What LuaJIT does (the reference)

LuaJIT never calls anything from compiled code that might re-enter the
VM. Both of its relevant mechanisms rest on that.

- **Classic `lua_CFunction`s are never called from a trace.**
  `recff_c` is `recff_nyi` (`lj_ffrecord.c:194`): the trace either
  aborts (`LJ_TRERR_TRACEUV`, when it is shorter than `minstitch`) or
  **stitches** (`recff_stitch`): the trace ends before the call, the
  interpreter makes the call, and a new trace starts after it. The trace
  guards the callee's identity (`rec_call_specialize`,
  `lj_record.c:794`) but never emits a call to it.
- **FFI calls are leaf calls.** `crec_call` (`lj_crecord.c:1264`) emits
  `CALLXS` with a `CARG` chain. There is no state sync before the call;
  `J->needsnap = 1` makes the next guard take a post-call snapshot.
  Results have static C types and are mostly converted or boxed without
  a guard; the exception is a `bool` result that is used, which gets a
  caller snapshot (`crec_snap_caller`) and a guarded compare
  (`lj_crecord.c:1301`). The backend only marks the caller-saved
  registers clobbered (`asm_callx`, `lj_asm_x86.h:757`).
- **The leaf assumption is load-bearing.** `HLOAD`/`ALOAD`/`ULOAD`/
  `FLOAD` are forwarded across `CALLXS`, because each forwarding routine
  walks only its own store chain (`lj_opt_mem.c:168`). Only raw-memory
  `XLOAD`/`XSTORE` stop at the last `CALLXS` (`lj_opt_mem.c:839`).
  No GC step can happen inside the call.
- **Re-entry is a fatal error, not a protocol.** `lj_ccallback_enter`
  (`lj_ccallback.c:716`) checks `G(L)->jit_base` and, if a trace is
  running, prints "bad callback" and calls `exit(EXIT_FAILURE)`. To make
  that rare, the interpreter's FFI call notices when a callback ran and
  blacklists the C function from recording (`lj_ccall.c:1199`, checked
  in `crec_call` at `lj_crecord.c:1282`). That is a heuristic: a
  function that calls back only on some paths can still kill the
  process.
- **GC runs only at snapshot-backed points.** `asm_gc_check` at the
  trace head, at `LOOP` and at `GCSTEP` calls `lj_gc_step_jit`, which
  refuses the atomic phase while `jit_base` is set
  (`lj_gc.c:668`) and forces an exit when one is due. Values held in
  registers are never needed as roots on trace.

So Pall's answer for functions that may call back is stitching, and for
functions that never call back it is a plain call. mahina's host
functions are the first kind: `mh_host_fn` may call `mh_call`,
`mh_eval`, `mh_collect`, `mh_table_set`, `mh_global_set`
(`mahina.h`, "Reentrancy: you may call back into the VM"). Replicating
LuaJIT exactly gives us stitching (§7.1) plus, optionally, leaf
functions (§5.12). This doc goes further: a call that may call back,
made directly from the trace, with the trace continuing afterwards when
nothing it relied on changed. It is built on mahina's precise mode
(doc 45), which already makes an execute-once effect (`tnew`) safe
across every exit. It borrows LuaJIT's callback blacklist (§5.9), but
makes a callback from a trace a handled event instead of a fatal one.

## 3. What mahina has today

- **The barrier.** `recCall`'s `.native` arm (`trace_recorder.zig:4101`)
  records natives with a `RecordedBuiltin` tag through `recBuiltin` and
  aborts every other native with `host_barrier`. Host natives can never
  carry a tag (`host != null ⇒ recorded == null`, asserted in
  `Vm.callHostNative`).
- **One invocation funnel.** `Vm.callHostNative` (`interp.zig`) is the
  only path into a host function. Since commit 4fed40b it gives every
  host call a private result range of `Vm.host_out` and returns the
  results as a slice the caller copies out. It does not count a level of
  `native_reentry_depth`; a callback's `callValue` does
  (`interp.zig:2314`).
- **Body callouts never re-enter.** The `BodyCallout` rows
  (`nativegen_alloc.zig:1743`) are leaf helpers with a baked `*Heap`;
  `calloutMayCollect` is false for all of them, and doc 61 §1 states
  "native and tier-1a trace code never calls `callValue`, a native
  through the dispatch arm, a metamethod, or `collect`". Doc 61 Phase Q's
  fact F3 rests on that: no collection runs while trace code is on the
  stack.
- **Coarse deopt re-runs the iteration.** An ordinary trace's default
  exit is anchor-coherent: tier-0 re-executes the partial iteration from
  the anchor (doc 01, `DeoptMode.entry_replay`). Every effect an ordinary
  trace records is idempotent under that replay. A host call is not.
- **Precise mode makes execute-once effects safe** (doc 45). A recording
  that meets an execute-once effect returns `.needs_precise` and is
  re-recorded in precise mode (`trace_recorder.zig:1687`). A precise
  trace snapshots the full window at every bytecode boundary, and every
  body op carries the current boundary's snapshot
  (`trace_recorder.zig:1741`). Its exits are `.precise_resume` (resume
  tier-0 at the snapshot's pc, nothing re-run) and `.precise_error`
  (raise at the bytecode, never retried). Both executors restore the
  failing op's snapshot before either exit (`irinterp.zig:1388`,
  `nativegen.zig:2721`). Precise exits never stage slot dispatch, never
  open patch windows and never take the linked loop-done branch; links
  involving a precise page are refused at arm and at dispatch; the
  loop-done exit uses the resume materializer. `tnew` is tested
  exactly-once through all of it, in tier-1a and native.
- **Precise limits.** Every precise recording is dupe-only (no
  optimizer: doc 45's "optimizer integration" item is outstanding),
  unpeeled, with `body_start == 0`, no frame motion, no inlined calls and
  no link closes. Tier-1a also runs head-anchored precise traces
  (`interp_trace_test.zig:7140`); native admission takes only
  loop-anchored ones with a `.loop` terminal.
- **Precise traces carry heap values in machine registers.** Write-
  dominated carried slots (`local t = {}`) get a heap home
  (`nativegen_alloc.zig:515`). Flushing a slot roots its value; it does
  not take the value out of its home.
- **Native code already writes VM state and continues.** Doc 54's inline
  frame motion writes `frames[]`, `depth`, `stack_top`, `call_seq` and
  `in_flight` from native code, then keeps running. It calls nothing.
- **GC runs only at the tier-0 prologue and `mh_collect`**
  (`interp.zig:3053`, `capi.zig:597`). `guard_gc` keeps on-trace
  allocation within budget (`!gc_stress and object_count +| A <
  next_gc`, `irinterp.zig:832`), so a trace never needs a collection.
  Heap values held in native registers or spill slots are not roots;
  that is sound only because nothing on trace can collect
  (`nativegen_alloc.zig:659`).
- **Nested execution records and runs traces.** A `callValue` from a host
  function runs a bounded nested `execWithEntry` on the fast or full
  path, with no JIT gate. While a recording is active, every instruction
  tier-0 executes feeds the recorder (`interp.zig:3237`), including those
  a callback runs. The native episode state is per VM, not per episode:
  `NativeSeedCtx` (including `touched[]`, `touched_len`, `episode_gen`),
  the page-owned `LinkHitCounter`s, promoted-set summaries, and
  `TraceState.ledger_scratch`. A nested episode overwrites them and can
  retire traces (`trace_registry.zig:55`).
- **Record/replay with host functions is refused by design** (doc 59
  §3.7, E6) but not yet wired: embedding runs with effects `.off`
  (doc 59:54).

## 4. The five hazards

- **H1 — Execute once.** The call must run exactly once per guest `.call`,
  in every tier and through every exit, including helper exits, armed
  exits, the loop-done exit and the error exit.
- **H2 — The host sees the VM.** Through the C API it reads globals and
  tables (stores the trace has made must be visible), and it may write
  them, set metatables, run guest code, deflate grids or collect.
  Anything the trace relied on may be stale afterwards, and the trace
  must not write stale values back over the host's changes.
- **H3 — GC.** A collection inside the callback runs while trace code is
  on the stack. It must not free a value the trace still reads, must not
  keep alive a value tier-0 would free (doc 61's tier-identical root
  set), and must not free a trace constant out from under code that will
  run again.
- **H4 — Nested episodes.** Guest code run by the callback may record,
  run or retire traces, feed an active recording, and overwrite per-VM
  episode state the outer trace still uses.
- **H5 — Unknown results.** The recorder runs before the instruction
  executes and never sees a native's results; host result types are not
  static.

## 5. Design

### 5.1 IR

Four new ops (wire numbers appended, per the trace IR rule). For a call
at bytecode `B` the recorder emits them in this order, with nothing in
between:

```
guard_native  callee, k          ; snap = S_B (full, resume B)
call_host     site               ; snap = C_B (failure); preflush site.preflush_snap = S_B
guard_host_epoch site            ; snap = C_B1; aux = A_rem
host_result   site, 0            ; tag check; snap = C_B1
…
host_result   site, nwanted-1    ; tag check; snap = C_B1
```

`S_B` is the ordinary full-window precise snapshot at `B`. `C_B` and
`C_B1` are **slab-coherent** snapshots at `B` and `B + 1` (§5.2).

`site` indexes a per-trace, read-only table:

```zig
pub const HostCallSite = struct {
    a: u16,               // callee register; results land at a ..
    nargs: u16,
    nwanted: u16,
    b_pc: u32,            // B
    preflush_snap: SnapIdx, // S_B, materialized before the call
};
```

Nothing writes to it at run time; per-call state lives in registers,
spill slots or tier-1a locals (§5.6). The shim finds its trace through
the dispatcher's published borrow and the callee in the slab (§5.8), so
the site names neither.

`IrInstr` field use (`a`, `b`, `aux`, `snap`, `trace_ir.zig:810`):

| Op | `a` | `aux` | `snap` |
|---|---|---|---|
| `guard_native` | callee ref | `k` | `S_B` |
| `call_host` | site index | — | `C_B` |
| `guard_host_epoch` | site index | `A_rem` | `C_B1` |
| `host_result` | site index | result index | `C_B1` |

`host_result`'s expected type is its `ty`, as for any typed load.

- **`guard_native callee, k`**: `ins.a` is the callee ref, `ins.aux` is
  `k`, the snapshot is `S_B`. It passes when the callee is exactly the
  `Native` in trace constant `k` **and** that native's `disturbs` count
  is below the threshold (§5.9): one pointer compare and one byte
  compare, the native being a constant. `guard_func` cannot do this (it
  checks a closure's proto id, `irinterp.zig:747`), and `guard_builtin`
  needs a recorded tag. Comparing the object, not the C function
  pointer, distinguishes two registrations of the same callback with
  different userdata. The constant joins the trace's weak pool (§5.10).
- **`call_host site`**: calls the host function. It is an ordered effect
  root (never CSE'd, moved or removed) and it is in `isStateEffectOp`, so
  no exit after it can count as pre-effect (`exitIsPreEffect`,
  `trace_ir.zig:872`). Its `snap` is `C_B`, so both executors' failure
  handling, which keys on `ins.snap` (`irinterp.zig:1392`), takes the
  coherent path; the preflush reads `S_B` from `site.preflush_snap`
  (§5.5). Finalize checks that `preflush_snap` is the `snap` of the
  `guard_native` immediately before it. The failure exit never restores
  `S_B`: the callback may have changed the slab since the flush.
- **`guard_host_epoch site`**: exits through `C_B1` when the epoch moved
  or the remaining allocation budget is spent (§5.6). `aux` holds
  `A_rem`.
- **`host_result site, k`**: result `k`, read from the slab, with its own
  SSA identity. It loads the tag first and compares it with the type the
  recorder observed; on a mismatch it exits through `C_B1` before
  unboxing. On a match it loads the payload under that kind. Every wanted
  result gets one, with its check, used or not, so its kind is always
  concrete (never `.boxed`, which the precise flush cannot materialize,
  `nativegen.zig:774`). A result that alternates types exits; that is
  the price of a typed result, as for any guard.

### 5.2 Slab-coherent snapshots

The existing contract cannot express "the slab is already the truth":
`trace_snapshot.validate` requires a full window (`trace_snapshot.zig:247`),
native admission repeats it, and both executors restore the failing op's
snapshot before a precise exit. Writing `S_B` back after a callback
would overwrite the callback's changes with pre-call values, and could
resurrect a pointer the callback's collection freed.

A new snapshot form, **coherent**:

- `Snapshot` gains `coherent: bool`. A coherent record has `slots_len ==
  0` and `register_count == proto.num_registers`, so the dispatcher
  consumers' assertions (`interp.zig:4665`, `:4700`) hold unchanged.
  `validate` becomes: coherent ⇒ `slots_len == 0`; otherwise full window,
  as today.
- **Placement rule** (finalize rejects the trace otherwise): a coherent
  snapshot is referenced only by `call_host`'s failure exit (resume `B`)
  and by the `guard_host_epoch` and `host_result` ops of the same site
  (resume `B + 1`), and those ops are contiguous after `call_host`. So
  between the call and every coherent exit nothing runs but loads and
  compares: the slab holds the flushed window, the callback's writes and
  the results, which is exactly tier-0's state. A coherent exit is legal
  only after a preflush; a leaf site (§5.12) has one too, and differs
  only in having no `guard_host_epoch`.
- **Executors.** Tier-1a's restore loop and native's per-snapshot
  materializer write nothing for a coherent snapshot (native jumps
  straight to the family tail). Both assert the placement rule.
- **Admission.** Native admission accepts coherent snapshots on these
  sites only.
- **Schema.** If snapshot records are serialized (the decoder path the
  finalizer's comment names), the field is a doc 04 schema change and
  the replay decoder validates it the same way.

Doc 56's sparse exit snapshots are a different thing (ordinary traces,
exit adapters) and stay separate; precise consumers never see them.

### 5.3 Recording: host calls make the trace precise

`recCall`'s `.native` arm gains a host branch. In an ordinary recording
it returns `.needs_precise`, exactly as an execute-once `tnew` does
(`trace_recorder.zig:1687`): the recording is cancelled without a
penalty and re-recorded in precise mode. In a precise recording it emits
the §5.1 sequence.

It records only what v1 can do, and **aborts with `host_barrier`
otherwise** (today's behaviour, so nothing regresses):

- the native is disturbing (§5.9);
- `nwanted` is a fixed count (`c != all_results`) and the argument count
  is fixed (no multret producer feeds it). Doc 27 is deferred (Q5);
- the recording is loop-anchored and will close with a `.loop` terminal,
  the shape native admits; host calls in head-anchored precise traces
  are a later item;
- exec-log sessions never produce a precise trace (doc 45); there the
  host call stays a barrier.

Tier-0 then executes the call. It runs suspended (§5.9), so a callback
does not feed the recording. If the epoch moved across the call
(`callHostNative` marks the native disturbing, §5.9), the recording
aborts with `host_barrier` at the next instruction: what it recorded
before the call may no longer describe the VM.

Results are typed at the next instruction's prologue: the recorder reads
the result registers tier-0 just wrote and records each observed type as
its `host_result`'s expected tag (§5.1).

### 5.4 Execute-once, route by route (H1)

Precise mode gives every exit after `call_host` a resume-at-pc contract.
Each route the reviews raised:

- **Guards after the call** exit `.precise_resume` at their own bytecode
  boundary; nothing before them re-runs.
- **The call's own coherent exits** (epoch, result tag, failure) resume
  at `B + 1` or raise at `B`, writing nothing (§5.2).
- **Helper exits** (integer division, typed loads, allocation failures,
  `nativegen_alloc.zig:1626`): every precise body op carries its
  boundary snapshot (`trace_recorder.zig:1741`), so a helper exit after
  the call resumes at its own bytecode and never replays the call.
  Phase 2c adds a finalize check that no exit-capable op after
  `call_host` has `snap == 0`.
- **Allocation-helper failures** are a separate, pre-existing problem
  (Prerequisite A). When this section was written, a string helper's
  null return left `runtime_error` at zero (`irinterp.zig:845` at the
  time), so a precise trace exited `.precise_resume` and tier-0 retried
  the allocation, where doc 45 D5 promises `.precise_error` and no retry.
  It does not replay the host call, but it is a precise-mode bug and is
  fixed first: helper allocation failures set `out_of_memory` and exit
  `.precise_error`, in both executors, with an injected-OOM test.

  *Landed 2026-10-10.* A helper failure that is not an OOM is a
  *decline* and still exits `.precise_resume`; tier-0 re-executes the
  bytecode and decides the outcome itself. For an out-of-range
  `string.char` codepoint that is its located `bad argument` raise. For
  a stale match scratch (a defense-in-depth check that a legitimately
  recorded trace never trips) tier-0's replay produces the real value,
  or the real error, from scratch.
- **The loop-done exit** uses the resume materializer and resumes at the
  `for_loop` bytecode, never replaying the body (doc 45 native money
  identity test).
- **Armed exits** (sibling handoff, `ordinary_guard`, region bridges,
  silent paths, ledger-cap yields): precise exits never open patch
  windows and links involving a precise page are refused at arm and at
  dispatch. `call_host` in `isStateEffectOp` is a second, independent
  barrier for `siblingHandoffEligible`.
- **Guards before the call** exit through their full snapshots. They fail
  before the call happens, so tier-0 makes it once.

Phase 2c tests count host invocations and log arguments for a failing
guard before and after the call, a helper exit after the call, the
loop-done exit, an epoch exit, a result-tag exit and an error, under all
ten equivalence legs (`interp_testutil.zig:161`).

### 5.5 Before the call: make the VM state real (H2, H3)

Precise traces are dupe-only: stores execute immediately (no sinking),
and everything live across a bytecode boundary is a window slot. So the
state at `B` is `S_B`, and the trace makes it real with the same
materializer an exit uses (doc 45 D6: konsts as immediates, carried
slots from their homes, in that materializer's order), run inline
instead of on the way out.

Then it writes what tier-0 has at a call in progress (doc 61 §4.2):

- `frames[depth-1].pc = B` and `in_flight = true`, so a collection masks
  the frame with `live_in[B]`, which includes the callee and arguments,
  and an error is located at `B` (`interp.zig:1761`).
- `stack_top` exactly as tier-0's native arm sets it for the call
  (`interp.zig:6710`: raised to the end of the argument span if that
  passes the frame top, which a fixed-count v1 call never does). On
  success it is restored. On an error it stays for the catcher.

**Seeds are neither protected nor rooted.** Seeds are copies of globals,
upvalues and proto constants in slots beyond `proto.num_registers`
(`trace_code.zig:162`, `interp.zig:1198`), so they lie above
`stack_top`. Revision 3 raised `stack_top` over them so that a nested
frame could not overwrite them. That moved where callback frames start,
so a callback that fits in tier-0 could overflow the fixed slab
(`interp.zig:125`, checked at `:2122`) when traced (Codex round 4 #1).
Revision 4 also had to scrub them on error so they would not become
rooted gaps. Neither is needed, because the seeds are only read under
the epoch proof (§5.7):

- If the epoch is unchanged after the call, no guest code ran, so no
  frame was laid out above `stack_top`. Nothing else writes the slab
  above `stack_top` during a host call either: arguments are gathered
  into `boundary_scratch`, results go through `host_out`, the C API
  parks values in `parked_inline`/`parked_results` (`capi.zig:368`),
  and every other slab-writing operation is guest execution or
  collection, which bump the epoch. The seeds are intact.
- If the epoch moved, the trace exits through `C_B1` or `C_B` and never
  reads a seed again.

Being above `stack_top`, the seeds are outside every GC walk, so a
collection inside the callback roots nothing tier-0 would not. Phase 1
adds a debug-build check to the shim: when the epoch is unchanged, the
seed span's bits are unchanged across the call. Phase 2b tests a
callback that drops a seed's original reference and collects (the next
allocation's id matches tier-0 in every leg), and a callback and an
`xpcall` handler that each use the stack up to tier-0's capacity limit.

The slots rooted below `stack_top` are the anchor window, which holds
exactly tier-0's values at `B`, masked exactly as tier-0's frame is. The
root set is tier-0's.

After a successful call the shim sets `frames[depth-1].pc = B + 1`,
clears `in_flight` and restores `stack_top`. On an error it leaves
`in_flight` set and `stack_top` as tier-0 would for the catcher.

### 5.6 After the call: the epoch and GC-budget guard (H2, H3)

`Heap.host_epoch` (`u64`) moves whenever something a trace may rely on
can have changed. It lives on `Heap`, not `Vm`, because `Vm` may move
and native pages bake only stable addresses (`interp.zig:576`, the
`&heap.object_count` precedent). The rule is drawn at the VM boundary, not as a list of API
functions:

- any guest execution: `callValue`, `execWithEntry`, every metamethod
  dispatch (so `mh_table_get` reaching `__index` bumps it), the doc 60
  hand-written entry;
- `collect`;
- any structural change to a heap object made outside a trace: table and
  global writes, metatable changes, grid deflation (`interp.zig:7702`,
  `gc.zig:401`; a C API read can trigger it), rehashes;
- every C API entry not on the exemption list below.

**Exemptions**, each with its argument. Phase 1 states each in code next
to the function and adds a test that it leaves the epoch alone; growing
the list needs the same.

| Function | Why it is exempt |
|---|---|
| `mh_nil`, `mh_bool`, `mh_int`, `mh_float` | build a value; touch no heap object |
| `mh_value_type`, `mh_value_truthy`, `mh_value_int`, `mh_value_float`, `mh_value_bool`, `mh_value_str` | read the value passed in |
| `mh_error_set` | stages message text in the box's `host_error` buffer (`capi.zig:1152`, the box's backing allocator, not the GC heap); it changes no guest state and nothing a trace relies on. Only a failing return raises (`capi.zig:1128`); a staged message followed by a successful return is tested |
| `mh_ref_get` | reads a host ref slot |
| `mh_string_new` | interns a string: an allocation (counted by the budget check), no reentry, no collection, no change to an existing object |
| `mh_table_new` | allocates an empty table: same argument |

Everything else bumps, including `mh_global_get` (it interns the name,
which is harmless, but the list stays short until Phase 0 shows a
reason) and `mh_ref_create`/`mh_ref_free` (they change the root set).

`guard_host_epoch` passes when both hold:

- `heap.host_epoch` equals its value before the call. Native code loads
  it through the baked `&heap.host_epoch` into a spill slot before the
  callout and compares after; tier-1a keeps it in a local. No trace
  metadata is written;
- `!heap.gc_stress and heap.object_count +| A_rem < heap.next_gc`, where
  `A_rem` (in `aux`) is the worst-case allocation count from `B + 1` to
  the back-edge, computed by the same finalize pass that computes
  `guard_gc`'s `A`, over the ops after the site. Exempt allocations
  inside the call advanced `object_count` without collecting; if a
  collection is now due before the iteration ends, the trace exits at
  `B + 1`, where tier-0's prologue collects at the same point it would
  have without the trace.

Either failing exits `.precise_resume` through `C_B1`, which writes
nothing (§5.2).

### 5.7 Why values held across the call are safe (H3)

Native code holds heap pointers across the call: carried homes,
including write-dominated heap homes (§3), seeds, and SSA values defined
before the call. Tier-1a holds them in its unrooted `values` scratch
(`trace.zig:1461`). None of them is a root during the call. The proof
that this is sound:

1. Every collection bumps `host_epoch` (§5.6).
2. After `call_host`, every path reads a pre-call value only after
   `guard_host_epoch` passed (§5.1's contiguity rule; the coherent exits
   before it read nothing).
3. So a pre-call value is read only when no collection ran. The GC does
   not move objects, so it is as valid as before the call.

Window slots the callback changed through open upvalues are guest
writes, which bump the epoch, so the trace never reads a stale home for
them either.

`mahina_trace_host_call` is a callout whose `calloutMayCollect` is true.
`nativegen_alloc`'s heap-φ refusal (`nativegen_alloc.zig:659`) keeps
applying to every other callout. It accepts this one by the rule above,
stated and asserted at the call site: the callout is a `call_host`, and
its `guard_host_epoch` follows it. Admission keeps refusing everything it
refuses today. Native tests cover a carried table and a `tnew` per
iteration across the call, with a callback that collects.

### 5.8 The call and its errors (H4)

Native code calls one runtime entry,
`mahina_trace_host_call(ctx: *NativeSeedCtx, site: *const HostCallSite)
callconv(.c) u32`, as a body callout (doc 23 D4 shape: save the
caller-saved lanes, `call`, restore). Native code has no `*Vm` in a
register and cannot bake one (`Vm` may move), but it already bakes the
stable `&NativeSeedCtx` (`compileSeeded`), whose `vm` field is valid for
the prepared episode (`trace_code.zig:267`); the site pointer is baked
from the trace's read-only table. Tier-1a calls the same function; its
`ExecCtx` (`irinterp.zig:241`, today `heap`, activation and
`exit_side` only) gains `seed_ctx: ?*NativeSeedCtx`. The dispatcher
fills it with the same heap-allocated context native code bakes,
`self.trace.registry.native_seed_ctx` (`trace_registry.zig:84`), which
it already prepares before either executor runs (`interp.zig:4309`). A
tier-1a trace containing `call_host` refuses to execute, before any
host call, when the context is missing.

**The owner.** The shim needs the trace it runs in, and neither the
context nor the site names it. Before either executor runs, the
dispatcher publishes the entered trace as `TraceState.executing:
?*Trace`, a borrow held until its result has been consumed (§5.10). The
borrow is the dispatcher's `ct`, not a registry lookup, so it survives
logical invalidation. A precise page never links or fuses, so the trace
whose code reaches the shim is always `executing`. The callee is not
looked up in the trace's constants. It is read from `regs[base + a]`,
which the preflush wrote and `guard_native` checked.

The shim:

1. raises `TraceState.suspend_depth` (§5.9) and sets
   `TraceState.suspended_trace = executing` (§5.10);
2. gathers the arguments from the slab and calls `Vm.callHostNative`, the
   single funnel (E6 will log there). The funnel returns a slice of its
   private `host_out` range and never writes registers. The shim copies
   that slice into `regs[base + a ..]` and nil-pads up to `nwanted`, as
   tier-0's native arm does (`interp.zig:6761`);
3. lowers `suspend_depth`, clears `suspended_trace`, finishes the frame
   per §5.5, and returns a status.

It does **not** count a level of `native_reentry_depth`. Tier-0's host
dispatch does not either (`interp.zig:6761`), so the recursion limit is
the same in every tier. `host_out`'s sizing holds without it: every
nested host call is reached through a callback's `callValue`, which
counts (`interp.zig:2314`), and `callHostNative` already returns
`StackOverflow` when `host_out` is exhausted.

The status extends doc 45's `table_runtime.Status`, with pinned
ordinals; the existing ordinal test (`table_runtime.zig:30`) grows to
cover the new ones:

| Status | Ordinal | Meaning | Raised as |
|---|---:|---|---|
| `ok` | 0 | results written | (continue) |
| `out_of_memory` | 1 | `host_out` or VM allocation failed | `Error.OutOfMemory`, uncatchable (doc 45 D5) |
| `type_error` | 2 | the host returned a malformed value (`fromC`) | `Error.TypeError` |
| `lua_error` | 3 | the host failed; `cHostCall` already set the pending error value via `raiseLocatedError`, located at `B` (§5.5) | `Error.LuaError`; the VM owns the pending value, as in tier-0 |
| `stack_overflow` | 4 | `host_out` exhausted | `Error.StackOverflow` |

On any status but `ok` the trace exits `.precise_error` through `C_B`:
nothing is written back, so the callback's changes stay, and nothing is
retried. The dispatcher's consumer (`interp.zig:4645`) decodes the new
statuses and returns `raise_at{pc = B, err}`. Its existing requirements
hold: the trace is precise, and the error row is the single terminal
row. The frame keeps `in_flight` and the raised `stack_top`. Phase 2c
tests a callback that changes an open upvalue, drops the old value,
collects, and then fails; the catcher sees the new value in every leg.

### 5.9 Nested execution runs with the JIT suspended (H4)

**Suspension.** While `TraceState.suspend_depth > 0`, guest code run by a
callback executes on tier-0 only. Exactly one party raises and lowers it
per call. For a traced call that is the shim (§5.8), together with
`suspended_trace`. For a tier-0 call made while a recording is active
it is `callHostNative` itself, only in that case
(`self.trace.isRecording()`), so a callback cannot feed the outer
recording. It is never raised twice for one call. Host calls
from tier-0 with no recording active are unaffected, and their callbacks
can still record and run traces, as today.

The gates, each with a Phase 1 test. The rule for each is that the
suspension check comes **before** any JIT decision or JIT-state
mutation on its path, and the canonical instruction then runs exactly
once:

- **the recording feed**: no instruction feeds `recordInstr`, and no
  recording starts (hot counters may still count; they are JIT-only
  state);
- **back-edge entry**: the shared back-edge path's cached-trace entry
  predicate (`eligible`, `interp.zig:7088`) gains `suspend_depth == 0`,
  as well as `onBackEdge`'s selection, so neither a fresh selection nor
  a cached entry runs;
- **patched entries**: each of the four patched handlers checks
  `suspend_depth` at its top, before its non-live recovery
  (`unpatchSlot`, `interp.zig:5931`, which runs before the R1-5 bypass
  at `:5980`; `:6081`, `:6158` and `:6259` have the same order). A
  suspended handler runs the canonical instruction without unpatching,
  entering or touching the patch, using each handler's existing
  provenance rule. The two loop handlers take their virgin path as their
  R1-5 bypass does today. The head and continuation handlers dispatch
  `&st.proto.code[cur_pc]`, never `&patch.orig`, because straight-line
  dispatch walks to the next instruction and a detached struct has none
  (`interp.zig:6134`, `:6246`). A callback's collection can leave a
  patch non-live (§5.10), and recovery must wait for the release point.
  Tests cover a cached unpatched entry, a logically invalidated patched
  entry reached while suspended, and a suspended head/continuation
  bypass followed by straight-line instructions;
- **head and continuation hooks**: no head-anchored or continuation trace
  is entered on a call or return;
- **unwind hooks**: pending exit/replay anchors are neither consumed nor
  set;
- **arming, linking and draining**: nothing is armed, disarmed or
  drained;
- **physical teardown**: no trace is destroyed; invalidation is logical
  (§5.10).

Saving and restoring episode fields cannot isolate a nested episode:
`touched[]`, the page-owned hit counters and the promoted-set summaries
are overwritten in place, and nested draining clears all summaries
(`trace_code.zig:343`, `nativegen_artifact.zig:281`,
`trace_chain.zig:1229`). Suspension avoids the problem instead of
patching it. Q2.

**Disturbing natives.** Suspension has a cost: a hot guest loop inside a
callback runs on tier-0 for its whole length. LuaJIT's answer is to stop
tracing calls to C functions that call back (`lj_ccall.c:1199`). mahina
does the same, deterministically:

- `Native.disturbs` (saturating `u8`) counts calls during which the
  epoch moved. `callHostNative` maintains it in every tier, on success
  **and** on failure: it reads `heap.host_epoch` before the call and
  compares in a `defer`, so the early error return (`interp.zig:2269`)
  is counted the same way. One load and compare per call, and a store
  only when the epoch moved.
- The recorder refuses a native whose count has reached the threshold
  (§5.3). v1's threshold is 1, LuaJIT's choice. Q4.
- **Every traced invocation checks it first.** `guard_native` fails
  when the native's count has reached the threshold (§5.1), through
  `S_B`, before the call: tier-0 makes the call, with the JIT on inside
  its callbacks. This holds for every cached trace that calls the
  native, not only the one that saw the disturbance, and whether the
  disturbing call succeeded or failed.
- When a precise exit at a `guard_native` finds its native over the
  threshold, the dispatcher retires the trace (logically, §5.10), so it
  stops paying an entry and an exit per iteration. The re-recording
  refuses the native, and the anchor falls back to tier-0 as today.

So suspended nested execution happens at most once per native with
threshold 1: on the first disturbing call made from a trace or during a
recording. Every later call is refused before it is made. Hosts that
only compute, or only read and allocate (§5.6 exemptions), keep the full
win.

Lifting suspension (episode-owned accounting) is a later design, in
Outstanding.

### 5.10 GC lifetime across a callback (H3)

Doc 61 Phase Q makes trace pools weak: a sweep that would free a pooled
constant first invalidates every trace naming it. It rests on F3: no
collection runs while trace code is on the stack. A callback from a
trace breaks F3. Phase 2b amends Phase Q:

- **F1 grows.** `guard_native`'s constant is a `Native`, not an interned
  string. It joins `heap_consts`, so a host function that is replaced
  and collected invalidates the traces that guard it. Phase Q's audit is
  extended to it.
- **Phase Q's transaction is split in two.** Its bulk retirement
  (`removeTraces`) mixes two kinds of work: making doomed traces
  unreachable, and tearing down their memory (record and code
  destruction, slot rewrites, promoted-state teardown, entry-patch
  drain and reuse, graph-cache rebuilds; `61:1251`, `61:1274`).
  - **Logical** (always at the sweep, so guest GC timing is unchanged):
    mark doomed traces retired, remove them from the cache, from every
    lookup a later entry or a later collection's pool scan consults, and
    clear their entry patches' `live` flag. A second collection in the
    same callback no longer sees them, so it never scans a freed
    constant.
  - **Physical**: runs at once only when `suspend_depth == 0` **and**
    no entry lease is outstanding; otherwise it is queued on
    `TraceState.deferred_retire`. The condition applies to every
    retirement source: collection-driven invalidation, the blacklist
    retirement of §5.9 (which happens inside the precise consumer while
    the entry wrapper still holds its patch), and the existing
    in-consumer removals that Phase Q moves into the bulk call.
- **Entry leases.** `TraceState.entry_leases: u32` is raised by every
  entry wrapper (`enterPatchedTrace`, the back-edge entry path, the head
  and continuation entries) before it enters a trace, and lowered after
  its last access to the patch and the trace record (`interp.zig:5339`,
  `:5455`). It is two instructions per trace entry. Phase 0 measures
  them with the rest of the tier-0 overhead (§8).
- **Release points.** The queue drains, before any later trace entry,
  at whichever of these brings both counters to zero:
  - an entry wrapper lowering the last lease, the case of a call from a
    trace;
  - `callHostNative` lowering a suspension it raised itself to 0, with
    no lease outstanding. That is the case of a call made by tier-0
    during a recording (Codex round 4 #3), where no wrapper is on the
    stack. A traced call's shim lowers its own suspension while its
    wrapper still holds a lease, so it never drains.

  Tests: a blacklist retirement through a patched entry; recording-time
  callbacks that collect once and twice, on success and on failure; and
  a recording that aborts without ever entering a trace. The queue's
  storage is reserved at commit time with Phase Q's other bulk scratch
  (its item 6), so neither the logical step nor queueing allocates.
- **The suspended trace itself may be doomed.** A collection bumps the
  epoch, so after the call that trace takes a coherent exit, which reads
  no constant (§5.2). The dispatcher must not resolve it by id: the
  native path's `traceById(final_trace_id)` panics on a missing id
  (`interp.zig:4492`). A precise page never links or fuses, so its final
  trace is the entered one. The dispatcher therefore handles precise
  terminal results **before** live-id resolution and before the ordinary
  post-run drains, through the retained entered-trace borrow (`ct`, the
  same borrow §5.8 publishes as `TraceState.executing`), asserting
  `final_trace_id == ct.id`. For a retired `ct` it skips the
  receipt and memo updates; it reads only the snapshot record, which
  lives until the release point. Tests: a callback collection that
  dooms the executing trace, followed by a successful return and,
  separately, a failing one.
- **`TraceState.suspended_trace: ?*Trace`** is set by the shim, from
  `executing`, while the call runs. At most one trace is ever suspended,
  since nothing enters a trace while `suspend_depth > 0`.
- **F3 is restated**: no collection runs while trace code that will read
  a pooled constant afterwards is on the stack. `invalidateDeadTraceConsts`
  asserts it: a doomed trace is either not executing or is
  `suspended_trace`.

### 5.10.1 As landed: doc 61 Phase Q and Phase 1 (2026-10-11)

§5.10 was written against Phase Q's design. Phase Q (`f1ea468`, follow-ups
through `b462369`) and Phase 1 (`0225b4d`) have since landed. The design
above stands; these are the facts about the landed code that it now
rests on, and what each changes for the phases.

- **F1 needs no new code.** Finalize indexes every heap value in the
  pool into `heap_consts` (`trace_finalize.zig`), not only strings, and
  `Native` is a heap object, so `guard_native`'s constant is scanned by
  `invalidateDeadTraceConsts` as soon as it is in the pool. The F1 item
  becomes a test (a native that is replaced and collected retires every
  trace that guards it) plus the audit entry. `guard_native` is recorded
  only from Phase 2c, so the test lands there, or earlier on a hand-built
  trace whose pool holds a `Native`.
- **What is already split, and what is not.** `removeTraces`
  (`trace_link.zig`) runs Phase Q's steps 2–7 as one transaction: the
  `doomed` bit, the relation and want drops, unpublishing (cache
  compaction, `trace_by_id`, the anchor index, entry patches marked
  non-live and pending), anchor reopening, `destroyDoomed`, and the
  graph rebuilds. Step 8, the entry-patch drain, already runs at the
  next safe point rather than inside the collection, and a non-live
  patch dispatched before it takes the §R6-1 recovery arm (doc 61 §7.1,
  "As built"). Unpublishing is not purely logical today:
  `unpublishDoomed` (`trace_registry.zig`) also calls
  `resetLinksTouchingDoomed`, which demotes promoted sets and rewrites
  surviving parents' slots. A callback's collection can doom any trace,
  ordinary ones included, not only the suspended one. So Phase 2b
  extracts the logical part of unpublishing (the doomed bit, cache
  compaction, `trace_by_id`, the anchor index, entry patches non-live)
  and defers everything else with the physical batch until both
  counters are zero, as §5.10 requires: link teardown and slot rewrites,
  promoted-state teardown, `destroyDoomed`, and the graph rebuilds. The
  existing deferred step 8 drain runs after that batch.
- **A collection inside a recording-time callback can cancel the
  recording.** `invalidateDeadTraceConsts` cancels an active recording
  that names a constant the sweep will free (`cancelRecording(.const_swept)`).
  During a recording-time host call (§5.3, §5.9) that is the recording
  the call belongs to. The epoch has moved in that case, so §5.3 would
  abort the recording at the next instruction anyway; the difference is
  that it is already gone. Phase 2c therefore keeps every piece of
  pending host-call state (the post-call epoch check, the result typing
  at the next prologue) inside the `RecordingSession`, so the cancel
  discards it, and the next-instruction hook does nothing when no
  recording is active. Test: a recording-time callback that drops and
  collects a constant the recording holds.
- **Collections now scrub dead registers.** `collect` nils every register
  below `stack_top` that the masked walk did not keep
  (`scrubDeadRegisters`), after invalidation and before the sweep. For
  this design:
  - the trace's anchor frame is `in_flight` at `B` (§5.5), so it is
    masked with `live_in[B]` up to `num_registers` (a fixed-count v1 call
    never takes the multret limit `CallFrame.multret_top`; lifting Q5
    must set it as tier-0 does);
  - seeds the callback did not overwrite lie above `stack_top`, so they
    are neither walked nor scrubbed. A nested guest frame can be laid
    out over part of the seed span (`bindAndPushClosure`, then
    `pushFrameTrusted` raising `stack_top`); those slots then hold that
    frame's values and may be walked or scrubbed. Either way the epoch
    has moved, so the trace never reads a seed again (§5.5);
  - a scrub implies a collection, which moves the epoch, so the trace
    takes a coherent exit that writes nothing, and tier-0 resumes on the
    same scrubbed registers it would have had without the trace. §5.7's
    proof is unchanged: a pre-call value is read only when no collection,
    and so no scrub, ran.
- **F3's assertion has a home.** `invalidateDeadTraceConsts` documents
  "no trace code is on the stack here". Phase 2b replaces that comment
  with the restated F3 assertion (a doomed trace is not executing, or is
  `suspended_trace`).

The line numbers cited elsewhere in this document are from revision 6
and have drifted; the named functions are the reference.

### 5.11 Tier-1a

The tier-1a precise executor gets the same four arms and the coherent
snapshot form. The flush, the shim, the statuses, the coherent exits and
the seed-span handling are shared code, so the root set and the
execute-once behaviour are identical between tiers. §5.7's proof covers
its unrooted `values` scratch.

### 5.12 Leaf host functions (Phase 4, Q3)

A host function registered as **leaf** (a new `mh_register_fn` flag)
promises no C API call other than reading its arguments and
`mh_error_set`. The promise is checked in every tier, so tiering stays
invisible. While a leaf runs, every other C API entry sees
`vm.leaf_call_active`, does not perform its operation, and latches
`vm.leaf_violation`. What it returns depends on its return type:

- `mh_status` functions return `MH_ERR_API` ("not allowed from a leaf
  host function");
- functions without a status (`mh_output`, `mh_last_error` and
  `mh_warnings` return `mh_str`; `mh_output_clear` and
  `mh_warnings_clear` return `void`, `capi.zig:555`–`:575`) return an
  empty string or nothing.

The value constructors and readers that need no VM (`mh_nil`,
`mh_int`, `mh_value_*`, …) are allowed, as they are pure.
`cHostCall` checks the latch after the callback returns. A violation
fails the call as `lua_error` ("leaf host function called a forbidden
API") even if the callback returned success, so a host that ignores the
refusal cannot hide it. Phase 4 tests that case. A leaf cannot move the
epoch, so it is never disturbing.

**What a leaf skips.** A leaf can neither re-enter nor allocate, and
cannot move the epoch or collect. So a leaf site has no
`guard_host_epoch`, raises no `suspend_depth`, and needs no budget
re-check. Its seeds are safe for the same reason as in §5.5: nothing
runs above `stack_top`.

**What it keeps: the preflush and the frame writes.** Revision 3 also
skipped the flush and marshalled arguments from SSA values. That left
the slab stale for every slot other than the results, so a result-tag
exit through `C_B1` would have resumed tier-0 over stale locals (carried
homes can be newer than the slab, `nativegen.zig:747`). The leaf path
therefore keeps §5.5's `S_B` preflush, and writes `frames[depth-1].pc =
B` and `in_flight`. That keeps every coherent exit legal under §5.2's
placement rule, and it locates an error at `B`: `cHostCall` locates
errors inside the call (`capi.zig:1130`, reading the frame pc,
`interp.zig:1761`), before any cold path could run. The placement rule
for a leaf site is `guard_native`, `call_host` (leaf), then the
`host_result` ops, with no epoch guard between them.

A partial materializer (flush everything but the results at a
result-tag exit, and skip the preflush) would save the flush. It is a
later optimization, measured against the Phase 0 numbers, not part of
Phase 4.

It still needs a precise trace, because the call remains execute-once.
Phase 4 compares caught error messages across tiers, and tests result
drift after several iterations with changing carried locals.

## 6. Determinism and replay

- **Tiering decisions.** Nothing new reads a clock, an address or host
  state to decide tiering. Admission depends on bytecode, observed types
  and `Native.disturbs`, a count of VM-boundary events (below).
- **Output equivalence.** Every tier keeps "each guest `.call` of a host
  function invokes it exactly once, with the same arguments, in the same
  order relative to every other observable effect". §5.4 keeps it
  through exits; §5.5 keeps the guest state and root set the host can
  observe identical to tier-0's.
- **GC timing.** A collection inside a callback runs at the same point
  and over the same roots as in tier-0 (§5.5, §5.10). After an exempt
  allocation the budget check sends the trace to tier-0 before a
  collection could fall due on trace (§5.6).
- **The epoch and the disturbance count are deterministic.** They count
  VM-boundary events the host caused, so they are functions of the
  host's behaviour, which the determinism envelope already treats as an
  input. Whether a trace exits or is retired after a call depends on
  them, but neither changes output.
- **Record/replay.** Still refused while host functions are registered
  (doc 59 E6). When E6 lands it logs in `callHostNative`, which the shim
  calls, so traces cannot bypass it.
- **The commitment this changes.** Doc 00 (`:710`, "Every host call is
  an effect and a trace barrier … the JIT does not trace through it")
  and doc 02 (`:28`, a native call is a trace barrier; host-mediated
  suspension depends on that). With this design a host call is an
  execute-once effect a precise trace may contain. Host-mediated
  suspension is not built; when it is, a suspending host call still ends
  the trace (a new status). Approved by Bart (Q1: yes).

## 7. Alternatives considered

### 7.1 Trace stitching (LuaJIT's answer for `lua_CFunction`)

End the trace before the call, let tier-0 make the call, and start a new
trace after it. It needs no flush, no epoch and no change to the barrier
commitment. But every iteration pays a trace exit, a tier-0 `.call` and
a trace entry, the seam cost docs 16, 17 and 56 spent months shaving. On
the callback loop the seams would dominate. It is the fallback for what
§5.3 refuses, not the main path.

### 7.2 Leaf-only, no callbacks (LuaJIT's FFI model)

§5.12 on its own. Cheapest per call, but it covers only host functions
that never touch the VM; the Rust crate's typed closures often do. A fast
path, not the whole answer.

### 7.3 A full optimizer barrier instead of the epoch guard

Revision 1's open question. In a precise trace there is no forwarding or
hoisting to barrier: the trace is dupe-only. What the epoch guard
protects is the seeds and the SSA values computed before the call; a
barrier would have to re-seed after every call. The epoch check is one
load and compare plus the budget compare. Moot until §7.4.

### 7.4 Ordinary (optimized) traces with forced resume-coherent exits

Revision 1's design: keep the trace ordinary and force every post-call
guard onto doc 56's resume-coherent path. Review round 1 showed why it
fails today: loop-done guards are refused by `exitAttachable`
(`trace_exit_attach.zig:351`); helper exits, ordinary arms, sibling
handoffs, region bridges, silent paths and ledger-cap yields each need
their own execute-once audit (`nativegen.zig:2574`); doc 56's sunk-store
replay would undo callback writes (`nativegen_adapter.zig:258`).
Precise mode has already done that work for one execute-once effect.
When doc 45's optimizer integration lands, host-calling traces get
optimized with it; that is the general path (Z-6), and it helps `tnew`
traces too.

### 7.5 Root the suspended trace's state instead of the epoch proof

Make every live machine value and seed a GC root during the call (a
stack map at the call site). It would let the trace continue after a
collection. But it keeps alive what tier-0 frees (§5.5), which breaks
doc 61's tier-identical root set, and the trace would still need the
epoch for everything else a callback changes. Rejected.

## 8. Performance budget (Rule #20)

Provisional until Phase 0 measures. Fixed costs per call: the call
itself (`cHostCall` plus the C function, about 80 instructions), the
callout save/restore (up to 21 lanes, `nativegen_emit.zig:1521`, about
40), the shim (about 40), the epoch and budget checks (about 6), and one
tag check per result. The flush is per window slot (two stores each).
Precise traces are not optimized, so the body costs more than an
ordinary trace's.

- **Minimal callback loop** (§1): at most 250 instructions per iteration
  with the JIT on (740 today).
- **Wide window** (8 live locals, one seeded global, one table store per
  iteration): at most 320. Phase 0 measures today's tier-0 number for
  the same shape. Phase 0 also varies the argument count, the window
  size and the number of seeds, and reports how the flush scales.
- **Disturbing hosts.** A host that calls back, or writes a table, on
  every call: one epoch exit, then a `guard_native` exit and a
  retirement per trace that calls it, then today's tier-0 path with the
  JIT on inside callbacks. Steady state must match today within noise.
  Phase 0 covers two cached traces calling the same native, and a host
  whose callback fails on every call and is caught by `pcall`.
- **Hot nested work under suspension.** A host whose first disturbing
  call runs a long guest loop: that one call runs on tier-0. Phase 0
  measures it against today, so the cost of threshold 1 (Q4) is a
  number, not a guess.
- **Tier-0 overhead.** `callHostNative`'s epoch compare (every host call,
  every tier), the `suspend_depth` check at the top of every patched
  handler (every patched back-edge) and in the cached-entry predicate,
  and the entry lease (every trace entry) are measured by the usual instruction-count A/B on
  `bench/` and the host-call benchmark. Neither may cost more than noise
  on `bench/`.
- **No regression** in `bench/` (none of them call host functions): the
  usual A/B, tier-0 and JIT-on, plus native residency (`--jit-stats`) on
  the new benchmark.

The benchmark runs through the C API (a C runner like the one used for
4fed40b, or `embed/rust/mahina/examples/`), because only the C API
registers host functions. The coherent-exit ABI, the statuses and the
GC lifetime protocol (Phases 2a and 2b) land before any trace executes a
callback (Phase 2c).

## 9. Open questions for review (decided 2026-10-10)

- **Q1.** Amend doc 00 and doc 02 so a host call is an execute-once
  effect a precise trace may contain (§6)? **Bart: yes.**
- **Q2.** Callbacks from a trace-called or recorded host call run with
  the JIT suspended in v1 (§5.9)? **Bart: yes.**
- **Q3.** Leaf host functions (§5.12): in v1, as a later phase, or never?
  **Bart: part of this plan, as Phase 4.**
- **Q4.** A native stops being traced after its first disturbing call
  (LuaJIT's rule), or after a threshold (§5.9)? Threshold 1 bounds the
  suspended-callback cost; a higher one keeps tracing hosts that rarely
  disturb, at the price of more suspended calls and retire/re-record
  churn. **Bart: like LuaJIT, threshold 1.**
- **Q5.** `nwanted == all_results` and multret arguments (doc 27):
  deferred past v1? **Bart: deferred; tracked in TODO.md.**

Revision 2's Q4 (count trace-initiated calls against
`max_native_reentry`) is withdrawn: it would make the recursion limit
depend on the tier (§5.8, Codex round 2 #8).

## 10. References

- LuaJIT: `lj_ffrecord.c:162-195` (`recff_nyi`, stitching),
  `lj_record.c:794` (`rec_call_specialize`), `lj_crecord.c:1264-1332`
  (`crec_call`, the bool-result guard at `:1301`), `lj_asm_x86.h:757`
  (`asm_callx`), `lj_opt_mem.c:168`, `:839` (forwarding across calls),
  `lj_ccallback.c:716` ("bad callback"), `lj_ccall.c:1199` (callback
  blacklist), `lj_gc.c:668`, `:762` (on-trace GC).
- mahina docs: 00 (§Embedding), 01 (trace lifecycle), 02 (determinism),
  04 (snapshot/replay schema), 10 (cross-frame tracing), 17 (sibling
  handoff), 23 (body callouts), 27 (multret), 39 (peeling), 45 (precise
  deopt, D5, D6), 54 (inline frame motion), 56 (resume-coherent exits),
  59 (embedding API, E6), 60 (the hand-written host-call entry), 61
  (in-flight frames, GC liveness, Phase Q, F1/F3).
- mahina source: `trace_recorder.zig:4101` (`host_barrier`), `:1687`
  (`needs_precise`), `:1741` (precise snap stamping), `trace_snapshot.zig:247`
  (`validate`), `irinterp.zig:832` (`guard_gc`), `:845` (string helper
  failure), `:1388` (precise restore), `nativegen.zig:774` (flush kinds),
  `:2721` (precise materializers), `nativegen_alloc.zig:515`
  (write-dominated homes), `:659`, `:1626`, `:1743`,
  `nativegen_emit.zig:1521`, `interp.zig` `callHostNative`, `:1198`
  (seeding), `:1761` (error location), `:2314` (`callValue` reentry
  count), `:3237` (recording feed), `:4645` (`.precise_error`
  consumer), `:5980`, `:6081`, `:6158`, `:6259` (patched-entry bypass
  sets), `:6761` (tier-0 host
  dispatch), `:7702` (grid deflation in `indexGet`), `capi.zig:1130`
  (`raiseLocatedError`), `trace_ir.zig:854`, `:872`, `:887`
  (`isSideExitGuardOp`, `exitIsPreEffect`, `requiresPreciseSnapshot`),
  `trace_code.zig:162`, `:343`, `table_runtime.zig:30` (status
  ordinals), `gc.zig:757` (`willFree`).

## 11. Review round 1 (Codex and Antigravity, 2026-10-10): dispositions

Both CHANGES REQUESTED. Receipts: `docs/reviews/doc63/codex-rev1.md`,
`antigravity-rev1.md`. The central change: host calls force precise
recording (§5.3), which answers the execute-once findings with machinery
already built and tested for `tnew`, instead of auditing every exit
route of an ordinary trace (revision 1, now §7.4). Section numbers below
are revision 2's.

| Finding | Disposition |
|---|---|
| Codex 1, AG 1: loop-done guard not attachable, motivating loop aborts | Precise loop-done exit uses the resume materializer (§5.3). |
| Codex 2: helper exits outside the guard set | Precise snapshot required on every exit-capable op; Phase 2 extends the predicate and adds a finalize check (§5.3). |
| Codex 3, AG 2: armed exits, sibling handoff, `ordinary_guard` | Precise pages refuse links and patch windows; `call_host` in `isStateEffectOp` (§5.1, §5.3). |
| Codex 4: flush order; sunk stores replayed over callback writes | Precise traces sink no stores; the flush is the precise materializer in its own order; the epoch exit materializes nothing (§5.4, §5.5). |
| Codex 5, AG 4: `pc = B + 1` breaks doc 61 masking | `pc = B` during the call, `B + 1` on success, `in_flight` kept on error (§5.4). |
| Codex 6: seeds beyond the window; raw cell seeds | Protected span covers seeds; root-set equality argued and asserted (§5.4). |
| Codex 7, AG 6: episode state cannot be saved and restored | Nested execution runs with the JIT suspended (§5.8, Q2). |
| Codex 8: nested execution can retire the suspended trace | Suspension forbids retirement; Phase Q defers sweeps (§5.8). |
| Codex 9, AG 5: epoch misses deflation, `__index`, GC budget | Epoch drawn at the VM boundary, whitelist of pure accessors, GC budget re-checked (§5.5). |
| Codex 10: post-call `slot_load` is hoisted | `host_result` op with its own SSA identity (§5.1). |
| Codex 11: `guard_func` cannot guard a Native | `guard_native` (§5.1). |
| Codex 12: error ABI undefined | Status table and consumer contract (§5.7). |
| Codex 13, AG 3: leaf path reads stale slab, error state | Leaf args marshalled from SSA; cold materialize on error (§5.10). |
| Codex 14, AG 7: phasing and budget | Rooting and suspension in Phases 1–2; budget split and provisional (§8). |
| Codex 15: LuaJIT bool-result guard | Corrected (§2). |
| AG 8: epoch guard IR and snapshot | `guard_host_epoch` with an empty snapshot at `B + 1` (§5.1, §5.5). |

## 12. Review round 2 (Codex and Antigravity, 2026-10-10): dispositions

Codex CHANGES REQUESTED, Antigravity APPROVE WITH CHANGES. Receipts:
`docs/reviews/doc63/codex-rev2.md`, `antigravity-rev2.md`. Section
numbers below are revision 3's. The main changes: a named slab-coherent
snapshot form used for every exit after the call, including errors
(§5.2); protection of seeds separated from rooting (§5.5); a written
proof for values held across the call (§5.7); the callback blacklist
that bounds suspension (§5.9); Phase Q's F3 amended (§5.10).

| Finding | Disposition |
|---|---|
| Codex 1, AG 1: empty snapshot fails validation; no recorder minting | Coherent snapshot form with its own validation, placement rule, admission and executor handling; `C_B`/`C_B1` minted per site (§5.1, §5.2, Phase 2a). |
| Codex 2: host errors restore the pre-call snapshot over callback writes | Failure exits through `C_B`, writing nothing; test with mutation, collection and failure (§5.1, §5.8). |
| Codex 3: seed copies root what tier-0 frees | Seeds protected from overwrite but scrubbed, not rooted (`trace_seed_span`); test with `gc_stress` off (§5.5). |
| Codex 4: deferring retirement does not protect weak constants | Logical invalidation at sweep, deferred physical destruction, `Native` constants in F1, F3 restated; Prerequisite B (§5.10, Phase 2b). |
| Codex 5: recording-time callbacks feed the recorder; gates incomplete | `callHostNative` suspends while recording; a disturbing call aborts the recording; seven gates enumerated, each tested (§5.3, §5.9). |
| Codex 6: result-type failure loses the actual result | Tag checked before unboxing; mismatch exits through `C_B1` with the results in the slab; the four test shapes listed (§5.1). |
| Codex 7: precise traces do have heap homes | "No heap φs" replaced by the epoch proof and a call-site rule in `nativegen_alloc`; tests with a carried table and `tnew` (§3, §5.7). |
| Codex 8: Q4 changes the recursion limit by tier | The shim does not count reentry; `host_out` sizing argued without it; Q4 withdrawn and replaced (§5.8, §9). |
| Codex 9: leaf error located before cold materialization | Leaf path stores `pc = B` before the call (§5.12). |
| Codex 10: helper OOM retries | Confirmed pre-existing precise-mode bug; Prerequisite A, fixed first (§5.4). |
| Codex 11: callback performance bound vs suspension | Disturbing natives stop being traced (Q4), so suspension is bounded; Phase 0 measures hot nested work and varies args, window and seeds; Phases 2a/2b before 2c (§5.9, §8). |
| Codex 12, AG 2: whitelist contradiction; `mh_string_new`; `A_rem` | Exemption table with an argument per function; `A_rem` in `aux` from the `guard_gc` pass; the check's formula stated (§5.6). |
| Codex 13: precise ≠ loop-only | §3 separates precise limits from native admission; v1 admission policy stated in §5.3; head-anchored host calls a Later item. |
| AG 3: leaf results and cold-path frame writes | Leaf entry writes results to the slab; cold path sets `in_flight` and `stack_top` (§5.12). |
| AG 4: status ordinals | Pinned 0–4; ordinal test extended (§5.8). |
| AG 5: unguarded `host_result` | Every result is tag-checked, so its kind is concrete, never `.boxed` (§5.1). |

## 13. Review round 3 (Codex and Antigravity, 2026-10-10): dispositions

Codex CHANGES REQUESTED, Antigravity APPROVE WITH CHANGES. Receipts:
`docs/reviews/doc63/codex-rev3.md`, `antigravity-rev3.md`. Section
numbers below are revision 4's. Both found the round-2 dispositions
sound for the ordinary call path; the remaining gaps were trace
lifetime, the suspension gates' ordering, the blacklist's reach, and
the leaf path.

| Finding | Disposition |
|---|---|
| Codex 1: a logically retired trace panics in `traceById` before the precise consumer | Precise terminal results are handled through the entered-trace borrow before live-id resolution and post-run drains; `final_trace_id == ct.id` asserted; success and failure tests (§5.10). |
| Codex 2: release point ignores entry-patch borrows; Phase Q's transaction not isolated | Phase Q split into logical and physical work; physical batch (incl. patch drain) queued and run at the outermost entry wrapper after its last patch access; storage reserved at commit (§5.10). |
| Codex 3: seeds become gaps on error | Seed span scrubbed to nil before its descriptor is cleared on error; `xpcall`-handler collection test (§5.5). |
| Codex 4: leaf result exits through `C_B1` without a coherent slab | Leaf keeps the preflush and frame writes; skips only the epoch guard, suspension, seed span and budget check; leaf placement rule stated (§5.2, §5.12). |
| Codex 5: cached entry at `interp.zig:7088` and patched non-live recovery run before the gates | Suspension checked before any JIT decision or mutation: in the cached-entry predicate and at the top of each patched handler, before `unpatchSlot`; tests for both (§5.9). |
| Codex 6: blacklist reaches only one trace; failed calls skip it; funnel's early return | `guard_native` checks the disturbance count before every traced call; counting in a `defer` covers failure; Phase 0 benchmarks two callers and caught failures (§5.1, §5.9, §8). |
| Codex 7: `mh_error_set` justification wrong | Exemption re-argued (stages text, no guest state); staged-then-success test (§5.6). |
| AG 1: `site` lacks `S_B` and the callee; `guard_native` lacks its operand | `HostCallSite` with `preflush_snap` and `callee_k`; `guard_native callee, k` with `snap = S_B`; `call_host`'s `snap = C_B`; finalize links them (§5.1). |
| AG 2: per-call scratch in trace metadata; `Vm` may move | `host_epoch` on `Heap` (stable, baked); the pre-call value in a spill slot or tier-1a local; the site table is read-only (§5.1, §5.6). |
| AG 3: native code has no `*Vm` | Shim takes the baked `*NativeSeedCtx` (its `vm` is valid for the episode) and a baked site pointer (§5.8). |
| AG 4: F3 assertion needs the executing trace | `TraceState.suspended_trace`, set by the shim; at most one (§5.10). |

## 14. Review round 4 (Codex and Antigravity, 2026-10-10): dispositions

Codex CHANGES REQUESTED, Antigravity APPROVE WITH CHANGES. Receipts:
`docs/reviews/doc63/codex-rev4.md`, `antigravity-rev4.md`. Section
numbers below are revision 5's. The main change: seeds are no longer
protected by raising `stack_top`; the epoch proof covers them, which
keeps tier-0's stack limit and removes the error-path scrub.

| Finding | Disposition |
|---|---|
| Codex 1: raising `stack_top` over seeds changes the stack limit | `stack_top` exactly as tier-0's native arm sets it; seeds stay above it, unrooted, and are read only after an epoch-clean call, when nothing can have written there; debug check plus capacity-boundary tests (§5.5). |
| Codex 2: physical retirement gated only by suspension | Physical work needs `suspend_depth == 0` and no entry lease, for every retirement source including blacklist exits; `TraceState.entry_leases` (§5.10). |
| Codex 3, AG 2: no release point for recording-time suspension | Second release point: `callHostNative` lowering `suspend_depth` to 0 with no lease; tests for collections during recording and an aborted recording (§5.10). |
| Codex 4, AG 1: shim cannot name its trace | Dispatcher publishes the entered `ct` as `TraceState.executing` (a borrow, not a lookup); callee read from the slab; `callee_k` dropped from the site (§5.1, §5.8). |
| Codex 5: bypass provenance in head/continuation handlers | Head and continuation bypasses dispatch `&st.proto.code[cur_pc]`, loop handlers keep their virgin path; straight-line test (§5.9). |
| AG 3: tier-1a has no seed context | `ExecCtx.seed_ctx`, filled by the dispatcher (§5.8). |
| AG 4: `IrInstr` operand layout | Field table in §5.1; `host_result`'s expected type in `ty`. |

## 15. Review round 5 (Codex and Antigravity, 2026-10-10): dispositions

Both APPROVE WITH CHANGES. Receipts: `docs/reviews/doc63/codex-rev5.md`,
`antigravity-rev5.md`. Both audited §5.5's claim that an epoch-clean
host call writes nothing above `stack_top`, and found it holds.

| Finding | Disposition |
|---|---|
| Codex 1: leaf refusal for APIs without a status | Refusal by return type, a latched violation, and `cHostCall` failing the call even on a success return; test (§5.12). |
| Codex 2: wrong seed-context address for tier-1a | `self.trace.registry.native_seed_ctx`; a missing context refuses before any host call (§5.8). |
| AG 1: who raises `suspend_depth` | Exactly one owner per call: the shim for traced calls, `callHostNative` only for recording-time calls; the second release point applies only to the latter (§5.9, §5.10). |
| AG 2: `callHostNative` does not write registers | The shim copies the returned `host_out` slice and nil-pads (§5.8). |
| AG 3: site index operand | `call_host` carries the site in `a` like the others (§5.1). |
