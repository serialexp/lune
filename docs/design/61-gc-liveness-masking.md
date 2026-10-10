# mahina — GC liveness masking — Design

Status: rev 7, approved by codex + antigravity; Q1 = (a), Q2 = label dead
slots (Bart, 2026-10-09); Phases P, 0 and Q landed, Phase 1 implemented
Owner: Bart + agents (amber-badger)
Last updated: 2026-10-10

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items
as they land; move bullets to Done once everything inside them is checked.

### Done

- [x] **Rev 1 → rev 2 tradeoff review** (codex, 2026-10-05). It compared rev 1
      with an alternative draft; rev 2 is the merge it recommended.
- [x] **Rev 2 review** (codex REVISE, antigravity REVISE, 2026-10-05). Every
      blocker is folded into rev 3; see "Revision history".
- [x] **Rev 3 review** (codex REVISE, antigravity REVISE, 2026-10-05). Every
      blocker is folded into rev 4.
- [x] **Rev 4 review** (codex REVISE, antigravity APPROVE, 2026-10-05).
      Codex's blockers and both reviewers' should-fixes are folded into rev 5.
- [x] **Rev 5 review** (codex REVISE, antigravity APPROVE, 2026-10-05).
      Folded into rev 6.
- [x] **Rev 6 review** (codex REVISE, antigravity APPROVE, 2026-10-05).
      Folded into rev 7.
- [x] **Rev 7 review: codex APPROVE, antigravity APPROVE** (2026-10-05). Each
      left one non-blocking should-fix, folded in place.

### Outstanding

- [x] **Q1 decided (Bart, 2026-10-09): (a) weak trace pools plus
      invalidate-on-sweep** (§7).
- [x] **Q2 decided (Bart, 2026-10-09): label dead slots** in the visualiser
      (§10).
- [ ] **Phase Q — Q1(a) lands before Phase 1** (codex rev 2: land Q1 before
      masking). It needs its own design section and review covering:
  - the weak pool;
  - the sweep-time invalidation set (recorder, dispatch/link references,
    native slots, dependency index), finished before the memory is freed;
  - batched retirement;
  - a mass-retirement benchmark.

  **The design (§7.1 rev 3) is approved by codex and antigravity**
  (2026-10-10; receipts in `docs/reviews/doc61/phaseQ-rev1.md`). Codex's
  rev 3 should-fixes are folded in.

  **Implemented (2026-10-10).** The implementation review's blockers are
  fixed (the widen-eviction double retire, recorder OOM on prep-link,
  `McodeArena.free` allocating on the collection path). Step 8's drain
  stays at the safe point (see step 8). R(T)'s superlinearity is fixed in
  the same change (registry anchor index, indexed per-component topology
  build). The implementation review's missing tests landed with
  `bench-retire`'s native table (2026-10-10); Phase Q is done.
- [ ] **Phase V — visualiser labels dead slots.** Its liveness source must be
      tier-identical data. Options are an exported per-frame live mask in the
      snapshot, or `reg_live` re-derived from the proto and the frame
      shape (§4).
- [ ] **Phase P — pre-existing rooting bugs (§3), each its own change, before
      Phase 1.**
  - [x] **P1:** surplus varargs past the caller window are clobbered by the
        callee window (confirmed in every tier). Fixed: the callee window
        sits above the argument span, the recorder refuses the shape, and
        keyframe restore accepts ordered windows with a gap (§3).
  - [x] **P2:** dynamic argument spans above `stack_top` during re-entry.
        CONFIRMED as a use-after-free reachable from plain Lua: `print`
        with `__tostring` arguments 3+ past the window panicked in every
        tier, and gave silently wrong output on older builds. Fixed in the
        `.call` native and `__call` arms (§3).
  - [x] **P3:** native-held transient values across every re-entry boundary.
        CONFIRMED use-after-free from plain Lua (a fused `a[i][j]` with a
        native `__index`). Fixed by parking a native callee and its arguments
        in `callValue`. Two capi-side items are still open (§3 P3 table,
        rows 7–8).
  - [x] **P4:** keyframe capture rejected, in release builds too, inside any
        re-entered native activation (`native_reentry_depth != 0`, i.e.
        under `callValue`). A native called directly from bytecode doesn't
        count as re-entry, so capture inside one is still accepted. That is
        mid-instruction too, and closing it is the `in_flight` half, which
        joins this check in Phase 0 (§6.4; codex Phase P review).
- [ ] **Phase 0 — frame state made exact.** Behaviour-neutral on its own;
      pinned by the frame-shape tests (§8).
  - [x] `gcTrampoline` publishes the innermost pc before `collect()`.
  - [x] `CallFrame.in_flight`: set on entry, restored on success, left set on
        error. Catchers restore `frames[entry_depth − 1]` (§4.2).
  - [x] `protectedCall` marks the topmost faulting frame in flight while an
        `xpcall` handler runs, when one exists (§4.4).
  - [x] Fault-pc invariant: a rejected Lua push re-stores the call pc before
        raising (§4.4).
  - [x] Backtraces use the in-flight marker. `backtraceFrames`/`callSiteAt`
        assume pc + 1 for every parent (`interp.zig:1975`). Moved here from a
        separate change (codex rev 4 should-fix).
  - [x] Audit of the JIT store-elision sites (§2, "Phase 0 audit"). One
        pre-existing open question (bridge carried homes) went to TODO.md;
        the keyframe-bytes question goes to Phase 1.
  - [x] `Proto.maskable` is computed at compile time (§5).
  - [x] P4's keyframe-capture refusal also covers any frame with `in_flight`
        set (§6.4), which includes a native called directly from bytecode.
        Flip `keyframeser_capture_test`'s top-level `capture_probe()` from
        accepted to refused, unless a legitimate capture-from-native caller
        turns up (check `main.zig`/`wasm_entry.zig`).
  - **As implemented** (differences from the text below, each simpler):
    - **Marking sites.** The dispatch `.native` arm marks every native
      (builtin or host) for its whole duration, and `callValue` marks the
      current frame when `depth > 0`. Host entries (H1 `pushHostCall`/
      `runPushedFrame`, the `.S` entry) mark nothing themselves. At
      `depth > 0` a host entry only ever runs inside a host fn, whose caller
      the native arm or `callValue` has already marked. `runPushedFrame`
      asserts that in debug builds. At depth 0 there is no caller frame.
    - **capi catcher.** For the same reason `guestFault` neither captures nor
      restores the flag, and its signature is unchanged. Its entry frame,
      when there is one, is in flight before the entry and stays so; it only
      asserts that. `protectedCall` does capture and restore as specified.
    - **Initialisation.** The Zig literal default, the native inline push
      (`movByteMemImm`), and the `.S` frame write (`CF_IN_FLIGHT`, with an
      `EXPECT` on its size) all initialise the flag false. The `.call`
      opcode path asserts the caller's flag is clear before any push, which
      caught a stale `.S`-pushed slot during development.
    - **Fault-pc invariant.** The opcode path re-stores `pc − 1` on a
      `pushFrameVararg` failure (the first of the two options). That failure
      cannot happen today: `pushFrameVararg`'s two checks (depth, register
      capacity) repeat the opcode path's early checks exactly, and those
      raise with `frame.pc` already naming the `.call`. The re-store keeps
      the invariant if the two ever diverge. The stack-overflow test pins
      the early-check path, so the mutation "no re-store" survives it.
    - **`xpcall` handler mark.** `protectedCall` needs no explicit mark. It
      runs the handler through `callValue`, which marks `frames[depth − 1]`:
      the topmost faulting frame when the fault left one, or the entry frame
      when it didn't. That mark stays for the handler's whole run and is left
      set on a fatal handler fault, which is exactly §4.4. An explicit mark
      survived its mutation for this reason and was removed.
    - **Untestable mutations.** "Catcher not restoring
      `frames[entry_depth − 1]`" and "marking without the
      `depth > entry_depth` check" leave no observable difference. Every
      catcher's entry frame is already in flight (a native's caller, or a
      `callValue` re-entry), and every path that touches its flag restores
      the same value. The restores stay as specified.
    - **P4.** `encodeSnapshot` refuses when any frame in `frames[0..depth]`
      is in flight. The keyframe capture test now expects every capture from
      a native to be refused, and a capture after the run to succeed.
    - **Debug net.** Every collection in a safety build classifies every
      frame of a maskable proto and panics on `unknown` or on a mask pc
      outside the code (`assertFrameShapesKnown`). The gc-stress test legs
      collect at every safepoint, so the whole suite exercises it. The
      compiler asserts that every proto with liveness is maskable.
    - **Liveness precision (§5).** The call-layout check failed on ordinary
      compiled code until `bc_liveness` stopped treating a multret
      consumer's whole-window read as live back past its producer; see §5,
      "As implemented".
