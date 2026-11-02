//! The REPL (doc 75 §6): one `Session` that turns typed lines into chunks run
//! on a long-lived VM, and the terminal loop around it. The session is pure
//! logic over a VM and a writer, so it is tested without a tty; the terminal
//! (raw mode, history file, prompt) is the part at the bottom and the only
//! part that touches the OS (Rule Z-2).
//!
//! A line is tried as an expression first (`1 + 1` prints `2`, as `lua` does),
//! then as statements. A chunk that ends early waits for more lines. Four
//! words are shell shortcuts when the line starts with them and no global of
//! that name exists: `cd`, `export`, `unset` and `exit`. They are translated
//! to Lua (`os.chdir`, `os.setenv`) and run like any other chunk.
//!
//! Each line is its own chunk, but the top-level `local`s of earlier lines stay
//! visible: they are the root closure's upvalues (`compiler.Repl`), their cells
//! carried from line to line by the session.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const posix = std.posix;

const interp = @import("interp.zig");
const function = @import("function.zig");
const gc = @import("gc.zig");
const resolve = @import("resolve.zig");
const compiler = @import("compiler.zig");
const parser = @import("parser.zig");
const diag = @import("diag.zig");
const lineedit = @import("lineedit.zig");
const mio = @import("io.zig");
const Vm = interp.Vm;

// ---------------------------------------------------------------------------
// Shortcuts
// ---------------------------------------------------------------------------

pub const shortcut_words = [_][]const u8{ "cd", "export", "unset", "exit" };

/// A line that starts with a shortcut word, as `{word, rest}`; null if it is
/// Lua. `cd = 1`, `cd(x)`, `cd[1]`, `cd:go()` and `cd, x = 1, 2` are Lua. The
/// session also leaves the line alone when a global of that name exists.
pub fn recognize(line: []const u8) ?struct { word: []const u8, rest: []const u8 } {
    const s = std.mem.trimStart(u8, line, " \t");
    for (shortcut_words) |w| {
        if (!std.mem.startsWith(u8, s, w)) continue;
        const after = s[w.len..];
        if (after.len != 0 and after[0] != ' ' and after[0] != '\t') continue;
        const rest = std.mem.trim(u8, after, " \t\r\n");
        if (rest.len != 0 and std.mem.indexOfScalar(u8, "=([:,", rest[0]) != null) return null;
        return .{ .word = w, .rest = rest };
    }
    return null;
}

pub const Translated = union(enum) {
    /// Lua source to run. Owned by the caller.
    lua: []u8,
    exit: u8,
    /// The shortcut's own complaint, printed as is.
    bad: []const u8,
};

const WordError = error{ UnterminatedQuote, WriteFailed, OutOfMemory };

