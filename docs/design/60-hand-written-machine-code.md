# 60 — Hand-written machine code: where we stop trusting the compiler (first user: the host-call entry)

**Status:** rev 3, not yet implemented. Revs 1 and 2 were reviewed by codex
and antigravity (both CHANGES REQUESTED both times,
`docs/reviews/doc60/*-rev{1,2}.md`). Every rev-2 finding is folded in
(§10). Bart's decisions so far:
- a C-ABI shim seam (Q2);
- the packed flag word in scope (Q4);
- M2, a separate `.S` file (Q3);
- SysV x86-64 only, meaning Linux and macOS, with Windows recorded as a
  TODO (Q8);
- an inspectable, checked-in offsets file (Q7);
- for Q6, an audit first: §5.4 records its result.

Re-review of rev 3 pending. Nothing hand-written ships yet beyond what
already existed: the `__zig_probe_stack` copy in `capi.zig` and the
runtime-emitted trace trampoline in `nativegen_mcode.zig`.
**Owner:** claude
**Last updated:** 2026-10-03

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis** (2026-10-02, doc 59 "Boundary pass vs LuaJIT/mlua").
  Four boundary fixes took a C `mh_call` from 567 to 518 instructions and
  from 119 to ~82 cycles. LuaJIT's `lua_pcall` does the same job in 304
  instructions and 54 cycles. §1 explains why more shaving in Zig won't
  close that gap.
- [x] **H0, rev-1 and rev-2 reviews** (codex + antigravity, both CHANGES
  REQUESTED each time). Folded into rev 2 and rev 3 respectively (§10).
- [x] **Q6 audit** (2026-10-03). The six pending fields are not mutually
  exclusive, so the flag word stays a bitmask and no union replaces them
  (§5.4).

### Outstanding

- [ ] **H0: re-review of rev 3** (codex + antigravity).
- [ ] **H1: the minimal-work host call, in Zig.** This is the dedicated
  entry path of §5, which bypasses `callValue`'s generic dispatch for
  closure callees. It also includes the packed fast-path word (§5.4).
  - It stays forever as the reference, as the fallback target, and as the
    path for every target that has no `.S` entry (aarch64, Windows x64,
    wasm).
  - Gated by the stage-1 differential tests against today's path (§6.1).
  - Measured with §5.3's ledger.
- [ ] **H1→H3 admission decision.** Write the assembly only if H1's
  measured *cycle* gap to LuaJIT justifies it (§7). Instruction counts
  alone don't decide it.
- [ ] **H2: the `.S` layer.**
  - Build wiring (§3.1).
  - `src/asm/offsets_x64.inc` and its comptime check (§3.2).
  - The CFI and frame-pointer convention (§3.3).
  - The concrete wrapper, entry, shim and helper symbols (§4.2).
  - Verify the build assumptions against the pinned toolchain (§3.1).
- [ ] **H3: the SysV x86-64 host-call entry** in `src/asm/hostcall_x64.S`
  (Linux and macOS).
  - Behind the stage-2 differential tests (§6.1), with H1 as the fallback.
  - The ledger is recorded in the embed benchmark.
- [ ] **H4: prepared calls (API addition).** `mh_prepare(callee)` caches
  the closure/proto lookup and validation for repeated same-callee calls,
  like a per-frame `update()`. Decide after H3 (Q5).
- [ ] **Defer: Windows x64 entry.** Windows x64 uses a different C calling
  convention, so it runs H1 until a Windows embedder's profile asks for
  it (TODO.md).
- [ ] **Defer: aarch64 entry.** H1 covers it. It would be one more
  internal `.S` file against the same narrow contract (§4.1), with no
  change to the public symbol.
- [ ] **Open questions** (§8), each a bullet there until decided.

## 1. Why this exists

The last arc (doc 59) fixed every per-call problem a profile could point
at:
- a host-process `memset` hijack;
- store-forwarding stalls on value writes and on the frame result;
- an extra protected-call layer.

The Rust call went from 172 to ~20 ns and now beats mlua+LuaJIT. The C
call is still 518 instructions and ~82 cycles against LuaJIT's 304 and 54.
No single item left is worth more than ~20 instructions.

Where the 518 go (callgrind, x86-64-v3 build, per call to
`function id(x) return x end`, rounded):

| layer | ≈ instr | what it is |
|---|---|---|
| C API glue (`mh_call`, `runProtected`) | ~150 | prologues/epilogues, validating callee and args, parking callee/args/results for the GC, slice setup |
| `callValue` + `execWithEntry` | ~220 | reentry and depth checks, arg bind (~19 for one arg), nil-fill (~9), `CallFrame` write (~14), `ExecState` build, `runFastPath`'s nine flag loads (~20), result copy-out (~18), **register spills (~45)** |
| guest code + chain entry | ~80 | `chainEntry`, `move`, `ret` handlers |
| the probe's own loop | ~30 | |

Roughly half of that is **compiler artifact**:
- spills in a large multi-path function;
- two prologue/epilogue pairs;
- argument shuffles between layers;
- wide struct copies, which cost us three store-forward stalls;
- loops LLVM unrolls by four for one element.

The other half is **work we chose**: generic `callValue` dispatch (native,
closure, `__call`, varargs), validation, and nine flag checks. Shaving in
Zig attacks both at a few instructions per change and plateaus around
400–450. That's Bart's intuition, and the table supports it.

