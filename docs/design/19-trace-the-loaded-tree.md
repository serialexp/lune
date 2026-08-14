# Trace the loaded tree — root `loaded_chunks`, lift the H-2 dynamic-proto gate

Status: design APPROVED (codex gpt-5.6-sol round 2, 2026-08-14) — implementation not started
Owner: Bart + Claude
Last updated: 2026-08-14

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move to Done once everything inside them is checked.

### Done

_(nothing yet)_

### Outstanding

- [ ] **Phase 0 — root `loaded_chunks` in both walks + schema bump.**
      `forEachRootHeader` walks `vm.loaded_chunks[].chunk.proto` through
      `rootProtoConsts`, immediately after the `retained_chunks` loop, in BOTH
      `.gc` and `.snapshot` kinds. Keyframe schema v7→v8 (§R1 blocker):
      pre-rooting snapshots are rejected; restore gains the post-recompile
      integrity check `heap.next_obj_id == kf.next_obj_id` (a v8 snapshot that
      trips it is corrupt by definition, `LoadedChunkRecompileAllocated` or
      similar).
- [ ] **Phase 1 — lift the gates, remove the dead machinery.** Remove the three
      anchor early-outs (`if (key.proto.dynamic) return;`), the `recCall`
      `abort(.dynamic_proto)`, the `.dynamic_proto` `AbortReason` member, and
      `Proto.dynamic` + its `compileWithOptions` option + both stamping sites
      (§R1 confirmed: no other production reader exists).
- [ ] **Phase 2 — flip the H-2 gate tests + doc sweep.** The "records ZERO
      traces" and negative-control tests become "records normally +
      byte-identical across modes"; the `.dynamic_proto` inline-abort test
      becomes an inline-succeeds test. New test: the July sole-root scenario
      itself (load, run hot loop, drop closure, collect, snapshot) is
      byte-identical across modes. Doc sweep per §R1 Q3: doc 03 §Chunk-constant
      rooting (currently *rejects* rooting `loaded_chunks`), `compiler.zig:80`,
      `load.zig:116`, `keyframeser.zig:477` + `:551` comments, doc 04
      (snapshot schema) + the version-history comment at `keyframeser.zig:45`
      for the v8 bump, doc 17 gate sections marked superseded-by-doc-19 (not
      rewritten).
- [ ] **Phase 3 — measurement.** scimark family + full board + memory columns;
      predictions P.1–P.4 below. Record results here.

## Why this exists

The H-2 part-1 gate (doc 17, landed 2026-07-18) makes every dynamically-loaded
proto permanently untraceable: no trace may anchor in one or inline a call into
one. The accepted cost was "`load`/`loadfile`/`dofile` chunks never JIT (rare,
and correctness-first)". The premise is falsified: **`require` compiles modules
through the same `loadChunk` path** (`package.zig searchPathCore →
load.compileToClosure`), so any module-structured program is JIT-dark. Measured
2026-08-14 (bench 20260814-191341): scimark-lu is 73.5× LuaJIT with **zero
traces, zero aborts** — recording never starts — and `lu_factor:128` alone is
92.2% of the run, 100% tier-0. The whole scimark family shows the same shape.

The gate was correctness-first and stays correctness-first: this doc removes it
by removing the hazard it guarded, not by weakening the guarantee.

## The hazard, restated precisely

(Condensed from doc 17 §"H-2 hard half — design".) The only heap values a trace
const pool can hold are **interned proto-literal strings** (`load_const`
konsts). GC marks proto constants downward from **live closures**
(`markProtoConstants`). The static tree is immune to sole-rooting because
`frames[0].closure` roots the whole static proto tree for the run. A dynamic
chunk is different: `loaded_chunks` retains `{chunk, source}` but **not** the
closure, so when the guest drops the last closure over a loaded chunk, the
chunk's string constants lose their only tier-0 root. A committed trace's const
pool (never retired before VM deinit within an epoch) then becomes the string's
**sole root**: record modes keep the string interned, `.off` sweeps and
de-interns it, and a later re-intern yields a different id → observable
divergence (`pairs` order, table capacity), plus a snapshot that would have to
serialize a trace-only object.

**Both facets share one root cause: the constant's liveness depends on tiering.**
Make the constant's liveness mode-invariant and every facet vanishes.

## The fix: make loaded-chunk constants VM-lifetime roots (all modes)

Add one loop to `forEachRootHeader`, in both `RootKind`s, directly after the
`retained_chunks` loop it mirrors:

```zig
// Loaded chunks (doc 19): a `load`/`loadfile`/`dofile`/`require` chunk's
// protos are VM-owned for the VM's lifetime (`loaded_chunks` is only freed at
// deinit), so their interned constants are rooted for the VM's lifetime too —
// in BOTH walks, like `retained_chunks`: membership is deterministic guest
// behaviour, hence mode-invariant, so the `.snapshot` walk stays byte-identical
// across modes and restore preserves constant-id continuity. This makes a
// trace const over a dynamic proto ALWAYS redundant, which is what licenses
// tracing the loaded tree at all (doc 17 H-2 gate, lifted by this doc).
for (self.loaded_chunks.items) |lc| rootProtoConsts(lc.chunk.proto, ctx, cb);
```

