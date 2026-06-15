# lune — Native Codegen (tier 1b)

Status: Phase 8 **cut 2** implemented — a hand-rolled x86-64 encoder + a
prove-typed-or-bail integer/boolean trace compiler with **register allocation +
single-snapshot deopt**, wired behind `--jit-native`. Cut 1 was a stack-slot
allocator (every SSA ref round-tripped through the frame); cut 2 keeps loop-carried
and loop-invariant slots in CPU **registers** across iterations, hoists the
per-iteration type guards/loads to a once-only prologue, and writes `regs[]` only on
a side-exit. Float/heap/mixed traces, deferred ops, derived-value guards, two-operand
in-place arithmetic, and per-exit side traces are later cuts (see §Out of scope).
Owner: Bart
Last updated: 2026-06-15

Realises **Phase 8** in `00-architecture.md`. Tiers 0 and 1a are both
*interpreters*: tier-0 walks bytecode (`interp.zig`), tier-1a walks the optimized
SSA trace IR (`irinterp.zig` — still a `for (instrs) switch (op)` software
dispatch loop). Tier-1b removes that last interpreter: a hot trace is lowered to
**real x86-64 machine code**, written to an executable page, and called like a C
function. The dispatch loop disappears; the trace's arithmetic becomes native CPU
instructions.

Two decisions Bart locked before any code: **(A)** write our **own** assembler —
no LLVM/Cranelift; a JIT needs fast compile latency and we own the whole pipeline.
**(B)** native is **CLI-only** for now; a wasm codegen backend is a separate future
consumer of the same lowering seam (you cannot write executable pages inside the
wasm sandbox). Target: **x86-64 / Linux / System V AMD64**.

---

## The central idea: prove-typed-or-bail

The trace IR is **polymorphic** — `add`/`sub`/… branch on int-vs-float at runtime
(`arith.zig`), and `guard_*` ops narrow types. We do **not** reimplement that whole
polymorphic surface in machine code on day one. Instead:

> The compiler lowers a trace **only if** a static forward pass over the linear SSA
> can assign every value a concrete *kind* ∈ {`Int` (unboxed `i64`), `Bool`
> (unboxed `0`/`1`)} using a supported op subset. Any value that would be float /
> heap / mixed / nil, or any unsupported op, makes the **whole trace
> `Unsupported`** → it runs on tier-1a forever.

This is sound by construction and matches how real tracing JITs start. The wedge
holds because **the IR-interpreter stays the fallback *and* the oracle**: every
compiled trace is differential-tested to produce bit-identical `completed` + `regs`
versus `irinterp.execute`.

### The kind lattice (`proveKinds` in `nativegen.zig`)

Linear SSA means every operand's kind is known before its use. Two passes:

- **Pass A** records each `slot_load`'s register slot, and which refs a `guard_int`
  covers (a `guard_int` whose operand is a `slot_load` marks that load *guarded*).
- **Pass B** assigns kinds:
  - `konst` → `Int` iff the const tag is `int`; `Bool` iff `boolean`; else **bail**.
  - `slot_load` → `Int` **iff** a `guard_int` covers this exact ref (there is no
    `guard_bool`, and `guard_true/false` do **not** prove a type — an int passes
    `guard_true` — so a slot can only ever be proven `Int`). Unguarded → **bail**.
  - `add sub mul band bor bxor neg bnot` → `Int` iff all operands are `Int`.
  - `eq ne lt le` → `Bool`; operands must both be `Int`.
  - `guard_int a` → requires `a` is a `slot_load` (cut 1); lowers to a tag re-check
    on `regs[slot]` + side-exit. `guard_float` / `guard_number` → **always bail**
    (a float passes `guard_number`, so neither proves `Int`).
  - `guard_true a` / `guard_false a` → operand kind decides the lowering (below).
  - `loop` → terminal; each `exit_store{slot, ref}` is boxed by `ref`'s proven kind.

`guard_int` is the runtime tag-check that *enforces* the static `Int` proof: if a
slot isn't int at runtime it side-exits exactly as tier-1a does. The static proof
is what lets the body run unboxed; the dynamic guard is what keeps it honest.

**Supported ops, cut 1:** `slot_load`, `konst`, `add`, `sub`, `mul`, `band`, `bor`,
`bxor`, `neg`, `bnot`, `eq`, `ne`, `lt`, `le`, `guard_int`, `guard_true`,
`guard_false`, `loop`. **Bail:** `div`, `idiv`, `mod`, `pow`, `shl`, `shr`, `not`
(Lua truthiness ≠ bitwise-not), `guard_float`, `guard_number`, and every
float / mixed / heap / nil trace.

---

## The two halves

