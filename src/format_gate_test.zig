//! Doc 83 §7.2: the formatter's correctness gates, run over the repo's own
//! `.lua`/`.mah` files.
//!
//! For every file: `format` is idempotent, and the formatted file compiles to
//! the same program as the original (compared recursively over every proto:
//! instructions, constants by content, parameter counts, upvalue descriptors,
//! to-be-closed variables; line information is not part of the signature).
//! A file the formatter refuses (a syntax error the corpus is not supposed to
//! have, or a comment in a position it does not place) is reported by name
//! and fails the test, so the corpus is a standing list of what the
//! formatter cannot yet place.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const diag = @import("diag.zig");
const format = @import("format.zig");
const gc = @import("gc.zig");
const io_mod = @import("io.zig");
const parser = @import("parser.zig");
const string = @import("string.zig");
const Value = @import("value.zig").Value;

const testing = std.testing;
const Proto = bytecode.Proto;

fn valueSig(w: *std.ArrayList(u8), a: std.mem.Allocator, v: Value) !void {
    if (v.isHeap() and v.heapType() == .string) {
        const bytes = string.String.fromHeader(v.asHeap()).bytes();
        try w.print(a, "s{d}:{s}", .{ bytes.len, bytes });
    } else if (v.isInt()) {
        try w.print(a, "i{d}", .{v.asInt()});
    } else if (v.isFloat()) {
        try w.print(a, "f{x}", .{@as(u64, @bitCast(v.asFloat()))});
    } else if (v.isBool()) {
        try w.print(a, "b{}", .{v.asBool()});
    } else if (v.isNil()) {
        try w.appendSlice(a, "nil");
    } else {
        try w.appendSlice(a, "?");
    }
}

fn protoSig(w: *std.ArrayList(u8), a: std.mem.Allocator, p: *const Proto) !void {
    try w.print(a, "proto regs={d} params={d} vararg={} up=[", .{ p.num_registers, p.num_params, p.is_vararg });
    for (p.upvalues) |u| try w.print(a, "{}:{d},", .{ u.in_stack, u.index });
    try w.appendSlice(a, "] tbc=[");
    for (p.tbc_vars) |t| try w.print(a, "{d}:{d}-{d},", .{ t.reg, t.start, t.end });
    try w.appendSlice(a, "]\n");
    for (p.code) |i| try w.print(a, "  {s} {d} {d} {d} {d}\n", .{ @tagName(i.op), i.a, i.b, i.c, i.aux });
    for (p.constants, 0..) |k, n| {
        try w.print(a, "  k{d}=", .{n});
        try valueSig(w, a, k);
        try w.append(a, '\n');
    }
    for (p.protos) |child| try protoSig(w, a, child);
}

/// The program `source` compiles to, as text, or null if it does not compile.
fn signature(a: std.mem.Allocator, source: []const u8) !?[]const u8 {
    const src = try a.dupeSentinel(u8, source, 0);
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    if (diags.hasErrors()) return null;
    var heap = gc.Heap.init(testing.allocator);
    defer heap.deinit();
    var chunk = compiler.compileWithOptions(testing.allocator, &heap, src, tree.root, &diags, .{ .vararg_root = true }) catch return null;
    defer chunk.deinit();
    var w: std.ArrayList(u8) = .empty;
    try protoSig(&w, a, chunk.proto);
    return w.items;
}

const Outcome = enum { ok, refused_syntax, refused_comment, not_idempotent, changed_program, skipped_compile };

fn check(a: std.mem.Allocator, source: []const u8) !Outcome {
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const out = format.format(testing.allocator, source, &diags) catch |e| switch (e) {
        error.SyntaxError => return .refused_syntax,
        error.UnplacedComment => return .refused_comment,
        error.OutOfMemory => return e,
    };
    defer testing.allocator.free(out);
    var d2 = diag.Diagnostics.init(testing.allocator);
    defer d2.deinit();
    const again = format.format(testing.allocator, out, &d2) catch return .not_idempotent;
    defer testing.allocator.free(again);
    if (!std.mem.eql(u8, out, again)) return .not_idempotent;
    const before = (try signature(a, source)) orelse return .skipped_compile;
    const after = (try signature(a, out)) orelse return .changed_program;
    if (!std.mem.eql(u8, before, after)) return .changed_program;
    return .ok;
}

const roots = [_][]const u8{ "bench", "tests", "viz/fixtures", "src/stdlib" };

test "format: the repo's own programs format to a fixed point and compile to the same program" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = io_mod.hostIo();
    var bad: usize = 0;
    var total: usize = 0;
    var checked: usize = 0;
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        defer dir.close(io);
        var walker = try dir.walk(testing.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".lua") and !std.mem.endsWith(u8, entry.path, ".mah")) continue;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.path });
            const source = try io_mod.readFileZ(testing.allocator, io, path);
            defer testing.allocator.free(source);
            total += 1;
            const outcome = try check(a, source);
            switch (outcome) {
                .ok => checked += 1,
                else => {
                    bad += 1;
                    std.debug.print("format gate: {s}: {s}\n", .{ path, @tagName(outcome) });
                },
            }
        }
    }
    std.debug.print("format gate: {d} files, {d} formatted to a fixed point with identical bytecode\n", .{ total, checked });
    try testing.expect(total > 0);
    try testing.expectEqual(@as(usize, 0), bad);
}
