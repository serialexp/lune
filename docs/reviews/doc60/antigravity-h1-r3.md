# Doc 60 H1 implementation review, round 3 — antigravity

Reviewer: antigravity (`mcp__antigravity__delegate`, tools allowed,
read-only brief), 2026-10-03. Input: `/tmp/h1-r3.diff`, both round-2
reviews, doc 60 §10. Disposition: doc 60 §10.

---

VERDICT: APPROVE

Round 3 cleanly and completely resolves all outstanding findings from Round 2 (Codex 1–4 and Antigravity 1). The changes were verified directly in the code, test suite, and design documentation.

### Verification of Round 2 Resolutions

1. **Codex Finding 1 (Closure & anchor identity)**: Resolved in src/capi_hostcall_test.zig:101-130, :178-193, :199-203, and :795-816.
   - Protos are assigned monotonic first-seen ordinals (`P{d}`) within a snapshot via `Dump.ids`, printing `P{d}:{name}#{id}` on first sight and `P{d}` on subsequent sightings. Closures (`cl.proto`), anchors (`a.proto`), pending call/ret anchors, and `frame0` all route through `Dump.proto`. Because `Proto.id` is unique only per chunk rather than per VM, first-seen ordinals correctly distinguish same-named, same-id closures from distinct chunks while preserving deterministic cross-leg comparability.
   - The snapshot self-test proves that swapping two anonymous closures sharing an upvalue changes the snapshot text (`expectRenderDiffers`).

2. **Codex Finding 2 (Recording constants compared by value)**: Resolved in src/capi_hostcall_test.zig:290-295 and :818-832.
   - In `snap()`, active recordings dump every constant value in `rec.consts.items` via `d.val(cv)`.
   - The snapshot self-test opens an owned recording, appends `Value.int(5)`, asserts the rendered text contains `"consts: int:5"`, changes the constant to `Value.int(6)`, and verifies that `expectRenderDiffers` detects the difference.

3. **Codex Finding 3 (Grid rendering & row-view parent identity)**: Resolved in src/capi_hostcall_test.zig:111-117, :148-162, :834-856, and :1129-1168.
   - `Dump.obj` checks `t.array.isGrid()`. If true, it non-mutatingly renders `grid rows={d} stride={d}`, row lengths `a.gridRowLen(r)`, and all cells `0..a.stride` via `a.gridGet(r, c)`. Non-grid tables iterate `0..t.array.asize` via `t.array.get(i)`.
   - Row views (`.row_view`) render `row[` + parent grid identity via `self.obj(Value.heap(v.rowViewParent()))` + `]#{d}` with `v.rowViewRow()`.
   - The snapshot self-test verifies cell value rendering, mutation detection, and row-view parent identity (`"row[h"`, `"grid rows=2"`).
   - The fresh-tables scenario invokes `gridpeek` before any bare `g[i]` access (which deflates grids to row tables in tier-0 `indexGet`) and asserts `peeks[0].snaps.items[6].text` observed `"grid rows=2"`.

4. **Codex Finding 4 (Record/replay coverage claims)**: Resolved in docs/design/60-hand-written-machine-code.md:1097-1101 and :1155-1158.
   - §6.1 and §6.2 now accurately state that differential tests run across the three active tiers (JIT off, tier-1 interpreter, native), while record/replay legs wait on embedding record/replay capabilities and remain on the Outstanding checklist.

5. **Antigravity Finding 1 (Nit: Parenthesized mask in `assertTraceBitsInSync`)**: Resolved in src/trace.zig:3080.
   - `(self.fast_block & FastBit.trace_owned) == self.traceFastBits()` is now explicitly parenthesized.

### Test Execution & Soundness Checks
- `just test`: PASSED (all unit tests, dependency boundary checks, and C-API smoke test green).
- `zig build test -Dtest-filter="hostcall diff" -Dtest-filter="snapshot self-test"`: PASSED (all 18 scenario tests and the snapshot self-test pass with zero leaks under `std.testing.allocator`).
