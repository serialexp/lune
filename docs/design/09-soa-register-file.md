# mahina — SoA register file (split the VM value stack) — Design

Status: complete (pending commit approval) — phases 0–2 landed & green: the
storage flip, the full hot-arm rewrite, and the two-pointer native ABI are in,
all 8 modes byte-identical. Codex + Antigravity review + Bart's commit approval
are the only remaining gates.
Owner: Bart
Last updated: 2026-06-22

Prerequisite reading: `00-architecture.md` (the tier model and the `Value`
contract), `03-gc-memory.md` (root scanning + the open/closed upvalue model), and
`04-snapshot-replay-schema.md` (the keyframe wire format the flip must keep
byte-identical).

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items as
they land; move whole sections to "done" once everything inside them is checked.

### Done

- [x] **Phase 0 — index-based upvalues (pre-flip, green).** `function.Upvalue`
  dropped its interior `*Value` (`ptr`) for `loc: union(open: usize, closed:
  Value)`; value access is Vm-mediated (`upvalGet`/`upvalSet`). GC mark (closed
  only — open is covered by the live-stack root scan), keyframe ser (resolves an
  open cell via `upvalGet`) / restore (sets `.open = stack_index`), and the two
  interpreter arms route through the new shape. Pure indirection swap over the
  still-`[]Value` stack; `just test` + `just check-version` green. Reviewers
  (Codex + Antigravity) caught one real bug: the `pcall`/`xpcall` error unwind
  (`stdlib/errors.zig`) restored the stack boundary without closing the faulting
  frames' open upvalues — now fixed with `closeUpvaluesFrom(entry_top)` at all
  three restore sites (the correct semantics regardless of GC), covered by two
  slot-reuse regression tests.
- [x] **Phase 1 — `RegWindow` seam through the cold consumers (perf-neutral).**
  Two accessors introduced over the *current* `[]Value` storage: `RegWindow`
  (`src/regwindow.zig`, a frame-relative value-semantics view; phase 1 wraps a
  `[]Value` slice, phase 2 swaps to tags/payloads base pointers) for the
  frame-relative consumers (trace recorder, irinterp executor), and absolute-index
  `Vm.regGet`/`regSet`/`regCapacity`/`fillNil`/`frameWindow` for the whole-stack /
  cross-frame consumers (GC root scan, keyframeser ser/restore, the structural
  call/ret/vararg per-element copies, upvalue open get/set, vararg reads,
  `stampSingleResult`, `describeFault`). The trace recorder's 17 production
  functions + the irinterp executor (`execute`/`executeTraced`/`executeImpl`) now
  take `regs: RegWindow`; the dispatch loop wraps the hot `regs` slice with
  `RegWindow.of(regs)` at each call site. **Deliberately left as raw slices for
  phase 2** (they are a control-flow restructure, not an accessor swap): the hot
  window backing `var regs = self.stack[base..]`, the native arg/out slice
  boundaries (`self.stack[base+a+1..]` etc.), and the `callValue` handler slice.
  All `inline` over `[]Value`, so it compiles identically — `just test` green
  (all 8 modes) and `just bench` shows no movement.
- [x] **Phase 2 — the atomic flip, folded with the hot-arm rewrite (the win).**
  One commit: `Vm.stack: []Value` → `tags: []u8` + `payloads: []u64` (allocated
  together at VM init with matching `defer deinit`). `RegWindow`
  (`src/regwindow.zig`) now holds `tags: [*]u8 + payloads: [*]u64 + n` and exposes
  raw gather/scatter (`get`/`set`) for cold consumers plus direct
  `tagAt`/`bitsAt`/`setInt`/`setFloat`/`setBool`/`setNil`/`copy` for the hot arms.
  The ~60–70 hot arms (`load_*`, `move`, all arith via `binNum`/`binBit`, `div`,
  comparisons, jumps, `for_*`/`tfor_loop`, get/set index, globals, closures,
  upvalues, `new_table`, vararg) read `payloads[b]`/`tags[b]` directly and write
  `payloads[a]`/`tags[a]` — the `Value` never materializes in the arithmetic path.
  GC scan, keyframeser, and `upvalGet`/`upvalSet` iterate the two arrays moving
  **raw payload bits** (`payload.bits`, `@bitCast`) — no float/NaN
  recanonicalization. **Native ABI:** `CompiledTrace.run(regs: RegWindow)` lowers
  to `EntryFn = fn([*]u8, [*]u64) callconv(.c)` — rdi=tags (scale-1 tag check via
  `cmpByteMemImm`/`movByteMemImm`), rsi=payloads (scale-8, rsi reserved out of the
  allocator pools so the two base pointers never collide). Natives keep their
  `[]Value` ABI via an absolute-indexed `Vm.boundary_scratch` materialized on
  demand (`gatherScratch`/`scratchOut`/`scatterScratch`), nesting-safe — so no
  native signature changes.
