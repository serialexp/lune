# Time-travel debugger over DAP — Design

Status: partial — P0 and P1 landed; P2–P7 outstanding
Owner: Bart
Last updated: 2026-11-11

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once
everything inside them is checked.

### Done

- [x] **Decisions D1–D14** (§2): settled with Bart, 2026-11-11.
- [x] **Review round 1** (§14): Codex and Antigravity, 2026-11-11. Every
  finding is applied or answered there.
- [x] **P0 — variable names in every Proto** (§4). The compiler emits
  `locals` rows (name, pc range, location: register or folded literal) and
  `upval_names` (`src/bytecode.zig` `LocalVar`, `Proto.localName`,
  `Proto.upvalName`). `bc_names` names locals and upvalues, so runtime
  errors read "(local 't')" / "(upvalue 'f')" as Lua 5.4 does; a traceback
  names a function expression from its call site; the viz replay labels
  registers with local names and lists folded `<const>`s
  (`wasm_entry.zig` `encodeLocals`, `viz/src/snapshot.ts`).
- [x] **P1 — exact resume from a keyframe** (§6.1). Landed 2026-11-11
  (ff05bca, 9af2266, 8156b59, 852e0e7, 3b825a7, a36c910, 824e821). How it
  differs from the plan is in §6.1's follow-up.
  - [x] The keyframe carries `VmState` (v22, v24): the Xoshiro state,
    `safepoint_seq`, `committed_effect_seq`, the effect cursor (the log's
    length in record mode), `warn_enabled`, `io_errors`, both pins, the
    system groups, `exit_status` and the last clock value
    (`keyframeser.zig` `restoreVmState`; v25 for the clock).
    The pins are stored, so the log-prefix scan is gone.
  - [x] Restore resumes inside the prologue without counting the step
    again (`Vm.resume_at`, `resumeEntry`).
  - [x] The host-ref table, its free list and the park are captured
    (`HostRoots`, v23).
  - [x] The `Vm` and `Heap` field audit. It found `exit_status`; the
    other fields are transient within an instruction, supplied by the
    host, rebuilt at init, or already carried.
  - [x] The effect log holds bytes and scalars only, a VM can record into
    and replay from a log it does not own (`Vm.shareEffectLog`), and a
    replay interns a string entry when it consumes it (`loggedValue`). The
    encoded-size count lives on the log (`EffectLog.encoded`).
  - [x] Gate: `src/keyframeser_corpus_test.zig`. Every `.lua`/`.mah`
    under `tests/` (embedded by `build.zig` as `program_corpus`) is
    recorded against a fake clock, seed and environment. Then, at nine
    cuts, the gate replays to the cut, restores, replays on, and compares
    the output, the final snapshot bytes and the effect cursor. It asserts
    that some program collects. `tests/programs/` holds the eight corpus
    programs.

### Outstanding

- [ ] **P2 — the debugger core, forward only** (§3, §5, §7). `src/debug/`
  covers:
  - the session and its live VM;
  - line and conditional breakpoints, and hit counts;
  - step in, over and out, and pause;
  - error stops at every site where an error is raised (§5.4);
  - threads, the stack, scopes, variables with slot-order paging, and
    pure-read `evaluate`.

  It does no I/O.
- [ ] **P3 — `mahina dap`** (§8). The DAP server on stdio, with the full
  lifecycle (initialize, configuration, disconnect and terminate) and a
  post-exit stop. Program output goes to `output` events, and stdin comes
  from a file.
- [ ] **P4 — history and reverse** (§6). The live VM records into the
  session log, with adaptive keyframes under the 1 GB budget. Scratch VMs
  replay history. This phase adds `stepBack`, `reverseContinue`, zoom-in
  keyframes and the hand-off back to the live VM at the frontier.
  Barriers include every `proc` call that cannot be recorded.
- [ ] **P5 — Zed** (§8.3). The extension registers the debug adapter
  through `get_dap_binary`, in `extension.toml` `[debug_adapters.mahina]`.
  `tests/dap/` drives `mahina dap` through scripted request sequences.
- [ ] **P6 — embedded attach** (§9).
  - The C and Rust APIs gain a sans-IO byte pump, a blocking wait
    callback and an optional TCP helper.
  - Host functions are flagged pure or effect when registered.
  - A host transaction log records every API call that touches guest
    state, including the nested transactions inside callbacks.
  - Scratch VMs replay host frames through a synthetic driver.
- [ ] **P7 — performance budgets** (§10). `zig build bench-debug` measures
  at the sizes in §10.
- [ ] **Q-B — the keyframe interval ratio** (§6.3). Measure tier-0 `.full`
  cost per step against capture cost per heap unit, and set the ratio that
  keeps keyframe overhead at about 10%.
- [ ] **Q-C — waking blocked waits** (§5.5). Confirm how an `aio` wait
  and a blocking file read observe a pause or terminate request, and wire
  them to the session's wake flag.
- [ ] **Defer — delta keyframes** (§6.7). Periodic full keyframes plus
  deltas of the objects written since the last one, found through a dirty
  bit. Build only once measured sessions show they are needed.
- [ ] **Equal step counts across tiers** (§6.1, Critical in TODO.md).
  Native and tier-1a code count steps as tier 0 does, and the cross-tier
  mask goes. It must land before the JIT runs in a debug session.
- [ ] **Defer — JIT in debug sessions** (§5.6). When a breakpoint is set,
  invalidate the traces whose span covers it. Until then a session runs
  tier 0.
- [ ] **Defer — typed arrays in keyframes** (§6.1). P1 planned to
  capture them, but no runtime path makes one: `object.TypedArray` has no
  constructor and the heap never allocates one (`gc.zig`, "Phase 9b"). So
  no keyframe can contain one, and a keyframe variant would have nothing to
  test it against. `keyframeser.zig` still refuses them with
  `UnsupportedObject`. Add the variant together with their constructor.
