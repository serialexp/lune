# 60 — Hand-written machine code: where we stop trusting the compiler (first user: the host-call entry)

**Status:** rev 5, **approved by codex and antigravity**, not yet
implemented. Revs 1–4 came back CHANGES REQUESTED; rev 5 was approved by
both, with nits only, which are folded in
(`docs/reviews/doc60/*-rev{1..5}.md`, per-finding status in §10).

Bart's decisions so far:
- a C-ABI shim seam (Q2);
- the packed flag word in scope (Q4);
- M2, a separate `.S` file (Q3);
- **Linux x86-64 only for now**, with macOS and Windows as TODOs (Q8);
- an inspectable, checked-in offsets file (Q7);
- the Zig `mh_call` wrapper, which tail-calls a hidden entry (Q9);
- park-then-helper for results (Q10);
- Q6 audited (§5.4).

- Q12, the register file and overflow park: (a), the assembly reads the
  slices directly under a stated exception (§3.2).

No design questions block H1. Nothing hand-written ships yet beyond what
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
  from 119 to ~82 cycles. LuaJIT's `lua_pcall` does the same job in 304 and
  54. §1 explains why more shaving in Zig won't close that gap.
- [x] **H0, design review** (codex + antigravity, five rounds). Rev 5
  was approved by both on 2026-10-03 (§10).
- [x] **Q6 audit** (2026-10-03; corrected in rev 4 after codex's rev-3
  review). The six pending fields can be set at the same time. So the flag
  word is a bitmask, and no union replaces them (§5.4).
- [x] **Q12 decided** (Bart, 2026-10-03): option (a). The assembly reads
  the register-file and overflow-park slices directly, under a stated
  exception to the representation rule (§3.2).

### Outstanding

- [ ] **H1 — the minimal-work host call, in Zig.** This is the dedicated
  entry path of §5. It bypasses `callValue`'s generic dispatch for closure
  callees.
  - It stays forever. It is the reference, the fallback target, and the
    path for every target without a `.S` entry (macOS, Windows, aarch64,
    wasm).
  - It includes the packed fast-path word (§5.4) and the VM-side runner
    split (§4.1).
  - Gated by the stage-1 differential tests against today's path (§6.1).
  - Measured with §5.3's ledger.
- [ ] **H1→H3 admission decision.** Write the assembly only if H1's
  measured *cycle* gap to LuaJIT justifies it (§7). Instruction counts
  alone don't decide it.
- [ ] **H2 — the `.S` layer.**
  - Build wiring (§3.1).
  - `src/asm/offsets_x64.inc` and its comptime check (§3.2).
  - The CFI and frame-pointer convention (§3.3).
  - The four internal symbols with hidden linkage (§4.2).
  - The build acceptance checks (§6.3).
  - Q11's toolchain verifications.
- [ ] **H3 — the Linux x86-64 host-call entry** in
  `src/asm/hostcall_x64.S`.
  - Behind the stage-2 differential tests (§6.1).
  - H1 is the fallback.
  - The ledger is recorded in the embed benchmark.
- [ ] **H4 — prepared calls (API addition).** `mh_prepare(callee)` caches
  the closure/proto lookup and validation for repeated same-callee calls,
  like a per-frame `update()`. Decide after H3 (Q5).
- [ ] **Defer: macOS x86-64 entry.** `libmahina` doesn't build for macOS
  today. `mh_vm_new` installs Linux-only clock and entropy sources
  (`capi.zig:414`, `:450`, `std.os.linux`). A portable C API comes first.
  Then the same SysV entry needs Mach-O macros (symbol prefix, sections,
  `.private_extern`) and a macOS build/link acceptance case (TODO.md).
- [ ] **Defer: Windows x64 entry.** Windows uses a different calling
  convention, so it runs H1 until a Windows embedder's profile asks for an
  entry (TODO.md).
- [ ] **Defer: aarch64 entry.** H1 covers it. A port would be one more
  internal `.S` against the same narrow contract (§4.1), with no change to
  the public symbol.
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
closure, `__call`, varargs), validation, and nine flag checks.

Shaving in Zig attacks both at a few instructions per change and plateaus
around 400–450. That's Bart's intuition, and the table supports it.

LuaJIT's answer is `vm_pcall`/`vm_call` in `vm_x64.dasc`: hand-written
code that runs no generic code on the way in. It does validate the callable,
and can redirect to `vmeta_call` (`vm_x64.dasc:647`), so "no checks" is
not the bar. LuaJIT's whole interpreter is hand-written, as DynASM source
that `buildvm` turns into a static object **at build time**
(`Makefile:675–688`).

So as mahina closes on LuaJIT, we will keep reaching places like this,
where what's left is the compiler's register allocation and layout, not
our algorithm. This doc sets out how we do hand-written code once, so the
next piece doesn't reinvent it. The host-call entry is the first case.

## 2. Goals and non-goals

Goals:
- **One repeatable way to write a hot path by hand on x86-64:** one
  mechanism, one inspectable source of truth for struct layout, one
  unwind/debug convention, and one test pattern.
- **The public API stays in Zig on every target.** A new target or
  architecture adds one internal `.S` file against a narrow, already
  validated contract. It never re-implements the public surface.
- **A faster host-call entry.** It should move measurably closer to
  LuaJIT's 54 cycles per call (§5.3), with every observable behaviour
  unchanged (§4.3, §6).
- **A Zig reference for every hand-written piece.** It stays in the tree,
  runs on every other target, and serves as the test oracle.

Non-goals:
- **Writing the tier-0 interpreter by hand.** The doc-42 handlers musttail
  among themselves with one uniform signature, so they can't be replaced
  one at a time. Hand-writing them means a whole hand-written
  interpreter, which would get its own doc (§7).
- **Other targets now.** macOS, Windows x64 and aarch64 get the Zig path
  (Q8).
- **Replacing Zig on the strength of a hunch.** §7's admission rule
  applies to every candidate, and H3 itself must pass it.
- **Changing tiering behaviour.** The host entry does not call
  `onCallEntry` today (guest `.call` does, `interp.zig:6327`), and H1/H3
  keep it that way. The same constraint rules out adding refusals between
  pending anchors (§5.4).

## 3. Mechanism: M2, a separate `.S` file (Bart, 2026-10-02)

The three options rev 1 weighed, kept for the record:
- **M1: Zig naked functions with inline asm.** Naked functions can't be
  called from ordinary Zig code (pinned `lib/std/lang.zig:157`). The only
  precedent is a zero-argument probe, and CFI would have to be written by
  hand inside strings.
- **M3: emitted at VM start-up with `x64.zig`.** Two rev-1 claims about it
  were wrong. LuaJIT generates its VM at build time, not at runtime. And
  `x64.zig` already supports indexed/scaled addressing (`x64.zig:218`,
  `:362`). M3 also has a problem of its own:
  - It needs executable memory mapped at VM creation.
  - Some hosts prohibit dynamic executable memory outright: consoles,
    iOS, hardened SELinux. That is a different thing from our mapper's
    own W^X discipline.
  - Those hosts run today with the JIT off (`mh_config.jit = 2`) and
    would lose the entry.
  
  Rejected for an embeddable library.
- **M2, chosen:** a build-time `.S` file. It has real assembler syntax,
  normal symbols for perf/gdb/callgrind, and ordinary CFI directives, and
  nothing is mapped at runtime.

### 3.1 Build wiring and targets

