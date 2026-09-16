# CURRENT_TASK — Campaign: every benchmark ≤1.2× LuaJIT (Bart 2026-08-20 mandate)

Loop: profile → worst *general* gap (Z-6) → design → codex (gpt-5.6-sol) review →
Claude implements → gate battery + board → commit → next arc. No per-arc reports
to Bart; this file + the design docs are the record.

Campaign map (from --dump-aborts across the board, 2026-08-20): (1) builtin
recording breadth — ffrecord beyond math.sqrt (scalar 37.6×, partialsums 6.9×,
str_format 18.5× host_barrier call) — **CORRECTED 2026-08-27 (LATEST-84): the
dominant cause of scalar's and str_format's gap was NOT ffrecord but the string
interner (82–89% of runtime); fixed, scalar 4.0×/str_format 3.2×. ffrecord
remains the lever for what's left of them (both now tier-0-bound on dispatch +
builtin calls) and for partialsums** — **arc A landed 2026-08-27 (LATEST-85):
partialsums 2.0×; scalar/str_* remainder is arc B (allocating builtins)**; (2) **[REFRAMED, see LATEST-72]**
Pall-shape nest coverage — NOT "root-recording linkage" (the `.root` LINNER
abort is Pall-faithful, lj_record.c 605–700); the real gaps are backend:
heap φ writeback + seeded-trace seams + inner-root owner election (nbody
38.5×; sparse/euler14/matmul outers abort earlier — recheck after);
(3) return tracing / up-recursion + call-site
hotness (recursive-fib 20.8×, binary-trees 5.5×, cross_frame ret everywhere);
(4) heap-valued (function/table) hash field loads + generic-for (array3d 90×,
method calls). Undiagnosed yet: spectral-norm 28.9×, repack 11.0×.

## HANDOFF → codex (2026-09-16)

Bart is out of Claude budget; you (codex / gpt-5.6-sol) are picking up the
campaign as the implementer. You already know this codebase as the design
reviewer — doc 49 was your review (thread `01a0a86c-f747-7db3-95c5-d4b1e3b7c664`).

**State of the tree**
- HEAD = `76198e5` (doc 49 arc: owned hash part + hrefk, nbody 23.3×→13.4×).
  Full `just test` green; board TSV `bench/results/20260916-141459-858834f.tsv`.
- **master is ahead of origin — do NOT push without Bart's say-so.**
- Older status sections moved to `CURRENT_TASK_ARCHIVE.md`; canonical design
  record is `docs/design/` (start: `00-architecture.md`, then 47/48/49).
- Untracked TSVs from parallel agents may exist under `bench/results/` —
  leave them alone.

**Next-arc candidates** (from the post-doc-49 nbody profile, latest+15 below;
Bart picks, or default to the most *general* gap per Rule Z-6):
1. **Nested `for_prep` tracing** (`nyi_opcode for_prep`): outer loops never
   trace anywhere — nbody advance:4 (13.6% of run), and the same abort gates
   every nested-loop bench. Biggest general rock; tier-0 no-trace is 32.3%
   of nbody cycles and `liveSlotOf` 31.9% of its profile is those tier-0
   probes.
2. **`aliased_input get_upval`** (nbody main:211, 18.5% of run).
3. **replayLedger seam** (~1028 cyc/walk, 16% of nbody run). READ Rule Z-8's
   diagnosis ladder in `CLAUDE.md` + doc 17/47 BEFORE touching this — exit
   patching already exists; do not rebuild it.
4. **Task #18 / doc 44 return tracing** (recursive-fib 27.2×, btrees 9.8×) —
   an in-progress arc with its own doc.
5. Doc 49 defers: guard_hash subsumption on hrefk chains, on-trace insertion
   (asm_newref analogue), scalar-key hrefk.

**Discipline digest** (full text in `CLAUDE.md` / project rules — these are
the ones that bite):
- Profile FIRST (`perf` recipe + tier rollup in CLAUDE.md); `--jit-stats`
  before declaring any bench flat; never conclude a regression from one run —
  ×3 interleaved re-runs (this arc: 3 apparent regressions, all noise).
- Benchmark ONLY via `just bench` (rebuilds ReleaseFast); `just shadow` for
  A/B baselines; a plain `zig build`/`just test` leaves a Debug binary.
- Z-6: never optimise for a single benchmark — fix the general gap.
- Z-1: verify Zig stdlib against the pinned toolchain source; your training
  data about `std` is wrong.
- Debug probes via `src/jitdbg.zig` (`-Djit-debug` + `--jit-debug`), never
  ad-hoc prints.
- New arcs get a design doc (`docs/design/`, status header + Done/Outstanding
  checklist) and land behind full `just test` + board + noise-checked diff;
  update the doc's checklist and this file in the same change.