/// The next shell word of `text` from `i`: [start, end) of its raw bytes,
/// quotes included. Null at the end.
fn nextWord(text: []const u8, i: *usize) WordError!?[]const u8 {
    var p = i.*;
    while (p < text.len and (text[p] == ' ' or text[p] == '\t')) p += 1;
    if (p >= text.len) return null;
    const start = p;
    while (p < text.len and text[p] != ' ' and text[p] != '\t') {
        switch (text[p]) {
            '\'', '"' => |q| {
                p += 1;
                while (p < text.len and text[p] != q) : (p += 1) {
                    if (q == '"' and text[p] == '\\' and p + 1 < text.len) p += 1;
                }
                if (p >= text.len) return error.UnterminatedQuote;
                p += 1;
            },
            '\\' => p += if (p + 1 < text.len) 2 else 1,
            else => p += 1,
        }
    }
    i.* = p;
    return text[start..p];
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// A Lua string literal for `bytes`.
fn writeLuaString(w: *Writer, bytes: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (bytes) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        0...9, 11...31, 127 => try w.print("\\{d:0>3}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// The Lua expression for one shell word: its quotes removed, `$NAME` and
/// `${NAME}` read from the environment (not inside single quotes), a leading
/// `~` the home directory.
fn writeWordExpr(gpa: Allocator, w: *Writer, raw: []const u8) WordError!void {
    var lit: std.ArrayList(u8) = .empty;
    defer lit.deinit(gpa);
    var parts: usize = 0;
    const Flush = struct {
        fn lit_(wr: *Writer, l: *std.ArrayList(u8), n: *usize) Writer.Error!void {
            if (l.items.len == 0) return;
            if (n.* > 0) try wr.writeAll(" .. ");
            try writeLuaString(wr, l.items);
            n.* += 1;
            l.clearRetainingCapacity();
        }
        fn env(wr: *Writer, name: []const u8, n: *usize) Writer.Error!void {
            if (n.* > 0) try wr.writeAll(" .. ");
            try wr.writeAll("(os.getenv(");
            try writeLuaString(wr, name);
            try wr.writeAll(") or \"\")");
            n.* += 1;
        }
    };
    var i: usize = 0;
    if (raw.len > 0 and raw[0] == '~' and (raw.len == 1 or raw[1] == '/')) {
        try Flush.env(w, "HOME", &parts);
        i = 1;
    }
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            '\'' => {
                const close = std.mem.indexOfScalarPos(u8, raw, i + 1, '\'') orelse return error.UnterminatedQuote;
                try lit.appendSlice(gpa, raw[i + 1 .. close]);
                i = close + 1;
            },
            '\\' => {
                if (i + 1 < raw.len) try lit.append(gpa, raw[i + 1]);
                i += 2;
            },
            '"', '$' => {
                // Inside double quotes everything but `\`, `"` and `$` is literal.
                const quoted = c == '"';
                if (quoted) i += 1;
                var closed = !quoted;
                while (i < raw.len and (quoted or raw[i] == '$')) {
                    const d = raw[i];
                    if (quoted and d == '"') {
                        i += 1;
                        closed = true;
                        break;
                    }
                    if (quoted and d == '\\' and i + 1 < raw.len) {
                        const n = raw[i + 1];
                        if (n == '\\' or n == '"' or n == '$') {
                            try lit.append(gpa, n);
                            i += 2;
                            continue;
                        }
                        try lit.append(gpa, d);
                        i += 1;
                        continue;
                    }
                    if (d == '$') {
                        var j = i + 1;
                        var braced = false;
                        if (j < raw.len and raw[j] == '{') {
                            braced = true;
                            j += 1;
                        }
                        const ns = j;
                        if (j < raw.len and isNameStart(raw[j])) {
                            while (j < raw.len and isNameByte(raw[j])) j += 1;
                            const name = raw[ns..j];
                            if (braced) {
                                if (j >= raw.len or raw[j] != '}') {
                                    try lit.append(gpa, '$');
                                    i += 1;
                                    continue;
                                }
                                j += 1;
                            }
                            try Flush.lit_(w, &lit, &parts);
                            try Flush.env(w, name, &parts);
                            i = j;
                            continue;
                        }
                        try lit.append(gpa, '$');
                        i += 1;
                        continue;
                    }
                    try lit.append(gpa, d);
                    i += 1;
                }
                if (!closed) return error.UnterminatedQuote;
            },
            else => {
                try lit.append(gpa, c);
                i += 1;
            },
        }
    }
    try Flush.lit_(w, &lit, &parts);
    if (parts == 0) try w.writeAll("\"\"");
}

/// Translate a shortcut line (`recognize` said it is one) to Lua, an exit, or
/// a complaint.
pub fn translate(gpa: Allocator, word: []const u8, rest: []const u8) Allocator.Error!Translated {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    const r = translateInto(gpa, w, word, rest) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        error.UnterminatedQuote => {
            aw.deinit();
            return .{ .bad = "unterminated quote" };
        },
    };
    switch (r) {
        .lua => return .{ .lua = try aw.toOwnedSlice() },
        .exit => |n| {
            aw.deinit();
            return .{ .exit = n };
        },
        .bad => |m| {
            aw.deinit();
            return .{ .bad = m };
        },
    }
}

const Translation = union(enum) { lua, exit: u8, bad: []const u8 };

fn translateInto(gpa: Allocator, w: *Writer, word: []const u8, rest: []const u8) WordError!Translation {
    var i: usize = 0;
    if (std.mem.eql(u8, word, "cd")) {
        const first = try nextWord(rest, &i);
        if (try nextWord(rest, &i) != null) return .{ .bad = "cd: too many arguments" };
        try w.writeAll("do local __o = os.getcwd() os.chdir(");
        if (first) |f| {
            if (std.mem.eql(u8, f, "-")) {
                try w.writeAll("(os.getenv(\"OLDPWD\") or \"\")");
            } else try writeWordExpr(gpa, w, f);
        } else try w.writeAll("(os.getenv(\"HOME\") or \"\")");
        try w.writeAll(") os.setenv(\"OLDPWD\", __o) os.setenv(\"PWD\", os.getcwd()) end");
        return .lua;
    }
    if (std.mem.eql(u8, word, "export") or std.mem.eql(u8, word, "unset")) {
        const unset = word[0] == 'u';
        var any = false;
        while (try nextWord(rest, &i)) |raw| {
            const eq = std.mem.indexOfScalar(u8, raw, '=');
            const name = raw[0 .. eq orelse raw.len];
            if (name.len == 0 or !isNameStart(name[0])) return .{ .bad = "not a valid identifier" };
            for (name) |c| if (!isNameByte(c)) return .{ .bad = "not a valid identifier" };
            if (unset) {
                if (eq != null) return .{ .bad = "unset: not a valid identifier" };
                try w.writeAll("os.setenv(");
                try writeLuaString(w, name);
                try w.writeAll(", nil) ");
                any = true;
            } else if (eq) |e| {
                try w.writeAll("os.setenv(");
                try writeLuaString(w, name);
                try w.writeAll(", ");
                try writeWordExpr(gpa, w, raw[e + 1 ..]);
                try w.writeAll(") ");
                any = true;
            }
        }
        if (!any) try w.writeAll("local _ = 0");
        return .lua;
    }
    // exit [status]
    const first = try nextWord(rest, &i);
    if (try nextWord(rest, &i) != null) return .{ .bad = "exit: too many arguments" };
    const n = std.fmt.parseInt(u8, first orelse "0", 10) catch return .{ .bad = "exit: numeric argument (0-255) required" };
    return .{ .exit = n };
}

