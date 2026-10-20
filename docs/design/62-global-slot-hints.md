# 62 — Global-access slot hints and id-keyed hash nodes

Status: complete. Rev 2 approved by codex and antigravity; their should-fix items are folded in (§8). One item is deferred (below).
Owner: claude
Last updated: 2026-10-20

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis** (2026-10-05). A C host callback called from a guest loop
  (`s = s + host_id(i)`) cost ~880 instructions per iteration at tier-0. The
  `get_global host_id` before the call was ~280 of them (§1).
- [x] **B — the hash node stores the key's id** (`src/hash_part.zig`, §3).
  Probes match keys without loading the key object's header. The hrefk native
  key guard reads the id from the node too (`src/nativegen_emit.zig`).
- [x] **A — per-site slot hints for `get_global` / `set_global`**
  (`Proto.global_slot_hints`, `Table.getHinted` / `setHinted`, §4).
- [x] **The hint hit calls nothing** (§4.3). The hit path is inlined into the
  `get_global` handler, and the miss leaves by tail call, so a hit saves no
  registers.
- [x] **Tests.** HashPart: same-id/different-object keys, and stale,
  out-of-range, foreign and dead hints. Interpreter: removal, redefinition,
  rehash and `_G` writes are all seen through the cache. A mutation pass
  (§6) showed the tests catch each of three planted bugs.
- [x] **Gates.** `just test`, `just hashgate` (87 digests, release and debug),
  `just embed-test`, and a ReleaseFast build.
- [x] **Measured** (§5). One global read went from 288 to 61 instructions.
  The callback loop went from ~880 to ~652 instructions per iteration.
