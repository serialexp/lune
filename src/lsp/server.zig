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
const analysis_mod = @import("analysis.zig");
const position = @import("position.zig");
const ast = @import("../ast.zig");
const navigation = @import("navigation.zig");
const syntax = @import("syntax.zig");
const tokens = @import("tokens.zig");
const completion = @import("completion.zig");
const library = @import("library.zig");
const modules = @import("modules.zig");
const exports = @import("exports.zig");
const module_cache = @import("module_cache.zig");
const symbol_index = @import("symbol_index.zig");
const uri_mod = @import("uri.zig");
const workspace = @import("workspace.zig");
const config = @import("config.zig");

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
    /// Whether more input is already waiting. An analysis that is under way
    /// when this turns true is abandoned between its phases: what it would
    /// publish is about to be out of date, and the document stays dirty so it
    /// is analysed again once the waiting messages are in.
    input_pending: *const fn (ctx: ?*anyopaque) bool = nothingPending,

    fn neverCancelled(_: ?*anyopaque, _: jsonrpc.Id) bool {
        return false;
    }

    fn nothingPending(_: ?*anyopaque) bool {
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

    fn request(self: *Outbox, id: jsonrpc.Id, method: []const u8, params: anytype) error{OutOfMemory}!void {
        try self.push(try jsonrpc.encodeRequest(self.arena.allocator(), id, method, params));
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
    /// The global names the host installs, so they are not flagged as
    /// undefined. Set by the host after `init`.
    known_globals: []const []const u8 = &.{},
    /// The host's disk, for `mahina.toml` and `require` (doc 74 §7.4). Set by
    /// the host after `init`; a host without one (the browser) leaves it null,
    /// and then only built-in modules and open documents resolve.
    files: ?workspace.Files = null,
    /// The workspace folders and their configs.
    ws: workspace.Workspace,
    /// The client registers file watchers on request, so a `mahina.toml`
    /// edit is seen (`workspace/didChangeWatchedFiles`).
    watches_files: bool = false,
    /// The exports of the modules `require` reached, per path (P6d).
    module_cache: module_cache.Cache,
    /// Every folder's functions and methods, for `workspace/symbol` (P6e).
    symbols: symbol_index.Index,

    pub const Error = error{OutOfMemory};

    /// The diagnostic code of a literal `require` that resolves nowhere.
    pub const unresolved_require_code = "unresolved-require";

    pub fn init(gpa: std.mem.Allocator, hooks: Hooks) Server {
        return .{
            .gpa = gpa,
            .hooks = hooks,
            .docs = documents.Store.init(gpa),
            .ws = workspace.Workspace.init(gpa),
            .module_cache = module_cache.Cache.init(gpa),
            .symbols = symbol_index.Index.init(gpa),
        };
    }

    pub fn deinit(self: *Server) void {
        self.docs.deinit();
        self.ws.deinit();
        self.module_cache.deinit();
        self.symbols.deinit();
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
        // A response to a request of ours (`client/registerCapability`): only
        // a refusal needs saying.
        const method = msg.method orelse {
            if (msg.failure) |why| {
                try out.log(protocol.MessageType.warning, try std.fmt.allocPrint(a, "the client refused a request: {s}", .{why}));
            }
            return;
        };
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
        if (std.mem.eql(u8, method, "textDocument/definition")) return self.definition(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/references")) return self.references(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/documentHighlight")) return self.highlights(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/prepareRename")) return self.prepareRename(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/rename")) return self.rename(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/completion")) return self.complete(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/hover")) return self.hover(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/signatureHelp")) return self.signatureHelp(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) return self.semanticTokens(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return self.documentSymbols(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/foldingRange")) return self.foldingRanges(a, id, params, out);
        if (std.mem.eql(u8, method, "textDocument/selectionRange")) return self.selectionRanges(a, id, params, out);
        if (std.mem.eql(u8, method, "workspace/symbol")) return self.workspaceSymbols(a, id, params, out);
        const msg = try std.fmt.allocPrint(a, "method not found: {s}", .{method});
        return out.fail(id, .method_not_found, msg);
    }

    // ---- navigation and completion (doc 74 §7.2) ---------------------------

    /// What a position-based request works on: the document's analysis of its
    /// current text, and the cursor as a byte offset into it.
    const Cursor = struct {
        doc: *documents.Document,
        an: *const analysis_mod.Analysis,
        index: *const position.LineIndex,
        offset: u32,
        /// What governs the document: its folder's config, or the defaults.
        settings: workspace.Settings,
    };

    /// Find the document and make sure its analysis is of the text as it is now
    /// (an edit still inside its debounce is analysed here, ahead of the
    /// timer). Answers the request with an error and returns null when it
    /// cannot be served. The offset is left at 0 for the caller to set.
    fn analysed(self: *Server, id: jsonrpc.Id, uri: []const u8, out: *Outbox) Error!?Cursor {
        const doc = self.docs.get(uri) orelse {
            try out.fail(id, .invalid_params, "the document is not open");
            return null;
        };
        if (doc.currentAnalysis() == null) try self.analyse(doc, out);
        const an = doc.currentAnalysis() orelse {
            // Newer input is waiting, or there is no tree; the client asks again.
            try out.fail(id, .content_modified, "the document changed");
            return null;
        };
        const index = doc.lineIndex(self.gpa) catch return error.OutOfMemory;
        const settings = try self.settingsOf(out.arena.allocator(), doc.uri);
        return .{ .doc = doc, .an = an, .index = index, .offset = 0, .settings = settings };
    }

    /// The settings for the document at `uri`, allocated in `a`.
    fn settingsOf(self: *const Server, a: std.mem.Allocator, uri: []const u8) Error!workspace.Settings {
        return self.ws.settingsFor(a, try uri_mod.toPath(a, uri), self.known_globals);
    }

    /// A probe that sees the open documents ahead of the host's disk. Its paths
    /// live in `a`.
    fn overlay(self: *const Server, a: std.mem.Allocator) Error!workspace.Overlay {
        var paths: std.ArrayList([]const u8) = .empty;
        var it = self.docs.map.valueIterator();
        while (it.next()) |d| {
            const path = (try uri_mod.toPath(a, d.*.uri)) orelse continue;
            try paths.append(a, try std.fs.path.resolveAllocPosix(a, &.{path}));
        }
        return .{ .open_paths = paths.items, .files = self.files };
    }

    /// The file a literal `require` at the cursor loads, as a URI.
    fn requireTarget(self: *const Server, a: std.mem.Allocator, c: Cursor) Error!?[]const u8 {
        const cwd = c.settings.cwd orelse return null;
        const site = modules.siteAt(try modules.sites(a, c.an), c.offset) orelse return null;
        const name = site.name orelse return null;
        var ov = try self.overlay(a);
        return switch (try modules.resolve(a, name, cwd, c.settings.package_path, ov.probe())) {
            .file => |path| try uri_mod.fromPath(a, path),
            .builtin, .missing => null,
        };
    }

    /// The open document whose file is `path` (resolved, as `overlay` has it).
    fn openAt(self: *const Server, a: std.mem.Allocator, path: []const u8) Error!?*documents.Document {
        var it = self.docs.map.valueIterator();
        while (it.next()) |d| {
            const p = (try uri_mod.toPath(a, d.*.uri)) orelse continue;
            if (std.mem.eql(u8, try std.fs.path.resolveAllocPosix(a, &.{p}), path)) return d.*;
        }
        return null;
    }

    /// A member access on a module local at the cursor, the file it reaches,
    /// and that module's exports (valid until the cache is next asked).
    const ModuleAccess = struct {
        access: exports.Access,
        path: []const u8,
        members: []const module_cache.Member,
    };

    /// The module behind `m.` or `m:` at the cursor, read from its open
    /// document ahead of the disk.
    fn moduleAccess(self: *Server, a: std.mem.Allocator, c: Cursor) Error!?ModuleAccess {
        const access = (try exports.accessAt(a, c.an, c.offset)) orelse return null;
        const cwd = c.settings.cwd orelse return null;
        var ov = try self.overlay(a);
        const path = switch (try modules.resolve(a, access.module, cwd, c.settings.package_path, ov.probe())) {
            .file => |file| file,
            .builtin, .missing => return null,
        };
        const text = if (try self.openAt(a, path)) |d| d.source() else blk: {
            const fs = self.files orelse return null;
            break :blk fs.read(fs.ctx, a, path) orelse return null;
        };
        return .{ .access = access, .path = path, .members = try self.module_cache.get(path, text, self.encoding) };
    }

    /// `analysed`, with the cursor position converted to a byte offset.
    fn cursor(self: *Server, id: jsonrpc.Id, uri: []const u8, pos: position.Position, out: *Outbox) Error!?Cursor {
        var c = (try self.analysed(id, uri, out)) orelse return null;
        c.offset = c.index.toOffset(c.an.source, pos, self.encoding);
        return c;
    }

    fn definition(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.TextDocumentPositionParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        // On the name in `require("a.b")`: the module's file, from its start.
        if (try self.requireTarget(out.arena.allocator(), c)) |target| {
            const top: position.Position = .{ .line = 0, .character = 0 };
            return out.result(id, protocol.Location{ .uri = target, .range = .{ .start = top, .end = top } });
        }
        // On the `f` of `m.f`, for a module local `m`: where the module writes it.
        if (try self.moduleAccess(a, c)) |m| {
            const name = c.an.source[m.access.member.start..m.access.member.end];
            for (m.members) |x| {
                if (!std.mem.eql(u8, x.name, name)) continue;
                const target = try uri_mod.fromPath(out.arena.allocator(), m.path);
                return out.result(id, protocol.Location{ .uri = target, .range = x.range });
            }
            return out.result(id, @as(?u8, null));
        }
        const occ = navigation.occurrenceAt(c.an, c.offset) orelse return out.result(id, @as(?u8, null));
        const span = navigation.definition(c.an, occ) orelse return out.result(id, @as(?u8, null));
        try out.result(id, protocol.Location{
            .uri = c.doc.uri,
            .range = c.index.toRange(c.an.source, span.start, span.end, self.encoding),
        });
    }

    fn references(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.ReferenceParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        const occ = navigation.occurrenceAt(c.an, c.offset) orelse return out.result(id, @as(?u8, null));
        const occs = try navigation.references(a, c.an, occ.binding, p.context.includeDeclaration);
        const oa = out.arena.allocator();
        const list = try oa.alloc(protocol.Location, occs.len);
        var cur = position.Cursor.init(c.index, c.an.source, self.encoding);
        for (occs, list) |o, *slot| {
            const start = cur.positionOf(o.span.start);
            slot.* = .{ .uri = c.doc.uri, .range = .{ .start = start, .end = cur.positionOf(o.span.end) } };
        }
        try out.result(id, list);
    }

    fn highlights(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.TextDocumentPositionParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        const occ = navigation.occurrenceAt(c.an, c.offset) orelse return out.result(id, @as(?u8, null));
        const occs = try navigation.references(a, c.an, occ.binding, true);
        const list = try out.arena.allocator().alloc(protocol.DocumentHighlight, occs.len);
        var cur = position.Cursor.init(c.index, c.an.source, self.encoding);
        for (occs, list) |o, *slot| {
            const start = cur.positionOf(o.span.start);
            slot.* = .{
                .range = .{ .start = start, .end = cur.positionOf(o.span.end) },
                .kind = if (o.access == .read) protocol.DocumentHighlightKind.read else protocol.DocumentHighlightKind.write,
            };
        }
        try out.result(id, list);
    }

    fn prepareRename(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.TextDocumentPositionParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        const occ = navigation.occurrenceAt(c.an, c.offset) orelse return out.result(id, @as(?u8, null));
        const name = c.an.res.binding(occ.binding).name;
        // The binding's own name is always a valid new spelling, so only the
        // refusals about the binding itself can come back.
        switch (navigation.checkRename(c.an, c.settings.known_globals, occ.binding, &.{}, name)) {
            .ok => {},
            .refused => |r| return out.fail(id, .request_failed, try refusalMessage(a, c, r.reason, null, name, name)),
        }
        try out.result(id, protocol.PrepareRenameResult{
            .range = c.index.toRange(c.an.source, occ.span.start, occ.span.end, self.encoding),
            .placeholder = name,
        });
    }

    fn rename(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.RenameParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        const occ = navigation.occurrenceAt(c.an, c.offset) orelse
            return out.fail(id, .request_failed, "there is no name to rename here");
        const b = c.an.res.binding(occ.binding);
        const occs = try navigation.references(a, c.an, occ.binding, true);
        switch (navigation.checkRename(c.an, c.settings.known_globals, occ.binding, occs, p.newName)) {
            .ok => {},
            .refused => |r| return out.fail(id, .request_failed, try refusalMessage(a, c, r.reason, r.at, b.name, p.newName)),
        }
        const oa = out.arena.allocator();
        const edits = try oa.alloc(protocol.TextEdit, if (std.mem.eql(u8, b.name, p.newName)) 0 else occs.len);
        var cur = position.Cursor.init(c.index, c.an.source, self.encoding);
        for (edits, occs[0..edits.len]) |*slot, o| {
            const start = cur.positionOf(o.span.start);
            slot.* = .{ .range = .{ .start = start, .end = cur.positionOf(o.span.end) }, .newText = p.newName };
        }
        if (b.kind == .global and edits.len > 0) {
            const message = if (c.an.res.damaged.items.len > 0)
                try std.fmt.allocPrint(oa, "{s} is a global: only this file was renamed, and text the parser could not read was left alone.", .{b.name})
            else
                try std.fmt.allocPrint(oa, "{s} is a global: only this file was renamed; other files that use it are unchanged.", .{b.name});
            try out.notify("window/showMessage", protocol.LogMessageParams{
                .type = protocol.MessageType.warning,
                .message = message,
            });
        }
        try out.result(id, protocol.WorkspaceEdit{ .uri = c.doc.uri, .edits = edits });
    }

    fn refusalMessage(
        a: std.mem.Allocator,
        c: Cursor,
        reason: navigation.Refusal,
        at: ?ast.Span,
        old: []const u8,
        new: []const u8,
    ) std.mem.Allocator.Error![]const u8 {
        const line: u32 = if (at) |s| c.index.lineOf(s.start) + 1 else 0;
        return switch (reason) {
            .not_a_name => "there is no name to rename here",
            .implicit_self => "'self' is implicit here: there is no parameter to rename",
            .builtin => std.fmt.allocPrint(a, "'{s}' is installed by the host and cannot be renamed", .{old}),
            .invalid_name => std.fmt.allocPrint(a, "'{s}' is not a valid name", .{new}),
            .keyword => std.fmt.allocPrint(a, "'{s}' is a keyword", .{new}),
            .would_capture => std.fmt.allocPrint(a, "renaming to '{s}' would capture the use of '{s}' at line {d}, where another '{s}' is in scope", .{ new, old, line, new }),
            .would_be_captured => std.fmt.allocPrint(a, "the use of '{s}' at line {d} is inside the scope of '{s}' and would start meaning it", .{ new, line, old }),
        };
    }

    fn complete(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.TextDocumentPositionParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        if (try self.moduleAccess(a, c)) |m| return memberCompletion(id, m, out);
        const items = try completion.complete(a, c.an, c.settings.known_globals, c.settings.system, c.offset);
        const oa = out.arena.allocator();
        const list = try oa.alloc(protocol.CompletionItem, items.len);
        for (items, list) |it, *slot| {
            slot.* = .{
                .label = it.label,
                .kind = switch (it.kind) {
                    .variable => protocol.CompletionItemKind.variable,
                    .function => protocol.CompletionItemKind.function,
                    .keyword => protocol.CompletionItemKind.keyword,
                },
                .detail = it.detail,
                .sortText = try std.fmt.allocPrint(oa, "{d}{s}", .{ it.rank, it.label }),
            };
        }
        try out.result(id, protocol.CompletionList{ .items = list });
    }

    /// After `m.` on a module local: the module's exports. After `m:`, only
    /// what can be called.
    fn memberCompletion(id: jsonrpc.Id, m: ModuleAccess, out: *Outbox) Error!void {
        const oa = out.arena.allocator();
        var list: std.ArrayList(protocol.CompletionItem) = .empty;
        for (m.members) |x| {
            if (m.access.method and x.kind == .value) continue;
            try list.append(oa, .{
                .label = x.name,
                .kind = switch (x.kind) {
                    .function => protocol.CompletionItemKind.function,
                    .method => protocol.CompletionItemKind.method,
                    .value => protocol.CompletionItemKind.field,
                },
                .detail = x.signature orelse try std.fmt.allocPrint(oa, "field of {s}", .{m.access.module}),
            });
        }
        try out.result(id, protocol.CompletionList{ .items = list.items });
    }

    /// The library name under the cursor, as Markdown (doc 74 §7.3).
    fn hover(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.TextDocumentPositionParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        const named = (try library.hoverAt(a, c.an, c.offset)) orelse return out.result(id, @as(?u8, null));
        const oa = out.arena.allocator();
        try out.result(id, protocol.Hover{
            .contents = .{ .kind = protocol.MarkupKind.markdown, .value = try library.markdown(oa, named.entry, c.settings.system) },
            .range = c.index.toRange(c.an.source, named.span.start, named.span.end, self.encoding),
        });
    }

    /// The signature of the library call the cursor is in, with the argument it
    /// is at (doc 74 §7.3).
    fn signatureHelp(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.TextDocumentPositionParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.cursor(id, p.textDocument.uri, p.position, out)) orelse return;
        const call = (try library.callAt(a, c.an, c.offset)) orelse return out.result(id, @as(?u8, null));
        const oa = out.arena.allocator();
        const spans = try library.paramSpans(oa, call.entry.signature);
        const parameters = try oa.alloc(protocol.ParameterInformation, spans.len);
        for (spans, parameters) |s, *slot| slot.* = .{ .label = s };
        const signatures = try oa.alloc(protocol.SignatureInformation, 1);
        signatures[0] = .{
            .label = call.entry.signature,
            .documentation = .{ .kind = protocol.MarkupKind.markdown, .value = call.entry.description },
            .parameters = parameters,
        };
        try out.result(id, protocol.SignatureHelp{ .signatures = signatures, .activeParameter = call.active });
    }

    // ---- syntax: tokens, outline, folds, selections (doc 74 §7.1) ----------

    /// LSP's delta encoding: each token is `deltaLine, deltaStart, length, type,
    /// modifiers`, where `deltaStart` is relative to the previous token's start
    /// only when they share a line. A token spanning lines goes out as one piece
    /// per line, each clipped to its line.
    fn semanticTokens(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.SemanticTokensParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.analysed(id, p.textDocument.uri, out)) orelse return;
        const toks = try tokens.collect(a, c.an, c.settings.known_globals);
        var data: std.ArrayList(u32) = .empty;
        var cur = position.Cursor.init(c.index, c.an.source, self.encoding);
        var prev_line: u32 = 0;
        var prev_start: u32 = 0;
        for (toks) |t| {
            var s = t.span.start;
            while (true) {
                const from = cur.positionOf(s);
                const e = @min(t.span.end, c.index.lineEnd(c.an.source, from.line));
                if (e > s) {
                    const to = cur.positionOf(e);
                    const delta_start = if (from.line == prev_line) from.character - prev_start else from.character;
                    try data.appendSlice(a, &[_]u32{
                        from.line - prev_line,
                        delta_start,
                        to.character - from.character,
                        @intFromEnum(t.kind),
                        t.modifiers,
                    });
                    prev_line = from.line;
                    prev_start = from.character;
                }
                if (e >= t.span.end) break;
                s = c.index.lineStart(from.line + 1);
            }
        }
        try out.result(id, protocol.SemanticTokens{ .data = data.items });
    }

    fn documentSymbols(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.DocumentSymbolParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.analysed(id, p.textDocument.uri, out)) orelse return;
        const syms = try syntax.symbols(a, c.an.tree.root);
        try out.result(id, try self.symbolList(a, c.index, c.an.source, syms));
    }

    /// The most `workspace/symbol` answers with; a client narrows the query.
    pub const max_workspace_symbols = 500;

    fn workspaceSymbols(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.WorkspaceSymbolParams, a, params) catch |e| return self.badParams(id, e, out);
        try self.refreshSymbols(a);
        const hits = try self.symbols.search(a, p.query, max_workspace_symbols);
        const list = try a.alloc(protocol.SymbolInformation, hits.len);
        for (hits, list) |h, *slot| slot.* = .{
            .name = h.symbol.name,
            .kind = symbolKind(h.symbol.kind),
            .location = .{ .uri = h.uri, .range = h.symbol.range },
            .containerName = h.symbol.container,
        };
        try out.result(id, list);
    }

    /// Bring the symbol index up to date with the open documents and every
    /// folder's files.
    pub fn refreshSymbols(self: *Server, a: std.mem.Allocator) Error!void {
        const roots = try a.alloc(symbol_index.Root, self.ws.folders.items.len);
        for (self.ws.folders.items, roots) |f, *r| r.* = .{
            .path = f.path,
            .extensions = try symbol_index.extensionsOf(a, f.config.package_path),
        };
        var opened: std.ArrayList(symbol_index.Open) = .empty;
        var it = self.docs.map.valueIterator();
        while (it.next()) |d| {
            const path = try uri_mod.toPath(a, d.*.uri);
            try opened.append(a, .{
                .uri = d.*.uri,
                .path = if (path) |q| try std.fs.path.resolveAllocPosix(a, &.{q}) else null,
                .text = d.*.text.items,
            });
        }
        try self.symbols.refresh(a, roots, self.files, opened.items, self.encoding);
    }

    fn symbolKind(kind: syntax.Kind) u8 {
        return switch (kind) {
            .function => protocol.SymbolKind.function,
            .method => protocol.SymbolKind.method,
            .variable => protocol.SymbolKind.variable,
            .field => protocol.SymbolKind.field,
            .object => protocol.SymbolKind.object,
        };
    }

    fn symbolList(
        self: *Server,
        a: std.mem.Allocator,
        index: *const position.LineIndex,
        text: []const u8,
        syms: []const syntax.Symbol,
    ) Error![]const protocol.DocumentSymbol {
        const list = try a.alloc(protocol.DocumentSymbol, syms.len);
        for (syms, list) |s, *slot| {
            slot.* = .{
                .name = s.name,
                .kind = symbolKind(s.kind),
                .range = index.toRange(text, s.range.start, s.range.end, self.encoding),
                .selectionRange = index.toRange(text, s.selection.start, s.selection.end, self.encoding),
                .children = if (s.children.len == 0) null else try self.symbolList(a, index, text, s.children),
            };
        }
        return list;
    }

    fn foldingRanges(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.FoldingRangeParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.analysed(id, p.textDocument.uri, out)) orelse return;
        var list: std.ArrayList(protocol.FoldingRange) = .empty;
        for (try syntax.nodes(a, c.an.tree.root)) |n| {
            if (n.foldable) try appendFold(&list, a, c.index, n.span, null);
        }
        for (c.an.comments) |cm| {
            if (cm.block) try appendFold(&list, a, c.index, .{ .start = cm.start, .end = cm.end }, "comment");
        }
        try out.result(id, list.items);
    }

    /// A fold over `span`. The closing line stays visible (the `end` or `}`),
    /// so the fold runs from the line after the opening one to the line before
    /// the closing one, and nothing is folded when no line lies between.
    fn appendFold(
        list: *std.ArrayList(protocol.FoldingRange),
        a: std.mem.Allocator,
        index: *const position.LineIndex,
        span: ast.Span,
        kind: ?[]const u8,
    ) Error!void {
        if (span.end <= span.start) return;
        const first = index.lineOf(span.start);
        const last = index.lineOf(span.end - 1);
        if (last <= first + 1) return;
        try list.append(a, .{ .startLine = first, .endLine = last - 1, .kind = kind });
    }

    fn selectionRanges(self: *Server, a: std.mem.Allocator, id: jsonrpc.Id, params: ?jsonrpc.Value, out: *Outbox) Error!void {
        const p = jsonrpc.decodeParams(protocol.SelectionRangeParams, a, params) catch |e| return self.badParams(id, e, out);
        const c = (try self.analysed(id, p.textDocument.uri, out)) orelse return;
        const ns = try syntax.nodes(a, c.an.tree.root);
        const results = try a.alloc(protocol.SelectionRange, p.positions.len);
        for (p.positions, results) |pos, *slot| {
            const offset = c.index.toOffset(c.an.source, pos, self.encoding);
            // Every range around the position: the file, each node, each name.
            var spans: std.ArrayList(ast.Span) = .empty;
            try spans.append(a, .{ .start = 0, .end = @intCast(c.an.source.len) });
            for (ns) |n| {
                if (encloses(n.span, offset)) try spans.append(a, n.span);
            }
            for (c.an.res.occurrences.items) |o| {
                if (encloses(o.span, offset)) try spans.append(a, o.span);
            }
            slot.* = try selectionChain(a, c.index, c.an.source, spans.items, self.encoding);
        }
        try out.result(id, results);
    }

    fn encloses(span: ast.Span, offset: u32) bool {
        return span.end > span.start and span.start <= offset and offset <= span.end;
    }

    /// The chain for one position, innermost first. `spans` holds every range
    /// around it, in any order; equal ranges collapse to one step.
    fn selectionChain(
        a: std.mem.Allocator,
        index: *const position.LineIndex,
        text: []const u8,
        spans: []ast.Span,
        enc: position.Encoding,
    ) Error!protocol.SelectionRange {
        // Largest first, so each range is built before the one inside it.
        std.mem.sort(ast.Span, spans, {}, struct {
            fn larger(_: void, x: ast.Span, y: ast.Span) bool {
                const lx = x.end - x.start;
                const ly = y.end - y.start;
                if (lx != ly) return lx > ly;
                return x.start < y.start;
            }
        }.larger);
        var parent: ?*const protocol.SelectionRange = null;
        for (spans, 0..) |s, i| {
            if (i > 0 and s.start == spans[i - 1].start and s.end == spans[i - 1].end) continue;
            const node = try a.create(protocol.SelectionRange);
            node.* = .{ .range = index.toRange(text, s.start, s.end, enc), .parent = parent };
            parent = node;
        }
        return parent.?.*;
    }

    fn badParams(self: *Server, id: jsonrpc.Id, err: anyerror, out: *Outbox) Error!void {
        _ = self;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try out.fail(id, .invalid_params, "malformed params");
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
        } else if (std.mem.eql(u8, method, "workspace/didChangeWorkspaceFolders")) {
            const p = jsonrpc.decodeParams(protocol.DidChangeWorkspaceFoldersParams, a, params) catch |e|
                return self.badNotification(a, method, e, out);
            for (p.event.removed) |f| try self.removeFolder(a, f.uri, out);
            for (p.event.added) |f| try self.addFolder(a, f.uri, out);
            // A document may now fall under another folder's config.
            var it = self.docs.map.valueIterator();
            while (it.next()) |d| markDirty(d.*, now_ms);
        } else if (std.mem.eql(u8, method, "initialized")) {
            try self.watchConfigs(out);
        } else if (std.mem.eql(u8, method, "workspace/didChangeWatchedFiles")) {
            const p = jsonrpc.decodeParams(protocol.DidChangeWatchedFilesParams, a, params) catch |e|
                return self.badNotification(a, method, e, out);
            if (try self.reloadConfigs(a, p.changes, out)) {
                var it = self.docs.map.valueIterator();
                while (it.next()) |d| markDirty(d.*, now_ms);
            }
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
        // `$/cancelRequest` (the host reads it), `$/setTrace` and anything
        // else: nothing to do.
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
        if (p.capabilities.workspace) |w| if (w.didChangeWatchedFiles) |d| {
            self.watches_files = d.dynamicRegistration orelse false;
        };
        self.state = .running;
        try out.result(id, protocol.InitializeResult{
            .capabilities = .{
                .positionEncoding = chosen,
                .semanticTokensProvider = .{ .legend = .{ .tokenTypes = &tokens.token_types, .tokenModifiers = &tokens.token_modifiers } },
            },
            .serverInfo = .{ .name = server_name },
        });
        // After the response: a folder's config may publish diagnostics, and
        // nothing may precede the answer to `initialize`. The editor's options
        // come first, since every folder applies them.
        try self.applyOptions(a, jsonrpc.member(params, "initializationOptions"), out);
        if (p.workspaceFolders) |folders| {
            for (folders) |f| try self.addFolder(a, f.uri, out);
        } else if (p.rootUri) |root| {
            try self.addFolder(a, root, out);
        }
    }

    // ---- workspace folders and their config (doc 74 §7.4) ------------------

    /// Take the editor's `initializationOptions` over every folder's
    /// `mahina.toml`. Options that are refused are reported and ignored as a
    /// whole, since half of a setting applied is harder to see than none.
    fn applyOptions(self: *Server, a: std.mem.Allocator, raw: ?jsonrpc.Value, out: *Outbox) Error!void {
        const value = raw orelse return;
        const oa = self.ws.options_arena.allocator();
        const opts = switch (try jsonrpc.decodeStrict(?protocol.InitializationOptions, oa, value)) {
            .ok => |o| o orelse return,
            .bad => |why| return refuseOptions(a, why, out),
        };
        var o: config.Overrides = .{};
        if (opts.runtime) |r| {
            o.cwd = r.cwd;
            o.package_path = r.package_path;
            if (r.system) |names| switch (config.groupsOf(names)) {
                .ok => |g| o.system = g,
                .unknown => |n| return refuseOptions(a, try std.fmt.allocPrint(a, "unknown system group '{s}' in runtime.system", .{n}), out),
            };
        }
        if (opts.globals) |gs| {
            const list = try oa.alloc(config.Global, gs.len);
            for (gs, list) |g, *slot| slot.* = .{ .name = g.name, .description = g.value };
            o.globals = list;
        }
        if (opts.diagnostics) |d| if (d.suppress) |s| {
            o.suppress = s;
        };
        try self.ws.setOverrides(o, self.known_globals);
    }

    /// The id of the server's one `client/registerCapability` request.
    pub const watch_registration = "mahina/watch-config";

    /// Ask the client to report changes to any `mahina.toml`, when it can
    /// (dynamic registration is the only way LSP offers). A client that
    /// cannot is told, once, what a config edit then needs, if there is a
    /// folder on a disk to have one.
    fn watchConfigs(self: *Server, out: *Outbox) Error!void {
        if (!self.watches_files) {
            if (self.files == null or self.ws.folders.items.len == 0) return;
            return out.log(protocol.MessageType.info, "the client cannot watch files: an edit to mahina.toml takes effect when its folder is re-added or the server restarts");
        }
        const watchers = [_]protocol.FileSystemWatcher{.{ .globPattern = "**/" ++ workspace.config_name }};
        const registrations = [_]protocol.Registration{.{
            .id = watch_registration,
            .method = "workspace/didChangeWatchedFiles",
            .registerOptions = .{ .watchers = &watchers },
        }};
        try out.request(.{ .string = watch_registration }, "client/registerCapability", protocol.RegistrationParams{ .registrations = &registrations });
    }

    /// Read again the config of every folder whose `mahina.toml` changed,
    /// appeared or went. Returns whether any did, so documents are analysed
    /// again under the new settings.
    fn reloadConfigs(self: *Server, a: std.mem.Allocator, changes: []const protocol.FileEvent, out: *Outbox) Error!bool {
        var uris: std.ArrayList([]const u8) = .empty;
        for (changes) |c| {
            const path = (try uri_mod.toPath(a, c.uri)) orelse continue;
            if (!std.mem.eql(u8, std.fs.path.basenamePosix(path), workspace.config_name)) continue;
            const resolved = try std.fs.path.resolveAllocPosix(a, &.{path});
            for (self.ws.folders.items) |f| {
                if (!std.mem.eql(u8, try f.configPath(a), resolved)) continue;
                // `addFolder` replaces the folder, so its uri is copied first.
                try uris.append(a, try a.dupe(u8, f.uri));
            }
        }
        for (uris.items) |u| try self.addFolder(a, u, out);
        return uris.items.len > 0;
    }

    fn refuseOptions(a: std.mem.Allocator, why: []const u8, out: *Outbox) Error!void {
        try out.notify("window/showMessage", protocol.LogMessageParams{
            .type = protocol.MessageType.warning,
            .message = try std.fmt.allocPrint(a, "mahina: initializationOptions ignored: {s}", .{why}),
        });
    }

    /// Add a workspace folder, read its `mahina.toml`, and publish what is
    /// wrong with it (or clear what was).
    fn addFolder(self: *Server, a: std.mem.Allocator, folder_uri: []const u8, out: *Outbox) Error!void {
        const path = (try uri_mod.toPath(a, folder_uri)) orelse {
            const m = try std.fmt.allocPrint(a, "workspace folder is not a local directory, so it has no mahina.toml: {s}", .{folder_uri});
            return out.log(protocol.MessageType.info, m);
        };
        const had_failure = if (try self.ws.find(a, path)) |old| old.failure != null else false;
        const f = try self.ws.add(folder_uri, path, self.files, self.known_globals);
        if (f.failure != null or had_failure) try self.publishConfig(a, f, out);
    }

    /// Drop a workspace folder, taking back the diagnostics on its config.
    fn removeFolder(self: *Server, a: std.mem.Allocator, folder_uri: []const u8, out: *Outbox) Error!void {
        const path = (try uri_mod.toPath(a, folder_uri)) orelse return;
        const f = (try self.ws.find(a, path)) orelse return;
        if (f.failure != null) {
            try out.notify("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{
                .uri = try uri_mod.fromPath(out.arena.allocator(), try f.configPath(a)),
                .diagnostics = &.{},
            });
        }
        _ = try self.ws.remove(path);
    }

    /// A rejected `mahina.toml` as one error, from the column it names to the
    /// end of that line; an accepted one as no diagnostics.
    fn publishConfig(self: *Server, a: std.mem.Allocator, f: *const workspace.Folder, out: *Outbox) Error!void {
        const oa = out.arena.allocator();
        const cfg_uri = try uri_mod.fromPath(oa, try f.configPath(a));
        const why = f.failure orelse return out.notify("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{
            .uri = cfg_uri,
            .diagnostics = &.{},
        });
        const text = f.config_text orelse "";
        const index = position.LineIndex.build(a, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TextTooLong => return out.log(protocol.MessageType.@"error", why.message),
        };
        const line = @min(why.line - 1, index.lineCount() - 1);
        const line_end = index.lineEnd(text, line);
        const start = @min(index.lineStart(line) + why.column - 1, line_end);
        const one = try oa.alloc(protocol.Diagnostic, 1);
        one[0] = .{
            .range = index.toRange(text, start, line_end, self.encoding),
            .severity = protocol.DiagnosticSeverity.@"error",
            .code = "config",
            .source = server_name,
            .message = try oa.dupe(u8, why.message),
        };
        try out.notify("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{ .uri = cfg_uri, .diagnostics = one });
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

    /// Analyse one document now and publish what it found. A newer edit already
    /// waiting makes the work pointless, so the host's `input_pending` is asked
    /// between phases and the document stays dirty if it says yes.
    fn analyse(self: *Server, doc: *documents.Document, out: *Outbox) Error!void {
        const a = out.arena.allocator();
        const settings = try self.settingsOf(a, doc.uri);
        const abandon: analysis_mod.Abandon = .{ .ctx = self.hooks.ctx, .stale = self.hooks.input_pending };
        const result = analysis_mod.analyse(self.gpa, doc.source(), settings.known_globals, abandon) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Abandoned => return, // stays dirty: `tick` comes round again
            error.Unparseable => {
                doc.dirty_since = null;
                try out.log(protocol.MessageType.warning, "analysis incomplete: the parser produced no tree");
                return;
            },
        };
        doc.setAnalysis(result);
        doc.dirty_since = null;
        const an = &doc.analysis.?;
        if (an.incomplete) try out.log(protocol.MessageType.warning, "analysis incomplete: out of memory while collecting diagnostics");

        const index = doc.lineIndex(self.gpa) catch return error.OutOfMemory;
        var list: std.ArrayList(protocol.Diagnostic) = try .initCapacity(a, an.diagnostics.len);
        for (an.diagnostics) |d| {
            if (suppressed(settings, d.code.id())) continue;
            var related: ?[]const protocol.DiagnosticRelatedInformation = null;
            if (d.related) |r| {
                const one = try a.alloc(protocol.DiagnosticRelatedInformation, 1);
                one[0] = .{
                    .location = .{ .uri = doc.uri, .range = index.toRange(an.source, r.start, r.end, self.encoding) },
                    .message = r.label,
                };
                related = one;
            }
            list.appendAssumeCapacity(.{
                .range = index.toRange(an.source, d.start, d.end, self.encoding),
                .severity = switch (d.severity) {
                    .@"error" => protocol.DiagnosticSeverity.@"error",
                    .warning => protocol.DiagnosticSeverity.warning,
                },
                .code = d.code.id(),
                .source = server_name,
                .message = d.message,
                .relatedInformation = related,
            });
        }
        try self.requireDiagnostics(a, an, index, settings, &list);
        try out.notify("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{
            .uri = doc.uri,
            .version = doc.version,
            .diagnostics = list.items,
        });
    }

    fn suppressed(settings: workspace.Settings, code: []const u8) bool {
        for (settings.suppress) |s| {
            if (std.mem.eql(u8, s, code)) return true;
        }
        return false;
    }

    /// A literal `require` that resolves nowhere, as information: the runtime
    /// may still find it through a searcher or preload entry the host installs,
    /// which the server cannot see (doc 74 §7.4). With no disk to look at, a
    /// miss says nothing, so there is none.
    fn requireDiagnostics(
        self: *const Server,
        a: std.mem.Allocator,
        an: *const analysis_mod.Analysis,
        index: *const position.LineIndex,
        settings: workspace.Settings,
        list: *std.ArrayList(protocol.Diagnostic),
    ) Error!void {
        if (self.files == null) return;
        const cwd = settings.cwd orelse return;
        if (suppressed(settings, unresolved_require_code)) return;
        var ov = try self.overlay(a);
        for (try modules.unresolved(a, an, cwd, settings.package_path, ov.probe())) |m| {
            var msg: std.ArrayList(u8) = .empty;
            try msg.print(a, "module '{s}' not found:", .{m.name});
            for (m.tried) |t| try msg.print(a, "\n\tno file '{s}'", .{t});
            try list.append(a, .{
                .range = index.toRange(an.source, m.span.start, m.span.end, self.encoding),
                .severity = protocol.DiagnosticSeverity.information,
                .code = unresolved_require_code,
                .source = server_name,
                .message = msg.items,
            });
        }
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

/// Open `text` as document `u` at version 1 and run its analysis.
fn analyseText(h: *Harness, text: []const u8) !json.Value {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"u","version":1,"text":{f}}}}}}}
    , .{std.json.fmt(text, .{})});
    _ = try h.send(0, body);
    const r = try h.tick(50);
    try testing.expectEqual(@as(usize, 1), r.len);
    return r[0].object.get("params").?;
}

