# Antigravity — doc 60 H3 review, round 4: confirmation (2026-10-05)

### Confirmation Review: Doc 60 Record/Replay Legs (Round 3 Fixes)

**Verdict:** **APPROVE**

---

### Verification Summary

All four items addressed in [`src/capi_hostcall_test.zig`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig) and recorded in [`docs/design/60-hand-written-machine-code.md`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L2160-L2172) have been verified:

#### 1. Traceable loop & compilation assertion (`effloop`)
* **Location:** [`src/capi_hostcall_test.zig:1386-1390`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1386-L1390), [`1436-1440`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1436-L1440)
* **Status:** **Correct.**
* **Details:** `effloop` now places the effect natives `os.nsclock()` strictly before (`local acc = os.nsclock()`) and after (`return acc + os.nsclock()`) the plain `for i = 1, n do acc = acc + i end` loop. The inner loop contains no uncompilable effect natives, allowing trace recording to proceed without aborting. Across the 12 invocations ($120$ iterations), `vm.trace.registry.cache.items.len > traces_before` is asserted and verified when `pr.tier != .off`, confirming tier-up on both `tier1` and `native`.

#### 2. Keyframe exclusion for host function registration
* **Location:** [`src/capi_hostcall_test.zig:1412`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1412)
* **Status:** **Correct.**
* **Details:** `pr.keyframes = false` is now set prior to registering the `reenter` host function callback (`capi.mh_register_fn`). This adheres to the contract in doc 59 E8 and doc 60 §6.2 (keyframes are excluded when host functions are registered), bringing this scenario into alignment with all other callback fixtures in `capi_hostcall_test.zig`.

#### 3. Strict admission check (`expectEqual(21, …)`)
* **Location:** [`src/capi_hostcall_test.zig:1448-1450`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1448-L1450)
* **Status:** **Correct.**
* **Details:** Replaced the loose `>= 21` check with `try testing.expectEqual(@as(usize, 21), capi.hostcall_counts.chain - chain_before)`. This strictly verifies that exactly 21 calls entered and executed through the hand-written machine code `.S` entry's `chain` path without fallback.

#### 4. Clarified call accounting comment
* **Location:** [`src/capi_hostcall_test.zig:1445-1447`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1445-L1447)
* **Status:** **Correct.**
* **Details:** Comment now reads: `// In stage 2 the .S entry admitted all 21 calls: the 20 above and the nested one inside effnest, so it ran them under each mode.`, which eliminates any ambiguity about the call count ($2 \times \text{eff} + 1 \times \text{effnest} + 1 \times \text{effboom} + 1 \times \text{effmany} + 1 \times \text{eff} + 1 \times \text{effva} + 12 \times \text{effloop} + 1 \times \text{effupper} = 20\text{ outer} + 1\text{ nested} = 21$).

#### 5. Documentation update in Doc 60
* **Location:** [`docs/design/60-hand-written-machine-code.md:2160-2172`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L2160-L2172)
* **Status:** **Correct.**
* **Details:** §10's Round 3 review table accurately records the disposition for all four findings across both reviews (`codex-h3-r3.md` and `antigravity-h3-r3.md`).

---

### Test Execution

The test `"hostcall diff: effects through every path of the entry, recorded and replayed"` was executed using temporary `/tmp` prefixes and caches:
- **Debug:** Passed cleanly (`code 0`).
- **ReleaseFast:** Passed cleanly (`code 0`).

No repo files were modified, no git state was mutated, and all scratch directories in `/tmp` were cleaned up.
