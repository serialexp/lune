//! JSON-RPC 2.0 over `Content-Length` framing (doc 74 §5.1) — the LSP's one
//! `std.json` boundary (Rule Z-2). Pure and sans-IO: bytes in, bytes out, so
//! the stdio host and the wasm host both sit on it.
//!
//! Everything above this file sees `Id`, `Incoming` and plain protocol
//! structs; `std.json` stays in here. `std.json` is churny between toolchain
//! pins, so a bump is a one-file fix.

const std = @import("std");
const json = std.json;

/// JSON-RPC and LSP error codes the server uses.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
    request_cancelled = -32800,
    content_modified = -32801,
    server_cancelled = -32802,
};

/// A request id: the spec allows an integer or a string.
pub const Id = union(enum) {
    int: i64,
    string: []const u8,

    pub fn jsonStringify(self: Id, jw: anytype) !void {
        switch (self) {
            .int => |i| try jw.write(i),
            .string => |s| try jw.write(s),
        }
    }

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .int => |x| b == .int and b.int == x,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        };
    }
};

// ---------------------------------------------------------------------------
// Framing

pub const FrameError = error{
    /// The header block exceeded `max_header` before its blank line.
    HeaderTooLong,
    /// A header line was not `Name: value`, or `Content-Length` was missing,
    /// repeated, or not a number.
    BadHeader,
    /// The announced body exceeds `max_body`. The body is skipped; the stream
    /// stays usable.
    BodyTooLong,
    OutOfMemory,
};

/// Incremental `Content-Length` frame reader. Feed it whatever bytes arrive;
/// `next` yields one complete body at a time, however the bytes were split or
/// coalesced. A body slice is valid until the next `feed` or `next`.
pub const FrameReader = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Bytes of `buf` already consumed (the front is compacted lazily).
    start: usize = 0,
    /// Bytes of an oversized body still to be discarded as they arrive.
    skip: usize = 0,
    max_header: usize = default_max_header,
    max_body: usize = default_max_body,

    pub const default_max_header: usize = 8 * 1024;
    pub const default_max_body: usize = 64 * 1024 * 1024;

    pub fn init(gpa: std.mem.Allocator) FrameReader {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FrameReader) void {
        self.buf.deinit(self.gpa);
    }

    pub fn feed(self: *FrameReader, bytes: []const u8) error{OutOfMemory}!void {
        var rest = bytes;
        if (self.skip > 0) {
            const n = @min(self.skip, rest.len);
            self.skip -= n;
            rest = rest[n..];
        }
        if (rest.len == 0) return;
        // Reclaim the consumed front before growing.
        if (self.start > 0 and self.start >= self.buf.items.len / 2) {
            const live = self.buf.items.len - self.start;
            std.mem.copyForwards(u8, self.buf.items[0..live], self.buf.items[self.start..]);
            self.buf.items.len = live;
            self.start = 0;
        }
        try self.buf.appendSlice(self.gpa, rest);
    }

    /// The next complete body, or null if more bytes are needed.
    pub fn next(self: *FrameReader) FrameError!?[]const u8 {
        while (true) {
            // Bytes of an oversized body that were already buffered.
            if (self.skip > 0) {
                const have = self.buf.items.len - self.start;
                const n = @min(self.skip, have);
                self.skip -= n;
                self.start += n;
                if (self.skip > 0) return null;
            }
            const data = self.buf.items[self.start..];
            const end = std.mem.find(u8, data, "\r\n\r\n") orelse {
                if (data.len > self.max_header) {
                    self.start = self.buf.items.len;
                    return error.HeaderTooLong;
                }
                return null;
            };
            if (end > self.max_header) {
                self.start += end + 4;
                return error.HeaderTooLong;
            }
            const len = parseContentLength(data[0..end]) catch |e| {
                // Resynchronise after the bad header block.
                self.start += end + 4;
                return e;
            };
            const body_at = end + 4;
            if (len > self.max_body) {
                self.start += body_at;
                const have = self.buf.items.len - self.start;
                const n = @min(len, have);
                self.start += n;
                self.skip = len - n;
                return error.BodyTooLong;
            }
            if (data.len < body_at + len) return null;
            const body = data[body_at .. body_at + len];
            self.start += body_at + len;
            return body;
        }
    }
};