test "diagnostics: a syntax error is published with its code, range and the opener it names" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const params = try analyseText(&h, "if x then");
    const diags = params.object.get("diagnostics").?.array.items;
    try testing.expectEqual(@as(usize, 1), diags.len);
    const d = diags[0].object;
    try testing.expectEqualStrings("E0109", d.get("code").?.string);
    try testing.expectEqualStrings("mahina", d.get("source").?.string);
    try testing.expectEqual(@as(i64, 1), d.get("severity").?.integer);
    const start = d.get("range").?.object.get("start").?.object;
    try testing.expectEqual(@as(i64, 9), start.get("character").?.integer); // the end of input
    const rel = d.get("relatedInformation").?.array.items[0].object;
    try testing.expectEqualStrings("'if' opened here", rel.get("message").?.string);
    const loc = rel.get("location").?.object;
    try testing.expectEqualStrings("u", loc.get("uri").?.string);
    try testing.expectEqual(@as(i64, 2), loc.get("range").?.object.get("end").?.object.get("character").?.integer);
}

test "diagnostics: a lint is a warning, and the names the host installs are not flagged" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{"print"};
    try h.open();
    const params = try analyseText(&h, "print(nope)");
    const diags = params.object.get("diagnostics").?.array.items;
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(@as(i64, 2), diags[0].object.get("severity").?.integer);
    try testing.expectEqualStrings("W0001", diags[0].object.get("code").?.string);
    try testing.expect(std.mem.indexOf(u8, diags[0].object.get("message").?.string, "nope") != null);
}

