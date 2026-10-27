//! Analysing one version of one document: lex, parse (with recovery), resolve
//! names, and check the compile, ending with the diagnostics and the tree and
//! name table that navigation reads (doc 74 §6, P2).
//!
//! Everything here is LSP-free: the result speaks in byte offsets and in the
//! compiler's own `diag.Diagnostic`, and the server turns those into protocol
//! positions. The text is copied, so the result outlives any later edit of
//! the document it came from.
//!
//! The frontend runs exactly as `mahina run` runs it, so the editor and the
//! compiler cannot disagree about what is an error. Compilation needs a
//! `gc.Heap` only to intern string constants; a bare one is made and dropped.

const std = @import("std");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const resolve = @import("../resolve.zig");
const compiler = @import("../compiler.zig");
const diag = @import("../diag.zig");
const gc = @import("../gc.zig");

/// Asked between phases: has the answer stopped being wanted (a newer edit is
/// waiting)? A phase already begun is not interrupted.
pub const Abandon = struct {
    ctx: ?*anyopaque = null,
    stale: *const fn (ctx: ?*anyopaque) bool = never,

    fn never(_: ?*anyopaque) bool {
        return false;
    }

    fn check(self: Abandon) error{Abandoned}!void {
        if (self.stale(self.ctx)) return error.Abandoned;
    }
};

pub const Error = error{
    OutOfMemory,
    /// `Abandon.stale` said so between phases.
    Abandoned,
    /// The parser gave up without a tree (it has no such path today).
    Unparseable,
};

pub const Analysis = struct {
    /// Owns `source`, `diagnostics` and the text of the diagnostics that name
    /// something.
    arena: std.heap.ArenaAllocator,
    /// The analysed text, NUL-terminated (the AST borrows it).
    source: [:0]const u8,
    tree: ast.Ast,
    res: resolve.Resolution,
    /// Every error and warning, in the order found.
    diagnostics: []const diag.Diagnostic,
    /// A diagnostic was lost to an allocation failure: this set is not the
    /// whole story and must not be shown as a clean result.
    incomplete: bool,

    pub fn deinit(self: *Analysis) void {
        self.res.deinit();
        self.tree.deinit();
        self.arena.deinit();
    }
};

/// Analyse `text`. `known_globals` are the names the host installs (they are
/// not flagged as undefined).
pub fn analyse(
    gpa: std.mem.Allocator,
    text: []const u8,
    known_globals: []const []const u8,
    abandon: Abandon,
) Error!Analysis {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const source = try a.dupeSentinel(u8, text, 0);

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    var tree = parser.parse(gpa, source, &diags) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => return error.Unparseable,
    };
    errdefer tree.deinit();
    try abandon.check();

    var res = try resolve.resolve(gpa, tree.root, @intCast(source.len));
    errdefer res.deinit();
    try abandon.check();

    var heap = gc.Heap.init(gpa);
    defer heap.deinit();
    compiler.checkChunk(gpa, a, &heap, source, tree.root, &res, &diags, .{
        .known_globals = known_globals,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // A statement that cannot compile is reported and skipped; the error
        // that escapes is the one that could not be skipped.
        error.CompileError => {},
    };
    try abandon.check();

    // Every allocation from `a` is made before `arena` is copied into the result.
    const diagnostics = try a.dupe(diag.Diagnostic, diags.list.items);
    return .{
        .arena = arena,
        .source = source,
        .tree = tree,
        .res = res,
        .diagnostics = diagnostics,
        .incomplete = diags.incomplete,
    };
}

// ---- tests ----

const testing = std.testing;

const known = [_][]const u8{"print"};

test "analysis: a clean document has no diagnostics and keeps its tree" {
    var an = try analyse(testing.allocator, "local x = 1\nprint(x)", &known, .{});
    defer an.deinit();
    try testing.expectEqual(@as(usize, 0), an.diagnostics.len);
    try testing.expect(!an.incomplete);
    try testing.expectEqual(@as(usize, 2), an.tree.root.len);
    try testing.expect(an.res.bindingAt(6) != null); // the `x` being declared
}

test "analysis: syntax errors and compile errors are reported together" {
    const src = "local x =\nbreak\nprint(undefined_name)";
    var an = try analyse(testing.allocator, src, &known, .{});
    defer an.deinit();
    var syntax: usize = 0;
    var compile: usize = 0;
    var lint: usize = 0;
    for (an.diagnostics) |d| switch (d.code) {
        .expected_expression => syntax += 1,
        .break_outside_loop => compile += 1,
        .undefined_global => lint += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), syntax);
    try testing.expectEqual(@as(usize, 1), compile);
    try testing.expectEqual(@as(usize, 1), lint);
}

test "analysis: the result owns its text, so the document may change" {
    var buf = [_]u8{ 'x', ' ', '=', ' ', '=' };
    var an = try analyse(testing.allocator, &buf, &known, .{});
    defer an.deinit();
    @memset(&buf, 'z');
    try testing.expectEqualStrings("x = =", an.source);
    try testing.expect(an.diagnostics.len > 0);
}

test "analysis: a lint message outlives the compile that made it" {
    var an = try analyse(testing.allocator, "print(nope)", &known, .{});
    defer an.deinit();
    try testing.expectEqual(@as(usize, 1), an.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, an.diagnostics[0].message, "nope") != null);
}

test "analysis: a stale answer is abandoned between phases, freeing everything" {
    const Stale = struct {
        calls: u32 = 0,
        fn stale(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return self.calls >= 2; // after the parse, not before the resolve finished
        }
    };
    var s = Stale{};
    try testing.expectError(error.Abandoned, analyse(testing.allocator, "local x = 1\nprint(x)", &known, .{
        .ctx = &s,
        .stale = Stale.stale,
    }));
    try testing.expectEqual(@as(u32, 2), s.calls);
}

test "analysis: an out-of-memory run fails cleanly at every allocation" {
    // Every allocation in turn fails once: no leak, and only OutOfMemory.
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        if (analyse(failing.allocator(), "local function f(a) return a + g end\nbreak\nx = = 1", &known, .{})) |ok| {
            // Past the last allocation, or the failure only cost a diagnostic.
            var an = ok;
            an.deinit();
        } else |e| try testing.expectEqual(error.OutOfMemory, e);
    }
}