- [x] **Phase 2 verify.** All 8 modes byte-identical (`just test` exit 0,
  `expectProgram` + determinism corpus), native JIT smoke-tested int + float
  (`sum`/`fsum` match tier-0; `--dump-native` compiles), `just bench` every
  `cross=ok`. A pure-tier-0 `perf record` of an arithmetic loop confirms the win:
  `shll $0x4` is **gone** from the hot loop (0 samples), payload access is scale-8
  free SIB (`movq (%rcx,%r12,8)` / `imulq (%rcx,%r12,8)`), tag access is scale-1
  (`movzbl (%r10,%r12)`), and `vmovapd …(%rbp)` spills collapsed from ~40 % to a
  single 1.44 % site. Codex + Antigravity review of the gather/scatter determinism
  + native ABI, then Bart's commit approval, are the remaining gates.

### Outstanding

- [ ] **Commit gate.** Codex + Antigravity review of the Phase 2 gather/scatter
  determinism (raw payload bits, no recanonicalization) + the native two-pointer
  ABI, then Bart's explicit commit approval (Rule #15). The implementation is
  complete and green; nothing here changes the tree, only clears it to land.

## Why this exists

mahina's register file is `Vm.stack: []Value` — a 16-byte tagged `Value` per slot
(`gpa.alloc(Value, stack_slots)`, `interp.zig`). Profiling the tier-0 interpreter on
the array-arithmetic scimark kernels (pure tier-0, ReleaseFast) showed it is **purely
instruction-throughput-bound**: 3.82 IPC, 0.00 stalled cycles/insn, 0.03 % L1 misses,
0.01 % branch misses. Every retired instruction we delete therefore pays ~linearly.
The 16-byte `Value` is the cost driver in two ways:

1. **Register pressure → stack spills** (`vmovapd …(%rbp)`, ~40 % of samples). Each
   `Value` eats a whole XMM / GP-pair, so the arithmetic temporaries of a body like
   SOR overflow the register file and spill.
2. **Lost free-scaled addressing** (`shll $0x4`, the single hottest instruction).
   x86 SIB scale caps at 8; a 16-byte stride needs an explicit shift per access that
   an 8-byte stride folds into the load for free.

The fix is **Struct-of-Arrays**: store the register stack as parallel `tags: []u8` +
`payloads: []u64` (8-byte payloads). The hot arms then check a 1-byte tag (scale-1,
free) and operate on an 8-byte payload (scale-8, free) — no `shl`, half the register
footprint, spills largely gone.

This is the **determinism-preserving** equivalent of LuaJIT's one-register value:
NaN-boxing is forbidden here (the snapshot serializer reads `payload.bits` explicitly
— see `02-determinism.md`), so we cannot shrink the `Value` *type*. We instead split
only the register *storage*, keeping `Value` a 16-byte struct everywhere it is passed
by value (natives, calls, constants, table values, upvalue `closed`). Table array
storage (`array.zig` lanes) is already separate and unaffected.

Payoff is bounded to programs that stay in tier-0 (trace-aborting loops); the headline
benchmarks like SOR already escape to the JIT (~10×). This is the right interpreter
representation regardless, and the win lands on the genuinely-interpreted remainder.

## Goals

- Eliminate the `shll $0x4` register-index scaling and the bulk of the 16-byte
  arithmetic-temporary spills from the tier-0 hot arms.
- Keep all 8 execution modes byte-identical and the keyframe wire format unchanged.
- Confine the storage representation behind a `RegWindow` seam so the flip is a
  localized change, not a sweep.

## Non-goals (v1)

- **NaN-boxing / shrinking the `Value` type.** Forbidden by the determinism design.
- **Native-codegen quality.** The residual ~5× vs LuaJIT on already-traced loops
  (e.g. SOR) is a `nativegen`/`tropt` concern, not this change.

## The three hard interfaces

- **Upvalue.** Index-based open (`loc.open: usize`) / owned-`Value` closed
  (`loc.closed: Value`); value access Vm-mediated (`upvalGet`/`upvalSet`). No raw
  `*Value` into the stack — the one representation that a split storage cannot
  express. `OpenUpvalue { index, cell }` already tracks the slot index, so the
  pointer was redundant.
- **RegWindow.** A value-semantics struct of pre-offset `tags`/`payloads` base
  pointers for the current frame; `inline get/set` (gather/scatter, for the cold
  consumers) plus direct `payload(slot)`/`tag(slot)` accessors (for the hot arms).
  Chosen over passing `(vm, base)` to avoid a hot-loop indirection.
- **Native run ABI.** `CompiledTrace.run` takes two base pointers (tags, payloads);
  slot addressing becomes the free scale-1 / scale-8 forms; `flushSlot` deopt
  writeback mirrors.

