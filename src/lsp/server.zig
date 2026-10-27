//! The sans-IO server core (doc 74 §5.2).
//!
//! One decoded message in, zero or more encoded messages out. The core owns no
//! thread, socket, clock or file: the host passes the time in and drains the
//! `Outbox`, so the same code runs behind stdio (`host_stdio.zig`) and in the
//! browser's wasm worker. The host also owns the debounce timer — it asks
//! `nextDeadline()` and calls `tick()` when that time arrives — and answers
//! `Hooks.cancelled` from whatever cancellation channel it has.
//!
//! P0 scope: lifecycle, capability negotiation, the document store, and the
//! debounce/publish pipeline. The diagnostics it publishes are empty until the
//! frontend work of doc 74 P1/P2 lands (§6).

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const documents = @import("documents.zig");
const position = @import("position.zig");

/// Analysis runs this long after the last change...
pub const debounce_ms: u64 = 50;
/// ...but never later than this after the first unanalysed change, so a long
/// typing burst still gets feedback (doc 74 §5.3).
pub const max_debounce_ms: u64 = 250;

pub const server_name = "mahina";

/// What the host can tell the core. Defaults suit a host with no cancellation.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// Whether the client has cancelled request `id` (`$/cancelRequest`).
    /// Asked once, just before a request is dispatched.
    cancelled: *const fn (ctx: ?*anyopaque, id: jsonrpc.Id) bool = neverCancelled,

    fn neverCancelled(_: ?*anyopaque, _: jsonrpc.Id) bool {
        return false;
    }
};

