# JIT ownership — Design

Status: ownership extractions implemented — registry, region policy and recording session; final arc-wide verification and follow-up architecture work remain
Owner: Bart
Last updated: 2026-09-05

## Implementation status

### Done

- [x] **Baseline.** `just test` passed before source changes.
- [x] **Pure IR semantics boundary.** `ir_eval.zig` owns arithmetic evaluation; optimizer production code imports IR vocabulary and evaluation rather than interpreter/lifecycle. The execution differential test retains test-local runtime imports.
- [x] **Shared execution contract.** `trace_exec.zig` owns result/exit/ledger types, sentinel and capacity. Both executors and lifecycle consumers import it directly; irinterp has no compatibility reexports. Native transport layout and decoding remain nativegen-owned. Default/ordinal tests and `just test` passed.

- [x] **Entry-patch physical owner.** `EntryRegistry` owns VM-local images, stable slots, generation and dirty/free storage, publication, restore and allocation teardown without a coordinator reference. Qualification and ordered drain remain coordinator policy. Owner tests cover publication, dead-record retirement, slot reuse and OOM refusal; existing entry-patch integration tests pass.

- [x] **Native physical owner.** Link publication, promotion patch/restore, disarm, deferred demotions and physical teardown now belong to `NativePhysicalRegistry`; policy consumes outcomes without registry callbacks. Existing promotion/retirement tests plus direct barrier/invalidation tests pass.

- [x] **TraceRegistry.** Composes both physical owners and owns cache, ID lookup/allocation, generation, arena and stable seed context. Publication transfers ownership only on success; retirement disables entry dispatch and disarms before freeing; clear is self-contained and drops borrowed candidate references. No coordinator reference or policy callbacks.
- [x] **Native owner API hardening.** Const topology views, guarded memo updates and ownership-taking candidate observation replace policy writes. Targeted destructive mutation requires a safe window; last-row convergence remains supported. Five physical diagnostics restored with synchronized runtime and compile-time gates.

- [x] **RegionPolicy.** Owns region storage, staged topology publication, normalized receipt consumption, window/lifecycle and observer decisions. Coordinator applies bounded physical/gate effects synchronously; policy has no coordinator/registry callbacks. Tests cover exclusive consumption, selection ordering and activation-map OOM invalidation.
- [x] **RecordingSession.** Owns emission scratch, abort notices, reset, peel/close and candidate finalization without lifecycle/backend imports. Candidate publication is separate; failure keeps ownership local. Tests cover snapshot consumption, independent candidate lifetime, inactive terminal behavior, reset OOM and finalizer allocation failures. Production helpers replace duplicate verifier/remap paths.

### Outstanding

- [ ] **TraceCode/TraceRecord verification.** Embedded code and record separation, teardown/borrow/const-interface tests and direct consumer checks implemented. Full phase review remains before closing phase 1; executor transitive runtime isolation belongs to the stdlib capability arc.
- [ ] **Boundary verification.** Dependency checks, production-native differential coverage, full hashgate and artifact comparisons.
- [ ] **Follow-up architecture arcs.** Runtime, replay, IR hardening, program lifetime and visualizer scope tracked in TODO.md.

## Decision and scope

Begin with the JIT sequence Bart selected: shared trace/execution contracts → registry/link ownership → region policy → recording lifecycle. This is an ownership/dependency refactor, not another file-size exercise. Track the runtime, replay, compiler-hardening and UI follow-ups explicitly so starting with JIT does not lose the rest of the review.

Existing local changes in gc.zig, wasm_entry.zig, viz/src/diff.ts and viz/test/keyframe-sans-arg.test.ts are not ours. Do not edit those regions or reconcile them. No commits or production actions are required by this plan.

## Evidence and target boundaries

`Trace` (trace.zig:673–900) combines committed instructions/constants with mutable native pages, patches, counters and memos. tropt, irinterp and nativegen import the lifecycle module that imports them back. Operational slices all borrow unrestricted TraceState. Region operations mutate armed links, while retirement calls region rebuilding. Recorder owns emission scratch but not abort/close/publication. These are the boundaries to replace.

