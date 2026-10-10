//! Tests for `interp.zig` — determinism.
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

const Vm = interp.Vm;

const util = @import("interp_testutil.zig");
const runCaptured = util.runCaptured;

// ---------------------------------------------------------------------------
// Determinism self-check — the regression spine for deterministic replay
// (docs/design/02-determinism.md §Replay verification). Replay reconstructs any
// past moment by restoring a keyframe and re-executing forward; that is only
// *sound* if an identical program run is bit-reproducible. The VM has no
// nondeterministic inputs (only `print`, an output) and no keyframes yet, so the
// honest current form of "record-then-replay equivalence" is run-twice
// equivalence: two *independent* VM instances running the same source must agree
// on every observable — printed output AND the serialized trace cache. Any
// address leaking into either (the old `@intFromPtr` render, or an
// address-keyed structure) breaks it. This is the spine effect-logging and
// keyframes plug into later, when "replay" becomes literal.
// ---------------------------------------------------------------------------

/// Run `source` with recording enabled (low hot threshold so test loops go hot),
/// capturing `print` output into `sink`, and return the **serialized trace
/// cache** wire bytes (owned by `gpa`, freed by the caller). Mirrors
/// `runCaptured`, but encodes the cache before the VM is destroyed so two
/// independent runs can be compared byte-for-byte.
fn recordRun(gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) ![]u8 {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = sink;
    vm.trace.config.enabled = true;
    vm.trace.config.hotloop = 4;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    // Self-contained wire bytes (copied out of the cache), safe past `vm.deinit`.
    return vm.trace.encodeTraceFile(gpa);
}

/// Run `source` (no tracing — a keyframe is a heap artifact, independent of the
/// JIT), then serialize a whole-VM keyframe snapshot and return its wire bytes
/// (owned by `gpa`, freed by the caller). The keyframe analogue of `recordRun`:
/// two independent runs must produce a byte-identical snapshot, which is only
/// true if the heap graph is fully id-keyed (no address leaks into the bytes,
/// including hash-map iteration order — see `table.ValueContext.hash`).
fn snapshotRun(gpa: std.mem.Allocator, source: [:0]const u8) ![]u8 {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const keyframeser = @import("keyframeser.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    // Self-contained wire bytes, safe past `vm.deinit`.
    return keyframeser.encodeSnapshot(gpa, &vm);
}

test "determinism: print of a heap object renders a stable id, not its address" {
    // The address-leak canary. A real pointer on a 64-bit target is enormous
    // (≥ ~0x550000000000); the heap-assigned identity is tiny and monotonic. We
    // assert the rendered hex is small, which distinguishes an id from an address
    // without coupling the test to the VM's exact init allocation order.
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runCaptured(testing.allocator, "print({})", &sink, false, .off);
    const out = sink.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "table: 0x"));
    var hex = out["table: 0x".len..];
    if (hex.len > 0 and hex[hex.len - 1] == '\n') hex = hex[0 .. hex.len - 1];
    const id = try std.fmt.parseInt(u64, hex, 16);
    try testing.expect(id < 0x1000); // an id, never an ASLR address
}

