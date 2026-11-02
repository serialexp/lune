//! The `bytebuf` heap object (doc 68 §7.4, Q2): a growable byte buffer the
//! collector owns, for a native that builds its result across Lua calls
//! (`string.gsub` with a function replacement). The buffer sits in an
//! activation's register, so the GC roots it and a keyframe saves it as its
//! used bytes; a Zig `ArrayList` could do neither, and a piece per match in
//! a table would cost a slot and a string for each.
//!
//! No Lua value is ever one: a program can't reach it, only the registers of
//! a native's activation hold it (`native_act.zig`). It has no metatable and
//! no `type()`; `typeName` calls it userdata, as it does a file.

const std = @import("std");
const object = @import("object.zig");

const GcHeader = object.GcHeader;

pub const ByteBuf = struct {
    header: GcHeader,
    list: std.ArrayList(u8),
    /// The pacing units charged for `list.items.len` (`gc.stringUnits`), so
    /// growth charges only the difference (`Heap.chargeByteBuf`) and the
    /// sweep refunds exactly. By length, not capacity: a restored buffer is
    /// exactly as long as the captured one but not as roomy, and the
    /// collector's pacing must come out the same.
    charged: usize = 0,

    /// Raw allocation only — GC-linking is the heap's job (`gc.zig`). Takes
    /// ownership of `list`, which a native hands over when it escalates from
    /// its Zig buffer to an activation.
    pub fn create(gpa: std.mem.Allocator, list: std.ArrayList(u8)) std.mem.Allocator.Error!*ByteBuf {
        const self = try gpa.create(ByteBuf);
        self.* = .{ .header = GcHeader.init(.bytebuf), .list = list };
        return self;
    }

    pub fn destroy(self: *ByteBuf, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn fromHeader(h: *GcHeader) *ByteBuf {
        std.debug.assert(h.type == .bytebuf);
        // `@alignCast` is a no-op on native, required on wasm32 (see
        // `String.fromHeader`).
        return @alignCast(@fieldParentPtr("header", h));
    }

    pub fn bytes(self: *const ByteBuf) []const u8 {
        return self.list.items;
    }
};
