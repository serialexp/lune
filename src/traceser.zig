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
///
/// v5 (doc 61 §7.1): each Trace record leads with its stable `id`, the key
/// execution logs join on (they no longer key on the cache index, which
/// retirement compacts).
///
/// v6: source mapping for the visualiser. Each instruction carries its
/// bytecode ordinal `ord`, and each Trace record ends with `src_by_ord`, the
/// ordinal → `{proto_id, pc}` table (`TraceCode.src_by_ord`).
pub const format_version: u32 = 6;

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

/// One trace as the serializer sees it: its immutable code plus the stable
/// `Trace.id` the wire carries (v5 — exec logs join on it). Serialization
/// consumes code, never lifecycle records (`tools/check-jit-boundaries.py`),
/// so the id travels beside the code rather than via the record.
pub const WireTrace = struct {
    id: u32,
    code: *const TraceCode,
};

/// Map a committed trace to its schema struct. Allocates the mapped arrays
/// from `a` (use a scratch arena; the result borrows from it and from the
/// trace's live string consts). The anchor is the proto's *id*, never its
/// pointer; the stable trace `id` leads (wire v5).
pub fn toSchemaTrace(a: std.mem.Allocator, wt: WireTrace) !schema.Trace {
    const t = wt.code;
    // Doc 45 D8 (fail-closed until it lands): the schema has no
    // snapshots/deopt_mode fields yet, so serializing a PRECISE trace would
    // silently strip its correctness metadata — the decoded trace would carry
    // dangling one-based `snap` indexes and claim entry-replay semantics.
    // Refuse rather than round-trip a lie.
    if (t.deopt_mode == .precise) return error.UnsupportedPreciseTrace;
    const instrs = try a.alloc(schema.IrInstr, t.instrs.len);
    for (t.instrs, 0..) |ins, i| instrs[i] = .{
        .op = @intFromEnum(ins.op),
        .a = ins.a,
        .b = ins.b,
        .aux = ins.aux,
        .ty = @intFromEnum(ins.ty),
        .snap = ins.snap,
        .ord = ins.ord,
    };

    const src_by_ord = try a.alloc(schema.SourcePoint, t.src_by_ord.len);
    for (t.src_by_ord, 0..) |pp, i| src_by_ord[i] = .{ .proto_id = pp.proto_id, .pc = pp.source_pc };

    const consts = try a.alloc(schema.ConstValue, t.consts.len);
    for (t.consts, 0..) |c, i| consts[i] = try toSchemaConst(c);

    return .{
        .id = wt.id,
        .anchor_proto_id = t.anchor.proto.id,
        .anchor_pc = t.anchor.pc,
        .peeled = @intFromBool(t.peeled),
        .instrs = instrs,
        .consts = consts,
        // `[]u16` coerces directly to the schema's `[]const u16` — no remap.
        .entry_slots = t.entry_slots,
        .src_by_ord = src_by_ord,
    };
}

/// Serialize a whole trace cache to bytes (a versioned `TraceFile`). The
/// returned slice is owned by `gpa` (caller frees). Intermediate schema structs
/// live in a scratch arena freed before return.
pub fn encodeFile(gpa: std.mem.Allocator, traces: []const WireTrace) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Doc 45 D8 interim: no filtering here. An exec-log session never
    // PRODUCES a precise trace at all: `consumeRecordingAbort` treats
    // `needs_precise` as an ordinary strike under `record_exec_log` (no memo,
    // no precise retry), so this hard error stays what it is — an invariant
    // trip, not a filter case — until the format bump serializes snapshots.
    const sch = try a.alloc(schema.Trace, traces.len);
    for (traces, 0..) |t, i| sch[i] = try toSchemaTrace(a, t);

    const file: schema.TraceFile = .{ .version = format_version, .traces = sch };
    return file.encode(gpa);
}

test {
    _ = @import("traceser_test.zig");
}