- [ ] **Phase 1 — the masked `.gc` root walk + scrub (§6).**
  - [x] Close the conservative multret-consumer row first (§5, "Phase 1
        prerequisite", options A / A′ / B; codex Phase 0 blocker 2).
        **Chose B.** `.call` with `b = all_results` records
        `CallFrame.multret_top` (the dynamic top, relative to the base)
        before anything can fail, so a faulting consumer keeps it. A frame
        in flight at such a call is masked `∩ [0, multret_top)`. The
        call-layout check gains one clause: a consumer that is itself a
        producer must be followed by its own consumer at the same or a
        lower base, so nothing at or above the base survives the chain.
  - [ ] Decide whether keyframe capture masks dead slots too (§2, "Phase 0
        audit"). **Open for Bart** (options in CURRENT_TASK.md).
  - [x] Masking driven by the shared `maskable` predicate, with an alias
        bitset and dead slots set to nil before sweep. **As implemented:**
        one keep bitset (`Vm.gc_keep`, `stack_slots / 64` words). It starts
        all ones, so gaps between windows and unknown frames are rooted
        whole. Every masked window is cleared, then each frame's row, its
        varargs span and the open-upvalue slots are ORed back in. The walk
        roots the kept heap slots; `collect` nils the rest below
        `stack_top` between `invalidateDeadTraceConsts` and the sweep. Cost
        is O(stack_top / 64 + frames × words), no allocation.
  - [x] Exit-snapshot sparsity, composite-bridge admission, the linked
        numeric-for `a+3` skip and the watermark all gated on `maskable`
        (watermark: also not captured; `a+3` skip: also dead at the
        fall-through) (§5). **As implemented:**
    - Exit snapshots record every `.def` slot of a non-maskable proto.
    - The bridge uses the empty row there.
    - `TraceCode.loopDoneFlushSupported` is the one gate both tiers
      consult (the store inventory plus `maskable` ∧ `R[a+3]` dead at the
      fall-through); otherwise the guard takes the ordinary deopt
      (option ii). A page records whether every loop-done guard emitted
      its linked branch (`CompiledTrace.linked_loop_done_ok`). Without it
      the dispatcher runs the page in ordinary mode and `arm` refuses a
      `.link_terminal` into it: a link-mode run that ended in an ordinary
      loop-done deopt was chained as if the flush had committed, losing
      the final iteration (found by the §8 non-maskable variant; the
      `sgm_setpos` decline had the same latent hole). The chain's call A
      runs an inner root in linked mode too; there the per-guard
      `TraceCode.linkedLoopDoneEmitted` (the predicate emission itself
      consults) ends the burst at the inner header exactly as tier-1a's
      declined flush does (codex Phase 1 review blocker: a captured
      register after a loop nest made the inner page decline, and the
      burst dropped the last `c = c + 20` of every followed trip).
    - The watermark drops a slot only when `trace_finalize.watermarkMayDrop`
      holds: maskable and dead at the anchor pc. A captured register is
      live at every pc, so this also excludes captured slots, in O(1).
  - [x] The recorder's `for` link checks no longer read the dead `R[a+3]`
        (`ForEntryView` substitutes the value tier-0 is about to write).
        The scrub made that read see nil and refuse the link.
  - [ ] Gates, hashgate (§9 regeneration procedure), the §8 tests and
        mutations, the boundary benchmark, and a pt-default board.
        **Done except the board.** Hashgate needed no regeneration (90
        digests match). Each site has a test that fails when its
        `maskable` gate is removed: site 1 (`trace_finalize_test`), site 3
        (`interp_semantics_test`, wanted and attached exits, which a
        `reg(k)` probe reads right after the materialisation, asserting
        the exit-side hops ran), site 4 (`trace_fingerprint_test`), site 5
        (`interp_tier1a_test`, and the `reg(k)` probe after a linked inner
        loop). An object id printed after the function returns cannot see a
        stale register in its window, so the §8 id programs are not the
        site oracles.
- [ ] **Phase 2 — land the dead-φ writeback filter on top.**
  - [ ] Re-base `phiLiveRow`/`phiWritebackKept` on `Proto.maskable` (§5).
  - [ ] Retire the numeric-for `locals_watermark` drop rule. Liveness
        subsumes it, and it can drop a captured slot (§5).
  - [ ] `/tmp/gcphi_new.lua` as a doc test, printing the same id in every
        mode.
- [ ] **Phase 3 — relax doc 24 D3's full-write-set flush.** Today
      `alloc_count != 0` keeps every φ only because the collector roots every
      register. Re-derive it under masking. Separate review.
- [ ] **Defer — `.snapshot` walk masking (doc 21 Phase B).**

## Why this exists

The native JIT stores every slot a loop defines back to `regs[]` on every
iteration, dead temporaries included. On `pi_leibniz` (99.5% native residency,
8.9× LuaJIT on the pinned board) that is 8 tag + 8 value stores per iteration.
LuaJIT stores none of them: a slot that no later bytecode reads is simply not
restored (`snap_usedef`, lj_snap.c). We have the same per-pc liveness
(`Proto.reg_live`, doc 56 §4.2). A filter that drops a φ dead at every pc that
consumes the φ set is written, gated and review-clean on every runtime path
except one.

That one path is the collector. `Vm.forEachRootHeader(.gc)` roots every
register in `0..stack_top`, live or not (`src/interp.zig` ~2419). A dropped φ
leaves a stale value in a dead slot. If that value is a heap reference, or
replaces one, the JIT run keeps a different set of objects alive than tier-0.
It then re-interns a swept string with a fresh id, and the printed table ids
diverge. Codex's counterexample does exactly this: tier-0 prints
`table: 0x178f`, the traced modes print `0x1790`. Object ids are deterministic
program output, so this is a determinism bug.

LuaJIT roots the whole stack too (`gc_traverse_thread`), and gets away with it
because its addresses are not part of a contract. We adapt instead of
copying: the collector's view of the stack becomes a pure function of the
program's logical state. Then what a dead slot holds is unobservable in every
tier, every JIT may elide dead stores freely, and dead objects are freed
sooner.

## Goals

1. **Determinism theorem.** At every collection, every rooted register slot
   holds a value that is identical in every tier, and the rooted set is a
   function of tier-identical data only.
2. **No dangling reads.** No later reader of a register slot ever sees a
   pointer to a swept object.
3. **Sound by default.** Anything the collector cannot classify is rooted.
   Goal 1 is then kept by making the JIT keep every φ in exactly those cases:
   **one predicate shared by the collector and the φ filter** (§5).
4. **Linear cost, no allocation per collection** (§6.3).

## Non-goals (v1)

- Masking the `.snapshot` walk or verbatim stack serialization (doc 21 Phase B).
- Weak tables / finalizers (none exist, `src/gc.zig:7`).
- Keeping collection timing as it is today. Fewer roots means a lower
  `next_gc` (`gc.zig:776`), so collections move, identically in every tier
  (§9).

## 1. Facts the design rests on

Verified against the tree at `b4abe70` (rev 3 reviews).

- **Where collections happen.** Only at the tier-0 dispatch prologue
  (`interp.zig:2852 → gcTrampoline`) and via `mh_collect` (`capi.zig:584`),
  which a host callback can call. No collection runs on trace: `guard_gc`
  refuses entry unless the trace's allocations fit under the threshold
  (doc 24 D3), and callouts are audited `may_collect = false`.
- **Lua call windows.**
  - An opcode call lays the callee at `base + caller.num_registers`
    (`interp.zig:6382`) and copies the fixed parameters. The native inline
    push does the same (`nativegen_emit.zig:979`).
  - Re-entry (`callValue`) lays the callee at `stack_top` (`interp.zig:2085`).
  - Host entry and the `.S` path bind arguments into an argument region below
    the callee base.
  - Surplus varargs are not copied. They stay where the arguments were
    (`va_base = base + a + 1 + num_params`).
- **pc conventions.**
  - The innermost frame's `frame.pc` is stale at a prologue collection
    (written at step 6, `:2965`); the trampoline's `pc` argument is the true
    next pc.
  - A caller suspended at a Lua call holds call pc + 1 (`:6410`; native push:
    `term_aux + 1`).
  - A frame whose instruction is running other code holds the instruction
    itself (step 6).
  - **The frame does not record which.**
- **Same-frame nesting.** One instruction can re-enter many times. An opcode
  calls a native, and the native calls `callValue`, possibly repeatedly and
  recursively, without pushing a frame (`interp.zig:2228`). `table.sort`'s
  comparator loop and `require`'s post-call `loaded.set` keep relying on the
  frame's operands between and after re-entries (`stdlib/package.zig:300-363`,
  `stdlib/table.zig:264`).
- **xpcall handlers run on top of live faulting frames.** `protectedCall` keeps
  `depth`/`stack_top` raised and lays the handler at the raised `stack_top`
  (`stdlib/errors.zig:79-104`). The faulting frames stay in
  `frames[0..depth]`. They are frames, not gaps.
- **Open upvalues.** `gc.zig:703` marks only closed upvalues. An open
  upvalue's value is kept alive by the stack scan alone.
- **`reg_top_pending` is not a lifetime.** A `call` consuming `all_results`
  clears it before invoking the callee (`interp.zig:6374`). Dynamic producers
  write beyond `stack_top` (`interp.zig:6708`).
- **`Proto.reg_live`.**
  - `live_in = use ∪ (live_out − kill) ∪ captured`.
  - Captured registers are live at every pc.
  - `call c=all` kills nothing (`bc_liveness.zig:202`).
  - `words == 0` means "unknown".

## 2. Where stale values come from, and the theorem

A register slot can differ between tiers only if the JIT elided a store to it.
The lemma's premise is that **every** elided store to slot `s` in proto `F`'s
window is to a slot dead at every pc `R` where tier-0 or a linked trace
resumes. There are five elision sites. Codex found the third, fourth and
fifth in its rev 4, rev 5 and rev 6 reviews:

1. **Loop-close φ writeback, numeric-for watermark** (today; retired in
   Phase 2, see below).
2. **Loop-close φ writeback, dead-φ filter** (Phase 2). `R` is the close's
   resume pc and each `loop_done` source pc.
3. **Side-exit snapshots** (today, doc 56 §4.2). `commitExitSnap`
   (`trace_recorder.zig:1433`) records only `.def` slots live at the exit's
   resume pc. Materialisation writes only the recorded ones
   (`irinterp.zig:214`, and the native exit path). A dead definition is left
   holding an earlier value, while tier-0 holds the newer one. `R` is the
   exit's resume pc.
4. **Composite bridge exits** (doc 17). `bridgeMatchesExitSnapshot`
   (`trace_code.zig:781-805`) admits a bridge only if its φ emission set
   agrees with the exit snapshot **on slots live at the landing pc**.
   `emitCompositeBridgeSnapshot` (`nativegen_emit.zig:2519-2531`) then writes
   only that emission set. A slot dead at the landing pc can be left
   unwritten, or written with a different terminal φ value than tier-0's.
   `R` is the landing pc.
5. **Linked numeric-for completion** (the linked `loop_done` exit).
   - **What it does.** It flushes the loop-close φs except the visible loop
     variable `a+3` (`nativegen_emit.zig:2504-2508`, `irinterp.zig:125-133`).
     That φ holds the **next** index (`trace_recorder.zig:3563`), which tier-0
     never writes on completion. Tier-0's `for_loop` leaves `a+3` with
     whatever the final iteration's body left there (`interp.zig:5683`).
     After linked execution, `a+3` holds whatever an earlier flush or tier-0
     iteration left there.
   - **Why it matters.** The two differ whenever the body assigns the loop
     variable (`i = tostring(i)`), so it can be a heap value. `R` is the
     `for_loop`'s fall-through pc, where `a+3` is normally dead. A
     **captured** loop variable is the exception: its captured bit makes it
     live everywhere (§2, captured registers).
   - **Gate (Phase 1).** The skip is allowed only when `maskable(F)` ∧
     `a+3 ∉ live_in[R]`. Otherwise the completion must not leave `a+3`
     stale. Flushing the terminal φ would write the wrong value, the next
     index. There are two options, and which one is an implementation choice:
     - (i) the recorder names the **pre-test** ref of `a+3`, its binding
       before the `for_loop`, on the `loop_done` guard, and the completion
       flushes that;
     - (ii) the exit declines linked completion and takes the coarse deopt,
       so tier-0 replays the final iteration. Its natural hook is
       `TraceCode.loopDoneSnapshotSupported` (`trace_code.zig:613`). Native
       codegen (`nativegen.zig:2610`) and tier-1a (`irinterp.zig:98`) both
       consult that one predicate already (antigravity rev 7 tip).

Site 3 materialises for every **wanted or attached** exit, the resume-coherent
`exit_side` contract (`trace_exec.zig:69-76`, `irinterp.zig:1419-1428`). That
includes an exit that resumes into tier-0 at `P` with no child trace. An
exit that is neither wanted nor attached takes the coarse deopt, where tier-0
re-runs the iteration and writes the slot itself.

So today's all-live root walk is **potentially** tier-dependent after a
site-3 or site-4 exit that leaves a heap value in a dead slot. That would be a
pre-existing hole that masking closes, not one Phase 2 creates. It is
unconfirmed: a first attempt through an ordinary guard
(`/tmp/exitsnap_gc.lua`) agreed in all three modes, as the coarse deopt
predicts. The §8 tests build the wanted, attached and bridge cases.

Phase 0 audits every native and IR exit/close/bridge writer, and lists every
other store the JIT omits relative to tier-0, against this premise. A site that
cannot state its `R` keeps every slot. Sites 2–4 satisfy the premise by
construction, because each filters on `live_in[R]`. Site 5 satisfies it under
its gate. Sites 2–5 are all gated on `maskable(F)` (§5).

**Audited non-sites** (rev 6 reviews; codex should-fix: these omissions are
harmless, not missing gates):
- **Sunk stores** write heap cells only (`.astore`, `.hstore`, `.ustore`,
  `.gstore`, `.sgm_setpos`), never register slots
  (`nativegen_exitloc.zig:112-117`, `irinterp.zig:190-200`).
- **`ret_cont`** copies results verbatim and nil-fills, as `opRet` does
  (`nativegen_emit.zig:1116-1250`).
- **Sibling handoff and the coarse deopt** flush every carried home and replay
  the iteration from the anchor in tier-0 or the sibling.
- **Precise exits** flush a full-window snapshot
  (`trace_recorder.zig:1493-1510`). Slots a precise snapshot skips are already
  coherent in the slab.
- **Inlined-callee frames** are omitted outside the surviving frame window
  (`trace_finalize.zig:59`). A guard failing at `inline_depth > 0` refuses
  snapshots and linking and coarse-deopts (`trace_exit_attach.zig:343`), so
  tier-0 pushes the callee frame itself.
- **`link_terminal`** is the loop-close φ writeback: sites 1 and 2.

The watermark (site 1) does not satisfy the premise. It drops every defined slot `>= base+4` of the anchoring numeric `for`,
by lexical position and not by liveness. That includes a register a later
captured local reuses: captured bits are permanent across the proto
(`bc_liveness.zig:254`), so such a register is live everywhere. Rev 4
therefore **retires the watermark** in Phase 2 (codex rev 3 blocker 1). Over a
`maskable` proto, liveness subsumes it. Masking itself (Phase 1) lands before
that, so in between the watermark still exists. Phase 1 therefore gates it:
the watermark drops a slot only if `s ∉ captured(F)` and `maskable(F)`. That
makes it satisfy the premise, because a non-captured slot `>= base+4` is dead
at the body start and after the loop (`compiler.zig` `freeTo(base)`).

**Phase 0 audit (2026-10-09).** Every reference above was re-checked against
the tree. Each still describes the code, at these locations:
- site 1: the drop is at `trace_finalize.zig:64-65`; the watermark is set at
  `trace_recorder.zig:3497-3498`, reset at `:6143`, and mirrored in
  `loopCloseDefeat` at `:6012-6013`;
- site 3: `commitExitSnap` is at `trace_recorder.zig:1440`; materialisation is
  `materializeExitSide` (`irinterp.zig:209-220`) and the native exit adapter
  (`nativegen_adapter.zig:263-306`);
- site 4: `bridgeMatchesExitSnapshot` is at `trace_code.zig:784-806`, and
  `emitCompositeBridgeSnapshot` at `nativegen_emit.zig:2522-2533`;
- site 5: `emitLinkedLoopDoneSnapshot` is at `nativegen_emit.zig:2508-2512`;
  tier-1a's `flushNumericForLoopDone` also has callers at
  `trace_chain.zig:504` and `:2961`; tier-0's `a+3` writes are `opForLoop`
  (`interp.zig:5876`) and `opJForLoop` (`:5947`);
- `loopDoneSnapshotSupported` is at `trace_code.zig:616`;
- `ret_cont` is `emitInlineSelfRetPop` (`nativegen_emit.zig:1119-1268`);
- the precise snapshot is `snapBoundary` (`trace_recorder.zig:1493-1505`).

Findings:
- **Site 1 is narrower than stated.** The watermark drops a slot only when
  the trace has no terminal close (head traces are exempt), no allocation
  (`alloc_count == 0`), and the slot is not an entry slot. The Phase 1 gate
  applies unchanged.
- **Site 3's live row is the guard's own pc, not the resume pc.** For a
  branch guard tier-0 resumes at the untaken successor. A `jmp_if*` kills
  nothing, so that row is a subset of the guard's row, and the premise
  holds.
- **Trace input seeding** (`seedTraceInputs`, `nativeSeedFn`) writes heap
  values above the window, at or past `stack_top`. Tier-0 never writes
  those slots and the walk never scans them; trace code consumes them with
  no collection in between. Not a site.
- **No JIT path runs other code inside an instruction.** Native and tier-1a
  trace code never calls `callValue`, a native through the dispatch arm, a
  metamethod, or `collect`. Its callouts are allocation shims, raw lookups
  gated on `metatable == null`, and the seed function. A trace collects only
  by exiting at `guard_gc`. So `in_flight` has no JIT-side marking site, and
  native self-push/ret-pop frames match `opCall`/`opRet` (the self-push
  initialises the flag, pinned by a test).
- **Open question (not a Phase 0 blocker): the armed native bridge flushes
  only E.** It never reaches `deopt_exit`'s carried-home flush. A carried
  slot updated after the guard is in neither E nor the snapshot, so
  `bridgeMatchesExitSnapshot` never looks at it. The comment at
  `trace_code.zig:775` assumes that flush runs. A targeted repro (the A-viii
  sieve plus an accumulator updated after the guard, with 2,287 fused bridge
  hops) gives the right answer. So either something else keeps the slab
  coherent there or that guard is not the case; it is in TODO.md for
  verification. Either way it is a pre-existing correctness question, not a
  GC one.
- **Keyframes serialise the whole window** (`keyframeser.zig:337`), so a
  stale dead slot left by sites 3–5 reaches keyframe bytes on JIT runs.
  Masking scrubs dead slots only at collections. Phase 1 must decide whether
  capture also masks dead slots, which is cheap and uses the same rows, or
  whether keyframe byte identity across tiers was never claimed. Recorded
  for the Phase 1 review.

**Lemma (path).** Take a stale slot `s` and a later collection where `F`'s
frame sits at pc `Y`, with `Y` reached from such an `R` in tier-0 execution.
If `s ∈ live_in[Y]`, then on the path `R → Y` tier-0 wrote `s`, with the same
value in every tier, so `s` is no longer stale. Proof: `s` is dead at `R`, so
every path from `R` writes `s` before reading it. If `s` is read after `Y`
before a write, the write must lie on `R → Y`.

So a frame whose mask is `live_in[Y]` for its true current pc `Y` (or a
subset) roots no stale slot. Goal 1 needs two things:

- every frame shape gets a mask that is a subset of `live_in` at its true pc
  (§4);
- every case where the collector must root more (an unknown shape, or a proto
  without usable liveness) is a case where the JIT elided no store at any of
  the five sites, via the shared predicate of §5.

**Captured registers** are live at every pc. The φ filter and exit snapshots
read the same `live_in`, so they keep these slots. They are never stale. This covers
captured-before-definition and captured-after-close slots (rev 2 review,
codex blocker 5).

## 3. Phase P — pre-existing rooting bugs

These are wrong today, independently of masking. Masking's guarantees assume
correct rooting, so they land first, each as its own reviewed change with a
TODO entry.

### P1 — surplus varargs beyond the caller window are clobbered (CONFIRMED)

```lua
local function g(...)
  local a, b, c, d, e, f, h, i, j, k = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
  local n, s = select('#', ...), 0
  for x = 1, n do s = s + select(x, ...) end
  return n, s
end
local t = {} for i = 1, 40 do t[i] = i end
print(g(table.unpack(t)))
```

In every tier this fails with "attempt to perform arithmetic on a function
value" at the `s + select(...)` line (`/tmp/varargs_tail.lua`). The 40
arguments extend past `base + caller.num_registers`. The callee window is laid
there, and the callee's locals overwrite the surplus varargs it then reads.

Fix, LuaJIT's layout (`lj_func.c`/`BC_IFUNCV` vararg frames sit above their
arguments): when the argument span ends past the caller window, lay the callee
at `max(base + nreg, base + a + 1 + nargs)`. The fixed parameters are still
copied up, the surplus varargs stay where they are, and `stack_top` covers the
arguments for the callee's lifetime.

