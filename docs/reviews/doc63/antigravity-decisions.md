APPROVE

The uncommitted changes across [`docs/design/63-trace-host-calls.md`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md) and [`TODO.md`](file:///home/bart/Projects/lune/TODO.md) faithfully record Bart's decisions on Q1–Q5 and remain consistent with the rest of the document.

### Verification Summary

1. **Header ([`docs/design/63-trace-host-calls.md#L3-L7`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L3-L7))**:
   - Accurately updated from awaiting decisions on Q1–Q4 to: `Q1–Q5 decided by Bart (2026-10-10; §9).`

2. **Done Checklist ([`docs/design/63-trace-host-calls.md#L16-L30`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L16-L30))**:
   - Replaced `_(nothing yet)_` with checked items (`- [x]`) for decisions Q1 through Q5, all timestamped `(Bart, 2026-10-10)`.
   - Removed old unresolved question bullets from Outstanding.
   - Specifically records:
     - **Q1**: Yes (amend doc 00/02 commitment with Phase 2c).
     - **Q2**: Yes (callbacks run with JIT suspended in v1).
     - **Q3**: Part of this plan, as Phase 4.
     - **Q4**: Disturbance threshold 1, like LuaJIT.
     - **Q5**: Multret host calls deferred past v1, tracked in `TODO.md`.

3. **Phase 4 Outstanding Item ([`docs/design/63-trace-host-calls.md#L70`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L70))**:
   - Accurately updated from conditional `(only if Q3 says so; §5.12)` to confirmed `(§5.12; Q3: part of this plan)` while remaining an open work item in Outstanding.

4. **Section 9 ([`docs/design/63-trace-host-calls.md#L985-L999`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L985-L999))**:
   - Section title updated to `## 9. Open questions for review (decided 2026-10-10)`.
   - Each of Q1–Q5 has Bart's explicit decision appended inline in bold.

5. **TODO.md Entry ([`TODO.md#L167-L174`](file:///home/bart/Projects/lune/TODO.md#L167-L174))**:
   - Added `## Traced host calls: multret arguments and results (deferred 2026-10-10)`.
   - Conforms to standard `TODO.md` deferred item formatting; records why multret argument/result handling (`c == all_results` or producer feed) is a `host_barrier` in v1, references doc 27, and attributes the deferral to Bart (Q5).

6. **Document Consistency**:
   - Aligns with §5.3 ([line 387](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L387)), which already treats multret as deferred (`Doc 27 is deferred (Q5);`).
   - Aligns with §5.9 ([lines 713, 726](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L713-L726)), which already specified threshold 1 as the primary design.

---

### Non-blocking Observations (Optional Polish)

These do not block approval, but could be polished in a future edit if desired:
- **[§5.12 Heading](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L814)**: Still reads `### 5.12 Leaf host functions (optional, Q3)`. Since Q3 is decided and integrated into the plan as Phase 4, the label could eventually be updated to `(Phase 4, Q3)` or simply `(Phase 4)`.
- **[§6 Text](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L894)**: Still says prospective `Bart decides (Q1).` instead of `Decided by Bart (Q1: yes).`
