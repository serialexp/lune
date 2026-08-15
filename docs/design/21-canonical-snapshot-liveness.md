# lune — Canonical snapshot liveness (the H-5(i) fix) — Design

Status: design APPROVED (codex gpt-5.6-sol round 3, 2026-08-15, after REVISE
rounds folding B-1..B-6 + M-1..M-4); Phase A LANDED — §R3 green with the full
JIT; Phase B (mid-flight masking) deliberately deferred
Owner: Bart + agents
Last updated: 2026-08-15

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items
as they land; move bullets to Done once everything inside them is checked.

### Done

- [x] **Phase A — final-state canonicalization (fixes §R3)** (2026-08-15).
      `Vm.final_cut` published by public `exec` alone on a `.finished` netting
      depth 0 (root base 0 cached-and-validated; B-6 dynamic-span raise of
      `stack_top` before publication); invalidated at the COLD boundaries
      only — `beginTopLevelEpoch`, `callValue` entry, and all three
      `protectedCall` unwind sites. `pushFrameVararg` instead ASSERTS the cut
      is already null: every execution path reaching a push starts at one of
      those cold boundaries (an exec-resume implies a suspended VM that never
      finished, so no cut exists), and the originally-landed per-push store
      measured a reproducible **13–17% tier-0 regression** on call-heavy rows
      (scimark-lu 748→880 ms, fft 685→775; interleaved quiet-machine A/B,
      3 rounds) — removing it restored parity exactly, and the debug assert
      keeps the invariant loud across the whole test matrix; validated —
      never trusted — by `encodeSnapshot`
      (depth 0, matching `stack_top`, in-bounds span, no open upvalues; any
      miss masks nothing), which computes ONE `CapturePolicy` and applies it
      to BOTH the `.snapshot` root walk (`forEachRootHeader` gained the
      `snapshot_mask` param; `.gc` asserts null) and the verbatim stack
      serialization. Keyframe v8 → v9. §T-A.2–.6 pinned
      (`keyframeser_resume_test.zig`); the doc-18 §R3 test passes UNMODIFIED
      with tracing+opt+native — full matrix 918/918 both flavors + hashgate.
- [x] **Doc sweep** (2026-08-15). Doc 04 status header + v9 note; doc 17's
      H-5(i) grounding closed with a RESOLVED pointer to this doc.

### Outstanding

- [ ] **Phase B — mid-flight statement-frontier masking (enhancement,
      separately gated).** `Proto.stmt_frontier` with max-merge collision
      rule + CFG-edge verification + release-mode fail-safe; only lands with
      its own §T-B matrix. Not needed for §R3; do not bundle with Phase A.

## Why this exists

Doc 17's hazard **H-5(i) (dead-register poisoning)** is now a measured red: the
doc-18 §R3 test (`capture→restore→resume with tracing+opt+native`) fails
deterministically at its own introducing commit (`7f803a8`). The decoded
snapshot diff isolates it completely: all 232 heap objects and `next_obj_id`
byte-identical; only dead stack slots 9–14 differ. Tier-0 rewrites dead
expression temporaries every iteration, so at final capture they hold the last
iteration's values; a native burst never materializes them (the recorder's
`locals_watermark` pruning drops never-read temps from the exit snapshot — the
φ filter in `TraceState.commit`), so the exit flush leaves pre-burst values
frozen in the slab. Both are semantically dead — but the snapshot captures the
register window **verbatim** (`encodeSnapshot` step 3) and roots the reachable
walk from it (`forEachRootHeader`, the `0..stack_top` loop), so the bytes
diverge and, in the worst case, the *reachable set* could diverge (a dead slot
holding the only reference to garbage in one tier and not the other).

Three fixes were on the table (CURRENT_TASK LATEST-65). Chosen: **(b) mask
dead slots to a canonical value at capture, in both tiers**, because (a)
(forcing the JIT to materialize dead values) taxes the hot loop always for
semantically meaningless data and re-breaks under any future dead-store
optimization, and (c) (logical comparison) leaks liveness knowledge into every
snapshot consumer and downgrades the cheap hash-compare replay check. Masking
makes the snapshot a **pure function of the program's logical state**: dead
bytes are canonicalized at the one place snapshots are born, and every tier
keeps full freedom to prune.

