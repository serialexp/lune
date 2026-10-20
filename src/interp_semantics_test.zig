//! Tests for `interp.zig` — semantics.
//!
//! Extracted verbatim from `interp.zig`; bodies are unchanged.
//! Shared harness lives in `interp_testutil.zig`.

const interp = @import("interp.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const execlog = @import("execlog.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

const catchable = interp.catchable;

const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;

// ---------------------------------------------------------------------------
// End-to-end integration — source text → parse → compile → run.
//
// The hand-assembled tests above pin individual opcodes; these drive the whole
// Phase 3 pipeline (front end + compiler + tier-0 interpreter + heap) the way
// the CLI runs a real program, and assert on the captured `print` output. The
// front-end imports are function-local so the production interpreter keeps no
// dependency on the parser/compiler — only this test path does.
// ---------------------------------------------------------------------------

// --- cross-frame tracing (8-mode parity) -------------------------------------

test "cross-frame: a fixed-arity leaf call inlines and stays byte-identical" {
    // The load-bearing replay-safety proof for Phase 0. The hot loop body calls a
    // non-recursive, fixed-arity Lua leaf; the recorder inlines it (guard_func +
    // seeded callee slots + return mapping). This must compute exactly what tier-0
    // computes by really calling `f`, across all 8 modes AND across a keyframe
    // restore — which is what proves `guard_func` keying on the stable `Proto.id`
    // (not a raw pointer) survives replay, where heap objects come back at a new
    // address with the same preserved id.
    try expectProgram(
        \\local function f(x) return x * x + 1 end
        \\local s = 0
        \\for i = 1, 200 do s = s + f(i) end
        \\print(s)
        \\
    ,
        "2686900\n",
    );
}

test "cross-frame: a two-deep call chain inlines and stays byte-identical" {
    // Genuine depth-2 inlining: g is inlined into the loop body, and the `fn(x)`
    // call *inside* g inlines h one level deeper (verified by --dump-traces emitting
    // two guard_func ops). The callee `h` is passed as a parameter, NOT read through
    // an upvalue — upvalue access in a callee is still an abort in Phase 0, so a
    // `local h; local function g() return h(...) end` chain would silently fall back
    // to tier-0 and prove nothing. Exercises the recorder frame stack push/pop and
    // base_off restore across two levels; deopt still replays the whole iteration
    // from the outer header.
    try expectProgram(
        \\local function h(y) return y + 3 end
        \\local function g(fn, x) return fn(x) * 2 end
        \\local s = 0
        \\for i = 1, 120 do s = s + g(h, i) end
        \\print(s)
        \\
    ,
        "15240\n",
    );
}

test "cross-frame: a callee reached through an upvalue inlines and stays byte-identical" {
    // Cluster sub-lever 1, the canonical replay-safety proof. The hot loop lives in
    // `inner`, whose body calls `A` — reached not as a local/param but through an
    // *upvalue* (`get_upval`). The recorder cannot read an upvalue from the executor
    // (no `*Vm`, no closure there), so it snapshots the loop-invariant callee into a
    // synthetic slab slot above the anchor window, emits a `slot_load` + `guard_func`,
    // and the dispatch loop re-seeds that slot every entry. This must match what
    // tier-0 computes by really resolving the upvalue and calling `A`, across all 8
    // modes AND a keyframe restore — proving the snapshot+guard is deterministic and
    // that `guard_func` keyed on the stable `Proto.id` survives replay.
    try expectProgram(
        \\local function A(i, j) return i * 100 + j end
        \\local function inner()
        \\  local s = 0
        \\  for j = 1, 200 do s = s + A(2, j) end
        \\  return s
        \\end
        \\print(inner())
        \\
    ,
        "60100\n",
    );
}

test "cross-frame: a callee reached through a global inlines and stays byte-identical" {
    // The global analogue of the upvalue case. `A` is a loop-invariant *global*
    // (`get_global`, a raw `globals.get` with no `__index` dispatch), snapshotted and
    // guarded the same way. Byte-identical across all 8 modes + keyframe restore is
    // the proof the global snapshot+guard replays deterministically.
    try expectProgram(
        \\function A(i, j) return i * 100 + j end
        \\local s = 0
        \\for j = 1, 200 do s = s + A(2, j) end
        \\print(s)
        \\
    ,
        "60100\n",
    );
}

test "global-access cache: removal, redefinition, rehash and _G writes are all seen" {
    // `get_global`/`set_global` keep a per-name hash-slot hint
    // (`Proto.global_slot_hints`). Every way the globals table can change
    // under a warm hint must still read the current value: a removal leaves
    // a dead slot, growth moves every key, `_G` and `rawset` write without
    // `set_global`, and mass deletion followed by an insert rehashes.
    try expectProgram(
        \\x = 1
        \\local function rd() return x end
        \\local function sum(n) local s = 0 for i = 1, n do s = s + x end return s end
        \\print(rd(), sum(10))
        \\x = nil
        \\print(rd())
        \\x = 2
        \\print(rd(), sum(10))
        \\for i = 1, 200 do _G["g" .. i] = i end
        \\print(rd(), g7, g200, sum(10))
        \\x = 3
        \\print(rd())
        \\_G.x = 4
        \\print(rd())
        \\rawset(_G, "x", 5)
        \\print(rd(), sum(10))
        \\for i = 1, 200 do _G["g" .. i] = nil end
        \\for i = 1, 300 do _G["h" .. i] = i end
        \\print(rd(), g7, h300, sum(10))
        \\
    ,
        "1\t10\nnil\n2\t20\n2\t7\t200\t20\n3\n4\n5\t50\n5\tnil\t300\t50\n",
    );
}

test "cross-frame: a changed upvalue callee deopts the snapshot and replays byte-identically" {
    // The snapshot's load-bearing guard. The first `inner()` records a trace whose
    // `guard_func` pins proto X (the first `A`). Reassigning the captured upvalue `A`
    // to a different-proto closure means the second `inner()` re-resolves the snapshot
    // to proto Y on entry; `guard_func` must fail and side-exit to tier-0, which
    // computes the second sum by really calling the new `A`. Byte-identical across all
    // 8 modes + keyframe restore proves the per-entry re-resolve + guard is what keeps
    // the snapshot sound when the loop-invariant cell changes between entries.
    try expectProgram(
        \\local A = function(i, j) return i + j end
        \\local function inner()
        \\  local s = 0
        \\  for j = 1, 200 do s = s + A(1, j) end
        \\  return s
        \\end
        \\print(inner())
        \\A = function(i, j) return i * j end
        \\print(inner())
        \\
    ,
        "20300\n20100\n",
    );
}

test "nested-loop: a linked 2-deep numeric-for nest is byte-identical across all modes (Phase 3)" {
    // The end-to-end output gate for nested-loop trace linking
    // (`docs/design/15-nested-loop-linking.md`). The inner loop traces as a root;
    // its loop-done exit arms a continuation at the post-inner-loop pc; the
    // continuation records the remaining outer-body work, reaches the next inner
    // `for_prep`, and links back to the inner root. Phase 3 executes that tier-1a
    // chain, including the nsieve-shaped statement between the inner loop and the
    // outer back-edge. Output must stay byte-identical to tier-0 across
    // {gc_stress × {off, record-only, no-opt, record-execute, native}}. Inner trip
    // count (30) clears `min_trip_entry` so the inner trace is genuinely entered
    // and the linked path can run in the executing modes.
    try expectProgram(
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do
        \\    s = s + i * j
        \\  end
        \\  s = s + i
        \\end
        \\print(s)
        \\
    ,
        "382120\n",
    );
}

test "nested-loop link: a float for_prep hand-off uses (init−step)+step, not init" {
    // Regression for the codex-flagged BLOCKER in `recForPrepLink`: the link
    // hand-off's first-iteration bounds test and published entry state must be
    // `(init−step)+step` — computed with the SAME float rounding tier-0's
    // `for_prep` + `for_loop` pair applies — not `init` (the "(init−step)+step =
    // init" shortcut only holds for ints). The inner loop gets hot with a benign
    // float step (1.0), so the continuation records a link with float-typed
    // control guards; the LAST outer iteration re-enters that link with
    // `step = 1e16`, where `(1.0 − 1e16) + 1e16 = 0.0 ≠ 1.0`. tier-0 runs that
    // inner loop once with `j = 0.0`; the pre-fix trace handed the inner root
    // `j = 1.0` and printed 18136 instead of 18135. The step comes from an array
    // (not a branch) so no branch guard side-exits before the link is reached.
    try expectProgram(
        \\local steps = {}
        \\for i = 1, 40 do steps[i] = 1.0 end
        \\steps[40] = 1e16
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1.0, 30.0, steps[i] do
        \\    s = s + j
        \\  end
        \\end
        \\print(s)
        \\
    ,
        "18135\n",
    );
}

// --- hash-field (string-keyed) tracing (8-mode parity) -----------------------
// `obj.field` get/set on the hash part records a trace via href/guard_hash/hload/
// hstore (doc 11). These prove the recorded trace is byte-identical to tier-0
// across {gc_stress × {off, record-only, no-opt, record-execute, native}} + a
// keyframe restore — the replay-safety proof. With H1 landed the four ops lower to
// native (seed-resolved invariant cell pointer + typed tag-checked load/store), so
// the `record_execute_native` mode now genuinely exercises the native field path; a
// per-entry seed-resolution miss routes that entry to the tier-1a oracle, which
// side-exits identically — so the matrix stays byte-identical either way.

test "hash field: a constant-key field read loop is byte-identical across all 8 modes" {
    // The minimal read shape: `t.x` is a present, constant-key, int field. Records
    // guard_table → href → guard_hash → hload → guard_int and runs every iteration
    // through the cell.
    try expectProgram(
        \\local t = {x = 7}
        \\local s = 0
        \\for i = 1, 200 do s = s + t.x end
        \\print(s)
        \\
    ,
        "1400\n",
    );
}

test "hash field: an RMW field store (t.n = t.n + 1) is byte-identical across all 8 modes" {
    // The read-modify-write shape OOP code is built from. The hstore sinks below the
    // loop close (C1), so a guard side-exit leaves it unexecuted and deopt-replay
    // applies it exactly once — the double-apply hazard this matrix would catch.
    try expectProgram(
        \\local t = {n = 0}
        \\for i = 1, 200 do t.n = t.n + 1 end
        \\print(t.n)
        \\
    ,
        "200\n",
    );
}

test "hash field: a float-valued field RMW is byte-identical across all 8 modes" {
    // nbody-shaped float arithmetic on a hash field (`p.x = p.x + 0.5`). Float is the
    // second in-scope scalar type; guard_float pins it.
    try expectProgram(
        \\local p = {x = 0.0}
        \\for i = 1, 100 do p.x = p.x + 0.5 end
        \\print(p.x)
        \\
    ,
        "50\n",
    );
}

test "hash field: two distinct constant keys record distinct cells, byte-identical" {
    // `t.a` and `t.b` resolve to two different hoistable cells in the same table; the
    // recorder emits two independent href/guard_hash/hload chains.
    try expectProgram(
        \\local t = {a = 3, b = 4}
        \\local s = 0
        \\for i = 1, 100 do s = s + t.a * t.b end
        \\print(s)
        \\
    ,
        "1200\n",
    );
}

test "hash field: a field whose type changes mid-loop deopts and replays byte-identically" {
    // The type-guard's load-bearing proof. The trace records `t.x` as an int
    // (guard_int on the hload). At i==50 tier-0 stores a float into `t.x`; on the next
    // entry the guard_int fails, side-exits to tier-0, and the sum continues in float.
    // Byte-identical across all 8 modes + keyframe restore proves the field type guard
    // side-exits on the same iteration the oracle and (eventually) native would.
    try expectProgram(
        \\local t = {x = 1}
        \\local s = 0.0
        \\for i = 1, 100 do
        \\  if i == 50 then t.x = 1.5 end
        \\  s = s + t.x
        \\end
        \\print(s)
        \\
    ,
        "125.5\n",
    );
}

test "hash field: a table that grows between trace entries re-resolves the cell (no dangle)" {
    // The cell-dangle proof for Approach B. The hot inner loop traces `t.n` (a present
    // cell). Between inner-loop entries the outer loop inserts a NEW key, growing `t`'s
    // hash part — a rehash that can MOVE the value cell. Because the seeded cell pointer
    // is re-resolved (`getPtr`) and its `hash.count()` re-validated at every entry
    // (never serialized, never assumed stable), a grown table fails the count check →
    // that entry declines native and runs the tier-1a oracle, whose guard_hash side-
    // exits to tier-0. The hoisted pointer can therefore never dangle. Byte-identical
    // across all 8 modes + keyframe restore is the proof.
    try expectProgram(
        \\local t = {n = 0}
        \\local total = 0
        \\for outer = 1, 5 do
        \\  for i = 1, 200 do t.n = t.n + 1 end
        \\  t["k" .. outer] = outer
        \\  total = total + t.n
        \\end
        \\print(t.n, total)
        \\
    ,
        "1000\t3000\n",
    );
}

// --- pure-builtin tracing (math.sqrt → guard_builtin/fsqrt, 8-mode parity) -------
// `sqrt(x)` on a float in a hot loop records a trace (guard_builtin pins the callee
// identity, fsqrt computes @sqrt) instead of aborting `.host_barrier` (doc 12).
// In F0 native declines any trace carrying the two new ops: the tier-1a oracle
// runs them under the record-execute / record-execute-noopt modes, while the
// `record_execute_native` mode skips the non-compilable trace and falls back to
// tier-0. Both the oracle's `fsqrt` arm and tier-0's `mSqrt` use `@sqrt`, which
// agrees bit-for-bit with the future native `sqrtsd` under the default MXCSR — so
// all five trace modes are byte-identical now and stay so when F1 lands.

test "pure-builtin: a sqrt float-reduction loop is byte-identical across all 8 modes" {
    // The nbody-shaped inner-loop call: `sqrt` reaches the loop as a loop-invariant
    // upvalue (`local sqrt = math.sqrt`), guard_builtin re-proves its identity, and
    // fsqrt computes the result from the guarded-float argument every iteration.
    try expectProgram(
        \\local sqrt = math.sqrt
        \\local s = 0.0
        \\for i = 1, 300 do s = s + sqrt(i * 1.0) end
        \\print(s)
        \\
    ,
        "3472.556388576408\n",
    );
}

test "pure-builtin: a rebound sqrt upvalue deopts via guard_builtin and replays byte-identically" {
    // guard_builtin's load-bearing proof. The first `run()` records a trace pinning the
    // `sqrt` builtin. Reassigning the captured upvalue to an ordinary Lua function
    // means the second `run()` re-resolves the seeded callee to a non-pure value on
    // entry; guard_builtin must fail closed and side-exit to tier-0, which really calls
    // the new `sqrt`. Byte-identical across all 8 modes + keyframe restore proves the
    // per-entry callee re-resolve + identity guard keeps the inlined builtin sound
    // when the loop-invariant cell changes between entries.
    try expectProgram(
        \\local sqrt = math.sqrt
        \\local function run()
        \\  local s = 0.0
        \\  for i = 1, 300 do s = s + sqrt(i * 1.0) end
        \\  return s
        \\end
        \\print(run())
        \\sqrt = function(x) return x + 1.0 end
        \\print(run())
        \\
    ,
        "3472.556388576408\n45450\n",
    );
}

test "pure-builtin: NaN and -0.0 sqrt results through a traced loop are byte-identical" {
    // The IEEE edge cases the trace must reproduce exactly: `sqrt(-1.0)` is a quiet
    // NaN (sign bit set on x86-64 → prints `-nan`) and `sqrt(-0.0)` is `-0.0`. Both
    // flow through a hot traced loop (loop-invariant const arg → konst + guard_float
    // + fsqrt), and `fsqrt` is deliberately never constant-folded, so the value is
    // produced by `@sqrt` on every tier identically.
    try expectProgram(
        \\local sqrt = math.sqrt
        \\local n = 0.0
        \\for i = 1, 300 do n = sqrt(-1.0) end
        \\print(n)
        \\local z = 1.0
        \\for i = 1, 300 do z = sqrt(-0.0) end
        \\print(z)
        \\
    ,
        "-nan\n-0\n",
    );
}

// --- long-bracket string literals (8-mode parity) ----------------------------

test "long string: plain, concat, and length" {
    try expectProgram(
        "print([[hello]] .. [[ world]], #[[abc]])\n",
        "hello world\t3\n",
    );
}

test "long string: a leading newline is dropped, later newlines kept" {
    // The newline right after `[[` is not part of the string; the one before
    // `]]` is. So the value is "hi\n" (length 3).
    try expectProgram(
        "local s = [[\nhi\n]]\nprint(#s)\n",
        "3\n",
    );
}

test "long string: no escape interpretation" {
    // Backslash-t inside a long string is two literal bytes, not a tab.
    try expectProgram(
        "print([[a\\tb]])\n",
        "a\\tb\n",
    );
}

test "long string: leveled brackets pass through inner ]] verbatim" {
    try expectProgram(
        "print([==[x]]y]==])\n",
        "x]]y\n",
    );
}

test "leveled long comment is ignored between statements" {
    try expectProgram(
        "print(1)--[=[ hidden ]] still hidden ]=]\nprint(2)\n",
        "1\n2\n",
    );
}

test "foundations: pcall catches a bare runtime fault (synthesized message)" {
    try expectProgram(
        "print(pcall(function() return nil + 1 end))\n",
        "false\tanonymous:1: attempt to perform arithmetic on a nil value\n",
    );
}

test "a multret consumer that faults on a non-callable value consumes its producer's span" {
    // `f(g())` with `f == nil`: `g()` leaves `reg_top_pending` set for the
    // adjacent consumer. The consumer used to fault before taking it, so the
    // flag leaked past the catcher: the next dynamic producer (`pcall`
    // under `print`) tripped its assert, and release builds suppressed
    // every GC safepoint until some later consumer cleared it.
    try expectProgram(
        \\local f = nil
        \\local function g() return 1, 2 end
        \\print(pcall(function() f(g()) end))
        \\print(pcall(function() return f(g()) end))
        \\print("after")
        \\
    ,
        "false\tanonymous:3: attempt to call a nil value\nfalse\tanonymous:4: attempt to call a nil value\nafter\n",
    );
}

test "pcall unwind closes the faulting frame's escaped upvalue" {
    // A closure captures a local inside the protected function and escapes (stored
    // in an outer variable) before the call errors. On unwind the faulting frame's
    // registers are discarded, so its open upvalue MUST be closed — otherwise it
    // stays open over a slot that (a) falls above the restored `stack_top`, off the
    // GC root scan, and (b) gets overwritten by the next call that reuses it. The
    // `clobber()` call reuses those high slots; `saved()` must still read "live"
    // (closed snapshot), not the clobbered ints. (Regression: SoA Phase 0
    // index-based upvalues + pcall unwind.)
    try expectProgram(
        \\local saved
        \\local ok = pcall(function()
        \\  local x = "live"
        \\  saved = function() return x end
        \\  error("boom")
        \\end)
        \\local function clobber() local a, b, c = 11, 22, 33 return a + b + c end
        \\clobber()
        \\print(ok, saved())
        \\
    ,
        "false\tlive\n",
    );
}

test "xpcall unwind closes the faulting frame's escaped upvalue (after handler)" {
    // Same invariant on the xpcall path: the boundary is restored only after the
    // message handler runs, and the close must accompany that restore. `clobber()`
    // reuses the discarded slots; `saved()` must read the closed snapshot 42.
    try expectProgram(
        \\local saved
        \\local ok = xpcall(function()
        \\  local y = 42
        \\  saved = function() return y end
        \\  error("boom")
        \\end, function(e) return "handled" end)
        \\local function clobber() local a, b, c = 11, 22, 33 return a + b + c end
        \\clobber()
        \\print(ok, saved())
        \\
    ,
        "false\t42\n",
    );
}

// --- error-message polish: located messages across all 8 modes ---------------

test "errmsg: error(msg) renders located through the pcall path" {
    try expectProgram(
        "print(pcall(function() error(\"boom\") end))\n",
        "false\tanonymous:1: boom\n",
    );
}

test "errmsg: error(msg, 0) suppresses the location prefix" {
    try expectProgram(
        "print(pcall(function() error(\"x\", 0) end))\n",
        "false\tx\n",
    );
}

test "errmsg: error(msg, 2) points at the caller's caller" {
    try expectProgram(
        \\local function f() error("deep", 2) end
        \\print(pcall(function() f() end))
        \\
    ,
        "false\tanonymous:2: deep\n",
    );
}

test "errmsg: a non-string error object passes through unprefixed and keeps its type" {
    try expectProgram(
        \\local ok, e = pcall(function() error({code = 1}) end)
        \\print(ok, type(e), e.code)
        \\
    ,
        "false\ttable\t1\n",
    );
}

test "errmsg: a converted native gives the detailed located bad-argument message" {
    try expectProgram(
        "print(pcall(function() return string.sub(nil, 1) end))\n",
        "false\tanonymous:1: bad argument #1 to 'sub' (string expected, got nil)\n",
    );
}

test "errmsg: a non-integral float arg reports the integer-representation reason" {
    try expectProgram(
        "print(pcall(function() return string.sub(\"abc\", 1.5) end))\n",
        "false\tanonymous:1: bad argument #2 to 'sub' (number has no integer representation)\n",
    );
}

test "errmsg: error() with invalid level type or non-integral float raises bad argument" {
    try expectProgram(
        "print(pcall(function() error(\"boom\", \"invalid\") end))\n",
        "false\tanonymous:1: bad argument #2 to 'error' (number expected, got string)\n",
    );
    try expectProgram(
        "print(pcall(function() error(\"boom\", 2.5) end))\n",
        "false\tanonymous:1: bad argument #2 to 'error' (number has no integer representation)\n",
    );
}

test "errmsg: error() with level past depth suppresses location" {
    try expectProgram(
        \\local function f() error("deep", 4) end
        \\print(pcall(function() f() end))
        \\
    ,
        "false\tdeep\n",
    );
}

test "errmsg: select() with float arguments handles conversion and bounds checks" {
    try expectProgram(
        "print(select(2.0, 'a', 'b', 'c'))\n",
        "b\tc\n",
    );
    try expectProgram(
        "print(pcall(function() select(1e20, 'a') end))\n",
        "false\tanonymous:1: bad argument #1 to 'select' (number has no integer representation)\n",
    );
}

test "errmsg: an unconverted (pure) native still names the function, located" {
    try expectProgram(
        "print(pcall(function() return math.floor(\"x\") end))\n",
        "false\tanonymous:1: bad argument to 'floor'\n",
    );
}

// --- load (chunk L-1): runtime compilation -----------------------------------
// `load` compiles a source string into a closure at runtime. It is a pure
// function of the source bytes (no host effect), so every program below runs
// byte-identical across all modes via `expectProgram`. A `load` native is a
// trace barrier like any native, so the compile never perturbs the JIT.

test "string.encode: s:encode() yields a byte array (UTF-8) across all modes" {
    try expectProgram(
        \\local b = ("Hi"):encode()
        \\print(b[1], b[2], #b)
        \\local e = ("é"):encode()
        \\print(e[1], e[2], #e)
        \\
    ,
        "72\t105\t2\n195\t169\t2\n",
    );
}

test "string.decode: round-trips encode and reads a hand-built byte array" {
    try expectProgram(
        \\print(string.decode(("héllo"):encode()) == "héllo")
        \\print(string.decode({72, 105, 33}))
        \\
    ,
        "true\nHi!\n",
    );
}

test "string.decode: malformed UTF-8 is a catchable error" {
    try expectProgram(
        \\local ok, msg = pcall(string.decode, {0xA9})
        \\print(ok, type(msg))
        \\
    ,
        "false\tstring\n",
    );
}

// --- S-E: the u8 (byte) array lane, byte-identical across all 8 modes ---------

test "S-E: a byte-array workload is byte-identical across all modes (u8 lane)" {
    // Dense fill with values in [0,255] commits the u8 lane (1 byte/slot); the hot
    // read loop tiers the u8 `aload` to native. High bytes (>=128) must ZERO-extend
    // — a wrong sign-extend would make t[200]=199 read as a negative and diverge the
    // sum. Identical output in record_execute_native vs tier-0 proves the native
    // movzx matches array.decode's zero-extend.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = (i - 1) % 256 end
        \\local sum = 0
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do sum = sum + t[i] end
        \\end
        \\print(sum)
        \\print(t[129], t[200], t[256])
        \\
    ,
        "3264000\n128\t199\t255\n",
    );
}

test "S-E: a u8->i16 mid-run widen stays deterministic across all modes" {
    // The array commits u8 (bytes 0..255), then a 5000 store widens it to i16
    // (u8's combined-range widen → the smallest signed lane covering [0,5000]). The
    // subsequent hot read loop runs on the widened i16 lane natively. Byte-identical
    // output confirms the widen + widen-eviction path is deterministic under record/
    // replay and native compilation.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 256 do t[i] = i - 1 end
        \\t[100] = 5000
        \\local sum = 0
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do sum = sum + t[i] end
        \\end
        \\print(sum)
        \\print(t[100], t[256])
        \\
    ,
        "3754100\n5000\t255\n",
    );
}

// --- Phase D Gap A: the f64 (double) array lane, byte-identical across all modes -

test "f64 lane: a float-array read reduction is byte-identical across all modes" {
    // Dense fill with doubles commits the f64 lane (8 bytes/slot); the hot read loop
    // tiers the f64 `aload` to native (`lea` + `movsd` into an XMM, `addsd` to the
    // carried float accumulator). The load moves raw bits — `array.decode` for `.f64`
    // is a `@bitCast` — so record_execute_native must match tier-0 bit-for-bit. The
    // sum (and the spot reads) are exactly representable, so the text is unambiguous.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\local sum = 0.0
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do sum = sum + t[i] end
        \\end
        \\print(sum)
        \\print(t[1], t[129], t[256])
        \\
    ,
        "1644800\n0.5\t64.5\t128\n",
    );
}