LuaJIT's answer is `vm_pcall`/`vm_call` in `vm_x64.dasc`: hand-written
code that runs no generic code on the way in. It still validates the
callable and can redirect to `vmeta_call` (`vm_x64.dasc:647`), so "no
checks" is not the bar. LuaJIT's whole interpreter is hand-written, as
DynASM source that `buildvm` turns into a static object **at build time**
(`Makefile:675–688`).

So as mahina closes on LuaJIT, we will keep reaching places like this,
where what's left is the compiler's register allocation and layout, not
our algorithm. This doc sets out how we do hand-written code once, so the
next piece doesn't reinvent it. The host-call entry is the first case.

## 2. Goals and non-goals

Goals:
- A repeatable way to write a hot path by hand on x86-64. That means one
  mechanism, one inspectable source of truth for struct layout, one
  unwind/debug convention, and one test pattern.
- A layering that keeps the **public API in Zig on every target**. A new
  architecture adds one internal `.S` file against a narrow, already
  validated contract. It never re-implements the public surface.
- The host-call entry measurably closer to LuaJIT's 54 cycles per call
  (§5.3), with every observable behaviour unchanged (§4.3, §6).
- Every hand-written piece keeps a Zig reference implementation that stays
  in the tree, runs on every other target, and serves as the test oracle.

Non-goals:
- **Writing the tier-0 interpreter by hand.** The doc-42 handlers musttail
  among themselves with one uniform signature, so they can't be replaced
  one at a time. Hand-writing them means a whole hand-written
  interpreter, which would get its own doc (§7).
- **Other ABIs and architectures now.** Windows x64 and aarch64 get the
  Zig path until a profile on that target says otherwise.
- **Replacing Zig on the strength of a hunch.** §7's admission rule
  applies to every candidate, and H3 itself must pass it.
- **Changing tiering behaviour.** The host entry does not call
  `onCallEntry` today (guest `.call` does, `interp.zig:6327`), and H1/H3
  keep it that way.

## 3. Mechanism: M2, a separate `.S` file (Bart, 2026-10-02)

The three options rev 1 weighed, kept for the record:
- **M1: Zig naked functions with inline asm.** Naked functions can't be
  called from ordinary Zig code (pinned `lib/std/lang.zig:157`). The only
  precedent is a zero-argument probe, and CFI would have to be written by
  hand inside strings.
- **M3: emitted at VM start-up with `x64.zig`.** Two rev-1 claims about it
  were wrong. LuaJIT generates its VM at build time, not at runtime, and
  `x64.zig` already supports indexed/scaled addressing (`x64.zig:218`,
  `:362`). M3 also needs executable memory mapped at VM creation.
  - Some hosts prohibit dynamic executable memory outright: consoles, iOS,
    hardened SELinux. That is a different thing from our mapper's own W^X
    discipline.
  - Those hosts run today with the JIT off (`mh_config.jit = 2`) and would
    lose the entry.
  - Rejected for an embeddable library.
- **M2, chosen:** a build-time `.S` file. It uses real assembler syntax,
  has normal symbols for perf, gdb and callgrind, uses ordinary CFI
  directives, and maps nothing at runtime.

### 3.1 Build wiring and targets

**Targets.** The `.S` entry is built only for x86-64 with the SysV calling
convention, meaning Linux and macOS (Q8, Bart 2026-10-03). The gate is on
the target's OS and ABI, not on the CPU architecture alone. The pinned
toolchain's `.c` calling convention is target-dependent, and Windows x64
differs (`lib/std/lang.zig:128`). Every other target compiles no assembly
and runs H1.

**Object-format differences** between ELF and Mach-O are confined to a
few macros at the top of the file:
- the C-symbol prefix (Mach-O prepends `_`);
- section directives;
- hidden-visibility spelling (`.hidden` vs `.private_extern`).

**Build API.** The pinned toolchain has `Module.addAssemblyFile(LazyPath)`
(`lib/std/Build/Module.zig:435`). It also has `addCSourceFile` with
language `.assembly_with_preprocessor` (`Module.zig:89`), which is the
fallback if `.S` doesn't go through the preprocessor. The file joins the
library's and CLI's root module only on the gated targets.

**H2 must verify against the pinned toolchain (Z-1):**
- that `#include` and `#if` work in the file;
- that the object is PIC-correct in `libmahina.a`: RIP-relative data
  only, no text relocations (checked with `readelf -r` / `otool -r` in a
  build test);
- that every symbol in the file is hidden, so none leaks from the C
  library (checked with `nm -D` / `nm -gU`).

### 3.2 Layout: an inspectable offsets file, checked by the compiler (Q7, Bart 2026-10-03)

Zig reorders non-`extern` struct fields, so `CallFrame`, `Vm` and the rest
have no fixed layout. Today's disassembly shows Zig's order differs from
source order.

Every number the `.S` file depends on lives in one checked-in,
human-readable include, `src/asm/offsets_x64.inc`, as `.set NAME, N`
lines. That covers:
- field offsets;
- struct sizes and field widths;
- `Value` tag constants;
- `HeapType` constants;
- the code-cache sentinel;
- `max_call_depth`;
- the reentry limit;
- `parked_inline.len`.

The structs it reads are `VmBox`, `Vm`, `CallFrame`, `Closure`, `Proto`,
the heap object header and `Value`. `ExecState` is not among them: it is
built in the Zig shim (§4.1).

The file is verified at comptime by the build for the target being
compiled:
- **What runs the check.** A Zig file, compiled only when the target is
  gated in (§3.1), `@embedFile`s the include and parses its `.set` lines.
  It compares each value with `@offsetOf`/`@sizeOf`/`@bitSizeOf` or the
  named constant.
