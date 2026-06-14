# TODO

Deferred items noted in passing (Rule #10) so they don't get lost.

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

## Generated TS codec: wrong discriminator field for *nested* unions

**Bug (pre-existing, in vendored generated code).** In
`viz/src/gen/generated.ts`, when a discriminated union is a *named field* of a
struct (rather than the top-level value), the generated decoder branches on the
wrong field. Concretely, `EffectDecoder.decode()` reads `value.result.tag` but
then does `if (value.tag === 0) …` (should be `value.result.tag`), so it always
hits the `else` and throws `Unknown discriminator value: undefined` for any
non-empty effect log. The same pattern breaks the snapshot path: a `HeapTable`'s
`TableEntry` `key`/`val` SnapValues decode against `value.tag` instead of
`value.key.tag`, so `SnapshotFileDecoder.decode()` throws on any keyframe that
contains a table (i.e. essentially all real keyframes). The standalone
`SnapValueDecoder` and `TraceFileDecoder` are fine (the union *is* the value
there), which is why traces decode but snapshots/effects don't.

This is a **generator** bug (binschema, `tools/regen-trace-schema.sh`), not a
hand-editable one — `generated.ts` is vendored and regenerated. Fix belongs in
the generator's nested-union discriminator emission, then regen both the Zig and
TS codecs.

**Impact / current mitigation.** The dual-execution differential validator
(`viz/src/diff.ts`) is deliberately decode-free — it byte-compares artifacts and
reads only the effect-log's u32 count prefix — so it is unaffected. But two
things are blocked until the codec is fixed:
  1. The visualiser can't yet *render* keyframe/effect artifacts in TS (only
     traces), so there's no snapshot/effect inspector view.
  2. `diff.ts` can't surface a *structural* divergence (decode both sides, show
     the first differing field) or auto-label cross-platform-FP divergence — it
     can only report which artifact differs and at what byte. Both are easy
     follow-ons once the decoder works.
