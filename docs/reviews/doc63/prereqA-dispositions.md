# Prerequisite A implementation review, round 1 — dispositions (2026-10-10)

Reviews: `codex-prereqA.md` (REJECT), `antigravity-prereqA.md` (APPROVE
WITH CHANGES).

| Finding | Disposition |
|---|---|
| Codex 1 / Antigravity 1: native liveness does not cover helper snapshots | Confirmed, and wider than the string helpers: the precise liveness extension in `nativegen_alloc.analyzeInner` used `requiresPreciseSnapshot`, which covered only guards and `tnew`, so every precise body exit outside that set (string helpers, match ops, `href`, typed loads) could flush a recycled register. Pre-existing for the non-allocating exits. Fixed: the extension now follows `opMayExitInBody`, the closed inventory of body exits, and `requiresPreciseSnapshot` covers every exit-capable body op, so finalize and native admission reject a missing snapshot on any of them. The precise exit stub asserts `opMayExitInBody` for every snapshot it materializes. Regression test: "nativegen (precise string helper exits, doc 45 D6)" checks the allocator's `last_use` against each helper's snapshot in every committed precise trace; it fails with the old guards-plus-`tnew` set. |
| Codex 2 / Antigravity 2: tests do not prove each helper failed; no `tostr_num` | Fixed. `sweep` now counts runs that raised through `.precise_error` *at the call to the helper under test* (the parked pc is that call's bytecode, not `new_table` or an earlier feeding call), and every case requires at least one in both tiers. Added a `tostr_num` case (`tostring(i + 0.5)`). |
| Antigravity 3: no `scap_str` decline test | Fixed: a unit test of `scapStrRuntime` (virgin scratch → `.decline`, intern miss under a failed allocation → `.oom` with the `out_of_memory` ordinal, then success). |
| Antigravity 4: stale `irinterp.zig` comment | Fixed: the comment names both sources of a nonzero `runtime_error`. |
| Codex 3: ordinary-OOM TODO overstates the restriction | Revised. Ordinary traces build doc 56 boundary snapshots, but only for attachable side-exit guards; helper exits carry none. Added option (c), extending the helper-error integration to ordinary traces, with its cost. |
| Codex 4: doc bookkeeping | Fixed: `### Outstanding` restored; §5.4 describes the old null protocol in the past tense; the two decline outcomes are distinguished (an out-of-range codepoint raises; a stale scratch replays to a value or an error). |

## Round 2 (2026-10-10)

Reviews: `codex-prereqA-r2.md` (APPROVE), `antigravity-prereqA-r2.md`
(APPROVE).

| Finding | Disposition |
|---|---|
| Codex 1 / Antigravity 1: `requiresPreciseSnapshot`'s doc comment names a nonexistent `nativegen_alloc.nativeMayExit` | Fixed: it names `opMayExitInBody`. |