fn parseContentLength(headers: []const u8) FrameError!usize {
    var found: ?usize = null;
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (found != null) return error.BadHeader;
            found = std.fmt.parseInt(usize, val, 10) catch return error.BadHeader;
        }
        // Content-Type and anything else is ignored (the spec's only others).
    }
    return found orelse error.BadHeader;
}

/// Append `Content-Length: N\r\n\r\n` + `body` to `out`.
pub fn writeFrame(gpa: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) error{OutOfMemory}!void {
    var hdr: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    try out.ensureUnusedCapacity(gpa, h.len + body.len);
    out.appendSliceAssumeCapacity(h);
    out.appendSliceAssumeCapacity(body);
}

// ---------------------------------------------------------------------------
// Messages

/// A decoded incoming message. Everything borrows the arena passed to `parse`.
pub const Incoming = struct {
    /// Present for requests and for responses to our requests.
    id: ?Id = null,
    /// Present for requests and notifications; null for a response.
    method: ?[]const u8 = null,
    params: ?json.Value = null,

    pub fn isRequest(self: Incoming) bool {
        return self.method != null and self.id != null;
    }

    pub fn isNotification(self: Incoming) bool {
        return self.method != null and self.id == null;
    }
};

pub const ParseError = error{
    /// The body was not valid JSON.
    InvalidJson,
    /// Valid JSON but not a JSON-RPC message. `id` carries the request id if
    /// one could be read, so the error response can address it.
    InvalidRequest,
    OutOfMemory,
};

/// Parse one body. On `InvalidRequest`, `id_out` receives the id if there was
/// a readable one.
pub fn parse(arena: std.mem.Allocator, body: []const u8, id_out: *?Id) ParseError!Incoming {
    id_out.* = null;
    const root = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (root != .object) return error.InvalidRequest;
    const obj = root.object;

    var msg: Incoming = .{};
    if (obj.get("id")) |idv| switch (idv) {
        .integer => |i| msg.id = .{ .int = i },
        .string => |s| msg.id = .{ .string = s },
        .null => {},
        else => return error.InvalidRequest,
    };
    id_out.* = msg.id;

    if (obj.get("method")) |mv| {
        if (mv != .string) return error.InvalidRequest;
        msg.method = mv.string;
    } else if (obj.get("result") == null and obj.get("error") == null) {
        return error.InvalidRequest;
    }
    msg.params = obj.get("params");
    return msg;
}

/// Decode `params` (or any value) into `T`, ignoring unknown fields.
pub fn decode(comptime T: type, arena: std.mem.Allocator, value: json.Value) error{ InvalidParams, OutOfMemory }!T {
    return json.parseFromValueLeaky(T, arena, value, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
}

/// An opaque JSON value (a message's `params`), so callers never name
/// `std.json`.
pub const Value = json.Value;

/// Decode a request's `params` into `T`. Absent params decode as `{}`, so a
/// `T` whose fields all have defaults accepts a request with no params.
pub fn decodeParams(comptime T: type, arena: std.mem.Allocator, params: ?Value) error{ InvalidParams, OutOfMemory }!T {
    const v = params orelse json.Value{ .object = json.ObjectMap.empty };
    return decode(T, arena, v);
}

/// A JSON value rendered back to text — for tests and for the places a
/// handler passes an opaque `params` through.
pub fn valueToString(arena: std.mem.Allocator, value: json.Value) error{OutOfMemory}![]u8 {
    return json.Stringify.valueAlloc(arena, value, .{});
}

// ---------------------------------------------------------------------------
// Encoding. Each returns a body allocated from `a` (an arena, per message).

// The envelope is written field by field, not as a struct, because the two
// null rules differ: a `result` (or `id`) of null must be written — `shutdown`
// answers `null`, and an unreadable request id is `null` — while optional
// fields *inside* a result (`Hover.range`, say) are omitted when null.

pub fn encodeResult(a: std.mem.Allocator, id: Id, result: anytype) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    putResult(&jw, id, result) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn putResult(jw: *json.Stringify, id: Id, result: anytype) json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("result");
    try jw.write(result);
    try jw.endObject();
}

