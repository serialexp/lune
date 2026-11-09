//! Diagnostics — a shared sink for lexer, parser and compiler errors.
//!
//! Every diagnostic carries a stable `Code` (doc 74 §6.4): one per message, so
//! a client can filter or link by code, and better prose can replace a message
//! later without touching a call site. A code owns its static message; the one
//! diagnostic whose text names something (the unknown-global lint) builds its
//! message at the call site and gives it a code all the same. A diagnostic
//! carries a byte span + line so a front-end driver (or the visualiser) can
//! point at the offending source, and optionally a second span with a short
//! label (the `function` an `end` was expected for).

const std = @import("std");

pub const Severity = enum { @"error", warning };

/// A stable identifier for one diagnostic message. The number never changes or
/// gets reused; `id()` renders it (`E0123`, `W0001` for the lints). Ranges:
/// 1–99 lexer, 100–199 parser, 200–299 compiler limits and rules, 300–399
/// string literals, 9000+ lints.
pub const Code = enum(u16) {
    // ---- lexer ----
    unterminated_block_comment = 1,
    unterminated_long_string = 2,
    malformed_number = 3,
    unterminated_string = 4,
    unexpected_character = 5,
    unterminated_template = 6,
    template_double_brace = 7,
    template_too_deep = 8,

    // ---- parser ----
    expected_end_of_input = 101,
    expected_function_after_async = 102,
    expected_statement = 103,
    expected_function_name = 104,
    expected_variable_name = 105,
    cannot_assign = 106,
    expected_assign = 107,
    expected_then = 108,
    expected_end_if = 109,
    expected_do = 110,
    expected_end_while = 111,
    expected_until = 112,
    expected_loop_variable = 113,
    expected_comma_after_for_start = 114,
    expected_end_for = 115,
    expected_in = 116,
    expected_end_do = 117,
    expected_name_after_dot = 118,
    expected_method_name = 119,
    expected_lparen_params = 120,
    expected_param_name = 121,
    expected_rparen_params = 122,
    expected_end_function = 123,
    expected_type_name = 124,
    expected_type_name_after_dot = 125,
    expected_field_name = 126,
    expected_rbracket = 127,
    expected_lparen_args = 128,
    expected_rparen_args = 129,
    expected_rparen = 130,
    expected_expression = 131,
    expected_rbracket_key = 132,
    expected_assign_after_key = 133,
    expected_rbrace = 134,
    nesting_too_deep = 135,
    expected_attribute_name = 136,
    expected_attribute_close = 137,
    unknown_attribute = 138,
    global_close = 139,
    multiple_close = 140,

    // ---- compiler ----
    function_too_large = 201,
    too_many_registers = 202,
    too_many_constants = 203,
    too_many_upvalues = 204,
    vararg_outside_vararg_function = 205,
    break_outside_loop = 206,
    too_many_parameters = 207,
    too_many_nested_functions = 208,
    too_many_arguments = 209,
    undeclared_variable = 210,
    assign_to_const = 211,

    // ---- string literals ----
    hex_escape_digits = 301,
    hex_escape_not_ascii = 302,
    decimal_escape_not_ascii = 303,
    unicode_escape_open_brace = 304,
    unicode_escape_out_of_range = 305,
    unicode_escape_no_digits = 306,
    unicode_escape_close_brace = 307,
    unicode_escape_invalid = 308,
    invalid_escape = 309,
    invalid_utf8 = 310,

    // ---- lints ----
    undefined_global = 9001,

    /// The code as shown to a person: a letter and four digits.
    pub fn id(self: Code) []const u8 {
        @setEvalBranchQuota(100_000);
        return switch (self) {
            inline else => |c| comptime std.fmt.comptimePrint("{c}{d:0>4}", .{
                @as(u8, if (@intFromEnum(c) >= 9000) 'W' else 'E'),
                if (@intFromEnum(c) >= 9000) @intFromEnum(c) - 9000 else @intFromEnum(c),
            }),
        };
    }

    /// The message of this code. For `undefined_global` this is the headline;
    /// the diagnostic itself names the global.
    pub fn message(self: Code) []const u8 {
        return switch (self) {
            .unterminated_block_comment => "unterminated block comment",
            .unterminated_long_string => "unterminated long string",
            .malformed_number => "malformed number",
            .unterminated_string => "unterminated string",
            .unexpected_character => "unexpected character",
            .unterminated_template => "unterminated template",
            .template_double_brace => "'{{' in a template: write \\{ for a brace, or put a space between the hole's brace and a table constructor",
            .template_too_deep => "templates nested too deeply (more than 200 levels)",

            .expected_end_of_input => "expected end of input",
            .expected_function_after_async => "expected 'function' after 'async'",
            .expected_statement => "expected a statement (assignment or call)",
            .expected_function_name => "expected function name",
            .expected_variable_name => "expected variable name",
            .cannot_assign => "cannot assign to this expression",
            .expected_assign => "expected '=' in assignment",
            .expected_then => "expected 'then'",
            .expected_end_if => "expected 'end' to close 'if'",
            .expected_do => "expected 'do'",
            .expected_end_while => "expected 'end' to close 'while'",
            .expected_until => "expected 'until' to close 'repeat'",
            .expected_loop_variable => "expected loop variable",
            .expected_comma_after_for_start => "expected ',' after numeric-for start",
            .expected_end_for => "expected 'end' to close 'for'",
            .expected_in => "expected '=' or 'in' in for-loop",
            .expected_end_do => "expected 'end' to close 'do'",
            .expected_name_after_dot => "expected name after '.'",
            .expected_method_name => "expected method name after ':'",
            .expected_lparen_params => "expected '(' for parameter list",
            .expected_param_name => "expected parameter name",
            .expected_rparen_params => "expected ')' after parameters",
            .expected_end_function => "expected 'end' to close function",
            .expected_type_name => "expected type name",
            .expected_type_name_after_dot => "expected type name after '.'",
            .expected_field_name => "expected field name after '.'",
            .expected_rbracket => "expected ']'",
            .expected_lparen_args => "expected '(' to start call arguments",
            .expected_rparen_args => "expected ')' to close call arguments",
            .expected_rparen => "expected ')'",
            .expected_expression => "expected an expression",
            .expected_rbracket_key => "expected ']' in table key",
            .expected_assign_after_key => "expected '=' after table key",
            .expected_rbrace => "expected '}' to close table",
            .nesting_too_deep => "too deeply nested (more than 200 levels)",
            .expected_attribute_name => "expected attribute name after '<'",
            .expected_attribute_close => "expected '>' to close attribute",
            .unknown_attribute => "unknown attribute (expected 'const' or 'close')",
            .global_close => "a global cannot be to-be-closed",
            .multiple_close => "more than one to-be-closed variable in one list",

            .function_too_large => "function too large (2^31 instruction limit)",
            .too_many_registers => "function needs too many registers",
            .too_many_constants => "too many constants",
            .too_many_upvalues => "function needs too many upvalues",
            .vararg_outside_vararg_function => "cannot use '...' outside a vararg function",
            .break_outside_loop => "break outside a loop",
            .too_many_parameters => "too many parameters",
            .too_many_nested_functions => "too many nested functions",
            .too_many_arguments => "too many arguments",
            .undeclared_variable => "variable not declared (a 'global' declaration is in scope)",
            .assign_to_const => "cannot assign to a const variable",

            .hex_escape_digits => "\\x escape needs exactly two hex digits",
            .hex_escape_not_ascii => "\\x escape must be ASCII (<= 0x7F); use \\u{...} for a code point or a byte array for a raw byte",
            .decimal_escape_not_ascii => "\\ddd escape must be ASCII (<= 127); use \\u{...} for a code point or a byte array for a raw byte",
            .unicode_escape_open_brace => "\\u must be followed by '{'",
            .unicode_escape_out_of_range => "\\u{...} code point out of range (> 0x10FFFF)",
            .unicode_escape_no_digits => "\\u{...} needs at least one hex digit",
            .unicode_escape_close_brace => "\\u{...} missing closing '}'",
            .unicode_escape_invalid => "\\u{...} is not a valid code point (surrogate or out of range)",
            .invalid_escape => "invalid escape sequence",
            .invalid_utf8 => "string literal is not valid UTF-8",

            .undefined_global => "undefined global",
        };
    }
};