/// The messages one call produced. Bodies live in `arena` and stay valid until
/// `reset`; the host frames and writes them, then resets.
pub const Outbox = struct {
    arena: std.heap.ArenaAllocator,
    msgs: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Outbox {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Outbox) void {
        self.arena.deinit();
    }

    pub fn reset(self: *Outbox) void {
        self.msgs = .empty;
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn messages(self: *const Outbox) []const []const u8 {
        return self.msgs.items;
    }

    fn push(self: *Outbox, body: []const u8) error{OutOfMemory}!void {
        try self.msgs.append(self.arena.allocator(), body);
    }

    fn result(self: *Outbox, id: jsonrpc.Id, value: anytype) error{OutOfMemory}!void {
        try self.push(try jsonrpc.encodeResult(self.arena.allocator(), id, value));
    }

    fn fail(self: *Outbox, id: ?jsonrpc.Id, code: jsonrpc.ErrorCode, message: []const u8) error{OutOfMemory}!void {
        try self.push(try jsonrpc.encodeError(self.arena.allocator(), id, code, message));
    }

    fn notify(self: *Outbox, method: []const u8, params: anytype) error{OutOfMemory}!void {
        try self.push(try jsonrpc.encodeNotification(self.arena.allocator(), method, params));
    }

    fn log(self: *Outbox, level: u8, message: []const u8) error{OutOfMemory}!void {
        try self.notify("window/logMessage", protocol.LogMessageParams{ .type = level, .message = message });
    }
};

pub const State = enum { uninitialized, running, shutdown, exited };

pub const Server = struct {
    gpa: std.mem.Allocator,
    hooks: Hooks,
    state: State = .uninitialized,
    /// Set by `exit`: 0 after a `shutdown`, 1 without one.
    exit_code: ?u8 = null,
    /// The unit of `character` in every position (negotiated at `initialize`).
    encoding: position.Encoding = .utf16,
    docs: documents.Store,

    pub const Error = error{OutOfMemory};

    pub fn init(gpa: std.mem.Allocator, hooks: Hooks) Server {
        return .{ .gpa = gpa, .hooks = hooks, .docs = documents.Store.init(gpa) };
    }

    pub fn deinit(self: *Server) void {
        self.docs.deinit();
    }

    /// Whether the process should now stop (`exit` arrived).
    pub fn isDone(self: *const Server) bool {
        return self.state == .exited;
    }

    /// The host saw end-of-input without an `exit`.
    pub fn inputClosed(self: *Server) void {
        if (self.exit_code == null) self.exit_code = 1;
        self.state = .exited;
    }

    // ---- message entry -----------------------------------------------------

    /// Handle one message body. `now_ms` is the host's monotonic clock.
    pub fn handle(self: *Server, now_ms: u64, body: []const u8, out: *Outbox) Error!void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var bad_id: ?jsonrpc.Id = null;
        const msg = jsonrpc.parse(a, body, &bad_id) catch |e| switch (e) {
            error.InvalidJson => return out.fail(null, .parse_error, "invalid JSON"),
            error.InvalidRequest => return out.fail(bad_id, .invalid_request, "not a JSON-RPC message"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        // A response to a request of ours: P0 sends none.
        const method = msg.method orelse return;
        if (msg.id) |id| {
            try self.request(now_ms, a, id, method, msg.params, out);
        } else {
            try self.notification(now_ms, a, method, msg.params, out);
        }
    }

    fn request(
        self: *Server,
        now_ms: u64,
        a: std.mem.Allocator,
        id: jsonrpc.Id,
        method: []const u8,
        params: ?jsonrpc.Value,
        out: *Outbox,
    ) Error!void {
        _ = now_ms;
        if (self.state == .exited) return;
        if (std.mem.eql(u8, method, "initialize")) {
            if (self.state != .uninitialized) return out.fail(id, .invalid_request, "already initialized");
            return self.initialize(a, id, params, out);
        }
        switch (self.state) {
            .uninitialized => return out.fail(id, .server_not_initialized, "the server is not initialized"),
            .shutdown => return out.fail(id, .invalid_request, "the server is shutting down"),
            else => {},
        }
        if (self.hooks.cancelled(self.hooks.ctx, id)) {
            return out.fail(id, .request_cancelled, "request cancelled");
        }
        if (std.mem.eql(u8, method, "shutdown")) {
            self.state = .shutdown;
            return out.result(id, @as(?u8, null));
        }
        const msg = try std.fmt.allocPrint(a, "method not found: {s}", .{method});
        return out.fail(id, .method_not_found, msg);
    }

    fn notification(
        self: *Server,
        now_ms: u64,
        a: std.mem.Allocator,
        method: []const u8,
        params: ?jsonrpc.Value,
        out: *Outbox,
    ) Error!void {
        if (std.mem.eql(u8, method, "exit")) {
            self.exit_code = if (self.state == .shutdown) 0 else 1;
            self.state = .exited;
            return;
        }
        if (self.state != .running) return;

        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const p = jsonrpc.decodeParams(protocol.DidOpenTextDocumentParams, a, params) catch |e|
                return self.badNotification(a, method, e, out);
            const td = p.textDocument;
            const doc = self.docs.open(td.uri, td.version, td.text) catch |e| return self.docError(a, td.uri, e, out);
            markDirty(doc, now_ms);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            const p = jsonrpc.decodeParams(protocol.DidChangeTextDocumentParams, a, params) catch |e|
                return self.badNotification(a, method, e, out);
            const doc = self.docs.get(p.textDocument.uri) orelse {
                const m = try std.fmt.allocPrint(a, "didChange for a document that is not open: {s}", .{p.textDocument.uri});
                return out.log(protocol.MessageType.warning, m);
            };
            for (p.contentChanges) |c| {
                doc.applyChange(self.gpa, self.encoding, c.range, c.text) catch |e|
                    return self.docError(a, p.textDocument.uri, e, out);
            }
            doc.version = p.textDocument.version;
            markDirty(doc, now_ms);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const p = jsonrpc.decodeParams(protocol.DidCloseTextDocumentParams, a, params) catch |e|
                return self.badNotification(a, method, e, out);
            const uri = p.textDocument.uri;
            if (self.docs.get(uri) == null) return;
            self.docs.close(uri);
            // We published for this document; take our diagnostics back.
            try out.notify("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{
                .uri = uri,
                .diagnostics = &.{},
            });
        }
        // `initialized`, `$/cancelRequest` (the host reads it), `$/setTrace`
        // and anything else: nothing to do.
    }

    fn badNotification(self: *Server, a: std.mem.Allocator, method: []const u8, err: anyerror, out: *Outbox) Error!void {
        _ = self;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const m = try std.fmt.allocPrint(a, "ignored {s}: malformed params", .{method});
        try out.log(protocol.MessageType.warning, m);
    }

    fn docError(self: *Server, a: std.mem.Allocator, uri: []const u8, err: documents.Document.Error, out: *Outbox) Error!void {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TextTooLong => {
                // Too large to hold: stop tracking it rather than serve stale text.
                self.docs.close(uri);
                const m = try std.fmt.allocPrint(a, "document too large, no longer tracked: {s}", .{uri});
                try out.log(protocol.MessageType.@"error", m);
            },
        }
    }

    fn initialize(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.InitializeParams, a, params) catch |e| switch (e) {
            error.InvalidParams => return out.fail(id, .invalid_params, "malformed initialize params"),
            error.OutOfMemory => return error.OutOfMemory,
        };
        var chosen: ?[]const u8 = null;
        if (p.capabilities.general) |g| if (g.positionEncodings) |offered| {
            if (offers(offered, "utf-8")) {
                chosen = "utf-8";
            } else if (offered.len > 0) {
                chosen = "utf-16"; // mandatory for every client
            }
        };
        self.encoding = if (chosen != null and std.mem.eql(u8, chosen.?, "utf-8")) .utf8 else .utf16;
        self.state = .running;
        try out.result(id, protocol.InitializeResult{
            .capabilities = .{ .positionEncoding = chosen },
            .serverInfo = .{ .name = server_name },
        });
    }

    fn offers(list: []const []const u8, name: []const u8) bool {
        for (list) |e| if (std.mem.eql(u8, e, name)) return true;
        return false;
    }

    // ---- the debounce / publish pipeline -----------------------------------

    fn markDirty(doc: *documents.Document, now_ms: u64) void {
        if (doc.dirty_since == null) doc.dirty_since = now_ms;
        doc.last_change = now_ms;
    }

    fn dueAt(doc: *const documents.Document) ?u64 {
        const since = doc.dirty_since orelse return null;
        return @min(doc.last_change + debounce_ms, since + max_debounce_ms);
    }

    /// When the host should next call `tick`, in its own clock; null if nothing
    /// is waiting.
    pub fn nextDeadline(self: *const Server) ?u64 {
        var best: ?u64 = null;
        var it = self.docs.map.valueIterator();
        while (it.next()) |d| {
            const due = dueAt(d.*) orelse continue;
            if (best == null or due < best.?) best = due;
        }
        return best;
    }

    /// Analyse every document whose debounce has run out.
    pub fn tick(self: *Server, now_ms: u64, out: *Outbox) Error!void {
        if (self.state != .running) return;
        var it = self.docs.map.valueIterator();
        while (it.next()) |d| {
            const due = dueAt(d.*) orelse continue;
            if (due <= now_ms) try self.analyse(d.*, out);
        }
    }

    /// Analyse one document now and publish what it found. The frontend is not
    /// wired in yet (doc 74 P1/P2), so this publishes a clean bill for the
    /// current version — which exercises the version/debounce plumbing the real
    /// diagnostics will ride on.
    fn analyse(self: *Server, doc: *documents.Document, out: *Outbox) Error!void {
        _ = self;
        doc.dirty_since = null;
        try out.notify("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{
            .uri = doc.uri,
            .version = doc.version,
            .diagnostics = &.{},
        });
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const json = std.json;