// ---------------------------------------------------------------------------
// The session
// ---------------------------------------------------------------------------

/// Wraps an expression so that its values print as `print` does, and nothing
/// prints when it has none. The expression starts on line 1, so errors point at
/// the line the user typed. (An anonymous function, not a `local`: a REPL
/// chunk's top-level locals persist.)
const show_prelude = "(function(...) if select('#', ...) > 0 then print(...) end end)(";

pub const Outcome = union(enum) {
    /// The chunk is not finished; the next line continues it.
    more,
    /// The line ran (or failed, with the report written).
    done,
    /// Leave the REPL with this status.
    exit: u8,
};

pub const Session = struct {
    gpa: Allocator,
    vm: *Vm,
    /// Where diagnostics and error reports go.
    err: *Writer,
    /// Compiled lines. They stay alive as long as the VM: the tracing JIT keeps
    /// pointers into them.
    chunks: std.ArrayList(compiler.Chunk) = .empty,
    /// The lines of the chunk being typed, joined by newlines.
    pending: std.ArrayList(u8) = .empty,
    /// The top-level locals of the lines so far, newest declaration of each name
    /// only: what the next chunk is compiled against (`resolve.Outer`, names
    /// owned here) and the cell of each, which stay alive through the VM's
    /// reference to the root closure that holds them.
    scope: std.ArrayList(resolve.Outer) = .empty,
    cells: std.ArrayList(*function.Upvalue) = .empty,

    pub fn init(gpa: Allocator, vm: *Vm, err: *Writer) Session {
        return .{ .gpa = gpa, .vm = vm, .err = err };
    }

    pub fn deinit(self: *Session) void {
        for (self.chunks.items) |*c| c.deinit();
        self.chunks.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        for (self.scope.items) |o| self.gpa.free(o.name);
        self.scope.deinit(self.gpa);
        self.cells.deinit(self.gpa);
    }

    /// Keep the top-level locals the line `chunk` declared, from its root
    /// closure `closure`; a name declared before is replaced in place (the
    /// older cell lives on in the closures that captured it).
    fn adopt(self: *Session, chunk: *const compiler.Chunk, closure: *function.Closure, outer_len: usize) !void {
        for (chunk.repl_exports, 0..) |ex, i| {
            const cell = closure.upvalues[outer_len + i];
            var found: ?usize = null;
            for (self.scope.items, 0..) |o, k| {
                if (std.mem.eql(u8, o.name, ex.name)) found = k;
            }
            if (found) |k| {
                self.scope.items[k].attrib = ex.attrib;
                self.cells.items[k] = cell;
            } else {
                const name = try self.gpa.dupe(u8, ex.name);
                errdefer self.gpa.free(name);
                try self.scope.append(self.gpa, .{ .name = name, .attrib = ex.attrib });
                errdefer _ = self.scope.pop();
                try self.cells.append(self.gpa, cell);
            }
        }
    }

    /// Whether a chunk is half typed (the prompt should be the continuation).
    pub fn continuing(self: *const Session) bool {
        return self.pending.items.len != 0;
    }

    /// Drop a half-typed chunk (Ctrl-C).
    pub fn abandon(self: *Session) void {
        self.pending.clearRetainingCapacity();
    }

    fn globalIsSet(self: *Session, name: []const u8) bool {
        const key = self.vm.heap.internValue(name) catch return false;
        return !self.vm.globals.get(key).isNil();
    }

    /// Take one typed line.
    pub fn submit(self: *Session, line: []const u8) !Outcome {
        if (!self.continuing()) {
            if (recognize(line)) |sc| if (!self.globalIsSet(sc.word)) {
                switch (try translate(self.gpa, sc.word, sc.rest)) {
                    .exit => |n| return .{ .exit = n },
                    .bad => |m| {
                        try self.err.print("{s}: {s}\n", .{ sc.word, m });
                        return .done;
                    },
                    .lua => |src| {
                        defer self.gpa.free(src);
                        return self.runText(src, "=(shortcut)", false);
                    },
                }
            };
        }
        if (self.continuing()) try self.pending.append(self.gpa, '\n');
        try self.pending.appendSlice(self.gpa, line);
        const text = try self.gpa.dupe(u8, self.pending.items);
        defer self.gpa.free(text);
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            self.pending.clearRetainingCapacity();
            return .done;
        }
        const out = try self.runText(text, "stdin", true);
        if (out != .more) self.pending.clearRetainingCapacity();
        return out;
    }

    const Prepared = union(enum) { chunk: compiler.Chunk, incomplete, failed };

    /// Parse and compile `text`. A parse failure that is only the end of the
    /// input coming too early is `incomplete`. With `report`, other failures
    /// print their diagnostics.
    fn prepare(self: *Session, text: []const u8, name: []const u8, report: bool) !Prepared {
        const src = try self.gpa.dupeSentinel(u8, text, 0);
        defer self.gpa.free(src);
        var diags = diag.Diagnostics.init(self.gpa);
        defer diags.deinit();
        var tree = parser.parse(self.gpa, src, &diags) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return self.failedWith(&diags, src, name, report),
        };
        defer tree.deinit();
        if (diags.hasErrors()) return self.failedWith(&diags, src, name, report);
        const chunk = compiler.compileWithOptions(self.gpa, self.vm.heap, src, tree.root, &diags, .{
            .known_globals = &interp.builtin_global_names,
            .chunk_name = name,
            .repl = .{ .outer = self.scope.items },
        }) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return self.failedWith(&diags, src, name, report),
        };
        if (diags.hasErrors()) {
            var c = chunk;
            c.deinit();
            return self.failedWith(&diags, src, name, report);
        }
        return .{ .chunk = chunk };
    }

    fn failedWith(self: *Session, diags: *const diag.Diagnostics, src: []const u8, name: []const u8, report: bool) !Prepared {
        const end = std.mem.trimEnd(u8, src, " \t\r\n").len;
        for (diags.list.items) |d| {
            if (d.severity != .@"error") continue;
            if (d.start >= end or d.code == .unterminated_long_string or d.code == .unterminated_block_comment)
                return .incomplete;
        }
        if (report) {
            const label = if (name.len > 0 and name[0] == '=') name[1..] else name;
            for (diags.list.items) |d| {
                if (d.severity != .@"error") continue;
                try self.err.print("{s}:{d}: {s}\n", .{ label, d.line, d.message });
            }
        }
        return .failed;
    }

    /// Run `text` as an expression when it is one, else as statements.
    fn runText(self: *Session, text: []const u8, name: []const u8, expression_first: bool) !Outcome {
        if (expression_first) {
            const wrapped = try std.mem.concat(self.gpa, u8, &.{ show_prelude, text, "\n)" });
            defer self.gpa.free(wrapped);
            switch (try self.prepare(wrapped, name, false)) {
                .chunk => |c| return self.execute(c),
                .incomplete, .failed => {},
            }
        }
        switch (try self.prepare(text, name, true)) {
            .chunk => |c| return self.execute(c),
            .incomplete => return .more,
            .failed => return .done,
        }
    }

    fn execute(self: *Session, chunk: compiler.Chunk) !Outcome {
        try self.chunks.append(self.gpa, chunk);
        const vm = self.vm;
        const kept = &self.chunks.items[self.chunks.items.len - 1];
        const outer_len = self.scope.items.len;
        var closure: ?*function.Closure = null;
        vm.heap.clearInterrupt(); // a Ctrl-C that missed its line is stale
        const result = vm.runLine(kept.proto, self.cells.items, &closure);
        mio.flush();
        if (closure) |cl| try self.adopt(kept, cl, outer_len);
        if (result) |_| return .done else |e| {
            if (e == error.Exit) {
                vm.unwindTo(0, 0);
                return .{ .exit = @truncate(@as(u32, @bitCast(vm.exit_status))) };
            }
            if (e == error.Interrupted) {
                try self.err.writeAll("interrupted\n");
                vm.heap.clearInterrupt();
                vm.pending_error = null;
                vm.unwindTo(0, 0);
                return .done;
            }
            if (!interp.catchable(e)) return e;
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            if (vm.describeFault(e, arena.allocator())) |fault| {
                try writeFault(self.err, fault, "");
            } else |_| {
                try self.err.print("{s}\n", .{@errorName(e)});
            }
            vm.pending_error = null;
            vm.unwindTo(0, 0);
            return .done;
        }
    }
};

