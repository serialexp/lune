# CURRENT TASK — finish `math.random` / `math.randomseed`

## Status: implemented + tested, GATE GREEN, manually verified. Awaiting Codex+Antigravity review, then Bart's review before commit (Rule #15 — do NOT commit until approved).

Finishes the last meaningfully-incomplete base-host functions. The determinism
plumbing (seed-as-`.random_seed`-effect, `Xoshiro256` pinned by name, host
`RandomSeedSource`) already existed; this adds the missing *language surface*.

## What this does

- **`math.random`** — three Lua 5.4 forms (was: float-only flat `random`):
  - `math.random()` → float `[0,1)` (the old behaviour, byte-unchanged path).
  - `math.random(n)` → int `[1,n]`; `n==0` → a full-width random int (all 64 bits).
  - `math.random(m,n)` → int `[m,n]` inclusive; `m>n` → "interval is empty"
    bad-argument error; non-integer/missing arg → bad-argument error.
- **`math.randomseed`** (new):
  - `math.randomseed(x)` → deterministic re-seed (pure; logs no effect; replays
    identically without consuming the log).
  - `math.randomseed()` → fresh OS-entropy seed via the existing `.random_seed`
    record/replay boundary (`obtainRandomSeed`); `RandomUnavailable` with no source.
  - returns the single `u64` seed used (lune's Xoshiro256 takes one word, not
    PUC's two).
- **Namespaced under `math`** (Bart's call): the flat `random` global is gone;
  both are installed into the `math` table via their registry `.module`/`.field`.
  They stay Vm-touching natives in `interp.zig` (they touch the PRNG + effect log),
  not the pure `stdlib/math.zig`.

## Determinism
lune is Lua-*shaped*, NOT PUC-stream-compatible (different engine). The internal
contract — same seed ⇒ same lune stream, reproducible across runs/replay/
native+wasm — holds. Integer uniformity uses our own Mersenne-rejection
`projectU64` on the raw `Xoshiro256.next()` words (Rule Z-2 — off the churny
`std.Random.intRangeAtMost`, so the stream is a pure function of our code + the
pinned engine). `math.randomseed()` is a new entropy-producing call site → touches
the seed/effect path → review gate applies.

## Files
- `src/interp.zig` — `nativeRandom` rewrite (arg dispatch), new `nativeRandomseed`,
  `projectU64` + `randIntArg` helpers, `core_natives` registry (`random`/
  `randomseed` → `module=math`), F2e tests migrated + extended.
- `src/stdlib/math.zig` — doc-comment only (random stays a Vm native in interp.zig).
- `docs/lua-stdlib-inventory.csv`, `TODO.md` — lockstep (both rows → implemented).

## Tests (in interp.zig F2e block)
Migrated the 5 existing F2e e2e tests flat `random()` → `math.random()`. Added:
range `[m,n]` stays in-bounds + hits both ends; `random(n)`/`(1,1)`/`(0)` spans
negatives; empty-interval + non-integer + non-number bad-argument errors;
`randomseed(x)` reproduces the stream (zero effects logged); `randomseed()` entropy
records exactly one `.random_seed` and replays byte-identically; `randomseed()` with
no source is `RandomUnavailable`.

## Verified
- `just test` = 0, `just check-version` = 0.
- Manual: `math.randomseed(42); math.random(1,6)×5` → identical across two runs
  (`2 5 1 4 6`); all three forms + full-width int + `randomseed` return value
  correct; `math.random(5,2)` → `bad argument #2 to 'random' (interval is empty)`.

## Review (DONE — both clean modulo one fix)
Codex + Antigravity reviewed. `projectU64` uniformity/overflow (incl. the full
`[mininteger,maxinteger]` span, the `sh: u6` wrap, span 0/1/2^k/maxInt) and the
range mapping + effect ordering all confirmed sound (Antigravity brute-forced 10M
inputs). **One finding, fixed:** `nativeRandom` acquired the lazy seed (and in
record/replay *logged/consumed* the `.random_seed` effect) BEFORE validating the
integer-form args — so a first-call `math.random("x")`/`math.random(5,2)` would
perturb the determinism boundary before raising its bad-argument error. Reordered:
all arg + interval validation now happens first, the lazy seed only immediately
before an actual draw. Added a regression test (replay with empty log → the
bad-argument LuaError, NOT EffectLogExhausted; record → zero effects logged).
Gate re-run green.

## Next
Await Bart's review + commit approval (Rule #15). After this: the `require`/
`package` arc (multi-file programs) per the agreed plan.