- [x] **Rev 1 review** (codex + antigravity, `docs/reviews/doc62/*-rev1.md`).
  Codex's blocker was booleans whose payload isn't 0 or 1. They are now
  rejected at the C boundary (§3.5, Bart's choice). The should-fix items
  are folded in (§8).
- [x] **Canonical booleans at the C boundary** (§3.5). `fromC` and the
  `.S` entry's argument check both reject a boolean payload other than 0
  or 1.

- [x] **Rev 2 review** (2026-10-05). Both reviewers approved; codex's
  should-fix items and nits are folded in (§8).
- [x] **A less tricky shape for the cold-path tail call** (§4.3,
  follow-up, 2026-10-20). The volatile-`var` indirection is replaced by a
  per-mode slow-handler table indexed by the instruction's opcode
  (`Vm.slowTail`). `get_index` and `set_index` use it too.

### Outstanding

- [ ] **Defer: compiled code calls host natives directly** (option 3 of the
  callback discussion; Bart's stated end goal). This needs its own design
  doc. This doc only makes the lookup in front of a host call cheap.

## 1. Why this exists

The embedding API (doc 59) and the hand-written host-call entry (doc 60)
made C → mahina calls cheap. The other direction, a guest calling a host
function, still cost ~880 instructions per iteration in a tight loop, against
~10 ns for LuaJIT. Where the instructions went (callgrind, AVX2 build, tier-0):

| part                          | instructions |
|-------------------------------|-------------:|
| loop body                     | 338          |
| `get_global host_id`          | ~280         |
| `call` host branch            | ~152         |
| `cHostCall`                   | 55           |
| the C function                | 12           |

The global read was the biggest single item. It is not specific to
callbacks: every function call to a global and every global variable access
pays it. Most of its cost came from two places:

1. **Header loads on every probed slot.** The globals table has hundreds of
   entries, and a lookup probes ~5 slots. For each one, `Value.eql` loaded
   the node key's `GcHeader` to compare ids, and it reloaded the probe key's
   header each time. That is ~40 instructions per probed slot.
2. **The probe itself.** The name is a compile-time constant and globals
   rarely move. Even so, every access hashed the key and walked the chain
   from the start.

We first tried comparing key pointers instead of ids. It broke nine keyframe
tests. Identity in mahina is `GcHeader.id`, not the address: keyframe restore
keeps ids, and a restored VM can run a proto compiled in another heap, whose
constant strings are other objects with the same ids. That attempt was
reverted. Bart chose a combination of two changes (2026-10-05): A, a
per-site slot hint, and B, storing the key's id in the hash node.

## 2. Goals and non-goals

Goals:
- Make `get_global` / `set_global` cheap in the common case: the global
  exists and has not moved.
- Make every hash-part probe cheaper, not just globals (Z-6).
- Change no observable result: not under deletion, redefinition, rehash,
  `_G` / `rawset` writes, keyframe restore, or a proto from another heap.
  Hints and node layout must not leak into anything that is serialized or
  replayed.

Non-goals:
- JIT changes beyond the hrefk key guard. Traced global access is already
  specialized by the recorder.
- Hints for field access (`t.x`) at tier-0. Possible later, using the same
  `getHinted` primitive.
- Compiled code calling host functions directly (deferred, see above).

## 3. B — the hash node stores the key's id

### 3.1 Layout

Doc 49's node is `extern { key: Value, value: Value }`, 32 bytes. A
`Value` is a tag byte at 0 and an 8-byte payload at 8, so bytes 1–7 are
padding. B puts the key's identity in that padding. The node stays 32 bytes,
and the tag and payload stay at the same offsets:

```zig
pub const Node = extern struct {
    key_tag: value.Tag,          // @0  (== Value.tag offset)
    _pad: [3]u8 = .{ 0, 0, 0 },
    key_id: u32,                 // @4  heap keys: GcHeader.id; scalars: 0
    key_payload: value.Payload,  // @8  (== Value.payload offset)
    value: Value,                // @16
};
```

All of this is comptime-asserted. All-zero bytes is still a free node.

### 3.2 Node states (amends doc 49's normative table)

| state | key_tag   | key_id               | key_payload                     | value   |
|-------|-----------|----------------------|---------------------------------|---------|
| free  | nil       | 0                    | 0                               | unused  |
| live  | key's tag | heap: id; scalar: 0  | heap: the pointer; scalar: bits | non-nil |
| dead  | key's tag | heap: id; scalar: 0  | heap: **0**; scalar: bits       | nil     |

Doc 49 rewrote a dead heap key's payload from the pointer to the id. With
the id already in `key_id`, removal zeroes the payload instead. Dead nodes
still hold no pointer, so the "GC marks live nodes only, a deleted key's
object is collectable at once" property is unchanged. The publication order
is unchanged too: removal writes `value = nil` before clearing the pointer,
and resurrection writes the whole key before publishing the value. A node
with a non-nil value always holds a valid live key.

### 3.3 Matching

A lookup computes the key's identity once (`Ident`: tag, plus the id for
heap keys or the raw bits for scalars). A probe compares it against the
node: tag first, then `key_id` (heap) or `key_payload` (scalar). Live and
dead nodes match the same way, so `liveSlotOf` and `probeForPut` share one
comparison. In safe builds (`std.debug.runtime_safety`), a live match
found by `liveSlotOf` is checked against `Value.eql`. Hinted hits and
`probeForPut` are not checked this way. The check also can't catch a false
negative, i.e. two keys that `Value.eql` calls equal but whose identities
differ.

This is exactly `Value.eql` for keys a hash part can hold:
- heap keys compare by id in both;
- integral floats are normalized to ints before reaching the hash part, and
  NaN is never a key, so equal numbers have equal bits;
- booleans have payload 0 or 1 (§3.5), so equal booleans have equal bits;
- `row_view` keys are still rejected at the boundary (asserted in
  `Ident.of`).

Per probed slot, a heap-key lookup now costs one compare of the node's
`key_id`. It used to cost two header loads. Rehash hashes from the node's
own `key_id`, with no header loads either. The hash function and probe
sequence are unchanged, so the layout is the same pure function of the
operation history as before (doc 49's determinism contract).

### 3.4 Consumers

- **Iteration** yields the key by value (`Entry.key`) rather than
  `key_ptr`. A node no longer holds a `Value`, and no caller wrote through
  `key_ptr`. Updated callers: `gc.zig` (marks `entry.key`), `keyframeser.zig`,
  `capi.zig`, `stdlib/base.zig`, `table.zig`, `capi_hostcall_test.zig`.
- **hrefk** (doc 49, native): key guard 4 was "load the node key's pointer,
  compare the id at `[ptr + GCHEADER_ID_OFF]`". It is now one
  `cmp dword [node + NODE_KEY_ID_OFF], key_id`. Guard 2 (live value) still
  precedes it.

### 3.5 Booleans are canonical (codex rev-1 blocker)

`Value.eql` treats any non-zero boolean payload as true. The hash part
hashes and matches raw bits, and it already hashed raw bits before this
change. So `true` with payload 11 and `true` with payload 1 were already
different keys, unless the two happened to land on the same probe chain. B
made the miss certain. Inside the VM every boolean comes from
`Value.boolean`, which stores 0 or 1. Untrusted input could bring in any
other payload only one way: a C host filling in an `mh_value` by hand, which
the header forbids (values are opaque; build them with `mh_bool`). Trusted
Zig code (natives, `HostFn`s, anything that fills `Value.tag`/`payload`
directly) can bypass the boundary. For that code, canonical booleans are a
documented precondition beside `Value`, `NativeFn` and `HostFn` (codex
rev 2), not a runtime check.

Bart's decision (2026-10-05): **reject** such a value at the boundary,
like an unknown tag or a null heap pointer. `fromC` returns null for a
boolean payload > 1:
- APIs that take an `mh_value` as input fail with `MH_ERR_API`;
- the inspectors degrade as they do for any invalid value (`mh_value_type`
  returns `.other`, `mh_value_truthy` returns 0);
- a host function returning one raises a catchable `TypeError`.

The `.S` entry (doc 60) checks its arguments itself before committing, so it
gained the same test: per argument, two more instructions for a
non-boolean (`cmpb $TAG_BOOLEAN`, `jne`) and four for a boolean (plus
`cmpq $1`, `ja`, an unsigned compare). A failing argument falls back to the
Zig path, which rejects it. `TAG_BOOLEAN` is a new entry in
`offsets_x64.inc`, checked like the others. The invariant is therefore
VM-wide: a boolean's payload is 0 or 1.

## 4. A — per-site slot hints

### 4.1 Where hints live

`Proto.global_slot_hints: []u32` holds one hint per constant, indexed by
the same `instr.b` that `get_global` / `set_global` use to name the global.
The compiler allocates it zeroed in the proto's arena, for the main proto
and each nested one. Hand-built protos leave it empty, and their global
accesses take the plain lookup. A hint is a slot index into the globals
table's hash part, nothing more: no pointer, no generation, no version.

The slice's elements are written through a `*const Proto`, like other
per-proto runtime caches. Hints are never serialized (keyframes, snapshots
and the trace schema are all unchanged).

### 4.2 Why a hint can never change a result

Every use re-checks the hinted slot: in range for the current node array,
holding this key's identity (tag + id), and with a non-nil value. Only then
is the hinted node's value used. A slot that passes all three checks holds
the key's live entry, because a key has at most one node (doc 49). So the
answer is the one `get` would give. Anything else falls back to the full
lookup, which moves the hint to where it found the key.

This covers every way a hint goes stale without any invalidation hook:

| event                                   | what the check sees                     |
|-----------------------------------------|-----------------------------------------|
| global removed (`x = nil`)              | value nil → miss → lookup returns nil   |
| global re-added after removal           | the dead slot is resurrected → hit, unless a rehash dropped it or another key reused it first (then miss, hint moves) |
| dead slot reused by another key         | a different id → miss → lookup returns nil |
| rehash (growth, shrink, same capacity)  | the key's own slot (hit), another key's or a free slot, or out of range (miss) |
| `_G[k] = v`, `rawset(_G, …)`            | same node is updated in place → hit sees it |
| proto run by a second VM (restore, foreign heap) | the other table's layout: a hit if the key happens to sit in the same slot there, otherwise a miss and the hint moves |
| node array freed and reallocated        | the hint is an index, re-checked against the live array |

`set_global` uses the hint the same way. If the hinted slot holds the key
live and the new value is non-nil, it overwrites the value in place. For a
non-integer key, `Table.set` would do exactly that (`hash.put` on a live
key). Otherwise `Table.set` runs as before, and the hint moves to wherever
the key now lives. The globals table's write barrier runs after either path.

### 4.3 Keeping the hit path free of calls

Interpreter handlers end in guaranteed tail calls (doc 42). If a handler
contains any call, even on a cold branch, LLVM saves and restores
callee-saved registers on every entry. A hint hit that pays five register
saves gives back much of what the hint saved. So the hit is split from the
miss:

- `HashPart.heapHintHit` (inline, calls nothing) checks the hinted node
  and returns the value or "not known here". `opGetGlobal` uses it and
  dispatches the next instruction.
- On a miss, `opGetGlobal` tail-calls a separate handler
  (`GetGlobalSlow(mode).handler`) that does `getHinted`.

Called directly, LLVM inlines that slow handler back into the fast one, and
the register saves return. `@branchHint(.cold)` does not stop it, and
`noinline` changes the function type, which `.always_tail` rejects. The
tail call therefore goes through a function pointer read with a volatile
load from a module-level `var` that is never written. (A `const` doesn't
work: Zig folds the load at compile time.) This took a global read from 73
to 61 instructions. It is a deliberate trick. Bart accepted it for now and
it is recorded in TODO.md, so we can look for a better shape later and
reuse it for other handlers with cold slow paths.

`set_global` was not split. It calls `setHinted` either way, and the write
barrier follows it.

**Follow-up (2026-10-20): the slow-handler table.** The volatile load is
gone. `interp.zig` now builds a second per-mode table beside the dispatch
table, `slow_table_fast` / `slow_table_full`: for each op with a split, its
slow handler; for the rest, `noSlowPath`, which panics. A fast handler
leaves through `slowTail`, a tail jump through that table indexed by
`instr.op`. The index is loaded from the instruction at run time, so LLVM
cannot turn the jump into a direct call and inline the slow handler. The
cost is the same as before: one load of the opcode, one of the table
entry, one indirect jump. The global-read probe loop measures the same
per-iteration instruction count as with the volatile load, and the
handler's prologue is identical. The same split now also serves `get_index`
and `set_index`, whose fast paths (array part, and a heap key probed
inline, `__index` chains of plain tables included) call nothing. Any
other handler with a cold slow path can join by adding one table entry.

### 4.4 Sharing and threads

Hints are per proto, so every VM running a proto shares its hints. Two VMs
whose globals tables differ in layout keep moving the hints back and forth.
That costs time but never changes a result. Concurrent use of one proto from
two threads would be a data race on the hint words. Today that can't happen:
the embedding API is one VM per thread at a time, with nothing shared
between VMs (doc 59 §3.2 and its non-goals). If that model ever changes,
hints must move to per-VM storage or use relaxed atomics. "One thread per
VM" isn't enough on its own: every VM sharing a proto must be synchronized.
The `Proto.global_slot_hints` doc comment says so.

## 5. Measurements

Instruction counts (`perf stat -e instructions:u` and callgrind), AVX2 build,
tier-0, the C callback probe:

| build                                      | one global read | callback loop / iter |
|--------------------------------------------|----------------:|---------------------:|
| HEAD                                       | 288             | ~880                 |
| pointer compare (reverted, §1)             | 199             | —                    |
| B only                                     | 159             | —                    |
| A + B, hint behind a call                  | 116             | —                    |
| A + B, inline hit                          | 80              | —                    |
| A + B, inline hit, split slow handler      | 61              | ~652                 |

Bench programs, whole-run `instructions:u`, HEAD library vs this change
(native build, run through the C API; JIT off = tier-0):

| bench              | JIT off | JIT on |
|--------------------|--------:|-------:|
| field_hash         | −10.79% | −0.00% |
| array3d            | −8.30%  | −2.69% |
| nbody              | −7.41%  | −2.75% |
| str_gsub           | −2.44%  | −2.43% |
| str_find_match     | −1.81%  | −0.00% |
| tbl_ops            | −1.03%  | −0.96% |
| lua54              | −0.93%  | −0.81% |
| str_gmatch         | −0.70%  | −0.93% |
| repack_adversarial | +1.42%  | −0.22% |
| sieve_int          | +0.50%  | −0.00% |
| binary-trees       | +0.33%  | +0.26% |
| nsieve             | +0.28%  | −0.00% |
| euler14-bit        | −0.75%  | +0.22% |

Every other bench was within ±0.3%. The scimark programs need `require`,
which the C-API runner doesn't provide, so they have no valid rows.

**The regressions are code layout, not extra work.** In
`repack_adversarial`, callgrind puts the whole +1.84M instructions (of 140M)
in `interp.Vm.indexSet`'s own cost: about 10 instructions more on each of
~200k calls. Both builds run the same instructions on its hot path: tag
checks, `metatable == null`, call `Table.set`. But the new build sets up two
VM-field addresses on every entry, plus an extra jump and a register move
around the return. Only the inlined metatable / `__newindex` branch uses
them. That branch inlines `t.get`, which now inlines the id-keyed probe, and
the larger function body changed how LLVM lays it out. Bart chose to accept
this (2026-10-05). The other small tier-0 regressions are the same size and
also in table-store-heavy benches, presumably the same effect.

## 6. Tests

- `hash_part.zig`:
  - "heap keys match by id, so a different object with the same id is the
    same key". Covers get, put, and overwrite through a second header with
    the same id; the dead node's id and zeroed payload; resurrection; and
    iteration.
  - "slot hints: stale, out-of-range, foreign and dead hints give the plain
    lookup's answer".
  - "slot hints across shrink, same-capacity rebuild and dead-slot reuse"
    (rev 2). Drives each physical transition directly through `rehashTo`,
    and checks it happened: capacity, and the reuse of the removed key's
    slot.
  - "slot hints hit through another object with the same id" (rev 2).
    Covers `heapHintHit`, `getHinted` and `setExistingHinted`.
- `keyframeser_restore_test.zig`: "doc 62: a restored VM shares its
  protos' global slot hints with the original, and both read their own
  globals" (rev 2). The original and a restored VM run the same protos,
  diverge their globals layouts, and alternate calls.
- `interp_bytecode_test.zig`: "set_global and get_global on a hand-built
  proto (no slot hints)" (rev 2).
- `capi_test.zig` and `capi_hostcall_test.zig`: a boolean with payload 11
  is rejected by the API, and identically by every host-call tier. A
  payload of `1 << 63` is rejected too, which pins the `.S` compare as
  unsigned. A host function returning payload 11 raises a catchable error,
  and the VM stays usable. (Rev 2, plus codex rev-2 additions.)
  Mutation-checked: with the `.S` boolean test removed, the host-call diff
  test fails.
- `interp_semantics_test.zig`: "global-access cache: removal, redefinition,
  rehash and _G writes are all seen". The program reads and writes globals
  around `x = nil`, 200 `_G["g"..i]` inserts (growth), `_G.x` and `rawset`
  writes, mass deletes, and 300 more inserts.
- Mutation check. Each of these was planted in turn, and at least one test
  failed for each:
  1. Skip the identity check on a hint hit.
  2. Drop the range check.
  3. Let `set_global` write into a dead hinted slot.

  The third was missed at first, because `set_global` never moved its hint.
  `setHinted` now moves it on fallback, and the test catches it. The second
  was missed at first too; `hintedNode` now indexes through a slice, so a
  safe build panics.

## 7. Open questions for review

- Is the per-proto hint (rather than per-VM) acceptable under the stated
  threading model (§4.4)? Rev 1: both reviewers accepted it under the
  current model.
- Is anything that consumes hash nodes missing from §3.4? (The JIT reads
  nodes only through `nativegen_layout`'s offsets, and those are comptime-tied
  to `Node`.) Rev 1: neither reviewer found one.

## 8. Review ledger

Rev 1 (2026-10-05): codex **CHANGES REQUESTED**, antigravity **APPROVE**.

| finding | from | status |
|---|---|---|
| Non-canonical boolean payloads break `Ident.matches` ≡ `Value.eql` (blocker) | codex | Fixed: rejected at the C boundary, `fromC` and `.S` (§3.5) |
| Tests for shrink, same-capacity rebuild, dead-slot reuse; same-id hinted hits | codex | Fixed (§6) |
| Threading restriction beside `Proto` | codex | Fixed (doc comment; §4.4) |
| Safe-build cross-check claim too broad | codex | Fixed (§3.3) |
| Stale comments: `hash_part.zig` header, `emitHrefK` guard list | codex | Fixed |
| Invalidation table outcomes too unconditional | codex | Fixed (§4.2) |
| `set_global` on a hand-built proto (no hints) untested | antigravity | Fixed (§6) |
| Multi-VM proto sharing untested | antigravity | Fixed through keyframe restore (§6). The only supported way two VMs run one proto: a proto compiled against another heap's ids is not otherwise valid in a second VM. |
| §3.4 lists `capi_hostcall_test.zig`; its line 311 is another map | antigravity | No change: line 214 is a real `t.hash.iterator()` site, so the listing is accurate. |
| `getHinted` re-checks the hinted node after `heapHintHit` already did | antigravity | Kept: `getHinted` is a standalone API. The repeat costs a few instructions on a miss only, which then probes anyway. |

Rev 2 (2026-10-05): codex **APPROVE**, antigravity **APPROVE**
(`docs/reviews/doc62/*-rev2.md`). Codex's should-fix items and nits are folded in:

| finding | from | status |
|---|---|---|
| State the 0/1 boolean precondition for trusted Zig callers | codex | Fixed: doc comments on `Value`, `NativeFn`, `HostFn`; §3.5 qualified |
| Persist the callback-result case; a high-bit boolean argument | codex | Fixed: `capi_test.zig` host fn returning payload 11; `capi_hostcall_test.zig` payload `1 << 63` |
| "Every API fails with `MH_ERR_API`" too broad | codex | Fixed (§3.5) |
| Instruction count omitted branches | codex | Fixed (§3.5, doc 60) |

## References

- `docs/design/49-owned-hash-part-hrefk.md`: the owned hash part, node
  states, and hrefk.
- `docs/design/42-tier0-tail-call-dispatch.md`: tail-called handlers.
- `docs/design/59-rust-embedding-api.md`, `docs/design/60-hand-written-machine-code.md`:
  the host boundary.
- `src/hash_part.zig`, `src/table.zig` (`getHinted`, `setHinted`),
  `src/interp.zig` (`opGetGlobal`, `GetGlobalSlow`, `opSetGlobal`),
  `src/nativegen_emit.zig` (`emitHrefK`).