/// A runtime fault as the CLI prints it: the message, located Lua-style, then
/// the call chain when control crossed a call boundary. `prefix` leads the
/// first line.
pub fn writeFault(w: *Writer, fault: interp.Fault, prefix: []const u8) Writer.Error!void {
    // A self-located message (a raised Lua value) already carries its
    // `chunk:line:` prefix; the type-name faults get a " at chunk:line" suffix.
    if (fault.self_located)
        try w.print("{s}{s}\n", .{ prefix, fault.message })
    else
        try w.print("{s}{s} at {s}:{d}\n", .{ prefix, fault.message, fault.chunk, fault.line });
    if (fault.frames.len > 1) {
        try w.writeAll("stack traceback:\n");
        for (fault.frames) |f| {
            if (f.native)
                try w.print("    [C]: in function '{s}{s}{s}'\n", .{ f.module, f.dot(), f.name })
            else if (f.main_chunk)
                try w.print("    {s}:{d}: in main chunk\n", .{ f.chunk, f.line })
            else
                try w.print("    {s}:{d}: in function '{s}'\n", .{ f.chunk, f.line, f.name });
        }
    }
}

// ---------------------------------------------------------------------------
// The terminal
// ---------------------------------------------------------------------------

/// Raw-mode editing needs POSIX termios; Windows and wasm read plain lines
/// (the console backend is Phase 6).
pub const tty_supported = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

const C = struct {
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
};