**Scope** (codex rev 3 should-fix): the `.call` opcode path. `callValue`
(`interp.zig:2105`) and the `.S` entry (`hostcall_x64.S:300`) already place
surplus arguments below the callee window and are unaffected.

**As implemented:**
- **The native inline push is unaffected.** It handles only static argument
  counts and writes `varargs_count = 0`.
- **The recorder refuses the shape.** When a dynamic span ends past the caller
  window, it aborts `.frame_bounds` instead of inlining the call: its inline
  window and the native push both assume `base + nreg`. Tier-0 runs that call.
- **A second symptom surfaced: a silently wrong result.** The same bug hit a
  non-vararg callee. With the span past the window, copying fixed params up
  to the window end overlapped the later params: a twelve-parameter sum came
  out 121200 instead of 393900. `@max(window end, span end)` fixes both.

**Keyframe restore** already records each frame's `base`. Its contiguity check
(`keyframeser.zig:811`) becomes "windows ordered, non-overlapping and in
bounds". No new gap field is needed.

### P2 — dynamic argument spans above `stack_top`

A native callee consuming `all_results` arguments past the window has them
above `stack_top`. A re-entry lays its window at `stack_top` over them, and an
`mh_collect` does not scan them.

**Confirmed (2026-10-09).** Here is the program:

```lua
local mt = {__tostring = function(t)
  local g = {} for i = 1, 3000 do g[i] = {i} end
  return "T" .. t.n
end}
local function fresh()
  local r = {}
  for i = 1, 6 do r[i] = setmetatable({n = i}, mt) end
  return r
end
local function run() print(table.unpack(fresh())) end
```

It panicked ("invalid enum value" in `writeValue`) in every tier, and
printed `table: 0x…` for arguments 4–6 on older builds. The span is worse
than unrooted, because natives read their arguments from `boundary_scratch`,
which is indexed by absolute slot and is not a GC root. A re-entry laid at
`stack_top` gathers its own natives' arguments into the same absolute
indices.

**Fix:** a call consuming `all_results` raises `stack_top` to cover its
argument span. As implemented, this is in the native and `__call` arms of
`.call`. It also restores the invariant behind the scratch's "a deeper call
parks its args at higher absolute indices". The span then sits in a gap (§6.1) and is rooted. Rev 2's
`dyn_hi` alias is withdrawn: it covered only slots below `stack_top`.

**Who restores `stack_top`** (codex rev 3 blocker 4). This is deliberately not
a Zig `defer`:
- **On success,** the call's native branch lowers it back to its saved value
  once the results are written. This is a **new** lowering site: today the
  native branch of the `.call` opcode (`interp.zig:6447` on) never touches
  `stack_top` (codex rev 4 should-fix). The same applies to the native inline
  push's host-call path, if it consumes `all_results` arguments.
- **On failure,** it is left raised. A failed call deliberately leaves the
  faulting frames and `stack_top` in place for diagnosis
  (`interp.zig:2187`), and the raised span is part of that state. The owner of
  the reset is the catcher that discards those frames:
  - `protectedCall` resets `stack_top = entry_top` after diagnostics and
    upvalue closing (`stdlib/errors.zig:103/113/124`);
  - capi `guestFault` does the same (`capi.zig:393`), and every capi entry
    funnels into it (§4.2).
- **Top-level `exec` failure** does not unwind (`interp.zig:2511`). The frames
  and the raised `stack_top` are kept for the CLI reporter (`main.zig:459`),
  and that VM is not resumed. A capi host never reaches this state, because
  its entries go through `guestFault`.
- **Rejected pushes and non-catchable errors** propagate the same way: the
  state stays raised until one of those catchers discards it, or until the VM
  is deinitialised.

### P3 — Zig-held transient values across re-entry

Two cases:
- `gsub` builds capture strings in a Zig array and passes them to a native
  replacement. `callValue` neither pushes nor parks a native callee's
  arguments, and the C adapter forwards them directly
  (`stdlib/string.zig:1473`, `capi.zig:1109`). A replacement that calls
  `mh_collect` sweeps them.
- A native holding a copy of an operand register loses its root if a callback
  rewrites that register through an open upvalue (`interp.zig:7574`).

Fix: a Vm transient-root stack (`transient_roots`, a `.gc` root, bounded,
allocated at init). `callValue` pushes a native callee's argument slice for the
call's duration. Any Zig code that holds a heap `Value` across arbitrary code
pushes it too. Every push is paired with a pop on every exit
(`defer vm.popTransient(mark)` to a saved mark), so the stack stays balanced
across errors. Release builds overflow to an error, never to an unrooted
value.

**Audit scope** (codex rev 3 blocker 5): every boundary where Zig code can run
arbitrary guest or host code, or reach `mh_collect`. That is every
`callValue`/`callMeta`/host-call caller, including the interpreter's own
metamethod paths (`callMeta` `interp.zig:7104` and its callers, the
`__index`/`__newindex` chains `:7436`, `:7504`, `:7515`, the `__call` path
`:6548`, `:6555`), `src/stdlib/`
and `src/capi.zig`. For each, list what it holds across the boundary:
- saved callees;
- argument slices;
- heap-backed pointers or slices into tables or strings;
- partially filled result buffers.

Then root each one, or show it is already reachable from a rooted register. The
audit's table goes in the P3 change.

**As implemented (2026-10-09).** The audit found a simpler mechanism than a
separate transient stack. `callValue`'s `.native` arm parks the callee and the
argument slice into registers at `stack_top`, the shape of a Lua call's
function slot plus arguments. It raises `stack_top` over them for the call
and restores it on success. Parking the callee came from the codex Phase P
review: a metamethod native whose callback drops the last reference to it and
collects was freed while it ran, along with a host fn's ctx. Registers below `stack_top` are already a `.gc` root.
The error path needs no pop, because it inherits the P2 discipline: every
catcher resets `stack_top` to its entry value. Overflow is
`error.StackOverflow`, never an unrooted value. The native still receives the
caller's slice (the parked copy only exists to root it), so aliasing and the
host contract are unchanged. A native that re-enters lays its windows at or
above the raised `stack_top`, so it cannot overwrite the parked copy.

CONFIRMED use-after-free from plain Lua: a fused `a[i][j]` get whose middle
table has `__index = table.sort` gets `mid` passed as the native's first
argument from a Zig local. The sort comparator collects, `mid` is swept, and
`table.sort` writes into freed memory. The fused `__newindex` set is the same.
Tests: "doc 61 P3" in `interp_semantics_test.zig` (get, set and error path,
across all 10 legs; plus the host self-drop test).

| # | Site | Held across the boundary | Disposition |
|---|------|--------------------------|-------------|
| 1 | fused `get_index2` (interp.zig) | `mid`, a Zig local, passed to a native `__index` | **UAF, confirmed.** Fixed by parking in `callValue` |
| 1b | fused `set_index2` | `mid` and the value, passed to a native `__newindex` | **UAF, confirmed.** Fixed by parking |
| 2 | `__index`/`__newindex` chain walk | `cur`, the current table in the chain | Latent. Fixed by parking: every native hop goes through `callValue` |
| 3 | `gsub` with a native replacement | capture strings in a Zig array | Latent. Fixed by parking |
| 4 | `xpcall` with a native handler | `errval` | Latent. Fixed by parking |
| 5 | `require` | `loader_data` passed to a native loader | Latent. Fixed by parking |
| 6 | the executing native itself; capi `cHostCall` reads `h.box` after the callback | the callee Native and its host ctx | **UAF, confirmed** (host test). Fixed by parking the callee in `callValue`. The bytecode arm already keeps it in `R[a]`, a fresh temp the compiler never aliases to a local, so no upvalue can clear it |
| 7 | dispatch `__call` arm; `pcall`/`xpcall` from bytecode | host `args` and `out` alias each other in `boundary_scratch` | **Open.** Breaks the host no-alias contract. capi area, see TODO.md |
| 8 | dispatch native arm, host branch | results already written to `boundary_scratch[out_lo..]` | **Open.** A nested `mh_call` can overwrite them when the range reaches past `stack_top`. capi area, see TODO.md |