**Codex round-1 restructuring.** The first draft derived the final-state mask
from a compiler statement-frontier table. Review showed that is both unsound
in corners (B-1: a depth-0 `callValue` boundary pop is indistinguishable from
the genuine top-level finish by depth alone; B-2: the same-pc stamp-collision
"stamps are equal" argument is false — `repeat` reserves its condition
register without emitting an instruction, so an outer-statement stamp and the
first body-statement stamp can collide at one pc with different values) and
**weaker than necessary** at the final state (B-3: a static frontier preserves
all locals below the result base, so any future JIT that stops writing back
dead *locals* — not just temps — recreates the divergence; and `all_results`
returns defeated the static stamp entirely). The fix is to split the design:

- **Phase A** uses the *runtime* result span, known exactly at the top-level
  pop (including `all_results` — the dynamic count is concrete by then), and
  canonicalizes **every** final stack slot outside it. No compiler metadata,
  strictly stronger guarantee, and it is the phase that heals §R3.
- **Phase B** (mid-flight statement-boundary masking) is a genuine
  enhancement with no current pin depending on it; it keeps the frontier
  design but must land separately with the collision rule fixed and its own
  fail-safes.

## Phase A — final-state canonicalization

### The invariant

At a **genuine top-level finish** (a `run`/`start`/`exec` that nets
`depth == 0`), the only live stack content is the returned result span
`[result_base, result_base + result_count)` — the `.ret`/`.halt` arm
deliberately leaves `stack_top` covering the popped window *only* so those
results stay GC-rooted until the host copies them out. Every other slot —
dead temps *and* dead locals — is semantic garbage. So the canonical final
capture rule is:

> At `depth == 0` with a valid `final_cut`, a stack slot is captured (and
> walked) iff it lies inside the recorded result span. Everything else
> serializes as `nil` and seeds nothing.

This is a pure function of the program's logical result, independent of which
tier produced the state and robust against *any* pruning the JIT does now or
later (the codex B-3 point: a static locals-frontier would not be).

### `Vm.final_cut`

```zig
/// Absolute description of the only live stack content after a genuine
/// top-level finish. Captured by the public finish paths; validated (not
/// trusted) at snapshot capture; invalidated by anything that reuses the
/// stack.
final_cut: ?struct {
    result_base: u32,   // absolute stack index of result 0
    result_count: u32,  // runtime count (all_results resolved)
    stack_top: u32,     // the stack_top this description is valid for
} = null,
```