/// A terminal on `fd`, put in raw mode for the length of a line edit.
pub const Terminal = if (tty_supported) struct {
    fd: posix.fd_t,
    saved: posix.termios,

    /// Null when `fd` is not a terminal.
    pub fn open(fd: posix.fd_t) ?Terminal {
        const t = posix.tcgetattr(fd) catch return null;
        return .{ .fd = fd, .saved = t };
    }

    /// No echo, no line buffering, no signals, no flow control: keys arrive
    /// as bytes. Output processing stays on, so `\n` still ends a line.
    pub fn raw(self: *Terminal) void {
        var t = self.saved;
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.ICRNL = false;
        t.iflag.IXON = false;
        t.cc[@intFromEnum(posix.V.MIN)] = 1;
        t.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(self.fd, .FLUSH, t) catch {};
    }

    pub fn cooked(self: *Terminal) void {
        posix.tcsetattr(self.fd, .FLUSH, self.saved) catch {};
    }

    pub fn columns(self: *const Terminal) usize {
        var ws: posix.winsize = undefined;
        const request: c_ulong = @intCast(posix.T.IOCGWINSZ);
        const ok = if (builtin.link_libc)
            C.ioctl(self.fd, request, &ws) == 0
        else if (builtin.os.tag == .linux)
            std.os.linux.ioctl(self.fd, @intCast(request), @intFromPtr(&ws)) == 0
        else
            false;
        return if (ok and ws.col > 0) ws.col else 80;
    }
} else struct {
    pub fn open(_: i32) ?@This() {
        return null;
    }
    pub fn raw(_: *@This()) void {}
    pub fn cooked(_: *@This()) void {}
    pub fn columns(_: *const @This()) usize {
        return 80;
    }
};

/// Ctrl-C while a line runs (the terminal is cooked then; at the prompt ISIG
/// is off and the editor sees the byte). The handler can only reach the heap
/// through a global, so the REPL registers its VM's here.
const Sigint = struct {
    var heap: std.atomic.Value(?*gc.Heap) = .init(null);

    fn handler(_: posix.SIG) callconv(.c) void {
        if (heap.load(.acquire)) |h| h.requestInterrupt();
    }

    fn install(h: *gc.Heap) void {
        if (!tty_supported) return;
        heap.store(h, .release);
        const act: posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.INT, &act, null);
    }

    fn uninstall() void {
        if (!tty_supported) return;
        posix.sigaction(.INT, &.{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 }, null);
        heap.store(null, .release);
    }
};

/// One byte from `fd`; null at end of input.
fn readByte(fd: i32) ?u8 {
    if (!tty_supported) return null;
    var b: [1]u8 = undefined;
    while (true) {
        const rc = posix.system.read(fd, &b, 1);
        switch (posix.errno(rc)) {
            .SUCCESS => return if (rc == 0) null else b[0],
            .INTR => continue,
            else => return null,
        }
    }
}

/// Where the history lives: `$XDG_STATE_HOME/mahina/history`, else
/// `~/.local/state/mahina/history`. Null with neither variable set.
pub fn historyPath(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    if (env.get("XDG_STATE_HOME")) |x| if (x.len > 0) return try std.fs.path.join(gpa, &.{ x, "mahina", "history" });
    if (env.get("HOME")) |h| if (h.len > 0) return try std.fs.path.join(gpa, &.{ h, ".local", "state", "mahina", "history" });
    return null;
}

pub const Config = struct {
    gpa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// Standard input's descriptor.
    stdin_fd: i32 = 0,
};

/// The prompt for the current directory, `~`-abbreviated: `~/src> `.
fn writePrompt(session: *Session, env: *const std.process.Environ.Map, w: *Writer, color: bool) !void {
    if (session.continuing()) return w.writeAll("... ");
    var dir: []const u8 = "?";
    if (session.vm.system) |sys| if (sys.vtable.getcwd) |get| switch (get(sys.ctx)) {
        .ok => |d| dir = d,
        .fail => {},
    };
    const home = env.get("HOME") orelse "";
    if (color) try w.writeAll("\x1b[1;34m");
    if (home.len > 0 and std.mem.startsWith(u8, dir, home) and (dir.len == home.len or dir[home.len] == '/')) {
        try w.writeAll("~");
        try w.writeAll(dir[home.len..]);
    } else try w.writeAll(dir);
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll("> ");
}

/// Read one line with the editor. Status says how it ended; the line is in
/// `ed.line()` when submitted.
fn editLine(term: *Terminal, ed: *lineedit.Editor, hist: *const lineedit.History, prompt: []const u8) !lineedit.Status {
    const w = mio.stdout();
    const pw = lineedit.promptWidth(prompt);
    ed.reset();
    var dec: lineedit.Decoder = .{};
    term.raw();
    defer term.cooked();
    try ed.render(w, prompt, pw, term.columns());
    try w.flush();
    while (true) {
        const byte = readByte(term.fd) orelse return .eof;
        const key = dec.feed(byte) orelse continue;
        if (key == .clear) try w.writeAll("\x1b[H\x1b[2J");
        const st = try ed.handle(key, hist);
        if (st != .editing) {
            try w.writeAll(if (st == .interrupted) "^C\n" else "\n");
            try w.flush();
            return st;
        }
        try ed.render(w, prompt, pw, term.columns());
        try w.flush();
    }
}

/// A line from a pipe or file: no editing, no prompt. Null at end of input.
fn plainLine(gpa: Allocator, fd: i32, buf: *std.ArrayList(u8)) Allocator.Error!?[]const u8 {
    buf.clearRetainingCapacity();
    var got_any = false;
    while (readByte(fd)) |b| {
        got_any = true;
        if (b == '\n') break;
        try buf.append(gpa, b);
    } else if (!got_any) return null;
    return std.mem.trimEnd(u8, buf.items, "\r");
}