/// A second place a diagnostic points at, with a short label.
pub const Related = struct {
    start: u32,
    end: u32,
    /// Static text, e.g. "'if' opened here".
    label: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    /// Human-readable. Usually `code.message()`; a diagnostic that names
    /// something (the unknown-global lint) formats its own through
    /// `Diagnostics.addFmt`, and the sink owns that text: it lives as long as
    /// the sink, whatever became of what was being compiled.
    message: []const u8,
    /// Byte span into the source: `[start, end)`.
    start: u32,
    end: u32,
    /// 1-based line of `start`.
    line: u32,
    related: ?Related = null,
};

/// An append-only collection of diagnostics. Backed by an unmanaged
/// `std.ArrayList` (methods take the allocator explicitly in this toolchain).
pub const Diagnostics = struct {
    list: std.ArrayList(Diagnostic) = .empty,
    gpa: std.mem.Allocator,
    /// The messages `addFmt` formatted.
    owned: std.ArrayList([]u8) = .empty,
    /// A diagnostic was lost to an allocation failure: what is here is not the
    /// whole story, so a client must not present it as a clean result.
    incomplete: bool = false,

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.list.deinit(self.gpa);
        for (self.owned.items) |m| self.gpa.free(m);
        self.owned.deinit(self.gpa);
    }

    pub fn add(self: *Diagnostics, d: Diagnostic) void {
        // A sink that itself fails to allocate has nothing useful to do; drop
        // the diagnostic rather than propagate an error through every lex/parse
        // call, but say so: `incomplete` is how the server learns it.
        self.list.append(self.gpa, d) catch {
            self.incomplete = true;
        };
    }

    /// Add `d` with a message formatted from `fmt` and `args`, which the sink
    /// keeps. Like `add`, a failed allocation drops it and marks the sink
    /// incomplete.
    pub fn addFmt(self: *Diagnostics, d: Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch {
            self.incomplete = true;
            return;
        };
        self.owned.append(self.gpa, msg) catch {
            self.gpa.free(msg);
            self.incomplete = true;
            return;
        };
        var with = d;
        with.message = msg;
        self.add(with);
    }

    /// Report an error with the code's own message.
    pub fn report(self: *Diagnostics, code: Code, start: u32, end: u32, line: u32) void {
        self.reportRelated(code, start, end, line, null);
    }

    /// `report`, pointing at a second place too.
    pub fn reportRelated(self: *Diagnostics, code: Code, start: u32, end: u32, line: u32, related: ?Related) void {
        self.add(.{
            .severity = .@"error",
            .code = code,
            .message = code.message(),
            .start = start,
            .end = end,
            .line = line,
            .related = related,
        });
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.list.items.len;
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.list.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }
};

