# Antigravity — doc 60 H3 review, round 3: the record/replay legs (2026-10-05)

### Verdict: **APPROVE**

The record and replay legs in [`src/capi_hostcall_test.zig`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig) and the corresponding updates to [`docs/design/60-hand-written-machine-code.md`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md) are sound, leak-free, and correctly verify that the hand-written x86-64 host-call entry (H3) preserves deterministic effect logging, cursor ordering, GC rooting, and fatal replay error handling identically to H1 across all execution tiers (`off`, `tier1`, `native`).

All 58 CAPI test suites pass cleanly in Debug mode without leaks.

---

### Detailed Review

#### 1. Harness Soundness

* **Reusing leg 0's log for both replay legs (`eachTier`):**
  **Sound.** In `.record` mode, `expectSame(&snaps)` runs after every single hostcall, comparing normalized state snapshots across leg 0 and leg 1. The snapshot serializer directly records `committed_effects`, `effect_cursor`, and the full encoded `effect_log` blob ([`src/capi_hostcall_test.zig:296-299`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L296-L299)). Because `expectSame` mandates exact equality at every step, leg 0's log is proven byte-for-byte identical to leg 1's log before `.replay` begins. Providing this verified ground-truth log to both legs in `.replay` mode ensures both implementations are tested against the same input, advance their cursors symmetrically, and consume the entire log (`effect_cursor == effect_log.items.len`).