- **On a mismatch,** the build stops with a compile error that prints the
  corrected line. A toolchain bump or a field added to `Vm` therefore
  fails the build. It never miscomputes silently.
- **Completeness.** Any name in the file the checker doesn't recognise
  is also a compile error, so no unchecked number can be added.
- **Which layout is checked.** Cross-compiles check the target's layout,
  not the host's. Non-gated targets (wasm, aarch64, Windows) never compile
  the checker, so their different layouts don't break them.

**Representation rule.** `@offsetOf` gives field *locations*, not
*representations*. The `.S` code reads and writes only plain integers,
pointers and the two words of a `Value`. It never writes or interprets:
- an optional;
- an error union;
- a tagged union;
- a slice;
- a packed struct (other than reading the fast word as a `u16`).

Concretely:
- **`Vm.final_cut`** (`?FinalCut`, `interp.zig:676`) is cleared by the
  shim, not the assembly. Today `callValue` clears it before the frame
  push (`interp.zig:2100`). Nothing between there and the shim reads it:
  binding, the push and the input parks don't. So the move is
  unobservable.
- **`CallFrame.code_cache`** (a slice) is **not written**. Only
  `code_cache_gen`, a plain `u64`, gets the sentinel, as one store of `-1`.
  This is exactly how the JIT's inline native push invalidates a reused
  frame slot today (`interp.zig:402–408`, doc 54 P0).
  - `cachedCodeFor` refuses to hit while the generation is the sentinel.
  - It also refuses when the registry generation itself equals the
    sentinel.
  - So a stale `code_cache` slice in a reused slot can never be used.
  - The include asserts the sentinel's value.

### 3.3 Calling convention, unwinding, debugging

Every routine in the `.S` file is a normal SysV function once it commits:
- callee-saved registers are preserved;
- `rsp` is 16-byte aligned at every call;
- `.cfi_startproc`/`.cfi_endproc` bracket each routine, with an accurate
  `.cfi_def_cfa_offset`/`.cfi_offset` after every push;
- a frame-pointer chain is kept (`push rbp; mov rbp, rsp`). So both
  `perf record --call-graph dwarf` and frame-pointer unwinding (`perf
  record -g`) walk across `host → mh_call → entry → shim → guest → host
  callback`, as do gdb and crash backtraces.

The **pre-commit checks run before the prologue**, using only the
argument registers and the caller-saved scratch registers (`rax`, `r10`,
`r11`). A failed check is therefore a bare `jmp` to the H1 Zig entry,
with every argument register and both stack arguments untouched (§4.1).
The CFI for that region is the entry-state CFI.

H2's acceptance test checks unwinding through each routine on three
paths: normal return, the pre-commit fallback, and the park helper call
(§4.3).

## 4. The seam and the state contract

### 4.1 Layers

The layering, from the host inward:

1. **`mh_call` (Zig, exported, every target).** It does the public checks
   that today's `mh_call` does first (`capi.zig:692–696`):
   - null `vm` → `.err_api`;
   - null `nresults` → `.err_api`;
   - `*nresults = 0`;
   - fatal-VM refusal (`checkFatal`).
   
   Then, on gated targets, it tail-calls the `.S` entry with the identical
   signature, through `@call(.always_tail, …)`. Elsewhere it calls H1.
   Whether `always_tail` with seven C-ABI parameters (two on the stack)
   compiles to a plain `jmp` is a Z-1 check at H2. If it can't, the cost
   becomes a full extra frame, and §5.3 and the H1→H3 decision account for
   it.
2. **The `.S` entry (internal, hidden).**
   - **Narrow contract.** `vm` and `nresults` are non-null, the VM is not
     fatal, and `*nresults` is already 0.
   - **Pre-commit checks**, all before its prologue and before any VM
     state is mutated:
     - the fast word (§5.4);
     - the callee tag and heap type: closure only; natives, `__call`
       targets and invalid values go to Zig;
     - each argument's tag, and its non-null heap pointer;
     - the arg count vs a small straight-line limit;
     - the depth limit and the reentry limit;
     - register capacity for the callee window;
     - `next_call_seq != maxInt(u64)` (today that is a `@panic`,
       `interp.zig:2025`, which H1 reproduces);
     - input park capacity: the inline slots free after the idle clear
       must hold the callee and every heap argument.
   - **Fallback.** Any failure is a `jmp` to the H1 Zig entry, which has
     the same signature and does every rejection and diagnostic exactly as
     today.
