# Codex — Prerequisite A implementation review (round 1, 2026-10-10)

Verbatim reply. Dispositions in `prereqA-dispositions.md`.

---

REJECT

1. **[blocker] Native helper snapshots lack liveness protection.** [`requiresPreciseSnapshot`](/home/bart/Projects/lune/src/trace_ir.zig:887) excludes all nine allocating string ops. Consequently, [`nativegen_alloc`](/home/bart/Projects/lune/src/nativegen_alloc.zig:885) skips their snapshot refs, although the new error path [materializes those snapshots](/home/bart/Projects/lune/src/nativegen.zig:2757). Earlier operations within the same bytecode—`smatch`, integer projections, or preceding captures—can reuse a captured value’s register. The flush can then restore incorrect values, including invalid heap references. The same omission bypasses snapshot admission checks. **Fix:** include these helpers in the shared precise-snapshot predicate; test a multi-capture failure with register reuse and verify the restored window, plus rejection of missing snapshots.

2. **[should-fix] Tests do not establish coverage of every helper.** [`checkCase`](/home/bart/Projects/lune/src/interp_trace_test.zig:6911) requires only one precise error; `tnew` or preliminary `ssub` can satisfy it. [`has_op`](/home/bart/Projects/lune/src/interp_trace_test.zig:6860) proves cache presence, not that the named helper failed while traced. Additionally, [`checkTostr`](/home/bart/Projects/lune/src/interp_trace_test.zig:6904) covers only `tostr_int`. **Fix:** add a nonintegral float fixture and require an observed precise error at each targeted opcode in both tiers. Generic mutation checks do not establish that individual coverage.

3. **[nit] The ordinary-OOM TODO overstates the architectural restriction.** [`TODO.md:190`](/home/bart/Projects/lune/TODO.md:190) says only precise traces have resumable state. Ordinary traces already have [bytecode-boundary snapshots](/home/bart/Projects/lune/src/trace_recorder.zig:1391) and doc 56’s resume-coherent materialization. **Fix:** describe the missing *helper-error integration* and include extending that machinery as another option.

4. **[nit] Doc bookkeeping needs correction.** The removed `Outstanding` heading leaves unchecked phases under [`Done`](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:39). [`§5.4`](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:420) also describes the old null protocol in present tense and implies stale scratch necessarily raises; the [core’s contract](/home/bart/Projects/lune/src/stdlib/string.zig:1399) allows a value or an error after replay. **Fix:** restore the heading, make the old behavior historical, and distinguish the two decline outcomes.

Otherwise, the failure-word mappings, `rcx` preservation, snapshot/status store ordering, and ordinary/no-heap error handling look consistent.

Bart, I kept all supplied rules in mind. This review was read-only; I excluded the unrelated hunks and did not rerun the reported gates.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
