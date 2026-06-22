# lune — Native Codegen (tier 1b)

Status: Phase 8 **cut 3** implemented — a hand-rolled x86-64 encoder + a
prove-typed-or-bail integer/boolean trace compiler with **register allocation +
single-snapshot deopt + two-operand in-place arithmetic**, wired behind
`--jit-native`. Cut 1 was a stack-slot allocator (every SSA ref round-tripped through
the frame); cut 2 keeps loop-carried and loop-invariant slots in CPU **registers**
across iterations, hoists the per-iteration type guards/loads to a once-only
prologue, and writes `regs[]` only on a side-exit; cut 3 reads ALU operands straight
from their homes (load-form `op r,[mem]`), coalesces a result onto a dying operand's
register, and — behind a single-snapshot safety predicate — updates a carried slot's
home **in place** so the back-edge shuffle elides. This put `acc=acc+i` at ~1.10× off
LuaJIT. Coverage #1 then relaxed `guard_int` onto proven-`Int` *derived* values
(`Int`-op-of-`Int`s), landing op-chain and multi-accumulator loops on the native
path (~2.5× off LuaJIT — the richer shapes still have headroom). **Phase B** then
added a lane-aware **array load/store** path (`t[k]` against the packed `ArrayPart`)
— see §Phase B below. **Phase D** then added a **float/XMM** path (float
`add`/`sub`/`mul`/`div` + comparisons, int→float promotion) — see §Phase D below.
**Phase E** then added native **`shl`/`shr`** (branch-bracketed `cl`-shift matching
Lua's full logical-shift semantics), unlocking nsieve-bit's shift loops to native
(2.5×) — see §Out of scope. Heap (non-array)/mixed traces, the remaining deferred
numeric ops (`idiv`/`mod`/`pow`/`not`), accumulator sinking, and per-exit side traces
are later cuts (see §Out of scope).
Owner: Bart
Last updated: 2026-06-22

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
  - `guard_int a` → passes iff `a` is already proven `Int`. If `a` is a `slot_load`
    it marks that load *guarded* (Pass A) and lowers to one hoisted tag re-check on
    `regs[slot]`. If `a` is a **derived** value (an `Int`-typed ALU result) the guard
    is statically redundant — `Int`-op-of-`Int`s is closed over `Int` — and lowers to
    **nothing** (the #1 relaxation; before, a derived guard bailed the whole trace).
    A `guard_int` on a `Bool` → **bail**. `guard_float` / `guard_number` → **always
    bail** (a float passes `guard_number`, so neither proves `Int`).
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

> The cut-1 lattice above is **int/bool-only** and is the historical baseline.
> **Phase D (below)** extends it with `Kind.float`: a `slot_load` covered by a
> `guard_float` proves `.float`, `guard_float` discharges (lowers to a `tag==3`
> prologue check), float-result `add`/`sub`/`mul` and *all* `div` lower to SSE2, and
> `eq`/`ne`/`lt`/`le` on two floats lower to `ucomisd`. `guard_number`, `pow`, `mod`,
> `idiv`-on-floats, and float `neg` still bail. See §Phase D for the full rules.

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
  Note the recorder pre-filters this set: for a numeric-`for`, a write-only slot
  that is a *compiler temporary* (above the live-locals watermark `base+4`, set
  only by the anchoring loop's `for_loop`) is dropped from `exit_stores` at
  `commit()` — it's dead at the loop header (tier-0 recomputes it on deopt) and
  after the loop, so its per-iteration commit was pure waste. So the write-only
  slots that reach here are genuine live-out locals (or any slot in a non-`for`-
  anchored trace, which is never filtered).

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

### Cut 3: two-operand in-place arithmetic

Cut 2 still computed every ALU op through the rax/rcx scratch pair. Cut 3 closes the
LuaJIT gap with two wins, both judged bit-for-bit by the oracle.

**Win 1 — operands in place + operand coalescing (always sound).** `emitBinAlu`/
`emitCompare` read each operand straight from its `Place`: a register operand uses
`op reg,reg`, a spilled operand uses the load form `op reg,[rsp+disp]` (the cut-3
`aluRegMem` encodings) — no more staging both through rax/rcx. The allocator's linear
scan adds *operand coalescing*: when a transient result's operand dies exactly at the
def (`last_use == def`) and lives in a **non-home** register, the result reuses that
register, so `acc=acc+i` lowers to `mov T,acc; add T,i` (+ the back-edge `mov acc,T`).
The non-home test is location-based (`loc ∈ home_reg_mask`), never `slot_id<0`, so it
stays correct once win 2 puts a transient into a home. This alone took the loop to
~1.10× off LuaJIT.

**Win 2 — in-place home coalescing (guarded).** When a carried slot S's sole
`store_ref` is an arithmetic/unary op at index `j`, the allocator may pin that result
*into* `home(S)` (set before the linear scan, which then leaves it fixed). The op
becomes `add home(S), other` and the back-edge shuffle move for S self-elides (S is
dropped from `moves[]`). Because this writes a carried home *mid-body* — violating
cut 2's "homes written only at the back-edge" invariant — it is gated on a predicate:

1. **`j` is after the last body guard** (`guard_true`/`guard_false`; `guard_int` is
   hoisted). A side-exit after the in-place write would flush the *new* value where
   the oracle's re-run model expects the loop-header value. The trace is straight-line,
   so trace-index order is dominance — the index test is exact.
2. **S's old value is dead by `j`** — no `slot_load(S)` ref has `last_use > j` (the
   in-place write clobbers the home holding the old value).
3. **`home(S)` holds an operand** — the left operand (any op), or a commutative op's
   right operand; a unary's sole operand must be `home(S)`. (Plus: a spilled-home
   `mul` falls back — `imul` has no `[mem],reg` store form.)

The coalesced transient is pinned (`last_use → loop marker`) and excluded from win-1
scavenging, so a later consumer of the new value never steals the home.

**Measured caveat (the perf cliff).** The recorded counted loop emits its loop-exit
`guard_true` as the *last* body instruction, with every accumulator update before it,
so predicate (1) declines and win 2 is **inert on `acc=acc+i`** — the win-1 form
stands. Win 2 fires for traces whose accumulation follows the last guard (loops with
internal branches). Making it fire on the counted loop needs a schedule pass that
sinks pure carried-`exit_store` producers below the last guard; that is a named
follow-up, sound under the same re-run deopt model but out of scope for cut 3.

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
  the bails (unguarded `slot_load`, `guard_number`, `mod` — `div` and float consts
  now compile, see Phase D). Cut-2 adds
  the allocator-stress cases: `analyze` classification + disjoint home pinning; a
  type-unstable carried slot (loaded `Int`, stored `Bool`) is rejected; a **swap
  loop** (`a,b = b,a`) exercising a register home cycle in the parallel move; and a
  loop with **more carried+invariant slots than registers** forcing spilled homes
  (and, with the pool exhausted, spilled transients too).
- **Integration (`interp.zig`):** a `record_execute_native` mode joins the
  `expectProgram` GC × trace-mode matrix, so **every** program test also runs
  through native codegen (falling back where a trace leaves the subset) and must
  print byte-identically. Focused tests assert the decisive internal signal — a hot
  integer for-loop is `.compiled`; a **float-accumulate loop is `.compiled`** too
  (Phase D / the XMM path) and matches tier-0 bit-for-bit; an int loop that flips to
  float mid-run deopts out of native code and still matches tier-0 to the last decimal.
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
| tier-1b native, **cut 2** (register homes) | 3.74 ms | ~28× |
| tier-1b native, **cut 3** (operands in place) | **2.27 ms** | **~46×** |
| LuaJIT (`os.clock` around the loop) | ~2.07 ms | — |

¹ tier-1a is slower than tier-0 here only because the optimizer/IR-interp path adds
fixed overhead the dispatch-bound microloop doesn't amortize; it's the *baseline the
native column is measured against*, not a regression. ² cut-1 figure scaled from its
2M measurement. Cut 3's **win 1** (read ALU operands straight from their register/
spill home + reuse a dying operand's register for the result, replacing cut 2's
`mov rax,a; mov rcx,b; op; mov dst,rax` staging) took the loop from 3.74 ms to
**2.27 ms — ~1.10× off LuaJIT** (cut 2 was ~1.81× off). Cut 3's **win 2** (in-place
home coalescing, `add acc,i` with the back-edge move elided) is implemented and
sound but **inert on this loop**: the recorded counted loop places its loop-exit
`guard_true` *last*, with every accumulator update before it, so the win-2 safety
predicate (no side-exit may follow an in-place home update — see §Cut 3) declines.
Win 2 fires for traces whose accumulation follows the last guard; making it fire on
the counted loop needs an update-sinking schedule pass (see §Out of scope).