### `src/x64.zig` — the encoder (the assembler)

A growable byte buffer + a label/fixup table. A `Reg` enum (`rax`..`r15`) with
`.lo()`/`.hi()` for the REX split, and typed emit methods for exactly the forms the
lowering needs: `mov r,imm64` / `mov r,r` / `mov r,[base+disp]` / `mov [base+disp],r`
/ `mov qword [base+disp], imm32` / `movzx r,r8`; `add/sub/imul/and/or/xor r,r`;
`neg/not r`; `cmp r,r` / `cmp byte [base+disp],imm8` / `cmp qword [base+disp],imm8`
/ `cmp r,imm32`; `setcc r8`; `inc r`; `push/pop r`; `add/sub rsp,imm32`; `ret`;
and `jmp`/`jcc` as **rel32** with forward-reference fixups patched by `resolve()`.
Every method is covered by a **golden-byte test** asserting the emitted bytes
against a hand-verified encoding (incl. the REX.W and r8–r15 REX.B/R cases — the
encoding tables are the highest-risk surface).

### `src/nativegen.zig` — the IR-lowering half + exec memory

`mapExecutable(code)` does W^X: `mmap` a page RW, `@memcpy` the code,
`mprotect` it R+X, hand back an `ExecPage` whose base reinterprets as a function
pointer (`munmap` on free). `compile(gpa, t)` runs `proveKinds`, lowers the
supported subset into an `Assembler`, resolves fixups, maps the page, and returns a
`CompiledTrace` (or `null` to bail). All of this is comptime-gated to x86-64 Linux
(`is_x64_linux`); on any other target — including the wasm build that also imports
`root.zig` — the OS-specific branches are pruned and `compile` returns `null`, so
the module compiles **inert** everywhere.

---

## Entry / exit ABI (one compiled function per trace)

Signature: `fn(regs: [*]Value) callconv(.c) usize` — mirrors
`irinterp.execute(t, regs, values)` minus the `values` scratch (machine registers
+ a stack frame instead). Register roles:

- `rdi` = `regs` base, held for the whole body.
- `rbx` = `completed` (kept out of the scratch pool so arithmetic can't clobber the
  counter, and it survives once we add `call`-outs for `pow`/`div`).
- `rax`/`rcx` = reserved scratch (operand staging + the parallel-move cycle temp).
- 11 allocatable GPRs (`rdx rsi r8 r9 r10 r11 rbp r12 r13 r14 r15`), caller-saved
  preferred; any callee-saved one we actually use (`rbp`,`r12`–`r15`) is push/pop'd
  in the prologue/epilogue — **whether it's a slot home *or* a transient**.

### Cut 2: slot classification + homes (`analyze` in `nativegen.zig`)

Allocation is a forward two-phase pass (analysis fills `Loc`s; lowering consumes
them), separated because our IR is already linear (unlike LuaJIT's backwards
emission). Each tier-0 slot the trace touches is classified — total and disjoint:

- **carried** = `slot_load`ed **and** in `exit_stores` (read+write, loop-carried;
  always `Int`). Gets a **home** (a register, or a frame slot when the 11-reg pool is
  exhausted), loaded once in the prologue, reassigned only at the back-edge.
- **invariant** = `slot_load`ed, not in `exit_stores` (read-only `Int`). Homed once;
  never written back (untouched ⇒ stays coherent).
- **write-only** = in `exit_stores`, not `slot_load`ed (e.g. `flag = i<limit`). Keeps
  cut-1 behaviour: committed to `regs[]` at the back-edge, never touched at a deopt.

**Type-stability rejection:** a carried slot whose `store_ref`'s proven kind differs
from its load kind (loaded `Int`, stored `Bool`, or vice-versa) **bails the whole
trace** — otherwise native would loop forever where the oracle deopts on the next
iteration's `guard_int`.

Transients (ALU/compare/konst results) get registers via a forward **linear scan**
(expire by last-use, spill to a compacted frame slot when the pool empties). Homes
are pinned out of the pool for the whole body, so no transient ever aliases a home.

### Loop-invariant hoisting

The proven trace is pure-`Int` and never re-reads memory inside the loop, so **every
`slot_load` and every `guard_int` is loop-invariant** → hoisted to the prologue (run
once, not per iteration). `guard_true`/`guard_false` target *derived* comparison
results that change each iteration, so they **stay in the body**.

### Lowering sketch (one trace = one function)

- **Prologue:** `push rbx`; push each callee-saved home/transient reg; `xor rbx,rbx`;
  `sub rsp, frame` (frame = compacted spill slots, 16-aligned accounting for push
  parity). Then **all** hoisted `guard_int`s first — `cmp byte [rdi+slot*16], 2; jne
  PROLOGUE_FAIL` (no home live yet if one fails) — **then** all hoisted loads `mov
  home, [rdi+slot*16+8]`.
