# Doc 60 rev 1 — antigravity review (2026-10-02)

Reviewer: Antigravity (tools enabled, read-only brief). No files modified.

## Verdict: CHANGES REQUESTED

The proposed architecture is promising and the goal of cutting host-call overhead below LuaJIT's 304 instructions is achievable. However, the design document has four soundness blockers: an omitted `CallFrame` field that causes silent bytecode/image corruption upon frame-slot reuse, an unhandled `.switch_mode` transition that will crash or corrupt VM state when JIT recording triggers mid-call, missing trace exit/abort cleanup, and an unsound argument rooting generalization for native callees. Furthermore, the instruction budget in §5.2 omits the mandatory setup of `ExecState` (~25+ instructions), and the proposed fast-path bitmask architecture breaks `TraceState`'s standalone modularity.

---

### BLOCKERS

#### 1. Omitted `CallFrame.code_cache_gen` invalidation causes stale code cache hits / bytecode corruption
- **Evidence:** `docs/design/60-hand-written-machine-code.md:202`, `src/interp.zig:393-410`, `src/interp.zig:2027-2036` (`pushFrameTrusted`), `src/interp.zig:2485` (`cachedCodeFor`).
- **Details:** The doc claims in §5.1 line 202 that writing a `CallFrame` consists of `8 fields | 8 fields`. In `src/interp.zig:366-410`, `CallFrame` actually has 10 fields (or 9 named fields, one being a 2-word slice):
  1. `closure`, 2. `call_seq`, 3. `base`, 4. `pc`, 5. `ret_dest`, 6. `ret_count`, 7. `varargs_base`, 8. `varargs_count`, 9. `code_cache: []const Instr`, 10. `code_cache_gen: u64`.
  In `pushFrameTrusted` (`src/interp.zig:2027`), Zig struct-literal initialization automatically applies default values, setting `code_cache_gen = CODE_CACHE_GEN_INVALID` (`std.math.maxInt(u64)`).
  As documented in `src/interp.zig:398-408`:
  > *"Push-time defaults are the invalidation (a full struct-literal reassignment covers frame-slot reuse... Doc 54 P0: the validity encoding is a plain-u64 sentinel... the inline native push replicates this struct literal's invalidation as one qword store of -1)"*

  If the hand-written entry only stores the 8 fields listed in doc 60, `code_cache` and `code_cache_gen` in a reused frame slot retain the generation and code slice of a *prior* call executed at that depth. When `cachedCodeFor(frame, cp)` runs (`src/interp.zig:2485`), if `code_cache_gen == image_gen`, it will falsely hit and execute the bytecode image of an unrelated function! Invalidating `code_cache_gen` (storing `-1` / `0xFFFFFFFFFFFFFFFF`) is mandatory.

#### 2. Unhandled `.switch_mode` transition will crash or break JIT trace arming
- **Evidence:** `docs/design/60-hand-written-machine-code.md:184-188`, `src/interp.zig:2506-2512` (`execWithEntry`), `src/interp.zig:5706, 5798, 5897, 6336, 6562`.
- **Details:** §4.3 assumes the dispatch chain returns only `.finished` (success) or `.err` (`st.err`). But inside the `.fast` handler chain:
  - If a backward jump triggers recording (`self.trace.isRecording()`), handlers return `.switch_mode` (`src/interp.zig:5706, 5798, 5897`).
  - If `opCall` arms a pending head recording, it returns `.switch_mode` (`src/interp.zig:6336`).
  - If `opRet` arms a return continuation, it returns `.switch_mode` (`src/interp.zig:6562`).
  In `execWithEntry` (`src/interp.zig:2506-2512`), `.switch_mode` exits the chain, parks `frame.pc`, and falls through to `self.execWith(stop_depth)`. If the hand-written host-call entry assumes only `.finished` and `.err`, any call that initiates trace recording mid-execution will be mishandled (either panic on unexpected `HandlerResult` or fail to resume the execution in `.full` mode).

#### 3. Missing `clearPendingExitAnchor()` and `abortRaised()` on exit / unwind
- **Evidence:** `docs/design/60-hand-written-machine-code.md:173-188`, `src/interp.zig:2476-2477, 2496, 2503`, `src/trace_link.zig:310-318`, `src/trace.zig:3007-3008`.
- **Details:** `execWithEntry` wraps execution in two mandatory lifecycle hooks:
  - On normal `.finished` or `.suspended`: `self.trace.clearPendingExitAnchor();` (`src/interp.zig:2496, 2503`). Without this, if an inner trace side-exited just before returning, a stale `pending_exit_anchor` remains set, permanently locking the VM in `.full` mode (`src/trace_link.zig:310-312`).
  - On error unwinding: `errdefer self.trace.clearPendingExitAnchor();` and `errdefer self.trace.abortRaised();` (`src/interp.zig:2476-2477`). Without `abortRaised()`, an in-flight recording survives the raise and splices an enclosing pcall's continuation onto partial iterations (doc 26 D1a).
  These must be part of §4.3's state contract.