pub fn encodeError(a: std.mem.Allocator, id: ?Id, code: ErrorCode, message: []const u8) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    putError(&jw, id, code, message) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn putError(jw: *json.Stringify, id: ?Id, code: ErrorCode, message: []const u8) json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    try jw.write(id); // null when the request id could not be read
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(@intFromEnum(code));
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    try jw.endObject();
}

pub fn encodeNotification(a: std.mem.Allocator, method: []const u8, params: anytype) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
    putNotification(&jw, method, params) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn putNotification(jw: *json.Stringify, method: []const u8, params: anytype) json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write(method);
    try jw.objectField("params");
    try jw.write(params);
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn drain(r: *FrameReader, out: *std.ArrayList([]u8)) !void {
    while (try r.next()) |b| try out.append(testing.allocator, try testing.allocator.dupe(u8, b));
}

fn freeAll(list: *std.ArrayList([]u8)) void {
    for (list.items) |b| testing.allocator.free(b);
    list.deinit(testing.allocator);
}

test "frames: one message, split at every byte, and several in one read" {
    const a = "Content-Length: 7\r\n\r\n{\"a\":1}";
    const b = "Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}";
    const both = a ++ b;
    // Byte by byte.
    {
        var r = FrameReader.init(testing.allocator);
        defer r.deinit();
        var got: std.ArrayList([]u8) = .empty;
        defer freeAll(&got);
        for (both) |c| {
            try r.feed(&.{c});
            try drain(&r, &got);
        }
        try testing.expectEqual(@as(usize, 2), got.items.len);
        try testing.expectEqualStrings("{\"a\":1}", got.items[0]);
        try testing.expectEqualStrings("{}", got.items[1]);
    }
    // Coalesced in a single feed.
    {
        var r = FrameReader.init(testing.allocator);
        defer r.deinit();
        var got: std.ArrayList([]u8) = .empty;
        defer freeAll(&got);
        try r.feed(both);
        try drain(&r, &got);
        try testing.expectEqual(@as(usize, 2), got.items.len);
    }
}

test "frames: header names are case-insensitive; the length counts bytes" {
    var r = FrameReader.init(testing.allocator);
    defer r.deinit();
    // "é" is two bytes.
    try r.feed("content-length: 4\r\n\r\n\"\xc3\xa9\"");
    const body = (try r.next()).?;
    try testing.expectEqualStrings("\"\xc3\xa9\"", body);
    try testing.expectEqual(@as(?[]const u8, null), try r.next());
}

test "frames: bad and oversize input is reported and the stream recovers" {
    var r = FrameReader.init(testing.allocator);
    defer r.deinit();
    r.max_header = 64;
    r.max_body = 8;

    // Missing Content-Length.
    try r.feed("X-Other: 1\r\n\r\n");
    try testing.expectError(error.BadHeader, r.next());
    // Not a number.
    try r.feed("Content-Length: abc\r\n\r\n");
    try testing.expectError(error.BadHeader, r.next());
    // Duplicate Content-Length.
    try r.feed("Content-Length: 1\r\nContent-Length: 1\r\n\r\n");
    try testing.expectError(error.BadHeader, r.next());
    // No colon.
    try r.feed("garbage\r\n\r\n");
    try testing.expectError(error.BadHeader, r.next());
    // A body over the limit is skipped, even when it arrives later in pieces,
    // and the message after it is still read.
    try r.feed("Content-Length: 20\r\n\r\n01234");
    try testing.expectError(error.BodyTooLong, r.next());
    try r.feed("56789012345");
    try testing.expectEqual(@as(?[]const u8, null), try r.next());
    try r.feed("6789Content-Length: 2\r\n\r\n{}");
    const ok = (try r.next()).?;
    try testing.expectEqualStrings("{}", ok);
    // A header block that never ends.
    const junk: [80]u8 = @splat('x');
    try r.feed("Content-Length: 1");
    try r.feed(&junk);
    try testing.expectError(error.HeaderTooLong, r.next());
}

