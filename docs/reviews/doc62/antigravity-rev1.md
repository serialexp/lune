# Doc 62 rev 1 — antigravity review (2026-10-05)

Reviewed the doc plus the uncommitted implementation; ran `just test`, `just hashgate`, `just embed-test`. Verbatim reply below.

---

## Verdict

**APPROVE**

The design in [docs/design/62-global-slot-hints.md](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md) and its implementation across `src/hash_part.zig`, `src/table.zig`, `src/interp.zig`, `src/nativegen_emit.zig`, and related files are sound, correct, and adhere strictly to mahina’s architecture principles (determinism, id-based identity, Rule Z-1 through Z-7).

All test gates pass cleanly:
- `just test` (unit tests and boundary checks pass)
- `just hashgate` (87 digests match in ReleaseFast and Debug across all 29 programs × 3 execution modes)
- `just embed-test` (C API and Rust workspace integration tests pass)

Below is the detailed evaluation addressing each of the focus areas, followed by Should-fix and Nit recommendations.

---

## Detailed Soundness Evaluation

### 1. Soundness of Slot Hints
A slot hint **cannot change any runtime result** under any condition:
- **`opGetGlobal` fast-path ([`src/interp.zig:6276-6286`](file:///home/bart/Projects/lune/src/interp.zig#L6276-L6286)) & `heapHintHit` ([`src/hash_part.zig:224-229`](file:///home/bart/Projects/lune/src/hash_part.zig#L224-L229))**:
  A hit strictly requires:
  1. `key.isHeap()` is true.
  2. `hintedNode(hint)` is non-null (`hint <= mask`).
  3. `n.key_tag == .heap_ref`.
  4. `n.key_id == key.asHeap().id`.
  5. `!n.value.isNil()`.
  Under open-addressing linear probing without duplicates (doc 49), a key exists at **at most one slot** in the table (dead or live). Finding a node matching both the tag and the unique `key_id` with a non-nil value proves this slot is the uniquely active logical entry for that key.
- **Dead slots**: When deleted via `remove` ([`src/hash_part.zig:320-329`](file:///home/bart/Projects/lune/src/hash_part.zig#L320-L329)), `n.value = nil`. Both `heapHintHit` and `setExistingHinted` check `!n.value.isNil()`. A dead slot immediately triggers a miss in `heapHintHit` and falls through in `setExistingHinted`.
- **Rehash and shrink**: If the table reallocates or shrinks:
  - If `hint > mask`, [`hintedNode`](file:///home/bart/Projects/lune/src/hash_part.zig#L235-L240) returns `null` via bounds check.
  - If `hint <= mask`, either the slot is free (`n.key_tag == .nil`), holds another key (`n.key_id != key.asHeap().id`), or holds the same key. A match only succeeds if the key landed in the exact same slot index.
- **Grid tables**: Handled in [`src/table.zig:158`](file:///home/bart/Projects/lune/src/table.zig#L158) with an explicit `!self.array.isGrid()` check; furthermore, outer grid access deflates before generic indexing ([`src/interp.zig:7451-7457`](file:///home/bart/Projects/lune/src/interp.zig#L7451-L7457)).
- **`_G` / `rawset` writes**: Table writes through `_G.x = v` or `rawset(_G, "x", v)` go through `Table.set`. If `"x"` was already present, `Table.set` updates `n.value` in place at the same slot, so subsequent hint reads immediately observe the new value. If `"x"` was moved or inserted elsewhere, the hint misses and relocates.
- **Restored VMs & cross-VM Proto sharing**: Because `GcHeader.id` is preserved across keyframe capture and restore, `key.asHeap().id` remains consistent with the proto’s interned string constants. If two VMs run the same proto sequentially with different globals layouts, the hint simply pings to the respective slot without returning incorrect values or memory faults.

---

### 2. Equivalence of `Ident.matches` and `Value.eql`
[`Ident.matches`](file:///home/bart/Projects/lune/src/hash_part.zig#L138-L141) is **exactly equivalent** to [`Value.eql`](file:///home/bart/Projects/lune/src/value.zig#L252-L270) for all keys that can reach the hash part:
- **Heap objects (`.heap_ref`)**: Both compare `id: u32` (`GcHeader.id`). Pointer identity is never used for equality.
- **Integers (`.int`)**: `Ident.bits` compares `k.payload.bits`, which represents the 64-bit two's-complement integer.
- **Floats (`.float`)**:
  - All integral floats within `i64` range (including `+0.0` and `-0.0`) are normalized to `Value.int` by [`normalizeKey`](file:///home/bart/Projects/lune/src/table.zig#L660-L675) before reaching `HashPart`. Specifically, for `-0.0`: `@floor(-0.0) == -0.0` is true and `@intFromFloat(-0.0)` produces `0` (`i64`), normalizing `-0.0` to `Value.int(0)`.
  - Non-integral floats and floats outside `i64` range have unique 64-bit IEEE-754 bit representations (excluding NaN and ±0.0). Comparing raw payload bits is therefore identical to numerical equality.
  - Float `NaN` cannot be stored in the table; [`Table.set`](file:///home/bart/Projects/lune/src/table.zig#L317) errors with `TypeError`.
- **Booleans (`.boolean`)**: Booleans are constructed with bits 0 or 1 ([`src/value.zig:97`](file:///home/bart/Projects/lune/src/value.zig#L97)); bit comparison matches boolean equality.
- **`row_view`**: Asserted in [`Ident.of`](file:///home/bart/Projects/lune/src/hash_part.zig#L132) (`std.debug.assert(k.tag != .row_view)`). Row views are transient values that never persist in heap tables (doc 14 and doc 49).

---

### 3. Node Layout, Invariants, and Consumers
- **Node Geometry**:
  [`src/hash_part.zig:76-85`](file:///home/bart/Projects/lune/src/hash_part.zig#L76-L85) uses bytes 4–7 (padding in `Value`) for `key_id: u32`. The node remains 32 bytes and 32-byte aligned. All offsets are verified with comptime assertions in [`src/hash_part.zig:110-118`](file:///home/bart/Projects/lune/src/hash_part.zig#L110-L118) and [`src/nativegen_layout.zig:110-128`](file:///home/bart/Projects/lune/src/nativegen_layout.zig#L110-L128).
- **GC Marking ([`src/gc.zig:693-698`](file:///home/bart/Projects/lune/src/gc.zig#L693-L698))**:
  `Heap.markRoots` iterates `t.hash.iterator()`, which yields live entries only ([`src/hash_part.zig:345`](file:///home/bart/Projects/lune/src/hash_part.zig#L345)). Dead and free nodes are skipped. For live nodes, `entry.key` constructs a valid `Value` using `key_payload.ptr`, which the collector marks.
- **Dead-Node Pointer Freedom ([`src/hash_part.zig:325-327`](file:///home/bart/Projects/lune/src/hash_part.zig#L325-L327))**:
  On removal, `n.key_payload = .{ .bits = 0 }` for heap keys while preserving `key_id`. Dead heap nodes hold a null pointer, ensuring collectability of deleted key objects immediately.
- **Publication Ordering**:
  - `remove` writes `n.value = nil` *before* zeroing `n.key_payload`.
  - `put` (resurrect or reuse) calls `n.setKey(key, ident)` *before* writing `n.value = val`.
  The invariant "non-nil value $\Rightarrow$ valid live key pointer" holds at every stage.
- **hrefk Guard Ordering ([`src/nativegen_emit.zig:2223-2232`](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L2223-L2232))**:
  Guard 2 (live value) still precedes Guard 4 (key identity). Guard 4 compares `[node + NODE_KEY_ID_OFF]` directly against `key_id`, avoiding the pointer dereference through `[node + NODE_KEY_PAYLOAD_OFF]` and releasing scratch register `rcx`.
- **Keyframe Serialization Determinism ([`src/keyframeser.zig:132-137`](file:///home/bart/Projects/lune/src/keyframeser.zig#L132-L137))**:
  Entries are extracted via `t.hash.iterator()` and sorted canonically using `HashKV.lessThan`. `Proto.global_slot_hints` is runtime cache data and is not serialized.
- **Consumers**:
  Exhaustive greps confirmed that all consumers of `HashPart.iterator()` have been transitioned from `e.key_ptr.*` to `e.key` ([`src/capi.zig:1375`](file:///home/bart/Projects/lune/src/capi.zig#L1375), [`src/gc.zig:696`](file:///home/bart/Projects/lune/src/gc.zig#L696), [`src/keyframeser.zig:135`](file:///home/bart/Projects/lune/src/keyframeser.zig#L135), [`src/stdlib/base.zig:102`](file:///home/bart/Projects/lune/src/stdlib/base.zig#L102), [`src/table.zig:531`](file:///home/bart/Projects/lune/src/table.zig#L531), [`src/capi_hostcall_test.zig:214`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L214)).

---

### 4. `Table.setHinted` Equivalence and Write Barrier
In [`src/table.zig:155-163`](file:///home/bart/Projects/lune/src/table.zig#L155-L163):
```zig
pub fn setHinted(self: *Table, gpa: std.mem.Allocator, key: Value, val: Value, hint: *u32) Error!void {
    const nk = normalizeKey(key);
    const hashed = !nk.isInt() and !nk.isNil();
    if (hashed and !self.array.isGrid() and self.hash.setExistingHinted(nk, val, hint.*)) return;
    try self.set(gpa, key, val);
    if (hashed and !val.isNil()) {
        if (self.hash.liveSlotOf(nk)) |slot| hint.* = slot;
    }
}
```
- **In-place overwrite equivalence**: For a live non-integer key and non-nil value, `Table.set` delegates to `HashPart.put`, which executes `probeForPut` $\rightarrow$ `.live => |idx| self.nodes.?[idx].value = val; return;`. It touches no array partition, changes neither `live` nor `used` counts, and triggers no rehash. `setExistingHinted` does this exact overwrite.
- **Write barrier**: In [`src/interp.zig:6330`](file:///home/bart/Projects/lune/src/interp.zig#L6330), `self.heap.writeBarrier(&self.globals.header, v)` is executed unconditionally after `setHinted` (or `set`) completes, maintaining GC barrier semantics.

---

### 5. Volatile-Var Tail-Call Trick in `opGetGlobal`
In [`src/interp.zig:6292-6294`](file:///home/bart/Projects/lune/src/interp.zig#L6292-L6294):
```zig
const slow: *volatile const *const HandlerFn = &GetGlobalSlow(mode).handler;
return @call(.always_tail, slow.*, .{ st, pc, instr, vm, tags, payloads });
```
- **Correctness & Safety**: `GetGlobalSlow(mode).handler` is statically allocated and initialized to `&h`. The volatile load forces an indirect read from static memory, preventing LLVM from inlining the slow path into `opGetGlobal` while preserving the `.always_tail` contract.
- **Threading**: The variable is read-only after initialization; concurrent reads across threads are data-race-free.
- **Design alignment**: Documented in `TODO.md` as an accepted solution approved by Bart pending future Zig attributes or a centralized dispatcher slow-path table.

---

### 6. Doc Claims vs. Code
All claims in [docs/design/62-global-slot-hints.md](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md) and the follow-up note in [docs/design/49-owned-hash-part-hrefk.md](file:///home/bart/Projects/lune/docs/design/49-owned-hash-part-hrefk.md) match the code:
- Node layout and state transitions (§3.1, §3.2) match [`src/hash_part.zig`](file:///home/bart/Projects/lune/src/hash_part.zig).
- `Proto.global_slot_hints` allocation and lifecycle (§4.1) match [`src/bytecode.zig`](file:///home/bart/Projects/lune/src/bytecode.zig) and [`src/compiler.zig`](file:///home/bart/Projects/lune/src/compiler.zig).
- Fallback and tail-call dispatch (§4.3) match [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig).
- Test matrix (§6) accurately reflects the test cases in [`src/hash_part.zig`](file:///home/bart/Projects/lune/src/hash_part.zig) and [`src/interp_semantics_test.zig`](file:///home/bart/Projects/lune/src/interp_semantics_test.zig).

---

## Blockers
*None.*

---

## Should-fix

1. **Add explicit test for `set_global` with a hand-built Proto (`hints.len == 0`)**
   - **Evidence**: [`src/interp.zig:6327-6330`](file:///home/bart/Projects/lune/src/interp.zig#L6327-L6330)
   - **Rationale**: `opGetGlobal` has a test with a hand-built proto without hints ([`src/interp_bytecode_test.zig:418`](file:///home/bart/Projects/lune/src/interp_bytecode_test.zig#L418)). `opSetGlobal` has a branch for `instr.b >= hints.len`:
     ```zig
     const stored = if (instr.b < hints.len)
         self.globals.setHinted(self.gpa, key, v, &hints[instr.b])
     else
         self.globals.set(self.gpa, key, v);
     ```
     Adding a 10-line test in `src/interp_bytecode_test.zig` that runs `set_global` on a hand-built `Proto` (where `global_slot_hints.len == 0`) ensures this fallback branch is directly pinned under tests (Rule Z-3).

2. **Add a multi-VM Proto sharing test**
   - **Evidence**: [docs/design/62-global-slot-hints.md §4.4](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md#L234-L243)
   - **Rationale**: The doc specifically discusses that two VMs running the same compiled `*const Proto` will share and oscillate the hint words if their globals layouts differ. A unit test in `src/interp_semantics_test.zig` compiling one Proto and executing it alternatively in two distinct `Vm` instances (with differing global sets) would verify this behavior under leak-checked conditions.

---

## Nits

1. **Clarify doc §3.4 on `capi_hostcall_test.zig` line 311**
   - **Evidence**: [docs/design/62-global-slot-hints.md §3.4](file:///home/bart/Projects/lune/docs/design/62-global-slot-hints.md#L159-L160)
   - **Detail**: Doc 62 lists `capi_hostcall_test.zig` under updated callers of `t.hash.iterator()`. Note that `src/capi_hostcall_test.zig:311` was `pol.region_profit.iterator()` (a `std.AutoHashMapUnmanaged`), whereas line 214 was the real `t.hash.iterator()`.

2. **Redundant check in `HashPart.getHinted` on miss from `opGetGlobal`**
   - **Evidence**: [`src/hash_part.zig:211-213`](file:///home/bart/Projects/lune/src/hash_part.zig#L211-L213)
   - **Detail**: When `opGetGlobal` misses, `heapHintHit` has already checked `hintedNode(hint)`. Falling through to `GetGlobalSlow` calls `Table.getHinted` $\rightarrow$ `HashPart.getHinted`, which re-checks `self.hintedNode(hint.*)`. For standalone calls to `HashPart.getHinted` this is needed, so keeping it is completely acceptable; a brief comment clarifying that `heapHintHit` callers already performed this check on fast-path misses would aid readability.
