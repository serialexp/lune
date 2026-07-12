# CURRENT_TASK — Exit-branch patching (faithful LuaJIT port), doc 17

## Status 2026-07-12

- **Increment 1 (P-D, shared mcode arena): LANDED** — commit `a970da4`.
- **Increment 2.1 (P-A, frameless chain-entry ABI): LANDED** — commit `3f46d5e`.
  Frameless trampoline + frameless bodies; all exits pinned to `shared_exit`.
- **Increment 2.2 (P-B, chain-wide result contract): LANDED** — commit `1f39d8a`.
  Stable `Trace.id` + `NativeResult.final_trace_id` baked at every native exit +
  `traceById` dispatcher resolve/assert. No linking yet; every exit bakes its own
  `ct.id`, so `final == ct` and behaviour is byte-identical.
- **Increment 2.3a (indirect exit + link-slot table + P-E registry): LANDED
  (uncommitted at time of writing this note — commit next).** Indirect
  `jmp qword [&slot]` exit; per-trace heap-owned `slots: []usize` defaulting to
  `shared_exit`; inert P-E backlink registry (`armed_links` +
  `armNativeLink`/`resetLinksTouching`, reset before `destroy`). Nothing arms a
  slot, so `armed_links` stays empty and `final == ct` still holds — byte-identical.
- **Increment 2.3b+ : DESIGNED + PEER-REVIEWED + DECIDED** — see
  `docs/design/17-exit-branch-patching.md` (Done/Outstanding) and the plan file.

## What 2.2 changed (the chain-wide result contract, P-B)

Files: `src/irinterp.zig`, `src/trace.zig`, `src/nativegen.zig`, `src/interp.zig`.

- **`irinterp.zig`**: `pub const NO_TRACE_ID: u32 = maxInt(u32)` sentinel;
  `ExecResult` gains `final_trace_id: u32 = NO_TRACE_ID` (**defaulted** → the ~40
  tier-1a `ExecResult{…}` sites are untouched, zero churn).
- **`trace.zig`**: `Trace.id: u32` (stable, monotonic, never reused — the cache
  index is `swapRemove`'d so it can't be a baked constant); `TraceState.next_trace_id`
  bumped + assigned at finalize; `traceById(id)` resolver.
- **`nativegen.zig`**: `NativeResult.final_trace_id: u32`; `emitReturn` takes a
  `trace_id` param and bakes it via `movMemImm32(.rdx, @offsetOf(NativeResult,
  "final_trace_id"), trace_id)` before teardown/jump (rdx = `*NativeResult` at every
  exit); the 4 `lower` call sites pass `t.id`; `runWithLinkedLoopDone` inits and
  marshals the field.
- **`interp.zig`**: dispatcher resolves `final = traceById(result.final_trace_id)
  orelse ct` and `if (ran_native) assert(final == ct)` — validates the full baked-id
  round-trip while staying byte-identical (consumers still route through `ct`; 2.3
  switches them to `final`).

### Verification done for 2.2
- `just test` green (EXIT=0; Debug asserts active).
- nsieve 9: tier-0 == tier-1a == native byte-identical; `--jit-native` exit 0
  (assert `final == ct` passed for all native traces).
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm.

## What 2.1 changed (the frameless ABI move)

Files: `src/x64.zig`, `src/nativegen.zig`.

- **`x64.zig`**: added `jmpReg` (FF /4, indirect near jump through a GP register) +
  golden-byte test (`jmp rcx/rax/r15`).
- **`nativegen.zig`**:
  - `pub const SPILL_MAX: u32 = 512` — frameless spill ceiling (4 KiB). Even, so
    `SPILL_MAX*8` is 16-aligned → body `rsp % 16 == 8` (same invariant the
    self-framed prologue gave, which the hash-cell callout relies on).
  - `McodeArena.ensureTrampoline()` — emits the shared trampoline ONCE into a
    permanent (never-freed) arena slot; returns `{entry, shared_exit}` absolute
    addrs. Trampoline: `push rbx/rbp/r12/r13/r14/r15; sub rsp,SPILL_MAX*8;
    xor rbx,rbx; jmp rcx`. `shared_exit`: `add rsp,SPILL_MAX*8; pop …; ret`.
    C-ABI `fn(rdi=tags, rsi=payloads, rdx=*NativeResult, rcx=body_entry)`.
  - `CompiledTrace.trampoline_entry: ?usize` + `TrampolineFn` type; `run` dispatches
    through the trampoline for arena (production) pages, directly (`EntryFn`) for
    owned (test) pages.
  - `compileImpl`: when `arena != null`, bail if `alloc.spill_count > SPILL_MAX`,
    else `ensureTrampoline` and pass `shared_exit` into `lower`; sets
    `trampoline_entry` on the result.
  - `lower(…, shared_exit: ?usize)`: prologue push/sub guarded behind
    `shared_exit == null`; every exit now calls `emitReturn(a, frame, callee,
    shared_exit)` — self-framed teardown when null, `movabs rax,shared_exit;
    jmp rax` (absolute, direct) when set.
  - Test path (`compile`, `arena == null`) keeps the OLD self-framed ABI → ~60
    standalone-page tests untouched + built-in A/B of both ABIs.

