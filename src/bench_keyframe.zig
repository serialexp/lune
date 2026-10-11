//! Doc 61 Phase K (global Rule #20) — `zig build bench-keyframe`
//! (ReleaseFast).
//!
//! Keyframe capture and restore at the sizes that bound them. Phase K made
//! capture carry every unswept object (sorted by id), each table's hash part
//! (sorted by key), its array part cell by cell and a live grid whole, so its
//! cost is O(H log H + E log E + C) in objects H, hash entries E and cells C,
//! and its bytes are linear in the same. Each scenario builds one heap shape
//! at the top level, finishes, and then times `encodeSnapshot` and `restore`
//! of that final state (best of `rounds`):
//!   - objects: a million small tables, so H dominates;
//!   - hash: one table with a million string keys, so E (and its sort) does;
//!   - array: four million integers in one packed array part, plus a
//!     1000 × 1000 integer grid, so C does;
//!   - garbage: a million tables dropped just before the cut, so no
//!     collection has swept them: the whole-heap part of Phase K.
//!
//! Budget (doc 61 §9a): capture under 250 ns and restore under 1 µs per
//! object, hash entry or cell at these sizes, with bytes linear in them. A
//! keyframe is taken at a suspend point (the visualiser's replay grid, a
//! debugger), not per instruction, so this keeps a full capture of a
//! million-object heap well under a second. Informational, not a gate
//! (global Rule #22).

const std = @import("std");
const mahina = @import("mahina");

const Vm = mahina.interp.Vm;
const keyframeser = mahina.keyframeser;

const rounds = 5;

const Scenario = struct {
    name: []const u8,
    /// Objects, hash entries or cells the scenario is sized by.
    units: usize,
    source: [:0]const u8,
};

const scenarios = [_]Scenario{
    .{ .name = "objects", .units = 1_000_000, .source =
    \\local t = {}
    \\for i = 1, 1000000 do t[i] = {i} end
    \\keep = t
    },
    .{ .name = "hash", .units = 1_000_000, .source =
    \\local h = {}
    \\for i = 1, 1000000 do h["k" .. i] = i end
    \\keep = h
    },
    .{ .name = "array", .units = 5_000_000, .source =
    \\local a = {}
    \\for i = 1, 4000000 do a[i] = i % 1000 end
    \\local m = {}
    \\for i = 1, 1000 do m[i] = {0} end
    \\for i = 1, 1000 do for j = 1, 1000 do m[i][j] = i + j end end
    \\keep = {a, m}
    },
    .{ .name = "garbage", .units = 1_000_000, .source =
    \\local t = {}
    \\for i = 1, 1000000 do t[i] = {i} end
    \\t = nil
    \\keep = 1
    },
};

var g_io: std.Io = undefined;

fn now() u64 {
    return @intCast(std.Io.Timestamp.now(g_io, .awake).nanoseconds);
}

pub fn main(init: std.process.Init) u8 {
    run(init.gpa, init.io) catch |e| {
        mahina.io.eprint("bench-keyframe: error: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    g_io = io;
    mahina.io.print("bench-keyframe: best of {d}\n", .{rounds});
    for (scenarios) |s| try scenario(gpa, s);
}

fn scenario(gpa: std.mem.Allocator, s: Scenario) !void {
    var diags = mahina.diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina.parser.parse(gpa, s.source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try mahina.compiler.compile(gpa, vm.heap, s.source, tree.root, &diags);
    defer chunk.deinit();
    if (diags.hasErrors()) return error.CompileFailed;
    _ = try vm.run(chunk.proto);

    var capture_ns: u64 = std.math.maxInt(u64);
    var restore_ns: u64 = std.math.maxInt(u64);
    var bytes_len: usize = 0;
    for (0..rounds) |_| {
        const t0 = now();
        const bytes = try keyframeser.encodeSnapshot(gpa, &vm);
        const t1 = now();
        defer gpa.free(bytes);
        const vm_r = try keyframeser.restore(gpa, bytes, chunk.proto, keyframeser.NativeRegistry.base());
        const t2 = now();
        vm_r.deinit();
        gpa.destroy(vm_r);
        capture_ns = @min(capture_ns, t1 - t0);
        restore_ns = @min(restore_ns, t2 - t1);
        bytes_len = bytes.len;
    }
    const units: f64 = @floatFromInt(s.units);
    mahina.io.print(
        \\  {s: <8} {d: >8} objects  {d: >9} units  {d: >11} bytes ({d: >5.1} B/unit)
        \\           capture {d: >8.1} ms ({d: >6.1} ns/unit)  restore {d: >8.1} ms ({d: >6.1} ns/unit)
        \\
    , .{
        s.name,                                      vm.heap.object_count,                       s.units,
        bytes_len,                                   @as(f64, @floatFromInt(bytes_len)) / units, ms(capture_ns),
        @as(f64, @floatFromInt(capture_ns)) / units, ms(restore_ns),                             @as(f64, @floatFromInt(restore_ns)) / units,
    });
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
