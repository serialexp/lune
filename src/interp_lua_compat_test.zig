//! Lua 5.4 behaviours the 2026-10-25 divergence audit found mahina getting
//! wrong (TODO.md, "Lua 5.4 divergence audit: bugs"). Each expected output
//! is what `lua5.4` prints for the same program, except where an error
//! message's position prefix or wording is mahina's own.

const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;

test "string positions at the integer limits do not overflow" {
    try expectProgram(
        \\print(("hello"):sub(math.mininteger, math.maxinteger))
        \\print(("hello"):sub(math.mininteger, -2), ("hello"):sub(-3, math.maxinteger))
        \\print(("hello"):find("l", math.mininteger), string.codepoint("hi", math.mininteger, 1))
    , "hello\nhell\tllo\n3\t104\n");
}

test "results and sizes past the limits raise Lua's errors instead of overflowing" {
    try expectProgram(
        \\local function fails(msg, f, ...)
        \\  local ok, e = pcall(f, ...)
        \\  print(ok, string.find(e, msg, 1, true) ~= nil)
        \\end
        \\fails("too many results to unpack", table.unpack, {}, math.mininteger, math.maxinteger)
        \\fails("too many results to unpack", table.unpack, {}, 1, 100000000)
        \\fails("destination wrap around", table.move, {}, 1, math.maxinteger, 2)
        \\fails("too many elements to move", table.move, {}, -1, math.maxinteger, 1)
        \\fails("resulting string too large", string.rep, "ab", math.maxinteger)
        \\fails("resulting string too large", string.rep, "ab", math.maxinteger, ",")
        \\print(select('#', table.unpack({}, 1, 60000)), #("ab"):rep(3, ","))
    , "false\ttrue\nfalse\ttrue\nfalse\ttrue\nfalse\ttrue\nfalse\ttrue\nfalse\ttrue\n60000\t8\n");
}