Then delete the gates: the three anchor early-outs (`trace.zig` ~7656, ~7682,
~10469) and the `recCall` `abort(.dynamic_proto)` (~12198).

### Why this closes H-2 for dynamic protos (the argument the reviewer should attack)

1. `loaded_chunks` membership is **append-only per epoch and deterministic**:
   entries are appended exactly when guest code executes a successful
   `load*`/`require` (a deterministic event under the effect log — `file_read`
   captures *content*, so replay never consults a path), and removed only at VM
   `deinit`. So the root set added here is a pure function of deterministic
   execution → mode-invariant, exactly the `retained_chunks` argument.
2. With the loop in place, **every string constant of every dynamic proto is
   live in every mode from the moment its chunk loads until VM deinit** —
   including `.off`, which runs the same mark phase. The July divergence
   scenario (drop closure → `.off` sweeps, record-mode trace keeps) becomes
   impossible: neither mode ever sweeps it. One id timeline.
3. A trace const over a dynamic proto is therefore **always redundant** — the
   same object is independently reachable via the `loaded_chunks` root in both
   walks. This is precisely the property (doc 17 step 3) that already makes the
   static tree safe to trace; the static and dynamic trees become
   root-equivalent, so every argument that licenses tracing static code now
   covers loaded code verbatim — including the post-review static-side
   hardening (9-A depth==0 clean-entry, part-3 epoch cache clear), which was
   never dynamic-specific.
4. **Snapshot**: the `.snapshot` walk gains the same roots, so loaded-chunk
   constants serialize as ordinary live strings in every mode — snapshot bytes
   stay JIT-independent (trace consts remain excluded from `.snapshot`; they
   are now provably redundant for dynamic protos too, so the exclusion cannot
   dangle). Restore already recompiles `loaded_sources` in load order into
   byte-identical protos/ids (keyframe L-2), and under v8 the recompile is
   guaranteed **zero-allocation**: every loaded-proto constant string is in
   `objects[]` (the new `.snapshot` root), Pass 1a interns them all before
   `recompileLoadedChunks`, and interning is byte-keyed — so recompile resolves
   every constant to its restored object. The post-recompile
   `next_obj_id` check enforces this. Traces are never serialized; they re-form
   against those identical protos.

### What this deliberately does NOT rely on

