//! Doc 43 P0 adversarial-alias corpus — the permanent, in-tree home of the
//! 2026-09-07 sweep that found the entry-snapshot / store-sinking miscompiles.
//!
//! Each program is a minimal shape that either (a) triggered a confirmed
//! tier-1a/native miscompile now fixed fail-closed (P0a callee-upvalue open
//! aliasing, P0b global-seed staleness, P0d length-dependent append double-
//! apply), or (b) is a boundary control that MUST keep tracing correctly and is
//! pinned so a future change can't silently regress it.
//!
//! `expectProgram` runs the full ten-leg matrix ({gc-stress off/on} × {tier-0,
//! record-only, tier-1a no-opt, tier-1a, native}) and asserts byte-identical
//! output on every leg — so a stale seed, a skipped sunk store, or a double-
//! applied append all diverge here. `hotloop = 4` (test config) commits traces
//! after 4 iterations, so the modest counts below still exercise committed
//! native code AND the loop-done replay path.
//!
//! Counts are scaled down from the original 1e5-iteration sweep purely for test
//! speed; the shapes and the expected sums are otherwise faithful (the sweep
//! itself lives at the same shapes with larger N).

const expectProgram = @import("interp_testutil.zig").expectProgram;

test "P0 corpus a01: callee upvalue open over anchor-mutated local (P0a fix)" {
    try expectProgram(
        \\local acc = 0
        \\local function get() return acc end
        \\local s = 0
        \\for i = 1, 2000 do acc = i; s = s + get() end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a02: hstore through _G stales a .global seed (P0b fix)" {
    try expectProgram(
        \\x = 0
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do g.x = i; s = s + x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a03: rawset(_G,...) stales a .global seed (P0b fix)" {
    try expectProgram(
        \\x = 0
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do rawset(g, "x", i); s = s + x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a04: read through _G alias, write via set_global (pin safe)" {
    try expectProgram(
        \\x = 0
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do x = i; s = s + g.x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a05: store via t, load via alias t2, hash field (pin safe)" {
    try expectProgram(
        \\local t = { x = 0 }
        \\local t2 = t
        \\local s = 0
        \\for i = 1, 2000 do t.x = i; s = s + t2.x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a06: store via a, load via alias a2, array slot (pin safe)" {
    try expectProgram(
        \\local a = { 0 }
        \\local a2 = a
        \\local s = 0
        \\for i = 1, 2000 do a[1] = i; s = s + a2[1] end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a07: two distinct same-shape tables, no cross-forward (control)" {
    try expectProgram(
        \\local t = { x = 0 }
        \\local u = { x = 0 }
        \\local s = 0
        \\for i = 1, 2000 do t.x = i; u.x = 2000 - i; s = s + t.x + u.x end
        \\print(s)
    , "4000000\n");
}

test "P0 corpus a08: shared closed-cell writer via set_upval (pin safe)" {
    try expectProgram(
        \\local function mk()
        \\  local v = 0
        \\  return function() return v end, function(nv) v = nv end
        \\end
        \\local get, set = mk()
        \\local s = 0
        \\for i = 1, 2000 do set(i); s = s + get() end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a09: callee upvalue open BELOW anchor window, per-episode reseed" {
    try expectProgram(
        \\local n = 0
        \\local function get() return n end
        \\local function run()
        \\  local s = 0
        \\  for i = 1, 2000 do s = s + get() end
        \\  return s
        \\end
        \\local total = 0
        \\for round = 1, 3 do n = round; total = total + run() end
        \\print(total)
    , "12000\n");
}

test "P0 corpus a10: hash_cell RMW via t, read via alias t2 (pin safe)" {
    try expectProgram(
        \\local t = { c = 0 }
        \\local t2 = t
        \\local s = 0
        \\for i = 1, 2000 do t.c = t.c + 1; s = s + t2.c end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a11: integer-key store + string-key global read, disjoint parts" {
    try expectProgram(
        \\x = 7
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do g[1] = i; s = s + x end
        \\print(s)
    , "14000\n");
}

test "P0 corpus a12: cross-episode function-valued swap via upvalue callee" {
    try expectProgram(
        \\local function f1() return 1 end
        \\local function f2() return 2 end
        \\local f = f1
        \\local s = 0
        \\for round = 1, 4 do
        \\  if round == 3 then f = f2 end
        \\  for i = 1, 2000 do s = s + f() end
        \\end
        \\print(s)
    , "12000\n");
}

test "P0 corpus a13: hash_cell seed vs table growth between episodes" {
    try expectProgram(
        \\local t = { c = 0 }
        \\local s = 0
        \\for round = 1, 4 do
        \\  for i = 1, 2000 do t.c = t.c + 1; s = s + t.c end
        \\  t["k" .. round] = round
        \\end
        \\print(s)
    , "32004000\n");
}

test "P0 corpus a14: mid-loop global function swap calls the right function" {
    try expectProgram(
        \\local function f1() return 1 end
        \\local function f2() return 1000 end
        \\f = f1
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do
        \\  if i == 1000 then g.f = f2 end
        \\  s = s + f()
        \\end
        \\print(s)
    , "1001999\n");
}

test "P0 corpus a15: mid-loop upvalue function swap through inlined callee" {
    try expectProgram(
        \\local function f1() return 1 end
        \\local function f2() return 1000 end
        \\local f = f1
        \\local function call() return f() end
        \\local s = 0
        \\for i = 1, 2000 do
        \\  if i == 1000 then f = f2 end
        \\  s = s + call()
        \\end
        \\print(s)
    , "1001999\n");
}

test "P0 corpus a16: length-dependent append via alias (P0d fix)" {
    try expectProgram(
        \\local a = {}
        \\local a2 = a
        \\local s = 0
        \\for i = 1, 2000 do a[#a + 1] = i; s = s + #a2 end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a17: sunk hash RMW visible right after linked loop-done" {
    try expectProgram(
        \\local t = { x = 0 }
        \\local s = 0
        \\for round = 1, 200 do
        \\  for i = 1, 50 do t.x = t.x + 1 end
        \\  s = s + t.x
        \\end
        \\print(s)
    , "1005000\n");
}

test "P0 corpus a18: sunk array RMW applies exactly once at loop-done" {
    try expectProgram(
        \\local a = { 0 }
        \\local s = 0
        \\for round = 1, 200 do
        \\  for i = 1, 50 do a[1] = a[1] + 1 end
        \\  s = s + a[1]
        \\end
        \\print(s)
    , "1005000\n");
}

test "P0 corpus a19: counting append (nsieve shape) stays exact" {
    try expectProgram(
        \\local a = {}
        \\for i = 1, 2000 do a[i] = i * 2 end
        \\local s = 0
        \\for i = 1, 2000 do s = s + a[i] end
        \\print(s, #a)
    , "4002000\t2000\n");
}

test "P0 corpus a20: per-round append + immediate aggregate (P0d-adjacent)" {
    try expectProgram(
        \\local s = 0
        \\for round = 1, 200 do
        \\  local a = {}
        \\  for i = 1, 100 do a[#a + 1] = i end
        \\  s = s + #a
        \\end
        \\print(s)
    , "20000\n");
}