test "diagnostics collect and report errors" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    try std.testing.expect(!diags.hasErrors());
    diags.report(.unterminated_string, 4, 9, 1);
    try std.testing.expectEqual(@as(usize, 1), diags.count());
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqualStrings("unterminated string", diags.list.items[0].message);
    try std.testing.expectEqual(Code.unterminated_string, diags.list.items[0].code);
    try std.testing.expect(!diags.incomplete);
}

test "a related span travels with its diagnostic" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    diags.reportRelated(.expected_end_if, 30, 33, 3, .{ .start = 0, .end = 2, .label = "'if' opened here" });
    const r = diags.list.items[0].related.?;
    try std.testing.expectEqual(@as(u32, 0), r.start);
    try std.testing.expectEqualStrings("'if' opened here", r.label);
}

test "a formatted message belongs to the sink" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();
    diags.addFmt(.{ .severity = .warning, .code = .undefined_global, .message = undefined, .start = 0, .end = 1, .line = 1 }, "undefined global '{s}'", .{"x"});
    try std.testing.expectEqualStrings("undefined global 'x'", diags.list.items[0].message);
}

test "an allocation failure marks the sink incomplete instead of vanishing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var diags = Diagnostics.init(failing.allocator());
    defer diags.deinit();
    diags.report(.malformed_number, 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), diags.count());
    try std.testing.expect(diags.incomplete);
}

test "codes render as a letter and four digits, and are unique" {
    try std.testing.expectEqualStrings("E0001", Code.unterminated_block_comment.id());
    try std.testing.expectEqualStrings("E0109", Code.expected_end_if.id());
    try std.testing.expectEqualStrings("W0001", Code.undefined_global.id());
    // No two codes share a number or an id.
    const all = std.enums.values(Code);
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            try std.testing.expect(@intFromEnum(a) != @intFromEnum(b));
            try std.testing.expect(!std.mem.eql(u8, a.id(), b.id()));
        }
        try std.testing.expect(a.message().len > 0);
    }
}