## Constraints (non-negotiable)

- **Byte-identical across all 8 modes + replay** (Rule Z-3 gate). Computed results
  are identical (same arithmetic on the same payload bits); only transient storage
  layout changes. Payload bits must round-trip **raw** — no float/NaN
  recanonicalization on gather/scatter.
- **Snapshot wire format unchanged.** keyframeser serializes via `toSchemaValue`
  (logical tag + 8-byte bits), layout-independent — must stay byte-for-byte
  identical.
- Allocator injected; the two arrays get matching `defer deinit` (Rule Z-4).
- `stack_top`/`reg_top` stay slot-index counts (NOT byte offsets) — all
  multret/vararg bound tracking is untouched.

## Phasing

### Phase 0 — index-based upvalues

The one hard blocker. `function.Upvalue { ptr: *Value, closed: Value }` held an
interior pointer into the stack for an open cell (`&stack[index]`). A raw `*Value`
into the register stack cannot survive the storage split. `OpenUpvalue { index,
cell }` already tracks the slot index, so the pointer is redundant.

- **Rep change.** `Upvalue.loc: union(enum) { open: usize, closed: Value }`. Open ⇒
  the value lives in the register stack at `index`; closed ⇒ the value was copied out
  of the departed slot and is owned here.
- **Value access is Vm-mediated.** `Vm.upvalGet(uv)` / `Vm.upvalSet(uv, v)`: open ⇒
  read/write `stack[index]`; closed ⇒ the owned `Value`. Every call site has `self`
  (the two interpreter arms; capture/close).
- **Close** copies the live slot value into the cell: `closeUpvaluesFrom` reads
  `stack[ou.index]` and calls `cell.closeWith(v)`.
- **GC mark** marks only the closed value; an open cell's value is already a root via
  the live-stack root scan, so re-marking it is redundant (and impossible without the
  stack from `gc.zig`).
- **Keyframe ser/restore.** The serializer resolves an open cell's value from the VM
  stack (`vm.upvalGet`); restore sets `loc = .{ .open = stack_index }` instead of an
  interior pointer. Wire bytes unchanged (open upvalues are absent at the F2a
  quiescent capture point; the value still rides the captured `stack[]`).
- **Green because** it's a pure indirection swap over the still-`[]Value` stack.

### Phase 1 — `RegWindow` abstraction routed through cold consumers

Introduce the access seam **before** flipping storage so the flip is localized. Over
the AoS `[]Value` the window simply wraps it; `inline` accessors compile identically,
so this is perf-neutral. Route the cold consumers through it (irinterp slot_load +
phi-writeback, trace fingerprint + recording refOf, the cold structural
call/ret/vararg sites, GC scan, keyframeser ser/restore). Hot arms deliberately stay
on `regs[...]` — they get rewritten directly at the flip, avoiding a wasted
intermediate form.

### Phase 2 — the atomic flip, folded with the hot-arm rewrite

One commit (main never regresses): storage becomes `tags: []u8` + `payloads: []u64`;
`RegWindow` internals become real gather/scatter; GC scan iterates indices checking
`tags[i]`; keyframeser gathers each slot → `toSchemaValue` (wire bytes identical);
`upvalGet`/`upvalSet` open case reads/writes the two arrays at `index`; the ~60–70 hot
arms read `payloads[b]`/`payloads[c]` + check `tags[b]`/`tags[c]` and write
`payloads[a]` + `tags[a]` (the `Value` never materializes in the arithmetic path); the
native ABI splits to two base pointers; irinterp window internals swap to the two
arrays.

## Risks / hazards

- **Native rsi stability** — two live base pointers across the trace body vs one
  today; confirm the register allocator/clobber set in `nativegen` handles it.
- **Determinism trap** — gather/scatter must move payload bits raw
  (`@bitCast`/`payload.bits`), never via float ops that could recanonicalize a NaN.
  GC heap-ptr reconstruction must equal `asHeap()`.
- **Phase 2 size** — large but irreducibly atomic; phases 0–1 shrink it by
  pre-landing the upvalue + seam changes.

## Open questions for review

- [ ] **rsi callee-stability in the native ABI.** Does keeping both `tags` and
  `payloads` base pointers live across a trace body fit the current clobber set, or
  does one need re-materializing from a spill slot per use?

## References

- `00-architecture.md` — tier model, `Value` contract, principle #4 (stay on
  bedrock, confine churn).
- `03-gc-memory.md` — root scanning, open/closed upvalue lifecycle.
- `04-snapshot-replay-schema.md` — keyframe wire format (the byte-identity contract).
- LuaJIT `src/lj_obj.h` (NaN-boxed `TValue`) — the one-register value this adapts
  determinism-safely.