3. **The shim** (Zig, `callconv(.c)`, hidden). It runs once the frame is
   pushed. In order:
   - clears `final_cut`;
   - builds `ExecState`, which it owns on its own stack;
   - resolves the code image through `cachedCodeFor`;
   - assigns `st.code_gen` itself (`cachedCodeFor` updates only the
     frame's cache, `interp.zig:2486`, `:2652`);
   - sets `err = null`;
   - sets the region context;
   - calls `chainEntry(.fast)`.
   
   It handles every outcome other than `.finished` itself:
   - **`.switch_mode`** resumes the **already-pushed frame at its parked
     pc with the original stop depth** through `execWith(stop_depth)`,
     exactly as `execWithEntry` does (`interp.zig:2506`). It never re-runs
     the entry.
   - **`.err`, and any error out of `execWith`,** run the error contract
     of §4.3 and return its status.
   - **`.suspended` cannot happen.** The entry runs only with `suspend_ctl
     == null` (a fast-word bit), and `callValue` already treats suspension
     as unreachable (`interp.zig:2099`, `:2201`). Host-call suspension
     stays unsupported, unchanged.
4. **The park helper** (Zig, `callconv(.c)`, hidden). The entry calls it
   only when result parking runs out of inline slots (§4.3 step 10).

### 4.2 Signatures (concrete in H2; the names are proposals)

```zig
// Same signature as mh_call; the .S entry jumps here on any pre-commit failure.
fn mahina_hostcall_slow(vm: ?*VmBox, callee: mh_value, args: ?[*]const mh_value,
                        nargs: usize, results: ?[*]mh_value, max_results: usize,
                        nresults: ?*usize) callconv(.c) mh_status;

const ChainResult = extern struct { frame_result: u32, status: u32 }; // returned in rax
fn mahina_hostcall_chain(box: *VmBox, cl: *const Closure, base: usize,
                         entry_top: usize, entry_depth: u32) callconv(.c) ChainResult;

fn mahina_hostcall_park_rest(box: *VmBox, results: [*]const mh_value,
                             from: usize, count: usize) callconv(.c) mh_status;
```

**`ChainResult`** comes back whole in `rax`, so there is no out-pointer
and no stack slot.
- `status` is authoritative on every return: `MH_OK` means `frame_result`
  holds the packed `FrameResult` (`reg` in the low 16 bits, `count` in the
  high 16, as `interp.zig`'s `packed struct(u32)`, layout asserted in the
  offsets file).
- Any other value means the shim has already run the full error contract,
  and the entry only returns that status.
- **`entry_top` and `entry_depth` are passed explicitly.** For a vararg
  callee with surplus arguments, `base = entry_top + nargs`
  (`interp.zig:2176–2189`), so `base` cannot stand in for `entry_top`.
- `stop_depth` is `entry_depth + 1` and is derived in the shim.

All four symbols are hidden. `mh_call` is the only exported one.

Handlers keep Zig's default convention (Q2). Making them `callconv(.c)`,
so the entry could jump straight into the first handler, is a **separate
future proposal** and not part of this doc.

### 4.3 The state contract, ordered

The VM must end every call in a state equivalent to what today's path
produces. "Equivalent" means two things, since two VMs differ in pointers
and padding, so raw memory is not compared:
- **byte-identical serialized artifacts:** keyframes, effect logs and
  committed traces;
- **equal normalized runtime state.**

The comparison set is in §6.1.

**Entry**, in order, after the pre-commit checks pass (`.S`):
1. **Clear the park if the VM is idle** (`parkClearIfIdle`: `depth == 0`
   and `native_reentry_depth == 0`; doc 59 §3.3).
2. **Park the callee and each heap-typed argument, in argument order,**
   into the inline slots. Capacity was checked before step 1.
   - This parking is required by the header contract: arguments "remain
     valid through and after" the call (`mahina.h:20–25`).
   - Parameter registers can be overwritten, surplus non-vararg arguments
     are discarded, and the frame is popped, so the window and frame don't
     give that lifetime (Q1, resolved).
3. **`native_reentry_depth += 1`.**
4. **Bind the parameters** into the window at `stack_top`, and nil-fill
   the rest of the callee's registers. Vararg callees with surplus args
   use the two-region layout (`interp.zig:2166–2187`).
5. **Push the frame.** `call_seq = next_call_seq++`, then write the nine
   plain fields:
   - `closure` and `call_seq`;
   - `base`;
   - `pc = 0`, `ret_dest = 0` and `ret_count = 0`;
   - `varargs_base` and `varargs_count`;
   - `code_cache_gen = -1` (§3.2; `code_cache` is not written).
   
   Then `depth += 1` and `stack_top = base + num_registers`.
6. **Call the shim**, which first clears `final_cut`.
   - The first dispatch prologue stays inside the unchanged chain, in its
     prescribed order (`interp.zig:2741`, `:2784`, `:2864`): GC safepoint,
     `safepoint_seq`, region observation, fault pc, anchor activation,
     recording mirror.

**Success exit** (`status == MH_OK`), all straight-line in the `.S`
entry except the overflow call. It follows today's `runProtected`
(`capi.zig:392–407`):

7. **`trace.clearPendingExitAnchor()`.** Done in the shim before
   returning (`interp.zig:2496`).
8. **Copy the results out**, `min(count, max_results)` of them, word-wise
   (`storeWords`).
9. **Restore:** `stack_top = entry_top` and `native_reentry_depth -= 1`.
10. **Park each heap result in order** while inline slots remain.
    - The first time a slot is missing, call
      `mahina_hostcall_park_rest(box, results, i, produced)`. It parks the
      rest through the ordinary `park` (inline, then `parked_results`).
    - On OOM it does exactly what today's code does: it sets `last_error`
      and returns `.err_oom` with `*nresults` still 0. Execution has
      completed, top and reentry are restored, and the VM is **not**
      poisoned (`capi.zig:404`).
    - Slots taken by a host callback's nested API calls during the guest
      run are seen here, because capacity is checked at park time rather
      than reserved at entry. Allocation timing therefore matches today's
      path.
11. **`*nresults = produced`**, then return `MH_OK`.

**Error exit**, all in the shim, in today's order:

12. **`trace.abortRaised()` and `trace.clearPendingExitAnchor()`.** These
    are today's errdefers (`interp.zig:2476–2477`; doc 26 D1a: a recording
    must not survive the raise).
