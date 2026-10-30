//! `mahina.toml`, the project config (doc 74 §7.4, Q5). The Zig stdlib has no
//! TOML reader, so this reads the subset the config needs: `[table]` headers
//! with bare names, `key = value` lines, basic strings, integers, booleans and
//! single-line arrays of strings, with `#` comments. Anything else is a
//! located error, never a guess. The file is data: it is parsed, never run.
//!
//! The format, version 1:
//!
//!     version = 1
//!
//!     [runtime]
//!     cwd = "."                      # the directory `require` searches from
//!     package_path = ["./?.mah", "./?/init.mah"]
//!     system = ["files", "stdio"]    # system groups the program is given;
//!                                    # all of them when absent, as the CLI
//!                                    # gives, none for `[]`
//!
//!     [globals]                      # host globals, with a description each
//!     spawn = "starts a host process"
//!
//!     [diagnostics]
//!     suppress = ["unused-local"]    # diagnostic codes to hide

const std = @import("std");
const system = @import("../system.zig");

/// The only `version` this reader understands.
pub const version = 1;

/// Lua's default searchers, as `package.path` (`stdlib/package.zig`).
pub const default_package_path = [_][]const u8{ "./?.mah", "./?/init.mah", "./?.lua", "./?/init.lua" };

pub const Global = struct {
    name: []const u8,
    description: []const u8,
};

pub const Config = struct {
    cwd: []const u8 = ".",
    package_path: []const []const u8 = &default_package_path,
    /// The system groups the host enables (doc 65 §5.2): every one unless the
    /// config says, as `mahina run` gives every one unless `--system` says.
    system: system.Groups = .all,
    globals: []const Global = &.{},
    suppress: []const []const u8 = &.{},
};

/// Where a config is wrong: 1-based line and column, and what is wrong.
pub const Failure = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

pub const Parsed = union(enum) {
    ok: Config,
    failed: Failure,
};

const Error = error{ Malformed, OutOfMemory };