/// Drives a Server like a client would and parses what comes back.
const Harness = struct {
    server: Server,
    out: Outbox,
    arena: std.heap.ArenaAllocator,
    cancel_id: ?i64 = null,

    fn init(hooks: Hooks) Harness {
        return .{
            .server = Server.init(testing.allocator, hooks),
            .out = Outbox.init(testing.allocator),
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Harness) void {
        self.server.deinit();
        self.out.deinit();
        self.arena.deinit();
    }

    /// Send `body`, return the outgoing messages parsed.
    fn send(self: *Harness, now: u64, body: []const u8) ![]json.Value {
        self.out.reset();
        try self.server.handle(now, body, &self.out);
        return self.parsed();
    }

    fn tick(self: *Harness, now: u64) ![]json.Value {
        self.out.reset();
        try self.server.tick(now, &self.out);
        return self.parsed();
    }

    fn parsed(self: *Harness) ![]json.Value {
        const a = self.arena.allocator();
        const msgs = self.out.messages();
        const vals = try a.alloc(json.Value, msgs.len);
        for (msgs, 0..) |m, i| vals[i] = try json.parseFromSliceLeaky(json.Value, a, m, .{});
        return vals;
    }

    fn open(self: *Harness) !void {
        const msgs = try self.send(0,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        );
        try testing.expectEqual(@as(usize, 1), msgs.len);
        _ = try self.send(0,
            \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        );
    }
};

fn errorCode(v: json.Value) i64 {
    return v.object.get("error").?.object.get("code").?.integer;
}

test "initialize: utf-8 is chosen when offered, utf-16 otherwise; sync is incremental" {
    var h = Harness.init(.{});
    defer h.deinit();
    const r = try h.send(0,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-16","utf-8"]}}}}
    );
    const caps = r[0].object.get("result").?.object.get("capabilities").?.object;
    try testing.expectEqualStrings("utf-8", caps.get("positionEncoding").?.string);
    try testing.expectEqual(@as(i64, 2), caps.get("textDocumentSync").?.object.get("change").?.integer);
    try testing.expectEqual(position.Encoding.utf8, h.server.encoding);

    var h2 = Harness.init(.{});
    defer h2.deinit();
    const r2 = try h2.send(0,
        \\{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-32","utf-16"]}}}}
    );
    const res2 = r2[0].object.get("result").?.object;
    try testing.expectEqualStrings("utf-16", res2.get("capabilities").?.object.get("positionEncoding").?.string);
    try testing.expectEqualStrings("a", r2[0].object.get("id").?.string);

    // No list at all: UTF-16 implied, field omitted.
    var h3 = Harness.init(.{});
    defer h3.deinit();
    const r3 = try h3.send(0,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
    );
    try testing.expect(r3[0].object.get("result").?.object.get("capabilities").?.object.get("positionEncoding") == null);
    try testing.expectEqual(position.Encoding.utf16, h3.server.encoding);
}

test "lifecycle: requests before initialize, double initialize, shutdown, exit codes" {
    var h = Harness.init(.{});
    defer h.deinit();
    var r = try h.send(0,
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{}}
    );
    try testing.expectEqual(@as(i64, -32002), errorCode(r[0]));
    // Notifications before initialize are dropped, not errors.
    r = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"u","text":"x"}}}
    );
    try testing.expectEqual(@as(usize, 0), r.len);
    try testing.expectEqual(@as(usize, 0), h.server.docs.count());

    try h.open();
    r = try h.send(0,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}
    );
    try testing.expectEqual(@as(i64, -32600), errorCode(r[0]));
    r = try h.send(0,
        \\{"jsonrpc":"2.0","id":3,"method":"no/suchMethod"}
    );
    try testing.expectEqual(@as(i64, -32601), errorCode(r[0]));
    r = try h.send(0,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
    );
    try testing.expect(r[0].object.get("result").? == .null);
    try testing.expect(r[0].object.get("error") == null);
    r = try h.send(0,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{}}
    );
    try testing.expectEqual(@as(i64, -32600), errorCode(r[0]));
    try testing.expect(!h.server.isDone());
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expect(h.server.isDone());
    try testing.expectEqual(@as(?u8, 0), h.server.exit_code);
}

