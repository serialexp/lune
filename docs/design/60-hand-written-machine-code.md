# 60 — Hand-written machine code: where we stop trusting the compiler (first user: the host-call entry)

**Status:** rev 2, not yet implemented. Rev 1 was reviewed by codex and
antigravity (both CHANGES REQUESTED, `docs/reviews/doc60/*-rev1.md`). Every
blocker, should-fix and nit is folded in here (§10 maps each one). Bart's
decisions so far: a C-ABI shim seam (Q2), the packed flag word in scope
(Q4), and **M2, a separate `.S` file** (Q3). Re-review of rev 2 pending.
Nothing hand-written ships yet beyond what already existed (the
`__zig_probe_stack` copy in `capi.zig` and the runtime-emitted trace
trampoline in `nativegen_mcode.zig`).
**Owner:** claude
**Last updated:** 2026-10-02

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis** (2026-10-02, doc 59 "Boundary pass vs LuaJIT/mlua"):
  four boundary fixes took a C `mh_call` from 567 to 518 instructions and
  119 to ~82 cycles. LuaJIT's `lua_pcall` does the same job in 304 / 54.
  §1 explains why more shaving in Zig won't close that gap.
- [x] **H0 rev 1 review** (codex + antigravity, both CHANGES REQUESTED;
  folded into rev 2, §10).

### Outstanding

- [ ] **H0 — re-review of rev 2** (codex + antigravity).
- [ ] **H1 — the minimal-work host call, in Zig.** The dedicated entry
  path of §5, which bypasses `callValue`'s generic dispatch for closure
  callees. It stays forever as the reference and as the non-x86-64 path.
  Includes the packed fast-path word (§5.4). Gated by the stage-1
  differential tests against today's path (§6.1). Measure it with §5.3's
  ledger.
- [ ] **H1→H3 admission decision.** Write the assembly only if H1's
  measured *cycle* gap to LuaJIT justifies it (§7). Instruction counts
  alone don't decide it.
- [ ] **H2 — the `.S` layer.** Build wiring (`Module.addAssemblyFile`),
  the offsets file with its comptime check (§3.2), the CFI convention
  (§3.3), and the shim's concrete signature (§4.2).
- [ ] **H3 — the x86-64 host-call entry** in `src/asm/hostcall_x64.S`,
  behind the stage-2 differential tests (§6.1) with H1 as the fallback.
  Record the ledger in the embed benchmark.
- [ ] **H4 — prepared calls (API addition).** `mh_prepare(callee)` caches
  the closure/proto lookup and validation for repeated same-callee calls,
  like a per-frame `update()`. Decide after H3 (Q5).
- [ ] **Open questions** (§8), each a bullet there until decided.

## 1. Why this exists

The last arc (doc 59) fixed every per-call problem a profile could point
at: a host-process `memset` hijack, store-forwarding stalls on value writes
and on the frame result, and an extra protected-call layer. The Rust call
went from 172 to ~20 ns and now beats mlua+LuaJIT. The C call is still 518
instructions and ~82 cycles against LuaJIT's 304 and 54, and no single item
left is worth more than ~20 instructions.

Where the 518 go (callgrind, x86-64-v3 build, per call to
`function id(x) return x end`, rounded):

| layer | ≈ instr | what it is |
|---|---|---|
| C API glue (`mh_call`, `runProtected`) | ~150 | prologues/epilogues, validating callee and args, parking callee/args/results for the GC, slice setup |
| `callValue` + `execWithEntry` | ~220 | reentry and depth checks, arg bind (~19 for one arg), nil-fill (~9), `CallFrame` write (~14), `ExecState` build, `runFastPath`'s nine flag loads (~20), result copy-out (~18), **register spills (~45)** |
| guest code + chain entry | ~80 | `chainEntry`, `move`, `ret` handlers |
| the probe's own loop | ~30 | |

