//! Tests for string interpolation (doc 82): backtick templates. Language
//! level, source in and output out, through `expectProgram`, which runs each
//! program across the GC-stress and trace-mode legs, so every output here is
//! also the cross-tier parity check. Syntax errors go through the parser.

const std = @import("std");
const diag = @import("diag.zig");
const parser = @import("parser.zig");
const util = @import("interp_testutil.zig");

const testing = std.testing;
const expectProgram = util.expectProgram;

/// The first diagnostic `source` raises, which must be `code`.
fn expectSyntaxError(source: [:0]const u8, code: diag.Code) !void {
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    if (parser.parse(testing.allocator, source, &diags)) |tree| {
        var t = tree;
        t.deinit();
    } else |_| {}
    try testing.expect(diags.hasErrors());
    try testing.expectEqual(code, diags.list.items[0].code);
}

fn expectParses(source: [:0]const u8) !void {
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());
}

// ---- REQ-102: the basic form ----

test "[REQ-102.1] a template builds a string from text and holes" {
    try expectProgram("print(`a{1}b`)", "a1b\n");
}

test "[REQ-102.2] a template with no hole is its text" {
    try expectProgram("print(`just text`, `` == '')", "just text\ttrue\n");
}

test "[REQ-102.3] holes may be adjacent or at either end, and chunks empty" {
    try expectProgram("print(`{1}{2}`, `{1}`, `{1}x`, `x{1}`)", "12\t1\t1x\tx1\n");
}

test "[REQ-102.4] a hole holds any expression" {
    try expectProgram(
        \\local t = {x = 5}
        \\local function f() return "F" end
        \\print(`{#({1, 2})}`, `a{`b{1}`}c`, `{f()}{t.x}{t["x"] + 1}`)
    , "2\tab1c\tF56\n");
}

// ---- REQ-103: escapes ----

test "[REQ-103.1] a backslash escapes the backtick, the braces and itself" {
    try expectProgram("print(`\\`\\{\\}\\\\`)", "`{}\\\n");
}

test "[REQ-103.2] the ordinary string escapes work in the text" {
    try expectProgram("print(`a\\tb\\x41\\n\\z   c`)", "a\tbA\nc\n");
}

test "[REQ-103.5] \\u{41} is the Unicode escape, \\\\u{41} a backslash, u and a hole" {
    try expectProgram("print(`\\u{41}`, `\\\\u{41}`)", "A\t\\u41\n");
}

test "[REQ-103.4] a right brace in the text is itself" {
    try expectProgram("print(`a}b`)", "a}b\n");
}

// ---- REQ-104: newlines ----

test "[REQ-104.1] a newline in the text is a newline in the string" {
    try expectProgram("local s = `a\nb`\nprint(#s, s == 'a\\nb')", "3\ttrue\n");
}

test "[REQ-104.2] a backslash before a newline gives the same newline" {
    try expectProgram("local s = `a\\\nb`\nprint(#s, s == 'a\\nb')", "3\ttrue\n");
}

test "[REQ-104.3] each kind of line break is one LF, raw or escaped" {
    try expectProgram(
        "print(`a\r\nb` == 'a\\nb', `a\n\rb` == 'a\\nb', `a\rb` == 'a\\nb', `a\\\r\nb` == 'a\\nb', `a\\\n\rb` == 'a\\nb', `a\\\rb` == 'a\\nb')",
        "true\ttrue\ttrue\ttrue\ttrue\ttrue\n",
    );
}

test "[REQ-104.4] a hole may span lines" {
    try expectProgram("print(`{1 +\n  2}`)", "3\n");
}

// ---- REQ-105: malformed templates ----

test "[REQ-105.1] a hole opener followed by a table opener is a syntax error" {
    try expectSyntaxError("local s = `{{1, 2}}`", .template_double_brace);
    try expectParses("local s = `{ {1, 2} }`");
    try expectParses("local s = `{({1, 2})}`");
}

test "[REQ-105.2] an empty hole is a syntax error" {
    try expectSyntaxError("local s = `a{}b`", .expected_expression);
    try expectSyntaxError("local s = `a{  }b`", .expected_expression);
    try expectSyntaxError("local s = `a{ --[[ nothing ]] }b`", .expected_expression);
}

test "[REQ-105.3] an unterminated template reports its opening backtick" {
    inline for (.{ "x = 1 `abc", "x = 1 `abc{y", "x = 1 `abc{y}d" }) |src| {
        var diags = diag.Diagnostics.init(testing.allocator);
        defer diags.deinit();
        if (parser.parse(testing.allocator, src, &diags)) |tree| {
            var t = tree;
            t.deinit();
        } else |_| {}
        try testing.expectEqual(diag.Code.unterminated_template, diags.list.items[0].code);
        try testing.expectEqual(@as(u32, 6), diags.list.items[0].start);
    }
}

test "[REQ-105.4] a template directly after a callee is a syntax error" {
    try expectSyntaxError("f`x`", .expected_statement);
    try expectSyntaxError("local s = f`x`", .expected_statement);
    try expectParses("local s = f(`x`)");
}

test "[REQ-105.5] a format specifier in a hole is a syntax error" {
    try expectSyntaxError("local s = `{x:%d}`", .expected_method_name);
    try expectSyntaxError("local s = `{x:%5.2f}`", .malformed_number);
}