test "exit without shutdown, and EOF, are status 1" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expectEqual(@as(?u8, 1), h.server.exit_code);

    var h2 = Harness.init(.{});
    defer h2.deinit();
    try h2.open();
    h2.server.inputClosed();
    try testing.expect(h2.server.isDone());
    try testing.expectEqual(@as(?u8, 1), h2.server.exit_code);
}

test "malformed messages: parse error has a null id, invalid request keeps its id" {
    var h = Harness.init(.{});
    defer h.deinit();
    var r = try h.send(0, "{oops");
    try testing.expectEqual(@as(i64, -32700), errorCode(r[0]));
    try testing.expect(r[0].object.get("id").? == .null);
    r = try h.send(0,
        \\{"jsonrpc":"2.0","id":9,"method":42}
    );
    try testing.expectEqual(@as(i64, -32600), errorCode(r[0]));
    try testing.expectEqual(@as(i64, 9), r[0].object.get("id").?.integer);
    // A response from the client is ignored.
    r = try h.send(0,
        \\{"jsonrpc":"2.0","id":1,"result":null}
    );
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "cancellation: a cancelled request still gets a response" {
    const Flag = struct {
        id: i64,
        fn cancelled(ctx: ?*anyopaque, id: jsonrpc.Id) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return id == .int and id.int == self.id;
        }
    };
    var flag = Flag{ .id = 7 };
    var h = Harness.init(.{ .ctx = &flag, .cancelled = Flag.cancelled });
    defer h.deinit();
    try h.open();
    var r = try h.send(0,
        \\{"jsonrpc":"2.0","id":7,"method":"shutdown"}
    );
    try testing.expectEqual(@as(i64, -32800), errorCode(r[0]));
    try testing.expectEqual(State.running, h.server.state); // cancelled, so not performed
    r = try h.send(0,
        \\{"jsonrpc":"2.0","id":8,"method":"shutdown"}
    );
    try testing.expect(r[0].object.get("result") != null);
}

