//! The `file` heap object (doc 65 §4.1): a Lua file handle. The VM owns only
//! what a program can observe — the handle's id, what it is, its mode, whether
//! it is closed — and the host owns the OS side, a table from id to OS file
//! (`host_system.zig`). The VM never sees a file descriptor, so a replay needs
//! no host at all: every operation's result comes from the effect log.
//!
//! There is no finalizer (the GC has none, doc 02): a handle the program drops
//! without closing stays open on the host until the VM is torn down.

const std = @import("std");
const object = @import("object.zig");
const system = @import("system.zig");

const GcHeader = object.GcHeader;

pub const File = struct {
    header: GcHeader,
    /// The VM-assigned handle number (`Vm.next_file_id`, a deterministic
    /// counter); 0, 1 and 2 are the standard streams.
    id: system.FileId,
    kind: Kind,
    mode: system.OpenMode,
    closed: bool = false,
    /// Restored from a keyframe into a live VM, and not reopened (doc 65 Q7):
    /// the host has nothing behind `id`, so every operation refuses. A replay
    /// never asks the host, so it ignores this.
    detached: bool = false,
    /// The path it was opened with, owned; empty for the standard streams and
    /// a temporary file. Error messages name it, and a reopen after a restore
    /// opens it again.
    path: []u8,
    /// The host's view of the file when the keyframe it was restored from was
    /// captured (Q7), checked before a reopen. Null when the keyframe carried
    /// none (captured in replay, or not a regular file).
    fingerprint: ?system.Fingerprint = null,

    pub const Kind = enum(u8) {
        stdin = 0,
        stdout = 1,
        stderr = 2,
        file = 3,
        tmpfile = 4,
    };

    /// Allocate a handle. Raw allocation only — GC-linking is the heap's job
    /// (`gc.zig`). `path` is copied.
    pub fn create(gpa: std.mem.Allocator, id: system.FileId, kind: Kind, mode: system.OpenMode, path: []const u8) std.mem.Allocator.Error!*File {
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        const self = try gpa.create(File);
        self.* = .{ .header = GcHeader.init(.file), .id = id, .kind = kind, .mode = mode, .path = owned };
        return self;
    }

    pub fn destroy(self: *File, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.destroy(self);
    }

    pub fn fromHeader(h: *GcHeader) *File {
        std.debug.assert(h.type == .file);
        // `@alignCast` is a no-op on native, required on wasm32 (see
        // `String.fromHeader`). The object is allocated at `@alignOf(File)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    /// How messages name the handle: the path, or what it is.
    pub fn displayName(self: *const File) []const u8 {
        return switch (self.kind) {
            .stdin => "stdin",
            .stdout => "stdout",
            .stderr => "stderr",
            .tmpfile => "temporary file",
            .file => self.path,
        };
    }

    /// A standard stream: its writes go to the VM's output seam, not the host.
    pub fn isStdStream(self: *const File) bool {
        return self.kind == .stdin or self.kind == .stdout or self.kind == .stderr;
    }
};

/// The keyframe's one-byte form of an `OpenMode`: the kind in bits 0–1,
/// `update` in bit 2, `binary` in bit 3.
pub fn packMode(m: system.OpenMode) u8 {
    return @as(u8, @intFromEnum(m.kind)) | (@as(u8, @intFromBool(m.update)) << 2) | (@as(u8, @intFromBool(m.binary)) << 3);
}

/// Inverse of `packMode`; null for a byte `packMode` never writes.
pub fn unpackMode(b: u8) ?system.OpenMode {
    if (b & 0xF0 != 0) return null;
    const kind = std.enums.fromInt(@FieldType(system.OpenMode, "kind"), b & 3) orelse return null;
    return .{ .kind = kind, .update = b & 4 != 0, .binary = b & 8 != 0 };
}

test "packMode round-trips every mode and rejects stray bits" {
    for ([_]system.OpenMode{
        .{ .kind = .read },
        .{ .kind = .write, .binary = true },
        .{ .kind = .append, .update = true },
        .{ .kind = .read, .update = true, .binary = true },
    }) |m| try std.testing.expectEqual(m, unpackMode(packMode(m)).?);
    try std.testing.expect(unpackMode(3) == null);
    try std.testing.expect(unpackMode(0x10) == null);
}