const Table = enum { root, runtime, globals, diagnostics };

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    i: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,
    failure: Failure = .{ .line = 1, .column = 1, .message = "" },

    fn column(p: *const Parser) u32 {
        return @intCast(p.i - p.line_start + 1);
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.failure = .{ .line = p.line, .column = p.column(), .message = try std.fmt.allocPrint(p.a, fmt, args) };
        return error.Malformed;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    /// Spaces and tabs (and the `\r` of a CRLF line end).
    fn skipBlanks(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t' and c != '\r') break;
            p.i += 1;
        }
    }

    /// The end of a statement: blanks, an optional comment, then a line end or
    /// the end of the file.
    fn endOfLine(p: *Parser) Error!void {
        p.skipBlanks();
        if (p.peek() == '#') {
            while (p.peek()) |c| {
                if (c == '\n') break;
                p.i += 1;
            }
        }
        switch (p.peek() orelse return) {
            '\n' => {
                p.i += 1;
                p.line += 1;
                p.line_start = p.i;
            },
            else => return p.fail("expected the end of the line", .{}),
        }
    }

    fn isKeyByte(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
    }

    fn bareKey(p: *Parser) Error![]const u8 {
        const start = p.i;
        while (p.peek()) |c| {
            if (!isKeyByte(c)) break;
            p.i += 1;
        }
        if (p.i == start) return p.fail("expected a name", .{});
        return p.src[start..p.i];
    }

    fn string(p: *Parser) Error![]const u8 {
        if (p.peek() != '"') return p.fail("expected a string in double quotes", .{});
        p.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated string", .{});
            if (c == '\n') return p.fail("a string cannot span lines", .{});
            p.i += 1;
            if (c == '"') break;
            if (c != '\\') {
                try out.append(p.a, c);
                continue;
            }
            const e = p.peek() orelse return p.fail("unterminated string", .{});
            p.i += 1;
            try out.append(p.a, switch (e) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                else => return p.fail("unknown escape '\\{c}' (\\\", \\\\, \\n and \\t are allowed)", .{e}),
            });
        }
        return out.toOwnedSlice(p.a);
    }

    fn stringArray(p: *Parser) Error![]const []const u8 {
        if (p.peek() != '[') return p.fail("expected an array of strings", .{});
        p.i += 1;
        var out: std.ArrayList([]const u8) = .empty;
        p.skipBlanks();
        while (p.peek() != ']') {
            try out.append(p.a, try p.string());
            p.skipBlanks();
            if (p.peek() == ',') {
                p.i += 1;
                p.skipBlanks();
            } else if (p.peek() != ']') {
                return p.fail("expected ',' or ']' in the array", .{});
            }
        }
        p.i += 1;
        return out.toOwnedSlice(p.a);
    }

    fn integer(p: *Parser) Error!i64 {
        const start = p.i;
        if (p.peek() == '-' or p.peek() == '+') p.i += 1;
        while (p.peek()) |c| {
            if (c < '0' or c > '9') break;
            p.i += 1;
        }
        return std.fmt.parseInt(i64, p.src[start..p.i], 10) catch p.fail("expected an integer", .{});
    }

    fn value(p: *Parser) Error!Value {
        switch (p.peek() orelse return p.fail("expected a value", .{})) {
            '"' => return .{ .string = try p.string() },
            '[' => return .{ .array = try p.stringArray() },
            't', 'f' => {
                if (std.mem.startsWith(u8, p.src[p.i..], "true")) {
                    p.i += 4;
                    return .{ .boolean = true };
                }
                if (std.mem.startsWith(u8, p.src[p.i..], "false")) {
                    p.i += 5;
                    return .{ .boolean = false };
                }
                return p.fail("expected true or false", .{});
            },
            '-', '+', '0'...'9' => return .{ .integer = try p.integer() },
            else => return p.fail("expected a string, an array, a boolean or an integer", .{}),
        }
    }

    /// The table a `[name]` header opens.
    fn header(p: *Parser) Error!Table {
        p.i += 1;
        p.skipBlanks();
        const at = p.column();
        const name = try p.bareKey();
        p.skipBlanks();
        if (p.peek() != ']') return p.fail("expected ']' after the table name", .{});
        p.i += 1;
        if (std.mem.eql(u8, name, "runtime")) return .runtime;
        if (std.mem.eql(u8, name, "globals")) return .globals;
        if (std.mem.eql(u8, name, "diagnostics")) return .diagnostics;
        p.failure = .{ .line = p.line, .column = at, .message = try std.fmt.allocPrint(p.a, "unknown table [{s}] (runtime, globals and diagnostics are the tables)", .{name}) };
        return error.Malformed;
    }
};

const Value = union(enum) {
    string: []const u8,
    array: []const []const u8,
    boolean: bool,
    integer: i64,
};

/// The groups `names` lists, or the first name that is no group.
pub fn groupsOf(names: []const []const u8) union(enum) { ok: system.Groups, unknown: []const u8 } {
    var out: system.Groups = .none;
    for (names) |n| {
        const group = std.meta.stringToEnum(system.Group, n) orelse return .{ .unknown = n };
        switch (group) {
            inline else => |t| @field(out, @tagName(t)) = true,
        }
    }
    return .{ .ok = out };
}

