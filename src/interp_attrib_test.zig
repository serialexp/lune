//! Tests for doc 76: global declarations, `<const>`, read-only `for`
//! variables, `<close>` and frozen tables, at the language's surface: what a
//! program prints, the run-time faults it raises, and the compile errors the
//! scoping rules give.

const std = @import("std");
const compiler = @import("compiler.zig");
const parser = @import("parser.zig");
const diag = @import("diag.zig");
const interp = @import("interp.zig");
const testutil = @import("interp_testutil.zig");
const expectProgram = testutil.expectProgram;
const testing = std.testing;

/// Compile `source` and return its diagnostics' codes and messages, errors
/// only, in order. The parse must be clean.
const Compiled = struct {
    diags: diag.Diagnostics,

    fn of(source: [:0]const u8) !Compiled {
        const gpa = testing.allocator;
        var diags = diag.Diagnostics.init(gpa);
        errdefer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        try testing.expect(!diags.hasErrors());
        var vm = try interp.Vm.init(gpa);
        defer vm.deinit();
        if (compiler.compile(gpa, vm.heap, source, tree.root, &diags)) |chunk| {
            var c = chunk;
            c.deinit();
        } else |e| switch (e) {
            error.CompileError => {},
            else => return e,
        }
        return .{ .diags = diags };
    }

    fn deinit(self: *Compiled) void {
        self.diags.deinit();
    }

    /// The errors, warnings left out.
    fn errors(self: *const Compiled, buf: []diag.Diagnostic) []diag.Diagnostic {
        var n: usize = 0;
        for (self.diags.list.items) |d| {
            if (d.severity != .@"error") continue;
            buf[n] = d;
            n += 1;
        }
        return buf[0..n];
    }
};

/// `source` compiles with no error.
fn expectCompiles(source: [:0]const u8) !void {
    var c = try Compiled.of(source);
    defer c.deinit();
    var buf: [8]diag.Diagnostic = undefined;
    const errs = c.errors(&buf);
    if (errs.len != 0) {
        std.debug.print("unexpected error in {s}: {s}\n", .{ source, errs[0].message });
        return error.TestUnexpectedError;
    }
}

/// `source` fails to compile with exactly one error, `message`, over the
/// text `at`.
fn expectCompileError(source: [:0]const u8, code: diag.Code, message: []const u8, at: []const u8) !void {
    var c = try Compiled.of(source);
    defer c.deinit();
    var buf: [8]diag.Diagnostic = undefined;
    const errs = c.errors(&buf);
    if (errs.len != 1) {
        std.debug.print("{s}: {d} errors\n", .{ source, errs.len });
        return error.TestExpectedOneError;
    }
    try testing.expectEqual(code, errs[0].code);
    try testing.expectEqualStrings(message, errs[0].message);
    try testing.expectEqualStrings(at, source[errs[0].start..errs[0].end]);
}

// ---- global declarations (§3) ----

test "doc 76: a global declaration defines the global, a function one too" {
    try expectProgram(
        \\global print, _G
        \\global x = 1
        \\global function f() return x + 1 end
        \\print(x, f(), _G.x)
        \\
    , "1\t2\t1\n");
}

test "doc 76: a declaration without a value leaves the global as it is" {
    try expectProgram(
        \\y = 5
        \\do global y, print; print(y) end
        \\
    , "5\n");
}

test "doc 76: global x = v refuses a global that is already set" {
    try expectProgram(
        \\x = 1
        \\print(x, pcall(function() global x = 2 end))
        \\print(x, pcall(function() global function x() end end))
        \\
    , "1\tfalse\tmain:2: global 'x' already defined\n1\tfalse\tmain:3: global 'x' already defined\n");
}

test "doc 76: several names are defined last first, each checked before its store" {
    // 5.5's `initglobal`: `b` is checked and stored, then `a`.
    try expectProgram(
        \\a = 0
        \\local ok, err = pcall(function() global a, b = 1, 2 end)
        \\print(ok, err, a, b)
        \\
    , "false\tmain:2: global 'a' already defined\t0\t2\n");
}

test "doc 76: a nil value defines nothing, and false is a value" {
    try expectProgram(
        \\global print, pcall
        \\global n = nil
        \\global n = false
        \\print(n, pcall(function() global n = 1 end))
        \\
    , "false\tfalse\tmain:4: global 'n' already defined\n");
}

test "doc 76: inside a declaration's scope, every free name must be declared" {
    try expectCompileError("global x\ny = 1", .undeclared_variable, "variable 'y' not declared", "y");
    try expectCompileError("global x\nprint(x)", .undeclared_variable, "variable 'print' not declared", "print");
    try expectCompileError("global x\nlocal function g() return y end", .undeclared_variable, "variable 'y' not declared", "y");
    // The declaration's own initializer is outside its scope (5.5).
    try expectCompileError("global x\nglobal y = z", .undeclared_variable, "variable 'z' not declared", "z");
    try expectCompiles("global x, print\nprint(x)");
    try expectCompiles("local y\nglobal x\ny = 1");
}