- [ ] **Defer — `setVariable` and side-effecting `evaluate`** (§7.3).
- [ ] **Defer — logpoints and function breakpoints** (§5.2).
- [ ] **Defer — `runInTerminal`** (§8.2). Interactive stdin for the
  debugged program.
- [ ] **Defer — viz breakpoints and stepping** (§11). The viz could use the
  same core through the wasm build.

## 1. Why this exists

mahina has a time-travel *visualiser* but no debugger. The viz replay
panel moves a slider over instruction or line steps. Each step re-runs the
program from step 0 at tier 0 (`wasm_entry.zig` `replayRun`), and the panel
has no breakpoints, step over or step out. Outside the browser there is
only `debug.traceback` (`stdlib/debug.zig`). You cannot stop a script in
Zed, look at its locals and step.

The runtime already has most of the pieces a reversible debugger needs:

- **A pause point.** The `.full` prologue (doc 42 §4.2, `interp.zig:5672`)
  runs on every instruction, and `SuspendCtl` (`interp.zig:792`) can stop
  there.
- **A clock.** `safepoint_seq` counts every instruction.
- **Whole-VM keyframes.** `keyframeser.encodeSnapshot` and `restore`, with
  resume (the F2c tests).
- **Deterministic replay.** An effect log (`EffectMode.record/replay`)
  replays every nondeterministic input byte for byte.
- **Located backtraces.** `backtraceFrames`, `FaultFrame` and
  `suspendedCoroutines`, the last written "for the step debugger".
- **A frame reader.** The LSP's sans-IO `Content-Length` reader
  (`lsp/jsonrpc.zig`), which DAP framing can reuse.

What is missing:

- runtime local and upvalue names (`bc_names.zig:14`);
- breakpoints and step conditions;
- keyframes taken during a run, and complete exact-resume state;
- a protocol server.

Doc 74 §7.7 deferred all of this to a debugger doc, which it called
"doc 75". That number went to process spawn, so the debugger doc is this
one.

## 2. Decisions

All decided by Bart, 2026-11-11.

- **D1 — scope.** Time travel from day one: forward and reverse stepping
  ship in v1.
- **D2 — clients.** DAP only, driven from Zed. There is never a VS Code
  extension (`CLAUDE.md`, Editors).
- **D3 — JIT.** Debug sessions run tier 0. Breakpoint-aware trace
  invalidation is deferred.
- **D4 — local names.** Always emitted, in every Proto.
- **D5 — reverse method.** Periodic keyframes plus re-running from the
  nearest one.
- **D6 — evaluate.** Pure reads only.
- **D7 — setVariable.** Not in v1.
- **D8 — breakpoints.** Line breakpoints with an optional condition and
  hit count. Error stops for uncaught errors and for errors caught by
  `pcall`.
- **D9 — unrecordable calls.** They run live and become history barriers.
- **D10 — history budget.** 1 GB by default, overridable in the launch
  configuration.
- **D11 — keyframe form.** Full keyframes with an adaptive interval and
  zoom-in. Delta keyframes are deferred.
- **D12 — embedding.** Attach is in v1, through a sans-IO core with an
  optional localhost TCP helper. Host functions declare pure or effect, and
  an unflagged one is a barrier.
- **D13 — debuggee stdio.** stdout and stderr become `output` events.
  stdin comes from a file, or is empty.
- **D14 — embedded history.** A full transaction log: every host API call
  that touches guest state is recorded, so reverse stepping works across
  host frames. Decided after review round 1.

## 3. Shape

```
 Zed ── DAP bytes ──▶ transport ──▶ debug.Session
                     stdio (CLI)      ├─ live VM   (tier 0, .full; paused in place at the frontier)
                     host pump        ├─ scratch VM (restored from a keyframe; replay only; disposable)
                     TCP helper       ├─ history   (session-owned effect + host-transaction log, keyframes)
                                      └─ breakpoints, evaluator, variable handles
```

`src/debug/` is the core. It does no I/O:

- `session.zig` owns the live VM pointer, the run state, the breakpoints
  and the history;
- `dap.zig` decodes requests into a tagged union and encodes responses and
  events;
- `history.zig` holds keyframes, barriers and the logs;
- `eval.zig` is the pure-read evaluator;
- `vars.zig` holds the variable handles.

The transports are thin:

- `mahina dap` links the core the way `mahina lsp` does;
- `capi.zig` exposes it to embedders.

The VM gains only a `debug: ?*DebugHooks` pointer, which is null in every
run that is not being debugged.

### 3.1 The live VM never moves backwards

The **live VM** is the program actually running. It owns the real file
handles, `aio` jobs, host bindings and host refs. It only ever runs
forward. When it stops, it stops **in place**: the prologue check, or a
raise hook, calls `session.stop(reason)`. That call runs the request loop
on the live VM's own stack until a request resumes it.

Because the stop is in place:

- it works inside a native's re-entry, a multret or a coroutine resumed
  from Zig, where `canSuspendHere` refuses (doc 68 §8);
- an error stop sees the raising frames before any handler unwinds them;
- an embedded host's own call stack is left as it is.

The furthest point the live VM has reached is the **frontier**. While the
live VM is stopped there, the user can go back. The session then restores
a keyframe into a **scratch VM** and replays to the target (§6.4). It
inspects, steps and continues within history, and the live VM stays
blocked in `session.stop`. When a forward operation in history reaches
the frontier, the session drops the scratch VM. The live VM's stop becomes
current again, and the operation continues there.

This means:

- nothing ever unwinds the live VM;
- no effect-mode switch is needed;
- external resources never have to be revived from a keyframe;
- the host's VM is never replaced.

A scratch VM never runs host code except leaf functions flagged
`MH_FN_PURE` (§9.2). Its files are detached as restored
(`keyframeser.zig:1183`), and its `aio` operations come back as restored
records (`stdlib/aio.zig:178`). Every effect it makes is fed from the log.

A scratch VM is discarded in one of two ways:

- **From its own stop**, for a further step back or a jump forward to the
  frontier. `stop` returns `Error.DebugRewind`, and the error unwinds
  scratch `exec` to the session driver. Two existing pieces of code need
  to know about it:
  - `catchable` lists it as not catchable;
  - the native error narrowing (`interp.zig:13112`) maps it through,
    as it does `Interrupted`, rather than to `HostError`.

  Coroutine propagation may tear down the scratch VM's stacks on the way
  out. That is fine, because the whole VM is dropped next.
- **From outside its exec**, by dropping it.

Restore errors, replay mismatches (`EffectKindMismatch` or
`EffectLogExhausted` before the frontier), OOM in a scratch VM, and any
other scratch failure all end the same way:

- the scratch VM is dropped;
- the error goes to the client as a `console` output event and a failed
  response;
- the session returns to the live VM's stop.

The live VM is never affected by these failures.

## 4. Variable names (P0, D4)

```zig
// in Proto
locals: []const LocalVar,        // sorted by start_pc
upval_names: []const []const u8,

pub const LocalVar = struct {
    name: []const u8,            // interned in the proto's string arena
    start_pc: u32,               // first pc where the binding is visible and initialised
    end_pc: u32,                 // first pc past its scope
    loc: union(enum) {
        reg: u16,
        constant: u32,           // a folded `<const>` binding: index into K (resolve.zig:86, compiler.zig:1230)
        none,                    // compiled away entirely
    },
};
```

The compiler already has the resolver's `Binding` for every local
(`compiler.zig` `Local.binding`). It writes a row when the local becomes
initialised, so `local x = x` shows the outer `x` during its own
initialiser. It closes the row at the end of the scope. Upvalue names
follow `UpvalDesc`.

The locals visible at pc p are the rows with `start_pc <= p < end_pc`.
When two visible rows share a name, the later row wins, which is how
shadowing works.

**Liveness.** A register-backed local is shown only if
`proto.reg_live` says its register is live at p. Otherwise it shows as
`<unavailable>`. The rule is the same for the live VM and for a scratch
VM, for two reasons:

- the GC already masks dead registers (doc 61), so an object in a dead
  register may have been collected, and reading it in the live VM would
  be unsound;
- keyframes tombstone dead registers (`keyframeser.zig:411`), and keeping
  them alive in a debug session would change GC timing and so diverge from
  the original run.

Memory is about 20 bytes per local plus the name, which is small next to
`spans`. Once P0 lands:

- `backtraceFrames` can name locals in faults;
- `bc_names.originOf` can say "local 'count'";
- the viz drops its `r0`, `r1` labels (`snapshot.ts:151`).

## 5. Forward debugging (P2)

### 5.1 The check, and when it runs

The check goes after `frame.pc` has been published for the instruction
(`interp.zig:5825`). That way a stop, a capture and an inspection all see
the current pc, never the previous one. It also stays inside the doc 42
ordering, after the line recorder and the suspend point:

```zig
if (self.debug) |d| if (self.safepoint_seq >= d.next_event_step or d.flags.load(.monotonic) != 0)
    try d.check(self, proto, pc);
```

**`next_event_step`** is the smallest of:

- the step a keyframe is next due at (§6.3);
- a scratch VM's target step;
- the frontier step, when running in a scratch VM.

**`flags`** is an atomic set by the session and the transport thread.
Its bits:

- *breakpoints present*: then `check` tests a per-proto bitset of
  breakpoint pcs, keyed by `proto.id` and built lazily;
- *stepping*;
- *pause requested*;
- *requests pending*: then `check` drains requests the client sent while
  the VM runs, such as `setBreakpoints`, `threads` and `disconnect`;
- *terminate requested*.

The check never allocates on the VM heap and never touches it, so it
cannot change GC timing or the step counter.

A session forces `ExecMode.full` and the canonical fallback at trace
entry (`interp.zig:8440`), so no trace runs (D3).

**Three predicates.** They are separate:

- *inspectable*: any prologue, or any raise site;
- *stoppable*: an inspectable point that is not in a `system` proto.
  Because stops are in place, a native re-entry is still stoppable;
- *capturable*: a point where `encodeSnapshot` holds a complete state.
  That means no native activation in flight, no pending multret
  (`interp.zig:949`), no error unwind in progress (`interp.zig:986`), and
  being in a prologue rather than at a raise site.

### 5.2 Breakpoints (D8)

**Binding a line.** `setBreakpoints` maps each line to the first stoppable
pc on that line, in every proto of that chunk, including nested
functions. A line with no code moves to the next line that has code. Each
breakpoint gets a stable `id`. The response carries the `line` actually
used and `verified`.

**Pending breakpoints.** A breakpoint for a chunk that is not loaded yet
stays `verified: false`. It binds when a chunk with that path compiles,
whether through `require`, `loadfile` or `load`, or through a keyframe
restore. Restore recompiles loaded chunks outside the ordinary load path
(`keyframeser.zig:1249`), so that path calls the same binding hook. When a
breakpoint binds, the session sends a `breakpoint` event with reason
`changed`, plus a `loadedSource` event for the chunk.

- **Conditions** use the pure-read evaluator (§7.3). A condition that
  fails to evaluate counts as false, and is reported once, as a `console`
  output event.
- **Hit counts** use `hitCondition` with `N`, `>= N` or `% N`. The count of
  a breakpoint is a function of the step: the number of times it was hit
  before that step. Each keyframe stores the counts at its step. A replay
  starts from those counts, and the session's own counts follow the
  current position, whether live or in history. A reverse scan computes
  candidate hits from the keyframe's counts without changing the
  session's counts (§6.5).
- **System code.** `system` protos, including `task.lua`, never take
  breakpoints and are stepped over.

### 5.3 Stepping

A step starts at a stop. It records the coroutine `C`, frame depth `D`,
proto `P` and line `L` at its start. A *line visit* begins at a stoppable
pc where one of these holds:

