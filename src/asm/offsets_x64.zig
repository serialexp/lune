//! Doc 60 §3.2: the comptime check of `offsets_x64.inc`, the one file of
//! numbers the hand-written host-call entry (`hostcall_x64.S`) depends on.
//!
//! Zig reorders non-`extern` struct fields, so `Vm`, `CallFrame` and the rest
//! have no fixed layout. The `.inc` file is checked in and human-readable;
//! this file `@embedFile`s it and compares every `.set NAME, N` line against
//! the value the compiler computes (`@offsetOf`/`@sizeOf`/`@alignOf`/
//! `@bitOffsetOf`, or a named constant):
//!   - a wrong value, a name this table doesn't know, a duplicate, or a name
//!     the file is missing is a compile error;
//!   - so is anything the preprocessor or the assembler could read
//!     differently from this checker: the grammar is only blank lines, `//`
//!     comments, the three mode directives, and `.set NAME, N` with N in
//!     canonical decimal (gas reads `064` as octal); only printable ASCII and
//!     tabs may appear (cpp ends a line at a bare CR); and no line may end in
//!     a backslash (cpp would splice the next line, directive and all, into
//!     it);
//!   - every problem is reported at once, each with the corrected line, so a
//!     toolchain bump that moves fields shows all the drift in one build.
//! So no unchecked number can enter the file, and layout drift fails the build
//! instead of miscomputing silently.
//!
//! Compiled only on targets that build the entry (`target.hostcallEntry`),
//! imported from `capi.zig`, in every optimize mode.
//!
//! **Safety-dependent layout.** `std`'s hash maps carry a `SafetyLock`, one
//! byte when `std.debug.runtime_safety` is on (Debug, ReleaseSafe) and empty
//! otherwise, which padding turns into 8 more bytes per map. `TraceState`
//! holds dozens of them, so `fast_block` and
//! the `Vm` fields Zig places after `trace` sit at different offsets in the
//! two kinds of build. The file therefore has a shared section plus two
//! blocks:
//!
//!     #if MAHINA_RUNTIME_SAFETY
//!     .set NAME, N      // Debug and ReleaseSafe
//!     #else
//!     .set NAME, N      // ReleaseFast and ReleaseSmall
//!     #endif
//!
//! Each name appears once in the shared section, or once in each block. A
//! build checks the shared lines and its own block, and checks only that the
//! names in the other block are known; that block is verified by the builds of
//! the other kind. The build passes the same define to the `.S` (from the
//! optimize mode), and the `.S` records it in `mahina_hostcall_offsets_safety`,
//! which `verifyAssembledMode` compares with this build's `runtime_safety`.
//!
//! Q12 (a): the register-file slices and the overflow park's `items` are
//! read through their pointer and length words. `@offsetOf` can't see inside
//! a slice, so `SLICE_PTR`/`SLICE_LEN` are pinned here to the constants
//! `verifySliceLayout` checks at run time (a unit test, and every
//! `capi.createVm`).

const std = @import("std");
const mahina = @import("mahina");
const capi = @import("../capi.zig");
const target = @import("target.zig");

const interp = mahina.interp;
const function = mahina.function;
const bytecode = mahina.bytecode;
const object = mahina.object;
const value = mahina.value;
const trace = mahina.trace;

const Vm = interp.Vm;
const VmBox = capi.VmBox;
const CallFrame = interp.CallFrame;
const Closure = function.Closure;
const Proto = bytecode.Proto;
const GcHeader = object.GcHeader;
const Value = value.Value;
const TraceState = trace.TraceState;
const ParkList = @FieldType(Vm, "parked_results");

/// Word index of a slice's pointer and length, checked at run time by
/// `verifySliceLayout` (comptime can't inspect a slice's representation).
pub const slice_ptr_word = 0;
pub const slice_len_word = 1;

const Entry = struct { name: []const u8, value: i128 };

fn off(comptime T: type, comptime field: []const u8) i128 {
    return @offsetOf(T, field);
}

fn width(comptime T: type, comptime field: []const u8) i128 {
    return @sizeOf(@FieldType(T, field));
}

