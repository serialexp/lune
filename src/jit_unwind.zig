//! Keeps std's stack unwinder out of mahina's JIT code.
//!
//! std's `SafeAllocator` (`std.testing.allocator`, and `init.gpa` in Debug and
//! ReleaseSafe builds) captures a stack trace on every allocation and free.
//! A trace that starts in a runtime helper called from native trace code
//! walks into a JIT frame, whose PC lies in no loaded module. std's default
//! `SelfInfo` answers that miss by rebuilding its module list, and since
//! Zig 0.17.0 also by clearing its unwind cache. So every such allocation
//! re-parses and re-sorts the whole binary's `.eh_frame`: one test went
//! from 1 s / 11 MB to 1m44 / 5.6 GB.
//!
//! The fix does not depend on how std implements any of that. The executable
//! memory the JIT maps is registered here (`register`/`unregister`, called by
//! `nativegen_mcode.zig`), and `Wrap` puts a thin layer over std's default
//! `SelfInfo` (`std.debug.TargetInfo`) through std's documented override
//! point, `root.debug.SelfInfo`. Any query for a registered PC is answered
//! here; everything else is forwarded unchanged. A JIT frame keeps no frame
//! pointer chain (rbp is an allocatable home), so a trace ends at the first
//! JIT frame, with the frames that matter (allocation site up to the helper)
//! intact.
//!
//! Every root mahina owns installs it: `pub const debug = jit_unwind.debug;`
//! in `src/main.zig` and `src/capi.zig`, and `tests/test_runner.zig` for the
//! test binaries. It is its own module so the test runner, which only sees
//! the imports of the module under test, reaches the same registry the JIT
//! writes.
//!
//! The registry is process-global by necessity: std's unwinder has no way to
//! be handed a VM. It owns no heap memory (a fixed slot table), so Rule Z-4's
//! injected allocators are unaffected, and it is never consulted by anything
//! a script can observe, so determinism and replay are unaffected too.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How many executable mappings can be registered at once. The JIT maps 1 MiB
/// arena regions (a VM rarely needs more than one or two) plus, in tests,
/// short-lived standalone pages. A mapping that finds the table full stays
/// unregistered: unwinding through it is then only slow, never wrong.
pub const capacity = 256;

const Slot = struct {
    /// Odd while a writer is changing the range (a seqlock), so a reader never
    /// trusts a torn `start`/`end` pair.
    seq: std.atomic.Value(u32) = .init(0),
    start: std.atomic.Value(usize) = .init(0),
    /// One past the last byte; `0` marks a free slot.
    end: std.atomic.Value(usize) = .init(0),
};

var slots: [capacity]Slot = @splat(.{});
/// Slots `[0, high_water)` may be in use; readers scan only those.
var high_water: std.atomic.Value(usize) = .init(0);
/// Registered ranges. Zero lets the common case (no JIT code mapped) skip the
/// scan entirely.
var live: std.atomic.Value(usize) = .init(0);
/// Serialises writers. Mapping and unmapping code is rare, so a spin lock is
/// enough; readers never take it.
var writer_lock: std.atomic.Value(bool) = .init(false);
/// Unwinder queries answered here instead of reaching std, for tests to
/// observe that the wrapper is installed and on the path.
var intercepted: std.atomic.Value(usize) = .init(0);

