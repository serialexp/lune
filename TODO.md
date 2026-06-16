# TODO

Deferred items noted in passing (Rule #10) so they don't get lost.

## stdlib `math` — deferred functions

First `math` cut landed in `src/stdlib/math.zig` (the stdlib now lives in
per-library modules under `src/stdlib/`, concatenated into `interp.base_natives`
via each module's `natives`/`constants` slice — not piled into `interp.zig`).
Implemented: `abs ceil floor sqrt exp log sin cos tan asin acos atan deg rad
fmod modf max min tointeger ult` + constants `pi huge maxinteger mininteger`.
`math.modf` landed on the new native multi-return ABI
(`function.NativeMultiFn` + multret-in-last-position for `local`/assignment).
Still deferred, each blocked on a capability lune doesn't have yet:

> **Update:** *dynamic* multret (the `all_results = 0xFFFF` sentinel) has since
> landed too — `print(f())`, `print(0, f())`, `return f()`, method-call last-arg
> expansion, and `print(table.unpack(t))` all expand fully now (VM `reg_top` +
> safepoint-atomic `reg_top_pending`; compiler emits `all_results` in the call-arg
> and `return` last positions). So `math.frexp` (item 2) really is just "implement
> it" now.

1. **`math.type`** — returns a *string* (`"integer"`/`"float"`/`nil`). Needs heap
   interning, i.e. a `*Vm`/heap in the native. Either thread heap access to the
   pure modules or special-case it like the effect natives. (Forces the only
   `math.*` dependency on `interp`, hence held back.)
2. **`math.frexp`** — returns *two* values (mantissa, exponent). The multi-return
   ABI is ready now (see `math.modf`); just needs implementing alongside the other
   C99 float helpers.
3. **`math.random` / `math.randomseed`** — the seeded host effect. The flat
   `random` global already draws from the VM PRNG (`.random_seed` effect); these
   are the namespaced front + explicit reseed. Land when the base-host effects get
   namespaced (see the `os.clock`/`math.random` flat-global note).

## stdlib `table` — deferred functions

First `table` cut landed in `src/stdlib/table.zig`: `insert remove concat move
pack unpack` (all tier `core`, `implemented` in the inventory). Unlike `math`,
these natives take a `*Vm` (heap/alloc), so the module imports `interp` for the
`Vm` type — the mutual import is fine (`Vm` is used only in fn bodies). `unpack`
is a multi native and rides the dynamic-multret path above.

Still deferred:

1. **`table.sort`** — a Lua comparator needs the VM to **re-enter** and call a
   closure from inside a native; there's no `callValue`/`callClosure` entry point
   today, and `arith.lt` is numeric-only (no string ordering). Both are their own
   cuts. Row stays `not-started`.

## Native codegen (tier-1b) — follow-ups

Phase 8 cut 1 landed (x64 encoder + prove-typed int/bool compiler + tier wiring +
`--jit-native`/`--dump-native` + docs/bench). **Cut 2 landed** (register-homed
loop-carried slots + loop-invariant hoisting + single-snapshot deopt +
register-resident transients). **Cut 3 landed** (two-operand in-place arithmetic):
the `acc=acc+i` loop is now ~46× over tier-1a and **~1.10× off LuaJIT** (cut 2 was
~1.8×). Named follow-ups, in rough value order (see
docs/design/05-native-codegen.md §Out of scope):

1. ~~**Relax `guard_int` onto proven-`Int` *derived* values**~~ — **DONE.** Pass A
   no longer bails on a non-`slot_load` guard operand (only `slot_load` guards mark
   the prologue tag-check); Pass B validates a derived `guard_int` against its
   already-computed kind (`Int`-op-of-`Int`s is closed over `Int`) and it lowers to
   nothing. Landed "CSE-able body" (5.40 ms, 33×) and "multi-var" (5.86 ms, 35×) on
   the native path — both were tier-1a fallbacks. Reviewed clean by Codex +
   Antigravity. **Finding:** the multi-op shapes sit ~2.5× off LuaJIT (vs ~1.10× on
   single-accumulator `acc=acc+i`) — the simple loop was overfit-favorable; longer
   operand chains / 2 accumulators expose real codegen headroom (spill/staging on
   chains; win-2 still inert because the loop-exit guard is recorded last).
1b. ~~**Drop dead-temporary writebacks from the exit snapshot ("A")**~~ — **DONE.**
   The recorder now drops compiler expression temporaries (numeric-`for` slots
   `>= base+4`, gated on the `for_loop` whose back-edge *is* the trace anchor) from
   `exit_stores` at `commit()`: they're dead at the loop header (tier-0 recomputes
   on deopt) and after the loop, so the per-iteration writeback was pure waste.
   Closed the multi-op gap — cse `5.40→1.70 ms`, mv `5.86→1.90 ms` (~3× each); both
   now below LuaJIT on these micro-loops. Codex found + helped fix a real
   anchor-attribution bug (a trace passing *through* a non-anchor `for_loop`);
   Antigravity review didn't land (timed out). Follow-ups: (a) **loop-invariant
   konst hoist** — the leftover per-iteration `movabs rNN,konst` for `i+7`, a
   nativegen regalloc/hoisting job independent of the snapshot; (b) **while /
   generic-`for` watermark** — needs a compiler-emitted watermark, no bench
   coverage yet.
2. **Float / mixed / heap traces** — xmm registers, tag dispatch, libm `call`-outs.
3. **Deferred ops** — `div`/`idiv`/`mod`/`pow` (floored-div/mod correction),
   `shl`/`shr` (Lua masked shift counts), logical `not`.
4. ~~**Linear-scan register allocation**~~ — **DONE (cut 2).** Loop-carried &
   invariant slots get register/spill homes loaded once; transients get registers
   via forward linear scan; `regs[]` written only on side-exit (single snapshot).
4b. ~~**Two-operand in-place arithmetic**~~ — **DONE (cut 3).** Win 1 (read ALU
   operands straight from their register/spill home + reuse a dying operand's
   register for the result) replaced cut-2's rax/rcx staging and took `acc=acc+i`
   to ~1.10× off LuaJIT. Win 2 (in-place home update + elided back-edge shuffle) is
   implemented behind a single-snapshot safety predicate but **inert on the counted
   loop** (its loop-exit guard is recorded last → predicate cond 1 declines).
   Commits 188251a/1e6a59b/b96ad70/ece721d.
4c. **Sink accumulator updates below the loop-exit guard** — the win-2 enabler on
   counted loops. The recorder emits the back-edge `guard_true` last, so win-2's
   "no side-exit after an in-place home update" condition never holds on
   `acc=acc+i`. A schedule pass that sinks pure ops feeding carried `exit_store`s
   past the last guard unlocks it (sound under cut-2's re-run-from-loop-header
   deopt: a sunk op isn't computed on guard-fail, tier-0 recomputes). Marginal
   (~10% over win-1) but the principled single-`add` form. New transformation →
   fresh plan + Codex/Antigravity review first.
5. **Per-exit identity / side traces** — cut 1 has a single shared exit epilogue.
6. **Proto-id stale-cache hardening** — `AnchorKey` borrows a raw `*const Proto`
   and the cache is never invalidated; a freed-then-reallocated `Proto` at the same
   address could hit a stale trace (now stale *machine code*). Pre-existing in
   tier-1a; surfaced to Bart as a separate task, not expanded into Phase 8.
7. **A wasm codegen backend** — a separate consumer of the same lowering seam.

## Benchmark north-star: run a real LuaJIT bench (`~/Projects/LuaJIT/bench/`)

Goal (Bart): pick a real LuaJIT benchmark to *work toward* end-to-end on lune, even
if unrunnable today — it defines the feature roadmap. None of the bench/ programs
run verbatim: they all need `tonumber`, `io.write`, `string.format`, `unpack`,
generic-`for`/`pairs`, `repeat/until`, `math.*` — none of which lune has yet (lune's
natives today: `print`, `clock`, `random`, `getenv`, `argc`, `argv`; no string/
table/math/io modules; generic-for & repeat/until parsed-but-not-compiled).

**Recommended target: `nsieve.lua`** — integer + boolean + tables, numeric-`for` hot
loops; closest to lune's int/bool tier-1b strength and drives the natural next
expansion (heap/table ops in native codegen). Incremental roadmap:
  1. ~~derived `guard_int`~~ — DONE (#1 above; unlocks pure-int derived loops).
  2. ~~**Minimal host stdlib** for the harness~~ — **DONE.** `tonumber`,
     `string.format` (fuller printf: `d i u o x X c f F e E g G s q %`, flags
     `- + space 0 #`, width, precision), `io.write`, and the `arg` global table.
     nsieve runs end-to-end on tier-0/1a and prints **byte-identical to LuaJIT**
     (verified N∈{1,4,6,9}, Debug + ReleaseFast). Module fns (`string.format`,
     `io.write`) live in `base_natives` with `module`/`field` qualifiers so keyframe
     restore resolves them by name; `arg` is populated at the host boundary
     (main.zig) to keep the VM exec core deterministic. A latent keyframe-serializer
     fragility (std.HashMap insertion-order slot layout) was surfaced by the larger
     globals table and fixed with canonical (sorted) hash-part serialization —
     reviewed clean by Codex. **This is the correctness milestone; hot loops still
     interpret.**
  2b. ~~**Table array-part rehash** (Lua `computesizes`)~~ — **DONE.** Profiling found
     nsieve's keys lived entirely in the **hash part** (it sets `t[2..m]`, never
     `t[1]`, and lune only grew the array on a contiguous `len+1` append) — the cause
     of *both* the ~6× memory and the fact that a tier-1b array fast path could never
     fire. `Table.set` now runs Lua's histogram-driven rehash (`src/table.zig`:
     `rehash`/`computeArraySize`/`countKey`, density gate `na <= nh*3`), migrating
     dense integer runs into the array part. **Result (N=11): memory 1.6 GB → 320 MB
     (~1.2× LuaJIT), time 32 s → 4.7 s** (~7× LuaJIT, was ~46×) — array indexing beats
     hash probing even on the interpreter. Output still byte-identical (N∈{1,4,6,9,11}).
     Codex review found + fixed a double-count-on-update and an O(n²) sparse-insert
     path; Antigravity timed out (one clean review). Keyframe round-trip stays
     byte-identical (rehash never runs on restore). Residual ~1.2× memory vs LuaJIT is
     Value width (16 B vs 8 B) — a separate packing step.
  3. **tier-1b heap/table support** — array load/store in native codegen so the hot
     inner loops (`p[k]=false`) actually JIT. **Now unblocked** by 2b (keys are in the
     array part). Needs recorder IR ops (`tget`/`tset` + `guard_table`/
     `guard_array_bounds`), irinterp execution, x64 SIB indexed addressing, nativegen
     lowering. **← next north-star item.**
  4. head-to-head vs `~/Projects/LuaJIT/src/luajit`.
Alt target `mandelbrot.lua` instead drives **float/xmm** tier-1b (follow-up #2) — the
second north-star once floats land. (Pick not locked; revisit with Bart.)

## ~~Recorder: intern duplicate konsts at record time~~ — DONE

**Resolved.** The recorder now interns constants: `TraceState.konst` keys a
`AutoHashMap(KonstKey → Ref)` on the value's tag + payload bits and reuses an
existing `konst` instruction's ref (and pool slot) for a recurring literal
(`src/trace.zig`). Slot reads were already cached by `refOf`, so with konsts
deduped, identical subexpressions get identical operand refs and the optimizer's
CSE collapses them. Verified end-to-end: for `acc + (i + 7) * (i + 7)`, the two
`i + 7` adds merge to a single ref and the multiply becomes `mul %4 %4` (see the
`--dump-traces` opt-vs-no-opt contrast and the tests in `src/interp.zig`:
"recorder: a recurring literal is interned…" and "konst interning lets CSE
collapse a repeated subexpression end-to-end").

### Optional follow-on (not needed for the common case)
General hash-consing of *arbitrary* pure subexpressions at record time (beyond
konsts + the existing slot-read cache) would let CSE merge structurally-identical
expressions that don't share operand refs by construction. Low priority — konst
interning + slot caching already cover the common recurring-subexpression
patterns. Revisit only if a real trace shows un-merged duplicates.

## ~~Generated TS codec: wrong discriminator field for *nested* unions~~ — FIXED upstream

**Resolved (binschema `aa0a270`).** The vendored TS decoder mis-decoded a
discriminated union sitting in a NAMED struct field (vs an array element): it
emitted `x.key.tag = readUint8()` for the tag read but branched on `x.tag`
(undefined), so every branch missed and it threw
`Unknown discriminator value: undefined`. This broke `EffectDecoder` (effect
logs) and `SnapshotFileDecoder` (any keyframe with a table — `TableEntry.key`/
`.val`, plus `HeapUpvalue.value`). Array-element unions (`Keyframe.stack`,
`HeapTable.array`) and the standalone `SnapValueDecoder`/`TraceFileDecoder` were
unaffected, which is why traces decoded but snapshots/effects didn't.

Root cause was in the generator (`~/Projects/binschema`
`packages/binschema/src/generators/typescript.ts`): the discriminator-branch
condition was resolved against the enclosing scope instead of the inlined
struct's local path. Reported in `binschema/BUG-nested-union-named-field-ts.md`
with a minimal repro; fixed in `aa0a270` (TS + Go). Both codecs were regenerated
here via `tools/regen-trace-schema.sh` (binschema `aa0a270`); the Zig codec was
already correct so only `viz/src/gen/generated.ts` changed. `viz/src/snapshot.ts`
uses the generated `SnapshotFileDecoder` directly — no hand-rolled byte reader.

Now-unblocked follow-ons (separate from the v8 replay work): a *structural*
divergence view in `diff.ts` (decode both sides, show the first differing field)
and a keyframe/effect inspector panel.


## tier-1b: "CSE-able body" / "multi-var" bench programs fall back to tier-1a
Confirmed via instrumentation: both bail in **`proveKinds`** (the stage cut-2 did
not touch — NOT a regression). Root cause is exactly follow-up #1 above: the
recorder emits a `guard_int` on a *derived* value (`i+7`), and Pass A only proves a
`guard_int` whose operand is a `slot_load`. Fixing #1 (relax `guard_int` onto
already-proven-`Int` derived values → no-op) lifts this fallback. Tracked under #1;
no separate work item.