/// Parse `source`. The result's strings live in `a`, which the caller keeps
/// for as long as the config is used.
pub fn parse(a: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Parsed {
    var p: Parser = .{ .a = a, .src = source };
    return parseInto(&p) catch |e| switch (e) {
        error.Malformed => .{ .failed = p.failure },
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn parseInto(p: *Parser) Error!Parsed {
    var cfg: Config = .{};
    var globals: std.ArrayList(Global) = .empty;
    var suppress: []const []const u8 = &.{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var seen_version = false;
    var table: Table = .root;

    while (p.peek()) |c| {
        switch (c) {
            ' ', '\t', '\r' => p.skipBlanks(),
            '\n' => try p.endOfLine(),
            '#' => try p.endOfLine(),
            '[' => {
                table = try p.header();
                try p.endOfLine();
            },
            else => {
                const key_at = p.column();
                const key = try p.bareKey();
                p.skipBlanks();
                if (p.peek() != '=') return p.fail("expected '=' after '{s}'", .{key});
                p.i += 1;
                p.skipBlanks();
                const dup = try std.fmt.allocPrint(p.a, "{d}.{s}", .{ @intFromEnum(table), key });
                if ((try seen.getOrPut(p.a, dup)).found_existing) {
                    p.failure = .{ .line = p.line, .column = key_at, .message = try std.fmt.allocPrint(p.a, "'{s}' is set twice", .{key}) };
                    return error.Malformed;
                }
                switch (table) {
                    .root => {
                        if (!std.mem.eql(u8, key, "version")) return unknownKey(p, key_at, key, "the top level");
                        const v = try p.value();
                        if (v != .integer or v.integer != version) {
                            p.failure = .{ .line = p.line, .column = key_at, .message = try std.fmt.allocPrint(p.a, "version must be {d}", .{version}) };
                            return error.Malformed;
                        }
                        seen_version = true;
                    },
                    .runtime => {
                        if (std.mem.eql(u8, key, "cwd")) {
                            cfg.cwd = try p.string();
                        } else if (std.mem.eql(u8, key, "package_path")) {
                            cfg.package_path = try p.stringArray();
                        } else if (std.mem.eql(u8, key, "system")) {
                            switch (groupsOf(try p.stringArray())) {
                                .ok => |g| cfg.system = g,
                                .unknown => |n| {
                                    p.failure = .{ .line = p.line, .column = key_at, .message = try std.fmt.allocPrint(p.a, "unknown system group '{s}'", .{n}) };
                                    return error.Malformed;
                                },
                            }
                        } else return unknownKey(p, key_at, key, "[runtime]");
                    },
                    .globals => {
                        const description = try p.string();
                        try globals.append(p.a, .{ .name = key, .description = description });
                    },
                    .diagnostics => {
                        if (!std.mem.eql(u8, key, "suppress")) return unknownKey(p, key_at, key, "[diagnostics]");
                        suppress = try p.stringArray();
                    },
                }
                try p.endOfLine();
            },
        }
    }
    if (!seen_version) {
        p.failure = .{ .line = 1, .column = 1, .message = try std.fmt.allocPrint(p.a, "the file must start with version = {d}", .{version}) };
        return error.Malformed;
    }
    cfg.globals = try globals.toOwnedSlice(p.a);
    cfg.suppress = suppress;
    return .{ .ok = cfg };
}

fn unknownKey(p: *Parser, at: u32, key: []const u8, where: []const u8) Error {
    p.failure = .{ .line = p.line, .column = at, .message = try std.fmt.allocPrint(p.a, "unknown key '{s}' in {s}", .{ key, where }) };
    return error.Malformed;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

fn parseOk(arena: std.mem.Allocator, source: []const u8) !Config {
    return switch (try parse(arena, source)) {
        .ok => |c| c,
        .failed => |f| {
            std.debug.print("unexpected failure at {d}:{d}: {s}\n", .{ f.line, f.column, f.message });
            return error.UnexpectedFailure;
        },
    };
}

fn parseFailure(arena: std.mem.Allocator, source: []const u8) !Failure {
    return switch (try parse(arena, source)) {
        .ok => error.UnexpectedSuccess,
        .failed => |f| f,
    };
}

test "config: a full file reads every table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try parseOk(arena.allocator(),
        \\# the project
        \\version = 1
        \\
        \\[runtime]
        \\cwd = "src"   # relative to the root
        \\package_path = ["./?.mah", "./?/init.mah",]
        \\system = ["files", "stdio"]
        \\
        \\[globals]
        \\spawn = "starts a host process"
        \\
        \\[diagnostics]
        \\suppress = ["unused-local"]
        \\
    );
    try testing.expectEqualStrings("src", c.cwd);
    try testing.expectEqual(@as(usize, 2), c.package_path.len);
    try testing.expectEqualStrings("./?/init.mah", c.package_path[1]);
    try testing.expectEqual(system.Groups{ .files = true, .stdio = true }, c.system);
    try testing.expectEqualStrings("spawn", c.globals[0].name);
    try testing.expectEqualStrings("starts a host process", c.globals[0].description);
    try testing.expectEqualStrings("unused-local", c.suppress[0]);
}

test "config: the defaults when a table is absent, and a string escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try parseOk(arena.allocator(), "version = 1\n[globals]\nq = \"say \\\"hi\\\"\"\n");
    try testing.expectEqualStrings(".", c.cwd);
    try testing.expectEqual(default_package_path.len, c.package_path.len);
    try testing.expectEqualStrings("say \"hi\"", c.globals[0].description);
}

test "config: version is required and must be the one this reader knows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const missing = try parseFailure(arena.allocator(), "[runtime]\ncwd = \".\"\n");
    try testing.expectEqual(@as(u32, 1), missing.line);
    try testing.expect(std.mem.indexOf(u8, missing.message, "version = 1") != null);
    const wrong = try parseFailure(arena.allocator(), "version = 2\n");
    try testing.expectEqual(@as(u32, 1), wrong.line);
    try testing.expectEqual(@as(u32, 1), wrong.column);
}