/// Every number the `.S` may use, in the order of `offsets_x64.inc`.
const expected = [_]Entry{
    // VmBox and the Vm fields the entry reads or writes.
    .{ .name = "VMBOX_VM", .value = off(VmBox, "vm") },
    .{ .name = "VM_TAGS", .value = off(Vm, "tags") },
    .{ .name = "VM_PAYLOADS", .value = off(Vm, "payloads") },
    .{ .name = "VM_DEPTH", .value = off(Vm, "depth") },
    .{ .name = "VM_DEPTH_SIZE", .value = width(Vm, "depth") },
    .{ .name = "VM_STACK_TOP", .value = off(Vm, "stack_top") },
    .{ .name = "VM_STACK_TOP_SIZE", .value = width(Vm, "stack_top") },
    .{ .name = "VM_NEXT_CALL_SEQ", .value = off(Vm, "next_call_seq") },
    .{ .name = "VM_NEXT_CALL_SEQ_SIZE", .value = width(Vm, "next_call_seq") },
    .{ .name = "VM_NATIVE_REENTRY_DEPTH", .value = off(Vm, "native_reentry_depth") },
    .{ .name = "VM_NATIVE_REENTRY_DEPTH_SIZE", .value = width(Vm, "native_reentry_depth") },
    .{ .name = "VM_FRAMES", .value = off(Vm, "frames") },
    .{ .name = "VM_TRACE", .value = off(Vm, "trace") },
    .{ .name = "TRACE_FAST_BLOCK", .value = off(TraceState, "fast_block") },
    .{ .name = "TRACE_FAST_BLOCK_SIZE", .value = width(TraceState, "fast_block") },
    .{ .name = "VM_PARKED_INLINE", .value = off(Vm, "parked_inline") },
    .{ .name = "VM_PARKED_INLINE_LEN", .value = off(Vm, "parked_inline_len") },
    .{ .name = "VM_PARKED_INLINE_LEN_SIZE", .value = width(Vm, "parked_inline_len") },
    .{ .name = "VM_PARKED_RESULTS", .value = off(Vm, "parked_results") },
    .{ .name = "PARKLIST_ITEMS", .value = off(ParkList, "items") },

    // Slices (Q12 (a)): the outer offsets above, the size here, the word
    // order checked at run time.
    .{ .name = "SLICE_SIZE", .value = @sizeOf([]u8) },
    .{ .name = "SLICE_PTR", .value = slice_ptr_word * @sizeOf(usize) },
    .{ .name = "SLICE_LEN", .value = slice_len_word * @sizeOf(usize) },

    // CallFrame: the frame-array stride and all nine plain fields.
    .{ .name = "CF_SIZE", .value = @sizeOf(CallFrame) },
    .{ .name = "CF_CLOSURE", .value = off(CallFrame, "closure") },
    .{ .name = "CF_CLOSURE_SIZE", .value = width(CallFrame, "closure") },
    .{ .name = "CF_CALL_SEQ", .value = off(CallFrame, "call_seq") },
    .{ .name = "CF_CALL_SEQ_SIZE", .value = width(CallFrame, "call_seq") },
    .{ .name = "CF_BASE", .value = off(CallFrame, "base") },
    .{ .name = "CF_BASE_SIZE", .value = width(CallFrame, "base") },
    .{ .name = "CF_PC", .value = off(CallFrame, "pc") },
    .{ .name = "CF_PC_SIZE", .value = width(CallFrame, "pc") },
    .{ .name = "CF_RET_DEST", .value = off(CallFrame, "ret_dest") },
    .{ .name = "CF_RET_DEST_SIZE", .value = width(CallFrame, "ret_dest") },
    .{ .name = "CF_RET_COUNT", .value = off(CallFrame, "ret_count") },
    .{ .name = "CF_RET_COUNT_SIZE", .value = width(CallFrame, "ret_count") },
    .{ .name = "CF_VARARGS_BASE", .value = off(CallFrame, "varargs_base") },
    .{ .name = "CF_VARARGS_BASE_SIZE", .value = width(CallFrame, "varargs_base") },
    .{ .name = "CF_VARARGS_COUNT", .value = off(CallFrame, "varargs_count") },
    .{ .name = "CF_VARARGS_COUNT_SIZE", .value = width(CallFrame, "varargs_count") },
    .{ .name = "CF_CODE_CACHE_GEN", .value = off(CallFrame, "code_cache_gen") },
    .{ .name = "CF_CODE_CACHE_GEN_SIZE", .value = width(CallFrame, "code_cache_gen") },

    // Closure, Proto, and the heap object header's type byte.
    .{ .name = "CLOSURE_PROTO", .value = off(Closure, "proto") },
    .{ .name = "PROTO_NUM_PARAMS", .value = off(Proto, "num_params") },
    .{ .name = "PROTO_NUM_PARAMS_SIZE", .value = width(Proto, "num_params") },
    .{ .name = "PROTO_NUM_REGISTERS", .value = off(Proto, "num_registers") },
    .{ .name = "PROTO_NUM_REGISTERS_SIZE", .value = width(Proto, "num_registers") },
    .{ .name = "PROTO_IS_VARARG", .value = off(Proto, "is_vararg") },
    .{ .name = "PROTO_IS_VARARG_SIZE", .value = width(Proto, "is_vararg") },
    .{ .name = "GCHEADER_TYPE", .value = off(GcHeader, "type") },
    .{ .name = "GCHEADER_TYPE_SIZE", .value = width(GcHeader, "type") },

    // Value: two words, tag then payload, and the tag numbers used.
    .{ .name = "VALUE_SIZE", .value = @sizeOf(Value) },
    .{ .name = "VALUE_TAG", .value = off(Value, "tag") },
    .{ .name = "VALUE_PAYLOAD", .value = off(Value, "payload") },
    .{ .name = "TAG_NIL", .value = @intFromEnum(value.Tag.nil) },
    .{ .name = "TAG_BOOLEAN", .value = @intFromEnum(value.Tag.boolean) },
    .{ .name = "TAG_HEAP_REF", .value = @intFromEnum(value.Tag.heap_ref) },
    .{ .name = "TAG_ROW_VIEW", .value = @intFromEnum(value.Tag.row_view) },
    .{ .name = "OBJ_FUNCTION", .value = @intFromEnum(object.ObjectType.function) },

    // Limits and sentinels.
    .{ .name = "CODE_CACHE_GEN_INVALID", .value = @as(i64, @bitCast(interp.CODE_CACHE_GEN_INVALID)) },
    .{ .name = "MAX_CALL_DEPTH", .value = interp.max_call_depth },
    .{ .name = "MAX_NATIVE_REENTRY", .value = interp.max_native_reentry },
    .{ .name = "PARKED_INLINE_CAP", .value = @typeInfo(@FieldType(Vm, "parked_inline")).array.len },
    .{ .name = "ARGS_MAX", .value = target.args_max },

    // FrameResult: a packed u32, reg in the low half, count in the high.
    .{ .name = "FRAMERESULT_SIZE", .value = @sizeOf(interp.FrameResult) },
    .{ .name = "FRAMERESULT_REG_BIT", .value = @bitOffsetOf(interp.FrameResult, "reg") },
    .{ .name = "FRAMERESULT_COUNT_BIT", .value = @bitOffsetOf(interp.FrameResult, "count") },

    // ChainResult (§4.2), returned whole in rax, and the status it carries.
    .{ .name = "CHAINRESULT_SIZE", .value = @sizeOf(capi.ChainResult) },
    .{ .name = "CHAINRESULT_STATUS", .value = off(capi.ChainResult, "status") },
    .{ .name = "CHAINRESULT_FRAME_RESULT", .value = off(capi.ChainResult, "frame_result") },
    .{ .name = "MH_OK", .value = @intFromEnum(capi.mh_status.ok) },

    // Alignments the code relies on.
    .{ .name = "VMBOX_ALIGN", .value = @alignOf(VmBox) },
    .{ .name = "VM_ALIGN", .value = @alignOf(Vm) },
    .{ .name = "CF_ALIGN", .value = @alignOf(CallFrame) },
    .{ .name = "VALUE_ALIGN", .value = @alignOf(Value) },
};