test "frames: an arithmetic-overflowing length is a bad header, not a crash" {
    var r = FrameReader.init(testing.allocator);
    defer r.deinit();
    try r.feed("Content-Length: 99999999999999999999999999\r\n\r\n");
    try testing.expectError(error.BadHeader, r.next());
}

test "writeFrame produces what the reader reads" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeFrame(testing.allocator, &out, "{\"k\":\"\xc3\xa9\"}");
    try testing.expectEqualStrings("Content-Length: 10\r\n\r\n{\"k\":\"\xc3\xa9\"}", out.items);
    var r = FrameReader.init(testing.allocator);
    defer r.deinit();
    try r.feed(out.items);
    try testing.expectEqualStrings("{\"k\":\"\xc3\xa9\"}", (try r.next()).?);
}

test "parse: requests, notifications, responses, string and integer ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var id: ?Id = null;

    const req = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"m\",\"params\":{\"x\":1}}", &id);
    try testing.expect(req.isRequest());
    try testing.expectEqual(@as(i64, 7), req.id.?.int);
    try testing.expectEqualStrings("m", req.method.?);

    const sreq = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"m\"}", &id);
    try testing.expectEqualStrings("abc", sreq.id.?.string);
    try testing.expect(sreq.params == null);

    const note = try parse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"n\"}", &id);
    try testing.expect(note.isNotification());

    const resp = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}", &id);
    try testing.expect(resp.method == null);
    try testing.expectEqual(@as(i64, 1), resp.id.?.int);
}

test "parse: malformed input maps to the right error and keeps a readable id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var id: ?Id = null;

    try testing.expectError(error.InvalidJson, parse(a, "{not json", &id));
    try testing.expect(id == null);
    try testing.expectError(error.InvalidRequest, parse(a, "[1,2]", &id));
    try testing.expectError(error.InvalidRequest, parse(a, "{\"id\":5,\"method\":12}", &id));
    try testing.expectEqual(@as(i64, 5), id.?.int);
    try testing.expectError(error.InvalidRequest, parse(a, "{\"id\":true,\"method\":\"m\"}", &id));
    try testing.expectError(error.InvalidRequest, parse(a, "{\"id\":9}", &id));
}

test "encode: results, errors, notifications; ids round trip as given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const R = struct { ok: bool, name: ?[]const u8 = null };
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}",
        try encodeResult(a, .{ .int = 3 }, R{ .ok = true }),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"result\":null}",
        try encodeResult(a, .{ .string = "x" }, @as(?u8, null)),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"bad\"}}",
        try encodeError(a, null, .parse_error, "bad"),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32601,\"message\":\"nope\"}}",
        try encodeError(a, .{ .int = 4 }, .method_not_found, "nope"),
    );
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":3}}",
        try encodeNotification(a, "window/logMessage", struct { type: u8 }{ .type = 3 }),
    );
}

test "decode: ignores unknown fields, rejects wrong types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const P = struct { uri: []const u8, version: ?i64 = null };
    const v = try json.parseFromSliceLeaky(json.Value, a, "{\"uri\":\"file:///a\",\"extra\":[1]}", .{});
    const p = try decode(P, a, v);
    try testing.expectEqualStrings("file:///a", p.uri);
    try testing.expect(p.version == null);
    const bad = try json.parseFromSliceLeaky(json.Value, a, "{\"uri\":5}", .{});
    try testing.expectError(error.InvalidParams, decode(P, a, bad));
}
