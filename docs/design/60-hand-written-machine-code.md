# 60 — Hand-written machine code: where we stop trusting the compiler (first user: the host-call entry)

**Status:** draft, not yet implemented. Nothing hand-written ships yet
beyond what already existed (the `__zig_probe_stack` copy in `capi.zig`, the
runtime-emitted frameless trampoline in `nativegen_mcode.zig`).
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

### Outstanding

- [ ] **H0 — review.** This doc, before any code.
- [ ] **H1 — the minimal-work host call, in Zig.** Settle §5.1, the work
  a host call must do, and build a dedicated entry path that does only
  that, bypassing `callValue`'s generic dispatch. It stays forever as the
  reference and the non-x86-64 path. Measure it against §5.2's budget.
- [ ] **H2 — the hand-written-code layer.** Pick the mechanism (§3),
  wire field offsets from `@offsetOf` (§4.1), and build the differential
  test harness (§6).
- [ ] **H3 — the x86-64 host-call entry.** Hand-written, behind the
  §6 differential tests, with the H1 path as fallback. Record the
  instruction budget in the embed benchmark.
- [ ] **H4 — prepared calls (API addition).** `mh_prepare(callee)` caches the
  closure/proto lookup and validation for repeated same-callee calls,
  like a per-frame `update()`. Decide after H3 whether it still pays.
- [ ] **H5 — the policy (§7) applied to the next candidate.** Each
  candidate needs its own profile first.
- [ ] **Open questions** (§8), each a bullet there until decided.

## 1. Why this exists

The last arc (doc 59) fixed every per-call problem a profile could point
at: a host-process `memset` hijack, store-forwarding stalls on value
writes and on the frame result, and an extra protected-call layer. The
Rust call went from 172 to ~20 ns and now beats mlua+LuaJIT. The C call is
still 518 instructions and ~82 cycles against LuaJIT's 304 and 54, and no
single item left is worth more than ~20 instructions.

Where the 518 go (callgrind, x86-64-v3 build, per call to
`function id(x) return x end`, rounded):

| layer | ≈ instr | what it is |
|---|---|---|
| C API glue (`mh_call`, `runProtected`) | ~150 | prologues/epilogues, validating callee and args, parking callee/args/results for the GC, slice setup |
| `callValue` | ~220 | reentry and depth checks, arg bind (~19 for one arg), nil-fill (~9), `CallFrame` write (~14), `runFastPath`'s nine flag loads (~20), result copy-out (~18), **register spills (~45)** |
| guest code + chain entry | ~80 | `chainEntry`, `move`, `ret` handlers |
| the probe's own loop | ~30 | |

Roughly half of that is **compiler artifact**: spills in a large
multi-path function, two prologue/epilogue pairs, argument shuffles
between layers, wide struct copies that cost us three store-forward
stalls, and loops LLVM unrolls by four for one element. The other half is
**work we chose**: generic `callValue` dispatch (native / closure /
`__call` / varargs), validating and parking every value, and nine flag
checks. Shaving in Zig attacks both at a few instructions per change and
plateaus around 400–450. That's Bart's intuition, and the table supports
it.

LuaJIT's answer is `vm_pcall`/`vm_call` in `vm_x64.dasc`. It is
hand-written, writes args straight into the callee's frame slots, keeps a
C-frame chain for unwinding instead of `setjmp`, and runs no generic code
on the way in. In fact LuaJIT's whole interpreter is hand-written
(DynASM). So as mahina closes on LuaJIT we will keep reaching places like
this, where what's left is the compiler's register allocation and layout,
not our algorithm. This doc sets out how we do hand-written code once,
so the next piece doesn't reinvent it, and uses the host-call entry as
the first case.

## 2. Goals and non-goals

Goals:
- A repeatable way to write a hot path by hand on x86-64. That means one
  mechanism, one source of truth for struct layout, and one test pattern.
- The host-call entry at or below LuaJIT's 304 instructions per call
  (§5.2), with determinism and replay unchanged.
- Every hand-written piece keeps a Zig reference implementation that stays
  in the tree, runs on every other target (wasm today), and serves as the
  test oracle.

Non-goals:
- Writing the tier-0 interpreter by hand. It's a candidate under §7, not
  part of this doc.
- Other architectures. aarch64 and others get the Zig path until a profile
  on that target says otherwise.
- Replacing Zig anywhere on the strength of a hunch. §7's admission rule
  applies to every candidate.

## 3. Mechanism: three ways to write it

All three are viable. Bart picks one at H2, and the rest of the doc holds
for any of them.