The other `callValue`/`callMeta` callers keep everything they hold in a
register below `stack_top`, or in a table reachable from one.

## 4. Frame shapes and their masks

Every frame in `frames[0..depth]` is in exactly one shape. Shapes are
classified from recorded state, never guessed.

### 4.1 Innermost, between instructions

Mask: `live_in[pc]`, with `pc` the next instruction. Phase 0 makes
`gcTrampoline` store `st.frame.pc = pc` before `collect()`. Step 6 does the
same store anyway, so this is behaviour-neutral. An `mh_collect` from a host
with the VM suspended between instructions is this shape too.

### 4.2 In flight

The frame is inside instruction `P = frame.pc`, which is running other code.
Mask: `live_in[P]`, which contains every operand of `P`. The destination is
correctly left out.

`CallFrame.in_flight: bool` is **set on entry, restored on success, and left
set on error**, at every site that runs code inside an instruction:

```zig
const prev = frame.in_flight;
frame.in_flight = true;
const r = try runOtherCode(...); // error: flag stays set, frame is retained
frame.in_flight = prev;
```

Not a Zig `defer` (codex rev 4 blocker 1). On error, `callValue`
deliberately leaves the faulting frames in `frames[0..depth]`
(`interp.zig:2266`). Each of those frames is frozen inside its instruction, so
"in flight" stays true for it. A `defer` would reset it while the frame is
still there, and a parent whose `frame.pc` names a non-call instruction (a
protected function inside `.add`, faulting in its Lua `__add`) would fall out
of every shape. This is the same ownership rule as P2's `stack_top` (§3).

**Catcher restore.** The flag is restored on error by whoever discards the
retained frames. Every catcher (`protectedCall`'s three discard sites
`stdlib/errors.zig:103/113/124`, and capi `guestFault` `capi.zig:393`, which
every capi entry funnels into: `runProtected`, H1, the `.S` fault return and
index get/set at `:438`, `:807-808`, `:851`, `:1262`, `:1280`) already saves
`entry_depth` and `entry_top`. It also saves `frames[entry_depth − 1].in_flight`
when `entry_depth > 0`, and restores that flag when it resets
`depth`/`stack_top`.

**Where the flag is captured** (codex and antigravity, rev 5). It is read at
the same point as `entry_depth`/`entry_top`, **before** any marking or
re-entry. It is never read inside `guestFault`, which runs after the failure,
when the flag has already been changed. capi carries it as a third entry value
into `guestFault`, whose signature grows by one parameter. That applies to
every caller, including the `.S` fault return (`capi.zig:851`), which gets the
value from its own entry capture.
*Superseded in Phase 0* (see "As implemented" in the status list): a capi
entry at `entry_depth > 0` always runs inside a host fn, so its entry frame
is in flight before the entry and stays so whatever the callee does. There
is nothing to capture, and `guestFault` only asserts the invariant; its
signature is unchanged.
The frames above `entry_depth` are discarded, and their next push
re-initialises them. The top-level `exec` failure path keeps everything for
the CLI reporter; that VM is not resumed.

- **Sites.**
  - The `call` opcode's native/host-function path, for the native's whole
    duration (not per `callValue`).
  - `callValue` on the current frame (for metamethods, and natives that
    re-enter), when `depth > 0`. A host `mh_call` into a VM suspended between
    instructions marks the top frame as well. Its pc is then the next
    instruction, so its mask `live_in[pc]` is the §4.1 mask.
  - `pushHostCall`/`runPushedFrame`. Only the **caller** is marked. The callee
    frame it pushes starts `in_flight = false` like every push (antigravity
    rev 3 SF1).
  - The `.S` entry wherever it suspends a Lua frame.
  - `protectedCall`, around an `xpcall` handler: the topmost faulting frame
    (§4.4).
- **Nesting.** Each successful exit restores the outer state, so an inner
  return never clears an outer native's protection. This was the shared rev 2
  blocker.
- **Unwinds.** An error leaves every flag between the raise and the catcher
  set, which is exactly the retained frames' state. The catcher restores the
  one surviving frame, `frames[entry_depth − 1]`. A frame below that is
  either still inside its own instruction (its flag is right) or untouched.
- **Initialisation.** Every push initialises it false: the Zig struct literal
  (`interp.zig:2038`), the native emitted push (`nativegen_emit.zig:998-1020`,
  one more immediate store) and the `.S` frame write
  (`hostcall_x64.S:248-257`, new `CF_IN_FLIGHT` offset, coordinated with
  coral-marten). Frame-slot reuse goes through those pushes.

### 4.3 Suspended at a Lua call (`in_flight == false`, not innermost)

`frame.pc = p ≥ 1` is one past `C = code[p − 1]`, a call-like opcode with base
`a`. Mask: `live_in[p] ∩ [0, a)`.

Every caller slot at or above `a` is one of: the callee, a fixed argument
(copied), a surplus vararg (alias, §6.1), a result slot (overwritten by the
result copy before any read, with no safepoint between pop and copy), or a
free temporary above the call window. By the lemma, `live_in[p]` is already
stale-free. `∩ [0, a)` additionally drops slots whose current contents are not
yet the caller's values. Those are stale results that tier-0 itself would not
read, and that can differ between tiers.

If `p == 0`, or `code[p − 1]` is not call-like, the shape is unknown (§4.5).
The call-like set is the `.call` opcode and the native inline push of a
`.call`. Method calls and the generic-for iterator call both compile to
`.call` (antigravity rev 3 SF2, confirmed against `compiler.zig`). Phase 0
asserts, at each **Lua-callee push from a `.call`** (the opcode path and the
native inline push), that the caller's stored `p` has `code[p − 1] == .call`.
Other pushes (`callValue` re-entry, metamethods, `pushHostCall`) leave the
caller in flight at its own instruction, so they are not covered by that
assertion (codex rev 4 should-fix).
This fixes antigravity's rev 2 blocker 1: no `p − 1` read happens for a frame
classified by another shape, and `p == 0` cannot underflow.

### 4.4 Faulting frames under an `xpcall` handler

While a handler runs, the frames `frames[entry_depth .. faulting_depth)` stay
live underneath it. They never resume, but they are **read**:
`describeFault` reads the top faulting frame's instruction operands
(`interp.zig:1905-1930`, e.g. `regs.get(instr.b)` for an arithmetic fault).
A non-catchable fault raised inside the handler propagates with these frames
still live, to capi `guestFault → renderFault` (`capi.zig:384`, `:405`) or to
the CLI reporter. That makes rev 3's ∅ mask unsafe (codex rev 3 blocker 3): a
collection in the handler would sweep an operand the reporter then reads.

**No Vm range, no ∅ mask.** Before running the handler, `protectedCall` marks
the **topmost faulting frame** in flight, if there is one:

```zig
if (vm.depth > entry_depth) vm.frames[vm.depth - 1].in_flight = true;
const hn = vm.callValue(h, &.{errval}, results) catch |herr| { ... };
```

The mark needs no restore. Like every retained frame's flag (§4.2), it goes
away with the frame when `protectedCall` discards down to `entry_depth`. That
discard happens on every handler outcome: return, catchable fault, and (via
the outer catcher) non-catchable fault.

- **No frame to mark.** `callValue` can fail before pushing anything: an
  uncallable value, a native callee that raises, a rejected push at the
  re-entry cap (`interp.zig:2139`, `:2216`). Then `vm.depth == entry_depth`,
  and nothing is marked. That includes `entry_depth == 0` from a host-called
  `xpcall` (codex rev 4 blocker 3). The retained frames below are in their own
  shapes.
- **Fault-pc invariant** (Phase 0). A frame left as the topmost faulting frame
  has `frame.pc` naming the faulting instruction:
  - tier-0 raises: already true (step 6 stores it; `describeFault` relies on
    it);
  - a native raised: true, because the frame is in flight at its `.call`;
  - **a rejected Lua push**: not true today. The opcode path stores `pc + 1`
    before `pushFrameVararg` (`interp.zig:6410`). The native inline push is
    not affected: it checks its walls before freezing the caller's pc
    (`nativegen_emit.zig` step 3 before step 4), and declines to tier-0, which
    re-runs the call. The opcode path's early depth/capacity checks
    (`interp.zig:6383-6384`) already raise with `frame.pc` unchanged. Only a
    `pushFrameVararg` failure after the freeze is affected. Phase 0 either
    re-stores the call pc on that failure, or freezes `pc + 1` only once the
    push has succeeded (antigravity rev 5 SF2). Which of the two is an
    implementation choice. That also fixes `describeFault`/backtraces for a stack
    overflow.

  Without this, the mark would give the frame `live_in[call pc + 1]`, which
  can root a stale temporary in an unwritten result slot.
- **Top faulting frame mask.** With the invariant, the mask is
  `live_in[fault pc]`. That contains every operand `describeFault` reads, and
  by the lemma it is stale-free. Its pc is reached in tier-0, so the lemma
  needs no resumption.
- **Faulting frames below it** are each in an ordinary shape already:
  - suspended at a Lua `.call` (§4.3, flag false, pc + 1);
  - in flight inside the instruction that called the code which faulted: a
    native, a metamethod, or `callValue` re-entry. The flag is left set on
    error, and `frame.pc` is that instruction (§4.2). Codex's
    `.add` → `__add` example is this case.
- **Nesting.** A handler that runs its own `xpcall` whose handler runs marks
  its own topmost faulting frame. That frame sits above the outer one, and each
  level's frames are discarded by their own catcher. No single Vm range has to
  describe several fault regions (codex rev 3 blocker 2, antigravity rev 3
  blocker).
- **Faulting at `pc == 0`** needs no special case: the frame is in flight, so
  no `code[p − 1]` read happens.

An all-live mask would be safe, but it would root stale slots and break Goal 1
(rev 2 review: codex 5, antigravity 1).

### 4.5 Unknown shape

Mask: all live. Goal 1 still holds only if the JIT elided no store that could
leave a stale value in such a frame (§2, all five sites). Unknown shapes arise from protos without
liveness or protos failing the layout check, and both are covered by §5.
Phase 0's audit must leave no other source: every frame lands in 4.1–4.4. A
debug assert fires on any unknown classification of a `maskable` proto.

## 5. One predicate: `Proto.maskable`

Computed once at compile time and stored on the proto. It is read by the
collector and by **every JIT store-elision site** (§2):

`maskable(F)` ⇔ `F.reg_live.available()` ∧ `F` passes the **call-layout
check**.

**Call-layout check.** For every `.call` instruction `(a, b, c)` in
`F.code`. That is the only frame-pushing opcode; the native inline push is a
JIT artifact of a `.call`, so it adds no instruction of its own:
∀ `r ≥ a`: `r ∈ live_out(call)` ∧ `r ∉ captured` ⇒ `r` is a result slot.
For fixed `c`, the result slots are `a ≤ r < a + c`. For `c = all_results`,
every `r ≥ a` is a result slot. That handles the "multret kills nothing" case
from codex blocker 4.

Captured slots need no closure proof here:
- an **open** captured slot is rooted by the open-upvalue alias (§6.1);
- a **closed** one is not read through the stack, and its φ is always kept
  (§2).

**As implemented (Phase 0): a precision fix in `bc_liveness`.** As first
computed, the check failed on almost every compiled main chunk. A multret
consumer (`call`/`ret` with `b = all_results`) is modelled as reading
`R[a..num_registers)`, because its real extent, the producer's dynamic top,
is unknown at compile time. A dynamic producer (`call` with
`c = all_results`, `vararg_spread`) killed nothing. So every consumer kept
every register above its base live all the way back through the code, and
the row after an earlier fixed-`c` call carried registers above its results.
Those registers were not really live: the check was right to reject the
liveness, not the layout.

The fix uses the one shape the compiler emits: a producer is always
immediately followed by its consumer. The pair writes `R[p..top)` and then
reads `R[a'..top)`, so a register `r ≥ p` is dead before the producer
unless it survives the consumer: `r ∈ live_out(consumer) − kill(consumer)`.
A `ret` consumer has no survivors. A fixed-`c` consumer kills its results.
A consumer that is itself a producer (`f(g(h()))`) passes on what survives
its own consumer, so the computation follows the chain. The producer kills
`R[p..)` except those survivors; captured registers stay live as before.
This is exact, not a heuristic. A survivor above the dynamic top keeps its
value, and the consumer row itself still covers the whole window, so a
prologue collection there roots every result.