**Coverage #1 (derived `guard_int`) — landed.** Loops with `guard_int`s on derived
values used to fall back to tier-1a; now they compile. This more than doubled the
benches reaching native and gave us *multi-op* shapes to measure (4M iters, best of
5, `Vm.run` only; LuaJIT via `os.clock`):

| program | tier-1b native | LuaJIT | off LuaJIT |
|---------|----------------|--------|-----------|
| `acc = acc + i` (1 accumulator) | 2.32 ms | ~2.07 ms | ~1.10× |
| `acc = acc + (i+7)*(i+7)` (op chain) | 5.40 ms | ~2.19 ms | ~2.5× |
| `a += (i-1)²; b += (i-1)` (2 accumulators) | 5.86 ms | ~2.20 ms | ~2.7× |

The richer shapes sit ~2.5× off LuaJIT, versus ~1.10× on the single-accumulator
loop — the single loop was overfit-favorable. Closing that gap is future work
(win-2 update-sinking, better operand scheduling/spill avoidance on longer chains).
Float loops now compile too (Phase D — float `add`/`sub`/`mul`/`div` + compares on
the XMM path; ≈7.8× over tier-0 on `bench/pi_leibniz.lua`). Loops still outside the
proven subset (heap/mixed traces, the deferred numeric ops) fall back to tier-1a
transparently (≈ 1.0×).