#### 4. Q1: Redundant pre-parking claim is FALSE for Native callees and Metamethod fallbacks
- **Evidence:** `docs/design/60-hand-written-machine-code.md:197, 275-279`, `src/capi.zig:701-704`, `src/interp.zig:2105-2137` (`callValue`), `src/interp.zig:2342-2391` (`forEachRootHeader`).
- **Verification of allocation points:** Between validation and the register window write for a closure callee, the path is:
  `checkFatal` → `fromC` → `argsSlice` → `parkClearIfIdle` → check `max_native_reentry` → check `max_call_depth` → check `regCapacity` → write `args` to `self.stack` → nil-fill remaining slots → `pushFrameTrusted`.
  **There are exactly zero allocations or GC triggers on this path.** Once `pushFrameTrusted` completes, `callee` is rooted in `self.frames[depth-1]` and `args` are rooted in `self.stack[0..stack_top]`. Thus, for a closure callee, pre-parking is indeed 100% redundant.
- **The flaw:** For **Native callees** (and `__call` before redirect), `callValue` (`src/interp.zig:2109-2137`) does **not** push a frame, does **not** allocate register window slots, and does **not** advance `stack_top`. Native args are passed as a bare slice `args: []const Value` directly to `nat.func` or `nat.host`.
  If `mh_call` drops pre-parking globally: when a host native or builtin native is called at `depth == 0`, if that native allocates (e.g. creating a string, table, or callback allocation) and triggers GC, `forEachRootHeader` will scan `self.stack[0..0]` and find nothing. Any heap-allocated argument passed from C that was only rooted by the host's borrowed reference will be swept as garbage!
  - **Requirement:** Pre-parking can only be omitted on the dedicated closure entry path. The fallback path for natives and `__call` MUST continue to park `callee` and `args` (or explicitly root them in a stack window).

---

### SHOULD-FIX

