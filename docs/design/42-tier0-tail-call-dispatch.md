# 42 — Tier-0 tail-call dispatch (per-op handlers, musttail)

Status: LANDED 2026-09-07 (conversion + §4.6 ABI widening + prologue
trampolines in one arc; measured receipts in §9 below). Codex-reviewed
design (gpt-5.6-sol, verdict sound-with-changes; all changes folded in).
Owner seam: `src/interp.zig` only (the trace modules are consumers, unchanged).
Authorized by Bart 2026-09-07 ("absolutely number 1") after the doc-41 perf
investigation. This is the interpreter phase `src/dispatch.zig` has been the
standing capability gate for since Phase 0 ("the real interpreter replaces the
code, NOT the capability").

## 1. Problem: the interpreter's speed is hostage to block-placement luck

Evidence chain (TODO "Doc-41 follow-ups" item 1b, all interleaved A/B against
the 8a9ef56 shadow):

- pi_leibniz **tier-0** +12.7% across the doc-41 split with `interp.zig`,
  `arith.zig`, `value.zig`, `table.zig` byte-for-byte untouched.
- `perf stat -e L1-icache-load-misses`: **19.7M misses (±0.4%) vs 14K**
  pre-split — ~4 misses per interpreted loop iteration, sustained; IPC
  4.57 → 4.13; +2% instructions.
- The misses are spread across the whole `execImpl` body: LLVM's basic-block
  placement of the ~48KB megafunction changed because the *shapes of trace
  helpers inlined at its dispatch points* changed. Nothing semantic moved.

The current loop is **already threaded** (labeled `sw: switch` +
`continue :sw`, 61 thread sites): each arm has its own indirect dispatch jump,
so branch prediction is fine. What threading does NOT give us is **layout
control**: all 56 opcode arms, the `nextOp` prologue, and every inlined helper
live in one function whose block order is a global LLVM optimization decision.
Any edit anywhere in the inlined closure of `execImpl` can re-roll that dice.
It came up bad this time; it will keep re-rolling every arc.

## 2. The structure that removes the dice

One handler **function** per opcode, dispatch by guaranteed tail call:

- Each handler is its own symbol. LLVM lays out each function independently;
  a hot handler is a compact straight-line block with its dispatch `jmp` at
  the end. Editing trace-module helpers can no longer reshuffle unrelated
  handlers against each other.
- Per-handler register allocation, instead of one allocation fought over by
  56 arms in a 48KB frame.
- This is the compiler-era equivalent of what LuaJIT's hand-written
  `lj_vm_*.dasc` per-op blocks achieve (each op a self-contained chunk ending
  in a direct-threaded jump), and the exact pattern protobuf/upb and wasm3
  use in C via `musttail`.
- Architecture doc 00 names guaranteed tail calls a **portable architectural
  pillar (#4)**; `build.zig` already enables the wasm `tail_call` CPU feature;
  `src/dispatch.zig` is the permanent capability gate (do not weaken it —
  extend it, §7 T-7).

## 3. Toolchain facts (verified 2026-09-07 on 0.17.0-dev.813+2153f8143, Z-1)

Experiments in /tmp/ztail (reproduce before implementation if the toolchain
was bumped):

1. **`@call(.always_tail)` through an error-union return DOES NOT COMPILE.**
   `Err!i64` lowers to an sret out-param and LLVM's verifier rejects the
   musttail ("musttail call must precede a ret with an optional bitcast").
   ⇒ handlers cannot return `Error!ExecStep`.
2. **Register-sized return + fn-pointer table works and is optimal**: with
   `*const fn (st: *State, x: u64) i64` handlers and a shared `dispatch`
   helper, ReleaseFast emits each handler as its own symbol ending in
   `jmp *table(,%rax,8)` — the dispatch inlined into every handler tail,
   i.e. true direct threading, zero call/ret pairs.
3. **wasm32**: `@call(.always_tail)` errors without the `tail_call` feature
   and compiles with it; `build.zig` already adds the feature.
4. Native x86-64 via LLVM (`use_llvm = true`, already pinned): works.
5. **CAVEAT (codex)**: the experiment's state struct is toy-sized and `Instr`
   is 12 bytes (`bytecode.zig:186`), not 8 — it will likely take two argument
   registers. The signature decision in §4.1 must therefore be made from
   generated assembly of REAL representative handlers, not from this
   experiment (§4.6).

## 4. Design

### 4.1 State: ownership and partition

**Ownership (codex blocking change 1).** `execImpl` owns a local `ExecState`
on its own frame and enters the handler chain with an **ordinary call** —
never a musttail — so a pointer to its local state can never outlive the
frame. Handlers and the dispatch wrapper musttail among themselves; any exit
event returns through the whole chain in one `ret` to `execImpl`, which
translates the result back to `Error!ExecStep` (re-raising a parked error as
a real Zig error). `execWith` is untouched, so its two `errdefer`s
(`clearPendingExitAnchor`, `abortRaised` — interp.zig:2033/2040) fire exactly
as today, and mode switches / suspension keep their current shape: `execImpl`
returns, its state dies, the next invocation reloads from `CallFrame`.

```zig
const ExecState = struct {
    vm: *Vm,
    frame: *CallFrame,
    closure: *const Closure,
    proto: *const Proto,
    code: []const Instr,
    code_gen: u64,
    base: usize,          // matches CallFrame.base (interp.zig:368) — NOT u32
    regs: RegWindow,
    stop_depth: u32,
    step: ExecStep,       // exit payload, set before returning non-continue
    err: ?Error,          // parked error — initialized null on EVERY entry
};

const HandlerResult = enum(u8) { finished, suspended, switch_mode, err };
```

A handler that continues execution never returns — it tail-jumps. Only exit
events return.

**Partition.** Baseline signature `(st: *ExecState, pc: usize, instr: Instr)`:
`pc` by value (hottest datum), `instr` by value (needed immediately; 12 bytes
≈ 2 registers), everything else behind `st`. `cur_pc` and `a` stop being
threaded state (`cur_pc = pc - 1` at handler entry; `a = instr.a`).

Codex correctly notes the honest cost: the megafunction keeps `self`, the
register lanes, and other hot state live in registers ACROSS arms; per-handler
functions cannot retain anything across an indirect tail call that isn't in
the ABI. The primary alternative to evaluate is `(vm: *Vm, st, pc, instr)` —
`vm` is consumed by every prologue and most handlers, so a dedicated register
argument removes the most universal `st.vm` load. If further widening looks
useful, thread the two RegWindow *lane pointers* individually, never the
three-word `RegWindow` (spill risk). Decision procedure in §4.6.

### 4.2 The dispatch tail = the prologue + table jump

`nextOp`'s body becomes the shared dispatch helper, called at every handler
tail; LLVM inlines it into each handler (verified §3.2), reproducing today's
per-arm threading plus per-function layout. Two comptime tables
(`table(.fast)` / `table(.full)`) generated from one `handlerFor(op, mode)`
so the `.full`-only hooks compile out of `.fast` handlers exactly as today.

**The determinism contract is the complete prologue order** (interp.zig
2103–2195), preserved verbatim — this list is normative:

1. GC check/collect (suppressed while `reg_top_pending`)
2. `safepoint_seq` increment
3. replay-line append (`.full` + `record_safepoint_lines`)
4. suspend test → park `frame.pc`, return `.suspended` (`.full`)
5. region departure observer (count-gated, then `observeFast`, then slow call)
6. `frame.pc = cur`
7. fetch `i = code[cur]`, advance pc
8. recording-close-at-anchor check (`.full` + recording)
9. pending continuation activation (`.full`)
10. pending replay-side activation (`.full`)
11. recording mirror (`.full` + recording)

Suspension stays before fetch and before all recording hooks. A prologue
error (e.g. the replay-line `append` OOM) must park-and-return leaving
exactly today's partial state — `safepoint_seq` already incremented, nothing
after the failing step run.

### 4.3 Errors: park-and-return replaces every error edge (not just `try`)

Translation covers ALL error forms in arm bodies (codex blocking change 1):

- `try X` → `X catch |e| { st.err = e; return .err; }`
- direct raises (`return self.raise(...)`-shaped sites, e.g. interp.zig
  ~3310/3670/3931) → park st.err, `return .err`
- narrowed/native error edges (e.g. ~3763) and nested `catch` arms (concat)
  → same parking at the point the error would today propagate out of the arm

Helpers (`arith.*`, `binNum`, metamethods, `callValue`) keep their error
unions unchanged. `execImpl` re-raises at the boundary (§4.1), so
`execWith`'s errdefers and every enclosing pcall behave identically. Happy
path pays zero (no error-union ABI on the tail chain at all); error path
pays one store+branch and is already the slow path.

### 4.4 Frame switches and resumes: TWO distinct operations (codex change 2)

The old `continue :outer` sites are NOT uniform and must not share a helper:

- **`reloadTopFrame(st)`** — only after a real push/pop (`.call` Lua entry
  ~3711–3719, `.ret` ~3881–3894). Re-derives frame/closure/proto/code/
  code_gen/base/regs from `frames[depth-1]`, calls `setRegionContext` — the
  current explicit reload blocks move in as-is. The surrounding boundary
  ORDER is owned by the call/ret handlers, not the helper: callee-window
  init without safepoint → park caller `frame.pc` → push (raises
  `stack_top`, sets region context) → reload → exactly one next-instruction
  prologue; and for return: close upvalues → copy results while the callee
  window is rooted → drop activation → pop → reload → shrink `stack_top` →
  exactly one parent prologue (atomic rooting contract, interp.zig:1622).
- **`dispatchCurrentAt(st, npc)`** — trace/deopt/patched-entry resumes
  (~3438, ~3508, ~4117): replace pc and tail-dispatch, re-resolving NOTHING
  (no `codeFor`, no `setRegionContext` — adding those would change observer
  behavior and cost on productive resumes).

**Back-edge epilogue** (the 14 `break :sw` sites → hotness seam, coverage,
`onBackEdge`, tier entries, patched-entry plumbing, ~interp.zig 3940+):
extracted as a **`noinline`** function (codex: "ordinary function" alone
lets ReleaseFast re-inline it and recreate the coupling), comptime-
parameterized by `mode`, returning a directive that maps onto: resume at pc
(tail dispatch), reload-then-dispatch (after a productive entry that pushed/
popped), suspend/switch-mode (return through the chain). Two invariants:

- It must NOT write the jump target into `frame.pc` — today `frame.pc`
  stays at the executed back-edge until the next prologue, except an explicit
  mode-switch park.
- It preserves every image-generation reload point inside itself
  (~3423, ~4110, ~4160).

### 4.5 What each handler looks like

```zig
fn opAdd(comptime mode: ExecMode) Handler {
    return struct {
        fn h(st: *ExecState, pc: usize, instr: Instr) HandlerResult {
            st.vm.binNum(st.regs, instr.a, instr.b, instr.c, .add, st.vm.mm.add)
                catch |e| { st.err = e; return .err; };
            return dispatchTail(mode, st, pc);
        }
    }.h;
}
```

Arm bodies move verbatim under five translation rules: `try`/raise/narrowed
error → park (§4.3); `continue :sw (…)` → `return dispatchTail(…)`;
push/pop reload → `reloadTopFrame` + dispatch; resume-only →
`dispatchCurrentAt`; `break :sw` → `switch (backEdge(mode, st, pc, instr))`.

### 4.6 ABI decision procedure (before the flip commit)

Build the conversion with the baseline signature, then compare generated
assembly (`objdump`) and interleaved wall time for `(st, pc, instr)` vs
`(vm, st, pc, instr)` on four real handlers: `move` (trivial), `add`
(arith), `jmp_if_false` (conditional), and `call` (helper-heavy). Look at
loads-per-handler, spills, handler size, and that every handler tail is a
`jmp` (T-6). Signature is one typedef; switching is mechanical. Further lane
widening only with measurement (R1).

Comptime safety: assert `OpCode` is dense and table index == enum value
(`bytecode.zig:30` is dense today; direct indexing must fail loudly if that
ever changes).

## 5. What this does NOT change

- `execWith`/`exec`/`runFastPath` drivers, `ExecOutcome`, `stop_depth`,
  `final_cut` publication — untouched (codex change 1 makes this literal).
- Tier-1a/1b entry seams, `driveChain`, recording, replay, all trace
  modules — untouched callees.
- Per-op semantic code: moved, not rewritten.
- Determinism: §4.2's prologue order is the whole contract; hashgate + the
  focused tests (§7) gate every commit.

## 6. Landing plan (revised per codex; Z-7 slices)

1. **Prep commit**: `ExecState`/`HandlerResult`/helper definitions
   (`reloadTopFrame`, `dispatchCurrentAt`, error-parking), the comptime
   dense-enum assert, and the §7 focused tests — WITHOUT routing the live
   loop through any of it (codex: extracting the epilogue early would
   re-roll the megafunction layout and contaminate every measurement).
2. **The conversion, one commit**: handlers + tables + musttail dispatch +
   `noinline` epilogue together; the labeled-switch loop deleted. Codex is
   right that an "arms call handlers" intermediate is not a coherent
   architecture (handlers have no non-tail continuation shape) — so the
   conversion lands whole. It is mechanical per §4.5's five rules and
   reviewed per-family within the one commit.
3. **Measure against the PRE-ARC baseline** (the 8a9ef56 shadow AND current
   HEAD): pi_leibniz t0, euler14/recursive-fib/array3d/lua54
   (interpreter-bound set), fft + grid_matmul, full `just bench`,
   `perf stat -e L1-icache-load-misses`, binary size, `zig build` wall.
   Wasm smoke test green.
4. **ABI tuning** (§4.6) as a follow-up commit only if assembly/measurement
   justify it; then docs (board, CURRENT_TASK, this doc → LANDED, close
   TODO 1b honestly).

## 7. Focused tests (beyond hashgate — codex list, all in the prep commit)

- T-1: error raised mid-recording → `abortRaised` + pending-anchor cleanup
  still fire (the execWith errdefer path through the new boundary).
- T-2: suspend cut landing immediately before the first callee instruction
  (call boundary: prologue neither skipped nor doubled — R6).
- T-3: parent resumption immediately after `.ret` (same property, pop side).
- T-4: fast→full and full→fast handoff at a back-edge (`switch_mode`
  through the new return chain).
- T-5: reentrant `callValue` — outer exec's cached state survives the nested
  `execWith` (interp.zig 1686–1695).
- T-6: long-chain real-interpreter run (millions of dispatches) asserting
  O(1) stack — extends `dispatch.zig`'s capability gate to the real
  handlers; the toy gate stays.
- T-7: wasm build + smoke test.

## 8. Risks

- R1 — cross-handler register retention is structurally lost (§4.1);
  mitigations are ABI widening (§4.6). Accepted: layout stability + per-
  handler allocation are expected to dominate, but §6.3 measures, not hopes.
- R2 — 112 handler symbols + 2 tables: watch build wall + binary size.
- R3 — epilogue `noinline` call cost, paid once per loop iteration on the
  interpreted path — measured in §6.3 as part of the whole (prep commit
  deliberately does NOT pre-extract it).
- R4 — wasm `return_call` engine performance is not a gate; correctness is.

## 9. As landed (2026-09-07) — amendments and measured receipts

The conversion landed as designed, plus three iterations the §6.3 battery
forced. Everything below was measured with interleaved A/B/C (NEW vs
pre-conversion HEAD a446bea vs pre-split shadow 8a9ef56), 9 reps + discarded
warmup round, medians.

### 9.1 Signature amendments (supersede §4.1's baseline)

1. **`instr` rides as `*const Instr`, never by value.** A by-value 12-byte
   `Instr` lowers to a byval STACK argument on wasm32, and wasm tail calls
   reject stack arguments outright ("does not support tail calling with
   stack arguments") — found by the T-7 build. `*const Instr` is
   register-sized on every target; the pointee is the fetched code-image
   element (same hot cache line).
2. **§4.6 widening WAS justified, and by lanes, not just `vm`.** The
   baseline signature measured +4.3% on pi_leibniz t0 with instruction
   count at parity — the delta was L1-dcache LOAD PORT saturation (HEAD
   already ran 3.0 loads/cycle; per-hop re-derivation of vm/frame/lanes
   from `st` added ~4 loads/hop). Final uniform signature — exactly six
   register-sized args, a full SysV x86-64 integer-register fit:
   `fn (st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult`.
   Handlers rebuild their window as
   `.{ .tags = tags, .payloads = payloads, .n = st.regs.n }` (the `n` load
   is dead-code-eliminated in hot handlers; kept correct for anything that
   forwards the window to `regs.len()` consumers, e.g. trace.zig:2502).
   `opCall`/`opRet` keep working through `st.regs` — their lanes
   legitimately change mid-handler (frame push/pop) — and the general
   `dispatchTail` re-derives lanes from `st.regs`, so every reload site
   inherits the pre-widening staleness discipline unchanged.
3. **Straight-line fetch = `instr + 1`.** At handler entry
   `instr == &st.code[pc - 1]` invariantly, so fall-through handlers pass
   `instrNext(instr)` to `dispatchTailFrom` and the opcode-load address is
   ready at handler ENTRY instead of behind an `st.code` load — the fetch
   chain the megafunction never paid (it kept `code` in a register). Pure
   algebraic identity against the same cached image: identical staleness
   semantics, no new hazard. Only handlers whose dispatch target is the
   incoming `pc` qualify (28 sites); jumps, reloads, `&patch.orig`
   presenters, and `chainEntry` (instr undefined) stay general.

### 9.2 The call-free hot prologue (supersedes the §4.2 shape, order intact)

The single biggest regression source (+37.7% → +23.2% → measured down to
parity) was CALLABLE SITES in the inlined prologue: any `call` anywhere in a
handler forces callee-saved push/pop pairs on EVERY hop, even when the call
never executes (LLVM cannot shrink-wrap past the tail jump). Three
extractions fixed it, each a handler-shaped musttail trampoline that does
its cold work and re-enters the remaining prologue, preserving the §4.2
step order exactly:

- `gcTrampoline` — step (1)'s `collect()`.
- `regionTrampoline` — ALL of step (5) behind the empty-map counter test:
  even the A-vii-e.2 inline `observeFast` probe costs 3 callee-saved
  registers of pressure in every fast handler when inlined; behind the
  musttail, a regions-live program pays one extra tail jump per
  instruction (still call-frame-free) and region-free programs pay one
  `cmpl`.
- The trampolines carry the fetch pointer through their (otherwise unused)
  `instr` argument — valid across `collect()` because the collector is
  non-moving and never swaps the cached image.

Two toolchain facts (Z-1, add to §3's list):

- `noinline` is part of the fn TYPE in 0.17.0-dev.813 and musttail requires
  exact caller/callee type match — a noinline trampoline cannot be
  musttail'd from plain handlers. `@branchHint(.cold)` as the first body
  statement (std/lang.zig BranchHint) is the working anti-inline device,
  and without it LLVM DOES re-inline small trampolines, dragging the
  spills back in (measured on regionSlowTrampoline).
- The shared dispatch must be Zig `inline fn` expanded into every handler
  tail; LLVM declines to inline it as a plain shared function (263-byte
  dispatch + `jmp dispatch` per handler = +37.7% pi_leibniz t0).

Two same-arc de-inlining fixes on the reload path (visible only once the
megafunction stopped hiding them): `reloadTopFrame` and
`TraceState.codeFor`/`EntryRegistry.codeFor` are now `inline fn` — perf
showed them as standalone symbols at 7.5% + 5.3% of recursive-fib after the
conversion (in the megafunction both inlined into `execImpl`'s arms).

### 9.3 Receipts (final shape, interleaved medians vs HEAD a446bea / shadow 8a9ef56)

    bench          t0 vs HEAD  t0 vs SHADOW   jit vs HEAD  jit vs SHADOW
    pi_leibniz       -10.8%       -7.3%          -0.9%        +1.4%
    euler14-bit       -5.9%       -2.2%          -1.2%        +4.0%
    recursive-fib     +1.9%       +6.5%          +0.4%        +3.4%
    array3d           -4.2%       +1.1%          -3.9%        +1.1%
    lua54             +1.7%       +3.1%          +1.7%        +5.1%
    scimark-fft       -8.9%       -4.1%          +6.9%        +7.2%
    grid_matmul       -4.6%       -2.4%          +1.1%        +4.9%

- The structural goal is met: pi_leibniz t0 L1-icache misses 9.1K (HEAD
  12–19.7K depending on that commit's layout luck; shadow 14–17K) — the
  megafunction's block-placement lottery is gone, and t0 beats HEAD on 5
  of 7 benches.
- Honest residuals: recursive-fib/lua54 t0 ≈ +2% vs HEAD (call-boundary
  hops still pay reload work the megafunction kept in registers);
  scimark-fft jit +6.9% — profiled to the trace-chain seam
  (`replayLedgerFrom` 13.7%, `driveDispatcherLedger` 5.7%,
  `backEdgeEpilogue` 2.2%), i.e. R3's accepted per-back-edge call cost,
  NOT the region trampoline (absent from the profile entirely).
- R2 receipts: binary 14.45MB vs 14.14MB HEAD (+2.2%); cold ReleaseFast
  build 40.8s vs HEAD's 46.3s — the conversion is FASTER to compile (the
  ~48KB megafunction was the expensive thing).
- Gates: `just test` green, hashgate 84/84 on BOTH legs (ReleaseFast +
  Debug), `zig build wasm` green (T-7: musttail with the six-arg
  signature compiles on wasm32+tail_call), T-1..T-6 in
  `interp_dispatch_test.zig`.

### 9.4 Follow-up lever on file (NOT landed — Bart's call)

`omit_frame_pointer = true` on the mahina module removes the remaining
`push rbp`/`pop rbp` per hop: measured ~1.5–3.5% additional t0 win
(pi_leibniz 195.9ms vs 202.9ms same-shape A/B). Cost: fp-based `perf
record -g` call graphs degrade (flat profiles and `--call-graph dwarf`
unaffected). Left out of the conversion commit deliberately.

### 9.5 Follow-up (2026-10-23): the handlers' own slow halves

§9.2's rule holds for a handler's own body as much as for the prologue,
and the busiest handlers still broke it: `opBinNum` (`+ - *`), `opDiv`,
`opBinBit`, `opNeg` and `opBnot` called `arithGeneric`/`unArithMeta` on
their non-number lane, `opForLoop` called `forLoopStepMixed`, and `opLen`
musttail'd `opLenSlow` directly, which LLVM inlined back with its calls.
Each pushed five callee-saved registers on every hit. They now leave
through `slowTail` (doc 62 §4.3's per-op slow table, whose runtime index
LLVM cannot fold into an inlinable call): `opArithMeta` for the binary
ops, `opUnArithSlow` for `-`/`~`, `opForLoopSlow` for a float index with
an int step, and `opLenSlow`, which searches with `Table.lengthSearch`
directly once `opLen` has tried `Table.lengthFast` inline. `for_loop`
keeps the int-index/float-limit case inline, tested after the all-one-type
lanes so the int path keeps its frame (nsieve's limit is a float).

Receipts (tier-0 instructions vs f03cee8; `ops.lua` base `s = s + i` 116 → 91;
`-i` 37 → 25, `~i` 41 → 24, `i & 7` 47 → 31, `x / x` 41 → 34, `#t` 100 → 81):
nsieve-bit −19.5%, euler14-bit −20.6% (JIT −5.5%), sieve_int −9.2%,
pi_leibniz −8.9%, scimark −7.2…−7.7%, nsieve −7.5%, field_hash −6.6%; every
@bench row down on both tiers, no aborts changed.
