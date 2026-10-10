CHANGES REQUESTED

### 1. [blocker] Loop-done exits violate execute-once (H1) or prevent loop tracing entirely
- **Evidence**:
  1. In `src/trace_exit_attach.zig:351`, `classifyWith` explicitly refuses loop-done guards:
     ```zig
     if (gp.role == .loop_done or code.isNumericForLoopDoneGuard(idx))
         return .{ .refused = .loop_done };
     ```
     `docs/design/56-exit-started-side-traces.md:738` confirms loop-done exits are not attachable. Under §5.1 ("Every guard the recorder will emit after the call in the same iteration must be attachable..."), the recorder will abort at `for_loop` with `host_barrier` on every numeric `for` loop, including the motivating benchmark in §1.
  2. If that check is bypassed, an unlinked numeric `for` loop-done exit deopts to tier-0 at the loop anchor with registers untouched (`src/irinterp.zig:78-80`, `src/interp.zig:5126`). Tier-0 then re-runs the final iteration from the anchor (`src/interp.zig:4985-4987`), invoking the host function a second time on the final iteration.
- **Suggested Fix**:
  Extend the exit adapter machinery so numeric `for` loop-done exits can take a resume-coherent exit that commits the final iteration and resumes tier-0 at the post-loop PC (`for_loop_pc + 1`) without replay, or emit an explicit loop-done commit sequence before exiting.

---

### 2. [blocker] Sibling handoff and `.ordinary_guard` patching can re-run host calls
- **Evidence**:
  - Sibling handoffs (`ArmKind.sibling_handoff`, doc 17 Part S) and `.ordinary_guard` arms jump to same-anchor sibling entries or ramps and re-run the iteration natively (`RULE[/home/bart/Projects/lune/AGENTS.md]`, `src/trace_link.zig:1174-1186`).
  - `TraceState.siblingHandoffEligible` (`src/trace.zig:1793`) relies on `exitIsPreEffect`, which checks `!trace_ir.isStateEffectOp(op)` (`src/trace_ir.zig:872-877`). Doc 63 defines `call_host` as an IR op but does not add it to `trace_ir.isStateEffectOp`. Without this, post-call guards appear pre-effect and can be armed as sibling handoffs, re-running the host call.
  - Furthermore, `validateArmKind` for `.ordinary_guard` (`src/trace_link.zig:2037-2045`) does not check `exitIsPreEffect` at all.
- **Suggested Fix**:
  1. Explicitly require `call_host` to be added to `trace_ir.isStateEffectOp`.
  2. Specify that exit slots after `call_host` can never be armed with `ArmKind.sibling_handoff` or `ArmKind.ordinary_guard` (only `.exit_side` / continuation links).

---

### 3. [blocker] Leaf host functions (§5.9) read uninitialized arguments and corrupt error exits
- **Evidence**:
  - §5.9 states: "For a leaf the trace skips §5.2's flush and the epoch guard and calls through the same shim."
  - §5.3 step 3 states: "[the shim] gathers the arguments from the slab, calls `Vm.callHostNative`...".
  - If §5.2's flush is skipped, carried slots and SSA values held in machine registers or spill slots are never written to the register slab. The shim will read stale or uninitialized memory from `regs[a + 1 ..]`.
  - Furthermore, §5.7 relies on §5.2 having materialized state before an error exit. If a leaf call raises an error via `mh_error_set`, the catching `pcall` sees un-materialized registers.
- **Suggested Fix**:
  Require leaf calls to either:
  1. Materialize operand slots to the slab before calling the shim, or
  2. Lower directly to C-ABI argument registers (`rdi`, `rsi`, `xmm0`...) in native code, and run a materializer on error return before raising into `pcall`.

---

