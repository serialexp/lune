# CURRENT_TASK — Exit-branch patching (faithful LuaJIT port), doc 17

## Status 2026-07-11

- **Increment 1 (P-D, shared mcode arena): LANDED** — commit `a970da4`.
- **Increment 2.1 (P-A, frameless chain-entry ABI): LANDED (uncommitted at time of
  writing this note — commit next).** Frameless trampoline + frameless bodies; all
  exits pinned to `shared_exit`; NO linking / NO ChainResult yet. Byte-identical.
- **Increment 2.2+ : DESIGNED + PEER-REVIEWED + DECIDED** — see
  `docs/design/17-exit-branch-patching.md` (§"Increment 2 — detailed design").

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

## NEXT: Increment 2.2 — ChainResult (P-B) + dispatcher PC mapping

Still NO linking; byte-identical gate. Replace the single-trace `NativeResult`
handoff with a chain-wide result carrying: FINAL trace identity, FINAL exit
identity, CUMULATIVE completed work, coherent resume PC. Must-fixes from the
review (already in doc 17 §"Peer-review corrections"):
- `completed` ≠ raw cumulative rbx (nested roll-up is +1 per inner run).
- Every exit consumer must index the FINAL trace, not the parent
  (`interp.zig:2584,2595` mis-attribution → OOB / wrong accounting).
- Stable never-reassigned trace id (cache index is `swapRemove`'d).
- Child prologue-fail must carry cumulative progress + a distinct reason, not
  `completed = 0`.
Then 2.3 link-slot population (`.link` first, then guard + loop-done; P-C/P-G),
2.4 P-F flag verification. Increment 3 = `lj_asm_patchexit` port + P-E
unpatch-on-retire lifetime (NOT deferrable — free-list reuse + widen-eviction make
code-UAF reachable; reset inbound slots before destroy).

## Unpushed local commits (Rule #15 — don't push unless asked)
master is well ahead of origin/master; do NOT push without Bart's say-so.

## Untracked files that belong to OTHER agents — do NOT stage
`CURRENT_TASK_E3.md`, `bench/results/*.tsv`, and similar.
