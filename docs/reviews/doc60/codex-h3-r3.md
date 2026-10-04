# Codex — doc 60 H3 review, round 3: the record/replay legs (2026-10-05)

**APPROVE**, with two non-blocking findings.

1. **Non-blocking — [src/capi_hostcall_test.zig:1386](/home/bart/Projects/lune/src/capi_hostcall_test.zig:1386), [doc 60:1734](/home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md:1734): `effloop` does not tier up.** `os.nsclock` is an opaque effect native that aborts recording. A `/tmp` probe requiring a committed trace after the twelve calls failed: the trace cache was empty. Remove the tier-up claim, or put a traceable loop between effects and assert that it compiles.

2. **Non-blocking — [src/capi_hostcall_test.zig:1409](/home/bart/Projects/lune/src/capi_hostcall_test.zig:1409): the new callback fixture forgets the keyframe exclusion.** It registers `reenter` while leaving `pr.keyframes = true`, so snapshots encode the host native despite §6.2 saying such captures remain excluded. Encoding stores its name without its host binding; equality does not establish a restorable snapshot. Set `pr.keyframes = false`, consistently with the other callback fixtures.

The harness otherwise appears sound:

- Leg 0’s log is suitable for both replay legs because record logs are compared byte-for-byte.
- Decoding cannot collect before the log becomes a VM root.
- Deterministic callbacks running again provide meaningful differential coverage, while leaving E6 callback replay untested.
- The admission threshold is correct: **20 outer calls plus one nested call**.
- Exhaustion correctly produces fatal `.err_runtime`: `EffectLogExhausted` is non-catchable.
- Scenarios with empty logs provide no additional effect-consumption coverage; the new effectful scenario supplies that coverage.

All **25 filtered C API tests passed in Debug and ReleaseFast** from `/tmp`.

I kept all 31 numbered rules in mind. The repo remained read-only.

[Codex thread: 01a10647-d722-7460-9f2d-e77f58a2c4fa]