fn loadHistory(cfg: Config, hist: *lineedit.History, path: []const u8) void {
    const text = std.Io.Dir.cwd().readFileAlloc(cfg.io, path, cfg.gpa, .limited(4 * 1024 * 1024)) catch return;
    defer cfg.gpa.free(text);
    hist.load(text) catch {};
}

fn saveHistory(cfg: Config, hist: *const lineedit.History, path: []const u8) void {
    var aw: Writer.Allocating = .init(cfg.gpa);
    defer aw.deinit();
    hist.write(&aw.writer) catch return;
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(cfg.io, dir) catch return;
    std.Io.Dir.cwd().writeFile(cfg.io, .{ .sub_path = path, .data = aw.written() }) catch {};
}

/// Run the REPL until `exit`, end of input, or a fatal fault. On a terminal
/// the line is edited in place and the history kept in a file; otherwise lines
/// are read plain and nothing is prompted. Returns the process exit status.
pub fn interactive(cfg: Config, session: *Session) !u8 {
    var term = Terminal.open(cfg.stdin_fd);
    var hist = lineedit.History.init(cfg.gpa);
    defer hist.deinit();
    var ed = lineedit.Editor.init(cfg.gpa);
    defer ed.deinit();
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(cfg.gpa);
    const hist_path = if (term != null) try historyPath(cfg.gpa, cfg.env) else null;
    defer if (hist_path) |p| cfg.gpa.free(p);
    if (hist_path) |p| loadHistory(cfg, &hist, p);
    if (term != null) Sigint.install(session.vm.heap);
    defer if (term != null) Sigint.uninstall();

    var prompt: Writer.Allocating = .init(cfg.gpa);
    defer prompt.deinit();
    while (true) {
        var line: []const u8 = undefined;
        if (term) |*t| {
            prompt.clearRetainingCapacity();
            try writePrompt(session, cfg.env, &prompt.writer, true);
            switch (try editLine(t, &ed, &hist, prompt.written())) {
                .eof => {
                    try mio.stdout().writeAll("\n");
                    mio.flush();
                    return 0;
                },
                .interrupted => {
                    session.abandon();
                    continue;
                },
                .submitted, .editing => {},
            }
            line = ed.line();
            try hist.add(line);
            if (hist_path) |p| saveHistory(cfg, &hist, p);
        } else {
            line = (try plainLine(cfg.gpa, cfg.stdin_fd, &plain)) orelse return 0;
        }
        switch (try session.submit(line)) {
            .more, .done => {},
            .exit => |n| return n,
        }
        session.err.flush() catch {};
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "[REQ-37.1] [REQ-37.2] recognize: shortcut words, and the Lua lines that start like them" {
    try testing.expectEqualStrings("/tmp", recognize("cd /tmp").?.rest);
    try testing.expectEqualStrings("..", recognize("  cd ..").?.rest);
    try testing.expectEqualStrings("", recognize("cd").?.rest);
    try testing.expectEqualStrings("A=1 B=2", recognize("export A=1 B=2").?.rest);
    try testing.expect(recognize("cd = 5") == null);
    try testing.expect(recognize("cd(x)") == null);
    try testing.expect(recognize("cd (x)") == null);
    try testing.expect(recognize("cd.x = 1") == null);
    try testing.expect(recognize("cd[1] = 1") == null);
    try testing.expect(recognize("cd:go()") == null);
    try testing.expect(recognize("cd, x = 1, 2") == null);
    try testing.expect(recognize("cdx /tmp") == null);
    try testing.expect(recognize("exports = 1") == null);
    try testing.expect(recognize("print(1)") == null);
}

fn luaOf(gpa: Allocator, word: []const u8, rest: []const u8) ![]u8 {
    return switch (try translate(gpa, word, rest)) {
        .lua => |s| s,
        .exit => error.TestUnexpectedResult,
        .bad => error.TestUnexpectedResult,
    };
}

test "[REQ-38.1] [REQ-38.2] translate: cd reads its path as a shell word" {
    const gpa = testing.allocator;
    const b = try luaOf(gpa, "cd", "'/tmp/my dir'");
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "os.chdir(\"/tmp/my dir\")") != null);
    const c = try luaOf(gpa, "cd", "~/src/$PROJECT");
    defer gpa.free(c);
    try testing.expect(std.mem.indexOf(u8, c, "os.chdir((os.getenv(\"HOME\") or \"\") .. \"/src/\" .. (os.getenv(\"PROJECT\") or \"\"))") != null);
    const d = try luaOf(gpa, "cd", "-");
    defer gpa.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "os.chdir((os.getenv(\"OLDPWD\") or \"\"))") != null);
    const e = try luaOf(gpa, "cd", "");
    defer gpa.free(e);
    try testing.expect(std.mem.indexOf(u8, e, "os.chdir((os.getenv(\"HOME\") or \"\"))") != null);
    try testing.expect(std.mem.indexOf(u8, d, "os.setenv(\"OLDPWD\", __o) os.setenv(\"PWD\", os.getcwd())") != null);
    try testing.expectEqualStrings("cd: too many arguments", (try translate(gpa, "cd", "a b")).bad);
}

