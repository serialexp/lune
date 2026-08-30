# 33 — An entry refusal is not anchor thrash (B2b, part 1)

> **v2.** v1 was reviewed BLOCKED: it proposed removing the refusal strike while
> claiming three independent bounds, none of which actually bounds an *unpatched*
> always-refusing trace. v2 replaces "suppress the strike" with "charge the
> refusal to the **candidate**, not the **anchor**". The review ledger is §8.

## 1. The bug

`accountLegacyThrash` (trace.zig ~3459) prices every `completed == 0` receipt as
turnstile cost. Doc 31 already narrowed it once — *"a PRODUCTIVE segment is never
a strike"* — and left this behind:

> What remains below is the zero-progress half only: an entry that commits
> NOTHING is pure turnstile cost.

That conflates two different events:

| | what happened | who it is evidence about |
|---|---|---|
| **deopt at zero** | the trace was entered, ran the body, hit a guard, committed nothing | the **anchor**: this loop shape is churning |
| **prologue refusal** | a hoisted entry guard failed pre-commit; the body never ran | this **candidate**: *this trace's* entry contract does not match |

Both are currently charged to the anchor's penalty. Charging a refusal to the
anchor is the category error: it condemns *every* trace at that pc, including
the ones that would have entered happily.

The codebase already draws this line one arm over (trace.zig ~6539, doc 22
§B.2, seed declines): *"a decline is an entry-condition mismatch, not a guard
failure."* A prologue refusal differs only in which entry condition failed.
(It is precedent for chargeless *anchor* accounting — not evidence that a
refusal is free or that its routing is identical; see §5.)

## 2. What it costs — spectral-norm

`Av` is called alternately over `u` (`.value`) and `v` (`.f64`): one anchor, two
array lanes. The committed trace pins one. Every call presenting the other lane
refuses at the prologue and is scored a strike against the *anchor*; ~60
consecutive refusals per call reach `max_penalty` and install
`gate[dispatch:legacy_thrash]` at pc=9 with escalating 256→4096-tick cooldown
windows, which also block the calls that would have entered.

```
[jit] receipt: pc=9 link_mode=false local=0 exit=4294967295 ledger_len=1 completed=0
[jit] legacy-strike: anchor pc=9 completed=0 penalty=1/8
[jit] gate[dispatch:legacy_thrash]: anchor pc=9 strikes=5 window=4096   (x45)
```

Measured, suppressing the anchor charge at the scalar dispatcher site only:

| | before | after |
|---|---|---|
| loop iterations that ran as a trace | 14.8% | **76.3%** |
| retired instructions, `--jit-native`, N=200 | 1,387,659,557 | **498,283,678** |

**−64% instructions.** The trace was always healthy (22.2 c/it vs tier-0's
434.3 c/it); dispatch was forbidden from entering it.

Not a spectral-norm fix (Rule Z-6): the mechanism is general. *Any* anchor whose
entry guards are polymorphic in something a trace pinned — a lane, a type, a
shape — has its whole dispatch condemned by the subset of callers that miss.

## 3. The fix: charge the candidate, not the anchor

Two parts, and part (b) is what makes part (a) safe.

### (a) A refusal takes no anchor penalty

`accountLegacyThrash` gains an explicit discriminator. A refusal takes no
penalty, no gate, and **no clear**:

```zig
const ChargeKind = enum { entered, entry_refusal };
```

**Explicit, never inferred.** `exit_instr == maxInt(u32)` must NOT be the
discriminator: it is overloaded between clean tier-1a completion
(irinterp.zig:70) and native prologue failure, and `onSideExit`
(trace.zig:3421) passes it merely to mean *"no exit identity known"*. The
correct source is `irinterp.ExitReason.prologue_fail` — initialised `.normal`,
stamped only in the prologue-failure stub (nativegen.zig:7092), marshalled into
`ExecResult` (nativegen.zig:1091), and asserted to agree with the terminal
ledger row (nativegen.zig:1050).

**No clear, and this matters.** A refusal proves nothing about productivity, so
it must not erase a genuine strike. Otherwise an alternating
`deopt → refusal → deopt → refusal` sequence would clear every real turnstile
charge and the anchor could never gate. Doc 31's clear-on-productive rule is
explicitly grounded in *committed progress*; a refusal supplies none.