The producer's row reads a row past its consumer, which is not a CFG
successor. So when a row changes, the worklist also requeues the producer
two pcs before it. A producer's survivors extend those of the chained
producer above it, which is cached, so a chain costs `O(L · words)` (codex
Phase 0 should-fix). `bench/compile_multret_chain.lua` holds that: 200
compiles of a 2,000-deep chain take 0.33 s, where a per-producer chain walk
spent 0.09 s in liveness for a single 2,800-deep chain. Tests pin the
back-edge requeue and a five-deep chain. Exit snapshots (§2 site 3) read
the same rows, so they now omit these dead registers too. That is sound for
guest reads: tier-0, resuming at or before the producer, writes them or
never reads them.

**Phase 1 prerequisite: the conservative consumer row (codex Phase 0
blocker 2).** The kill above is a model kill, not a must-write. A register
`r` in `[top, num_registers)` (above the producer's actual dynamic top) is
dead before the producer but **not written** by it. It still appears in the
consumer's own row, which covers the whole window. So the path lemma's step
"`s ∈ live_in[Y]` ⇒ tier-0 wrote `s` on the way to `Y`" fails for
`Y` = a multret consumer pc. A JIT exit that elided `r` (it is dead at its
resume pc) leaves `r` stale, and a collection with the frame in flight at the
consumer roots that stale value. That happens when a native callee or a
`__call` handler of a `b = all_results` call collects. Before this change,
`r` was live back past the producer, so no site elided it.

Shapes at a consumer pc:
- innermost before the consumer runs: no collection (`reg_top_pending`
  suppresses that safepoint);
- a Lua callee pushed by the consumer: the caller is suspended at `pc + 1`,
  masked `∩ [0, a)`, so it is not affected;
- **in flight at the consumer** (native or `__call` callee): affected;
- **faulting at the consumer under `xpcall`**: affected. The call can fail
  before it enters any callee, for example on a rejected Lua push. The
  handler's `callValue` then marks the retained frame in flight at the
  consumer pc, and the handler can collect (codex Phase 0 re-review).

This is a **potential determinism divergence**, and it is unresolved. mahina
has no weak tables, `__gc` or `collectgarbage`, but object survival is still
observable. A string that survives in one tier and is freed in another
changes later re-interning allocations, and printed object ids follow from
those. Phase 0's liveness already reaches exit snapshots (above), so the
stale value can arise today under the all-live walk, the same class as the
pre-existing site-3 hole (§2). It is accepted at the Phase 0 boundary and
**must be closed in Phase 1, before masking relies on the lemma.** Options,
for decision in the Phase 1 review:
- **(A) The producer makes the kill real.** Every dynamic producer nil-fills
  `[top, base + num_registers)` after placing its results: tier-0's `.call`
  with `c = all_results`, `vararg_spread`, the return into such a caller,
  and any JIT path that completes one. Rows become exact and the lemma holds
  unchanged. The compiler would assert that no survivor `≥ p` exists, since a
  fill would clobber one; none can under stack-discipline allocation.
  Cost: up to a window of nil stores per multret call, at several sites.
- **(A′) The consumer canonicalises its stale tail.** The `.call` opcode,
  with `b = all_results`, nil-fills `[top, base + num_registers)` before
  anything that can collect or fail: before it runs a native or a `__call`
  handler, and before any check that can raise (a rejected push), so the
  faulting-consumer shape is covered too. Then the in-flight frame's rooted
  tail is nil in every tier: the consumer wrote it on the path to the
  collection, so the lemma holds with `Y` inside the consumer. This is one
  opcode, and traces never run natives or metamethods (§2 audit), so tier-0's
  opcode path is the only executor. Cost: up to a window of nil stores per
  multret call; measure it.
- **(B) The collector uses the dynamic top.** A frame in flight at a
  multret consumer is masked with `live_in[pc] ∩ ([0, top) ∪ survivors)`.
  That needs the consumer's `top` at collection time. `vm.reg_top` is
  overwritten by re-entered code, so the frame would have to record it, in
  a new `CallFrame` field or the spare bytes after `in_flight`. It must be
  recorded before anything that can fail, so the faulting-consumer shape
  keeps it. This is Lua 5.4's shape: `traversethread` marks only below
  `L->top` and clears the slice above it. No stores on the call path beyond
  the bound; one more frame field and a special case in the walk, whose
  review must cover captured aliases, survivors, nesting and retained
  faulting frames. Codex (Phase 0 re-review) recommends B for that reason:
  it records the real bound instead of clearing a window per call.

**Uses.**
- **Collector.** A frame of a non-`maskable` proto is all live.
- **φ filter (Phase 2).** A trace anchored in a non-`maskable` proto keeps
  every φ (today's behaviour). Over a `maskable` proto the filter is
  **liveness only**: `phiWritebackKept` loses its `locals_watermark` clause,
  and the recorder stops dropping temporaries by watermark (§2). The
  `readSlot` and resume-pc/`loop_done` rows of `phiLiveRow` stay as they are.
- **Exit snapshots (Phase 1).** `commitExitSnap` intersects with
  `live_in[rpc]` only when `maskable(F)`. Otherwise it records every `.def`
  slot. Today `available()` already gates snapshot creation
  (`trace_recorder.zig:1371`). The only new case is a liveness-carrying proto
  that fails the layout check. The compiler is not expected to emit one, so
  the cost is nil on real code, and a test pins the fallback. Every consumer
  reads the committed snapshot, the native exit adapter included
  (`nativegen_adapter.zig:280`), so gating at commit covers them all.
- **Composite bridges (Phase 1).** `bridgeMatchesExitSnapshot` takes its
  `live_row` from `row(landing)` only when `maskable(F)`. Otherwise it uses
  the empty row, its existing "no liveness" path, where every slot counts as
  observable. So the emission set must agree with the snapshot on every slot.
  Since the snapshot of a non-`maskable` proto is full (above), the bridge
  then writes the tier-0 state exactly, or is not admitted.
- **Linked numeric-for completion (Phase 1).** It skips `a+3` only when
  `maskable(F)` ∧ `a+3 ∉ live_in[fall-through pc]`. Otherwise it writes the
  pre-test value, or declines to the coarse deopt (§2 site 5). A for-loop
  whose control variable is captured is the case this affects on real code,
  and only when such a loop is linked.
- **Watermark (Phase 1 → Phase 2).** Until Phase 2 removes it, it drops a slot
  only if `maskable(F)` ∧ the slot is not captured in `F` (§2). Gating on
  `maskable` alone is not enough: it would still drop a captured slot that a
  later local reuses (codex rev 3 blocker 1).

So every all-live frame belongs to a proto whose traces leave no stale slots.
That is Goal 1 for §4.5.

## 6. The walk

### 6.1 Alias bitset

At collection start, a Vm-owned bitset over `[0, stack_top)` is cleared and
filled with:
- each frame's varargs span;
- each open upvalue's stack slot;
- P3's parked native callees and arguments need no bits. They sit at or above
  the innermost window's end, in a gap the walk roots whole (§6.2).

Its size is the stack slab: 65,536 bits = 8 KiB, allocated at VM init. Filling
it is O(Σ spans + open upvalues), with no sorting. That fixes the
membership-algorithm should-fix.

### 6.2 Walk

```
for each frame f in frames[0..depth]:
    mask = mask(f)                       // §4; ALL if !maskable(proto)
    for i in [f.base, f.base + nreg(f)):
        if mask[i - f.base] or alias[i]: root(i)
        else: scrub(i)                   // §6.4
root every slot in [0, stack_top) outside all windows   // gaps
```

Gaps include host argument regions, the parked `__call` region, P3's parked
native callees and arguments, P1's raised
argument tails, P2's spans, returned spans before their copy, and the depth-0
B-6 result span. Only the `.gc` kind is masked. The `.snapshot` walk keeps doc
21 Phase A's seeding.

### 6.3 Budget (Rule #20)

Per collection the walk costs:
- one bitset clear, O(stack_top / 64);
- span fills;
- one liveness row per frame;
- one or two bit tests per window slot.

That is linear, with no allocation. The new memory is the 8 KiB bitset,
fixed at init. P3's parking uses the register stack itself.

**Boundary benchmark**, run deliberately with no timing assertion in a test:
- a full 65,536-slot stack;
- 200 frames;
- maximally fragmented vararg/alias spans;
- a small heap, so the root walk dominates.

Target: within noise of today's unmasked walk at that size. Board: pinned
pt-default, with no row regressing beyond noise (`binary-trees` to watch).

**As implemented (Phase 1): `zig build bench-gcwalk`.** 200 frames
(`max_call_depth`), `stack_top` 51,942. Each frame has 170 locals, half
dead across its call, and passes 70 surplus varargs; every register holds an
integer. It times `collect` with every proto maskable and again with every
proto non-maskable (each frame whole, through the same code). A/B against
HEAD in a `just shadow` tree, interleaved, three runs each:

| build | per collection |
|---|---|
| HEAD (unmasked walk) | 8.7–9.5 µs |
| first cut, masked | 22.7–23.2 µs |
| vectorized, masked | 5.9–6.0 µs |
| vectorized, every frame whole | 3.4–3.6 µs |

The first cut walked the keep bitset one set bit at a time (`ctz`, then a
register read and a heap test) and scrubbed every dead slot on every
collection. It was 2.5× HEAD, which a register-heavy program would pay at
each collection. The fix compares each 64-register block of tag bytes at
once (`Vm.tagMask`): the walk visits only `keep ∩ heap_ref` slots, and the
scrub stores only to `dead ∩ ¬nil` slots, so a steady state scrubs almost
nothing. The masked walk is now faster than HEAD's. What remains over the
whole-frame variant is building the mask, about 12 ns per frame.

### 6.4 Scrub

A dead window slot is set to nil before the sweep.

1. **No dangling pointer survives.** A dead slot whose object is swept would
   otherwise be dereferenced by the next mid-flight `encodeSnapshot`
   (`keyframeser.zig:315-332`) or `.snapshot` walk. Invariant: *after any
   collection, no register slot points to a swept object.*
2. **Canonical dead state.** After each collection the dead slots are nil in
   every tier.
3. **Unobservable to the program.** A dead slot is written before any read on
   every path from its frame's pc. Faulting frames never resume.

**Other readers.**
- `matchesFingerprint` probes only slots live at the anchor
  (`trace_code.zig:548`).
- `bridgeMatchesExitSnapshot` gates on liveness (`trace_code.zig:781-805`),
  and on `maskable` from Phase 1 (§5).
- Exit-side snapshots materialise resume-pc liveness.
- `ret_cont` receives copied results.
- Backtraces read pcs.
- The visualiser shows registers (`viz/src/snapshot.ts:130`), so a dead local
  reads nil after a collection (Q2).

**Keyframes (P4).** Capture never happens with an in-flight frame or a live
native activation. Capture points are suspend boundaries, not re-entries.
This is **enforced, not just asserted** (codex rev 3 blocker 6):
`encodeSnapshot` (`keyframeser.zig:279`) returns an error, in every build
mode, if any frame in `frames[0..depth]` has `in_flight` set, or if
`native_reentry_depth != 0`. A host that calls the capture API from inside a
callback gets that error instead of a keyframe whose frames cannot be resumed.
So `in_flight` is not serialized, and restore initialises it to false. P1 adds
no field: restore validates ordered, non-overlapping, in-bounds windows from
the recorded bases (§3).

## 7. Q1 — trace constants (pre-existing hazard, decide before Phase 1)

A folded `tostring` result (`trace_recorder.zig:4518`) and a runtime pattern
string (`:4735`) are interned into a trace's constant pool. The pool is a
`.gc` root only when a trace exists (`interp.zig:2451`). Once such a string's
last ordinary reference dies:
- the JIT run keeps it alive;
- tier-0 sweeps it;
- re-interning it allocates in tier-0 only, so `next_obj_id` diverges.

Masking removes more ordinary roots, which makes this easier to reach. One
attempt to reproduce it on HEAD did not diverge (`/tmp/tconst.lua`).

Proto constants are not automatically permanent either. A host can release a
retained chunk (`interp.zig:2423`). What counts is an actual pin.

- **(a) Weak trace-pool references + invalidate on sweep.**
  - Pooled runtime heap values stop being `.gc` roots.
  - A sweep that would free one first invalidates every trace naming it,
    including the active recorder, dispatch/link references, native slots and
    the dependency index. Native code bakes these pointers
    (`nativegen_emit.zig:1975`), so this must finish **before** the memory is
    freed.
  - Needs batched invalidation, because per-trace retire rebuilds graph caches
    (`trace_link.zig:2379`), and a mass-retirement benchmark.
  - Keeps folding. Costs the most machinery.
- **(b) Pool only pinned values.**
  - **Every** heap-constant insertion into a trace pool requires the value's
    pin bit: folding, pattern pins, `konst` of heap values, and any other
    insertion site.
  - Unpinned values take the runtime path: `tostring` on trace, the pattern
    guarded by content instead of pool id.
  - Trace-const roots then only ever re-root pinned objects, so they become
    redundant and stop being tier-dependent.
  - Simple and sound. Loses folding for unpinned values. The runtime-path cost
    is measured on `str_*` rows.

Antigravity recommends (b) in both rev 2 and rev 3 reviews. Codex judged both
sound under the conditions stated.

**Decision (Bart, 2026-10-09): (a).** It lands as Phase Q, before Phase 1,
with its own design section and review. (a)'s conditions above are its
acceptance criteria.

### 7.1 Phase Q design (rev 3, 2026-10-10)

Rev 2 was approved by antigravity; codex returned REVISE. Rev 3 makes
these changes:
- the retirement budget is now stated as O(T + L + P + E + D) plus one
  commit-equivalent R(T); R's own superlinearity goes to TODO.md;
- the bulk entry-patch drain and slot teardown are now specified;
- the recorder's id keys are separate from tropt's pointer key, and
  `PendingStore.tab_obj` is covered;
- the exec-log history policy is new, along with a wire `id`;
- wants are cleared;
- the contract-ownership funnel is new;
- all scratch is reserved at commit.

Rev 1 was reviewed by codex and antigravity (both REVISE,
`docs/reviews/doc61/phaseQ-rev1.md`). Rev 2 makes these changes:
- the sweep predicate is now exact;
- the recording cancel no longer goes through `abort()`;
- the borrowed contract is now an owned copy;
- the recorder's dedup maps are keyed by id;
- retirement is done in one bulk pass;
- the exec-log policy is new;
- the determinism claim is narrowed to tier identity;
- the tests and benchmarks are wider.

**The hazard is live on HEAD, from plain Lua, without masking.**

```lua
local function f()
  local n = 0
  for i = 1, 2000 do local s = tostring(7) n = n + #s end
  return n
end
print(f())
for k = 1, 5000 do local junk = {} end
local again = tostring(7)
print({})
```

Tier-0 prints `table: 0x146e`; `--trace` and `--jit-native` print `0x146d`.
After `f` returns, `"7"` is reachable only from the trace pool, which the root
walk (item 5) marks, so the JIT legs never re-intern it. (The earlier
`/tmp/tconst.lua` kept the string in a dead main-frame register, which every
tier roots today. That is why it did not diverge.) This is the Phase Q test.

**Facts the design rests on.** Each was audited with file:line in the
2026-10-09 code map.

- **F1. Heap constants in trace pools are interned strings only.** They are
  appended in two places: `konst()` (`trace_recorder.zig:1783`) and
  `recCalleeGlobal` (`:5582`). The kinds are:
  - proto string literals (`load_const`);
  - read-only `internedLookup` folds: `math.type`, `type`, scalar `tostring`;
  - runtime pattern pins (`patternArgPin`, the gmatch step);
  - callee global names.

  Function identity is pinned by proto id, builtins by tag, and lanes by
  `GcHeader.id`. Optimizer folds produce only numbers and bools. Pools are
  never compacted, so a dead `konst` can leave a heap constant in the pool.
- **F2. Every heap pointer a trace bakes into native code or reads at run
  time comes from its pool,** or from a VM-permanent root (globals,
  metamethod names). Native code bakes these pointers at a lazy compile: the
  `sgmatch` pattern, the `guard_sid` expected pointer, `konst` imm64 values,
  snapshot/adapter immediates, and `resolveHashCell` keys. Tier-1a and entry
  seeding read `consts[i]` at run time. Entry seeding also reads proto
  constants, closures, upvalues and table cells (`interp.zig:1198`). Those
  are reached through the activation being entered and re-seeded on every
  entry, so nothing about them is persisted past it.
- **F3. Collection runs only at the tier-0 dispatch safepoint
  (`gcTrampoline`) or from `mh_collect`.** `mh_collect` can be called by the
  host outside any run, or by a host function called from tier-0. Neither
  path runs while a trace is on the native stack, inside tier-1a `execute`,
  or inside a replay walk:
  - traces never call host code or metamethods;
  - callouts allocate but never collect;
  - replay walks run no tier-0.
- **F4. Interned strings are already weak.** The intern table is not a root,
  and `sweep` unlinks dead strings. A string that is unreachable but not yet
  swept is still found by `internedLookup`. So a trace that hands a pooled
  string back to the guest between collections does exactly what tier-0's
  re-intern would: return the same object.

**Design.**

1. **The pools stop being `.gc` roots.** Item 5 drops the
   `registry.cache[*].code.consts` and `rec.consts` loops. The `.snapshot`
   walk already excludes them.
2. **Invalidate between mark and sweep.** `Vm.collect` becomes
   `beginCollect → roots → traceAll → invalidateDeadTraceConsts → sweep`.
   - **The predicate is the sweep's own:** `Heap.willFree(h)` =
     `h.color == .white and !h.flags.pinned` (`gc.zig:757`). That makes the
     check exact. White alone is not enough: loaded-chunk constants are
     pinned but never marked (`interp.zig:896`), so a plain white test would
     retire every trace over a `load`ed chunk on every cycle (both reviewers,
     rev 1).
   - Each cached trace whose `heap_consts` names a header that `willFree`
     accepts is marked doomed.
   - **An active recording is cancelled when either holds:**
     - `rec.consts` names a header that `willFree` accepts;
     - its `pending_link_close` borrows from a doomed trace (but see item 4:
       the borrow is removed).

     Cancellation is a new `RecordingSession.cancel(reason)` with `realAbort`
     semantics (`trace_recorder.zig:1148`). It deactivates unconditionally,
     resets the scratch and syncs `TraceState`'s recording bit. It does
     **not** go through `abort()`, because `abort()` (`:982`) can rewind an
     in-progress link peel into a `.link` close that keeps the pool (codex
     rev 1 blocker 1). The reason is `const_swept`.

   No trace or recorder pointer to a swept string survives into the sweep.
   By F2 nothing else in a trace can dangle.
3. **`heap_consts` is built from the final, complete pool.** At finalize,
   after tropt, every pool index holding a heap value goes into
   `TraceCode.heap_consts: []u32`, freed in `TraceCode.deinit`. That covers
   `konst` users, `guard_sid`/`sgmatch` operands, and `callee_global` keys,
   which have no `konst` instruction. The index type is `u32` because
   `maxrecord` is a `u32`. A "live `konst` users only" refinement is
   rejected: serializers and non-`konst` consumers read the whole pool
   (codex rev 1). The scan costs O(traces + heap constants), one colour read
   each, and replaces item 5's marking of the same headers.
4. **Remove the recorder's lifetime borrows.**
   - **`PendingLinkClose.contract` becomes an owned copy** of the inner
     root's `entry_guards` (a few entries), freed with the session. Today it
     borrows `Trace.code.entry_guards` on the premise that nothing evicts
     during recording (`trace_recorder.zig:304`), and a collection mid-peel
     now can (codex rev 1 blocker 2). With the copy, a doomed inner root
     needs no recorder action at all.
   - **The recorder's identity keys use `GcHeader.id`, not the address.**
     These are `konst_map`'s heap keys, `callee_global_dedup`,
     `upvalue_cell_classes`, `snapshot_read_cells`, and
     `PendingStore.tab_obj` (`trace_recorder.zig:378`), which is compared at
     array and hash forwarding (`:2336`, `:2429`). Codex checked each one:
     none of them needs the address to get a pointer back. The pool keeps
     the value, and the access paths re-resolve cells. Ids are monotonic and
     never reused, so address reuse after any sweep cannot alias two
     identities within one recording. Each id is captured when the entry is
     recorded, never by dereferencing a header later.
   - **The recorder gets its own id-based key; the optimizer keeps its
     pointer key.** The shared `konstKey` (`trace_ir.zig:33`) also serves
     tropt, whose test passes two distinct raw headers with id 0
     (`tropt.zig:1361`). tropt runs synchronously, with no collection inside
     it, so pointer identity stays sound there.
   - **Ownership of the contract copy** goes through a single
     `clearPendingLinkClose()` funnel, which frees the copy. Every path that
     clears `pending_link_close` today (`trace_recorder.zig:3632` and the
     others) uses it: peel close, zero-trip, rewind, cancel, reset, deinit,
     and setup failure. A leak-checked test drives each path.
   - **A side recording whose parent retires mid-recording keeps going.**
     `side_src` is an `ExitKey`, and `finishSideTraceProvenance`
     (`trace.zig:3881`) already tolerates a missing parent: the child
     commits without the provenance edge. This is a valid child, not an
     orphan hazard.
   - **Pending wants and recording requests sourced from a doomed trace are
     cleared in the bulk pass (item 5, step 3).** `side_want_src`,
     `head_want_src`, `prime_want_src`, `pending_exit_src` and
     `pending_replay_src` are carried into recordings without resolving
     their source (`trace.zig:3337`, `trace_link.zig:292`). Clearing them
     means no recording is started from a retired exit.
5. **Bulk retirement: `TraceState.removeTraces(doomed)`.** Calling
   `removeTrace` once per trace is Θ(N²) even with one graph rebuild: each
   call repeats the cache searches, `countTracesAt` and the link and
   provenance scans (codex rev 1 blocker 4). The bulk path instead:
   1. returns early on an empty set; most collections doom nothing;
   2. writes the doomed `*Trace`s into the reserved scratch list (item 6),
      sets a `doomed` bit on each, and records each anchor. The list keeps
      the pointers alive until step 6, even after the cache is compacted;
   3. **the teardown pass:**
      - one pass each over armed links (`resetLinksTouchingSet`), parked
        proofs, promoted sets and `provenance_edges` drops everything that
        touches a doomed trace;
      - one pass over the want/request maps clears the entries whose source
        is doomed (item 4);
      - slots on surviving parents are rewritten to `shared_exit` through
        the existing `commitSlotMutation` funnel, after the proofs are
        dropped, using a bulk variant of `prepareSlotMutation` that skips
        its per-mutation parked-proof rescan (`trace_native_registry.zig:610`):
        the proof pass already established that no proof touches these
        slots;

      physical teardown completes before any endpoint is freed;
   4. compacts `registry.cache` once (an order-preserving filter, not
      `swapRemove`), nulls `trace_by_id`, and marks entry patches non-live
      and pending;
   5. reopens anchors: one pass over the survivors counts traces per
      recorded doomed anchor (a hash map with reserved capacity), then the
      zero-count anchors reset their counter and coverage flag;
   6. destroys the doomed records;
   7. runs `syncNativeInvalidation` once, then `rebuildEdgeCache` and
      `rebuildRegions` once each (fail-closed to empty on OOM, as today);
   8. **a bulk entry-patch drain.** Today `drainEntryPatchWork`
      (`trace_link.zig:2534`) scans the surviving cache for every
      `unpatchSlot` and every pending install. The bulk drain keeps the
      current semantics exactly:
      - it restores every pending unpatch before any installation;
      - it installs in ascending trace-id order;
      - owner lookup goes by trace id;
      - waiter wakeup covers both capacity suppression and incumbent-slot
        suppression (`trace_entry_registry.zig:202`).

      Only the lookups change. It builds one anchor → id-sorted list of
      surviving traces (several traces can share an anchor) and an id →
      trace index, once each. `resolvePatchPc` (`trace_entry_registry.zig:105`)
      scans proto bytecode for loop anchors, so its result is cached on the
      entry patch when the patch is created. The drain then does no bytecode
      work.

      **As built: the drain runs at the next safe point, not inside the
      collection.** Step 4 leaves the doomed traces' patches non-live and
      pending; `removeTraces` does not call `drainEntryPatchWork`. An
      install moves `image_gen`, and a collection can run under a frame
      that holds a cached image pointer it cannot re-resolve there (the
      reason recorder-abort marks are already deferred). A non-live patch
      dispatched before the drain takes the §R6-1 recovery arm, which
      restores the slot synchronously and runs the original instruction, so
      the deferred state is sound. The drain itself is one pass over the
      entry patches and one over the cache: restores first, owners unbound
      by id (`EntryPatch.owner_retired` skips retired owners), waiters
      woken in the same cache pass, installs sorted by id from
      `batch_scratch`. It needs no anchor index, because each install
      touches only its own trace and the image check for an incumbent is
      O(1).

   **Budget.** Steps 1–6 and 8 are O(T + L + P + E + D + X), where T is
   surviving traces, L armed links, P parked proofs and promoted-set
   members, E provenance edges and wants, D doomed traces, and X entry-patch
   records plus the dropped logs' events and string bytes. Step 7 is
   **one** run of the existing graph rebuild, R(T). Today every trace commit
   already pays R(T) (`trace.zig:4028`). So a non-empty collection costs at
   most one commit-equivalent rebuild, whatever D is, and an empty one costs
   nothing.

   R(T) itself is superlinear (codex rev 2):
   - `topologyView` calls `hasInnerRootAt` per trace, which is a cache scan
     (`trace_link.zig:832`), and successor resolution scans again (`:889`);
   - `buildEdges` matches exit facts pairwise (`trace_region_topology.zig:59`);
   - region construction rescans edges per component and in its liveness
     propagation (`trace_region_topology_build.zig:213`, `:297`, `:755`).

   That cost is a pre-existing property of the commit path. Phase Q reuses
   the existing rebuild algorithm once per non-empty batch: a new call site,
   but without the per-doomed-trace multiplier. Usable performance is still
   established by measurement before landing (Rule #20): total collection
   latency, and repeated retirement/re-recording churn. An unacceptable
   result means more work before Phase Q lands. It is tracked as its own item
   (TODO.md: indexed trace/anchor lookup, direct exit-fact matching,
   component-local adjacency). The benchmark reports R separately, so its
   scaling stays visible.

   No guest or trace code runs inside the transaction (F3), so nothing reads
   a half-torn graph. `removeTrace(t)` becomes the one-element case. The
   widen-eviction loops (`interp.zig` ~4385/5191/5482) move to the bulk call.

   `registry.retire` already panics inside a replay walk. By F3 that cannot
   happen at a collection, and `invalidateDeadTraceConsts` asserts it
   anyway. The pending arm requests resolve through `traceById` and drop
   themselves when it returns null (`trace.zig:1917`,
   `trace_regionops.zig:824`). Wants and recording requests are cleared in
   step 3, because they don't resolve. Active side recordings continue
   (item 4). Entry patches
   clear `live` before destruction, and the patched handlers recover through
   the non-live path (`trace_entry_registry.zig:180`). `EntryPatch.trace` is
   poisoned on retire.
6. **Collection never allocates for the doomed set.** All bulk scratch is
   reserved at commit time, which already allocates: the doomed-pointer
   list, the anchor list, and the anchor-count map, with capacity ≥
   `registry.cache.len`. That includes the bulk drain's anchor index. A
   commit that cannot reserve fails like any other commit OOM, before the
   trace is published.
   Graph rebuilds keep their existing fail-closed OOM behaviour. The OOM rule
   is unchanged: `beginCollect` can still skip a cycle before anything is
   coloured.
7. **Execution logs stop borrowing and stop using cache indices.** Today
   `ExecLogRecorder.value()` keeps raw string `Value`s
   (`execlog.zig:160`), which `execlogser` dereferences later (the WASM
   visualiser path, `wasm_entry.zig:662`). The logs are also keyed by cache
   index (`traceIndex`, `trace.zig:2529`), which any `swapRemove` reshuffles.
   Both are pre-existing, since widen-eviction already retires, but pool
   weakness makes the first one reachable for previously protected
   constants (codex rev 1 blocker 3). The policy:
   - **Owned bytes.** Every string a log keeps copies its bytes at log time:
     `value`, `guardPass` and `exit` events (`execlog.zig:160`). A
     successful append transfers the bytes into the completed log, whose
     deinit and reset free them. Abandoned scratch and events free their
     own bytes. On either failure, the byte copy or the event-array append,
     the event is dropped and nothing leaks. The logs are only on when
     instrumented.
   - **Stable identity.** Logs key on `Trace.id`. The trace wire schema
     (`schema/trace.json`, `traceser.encodeFile`) gains an `id` field, and
     the visualiser joins logs to trace records by id instead of by
     position.
   - **History.** A retired trace's log is dropped in the bulk pass (step
     3). WASM emits only surviving trace records (`wasm_entry.zig:658`), so
     an orphaned log could never be shown, and keeping a retired trace's
     artifact would need owned pool bytes for no consumer today. Archiving
     retired traces is a possible visualiser feature for later, not a
     Phase Q requirement.
   - Re-rooting log strings is rejected, because it would bring back
     tier-dependent liveness.
8. **Determinism.** Collection points and colours are tier-identical, because
   guest allocation is. So the set of objects freed is now identical in every
   tier, which is the point. Invalidation affects only JIT state (which
   traces exist and which anchors re-record), which is outside every
   determinism contract. Retiring a trace is a cache decision like the
   existing widen-eviction. **The claim is tier identity only.** Replay
   across a keyframe cut taken between "a string became unreachable" and
   "the sweep freed it" is not established. The snapshot omits the
   unreachable-but-unswept string, so after restore a re-intern allocates
   where the uninterrupted run gets an intern hit (codex rev 1 blocker 5).
   That happens in tier-0 alone and predates Phase Q. It is tracked
   separately (TODO.md, with options) and is not a Phase Q acceptance
   criterion.

**Costs.**
- One colour read per heap constant per collection, replacing the marks.
- Retirement churn when a pooled string dies. A pattern string rebuilt per
  outer iteration retires and re-records its loop's trace. Tier-0 pays the
  same re-intern, so this is a tiering cost, not a semantic one.
- A heap constant left in the pool by a dead `konst` still dooms its trace.
  That is conservative, not unsound (item 3).

**Benchmarks (Rule #20).** `collectgarbage` is not implemented, so the
mass-retirement benchmark is a release-only Zig benchmark driven through
`mh_collect`/`Vm.collect`, following the `bench_topology.zig` pattern and
run deliberately, never in the gate. It builds the traces through the
embedding API, then times only the collection. It covers:
- N ∈ {250, 1000, 4000} traces, each over its own runtime-built pattern;
- all doomed, versus 10% doomed with 90% surviving. The 10% case keeps the
  large surviving cache that exposes R(T);
- plain caches, versus caches with armed links, promoted sets and parked
  proofs;
- many distinct anchors, many small cyclic components, many exits per
  trace, long sibling chains, and many entry patches.

It reports total collection latency, plus the retirement steps (1–6 and 8)
and R(T) each timed separately. A repeated sparse retirement against a large
surviving cache measures churn. R is compared with a commit's rebuild on an
equivalent graph: the same traces, exits, cyclic components, sibling
relations and persistent region state, not merely the same T.

Structural counts are asserted in tests, not timed: retirements = doomed,
graph rebuilds = 1 per non-empty collection, 0 per empty one, and per-step
scan and lookup counters stay ≤ c·(T + L + P + E + D). Budgets:
- the retirement steps grow linearly: a 4× size step stays within 4× ±25%
  time;
- a non-empty collection's R(T) is within noise of one commit's rebuild at
  the same T.

The `str_*` board rows must not regress beyond noise (pins and folds still
apply while their strings live).

**Tests.**
- The program above, as a 10-leg `expectProgram` differential (identical
  printed ids). It is mutation-checked: re-adding the item-5 pool roots must
  fail it.
- A pattern-pin variant (`string.find` with a pattern built per call that
  dies between calls), and a gmatch variant.
- **Pinned survival:** a trace over a `load`ed chunk's string constant
  survives many collections. Mutation: a white-only predicate must fail it.
- A shared constant across two traces dooms both. A non-`konst` dependency
  (a `callee_global` key) dooms its trace. With partial retirement, the
  survivors are untouched.
- **Recorder:**
  - a collection that sweeps a recording's const cancels it with
    `const_swept`, including with `pending_link_close` active mid-peel;
  - a collection mid-peel that dooms the inner root leaves the peel valid,
    because the contract is owned;
  - id-keyed dedup maps and `PendingStore.tab_obj`: a sweep followed by
    address reuse within one recording does not merge identities;
  - tropt's pointer `konstKey` still keeps equal-id distinct headers apart
    (`tropt.zig:1361`);
  - every `clearPendingLinkClose` path frees the owned contract (the leak
    checker).
- **Side recording:** the parent retires mid-recording, the child commits
  without its provenance edge, and pending arms or wants naming the parent
  drop cleanly.
- **`mh_collect`** from a host callback, and from a callback's nested Lua
  run, dooms a patched trace. Re-entry through the patched loop recovers via
  the non-live path.
- **Bulk retirement:** after a mass invalidation, every surviving trace's
  slot that targeted a doomed trace points at `shared_exit`, `trace_by_id`
  is null, and the graph caches equal a fresh rebuild. An OOM injected into
  the rebuild fails closed to empty.
- **Exec logs:** serialization after a sweep, after retirement, and after a
  re-record reads owned bytes for all three string-bearing event kinds. It
  joins logs to records by `Trace.id`, and drops a retired trace's log.
- **Bulk drain and teardown:** with partial retirement over many entry
  patches and many surviving parked proofs, the per-step counters stay
  linear. Surviving proofs are intact right after the bulk teardown,
  before R runs. After R, the existing rebuild behaviour holds: R drops all
  parked proofs and demotes promoted sets (`trace_native_registry.zig:595`).
  The drain restores every unpatch before installing, installs in id order,
  and handles several traces per anchor.
- **Retired wants:** a want or recording request whose source exit was
  retired is cleared, and no recording starts from it.
- **Lazy compile after a sweep:** a committed but uncompiled trace whose
  constant died is retired before `nativeFor` can bake the pointer.

**Out of scope, noted (TODO.md).**
- `releaseChunk` (`interp.zig:871`) leaves traces anchored in the released
  protos, with raw `anchor.proto` pointers, until the next epoch. This is a
  separate dangling hazard, with no production caller of `retainChunk`
  today. It can use `removeTraces`.
- The keyframe/unswept-intern replay gap (item 8).

## 8. Tests (pinned before the code they cover lands)

- **Phase P.**
  - P1's program, as a three-mode differential, including a native-pushed
    variant and a `callValue` variant.
  - Keyframe capture/restore across a P1 gap.
  - P2: a native consuming an `all_results` span past the window calls
    `mh_collect`, then re-enters.
  - P2 failure path: the same native raises after its re-entry; `pcall`
    catches; `stack_top` is back at the boundary and the span is not rooted
    afterwards.
  - P3: a native `gsub` replacement calls `mh_collect`; a callback rewrites an
    operand register through an upvalue while a native holds the old value;
    a `__index`/`__newindex`/`__eq` metamethod collects while the interpreter
    holds its key and receiver; `stack_top` is back at the boundary after an
    error unwinds through a parked call. As implemented: the fused
    `a[i][j]` get and set with a native `__index`/`__newindex`, their error
    path, and a host `__index` that drops the last reference to itself and
    collects mid-call.
  - P4: `encodeSnapshot` from inside a host callback (frame in flight) returns
    the error in a **ReleaseFast** test build too.
- **Frame shapes** (constructed VMs):
  - innermost at a prologue GC;
  - caller at a fixed-result call, and at a multret call (stale result tail
    masked);
  - in flight under a metamethod, `pcall`, a native from `call`, and
    same-frame nesting, including a GC **between** two `callValue`s of one
    `table.sort` and after `require`'s loader returns;
  - an erroring re-entry unwound by `pcall` (flag restored);
  - an `xpcall` handler collecting over faulting frames, with the fault at
    `pc == 0` and at `pc > 0` where `code[pc − 1]` is a call;
  - **nested `xpcall`**: a handler runs its own `xpcall` whose handler
    collects; both levels' faulting operands survive, and both flags are
    restored afterwards;
  - **handler-side reporting**: an arithmetic fault whose operand is a fresh
    heap object only referenced by that register; the handler collects and
    then raises non-catchably; capi `renderFault` reports the operand's type
    correctly (and, in debug, the use-after-free net stays quiet);
  - `pushHostCall`: the caller is in flight and the pushed callee is not;
  - **retained in-flight parent**: protected function → `.add` → Lua `__add`
    faults → a collecting `xpcall` handler. The parent is in flight at `.add`,
    its operands survive, and a slot dead at `.add` is scrubbed. Also with a
    `.call` placed just before the `.add`, so a misclassification would show;
  - **nothing to mark**: a host-called `xpcall` (`entry_depth == 0`) of an
    uncallable value and of a native that raises, with a collecting handler;
  - **rejected push**: stack overflow under a collecting `xpcall` handler. The
    top frame's pc names the `.call`, and `describeFault` reports it;
  - **catcher restore**: a host `mh_call` into a VM suspended between
    instructions faults. Afterwards the top frame's flag is back to its entry
    value, and a later collection classifies it as §4.1;
  - `.S` and native frame reuse (fields initialised);
  - `mh_collect` from a host callback (`callHostNative`, `interp.zig:2208`);
  - a host-entered callee with an argument region;
  - the parked `__call` region;
  - the depth-0 result span;
  - a non-`maskable` proto (all live, and its traces keep every φ);
  - **captured slot above the watermark**: a numeric-for body whose register
    `>= base+4` is reused by a captured local; the trace keeps its φ, and a
    collection in every mode roots the same value.
- **Alias spans.** Surplus varargs survive a collection while the callee runs;
  an open upvalue's slot survives.
- **Behaviour.**
  - An object whose only reference is a dead register is freed at the next
    collection (`gc_stress`), and the slot reads nil afterwards.
  - Objects in live registers, alias spans, transient roots and in-flight
    operands survive.
- **Determinism** (three modes, also under `gc_stress`):
  - `/tmp/gcphi_new.lua`;
  - a `while` temporary;
  - a generic-for body;
  - a slot holding a table before the loop and a number inside it;
  - **materialised exit with a dead heap definition**: a loop body defines a
    fresh heap value in a temporary, then exits at a guard where the
    temporary is dead, then collects and re-interns that value. Run three
    variants:
    - a **wanted** exit resuming into tier-0 without a child;
    - an **attached** exit (side trace or sibling);
    - a **composite bridge** whose emission set differs from the snapshot on
      the dead slot (the shapes of `trace_fingerprint_test.zig:493-513`).

    These are the site-3/site-4 holes (§2). Run each on HEAD first and record
    whether it diverges; each must agree after Phase 1. Also run each against
    a non-`maskable` proto (test-constructed): there the snapshot keeps the
    slot, and the mismatching bridge is not admitted;
  - **linked numeric-for completion with a heap loop variable**: a linked
    `for i = 1, n do ... i = tostring(i) end`, run in three variants:
    - plain, where `a+3` is dead after the loop;
    - with `a+3` captured, via a **constructed** captured-slot proto/trace.
      Closure creation aborts recording today (`trace_recorder.zig:1704`), so
      a Lua-level closure in the body would make the case vacuous. The test
      asserts that the completion actually links, or deliberately declines
      under option (ii), so the gate is exercised (codex rev 7 should-fix);
    - in a non-`maskable` proto.

    In each, collect after the loop and re-intern the string. All modes must
    agree, and the HEAD result is recorded first;
  - collections from a metamethod and from `mh_collect`;
  - collect → snapshot → restore → linked execution.
  coral-marten's hostcall differential tests (every register dumped, under GC
  stress, off/record/replay) cover the host-entry layouts.
- **Use-after-free net.** Under `gc_stress` in debug, the sweep records freed
  addresses in a set. After each collection a walk checks that no register
  slot holds one, without dereferencing a freed header.
- **Mutations** (each must fail a test):
  - stale `frame.pc` for the innermost frame;
  - no `∩ [0, a)`;
  - no varargs alias;
  - no open-upvalue alias;
  - no scrub;
  - `in_flight` never set;
  - unconditional clear instead of restore;
  - `in_flight` not initialised by the native push;
  - not initialised by the `.S`;
  - faulting frames all-live (the determinism test must catch it);
  - faulting frames classified as call-suspended;
  - top faulting frame not marked in flight (handler-side reporting test);
  - `in_flight` restored by `defer` on error (retained in-flight parent
    test);
  - catcher not restoring `frames[entry_depth − 1]` (catcher restore test);
  - `protectedCall` marking without the `depth > entry_depth` check (nothing
    to mark test);
  - rejected push without the pc re-store (rejected push test);
  - exit-snapshot sparsity not gated on `maskable` (materialised-exit test,
    non-maskable variant);
  - bridge admission not gated on `maskable` (bridge variant, non-maskable);
  - `a+3` skipped unconditionally (linked completion test, captured and
    non-maskable variants);
  - `a+3` flushed from the terminal φ instead of the pre-test value (same
    test: it would expose the next index);
  - the capi entry flag captured inside `guestFault` instead of at entry
    (catcher restore test, via `mh_call`);
  - `pushHostCall` marking the callee in flight;
  - `maskable` ignored by the φ filter;
  - watermark ignoring captured slots (Phase 1);
  - P2's `stack_top` raise dropped;
  - P2's raise restored by `defer` (the failure-path test sees the span
    unrooted while frames are still live);
  - P3's parking dropped. Run: without the args park the fused repros panic
    (a pre-P3 build); without the callee park the self-drop test fails;
  - P3's restore moved into a `defer` (the error-path test then sees the
    parked region unrooted while frames are still live);
  - P4's check compiled only in debug.