comptime {
    // Q12 (a): every slice the entry reads shares one representation size.
    for ([_]type{ []u8, []u64, []Value, @FieldType(ParkList, "items") }) |S| {
        if (@sizeOf(S) != @sizeOf([]u8)) @compileError("offsets_x64: slice types differ in size");
    }
    if (@FieldType(Vm, "tags") != []u8 or @FieldType(Vm, "payloads") != []u64)
        @compileError("offsets_x64: Vm.tags/Vm.payloads are no longer []u8/[]u64");
    const problems = problemsIn(@embedFile("offsets_x64.inc"));
    if (problems.len != 0) @compileError(std.fmt.comptimePrint(
        "src/asm/offsets_x64.inc is out of date with the Zig layout ({s} build):",
        .{if (std.debug.runtime_safety) "runtime-safety" else "no-runtime-safety"},
    ) ++ problems);
}

const Section = enum { shared, safe, fast };

/// Every problem with `text` as an offsets file for this build, one per
/// line, or "" when there are none. Separate from the compile error so the
/// tests below can show what it rejects.
fn problemsIn(comptime text: []const u8) []const u8 {
    @setEvalBranchQuota(400_000);
    const mine: Section = if (std.debug.runtime_safety) .safe else .fast;
    // Where each name was seen: once in .shared, or once in each of .safe/.fast.
    var seen: [expected.len][3]bool = @splat(@splat(false));
    var problems: []const u8 = "";
    var section: Section = .shared;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        // Before anything is skipped, every byte must be printable ASCII or a
        // tab. cpp ends a line at a bare CR, and accepts a backslash followed
        // by a form feed or vertical tab as a line splice, so either could
        // smuggle a line past a check that skips comments.
        const bad: ?u8 = for (raw) |c| {
            if (c != '\t' and (c < 0x20 or c > 0x7e)) break c;
        } else null;
        if (bad) |c| {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: contains byte 0x{x:0>2}; only printable ASCII and tabs are allowed", .{ lineno, c });
            continue;
        }
        const line = std.mem.trim(u8, raw, " \t");
        // A trailing backslash splices the next line in (cpp, translation
        // phase 2, before comments are removed), and `??/` is the backslash
        // trigraph.
        if (std.mem.endsWith(u8, line, "\\")) {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: ends in a backslash, which joins the next line to it: {s}", .{ lineno, line });
            continue;
        }
        if (std.mem.indexOf(u8, line, "??/") != null) {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: contains the backslash trigraph ??/: {s}", .{ lineno, line });
            continue;
        }
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.eql(u8, line, "#if MAHINA_RUNTIME_SAFETY") or std.mem.eql(u8, line, "#else") or std.mem.eql(u8, line, "#endif")) {
            const want: Section = switch (line[1]) {
                'i' => .shared,
                'e' => if (line[2] == 'l') .safe else .fast,
                else => unreachable,
            };
            if (section != want) {
                problems = problems ++ std.fmt.comptimePrint("\n  line {d}: misplaced {s}", .{ lineno, line });
                continue;
            }
            section = switch (line[2]) {
                'f' => .safe,
                'l' => .fast,
                else => .shared,
            };
            continue;
        }
        const body = if (std.mem.startsWith(u8, line, ".set ")) line[".set ".len..] else {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: not a `.set NAME, N` line, a `//` comment, or #if MAHINA_RUNTIME_SAFETY/#else/#endif: {s}", .{ lineno, line });
            continue;
        };
        const comma = std.mem.indexOfScalar(u8, body, ',') orelse {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: missing comma: {s}", .{ lineno, line });
            continue;
        };
        const name = std.mem.trim(u8, body[0..comma], " \t");
        const num = canonicalDecimal(std.mem.trim(u8, body[comma + 1 ..], " \t")) orelse {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: value is not a canonical decimal integer (an optional -, then 0 or digits without a leading 0): {s}", .{ lineno, line });
            continue;
        };
        const idx = for (expected, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) break i;
        } else {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: unknown name {s} (add it to src/asm/offsets_x64.zig first)", .{ lineno, name });
            continue;
        };
        if (seen[idx][@intFromEnum(section)]) {
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: duplicate {s}", .{ lineno, name });
            continue;
        }
        seen[idx][@intFromEnum(section)] = true;
        if ((section == .shared or section == mine) and num != expected[idx].value) {
            const hint = if (section == .shared) " (if it differs between safe and fast builds, move it into the #if MAHINA_RUNTIME_SAFETY blocks)" else "";
            problems = problems ++ std.fmt.comptimePrint("\n  line {d}: {s} is {d}; expected  .set {s}, {d}{s}", .{ lineno, name, num, name, expected[idx].value, hint });
        }
    }
    if (section != .shared) problems = problems ++ "\n  unterminated #if MAHINA_RUNTIME_SAFETY block";
    for (expected, seen) |e, s| {
        const shared, const safe, const fast = s;
        if (shared and (safe or fast)) {
            problems = problems ++ std.fmt.comptimePrint("\n  {s} is in the shared section and a mode block", .{e.name});
        } else if (!shared and !safe and !fast) {
            problems = problems ++ std.fmt.comptimePrint("\n  missing:  .set {s}, {d}", .{ e.name, e.value });
        } else if (!shared and !(safe and fast)) {
            // Missing from one block only. This build knows the number only
            // for its own block.
            const block = if (!safe) "#if MAHINA_RUNTIME_SAFETY" else "#else";
            if ((!safe and mine == .safe) or (!fast and mine == .fast)) {
                problems = problems ++ std.fmt.comptimePrint("\n  missing (in the {s} block):  .set {s}, {d}", .{ block, e.name, e.value });
            } else {
                problems = problems ++ std.fmt.comptimePrint("\n  missing (in the {s} block): {s}; a build of that kind prints its number", .{ block, e.name });
            }
        }
    }
    return problems;
}