test "doc 76: a declaration's scope ends with its block" {
    try expectCompiles("do global x end\ny = 1");
    try expectCompiles("local function g() global x end\ny = 1");
    try expectCompiles("y = 1\nglobal x");
}

test "doc 76: global * admits every name, wherever it is in scope" {
    try expectCompiles("global x\nglobal *\ny = 1");
    try expectCompiles("global *\nglobal x\ny = 1");
    try expectCompiles("global *\nprint(1)");
}

test "doc 76: a declared global is the global, whatever the declaration shadows" {
    try expectProgram(
        \\local x = "local"
        \\do
        \\  global x = "global"
        \\  global print
        \\  print(x)
        \\end
        \\print(x, _G.x)
        \\
    , "global\nlocal\tglobal\n");
}

// ---- read-only variables (§3.4, §4) ----

test "doc 76: a <const> variable cannot be assigned, its value can" {
    try expectProgram(
        \\local t <const> = {}
        \\t.x = 1
        \\local <const> a, b = 2, 3
        \\print(t.x, a, b)
        \\
    , "1\t2\t3\n");
    try expectCompileError("local x <const> = 1\nx = 2", .assign_to_const, "attempt to assign to const variable 'x'", "x");
    try expectCompileError("local x <const> = 1\nx += 2", .assign_to_const, "attempt to assign to const variable 'x'", "x");
    try expectCompileError("local f <const> = 1\nfunction f() end", .assign_to_const, "attempt to assign to const variable 'f'", "f");
    try expectCompileError("local x <const> = 1\nlocal function g() x = 2 end", .assign_to_const, "attempt to assign to const variable 'x'", "x");
    try expectCompileError("local a, b <const> = 1, 2\na, b = 3, 4", .assign_to_const, "attempt to assign to const variable 'b'", "b");
    try expectCompiles("local x <const> = 1\ndo local x = 2; x = 3 end");
}

test "doc 76: a <const> global and a <const> * refuse assignment, _G does not" {
    try expectCompileError("global <const> x\nx = 1", .assign_to_const, "attempt to assign to const variable 'x'", "x");
    try expectCompileError("global <const> *\ny = 1", .assign_to_const, "attempt to assign to const variable 'y'", "y");
    try expectCompiles("global <const> *\nglobal y\ny = 1");
    try expectCompiles("global <const> x = 1");
    try expectProgram(
        \\global <const> x = 1
        \\global <const> print, _G
        \\_G.x = 2
        \\print(x)
        \\
    , "2\n");
}

test "doc 76: a for loop's control variable is read-only, the others are not" {
    try expectCompileError("for i = 1, 2 do i = 3 end", .assign_to_const, "attempt to assign to const variable 'i'", "i");
    try expectCompileError("for k, v in pairs({}) do k = 1 end", .assign_to_const, "attempt to assign to const variable 'k'", "k");
    try expectCompiles("for k, v in pairs({}) do v = 1 end");
    try expectCompiles("for i = 1, 2 do local j = i; j = 3 end");
}

// ---- to-be-closed variables (§6) ----

