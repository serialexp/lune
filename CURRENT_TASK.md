# CURRENT_TASK — Exit-branch patching (faithful LuaJIT port), doc 17

## Status 2026-07-11

- **Increment 1 (P-D, shared mcode arena): LANDED** — commit `a970da4`.
- **Increment 2: DESIGNED + PEER-REVIEWED + DECIDED** — commits `4b2c9b0`, `b588fb8`.
  Concrete design in `docs/design/17-exit-branch-patching.md`
  (§"Increment 2 — detailed design"). Reviewed by gpt-5.6-sol: pure-memory
  handoff premise is sound; 3 showstoppers + must-fixes folded in. **Coding not
  started.**

### Unpushed local commits (Rule #15 — don't push unless asked)
`5ba4048 62d619b 911fbaf 01ece13 bf55370 a970da4 4b2c9b0 b588fb8` — master ahead
of origin/master by 8.

## The Increment 2 design in one breath

Make trace→trace transitions happen in machine code (kill the ~600 ns Zig
round-trip). Load-bearing fact: the ONLY state crossing a transition is `regs[]`
(SoA tags/payloads memory), `rbx` (counter), `rsp` (constant when frameless) —
register homes are flushed to `regs[]` at every exit and reloaded by the child's
hoisted prologue. So: one shared **trampoline** owns the C frame (saves all
callee-saved once, reserves one generous 16-aligned spill area, `jmp`s into a
**frameless** body); bodies drop their own push/sub/pop/ret; exits `jmp` a
**link slot** (default `&shared_exit` = today's behaviour; armed by driveChain →
child body = native handoff). No code patching in Inc 2 (that's Inc 3).

### P-F DECIDED (Bart): replicate-but-inert
Per-hop accounting is carried in a transition record **gated by a config flag**
(like `record_exec_log`): ON for the 10-mode matrix/goldens (assert byte-identical
tiering metadata across modes), OFF in production (skip it, keep the handoff cheap).

### Review showstoppers already folded into the doc (MUST honour when coding)
1. Loop-done dual materialization: default slot must NOT commit the final
   iteration — select ordinary-deopt-stub vs linked-materialize-stub BEFORE
   materializing, don't put the snapshot before a shared tail.
2. Dangling code links: P-E lifetime is NOT deferrable — `removeTrace`→arena
   free-list reuse + widen-eviction make code-UAF reachable in normal operation.
   Reset inbound slots before destroy (backlinks / refcount / generation check).
3. Child prologue-fail must carry cumulative progress + distinct reason, not
   `completed=0`.
Plus must-fixes: `completed` ≠ raw cumulative rbx (nested roll-up is +1/inner
run); every exit consumer must index the FINAL trace not the parent; stable
never-reassigned trace id (cache index is swapRemove'd); 16-byte frame rounding
incl. callout-save region; slot reachability/W^X (nearby RW page or imm64+`jmp
[rax]`); safepoint blackout bound (unarm when observation hooks active);
`body_entry` = child guards/reloads/preheader, NOT loop_top.

## NEXT: Increment 2 sub-step 2.1 — trampoline + frameless bodies (turnkey plan)

Pure ABI move, **byte-identical**, NO linking / NO ChainResult yet (keep
`NativeResult`). This isolates the risky stack-discipline change.

Key code (all nativegen.zig unless noted), verified 2026-07-11:
- `NativeResult` :502; `CompiledTrace`/`EntryFn`/`run`/`runWithLinkedLoopDone`
  :513-542 (builds result, calls `page.entry(EntryFn)(tags,payloads,&result)`).
- `emitTeardown(a, frame, callee)` :2875 — `add rsp,frame; pop callee…; pop rbx;
  ret`. Called at EACH exit (deopt :4051-area, `.link` :3989, linked-loop-done
  :4038, prologue_fail :4065).
- Prologue :3163-3181 — computes `callee[]` (used callee-saved), `frame`
  (16-aligned via `pushes = 1+callee_len`), then `push rbx; push callee…;
  xor rbx,rbx; sub rsp,frame`.
- Hoisted body prologue (guards+loads) :3191-3216+ — this is `body_entry`; KEEP.
- Spill place is `[rsp + idx*8]` (`.mem => idx*8`, ~:2186); callout save area is
  part of `alloc.spill_count`, callout does transient `sub rsp,8;call;add rsp,8`
  (:2981) assuming body `rsp%16==8`.

Plan:
1. Add `pub const SPILL_MAX` (comptime, e.g. 512 slots = 4 KiB). In `lower`/
   `analyze`, **bail compile** (return null) if `alloc.spill_count > SPILL_MAX`.
2. Emit the trampoline ONCE into the arena (lazily, store entry+shared_exit
   absolute addrs on `McodeArena` or `TraceState`). Trampoline is C-callable
   `fn(rdi=tags, rsi=payloads, rdx=*result, rcx=body_entry)`:
   `push rbx;push rbp;push r12;push r13;push r14;push r15; sub rsp,SPILL_MAX*8
   (16-aligned: 6 pushes keep %16==8, so SPILL_MAX*8 multiple of 16 → body
   rsp%16==8 ✓); xor rbx,rbx; jmp rcx`. `shared_exit:` `add rsp,SPILL_MAX*8;
   pop r15;pop r14;pop r13;pop r12;pop rbp;pop rbx; ret`.
   NB: trampoline saves ALL of rbp/r12-r15 unconditionally (bodies then clobber
   freely); needs its own tiny Assembler + arena.alloc, or hand-assemble bytes.
3. In `lower`: DELETE the per-trace prologue push/sub (:3178-3181) and the
   `callee[]`/`frame` computation used for it. Body starts at the hoisted
   guards. rbx no longer zeroed here (trampoline does it).
4. Replace every `emitTeardown(a, frame, callee…)` with `jmp shared_exit` —
   absolute: `movabs rax, shared_exit_addr; jmp rax` (rax scratch post-flush).
   The exit SITE still writes completed/exit_instr to [rdx] and does its flush;
   only the frame teardown moves to shared_exit.
5. `CompiledTrace` stores `body_entry` (= page.code.ptr) + the trampoline ptr;
   `runWithLinkedLoopDone` calls `trampoline(tags,payloads,&result,body_entry)`.
   Need a Zig fn-ptr type `fn([*]u8,[*]u64,*NativeResult, *const anyopaque)
   callconv(.c) void` for the trampoline.
6. Gate: `just test`; nsieve byte-identical tier-0/tier-1a/native; bench flat.

Watch: `.loop` stays local `jmp loop_top`. The two standalone exec-memory tests
(:5247,:5280) + `compile(gpa,t)` test path build owned pages and call
`page.entry` directly — they DON'T use the trampoline. Decide: either give the
test path its own trampoline, or keep `compile` emitting the old self-framed ABI
and only `compileInto` (production) uses the trampoline. Simplest: keep the old
self-framed prologue/epilogue behind an `arena==null` flag in `compileImpl`, new
frameless path when `arena!=null`. (Slightly more code but keeps ~60 tests
untouched and gives a built-in A/B of the two ABIs.)

Then 2.2 ChainResult+stable-id, 2.3 link-slot population (.link → guard →
loop-done), 2.4 P-F flag verification. Increment 3 = patchexit + P-E.

## Untracked files that belong to OTHER agents — do NOT stage
`CURRENT_TASK_E3.md`, `bench/results/*.tsv`, and similar.