**Targets.** The `.S` entry is built only for **Linux x86-64** (Q8, Bart
2026-10-03). The gate is the target's OS together with its ABI, not the
CPU architecture alone. The pinned toolchain's `.c` calling convention is
target-dependent, and Windows x64 differs (`lib/std/lang.zig:128`). Every
other target compiles no assembly and runs H1.

The file is written for SysV and ELF. The few object-format-specific
directives sit behind macros at the top, so a later macOS port only
changes those: the symbol prefix, sections, and hidden visibility.

**Build API.** The pinned toolchain has `Module.addAssemblyFile(LazyPath)`
(`lib/std/Build/Module.zig:435`), and `addCSourceFile` with language
`.assembly_with_preprocessor` (`Module.zig:89`). The second is the fallback
if a `.S` file doesn't go through the preprocessor. The file joins the
library's and CLI's root module only on the gated target.

### 3.2 Layout: an inspectable offsets file, checked by the compiler (Q7, Bart 2026-10-03)

Zig reorders non-`extern` struct fields. `CallFrame`, `Vm` and the rest
have no fixed layout, and today's disassembly shows Zig's order differs
from source order.

**The file.** Every number the `.S` file depends on lives in one
checked-in, human-readable include, `src/asm/offsets_x64.inc`, as `.set
NAME, N` lines:
- **field offsets**, from `@offsetOf`:
  - `VmBox.vm`;
  - the `Vm` fields used, including `trace` and
    `TraceState.fast_block`, plus the Q12 fields below;
  - all nine plain `CallFrame` fields;
  - the `Closure` proto pointer;
  - the `Proto` fields `num_params`, `num_registers` and `is_vararg`;
  - the heap object header type byte;
- **sizes and widths**: `@sizeOf(CallFrame)`, which is the frame-array
  stride, `@sizeOf(Value)`, and the size and width of each field read;
- **alignments** that the code relies on for `Vm`, `CallFrame` and the
  park array;
- **constants**:
  - the `Value` tag numbers and the closure `HeapType`;
  - `CODE_CACHE_GEN_INVALID`;
  - `max_call_depth`, `max_native_reentry` (`interp.zig:139`) and
    `parked_inline.len`;
  - the straight-line argument limit (§4.1);
- **`FrameResult`**: its size, and the **bit offsets** of `reg` (0) and
  `count` (16), checked with `@bitOffsetOf`;
- **`ChainResult`**: its size and member offsets (§4.2).

**The check.** The file is verified at comptime by the build for the
target being compiled:
- **What runs it.** A Zig file, compiled only when the target is gated in
  (§3.1), `@embedFile`s the include and parses its `.set` lines.
- **What it compares.** Each value against the corresponding
  `@offsetOf`/`@sizeOf`/`@alignOf`/`@bitOffsetOf` result or named
  constant.
- **On a mismatch** it's a compile error that prints the corrected line.
  A name the checker doesn't know is also a compile error, so no unchecked
  number can enter the file.
- **Layout drift is caught.** A toolchain bump or a field added to `Vm`
  fails the build; it never miscomputes silently.
- **Only the gated target is checked.** Other targets never compile the
  checker.
- **No Debug-only fields.** The file contains no field that exists only
  in Debug builds, so one set of offsets serves Debug and ReleaseFast. The
  rejection reason in §5.4 lives in a register, not a field. The checker
  runs in both modes, so a mode-dependent layout would fail the build.

**Representation rule.** `@offsetOf` gives field *locations*, not
*representations*. The `.S` code reads and writes only plain integers,
pointers and the two words of a `Value`. It never writes or interprets any
of these:
- an optional;
- an error union;
- a tagged union;
- a slice, except the three named in Q12 below;
- a packed struct, other than reading the fast word as a `u16` and the
  checked bit offsets of `FrameResult`.

The resulting placements:
- **`Vm.final_cut`** (`?FinalCut`, `interp.zig:676`) is cleared by the
  shim, not the assembly (§4.1). That's sound for the assembly's own
  push. **H1 differs.** It uses the existing `pushFrameTrusted`, which
  asserts `final_cut == null` (`interp.zig:2021`), so H1 clears it before
  the push, exactly where `callValue` does today (`interp.zig:2100`).
  Between the assembly's push and the shim, nothing reads `final_cut`.
- **`CallFrame.code_cache`** (a slice) is **not written**. Only
  `code_cache_gen`, a plain `u64`, gets the sentinel, as one store of `-1`.
  This is exactly how the JIT's inline native push invalidates a reused
  frame slot today (`interp.zig:402–408`, doc 54 P0). A frame whose
  `code_cache_gen` is the sentinel never matches the registry's live
  generation, so `cachedCodeFor` misses and refills: a stale
  `code_cache` slice in a reused slot is never used. (The separate rule
  that refuses both hits and fills applies when the **registry**
  generation itself equals the sentinel, `interp.zig:2652`.)

**Q12 — the register file and the overflow park. Decided: (a)** (Bart,
2026-10-03). Zig's internals change only when the pinned toolchain
(`.zig-version`) changes, so a toolchain bump is the known, deliberate
point at which this layout could move. Then the executable checks below
run as part of the bump, along with the comptime offsets check. Option
(b) is kept below for the record.

The entry must reach five things:
- the register file's tag and payload base pointers (`Vm.tags`,
  `Vm.payloads`, both slices, `interp.zig:573–574`);
- its capacity (`regCapacity()` is `payloads.len`, `interp.zig:1080`);
- whether the overflow park is empty, so the idle clear can empty it
  (`parked_results`, an `ArrayList`, `interp.zig:803`).

The register file is fixed-size and never reallocated
(`interp.zig:570–572`). Today's idle clear empties `parked_results` with
`clearRetainingCapacity()` (`capi.zig:313–318`).

