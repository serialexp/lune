# Doc 62 rev 1 — codex review (2026-10-05)

Thread 01a109e6-3da3-7ff3-9a45-c94ce7760b08. Reviewed the doc plus the uncommitted implementation. Verbatim reply below.

---

## Verdict — CHANGES REQUESTED

Bart, I found one blocker in the hash-key equality contract. The global-slot hint mechanism otherwise appears sound under the documented single-threaded, shared-nothing model.

Validation ran in a fresh `/tmp` copy: `just test` passed. Additional probes passed for normalized scalar keys and same-ID/different-pointer hint hits; two boolean probes failed in both Debug and ReleaseFast.

## Blockers

1. **`Ident.matches` is not equivalent to `Value.eql` for noncanonical boolean payloads.**

   [hash_part.zig:140](/home/bart/Projects/lune/src/hash_part.zig:140) compares scalar payload bits. [value.zig:259](/home/bart/Projects/lune/src/value.zig:259) compares booleans through `asBool`, which treats **every nonzero payload as true** at [value.zig:181](/home/bart/Projects/lune/src/value.zig:181).

   Concrete reproduction: boolean payloads `1` and `11` compare equal and both hash to slot `0` in a four-node map. After storing under payload `1`, reading through payload `11` returns nil. Storing through payload `11` then creates a second entry instead of overwriting the first. Previously, the live-node `Value.eql` comparison recognized this colliding pair.

   `normalizeKey` only normalizes floats at [table.zig:666](/home/bart/Projects/lune/src/table.zig:666). The public Zig value/table interfaces do not enforce canonical boolean payloads, and [capi.zig:293](/home/bart/Projects/lune/src/capi.zig:293) accepts them too—although the C header tells callers to treat values as opaque. Ordinary guest boolean constructors produce `0` or `1`, so this is a representation-boundary failure rather than an ordinary-script reproduction.

   Resolve the invariant explicitly: consistently canonicalize boolean keys across storage, hashing, and matching, or enforce rejection of noncanonical representations at supported ingress points. Merely changing `matches` leaves the existing raw-bit hash/equality inconsistency. Add regression tests and amend the equivalence claim at [62-global-slot-hints.md:142](/home/bart/Projects/lune/docs/design/62-global-slot-hints.md:142).

## Should-fix

1. **Add targeted tests for the remaining hint transitions.**

   The new hint test at [hash_part.zig:718](/home/bart/Projects/lune/src/hash_part.zig:718) covers growth and manually supplied out-of-range hints, but does not explicitly establish shrink, same-capacity rebuilding, or reuse of the hinted dead slot by another key. The interpreter test at [interp_semantics_test.zig:137](/home/bart/Projects/lune/src/interp_semantics_test.zig:137) checks useful output behavior without asserting those particular physical transitions occurred.

   Add deterministic transition tests, plus a same-ID/different-pointer test that exercises **both hinted hit paths**. The existing same-ID test at [hash_part.zig:682](/home/bart/Projects/lune/src/hash_part.zig:682) exercises ordinary probing; my scratch hinted-access probe passes.

2. **Put the shared-proto threading restriction beside the API.**

   [bytecode.zig:634](/home/bart/Projects/lune/src/bytecode.zig:634) introduces mutable storage shared by every VM using that proto. The restriction is acknowledged at [62-global-slot-hints.md:236](/home/bart/Projects/lune/docs/design/62-global-slot-hints.md:236), and fits the current sharing exclusions. Document beside `Proto` that concurrent execution requires synchronization across **all VMs sharing it**. “One thread per VM” alone does not establish that guarantee.

## Nits

1. **The safe-build cross-check claim is broader than the implementation.**

   [62-global-slot-hints.md:139](/home/bart/Projects/lune/docs/design/62-global-slot-hints.md:139) says live matches are checked against `Value.eql`. That happens in [hash_part.zig:384](/home/bart/Projects/lune/src/hash_part.zig:384), but not in hinted hits or `probeForPut`. Qualify the claim. The assertion also cannot detect false-negative identity comparisons, including the boolean reproduction.

2. **Update stale layout comments.**

   [hash_part.zig:21](/home/bart/Projects/lune/src/hash_part.zig:21) still says deletion rewrites the pointer payload to the ID. [nativegen_emit.zig:2191](/home/bart/Projects/lune/src/nativegen_emit.zig:2191) still describes dead keys as holding ID bits in place of a pointer. The new payload is zero.

3. **Qualify the invalidation table’s unconditional outcomes.**

   At [62-global-slot-hints.md:195](/home/bart/Projects/lune/docs/design/62-global-slot-hints.md:195), reinsertion preserves the slot only if it has not been reused or discarded by rehash. A second VM can also produce a valid hint hit, rather than necessarily a miss at line 198. Neither changes the implementation’s soundness argument.

The remaining soundness checks found no additional blocker:

- Bounds, identity, and liveness are checked against the current node array at [hash_part.zig:209](/home/bart/Projects/lune/src/hash_part.zig:209). Dead slots, reallocation, `_G` writes, and sequential sharing therefore preserve lookup results.
- [table.zig:155](/home/bart/Projects/lune/src/table.zig:155) limits hinted stores to existing non-integer entries, excludes grids, and routes deletion through `Table.set`. The write barrier remains after either interpreter store path at [interp.zig:6332](/home/bart/Projects/lune/src/interp.zig:6332).
- Deletion clears the pointer after nil publication at [hash_part.zig:325](/home/bart/Projects/lune/src/hash_part.zig:325); insertion publishes the key before the value. GC marks live iterator entries at [gc.zig:694](/home/bart/Projects/lune/src/gc.zig:694). I found no missed hash-node consumer.
- Restore assigns IDs before wiring table entries at [keyframeser.zig:626](/home/bart/Projects/lune/src/keyframeser.zig:626), and serialization still uses sorted logical entries at [keyframeser.zig:131](/home/bart/Projects/lune/src/keyframeser.zig:131).
- The hrefk capacity/live/tag/ID ordering remains sound at [nativegen_emit.zig:2219](/home/bart/Projects/lune/src/nativegen_emit.zig:2219).
- The volatile pointer at [interp.zig:6293](/home/bart/Projects/lune/src/interp.zig:6293) targets static storage and a matching handler signature; I found no lifetime or UB issue. Wasm validation was blocked by the unchanged 64-bit field assertion at [interp.zig:958](/home/bart/Projects/lune/src/interp.zig:958).

I made no repository changes or mutating Git calls, and kept all 23 global rules and 8 project rules in mind.
