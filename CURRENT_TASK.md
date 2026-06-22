# CURRENT TASK — SoA register file (split Vm.stack into tags[] + payloads[])

Governing arc: chase Lua compatibility so lune is usable, THEN optimize toward
LuaJIT parity. Tier-0 is instruction-throughput-bound (3.82 IPC, ~0 stalls); the
16-byte `Value` drives register-pressure spills (`vmovapd …(%rbp)`) and the
`shll $0x4` index-scaling. The fix is Struct-of-Arrays storage: `tags: []u8` +
`payloads: []u64`. NaN-boxing stays FORBIDDEN — only the register *storage* splits;
`Value` stays 16 bytes everywhere it's passed by value. Full design + phasing:
`docs/design/09-soa-register-file.md`.

## Phase 0 — index-based upvalues — DONE, GREEN (uncommitted, awaiting Bart's approval)

The one hard blocker for the storage flip: an open `function.Upvalue` held a raw
`*Value` into the stack (`&stack[index]`), which a split storage can't express.
`OpenUpvalue { index, cell }` already tracked the slot index, so the pointer was
redundant.

Changes (4 files):
- **src/function.zig** — `Upvalue` rep: `ptr: *Value` + `closed: Value` →
  `loc: union(enum){ open: usize, closed: Value }`. `create`→`createOpen(index)` /
  `createClosed(v)`; `get/set/close` removed (value access is now Vm-mediated);
  added `isOpen()` + `closeWith(v)`. Unit test rewritten to the cell state machine.
- **src/interp.zig** — added `Vm.upvalGet(uv)` / `Vm.upvalSet(uv, v)` (open ⇒
  read/write `stack[index]`, closed ⇒ owned value). Wired the `get_upval`/`set_upval`
  arms; `captureUpvalue` calls `newUpvalue(index)`; `closeUpvaluesFrom` calls
  `cell.closeWith(self.stack[ou.index])`.
- **src/gc.zig** — `newUpvalue(*Value)` → `newUpvalue(index: usize)`; mark arm marks
  ONLY the closed value (an open cell's value is already covered by the live-stack
  root scan in `forEachRootHeader`, and gc.zig has no stack to resolve the index).
- **src/keyframeser.zig** — serializer resolves an open cell's value via
  `vm.upvalGet` (added `vm` param to `toSchemaHeapObject`); Walk skips open (covered
  by the stack root seed); restore builds a closed-nil shell then root-rebinds open
  cells to `.open = stack_index`; updated the stale "VM address must stay fixed"
  comment + two tests (`.get()` → `vm.upvalGet`, `.ptr` → `.loc.open`).
- **docs/design/09-soa-register-file.md** — new design doc; Phase 0 ticked Done.

Wire format unchanged (open upvalues are absent at the F2a quiescent capture point;
their value still rides the captured `stack[]`). No JIT changes — the recorder
aborts on upvalue ops, so trace/irinterp/nativegen don't touch upvalues.

## Reviewer-found bug + fix (Codex + Antigravity, both independently)
The `pcall`/`xpcall` error unwind (`src/stdlib/errors.zig` `protectedCall`) restored
`vm.depth`/`vm.stack_top` to the entry boundary WITHOUT closing the faulting frames'
open upvalues. Under the old `*Value` rep, GC marked through `u.ptr.*`, so an escaped
closure's still-open upvalue (slot now ≥ stack_top) kept its value alive — and even
that was semantically loose (the slot could be reused). Under the new index rep, GC
marks only closed values and `forEachRootHeader` only scans `stack[0..stack_top]`, so
the value could be swept / clobbered → dangling. Fix: `closeUpvaluesFrom(entry_top)`
at all three boundary-restore sites (made the helper `pub`). This is also the correct
semantics independent of GC — discarding frames must close their upvalues, exactly as
a normal `ret` does. Added 2 e2e regression tests (pcall + xpcall, with a slot-reuse
`clobber()` so they have teeth — verified they FAIL with the fix disabled).

## Phase 1 — RegWindow seam — DONE, GREEN (uncommitted, awaiting Bart's approval)

Introduced the access seam over the *current* `[]Value` storage so the phase-2 flip
is localized. Two accessors, chosen because the consumers split cleanly into
frame-relative vs whole-stack/cross-frame:

- **`src/regwindow.zig` (NEW) — `RegWindow`**, a frame-relative value-semantics view.
  Phase 1 wraps a `[]Value` slice (`of(slots)`, `get/set/len`, `empty`); phase 2
  swaps its internals to tags/payloads base pointers with no caller change. Consumed
  by the trace recorder + the irinterp executor. Wired into `root.zig` (`pub const` +
  `_ = regwindow;`).
- **`Vm.regGet`/`regSet`/`regCapacity`/`fillNil`/`frameWindow`** (interp.zig, all
  `inline` passthroughs over `self.stack`) — absolute-index accessors for the
  whole-stack / cross-frame consumers: GC root scan (`forEachRootHeader`),
  keyframeser ser/restore, the structural call/ret/vararg per-element copies, open
  upvalue get/set, vararg reads, `stampSingleResult`, `describeFault`, `nativeSite`.

Routed consumers:
- **trace.zig** — 17 production fns (matchesFingerprint, tryChainExit, laneWidenedPast,
  onBackEdge, closeTrace, recordInstr/recordOne, the rec* family) take `regs: RegWindow`;
  `regs[i]`→`regs.get(i)`, `regs.len`→`regs.len()`. (No writes — the recorder only reads.)
