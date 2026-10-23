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

test "nested-loop link: a float for_prep hand-off publishes init exactly" {
    // The link hand-off's entry test and published entry state must be the
    // first index tier-0's `for_prep` publishes: `init` itself (Lua 5.4), not a
    // re-derived value. The inner loop gets hot with a benign float step (1.0),
    // so the continuation records a link with float-typed control guards; the
    // LAST outer iteration re-enters that link with `step = 1e16`, which runs
    // the inner loop once with `j = 1.0`. When `for_prep` pre-subtracted the
    // step, tier-0 computed `(1.0 − 1e16) + 1e16 = 0.0` there and printed
    // 18135 (and a trace that shortcut to `init` disagreed with it). The step
    // comes from an array (not a branch) so no branch guard side-exits before
    // the link is reached.
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
        "18136\n",
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
        \\local function f() error("deep", 5) end
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
        // Lua 5.4: raised at level 1, which is `pcall` here: no location.
        "locked\nfalse\tcannot change a protected metatable\n",
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

test "heap-key fast paths: field reads and stores match the full lookup" {
    // `get_index`/`set_index` probe a heap key inline and walk `__index`
    // chains of plain tables; everything else leaves for `indexGet` /
    // `indexSet`. Each line pins one edge of that split. Doc 66 P2: a
    // literal key (`o.own`) compiles to `get_field`/`set_field`, whose fast
    // lanes are these; `tk[key]` keeps a register key.
    try expectProgram(
        \\local Base = {}; Base.__index = function(_, k) return k .. "!" end
        \\local C = setmetatable({ m = "Cm" }, Base); C.__index = C
        \\local o = setmetatable({ own = 1 }, C)
        \\print(o.own, o.m, o.miss)
        \\local log = {}
        \\local w = setmetatable({ x = 1 }, { __newindex = function(t, k, v) log[#log + 1] = k end })
        \\w.x = 2; w.y = 3
        \\print(w.x, rawget(w, "y"), log[1], #log)
        \\local d = { k = 1 }
        \\d.k = nil
        \\print(d.k, next(d) == nil)
        \\d.k = 5
        \\print(d.k, next(d))
        \\local key = {}
        \\local tk = { [key] = "t" }
        \\tk[key] = "u"
        \\print(tk[key], tk[{}])
        \\local arr = { 10, nil, 30 }
        \\arr[100] = "s"
        \\local ix = setmetatable({ 1 }, { __index = function(_, k) return k * 2 end })
        \\print(arr[1], arr[2], arr[4], arr[100], ix[1], ix[3], ix[0])
        \\
    ,
        "1\tCm\tmiss!\n2\tnil\ty\t1\nnil\ttrue\n5\tk\t5\nu\tnil\n10\tnil\tnil\ts\t1\t6\t0\n",
    );
}

test "doc 66 P2: the constant-key field forms match the register-key access" {
    // Every site the compiler emits `get_field`/`set_field` from — `t.x`,
    // `t["x"]`, stores, compound assignment, constructors, method calls,
    // `function t.f()`/`t:m()` — next to the register-key `t[k]` it
    // replaces, over the fast lanes (present key, in-place store) and the
    // slow halves (`__index` function and chains, `__newindex`, deletion,
    // a string container, and a non-table container's error).
    try expectProgram(
        \\local Base = {}; Base.__index = function(_, k) return k .. "!" end
        \\local C = setmetatable({ m = "Cm" }, Base); C.__index = C
        \\local o = setmetatable({ own = 1 }, C)
        \\local k = "own"
        \\print(o.own, o["own"], o[k], o.m, o.miss, o["miss"])
        \\local log = {}
        \\local w = setmetatable({ x = 1 }, { __newindex = function(t, key, v) log[#log + 1] = key .. "=" .. tostring(v) end })
        \\w.x = 2; w.y = 3; w["z"] = 4
        \\print(w.x, rawget(w, "y"), log[1], log[2], #log)
        \\local d = { k = 1, ["j"] = 2 }
        \\d.k = nil; d["j"] = nil
        \\print(d.k, d.j, next(d) == nil)
        \\d.k = 5; d.k = d.k + 1; d.k += 10; d["k"] += 100
        \\print(d.k)
        \\local obj = { n = 0 }
        \\function obj.inc(self, by) self.n = self.n + by; return self.n end
        \\function obj:dec(by) self.n = self.n - by; return self.n end
        \\print(obj:inc(3), obj.inc(obj, 4), obj:dec(2), select("#", obj:inc(1)))
        \\local ns = { a = { b = {} } }
        \\function ns.a.b.f() return "deep" end
        \\function ns.a.b:g() return self == ns.a.b end
        \\print(ns.a.b.f(), ns.a.b:g(), ns["a"]["b"].f())
        \\local s = "Hello"
        \\print(s:upper(), ("x"):rep(3))
        \\local function idx(t) return t.field end
        \\local function put(t) t.field = 1 end
        \\print(pcall(idx, nil))
        \\print(pcall(put, 7))
        \\print(pcall(function() local n; return n:method() end))
        \\local mixed = { 1, 2, x = "X", ["y"] = "Y", [3] = 3 }
        \\print(mixed[1], mixed[3], mixed.x, mixed.y, #mixed)
        \\local up = setmetatable({}, { __index = { deep = setmetatable({}, { __index = { v = 42 } }) } })
        \\print(up.deep.v, up.deep.nope)
        \\
    ,
        "1\t1\t1\tCm\tmiss!\tmiss!\n" ++
            "2\tnil\ty=3\tz=4\t2\n" ++
            "nil\tnil\ttrue\n" ++
            "116\n" ++
            "3\t7\t5\t1\n" ++
            "deep\ttrue\tdeep\n" ++
            "HELLO\txxx\n" ++
            "false\tidx:25: attempt to index a nil value\n" ++
            "false\tput:26: attempt to index a number value\n" ++
            "false\tanonymous:29: attempt to index a nil value\n" ++
            "1\t3\tX\tY\t3\n" ++
            "42\tnil\n",
    );
}

test "doc 66 P3: every constant arithmetic form is its register form" {
    // Each operator with a literal on either side (`x + (2)`, `(2) + x`)
    // against the same operator with the constant in a register, over an
    // operand matrix: ints at the edges, floats, -0.0, NaN, inf, a table with
    // every metamethod (which sees the operands in source order), a string, a
    // boolean and nil. The result's type and value, or the error message
    // without its location, must match. The compiler emits a constant form
    // wherever one exists (the compiler test pins which).
    //
    // The two sides share the handlers' number lanes (mixed int/float, pow,
    // shifts, mod/idiv on floats), so the digest of every result pins those
    // lanes as well: it was taken on e4ba1e2, before them, where every case
    // ran through `arith`.
    try expectProgram(
        \\local M = {}
        \\for _, op in ipairs({ "add", "sub", "mul", "div", "mod", "idiv", "pow", "band", "bor", "bxor", "shl", "shr" }) do
        \\  M["__" .. op] = function(a, b)
        \\    return (type(a) == "table" and "T" or type(a)) .. op .. (type(b) == "table" and "T" or type(b))
        \\  end
        \\end
        \\local X = { 7, -7, 0, math.mininteger, math.maxinteger, 2.5, -0.0, 0 / 0, 1 / 0, setmetatable({}, M), "7", true }
        \\local function render(ok, v)
        \\  if not ok then return "E:" .. string.gsub(tostring(v), "^[^:]*:%d+: ", "") end
        \\  if math.type(v) == "float" then return "f:" .. string.format("%.17g", v) end
        \\  return (math.type(v) or type(v)) .. ":" .. tostring(v)
        \\end
        \\local bad, checks, h = 0, 0, 0
        \\local function check(kexpr, rexpr, k)
        \\  local kf = load("return function(x) return " .. kexpr .. " end")()
        \\  local rf = load("return function(x, k) return " .. rexpr .. " end")()
        \\  for i = 1, 13 do
        \\    local got = render(pcall(kf, X[i]))
        \\    if got ~= render(pcall(rf, X[i], k)) then bad = bad + 1 end
        \\    for j = 1, #got do h = h * 31 + string.codepoint(got, j) end
        \\    checks = checks + 1
        \\  end
        \\end
        \\local K = { "2", "-3", "0", "-1", "0.5", "-0.0", "1e308", "9223372036854775807" }
        \\for _, op in ipairs({ "+", "-", "*", "/", "%", "//", "^", "&", "|", "~", "<<", ">>" }) do
        \\  for _, k in ipairs(K) do
        \\    local kv = load("return " .. k)()
        \\    check("x " .. op .. " (" .. k .. ")", "x " .. op .. " k", kv)
        \\    check("(" .. k .. ") " .. op .. " x", "k " .. op .. " x", kv)
        \\  end
        \\end
        \\print(bad, checks, h)
        \\
    , "0\t2496\t-2335769007170761397\n");
}

test "doc 66 P5: equality against a constant is `Value.eql` against it" {
    // Every value class against nil, the booleans, strings (one built at run
    // time, so equal by interning) and numbers (`1 == 1.0`, `-0.0 == 0.0`,
    // NaN, 2^53 against its float and the int past it), the constant on
    // either side; a table with `__eq` is still unequal to a constant. Then
    // the same compares as loop conditions, hot enough to record. The digest
    // was taken on e4ba1e2, where every one of these was a register `eq`.
    const Inspect = struct {
        fn run(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
            if (mode == .off) return;
            for (vm.trace.abort_log.items) |r| try testing.expect(bytecode.eqFormOf(r.op) == null);
            try testing.expect(vm.trace.registry.cache.items.len > 0);
        }
    };
    try util.expectProgramTuned(
        \\local t = setmetatable({}, { __eq = function() return true end })
        \\local X = { false, true, 0, 1, -1, 1.0, 0.0, -0.0, 0 / 0, 1 / 0, 2 ^ 53, 9007199254740993, "a", "", "abc", "a" .. "bc", t, {}, print }
        \\local acc, n = 0, 0
        \\local function mix(b) n = n + 1; acc = acc * 3 + (b and 1 or 2) end
        \\for i = 1, 20 do
        \\  local x = X[i]
        \\  mix(x == nil) mix(x ~= nil) mix(nil == x) mix(x == false) mix(x ~= false) mix(true == x) mix(x == true) mix(x ~= true)
        \\  mix(x == "abc") mix(x ~= "abc") mix("abc" == x) mix(x == "") mix(x == "a")
        \\  mix(x == 0) mix(x ~= 0) mix(0 == x) mix(x == 1) mix(x == 1.0) mix(1.0 == x) mix(x == -0.0) mix(x == 0.0) mix(x ~= 1)
        \\  mix(x == 9007199254740992) mix(x == 9007199254740993) mix(x == 2 ^ 53) mix((x) == (nil)) mix(x == ("abc")) mix(-1 == x)
        \\  local c = 0
        \\  for j = 1, 300 do
        \\    if x == nil then c = c + 1 end
        \\    if x ~= false then c = c + 2 end
        \\    if x == "abc" then c = c + 4 end
        \\    if x ~= 0 then c = c + 8 end
        \\    if x == 1.0 then c = c + 16 end
        \\  end
        \\  acc = acc * 7 + c
        \\end
        \\print(n, acc)
        \\
    , "560\t-8917125095649679768\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 66 P4: a compare-and-branch is its compare followed by the branch" {
    // Every relation as an `if` test in both polarities (`not`, `~=`) over
    // every value class: ints, floats, the int/float boundary (2^53 against
    // the int past it), -0.0, NaN, strings (one built at run time, equal by
    // interning), tables with and without `__lt`/`__le`/`__eq`, booleans and
    // nil; against registers and against constants on either side. Then a
    // `repeat` whose condition reads a captured body local, and hot
    // conditions that record and run natively. The digest was taken on
    // 8eee20c, where every one of these was a compare into a register and a
    // `jmp_if_false`.
    const Inspect = struct {
        fn run(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
            if (mode == .off) return;
            for (vm.trace.abort_log.items) |r| {
                if (bytecode.cmpBranchOf(r.op) != null) try testing.expect(r.reason != .nyi_opcode);
            }
            try testing.expect(vm.trace.registry.cache.items.len > 0);
        }
    };
    try util.expectProgramTuned(
        \\local V = {}
        \\V.__lt = function(a, b) return a.v < b.v end
        \\V.__le = function(a, b) return a.v <= b.v end
        \\V.__eq = function(a, b) return a.v == b.v end
        \\local p, q, r = setmetatable({ v = 1 }, V), setmetatable({ v = 2 }, V), setmetatable({ v = 1 }, V)
        \\local nan = 0 / 0
        \\local X = { false, true, 0, 1, -1, 2, 1.0, 0.5, -0.0, 0.0, nan, 1 / 0, 2 ^ 53, 9007199254740993, "a", "b", "", "a" .. "", p, q, r, {} }
        \\X.n = #X + 1 -- and X[X.n] is nil
        \\local acc, n = 0, 0
        \\local function mix(b) n = n + 1; acc = (acc * 3 + (b and 1 or 2)) % 1000000007 end
        \\local function ordered(x, y)
        \\  local tx, ty = type(x), type(y)
        \\  if tx ~= ty then return false end
        \\  return tx == "number" or tx == "string" or (tx == "table" and getmetatable(x) == V and getmetatable(y) == V)
        \\end
        \\for i = 1, X.n do
        \\  local x = X[i]
        \\  if x == nil then mix(true) else mix(false) end
        \\  if x ~= nil then mix(true) else mix(false) end
        \\  if not (nil == x) then mix(true) else mix(false) end
        \\  if x == false then mix(true) else mix(false) end
        \\  if x ~= true then mix(true) else mix(false) end
        \\  if x == "a" then mix(true) else mix(false) end
        \\  if not ("b" ~= x) then mix(true) else mix(false) end
        \\  if x == 1 then mix(true) else mix(false) end
        \\  if 1.0 == x then mix(true) else mix(false) end
        \\  if x == -0.0 then mix(true) else mix(false) end
        \\  if x ~= 9007199254740992 then mix(true) else mix(false) end
        \\  if type(x) == "number" then
        \\    if x < 1 then mix(true) else mix(false) end
        \\    if 1 < x then mix(true) else mix(false) end
        \\    if x >= 0.5 then mix(true) else mix(false) end
        \\    if 2 ^ 53 <= x then mix(true) else mix(false) end
        \\    if x > -1 then mix(true) else mix(false) end
        \\    if not (x < 0) then mix(true) else mix(false) end
        \\    if not (0.0 >= x) then mix(true) else mix(false) end
        \\    if x <= 9007199254740992 then mix(true) else mix(false) end
        \\    if 0.5 <= x then mix(true) else mix(false) end
        \\    if -1 >= x then mix(true) else mix(false) end
        \\    if 2 > x then mix(true) else mix(false) end
        \\    if not (-0.0 < x) then mix(true) else mix(false) end
        \\  end
        \\  for j = 1, X.n do
        \\    local y = X[j]
        \\    if x == y then mix(true) else mix(false) end
        \\    if x ~= y then mix(true) else mix(false) end
        \\    if not (x == y) then mix(true) else mix(false) end
        \\    if ordered(x, y) then
        \\      if x < y then mix(true) else mix(false) end
        \\      if not (x <= y) then mix(true) else mix(false) end
        \\      if x > y then mix(true) else mix(false) end
        \\      if (x >= y) then mix(true) else mix(false) end
        \\    end
        \\  end
        \\end
        \\print(n, acc)
        \\-- repeat: the condition sees the body's locals, and each iteration's
        \\-- captured local is its own
        \\local fs, k = {}, 0
        \\repeat
        \\  local j = k
        \\  fs[#fs + 1] = function() return j end
        \\  k = k + 1
        \\until j >= 5
        \\local out = {}
        \\for i = 1, #fs do out[i] = fs[i]() end
        \\print(table.concat(out, " "))
        \\k = 0
        \\repeat local j = k; k = k + 1 until not (j < 3)
        \\print(k)
        \\-- hot conditions, recorded and run natively
        \\local c = 0
        \\for i = 1, X.n do
        \\  local x = X[i]
        \\  if type(x) == "number" then
        \\    for j = 1, 300 do
        \\      local y = j % 7 - 3
        \\      if x < y then c = c + 1 end
        \\      if not (x >= y) then c = c + 2 end
        \\      if x <= 1 then c = c + 4 end
        \\      if 0.5 < x then c = c + 8 end
        \\      if x == y then c = c + 16 end
        \\      if y ~= 2 then c = c + 32 end
        \\      if y + 0.5 > x then c = c + 64 end
        \\    end
        \\    c = c % 1000000007
        \\  end
        \\end
        \\local w, z = 0, 0.0
        \\while w < 3000 do w = w + 3 end
        \\while not (z >= 1000.5) do z = z + 1.5 end
        \\local u = 0
        \\repeat u = u + 2 until u > 4000
        \\print(c, w, z, u)
        \\
    , "2660\t738004662\n0 1 2 3 4 5\n4\n206669\t3000\t1000.5\t4002\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "doc 66 P4: a compare-and-branch fault names its operands in source order" {
    // `1 < t` compiles to `t > 1` against a constant; the message still reads
    // "number with table", and each points at its own line.
    try expectProgram(
        \\local function err(f) local ok, e = pcall(f); print(ok, e:match(":(%d+): attempt to compare (.*)")) end
        \\local t, s = {}, "s"
        \\err(function() if t < 1 then end end)
        \\err(function() if 1 < t then end end)
        \\err(function() if t >= 2.5 then end end)
        \\err(function() if 2.5 > t then end end)
        \\err(function() if t <= s then end end)
        \\err(function() if s > t then end end)
        \\err(function() if not (1 < s) then end end)
        \\err(function() while t < 1 do end end)
        \\err(function() repeat until 1 <= t end)
        \\
    ,
        "false\t3\ttable with number\nfalse\t4\tnumber with table\nfalse\t5\ttable with number\n" ++
            "false\t6\tnumber with table\nfalse\t7\ttable with string\nfalse\t8\tstring with table\n" ++
            "false\t9\tnumber with string\nfalse\t10\ttable with number\nfalse\t11\tnumber with table\n",
    );
}

test "doc 66: an `and`/`or`/`not` test runs its links in order, each once" {
    // A chain of branches must evaluate exactly the operands the value
    // form did, in its order: a link skipped by a short circuit runs no
    // call, no metamethod and no fault. The outputs were taken on 8b98d64,
    // before the chains.
    try expectProgram(
        \\local log = ""
        \\local function v(name, x) log = log .. name return x end
        \\local function r(c) local s = (c and "T" or "F") .. log .. " " log = "" return s end
        \\local o = ""
        \\if v("a", 1) < v("b", 2) and v("c", 3) > v("d", 4) then o = o .. r(true) else o = o .. r(false) end
        \\if v("a", nil) or v("b", false) then o = o .. r(true) else o = o .. r(false) end
        \\if not (v("a", 1) == v("b", 1) or v("c", 0)) then o = o .. r(true) else o = o .. r(false) end
        \\if v("a", false) and v("b", error("never")) then end log = ""
        \\if v("a", 0) and v("b", "") and not v("c", nil) then o = o .. r(true) else o = o .. r(false) end
        \\if (v("a", 1) > 2 or v("b", 2) > 1) and (v("c", nil) or v("d", 5) == 5) then o = o .. r(true) else o = o .. r(false) end
        \\local mt = { __lt = function(a, b) log = log .. "<" return a.v < b.v end, __eq = function(a, b) log = log .. "=" return a.v == b.v end }
        \\local A, B = setmetatable({ v = 1 }, mt), setmetatable({ v = 2 }, mt)
        \\if A < B and not (A == B) then o = o .. r(true) else o = o .. r(false) end
        \\if B < A or A == B then o = o .. r(true) else o = o .. r(false) end
        \\print(o)
        \\local function cls(x) if x < 0 and x > -10 then return "s" elseif x >= 10 or x ~= x then return "b" elseif not (x == 0) then return "p" else return "z" end end
        \\print(cls(-5), cls(-50), cls(0/0), cls(10), cls(3), cls(0))
        \\print(pcall(function() local x if x or 1 < "a" then end end))
        \\
    ,
        "Fabcd Fab Fab Tabc Tabcd T<= F<= \n" ++
            "s\tp\tb\tb\tp\tz\n" ++
            "false\tanonymous:18: attempt to compare number with string\n",
    );
}

test "doc 66: loops leave through any link of their test" {
    // `while` chains exiting through their first link and their last, a
    // `not` folded into the links, an `or` link landing on the marker, the
    // value-tested fallback, and a `repeat` chain, each hot enough to trace.
    try expectProgram(
        \\local s, i = 0, 0
        \\while i < 300 and s >= 0 do i = i + 1 if i % 3 == 0 or i % 5 == 0 then s = s + i end end
        \\local j, k = 0, 0
        \\while j < 200 or k < 100 do j = j + 1 if not (j % 2 == 0) and j > 50 then k = k + 1 end end
        \\local found = 0
        \\for r = 1, 200 do
        \\  local t = { 5, 6, 7, r % 4 }
        \\  local p = 1
        \\  while p <= #t and t[p] ~= 7 + (r % 2) do p = p + 1 end
        \\  found = found + p
        \\end
        \\local q, f = 0, false
        \\while not f and not (q >= 250) do q = q + 1 f = q % 97 == 0 end
        \\local u = 0
        \\repeat u = u + 1 until u >= 10 and u % 7 == 0
        \\local w, x = 0, true
        \\while not (w >= 300 and x) do w = w + 1 end
        \\print(s, i, j, k, found, q, u, w)
        \\
    ,
        "21150\t300\t249\t100\t800\t97\t14\t300\n",
    );
}

test "doc 66: a `repeat` test runs each link once, in order, with Lua's values" {
    // `and`/`or`/`not` links logging their order; a captured body local and
    // a closure in the test (both keep the value form); `break`; a body
    // local holding a table in the test; a hot chain; an error from the
    // last link. Checked against LuaJIT.
    try expectProgram(
        \\local log = {}
        \\local function p(tag, v) log[#log + 1] = tag return v end
        \\local i = 0
        \\repeat i = i + 1 until p("a", i >= 2) and p("b", i % 3 == 0)
        \\print(i, table.concat(log))
        \\log = {}
        \\local j = 0
        \\repeat j = j + 1 until p("c", j > 5) or not p("d", j < 3)
        \\print(j, table.concat(log))
        \\local fs, k = {}, 0
        \\repeat local v = k fs[#fs + 1] = function() return v end k = k + 1 until k >= 2 and fs[1]
        \\print(k, fs[1](), fs[2]())
        \\local m = 0
        \\repeat local w = m * 2 m = m + 1 until (function() return w end)() >= 4 and m > 1
        \\print(m)
        \\local q = 0
        \\repeat q = q + 1 if q == 4 then break end until q > 10 and q < 0
        \\print(q)
        \\local r = 0
        \\repeat r = r + 1 local t = r > 2 and { done = true } or nil until t and t.done
        \\print(r)
        \\local h, acc = 0, 0
        \\repeat h = h + 1 acc = acc + (h % 3) until h >= 300 and acc > 0
        \\print(h, acc)
        \\print(pcall(function() local z = 0 repeat z = z + 1 until z > 1 and z < "x" end))
        \\
    ,
        "3\taabab\n3\tcdcdcd\n2\t0\t1\n3\n4\n3\n300\t300\n" ++
            "false\tanonymous:25: attempt to compare number with string\n",
    );
}

test "doc 66: a `repeat` root records through a link that falls to the next" {
    // `n > 3` holds on almost every iteration while `n >= 2000` fails, so
    // the first link falls through to the second, which loops back. Only
    // the closer's fall-through leaves the loop: a recording that took the
    // first link's fall-through for the loop's exit would abort LLEAVE on
    // every iteration and never commit. The `or` loop leaves through its
    // first link's jump.
    const Inspect = struct {
        fn run(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
            if (mode == .off) return;
            for (vm.trace.abort_log.items) |r| try testing.expect(r.reason != .loop_leave);
            var repeat_roots: usize = 0;
            for (vm.trace.registry.cache.items) |t| {
                const pc = t.code.anchor.pc;
                const code = t.code.anchor.proto.code;
                if (pc == 0 or pc >= code.len or code[pc - 1].op != .loop) continue;
                if (code[pc - 1].b != @intFromEnum(bytecode.LoopKind.repeat_loop)) continue;
                repeat_roots += 1;
                // The own test is a leaving link, never the first `and` link.
                for (t.code.instrs, 0..) |_, idx| {
                    if (!t.code.isOwnLoopTest(idx)) continue;
                    const src = t.code.anchorSourcePc(idx).?;
                    try testing.expectEqual(@as(?usize, pc - 1), bytecode.repeatTestMarkerOf(code, src));
                }
            }
            try testing.expectEqual(@as(usize, 2), repeat_roots);
        }
    };
    try util.expectProgramTuned(
        \\local n, c = 0, 0
        \\repeat n = n + 1 if n % 2 == 0 then c = c + 1 end until n > 3 and n >= 2000
        \\local m, d = 0, 0
        \\repeat m = m + 1 d = d + m % 3 until m >= 2000 or d < 0
        \\print(n, c, m, d)
        \\
    , "2000\t1000\t2000\t2001\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "open upvalues: captures out of slot order, shared cells, block and frame closes" {
    // The open-upvalue list is slot-ordered (`Vm.appendOpenUpvalue`), so a
    // close pops its suffix. This pins what that must preserve: captures
    // made in descending slot order, a cell shared by closures made at
    // different times, a block exit closing only its own local under a
    // still-open frame, one cell per recursion level, closed in turn as
    // each level returns (after it last wrote the local), a fresh cell per
    // loop iteration, and a nested function's cell next to its caller's.
    // The output was taken on d21a333, before the list was ordered.
    try expectProgram(
        \\local function mk()
        \\  local a, b, c = 1, 2, 3
        \\  local fc = function() c = c + 10; return c end
        \\  local fa = function() a = a + 1; return a end
        \\  local fb
        \\  do
        \\    local d = 100
        \\    fb = function() d = d + b; return d end
        \\  end
        \\  local fc2 = function() return c end
        \\  b = 5
        \\  return fa, fb, fc, fc2
        \\end
        \\local fa, fb, fc, fc2 = mk()
        \\print(fa(), fb(), fc(), fc2(), fa(), fb())
        \\local function rec(n, acc)
        \\  if n == 0 then return acc end
        \\  local v = n
        \\  acc[#acc + 1] = function() v = v * 2; return v end
        \\  local r = rec(n - 1, acc)
        \\  v = v + 1000
        \\  return r
        \\end
        \\local fs = rec(5, {})
        \\local out = {}
        \\for i = 1, #fs do out[i] = fs[i]() end
        \\print(table.concat(out, " "))
        \\local gs = {}
        \\for i = 1, 4 do local j = i * i; gs[i] = function() j = j + 1; return j end end
        \\print(gs[1](), gs[4](), gs[1]())
        \\local function outer()
        \\  local x = 0
        \\  local function inc() x = x + 1 end
        \\  for _ = 1, 3 do
        \\    local y = x
        \\    local function both() x = x + y; return x end
        \\    inc(); both()
        \\  end
        \\  return x
        \\end
        \\print(outer(), outer())
        \\
    , "2\t105\t13\t13\t3\t110\n2010 2008 2006 2004 2002\n2\t17\t3\n7\t7\n");
}

test "doc 66 P1: `itern` steps a table exactly as the `next` native does" {
    // The array part (holes, key 0), the hash part, both and neither; a
    // second traversal reusing the hash view, and one after an insertion
    // dropped it; one to five loop variables; deleting the current key and
    // overwriting another mid-traversal; inserting mid-traversal; `next`
    // with an integer, a float-spelled and a hash-key control; a grid
    // (deflated by the fallback's real `next`); nested traversals of one
    // table; a long mixed traversal allocating per step. The output was
    // taken on 98aef7f, where every step was the `move`s and a `call next`.
    try expectProgram(
        \\local function keys(t)
        \\  local out = {}
        \\  for k, v in pairs(t) do out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
        \\  return table.concat(out, " ")
        \\end
        \\local z = { 1, nil, 3, nil, nil, 6 }; z[0] = "z"
        \\print(keys(z), keys({}))
        \\print(keys({ x = 1, [true] = "t", [2.5] = "f", 10, [100] = "far" }))
        \\local h = { a = 1, b = 2 }
        \\print(keys(h), keys(h))
        \\h.c = 3
        \\print(keys(h))
        \\for k in pairs({ 7 }) do io.write(k, " ") end
        \\for a, b, c, d, e in pairs({ 7, x = 8 }) do io.write(a, b, tostring(c), tostring(e), " ") end
        \\print()
        \\local d = { a = 1, b = 2, c = 3, 5, 6 }
        \\local seen = 0
        \\for k in pairs(d) do seen = seen + 1; d[k] = nil; if d.c then d.c = "c" end end
        \\local g, log = { a = 1 }, {}
        \\for k in pairs(g) do log[#log + 1] = k; if k == "a" then g.z = 26; g.b = 2 end end
        \\print(seen, next(d), table.concat(log))
        \\for k, v in next, { 1, 2, 3 }, 1 do io.write(k, v, " ") end
        \\for k, v in next, { 1, 2, 3 }, 2.0 do io.write(k, v, " ") end
        \\local m = { 1, p = "P", q = "Q" }
        \\for k, v in next, m, next(m, 1) do io.write(k, v, " ") end
        \\local grid = { { 1, 2 }, { 3, 4 } }
        \\grid[1][1] = 10
        \\local rows = 0
        \\for _, row in pairs(grid) do rows = rows + row[1] end
        \\local nest, n2 = { a = 1, b = 2 }, 0
        \\for _ in pairs(nest) do for _ in pairs(nest) do n2 = n2 + 1 end end
        \\print(rows, n2)
        \\local big = {}
        \\for i = 1, 300 do big["k" .. i] = i; big[i] = -i end
        \\local s1, s2 = 0, 0
        \\for k, v in pairs(big) do
        \\  if type(k) == "string" then s1 = s1 + v else s2 = s2 + v end
        \\  local garbage = { k, v }
        \\end
        \\print(s1, s2)
        \\
    ,
        "0=z 1=1 3=3 6=6\t\n" ++
            "1=10 true=t 100=far 2.5=f x=1\n" ++
            "a=1 b=2\ta=1 b=2\n" ++
            "a=1 b=2 c=3\n" ++
            "1 17nilnil x8nilnil \n" ++
            "5\tnil\tab\n" ++
            "22 33 33 qQ 13\t4\n" ++
            "45150\t-45150\n",
    );
}

test "doc 66 P1: `itern` steps a host's `row_view` as `next` does" {
    // A grid row reaches a program only from a host: `Table.getInt` mints
    // a `row_view`, but source-level indexing and `ipairs` deflate the grid
    // first. `rowof` stands in for that host. `opIternSlow` steps the row
    // through `stdbase.iternStep`. The output was taken on 98aef7f, whose
    // GC-stress legs crashed here: the register root walk skipped a
    // `row_view`, so `rowof(g, 1)`'s grid, dead after the call, was swept
    // under the loop stepping its row (`forEachKeptRegister`).
    const Host = struct {
        fn rowOf(_: *anyopaque, args: []const Value) anyerror!Value {
            const t = table.Table.fromHeader(args[0].asHeap());
            if (!t.array.isGrid()) return Value.nil();
            return t.getInt(args[1].asInt());
        }
        fn install(vm: *interp.Vm) anyerror!void {
            const native = try vm.heap.newNative(&rowOf, "rowof");
            try vm.globals.set(vm.heap.gpa, try vm.heap.internValue("rowof"), Value.heap(&native.header));
        }
    };
    try util.expectProgramTuned(
        \\local g = { { 1, 2, 3 }, { 4, 5, 6 } }
        \\local i, j = 2, 2
        \\g[i][j] = 50
        \\local r = rowof(g, 2)
        \\local out = {}
        \\for k, v in pairs(r) do out[#out + 1] = k .. "=" .. v end
        \\for k, v, x in next, r, 1 do out[#out + 1] = k .. v .. tostring(x) end
        \\for k in next, r, 3 do out[#out + 1] = "after3" end
        \\for k in pairs(rowof(g, 1)) do out[#out + 1] = k end
        \\print(r ~= nil, table.concat(out, " "))
        \\local h, a = { { 7, 8 } }, 1
        \\h[a][a] = 70
        \\local hr = rowof(h, 1)
        \\h = nil
        \\local junk = { {}, {} }
        \\print(next(hr, 1))
        \\
    , "true\t1=4 2=50 3=6 250nil 36nil 1 2 3\n2\t8\n", .{ .setup = Host.install });
}

test "doc 66 P1: any other iterator is the call `itern` replaced" {
    // `ipairs`, `gmatch`, a closure, a `__call` table, a local shadowing
    // `next`, `next` over a table with `__index` (raw, as before), and the
    // faults: each message and line as the `call` gave them (98aef7f).
    try expectProgram(
        \\for i, v in ipairs({ "a", "b", nil, "d" }) do io.write(i, v, " ") end
        \\for w, n in string.gmatch("a1 b22", "(%a)(%d+)") do io.write(w, n, " ") end
        \\local function range(s, c) if c < s then return c + 1 end end
        \\for i in range, 3, 0 do io.write(i, " ") end
        \\local callable = setmetatable({}, { __call = function(_, s, c) if c < s then return c + 1, "c" end end })
        \\for i, v in callable, 2, 0 do io.write(i, v, " ") end
        \\print()
        \\do
        \\  local next = function(t, k) if k == nil then return "only", t end end
        \\  for k, v in next, {} do io.write(k, type(v), " ") end
        \\end
        \\local count = 0
        \\for _ in next, setmetatable({ 1, 2 }, { __index = function() return "x" end }) do count = count + 1 end
        \\print(count)
        \\local function err(f) print(select(2, pcall(f))) end
        \\err(function() for k in next, 5 do end end)
        \\err(function() for k in nil do end end)
        \\err(function() for k in 42, 1 do end end)
        \\print(pcall(function() for k in next, {}, "absent" do end end))
        \\
    ,
        "1a 2b a1 b22 1 2 3 1c 2c \n" ++
            "onlytable 2\n" ++
            "anonymous:16: bad argument #1 to 'next' (table expected, got number)\n" ++
            "anonymous:17: attempt to call a nil value\n" ++
            "anonymous:18: attempt to call a number value\n" ++
            "true\n",
    );
}

test "doc 66: `itern` steps `ipairs` exactly as its native does" {
    // The `inext` lane: holes, a hash-only array, a `[0]` key, an array
    // grown and shrunk mid-walk, a float, string or maxinteger control (all
    // three the native's call; maxinteger wraps to `t[mininteger]`, as Lua's
    // `ipairs` does), more loop variables than it returns, nested walks, and
    // the faults with the native's message (as before the lane).
    try expectProgram(
        \\local function walk(t)
        \\  local out = {}
        \\  for i, v in ipairs(t) do out[#out + 1] = i .. "=" .. tostring(v) end
        \\  return table.concat(out, " ")
        \\end
        \\local h = {}; h[1] = "a"; h[2] = "b"; h[4] = "d"
        \\print(walk({ 1, 2, 3, nil, 5 }), walk({}), walk(h), walk({ [0] = 0, 1 }))
        \\local grow, n = { 1 }, 0
        \\for i, v in ipairs(grow) do n = n + v; if i < 5 then grow[i + 1] = i + 1 end end
        \\local shrink, m = { 1, 2, 3, 4 }, 0
        \\for i in ipairs(shrink) do m = m + i; shrink[3] = nil end
        \\print(n, m)
        \\local f, s = ipairs({ 10, 20, 30 })
        \\for i, v in f, s, 1 do io.write(i, v, " ") end
        \\for i, v in f, s, 1.0 do io.write(i, v, " ") end
        \\for i, v in f, s, "x" do io.write(i, v, " ") end
        \\for i, v in f, { 1, [math.mininteger] = "w" }, math.maxinteger do io.write(i, v, " ") end
        \\for i in ipairs({ 7, 8 }) do io.write(i, " ") end
        \\for i, v, w in ipairs({ 7 }) do io.write(i, v, tostring(w), " ") end
        \\print()
        \\local g = 0
        \\for _, row in ipairs({ { 10, 2 }, { 3, 4 } }) do for _, x in ipairs(row) do g = g + x end end
        \\print(g)
        \\
    ,
        "1=1 2=2 3=3\t\t1=a 2=b\t1=1\n" ++
            "15\t3\n" ++
            "220 330 110 220 330 110 220 330 -9223372036854775808w 1 2 17nil \n" ++
            "19\n",
    );
    try expectProgram(
        \\local f = ipairs({})
        \\print(pcall(function() for i, v in f, 5, 0 do end end))
        \\print(pcall(function() for i, v in f, "ab", 0 do end end))
        \\
    ,
        "false\tanonymous:2: bad argument #1 to '@ipairs_iter' (table expected, got number)\n" ++
            "false\tanonymous:3: bad argument #1 to '@ipairs_iter' (table expected, got string)\n",
    );
}

test "doc 66 P1: one generic `for` traced with `gmatch` keeps its trace across `pairs`" {
    // One compiled loop driven by `gmatch`, then by `pairs` and `next`,
    // then by `gmatch` with another pattern and the first one again. The
    // `gmatch` step records (the fallback is the `call` it replaced, and its
    // builtin guard pins the callee), so a `next` in the same slot exits; a
    // `next` step aborts its own recording as `.itern_next`, never as an
    // unknown opcode.
    const Inspect = struct {
        fn run(vm: *interp.Vm, mode: util.TraceMode) anyerror!void {
            if (mode == .off) return;
            for (vm.trace.abort_log.items) |r| {
                if (r.op == .itern) try testing.expectEqual(trace.AbortReason.itern_next, r.reason);
            }
            // The GC-stress leg too: the ctrl pin reads the register where
            // `itern` reads it, before a collection can scrub it as dead.
            if (mode != .record_execute_native) return;
            var compiled = false;
            for (vm.trace.registry.cache.items) |t| {
                if (!std.mem.eql(u8, t.code.anchor.proto.name, "walk")) continue;
                if (t.native == .compiled) compiled = true;
            }
            try testing.expect(compiled);
        }
    };
    try util.expectProgramTuned(
        \\local function walk(f, s, c)
        \\  local n, acc = 0, 0
        \\  for k, v in f, s, c do
        \\    n = n + 1
        \\    acc = acc + #k
        \\  end
        \\  return n, acc
        \\end
        \\local text = string.rep("ab cde ", 150)
        \\local t = { alpha = 1, beta = 2, gamma = 3, delta = 4, eps = 5, zeta = 6, eta = 7, theta = 8, iota = 9, kappa = 10 }
        \\print(walk(string.gmatch(text, "%a+")))
        \\print(walk(pairs(t)))
        \\print(walk(next, t))
        \\print(walk(string.gmatch(text, "(%a)%a*")))
        \\print(walk(string.gmatch(text, "%a+")))
        \\
    , "300\t750\n10\t43\n10\t43\n300\t300\n300\t750\n", .{ .record_aborts = true, .inspect = Inspect.run });
}

test "float text: print, tostring and .. agree, exponent form at the extremes" {
    // One renderer (`io.formatFloat`) behind all three. Positional text at
    // the extremes ran to 330 bytes and overran the fixed buffers `tostring`
    // and `..` render into (a panic in Debug, UB in release); a loop over the
    // conversions keeps the traced legs on the same renderer.
    try expectProgram(
        \\local xs = { 1e308 / 3, 5e-324, 1e21, 1e20, 1e-7, 1e-8, -1e300 / 7, 0.1, 2 ^ 63 }
        \\local out = {}
        \\for i = 1, #xs do
        \\  local x = xs[i]
        \\  local t = tostring(x)
        \\  out[i] = (t == x .. "" and t == string.format("%s", x)) and t or "MISMATCH"
        \\end
        \\print(table.concat(out, " "))
        \\print(1e308 / 3, -5e-324)
        \\
    ,
        "3.333333333333333e+307 5e-324 1e+21 100000000000000000000 0.0000001 1e-8 -1.4285714285714286e+299 0.1 9223372036854776000\n" ++
            "3.333333333333333e+307\t-5e-324\n",
    );
}

test "compare fast paths: every operand mix matches the full op" {
    // `lt`/`le`/`gt`/`ge` decide two ints or two floats on the raw lanes; a
    // mixed pair, strings and `__lt`/`__le` leave for the full op. Each line
    // pins one edge of that split.
    try expectProgram(
        \\local nan, big = 0 / 0, 2 ^ 53
        \\print(1 < 2, 2 <= 2, 3 > 2, 2 >= 3, -0.0 < 0.0, -0.0 <= 0.0, nan < 1.0, nan >= nan)
        \\print(9007199254740993 > big, big < 9007199254740993, 1 <= 1.0, 2.5 > 2, "a" < "b", "b" <= "a")
        \\print(2 < 2, 2 > 2, 2 >= 2, 1 > 2, 2.5 < 2.5, 2.5 > 2.5, 2.5 >= 2.5, 1.5 >= 2.5, nan > nan, -0.0 >= 0.0)
        \\local V = {}; V.__lt = function(a, b) return a.v < b.v end; V.__le = function(a, b) return a.v <= b.v end
        \\local x, y = setmetatable({ v = 1 }, V), setmetatable({ v = 2 }, V)
        \\print(x < y, x > y, x <= y, y >= x, (pcall(function() return 1 < "x" end)))
        \\
    ,
        "true\ttrue\ttrue\tfalse\tfalse\ttrue\tfalse\tfalse\n" ++
            "true\ttrue\ttrue\ttrue\ttrue\tfalse\n" ++
            "false\tfalse\ttrue\tfalse\tfalse\tfalse\ttrue\tfalse\tfalse\ttrue\n" ++
            "true\tfalse\ttrue\ttrue\tfalse\n",
    );
}

test "eq fast paths: every operand mix matches the full op" {
    // `eq`/`ne` decide same-typed numbers, primitives and heap identity on
    // the raw lanes; two distinct tables (`__eq`), strings by content and a
    // mixed number pair leave for the full op.
    try expectProgram(
        \\local nan = 0 / 0
        \\local E = { __eq = function() return true end }
        \\local p, q, t = setmetatable({}, E), setmetatable({}, E), {}
        \\print(1 == 1, 1 == 2, 1 == 1.0, 1.5 ~= 1.5, nan == nan, nan ~= nan, -0.0 == 0.0, nil == nil, nil == false)
        \\print(true == true, true ~= false, t == t, t == {}, p == q, p ~= q, "ab" == "a" .. "b", "ab" == "ac", print == print, 1 == "1")
        \\
    ,
        "true\tfalse\ttrue\tfalse\tfalse\ttrue\ttrue\ttrue\tfalse\n" ++
            "true\ttrue\ttrue\tfalse\ttrue\tfalse\ttrue\tfalse\ttrue\tfalse\n",
    );
}

test "mod and idiv fast paths: every operand mix matches the full op" {
    // Two ints with a nonzero divisor run on the raw lanes, two floats on
    // the slow half's `fmath` lane; a zero divisor, a mixed pair and
    // `__mod`/`__idiv` take the full op.
    try expectProgram(
        \\local mi = math.mininteger
        \\print(7 % 3, -7 % 3, 7 % -3, mi % -1, 7 // 2, -7 // 2, 7 // -2, mi // -1, mi // 1)
        \\print(7.5 % 2, -7.5 % 2, 5.5 % -2, 7.5 // 2, -7.5 // 2, 1.0 % 0.0 ~= 1.0 % 0.0, 1.0 // 0.0, 7 % 2.5, 7.5 // 2)
        \\print(-7.5 % 2.0, 7.5 // -2.0, (pcall(function() return 1 % 0 end)), (pcall(function() return 1 // 0 end)))
        \\local M = { __mod = function() return "m" end, __idiv = function() return "i" end }
        \\local m = setmetatable({}, M)
        \\print(m % 2, 2 // m)
        \\
    ,
        "1\t2\t-2\t0\t3\t-4\t-4\t-9223372036854775808\t-9223372036854775808\n" ++
            "1.5\t0.5\t-0.5\t3\t-4\ttrue\tinf\t2\t3\n" ++
            "0.5\t-4\tfalse\tfalse\n" ++
            "m\ti\n",
    );
}

test "numeric for: every index/limit/step type mix counts the same iterations" {
    // `forLoopStep` has an int lane and a float lane, each taking either a
    // same-typed or an other-typed limit; the rest goes out of line. Each
    // case pins the iteration count and the last index for one shape. One
    // `run` sees every step sign, so it also leans on the step guard below.
    try expectProgram(
        \\local function run(a, b, c)
        \\  local n, last = 0, nil
        \\  for i = a, b, c do
        \\    n = n + 1; last = i
        \\    if n > 50 then break end
        \\  end
        \\  return n .. ":" .. tostring(last)
        \\end
        \\local nan = 0 / 0
        \\local cases = {
        \\  { 1, 10.0, 1 }, { 1, 10.5, 1 }, { 1, 9.99, 2 }, { 10, 1.5, -1 }, { 10, 1.0, -3 },
        \\  { 1, nan, 1 }, { 1, -nan, -1 }, { 1, -1 / 0, -1 }, { 1, 0.5, 1 }, { 1, 1.0, 1 },
        \\  { -3, -2.5, 1 }, { 0.5, 3, 0.5 }, { 3.5, 1, -0.5 }, { 0.5, 0, 0.25 }, { 0.0, 2, 1.0 },
        \\  { 0.5, nan, 0.5 }, { 1, 3, 1.0 }, { 1.0, 3, 1 },
        \\}
        \\local out = {}
        \\for _, c in ipairs(cases) do out[#out + 1] = run(c[1], c[2], c[3]) end
        \\print(table.concat(out, " "))
        \\
    ,
        "10:10 10:10 5:9 9:2 4:1 0:nil 0:nil 51:-49 0:nil 1:1 1:-3 6:3 6:1 0:nil 3:2 0:nil 3:3 3:3\n",
    );
}

test "numeric for: a trace recorded on one step sign never runs the other" {
    // The recorder bakes the loop test's direction in from the observed
    // step, so a trace entered with a step of the other sign must side-exit
    // (`guard_step_up`/`guard_step_down`). Without the guard the second
    // `run` counted upward under the descending test until the `break`.
    // The `break` caps keep a regression a wrong answer, not a hang. A `-0.0`
    // step raises (`'for' step is zero`) even when `run` is already hot.
    try expectProgram(
        \\local function run(a, b, c)
        \\  local s, n = 0, 0
        \\  for i = a, b, c do
        \\    s = s + i
        \\    n = n + 1
        \\    if n > 500 then break end
        \\  end
        \\  return s
        \\end
        \\print(run(200, 1, -1), run(1, 3, 1), run(200, 1, -1))
        \\print(run(200.5, 1.5, -1.0), run(1.5, 3.5, 1.0), run(0.5, 2.5, 0 / 0), select(2, pcall(run, 2.5, 0.5, -0.0)))
        \\
    ,
        "20100\t6\t20100\n20200\t7.5\t0\trun:3: 'for' step is zero\n",
    );
}

test "numeric for: an inner loop linked from an outer trace keeps its step sign" {
    // An inner root plus the outer continuation that links into it, with
    // the inner step flipping sign between outer iterations. Before the
    // step guard, `--trace` and `--jit-native` printed wrong totals here.
    // (This does not pin `recForPrepLink`'s own guard: removing only that
    // one leaves the output unchanged, as no flipped step reaches the link
    // test here.)
    try expectProgram(
        \\local total, n = 0, 0
        \\for k = 1, 300 do
        \\  local a, b, c = 1, 6, 1
        \\  if k > 150 and k % 3 == 0 then a, b, c = 6, 1, -1 end
        \\  for i = a, b, c do
        \\    total = total + i * k
        \\    n = n + 1
        \\    if n > 100000 then break end
        \\  end
        \\end
        \\local ftotal, fn = 0, 0
        \\for k = 1, 300 do
        \\  local a, b, c = 0.5, 3.5, 0.5
        \\  if k > 150 and k % 3 == 0 then a, b, c = 3.5, 0.5, -0.5 end
        \\  for i = a, b, c do
        \\    ftotal = ftotal + i
        \\    fn = fn + 1
        \\    if fn > 100000 then break end
        \\  end
        \\end
        \\print(total, n, ftotal, fn)
        \\
    ,
        "948150\t1800\t4200\t2100\n",
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

test "for: a zero step raises before the loop runs, as Lua 5.4 does" {
    // Int `0`, `0.0` and `-0.0` all raise; NaN is not zero (its loop runs no
    // times, since every compare with NaN is false).
    try expectProgram(
        \\local n = 0
        \\print(pcall(function() for i = 1, 10, 0 do n = n + 1 end end))
        \\print(pcall(function() for i = 1, 10, 0.0 do n = n + 1 end end))
        \\print(pcall(function() for i = 10, 1, -0.0 do n = n + 1 end end))
        \\for i = 1, 10, 0/0 do n = n + 1 end
        \\print(n)
        \\
    ,
        "false\tanonymous:2: 'for' step is zero\n" ++
            "false\tanonymous:3: 'for' step is zero\n" ++
            "false\tanonymous:4: 'for' step is zero\n" ++
            "0\n",
    );
}

test "for: a hot loop whose inner step turns zero raises on that run" {
    // The inner loop runs hot with step 1, then its step becomes 0: every
    // trace mode must raise at the same run, after the same sum.
    try expectProgram(
        \\local s = 0
        \\local ok, e = pcall(function()
        \\  for k = 1, 40 do
        \\    local step = k < 30 and 1 or 0
        \\    for i = 1, 3, step do s = s + i end
        \\  end
        \\end)
        \\print(ok, e, s)
        \\
    ,
        "false\tanonymous:5: 'for' step is zero\t174\n",
    );
}

test "for: a non-number control value names which one, as Lua 5.4 does" {
    try expectProgram(
        \\print(pcall(function() for i = "a", 2 do end end))
        \\print(pcall(function() for i = 1, {} do end end))
        \\print(pcall(function() for i = 1, 2, nil do end end))
        \\
    ,
        "false\tanonymous:1: 'for' initial value must be a number\n" ++
            "false\tanonymous:2: 'for' limit must be a number\n" ++
            "false\tanonymous:3: 'for' step must be a number\n",
    );
}

test "for: an int loop stops at the integer edge instead of wrapping" {
    // Lua 5.4's counts, all checked against lua5.4. Each loop ends where the
    // next step would overflow; wrapping round never ends, which `count`
    // reports as -1. The second line runs the loop hot with a varying limit
    // until it reaches maxinteger (a hoisted overflow guard failing); the
    // third runs hot loops whose limit is at the edge when they record.
    try expectProgram(
        \\local function count(a, b, c)
        \\  local n = 0
        \\  for i = a, b, c do
        \\    n = n + 1
        \\    if n > 1000 then return -1 end
        \\  end
        \\  return n
        \\end
        \\print(count(math.maxinteger - 1, math.maxinteger, 1),
        \\  count(math.mininteger + 1, math.mininteger, -1),
        \\  count(1, math.maxinteger, math.maxinteger // 2 + 1))
        \\local n = 0
        \\for k = 1, 60 do
        \\  local hi = k < 50 and 100 or math.maxinteger
        \\  n = n + count(hi - 3, hi, 1)
        \\end
        \\print(n)
        \\print(count(math.maxinteger - 300, math.maxinteger, 1),
        \\  count(math.mininteger + 300, math.mininteger, -1),
        \\  count(math.maxinteger - 300, 2^63, 1))
        \\
    ,
        "2\t2\t2\n240\n301\t301\t301\n",
    );
}

test "for: the first value is init itself, and a NaN step counts down" {
    // No `init - step + step` round trip: 1e-20 + 1 - 1 is 0. A NaN step is
    // not zero and not `0 < step`, so the loop counts down, like Lua 5.4:
    // 1 <= 10 runs the first trip, and the NaN index ends it.
    try expectProgram(
        \\local x0
        \\for x = 1e-20, 1, 1 do x0 = x0 or x end
        \\print(x0 == 1e-20)
        \\local n, last = 0, nil
        \\for i = 10, 1, 0/0 do n = n + 1; last = math.type(i) end
        \\print(n, last)
        \\
    ,
        "true\n1\tfloat\n",
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
    , "F:add F:call\nF:get_field F:call\n");
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

test "doc 61 Phase 0: table.sort and a require loader keep their caller in flight across every re-entry; pcall suspends it" {
    // The comparator runs once per comparison: each sees the same shapes.
    // A Lua function under `pcall` runs in a protected frame (doc 68 §5),
    // with its caller suspended at the `.call`.
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
    , "F:call F:call\nS F:call\nF:call F:call\nF:call\n");
}

test "doc 61 Phase 0: an xpcall handler sees the faulting frame in flight at its fault" {
    // Faults at pc 0, and right after a `.call` (where the call-suspended
    // classification would wrongly apply). Below the faulting protected
    // frame (doc 68 §5), main is suspended at its `.call`.
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
    , "S F:get_field F:call\nS F:add F:call\n");
}

test "doc 61 Phase 0: a retained in-flight parent stays in flight under its faulting metamethod" {
    // protected fn → `.add` → Lua `__add` faults → the handler runs over
    // both: the parent is in flight at `.add`, the metamethod at its fault.
    // The `g()` before the `.add` puts a `.call` at `pc − 1`. Main, below
    // the protected frame, is suspended at its `.call`.
    try expectShapes(
        \\local function g() return 1 end
        \\local mt = {__add = function(x, y) return y.z end}
        \\local t = setmetatable({}, mt)
        \\local function f() local q = g(); return t + q end
        \\local r
        \\for i = 1, 10 do r = select(2, xpcall(f, function(e) return shapes() end)) end
        \\print(r)
        \\
    , "S F:add F:get_field F:call\n");
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
    , "S F:get_field S F:get_field F:call\nF:call\n");
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
    vm.heap.setGcStress(true);
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

test "doc 44: a function that is only its `ret`, and a call followed by `ret`, run to completion" {
    // A one-shot trace at either pc closed at its own entry and resumed at
    // its patched pc, re-entering itself forever (`.self_terminal`). The
    // `setmetatable` call keeps the driver loop off trace, so the heads and
    // continuations go hot on their own.
    try expectProgram(
        \\local mt = {}
        \\local function e() end
        \\local function v(n) if n == 0 then return end v(n - 1) end
        \\local c = 0
        \\for i = 1, 300 do local t = setmetatable({}, mt) e() v(2) c = c + 1 end
        \\print(c)
        \\
    , "300\n");
}

test "a call laid out at its destination, and `return x` in place, keep every value" {
    // Output taken on 2a20e98, before calls sat at a fresh destination.
    // `a = f1(a + b)` and `x = bump()` store into locals, which keep their
    // result move; `bump` writes `x` through its upvalue while it runs.
    // `rec2` returns the local its call landed in, the call's own register.
    try expectProgram(
        \\local function f1(x) return x end
        \\local function rec(n) if n == 0 then return 0 end local s = rec(n - 1) return s + 1 end
        \\local function rec2(n) if n == 0 then return 0 end local s = rec2(n - 1) return s end
        \\local o = { k = 5 }
        \\function o:m(v) return self.k + v end
        \\local x = 1
        \\local function bump() x = x + 10 return x end
        \\local a = f1(3)
        \\local b = o:m(a)
        \\a = f1(a + b)
        \\x = bump()
        \\local y = bump()
        \\local z = f1(f1(2) + f1(3))
        \\local t = { f1(4), f1(5) }
        \\local ok, e = pcall(function() local q = f1(nil) + 1 return q end)
        \\local r = 0
        \\for i = 1, 300 do r = r + rec(4) + rec2(4) end
        \\print(a, b, x, y, z, t[1] + t[2], ok, r)
        \\
    , "11\t8\t21\t21\t5\t9\tfalse\t1200\n");
}

test "doc 66: `A and B or C` runs each operand once, in order, with Lua's values" {
    // Output taken on 2a20e98, where every `and`/`or` value was a tested
    // register, and checked against LuaJIT. A falsy `B` falls to `C`; a
    // falsy `A` never becomes the value.
    try expectProgram(
        \\local log = ""
        \\local function v(x, s) log = log .. s return x end
        \\local n, f, z = 5, false, nil
        \\local r = {}
        \\for i = 3, 7 do r[#r + 1] = i > n and 1 or 2 end
        \\print(table.concat(r, " "))
        \\print(n > 1 and false or 3, n > 1 and nil or 4, n < 1 and 9 or nil, f and 1 or 2, z and 1 or f)
        \\print(v(1, "a") and v(false, "b") or v(7, "c"), log)
        \\log = ""
        \\print(v(nil, "a") and v(1, "b") or v(8, "c"), log)
        \\log = ""
        \\print((v(1, "a") and v(2, "b")) or v(9, "c"), log)
        \\log = ""
        \\print(n > 1 and n < 9 and "in" or "out", not (n > 1) and "x" or "y", (n == 5 or f) and {} ~= nil or 0)
        \\local nan = 0 / 0
        \\print(nan < 1 and "lt" or "nlt", nan ~= nan and "ne" or "eq")
        \\print(pcall(function() return n < "x" and 1 or 2 end))
        \\local t = {}
        \\local c = n > 3 and t or {}
        \\print(c == t, (n > 9 and t or c) == t, 1 and 2 and 3 or 4, nil and 1 or false and 2 or 5)
        \\
    ,
        "2 2 2 1 1\n3\t4\tnil\t2\tfalse\n7\tabc\n8\tac\n2\tab\nin\ty\ttrue\nnlt\tne\n" ++
            "false\tanonymous:17: attempt to compare number with string\ntrue\ttrue\t3\t5\n");
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
    // `n` and `u` are read after the call, and r3, the register `s` takes,
    // holds the callee. The suspended main chunk keeps `print` below its
    // call; `f` itself is dead.
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
    , ".f.|.#tf...\t0\t0\n");
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
    // `regs` sits at r0, the register `s` takes, and `h()` leaves its two
    // results at r1, r2, so the consumer's top is r3. The dead tables `a4`
    // and `a5` left in r3, r4 lie above it: masked to the span they are
    // scrubbed, though the consumer's row covers every register from its
    // base up.
    try expectRegs(
        \\local function h() return {}, {} end
        \\local function f()
        \\  do local a1, a2, a3, a4, a5 = {}, {}, {}, {}, {} end
        \\  local s = regs(h())
        \\  return s
        \\end
        \\print(f())
        \\
    , "f.f.|ftt..\n");
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
    , ".f.|t#tf...\t0\t0\n");
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
/// collects and reads `s`'s register before this trip writes it. `w` takes
/// the register `x` takes, so the call, which lands in `v`, has its base at
/// `y`'s and `s` is the one above it. A maskable `f` has `s` scrubbed in every
/// tier; a non-maskable one keeps the φ, so every tier holds the previous
/// trip's value. `s` is a number, which keeps the trace non-allocating; an
/// allocating one filters the same way (doc 61 §9b). `PRE` runs before `f`.
fn deadPhiProbeSource(comptime pre: []const u8) [:0]const u8 {
    return
    \\local function f(n)
    \\  local c, same, nils, hit = 0, 0, 0, false
    \\  for i = 1, n do
    \\    if hit then
    \\      local w, v = 0, peek()
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
    native.protocol = .host;
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

// Doc 68 §5: a protected frame's parent is suspended at the `pcall`, whose
// slots (`true`, `xpcall`'s handler) lie at and above the call base, outside
// the parent's mask. The stress legs collect inside each body (the concat), so
// a scrub there would print `nil` for `true` or run a nil handler.
test "doc 68 §5: a collection inside a protected body keeps the call's own slots" {
    try expectProgram(
        \\local e = 'x'
        \\print(pcall(function() return 'H:' .. e end))
        \\local function g() local ok, m = pcall(function() return 'H:' .. e end) return ok, m end
        \\print(g())
        \\local t = setmetatable({}, {__index = function() return (g()) end})
        \\print(t.x)
        \\print(xpcall(function() error('o') end, function(m) return 'h:' .. m end))
        \\print(xpcall(function() error('o') end, function() return g() end))
        \\
    ,
        "true\tH:x\ntrue\tH:x\ntrue\nfalse\th:anonymous:7: o\nfalse\ttrue\tH:x\n",
    );
}

test "a numeric for steps every limit, step and index shape" {
    // `opForLoop` steps an all-int or all-float triple and an int loop with a
    // float limit inline; everything else (a float index with an int step)
    // is `opForLoopSlow`'s.
    try expectProgram(
        \\local s = 0
        \\for i = 1, 3.5 do s = s + i end
        \\for i = 3, 0.5, -1 do s = s + i end
        \\for i = 1, 0 / 0 do s = s + 100 end
        \\for i = 1.0, 2.0 do s = s + i end
        \\for i = 1.0, 2 do s = s + i end
        \\for i = 1, 2, 0.5 do s = s + i end
        \\for i = math.maxinteger - 1, math.maxinteger do s = s + 1 end
        \\for i = math.mininteger + 1, math.mininteger, -1 do s = s + 1 end
        \\print(s, math.type(s))
        \\print(pcall(function() for i = 1, "x" do end end))
        \\
    ,
        "26.5\tfloat\nfalse\tanonymous:11: 'for' limit must be a number\n",
    );
}

test "arithmetic, unary and length fall back to their metamethods" {
    // The raw lanes live in the hot handlers; metamethods and errors are the
    // slow halves'.
    try expectProgram(
        \\local mt = {}
        \\for _, k in ipairs({ "add", "sub", "mul", "div", "band", "shl", "unm", "bnot", "len" }) do
        \\  mt["__" .. k] = function() return k end
        \\end
        \\local o = setmetatable({}, mt)
        \\print(o + 1, 1 - o, o * 2, 1 / o, o & 1, 1 << o, -o, ~o, #o)
        \\print(pcall(function() return "10" + 1 end))
        \\print(7 // 2, #"abc")
        \\local t = { 1, 2, 3 }
        \\t[3] = nil
        \\print(#t, ~5, -2.5, 6 / 4)
        \\print(pcall(function() return {} + 1 end))
        \\
    ,
        "add\tsub\tmul\tdiv\tband\tshl\tunm\tbnot\tlen\nfalse\tanonymous:7: attempt to perform arithmetic on a string value\n3\t3\n2\t-6\t-2.5\t1.5\nfalse\tanonymous:12: attempt to perform arithmetic on a table value\n",
    );
}

test "an append stores, and leaves the rest to the full store" {
    // `set_index`'s append lane takes only a plain store into allocated
    // capacity, or a fresh table's first store at key 0 or 1: a `__newindex`
    // on the key, a successor already in the hash part, a fresh table with a
    // hash part, a value that widens the lane and a full array take the full
    // store.
    try expectProgram(
        \\local t = { 1, 2 }
        \\for i = 3, 20 do t[i] = i end
        \\print(#t, t[20])
        \\local log = {}
        \\local m = setmetatable({ 1 }, { __newindex = function(_, k, v) log[#log + 1] = k .. "=" .. v end })
        \\m[2] = 5
        \\print(rawget(m, 2), log[1])
        \\local h = { 1 }
        \\h[3] = 30
        \\h[2] = 20
        \\print(#h, h[3])
        \\local w = { 1, 2 }
        \\w[3] = "x"
        \\w[4] = 1.5
        \\print(#w, w[3], w[4])
        \\local z = {}
        \\z[0] = 5
        \\z[1] = 6
        \\print(z[0], z[1], #z)
        \\local b, f, s = { true, false }, { 1.5, 2 }, { "a", nil, "c" }
        \\print(b[1], b[2], f[1], f[2], s[1], s[2], s[3])
        \\local q = { x = 1 }
        \\q[1] = 2
        \\print(q[1], q.x, #q)
        \\local n = setmetatable({}, { __newindex = function(_, k, v) log[#log + 1] = k .. "=" .. v end })
        \\n[1] = 7
        \\print(rawget(n, 1), log[2])
        \\
    ,
        "20\t20\nnil\t2=5\n3\t30\n4\tx\t1.5\n5\t6\t1\ntrue\tfalse\t1.5\t2\ta\tnil\tc\n2\t1\t1\nnil\t1=7\n",
    );
}
