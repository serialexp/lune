# 27 — MULTRET nested-call recording ("multinest")

**Status: LANDED (2026-08-28).** Codex review approved the architecture with
two MUST-FIX items, both folded in below (§3a shadow lifetime + width; §5
rewritten) and implemented. See "Landed results" at the end.
Predecessors: doc 23 (builtin recording), doc 24 (on-trace allocation),
doc 26 (upper/lower/codepoint). This arc is **recorder-only**: no new IR ops,
no tier-1a or nativegen changes, no tier-0 changes.

## 1. Problem

The compiler encodes a call whose **last argument is itself a call** as a
dynamic-multret pair (`compiler.zig` `compileArgList`, lines ~1256–1263):

```
call r_inner, b=<fixed>, c=all_results     ; producer: inner call, dynamic results
call r_outer, b=all_results, c=<nwanted>   ; consumer: outer call, dynamic args
```

and a **`return f(...)`** as the sibling pair (`compileRet`, ~793–794):

```
call r, b=<fixed>, c=all_results           ; producer
ret  r, b=all_results                      ; consumer
```

Tier-0 resolves the dynamic count from the live stack top
(`interp.zig` `.call`, ~3559):

```zig
const nargs: usize = if (instr.b == bytecode.all_results) blk: {
    self.reg_top_pending = false;
    break :blk self.reg_top - (base + a + 1);
} else instr.b;
```

The recorder aborts `.cross_frame` at **four** sites instead
(`trace.zig` 13406/13407 in `recCall`, 13473/13474 in the `recBuiltin`
preamble, 14108 in `recReturn`). Consequence: `lower(upper(s))` — the most
ordinary way to compose two builtins — kills the whole trace, while the
semantically identical `local u = upper(s); lower(u)` records fine. That is a
composition cliff in the *language*, not a benchmark quirk (Z-6: any `f(g(x))`
benefits). Evidence: doc 26 landed all of upper/lower/codepoint and str_manip
did not move — `--dump-aborts` shows exactly one `.cross_frame` at the nested
call, and the intermediate-local rewrite of the same line records with zero
aborts. str_manip (5.1× LuaJIT) has this as its sole remaining blocker.

## 2. How LuaJIT does it (`lj_record.c`)

```c
/* L->top is set to L->base+ra+rc+NARGS-1+1. See lj_dispatch_ins(). */
case BC_CALLM:
  rc = (BCReg)(J->L->top - J->L->base) - ra - LJ_FR2;
  /* fallthrough */
case BC_CALL:
  lj_record_call(J, ra, (ptrdiff_t)rc-1);
```