Refinement vs the doc's final design: 2.1 uses a *direct* absolute jmp to
`shared_exit` at each exit (no per-trace slot table). 2.3 replaces it with the
indirect `jmp [slot]` handoff (slot default = `shared_exit`) when link population
lands. Behaviourally identical while no slot is armed.

### Verification done for 2.1
- `just test` green (EXIT=0).
- nsieve 9: tier-0 == tier-1a == native byte-identical.
- 5 native traces compile+run frameless (`--dump-native`).
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm, sieve_int, **field_hash** (the resolveHashCell callout —
  most rsp-alignment-sensitive), array3d, grid_matmul.
- `just bench --filter nsieve --reps 5`: jit ms flat (93.3→91.5 nsieve;
  52.5→53.3 nsieve-bit; within noise). ABI move is perf-neutral (expected — no
  linking yet, just one extra indirect jmp per trace entry/exit).

## What 2.3a changed (indirect exit + slot table + P-E registry, byte-identical)

Files: `src/x64.zig`, `src/nativegen.zig`, `src/trace.zig`.

- **`x64.zig`**: added `jmpMem(base, disp)` (FF /4 memory form, indirect near jump
  through `[base+disp]`) + golden-byte tests (`FF 20`, `FF 60 08`, `41 FF 20`).
- **`nativegen.zig`**: `CompiledTrace` gains `slots: []usize` (owned, one per IR
  instruction index, default-filled `shared_exit`) + a `gpa` handle for `deinit`.
  `emitReturn` takes `slot_addr: ?usize` — when set (frameless + chainable exit) it
  emits `movabs rax, &slot; jmp qword [rax]`; `null` (deopt_exit/prologue_fail) keeps
  the direct `movabs rax, shared_exit; jmp rax`. `compileImpl` allocs `slots` *before*
  `lower` (stable imm64), frees on every failure path; `slotAddr(slots, i)` helper.
- **`trace.zig`**: `NativeLink{parent, slot_index, child}` + `TraceState.armed_links`
  list; `armNativeLink` (records dependency, supersedes same-slot record, then writes
  slot); `resetLinksTouching(t)` (child-retire → reset parent slots to `shared_exit`;
  parent-retire → drop record; slot addr re-derived from live parent, never cached);
  `removeTrace` calls it *before* `destroy`. Focused unit test pins both directions +
  re-arm supersede + OOB/non-compiled no-ops.

Nothing arms a slot yet → `armed_links` always empty, every exit still resolves to
its own `ct.id`, so `final == ct` holds and output is byte-identical.

### Verification done for 2.3a
- `just test` green (EXIT=0; Debug asserts + P-E registry unit test).
- nsieve 9: tier-0 == tier-1a == native byte-identical.
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm.
- `just bench --filter nsieve --reps 5`: jit ms flat (nsieve 94.2 vs 2.1's 91.5;
  nsieve-bit 53.8 vs 53.3; within noise — one extra load per exit is perf-neutral).

## 2.3a foundation review (two independent models) — DONE, hardening landed

Reviewed the `b8fc3fa` foundation with codex gpt-5.6-sol + a fable
technical-architect pass (Bart's call: review the foundation now, not just at the
end). Both returned **"approve with changes"** and converged: byte-identical holds,
S2 reset ordering correct both directions, slot addressing sound, and the flat
identity-keyed registry is genuinely *better* than the plan's pointer-map (which
would dangle its cached `*usize` on parent-retire).

**Hardening landed as a follow-up commit (still inert / byte-identical):**
- **BUG-1 (real latent OOM-only UAF, mine):** `armNativeLink` re-arm did
  `swapRemove(old)` then `try append(new)`; a failed append stranded the slot armed
  but untracked → S2 UAF on the old child's retire. Fixed: mutate the record in
  place on supersede (no allocation on the re-arm path). Doc comment corrected.
- `armNativeLink` now returns `bool` (armed vs no-op) for P-F accounting; pinned
  "only writer of `slots[i]`" invariant; unit test updated.
- doc 17: recorded the `rdi`/`rsi` liveness contract (P-A) and the
  slot-index-vs-exit-kind collision open question (P-C, blocks 2.3c).