### (b) A per-candidate consecutive-refusal cooldown

This is the bound v1 lacked. Per **trace** (not per anchor):

* a refusal increments that trace's `consec_refusals`;
* **any** entry that actually ran the body — productive or a real deopt —
  resets it to 0;
* on reaching `max_entry_refusals`, that *one trace* becomes ineligible for
  selection for a cooldown window. The anchor is untouched; every other
  candidate at that pc still dispatches.

Why this is the right shape:

* **It preserves the win exactly.** spectral-norm's trace alternates
  refuse/enter, so `consec_refusals` never accumulates past 1. Only a trace that
  refuses *every single time* — one whose entry contract can no longer be
  satisfied at all — is suppressed.
* **It is the dynamic twin of machinery already at the site.** The widen-eviction
  check sits immediately below the charge in interp.zig: *"this trace's array
  lane guard can never pass again, retire it."* Consecutive refusal is the
  observational version of the same statement, for guards whose
  unsatisfiability we cannot prove statically.
* **It is deterministic** — a pure function of the receipt sequence, no clock,
  no address, no RNG.
* **It cannot recreate the bug.** The suppression is keyed on the trace, so a
  polymorphic anchor never loses dispatch for its matching callers.

`max_entry_refusals` is a new `TraceConfig` field. It should be generous
(a refusing candidate costs one native call + ledger row, not a full deopt) —
proposed default 32, to be justified by measurement, not guessed permanently.

### (c) Sites to convert

Every site that has *locally proven* the reason. v1 listed three and missed
four; the review found the rest:

| site | evidence available at the site |
|---|---|
| `interp.zig:2839` scalar dispatcher zero path | `result.exit_reason` |
| `trace.zig:5540`, `5545` `driveChain` zero paths | `sresult.exit_reason` |
| `trace.zig:6529` silent M1 ramp | asserts `e.reason == .prologue_fail` |
| `trace.zig:7013` fused M1 sub-case (c) | asserts `se.reason == .prologue_fail` |
| `trace.zig:7165`, `7182` main replay arm | arm asserts the full contract at 7140 |
| `trace.zig:7585` linked-burst call A | `iresult.exit_reason` |

The main replay arm's `ends_link` branch returns `.break_burst` (trace.zig:7176)
and *loses* the reason; its consumers then charge a generic seed zero
(trace.zig:5614, 7847, 8199). The directive must carry refusal-ness through, or
that branch must return a chargeless terminal result directly. Leaving it
unconverted is not acceptable for the general policy — it is precisely the
linked/bridged shape B3 will make common.

## 4. Determinism and replay

No blocker, confirmed against source. `exit_reason` is deterministic (§3a). No
gate or penalty state is serialised into keyframes — they carry semantic heap,
stack and frame state (keyframeser.zig:313) and restore deliberately starts with
no transient JIT tiering state (keyframeser.zig:578). Execution-log mode cannot
observe a native prologue-fail at all: enabling the log disables native entry
(interp.zig:2259) and runs instrumented tier-1a instead. The log is
observation-only, not replay input (execlog.zig:7).

The 10-leg matrix and keyframe parity tests are still required, because the
change alters *tier residency* — but `exit_reason` introduces no
nondeterministic input.

## 5. Cost accounting, stated accurately

v1 overstated this and is corrected:

* A refusal is **not** "never entered". The trace is selected, counted as an
  entry, native code is invoked, and the prologue runs; only the body commits
  nothing (interp.zig:2311, nativegen.zig:7075).
* It is **not** "a handful of `cmp`s and a `ret`". It appends a ledger row
  (nativegen.zig:7092), runs the native return path, marshals `NativeResult`,
  and returns through dispatcher receipt processing.
* It is therefore **not** "strictly cheaper than the tier-0 work those calls do
  anyway" — it is refusal overhead *plus* that tier-0 work, since selection
  returns `.next_candidate` (interp.zig:2897).

This is exactly why (b) exists: the refusal is cheap relative to a deopt but not
free, so it needs a candidate-local bound rather than no bound.

