# Design Review: doc 56 (Revision 4) — Exit-started side traces

Reviewer: independent Claude sub-agent (technical-architect), 2026-09-24.
Round 4 (follow-up to its round 3). Receipt condensed from the review
response; findings and evidence are kept verbatim. Dispositions are in
doc 56 §14.

## Part 1: Disposition of round-3 findings

- **Finding 1 (BLOCKER, loop-done store helpers):** RESOLVED. §4.3 uses an ordinal filter over the trailing store block; §4.6 reuses only the leaf emitters.
- **Finding 2 (MAJOR, ±2GB cell region):** RESOLVED. Absolute `mov rax, imm64` load, same pattern as `emitPreciseSnapshotFlush` (`src/nativegen.zig:~664`); `ALLOC_ORDER` (`src/nativegen_alloc.zig:180`) excludes `rax`/`rcx`.
- **Finding 3 (MAJOR, `.link_terminal` topology):** RESOLVED, with a residual gap carried forward as R4-F3.
- **Finding 4 (MINOR, arm-time re-proof):** RESOLVED.
- **Finding 5 (NIT, ordinal justification):** RESOLVED.
- **Unverified item (exit counters once per tier):** PARTIAL — converted into a Phase 3 test commitment.

## Part 2: Soundness of the new text

- **§4.8 `.link_terminal` reuse — SOUND.** `ends_link`/`ends_loop` (`trace_chain.zig:1580-1585`) come from the last opcode only, never `AnchorPcKind`. `isInnerLoopRoot` (`trace.zig:2287-2290`) and `armLinkTerminal`/`armLoopDoneLink`/`armLoopDoneLinkTo` (`trace_link.zig:~1836-1900`) are purely structural. The one place that inspects `cursor.cont`'s value, the `.loop_done_linked` arm's `is_last` branch (`trace_chain.zig:~1914-1926`), states the entry path is irrelevant to coherence and selects via `resolveLoopDoneCont` on `post_pc`. The seed-decline arms (`trace_chain.zig:2318-2407`) never reference `cursor.cont`, only `cursor.link_pc`. No finding.
- **New `exit_side` arm/cursor transition — SOUND as specified.** `applyEdgeCursorTransition` (`trace_chain.zig:782-810`) is an exhaustive switch, a compile-time forcing function. `driveSilentBurst`'s `SuffixInit` path (`trace_chain.zig:1150-1230`) calls the same funnel with a runtime-observed `arm_kind`, so silently promoted `exit_side` suffixes are covered once it is extended.
- **Absolute-address cell stub — SOUND.**
- **"`exit_side` is a committing kind" — NOT adequately specified** (R4-F3).

## Part 3: New issues

### R4-F1 (MAJOR) — `trace_entry_registry.zig`'s tier-0 patch-installer switches are unaddressed

`resolvePatchPc` (`src/trace_entry_registry.zig:101-123`) and `installEntryPatch` (`:126-138`) are exhaustive switches over `AnchorPcKind` (`.head`, `.cont`, `.loop`) deciding whether tier-0's own bytecode gets rewritten (`.jfunc_head`/`.jcont`/`.jfor_loop`/`.jloop`) for direct entry into a compiled trace. Adding `AnchorPcKind.exit` forces both open, and the right answer is a design decision: should an `.exit`-anchored one-shot trace ever get a tier-0 entry patch, or only be entered via the exit adapter? Suggested fix: state the answer (most likely "no patch") and why.

### R4-F2 (MINOR) — `trace.zig:3619`'s precise-retry threshold switch

`switch (anchorKind(notice.anchor.pc)) { .loop => hotloop, .head, .cont => hotcall }` has no `.exit` arm and no discussion. Plausibly unreachable for `.exit` (one-shot, not counter-driven), but that assumption should be stated.

### R4-F3 (MAJOR) — the committing-kind rule is bound by four sites, only one named, and two axes are conflated

1. `trace_chain.zig:1670-1685` — `region_work` switch (region progress). Needs an `.exit_side` value.
2. `trace_link.zig:745-753` (`silentKindForArm`) and `trace_link.zig:907-926` (`rowSilentKind`) — map `ArmKind`/`LedgerKind` to `SilentSiteKind` (`deopt, link_terminal, loop_done_linked, region_bridge`); need `.exit_side`.
3. `nativegen_emit.zig:1287-1443` (`emitSilentEpilogue`) — hand-written per-kind x86 (lines 1360-1418) that must agree in emitted bytes with site 1's count; the same class of cross-site miscount already caused the doc 55 correction arc.
4. `src/trace_exec.zig:285` `commitsGuestWork` — exhaustive over all 12 `LedgerKind`s (`true` for `link_terminal, loop_done_linked, region_bridge, head_terminal, ret_pop, call_push`; `false` for `deopt, prologue_fail, seed_hash_decline, seed_capacity_decline, precise_deopt, precise_error`). A separate axis: it feeds doc 55 §1's zero-progress strike/retirement (`provenanceEdgeVerdict`, `trace_regionops.zig:1007-1044`; `stageSilentSuffixProvenance`, `trace_regionops.zig:1110-1126`). Doc 56 cites only doc 55 §2(c).

Getting `commitsGuestWork` wrong in either direction risks spurious strikes or masking a real ping-pong (cf. the nsieve +128% scar, Rule Z-8). Suggested fix: list all four sites with intended values (best guess `local-ish 1 / .exit_side / mirror loop_done_linked / true`) and note the §1-vs-§2(c) axis distinction.

## Verdict

**CHANGES REQUESTED.** All round-3 findings resolved; the `.link_terminal` reuse checks out against source. R4-F3 (MAJOR) is a materially incomplete accounting spec across four sites; R4-F1 (MAJOR) is an open design question; R4-F2 (MINOR) is a smaller loose end in the same family.