- **(a) A stated slice exception (chosen).** The representation rule
  allows exactly this, and nothing more:
  - reading the pointer and length of `Vm.tags` and `Vm.payloads`;
  - reading `parked_results.items.len`;
  - writing `parked_results.items.len = 0`, which is what
    `clearRetainingCapacity()` does.
  - **The checker can't verify this at comptime.** `@offsetOf` can't
    look inside a slice: `@offsetOf([]u8, "ptr")` is a compile error. The
    pinned compiler also rejects `@bitCast` from a slice (codex rev-4
    probe), and pointer type info carries no physical component offsets
    (`lib/std/lang.zig:597`).
  - **So the verification is executable instead:**
    - a unit test in `zig build test` on the gated target reads the
      memory of a known `[]u8`, `[]u64` and `[]Value`, and of an
      `ArrayList(Value)`'s `items`, through `@as(*const [2]usize,
      @ptrCast(&s))`. It asserts that the pointer is word 0 and the
      length word 1;
    - the slice must be a runtime value (`var s`, or its address
      escaped). The pinned compiler refuses that pointer cast at
      comptime, because a slice has no well-defined layout (antigravity
      rev-5 probe);
    - the same check runs once in `mh_vm_new` on the gated target, Debug
      and ReleaseFast. A mismatch is a hard panic, not a silent
      miscompute.
    
    The offsets file records only the outer field offsets and
    `@sizeOf([]T) == 16`, which comptime *can* check.
  - **The cost.** The assembly then depends on Zig's slice layout and on
    `ArrayList`'s field names, both of which can churn (Z-2). The checks
    catch a change; they don't make one free, and the slice-order check
    runs at test time and VM creation, not at compile time.
  - **Where that cost lands.** Those internals move only with a
    toolchain bump. The bump's checklist therefore includes the gated
    `zig build test` run, which covers the slice-layout unit test and the
    offsets check. It also reviews `ArrayList`'s `items`/`clearRetainingCapacity`
    for semantic changes, which no layout check can see.
- **(b) Plain fields on `Vm` (not chosen).** Add `reg_tags: [*]u8`, `reg_payloads:
  [*]u64` and `reg_capacity: usize`. They are set once where the register
  file is allocated; they never change, since the file is never
  reallocated. Add `parked_overflow_len: usize`, the same width as the
  `ArrayList` length it mirrors. `park` updates it only after a
  successful append, and `parkClearIfIdle` zeroes it.
  - The assembly reads only plain pointers and integers. Its idle clear
    zeroes `parked_inline_len`. When `parked_overflow_len != 0` it falls
    back to H1 instead, so emptying the `ArrayList` stays in Zig.
  - That case is rare: it needs a previous call that parked more than six
    values.
  - Debug builds assert each mirror against its slice at every entry.

### 3.3 Calling convention, unwinding, debugging

**The SysV convention.** Every routine in the `.S` file is a normal SysV
function once it commits:
- callee-saved registers are preserved;
- `rsp` is 16-byte aligned at every call;
- `.cfi_startproc`/`.cfi_endproc` bracket each routine, with accurate
  `.cfi_def_cfa_offset`/`.cfi_offset` after every push;
- the `rbp` frame-pointer chain is kept.

The **pre-commit checks run before the prologue**, using only the
argument registers and the caller-saved scratch registers (`rax`, `r10`,
`r11`). A failed check is therefore a bare `jmp` to the H1 Zig entry. The
argument registers and both stack arguments are untouched. That stretch
of code is described by the entry-state CFI.

**The resulting stacks.** The Zig `mh_call` *tail-calls* the entry, so
it leaves no frame. The fallback is a pre-prologue `jmp`, so the entry
leaves no frame on that path either. The physical stack on each path:

| path | frames, outermost first |
|---|---|
| normal, inside guest code | `host → mahina_hostcall_entry → mahina_hostcall_chain → runPushedFrame (if not inlined) → handlers` |
| normal, inside a host callback | the same `→ … → host callback` |
| pre-commit fallback | `host → mahina_hostcall_slow → …` |
| result-park overflow | `host → mahina_hostcall_entry → mahina_hostcall_park_rest` (the chain has returned) |

**Unwinding is tested per path, against exactly those frames** (§6.3):
- **DWARF unwinding** (`perf record --call-graph dwarf`, gdb). The Zig
  modules are built with `unwind_tables = .async`
  (`Build/Module.zig:214`). The `.S` file carries its CFI, and the host
  fixture is compiled with `-funwind-tables`.
- **Frame-pointer unwinding** is tested only in a build where everything
  on the stack keeps `rbp`:
  - the Zig modules (`omit_frame_pointer = false`, `Module.zig:229`);
  - the host fixture and its callbacks (`-fno-omit-frame-pointer`).
  
  Keeping `rbp` in the assembly alone doesn't make the other frames
  walkable, so the test states those build settings explicitly.

## 4. The seam and the state contract

### 4.1 Layers

From the host inward:

1. **`mh_call`** (Zig, `capi.zig`, exported, every target). It does the
   public checks that today's `mh_call` does first (`capi.zig:692–696`):
   - null `vm` → `.err_api`;
   - null `nresults` → `.err_api`;
   - `*nresults = 0`;
   - fatal-VM refusal (`checkFatal`).
   
   It then **normalizes `max_results` to 0 when `results` is null**. Today
   that already means "no output buffer" (`resultsSlice`,
   `capi.zig:681–686`), so the internal layers never see a null
   `results` with a nonzero length.
   
   Then it hands off:
   - on the gated target, it tail-calls the `.S` entry with the identical
     signature (`@call(.always_tail, …)`);
   - elsewhere, it calls H1.
   
   If the pinned toolchain can't compile that `always_tail` (seven C-ABI
   parameters, two on the stack), it's a **compile error**, not a silent
   extra frame. In that case, falling back to an ordinary call means
   changing the call modifier on purpose and revisiting Q9 and §5.3
   (Q11).
2. **`mahina_hostcall_entry`** (`.S`, hidden). Its narrow contract:
   - `vm` and `nresults` are non-null;
   - the VM is not fatal;
   - `*nresults` is already 0;
   - `results` is non-null whenever `max_results > 0`.
   
   **Pre-commit checks**, all before its prologue and before any VM state
   is mutated:
   - the fast word (§5.4);
   - the callee tag and heap type: closure only. Natives, `__call`
     targets and invalid values go to H1;
   - `nargs <= ARGS_MAX`, the straight-line limit, 8 (the Rust crate's
     inline `ArgBuf` size). **More arguments fall back to H1**; the
     assembly has no "loop beyond";
   - `args != null` when `nargs > 0`. That check comes before any
     argument load;
   - each argument's tag, and its non-null heap pointer;
   - the depth limit and the reentry limit;
   - register capacity for the callee window;
   - `next_call_seq != maxInt(u64)`. Today that is a `@panic`
     (`interp.zig:2025`), which H1 reproduces;
   - input park capacity: the inline slots free after the idle clear must
     hold the callee and every heap argument;
   
   Any failure is a `jmp` to `mahina_hostcall_slow`, which has the same
   signature and does every rejection and diagnostic exactly as today.
3. **The runner, split across the module boundary.** `ExecState`,
   `cachedCodeFor`, `execWith` and `chainEntry` are private to
   `interp.zig`. `VmBox`, `guestFault` and the C types are private to
   `capi.zig`. So the shim is two functions:
   - **`Vm.runPushedFrame(entry_depth, base) Error!FrameResult`** (Zig,
     `interp.zig`, `pub`, ordinary Zig convention). It is VM-owned and has
     no C-API dependency. `base` is passed in, as `execWithEntry` takes it
     today (`interp.zig:2475`), so `ExecState` is built without a
     dependent load through `frame.base`.
     
     **It owns `native_reentry_depth` on both edges:**
     `native_reentry_depth += 1` with a paired `defer … -= 1`, the same
     `defer` (not `errdefer`) that `callValue` uses
     (`interp.zig:2101–2103`). Neither the `.S` entry nor H1 touches the
     counter; the entry only *reads* it for the pre-commit limit check. Two
     things therefore match today:
     - nested API calls made from host callbacks during the run see the
       incremented value, so they don't clear the park;
     - the decrement happens before `guestFault` (error) or before result
       parking (success).
     
     In order, it:
     - clears `final_cut`;
     - builds `ExecState`, which it owns on its own stack;
     - resolves the image through `cachedCodeFor`;
     - assigns `st.code_gen` itself (`cachedCodeFor` updates only the
       frame's cache, `interp.zig:2486`, `:2652`);
     - sets `err = null`;
     - sets the region context;
     - **picks the dispatch mode exactly as `execWithEntry` does**
       (`interp.zig:2478`):
       - if `runFastPath()`, it calls `chainEntry(.fast)`;
       - otherwise it runs `execWith(stop_depth)`, which dispatches
         `.full`, so the recording and anchor hooks guarded by `.full`
         (`interp.zig:2880`) fire.
       
       Calls admitted by the `.S` entry always take the first branch,
       since the fast word was zero at admission. H1 receives the
       fast-word rejections and takes the second.
     
     It handles the outcomes like this:
     - **`.finished`** → `clearPendingExitAnchor()`, then return the
       `FrameResult`.
     - **`.switch_mode`** resumes the **already-pushed frame at its parked
       pc with the original stop depth** through `execWith(stop_depth)`,
       as `execWithEntry` does (`interp.zig:2506`). It never re-runs the
       entry.
     - **Errors** run today's two errdefers, which execute as
       `abortRaised()` then `clearPendingExitAnchor()`
       (`interp.zig:2476–2477`). Zig runs errdefers in reverse
       declaration order, so they are declared in that reverse order, as
       today. The reentry `defer` runs too, and the error is returned.
     - **`.suspended` cannot happen.** Both branches run only with
       `suspend_ctl == null`. For the `.S` entry that is a fast-word bit.
       For H1, `callValue`'s assertion (`interp.zig:2099`) moves into
       `runPushedFrame`. `callValue` treats suspension as unreachable
       (`interp.zig:2201`).
     
     **H1 uses this same function for closure callees**, after its own
     Zig push. So H1 and H3 differ only in the push and copy-out, not in
     the run. Natives and `__call` keep going through `callValue`
     unchanged.
   - **`mahina_hostcall_chain`** (Zig, `capi.zig`, `callconv(.c)`, hidden
     export). It calls `box.vm.runPushedFrame(entry_depth, base)`. On an
     error it calls `guestFault(box, entry_depth, entry_top, err)` (§4.3
     step 14) and returns that status.
4. **`mahina_hostcall_park_rest`** (Zig, `capi.zig`, `callconv(.c)`,
   hidden export). The entry calls it only when result parking runs out of
   inline slots (§4.3 step 10).

### 4.2 Symbols and signatures (the names are proposals)

```zig
// capi.zig — the only exported symbol (unchanged signature).
pub export fn mh_call(vm: ?*VmBox, callee: mh_value, args: ?[*]const mh_value, nargs: usize,
                      results: ?[*]mh_value, max_results: usize, nresults: ?*usize) mh_status;