**Bart's decisions from the review:**
- `armNativeLink` **keeps** the explicit `target` param + gets a Debug
  bounds-assert (`target` within `child`'s page). Deferred to 2.3b because the
  assert reads `child.page` → needs real compiled children (= fable's real
  retire-then-reuse test, item 6).
- **Pull S3 forward into 2.3b:** fix the chain-safe result contract (child
  prologue-fail must carry cumulative `rbx` + a distinct reason, never
  `completed=0`) BEFORE arming any slot, so the first arm is unconditionally
  chain-safe. codex flagged this as a hard prerequisite to the first real arm.

## NEXT: Increment 2.3b — arm `.link`-terminal handoffs (now incl. S3)

Slot table + P-E registry exist but nothing arms a slot. 2.3b makes `driveChain`
store a child's frameless body entry into the parent's slot for the **single-contract
`.link` terminal only** (avoids S1 loop-done dual materialization):
- **S3 result contract FIRST (pulled forward):** split `prologue_fail` so a child
  whose entry guard fails *after* the parent committed writes cumulative `rbx` +
  `final_trace_id=child` + a distinct reason, never `exit_instr=-1`/`completed=0`.
- **Bounds-assert + BUG-2:** add the Debug `target`-within-`child`-page assert in
  `armNativeLink` and the missing-trampoline assert in `resetLinksTouching`; add a
  real retire-then-reuse lifetime test (arm, force `removeTrace`, assert parent slot
  reset before the arena slot can be reused).
- **Eligibility (P-G):** child `.compiled`, `inputs.len == 0`, exit kind `.link`.
- **Arming point (P-F):** inside `driveChain` *after* the existing per-hop
  `onSideExit`/counters run, so every accounting side effect still happens; then
  `armNativeLink(&parent, E, child, child.page.code.ptr)` (now returns bool).
- **Safepoint blackout:** do NOT arm when `suspend_ctl`/replay-line/exec-log active.
- **Dispatcher (P-B payoff):** DROP `assert(final == ct)`; route consumers through
  `final` not `ct` — `last_exit_instr`, guard-fail counting
  (`final.instrs[exit_instr]`), `onSideExit(final,…)`, `maybeArmContinuation`,
  productive-branch counting, source-branch discrimination (interp.zig ~2586–2807).
Then 2.3c (ordinary guards + loop-done, S1; slot-identity collision decision), 2.3d
(P-E lane-widen end-to-end + peer-review full diff). Increment 3 = full
`lj_asm_patchexit` port (guard-jump rel32 patching, no runtime re-entry).

## 2.3b CONTRACT REVIEW (codex gpt-5.6-sol) — planned scope is WRONG, re-plan pending

Ran the arming contract past codex before coding the dispatcher rewire. Verdict:
**"do NOT implement 2.3b as 'arm the slot, drop `final==ct`, route everything
through `final`'."** Two substantive findings the plan missed:

- **BLOCKER — the `.link` terminal is NOT single-contract on the child side.**
  The L→I hop (a `.link` continuation reaching its terminal, handing off to the
  inner-loop root `I`) is run today via `int_native.runLinkedLoopDone(regs)`, which
  sets `NativeResult.linked_loop_done = 1`; `I`'s inner loop-done guard READS that
  flag (nativegen ~4213) to pick linked-completion materialization vs ordinary
  deopt. A bare armed `jmp I.page.code.ptr` does **not** set the flag → `I` takes
  ordinary `deopt_exit`, never commits its final iteration → wrong state. So arming
  `.link`→inner drags in the S1 mode-propagation that was supposed to be deferred to
  2.3c. Fix needs one of: (a) a second entry point on `I` (`linked_entry`) that
  presets the flag then falls into the body — armed slot targets that; (b) a per-arm
  stub that sets the flag then jumps; (c) enter armed parents with the flag already
  set. (a) is cleanest (compile-time, no runtime thunk, `I` codegen unchanged).
- **DETERMINISM TRAP — "route consumers through `final`" is unsafe as-is.** Exit
  IDENTITY (`exit_instr`, guard lookup, exit PC, resume PC) must use `final`. But
  the recording-STEERING accounting (`onSideExit`, `maybeArmContinuation`,
  `countProductiveBranchExit`) must reproduce driveChain's *logical* per-hop events,
  which are specific (validate loop-done → `onSideExit(I, max(local,1))` → +1
  enclosing progress; NO `maybeArmContinuation`/`countProductiveBranchExit` on that
  hop). Calling the dispatcher's whole productive-exit block against `final` invents
  accounting the unarmed chain never did → different penalties/gates → different
  later trace recording → **non-byte-identical across modes.** Worse,
  `NativeResult.completed` is cumulative `rbx`, NOT `I`'s LOCAL count nor
  `ChainResult.completed`; feeding cumulative `rbx` to `onSideExit` can flip a
  low-yield event to "useful". Needs a WIDER result contract: final identity + final
  exit reason + final's **local** committed count + enclosing-chain progress — the
  current 4 `NativeResult` fields are insufficient.
- Minor: once linking is live, `traceById(id) orelse ct` (interp ~2595) should
  **fail closed** (assert), not silently reinterpret a child exit as the parent's.

Net: the first real arm needs (i) child linked-entry mode propagation, (ii) a wider
`NativeResult` (local completed + enclosing progress), (iii) a driveChain-faithful
accounting split (identity via `final`, steering-accounting replicates the hop's
logical events), (iv) fail-closed `traceById`. That's materially bigger than the
one-commit 2.3b in the plan. **Landed so far:** S3 prep (`9d16711`, byte-identical,
codex-confirmed correct). **Awaiting Bart's call on how to re-scope/sequence.**

## Unpushed local commits (Rule #15 — don't push unless asked)
master is well ahead of origin/master; do NOT push without Bart's say-so.

## Untracked files that belong to OTHER agents — do NOT stage
`CURRENT_TASK_E3.md`, `bench/results/*.tsv`, and similar.
