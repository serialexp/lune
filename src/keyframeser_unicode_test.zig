//! Tests for `keyframeser.zig` — unicode.
//!
//! Extracted verbatim from `keyframeser.zig`; bodies are unchanged.
//! Shared harness lives in `keyframeser_testutil.zig`.

const keyframeser = @import("keyframeser.zig");
const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const interp = @import("interp.zig");
const gc = @import("gc.zig");
const key_order = @import("key_order.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const diag = @import("diag.zig");
const trace = @import("trace.zig");
const Value = value.Value;
const GcHeader = object.GcHeader;
const Proto = bytecode.Proto;
const Vm = interp.Vm;
pub const schema = @import("gen/trace_schema.zig");
const testing = std.testing;
const mahina_parser = @import("parser.zig");
const mahina_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

const NativeRegistry = keyframeser.NativeRegistry;
const encodeSnapshot = keyframeser.encodeSnapshot;
const restore = keyframeser.restore;

// ---------------------------------------------------------------------------
// S-C — `unicode_version` survives a snapshot cut without double-consuming.
//
// Unlike F2d (a multi-entry clock() log cut mid-stream), the unicode_version
// effect is logged EXACTLY ONCE per session — at the first case op. So the
// replay hazard is the opposite shape: a later `upper` on a *restored* VM (whose
// in-memory `unicode_version_pinned` was reset to false by `restore`) must NOT
// try to consume a second, nonexistent effect. It must instead DERIVE that the
// version was already pinned pre-cut by scanning the consumed effect-log prefix
// (`versionAlreadyConsumed`). This test cuts AFTER the lone effect is consumed,
// then runs more case ops on the restored VM and proves the forward output is
// byte-identical with the log consumed exactly once.
// ---------------------------------------------------------------------------

const sc_snapshot_source =
    \\local function shout(s, n)
    \\  local r = s
    \\  for i = 1, n do r = string.upper(r) end
    \\  return r
    \\end
    \\print(shout("café", 3))
    \\print(shout("naïve", 3))
;

test "S-C: unicode_version survives a snapshot cut with no double-consume" {
    const gpa = testing.allocator;
    const source = sc_snapshot_source;

    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // --- Run 1 (record): reference output F + effect log L (a single unicode_version).
    const ref = blk: {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [512]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        vm.effect_mode = .record;
        _ = try vm.run(chunk.proto);
        break :blk .{
            .out = try gpa.dupe(u8, sink.buffered()),
            .log = try gpa.dupe(interp.Effect, vm.effect_log.items),
            .safepoints = vm.safepoint_seq,
        };
    };
    defer gpa.free(ref.out);
    defer gpa.free(ref.log);
    // Six upper() calls across the two shout()s, but the version is pinned ONCE.
    try testing.expectEqual(@as(usize, 1), ref.log.len);
    try testing.expectEqual(interp.EffectKind.unicode_version, ref.log[0].kind);

    // --- Run 2 (replay + suspend): cut mid-execution, after the version is pinned.
    var vm2 = try Vm.init(gpa);
    defer vm2.deinit();
    var buf2: [512]u8 = undefined;
    var sink2 = io.Writer.fixed(&buf2);
    vm2.out = &sink2;
    var chunk2 = try mahina_compiler.compile(gpa, vm2.heap, source, tree.root, &diags);
    defer chunk2.deinit();
    try testing.expect(!diags.hasErrors());

    vm2.effect_mode = .replay;
    try vm2.effect_log.appendSlice(gpa, ref.log);
    vm2.suspend_ctl = .{ .min_depth = 2, .after_safepoints = ref.safepoints / 2 };
    try testing.expect((try vm2.start(chunk2.proto)) == .suspended);

    const out_before = try gpa.dupe(u8, sink2.buffered());
    defer gpa.free(out_before);
    // The lone effect was consumed before the cut: the whole (length-1) log is spent.
    const cursor_at_cut = vm2.effect_cursor;
    try testing.expectEqual(ref.log.len, cursor_at_cut);
    // And there is genuinely forward work left (the second shout has not printed yet).
    try testing.expect(out_before.len < ref.out.len);

    const mid = try encodeSnapshot(gpa, &vm2);
    defer gpa.free(mid);

    // --- Restore + replay-from-cursor. `restore` rebuilds the VM fresh, so
    // `unicode_version_pinned` is false again — the derivation is what must hold.
    const vm_r = try restore(gpa, mid, chunk2.proto, NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    try testing.expect(!vm_r.unicode_version_pinned); // restore did NOT carry the flag
    var buf_r: [512]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.effect_mode = .replay;
    try vm_r.effect_log.appendSlice(gpa, ref.log);
    vm_r.effect_cursor = cursor_at_cut;
    vm_r.suspend_ctl = null;
    // If the derivation were wrong, the post-cut upper() would try to consume a
    // second effect and fault (log exhausted); instead it finishes cleanly.
    try testing.expect((try vm_r.exec()) == .finished);

    var combined: [1024]u8 = undefined;
    @memcpy(combined[0..out_before.len], out_before);
    @memcpy(combined[out_before.len..][0..sink_r.buffered().len], sink_r.buffered());
    try testing.expectEqualStrings(ref.out, combined[0 .. out_before.len + sink_r.buffered().len]);
    // The single effect was consumed exactly once across the whole cut.
    try testing.expectEqual(ref.log.len, vm_r.effect_cursor);
}
