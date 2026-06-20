# CURRENT TASK — S-C (Unicode case mapping + pinned `unicode_version`, design doc 06)

## Status: implemented + tested, GATE GREEN. Awaiting the Codex+Antigravity determinism review, then Bart's review before commit (Rule #15 — do NOT commit until approved).

(S-A + S-B + the host-input UTF-8 boundary already landed and were committed last
session as c8fb684.)

## What S-C does

`string.upper`/`string.lower` are now Unicode-aware **simple (1:1)** case mapping
instead of C-locale ASCII — one code point → one code point, count-preserving (`ß`
stays `ß`, `ﬀ` stays `ﬀ`; no length-changing, no locale tailoring, no final-sigma).
The hazard is that a Unicode case table churns between releases, which would break
byte-identical replay-forever; the fix (doc 06) is to record the **active Unicode
version** in the session, like the RNG seed, never in the string.

## Files

- **`vendor/ucd/16.0.0/UnicodeData.txt`** (+ `README.md`: URL, sha256, bump policy)
  — vendored UCD so the build is offline/reproducible.
- **`tools/gen_unicode_case.py`** — reads fields 12 (Simple_Uppercase) / 13
  (Simple_Lowercase) for every cp ≥ U+0080 with a mapping, emits the generated
  table. Idempotent (re-run → byte-identical). `just gen-unicode` regenerates.
- **`src/gen/unicode_case.zig`** (generated, `// @generated`) — `unicode_version =
  "16.0.0"`, `unicode_version_packed = 0x100000`, sorted `upper`/`lower` `Map`
  arrays, binary-searched `toUpper`/`toLower` (return cp unchanged if unmapped).
- **`src/function.zig`** — `EffectKind.unicode_version = 6` (scalar int, recorded
  once per session at the first case op, re-pinned on replay).
- **`src/effectser.zig`** — `effect_format_version` 3→4; `resultShapeOf`
  `.unicode_version => .scalar` (rides the `random_seed` scalar-int codec).
- **`src/interp.zig`** — `Error.UnicodeVersionMismatch` (in `narrowError`, and
  **not** catchable — a determinism fault, like `EffectKindMismatch`); `Vm`
  in-memory field `unicode_version_pinned`; file-scope `noteUnicodeVersion` (modeled
  on `obtainRandomSeed`) + `versionAlreadyConsumed` scan helper.
- **`src/stdlib/string.zig`** — `sUpper`/`sLower` → `mapCaseUnicode(vm, args, kind)`:
  `noteUnicodeVersion` first, then walk by UTF-8 sequence — `< 0x80` → ASCII fast
  path; else `unicode_case.toUpper/toLower` + re-encode. Output valid UTF-8 by
  construction, code-point-count-preserving.

## The determinism design (load-bearing)

`upper`/`lower` are pure natives (no JIT — string ops are trace barriers). At the
first case op `noteUnicodeVersion` runs: in `record` it logs the compiled-in packed
version **once**; in `replay` it consumes that effect and asserts equality, else
fatal `UnicodeVersionMismatch`; in `off` it just sets the guard. The "once per
session" guard is **derived, not stored** — the keyframe carries no PRNG/effect
state, so on replay we first scan `effect_log[0..effect_cursor]` for an
already-consumed `.unicode_version` (a pre-cut pin) and skip re-consuming. So
snapshot-resume across an `upper` is correct with **no `snapshot_format_version`
bump** — only `effect_format_version` 3→4.

## Tests

- `src/stdlib/string.zig` — unit: `toUpper(é)=É`, `toLower(Α)=α`, `ß`/`ﬀ`/ASCII
  unchanged; `café→CAFÉ`, `ΑΒΓ→αβγ` round-trips; count preserved (`#upper("héllo")=5`).
- `src/interp.zig` — (1) 8-mode `expectProgram` parity on non-ASCII upper/lower;
  (2) record→replay byte-identity asserting **exactly one** `.unicode_version`
  effect even with two case ops; (3) wrong-version replay → fatal, **pcall does NOT
  catch** `UnicodeVersionMismatch`.
- `src/keyframeser.zig` — snapshot-resume across case ops: cut after the lone effect
  is consumed, restore (which resets `unicode_version_pinned`), run more case ops →
  no double-consume, byte-identical forward output (validates the derivation).

## Docs (lockstep, Rule Z-5)
doc-06 S-C `[x]` (landed note); doc-02 recorded-inputs bullet + effect table row +
`effect_format_version` 3→4; CSV `string.upper`/`lower` rows; TODO S-C-landed +
rng-across-snapshot follow-up.

## Gate
`just test` = 0, `just check-version` = 0.

## Next
Codex + Antigravity determinism-gate review of the effect + guard-derivation path,
address findings, then Bart's review and commit approval (conventional-commits,
trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`).
Then S-D (patterns on code points), S-E (`u8` array lane).
