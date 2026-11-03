//! Doc 68 §5.1: resumable natives. A native that has to call Lua code in
//! the middle of its work (`table.sort`'s comparator, a `__lt` handler)
//! makes those calls from an **activation**: a frame of a tiny hand-built
//! system proto,
//!
//!     [0] native_act  k        step the native
//!     [1] call        C, n, 1  the call it asked for
//!     [2] native_act  k        step again, with that call's result
//!     [3] ret         C, r     its work is done
//! (A native with nothing to do after its call, `dofile`, returns the call's
//! results as they are: `call C, 0, all` and `ret C, all` at [2] and [3].)
//!
//! so the call is an ordinary Lua call of an ordinary frame: a coroutine
//! can yield inside it, a keyframe captures it, a step debugger stops in
//! it, and an error unwinds through it, none of which a Zig re-entry
//! (`Vm.callValue`) can do. The native's state lives in the activation's
//! registers, as integers, never in a Zig frame or the heap.
//!
//! A step (`Vm.opNativeAct`) runs the native's own Zig code against the
//! frame's registers until it either needs a call (it writes the callee
//! and two arguments at `callReg` and the step dispatches `[1]`) or is done
//! (`[3]`). There is no back-edge, so nothing counts toward a trace. The
//! call's argument count `n` is fixed per native, or dynamic (a step sets
//! `reg_top` past the arguments it wrote, as a multret producer does); a
//! step that is done leaves its `r` results from `callReg` on.
//!
//! The native itself starts as any other: called inline, it does every
//! step that needs no Lua call in Zig, and only at the first one that does
//! it leaves its state in `Vm.act_seed` and signals `error.ActivateNative`,
//! which the `.call` that called it turns into the activation
//! (`Vm.opEntry`); the activation's first step takes the seed. Called from
//! Zig (`callValue`), it finishes there instead, with Zig re-entries for its
//! calls (`Vm.nativeUnparkedFailed`).

const std = @import("std");
const bytecode = @import("bytecode.zig");

const value = @import("value.zig");

const Instr = bytecode.Instr;
const Proto = bytecode.Proto;
const Value = value.Value;

/// The resumable natives.
pub const Kind = enum(u8) {
    /// `table.sort` with a comparator, or over values compared by `__lt`.
    sort,
    /// `string.gsub` with a function replacement.
    gsub,
    /// `dofile`: the loaded chunk's call, whose results are its own.
    dofile,
    /// `require`, from the first searcher or loader that is a Lua function.
    require,
    /// `tostring` of a value whose `__tostring` is a Lua function.
    tostring,
    /// `print`, from the first argument whose `__tostring` is a Lua function.
    print,
};

/// An activation's register layout: the native's parameters (bound as a
/// Lua function's are), then its state registers, then the call area: the
/// callee and its arguments, with the call's one result landing on the
/// callee's slot.
const Layout = struct {
    params: u8,
    /// State registers after the parameters. The first is nil until the
    /// first step has taken the seed.
    words: u8,
    /// The call's arguments: all there is room for.
    call_args: u8,
    /// Whether the call's argument count is the step's to say (`reg_top`)
    /// rather than `call_args`.
    dynamic_args: bool = false,
    /// The values the activation returns, from `callReg`.
    results: u8,
    /// The call's results are the activation's own, however many: the call
    /// wants them all and what follows it is a `ret` of them all, with no
    /// step between. Such a native has nothing to do after its call.
    tail: bool = false,
    /// The activation returns however many values the step leaves (it ends
    /// them with `Vm.setActArgsEnd`), not `results`.
    dynamic_results: bool = false,
    /// How many results the call writes back, from `callReg`.
    call_results: u8 = 1,
    /// The native takes any number of arguments: its activation is a vararg
    /// function, with none of them bound (a step reads them as `...`).
    vararg: bool = false,
    /// How a traceback names it: `module.name`, a `[C]` row.
    module: []const u8,
    name: []const u8,
};

fn layoutOf(kind: Kind) Layout {
    return switch (kind) {
        .sort => .{ .params = 2, .words = 8, .call_args = 2, .results = 0, .module = "table", .name = "sort" },
        // s, pattern, replacement, n; the buffer, then src, count, max_n
        // and the pending match's end. A call passes up to 32 captures.
        .gsub => .{ .params = 4, .words = 5, .call_args = 32, .dynamic_args = true, .results = 2, .module = "string", .name = "gsub" },
        // name; the phase, the searcher index, then the notfound buffer (or
        // the loader) and the loader's data. A call is a searcher's or the
        // loader's: its one or two arguments, and (up to) two results.
        .require => .{ .params = 1, .words = 4, .call_args = 2, .dynamic_args = true, .dynamic_results = true, .results = 0, .call_results = 2, .module = "", .name = "require" },
        // v; a marker that is nil until the first step. The call is
        // `__tostring(v)`; its answer is checked in the second step.
        .tostring => .{ .params = 1, .words = 1, .call_args = 1, .results = 1, .module = "", .name = "tostring" },
        // ...; the index of the argument whose `__tostring` is being called.
        .print => .{ .params = 0, .words = 1, .call_args = 1, .results = 0, .vararg = true, .module = "", .name = "print" },
        // path; the chunk is called with no arguments
        .dofile => .{ .params = 1, .words = 0, .call_args = 0, .results = 0, .tail = true, .module = "", .name = "dofile" },
    };
}