test "[REQ-39.1] [REQ-39.2] [REQ-39.3] translate: export and unset" {
    const gpa = testing.allocator;
    const a = try luaOf(gpa, "export", "PATH=$PATH:/x A=\"q r\" B='$no' C=");
    defer gpa.free(a);
    try testing.expectEqualStrings(
        "os.setenv(\"PATH\", (os.getenv(\"PATH\") or \"\") .. \":/x\") " ++
            "os.setenv(\"A\", \"q r\") os.setenv(\"B\", \"$no\") os.setenv(\"C\", \"\") ",
        a,
    );
    const b = try luaOf(gpa, "unset", "A B");
    defer gpa.free(b);
    try testing.expectEqualStrings("os.setenv(\"A\", nil) os.setenv(\"B\", nil) ", b);
    try testing.expectEqualStrings("not a valid identifier", (try translate(gpa, "export", "1A=x")).bad);
    try testing.expectEqualStrings("unterminated quote", (try translate(gpa, "export", "A='x")).bad);
    const c = try luaOf(gpa, "export", "JUSTNAME");
    defer gpa.free(c);
}

test "[REQ-40.1] translate: exit takes a status" {
    const gpa = testing.allocator;
    try testing.expectEqual(@as(u8, 0), (try translate(gpa, "exit", "")).exit);
    try testing.expectEqual(@as(u8, 3), (try translate(gpa, "exit", "3")).exit);
    try testing.expect((try translate(gpa, "exit", "999")) == .bad);
    try testing.expect((try translate(gpa, "exit", "1 2")) == .bad);
}

const util = @import("interp_testutil.zig");

/// A session on a fresh VM; `feed` lines, read what `print` wrote and what the
/// session reported.
const Rig = struct {
    vm: *Vm,
    out: Writer.Allocating,
    err: Writer.Allocating,
    session: Session,
    host: util.FakeHost,

    fn init(gpa: Allocator) !*Rig {
        const r = try gpa.create(Rig);
        r.vm = try gpa.create(Vm);
        r.vm.* = try Vm.init(gpa);
        r.out = .init(gpa);
        r.err = .init(gpa);
        r.host = util.FakeHost.init(gpa);
        r.vm.out = &r.out.writer;
        r.vm.system = r.host.system();
        try r.vm.enableSystem(.{ .files = true, .env = true, .stdio = true });
        r.session = Session.init(gpa, r.vm, &r.err.writer);
        return r;
    }

    fn deinit(r: *Rig, gpa: Allocator) void {
        r.session.deinit();
        r.vm.deinit();
        gpa.destroy(r.vm);
        r.out.deinit();
        r.err.deinit();
        r.host.deinit();
        gpa.destroy(r);
    }

    fn feed(r: *Rig, line: []const u8) !Outcome {
        return r.session.submit(line);
    }
};

test "[REQ-45.3] historyPath: XDG_STATE_HOME first, then ~/.local/state, else none" {
    const gpa = testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try testing.expect((try historyPath(gpa, &env)) == null);
    try env.put("HOME", "/home/u");
    const a = (try historyPath(gpa, &env)).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("/home/u/.local/state/mahina/history", a);
    try env.put("XDG_STATE_HOME", "/state");
    const b = (try historyPath(gpa, &env)).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("/state/mahina/history", b);
}

test "[REQ-32.1] session: expressions print their values, statements print nothing" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expect(try r.feed("1 + 1") == .done);
    try testing.expect(try r.feed("x = 5") == .done);
    try testing.expect(try r.feed("x") == .done);
    try testing.expect(try r.feed("(function() end)()") == .done);
    try testing.expect(try r.feed("1, 'two', nil") == .done);
    try testing.expectEqualStrings("2\n5\n1\ttwo\tnil\n", r.out.written());
    try testing.expectEqualStrings("", r.err.written());
}

test "[REQ-33.1] [REQ-33.2] session: a chunk that ends early waits for more lines" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expect(try r.feed("for i = 1, 3 do") == .more);
    try testing.expect(r.session.continuing());
    try testing.expect(try r.feed("  print(i)") == .more);
    try testing.expect(try r.feed("end") == .done);
    try testing.expect(!r.session.continuing());
    try testing.expectEqualStrings("1\n2\n3\n", r.out.written());
    try testing.expect(try r.feed("s = [[a") == .more);
    try testing.expect(try r.feed("b]]") == .done);
    try testing.expect(try r.feed("s") == .done);
    try testing.expect(try r.feed("x = (1 +") == .more);
    r.session.abandon();
    try testing.expect(!r.session.continuing());
}

test "[REQ-34.1] session: a syntax error is reported once and the line is dropped" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expect(try r.feed("x y") == .done);
    try testing.expect(std.mem.startsWith(u8, r.err.written(), "stdin:1: "));
    try testing.expect(!r.session.continuing());
    try testing.expect(try r.feed("print('still alive')") == .done);
    try testing.expectEqualStrings("still alive\n", r.out.written());
}

test "[REQ-34.2] session: a runtime error is reported and the next line still runs" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expect(try r.feed("error('boom')") == .done);
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "boom") != null);
    try testing.expect(try r.feed("local t = nil; t.x = 1") == .done);
    try testing.expect(try r.feed("1 + 1") == .done);
    try testing.expectEqualStrings("2\n", r.out.written());
}

