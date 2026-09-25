//! Owned recording result, before registry allocation assigns a stable trace ID.
//! No recorder scratch, registry, coordinator, or native lifecycle state is retained.
const std = @import("std");
const TraceCode = @import("trace_code.zig").TraceCode;
const ExitKey = @import("trace_types.zig").ExitKey;

/// Single owner of frozen code. Like TraceCode, this must not be shallow-copied
/// while live: transfer ownership with take(), then initialize the next owner.
/// The anchor's program image and heap values in constants remain borrowed under
/// TraceCode's existing lifetime contract; only the payload arrays are owned.
pub const RecordingCandidate = struct {
    code: ?TraceCode,
    /// Originating exit for a side recording, not this candidate's identity.
    side_src: ?ExitKey,

    /// Consumes code's owned arrays. The caller must no longer deinit that copy.
    pub fn init(code: TraceCode, side_src: ?ExitKey) RecordingCandidate {
        return .{ .code = code, .side_src = side_src };
    }

    /// Borrow immutable code until take(), deinit(), or movement of this owner.
    pub fn getCode(self: *const RecordingCandidate) ?*const TraceCode {
        if (self.code) |*code| return code;
        return null;
    }

    /// Transfers all code ownership to the caller, who must eventually deinit it
    /// or publish it to another owner. Subsequent take() returns null. side_src
    /// stays readable so publication can associate the originating exit.
    pub fn take(self: *RecordingCandidate) ?TraceCode {
        const code = self.code;
        self.code = null;
        return code;
    }

    /// Safe after take() and on repeated calls; TraceCode.deinit itself is not.
    pub fn deinit(self: *RecordingCandidate, gpa: std.mem.Allocator) void {
        if (self.take()) |owned| {
            var code = owned;
            code.deinit(gpa);
        }
    }
};

fn emptyCode() TraceCode {
    return .{
        .anchor = undefined, // These ownership tests never inspect proto identity.
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
}

/// Minimal allocations exercise every array freed by TraceCode.deinit, without
/// constructing a recorder/session or any runtime-owned heap values.
fn ownedCode(gpa: std.mem.Allocator) !TraceCode {
    var code = emptyCode();
    errdefer code.deinit(gpa);
    inline for (.{ "instrs", "consts", "entry_slots", "entry_guards", "inputs", "exit_prov", "rec_path", "bridge_cand", "exit_attach" }) |field| {
        const Element = std.meta.Child(@TypeOf(@field(code, field)));
        @field(code, field) = try gpa.alloc(Element, 1);
    }
    code.entry_slots[0] = 7;
    return code;
}

test "recording candidate cleanup owns all code arrays" {
    const gpa = std.testing.allocator;
    var candidate = RecordingCandidate.init(try ownedCode(gpa), null);
    defer candidate.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 7), candidate.getCode().?.entry_slots[0]);
    candidate.deinit(gpa);
    try std.testing.expect(candidate.getCode() == null);
    try std.testing.expect(candidate.take() == null);
}

test "recording candidate take survives source cleanup and moves to next owner" {
    const gpa = std.testing.allocator;
    const side_src: ExitKey = .{ .trace_id = 17, .exit_instr = 3 };
    var source = RecordingCandidate.init(try ownedCode(gpa), side_src);
    defer source.deinit(gpa);
    const slots = source.getCode().?.entry_slots.ptr;
    var destination = RecordingCandidate.init(source.take().?, source.side_src);
    defer destination.deinit(gpa);
    source.deinit(gpa);
    try std.testing.expect(source.take() == null);
    try std.testing.expectEqualDeep(side_src, destination.side_src.?);
    try std.testing.expectEqual(slots, destination.getCode().?.entry_slots.ptr);
    try std.testing.expectEqual(@as(u16, 7), destination.getCode().?.entry_slots[0]);

    var code = destination.take().?;
    defer code.deinit(gpa);
    destination.deinit(gpa);
    try std.testing.expect(destination.getCode() == null);
    try std.testing.expectEqual(@as(u16, 7), code.entry_slots[0]);
}

test "recording candidate empty arrays can be dropped or taken" {
    var candidate = RecordingCandidate.init(emptyCode(), null);
    candidate.deinit(std.testing.allocator);
    candidate.deinit(std.testing.allocator);
    candidate = RecordingCandidate.init(emptyCode(), null);
    var code = candidate.take().?;
    defer code.deinit(std.testing.allocator);
    candidate.deinit(std.testing.allocator);
    try std.testing.expect(candidate.side_src == null);
}