// hostcall_x64.S, declared in Zig for the tail call. Hidden.
extern fn mahina_hostcall_entry(vm: ?*VmBox, callee: mh_value, args: ?[*]const mh_value,
                                nargs: usize, results: ?[*]mh_value, max_results: usize,
                                nresults: ?*usize) callconv(.c) mh_status;

// capi.zig, all three @export-ed with .visibility = .hidden (the .S references them).
fn mahina_hostcall_slow(/* same seven parameters as mh_call */) callconv(.c) mh_status;

const ChainResult = extern struct { status: u32, frame_result: u32 }; // whole in rax: status = eax
fn mahina_hostcall_chain(box: *VmBox, base: usize, entry_top: usize,
                         entry_depth: u32) callconv(.c) ChainResult;

fn mahina_hostcall_park_rest(box: *VmBox, results: ?[*]const mh_value,
                             from: usize, produced: usize) callconv(.c) mh_status;
```

**Linkage.** `callconv(.c)` alone creates no linkable symbol.
- The three Zig functions the assembly calls are emitted with
  `@export(&f, .{ .name = "…", .visibility = .hidden })`.
- The `.S` file marks its own entry `.hidden`. It also declares
  `.hidden` on each of its three **undefined references**, so the
  hidden-visibility check in §6.3 holds per object for references as
  well as definitions.
- All references are RIP-relative or direct `call`/`jmp`; the `.S` file
  takes no absolute addresses.
- `mh_call` stays the only default-visibility symbol.

**`ChainResult` field order.** `status` comes first, so on an error the
status is already in `eax` and the entry only restores and returns; on
success the entry reads `frame_result` from the upper half of `rax`.

**`ChainResult` encoding.** `status` is authoritative on every return:
- **`MH_OK`**: `frame_result` holds the packed `FrameResult`, with `reg`
  in bits 0–15 and `count` in bits 16–31. Both bit offsets are checked in
  the offsets file.
- **Anything else**: the error contract has already run, and the entry
  only restores its callee-saved registers and returns that status.

**`entry_top` is passed explicitly.** For a vararg callee with surplus
arguments, `base = entry_top + nargs` (`interp.zig:2176–2189`), so `base`
cannot stand in for `entry_top`. `stop_depth` is `entry_depth + 1`,
derived in `runPushedFrame`.

Handlers keep Zig's default convention (Q2). Making them `callconv(.c)`,
so the entry could jump straight into the first handler, is a **separate
future proposal**, not part of this doc.

### 4.3 The state contract, ordered

The VM must end every call in a state equivalent to what today's path
produces. Two VMs differ in pointers and padding, so raw memory is not
compared. "Equivalent" means:
- **byte-identical serialized artifacts**: keyframes, effect logs and
  committed traces;
- **equal normalized runtime state**, compared over the set in §6.1.

**Entry**, in order, after the pre-commit checks pass (`.S`):
1. **Clear the park if the VM is idle**, meaning `depth == 0` and
   `native_reentry_depth == 0` (doc 59 §3.3). That zeroes
   `parked_inline_len` and `parked_results.items.len`, matching
   `parkClearIfIdle` (Q12 (a)).
2. **Park the callee and each heap-typed argument, in argument order,**
   into the inline slots. Capacity was checked before step 1.
   - This is required by the header contract: arguments "remain valid
     through and after" the call (`mahina.h:20–25`).
   - Nothing else gives that lifetime. Parameter registers can be
     overwritten, surplus non-vararg arguments are discarded, and the
     frame is popped (Q1).
3. **Capture `entry_top = stack_top` and `entry_depth = depth`** into
   callee-saved registers, before anything below changes them. The
   reentry increment is not done here: `runPushedFrame` owns it (§4.1).
4. **Bind the parameters** into the window at `stack_top`, and nil-fill
   the rest of the callee's registers. Vararg callees with surplus
   arguments use the two-region layout (`interp.zig:2166–2187`).
5. **Push the frame.** Set `call_seq = next_call_seq++`, then write the
   nine plain fields:
   - `closure` and `call_seq`;
   - `base` and `pc = 0`;
   - `ret_dest = 0` and `ret_count = 0`;
   - `varargs_base` and `varargs_count`;
   - `code_cache_gen = -1` (§3.2).
   
   Then `depth += 1` and `stack_top = base + num_registers`.
6. **Call `mahina_hostcall_chain(box, base, entry_top, entry_depth)`.**
   Inside it, `runPushedFrame`:
   - increments `native_reentry_depth`;
   - clears `final_cut`;
   - builds `ExecState`;
   - picks the dispatch mode (§4.1).
   
   The first dispatch prologue stays inside the unchanged chain, in its
   prescribed order (`interp.zig:2741`, `:2789`, `:2864`): GC safepoint,
   `safepoint_seq`, region observation, fault pc, anchor activation,
   recording mirror.

**Success exit** (`status == MH_OK`). This is straight-line in the `.S`
entry, except for the overflow call, and it mirrors today's
`runProtected` (`capi.zig:392–407`):
7. The anchor clear and the reentry decrement have already run, in
   `runPushedFrame`.
8. **Copy the results out:** `produced = min(count, max_results)` results,
   word-wise (`storeWords`). `produced` is this value everywhere below,
   never the callee's raw `count`.
9. **Restore:** `stack_top = entry_top`.
10. **Park each heap result among `results[0..produced]`, in order,**
    while inline slots remain. The first time a slot is missing, call
    `mahina_hostcall_park_rest(box, results, i, produced)`. It parks the
    rest through the ordinary `park` (inline, then `parked_results`).
    - **On OOM** it does exactly what today's code does (`capi.zig:404`):
      `last_error` is set, `.err_oom` is returned, and `*nresults` stays
      0. Execution has completed and top and reentry are restored, and
      the VM is **not** poisoned.
    - **Slots taken during the call are seen here.** A host callback's
      nested API calls can use up slots during the guest run. Because
      capacity is checked at park time rather than reserved at entry, the
      allocation timing matches today's.
11. **Report:** `*nresults = produced`, then return `MH_OK`.

**Error exit**, in today's order:
12. **`abortRaised()` and `clearPendingExitAnchor()`** (in
    `runPushedFrame`). Doc 26 D1a: a recording must not survive the
    raise.
13. **`native_reentry_depth -= 1`**, the `defer` in `runPushedFrame`.
14. **`guestFault(box, entry_depth, entry_top, err)`, unchanged** (in
    `mahina_hostcall_chain`, `capi.zig:345–359`). It renders the located
    message **while the faulting frames are live**. Then:
    - **Non-catchable:** it sets `box.fatal` and keeps the fault state.
    - **Catchable:** it clears `pending_error`, closes upvalues from
      `entry_top`, drops region activations from `entry_depth`, restores
      `depth` and `stack_top`, and clears `final_cut`.

## 5. First user: the host-call entry

### 5.1 The minimal work

| step | today | H1/H3 | note |
|---|---|---|---|
| null / fatal / `*nresults = 0` / null-`results` normalization | yes | yes, in the Zig `mh_call` | §4.1 |
| fast-word check | 9 loads | 1 load + test | §5.4 |
| validate callee tag / non-null / closure type | yes | yes | anything else → H1 |
| `args` non-null, each arg tag | yes | yes | > 8 args → H1 |
| park-clear when idle | yes | yes | doc 59 §3.3 |
| park callee + heap args | yes | **yes** | header contract (§4.3 step 2); scalars skip it |
| generic `callValue` dispatch | yes | no | closure only; natives / `__call` → H1 |
| reentry / depth / capacity / call_seq checks | yes | yes, pre-commit | §4.1 |
| bind args + nil-fill | loops | ≤ 8 args straight-line; nil-fill loops over `num_registers` | |
| `CallFrame` write | 10 fields | 9 stores | `code_cache` not written (§3.2) |
| `ExecState` build + image resolve + region context | yes | yes, in `runPushedFrame` | |
| copy results out, word-wise | yes | yes | |
| park results | yes | yes, overflow → helper | §4.3 step 10 |
| restore `stack_top`, reentry depth, exit-anchor clear | yes | yes | |

### 5.2 Why hand-written can still win

The work above is roughly today's, minus the generic dispatch and eight of
the nine flag loads. Hand-writing it removes the overhead callgrind
attributes to the compiler:
- ~45 spill instructions;
- the duplicated prologues and epilogues;
- the argument shuffling between three Zig layers;
- the loop setup for one-element binds.

`runPushedFrame` is ordinary Zig, but it's a small function with a fixed
job, which is the shape LLVM handles well. Whether this wins enough is
the H1→H3 measurement (§7), not something this doc asserts.

### 5.3 The ledger (unsubstantiated estimates; H1 and H3 replace them with measurements)

Both reviews call these totals unproven. They're kept only as a target to
measure against, never as a claim.

**Internal entry**: the Zig `mh_call`, the `.S` entry,
`mahina_hostcall_chain` and `runPushedFrame`, without guest code. Every
helper is counted inclusively.

| part | ≈ instr |
|---|---|
| Zig `mh_call`: null tests, fatal load, `*nresults = 0`, `results` normalization, tail `jmp` | 8–12 |
| pre-commit: fast word, dependent closure→proto loads, tag/heap-type/closure tests, `args`/count, per-arg tag tests, depth/reentry/capacity/call_seq, park capacity | 22–30 |
| `.S` prologue/epilogue, callee-saved saves/restores, frame pointer, alignment, values kept live across the chain call | 12–16 |
| park-clear + park callee/args (1 heap value) | 8–12 |
| capture `entry_top`/`entry_depth`, bind 1 arg + nil-fill | 5–9 |
| frame write (9 stores) + depth/stack_top | 13–16 |
| `mahina_hostcall_chain` + `runPushedFrame`: two prologues, reentry increment/decrement, `final_cut`, fast-path mode check, `ExecState` (11 fields), image resolve, `code_gen`, region context, call into the chain, outcome switch, anchor clear | 44–60 |
| success exit: copy-out, restore, park results, `*nresults` | 12–18 |
| **total** | **~125–175** |

If LLVM inlines `runPushedFrame` into `mahina_hostcall_chain`, the second
prologue disappears.

**Full public crossing** = the internal entry, plus guest code and
handlers (~60 for `id`), plus the host's own call and result read. That's
roughly **~215–265 per `mh_call`**, against LuaJIT's 304 and today's 518.

Both ledgers are reported per shape, not just for `id(1)`:
- 0, 1, 4 and 8 arguments, and 9 (the fallback cost);
- 0, 1 and 4 results;
- register windows of different sizes, since nil-fill scales with them;
- scalar vs heap-valued arguments and results;
- park overflow;
- vararg callees;
- reentrant calls.

### 5.4 The packed fast-path word

Nine conditions gate the fast dispatch today (`runFastPath`,
`interp.zig:2555`):
- **two owned by `Vm`**: `suspend_ctl != null` and
  `record_safepoint_lines`;
- **seven owned by `TraceState`**: `isRecording()` plus six pending
  fields:
  - `pending_exit_anchor`;
  - `pending_replay_anchor`;
  - `pending_call_anchor`;
  - `pending_ret_anchor`;
  - `pending_ret_cont_arm`;
  - `pending_call_head_arm`.

**Q6 audit (2026-10-03, corrected in rev 4): the six pending fields are
not mutually exclusive, so a single union cannot replace them.** The
producers and consumers of each field are below. The guards listed are
the ones that bear on coexistence: the recording state and the other
pending fields. Every producer has further guards (config, varargs,
bounds, patch collisions, existing traces, barred anchors, hotness,
allocation), which are omitted because they don't affect which fields
can be set together.

| field | producers (guards) | consumers / clearers |
|---|---|---|
| `pending_exit_anchor` | `maybeArmContinuation` (`trace_link.zig:143`; refuses on `rec.active` or an existing exit anchor, then `hasTrace`/barred at `:178`); `maybeArmExitSide` (`:231`; refuses on `rec.active`, an exit or replay anchor, barred, anchor full) | `maybeStartContinuation` at its pc (`:197`); `clearPendingExitAnchor` (`:313`); cache clear (`:2643`) |
| `pending_replay_anchor` | prime-side transfer (`interp.zig:4710`; an earlier return when an exit anchor is pending, `:4690`, then refuses on recording or an existing replay anchor); `consumeSideTraceWantAtResume` (`trace.zig:3193`; refuses on recording, an existing replay anchor, barred, **not** on an exit anchor) | `maybeStartReplaySide` (`trace_link.zig:292`); `clearPendingExitAnchor`; cache clear |
| `pending_call_anchor` | `onCallEntry` (`trace.zig:3383`; refuses on `rec.active`); probe/want transfers (`interp.zig:4980`, `:5100`; refuse when call or ret is pending) | `maybeStartHead`, consume-or-discard (`trace.zig:3510`) |
| `pending_ret_anchor` | `onRetResume` (`trace.zig:3448`; refuses on `rec.active`); probe/want transfers (same) | `maybeStartCont`, consume-or-discard (`trace.zig:3493`) |
| `pending_ret_cont_arm` | `fileRetContArm` (`trace.zig:1893`; **displaces** a different key) | `tryArmFrameLinks` when the dispatcher **selects and enters** a matching trace, new or existing (`interp.zig:4039`, `trace.zig:1906`); dropped when the parent is gone (`:1917`); cache clear (`trace_link.zig:2650`) |
| `pending_call_head_arm` | dispatcher ledger (`interp.zig:3490–3503`; **displaces** a different key) | same as above (`trace.zig:1918–1927`); cache clear (`trace_link.zig:2651`) |

Reachable coexistences:
- **An exit anchor plus a ret anchor.** While a `pending_exit_anchor`
  waits for its pc, tier-0 runs in `.full`. A **non-boundary** `ret`
  calls `onRetResume` (`interp.zig:6560`). Among the pending fields and
  recording state, that checks only `rec.active`, so it can file a
  `pending_ret_anchor`. (Boundary returns exit before this
  producer.)
- **An exit anchor plus a replay anchor.** Through
  `consumeSideTraceWantAtResume`, which doesn't check the exit anchor.
- **Either arm request alongside anything, including a live recording.**
  The two arm requests wait for a trace *entry*, which can be far off, and
  neither setter checks the other fields or recording.

Making even the four prologue anchors exclusive would add refusals,
which changes tiering decisions. §2 rules that out.

**Therefore the nine conditions become one `u16` on `TraceState`,
`trace.fast_block`.**
- Zero means "fast dispatch allowed". `runFastPath` becomes
  `vm.trace.fast_block == 0`: one load and a test, the same load the
  `.S` entry does.
- It lives on `TraceState`, which owns seven of the nine conditions.
  `TraceState` has no pointer to `Vm`, and many tests build it standalone
  (`trace_gate_test.zig`, `trace_replay_test.zig`), so the trace side
  never reaches into the VM.

**Mutation ownership:**
- **`TraceState` owns its seven bits.**
  - The six pending fields move into a nested `pending` struct. Its
    methods write the payload and the bit together: `setExitAnchor`,
    `clearExitAnchor`, …, `displaceRetContArm`, `clearPendingExitAnchor`.
  - Zig can't hide fields, so the migration is enforced by the debug
    check below and a review checklist item. Every one of the current 28
    production write sites (`interp.zig`, `trace.zig`, `trace_link.zig`)
    and every test site moves to the methods in the same change.
- **The recording bit is set and cleared at the `TraceState` boundaries
  that call into the recorder, never inside `RecordingSession`.**
  `RecordingSession` keeps no link to `TraceState`, and its 10
  standalone tests (`trace_recorder.zig:6148` onward) stay untouched.
  - After every `TraceState` call that can change `rec.active`,
    `syncRecordingBit()` re-reads `rec.active`. Those calls are:
    - `rec.start` in `armWithPolicy`, `maybeStartContinuation` and
      `maybeStartReplaySide`, including OOM declines;
    - every `recordInstr` call site, because the recorder aborts itself
      there (`trace_recorder.zig:996`);
    - `closeTrace`/finalize, successful or failed (`active` is cleared
      at `trace_recorder.zig:1262`);
    - `consumeRecordingAbort`;
    - `abortRaised`.
    
    For reference, `reset` clears `active` at `:6077` and sets it at
    `:6144`. H1 audits that list against the source and adds every site
    it finds.
  - **Tests that start an owned recorder directly.** 58 test sites call
    `state.rec.reset(…)` on a `TraceState`'s recorder:
    - `trace_record_test.zig`: 50;
    - `trace_fingerprint_test.zig`: 4;
    - `trace_region_test.zig`: 3;
    - `interp_trace_test.zig`: 1.
    
    They move to a `TraceState.startRecordingForTest(…)` wrapper that
    syncs the bit. A test that does run the VM afterwards would otherwise
    trip the debug check.
    
    One test also **stops** an owned recording directly:
    `trace_gate_test.zig:1067` writes `state.rec.active = false` to
    simulate an abort's effect, then gates the anchor. It moves to a
    `TraceState.stopRecordingForTest()` that clears `active` and syncs the
    bit. The test's following `gateRecordAnchor` call is unchanged, so
    its abort/gate behaviour is preserved.
- **`Vm` owns its two bits** (`suspend_ctl`, `record_safepoint_lines`) and
  writes them into `vm.trace.fast_block` through `Vm` setters. That
  includes the production writes in `wasm_entry.zig:711`.
- **Init, restore and reset.**
  - `TraceState.init` sets the word to 0.
  - `TraceState` resets (cache clear, `trace_link.zig:2643–2651`)
    recompute **only the seven trace bits** and preserve the two VM bits.
  - Keyframe restore and VM init recompute all nine, using
    `Vm.recomputeFastBlock()`.
- **Whole-word writes only.** Every update reads, modifies and stores the
  whole `u16`. A byte-wide bit store followed by the 16-bit load would not
  store-forward (the `FrameResult` lesson, doc 59).
- **Validation is bit-exact.** The original predicate stays in the tree
  as `fastBlockReference()`. It returns the **nine-bit word**,
  reconstructed independently from the fields, not a boolean. A boolean
  couldn't catch a missing or extra bit while another condition is
  active. Debug builds assert `fast_block == fastBlockReference()` in
  three places:
  1. in `runFastPath`;
  2. in `runPushedFrame`, which every admitted `.S` call passes through;
  3. in `mahina_hostcall_slow`, unconditionally on every entry. That
     covers fast-word rejections without the `.S` entry having to record
     why it fell back.
  
  A stale clear bit would skip required hooks. A stale set bit would
  strand execution in `.full` or wrongly reject admission. Either one
  trips an assertion in tests.

## 6. Testing

### 6.1 Differential tests: two stages, normalized comparison

- **Stage 1 (H1).** H1 is diffed against **today's path** (`mh_call` →
  `callValue`).
  - The reference leg's dispatch uses the original nine-condition
    predicate, not the packed word, so H1 and the reference can't share
    a mask bug.
  - Separately, a mutation test drives every `TraceState`/`Vm` mutation
    method and compares `fast_block` with `fastBlockReference()` after each
    transition, bit for bit. It includes:
    - overlapping conditions: the table's three coexistence cases, plus
      a recording with an arm request pending;
    - selective clearing of one bit while others stay set;
    - displacement of an arm request;
    - stale-parent drops;
    - a cache clear with VM bits set, which must survive it.
- **Stage 2 (H3).** The `.S` entry is diffed against H1.

Each test runs the same script and call sequence on two VMs and compares
after every call:
- results, normalized: heap values by identity class and content, not by
  address;
- `*nresults` and the returned status, plus `last_error` and `fatal`;
- `depth`, `stack_top`, `native_reentry_depth`, and register contents
  below `stack_top`. Reentry depth is checked especially after catchable
  and fatal errors, nested calls, and result-park OOM;
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
tier/record/replay matrix: JIT off, the tier-1 interpreter, native, and
the embedding's record and replay modes.

Call shapes:
- **Argument counts:** 0..8 arguments, and 9 (the fallback); more and
  fewer than the parameters.
- **Varargs:** vararg callees with and without surplus arguments.
- **Results:** multiple results; result truncation, including zero
  capacity.
- **Null buffers:**
  - `results == NULL` with `max_results` 0 and > 0: an empty buffer in
    both cases, as today;
  - `args == NULL` with `nargs == 0`: valid, the call runs;
  - `args == NULL` with `nargs > 0`: `.err_api`, as today
    (`capi.zig:708`).
- **Fast word nonzero at entry:** a call while a recording is active,
  and while each kind of pending anchor or arm request is set. The `.S`
  entry falls back, and H1's `runPushedFrame` must take the `.full`
  branch, so the hooks fire exactly as in the reference.
- **Fallback callees:** natives and `__call`.
- **Errors:** guest errors, catchable and non-catchable; fatal refusal.
- **Reentry:** re-entrant calls, up to the reentry limit and past it.
- **Call-sequence exhaustion:** `next_call_seq` set to `maxInt(u64)`. The
  entry falls back, and H1 panics as today; checked in a subprocess test.
- **Recording:** a nested call that starts a recording and then raises.
- **GC timing:** a collection forced during the call, and after it
  returns.
- **The parking contract** (§4.3 step 2): an overwritten heap parameter,
  a discarded surplus heap argument, and an otherwise-unrooted callee,
  each followed by a collection during execution **and after return**.
- **Park overflow:**
  - on input, which falls back;
  - on results, which goes to the helper;
  - a host callback that uses up the inline park before the outer call
    returns heap results;
  - an idle call with a non-empty overflow park, which the `.S` entry
    empties itself (Q12 (a)). The parked lists must then match H1's
    exactly.
- **Helper OOM:** an OOM in the result-park helper. `*nresults` must stay
  0, the VM must not be fatal, and the next call must work.
- **`final_cut`:** a call after a genuine top-level finish, so the
  previous `final_cut` is non-null on entry.
- **Bad inputs:** an invalid tag (`0xFF`), `row_view`, a null heap
  pointer, null `vm`/`nresults`, the depth limit, register capacity, and
  OOM.
- **Frame-slot reuse** after a code-image change (the sentinel
  invalidation).
- **JIT modes:** on, off, and recording (the mode-switch path).

### 6.2 Determinism and replay

`just hashgate` runs only the CLI binary and never calls the C API, so
it is **not** coverage for this work. Embedding-level determinism tests
are added instead:
- capture keyframes around host calls, and require byte-identical
  serialized artifacts between the fast entry and the reference path;
- run the record and replay modes the embedding supports today.

Callback replay, and keyframes taken while host functions are registered,
remain excluded, as in doc 59 (E6/E8). The exclusions are written out in
the tests. The existing gates (`zig build test`, `just hashgate`, the
Rust crate tests) run unchanged.

### 6.3 Build acceptance (H2)

- **Visibility.** For each object in `libmahina.a`, `readelf -s --wide`
  shows:
  - every **defined** `mahina_hostcall_*` symbol as `HIDDEN`;
  - every **undefined reference** to one, in the `.S` object, as
    `HIDDEN` too (§4.2 linkage);
  - `mh_call` as `DEFAULT`.
- **Relocations, in a real link.** The acceptance build compiles the
  library modules with `.pic = true` (`Build/Module.zig:225`); today's
  `capi_mod` doesn't set it (`build.zig:106`). It then links the archive
  into a **shared library and into a PIE executable**, built with
  `-Wl,-z,text` so that any text relocation is a link error.
  - **The archive members must actually be pulled in.** The shared
    library is linked with `--whole-archive`, and the PIE executable
    calls `mh_call`. An unused archive would otherwise produce an empty
    library that passes every check.
  - The test then checks that `mahina_hostcall_entry` is present in both
    outputs (`readelf -s`). It also checks that no internal symbol is
    dynamically exported (`readelf --dyn-syms`), and that there's no
    `TEXTREL` (`readelf -d`).
  - (`nm -D` on a static archive says nothing about hidden symbols, and a
    relocation listing on the `.o` alone doesn't rule out dynamic text
    relocations.)
- **Unwinding**, per path against the expected frames in §3.3's table:
  - **DWARF**, with gdb or `perf --call-graph dwarf` in the build
    settings §3.3 states:
    - a stop in a guest handler walks
      `entry → chain → runPushedFrame (if not inlined) → handler`;
    - a stop in a host callback walks the same plus the callback;
    - a forced pre-commit fallback walks `host → mahina_hostcall_slow`;
    - a stop in the park helper walks
      `host → mahina_hostcall_entry → mahina_hostcall_park_rest`.
    
    Each unwinds back to the host's `main`.
  - **Frame pointers:** the same four walks, run only in the build where
    the Zig modules, the host fixture and its callbacks all keep `rbp`
    (§3.3).
- **Tail call.** `objdump` of the Zig `mh_call` shows a `jmp` to
  `mahina_hostcall_entry` with no frame left behind (Q11).

### 6.4 Budgets are benchmarks, not tests

The §5.3 ledgers are measured by the embed probe and the embed benchmark,
then recorded in this doc's status section (Rule #22).

## 7. When a path earns hand-written code (this applies to H3 too)

A candidate qualifies when all of these hold:
1. **It's hot on general workloads.** A profile shows that, not one
   benchmark (Z-6).
2. **What's left is compiler artifact.** Its minimal-work Zig version
   (its "H1") exists and has been measured. Callgrind or perf annotation
   shows the remainder is mostly spills, prologues, struct copies, alias
   reloads and layout.
3. **Its semantics are small and stable.** Logic that churns stays in
   Zig.
4. **It wins on cycles.** An A/B of the hand-written version against its
   Zig version shows a **cycle or latency** gain on representative
   workloads. The A/B also reports fallback frequency, code size, and
   the language suite, with no regression elsewhere. Fewer instructions
   alone is not enough: doc 59 measured an instruction cut that cost
   cycles through code placement.
5. **It keeps a safety net.** The Zig reference stays, along with the
   differential tests and a recorded budget.

Candidates to profile, in no committed order:
- table get/set fast paths, where callable as leaf routines;
- the guest→host callback trampoline (doc 59 E5: ~54 ns);
- GC mark/sweep inner loops.

The doc-42 opcode handlers are **not** piecemeal candidates (§2
non-goals). A hand-written interpreter is all or nothing. It would get
its own doc, built on this one's `.S` and offsets machinery.

## 8. Open questions

- [x] **Q1: pre-parking callee and args — keep it** (rev-1 reviews).
  - The header promises arguments stay valid through and after the call
    (`mahina.h:20–25`).
  - Natives and `__call` never root args in a frame.
  - The closure window doesn't cover surplus or overwritten arguments,
    or the time after the frame pops.
- [x] **Q2: the seam is a C-ABI shim** (Bart, 2026-10-02). Handlers keep
  Zig's convention.
- [x] **Q3: mechanism M2, a separate `.S` file** (Bart, 2026-10-02:
  easier to inspect).
- [x] **Q4: the packed fast-path word is in scope** (Bart, 2026-10-02),
  in H1 (§5.4).
- [ ] **Q5: prepared calls (H4).** Is a new API worth it once the entry is
  ~100–170 instructions? Decide after H3.
- [x] **Q6: where the fast word lives.** Audited 2026-10-03 and corrected
  in rev 4 (§5.4). The pending fields coexist, so it's a `u16` on
  `TraceState` with `Vm` setters for the two VM bits.
- [x] **Q7: offsets mechanism.** A checked-in, inspectable
  `offsets_x64.inc`, verified at comptime by the gated target build (Bart,
  2026-10-03; §3.2).
- [x] **Q8: targets.** Linux x86-64 only for now. macOS waits on a
  portable C API, and Windows is a TODO (Bart, 2026-10-03; §3.1).
- [x] **Q9: export layout.** The Zig `mh_call` stays the public symbol on
  every target and tail-calls a hidden per-target entry (Bart,
  2026-10-03).
- [x] **Q10: result parking.** The assembly parks into inline slots and
  calls a Zig helper for the rest on overflow (Bart, 2026-10-03; §4.3
  step 10).
- [ ] **Q11: verify at H2 against the pinned toolchain:**
  - `.S` preprocessing, or the `.assembly_with_preprocessor` fallback;
  - hidden `@export`;
  - `always_tail` compiling to a plain `jmp` with this signature;
  - the §6.3 checks.
- [x] **Q12: the register file and overflow park: (a)**, a stated slice
  exception (Bart, 2026-10-03; §3.2). The slice layout is checked by an
  executable test and a check at VM creation, because comptime can't
  inspect a slice. Zig internals move only with a toolchain bump, which
  is when those checks are re-run deliberately. Option (b), plain mirror
  fields on `Vm`, was not chosen.

## 9. References

- Doc 59: the embedding API. The "Boundary pass vs LuaJIT/mlua" section
  has the measurements used here; §3.3 is the rooting protocol; E6/E8 are
  the replay exclusions.
- Doc 42: tier-0 tail-call dispatch, with the handler ABI in §4.6.
- Doc 54 P0, the plain-`u64` code-cache sentinel.
- Doc 26 D1a, recording abort on raise.
- `include/mahina.h`: the value lifetime contract (lines 20–25) and
  `mh_call` (line 149).
- `~/Projects/LuaJIT/src/`:
  - `vm_x64.dasc`: `vm_call`, `vm_pcall`, `vm_call_dispatch`;
  - `lj_api.c`: `lua_pcall`;
  - `lj_frame.h` and `lj_err.c`: the C-frame chain;
  - `Makefile`: DynASM → `buildvm` at build time.
- `src/capi.zig`: `mh_call`, `runProtected`, `park`, `parkClearIfIdle`,
  `guestFault`, `resultsSlice`, `zigProbeStack`.
- `src/x64.zig` and `src/nativegen_mcode.zig`: the runtime encoder and
  mapper, kept for the JIT.
- Reviews: `docs/reviews/doc60/{codex,antigravity}-rev{1,2,3}.md`.

## 10. Review disposition

"Addressed" means specified by the design. Nothing here is implemented
or tested.

### Rev 1 → rev 2, and rev 2 → rev 3

These are scored in `codex-rev2.md` §NITS 5 and `codex-rev3.md` §SHOULD-FIX
7. Items those reviews left partial are carried into the rev-3 → rev-4
table below.

### Rev 3 → rev 4

Antigravity numbers its rev-3 findings B1–B2, S1–S4 and N1–N3.

| finding | status in rev 4 | where |
|---|---|---|
| codex B1 / antigravity B1, S4: null `results`/`args` | addressed: `mh_call` normalizes `max_results`; `args` null check before any load; tests with zero and nonzero lengths | §4.1, §6.1 |
| codex B2 / antigravity B2: slice representation | specified as two options in rev 4; decided (a) by Bart after rev 5 | §3.2, Q12 |
| codex S1: audit lifecycle claims, missing producer, coexistence cases | addressed: full producer/consumer table, three reachable coexistences, mutation tests | §5.4, §6.1 |
| codex S2: owned-recorder test starts; boolean validation | addressed: 58 sites → `startRecordingForTest`; bit-exact `fastBlockReference()` | §5.4 |
| codex S3 / antigravity N1: module placement, linkage, fourth symbol | addressed: `runPushedFrame` (VM) + `mahina_hostcall_chain` (C API); hidden `@export`; all symbols declared | §4.1, §4.2 |
| codex S4: unwind/visibility checks misleading | addressed: no `mh_call` frame; DWARF vs FP tests separated; `readelf` + shared/PIE link with `-z text` | §3.3, §6.3 |
| codex S5: macOS needs a portable C API | addressed by scope: Linux only (Q8); macOS deferred with its prerequisite | Status, §3.1 |
| codex S6: H1 must clear `final_cut` before `pushFrameTrusted` | addressed; non-null-`final_cut` test added | §3.2, §6.1 |
| antigravity S1: `produced` undefined | addressed | §4.3 step 8 |
| antigravity S2: nullable `results` in helper | addressed | §4.2 |
| antigravity S3: straight-line limit vs loop | addressed: ≤ 8 in `.S`, > 8 falls back | §4.1, §5.1 |
| codex N1: `always_tail` failure is a compile error | addressed | §4.1, Q11 |
| codex N2: offsets inventory (fast word, `ChainResult`, alignments, bit offsets, Debug layout) | addressed: listed; no Debug-only fields; rejection scratch field dropped | §3.2, §5.4 |
| codex N3: test count, line 1262, Z-6 vs §2 | addressed | §5.4, §2 |
| antigravity N2: debug rejection field lifecycle | addressed by removal: `mahina_hostcall_slow` asserts on every entry | §5.4 |
| antigravity N3: `max_native_reentry` name | addressed | §3.2 |

Codex's rev-4 review scores the table above. It rates codex S1, S2 and S4
(and so S7) as partial. Those items are carried into the next table.

### Rev 4 → rev 5

Antigravity numbers its rev-4 findings B1–B2, S1–S4 and N1–N3.

| finding | status in rev 5 | where |
|---|---|---|
| codex B1: shared runner must keep the initial mode check | addressed: `runPushedFrame` picks `.fast` or `execWith`/`.full` as `execWithEntry` does; nonzero-fast-word tests added | §4.1, §6.1 |
| antigravity B1: asymmetric reentry decrement | addressed: `runPushedFrame` owns increment + `defer` decrement; `.S` and H1 only read it | §4.1, §4.3 steps 3, 6, 7, 9, 13 |
| codex S2 / antigravity B2: unwind frames per path; FP/DWARF build settings | addressed: per-path frame table and walks; unwind tables, frame-pointer settings for Zig and host | §3.3, §6.3 |
| codex S1: Q12(a) comptime verification doesn't work; overflow length width | addressed: executable verification (test + `mh_vm_new` check); `usize` mirror updated after successful append. Q12 was then decided (a) | §3.2 |
| codex S3: archive extraction; hidden undefined references | addressed: `--whole-archive` / a consumer of `mh_call`; entry presence checked; `.hidden` on references | §4.2, §6.3 |
| codex S4: direct `rec.active = false` in a test | addressed: `stopRecordingForTest()` | §5.4 |
| codex S5: compare `native_reentry_depth` | addressed | §6.1 |
| antigravity S1: dead `base` parameter | addressed: passed to `runPushedFrame` | §4.1, §4.3 step 6 |
| antigravity S2: `final_cut` and `entry_top`/`entry_depth` capture in §4.3 | addressed | §4.3 steps 3, 6 |
| antigravity S3: PIC for the shared-library check | addressed: `.pic = true` in the acceptance build; RIP-relative references | §4.2, §6.3 |
| antigravity S4: `ChainResult` field order | addressed: `status` first | §4.2 |
| codex N1: "checks only `rec.active`" | addressed: the table is labelled as coexistence-relevant guards | §5.4 |
| codex N2: `args == NULL, nargs == 0` is valid | addressed | §6.1 |
| codex N3: `defer` not `errdefer`; frame vs registry sentinel | addressed | §3.2, §4.1 |
| antigravity N1: errdefer LIFO order | addressed | §4.1 |
| antigravity N2: `safepoint_seq` line | addressed (`:2789`) | §4.3 step 6 |
| antigravity N3: Q12 options sound | superseded by codex S1: (a)'s comptime check was not sound and is replaced | §3.2 |
