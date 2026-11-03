# 80 — Growing strings: allocator, pacing, concat, long strings — Design

Status: partial — U1 (large-block cache), U2 (single-copy concat), U3
(byte-charged GC pacing) and U4 (long strings: the sparse intern hash) built;
the follow-ups below outstanding
Owner: Bart
Last updated: 2026-11-02

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole units to Done once everything inside them is checked.

### Done

- [x] **U1 — large-block cache** (§2). `mem.LargeBlockCacheOver` in
  `src/mem.zig`; the CLI (`src/main.zig`) installs it over the process
  allocator on every platform.
- [x] **U3 — GC pacing charges string bytes** (§3). `gc.stringUnits`,
  `Heap.string_debt`, the refund in `destroyObject`, and the trace charge
  rule (§3.2): `guard_gc`/`guard_host_epoch` publish their bound in
  `Heap.trace_alloc_bound`, the stralloc shims arm `trace_callout`, and a
  charged intern that would break the guard's promise is refused and the op
  declines to tier 0.
- [x] **U2 — concat copies each operand once** (§4). `String.Builder`
  and `Heap.internBuilt` for a result past 256 bytes, a stack join plus
  `internKnown` below it. Both carry the operands' character facts, so no
  construction scan runs.
- [x] **Bench `bench/stdlib/str_concat_grow.lua`** with its hashgate rows.
- [x] **Q1 — long strings: which model** (§5). Bart picked (A) first, then
  (B) once §5.2 showed doc 28 §5 had already designed it.
- [x] **U4 — long strings, as (B)** (§5.4). Doc 28 §5's L3: the sparse
  hash, widened to the first and last eight bytes, LuaJIT's chain guard
  with its weighting, and an identical-hash trigger that the rebuild keeps.
  str_concat_grow −61%, io_read_all −53%; os_date +0.9% once the sweep
  re-decides the marks (doc 28 §5.1).
- [x] **The sweep re-decides the dense marks** (doc 28 §5.1). os_date's
  +7.7% came from marks that outlived the strings that made them, in a
  table that never grew: every bucket ended up marked.

### Outstanding

- [ ] **More producers through `String.Builder`** (§4.2): `table.concat`,
  `string.rep`, `string.format` and `gsub` build in a growable buffer and
  then intern a copy. Defer until the builder grows a capacity API.
- [ ] **n-ary concat** (§4.2): `a .. b .. c .. d` is three binary concats
  with two intermediate strings; Lua's `OP_CONCAT` joins a register range
  once. A bytecode change; not started.
- [ ] **The trigger counts compares, not their cost** (§5.4). Short
  same-hash groups that die young still get promoted: os_date pays +0.9%
  where a build without the trigger pays −1.9%. A budget of compared bytes
  might promote only groups whose compares are expensive. Not measured.
- [ ] **Embedders** (§2.3): document `LargeBlockCache` in the embedding
  guide; the C API does not install it today.

## 1. Why this exists

`s = s .. "x"` in a loop is the idiom every Lua programmer reaches for, and in
mahina it was worse than quadratic: 80 000 iterations took 1.23 s
(`lua` 0.08 s), 160 000 took 5.34 s, and RSS climbed past 230 MB. Three costs
stacked:

1. **Every allocation past 32 KiB was an `mmap`/`munmap` pair.** The release
   CLI's process allocator is `std.heap.smp_allocator`, which sends anything
   larger than its 64 KiB slab classes straight to `PageAllocator`. A growing
   string past 32 KiB therefore paid a syscall pair plus first-touch page
   faults on every step, and the kernel zeroed every page again.
2. **The collector did not see string bytes.** Pacing counted objects, so a
   heap of a few hundred 100 KiB strings looked as small as a few hundred
   empty tables. The dead intermediates of the loop stayed alive until the
   object count caught up, which is where the RSS went.
3. **Each concat copies twice and hashes the whole result** (§4, §5).

U1 and U3 fix the first two. U2 removes the extra copy and the construction
scan; U4 is about the hash.

| | 80k `s..x` | 160k `s..x` | `str_concat_grow` 80000 | peak RSS (80k) |
|---|---|---|---|---|
| before | 1.23 s | 5.34 s | 1.57 s | 181 MB |
| U1 | 0.50 s | 1.93 s | 0.58 s | 243 MB |
| U1 + U3 | 0.19 s | 0.75 s | 0.22 s | 8 MB |
| U1 + U3 + U2 | 0.15 s | 0.57 s | 0.18 s | 8 MB |
| `lua5.4` | 0.10 s | 0.44 s | 0.09 s | 3 MB |

## 2. U1 — the large-block cache

### 2.1 Shape