test "diagnostics: columns follow the negotiated encoding" {
    const src = "local s = \"\u{1F600}\" +";
    // UTF-16 (the default): the emoji is two code units.
    {
        var h = Harness.init(.{});
        defer h.deinit();
        try h.open();
        const params = try analyseText(&h, src);
        const start = params.object.get("diagnostics").?.array.items[0].object.get("range").?.object.get("start").?.object;
        try testing.expectEqual(@as(i64, 16), start.get("character").?.integer);
    }
    // UTF-8, when the client offers it: four bytes.
    {
        var h = Harness.init(.{});
        defer h.deinit();
        _ = try h.send(0,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}}
        );
        const params = try analyseText(&h, src);
        const start = params.object.get("diagnostics").?.array.items[0].object.get("range").?.object.get("start").?.object;
        try testing.expectEqual(@as(i64, 18), start.get("character").?.integer);
    }
}

test "diagnostics: fixing the text clears them, and the version travels with the set" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    _ = try analyseText(&h, "x = =");
    _ = try h.send(100,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"u","version":2},"contentChanges":[{"text":"local x = 1"}]}}
    );
    const r = try h.tick(150);
    try testing.expectEqual(@as(usize, 1), r.len);
    const p = r[0].object.get("params").?.object;
    try testing.expectEqual(@as(i64, 2), p.get("version").?.integer);
    try testing.expectEqual(@as(usize, 0), p.get("diagnostics").?.array.items.len);
}