#### 5. Instruction budget (§5.2) completely omits `ExecState` construction
- **Evidence:** `docs/design/60-hand-written-machine-code.md:210-222`, `src/interp.zig:2480-2492`, `src/interp.zig:2584-2611`.
- **Details:** §5.2 budgets "chain entry (seam): 5–10 instr" and "entry total: ~45–70 instr".
  Every opcode handler and dispatch helper takes `st: *ExecState` as its first parameter. `ExecState` is a 104-byte struct with 11 fields (`vm`, `frame`, `closure`, `proto`, `code` [ptr + len], `code_gen`, `base`, `regs` [tags + payloads], `stop_depth`, `step`, `err`).
  Whether constructed in assembly before calling the C-ABI shim or constructed inside the shim, populating `ExecState` on the stack requires at least 25–35 instructions:
  - 11 stores to stack.
  - Address calculations for `st.regs.tags` (`vm.stack_tags + base`) and `st.regs.payloads` (`vm.stack_payloads + base * 8`).
  - Loading `image_gen` and `cachedCodeFor`.
  - Setting up the SysV argument registers (`%rdi..%r9`).
  Additionally, §5.2's "result copy, park, restore: 8–12" omits restoring `vm.native_reentry_depth`, restoring `vm.stack_top`, clearing exit anchors, and checking inline park capacity.
  A realistic budget for the minimal entry path is **~95–100 instructions** (still beating LuaJIT's 304 by ~200 instructions, but not 45–70).

#### 6. Packed fast-path word (§8 Q4) breaks `TraceState` standalone unit tests
- **Evidence:** `docs/design/60-hand-written-machine-code.md:286-302`, `src/trace.zig:892`, `src/trace_gate_test.zig:479, 651, 727, 800, 857`.
- **Details:** The doc proposes putting a `u16` fast-path bitmask on `Vm` and updating it across ~31 write sites in `trace.zig`, `trace_link.zig`, and `trace_recorder.zig`.
  However, `TraceState` does **not** have a pointer to `Vm`. Furthermore, dozens of tests in `src/trace_gate_test.zig` and `src/trace_replay_test.zig` instantiate `TraceState` as a standalone struct (`var state = TraceState.init(gpa);`) without any enclosing `Vm`.
  If helper functions in `trace_link.zig` attempt to update bits on `Vm` via `@fieldParentPtr(Vm, "trace", self)`, every standalone `TraceState` test will segfault or corrupt memory.
  - **Better Design:** 7 of the 9 conditions belong to `TraceState` (the 6 pending anchors + `rec.active`). Put a `u8` or tagged union directly on `TraceState`. Notice that `pending_exit_anchor`, `pending_replay_anchor`, `pending_call_anchor`, `pending_ret_anchor`, etc. are mutually exclusive transient requests consumed at the very next instruction. If unified into a single tagged union `pending: union(enum) { none, exit: ..., call: ..., ... }`, checking whether any anchor is pending becomes a single byte comparison (`trace.pending != .none`), clearing all anchors becomes `trace.pending = .none` (eliminating multi-site clears), and `TraceState` remains self-contained.

#### 7. M3 factually misattributes LuaJIT's model and violates embedding W^X constraints
- **Evidence:** `docs/design/60-hand-written-machine-code.md:123-139`, `/home/bart/Projects/LuaJIT/src/Makefile:675-688`.
- **Details:** §3 claims: *"Generating the VM's hand-written parts at start-up is LuaJIT's model too: DynASM generates its VM."*
  This is factually false. In LuaJIT, DynASM is a **build-time preprocessor** (`Makefile:677`). `buildvm` generates static assembly (`lj_vm.s`) with symbols and CFI unwind tables, which is assembled into `libluajit.a`'s text segment. LuaJIT's VM is never emitted into runtime-allocated executable memory.
  M3 (runtime emission with `x64.zig`) has severe unlisted drawbacks for an embedding library:
  - **W^X violations:** Hardened environments (iOS, game consoles, web browsers/wasm, SELinux) forbid mapping runtime pages with `PROT_EXEC`. Doc 59 §3.7 explicitly introduced `mh_config.jit = 2` (pure interpreted mode) for these targets; M3 would re-break them even with JIT disabled.
  - **Per-VM memory overhead:** Allocating an executable page per `VmBox` wastes at least 4KB of executable memory per instance.
  - **Tooling:** Emitted memory appears as anonymous `[JIT]` in `perf` and callgrind without external map files.
  M1 (`callconv(.naked)` inline asm) or M2 (build-time `.S`) is far superior for this use case.

#### 8. §6 test plan incorrectly cites `hashgate` as determinism coverage for `mh_call`
- **Evidence:** `docs/design/60-hand-written-machine-code.md:245-247`, `justfile:55-57`.
- **Details:** §6 states: *"The existing gates (zig build test, just hashgate, the Rust crate tests) run unchanged. Hashgate covers determinism."*
  `just hashgate` (`tools/hashgate.py`) executes only the CLI binary (`zig-out/bin/mahina`) running benchmark/test scripts. It does not invoke `libmahina.a`'s C API entry points (`mh_call`).
  Determinism and replay equivalence for host calls must be tested by dedicated C-API / Rust embedding tests that record and compare keyframe hashes across runs.

---

### NITS

#### 9. Missing DWARF CFI directives in M1/M2 breaks profiler/debugger unwinding
- **Evidence:** `docs/design/60-hand-written-machine-code.md:105-122`, `src/capi.zig:82-103`.
- **Details:** If M1 (`callconv(.naked)`) is chosen, the routine will lack DWARF Call Frame Information unless hand-written `.cfi_*` directives are emitted in the asm string. When an embedder runs under `perf record -g` or inspects a crash in `gdb`/`lldb`, the stack trace will fail to unwind across `host -> mh_call -> guest -> host callback`.

#### 10. Missing boundary/fuzz tests in §6
- **Evidence:** `docs/design/60-hand-written-machine-code.md:230-244`.
- **Details:** §6 lists valid shapes and guest errors, but omits boundary inputs: invalid value tags (`0xFF`), `row_view` tags, null heap pointers, and hitting recursion depth limits (`depth >= max_call_depth` or `stack_top + num_registers > regCapacity`). These must return `MH_ERR_API` or `MH_ERR_RUNTIME` without corrupting VM state.

#### 11. §7 candidate list: opcode handlers require an all-or-nothing dispatch design
- **Evidence:** `docs/design/60-hand-written-machine-code.md:263-264`.
- **Details:** §7 lists "the doc-42 handlers for the hottest opcodes" as candidates for piecemeal hand-written code. Because handlers musttail among themselves with a uniform signature (`src/interp.zig:2624`), individual handlers cannot be written in naked assembly without changing the calling convention of all handlers or routing through trampoline seams on every opcode hop. Writing handlers by hand only makes architectural sense as a complete assembly interpreter (DynASM/LuaJIT style), not piecemeal.