---

## Phase B — lane-aware array load/store (tier-1b)

Phase B teaches the native backend to read and write a table's dense run directly,
against the lane-packed `ArrayPart` (`src/array.zig`) frozen by Phase A. The native
path handles `t[k]` exactly when `k ∈ 1..len` (the array part); sparse/string keys,
OOB, holes, and the heap-bearing `.value` lane all guard-bail to tier-1a. The
fixed-width lanes — bool, i8…i64, u8, **and now f64 (Phase D Gap A, see §Phase D)** —
all lower natively.

**IR (recorder → oracle → native), `IrInstr` stays 16 B via the aref-pairing trick:**
- `aref` (`a`=table, `b`=index, `aux`=lane) → addressing token carrying `idx0 = k-1`.
  Loop-variant (never hoisted). New native `Kind.aref`.
- `aload` (`a`=aref, `aux`=lane) → decode the slot to a `Value` (bool lane: `movzx`
  the in-band byte + `sub 1` → 0/1; int lanes i8/i16/i32/i64: `movsx`/`movsxd`/`mov`
  per width; **f64 lane: `lea` the element address + `movsd` the raw 8 bytes into the
  aload's XMM/spill home** — no decode, `array.decode` for `.f64` is a `@bitCast`).
- `astore` (`a`=aref, `b`=value, `aux`=lane) → encode the value. The **bool lane** is
  byte-granular with presence in-band (`0=absent,1=false,2=true`): a single
  `mov byte [data+idx0], value+1` carries value and presence together — one
  non-RMW store, one cacheline, the atomic commit (I5 trivial). The **int lanes**
  write a width-truncating `mov [data+idx0*w]` then set the presence bitmap bit
  **LAST** (I5 — the commit point for an absent→present transition). The **f64 lane**
  is the int-lane shape with a full-width `movsd [data+idx0*8]` store (no truncation —
  every double fits) followed by the same presence `bts`.
- read/write guards: `guard_table` (slot is a `table`), `guard_lane` (array lane ==
  recorded lane — both hoisted to the prologue), `guard_bounds` (`idx0 <u len`),
  `guard_present` (a hole would read as `nil`: bool lane tests the in-band byte ≠ 0;
  int/float lanes `bt` the presence bitmap).
- `guard_fits` (`a`=value, `aux`=lane) — **the narrow-lane store soundness guard.** A
  value that no longer fits the recorded lane would force tier-0 to WIDEN the array
  (allocate + relayout), which the native store cannot do mid-run. The recorder emits
  `guard_fits` before **every** narrow-lane `astore` (the store value can be a
  free-variable loop-carried slot, not just a constant, so the recorder cannot assume
  it stays in-lane); the tier-1a oracle side-exits via `ArrayPart.laneFits` identically.
  Native lowers it per lane: an int lane → a signed range compare (i8/i16/i32; i64 fits
  everything → no check); the **bool** and **f64** lanes → *nothing* (proveKinds already
  requires the store value to be a proven `.bool` / `.float`, so the guard is a runtime
  no-op there) — but the oracle, which runs the raw trace, still needs it so a
  free-variable store of the wrong type side-exits instead of tripping
  `ArrayPart.setInLane`'s in-lane assert. When the store value is a *constant* (e.g. the
  bool sieve's `t[k]=false` or an `a[k]=2.0` float fill), the optimizer folds the guard
  away entirely (`tropt` evaluates it via `laneFits` at commit time) — so unlike the
  narrow int lanes, the f64 `astore` requires **no `fits_ok` coverage** in proveKinds
  (a full-width `movsd` never narrows), letting a constant float fill compile even with
  the guard folded out.

**Soundness invariants enforced:**
- **C1 (relaxed by store-sinking — Gap B, doc 07)** — a write whose value/control
  depends on a prior packed read used to be unrecordable: `recArraySet` aborted if
  *any* `aload` existed in the trace (conservative over both data and control
  channels). That blocked every read-modify-write loop. **Store-sinking** now lifts
  the restriction for the common single-store RMW shape: rather than aborting, the
  recorder *defers* the `astore`(s) and re-emits them in `commit()` just before the
  `.loop` terminator — i.e. **below every loop-exit guard**. Because no side-exit can
  occur after the store(s), deopt never re-runs a half-applied iteration (tier-0 re-runs
  the side-exiting iteration from the loop header and applies the store(s) exactly once),
  so the double-apply hazard the rule guarded against cannot arise. **Gap C (multi-store,
  doc 08, landed 2026-06-22)** generalizes this to a bounded ordered set of up to
  `MAX_PENDING_STORES = 4` deferred stores, flushed front-to-back in recorded
  (bytecode) order below every guard — so the FFT butterfly (4 reads then 4 stores to
  two indices) records and runs native (scimark-fft t0 993.9 ms → jit 715.7 ms). The
  deferral is rejected (still abort) if a heap-*reading* op (`aload`) or an
  `astore_append` follows a deferred store — the stores must be the trace's last array
  accesses — or if the store count exceeds the cap. A further in-bounds `astore`
  appends to the pending set instead of aborting (that is the Gap C change).
  nsieve's sieve-clearing loop is pure constant writes (no `aload`), so
  it never deferred and is unaffected. The real oracle for soundness here is **tier-0
  deopt-replay** (an 8-mode `expectProgram` RMW loop — `interp.zig`) — `expectMatch`
  (regs-only) cannot catch a double-apply because both tiers leave the same partial
  heap on a side-exit.
- **C2** — no `.ptr`/`.aref` kind in `exit_stores` (the deopt flush writes TAG_INT;
  a raw pointer there would corrupt the slot). Enforced in `proveKinds`.
- **I3** one `idx0 = index-1` shared by bounds/present/address. **I4** `guard_bounds`
  dominates `guard_present`/`aload`/`astore` (`len>0 ⇒ present non-null`). Int astore
  folds `idx0` into the element address with `lea` so data-ptr + value fit in the two
  scratch registers (rax/rcx) without a third.

**B5 — nsieve end-to-end + measurement.** The array path compiles end-to-end: an
integer-limit sieve (`bench/sieve_int.lua`) records both hot loops — the read
(`if p[i]`) and the bool-lane write (`for k=i+i,m,i do p[k]=false end`) — and both
`.compiled` to native x86-64 (243 + 247 bytes). Output is byte-identical to LuaJIT.

| int-sieve, N=4 000 000, best-of-3 | time | vs tier-0 |
|---|---|---|
| tier-0 (bytecode interp) | 0.36 s | 1.0× |
| tier-1a (IR interp) | 0.55 s | 0.65× |
| **tier-1b (native, array path)** | **0.13 s** | **2.8×** |
| LuaJIT | 0.04 s | 9.0× |

The native array path is **2.8× faster than tier-0 and 4.2× faster than tier-1a**,
~3.25× off LuaJIT. (The bool-lane write shed a branch and a second bit-op once the
lane went byte-granular — see Phase C below — improving native 0.15 s → 0.13 s.)

> **Caveat — canonical `bench/nsieve.lua` does NOT JIT its hot loop yet.** Its limit
> `m = (2^(N-i))*10000` comes from a float `pow`, so the numeric-for loop variable and
> limit are **floats**; the loop bails on `guard_float` before the array work is even
> reached. This is the deferred **float/XMM** phase, *not* an array-path gap — the
> array read/write lowering is complete and exercised by the int-limit variant above.
> Canonical nsieve still runs **byte-identical to LuaJIT under `--jit-native`** for
> N∈{1,4,6,9,11} (it transparently executes on tier-1a). `bench/sieve_int.lua` is the
> int-keyed variant that actually JITs, kept as the reproducible array-path benchmark.

**Phase C — byte-granular bool lane.** The bool lane was originally bit-packed (1 value
bit + a separate presence bitmap), so each `p[k]=false` lowered to a branch on the value
plus `bts`/`btr [data],idx0` and a second `bts [present],idx0` — two `bt`-family
read-modify-write ops on two cachelines. x86's smallest single-instruction unit is the
byte, so sub-byte storage *forces* those RMW ops. Phase C made the bool lane one byte per
slot with presence folded **in-band** (`0=absent, 1=false, 2=true`, see `03-gc-memory.md`):
the store is a single `mov byte [data+idx0], value+1` (one cacheline, no RMW, atomic
commit — no separate presence write), and the load a `movzx` + `sub 1`. `guard_present`
tests the in-band byte ≠ 0 instead of `bt`-ing the bitmap. Cost: ~4× the bool-lane bytes
(still ~5× under LuaJIT at 20 M slots), bought a measurable write-path speedup (0.15 →
0.13 s) and a structurally simpler lane (no second allocation). Int/float lanes keep the
presence bitmap — every int/float bit pattern is a valid value, so they can't fold
absence in-band.

## Phase D — float / XMM native path (tier-1b)

Phase D lifts the int/bool-only restriction: **float numeric loops now compile to native
x86-64**. The backend gained a second register class (`Kind.float`, homed in xmm2–15 with
xmm0/xmm1 reserved as scratch — the analogue of rax/rcx), a shared 8-byte spill pool
(`kinds[]` picks `movsd` vs `mov`), and SSE2 emitters in `x64.zig` (`movsd`, `addsd`/
`subsd`/`mulsd`/`divsd`, `ucomisd`, `cvtsi2sd`, `movq`). Because the target is
`fn([*]Value) callconv(.c)` and **all** of xmm0–15 are caller-saved under SysV, the trace
owns every XMM register — there is no prologue/epilogue XMM save (the GP push machinery is
untouched, and no XMM bit ever enters `CALLEE_SAVED_MASK`).

What compiles: float `add`/`sub`/`mul`/`div` and float comparisons (`eq`/`ne`/`lt`/`le`),
with int→float promotion via `cvtsi2sd` at the use site so mixed arithmetic (`acc + i`)
and integer `div` (`7/2 == 3.5`, always float in Lua) work. Kinds stay **fully static** —
the recorder guards each operand `guard_int`/`guard_float` and stamps `ins.ty`, so native
needs no runtime int-vs-float dispatch; every value's class is pinned by a dominating
guard, its konst tag, or `ins.ty`.

- **Strict-FP bit-exactness.** The tier-1a oracle runs `arith.zig` under
  `@setFloatMode(.strict)` (scalar SSE2 — no x87, no FMA), so the same `divsd`/`addsd`
  native emits produces identical bits, including ±inf and the `0.0/0.0` quiet-NaN
  payload. `cvtsi2sd` (round-to-nearest, ties-to-even) matches `@floatFromInt` exactly,
  even for `|i| > 2^53` and the i64 extremes. Operand order is preserved (xmm0=lhs op
  xmm1=rhs) for the non-commutative `sub`/`div`. `div` is *always* float — proveKinds
  gives it `.float` with **no "≥1 float operand" gate** (unlike `add`/`sub`/`mul`, where
  int+int is an integer-wrapping op stamped `.int`); int operands are `cvtsi2sd`'d, which
  is the oracle's own `toFloat()` path.
- **NaN-aware compares.** `ucomisd` sets only ZF/PF/CF (PF=1 ⇔ unordered). `lt`/`le` use a
  *swapped* `ucomisd rhs,lhs` + `seta`/`setae` (unsigned conds; a NaN's CF=1 makes them
  false for free); `eq` = `sete AND setnp` (ordered ∧ equal), `ne` = `setne OR setp`
  (unordered ∨ not-equal). This mirrors `compareNumeric` for two f64s: a NaN makes
  lt/le/eq false and ne true. **Mixed int/float compares deliberately bail** — the oracle
  compares them *exactly* (`compareIntFloat`, no rounding), which a cvtsi2sd-then-ucomisd
  lowering cannot reproduce for large ints. (Mixed *arithmetic* is fine: there the oracle
  promotes via `toFloat`, which cvtsi2sd matches.)
- **Float deopt flush.** A carried float slot is flushed to `regs[slot]` as the tag byte
  `TAG_FLOAT` (a 4-byte imm whose top 3 bytes overwrite non-semantic `Value` padding) then
  the payload via `movsd [rdi+slot*16+8], xmm` (a register-homed float can't use the GP
  `movMemReg`); a spilled float copies its 8 bytes raw through rax. The prologue mirrors
  this: a float slot's hoisted type-guard checks `tag == 3` and loads with `movsd`.

**Benchmark (`bench/pi_leibniz.lua`).** A pure-float hot loop (Leibniz series for π:
carried float accumulator + sign-flip `mulsd`, a `cvtsi2sd`'d int counter, and a `divsd`)
compiles to one 443-byte native function. Output is bit-identical across all four tiers
**and to LuaJIT** (`leibniz(2e6) == 3.141592153589724`, `0x1.921fb11284dfap+1`). Timings
(best-of-3, N=50 M): tier-0 **3.06 s**, tier-1a **3.36 s**, **tier-1b 0.39 s** (≈7.8× over
tier-0), LuaJIT **0.03 s**. The LuaJIT gap is wider than on the int loops — it hoists the
loop-invariant reciprocal and strength-reduces the `2k+1`, neither of which lune's
single-block trace does yet.

> **Deferred (still bail to tier-1a):** `pow` (libm), `mod`/`idiv` on floats
> (floored-div correction / no float remainder native), float `neg` (xorpd sign-mask),
> and `guard_number` (a float passes it, so it can't prove a single pinned kind). Float
> coalescing (win-1/win-2) is also off in this first cut — SSE has no `op [mem],xmm`
> store-form, so float ops always materialize into xmm0/xmm1 then write the home.
> The canonical `bench/nsieve.lua` uses `pow` only *once, outside* the hot loop, so its
> loops compile under Phase D (the `2^x` limit is float, but the loop variable is the
> int `i`); only programs whose hot loop hits a deferred op stay interpreted.

### Gap A — the f64 array lane (tier-1b)

Phase D's scalar XMM path covered float *arithmetic* but not the float *array* lane:
`nativegen.laneKind` returned `null` for `.f64`, so every `aload`/`astore`/`guard_fits`
over a float array bailed in `proveKinds` ("unsupported, runs on tier-1a"). Profiling
the scimark corpus (`scimark-lu`, 77× off LuaJIT) found it ran **0% native** — 52% of
its time in `array.ArrayPart.decode` unpacking f64 slots that the JIT never touched.

Gap A is **pure lowering** — the recorder already emits f64 `aload`/`astore`, the
tier-1a oracle already executes them, and the `movsd`/`lea`/`cvtsi2sd` encodings + XMM
allocator already existed from Phase D. The change: `laneKind` maps `.f64 → .float`
(unblocking `proveKinds`), the `aload` arm classifies a loaded double as `.float`, and
three lowering arms mirror the int lanes with `movsd` substituted for the GP `mov`
(`lea` element address → `movsd` load into the XMM/spill home; stage value to a scratch
XMM → `movsd` store + presence `bts`; `guard_fits` is a no-op). Crucially the f64
`astore` requires **no `fits_ok`** (every double fits a full-width `movsd`), so it
mirrors the **bool** lane rather than the narrow int lanes — that's what lets a
constant-float fill compile after `tropt` folds the redundant `guard_fits`.

**Determinism** is inherited from the int lanes: `movsd` moves raw 8-byte patterns and
`array.decode`/`encode` for `.f64` are `@bitCast` round-trips, so native and tier-0
move byte-identical bits — no FP rounding in a load or a store (arithmetic
bit-exactness was already settled by Phase D's strict-FP). Verified byte-identical
across all 8 determinism modes (read reduction + constant fill).

**Benchmark (float-array probes, ReleaseFast, N=200 k × 1 k).** A pure read reduction
(`s = s + a[k]`) goes **tier-0 4.74 s → tier-1b 0.34 s (≈13.9×)**; a constant fill
(`a[k] = 2.5`) goes **2.71 s → 0.30 s (≈9.0×)** — both previously compiled to *zero*
native instructions. LuaJIT runs them in 0.08 s / 0.04 s, so the remaining ~4–7× is
codegen tightness (loop overhead, per-iteration guards), **not** JIT coverage. The
scimark kernels themselves were unmoved by Gap A alone: their hot loops are
read-modify-write (`vi[k] = vi[k] - eij*vj[k]`), which the recorder's old **C1 rule**
aborted (any `astore`-after-`aload` → `.bad_type`). **Gap B** (store-sinking, doc 07)
unblocked them by deferring the single RMW `astore` below the last loop-exit guard;
with both landed, scimark-sor went **46.9× → 4.5×** vs LuaJIT and scimark-lu
**74.5× → 12.4×**. **Gap C** (multi-store, doc 08) then generalized the deferral to a
bounded ordered set, moving scimark-fft **54.3× → 39.1×** (t0 993.9 ms → jit 715.7 ms;
the 4-store butterfly now records native). Sparse's indirect gather (`x[col[k]]`)
stays out of scope. Gap A is the float-array foundation Gaps B and C build on.

## Out of scope (named follow-ups)

- **Mixed / heap (non-array) traces** — heap-value tag dispatch, nil handling, and
  metatable-free table-field access outside the dense array part. Float arithmetic and
  comparisons are **done (Phase D)**; what remains is the non-numeric polymorphic shapes.
- **Deferred numeric ops** — `idiv`/`mod`/`pow` (floored-div/mod correction, libm),
  float `neg` (xorpd sign-mask), `not` (logical, not bitwise). `div` is **done
  (Phase D / F3)** — `divsd`, always float. `shl`/`shr` are **done (Phase E)** — see
  below.
- ~~**`shl`/`shr` (Lua logical shifts)**~~ — **done (Phase E):** lowered to a
  branch-bracketed `cl`-shift. x86 `shl/shr reg,cl` honours only the low 6 bits of
  the count, whereas Lua's `arith.shiftLeft`/`shiftRight` are full logical shifts
  (`|count| ≥ 64 → 0`, negative count reverses direction), so `emitShift` brackets the
  hardware shift with explicit range checks: load count into rcx first (its home may
  be the dst reg), `cmp rcx,0`+`js` → negate-and-reverse, `cmp rcx,64`+`jae` →
  `xor W,W` (result 0), else the bare `cl`-shift. Uses only the dst register (or rax
  for a spilled dst) + rcx scratch. No new IR op — shl/shr stay opaque ops; only the
  native lowering was added (`nativegen.zig` + `x64.zig`). Differential-tested vs the
  tier-1a oracle across every count regime (in-range, ≥64→0, negative, INT64_MIN).
  Unlocked nsieve-bit's two shift-bearing inner loops to native (t0 139 ms → jit
  55 ms, 2.5×).
- ~~**Relax `guard_int` onto proven-`Int` derived values**~~ — **done (#1):** a
  `guard_int` on a statically-`Int` derived value (an `Int`-op-of-`Int`s) lowers to
  nothing; `proveKinds` validates it against the computed kind instead of bailing.
  Landed `(i+7)*(i+7)` and the two-accumulator loop on the native path.
- ~~**Linear-scan register allocation**~~ — **done (cut 2):** carried/invariant slots
  are register-homed across iterations, `regs[]` written only on a side-exit.
- ~~**Two-operand in-place arithmetic**~~ — **done (cut 3):** win 1 (operands read in
  place + result coalesced onto a dying operand register) closed the LuaJIT gap to
  ~1.10×; win 2 (in-place home coalescing) is implemented behind a single-snapshot
  safety predicate.
- **Sink accumulator updates below the loop-exit guard** — the recorded counted loop
  emits its back-edge `guard_true` last, so win 2 (which requires no side-exit after
  an in-place home update) never fires on it. A schedule pass that sinks pure ops
  feeding carried `exit_store`s past the last guard would unlock win 2 there (sound
  under cut-2's re-run-from-loop-header deopt model: a sunk op simply isn't computed
  on a guard-fail, and tier-0 recomputes it). Marginal here (~10% over win 1) but the
  enabler for `add acc,i`-with-no-shuffle on the canonical loop.
- **Encoder size-opts** (`test r,r` for bool guards, `xchg` for 2-cycle swaps) —
  semantically identical, smaller; currently uses `cmp r,0` / mov-through-`rcx`.
- **Per-exit identity / side traces** — cut 1/2 have a single shared deopt epilogue.
- **Proto-id stale-cache hardening** — `AnchorKey` borrows a raw `*const Proto` and
  the cache is never invalidated; a freed-then-reallocated `Proto` at the same
  address could hit a stale trace (and now stale machine code). Pre-existing in
  tier-1a; tracked as a separate task, not expanded here.
- **A wasm codegen backend** — a separate consumer of the same lowering seam.