Target composition:

- Leaf IR and identities: existing trace_ir/trace_types, plus shared trace-code and execution contracts.
- TraceCode: immutable-after-publication instructions, constants, entry contract and provenance. Own allocation cleanup at the artifact boundary; readers borrow const views.
- TraceRecord: stable-ID cache entry composing code and mutable execution/deployment state. No redundant copied IR arrays or per-entry indirection unless lifetime requirements demand it.
- TraceRegistry: owns cache/ID lookup, native pages/arena, armed links, patches, retirement and protected mutation windows. Public operations preserve publication/retirement invariants; callers cannot finish a transaction by editing registry rows themselves.
- RegionPolicy: owns logical regions, physical indices, observer caches and region accounting; consumes deterministic receipts and read-only topology, returns bounded decisions for the coordinator.
- RecordingSession: owns emission, reset/abort/finalize scratch; returns a candidate for registry publication. Optimizing/finalizing a candidate is distinct from making it executable.
- TraceState becomes the coordinator composing these owners, not a cross-module method namespace. Direct calls remain direct; no virtual execution interface, event bus or heap-allocated action per receipt.

### Dependency direction

```text
recording session ── candidate ──> coordinator ── publish ──> registry
                                      │                       │
                               receipt / topology       owns runtime records
                                      ▼                       │
                                 region policy                ▼
                                      │                  immutable TraceCode
                              bounded decisions               ▲
                                      │                       │
                                      └── coordinator    optimizer / executors
                                                              │
                                                   IR + evaluation + execution contract
```

Dependencies describe authority, not necessarily separate allocations. A code
artifact may be embedded in a stable runtime record; readers receive a const
borrow and cannot reach deployment state through that borrow. Native machine
code may retain pointers into artifact-owned arrays only while the registry
keeps the artifact alive. Destroy deployment state before releasing those arrays.
The shared execution contract describes results; it does not select tiers,
interpret receipts, allocate ledgers, or own native transport layout.

### Ownership acceptance criteria

| Component | Owns | Must not do |
|---|---|---|
| IR/evaluation | Operand vocabulary and pure arithmetic semantics | Import lifecycle or execute a trace |
| Execution contract | Exit reasons, semantic results, ledger vocabulary | Depend on either executor implementation |
| TraceCode | Committed code and entry/exit contracts | Own a machine-code page or mutate tiering counters |
| Registry | Publication, patch records, executable lifetime, retirement | Call region-policy methods during mutation |
| Region policy | Region topology interpretation, accounting, observers | Edit armed-link rows or executable slots |
| Recording session | Scratch and candidate finalization | Publish partially initialized executable state |
| Coordinator | Ordering of component operations | Become the storage owner for extracted components |

## Implementation phases

### Phase 0 — record contracts and baseline

Create docs/design/41-jit-ownership.md with status/Done/Outstanding checklist, ownership table, dependency diagram, pointer lifetime/publication rules, failure semantics and staged acceptance criteria. Record the full follow-up roadmap in TODO.md and CURRENT_TASK.md without overwriting unrelated notes. Read existing documentation before edits.

Run `just test` before source changes. Record any baseline failures as blockers rather than attributing them to the refactor. Inspect pinned stdlib source before introducing or changing uses of its APIs. Load hot-loop-allocations skill before hot-path implementation/review.

### Phase 1 — actual shared contracts and compiler dependency direction

Extract pure IR evaluation from irinterp into a leaf; optimizer depends on trace_ir and that evaluator, not interpreter/lifecycle. Extract shared semantic execution result/ledger types from irinterp; retain native's layout-pinned extern transport with explicit conversion. Update repository callers directly: backwards compatibility is not a requirement.

Define TraceCode and immutable entry types outside lifecycle/backend modules. Classify every existing Trace field by semantic code, static derived metadata, or mutable runtime state before moving it. Convert compiler/executor/serializer read-only consumers to this contract, with native identity/context passed explicitly. Keep artifact arrays and embedded native pointers stable. Do not call this phase complete while consumers still import trace.zig for their production types.

