# Codex — doc 60 H3 implementation review (2026-10-04)

**CHANGES REQUESTED**

Bart, I found no concrete production defect in the assembly. The blocking finding is a demonstrated gap in coverage of a memory-safety check.

1. **Blocking — [src/capi_hostcall_test.zig:1315](/home/bart/Projects/lune/src/capi_hostcall_test.zig:1315): H3’s surplus-vararg capacity check is untested at the boundary.** The outer capacity sweep uses roughly 65K arguments, so H3 rejects it at `nargs > 8`; its nested call targets non-vararg `w40`. Neither exercises the surplus-vararg capacity calculation near exhaustion. In a `/tmp` copy, replacing [hostcall_x64.S:185](/home/bart/Projects/lune/src/asm/hostcall_x64.S:185)’s `add %r8, %rax` with `nop` still passed all 22 filtered C API tests, including the admission test, in Debug. That mutation admits calls whose two-region layout exceeds register capacity. Add an H3-eligible surplus-vararg call at exact fit and one slot beyond capacity, and prove its admission/fallback behavior.

2. **Non-blocking — [docs/design/60-hand-written-machine-code.md:162](/home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md:162): the counter coverage is overstated.** The checklist says the counter proves that *each scenario* takes its intended path. Only the dedicated admission test checks counter deltas; `Pair.call` never does. A scenario-specific fallback regression can therefore compare H1 against itself unnoticed. Narrow the claim or assert the expected path in the relevant scenarios.

3. **Non-blocking — [docs/design/60-hand-written-machine-code.md:1601](/home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md:1601): instruction counts do not establish whether a cycle improvement is real.** More instructions can execute faster through reduced dependencies, stalls, or better scheduling. The statement that `r0` and `overflow` “are not wins” does not follow from their instruction increases, and conflicts with line 1593’s claim that every admitted shape meets the cycle criterion. Describe those timing results as uncertain if noise prevents classification.

I see no additional H3-specific soundness reason that requires the unavailable embedding record/replay mode: H3 uses the same runner and effect machinery as H1. Those legs remain unverified, and the documented landing decision still belongs to you. `next_call_seq` exhaustion also remains untested, as already disclosed.

The baseline filtered hostcall and admission tests passed in Debug and ReleaseFast. ReleaseFast acceptance passed visibility, linking, fixture execution, and tail-call checks. Gdb walks could not run because the sandbox denied `ptrace`; I inspected the source and emitted CFI instead.

I kept all 31 numbered rules in mind. The repo remained read-only.

[Codex thread: 01a10647-d722-7460-9f2d-e77f58a2c4fa]
