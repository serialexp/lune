//! Tier-1b native codegen — the IR-lowering half (the encoder is `x64.zig`).
//!
//! This module turns a hot integer trace into real x86-64 machine code, writes it
//! to an executable page, and hands back a callable function pointer. Commit 2 (this
//! file's first slice) is just the **executable-memory** plumbing + a smoke test;
//! the trace compiler (`compile`) lands in the next commit.
//!
//! ## Target-gating
//!
//! Native codegen is **x86-64 / Linux only** — it emits raw machine code and flips a
//! page to executable, neither of which exists in the `wasm32-freestanding` build
//! that also imports `root.zig`. Every OS-specific reference (`std.posix.mmap`,
//! `std.os.linux.mprotect`) lives inside a function guarded by
//! `if (comptime !is_x64_linux) return error.UnsupportedTarget;`, so on any other
//! target those branches are comptime-pruned and never analyzed. The `x64` encoder
//! itself is target-independent (a pure byte buffer) and compiles everywhere.

const std = @import("std");
const builtin = @import("builtin");
const x64 = @import("x64.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");
const Value = value.Value;
const Trace = trace.Trace;

/// True only where we can actually emit and run native code.
pub const is_x64_linux = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

const page_align = std.heap.page_size_min;

pub const MapError = error{
    /// Built for a target without native codegen (e.g. wasm) — callers fall back
    /// to the tier-1a IR-interpreter.
    UnsupportedTarget,
    MmapFailed,
    MprotectFailed,
};

/// An `mmap`'d, executable page holding emitted machine code. `entry()` reinterprets
/// its base as a function pointer; `deinit()` returns the page to the kernel.
pub const ExecPage = struct {
    /// The whole mapped region (page-rounded). Owned; freed by `deinit`.
    mem: []align(page_align) u8,
    /// Bytes of actual code at the start of `mem`.
    len: usize,

    /// Reinterpret the page base as a C-ABI function pointer of type `Fn`.
    /// Caller guarantees the emitted code matches `Fn`'s signature.
    pub fn entry(self: ExecPage, comptime Fn: type) *const Fn {
        return @ptrCast(self.mem.ptr);
    }

    pub fn deinit(self: *ExecPage) void {
        if (comptime is_x64_linux) std.posix.munmap(self.mem);
        self.* = undefined;
    }
};