test "diagnostics: input already waiting abandons the analysis, which runs again later" {
    const Pending = struct {
        waiting: bool = true,
        fn check(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.waiting;
        }
    };
    var pending = Pending{};
    var h = Harness.init(.{ .ctx = &pending, .input_pending = Pending.check });
    defer h.deinit();
    try h.open();
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"u","version":1,"text":"local x = 1"}}}
    );
    try testing.expectEqual(@as(usize, 0), (try h.tick(50)).len);
    // Still dirty, so the host's timer fires again.
    try testing.expect(h.server.nextDeadline() != null);
    pending.waiting = false;
    const r = try h.tick(60);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expect(h.server.nextDeadline() == null);
}

// ---- navigation and completion over the wire ----

/// Open `text` as document "u" (version 1) without ticking, then send one
/// position request and return its response.
fn askAt(h: *Harness, text: []const u8, method: []const u8, line: u32, ch: u32, extra: []const u8) !json.Value {
    var buf: [1024]u8 = undefined;
    const open = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"u","version":1,"text":{f}}}}}}}
    , .{std.json.fmt(text, .{})});
    _ = try h.send(0, open);
    var buf2: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf2,
        \\{{"jsonrpc":"2.0","id":7,"method":"{s}","params":{{"textDocument":{{"uri":"u"}},"position":{{"line":{d},"character":{d}}}{s}}}}}
    , .{ method, line, ch, extra });
    const r = try h.send(1, req);
    // The edit was not yet due, so the request itself analysed the document and
    // published: the response is the last message.
    return r[r.len - 1];
}