- the (proto, line) differs from the previous stoppable pc in that frame;
- a back-edge jumped to an earlier pc, as in `for i = 1, 3 do f(i) end`,
  where each pass is a new visit;
- a call has returned into the frame.

The step kinds stop at:

- **step in**: the next line-visit start anywhere, in any coroutine or at
  any depth;
- **step over**: the next line-visit start in `C` at a depth of `D` or
  less;
- **step out**: the first stoppable pc in `C` after the frame at `D`
  returns.

Three transitions need defining:

- **Tail calls.** A tail call replaces the frame at the same depth with a
  different proto. That counts as a line-visit start for step in and step
  over, because the (proto, line) changed.
- **Leaving the coroutine.** If `C` yields, finishes or errors out to its
  resumer during step over or step out, the step stops at the first
  stoppable pc in the resuming coroutine. A step therefore never becomes a
  silent continue.
- **Errors.** If an error unwinds past `D`, the step stops at the
  handler's next stoppable pc, or at the uncaught-error stop.

### 5.4 Error stops (D8)

`setExceptionBreakpoints` takes two filters:

- `uncaught` (Uncaught errors, on by default);
- `caught` (Errors caught by pcall/xpcall).

Raise hooks go before each place that transforms or unwinds a catchable
error. Codex listed these sites, and P2 checks each one:

| Site | Where | Filter |
|---|---|---|
| The dispatch error path, for errors from an instruction or a native | `interp.zig` ~4052 | depends on whether a handler exists |
| A synchronous protected call: `pcall` or `xpcall`, before the message handler runs | `interp.zig` ~4761 | `caught` |
| Coroutine resume propagation | `interp.zig` ~5039, ~5103 | per the outer handler |
| An error in a `__close` handler while unwinding | the TBC close path | per the handler |
| An uncaught error at the top level | `exec` return (`interp.zig:2868`) | `uncaught` |

To decide the filter, the hook asks whether a protected-call frame
encloses the raise on the current chain. A raise whose coroutine has no
handler, inside a chain that has one, counts as caught. A stop has reason
`exception`. Its text is the rendered error, and the session supports
`exceptionInfo`, giving the error value and the raising frame.

During a replay in a scratch VM, a raise stops only if that replay is a
user step or continue in history. A replay that is only seeking a target
step, or scanning for a reverse continue, records the raise as a
candidate (§6.5) instead.

### 5.5 Threads, stack, pause, end of program

- **Threads.** DAP threads are VM threads. Id 1 is the main stack, and
  each coroutine that exists is a thread named by its header id.
  - Every `stopped` event sets `allThreadsStopped: true`, with `threadId`
    the running coroutine.
  - A step request aimed at a coroutine that is not running fails with
    the message "only the running coroutine can be stepped".
  - The `threads` list is built at each stop, so coroutines that came and
    went in between do not matter.
- **Stack.** `stackTrace` comes from `backtraceFrames(.chain)` with each
  frame's pc, so lines and columns come from `spans`.
- **Pause and terminate.** Both set flag bits and take effect at the next
  prologue. A blocking host call, such as a file read or an `aio` wait,
  must see them as well. Q-C covers how each wait gets woken.
- **End of program.** When the program returns or exits, and also after
  an uncaught error, the session stays in a final stop: reason `pause`,
  with a description of "program ended". Reverse stepping still works
  there. `terminated` is sent only on `disconnect` or `terminate`, or when
  no history exists.

### 5.6 Why tier 0 (D3)

Traces have no per-instruction prologue. Stopping in one requires the
traces covering each breakpoint to be invalidated, and a deopt at a pause.
That is the deferred JIT phase. Until then, a debug session runs at tier-0
`.full` speed.

## 6. History and reverse (P1, P4)

### 6.1 Time and exact resume (P1)

A point in the run is a **position**, made of:

- the step (`safepoint_seq`);
- a phase: prologue, raise site, or ended;
- for embedded VMs, the host-transaction index (§9.3).

Stops, keyframes, barriers and the frontier are all positions. Reverse
execution depends on this property:

> Restoring the keyframe at position k and replaying the session log from
> its cursors reaches every later position in the same state as the
> original run.

A keyframe is taken in the prologue at step s, after `safepoint_seq` was
advanced to s and before the instruction runs. Restore resumes inside
that prologue at the check, with a `resume_counted` flag set, so
`safepoint_seq` is not advanced a second time. A target of `t == K.step`
is reached the moment restore completes.

P1 adds to `VmState` everything that feeds observable behaviour and is
not there today:

- `rng`, the Xoshiro state, not just the seed;
- `safepoint_seq` and `committed_effect_seq`;
- the effect cursor. In record mode the cursor is not advanced
  (`interp.zig:1072`), so the capture writes the session log's length
  instead;
- `warn_enabled` and `io_errors`, plus the configuration of the system
  groups (`interp.zig:1035`);
- the Unicode and I/O pin state, and the effect-size accounting
  (`interp.zig:1073`). The pins are rebuilt today by scanning the log
  prefix (`interp.zig:13338`). Log compaction (§6.3) drops that prefix,
  so the pins have to be stored;
- the host-ref table (`interp.zig:1247`), as ids. It is needed for
  embedded replay (§9);
- typed arrays, which are `UnsupportedObject` today
  (`keyframeser.zig:360`).

P1 also audits every other `Vm` field. `gc_target` and `next_obj_id` are
the precedent for what that audit looks for.

**The session log owns its payloads.** Today a log entry can hold a heap
string that belongs to the VM (`effectlog.zig:23`). Such an entry dies
with that VM. Decoding a whole log up front would intern strings early
and so shift allocation ids (`effectser.zig:234`). So:

- a debug session's VMs record into a session-owned log, which holds
  bytes and scalars only;
- a replay turns an entry into a value at the moment it consumes it,
  doing the same allocations, in the same order, as the recording did
  when it first produced the value.

The P1 gate checks both halves.

**As built (P1, 2026-11-11).** The design held, with these differences:

- Restore has no `resume_counted` flag. It sets `Vm.resume_at` to the top
  frame's activation (`call_seq`) and pc. The stop at the suspend check
  sets the same point. `execImpl` matches that point against the frame it
  enters, clears it, and enters through `resumeEntry`. That function runs
  the prologue from the step after the suspend check (the region
  observer), so the stopped step's GC check, step count, line record and
  suspend check are not repeated. A stale point cannot misfire, because it
  matches only the frame and pc it was taken at.
- `safepoint_seq` depends on the tier. Native traces do not pass the
  prologue, so the step counts of a JIT run and a tier-0 run differ.
  Tests that compare snapshots across tiers mask that one field
  (`keyframeser_testutil.expectSameStateAcrossTiers`), and every
  same-tier comparison keeps it. A debug session runs tier 0 (§5.6), so
  positions stay exact. Bart, 2026-11-12: the mask can hide other
  divergence, so the tiers must count steps alike. That is the Critical
  item at the top of TODO.md, and it must land before the JIT runs in a
  session.
- The effect-size count moved from `Vm` onto the log
  (`EffectLog.encoded`), so it is not keyframe state. Its value is a
  function of the log, so a recording and a replay of one log agree.
- Restore numbers the restored frames' activations from 0, so the
  activation ids after a restore differ from the original run's. They are
  identities only: nothing observable and no snapshot byte depends on
  them.
- The host's clock epoch (`Vm.clock`) is host state, a reading of a clock
  that means nothing in another process, so the keyframe does not carry
  it. It carries the last clock value the program got instead
  (`clock_last_ns`, v25), taken from the logged result so a recording and
  its replay agree. `setClockSource` places the zero that far before its
  own reading, so a restored VM that records again goes on from where
  the program's clock left off rather than starting at 0. (First built
  as an embedder's job; Bart, 2026-11-12: the restored VM continues from
  the last recorded value.)
- Typed arrays are deferred (Implementation status): nothing can make
  one yet.

### 6.2 Recording and output

The live VM records every effect into the session log through a sink. It
keeps no log of its own. The VM's fatal `effect_log_limit`, 1 MiB by
default (`interp.zig:200`), is off in a session, and the history budget
takes its place (§6.3).

**Output** has one sink. `print`, `io.write` and stdout and stderr writes
all go through host stdout and stderr that the session installs. In the
live VM the sink sends `output` events. In a scratch VM it discards
everything, because the original run already printed that output once. A
`console` event marks when the user enters history and when they leave
it.

**A barrier** is a call that cannot be recorded:

- any `proc` operation that `recordable()` rejects, or that is refused in
  record mode outright, such as `spawn`, pipes and job waits
  (`stdlib/proc.zig:532, 610, 700–718`);
- a host function with no pure or effect flag (§9.2).

In a session such a call runs live, in the live VM only. The session
then takes a keyframe at the next capturable position. Only once that
keyframe exists does history move to start there: the earlier keyframes
and log entries are dropped, and a `console` event says why. Until the
keyframe is taken, the old history stays reachable up to the barrier.

### 6.3 Keyframe policy and budget (D10, D11)

The live VM takes a keyframe when both of these hold:

- the steps since the last keyframe are at least
  `max(min_steps, ratio × heap_units)`. `heap_units` is the object, hash
  entry and cell count of the last keyframe, which is how `bench-keyframe`
  sizes capture. Q-B sets `ratio`;
- the position is capturable. A keyframe that is due waits for the next
  capturable one.

The policy uses counts only, so keyframe placement does not depend on the
machine. Capture reads the heap and never runs a GC, so it does not
perturb the run. Scratch VMs do not take periodic keyframes; they only
take zoom-in keyframes (§6.4).

**Budget accounting.** The resident cost counts:

- the encoded keyframe bytes;
- the session log, both the effect log and the host-transaction log;
- breakpoint hit-count tables.

At its peak the session uses the budget plus one capture's workspace,
because `encodeSnapshot` builds schema intermediates and the encoded bytes
together (`keyframeser.zig:516, 597`). `bench-debug` reports that peak.

**Over budget.** The session thins keyframes by age. It keeps the newest
ones dense, keeps older ones at doubling gaps, and always keeps the
oldest one. If the log alone pushes the total over the budget, the oldest
keyframe moves forward to the next one, and the log before the new oldest
keyframe is dropped. Log offsets are absolute, so the cursors of the
remaining keyframes stay valid. A `console` event reports the new start
of history. A single keyframe larger than the budget replaces all the
others, so history then starts at the newest keyframe. That is reported
too.

### 6.4 Re-execution and the frontier

To reach position t, which is earlier than the current position:

1. If a scratch VM exists and is at or before t, keep running it forward
   to t.
2. Otherwise restore the newest keyframe K with `K <= t` into a new
   scratch VM, in `.replay` mode. Its effect and host-transaction cursors
   come from K. The session's hooks are attached, and its breakpoint hit
   counts are set from K.
3. Run with `next_event_step = t`. Breakpoints and error stops are only
   counted on the way (§5.4).
4. **Zoom-in.** When the replay distance `t − K.step` exceeds
   `zoom_steps`, the scratch VM takes keyframes on the way, at quarter
   points, under the same budget. Each one is marked as a zoom keyframe,
   and zoom keyframes are thinned first. A stepBack repeated near the
   same place then replays at most `zoom_steps`.

**Moving forward in history.** Step, next and continue in a scratch VM run
it forward. If the operation would go past the frontier, the scratch VM
stops at the frontier position and is dropped. The live VM's stop then
becomes current, and the rest of the operation continues live. For
example, continue resumes the live VM's request loop with a continue.

The frontier position has an exact step and phase, so the hand-off is
exact. A `verifyFrontier` launch option, also used in the tests, compares
a state hash of the scratch VM at the frontier with the live VM's state
hash.

### 6.5 Reverse operations