Add boundary tests and focused evaluator/result conversion tests. Extend existing differential tests to compare the documented semantic exit result and exercise the production arena/frameless path, rather than relying only on self-framed test code.

For an unlinked differential run, compare IR completed guest iterations to native
`local_completed`, not native's raw cumulative `completed` (peeled traces differ
by the run-once iteration). Compare exit instruction only for normal native
exits. A native hoisted-prologue refusal instead requires zero progress and
unchanged/equal register state: tier-1a reports its concrete guard instruction,
not the native refusal sentinel. Reject seed-decline cases from the generic
unseeded helper; test them with their explicit seeding contract. Provenance,
ledger length and silent-chain transport fields are not whole-struct equality
candidates across tiers. Duplicate register slabs do not clone heap objects:
mutating traces require independent heaps and must not enter the shared read-only
helper. Run one production-native execution, not standalone and frameless runs
against the same heap. Keep a focused standalone-page smoke test separately.

#### Trace field partition and native-pointer audit

Embed `TraceCode` by value in the existing heap-allocated record: one allocation,
no extra pointer chase to acquire the artifact. Its stable address is
`&record.code`; that address must remain valid until native teardown finishes.

- Code facts: `anchor`, `unrolled_while`, `peeled`, `instrs`, `consts`,
  `entry_slots`, `inputs`, `exit_prov`/completeness and `rec_path`/completeness.
- Static derived metadata: `entry_guards`, `alloc_bound`, Unicode-pin requirement,
  and bridge-candidate bitset/completeness. Nonserialized does not mean mutable.
- Record identity: `id`, explicitly supplied to native compilation (not a compiler
  dependency on the cache record).
- Mutable record state: native compilation, entry patching, hit/refusal counters,
  bridge decline memo, anchor population/loop-done memos, exit hotness, sibling
  handoff state and region membership memo.

`provAt` and `matchesFingerprint` move with code. The bridge-candidate fallback
must use shared static classification, not import nativegen back into code.
`TraceCode.deinit` frees artifact arrays; record destruction first releases native
state, then code and mutable exit counters, then the record allocation.

Native seeding currently bakes both the trace pointer and a separately stable
`NativeSeedCtx` pointer. Its callback changes to a code pointer; the context stays
stable and outlives pages. The seed-plan bitmap continues to travel by value:
`CompiledTrace` itself is movable, so no pointer to its embedded plan may be baked.
Heap callout pointers, link-slot addresses, executable entry addresses and exit
metadata cells retain their existing lifetimes. Retirement must reset inbound
links before freeing any of them. `InputSeed` and seed callback types need leaf
contracts so moving TraceCode does not recreate the cycle through those types.

Serializer mapping accepts code, not a runtime record. Cache-to-code adaptation
belongs to the caller or an explicit borrowed collection view; do not smuggle a
record dependency into the codec via a generic function reading `.code`.

### Phase 2 — registry and native mutation ownership

**Implementation note:** `trace_record.zig` now owns the mutable record type and
its native-before-code teardown, independent of a direct coordinator import.
The complete `trace_link.ArmRequest` accepts region proof identity/generation;
region policy no longer edits the row after arming. Tests pin metadata refresh
on identical re-arms and invalid proof/kind rejection. Entry-patch storage and
physical operations now belong to `trace_entry_registry.EntryRegistry`, composed
by TraceState. `NativePhysicalRegistry` now owns armed links, live promotions,
exit ownership, candidate storage and deferred demotion/disarm state. Physical
operations borrow the arena explicitly, with no coordinator/policy callbacks;
arm outcomes and a consumed invalidation flag drive coordinator policy. Teardown
now restores/disarms before records and arena die. Cache publication/retirement
orchestration and region policy are still outside, so phase 2 remains partial.

Review found no demonstrated extraction regression in production paths. The
existing replay rule is preserved, not strengthened to a blanket mutation ban:
last-row convergence still arms during replay; targeted retirement/disarm rely
on safe-call-site preconditions. `clearCache` still requires prior disarm.
Region bridge replay memos are now cleared when an identical physical re-arm
changes proof identity or generation, including same-generation identity changes.
Some physical arm/reset/disarm debug messages were removed; counters remain.
Follow-up: diagnostics are restored and synchronized at coordinator boundaries;
policy reads const link views and requests guarded memo updates. Candidate
storage/streak updates are owner operations. Targeted destructive mutations
now enforce safe-window preconditions in release builds.