test "definition: answers from the text as it is, ahead of the debounce" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const r = try askAt(&h, "local abc = 1\nprint(abc)", "textDocument/definition", 1, 7, "");
    const loc = r.object.get("result").?.object;
    try testing.expectEqualStrings("u", loc.get("uri").?.string);
    const range = loc.get("range").?.object;
    try testing.expectEqual(@as(i64, 0), range.get("start").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 6), range.get("start").?.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 9), range.get("end").?.object.get("character").?.integer);
}

test "definition: nothing under the cursor, or for a name nothing defines, is null" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{"print"};
    try h.open();
    const r = try askAt(&h, "print(1)", "textDocument/definition", 0, 2, "");
    try testing.expect(r.object.get("result").? == .null);
}

test "references: every use, the declaration on request, columns in the negotiated unit" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    // `é` is two bytes but one UTF-16 unit, so the `a` in `print(a)` is at
    // column 32 although it is at byte 33.
    const text = "local s = \"é\" local a = 1 print(a)";
    const with = try askAt(&h, text, "textDocument/references", 0, 32, ",\"context\":{\"includeDeclaration\":true}");
    try testing.expectEqual(@as(usize, 2), with.object.get("result").?.array.items.len);
    const last = with.object.get("result").?.array.items[1].object.get("range").?.object;
    try testing.expectEqual(@as(i64, 32), last.get("start").?.object.get("character").?.integer);
}

test "references: includeDeclaration false leaves the declaring name out" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const r = try askAt(&h, "local a = 1\nprint(a)", "textDocument/references", 1, 6, ",\"context\":{\"includeDeclaration\":false}");
    try testing.expectEqual(@as(usize, 1), r.object.get("result").?.array.items.len);
}

test "documentHighlight: reads and writes" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const r = try askAt(&h, "local a = 1\na = a + 1", "textDocument/documentHighlight", 1, 0, "");
    const items = r.object.get("result").?.array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(i64, 3), items[0].object.get("kind").?.integer); // the declaration
    try testing.expectEqual(@as(i64, 3), items[1].object.get("kind").?.integer); // `a =`
    try testing.expectEqual(@as(i64, 2), items[2].object.get("kind").?.integer); // `= a`
}

test "rename: edits every occurrence, in the form clients read" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const r = try askAt(&h, "local a = 1\nprint(a)", "textDocument/rename", 1, 6, ",\"newName\":\"count\"");
    const changes = r.object.get("result").?.object.get("changes").?.object;
    const edits = changes.get("u").?.array.items;
    try testing.expectEqual(@as(usize, 2), edits.len);
    try testing.expectEqualStrings("count", edits[0].object.get("newText").?.string);
    try testing.expectEqual(@as(i64, 6), edits[1].object.get("range").?.object.get("start").?.object.get("character").?.integer);
}

test "rename: a refusal is an error response that says why" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{"print"};
    try h.open();
    const text = "local a = 1\ndo local b = 2 print(a, b) end";
    const capture = try askAt(&h, text, "textDocument/rename", 0, 6, ",\"newName\":\"b\"");
    try testing.expectEqual(@as(i64, -32803), errorCode(capture));
    try testing.expect(std.mem.indexOf(u8, capture.object.get("error").?.object.get("message").?.string, "capture") != null);
}

test "rename: a global changes this file and says so" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    var buf: [1024]u8 = undefined;
    _ = try h.send(0, try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"u","version":1,"text":"g = 1\nprint(g)"}}}}}}
    , .{}));
    const r = try h.send(1,
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/rename","params":{"textDocument":{"uri":"u"},"position":{"line":0,"character":0},"newName":"h"}}
    );
    var warned = false;
    for (r) |m| {
        const method = m.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "window/showMessage")) warned = true;
    }
    try testing.expect(warned);
    try testing.expectEqual(@as(usize, 2), r[r.len - 1].object.get("result").?.object.get("changes").?.object.get("u").?.array.items.len);
}

test "prepareRename: the name's range, or a refusal for what cannot be renamed" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{"print"};
    try h.open();
    const ok = try askAt(&h, "local abc = 1", "textDocument/prepareRename", 0, 7, "");
    const res = ok.object.get("result").?.object;
    try testing.expectEqualStrings("abc", res.get("placeholder").?.string);
    try testing.expectEqual(@as(i64, 9), res.get("range").?.object.get("end").?.object.get("character").?.integer);

    h.server.docs.close("u");
    const bad = try askAt(&h, "print(1)", "textDocument/prepareRename", 0, 1, "");
    try testing.expectEqual(@as(i64, -32803), errorCode(bad));
}