- Test gotcha (cost me an hour this arc): raw test-created heap objects have
  `GcHeader.id = 0`, and heap `Value.eql`/`hash_part.keyHash` compare BY ID —
  multi-key tests must assign distinct ids (see `assignIdWithSlot` in
  `src/nativegen_hrefk_test.zig`).
- LuaJIT source is at `~/Projects/LuaJIT/src/` — read how Pall did a thing
  before declaring it hard; "replay/determinism forbids it" only ever means
  *adapt* the mechanism (ids not addresses, deterministic counters).

## Status 2026-09-16 (latest+17) — doc 50 Astra-review follow-ups landed; next arc = nest-decomposition diagnosis

Codex Astra (gpt-6-astra) reviewed the doc 50 arc read-only. Verdicts and what
landed from them (this session, on top of `d35ca63`):

- **`guard_gcol` fail-open gap FIXED** (pre-existing, Rule #0.5): native
  range-checks `guard_gcol.b` while the oracle derives the column from
  `gcell.b`; the prover never tied them, and the shared `.aref` kind let
  aref/garow/gcell impersonate each other while native emitters walk exact-op
  `t.instrs[...]` chains (`guard_bounds` on a gcell even satisfied
  `bounds_ok`, so a gcell-of-gcell chain COMPILED). Prover now enforces
  `guard_gcol.b == gcell.b` + exact op identity along the whole grid chain.
  Three previously-compiling malformed variants pinned in
  nativegen_arrayread_test.zig ("Astra/doc50" tests) — bite verified by
  temporary neutering (they compiled pre-fix), positive control compiles.
- **Heap identity eq coverage extended**: `eq` op (only `ne` was covered),
  mixed invariant-`.ptr`/value-lane-`.heap` operands, top-bit ids
  (sign-extension trap), equal-twin + differing cases. Leftovers in TODO.md:
  spill-pressure variant, real capture/restore differential.
- **Doc 50 amended per review**: rejection scoped to whole-inner-loop cloning
  of variable-trip nests (bounded unrolling of genuinely short loops stays
  legitimate); "no production multi-loop trace" softened to a working
  assumption; "External review" section records verdicts + follow-ups.
- **Next arc (Astra-recommended, recorded in doc 50 "Outstanding
  direction")**: NOT a new mechanism — diagnose why the EXISTING
  `inner root → outer continuation → inner root` decomposition fails to
  cover outer work on a reduced advance:4-shaped variable-trip nest, layer
  by layer (the Z-8 ladder generalized): 1 topology/aborts, 2 entry-guard
  mismatches, 3 exit arming, 4 silent-region promotion / SCC owner
  election, 5 residency + seam cost. End state: inner trace REUSED, outer
  state through continuation φ/writeback, code size independent of inner
  trip count.

## Status 2026-09-16 (latest+16) — task #33 (doc 50): nested `for_prep` investigation — unrolling rejected

**NO FEATURE LANDING.** Doc 50 (`docs/design/50-nested-for-prep-investigation.md`)
records the experiment and measurements. Starting HEAD for this run was
`33d4ced`; do not push without Bart's say-so.

- Profile + `--jit-stats` confirmed the documented nbody gap: `advance:4`
  contributes about 13.5–13.9% of the run with zero traced iterations;
  `advance:34` remains about 87.5% trace-resident. The outer abort is
  `nyi_opcode for_prep`.
- A general bounded numeric-inner-loop recorder prototype (15-trip cap) built
  an approximately 500-IR native outer trace. Variable/shrinking trip counts
  made it match only about one third of nbody outer iterations at ~2,417
  cycles/iteration versus ~485 in tier 0, regressing wall time to ~108 ms.
  Mismatch retirement merely restored the old shape with no durable new
  coverage. A fixed-four-trip control was already covered by the existing
  inner-root/link machinery. Per Z-6, the prototype was removed in full.
- Two independent correctness bugs exposed by the experiment remain fixed:
  `guard_gcol.b` is now marked/remapped through tropt's two-operand effect
  class; and native heap `eq`/`ne` now admits both invariant `.ptr` and
  value-lane `.heap` operands while comparing stable `GcHeader.id`, never
  process address. Differential tests cover distinct IDs, the same object,
  and restored twins with equal IDs at different addresses.
- An owner-aware numeric loop-done classifier was prototyped but removed: its
  only demonstrated need was the rejected multi-loop root, while landing it
  would require a deliberate revision of the replay fixture contract. Doc 50
  records this requirement for any future multi-loop-root design.
- Gates: focused regressions green; full `just test` green; full
  `zig build test -Djit-debug=true` green. Post-removal nbody 50,000 is correct,
  71.8 ms in the sampled stats run, with `advance:4` back to zero trace
  iterations and 50.8% traced time. Full five-repetition `just bench` is
  cross-tier clean and LuaJIT-parity clean on every compatible row; nbody is
  62.4 ms versus 61.7 ms on the post-doc-49 board (noise-scale).
- Next choice returns to the candidate list above. Bounded whole-inner-loop
  cloning is ruled out; a future nested-loop design must preserve the reusable
  inner trace and represent the enclosing state transition instead.

## Status 2026-09-16 (latest+15) — task #32 (doc 49): owned hash part + hrefk — nbody 23.3× → 13.4× LJ

**COMPLETE — committed as `76198e5` on master (not pushed).** Doc 49
(`docs/design/49-owned-hash-part-hrefk.md`, codex-approved rounds 1–3, thread
`01a0a86c-f747-7db3-95c5-d4b1e3b7c664`) holds the full design + measurements.
Bart chose "Own hash part (B)" over the std-map layout-discovery hack. Summary:

- **P1 `src/hash_part.zig`**: mahina-owned extern-layout open-addressing map
  (interleaved 32 B `Node{key,value}`, `{nodes, mask, live, used}` header).
  Lua-style deletion: free ⇔ nil KEY tag; dead ⇔ live key + nil VALUE, dead
  heap-key payload rewritten to `GcHeader.id` bits (pointer-free dead nodes).
  `keyHash` = splitmix64 over (tag, id-or-bits). 8 inline tests.
- **P1b battery**: owned map BEATS std map at tier-0 (nbody −4.7%, array3d
  −5.8%, churn −6.3%, field-hash −6.8%; miss micro +2.2% = predicted
  no-fingerprint cost). binary-trees "+13.9%" disproven as noise ×3.
- **P2 swap**: `table.Map = hash_part.HashPart`, call sites migrated,
  `hash_size` → `live`. Table 112→120 B, same 128 B SmpAllocator class.
- **P2b restore contract**: geometry (slot/mask/dead nodes/used) deliberately
  NOT serialized; divergence across restore PERMISSIBLE (doc 02 Done-bullet
  added). Pinned by `doc 49 P2b` test in keyframeser_restore_test.zig:
  used>live history restores dead-node-free, `encodeSnapshot ∘ restore ==
  identity`, second restore layout-identical slot-for-slot.
- **P3 hrefk**: recorder pins live `(slot, mask)` via `Table.hashSlotOf` into
  `href.aux` (`trace_ir.HrefAux`, 3-domain contract: aux≥0 seed slab / −1
  callout / ≤−2 hrefk); `emitHrefK` (~7 instr, 4 loads, NO callout/save
  frame) with CONTRACTUAL guard order mask → live-cell → key tag → key id
  (ids, never payload bits — restore moves strings). Prover admits hrefk only
  at `.heap` roots; static-root-with-hrefk-aux fails closed.
  Tests `src/nativegen_hrefk_test.zig` (7): same-shape distinct-table read
  vs oracle; guard_table agreement; two-universe RMW store; swapped-slot
  sibling (native exits at pinned iteration K with hand-computed regs, oracle
  completes N — the documented conservative divergence); delete+unrelated-
  insert dead-node STORE TRAP (live-cell guard exits before key deref —
  neutering it segfaults on the id-bits deref, proving the guard order);
  rehash + empty-map mask exits; static-root bail. All guards
  neuter-verified to bite. GOTCHA for future tests: raw-created heap objects
  default `GcHeader.id = 0` and heap `Value.eql`/`keyHash` go BY ID — a test
  with >1 heap key must assign distinct ids itself (see `assignIdWithSlot`).
- **P4 board** (TSV 20260916-141459-858834f, cross+luajit ok everywhere):
  **nbody 106.4 → 61.7 ms, 23.3× → 13.4×**; repack −14.1%, btrees −7.4%,
  grid_matmul_f64 −7.4%, nsieve −6.5%; tier-0 broadly down. str_gsub/
  str_manip/array3d apparent jit regressions disproven ×3 interleaved.
  Full `just test` green on the final tree.
- **Next rocks (out of scope, recorded in doc 49)**: nbody remaining gap is
  tier-0 COVERAGE, not the traced loop — `--jit-stats` 50000: advance:4
  nested for_prep (13.6% run, `nyi_opcode for_prep`), main:211
  `aliased_input get_upval` (18.5%), tier-0 no-trace 32.3% of cycles;
  liveSlotOf 31.9% of profile is those tier-0 probes. Seam:
  replayLedgerFrom 7.5%, ~1028 cyc/walk. Defers: guard_hash subsumption on
  hrefk chains, on-trace insertion (asm_newref analogue), scalar-key hrefk.