/// Copy `code` into a fresh page and make it executable (W^X: mapped RW, written,
/// then flipped to R+X). Returns a callable `ExecPage`. `code` must be non-empty.
pub fn mapExecutable(code: []const u8) MapError!ExecPage {
    if (comptime !is_x64_linux) return error.UnsupportedTarget;
    std.debug.assert(code.len > 0);

    const posix = std.posix;

    const page = std.heap.pageSize();
    const len = std.mem.alignForward(usize, code.len, page);

    // Map writable + readable (not yet executable).
    const mem = posix.mmap(
        null,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.MmapFailed;
    errdefer posix.munmap(mem);

    @memcpy(mem[0..code.len], code);

    // Flip to read + execute. After this the page is no longer writable (W^X).
    // Raw syscall + errno (mirrors std.Thread's stack-guard mprotect).
    switch (posix.errno(posix.system.mprotect(mem.ptr, mem.len, .{ .READ = true, .EXEC = true }))) {
        .SUCCESS => {},
        else => return error.MprotectFailed,
    }

    return .{ .mem = mem, .len = code.len };
}

// ---------------------------------------------------------------------------
// The integer-trace compiler
// ---------------------------------------------------------------------------

const Reg = x64.Reg;
const TAG_INT: u8 = @intFromEnum(value.Tag.int);
const TAG_BOOL: u8 = @intFromEnum(value.Tag.boolean);

/// The proven kind of each SSA ref. `none` = produces no usable value (a guard /
/// the `loop` marker) — referencing it as an operand is a bail.
const Kind = enum { none, int, bool };

/// A compiled trace: an executable page whose entry is
/// `fn(regs: [*]Value) callconv(.c) usize` — `regs` base in rdi, the cleanly
/// committed iteration count (`completed`) returned in rax. Semantically identical
/// to `irinterp.execute(t, regs, scratch)`.
pub const CompiledTrace = struct {
    page: ExecPage,

    pub const EntryFn = fn ([*]Value) callconv(.c) usize;

    /// Run the trace over `regs` (mutated in place at each loop commit, exactly as
    /// the IR-interpreter does). Returns the committed-iteration count.
    pub fn run(self: CompiledTrace, regs: []Value) usize {
        return self.page.entry(EntryFn)(regs.ptr);
    }

    pub fn deinit(self: *CompiledTrace) void {
        self.page.deinit();
        self.* = undefined;
    }
};

/// Per-trace memoized native-codegen status (a tri-state, so "not yet attempted"
/// never aliases "known unsupported"). Lives on the cached `Trace`; lazily resolved
/// on the first native dispatch and then terminal — a `.compiled` page runs forever,
/// an `.unsupported` trace stays on tier-1a forever. Runtime-only (not serialized).
pub const NativeState = union(enum) {
    /// Native compilation has not been attempted yet.
    unattempted,
    /// The trace is outside the proven-int/bool subset (or this is an off-target
    /// build): it runs on the tier-1a IR-interpreter. Never retried.
    unsupported,
    /// Successfully lowered to an executable page.
    compiled: CompiledTrace,

    /// Free any owned executable page and reset to `unattempted`.
    pub fn deinit(self: *NativeState) void {
        switch (self.*) {
            .compiled => |*c| c.deinit(),
            .unattempted, .unsupported => {},
        }
        self.* = .unattempted;
    }
};

/// Try to compile `t` to native code. Returns `null` to **bail** — for any reason:
/// an off-target build, a value/op outside the proven-int/bool subset, malformed
/// IR, or an assembly/mapping failure. A `null` is never fatal: the caller falls
/// back to the tier-1a IR-interpreter. Success transfers ownership of an executable
/// page to the returned `CompiledTrace` (free it with `deinit`).
pub fn compile(gpa: std.mem.Allocator, t: *const Trace) ?CompiledTrace {
    if (comptime !is_x64_linux) return null;

    const n = t.instrs.len;
    // A well-formed trace is non-empty and ends in exactly one `loop`. Re-checked
    // here because `assertWellFormed` is gone in release builds (never trust the IR).
    if (n == 0 or n > 0xFFFF or t.instrs[n - 1].op != .loop) return null;

    const kinds = gpa.alloc(Kind, n) catch return null;
    defer gpa.free(kinds);
    const slot_of = gpa.alloc(i32, n) catch return null;
    defer gpa.free(slot_of);

    if (!proveKinds(gpa, t, kinds, slot_of)) return null;

    var asm_buf = x64.Assembler.init(gpa);
    defer asm_buf.deinit();
    lower(t, kinds, slot_of, &asm_buf) catch return null;
    asm_buf.resolve();

    const page = mapExecutable(asm_buf.code.items) catch return null;
    return .{ .page = page };
}

/// Forward type-proof over the linear SSA. Fills `kinds` (and `slot_of`, the
/// register slot of each `slot_load`) and returns `true` iff every value is a
/// proven `int`/`bool` produced by a supported op — otherwise `false` (bail).
fn proveKinds(gpa: std.mem.Allocator, t: *const Trace, kinds: []Kind, slot_of: []i32) bool {
    const n = t.instrs.len;
    @memset(kinds, .none);
    @memset(slot_of, -1);

    // Pass A: record each slot_load's register slot, and the set of refs a
    // `guard_int` covers. A guard_int must target a slot_load (its lowering reads
    // the tag straight from `regs[slot]`); anything else bails.
    const guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(guarded);
    @memset(guarded, false);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                slot_of[i] = ins.aux;
            },
            .guard_int => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op != .slot_load) return false; // unsupported guard shape
                guarded[r] = true;
            },
            else => {},
        }
    }

    // Pass B: assign kinds, validating operands and constants as we go.
    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (!guarded[i]) return false; // unguarded → cannot prove int
                kinds[i] = .int;
            },
            .konst => {
                if (ins.aux < 0 or ins.aux >= t.consts.len) return false;
                kinds[i] = switch (t.consts[@intCast(ins.aux)].tag) {
                    .int => .int,
                    .boolean => .bool,
                    else => return false, // float / nil / heap const → bail
                };
            },
            .add, .sub, .mul, .band, .bor, .bxor => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .int;
            },
            .neg, .bnot => {
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .int;
            },
            .eq, .ne, .lt, .le => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .bool;
            },
            .guard_int => kinds[i] = .none, // operand validated in pass A
            .guard_true, .guard_false => {
                const k = kinds[ins.a];
                if (k != .int and k != .bool) return false;
                kinds[i] = .none;
            },
            .loop => {
                if (i != n - 1) return false; // loop must be terminal
                kinds[i] = .none;
            },
            // Everything else (div/idiv/mod/pow/shl/shr/not/guard_float/
            // guard_number) is deferred — bail to tier-1a.
            else => return false,
        }
    }

    // Every loop-carried writeback must reference a proven value (int/bool) so we
    // know its box tag.
    for (t.exit_stores) |st| {
        if (st.ref >= n) return false;
        if (kinds[st.ref] == .none) return false;
    }
    return true;
}