test "f64 lane: a constant float-array fill is byte-identical across all modes" {
    // The hot write loop tiers the f64 `astore` to native (`movsd` store + presence
    // `bts`). guard_fits is a no-op for f64 (every double fits) and tropt folds it for
    // the constant store, so this also exercises the proveKinds path that admits an
    // f64 astore with no `fits_ok` coverage. Slots 257..300 stay at their fill value
    // (the hot loop only writes 1..256), proving the store is correctly bounded.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do t[i] = 2.5 end
        \\end
        \\local s = 0.0
        \\for i = 1, 256 do s = s + t[i] end
        \\print(s)
        \\print(t[1], t[200], t[256], t[300])
        \\
    ,
        "640\n2.5\t2.5\t2.5\t150\n",
    );
}

// --- Gap B: read-modify-write store-sinking, byte-identical across all modes ----

test "f64 RMW: a read-modify-write float loop is byte-identical across all modes" {
    // The hot inner loop is `t[i] = t[i] + 1.0` — an `aload` of t[i] feeds the value
    // that the `astore` writes back. Under the old C1 rule this aborted recording
    // ("astore after aload"); store-sinking (doc 07) defers the single astore below
    // every loop-exit guard so it lands just before `.loop`.
    //
    // This is the load-bearing idempotence test. mahina's deopt re-runs a whole
    // iteration from the loop header: a trace completes N iterations, then on the
    // loop-back guard side-exit tier-0 re-runs iteration N+1 from bytecode. Because
    // the store is sunk *below* that guard, the side-exiting iteration never executed
    // its store inside the trace, so tier-0 applies `+1.0` exactly once. If the store
    // were *not* sunk, the boundary iteration would double-apply (+2.0) and
    // record_execute_native would diverge from tier-0. The accumulate makes any
    // double-apply visible in the printed bits.
    //
    // After 100 reps over 1..256: t[i] = i*0.5 + 100 (exactly representable);
    // t[257..300] stay at their fill value, proving the sunk store stays in bounds.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do t[i] = t[i] + 1.0 end
        \\end
        \\print(t[1], t[128], t[256], t[300])
        \\
    ,
        "100.5\t164\t228\t150\n",
    );
}

