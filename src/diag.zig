//! Diagnostics — a shared sink for lexer and parser errors.
//!
//! v1 keeps messages as static strings (no formatting) to stay off the churny
//! `std.fmt`/`std.Io` surface and to avoid per-error allocation. A diagnostic
//! carries a byte span + line so a front-end driver (or the future visualiser)
//! can point at the offending source. Richer, formatted messages can come later
//! without changing call sites.

const std = @import("std");

pub const Severity = enum { @"error", warning };

pub const Diagnostic = struct {
    severity: Severity,
    /// Static, human-readable message (no interpolation in v1).
    message: []const u8,
    /// Byte span into the source: `[start, end)`.
    start: u32,
    end: u32,
    /// 1-based line of `start`.
    line: u32,
};

/// An append-only collection of diagnostics. Backed by an unmanaged
/// `std.ArrayList` (methods take the allocator explicitly in this toolchain).
pub const Diagnostics = struct {
    list: std.ArrayList(Diagnostic) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.list.deinit(self.gpa);
    }

    pub fn add(self: *Diagnostics, d: Diagnostic) void {
        // A diagnostics sink that itself fails to allocate has nothing useful to
        // do; drop the diagnostic rather than propagate an error through every
        // lex/parse call. (Out-of-memory while recording an error is already a
        // lost cause for this compile.)
        self.list.append(self.gpa, d) catch {};
    }

    pub fn err(self: *Diagnostics, message: []const u8, start: u32, end: u32, line: u32) void {
        self.add(.{
            .severity = .@"error",
            .message = message,
            .start = start,
            .end = end,
            .line = line,
        });
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.list.items.len;
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.list.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }
};

test "diagnostics collect and report errors" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    try std.testing.expect(!diags.hasErrors());
    diags.err("unterminated string", 4, 9, 1);
    try std.testing.expectEqual(@as(usize, 1), diags.count());
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqualStrings("unterminated string", diags.list.items[0].message);
}
