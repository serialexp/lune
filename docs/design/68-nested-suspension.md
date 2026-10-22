# 68 — Nested suspension: re-entry as continuation frames, so the VM can stop anywhere

Status: draft rev 2, not yet implemented. Bart chose this direction on
2026-10-22 over "stop in place, then abort" and "step over nested code" (§2).
Round-1 review by codex and antigravity is folded in (§11). Q2 and Q3 are
decided: the reviewers split on both, and Bart asked the author to break the
tie (2026-10-22).
Owner: claude (coral-raven)
Last updated: 2026-10-22

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Direction** (2026-10-22). Bart picked real nested suspension over the
  two cheaper options in §2.
- [x] **Panic capture in the wasm VM** (2026-10-22, with the multi-file
  work). A wasm panic used to reach JS as a bare "unreachable"; now
  `mahina_panic_message_*` carries its message, the JS binding throws
  `MahinaTrapError`, and the worker loads a fresh instance after one. It is
  how this bug was found and is independent of the design.
- [x] **Round-1 review** (2026-10-22, codex and antigravity,
  `docs/reviews/doc68/*-r1.md`). Bart didn't answer whether to run one, so it
  ran as for doc 67; rev 2 folds it in (§11).
- [x] **Q2 — gsub's output buffer: (a), the GC-owned byte buffer** (§7.4;
  tiebreak by the author at Bart's request, 2026-10-22). The state lives in
  registers on every function-replacement `gsub`, not only on one that
  suspends. So (b) would put a string and a table slot per match on the
  ordinary path, while (a) keeps appends O(1) amortized, close to today's
  native buffer. `require` reuses the kind.
- [x] **Q3 — the embedder boundary: (a), defer** (§8; same tiebreak). Under
  (b), a program that calls any embedder binding could not be stepped. Most
  mahina programs will run inside an embedding app, so that would switch
  the debugger off in the main use case. P1 handles (a)'s three caveats: the
  suspend reports the step it actually stopped at; a host entry that returns
  without reaching a boundary ends the run as "stop not reached", and the
  replay index treats it the same way; the index cap applies as today.

### Outstanding

- [x] **P0 — the frame contract.** Landed in d0b815e (2026-10-22, bundled
  into doc 66 P3): `FrameCtl` (kind, `Cont`, phase) as one byte in
  `CallFrame`'s free byte at offset 79, so the 80-byte stride holds;
  written by all three push paths (struct literal, inline native push,
  `hostcall_x64.S`); `CF_CTL` in the checked offsets; `opRet` asserts no
  continuation yet. The io_write +1 instruction/call first blamed on it is
  an LLVM spill in `nativeIoWrite`: a d0b815e build with P0 backed out
  shows it too (coral-marten). Still, the follow-up (committed with doc 66
  P5) clears `in_flight` and `ctl` with one 16-bit store in both the `.S`
  and the inline push, so `ctl` costs no store of its own. `ctl` ==
  `in_flight + 1` is asserted at comptime and in the `.S`. Moved to P1, where they are first used: the keyframe
  `FrameRef` fields and format bump, `host_boundary_depth`, the
  `onRetResume` gating and the walkers' kind branches (§4, §9).