/// The assembler's reading of a `.set` value, restricted to the spelling on
/// which gas and this checker agree: decimal, no leading zero (gas reads
/// `064` as octal), no `+`, no `_` (which `std.fmt.parseInt` would accept).
fn canonicalDecimal(comptime s: []const u8) ?i128 {
    const digits = if (std.mem.startsWith(u8, s, "-")) s[1..] else s;
    if (digits.len == 0) return null;
    for (digits) |c| if (c < '0' or c > '9') return null;
    if (digits[0] == '0' and (digits.len > 1 or digits.len != s.len)) return null; // 064, -0
    return std.fmt.parseInt(i128, s, 10) catch null;
}

/// Q12 (a), run time: a slice's pointer is word `slice_ptr_word` and its
/// length word `slice_len_word`, for each slice type the entry reads. The
/// slices must be runtime values; the compiler refuses the pointer cast on a
/// comptime slice, which has no defined layout.
pub fn verifySliceLayout() bool {
    var bytes = [_]u8{ 1, 2, 3 };
    var words = [_]u64{ 1, 2 };
    var vals = [_]Value{ Value.nil(), Value.nil(), Value.nil(), Value.nil() };
    var a: []u8 = bytes[0..3];
    var b: []u64 = words[0..2];
    var c: []Value = vals[0..4];
    var list: ParkList = .{ .items = vals[1..3], .capacity = 3 };
    _ = .{ &a, &b, &c, &list };
    return sliceWordsMatch(&a) and sliceWordsMatch(&b) and sliceWordsMatch(&c) and sliceWordsMatch(&list.items);
}

