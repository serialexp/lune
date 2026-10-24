//! The real-OS `HostSystem` (doc 65 §5.1), shared by the CLI (`main.zig`) and
//! libmahina (`capi.zig`). One of the `std.Io` users Rule Z-2 confines, beside
//! `io.zig` and `viz_server.zig`: a toolchain bump that moves the file API
//! is a fix here, not in the VM.
//!
//! Never compiled into the wasm build (the browser has no system interface).

const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");
const mio = @import("io.zig");

const Io = std.Io;
const HostSystem = system.HostSystem;

pub const RealSystem = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The process environment (the CLI's `Init.environ_map`). Null in
    /// libmahina, which reads the host process's through libc.
    env_map: ?*std.process.Environ.Map = null,
    /// The bytes behind the last borrowed result (`readFile`), freed on the
    /// next call that borrows and at `deinit`.
    last: ?[]u8 = null,

    /// For the CLI, with the process environment from `Init`.
    pub fn init(gpa: std.mem.Allocator, io: Io, env_map: ?*std.process.Environ.Map) RealSystem {
        return .{ .gpa = gpa, .io = io, .env_map = env_map };
    }

    pub fn deinit(self: *RealSystem) void {
        self.dropLast();
    }

    pub fn system(self: *RealSystem) HostSystem {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: HostSystem.VTable = .{
        .readFile = &readFile,
        .getenv = &getenv,
    };

    fn of(ctx: *anyopaque) *RealSystem {
        return @ptrCast(@alignCast(ctx));
    }

    fn dropLast(self: *RealSystem) void {
        if (self.last) |b| self.gpa.free(b);
        self.last = null;
    }

    fn readFile(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self = of(ctx);
        self.dropLast();
        const bytes = Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.gpa,
            Io.Limit.limited(mio.max_source_bytes),
        ) catch return null; // missing/unreadable/too large: "cannot open"
        self.last = bytes;
        return bytes;
    }

    fn getenv(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self = of(ctx);
        if (self.env_map) |m| return m.get(name);
        if (comptime builtin.link_libc and builtin.os.tag != .windows) {
            // libc wants a NUL-terminated name; an over-long or NUL-bearing
            // name can't name a variable.
            var buf: [256]u8 = undefined;
            if (name.len >= buf.len or std.mem.indexOfScalar(u8, name, 0) != null) return null;
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            const v = std.c.getenv(buf[0..name.len :0]) orelse return null;
            return std.mem.span(v);
        }
        return null;
    }
};