test "completion: a list with kinds and an ordering that puts locals first" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{"print"};
    try h.open();
    const r = try askAt(&h, "local mine = 1\n", "textDocument/completion", 1, 0, "");
    const list = r.object.get("result").?.object;
    try testing.expect(!list.get("isIncomplete").?.bool);
    var found_local = false;
    var found_keyword = false;
    for (list.get("items").?.array.items) |it| {
        const label = it.object.get("label").?.string;
        if (std.mem.eql(u8, label, "mine")) {
            found_local = true;
            try testing.expectEqualStrings("0mine", it.object.get("sortText").?.string);
        }
        if (std.mem.eql(u8, label, "while")) {
            found_keyword = true;
            try testing.expectEqual(@as(i64, 14), it.object.get("kind").?.integer);
        }
    }
    try testing.expect(found_local and found_keyword);
}

test "requests: an unopened document is invalid params; initialize advertises the features" {
    var h = Harness.init(.{});
    defer h.deinit();
    const init = try h.send(0,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    const caps = init[0].object.get("result").?.object.get("capabilities").?.object;
    try testing.expect(caps.get("definitionProvider").?.bool);
    try testing.expect(caps.get("renameProvider").?.object.get("prepareProvider").?.bool);
    try testing.expect(caps.get("semanticTokensProvider").?.object.get("full").?.bool);
    try testing.expect(caps.get("foldingRangeProvider").?.bool);
    try testing.expect(caps.get("hoverProvider").?.bool);
    try testing.expectEqualStrings("(", caps.get("signatureHelpProvider").?.object.get("triggerCharacters").?.array.items[0].string);
    try testing.expectEqualStrings(".", caps.get("completionProvider").?.object.get("triggerCharacters").?.array.items[0].string);
    const r = try h.send(1,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"nope"},"position":{"line":0,"character":0}}}
    );
    try testing.expectEqual(@as(i64, -32602), errorCode(r[0]));
}

// ---- the library over the wire (doc 74 §7.3) ----

test "library: hover, signature help, and members after a dot, from the stdlib table" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{ "print", "string" };
    try h.open();

    const hover = try askAt(&h, "print(string.format)", "textDocument/hover", 0, 15, "");
    const contents = hover.object.get("result").?.object.get("contents").?.object;
    try testing.expectEqualStrings("markdown", contents.get("kind").?.string);
    try testing.expect(std.mem.indexOf(u8, contents.get("value").?.string, "string.format(formatstring, ...)") != null);
    const range = hover.object.get("result").?.object.get("range").?.object;
    try testing.expectEqual(@as(i64, 13), range.get("start").?.object.get("character").?.integer);

    // Nothing for a string's text.
    const quoted = try askAt(&h, "x = \"print\"", "textDocument/hover", 0, 7, "");
    try testing.expect(quoted.object.get("result").? == .null);

    // The signature of the call the cursor is in, with its second argument active.
    const sig = try askAt(&h, "string.sub(s, ", "textDocument/signatureHelp", 0, 14, "");
    const info = sig.object.get("result").?.object;
    try testing.expectEqual(@as(i64, 1), info.get("activeParameter").?.integer);
    const sigs = info.get("signatures").?.array.items;
    try testing.expectEqualStrings("string.sub(s, i [, j])", sigs[0].object.get("label").?.string);
    const params = sigs[0].object.get("parameters").?.array.items;
    const label = params[1].object.get("label").?.array.items;
    try testing.expectEqual(@as(i64, 14), label[0].integer);
    try testing.expectEqual(@as(i64, 15), label[1].integer);

    // Members after `string.`: functions, with their signatures as detail.
    const members = try askAt(&h, "x = string.", "textDocument/completion", 0, 11, "");
    var found = false;
    for (members.object.get("result").?.object.get("items").?.array.items) |it| {
        if (!std.mem.eql(u8, it.object.get("label").?.string, "format")) continue;
        found = true;
        try testing.expectEqual(@as(i64, 3), it.object.get("kind").?.integer);
        try testing.expectEqualStrings("string.format(formatstring, ...)", it.object.get("detail").?.string);
    }
    try testing.expect(found);
}

// ---- syntax over the wire (doc 74 §7.1) ----

/// Open `text` as document "u" and answer one request whose `params` are the
/// document identifier plus `tail` (more members, starting with a comma).
fn askWith(h: *Harness, text: []const u8, method: []const u8, tail: []const u8) !json.Value {
    var buf: [4096]u8 = undefined;
    const open = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"u","version":1,"text":{f}}}}}}}
    , .{std.json.fmt(text, .{})});
    _ = try h.send(0, open);
    var buf2: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf2,
        \\{{"jsonrpc":"2.0","id":7,"method":"{s}","params":{{"textDocument":{{"uri":"u"}}{s}}}}}
    , .{ method, tail });
    const r = try h.send(1, req);
    return r[r.len - 1];
}

/// The wire's delta encoding, decoded back to absolute
/// `[line, character, length, type, modifiers]` rows.
fn absoluteTokens(a: std.mem.Allocator, data: []const json.Value) ![]const [5]i64 {
    const rows = try a.alloc([5]i64, data.len / 5);
    var line: i64 = 0;
    var ch: i64 = 0;
    for (rows, 0..) |*row, i| {
        const d = data[i * 5 ..][0..5];
        const dl = d[0].integer;
        line += dl;
        ch = if (dl == 0) ch + d[1].integer else d[1].integer;
        row.* = .{ line, ch, d[2].integer, d[3].integer, d[4].integer };
    }
    return rows;
}

test "semantic tokens: the delta encoding, with types, modifiers and the comment" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{"print"};
    try h.open();
    const r = try askWith(&h, "local x = 1 -- c\nprint(x.y)", "textDocument/semanticTokens/full", "");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const data = r.object.get("result").?.object.get("data").?.array.items;
    const rows = try absoluteTokens(arena.allocator(), data);
    const want = [_][5]i64{
        .{ 0, 0, 5, 0, 0 }, // local
        .{ 0, 6, 1, 7, 1 }, // x, declared
        .{ 0, 8, 1, 1, 0 }, // =
        .{ 0, 10, 1, 2, 0 }, // 1
        .{ 0, 12, 4, 4, 0 }, // -- c
        .{ 1, 0, 5, 7, 2 }, // print, a built-in
        .{ 1, 6, 1, 7, 0 }, // x
        .{ 1, 7, 1, 1, 0 }, // .
        .{ 1, 8, 1, 8, 0 }, // y, a property
    };
    try testing.expectEqualSlices([5]i64, &want, rows);
}

test "semantic tokens: a long string spanning lines is one piece per line" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const r = try askWith(&h, "local s = [[a\nb]]", "textDocument/semanticTokens/full", "");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try absoluteTokens(arena.allocator(), r.object.get("result").?.object.get("data").?.array.items);
    try testing.expectEqualSlices([5]i64, &.{
        .{ 0, 0, 5, 0, 0 },
        .{ 0, 6, 1, 7, 1 },
        .{ 0, 8, 1, 1, 0 },
        .{ 0, 10, 3, 3, 0 },
        .{ 1, 0, 3, 3, 0 },
    }, rows);
}

test "folding: multi-line statements, tables and block comments keep their closing line" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const text = "if x then\n  print(1)\nend\nlocal t = {\n  a = 1,\n}\n--[[ a\nb\nc ]]\n";
    const r = try askWith(&h, text, "textDocument/foldingRange", "");
    const folds = r.object.get("result").?.array.items;
    try testing.expectEqual(@as(usize, 3), folds.len);
    try testing.expectEqual(@as(i64, 0), folds[0].object.get("startLine").?.integer);
    try testing.expectEqual(@as(i64, 1), folds[0].object.get("endLine").?.integer);
    try testing.expectEqual(@as(i64, 3), folds[1].object.get("startLine").?.integer);
    try testing.expectEqual(@as(i64, 4), folds[1].object.get("endLine").?.integer);
    try testing.expectEqualStrings("comment", folds[2].object.get("kind").?.string);
    try testing.expectEqual(@as(i64, 6), folds[2].object.get("startLine").?.integer);
    try testing.expectEqual(@as(i64, 7), folds[2].object.get("endLine").?.integer);
}

test "document symbols: the outline nests functions and table fields" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const text = "local M = {\n  add = function(a) return a end,\n  n = 1,\n}\nfunction M.run(x) local y = 2 end\nlocal function f() end";
    const r = try askWith(&h, text, "textDocument/documentSymbol", "");
    const top = r.object.get("result").?.array.items;
    try testing.expectEqual(@as(usize, 3), top.len);
    try testing.expectEqualStrings("M", top[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 19), top[0].object.get("kind").?.integer);
    try testing.expectEqualStrings("M.run", top[1].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 12), top[1].object.get("kind").?.integer);
    try testing.expectEqualStrings("f", top[2].object.get("name").?.string);

    const fields = top[0].object.get("children").?.array.items;
    try testing.expectEqualStrings("add", fields[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 12), fields[0].object.get("kind").?.integer);
    try testing.expectEqual(@as(i64, 8), fields[1].object.get("kind").?.integer);
    // The selection is the name, inside the whole declaration.
    const sel = fields[1].object.get("selectionRange").?.object.get("start").?.object;
    try testing.expectEqual(@as(i64, 2), sel.get("line").?.integer);
    try testing.expectEqual(@as(i64, 2), sel.get("character").?.integer);
    try testing.expect(top[1].object.get("children") != null);
    try testing.expectEqualStrings("y", top[1].object.get("children").?.array.items[0].object.get("name").?.string);
}

