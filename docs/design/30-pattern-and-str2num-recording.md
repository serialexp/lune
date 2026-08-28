# 30 — recording the pattern engine and string→number (killing host_barrier on the string loops)

Status: **DRAFT v3 — two codex review rounds folded in (ledger at bottom;
v1 BLOCKED → v2 redesign → round-2 found three replay/layout blockers in the
composite op, fixed below). Pending Bart's go-ahead.** Depends on doc 29's
cores landing first (the callouts invoke them); independent of doc 29's
A5/B2 choices.
Owner: Bart
Last updated: 2026-08-28

Prerequisite reading: doc 23 (RecordedBuiltin discipline), doc 24 (on-trace
allocation: `guard_gc` bound A, id-stream lemma, ≤1-link audit, the
dead-allocation rule at doc 24:140), doc 26 (callout kernels), doc 27
(multret shadow — its §7 exclusion of multi-result producers is partially
lifted here), doc 29 (the cores).

## 1. Why this exists

All four pattern/format string benches run 100% tier-0: `--dump-aborts` shows
`host_barrier` at the builtin `call` sites (find_match 1 site, gmatch 2,
gsub 1, format 1), and the board shows jit≈t0 on all four. The single abort
site is `trace.zig:13427` — `Native.recorded == null`. Tier-0 dispatch is
~25-30% of find_match/gmatch (~6.4 ms and ~18 ms). LuaJIT cannot trace these
(`recff_string_find` → NYI on any real pattern, `lj_ffrecord.c:997`) — its
recorder and matcher never meet. **lune's can**: the recorder observes
runtime values and the konst pool, and the matcher is a pure function in
`pattern.zig`. Recording pattern calls is a beyond-Pall move that is
nevertheless pure doc-23/24 discipline — no new determinism surface (Z-6:
any program calling `find`/`match`/`gmatch`/`tonumber` in a hot loop wins;
`gsub`-with-function-repl stays a barrier exactly as LuaJIT's).

The four structural blockers (machinery audit, 2026-08-28) and their answers:

| blocker | answer |
|---|---|
| multi-result: every arm requires `instr.c == 1`; IR defines 1 reg/op | decompose: one scratch-writing match op + per-result projection ops; the arm defines all wanted regs, nil-padding the rest (§4, review M04 — multi-`setReg` per recorded call is verified sound: `trace.zig:12165`, commit φ-scan `trace.zig:11516`) |
| unbounded allocation: captures intern N times vs the ≤1-link audit | **pattern census**: capture count/kinds are static once the pattern is pinned; each string capture is its own `.alloc` projection, emitted for **every capture tier-0 materializes** (§3, review B02) |
| VM re-entry (`gsub` function repl) | stays a barrier (non-goal, same as LuaJIT) |
| heap mutation (gmatch state-table pos write) | the iterator records as ONE composite scratch op whose shim owns the state read/match/pos-write (§6, review B01 — the v1 "existing get/store shapes" plan was false: `.value`-lane loads of strings/scalars abort `.nyi_opcode` at `trace.zig:12403` and `.value`-lane array stores abort at `trace.zig:12623`) |

## 2. The record-time principles

**P1 — a censused pattern, always.** Every op here requires the pattern to be
**pinned at record time**: either a konst string ref, or an observed runtime
string pinned by an **interned-identity guard** (§2a). The arm then runs a
**pattern census** (a pure `pattern.zig` walk): capture count `ncap`,
per-capture kind (position → int, span → string), leading-`^` anchor,
`hasSpecials`, and static malformedness (malformed → abort `.bad_type`; the
pattern never changes under the pin, so tier-0's error is tier-0's business).
Unpinnable pattern → `abort(.bad_type)`. The census makes result arity, the
projection list, and the `guard_gc` contribution compile-time constants of
the trace. (Review m01: a pattern cached in a local outside the loop is a
`slot_load`, NOT a konst — the identity guard covers exactly that shape, so
real-world coverage does not silently narrow to literals.)

**2a — the interned-identity guard (`guard_sid`, find/match only).** lune
interns every string: equal bytes ⇔ same `*String` within a heap. Pinning an
observed pattern is therefore a pointer compare of the ref's runtime value
against the record-time pointer. Encoding: `a` = ref, `aux` = **konst-pool
id** of the expected string — never a raw pointer in the IR (serialization
stays pointer-free; `Trace.consts` stores Values, tier-1a resolves via
`t.consts`, the native emitter resolves the konst to its pointer at compile
time — all verified in review round 2, incl. rooting: trace consts are
explicit GC roots, `interp.zig:1933`; tropt preserves the whole const pool,
`tropt.zig:317`). Lifetime (review M06): traces never survive a keyframe
restore (fresh VM/`TraceState`) and never cross VMs — the same argument as
the baked `*Heap`. Two round-2 obligations (review M01): the guard requires
a **dominating string proof** on `a` (`guard_string` or a proven producer;
`proveKinds` rejects anything else — a bare payload compare is not a type
proof), and its konst id joins `guardKeyAux` (`tropt.zig:256`) so guards
expecting different strings are never deduplicated. `sgmatch` does NOT use
this op — its pattern lives in the state table where no SSA ref exists
(round-2 B02); the identity check folds into its shim (§6).

**P2 — the recorder computes the outcome it is about to guard.** The mirror
runs before tier-0 executes the call (`interp.zig:2171-2192`, verified) and
the arm sees the observed subject/init values and the pinned pattern. It
runs the same pure core tier-0 is about to run (`locateMatch`, §3) and
learns whether this call matches. It must: the instructions recorded after
the call are the path tier-0 actually takes, so the guard's direction has to
agree or the trace body is wrong-path code. v1 records the **matched**
direction only; an observed no-match aborts `.bad_type` (fail-closed; the
no-match-direction shape is a mechanical v2 flag). Argument shapes the
tier-0 wrapper would reject (non-string subject, non-int init) abort at the
existing `stringArgRef`/`intArgRef` seams — the census never runs on
arguments tier-0 would raise on.

**P3 — one core, three callers.** Each builtin's semantics live in one pure
core: tier-0 wrapper = arg parsing + core; record-time census/outcome = same
core; native shim = same core. `findCore`/`matchCore`/`gmatchAuxCore` get
their pure locate step extracted (`locateMatch(s_bytes, pat, init_byte)
Error!?Located` — anchored-scan loop + `MatchState`, no `*Vm`, no `Value`,
no interning; the matcher allocates nothing — fixed capture array, verified).

## 3. The scratch-and-project decomposition

A match produces up to `2 + ncap` values but an `IrInstr` defines one
register. Decomposition (the LuaJIT IRCALL+FLOAD shape, adapted):

- The **match op** runs the locate step and writes results into a fixed
  **match scratch** hanging off `gc.Heap` (per-VM; plain memory, not a heap
  object; invisible to GC roots, serialization, and snapshots — asserted,
  review m03). Layout is a pure function of op + census: `slot0 = start`
  (char index, int), `slot1 = end` (char index, int), `slot2 = whole-match
  span`, `slot3.. = captures` (int for position captures, byte-span
  otherwise; §6 adds `next_pos` for the iterator). The op's IR result is
  `.int`: the status channel — `>= 0` matched, negative → side-exit.
  **Review M03**: the shim catches every matcher error (`MalformedPattern`,
  `InvalidCapture`, `TooManyCaptures`, `PatternTooComplex` —
  `pattern.zig:44`) and encodes it as a distinct negative status; no Zig
  error may cross the C ABI. Both no-match and matcher-error side-exit;
  tier-0 replays the iteration and raises or branches exactly as the program
  dictates.
- **Projection ops** then read scratch slots, one register each:
  - `scap_int(m, slot)` — non-allocating; native lowering is a direct load
    from a baked absolute address (scratch at a fixed offset in the
    VM-lifetime-stable `*Heap`, the `guard_gc` counter-load discipline). No
    exit path. **Requires the heap context** (review M05) — it joins the
    heap-null native bail list with everything else scratch-touching.
  - `scap_str(m, slot)` — `.alloc`: shim `(heap, slot)` interns the span →
    `*GcHeader` or null (OOM → side-exit, the snew protocol). One link max →
    counts exactly 1 in bound A. `isProvenStringRef` member.
- **Allocation-stream fidelity (review B02 — the v1 design was wrong).**
  Tier-0 materializes **every** capture before the native ABI truncates the
  caller's result window (`writeCaptures` at `string.zig:1115/1160/1231`,
  truncation at `interp.zig:3642`). The arm therefore emits one `scap_str`
  per string capture **in capture order, regardless of `c`** — unrequested
  ones simply have no register consumer but remain live `.alloc` roots
  (doc 24's dead-allocation rule: the id stream is the observable). Only
  non-allocating unused projections (`scap_int`) may be omitted.
- **Soundness of the hidden buffer**: projections carry a data dependence on
  the match op (`a` = the match ref) and are emitted by the arm with **no
  intervening scratch writer** (review m02 — `emitAlloc` may lazily insert
  `guard_gc` between the match op and the first `scap_str`; `guard_gc`
  cannot write scratch, so the proof obligation is "no interposed writer",
  not literal adjacency). Neither the match ops nor the projections are
  CSE'd/hoisted/reordered (kinds below), so no second writer can interpose.
  A side-exit mid-sequence (OOM null) replays the whole iteration in tier-0,
  which never reads scratch — stale scratch is unobservable. Projections
  never execute without their writer earlier in the same trace entry: they
  are body ops of the same trace, dominated by the match op, and traces
  always enter at the anchor (no mid-body entry). Doc 24's observation
  blackout already covers any trace containing `scap_str` (alloc_bound > 0);
  scratch itself needs no blackout state (review verified).

**tropt kinds (review M01 — no `.pure3` abuse; operand-shape-accurate):**

- `.scratch3` — `smatch` (three SSA ref operands `a`,`b`,`aux`) —
  side-effecting producer; excluded from DCE, CSE, LICM/hoist, fold; ordered
  like `.alloc`. Operand walks (liveness, compaction, preheader) cover all
  three (the `.pure3` walk shape). `sgmatch` is the same policy with an
  honest **different operand shape** (round-2 B02): `a` = state ref (SSA),
  `aux` = expected-pattern konst id (**immediate**, never walked as a ref) —
  its own kind row (`.scratch1k`), not a lie about three refs.
- `.proj` — `scap_int`: `a` = SSA ref (the match op), `b` = slot
  **immediate** (never remapped/walked as a ref). DCE admitted, CSE/LICM
  excluded fail-closed.
- `.alloc_proj` — `scap_str` (round-2 M02: "proj plus alloc obligations" is
  not a kind — `kindOf` returns ONE kind and the liveness root condition
  keys on it, `tropt.zig:420`): a dedicated kind that is BOTH an alloc root
  (dead results retained — the id stream) AND `.proj`-shaped for operand
  walks (`a` ref, `b` immediate). Every root/canonicalization/LICM/
  compaction walk gets an explicit arm, each pinned by a test.
- `str2num_*` — unary pure producer (`a` only), may side-exit. DCE admitted
  with a named stance: removing an unused parse removes only its
  kind-honesty exit, which is sound (tier-0 semantics don't depend on it;
  fewer exits, same results). CSE/LICM excluded fail-closed.
- `sgm_setpos` — the deferred position store (§6): `a` = state ref, `b` =
  new-pos ref. Joins the **existing deferred-store discipline** (docs
  07/08): sunk below every guard of the iteration, just before `.loop`,
  exactly like ordinary recorded stores (`trace.zig:11500`). Never DCE'd,
  never reordered.

**Exit provenance (review M02, the doc 26 M7 pattern):** every new op's
side-exit is an **ordinary unchainable header-replay side-exit** — none of
them join `guardExitPc` (`trace.zig:586`) or `isSideExitGuardOp`
(`trace.zig:597`); `aux` is an operand/slot, never a PC; they are never
hotguard or side-trace predicates. Pinned by the same accessor tests as scp.

## 4. The op inventory (wire ordinals 72–78, append-only)

| op | operands (`a`,`b`,`aux`) | ty | kind | notes |
|---|---|---|---|---|
| `sfindp` 72 | s, init, pat | .int | pure3 | plain find: `indexOfPos` core → start char index, negative → exit. No scratch. End result is arithmetic: `end = start + cpLen(pat) − 1`, konst-folded `add` (census knows `cpLen(pat)`) |
| `smatch` 73 | s, init, pat | .int | .scratch3 | pattern locate + scratch fill (find/match flavor) |
| `sgmatch` 74 | state, —, aux=pat konst id (imm) | .int | .scratch1k | the composite iterator op (§6) |
| `scap_int` 75 | m, slot imm | .int | .proj | direct load, no call, no exit; heap-context required |
| `scap_str` 76 | m, slot imm | .heap | .alloc_proj | intern span, null → exit |
| `str2num_i` 77 | s | .int | unary | `arith.toNumber` string path; exit unless int |
| `str2num_f` 78 | s | .float | unary | ditto, float direction |
| `sgm_setpos` 79 | state, new_pos | none | deferred store | pos commit, sunk below all guards (§6) |

`str2num_*` ABI: shim returns `extern struct { status: i64, value: u64 }`
(SysV: rax + rdx, verified); emitter compares `status` against the baked
expected kind (nil and kind-flip both mismatch) → side-exit, else homes
`value` per the op's ty. Both directions call the ONE `arith.toNumber` core
(doc 29 B), so tier-0, the konst fold, and the trace can never disagree.
`recBTonumber` gains the observed-string arm (today: `abort(.bad_type)`,
`trace.zig:13937`); konst-string keeps folding.

Heap-null native bail list (review M05): `smatch`, `sgmatch`, `scap_int`,
`scap_str` (scratch and/or interning live behind `*Heap`). `sfindp` and
`str2num_*` are heap-free (pure byte readers; sfindp's result is an index).

## 5. Recorder arms (the builtin surface)

New `RecordedBuiltin` rows: `find = 20`, `match = 21`, `gmatch_iter = 22`;
`tonumber = 3` extended. `string.gmatch` (the triple constructor — table
alloc + global lookup, once per generic-for, outside the hot loop), `gsub`
(v1; its dispatch share is 3-5% — doc 29 owns its cost; string/table-repl
recording is a natural v2 on this machinery), and `string.format` (needs a
buffer-op chain, own doc; ~40% decimal-bound anyway) stay barriers.

Common arm shape: `guardBuiltinCallee`; subject via `stringArgRef`; init via
`intArgRef` or konst default; pattern pinned per P1 (konst or
`guard_sid`); census; observed outcome per P2 (no-match → abort). Then:

- **`recBSFind`** (`b ∈ {2,3,4}`, fixed `c ∈ {1..2+ncap}`): `plain`-arg, if
  present, must be konst. Plain/no-specials → `sfindp` + konst-folded end
  `add`; else `smatch` + `scap_int(0)`, `scap_int(1)` + **every** string
  capture as `scap_str` in order (B02), position captures as `scap_int` only
  if register-wanted. Define `c` result regs; `c` beyond produced → konst
  nil (M04).
- **`recBSMatch`** (`b ∈ {2,3}`, fixed `c ∈ {1..max(1,ncap)}`): `ncap == 0`
  → `smatch` + `scap_str(2)` (whole match); else `smatch` + all-captures
  projection per B02, nil-padding per M04.
- **`recBSGmatchIter`**: §6.
- **`recBTonumber`** observed-string arm: run `arith.toNumber` on the
  observed value; int → `str2num_i`, float → `str2num_f`, nil → abort
  `.bad_type` (v1).

`c == all_results` producer forms: find/match/gmatch_iter join doc 27's D1
**excluded** list in v1 (the shadow would need the census count —
mechanical v2); the three rows take explicit stances in the whitelist
switch. Fixed-`c` consumers are unaffected (the bench shapes:
`local s, e = find(...)` is `c == 2`; the for-in iterator call has fixed
`c` = loop-variable count, `compiler.zig:943/978`).

## 6. gmatch: the composite iterator op (review B01 redesign)

v1's plan — decompose the aux into recorded state-table gets/stores — was
unimplementable: `.value`-lane loads of strings/scalars and `.value`-lane
array stores abort recording today (`trace.zig:12403/12623`), and building
general heterogeneous-lane recording is its own arc. Instead the iterator
records as **one composite op**, `sgmatch(state, —, pat)`, whose shim owns
the whole aux semantics (P3: the shim and `gmatchAuxCore` share the core):

1. `state` is the aux's table argument (type-guarded table ref — a loop
   input through the ordinary slot_load/guard path). At record time the arm
   reads `state[1]`(subject)/`state[2]`(pattern)/`state[3]`(pos) via
   rec_heap and runs the census on the observed pattern. The pattern pin
   does NOT use `guard_sid` — there is no SSA ref for `state[2]` (round-2
   B02; the value-lane load is exactly what we're not recording). Instead
   the expected pattern's **konst-pool id rides in `sgmatch.aux`** and the
   **shim itself** compares `state[2]`'s payload against the resolved
   pointer before matching; mismatch → negative status → side-exit. The
   subject needs no pin: the shim reads it at run time, and the census only
   fixed the *projection list*, which is a function of the pattern alone
   (verified: capture count/kinds are syntactic properties of the pattern).
   A runtime non-string subject or pattern → negative status (tier-0
   replays and raises its own `TypeError`).
2. **The shim is read-only on the state** (round-2 B01 — the v2 shim-owned
   pos write was a replay-idempotence bug: a later `scap_str` OOM exit
   would replay the iteration against an already-advanced pos and lose a
   token). It: verifies the pattern identity and that `state[3]` is an
   **existing in-lane array int cell** (round-2 B03 — a user-built state
   table with a hash-resident or missing `[3]` would make the later store
   allocate through insertion/migration; that shape gets a negative status
   and stays tier-0); reads subject/pos; runs the gmatch-flavor locate
   (continue-from-pos, empty-match bump — the exact `gmatchAuxCore` rule,
   `e == src ? e + max(seqLen(e),1) : e`); fills scratch (match spans +
   `next_pos` as an int slot); returns status. No heap mutation, no
   allocation. No-match → negative status → side-exit (the for-in loop end,
   one exit per gmatch() call; tier-0 replays, produces nil, ends the loop).
3. The arm then projects the token (`scap_str`/`scap_int` per census, B02
   all-captures rule), nil-pads extra loop variables (M04: `for a, b in
   gmatch(...)` has `c == 2` with one produced value — `b` gets konst nil),
   projects `next_pos` via `scap_int`, and registers **`sgm_setpos`(state,
   next_pos)** through the existing deferred-store discipline (docs 07/08):
   the store sinks below every guard of the iteration, just before `.loop`
   — exactly where ordinary recorded stores go (`trace.zig:11500`). Any
   exit in the iteration (OOM in a projection, a later guard, the next
   call's status) therefore replays in tier-0 against the UN-advanced pos
   and reproduces the same token — replay-idempotent by the same argument
   as every other sunk store. `sgm_setpos`'s lowering writes the int
   payload into the array cell the shim just verified (no allocation
   possible by the B03 check).

Fail-closed corner: a SECOND `sgmatch` against the same state ref within
one iteration (two manual `f(s, c)` calls per loop body) would read a stale
pos under the deferred store — the arm aborts `.bad_type` when a pending
`sgm_setpos` already exists for that state ref in this iteration. The
for-in shape (one aux call per iteration) is unaffected.

**Why the deferred mutation is otherwise invisible**: no *recorded* load
can observe state across the iteration — `.value`-lane loads abort
recording today, so a program that also indexes the state table inside the
loop simply doesn't trace. **Named coupling**: if value-lane load recording
ever lands, `sgm_setpos` must join its load/store-forwarding barrier
discipline — a stated obligation on that future arc, mirrored in a code
comment on the op.

The state table is compiler-generated for `for ... in gmatch(...)` but the
recording does not rely on non-escape — every assumption is either shim-
verified per execution (pattern identity, slot-3 layout, subject/pos types)
or guarded (the table type guard); a poked `state[2]` fails the identity
check → side-exit → tier-0 truth.

## 7. What does NOT change

- No effect-log/exec-log schema change (producers + ordinary side-exits).
- No `*Vm` channel: shims take `*Heap` (+ scratch inside it) or nothing.
  None of these builtins touch effect state; no `requires_*` bits.
- `guard_gc` bound A: each `scap_str` counts 1; match ops count 0 (scratch
  is not heap). Static per trace by P1+B02.
- Barriers kept: `gsub` (v1), `string.format`, `string.gmatch` constructor,
  unpinnable patterns, observed-no-match shapes, `c == all_results`
  producer forms, vararg `char`, 3-arg `rep`, `codes`/`encode`/`decode`,
  value-lane table access (unchanged, and §6 documents the coupling).
- Tier-0 semantics: byte-identical (wrappers refactor to cores; doc 29
  pins).

## 8. The append-only sweep (closed inventory, review m03 additions marked ●)

Per the doc 26 D6 checklist: `IrOp` rows 72–78 + `assertWellFormed` (three-
ref pins for `.scratch3`; slot-imm bounds for `.proj`) + `writeIrInstr`
(ternary rendering; slot-imm rendering); `traceser` ordinal pins/count;
`viz/src/enums.ts` names + `TERNARY_AUX_OPS` for the `.scratch3` ops;
`tropt.zig` `kindOf` + the two new kinds (`.scratch3`, `.proj`) and the
unary-parse stance through every switch, each exclusion pinned by a test;
`troptdiag` walks; `irinterp.zig` arms (executor ctx carries heap; scratch
reachable through it); `nativegen.zig` proveKinds (bounds → kinds →
exhaustive result-ty), isTransient, operandReads (+ `analyzeInner`
aux-liveness for `.scratch3`), opMayExitInBody, BodyCallout rows +
calloutMayCollect(false) + bodyCalloutOf, the heap-null bail list per §4,
emitters (match callouts + status check; `scap_int` direct load; `str2num`
two-reg status/value); `function.zig` RecordedBuiltin 20–22 + registry tags;
doc 27 producer-whitelist stances; **grep-audit every else-armed IrOp
switch**. ● `guard_sid`: new guard op — full guard-surface sweep
(`guardExitPc`/`isSideExitGuardOp` stances: exit-PC no, hotguard no —
pinned), `guardKeyAux` inclusion (round-2 M01), dominating-string-proof
requirement in proveKinds, serializer, viz, tier-1a, native. ●
`sgm_setpos`: integration with the deferred-store sinking machinery (docs
07/08) — sink position, flush ordering vs other pending stores, the
one-pending-per-state-ref recorder pin. ● `.alloc_proj` kind: explicit arms
in every root/liveness/canonicalization/LICM/compaction walk (round-2 M02),
each pinned. ● `gc.Heap` scratch: layout, init, non-root/non-serialized
asserts. ● Matcher-error→status ABI table (one row per `pattern.Error` +
pattern-mismatch + layout-fail + type-fail statuses). ● Nil-padding in all
three arms. ● `isProvenStringRef` += `scap_str`. ● Exit-provenance accessor
tests for all new ops. ● Recorder arms assert only projection/nil refs
enter `reg_map` (round-2 m01 — the status ref is never guest-visible).

## 9. Tests (adversarial set)

- Per-op parity: record leg (`expectRecordedProgram`, entries > 0), tier-1a
  oracle, native regs/exit parity, VM e2e vs tier-0 truth — ASCII +
  multibyte subjects (S-D char indices at the seams), captures incl.
  position captures and `ncap == 0`.
- **Allocation-stream fidelity (B02)**: `find(s, "(a)(b)")` with `c == 1` —
  the trace still interns BOTH captures in capture order; `next_obj_id` /
  live-object equality vs tier-0 at a post-call exit AND at loop end (the
  id-stream lemma with dead-register allocations).
- Deopt matrix: runtime no-match after matched-recording (side-exit →
  tier-0 replay parity incl. id stream); OOM-null on the 2nd of two
  `scap_str`s; **the round-2 m02 regression**: successful `sgmatch`, then a
  forced failure in the first/later `scap_str` — tier-0 after the exit must
  return the SAME token, never the next one (the deferred `sgm_setpos`
  never ran); matcher-error status (a pattern that census-passes but errors
  at run time — e.g. `PatternTooComplex` via deep backtrack — side-exits
  and tier-0 raises the same error); str2num kind-flip and runtime nil;
  gmatch loop end (status exit) then a second for-in over a fresh gmatch
  (fresh state table, guards re-established).
- Fail-closed matrix: unpinnable pattern (non-string, or a value the
  identity guard can't pin); observed no-match at record time;
  `c == all_results` producer; poked `state[2]` (shim identity check →
  exit, correct results via tier-0); poked `state[3]` to a non-int or a
  hand-built state with hash-resident `[3]` (round-2 B03 → status exit);
  non-string subject; a manual double `f(s, c)` call in one loop body
  (pending-`sgm_setpos` pin → abort, parity holds); two `guard_sid`s
  expecting different strings not deduplicated (M01 `guardKeyAux` pin).
- Nil-padding (M04): `for a, b in gmatch(csv, "[^,]+")` — `b` nil each
  iteration, parity across modes; `local s, e, c1 = find(...)` on a
  0-capture pattern → `c1` nil.
- Identity-guard shapes (m01): pattern in a local cached OUTSIDE the loop
  (slot_load + guard_sid records); pattern rebound between loop runs →
  guard fails, re-record with new census.
- Structural: bound A == census count; `.scratch3`/`.proj` exclusion pins
  (not hoisted/CSE'd; `scap_str` never DCE'd, `scap_int` DCE'd when
  unused); two matches in one loop body (no interposed-writer violation,
  projections interleave correctly); effect-modes legs (record/replay) on a
  natively-running pattern loop; exit-provenance accessors return null for
  all new ops.
- Bench-shape e2e: each of the three bench loops (find_match's 4-call body,
  gmatch's for-in, `tonumber(match(...))` through doc 27's shadow) records
  with **zero aborts** and `native_entries > 0`, output byte-identical
  across all modes.

## 10. Gates and expected outcome

`just test` both legs; hashgate 84/84; `just bench` 28/28 cross=ok ×2;
whole-board A/B vs `just shadow` baseline (nm-verified); `--dump-aborts` on
the four string benches recorded before/after in this doc.

Predictions against the 2026-08-28 board (post-doc-29 baselines TBD):
find_match loses its ~25% dispatch slice + per-call wrapper overhead —
target **≤ 20 ms from 32.4** (≤ ~24 if doc 29 lands first and took its
share); gmatch loses ~30% — target **≤ 45 ms from 61.2**; gsub/format ≈
flat (their levers are doc 29 / the decimal arc). Combined with doc 29,
find_match's arithmetic lands within reach of ≤1.2× (LJ 13.4); gmatch's
residue after both arcs decides whether the v2 arms (gsub repl recording,
no-match direction, format buffer chain) are the next general gap.

## Codex review ledger (2026-08-28, v1 → v2)

Verdict on v1: BLOCKED. **B01** (blocker): v1's gmatch decomposition
claimed "existing recorded get/store shapes" for the state table — false:
`.value`-lane loads of strings/scalars abort `.nyi_opcode`
(`trace.zig:12403`) and `.value`-lane array stores abort unconditionally
(`trace.zig:12623`) → §6 redesigned as the composite `sgmatch` op with the
shim owning state access, plus a named coupling obligation on any future
value-lane recording arc. **B02** (blocker): v1 projected only
register-wanted results, but tier-0 materializes every capture before ABI
truncation (`string.zig:1115/1160/1231`, `interp.zig:3642`) — omitting
unrequested `scap_str`s changes `next_obj_id` (doc 24:140's dead-allocation
rule) → all-captures-in-order rule in §3/§5, pinned by a dedicated test.
**M01**: `.pure3` reuse for wrong operand shapes would mark/remap bogus refs
(`tropt.zig:468/658`) → new `.scratch3` + `.proj` kinds, unary stance for
`str2num`. **M02**: exit provenance unspecified → all exits declared
ordinary unchainable header-replay side-exits, `guardExitPc`/
`isSideExitGuardOp` stances pinned. **M03**: matcher runtime errors
(`pattern.zig:44`) must be caught in the shim and encoded as negative
status — no Zig error across the C ABI. **M04**: fixed result windows
nil-pad (`interp.zig:3653`, `compiler.zig:943/978`) → arms nil-pad; multi-
`setReg` verified sound (`trace.zig:12165`, `11516`). **M05**: `scap_int`
is not heap-free (scratch lives in `*Heap`) → heap-null bail list corrected.
**M06**: "re-resolution at entry" misattributed to `seedTraceInputs`
(`interp.zig:959` — upvalues/globals/hash-cells only) → replaced by
`guard_sid` with the trace-lifetime pointer argument stated explicitly.
Minors: **m01** cached-local patterns are slot_loads, not konsts → P1
widened via `guard_sid`. **m02** `guard_gc` may interpose → proof restated
as "no intervening scratch writer". **m03** sweep rows added (● items).
Verified by review: P2 mirror timing, matcher non-allocation, SysV two-reg
struct return, multi-def soundness, no metamethod/coercion hazards in the
wrappers, no blackout state needed for scratch.

**Round 2 (on the v2 redesign)** — verdict: still blocked; three fresh
blockers in the composite op, all fixed in this v3. **B01**: the v2 shim
wrote `next_pos` before the trailing projections — a later `scap_str` OOM
exit replays the iteration against the advanced pos and LOSES a token
(exits preserve heap mutations, `nativegen.zig:6349`; this is exactly why
ordinary recorded stores sink below every guard, `trace.zig:11500`) → the
shim is now read-only; the pos update is `sgm_setpos`, a deferred store on
the docs-07/08 sinking discipline; plus the one-pending-per-state-ref
recorder pin for double-call shapes. **B02**: `guard_sid` had no SSA ref to
guard for `state[2]` (the value-lane load is precisely what isn't recorded)
→ the identity check folds into the `sgmatch` shim via an `aux` konst id;
`guard_sid` remains for find/match where the pattern IS an SSA ref;
`sgmatch` gets an honest operand-shape kind (`.scratch1k`), not a
three-ref lie. **B03**: the slot-3 no-alloc claim held only for the
constructor's table — a user-built state with hash-resident/missing `[3]`
allocates through `Table.set` (`table.zig:288/319`) → the shim verifies an
existing in-lane array int cell before matching, else status-exit.
**M01**: `guard_sid` needs a dominating string proof (payload compare is
not a type proof; the `guard_string` prologue precedent,
`nativegen.zig:1585/1616`) and its konst id must join `guardKeyAux`
(`tropt.zig:256`) or differing expectations get deduplicated. **M02**:
"`.proj`+`.alloc`" is not a kind — `kindOf` returns one kind and liveness
roots key on `.alloc` (`tropt.zig:420`) → dedicated `.alloc_proj` kind with
explicit arms. **m01**: arms must assert only projection/nil refs enter
`reg_map` (status never guest-visible). **m02**: the decisive regression
test — post-`sgmatch` projection OOM must yield the SAME token on replay.
Round-2 verified: konst-pool guard encoding + rooting (trace consts are GC
roots, `interp.zig:1933`; const pool never compacted, `tropt.zig:317`;
fresh heap/TraceState on restore), census is pattern-only, subject
replacement mid-loop is sound (both tiers read current state), dead-alloc
native homing works once classification is fixed (`nativegen.zig:3189/3520`),
the exact gmatch progress rule (`string.zig:1221`).

## 11. Landed results (2026-08-29)

Landed as c4 (`d32103b`: recorder arms + `recTForLoop`), c4b (`b008140`:
carried-string slot classification — gmatch's for-in goes native
end-to-end, 2995 bytes, `completed=7..20`/entry), the §8 audit fixes
(`c28202a`), and c5 (test matrix + two general fixes, this commit).

**Abort profile, before → after** (`--dump-aborts`, ReleaseFast,
baseline `1755f0c`):

| bench | before | after |
|---|---|---|
| str_find_match | `host_barrier` ×6 | **no recording aborts** |
| str_gmatch | ctor `host_barrier` ×6 + body `host_barrier` ×6 | ctor ×6 (by design, §7) + `bad_type` ×1 (nil-ctrl first iteration — abort-don't-commit, §6) |
| str_gsub | `host_barrier` ×6 | unchanged (kept, §7) |
| str_format | `host_barrier` ×6 | unchanged (kept, §7) |

**Board** (interleaved A/B vs nm-verified `1755f0c` shadow binary):

- **str_find_match 32.4 → 20.1 ms jit — the ≤20 target is met** (1.5×
  vs LJ 13.2). The last ~10 ms (30.4 → 20.2) came not from a doc-30 op
  but from a general recorder gap the bench exposed: `recBranch` emitted
  `guard_true` on a konst/proven-string operand (`if match(s,"^key")`
  anchored tests), and that guard's ref bailed `proveKinds`. The fold —
  statically-decided branches emit no guard (only nil/false are falsy; a
  string ref is never either; a konst matching the observed truthiness is
  a tautology) — helps every tier and loses no region identity (an
  undivergeable branch has no other CFG edge).
- **str_gmatch 57 ms, flat vs the ≤45 target — and the evidence says
  coverage was never the residue.** LuaJIT runs this bench in ~25 ms
  **with `-joff`**: gmatch iteration is NYI in LuaJIT's recorder too, so
  its number is pure interpreter + matcher + intern constant factors.
  Our native gmatch loop executes ≈ at tier-0 speed because the
  per-token callout (matcher + `scap_str` intern) dominates the loop
  body in both tiers. Per §10's contingency the residue routes to the
  constant-factor levers (doc 28 §5 L3 intern hash, doc 29), not to more
  recording breadth. No heuristic tuning was done to force more native
  iterations (Z-6): the region window gates instances at `work=7 <
  min_useful=8` (each instance yields 8 tokens, iteration 1 lost to the
  nil-ctrl prologue), and that observation is recorded in TODO.md as a
  gate-design question, not patched around.
- gsub/format flat, as predicted (§10 — their levers are other arcs).
- Whole-board A/B: every other row ≤ noise except **lua54 t0 +11%**,
  proven layout-only by `perf stat`: instructions +0.3%, cycles +11%,
  L1-icache misses 7× (356K vs 51K) — the ~230 KB of new
  recorder/nativegen code shifted tier-0 dispatch alignment. Recorded in
  TODO.md as a binary-layout sensitivity, not chased here.

**General mechanisms this arc added beyond the §4–§6 inventory** (each
earned by a bench but general per Z-6):

- `recTForLoop` (trace.zig): generic-for back-edge recording, continue
  direction — v1 pinned by observed-type guard (the pin doubles as the
  loop-done check), nil → `.bad_type` abort (§6's abort-don't-commit),
  plus the **old-ctrl pin**: the loop-entry `move` materializes an
  unguarded `slot_load` of the previous control value which would bail
  `proveKinds`; nil ctrl aborts, string/number/table ctrl guards by
  observed type, bool/exotic records unpinned (tier-1a still beats
  never-tracing).
- **Carried-string slot classification** (nativegen.zig): `lk==.heap ∧
  sk==.heap` slots admit native homing iff the load is pinned by
  `guard_string` (entry: prologue keeps TAG_HEAP + `header.type ==
  string`) and the writeback is an `isStringProducerOp` (a deliberate
  fail-closed subset of `proveKinds`' string producers). Home = GP reg
  or spill of `*GcHeader`, TAG_HEAP flush.
- **Statically-decided branch fold** (trace.zig `recBranch`): see above.
- **`tfor_loop` entry patching**: `patchedEntryOp` admits `.tfor_loop →
  .jloop`; the interp's `.jloop` orig-arm replays the canonical
  tfor_loop semantics before entering the trace.
- **`loopDoneSnapshotSupported`** (irinterp.zig, §8 audit): the
  loop-done fast-flush and nativegen's linked-branch emission both
  pre-scan the post-guard sunk-store range; a deferred `sgm_setpos`
  makes the loop-done snapshot unsound (it must not run on the done
  path) → decline to ordinary deopt replay, sound by §6's
  replay-idempotence.

**Verdict.** find_match target met; gmatch residue reclassified from
"coverage" to "constant factors" with the `-joff` evidence — which makes
the doc 28 §5 L3 sparse intern hash decision (open with Bart) the next
lever on that bench, alongside doc 29's remaining matcher items.