13. **`native_reentry_depth -= 1`.**
14. **`guestFault(box, entry_depth, entry_top, err)`, unchanged**
    (`capi.zig:345–359`). It renders the located message **while the
    faulting frames are live**. Then:
    - a non-catchable error sets `box.fatal` and keeps its fault state;
    - a catchable one clears `pending_error`, then
      `closeUpvaluesFrom(entry_top)` and
      `dropRegionActivationsFromDepth(entry_depth)`, then restores `depth`
      and `stack_top`, then clears `final_cut`.

## 5. First user: the host-call entry

### 5.1 The minimal work

| step | today | H1/H3 | note |
|---|---|---|---|
| null / fatal / `*nresults = 0` | yes | yes, in the Zig `mh_call` | §4.1 |
| fast-word check | 9 loads | 1 load + test | §5.4 |
| validate callee tag / non-null / closure type | yes | yes | anything else → H1 |
| validate each arg tag | yes | yes | API contract |
| park-clear when idle | yes | yes | doc 59 §3.3 |
| park callee + heap args | yes | **yes** | header contract (§4.3 step 2); scalars skip it |
| generic `callValue` dispatch | yes | no | closure only; natives / `__call` → H1 |
| reentry / depth / capacity / call_seq checks | yes | yes, pre-commit | §4.1 |
| bind args + nil-fill | loops | straight-line up to the small limit, loop beyond | |
| `CallFrame` write | 10 fields | 9 stores | `code_cache` not written (§3.2) |
| `ExecState` build + image resolve + region context | yes | yes, in the shim | |
| copy results out, word-wise | yes | yes | |
| park results | yes | yes, overflow → helper | §4.3 step 10 |
| restore `stack_top`, reentry depth, exit-anchor clear | yes | yes | |

### 5.2 Why hand-written can still win

The work above is roughly today's, minus the generic dispatch and eight of
the nine flag loads. Hand-writing it removes the compiler overhead that
callgrind attributes:
- ~45 spill instructions;
- the duplicated prologues/epilogues;
- argument shuffling between three Zig layers;
- the loop setup for one-element binds.

The shim is ordinary Zig, but it's a small leaf-like function with a fixed
job, which is the shape LLVM handles well. Whether all this wins enough is
the H1→H3 measurement (§7), not something this doc asserts.

### 5.3 The ledger (unsubstantiated estimates; H1 and H3 replace them with measurements)

Both reviews of rev 2 call these totals optimistic-to-plausible. The
estimates are kept only as a target to measure against, never as a claim.

**Internal entry**: the Zig `mh_call` wrapper, the `.S` entry and the
shim, excluding guest code. Every helper is counted inclusively.

| part | ≈ instr |
|---|---|
| Zig `mh_call` wrapper: null tests, fatal load, `*nresults = 0`, tail `jmp` | 6–10 |
| pre-commit: fast word, dependent closure→proto loads, tag/heap-type/closure tests, per-arg tag tests, depth/reentry/capacity/call_seq, park capacity | 20–28 |
| `.S` prologue/epilogue, callee-saved saves/restores, frame pointer, alignment | 10–14 |
| park-clear + park callee/args (1 heap value) | 8–12 |
| reentry, bind 1 arg + nil-fill | 5–9 |
| frame write (9 stores) + depth/stack_top | 13–16 |
| shim: prologue, `final_cut`, `ExecState` (11 fields), image resolve, `code_gen`, region context, call into the chain, outcome switch, anchor clear | 35–45 |
| success exit: copy-out, restore, park results, `*nresults` | 12–18 |
| **total** | **~110–150** |

**Full public crossing** is the internal entry, plus guest code and
handlers (~60 for `id`), plus the host's own call and result read. That
comes to roughly **~200–250 per `mh_call`**, against LuaJIT's 304 and
today's 518.

Both ledgers are reported per shape, not just for `id(1)`:
- 0, 1, 4 and 8 arguments, and beyond the straight-line limit;
- 0, 1 and 4 results;
- register windows of different sizes, since nil-fill scales with them;
- scalar vs heap-valued arguments and results;
- park overflow;
- vararg callees;
- reentrant calls (a host function calling `mh_call`).

### 5.4 The packed fast-path word

Nine conditions gate the fast dispatch today (`runFastPath`,
`interp.zig:2555`):
- two belong to `Vm`: `suspend_ctl != null` and `record_safepoint_lines`;
- seven belong to `TraceState`: `isRecording()` plus six pending fields,
  `pending_exit_anchor`, `pending_replay_anchor`, `pending_call_anchor`,
  `pending_ret_anchor`, `pending_ret_cont_arm` and
  `pending_call_head_arm`.

**Q6 audit (2026-10-03): the six pending fields are not mutually
exclusive**, so a single union cannot replace them:
- **The two arm requests outlive recordings by design.**
  `pending_ret_cont_arm` (filed by `fileRetContArm`, `trace.zig:1893`)
  and `pending_call_head_arm` (filed from the dispatcher ledger,
  `interp.zig:3495–3500`) are consumed only when a matching child trace
  **commits** (`tryArmFrameLinks`, `trace.zig:1906`). So they are pending
  for the whole recording of that child, and coexist with `isRecording()`.
  Neither setter tests the other slot, and both may be pending at once.