test "selection ranges: the chain from the name outwards, each range containing the last" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const r = try askWith(&h, "local x = f(a.b)", "textDocument/selectionRange", ",\"positions\":[{\"line\":0,\"character\":14}]");
    var node = r.object.get("result").?.array.items[0].object;
    var count: usize = 0;
    var inner_start: i64 = 12;
    var inner_end: i64 = 15;
    while (true) {
        count += 1;
        const range = node.get("range").?.object;
        const start = range.get("start").?.object.get("character").?.integer;
        const end = range.get("end").?.object.get("character").?.integer;
        try testing.expect(start <= inner_start and inner_end <= end);
        inner_start = start;
        inner_end = end;
        node = (node.get("parent") orelse break).object;
    }
    // `a.b`, the call `f(a.b)`, and the statement, which is also the file.
    try testing.expectEqual(@as(usize, 3), count);
}

test "syntax requests answer on damaged text, and for an unopened document" {
    var h = Harness.init(.{});
    defer h.deinit();
    try h.open();
    const r = try askWith(&h, "local x =", "textDocument/semanticTokens/full", "");
    try testing.expect(r.object.get("result") != null);
    const r2 = try askWith(&h, "local x =", "textDocument/documentSymbol", "");
    try testing.expect(r2.object.get("result") != null);
    h.server.docs.close("u");
    const bad = try h.send(2,
        \\{"jsonrpc":"2.0","id":9,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"nope"}}}
    );
    try testing.expectEqual(@as(i64, -32602), errorCode(bad[0]));
}
// ---- workspace folders, mahina.toml and require (doc 74 §7.4) ----------------

const MemoryFiles = workspace.MemoryFiles;

/// `initialize` with `extra` (folders or a root) in its params, then `initialized`.
fn initWith(h: *Harness, extra: []const u8) ![]json.Value {
    var buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"capabilities":{{}},{s}}}}}
    , .{extra});
    const r = try h.send(0, body);
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    return r;
}

fn openDoc(h: *Harness, now: u64, uri: []const u8, text: []const u8) ![]json.Value {
    var buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","version":1,"text":{f}}}}}}}
    , .{ uri, std.json.fmt(text, .{}) });
    return h.send(now, body);
}

/// The diagnostics published for `uri` among `msgs`, or null if none were.
fn diagnosticsFor(msgs: []const json.Value, uri: []const u8) ?[]json.Value {
    for (msgs) |m| {
        const method = m.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) continue;
        const params = m.object.get("params").?.object;
        if (std.mem.eql(u8, params.get("uri").?.string, uri)) return params.get("diagnostics").?.array.items;
    }
    return null;
}

test "workspace: one server serves every folder; a rejected mahina.toml is an error on the file" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/a/mahina.toml", "version = 1\n[runtme]\n" },
        .{ "/w/b/mahina.toml", "version = 1\n[globals]\nspawn = \"starts a process\"\n" },
    } };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    const r = try initWith(&h,
        \\"workspaceFolders":[{"uri":"file:///w/a","name":"a"},{"uri":"file:///w/b","name":"b"}]
    );
    // The response comes first; the config's error follows it.
    const caps = r[0].object.get("result").?.object.get("capabilities").?.object;
    try testing.expect(caps.get("workspace").?.object.get("workspaceFolders").?.object.get("supported").?.bool);
    const errs = diagnosticsFor(r, "file:///w/a/mahina.toml").?;
    try testing.expectEqual(@as(usize, 1), errs.len);
    const range = errs[0].object.get("range").?.object;
    try testing.expectEqual(@as(i64, 1), range.get("start").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 1), range.get("start").?.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 8), range.get("end").?.object.get("character").?.integer);
    try testing.expect(diagnosticsFor(r, "file:///w/b/mahina.toml") == null);

    // b's `[globals]` reach b's files and no others.
    _ = try openDoc(&h, 0, "file:///w/b/m.mah", "spawn()\n");
    _ = try openDoc(&h, 0, "file:///w/a/m.mah", "spawn()\n");
    const t = try h.tick(50);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(t, "file:///w/b/m.mah").?.len);
    try testing.expectEqual(@as(usize, 1), diagnosticsFor(t, "file:///w/a/m.mah").?.len);

    // Removing a folder takes its config's error back, and its files are
    // analysed again under the defaults.
    const rm = try h.send(60,
        \\{"jsonrpc":"2.0","method":"workspace/didChangeWorkspaceFolders","params":{"event":{"added":[],"removed":[{"uri":"file:///w/b","name":"b"},{"uri":"file:///w/a","name":"a"}]}}}
    );
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(rm, "file:///w/a/mahina.toml").?.len);
    const again = try h.tick(200);
    try testing.expectEqual(@as(usize, 1), diagnosticsFor(again, "file:///w/b/m.mah").?.len);
}

test "require: the module name goes to its file; an unresolved literal is information unless suppressed" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/lib/util.mah", "return {}\n" },
        .{ "/q/mahina.toml", "version = 1\n[diagnostics]\nsuppress = [\"unresolved-require\"]\n" },
    } };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    h.server.known_globals = &.{ "print", "require" };
    _ = try initWith(&h,
        \\"workspaceFolders":[{"uri":"file:///w","name":"w"},{"uri":"file:///q","name":"q"}]
    );
    const main_text = "local u = require(\"lib.util\")\nlocal g = require(\"gone\")\nlocal s = require \"string\"\nprint(u, g, s, require(name))\n";
    _ = try openDoc(&h, 0, "file:///w/main.mah", main_text);
    const t = try h.tick(50);
    const ds = diagnosticsFor(t, "file:///w/main.mah").?;
    // `name` is an undefined global; `gone` is the one module that is missing.
    var missing: ?json.ObjectMap = null;
    for (ds) |d| {
        if (std.mem.eql(u8, d.object.get("code").?.string, Server.unresolved_require_code)) {
            try testing.expect(missing == null);
            missing = d.object;
        }
    }
    try testing.expectEqual(@as(i64, 3), missing.?.get("severity").?.integer);
    try testing.expectEqual(@as(i64, 1), missing.?.get("range").?.object.get("start").?.object.get("line").?.integer);
    try testing.expect(std.mem.indexOf(u8, missing.?.get("message").?.string, "no file '/w/gone.mah'") != null);

    // Definition on the module name: the file, from its start.
    const def = try h.send(60,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///w/main.mah"},"position":{"line":0,"character":21}}}
    );
    const loc = def[def.len - 1].object.get("result").?.object;
    try testing.expectEqualStrings("file:///w/lib/util.mah", loc.get("uri").?.string);
    try testing.expectEqual(@as(i64, 0), loc.get("range").?.object.get("start").?.object.get("character").?.integer);

    // An open document that was never saved resolves.
    _ = try openDoc(&h, 70, "file:///w/gone.mah", "return 1\n");
    _ = try h.send(70,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///w/main.mah","version":2},"contentChanges":[{"text":"local g = require(\"gone\")\nprint(g)\n"}]}}
    );
    const after = try h.tick(200);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(after, "file:///w/main.mah").?.len);

    // Suppressed by the folder's config; and a document that names no file
    // has no directory to search from.
    _ = try openDoc(&h, 300, "file:///q/x.mah", "local g = require(\"gone\")\nprint(g)\n");
    _ = try openDoc(&h, 300, "untitled:1", "local g = require(\"gone\")\nprint(g)\n");
    const rest = try h.tick(400);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(rest, "file:///q/x.mah").?.len);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(rest, "untitled:1").?.len);
}

test "require: without a disk only built-ins and open documents resolve, and no miss is reported" {
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.known_globals = &.{ "print", "require" };
    _ = try initWith(&h,
        \\"rootUri":"file:///w"
    );
    _ = try openDoc(&h, 0, "file:///w/main.mah", "local g = require(\"gone\")\nlocal o = require(\"other\")\nprint(g, o)\n");
    _ = try openDoc(&h, 0, "file:///w/other.mah", "return 1\n");
    const t = try h.tick(50);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(t, "file:///w/main.mah").?.len);
    const def = try h.send(60,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///w/main.mah"},"position":{"line":1,"character":20}}}
    );
    try testing.expectEqualStrings("file:///w/other.mah", def[def.len - 1].object.get("result").?.object.get("uri").?.string);
}
/// The response to `method` at `line:ch` in the open document `uri`.
fn requestAt(h: *Harness, now: u64, uri: []const u8, method: []const u8, line: u32, ch: u32) !json.Value {
    var buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","id":9,"method":"{s}","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}}}
    , .{ method, uri, line, ch });
    const r = try h.send(now, req);
    return r[r.len - 1];
}

/// The completion item labelled `label` in a completion response.
fn itemNamed(resp: json.Value, label: []const u8) ?json.ObjectMap {
    for (resp.object.get("result").?.object.get("items").?.array.items) |it| {
        if (std.mem.eql(u8, it.object.get("label").?.string, label)) return it.object;
    }
    return null;
}