/// A helper every `<close>` program starts with: `closer(name)` is a value
/// whose `__close` appends `name:err` to `log`.
const closer_prelude =
    \\local log = {}
    \\local function closer(name)
    \\  return setmetatable({}, { __close = function(_, err) log[#log + 1] = name .. ":" .. tostring(err) end })
    \\end
    \\local function flush() local s = table.concat(log, " ") log = {} return s end
    \\
;

test "doc 76: <close> variables close at the end of their scope, last first" {
    try expectProgram(closer_prelude ++
        \\do
        \\  local a <close> = closer("a")
        \\  local b <close>, c = closer("b"), closer("unclosed")
        \\  local d <close> = nil
        \\  local e <close> = false
        \\  log[#log + 1] = "body"
        \\end
        \\print(flush())
        \\local function top()
        \\  local x <close> = closer("x")
        \\end
        \\top()
        \\print(flush())
        \\
    , "body b:nil a:nil\nx:nil\n");
}

test "doc 76: break and return close, after the returned values are computed" {
    try expectProgram(closer_prelude ++
        \\for i = 1, 3 do
        \\  local z <close> = closer("z" .. i)
        \\  if i == 2 then break end
        \\end
        \\print(flush())
        \\local function one()
        \\  local x <close> = closer("x")
        \\  return #log, 2
        \\end
        \\local function all()
        \\  local x <close> = closer("y")
        \\  return select(2, "a", "b", "c")
        \\end
        \\local function nested()
        \\  local x <close> = closer("outer")
        \\  do
        \\    local y <close> = closer("inner")
        \\    return "r"
        \\  end
        \\end
        \\print(one())
        \\print(all())
        \\print(nested())
        \\print(flush())
        \\local n = 0
        \\repeat
        \\  n = n + 1
        \\  local r <close> = closer("r" .. n)
        \\until n >= 2
        \\print(flush())
        \\
    , "z1:nil z2:nil\n0\t2\nb\tc\nr\nx:nil y:nil inner:nil outer:nil\nr1:nil r2:nil\n");
}

test "doc 76: an error closes the variables it unwinds through and is passed to them" {
    try expectProgram(closer_prelude ++
        \\local function inner()
        \\  local i <close> = closer("i")
        \\  error("boom", 0)
        \\end
        \\print(pcall(function()
        \\  local o <close> = closer("o")
        \\  inner()
        \\end))
        \\print(flush())
        \\print(xpcall(function()
        \\  local w <close> = closer("w")
        \\  error("e", 0)
        \\end, function(m) return "handled " .. m end))
        \\print(flush())
        \\
    , "false\tboom\ni:boom o:boom\nfalse\thandled e\nw:handled e\n");
}

test "doc 76: an error in __close is passed to the rest, then raised" {
    try expectProgram(closer_prelude ++
        \\local function bad(m) return setmetatable({}, { __close = function() error(m, 0) end }) end
        \\print(pcall(function()
        \\  local a <close> = closer("a")
        \\  local b <close> = bad("in b")
        \\  local c <close> = closer("c")
        \\end))
        \\print(flush())
        \\print(pcall(function()
        \\  local a <close> = closer("a")
        \\  local b <close> = bad("in b")
        \\  error("first", 0)
        \\end))
        \\print(flush())
        \\local function f()
        \\  local a <close> = closer("a")
        \\  local b <close> = bad("in b")
        \\  return 1
        \\end
        \\print(pcall(f))
        \\print(flush())
        \\
    , "false\tin b\nc:nil a:in b\nfalse\tin b\na:in b\nfalse\tin b\na:in b\n");
}

test "doc 76: a value that cannot be closed is refused where it is declared" {
    try expectProgram(
        \\print(pcall(function() local x <close> = 42 end))
        \\print(pcall(function() local y <close> = {} end))
        \\local t = setmetatable({}, { __close = function() end })
        \\print(pcall(function()
        \\  local z <close> = t
        \\  getmetatable(t).__close = nil
        \\end))
        \\
    , "false\tmain:1: variable 'x' got a non-closable value\n" ++
        "false\tmain:2: variable 'y' got a non-closable value\n" ++
        "false\tattempt to call a nil value (metamethod 'close')\n");
}

test "doc 76: a <close> variable is read-only" {
    try expectCompileError("local x <close> = nil\nx = 1", .assign_to_const, "attempt to assign to const variable 'x'", "x");
}

test "doc 76: a generic for's fourth value is closed when the loop ends, by its end or a break" {
    try expectProgram(closer_prelude ++
        \\local function iter(name)
        \\  local n = 0
        \\  return function() n = n + 1; if n <= 2 then return n end end, nil, nil, closer(name)
        \\end
        \\for i in iter("done") do log[#log + 1] = i end
        \\print(flush())
        \\for i in iter("broken") do if i == 1 then break end end
        \\print(flush())
        \\print(pcall(function() for i in iter("raised") do error("x", 0) end end))
        \\print(flush())
        \\local function find()
        \\  for i in iter("returned") do if i == 2 then return i end end
        \\end
        \\print(find(), flush())
        \\for k, v in pairs({ 1 }) do log[#log + 1] = k end
        \\print(flush())
        \\print(pcall(function() for k in next, {}, nil, 1 do end end))
        \\
    , "1 2 done:nil\nbroken:nil\nfalse\tx\nraised:x\n2\treturned:nil\n1\n" ++
        "false\tmain:22: variable '(for state)' got a non-closable value\n");
}

test "doc 76: coroutine.close runs the pending closes, and a dying coroutine runs its own" {
    try expectProgram(closer_prelude ++
        \\local co = coroutine.create(function()
        \\  local k <close> = closer("k")
        \\  coroutine.yield(1)
        \\end)
        \\print(coroutine.resume(co))
        \\print(coroutine.close(co), flush(), coroutine.status(co))
        \\local bad = coroutine.create(function()
        \\  local k <close> = setmetatable({}, { __close = function() error("closing", 0) end })
        \\  coroutine.yield()
        \\end)
        \\coroutine.resume(bad)
        \\print(coroutine.close(bad))
        \\local dies = coroutine.create(function()
        \\  local k <close> = closer("k2")
        \\  error("dead", 0)
        \\end)
        \\print(coroutine.resume(dies))
        \\print(flush())
        \\
    , "true\t1\ntrue\tk:nil\tdead\nfalse\tclosing\nfalse\tdead\nk2:dead\n");
}