/// The `MAHINA_RUNTIME_SAFETY` the `.S` was assembled with (`hostcall_x64.S`).
/// Hidden, like every internal host-call symbol and reference (doc 60 §4.2).
const mahina_hostcall_offsets_safety = @extern(*const u8, .{ .name = "mahina_hostcall_offsets_safety", .visibility = .hidden });

/// The `.S` used the offsets block of this build's kind: the build derives
/// its define from the same optimize mode that sets `runtime_safety`, and
/// this catches the two ever disagreeing (a hard stop in `capi.createVm`).
pub fn verifyAssembledMode() bool {
    return (mahina_hostcall_offsets_safety.* != 0) == std.debug.runtime_safety;
}

fn sliceWordsMatch(s: anytype) bool {
    const w: *const [2]usize = @ptrCast(s);
    return w[slice_ptr_word] == @intFromPtr(s.*.ptr) and w[slice_len_word] == s.*.len;
}

test "offsets_x64: slices are {ptr, len} words (doc 60 Q12 (a))" {
    try std.testing.expect(verifySliceLayout());
}

test "offsets_x64: the .S was assembled with this build's offsets block" {
    try std.testing.expect(verifyAssembledMode());
}

/// Whether the checker reports `needle` for `text`. The texts below are
/// fragments, so they also miss most names; only the named problem matters.
fn reports(comptime text: []const u8, comptime needle: []const u8) bool {
    return comptime std.mem.indexOf(u8, problemsIn(text), needle) != null;
}