`LargeBlockCacheOver(static_vtable)` wraps a child allocator and keeps
freed blocks of 32 KiB and up for reuse:

- **Size classes**, 8 per doubling from 32 KiB to 64 MiB (81 classes, at
  most 12.5 % waste). A request is rounded up to its class, so a block freed
  by one string serves the next string of a similar size.
- **One LRU across classes**, not a cap per class. A per-class cap filled up
  with blocks of sizes the program had already grown past, and those blocks
  were never reused.
- **A bounded total:** kept bytes never exceed
  `max(retain_floor, peak_in_use)`. The floor is 64 MiB by default. Above it
  the cache keeps at most as much as the program has ever had live at once,
  so it never more than doubles the footprint. The oldest blocks are evicted
  first.
- **Blocks above 64 MiB** are still the cache's (taken at its 64-byte
  alignment, at their exact length), but are never kept. Treating them as
  the cache's own means resize and remap stay with the cache as a buffer
  grows past the limit, so it is never copied between two allocators.
- **resize/remap between classes are delegated to the child at class
  sizes.** On Linux that is `mremap`, so a growing buffer moves without a
  copy. Refusing them and copying instead cost `io_read_all_bin` 19 %.

### 2.2 Cost on the fast path

The wrapper is one extra compare for small allocations. When the child's
vtable is known at comptime (`static_vtable`, which the CLI passes for
`SmpAllocator`), child calls are inlined direct calls, and the large-block
paths are `noinline`. With a dynamic vtable the A/B cost was +2–7 %
instructions across the board. With the static vtable every benchmark is
within ±0.7 %.

### 2.3 Who installs it

The CLI installs it over the process allocator on every platform; with
`--mem-stats` the tracker wraps the cache, so it counts what the VM asks for. The thread, LSP and viz
allocators keep the plain process allocator. An embedder brings its own
allocator (Rule Z-4), so the cache is opt-in there: wrap the backing
allocator once and feed the VM from it.

## 3. U3 — GC pacing charges string bytes

### 3.1 The charge

A string costs `stringUnits(len) = len / nominal_object_bytes` (256) object
units on top of its own object. That is charged as `Heap.string_debt` when
the string is linked into the intern table (`internImpl`, and
`internRestoredUnique` on restore), and refunded when `destroyObject`
frees it. The pacer's debt is `stack_debt + string_debt`: `next_gc` is
`gc_target - debt`, and a sweep sets the next target to
`max(1024, (live + debt) * 2)`. Short strings charge nothing, so programs
that never build long strings collect on exactly the schedule they had
before.

The charge is a pure function of string lengths, so all eight modes see the
same schedule and the same collections (doc 02).

### 3.2 The trace charge rule

Doc 24 D3 lets a trace iteration run only if
`!gc_stress ∧ object_count + A < next_gc`, where A is the trace's static
allocation bound. That is what guarantees no collection can start in the
middle of an iteration. A charged string breaks the promise: one 1 MiB
string adds 4096 units, far more than the one object A counted for it.

Rejected alternatives were (a) charging nothing on trace, which makes the
schedule depend on the tier and breaks 8-mode equivalence, and (b) folding a
byte bound into A, which no static bound can give for `rep` or `sub` of a
runtime length.

The rule that ships:

1. `guard_gc` and `guard_host_epoch` store A in `Heap.trace_alloc_bound`
   when they pass (native and tier-1a both).
2. The trace-side string shims (`ssub`, `srev`, `srep2`, `supper`, `slower`,
   `scapStr` in `stralloc.zig`) set `Heap.trace_callout` around their
   allocation.
3. A charged intern miss under `trace_callout` is admitted only if
   `object_count + A + units < next_gc`. Otherwise it is refused: the shim
   sets `trace_charge_refused` and returns `.decline`, so tier 0 replays the
   op and the collection happens where tier 0 would have done it.

The refusal must be `.decline`, not `.oom`: on a precise trace an OOM is
raised in place (doc 45 D5), which would turn a pacing event into a
program-visible error. `tostr` and `schar1` produce short strings and are
never charged.

## 4. U2 — concat in one copy

Before U2, `Vm.concat` joined its operands in a heap scratch buffer, then
interned that. On a miss the intern copied the bytes again and ran the
construction scan (code-point count and ASCII bit) over the whole result;
on a hit the scratch buffer was allocated and freed for nothing.

### 4.1 What shipped

The operands' character facts are known: a string carries its cached
`cp_len` and ASCII bit, and a number's text is ASCII with one code point per
byte. So the result's facts are a sum and an AND, and every concat skips the
scan (safe builds still assert the claim against it). The bytes take one of
two paths, split at `nominal_object_bytes` (256):