/// Stack-slot displacement for SSA ref `r`: each ref owns one 8-byte frame slot.
fn spill(r: usize) i32 {
    return @intCast(r * 8);
}

/// Lower a proven trace to machine code. ABI: rdi = regs base (held throughout),
/// rbx = committed counter, rax/rcx = transient scratch. Each SSA ref lives in a
/// stack slot `[rsp + r*8]`; the body re-runs from `loop_top` every iteration.
fn lower(t: *const Trace, kinds: []const Kind, slot_of: []const i32, a: *x64.Assembler) !void {
    const n = t.instrs.len;
    const frame: i32 = @intCast(std.mem.alignForward(usize, n * 8, 16));

    // Prologue: save rbx, completed = 0, reserve the spill frame.
    try a.push(.rbx);
    try a.xorRegReg(.rbx, .rbx);
    if (frame > 0) try a.subRegImm32(.rsp, frame);

    const loop_top = try a.label();
    const exit = try a.label();
    a.bind(loop_top);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                // rax = regs[slot].payload.int  (offset slot*16 + 8)
                try a.movRegMem(.rax, .rdi, slot_of[i] * 16 + 8);
                try a.movMemReg(.rsp, spill(i), .rax);
            },
            .konst => {
                const bits = t.consts[@intCast(ins.aux)].payload.bits;
                try a.movRegImm64(.rax, @bitCast(bits));
                try a.movMemReg(.rsp, spill(i), .rax);
            },
            .add, .sub, .mul, .band, .bor, .bxor => {
                try a.movRegMem(.rax, .rsp, spill(ins.a));
                try a.movRegMem(.rcx, .rsp, spill(ins.b));
                switch (ins.op) {
                    .add => try a.addRegReg(.rax, .rcx),
                    .sub => try a.subRegReg(.rax, .rcx),
                    .mul => try a.imulRegReg(.rax, .rcx),
                    .band => try a.andRegReg(.rax, .rcx),
                    .bor => try a.orRegReg(.rax, .rcx),
                    .bxor => try a.xorRegReg(.rax, .rcx),
                    else => unreachable,
                }
                try a.movMemReg(.rsp, spill(i), .rax);
            },
            .neg, .bnot => {
                try a.movRegMem(.rax, .rsp, spill(ins.a));
                if (ins.op == .neg) try a.negReg(.rax) else try a.notReg(.rax);
                try a.movMemReg(.rsp, spill(i), .rax);
            },
            .eq, .ne, .lt, .le => {
                try a.movRegMem(.rax, .rsp, spill(ins.a));
                try a.movRegMem(.rcx, .rsp, spill(ins.b));
                try a.cmpRegReg(.rax, .rcx);
                const cc: x64.Cond = switch (ins.op) {
                    .eq => .e,
                    .ne => .ne,
                    .lt => .l,
                    .le => .le,
                    else => unreachable,
                };
                try a.setcc(cc, .rax);
                try a.movzxRegReg8(.rax, .rax); // zero-extend the 0/1 (setcc is 8-bit)
                try a.movMemReg(.rsp, spill(i), .rax);
            },
            .guard_int => {
                // cmp byte [regs[slot].tag], int ; jne EXIT
                try a.cmpByteMemImm(.rdi, slot_of[ins.a] * 16, TAG_INT);
                try a.jcc(.ne, exit);
            },
            .guard_true => switch (kinds[ins.a]) {
                .int => {}, // every int is truthy → guard always passes (no-op)
                .bool => {
                    try a.cmpQwordMemImm8(.rsp, spill(ins.a), 0);
                    try a.jcc(.e, exit); // false (0) → side-exit
                },
                .none => unreachable,
            },
            .guard_false => switch (kinds[ins.a]) {
                .int => try a.jmp(exit), // an int is never falsy → always side-exit
                .bool => {
                    try a.cmpQwordMemImm8(.rsp, spill(ins.a), 0);
                    try a.jcc(.ne, exit); // true (≠0) → side-exit
                },
                .none => unreachable,
            },
            .loop => {
                // Commit: box each loop-carried writeback into regs, then iterate.
                for (t.exit_stores) |st| {
                    const tag: i32 = if (kinds[st.ref] == .bool) TAG_BOOL else TAG_INT;
                    const base: i32 = @as(i32, st.slot) * 16;
                    try a.movMemImm32(.rdi, base, tag); // tag word (zeroes padding)
                    try a.movRegMem(.rax, .rsp, spill(st.ref));
                    try a.movMemReg(.rdi, base + 8, .rax); // payload word
                }
                try a.incReg(.rbx);
                try a.jmp(loop_top);
            },
            else => unreachable, // proveKinds rejected everything else
        }
    }

    // Shared side-exit epilogue: return completed, restore the stack and rbx.
    a.bind(exit);
    try a.movRegReg(.rax, .rbx);
    if (frame > 0) try a.addRegImm32(.rsp, frame);
    try a.pop(.rbx);
    try a.ret();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const irinterp = @import("irinterp.zig");