- **Set** at exactly ONE site: public `exec` (which `run`/`start` already
  route through), on a `.finished` outcome that nets `depth == 0` — NOT
  inside the `.ret` arm's `stop_depth` pop, which cannot distinguish the top
  level from a reentrant depth-0 `callValue` boundary (codex B-1: `callValue`
  at entry depth 0 also pops to `stop_depth == 1`, and its callee window sits
  above the *saved* `stack_top` which `callValue` then restores — a frontier
  recorded there would describe the callee window while capture applied it to
  the root window; `callValue` uses private `execWith`, preserving the
  boundary distinction). The popped root frame's base is 0 by construction —
  `run`/`start` push at base 0 and restore enforces `frames[0].base == 0`
  (the F2c `FrameWindowMismatch` pin) — and `FrameResult.reg` is
  frame-relative, so `result_base = fr.reg` directly; defensively, public
  `exec` caches-and-validates `frames[0].base == 0` before `execWith` and
  declines to publish on mismatch (codex round-2 adjudication: do NOT read
  the popped frame's stale storage).
- **Dynamic spans can exceed the static window** (codex B-6): `stack_top`
  after the pop covers `base + proto.num_registers`, but a top-level
  `return f()` (`all_results`) resolves its count from the dynamic `reg_top`,
  so `result_base + result_count > stack_top` is possible — and
  `encodeSnapshot` serializes only `stack[0..stack_top]`, which would DROP
  the surplus results entirely (a pre-existing capture gap, not just a mask
  problem). At publication: checked-compute `result_end`, validate against
  register capacity, then **raise `vm.stack_top = max(stack_top,
  result_end)` before publishing** `final_cut` (with the raised value
  recorded in the cut), so every returned value is genuinely rooted and
  capturable — the "exact runtime result span" promise made real.
- **Invalidated** (`= null`) at: `pushFrame`, `beginTopLevelEpoch`,
  `callValue` entry, and the `protectedCall` manual unwind (errors.zig) —
  i.e. anything that pushes frames or rewinds/reuses the stack after a
  finish. Belt-and-braces: capture *validates* rather than trusts.
- **Validated at capture**: the mask applies only when `vm.depth == 0` AND
  `final_cut != null` AND `final_cut.stack_top == vm.stack_top` AND the span
  is in-bounds (`result_base + result_count <= stack_top`). Any mismatch →
  **mask nothing** (fail-safe direction, codex B-4/M-2 spirit: bad or stale
  metadata must degrade to today's behaviour, never to silently nil'd live
  data).

### Capture policy (codex M-4)

`encodeSnapshot` computes one immutable `CapturePolicy` up front —
`mask: ?struct { from: usize, span_base: usize, span_len: usize }` — and
passes it explicitly to both consumers; neither re-derives VM state:

1. **Root walk**: the `.snapshot` walk's `0..stack_top` register loop skips
   slots outside the result span when the policy masks (`.gc` walk untouched
   — the collector's view of liveness is not the snapshot's business, and the
   doc-17 H-2 `{gc, snapshot}` split is the ready-made seam). A heap object
   whose only reference is a dead slot is semantic garbage; excluding it
   makes the reachable *set* — not just the stack bytes — a function of
   logical state.
2. **Verbatim stack capture**: slots outside the span serialize as canonical
   `nil`.

Open upvalues: at `depth == 0` all upvalues are closed
(`closeUpvaluesFrom(base)` runs before every pop), so
`vm.open_upvalues.items.len == 0` whenever the Phase-A mask applies — assert
it in debug; in release, a non-empty list at depth 0 disables the mask
(fail-safe, codex B-4).

### Wire-format identity (codex B-5)

Masking changes the canonical encoding of the same logical state, so the
keyframe **version bumps** (v8 → v9). No structural schema change — the bump
exists so two encoders can never emit different bytes under one version
number for the same state (the identity contract), and Rule #8 says we owe no
decode path for v8. Doc 04 gets the note.

### Restore

No change. Masked slots decode as nil like any other nil. A restored final
state resumes into nothing (depth 0, program finished) — the span-preserved
results remain available to the host exactly as today.

## Phase B — mid-flight statement-frontier masking (separate enhancement)

No current pin needs cross-tier mid-flight byte-identity (suspend cuts aren't
even aligned across tiers — safepoint counts differ), so this phase is
optional hardening, kept in the doc because the grounding is done. It must
NOT ride along with Phase A. Requirements folded from codex round 1:

- `Proto.stmt_frontier: []const u16`, `len == code.len`, sentinel
  `maxInt(u16)`; stamped at statement boundaries in `compileBlock` plus loop
  headers/branch joins **only after per-form verification**.
- **Collision rule is `max(existing, new)`** — a larger suffix start masks
  less (codex B-2: the "colliding stamps are equal" claim is false; `repeat`
  reserves its condition register with no instruction emitted, so an
  outer-statement stamp and a first-body-statement stamp can share a pc with
  different values). Every stamped pc must be proven safe for **every
  incoming CFG edge**, not just lexical fallthrough — compiler tests per
  form: empty/nested `do`, `repeat`, all loop forms, empty branches, `break`,
  short-circuit patch targets coinciding with the next statement.
- Mask applies to the **topmost frame only**: `top.base + frontier[top.pc]`
  when stamped, else nothing. Suspended callers rest with `pc` one past
  their call instruction (codex M-1) — mid-statement, sentinel — so caller
  windows, callee windows, and sub-`base` vararg regions are structurally
  unreachable by the mask.
- **Release-mode fail-safes** (codex B-4/M-2): bounds-check `pc` against the
  metadata slice (hand-built protos may carry an empty one),
  `base + frontier <= stack_top`, and any open upvalue with
  `stack_index >= mask_start` disables the mask for that capture (debug
  builds also assert — upvalues capture named locals, never temps, so a
  violation means the stamp or the invariant broke and we want the alarm).
- `reg_top_pending` is required-null at any suspend safepoint (existing
  invariant), so no dynamic multret span can be live above a frontier at a
  masked capture.

## Interactions checked

- **GC**: unaffected (`.gc` walk unmasked); the collector keeps dead-slot
  referents alive exactly as today, and the snapshot no longer looks at them.
- **Recorder/JIT**: zero changes. `locals_watermark` pruning stays as-is; the
  design makes the snapshot robust against any current or future dead-store
  pruning, which is the point of choosing (b).
- **`interp_determinism_test`** (8-mode final-snapshot equivalence): the mask
  is a pure function of `(FrameResult, stack_top)` at a deterministic program
  point — no clock, address, or tier-dependent input (codex adjudicated all
  8 modes conditional on the B-fixes; safepoint-lines / exec-log observation
  modes suppress native execution and add no mask input). Modes that agreed
  before still agree; modes that disagreed only in dead bytes now agree.
- **Effect / exec / coverage serializers**: untouched (none serialize the
  register window; codex confirmed no other capture-visible divergence
  channel from the watermark pruning — frames empty, upvalues closed at the
  final state).
- **`callValue` / metamethod reentry**: armed suspension is prohibited there
  today, so no capturable host-boundary state exists mid-`callValue`; the
  Phase-A validation (`stack_top` match + invalidation set) covers the
  before/after states.

## §T — test matrix

### §T-A (Phase A, mandatory)

1. **§R3 goes green unmodified** — the gate (doc 17: "a concrete bug the
   mandatory native-F2c test must catch"; the test was right, the capture was
   incomplete).
2. **Cross-tier final byte-identity, minimized**: the g-loop reduction from
   the §R3 repro — pure tier-0 final snapshot == JIT-run final snapshot,
   byte compare.
3. **Result-span preservation**: top-level `return <table>` — the returned
   object survives the walk and the span slots serialize verbatim; a dead
   local holding the only other reference to a second table → that table
   absent from the snapshot, present in a `.gc` walk (split intact).
4. **`all_results` finish**: top-level `return f()` with a multi-value `f` —
   runtime span recorded, all results preserved, everything else masked;
   include the B-6 shape (more results than the root's static window —
   `stack_top` raised at publication, surplus results captured, previously
   silently dropped).
5. **Depth-0 `callValue` does NOT stamp** (codex B-1 shape): host calls a
   guest function at depth 0 after a finished run — capture after the
   `callValue` masks nothing stale (validation catches the restored
   `stack_top`); also the callable-table/metamethod dispatch variant.
6. **`pcall`/`xpcall` unwind** (codex M-3): successful and failing protected
   calls followed by top-level finish — `final_cut` reflects the finish, not
   the unwind.
7. **Same-cut identity preserved**: the existing "independent VMs suspended
   at the same cut" pin stays green (mid-flight captures are untouched by
   Phase A).
8. **Version**: encoder emits v9; the §R3 corpus round-trips.

### §T-B (Phase B, when/if it lands)

Per-form stamp-collision tests (codex B-2 list), the open-upvalue fail-safe,
mask-vs-locals boundary at a mid-loop statement cut, restore+resume output
identity from a masked mid-flight snapshot.

## References

- Doc 17 — H-5 grounding (H-5(i) dead-temporary omission), the
  `{gc, snapshot}` root-walk split (H-2), the native-F2c mandate.
- Doc 18 §R4 — the §R3 test's introduction (`7f803a8`).
- Doc 04 — snapshot/replay schema (gains the canonical-final-state note +
  version bump).
- `compiler.zig` header — the statement-boundary invariant Phase B would
  promote to a serialized artifact.
- CURRENT_TASK LATEST-65/66 — the bisect, the decoded diff, the option call.
- Codex gpt-5.6-sol rounds 1–2 (2026-08-15): REVISE B-1..B-5 + M-1..M-4,
  then REVISE B-6 (dynamic `all_results` span past `stack_top` + the
  pre-existing surplus-result capture drop) + the root-base adjudication —
  all folded above.