## 9. Observable changes

- **Collection timing.** Collections move: fewer dead objects survive. That
  shifts `next_obj_id`, printed ids and post-re-intern `pairs` order,
  identically in all tiers.
- **hashgate.** Each affected program is first confirmed to agree across all
  three modes on both builds. Then its references are regenerated, into a
  scratch `--refs` and merged by hand, because `--generate --filter` rewrites
  the whole file.
- **Memory.** `mh_mem_stats` live bytes drop, minus the fixed 8 KiB bitset
  per VM.

## 10. Open questions

- **Q1.** Trace constants (§7). **Decided: (a)** (Bart, 2026-10-09).
- **Q2.** The visualiser shows dead locals as nil after a collection.
  **Decided: label dead slots** (Bart, 2026-10-09), as Phase V.
- **Q3.** Completeness, for reviewers:
  - a live value outside every frame mask, alias span, gap and transient root;
  - a stale value inside a mask;
  - a missing `in_flight` site;
  - a frame that lands in no §4 shape.

## Revision history

- **Rev 1** (`93da3a3`). Overlapping call windows with innermost ownership.
- **Rev 2** (`2235f3d`). Disjoint windows, alias spans (varargs, open
  upvalues, `dyn_hi`), a set/clear `in_flight` flag, a static layout check,
  and the trace-const hazard raised.