fn lockWriters() void {
    while (writer_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockWriters() void {
    writer_lock.store(false, .release);
}

fn writeSlot(slot: *Slot, start: usize, end: usize) void {
    const seq = slot.seq.load(.monotonic);
    slot.seq.store(seq +% 1, .monotonic);
    slot.start.store(start, .release);
    slot.end.store(end, .release);
    slot.seq.store(seq +% 2, .release);
}

/// Record `code` as JIT-owned executable memory. Call after mapping it and
/// before any code in it can run.
pub fn register(code: []const u8) void {
    if (code.len == 0) return;
    lockWriters();
    defer unlockWriters();
    const used = high_water.load(.monotonic);
    for (slots[0..used]) |*slot| {
        if (slot.end.load(.monotonic) == 0) {
            writeSlot(slot, @intFromPtr(code.ptr), @intFromPtr(code.ptr) + code.len);
            _ = live.fetchAdd(1, .release);
            return;
        }
    }
    if (used == capacity) return;
    writeSlot(&slots[used], @intFromPtr(code.ptr), @intFromPtr(code.ptr) + code.len);
    high_water.store(used + 1, .release);
    _ = live.fetchAdd(1, .release);
}

/// Forget a range `register` recorded. Call before unmapping it. A range that
/// was never registered (the table was full) is ignored.
pub fn unregister(code: []const u8) void {
    if (code.len == 0) return;
    lockWriters();
    defer unlockWriters();
    const start = @intFromPtr(code.ptr);
    for (slots[0..high_water.load(.monotonic)]) |*slot| {
        if (slot.end.load(.monotonic) != 0 and slot.start.load(.monotonic) == start) {
            writeSlot(slot, 0, 0);
            _ = live.fetchSub(1, .release);
            return;
        }
    }
}

/// Whether `pc` lies in registered JIT memory. Lock-free and allocation-free,
/// so it is safe from inside an allocator and from a panic handler.
pub fn contains(pc: usize) bool {
    if (live.load(.acquire) == 0) return false;
    for (slots[0..high_water.load(.acquire)]) |*slot| {
        const seq = slot.seq.load(.acquire);
        if (seq & 1 != 0) continue;
        const start = slot.start.load(.acquire);
        const end = slot.end.load(.acquire);
        if (slot.seq.load(.acquire) != seq) continue;
        if (pc >= start and pc < end) return true;
    }
    return false;
}

/// How many unwinder queries were answered here so far (process-wide).
pub fn interceptCount() usize {
    return intercepted.load(.monotonic);
}

/// The name `getModuleName` reports for a JIT PC.
pub const module_name = "<mahina jit>";

/// `Inner` (a `std.debug.SelfInfo` implementation) with every query about a
/// registered PC answered here: no symbols, no module slide, no unwind rules.
/// Implements exactly the interface `std.debug.SelfInfo` documents.
pub fn Wrap(comptime Inner: type) type {
    return struct {
        inner: Inner,

        const Self = @This();

        pub const init: Self = .{ .inner = .init };

        pub fn deinit(si: *Self, io: Io) void {
            si.inner.deinit(io);
        }

        pub fn getSymbols(
            si: *Self,
            io: Io,
            symbol_allocator: Allocator,
            text_arena: Allocator,
            address: usize,
            include_inline_callers: bool,
            symbols: *std.ArrayList(std.debug.Symbol),
        ) std.debug.SelfInfoError!void {
            if (contains(address)) return intercept(error.MissingDebugInfo);
            return si.inner.getSymbols(io, symbol_allocator, text_arena, address, include_inline_callers, symbols);
        }

        pub fn getModuleName(si: *Self, io: Io, address: usize) std.debug.SelfInfoError![]const u8 {
            if (contains(address)) {
                _ = intercepted.fetchAdd(1, .monotonic);
                return module_name;
            }
            return si.inner.getModuleName(io, address);
        }

        pub fn getModuleSlide(si: *Self, io: Io, address: usize) std.debug.SelfInfoError!usize {
            if (contains(address)) return intercept(error.MissingDebugInfo);
            return si.inner.getModuleSlide(io, address);
        }

        pub const can_unwind: bool = Inner.can_unwind;
        pub const UnwindContext = if (can_unwind) Inner.UnwindContext else void;

        /// A JIT frame has no unwind info; std's iterator takes the error as
        /// "switch to frame-pointer unwinding", which a stack-trace capture
        /// only does where it is safe.
        pub fn unwindFrame(si: *Self, io: Io, context: *UnwindContext) std.debug.SelfInfoError!usize {
            if (contains(context.pc)) return intercept(error.MissingDebugInfo);
            return si.inner.unwindFrame(io, context);
        }

        fn intercept(err: std.debug.SelfInfoError) std.debug.SelfInfoError {
            _ = intercepted.fetchAdd(1, .monotonic);
            return err;
        }
    };
}

/// std's default `SelfInfo` for this target, wrapped; `void` where std has
/// none.
///
/// aarch64-windows is also `void`: the pinned std's
/// `debug/SelfInfo/Windows.zig` does not compile there (a `@ptrCast` of a
/// `*anyopaque` to a 4-aligned fn pointer without `@alignCast`, in
/// `getNtdllProc`), so that one target opts out of self-symbolisation: a
/// panic there prints raw return addresses instead of symbolised frames.
/// Drop the case once the pinned Zig carries the upstream fix.
pub const TargetSelfInfo = blk: {
    if (builtin.os.tag == .windows and builtin.cpu.arch == .aarch64) break :blk void;
    const Inner = std.debug.TargetInfo(builtin.os.tag, builtin.cpu.arch);
    break :blk if (Inner == void) void else Wrap(Inner);
};

/// What a root re-exports as `pub const debug` to install `TargetSelfInfo`.
pub const debug = struct {
    pub const SelfInfo = TargetSelfInfo;
};

test "register, contains, unregister" {
    // Two registered ranges with an unregistered gap between them.
    var buf: [96]u8 = undefined;
    const a = buf[0..32];
    const b = buf[64..96];
    const base = @intFromPtr(&buf);
    const base_live = live.load(.monotonic);
    register(a);
    register(b);
    defer unregister(b);
    try std.testing.expect(contains(base));
    try std.testing.expect(contains(base + 31));
    try std.testing.expect(!contains(base + 32));
    try std.testing.expect(!contains(base + 63));
    try std.testing.expect(contains(base + 64));
    try std.testing.expect(contains(base + 95));
    try std.testing.expectEqual(base_live + 2, live.load(.monotonic));
    unregister(a);
    try std.testing.expect(!contains(base));
    try std.testing.expect(contains(base + 64));
    // A range that was never registered is ignored.
    unregister(a);
    try std.testing.expectEqual(base_live + 1, live.load(.monotonic));
}

test "a freed slot is reused before the table grows" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    register(&a);
    const grown = high_water.load(.monotonic);
    unregister(&a);
    register(&b);
    defer unregister(&b);
    try std.testing.expectEqual(grown, high_water.load(.monotonic));
    try std.testing.expect(contains(@intFromPtr(&b[0])));
    try std.testing.expect(!contains(@intFromPtr(&a[0])));
}

/// Stands in for std's `SelfInfo`, counting the queries that reach it.
const FakeInner = struct {
    calls: usize,

    pub const init: FakeInner = .{ .calls = 0 };
    pub fn deinit(si: *FakeInner, io: Io) void {
        _ = io;
        si.* = undefined;
    }
    pub fn getSymbols(si: *FakeInner, io: Io, sa: Allocator, ta: Allocator, address: usize, inl: bool, symbols: *std.ArrayList(std.debug.Symbol)) std.debug.SelfInfoError!void {
        _ = .{ io, sa, ta, address, inl, symbols };
        si.calls += 1;
    }
    pub fn getModuleName(si: *FakeInner, io: Io, address: usize) std.debug.SelfInfoError![]const u8 {
        _ = .{ io, address };
        si.calls += 1;
        return "inner";
    }
    pub fn getModuleSlide(si: *FakeInner, io: Io, address: usize) std.debug.SelfInfoError!usize {
        _ = .{ io, address };
        si.calls += 1;
        return 7;
    }
    pub const can_unwind = true;
    pub const UnwindContext = struct { pc: usize };
    pub fn unwindFrame(si: *FakeInner, io: Io, context: *UnwindContext) std.debug.SelfInfoError!usize {
        _ = .{ io, context };
        si.calls += 1;
        return 0x1234;
    }
};

test "Wrap answers registered PCs itself and forwards everything else" {
    const io = std.testing.io;
    var jit: [64]u8 = undefined;
    var other: [8]u8 = undefined;
    register(&jit);
    defer unregister(&jit);
    var si: Wrap(FakeInner) = .init;
    defer si.deinit(io);
    const jit_pc = @intFromPtr(&jit[10]);
    const other_pc = @intFromPtr(&other[0]);
    const before = interceptCount();

    var ctx: FakeInner.UnwindContext = .{ .pc = jit_pc };
    try std.testing.expectError(error.MissingDebugInfo, si.unwindFrame(io, &ctx));
    try std.testing.expectError(error.MissingDebugInfo, si.getModuleSlide(io, jit_pc));
    try std.testing.expectEqualStrings(module_name, try si.getModuleName(io, jit_pc));
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    try std.testing.expectError(error.MissingDebugInfo, si.getSymbols(io, std.testing.allocator, std.testing.allocator, jit_pc, false, &symbols));
    try std.testing.expectEqual(@as(usize, 0), si.inner.calls);
    try std.testing.expectEqual(before + 4, interceptCount());

    ctx.pc = other_pc;
    try std.testing.expectEqual(@as(usize, 0x1234), try si.unwindFrame(io, &ctx));
    try std.testing.expectEqual(@as(usize, 7), try si.getModuleSlide(io, other_pc));
    try std.testing.expectEqualStrings("inner", try si.getModuleName(io, other_pc));
    try si.getSymbols(io, std.testing.allocator, std.testing.allocator, other_pc, false, &symbols);
    try std.testing.expectEqual(@as(usize, 4), si.inner.calls);
}

test "concurrent writers never corrupt a reader's view" {
    // Writers keep re-registering the first half of their own buffer, so the
    // slots are constantly reused across ranges. A torn read (one range's
    // `start` with another's `end`) would cover the never-registered second
    // halves, which is what the readers probe.
    var ranges: [4][256]u8 = undefined;
    var stop: std.atomic.Value(bool) = .init(false);
    var bad: std.atomic.Value(usize) = .init(0);
    const outside = @intFromPtr(&ranges[1][200]);

    const Writer = struct {
        fn run(buf: *[256]u8, s: *std.atomic.Value(bool)) void {
            const r = buf[0..128];
            while (!s.load(.acquire)) {
                register(r);
                unregister(r);
            }
        }
    };
    const Reader = struct {
        fn run(o: usize, s: *std.atomic.Value(bool), b: *std.atomic.Value(usize)) void {
            while (!s.load(.acquire)) {
                if (contains(o)) _ = b.fetchAdd(1, .monotonic);
            }
        }
    };
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads: [6]std.Thread = undefined;
    for (threads[0..4], &ranges) |*t, *r| t.* = try std.Thread.spawn(.{}, Writer.run, .{ r, &stop });
    for (threads[4..]) |*t| t.* = try std.Thread.spawn(.{}, Reader.run, .{ outside, &stop, &bad });
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        if (contains(outside)) _ = bad.fetchAdd(1, .monotonic);
    }
    stop.store(true, .release);
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 0), bad.load(.monotonic));
}