- **The four dispatch-prologue anchors are each guarded against only some
  of the others.**
  - The continuation arm (`trace_link.zig:184`) checks only
    `hasTrace`/`recordingBarred`.
  - `maybeArmExitSide` refuses only on the exit and replay anchors
    (`trace_link.zig:233`).
  - The prime-side replay arm checks only the replay anchor
    (`interp.zig:4712`).
  - `onCallEntry` and `onRetResume` check only `rec.active`
    (`trace.zig:3386`, `:3450`).
  - Only the probe/want transfers test call and ret together
    (`interp.zig:4980`, `:5100`).
  
  So, for example, a `pending_exit_anchor` waiting for its pc while tier-0
  executes a `ret` can gain a `pending_ret_anchor`.
  - Making even these four exclusive would add refusals, which changes
    tiering decisions. That is out of scope here: Z-6 says no behaviour
    change for a call-boundary win.

Therefore the nine conditions become **one `u16` on `TraceState`,
`trace.fast_block`**, with zero meaning "fast dispatch allowed".
`runFastPath` becomes `vm.trace.fast_block == 0`: one load and a test, the
same load the `.S` entry does. It lives on `TraceState`, which owns seven
of the nine conditions. `TraceState` has no pointer to `Vm`, and many
tests build it standalone (`trace_gate_test.zig`,
`trace_replay_test.zig`), so the trace side must never reach into the VM.

**Mutation ownership:**
- **`TraceState` owns its seven bits.**
  - **The pending fields** move into a nested `pending` struct whose
    methods (`setExitAnchor`, `clearExitAnchor`, …,
    `clearPendingExitAnchor`) write the payload and the bit together.
  - **Enforcement.** Zig can't hide fields, so the migration is enforced
    by the debug check below plus a review checklist item. Every one of
    the current 28 production write sites (`interp.zig`, `trace.zig`,
    `trace_link.zig`) and all test sites move to the methods in the same
    change.
- **The recording bit is set and cleared at the `TraceState` boundaries
  that call into the recorder, never inside `RecordingSession`.**
  `RecordingSession` keeps no link to `TraceState`, and its 12 standalone
  tests (`trace_recorder.zig:6150–6508`) stay untouched.
  - After every `TraceState` call that can change `rec.active`,
    `syncRecordingBit()` re-reads `rec.active`.
  - Those calls are: `rec.start` in `armWithPolicy`,
    `maybeStartContinuation` and `maybeStartReplaySide`, including OOM
    declines; every `recordInstr` call site, since the recorder can abort
    itself (`trace_recorder.zig:996`, `:1262`); `closeTrace`/commit,
    successful or failed; `consumeRecordingAbort`; and `abortRaised`.
  - `active` is cleared at `trace_recorder.zig:6077` and set at `:6144`.
  - H1 audits that list against the source and adds every site the audit
    finds.
- **`Vm` owns its two bits** (`suspend_ctl`, `record_safepoint_lines`) and
  writes them into `vm.trace.fast_block` through `Vm` setters. That
  includes the production writes in `wasm_entry.zig:711`, which go through
  the setters instead of assigning the fields.
- **Init, restore and reset.**
  - `TraceState.init` starts with the word at 0.
  - `TraceState` resets (cache clear, `trace_link.zig:2643–2651`)
    recompute **only the seven trace bits** and preserve the two VM bits.
  - Keyframe restore and VM init recompute all nine, using
    `Vm.recomputeFastBlock()`.
- **Whole-word writes only.** Every update reads, modifies and stores the
  whole `u16`. A byte-wide bit store followed by the 16-bit load would not
  store-forward (the `FrameResult` lesson, doc 59).
- **Validation.** Debug builds compare `fast_block` with the original
  nine-condition predicate, which stays in the tree as
  `fastPathReference()`, in three places:
  1. in `runFastPath`;
  2. in the shim, which every admitted `.S` call passes through;
  3. in `mahina_hostcall_slow` whenever it was entered by a fast-word
     rejection. The `.S` entry records the rejection reason in a
     debug-only scratch field.
  
  So a stale clear bit, which would skip required hooks, and a stale set
  bit, which would strand execution in `.full` or wrongly reject
  admission, both trip an assertion in tests.

## 6. Testing

### 6.1 Differential tests: two stages, normalized comparison

- **Stage 1 (H1).** H1 is diffed against **today's path** (`mh_call` →
  `callValue`). The reference leg uses `fastPathReference()`, the original
  nine-condition predicate, not the packed word. So H1 and the reference
  can't share a mask bug. Separately, a unit test drives every
  `TraceState`/`Vm` mutation method and asserts the word against the
  predicate after each transition.
- **Stage 2 (H3).** The `.S` entry is diffed against H1.

Each test runs the same script and call sequence on two VMs and compares
after every call:
- results, normalized: heap values are compared by identity class and
  content, not by address;
- `*nresults` and the returned status;
- `last_error` and `fatal`;
- `depth`, `stack_top`, and register contents below `stack_top`;
- `next_call_seq` and `safepoint_seq`;
- the effect counters **and the serialized effect log**;
- the region context and region activations;
- open upvalues;
- `final_cut`;
- recorder and anchor state, including `fast_block`;
- the **committed traces**, serialized;
- frame code-cache generations;
- the parked values, **in order and with multiplicity**. Duplicate parks
  consume capacity, and keyframes deliberately exclude parked roots, so
  snapshot equality can't stand in for this check;
- serialized keyframes, byte for byte.

The tests run in Debug and ReleaseFast, across the supported
tier/record/replay matrix: JIT off, tier-1 interpreter, native, and the
record and replay modes the embedding supports.