- **Paths.** Replay and restore never re-read a file: `file_read` logs content
  (record) / supplies content (replay); the keyframe carries `loaded_sources`
  text. (Bart's requirement 2026-08-14: "We cannot rely on paths or anything.")
- **Closure liveness.** The root is the chunk registry, not the closure — so
  the guest dropping every reference to a loaded module's functions cannot
  affect constant liveness in any mode.
- **Trace lifetime.** Traces stay epoch-transient and unserialized; nothing new
  outlives what already outlives.

### Accepted cost

String constants of loaded chunks are retained until VM deinit even if the
guest drops the chunk entirely. Bounded and proportional: the `Chunk` (arena:
bytecode, protos, debug spans) and its full `source` text are **already**
retained for the VM's lifetime in `loaded_chunks`; the constants are a strict
subset of content we already hold. No new unbounded growth mode: one entry per
successful `load*`, exactly as today.

### Interactions checked (grounding, 2026-08-14)

- **`retained_chunks` precedent** (doc 03 §"Chunk-constant rooting", task #41):
  same helper (`rootProtoConsts`, recurses child protos), same both-walks
  mode-invariance argument, adjacent code. This design is "make the VM itself a
  retainer of what it already owns".
- **H-2 part 3** (trace cache cleared at `beginTopLevelEpoch`): unaffected.
  Traces stay within an epoch; loaded chunks persist across epochs; a re-run
  re-records against the same VM-owned protos.
- **9-A / depth==0 static sole-root** (codex's July blocker on the static
  side): that hardening is anchored in epoch/entry mechanics, not in the
  static/dynamic distinction; root-equivalence (point 3) means it now covers
  both trees on identical terms.
- **Compile→run window** (task #41's original hole): `load` appends to
  `loaded_chunks` before the closure is handed back (`stdlib/load.zig` takes
  ownership before creating the closure), so the new root covers the window in
  which the closure exists but is not yet reachable from a frame. To confirm
  under review: exact append point vs first possible safepoint.
- **`Proto.dynamic`**: no production reader remains once the gates go (§R1);
  the flag, its `compileWithOptions` option, both stamping sites, the
  `assignProtoIds` plumbing, and the restored-tree stamping test
  (keyframeser.zig ~1641) are all removed in Phase 1.

## Predictions (Phase 3 measures these)

- **P.1** scimark-lu records traces (entries > 0, aborts may now appear — the
  gate was hiding the recorder's real frontier); jit ≤ t0 at minimum, and the
  73.5× ratio drops materially. Any *remaining* gap is attributable to named
  abort reasons / nyi opcodes, each a general follow-up lever.
- **P.2** scimark-fft/sor/sparse move the same direction (same mechanism).
- **P.3** The 7 frozen stdout hashes and 3 repros are byte-identical (the
  change is liveness-only in guest-invisible directions for programs that never
  drop loaded chunks mid-heat — and the full 8/10-mode matrix pins the rest).
- **P.4** Memory board: at most proportional growth on `load`-heavy programs
  (repack is the stressor to watch); flat elsewhere.

## Testing

1. **Flip the H-2 gate tests** (they were designed as presence/absence proofs):
   hot loop in a `load`ed chunk now **records** and is byte-identical across
   all modes + restore; static-anchored trace inlining a loaded callee
   **succeeds** (no `.dynamic_proto` abort) and stays byte-identical.
2. **The July scenario as a determinism test**: `load` a chunk with a unique
   string literal in a hot loop → run hot → drop the closure → force
   collection → continue interning other strings → capture snapshot. Assert
   byte-identical output and snapshot across `.off` / record / native modes.
3. **Restore-resume**: snapshot mid-run of a require-driven program (scimark
   shape), restore, enable JIT, resume — output equivalence + traces re-form
   (extends the §R3 pattern from doc 18).
4. **Failing-allocator**: the new root loop allocates nothing (walk only), so
   no new OOM path; assert via existing `checkAllAllocationFailures` restore
   test still passing unchanged.
5. **Schema boundary (§R2)**: an explicit v7 snapshot is rejected with the
   version error; a hand-corrupted v8 snapshot missing a loaded-proto literal
   trips the post-recompile `next_obj_id` check with the defined restore error.

## §R1 — Design review round 1 (codex gpt-5.6-sol, 2026-08-14): REVISE → resolved

**Confirmed against the tree**: hazard completeness (compiler's only heap
constant is `stringConstant → internValue`, compiler.zig:361; `rootProtoConsts`
recursion matches `markProtoConstants`), mode-invariant membership (parse/
compile failures return through `loadError` *before* append; exactly two append
sites — successful runtime compile + ordered restore recompile; no removal
before deinit), snapshot ordering soundness (root-discovery order, new loop
outside the `.gc`-only block ⇒ JIT-independent), the 9-A/part-3 hardenings are
generic not dynamic-specific, and no hidden `Proto.dynamic` reader beyond the
four gates. Q1 answered YES from the tree: GC runs only at dispatch-loop
instruction boundaries (interp.zig:1858); append (load.zig:148) precedes
`newClosure` (load.zig:159) and any execution; restore likewise.

**Blocker (accepted, resolved in Phase 0)**: a *pre-change* snapshot may
legitimately omit a dropped loaded chunk's constants — restore's
missing-constant model (keyframeser.zig:551,581) recompiles and allocates them
above `next_obj_id`, so accepting such a snapshot post-change breaks
`encode(restore(s)) == s` and the allocation timeline. Resolution (Rule #8 —
no back-compat): **schema v7→v8**; pre-v8 snapshots rejected. Additionally the
restore path asserts recompile allocated nothing
(`heap.next_obj_id == kf.next_obj_id` after `recompileLoadedChunks`) — under
the v8 invariant (encoder serializes every loaded-proto constant, guaranteed by
the new `.snapshot` root) any trip is snapshot corruption, reported as a
defined restore error, never silently divergent.

**Q2 answered**: `.dynamic_proto` and `Proto.dynamic` have no remaining
production reader once the gates go — both are removed outright (Phase 1), not
tombstoned. **Q3 answered**: sweep list folded into Phase 2.

## §R2 — Design review round 2 (codex gpt-5.6-sol, 2026-08-14): APPROVE

No blockers. Verified: (a) the `next_obj_id` post-recompile check is the right
invariant — interning is byte-keyed (gc.zig:389), Pass 1a inserts every
restored string into the intern table before `recompileLoadedChunks`
(keyframeser.zig:590,645), no GC safepoint runs during restore, and non-heap
restore allocations (arenas, diagnostics, appends) don't touch `next_obj_id`;
a byte-matching string reachable via any root satisfies a constant, and any
genuinely missing bytes allocate and trip the check. (b) `Proto.dynamic`
removal is behaviourally inert (stamping only fed the lifted predicate).
(c) v7 rejection is structural — `restoreSnapshot` already rejects any
version ≠ `snapshot_format_version` (keyframeser.zig:529). Four non-blocking
cleanups (doc wording, doc 04 + version-comment sweep, §R2 boundary tests)
folded into this doc.

## References

- doc 17 §"H-2 hard half — design" (the gate this lifts) and its review chain.
- doc 03 §"Chunk-constant rooting" (`retained_chunks` precedent).
- keyframeser L-2 (`loaded_sources`, deterministic recompile).
- Bench 20260814-191341 (scimark-lu 73.5×, zero traces).
