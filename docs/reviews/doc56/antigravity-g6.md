# Doc 56 §4.8.4 (G6: the `.side` link close) — design review (Antigravity, 2026-09-27)

Scope: widening `recForLoop`'s `LJ_TRLINK_ROOT`-style close from
`kind == .continuation` to `.continuation or .side`, and the options
G6-Q1 / G6-Q2.

**Verdict: APPROVE WITH CHANGES.**

Verified in source (reviewer's summary):

- **Soundness.** `side_src` / DONE-latch provenance at commit is
  unaffected (`finishSideTraceProvenance`; `noteExitSideCommit` already
  wants a `.link` child at a wanted exit's resume pc). Sibling handoff
  has no `.loop`-tail requirement (`siblingHandoffEligible`,
  `armNativeLink`), and `replayLedgerFrom` accepts `ends_link` for
  handoff and exit-side entries. `linkKindAt` classifies a non-header
  `.side` anchor inside the enclosing loop as `.enclosing_iteration`
  (credits the iteration), an outer anchor entering an inner loop as
  `.inner_root`, and a header anchor's own back-edge never links
  (`target != anchor.pc`). Region owner election still succeeds (the
  enclosing header encloses the members; fallback 3e-b also names the
  link's loop root). The doc 40 peel runs only on anchor-return closes,
  so it is bypassed, not broken.
- **Parity.** `recForPrepLink` and `recWhileLink` already accept
  `.side`; `recForLoop`'s gate is stricter (entry guards, non-peeled
  root, no pending doc 47 peel, `within`).
- **LuaJIT.** `rec_loop_jit` (`lj_record.c` ~659): a root hitting a
  compiled inner loop aborts `LINNER`; any other trace entering a
  compiled loop stops `LJ_TRLINK_ROOT`. No side/continuation
  distinction — the `.continuation`-only gate is a divergence.

## Findings and dispositions

1. **MAJOR — the switch-off fft regression (215 → 512 ms) comes from
   G5.** Reviewer recommends G6-Q1 (c): G5 first, then (a). Recorded as
   the reviewer's recommendation; the choice is Bart's.
2. **MAJOR — no `loopunroll` bound.** When the link gate declines (no
   root at the target, entry guards mismatch, peeled root), a `.side`
   or `.continuation` recording still unrolls the enclosing loop up to
   `maxrecord`. LuaJIT bounds this with `loopunroll` = 15
   (`lj_jit.h:121`; `rec_loop_interp`, `lj_record.c` ~648/654: roots
   and side traces entering an UNCOMPILED loop, `LJ_TRERR_LUNROLL`).
   **Taken as a new option, G6-Q1 (d).** Verified: mahina has no
   equivalent (`instunroll` bounds only same-anchor carrier
   oscillation). Note: it would not by itself have fixed nsieve — t6
   crossed a COMPILED loop (the outer root existed) and unrolled ~10
   iterations, under 15; the link close is what LuaJIT does there.
3. **MINOR — the doc 40 glue peel test** must be rewritten if the close
   is widened. Reviewer suggests G6-Q2 (b) (pin the link, keep a
   separate program that still peels with no enclosing root); five
   other peel tests (`interp_native_test.zig` ~1640–1748) keep the peel
   covered. Folded into G6-Q2.
4. **NIT — `linkKindAt` could assert the anchor proto**
   (`cur_proto_id == anchor.proto.id`). Deferred to the implementation.

**Not taken as stated:** the reviewer's claim that option (b)
"violates determinism". The switch is a VM config input, identical on
every leg of a run, so all record/exec modes still see the same trace
shapes. It does make trace shapes depend on the flag, which the switch
already does (adapters, exit-side arms). Kept as an option.