test "f64 multi-store RMW: a two-store butterfly loop is byte-identical across all modes" {
    // Gap C (doc 08): the inner loop reads two slots then writes both back
    // (`a=t[i]; b=t[i+1]; t[i]=a+1; t[i+1]=b+2`) — TWO read-modify-write stores per
    // iteration, the shape Gap B's single-store rule aborted on (the 2nd store hit
    // `pending_store != null`). Multi-store sinking defers both stores and flushes
    // them, in recorded order, below every loop-exit guard.
    //
    // Same load-bearing idempotence argument as Gap B, now for K=2: on a side-exit
    // (incl. the loop-back `guard_true`) NEITHER sunk store has executed on-trace, so
    // tier-0 re-runs the iteration from the header and applies each `+1.0`/`+2.0`
    // exactly once. A double-apply on the boundary iteration would shift t[253]/t[254]
    // by their increment — visible in the printed bits. All reads precede all stores,
    // so the "no aload after a sunk store" invariant holds.
    //
    // After 100 reps over odd i in 1..253 (writing t[i], t[i+1]): t[i] = i*0.5 + 100,
    // t[i+1] = (i+1)*0.5 + 200 (exactly representable). t[255] stays at its fill value
    // (the loop's last i is 253, writing t[253],t[254]) — proving the sunk stores stay
    // in bounds.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\for rep = 1, 100 do
        \\  for i = 1, 254, 2 do
        \\    local a = t[i]
        \\    local b = t[i+1]
        \\    t[i]   = a + 1.0
        \\    t[i+1] = b + 2.0
        \\  end
        \\end
        \\print(t[1], t[2], t[253], t[254], t[255])
        \\
    ,
        "100.5\t201\t226.5\t327\t127.5\n",
    );
}

test "load: compiles and runs a returning chunk" {
    try expectProgram(
        "local f = load(\"return 6 * 7\"); print(f())\n",
        "42\n",
    );
}

test "load: loaded chunk sees globals and prints" {
    try expectProgram(
        \\local f = load("print('hi from load')")
        \\f()
        \\
    ,
        "hi from load\n",
    );
}

test "load: a syntax error returns (nil, message) rather than raising" {
    try expectProgram(
        "local f, e = load(\"return ++\"); print(f, type(e))\n",
        "nil\tstring\n",
    );
}

test "load: the error message carries the chunk name and line" {
    try expectProgram(
        "local f, e = load(\"return ++\"); print(e)\n",
        "(load):1: expected an expression\n",
    );
}

test "load: an explicit chunk name appears in the error message" {
    try expectProgram(
        "local f, e = load(\"x x\", \"mychunk\"); print(e)\n",
        "mychunk:1: expected a statement (assignment or call)\n",
    );
}

test "load: a runtime fault in loaded code reports the loaded chunk's line" {
    try expectProgram(
        \\local f = load("local x = 1\nreturn nil + x")
        \\print(pcall(f))
        \\
    ,
        "false\t(load):2: attempt to perform arithmetic on a nil value\n",
    );
}

test "load: a single-result call yields only the closure (primary projection)" {
    try expectProgram(
        "print(type(load(\"return 1\")))\n",
        "function\n",
    );
}

test "load: passing a non-string chunk raises a bad-argument error" {
    try expectProgram(
        "print(pcall(function() return load(42) end))\n",
        "false\tanonymous:1: bad argument #1 to 'load' (string expected, got number)\n",
    );
}