Verification after entry-owner integration: `just test`, `zig build wasm`, and
`just hashgate` passed (84 digests per Debug/ReleaseFast leg). After adding two
focused owner tests, `just test` passed again. Direct `zig test` of the owner is
not a supported standalone invocation because its record/backend dependency
requires the build-provided `build_options` module; use the build test target.

Move registry fields and their allocation lifecycle together. Consolidate prepare/commit mutation, arming/disarming, protected-ledger deferral, entry patching, lookup and retirement. Registry returns topology-change results; coordinator updates region policy at the existing deterministic safe points. Region bridge requests include complete metadata so callers never patch armed-link rows afterward.

Tests cover failed publication/allocation, duplicate arm, stale generation, inbound/outbound retirement, deferred mutation during ledger validation, safe-window disarming and destruction order. Preserve fail-closed behavior and counter/event order.

The first cohesive registry slice may own physical mutation before cache
publication moves, but must already remove region callbacks and unrestricted
TraceState access. Move link rows, slot mutation, physical promotion ownership,
and protected-window state together. A complete arm request includes parent,
exit, child, patch kind and region identity/generation; region code must not
search and amend the published row afterward. Return unchanged/declined/change
results; coordinator interprets membership changes and requests demotion.

**Extraction sequencing:** first isolate entry images and stable patch slots in an
`EntryRegistry`, keeping eligibility and deterministic drain scheduling outside.
The next cohesive owner is native links plus live promotion ownership and the
replay mutation barrier: armed rows, promoted sets/exit ownership, deferred
demotions and pending disarm must move together. Region membership validation,
candidate profitability and pending bridge requests remain policy. Physical
operations return change/invalidation outcomes rather than calling region
methods or setting coordinator provenance flags. Pass the arena explicitly;
never retain a pointer into the movable coordinator. Use the existing lower-level
`TraceRecord` type rather than introducing a generic owner to hide a dependency.

Preserve the settle order: restore deferred promoted reporting patches, apply
pending disarm, apply provenance verdicts, drain pending bridge arm, then drain
provenance arms. A condemning disarm cancels pending bridge arm before any drain.
Entry-patch drains unpatch first, then install in stable trace-ID order. Registry
teardown owns demotion/disarm rather than requiring a caller to do it; drop entry
patches/images before records, records before arena, and seed context last.

### Phase 3 — region policy composition

Define one normalized receipt contract without collapsing distinctions required by native/IR execution. Move region-owned maps, generations, observers and lifecycle into RegionPolicy. Read topology through registry views and return inline/bounded decisions applied by the coordinator. Exactly one accounting owner consumes each receipt. No callbacks from registry into policy.

Tests cover exclusive accounting, generation invalidation, activation boundaries, fail-closed OOM rebuilds, deterministic decision order, and no mutation mid-ledger. Preserve existing observer fast-path invalidation funnels.

### Phase 4 — recording lifecycle composition

Move abort/reset/finalize with recorder state. Finalization returns a candidate with explicit ownership; registry publication is a separate commit step. Ensure abort, peel, side-trace and failed finalization release every owned allocation and maintain trace/proto identity semantics. Remove remaining cross-slice TraceState forwarding patterns for migrated responsibilities.

Gate with recording, peel, linking, provenance, replay and allocator-failure tests; review init/deinit and GC root traversal against the new ownership tree.

### Phase 5 — close the JIT arc

Recheck imports, full mutable-state access, native pointer lifetime, failure paths and test registration after implementation, not only before it. Run full tests/hashgate and artifact equivalence checks. Run benchmarks through `just bench`; performance claims require profiling and `--jit-stats` when coverage/residency is implicated. Do not regenerate expected artifacts merely to make a gate pass. Keep docs/checklists and CURRENT_TASK current, explicitly recording outstanding phases at any stopping point.