test "module exports: members after a module local's dot or colon, and definition in the module's file" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/lib/util.mah", "local M = { version = 1 }\nfunction M.add(a, b) end\nfunction M:size() end\nreturn M\n" },
    } };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    h.server.known_globals = &.{ "print", "require" };
    _ = try initWith(&h,
        \\"workspaceFolders":[{"uri":"file:///w","name":"w"}]
    );
    _ = try openDoc(&h, 0, "file:///w/main.mah", "local u = require(\"lib.util\")\nu.\n");
    const dot = try requestAt(&h, 1, "file:///w/main.mah", "textDocument/completion", 1, 2);
    try testing.expectEqualStrings("add(a, b)", itemNamed(dot, "add").?.get("detail").?.string);
    try testing.expectEqual(@as(i64, protocol.CompletionItemKind.method), itemNamed(dot, "size").?.get("kind").?.integer);
    try testing.expectEqualStrings("field of lib.util", itemNamed(dot, "version").?.get("detail").?.string);
    try testing.expect(itemNamed(dot, "while") == null);
    try testing.expectEqual(@as(u64, 1), h.server.module_cache.builds);

    // After a colon, only what can be called; the module was not read again.
    _ = try h.send(2,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///w/main.mah","version":2},"contentChanges":[{"text":"local u = require(\"lib.util\")\nu:\nprint(u.add)\n"}]}}
    );
    const colon = try requestAt(&h, 3, "file:///w/main.mah", "textDocument/completion", 1, 2);
    try testing.expect(itemNamed(colon, "size") != null);
    try testing.expect(itemNamed(colon, "version") == null);
    try testing.expectEqual(@as(u64, 1), h.server.module_cache.builds);

    // Definition on `add`: where the module writes it.
    const def = try requestAt(&h, 4, "file:///w/main.mah", "textDocument/definition", 2, 9);
    const loc = def.object.get("result").?.object;
    try testing.expectEqualStrings("file:///w/lib/util.mah", loc.get("uri").?.string);
    const start = loc.get("range").?.object.get("start").?.object;
    try testing.expectEqual(@as(i64, 1), start.get("line").?.integer);
    try testing.expectEqual(@as(i64, 11), start.get("character").?.integer);

    // The module open in the editor is read ahead of the disk, edits included.
    _ = try openDoc(&h, 5, "file:///w/lib/util.mah", "local M = {}\nfunction M.sub(x) end\nreturn M\n");
    const open = try requestAt(&h, 6, "file:///w/main.mah", "textDocument/completion", 1, 2);
    try testing.expect(itemNamed(open, "sub") != null);
    try testing.expect(itemNamed(open, "add") == null);
    try testing.expectEqual(@as(u64, 2), h.server.module_cache.builds);
}
test "system groups: a folder's mahina.toml decides which members exist, and hover says what is missing" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/mahina.toml", "version = 1\n[runtime]\nsystem = [\"stdio\"]\n" },
    } };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    h.server.known_globals = &.{ "print", "io" };
    _ = try initWith(&h,
        \\"workspaceFolders":[{"uri":"file:///w","name":"w"}]
    );
    _ = try openDoc(&h, 0, "file:///w/m.mah", "local f = io.open(\"x\")\nlocal l = io.read()\nx = io.\n");
    const members = try requestAt(&h, 1, "file:///w/m.mah", "textDocument/completion", 2, 7);
    try testing.expect(itemNamed(members, "open") == null);
    try testing.expect(itemNamed(members, "read") != null);
    const open = try requestAt(&h, 2, "file:///w/m.mah", "textDocument/hover", 0, 14);
    const text = open.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "files system group, which this project does not enable") != null);
    const read = try requestAt(&h, 3, "file:///w/m.mah", "textDocument/hover", 1, 14);
    const read_text = read.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, read_text, "does not enable") == null);
}
test "initializationOptions: override every folder's mahina.toml; a misspelt key is reported and nothing applies" {
    var mem: MemoryFiles = .{ .entries = &.{
        .{ "/w/mahina.toml", "version = 1\n[diagnostics]\nsuppress = [\"W0001\"]\n" },
    } };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    h.server.known_globals = &.{ "print", "require" };
    _ = try initWith(&h,
        \\"workspaceFolders":[{"uri":"file:///w","name":"w"}],"initializationOptions":{"globals":{"spawn":"starts a process"},"diagnostics":{"suppress":["unresolved-require"]}}
    );
    // `spawn` is known, `undefined_name` is suppressed by the file, the missing
    // module by the editor.
    _ = try openDoc(&h, 0, "file:///w/m.mah", "spawn(undefined_name, require(\"gone\"))\n");
    const t = try h.tick(50);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(t, "file:///w/m.mah").?.len);

    var bad = Harness.init(.{});
    defer bad.deinit();
    bad.server.known_globals = &.{"print"};
    const r = try initWith(&bad,
        \\"rootUri":"file:///w","initializationOptions":{"runtime":{"systm":["files"]}}
    );
    var said: ?[]const u8 = null;
    for (r) |m| {
        const method = m.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "window/showMessage")) said = m.object.get("params").?.object.get("message").?.string;
    }
    try testing.expectEqualStrings("mahina: initializationOptions ignored: unknown member 'runtime.systm'", said.?);
    try testing.expect(bad.server.ws.loose.system == @import("../system.zig").Groups.all);
}
test "watched files: the server asks to watch mahina.toml, and an edit to one is read again" {
    var entries = [_][2][]const u8{.{ "/w/mahina.toml", "version = 1\n" }};
    var mem: MemoryFiles = .{ .entries = &entries };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    h.server.known_globals = &.{"print"};
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}},"workspaceFolders":[{"uri":"file:///w","name":"w"}]}}
    );
    const ready = try h.send(0,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("client/registerCapability", ready[0].object.get("method").?.string);
    const reg = ready[0].object.get("params").?.object.get("registrations").?.array.items[0].object;
    try testing.expectEqualStrings("**/mahina.toml", reg.get("registerOptions").?.object.get("watchers").?.array.items[0].object.get("globPattern").?.string);
    // The client's answer needs no reply; a refusal is logged.
    try testing.expectEqual(@as(usize, 0), (try h.send(1,
        \\{"jsonrpc":"2.0","id":"mahina/watch-config","result":null}
    )).len);
    const refused = try h.send(1,
        \\{"jsonrpc":"2.0","id":"mahina/watch-config","error":{"code":-32601,"message":"unsupported"}}
    );
    try testing.expectEqualStrings("window/logMessage", refused[0].object.get("method").?.string);

    _ = try openDoc(&h, 2, "file:///w/m.mah", "spawn()\n");
    try testing.expectEqual(@as(usize, 1), diagnosticsFor(try h.tick(60), "file:///w/m.mah").?.len);

    // The file gains `[globals]`: the document is analysed again under it.
    entries[0][1] = "version = 1\n[globals]\nspawn = \"host\"\n";
    const changed =
        \\{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///w/mahina.toml","type":2},{"uri":"file:///w/other.txt","type":2}]}}
    ;
    _ = try h.send(100, changed);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(try h.tick(200), "file:///w/m.mah").?.len);

    // A broken edit is published on the file, and fixing it takes it back.
    entries[0][1] = "version = 1\n[globls]\n";
    const broken = try h.send(300, changed);
    try testing.expectEqual(@as(usize, 1), diagnosticsFor(broken, "file:///w/mahina.toml").?.len);
    entries[0][1] = "version = 1\n";
    const fixed = try h.send(400, changed);
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(fixed, "file:///w/mahina.toml").?.len);
}

test "watched files: a client that cannot watch is told what a config edit needs" {
    var mem: MemoryFiles = .{ .entries = &.{} };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    _ = try h.send(0,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file:///w"}}
    );
    const ready = try h.send(0,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try testing.expectEqual(@as(usize, 1), ready.len);
    try testing.expectEqualStrings("window/logMessage", ready[0].object.get("method").?.string);
}

test "workspace symbols: every folder's functions, an open document's as edited, the closest first" {
    var entries = [_][2][]const u8{
        .{ "/w/lib/util.mah", "local M = {}\nfunction M.add(a, b) end\nfunction M:size() end\nreturn M\n" },
        .{ "/w/main.mah", "local function adder() end\n" },
        .{ "/v/tool.lua", "function add() end\n" },
    };
    var mem: MemoryFiles = .{ .entries = &entries };
    var h = Harness.init(.{});
    defer h.deinit();
    h.server.files = mem.files();
    const r = try initWith(&h,
        \\"workspaceFolders":[{"uri":"file:///w","name":"w"},{"uri":"file:///v","name":"v"}]
    );
    try testing.expect(r[0].object.get("result").?.object.get("capabilities").?.object.get("workspaceSymbolProvider").?.bool);

    const q = try h.send(0,
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/symbol","params":{"query":"add"}}
    );
    const hits = q[q.len - 1].object.get("result").?.array.items;
    try testing.expectEqual(@as(usize, 3), hits.len);
    // `add` exactly, then the prefix `adder`, then `M.add` containing it.
    try testing.expectEqualStrings("add", hits[0].object.get("name").?.string);
    try testing.expectEqualStrings("file:///v/tool.lua", hits[0].object.get("location").?.object.get("uri").?.string);
    try testing.expectEqual(@as(i64, protocol.SymbolKind.function), hits[0].object.get("kind").?.integer);
    try testing.expectEqualStrings("adder", hits[1].object.get("name").?.string);
    try testing.expectEqualStrings("M.add", hits[2].object.get("name").?.string);
    const start = hits[2].object.get("location").?.object.get("range").?.object.get("start").?.object;
    try testing.expectEqual(@as(i64, 1), start.get("line").?.integer);
    try testing.expectEqual(@as(i64, 11), start.get("character").?.integer);
    try testing.expectEqual(@as(u64, 3), h.server.symbols.builds);

    // Asked again, nothing is parsed again; an open document is read as
    // edited, and a document with no file is searched too.
    _ = try h.send(1,
        \\{"jsonrpc":"2.0","id":3,"method":"workspace/symbol","params":{"query":"size"}}
    );
    try testing.expectEqual(@as(u64, 3), h.server.symbols.builds);
    _ = try openDoc(&h, 2, "file:///w/main.mah", "local function subtract() end\n");
    _ = try openDoc(&h, 2, "untitled:1", "function scratch() end\n");
    const s = try h.send(3,
        \\{"jsonrpc":"2.0","id":4,"method":"workspace/symbol","params":{"query":"s"}}
    );
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    for (s[s.len - 1].object.get("result").?.array.items) |x| {
        try names.appendSlice(testing.allocator, x.object.get("name").?.string);
        try names.append(testing.allocator, ' ');
    }
    try testing.expectEqualStrings("scratch subtract M:size ", names.items);
}