**Step back.** DAP has `stepBack` and `reverseContinue`, but no reverse
step in or reverse step out. `granularity` only selects the unit size
(statement, line or instruction).

- `stepBack` means **reverse step over** by default.
- A launch option, `stepBackMode: "over" | "in"`, selects reverse step in
  instead.
- `granularity: "instruction"` steps back one stoppable instruction.

For a target, reverse step over finds the latest position `s` before the
current one where all of these hold:

- `s` is a line-visit start (§5.3);
- `s` is in the current coroutine;
- `s` is at a depth less than or equal to the current depth.

If the current position is the first line visit of a function, the
target is instead the caller's line-visit start that made the call.
Reverse step in finds the latest line-visit start of any kind.

The search runs one replay from the keyframe K before the current
position to the current position, and keeps the latest candidate seen.
It then moves to that candidate, which is cheap because the replay
already took zoom-in keyframes.

**Reverse continue.**

1. Replay the interval from the keyframe K before the current position up
   to that position. Record every breakpoint hit, counted from K's hit
   counts, and every error stop that the filters admit, as a candidate.
   The session's own counts are not changed.
2. If any candidates exist, go to the latest one.
3. If not, repeat with the previous keyframe interval.
4. At the oldest keyframe, stop there with reason `entry`. Its description
   says whether that is the start of the program or the start of history
   after a barrier or trimming.

**Restart.** For `mahina dap`, restart relaunches the program with a fresh
live VM and empty history. It is not a restore of the oldest keyframe,
which may not be the start of the program. Embedded sessions report
`supportsRestartRequest: false`.

### 6.6 Latency

A reverse operation that cannot keep running the current scratch VM
forward pays for one full restore. That costs 273–434 ms per million
units (doc 61 §9a) plus the replay. Budgets are therefore heap-dependent
(§10). Delta keyframes (§6.7) and reusing a scratch VM in place are what
would cut the restore cost.

### 6.7 Delta keyframes (deferred)

On a 1M-object heap a full keyframe is about 44 MB, and capture takes
165 ms (`bench-keyframe`, 2026-11-11). That gives about 23 keyframes in
1 GB. A delta would keep only the objects written since the last keyframe,
found through a dirty bit in the write paths. Restore would apply a chain
of deltas on top of a full keyframe. Build it only once measured sessions
show the full form falls short.

## 7. Inspecting state

### 7.1 Scopes

For each frame, `scopes` returns:

- **Locals**: the visible rows from §4, read from `frame.base + reg`, or
  from `K`, or shown as `<unavailable>`. Varargs show as `...`.
- **Upvalues**: `upval_names` paired with the closure's cells.
- **Globals**: the globals table, marked `expensive`.

### 7.2 Variables

- **References.** A table, function, coroutine or userdata gets a
  variables reference. That is a session handle onto the object in the VM
  currently being inspected, which is the live VM or the scratch VM. The
  handle table is cleared on every resume, as DAP requires, and is never
  carried across one.
- **Arrays.** A table's array part is reported as `indexedVariables`, and
  `start`/`count` page it directly.
- **Hash parts.** These are listed in slot order, which is the order
  `next` uses and is deterministic (keyed by ids). Nothing is sorted. A
  hash part over 100 entries is shown as synthetic group children, for
  example `[slots 0–99]`, each a slot range. Expanding a group reads only
  its slots, so a page costs O(page) with no index to build.
- **Metatables** show as a `[metatable]` child.
- **Rendering** uses `io.zig`'s renderer with a length cap, and never calls
  `__tostring` or `__name` (D6).

### 7.3 Evaluate and conditions (D6)

`eval.zig` parses the expression with the real parser and walks the AST.
It accepts:

- literals;
- names, resolved as locals (§4), then upvalues, then globals;
- `.field` and `[index]` as raw gets;
- arithmetic, comparison, `not`, `and` and `or` on primitive values;
- `#` on strings, and on tables without `__len`;
- `..` on strings and numbers.

It refuses calls, method calls, assignment, and any operation where a
metamethod would apply. Each refusal comes with a message.

It works in the session's arena, never on the VM heap. A concatenation
produces a scratch byte string, and nothing is interned. So evaluating
never changes the heap, the step counter or the logs. The `watch`,
`hover` and `repl` contexts all use this evaluator.

## 8. `mahina dap` (P3, P5)

### 8.1 Transport and lifecycle

- **Transport.**
  - Frames use `jsonrpc.FrameReader` and `writeFrame` unchanged.
  - DAP's own envelope (`seq`, `type`, `command`, `arguments`) is handled
    in `dap.zig`.
  - A reader thread queues requests and sets the flag bits.
  - The session thread runs the live VM, or a scratch VM, and serves the
    queue. While a VM runs, it serves the queue at `check` (§5.1). During
    a stop, it serves it from `session.stop`.
- **Lifecycle.**
  1. `initialize`: the response lists the capabilities.
  2. The `initialized` event follows.
  3. The client sends `setBreakpoints`, `setExceptionBreakpoints` and
     `configurationDone`.
  4. `launch`: the run starts, or stops with reason `entry` when
     `stopOnEntry` is set.
  5. `disconnect` or `terminate` ends the session: it sets the terminate
     flag, sends `exited` with the exit status, then `terminated`.
- **Capabilities.**
  - `supportsConfigurationDoneRequest`;
  - `supportsConditionalBreakpoints` and
    `supportsHitConditionalBreakpoints`;
  - `supportsEvaluateForHovers`;
  - `supportsStepBack`;
  - `supportsSteppingGranularity`;
  - `supportsRestartRequest`;
  - `supportsTerminateRequest`;
  - `supportsExceptionInfoRequest`;
  - `supportsLoadedSourcesRequest`;
  - `exceptionBreakpointFilters` (§5.4).
- **Debugger notices** use output category `console`. Program output uses
  `stdout` and `stderr`.

### 8.2 Launch configuration (D13)

