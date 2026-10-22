# Doc 68 — round-1 review (antigravity, 2026-10-22)

Asked for a read-only review of doc 68 rev 1 against the tree and LuaJIT,
with tool access. Findings as given, lightly condensed (code excerpts and
link markup dropped; every claim and citation kept):

---

| # | Severity | Finding | Primary location |
|---|---|---|---|
| F-1 | Critical | Type confusion from placing `*const Native` into `CallFrame.closure: *const Closure` | `interp.zig:421`, `function.zig:99-140` |
| F-2 | Critical | Advancing the parent `pc` to `P + 1` with `in_flight = false` breaks the GC `frameShape` assertion and lets GC scrub live continuation operands | `interp.zig:2651-2717`, `:2814-2825` |
| F-3 | Critical | `xpcall`: a catchable error in the handler re-finds the `.protected` frame and runs the handler again, forever | doc 68 §6.1, `errors.zig:104-124` |
| F-4 | Critical | Fused `set_index2` (`a[i][j] = v`) omitted; `cont_aux: u16` cannot hold both key2 and the value | `interp.zig:8330-8350`, `:7120-7126` |
| F-5 | Major | Keyframe restore rejects native activation frames (`FrameNotAClosure`) | `keyframeser.zig:876-887` |
| F-6 | Major | `pcall` multret results: `reg_top`/`reg_top_pending` stamping and the `ret_dest + 1` shift unspecified | `interp.zig:7567-7571` |
| F-7 | Major | Phasing inversion: `pcall` is a native, so P2 needs P3's machinery or an `opCall` special case | doc 68 §10 |
| F-8 | Major | Advancing `pc` early misattributes faults raised by a continuation (`describeFault`, backtraces) | `interp.zig:1848-1850`, `:2027-2035` |
| F-9 | Medium | `hostcall_x64.S` must zero the new fields | `hostcall_x64.S:261-265` |
| F-10 | Medium | `opRet` calls `onRetResume` on the parent's `pc` after a metamethod returns, arming `.cont` recording after a non-call instruction | `interp.zig:7588`, `trace.zig:3706-3727` |

**F-1.** `Closure` is `{header, proto, upvalues}`, `Native` is `{header, func, name, effect, …}`. `frame.closure.proto` is read unconditionally in `callSiteAt` (`interp.zig:1846`), `backtraceFrames` (`:2106`), `synthErrorValue` (`:2553`), `assertFrameShapesKnown` (`:2669`, `:2684`), `frameMask` (`:2696`), `fillKeep` (`:2774`), `reloadTopFrame` (`:3210`), `execImpl` (`:5845`), `wasm_entry.zig:542`. Fix: an explicit frame kind (`lua`/`native`, or a `Callee` union) as LuaJIT's `FRAME_LUA`/`FRAME_C`, or an immortal dummy `Proto`/`Closure` per resumable native (`num_registers = num_state`, empty code, `maskable = false`); every stack walker branches on the kind.

**F-2.** `frameShape` (`:2651-2679`) classifies a non-innermost, not-in-flight frame by `code[pc - 1]`; after `.add` it is `.unknown`, and `assertFrameShapesKnown` panics at the first GC inside a metamethod. And `live_in[P + 1]` (`bc_liveness.zig:11-12`) omits operands only `P` uses: during `get_index2`'s `__index`, a GC `scrubDeadRegisters` (`:2814-2825`) sets key2 to nil before `index_second` reads it. Fix: keep the parent at `P` (LuaJIT keeps the original PC in the continuation frame, `lj_meta.c:113`), classified `in_flight` or a new continuation shape so `row(P)` applies; narrow `encodeSnapshot`'s refusal from `in_flight` to `native_reentry_depth != 0`; advance to `P + 1` in `finishCont`.

**F-3.** Fix: mark the protection as handling (e.g. `.in_handler`) or detect an `.xpcall_handler` frame above it; a non-catchable error propagates; a catchable one unwinds `h` and the faulting frames to the protection and produces `false, "error in error handling"` without re-running `h`.

**F-4.** `fusedStore` does `indexGet(container, key1)` then `indexSet(mid, key2, val)`; `opSetIndex2` has four operand registers. Fix: a `set_second` continuation, with key2 and the value either packed in a wider `cont_aux` or read from `code[P]` (keeping `P` as the anchor).

**F-5.** Restore requires `fh.type == .function` and reads `cl.proto`; natives are rebound from `base_natives` by name. Fix: `FrameRef` says whether the frame is a closure or a native activation; restore resolves the native, allocates `num_state` registers, restores the step cursor.

**F-6.** `opRet` stamps `reg_top`/`reg_top_pending` when the caller wants all results (`:7567-7571`). Fix: specify `.protected`'s contract — `true` at `ret_dest`, results from `ret_dest + 1`, and on `all_results` `reg_top = base + ret_dest + 1 + n` (error: `+ 2`) with `reg_top_pending = true`.

**F-7.** Fix: build the native-activation machinery first with `pcall` as the first resumable native, then migrate the rest.

**F-8.** `callSiteAt` (`:1848-1850`) uses `f.pc` only when the frame is top or in flight; `describeFault` reads `code[pc]`. With the parent at `P + 1`, a continuation's own fault (`__tostring` returning a number, `index_second` type error) points at the next instruction. Fix: as F-2.

**F-9.** Add `CF_CONT`/`CF_CONT_AUX` to `offsets_x64.inc` and zero them in `hostcall_x64.S`.

**F-10.** Fix: call `onRetResume` only when the popped frame's `cont == .none`.

**Q2 — recommend (b), pieces in a table.** A byte-buffer kind means a new `ObjectType`, GC mark/sweep, schema and keyframe support and a determinism proof, for a callback path that is not hot (Rules Z-6, Z-2). Tables and strings already work everywhere.

**Q3 — recommend (a), defer, with guarded arming.** Refusing would make any program using an embedder binding fail as soon as a debugger arms a step. Once P1–P3 land, `native_reentry_depth` is 0 throughout guest and stdlib code, so only external C API calls defer. Return an API error if an embedder calls `setSuspendCtl` from inside a C callback.
