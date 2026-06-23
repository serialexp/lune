# TODO

Deferred items noted in passing (Rule #10) so they don't get lost.

## Cross-frame tracing — the *cluster lever* (June 2026)

Cross-frame Phase 0 (`docs/design/10-cross-frame-tracing.md`) inlines pure
local/param-leaf Lua calls. **Sub-lever 1 — U0 (done, uncommitted):** the recorder
now also reaches a callee through a loop-invariant **upvalue / global** (entry
snapshot + `guard_func`), so spectral-norm's inner loop records a trace. No speedup
yet — that trace carries `guard_func`, which native auto-declines until **U1**
(native `guard_func` lowering; task #186). The remaining JIT-inert shapes still
abort: **method / `__index` dispatch** (`arr:set`, array3d), **generic-for closure
iterators** (array3d's `for … in arr:points()`), and **native callees** (scalar's
`type`/`tostring`/…, correctly never inlined) — each its own change. Tripwire (still
open): U0's callee reads no upvalues of *its own*, so `Proto.id` is still a sound
`guard_func` key; the day we inline a callee whose own body reads an upvalue,
tighten `Proto.id` → closure `GcHeader.id`.

## nativegen — pre-existing latent shape: conflicting-aux duplicate guards on one slot_load (June 2026)

U1's `guard_func` native lowering hardened its prologue-id scan in `analyzeInner`
to **bail** if two `guard_func`s cover one snapshot `slot_load` with *different*
recorded `aux` (the prologue checks one id; the oracle re-checks each and would
side-exit on the second — a native≠oracle divergence). The **`.ptr`/`guard_lane`
scan immediately above it has the identical first-match shape** and is *not*
hardened: two `guard_lane`s on one table `slot_load` with different lane `aux`
would likewise miscompile. Neither is reachable today (the recorder dedups each
snapshot to one synthetic slot → one resolved value → one guard), so this is a
robustness gap in the verifier-gated native subset, not a live bug. If the lane
path is ever generalized, mirror the func-scan's duplicate-aux bail (and consider
lifting the check into `proveKinds` to cover all guard kinds uniformly).

## LuaJIT benchmark corpus — blocked benches (June 2026)

`bench/luajit/` vendors the 14 CLBG/SciMark ports that run byte-identical to
LuaJIT today (array3d, binary-trees, euler14-bit, nbody, nsieve, nsieve-bit,
nsieve-bit-fp, partialsums, recursive-fib, spectral-norm, and scimark-fft/lu/sor/
sparse). The remaining LuaJIT benches are each blocked by one identified gap —
knocking any of these down unlocks the listed benches as new corpus members:

- **`coroutine` library** (none yet): unlocks `chameneos`, `coroutine-ring`.
  Largest lift; intersects determinism (coroutine resume order must be replayable).
- **LuaJIT `bit.*` library** — RESOLVED, not added (June 2026). lune already has
  native 64-bit bitwise *operators* (`&` `|` `~` `<<` `>>`, wired by the metamethod
  arc). Bart's call: do **not** add a `bit` module — its int32-normalization would
  bolt a 32-bit-semantics island onto a 64-bit language, which Lua 5.4 itself
  rejected in favour of native operators. lune also stays strict integer-only
  (unlike 5.4 it does not coerce integral floats in bitwise ops; the error message
  was fixed to the Lua-shaped "number has no integer representation" / "attempt to
  perform bitwise operation on a <type> value"). `euler14-bit` and `nsieve-bit` are
  now in the corpus, **rewritten** to native operators (semantically equivalent,
  not code-identical); LuaJIT runs the verbatim `bit.*` originals under
  `bench/luajit/_ref/` via the new `luajit_src=` metadata key, and both halves are
  byte-identical. `mandelbrot-bit`/`md5` remain blocked on binary output / non-ASCII
  escapes, independent of bitwise support.
- **Leveled long-bracket strings `[[…]]` / `[=[…]=]`** — DONE (June 2026, lexer +
  compiler, 8-mode tested). This was a genuine Lua 5.4 conformance gap (lune
  previously lacked long strings entirely, even `[[…]]`). It did **not** unlock the
  dynamic-codegen ports as hoped: `fasta`/`pidigits-nogmp`/`revcomp`/`meteor` each
  pile on further LuaJIT-isms — the `jit.*` module, `loadstring` with a *numeric*
  chunkname, stdin (`revcomp`), and `...` forwarded into the loaded chunk. Left
  blocked; revisit per-bench if those land. `loadstring` (a 5.1 alias of
  `load(string)`) was deliberately **not** added — it unlocks nothing measurable on
  its own and is a 5.1-ism; reconsider alongside the broader compat-alias question.
- **`require`-from-cwd in `bench/run.py`** — DONE (June 2026). `run.py` now runs
  every child (lune all tiers + LuaJIT) with `cwd` set to the bench's own
  directory (`run_once`/`time_best` gained a `cwd=` param), mirroring LuaJIT's
  `run.sh` `cd $BENCH_DIR`, so `package.path`'s `./?.lua` resolves the shared
  `scimark_lib.lua` (vendored verbatim, no `@bench` header). Unlocked the four
  `scimark-{fft,lu,sor,sparse}` kernels (corpus 10→14). They are pure-timing benches
  (the kernels return a discarded flop count → empty stdout → empty==empty parity)
  and sit 35–76× off LuaJIT — the float/array throughput the JIT is still a no-op on.
- **Binary / Latin-1 output** (`io.write` of non-UTF-8 bytes) or non-UTF-8 source:
  `life` (Latin-1 source string), `mandelbrot`/`fannkuch` (binary PBM output +
  a perm-printing branch divergence). Needs care re: the UTF-8 source/output policy.
- **Missing functions**: `k-nucleotide`, `sum-file` (io.read/io.lines shapes).
- **Deep non-tail recursion** overflows lune's call stack at LuaJIT's N:
  `recursive-ack` (Ack(3,6) overflows; matches only at small N). Needs a growable
  / deeper VM call stack.
- Excluded: programs that print their own `os.clock` timing (`series`) — stdout is
  not byte-comparable across runs (the clock is an effect, legitimately varying).

### Pre-existing bench bug (separate, Rule #10): `bench/stdlib/str_manip.lua` is mislabeled `luajit=compatible`
Discovered while vendoring scimark (June 2026). `str_manip.lua:17` does `local byte =
string.codepoint`, but `string.codepoint` is a Lua 5.3+ function LuaJIT (5.1) lacks,
so on LuaJIT `byte` is nil and line 28 errors `attempt to call upvalue 'byte'`. The
harness has always shown this as `luajit=ERR` (independent of the new per-bench cwd —
it errors identically from the repo root). The names don't line up across engines:
lune has only `string.codepoint` (S-B removed `string.byte` for code-point semantics),
LuaJIT 5.1 has only `string.byte`. The bench's own comment notes the base string is
all-ASCII, so a lune code point equals a LuaJIT byte — so parity is achievable two
ways: (a) flip the bench to `luajit=skip` (simplest, loses the parity check), or (b)
use the `luajit_src=` mechanism (the `_ref/` file calls `string.byte`, the lune file
calls `string.codepoint`), the same shape as the `euler14-bit`/`nsieve-bit` split. Out
of scope for the scimark commit; left for a separate bench-fix pass so it isn't bundled
with unrelated corpus work.

## Unicode-native strings (design doc 06) — S-A..S-E ALL LANDED (June 2026)

S-A (text↔bytes boundary, `src/stdlib/string.zig`, `sEncode`/`sDecode`):
`string.encode`/`s:encode()` → byte array (table, integer keys `1..n`, `0..255`),
total; `string.decode(bytes)` → interned string, raising a **catchable** error on
invalid UTF-8 / out-of-range / non-integer elements.

S-B (code-point-native strings, the breaking core): a `string` is a sequence of
Unicode code points. `#s`/`string.len`/`sub`/`reverse`/`string.char`/
`string.codepoint`/`s:codes()` index by code point; cached `cp_len` on the heap
`String` (computed in `String.create`, recomputed on restore — no schema bump);
`#s` is tier-0-only so all 8 modes inherit it (no JIT change). `\u{…}` lexer
escape; `\xNN`/`\ddd` are ASCII-only (byte ≥ 0x80 → compile error); every literal
validated UTF-8 at construction (`decodeString` + `utf8ValidateSlice`).
`string.byte` removed; no `utf8` module ships. CSV + doc-06 updated in lockstep.

**S-D LANDED (June 2026) — patterns on code points + character indices.** The
matcher (`src/stdlib/pattern.zig`) now steps the **subject** by code point: `.`
matches one whole code point, a literal multibyte char is one item (`classEnd`
groups the UTF-8 sequence), and quantifiers/anchors/captures advance by code-point
width. Greedy `maxExpand` backtracks one code point at a time via a backward
continuation-byte scan (`cur -= 1; while (src[cur] & 0xC0)==0x80`), so `MatchState`
stays **allocation-free** (no scratch). Class shorthands (`%a %d …`) and bracket
sets stay **ASCII**, guarded by `src[s] < 0x80` in `singleMatch` — load-bearing,
not an optimization: without it a high byte wrongly satisfies a *complement* class
(`%A`/`%D`/`[^…]`). At the `string.zig` seam, `find`/`match`/`gmatch`/`gsub` accept
and return 1-based **character** indices (`resolveInit`→`charByteOffset`, byte
offsets→`cpCount`, position captures `()`→`byteToChar`); captures stay byte offsets
inside the engine and convert only at the boundary. The matcher is a pure,
allocation-free function of its byte inputs — no host effect, no recorded input —
so 8-mode determinism is inherited (asserted by an `expectProgram` test). **Caveat
(documented, out of scope):** multibyte chars inside bracket sets (`[é]`, `[é-ñ]`)
and multibyte `%b` delimiters stay byte/ASCII-level; Unicode property classes
(`\p{L}`) deferred. CSV + doc-06 updated in lockstep.

**RESOLVED — host-input UTF-8 boundary.** S-B's review (Codex + Antigravity) flagged
that the "every string is valid UTF-8 by construction" invariant held for string
*literals* and `string.decode` but NOT for host-sourced strings. Bart's call: **reject**
— the host-input boundary now validates and raises a *catchable* error (like
`string.decode`). `Vm.validateHostText` (`interp.zig`) checks `utf8ValidateSlice` and
raises a located error; it is called on the *logged* result in `performEffect`
(`getenv`/`argv`) and `obtainFileRead` (`file_read`) — **after** `logEffect`, so record
(fresh intern) and replay (re-intern from the log) validate identical bytes and raise
identically — and inline in `populateArgs` (load-time `arg[]`, before intern). No
malformed string can now reach a program, so the `cp_len`/`charByteOffset` divergence is
gone too. `internValue` stays raw (internal callers are valid by construction; the
replay re-intern path must not re-raise mid-feed).

**S-C LANDED (June 2026) — case mapping + recorded `unicode_version`.**
`string.upper`/`string.lower` are now Unicode-aware via the vendored, versioned
**simple (1:1)** case table (`src/gen/unicode_case.zig`, generated by
`tools/gen_unicode_case.py` from `vendor/ucd/16.0.0/UnicodeData.txt` fields 12/13;
`just gen-unicode` regenerates). ASCII is the branch-free fast path; non-ASCII
maps one code point → one code point (count-preserving — `ß`/`ﬀ` unchanged). The
active version (16.0.0, packed `major<<16|minor<<8|patch`) is recorded once per
session as `EffectKind.unicode_version`=6 at the first case op (`noteUnicodeVersion`,
modeled on `obtainRandomSeed`) and re-asserted on replay — a mismatch is a fatal,
**uncatchable** `Error.UnicodeVersionMismatch`. `effect_format_version` 3→4 (the
only wire bump; rides the scalar-int `EffectResult` path). The "once per session"
pin is **derived, not stored**: the keyframe carries no effect-cursor/PRNG state,
so a snapshot resume re-scans the consumed effect-log prefix
(`versionAlreadyConsumed`) instead of needing a `snapshot_format_version` bump
(proven by the keyframeser resume test).

**FOLLOW-UP (pre-existing, separate, Rule #10): once-per-session effects across a
*record-mode* snapshot resume.** The keyframe carries no `effect_log`/`effect_cursor`/
PRNG state (that's what made S-C's *replay* pin a sound *derived* guard). The flip
side, flagged by Codex's S-C review: snapshotting a **live recording** and resuming
it *in record mode* would re-log every once-per-session effect — both the **RNG
seed** (`EffectKind.random_seed`) and now the **`unicode_version`** pin — because
`restore` resets their in-memory guards and the record arm has no recorded prefix to
derive from. The replay-resume path (the harness we actually ship) is correct; only
the hypothetical "resume a live recording as a fresh recording" flow is exposed, and
it is exposed *symmetrically* for both effects, so the fix belongs at the keyframe
layer (persist `rng`/`effect_cursor`/`effect_log` + a `snapshot_format_version` bump),
not as a per-effect patch. Out of scope for S-C — noted so it isn't lost.

**S-E LANDED (June 2026) — the `u8` (unsigned-byte) array lane.** Byte arrays
(integers in `[0,255]`) now pack at **1 byte/slot** instead of `i16`'s two (a byte
overflows signed `i8`'s 127 ceiling). `u8` is the final rung appended to the
`Lane` enum (ordinal 7, so existing ordinals stay put — trace IR embeds them in
`guard_lane.aux`). It is a *sibling* entry point, not below `i8`: a new
`intLaneForRange(lo,hi)` chooser maps a non-negative `[lo,hi] ⊆ [0,255]` to `u8`
and routes `laneForValue`/`optimalLane` through it; a negative or `>255` store
widens to the smallest *signed* lane covering the **combined** range
`[min(0,v),max(255,v)]` — always `≥ i16`, never `i8`, never back to `u8` (so high
bytes survive), via `widenFor`'s `.u8` arm. `canWidenTo(.u8,·)={i16,i32,i64,value}`;
nothing widens *to* `u8`. `decode` zero-extends (`@as(i64, byte)`), `encode`
`@intCast`s, `laneFits`/`dataBytes`/`usesPresenceBitmap`/`isInt` get `u8` arms. In
`nativegen.zig`: a `U8_LANE` const, `laneKind→.int`, `intLaneWidth→1`, an `aload`
that zero-extends (`movzx` — the existing `loadRegMemSib(width=1, signed=false)`,
**no new x64 op**) instead of the signed lanes' `movsx`, and a `guard_fits` that
range-checks `[0,255]` derived from the *lane* (not the width, since width-1 is now
ambiguous with `i8`). The store path (width-truncate + presence `bts`) is
signedness-agnostic and unchanged; the trace recorder gate (`lane.isInt()`) now
includes `u8` automatically. Lanes are never serialised and the native load matches
tier-0 `decode` byte-for-byte, so determinism/8-mode parity is inherited. **Accepted
trade (Bart's framing):** `{1,2,3}`→`u8` (was `i8`, both 1 B/slot); `{1,2,-3}`→`u8`
then widens to `i16` (was `i8`). Tests: array unit (commit/zero-extend-decode/
combined-range widen), nativegen unit (zero-extend read scan, in-range write,
`guard_fits` side-exit at 256 and −1), interp 8-mode (byte-array workload + `u8→i16`
widen). doc-06 S-E `[x]` + open-question resolved; bench `cross: ok`, no regression.

## `load` / `loadfile` / `dofile` LANDED — deferred follow-ups (June 2026)

The full runtime-compile arc is in (`src/stdlib/load.zig`):
- **L-1 `load(chunk [, chunkname])`** — string chunk → vararg closure, `(nil, msg)`
  on syntax error, VM-owned `loaded_chunks` (freed at `Vm.deinit`), globally-unique
  proto ids via `compiler.Options.id_base`/`vararg_root`, per-proto `source` so
  faults report the loaded chunk's line/name.
- **L-2 recompile-on-restore** — a live `load` closure survives snapshot→restore:
  the keyframe carries each load's source text (`schema.LoadedChunk`) and restore
  recompiles deterministically (`recompileLoadedChunks`), resolving `proto_id`
  across static + dynamic trees. Hardened against `DuplicateInternedString` and
  `IdSpaceExhausted` (Codex review).
- **L-3 `loadfile`/`dofile`** — file content read via the injected `fs_source` seam
  and logged as `EffectKind.file_read` (record) / fed back from the log (replay);
  `effect_format_version` 2→3. `loadfile` → closure or `(nil, "cannot open <path>")`;
  `dofile` runs the chunk with no args and returns its results, raising on
  read/compile error.

Deferred:
- **Reader-function `chunk`** — only the string form is accepted today.
- **`mode` arg (`"t"`/`"b"`)** — lune has no binary bytecode; `string.dump` is
  excluded, so only text loading exists. The arg is simply ignored/unsupported.
- **`env` arg** — lune has no `_ENV` upvalue, so no per-chunk environment.
- **Per-chunk arena reclamation** — `load` in a loop accumulates `LoadedChunk`s
  until VM teardown (correct, leak-free per `testing.allocator`, but unbounded
  within a run). GC-integrated chunk lifetime is a later optimization.

## `_G` + error ergonomics LANDED (June 2026)

Lua-compat chunk: `_G`, `xpcall` before-unwind handler, `debug.traceback`.
- **`_G`** — the global environment exposed as a self-reference into the globals
  table (id 0), seeded in `installBaseLib` next to `arg`/`_VERSION`. The
  self-edge serializes as `HeapRef{id=0}` and round-trips the keyframe path; the
  unknown-global lint knows it (added to `builtin_global_names`).
- **`xpcall`** — the message handler now runs **before** the stack unwinds
  (`protectedCall` in `stdlib/errors.zig` reordered: call the handler with the
  faulting frames live, restore `depth`/`stack_top` only after it returns). pcall
  unchanged; handler-faults (catchable → `"error in error handling"`,
  non-catchable → re-raise) unchanged.
- **`debug.traceback`** — new `src/stdlib/debug.zig`, one native reusing
  `Vm.backtraceFrames`. Lua-shaped: no `thread` arg (no coroutines); a
  non-string, non-nil message passes through unchanged; `level` (default 1) skips
  leaf frames. Pure function of static proto names + source offsets → 8-mode
  deterministic; a native call is a trace barrier so no recorder/JIT change.

**Intentional semantic change:** because the handler now runs on the *live*
faulting stack, a located error *inside* the handler (`error(msg, level)` with
`level` reaching the faulting frames) resolves to the original error site, not
the restored xpcall boundary — this is Lua's before-unwind behavior and is
deterministic across all 8 modes (Codex flagged it; it's the intended effect).

**Pre-existing (noted, not in scope):** `nError`'s `raiseLocatedError(bytes,
@intCast(level))` and any `@intCast(i64→usize)` of a user level can trap on a
32-bit target (wasm32) for a huge in-`i64`-range level. `debug.traceback`'s own
level handling was made 32-bit-safe here; the `error()` path is unchanged and the
wasm build is already broken for an unrelated reason (see the `zig build wasm`
section). Fix alongside that.

**Deferred / known cosmetics:**
- Traceback lines render a named function's name as *both* chunk and function
  (`foo:5: in function 'foo'`) because lune conflates per-function `proto.name`
  with the chunk name (consistent with existing `chunk:line:` error messages).
  Cosmetic; not worth a per-function chunk/name split yet.
- The rest of `debug.*` (`getinfo`/`sethook`/`getlocal`/…) stays unimplemented —
  most is determinism-hostile or excluded in the inventory.

## Metatables — chunks 2a + 2b LANDED; remaining follow-ups

Chunk 2a (the OO core) landed (June 2026): `Table.metatable` field + GC mark +
keyframe persistence (`HeapTable.metatable_id`, `Keyframe.string_metatable_id`,
snapshot v3); `setmetatable`/`getmetatable` (with `__metatable` protection);
`__index`/`__newindex` (table + function forms, bounded chain via
`Vm.indexGet`/`indexSet` + `MetatableChainLoop`); the shared string metatable so
`("x"):upper()` resolves through `string`; and the recorder aborts
(`AbortReason.has_metatable`) at `recArrayGet`/`recArraySet` so metatable-bearing
tables run tier-0. The dispatch keystone is `Vm.metatableOf` + `Vm.metamethod`
(interp.zig) over the cached `Vm.mm` name strings.

Chunk 2b (the operator metamethods) landed (June 2026): `__add __sub __mul __div
__mod __pow __idiv` (arith), `__unm` (neg), `__band __bor __bxor __shl __shr
__bnot` (bitwise), `__eq` (two-tables-only), `__lt`/`__le` (with `>`/`>=` via
operand swap), `__concat`, `__len`, `__call` (single + multret), and
`__tostring` (`tostring`/`print`). All route the tier-0 op's TypeError /
non-callable path through one shared helper set in interp.zig
(`binMeta`/`unMeta`/`arithMeta`/`unArithMeta`/`compareMeta`/`valuesEqual`/
`lenValue`/`metaToString`), each ultimately calling `Vm.callValue` — a trace
barrier, so every recorded op already aborts on a non-number operand and
side-exits to tier-0. 8-mode parity + a deterministic hot-loop `__add` corpus
under `interp.zig` tests.

**Deferred metamethod follow-ups:**
- `__name` metafield in `tostring`/error rendering (not yet honoured; only
  `__tostring` is). Out of the 2b scope.
- `string.format %s` honouring `__tostring` (currently raw-renders).

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
3. ~~**`math.random` / `math.randomseed`**~~ — **LANDED (June 2026).** Now
   namespaced under `math` (the flat `random` global is gone), with all three Lua
   5.4 forms: `math.random()` float `[0,1)`, `math.random(n)` int `[1,n]` (`n==0` →
   full-width int), `math.random(m,n)` int `[m,n]` (`m>n` → "interval is empty"
   bad-argument error). Uniformity comes from our own Mersenne-rejection
   `projectU64` on the pinned `Xoshiro256` word stream (Rule Z-2 — off the churny
   `std.Random.intRangeAtMost`; Lua-*shaped*, deliberately **not** PUC-stream-
   compatible). `math.randomseed(x)` re-seeds deterministically (logs no effect);
   `math.randomseed()` pulls fresh OS entropy through the existing `.random_seed`
   record/replay boundary and returns the single `u64` seed used. Both stay
   Vm-touching natives in `interp.zig` (PRNG + effect log), installed into the
   `math` table via their registry `.module`/`.field`. This finishes the base-host
   tier — only `basic.warn` and `os.clock`'s `partial` remain outside cli-binding.

   **LANDED (June 2026): base-host tier closed.** `os.clock` now returns
   Lua-faithful **float seconds** (`nativeClock`, namespaced under `os`; the
   recorded `.clock` effect now carries the float — the serializer round-trips
   float scalars); the flat `clock` global is gone. Added the lune extension
   `os.nsclock()` → raw **integer nanoseconds** (shares the `.clock` effect).
   `warn(...)` (Lua 5.4) landed as pure stderr output (`Vm.err`, NOT a recorded
   effect, like `print`): all args must be strings, concatenated to one
   `lune warning: …` line; a single `@`-prefixed piece is a control message
   (`@off`/`@on` toggle `Vm.warn_enabled`, recognized even while off; unknown `@…`
   ignored). `warn_enabled` is per-session, not serialized.

   **LANDED (June 2026): require/package module system.** `require` + the
   `package` table (`src/stdlib/package.zig`), built on the existing
   `fs_source`/`file_read` effect — base-host, host-injectable loader, no new seam.
   Faithful searchers-as-functions model (`package.searchers` = preload + path,
   both `manual` natives rebound by name on restore). `package.searchpath`,
   `package.loaded` (pre-seeded with built-ins), `package.preload`, `package.path`,
   `package.config`; `package.cpath` is an inert empty field (no native loading
   under determinism), `package.loadlib` stays excluded.

   - FOLLOW-UP (require cycles): a `require` cycle (A requires B requires A) is not
     yet detected with a dedicated "loop or previous error loading module" message —
     it currently bottoms out in `StackOverflow` via `native_reentry_depth`. Lua
     marks `package.loaded[name]` with a sentinel during loading to detect this;
     add the sentinel + a clear cyclic-require error.

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
   logical `not`. (`shl`/`shr` LANDED June 2026 — branch-bracketed `cl`-shift in
   `nativegen.emitShift`, confined to nativegen + x64; see the shift-lowering note
   below.)
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
8. **scimark-sparse trip-decline / recorder-bookkeeping residual (~17% jit>t0).**
   Found while landing the native-unsupported safety net (June 2026). `--jit-native`
   leaves scimark-sparse ~17% slower than pure tier-0, but it is **not** a
   native-unsupported / tier-1a problem (the safety net is inert here: gates=0,
   skips=0, entries=0). Root cause: the hot inner kernel
   `for i=row[r],row[r+1]-1 do sum=sum+vx[col[i]]*val[i] end` runs exactly
   `nr=floor(nz/n)=floor(5000/1000)=5` trips — below `min_trip_entry=24` — so dispatch
   **trip-declines** entry every invocation and the trace never runs (native or
   tier-1a). The cost is pure trace-dispatch bookkeeping on a short hot loop nested in
   a hot outer loop: per-back-edge `onBackEdge` (hashmap getOrPut) + `isGated` +
   `armShortLoopSkip`, plus the middle loop (`for r=1,n`, 1000 trips) which never
   commits a trace and re-pays `onBackEdge` + fingerprint-miss every back-edge. Pure
   tier-0 (no `--trace`, `config.enabled=false`) skips all of it. Addressable only by
   cheaper warming-loop bookkeeping or by tracing the middle loop with the inner loop
   unrolled — neither is the safety net nor shift codegen. Distinct, pre-existing
   JIT-coverage issue.
9. **Int-lane astore of a constant bails native (guard_fits DCE'd).** Found while
   landing shl/shr (June 2026) by diagnosing why nsieve-bit's array-init loop
   `for i=0,(m>>6) do p[i]=-1 end` stays native-unsupported (`trace #2`) on the
   2nd/3rd `nsieve` call (in-bounds store into the reused `primes` table). The
   recorder emits a `guard_fits` ahead of every int-lane `astore` (trace.zig:1712),
   but `tropt` **DCE's it when the value is a constant** that provably fits the lane
   — so `proveKinds`' unconditional `if (!fits_ok[ins.b]) return false`
   (nativegen.zig int-lane `astore` arm) rejects the trace. This is the *exact* case
   already exempted for the **f64 lane** (the `astore` requires no `fits_ok` because
   a `movsd` never narrows; nativegen.zig:~624 comment) and the **bool lane**. The
   narrow int lanes (i8/i16/i32) genuinely need the range check for *free-variable*
   stores, but a constant that survived `tropt`'s fold provably fits — the fix is to
   admit a constant (or otherwise statically-in-lane) int `astore` value without a
   covering `guard_fits`, mirroring the f64/bool exemption, while still requiring it
   for free-variable int stores. Determinism subtlety: must prove the constant fits
   the *recorded* lane width (the prologue `guard_lane` pins it), so a later
   wider-lane store still side-exits. Net effect: would unlock the init loop's
   constant fill to native (currently 100% tier-0). Distinct from shl/shr; new
   nativegen analysis change → fresh plan + Codex/Antigravity review first.

### Native shl/shr lowering (nsieve-bit shift loops) — LANDED (June 2026)

`shl`/`shr` now lower to native (`nativegen.emitShift`): a **branch-bracketed
`cl`-shift** that reproduces Lua's shift semantics (`arith.shiftLeft`/`shiftRight`)
exactly — the x86 `shl/shr reg,cl` only honours the low 6 bits of the count, so the
lowering brackets the hardware shift with explicit range checks: count `< 0` →
negate and shift the other direction; `|count| ≥ 64` → result 0; else the bare
`cl`-shift. Confined to `nativegen.zig` (proveKinds Int arm, `isTransient`,
`operandReads`, `emitShift`, lower dispatch) + `x64.zig` (`shlRegCl`/`shrRegCl`,
`Cond.s`) — **no** new IR op, no recorder/snapshot/irinterp/tropt change (shl/shr
stay opaque ops; only native lowering was added). Uses only the dst register (or rax
for a spilled dst) + rcx scratch, so it fits the cut-2 allocator's two scratch
registers regardless of operand homes (count loaded into rcx *first*, since the
allocator may reuse a dying operand's home as the result reg). Differential-tested
vs the tier-1a oracle across every count regime (in-range, ≥64→0, negative→reverse,
INT64_MIN). Measured: nsieve-bit **t0 139 ms → jit 55 ms (2.5× native win)** — the
two shift-bearing inner loops now compile native (538 + 448 bytes); previously they
were the native-unsupported traces the Part 1 safety net retired to tier-0. (The
array-init loop `trace #2` stays unsupported for the separate constant-store reason
in item 9 above.)

### f64 array lane (Phase D Gap A) — LANDED (June 2026)

The float (`.f64`) array lane now lowers to native (`nativegen.zig`): `laneKind`
admits `.f64 → .float`, the `aload` arm classifies a loaded double as `.float`, and
the `aload`/`astore`/`guard_fits` lowering arms mirror the int lanes with `movsd`
(`lea` addr → `movsd` load into the XMM/spill home; stage value → `movsd` store +
presence `bts`; `guard_fits` no-op). The f64 `astore` requires **no `fits_ok`** (a
full-width `movsd` never narrows — mirrors the bool lane, not the narrow int lanes),
so a constant-float fill compiles even after `tropt` folds the redundant guard.
Measured: pure float read reduction **13.9×** over tier-0, constant fill **9.0×**
(both were 0% native before); ~4–7× off LuaJIT now (codegen tightness, not coverage).
8-mode byte-identical (read + fill e2e in `interp.zig`); nativegen unit tests for the
write + idempotent-deopt-replay. Reviewed by Codex + Antigravity, Bart-approved.

**Gap B (store-sinking) — LANDED (June 2026, doc 07):** the scimark hot loops are
read-modify-write (`vi[k] = vi[k] - eij*vj[k]`) and array copies, which the recorder's
old **C1 rule** (`trace.zig` `recArraySet`: any `astore` after any `aload` →
`.bad_type`) aborted — so scimark-lu/sor were unmoved by Gap A (jit ≈ t0). Lifting C1:
the recorder now **defers the single RMW `astore` and re-emits it in `commit()` just
before `.loop`** — below every loop-exit guard. No side-exit can follow the store, so
coarse deopt never re-runs a half-applied iteration (tier-0 re-runs the iteration from
the loop header and stores exactly once). Constrained to one store that is the trace's
*last* array access (any later aload/astore/append aborts). Measured: scimark-sor
**46.9× → 4.5×** vs LuaJIT (10.5× over tier-0), scimark-lu **74.5× → 12.4×** (6×).
8-mode byte-identical (RMW `expectProgram` e2e in `interp.zig`; recorder + nativegen
unit tests). Reviewed by Codex + Antigravity (design + implementation).

**Gap C (multi-store) — LANDED (June 2026, doc 08):** generalized Gap B's single
deferred `astore` to a bounded ordered set (`MAX_PENDING_STORES = 4`) flushed
front-to-back in recorded (bytecode) order below every guard, so FFT's butterfly (4
reads then 4 RMW stores to two indices) records + runs native. A second/third/fourth
in-bounds RMW `astore` now appends to the pending set instead of aborting; a post-store
`aload`/`astore_append` or exceeding the cap still aborts cleanly. Measured: scimark-fft
**54.3× → 39.1×** vs LuaJIT (t0 993.9 ms → jit 715.7 ms; 1.39× over tier-0; `cross=ok`).
8-mode byte-identical (two-store butterfly `expectProgram` e2e + recorder/nativegen
units). **Remaining scope:** sparse (indirect `x[col[k]]` gather, not a same-index RMW)
stays ~35× off LuaJIT; FFT's remaining gap is structural coverage (bit-reversal +
non-butterfly work still tier-0), not codegen tightness.

**Tier-0 array decode/encode fast path — LANDED (June 2026):** profiling pure tier-0
(no `--trace`) of the array-heavy scimark kernels showed the bottleneck is NOT dispatch
(the interpreter `jmp` is 0.46%) but `array.ArrayPart.decode` — 55% of scimark-sparse /
11% of scimark-fft, as an *out-of-line call per element* across the interp.zig→array.zig
module boundary. Fix (src/array.zig only): (1) marked `get`/`setInLane`/`decode`/`encode`
`inline` so the read/write chain folds into `execImpl` (the loop-invariant lane `switch`
hoists; the per-element call vanishes — decode dropped from a 55% symbol to fully inlined,
execImpl 98%); (2) removed a gratuitous `@memcpy` stack-buffer round-trip in
`readInt`/`writeInt` (byte-identical, same `.little`). Tier-0 wins, all `cross=ok`:
scimark-sparse 866→770 ms (~11%), lu 1162→1019 (~12%), sor 953→871 (~9%), fft 994→911
(~8%); other benches flat (not decode-bound). NaN-boxing was explicitly ruled out — the
16-byte tagged `Value` is foundational to determinism+replay; this cuts cost *around* the
Value. Reviewed (Codex + Antigravity, both sound). The remaining `execImpl` cost is
inherent 16-byte `Value` register-file shuffling (`vmovapd` spills + `×16` offsets), not
addressable without changing the Value rep.

**Minor finding (pre-existing, int lanes):** a constant-int *fill* (`a[k] = 7`) also
fails to compile — `tropt` folds its `guard_fits` (the constant provably fits), so the
int `astore` arm's `fits_ok[value]` requirement is never satisfied → bail. Unlike f64
(full-width, every value fits), a narrow int lane genuinely needs the range proof, so
the fix would be a proveKinds path that range-checks a *constant* store value directly
(at prove time) instead of relying on a runtime `guard_fits`. Low priority; not a
regression (predates Gap A). Noted so it isn't re-discovered as a bug.

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