- **A short result is joined in a stack buffer** and interned with
  `internKnown`. A hit allocates nothing; a miss allocates the string and
  copies the short result once more.
- **A long result is built in place.** `String.Builder` allocates the
  string's own block (header plus payload), the operands are copied into it,
  and `Heap.internBuilt` seals it (hash and caches) and interns it. A miss
  links that block as it is. A hit, which is rare for a long result, frees
  it.

Every intern entry ends in one miss-path tail, `Heap.linkNew` (the charge
refusal of §3.2, table growth, insert, link, charge), so the doc 24 D5
transactional shape and the charge rule cannot fork between entries. It and
the intern table's capacity check are `inline`: as out-of-line calls they
cost every miss about 25 instructions (scalar +3.6 %).

Instruction counts against U3, both tiers: str_concat_grow −16.6 %,
str_long_keys −12 %, str_sort −4 %, pairs_hash −1.7 %, everything else
within ±0.5 %. A short concat whose result is already interned costs 20 %
fewer instructions, and one that is new 18 % fewer.

### 4.2 Not yet

- `table.concat`, `string.rep`, `string.format` and `gsub` still build in
  a growable buffer and intern a copy. They want a builder that can grow
  and trim its block; the exact-size `Builder` is the first slice of that.
- Concat is binary. `"x=" .. x .. ", y=" .. y` makes three strings to keep
  one, where Lua's `OP_CONCAT` joins a register range in one pass. That is
  a compiler and bytecode change.
- The hash still reads the whole result on every step (§5). U4 (§5.4)
  fixed this.

## 5. Q1 — long strings

Even with U1–U3, every concat hashes its full result, so a loop that grows a
string to n bytes still does O(n²) hashing work. After U2, a 160k
`s = s .. "x"` loop spends 56 % of its cycles in `Wyhash.hash`, 16 % in
`memcpy` and 12 % in the collector. Two ways out:

- **(A) Lua 5.4: long strings are not interned.** Strings past a limit
  (40 bytes in Lua) are created without a hash-table lookup; equality
  compares lengths and then bytes, and a long string used as a table key
  hashes lazily, once. This is what Bart picked first. It is structural:
  string identity, table keys, equality, the JIT's pointer-equality string
  compares, keyframe string tables and restore all change.
- **(B) LuaJIT: everything stays interned, with a sparse hash.** A long
  string hashes a fixed sample of its bytes, so hashing is O(1) in its
  length. Strings that collide fall back to a full hash on long chains. The
  intern table and every pointer-equality fast path stay as they are, and
  the cost moves to the comparisons on a hash-chain hit.

Bart decides between them before U4 starts. **He picked (B)** (§5.4).

### 5.1 What (A) touches

Interning is load-bearing in two forms: object-id equality (`Value.eql`,
every hash-part probe, `next`, the native hrefk guard, keyframes) and
address equality (`eq_s`/`jeq_s`, `guard_sid`, the compiler's constant
dedup, the trace konst pool). An inventory of the tree (2026-11-02)
found these sites, grouped by what fails:

**Silently wrong results** (each must be fixed before any long string
skips the intern table):

1. `==`/`~=` on two strings: `eqLanes` (interp.zig ~8923) answers "not
   equal" for two heap refs that are not both tables, with no slow path;
   `eqStrLane` (~8962, the `eq_s`/`jeq_s` lanes) compares addresses, and
   `opJEqSlow` has no string arm. `Value.eql` (value.zig ~252) compares ids,
   and the recorder's konst fold (`eqRef`) inherits it.
2. Table keys: `hash_part` hashes and matches heap keys by id (`keyHash`,
   `Ident`, `liveNodeInline`), so an equal but distinct long string misses.
   This is every `get`/`set`/`getPtr`/`remove`, and the `get_field`/
   `set_field` fast lanes.
3. `next(t, k)` (`nextLive`) finds the control key by raw bits, then by id,
   then by binary search over ids: an equal but distinct control key lands
   at the wrong position.
4. `forwardPendingHashLoad` (trace_recorder.zig ~2706) treats two konsts
   as different cells when their refs differ, which interning made equal to
   "different content".
5. **Deopt replay (doc 24 D2).** Re-running a partial iteration after a
   coarse exit costs no new object ids because its string producers' first
   misses are the re-run's hits; `tostr_*` CSE rests on the same fact. An
   uninterned long result allocates a new id on every re-run, so `ssub`,
   `srev`, `srep2`, `supper`/`slower` and `scap_str` would diverge from
   tier 0 (8-mode equivalence). They would have to become effects, stay
   restricted to short results on trace, or move to precise deopt.

**Structural:**

