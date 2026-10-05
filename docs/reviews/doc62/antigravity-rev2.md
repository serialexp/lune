# Doc 62 Rev 2 Review — Antigravity

Re-reviewed [docs/design/62-global-slot-hints.md](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md) (rev 2) along with its uncommitted implementation in `/home/bart/Projects/lune`.

---

## Verdict

**APPROVE**

All findings from the rev 1 reviews (Codex’s blocker on non-canonical boolean payloads, Codex’s should-fix and nits, and Antigravity’s should-fix items) have been cleanly addressed, thoroughly tested, and accurately reflected in the design document and review ledger.

All automated verification gates passed:
- `just test`: PASS (unit tests, bytecode tests, semantic tests, and JIT production boundary checks).
- `just embed-test`: PASS (27 Rust integration tests, 2 `mahina_sys` tests, doc tests, and C API smoke test).
- `just hashgate`: PASS (all 87 digests match across 29 programs $\times$ 3 execution modes in both `ReleaseFast` and `Debug`).

---

## Audit of Rev-2 Changes

### 1. Codex Blocker: Non-Canonical Boolean Payloads Rejected at C Ingress
Bart’s design decision to reject non-0/1 boolean payloads at the boundary maintains the invariant that every `Value` inside the VM with `tag == .boolean` has payload `0` or `1`. Under this invariant, raw bit comparison in [`Ident.matches`](file:///home/bart/Projects/lune/src/hash_part.zig#L138-L141) is identical to [`Value.eql`](file:///home/bart/Projects/lune/src/value.zig#L252-L270) for all hash-part keys.

- **C API validation**: [`src/capi.zig:300`](file:///home/bart/Projects/lune/src/capi.zig#L300) in `fromC`:
  ```zig
  if (cv.tag == @intFromEnum(value.Tag.boolean) and cv.payload > 1) return null;
  ```
  Returns `null` (`mh_status.err_api`) for any `mh_value` with boolean payload $> 1$.
- **Host callback returns**: [`src/capi.zig:1130-1133`](file:///home/bart/Projects/lune/src/capi.zig#L1130-L1133) in `cHostCall`:
  ```zig
  for (raw[0..n]) |cv| {
      if (fromC(cv) == null) return error.TypeError;
  }
  ```
  Rejects invalid boolean payloads returned by host C functions with `error.TypeError`.
- **Fast-path hostcall entry**: Checked below.
- **Offset table & constants**: Added `TAG_BOOLEAN` to [`src/asm/offsets_x64.inc:92`](file:///home/bart/Projects/lune/src/asm/offsets_x64.inc#L92) and verified in [`src/asm/offsets_x64.zig:157`](file:///home/bart/Projects/lune/src/asm/offsets_x64.zig#L157). Also accounts for the $+16$-byte shift in `Proto` fields (`PROTO_NUM_REGISTERS: 188`, `PROTO_NUM_PARAMS: 190`, `PROTO_IS_VARARG: 191`) caused by `global_slot_hints: []u32`.
- **Tests**:
  - [`src/capi_test.zig:478-485`](file:///home/bart/Projects/lune/src/capi_test.zig#L478-L485): verifies that `wide_true: mh_value = .{ .tag = 1, .payload = 11 }` returns `err_api` via `mh_global_set`, while `mh_bool(7)` (normalized to 1) succeeds.
  - [`src/capi_hostcall_test.zig:756`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L756): verifies in `hostcall diff: invalid values are rejected identically` that payload 11 is rejected identically across all execution tiers (including the `.S` assembly fast path).
- **Docs**: Documented in [docs/design/62-global-slot-hints.md §3.5](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md#L177-L198) and [docs/design/60-hand-written-machine-code.md](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L1501-L1504).

---

### 2. Assembly Correctness: `src/asm/hostcall_x64.S`
Detailed verification of [`src/asm/hostcall_x64.S:165-178`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L165-L178):

```S
1:  cmpb $TAG_ROW_VIEW, VALUE_TAG(%r10)
    jae SYM(mahina_hostcall_slow)
    cmpb $TAG_BOOLEAN, VALUE_TAG(%r10)
    jne 7f
    cmpq $1, VALUE_PAYLOAD(%r10)
    ja SYM(mahina_hostcall_slow)
7:  cmpb $TAG_HEAP_REF, VALUE_TAG(%r10)
    jne 3f
    cmpq $0, VALUE_PAYLOAD(%r10)
    je SYM(mahina_hostcall_slow)
    inc %r11d
3:  add $VALUE_SIZE, %r10
    dec %rax
    jnz 1b
```

- **Register use**:
  - `%r10` is read-only during the check as the base pointer to the current argument `Value`.
  - `%rax` (the remaining argument counter) and `%r11d` (parked value counter) are unmodified by the boolean check.
  - No scratch registers are clobbered or required.
- **Label 7 uniqueness**:
  - Grepping across `src/asm/hostcall_x64.S` confirms label `7:` appears exactly once (at line 171). There are no other numeric label `7` definitions or references in the file, ruling out jump target ambiguity.
- **Flags and comparisons**:
  - `cmpb $TAG_BOOLEAN, VALUE_TAG(%r10)` sets flags for `jne 7f`.
  - If boolean (`tag == 1`), `cmpq $1, VALUE_PAYLOAD(%r10)` sets flags for `ja SYM(mahina_hostcall_slow)`.
  - `ja` uses unsigned comparison (`CF = 0 and ZF = 0`). Payloads `0` and `1` do not branch; payloads $> 1$ branch to `mahina_hostcall_slow`.
- **Fallthrough to the heap check**:
  - If a boolean argument is valid (`payload <= 1`), execution falls through to `7: cmpb $TAG_HEAP_REF, VALUE_TAG(%r10)`.
  - Because `TAG_BOOLEAN (1) != TAG_HEAP_REF (4)`, `cmpb` clears `ZF`.
  - `jne 3f` is unconditionally taken for booleans, properly bypassing the null heap pointer check (`cmpq $0`) and the `inc %r11d` park counter increment.
  - If the argument was not boolean (`jne 7f`), `cmpb $TAG_HEAP_REF, VALUE_TAG(%r10)` at label 7 cleanly re-evaluates condition flags on the argument tag before `jne 3f`.

---

### 3. Antigravity Rev-1 Should-Fix Items
1. **`set_global` and `get_global` on hand-built proto (`hints.len == 0`)**:
   - Implemented in [`src/interp_bytecode_test.zig:423-439`](file:///home/bart/Projects/lune/src/interp_bytecode_test.zig#L423-L439) (`test "set_global and get_global on a hand-built proto (no slot hints)"`).
   - Confirms that hand-built protos without hints fall back directly to `vm.globals.set` and `vm.globals.get`.
2. **Multi-VM Proto sharing test via keyframe restore**:
   - Implemented in [`src/keyframeser_restore_test.zig:320-385`](file:///home/bart/Projects/lune/src/keyframeser_restore_test.zig#L320-L385) (`test "doc 62: a restored VM shares its protos' global slot hints with the original, and both read their own globals"`).
   - Validates that an original and restored VM sharing `chunk.proto` alternate reading and writing globals across 6 rounds with diverging table layouts (growth, deletion) without divergence or memory faults.

---

### 4. Codex Rev-1 Should-Fix & Nits
1. **Targeted tests for physical hint transitions & same-ID hits**:
   - [`src/hash_part.zig:781-851`](file:///home/bart/Projects/lune/src/hash_part.zig#L781-L851) (`test "slot hints across shrink, same-capacity rebuild and dead-slot reuse"`):
     - Exercises `rehashTo(gpa, cap)` preserving capacity while squeezing out dead nodes.
     - Exercises `rehashTo(gpa, 16)` shrinking capacity with hints in and out of range.
     - Exercises dead-slot reuse where an inserted key reuses the deleted slot of another key, proving stale hints miss cleanly.
   - [`src/hash_part.zig:853-868`](file:///home/bart/Projects/lune/src/hash_part.zig#L853-L868) (`test "slot hints hit through another object with the same id"`):
     - Verifies `heapHintHit`, `getHinted`, and `setExistingHinted` through a separate `GcHeader` with the same `id`.
2. **Proto doc comment on threading**:
   - [`src/bytecode.zig:627-636`](file:///home/bart/Projects/lune/src/bytecode.zig#L627-L636): explicitly documents the mutability of `global_slot_hints` elements through `*const Proto` and records the requirement for synchronization across all VMs sharing a proto if the threading model ever expands beyond single-threaded VMs.
3. **Stale layout comments**:
   - [`src/hash_part.zig:21-23`](file:///home/bart/Projects/lune/src/hash_part.zig#L21-L23): updated to note zeroed payload and `key_id`.
   - [`src/nativegen_emit.zig:2191-2195`](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L2191-L2195): updated `emitHrefK` documentation.
4. **Doc 62 qualifications**:
   - [docs/design/62-global-slot-hints.md §3.3](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md#L146-L150): qualified `Value.eql` assertion scope to `liveSlotOf` during safe builds.
   - [docs/design/62-global-slot-hints.md §4.2](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md#L228-L232): qualified invalidation table outcomes.

---

## Blockers
*None.*

---

## Should-fix
*None.*

---

## Nits
*None.*