Pall reads the **live interpreter top**: his recorder hook fires after the
producer executed and before the consumer does, so `L->top` is exactly the
number the interpreter itself is about to consume, and CALLM collapses into
the fixed-arity CALL path. `BC_RETM` does the same for returns. The resolved
count is baked into the trace. (This citation establishes the live-top
*resolution mechanism* only; the invariance argument that makes baking the
count sound is lune's own, in §6.)

lune's dispatch has the same window — the mirror records each instruction
*before* tier-0 executes it (`interp.zig` ~2172), so at the consumer,
`vm.reg_top`/`reg_top_pending` are live. But we do **not** need the VM
channel at all: unlike LuaJIT (whose recorder tolerates producers it models
loosely), every lune producer that can precede a recordable consumer was
*itself just recorded* — the recorder already knows exactly how many values
it produced and where. A recorder-local shadow of the producer/consumer
handshake is therefore complete, needs no new `*Vm` plumbing, and keeps the
resolved count derived from what the recorder *proved* rather than from what
tier-0 *happened* to do (§6 makes this the soundness argument; the two always
agree, but the shadow makes the derivation checkable).

## 3. Design: a recorder-local multret shadow

New recorder state (in `rec`, alongside `reg_map`/`base_off`):

```zig
/// Frame-relative one-past-the-end of the values the immediately-preceding
/// recorded instruction produced under `c == all_results` — the recorder's
/// shadow of tier-0's `reg_top`/`reg_top_pending` handshake. Set only by a
/// successfully recorded producer; valid for exactly one instruction
/// (mirroring tier-0's `reg_top_pending` discipline); expressed in the
/// frame-space of the instruction that will consume it. `null` = no pending
/// producer — every consumer fails closed on it.
multret_top: ?u32 = null, // u32, not u16 — see §3a (width)
```

**One-instruction validity** is enforced structurally at the top of
`recordOne`: stash and clear, so only the immediately-next instruction can
observe a pending producer — exactly tier-0's `reg_top_pending` scope:

```zig
const multret = self.rec.multret_top;   // pending producer, if any
self.rec.multret_top = null;            // consumed or dead after this instr
```

(consumer arms receive `multret` via a field read of the stash — mechanically,
a `multret_prev` field or a parameter; implementation's choice, the contract
is "visible for one instruction only").

### 3a. Shadow lifetime and width (codex MUST-FIX, both)

**Lifetime.** The stash-and-clear runs only inside a live `recordOne` — but
`recordInstr` can abort for `maxrecord` *before* reaching it
(`trace.zig:11885`), leaving a shadow set by the previous (successfully
recorded) producer in place. `Recorder.reset` re-arms fields explicitly, not
via struct defaults, so without an explicit clear a **later recording** could
start at an `all_results` consumer, find the stale shadow, and bake an
unrelated count — silent misrecording, not an abort. The complete invariant:

* stash-and-clear at the top of every live `recordOne`;
* `multret_top = null` in `Recorder.reset` (the soundness boundary), and in
  abort/commit as defense-in-depth;
* no consumer may observe the field once recording is inactive.

Regression test: producer records, consumer trips `maxrecord` pre-switch, a
later recording starts at an `all_results` consumer → must abort
`.cross_frame`.

**Width.** The register slab has 65,536 slots, so a valid one-past-the-end
top can be 65,536 — outside `u16` — and a resolved count of 65,535 collides
with the `all_results` sentinel itself. All shadow arithmetic
(`instr.a + 1`, `fr.ret_dest + produced`, the subtractions in D2/D3/D5) is
done in `u32`; the effective `b`/`c` conversion aborts fail-closed whenever
the result cannot be represented **below** `bytecode.all_results`.
Practically unreachable shapes, but the failure mode without the check is
wrong code, so the check is not optional.

### 3b. Dual-role calls: stash the original flags before rewriting

The middle call of `f(g(h()))` is simultaneously a **consumer**
(`b == all_results`, resolves via the pending shadow) and a **producer**
(`c == all_results`, must publish a new shadow). The effective-instr rewrite
destroys both sentinels, so the preamble must capture
`was_dynamic_b`/`was_dynamic_c` *before* constructing the effective
instruction; the postamble publishes the new shadow iff `was_dynamic_c` (and
the arm is whitelisted). A depth-3 chain is the direct test for this.

### D1 — builtin producer: `recBuiltin` accepts `c == all_results` for single-result arms

The preamble's `instr.c == all_results → abort` becomes a **per-arm
whitelist**. Of the 20 recorded builtins, only `codepoint` and `select` carry
a `.multi` projection in the registry (`string.zig:1346`, `basic.zig:291`) —
under `c == all_results` tier-0's multi path can produce ≠1 values for them
(`cp(s,1,3)` → 3 values), so they stay excluded and abort as today. Every
other arm is structurally single-result: tier-0's `stampSingleResult` writes
exactly one value at `a` and sets `reg_top = base + a + 1`. For those:

* dispatch the arm with an **effective instr** whose `c = 1` (the arm's
  result write — `setReg(instr.a, ref)` — is already the exact mirror of
  `stampSingleResult`'s one-value write; nothing else in any arm reads `c`
  beyond the `== 1` check);
* after the arm returns, set `self.rec.multret_top = instr.a + 1`. (If the
  arm aborted, recording is already dead and the write is inert; a
  consumer can only ever run on a live recording, so shadow truthfulness —
  "set only by a successfully recorded producer" — holds.)

The whitelist is a `switch (rb)` (compile-time exhaustive, so a future
registry row must take a stance), not a runtime `nat.multi == null` probe.

### D2 — builtin consumer: `recBuiltin` resolves `b == all_results`

The preamble's `instr.b == all_results → abort` becomes:

```zig
const nargs: u16 = if (instr.b == bytecode.all_results)
    (multret orelse return self.abort(.cross_frame)) - (instr.a + 1)
else
    instr.b;
```

and the arm is dispatched with effective `b = nargs`. `multret orelse abort`
fails closed on every shape where the producer was not a recorded
one-past-the-end: vararg spreads (`f(a, ...)` — `compileSpreadInPlace` is not
in the record switch), producers whose own arm aborted (recording already
dead), and recordings that *start* at the consumer (§5). Arms are otherwise
untouched — `cp(upper(s))` enters `recBSCodepoint` with `b = 1` and records
exactly as if the source had used an intermediate local.

`nargs` arithmetic is frame-relative on both sides (`multret` stores `a+1`
of the producer; the consumer subtracts its own `a+1`), and producer and
consumer always share a frame (§5), so `base` never enters. For
`f(g(x))`: producer at `a_outer+1` yields `multret = a_outer+2`, so
`nargs = 1`. For `f(p, q, g(x))`: producer at `a_outer+3` → `nargs = 3`.
For `f(g())` where `g` returns nothing (closure producer, D4 with
`produced = 0`): `multret = a_outer+1` → `nargs = 0`.

### D3 — closure consumer: `recCall` resolves `b == all_results`

Same three lines as D2 replace the abort at 13406; the resolved `nargs`
feeds the existing S1 seeding loop (`i < cp.num_params and i < nargs`)
unchanged. The last-arg slot's ref is the producer's `setReg` result, so
`refOf` resolves it without a `slot_load`.

### D4 — closure producer: `recCall` defers `c == all_results` to `recReturn`

The abort at 13407 is lifted: `ret_count = instr.c` already stores the
sentinel verbatim (`RecFrame.ret_count: u16`, `all_results = maxInt(u16)`).
`recReturn` gains the `want == all_results` arm:

```zig
const want: u16 = if (fr.ret_count == bytecode.all_results) produced else fr.ret_count;
```

— copy exactly `produced` results to `fr.ret_dest` (no nil-fill; tier-0's
`wants_all` arm takes everything produced and nothing more), then after
restoring `base_off`, set `multret_top = fr.ret_dest + produced` — expressed
in the **caller's** frame space, which is the space of the next recorded
instruction (the consumer). This is what makes `f(luaFn(x))` and
`return luaFn(x)` record, and it composes: a callee whose own `ret` consumed
a shadow (D5) re-exports one for its caller.

### D5 — return consumer: `recReturn` resolves `b == all_results`

The abort at 14108 becomes the same resolution in **callee** frame space
(where `ret a` reads its result slots and where a producer inside the callee
set the shadow):

```zig
const produced: u16 = if (instr.b == bytecode.all_results)
    (multret orelse return self.abort(.cross_frame)) - instr.a
else
    instr.b;
```

`return g(x)` inside an inlined callee then flows through the existing
result-mapping loop. Note the anchor-frame `ret` (inline_depth == 0) still
aborts before any of this — unchanged.

## 4. Why arbitrary nesting is free

No mechanism above mentions depth. `f(g(h(x)))` is three CALLs executing
innermost-first; each producer/consumer pair resolves independently through
the same shadow, one instruction apart. Chains through closures
(`f(luaFn(g(x)))`, `return f(g(x))`) compose via D4/D5 re-exporting the
shadow across the frame boundary. The compiler guarantees at most one
pending producer at a time ("only the tail position is variadic" —
`compileArgList` doc comment), so a single `?u16` is the whole state.

## 5. The deopt invariant: no resumable point between producer and consumer

The hazard to rule out: a guard emitted while recording the consumer fails at
runtime, tier-0 resumes at the consumer's pc, re-executes
`call b=all_results`, and reads a `vm.reg_top` nothing set → garbage nargs.
LuaJIT needs `J->needsnap` machinery for exactly this class. **lune needs
nothing**, for two independent structural reasons:

1. **Coherent-anchor resumption.** Every trace-execution return supplies
   registers coherent for the pc it hands back, and no path resumes tier-0 at
   an arbitrary guard's stamped `exit_pc`. Ordinary side exits discard the
   partial iteration and tier-0 re-runs it from the loop header
   (`interp.zig` ~3857: "regs coherent for the header … tier-0 then re-runs
   the loop header to redo the deopt iteration") — the deopt iteration
   re-executes the producer in tier-0 itself, which sets `reg_top` before the
   consumer needs it. The other resumption pcs (`driveChain` returns:
   inner-root/owner anchors, post-loop continuation pcs) are all coherent
   anchors — committed-state boundaries, never mid-pair.
2. **Pair adjacency.** Producer and consumer are adjacent instructions by
   construction, and tier-0's own correctness already depends on nothing
   landing between them (`reg_top` is "valid only for the single instruction
   that immediately follows the producer"; `reg_top_pending` suppresses the
   GC/suspend safepoint — `interp.zig` ~2092/~2115; the compiler never emits
   a jump target between them — a loop header or loop-done pc in the gap
   would break tier-0 with or without a JIT). So no anchor, no back-edge, no
   coherent resumption pc can split the pair.

Recording starts are anchor-shaped too: root recordings arm at back-edge
targets, prime-side recordings at the failed trace's own coherent anchor,
and continuation recordings at a numeric-for loop-done exit — none of these
can be the consumer of a pair (a jump target or loop boundary between the
pair is impossible per (2)). If a future anchor kind ever did land on a
consumer, it sees `b == all_results` with a `null` shadow and aborts
`.cross_frame` — the fail-closed default covers even the shapes we believe
unreachable. (A v2 could seed the shadow from a supplied `reg_top` channel
for such starts, LuaJIT-style; deliberately out of scope.)

## 6. Soundness: the baked count is path-invariant

The resolved `nargs`/`produced` is a compile-time constant of the trace, so
it must be identical on every future execution that passes the trace's
guards. It is:

* **Builtin producer (D1):** `guard_builtin` pins the callee identity; being
  single-result is a static property of that builtin (no `.multi`
  projection — tier-0's `all` path calls `nat.func` and stamps exactly one
  value, unconditionally).
* **Closure producer (D4/D5):** `guard_func` pins the callee proto; *which*
  `ret` executes and its fixed `b` are pinned by the branch guards along the
  recorded path; a `ret b=all_results` recurses into this same argument via
  its own producer.

This is the same invariance argument LuaJIT relies on — his `L->top` read is
sound only because the recorded producer reproduces its count — made explicit
by deriving the count from the recorder's own knowledge instead of the VM's
dynamic state. Determinism/replay is untouched: recording decisions depend
only on recorded state (no clock, no addresses), tier-0 semantics are
unchanged, and 8-mode equivalence holds because traces produced with the
feature record strictly more of the *same* semantics.

## 7. Non-goals (v1)

* **Vararg producers** — `f(a, ...)` (spread) stays aborted via null shadow;
  `rec_varg` is its own future arc.
* **Multi-result builtin producers** — `f(cp(s,1,3))`, `f(select(2,...))`:
  excluded by the D1 whitelist; would need result-count proofs
  (e.g. `j == i` konst) that no current benchmark motivates.
* **Table constructors `{g()}`** — no `all_results` bytecode shape exists for
  them in the compiler today; nothing to record.
* **`reg_top` channel cross-check** — considered (LuaJIT parity, §5 side-trace
  seeding); rejected for v1 as new VM→recorder plumbing with no consumer.
  The shadow-vs-`reg_top` agreement is structural (both mirror the same
  producer), not worth a runtime assert channel yet.

## 8. Tests

All in `interp_trace_test.zig` unless noted; every functional test asserts
tier parity (t0 vs `--trace` vs native where applicable) per Z-3.

1. **Flagship end-to-end:** `lower(upper(s))` in a hot loop records, compiles
   native (`native_entries > 0`), zero aborts, byte-identical output across
   modes; trace contains `supper` feeding `slower` with no intervening
   `guard_string` (the doc-26 `isProvenStringRef` chain now actually fires on
   the nested form).
2. **Depth-3:** `upper(lower(upper(s)))` — proves §4 (no depth anywhere).
3. **Mixed args:** a trailing call that is *not* the only argument — e.g.
   `sub(s, 2, len(u))` composed so the inner call sits at `a_outer+3`
   (`nargs = 3`). Asserts via the recorded IR that the consumer resolved the
   full fixed-prefix-plus-producer arity, not just the depth-1 single-arg
   case.
4. **Closure consumer:** `luaFn(upper(s))` with `luaFn` inlinable — D3.
5. **Closure producer:** `upper(luaFn(s))` where `luaFn` ends in a fixed
   `ret` — D4; and `return upper(s)` inside an inlined callee — D5; and the
   composed `upper(luaFn(s))` where `luaFn` is `return lower(x)` — D4+D5
   shadow re-export.
6. **Return prefixes (codex #7):** `return prefix, g()` compiles the producer
   above the prefix and `ret base, all_results` — `produced` must count both.
   Legs: `g` returning zero, one, and multiple fixed values; a closure
   producer returning ≥2 fixed values into a caller wanting fixed 2; the same
   through an outer closure consumer. These are exactly where an
   off-by-prefix or D4 frame-space error silently changes *values*, not just
   arity.
7. **Method-call consumer (codex #8):** `obj:m(prefix, g())` — the implicit
   `self` precedes the dynamic tail (`compileMethodArgs`), so the resolved
   count must be `self + prefix + produced`.
8. **Resolved-`b`-dependent arms (codex #9):** the effective `b` is
   semantically load-bearing, not just an arity check — `sub`'s optional `j`,
   `codepoint`'s optional indices, `tonumber`'s base form, and
   `select('#', …)`'s *result* all read it. At least `select('#', g())`
   (whose folded konst result is directly wrong if the arithmetic is off) and
   one optional-argument arm (`sub(s, 2, len(u))` from test 3 counts).
9. **`rawset` producer (codex #10):** the one arm whose result write is
   conditional on `c == 1` — under producer `c = all_results` the effective
   `c = 1` rewrite must still define the result slot before the shadow is
   published.
10. **Zero-produced:** `f(g())` with `g` an inlined closure returning nothing
   → resolution yields `nargs = 0`; assert the consumer *arm's own* arity
   abort fires (not `.cross_frame` at the preamble) — pinning that
   resolution happened.
11. **Fail-closed matrix:** (a) `upper(cp(s, 1, 3))` — multi producer,
   aborts, parity holds; (b) `f(a, ...)` vararg spread under recording —
   aborts as today; (c) a recording that *starts* at an `all_results`
   consumer (null shadow) — aborts `.cross_frame`, no crash, parity holds.
12. **Stale-shadow regression (§3a):** producer records, consumer trips
   `maxrecord` pre-switch, a later recording starts at an `all_results`
   consumer → `.cross_frame`, never a baked count.
13. **Deopt through the pair:** a nested-call loop where a consumer-arm guard
   fails mid-run (e.g. argument type flips) — tier-0 anchor-replay redoes the
   iteration correctly; byte-identical output vs pure tier-0; also under
   `effect_mode = .record`/`.replay` (unicode pin interaction with
   upper/lower producers).
14. **Lowering test** (`nativegen_lowering_test.zig`): none needed — no new
   IR ops; the flagship's `native_entries > 0` covers the composed pipeline.

## 9. Gates and expected outcome

* `just test` green; hashgate 84/84; `just bench` 28/28 `cross=ok`.
* str_manip: the nested `lower(upper(a))` line stops aborting;
  `--dump-aborts` on str_manip shows zero `.cross_frame` at that pc. Board
  target: meaningful move toward LuaJIT (from 5.1×); the `rep(char(..),4,"-")`
  1/64 branch stays a side-exit by design.
* Whole-board A/B (shadow baseline per the `just shadow` discipline): no
  regression outside noise anywhere else — the feature only adds recorded
  shapes; any previously-recording trace records byte-identically (stash/clear
  touches no existing path when no producer is pending).

## 10. Landing plan

Single commit: the recorder deltas are ~100 lines across five sites in
`trace.zig` plus tests. (Splitting D1/D2 from D4/D5 would leave a commit
where `f(luaFn(x))` aborts but `f(g(x))` records — a coherent but pointless
intermediate; the mechanism is one idea.) Same-change updates: TODO.md #1
(resolved), CURRENT_TASK.md, this doc's status. No inventory changes (Z-5:
recording is not an inventory dimension).

## 11. Landed results (2026-08-28)

Implemented exactly as specified (D1–D5, §3a lifetime + u32 width, §3b
dual-role stash), single commit. Deltas from the plan, all minor:

* `recReturn` gained a reg_map bounds check before the mapping loop (the
  dynamic shapes can write above the caller's fixed window; aborts
  `.too_deep` like `recCall`'s reservation check) — an OOB the fixed shapes
  could never reach.
* The stash is threaded as a **parameter** (`recordOne` → `recCall` →
  `recBuiltin`, and `recordOne` → `recReturn`) rather than a second field —
  same one-instruction contract, enforced by scope.
* §8 test 7(c) ("recording starts at a consumer") is not separately
  arranged: per the corrected §5 no present anchor kind can land there, and
  the observable contract (null shadow → `.cross_frame`) is covered by the
  §3a lifetime tests. Test 6's zero-produced leg asserts recording continues
  (a closure consumer accepting 0 args) rather than an arm-arity abort.

**Verification.** 14 new tests (interp_trace_test.zig, "doc 27" prefix +
the §3a lifetime pair), all through the 10-leg GC×mode matrix plus a
dedicated `entries > 0` record leg (`expectRecordedProgram` — parity alone
cannot distinguish "recorded" from "aborted silently"). Full suite green;
hashgate 84/84; board 28/28 `cross=ok`, `luajit ok`. Probes: `lower(upper(s))`,
depth-3, mixed-arg, closure producer/consumer, and the D1+D2+D4+D5
`up(ap(low, base))` chain all record with **zero aborts** and run natively.

**Board.** Whole-board A/B vs a HEAD shadow baseline: flat within noise
everywhere (two rows that looked inflated — recursive-fib, scimark-fft — had
LuaJIT's own column inflated too; re-runs confirmed environmental contention,
not the change). str_manip: jit 24.6→23.3 ms, ratio 5.2×→5.0×.

**The honest str_manip outcome.** The `.cross_frame` MULTRET abort is GONE
(`--dump-aborts` on str_manip shows zero) — but the same loop now dies at the
NEXT frontier: `recInputGet`'s `MAX_TRACE_INPUTS = 8` cap (`too_deep` at a
`get_upval`, 518 hits), because the loop reads more than 8 distinct
cached-builtin upvalues and the pre-27 recording never survived long enough
to reach that cap. Recorded in TODO.md as str_manip's new sole blocker with
the measurement caveats (input cost is per-trace-entry). The composition
cliff this doc targeted is closed for the language as a whole — any
`f(g(x))`, any depth, closures included.

> **CORRECTION (2026-08-28, input-cap arc).** The "new sole blocker" claim in
> the paragraph above was WRONG. str_manip's main path reads only SEVEN
> upvalues, and its 74-op trace was committing at cap 8 all along — the 518
> `too_deep` hits were the rare 1/64-branch's *side-traces* (which
> additionally read `char`/`rep`), and at any cap ≥16 those same side-traces
> die at 3-arg `rep` instead (rep3 frontier). The bench is unchanged at any
> cap value; its remaining time is op-core cost (caseCore/memcpy/wyhash/
> subCore…), not coverage. `MAX_TRACE_INPUTS` was still raised 8→64 after an
> empirical sweep showed the input machinery is free through N=64 — see
> TODO.md's corrected entry and CURRENT_TASK LATEST-94.
