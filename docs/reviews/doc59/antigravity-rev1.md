# antigravity review — doc 59 rev 1 (2026-10-01)

Verdict: **CHANGES REQUESTED**. Condensed from the verbatim reply (file:line
refs preserved); the per-prompt-area appendix is summarized at the end.

---

1. **[BLOCKER] Chunk & `Proto` use-after-free in `mh_script_free`/`mh_eval`**
   (§3.2). Protos/bytecode/spans live in `Chunk.arena` (compiler.zig:51);
   closures hold raw `cl.proto` pointers (function.zig:96). Freeing the chunk
   while a guest-created function survives ⇒ `gc.blacken`'s
   `markProtoConstants(cl.proto)` (gc.zig:717) and `describeFault`'s
   `proto.source` read (interp.zig:1839) dereference freed memory. Also
   `compileWithOptions` must be given `id_base = vm.next_proto_id`
   (interp.zig:751) or proto IDs collide across scripts. **Fix:** the VM
   already solved this for dynamic scripts via `vm.loaded_chunks`
   (stdlib/load.zig:148, interp.zig:750): owns Chunk + NUL-terminated source
   for the VM's lifetime, advances `next_proto_id`, roots constants in
   `forEachRootHeader` (interp.zig:2239). Embedder compilation should append
   there (or a dedicated VM-owned script list). An independent
   `mh_script_free` that frees the arena is unsound.

2. **[BLOCKER] Rooting gap on "borrowed-until-next-call" results** (§3.2,
   §3.3, §5). `Vm.callValue` restores `stack_top` before returning
   (interp.zig:2082); `forEachRootHeader` only marks `0..stack_top`
   (interp.zig:2213) ⇒ returned results are unrooted the moment `callValue`
   returns, not "until the next call". Any interleaved allocation/GC sweeps
   them. **Fix:** `capi.zig` must maintain an explicit result parking buffer
   on the `mh_vm` handle (e.g. `last_call_results: std.ArrayList(Value)`)
   registered as a root in the `.gc` walk; each new API entry point clears it.

3. **[SHOULD-FIX] `row_view` leakage & GC rooting hole** (§3.2, §5).
   `row_view.isHeap()` is false (value.zig:122) so a `row_view` in
   `host_refs` would NOT mark its parent grid ⇒ dangling. mahina's escape
   model already forbids handing out bare `row_view`s
   (interp_native_test.zig:1169, keyframeser.zig:100). **Fix:** spec that
   `row_view` never crosses the boundary; `indexGet` already deflates
   (interp.zig:7107); `mh_ref_create` must reject it.

4. **[SHOULD-FIX] Lifetime leak of `HostBinding`/userdata under GC** (§3.5).
   If the guest drops the last reference to a registered `Native`, GC calls
   `Native.destroy` (function.zig:347) — but a VM-owned binding list freed
   only at `mh_vm_free` leaks every dead Rust closure until teardown.
   **Fix:** `Native.destroy` runs the binding's destroy hook and frees the
   binding; lifetime ties to GC liveness of the Native.

5. **[SHOULD-FIX] Multi-result host functions deferred behind an ABI break**
   (§3.5, §4). The single-`result` fn-pointer typedef cannot be upgraded
   without breaking it. Returning multiple values (`nil, "msg"`) is standard.
   **Fix:** design `mh_host_fn` with `(results, max_results, *nresults_out)`
   from day one, mirroring `NativeMultiFn` (function.zig:155) — or spec a
   separate additive `mh_register_multi_fn` explicitly.

6. **[SHOULD-FIX] Missing metatable table-stakes** (§3.4, §4). Add
   `mh_table_get_metatable` / `mh_table_set_metatable` in E1/E2; forcing
   embedders through guest `setmetatable` glue is not acceptable for
   mlua-style wrappers.

7. **[SHOULD-FIX] `build.rs` optimization hardcoding & toolchain drift**
   (§3.8). Map Cargo `PROFILE` → Zig optimize mode (debug → Debug/ReleaseSafe,
   release → ReleaseFast); honor `$ZIG` and verify `.zig-version` (Rule Z-1)
   instead of trusting ambient PATH.

8. **[NIT] `Native.name` slice lifetime in `mh_register_fn`** (§3.5).
   `Native.name` is a borrowed slice; a C temporary would dangle
   (keyframeser.zig:188 and describeFault read it). Spec duplication into the
   VM allocator or an interned string.

9. **[NIT] Effect-mode staging must refuse `.replay` too** (§3.7), not just
   `.record` — no host call can be replayed from the log in v1.

10. **[NIT] Generational guard for `mh_ref`** (§3.2, §3.6). A raw u32 index
    has the classic ABA problem after free+reuse. Spec a generational index
    (e.g. index + generation bits) or defined stale-ref detection.

## Appendix (per-area verdicts)

- **GC/rooting:** `host_refs` rooted in the `.gc` walk only is sound and
  keeps snapshot bytes embedder-invariant; free slots must hold `nil`.
  String borrows from a rooted ref are sound under the non-moving GC.
  Reentrancy via `callValue` is structurally sound
  (`max_native_reentry = 200`).
- **§3.5 option (c): APPROVE.** Recorder aborts untagged natives with
  `.host_barrier` (trace_recorder.zig:4101) — zero new JIT code. Keyframe
  restore of an unknown host name cleanly fails `UnknownNative`
  (keyframeser.zig:670) *provided the name doesn't collide with a builtin*.
  One pointer check on a cold path is negligible.
- **§3.7 staging: APPROVE** (with finding 9). `host_call = 7` append is
  clean when E6 comes.
- **ABI:** keep `mh_value` as the opaque 16-byte struct but translate the
  *type* through a stable public C enum (`MH_TYPE_*`); do not expose internal
  tag ordinals. Borrowed results are the right default *given finding 2*.
- **Rust side:** build.rs strategy sound with finding 7; `Ref`-guard model,
  `!Send + !Sync`, and `catch_unwind` at the boundary are correct.
- **Phasing/table-stakes:** add metatable access, multi-return callbacks, an
  execution interrupt / instruction-limit hook (wire to
  `suspend_ctl.after_safepoints`), and ergonomic `IntoValue`/`FromValue`
  traits in E4.