const I = trace.IrInstr;
const S = trace.SlotStore;

/// Compare two register files **semantically** (tag + payload bits). The 7 padding
/// bytes of a `Value` are non-semantic and left undefined by `Value.int`/etc., so a
/// raw byte compare would spuriously fail against native code that zeroes them.
fn expectRegsEqual(expected: []const Value, actual: []const Value) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, ac| {
        try testing.expectEqual(@intFromEnum(e.tag), @intFromEnum(ac.tag));
        try testing.expectEqual(e.payload.bits, ac.payload.bits);
    }
}

/// Run `t` through both the IR-interpreter (the oracle) and the native compiler on
/// identical fresh register files; assert the same `completed` and final `regs`.
fn expectMatch(t: *const Trace, regs_init: []const Value) !void {
    // Oracle: the tier-1a IR-interpreter.
    const iregs = try testing.allocator.dupe(Value, regs_init);
    defer testing.allocator.free(iregs);
    const values = try testing.allocator.alloc(Value, t.instrs.len);
    defer testing.allocator.free(values);
    const icompleted = irinterp.execute(t, iregs, values);

    // Native: must compile (caller picks compilable traces) and match bit-for-bit.
    var ct = compile(testing.allocator, t) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const nregs = try testing.allocator.dupe(Value, regs_init);
    defer testing.allocator.free(nregs);
    const ncompleted = ct.run(nregs);

    try testing.expectEqual(icompleted, ncompleted);
    try expectRegsEqual(iregs, nregs);
}

/// Assert `compile` bails (returns null) for an unsupported trace.
fn expectBail(t: *const Trace) !void {
    if (compile(testing.allocator, t)) |ct| {
        var c = ct;
        c.deinit();
        return error.TestExpectedBail;
    }
}

test "nativegen: clean integer counting loop matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (i < limit) { acc += i; i += 1; }  — regs: r0=i, r1=limit, r2=acc.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 2, .ref = 8 }, .{ .slot = 0, .ref = 10 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };

    // i=1..5: commits 4 iterations (1+2+3+4=10), exits when i==5 (5<5 false).
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0) });
    // A tighter limit: 0 commits.
    try expectMatch(&t, &.{ Value.int(7), Value.int(3), Value.int(100) });
}

test "nativegen: a guard_int failure side-exits with completed==0" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit (will be a float at runtime)
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3 — fails: limit is float
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i+1
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{.{ .slot = 0, .ref = 7 }};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // limit is a float → guard_int #3 fails on the very first iteration.
    try expectMatch(&t, &.{ Value.int(0), Value.float(5.0) });
}