test "documents: open, incremental change, close; the client's version is kept" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.mah","languageId":"mahina","version":1,"text":"local x = 1\n"}}}
    );
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.mah","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":10},"end":{"line":0,"character":11}},"text":"42"},{"text":"return 1\n"}]}}
    );
    const d = h.server.docs.get("file:///a.mah").?;
    try testing.expectEqual(@as(i64, 2), d.version);
    // The second change (no range) replaced everything, applied in order.
    try testing.expectEqualStrings("return 1\n", d.source());

    const r = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///a.mah"}}}
    );
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", r[0].object.get("method").?.string);
    try testing.expectEqual(@as(usize, 0), r[0].object.get("params").?.object.get("diagnostics").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), h.server.docs.count());
    try testing.expect(h.server.nextDeadline() == null);
}

test "documents: bad params and unknown documents are logged, never fatal" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    var r = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":5}}}
    );
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("window/logMessage", r[0].object.get("method").?.string);
    r = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"nope","version":1},"contentChanges":[]}}
    );
    try testing.expectEqualStrings("window/logMessage", r[0].object.get("method").?.string);
    // A close for a document never opened is silent.
    r = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"nope"}}}
    );
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "debounce: 50 ms after the last change, never later than 250 ms after the first" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    _ = try h.send(1000,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"u","version":1,"text":"a"}}}
    );
    try testing.expectEqual(@as(?u64, 1050), h.server.nextDeadline());
    try testing.expectEqual(@as(usize, 0), (try h.tick(1049)).len);

    // A change inside the window pushes the deadline out.
    _ = try h.send(1040,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"u","version":2},"contentChanges":[{"text":"ab"}]}}
    );
    try testing.expectEqual(@as(?u64, 1090), h.server.nextDeadline());

    // Changes keep arriving every 40 ms: the cap (first change + 250) wins.
    var t: u64 = 1080;
    var v: i64 = 3;
    while (t < 1240) : (t += 40) {
        var buf: [160]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":"u","version":{d}}},"contentChanges":[{{"text":"x"}}]}}}}
        , .{v});
        _ = try h.send(t, body);
        v += 1;
    }
    try testing.expectEqual(@as(?u64, 1250), h.server.nextDeadline());
    try testing.expectEqual(@as(usize, 0), (try h.tick(1249)).len);
    const r = try h.tick(1250);
    try testing.expectEqual(@as(usize, 1), r.len);
    const p = r[0].object.get("params").?.object;
    try testing.expectEqualStrings("u", p.get("uri").?.string);
    try testing.expectEqual(v - 1, p.get("version").?.integer);
    // Published: nothing is waiting any more.
    try testing.expect(h.server.nextDeadline() == null);
    try testing.expectEqual(@as(usize, 0), (try h.tick(9999)).len);
}

test "debounce: documents are independent" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"a","version":1,"text":""}}}
    );
    _ = try h.send(30,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"b","version":1,"text":""}}}
    );
    var r = try h.tick(50);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("a", r[0].object.get("params").?.object.get("uri").?.string);
    try testing.expectEqual(@as(?u64, 80), h.server.nextDeadline());
    r = try h.tick(80);
    try testing.expectEqualStrings("b", r[0].object.get("params").?.object.get("uri").?.string);
}