- **Rev 3** (`b4abe70`). Folds the rev 2 reviews (codex REVISE, antigravity
  REVISE):
  - **Stale-value theorem** (§2, path lemma). Rooting must be tier-identical,
    not just conservative.
  - **`Proto.maskable` shared by collector and φ filter**, so every all-live
    fallback coincides with a no-dropped-φ proto. It also gates the existing
    watermark.
  - **Faulting frames** get their own shape with an empty mask, instead of
    being misclassified as gaps or calls (`p == 0` underflow fixed).
  - **`in_flight` uses save/restore**, held for a native's whole duration.
  - **`dyn_hi` withdrawn.** It is replaced by P2's `stack_top` raise.
  - **Pre-existing rooting bugs separated out as Phase P:**
    - P1 vararg clobber, confirmed in every tier;
    - P2 dynamic spans above `stack_top`;
    - P3 native-held transients.
  - **Layout check redefined** for multret and captured slots.
  - **Alias membership** becomes a linear bitset.
  - **Q1 options specified** with their full lifetime/cost conditions.
  - **Keyframe interaction stated.**
  - **Tests and mutations broadened** per both reviews.
- **Rev 4** (`ede6e83`). Folds the rev 3 reviews (codex REVISE, antigravity
  REVISE):
  - **Watermark retired** in Phase 2. In the meantime it is gated on
    `maskable` ∧ not captured. Gating on `maskable` alone still dropped a
    captured slot (§2, §5).
  - **Faulting frames:** the ∅ mask and the Vm fault range are withdrawn.
    `protectedCall` marks the topmost faulting frame in flight with
    save/restore. That keeps `describeFault`'s operands and nests across
    `xpcall` levels (§4.4).
  - **P2:** who restores `stack_top` on success, failure, rejected push and
    non-catchable propagation is now spelled out.
  - **P3:** the audit covers every re-entry boundary, the interpreter's
    metamethod paths included, with a balanced pop on every exit.
  - **P4 added:** keyframe capture is rejected in release builds too.
  - **P1 scoped** to the `.call` path and the native push. Restore validates
    windows from the recorded bases.
  - **Call-like set** reduced to `.call`; `pushHostCall`'s callee starts not
    in flight.
  - **Tests and mutations** added for each of the above.