### 4. [blocker] In-flight frame PC in §5.2 breaks GC liveness masking
- **Evidence**:
  - Doc 63 §5.2 states: `frames[depth-1].pc = B + 1`, `frames[depth-1].in_flight = true` (doc 61 §4.2).
  - This contradicts `docs/design/61-gc-liveness-masking.md:622`:
    > "The frame is inside instruction `P = frame.pc`, which is running other code. Mask: `live_in[P]`, which contains every operand of `P`."
  - And in `src/interp.zig:2509`, an `in_flight` frame uses `shape.pc = f.pc`.
  - Setting `frame.pc = B + 1` with `in_flight = true` causes GC to mask roots using `live_in[B + 1]`. Any operand whose last use was at instruction `B` (such as the host call's arguments) is dead in `live_in[B + 1]`. If the callback triggers a GC, those argument objects will be swept while the host callback is actively reading them.
- **Suggested Fix**:
  Write `frames[depth - 1].pc = B` (the call instruction itself, matching doc 61 §4.2), not `B + 1`.

---

### 5. [should-fix] `mh_table_get` can execute guest code and is misclassified as non-bumping
- **Evidence**:
  - Doc 63 §5.4 lists `mh_table_get` under operations that do not bump `host_epoch` because "they change nothing a trace can observe".
  - In `src/capi.zig:1268-1272`, `mh_table_get` calls `box.vm.indexGet(tv, kv)`, which is metamethod-aware and executes guest code on `__index`. An `__index` function can mutate globals, tables, or upvalues.
- **Suggested Fix**:
  Rule that `host_epoch` is incremented whenever guest execution is entered (e.g. inside `callValue`/metamethod dispatch), ensuring any metamethod fired during `mh_table_get` bumps the epoch; remove `mh_table_get` from the blanket non-bumping list.

---

### 6. [should-fix] Nested native episodes clobber `TraceState` and `NativeSeedCtx`
- **Evidence**:
  - In §5.3 step 1, the shim saves episode state on the stack.
  - However, `NativeSeedCtx` (`src/trace_code.zig:249-354`) contains `episode_gen`, `touched_len`, and `touched: [TOUCHED_CAP]usize`. When a nested episode runs, `prepareNativeEpisode` (`src/interp.zig:1511-1519`) bumps `episode_gen` and clears `touched_len`, invalidating row-free hit tracking for the outer trace.
  - Additionally, `TraceState.ledger_scratch` (`src/trace.zig:1506`) is a single per-VM buffer `[LEDGER_CAP]LedgerEntry` shared by all native entries (`src/interp.zig:4371`). A nested native episode overwrites this scratch buffer.
- **Suggested Fix**:
  Explicitly forbid nested native compilation/entry during re-entrant host calls (forcing nested guest execution to stay in tier-0 while `native_reentry_depth > 0`), or preserve the full `NativeSeedCtx` struct and provide an isolated ledger buffer.

---

### 7. [should-fix] The 200-instruction performance budget is unrealistic for 8 live locals
- **Evidence**:
  - Fixed costs per iteration:
    - Host call (`cHostCall` + C function): ~80 instructions (§1).
    - `emitCalloutSave` + `emitCalloutRestore` (`src/nativegen_emit.zig:1521-1560`): unconditionally saves/restores 14 XMM registers and 4 GPRs = 42 instructions.
    - Fixed subtotal: 122 instructions before shim or trace logic.
  - For 8 live locals:
    - Pre-call flush (§5.2): 16 stores (tag + payload) + frame updates = ~25–30 instructions.
    - Shim overhead (§5.3): save/restore episode state (9+ fields), argument gathering, result writing, epoch check = ~45–55 instructions.
    - Post-call reload, type check, loop arithmetic, back-edge: ~15 instructions.
  - Total for 8 locals is ~210–230 instructions.
- **Suggested Fix**:
  Split the budget in §8: ≤200 instructions for the minimal 1-local loop, and ≤240 instructions for a loop with 8 live locals (or update `nativegen_emit` to save only live caller-saved registers instead of all 14 XMM lanes).

---

### 8. [nit] Missing IR representation and snapshot definition for the epoch guard
- **Evidence**:
  - §5.4 states the epoch guard compares `host_epoch` and takes a resume-coherent exit at `B + 1`, but §5.1 does not specify whether this is lowered as a distinct IR guard (e.g. `guard_epoch`) or part of `call_host`, nor how its exit snapshot at `B + 1` is constructed.
- **Suggested Fix**:
  Define the IR op for the epoch check in §5.1 and specify its snapshot construction at bytecode `B + 1`.