**M1 — Zig naked functions with inline asm.** This is what
`capi.zig`'s `zigProbeStack` already does (`callconv(.naked)` plus
`asm volatile`).
- The code is a normal symbol in `libmahina.a` and the CLI, so perf,
  gdb and callgrind see it.
- No executable memory is mapped at runtime, so it works in any host.
- Field offsets go in as comptime operands (§4.1).
- Cost: AT&T syntax inside Zig strings, no macros, and the asm-constraint
  syntax is part of the Zig surface that can churn (Z-1/Z-2: confine it to
  one file).

**M2 — a separate `.S` file assembled by the build.**
- Real assembler syntax and macros.
- Offsets must cross a file boundary: either a header generated at
  build time from `@offsetOf`, or constants in the `.S` that a comptime
  test checks against the structs.
- The build-system call for assembly files is churny build API (Z-1).

**M3 — emitted at VM init with our own encoder** (`x64.zig`, golden-byte
tested, already used for the trace trampoline). This is LuaJIT's model:
DynASM generates its VM.
- One encoder serves both the JIT and the hand-written runtime.
- Per-VM constants (the `Vm` address, offsets) can be baked in as
  immediates.
- It's the natural base if §7 ever leads to a hand-written interpreter.
- Cost: the host process needs executable pages at VM creation. Some
  embedders forbid W^X mappings, which would push them onto the Zig path.
  Perf shows `[JIT]` unless we write a perf map. And the encoder supports
  only the forms the JIT needs (no index/scale addressing yet).

## 4. Rules for any hand-written code

### 4.1 Layout comes from the compiler, never from a number in the code

Zig reorders non-`extern` struct fields. `CallFrame`, `ExecState` and
`Vm` have no fixed layout, and today's disassembly shows Zig's chosen
order differs from source order. Every field offset the hand-written code
uses comes from `@offsetOf`/`@sizeOf`:
- in M1, as an `"i"` asm operand;
- in M2, through a generated header;
- in M3, as an emitter immediate.

A comptime assertion pins any assumption the code makes beyond an offset,
such as a size, an alignment, or two fields being adjacent. A toolchain
bump or a field added to `Vm` then either recompiles correctly or fails
to build. It never miscomputes silently.

### 4.2 Calling convention at the seam

The doc-42 handlers are declared with Zig's default convention
(`HandlerFn`), which has no stable ABI. Hand-written code can't jump into
a handler. Two seams are possible:
- (a) call one `callconv(.c)` Zig shim that starts the chain, costing a
  call and some register shuffling;
- (b) declare `HandlerFn` `callconv(.c)`.

Its six arguments (`st, pc, instr, vm, tags, payloads`) already fill the
six SysV integer argument registers exactly, the doc 42 §4.6 widening.
Under (b), hand-written code could tail-jump straight into the first
handler. Whether `musttail` is still guaranteed and whether the dispatch
loses anything under `.c` is an H2 measurement (§8 Q2).

### 4.3 The state contract

The hand-written entry must leave the VM byte-identical to what the Zig
path leaves, on success and on error. That covers:
- `depth`, `stack_top` and `frames[]` contents;
- `next_call_seq`, the region context (`setRegionContext`) and its
  validity flag;
- `native_reentry_depth` and `final_cut`;
- the parked-results rooting.

The fallback condition is `runFastPath()` false: recording, a pending
anchor, a suspend cut, or line recording. Under it the entry must hand the
call to the general Zig path, exactly as `execWithEntry` does today.
Errors come back through `st.err` as a `HandlerResult`, with no `longjmp`,
so the hand-written side needs no unwinding machinery. That's simpler than
LuaJIT's C-frame chain.

## 5. First user: the host-call entry

### 5.1 The minimal work (H1 settles each line)

| step | today | minimal | note |
|---|---|---|---|
| validate callee tag / non-null | yes | yes | API contract (bad tag → `err_api`) |
| validate each arg tag | yes | yes | API contract; one compare per arg |
| park callee + args | yes | **question** | §8 Q1: once the args sit in the callee window below the raised `stack_top`, and the callee sits in `frames[].closure`, they are rooted. Parking first is only needed if something can collect between validation and the window write, and nothing allocates there. |
| park-clear when idle | yes | yes | part of the §3.3 borrow-window contract |
| generic `callValue` dispatch | yes | **no** | the entry handles a closure callee directly; natives and `__call` go to the Zig path |
| reentry/depth/stack checks | yes | yes | a few compares |
| bind args + nil-fill | loops | straight-line for small counts, loop beyond | |
| `CallFrame` write | 8 fields | 8 fields | unavoidable; stored, not vector-copied |
| `call_seq`, region context | yes | yes | determinism |
| `runFastPath` (9 loads) | yes | 1 load | needs a packed flag word (TODO item f); until then 9 loads |
| enter chain / return | via `execWithEntry` | §4.2 seam | |
| copy results out, word-wise | yes | yes | |
| park results | yes | yes | §3.3 contract |