- [~] **P1 — the boundary guard and native activations.**
  - [x] **The boundary guard** (2026-10-22). A due suspend waits while
    `native_reentry_depth > 0` (`Vm.canSuspendHere`, which also holds the
    existing `reg_top_pending` gate), so the three asserts are gone and the
    nested `.suspended` arms are unreachable by construction: the trap and
    the ReleaseFast UB of §1 are fixed. While every re-entry is still a Zig
    recursion, `native_reentry_depth` is the boundary. `host_boundary_depth`
    arrives with the first activation that doesn't recurse, so that a
    converted site becomes stoppable while host functions stay deferred.
    Each `SafepointLine` records `stoppable` with the same predicate, the
    viz slider offers only those steps, and `mahina_replay` reports
    `stopped_at`. `SuspendCtl.index_limit` bounds the index at the replay
    driver's cap, because a cap that falls in nested code is deferred too.
    It sits in `SuspendCtl`'s padding: a new `Vm` field reshuffled the
    asm-visible `Vm` offsets (trace 32 → 16360). Deviation from §8:
    `setSuspendCtl` inside a host function is not an error, because
    deferral already makes it harmless. Found on the way: the wasm index
    pass fed the run VM's effect values, strings and all, to a fresh VM, and
    a `require` program got no index. It now decodes the encoded log, as
    `mahina_replay` does. Tests: `interp_replay_test` "doc 68 defer" (every
    `k` over pcall/xpcall, sort, gsub, `__index`, `__add`: the stop lands on
    the next stoppable step, can be captured as a keyframe, and resumes to
    the full run's output; the index limit), plus the viz wasm and store
    tests. The five `multi-file:` wasm tests pass again.
  - [ ] The resumable-native protocol, with `pcall`/`xpcall` as its first
    users (§5, §7.1). This is where `host_boundary_depth` and the keyframe
    fields of §4.5 land.
- [ ] **P2 — metamethods.** The shared callable driver; every metamethod
  site in §3, fused reads and stores included, runs as a continuation frame;
  `__call` chains stay bounded (§6).
- [ ] **P3 — the other natives.** `dofile`, `require`, `tostring`, `print`,
  `table.sort`, `gsub`, one per commit (§7.2–§7.5).
- [ ] **P4 — gates.** Per site: replay-index and `mahina_replay` stops inside
  it (wasm), capture → restore → recapture identity with the replay
  envelope (§9), GC stress, 8-mode equivalence, the benchmark in §10. The
  index's unstoppable steps shrink to embedder host frames only, and
  the viz "steps inside nested calls skipped" note never shows in the wasm
  playground, which has no embedder.

## 1. Why this exists

`Vm.suspend_ctl` stops the VM at an instruction boundary and returns
`.suspended` to the host, which can resume with `exec()` or take a keyframe and
restore it elsewhere. It only works when nothing but the VM's own frame stack
is between the boundary and the host. Every place where native code calls back
into mahina — a metamethod, `pcall`, a `table.sort` comparator, a `gsub`
replacement function, `require` — runs a nested dispatch on the **Zig** stack
(`callValue`, `interp.zig:2406`; `pushHostCall`/`runPushedFrame`, `:2261`/
`:2288`). A suspend there would have to return through a Zig frame that has no
way to be resumed. So all three entry points assert `suspend_ctl == null`, and
`keyframeser.encodeSnapshot` refuses capture while `native_reentry_depth != 0`
or any frame is `in_flight` (`keyframeser.zig:318-328`).

The visualiser's step replay arms `suspend_ctl` on every run
(`wasm_entry.zig`, `buildReplayIndexInner` and `mahina_replay`). The result,
found on 2026-10-22 while adding multi-file programs:

- In a Debug wasm, any program that calls `pcall`, sorts with a comparator,
  `gsub`s with a function, has a function metamethod, or `require`s a file
  panics on Run.
- In the ReleaseFast wasm the release CLIs embed (`tools/mahina-cli.sh:68`),
  the assert is compiled out and `callValue` meets `.suspended =>
  unreachable`. That is undefined behaviour. The likely lowering treats it as
  `.finished`, so `pcall` returns `true` plus garbage, the orphaned callee
  frame stays on the stack, and the keyframe the step view decodes comes from
  a corrupt frame stack.

`require` is how a multi-file program works, so stepping one cannot work at
all today.

Doc 02 already names the end state. "Host-mediated suspension" — the
replacement for coroutines — is reserved but not built (`02-determinism.md`,
"Host-mediated suspension"), and the `callValue` comment defers the same
thing to "a future host-mediated-suspension chunk". This doc is that chunk,
for the re-entry sites the VM and its stdlib own.

## 2. Options that were weighed

1. **Stop in place, then abort.** When the target step falls inside nested
   code, capture the view there and end the run with a new non-catchable
   error. Every step becomes reachable, but the stop cannot be resumed: it
   fixes the step debugger and nothing else.
2. **Step over nested code.** Nested dispatch neither counts steps nor
   suspends. Small, but `pcall` bodies, module top levels, comparators and
   metamethods become opaque.
3. **Real nested suspension** — this doc. No re-entry the VM owns keeps live
   state on the Zig stack, so a suspend anywhere is the ordinary top-level
   suspend, and a keyframe anywhere is resumable.

## 3. The sites

From the 2026-10-22 survey. Every one funnels into `callValue` or
`pushHostCall`/`runPushedFrame`.

| # | Site | Operation | After the callee returns | State live across the call |
|---|---|---|---|---|
| 1 | `callValueIn` `__call` (`interp.zig:2525`) | `__call` when a host re-entry calls a callable table | results to the caller's `results_out` | `pbase`, the out slice |
| 2–3 | `.call` opcode `__call` (`:7405`, `:7412`) | calling a table with `__call` | scatter into `R[A..]` | the call's registers |
| 4 | `callMeta` (`:7968`) | arith, `unm`, `bnot`, binary `concat`, `len`, `eq`/`ne`, `lt`/`le`/`gt`/`ge`, `__tostring` | first result → `R[A]`; comparisons → truthiness (negated for `ne`) → `R[A]` | two operands |
| 5 | `indexGet` (`:8376`) | `__index` function: `get_index`, fused `get_index2` (two lookups), `mh_table_get` | first result → `R[A]`, or the container of the second lookup | key, the second key |
| 5b | `fusedStore` (`:8347`) | `set_index2` (`a[i][j] = v`): `__index` on the first lookup, then possibly `__newindex` on the second | the result is the container of the store | key2, the value |
| 6–7 | `indexSet` (`:8444`, `:8455`) | `__newindex` function (also via `set_field`, `mh_table_set`) | discarded | — |
| 8–9 | `protectedCall` (`stdlib/errors.zig:78`, `:104`) | `pcall`, `xpcall` and its handler | `true, …`; on error, unwind and `false, err` | entry depth/top, the handler |
| 10 | `dofile` (`stdlib/load.zig:265`) | the loaded chunk | results are the native's results | — |
| 11 | `sortLess` (`stdlib/table.zig:264`) | `table.sort` comparator, O(n log n) calls | truthiness drives the heapsort | heap indices (a handful of ints) |
| 12–13 | `require` (`stdlib/package.zig:335`, `:356`) | searchers, then the loader | searchers: try the next; loader: store in `package.loaded` | name, searcher index, the "not found" message |
| 14 | `addReplFunction` (`stdlib/string.zig:1479`) | `gsub` replacement function, one call per match | append to the output, continue matching | output buffer, source position, count |
| — | `print` (`:9076`), `tostring` (`stdlib/basic.zig:66`) | `__tostring` through `callMeta`; `tostring` can itself be installed as a metamethod | append / return | argument index, partial output |
| 15–17 | `capi.zig:460`, `:844`, `:887` | embedder `mh_call`/`mh_run`/`mh_eval`, host functions | to the embedder | embedder C frames |

None of these is traced: the recorder aborts before each (`.has_metatable`,
`.bad_type`, `.host_barrier`, `.cross_frame`, `.nyi_opcode`), and no
benchmark under `bench/` re-enters on a hot path. Only the embedding benches
(`bench/embed/tracecall_probe.c`) exercise 15–17.

## 4. The frame contract (P0)

LuaJIT never recurses in C for a metamethod. `lj_meta_tget` lays out a
`FRAME_CONT` frame holding a continuation (`lj_cont_ra`, `lj_cont_nop`,
`lj_cont_condt`/`condf`, `lj_cont_cat`) and the interrupted PC, and returns;
the interpreter calls the metamethod as an ordinary Lua frame, and its return
runs the continuation (`vm_x64.dasc` `cont_dispatch`). `pcall` is a
`FRAME_PCALL` frame; frames are typed (`lj_frame.h:24`). Only C library
functions that use `lua_call` (the `table.sort` comparator) still recurse,
and a yield across them is "attempt to yield across C-call boundary". Lua 5.4
gets the same effect with `luaV_finishOp` and `lua_callk`/`lua_pcallk`.

mahina already has most of the substrate: an explicit `Vm.frames` stack, an
iterative dispatch, and frames that stay live until a catcher discards them.
Rev 1 tried to add one `cont` enum and a `u16` beside it. The review showed
that this is not enough state, and that two of its moves broke invariants
(§11). Rev 2's contract:

**4.1 Typed activations.** `CallFrame.closure: *const Closure` becomes a
callee of one of two kinds:

- **Lua** — today's frame: a closure, its proto, its register window.
- **Native activation** — a resumable native (§5): a pointer to its
  registered descriptor (`ResumableNative`: name, step function, number of
  state registers), a register window of arguments plus state, and a step
  cursor in `pc`.

Every stack walker branches on the kind: frame reload and `execImpl`, the GC
(`frameShape`, `frameMask`, `fillKeep`, `assertFrameShapesKnown`),
`callSiteAt`, `describeFault`, `backtraceFrames`, `synthErrorValue`,
`wasm_entry`'s replay cursor, keyframe capture and restore. A native
activation's registers are all live (it has no liveness table) and it shows
in a backtrace as `[native name]`, like Lua's `[C]`. `error(msg, level)`
counts it, as Lua counts a C frame.

**4.2 The interrupted frame stays at its instruction.** When an instruction
`P` hands control to a metamethod or a callback, its frame keeps `pc = P`
and sets `in_flight` — doc 61's own meaning, "inside instruction `pc`, which
is running other code". That keeps three things correct that rev 1 broke:

- GC liveness uses `row(P)`, which still holds the operands only `P` reads
  (`get_index2`'s second key). `row(P + 1)` would let `scrubDeadRegisters`
  nil them mid-metamethod.
- `frameShape` classifies the frame as `.in_flight`, not `.unknown` (which
  the safety-build assertion rejects for a maskable proto).
- A fault the continuation itself raises (`__tostring` returning a table)
  names `P`.

The continuation finishes `P`, clears `in_flight`, and sets `pc = P + 1`.
`in_flight` becomes part of the keyframe (§4.5).

**4.3 What a continuation knows.** A continuation reads its operands from
`code[P]` — the destination, the second key, the value of a fused store —
so most need no payload at all. `CallFrame` gains:

- `cont: Cont` — what the frame's return means for its parent: `.none`
  (today's result wiring), `.finish_op` (finish the parent's in-flight
  instruction `P` with this result; the opcode decides how: store it, store
  its truthiness, its negation, discard it, do the second lookup or store of
  a fused op), `.native_resume` (step the parent native activation with
  these results).
- Nothing else for Lua frames. A native activation's own phase and payload
  live in its state registers (§5).

`finish_op` dispatches on `code[P].op`, which keeps the continuation table in
one place, next to the opcodes it finishes — the `luaV_finishOp` shape.

**4.4 Every push initializes the fields.** Three paths build frames: the Zig
push funnel, the emitted inline native push (`nativegen_emit.zig:987`), and
the host-call assembly (`hostcall_x64.S:246-265`), which writes field by
field. All three write the canonical defaults (`kind = .lua`, `cont = .none`,
`in_flight = false`), so a reused slot can never keep an old continuation,
and the snapshot bytes stay deterministic. `offsets_x64.inc` and the ABI
checker gain the fields; both the safety and non-safety blocks are checked
(2ea4454 shows what a missed offset looks like). Tests reuse a slot after a
special continuation and after an error unwind.

**4.5 Keyframes.** `FrameRef` gains `kind`, `cont`, `in_flight`, and for a
native activation the descriptor's registered name, which restore rebinds as
it rebinds natives today. Restore validates the window against the
descriptor's state count instead of a proto. The snapshot format version
bumps; per global Rule #8 there is no reader for the old version.
`encodeSnapshot`'s refusal changes from "any frame in flight" to "a host
boundary is live" (§8).

**4.6 The JIT.** None of the sites in §3 is recorded, and this design keeps
it that way. Two places still touch the JIT:

- `opRet` calls `trace.onRetResume` on the parent's `pc` after every pop, to
  arm `.cont` recordings after calls. It must only do so when the popped
  frame's `cont == .none`; after `.finish_op` the parent is mid-instruction,
  not past a call.
- Native returns. `emitInlineSelfRetPop` (`nativegen_emit.zig:1133`) only
  pops frames the episode itself pushed, which are ordinary `.none` frames, so
  an episode's entry frame — a metamethod or a callback — always returns
  through tier-0. P0 adds an assertion on the popped frame's `cont`, plus a
  test with a hot loop inside a metamethod and a callback.

## 5. Native activations and the callable driver (P1)

**5.1 The protocol.** A resumable native is registered with a descriptor:

```zig
pub const ResumableNative = struct {
    name: []const u8,          // keyframe identity, as for natives today
    num_state: u16,            // state registers after the arguments
    step: *const fn (vm: *Vm, act: Activation) Error!StepOutcome,
};
pub const StepOutcome = union(enum) {
    /// Call `callee` with the arguments in `args`, wanting `want` results
    /// (`all_results` allowed) placed at `results`.
    call: struct { callee: Value, args: RegRange, want: u16, results: Reg },
    /// Return the values in `results` (any count up to the VM's limits).
    done: RegRange,
};
```

`Activation` is the frame's register window: the step reads and writes its
arguments and state through register indices, never through a gathered
`Value` slice, because the register file is SoA and a scratch slice is
neither rooted nor serialized (`interp.zig:1611`). Everything the native
needs across a call is in those registers, so the GC scans it and the
keyframe saves it, and the step never holds a Zig pointer across a call.

Result counts use the VM's widths, not `u8`: `dofile` forwards whatever its
chunk returns (`load.zig:265`). Only the activation's final `done` publishes
`reg_top`/`reg_top_pending`, through the same code as `opRet`
(`interp.zig:7567-7571`); an intermediate callback return never does
(the producer/consumer atomicity of `interp.zig:685`).

**5.2 The callable driver.** One function issues every call a continuation
or a native activation asks for, whatever the callee is: a Lua closure (push
a frame), a plain native (call it inline), a resumable native (push its
activation), a host function (the embedder boundary, §8), or a table with
`__call` (shift it into the arguments and retry). It keeps `__call` chains
bounded: removing `callValue`'s recursion removes the depth count that ends a
callable-table cycle today, so the driver counts hops itself and raises the
same catchable error.

**5.3 Errors in the dispatcher.** A catchable error used to be caught by a
Zig `catch` around `callValue`. Now `execImpl`'s error path asks the frame
stack: is there a protected activation (§7.1) between the faulting frame and
this dispatch's boundary? Before resuming anywhere it runs what `execWith`'s
errdefers run today — `abortRaised`, `clearPendingExitAnchor`, keeping
`trace.zig:3238`'s JIT-suspension handling — so a recording can never splice
a caught error onto a partial iteration. Then the unwind of
`stdlib/errors.zig:116-144`: close upvalues above the boundary, drop region
activations, restore `depth` and `stack_top`, retire a stale `final_cut`,
reload the frame and reselect the dispatch mode. A regression test catches
an arithmetic error inside a protected function while a recording is active.

## 6. Metamethods (P2)

The opcode that meets a function metamethod no longer calls `callValue`: it
sets its frame in flight at `P` (§4.2), lays out `[handler, args…]` above the
window, and hands the call to the driver with `cont = .finish_op` on the new
frame. `finish_op` then does what `code[P]` needs:

| `code[P]` | Finish |
|---|---|
| arith, `unm`, `bnot`, `concat` (binary), `len`, `get_index`, `get_field` | first result (or nil) → `R[A]` |
| `eq`, `lt`, `le`, `gt`/`ge` (operands swapped) | truthiness → `R[A]` |
| `ne` | its negation → `R[A]` |
| `set_index`, `set_field` | nothing |
| `get_index2` after `__index` on the first lookup | look the second key up in the result; that lookup may hit `__index` again, which is a new `finish_op` on the same `P` with a phase bit |
| `set_index2` after `__index` on the first lookup | store `R[value]` at the second key of the result; may hit `__newindex` |
| `.call` on a table with `__call` | none needed: the driver shifts the table into the arguments and calls the handler as an ordinary frame, as LuaJIT does |

The two fused ops need one bit of phase (which lookup is pending). It goes in
a `u8 cont_phase` beside `cont`, set only by `finish_op`.

A native metamethod (a host function, or `tostring` installed as
`__tostring`) goes through the driver too, so `tostring`'s own callback is a
resumable native's and suspends like any other (§7.5). `mh_table_get`/
`mh_table_set` start at an embedder boundary and stay synchronous (§8).

## 7. The natives

### 7.1 `pcall` and `xpcall` (P1)

`pcall` and `xpcall` are the protocol's first resumable natives, because a
protected call needs an activation that exists before its callee does:
`pcall(nil)`, `pcall(error, "x")`, `pcall(pcall, f)` and `pcall(t)` with a
callable `t` must all behave as today, and some of them fail before any frame
for the callee could be pushed.

The activation's state registers: the phase (`calling` or `handling`), the
handler (xpcall), and the error value. Step 0 asks the driver to call `f`
with `want = all_results`. On `done`, the results become `true, …` (shifted
up by one, with `reg_top` stamped when the caller wanted all results).

On a catchable error, §5.3's search finds the **nearest** protected
activation above the boundary that is in phase `calling`:

- `pcall`: unwind to it, then it returns `false, err`.
- `xpcall`: set its phase to `handling`, save the error value in its state,
  and call the handler *on top of the faulting frames* (Lua's semantics and
  today's, `errors.zig:104`) with `cont = .native_resume`. When the handler
  returns, unwind the faulting frames and return `false, handler results…`.
  The results are moved below the unwind point first, so closing upvalues
  and dropping the faulting frames can't clobber them.

A protection in phase `handling` is skipped by the search, so a catchable
error inside the handler goes to a newer protection if the handler has one
(a `pcall` inside the handler still works) and otherwise becomes "error in
error handling" at this protection — never a second run of the handler. A
non-catchable error ignores every protection and propagates with the frames
retained, as today.

**Ownership at an embedder entry.** A dispatch started by `mh_call` has a
boundary frame at `stop_depth - 1`. The search covers the frames this
dispatch pushed, `[stop_depth - 1, depth)`, the boundary frame included, so a
`pcall` the embedder calls directly through `mh_call` still returns
`false, err` to it. It never looks below: a protection under the embedder
entry belongs to the guest code that called the embedder, and the error goes
to the embedder first, as it does today. Tests cover both directions.

### 7.2 `table.sort`

The heapsort's state is `n`, the phase (heapify or pop), the outer index,
and the sift-down's `root`/`child`/`end` — six integer registers — plus the
comparator. Each comparison asks the driver to call the comparator with
`t[a], t[b]`, wanting one result. No allocation per comparison. The
no-comparator path stays a single native call with no step machinery.

### 7.3 `require` and `dofile`

`require`: the module name, the searcher index, the loader and its data, and
the "not found" diagnostics. One call per searcher, then one for the loader;
storing in `package.loaded` is the step after it. `package.searchers` is a
mutable table (`package.zig:327`), so the number of searchers is unbounded
and rebuilding the diagnostics string per searcher would be quadratic: the
diagnostics use Q2's builder.

`dofile`: one call of the loaded chunk, wanting all results, which become
its own.

### 7.4 `gsub` with a function replacement

Between two calls the state is the source position, the pending match's
start and end (needed after the callback to keep the original match on
`nil`/`false` and to step past an empty match, `string.zig:1532`), the match
count, `max_n`, and the phase (matching or awaiting a replacement). The
matcher's capture stack is rebuilt per match, and the captures are the
callback's arguments. The output so far is Q2:

- (a) a GC-owned growable byte buffer, rooted from a state register: O(1)
  amortized append, serialized as its used bytes, a new heap object kind with
  GC, keyframe and schema support (codex's pick; it also serves `require`);
- (b) the pieces in a table, joined at `done`: no new kind, but a table slot
  and a string per piece (antigravity's pick).

**Decided: (a)** (status block). The table and string replacements keep
today's single native call.

### 7.5 `print` and `tostring`

`print`: the argument index is state, and each argument with `__tostring` is
a call. The pieces already written to `vm.out` stay written, as today.
`tostring`: one call, then check that the result is a string.

## 8. The embedder boundary

An embedder's host function is C (or Zig through the C API); while it runs,
its frames are on the native stack and nothing can resume them. This is
Lua's "C-call boundary", and it stays one.

`native_reentry_depth` does not see every such frame: `callHostNative` runs a
host function called straight from bytecode without raising it
(`interp.zig:2351`). P0 adds a `host_boundary_depth` raised around every
host function invocation and every C API entry that runs guest code
(`mh_call`, `mh_run`, `mh_eval`, `mh_table_get`/`mh_table_set`). It is what
`encodeSnapshot` refuses on, and what Q3's policy reads:

- (a) **Defer** (antigravity). The suspend check also requires
  `host_boundary_depth == 0`; a suspend due inside a host call fires at the
  first boundary after it returns. The replay index records the steps
  inside but cannot stop at them. `setSuspendCtl` from inside a host
  function is an API error. Caveats (codex): the host must be told where the
  VM actually stopped, a top-level host entry can return without reaching
  another boundary, and a long callback can run past the replay-index cap.
- (b) **Refuse** (codex). Arming fails while `host_boundary_depth > 0`, and
  entering a host boundary while a suspend is armed fails with an API-level
  error that guest code cannot catch. Disarming always works. Caveat
  (antigravity): any program that calls an embedder binding cannot be
  stepped.

**Decided: (a), defer** (status block). The three asserts and the two
`.suspended => unreachable` arms go:
the policy makes them impossible by construction. P1 lands the policy first,
so the undefined behaviour is gone before the rest of the design.

## 9. Resuming a keyframe

A keyframe is the heap, the stack, the frames and the loaded chunks
(`keyframeser.zig:393`). Resuming one also needs what the replay tests
reattach beside it (`keyframeser_replay_test.zig:47`, `:366`): the effect-log
position, the PRNG state, the committed-effect count, the output so far.
This doc's "a keyframe anywhere is resumable" means that **replay envelope**
plus the keyframe; the schema split stays as it is. The P4 restore tests
resume from inside nested code *after* an effect has committed there — a
`require` after its `file_read`, a comparator that drew a random number — not
only from pure callbacks or replay-from-start.

## 10. Performance

- **Frame layout.** The x64 frame stride is 80 bytes today
  (`offsets_x64.inc:62`). `kind`, `cont` and `cont_phase` are three bytes;
  they go in the padding after `in_flight`/`multret_top` if they fit, and the
  stride is measured either way. The source records a ~4% regression from
  merely moving call-handler code (`interp.zig:2157`), so the ordinary call
  and return paths stay outlined as they are, and `opRet`'s new test reads a
  byte it already has in cache.
- **Budgets.** Tier-0 board rows that are call/return heavy (recursive fib,
  method calls, binary-trees): within run-to-run noise on instruction counts.
  A new `bench/stdlib/` micro-bench at 10⁶ calls each: `__index`, `__add`
  and `__eq` functions, `pcall` of a trivial function, `table.sort` with a
  comparator, `gsub` with a function. Metamethods and `pcall` should get
  faster (no nested `execWithEntry` setup); `table.sort` with a comparator
  may cost up to 10% more. Zero allocations per comparison or per metamethod
  call; native state copying, gsub output and `require` diagnostics linear
  in their size. Numbers go in §12; no timing assertions in tests.

## 11. Round-1 review (2026-10-22)

`docs/reviews/doc68/codex-r1.md` and `antigravity-r1.md`. They agreed on the
four findings that broke rev 1, and rev 2 is built around them:

- A native can't sit in `CallFrame.closure` (codex 1, antigravity F-1, F-5)
  → typed activations, §4.1.
- Moving the parent to `P + 1` breaks GC liveness, `frameShape` and fault
  attribution (codex 2, antigravity F-2, F-8) → the parent stays in flight
  at `P`, §4.2.
- `xpcall` needs a handling phase or a failing handler loops (codex 4,
  antigravity F-3) → phases and the "nearest `calling` protection" search,
  §7.1.
- Fused `set_index2` was missing (codex 7, antigravity F-4) → §3, §6.

Also taken: protection before callable resolution and the `pcall` → native
activation ordering (codex 3, antigravity F-7); the `stop_depth` ownership
contract (codex 5); JIT cleanup on caught errors (codex 6); the register and
result protocol (codex 8, antigravity F-6); push-path initialization (codex
9, antigravity F-9); `host_boundary_depth` (codex 10); gsub's pending match
(codex 11); the replay envelope (codex 12); frame layout and linear-cost
budgets (codex 13); `onRetResume` only after `.none` (antigravity F-10).
Codex's note that native returns already only pop `.none` frames turned
§4.6's "exit on every continuation return" into an assertion.

Split, for Bart: Q2 (codex a byte buffer, antigravity a table) and Q3
(codex refuse, antigravity defer).

## 12. Measurements

_(filled in as phases land)_

## 13. References

- `docs/design/02-determinism.md` — "Host-mediated suspension".
- `docs/design/04-snapshot-replay-schema.md` — F2c mid-execution capture and
  resume; the replay-to-k browser driver.
- `docs/design/61-gc-liveness-masking.md` §4 — frame shapes, `in_flight`.
- `docs/design/63-trace-host-calls.md` — JIT suspension around host calls
  (`TraceState.suspend_depth`, unrelated to `suspend_ctl` despite the name).
- `docs/reviews/doc68/` — round-1 reviews.
- LuaJIT: `lj_meta.c` (`mmcall`, `lj_cont_*`), `vm_x64.dasc`
  (`cont_dispatch`, pcall's `FRAME_PCALL`), `lj_frame.h` (frame types),
  `lj_record.c` (`rec_mm_prep`).
- Lua 5.4: `luaV_finishOp`, `lua_callk`/`lua_pcallk` (from memory; no 5.4
  tree is checked out here).