- **body `slot_load` / `guard_int`:** nothing — a `slot_load` ref *is* its home; the
  guard already fired in the prologue.
- **`konst`:** `mov rax, imm64` → its `Loc` (reg or spill).
- **arith / bitwise / `neg` / `bnot`:** operands → `rax`/`rcx` → native op
  (`add`/`sub`/`imul`/`and`/`or`/`xor`/`neg`/`not`) → result `Loc`. Wrapping `i64`
  maps directly (`0F AF /r` is exact low-64 two's-complement wrap).
- **compare (`eq ne lt le`):** `cmp`; `setcc al`; **`movzx rax, al`** (the
  zero-extend is load-bearing) → result `Loc`.
- **`guard_true a`/`guard_false a`:** `Int` operand → no-op / unconditional `jmp
  DEOPT_EXIT` (Lua truthiness: every int is truthy); `Bool` operand → `cmp` its
  `Loc` against 0 + `je`/`jne DEOPT_EXIT`.
- **`loop` (back-edge), in order:** (1) commit **write-only** slots to `regs[]`
  *first*; (2) the **PHI shuffle** — a parallel move `home(slot) ← loc(store_ref)`
  for every carried slot, acyclic moves first (Kahn), each remaining disjoint cycle
  broken with `rcx`, mem↔mem routed through `rax`; (3) `inc rbx; jmp LOOP_TOP`.
- **DEOPT_EXIT** (every body guard jumps here — the *single snapshot* flush): for each
  **carried** slot, `mov qword [rdi+slot*16], 2` (Int tag) + store its home payload
  (invariant + write-only slots are already coherent). Then `mov rax, rbx` → teardown
  (`add rsp,frame`; pop callee-saved reverse; `pop rbx`; `ret`).
- **PROLOGUE_FAIL** (a hoisted `guard_int` failed before any commit): `xor rax,rax`
  (rbx still 0) → same teardown, **without** the flush. A *distinct* label from
  DEOPT_EXIT — flushing half-initialised homes here would corrupt `regs[]`.

### Why one snapshot is valid at every guard

LuaJIT snapshots before *every* guard because it mutates in place. Lune doesn't need
to: `irinterp.zig` writes `regs[]` **only at the `loop` commit**, and on *any*
mid-iteration guard fail returns with `regs[]` untouched since the iteration began
(tier-0 re-runs the **pure, side-effect-free** partial iteration from `anchor.pc`).
So every native side-exit must restore `regs[]` to the *same* state — the last
loop-header commit, which is exactly the trace-wide `exit_stores`. **One snapshot,
valid at every guard.** Soundness: carried homes are loaded once in the prologue and
reassigned only at the back-edge shuffle (which runs *after* every body guard), so at
any body guard `home(slot) == regs[slot]` as of loop entry → the DEOPT_EXIT flush is
byte-equivalent to "untouched." The prologue guard is the one exception, handled by
the separate no-flush PROLOGUE_FAIL exit.

A committed trace contains no side effects (host calls / tables / globals all abort
recording), so re-execution never doubles an effect. And even when an unboxed int
*use* precedes its (now hoisted) guard, any divergent intermediate is discarded at
the side-exit (nothing committed), so `regs` + `completed` stay identical to the
interpreter.

---

## Tier integration

`TraceConfig.native_codegen` (default off) flips the path on. Each cached `Trace`
carries a **tri-state** `native: NativeState` (`unattempted` | `unsupported` |
`compiled: CompiledTrace`) so "not yet tried" never aliases "known unsupported."
`TraceState.nativeFor(t)` compiles lazily on the first native dispatch and memoizes
the verdict forever; the page is freed in `Trace.destroy`.

At the dispatch seam (`interp.zig`), the native path is taken **only when**
`config.execute && config.native_codegen && !config.record_exec_log &&
!isRecording()` — native is mutually exclusive with the visualiser's exec-log
instrumentation (which must observe the interpreter). On an `.unsupported` verdict
it transparently falls back to `irinterp.execute`.

---

## Correctness story (the differential oracle)

The IR-interpreter is the source of truth for IR *semantics*. Native code must be
**invisible**:

- **Unit (`nativegen.zig`):** hand-built traces run through both
  `irinterp.execute` and `compile().run()`; assert identical `completed` + `regs`
  (compared **semantically** — tag + payload bits — since the 7 padding bytes are
  non-semantic and left undefined by `Value.int`). Cases: a clean counting loop; a
  `guard_int` side-exit; a **loop-carried bool** (proves tag=1 boxing); `guard_true`
  on `int 0` (must pass — truthy); `guard_false` on an int (immediate exit); and
  the bails (float const, unguarded `slot_load`, `guard_number`, `div`). Cut-2 adds
  the allocator-stress cases: `analyze` classification + disjoint home pinning; a
  type-unstable carried slot (loaded `Int`, stored `Bool`) is rejected; a **swap
  loop** (`a,b = b,a`) exercising a register home cycle in the parallel move; and a
  loop with **more carried+invariant slots than registers** forcing spilled homes
  (and, with the pool exhausted, spilled transients too).
- **Integration (`interp.zig`):** a `record_execute_native` mode joins the
  `expectProgram` GC × trace-mode matrix, so **every** program test also runs
  through native codegen (falling back where a trace leaves the subset) and must
  print byte-identically. Focused tests assert the decisive internal signal — a hot
  integer for-loop is `.compiled`; a float loop is terminally `.unsupported` yet
  matches tier-0; an int loop that flips to float mid-run deopts out of native code
  and still matches tier-0 to the last decimal.
- **Self-validation (release-safe):** `assertWellFormed` is compiled out in
  release, so `compile` **re-validates** its input and bails on anything it can't
  faithfully encode (out-of-range `aux`/`exit_store.ref`, a malformed/non-`loop`-
  terminated trace, any op/kind outside the lattice). It never emits code on an
  unproven assumption.

---

## Measured (informational)

`zig build bench` (ReleaseFast) reports a tier-1b native column. On the
`acc = acc + i` numeric-for loop (4M iterations, best of 5, `Vm.run` only):

| tier | time | vs tier-1a |
|------|------|-----------|
| tier-0 bytecode | ~48 ms | — |
| tier-1a (optimized IR interp) | ~105 ms¹ | 1.0× |
| tier-1b native, **cut 1** (stack-slot) | ~9.3 ms² | ~11× |
| tier-1b native, **cut 2** (register homes) | **3.74 ms** | **~28×** |
| LuaJIT (`os.clock` around the loop) | ~2.0 ms | — |

¹ tier-1a is slower than tier-0 here only because the optimizer/IR-interp path adds
fixed overhead the dispatch-bound microloop doesn't amortize; it's the *baseline the
native column is measured against*, not a regression. ² cut-1 figure scaled from its
2M measurement. Cut 2 closed the gap to LuaJIT from ~4× to **~1.9×** — the remaining
gap is mostly the rax/rcx operand staging (cut 2 still does `mov rax,a; mov rcx,b;
op; mov dst,rax` where LuaJIT emits a single two-operand `op dst,b`); see §Out of
scope "two-operand in-place arithmetic".

Loops that leave the proven subset show ≈ 1.0× — they fall back to tier-1a
transparently. The classic example is `(i+7)*(i+7)`: the recorder emits a
`guard_int` on the *derived* `i+7` value, and we only prove a `guard_int` on a
`slot_load`, so the whole trace bails (this is `proveKinds`, unchanged by cut 2).
Relaxing that (a `guard_int` on a statically-proven-`Int` derived value is a no-op)
is the highest-value coverage increment.

---

## Out of scope (named follow-ups)

- **Float / mixed / heap traces** — xmm registers, tag dispatch, libm `call`-outs.
- **Deferred ops** — `div`/`idiv`/`mod`/`pow` (floored-div/mod correction),
  `shl`/`shr` (Lua masked shift counts), `not` (logical, not bitwise).
- **Relax `guard_int` onto proven-`Int` derived values** (lower to a no-op) — lifts
  the `(i+7)*(i+7)`-style fallback; the single biggest coverage win.
- ~~**Linear-scan register allocation**~~ — **done (cut 2):** carried/invariant slots
  are register-homed across iterations, `regs[]` written only on a side-exit.
- **Two-operand in-place arithmetic** — cut 2 still stages every ALU op through
  rax/rcx; coalescing the result home onto a dying operand register would emit a
  single `op dst, b` and close most of the remaining gap to LuaJIT.
- **Encoder size-opts** (`test r,r` for bool guards, `xchg` for 2-cycle swaps) —
  semantically identical, smaller; currently uses `cmp r,0` / mov-through-`rcx`.
- **Per-exit identity / side traces** — cut 1/2 have a single shared deopt epilogue.
- **Proto-id stale-cache hardening** — `AnchorKey` borrows a raw `*const Proto` and
  the cache is never invalidated; a freed-then-reallocated `Proto` at the same
  address could hit a stale trace (and now stale machine code). Pre-existing in
  tier-1a; tracked as a separate task, not expanded here.
- **A wasm codegen backend** — a separate consumer of the same lowering seam.