### 5.2 The budget

| part | ≈ instr |
|---|---|
| validate + park-clear + checks | 12–18 |
| bind (1 arg) + nil-fill | 4–6 |
| frame write, call_seq, region context, depth/stack_top | 12–16 |
| fast-path check | 2–10 |
| chain entry (seam) | 5–10 |
| result copy, park, restore | 8–12 |
| **entry total** | **~45–70** |
| guest `id` + handlers | ~60 (today's ~80 less the entry share) |
| probe loop | ~30 |
| **per call** | **~135–160** |

These figures are estimates, to be replaced by measurements at H1 and H3.
H1 alone, the minimal work in Zig, should land somewhere between today's
518 and the hand-written figure. The difference between H1 and H3 measures
how much was compiler artifact, which feeds §7.

## 6. Testing

- **Differential.** A test runs the same calls through the hand-written
  entry and the H1 Zig path on two VMs built from one script. After every
  call it compares results, `depth`, `stack_top`, `next_call_seq`, the
  region context, the parked set, and the error and message on fault
  paths. The call shapes it drives:
  - arg counts 0..N, more and fewer than the params;
  - vararg callees;
  - natives and `__call` (which take the fallback);
  - errors thrown in the guest;
  - re-entrant calls (a host fn calling `mh_call`);
  - a GC forced mid-call;
  - the JIT on, off, and recording (the fallback paths).

  This is the main correctness gate; the Zig path is the oracle.
- **The existing gates** (`zig build test`, `just hashgate`, the Rust crate
  tests) run unchanged. Hashgate covers determinism.
- **The budget is a benchmark, not a test** (Rule #22). The embed probe
  records instructions and cycles per call, and that record lives in this
  doc's status section.

## 7. Going forward: when a path earns hand-written code

A candidate qualifies when all of these hold:
1. A profile shows it hot on general workloads (Z-6), not one benchmark.
2. Callgrind or perf annotation shows its cost is mostly compiler
   artifact (spills, prologues, struct copies, alias reloads, layout),
   and the work is already minimal in Zig, i.e. its H1 equivalent is done.
3. Its semantics are small and stable. Logic that churns stays in Zig.
4. It gets a Zig reference that stays, differential tests, and a recorded
   budget.

Candidates to profile, in no committed order:
- the doc-42 handlers for the hottest opcodes (dispatch is the tier-0
  ceiling; LuaJIT's interpreter is all hand-written);
- table get/set fast paths;
- the guest→host callback trampoline (doc 59 E5: ~54 ns);
- GC mark/sweep inner loops.

Each one gets its own doc. If two or more land under M1/M2 and then
outgrow them, that's the signal to revisit M3 as a shared VM generator,
LuaJIT's DynASM shape.

## 8. Open questions

- [ ] **Q1 — is pre-parking callee and args needed?** It is only needed
  if a collection can happen between validation and the window write. List
  every allocation point on that path. If there are none, rooting comes
  from the window and the frame, and the park only does its borrow-window
  job for results.
- [ ] **Q2 — the seam (§4.2).** Option (a), a C-ABI shim, or option (b),
  handlers made `callconv(.c)`. Measure (b) on the language suite first,
  because it touches every handler.
- [ ] **Q3 — mechanism (§3): M1, M2 or M3.** Bart's call.
- [ ] **Q4 — the packed fast-path word** (TODO item f). The entry's
  fast-path check drops from 9 loads to 1 only with it; Bart's call
  whether that's in scope here.
- [ ] **Q5 — prepared calls (H4).** Is a new API worth it once the entry
  itself is ~50 instructions? Decide after H3.

## 9. References

- Doc 59 (the embedding API; "Boundary pass vs LuaJIT/mlua" for the
  measurements here; §3.3 rooting protocol).
- Doc 42 (tier-0 tail-call dispatch; the handler ABI in §4.6).
- `~/Projects/LuaJIT/src/vm_x64.dasc` (`vm_call`, `vm_pcall`, `vm_cpcall`),
  `lj_api.c` (`lua_pcall`), `lj_frame.h` + `lj_err.c` (the C-frame chain
  and the unwinding that replaces `setjmp`).
- `src/capi.zig` (`zigProbeStack`: the existing naked-asm precedent),
  `src/x64.zig` and `src/nativegen_mcode.zig` (the encoder and the
  runtime-emitted trampoline: the M3 precedent).
- `TODO.md` "Embedding call boundary vs LuaJIT/mlua" (items e/f).
