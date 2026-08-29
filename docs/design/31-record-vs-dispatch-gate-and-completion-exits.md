# 31 — Record-gate vs dispatch-gate, and clear-on-productive

Status: v2 after codex review (2026-08-29; ledger §8). Follows doc 30;
fixes the profitability-machine pathology that capped str_gmatch's native
residency at 2.6% and invalidated the doc 30 §11 "callout dominates"
verdict. Bart's original pick was (1)+(3) — gate split + designed-exit
classification; the review BLOCKED (3) as specced (op-level exit identity
cannot separate sgmatch exhaustion from its error statuses, and guard_gc
is not safe to neutralize) and Bart switched to **(1)+(2)**: gate split +
clear-penalty-on-any-productive-receipt.

## 1. The evidence (str_gmatch, N=80000, jit-debug + --jit-stats)

The committed gmatch trace is healthy: entries complete 7 of the 8 tokens
per instance (receipts `completed=7` ×2647), and `--jit-stats` prices its
iterations at **~332 cycles/iter native vs ~465 tier-0** (−29%). Yet:

```
tier-0, has-trace:  621271  (86.3%)   <- fallback despite a trace
ran as a trace: 2.6% of iterations
```

Three interacting mechanisms gate the healthy anchor (pc=12) for most of
the run:

1. **Zero-progress receipts at designed exits ratchet the penalty.**
   Occasionally an entry lands at exhaustion (`sgmatch` finds no match →
   `completed=0`, exit 16) or at a GC-admission refusal (`guard_gc`, exit
   17). `accountLegacyThrash` counts each as a strike (12 such receipts at
   N=80000).
2. **Productive receipts can never clear the ratchet.** The clear
   condition is `completed >= min_useful` (8); an instance physically has
   only 7 native iterations to give. `completed=7` is "not a strike" but
   also never clears, so the penalty grows monotonically to `max_penalty`
   → `gateAnchor` → doubling cooldown (256 → 8192+ ticks). Observed:
   `legacy-strike: completed=0 penalty=8..12 -> gate`, strikes 2–6.