test "determinism: two independent runs agree on output, traces, and snapshots" {
    const programs = [_][:0]const u8{
        // A long hot integer loop — records and (had we executed) runs a trace.
        \\local s = 0
        \\for i = 1, 200 do s = s + i end
        \\print(s)
        ,
        // Tables + a hot summing loop over heap-stored values.
        \\local t = {}
        \\for i = 1, 50 do t[i] = i * i end
        \\local s = 0
        \\for i = 1, 50 do s = s + t[i] end
        \\print(s)
        ,
        // Prints a heap object's identity — would diverge if it were an address.
        \\local t = {}
        \\print(t)
        ,
        // Multiple top-level globals + a string-keyed table, all reachable from
        // `globals` at end-of-run. The globals table's hash part holds several
        // string keys; the snapshot serializes them in hash-iteration order, which
        // is deterministic ONLY if heap keys hash by their stable id, not their
        // address (table.ValueContext.hash). Reverting that fix diverges the
        // snapshot bytes here even though the printed output stays identical.
        \\config = {}
        \\config.width = 64
        \\config.height = 48
        \\config.name = "mahina"
        \\alpha = 1
        \\beta = 2
        \\gamma = 3
        \\print(config.name)
        ,
        // Dynamic multret (`all_results`) inside a hot loop. The `reg_top`
        // producer→consumer pair brackets a safepoint, so this run diverges in
        // trace/snapshot bytes if `reg_top` ever leaked into capturable state
        // (it must not — the safepoint is suppressed while a multret is pending).
        \\local function pair(i) return i, i * i end
        \\local s = 0
        \\for i = 1, 100 do
        \\  local a, b = pair(i)
        \\  s = s + a + b
        \\end
        \\print(s, pair(7))
        ,
        // Generic-for over `pairs` — the deterministic-iteration core guarantee.
        // Two tables receive the SAME keys in OPPOSITE insertion order; both are
        // traversed via `pairs` and accumulated into strings. Canonical key order
        // (tag → heap id → bits) erases the insertion order, so the printed output
        // is identical between p and q AND stable across the two independent runs.
        // The string keys also land in the heap, so the snapshot bytes only agree
        // if iteration is address-independent.
        \\local p = {}
        \\p.a = 1
        \\p.b = 2
        \\p.c = 3
        \\local q = {}
        \\q.c = 3
        \\q.b = 2
        \\q.a = 1
        \\local sp = ""
        \\for k, v in pairs(p) do sp = sp .. k .. v end
        \\local sq = ""
        \\for k, v in pairs(q) do sq = sq .. k .. v end
        \\print(sp)
        \\print(sq)
        ,
        // Varargs (`...`): destructure surplus, tail-spread forwarding, and
        // `return ...`. A vararg function aborts trace formation (nyi_opcode), so
        // this exercises the interpreter/snapshot path; the spread sets `reg_top`
        // exactly like a multret call, so divergence here would catch any address
        // or transient-state leak into the serialized bytes.
        \\local function head(...)
        \\  local a, b = ...
        \\  return a, b
        \\end
        \\local function tail(x, ...)
        \\  print(x, ...)
        \\end
        \\local s = 0
        \\for i = 1, 20 do
        \\  local a, b = head(i, i * i, i * i * i)
        \\  s = s + a + b
        \\end
        \\tail(s, head(s, s))
        ,
        // Reentrant call (`Vm.callValue`) inside a hot loop: a sort with a custom
        // comparator and a gsub with a function replacement, both driven each
        // iteration. The comparator/replacement reenter the dispatch loop on the
        // host stack; the captured/argument values are interned strings and table
        // elements. If reentry leaked an address into the parked error value, the
        // arg window, or the serialized trace/snapshot, the bytes would diverge.
        \\local total = 0
        \\for i = 1, 30 do
        \\  local t = {(i * 7) % 11, (i * 3) % 11, i % 11, (i * 5) % 11}
        \\  table.sort(t, function(a, b) return a > b end)
        \\  total = total + t[1]
        \\  local r = string.gsub("abc", "%a", function(c) return c .. tostring(i % 3) end)
        \\  total = total + #r
        \\end
        \\print(total)
        ,
        // Error raising + located message synthesis inside a hot loop. Each
        // iteration `pcall`s a function that raises both a Lua value (`error`,
        // prefixed via the call-site locator) and triggers a native bad-argument
        // fault (`string.sub(nil)`, located via `Vm.badArg`), accumulating the
        // caught message lengths. The interned located strings (`chunk:line: …`)
        // must be byte-identical across runs — a leaked address or a per-run line
        // would diverge the output AND the snapshot (the strings land in the heap).
        \\local total = 0
        \\for i = 1, 40 do
        \\  local ok1, e1 = pcall(function() error("loop") end)
        \\  total = total + #e1
        \\  local ok2, e2 = pcall(function() return string.sub(nil, i) end)
        \\  total = total + #e2
        \\end
        \\print(total)
        ,
        // Metatables (chunk 2a): a class via `__index` built and read in a hot
        // loop, plus a `__newindex` logger. Each object carries a metatable — a
        // new heap edge the snapshot serializes (`HeapTable.metatable_id`) and the
        // GC marks. The shared `string_metatable` and the interned `__index`/
        // `__newindex` names are VM-level roots captured by the snapshot too, so a
        // divergent id (a rebuilt-not-rebound metatable, an address leak through
        // the metatable edge) would split the snapshot bytes here. The objects
        // carry metatables, so trace recording aborts (`has_metatable`) and this
        // runs the tier-0 dispatch path under all modes.
        \\local Vec = {}
        \\Vec.__index = Vec
        \\function Vec.new(x) return setmetatable({ x = x }, Vec) end
        \\function Vec:double() return self.x * 2 end
        \\local log = {}
        \\local sink = setmetatable({}, { __newindex = function(t, k, v) log[#log + 1] = v end })
        \\local total = 0
        \\for i = 1, 60 do
        \\  local v = Vec.new(i)
        \\  total = total + v:double()
        \\  sink[i] = i
        \\end
        \\total = total + #log
        \\print(total)
        \\print(("mahina"):upper())
        ,
        // _G (the global environment self-reference): write and read globals
        // through `_G` in a hot loop, then chase the self-edge (`_G._G._G…`). The
        // globals table (id 0) now holds a self-referential entry serialized as
        // `HeapRef{id=0}`; a divergent id or a leaked address through that edge
        // would split the snapshot bytes. Writing through `_G` mutates the same
        // globals table the snapshot captures, so the final heap state is fully
        // exercised by the run-twice + snapshot equality checks.
        \\local total = 0
        \\for i = 1, 50 do
        \\  _G.acc = (_G.acc or 0) + i
        \\  total = total + (_G["acc"] % 7)
        \\end
        \\total = total + (_G._G._G._G.acc % 13)
        \\print(total)
        \\print(_G._G == _G)
        ,
    };
    inline for (programs) |src| {
        var buf_a: [256]u8 = undefined;
        var buf_b: [256]u8 = undefined;
        var sink_a = io.Writer.fixed(&buf_a);
        var sink_b = io.Writer.fixed(&buf_b);
        const traces_a = try recordRun(testing.allocator, src, &sink_a);
        defer testing.allocator.free(traces_a);
        const traces_b = try recordRun(testing.allocator, src, &sink_b);
        defer testing.allocator.free(traces_b);
        // Observable output is identical across independent runs...
        try testing.expectEqualStrings(sink_a.buffered(), sink_b.buffered());
        // ...and so is the serialized trace cache (no address-dependent bytes)...
        try testing.expectEqualSlices(u8, traces_a, traces_b);
        // ...and so is a whole-VM keyframe snapshot of the final heap state.
        const snap_a = try snapshotRun(testing.allocator, src);
        defer testing.allocator.free(snap_a);
        const snap_b = try snapshotRun(testing.allocator, src);
        defer testing.allocator.free(snap_b);
        try testing.expectEqualSlices(u8, snap_a, snap_b);
    }
}
