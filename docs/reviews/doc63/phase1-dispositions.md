# Doc 63 Phase 1 — review dispositions

Round 1: `codex-phase1.md` (changes requested), `antigravity-phase1.md`
(accept with test fixes).

| Finding | Disposition |
|---|---|
| Codex 1: suspended back-edges write `pending_anchor_base` before the gate; `afterBackEdge` (and `armShortLoopSkip`) still run | **Fixed.** `backEdgeEpilogue` skips the whole slow path after `skipBackEdge`'s counting while suspended. `onBackEdge`'s early return becomes an assert, because its one caller is now gated. Tests: in a cached unpatched entry and an active outer recording across a callback loop with a different frame base, `pending_anchor_base` is unchanged. Removing the gate trips the assert in every suspended test. |
| Codex 2: `run`/`start` go through `exec` → `execWith`, which doesn't bump | **Fixed.** `Vm.exec` bumps. Pinned by `Vm.run` of a call-free chunk moving the epoch by exactly 1, and mutation-checked. §5.9.1 now says the C API runs chunks as closures through `callValue`. |
| Codex 3: grouped epoch tests can pass with a named bump removed; `mhCallViaH1` untested | **Fixed.** Every non-exempt C API entry is called with an argument it rejects right after its bump: delta exactly 1, with no deeper site reachable. `mh_collect` is pinned at exactly 2. `mhCallViaH1` and `hostcallReference` are covered. The core sites are pinned by exact delta (`exec` 1, native `callValue` 1, closure `callValue` 2, `mh_run` 3, `collect` 1, `deflateGrid` 1). Each of the five core bumps was removed by hand, one at a time, and each removal failed its test. |
| Codex 4: suspension tests don't establish coverage | **Fixed.** Each of `work`/`wloop`/`fib` has its own suspended-vs-control entry check. All patches (all four kinds) are marked pending and survive suspended visits, then settle. A cached *unpatched* entry test uses native codegen off. A real active outer recording is reached by stepping `suspend_ctl` and is untouched by a suspended callback: IR, path, constants, base, pending anchor, trace count. The outer run then resumes correctly. `abortRaised` is tested on a real recording, with a control. |
| Codex 5: "+11 per host call" overstates; "within noise" unsupported | **Fixed.** The per-shape table lists the disturbing shapes (+19/+23/+19/+21). Repeat spread was measured: 0.00% on every row, so the deltas are real costs and §5.9.1 says so. The first cut's real cost on the patched-handler hot path (euler14-bit JIT +0.22%) was removed: suspension became a `fast_block` bit, and `Vm.jitSuspended(mode)` is comptime false in `.fast` (now −0.01%). The remaining stdlib-heavy tier-0 cost (≤ +0.18%) was traced to `opCall` register allocation. It is recorded as an Outstanding decision for Bart. |
| Codex 6: contradictory wording (readers; "third path needs no gate") | **Fixed.** §5.9.1 now says `callHostNative` maintains the values but nothing acts on them until Phase 2c, and that all three paths are gated. |
| AG 1: `abortRaised` test lacks a control | **Fixed** (see Codex 4). |
| AG 2: `mhCallViaH1` not tested | **Fixed** (see Codex 3). |
| AG 3: `mh_vm_new`/`mh_vm_free` exemptions untested | **Fixed.** Creating and freeing another VM leaves this VM's epoch alone. A refused `mh_vm_free` from inside a host call returns `err_api` and leaves the epoch alone. |
| AG 4: ungated `pending_anchor_base` write | **Fixed** (see Codex 1). |
| AG 5: `hostcallReference` lacks the boundary bump | **Fixed.** It bumps like `mh_call` and is tested. |
| AG §3: `setRegionContext` in the region gap | **Accepted.** Named in §5.9.1 under the region-accounting item, which stays Outstanding. |

Round 2 (confirmation): `codex-phase1-r2.md` (approve, doc nits) and
`antigravity-phase1-r2.md` (accept, doc nits).

| Finding | Disposition |
|---|---|
| Codex r2-1 / AG r2-2: the checklist's "no reader" and the unqualified "+11" | **Fixed.** A Phase 1 sub-bullet says "no reader" means no guard or admission reader. The checklist and the Outstanding decision now list +11 per pure host call, +19–23 for disturbing hosts, and the tier-0 rows. |
| Codex r2-2 / AG r2-1: the recording-feed row overstates `dispatchPostObserve`'s gate; the asserts don't run in every test | **Fixed.** The row lists steps 8–11 as they are, and notes that the region observer (step 5) precedes it, ungated. The assert claim is limited to tests whose suspended callback reaches those paths. |
| Codex r2 note: the bit doesn't switch an already-running `.fast` chain; raise/lower ordering around the call is essential | **Accepted.** That ordering is §5.8's shim contract (raise before the call, lower after it) and Phase 2c's `callHostNative` rule. Phase 1 has no production raiser. |