3. **Recording aborts gate dispatch.** The hot exhaustion exit keeps
   requesting a side trace anchored at pc=12; the generic-for done
   direction is deliberately unrecordable (`recTForLoop` aborts
   `.bad_type` on nil ctrl, doc 30 §6 abort-don't-commit); and
   `abortRecording` → `gateAnchor(self.rec.anchor)` — which blocks
   **entering the committed root trace** at the same anchor.

The doc 30 §11 str_gmatch verdict ("native iterations ≈ tier-0 because the
callout dominates") was measured on a run that was ~97% tier-0 *because of
these gates* — the jit leg retired MORE instructions than pure tier-0
(1152M vs 1130M) with a near-identical symbol profile. The −joff LuaJIT
bound (their constants) stands; our own native-vs-tier-0 comparison was
gate-corrupted and is superseded by the `--jit-stats` per-iter pricing.

## 2. LuaJIT grounding

Pall's backoff machine (`penalty_pc`, lj_trace.c) fires **exclusively on
recording aborts**, and what it suppresses is **re-recording at that
start-PC** (escalating to blacklist). A committed trace keeps dispatching
forever; nothing in LuaJIT stops entering a healthy root because a later
side-trace recording failed. Side-exit growth is throttled separately
(`hotside`), again recording-side only. Our single `gate` map conflates
"stop trying to record here" with "stop entering the trace cached here" —
the non-Pall invention this doc removes. (Same family as the reformed
per-segment strike machine, trace.zig:3446 comment: productive segments
were never strikes in LuaJIT either.)

## 3. D1 — split the gate (option 1)

Two maps with the same `GateState` backoff struct and the same
deterministic tick arithmetic:

- **`gate` (dispatch)** — unchanged meaning: this anchor's cached traces
  are not entered while gated. Sources: `accountLegacyThrash` (zero-
  progress turnstile, as re-scoped by D2), `flushRegionWindow` (region
  decay, untouched this arc), `gateNativeUnsupported` (running the trace
  would be slower than tier-0 — dispatch is exactly what it must stop).
- **`record_gate` (new)** — this anchor does not START new recordings
  while gated. Sources: `abortRecording` (both the root-attempt and
  side/replay-side attempt paths) and `closeTrace`'s commit-failure arm.

Check-site assignment:

| site | today | after |
|---|---|---|
| trace-entry eligibility (interp.zig:2732, :3894) | `isGated` | dispatch only |
| entry-patch qualification (trace.zig:10973) + `markEntryPatchesAt` | via `gateAnchor` | dispatch-gate only — a record-gate must NOT unpatch a healthy trace's entry |
| `afterBackEdge` GATE_SKIP hot-count arming (trace.zig:11305) | `isGated` | dispatch only — a record-gate must not starve dispatch through the pre-filter |
| recording-start guards (trace.zig:8251, :11355 `consumeSideTraceWantAtResume`, and every `arm()`/replay-side path that consults `isGated`) | `isGated` | **both** gates — dispatch-gated anchors also decline recording, preserving today's duplicate-suppression |
| `gateNativeUnsupported`'s `isGated` re-escalation guard | `isGated` | dispatch only (it writes the dispatch gate) |

**Review round-1 leak fixes (B3), now part of D1:**

- **Want production must be gated, not just consumption.** `noteTakenExit`
  creates `wants_side_trace` and immediately `markEntryPatchesAt`
  (trace.zig:8404/8410; prime-side 8395/8401) — with a standing record
  gate every qualifying hot exit would re-create the want and unpatch the
  healthy entry forever. Both-gates eligibility moves to want CREATION;
  the exit counter stays saturated at `hotexit`, so the first exit after
  cooldown retries without losing hotness.
- **Every actual `rec.reset` gets a final both-gates check** — the
  continuation and replay-side start hooks activate the recorder directly
  (trace.zig:8283/8306), after the request was created; the request may
  have been gated in between.
- **Cooldown retry must see both maps.** `onBackEdge` detects an expired
  gate via `self.gate.contains(key)` (trace.zig:11443/11449) to re-arm a
  recording whose counter is already past the one-shot `count == hotloop`
  crossing; with aborts moved to `record_gate`, that probe must consult
  both maps or an aborted root recording never retries.

**`max_strikes` after the split** — the two histories are independent:
dispatch `max_strikes` permanently abandons execution (and, since
recording consults both gates, recording too); record `max_strikes`
permanently abandons only future recordings — committed traces keep
dispatching. Record-abandonment deliberately survives trace retirement
(`removeTrace` resets only the warming counter, trace.zig:10722) — that
is the `penalty_pc` blacklist analog, accepted and tested.

Lifecycle: `record_gate` is cleared/deinitialized wherever `gate` is
(clearCache trace.zig:11070, deinit :2906). Region recovery and member
amnesty (trace.zig:4667/4737) clear penalty + dispatch gate only — they
must not pardon recording-abort history.

Determinism: both maps key on the same monotonic back-edge `tick`; no new
inputs. Snapshot/replay: gate state is runtime-private (not serialized)
today; the split adds none (restore starts with a fresh trace cache).

Expected collateral: any bench whose root anchor was being gated by failed
side/re-recordings gets its dispatch back (the abort log shows cross_frame
aborts on many benches). Board prediction is neutral-or-positive; traces
whose *dispatch* is genuinely unprofitable remain gated by the dispatch
sources.

## 4. D2 — clear-on-productive (option 2, review-recommended)

`accountLegacyThrash`'s clear condition drops from `completed >=
min_useful` to **`completed > 0`**:

```zig
if (completed > 0) {
    _ = self.penalty.remove(key);
    _ = self.gate.remove(key);   // dispatch gate only — never record_gate
    return;
}
```

Why this is sufficient AND safe:

- **The ratchet dies.** The observed pattern is `7-productive,
  7-productive, …, 1-zero` — every productive receipt now resets the
  strike count, so isolated designed-exit zeros (exhaustion entries,
  guard_gc refusals) can never accumulate to `max_penalty`.
- **Every real turnstile still gates.** A pathological anchor —
  `gc_stress` admission failure on every entry, a corrupted gmatch state
  zero-exiting through `sgmatch`'s error statuses, a type-flip loop —
  produces *consecutive* zeros with no productive receipt in between, and
  reaches `max_penalty` exactly as today (the `gc_stress` parking test at
  interp_trace_test.zig:508 stays green by construction).
- **No exit taxonomy, no receipt-ABI change.** The review's B1/B2
  blockers (sgmatch status collapse at irinterp.zig:1046 /
  nativegen.zig:5260; guard_gc's parked `object_count < next_gc <=
  object_count + A` state that tier-0 never collects out of) simply don't
  arise — the rule never needs to know WHY a zero happened.
- **Pall-faithful.** LuaJIT has no penalty for productive traces at all;
  this is the closest determinism-preserving analog our
  runtime-turnstile exits allow.

The known give: strict `1-productive / 1-zero` alternation never gates
(each productive clears the single strike). That shape pays half its
entries as pure turnstile. Accepted for now — LuaJIT accepts the same
(hot exits there are patched branches, so their cost model doesn't even
care); if a bench ever demonstrates it, the recorded escalation path is a
deterministic saturating work-credit score, NOT an IR-op exemption list
(review §"simpler alternative").

The exit-outcome plumbing from v1 (status into the receipt/ledger ABI,
neutral = {numeric-for loop-done, sgmatch `no_match` only}) is shelved
with its blockers documented — it becomes relevant only if the work-credit
escalation is ever needed.

Out of scope, recorded: the region-window remainder strike
(`flushRegionWindow`, `0 < work < min_useful`) has the same conceptual
issue but was NOT the mechanism here (`barren-noactive` receipts routed
to the legacy machine); touching doc 17's window pricing needs its own
evidence.

## 5. D3 — make the pathology visible (the "we keep circling this" fix)

- `gateAnchor` takes a `reason: GateReason` (`record_abort`,
  `commit_failure`, `legacy_thrash`, `region_decay`, `native_unsupported`)
  — carried in the dbg line, so a receipts log self-explains which machine
  gated. Zero cost in normal builds (comptime-false dbg).
- `bench/run.py --jit-stats`: optional per-row native-residency column
  ("ran as a trace %" from the existing `--jit-stats` output), so the
  board artifact itself shows a flat row sitting at 3% residency.
- Project CLAUDE.md profiling recipe gains the standing rule: a bench that
  stays flat after a coverage lever gets a `--jit-stats` run BEFORE any
  verdict; "fallback despite a trace" above a few % is the first suspect;
  native-vs-tier-0 per-iter claims are citable only from that output.

## 6. Tests (adversarial; review round-1 list merged)

1. **Ratchet regression (the bug)**: a gmatch-shaped for-in loop (fixed
   token count < min_useful per instance) driven for many instances —
   assert the anchor is never dispatch-gated, receipts keep flowing, and
   output is byte-identical to tier-0.
2. **Record-gate does not block dispatch or unpatch**: with a committed
   patched trace, force recording aborts at the same anchor — entries
   continue, the entry patch survives, repeated hot exits do not re-create
   wants while record-gated.
3. **Turnstile preserved**: an anchor producing only consecutive
   `completed=0` receipts (no productive receipts) still reaches
   `max_penalty` and dispatch-gates; the `gc_stress` parking test
   (interp_trace_test.zig:508) stays green.
4. **Clear is dispatch-only**: productive receipts clear penalty + the
   dispatch gate but never `record_gate`.
5. **Root abort retry**: an aborted root recording retries after the
   record cooldown expires even though its warming counter is past the
   one-shot `count == hotloop` crossing (the `contains` probe fix).
6. **Late gating of a pending request**: a continuation/replay-side
   request created before a gate lands is declined at `rec.reset` time.
7. **Independent `max_strikes`**: record-map permanence blocks future
   recordings only (dispatch continues); dispatch-map permanence blocks
   both; record-abandonment survives trace retirement.
8. **Unsupported stays dispatch-gated**: `gateNativeUnsupported` still
   prevents entry (tier-1a-slower protection intact).
9. **Map lifecycle**: clearCache/deinit cover `record_gate`
   (std.testing.allocator leak-check).
10. Full battery: `zig build test` both legs, hashgate 84/84 (mode
    byte-identity is the determinism gate — gating decisions may differ
    per mode, output must not), board ×2 + shadow A/B.

## 7. Predictions

str_gmatch: residency 2.6% → >80%; with native at ~332 vs tier-0 ~465
cycles/iter over ~86% of loop iterations and the loop at ~96% of the run,
wall ~52.6 → **~44–48 ms** (entry-seam per instance is the uncertainty;
receipts show ~7 iters/entry amortization). find_match/gsub/format:
unchanged (their anchors weren't thrash-gated). Board-wide: neutral or
positive from D1 (root anchors previously gated by failed side
recordings); any regression is a real finding about a marginal trace whose
dispatch the old conflation was accidentally suppressing — investigate,
don't tune.

## 8. Codex review ledger (2026-08-29, v1 → v2)

Verdict on v1 ((1)+(3) as approved by Bart): **BLOCKED**, three blockers.
**B1**: op-level exit classification for `.sgmatch` is unsound — both
executors collapse every non-OK status into the same `exit_instr`
(irinterp.zig:1046/1054, nativegen.zig:5260/5268), so "neutral if
op==sgmatch" would also pardon `pattern_mismatch`/`bad_layout`/`bad_type`
turnstiles; doing (3) right requires exit-status plumbing through the
receipt/ledger ABI with neutral = `no_match` only. **B2**: `guard_gc`
must keep striking — a parked state (`object_count < next_gc <=
object_count + A`, irinterp.zig:852 vs the tier-0 safepoint condition
interp.zig:2092) can fail admission indefinitely without tier-0 ever
collecting, and under `gc_stress` every entry fails (the parking test at
interp_trace_test.zig:508 depends on the gate). **B3**: the v1 D1 split
leaked in three places — want production unpatches at creation
(trace.zig:8395-8410), the continuation/replay-side hooks `rec.reset`
without a final gate check (8283/8306), and cooldown retry probes
`gate.contains` (11443/11449) so record-gated aborts would never retry.
All three fixes are folded into §3.

The review recommended option (2) (clear-on-productive) as the simpler,
more general rule — no taxonomy, no ABI change, all real turnstiles
(consecutive zeros) still gate; escalation path if ever needed is a
deterministic saturating work-credit score, not an op list. Bart
switched the arc to (1)+(2); §4 is the v2 result. Review confirmations
kept: dispatch-only assignments for interp.zig:2732/:3894,
installPending :10973, `markEntryPatchesAt` :11262, GATE_SKIP :11305,
native-unsupported :5028; snapshot/restore adds no schema; region
recovery/amnesty (:4667/:4737) must clear dispatch state only; both maps
join clearCache :11070 and deinit :2906; `removeTrace` :10722
record-blacklist permanence accepted; D3 dbg lines name gate kind AND
reason (`dispatch:legacy_thrash` vs `record:record_abort`).

## 9. Landed results (2026-08-29)

Implementation matched §3–§5 with no deviations. Gates: `zig build test`
green (both legs, incl. `-Djit-debug=true`), hashgate 84/84.

**Test fallout, all semantic and intended:**
- 8 abort-path assertions in `interp_trace_test.zig` moved `gate` →
  `record_gate` (aborts now gate RECORDING).
- `trace_entrypatch_test.zig` "doc 20 triggers": the side-arm half now
  runs with the dispatch gate cleared between the halves, and pins the
  new blocked-while-gated want production plus saturating-counter
  recovery.
- `interp_native_test.zig` "branchy low-yield loop": **expectation
  deliberately inverted.** The 1-productive-iteration-per-entry parity
  loop was the old gate's poster child; under D2 it never gates
  (probe: gate=0, penalty=0, entries=98/200-iter run) — this is §4's
  accepted give, now pinned as such with the work-credit escalation
  path named in the comment.
- New §6 coverage: 5 unit tests in `trace_gate_test.zig` (D2 alternation
  + turnstile + dispatch-only clear; map independence/permanence; abort
  retry via the `contains` probe; late gating of pending
  continuation/replay-side requests; `clearCache` epoch drop), 1 in
  `trace_entrypatch_test.zig` (record gate leaves the patch live, bars
  want production, survives retirement), 1 e2e ratchet regression in
  `interp_native_test.zig` (300 gmatch instances × 5 tokens: gate=0,
  entries=300, the one `record_gate` entry is the outer j-loop's abort).

**§7 predictions vs measured (str_gmatch, bench scale N=80000):**

| metric | before | predicted | measured |
|---|---|---|---|
| native residency (iterations, gmatch anchor) | 3.3% | >80% | **75.0%** (66.7% whole-run) |
| "tier-0, has-trace" iterations | 86.3% | — | 22.2% |
| wall (jit) | 52.6 ms | ~44–48 | **49.4 ms** |

Direction right, magnitude short of the window. The residual is exactly
§7's named uncertainty — the per-instance entry seam: receipts show 8
loop iterations per instance of which 2 run tier-0 (the header
iterations before trace entry) and 6 native (`iters/native-entry ~6`),
so 22% of iterations — ~40% of the loop's cycles at ~541 t0-c/it vs
~265 trc-c/it — are seam, not gating. Getting the entry onto the
FIRST header reach (tfor `.jloop` entry patching covers the back-edge
path today) is the follow-up lever, recorded in TODO.md; it is doc-30
patching territory, not gate policy.

D3 landed: `GateReason` in the dbg lines, `res%` on the board (one
dedicated `--jit-stats` run per bench, never timed; `--no-jit-stats`
opts out), and the standing `--jit-stats`-before-verdict rule in the
project CLAUDE.md profiling section.

### §9a. First-board regression and the D1 amendment (same day)

The first post-split board (vs an nm-verified a818c79 shadow) was NOT
neutral: every bench whose hot loops abort recording and never commit a
trace regressed hard in jit mode — tbl_ops 16.9 → 23.7 ms (+40%),
euler14-bit 103 → 161 (+55%), nsieve-bit-fp 284 → 445 (+57%),
scimark-sparse/array3d/spectral-norm +13–35% — all showing `res% 0.0`
and `--jit-stats` "0 committed traces, 100% tier-0". Mechanism: §3's
check-site table assigned the `afterBackEdge` GATE_SKIP arming to the
dispatch gate only (correct for anchors WITH a trace — a record gate
must not starve dispatch through the pre-filter), but an abort-
blacklisted anchor now lives ONLY in `record_gate`, so it never armed
the skip and paid full `onBackEdge` bookkeeping (hash getOrPut + cache
scan + two gate probes) on every back-edge forever. Pre-split, those
anchors were dispatch-gated and skipped.

Amendment (landed with a pin test in trace_entrypatch_test.zig):
`afterBackEdge` arms GATE_SKIP when `isGated(key) OR (isRecordGated(key)
and !hasTrace(key))` — a record-gated anchor with nothing to enter is
dead for the slow path exactly like a dispatch-gated one; a record-gated
anchor WITH a trace still never skips. Spot-checks after: euler14 jit
0.10 s ≈ t0, nsieve-bit-fp 0.29 vs t0 0.27, scimark-lu 0.19 (baseline
0.165→0.238 regression mostly recovered). The §7 sentence "any
regression is a real finding — investigate, don't tune" did its job:
the finding was a D1 implementation leak, not a D2 policy cost.

### §9b. Final whole-board A/B (post-amendment, vs nm-verified a818c79 shadow)

Board TSVs: `20260829-102911` (pre-amendment, the regression evidence),
`20260829-104730` (final). Post-amendment vs baseline, jit column:

- **Wins**: str_manip −37% (19.1 → 12.1 ms — the biggest single-bench
  move of the arc, an anchor the old conflated gate was starving),
  scalar −11%, str_gmatch −9% (55.1 → 50.0), str_find_match −6%,
  lua54 jit/t0 1.01 → 0.95.
- **Everything else ≤ noise** by jit/t0 ratio (the machine drifted a few
  % between boards; same-conditions 9-rep A/Bs used for the two
  suspects). repack: d31 64.6 vs base 66.3 same-conditions — clear.
  str_format: instructions IDENTICAL (2.3065e9 vs 2.3071e9, d31 fewer),
  cycles +2.8% at IPC 3.73-vs-3.84 — pure code-layout/icache, the
  lua54-class effect; not semantic.

Net: the split + clear-on-productive is board-positive with no
above-noise regression remaining.
