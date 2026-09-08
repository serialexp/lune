//! Trace serialization (Phase 5b) — the bridge between an in-memory committed
//! `TraceCode` and its on-disk wire form.
//!
//! The wire format is defined once, declaratively, in `schema/trace.json`
//! (binschema). `tools/regen-trace-schema.sh` generates the Zig encoder/decoder
//! from it into `src/gen/trace_schema.zig` (+ the `binschema` runtime under
//! `src/gen/binschema/`), which we vendor and commit. We never hand-write
//! encode/decode — this module only *maps* mahina's runtime structs to/from the
//! generated schema structs.
//!
//! Direction: this is the *producer* side (VM → bytes). Decoding back into live
//! VM `Value`s / `*Proto`s (reload-into-VM) is deliberately out of scope — a
//! serialized anchor is a proto *id*, not a pointer, and the consumer (the
//! Phase 7 visualiser) reads the structural form, never rebinds a live pointer.
//! `decode` therefore yields the generated schema structs, not mahina types.

const std = @import("std");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const TraceCode = trace_code.TraceCode;
const value = @import("value.zig");
const string = @import("string.zig");

const Value = value.Value;

/// The generated binschema codec (structs + encode/decode). Generated from
/// `schema/trace.json`; see this file's module doc.
pub const schema = @import("gen/trace_schema.zig");

/// Wire-format version, written into every `TraceFile`. Bump on any
/// schema-incompatible change. The compat policy (visualiser reads only its own
/// VM commit's traces) lives in `docs/design/04-snapshot-replay-schema.md`.
///
/// v2 (Phase E0): loop-carried writebacks moved from a separate `exit_stores`
/// list into the instruction stream as slot-bound `phi` nodes; `exit_stores` and
/// the `SlotStore` type were dropped from the schema. A v1 trace's trailing
/// `exit_stores` bytes are wire-incompatible with the v2 layout.
///
/// v3 (doc 39): the `peeled` byte joins the Trace record — semantic state (the
/// run-once region is a real tier-0 iteration; first back-edge counts two)
/// that cannot be inferred from the `preheader` marker.
///
/// v4 (doc 44 P0): the `.terminal` IR op (wire 86) joins the instruction
/// stream, and a head trace's `anchor.pc` is the `FUNC_HEAD_PC` sentinel
/// (`maxInt(u32)`) — a v3 reader would misdecode op 86 and misread the
/// sentinel as a bytecode pc. No layout change; the bump is semantic.
pub const format_version: u32 = 4;

/// Map one trace constant. A `heap_ref` const is always a string — the only
/// heap value a trace constant can be (tables/closures are never compile-time
/// constants); anything else is a recorder bug, surfaced as `UnsupportedConst`.
/// The returned `ConstString` borrows the live string's bytes, so the value is
/// valid only while the source heap object is alive (true during encode).
pub fn toSchemaConst(v: Value) error{UnsupportedConst}!schema.ConstValue {
    return switch (v.tag) {
        .nil => .{ .tag = @intFromEnum(value.Tag.nil), .body = .{ .ConstNil = .{ .pad = 0 } } },
        .boolean => .{ .tag = @intFromEnum(value.Tag.boolean), .body = .{ .ConstBool = .{ .v = @intFromBool(v.asBool()) } } },
        .int => .{ .tag = @intFromEnum(value.Tag.int), .body = .{ .ConstInt = .{ .v = v.asInt() } } },
        .float => .{ .tag = @intFromEnum(value.Tag.float), .body = .{ .ConstFloat = .{ .v = v.asFloat() } } },
        .heap_ref => blk: {
            const hdr = v.asHeap();
            if (hdr.type != .string) return error.UnsupportedConst;
            break :blk .{
                .tag = @intFromEnum(value.Tag.heap_ref),
                .body = .{ .ConstString = .{ .v = string.String.fromHeader(hdr).bytes() } },
            };
        },
        // A grid row handle is a runtime transient, never a trace constant.
        .row_view => return error.UnsupportedConst,
    };
}

/// Map a committed `TraceCode` to its schema struct. Allocates the mapped
/// arrays from `a` (use a scratch arena; the result borrows from it and from the
/// trace's live string consts). The anchor is the proto's *id*, never its
/// pointer.
pub fn toSchemaTrace(a: std.mem.Allocator, t: *const TraceCode) !schema.Trace {
    const instrs = try a.alloc(schema.IrInstr, t.instrs.len);
    for (t.instrs, 0..) |ins, i| instrs[i] = .{
        .op = @intFromEnum(ins.op),
        .a = ins.a,
        .b = ins.b,
        .aux = ins.aux,
        .ty = @intFromEnum(ins.ty),
        .snap = ins.snap,
    };

    const consts = try a.alloc(schema.ConstValue, t.consts.len);
    for (t.consts, 0..) |c, i| consts[i] = try toSchemaConst(c);

    return .{
        .anchor_proto_id = t.anchor.proto.id,
        .anchor_pc = t.anchor.pc,
        .peeled = @intFromBool(t.peeled),
        .instrs = instrs,
        .consts = consts,
        // `[]u16` coerces directly to the schema's `[]const u16` — no remap.
        .entry_slots = t.entry_slots,
    };
}

/// Serialize a whole trace cache to bytes (a versioned `TraceFile`). The
/// returned slice is owned by `gpa` (caller frees). Intermediate schema structs
/// live in a scratch arena freed before return.
pub fn encodeFile(gpa: std.mem.Allocator, traces: []const *const TraceCode) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const sch = try a.alloc(schema.Trace, traces.len);
    for (traces, 0..) |t, i| sch[i] = try toSchemaTrace(a, t);

    const file: schema.TraceFile = .{ .version = format_version, .traces = sch };
    return file.encode(gpa);
}

test {
    _ = @import("traceser_test.zig");
}