test "[REQ-105.6] nesting deeper than the limit is a syntax error, not a crash" {
    const gpa = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "local s = ");
    const depth = 5000;
    for (0..depth) |_| try src.appendSlice(gpa, "`{");
    try src.append(gpa, '1');
    for (0..depth) |_| try src.appendSlice(gpa, "}`");
    try src.append(gpa, 0);
    const z: [:0]const u8 = src.items[0 .. src.items.len - 1 :0];
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    if (parser.parse(gpa, z, &diags)) |tree| {
        var t = tree;
        t.deinit();
    } else |_| {}
    try testing.expect(diags.hasErrors());
}

// ---- REQ-106: a hole ends at its own closing brace ----

test "[REQ-106.1] braces in strings, long strings and comments do not end a hole" {
    try expectProgram(
        \\local function f(s) return s end
        \\print(`{f("}")}`, `{[=[}]=]}`, `{1 --[[ } ]] + 1}`)
        \\print(`{1 -- }
        \\}`)
    , "}\t}\t2\n1\n");
}

test "[REQ-106.2] a table constructor in a hole keeps its braces" {
    try expectProgram("print(`{({a = 1}).a}`, `{ {a = 2}.a }`)", "1\t2\n");
}

test "[REQ-106.3] a backtick in a string or comment in a hole is not a template" {
    try expectProgram("print(`{\"`\"}{1 --[[ ` ]]}`)", "`1\n");
}

// ---- REQ-108: the evaluation schedule ----

test "[REQ-108.1] every hole is evaluated before any value is converted" {
    try expectProgram(
        \\local obj = setmetatable({n = 1}, {__tostring = function(o) return "n=" .. o.n end})
        \\local function change() obj.n = 2 return "c" end
        \\print(`{obj} {change()}`)
    , "n=2 c\n");
}

test "[REQ-108.2] each value is converted once, in source order" {
    try expectProgram(
        \\local log = {}
        \\local function mk(name)
        \\  return setmetatable({}, {__tostring = function() log[#log + 1] = name return name end})
        \\end
        \\local s = `{mk("a")}{mk("b")}{mk("c")}`
        \\print(s, table.concat(log, ","))
    , "abc\ta,b,c\n");
}

test "[REQ-108.3] a hole is one value: nothing is nil, several give the first" {
    try expectProgram(
        \\local function none() end
        \\local function two() return "x", "y" end
        \\local function va(...) return `{...}` end
        \\print(`{none()}`, `{two()}`, va("p", "q"), va())
    , "nil\tx\tp\tnil\n");
}

// ---- REQ-109: conversion ----

test "[REQ-109.1] scalars convert as tostring converts them" {
    try expectProgram(
        \\local vs = {1, -2, 1.5, 1e100, 0.1, true, false, "s", 2^63}
        \\local ok = true
        \\for _, v in ipairs(vs) do ok = ok and `{v}` == tostring(v) end
        \\print(ok, `{nil}` == tostring(nil))
    , "true\ttrue\n");
}

test "[REQ-109.2] __tostring converts, including a handler that yields" {
    try expectProgram(
        \\local t = setmetatable({}, {__tostring = function() return "T!" end})
        \\print(`obj={t}`)
        \\local y = setmetatable({}, {__tostring = function() coroutine.yield("paused") return "Y" end})
        \\local co = coroutine.wrap(function() return `v={y}` end)
        \\print(co())
        \\print(co())
    , "obj=T!\npaused\nv=Y\n");
}

test "[REQ-109.3] a __tostring that returns a non-string raises tostring's error" {
    try expectProgram(
        \\local bad = setmetatable({}, {__tostring = function() return {} end})
        \\local _, a = pcall(function() return `x{bad}` end)
        \\local _, b = pcall(tostring, bad)
        \\print(a:match("'__tostring' must return a string$") ~= nil, b:match("'__tostring' must return a string$") ~= nil)
    , "true\ttrue\n");
}

test "[REQ-109.4] rebinding tostring does not change a template" {
    try expectProgram(
        \\local tostring = function() return "X" end
        \\print(`{1}{true}`)
        \\_G.tostring = function() return "Y" end
        \\print(`{2}`)
    , "1true\n2\n");
}

test "[REQ-109.5] an error in a hole or its conversion reports that hole" {
    try expectProgram(
        \\local bad = setmetatable({}, {__tostring = function() return {} end})
        \\local _, a = pcall(function()
        \\  return `x
        \\  {1 + nil}`
        \\end)
        \\local _, b = pcall(function()
        \\  local s = `x
        \\  {bad}`
        \\end)
        \\print(a:match("^main:(%d+):"), b:match("^main:(%d+):"))
    , "4\t8\n");
}

// ---- REQ-110: the result ----

test "[REQ-110.1] a template is the pieces joined after tostring" {
    try expectProgram(
        \\local t = setmetatable({}, {__tostring = function() return "T" end})
        \\local function same(a, b) return `<{a}|{b}>` == "<" .. tostring(a) .. "|" .. tostring(b) .. ">" end
        \\print(same(1, "x"), same(nil, true), same(t, 2.5), same("", {} ~= nil))
    , "true\ttrue\ttrue\ttrue\n");
}

test "[REQ-110.2] NUL bytes survive" {
    try expectProgram("local s = `a\\0b{'c\\0d'}`\nprint(#s, s == 'a\\0bc\\0d')", "6\ttrue\n");
}

test "[REQ-110.3] a template in a loop gives the same output in every mode" {
    try expectProgram(
        \\local acc = 0
        \\for i = 1, 3000 do
        \\  local s = `n={i} sq={i * i} {i % 2 == 0}`
        \\  acc = acc + #s
        \\end
        \\print(acc)
    , "64936\n");
}
