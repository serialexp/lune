# lune — Native Codegen (tier 1b)

Status: Phase 8 cut 1 implemented — a hand-rolled x86-64 encoder + a
prove-typed-or-bail integer/boolean trace compiler, wired behind `--jit-native`.
Float/heap/mixed traces, deferred ops, derived-value guards, register allocation
across side exits, and per-exit side traces are later cuts (see §Out of scope).
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
- `rbx` = `completed` (callee-saved; pushed in the prologue, popped in the epilogue
  — kept out of the scratch pool so arithmetic can't clobber the counter, and it
  survives once we add `call`-outs for `pow`/`div`).
- `rax`/`rcx` = transient scratch.
- Each SSA ref gets an 8-byte **stack spill slot** `[rsp + ref*8]` (cut 1 is a
  stack-slot allocator: load operands → scratch → compute → store back; obviously
  correct, trivially matches SSA, already far faster than the interpreter).

Lowering sketch (one trace = one function):

- **Prologue:** `push rbx; xor rbx,rbx; sub rsp, frame` (frame 16-aligned).
- **`slot_load slot`:** `mov rax, [rdi + slot*16 + 8]` (payload) → spill.
- **`guard_int` on `slot_load(slot)`:** `cmp byte [rdi + slot*16], 2` (`Tag.int`)
  `; jne EXIT`.
- **`konst`:** `mov rax, imm64` (the const's payload bits, read at compile time) →
  spill.
- **arith / bitwise / `neg` / `bnot`:** load operand spills → scratch → native op
  (`add`/`sub`/`imul`/`and`/`or`/`xor`/`neg`/`not`) → spill. Wrapping `i64`
  `add/sub/mul` map directly to `add`/`sub`/`imul` (`0F AF /r` is exact low-64
  two's-complement wrap).
- **compare (`eq ne lt le`):** `cmp` operands; `setcc al`; **`movzx rax, al`**
  (setcc writes only the low byte — the zero-extend is load-bearing); → spill.
- **`guard_true a`:** if `a` is `Bool`, `cmp qword [spill_a], 0; je EXIT`; if `Int`,
  **no-op** (every int is truthy). **`guard_false a`:** if `Bool`,
  `cmp qword [spill_a], 0; jne EXIT`; if `Int`, **unconditional `jmp EXIT`** (an int
  is never falsy). This is Lua truthiness, in machine code.
- **`loop`:** for each `exit_store{slot, ref}`, box by `ref`'s proven kind —
  `mov qword [rdi+slot*16], TAG` (`2` for `Int`, `1` for `Bool`; the qword store
  zeroes the 7 padding bytes harmlessly) then `mov rax,[spill_ref]; mov
  [rdi+slot*16+8], rax`. Then `inc rbx; jmp LOOP_TOP`.
- **EXIT** (a *single* shared epilogue — every guard jumps here):
  `mov rax, rbx; add rsp, frame; pop rbx; ret`.

### Why the single-exit deopt is sound

`exit_stores` are written to `regs` **only at each `loop` commit** — mirroring
`irinterp.zig` exactly (`trace.commit` records every register the trace *defined*,
no more, no fewer). So at the *start* of every iteration `regs` is already a
coherent tier-0 loop-header state. A mid-iteration guard fail returns `completed`
with the last commit intact, and tier-0 re-runs the **pure, side-effect-free**
partial iteration from `anchor.pc`. No per-guard snapshot is needed — exactly the
tier-1a deopt model, now in machine code. A committed trace contains no side
effects (host calls / tables / globals all abort recording), so re-execution never
doubles an effect.

A subtle but important consequence: even when an unboxed int *use* precedes its
`guard_int` in the instruction stream, any divergent intermediate value is
discarded at the side-exit (nothing is committed), so the observable result
(`regs` + `completed`) stays identical to the interpreter.

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
  the bails (float const, unguarded `slot_load`, `guard_number`, `div`).
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

`zig build bench` (ReleaseFast) now reports a tier-1b native column. On a
~2–4M-iteration integer accumulator loop, tier-1b runs **~12–60× faster** than
tier-1a (the exact ratio depends on the loop and the machine; the dispatch loop is
simply gone). Loops that leave the proven subset show ≈ 1.0× — they fall back to
tier-1a transparently, which is the honest, expected behaviour for cut 1. The
classic example is `(i+7)*(i+7)`: the recorder emits a `guard_int` on the *derived*
`i+7` value, and cut 1 only proves a `guard_int` on a `slot_load`, so the whole
trace bails. Relaxing that (a `guard_int` on a statically-proven-`Int` derived
value is a no-op) is the highest-value next increment.

---

## Out of scope (named follow-ups)

- **Float / mixed / heap traces** — xmm registers, tag dispatch, libm `call`-outs.
- **Deferred ops** — `div`/`idiv`/`mod`/`pow` (floored-div/mod correction),
  `shl`/`shr` (Lua masked shift counts), `not` (logical, not bitwise).
- **Relax `guard_int` onto proven-`Int` derived values** (lower to a no-op) — lifts
  the `(i+7)*(i+7)`-style fallback; the single biggest coverage win.
- **Linear-scan register allocation** — keep loop-carried values in CPU registers
  across iterations instead of spilling every ref (cut 1 is stack-slot; correctness
  first).
- **Per-exit identity / side traces** — cut 1 has a single shared exit epilogue.
- **Proto-id stale-cache hardening** — `AnchorKey` borrows a raw `*const Proto` and
  the cache is never invalidated; a freed-then-reallocated `Proto` at the same
  address could hit a stale trace (and now stale machine code). Pre-existing in
  tier-1a; tracked as a separate task, not expanded here.
- **A wasm codegen backend** — a separate consumer of the same lowering seam.