- **Rev 7** (this; approved by both). Folds the rev 6 reviews (codex REVISE,
  antigravity APPROVE). The rev 7 reviews' should-fixes (a non-vacuous
  captured-slot test, and the option (ii) hook) are folded in place:
  - **Linked numeric-for completion is the fifth elision site** (§2). Its
    `a+3` skip is gated on `maskable` and on a dead `a+3`. Otherwise it writes
    the pre-test value or declines to the coarse deopt (§5).
  - **The audited non-sites are listed** with their reasons (§2).
  - **§6.4 line references corrected.**
  - **Tests and mutations** added.
- **Rev 6** (`c3940ed`). Folds the rev 5 reviews (codex REVISE, antigravity
  APPROVE):
  - **Composite bridges are the fourth elision site** (§2). Admission is
    gated on `maskable`; the "no liveness" all-slots path is used otherwise
    (§5).
  - **Materialisation corrected:** snapshots are materialised for wanted
    exits as well as attached ones (§2).
  - **Catchers capture the `in_flight` flag at entry**, and capi passes it
    into `guestFault` (§4.2).
  - **Fault-pc fix options named;** the early depth/capacity checks are
    already correct (§4.4).
  - **The native adapter's snapshot consumer** is covered by gating at commit
    (§5).
  - **Tests and mutations** added for each of the above.
- **Rev 5** (`3181db2`). Folds the rev 4 reviews (codex REVISE, antigravity
  APPROVE):
  - **`in_flight` is left set on error**, not restored by `defer`, because
    retained frames are frozen mid-instruction. The catcher restores the one
    surviving frame (§4.2). This fixes the `.add` → `__add` retained parent.
  - **Exit snapshots are the third elision site** (§2). Their sparsity is
    gated on `maskable` (§5), and the premise and audit now cover every elided
    store.
  - **`protectedCall` marks only when `depth > entry_depth`.** The mark needs
    no restore, and a rejected Lua push re-stores the call pc (fault-pc
    invariant, §4.4).
  - **P2:** the new success-side lowering site and the actual reset owners
    are named.
  - **Smaller fixes:** the push assertion is scoped to Lua-callee `.call`
    pushes; backtrace correction moved into Phase 0; `callValue` marks only
    when `depth > 0`; the call-layout check reads `.call` in `F.code`; the
    stale "not faulting" is gone from the §4.3 heading.
  - **Tests and mutations** added for each of the above.

## References

- Codex: Phase 2 filter review (GC counterexample),
  01a10917-bc12-70f1-a55e-d09ea59b082c.
- Codex: rev 1 tradeoff, 01a1094b-d759-7ab2-b076-f51a6be6f10c.
- Codex: rev 2 review, 01a1095f-23da-71a1-8b68-36b2e40d2012.
- Antigravity: rev 2 review (REVISE), 2026-10-05.
- Codex: rev 3 review, 01a1096c-37fe-77f0-8e3f-441ba5942d46.
- Antigravity: rev 3 review (REVISE), 2026-10-05.
- Codex: rev 4 review, 01a10978-f8f4-7670-8baf-b5a666842ac2.
- Antigravity: rev 4 review (APPROVE), 2026-10-05.
- Codex: rev 5 review, 01a10986-6a30-78a0-89ac-947d9635c5c3.
- Antigravity: rev 5 review (APPROVE), 2026-10-05.
- Codex: rev 6 review, 01a10990-6d32-7713-a99e-9edfaa912e5a.
- Antigravity: rev 6 review (APPROVE), 2026-10-05.
- Codex: rev 7 review (APPROVE), 01a1099b-a20b-7f43-b7be-307bb52247c5.
- Antigravity: rev 7 review (APPROVE), 2026-10-05.
- Review receipts: `docs/reviews/doc61/`.
- Doc 21 (canonical snapshot liveness; Phase B deferred).
- Doc 24 D3/D8 (full-write-set flush).
- Doc 03 (root set).
- Doc 56 §4.2 (`Proto.reg_live`).
- LuaJIT: `snap_usedef` (lj_snap.c:208), `gc_traverse_thread` (lj_gc.c),
  vararg frame layout (`BC_IFUNCV`).
