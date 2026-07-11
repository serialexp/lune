# lune — project instructions

lune is a Lua-shaped (not Lua-compatible), dynamically-typed language with a
tracing JIT and a time-travel trace visualiser, written in Zig. Start with
`docs/design/00-architecture.md`; the companion docs (`01`–`04`) own the trace
lifecycle, determinism, GC/memory, and the snapshot/replay schema.

## Rules

### Rule Z-1: Verify the Zig stdlib before relying on it — do not trust memory.

We pin a `-dev` Zig toolchain (`.zig-version`). The stdlib is a moving target and
your training data about it is stale — function names, signatures, the whole
`std.Io` writer/reader model, build-system APIs, and `std.fmt` have all churned
and will keep churning. **Before you call or depend on any stdlib API, confirm
what it actually is in the pinned toolchain.** Read the source under
`$(dirname $(readlink -f $(which zig)))/../lib/std/` (or wherever `.zig-version`
resolves to) and check the real signature, fields, and behaviour. `zig init` is
the source of truth for current `build.zig`/`build.zig.zon` shape.

Concretely:
- Grep/read the actual `lib/std/**.zig` for the symbol; don't guess the name or
  arguments. (`std.Io.File.stdout()`, `File.Writer` via `@fieldParentPtr`, the
  `Io.Threaded` instance, `Writer.fixed`, etc. are all things memory gets wrong.)
- If a build fails with "no member named X" or a signature mismatch, the fix is
  to read the current source, not to try variations.
- Things already verified the hard way (see `00-architecture.md`): guaranteed
  tail calls are **LLVM-backend only** (`use_llvm = true`); `refAllDeclsRecursive`
  is gone; `**`/array-repeat wants symmetric whitespace; the stdout writer needs
  an `Io` instance and a stably-addressed `File.Writer`.

### Rule Z-2: Confine the churning frontier to wrappers.

Per architecture principle #4 we stay on Zig's bedrock (manual memory, comptime,
tail calls, inline asm, C ABI) and avoid the churn (async/`std.Io`, bleeding-edge
stdlib). Where we genuinely need a churny surface, confine it to one wrapper so a
toolchain bump is a one-file fix, not a sweep. Example: all `std.Io` writer use
and `Value` text rendering live in `src/io.zig`; the VM core and `Value` stay
free of it.

### Rule Z-3: Keep it green and tested.