```json
{
  "type": "mahina",
  "request": "launch",
  "program": "${file}",
  "args": [],
  "cwd": "${workspaceFolder}",
  "stdin": "input.txt",
  "system": "default",
  "historyBudget": "1GB",
  "stopOnEntry": false,
  "stepBackMode": "over",
  "verifyFrontier": false
}
```

- `system` maps to `--system` (doc 65 §5.2).
- `stdin` names a file, read through the recorded `file_read_op` effect.
  With no `stdin`, reads see EOF.

### 8.3 Zed (P5)

- **Registration.** The extension declares `[debug_adapters.mahina]` in
  `extension.toml`. It implements `get_dap_binary`, returning `mahina dap`
  over stdio with no TCP connection, from the same binary it already finds
  for `mahina lsp`. It also implements the config-to-scenario hooks for a
  default launch of the current file.
- **API version.** Zed's debugger extension API has changed quickly, so P5
  first checks the trait signatures in the `zed_extension_api` version
  that `editors/zed` pins.
- **Toolbar.** Zed shows Step Back and Reverse Continue when an adapter
  advertises `supportsStepBack`.

The tests drive the protocol, not the editor. `tests/dap/` replays
scripted request sequences against `mahina dap` and compares responses
and events, with `seq` numbers and paths normalised. The sequences cover:

- the lifecycle;
- breakpoints, including pending ones that bind later;
- each step kind, including a one-line loop, a tail call and a yield
  during step over;
- every error stop site;
- `stepBack` and `reverseContinue` across keyframes, hit counts and a
  barrier;
- the post-exit stop;
- `verifyFrontier`;
- variables paging and groups.

## 9. Embedded attach (P6, D12, D14)

### 9.1 The byte pump

```c
mh_debug *mh_debug_attach(mh_vm *vm, const mh_debug_opts *opts);
void      mh_debug_feed(mh_debug *d, const uint8_t *bytes, size_t len);
size_t    mh_debug_drain(mh_debug *d, uint8_t *out, size_t cap);
void      mh_debug_detach(mh_debug *d);
/* opts->wait(userdata, timeout_ms): block until feed has bytes; opts->write(userdata, bytes, len):
   send replies. Both are called only while the VM is stopped in place (§3.1). */
mh_status mh_debug_serve_tcp(mh_debug *d, uint16_t port);   /* optional helper */
```

While the VM is running, the host calls `feed` and `drain` from its own
loop. A `pause` takes effect at the VM's next prologue. While the VM is
stopped in place inside the host's `mh_call`, the core calls `wait` and
`write` itself.

`mh_debug_serve_tcp` runs a localhost listener on a background thread
that does all of the feeding, draining and waiting. Networking stays in
that helper, in its own file next to `viz_server.zig` (Rule Z-2). The Rust
crate wraps the same calls.

History starts at attach, with a keyframe taken at the first capturable
position.

### 9.2 Host functions (D12)

`mh_register_fn` gains a flags argument:

- **`MH_FN_PURE`.** A leaf function whose result depends only on its
  arguments. It makes no API calls that touch guest state. A scratch VM
  calls it again.
- **`MH_FN_EFFECT`.** Its whole interaction with the guest is recorded as
  one host-call record: its result or failure, plus the nested host
  transactions it made (§9.3), including any re-entry into guest code
  through `mh_call`. A scratch VM never calls the function. It replays the
  record: it applies the nested transactions in order, runs the guest
  code of nested calls, and returns the recorded result.
- **Neither flag.** The call is a barrier (§6.2) while a session is
  attached, and costs nothing otherwise.

Scratch VMs get the host's registrations through the `NativeRegistry` that
`restore` takes (`keyframeser.zig:1213`). The session owns that registry
for as long as the session lives. Dropping a scratch VM never runs a
host's destroy callbacks (`function.zig:613`). Those run only when the
live VM dies.

### 9.3 The host-transaction log (D14)

While a session is attached, every C or Rust API call that can change
guest state or allocate in the guest heap is recorded, in order. That
covers:

- `mh_call` and the other entries into the VM;
- compiling and loading chunks;
- setting globals and table fields, both raw and with metamethods;
- creating values;
- making and freeing refs;
- settling pending operations;
- task driving.

Read-only calls are not recorded.

Each record holds the operation, its arguments and its result. Values are
encoded as scalars, as bytes, or as guest object ids. Host refs are
encoded by their slot and generation, which the keyframe's host-ref table
makes resolvable. A record is ordered by position: the step plus the
transaction index. Several host transactions can happen between two guest
instructions, and the transaction index is what orders them.

**Replay.** The scratch VM has no host to drive it, so the session runs a
**synthetic driver**. When guest execution returns to the top level, with
the live host sitting between host calls in history, the driver applies
the next recorded transactions until the next entry into the VM, and
enters it. It continues until it reaches the target position. Results
that went back to the host are checked against the record, which catches
divergence, and are not delivered.

**Frontier.** The frontier is a position in the live host's real call
stack. Reaching it hands control back to the live VM, as in §6.4, and the
host continues from its current `mh_call`.

## 10. Budgets (P7, global Rule #20)