test "load: a long chunk name is reported in full (allocated message, no truncation)" {
    // The error message is allocated, not written into a fixed buffer, so an
    // arbitrarily long chunk name appears in full as the `<name>:<line>: <msg>`
    // prefix — verified by checking the 600-char name is the message's prefix and
    // the message extends past it with the location/syntax text.
    try expectProgram(
        \\local name = string.rep("a", 600)
        \\local f, e = load("x x", name)
        \\print(f, e:sub(1, 600) == name, #e > 600)
        \\
    ,
        "nil\ttrue\ttrue\n",
    );
}

test "load: a loaded chunk is vararg — arguments arrive through ..." {
    try expectProgram(
        \\local add = load("local a, b = ...\nreturn a + b")
        \\print(add(2, 3), add(10, 20))
        \\
    ,
        "5\t30\n",
    );
}

// --- metatables (chunk 2a): __index / __newindex + set/getmetatable ----------
// Each program runs byte-identical across all 8 modes (gc_stress × 5 trace
// modes). Metatable-bearing tables abort trace recording (`has_metatable`), so
// the metamethod path is the tier-0 dispatch under every mode.

test "metatable: __index table gives class/inheritance method lookup" {
    try expectProgram(
        \\local Animal = {}
        \\Animal.__index = Animal
        \\function Animal.new(name) return setmetatable({ name = name }, Animal) end
        \\function Animal:speak() return self.name .. " speaks" end
        \\local a = Animal.new("rex")
        \\print(a:speak())
        \\print(a.name)
        \\
    ,
        "rex speaks\nrex\n",
    );
}

test "metatable: __index function form" {
    try expectProgram(
        \\local t = setmetatable({}, { __index = function(_, k) return "<" .. k .. ">" end })
        \\print(t.foo)
        \\t.foo = 1
        \\print(t.foo)
        \\
    ,
        "<foo>\n1\n",
    );
}

test "metatable: __newindex function fires only for absent keys" {
    try expectProgram(
        \\local n = 0
        \\local t = setmetatable({}, { __newindex = function(tt, k, v) n = n + 1; rawset(tt, k, v) end })
        \\t.a = 1
        \\t.a = 2
        \\t.b = 3
        \\print(n, t.a, t.b)
        \\
    ,
        "2\t2\t3\n",
    );
}

test "metatable: __newindex table redirects writes" {
    try expectProgram(
        \\local backing = {}
        \\local t = setmetatable({}, { __newindex = backing })
        \\t.x = 10
        \\print(rawget(t, "x"), backing.x)
        \\
    ,
        "nil\t10\n",
    );
}

test "metatable: getmetatable and __metatable protection" {
    try expectProgram(
        \\local mt = { __metatable = "locked" }
        \\local t = setmetatable({}, mt)
        \\print(getmetatable(t))
        \\print(pcall(setmetatable, t, {}))
        \\
    ,
        "locked\nfalse\tmain:4: cannot change a protected metatable\n",
    );
}

test "metatable: setmetatable(t, nil) clears the metatable" {
    try expectProgram(
        \\local t = setmetatable({}, { __index = function() return 7 end })
        \\print(t.missing)
        \\setmetatable(t, nil)
        \\print(t.missing)
        \\print(getmetatable(t))
        \\
    ,
        "7\nnil\nnil\n",
    );
}

test "metatable: string methods resolve through the shared string metatable" {
    try expectProgram(
        \\print(("foo"):upper())
        \\print(("hello"):len())
        \\print(("a,b,c"):gsub(",", ";"))
        \\print(getmetatable("") ~= nil)
        \\
    ,
        "FOO\n5\na;b;c\t2\ntrue\n",
    );
}

test "metatable: __index chain (multi-level inheritance) is bounded and resolves" {
    try expectProgram(
        \\local A = {}; A.__index = A; A.kind = "A"
        \\local B = setmetatable({}, A); B.__index = B
        \\local obj = setmetatable({}, B)
        \\print(obj.kind)
        \\
    ,
        "A\n",
    );
}

test "metatable: a self-referential __index chain raises rather than hanging" {
    try expectProgram(
        \\local loop = {}
        \\setmetatable(loop, { __index = loop })
        \\print(pcall(function() return loop.nope end))
        \\
    ,
        "false\tanonymous:3: '__index' chain too long; possible loop\n",
    );
}

test "metatable: setmetatable rejects a non-table/non-nil metatable argument" {
    try expectProgram(
        \\print(pcall(function() return setmetatable({}, 5) end))
        \\
    ,
        "false\tanonymous:1: bad argument #2 to 'setmetatable' (nil or table expected, got number)\n",
    );
}

// Recorder/JIT safety (reviewer-found, chunk 2a): a hot array loop forms a
// native trace on a metatable-free table; if `setmetatable` later adds a
// metatable, the cached trace must side-exit to tier-0 (the `guard_table`
// no-metatable half) so `__newindex` still fires. A wrong (raw native store)
// would diverge the native mode from tier-0 — caught by all 8 modes here.

test "metatable: setmetatable mid-hot-loop still dispatches __newindex (trace guard)" {
    try expectProgram(
        \\local t, n = {}, 0
        \\local mt = { __newindex = function(tt, k, v) n = n + 1; rawset(tt, k, v) end }
        \\for i = 1, 100 do
        \\  if i == 30 then setmetatable(t, mt) end
        \\  t[i] = true
        \\end
        \\print(n)
        \\
    ,
        "71\n",
    );
}

test "metatable: a native trace re-entered on a metatable'd table dispatches __newindex" {
    try expectProgram(
        \\local function fill(t) for i = 1, 60 do t[i] = i end end
        \\local a = {}
        \\fill(a)
        \\local log = {}
        \\local b = setmetatable({}, { __newindex = function(_, _, v) log[#log + 1] = v end })
        \\fill(b)
        \\print(#a, #log, rawlen(b))
        \\
    ,
        "60\t60\t0\n",
    );
}

// ── Chunk 2b: arithmetic / compare / __concat / __len / __call / __tostring
// metamethods. Each routes the tier-0 op's TypeError (or non-callable) path
// through the shared dispatch helpers, which call into the VM via `callValue`
// — a trace barrier, so every recorded op already aborts on a non-number
// operand and side-exits to tier-0, keeping all 8 modes byte-identical.

test "metatable: arithmetic metamethods (add/sub/mul/div/mod/pow/idiv)" {
    try expectProgram(
        \\local V = {}; V.__index = V
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\V.__add  = function(a, b) return v(a.n + b.n) end
        \\V.__sub  = function(a, b) return v(a.n - b.n) end
        \\V.__mul  = function(a, b) return v(a.n * b.n) end
        \\V.__div  = function(a, b) return a.n / b.n end
        \\V.__mod  = function(a, b) return a.n % b.n end
        \\V.__pow  = function(a, b) return a.n ^ b.n end
        \\V.__idiv = function(a, b) return a.n // b.n end
        \\print((v(2) + v(3)).n)
        \\print((v(7) - v(4)).n)
        \\print((v(3) * v(5)).n)
        \\print(v(7) / v(2))
        \\print(v(7) % v(3))
        \\print(v(2) ^ v(10))
        \\print(v(7) // v(2))
        \\
    ,
        "5\n3\n15\n3.5\n1\n1024\n3\n",
    );
}

test "nil-coalescing: ?? returns rhs only on pure nil, short-circuits" {
    try expectProgram(
        \\print(nil ?? 5)
        \\print(7 ?? 5)
        \\-- pure-nil: a non-nil-but-falsy lhs is KEPT (this is the `or` pitfall ?? avoids)
        \\print(false ?? 9)
        \\print(0 ?? 9)
        \\print("" ?? 9)
        \\-- left-assoc chain: first non-nil wins
        \\print(nil ?? nil ?? 3)
        \\print(nil ?? 2 ?? 3)
        \\-- short-circuit: rhs not evaluated when lhs is non-nil
        \\local hit = false
        \\local function side() hit = true; return 1 end
        \\local _ = 42 ?? side()
        \\print(hit)
        \\local _ = nil ?? side()
        \\print(hit)
        \\
    ,
        "5\n7\nfalse\n0\n\n3\n2\nfalse\ntrue\n",
    );
}

test "nil-coalescing: ?? precedence sits at the or level" {
    try expectProgram(
        \\-- `or` and `??` share a level, left-assoc: evaluate left to right.
        \\print(false or nil ?? 8)
        \\-- (false or nil) ?? 8  ->  nil ?? 8  ->  8
        \\print(nil ?? false or 8)
        \\-- (nil ?? false) or 8  ->  false or 8  ->  8
        \\
    ,
        "8\n8\n",
    );
}

test "customary operators: ! && || != alias not/and/or/~=" {
    try expectProgram(
        \\print(!true)
        \\print(!false)
        \\print(!nil)
        \\print(1 == 1 && 2 == 2)
        \\print(1 == 2 || 3 == 3)
        \\print(1 != 2)
        \\print(1 != 1)
        \\-- short-circuit must match `and`/`or`: the RHS is not evaluated
        \\local hit = false
        \\local function side() hit = true; return true end
        \\local _ = false && side()
        \\print(hit)
        \\local _ = true || side()
        \\print(hit)
        \\-- value-returning (not boolean-coercing), exactly like and/or
        \\print(nil || 7)
        \\print(5 && 9)
        \\
    ,
        "false\ntrue\ntrue\ntrue\ntrue\ntrue\nfalse\nfalse\nfalse\n7\n9\n",
    );
}

test "compound assignment: every operator on a name target" {
    try expectProgram(
        \\local a = 10
        \\a += 5;   print(a)   -- 15
        \\a -= 3;   print(a)   -- 12
        \\a *= 2;   print(a)   -- 24
        \\a //= 5;  print(a)   -- 4
        \\a %= 3;   print(a)   -- 1
        \\a <<= 4;  print(a)   -- 16
        \\a >>= 1;  print(a)   -- 8
        \\a |= 1;   print(a)   -- 9
        \\a &= 12;  print(a)   -- 8
        \\a ~= 5;   print(a)   -- 13  (xor-assign, NOT inequality)
        \\a ~>>= 1; print(a)   -- 6   (arithmetic right shift)
        \\local f = 7.0
        \\f /= 2;   print(f)   -- 3.5  (true division)
        \\local s = "foo"
        \\s ..= "bar"; print(s) -- foobar
        \\
    ,
        "15\n12\n24\n4\n1\n16\n8\n9\n8\n13\n6\n3.5\nfoobar\n",
    );
}

test "compound assignment: ~= is xor-assign in statement context, inequality elsewhere" {
    // The same `~=` token means xor-assign as a statement and ~= (inequality) in
    // an expression — disambiguated purely by parse position.
    try expectProgram(
        \\local a = 12
        \\a ~= 10           -- xor-assign: 12 ~ 10 = 6
        \\print(a)          -- 6
        \\print(a ~= 6)     -- inequality: false
        \\print(a ~= 7)     -- inequality: true
        \\
    ,
        "6\nfalse\ntrue\n",
    );
}

test "compound assignment: field and index targets, prefix evaluated exactly once" {
    try expectProgram(
        \\-- index target with a side-effecting key: must be evaluated once.
        \\local calls = 0
        \\local function idx() calls = calls + 1; return 2 end
        \\local t = {10, 20, 30}
        \\t[idx()] += 100
        \\print(t[2], calls)   -- 120  1
        \\-- field target
        \\local o = { n = 5 }
        \\o.n *= 4
        \\print(o.n)           -- 20
        \\-- side-effecting object prefix evaluated once, too
        \\local ocalls = 0
        \\local function obj() ocalls = ocalls + 1; return o end
        \\obj().n -= 3
        \\print(o.n, ocalls)   -- 17  1
        \\
    ,
        "120\t1\n20\n17\t1\n",
    );
}

test "bitwise: ~>> arithmetic right shift (sign-extending, 64-bit)" {
    try expectProgram(
        \\print(-8 ~>> 1)
        \\print(-1 ~>> 63)
        \\print(256 ~>> 4)
        \\print(-1 ~>> 100)
        \\print(1 ~>> -5)
        \\print((1 << 62) ~>> 60)
        \\
    ,
        // -4, -1 (sign fill, not 1), 16, -1 (overshift saturates to sign), 32 (neg
        // count = logical left), 4
        "-4\n-1\n16\n-1\n32\n4\n",
    );
}

test "metatable: bitwise metamethods (band/bor/bxor/shl/shr/sar/bnot)" {
    try expectProgram(
        \\local N = {}; N.__index = N
        \\local function n(x) return setmetatable({ v = x }, N) end
        \\N.__band = function(a, b) return a.v & b.v end
        \\N.__bor  = function(a, b) return a.v | b.v end
        \\N.__bxor = function(a, b) return a.v ~ b.v end
        \\N.__shl  = function(a, b) return a.v << b.v end
        \\N.__shr  = function(a, b) return a.v >> b.v end
        \\N.__sar  = function(a, b) return a.v ~>> b.v end
        \\N.__bnot = function(a) return ~a.v end
        \\print(n(6) & n(3))
        \\print(n(6) | n(1))
        \\print(n(6) ~ n(3))
        \\print(n(1) << n(4))
        \\print(n(64) >> n(2))
        \\print(n(-8) ~>> n(1))
        \\print(~n(0))
        \\
    ,
        "2\n7\n5\n16\n16\n-4\n-1\n",
    );
}

test "metatable: unary minus __unm" {
    try expectProgram(
        \\local V = {}
        \\V.__unm = function(a) return -a.n end
        \\local x = setmetatable({ n = 9 }, V)
        \\print(-x)
        \\print(-setmetatable({ n = -4 }, V))
        \\
    ,
        "-9\n4\n",
    );
}

test "metatable: __add dispatches from the right operand when the left lacks it" {
    try expectProgram(
        \\local V = {}
        \\V.__add = function(a, b)
        \\  local an = type(a) == "table" and a.n or a
        \\  local bn = type(b) == "table" and b.n or b
        \\  return an + bn
        \\end
        \\local x = setmetatable({ n = 10 }, V)
        \\print(x + 5)
        \\print(5 + x)
        \\
    ,
        "15\n15\n",
    );
}

test "metatable: __eq fires only between two tables" {
    try expectProgram(
        \\local V = {}
        \\V.__eq = function(a, b) return a.n == b.n end
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\print(v(2) == v(2))
        \\print(v(2) == v(3))
        \\print(v(2) ~= v(3))
        \\print(v(2) == 2)
        \\print(v(2) == "x")
        \\
    ,
        "true\nfalse\ntrue\nfalse\nfalse\n",
    );
}

test "metatable: comparison __lt/__le with gt/ge via operand swap" {
    try expectProgram(
        \\local V = {}
        \\V.__lt = function(a, b) return a.n < b.n end
        \\V.__le = function(a, b) return a.n <= b.n end
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\print(v(1) < v(2), v(2) < v(2))
        \\print(v(2) <= v(2), v(3) <= v(2))
        \\print(v(3) > v(1), v(1) > v(3))
        \\print(v(2) >= v(5), v(5) >= v(2))
        \\
    ,
        "true\tfalse\ntrue\tfalse\ntrue\tfalse\nfalse\ttrue\n",
    );
}

test "metatable: __concat dispatches from either operand" {
    try expectProgram(
        \\local V = {}
        \\V.__concat = function(a, b)
        \\  local an = type(a) == "table" and a.n or a
        \\  local bn = type(b) == "table" and b.n or b
        \\  return "C(" .. an .. "," .. bn .. ")"
        \\end
        \\local x = setmetatable({ n = 4 }, V)
        \\print(x .. "z")
        \\print("z" .. x)
        \\print(x .. x)
        \\
    ,
        "C(4,z)\nC(z,4)\nC(4,4)\n",
    );
}

test "metatable: __len overrides table length" {
    try expectProgram(
        \\local V = {}
        \\V.__len = function(a) return a.size end
        \\local x = setmetatable({ 1, 2, size = 42 }, V)
        \\print(#x)
        \\local plain = { 1, 2, 3 }
        \\print(#plain)
        \\
    ,
        "42\n3\n",
    );
}

test "metatable: __call single and multi-return" {
    try expectProgram(
        \\local adder = setmetatable({ base = 10 }, {
        \\  __call = function(self, x, y) return self.base + x + y end,
        \\})
        \\print(adder(3, 4))
        \\local multi = setmetatable({}, {
        \\  __call = function(self, a, b) return a, b, a + b end,
        \\})
        \\local x, y, z = multi(2, 5)
        \\print(x, y, z)
        \\local sum = 0
        \\for i = 1, 5 do sum = sum + adder(i, 0) end
        \\print(sum)
        \\
    ,
        "17\n2\t5\t7\n65\n",
    );
}

test "metatable: a callable table dispatches __call through host reentry (pcall, table.sort)" {
    // `callValue` (the pcall/sort/gsub reentry primitive) honours `__call`
    // identically to the bytecode call arm — a callable table is callable from
    // every site, not just direct `t(...)`.
    try expectProgram(
        \\local c = setmetatable({}, { __call = function(self, a, b) return a + b end })
        \\print(pcall(c, 3, 4))
        \\local items = { 3, 1, 2 }
        \\local cmp = setmetatable({}, { __call = function(self, x, y) return x < y end })
        \\table.sort(items, cmp)
        \\print(items[1], items[2], items[3])
        \\
    ,
        "true\t7\n1\t2\t3\n",
    );
}

test "metatable: a __call cycle is caught as a stack overflow, not a hang" {
    try expectProgram(
        \\local loop = {}
        \\setmetatable(loop, { __call = loop })
        \\print(pcall(function() return loop() end))
        \\
    ,
        "false\tanonymous:3: stack overflow\n",
    );
}

test "metatable: __tostring via tostring(), print(), and concat" {
    try expectProgram(
        \\local Pt = { __tostring = function(p) return "Pt(" .. p.x .. "," .. p.y .. ")" end }
        \\local p = setmetatable({ x = 1, y = 2 }, Pt)
        \\print(tostring(p))
        \\print(p)
        \\print("p=" .. tostring(p))
        \\
    ,
        "Pt(1,2)\nPt(1,2)\np=Pt(1,2)\n",
    );
}

test "metatable: arithmetic on a table without the metamethod still raises located TypeError" {
    try expectProgram(
        \\print(pcall(function() local t = {}; return t + 1 end))
        \\print(pcall(function() return {} .. "x" end))
        \\print(pcall(function() return -({}) end))
        \\
    ,
        "false\tanonymous:1: attempt to perform arithmetic on a table value\n" ++
            "false\tanonymous:2: attempt to concatenate a table value\n" ++
            "false\tanonymous:3: attempt to perform arithmetic on a table value\n",
    );
}

test "bitwise faults report integer-representation / bitwise-operation messages" {
    // mahina is strict integer-only for bitwise: a float operand (even integral)
    // gets "number has no integer representation"; a non-number operand gets
    // "attempt to perform bitwise operation on a <type> value" — distinct from
    // the arithmetic message, matching Lua 5.4's split.
    try expectProgram(
        \\print(pcall(function() return 3.5 & 1 end))
        \\print(pcall(function() return 1 << 2.0 end))
        \\print(pcall(function() return 1 | {} end))
    ,
        "false\tanonymous:1: number has no integer representation\n" ++
            "false\tanonymous:2: number has no integer representation\n" ++
            "false\tanonymous:3: attempt to perform bitwise operation on a table value\n",
    );
}

test "metatable: calling a table with no __call raises a located TypeError" {
    try expectProgram(
        \\print(pcall(function() local t = {}; return t() end))
        \\
    ,
        "false\tanonymous:1: attempt to call a table value\n",
    );
}

test "metatable: __tostring returning a non-string is rejected" {
    try expectProgram(
        \\local bad = setmetatable({}, { __tostring = function() return 42 end })
        \\print(pcall(function() return tostring(bad) end))
        \\
    ,
        "false\tanonymous:2: bad argument to 'tostring'\n",
    );
}

// --- _G (the global environment table) ---------------------------------------

test "_G: reflective access through the global environment table" {
    try expectProgram(
        \\print(_G.print == print)
        \\_G.x = 5
        \\print(_G.x)
        \\print(_G._G == _G)
        \\print(_G._VERSION ~= nil)
        \\
    ,
        "true\n5\ntrue\ntrue\n",
    );
}

test "_G: globals and _G are the same table in both directions" {
    try expectProgram(
        \\g = 42
        \\print(_G.g)
        \\_G.h = 7
        \\print(_G.h)
        \\print(_G._G._G.g)
        \\
    ,
        "42\n7\n42\n",
    );
}

// --- xpcall before-unwind handler + debug.traceback --------------------------

test "xpcall: message handler transforms the error value" {
    try expectProgram(
        "print(xpcall(function() error(\"boom\") end, function(e) return \"H:\" .. e end))\n",
        "false\tH:anonymous:1: boom\n",
    );
}

test "xpcall: a handler that itself errors yields the fixed message" {
    try expectProgram(
        "print(xpcall(function() error(\"x\") end, function(e) error(\"handler boom\") end))\n",
        "false\terror in error handling\n",
    );
}

test "xpcall: pcall behaviour is unchanged (false + located value)" {
    try expectProgram(
        "print(pcall(function() error(\"boom\") end))\n",
        "false\tanonymous:1: boom\n",
    );
}

test "debug.traceback: handler sees the live faulting stack" {
    try expectProgram(
        \\local ok, tb = xpcall(function()
        \\  local t = nil
        \\  return t.x
        \\end, debug.traceback)
        \\print(ok)
        \\print(string.find(tb, "stack traceback:", 1, true) ~= nil)
        \\print(string.find(tb, "attempt to index", 1, true) ~= nil)
        \\
    ,
        "false\ntrue\ntrue\n",
    );
}

test "debug.traceback: message prefix + exact format at top level" {
    try expectProgram(
        "print(debug.traceback(\"x\"))\n",
        "x\nstack traceback:\n\tmain:1: in main chunk\n",
    );
}

test "debug.traceback: a non-stringable message (table) is returned unchanged" {
    try expectProgram(
        \\local t = {}
        \\print(debug.traceback(t) == t)
        \\
    ,
        "true\n",
    );
}

test "debug.traceback: a number message is coerced (Lua's lua_tostring quirk)" {
    try expectProgram(
        "print(debug.traceback(42))\n",
        "42\nstack traceback:\n\tmain:1: in main chunk\n",
    );
}

test "debug.traceback: level skips frames (level past the top is empty)" {
    try expectProgram(
        "print(debug.traceback(\"x\", 99))\n",
        "x\nstack traceback:\n",
    );
}

test "debug.traceback: an out-of-range float level is a bad argument, not a trap" {
    try expectProgram(
        \\local ok, e = pcall(function() return debug.traceback("x", 1e100) end)
        \\print(ok, string.find(e, "integer representation", 1, true) ~= nil)
        \\
    ,
        "false\ttrue\n",
    );
}

// Determinism corpus: a hot loop summing __add-bearing vector objects. The
// metamethod call is a trace barrier so the loop never tiers up past the call,
// but the output and the captured snapshot bytes must be byte-identical across
// two independent runs (proves no nondeterminism leaks through the dispatch
// helpers). expectProgram already runs this across all 8 modes.

test "metatable: hot loop accumulating through __add is deterministic across modes" {
    try expectProgram(
        \\local V = {}; V.__index = V
        \\V.__add = function(a, b) return setmetatable({ n = a.n + b.n }, V) end
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\local acc = v(0)
        \\for i = 1, 200 do acc = acc + v(i) end
        \\print(acc.n)
        \\
    ,
        "20100\n",
    );
}

test "errmsg: a converted table native reports the located bad-argument message" {
    try expectProgram(
        "print(pcall(function() return table.insert(nil, 1) end))\n",
        "false\tanonymous:1: bad argument #1 to 'insert' (table expected, got nil)\n",
    );
}

test "foundations: error raises an arbitrary value caught by pcall" {
    try expectProgram(
        \\local ok, e = pcall(function() error({code = 42}) end)
        \\print(ok, type(e), e.code)
        \\
    ,
        "false\ttable\t42\n",
    );
}

test "foundations: recursive pcall — inner result flows out of the outer" {
    try expectProgram(
        "print(pcall(function() return pcall(function() error(\"x\") end) end))\n",
        "true\tfalse\tanonymous:1: x\n",
    );
}

test "foundations: table.sort default comparator (ascending)" {
    try expectProgram(
        \\local t = {3, 1, 2}
        \\table.sort(t)
        \\print(t[1], t[2], t[3])
        \\
    ,
        "1\t2\t3\n",
    );
}

test "foundations: table.sort with a custom comparator (descending)" {
    try expectProgram(
        \\local t = {5, 3, 8, 1}
        \\table.sort(t, function(a, b) return a > b end)
        \\print(t[1], t[2], t[3], t[4])
        \\
    ,
        "8\t5\t3\t1\n",
    );
}

test "foundations: a sort comparator that errors propagates to an enclosing pcall" {
    try expectProgram(
        "print(pcall(function() table.sort({1, 2}, function() error(\"cmp\") end) end))\n",
        "false\tanonymous:1: cmp\n",
    );
}

test "foundations: string.gsub function replacement substitutes each match" {
    try expectProgram(
        "print(string.gsub(\"hello\", \"l\", function(c) return c .. c end))\n",
        "hellllo\t2\n",
    );
}

test "foundations: string.gsub function returning nil keeps the original text" {
    try expectProgram(
        "print(string.gsub(\"a1b2c3\", \"%a\", function(c) if c == \"b\" then return \"B\" end end))\n",
        "a1B2c3\t3\n",
    );
}

test "foundations: assert passes its arguments through when truthy" {
    try expectProgram(
        "print(assert(5, \"msg\"))\n",
        "5\tmsg\n",
    );
}

test "foundations: assert raises its message when falsy, caught by pcall" {
    try expectProgram(
        "print(pcall(function() assert(false, \"boom\") end))\n",
        "false\tboom\n",
    );
}

test "foundations: xpcall runs the message handler on the error value" {
    try expectProgram(
        \\local ok, r = xpcall(function() error("orig") end, function(m) return "handled:" .. m end)
        \\print(ok, r)
        \\
    ,
        "false\thandled:anonymous:1: orig\n",
    );
}

test "strings: lexicographic ordering with < <= > >=" {
    try expectProgram(
        \\print("a" < "b", "b" < "a", "a" < "a")
        \\print("ab" < "abc", "abc" < "ab", "Z" < "a")
        \\print("a" <= "a", "b" <= "a", "ab" >= "ab")
        \\print("apple" > "apricot", "banana" > "apple")
        \\
    ,
        "true\tfalse\tfalse\n" ++
            "true\tfalse\ttrue\n" ++
            "true\tfalse\ttrue\n" ++
            "false\ttrue\n",
    );
}

test "strings: table.sort orders a string list with the default comparator" {
    try expectProgram(
        \\local t = {"cherry", "apple", "banana"}
        \\table.sort(t)
        \\print(t[1], t[2], t[3])
        \\
    ,
        "apple\tbanana\tcherry\n",
    );
}

test "strings: comparing a string with a number is a catchable type error" {
    try expectProgram(
        "print(pcall(function() return \"a\" < 1 end))\n",
        "false\tanonymous:1: attempt to compare string with number\n",
    );
}

test "doc 61 P1: surplus varargs past the caller window survive the callee's locals" {
    // 40 arguments from a multret producer run far past the main chunk's
    // window. The callee used to be laid at the window end, over the surplus
    // varargs, so its locals clobbered what `select` then read.
    try expectProgram(
        \\local function g(...)
        \\  local a, b, c, d, e, f, h, i, j, k = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
        \\  local n = select('#', ...)
        \\  local s = 0
        \\  for x = 1, n do s = s + select(x, ...) end
        \\  return n, s, a + b + c + d + e + f + h + i + j + k
        \\end
        \\local t = {}
        \\for i = 1, 40 do t[i] = i end
        \\print(g(table.unpack(t)))
        \\
    ,
        "40\t820\t55\n",
    );
}

test "doc 61 P1: fixed params from a dynamic span past the caller window copy without overlap" {
    // A small caller window and a twelve-parameter callee: the argument span
    // ends past the window, so copying the params up to the window end
    // overwrote later params before they were read (a silently wrong sum).
    // The call site is hot, so the recorder's refusal of this shape is
    // exercised in the traced legs too.
    try expectProgram(
        \\local function h(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
        \\  return p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9 + p10 + p11 + p12
        \\end
        \\local function call(t) return h(table.unpack(t)) end
        \\local t = {}
        \\for i = 1, 12 do t[i] = i * 100 + i end
        \\local s = 0
        \\for k = 1, 50 do s = s + call(t) end
        \\print(s)
        \\
    ,
        "393900\n",
    );
}

test "doc 61 P2: a native's dynamic argument span past the window stays rooted across a re-entry" {
    // `print` gets six fresh objects whose only references are its arguments;
    // arguments 3..6 sit past `run`'s window, above `stack_top`. Each
    // `__tostring` allocates (the stress legs collect on it). Before P2 the
    // tail was neither rooted nor safe from the re-entry's window: a collection
    // swept it and `print` read freed objects (a panic, or wrong output).
    try expectProgram(
        \\local mt = {__tostring = function(t)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  return "T" .. t.n
        \\end}
        \\local function fresh()
        \\  local r = {}
        \\  for i = 1, 6 do r[i] = setmetatable({n = i}, mt) end
        \\  return r
        \\end
        \\local function run() print(table.unpack(fresh())) end
        \\for k = 1, 3 do run() end
        \\
    ,
        "T1\tT2\tT3\tT4\tT5\tT6\n" ++
            "T1\tT2\tT3\tT4\tT5\tT6\n" ++
            "T1\tT2\tT3\tT4\tT5\tT6\n",
    );
}

test "doc 61 P2: a __call handler's dynamic argument span past the window stays rooted" {
    try expectProgram(
        \\local mt = {__tostring = function(t)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  return "T" .. t.n
        \\end}
        \\local callable = setmetatable({}, {__call = function(self, ...)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  print(...)
        \\end})
        \\local function fresh()
        \\  local r = {}
        \\  for i = 1, 6 do r[i] = setmetatable({n = i}, mt) end
        \\  return r
        \\end
        \\local function run() callable(table.unpack(fresh())) end
        \\for k = 1, 2 do run() end
        \\
    ,
        "T1\tT2\tT3\tT4\tT5\tT6\n" ++
            "T1\tT2\tT3\tT4\tT5\tT6\n",
    );
}

test "doc 61 P2: an error inside a native with a raised span unwinds to the protected boundary" {
    // The span stays raised while the error propagates; `pcall` discards the
    // frames and resets `stack_top`. Later calls and collections must see a
    // normal stack.
    try expectProgram(
        \\local mt = {__tostring = function(t)
        \\  if t.n == 2 then error("bad " .. t.n) end
        \\  return "T" .. t.n
        \\end}
        \\local function fresh()
        \\  local r = {}
        \\  for i = 1, 6 do r[i] = setmetatable({n = i}, mt) end
        \\  return r
        \\end
        \\local function run() print(table.unpack(fresh())) end
        \\for k = 1, 3 do
        \\  local ok, e = pcall(run)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  print(ok, e)
        \\end
        \\
    ,
        // `print` streams: "T1\t" is out before argument 2's `__tostring` raises.
        "T1\tfalse\tanonymous:2: bad 2\n" ++
            "T1\tfalse\tanonymous:2: bad 2\n" ++
            "T1\tfalse\tanonymous:2: bad 2\n",
    );
}

test "doc 61 P3: a native __index handler on the fused a[i][j] path keeps its intermediate rooted" {
    // `outer[1]` yields a fresh table held only in a Zig local by the fused
    // get; its `__index` is `table.sort`, which keeps that table across every
    // comparator call. The comparator allocates (the stress legs collect), and
    // before P3 the table was swept mid-sort (a panic, or "compare nil with nil").
    try expectProgram(
        \\local outer = setmetatable({}, {__index = function()
        \\  return setmetatable({5, 3, 4, 1, 2}, {__index = table.sort})
        \\end})
        \\local calls = 0
        \\local cmp = function(a, b)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  calls = calls + 1
        \\  return a < b
        \\end
        \\local _ = outer[1][cmp]
        \\print(calls > 0)
        \\
    ,
        "true\n",
    );
}

test "doc 61 P3: a native __newindex handler on the fused a[i][j] = v path keeps its intermediate rooted" {
    try expectProgram(
        \\local outer = setmetatable({}, {__index = function()
        \\  return setmetatable({5, 3, 4, 1, 2}, {__newindex = table.sort})
        \\end})
        \\local calls = 0
        \\local cmp = function(a, b)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  calls = calls + 1
        \\  return a < b
        \\end
        \\outer[1][cmp] = 0
        \\print(calls > 0)
        \\
    ,
        "true\n",
    );
}

test "doc 61 P3: an error inside a parked native call unwinds to the protected boundary" {
    try expectProgram(
        \\local outer = setmetatable({}, {__index = function()
        \\  return setmetatable({5, 3, 4, 1, 2}, {__index = table.sort})
        \\end})
        \\local cmp = function(a, b)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  error("stop")
        \\end
        \\for k = 1, 3 do
        \\  local ok, e = pcall(function() return outer[1][cmp] end)
        \\  local g = {}
        \\  for i = 1, 300 do g[i] = {i} end
        \\  print(ok, e)
        \\end
        \\
    ,
        "false\tanonymous:7: stop\n" ++
            "false\tanonymous:7: stop\n" ++
            "false\tanonymous:7: stop\n",
    );
}

test "doc 61: a multret result span past the window survives collections inside its consumer" {
    // `mk` returns 40 fresh tables held only by its result span, which ends
    // past the caller's window. No collection runs between the producer and
    // the consumer `g(...)` (`reg_top_pending` suppresses that safepoint);
    // the span becomes `g`'s varargs, and the stress legs collect at every
    // instruction of `g` while it reads them.
    try expectProgram(
        \\local function mk(n)
        \\  local r = {}
        \\  for i = 1, n do r[i] = {i} end
        \\  return table.unpack(r)
        \\end
        \\local function g(...)
        \\  local s = 0
        \\  for i = 1, select('#', ...) do s = s + (select(i, ...))[1] end
        \\  return s
        \\end
        \\for k = 1, 3 do print(g(mk(40))) end
        \\
    , "820\n820\n820\n");
}

/// Doc 61 Phase 0 frame-shape probes: what a collection would see right
/// now. `shapes()` describes every live frame, bottom first; `topshape()`
/// only the top one, so it can be an `xpcall` handler at the depth cap,
/// where no Lua handler frame fits. Per frame: `F:<op>` (in flight, with
/// the opcode its mask row names), `I:<op>` (innermost), `S` (suspended
/// at a `.call`), `U` (unknown).
const ShapeProbe = struct {
    fn shapes(ctx: *anyopaque, _: []const Value) anyerror!Value {
        const vm: *interp.Vm = @ptrCast(@alignCast(ctx));
        return describe(vm, 0);
    }

    fn topshape(ctx: *anyopaque, _: []const Value) anyerror!Value {
        const vm: *interp.Vm = @ptrCast(@alignCast(ctx));
        return describe(vm, vm.depth - 1);
    }

    /// `after(f)`: re-enters `f` twice, then reports the shapes from inside
    /// this same native activation — the moment a collection between two
    /// `callValue`s of one native (`table.sort`'s comparisons) would see.
    fn after(ctx: *anyopaque, args: []const Value) anyerror!Value {
        const vm: *interp.Vm = @ptrCast(@alignCast(ctx));
        var res: [1]Value = undefined;
        _ = try vm.callValue(args[0], &.{}, &res);
        _ = try vm.callValue(args[0], &.{}, &res);
        return describe(vm, 0);
    }

    fn describe(vm: *interp.Vm, from: usize) !Value {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (from..vm.depth) |i| {
            const shape = vm.frameShape(i);
            const code = vm.frames[i].closure.proto.code;
            const sep: []const u8 = if (len == 0) "" else " ";
            const part = switch (shape.kind) {
                .in_flight, .innermost => try std.fmt.bufPrint(buf[len..], "{s}{s}:{s}", .{
                    sep,
                    if (shape.kind == .in_flight) "F" else "I",
                    if (shape.pc < code.len) @tagName(code[shape.pc].op) else "?",
                }),
                .suspended_call => try std.fmt.bufPrint(buf[len..], "{s}S", .{sep}),
                .unknown => try std.fmt.bufPrint(buf[len..], "{s}U", .{sep}),
            };
            len += part.len;
        }
        return vm.heap.internValue(buf[0..len]);
    }

    fn install(vm: *interp.Vm) !void {
        const gpa = vm.heap.gpa;
        inline for (.{ .{ "shapes", &shapes }, .{ "topshape", &topshape }, .{ "after", &after } }) |n| {
            const native = try vm.heap.newNative(n[1], n[0]);
            try vm.globals.set(gpa, try vm.heap.internValue(n[0]), Value.heap(&native.header));
        }
    }
};

fn expectShapes(source: [:0]const u8, expected: []const u8) !void {
    return util.expectProgramTuned(source, expected, .{ .setup = &ShapeProbe.install });
}

test "doc 61 Phase 0: a native's caller is in flight at its .call; Lua callers below are suspended" {
    try expectShapes(
        \\local function f() return shapes() end
        \\local a, b
        \\for i = 1, 10 do a = shapes(); b = f() end
        \\print(a)
        \\print(b)
        \\
    , "F:call\nS F:call\n");
}

test "doc 61 Phase 0: a metamethod's caller is in flight at the instruction that invoked it" {
    try expectShapes(
        \\local mt = {__add = function(x, y) return shapes() end,
        \\            __index = function(t, k) return shapes() end}
        \\local t = setmetatable({}, mt)
        \\local a, b
        \\for i = 1, 10 do a = t + i; b = t.x end
        \\print(a)
        \\print(b)
        \\
    , "F:add F:call\nF:get_index F:call\n");
}

test "doc 61 Phase 0: a native stays in flight between and after its re-entries" {
    // `after` re-enters twice and then looks: a callValue that cleared the
    // flag instead of restoring it would leave its caller innermost. Under
    // `pcall` the same holds one frame up, and a metamethod re-entry inside
    // the callback restores its own frame's flag.
    try expectShapes(
        \\local mt = {__add = function(x, y) return 1 end}
        \\local t = setmetatable({}, mt)
        \\local function f() local v = t + 1; return v end
        \\local a, b
        \\for i = 1, 10 do
        \\  a = after(f)
        \\  b = select(2, pcall(after, f))
        \\end
        \\print(a)
        \\print(b)
        \\
    , "F:call\nF:call\n");
}

test "doc 61 Phase 0: pcall, table.sort and a require loader keep their caller in flight across every re-entry" {
    // The comparator runs once per comparison: each sees the same shapes.
    try expectShapes(
        \\local seen = {}
        \\local t = {5, 3, 8, 1, 9, 2}
        \\table.sort(t, function(x, y) seen[shapes()] = true; return x < y end)
        \\for k in pairs(seen) do print(k) end
        \\local ok, s = pcall(function() return shapes() end)
        \\print(s)
        \\package.preload.m = function() return shapes() end
        \\print(require('m'))
        \\print(shapes())
        \\
    , "F:call F:call\nF:call F:call\nF:call F:call\nF:call\n");
}

test "doc 61 Phase 0: an xpcall handler sees the faulting frame in flight at its fault" {
    // Faults at pc 0, and right after a `.call` (where the call-suspended
    // classification would wrongly apply).
    try expectShapes(
        \\local function g() return 1 end
        \\local function h(e) return shapes() end
        \\local function at0(t) return t.x end
        \\local function aftercall(z) return g() + z end
        \\local a, b
        \\for i = 1, 10 do
        \\  a = select(2, xpcall(at0, h, nil))
        \\  b = select(2, xpcall(aftercall, h, nil))
        \\end
        \\print(a)
        \\print(b)
        \\
    , "F:call F:get_index F:call\nF:call F:add F:call\n");
}

test "doc 61 Phase 0: a retained in-flight parent stays in flight under its faulting metamethod" {
    // protected fn → `.add` → Lua `__add` faults → the handler runs over
    // both: the parent is in flight at `.add`, the metamethod at its fault.
    // The `g()` before the `.add` puts a `.call` at `pc − 1`.
    try expectShapes(
        \\local function g() return 1 end
        \\local mt = {__add = function(x, y) return y.z end}
        \\local t = setmetatable({}, mt)
        \\local function f() local q = g(); return t + q end
        \\local r
        \\for i = 1, 10 do r = select(2, xpcall(f, function(e) return shapes() end)) end
        \\print(r)
        \\
    , "F:call F:add F:get_index F:call\n");
}

test "doc 61 Phase 0: nested xpcall marks each level's own faulting frame" {
    try expectShapes(
        \\local function bad(t) return t.x end
        \\local function inner(e) return shapes() end
        \\local function outer(e) return select(2, xpcall(bad, inner, nil)) end
        \\local r
        \\for i = 1, 10 do r = select(2, xpcall(bad, outer, nil)) end
        \\print(r)
        \\print(shapes())
        \\
    , "F:call F:get_index F:call F:get_index F:call\nF:call\n");
}

test "doc 61 Phase 0: a rejected push leaves the faulting frame's pc at its .call" {
    // Stack overflow: the deepest `r` fails to push its callee. The handler
    // is a native (no Lua frame fits at the cap). Without the pc re-store
    // the frame would name the `.add` after the call.
    try expectShapes(
        \\local function r(n) return r(n + 1) + 1 end
        \\print(select(2, xpcall(r, topshape, 1)))
        \\print(shapes())
        \\
    , "F:call\nF:call\n");
}

/// Records the innermost frame's pc at every collection while `f` is on top.
const InnermostProbe = struct {
    var pcs: [32]usize = undefined;
    var n: usize = 0;

    fn probe(vm: *interp.Vm) void {
        if (vm.depth == 0) return;
        const top = vm.depth - 1;
        if (!std.mem.eql(u8, vm.frames[top].closure.proto.name, "f")) return;
        std.debug.assert(vm.frameShape(top).kind == .innermost);
        if (n < pcs.len) pcs[n] = vm.frameShape(top).pc;
        n += 1;
    }
};

test "doc 61 Phase 0: a collection between instructions sees the innermost frame's next pc" {
    // Under gc_stress every prologue collects, so a straight-line `f`
    // collects once before each of its instructions, in order: the mask
    // row is the instruction about to run (§4.1). A frame pc left at the
    // previous instruction would repeat a pc and lag one behind.
    const gpa = testing.allocator;
    var vm = try interp.Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    vm.heap.gc_stress = true;
    InnermostProbe.n = 0;
    interp.Vm.test_collect_probe = &InnermostProbe.probe;
    defer interp.Vm.test_collect_probe = null;
    try util.compileRun(gpa, &vm,
        \\local function f(x)
        \\  local y = x + 1
        \\  local z = y * x
        \\  return z - y
        \\end
        \\print(f(3))
    );
    try testing.expectEqualStrings("8\n", sink.buffered());
    const len = InnermostProbe.n;
    try testing.expect(len >= 3 and len <= InnermostProbe.pcs.len);
    for (InnermostProbe.pcs[0..len], 0..) |pc, i| try testing.expectEqual(i, pc);
}

test "doc 61 Phase 0: a reused frame slot starts out of flight" {
    // `pcall(bad, 10)` faults ten metamethod levels deep and leaves every
    // other frame slot's flag set when its frames are discarded. `rec` then
    // reuses those slots: tier-0 pushes, the native self-push once `rec` is
    // hot (the native leg asserts it ran). A push that kept a stale flag
    // would show `F` where `S` belongs, and trip the `.call` arm's assert.
    const check = struct {
        fn pushed(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
            if (mode == .record_execute_native) try testing.expect(vm.trace.self_call_pushes > 0);
        }
    };
    try util.expectProgramTuned(
        \\local mt = {}
        \\local t = setmetatable({}, mt)
        \\local function bad(n) local v = t + n; return v end
        \\mt.__add = function(x, y) if y == 0 then error("e") end return bad(y - 1) end
        \\local function rec(n)
        \\  if n == 0 then return shapes() end
        \\  local s = rec(n - 1)
        \\  return s
        \\end
        \\local r
        \\for i = 1, 400 do pcall(bad, 10); r = rec(6) end
        \\print(r)
        \\
    , "S S S S S S S F:call\n", .{ .setup = &ShapeProbe.install, .inspect = &check.pushed });
}

test "doc 61 Phase 0: a backtrace names an in-flight parent's own instruction line" {
    // `f` is in flight at the `.add`, whose span starts on line 3; the
    // instruction before it, the call to its right operand, is on line 4.
    // The old `pc − 1` rule for every parent reported line 4. Both the
    // traceback (`backtraceFrames`) and `error`'s level-2 location prefix
    // (`callSiteAt`) name the caller.
    try expectProgram(
        \\local mt = {__add = function(x, y) error("boom", tonumber(y)) end}
        \\local function f(t, q)
        \\  local s = t +
        \\    tostring(q)
        \\  return s
        \\end
        \\local ok, tb = xpcall(f, debug.traceback, setmetatable({}, mt), 1)
        \\print(string.find(tb, "f:3:", 1, true) ~= nil, string.find(tb, "f:4:", 1, true) ~= nil)
        \\local ok2, msg = pcall(f, setmetatable({}, mt), 2)
        \\print(msg)
        \\
    , "true\tfalse\nf:3: boom\n");
}

/// Doc 61 Phase 1 probe. `regs()` collects, then reports every frame's
/// registers by type, outermost first, frames separated by `|`: `t` table,
/// `s` string, `#` number, `f` function, `b` boolean, `.` nil. A register
/// the mask did not keep reads `.` after the scrub. Also installs `unmask`
/// (`util.installUnmask`).
const RegProbe = struct {
    fn regs(ctx: *anyopaque, _: []const Value) anyerror!Value {
        const vm: *interp.Vm = @ptrCast(@alignCast(ctx));
        vm.collect();
        return describe(vm);
    }

    fn describe(vm: *interp.Vm) !Value {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (0..vm.depth) |i| {
            const f = vm.frames[i];
            if (i != 0) {
                buf[len] = '|';
                len += 1;
            }
            for (0..f.closure.proto.num_registers) |r| {
                const v = vm.regGet(f.base + r);
                buf[len] = if (v.isNil()) '.' else switch (v.typeName()[0]) {
                    'n' => '#',
                    else => |c| c,
                };
                len += 1;
            }
        }
        return vm.heap.internValue(buf[0..len]);
    }

    /// `reg(k)`: collect, then return register `k` of the calling frame —
    /// the slab value itself, so a test can compare it with the value
    /// tier-0 holds there.
    fn reg(ctx: *anyopaque, args: []const Value) anyerror!Value {
        const vm: *interp.Vm = @ptrCast(@alignCast(ctx));
        vm.collect();
        const k: usize = @intCast(args[0].asInt());
        return vm.regGet(vm.frames[vm.depth - 1].base + k);
    }

    /// `peek()`: `reg(k)` for the register just above the call's own base,
    /// which a call with no arguments leaves untouched. The calling frame is
    /// in flight, so its `pc` is the `.call` itself.
    fn peek(ctx: *anyopaque, _: []const Value) anyerror!Value {
        const vm: *interp.Vm = @ptrCast(@alignCast(ctx));
        const f = vm.frames[vm.depth - 1];
        std.debug.assert(f.in_flight);
        const call = f.closure.proto.code[f.pc];
        std.debug.assert(call.op == .call);
        return reg(ctx, &.{Value.int(@as(i64, call.a) + 1)});
    }

    fn install(vm: *interp.Vm) !void {
        const native = try vm.heap.newNative(&regs, "regs");
        try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("regs"), Value.heap(&native.header));
        const reg_native = try vm.heap.newNative(&reg, "reg");
        try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("reg"), Value.heap(&reg_native.header));
        const peek_native = try vm.heap.newNative(&peek, "peek");
        try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("peek"), Value.heap(&peek_native.header));
        try util.installUnmask(vm);
    }
};

fn expectRegs(source: [:0]const u8, expected: []const u8) !void {
    return util.expectProgramTuned(source, expected, .{ .setup = &RegProbe.install });
}

test "doc 61 Phase 1: a dead register of the in-flight frame is scrubbed; live ones survive" {
    // At the `.call` of `regs`, `t` (r0) is dead: `#t` was its last read.
    // `n` and `u` are read after the call, and r4 holds the callee. The
    // suspended main chunk keeps `print` below its call; `f` itself is dead.
    try expectRegs(
        \\local function f()
        \\  local t = {}
        \\  local n = #t
        \\  local u = {}
        \\  local s = regs()
        \\  return s, n, #u
        \\end
        \\print(f())
        \\
    , ".f.|.#t.f..\t0\t0\n");
}

test "doc 61 Phase 1: a suspended caller keeps only the registers below its call" {
    // `a1..a3` are dead stale tables in r1..r3 once their block ends; `g`
    // is called at r1, so the suspended `f` keeps r0 alone. `keep` is read
    // after the call.
    try expectRegs(
        \\local function g() return regs() end
        \\local function f()
        \\  local keep = {}
        \\  do local a1, a2, a3 = {}, {}, {} end
        \\  local s = g()
        \\  return s, #keep
        \\end
        \\print(f())
        \\
    , "f.f.|t...|f\t0\n");
}

test "doc 61 Phase 1: a frame in flight at a multret consumer keeps its dynamic span only" {
    // `regs` sits at r1 and `h()` leaves its two results at r2, r3, so the
    // consumer's top is r4. The dead table `a5` left in r4 lies above it:
    // masked to the span it is scrubbed, though the consumer's row covers
    // every register from its base up.
    try expectRegs(
        \\local function h() return {}, {} end
        \\local function f()
        \\  do local a1, a2, a3, a4, a5 = {}, {}, {}, {}, {} end
        \\  local s = regs(h())
        \\  return s
        \\end
        \\print(f())
        \\
    , "f.f.|.ftt.\n");
}

test "doc 61 Phase 1: a frame of a non-maskable proto is kept whole" {
    // The first test's program over a non-maskable `f`: `t` survives every
    // collection, the stress legs' safepoint collections included.
    try expectRegs(
        \\local function f()
        \\  local t = {}
        \\  local n = #t
        \\  local u = {}
        \\  local s = regs()
        \\  return s, n, #u
        \\end
        \\unmask(f)
        \\print(f())
        \\
    , ".f.|t#t.f..\t0\t0\n");
}

/// The traced legs materialised exits at their resume pcs (doc 56): the
/// path site 3's snapshot serves. (The stress legs collect at every
/// safepoint and never get that far.)
const ExitSide = struct {
    fn materialised(vm: *interp.Vm, mode: util.TraceMode) !void {
        if (vm.heap.gc_stress) return;
        switch (mode) {
            .record_execute_noopt, .record_execute => try std.testing.expect(vm.trace.exit_side_hops > 0),
            .record_execute_native => try std.testing.expect(vm.trace.exit_side_native_hops > 0),
            .off, .record_only => {},
        }
    }

    /// Wanted: the exit materialises at its resume pc with no child there.
    fn wanted(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
        try materialised(vm, mode);
    }

    /// Attached: a child trace at the resume pc bound the exit.
    fn attached(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
        try materialised(vm, mode);
        if (!vm.heap.gc_stress and mode != .off and mode != .record_only)
            try std.testing.expect(vm.trace.exit_side_binds > 0);
    }
};

/// Doc 61 §2 site 3 (codex review of Phase 1): `s` (r8) is dead from the
/// `i % 4 == 0` branch on. That exit turns hot, so the traced tiers
/// materialise it at the arm through its exit snapshot, and `reg` collects
/// and reads r8 before tier-0 writes it again. Wanted: the arm's own `reg`
/// call keeps a child from recording there. Attached: `reg` sits in a rarer
/// branch of the arm, so a child records the arm and binds the exit; the
/// child's own exit to `reg` resumes from the slab the parent's
/// materialisation left. `PRE` runs before `f`.
fn hotExitSource(comptime attach: bool, comptime pre: []const u8) [:0]const u8 {
    const arm = if (attach)
        \\      c = c + 1
        \\      if i % 16 == 0 then
        \\        local v = reg(8)
        \\        if v == tostring(i) then same = same + 1 elseif v == nil then nils = nils + 1 end
        \\      end
        \\
    else
        \\      local v = reg(8)
        \\      if v == tostring(i) then same = same + 1 elseif v == nil then nils = nils + 1 end
        \\
        ;
    return
    \\local function f(n)
    \\  local c, same, nils = 0, 0, 0
    \\  for i = 1, n do
    \\    local s = tostring(i)
    \\    c = c + #s
    \\    if i % 4 == 0 then
    \\
    ++ arm ++
        \\    end
        \\  end
        \\  return c, same, nils
        \\end
        \\
    ++ pre ++
        \\print(f(400))
        \\
    ;
}

test "doc 61 §2 site 3: a wanted exit over a maskable proto leaves its dead temporary to the scrub" {
    try util.expectProgramTuned(hotExitSource(false, ""), "1092\t0\t100\n", .{ .setup = &RegProbe.install, .inspect = &ExitSide.wanted });
}

test "doc 61 §2 site 3: a wanted exit over a non-maskable proto materialises its dead temporary" {
    try util.expectProgramTuned(hotExitSource(false, "unmask(f)\n"), "1092\t100\t0\n", .{ .setup = &RegProbe.install, .inspect = &ExitSide.wanted });
}

test "doc 61 §2 site 3: an attached exit over a maskable proto leaves its dead temporary to the scrub" {
    try util.expectProgramTuned(hotExitSource(true, ""), "1192\t0\t25\n", .{ .setup = &RegProbe.install, .inspect = &ExitSide.attached });
}

test "doc 61 §2 site 3: an attached exit over a non-maskable proto materialises its dead temporary" {
    try util.expectProgramTuned(hotExitSource(true, "unmask(f)\n"), "1192\t25\t0\n", .{ .setup = &RegProbe.install, .inspect = &ExitSide.attached });
}

/// Doc 61 §5 site 2 (the dead-φ filter): `s` is dead at the loop header, so
/// over a maskable `f` the loop-close φ set leaves it out and its slab copy
/// stays stale. On every 50th trip `hit` sends tier-0 back to the header
/// with the committed registers (the `if hit` guard fails), and `peek`
/// collects and reads `s`'s register before this trip writes it. The `if`
/// holds its condition in the register `x` takes, the call's base is `y`'s
/// and `s` is the one above it. A maskable `f` has `s` scrubbed in every
/// tier; a non-maskable one keeps the φ, so every tier holds the previous
/// trip's value. `s` is a number, which keeps the trace non-allocating; an
/// allocating one filters the same way (doc 61 §9b). `PRE` runs before `f`.
fn deadPhiProbeSource(comptime pre: []const u8) [:0]const u8 {
    return
    \\local function f(n)
    \\  local c, same, nils, hit = 0, 0, 0, false
    \\  for i = 1, n do
    \\    if hit then
    \\      local v = peek()
    \\      if v == (i - 1) * 3 then same = same + 1 elseif v == nil then nils = nils + 1 end
    \\    end
    \\    local x, y = 0, 0
    \\    local s = i * 3
    \\    c = c + s
    \\    hit = i % 50 == 0
    \\  end
    \\  return c, same, nils
    \\end
    \\
    ++ pre ++
        \\print(f(400))
        \\
    ;
}

test "doc 61 §5 site 2: a φ the dead-φ filter drops over a maskable proto is left to the scrub" {
    try util.expectProgramTuned(deadPhiProbeSource(""), "240600\t0\t7\n", .{ .setup = &RegProbe.install });
}

test "doc 61 §5 site 2: a non-maskable proto keeps every φ" {
    try util.expectProgramTuned(deadPhiProbeSource("unmask(f)\n"), "240600\t7\t0\n", .{ .setup = &RegProbe.install });
}

/// Doc 61 §5 site 5: the inner loop's control variable `i` (r12, `R[a+3]`)
/// holds a string at its last iteration and is dead after the loop, so the
/// linked loop-done flush may skip it. Every eighth outer trip, `reg`
/// collects and reads r12 after the loop; the probe's condition is computed
/// before the loop and the call sits at r9, so nothing after the loop
/// writes r12 first. A maskable `f` has it scrubbed in every tier, a
/// non-maskable one has the final iteration's "30" in every tier. `PRE`
/// runs before `f`.
fn linkedForProbeSource(comptime pre: []const u8) [:0]const u8 {
    return
    \\local function f(n)
    \\  local c, same, nils = 0, 0, 0
    \\  for j = 1, 40 do
    \\    local probe = j % 8 == 0
    \\    for i = 1, n do i = tostring(i) c = c + #i end
    \\    if probe then
    \\      local v = reg(12)
    \\      if v == tostring(n) then same = same + 1 elseif v == nil then nils = nils + 1 end
    \\    end
    \\  end
    \\  return c, same, nils
    \\end
    \\
    ++ pre ++
        \\print(f(30))
        \\
    ;
}

const LinkedFor = struct {
    /// The native leg linked the inner loop's completion, so the flush ran.
    fn linked(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
        if (mode == .record_execute_native and !vm.heap.gc_stress) try std.testing.expect(vm.trace.native_loopdone_link_arms > 0);
    }

    /// A non-maskable proto declines the flush: no completion fuses.
    fn declined(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
        if (mode == .record_execute_native) try std.testing.expectEqual(@as(u64, 0), vm.trace.native_loopdone_link_fused);
    }
};

test "doc 61 §5 site 5: a linked loop-done over a maskable proto leaves R[a+3] to the scrub" {
    try util.expectProgramTuned(linkedForProbeSource(""), "2040\t0\t5\n", .{ .hotloop = (trace.TraceConfig{}).hotloop, .setup = &RegProbe.install, .inspect = &LinkedFor.linked });
}

test "doc 61 §5 site 5: a loop-done over a non-maskable proto declines the flush and keeps R[a+3]" {
    try util.expectProgramTuned(linkedForProbeSource("unmask(f)\n"), "2040\t5\t0\n", .{ .hotloop = (trace.TraceConfig{}).hotloop, .setup = &RegProbe.install, .inspect = &LinkedFor.declined });
}

/// A host `__index` that removes the only reference to itself (its table's
/// metatable) and collects mid-call. Its binding's destroy hook records
/// whether the Native was swept while it was still running.
const SelfDrop = struct {
    var destroyed: bool = false;
    var destroyed_mid_call: bool = false;

    fn call(_: ?*anyopaque, vmp: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
        const vm: *interp.Vm = @ptrCast(@alignCast(vmp));
        table.Table.fromHeader(args[0].asHeap()).metatable = null;
        vm.collect();
        destroyed_mid_call = destroyed;
        if (out.len == 0) return 0;
        out[0] = Value.int(7);
        return 1;
    }

    fn destroy(_: ?*anyopaque) void {
        destroyed = true;
    }

    // Never called: a host Native dispatches through its binding.
    fn call_stub(_: *anyopaque, _: []const Value) anyerror!Value {
        return error.TypeError;
    }
};

test "doc 61 P3: a native callee reached through a metamethod stays rooted while it runs" {
    const gpa = testing.allocator;
    SelfDrop.destroyed = false;
    SelfDrop.destroyed_mid_call = false;
    var vm = try interp.Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    const binding = try gpa.create(function.HostBinding);
    binding.* = .{ .call = &SelfDrop.call, .destroy = &SelfDrop.destroy, .name = try gpa.dupe(u8, "selfdrop") };
    const native = try vm.heap.newNative(&SelfDrop.call_stub, binding.name);
    native.host = binding;
    try vm.globals.set(gpa, try vm.heap.internValue("selfdrop"), Value.heap(&native.header));

    // `make` builds the metatable in its own frame, so no stale register of
    // the main chunk still holds `selfdrop` when `t.x` runs: the metatable is
    // its only reference.
    try util.compileRun(gpa, &vm,
        \\local function make()
        \\  local t = setmetatable({}, {__index = selfdrop})
        \\  selfdrop = nil
        \\  return t
        \\end
        \\local t = make()
        \\print(t.x)
    );
    try testing.expectEqualStrings("7\n", sink.buffered());
    try testing.expect(!SelfDrop.destroyed_mid_call);
}

test "doc 61 P1: a hot vararg call with a surplus span past the window" {
    try expectProgram(
        \\local function sum(...)
        \\  local s = 0
        \\  for i = 1, select('#', ...) do s = s + select(i, ...) end
        \\  return s
        \\end
        \\local t = {}
        \\for i = 1, 20 do t[i] = i end
        \\local acc = 0
        \\for k = 1, 30 do acc = acc + sum(table.unpack(t)) end
        \\print(acc)
        \\
    ,
        "6300\n",
    );
}
