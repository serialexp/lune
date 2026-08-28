# lune — finishing the non-pattern string recording surface: upper/lower + codepoint

Status: **LANDED (2026-08-28; c1 = 3d0b946 D1a fix, c2 = the three ops
end-to-end). See "Landed results" at the bottom — all gates green; str_manip
itself did NOT move because its hot path spells `lower(upper(a))`, which
aborts at the pre-existing MULTRET nested-call frontier (TODO.md #1, now the
bench's sole blocker — the intermediate-local form of the same core records
with zero aborts).**
Codex review: no blockers; 8 majors, 5 minors — all folded in below.
Codex verdict: D1 is viable for the current VM lifecycle — "I did not find a
current internal restore, suspend, replay, deopt, or patched-link path that
falsifies the pin at execution" — but the proof as first drafted was
overstated (the "error aborts the recording" claim was false; recording
survival across a caught error is a real pre-existing hazard, see D1a) and
the scp optimizer/native integration was underspecified. This revision is
the post-review design of record.
Owner: Bart
Last updated: 2026-08-28

Prerequisite reading: `24-deterministic-on-trace-allocation.md` (the snew
class, the `guard_gc` budget, codex #10 — the exclusion this doc lifts),
`23-builtin-recording-breadth.md` (RecordedBuiltin registry discipline),
`02-determinism.md` (effect log, session pins), doc 06 S-B/S-C (code-point
strings, Unicode simple case mapping).

Upstream reference: `~/Projects/LuaJIT/src/lib_string.c:111-112` —
`LJLIB_REC(string_op IRCALL_lj_buf_putstr_lower/upper)`: Pall records
`upper`/`lower` as a **callout to a C helper** per call (BUFHDR + putstr +
BUFSTR), exactly the shared-kernel-callout shape lune's snew class already
adapted to the intern-everything model. `lj_ffrecord.c:808`
(`recff_string_range`, `rd->data == 0`) is `string.byte` with the same
start/end defaulting our `charRange` has. Nothing here is novel machinery —
it is the doc-24 adaptation applied to the three remaining ops.

## Why this exists

str_manip is 5.3× LuaJIT with exactly ONE recording-abort site left
(`--dump-aborts`: 1 × host_barrier). Probes isolate it to three builtins the
registry cannot record:

- `string.upper` / `string.lower` — excluded from doc 24 v1 by codex #10
  (they touch VM effect state via `noteUnicodeVersion`).
- `string.codepoint` — never scoped; str_manip calls it **twice per
  iteration** (`byte(c, 1)`, `byte(c, -1)`), so upper/lower alone would only
  move the abort site.

A control probe with only the landed set (`sub`/`reverse`/`len`) records with
zero aborts. This arc records all three, closing the non-pattern string
surface (pattern engine and `format` remain their own arcs). Z-6: all three
are bread-and-butter string primitives (LuaJIT records every one); the
recorded semantics are the full Unicode cores, not ASCII benchmark carve-outs.

## D1. The central claim: codex #10's `*Vm` channel is unnecessary — the pin
## is a committed-trace invariant

Codex #10 excluded `upper`/`lower` from v1 because `mapCaseUnicode` calls
`noteUnicodeVersion(vm)` — an effect append (record mode), an effect consume
+ version check (replay mode), `unicode_version_pinned`,
`committed_effect_seq`. A kernel that replays that on-trace needs a `*Vm`
channel and an idempotency proof across deopt replay. **The sound design is
the opposite: the kernel never touches effect state at all**, because the
pin is already committed before any trace containing `supper`/`slower` can
exist. The invariant, in codex's sharpened (review M2) form:

> While any trace cache from the current execution epoch remains executable,
> no supported transition clears `unicode_version_pinned`; every transition
> that establishes a new unpinned session first retires the cache and all
> patched links.

Why it holds:

1. **Recording shadows tier-0 execution, and commit requires anchor
   closure.** The recorder mirror runs at the call instruction
   (interp.zig ~2164) while tier-0 actually performs the call; a trace
   commits only when execution later re-reaches the anchor (`closeTrace`).
   A recording that emitted `supper` did so because tier-0 was executing
   `string.upper` in that iteration: on success, `noteUnicodeVersion` ran to
   completion (effect logged/consumed + `pinned = true`) **before scratch
   allocation** — so even a first call that then OOMs in scratch has already
   pinned (review m5), and the deopt/tier-0 retry takes the no-op path. On
   failure (replay-mode `UnicodeVersionMismatch`, OOM, any raise), the error
   unwinds and — with D1a below — the active recording is aborted at the
   unwind, so no trace containing that call can ever commit. (The first
   draft claimed "raises abort the recording"; pre-D1a they merely made the
   anchor unreachable *in that execution*, which is NOT sufficient — see
   D1a.)
2. **`unicode_version_pinned` is monotone under supported transitions.** The
   only production assignment is `false → true` (interp.zig:4910). The
   transitions that DO reset it both retire the trace cache first: a
   keyframe restore builds a **fresh VM** (`restoreSnapshot`:
   `gpa.create(Vm)` + `initBare` — fresh `TraceState`), and every fresh
   top-level entry runs `beginTopLevelEpoch`, which fail-closes on
   `depth != 0`, `disarmAllLinks()`, then `clearCache()` (interp.zig:1277) —
   so even an embedder that pokes VM fields between runs (as
   interp_effects_test does) cannot execute a stale case trace: the cache
   died at the epoch boundary. Trace serialization is output-only today;
   **if trace deserialization ever lands, this invariant is a named
   obligation for that design.**
3. **Traces never cross VMs.** The cache is `vm.trace`; there is no sharing
   or loading mechanism.

Therefore at every execution of a committed trace containing
`supper`/`slower`, `unicode_version_pinned == true` and `noteUnicodeVersion`
would be the `if (pinned) return;` no-op. A kernel that omits the call is
bit-identical to tier-0 on every path a trace can execute. The kernels take
a bare `*Heap`, same class as `srev`.

**Enforcement (review M3 — the e2e assert alone is not a tripwire).** A
committed `Trace` gains a capability bit `requires_unicode_pin` (set at
commit when the IR contains `supper`/`slower`). Debug-mode asserts check
`vm.unicode_version_pinned` wherever the vm is in reach: at commit, at
`enterSelectedTrace`, and at link **arming** (the arm site has the vm; a
native→native patched transfer at run time does not, and by monotonicity a
pin that held at arm time holds forever after — that argument is the reason
asserting at arm suffices). Release builds carry no cost.

Threat enumeration (each must stay refuted):

- **T1 restore-with-cache**: refuted by (2) — fresh VM. Named obligation for
  any future trace-deserialization design.
- **T2 in-VM reset**: refuted by (2) — the epoch boundary retires the cache
  before any run that could observe a poked flag.
- **T3 cross-VM trace sharing**: no mechanism (3).
- **T4 replay mode**: the first session `upper` is tier-0 by (1); a version
  MISMATCH raises there — D1a aborts the recording — and is the program's
  own deterministic error. Traces never carry the fallible consume.
- **T5 record-mode snapshot-resume** (re-logging the pin): pre-existing
  documented out-of-scope for the effect system; irrelevant here by (2).
- **T6 method-call form** (`s:upper()`): same native, same registry row.
- **T7 number coercion**: none exists — `strObjArg`/`strArg` reject
  non-strings (`badArg`), so `guard_string` mirrors tier-0 exactly.
- **T8 suspend/keyframe capture splitting pin from kernel**: refuted by the
  codex review — suspension happens in the next-instruction prologue
  (interp.zig:2064), never inside a native; and allocating traces are
  already observation-blacked-out (doc 24).

Pre-existing oddity found en route (NOT this arc's business — TODO.md note):
in replay mode `nextLoggedEffect` advances the cursor **before** the version
check, and `versionAlreadyConsumed` scans the consumed prefix — so after a
`UnicodeVersionMismatch` is raised once, a later retry of `upper` (pcall, or
host-level exec resumption) finds the entry behind the cursor and silently
succeeds with the wrong-version table. Pure tier-0 behavior, no JIT
involvement; flagged for Bart, not silently changed.

## D1a. Errors must abort the active recording (a pre-existing c3-class fix)

Review M1 exposed a hazard that predates this arc. `rec.active` is cleared
only by `abort()` and `closeTrace()`; an error unwinding through the
dispatch loop leaves the recording **live**. `pcall` called *during* a
recording is a `.host_barrier` abort, but a recording started *under* an
enclosing `pcall` is not covered: the protected body's loop gets hot,
records, an instruction raises after passing the recorder's shape checks,
the unwind is caught at `protectedCall`, the outer loop continues — with
`rec.active` still true, the recorder stitching post-unwind instructions
onto the partial iteration. If control re-reaches the anchor, a Franken-path
trace commits.

This is reachable **today** without upper/lower: `schar1`'s operand passes
the record-time `guard_int` and tier-0's `string.char` then raises `bad
argument` for an out-of-range value (`for i=1,n do pcall(worker) end` with
the hot loop inside `worker`). upper/lower would widen the class (the
replay-mismatch raise), so the arc fixes it generally first (Rule #0.5 +
Z-7 — foundation before extension):

- **The fix**: one choke point — `errdefer` on the error-propagation path of
  `Vm.execWith` (interp.zig:2018): if `self.trace.rec.active`, abort with a
  new `AbortReason.raised`. `execWith` is re-entrant (nested dispatch
  loops); the abort is guarded by `rec.active`, so the innermost unwind
  aborts and outer levels see an inactive recording — idempotent by
  construction. Suspension is NOT an error return (`.suspended` outcome), so
  suspend/resume recordings are untouched.
- **Effect on doc-24 machinery**: none. Aborted recordings already discard
  IR + gate the anchor with backoff; this only adds a new reason row (and
  `--dump-aborts` visibility).
- **Pinned tests**: (a) the char shape above — hot loop under enclosing
  pcall, out-of-range `char` raise mid-recording → NO trace commits, the
  post-pcall iteration records cleanly on a later attempt; (b) the same
  shape with `upper` raising `UnicodeVersionMismatch` in a replay session.

With D1a in place, D1's clause (1) is true as stated: any raise during a
recorded iteration kills the recording at the unwind, whether or not the
error is later caught, and regardless of host exec() resumption behavior.

## D2. `supper` / `slower` — the case-mapping snew ops

**Core extraction** (the rep2Core discipline): `mapCaseUnicode`'s loop moves
to `caseCore(heap: *gc.Heap, bytes: []const u8, comptime kind) Allocator.Error!*String`
in stdlib/string.zig — ASCII fast path and `unicode_case` table lookups
unchanged (the recorded op is the FULL Unicode transform; the ASCII win
stays inside the one shared core where every tier gets it). Scratch is an
`ArrayList(u8)` on `heap.gpa` (reverseCore's discipline), the single
`heap.intern(buf.items)` comes last. Audit: every fallible step (scratch
growth) precedes the intern; **≤ 1 `Heap.link` per call** (intern hit: 0).
Tier-0's `mapCaseUnicode` becomes `strArg` + `noteUnicodeVersion` +
`caseCore` — one compiled body across all tiers, by construction. The
pin-then-allocate ordering (effect committed before scratch can OOM) is
part of the D1 proof, not incidental (review m5).

**Shims** (stralloc.zig): `supperRuntime(heap, s) ?*GcHeader` /
`slowerRuntime(heap, s) ?*GcHeader` — null collapses OOM (no link preceded
it), the trace side-exits, tier-0's replay re-raises. Identical protocol to
`srevRuntime`.

**IR**: `supper` = wire ordinal **69**, `slower` = **70**. `a` = proven/
guarded string ref, `ty = .heap`, result is_string. Emitted via `emitAlloc`
(counted in the `guard_gc` bound A; lazily creates the entry guard).
tropt kind `.alloc` — never DCE'd/CSE'd/hoisted/reordered (the id stream).

**Recorder**: `RecordedBuiltin.upper = 17`, `.lower = 18` (append-only;
registry rows get `.recorded` tags). Arms `recBSUpper`/`recBSLower` clone
`recBSRev`: pin `instr.b == 1` (one argument) and `instr.c == 1` (one
result), `guardBuiltinCallee`, `stringArgRef`, `emitAlloc`. Commit sets
`requires_unicode_pin`. Konst-string argument: NO record-time fold (a fold
would allocate a derived string into the konst pool at record time); the
konst ref passes through and the op runs per-iteration — an intern hit.

## D3. `scp` — single-result `string.codepoint`

**Recorded shape** (review m1 — two independent pins): argument count
`instr.b ∈ {1, 2, 3}`; wanted results `instr.c == 1`. Any other `c` aborts
(the VM routes `nwanted >= 2` through `sCodepointN`, which stays a
barrier). Semantics must equal `sCodepoint1` exactly: `charRange` (defaults
i=1, j=i; `posRelat` negative wrap; clamp; `lo > hi` → **nil**), then decode
at `lo`. The nil (empty-range) result side-exits — tier-0 replays the
partial iteration, produces nil, and continues or raises exactly as the
surrounding program dictates (including *valid* nil-consuming control flow —
the parity test covers both, review M6).

**Operands** (the ssub aux precedent): `a` = string ref, `b` = i ref,
`aux` = j ref. 1-arg: `b` = `aux` = konst 1. 2-arg: `aux` = the same ref as
`b` (j defaults to the *runtime* i — same ref, not a konst). 3-arg: the j
argument's ref. `assertWellFormed` gets the `0 ≤ aux < i` arm alongside
ssub's. Recording pins **int-only** indices (float/integral-float indices
abort `.bad_type` — tier-0's `optIntArg` coercion stays tier-0-owned, the
ssub precedent).

**Core + shim** (review m3 — the core literally owns the range logic):
`codepointCore(s: *const String, i: i64, j: i64) ?i64` (null = empty range)
holds ALL of posRelat/clamp/decode; `sCodepoint1` becomes arg
parsing/coercion + `codepointCore`; `charRange` keeps serving
`sCodepointN`, but the single-result semantics live in ONE place. The shim
`scpRuntime(s: *GcHeader, i: i64, j: i64) callconv(.c) i64` returns **−1 as
the sentinel** (valid scalars are 0…0x10FFFF — U+0000 makes 0 unusable, −1
is unreachable; the native comparison is full 64-bit signed, and an
embedded-NUL / U+0000-result test pins it, review m2). Shim placement:
stralloc.zig, whose module doc is amended to "string JIT runtime shims" with
the allocating-audit contract scoped to the `.alloc`-op routines and the
non-allocating reader called out explicitly (review m4; a one-function
module is worse fragmentation). **Non-allocating, no heap argument, no
error path other than the sentinel.**

**IR**: `scp` = wire ordinal **71**, `ty = .int`. Plain `emit` (NOT
`emitAlloc` — it allocates nothing; inflating bound A would be dishonest
accounting). `RecordedBuiltin.codepoint = 19`.

**tropt classification (review M4 — corrected).** The first draft claimed
the binary CSE key omits `aux`; FALSE — `CseKey` carries `aux`
(tropt.zig:223, populated at :330), so binary CSE would actually be sound
for scp. The REAL gap is everything else: backward liveness (:431), LICM
dependency propagation (:503), and preheader-cone propagation (:554) walk
only `a`/`b`; compaction must remap `aux` as the ssub exception does. Per
codex: `scp` gets a **dedicated OpKind `.pure3`** — a pure three-operand
producer class — rather than `.binary` plus scattered op-keyed exceptions
(exactly the drift-prone shape an operand-kind abstraction exists to
prevent). The `.pure3` contract, each property pinned by a test:

- liveness, compaction/remap, and every operand walk cover **all three**
  operands (`a`, `b`, `aux`-as-ref);
- **CSE: deliberately excluded** in v1 (sound in principle since the key
  covers aux, but a root-class admission needs its own test story — the
  demand table has no repeats; fail closed);
- **LICM/hoist: deliberately excluded** in v1;
- **DCE: admitted** (pure; a dead scp drops).

**Exit classification (review M7).** `scp.aux` is an operand ref, never a
PC. Pinned: `scp` IS in native `opMayExitInBody` (register-home safety); it
is NOT in `guardExitPc` or any exit-PC/provenance accessor; it is never a
hotguard/side-trace predicate; its sentinel exit is an ordinary unchainable
header-replay side-exit. (Accessors already return null for unlisted ops —
trace.zig:569 — the pin is against a future "all side-exiting producers"
sweep misreading `aux`.)

## D4. Native lowering

- **proveKinds — exhaustive, doc-25 discipline (review M5)**: bounds first
  (`a < i`, `b < i`, `0 ≤ aux < i` before ANY `kinds[]`/`is_string[]`
  access), operand kinds (`is_string[a]`, `kinds[b] == .int`,
  `kinds[aux] == .int` for scp; `is_string[a]` for supper/slower), AND the
  result-`ty` stamp validated exhaustively: `supper`/`slower` require
  `ins.ty == .heap`, `scp` requires `ins.ty == .int`, any other stamp fails
  compilation. **Ride-along hardening**: the existing snew arms
  (nativegen ~1830) never check their result `ty` — the same malformed-
  stamp fail-closed check is retrofitted onto
  `tostr_*`/`ssub`/`srev`/`schar1`/`srep2` in the same change (codex: "do
  not copy that weakness" — so also do not leave it).
- **isTransient**: all three true. **operandReads**: `supper`/`slower` =
  `.{ .a = true }`; `scp` = `.{ .a = true, .b = true }` + aux-liveness on
  ssub's existing `analyzeInner` mechanism.
- **opMayExitInBody**: all three true (null / sentinel → side-exit).
- **BodyCallout**: rows `supper`, `slower` (may_collect = false,
  may_allocate documented per-row — the guard_gc budget accounts them) and
  `scp` (may_collect = false, allocates NOTHING — the row documents why it
  is a callout at all: the UTF-8 walk is a loop, not an instruction).
- **Emission**: `supper`/`slower` join `emitSnewCallout`'s op switch (the
  `srev` arg shape: heap in rdi, s in rsi). `scp` gets `emitScpCallout` —
  same save/align/call/restore choreography, but args (s, i, j) in
  rdi/rsi/rdx (no heap slot), result stashed in rcx across the restore,
  compared full-width signed against −1 (`cmp rcx, -1` sign-extends; a je
  side-exits), then homed as `.int`. A separate emitter, not a mode flag on
  emitSnewCallout: the return protocol (sentinel vs null pointer) and the
  arg map (no heap) both differ.

## D5. Tier-1a (irinterp)

`supper`/`slower` clone the `srev` arm: type-check the operand, call the
shim, null → defensive side-exit (`rec.exit`). The executor ctx carries only
`heap` — no vm pointer is threaded in for an assert; the M3 tripwire lives
at commit/entry/arm (D1) where the vm already is. `scp`: type-check
(heap-string a, int b, int aux), `codepointCore`, null → side-exit, else
`Value.int`.

## D6. The append-only sweep — closed inventory (review M8)

Appending IR ops is more than the Zig enum. The full checklist, audited in
one pass:

- `trace.zig`: `IrOp` rows 69/70/71 with doc comments; `assertWellFormed`
  arms (scp joins ssub's aux-ref pin); `writeIrInstr` — scp needs
  **three-operand rendering** (the ssub arm's shape), supper/slower the
  unary shape; `guardExitPc`-class accessors stay null for all three.
- `traceser.zig:310`-region: ordinal pins / enum-count asserts extended.
- `viz/src/enums.ts:12`-region: ordinal names + operand rendering (scp
  ternary).
- `tropt.zig`: `kindOf` rows; the `.pure3` kind through every switch
  (liveness, LICM, preheader-cone, compaction/remap, fold — excluded,
  CSE — excluded); `troptdiag.zig` use/consumer walks get the aux operand.
- `irinterp.zig`: three arms.
- `nativegen.zig`: proveKinds (+ the snew ty retrofit), isTransient,
  operandReads, opMayExitInBody, BodyCallout + calloutMayCollect +
  bodyCalloutOf, emitSnewCallout extension, emitScpCallout.
- `function.zig`: RecordedBuiltin 17/18/19; registry `.recorded` tags on
  the three string.zig rows.
- Every `IrOp` switch with an `else` arm audited by grep, not assumed
  (compile-time exhaustiveness does not cover them).

## D7. What does NOT change

- No new guard ops; no exec-log schema change (producers, not predicates —
  doc 24 D6's story is untouched).
- No effect-system change. `noteUnicodeVersion` body untouched (the pcall
  cursor oddity is a TODO flag for Bart, not a silent fix).
- `sCodepointN` (multi), variadic `char`, 3-arg `rep`, the format chain,
  pattern engine: still barriers.
- `docs/lua-stdlib-inventory.csv`: rows already `implemented` (tier-0);
  recording is not an inventory dimension — no row changes (Z-5 scope).

## D8. Tests (the adversarial set)

- **D1a regression pair**: hot loop under an enclosing pcall raising
  mid-recording — (a) out-of-range `char` (the pre-existing c3 shape), (b)
  `upper` under a replay-session version mismatch. Assert: no trace
  commits from the poisoned execution; a later clean execution records
  normally; `--dump-aborts` shows `.raised`.
- **Unicode parity, not ASCII-only**: upper/lower over mixed ASCII +
  Latin-1 + multi-byte input — tier-1a oracle vs native regs/exit parity,
  and VM e2e vs tier-0 truth. Simple mapping is 1:1 count-preserving —
  pinned.
- **scp matrix**: 1/2/3-arg shapes; negative wrap (−1 → last char);
  out-of-range i (→ empty → side-exit; tier-0 replays to nil) through BOTH
  continuations — valid nil-consuming control flow AND a raising
  expression (review M6); non-ASCII codepoint values; U+0000 (embedded
  NUL) as a REAL result distinct from the −1 sentinel; the 2-arg aux==b
  ref-sharing shape.
- **Empty-range deopt-state parity (review M6)**: upper/sub allocate
  earlier in the same iteration, then scp side-exits — identical
  `completed`, `exit_instr == scp index`, register parity, and tier-0-only
  vs traced `next_obj_id` / live-object / post-collection equality (the
  id-stream lemma exercised at this exit).
- **Fail-closed matrix**: non-string operand (record-time `.bad_type`);
  float index (abort); `nwanted >= 2` codepoint call (abort); malformed-ty
  native compile bail for all three ops AND for one retrofitted snew op
  (the D4 hardening pinned).
- **Budget**: a trace with upper+lower+sub carries `guard_gc` with A ≥ 3
  (structural IR assert); scp does NOT inflate A.
- **Pin invariant**: VM e2e — trace with `upper` runs natively
  (`native_entries > 0`), `vm.unicode_version_pinned` true,
  `requires_unicode_pin` set on the committed trace; plus a record→replay
  pair where the replay session traces natively and outputs are
  byte-identical with exactly ONE `.unicode_version` effect in the log.
- **`.pure3` contract pins**: dead scp is DCE'd; scp with invariant
  operands is NOT hoisted; two scp differing only in `aux` are NOT merged;
  compaction remaps `aux` (a trace long enough to compact).
- **str_manip e2e shape**: the bench loop body (sub/upper/lower/reverse/
  len/codepoint ×2) traces with zero aborts and enters natively; output ==
  tier-0 truth.

## D9. Gates

Full suite both legs (incl. `-Djit-debug`); hashgate 84/84; `just bench`
28/28 cross=ok ×2; instruction A/B vs an abcc301 shadow (rc-checked,
magnitude-checked — the zsh lesson); str_manip before/after ratio recorded
honestly (the 1/64 `rep(char(...), 4, "-")` branch stays a side-exit — the
3-arg rep barrier is out of scope and its cost is measured, not hidden).

## Non-goals

- `sCodepointN` / multi-result recording; variadic `char`; 3-arg `rep`.
- CSE/hoisting of `scp` (excluded above, fail closed; CSE is provably
  admissible later — the key covers aux — but needs its own root-class
  test story).
- ASCII-specialized case ops (Z-6: the ASCII fast path lives inside the one
  shared core).
- ~~The `nextLoggedEffect`-cursor pcall-retry oddity (TODO.md, Bart's
  call)~~ — Bart called it: fixed post-landing (see "Landed results").
- Record-mode snapshot-resume effect re-logging (pre-existing TODO).
- Pattern engine, `string.format` chain (own arcs).
- Trace serialization/deserialization (if it ever lands, D1's invariant is
  a named obligation on that design).

## Codex review ledger (2026-08-28)

Blockers: none. Majors: #1 "error aborts recording" was false → D1a (the
general fix, incl. the pre-existing schar1 exposure). #2 overbroad
monotonicity claim → epoch-scoped invariant (beginTopLevelEpoch clearCache /
fresh-VM restore). #3 e2e assert is not a tripwire → `requires_unicode_pin`
bit + commit/entry/arm asserts (arm suffices for patched links by
monotonicity). #4 CSE-key claim was backwards (CseKey covers aux); real gap
is liveness/LICM/preheader walks → dedicated `.pure3` kind, CSE/LICM
excluded deliberately. #5 exhaustive result-`ty` validation + operand
bounds; retrofit the missing ty checks onto the existing snew arms. #6
empty-range exit needs deopt-STATE parity (id stream) not just output. #7
scp exit-classification pinned (aux is never a PC). #8 closed append-only
sweep inventory (traceser ordinal pins, viz enums, writeIrInstr ternary
rendering, troptdiag walks). Minors: #m1 arity wording split (b vs c). #m2
sentinel: 64-bit signed compare + U+0000 test. #m3 codepointCore owns the
range logic. #m4 stralloc module-doc scope amendment. #m5 pin-before-
scratch-OOM ordering recorded in the proof.

## Landed results (2026-08-28)

Implementation matched this doc; deltas from the plan, findings, and the
gate record:

- **Everything specified landed as specified**: `supper`/`slower` (snew
  `.alloc` class via `emitSnewCallout`, srev arg shape), `scp` (`.pure3`,
  separate `emitScpCallout`, args (s,i,j) in rdi/rsi/rdx, no heap arg, −1
  sentinel via full-width `cmp r64, imm32` sign-extension), wire ordinals
  69/70/71, `requires_unicode_pin` stamping + entry/`driveChain` asserts,
  the M5 result-`ty` retrofit on ALL existing snew/tostr arms, tier-1a arms,
  and the D6 sweep (traceser count 69→72, viz `TERNARY_AUX_OPS` — which also
  fixed ssub's aux never rendering in the web disasm).
- **One integration point the doc's sweep missed, caught by the else-arm
  audit**: `isProvenStringRef` (trace.zig) — without `supper`/`slower` rows a
  nested producer chain (`lower(upper(x))`, once it can record) would emit a
  redundant-but-sound `guard_string` on the inner result. Added; every other
  else-armed IrOp switch verified correct-by-exclusion (notably `emit`'s
  PC-stamping must NOT touch scp — aux is a ref, review M7 — and
  `guardExitPc` stays null for all three).
- **Tests**: 12 new (5 recorder/e2e in interp_trace_test, incl. the flagship
  native run under effect-recording with exactly ONE `.unicode_version`
  entry + replay leg; 3 hand-built native in nativegen_lowering_test, incl.
  U+0000-vs-sentinel, heap-less scp compilation, and the M5 malformed-stamp
  matrix with its control leg) + the D1a test from c1. All D8 rows covered.
- **Gates**: full suite green both legs (normal + `-Djit-debug`); hashgate
  84/84; `just bench` 28/28 cross=ok ×2, board stable; instruction A/B vs a
  3d0b946 `just shadow` baseline (nm-verified: 0 new symbols in base, 2 in
  c2): scalar +0.0006%, nsieve −0.0004%, fft −0.05%, str_manip −0.56% — no
  regressions.
- **The honest str_manip outcome**: 5.1–5.3× LuaJIT, unchanged. The bench's
  core is `lower(upper(a))` — the inner call sits in last-arg position,
  compiles to MULTRET, and recording aborts `.cross_frame` at the call
  (`--dump-aborts`: 1 site, anchor `run`). The A/B probe proves the arc's
  machinery works and the abort merely moved to the pre-existing frontier:
  the same core through an intermediate local records with ZERO aborts.
  TODO.md #1 (nested last-arg builtin calls) is now str_manip's sole
  blocker and the next general gap; `sub`/`reverse`/`len`/2-arg `codepoint`
  all record today, and `rep(char(..), 4, "-")` hides behind a 1-in-64
  branch (side-exit, fine).
- **Flagged, then fixed (2026-08-28, follow-up commit)**: the
  `nextLoggedEffect` pre-validation cursor advance. Bart chose
  validate-before-advance: the cursor now moves only on acceptance
  (kind-check before advance; `noteUnicodeVersion` peeks via the new
  `peekLoggedEffect`, validates the version, consumes on success), so a
  rejected wrong-version entry stays in front of the cursor and every retry
  re-raises instead of silently pinning the mismatched table. Found while
  testing: `beginTopLevelEpoch` already refuses a top-level re-`run` of a
  faulted VM (`DirtyTopLevelEntry`), so the closed seam is host-driven
  calls / resumed sessions; the faulted-but-live TODO entry was amended
  accordingly.