Roughly half of that is **compiler artifact**: spills in a large
multi-path function, two prologue/epilogue pairs, argument shuffles between
layers, wide struct copies (which cost us three store-forward stalls), and
loops LLVM unrolls by four for one element. The other half is **work we
chose**: generic `callValue` dispatch (native / closure / `__call` /
varargs), validation, and nine flag checks. Shaving in Zig attacks both at
a few instructions per change and plateaus around 400–450. That's Bart's
intuition, and the table supports it.

LuaJIT's answer is `vm_pcall`/`vm_call` in `vm_x64.dasc`: hand-written
code that runs no generic code on the way in. (It does validate the
callable and can redirect to `vmeta_call`, `vm_x64.dasc:647`, so "no
checks" is not the bar.) LuaJIT's whole interpreter is hand-written, as
DynASM source that `buildvm` turns into a static object **at build time**
(`Makefile:675–688`). So as mahina closes on LuaJIT we will keep reaching
places like this, where what's left is the compiler's register allocation
and layout, not our algorithm. This doc sets out how we do hand-written
code once, so the next piece doesn't reinvent it, and uses the host-call
entry as the first case.

## 2. Goals and non-goals

Goals:
- A repeatable way to write a hot path by hand on x86-64. That means one
  mechanism, one source of truth for struct layout, one unwind/debug
  convention, and one test pattern.
- The host-call entry measurably closer to LuaJIT's 54 cycles per call
  (§5.3), with every observable behaviour unchanged (§4.3, §6).
- Every hand-written piece keeps a Zig reference implementation that stays
  in the tree, runs on every other target (wasm today), and serves as the
  test oracle.

Non-goals:
- Writing the tier-0 interpreter by hand. The doc-42 handlers musttail
  among themselves with one uniform signature, so they can't be replaced
  one at a time. Hand-writing them means a whole hand-written
  interpreter, which would get its own doc (§7).
- Other architectures. aarch64 and others get the Zig path until a profile
  on that target says otherwise.
- Replacing Zig anywhere on the strength of a hunch. §7's admission rule
  applies to every candidate, and H3 itself must pass it.
- Changing tiering behaviour. The host entry does not call `onCallEntry`
  today (guest `.call` does, `interp.zig:6327`), and H1/H3 keep it that way.

## 3. Mechanism: M2, a separate `.S` file (Bart, 2026-10-02)

The three options rev 1 weighed, kept for the record:
- **M1, Zig naked functions with inline asm.** Naked functions can't be
  called from ordinary Zig code (pinned `lib/std/lang.zig:157`). The only
  precedent is a zero-argument probe. CFI would have to be written by hand
  inside strings.
- **M3, emitted at VM start-up with `x64.zig`.** Two rev-1 claims were
  wrong. LuaJIT generates its VM at build time, not at runtime. And
  `x64.zig` already supports indexed/scaled addressing (`x64.zig:218`,
  `:362`). M3 also needs executable memory mapped at VM creation. Some
  hosts prohibit dynamic executable memory outright (consoles, iOS,
  hardened SELinux), which is a different thing from our mapper's own W^X
  discipline. Those hosts run today with the JIT off (`mh_config.jit = 2`)
  and would lose the entry. Rejected for an embeddable library.
- **M2, chosen:** a build-time `.S` file with real assembler syntax,
  normal symbols for perf/gdb/callgrind, ordinary CFI directives, and
  nothing mapped at runtime.

### 3.1 Build wiring

The pinned toolchain has `Module.addAssemblyFile(LazyPath)`
(`lib/std/Build/Module.zig:435`). The `.S` file joins the library's and
CLI's root module only when the target is x86-64. Other targets don't see
it and use the H1 path. H2 must verify, against the pinned toolchain
(Z-1), three things: that `.S` (capital) goes through the C preprocessor
so `#include` works; that the object is PIC-correct in `libmahina.a`
(RIP-relative data, no absolute relocations); and the symbol visibility
(the entry is internal to the library and is not exported from the C
API).

### 3.2 Layout: offsets come from the compiler, never from a number in the code

Zig reorders non-`extern` struct fields. `CallFrame`, `ExecState` and
`Vm` have no fixed layout, and today's disassembly shows Zig's order
differs from source order. Every offset the `.S` file uses lives in one
checked-in include, `src/asm/offsets_x64.inc`, as `.set OFF_…, N` lines.
The **target** build verifies it at comptime: a Zig file `@embedFile`s the
include, parses the `.set` lines, and compares each value with
`@offsetOf`/`@sizeOf` on the target being compiled. Any mismatch is a
compile error that prints the corrected line. A toolchain bump or a field
added to `Vm` therefore fails to build; it never miscomputes silently, and
cross-compiles check the target's layout, not the host's. An alternative
for Q7: Zig emits the constants itself as global absolute symbols, with
module-level `asm` built by `comptimePrint`, and the `.S` references them
as externs. There's then no checked-in file, but every displacement
becomes a linker-resolved disp32.

`@offsetOf` gives field *locations*, not *representations*. The `.S` code
never interprets an optional, an error union, a tagged union or a packed
struct. It reads and writes plain integers and pointers only, and anything
richer stays on the Zig side of the shim (§4.2). One exception is allowed:
`CallFrame.code_cache_gen` is a plain `u64` sentinel precisely so that
generated code can invalidate it with one store of `-1`
(`interp.zig:404–408`, doc 54 P0). The include asserts that sentinel's
value too.

### 3.3 Calling convention, unwinding, debugging

Every routine in the `.S` file is a normal SysV function: a standard
prologue, callee-saved registers preserved, `rsp` 16-byte aligned at
every call, and `.cfi_startproc`/`.cfi_endproc` with accurate
`.cfi_def_cfa_offset`/`.cfi_offset` after every push. `perf record -g`,
gdb and a crash backtrace then unwind across
`host → mh_call → entry → shim → guest → host callback` like any C code.

## 4. The seam and the state contract

### 4.1 Division of labour

The hand-written entry does only the straight-line fast work: the
fast-path check, validation, parking, binding, the frame push, and the
success copy-out. **Everything that can branch into rare or complex
handling happens in Zig**, either before the entry commits to anything or
inside the shim:
- **Pre-commit fallback.** The entry checks, in order: the fast word
  (§5.4), the callee tag and heap type (closure only; natives and
  `__call` go to Zig), the depth limit, the reentry limit, the register
  capacity, and park capacity for every value it must park. Any failure
  makes it **tail-jump to the H1 Zig entry with the original arguments,
  before any VM state is mutated**. Every rejection path, including
  invalid tags and `last_error` rendering, stays in Zig.
- **The shim** (`callconv(.c)`, Zig) builds `ExecState` (it owns its
  stack lifetime), resolves the code image through `cachedCodeFor` (which
  also sets `code_gen`), initializes `err = null`, sets the region
  context, and calls `chainEntry(.fast)`. It then handles every outcome
  other than `.finished` itself:
  - `.switch_mode` resumes the **already-pushed frame at its parked pc
    with the original stop depth** through `execWith(stop_depth)`, exactly
    as `execWithEntry` does (`interp.zig:2506`); it never re-runs the
    entry.
  - `.err` and any error out of `execWith` run the error contract of
    §4.3, then return the `mh_status`.
  - `.suspended` can't happen: the entry only runs with `suspend_ctl ==
    null`, which is a fast-word bit, and `callValue` already treats it as
    unreachable (`interp.zig:2099`, `:2201`). Host-call suspension remains
    unsupported, unchanged.

  On `.finished` it returns the `FrameResult` (one `u32`) to the entry,
  which does the copy-out and the parking.

### 4.2 The shim signature (concrete in H2)

Proposed:

```zig
fn hostcallChain(vm: *Vm, cl: *const Closure, base: usize, stop_depth: u32,
                 out_status: *mh_status) callconv(.c) u32
```

It returns the packed `FrameResult` on success, or sets `out_status` and
returns a sentinel. `@offsetOf` can't cover error unions, which is why
the status travels as a plain integer (§3.2). Handlers keep Zig's default
convention (Q2). Making them `callconv(.c)` so the entry could jump
straight into the first handler is a **separate future proposal**, not
part of this doc.

### 4.3 The state contract, ordered

The VM must end every call in a state equivalent to what today's path
produces. "Equivalent" means byte-identical **serialized artifacts**
(keyframes, effect logs) and **equal normalized runtime state**, not raw
memory: two VMs differ in pointers and padding. The comparison set is in
§6.1.

**Entry**, in order, after the pre-commit checks pass:
1. Clear the park if the VM is idle (`parkClearIfIdle`; part of doc 59
   §3.3's borrow window).
2. Park the callee and every heap-typed argument. This is required by the
   header contract: arguments "remain valid through and after" the call
   (`mahina.h:20–25`). Parameter registers can be overwritten, surplus
   non-vararg arguments are discarded, and the frame is popped, so the
   window and frame don't give that lifetime (Q1, resolved).
3. `native_reentry_depth += 1` and `final_cut = null`.
4. Bind the parameters into the window at `stack_top` and nil-fill the
   rest of the callee's registers. Vararg callees with surplus args use
   the two-region layout (`interp.zig:2166–2187`).
5. Push the frame. Write **all ten fields**: `closure`, `call_seq` (from
   `next_call_seq`, with the exhaustion check `interp.zig:2024–2026`
   preserved as a pre-commit check), `base`, `pc = 0`, `ret_dest = 0`,
   `ret_count = 0`, `varargs_base`, `varargs_count`, and the
   **invalidation of the code cache**: `code_cache = empty` and
   `code_cache_gen = -1`. Missing that last pair lets a reused frame slot
   run another closure's cached image. Then `depth += 1` and `stack_top =
   base + num_registers`.
6. Call the shim. The first dispatch prologue (GC safepoint,
   `safepoint_seq`, region observation, fault pc, anchor activation, the
   recording mirror) stays inside the unchanged chain, in its prescribed
   order (`interp.zig:2741`, `:2784`, `:2864`).

**Success exit** (`.finished`):
7. `trace.clearPendingExitAnchor()`, in the shim (`interp.zig:2496`).
8. Copy `min(count, max_results)` results out word-wise (`storeWords`).
9. `stack_top = saved_top` and `native_reentry_depth -= 1`.
10. Park each heap result, report `nresults`, return `MH_OK`.

**Error exit**, all in the shim, in this order:
11. `trace.abortRaised()` and `trace.clearPendingExitAnchor()`, today's
    errdefers (`interp.zig:2476–2477`; doc 26 D1a: a recording must not
    survive the raise).
12. `native_reentry_depth -= 1`.
13. `guestFault`: render the located message **while the faulting frames
    are live**, then for catchable errors `closeUpvaluesFrom(entry_top)`,
    `dropRegionActivationsFromDepth(entry_depth)`, restore `depth` and
    `stack_top`, and clear `pending_error` and `final_cut`. Non-catchable
    errors poison the VM (`box.fatal`) and keep their fault state
    (`capi.zig:345–359`).

## 5. First user: the host-call entry

### 5.1 The minimal work

| step | today | H1/H3 | note |
|---|---|---|---|
| fast-word check | 9 loads | 1 load + test | §5.4 |
| validate callee tag / non-null / closure type | yes | yes | anything else → Zig path |
| validate each arg tag | yes | yes | API contract |
| park-clear when idle | yes | yes | doc 59 §3.3 |
| park callee + heap args | yes | **yes** | header contract (§4.3 step 2); scalars skip it |
| generic `callValue` dispatch | yes | no | closure only; natives / `__call` → Zig |
| reentry / depth / capacity / call_seq checks | yes | yes, pre-commit | §4.1 |
| bind args + nil-fill | loops | straight-line for small counts, loop beyond | |
| `CallFrame` write | 10 fields | 10 fields | §4.3 step 5 |
| `ExecState` build + image resolve + region context | yes | yes, in the shim | |
| copy results out, word-wise | yes | yes | |
| park results | yes | yes | |
| restore `stack_top`, reentry depth, exit-anchor clear | yes | yes | |

### 5.2 Why hand-written can still win

The work above is roughly today's minus the generic dispatch and eight of
the nine flag loads. Hand-writing it removes the compiler overhead
callgrind attributes: ~45 spill instructions, the duplicated
prologues/epilogues, argument shuffling between three Zig layers, and the
loop setup for one-element binds. The shim is ordinary Zig, but it's a
small leaf-like function with a fixed job, which is the shape LLVM handles
well. Whether this wins enough is the H1→H3 measurement (§7), not
something this doc asserts.

### 5.3 The ledger (estimates; H1 and H3 replace them with measurements)

Two ledgers, every helper counted inclusively:

**Internal entry** (entry + shim, excluding guest code):

| part | ≈ instr |
|---|---|
| pre-commit checks (fast word, tags, limits, capacity, call_seq) | 15–20 |
| park-clear + park callee/args (1 heap value) | 8–12 |
| reentry/final_cut, bind 1 arg + nil-fill | 6–10 |
| frame write (10 fields) + depth/stack_top | 14–18 |
| shim: prologue, `ExecState` (11 fields, register-window addresses, image resolve, `code_gen`, region context), call into the chain, outcome switch | 30–40 |
| success exit: anchor clear, copy-out, restore, park results | 15–20 |
| **total** | **~90–120** |

**Full public crossing** = internal entry + guest code and handlers (~60
for `id`) + the host's own call and result read. That makes roughly
**~180–230 per `mh_call`**, against LuaJIT's 304 and today's 518.

Both ledgers are reported per shape, not just for `id(1)`: 0/1/4/8
arguments, 0/1/4 results, scalar vs heap-valued arguments, vararg
callees, and reentrant calls (a host function calling `mh_call`).

### 5.4 The packed fast-path word

Nine conditions gate the fast dispatch today (`runFastPath`,
`interp.zig:2555`): `suspend_ctl != null`, `record_safepoint_lines`,
`trace.isRecording()`, and six `trace.pending_*` anchors and arms. They
collapse into **one `u16` on `TraceState`**: `trace.fast_block`, with
zero meaning "fast dispatch allowed". It lives there, not on `Vm`, because
eight of the nine conditions are `TraceState`'s own. `TraceState` has no
pointer to `Vm`, and many tests build it standalone
(`trace_gate_test.zig`, `trace_replay_test.zig`), so the trace side must
never reach into the VM. `runFastPath` becomes `vm.trace.fast_block == 0`:
one load and a test, the same load the `.S` entry does.

Mutation ownership:
- **`TraceState` owns its seven bits.** Each `pending_*` field becomes
  private behind a setter/clearer pair that writes the payload and the
  bit together. `isRecording()`'s bit is set and cleared at the
  recorder's own success, abort and OOM boundaries (`trace_recorder.zig`
  resets `active` before a fallible allocation and sets it only after
  initialization, `:6071`, `:6130`), so no path can leave the bit
  disagreeing with `active`.
- **`Vm` owns its two bits** (`suspend_ctl`, `record_safepoint_lines`) and
  writes them into `vm.trace.fast_block` through `Vm` setters. That
  includes the production writes in `wasm_entry.zig:711`, which go through
  the setters instead of assigning the fields.
- **Init, restore and reset**: `TraceState.init`, keyframe restore and
  every reset path recompute the word from the fields, using one
  function, `recomputeFastBlock()`.
- **Whole-word writes only.** Every update reads, modifies and stores the
  whole `u16`. A byte-wide bit store followed by the 16-bit load would not
  store-forward (the `FrameResult` lesson, doc 59).
- **Validation.** Debug builds assert `fast_block` against the nine
  underlying conditions in `runFastPath` *and* in the shim. The `.S`
  entry's own load bypasses `runFastPath`, but every fast call passes
  through the shim, so the shim's assertion covers the hand-written path.
  A stale clear bit would skip required hooks; a stale set bit would
  strand execution in `.full`. The assertion catches both in tests.

An alternative for Q6: merge the six pending fields into one tagged
union, so "anything pending" is one byte compare and clearing them all
is one store. This is only valid if they're mutually exclusive. One site
sets the call and ret anchors exclusively (`interp.zig:4989–5004`), but
`pending_ret_cont_arm` "accumulates independently" (`trace.zig:1886`), and
no proof covers all six. Adopting the union needs that proof first.

## 6. Testing

### 6.1 Differential tests: two stages, normalized comparison

- **Stage 1 (H1).** H1 is diffed against **today's path** (`mh_call` →
  `callValue`), so that H1 and H3 can't share a bug unseen.
- **Stage 2 (H3).** The `.S` entry is diffed against H1.

Each test runs the same script and call sequence on two VMs and compares
after every call:
- results (normalized: heap values compared by identity class and
  content, not by address);
- `depth`, `stack_top`, and register contents below `stack_top`;
- `next_call_seq` and `safepoint_seq`;
- effect counters;
- the region context and region activations;
- open upvalues;
- `final_cut`;
- recorder and anchor state, including `fast_block`;
- frame code caches;
- the parked set;
- `fatal` and `last_error`;
- serialized keyframes, **byte for byte**.

The tests run in Debug and ReleaseFast.

Call shapes:
- 0..N arguments, more and fewer than the parameters;
- vararg callees with and without surplus arguments;
- multiple results and result truncation, including zero capacity;
- natives and `__call` (the fallback);
- guest errors, both catchable and non-catchable, and fatal refusal;
- re-entrant calls (a host function calling `mh_call`);
- a nested call that starts a recording and then raises;
- a GC forced during the call and after it returns;
- an overwritten heap parameter, a discarded surplus heap argument, and
  an otherwise-unrooted callee, each followed by a collection during
  execution **and after return** (the parking contract, §4.3 step 2);
- boundary inputs: an invalid tag (`0xFF`), `row_view`, a null heap
  pointer, the depth limit, register capacity, park overflow and OOM;
- frame-slot reuse after a code-image change (the cache invalidation);
- the JIT on, off, and recording (the mode-switch path).

### 6.2 Determinism and replay

`just hashgate` runs only the CLI binary. It never calls the C API, so it
is **not** coverage for this work. Add embedding-level determinism tests:
- capture keyframes around host calls and require byte-identical
  serialized artifacts between the fast entry and the reference path;
- run the record/replay modes the embedding supports today.

Callback replay and keyframes taken while host functions are registered
remain excluded, as in doc 59 (E6/E8); the exclusions are kept explicit
in the tests. The existing gates (`zig build test`, `just hashgate`, the
Rust crate tests) still run unchanged.

### 6.3 Budgets are benchmarks, not tests

The §5.3 ledgers are measured by the embed probe and the embed benchmark,
then recorded in this doc's status section (Rule #22).

## 7. When a path earns hand-written code (this applies to H3 too)

A candidate qualifies when all of these hold:
1. A profile shows it hot on general workloads (Z-6), not on one
   benchmark.
2. Its minimal-work Zig version (its "H1") exists and has been measured.
   Callgrind or perf annotation shows that what's left is mostly compiler
   artifact (spills, prologues, struct copies, alias reloads, layout).
3. Its semantics are small and stable. Logic that churns stays in Zig.
4. An A/B of the hand-written version against its Zig version shows a
   **cycle or latency** gain on representative workloads. The A/B also
   reports fallback frequency, code size, and the language suite (no
   regression elsewhere). Fewer instructions alone is not enough: doc 59
   measured an instruction cut that cost cycles through code placement.
5. It keeps the Zig reference, the differential tests, and a recorded
   budget.

Candidates to profile, in no committed order:
- table get/set fast paths, where callable as leaf routines;
- the guest→host callback trampoline (doc 59 E5: ~54 ns);
- GC mark/sweep inner loops.

The doc-42 opcode handlers are **not** piecemeal candidates (§2
non-goals). A hand-written interpreter is all or nothing, and would get
its own doc built on this one's `.S` and offsets machinery.

## 8. Open questions

- [x] **Q1: pre-parking callee and args. Keep it** (rev-1 reviews). The
  header promises arguments stay valid through and after the call
  (`mahina.h:20–25`). Natives and `__call` never root args in a frame.
  The closure window doesn't cover surplus or overwritten arguments, or
  the time after the frame pops.
- [x] **Q2: the seam is a C-ABI shim** (Bart, 2026-10-02). Its signature
  is in §4.2; handlers keep Zig's convention.
- [x] **Q3: mechanism M2, a separate `.S` file** (Bart, 2026-10-02:
  easier to inspect).
- [x] **Q4: the packed fast-path word is in scope** (Bart, 2026-10-02),
  in H1 (§5.4).
- [ ] **Q5: prepared calls (H4).** Is a new API worth it once the entry is
  ~100 instructions? Decide after H3.
- [ ] **Q6: where the fast word lives.** §5.4's default is a `u16` on
  `TraceState` with `Vm` setters for the two VM bits. The alternative is
  a single tagged union for the six pending fields, which needs a
  mutual-exclusivity proof first. Bart's call.
- [ ] **Q7: offsets mechanism.** §3.2's default is a checked-in
  `offsets_x64.inc` verified at comptime by the target build. The
  alternative is Zig-emitted absolute symbols. Bart's call.
- [ ] **Q8: verify the build assumptions at H2** (§3.1): preprocessing of
  `.S`, PIC, symbol visibility, all against the pinned toolchain.

## 9. References

- Doc 59 (the embedding API: "Boundary pass vs LuaJIT/mlua" for the
  measurements here; §3.3 rooting protocol; E6/E8 replay exclusions).
- Doc 42 (tier-0 tail-call dispatch; the handler ABI in §4.6).
- Doc 54 P0 (the plain-`u64` code-cache sentinel), doc 26 D1a (recording
  abort on raise).
- `include/mahina.h` (value lifetime contract, lines 20–25).
- `~/Projects/LuaJIT/src/vm_x64.dasc` (`vm_call`, `vm_pcall`,
  `vm_call_dispatch`), `lj_api.c` (`lua_pcall`), `lj_frame.h` + `lj_err.c`
  (the C-frame chain), `Makefile` (DynASM → `buildvm` at build time).
- `src/capi.zig` (`zigProbeStack`, the existing asm precedent),
  `src/x64.zig` and `src/nativegen_mcode.zig` (the runtime encoder and
  mapper, kept for the JIT).
- Reviews: `docs/reviews/doc60/codex-rev1.md`,
  `docs/reviews/doc60/antigravity-rev1.md`.

## 10. Rev-1 review disposition

Antigravity numbers its findings 1–11 continuously; below, B1–B4 are its
#1–#4, S5–S8 its #5–#8 and N9–N11 its #9–#11.

| finding | where addressed |
|---|---|
| codex B1 / antigravity B4: input parking is required | Q1 resolved, §4.3 step 2, §6.1 parking regressions |
| codex B2 / antigravity B1: 10 frame fields, cache invalidation, `ExecState` ownership, call_seq exhaustion | §4.1 shim, §4.3 step 5, §3.2 sentinel |
| codex B3 / antigravity B2–B3: ordered exits, `.switch_mode`, anchor clear, `abortRaised`, suspension | §4.1, §4.3 steps 7–13 |
| codex B4 / antigravity S6: fast-word mutation ownership, `TraceState` standalone | §5.4, Q6 |
| codex B5 / antigravity S8, N10: test plan, hashgate scope, boundary inputs | §6 |
| codex S1: first prologue order, no `onCallEntry` | §4.3 step 6, §2 non-goals |
| codex S2 / antigravity S5: budget incomplete | §5.3 (two inclusive ledgers, per shape) |
| codex S3 / antigravity N9: ABI, CFI, PIC, representation limits | §3.1–§3.3, §4.2 |
| codex S4 / antigravity S7: M3 claims false, executable-memory constraints | §1, §3 |
| codex S5: measured H1→H3 admission | Outstanding list, §7 rule 4 |
| codex N1: §4.2 vs settled shim | §4.2 |
| codex N2: "byte-identical" defined | §4.3 |
| antigravity N11: handlers are all-or-nothing | §2 non-goals, §7 |