test "config: a mistake is located at its line and column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const unknown_key = try parseFailure(arena.allocator(), "version = 1\n[runtime]\ncwdd = \".\"\n");
    try testing.expectEqual(@as(u32, 3), unknown_key.line);
    try testing.expectEqual(@as(u32, 1), unknown_key.column);
    try testing.expect(std.mem.indexOf(u8, unknown_key.message, "cwdd") != null);

    const unknown_table = try parseFailure(arena.allocator(), "version = 1\n[runtme]\n");
    try testing.expectEqual(@as(u32, 2), unknown_table.line);
    try testing.expectEqual(@as(u32, 2), unknown_table.column);

    const group = try parseFailure(arena.allocator(), "version = 1\n[runtime]\nsystem = [\"disk\"]\n");
    try testing.expectEqual(@as(u32, 3), group.line);
    try testing.expect(std.mem.indexOf(u8, group.message, "disk") != null);
}

test "config: strings, arrays and values that are not allowed are errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(u32, 3), (try parseFailure(a, "version = 1\n[runtime]\ncwd = \"open\n")).line);
    try testing.expect(std.mem.indexOf(u8, (try parseFailure(a, "version = 1\n[runtime]\ncwd = \"a\\qb\"\n")).message, "unknown escape") != null);
    try testing.expectEqual(@as(u32, 3), (try parseFailure(a, "version = 1\n[runtime]\ncwd = 3\n")).line);
    try testing.expectEqual(@as(u32, 3), (try parseFailure(a, "version = 1\n[runtime]\nsystem = [\"files\" \"stdio\"]\n")).line);
    try testing.expectEqual(@as(u32, 3), (try parseFailure(a, "version = 1\n[runtime]\ncwd = \".\" junk\n")).line);
}

test "config: a key set twice is an error, in each table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const twice = try parseFailure(a, "version = 1\n[runtime]\ncwd = \".\"\ncwd = \"x\"\n");
    try testing.expectEqual(@as(u32, 4), twice.line);
    // The same name in two tables is not a repeat: a host global may share a
    // spelling with a runtime key.
    _ = try parseOk(a, "version = 1\n[runtime]\ncwd = \".\"\n[globals]\ncwd = \"a host value\"\n");
}
