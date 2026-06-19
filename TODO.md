# TODO

Deferred items noted in passing (Rule #10) so they don't get lost.

## Metatables chunk 2b — arithmetic/compare/concat/len/call/tostring metamethods

Chunk 2a (the OO core) landed (June 2026): `Table.metatable` field + GC mark +
keyframe persistence (`HeapTable.metatable_id`, `Keyframe.string_metatable_id`,
snapshot v3); `setmetatable`/`getmetatable` (with `__metatable` protection);
`__index`/`__newindex` (table + function forms, bounded chain via
`Vm.indexGet`/`indexSet` + `MetatableChainLoop`); the shared string metatable so
`("x"):upper()` resolves through `string`; and the recorder aborts
(`AbortReason.has_metatable`) at `recArrayGet`/`recArraySet` so metatable-bearing
tables run tier-0. The dispatch keystone is `Vm.metatableOf` + `Vm.metamethod`
(interp.zig) over the cached `Vm.mm` name strings.

**Chunk 2b (deferred):** the remaining metamethods, each wrapping the tier-0 op's
`TypeError`/non-callable path and reusing `Vm.metamethod`:
- `__add __sub __mul __div __mod __pow __idiv` (arith), `__unm` (neg),
  `__band __bor __bxor __shl __shr __bnot` (bitwise) — fire when an operand is a
  metatable-bearing table; symmetric operand lookup (left then right).
- `__eq` (only when both are tables and raw-unequal), `__lt`, `__le` (compare).
- `__concat` (the `..` non-string/number path), `__len` (the `#` non-table/string
  path), `__call` (calling a non-function with a `__call` table), `__tostring`
  (`tostring`/`print` of a metatable-bearing value).

**Perf follow-up (separate):** a `guard_no_metatable` IR op so the recorder can
keep tracing metatable-*free* tables across a polymorphic site instead of the
current whole-trace abort. Not needed for correctness — only to recover JIT
coverage on code that mixes plain and metatable'd tables.

## `zig build wasm` is broken (wasm32 `usize` overflow in trace.zig hotIndex) — PRE-EXISTING

Discovered during the metatables M0 work (June 2026), unrelated to it. `zig
build wasm` fails to compile:

```
src/trace.zig:504: error: type 'usize' cannot represent integer value '11400714819323198485'
    h ^= @as(usize, pc) *% 0x9E3779B97F4A7C15;
```

On wasm32 `usize` is **32-bit**, so the 64-bit golden-ratio constant in
`hotIndex` overflows at compile time (and `@intFromPtr(proto)` is 32-bit too).
The line is unchanged at HEAD — this is a latent breakage from an earlier
trace/hotcount change, not the metatable work. Consequence: the committed
`zig-out/bin/lune.wasm` is **stale**, so `viz/test/diff.test.ts`'s cross-engine
byte-identity check cannot be rebuilt/rerun and its pass/fail reflects an old
artifact (on top of the separate known `arg`-table divergence below). **Fix:**
make `hotIndex` width-correct on wasm32 — hash in `u64` explicitly
(`@as(u64, pc) *% 0x9E3779B97F4A7C15`, fold to `usize` at the end) and use a
stable proto id instead of `@intFromPtr` for the wasm path. The native
`zig build test` gate is unaffected and green.

## tier-0 interpreter perf — next lever (after T1+T3)

Two interpreter wins landed: T1 (inline table array fast-path in
`get_index`/`set_index`) and T3 (hook-elision fast/slow `execImpl(comptime mode)`
split). nsieve tier-0 0.81s → 0.65s (~20%), `--trace --jit-native` 0.33 → 0.28.

**Threaded dispatch (labeled-switch-continue) was profiled OUT, not done.** nsieve
tier-0 has branch-misses at **0.03%** and IPC **4.32** — the interpreter is
instruction-count bound, not misprediction bound, so threading the dispatch switch
buys ~nothing here. Don't revisit it expecting a win unless a *different*
benchmark shows real indirect-branch misprediction (check `perf stat -e
branch-misses` first — the documented "polished the 3%" trap).

The real remaining lever is **fewer instructions retired per opcode**, since we're
near peak IPC. Biggest structural candidate: the `Value` is 16 bytes, so every
`regs[x]` is a 16-byte load and arith goes through tag dispatch — **NaN-boxing to
8 bytes** would roughly halve register traffic. That's a large, determinism-
sensitive change (touches every Value site + the snapshot/replay schema), so it
needs its own design doc + Codex/Antigravity review. Smaller nibbles: the
per-instruction back-edge epilogue check, and tightening the hottest arith arms.

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
generic-`for`/`pairs`, `repeat/until`, `math.*`. lune now has most of these
(`math.*`, `table.*` incl. `unpack`, `tonumber`/`string.format`/`io.write`,
generic-`for` + `pairs`/`ipairs`/`next`, `repeat/until`, and bare varargs `...` —
see below). Remaining vararg work: named `...rest` (`#rest`/`rest[i]`), keyframe
persistence, and `{...}`/`{f()}` table-spread.

### ~~Generic-`for` + `pairs`/`ipairs`/`next` (deterministic iteration)~~ — DONE
`for v1..vn in explist` now compiles (`compiler.compileGenericFor` → one new
`tfor_loop` opcode; the per-iteration iterator call is a real bytecode `.call`, so
closures and natives both work with no VM re-entrancy). The basic-library iterators
live in `src/stdlib/base.zig`: `next`/`pairs`/`ipairs` plus a hidden `@ipairs_iter`
(un-spellable name, GC-root + keyframe-restorable by name). `next` walks the array
part ascending then the hash part in **canonical key order** (tag → heap id → bits),
lifted into `src/key_order.zig` and shared with the keyframe serializer — so a
mid-iteration snapshot resumes the exact same traversal (F2c corpus covers it).
First cut sorts the hash keys **on each `next` call** (correct, trivially
snapshot-safe). **Follow-up:** a per-table lazily-built sorted-key cache for `next`,
invalidated at the four hash key-set mutation sites — pure perf, behind the same
D1-D9 tests.

### ~~`repeat ... until cond` (post-test loop)~~ — DONE
`repeat`/`until` are now lexer keywords, an `ast.repeat` node, a parser
`parseRepeat`, and `compiler.compileRepeat` (no new opcode — reuses
`jmp_if_false` as a backward branch, the post-test mirror of `while`). The Lua
subtlety that `until`'s condition sees locals declared in the body is handled by
reserving the condition register *below* the body scope so it survives `endScope`'s
register pop, letting `endScope` close per-iteration upvalue cells normally before
the back-edge. Covered by compiler unit tests, an all-modes e2e, and a mid-loop
keyframe resume in the F2c corpus.

### ~~Bare varargs `...` (zero-copy stack cursor)~~ — V1+V2 DONE
A vararg function's surplus arguments already sit in a stable, GC-rooted region of
the shared `stack` (the `.call` ABI copies only `num_params` and *drops* the rest,
but never reallocates the slab), so varargs are a **zero-copy cursor**
`(varargs_base, varargs_count)` on `CallFrame` — no heap object, no new `Value`
kind, no allocation. Four opcodes read the current frame's cursor: `vararg_first`
(single-value position), `vararg_len` (`#`), `vararg_get` (1-based, bounds-checked
index), and `vararg_spread` (the dynamic-`reg_top` multret producer, bounded vs
`stack.len`). The compiler lowers bare `...`: first-value in single position,
per-slot `vararg_get` with constant indices for a destructure (`local a,b = ...`,
nil-padded), and `vararg_spread` + a consuming `call`/`ret` in every expanding
position — forward `f(...)`, `g(x, ...)`, `obj:m(...)`, `return ...`, and a nested
`f(g(...))` (the trailing-arg expansion was unified into `compileArgList` /
`compileMethodArgs` so an inner call's own trailing `...` also spreads). `(...)`
truncates to one value via the existing `.paren` node. `...` outside a vararg
function is a clean compile error. Trace recorder aborts (`nyi_opcode`) on the four
opcodes, so vararg functions never form a trace. Covered by V1 VM unit tests,
compiler diagnostics, three all-modes e2e programs, and a determinism-corpus entry.
**Remaining:** V3 named `...rest` (`#rest`/`rest[i]` + capture diagnostic), V4
keyframe persistence (frame schema + version bump + suspend-in-vararg F2c), and the
`{...}`/`{f()}` table-spread follow-up (also fixes the latent `{f()}` bug).

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


## viz `diff.test.ts` "wasm ≡ native" fails — `arg` global heap divergence (host setup)

The cross-engine byte-identity test (`viz/test/diff.test.ts`) fails on every
integer/float case. Root-caused (not E0): the **native** host (`main.zig`)
populates an `arg` global table from process args, while the **wasm** host
(`wasm_entry.zig`) injects a null env/args source (argc=0, argv=nil). So the
native keyframe carries one extra heap object (the `arg` table, +44 bytes) the
wasm keyframe lacks — even for a no-trace program like `print(1)`. Trace bytes
are byte-identical across engines; only the keyframe heap differs. This is the
env/args stdlib feature (tasks #98–102/#132–137), not the trace/phi work.
**Fix (concurrent stdlib task's call):** either have the wasm host also build an
empty `arg` table, or teach the diff test to tolerate the host-injected `arg`
global. Flagged here per Rule #10; left for that task's owner.

## tier-1b: "CSE-able body" / "multi-var" bench programs fall back to tier-1a
Confirmed via instrumentation: both bail in **`proveKinds`** (the stage cut-2 did
not touch — NOT a regression). Root cause is exactly follow-up #1 above: the
recorder emits a `guard_int` on a *derived* value (`i+7`), and Pass A only proves a
`guard_int` whose operand is a `slot_load`. Fixing #1 (relax `guard_int` onto
already-proven-`Int` derived values → no-op) lifts this fallback. Tracked under #1;
no separate work item.

## Native int store: constant-value stores stay tier-1a (pre-existing, shared)
A constant int store into a narrow lane (`t[i]=7`, both in-bounds `astore` and
grow `astore_append`) does NOT lower to native: the trace optimizer folds the
provably-in-range `guard_fits`, so `proveKinds` finds no `fits_ok` proof for the
value and rejects the trace. Dynamic values (`t[i]=i`) are unaffected and compile.
Fix (separate, benefits both store paths): in `nativegen.proveKinds`, treat an
int-lane store value as fits-proven when it is a `konst` whose constant fits the
guard_lane-pinned lane width (sound: guard_lane pins the lane, so an in-range
constant always fits). Noted while landing Phase B (int astore_append).

## Phase B int astore_append: WIDEN-FLICKER — FIXED (widen-eviction)
The headline idiom `for i=1,N do t[i]=i end` crosses i8->i16->i32; each monotonic
widen permanently invalidates the current-lane trace, but the stale trace lingered
in a per-anchor slot and the wider-lane steady state never got a stable trace
(~88% tier-0). Fixed by widen-eviction: when a trace side-exits with completed==0
and the live array's lane has monotonically widened past the trace's `guard_lane`
lane (`!live.canWidenTo(trace_lane)`, array.zig), the trace is permanently dead, so
we retire it (`removeTrace`) and reset the anchor's hot-counter so the stabilised
wider lane re-records. The dispatch walk was also made visit-once
(`nextTraceExcluding`) — the old `findNextTrace(skip)` cursor could cycle A->B->A
forever once two stale-lane traces coexisted (latent bug the eviction exposed).
Result: a fresh-table fill crossing i8->i16 runs 0.06s native vs 0.22s tier-0
(~3.7x). Output byte-identical across all 8 modes (eviction never affects output —
tier-0 stays the oracle).

### Known limitation (gate-bounded, output-safe): polymorphic-anchor thrash
A genuinely bi-hot anchor — same loop PC alternately filling an i8 table and an i32
table — can record+evict the narrow-lane trace repeatedly (eviction only fires when
the live lane is WIDER, so the i32 trace is never evicted by an i8 table, but the
re-recorded i8 trace is evicted whenever the i32 table flows). This is deterministic
and output-safe; the existing penalty->gateAnchor cooldown bounds the repeated
low-yield re-entries. Monomorphic fills (the target) are unaffected. If it ever
shows up in a profile, gate re-recording on a per-anchor widen-eviction count.

## Phase B int astore_append: loop-INVARIANT int value (t[i]=v) is "unsupported"
`local v=1000; for i=1,N do t[i]=v end` records but proveKinds rejects the trace (the
invariant value isn't proven .int / fits-covered after loop-invariant handling). Smaller
follow-up; affects another common fill idiom. Characterise + fix alongside the flicker.

## stdlib pattern pass — follow-ups (string.find/match/gmatch/gsub landed)
- **gsub function replacement** — DONE (chunk-1 foundations). `Vm.callValue`
  (the call-into-VM-from-native primitive) landed; `addReplFunction` drives the
  replacement per match. CSV row is `implemented`. Same primitive unblocked
  `table.sort`'s comparator.
- **Misleading native-error messages** — DONE (error-message cheap-wins batch).
  `describeFault`'s `.call` arm now only emits "attempt to call a <type> value"
  for a genuine non-callable; a native-internal fault renders `"bad argument to
  '<name>'"` (located), and converted `*Arg` checkers raise the full detailed
  `Vm.badArg` message. See the "Native-raised fault messages …— DONE" section
  below.

## Native-raised fault messages are misattributed to the call site — DONE

Fixed in the error-message cheap-wins batch. The keystone was the shared
`Vm.callSiteAt(level)` locator (interp.zig): when a native faults inline in a
`.call`, its caller frame still holds that `.call`, so the native's name and the
source location are recoverable from the live call site without threading.
- `describeFault`'s `.call` arm now distinguishes a native-internal fault (→
  `"bad argument to '<name>'"`, located) from a genuine non-callable (keeps
  `"attempt to call a <type> value"`).
- `Vm.badArg(n, expected, got)` / `Vm.badArgReason(n, reason)` raise the full
  Lua-style `"<chunk:line>: bad argument #<n> to '<fn>' (…)"`; the shared
  `*Arg` checkers in string/table/basic/base route through them. `math.zig`
  stays a pure module (no `interp` import) and uses the generic located arm.
- `synthErrorValue` now prefixes `chunk:line:` on caught bare runtime faults too
  (matching Lua's caught-error value format). Deterministic across all 8 modes
  (proto name is static, line derives from a source offset).
Remaining (metatables chunk): `__tostring` on error objects; richer context.

### Known limitation: indirectly-called natives misattribute the arg-error name

When a native is invoked *indirectly* through another native — e.g.
`pcall(string.sub, nil, 1)` or `pcall(math.floor, "x")` — the bad-argument
message names the **outer** native (`pcall`), not the faulting one (`sub`):

```
pcall(string.sub, nil, 1)  → bad argument #1 to 'pcall' (string expected, got nil)   (Lua: 'sub')
```

Root cause is structural and the mirror image of the fix above: `Vm.callValue`'s
native path runs the target native inline **without pushing a frame and without a
`.call` instruction**, so `callSiteAt(1)`/`nativeSite` find the live call site of
the *outer* native instead. The **direct** call form
(`(function() return string.sub(nil,1) end)`) is correct — only the
native-invokes-native indirection is wrong, and it's an uncommon pattern.

Proper fix (deferred — needs a new mechanism, not a hack): have `callValue`'s
native path set a "currently-invoked native" context (name + the caller's
call-site) that `nativeSite` consults *before* falling back to the live `.call`
frame, then clears on return. Confirmed by both reviewers (Codex, Antigravity)
during the cheap-wins review.

## error(msg, level) location prefix — DONE

`nError` (stdlib/errors.zig) honors `level`: a string message gets a
`chunk:line:` prefix from `Vm.raiseLocatedError(bytes, level)` (level 1 = the
function that called `error`, level 0 = no prefix), reusing the shared
`callSiteAt` locator. Non-string messages pass through verbatim. CSV `error`
row flipped to `implemented`.

## String ordering (`<` `<=` `>` `>=` on strings) — DONE

`arith.lt`/`arith.le` (`src/arith.zig`) now compare two strings lexicographically
by byte (`std.mem.order`), keeping mixed string/number a `TypeError` exactly as
Lua does. `table.sort` on a string list with the default comparator works. Safe
for the JIT: `recCompare` (trace.zig) aborts a compare whose operands aren't
numbers, so string ordering only ever runs on tier-0/1a, never inside native
trace code. Parity tests in interp.zig ("strings: …").