* **GC safety of decoding into the heap before running:**
  **Sound.** In [`Pair.init`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L475-L478), [`effectser.decodeFile`](file:///home/bart/Projects/lune/src/effectser.zig#L121) interns string effect results into `vm.heap` and returns them in a temporary slice, which is immediately appended to `vm.effect_log`. Allocation during `decodeFile` or `appendSlice` cannot trigger a garbage collection cycle, as GC in mahina is strictly driven by VM safepoints or explicit calls to `vm.collect()` ([`src/interp.zig:2852`](file:///home/bart/Projects/lune/src/interp.zig#L2852)). Once in `vm.effect_log`, [`interp.Vm.forEachRootHeader`](file:///home/bart/Projects/lune/src/interp.zig#L2465) explicitly roots every heap item in `effect_log.items` on every GC cycle. This is directly exercised under GC stress in `effects_src` (`setGcStress(true)` + `collect_after = true`) and passes without memory corruption or leaks.
* **Re-running host callbacks on replay:**
  **Sound and meaningful.** Full host-call replay is deferred under doc 59 E6. Because registered host callbacks are re-invoked on replay rather than skipped, the test callback [`reenterFn`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1190) executes again during the replay pass. Crucially, `reenterFn` is deterministic and re-enters the runtime via `entry(ctx.stage, ctx.leg, ...)`. This is what enables nested host calls through the `.S` entry to be exercised and compared under `.replay` mode. The guest callee inside the callback (`effn`) consumes recorded effects from `effect_log`, verifying that nested host calls preserve replay integrity.
* **Vacuous replay in pure scenarios:**
  **Confirmed, by design.** In [`eachTier`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L640), all differential scenarios other than `effects_src` run pure guest Lua code that performs no effectful operations (`os.clock()`, `getenv()`, `math.random()`). Consequently, for those scenarios, `.record` records 0 effects, `.replay` loads an empty log, and `effect_cursor == effect_log.items.len` evaluates to `0 == 0`. This is not a flaw—it confirms that pure code produces no spurious effects across modes—but it means non-vacuous effect record/replay verification rests entirely on the dedicated `effects_src` and truncation tests (which is explicitly called out in the comment at [`src/capi_hostcall_test.zig:1398`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1398)).
* **Exhaustion test expecting `err_runtime + fatal`:**
  **Sound and exact.** Per doc 59 §3.5 and [`interp.catchable`](file:///home/bart/Projects/lune/src/interp.zig#L7713), `Error.EffectLogExhausted` is non-catchable. When `eff(2)` attempts to read an effect from the exhausted log, `guestFault` sets `box.fatal = true` and returns `mh_status.err_runtime` ([`src/capi.zig:385-388`](file:///home/bart/Projects/lune/src/capi.zig#L385-L388)). `hostcallChain` packs this into `ChainResult`, the `.S` entry restores registers and returns `.err_runtime`, and both VMs are verified to be fatal.

---

#### 2. The "≥ 21 Admitted Calls" Assertion

In [`src/capi_hostcall_test.zig:1438-1440`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1438-L1440):
```zig
if (capi.hostcall_asm and pr.stage == .asm_entry)
    try testing.expect(capi.hostcall_counts.chain - chain_before >= 21);
```
* **Call accounting:** The scenario performs 20 top-level calls:
  - 2 × `eff(1)`
  - 1 × `effnest(5)` (which invokes `reenterFn`, making **1 nested call** to `effn(4)`)
  - 1 × `effboom("!")`
  - 1 × `effmany()`
  - 1 × `eff(2)`
  - 1 × `effva(...)`
  - 12 × `effloop(10)`
  - 1 × `effupper("abc")`
  **Total:** 20 outer calls + 1 nested callback call = **exactly 21 calls**.
* **Empirical verification:** In stage 2 (`.asm_entry`), leg 0 executes all 21 calls through the `.S` entry, and every call satisfies the pre-commit checks and runs via `mahina_hostcall_chain`. An instrumentation probe confirmed that across all 9 configurations (`{off, tier1, native} × {off, record, replay}`), `capi.hostcall_counts.chain - chain_before` is **identically 21**. If any call had fallen back to H1, `chain - chain_before` would have been $\le 20$, causing the assertion to fail.

---

#### 3. Accuracy of Doc 60 Claims

* **§6.1 as-built note ([`docs/design/60-hand-written-machine-code.md:1713-1748`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L1713-L1748)):** Accurately describes the 3-mode matrix in `eachTier`, log serialization/decoding, the 21 admitted calls across all paths, the exhaustion test, and the deterministic `host_env`.
* **§6.2 note ([`docs/design/60-hand-written-machine-code.md:1804-1806`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L1804-L1806)):** Correctly notes that the record and replay legs run without public embedding mode exposure, via direct setting of `vm.effect_mode`.
* **"What these legs can catch" ([`docs/design/60-hand-written-machine-code.md:1740-1747`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L1740-L1747)):** Completely truthful. `hostcall_x64.S` contains zero references to `effect_mode`, `effect_log`, or `effect_cursor`. The assembly entry is oblivious to effect recording/replaying; the legs confirm that H3 does not perturb guest effect sequencing, GC rooting of the log, or uncatchable error propagation compared to H1.

---

### Findings

#### Finding 1: Assert exact admission count rather than `>= 21`
* **Severity:** Nit / Minor improvement
* **Location:** [`src/capi_hostcall_test.zig:1438-1440`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1438-L1440)
* **Problem:** `try testing.expect(capi.hostcall_counts.chain - chain_before >= 21)` verifies that all 21 calls were admitted, but using `>=` with `testing.expect` is looser than necessary and provides no diagnostics if it fails. Because the scenario makes exactly 21 calls in leg 0 (20 top-level + 1 nested), asserting `try testing.expectEqual(@as(usize, 21), capi.hostcall_counts.chain - chain_before)` would strictly verify that no unexpected extra calls occurred and print expected vs. actual values on mismatch.

#### Finding 2: Ambiguous phrasing in the 21-call comment
* **Severity:** Nit (documentation clarity)
* **Location:** [`src/capi_hostcall_test.zig:1436-1437`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1436-L1437)
* **Problem:** The comment states: `// In stage 2 the .S entry admitted every one of the 21 calls above (and the nested ones)...`. A reader might interpret "the 21 calls above (and the nested ones)" as 21 top-level calls *plus* nested ones (totaling 22). Phrasing it as `every one of the 21 calls above (20 top-level calls plus the nested one inside effnest)` would clarify the count.