Also corrected: reaching `max_penalty` installs or escalates a **cooldown**;
permanence arrives only after `max_strikes` gate escalations (trace.zig:11293,
11316). v1's "gated off for the run" was wrong.

## 6. What this does NOT fix (B2b part 2)

The anchor still never records a **second** trace for the second lane shape.
LuaJIT's answer to a polymorphic loop is another root or side trace, not a
penalty. After this change the refusing calls stop poisoning dispatch, but they
still run tier-0 forever — spectral-norm goes to ~76% traced iterations, not
~100%. The rest needs part 2, which is adjacent to B3 (`nativegen.zig`
`laneConsistent`: one array lane per whole trace, a single `?i32` with no keying
by table/ref/slot).

## 7. Tests and falsification

* `trace_gate_test.zig` — a refusal does not strike the anchor; N consecutive
  refusals do not gate the anchor; a refusal does **not** clear an existing
  penalty; an alternating `deopt/refusal` sequence still reaches
  `max_penalty` on the deopts alone; a real zero-progress deopt still strikes
  and gates exactly as before.
* Candidate cooldown: `max_entry_refusals` consecutive refusals suppress **that
  trace** and leave the anchor dispatchable; one successful entry resets the
  counter; a sibling candidate at the same anchor is unaffected.
* e2e: a lane-polymorphic anchor (minimised `Av`: one function called alternately
  over a `.value` array and an `.f64` array), byte-identical across the 10-leg
  matrix, anchor not gated.

Prediction: spectral-norm improves materially; everything else within the pool's
measured ±1.3% band. Any above-noise regression is a real finding to investigate
(doc 31 §7) — and per doc 32 §7b the FIRST mechanism to rule out is binary code
layout (identical trace structure + identical `--dump-native` stream ⇒ layout).
`tools/hashgate.py` 84/84 on both legs, no ref regeneration.

## 8. Review ledger

Codex review of v1, 2026-08-30. Verdict **BLOCKED**. All findings accepted.

| # | Finding | Disposition |
|---|---|---|
| 1 | **BLOCKER** — none of the three claimed bounds bounds an unpatched always-refusing trace. `patch.strikes` increments only in `enterPatchedTrace` while `patch.live` (interp.zig:2905/2940); the ordinary walk does no patch accounting (interp.zig:3943); unpatching returns the trace to `.eligible` rather than retiring it (trace.zig:11053); and a trace only becomes patch-pending after a receipt commits ≥ `min_useful` (trace.zig:5029) — so a never-succeeding trace is never patched in the first place. | Accepted. v1's premise deleted. §3(b) adds a per-candidate consecutive-refusal cooldown as the real bound. |
| 2 | `max_traces_per_anchor` bounds trace *population*, not entry attempts (trace.zig:1647); `record_gate` governs recording, not dispatch (trace.zig:11299) — neither is a bound on this. | Accepted; both claims removed. |
| 3 | Four charge sites missed: `driveChain` 5540/5545 (which has `sresult.exit_reason` locally, contradicting v1's "only three sites have the evidence"), the main replay arm 7165/7182, and linked-burst call A 7585. Also, the `ends_link` branch returns `.break_burst` (7176) and loses the reason, after which generic seed tails charge (5614, 7847, 8199). | Accepted; §3(c) rewritten with all seven sites plus the reason-propagation requirement. |
| 4 | Determinism/replay: no blocker. `exit_reason` is deterministic; no gate state in keyframes; execlog mode cannot observe a native prologue-fail. | Accepted; §4 now cites the source rather than asserting. |
| 5 | "No clear" is correct — and for a sharper reason than v1 gave: clearing would let alternating `deopt/refusal` erase every genuine strike. | Accepted; argument adopted in §3(a). |
| 6 | Four factual errors: "never entered" (it is selected, entered, prologue runs); "a handful of cmps" (ledger row + return machinery + marshalling); "strictly cheaper than tier-0" (it is refusal overhead *plus* tier-0); "gated off for the run after 8 refusals" (cooldown; permanence only after `max_strikes` escalations). | Accepted; §5 added, stating all four correctly. |
| 7 | Seed decline is precedent for chargeless accounting, not proof that routing/cost are equivalent (capacity decline → next candidate; hash decline → tier-1a rerun). | Accepted; §1 qualified. |