## Invariants and trade-offs

- Preserve stable trace IDs and borrowed proto lifetimes, raw value bits, IR/wire ordinals, GC rooting and deterministic root order. This change does not request a wire version change.
- Native code must never retain pointers to moved/freed arrays or runtime contexts. Audit pointer capture before deciding nested vs separately allocated storage.
- Publish registry metadata before publishing a native jump when allocation can fail. Reset inbound/outbound links before freeing code. Do not mutate the armed-link registry while validating a ledger.
- Preserve deterministic gates, receipt order, accounting and fail-closed region behavior. Do not change retry/profitability policies incidentally.
- Small phase transitions may use adapters, but each phase must terminate in a real dependency/ownership boundary; no permanent compatibility facade or forwarding-only endpoint.
- No speculative backend framework or dynamic dispatch. Do not promise a speedup; measure regression risk.

## Tracked follow-up arcs (not silently dropped)

1. Canonical IR operand roles/reference traversal, release-safe validation at publication/trust boundaries, precise native compile declines, fallible assembler finalization. Structural validation can accompany Phase 1 where needed; changes to retry policy remain separately designed.
2. Runtime-owned protected invocation/unwinding and loaded-program ownership; narrow stdlib runtime capabilities and eliminate representation-level cycles.
3. EffectSession ownership and atomic replay attachment; runtime snapshot capture/RestoreBuilder separate from codecs; investigate non-mutating canonical grid projection.
4. Program-image retention/lifetime API and shared CLI/wasm Runner; stable-address runtime storage distinct from collector mechanism.
5. Visualizer session/artifact ownership and injected execution clients, retaining Solid stores; assess stale async result handling with focused tests.
6. Native registry uniqueness/restore validation without assuming backwards compatibility requirements.

These are tracked work, not implemented by documentation. Before each follow-up, inspect the then-current code and user scope rather than executing stale recommendations mechanically.

## Verification

Every implementation phase: focused automated tests plus `just test`. Major execution/link boundaries: `just hashgate` (ReleaseFast and Debug), native-vs-IR semantic differential tests, GC stress and existing all-mode replay/artifact tests. Add dependency checks scoped to production imports (test imports must not produce false positives). Use pinned stdlib sources, allocator injection and leak-checked teardown throughout. Report actual commands/results and any remaining work without proclaiming success.

### Registry extraction completion verification

`TraceRegistry` now composes both physical owners. The coordinator retains logical
region/provenance policy and deterministic notification ordering, not cache/native
allocation ownership. Registry tests cover publication failure, optional-index OOM
fallback, monotonic identities, swap-removal order and candidate cleanup on clear.
Native tests cover candidate ownership and exact proof-keyed memo updates. Final
`just test` passes (14 dependency tests); wasm and both 84-digest hashgate legs
pass. No benchmark rerun or commit. RegionPolicy/RecordingSession remain separate
outstanding phases; registry extraction does not claim the entire JIT arc complete.

### Region and recording extraction verification

Region rebuilding now consumes immutable topology facts and returns owned staging;
policy reserves before the coordinator demotes, then publishes infallibly. Receipt
selection/window/lifecycle and observer departure decisions are policy-owned;
coordinator iteration preserves close/flush effects before subsequent activation.
Epoch teardown uses policy APIs, not external map destruction.

RecordingSession receives instruction-scoped heap/inner-loop facts, never a VM or
registry reference. Abort handling uses captured notices exclusively; peel notices
restore coordinator diagnostics. Inactive sessions reject record/close/finalize;
reset clears context and allocates replacement register storage before releasing
old storage. Candidate code remains independent across reset/deinit and transfers
only after successful publication. Side provenance is passed explicitly instead
of resurrecting terminal session state.

Final combined `just test` passed (15 Python boundary tests plus Zig suites),
`zig build wasm` passed, and Debug/ReleaseFast hashgate each matched 84 digests.
`git diff --check` passed. No benchmark rerun or commit. Full artifact/performance
arc closure remains tracked separately; these results complete the two requested
ownership extractions, not the later runtime/replay/UI architecture arcs.