/// The most state words any resumable native keeps.
pub const max_words = 8;

/// The first state word's register.
pub fn wordReg(kind: Kind) u16 {
    return layoutOf(kind).params;
}

/// The call area's first register: the callee, then its arguments; the
/// call's result lands here.
pub fn callReg(kind: Kind) u16 {
    const l = layoutOf(kind);
    return @as(u16, l.params) + l.words;
}


/// The module and name a traceback shows the activation as (`table.sort`).
pub fn moduleOf(kind: Kind) []const u8 {
    return layoutOf(kind).module;
}

/// What a step asks the activation to do next.
pub const Next = enum {
    /// Make the call it laid out at `callReg`, then step again. A kind with
    /// a dynamic argument count has set where they end first
    /// (`Vm.setActArgsEnd`).
    call,
    /// Return the results it left at `callReg`.
    done,
};

/// The count of values the kind's activation returns, and whether its call
/// takes a step-chosen number of arguments (then `Vm.reg_top` ends them).
pub fn resultsOf(kind: Kind) u8 {
    return layoutOf(kind).results;
}

pub fn dynamicArgs(kind: Kind) bool {
    return layoutOf(kind).dynamic_args;
}

/// The pc of the activation's call and of its return.
pub const call_pc: usize = 1;
pub const ret_pc: usize = 3;

/// A native's state when it signals `error.ActivateNative`, for the
/// activation's first step (or the Zig fallback) to carry on from.
/// Integers, and up to two heap `values` (the byte buffer `gsub` has built
/// so far; `require`'s loader and its data), which `Vm.forEachRootHeader`
/// roots until a step takes them: what the state refers to otherwise sits
/// in the native's arguments, which become the activation's parameters.
pub const Seed = struct {
    kind: Kind,
    words: [max_words]i64,
    values: [2]Value = .{ Value.nil(), Value.nil() },
};

/// The reserved proto ids, which keyframes name the activations by:
/// below the native-body chunk's two (`coroutine.native_body_proto_id`,
/// the top id but one, and its chunk's root, one below it; `coroutine.zig`
/// asserts they stay apart), one per kind, downwards. Spelled out rather
/// than derived, so the trace-side modules that read opcodes don't reach
/// the VM through this file.
pub const first_id: u32 = std.math.maxInt(u32) - 3;
const kind_count = @typeInfo(Kind).@"enum".field_names.len;

pub fn idOf(kind: Kind) u32 {
    return first_id - @intFromEnum(kind);
}

/// The kind whose activation `p` is, or null for any other proto.
pub fn kindOf(p: *const Proto) ?Kind {
    return kindOfId(p.id);
}

pub fn kindOfId(id: u32) ?Kind {
    if (id > first_id or id <= first_id - kind_count) return null;
    return @enumFromInt(first_id - id);
}

/// The activation proto of `kind`. One per process, shared by every VM:
/// nothing in it is mutable (no globals, so no slot hints), and a VM keeps
/// its own per-proto state (code images, anchors) keyed by it.
pub fn protoOf(kind: Kind) *const Proto {
    return &protos[@intFromEnum(kind)];
}

const protos: [kind_count]Proto = blk: {
    var ps: [kind_count]Proto = undefined;
    for (&ps, 0..) |*p, i| p.* = build(@enumFromInt(i));
    break :blk ps;
};

fn build(comptime kind: Kind) Proto {
    const l = layoutOf(kind);
    const k: u16 = @intFromEnum(kind);
    const c = callReg(kind);
    const nargs: u16 = if (l.dynamic_args) bytecode.all_results else l.call_args;
    const ret_all = Instr.opAB(.ret, c, bytecode.all_results);
    const code = [_]Instr{
        Instr.opAB(.native_act, 0, k),
        Instr.opABC(.call, c, nargs, if (l.tail) bytecode.all_results else l.call_results),
        if (l.tail) ret_all else Instr.opAB(.native_act, 0, k),
        if (l.tail or l.dynamic_results) ret_all else Instr.opAB(.ret, c, l.results),
    };
    std.debug.assert(code[call_pc].op == .call and code[ret_pc].op == .ret);
    const frozen = code;
    return .{
        .code = &frozen,
        .num_registers = c + 1 + @max(l.call_args, l.results, l.call_results),
        .num_params = l.params,
        .is_vararg = l.vararg,
        .name = l.name,
        .chunk = "[C]",
        // To Lua the frame is the native running: no step stops in it, and
        // a traceback shows it as the native (`Vm.contextFrames`).
        .system = true,
        .id = idOf(kind),
    };
}

test "activation ids are reserved and round-trip" {
    try std.testing.expectEqual(@as(?Kind, .sort), kindOfId(idOf(.sort)));
    try std.testing.expectEqual(@as(?Kind, .gsub), kindOfId(idOf(.gsub)));
    try std.testing.expectEqual(@as(?Kind, .dofile), kindOfId(idOf(.dofile)));
    try std.testing.expectEqual(@as(?Kind, .print), kindOfId(idOf(.print)));
    try std.testing.expectEqual(@as(?Kind, null), kindOfId(first_id + 1));
    try std.testing.expectEqual(@as(?Kind, null), kindOfId(first_id - kind_count));
    try std.testing.expectEqual(@as(?Kind, null), kindOfId(0));
    try std.testing.expectEqual(idOf(.sort), protoOf(.sort).id);
    try std.testing.expect(protoOf(.sort).code[0].op == .native_act);
}