6. A deleted hash node keeps only `key_id` (its payload is zeroed by
   `remove`), and `probeForPut`/`liveSlotOf` rely on "a key occupies at most
   one node, live or dead": a dead id match proves absence and is
   resurrected. A dead long-string node cannot be matched by content, so a
   re-inserted equal string would take a second node, which breaks the
   stable slots `next` depends on. Nodes would need the content hash and a
   comparable handle, or long keys must leave the dead-match rule.
7. Keyframe restore interns every `HeapString` and rejects duplicates
   (`internRestoredUnique`); two equal long strings are legal under (A).
   The recompile of loaded chunks must allocate nothing
   (`RecompileAllocated`), which holds only because literals re-intern to
   restored strings: the compiler would have to keep interning long
   literals.
8. The sweep re-inserts every surviving string into the intern table; it
   would skip long ones.

**Slower but correct:** the hrefk guard compares the node's `key_id` with
the konst's id, so a table whose key object is not the literal side-exits
every iteration (record the node's own id instead); `guard_sid` pattern
pins and `sgmatchCore` exit when an equal pattern is a different object;
konst dedup, `callee_global_dedup` and `hash_cell_dedup` lose sharing.
`fieldByName` returns "absent" for any name past the limit
(`internedLookup` would always miss). Tests that assert result identity
(stdlib/string.zig, effectser) or use `strtab_count` as an
"allocated nothing" probe go blind or fail.

**Unaffected:** `<`/`<=` already compare bytes; metamethod, type and
method names are short; table key *order* stays deterministic (by id,
with one key object per content per table); GC byte pacing applies as is.

About 250 intern call sites outside test files exist; nearly all produce
short strings. The long producers are concat, the stdlib string cores,
`table.concat`, `string.format`/`gsub`, file/getenv results and the C
API's `push_string`.

### 5.2 What (B) touches

(B) is doc 28 §5's **L3**, designed and reviewed on 2026-08-28 (Codex
must-fixes folded in: fixed little-endian sampled loads, the determinism
argument, and collision hardening shipping in the same change) and left
open as a separate decision for Bart. It was never built. Doc 28 §5 is the
decision text; this section only adds what growing strings change.

`String.hash` is read only by the intern table (`strtabLookup`,
`strtabInsert`, rebuild); table keys hash by id. So (B) is local to
`gc.zig` and `string.zig`: the hash function for strings past a length
limit, plus LuaJIT's collision guard (`lj_str.c` `lj_str_new`: more than
32 collisions on a chain rehashes that chain with the dense hash, marked
by a tag bit on the bucket head). Equality, table keys, the JIT, deopt
replay and keyframes are untouched. The seed must stay a constant (LuaJIT
draws it from its PRNG; ours feeds no observable order, doc 02, but a
fixed seed keeps runs identical). What it does not remove: a chain hit
still compares bytes (`memcmp`) when hash and length match, and a hit on a
long string is a full compare. For `s = s .. x` the length differs on
every step, so hits are rare.

### 5.3 Outstanding for U4

- [x] Bart picks (A) or (B) with §5.1/§5.2 in hand: (B).
- [ ] Under (A): not taken. §5.1 stays as the inventory should the
  question come back.
- [x] Under (B): the sparse hash and the chain guard, with adversarial
  collision tests (`gc.zig`, "doc 28 §5: …") and the A/Bs (§5.4).

### 5.4 What U4 built

Doc 28 §5.1 records the design as landed, the variants measured and the
review. In short:
- `string.sparseHash` is `hash_sparse` reading two more words from 8 bytes
  up, so the first and last eight bytes all count;
- `Heap.strtabFind` counts LuaJIT's way;
- `strtabGuard` also fires on the fourth same-hash, same-length compare;
- `strtabDecideMarks` keeps both rules across a rebuild.

The 80k `s = s .. "x"` loop takes 0.07 s (U1–U3: 0.15 s; lua5.4 0.09 s).
Every intern still pays a sparse hash, and a promoted bucket pays the
dense one as well. os_date's +7.7% came from marks that outlived their
strings; the sweep now re-decides them (doc 28 §5.1), which leaves +0.9%.

## References

- `src/mem.zig` — `LargeBlockCacheOver`.
- `src/main.zig` — the CLI's allocator chain.
- `src/gc.zig` — `stringUnits`, `string_debt`, `traceChargeFits`.
- `src/stralloc.zig` — the charged shims.
- Doc 02 (determinism), doc 24 D3 (`guard_gc`), doc 45 D5 (precise OOM).
- LuaJIT `lj_str.c` (`lj_str_new`, sparse hashing); Lua 5.4 `lstring.c`
  (`luaS_newlstr`, `LUAI_MAXSHORTLEN`).
