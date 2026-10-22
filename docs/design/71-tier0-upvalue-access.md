# 71 — Tier-0 upvalue access

Status: complete. P0–P2 landed 2026-10-23.
Owner: claude (coral-marten)
Last updated: 2026-10-23

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis and prototype** (2026-10-23, §2, §4).
- [x] **P0 — store from a local** (§3.1): `u = v` and `g = v` store `v`'s
  register, with no `move`.
- [x] **P1 — lane pointers in the cell** (§3.2): `get_upval` / `set_upval`
  read and write through them, with no open/closed branch.
  `Vm.upvalGet`/`upvalSet` are replaced by `Upvalue.get`/`set`.
- [x] **P2 — cells inline in the closure** (§3.3).

### Outstanding

_(nothing)_

## 1. Why this exists

An upvalue read is 33 instructions at tier 0, against 13 under LuaJIT
`-joff`, and a write is 52 against 17. Code that keeps its helpers and
state in enclosing locals pays it on every use: `local function` recursion,
module-level `local floor = math.floor`, counters in a closure. The
`get_upval` / `set_upval` handlers alone are 10–17% of tier-0 cycles on
recursive-fib, str_find_match, lua54 and scalar (perf, ReleaseFast).

## 2. Diagnosis

`bench/opprobe/upvalues.lua`, instructions per use (LuaJIT `-joff` second):

| construct | mahina | LuaJIT |
|---|---|---|
| read, closed cell | 33 | 13 |
| read, open cell | 34 | 13 |
| write, closed cell | 52 | 17 |

A read loads `st.closure`, then `closure.upvalues.ptr`, then the cell, then
tests `loc`'s tag. An open cell then loads `vm.tags` and `vm.payloads`
before the value; a closed cell reads it from the cell. The branch and the
two extra loads need two more registers, so the handler pushes and pops
`rbx` and `r14`. perf puts most of the handler's cycles on the `loc` test,
at the end of three dependent loads.

LuaJIT's `UGET` is `base[-1]` → `fn->uvptr[b]` → `uv->v` → the value: the
cell holds a pointer to the value wherever it lives, so there is no branch,
and the cell pointers sit inside the closure.

A write pays the same, plus a `move`: `u = v` compiles `v` into a temporary
and stores the temporary.

## 3. Design

### 3.1 P0 — store from a local

`compileSingleAssign` already stores a local's own register into a field or
index target whose prefix can't write it. An upvalue or global target has
no prefix at all, so a local value stores from its own register. This is
Lua 5.4's `SETUPVAL A B` from any register.

### 3.2 P1 — lane pointers in the cell

`Upvalue` gains `tag: *u8` and `payload: *u64`, the value's two lanes:
`&vm.tags[i]` / `&vm.payloads[i]` while the cell is open over slot `i`,
and `loc.closed`'s own tag and payload once closed. They change only
together with `loc`, in `createOpen`, `reopen` (the keyframe restorer),
`closeWith` and `createClosed`. `get_upval` and `set_upval` read and write
through them, with no branch.

`loc` stays as it is. The GC, the keyframe serializer, the recorder and
the JIT's entry seeding still ask it whether the cell is open and where.
The JIT's closed-cell path keeps using `&cell.loc.closed` as a `*Value`
(doc 43 P5), which the pointers alias.

**Why this is sound now, unlike when doc 09 removed `*Value`.** Doc 09
Phase 0 dropped the open cell's `*Value` into the stack because a single
pointer can't address a value split across two arrays. Two pointers can.
They stay valid because the register stack is allocated once at
`initBare` and never reallocated, and a cell never moves after `create`.
If the stack ever grows in place, the open list (`open_upvalues`, which
holds every open cell) is where the pointers get rebased, as LuaJIT's
`resizestack` does.

### 3.3 P2 — cells inline in the closure

`Closure.create` allocates the closure and its cell pointers in one block,
the pointers right after the struct (LuaJIT's `GCfuncL.uvptr`).
`Closure.upvalue(i)` computes the address from the closure, so the hot
handlers skip loading `upvalues.ptr`. The `upvalues` slice stays, pointing
at the same memory, for every other consumer. One allocation per closure
instead of two.

## 4. Results (2026-10-23)

Per use, after P0–P2 together: read 33 → 26 (open 34 → 26), write
52 → 28. The read handler is straight-line with no callee-saved register.
P1 alone gives the read 33 → 27; P0 the write 51 → 29; P2 one more
instruction and one fewer dependent load on each.

All `@bench` programs, instructions against 02ea711 (every output
identical): no row above +0.01%. Tier-0: scalar −2.08%, str_manip −1.79%,
recursive-fib −1.52%, lua54 −1.44%, nsieve-bit-fp −1.09%, str_find_match
−0.87%, tbl_ops −0.81%, spectral-norm −0.73%, binary-trees −0.59%.
`--jit-native`: lua54 −1.43%, recursive-fib −1.37%, tbl_ops −0.79%.

## 5. Determinism

No value changes: the lanes read and written are the ones `upvalGet` /
`upvalSet` reached through `loc`. Object ids come from heap linking, not
allocations, so the single closure allocation changes no id. Keyframes
don't serialize the pointers; the restorer sets them through `reopen` and
`closeWith`.

## 6. Testing

The existing upvalue tests (open, closed, close-on-return, escaping
closures, protected-call unwinds, keyframe round trips) cover both cell states through
every handler. A cell-level test checks that the pointers follow `loc`
across create, close and reopen, and that writes through them land in the
stack slot or in `loc.closed`.

## 7. References

- LuaJIT: `lj_obj.h` (`GCupval.v`, `GCfuncL.uvptr`), `vm_x86.dasc`
  (`BC_UGET`, `BC_USETV`), `lj_state.c` (`resizestack`).
- Doc 09 Phase 0 (index-based upvalues), doc 43 P5 (the JIT's closed-cell
  path), doc 53 (open-upvalue slot canonicalization).