test "[REQ-35.1] session: globals persist from one line to the next" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    _ = try r.feed("function inc() n = (n or 0) + 1 return n end");
    _ = try r.feed("inc()");
    _ = try r.feed("inc()");
    try testing.expectEqualStrings("1\n2\n", r.out.written());
}

test "[REQ-35.2] [REQ-35.3] session: top-level locals persist from line to line, and closures share them" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    _ = try r.feed("local n = 1");
    _ = try r.feed("n = n + 1");
    _ = try r.feed("n");
    _ = try r.feed("local function bump() n = n + 1 return n end");
    _ = try r.feed("bump()");
    _ = try r.feed("n");
    // A redeclaration is a new variable; the closure keeps the old one.
    _ = try r.feed("local n = 100");
    _ = try r.feed("n");
    _ = try r.feed("bump()");
    _ = try r.feed("local a, b = 1, 2");
    _ = try r.feed("a + b");
    try testing.expectEqualStrings("2\n3\n3\n100\n4\n3\n", r.out.written());
    try testing.expectEqualStrings("", r.err.written());
}

test "[REQ-36.1] session: locals of blocks and loops do not persist, and a recursive local function works" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    _ = try r.feed("do local hidden = 1 end");
    _ = try r.feed("for i = 1, 2 do local inner = i end");
    _ = try r.feed("hidden");
    _ = try r.feed("inner");
    _ = try r.feed("local function fact(k) if k <= 1 then return 1 end return k * fact(k - 1) end");
    _ = try r.feed("fact(5)");
    try testing.expectEqualStrings("nil\nnil\n120\n", r.out.written());
}

test "[REQ-36.2] [REQ-36.3] session: a persisted <const> cannot be assigned, and a <close> local stays in its chunk" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    _ = try r.feed("local c <const> = 7");
    _ = try r.feed("c");
    try testing.expectEqual(@as(usize, 0), r.err.written().len);
    _ = try r.feed("c = 8");
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "const") != null);
    _ = try r.feed("c");
    _ = try r.feed("local g <close> = setmetatable({}, {__close = function() print('closed') end})");
    _ = try r.feed("g");
    try testing.expectEqualStrings("7\n7\nclosed\nnil\n", r.out.written());
}

test "[REQ-36.2] session: a constant <const> folds in its own line and persists for the next ones" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    // Doc 76 D8: the line's own uses fold; the cell still carries the value.
    _ = try r.feed("local k <const> = 3; local function twice() return k * 2 end; print(twice())");
    _ = try r.feed("k + 1");
    _ = try r.feed("twice()");
    try testing.expectEqualStrings("6\n4\n6\n", r.out.written());
    try testing.expectEqualStrings("", r.err.written());
}

test "[REQ-35.4] session: persisted locals survive a garbage collection" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    _ = try r.feed("local keep = {1, 2, 3}");
    _ = try r.feed("local function sum() local s = 0 for _, v in ipairs(keep) do s = s + v end return s end");
    _ = try r.feed("for i = 1, 2000 do local junk = {i, tostring(i)} end");
    r.vm.collect();
    _ = try r.feed("sum()");
    r.vm.collect();
    _ = try r.feed("#keep");
    try testing.expectEqualStrings("6\n3\n", r.out.written());
    try testing.expectEqualStrings("", r.err.written());
}

test "[REQ-37.3] [REQ-41.1] session: cd, export, unset and exit run as shortcuts, but not over a global of that name" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    try testing.expect(try r.feed("export GREETING=hi") == .done);
    try testing.expectEqualStrings("GREETING", r.host.set_name[0..r.host.set_name_len]);
    try testing.expectEqualStrings("hi", r.host.set_value[0..r.host.set_value_len.?]);
    try testing.expect(try r.feed("cd /tmp/x") == .done);
    try testing.expectEqualStrings("/tmp/x", r.host.chdir_path[0..r.host.chdir_path_len]);
    // The export's one setenv, then the cd's chdir and its OLDPWD and PWD.
    try testing.expectEqual(@as(usize, 4), r.host.mutate_calls);
    try testing.expectEqual(Outcome{ .exit = 4 }, try r.feed("exit 4"));
    _ = try r.feed("function cd(p) print('mine', p) end");
    _ = try r.feed("cd('here')");
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqualStrings("mine\there\n", r.out.written());
    // With a global `cd`, the shortcut form is just (bad) Lua and no chdir happens.
    const calls = r.host.mutate_calls;
    _ = try r.feed("cd /tmp/y");
    try testing.expect(r.err.written().len != 0);
    try testing.expectEqual(calls, r.host.mutate_calls);
}

test "[REQ-41.2] session: a failing cd says why and does not end the session" {
    const r = try Rig.init(testing.allocator);
    defer r.deinit(testing.allocator);
    r.host.chdir_result = .not_found;
    try testing.expect(try r.feed("cd /nope") == .done);
    try testing.expect(std.mem.indexOf(u8, r.err.written(), "/nope") != null);
    try testing.expect(try r.feed("print(1)") == .done);
}