Every phase lands behind `zig build test`. Pure logic (numeric semantics, the
value model, lexer/parser rules) gets its shape pinned with tests. Don't proclaim
success while anything is red (global Rule #3).

### Rule Z-4: Inject allocators; account at the boundary.

Allocation is the runtime's main enemy. Every subsystem takes an
`std.mem.Allocator` parameter — never reach for a global heap (the only
deliberate exception is the diagnostic stdout path in `src/io.zig`, which is not
VM data). Tests run on `std.testing.allocator`, which leak-checks; a `defer
…deinit()` for every owning structure is mandatory, not optional. For runtime /
embedding memory introspection, wrap the backing allocator once in
`mem.TrackingAllocator` (live/peak/total bytes, outstanding-allocation count,
`assertNoLeaks()`) and feed every subsystem from it. Prefer arenas for
parse-once/free-all lifetimes (the AST already does this).

### Rule Z-5: Keep the stdlib inventory in lockstep with the stdlib.

`docs/lua-stdlib-inventory.csv` is the canonical map of the Lua 5.4 standard
library we draw from: one row per function/constant, columns
`category,function,tier,status,description`. `tier` is the disposition
(`core` = pure deterministic language; `base-host` = host effects installed in
every VM; `cli-binding` = the OS world the default CLI ships and a game host
omits; `excluded` = won't implement, determinism-hostile or out of scope), and
`status` is implementation progress (`implemented`/`partial`/`not-started`, or
`n/a` for excluded rows). Whenever you add, finish, rename, namespace, or drop a
stdlib function, update its row in the **same change** — flip `status`, move the
`tier`, or add the row — so the inventory never drifts from the tree (global
Rule #3 spirit). It's the at-a-glance "what's left to replicate" for lune.

## Build

Use the `just` recipes (`justfile`) as the canonical entry points — they wrap
the `zig build` invocations and, for benchmarks, guarantee the right binary.

- `just build` — build the CLI. (`zig build`)
- `just test` — run all unit tests, the gate. Depends on `build`, so it also
  refreshes `zig-out/bin/lune` (Debug) — no more debugging a stale CLI after a
  test-only run. (`zig build && zig build test`)
- `just run -- <script> [args]` — run the CLI. (`zig build run`)
- `just release` — build the optimized CLI (`zig build -Doptimize=ReleaseFast`).
- `just bench [args]` — run the benchmark suite (`bench/run.py`); **always
  rebuilds ReleaseFast first**, so you never benchmark a stale Debug binary.
  Args pass through (`just bench --filter str`, `just bench --reps 7`). See
  `bench/README.md`. ALWAYS benchmark via this recipe, never a bare
  `python3 bench/run.py` against whatever happens to be in `zig-out/`.
- `just check-version` — hard-fail on toolchain drift (CI). NB: this rebuilds
  `zig-out/bin/lune` as **Debug**; re-run `just release`/`just bench` before
  timing anything afterward (a plain `zig build`, `zig build test`, or this
  recipe leaves a Debug binary that benchmarks ~20× slow).

## LuaJIT is dedication, not magic — and not a talent ceiling

When lune is N× slower than LuaJIT, that gap is **not** innate genius and it is
**not** a wall. Mike Pall isn't superhuman; he spent ~15 years relentlessly
optimizing one thing and hand-writing assembly. Any dedicated engineer could
build something like it given that commitment. Two consequences, and you must
hold both:

1. **"Is it possible" is always answered yes.** Never invoke "too hard," "out of
   scope," or "structural work we can't do" to wave away a benchmark gap. The
   technique is real, achievable, and — decisively — **we have the source**
   (`~/Projects/LuaJIT/src/`: `lj_record.c`, `lj_asm_*.h`, `lj_opt_*.c`,
   `lj_crecord.c`, …). Everything Pall did is sitting there to read. So if we
   *cannot* replicate a thing he did, that is a **shocking failure on our part**,
   not an acceptable "it's beyond us." Go read how he did it before concluding
   anything is out of reach.
2. **The gap is years of accumulated grinding — close it the same way.** One
   named technique at a time, measured and landed, never one heroic leap to
   parity. When you catch yourself treating a LuaJIT number as an unreachable
   ceiling, stop: name the specific technique, read how Pall did it, implement
   it, measure, repeat.

Anything we do **on top** of what Pall did is bonus, not the bar. Bart is
"cheating" by pointing the combined intelligence of three LLMs in parallel at
the same single-minded optimization problem Pall ground on solo — so matching
him is the floor we owe to the fact that we can read his source, and beating
him is the upside that parallelism buys. Replicate first; the gravy comes after.

**The one legitimate asterisk: determinism and full session replay.** lune
carries weight LuaJIT doesn't — byte-identical 8-mode equivalence and
time-travel replay. So the *only* defensible reason a Pall technique can't be
lifted verbatim is that doing so would break determinism or replay (smuggling a
clock, RNG, or raw address into a tiering decision; making a trace
non-reproducible). Even then this is a constraint on **how**, never a licence to
skip the win: find the determinism-preserving equivalent of his mechanism — as
we already did with the direct-mapped hotcount and `int_of_float`, both pure
functions of deterministic counters — rather than declaring the technique
impossible. "Replay forbids it" only ever justifies *adapting* the mechanism.

## Performance: profile FIRST, then optimize the part that's actually hot

**Hard-won lesson (nsieve, June 2026): before optimizing the JIT, `perf record` the
benchmark and confirm where the time actually goes — do not assume the traced code is
the bottleneck.** We spent a whole arc making the *traced* loops faster (float
loop-limit → int specialization, then hoisting invariant array base pointers) and the
second change moved nsieve's wall-clock by 0.00s. A 60-second profile would have said
so up front. The JIT was ~3% of the runtime; we were polishing the 3%.

How to actually find the bottleneck (this is the recipe, reuse it):

```sh
zig build -Doptimize=ReleaseFast
NS=~/Projects/LuaJIT/bench/nsieve.lua
perf record -g -o /tmp/p.data -- ./zig-out/bin/lune --trace --jit-native $NS 9 >/dev/null 2>&1
perf report -i /tmp/p.data --stdio --no-children | grep -vE '^\s*#' | head -25
```

Then **roll the symbols up by tier**, because per-symbol noise hides the real split.
The one number that matters first is *how much runs on native JIT code vs the tier-0
interpreter* — sum the `[JIT]` rows vs `interp.Vm.exec`:

```sh
perf report -i /tmp/p.data --stdio --no-children | grep -vE '^\s*#' | awk '
/\[JIT\]/ {jit+=$1} /Vm\.exec/ {exec+=$1} /Table\.(get|set)/ {tbl+=$1}
/hash|wyhash|getIndex/ {hsh+=$1}
END{printf "native [JIT]: %.1f%%\ntier-0 Vm.exec: %.1f%%\nTable.get/set: %.1f%%\nhashing: %.1f%%\n",jit,exec,tbl,hsh}'
```

Two gotchas that bit us, so read percentages carefully:
- **Percentages are relative to a shrinking denominator.** A *working* JIT makes
  `Table.get` look like a *bigger* fraction (19% with JIT vs 8.5% pure-tier-0) only
  because the JIT removed `Vm.exec` time from under it. Always cross-check against a
  pure tier-0 run (`./zig-out/bin/lune $NS 9`, no `--trace`) before concluding a
  symbol "got worse."
- **Isolate a suspected loop instead of arguing about it.** Extract the loop into a
  standalone script with the same call shape and time it + `--dump-native` it.
  `--dump-native` saying "no traces recorded" / "unsupported" is the signal a hot loop
  never tiers up.

> **CORRECTION (2026-07-11).** The verdict below was substantially wrong and is kept
> only so the stale reasoning is visible. Two independent agent investigations (fable +
> gpt-5.6-sol) plus a clean A/B disproved it. What actually holds:
> - **The init loop `for i=2,m do p[i]=true end` traces and compiles to native** via
>   `guard_append → astore_append → loop` (~413 bytes x86-64); `--dump-aborts` shows
>   **zero** aborts. It is ~25–35% of the run, not ~40% "fully interpreted". The
>   "array growth aborts recording → no trace" claim predates the `astore_append` work
>   and is false.
> - nsieve is ~85–90% tier-0 by *cycles* (dispatch + arith helpers over the outer scan),
>   not "~96% because the init loop can't trace".
> - The "make side-trace linking native" lever (below) was built as doc 15 + doc 16, and
>   on nsieve it is **performance-neutral, not a win**: `driveChain` re-enters the runtime
>   per transition (~600ns), which cancels the benefit on 1–2-iteration prime clusters.
>   The real win needs LuaJIT-style exit-branch *patching* (guard patched to jump straight
>   into the side trace, no runtime re-entry). See `docs/design/16-coherent-state-chaining.md`
>   → "nsieve outcome (corrected)".

**nsieve verdict on file — STALE, see correction above:** ~96% of nsieve runs on the
tier-0 interpreter; the JIT covers only two non-branchy inner loops' steady state. The
remaining LuaJIT gap (~5×) is structural JIT-*coverage*, not codegen tightness — making
already-traced code faster cannot close it. The levers, in order:

1. **Untraceable array growth (~40%, biggest).** ~~The init loop `for i=2,m do p[i]=true
   end` grows the array, recording aborts, and it runs *fully interpreted* with no trace
   at all.~~ **FALSE — see correction above; the init loop traces via `astore_append`.**
2. **Side-trace linking already EXISTS but dead-ends on tier-1a.** `tryChainExit`
   (trace.zig, called from the dispatch loop in interp.zig) already does exit-PC
   chaining: on a side-exit it looks up a trace anchored at the exit PC and runs it —
   guard-failure counters + `--trace-hotguard` + side-trace recording are all built. The
   catch: the chain executes via `irinterp.execute` (**tier-1a only**, trace.zig:707),
   and tier-1a is ~equal-to-slower than tier-0 on these bodies (`--trace` 1.20s vs tier-0
   0.79s), so a *successful* chain swaps tier-0 for something no faster — the gate
   correctly retires it. To make linking pay, the chain must dispatch the side trace's
   **native** code (chain native→native), which the float-limit unlock finally makes
   possible (the inner bodies are now native-able and beat tier-0). Do NOT "add
   side-trace linking" — it's there; the work is making the chain path native.
3. **Faster tier-0 dispatch** (threaded/computed-goto) for the genuinely-interpreted
   remainder — untouched.