- **irinterp.zig** — `execute`/`executeTraced`/`executeImpl` take `regs: RegWindow`;
  slot_load + phi-writeback use `regs.get`/`regs.set`.
- **interp.zig dispatch loop** — wraps the hot `regs` slice with `RegWindow.of(regs)`
  at each recorder/irinterp call site (recordInstr, onBackEdge, matchesFingerprint,
  irinterp.execute, executeTraced, laneWidenedPast, tryChainExit).
- **nativegen.zig / tropt.zig** — test/helper `irinterp.execute` calls wrapped.

**Deliberately left as raw `self.stack[...]` slices for phase 2** (a control-flow
restructure — gather-into-scratch + scatter-back — not an accessor swap): the hot
window backing `var regs = self.stack[base..base+num_registers]` (3 sites), the
native arg/out slice boundaries passed to natives/`callValue`, and the `callValue`
handler slice. These become real gather/scatter at the flip.

Perf-neutral by construction: `inline` over `[]Value` compiles identically.

## Phase 2 — atomic flip + hot-arm rewrite + native ABI — DONE, GREEN (uncommitted, awaiting Bart's approval)

The flip itself, folded with the full hot-arm rewrite and the native ABI change, in
one (uncommitted) change so main never regresses.

- **Storage flip (interp.zig):** `Vm.stack: []Value` → `tags: []u8` + `payloads:
  []u64`, allocated together at VM init with matching `defer deinit` (Rule Z-4).
  `stack_top`/`reg_top` stay slot-index counts (untouched).
- **`src/regwindow.zig`** — `RegWindow` internals now hold `tags: [*]u8 + payloads:
  [*]u64 + n`. `of(tags, payloads)` + gather/scatter `get`/`set` for cold consumers;
  direct `tagAt`/`bitsAt`/`setInt`/`setFloat`/`setBool`/`setNil`/`copy` for the hot
  arms. All payload movement is **raw bits** (`payload.bits`/`@bitCast`) — no
  float/NaN recanonicalization, so 8-mode bytes stay identical.
- **Hot arms (interp.zig, ~60–70):** `load_*`, `move`, all arith (`binNum`/`binBit`
  inline helpers: both-int/both-float fast lanes on raw bits, else `arith.*` +
  `arithMeta`), `div`, comparisons, jumps, `for_*`/`tfor_loop`, get/set index,
  globals, closures, upvalues, `new_table`, vararg — read `payloads[b]`/`tags[b]`
  directly, write `payloads[a]`/`tags[a]`. The `Value` never materializes in arith.
- **Boundary scratch (interp.zig):** natives keep their `[]Value` ABI via a single
  absolute-indexed `Vm.boundary_scratch: []Value` materialized on demand
  (`gatherScratch`/`scratchOut`/`scatterScratch`), nesting-safe (deeper calls park at
  higher absolute indices). No native signature changes (NativeFn/NativeMultiFn/
  callValue/`__call`).
- **GC scan + keyframeser + `upvalGet`/`upvalSet`** iterate the two arrays moving raw
  payload bits; wire format byte-identical.
- **Native ABI (nativegen.zig + x64.zig):** `CompiledTrace.run(regs: RegWindow)` →
  `EntryFn = fn([*]u8, [*]u64) callconv(.c)`; rdi=tags (scale-1 tag check via new
  `x64.movByteMemImm`/`cmpByteMemImm` — a 1-byte store, since the 4-byte
  `movMemImm32` would clobber 3 adjacent slots' tags), rsi=payloads (scale-8). rsi
  reserved out of `ALLOC_ORDER`/`BASE_HOME_ORDER` so the two base pointers never
  collide. Test adapters: `runNative` (nativegen), `executeValues`/
  `executeTracedValues` (irinterp), `winRO`/`TestRegs` (trace.zig) split/scatter
  `[]Value` fixtures across the two lanes.

## Gate
`just test` exit 0 (all 8 modes byte-identical); native JIT smoke-tested int + float
(`sum(1e6)`=500000500000, `fsum`=1500000, both match tier-0; `--dump-native`
compiles a 176-byte trace); `just bench` every `cross=ok` (lone `str_manip` flag is
the pre-existing LuaJIT-reference error, lune side `ok`).

**Perf verification (pure tier-0 arithmetic loop, ReleaseFast, `perf record`):** the
predicted win is confirmed — `shll $0x4` (16-byte index scaling) is **gone** from the
hot loop (0 samples); payload access is scale-8 free SIB (`movq (%rcx,%r12,8)` /
`imulq (%rcx,%r12,8)` / `movq %rax,(%rcx,%rdx,8)`); tag access is scale-1
(`movzbl (%r10,%r12)`); `vmovapd …(%rbp)` spills collapsed from ~40 % to a single
1.44 % site. 88.6 % of samples in `execImpl`, as expected.

Stray untracked files (CURRENT_TASK_E3.md, SESSION_CHANGES.md, check_ordinals,
bench/results/*.tsv) are NOT mine — left untouched.

## Next
- Phases 0 + 1 + 2 all green, uncommitted (Phase 0+1 = commit `79402e0`'s successors;
  Phase 2 on top). The whole stack lands as the atomic SoA change.
- **Codex + Antigravity review** of the Phase 2 gather/scatter determinism (raw
  payload bits, no recanonicalization) + the native two-pointer ABI — the next gate.
- **Do NOT commit any of this without Bart's explicit approval (Rule #15).**
