# Design Review: doc 56 (Revision 5) — Exit-started side traces

Reviewer: independent Claude sub-agent (technical-architect), 2026-09-24.
Round 5. Receipt condensed from the review response; findings and
evidence are kept verbatim. Dispositions are in doc 56 §15.

## Part 1: Disposition of round-4 findings

- **R4-F1 (MAJOR):** RESOLVED, verified independently. `anchorKind(pc)` (`src/trace_code.zig:102-120`) returns `.cont` only for `CONT_PC_BIT`-tagged pcs and `.loop` for every other untagged pc. An exit-side trace at the raw resume pc `P` decodes as plain `.loop`, identical to a loop-done continuation. `resolvePatchPc`'s `.loop` arm scans for a back-edge targeting the anchor; a non-header `P` has none, so no patch. `noteTakenExit`'s fork (`trace_link.zig:355`) and the arm funnel's `head_parent` (`trace_link.zig:1664`) treat it like any loop-rooted trace.
- **R4-F2 (MINOR):** RESOLVED. `anchorKind(P) == .loop` takes the `.loop => hotloop` arm.
- **R4-F3 (MAJOR):** RESOLVED. §4.8's table names all four sites, gives values and reasons, and separates the two axes.

## Part 2: "exit-side trace == continuation" — verification

- **Structural equivalence — SOUND.** `maybeStartContinuation` (`trace_link.zig:216-236`) sets `rec.kind = .continuation` unconditionally and only checks the key and `!rec.active`; nothing inspects why `pending_exit_anchor` was set.
- **`continuationReachesEnclosingBackEdge` reuse — SOUND.** (`trace_link.zig:185-208`) scans forward from `start_pc` for a back-edge whose target is `<= inner_anchor`. With the parent's own anchor and `P` inside the parent's body, the scan finds the parent's back-edge. The same argument applies recursively to nested side traces.
- **`cursor.cont`/`.link_terminal`, `region_work`/`SilentSiteKind`, region classification — SOUND.** `edgeMemberOfRegion` (`trace_link.zig:944-960`) is structural; `trace_region_topology_build.zig` has zero `ArmKind`/`arm_kind` hits (apart from an unrelated `.region_bridge` stamp check). No fifth accounting site.
- **Routing double-want (attachable exit vs prime/replay side) — already foreclosed** by §4.9's precedence list.

## Part 3: New issues

### R5-F1 (MAJOR) — `pending_anchor_base`/`anchor_abs_base` is not mentioned, and has caused this exact class of bug once

`maybeStartContinuation` (`trace_link.zig:231`) seeds `anchor_abs_base` from `self.pending_anchor_base`, a separate field from `pending_exit_anchor`. It is populated at one call site, just before `onBackEdge` (`interp.zig:6314`: "Any arm inside `onBackEdge` reads it immediately; a stale value between arms is never consumed"). §4.4 sets `pending_exit_anchor` at the exit-side materialization point and never mentions `pending_anchor_base`. If omitted, `maybeStartContinuation` seeds the base from the last unrelated back-edge — possibly a different frame.

`src/trace_link_peel_test.zig:256-267` is a standing regression test for this ("Before the anchor_abs_base fix, `maybeStartContinuation` left `anchor_abs_base=0` ..."). In `recUpvalSlotAlias` (`trace_recorder.zig:4810-4920`) the guard is `if (open_idx >= self.anchor_abs_base) return self.recUpvalSlotAlias(...)`, then `rel = open_idx - anchor_abs_base; if (rel >= anchor_num_registers) abort(.aliased_input)`. Too low is fail-safe (over-aborts). Too high (e.g. a deeper callee's base) makes an aliased `open_idx` skip the alias path and be treated as an immutable outer read — a soundness hazard.

Fix: state in §4.4 what populates `pending_anchor_base` at the exit-side site (the activation base is already threaded through the native-exit result, `interp.zig:4034/4066`), and add a Phase 3 test mirroring the peel-test regression via an exit arrival.

### R5-F2 (MINOR) — the arm funnel's `head_parent` exclusion is not addressed for `ArmKind.exit_side`

`armNativeLink`'s per-kind switch (`trace_link.zig:1665-1734`) is exhaustive; every non-sibling kind refuses one-shot parents (`if (head_parent) return false;`, doc 44 D10). §4.6's validation list doesn't mention it. Likely moot (one-shot exits are diverted at `trace_link.zig:355`), but it should be stated for defense in depth.

### R5-F3 (NIT) — stale doc comments once `pending_exit_anchor` gets a second producer

`trace.zig:1565-1572` (field comment, "a hot inner loop-done exit"), `trace.zig:1589-1591` (`pending_replay_anchor`: "Unlike `pending_exit_anchor` (a *post-inner* continuation pc)"), and `interp.zig:2692-2696` (dispatch step 9) describe it in loop-done-only terms. Update alongside the implementation.

## Verdict

**APPROVE WITH CHANGES.** Revision 5's structural fix is sound at every layer checked and dissolves all round-4 findings. R5-F1 is a real omission (a missing paragraph, not a design flaw); R5-F2 and R5-F3 are completeness/hygiene items.