`zig build bench-debug` (ReleaseFast) measures these. It is informational
and not a gate (Rule #22).

| What | Size | Budget |
|---|---|---|
| Session check with no event due | per step | ≤ 5% over `suspend_ctl` tier-0 `.full` |
| Keyframe overhead on a forward run | 1M-object heap; 5k-line script | ≤ 15% of tier-0 time |
| Warm `stepBack` (zoom done; scratch reusable) | any heap | ≤ 50 ms |
| Warm `stepBack` that needs a restore | 100k units / 1M units | ≤ 100 ms / ≤ restore + 50 ms (~0.5 s) |
| Cold `stepBack` | 1M units | ≤ restore + one keyframe interval of replay |
| History memory | any run | ≤ budget + one capture workspace |
| `variables`, one page or group of 100 | 1M-entry table | ≤ 5 ms, O(page) |
| Host-transaction log | 60 calls a frame for 10k frames | reported bytes per transaction |

The tests assert the countable form of these:

- history bytes stay at or under the budget;
- a warm `stepBack` replays no more than `zoom_steps`;
- a variables page reads only its own slots;
- a scratch replay of every `tests/dap/` program matches the frontier
  state hash.

## 11. Non-goals (v1)

- JIT execution in a debug session (D3, deferred).
- Changing state: `setVariable`, evaluate with side effects, hot code
  replacement.
- Logpoints, function breakpoints and data breakpoints.
- Debugging in the viz or the browser.
- A VS Code extension, ever.
- Debugging `proc` child processes.

## 12. Questions only building can answer

- **Q-B — the keyframe ratio** (§6.3). Set from measurement.
- **Q-C — waking blocked waits** (§5.5). Which waits need a wake path, and
  how each one observes the session flags.

## 13. References

- Design docs:
  - Doc 04: snapshot and replay schema.
  - Doc 42 §4.2: the prologue order.
  - Doc 59: the embedding API.
  - Doc 61 Phase K and §9a: keyframe cost.
  - Doc 65 §4.2: host effects.
  - Doc 68: nested suspension.
  - Doc 74 §7.7.
  - Doc 75 §5: `proc` recordability.
- Code:
  - `src/interp.zig`: the prologue, `SuspendCtl`, `catchable` and the error
    narrowing, `backtraceFrames`, `suspendedCoroutines`, `host_refs`.
  - `src/keyframeser.zig`, `src/effectlog.zig`, `src/effectser.zig`.
  - `src/wasm_entry.zig` `replayRun`.
  - `src/capi.zig`.
- External:
  - The Debug Adapter Protocol specification.
  - Zed's `zed_extension_api` debugger traits.
  - rr: checkpoints plus deterministic replay, and the real process kept
    at the frontier.

## 14. Review

Round 1, 2026-11-11. Codex and Antigravity both reviewed. Antigravity's
first run timed out at 15 minutes, and it answered on a narrower retry.

**Codex** (17 findings). The structural answer to blockers 3, 6 and 8 and
to major 7 is §3.1. The live VM never moves backwards and history is
explored in scratch VMs, so:

- nothing unwinds through host or C frames;
- the host's VM is never replaced;
- restored files and `aio` never have to become live;
- the frontier is the live VM's exact position.

The rest:

1. **Effect payloads die with their VM.** Applied (§6.1): the session log
   owns its payloads and replay turns them into values at consumption.
2. **The pc is not published when the check runs, and capture and resume
   phases are undefined.** Applied (§5.1, §6.1): the check runs after the
   pc is published, and restore resumes with `resume_counted`.
3. **`DebugRewind` through natives and C.** Answered by §3.1: it is
   needed only inside scratch VMs. The native error narrowing is updated.
4. **Host callbacks can mutate the guest and re-enter it.** Applied (§9.2):
   an effect callback is replayed as its recorded nested transactions plus
   its result. Bart chose a full log (D14).
5. **`mh_call` is not the only input.** Applied (§9.3): the log covers
   every host call that touches guest state, ordered by a transaction
   index.
6. **VM ownership in embedding.** Answered by §3.1, plus §9.2: the
   session owns the registry and destroy callbacks never run on a scratch
   VM.
7. **Log exhaustion does not mark the frontier.** Applied: positions
   (§6.1) and the hand-off at the frontier (§6.4).
8. **External resources after restore.** Answered by §3.1.
9. **Missing VM state.** Applied (§6.1).
10. **One predicate for inspect, stop and capture.** Applied (§5.1): three
    predicates. The barrier's new start is published only after a capture,
    and every `proc` refusal is a barrier (§6.2).
11. **Error sites.** Applied (§5.4): a table of sites, behaviour during
    replay, and failure handling (§3.1).
12. **Locals without registers, and dead registers.** Applied (§4):
    locations are register, constant or none, and the `reg_live` rule is
    the same in the live VM and in scratch VMs.
13. **Breakpoint binding on restore, hit counts, and tail calls or
    coroutine returns.** Applied (§5.2, §5.3).
14. **The 1 MiB effect-log limit and capture workspace.** Applied (§6.2,
    §6.3).
15. **Sorted paging.** Applied differently (§7.2): slot order, which is
    already deterministic, with slot-range groups. No index is built.
16. **The latency bound ignores restore.** Applied (§6.6, §10):
    heap-dependent budgets.
17. **Arming and requests while running.** Applied (§5.1, §8.1): the
    event step plus flags, requests drained at `check`, and Q-C for
    blocking waits.

**Antigravity** (11 findings):

- **Lifecycle, disconnect and terminate, post-exit stop.** Applied (§5.5,
  §8.1).
- **`stepBack` granularity.** Applied (§6.5): granularity is the unit
  size, and `stepBackMode` selects over or in.
- **Breakpoint ids, `breakpoint changed` and `loadedSource` events.**
  Applied (§5.2).
- **`allThreadsStopped` and steps on a coroutine that is not running.**
  Applied (§5.5).
- **Exception filters and `exceptionInfo`.** Applied (§5.4, §8.1).
- **Handles do not carry across a resume, restart after trimming, and a
  `console` category for notices.** Applied (§6.5, §7.2, §8.1).
- **The reverse-step algorithm fails on one-line loops and across
  frames.** Applied (§5.3, §6.5): line-visit starts, and the caller target
  at function entry.
- **Hit counts in `reverseContinue`.** Applied (§5.2, §6.5): counts per
  keyframe, and a scan never changes the session's counts.
- **A yield during step over.** Applied (§5.3).
- **Embedded replay across host frames.** Applied (§9.3): the synthetic
  driver.
- **Output while stepping forward through history.** Answered (§6.2):
  scratch output is discarded because the original run already printed it
  once, and `console` events mark entering and leaving history. Showing it
  again would print it twice.
- **Zed API.** Recorded (§8.3), with a check of the API version first.