Call shapes:
- 0..N arguments, more and fewer than the parameters, beyond the
  straight-line limit;
- vararg callees with and without surplus arguments;
- multiple results and result truncation, including zero capacity;
- natives and `__call` (the fallback);
- guest errors, catchable and non-catchable; fatal refusal;
- re-entrant calls (a host function calling `mh_call`), up to the
  reentry limit and past it;
- `next_call_seq` set near `maxInt(u64)`: the entry falls back, and H1
  panics exactly as today, which is checked in a subprocess test;
- a nested call that starts a recording and then raises;
- a GC forced during the call and after it returns;
- the parking contract (§4.3 step 2): an overwritten heap parameter, a
  discarded surplus heap argument, and an otherwise-unrooted callee, each
  followed by a collection during execution **and after return**;
- park overflow on input (fallback) and on results (the helper), and a
  host callback that uses up the inline park before the outer call
  returns heap results;
- OOM in the result-park helper: `*nresults` stays 0, the VM is not
  fatal, and the next call works;
- boundary inputs: an invalid tag (`0xFF`), `row_view`, a null heap
  pointer, null `vm`/`args`/`results`/`nresults` pointers, the depth
  limit, register capacity, and OOM;
- frame-slot reuse after a code-image change (the sentinel invalidation);
- the JIT on, off and recording (the mode-switch path).

### 6.2 Determinism and replay

`just hashgate` runs only the CLI binary. It never calls the C API, so it
is **not** coverage for this work. Add embedding-level determinism tests:
- capture keyframes around host calls, and require byte-identical
  serialized artifacts between the fast entry and the reference path;
- run the record/replay modes the embedding supports today.

Callback replay and keyframes taken while host functions are registered
remain excluded, as in doc 59 (E6/E8). The exclusions are kept explicit in
the tests. The existing gates (`zig build test`, `just hashgate`, the Rust
crate tests) still run unchanged.

### 6.3 Build checks

These are H2's acceptance tests (§3.1, §3.3):
- PIC: no text relocations;
- hidden symbols: none of the internal symbols are exported;
- the unwind walk on the three paths.

### 6.4 Budgets are benchmarks, not tests

The §5.3 ledgers are measured by the embed probe and the embed benchmark,
then recorded in this doc's status section (Rule #22).

## 7. When a path earns hand-written code (this applies to H3 too)

A candidate qualifies when all of these hold:
1. **It's hot in general.** A profile shows it hot on general workloads
   (Z-6), not on one benchmark.
2. **Its Zig version has been measured.** Its minimal-work Zig version
   (its "H1") exists and has been measured. Callgrind or perf annotation
   shows that what's left is mostly compiler artifact: spills, prologues,
   struct copies, alias reloads, layout.
3. **Its semantics are small and stable.** Logic that churns stays in
   Zig.
4. **It wins on cycles.** An A/B of the hand-written version against its
   Zig version shows a **cycle or latency** gain on representative
   workloads. The A/B also reports fallback frequency, code size, and the
   language suite, with no regression elsewhere. Fewer instructions alone
   is not enough: doc 59 measured an instruction cut that cost cycles
   through code placement.
5. **It keeps its safety net.** The Zig reference stays, along with the
   differential tests and a recorded budget.

Candidates to profile, in no committed order:
- table get/set fast paths, where callable as leaf routines;
- the guest→host callback trampoline (doc 59 E5: ~54 ns);
- GC mark/sweep inner loops.

The doc-42 opcode handlers are **not** piecemeal candidates (§2
non-goals). A hand-written interpreter is all or nothing. It would get its
own doc, built on this one's `.S` and offsets machinery.

## 8. Open questions

- [x] **Q1: pre-parking callee and args. Keep it** (rev-1 reviews).
  - The header promises arguments stay valid through and after the call
    (`mahina.h:20–25`).
  - Natives and `__call` never root args in a frame.
  - The closure window doesn't cover surplus or overwritten arguments, or
    the time after the frame pops.
- [x] **Q2: the seam is a C-ABI shim** (Bart, 2026-10-02). Signatures are
  in §4.2; handlers keep Zig's convention.
- [x] **Q3: mechanism M2, a separate `.S` file** (Bart, 2026-10-02:
  easier to inspect).
- [x] **Q4: the packed fast-path word is in scope** (Bart, 2026-10-02),
  in H1 (§5.4).
- [ ] **Q5: prepared calls (H4).** Is a new API worth it once the entry is
  ~100 instructions? Decide after H3.
- [x] **Q6: where the fast word lives.** It is audited (2026-10-03, §5.4).
  The pending fields coexist, so it's a `u16` on `TraceState` with `Vm`
  setters for the two VM bits. A partial union over the four
  prologue anchors would need new refusals that change tiering, so it is
  not pursued.
- [x] **Q7: offsets mechanism.** It is a checked-in, inspectable
  `offsets_x64.inc`, verified at comptime by the gated target build (Bart,
  2026-10-03; §3.2).
- [x] **Q8: targets.** SysV x86-64 (Linux, macOS) only. Windows x64 is a
  TODO (Bart, 2026-10-03; §3.1).
- [x] **Q9: export layout.** The Zig `mh_call` stays the public symbol on
  every target and tail-calls a hidden per-architecture entry (Bart,
  2026-10-03). A port to a new architecture then never re-implements the
  public surface.
- [x] **Q10: result parking.** The assembly parks into inline slots and
  calls a Zig helper for the rest on overflow (Bart, 2026-10-03; §4.3
  step 10).
