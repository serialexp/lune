# Doc 62 rev 2 — codex review (2026-10-05)

Thread 01a109e6-3da3-7ff3-9a45-c94ce7760b08 (the first rev-2 attempt failed with "model at capacity"; this is the retry). Verbatim reply below.

---

## Verdict: APPROVE

Bart, rev 2 closes the C-boundary blocker. I found no remaining soundness blocker for canonical `Value`s under the documented threading constraints.

## Blockers

None.

- [`fromC`](/home/bart/Projects/lune/src/capi.zig:300) rejects boolean payloads above 1. The [assembly argument check](/home/bart/Projects/lune/src/asm/hostcall_x64.S:167) uses unsigned `ja` and runs before committing VM state. [Callback results](/home/bart/Projects/lune/src/capi.zig:1132) pass through the same validation.
- The added tests cover [shrink, rebuild and dead-slot reuse](/home/bart/Projects/lune/src/hash_part.zig:781), [same-id hits on all three hinted paths](/home/bart/Projects/lune/src/hash_part.zig:844), [alternating original/restored VMs sharing protos](/home/bart/Projects/lune/src/keyframeser_restore_test.zig:320), and [hand-built protos without hints](/home/bart/Projects/lune/src/interp_bytecode_test.zig:423).
- The [Proto comment](/home/bart/Projects/lune/src/bytecode.zig:633) now states the shared-proto threading restriction. The GC, publication, hrefk guard-ordering and serialization conclusions from rev 1 remain unchanged.

## Should-fix

1. **Document canonical booleans as a requirement for trusted Zig callers.** [Doc 62](/home/bart/Projects/lune/docs/design/62-global-slot-hints.md:183) says C was the only possible ingress for other payloads. Public [`Value` fields](/home/bart/Projects/lune/src/value.zig:63) and Zig [`NativeFn`/`HostFn`](/home/bart/Projects/lune/src/function.zig:140) can bypass `fromC`. State their 0/1 precondition beside those APIs and qualify the doc’s claim. This is a documentation issue under Bart’s chosen boundary policy.

2. **Persist the callback-result regression case.** The new tests exercise malformed [C input](/home/bart/Projects/lune/src/capi_test.zig:480) and [hostcall arguments](/home/bart/Projects/lune/src/capi_hostcall_test.zig:756). Add a callback returning payload 11, followed by a valid call proving the VM remains usable. A high-bit argument would also pin the assembly comparison’s unsigned behavior. Both cases passed my scratch probe.

## Nits

1. [Doc 62’s “every API … fails with `MH_ERR_API`”](/home/bart/Projects/lune/docs/design/62-global-slot-hints.md:190) is too broad: [`mh_value_type`](/home/bart/Projects/lune/src/capi.zig:930) returns `.other`, and `mh_value_truthy` returns 0 for invalid values.

2. The [instruction-count claim](/home/bart/Projects/lune/docs/design/62-global-slot-hints.md:193) omits branches. The added check executes two instructions for non-booleans and four for booleans; update doc 60’s corresponding claim too.

I independently ran `just test` in an isolated `/tmp` copy, plus boundary and dead-slot-reuse probes; all passed. `git diff --check` was clean. The repo remained untouched, with no mutating Git operations. I kept all 23 global rules and 8 project rules in mind.