test "nativegen: a loop-carried boolean is boxed with the boolean tag" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // r1 := (i < 10) each iteration; r0 := i+1. Exits when i==10.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 10
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 10  (BOOL, loop-carried)
        .{ .op = .konst, .aux = 1 }, // 4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // 5: i + 1
        .{ .op = .guard_true, .a = 3 }, // 6
        .{ .op = .loop }, // 7
    };
    var consts = [_]Value{ Value.int(10), Value.int(1) };
    var exits = [_]S{ .{ .slot = 0, .ref = 5 }, .{ .slot = 1, .ref = 3 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // r1 must end as boolean(true) (tag=1), NOT int(1) (tag=2) — the oracle catches it.
    try expectMatch(&t, &.{ Value.int(0), Value.nil() });
}

test "nativegen: guard_true on an integer always passes (int 0 is truthy)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (starts at 0)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .guard_true, .a = 0 }, // 2: truthy-guard on the int itself
        .{ .op = .konst, .aux = 0 }, // 3: 3
        .{ .op = .lt, .a = 0, .b = 3 }, // 4: i < 3
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 1 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i+1
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{ Value.int(3), Value.int(1) };
    var exits = [_]S{.{ .slot = 0, .ref = 7 }};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // i=0,1,2 commit (guard_true on int 0 must NOT exit); exits at i=3. completed==3.
    try expectMatch(&t, &.{Value.int(0)});
}

test "nativegen: guard_false on an integer side-exits immediately" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .guard_false, .a = 0 }, // 2: int is truthy → guard_false fails
        .{ .op = .loop }, // 3
    };
    var consts = [_]Value{};
    var exits = [_]S{.{ .slot = 0, .ref = 0 }};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try expectMatch(&t, &.{Value.int(5)}); // completed==0, regs unchanged
}

test "nativegen: bails on unsupported traces" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var es = [_]u16{};

    // (a) a float constant → not provably int.
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .add, .a = 0, .b = 2 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.float(1.5)};
        var exits = [_]S{.{ .slot = 0, .ref = 3 }};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
    // (b) a slot_load with no covering guard_int.
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .add, .a = 0, .b = 1 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.int(1)};
        var exits = [_]S{.{ .slot = 0, .ref = 2 }};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
    // (c) guard_number (a float passes it → can't prove int).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_number, .a = 0 },
            .{ .op = .loop },
        };
        var consts = [_]Value{};
        var exits = [_]S{};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
    // (d) a deferred op (div).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .div, .a = 0, .b = 2 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.int(2)};
        var exits = [_]S{.{ .slot = 0, .ref = 0 }};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
}

test "exec memory: assemble, map, and call a native fn(i64)->i64" {
    if (comptime !is_x64_linux) return error.SkipZigTest;

    // f(x) = 2*x + 1, SysV: arg in rdi, return in rax.
    //   mov rax, rdi ; add rax, rdi ; inc rax ; ret
    var a = x64.Assembler.init(testing.allocator);
    defer a.deinit();
    try a.movRegReg(.rax, .rdi);
    try a.addRegReg(.rax, .rdi);
    try a.incReg(.rax);
    try a.ret();
    a.resolve();

    var page = try mapExecutable(a.code.items);
    defer page.deinit();

    const f = page.entry(fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 1), f(0));
    try testing.expectEqual(@as(i64, 21), f(10));
    try testing.expectEqual(@as(i64, -1), f(-1));
}

test "exec memory: a loop with a backward jump runs natively" {
    if (comptime !is_x64_linux) return error.SkipZigTest;

    // f(n) = sum(1..n) the dumb way:  rax=0; rcx=n; L: (n<=0?exit) rax+=rcx; rcx-=1; jnz-ish
    // Keep it simple & branch-exercising:  rax=0 ; while (rdi != 0) { rax += rdi; rdi -= 1; }
    //   xor-free version using cmp/jcc:
    //   mov rax, 0
    //   L: cmp rdi, 0 ; je END ; add rax, rdi ; sub rdi, 1 ; jmp L
    //   END: ret
    var a = x64.Assembler.init(testing.allocator);
    defer a.deinit();
    const loop = try a.label();
    const end = try a.label();
    try a.movRegImm64(.rax, 0);
    a.bind(loop);
    try a.cmpRegImm32(.rdi, 0);
    try a.jcc(.e, end);
    try a.addRegReg(.rax, .rdi);
    try a.subRegImm32(.rdi, 1);
    try a.jmp(loop);
    a.bind(end);
    try a.ret();
    a.resolve();

    var page = try mapExecutable(a.code.items);
    defer page.deinit();

    const f = page.entry(fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 0), f(0));
    try testing.expectEqual(@as(i64, 15), f(5)); // 5+4+3+2+1
    try testing.expectEqual(@as(i64, 55), f(10));
}