test "offsets_x64: the checker accepts the checked-in file" {
    try std.testing.expectEqualStrings("", comptime problemsIn(@embedFile("offsets_x64.inc")));
}

test "offsets_x64: the checker rejects what cpp or gas would read differently" {
    // gas reads a leading zero as octal: 064 is 52 to the assembler.
    try std.testing.expect(reports("\n.set VM_TAGS, 064\n", "line 2: value is not a canonical decimal"));
    // A trailing backslash splices the next line, here a directive, into a
    // comment that cpp then drops: the fast block would follow the safe one.
    try std.testing.expect(reports("// boundary \\\n#else\n", "line 1: ends in a backslash"));
    try std.testing.expect(reports(".set VM_TAGS, 64 \\\n", "line 1: ends in a backslash"));
    try std.testing.expect(reports("// boundary ??/\n", "line 1: contains the backslash trigraph"));
    // cpp ends a line at a bare CR, so this comment hides a second line; and
    // a backslash then a form feed or vertical tab is still a splice.
    try std.testing.expect(reports("// hidden\r.set VM_TAGS, 52\n", "line 1: contains byte 0x0d"));
    try std.testing.expect(reports("// boundary \\\x0c\n#else\n", "line 1: contains byte 0x0c"));
    try std.testing.expect(reports("// boundary \\\x0b\n#else\n", "line 1: contains byte 0x0b"));
    try std.testing.expect(reports(".set VM_TAGS, 64\r\n", "line 1: contains byte 0x0d"));
    // Anything else gas would accept is outside the grammar.
    try std.testing.expect(reports(".set VM_TAGS, 64 # comment\n", "line 1: value is not a canonical decimal"));
    try std.testing.expect(reports(".set VM_TAGS, 64; .set VM_TAGS, 52\n", "line 1: value is not a canonical decimal"));
    try std.testing.expect(reports("#define VM_TAGS 52\n", "line 1: not a `.set NAME, N` line"));
    try std.testing.expect(reports("/* .set VM_TAGS, 52 */\n", "line 1: not a `.set NAME, N` line"));
}

test "offsets_x64: canonical decimal is the only accepted spelling" {
    comptime {
        for ([_][]const u8{ "0", "64", "-1", "16376" }) |s|
            if (canonicalDecimal(s) == null) @compileError("rejected " ++ s);
        for ([_][]const u8{ "064", "00", "-0", "+64", "6_4", "0x40", "0b1", "64h", "", "-", " 64" }) |s|
            if (canonicalDecimal(s) != null) @compileError("accepted " ++ s);
    }
}

test "offsets_x64: the checker rejects misplaced mode blocks, duplicates and unknown names" {
    try std.testing.expect(reports("#else\n", "line 1: misplaced #else"));
    try std.testing.expect(reports("#if MAHINA_RUNTIME_SAFETY\n#if MAHINA_RUNTIME_SAFETY\n", "line 2: misplaced #if"));
    try std.testing.expect(reports("#if MAHINA_RUNTIME_SAFETY\n", "unterminated #if MAHINA_RUNTIME_SAFETY block"));
    try std.testing.expect(reports("#ifdef MAHINA_RUNTIME_SAFETY\n", "line 1: not a `.set NAME, N` line"));
    try std.testing.expect(reports(".set VM_TAGS, 64\n.set VM_TAGS, 64\n", "line 2: duplicate VM_TAGS"));
    try std.testing.expect(reports(".set VM_BOGUS, 1\n", "line 1: unknown name VM_BOGUS"));
    try std.testing.expect(reports(".set VM_TAGS, 63\n", "line 1: VM_TAGS is 63; expected  .set VM_TAGS, 64"));
    try std.testing.expect(reports(
        ".set VM_DEPTH, 1\n#if MAHINA_RUNTIME_SAFETY\n.set VM_DEPTH, 1\n#else\n.set VM_DEPTH, 1\n#endif\n",
        "VM_DEPTH is in the shared section and a mode block",
    ));
    try std.testing.expect(reports("", "missing:  .set VM_TAGS, 64"));
}