- [ ] **Q11: verify the build assumptions at H2** (§3.1, §4.1):
  preprocessing of `.S`, PIC, symbol visibility, Mach-O macros, and
  `always_tail` compiling to a plain `jmp`, all against the pinned
  toolchain.

## 9. References

- Doc 59: the embedding API. "Boundary pass vs LuaJIT/mlua" for the
  measurements here; §3.3 for the rooting protocol; E6/E8 for the replay
  exclusions.
- Doc 42: tier-0 tail-call dispatch, with the handler ABI in §4.6.
- Doc 54 P0 (the plain-`u64` code-cache sentinel) and doc 26 D1a
  (recording abort on raise).
- `include/mahina.h`: the value lifetime contract (lines 20–25) and
  `mh_call` (line 149).
- `~/Projects/LuaJIT/src/`:
  - `vm_x64.dasc` (`vm_call`, `vm_pcall`, `vm_call_dispatch`);
  - `lj_api.c` (`lua_pcall`);
  - `lj_frame.h` and `lj_err.c` (the C-frame chain);
  - `Makefile` (DynASM → `buildvm` at build time).
- `src/capi.zig`: `mh_call`, `runProtected`, `park`, `guestFault`, and
  `zigProbeStack`, the existing asm precedent.
- `src/x64.zig` and `src/nativegen_mcode.zig`: the runtime encoder and
  mapper, kept for the JIT.
- Reviews: `docs/reviews/doc60/{codex,antigravity}-rev{1,2}.md`.

## 10. Review disposition

### Rev 1 → rev 2

Antigravity numbers its findings 1–11 continuously: below, B1–B4 are its
#1–#4, S5–S8 its #5–#8, and N9–N11 its #9–#11. Codex's rev-2 review
scored this table, and rev 3 closes the items it marked partial (see the
next table).

| finding | where addressed |
|---|---|
| codex B1 / antigravity B4: input parking is required | Q1, §4.3 step 2, §6.1 |
| codex B2 / antigravity B1: frame fields, cache invalidation, `ExecState` ownership, call_seq exhaustion | §3.2, §4.1, §4.3 step 5 |
| codex B3 / antigravity B2–B3: ordered exits, `.switch_mode`, anchor clear, `abortRaised`, suspension | §4.1, §4.3 |
| codex B4 / antigravity S6: fast-word mutation ownership, standalone `TraceState` | §5.4 |
| codex B5 / antigravity S8, N10: test plan, hashgate scope, boundary inputs | §6 |
| codex S1: first prologue order, no `onCallEntry` | §4.3 step 6, §2 |
| codex S2 / antigravity S5: budget incomplete | §5.3 |
| codex S3 / antigravity N9: ABI, CFI, PIC, representation limits | §3 |
| codex S4 / antigravity S7: M3 claims false, executable memory | §1, §3 |
| codex S5: measured H1→H3 admission | §7 rule 4 |
| codex N1: §4.2 vs the settled shim | §4.2 |
| codex N2: "byte-identical" defined | §4.3 |
| antigravity N11: handlers are all-or-nothing | §2, §7 |

### Rev 2 → rev 3

Antigravity's rev-2 numbering: B1–B3 are its #1–#3, S4–S7 its #4–#7, and
N8–N10 its #8–#10.

| finding | where addressed |
|---|---|
| codex B1: assembly wrote an optional (`final_cut`), slice representation | §3.2 representation rule: `final_cut` moved to the shim; `code_cache` not written, sentinel only |
| codex B2 / antigravity B2: shim lacks `VmBox`, `entry_top`, `entry_depth`; status encoding | §4.2 signatures and `ChainResult`; §4.3 step 14 |
| codex B3 / antigravity B3: result parking after execution | Q10, §4.3 step 10, park helper with today's OOM semantics |
| codex B4 / antigravity S5: fast-word sync (VM bits on reset, recorder boundaries, rejection validation) | §5.4 ownership and validation |
| antigravity B1: null pointers, fatal VM in the entry | §4.1 layer 1: the Zig `mh_call` keeps the public checks |
| codex S1 / antigravity S4: linkage, visibility, layer ownership | §4.1, §4.2, Q9 |
| codex S2: gate on ABI not arch; unwind acceptance | §3.1, §3.3, Q8, §6.3 |
| codex S3: independent stage-1 oracle, artifacts, parking order, extra cases | §6.1 |
| codex S4: ledger optimistic, missing rows, scaling shapes | §5.3 |
| codex S5 / antigravity Q6 trade-offs: exclusivity unproven | §5.4 audit, Q6 |
| codex S6 / antigravity Q7 trade-offs | Q7 decided; §3.2 checks sizes and constants too; `.assembly_with_preprocessor` fallback noted |
| antigravity S6: checks before the prologue for a clean `jmp` fallback | §3.3, §4.1 |
| antigravity S7: offsets check on non-x86 targets | §3.2: compiled only on gated targets |
| codex N1 / antigravity N8: 7 of 9, recorder line numbers | §5.4 |
| codex N2: `cachedCodeFor` doesn't set `code_gen` | §4.1 layer 3 |
| codex N3: `guestFault` order | §4.3 step 14 (today's order verbatim) |
| codex N4: setter enforcement | §5.4 (nested struct, migration, debug check) |
| codex N5: §10 overstated | this split table |
| antigravity N9: `ExecState` in the offsets list | §3.2 struct list |
| antigravity N10: return status in `rax` | §4.2 `ChainResult` |
