APPROVE

The edits in revision 6 correctly address all review findings from round 5 and introduce no new problems or inconsistencies with the codebase:

1. **Leaf refusal by return type and latched violation (§5.12)**
   - **Verified**: Non-status functions in the C API ([`capi.zig:555–575`](file:///home/bart/Projects/lune/src/capi.zig#L555-L575))—`mh_output`, `mh_last_error`, and `mh_warnings` returning `mh_str`, and `mh_output_clear` and `mh_warnings_clear` returning `void`—return neutral empty values (`.{}`) or `void` without executing. Status-returning functions return `MH_ERR_API`.
   - Latching `vm.leaf_violation` during `vm.leaf_call_active` ensures that [`cHostCall`](file:///home/bart/Projects/lune/src/capi.zig#L1114-L1141) traps any forbidden API invocation as a `lua_error`, even if an external callback ignores the error and returns `MH_OK`.

2. **Tier-1a seed-context address and missing-context check (§5.8)**
   - **Verified**: The pointer is correctly identified as `self.trace.registry.native_seed_ctx` ([`trace_registry.zig:19`](file:///home/bart/Projects/lune/src/trace_registry.zig#L19), [`:84`](file:///home/bart/Projects/lune/src/trace_registry.zig#L84)), initialized in `prepareNativeEpisode` before execution ([`interp.zig:1481`](file:///home/bart/Projects/lune/src/interp.zig#L1481), [`:4309`](file:///home/bart/Projects/lune/src/interp.zig#L4309)).
   - Tier-1a's [`ExecCtx`](file:///home/bart/Projects/lune/src/irinterp.zig#L241) receives this pointer, and the rule that a tier-1a trace containing `call_host` refuses execution if `seed_ctx` is missing prevents any null-pointer dereference when calling the C shim.

3. **Single owner for `suspend_depth` and release-point wording (§5.9, §5.10)**
   - **Verified**: Ownership is unambiguous:
     - For traced calls, `mahina_trace_host_call` exclusively raises and lowers `suspend_depth`.
     - For tier-0 calls during an active recording (`self.trace.isRecording()`), [`callHostNative`](file:///home/bart/Projects/lune/src/interp.zig#L2258-L2271) exclusively raises and lowers `suspend_depth`.
   - The release point in §5.10 correctly states that `callHostNative` drains deferred retirement only when lowering a suspension it raised itself with no lease outstanding, while a traced call's shim never drains because its entry wrapper still holds an `entry_lease`.

4. **Shim copies the `host_out` slice (§5.8)**
   - **Verified**: Matches tier-0 semantics ([`interp.zig:6761–6774`](file:///home/bart/Projects/lune/src/interp.zig#L6761-L6774)). [`callHostNative`](file:///home/bart/Projects/lune/src/interp.zig#L2258-L2271) writes results to `self.host_out` and returns a `[]const Value` slice. The trace shim copies this slice into `regs[base + site.a ..]` and nil-pads up to `site.nwanted`.

5. **Site index in `ins.a` for `call_host` (§5.1)**
   - **Verified**: `call_host`, `guard_host_epoch`, and `host_result` now consistently store `site index` in `ins.a` ([`trace_ir.zig:810–816`](file:///home/bart/Projects/lune/src/trace_ir.zig#L810-L816)), standardizing site referencing across all host-call IR instructions.
