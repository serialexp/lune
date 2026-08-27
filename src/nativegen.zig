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
const irinterp = @import("irinterp.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const fmath = @import("fmath.zig");
const gc = @import("gc.zig");
const stralloc = @import("stralloc.zig");
const string_mod = @import("string.zig");
const Value = value.Value;
const RegWindow = @import("regwindow.zig").RegWindow;
const Trace = trace.Trace;

/// Frozen in-memory layout the lane-aware native array path (Phase B) encodes
/// against. Every constant is imported from the table/array modules via
/// `@offsetOf`, never a literal — a layout change in `table.zig`/`array.zig` is
/// reflected here at comptime, and a regression fails to compile rather than
/// silently miscompiling a load/store address. Reaching a packed slot from a
/// `*Table` is `ArrLayout.array_base + ArrLayout.<field>`.
const ArrLayout = struct {
    /// `*Table` → embedded `ArrayPart`.
    const array_base = table.Table.array_off;
    /// `ArrayPart` field offsets (from `array_base`).
    const lane = arr.ArrayPart.Layout.lane;
    const asize = arr.ArrayPart.Layout.asize;
    const cap = arr.ArrayPart.Layout.cap;
    const data = arr.ArrayPart.Layout.data;
    const present = arr.ArrayPart.Layout.present;
    /// Grid fields (doc 14): the per-cell element lane and the row stride. A grid's
    /// `data`/`present` are the SAME fields as a scalar array's, reinterpreted as a
    /// flat `cap*stride` cell buffer indexed by `row*stride + col` at `grid_elem`
    /// width. `@offsetOf` makes a layout churn a compile error (Z-1/Z-2).
    const grid_elem = arr.ArrayPart.Layout.grid_elem;
    const stride = arr.ArrayPart.Layout.stride;
    /// `*Table` → embedded hash part's `size` (live entry count, u32). The grow
    /// store's `guard_append` reads this to prove the hash is empty (so tier-0's
    /// `migrateFromHash` would be a no-op). `@offsetOf` on the std map field makes a
    /// layout churn a compile error, never a silent miscompile (Z-1/Z-2).
    const hash_size = table.Table.hash_off + @offsetOf(table.Table.Map, "size");
};

comptime {
    // Sanity (evaluated at file scope, so it always runs and marks ArrLayout
    // used): the array sits past an 8-byte GcHeader, lane is the first
    // ArrayPart byte, and the pointer/len fields are usize-aligned. These are
    // the assumptions the native address math (B2+) relies on.
    std.debug.assert(ArrLayout.array_base >= @sizeOf(@import("object.zig").GcHeader));
    std.debug.assert(ArrLayout.lane == 0);
    std.debug.assert(ArrLayout.asize % @alignOf(usize) == 0);
    std.debug.assert(ArrLayout.data % @alignOf(usize) == 0);
    std.debug.assert(ArrLayout.present % @alignOf(usize) == 0);
}

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

pub const PatchError = MapError || error{
    NotArenaOwned,
    WrongArena,
    StalePage,
    OffsetOutOfBounds,
    OpcodeMismatch,
    OriginalBytesMismatch,
    DisplacementOutOfRange,
};

/// A callable view of emitted machine code. `entry()` reinterprets its base as a
/// function pointer; `deinit()` releases the backing memory.
///
/// Two ownership disciplines share this handle:
///   - `.owned` — a standalone `mmap` mapped by `mapExecutable` (the two exec-memory
///     unit tests + the `compile(gpa, t)` test entry point). `deinit` munmaps it.
///   - `.arena` — a *slice* of an `McodeArena` region (the production path via
///     `nativeFor`→`compileInto`). The bytes are not individually mapped; `deinit`
///     returns the slot to the arena's free-list (LuaJIT-style co-located mcode).
pub const ExecPage = struct {
    /// The emitted code bytes. For `.arena` pages this is a subslice of a region
    /// (base is 16-byte-aligned by construction, not page-aligned). Execution and
    /// `--dump-native` read this; nothing at runtime needs a page-rounded length.
    code: []u8,
    owner: Owner,

    const ArenaSlot = struct {
        arena: *McodeArena,
        region: u32,
        offset: usize,
        /// The slot's *capacity* (16-aligned `code.len` at alloc time), returned to
        /// the free-list on `deinit` so a reused slot never shrinks.
        cap: usize,
        /// Unique allocation incarnation. A free-list reuse gets a fresh value,
        /// so a stale patch descriptor cannot rewrite unrelated replacement code.
        generation: u64,
    };

    const Owner = union(enum) {
        /// The whole page-rounded mapping this handle owns; `deinit` munmaps it.
        owned: []align(page_align) u8,
        /// A slot inside a shared arena region; `deinit` frees it to the free-list.
        arena: ArenaSlot,
    };

    /// Reinterpret the code base as a C-ABI function pointer of type `Fn`.
    /// Caller guarantees the emitted code matches `Fn`'s signature.
    pub fn entry(self: ExecPage, comptime Fn: type) *const Fn {
        return @ptrCast(self.code.ptr);
    }

    pub fn deinit(self: *ExecPage) void {
        switch (self.owner) {
            .owned => |mem| if (comptime is_x64_linux) std.posix.munmap(mem),
            .arena => |slot| slot.arena.free(slot.region, slot.offset, slot.cap, slot.generation),
        }
        self.* = undefined;
    }
};

/// Copy `code` into a fresh standalone page and make it executable (W^X: mapped RW,
/// written, then flipped to R+X). Returns an owning `ExecPage`. `code` must be
/// non-empty. Used by the exec-memory unit tests and the `compile(gpa, t)` test
/// entry point; the production path co-locates code in an `McodeArena` instead.
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

    return .{ .code = mem[0..code.len], .owner = .{ .owned = mem } };
}

/// Frameless-ABI spill ceiling (P-A / doc 17 Increment 2). The shared trampoline
/// reserves exactly `SPILL_MAX * 8` bytes of spill area once; a frameless body may
/// address `[rsp + idx*8]` for `idx < SPILL_MAX`. A trace whose `alloc.spill_count`
/// exceeds this bails to tier-1a (`compileImpl` returns null). 512 slots = 4 KiB —
/// far above any real trace's spill_count (tens), so the bail is a safety net, not a
/// path hit in practice. MUST be even so `SPILL_MAX*8` is 16-aligned, which (with the
/// trampoline's 6 callee-saved pushes) keeps the body's `rsp % 16 == 8` — the same
/// invariant the self-framed prologue guarantees and the hash-cell callout relies on.
pub const SPILL_MAX: u32 = 512;

/// A shared, contiguous machine-code arena — the lune analogue of LuaJIT's
/// `lj_mcode.c` mcode areas. Instead of one `mmap` per compiled trace, every trace's
/// code lives as a slice of a small chain of large regions. This is prerequisite P-D
/// of the exit-branch-patching port (doc 17): co-locating all mcode is what will let
/// a later increment link trace→trace with a bare `rel32` jump (guard-patch), which a
/// per-trace `mmap` can never guarantee is within ±2 GiB. Increment 1 only co-locates
/// — no cross-region references are emitted yet, so the ±2 GiB reachability check is
/// deliberately deferred (all runtime-helper calls are absolute `mov rax,imm64;call`).
///
/// Reclamation: per-trace `free` returns the slot to a first-fit free-list (a retired
/// trace's mcode is reused by a later compile of the same-or-smaller size). This keeps
/// today's immediate-reclaim behaviour rather than LuaJIT's never-free-until-flush
/// model; if it measures worse than a pure bump allocator we revisit (per Bart).
pub const McodeArena = struct {
    /// Default region size. Big enough that a whole benchmark's traces fit in one or
    /// two regions (traces are hundreds of bytes); small enough to not waste address
    /// space. A single trace larger than this gets its own exact-fit region.
    pub const REGION_SIZE: usize = 1 << 20; // 1 MiB
    /// Entry alignment — keeps every trace entry 16-byte-aligned (a codegen nicety;
    /// x86-64 has no hard code-alignment requirement) and makes the free-list's
    /// capacity bookkeeping tidy.
    const ENTRY_ALIGN: usize = 16;

    const Region = struct {
        /// The whole page-rounded mapping. Toggled RW↔RX around each write (mcprot).
        mem: []align(page_align) u8,
        /// Bump cursor: bytes handed out from the front (16-aligned).
        used: usize,
    };

    /// A returned slot available for reuse. `cap` is the slot's 16-aligned capacity.
    const FreeBlock = struct { region: u32, offset: usize, cap: usize };
    const LivePage = struct { region: u32, offset: usize, generation: u64 };

    gpa: std.mem.Allocator,
    regions: std.ArrayListUnmanaged(Region) = .empty,
    free_list: std.ArrayListUnmanaged(FreeBlock) = .empty,
    live_pages: std.ArrayListUnmanaged(LivePage) = .empty,
    next_page_generation: u64 = 1,
    /// The shared frameless trampoline (P-A / doc 17 Increment 2), emitted lazily on
    /// the first `compileInto`. Absolute addresses into a permanent arena slot that is
    /// never freed — stable for the arena's lifetime (regions never move). `null`
    /// until first use.
    trampoline_entry: ?usize = null,
    trampoline_exit: ?usize = null,

    pub fn init(gpa: std.mem.Allocator) McodeArena {
        return .{ .gpa = gpa };
    }

    /// The two stable absolute addresses a frameless compile needs.
    pub const Trampoline = struct { entry: usize, shared_exit: usize };

    /// Lazily emit (once) and return the shared frameless trampoline. The trampoline
    /// owns the C frame so bodies don't: it saves every callee-saved GPR, reserves the
    /// `SPILL_MAX` spill area (keeping body `rsp % 16 == 8`), zeroes the rbx iteration
    /// counter, then `jmp`s into `body_entry` (passed in rcx). `shared_exit` reverses
    /// the prologue and returns to the C caller. C-ABI:
    /// `fn(rdi=tags, rsi=payloads, rdx=*NativeResult, rcx=body_entry) callconv(.c) void`.
    pub fn ensureTrampoline(self: *McodeArena) (MapError || std.mem.Allocator.Error)!Trampoline {
        if (self.trampoline_entry) |e| return .{ .entry = e, .shared_exit = self.trampoline_exit.? };

        var a = x64.Assembler.init(self.gpa);
        defer a.deinit();
        const exit_lbl = try a.label();
        // Prologue: save all callee-saved (unconditionally — bodies then clobber
        // rbp/r12–r15 freely), reserve the spill area, zero the counter, enter body.
        try a.push(.rbx);
        try a.push(.rbp);
        try a.push(.r12);
        try a.push(.r13);
        try a.push(.r14);
        try a.push(.r15);
        // 6 pushes (48 B) keep rsp % 16 == 8 after the C-ABI call's return-address
        // push; SPILL_MAX*8 is 16-aligned, so the body sees rsp % 16 == 8 too.
        try a.subRegImm32(.rsp, @intCast(SPILL_MAX * 8));
        try a.xorRegReg(.rbx, .rbx);
        try a.jmpReg(.rcx); // enter body_entry (arg3); rcx is body scratch afterward
        // shared_exit: undo the prologue and return. Bodies `jmp` here (absolute)
        // after writing completed/exit_instr to [rdx].
        a.bind(exit_lbl);
        try a.addRegImm32(.rsp, @intCast(SPILL_MAX * 8));
        try a.pop(.r15);
        try a.pop(.r14);
        try a.pop(.r13);
        try a.pop(.r12);
        try a.pop(.rbp);
        try a.pop(.rbx);
        try a.ret();
        a.resolve();

        // Alloc into the arena; the returned page is intentionally never deinit'd —
        // this slot is permanent (never on the free-list), so its address is stable.
        const page = try self.alloc(a.code.items);
        const base = @intFromPtr(page.code.ptr);
        self.trampoline_entry = base;
        self.trampoline_exit = base + a.labels.items[exit_lbl.id].?;
        return .{ .entry = base, .shared_exit = self.trampoline_exit.? };
    }

    pub fn deinit(self: *McodeArena) void {
        if (comptime is_x64_linux) {
            for (self.regions.items) |r| std.posix.munmap(r.mem);
        }
        self.regions.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
        self.live_pages.deinit(self.gpa);
        self.* = undefined;
    }

    /// Flip a region between writable (RW) and executable (RX). Single-threaded VM:
    /// no native code executes during a compile, so temporarily making a whole region
    /// writable (including already-compiled sibling traces) is safe — it is flipped
    /// back to RX before the compile returns.
    fn protectRegion(mem: []align(page_align) u8, exec: bool) MapError!void {
        const prot: std.posix.PROT = if (exec)
            .{ .READ = true, .EXEC = true }
        else
            .{ .READ = true, .WRITE = true };
        switch (std.posix.errno(std.posix.system.mprotect(mem.ptr, mem.len, prot))) {
            .SUCCESS => {},
            else => return error.MprotectFailed,
        }
    }

    fn mapRegion(self: *McodeArena, min_bytes: usize) (MapError || std.mem.Allocator.Error)!*Region {
        const page = std.heap.pageSize();
        const len = std.mem.alignForward(usize, @max(min_bytes, REGION_SIZE), page);
        const mem = std.posix.mmap(
            null,
            len,
            .{ .READ = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.MmapFailed;
        errdefer std.posix.munmap(mem);
        try self.regions.append(self.gpa, .{ .mem = mem, .used = 0 });
        return &self.regions.items[self.regions.items.len - 1];
    }

    /// Copy `code` into the arena and return a callable `ExecPage` viewing it.
    /// Reuses a free-list slot when one is large enough (first fit); otherwise bump-
    /// allocates from a region with room, mapping a new region when none fits.
    pub fn alloc(self: *McodeArena, code: []const u8) (MapError || std.mem.Allocator.Error)!ExecPage {
        if (comptime !is_x64_linux) return error.UnsupportedTarget;
        std.debug.assert(code.len > 0);
        const cap = std.mem.alignForward(usize, code.len, ENTRY_ALIGN);

        // 1. First-fit reuse of a retired slot.
        for (self.free_list.items, 0..) |fb, i| {
            if (fb.cap >= cap) {
                const region_mem = self.regions.items[fb.region].mem;
                try protectRegion(region_mem, false);
                @memcpy(region_mem[fb.offset..][0..code.len], code);
                try protectRegion(region_mem, true);
                const generation = self.takePageGeneration();
                try self.live_pages.append(self.gpa, .{ .region = fb.region, .offset = fb.offset, .generation = generation });
                _ = self.free_list.swapRemove(i);
                return .{
                    .code = region_mem[fb.offset..][0..code.len],
                    // Keep the original slot capacity so a re-free never shrinks it.
                    .owner = .{ .arena = .{ .arena = self, .region = fb.region, .offset = fb.offset, .cap = fb.cap, .generation = generation } },
                };
            }
        }

        // 2. Bump-allocate from a region with room (else map a fresh one).
        var region_idx: u32 = std.math.maxInt(u32);
        for (self.regions.items, 0..) |r, i| {
            if (r.mem.len - r.used >= cap) {
                region_idx = @intCast(i);
                break;
            }
        }
        if (region_idx == std.math.maxInt(u32)) {
            _ = try self.mapRegion(cap);
            region_idx = @intCast(self.regions.items.len - 1);
        }
        const region = &self.regions.items[region_idx];
        const off = region.used;
        try protectRegion(region.mem, false);
        @memcpy(region.mem[off..][0..code.len], code);
        try protectRegion(region.mem, true);
        const generation = self.takePageGeneration();
        try self.live_pages.append(self.gpa, .{ .region = region_idx, .offset = off, .generation = generation });
        region.used += cap;
        return .{
            .code = region.mem[off..][0..code.len],
            .owner = .{ .arena = .{ .arena = self, .region = region_idx, .offset = off, .cap = cap, .generation = generation } },
        };
    }

    fn takePageGeneration(self: *McodeArena) u64 {
        const generation = self.next_page_generation;
        self.next_page_generation +%= 1;
        if (self.next_page_generation == 0) self.next_page_generation = 1;
        return generation;
    }

    fn validatePatchPage(self: *McodeArena, page: *const ExecPage, generation: u64, patch_off: usize) PatchError!*Region {
        const slot = switch (page.owner) {
            .arena => |s| s,
            .owned => return error.NotArenaOwned,
        };
        if (slot.arena != self) return error.WrongArena;
        if (slot.generation != generation) return error.StalePage;
        var live = false;
        for (self.live_pages.items) |allocation| {
            if (allocation.region == slot.region and allocation.offset == slot.offset and allocation.generation == generation) {
                live = true;
                break;
            }
        }
        if (!live) return error.StalePage;
        if (slot.region >= self.regions.items.len) return error.StalePage;
        if (patch_off > page.code.len or page.code.len - patch_off < 5) return error.OffsetOutOfBounds;
        const region = &self.regions.items[slot.region];
        if (slot.offset > region.used or page.code.len > region.used - slot.offset) return error.StalePage;
        if (page.code.ptr != region.mem.ptr + slot.offset) return error.StalePage;
        return region;
    }

    fn rel32Bytes(page: *const ExecPage, patch_off: usize, target: usize) PatchError![5]u8 {
        const next = @intFromPtr(page.code.ptr) + patch_off + 5;
        const delta: i128 = @as(i128, @intCast(target)) - @as(i128, @intCast(next));
        if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32))
            return error.DisplacementOutOfRange;
        const disp: u32 = @bitCast(@as(i32, @intCast(delta)));
        return .{ 0xE9, @truncate(disp), @truncate(disp >> 8), @truncate(disp >> 16), @truncate(disp >> 24) };
    }

    fn applyPatch(self: *McodeArena, region: *Region, dst: []u8, replacement: []const u8) PatchError!void {
        try protectRegion(region.mem, false);
        // Once RW is established there is no fallible apply step. RX restoration is
        // a soundness boundary, not a recoverable compile miss.
        @memcpy(dst, replacement);
        protectRegion(region.mem, true) catch @panic("McodeArena: failed to restore RX after patch");
        _ = self;
    }

    /// Swap only the rel32 operand of an existing `E9 rel32`. The opcode and live
    /// page incarnation are validated before W^X is opened.
    pub fn patchRel32(self: *McodeArena, page: *ExecPage, generation: u64, patch_off: usize, target: usize) PatchError!void {
        const region = try self.validatePatchPage(page, generation, patch_off);
        if (page.code[patch_off] != 0xE9) return error.OpcodeMismatch;
        const replacement = try rel32Bytes(page, patch_off, target);
        // Preserve the existing E9 byte: ordinary deopt patching changes its four-byte
        // operand only, matching the accepted B3.13 contract.
        try self.applyPatch(region, page.code[patch_off + 1 .. patch_off + 5], replacement[1..5]);
    }

    /// Promote/demote a canonical five-byte NOP window. Promotion requires the exact
    /// recorded original bytes; demotion requires the exact E9-to-epilogue bytes and
    /// restores all five original bytes.
    pub fn patchWindow(self: *McodeArena, page: *ExecPage, generation: u64, patch_off: usize, original: [5]u8, epilogue: usize, promote: bool) PatchError!void {
        const region = try self.validatePatchPage(page, generation, patch_off);
        const patched = try rel32Bytes(page, patch_off, epilogue);
        const expected = if (promote) original else patched;
        if (!std.mem.eql(u8, page.code[patch_off..][0..5], &expected))
            return if (promote) error.OriginalBytesMismatch else error.OpcodeMismatch;
        const replacement = if (promote) patched else original;
        try self.applyPatch(region, page.code[patch_off..][0..5], &replacement);
    }

    /// Return a slot to the free-list. Best-effort: on OOM the slot is simply leaked
    /// back into the region (dead space until arena deinit) — never fatal.
    pub fn free(self: *McodeArena, region: u32, offset: usize, cap: usize, generation: u64) void {
        var i: usize = self.live_pages.items.len;
        var removed = false;
        while (i > 0) {
            i -= 1;
            const live = self.live_pages.items[i];
            if (live.region == region and live.offset == offset and live.generation == generation) {
                _ = self.live_pages.swapRemove(i);
                removed = true;
                break;
            }
        }
        if (!removed) return;
        self.free_list.append(self.gpa, .{ .region = region, .offset = offset, .cap = cap }) catch {};
    }
};

// ---------------------------------------------------------------------------
// The integer-trace compiler
// ---------------------------------------------------------------------------

const Reg = x64.Reg;
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const TAG_INT: u8 = @intFromEnum(value.Tag.int);
const TAG_BOOL: u8 = @intFromEnum(value.Tag.boolean);
const TAG_FLOAT: u8 = @intFromEnum(value.Tag.float);
const TAG_HEAP: u8 = @intFromEnum(value.Tag.heap_ref);
/// Byte offsets within a 16-byte tagged `Value` — used by `hload`/`hstore` to
/// touch a hash-part value cell (`*Value`) directly. The tag lives at offset 0
/// (1 byte), the payload union at offset 8 (8 bytes); the 7 bytes between are
/// padding the oracle's struct-assign also leaves undefined, so native writing
/// only tag+payload is byte-identical at every observable point.
const VALUE_TAG_OFF: i32 = @offsetOf(value.Value, "tag");
const VALUE_PAYLOAD_OFF: i32 = @offsetOf(value.Value, "payload");
/// `ObjectType.table` ordinal — the byte at `GcHeader.type` for a table.
const TABLE_TYPE: u8 = @intFromEnum(object.ObjectType.table);
/// Offset of `GcHeader.type` (the first header byte) from a `*GcHeader`.
const HEADER_TYPE_OFF: i32 = @offsetOf(object.GcHeader, "type");
/// Offset of `Table.metatable` (an optional `*Table`; null = 0) from a
/// `*GcHeader`. The prologue checks this is null: a table that grew a metatable
/// after the trace was recorded must side-exit to tier-0 (which dispatches
/// `__index`/`__newindex`), never run the raw native load/store — chunk 2a.
const METATABLE_OFF: i32 = @offsetOf(table.Table, "metatable");
/// `ObjectType.function` ordinal — the byte at `GcHeader.type` for a Lua closure.
/// The cross-frame `guard_func` (U1) checks a snapshot callee value is a closure
/// of this type before reading its `proto.id`.
const FUNCTION_TYPE: u8 = @intFromEnum(object.ObjectType.function);
/// Offset of `Closure.proto` (a `*const Proto`) from a `*GcHeader`. The header is
/// the first field, so this is the closure's second word.
const CLOSURE_PROTO_OFF: i32 = @offsetOf(function.Closure, "proto");
/// Offset of `Proto.id` (a stable `u32` compile-time identity — NOT an address, so
/// it survives keyframe restore/replay) from a `*const Proto`. `guard_func` compares
/// the recorded id against `[closure.proto + PROTO_ID_OFF]`.
const PROTO_ID_OFF: i32 = @offsetOf(bytecode.Proto, "id");
/// `ObjectType.native` ordinal — the byte at `GcHeader.type` for a host native.
/// The pure-builtin `guard_builtin` checks a snapshot callee value is a native of this
/// type before reading its `pure` tag.
const NATIVE_TYPE: u8 = @intFromEnum(object.ObjectType.native);
/// Offset of `Native.recorded` (a `?RecordedBuiltin` — an `enum(u8)` optional, 2 bytes laid
/// out `[payload, has_value]`) from a `*GcHeader`. `guard_builtin` proves the callee is
/// the recorded builtin with two byte compares: `[native + recorded]` (the payload
/// ordinal) == the recorded `RecordedBuiltin` tag, AND `[native + recorded + 1]` (the
/// non-null flag) == 1. Two byte compares sidestep needing a 16-bit-immediate
/// compare encoder and don't depend on the optional's internal byte order beyond the
/// verified `[payload, flag]` layout.
const NATIVE_RECORDED_OFF: i32 = @offsetOf(function.Native, "recorded");
comptime {
    // Pin the `?RecordedBuiltin` size the `guard_builtin` prologue depends on (Z-1: a
    // toolchain bump that changes optional layout must fail the build loudly, not
    // silently miscompile the two-byte identity check). The `[payload, has_value]`
    // byte *order* can't be asserted at comptime (an optional has no well-defined
    // comptime layout to deref) — it's pinned by the runtime test below instead.
    std.debug.assert(@sizeOf(?function.RecordedBuiltin) == 2);
}
/// Packed-lane ordinals the native array path can lower. The bool lane (B2/B3,
/// the nsieve sieve) is bit-packed; the int lanes (B4) are byte-packed and
/// SIB-indexed; the `f64` lane (Phase D, float arrays) is 8-byte doubles read/
/// written with `movsd` into the XMM pool. Only `.value` (16-B unpacked,
/// heap-bearing) always bails to tier-1a — `laneKind` returns null for it.
const BOOL_LANE: i32 = @intFromEnum(arr.Lane.boolean);
const I8_LANE: i32 = @intFromEnum(arr.Lane.i8);
const I16_LANE: i32 = @intFromEnum(arr.Lane.i16);
const I32_LANE: i32 = @intFromEnum(arr.Lane.i32);
const I64_LANE: i32 = @intFromEnum(arr.Lane.i64);
const U8_LANE: i32 = @intFromEnum(arr.Lane.u8);
const F64_LANE: i32 = @intFromEnum(arr.Lane.f64);
/// The grid meta-lane (doc 14): a `.grid` array's `lane` field. Used as the
/// `SlotInfo.lane` prologue check for a grid table (`array.lane == .grid`); the
/// per-cell element width comes from the separate `grid_elem` field/ordinal,
/// which the grid ops carry in their `aux` (an int lane, so `laneKind`/
/// `intLaneWidth` classify it exactly like a scalar int lane).
const GRID_LANE: i32 = @intFromEnum(arr.Lane.grid);

/// The `.value` lane ordinal — 16-byte full-`Value` elements, heap-bearing.
/// Phase 2 admits this lane for aload→guard_table→href→hload chains (the
/// array-of-structs pattern `bodies[i].x`); the aload itself produces a `.heap`
/// kind (a per-iteration `*GcHeader` table pointer) consumed by the hash-field
/// path, not a scalar lane kind.
pub const VALUE_LANE: i32 = @intFromEnum(arr.Lane.value);

/// Offset from a `*GcHeader` (the table's embedded header) to the hash-part
/// `size` (u32 live-entry count). The comptime chain is:
/// `@offsetOf(Table, "hash") + @offsetOf(Map, "size") - @offsetOf(Table, "header")`.
/// Since `header` is always the first field (`@offsetOf(Table, "header") == 0`
/// for Zig's default layout where `GcHeader` is first), this equals
/// `ArrLayout.hash_size`. We name it separately for clarity and pin the
/// assumption via a comptime assert below.
const HASH_SIZE_FROM_HEADER: i32 = ArrLayout.hash_size - @as(i32, @intCast(@offsetOf(table.Table, "header")));
comptime {
    // The header-to-hash offset must be non-negative (header is before hash).
    std.debug.assert(HASH_SIZE_FROM_HEADER >= 0);
}

/// Per-iteration hash-cell resolver for `.value`-lane table loads (Phase 2).
///
/// The native loop body calls this via `call rax` to resolve the value-cell
/// pointer for a constant string key in a per-iteration element table. The
/// existing loop-invariant href path resolves the cell once at entry via
/// `seedTraceInputs`; this function is the per-iteration equivalent.
///
/// SysV ABI: rdi = `*GcHeader` (element table from aload), rsi = key tag
/// bits (low byte = `Tag` ordinal), rdx = key payload bits. Returns the
/// `*Value` cell pointer as a `usize` in rax, or 0 if the key is absent.
///
/// Does NOT check metatable (`guard_table` already did) or hash count
/// (`guard_hash` does it inline). Pure `fieldPtr` resolution — a wrapper
/// that confines the Zig HashMap's non-extern internals to one call site
/// (Rule Z-2).
fn resolveHashCell(header_bits: usize, key_tag_bits: u64, key_payload_bits: u64) callconv(.c) usize {
    const header: *object.GcHeader = @ptrFromInt(header_bits);
    const tbl = table.Table.fromHeader(header);
    const key = Value{ .tag = @enumFromInt(@as(u8, @truncate(key_tag_bits))), .payload = .{ .bits = key_payload_bits } };
    const cell = tbl.fieldPtr(key) orelse return 0;
    return @intFromPtr(cell);
}

/// The native scalar `Kind` a packed lane decodes to, or `null` when the native
/// array path does not lower this lane (`.value` → tier-1a). The bool lane
/// yields a 0/1 boolean; the i8…i64 lanes yield a sign-extended int; the
/// unsigned-byte `u8` lane yields a zero-extended int (same `.int` Kind — the
/// signedness difference is purely in the `aload` extension width, see below);
/// the `f64` lane yields a `.float` (an 8-byte double, XMM-resident).
fn laneKind(aux: i32) ?Kind {
    if (aux == BOOL_LANE) return .bool;
    if (aux == I8_LANE or aux == I16_LANE or aux == I32_LANE or aux == I64_LANE or aux == U8_LANE) return .int;
    if (aux == F64_LANE) return .float;
    return null;
}

/// Packed-element width in bytes for an int lane (1/2/4/8 → the SIB scale).
/// Asserts an int lane (`laneKind(aux) == .int`); the bit-packed bool lane uses
/// `bt`/`bts`/`btr` instead and never calls this. `u8` is one byte wide, like i8.
fn intLaneWidth(aux: i32) u8 {
    return if (aux == I8_LANE or aux == U8_LANE) 1 else if (aux == I16_LANE) 2 else if (aux == I32_LANE) 4 else if (aux == I64_LANE) 8 else unreachable;
}

/// True when SSA ref `r` is a `.konst` whose value statically fits the lane named
/// by `aux`. A *constant* int-lane array store needs no runtime `guard_fits`: the
/// recorder only emits the store when the value fit the lane (`recArraySet`'s
/// `array.fits` precondition), and a constant never changes — so tropt proves the
/// `guard_fits` always-passes and folds it away (`tropt` const-eval via the same
/// `laneFits`). Native then sees no covering `guard_fits` and would bail the whole
/// trace to tier-1a; re-derive the static fit here with the identical `laneFits`
/// rule so a constant int-lane fill/init store (`p[i]=0`, `a[k]=7`) compiles to
/// native instead. Narrow lanes (i8…i32/u8) range-check the constant; the i64 lane
/// fits every int. Mirrors the f64 arm, which already compiles a const-fill whose
/// guard_fits tropt DCE'd. A *variant* (non-const) narrow-lane value keeps its
/// guard_fits (tropt can't prove it always fits), so it takes the `fits_ok` path,
/// not this one.
fn konstFitsLane(t: *const Trace, r: trace.Ref, aux: i32) bool {
    if (r >= t.instrs.len) return false;
    const ki = t.instrs[r];
    if (ki.op != .konst) return false;
    if (ki.aux < 0 or ki.aux >= t.consts.len) return false;
    return arr.ArrayPart.laneFits(@enumFromInt(aux), t.consts[@intCast(ki.aux)]);
}

/// Enforce that every lane-bearing op in a trace (`guard_lane`/`aref`/`aload`/
/// `astore`) names the SAME lane. The prologue checks the runtime array lane
/// once against the `guard_lane` ordinal; tying the per-op `aux` to that single
/// lane guarantees each aload/astore uses the width the prologue verified.
fn laneConsistent(trace_lane: *?i32, aux: i32) bool {
    if (trace_lane.*) |l| return l == aux;
    trace_lane.* = aux;
    return true;
}

/// The proven kind of each SSA ref.
///   - `none`  — produces no usable value (a guard / the `loop` marker);
///               referencing it as an operand is a bail.
///   - `int` / `bool` — a boxed scalar (GP register) that may be carried, flushed,
///               or stored.
///   - `float` — a boxed f64 (Phase D). Lives in an XMM register / a shared 8-byte
///               spill cell; carried & flushed (TAG_FLOAT + `movsd`) like an int but
///               in the disjoint XMM pool. `div`/`pow` results and any arithmetic
///               with a float operand are `.float`.
///   - `ptr`   — a raw `*GcHeader` (a `guard_table`-covered table `slot_load`).
///               Classified `invariant`, loaded once; **must never** reach
///               `exit_stores` (the deopt flush boxes as TAG_INT — C2).
///   - `func`  — a raw `*GcHeader` for a Lua closure (a `guard_func`-covered
///               `slot_load`: the cross-frame callee snapshot, U1). Like `.ptr` it
///               is an invariant heap pointer loaded once and tag-checked TAG_HEAP,
///               but the prologue verifies it is a closure of the recorded
///               `Proto.id` (not a table+lane). Consumed ONLY by `guard_func` (an
///               entry guard) — never feeds arithmetic, an `aref`, or a flush.
///   - `aref`  — the paired `(table, index)` addressing token produced by `aref`
///               (its register holds `idx0 = index-1`). A distinct kind so it can
///               neither feed arithmetic nor be flushed to a slot.
///   - `href` — the hash-part value-cell pointer produced by `href` (H1). A
///               loop-invariant `*Value` into a table's hash part, **seeded** into a
///               slab slot per entry (`seedTraceInputs`) and loaded from
///               `[rsi + aux*8]`, not computed from the operands. Like `.aref` it is a
///               distinct addressing kind — it can neither feed arithmetic nor be
///               flushed to a slot (C2). Consumed only by `hload`/`hstore`/`guard_hash`.
pub const Kind = enum { none, int, bool, ptr, aref, float, func, href, native, heap };

pub const NativeResult = extern struct {
    completed: usize,
    exit_instr: u32,
    linked_loop_done: u64,
    /// P-B (doc 17): the stable `Trace.id` of the trace performing the final exit,
    /// baked as an imm32 into every exit stub (`emitReturn`). With no linking yet it
    /// is always the entered trace's id; once a native parent `jmp`s into a linked
    /// child (2.3), the child's exit stub overwrites it, so the dispatcher can map
    /// the result back to the correct final trace instead of assuming the parent.
    final_trace_id: u32,
    /// 2.3b-0 (doc 17): the value of the `rbx` iteration counter at the moment this
    /// body was entered, snapshotted by the first body instruction
    /// (`mov [rdx+entry_rbx], rbx`). A fresh trampoline entry zeroes `rbx`, so for an
    /// un-fused run this is 0 and `local_completed == completed`. Once a native parent
    /// `jmp`s into a child under the shared frame (2.3b-1) `rbx` already holds the
    /// parent's cumulative count, so the child's body records that baseline here and
    /// the Zig wrapper recovers the child's OWN committed count as
    /// `completed − entry_rbx`. Written by whichever body performs the FINAL exit
    /// (each body's entry overwrites it), so the returned value always describes the
    /// final trace. Not consumed by the host — pure scratch that rides in the result.
    entry_rbx: usize,
    /// 2.3c-0b (doc 17): why the final body exited — `irinterp.ExitReason` as a raw
    /// `u32`. The wrapper inits it to `.normal` (0); ONLY the `prologue_fail` stub
    /// overwrites it (to 1) via `movMemImm32`, so it splits a native prologue-fail from
    /// the tier-1a "ran to completion" meaning of `exit_instr == maxInt`. Written by
    /// whichever body performs the FINAL exit (each exit path either leaves it 0 or, at
    /// prologue_fail, sets 1), so the returned value describes the final trace.
    exit_reason: u32,
    /// 2.3c-0 (doc 17): the resolved absolute dispatch target for the shared
    /// `deopt_exit` flush. Each ordinary / loop-done-ordinary mini-stub RESOLVES its
    /// dispatch target and stashes it HERE, in memory, BEFORE the carried-home flush
    /// runs — an ordinary guard derefs its own `slot[ei]` (holds `shared_exit` while
    /// unarmed, a child body entry once 2.3c-1 arms it); a loop-done ordinary deopt uses
    /// `shared_exit` directly (its `slot[ei]` is the EXCLUSIVE linked exit, P-C option
    /// (b)). `deopt_exit` ends with `jmp qword [rdx+exit_target]`. Why a memory field
    /// and not a register: `flushSlot`'s spilled-payload path clobbers rax, so a
    /// register-staged holder would be destroyed by any spilled carried home before the
    /// jump; a `*NativeResult` field is flush-immune. Frameless production path only
    /// (the self-framed test page tears down + `ret`, never reading this). Pure scratch,
    /// not host-consumed; the wrapper inits it to 0 and every deopt exit overwrites it.
    exit_target: usize,
    /// 2.3c-2a (doc 17): per-transition ledger. A fused native span (`C→I→C→…` chained
    /// under the shared frame) returns ONE `NativeResult` whose scalar fields describe
    /// only the TERMINAL body; every intermediate exit is otherwise lost. Each
    /// exit-materialization (`emitLedgerAppend`, called by all four exit sites) appends
    /// one entry — parallel arrays indexed by `ledger_len` — so `runLinkedBurst` can
    /// replay the hops it never re-entered Zig to observe (2.3c-2b+ consume it; 2.3c-2a
    /// only writes + cross-checks the terminal entry against the scalar fields). Parallel
    /// (not array-of-struct) so the JIT indexes each lane with a native SIB scale — 8 for
    /// `ledger_cum`, 4 for the u32 lanes — with no ×stride multiply. `ledger_cum[i]` is
    /// the cumulative `rbx` counter at hop `i`, so a segment's OWN count is
    /// `ledger_cum[i] − ledger_cum[i-1]` (`− entry_rbx` for i==0). The Zig wrapper inits
    /// `ledger_len = 0` (arrays left `undefined`; only `[0..ledger_len]` is read). MUST
    /// stay LAST: every scalar field's `@offsetOf` is baked into the exit stubs, so
    /// appending here keeps them byte-identical.
    ledger_len: usize,
    ledger_cum: [irinterp.LEDGER_CAP]usize,
    ledger_id: [irinterp.LEDGER_CAP]u32,
    ledger_exit: [irinterp.LEDGER_CAP]u32,
    ledger_reason: [irinterp.LEDGER_CAP]u32,
    /// 2.3c-2c (doc 17): parallel `LedgerKind` lane — the exit-materialization SITE
    /// that appended each hop (one static constant per `emitLedgerAppend` caller).
    /// The generic `replayLedger` reads it to classify a hop's coherent-resume
    /// contract without re-deriving it from the trace IR. Like the other ledger
    /// lanes, appended AFTER the scalar fields so every baked scalar `@offsetOf` in
    /// the exit stubs stays byte-identical.
    ledger_kind: [irinterp.LEDGER_CAP]u32,
    /// 2.3c-2c (doc 17): parallel `LedgerOutcome` lane — `.normal` for every entry by
    /// default (written by `emitLedgerAppend`), rewritten to `.yielded` by
    /// `emitForcedYieldCheck` when an armed chain source hits a full ledger. Lets
    /// `replayLedger` tell a forced yield apart from a natural terminal at the last
    /// entry. Appended last (after `ledger_kind`), same byte-identity rationale.
    ledger_outcome: [irinterp.LEDGER_CAP]u32,
    // Doc 17 B-3 frozen tail. These stay unreachable/zero in B-3a: only a future
    // validated exit patch can enter a silent epilogue.
    silent_active: u64,
    silent_transitions: u64,
    silent_budget: u64,
    barren_budget: u64,
    silent_cell: u64,
    cur_zero_run: u64,
    silent_cum: u64,
    /// Round-6 exactness: the `*SilentExitMetadata` of the LAST promoted edge that
    /// fired in this call, overwritten by every silent epilogue. `silent_cell` keeps
    /// the FIRST (entry ownership); this keeps the terminal one. Zig derives the
    /// resume contract from this instead of reconstructing it as
    /// `(first_phase + transitions - 1) % len`, which silently assumed a strict
    /// round-robin that neither a repeated-parent ring nor two concurrently live
    /// promoted cycles obey.
    silent_last_cell: u64,
};

/// Host-staged bounds/state for a native call that may enter a promoted silent
/// cycle. Keeping these values together makes the wrapper initialization the
/// single ABI staging point for every native-call origin.
pub const SilentStaging = struct {
    silent_budget: u64 = 0,
    barren_budget: u64 = 0,
    cur_zero_run: u64 = 0,
};

/// The pre-B-3 ABI prefix, retained solely as a compile-time layout oracle. Appending
/// the silent tail must not move any existing ledger lane.
pub const NativeResultLedgerLayout = extern struct {
    completed: usize,
    exit_instr: u32,
    linked_loop_done: u64,
    final_trace_id: u32,
    entry_rbx: usize,
    exit_reason: u32,
    exit_target: usize,
    ledger_len: usize,
    ledger_cum: [irinterp.LEDGER_CAP]usize,
    ledger_id: [irinterp.LEDGER_CAP]u32,
    ledger_exit: [irinterp.LEDGER_CAP]u32,
    ledger_reason: [irinterp.LEDGER_CAP]u32,
    ledger_kind: [irinterp.LEDGER_CAP]u32,
    ledger_outcome: [irinterp.LEDGER_CAP]u32,
};

comptime {
    for (.{ "ledger_len", "ledger_cum", "ledger_id", "ledger_exit", "ledger_reason", "ledger_kind", "ledger_outcome" }) |field|
        std.debug.assert(@offsetOf(NativeResult, field) == @offsetOf(NativeResultLedgerLayout, field));
    std.debug.assert(@offsetOf(NativeResult, "silent_active") == @sizeOf(NativeResultLedgerLayout));
    std.debug.assert(@offsetOf(NativeResult, "silent_cum") == @offsetOf(NativeResult, "silent_active") + 6 * @sizeOf(u64));
    std.debug.assert(@offsetOf(NativeResult, "silent_last_cell") == @offsetOf(NativeResult, "silent_active") + 7 * @sizeOf(u64));
}

pub const SilentSummaryCell = extern struct {
    region_work: u64,
    selection_work: u64,
    qualifying_rows: u64,
    productive_firings: u64,
    /// Dynamic local of this edge's most recent firing in the native call.
    last_local: u64,
    /// One-based silent-transition ordinal of this edge's most recent
    /// productive firing; zero means none in this call.
    last_productive_ordinal: u64,
    /// Round-6 exactness: how many times THIS edge fired in this call, counted by
    /// the epilogue itself. Replaces the derived `transitions/len + …` round-robin
    /// estimate, which is only valid when every trace owns exactly one phase of
    /// exactly one live ring — a property the detector does not enforce.
    firings: u64,
    /// One-based silent-transition ordinal of this edge's most recent firing
    /// (productive or not); zero means it never fired in this call.
    last_ordinal: u64,
};

comptime {
    std.debug.assert(@sizeOf(SilentSummaryCell) == 8 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "productive_firings") == 3 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "last_local") == 4 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "last_productive_ordinal") == 5 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "firings") == 6 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "last_ordinal") == 7 * @sizeOf(u64));
}

/// Runtime-owned payload addressed through a compile-time-owned pointer cell. B-3a
/// freezes this transport; B-3b will allocate/populate instances before patching.
pub const SilentExitMetadata = extern struct {
    summary: *SilentSummaryCell,
    slot: *usize,
    min_useful: u64,
    reporting_target: usize,
};

pub const ExitPatchKind = enum(u8) { deopt, link_terminal, loop_done_linked, region_bridge };
pub const EXIT_NOP5 = [5]u8{ 0x0F, 0x1F, 0x44, 0x00, 0x00 };

pub const ExitPatch = struct {
    kind: ExitPatchKind,
    exit_instr: u32,
    patch_off: u32,
    original: [5]u8,
    epilogue_off: u32,
    metadata_cell: *usize,
};

/// Doc 22 §A.1b/§B.4: the page-owned seed plan — which of `t.inputs` this
/// compiled page actually consumes at entry. A committed `Trace` is immutable
/// (its `inputs` cannot be edited at analysis time), and the carried-heap
/// rewrite makes some recorded `hash_cell` seeds redundant: an `href` rooted at
/// a carried-heap slot re-resolves the CURRENT table's cell per iteration via
/// the `resolveHashCell` callout and never reads the entry-seeded slab slot.
/// Processing such a seed normally is worse than wasteful — its entry-table
/// validation could hash-decline the whole entry even though the emitted body
/// deliberately re-resolves per iteration. So compilation *deactivates* it here
/// instead. The Phase-B seeding helper (`NativeSeedCtx.seed_fn`) resolves only
/// active seeds (inactive slab slots stay unwritten), and "does this page seed
/// at entry" is defined as `plan.nonEmpty()` — never raw `inputs.len`.
/// Computed by `computeSeedPlan` for every compile; consumed by the Phase-B
/// entry prologue (inert until B-ii emits it).
pub const SeedPlan = struct {
    /// LSB-first bitmap over `t.inputs` indices; bit set ⇒ the seed is active.
    /// 64 bits bounds `inputs.len` for seeded pages (`computeSeedPlan` bails
    /// beyond it, fail closed — real traces carry a handful of inputs).
    bits: u64 = 0,

    pub fn nonEmpty(self: SeedPlan) bool {
        return self.bits != 0;
    }

    pub fn isActive(self: SeedPlan, i: usize) bool {
        return i < 64 and (self.bits >> @intCast(i)) & 1 != 0;
    }

    fn activate(self: *SeedPlan, i: usize) void {
        self.bits |= @as(u64, 1) << @intCast(i);
    }
};

/// A compiled trace: an executable page whose entry is
/// `fn(tags: [*]u8, payloads: [*]u64, result: *NativeResult) callconv(.c) void` —
/// the SoA register file's two base pointers (tags in rdi, payloads in rsi), plus
/// an out-param in rdx for the committed iteration count and deterministic exit
/// instruction. Semantically identical to `irinterp.execute(t, regs, scratch)`.
pub const CompiledTrace = struct {
    page: ExecPage,
    /// Frameless dispatch (P-A / doc 17 Increment 2). `null` → the page is a
    /// self-framed function (test path via `compile`/`mapExecutable`), called
    /// directly as `EntryFn`. Non-null → the page is a frameless body; run it by
    /// calling this shared trampoline with `page.code.ptr` as the body_entry arg.
    trampoline_entry: ?usize = null,
    /// Link-slot table (doc 17 Increment 2.3), one 8-byte absolute target per IR
    /// instruction index. A chainable exit (`.link` terminal / linked-loop-done stub)
    /// jumps through `jmp qword [&slots[i]]`; the default value is the shared
    /// trampoline teardown (`shared_exit`), so an unarmed slot behaves exactly like
    /// 2.1's direct `jmp shared_exit`. `driveChain` arms a slot (2.3b+) by storing a
    /// child's frameless body entry into it — a plain data write (the array is
    /// ordinary GPA heap memory, always RW; no `mprotect`, no rel32 constraint since
    /// the exit loads the slot address as a full imm64). Empty for self-framed test
    /// pages (`trampoline_entry == null`). Owned; freed in `deinit` via `gpa`.
    slots: []usize = &.{},
    /// The allocator that owns `slots` (needed at `deinit`, which has no other handle
    /// to a gpa — the page frees itself through its own owner).
    gpa: std.mem.Allocator = undefined,
    /// Secondary entry point (doc 17 Increment 2.3b-0): absolute address of the
    /// `linked_entry` stub, which presets `NativeResult.linked_loop_done = 1` then
    /// falls through to `body_entry`. When a native parent arms a `.link`-terminal
    /// handoff into this trace (2.3b-1), the slot targets THIS address, not
    /// `page.code.ptr`, so the child materializes its numeric-for loop-done in linked
    /// mode (commit the final iteration) exactly as `runLinkedLoopDone` would — a bare
    /// jump to the body would leave `linked_loop_done = 0` and mis-deopt. `null` for
    /// self-framed test pages (never chained) and non-frameless builds. Points into
    /// the same owned `page`, so it needs no separate free.
    linked_entry: ?usize = null,
    /// Secondary entry point (doc 17 Increment 2.3c-0): the dual of `linked_entry`.
    /// Presets `NativeResult.linked_loop_done = 0` then falls through to `body_entry`.
    /// A FUSED handoff inherits whatever `linked_loop_done` sits in the shared
    /// `NativeResult` (rdx) — and `linked_entry` leaves it stuck at 1. The
    /// inner→continuation hop (2.3c-2) arms the inner's linked-loop-done slot into a
    /// continuation that must run in ORDINARY mode, so it targets THIS entry to clear
    /// the inherited flag; a bare jump to `body_entry` would let the continuation's own
    /// numeric-for loop-done guard wrongly take the linked-materialization path. `null`
    /// on the same builds as `linked_entry` (frameless production only). Points into
    /// the same owned `page`; no separate free. INERT until 2.3c-2 arms a slot to it.
    ordinary_entry: ?usize = null,
    /// B-3a patch descriptors and stable per-exit metadata pointer cells. The cells
    /// remain null and every epilogue unreachable until B-3b publishes promotion.
    exit_patches: []ExitPatch = &.{},
    metadata_cells: []usize = &.{},
    /// Doc 22 §B.4: which of the trace's `inputs` this page consumes at entry
    /// (see `SeedPlan`). Set by `compileImpl` for every page; "this page seeds
    /// at entry" is `seed_plan.nonEmpty()`, never raw `inputs.len`. The Phase-B
    /// invariant `seed_plan.nonEmpty() == seed_prologue` is release-asserted by
    /// `trace.TraceState.stubEnterable` at every arm/link gate (B-iv).
    seed_plan: SeedPlan = .{},
    /// Doc 22 §B.4: whether the emitted body actually carries the seed prologue,
    /// recorded at emission time (see `EntryStubs.seed_prologue`). Independent
    /// witness for the `seed_plan.nonEmpty() ⟺ prologue-present` invariant.
    seed_prologue: bool = false,

    pub const EntryFn = fn ([*]u8, [*]u64, *NativeResult) callconv(.c) void;
    /// The shared frameless trampoline's C-ABI type: SoA lanes + result out-param,
    /// plus the body entry address in the 4th arg (rcx).
    pub const TrampolineFn = fn ([*]u8, [*]u64, *NativeResult, *const anyopaque) callconv(.c) void;

    /// Run the trace over the register file `regs` (mutated in place at each loop
    /// commit, exactly as the IR-interpreter does). Returns the committed-iteration
    /// count plus the failing IR instruction when native can identify it. The two
    /// lanes are passed as the SysV first two args (rdi=tags, rsi=payloads); the
    /// result pointer is the third (rdx), reserved out of the allocator pools.
    pub fn run(self: CompiledTrace, regs: RegWindow) irinterp.ExecResult {
        return self.runWithLinkedLoopDone(regs, false, null, .{});
    }

    /// Run in the chain-consumed loop-done mode. Numeric-for loop-done exits commit
    /// the final iteration's post-guard stores and phi snapshot before returning,
    /// so the native nested-loop chainer can jump to the `.link` continuation
    /// without tier-0 replay.
    pub fn runLinkedLoopDone(self: CompiledTrace, regs: RegWindow) irinterp.ExecResult {
        return self.runWithLinkedLoopDone(regs, true, null, .{});
    }

    /// 2.3c-2b (doc 17): like `run` (ordinary mode, `linked_loop_done = 0`) but ALSO
    /// decodes the native per-transition ledger into `ledger_out[0..ledger_len]`, so
    /// `runLinkedBurst` replays each fused `C→I` hop the terminal-only scalar fields
    /// hide instead of re-reading them. `ledger_out` must have room for `LEDGER_CAP`
    /// entries (the native append is bounds-guarded at that cap). The borrow is
    /// consumed immediately by the caller's replay — no native call / resize / nested
    /// replay may intervene between this capture and its consumption.
    pub fn runCapturingLedger(self: CompiledTrace, regs: RegWindow, ledger_out: []irinterp.LedgerEntry, silent: SilentStaging) irinterp.ExecResult {
        return self.runWithLinkedLoopDone(regs, false, ledger_out, silent);
    }

    /// 2.3c-2d (D1): the LINKED-mode counterpart of `runCapturingLedger`. Call A
    /// (`runLinkedBurst`'s first inner drive, trace.zig) needs the chain-consumed
    /// loop-done materialization (`linked_loop_done = 1`: the final inner iteration's
    /// post-guard stores + phi snapshot are committed so regs are coherent at the
    /// continuation anchor) AND the per-transition ledger. A literal `runCapturingLedger`
    /// swap would flip the mode to ordinary (0) and leave the final iteration for tier-0
    /// replay, corrupting the coherent resume — so capture MUST preserve the mode. Same
    /// borrow contract as `runCapturingLedger`: `ledger_out` holds `LEDGER_CAP` entries
    /// and is consumed immediately, with no intervening native call.
    pub fn runLinkedLoopDoneCapturing(self: CompiledTrace, regs: RegWindow, ledger_out: []irinterp.LedgerEntry, silent: SilentStaging) irinterp.ExecResult {
        return self.runWithLinkedLoopDone(regs, true, ledger_out, silent);
    }

    fn runWithLinkedLoopDone(self: CompiledTrace, regs: RegWindow, linked_loop_done: bool, ledger_out: ?[]irinterp.LedgerEntry, silent: SilentStaging) irinterp.ExecResult {
        var result = NativeResult{
            .completed = 0,
            .exit_instr = std.math.maxInt(u32),
            .linked_loop_done = if (linked_loop_done) 1 else 0,
            .final_trace_id = irinterp.NO_TRACE_ID,
            .entry_rbx = 0,
            .exit_reason = @intFromEnum(irinterp.ExitReason.normal),
            .exit_target = 0,
            // 2.3c-2a: fresh span → zero recorded transitions. Arrays stay `undefined`;
            // only `[0..ledger_len]` is ever read, and every appended slot is fully
            // written by `emitLedgerAppend` before `ledger_len` counts it.
            .ledger_len = 0,
            .ledger_cum = undefined,
            .ledger_id = undefined,
            .ledger_exit = undefined,
            .ledger_reason = undefined,
            .ledger_kind = undefined,
            .ledger_outcome = undefined,
            .silent_active = 0,
            .silent_transitions = 0,
            .silent_budget = silent.silent_budget,
            .barren_budget = silent.barren_budget,
            .silent_cell = 0,
            .cur_zero_run = silent.cur_zero_run,
            .silent_cum = 0,
            .silent_last_cell = 0,
        };
        if (self.trampoline_entry) |tramp| {
            const f: *const TrampolineFn = @ptrFromInt(tramp);
            f(regs.tags, regs.payloads, &result, self.page.code.ptr);
        } else {
            self.page.entry(EntryFn)(regs.tags, regs.payloads, &result);
        }
        // 2.3b-0/2.3b-1: the final trace's OWN committed count = cumulative rbx − the
        // rbx it inherited at entry. `-%` because a spurious wrap is never worse than the
        // old behaviour and there is no valid case where entry_rbx > completed. Before
        // 2.3b-1 armed a slot, every body was entered fresh (rbx = 0 → entry_rbx = 0) and
        // this equalled `completed`; now that a parent `.link` slot can `jmp` straight
        // into a child under the shared frame, the fused child inherits the parent's
        // cumulative `rbx`, so `entry_rbx > 0` is the expected steady state and the old
        // `assert(entry_rbx == 0)` no longer holds.
        const local: usize = result.completed -% result.entry_rbx;
        // 2.3c-2a: the per-transition ledger's TERMINAL entry must reproduce the scalar
        // result fields. The ledger's whole reason to exist — recover the HIDDEN
        // intermediate hops a fused span drops — is only trustworthy if its last entry
        // agrees with the body that actually returned. A debug tripwire while the drain
        // still reads scalar fields (2.3c-2b flips the drain to consume the ledger
        // authoritatively); it proves the append fired (`ledger_len ≥ 1`), stayed in
        // bounds, and that the scale-8 `ledger_cum` store landed at the right index with
        // `rbx`. Native only (tier-1a never enters this wrapper).
        if (std.debug.runtime_safety) {
            const n = result.ledger_len;
            std.debug.assert(n <= irinterp.LEDGER_CAP);
            std.debug.assert(result.silent_active != 0 or n >= 1);
            if (n != 0) {
                std.debug.assert(result.ledger_cum[n - 1] == result.completed);
                std.debug.assert(result.ledger_id[n - 1] == result.final_trace_id);
                std.debug.assert(result.ledger_exit[n - 1] == result.exit_instr);
                std.debug.assert(result.ledger_reason[n - 1] == result.exit_reason);
                // 2.3c-2c: the site tag must agree with the scalar reason on the only
                // axis the scalar fields expose — each non-`.normal` reason ⟺ its
                // matching terminal site (prologue_fail, and doc 22 §B.2's two seed
                // declines), and vice-versa. (link_terminal / loop_done_linked /
                // deopt all carry reason `.normal`, so the ledger `kind` is what tells them
                // apart; nothing scalar cross-checks those three yet — the generic replay
                // validates them structurally in 2.3c-2c.)
                const term_kind: irinterp.LedgerKind = @enumFromInt(result.ledger_kind[n - 1]);
                std.debug.assert((result.exit_reason == @intFromEnum(irinterp.ExitReason.prologue_fail)) ==
                    (term_kind == .prologue_fail));
                std.debug.assert((result.exit_reason == @intFromEnum(irinterp.ExitReason.seed_hash_decline)) ==
                    (term_kind == .seed_hash_decline));
                std.debug.assert((result.exit_reason == @intFromEnum(irinterp.ExitReason.seed_capacity_decline)) ==
                    (term_kind == .seed_capacity_decline));
            }
        }
        // 2.3c-2b: decode the per-transition ledger for the caller's replay. Only
        // `[0..ledger_len]` is meaningful; the append fully writes every counted slot.
        if (ledger_out) |out| {
            std.debug.assert(out.len >= result.ledger_len);
            var k: usize = 0;
            while (k < result.ledger_len) : (k += 1) {
                out[k] = .{
                    .cum = result.ledger_cum[k],
                    .id = result.ledger_id[k],
                    .exit = result.ledger_exit[k],
                    .reason = @enumFromInt(result.ledger_reason[k]),
                    .kind = @enumFromInt(result.ledger_kind[k]),
                    .outcome = @enumFromInt(result.ledger_outcome[k]),
                };
            }
        }
        return .{
            .completed = result.completed,
            .exit_instr = result.exit_instr,
            .final_trace_id = result.final_trace_id,
            .local_completed = local,
            .exit_reason = @enumFromInt(result.exit_reason),
            .ledger_len = result.ledger_len,
            .silent_active = result.silent_active,
            .silent_transitions = result.silent_transitions,
            .silent_budget = result.silent_budget,
            .barren_budget = result.barren_budget,
            .silent_cell = result.silent_cell,
            .cur_zero_run = result.cur_zero_run,
            .silent_cum = result.silent_cum,
            .silent_last_cell = result.silent_last_cell,
        };
    }

    pub fn pageGeneration(self: *const CompiledTrace) ?u64 {
        return switch (self.page.owner) {
            .arena => |slot| slot.generation,
            .owned => null,
        };
    }

    pub fn deinit(self: *CompiledTrace) void {
        self.page.deinit();
        if (self.slots.len > 0) self.gpa.free(self.slots);
        if (self.exit_patches.len > 0) self.gpa.free(self.exit_patches);
        if (self.metadata_cells.len > 0) self.gpa.free(self.metadata_cells);
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
    return compileImpl(gpa, t, null, null, null);
}

/// Test entry point for ALLOCATING traces (doc 24): like `compile` but with the
/// heap whose counters/`gc_stress` the `guard_gc` lowering and the `tostr_*`
/// callouts bake as absolute addresses. Without one, an allocating trace bails
/// (fail closed) — see `compileImpl`.
pub fn compileWithHeap(gpa: std.mem.Allocator, t: *const Trace, heap: *gc.Heap) ?CompiledTrace {
    return compileImpl(gpa, t, null, null, heap);
}

/// Test entry point for SEEDED traces (doc 22 §B.2): like `compile` but with a
/// seeding ctx to bake into the entry prologue. A trace whose seed plan is
/// non-empty cannot compile without one (fail closed, §B.4).
pub fn compileSeeded(gpa: std.mem.Allocator, t: *const Trace, seed_ctx: *const trace.NativeSeedCtx) ?CompiledTrace {
    return compileImpl(gpa, t, null, seed_ctx, null);
}

/// Production entry point: compile `t` and co-locate its code in the shared `arena`
/// (P-D). Same bail semantics as `compile`; the only difference is where the mcode
/// lives (an arena slot vs a standalone `mmap`). `seed_ctx` is the per-VM seeding
/// context (doc 22 §B.1) a seeded trace's entry prologue bakes; nullable because
/// hand-built test TraceStates carry none — a seeded trace then bails to tier-1a.
pub fn compileInto(gpa: std.mem.Allocator, arena: *McodeArena, t: *const Trace, seed_ctx: ?*const trace.NativeSeedCtx, heap: ?*gc.Heap) ?CompiledTrace {
    return compileImpl(gpa, t, arena, seed_ctx, heap);
}

/// Shared compile body. `arena == null` maps a standalone owned page (test path);
/// non-null co-locates the code as an arena slot (production path).
fn compileImpl(gpa: std.mem.Allocator, t: *const Trace, arena: ?*McodeArena, seed_ctx: ?*const trace.NativeSeedCtx, heap: ?*gc.Heap) ?CompiledTrace {
    if (comptime !is_x64_linux) return null;

    const n = t.instrs.len;
    // Doc 24 D5 fail-closed: an allocating body (`guard_gc` / `tostr_*`) bakes
    // the heap's counter and `gc_stress` addresses (and hands the heap to the
    // interning callouts) — without a heap it cannot be lowered soundly, so it
    // bails to tier-1a rather than compile a body that could never re-check
    // the budget. (Hand-built test TraceStates pass none unless they mean to.)
    if (heap == null) {
        for (t.instrs) |ins| {
            switch (ins.op) {
                .guard_gc, .tostr_int, .tostr_num => return null,
                else => {},
            }
        }
    }
    // A well-formed native-able trace is non-empty and ends in a terminal `loop`
    // or `link`. Re-checked here because `assertWellFormed` is gone in release
    // builds (never trust the IR).
    if (n == 0 or n > 0xFFFF) return null;
    const terminal = t.instrs[n - 1].op;
    if (terminal != .loop and terminal != .link) return null;

    const kinds = gpa.alloc(Kind, n) catch return null;
    defer gpa.free(kinds);
    const slot_of = gpa.alloc(i32, n) catch return null;
    defer gpa.free(slot_of);

    if (!proveKinds(gpa, t, kinds, slot_of)) return null;

    // cut-2: the register allocator + single-snapshot deopt. A `null` is a bail (the
    // trace runs on tier-1a) — e.g. a type-unstable carried slot the hoisted guard
    // can't catch.
    var alloc = analyze(gpa, t, kinds, slot_of) orelse return null;
    defer alloc.deinit(gpa);

    // Doc 22 §A.1b/§B.4: the page-owned seed plan. Needs the slot classes
    // (carried-heap discrimination), so it runs after `analyze`. `null` ⇒ more
    // inputs than the plan can name ⇒ bail (fail closed).
    const seed_plan = computeSeedPlan(t, kinds, alloc.slots, alloc.slot_id_of_ref) orelse return null;
    // Doc 22 §B.2/§B.4 fail-closed: an active plan needs a seeding ctx to bake into
    // the entry prologue. No ctx (hand-built test TraceState) ⇒ the seeded trace
    // cannot self-seed ⇒ bail to tier-1a. This is also what makes the §B.4 invariant
    // definitional: `lower` emits the prologue iff `seed_plan.nonEmpty()`, and this
    // bail guarantees the ctx it bakes exists.
    if (seed_plan.nonEmpty() and seed_ctx == null) return null;
    // B-v (doc 22 §A.1b + §B.6 redundant-seed row): the inactive-slot contract.
    // The seeding helper skips a plan-inactive seed, so its slab slot stays
    // UNWRITTEN at entry — the emitted body must never read it.
    //
    // This was a release `@panic` scanning every instr for an `href` OR a
    // `slot_load` naming the slot. The `href` half was unsatisfiable: it is the
    // exact negation of `computeSeedPlan`'s activation clause (same pure
    // predicate, same `kinds`/`slots`/`slot_id_of_ref`/`t.instrs`, nothing
    // mutated in between), evaluated inside `if (isActive) continue` — a literal
    // contradiction. It could never fire.
    //
    // The `slot_load` half rests on a real and separate fact, so it is kept as a
    // debug assert: `.hash_cell` is the only deactivatable kind, and a hash
    // cell's slot is consumed solely through `href.aux` — `recInputGet` is the
    // only site that emits a seed `slot_load` (and the only one that appends to
    // `entry_slots`), while `seedHashCell` stamps aux and emits none. Checking
    // `entry_slots` instead of every instr also makes it O(inputs x entry_slots).
    if (std.debug.runtime_safety) {
        for (t.inputs, 0..) |seed, i| {
            if (seed_plan.isActive(i)) continue;
            std.debug.assert(seed.kind == .hash_cell);
            for (t.entry_slots) |es| std.debug.assert(es != seed.slot);
        }
    }

    // Frameless production path (arena present): reserve the shared trampoline and
    // emit a body that `jmp`s to its shared_exit. Test path (arena == null) keeps the
    // self-framed ABI so the standalone-page unit tests are untouched — and gives a
    // built-in A/B of the two ABIs over the same lowered trace.
    var shared_exit: ?usize = null;
    var tramp_entry: ?usize = null;
    // Link-slot table (doc 17 Increment 2.3), exactly one usize per IR instr index.
    // Allocated only on the frameless production path (the self-framed test page has no
    // shared trampoline to default to and never chains). Every entry defaults to
    // `shared_exit`, so an unarmed exit behaves exactly like 2.1's direct jump — the
    // table is inert until `driveChain` arms a slot. Its address must be stable *before*
    // `lower` bakes `&slots[i]` as an imm64, so it is allocated here and handed in.
    // No reserved trailing cell: the loop-done ORDINARY deopt reaches `shared_exit`
    // through the memory-staged `NativeResult.exit_target` (it must bypass its own
    // `slot[ei]`, which is the EXCLUSIVE linked-materialized exit — P-C option (b)),
    // so `slots.len == n` and every index is a real IR exit slot that `armNativeLink`
    // may legitimately arm.
    var slots: []usize = &.{};
    var metadata_cells: []usize = &.{};
    var patch_emissions: []?PatchEmission = &.{};
    if (arena) |ar| {
        // A frameless body may only address SPILL_MAX spill slots (the trampoline
        // reserves exactly that many). Beyond it → bail to tier-1a.
        if (alloc.spill_count > SPILL_MAX) return null;
        const tr = ar.ensureTrampoline() catch return null;
        shared_exit = tr.shared_exit;
        tramp_entry = tr.entry;
        slots = gpa.alloc(usize, n) catch return null;
        @memset(slots, tr.shared_exit);
        metadata_cells = gpa.alloc(usize, n) catch {
            gpa.free(slots);
            return null;
        };
        @memset(metadata_cells, 0);
        patch_emissions = gpa.alloc(?PatchEmission, n) catch {
            gpa.free(metadata_cells);
            gpa.free(slots);
            return null;
        };
        @memset(patch_emissions, null);
    }
    defer if (patch_emissions.len > 0) gpa.free(patch_emissions);

    var asm_buf = x64.Assembler.init(gpa);
    defer asm_buf.deinit();
    const entry_stubs = lower(gpa, t, kinds, &alloc, &asm_buf, shared_exit, slots, metadata_cells, patch_emissions, seed_ctx, seed_plan, heap) catch {
        if (metadata_cells.len > 0) gpa.free(metadata_cells);
        if (slots.len > 0) gpa.free(slots);
        return null;
    };
    asm_buf.resolve();

    var patch_count: usize = 0;
    for (patch_emissions) |p| if (p != null) {
        patch_count += 1;
    };
    var exit_patches: []ExitPatch = &.{};
    if (patch_count > 0) {
        exit_patches = gpa.alloc(ExitPatch, patch_count) catch {
            gpa.free(metadata_cells);
            gpa.free(slots);
            return null;
        };
        var pi: usize = 0;
        for (patch_emissions, 0..) |maybe, ei| if (maybe) |em| {
            const off = em.patch_off;
            if (off > asm_buf.code.items.len or asm_buf.code.items.len - off < 5) {
                gpa.free(exit_patches);
                gpa.free(metadata_cells);
                gpa.free(slots);
                return null;
            }
            var original: [5]u8 = undefined;
            @memcpy(&original, asm_buf.code.items[off..][0..5]);
            if ((em.kind == .deopt and original[0] != 0xE9) or
                (em.kind != .deopt and !std.mem.eql(u8, &original, &EXIT_NOP5)))
            {
                gpa.free(exit_patches);
                gpa.free(metadata_cells);
                gpa.free(slots);
                return null;
            }
            exit_patches[pi] = .{
                .kind = em.kind,
                .exit_instr = @intCast(ei),
                .patch_off = @intCast(off),
                .original = original,
                .epilogue_off = @intCast(asm_buf.labelOffset(em.epilogue)),
                .metadata_cell = &metadata_cells[ei],
            };
            pi += 1;
        };
    }

    const page = if (arena) |a|
        a.alloc(asm_buf.code.items) catch {
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        }
    else
        mapExecutable(asm_buf.code.items) catch {
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        };
    // Resolve the secondary-entry stubs' absolute addresses (base + byte offset). Both
    // live in the same mapped `page`, so they are freed with it — no extra owner.
    const base = @intFromPtr(page.code.ptr);
    const linked_entry: ?usize = if (entry_stubs.linked_entry) |off| blk: {
        if (off >= page.code.len) {
            var invalid_page = page;
            invalid_page.deinit();
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        }
        break :blk base + off;
    } else null;
    const ordinary_entry: ?usize = if (entry_stubs.ordinary_entry) |off| blk: {
        if (off >= page.code.len) {
            var invalid_page = page;
            invalid_page.deinit();
            if (exit_patches.len > 0) gpa.free(exit_patches);
            if (metadata_cells.len > 0) gpa.free(metadata_cells);
            if (slots.len > 0) gpa.free(slots);
            return null;
        }
        break :blk base + off;
    } else null;
    // Wiring invariant (2.3b-0/2.3c-0): a frameless production body (arena present ⟺
    // shared_exit set) ALWAYS emits BOTH secondary entries; a self-framed test page
    // never does. Pins that the mechanism produces real secondary entries before an
    // increment arms a slot to them.
    std.debug.assert((arena != null) == (linked_entry != null));
    std.debug.assert((linked_entry != null) == (ordinary_entry != null));
    // Doc 22 §B.4: the plan (source of truth for "this page seeds at entry") and
    // the emitted prologue must agree. This used to be release-asserted over in
    // `stubEnterable`, described there as witnessed by "two independent facts".
    // They are not independent: `seed_hash_exit` is assigned only inside
    // `if (seed_plan.nonEmpty())`, and `stubs.seed_prologue = seed_hash_exit
    // != null` on the single path through `lower` — one fact routed through two
    // fields. As a result that check was a tautology on every real page and
    // could only ever fire on a hand-built test fixture, while costing a branch
    // in a predicate consulted at every arm attempt. Asserted HERE instead,
    // which is where a future conditional-emission path in `lower` would
    // actually break it.
    std.debug.assert(seed_plan.nonEmpty() == entry_stubs.seed_prologue);
    return .{
        .page = page,
        .trampoline_entry = tramp_entry,
        .slots = slots,
        .gpa = gpa,
        .linked_entry = linked_entry,
        .ordinary_entry = ordinary_entry,
        .exit_patches = exit_patches,
        .metadata_cells = metadata_cells,
        .seed_plan = seed_plan,
        .seed_prologue = entry_stubs.seed_prologue,
    };
}

/// Forward type-proof over the linear SSA. Fills `kinds` (and `slot_of`, the
/// register slot of each `slot_load`) and returns `true` iff every value is a
/// proven `int`/`bool` produced by a supported op — otherwise `false` (bail).
pub fn proveKinds(gpa: std.mem.Allocator, t: *const Trace, kinds: []Kind, slot_of: []i32) bool {
    const n = t.instrs.len;
    @memset(kinds, .none);
    @memset(slot_of, -1);

    // Pass A: record each slot_load's register slot, and which slot_loads a
    // `guard_int` covers. A guard on a *slot_load* is the type check we hoist to a
    // single tag-check in the prologue (lowering reads the tag straight from
    // `regs[slot]`), so mark it. A guard on a *derived* value (e.g. an `add`/`mul`
    // result) is not hoisted: it is validated in Pass B against the value's
    // already-proven kind and lowered to nothing — a derived int (int-op-of-ints)
    // can never fail the guard. So we no longer bail on a non-slot_load operand.
    const guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(guarded);
    @memset(guarded, false);
    // Parallel to `guarded`, but for `guard_float` (Phase D): a slot_load it covers
    // is a float input → classified `.float`, hoisted to a single TAG_FLOAT prologue
    // check + a `movsd` slot load. A guard_float on a *derived* float (an arith
    // result) is validated in Pass B against the already-proven kind and lowers to
    // nothing — exactly like the derived guard_int relaxation.
    const float_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(float_guarded);
    @memset(float_guarded, false);
    // Parallel to `guarded`, but for `guard_table`: a slot_load it covers is the
    // table value → classified `.ptr` (invariant, loaded once).
    const table_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(table_guarded);
    @memset(table_guarded, false);
    // Parallel to `table_guarded`, but for `guard_func` (U1, cross-frame): a
    // slot_load it covers is the snapshot callee value → classified `.func`
    // (invariant closure pointer, identity-checked once in the prologue).
    const func_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(func_guarded);
    @memset(func_guarded, false);
    // Parallel to `func_guarded`, but for `guard_builtin` (the pure-builtin identity
    // guard): a slot_load it covers is the callee-snapshot value → classified
    // `.native` (invariant native pointer, identity-checked once in the prologue
    // against the recorded `RecordedBuiltin` tag).
    const pure_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(pure_guarded);
    @memset(pure_guarded, false);
    // Per-aref: has a `guard_bounds` on this aref been proven before we reach a
    // `guard_present`/`aload`? [I4 / review] `present` is non-null only when
    // `len > 0`, which a passing `guard_bounds` (idx0 <u len) implies — so the
    // bitmap `bt` and the data load are memory-safe ONLY behind a dominating
    // bounds check. The recorder emits that order; this enforces it on the IR we
    // were handed (a malformed/deserialized trace must not segfault).
    const bounds_ok = gpa.alloc(bool, n) catch return false;
    defer gpa.free(bounds_ok);
    @memset(bounds_ok, false);
    // Per-value: has a `guard_fits` proven this value fits the narrow int lane's
    // signed range? [B4b] An int-lane astore requires it — native cannot widen
    // the lane mid-run (it has no allocate-and-repack path), so the recorder
    // emits a `guard_fits` ahead of every int-lane store and the tier-1a oracle
    // side-exits identically when the value would overflow the lane. Without a
    // covering guard_fits an int-lane astore bails the whole trace to tier-1a.
    const fits_ok = gpa.alloc(bool, n) catch return false;
    defer gpa.free(fits_ok);
    @memset(fits_ok, false);
    // Per-gcell (doc 14): has a `guard_gcol` proven this cell's column in
    // `[1, stride]`? A grid `gload`/`gstore`/`guard_gpresent` touches `data`/
    // `present` at the flat index `gcell` computed (`row0*stride + col-1`), which
    // is in `[0, rows*stride)` — and thus inside the `cap*stride` buffer — only
    // when BOTH the row bound (`guard_bounds` on the `garow`) and this column bound
    // hold. Without a covering guard_gcol a grid memory op bails to tier-1a.
    const gcol_ok = gpa.alloc(bool, n) catch return false;
    defer gpa.free(gcol_ok);
    @memset(gcol_ok, false);
    // Per-konst: is this `.konst` ref used as the *key operand* of an `href` (H1)?
    // The key is the interned field-name string — a heap const, which the `.konst`
    // arm below would otherwise reject (`else => return false`). An href reads its
    // cell from the seeded slab slot, never from the key, so the key carries no
    // native value: a marked heap-key konst is accepted as `.none` and `lower`
    // emits nothing for it. Any OTHER use of a heap const (one feeding a non-href
    // op) stays unmarked and bails, exactly as before.
    const href_key = gpa.alloc(bool, n) catch return false;
    defer gpa.free(href_key);
    @memset(href_key, false);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                slot_of[i] = ins.aux;
            },
            // H1: mark this href's key operand so the `.konst` arm accepts the
            // interned heap-string key (its only use). Full href validation is in
            // Pass B; here we only need the forward-collected key marking.
            .href => {
                const r = ins.b;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .konst) href_key[r] = true;
            },
            .guard_int => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .slot_load) guarded[r] = true;
            },
            .guard_float => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .slot_load) float_guarded[r] = true;
            },
            .guard_table => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                // A table guard on a slot_load covers the table-bearing snapshot
                // slot; the native path hoists it to a prologue heap/type check.
                // A guard on an aload (Phase 2, .value-lane) is a per-iteration
                // body guard — accept it but don't mark table_guarded (no slot
                // to pin for the prologue).
                if (t.instrs[r].op == .slot_load) {
                    table_guarded[r] = true;
                } else if (t.instrs[r].op != .aload) {
                    return false;
                }
            },
            // guard_grid (doc 14): the grid analogue of guard_table+guard_lane. It
            // covers the grid table's slot_load (proven `.ptr`); the prologue
            // additionally verifies `lane == .grid ∧ grid_elem == aux`. Like
            // guard_table it only ever guards a table-bearing slot_load.
            .guard_grid => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op != .slot_load) return false;
                table_guarded[r] = true;
            },
            .guard_func => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                // A func guard only ever covers the callee-snapshot slot_load (the
                // recorder emits it on a fresh synthetic input); the native path
                // hoists it to a prologue closure/proto-id check.
                if (t.instrs[r].op != .slot_load) return false;
                func_guarded[r] = true;
            },
            .guard_builtin => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                // A pure guard only ever covers the callee-snapshot slot_load (the
                // recorder emits it on a fresh seeded upvalue/global input); the native
                // path hoists it to a prologue native/`RecordedBuiltin`-tag check.
                if (t.instrs[r].op != .slot_load) return false;
                pure_guarded[r] = true;
            },
            else => {},
        }
    }

    // The single packed lane this trace's array ops touch (set by the first
    // lane-bearing op; every later one must match — see `laneConsistent`).
    var trace_lane: ?i32 = null;

    // Pass B: assign kinds, validating operands and constants as we go.
    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (guarded[i]) {
                    kinds[i] = .int;
                } else if (float_guarded[i]) {
                    kinds[i] = .float; // guard_float-covered → float input
                } else if (table_guarded[i]) {
                    kinds[i] = .ptr; // guard_table-covered → invariant table pointer
                } else if (func_guarded[i]) {
                    kinds[i] = .func; // guard_func-covered → invariant callee closure
                } else if (pure_guarded[i]) {
                    kinds[i] = .native; // guard_builtin-covered → invariant callee native
                } else {
                    return false; // unguarded → cannot prove a kind
                }
            },
            .konst => {
                if (ins.aux < 0 or ins.aux >= t.consts.len) return false;
                kinds[i] = switch (t.consts[@intCast(ins.aux)].tag) {
                    .int => .int,
                    .boolean => .bool,
                    .float => .float, // Phase D: a float constant materializes via movq
                    // H1: a heap const is admissible ONLY as an href key (the interned
                    // field-name string). It carries no native value — href reads the
                    // seeded cell, not the key — so accept it as `.none` and let `lower`
                    // emit nothing. Any other heap-const use stays unmarked → bails.
                    .heap_ref => if (href_key[i]) .none else return false,
                    else => return false, // nil → bail
                };
            },
            // Arithmetic: the recorder stamps the *result* type in `ins.ty`
            // (`arithResultType`: float iff div/pow or any operand float). Trust it
            // for the result kind and validate the operands are the matching class.
            //   - int result  → both operands proven int (the existing path).
            //   - float result → each operand int OR float; an int operand is
            //     promoted with `cvtsi2sd` at its use site. (band/bor/bxor are
            //     always int — they never carry `ins.ty == .float`.)
            .add, .sub, .mul => {
                if (ins.ty == .float) {
                    if (!isNumKind(kinds[ins.a]) or !isNumKind(kinds[ins.b])) return false;
                    // [review] Don't trust `ins.ty == .float` blindly: the oracle
                    // (arith.zig) computes int+int as a wrapping INTEGER and boxes
                    // TAG_INT, while a float lowering would cvtsi2sd both and box
                    // TAG_FLOAT — a divergence on side-exit. A genuine float result
                    // requires at least one float operand; a malformed/deserialized
                    // trace claiming otherwise bails to tier-1a.
                    if (kinds[ins.a] != .float and kinds[ins.b] != .float) return false;
                    kinds[i] = .float;
                } else {
                    if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                    kinds[i] = .int;
                }
            },
            .band, .bor, .bxor => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .int;
            },
            // shl/shr: both operands int, int result. The native lowering reproduces
            // Lua's full shift semantics (negative count → reverse direction, |count|
            // >= 64 → 0) with an explicit range bracket, so any int count is correct —
            // no masking assumption (`emitShift`).
            .shl, .shr, .sar => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .int;
            },
            // div is ALWAYS float (arithResultType stamps ins.ty == .float), even on
            // two int operands (3/2 == 1.5). The oracle computes a.toFloat()/b.toFloat()
            // under strict FP, where toFloat(int) == @floatFromInt == cvtsi2sd — so the
            // int/int case is bit-exact too (unlike a compare, this conversion is the
            // oracle's own path). No "≥1 float operand" gate: int/int div is genuinely
            // float here. NaN/inf (x/0.0, 0.0/0.0) fall out of IEEE divsd identically.
            .div => {
                if (!isNumKind(kinds[ins.a]) or !isNumKind(kinds[ins.b])) return false;
                kinds[i] = .float;
            },
            .neg, .bnot => {
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .int;
            },
            // int_of_float: the operand must be a proven float (a guard_float-covered
            // slot_load or a derived float); the result is the exact integer value
            // (or a side-exit). Lowers to a `cvttsd2si` round-trip check + convert.
            .int_of_float => {
                if (kinds[ins.a] != .float) return false;
                kinds[i] = .int;
            },
            // alen (doc 23 D3): the `#t` fast-case border. The operand is a
            // loop-invariant table home (`.ptr`, guard_table-covered slot_load) or
            // a per-iteration element table (`.heap`, .value-lane aload). The
            // lowered body re-verifies the whole fast case with memory-operand
            // compares (mirroring guard_append) and side-exits on any miss, so no
            // analysis-time table state is baked into the code. Result: the
            // border, an int.
            .alen => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                kinds[i] = .int;
            },
            .eq, .ne, .lt, .le => {
                // Two int operands → int compare (existing path). Two float operands →
                // float compare (F2, ucomisd). A MIXED int/float compare bails: the
                // oracle (value.compareNumeric) compares the int against the float
                // EXACTLY (compareIntFloat, no rounding), so a cvtsi2sd-then-ucomisd
                // lowering would diverge for ints not representable as f64. (Unlike F1
                // arith, where the oracle promotes via toFloat — there cvtsi2sd matches.)
                const ka = kinds[ins.a];
                const kb = kinds[ins.b];
                if (!((ka == .int and kb == .int) or (ka == .float and kb == .float))) return false;
                kinds[i] = .bool;
            },
            .guard_int => {
                // Passes trivially iff the operand is already proven int — a guarded
                // slot_load (set .int above) or a derived int (int-op-of-ints). Then
                // it is redundant and lowers to nothing. A guard on a .bool (e.g. a
                // compare result) or any unproven value can't be discharged → bail.
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .none;
            },
            .guard_float => {
                // Passes iff the operand is already proven float — a guard_float-
                // covered slot_load (set .float above) or a derived float (an arith
                // result with `ins.ty == .float`). Redundant then, lowers to nothing.
                // A guard_float on an int/bool/unproven value can't be discharged → bail.
                if (kinds[ins.a] != .float) return false;
                kinds[i] = .none;
            },
            .guard_true, .guard_false => {
                const k = kinds[ins.a];
                if (k != .int and k != .bool) return false;
                kinds[i] = .none;
            },
            // --- lane-aware array read path (B2) ---------------------------------
            // guard_table / guard_lane: cover the table slot_load (proven .ptr).
            // guard_lane additionally pins the lane; the native path only lowers
            // the bool lane, so any other lane bails here.
            .guard_table => {
                if (ins.a >= i) return false;
                // `.ptr` = loop-invariant table (prologue-hoisted, no-op in body).
                // `.heap` = per-iteration element table from .value-lane aload
                // (Phase 2) — body guard, NOT hoisted.
                if (kinds[ins.a] != .ptr and kinds[ins.a] != .heap) return false;
                kinds[i] = .none;
            },
            // guard_func (U1, cross-frame): covers the callee-snapshot slot_load
            // (proven `.func`). Pinned to a prologue identity check (closure type +
            // recorded `Proto.id`); lowers to nothing in the body, like guard_table.
            .guard_func => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .func) return false;
                kinds[i] = .none;
            },
            // guard_builtin (the pure-builtin identity guard): covers the callee-snapshot
            // slot_load (proven `.native`). Pinned to a prologue identity check (native
            // type + recorded `RecordedBuiltin` tag); lowers to nothing in the body, like
            // guard_func. The callee is a once-seeded loop-invariant upvalue/global, so
            // one prologue check covers the whole native run.
            .guard_builtin => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .native) return false;
                kinds[i] = .none;
            },
            // fsqrt: a leaf float producer computing `@sqrt` of its operand (the same
            // IEEE correctly-rounded sqrt as native `sqrtsd` under the default MXCSR).
            // The operand is a proven float, OR a proven int promoted by the same
            // operand-level `cvtsi2sd` the float binops use (`floatOperandToXmm`);
            // the result is a float. fsqrt lowers to a single `sqrtsd`; fsin/fcos
            // lower to a mid-body callout into the shared noinline `fmath` kernel
            // (doc 23 D4) — there is no bit-identical SSE instruction for them.
            .fsqrt, .fsin, .fcos => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .float and kinds[ins.a] != .int) return false;
                kinds[i] = .float;
            },
            // Doc 24 D4/D5: allocating interned-string producers. The operand is
            // the guard-pinned scalar; the result is a raw `*GcHeader` (an
            // interned String) — kind `.heap`, the same class as a carried-heap
            // value or a VALUE_LANE aload result, so the existing homes/flush
            // (TAG_HEAP re-box) apply. Lowered as a mid-body callout into the
            // shared `stralloc` body; side-exits on OOM (null return).
            .tostr_int => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .heap;
            },
            .tostr_num => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .float) return false;
                kinds[i] = .heap;
            },
            // `#s` of a proven string: one 8-byte load of the cached `cp_len`
            // field. The operand must be a proven string producer's result
            // (`tostr_*` — kind `.heap` via the arms above); a `guard_string`-
            // pinned slot is NOT yet native (guard_string bails below, c3).
            .slen => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .heap) return false;
                // Doc 24 c2 scope: only the proven-string producers reach
                // `.heap` upstream of a `slen` today (`tostr_*`); a carried-heap
                // slot's `.heap` is a TABLE (guard_table-covered) and its `#`
                // records as `alen`, never `slen`. When c3 admits observed
                // strings natively (guard_string), this arm stays correct: the
                // guard proves stringness before the load.
                const prod = t.instrs[ins.a].op;
                if (prod != .tostr_int and prod != .tostr_num) return false;
                kinds[i] = .int;
            },
            // Doc 24 c2 scope: `guard_string` (an observed-string pin) is not
            // lowered natively yet — a trace using it runs tier-1a. c3 lands it
            // together with the snew-class ops that need it.
            .guard_string => return false,
            // Doc 24 D3: the allocation-budget entry guard. Value-less; lowered
            // to two loads of the baked heap counters + the gc_stress byte test.
            // `compileImpl` guaranteed `heap != null` for any trace containing it.
            .guard_gc => {
                if (ins.aux <= 0) return false; // bound A is stamped positive
                kinds[i] = .none;
            },
            // --- hash-part field path (H1) --------------------------------------
            // href: a value-cell pointer (`*Value`) for a constant string key into
            // a table's hash part. Two sub-paths:
            // - `.ptr` table (loop-invariant): cell resolved once per entry by
            //   `seedTraceInputs` into slab slot `ins.aux` ≥ 0.
            // - `.heap` table (Phase 2, per-iteration): cell resolved per iteration
            //   by a call-out to `resolveHashCell`; `ins.aux == -1` (no seed slot).
            // In both cases `b` is the interned key konst (marked an href_key above
            // → accepted `.none`). The result is a distinct `.href` kind.
            .href => {
                if (ins.a >= i or ins.b >= i) return false;
                if (t.instrs[ins.b].op != .konst) return false; // key is a constant
                if (kinds[ins.a] == .ptr) {
                    // Loop-invariant: seed slot must be valid.
                    if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                } else if (kinds[ins.a] == .heap) {
                    // Per-iteration: recorder sets aux = -1 (no seed).
                    if (ins.aux != -1) return false;
                } else {
                    return false;
                }
                kinds[i] = .href;
            },
            // guard_hash: the structural sentinel. The oracle re-resolves the cell and
            // re-checks `metatable==null ∧ getPtr(key)!=null ∧ hash.count()==recorded`
            // every iteration; native relies on the per-entry seed validation in
            // `seedTraceInputs` (a failed resolve routes the whole entry to tier-1a
            // instead of native) and the per-iteration `hload` tag-check, so in the
            // native body this guard lowers to nothing. Covers an href.
            .guard_hash => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .href) return false;
                kinds[i] = .none;
            },
            // hload: a typed load from the cell. `a` is the href; the recorder stamps
            // the observed scalar type in `ins.ty` and emits the existing type-guard on
            // this ref. Native restricts to int/float field values (a heap-valued field
            // declines native, like the `.value` array lane); the load tag-checks
            // `[cell+0]` (side-exit on mismatch) then loads `[cell+8]`.
            .hload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .href) return false;
                kinds[i] = switch (ins.ty) {
                    .int => .int,
                    .float => .float,
                    else => return false, // heap/bool field value → tier-1a
                };
            },
            // hstore: overwrite the present cell in place (no grow — the present-key
            // rule holds). `a` is the href, `b` the value; native lowers int/float
            // values to a tag+payload store and declines a heap value. Produces nothing.
            .hstore => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .href) return false;
                const vk = kinds[ins.b];
                if (vk != .int and vk != .float) return false; // heap value → tier-1a
                kinds[i] = .none;
            },
            .guard_lane => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr) return false;
                // `.value` lane: accepted for Phase 2 (array-of-structs). The
                // prologue checks `array.lane == .value` the same way it checks
                // any other lane byte. No scalar lane-kind produced — the aload
                // arm handles the `.value` case separately.
                if (ins.aux != VALUE_LANE and laneKind(ins.aux) == null) return false;
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                kinds[i] = .none;
            },
            // aref pairs (table, index); its register carries idx0 = index-1. A
            // distinct `.aref` kind so it can neither feed arithmetic nor be flushed.
            .aref => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .ptr or kinds[ins.b] != .int) return false;
                if (ins.aux != VALUE_LANE and laneKind(ins.aux) == null) return false;
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                kinds[i] = .aref;
            },
            // guard_bounds (idx0 <u len): the bounds proof for this aref. Marks the
            // aref bounds-checked so a later guard_present/aload may touch memory.
            .guard_bounds => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                bounds_ok[ins.a] = true;
                kinds[i] = .none;
            },
            // guard_present (bool: in-band byte ≠ 0; int/float: bt the presence
            // bitmap): only safe behind a dominating bounds check on the same aref
            // (else the data/presence load may be null / idx0 OOB).
            .guard_present => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!bounds_ok[ins.a]) return false; // [I4] bounds must dominate
                kinds[i] = .none;
            },
            // aload decodes the slot to a boolean (bool lane: movzx the in-band byte
            // then sub 1) or a sign-extended int (i8…i64). Likewise gated on a
            // dominating bounds check (the data load is indexed by idx0, which must
            // be proven in range).
            .aload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!bounds_ok[ins.a]) return false; // [I4] bounds must dominate
                if (ins.aux == VALUE_LANE) {
                    // Phase 2: .value-lane aload produces a per-iteration heap
                    // pointer (a *GcHeader for a table). Only the .heap ty is
                    // accepted — scalar .value-lane elements still bail.
                    if (ins.ty != .heap) return false;
                    kinds[i] = .heap;
                } else {
                    const lk = laneKind(ins.aux) orelse return false;
                    if (!laneConsistent(&trace_lane, ins.aux)) return false;
                    kinds[i] = lk; // bool → .bool; i8…i64/u8 → .int; f64 → .float
                }
            },
            // guard_fits: the value (`a`) still fits the recorded narrow lane.
            // For an int lane it marks the value so a following int-lane astore may
            // store it without widening; lowers to a range compare (i8/i16/i32) or
            // nothing (i64 — every i64 fits). For the bool lane it is a tier-1a-only
            // soundness guard (a free-variable non-bool store side-exits there);
            // native already proves the value is `.bool`, so it lowers to nothing.
            // For the f64 lane it likewise lowers to nothing (a double is never
            // narrowed). Only the `.value` lane bails (laneKind → null).
            .guard_fits => {
                if (ins.a >= i) return false;
                const lk = laneKind(ins.aux) orelse return false; // .value → tier-1a
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                switch (lk) {
                    .int => {
                        if (kinds[ins.a] != .int) return false; // only int values are range-guarded
                        fits_ok[ins.a] = true;
                    },
                    // The bool lane's guard_fits exists only for the tier-1a oracle
                    // (it side-exits a free-variable non-bool store). Native already
                    // requires the astore value to be a proven `.bool`, so this guard
                    // lowers to nothing — just type-check it and drop it.
                    .bool => if (kinds[ins.a] != .bool) return false,
                    // The f64 lane's guard_fits, like the bool lane's, exists for the
                    // tier-1a oracle (it side-exits a free-variable non-float store).
                    // Native already requires the astore value to be a proven `.float`
                    // and a double is never width-truncated, so this lowers to nothing —
                    // just type-check it and drop it. Unlike the int lanes it does NOT
                    // mark `fits_ok`: an f64 astore is a full-width `movsd` that needs no
                    // range coverage, so it must compile even when tropt has folded this
                    // guard away (a constant store fits trivially → guard DCE'd).
                    .float => if (kinds[ins.a] != .float) return false,
                    else => return false,
                }
                kinds[i] = .none;
            },
            // astore encodes the value (`b`) into the lane slot addressed by the
            // aref (`a`). Like aload, the data write is indexed by idx0, so it
            // requires a dominating bounds check on the same aref [I1/P1] (else it
            // could write out of bounds). C1 — that the stored value not depend on
            // any prior `aload` — is enforced at record time (`recArraySet` aborts),
            // so by here the value is a guarded slot input or constant. astore
            // produces no value.
            .astore => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                const lk = laneKind(ins.aux) orelse return false; // .value → tier-1a
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                if (!bounds_ok[ins.a]) return false; // [I1/P1] bounds must dominate
                switch (lk) {
                    .bool => {
                        if (kinds[ins.b] != .bool) return false; // bool lane stores a boolean
                    },
                    .int => {
                        // int lane (i8…i64): the value must be a proven int AND
                        // provably fit the lane width, so native may store it at the
                        // lane width without the widening tier-0 would otherwise do.
                        // Fit is established by a covering guard_fits (a free-variable
                        // store) OR, when tropt folded that guard away because the
                        // value is a constant that trivially fits, by re-deriving the
                        // static fit here (a const fill/init store) — mirrors the f64
                        // arm below.
                        if (kinds[ins.b] != .int) return false;
                        if (!fits_ok[ins.b] and !konstFitsLane(t, ins.b, ins.aux)) return false;
                    },
                    .float => {
                        // f64 lane: the value need only be a proven float. The store is
                        // a full-width `movsd` with no truncation, so EVERY double fits —
                        // there is nothing to range-check, hence no `fits_ok` requirement
                        // (mirrors the bool lane, NOT the narrow int lanes). This is what
                        // lets a constant-float fill (`a[k] = 2.0`) compile even though
                        // tropt folds the redundant guard_fits for the constant.
                        if (kinds[ins.b] != .float) return false;
                    },
                    else => return false, // laneKind yields .bool/.int/.float
                }
                kinds[i] = .none;
            },
            // guard_append (the grow precondition): like guard_bounds, it proves the
            // aref addresses a writable slot — here `data[len]`, the in-cap append
            // successor (idx==len+1, len<cap) into a migrate-free (empty-hash) table.
            // Marks the aref bounds-checked so the following astore_append may store.
            // bool + i8…i64 (the lanes the append path lowers); `.value` → tier-1a.
            // (`.f64` passes laneKind but the recorder never emits an f64 append —
            // the astore_append below bails it; see there.)
            .guard_append => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                const aref_ins = t.instrs[ins.a];
                if (laneKind(aref_ins.aux) == null) return false; // .value → tier-1a
                if (!laneConsistent(&trace_lane, aref_ins.aux)) return false;
                bounds_ok[ins.a] = true;
                kinds[i] = .none;
            },
            // astore_append: append the value at `data[len]` and bump len. Like
            // astore, gated on a dominating bounds proof (guard_append) on the same
            // aref. Same lane/value rules as the in-bounds astore: bool lane stores a
            // proven boolean (in-band byte); int lanes store a proven int covered by a
            // dominating guard_fits (so the width-truncating native store is exact).
            .astore_append => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                // Validate the lane `lower()` actually switches on (`ins.aux`), exactly
                // like the in-bounds `astore` — not the aref's aux. The aref arm already
                // pinned its own aux to `trace_lane`, so checking `ins.aux` against
                // `trace_lane` here forces ins.aux == aref.aux transitively; a trace
                // whose astore_append.aux disagreed with its aref would be rejected
                // rather than lowered with a mismatched width/lane.
                const lk = laneKind(ins.aux) orelse return false; // .value → tier-1a
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                if (!bounds_ok[ins.a]) return false; // guard_append must dominate
                switch (lk) {
                    .bool => if (kinds[ins.b] != .bool) return false,
                    .int => {
                        if (kinds[ins.b] != .int) return false;
                        // guard_fits ⇒ width store is exact; or a constant whose fit
                        // tropt proved and folded away (const fill append, `p[i]=0`).
                        if (!fits_ok[ins.b] and !konstFitsLane(t, ins.b, ins.aux)) return false;
                    },
                    // f64 append is intentionally not lowered in this cut: the recorder's
                    // append gate (`recArraySet`) excludes the f64 lane, so no f64
                    // astore_append is ever emitted. Should one appear, bail to tier-1a.
                    else => return false,
                }
                kinds[i] = .none;
            },
            // --- flattened-grid cell path (doc 14, Phase 8) ---------------------
            // guard_grid / guard_stride: cover the grid table's slot_load (proven
            // `.ptr`). Both are PROLOGUE-pinned structural guards — the prologue
            // checks `lane == .grid ∧ grid_elem == aux` (guard_grid) and
            // `stride == aux` (guard_stride) once per native entry, so in the body
            // they lower to nothing, exactly like guard_table/guard_lane. Sound
            // because grid_elem and stride are invariant across a native run: the
            // recorder aborts any growing/widening store, and a deflation only ever
            // happens on a bare access, which is never part of a recorded trace.
            .guard_grid => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr) return false;
                const lk = laneKind(ins.aux) orelse return false; // grid_elem lane
                if (lk != .int and lk != .float) return false; // int + f64 grid lanes
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                kinds[i] = .none;
            },
            .guard_stride => {
                // `ins.aux` is the recorded stride VALUE (a row width), not a lane —
                // do not run laneKind on it. The prologue compares the live
                // `array.stride` against it; an enlarged grid side-exits there.
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr) return false;
                kinds[i] = .none;
            },
            // garow pairs (grid table, row); its register carries the row base —
            // concretely row0 = row-1 (the 0-based row), exactly mirroring `aref`'s
            // idx0. Reuses the `.aref` kind so it composes with the existing
            // guard_bounds (row0 <u rows, since a grid's array length == its row
            // count) and the home-reservation machinery.
            .garow => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .ptr or kinds[ins.b] != .int) return false;
                const lk = laneKind(ins.aux) orelse return false;
                if (lk != .int and lk != .float) return false; // int + f64 grid lanes (bool never a grid)
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                kinds[i] = .aref;
            },
            // gcell pairs (garow, col); its register carries the FLAT cell index
            // flat = row0*stride + (col-1), with `stride` folded as an imm32 from the
            // covering guard_stride. Also `.aref`-kind (it addresses one scalar cell,
            // just like an aref's idx0) so the gload/gstore/guard_gpresent arms below
            // treat it uniformly. The row-bounds proof lives on the `garow`
            // (guard_bounds), which the recorder emits before this gcell — require it
            // here so the flat index a memory op will dereference is row-safe.
            .gcell => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref or kinds[ins.b] != .int) return false;
                const lk = laneKind(ins.aux) orelse return false;
                if (lk != .int and lk != .float) return false;
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                if (!bounds_ok[ins.a]) return false; // row bound must dominate the gcell
                kinds[i] = .aref;
            },
            // guard_gcol (col in [1, stride]): the column bound for this gcell, the
            // grid analogue of guard_bounds. `b` carries the column ref (kept live so
            // native can range-compare it). Marks the gcell column-checked so a
            // following gload/gstore/guard_gpresent may dereference the cell.
            .guard_gcol => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref or kinds[ins.b] != .int) return false;
                gcol_ok[ins.a] = true;
                kinds[i] = .none;
            },
            // guard_gpresent (cell present): bt the per-cell presence bitmap at the
            // flat index. Safe only behind BOTH the row bound (carried on the garow,
            // already required at the gcell) and the column bound (guard_gcol on this
            // gcell) — else the bit index is outside the buffer.
            .guard_gpresent => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!gcol_ok[ins.a]) return false; // column bound must dominate
                kinds[i] = .none;
            },
            // gload: a typed load from the grid cell addressed by the gcell. Gated on
            // the column proof; the row proof is already discharged at the gcell. An
            // int cell sign/zero-extends the grid_elem-width element into a GP home; an
            // f64 cell `movsd`s the raw double into an XMM home (kind `.float`).
            .gload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!gcol_ok[ins.a]) return false; // column bound must dominate
                const lk = laneKind(ins.aux) orelse return false;
                if (lk != .int and lk != .float) return false;
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                kinds[i] = lk; // int grid → .int (GP); f64 grid → .float (XMM)
            },
            // gstore: encode the value (`b`) into the grid cell addressed by the
            // gcell (`a`) and set its presence bit. Gated on the column proof; the
            // row proof is discharged at the gcell. The recorder emits a covering
            // guard_fits on the value and aborts a growing store, so for an int lane
            // the value is a proven int that fits grid_elem (store at the cell width);
            // for an f64 lane it is a proven float committed as a full-width `movsd`
            // (every double fits → no fits_ok requirement, mirroring the f64 astore).
            // Produces no value.
            .gstore => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!gcol_ok[ins.a]) return false; // column bound must dominate
                const lk = laneKind(ins.aux) orelse return false;
                if (!laneConsistent(&trace_lane, ins.aux)) return false;
                switch (lk) {
                    .int => {
                        if (kinds[ins.b] != .int) return false;
                        if (!fits_ok[ins.b]) return false; // guard_fits ⇒ width store is exact
                    },
                    .float => {
                        if (kinds[ins.b] != .float) return false; // full-width movsd, no range check
                    },
                    else => return false,
                }
                kinds[i] = .none;
            },
            .loop => {
                if (i != n - 1) return false; // loop must be terminal
                kinds[i] = .none;
            },
            .link => {
                if (i != n - 1) return false; // link must be terminal
                kinds[i] = .none;
            },
            // Phase E1/E2: the preheader region boundary. A pure marker (no value);
            // everything before it is the run-once region the lowering emits ahead
            // of `loop_top`. `analyze` gives each run-once value a computed home.
            .preheader => {
                kinds[i] = .none;
            },
            // A loop-carried φ. `b` (the back-edge update) is the one operand allowed
            // to reference a *later* node, so it is only range-checked here (< n) and
            // kind-checked in the post-pass below (it may not be assigned yet on the
            // forward scan). A *slot-bound* φ (aux >= 0) records a writeback to
            // regs[aux]; the body reads the slot through its `slot_load`, never the φ
            // node, so the φ itself is value-less (.none) — exactly what the old
            // exit_store was. An *internal* φ (aux == PHI_INTERNAL) backs no register:
            // its init `a` is a real preheader ref (a < i) and its value carries the
            // recorded scalar type, since body uses reference the φ directly.
            .phi => {
                if (ins.b >= n) return false;
                if (ins.aux == trace.PHI_INTERNAL) {
                    if (ins.a >= i) return false; // init must precede the φ
                    kinds[i] = switch (ins.ty) {
                        .int => .int,
                        .float => .float,
                        .boolean => .bool,
                        else => return false,
                    };
                } else {
                    if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                    kinds[i] = .none;
                }
            },
            // pow: always a float producer (Lua `^`), evaluated by a two-arg
            // body callout into the shared `fmath.powRuntime` kernel — the same
            // body `arith.pow` runs in tier-0/tier-1a, so bit-identity holds by
            // construction. Operands are any proven numeric (an int promotes
            // via the shared `cvtsi2sd` discipline at the callout).
            .pow => {
                if (ins.a >= i or ins.b >= i) return false;
                if (ins.ty != .float) return false; // the oracle always boxes float
                if (!isNumKind(kinds[ins.a]) or !isNumKind(kinds[ins.b])) return false;
                kinds[i] = .float;
            },
            // Everything else (idiv/mod/guard_number/float-neg) is deferred —
            // bail to tier-1a. (shl/shr, guard_float, guard_builtin and fsqrt are handled
            // above.)
            else => return false,
        }
    }

    // Every loop-carried writeback must reference a boxable value. A raw table
    // pointer is boxable as TAG_HEAP and is needed for compiler temporaries that
    // are write-only at a while-loop header. A `.heap` value (a per-iteration
    // table from a VALUE_LANE aload) is likewise TAG_HEAP-boxable and is the
    // carried-heap writeback of doc 22 §A.1 (`bi = b[i]`-shaped outer bodies) —
    // `analyze` classifies the slot and decides admissibility. An `.aref` is only
    // an addressing token and must never escape into the VM register file. This
    // runs after Pass B so a φ's forward-referencing `b` has its kind assigned.
    for (t.instrs) |p| {
        if (p.op != .phi) continue;
        if (p.b >= n) return false;
        const k = kinds[p.b];
        if (k != .int and k != .bool and k != .float and k != .ptr and k != .heap) return false;
    }
    return true;
}

/// True iff `k` is a numeric scalar (int or float) — i.e. a valid operand to a
/// float arithmetic op (an int is `cvtsi2sd`'d at its use site).
fn isNumKind(k: Kind) bool {
    return k == .int or k == .float;
}

// ---------------------------------------------------------------------------
// doc 22 §A.1b: carried-heap roots and per-iteration table facts
//
// A *carried-heap* slot (class == .carried, kind == .heap) holds a table whose
// identity changes at every back-edge (`bi = b[i]`-shaped φ writeback). Any
// entry-time fact about that table — the seeded hash cell, the prologue's
// type/metatable/lane checks, a hoisted array base — describes only the FIRST
// iteration's table, so every table-rooted op on such a slot must use its
// dynamic in-body form (exactly the forms the `.heap`-kind aload roots already
// use). These predicates are the single decision point, shared by analysis
// (liveness, coalescing safety, save-area sizing) and lowering.

/// True iff `ref` is the slot_load of a carried-heap slot.
fn isCarriedHeapRoot(slots: []const SlotInfo, slot_id_of_ref: []const i32, ref: u16) bool {
    const sid = slot_id_of_ref[ref];
    if (sid < 0) return false;
    const s = slots[@intCast(sid)];
    return s.class == .carried and s.kind == .heap;
}

/// True iff a table-rooted op at `ref` cannot rely on entry-time facts: the root
/// is a per-iteration `.heap` value (VALUE_LANE aload result) or a carried-heap
/// slot. An href on such a root needs the `resolveHashCell` callout; its
/// guard_table/guard_hash need their dynamic in-body forms.
fn isDynTableRoot(kinds: []const Kind, slots: []const SlotInfo, slot_id_of_ref: []const i32, ref: u16) bool {
    return kinds[ref] == .heap or isCarriedHeapRoot(slots, slot_id_of_ref, ref);
}

/// Does lowering emit a mid-body side-exit for instruction `idx`? Home
/// coalescing must not order an in-place carried-home update before ANY of
/// these — the single-snapshot deopt flush would commit a partial iteration
/// (see the coalescing block in `analyzeInner`). This is the closed inventory
/// of every `jccNativeExit`/`jmpNativeExit` the body emitter can produce; when
/// adding a new side-exiting lowering, extend this switch in the same change.
///
/// [Rule #0.5] This replaces a hand-kept op list that had gone stale: it was
/// blind to the href-callout miss exit, the dynamic guard_table/guard_hash
/// forms, the VALUE_LANE aload heap-tag check, and the grid guards
/// guard_gcol/guard_gpresent — any of which, ordered after the last inventoried
/// guard, would have let a coalesced in-place update commit early.
fn opMayExitInBody(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
    idx: usize,
) bool {
    const ins = t.instrs[idx];
    return switch (ins.op) {
        .guard_true,
        .guard_false,
        .guard_bounds,
        .guard_present,
        .guard_fits,
        .guard_append,
        .int_of_float,
        .hload,
        .guard_gcol,
        .guard_gpresent,
        .alen,
        // Doc 24: the budget guard exits when headroom is gone; the tostr
        // callouts exit on OOM (null return).
        .guard_gc,
        .tostr_int,
        .tostr_num,
        => true,
        // A VALUE_LANE aload tag-checks TAG_HEAP and side-exits on mismatch;
        // scalar-lane aloads are exit-free (guard_present/guard_bounds dominate).
        .aload => ins.aux == VALUE_LANE,
        // The dynamic (per-iteration) table checks side-exit; the `.ptr` forms
        // are prologue-hoisted / seed-validated and emit nothing in the body.
        .guard_table => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        // A dynamically-resolved href side-exits on callout miss (cell == 0).
        .href => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        .guard_hash => isDynTableRoot(kinds, slots, slot_id_of_ref, t.instrs[ins.a].a),
        else => false,
    };
}

// doc 22 §A.2 (HelperCaps), doc 24 D5 (the may_allocate/may_collect split): a
// heap φ keeps a raw `*GcHeader` in a register or spill cell across the whole
// body with no GC root. That is sound only while nothing in the body can
// trigger a COLLECTION — so every runtime helper the body may call out to is
// enumerated here with an explicit may-collect capability, and heap-φ
// admission refuses the trace if any callout could collect. Mere ALLOCATION
// (`tostr_*`) does not invalidate a φ-carried pointer: the GC is non-moving
// and allocation never collects in place (the single collect site is tier-0's
// dispatch prologue); its determinism cost is accounted by the `guard_gc`
// budget instead. A new callout MUST add a row (the exhaustive switch enforces
// it at compile time); claiming may_collect=false for a helper that can reach
// `Vm.collect` would be a soundness bug.

/// Every runtime helper a native body can call MID-ITERATION. The enum exists
/// solely to feed `calloutMayCollect`, i.e. to answer "can a heap φ be
/// invalidated across this call site", so membership is exactly "reachable from
/// `bodyCalloutOf`" — a variant no mapping ever returns is dead weight that
/// makes the GC audit look broader than it is.
///
/// Deliberately EXCLUDED, and why it needs no row: `NativeSeedCtx.seed_fn`
/// (doc 22 §B.2), the entry-prologue seeding callout that resolves
/// upvalue/global/hash-cell inputs into the trace's slab slots. It runs ONCE at
/// entry, before any heap φ is live, so it is outside this enum's question by
/// construction — not merely a `can_gc = false` answer to it. (For the record
/// it also allocates nothing: resolution and validation only — upvalue reads,
/// global-table lookups, hash-chain walks.)
const BodyCallout = enum {
    /// `resolveHashCell`: pure hash-chain walk over an existing table — reads
    /// the key, hashes, follows cells; allocates nothing.
    resolve_hash_cell,
    /// `fmath.sinRuntime`: the shared noinline `math.sin` kernel (doc 23 D4) —
    /// a pure f64 → f64 function; allocates nothing.
    fsin,
    /// `fmath.cosRuntime`: likewise for `math.cos`.
    fcos,
    /// `fmath.powRuntime`: the shared `^` kernel — pure (f64, f64) → f64;
    /// allocates nothing.
    fpow,
    /// `stralloc.tostrIntRuntime` (doc 24): renders + interns an int's decimal
    /// string. **may_allocate = true** (at most ONE `Heap.link` per call — the
    /// D5 audit rule; an intern hit links zero), **may_collect = false**
    /// (allocation never collects in place — the ONLY collect site is the
    /// tier-0 dispatch prologue).
    tostr_int,
    /// `stralloc.tostrNumRuntime`: likewise for a float. Same
    /// may_allocate/may_collect split as `tostr_int`.
    tostr_num,
};

/// The doc-22 capability, renamed for the doc-24 may_allocate/may_collect
/// split: can this callout trigger a COLLECTION mid-body? That is the only
/// capability heap-φ admission cares about — the GC is non-moving and
/// allocation never collects in place (single collect site: tier-0's dispatch
/// prologue), so a callout that merely ALLOCATES (`tostr_*`) leaves every
/// φ-carried raw `*GcHeader` valid. Allocation capability is documented
/// per-row above and accounted by the `guard_gc` budget instead.
fn calloutMayCollect(c: BodyCallout) bool {
    return switch (c) {
        .resolve_hash_cell => false,
        .fsin, .fcos, .fpow => false,
        .tostr_int, .tostr_num => false,
    };
}

/// Which helper (if any) does instruction `idx` call out to in the body?
fn bodyCalloutOf(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
    idx: usize,
) ?BodyCallout {
    const ins = t.instrs[idx];
    return switch (ins.op) {
        .href => if (isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a)) .resolve_hash_cell else null,
        .fsin => .fsin,
        .fcos => .fcos,
        .pow => .fpow,
        .tostr_int => .tostr_int,
        .tostr_num => .tostr_num,
        else => null,
    };
}

/// Doc 22 §A.1b: compute the page's `SeedPlan` — which of `t.inputs` the
/// emitted body actually consumes at entry.
///
/// - `.upvalue` / `.global` seeds are always active: their slab slots are read
///   by ordinary `slot_load`s in the body.
/// - A `.hash_cell` seed is active iff some `href` names its slot (`aux ==
///   seed.slot`) AND that href's table root is *not* dynamic (`isDynTableRoot`
///   false). A dynamic-rooted href lowers to the per-iteration
///   `resolveHashCell` callout (aux forced to -1) and never reads the seeded
///   slab slot — seeding it would be dead work whose entry validation could
///   spuriously hash-decline the whole entry.
/// - `null` ⇒ compile bail (fail closed): more inputs than the 64-bit plan can
///   name. Real traces carry a handful; this is a structural bound, not a
///   tuning knob.
fn computeSeedPlan(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
) ?SeedPlan {
    if (t.inputs.len > 64) return null;
    var plan = SeedPlan{};
    for (t.inputs, 0..) |seed, i| {
        switch (seed.kind) {
            .upvalue, .global => plan.activate(i),
            .hash_cell => {
                for (t.instrs) |ins| {
                    if (ins.op != .href) continue;
                    if (ins.aux < 0) continue;
                    if (@as(u32, @intCast(ins.aux)) != seed.slot) continue;
                    if (!isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a)) {
                        plan.activate(i);
                        break;
                    }
                }
            },
        }
    }
    return plan;
}

// ---------------------------------------------------------------------------
// cut-2: register allocation + single-snapshot deopt — the analysis half
//
// `analyze` is a forward linear-scan over the linear SSA that (a) classifies each
// tier-0 slot the trace touches, (b) computes per-ref liveness, and (c) assigns
// every value a `Loc` (a CPU register or a frame spill slot). It is *pure analysis*:
// `lower` consumes its output in later commits. Landed first as a measured no-op so
// the risky logic rides under the existing differential oracle.
// ---------------------------------------------------------------------------

/// Where a value lives during the loop body.
const Loc = union(enum) {
    reg: Reg, // a general-purpose register (int/bool/ptr/aref)
    xmm: Reg, // an XMM register (float) — same 0..15 index space, disjoint pool
    spill: u32, // frame slot index; byte displacement = index * 8 (kind-agnostic 8-B cell)
};

/// How a slot participates in the loop, deciding its prologue/back-edge/EXIT handling.
pub const SlotClass = enum {
    /// slot_loaded AND in exit_stores: read+write loop-carried. Gets a home; flushed
    /// to regs[] on a side-exit; reassigned at the back-edge shuffle.
    carried,
    /// slot_loaded, NOT in exit_stores: read-only, loop-invariant. Loaded once into a
    /// home; never written back (untouched ⇒ coherent).
    invariant,
    /// in exit_stores, NOT slot_loaded (e.g. `flag = i<limit`). No home; committed to
    /// regs[] at the back-edge (cut-1 style); never touched at EXIT.
    write_only,
};

/// Compile-time facts about one tier-0 slot.
const SlotInfo = struct {
    slot: u16,
    class: SlotClass,
    kind: Kind, // box tag at commit/flush (int/ptr for carried/invariant; store_ref's for write_only)
    home: Loc, // valid for carried/invariant
    load_ref: i32, // the slot_load ref, or -1
    store_ref: i32, // the exit_store ref feeding it, or -1
    /// For a `.ptr` (table) invariant slot: the bool-lane ordinal its `guard_lane`
    /// pins, checked once in the prologue. `-1` for non-`.ptr` slots.
    lane: i32,
    /// For a `.func` (cross-frame callee snapshot) invariant slot: the recorded
    /// `Proto.id` its covering `guard_func` pins, checked once in the prologue
    /// (closure type + this id). Unused (0) for non-`.func` slots.
    func_id: u32 = 0,
    /// For a `.native` (pure-builtin callee snapshot) invariant slot: the recorded
    /// `RecordedBuiltin` ordinal its covering `guard_builtin` pins, checked once in the
    /// prologue (native type + this tag's payload byte + the non-null flag). `-1` for
    /// non-`.native` slots.
    recorded_tag: i32 = -1,
    /// For a `.ptr` table accessed as a GRID (doc 14): the `grid_elem` lane ordinal
    /// (an int lane) its covering `guard_grid` pins and the `stride` its
    /// `guard_stride` pins, both checked once in the prologue (`array.grid_elem ==
    /// grid_elem ∧ array.stride == grid_stride`; `s.lane` is set to `GRID_LANE` so
    /// the shared lane check verifies `array.lane == .grid`). `-1` when the slot is
    /// not a grid table. `grid_stride` is also the folded immediate `gcell` uses for
    /// its `row*stride` multiply — sound because the prologue proved it equals the
    /// runtime stride and no traced store grows it (the recorder aborts a grow).
    grid_elem: i32 = -1,
    grid_stride: i32 = -1,
    /// win 2: the store_ref transient was allocated *into* home, so the op updates the
    /// home in place and the back-edge shuffle move for this slot self-elides. Only set
    /// for `carried` slots passing the safety predicate (see `analyzeInner`).
    coalesced: bool,
    /// Phase 2 (invariant array-base hoisting): for a `.ptr` slot used as an
    /// `aref.a`, the loop-invariant array base pointers / length, materialized ONCE
    /// in the prologue into a dedicated register and reused across every iteration
    /// (instead of re-loading `[tbreg+field]` each time). `null` ⇒ not hoisted (no
    /// free register, or the field is unused) and the body keeps the per-iteration
    /// load — correctness never depends on seating. Valid for the whole native run
    /// by the B5 invariant: the read/write path never reallocates or lane-widens the
    /// array (`guard_fits` side-exits first). Pure invariant scratch — never written
    /// back to `regs[]` on exit.
    data_home: ?Reg = null, // [array_base + data]  (element pointer)
    present_home: ?Reg = null, // [array_base + present] (int-lane presence bitmap ptr)
    len_home: ?Reg = null, // [array_base + asize]   (slot count / bounds limit, for guard_bounds)
};

/// The allocator's output — the sole input `lower` needs (later commits).
pub const Alloc = struct {
    loc: []Loc, // [n] location of each ref's value (slot_load refs resolve to their home)
    last_use: []u32, // [n] index of the last instruction reading each ref
    slot_id_of_ref: []i32, // [n] slots[] index for a slot_load ref, else -1
    slots: []SlotInfo,
    spill_count: u32, // frame slots used (homes + transients); frame = spill_count*8
    used_callee_saved: u16, // bitmask of callee-saved GPRs used (must be push/pop'd)

    // --- callout save area (Phase 2, .value-lane href) ---
    // When a trace contains a .heap-rooted href (per-iteration hash-cell
    // resolution via `resolveHashCell`), the callout clobbers all SysV
    // caller-saved registers. Live homes in those registers must be saved
    // to the frame before the call and restored after. These fields describe
    // the save area appended to the spill region (slots callout_save_base ..
    // callout_save_base + callout_save_count - 1).
    callout_save_base: u32 = 0, // first spill-slot index of save area
    callout_save_count: u32 = 0, // number of 8-byte slots reserved

    pub fn deinit(self: *Alloc, gpa: std.mem.Allocator) void {
        gpa.free(self.loc);
        gpa.free(self.last_use);
        gpa.free(self.slot_id_of_ref);
        gpa.free(self.slots);
        self.* = undefined;
    }
};

/// 1<<reg as a 16-bit register-set bit.
pub fn regBit(r: Reg) u16 {
    return @as(u16, 1) << @intFromEnum(r);
}

/// Allocatable GPRs, in preference order: caller-saved first (no prologue save), then
/// callee-saved (push/pop'd). Excludes rax/rcx (scratch), rbx (completed), rsp, rdi
/// (tags base), rsi (payloads base), and rdx (native result out-param).
const ALLOC_ORDER = [_]Reg{ .r8, .r9, .r10, .r11, .rbp, .r12, .r13, .r14, .r15 };
const CALLEE_SAVED_MASK: u16 = regBit(.rbp) | regBit(.r12) | regBit(.r13) | regBit(.r14) | regBit(.r15);

/// Preference order for Phase-2 invariant array-base homes: `ALLOC_ORDER` reversed,
/// so base pointers claim the callee-saved tail (r15…r12, rbp) the body's linear
/// scan only reaches under register pressure. A low-pressure trace (e.g. nsieve)
/// therefore hoists its array bases without displacing any hot transient into a
/// spill; a high-pressure one simply leaves a base un-hoisted (per-iter load).
const BASE_HOME_ORDER = [_]Reg{ .r15, .r14, .r13, .r12, .rbp, .r11, .r10, .r9, .r8 };

/// Allocatable XMM registers (Phase D float homes/transients). xmm0/xmm1 are the
/// float scratch pair (the SSE analogue of rax/rcx) — never allocated; xmm2..xmm15
/// are the pool. On the SysV/Linux ABI every XMM is *caller-saved*, so a float home
/// needs no prologue save (the `fn([*]Value) callconv(.c)` target owns them all) —
/// hence no XMM analogue of `CALLEE_SAVED_MASK`. The `Reg` indices are reused for
/// XMM (same 0..15 ModRM/REX bits); a `Loc.xmm`/`Place.xmm` tag keeps them disjoint
/// from the identically-indexed GP registers.
const XMM_ALLOC_ORDER = [_]Reg{
    x64.xmm2,  x64.xmm3,  x64.xmm4,  x64.xmm5,  x64.xmm6,  x64.xmm7,
    x64.xmm8,  x64.xmm9,  x64.xmm10, x64.xmm11, x64.xmm12, x64.xmm13,
    x64.xmm14, x64.xmm15,
};
/// The float scratch pair (analogue of rax/rcx), reserved out of the pool above.
const XMM_SCRATCH0: Reg = x64.xmm0;
const XMM_SCRATCH1: Reg = x64.xmm1;

const AnalyzeError = std.mem.Allocator.Error || error{
    /// cut-2 cannot represent this trace (type-instability, etc.). The caller bails;
    /// the cut-1 stack-slot path (or tier-1a) handles it correctly.
    Bail,
};

/// True iff `op` produces a register-resident value that gets its own location (i.e. a
/// transient: konst / arithmetic / compare). slot_loads resolve to a slot home; guards
/// and the loop marker produce no value.
fn isTransient(op: trace.IrOp) bool {
    return switch (op) {
        .konst, .add, .sub, .mul, .div, .band, .bor, .bxor, .shl, .shr, .sar, .neg, .bnot, .eq, .ne, .lt, .le => true,
        // aref materializes idx0 in a register; aload materializes the decoded bool.
        .aref, .aload => true,
        // int_of_float materializes the converted int limit in a register; alen
        // the border int.
        .int_of_float, .alen => true,
        // fsqrt materializes the `@sqrt` result in a float home (XMM/spill);
        // fsin/fcos/pow materialize their `fmath` kernel callout's result
        // likewise.
        .fsqrt, .fsin, .fcos, .pow => true,
        // doc 24: tostr_* materialize the interned `*GcHeader` in a GP home;
        // slen the cp_len int.
        .tostr_int, .tostr_num, .slen => true,
        // href materializes the seeded cell pointer in a register (like aref); hload
        // materializes the decoded scalar field value. hstore/guard_hash are effects.
        .href, .hload => true,
        // grid (doc 14): garow materializes the row base (row0, like aref), gcell the
        // flat cell index, gload the decoded int cell. gstore/the grid guards are
        // effects/value-less.
        .garow, .gcell, .gload => true,
        else => false,
    };
}

/// True iff the op's two operands may be swapped without changing the result. Used
/// both for operand coalescing (either operand's dying register may be reused) and to
/// let the ALU emitter avoid a staging move when the in-register operand is `b`.
fn isCommutative(op: trace.IrOp) bool {
    return switch (op) {
        .add, .mul, .band, .bor, .bxor, .eq, .ne => true,
        else => false, // sub, lt, le are order-sensitive
    };
}

/// The operand refs an instruction reads (matching `proveKinds`/`lower` exactly).
fn operandReads(ins: trace.IrInstr) struct { a: bool, b: bool } {
    return switch (ins.op) {
        .add, .sub, .mul, .div, .pow, .band, .bor, .bxor, .shl, .shr, .sar, .eq, .ne, .lt, .le => .{ .a = true, .b = true },
        .neg, .bnot, .guard_int, .guard_true, .guard_false => .{ .a = true, .b = false },
        // int_of_float reads its sole float operand (a); alen its sole table
        // operand (a).
        .int_of_float, .alen => .{ .a = true, .b = false },
        // aref reads table (a, an invariant home) + index (b). aload/guards reach the
        // table through aref.a, so they read only the aref token (a). astore reads
        // the aref token (a) plus the value to write (b). astore_append is the grow
        // analogue (aref token + value).
        .aref, .astore, .astore_append => .{ .a = true, .b = true },
        .aload, .guard_bounds, .guard_present, .guard_table, .guard_lane => .{ .a = true, .b = false },
        // guard_func reads the callee-snapshot value it identity-checks (a).
        .guard_func => .{ .a = true, .b = false },
        // guard_builtin reads the callee-snapshot native it identity-checks (a);
        // fsqrt/fsin/fcos read their sole float operand (a).
        .guard_builtin, .fsqrt, .fsin, .fcos => .{ .a = true, .b = false },
        // doc 24: tostr_* read their guard-pinned scalar (a); slen its string
        // (a). guard_gc reads NOTHING (`a` unused, aux = the bound A).
        .tostr_int, .tostr_num, .slen => .{ .a = true, .b = false },
        .guard_gc => .{ .a = false, .b = false },
        // guard_fits reads the value it range-checks (a); guard_append reads the aref
        // token (a) and reaches len/cap/hash through aref.a — no second operand.
        .guard_fits, .guard_append => .{ .a = true, .b = false },
        // href reads NEITHER operand: the cell pointer comes from the seeded slab slot
        // (`ins.aux`), not from the table (a) or key konst (b). hload reaches the cell
        // through the href token (a). hstore reads the href token (a) plus the value to
        // write (b). guard_hash reads the href token (a) it is anchored on (lowers to
        // nothing, but operand liveness must keep the href live across it).
        .href => .{ .a = false, .b = false },
        .hload, .guard_hash => .{ .a = true, .b = false },
        .hstore => .{ .a = true, .b = true },
        // grid (doc 14): garow reads table (a) + row (b); gcell reads the garow token
        // (a) + col (b); gstore reads the gcell token (a) + value (b); guard_gcol reads
        // the gcell token (a) + the column ref (b) it range-checks. gload reaches the
        // cell through the gcell token (a). guard_gpresent reads the gcell token (a).
        // guard_grid/guard_stride reach the table through their slot_load operand (a).
        .garow, .gcell, .gstore, .guard_gcol => .{ .a = true, .b = true },
        .gload, .guard_gpresent, .guard_grid, .guard_stride => .{ .a = true, .b = false },
        else => .{ .a = false, .b = false },
    };
}

/// Whether two `Loc`s name the same physical home (register or spill slot).
fn locEql(x: Loc, y: Loc) bool {
    return Place.eql(locToPlace(x), locToPlace(y));
}

/// Ops whose result can be computed *into* a destination home in place (win 2). A
/// compare result is Bool, never carried (type-stability bails), and konst has no
/// operand to anchor the home — so only arithmetic/bitwise + unary qualify.
fn isCoalescibleOp(op: trace.IrOp) bool {
    return switch (op) {
        .add, .sub, .mul, .band, .bor, .bxor, .neg, .bnot => true,
        else => false,
    };
}

/// Find a slot in the list or append a fresh (unclassified) entry; returns its index.
fn findOrAddSlot(slots: *std.ArrayListUnmanaged(SlotInfo), gpa: std.mem.Allocator, slot: u16) !usize {
    for (slots.items, 0..) |s, id| {
        if (s.slot == slot) return id;
    }
    try slots.append(gpa, .{
        .slot = slot,
        .class = undefined,
        .kind = .none,
        .home = undefined,
        .load_ref = -1,
        .store_ref = -1,
        .lane = -1,
        .coalesced = false,
    });
    return slots.items.len - 1;
}

/// See module header. Returns `null` to bail (cut-2 cannot compile this trace); the
/// caller falls back. Runs only on a `proveKinds`-accepted trace, so every op is in the
/// supported subset and `kinds`/`slot_of` are filled.
pub fn analyze(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) ?Alloc {
    return analyzeInner(gpa, t, kinds, slot_of) catch |e| switch (e) {
        error.Bail, error.OutOfMemory => null,
    };
}

fn analyzeInner(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) AnalyzeError!Alloc {
    const n = t.instrs.len;

    // Phase E1/E2: the preheader marker (if any) splits the trace into a run-once
    // region (index < marker) and the per-iteration body. Run-once value refs and
    // every internal φ get a *computed home* — a register/spill held across the whole
    // loop, written once in the prologue (an internal φ also updates at the back-edge),
    // and NEVER flushed at deopt (they back no tier-0 slot; tier-0 recomputes on replay).
    var marker_idx: ?usize = null;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .preheader) {
            marker_idx = i;
            break;
        }
    }

    var slots: std.ArrayListUnmanaged(SlotInfo) = .empty;
    errdefer slots.deinit(gpa);

    const slot_id_of_ref = try gpa.alloc(i32, n);
    errdefer gpa.free(slot_id_of_ref);
    @memset(slot_id_of_ref, -1);

    // --- classification: gather slot_loads, then slot-bound φ writebacks ---
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        const slot: u16 = @intCast(slot_of[i]); // validated >= 0 in proveKinds
        const id = try findOrAddSlot(&slots, gpa, slot);
        slots.items[id].load_ref = @intCast(i);
        slot_id_of_ref[i] = @intCast(id);
    }
    // A slot-bound φ (aux >= 0) is the loop-carried writeback the old exit_store was:
    // `aux` is the tier-0 slot, `b` is the body value carried to the next iteration.
    // Internal φs (aux == PHI_INTERNAL) back no slot — they get a computed home in a
    // later phase, not a slot class here.
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const id = try findOrAddSlot(&slots, gpa, @intCast(ins.aux));
        slots.items[id].store_ref = ins.b;
    }
    for (slots.items) |*s| {
        const loaded = s.load_ref >= 0;
        const stored = s.store_ref >= 0;
        if (loaded and stored) {
            s.class = .carried;
            // A carried slot is treated as ONE boxable scalar kind end-to-end: the
            // prologue tag-checks it, the body keeps it in a same-class home, and the
            // deopt flush re-boxes it with that tag. Phase D widens the admissible set
            // from int to {int, float}; bool/ptr/aref carried still bail.
            const lk = kinds[@intCast(s.load_ref)];
            const sk = kinds[@intCast(s.store_ref)];
            if (lk == .ptr and (sk == .ptr or sk == .heap)) {
                // [doc 22 §A.1] Carried-heap: a guard_table-covered table slot whose φ
                // writeback is itself a table (`bi = b[i]` — a VALUE_LANE aload result,
                // or another table slot_load). The slot's kind becomes `.heap`, NOT
                // `.ptr`: every `.ptr`-keyed analysis and prologue hoist (lane/grid
                // pinning, C2 type+metatable checks, array-base homes) then skips it by
                // kind mismatch, because those entry-time facts describe only the first
                // iteration's table. The home is a GP register/spill holding the current
                // `*GcHeader`, refreshed by the back-edge φ shuffle; in-body table facts
                // come from the DYNAMIC forms (per-iteration guard_table/guard_hash, the
                // resolveHashCell href callout) via `isCarriedHeapRoot`, and both the
                // entry tag-check and every flush use TAG_HEAP. Structural bails below
                // refuse anything this cut cannot check per-iteration (array/grid roots).
                s.kind = .heap;
            } else {
                // [RV-4 / review P0] The *load* class fixes the prologue tag-check and the
                // home's register class. Outside the carried-heap case above, a `.ptr`
                // load carried would skip the table/lane checks and reinterpret an
                // int/float payload as a `*GcHeader` → type confusion; only a boxable
                // scalar may be carried.
                if (lk != .int and lk != .float) return error.Bail;
                // [RV-3] type-stability: the store class must match the load class. A slot
                // loaded int but stored float (or vice versa) would pass our once-hoisted
                // prologue guard forever while the oracle re-checks every iteration and
                // deopts — and the home's register class (GP vs XMM) would be wrong. Bail.
                if (sk != lk) return error.Bail;
                s.kind = lk;
            }
        } else if (loaded) {
            s.class = .invariant;
            // int OR ptr (a guard_table-covered table slot, read-only loop-invariant).
            s.kind = kinds[@intCast(s.load_ref)];
        } else {
            s.class = .write_only;
            s.kind = kinds[@intCast(s.store_ref)];
        }
    }
    // [doc 22 §A.1, fail closed] Structural bails for carried-heap slots. The
    // `.ptr`-keyed lane/grid analyses below skip a carried-heap slot by kind
    // mismatch — which means an aref/garow rooted at one would otherwise compile
    // SILENTLY with no lane pin and a first-iteration-only base. Refuse instead:
    // this cut supports exactly the hash-path ops (href/guard_table/guard_hash),
    // whose dynamic in-body forms re-check the CURRENT table each iteration. And
    // those dynamic forms are only per-iteration if they sit in the body — a
    // placement before the preheader marker would run once, checking iteration
    // 1's table only, so that too is refused.
    for (slots.items) |s| {
        if (s.class != .carried or s.kind != .heap) continue;
        const lr: u16 = @intCast(s.load_ref);
        const ms: usize = marker_idx orelse 0;
        for (t.instrs, 0..) |g, gi| {
            switch (g.op) {
                // No entry-hoisted per-table fact may root at a per-iteration table.
                .aref, .garow, .guard_lane, .guard_grid, .guard_stride => {
                    if (g.a == lr) return error.Bail;
                },
                .guard_table, .href => if (g.a == lr and gi < ms) return error.Bail,
                .guard_hash => if (t.instrs[g.a].a == lr and gi < ms) return error.Bail,
                else => {},
            }
        }
    }
    // [doc 22 §A.2] Heap-φ GC admission: a `.heap`-kind slot (carried OR
    // write-only) keeps a raw `*GcHeader` unrooted in a register/spill across the
    // body, sound only while no body callout can trigger a collection. Check every
    // callout against the HelperCaps table; refuse the trace if any may GC.
    {
        var has_heap_phi = false;
        for (slots.items) |s| {
            if (s.kind == .heap) {
                has_heap_phi = true;
                break;
            }
        }
        if (has_heap_phi) {
            for (0..n) |ci| {
                if (bodyCalloutOf(t, kinds, slots.items, slot_id_of_ref, ci)) |c| {
                    if (calloutMayCollect(c)) return error.Bail;
                }
            }
        }
    }
    // A `.ptr` (table) invariant slot accessed as an ARRAY needs the lane its
    // `guard_lane` pins, so the prologue can check it once. Locate the guard_lane
    // covering the slot_load. A table accessed only via the HASH part (H1: `href`,
    // no `aref`) carries no array lane — the recorder emits `guard_table` but no
    // `guard_lane` — so `s.lane` stays -1 and the prologue skips the lane check (the
    // data/present/len array-base hoist is likewise keyed on aref usage, so a
    // hash-only slot gets none). A table used BOTH ways has the guard_lane and is
    // pinned normally. The table-type + metatable prologue checks cover the hash
    // path's validity regardless of lane.
    for (slots.items) |*s| {
        if (s.kind != .ptr) continue;
        if (s.class == .write_only) continue;
        const lr: u16 = @intCast(s.load_ref);
        // An aref on this slot REQUIRES a guard_lane (the recorder always emits both);
        // a malformed trace with array access but no lane would miscompile, so track it.
        var has_aref = false;
        for (t.instrs) |g| {
            if (g.op == .aref and g.a == lr) has_aref = true;
            if (g.op == .guard_lane and g.a == lr) s.lane = g.aux;
        }
        if (has_aref and s.lane < 0) return error.Bail; // array access without a pinned lane
    }
    // A `.ptr` table accessed as a GRID (doc 14) carries no `guard_lane`; instead a
    // `guard_grid` pins `lane == .grid ∧ grid_elem` and a `guard_stride` pins the row
    // width. Tag the slot with the meta-lane GRID_LANE plus the recorded grid_elem and
    // stride so the prologue can verify all three once per entry. A table is a grid OR
    // a scalar array at any instant — never both — so a slot already carrying a scalar
    // lane (set above) here is malformed; bail rather than miscompile.
    for (slots.items) |*s| {
        if (s.kind != .ptr) continue;
        if (s.class == .write_only) continue;
        const lr: u16 = @intCast(s.load_ref);
        var has_garow = false;
        var ge: i32 = -1;
        var gs: i32 = -1;
        for (t.instrs) |g| {
            if (g.op == .garow and g.a == lr) has_garow = true;
            if (g.op == .guard_grid and g.a == lr) ge = g.aux;
            if (g.op == .guard_stride and g.a == lr) gs = g.aux;
        }
        if (!has_garow) continue;
        if (s.lane >= 0 or ge < 0 or gs < 0) return error.Bail;
        s.lane = GRID_LANE;
        s.grid_elem = ge;
        s.grid_stride = gs;
    }
    // A `.func` (cross-frame callee snapshot) invariant slot carries the recorded
    // `Proto.id` from its covering `guard_func`, checked once in the prologue (the
    // upvalue/global cell is re-resolved + re-seeded each entry, so it cannot change
    // within a native run). Locate the guard_func and stash its id on the slot.
    for (slots.items) |*s| {
        if (s.kind != .func) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_func and g.a == lr) {
                if (found and @as(u32, @bitCast(g.aux)) != s.func_id) {
                    // Two guard_funcs on one snapshot with *different* recorded ids:
                    // the prologue checks one id, but the oracle re-checks each and
                    // would side-exit on the second — a divergence. The recorder never
                    // emits this (dedup → one synthetic slot → one resolved closure →
                    // one id), so it can only arise malformed. Bail, don't miscompile.
                    return error.Bail;
                }
                s.func_id = @bitCast(g.aux);
                found = true;
            }
        }
        // proveKinds only set .func via a guard_func, so one always exists.
        // Defensive: bail rather than miscompile.
        if (!found) return error.Bail;
    }
    // A `.native` (pure-builtin callee snapshot) invariant slot carries the recorded
    // `RecordedBuiltin` ordinal from its covering `guard_builtin`, checked once in the
    // prologue (the upvalue/global cell is re-resolved + re-seeded each entry, so it
    // cannot change within a native run). Locate the guard_builtin and stash its tag.
    for (slots.items) |*s| {
        if (s.kind != .native) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_builtin and g.a == lr) {
                if (found and g.aux != s.recorded_tag) {
                    // Two guard_builtins on one snapshot with *different* recorded tags:
                    // the prologue checks one, but the oracle re-checks each and would
                    // side-exit on the second — a divergence. The recorder never emits
                    // this (one seeded callee → one tag), so it can only arise malformed.
                    return error.Bail;
                }
                s.recorded_tag = g.aux;
                found = true;
            }
        }
        // proveKinds only set .native via a guard_builtin, so one always exists.
        if (!found) return error.Bail;
    }

    // --- liveness: last_use, single backward pass; carried/write store_refs live to the marker ---
    const last_use = try gpa.alloc(u32, n);
    errdefer gpa.free(last_use);
    for (last_use, 0..) |*lu, i| lu.* = @intCast(i); // live at least at its own def
    {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const ins = t.instrs[i];
            const rd = operandReads(ins);
            if (rd.a and last_use[ins.a] < i) last_use[ins.a] = @intCast(i);
            if (rd.b and last_use[ins.b] < i) last_use[ins.b] = @intCast(i);
        }
    }
    // The value feeding ANY φ's back-edge update (slot-bound OR internal) must survive
    // to the shuffle/commit at the terminal `loop` (operandReads does not count φ.b, so
    // this explicit extension is its only liveness — exactly as the old exit_store had).
    for (t.instrs) |ins| {
        if (ins.op != .phi) continue;
        if (last_use[ins.b] < n - 1) last_use[ins.b] = @intCast(n - 1);
    }
    // A dynamically-rooted href reads ins.a (the per-iteration *GcHeader — a
    // VALUE_LANE aload result, or a carried-heap slot_load) but
    // `operandReads(.href)` returns {false, false} (the loop-invariant path reads
    // from the seeded slab slot, not from operand refs). Extend the root's
    // liveness here so it survives to the href and the guard_hash that follows it.
    // guard_hash also reads href_ins.a (the same root) to check hash population.
    // (For a carried-heap slot_load the extension is a no-op — its loc IS the
    // pinned slot home — but routing both roots through the one predicate keeps
    // analysis and lowering deciding identically.)
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .href and isDynTableRoot(kinds, slots.items, slot_id_of_ref, ins.a)) {
            if (last_use[ins.a] < i) last_use[ins.a] = @intCast(i);
        }
        if (ins.op == .guard_hash) {
            const href_ins = t.instrs[ins.a];
            if (isDynTableRoot(kinds, slots.items, slot_id_of_ref, href_ins.a)) {
                if (last_use[href_ins.a] < i) last_use[href_ins.a] = @intCast(i);
            }
        }
    }

    // --- allocation: pin slot homes, then linear-scan the transients ---
    const loc = try gpa.alloc(Loc, n);
    errdefer gpa.free(loc);
    for (loc) |*l| l.* = .{ .spill = 0 }; // placeholder for value-less refs (guards/loop)

    var free: u16 = comptime blk: {
        var m: u16 = 0;
        for (ALLOC_ORDER) |r| m |= regBit(r);
        break :blk m;
    };
    // The disjoint XMM pool (Phase D). Bits are the same 0..15 index space; a float
    // home/transient draws from here, an int/bool/ptr from `free`.
    var free_xmm: u16 = comptime blk: {
        var m: u16 = 0;
        for (XMM_ALLOC_ORDER) |r| m |= regBit(r);
        break :blk m;
    };
    var spill_count: u32 = 0;
    var used_callee: u16 = 0;
    var home_reg_mask: u16 = 0;
    var home_xmm_mask: u16 = 0;

    for (slots.items) |*s| {
        if (s.class == .write_only) continue;
        if (s.kind == .float) {
            // Float home: draw from the XMM pool, else a shared 8-byte spill cell.
            if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                s.home = .{ .xmm = r };
                home_xmm_mask |= regBit(r);
            } else {
                s.home = .{ .spill = spill_count };
                spill_count += 1;
            }
        } else if (pickReg(&free)) |r| {
            s.home = .{ .reg = r };
            home_reg_mask |= regBit(r);
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
        } else {
            s.home = .{ .spill = spill_count };
            spill_count += 1;
        }
    }
    // Resolve slot_load refs to their slot home.
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        loc[i] = slots.items[@intCast(slot_id_of_ref[i])].home;
    }

    // --- computed homes (Phase E1/E2) ---
    // Pin a persistent home for every run-once value (preheader transient) and every
    // internal φ, drawing from the same pools as slot homes (so their registers are
    // reserved out of the body linear scan). The scan then skips these refs. A φ's home
    // is updated at the back-edge; a preheader value's is written once in the prologue.
    const is_computed = try gpa.alloc(bool, n);
    defer gpa.free(is_computed);
    @memset(is_computed, false);
    {
        const ms = marker_idx orelse 0;
        for (t.instrs, 0..) |ins, i| {
            const is_pre_val = marker_idx != null and i < ms and isTransient(ins.op);
            const is_int_phi = ins.op == .phi and ins.aux == trace.PHI_INTERNAL;
            if (!is_pre_val and !is_int_phi) continue;
            if (is_int_phi) {
                // The init must be a run-once value (a < marker), so the prologue
                // init-move reads a home already materialized before `loop_top`.
                if (marker_idx == null or ins.a >= ms) return error.Bail;
            }
            switch (kinds[i]) {
                .float => {
                    if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                        loc[i] = .{ .xmm = r };
                        home_xmm_mask |= regBit(r);
                    } else {
                        loc[i] = .{ .spill = spill_count };
                        spill_count += 1;
                    }
                },
                .int, .bool => {
                    if (pickReg(&free)) |r| {
                        loc[i] = .{ .reg = r };
                        home_reg_mask |= regBit(r);
                        used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                    } else {
                        loc[i] = .{ .spill = spill_count };
                        spill_count += 1;
                    }
                },
                // A computed home must carry a boxable scalar; anything else (a `.ptr`/
                // `.aref` hoisted into the preheader, or a mis-typed φ) cannot be homed.
                else => return error.Bail,
            }
            is_computed[i] = true;
        }
    }

    // --- Phase 2: reserve invariant array-base homes ---------------------------------
    // For each `.ptr` slot used as an `aref.a`, the array `data`/`present` pointers and
    // `len` are loop-invariant across a native run (B5: the path never reallocates or
    // lane-widens — `guard_fits` side-exits first). Materialize each *once* in the
    // prologue into a dedicated register instead of re-loading `[tbreg+field]` every
    // iteration. Only the fields the body actually reads are reserved, drawn from the
    // callee-saved tail (`BASE_HOME_ORDER`) so a low-pressure trace hoists for free
    // while a high-pressure one falls back to the per-iteration load (a `null` home).
    // Reserved here — after computed homes, before coalescing + the body linear scan —
    // so neither reuses these registers; folded into `home_reg_mask`/`used_callee` so
    // the disjointness assertions and prologue push/pop already cover them.
    {
        const ns = slots.items.len;
        const need_data = try gpa.alloc(bool, ns);
        defer gpa.free(need_data);
        const need_present = try gpa.alloc(bool, ns);
        defer gpa.free(need_present);
        const need_len = try gpa.alloc(bool, ns);
        defer gpa.free(need_len);
        @memset(need_data, false);
        @memset(need_present, false);
        @memset(need_len, false);

        // Which array base each consuming op needs, attributed to the `.ptr` slot its
        // address operand roots at. (guard_bounds → len; bool guard_present/aload/astore
        // → data; int guard_present → present; int astore/astore_append → data + present.)
        // astore_append also bumps len in memory, but via a re-fetched table pointer in
        // rax (no len_home for an append trace), so it needs no len reservation here.
        //
        // A scalar array op roots ONE hop (aref.a == table slot_load); a grid op
        // (doc 14) roots TWO hops (gcell.a == garow, garow.a == table slot_load). Its
        // grid guard_bounds is on the GAROW, whose `.a` is already the table slot_load,
        // so it falls into the one-hop arm below unchanged. The cell ops (gload/gstore/
        // guard_gpresent) carry the gcell and need the extra hop.
        for (t.instrs) |ins| {
            var sid_signed: i32 = -1;
            var is_bool = false;
            switch (ins.op) {
                .guard_bounds, .guard_present, .aload, .astore, .astore_append => {
                    const aref_ins = t.instrs[@intCast(ins.a)];
                    sid_signed = slot_id_of_ref[aref_ins.a];
                    is_bool = aref_ins.aux == BOOL_LANE;
                },
                .gload, .gstore, .guard_gpresent => {
                    const gcell_ins = t.instrs[@intCast(ins.a)];
                    const garow_ins = t.instrs[@intCast(gcell_ins.a)];
                    sid_signed = slot_id_of_ref[garow_ins.a]; // two hops to the table slot
                },
                else => continue,
            }
            if (sid_signed < 0) continue; // table operand isn't a slot home — leave per-iter
            const sid: usize = @intCast(sid_signed);
            switch (ins.op) {
                .guard_bounds => need_len[sid] = true,
                .guard_present => if (is_bool) {
                    need_data[sid] = true;
                } else {
                    need_present[sid] = true;
                },
                .aload => need_data[sid] = true,
                .astore, .astore_append => {
                    need_data[sid] = true;
                    if (!is_bool) need_present[sid] = true;
                },
                // Grid cells (doc 14) are int-lane only in this cut: a load needs the
                // data base; a store needs data + the presence bitmap; a presence guard
                // needs only the bitmap.
                .gload => need_data[sid] = true,
                .guard_gpresent => need_present[sid] = true,
                .gstore => {
                    need_data[sid] = true;
                    need_present[sid] = true;
                },
                else => unreachable,
            }
        }

        // An astore_append bumps `len` in memory only (no len_home writeback — see the
        // lowering), so a `len` register hoisted by a sibling guard_bounds on the same
        // table would go stale the moment the append commits. Don't hoist `len` for any
        // trace that contains an astore_append; guard_bounds then reloads `len` from the
        // table each iteration (always the committed value). A pure append fill has no
        // guard_bounds, so this costs it nothing.
        var has_append = false;
        for (t.instrs) |ins| {
            if (ins.op == .astore_append) {
                has_append = true;
                break;
            }
        }
        for (slots.items, 0..) |*s, sid| {
            if (s.class == .write_only) continue;
            if (need_data[sid]) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.data_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
            if (need_present[sid]) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.present_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
            if (need_len[sid] and !has_append) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.len_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
        }
    }

    // --- home coalescing (win 2): allocate a carried slot's store_ref transient INTO
    // the slot's home, so the op updates the home in place AND the back-edge shuffle
    // self-elides. Gated by a safety predicate (cuts-2's single-snapshot model assumes
    // homes are written only at the back-edge; an in-place update breaks that unless no
    // side-exit follows it). Must run BEFORE the linear scan so it sees loc[j] fixed.
    const is_coalesced_home = try gpa.alloc(bool, n);
    defer gpa.free(is_coalesced_home);
    @memset(is_coalesced_home, false);
    {
        // The last side-exiting instruction. An in-place home update that PRECEDES
        // any mid-body side-exit would be committed by the deopt flush even though
        // the iteration aborted — so home coalescing must be blocked past the last
        // of them. `opMayExitInBody` is the closed inventory of every exit the body
        // emitter can produce (the hoisted guards — guard_int/guard_lane and the
        // `.ptr` forms of guard_table/guard_hash — never exit mid-body; their
        // dynamic per-iteration forms and the href callout DO). Trace order is
        // straight-line, so index order == dominance: "after" == strictly greater
        // index.
        var last_body_guard: i64 = -1;
        for (0..n) |idx| {
            if (opMayExitInBody(t, kinds, slots.items, slot_id_of_ref, idx)) last_body_guard = @intCast(idx);
        }
        for (slots.items, 0..) |*s, sid| {
            if (s.class != .carried) continue;
            // [Phase D] Float coalescing is disabled in the first cut: SSE has no
            // `op [mem],xmm` store form and a float op always materializes into a
            // scratch XMM before writing its home, so there is no in-place win to
            // capture. Skip — the back-edge shuffle handles the float carry.
            if (s.kind == .float) continue;
            const j: usize = @intCast(s.store_ref);
            const def = t.instrs[j];
            if (!isCoalescibleOp(def.op)) continue;
            // (1) no side-exit follows the in-place update.
            if (@as(i64, @intCast(j)) <= last_body_guard) continue;
            // [RV] imul has no [mem],reg store form → a spilled-home mul can't go in place.
            if (def.op == .mul and s.home != .reg) continue;
            // (2) S's OLD value is fully dead by j: no slot_load(S) ref is read after j.
            // (The operand read at j itself has last_use == j ≤ j, which is fine.)
            var old_live = false;
            for (0..n) |r2| {
                if (slot_id_of_ref[r2] == @as(i32, @intCast(sid)) and last_use[r2] > j) {
                    old_live = true;
                    break;
                }
            }
            if (old_live) continue;
            // (3) home(S) holds an operand at the op: left operand is home (any op), or a
            // commutative op's right operand is home. Unary requires its sole operand.
            const a_home = operandReads(def).a and locEql(loc[def.a], s.home);
            const b_home = operandReads(def).b and locEql(loc[def.b], s.home);
            const op_ok = a_home or (b_home and isCommutative(def.op));
            if (!op_ok) continue;
            // Coalesce: pin the transient into the home, mark the slot, and extend the
            // transient's live range to the loop marker so the scan never frees the home
            // [RV: the coalesced value IS snapshot state from j onward].
            loc[j] = s.home;
            s.coalesced = true;
            is_coalesced_home[j] = true;
            if (last_use[j] < n - 1) last_use[j] = @intCast(n - 1);
        }
    }

    // Linear scan over transient defs in index order; active set ≤ pool size. A
    // second, parallel active set tracks the XMM pool (float transients) — the two
    // register files expire independently into `free` / `free_xmm`.
    var active: [ALLOC_ORDER.len]struct { reg: Reg, last: u32 } = undefined;
    var active_len: usize = 0;
    var active_xmm: [XMM_ALLOC_ORDER.len]struct { reg: Reg, last: u32 } = undefined;
    var active_xmm_len: usize = 0;
    for (t.instrs, 0..) |ins, i| {
        if (!isTransient(ins.op)) continue;
        // expire GP transients whose last use precedes i
        var w: usize = 0;
        for (active[0..active_len]) |e| {
            if (e.last < i) {
                free |= regBit(e.reg);
            } else {
                active[w] = e;
                w += 1;
            }
        }
        active_len = w;
        // expire XMM transients likewise
        var wx: usize = 0;
        for (active_xmm[0..active_xmm_len]) |e| {
            if (e.last < i) {
                free_xmm |= regBit(e.reg);
            } else {
                active_xmm[wx] = e;
                wx += 1;
            }
        }
        active_xmm_len = wx;

        // A win-2 transient is already pinned to its slot home — never reallocate it.
        if (is_coalesced_home[i]) continue;
        // A run-once preheader value already has a computed home (pinned above, its
        // register reserved out of the pool) — never reallocate or expire it.
        if (is_computed[i]) continue;

        // [Phase D] A float transient draws from the XMM pool. Operand coalescing
        // (win 1) is disabled for floats (the value always lands in a scratch XMM
        // first — see the win-2 skip above), so allocate a fresh XMM or a spill cell.
        if (kinds[i] == .float) {
            if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                loc[i] = .{ .xmm = r };
                active_xmm[active_xmm_len] = .{ .reg = r, .last = last_use[i] };
                active_xmm_len += 1;
            } else {
                loc[i] = .{ .spill = spill_count };
                spill_count += 1;
            }
            continue;
        }

        // --- operand coalescing (win 1): reuse a *dying* operand's register for the
        // result, emitting an in-place `op dst, b` instead of staging through rax.
        // The operand must (a) live in a register, (b) NOT be a slot home — reusing a
        // home would clobber a loop-carried value mid-iteration [RV: location-based,
        // not slot_id<0, so it stays correct once win-2 puts transients in homes] —
        // and (c) die exactly here (last_use == i). For commutative ops either operand
        // qualifies; otherwise only `a` (the destructive-write target).
        const rd = operandReads(ins);
        var coalesced: ?Reg = null;
        const cands = [2]struct { ref: usize, ok: bool }{
            .{ .ref = ins.a, .ok = rd.a },
            .{ .ref = ins.b, .ok = rd.b and isCommutative(ins.op) },
        };
        for (cands) |c| {
            if (!c.ok) continue;
            if (loc[c.ref] != .reg) continue;
            const r = loc[c.ref].reg;
            if (home_reg_mask & regBit(r) != 0) continue;
            if (last_use[c.ref] != i) continue;
            // Repurpose the operand's active entry for the result's live range.
            for (active[0..active_len]) |*e| {
                if (e.reg == r) {
                    e.last = last_use[i];
                    coalesced = r;
                    break;
                }
            }
            if (coalesced != null) break;
        }
        if (coalesced) |r| {
            loc[i] = .{ .reg = r };
        } else if (pickReg(&free)) |r| {
            loc[i] = .{ .reg = r };
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
            active[active_len] = .{ .reg = r, .last = last_use[i] };
            active_len += 1;
        } else {
            loc[i] = .{ .spill = spill_count };
            spill_count += 1;
        }
    }

    // --- invariant assertions (compiled out in release; the structural guardrail) ---
    if (std.debug.runtime_safety) {
        // homes are register-disjoint, tracked per register file (a GP reg and the
        // XMM of the same 0..15 index are physically distinct → never alias).
        var seen: u16 = 0;
        var seen_xmm: u16 = 0;
        for (slots.items) |s| {
            if (s.class == .write_only) continue;
            switch (s.home) {
                .reg => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                },
                .xmm => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen_xmm & b == 0);
                    seen_xmm |= b;
                },
                .spill => {},
            }
        }
        // Computed homes (preheader values + internal φs) are also register-disjoint
        // from slot homes and from each other (drawn from the same pools after slots).
        for (0..n) |i| {
            if (!is_computed[i]) continue;
            switch (loc[i]) {
                .reg => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                },
                .xmm => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen_xmm & b == 0);
                    seen_xmm |= b;
                },
                .spill => {},
            }
        }
        // [Phase 2] Invariant array-base homes are register-disjoint from slot homes,
        // computed homes, and each other (drawn from `free` after both, each pick
        // clearing its bit). They are GP-only and folded into `home_reg_mask`.
        for (slots.items) |s| {
            for ([_]?Reg{ s.data_home, s.present_home, s.len_home }) |maybe| {
                if (maybe) |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                    std.debug.assert(home_reg_mask & b != 0); // must be reserved out of the body
                }
            }
        }
        // no transient register aliases a home register (per file) — except a win-2
        // transient (pinned INTO its slot's home) or a computed home (pinned above).
        for (t.instrs, 0..) |ins, i| {
            if (!isTransient(ins.op)) continue;
            if (is_coalesced_home[i] or is_computed[i]) continue;
            switch (loc[i]) {
                .reg => |r| std.debug.assert(home_reg_mask & regBit(r) == 0),
                .xmm => |r| std.debug.assert(home_xmm_mask & regBit(r) == 0),
                .spill => {},
            }
        }
        // every slot-bound φ's back-edge update ref has a concrete location (always does)
        for (t.instrs) |ins| {
            if (ins.op != .phi or ins.aux < 0) continue;
            const l = loc[ins.b];
            std.debug.assert(l == .reg or l == .xmm or l == .spill);
        }
    }

    // --- callout save area (any BodyCallout in the body) ---
    // If any instruction in this trace lowers to a mid-body callout (a
    // dynamically-rooted href's `resolveHashCell`, an fsin/fcos `fmath` kernel
    // call, …), the callout clobbers all SysV caller-saved registers. Reserve
    // frame slots to save/restore live homes. The predicate is `bodyCalloutOf`
    // itself — the SAME mapping the lowering and the heap-φ GC audit dispatch
    // on — so a new callout can never silently miss its save area.
    var callout_save_base: u32 = 0;
    var callout_save_count: u32 = 0;
    {
        var needs_callout = false;
        for (t.instrs, 0..) |_, ci| {
            if (bodyCalloutOf(t, kinds, slots.items, slot_id_of_ref, ci) != null) {
                needs_callout = true;
                break;
            }
        }
        if (needs_callout) {
            callout_save_base = spill_count;
            // The callout clobbers ALL SysV caller-saved registers. We must save
            // not just slot homes but also transient registers that may be live
            // across the callout (e.g. a float hload result from a prior field
            // access in the same iteration, still alive at the second href).
            // Simplest correct approach: save ALL caller-saved GP and XMM
            // allocatable registers unconditionally, plus rdi/rsi (SoA bases)
            // and rdx (*NativeResult out-param, used at side-exits).
            var count: u32 = 3; // rdi + rsi + rdx
            // All allocatable caller-saved GPRs: r8, r9, r10, r11.
            count += 4;
            // All allocatable XMMs: xmm2–xmm15 (XMM_ALLOC_ORDER, 14 regs).
            count += XMM_ALLOC_ORDER.len;
            callout_save_count = count;
            // +1 for the alignment padding slot: the JIT body runs with
            // rsp % 16 == 8 (correct for the JIT's own return convention but
            // wrong for an outgoing SysV call). `emitHrefCallout` does
            // `sub rsp, 8` before the call and `add rsp, 8` after — the
            // extra slot ensures this doesn't underflow the frame.
            spill_count += count + 1;
        }
    }

    return .{
        .loc = loc,
        .last_use = last_use,
        .slot_id_of_ref = slot_id_of_ref,
        .slots = try slots.toOwnedSlice(gpa),
        .spill_count = spill_count,
        .used_callee_saved = used_callee,
        .callout_save_base = callout_save_base,
        .callout_save_count = callout_save_count,
    };
}

/// Pop the first free register in `ALLOC_ORDER` preference, clearing its bit. Null if none.
fn pickReg(free: *u16) ?Reg {
    return pickRegFrom(free, &ALLOC_ORDER);
}

/// Pop the first free register in the given preference order, clearing its bit. Null
/// if none. Shared by the GP pool (`ALLOC_ORDER`) and the XMM pool (`XMM_ALLOC_ORDER`).
fn pickRegFrom(free: *u16, order: []const Reg) ?Reg {
    for (order) |r| {
        const b = regBit(r);
        if (free.* & b != 0) {
            free.* &= ~b;
            return r;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// cut-2: lowering helpers — a `Place` is where a value sits (a register or a frame
// slot at an rsp displacement). The body keeps slot homes in registers and transients
// in frame slots (commit B); commit C moves transients to registers too.
// ---------------------------------------------------------------------------

const Place = union(enum) {
    reg: Reg, // a general-purpose register
    xmm: Reg, // an XMM register (float). Distinct tag → a GP reg and the XMM of the
    // same 0..15 index never compare equal (they are physically distinct registers).
    mem: i32, // rsp-relative byte displacement (kind-agnostic 8-B cell)

    fn eql(x: Place, y: Place) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .reg => x.reg == y.reg,
            .xmm => x.xmm == y.xmm,
            .mem => x.mem == y.mem,
        };
    }
};

/// Map an allocation `Loc` to a `Place`: a register stays a register; a spill slot
/// becomes a frame displacement `[rsp + idx*8]`.
fn locToPlace(l: Loc) Place {
    return switch (l) {
        .reg => |r| .{ .reg = r },
        .xmm => |r| .{ .xmm = r },
        .spill => |idx| .{ .mem = @as(i32, @intCast(idx)) * 8 },
    };
}

/// The home of a carried/invariant slot: its assigned register or spill slot.
fn slotHomePlace(s: SlotInfo) Place {
    return locToPlace(s.home);
}

/// Where ref `r`'s value lives — its linear-scan-assigned register or frame slot.
/// A `slot_load` ref resolves to its slot home (its `loc` was set to that home).
fn placeOfRef(alloc: *const Alloc, r: usize) Place {
    return locToPlace(alloc.loc[r]);
}

fn placeToReg(a: *x64.Assembler, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| if (r != dst) try a.movRegReg(dst, r),
        .mem => |d| try a.movRegMem(dst, .rsp, d),
        .xmm => unreachable, // a GP destination never receives a float source
    }
}

fn regToPlace(a: *x64.Assembler, dst: Place, src: Reg) !void {
    switch (dst) {
        .reg => |r| if (r != src) try a.movRegReg(r, src),
        .mem => |d| try a.movMemReg(.rsp, d, src),
        .xmm => unreachable, // a GP source never targets a float home
    }
}

/// Ensure a ref's value is in a CPU register usable as a memory *base*, returning
/// that register. A register home is used directly; a spilled home is loaded into
/// `scratch` (rax). Used for the invariant table pointer at each array op.
fn refBaseReg(a: *x64.Assembler, alloc: *const Alloc, ref: usize, scratch: Reg) !Reg {
    switch (placeOfRef(alloc, ref)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
        .xmm => unreachable, // array-path operands are int/ptr, never float
    }
}

/// [Phase 2] The register holding an invariant array base pointer (`data` or
/// `present`) for the table referenced by `aref_a` (an aref token's table operand).
/// If `analyze` hoisted that field into a dedicated register home, return it directly
/// — no memory traffic. Otherwise fall back to the per-iteration load: fetch the table
/// pointer (its home, or `scratch`) and load `[tbreg + array_base + field]` into
/// `scratch`, returning `scratch`. Either way the returned register is a valid memory
/// base for the subsequent SIB element access. (`len` is a compare operand, handled
/// inline at `guard_bounds`.)
const ArrayBaseField = enum { data, present };
fn arrayFieldReg(a: *x64.Assembler, alloc: *const Alloc, aref_a: usize, field: ArrayBaseField, scratch: Reg) !Reg {
    const sid = alloc.slot_id_of_ref[aref_a];
    if (sid >= 0) {
        const s = alloc.slots[@intCast(sid)];
        const home: ?Reg = switch (field) {
            .data => s.data_home,
            .present => s.present_home,
        };
        if (home) |r| return r; // hoisted — already in a register, no load
    }
    const tb = try refBaseReg(a, alloc, aref_a, scratch);
    const fieldoff: i32 = switch (field) {
        .data => ArrLayout.data,
        .present => ArrLayout.present,
    };
    try a.movRegMem(scratch, tb, ArrLayout.array_base + fieldoff);
    return scratch;
}

/// Like `refBaseReg`, but for a slot's home `Place` (used for the prologue table
/// checks, where the slot is referenced by its home, not an SSA ref).
fn refHomeBaseReg(a: *x64.Assembler, s: SlotInfo, scratch: Reg) !Reg {
    switch (slotHomePlace(s)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
        .xmm => unreachable, // only `.ptr`/`.func`/`.native` heap-pointer slots reach here, never float
    }
}

/// Emit `dst <op> src` where `dst` is a register and `src` is a Place — reg→reg ALU
/// or the load-form `op r64, [mem]` when the operand is spilled (avoids staging it
/// through scratch). Only binary arithmetic/bitwise ops reach here.
fn emitAluRegPlace(a: *x64.Assembler, op: trace.IrOp, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| switch (op) {
            .add => try a.addRegReg(dst, r),
            .sub => try a.subRegReg(dst, r),
            .mul => try a.imulRegReg(dst, r),
            .band => try a.andRegReg(dst, r),
            .bor => try a.orRegReg(dst, r),
            .bxor => try a.xorRegReg(dst, r),
            else => unreachable,
        },
        .mem => |d| switch (op) {
            .add => try a.addRegMem(dst, .rsp, d),
            .sub => try a.subRegMem(dst, .rsp, d),
            .mul => try a.imulRegMem(dst, .rsp, d),
            .band => try a.andRegMem(dst, .rsp, d),
            .bor => try a.orRegMem(dst, .rsp, d),
            .bxor => try a.xorRegMem(dst, .rsp, d),
            else => unreachable,
        },
        .xmm => unreachable, // integer ALU never reads a float operand
    }
}

/// Lower a binary ALU op `dst = pa <op> pb` reading operands in place.
///   - register dst: keep `pa` in dst (elided when operand/home-coalesced so `pa==dst`)
///     then `op dst, pb`; a commutative op may instead keep the in-register `pb`.
///   - spilled dst: in-place store form `op [dst], pb_reg` when `pa==dst` (the win-2
///     coalesced home), else stage `a` in rax and write back. imul has no store form,
///     so a spilled in-place `mul` is never produced (analyze keeps such homes in regs).
fn emitBinAlu(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    switch (dst) {
        .reg => |R| {
            if (pa == .reg and pa.reg == R) {
                try emitAluRegPlace(a, op, R, pb);
            } else if (isCommutative(op) and pb == .reg and pb.reg == R) {
                try emitAluRegPlace(a, op, R, pa);
            } else {
                // R holds neither operand: materialize `a`, then `op R, b`. For
                // non-commutative ops `pb.reg == R` is impossible (a still-live operand
                // keeps its register), so the staging move never clobbers `b`.
                try placeToReg(a, R, pa);
                try emitAluRegPlace(a, op, R, pb);
            }
        },
        .mem => |D| {
            if (Place.eql(pa, dst)) {
                // In-place spilled home (win 2): `op [dst], b`. Load b to rcx if spilled.
                std.debug.assert(op != .mul); // no imul store form
                const src_reg: Reg = switch (pb) {
                    .reg => |r| r,
                    .mem => |bd| blk: {
                        try a.movRegMem(.rcx, .rsp, bd);
                        break :blk .rcx;
                    },
                    .xmm => unreachable,
                };
                switch (op) {
                    .add => try a.addMemReg(.rsp, D, src_reg),
                    .sub => try a.subMemReg(.rsp, D, src_reg),
                    .band => try a.andMemReg(.rsp, D, src_reg),
                    .bor => try a.orMemReg(.rsp, D, src_reg),
                    .bxor => try a.xorMemReg(.rsp, D, src_reg),
                    else => unreachable,
                }
            } else {
                // General spilled dst: compute in rax, write back.
                try placeToReg(a, .rax, pa);
                try emitAluRegPlace(a, op, .rax, pb);
                try a.movMemReg(.rsp, D, .rax);
            }
        },
        .xmm => unreachable, // integer ALU never writes a float home (see emitFloatBinOp)
    }
}

/// Lower a Lua/lune shift `dst = pa <shift> pb` (`pb` = the count). Reproduces the
/// FULL operator semantics the oracle (`arith.shiftLeft`/`shiftRight`/`shiftRightArith`)
/// computes, making no assumption that the count is masked: a negative count shifts the
/// other direction, and an out-of-range positive count saturates — to `0` for the
/// logical shifts (`shl`/`shr`), or to the **sign fill** (`-1`/`0`) for the arithmetic
/// right shift (`sar`, the `~>>` operator). x86 `shl/shr/sar reg, cl` honour only the
/// low 6 bits of the count, so the out-of-`[0,63]` cases are handled with an explicit
/// branch bracket rather than a bare hardware shift (which would alias 64→0, 65→1, … and
/// mishandle a negative count). The value works in `W` (the dst register, or rax for a
/// spilled dst); the count lives in cl (rcx, a scratch reg) for the duration. Registers
/// used: `W` + rcx only — no extra temporary — so it fits the cut-2 allocator's two
/// scratch registers no matter how many homes are live.
fn emitShift(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    // Working register: the dst register itself, or rax when dst is spilled.
    const W: Reg = switch (dst) {
        .reg => |R| R,
        .mem => .rax,
        .xmm => unreachable, // a shift result is int, never a float home
    };
    // Load the count into rcx FIRST: pb's home may coincide with the dst register (the
    // linear scan can reuse a dying operand's reg as the result home), so reading the
    // count before W is overwritten with the value avoids clobbering it. (rcx is a
    // reserved scratch, never an operand home, so this never clobbers pa.)
    try placeToReg(a, .rcx, pb);
    // Then the value into W (the mov elides when pa is already in W).
    if (!(pa == .reg and pa.reg == W)) try placeToReg(a, W, pa);

    const neg_lbl = try a.label();
    const zero_lbl = try a.label();
    const done_lbl = try a.label();
    // sar's positive-overflow leg broadcasts the sign bit instead of zeroing; only
    // referenced/bound on the `.sar` path.
    const sign_lbl = if (op == .sar) try a.label() else undefined;

    // count < 0 → reverse-direction branch.
    try a.cmpRegImm32(.rcx, 0);
    try a.jcc(.s, neg_lbl);
    // count >= 64 → out of range. Logical shifts yield 0; arithmetic right shift
    // saturates to the sign fill (`sar W, 63`).
    try a.cmpRegImm32(.rcx, 64);
    if (op == .sar) try a.jcc(.ae, sign_lbl) else try a.jcc(.ae, zero_lbl);
    // 0 <= count < 64 → the op's primary direction.
    switch (op) {
        .shl => try a.shlRegCl(W),
        .shr => try a.shrRegCl(W),
        .sar => try a.sarRegCl(W),
        else => unreachable,
    }
    try a.jmp(done_lbl);

    a.bind(neg_lbl);
    // magnitude = -count; an out-of-range magnitude (incl. INT64_MIN, whose negation
    // stays INT64_MIN — huge as unsigned) → result 0 (the reverse is always logical).
    try a.negReg(.rcx);
    try a.cmpRegImm32(.rcx, 64);
    try a.jcc(.ae, zero_lbl);
    // Reverse direction by the magnitude (`x << -n` == `x >> n`; for sar the reverse is
    // a logical left, exactly as for shr).
    if (op == .shl) try a.shrRegCl(W) else try a.shlRegCl(W);
    try a.jmp(done_lbl);

    a.bind(zero_lbl);
    try a.xorRegReg(W, W);
    if (op == .sar) {
        // zero_lbl falls through to done unless sar's sign leg follows; jump past it.
        try a.jmp(done_lbl);
        a.bind(sign_lbl);
        try a.sarRegImm8(W, 63); // broadcast bit 63 → all-ones (-1) or all-zeros (0)
    }

    a.bind(done_lbl);
    // Spilled dst: write the computed value back to its stack home.
    if (dst == .mem) try a.movMemReg(.rsp, dst.mem, W);
}

/// Lower a comparison `dst = pa <cc> pb` reading operands in place. Needs a register
/// on the left of `cmp`; stages `a` through rax only when it is spilled. The Bool
/// result lands in `dst` via setcc+movzx.
fn emitCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    const lhs: Reg = switch (pa) {
        .reg => |r| r,
        .mem => |d| blk: {
            try a.movRegMem(.rax, .rsp, d);
            break :blk .rax;
        },
        .xmm => unreachable, // F1 admits only int compare operands (float compare is F2)
    };
    switch (pb) {
        .reg => |r| try a.cmpRegReg(lhs, r),
        .mem => |d| try a.cmpRegMem(lhs, .rsp, d),
        .xmm => unreachable, // F1 admits only int compare operands (float compare is F2)
    }
    const cc: x64.Cond = switch (op) {
        .eq => .e,
        .ne => .ne,
        .lt => .l,
        .le => .le,
        else => unreachable,
    };
    switch (dst) {
        .reg => |R| {
            try a.setcc(cc, R);
            try a.movzxRegReg8(R, R); // zero-extend the 0/1 byte to the full register
        },
        .mem => |D| {
            try a.setcc(cc, .rax);
            try a.movzxRegReg8(.rax, .rax);
            try a.movMemReg(.rsp, D, .rax);
        },
        .xmm => unreachable, // a comparison result is a bool, never homed in an XMM
    }
}

/// Lower a float comparison `dst = pa <cc> pb` (both operands proven `.float`; mixed
/// int/float compares bail in proveKinds). Stages operands into xmm0/xmm1, runs
/// `ucomisd`, and combines the NaN-aware flags into a clean 0/1 bool in rax, then to
/// `dst`. `ucomisd` sets only ZF/PF/CF (PF=1 ⇔ unordered/NaN); SF/OF are untouched, so
/// the unsigned-style conds (a/ae) + p/np are the correct readouts. Semantics mirror
/// `value.compareNumeric` for two f64s: a NaN operand makes lt/le/eq false and ne true.
///
/// [review] `ucomisd` (not `comisd`) is deliberate: it raises the invalid-operand flag
/// only for a *signaling* NaN, never a quiet one. The oracle short-circuits
/// `isNan(x) or isNan(y)`, so a qNaN lhs + sNaN rhs makes native touch the sNaN (setting
/// MXCSR.IE) where the oracle would not. This never diverges the boolean *result* — and
/// it is unobservable in lune anyway: FP exceptions are masked (SysV default), there is
/// no MXCSR/feenableexcept seam, and a signaling NaN is unreachable from Lua source
/// (0.0/0.0 yields a quiet NaN; there is no sNaN literal).
fn emitFloatCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    try floatOperandToXmm(a, XMM_SCRATCH0, pa, .float); // lhs
    try floatOperandToXmm(a, XMM_SCRATCH1, pb, .float); // rhs
    switch (op) {
        // a < b: compare (rhs ? lhs); `seta` = CF==0 && ZF==0 = rhs>lhs = a<b. A NaN
        // sets CF=1 → seta=0 (false), as required.
        .lt => {
            try a.ucomisdRegReg(XMM_SCRATCH1, XMM_SCRATCH0);
            try a.setcc(.a, .rax);
            try a.movzxRegReg8(.rax, .rax);
        },
        // a <= b: `setae` = CF==0 = rhs>=lhs = a<=b. NaN sets CF=1 → 0 (false).
        .le => {
            try a.ucomisdRegReg(XMM_SCRATCH1, XMM_SCRATCH0);
            try a.setcc(.ae, .rax);
            try a.movzxRegReg8(.rax, .rax);
        },
        // a == b, NaN→false: ordered (np) AND equal (ZF). On NaN, ZF=1 but PF=1 → np=0.
        .eq => {
            try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
            try a.setcc(.e, .rax); // ZF: equal OR unordered
            try a.setcc(.np, .rcx); // ordered (not-parity)
            try a.movzxRegReg8(.rax, .rax);
            try a.movzxRegReg8(.rcx, .rcx);
            try a.andRegReg(.rax, .rcx);
        },
        // a != b, NaN→true: unordered (p) OR not-equal (!ZF). On NaN, ZF=1 → setne=0 but PF=1 → p=1.
        .ne => {
            try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
            try a.setcc(.ne, .rax); // !ZF
            try a.setcc(.p, .rcx); // unordered (parity)
            try a.movzxRegReg8(.rax, .rax);
            try a.movzxRegReg8(.rcx, .rcx);
            try a.orRegReg(.rax, .rcx);
        },
        else => unreachable,
    }
    try regToPlace(a, dst, .rax);
}

/// Materialize a numeric operand into a scratch XMM (`dst_xmm`). A `.float` operand is
/// moved with `movsd`; an `.int` operand is promoted with `cvtsi2sd` (round-to-nearest,
/// bit-matching `@floatFromInt` in the strict-FP oracle). Operand homes are XMM/spill
/// (float) or GP/spill (int) — never the cross combination.
fn floatOperandToXmm(a: *x64.Assembler, dst_xmm: Reg, place: Place, kind: Kind) !void {
    switch (kind) {
        .float => switch (place) {
            .xmm => |x| try a.movsdRegReg(dst_xmm, x),
            .mem => |d| try a.movsdRegMem(dst_xmm, .rsp, d),
            .reg => unreachable, // a float never lives in a GP register
        },
        .int => switch (place) {
            .reg => |r| try a.cvtsi2sdRegReg(dst_xmm, r),
            .mem => |d| try a.cvtsi2sdRegMem(dst_xmm, .rsp, d),
            .xmm => unreachable, // an int never lives in an XMM register
        },
        else => unreachable, // proveKinds admits only int/float operands to a float op
    }
}

/// Lower a float binary op `dst = pa <op> pb`. Both operands are staged into the reserved
/// scratch XMMs (xmm0 = lhs, xmm1 = rhs; an int operand is `cvtsi2sd`-promoted), the SSE
/// op runs in xmm0 preserving operand order (matters for sub/div), then the result moves
/// to the home. Float coalescing is disabled in the first cut, so `dst` is xmm2..15 or a
/// spill cell — never a scratch XMM — and staging through xmm0/xmm1 cannot clobber it
/// before both operands are read (so `x*x` and reused-register dsts are safe).
fn emitFloatBinOp(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, ka: Kind, pb: Place, kb: Kind) !void {
    try floatOperandToXmm(a, XMM_SCRATCH0, pa, ka);
    try floatOperandToXmm(a, XMM_SCRATCH1, pb, kb);
    switch (op) {
        .add => try a.addsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .sub => try a.subsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .mul => try a.mulsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .div => try a.divsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        else => unreachable,
    }
    switch (dst) {
        .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
        .reg => unreachable, // a float result never homes in a GP register
    }
}

/// Flush one slot's `Value` into the SoA register file: the 1-byte tag into
/// `tags[slot]` (rdi, scale-1) and the 8 payload bytes into `payloads[slot]` (rsi,
/// scale-8). The tag is written with a single-byte store (NOT the old 4-byte
/// `movMemImm32`, which under SoA would clobber the next three slots' tag bytes).
/// The payload source is a `Place`: a GP reg / spill cell raw-copies the 8 bytes
/// (int/bool); an XMM home stores the double with `movsd` (float). rax is the
/// scratch for a spilled payload.
fn flushSlot(a: *x64.Assembler, slot: i32, kind: Kind, payload: Place) !void {
    const tag: u8 = switch (kind) {
        .bool => TAG_BOOL,
        .float => TAG_FLOAT,
        // `.ptr` (invariant table) and `.heap` (per-iteration table — a carried-heap
        // slot's current value or a write-only VALUE_LANE aload result) both hold a
        // raw *GcHeader payload and re-box as a heap ref.
        .ptr, .heap => TAG_HEAP,
        else => TAG_INT,
    };
    const poff: i32 = slot * 8;
    try a.movByteMemImm(.rdi, slot, tag);
    switch (payload) {
        .reg => |r| try a.movMemReg(.rsi, poff, r),
        .xmm => |x| try a.movsdMemReg(.rsi, poff, x),
        .mem => |d| {
            try a.movRegMem(.rax, .rsp, d);
            try a.movMemReg(.rsi, poff, .rax);
        },
    }
}

/// `dst <- src` between two Places. A mem→mem move routes through rax (raw 8 bytes —
/// kind-agnostic, so it serves int and float spill cells alike). A parallel-move cycle is
/// always single-class (a move connects xmm↔xmm/mem or reg↔reg/mem, never xmm↔reg — see
/// `analyze`), so the float/int endpoint combinations below are the only ones that occur.
fn movePlace(a: *x64.Assembler, dst: Place, src: Place) !void {
    if (Place.eql(dst, src)) return;
    switch (dst) {
        .reg => |r| try placeToReg(a, r, src),
        .xmm => |dx| switch (src) {
            .xmm => |sx| try a.movsdRegReg(dx, sx),
            .mem => |sd| try a.movsdRegMem(dx, .rsp, sd),
            .reg => unreachable, // a float src never lives in a GP register
        },
        .mem => |d| switch (src) {
            .reg => |sr| try a.movMemReg(.rsp, d, sr),
            .xmm => |sx| try a.movsdMemReg(.rsp, d, sx),
            .mem => |sd| {
                try a.movRegMem(.rax, .rsp, sd);
                try a.movMemReg(.rsp, d, .rax);
            },
        },
    }
}

/// One PHI back-edge move. `is_float` records the carried slot's class so the cycle
/// breaker picks the matching scratch (xmm1 for float, rcx for int) — needed because a
/// `.mem` (spill) endpoint alone does not reveal the value's class.
const Move = struct { dst: Place, src: Place, is_float: bool = false };

/// Emit a parallel move (the back-edge PHI shuffle): all `dst <- src` happen as if
/// simultaneously. Acyclic moves go first (Kahn); each remaining disjoint cycle is
/// broken with rcx (saving the cycle's start value), fully, before the next. rax is
/// the mem↔mem scratch inside `movePlace`; the two never collide.
fn emitParallelMove(a: *x64.Assembler, moves: []Move, done: []bool) !void {
    @memset(done, false);
    var left = moves.len;

    var progress = true;
    while (progress and left > 0) {
        progress = false;
        for (moves, 0..) |m, i| {
            if (done[i]) continue;
            var blocked = false;
            for (moves, 0..) |o, j| {
                if (done[j] or j == i) continue;
                if (Place.eql(o.src, m.dst)) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            try movePlace(a, m.dst, m.src);
            done[i] = true;
            left -= 1;
            progress = true;
        }
    }

    for (moves, 0..) |_, start| {
        if (done[start]) continue;
        // Save the cycle's start value in a scratch matching the cycle's class (a cycle
        // is wholly int or wholly float). float → xmm1 (movsd), int → rcx (raw bytes,
        // works for both reg and spill endpoints).
        const fcycle = moves[start].is_float;
        if (fcycle) {
            switch (moves[start].dst) {
                .xmm => |x| try a.movsdRegReg(XMM_SCRATCH1, x),
                .mem => |d| try a.movsdRegMem(XMM_SCRATCH1, .rsp, d),
                .reg => unreachable,
            }
        } else {
            try placeToReg(a, .rcx, moves[start].dst);
        }
        var cur = start;
        while (true) {
            const m = moves[cur];
            done[cur] = true;
            left -= 1;
            var nxt: ?usize = null;
            for (moves, 0..) |o, j| {
                if (done[j]) continue;
                if (Place.eql(o.dst, m.src)) {
                    nxt = j;
                    break;
                }
            }
            if (nxt) |j| {
                try movePlace(a, m.dst, m.src);
                cur = j;
            } else {
                // m.src is the (clobbered) cycle start; restore from the saved scratch.
                if (fcycle) {
                    switch (m.dst) {
                        .xmm => |x| try a.movsdRegReg(x, XMM_SCRATCH1),
                        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH1),
                        .reg => unreachable,
                    }
                } else {
                    try regToPlace(a, m.dst, .rcx);
                }
                break;
            }
        }
    }
    std.debug.assert(left == 0);
}

/// Restore the stack/callee-saved state and return. Self-framed epilogue.
fn emitTeardown(a: *x64.Assembler, frame: i32, callee: []const Reg) !void {
    if (frame > 0) try a.addRegImm32(.rsp, frame);
    var k = callee.len;
    while (k > 0) {
        k -= 1;
        try a.pop(callee[k]);
    }
    try a.pop(.rbx);
    try a.ret();
}

/// Emit a trace's return path. Self-framed (`shared_exit == null`, test path): tear
/// down the per-trace frame + callee-saved and `ret`. Frameless (`shared_exit` set,
/// production path): the shared trampoline owns the frame, so just leave to its
/// teardown. rax is dead scratch at every exit site (the slot flush + result writes
/// are already done), so it is free to hold the target address.
///
/// `slot_addr` (doc 17 Increment 2.3) is the absolute address of this exit's link
/// slot when the exit is *chainable* (the `.link` terminal / a linked-loop-done
/// stub). When set (frameless only), the exit becomes an indirect
/// `movabs rax, slot_addr; jmp qword [rax]` — the slot holds `shared_exit` by default
/// (byte-identical to the direct jump) and a child body entry once `driveChain` arms
/// it. When null, the exit jumps directly to `shared_exit` as in 2.1 (used by the
/// non-chainable `deopt_exit` fallback and `prologue_fail`).
fn emitReturn(a: *x64.Assembler, frame: i32, callee: []const Reg, shared_exit: ?usize, trace_id: u32, slot_addr: ?usize) !void {
    // P-B (doc 17): stamp the final trace's stable id into the result. rdx still holds
    // the *NativeResult at every exit site (it is reserved for the whole body). Baked
    // as an imm32 (the trace's own id here; a linked child overwrites it in 2.3).
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    if (shared_exit) |se| {
        if (slot_addr) |sa| {
            // Indirect through the link slot: load the slot's current target VALUE
            // (default `shared_exit`, or an armed child body entry) into rax, apply the
            // 2.3c-2c forced-yield cap (redirects an armed dispatch to `shared_exit` when
            // the ledger is full), then jump. Loading the value (vs. the old `jmp [slot]`
            // through memory) is what lets the cap inspect and, if needed, override it.
            try a.movRegImm64(.rax, @bitCast(@as(u64, sa)));
            try a.movRegMem(.rax, .rax, 0);
            try emitForcedYieldCheck(a, se);
            try a.jmpReg(.rax);
        } else {
            try a.movRegImm64(.rax, @bitCast(@as(u64, se)));
            try a.jmpReg(.rax);
        }
    } else {
        try emitTeardown(a, frame, callee);
    }
}

/// Absolute address of the link slot for IR instruction `idx`, or null when there is
/// no slot table (self-framed test page). Baked into the exit as an imm64 so the
/// `jmp qword [rax]` reaches the slot regardless of where the heap array lives.
fn slotAddr(slots: []usize, idx: usize) ?usize {
    if (slots.len == 0) return null;
    return @intFromPtr(&slots[idx]);
}

/// 2.3c-2a (doc 17): append one per-transition entry to `NativeResult`'s ledger at
/// index `ledger_len`, then bump the length — the mechanism that lets a fused native
/// span (`C→I→C→…` chained under the shared frame) recover the HIDDEN intermediate
/// exits its single returned `NativeResult` would otherwise drop. Records the cumulative
/// `rbx` counter (`ledger_cum`, scale-8) plus `trace_id` (imm) and the already-in-memory
/// `exit_instr` / `exit_reason` (scale-4 parallel arrays). EVERY exit site calls this
/// AFTER it has written `NativeResult.exit_instr` and `NativeResult.exit_reason` (so the
/// reads below see THIS exit's values — `exit_reason` stays the wrapper-init `.normal`
/// at every site except `prologue_fail`, which writes it first, and `prologue_fail` is
/// terminal so it never rides mid-span) and BEFORE it dispatches (so a chain-source exit
/// records itself before jumping into the child). Clobbers rax (index) and rcx (staging)
/// — both dead scratch at every exit; rbx is the live cumulative counter, rdx the
/// `*NativeResult`.
///
/// Bounds-guarded: when the ledger is at `LEDGER_CAP` the entry is DROPPED (span
/// continues). That is inert while nothing forms a native cycle — 2.3c-2a/b spans are a
/// handful of hops, far below the cap — and 2.3c-2c replaces the drop at chain-SOURCE
/// sites with a forced yield to `shared_exit` so a closed cycle can never silently lose
/// a hop.
fn emitLedgerAppend(a: *x64.Assembler, trace_id: u32, kind: irinterp.LedgerKind) !void {
    const full = try a.label();
    // rax = ledger_len; drop the entry if already at capacity (unreachable pre-cycle).
    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "ledger_len"));
    try a.cmpRegImm32(.rax, @intCast(irinterp.LEDGER_CAP));
    try a.jcc(.ae, full);
    // ledger_cum[rax] = rbx  (usize lane, SIB scale 8)
    try a.storeMemSibReg(.rdx, .rax, 8, @offsetOf(NativeResult, "ledger_cum"), .rbx);
    // ledger_id[rax] = trace_id  (u32 lane; imm staged in rcx, scale 4)
    try a.movRegImm64(.rcx, @intCast(trace_id));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_id"), .rcx);
    // ledger_exit[rax] = NativeResult.exit_instr  (8-byte load, low 32 stored)
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "exit_instr"));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_exit"), .rcx);
    // ledger_reason[rax] = NativeResult.exit_reason
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "exit_reason"));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_reason"), .rcx);
    // 2.3c-2c: ledger_kind[rax] = kind  (u32 lane; per-site compile-time constant).
    try a.movRegImm64(.rcx, @intCast(@intFromEnum(kind)));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_kind"), .rcx);
    // 2.3c-2c: ledger_outcome[rax] = .normal (0). A chain-source forced yield
    // (`emitForcedYieldCheck`) overwrites this entry to `.yielded` when the ledger is
    // full; otherwise it stays `.normal` (dispatched-or-terminal, positionally resolved).
    try a.movRegImm64(.rcx, @intCast(@intFromEnum(irinterp.LedgerOutcome.normal)));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_outcome"), .rcx);
    // ledger_len = rax + 1
    try a.incReg(.rax);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "ledger_len"), .rax);
    a.bind(full);
}

/// 2.3c-2c (doc 17): the forced-yield cap. Emitted at every frameless chain-source
/// dispatch, AFTER `emitLedgerAppend` and BEFORE the `jmp`. On entry `rax` holds the
/// resolved dispatch target — an armed child body entry, or `shared_exit` when the
/// slot is unarmed. Contract:
///   * unarmed (`rax == shared_exit`)         → leave `rax`, fall through (natural terminal / plain deopt);
///   * armed + ledger has room (`len < CAP`)  → leave `rax`, fall through (dispatch into the child);
///   * armed + ledger FULL (`len == CAP`)     → mark the just-appended terminal entry
///       `.yielded` and rewrite `rax = shared_exit`, so a closed native cycle returns to
///       the driver instead of running an unrecordable hop.
/// Leaves `rax` = the (possibly rewritten) jmp target; the caller does `jmp rax`.
/// Clobbers `rcx` (dead scratch — `emitLedgerAppend` just clobbered it). `rbx` (live
/// cumulative counter) and `rdx` (`*NativeResult`) are untouched.
///
/// DEAD until 2.3c-2e closes the `I→C` cycle: pre-cycle every span is ≤2 entries « CAP
/// (32), so the ledger never fills and the yield branch never executes — byte-identical.
fn emitForcedYieldCheck(a: *x64.Assembler, shared_exit: usize) !void {
    const do_jmp = try a.label();
    // rcx = shared_exit. Unarmed target (rax == shared_exit) → nothing to cap.
    try a.movRegImm64(.rcx, @bitCast(@as(u64, shared_exit)));
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.e, do_jmp);
    // Armed. Room left in the ledger (ledger_len < CAP) → dispatch into the child.
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "ledger_len"), @intCast(irinterp.LEDGER_CAP));
    try a.jcc(.b, do_jmp);
    // Armed AND full → forced yield. Mark the just-appended terminal entry (index
    // ledger_len − 1) `.yielded`, then redirect the dispatch to `shared_exit`.
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "ledger_len"));
    try a.subRegImm32(.rcx, 1);
    // Stage the `.yielded` code in rax (free — reloaded with shared_exit right after),
    // store it into ledger_outcome[rcx] (u32 lane, scale 4).
    try a.movRegImm64(.rax, @intCast(@intFromEnum(irinterp.LedgerOutcome.yielded)));
    try a.storeMemSibReg(.rdx, .rcx, 4, @offsetOf(NativeResult, "ledger_outcome"), .rax);
    try a.movRegImm64(.rax, @bitCast(@as(u64, shared_exit)));
    a.bind(do_jmp);
}

/// B-3a's unreachable silent tail. `metadata_cell` is a stable compile-time-owned
/// pointer cell; B-3b publishes a `*SilentExitMetadata` into it before patching.
fn emitSilentEpilogue(a: *x64.Assembler, kind: ExitPatchKind, metadata_cell: *usize, shared_exit: usize, trace_id: u32) !void {
    const can_silence = try a.label();
    const owned = try a.label();
    const qualified_done = try a.label();
    const zero_done = try a.label();
    const reset_zero = try a.label();
    const exhausted = try a.label();

    // A reporting prefix cannot be represented by the silent ABI. Continue at the
    // exact original reporting target whenever this span has emitted any row. This
    // also prevents re-entering silence after an off-cycle reporting suffix begins.
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(metadata_cell))));
    try a.movRegMem(.rax, .rax, 0);
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "ledger_len"), 0);
    try a.jcc(.e, can_silence);
    try a.movRegMem(.rax, .rax, @offsetOf(SilentExitMetadata, "reporting_target"));
    try a.jmpReg(.rax);
    a.bind(can_silence);

    // Final round-5 ordering: kind-specific materialization is complete before this
    // store, and every promoted epilogue publishes the exact cumulative rbx baseline.
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_cum"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "silent_active"), 1);

    // rax = *SilentExitMetadata (loaded above).
    // First-cell ownership: preserve the first promoted edge observed in this call.
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "silent_cell"), 0);
    try a.jcc(.ne, owned);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_cell"), .rax);
    a.bind(owned);

    // r8 = dynamic local = current rbx - this body's entry rbx; rcx = edge cell.
    try a.movRegReg(.r8, .rbx);
    try a.subRegMem(.r8, .rdx, @offsetOf(NativeResult, "entry_rbx"));
    try a.movRegMem(.rcx, .rax, @offsetOf(SilentExitMetadata, "summary"));
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_local"), .r8);

    // Round-6 exactness: every firing records ITSELF — its count, its ordinal, and
    // that it was the most recent edge to fire. Zig then indexes the summary by
    // measurement rather than by `(first_phase + t) % len` arithmetic, which is only
    // sound for a single live ring in which every trace owns exactly one phase.
    // r9 = this firing's one-based silent-transition ordinal (the counter at
    // `silent_transitions` is bumped at the tail, after the kind switch).
    try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "firings"));
    try a.movRegMem(.r9, .rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.incReg(.r9);
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_ordinal"), .r9);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_last_cell"), .rax);

    // Preserve dynamic progress evidence independently from aggregated work.
    // Provenance verdict merging needs occurrence count, not merely a sum that
    // could have come from a different number of firings.
    const not_productive = try a.label();
    try a.cmpRegImm32(.r8, 0);
    try a.jcc(.e, not_productive);
    try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "productive_firings"));
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_productive_ordinal"), .r9);
    a.bind(not_productive);

    switch (kind) {
        .deopt => {
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "region_work"), .r8);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.cmpRegImm32(.r8, 0);
            try a.jcc(.ne, reset_zero);
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
        .loop_done_linked => {
            // region_work += 1; selection_work += max(local, 1).
            try a.movRegImm64(.r9, 1);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "region_work"), .r9);
            try a.cmpRegImm32(.r8, 0);
            const local_nonzero = try a.label();
            try a.jcc(.ne, local_nonzero);
            try a.movRegImm64(.r8, 1);
            a.bind(local_nonzero);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.jmp(reset_zero);
        },
        .link_terminal => {
            // Structural only: no work cells; a zero-work link advances the barren run.
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
        .region_bridge => {
            // Structural region work is zero, but selection charges max(local, 1).
            // Zero region work advances the barren run even when local is nonzero.
            try a.cmpRegImm32(.r8, 0);
            const local_nonzero = try a.label();
            try a.jcc(.ne, local_nonzero);
            try a.movRegImm64(.r8, 1);
            a.bind(local_nonzero);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
    }
    a.bind(reset_zero);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "cur_zero_run"), 0);
    a.bind(zero_done);

    try a.incMemQword(.rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.movRegMem(.r8, .rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.cmpRegMem(.r8, .rdx, @offsetOf(NativeResult, "silent_budget"));
    try a.jcc(.ae, exhausted);
    try a.movRegMem(.r8, .rdx, @offsetOf(NativeResult, "cur_zero_run"));
    // Final round-5 barren comparison is absolute: cur_zero_run >= max_barren_run,
    // with max_barren_run staged directly in barren_budget.
    try a.cmpRegMem(.r8, .rdx, @offsetOf(NativeResult, "barren_budget"));
    try a.jcc(.ae, exhausted);

    // Continue through the same per-exit slot as the reporting path.
    try a.movRegMem(.rax, .rax, @offsetOf(SilentExitMetadata, "slot"));
    try a.movRegMem(.rax, .rax, 0);
    try a.jmpReg(.rax);

    a.bind(exhausted);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    try a.movRegImm64(.rax, @bitCast(@as(u64, shared_exit)));
    try a.jmpReg(.rax);
}

fn nativeExitLabel(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize) !x64.Label {
    if (exit_labels[instr_idx]) |l| return l;
    const l = try a.label();
    exit_labels[instr_idx] = l;
    return l;
}

fn jccNativeExit(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize, cc: x64.Cond) !void {
    try a.jcc(cc, try nativeExitLabel(a, exit_labels, instr_idx));
}

fn jmpNativeExit(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize) !void {
    try a.jmp(try nativeExitLabel(a, exit_labels, instr_idx));
}

fn nativeLinkedLoopDoneLabel(a: *x64.Assembler, linked_loop_done_labels: []?x64.Label, instr_idx: usize) !x64.Label {
    if (linked_loop_done_labels[instr_idx]) |l| return l;
    const l = try a.label();
    linked_loop_done_labels[instr_idx] = l;
    return l;
}

fn isNumericForLoopDoneGuard(t: *const Trace, instr_idx: usize) bool {
    if (instr_idx >= t.instrs.len) return false;
    const guard = t.instrs[instr_idx];
    if (guard.op != .guard_true) return false;
    const exit_pc = trace.guardExitPc(guard) orelse return false;
    if (exit_pc == 0 or exit_pc > t.anchor.proto.code.len) return false;
    return t.anchor.proto.code[trace.guardSourcePc(guard).?].op == .for_loop;
}

/// Part A-v (doc 17 §A2.1/§A2.3): true for a trace-local composite outer-loop
/// re-test whose bridge has at least one dominance-safe slot update to commit.
///
/// "Same-proto outer re-test" is represented without region metadata: committed
/// guard provenance must identify a source-level branch condition owned by the
/// anchor proto, and its post-fetch PC must precede this continuation's anchor.
/// This excludes inlined-callee guards, forward branches, and numeric-for
/// loop-done guards. The dominance-scoped set E is the slot-bound phi set whose
/// update ref was defined before the guard; a slot-bound phi is precisely a value
/// live at the trace successor/back-edge. Internal phis do not name VM slots and
/// are excluded.
pub fn isCompositeBridgeCandidate(t: *const Trace, instr_idx: usize) bool {
    if (instr_idx >= t.instrs.len) return false;
    const guard = t.instrs[instr_idx];
    if (guard.op != .guard_true and guard.op != .guard_false) return false;
    if (isNumericForLoopDoneGuard(t, instr_idx)) return false;

    const exit_pc = trace.guardExitPc(guard) orelse return false;
    const source_pc = trace.guardSourcePc(guard) orelse return false;
    if (exit_pc >= t.anchor.pc or source_pc >= t.anchor.proto.code.len) return false;
    const prov = t.provAt(@intCast(instr_idx)) orelse return false;
    const guard_prov = switch (prov) {
        .guard => |g| g,
        .link_terminal => return false,
    };
    if (guard_prov.role != .branch_cond or
        guard_prov.source_proto_id != t.anchor.proto.id or
        guard_prov.source_pc != source_pc)
        return false;
    switch (t.anchor.proto.code[source_pc].op) {
        .jmp_if_true, .jmp_if_false => {},
        else => return false,
    }

    for (t.instrs) |p| {
        if (p.op == .phi and p.aux != trace.PHI_INTERNAL and p.b < instr_idx)
            return true;
    }
    return false;
}

/// The caller-saved GPRs every body callout must preserve (rax/rcx are the
/// JIT's scratch pair and deliberately excluded — a callout result rides
/// through the restore in one of them).
const CALLOUT_SAVED_GP = [_]Reg{ .r8, .r9, .r10, .r11 };

/// Save every SysV caller-saved home the JIT body may keep live across a
/// mid-body callout — rdi/rsi (SoA bases), rdx (*NativeResult), r8–r11, and
/// all allocatable XMMs (xmm2–xmm15) — into the pre-reserved
/// `callout_save_base` frame area. Shared by every `BodyCallout` lowering
/// (doc 23 D4 generalized this out of the href callout); paired with
/// `emitCalloutRestore`.
fn emitCalloutSave(a: *x64.Assembler, alloc: *const Alloc) !void {
    std.debug.assert(alloc.callout_save_count != 0); // save area must be reserved
    var off: u32 = alloc.callout_save_base;
    // rdi (tags base), rsi (payloads base), rdx (*NativeResult).
    try a.movMemReg(.rsp, @intCast(off * 8), .rdi);
    off += 1;
    try a.movMemReg(.rsp, @intCast(off * 8), .rsi);
    off += 1;
    try a.movMemReg(.rsp, @intCast(off * 8), .rdx);
    off += 1;
    // ALL caller-saved GP registers (r8–r11), not just homes — transients in
    // these registers may be live across the callout.
    for (CALLOUT_SAVED_GP) |r| {
        try a.movMemReg(.rsp, @intCast(off * 8), r);
        off += 1;
    }
    // ALL allocatable XMMs (xmm2–xmm15): same reasoning — a transient float
    // live across the callout would be clobbered.
    for (XMM_ALLOC_ORDER) |r| {
        try a.movsdMemReg(.rsp, @intCast(off * 8), r);
        off += 1;
    }
    // Sanity: we used exactly the reserved number of slots.
    std.debug.assert(off == alloc.callout_save_base + alloc.callout_save_count);
}

/// Restore everything `emitCalloutSave` saved, in reverse order. Deliberately
/// never touches rax/rcx (GP scratch) or xmm0/xmm1 (float scratch): a callout
/// stashes its result there so it survives the restore. Restore must happen
/// BEFORE any result check that can side-exit — the deopt flush at
/// `jccNativeExit` relies on slot homes being correct.
fn emitCalloutRestore(a: *x64.Assembler, alloc: *const Alloc) !void {
    var off: u32 = alloc.callout_save_base + alloc.callout_save_count;
    {
        var ri: usize = XMM_ALLOC_ORDER.len;
        while (ri > 0) {
            ri -= 1;
            off -= 1;
            try a.movsdRegMem(XMM_ALLOC_ORDER[ri], .rsp, @intCast(off * 8));
        }
    }
    {
        var ri: usize = CALLOUT_SAVED_GP.len;
        while (ri > 0) {
            ri -= 1;
            off -= 1;
            try a.movRegMem(CALLOUT_SAVED_GP[ri], .rsp, @intCast(off * 8));
        }
    }
    off -= 1;
    try a.movRegMem(.rdx, .rsp, @intCast(off * 8));
    off -= 1;
    try a.movRegMem(.rsi, .rsp, @intCast(off * 8));
    off -= 1;
    try a.movRegMem(.rdi, .rsp, @intCast(off * 8));
    std.debug.assert(off == alloc.callout_save_base);
}

/// Emit the mid-body callout for a float-kernel producer (`fsin`/`fcos`
/// unary, `pow` binary — doc 23 D4). The native body calls THE SAME noinline
/// `fmath` kernel tier-0 and tier-1a execute — never an inline SSE
/// re-derivation — so cross-tier bit-identity holds by construction (there is
/// exactly one compiled body of each kernel in the process). SysV float call:
/// operands in xmm0(/xmm1), result in xmm0; the restore only touches xmm2–xmm15 /
/// r8–r11 / rdi/rsi/rdx, so the result rides through it in xmm0. No side-exit:
/// the operand is a proven numeric (dominating `guard_float`/`guard_int`) and
/// the kernel is total (NaN in → NaN out).
fn emitFloatCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
) !void {
    try emitCalloutSave(a, alloc);

    // arg0: the proven-numeric operand into xmm0 (== XMM_SCRATCH0); a proven
    // int promotes via the shared cvtsi2sd discipline. `pow` (the two-arg
    // kernel) additionally stages its exponent into xmm1 — staging order is
    // safe because operand homes are never the scratch XMMs.
    try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
    if (ins.op == .pow)
        try floatOperandToXmm(a, XMM_SCRATCH1, placeOfRef(alloc, ins.b), kinds[ins.b]);

    // Call the fmath kernel via an absolute address in rax. Same alignment
    // dance as emitHrefCallout: the body runs with rsp % 16 == 8, SysV wants
    // rsp % 16 == 0 at the call.
    const kernel: usize = switch (ins.op) {
        .fsin => @intFromPtr(&fmath.sinRuntime),
        .fcos => @intFromPtr(&fmath.cosRuntime),
        .pow => @intFromPtr(&fmath.powRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(kernel));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // Result is in xmm0; restore (which leaves xmm0 alone), then home it.
    try emitCalloutRestore(a, alloc);
    switch (placeOfRef(alloc, i)) {
        .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
        .reg => unreachable, // a float result never homes in a GP register
    }
}

/// Emit the mid-body callout for an allocating interned-string producer
/// (`tostr_int`/`tostr_num` — doc 24 D5). Same shape as `emitHrefCallout`:
/// save, SysV args (rdi = the baked `*Heap`; the guarded scalar in rsi for the
/// int body, xmm0 for the float body), call the shared noinline `stralloc`
/// body through an absolute pointer, stash the result across the restore, then
/// test-and-exit. A null return is OOM with a CLEAN id stream (no `Heap.link`
/// preceded the fallible step — stralloc.zig's audit): the ordinary deopt exit
/// resumes tier-0 at the header and the replay re-raises the same OOM at the
/// same logical point. On success the `*GcHeader` (kind `.heap`) lands in the
/// op's home; the restore leaves rcx/rax/xmm0 untouched so it rides through.
fn emitTostrCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    heap: *gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // Stage the operand BEFORE overwriting rdi (a `.mem` home reads via rsp,
    // untouched by the save; a `.reg` home is r8–r11, also untouched).
    if (ins.op == .tostr_int) {
        try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
    } else {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
    }
    // arg0: the Heap, baked absolute (stable for the VM's lifetime).
    try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap))));

    // Call the stralloc body via an absolute address in rax. Same alignment
    // dance as emitHrefCallout (body runs with rsp % 16 == 8).
    const body: usize = switch (ins.op) {
        .tostr_int => @intFromPtr(&stralloc.tostrIntRuntime),
        .tostr_num => @intFromPtr(&stralloc.tostrNumRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(body));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax = the interned *GcHeader, or 0 on OOM. The result check must come
    // AFTER the restore (the deopt flush relies on slot homes being correct),
    // so stash it in rcx — scratch, never a home, untouched by the restore.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // 0 → OOM → side-exit
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the per-iteration hash-cell resolution call-out for a `.heap`-rooted href.
/// The sequence saves all live caller-saved homes (rdi/rsi SoA bases + GP + XMM)
/// into the pre-reserved frame area, sets up SysV ABI arguments, calls
/// `resolveHashCell`, restores, checks the result, and stores the cell pointer in
/// the href's home. On a 0 return (cell not found) the trace side-exits.
fn emitHrefCallout(
    a: *x64.Assembler,
    t: *const Trace,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    _ = kinds;

    // 1. Save all caller-saved homes into the reserved frame area.
    try emitCalloutSave(a, alloc);

    // 2. Set up SysV ABI arguments:
    //    rdi = *GcHeader (from the aload's home — the .heap table pointer)
    //    rsi = key tag bits (compile-time constant from the trace's const pool)
    //    rdx = key payload bits (compile-time constant)
    //
    // The href's ins.b is a konst instruction; the konst's aux indexes t.consts.
    const konst_ins = t.instrs[ins.b];
    const key = t.consts[@intCast(konst_ins.aux)];
    const key_tag: u64 = @intFromEnum(key.tag);
    const key_payload: u64 = key.payload.bits;

    // Load the table *GcHeader into rdi (arg0). The aload result (ins.a) might be
    // in a register home, a spill, or might have been clobbered if its home was rdi
    // — but we already saved rdi, and refBaseReg uses .rax as scratch, which is fine
    // since we haven't loaded args into it yet.
    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));

    // Key tag and payload are compile-time constants.
    try a.movRegImm64(.rsi, @bitCast(key_tag));
    try a.movRegImm64(.rdx, @bitCast(key_payload));

    // 3. Call resolveHashCell via an absolute address in rax.
    // The JIT body runs with rsp % 16 == 8 (return-address push from the
    // C-ABI entry call). SysV requires rsp % 16 == 0 at a `call` site, so
    // bump the stack by 8 to fix alignment, then undo after the call.
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@intFromPtr(&resolveHashCell)));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax now holds the cell pointer (or 0 on miss). The result check must
    // come AFTER the restore (the deopt flush at jccNativeExit relies on slot
    // homes being correct), so stash rax in rcx — scratch, not a home, and
    // emitCalloutRestore never touches it — then restore, then test rcx.
    try a.movRegReg(.rcx, .rax);

    // 5. Restore everything saved in step 1 (rcx/xmm0 untouched).
    try emitCalloutRestore(a, alloc);

    // 6. Check the result (stashed in rcx). 0 = cell not found → side-exit.
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // ZF=1 → rcx==0 → miss

    // 7. Store the cell pointer (in rcx) into the href's home.
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

fn emitHStore(a: *x64.Assembler, kinds: []const Kind, alloc: *const Alloc, ins: trace.IrInstr) !void {
    if (kinds[ins.b] == .float) {
        // Stage the value into XMM_SCRATCH0 first (independent of rax/rcx), then
        // write tag + payload through the cell pointer.
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const creg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.movByteMemImm(creg, VALUE_TAG_OFF, TAG_FLOAT);
        try a.movsdMemReg(creg, VALUE_PAYLOAD_OFF, XMM_SCRATCH0);
    } else {
        // Load the value before resolving the cell pointer: a spilled href resolves
        // through rcx (never rax), and value homes are outside rax/rcx.
        try placeToReg(a, .rax, placeOfRef(alloc, ins.b));
        const creg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.movByteMemImm(creg, VALUE_TAG_OFF, TAG_INT);
        try a.storeMemReg(creg, 8, VALUE_PAYLOAD_OFF, .rax);
    }
}

fn emitAStore(a: *x64.Assembler, t: *const Trace, alloc: *const Alloc, ins: trace.IrInstr) !void {
    const aref_ins = t.instrs[ins.a];
    if (ins.aux == F64_LANE) {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, 8, 0);
        try a.movsdMemReg(.rax, 0, XMM_SCRATCH0);
        const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
        const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.btsMemReg(preg, 0, pireg);
    } else if (ins.aux == BOOL_LANE) {
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, 1, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.incReg(.rcx);
        try a.storeMemReg(.rax, 1, 0, .rcx);
    } else {
        const w = intLaneWidth(ins.aux);
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, w, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.storeMemReg(.rax, w, 0, .rcx);

        const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
        const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.btsMemReg(preg, 0, pireg);
    }
}

fn emitGStore(a: *x64.Assembler, t: *const Trace, alloc: *const Alloc, ins: trace.IrInstr) !void {
    const gcell_ins = t.instrs[ins.a];
    const garow_ins = t.instrs[gcell_ins.a];
    if (ins.aux == F64_LANE) {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
        const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, flatreg, 8, 0);
        try a.movsdMemReg(.rax, 0, XMM_SCRATCH0);
    } else {
        const w = intLaneWidth(ins.aux);
        const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
        const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, flatreg, w, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.storeMemReg(.rax, w, 0, .rcx);
    }
    const preg = try arrayFieldReg(a, alloc, garow_ins.a, .present, .rax);
    const pflat = try refBaseReg(a, alloc, ins.a, .rcx);
    try a.btsMemReg(preg, 0, pflat);
}

fn emitLinkedLoopDoneSnapshot(
    a: *x64.Assembler,
    t: *const Trace,
    kinds: []const Kind,
    alloc: *const Alloc,
    exit_instr: usize,
) !void {
    var si = exit_instr + 1;
    while (si < t.instrs.len) : (si += 1) {
        const p = t.instrs[si];
        switch (p.op) {
            .astore => try emitAStore(a, t, alloc, p),
            .hstore => try emitHStore(a, kinds, alloc, p),
            .gstore => try emitGStore(a, t, alloc, p),
            .phi, .loop, .link => break,
            else => {},
        }
    }

    const guard = t.instrs[exit_instr];
    const for_ins = t.anchor.proto.code[trace.guardSourcePc(guard).?];
    const visible_var_slot: i32 = @as(i32, @intCast(for_ins.a)) + 3;
    for (t.instrs) |p| {
        if (p.op != .phi or p.aux == trace.PHI_INTERNAL) continue;
        if (p.aux == visible_var_slot) continue;
        try flushSlot(a, @as(i32, @intCast(p.aux)), kinds[@intCast(p.b)], placeOfRef(alloc, @intCast(p.b)));
    }
}

/// Part A-v (doc 17 §A2.1): materialize the bridge's compile-time set E.
/// Slot-bound phis are the trace successor's live VM-slot writebacks; only an
/// update defined before `exit_instr` dominates that guard. Post-guard phis and
/// internal optimizer phis are deliberately excluded.
fn emitCompositeBridgeSnapshot(
    a: *x64.Assembler,
    t: *const Trace,
    kinds: []const Kind,
    alloc: *const Alloc,
    exit_instr: usize,
) !void {
    var emitted = compositeBridgeEmissions(t, exit_instr);
    while (emitted.next()) |p| {
        try flushSlot(
            a,
            @as(i32, @intCast(p.aux)),
            kinds[@intCast(p.b)],
            placeOfRef(alloc, @intCast(p.b)),
        );
    }
}

pub const CompositeBridgeEmissionIterator = struct {
    instrs: []const trace.IrInstr,
    exit_instr: usize,
    index: usize = 0,

    pub fn next(self: *CompositeBridgeEmissionIterator) ?trace.IrInstr {
        while (self.index < self.instrs.len) {
            const p = self.instrs[self.index];
            self.index += 1;
            if (p.op == .phi and p.aux != trace.PHI_INTERNAL and p.b < self.exit_instr)
                return p;
        }
        return null;
    }
};

/// The single source of truth for A-v's emitted bridge set E: slot-bound phis
/// whose update dominates the composite exit. Both lowering and arm validation
/// consume this allocation-free immutable-IR query.
pub fn compositeBridgeEmissions(t: *const Trace, exit_instr: usize) CompositeBridgeEmissionIterator {
    return .{ .instrs = t.instrs, .exit_instr = exit_instr };
}

pub fn compositeBridgeEmitsSlot(t: *const Trace, exit_instr: usize, slot: u16) bool {
    var emitted = compositeBridgeEmissions(t, exit_instr);
    while (emitted.next()) |p|
        if (p.aux == @as(i32, @intCast(slot))) return true;
    return false;
}

/// Byte offsets (from `page.code.ptr`) of the two frameless secondary entry stubs a
/// production body emits after its exit tables. Both `null` on the self-framed test
/// path (no shared trampoline → no chaining). `compileImpl` resolves them to absolute
/// addresses against the mapped page.
const EntryStubs = struct {
    linked_entry: ?usize = null,
    ordinary_entry: ?usize = null,
    /// Doc 22 §B.4: whether `lower` actually emitted the seed prologue at
    /// `body_entry`. Recorded from emission itself (`seed_hash_exit != null`),
    /// NOT recomputed from the plan, so `stubEnterable`'s release-assert
    /// `seed_plan.nonEmpty() == seed_prologue` checks two independent facts.
    seed_prologue: bool = false,
};

const PatchEmission = struct {
    kind: ExitPatchKind,
    patch_off: usize,
    epilogue: x64.Label,
};

/// Lower a proven trace to machine code (cut-2). ABI: rdi = tags base, rsi = payloads
/// base (the SoA register file's two lanes), rdx = native result out-param, rbx =
/// committed counter, rax/rcx = scratch. Loop-carried/invariant slots live in registers
/// across iterations (loaded + type-guarded once in the prologue); `regs[]` is written
/// only on a side-exit (the single snapshot) or for write-only slots at the back-edge.
fn lower(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, alloc: *const Alloc, a: *x64.Assembler, shared_exit: ?usize, slots: []usize, metadata_cells: []usize, patch_emissions: []?PatchEmission, seed_ctx: ?*const trace.NativeSeedCtx, seed_plan: SeedPlan, heap: ?*gc.Heap) !EntryStubs {
    const exit_labels = try gpa.alloc(?x64.Label, t.instrs.len);
    defer gpa.free(exit_labels);
    @memset(exit_labels, null);
    const linked_loop_done_labels = try gpa.alloc(?x64.Label, t.instrs.len);
    defer gpa.free(linked_loop_done_labels);
    @memset(linked_loop_done_labels, null);

    // Callee-saved registers we clobber — as a home OR as a transient — must be
    // preserved across the call. `used_callee_saved` already ORs both; iterate a fixed
    // order so push/pop pair up. (Homing only the slot homes here was a latent bug: a
    // linear-scan transient landing in rbp/r12–r15 was clobbered unsaved → SEGV on
    // return once the host actually relied on that register.)
    var callee: [ALLOC_ORDER.len]Reg = undefined;
    var callee_len: usize = 0;
    for (ALLOC_ORDER) |r| {
        if ((regBit(r) & CALLEE_SAVED_MASK) != 0 and (alloc.used_callee_saved & regBit(r)) != 0) {
            callee[callee_len] = r;
            callee_len += 1;
        }
    }

    // Frame = compacted spill area (homes + transients that missed a register), padded so
    // the total below-entry delta (rbx + callee pushes + frame) stays 16-byte aligned [RV-6].
    const pushes = 1 + callee_len; // rbx + callee-saved homes
    const frame: i32 = @intCast(std.mem.alignForward(usize, pushes * 8 + alloc.spill_count * 8, 16) - pushes * 8);

    // Prologue: save rbx + callee-saved homes, completed = 0, reserve the frame.
    // Frameless (production): the shared trampoline already saved ALL callee-saved,
    // zeroed rbx, and reserved SPILL_MAX*8 of spill area, so the body starts directly
    // at the hoisted guards below. `[rsp + idx*8]` spill addressing is identical
    // (idx < SPILL_MAX, guaranteed by the compileImpl bail); `frame`/`callee` are
    // computed above but used only by the self-framed epilogue.
    if (shared_exit == null) {
        try a.push(.rbx);
        for (callee[0..callee_len]) |r| try a.push(r);
        try a.xorRegReg(.rbx, .rbx);
        if (frame > 0) try a.subRegImm32(.rsp, frame);
    }

    // 2.3b-0 (doc 17): `body_entry` — the trace's real entry, reached fresh from the
    // trampoline (`page.code.ptr`) OR fallen-through from the `linked_entry` stub
    // emitted at the end (which presets `linked_loop_done` for a chained handoff).
    const body_entry = try a.label();
    a.bind(body_entry);
    // Snapshot the entry value of the `rbx` iteration counter into the result so the
    // Zig wrapper can recover this body's OWN committed count as
    // `completed − entry_rbx`. This is the first body instruction (rbx is already
    // zeroed — trampoline for frameless, the `xor` above for self-framed). A child
    // entered via `linked_entry` (2.3b-1) inherits the parent's cumulative `rbx` —
    // recorded here, subtracted out by the wrapper. rdx holds `*NativeResult` for the
    // whole body. Un-fused, rbx = 0, so this stores 0 and `local_completed ==
    // completed` (asserted in the wrapper).
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "entry_rbx"), .rbx);

    const loop_top = try a.label();
    const deopt_exit = try a.label();
    const prologue_fail = try a.label();

    // Doc 22 §B.2: the SEED PROLOGUE. A seeded page resolves its own entry inputs
    // (upvalue / global / hash_cell seeds) by calling the VM's C-ABI seeding twin
    // (`NativeSeedCtx.seed_fn` → interp.zig `nativeSeedFn`) before anything reads
    // the slab — the hoisted tag guards below ([RV-1]) read `tags[slot]` for the
    // seeded slots, so the callout MUST precede them. Emitted iff the plan is
    // non-empty (`compileImpl` bailed when the ctx was missing, so `seed_ctx.?` is
    // guaranteed here — the §B.4 invariant `plan.nonEmpty() ⟺ prologue-present` is
    // definitional). Every entry runs it: fresh trampoline entries AND fused hops
    // through LINKED_ENTRY/ORDINARY_ENTRY (both fall into `body_entry`) — inert for
    // the latter until B-iv opens the arm gates to seeded pages.
    //
    // Register bracket: at `body_entry` only rdi (tags), rsi (payloads) and rdx
    // (*NativeResult) are live caller-saved regs — no home is loaded yet, all XMM
    // are dead, and rbx (the cumulative counter) is callee-saved so the C call
    // preserves it. Three pushes take rsp from ≡8 (mod 16, the body's invariant —
    // see emitHrefCallout) to ≡0, so the call site is aligned with no fixup.
    var seed_hash_exit: ?x64.Label = null;
    var seed_capacity_exit: ?x64.Label = null;
    if (seed_plan.nonEmpty()) {
        const ctx = seed_ctx.?;
        const hash_l = try a.label();
        const cap_l = try a.label();
        const seed_ok = try a.label();
        try a.push(.rdi);
        try a.push(.rsi);
        try a.push(.rdx);
        // SysV args: rdi = &ctx (per-VM, heap-stable), rsi = &t (committed traces
        // are heap-allocated + immutable), rdx = the plan bitmap BY VALUE (the
        // returned CompiledTrace has no stable address to bake — see
        // `NativeSeedCtx.seed_fn`).
        try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(ctx))));
        try a.movRegImm64(.rsi, @bitCast(@as(u64, @intFromPtr(t))));
        try a.movRegImm64(.rdx, @bitCast(seed_plan.bits));
        // `seed_fn` is installed once at VM init and never reassigned — safe to
        // read at compile time and bake.
        try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(ctx.seed_fn))));
        try a.callReg(.rax);
        try a.pop(.rdx);
        try a.pop(.rsi);
        try a.pop(.rdi);
        // Tri-state result, fail closed: SEED_OK runs the body, SEED_HASH_DECLINE
        // takes the hash exit, and EVERYTHING else (SEED_CAPACITY_DECLINE or a
        // value outside the grammar) takes the capacity exit — whose consumer
        // moves to the next candidate, which is sound for any unexpected value.
        try a.cmpRegImm32(.rax, @intCast(trace.NativeSeedCtx.SEED_OK));
        try a.jcc(.e, seed_ok);
        try a.cmpRegImm32(.rax, @intCast(trace.NativeSeedCtx.SEED_HASH_DECLINE));
        try a.jcc(.e, hash_l);
        try a.jmp(cap_l);
        a.bind(seed_ok);
        seed_hash_exit = hash_l;
        seed_capacity_exit = cap_l;
    }

    // [RV-1] Hoisted type guards (all first → no home is live if one fails), then the
    // hoisted slot loads. A guard failure here returns 0 without touching regs[].
    // An int slot checks TAG_INT; a `.ptr` (table) slot checks TAG_HEAP (its
    // table-type + lane are verified below, after the pointer is loaded).
    for (alloc.slots) |s| {
        if (s.class == .write_only) continue;
        const tag: u8 = switch (s.kind) {
            .ptr, .func, .native => TAG_HEAP, // all invariant heap pointers
            // A carried-heap slot enters holding a table (TAG_HEAP). Its table-type/
            // metatable facts are NOT hoisted here — the dynamic in-body guard_table
            // re-checks the CURRENT table every iteration (doc 22 §A.1).
            .heap => TAG_HEAP,
            .float => TAG_FLOAT,
            else => TAG_INT,
        };
        // tag lane: `tags[slot]` at rdi+slot (scale-1, free).
        try a.cmpByteMemImm(.rdi, @as(i32, s.slot), tag);
        try a.jcc(.ne, prologue_fail);
    }
    for (alloc.slots) |s| {
        if (s.class == .write_only) continue;
        // payload lane: `payloads[slot]` at rsi+slot*8 (scale-8, free).
        const off: i32 = @as(i32, s.slot) * 8;
        switch (slotHomePlace(s)) {
            .reg => |r| try a.movRegMem(r, .rsi, off),
            .xmm => |x| try a.movsdRegMem(x, .rsi, off), // float slot: load the double
            .mem => |d| {
                // GP/spill raw 8-byte load (int/bool/ptr, and a spilled float — bits
                // are bits, so a spilled float reuses the raw round-trip).
                try a.movRegMem(.rax, .rsi, off);
                try a.movMemReg(.rsp, d, .rax);
            },
        }
    }
    // [C2-prologue] For each `.ptr` table slot the pointer is now in its home; verify
    // the object is a table and its array lane matches the recorded lane — once, here,
    // since neither changes within a native run (the read path never widens). A miss
    // returns 0 (regs[] untouched). The bool-lane is the only lane proveKinds admits.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .ptr) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, TABLE_TYPE);
        try a.jcc(.ne, prologue_fail);
        // [chunk 2a] The table must have NO metatable: recording aborted on a
        // metatable-bearing table, so a trace that reached here only models raw
        // array access. If `setmetatable` added one between trace entries, the
        // raw load/store would skip `__index`/`__newindex` — so side-exit to
        // tier-0 (full dispatch) when `metatable != null`. Checked once in the
        // prologue: a metamethod call is a trace barrier, so the metatable cannot
        // change *within* a single native run.
        try a.cmpQwordMemImm8(preg, METATABLE_OFF, 0);
        try a.jcc(.ne, prologue_fail);
        // Lane check only for array-accessed tables (s.lane >= 0). A hash-only table
        // (H1: href, no aref) has no pinned lane — skip it; the type + metatable checks
        // above already cover the hash path's validity, and the cell pointer was
        // resolved + validated per-entry by seedTraceInputs.
        if (s.lane >= 0) {
            try a.cmpByteMemImm(preg, ArrLayout.array_base + ArrLayout.lane, @intCast(s.lane));
            try a.jcc(.ne, prologue_fail);
        }
        // Grid table (doc 14): the lane check above already proved `array.lane ==
        // .grid` (s.lane == GRID_LANE). Additionally pin the cell element lane and the
        // row stride the recorder folded — gcell's flat-index math uses `stride` as an
        // immediate and gload/gstore use the `grid_elem` width, both sound for the run
        // only if these still match. A grow/widen between entries side-exits here.
        if (s.grid_elem >= 0) {
            try a.cmpByteMemImm(preg, ArrLayout.array_base + ArrLayout.grid_elem, @intCast(s.grid_elem));
            try a.jcc(.ne, prologue_fail);
            // stride is a usize field; the recorder aborted any stride > maxInt(i32),
            // so s.grid_stride fits an imm32 and the full-width compare is exact (a
            // runtime stride grown past i32 simply won't equal it → side-exit).
            try a.movRegMem(.rax, preg, ArrLayout.array_base + ArrLayout.stride);
            try a.cmpRegImm32(.rax, s.grid_stride);
            try a.jcc(.ne, prologue_fail);
        }
    }

    // [U1-prologue] For each `.func` slot the callee pointer is now in its home;
    // verify it is a Lua closure of the recorded `Proto.id` — the cross-frame
    // snapshot guard, checked once here (the upvalue/global cell is re-resolved and
    // re-seeded each entry, so it cannot change within a single native run; a
    // `set_upval`/`set_global` in the traced region aborts recording). A miss returns
    // 0 (regs[] untouched), side-exiting to tier-0 which really pushes the call frame
    // and re-runs the iteration. Byte-identical to irinterp's `guard_func` arm: heap
    // + type==function + `closure.proto.id == aux`.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .func) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        // header.type == function (the payload is a TAG_HEAP `*GcHeader`).
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, FUNCTION_TYPE);
        try a.jcc(.ne, prologue_fail);
        // proto = [closure + CLOSURE_PROTO_OFF]; then proto.id == recorded id. rax is
        // a free scratch here (never a home); it may also BE `preg` for a spilled home
        // (refHomeBaseReg loaded the closure into rax), and overwriting it with the
        // proto pointer is fine — the closure pointer is dead after this load.
        try a.movRegMem(.rax, preg, CLOSURE_PROTO_OFF);
        try a.cmpDwordMemImm(.rax, PROTO_ID_OFF, s.func_id);
        try a.jcc(.ne, prologue_fail);
    }

    // [guard_builtin prologue] For each `.native` slot the callee pointer is now in its
    // home; verify it is a host native carrying exactly the recorded `RecordedBuiltin` tag
    // — the pure-builtin identity guard, checked once here (the upvalue/global cell is
    // re-resolved + re-seeded each entry, so it cannot change within a native run; a
    // `set_upval`/`set_global` in the traced region aborts recording). A miss returns 0
    // (regs[] untouched), side-exiting to tier-0 which really pushes the call frame and
    // re-runs the iteration. Byte-identical to irinterp's `guard_builtin` arm: heap +
    // type==native + `native.recorded == @enumFromInt(tag)`. The `recorded` field is a 2-byte
    // `?RecordedBuiltin` laid out `[payload, has_value]`, so the non-null check is the flag
    // byte == 1 and the identity check is the payload byte == tag.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .native) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        // header.type == native (the payload is a TAG_HEAP `*GcHeader`).
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, NATIVE_TYPE);
        try a.jcc(.ne, prologue_fail);
        // `recorded` non-null (flag byte == 1) AND payload ordinal == recorded tag.
        try a.cmpByteMemImm(preg, NATIVE_RECORDED_OFF + 1, 1);
        try a.jcc(.ne, prologue_fail);
        try a.cmpByteMemImm(preg, NATIVE_RECORDED_OFF, @intCast(s.recorded_tag));
        try a.jcc(.ne, prologue_fail);
    }

    // [Phase 2] Materialize the invariant array bases ONCE, now that each `.ptr` slot
    // is proven a table of the recorded lane. `data`/`present` pointers and `len` are
    // fixed for the whole native run (B5), so they live in dedicated registers and the
    // body reads them instead of re-loading `[tbreg+field]` per iteration. The table
    // pointer is fetched into a base register (its home, or rax for a spilled home);
    // each home is a callee-saved register (never rax), so it survives across the few
    // loads here. A slot with no reserved home keeps the per-iteration load.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .ptr) continue;
        if (s.data_home == null and s.present_home == null and s.len_home == null) continue;
        const tb = try refHomeBaseReg(a, s, .rax);
        if (s.data_home) |r| try a.movRegMem(r, tb, ArrLayout.array_base + ArrLayout.data);
        if (s.present_home) |r| try a.movRegMem(r, tb, ArrLayout.array_base + ArrLayout.present);
        if (s.len_home) |r| try a.movRegMem(r, tb, ArrLayout.array_base + ArrLayout.asize);
    }

    // Phase E1/E2: with a preheader marker the run-once region (instructions before
    // it) is emitted by the body loop below but lands physically *before* loop_top —
    // so the bind is deferred to the `.preheader` arm. Without a marker the whole
    // trace is the body and loop_top binds here (byte-identical to pre-E1).
    var marker_idx: ?usize = null;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .preheader) {
            marker_idx = i;
            break;
        }
    }
    if (marker_idx == null) a.bind(loop_top);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            // slot_load: hoisted to the prologue (loop-invariant). guard_int: either
            // hoisted (slot_load operand → one prologue tag-check) or a proven-int
            // derived guard that's statically redundant — both emit nothing here.
            // guard_table/guard_lane: hoisted to the prologue table checks (the lane
            // never changes within a native run) — nothing here either.
            // guard_float joins the hoisted/redundant no-ops: a guard on a slot_load is
            // the prologue TAG_FLOAT tag-check; a guard on a derived float is statically
            // discharged (proveKinds proved the kind) — both emit nothing here.
            // guard_func joins the hoisted no-ops: the closure identity check is in
            // the prologue (loop-invariant snapshot), so nothing here.
            // guard_hash (H1) joins the hoisted/redundant no-ops: the structural
            // recheck happens at entry in `seedTraceInputs` (a failed cell resolve
            // routes the entry to tier-1a, never native) and per-iteration in the
            // `hload` tag-check, so in the native body it emits nothing.
            // guard_builtin joins the hoisted no-ops: the native-identity check is in the
            // prologue (loop-invariant callee snapshot), so nothing here.
            // guard_grid/guard_stride (doc 14): the grid structural guards, hoisted to
            // the prologue grid-elem/stride checks (invariant within a native run) —
            // nothing here, exactly like guard_table/guard_lane.
            .slot_load, .guard_int, .guard_float, .guard_lane, .guard_func, .guard_builtin, .guard_grid, .guard_stride => {},
            // guard_table: hoisted no-op for invariant `.ptr` operands (prologue
            // checks). For per-iteration roots — a `.heap`-kind VALUE_LANE aload
            // result, or a carried-heap slot whose home the back-edge φ shuffle
            // refreshes (doc 22 §A.1) — emit per-iteration type + metatable checks
            // against the CURRENT table.
            .guard_table => {
                if (isDynTableRoot(kinds, alloc.slots, alloc.slot_id_of_ref, ins.a)) {
                    const tbl_reg = try refBaseReg(a, alloc, ins.a, .rax);
                    // Check GcHeader.type == TABLE_TYPE
                    try a.cmpByteMemImm(tbl_reg, HEADER_TYPE_OFF, TABLE_TYPE);
                    try jccNativeExit(a, exit_labels, i, .ne);
                    // Check Table.metatable == null (metatable field is at a
                    // known offset from *GcHeader since header is the first field).
                    try a.cmpQwordMemImm8(tbl_reg, METATABLE_OFF, 0);
                    try jccNativeExit(a, exit_labels, i, .ne);
                }
                // else: .ptr → prologue-hoisted, no-op
            },
            // guard_hash: for an invariant `.ptr`-rooted href, the seed validation
            // covers it (no-op). For a dynamically-rooted href (`.heap` aload result
            // or carried-heap slot), emit the per-iteration hash.count() check.
            .guard_hash => {
                const href_ins = t.instrs[ins.a];
                if (isDynTableRoot(kinds, alloc.slots, alloc.slot_id_of_ref, href_ins.a)) {
                    // Load the element table's *GcHeader (the href's table operand).
                    const tbl_reg = try refBaseReg(a, alloc, href_ins.a, .rax);
                    // Compare hash.count() (u32) against the recorded population.
                    try a.cmpDwordMemImm(tbl_reg, HASH_SIZE_FROM_HEADER, @intCast(ins.aux));
                    try jccNativeExit(a, exit_labels, i, .ne);
                }
                // else: .ptr → seed-validated, no-op
            },
            .konst => {
                // H1: a `.none`-kind konst is an interned heap-string href key. href
                // reads the seeded cell, not the key, so the key carries no native
                // value — emit nothing (analyze gave it a dead Loc nothing reads).
                if (kinds[i] == .none) continue;
                const bits = t.consts[@intCast(ins.aux)].payload.bits;
                switch (placeOfRef(alloc, i)) {
                    .reg => |r| try a.movRegImm64(r, @bitCast(bits)),
                    // float konst: stage the raw bits in rax, then movq into the XMM home.
                    .xmm => |x| {
                        try a.movRegImm64(.rax, @bitCast(bits));
                        try a.movqXmmReg(x, .rax);
                    },
                    .mem => |d| {
                        // int or spilled-float konst: raw 8-byte store (bits are bits).
                        try a.movRegImm64(.rax, @bitCast(bits));
                        try a.movMemReg(.rsp, d, .rax);
                    },
                }
            },
            .add, .sub, .mul, .div, .band, .bor, .bxor => {
                if (kinds[i] == .float) {
                    // float add/sub/mul/div: SSE2 path with cvtsi2sd-promoted int operands.
                    // (div is ALWAYS float here; band/bor/bxor are always int → int branch.)
                    try emitFloatBinOp(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), kinds[ins.a], placeOfRef(alloc, ins.b), kinds[ins.b]);
                } else {
                    try emitBinAlu(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
                }
            },
            .shl, .shr, .sar => {
                // Always int (proveKinds pins both operands int). Full Lua/lune semantics
                // via the branch-bracketed cl shift (emitShift); `.sar` adds the
                // sign-fill overflow leg.
                try emitShift(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
            },
            .neg, .bnot => {
                const dst = placeOfRef(alloc, i);
                const pa = placeOfRef(alloc, ins.a);
                switch (dst) {
                    .reg => |R| {
                        if (!(pa == .reg and pa.reg == R)) try placeToReg(a, R, pa);
                        if (ins.op == .neg) try a.negReg(R) else try a.notReg(R);
                    },
                    .mem => |D| {
                        if (Place.eql(pa, dst)) {
                            // In-place spilled home (win 2): neg/not via rcx round-trip
                            // (F7 has no [mem] form in this encoder).
                            try a.movRegMem(.rcx, .rsp, D);
                            if (ins.op == .neg) try a.negReg(.rcx) else try a.notReg(.rcx);
                            try a.movMemReg(.rsp, D, .rcx);
                        } else {
                            try placeToReg(a, .rax, pa);
                            if (ins.op == .neg) try a.negReg(.rax) else try a.notReg(.rax);
                            try a.movMemReg(.rsp, D, .rax);
                        }
                    },
                    .xmm => unreachable, // int neg/bnot only (float-neg is deferred)
                }
            },
            .eq, .ne, .lt, .le => {
                // proveKinds pins the operand pair to both-int or both-float; check one
                // operand to pick the path (float compare via ucomisd, int via cmp).
                if (kinds[ins.a] == .float) {
                    try emitFloatCompare(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
                } else {
                    try emitCompare(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
                }
            },
            // int_of_float: convert the float limit (in its float home) to an exact
            // i64, or side-exit. Mirrors `value.floatAsExactInt` via a cvttsd2si
            // round-trip: truncate to int, convert back, and compare for exact
            // equality. A non-integral value, an out-of-`[-2^63, 2^63)` value (whose
            // cvttsd2si yields the integer-indefinite 0x8000…), or a NaN all fail the
            // compare (NaN sets PF). The result lands in the op's int home.
            .int_of_float => {
                try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), .float);
                try a.cvttsd2siRegReg(.rax, XMM_SCRATCH0); // rax = (i64)trunc(f) or indefinite
                try a.cvtsi2sdRegReg(XMM_SCRATCH1, .rax); // back to double
                try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
                try jccNativeExit(a, exit_labels, i, .ne); // ordered & not equal → non-integral / out-of-range
                try jccNativeExit(a, exit_labels, i, .p); // unordered (NaN) → side-exit
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            // fsqrt: the inlined pure builtin. `@sqrt` ≡ `sqrtsd` bit-for-bit under the
            // default MXCSR (round-to-nearest-even, which lune never changes) — including
            // `sqrt(-0.0) = -0.0`, `sqrt(x<0) = qNaN`, `sqrt(+inf) = +inf` — so this one
            // SSE instruction reproduces the tier-1a oracle's `Value.float(@sqrt(arg))`
            // exactly. The operand is a proven float; stage it into a scratch XMM, sqrt
            // in place, then move to the float home (xmm or spill). No side-exit: a stale
            // callee is caught by the hoisted `guard_builtin`, not here.
            .fsqrt => {
                // proveKinds pinned .float or .int; an int operand promotes here.
                try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
                try a.sqrtsdRegReg(XMM_SCRATCH0, XMM_SCRATCH0);
                switch (placeOfRef(alloc, i)) {
                    .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
                    .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
                    .reg => unreachable, // a float result never homes in a GP register
                }
            },
            // fsin/fcos/pow: a mid-body callout into THE shared noinline `fmath`
            // kernel (doc 23 D4) — never an inline SSE re-derivation, so every
            // tier runs the one compiled body and bit-identity holds by
            // construction. No side-exit (total functions of proven numerics).
            .fsin, .fcos, .pow => try emitFloatCallout(a, alloc, kinds, ins, i),
            // Doc 24 D5: allocating interned-string producers — mid-body
            // callouts into the shared `stralloc` bodies. Side-exit on OOM.
            .tostr_int, .tostr_num => try emitTostrCallout(a, alloc, kinds, heap.?, ins, i, exit_labels),
            // Doc 24 D4: `#s` of a proven string — one load of the cached
            // `cp_len` (a usize field; every real string's count fits i63).
            .slen => {
                const sreg = try refBaseReg(a, alloc, ins.a, .rcx);
                try a.movRegMem(.rax, sreg, @offsetOf(string_mod.String, "cp_len"));
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            // Doc 24 D3: the allocation-budget entry guard —
            //   passes ⇔ !gc_stress ∧ object_count + A < next_gc.
            // The heap's field addresses are baked absolute (the Heap lives at
            // a stable address for the VM's lifetime; compileImpl bailed
            // without one). Value-less; an ordinary deopt exit on failure —
            // deliberately NOT chainable/hot-guard-counted (no exit PC).
            .guard_gc => {
                const h = heap.?;
                // gc_stress: a 1-byte bool (0/1). Non-zero → exit.
                try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&h.gc_stress))));
                try a.cmpByteMemImm(.rax, 0, 0);
                try jccNativeExit(a, exit_labels, i, .ne);
                // rcx = object_count + A (A is a stamped-positive i32; the sum
                // cannot wrap u64 for any real heap).
                try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&h.object_count))));
                try a.movRegMem(.rcx, .rax, 0);
                try a.addRegImm32(.rcx, @intCast(ins.aux));
                // rcx >= next_gc (unsigned) → exit.
                try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&h.next_gc))));
                try a.cmpRegMem(.rcx, .rax, 0);
                try jccNativeExit(a, exit_labels, i, .ae);
            },
            // --- hash-part field path (H1) --------------------------------------
            // href: load the loop-invariant value-cell pointer (`*Value`) from its
            // seeded slab slot `[rsi + aux*8]` into the href token's home. The cell was
            // resolved + validated once per entry by `seedTraceInputs` (writing it into
            // payload slot `ins.aux` tagged TAG_INT); the body reads it instead of
            // recomputing the hash lookup, exactly as `aref` reads an invariant base.
            .href => {
                if (isDynTableRoot(kinds, alloc.slots, alloc.slot_id_of_ref, ins.a)) {
                    // Per-iteration hash-cell resolution via call-out (the root is a
                    // `.heap`-kind aload result, or a carried-heap slot whose current
                    // table the seed cannot describe — its recorded seed, if any, is
                    // ignored). Save rdi/rsi (SoA bases) and all live caller-saved
                    // homes, call resolveHashCell, restore, check result.
                    std.debug.assert(alloc.callout_save_count != 0); // save area must be reserved
                    try emitHrefCallout(a, t, alloc, kinds, ins, i, exit_labels);
                } else {
                    // Loop-invariant: load seeded cell pointer from slab.
                    const off: i32 = @as(i32, @intCast(ins.aux)) * 8;
                    switch (placeOfRef(alloc, i)) {
                        .reg => |r| try a.movRegMem(r, .rsi, off),
                        .mem => |d| {
                            try a.movRegMem(.rax, .rsi, off);
                            try a.movMemReg(.rsp, d, .rax);
                        },
                        .xmm => unreachable, // a cell pointer is an int kind, never an XMM home
                    }
                }
            },
            // hload: a typed load from the cell. The dominating guard_hash + per-entry
            // seed validation pinned the cell's identity; here we tag-check `[cell+0]`
            // against the recorded scalar type (side-exit on a type change — the field
            // turned from int↔float or to a heap value mid-loop) and load `[cell+8]`.
            .hload => {
                const creg = try refBaseReg(a, alloc, ins.a, .rcx);
                const want_tag: u8 = if (kinds[i] == .float) TAG_FLOAT else TAG_INT;
                try a.cmpByteMemImm(creg, VALUE_TAG_OFF, want_tag);
                try jccNativeExit(a, exit_labels, i, .ne); // field type changed → drop to tier-1a/tier-0
                if (kinds[i] == .float) {
                    switch (placeOfRef(alloc, i)) {
                        .xmm => |x| try a.movsdRegMem(x, creg, VALUE_PAYLOAD_OFF),
                        .mem => |d| {
                            try a.movsdRegMem(XMM_SCRATCH0, creg, VALUE_PAYLOAD_OFF);
                            try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                        },
                        .reg => unreachable, // a float never homes in a GP register
                    }
                } else {
                    try a.movRegMem(.rax, creg, VALUE_PAYLOAD_OFF);
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                }
            },
            // hstore: overwrite the present cell in place — tag byte then payload. The
            // present-key rule (record-time abort on an absent key) guarantees the cell
            // exists and a put never grows, so this is a pure in-place 16-byte write (we
            // touch only tag+payload; the 7 padding bytes are unobservable, matching the
            // oracle's struct-assign which also leaves them undefined). int → TAG_INT +
            // 8-byte payload; float → TAG_FLOAT + `movsd`. Heap values declined (proveKinds).
            .hstore => {
                try emitHStore(a, kinds, alloc, ins);
            },
            // --- lane-aware array read path (B2, bool lane) ----------------------
            // aref: materialize idx0 = index (doc 18: identity mapping — logical key
            // IS the physical slot, no `- 1`) into the aref token's own location.
            // The table pointer is reached lazily by each consumer through `aref.a`
            // (the invariant table home), so aref itself touches only the index.
            .aref => {
                const dst = placeOfRef(alloc, i);
                const idxp = placeOfRef(alloc, ins.b);
                switch (dst) {
                    .reg => |R| {
                        try placeToReg(a, R, idxp);
                    },
                    .mem => |D| {
                        try placeToReg(a, .rax, idxp);
                        try a.movMemReg(.rsp, D, .rax);
                    },
                    .xmm => unreachable, // idx0 is an int (aref kind), never an XMM home
                }
            },
            // guard_bounds: idx0 <u asize, else side-exit. [I3] the single idx0 from aref
            // is shared by bounds/present/aload. [I4] precedes guard_present.
            .guard_bounds => {
                const aref_ins = t.instrs[ins.a];
                const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                // [Phase 2] compare against the hoisted `len` register if we have one
                // (reg-reg), else the per-iteration `[tbreg+len]` load.
                const sid = alloc.slot_id_of_ref[aref_ins.a];
                const lenhome: ?Reg = if (sid >= 0) alloc.slots[@intCast(sid)].len_home else null;
                if (lenhome) |lr| {
                    try a.cmpRegReg(ireg, lr);
                } else {
                    const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax);
                    try a.cmpRegMem(ireg, tbreg, ArrLayout.array_base + ArrLayout.asize);
                }
                try jccNativeExit(a, exit_labels, i, .ae); // idx0 >=u asize (unsigned: covers negative keys)
            },
            // guard_present: the slot must hold a value; a hole would read as nil,
            // which the int/bool kind can't hold. The hole test is lane-specific:
            //   - boolean lane: presence is in-band — the data byte is 0 for an
            //     absent slot, so `movzx rax, byte [data+idx0]; cmp; je` bails.
            //   - int/float lanes: a separate presence bitmap — `bt [present], idx0`.
            .guard_present => {
                const aref_ins = t.instrs[ins.a];
                if (aref_ins.aux == BOOL_LANE) {
                    // [Phase 2] data base from its hoisted home (or a per-iter load).
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.loadRegMemSib(.rax, datareg, ireg, 1, false, 0); // movzx rax, byte [data+idx0]
                    try a.cmpRegImm32(.rax, 0);
                    try jccNativeExit(a, exit_labels, i, .e); // byte==0 → hole → side-exit
                } else {
                    // [Phase 2] present-bitmap base from its hoisted home (or per-iter load).
                    const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.btMemReg(preg, 0, ireg);
                    try jccNativeExit(a, exit_labels, i, .ae); // CF==0 → hole → side-exit
                }
            },
            // aload: decode the packed slot the aref addresses into the aload's home.
            // Both lanes reach the table through `aref.a` (the invariant table home)
            // and use rax for the data pointer + rcx for idx0 — exactly the two
            // scratch registers, no third needed (the int load's dst reuses rax).
            .aload => {
                const aref_ins = t.instrs[ins.a];
                if (ins.aux == VALUE_LANE) {
                    // Phase 2: .value-lane aload — load a 16-byte Value element,
                    // verify it's a heap ref, and extract the *GcHeader payload.
                    //
                    // data + idx0*16: SIB can't scale by 16, so shl idx0 by 4 then
                    // add data. The element is a full Value: [tag(1) pad(7) payload(8)].
                    // We check tag == TAG_HEAP then load the payload (a *GcHeader).
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    // rax = idx0; can't use ireg directly — it might be the aref's
                    // home that we must not clobber (rcx is scratch).
                    try a.movRegReg(.rax, ireg);
                    try a.shlRegImm8(.rax, 4); // rax = idx0 * 16
                    try a.addRegReg(.rax, datareg); // rax = &data[idx0] (Value*)
                    // Tag check: byte [rax + TAG_OFF] == TAG_HEAP
                    try a.cmpByteMemImm(.rax, VALUE_TAG_OFF, TAG_HEAP);
                    try jccNativeExit(a, exit_labels, i, .ne); // not heap → side-exit
                    // Load *GcHeader from payload
                    try a.movRegMem(.rax, .rax, VALUE_PAYLOAD_OFF);
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                } else {
                    // Scalar lanes: data base from hoisted home (or per-iter load).
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    if (ins.aux == F64_LANE) {
                        // f64 lane: load the raw 8-byte double at `[data + idx0*8]` into
                        // the aload's float home (an xmm reg or a spill cell). No decode —
                        // tier-0's `array.decode` for `.f64` is a raw `@bitCast`, so `movsd`
                        // moves byte-identical bits (no FP rounding in a load → 8-mode
                        // parity inherited). `lea` the element address (datareg + idx0*8)
                        // into rax, then `movsd` from `[rax]`.
                        try a.leaRegMemSib(.rax, datareg, ireg, 8, 0); // rax = &data[idx0]
                        switch (placeOfRef(alloc, i)) {
                            .xmm => |x| try a.movsdRegMem(x, .rax, 0),
                            .mem => |d| {
                                try a.movsdRegMem(XMM_SCRATCH0, .rax, 0);
                                try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                            },
                            .reg => unreachable, // a float never homes in a GP register
                        }
                    } else {
                        if (ins.aux == BOOL_LANE) {
                            // bool lane: load the in-band byte (1=false, 2=true) and decode
                            // to a clean 0/1 boolean with `byte - 1`. The dominating
                            // guard_present already proved the byte is non-zero (a hole
                            // would be 0), so the result is exactly 0 or 1.
                            try a.loadRegMemSib(.rax, datareg, ireg, 1, false, 0); // movzx rax, byte [data+idx0]
                            try a.subRegImm32(.rax, 1); // 1→0 (false), 2→1 (true)
                        } else if (ins.aux == U8_LANE) {
                            // u8 lane: zero-extend the byte element at `[data + idx0]` into a
                            // full 64-bit int (range 0..255). `movzx` (signed=false), no
                            // `sub` — this is the only point u8 diverges from the signed int
                            // lanes, and it matches `array.decode`'s zero-extend exactly.
                            try a.loadRegMemSib(.rax, datareg, ireg, 1, false, 0); // movzx rax, byte [data+idx0]
                        } else {
                            // int lane (i8…i64): sign-extend the width-byte element at
                            // `[data + idx0*w]` into a full 64-bit int.
                            const w = intLaneWidth(ins.aux);
                            try a.loadRegMemSib(.rax, datareg, ireg, w, true, 0);
                        }
                        try regToPlace(a, placeOfRef(alloc, i), .rax);
                    }
                } // close outer `else` for scalar lanes
            },
            // guard_fits (B4b): range-check the int value (`a`) against the lane's
            // signed bounds and side-exit if it would overflow. Native stores at the
            // lane width and cannot widen the lane the way tier-0 would, so a value
            // that no longer fits must drop back to tier-1a (which then widens). i64
            // holds every int → no check. The compare clobbers only rax (scratch).
            .guard_fits => {
                if (ins.aux == F64_LANE) {
                    // f64-lane guard_fits is a tier-1a-only soundness guard: every
                    // 8-byte bit pattern is a valid double and the lane never narrows,
                    // so there is nothing to range-check. The value is already proven
                    // `.float` in proveKinds. (The oracle, which runs the raw trace,
                    // still re-checks `fits` — but native f64 stores can never widen.)
                } else if (ins.aux == BOOL_LANE) {
                    // Bool-lane guard_fits is a tier-1a-only soundness guard; the
                    // value is already proven `.bool` in proveKinds, so there is
                    // nothing to range-check here.
                } else if (ins.aux == U8_LANE) {
                    // u8 lane: range-check against the *unsigned-byte* bounds
                    // `[0,255]` (NOT the i8 `[-128,127]` the width-1 signed lane
                    // would imply). The value is a full untagged int in rax; the
                    // signed `cmp`+`jcc(.l/.g)` against 0 and 255 is exact (both
                    // bounds are small positive constants, no sign-bit ambiguity).
                    try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
                    try a.cmpRegImm32(.rax, 0);
                    try jccNativeExit(a, exit_labels, i, .l); // value < 0 → side-exit (widen)
                    try a.cmpRegImm32(.rax, 255);
                    try jccNativeExit(a, exit_labels, i, .g); // value > 255 → side-exit (widen)
                } else {
                    const w = intLaneWidth(ins.aux);
                    if (w < 8) {
                        const lo: i32 = switch (w) {
                            1 => std.math.minInt(i8),
                            2 => std.math.minInt(i16),
                            4 => std.math.minInt(i32),
                            else => unreachable,
                        };
                        const hi: i32 = switch (w) {
                            1 => std.math.maxInt(i8),
                            2 => std.math.maxInt(i16),
                            4 => std.math.maxInt(i32),
                            else => unreachable,
                        };
                        try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
                        try a.cmpRegImm32(.rax, lo);
                        try jccNativeExit(a, exit_labels, i, .l); // value < lane min → side-exit (signed)
                        try a.cmpRegImm32(.rax, hi);
                        try jccNativeExit(a, exit_labels, i, .g); // value > lane max → side-exit (signed)
                    }
                }
            },
            // --- lane-aware array write path (B3 bool / B4b int) -----------------
            // astore: write the value into the slot the aref addresses.
            // `idx0` (from the aref) is shared with the dominating guard_bounds [I3].
            .astore => {
                try emitAStore(a, t, alloc, ins);
            },
            // guard_append (B5-grow): the append precondition, the grow analogue of
            // guard_bounds. Three memory-relative checks, no extra register beyond the
            // two the array path already uses (idx0 in `ireg`, table in `tbreg`):
            //   (1) idx0 == asize — the exact append successor (doc 18 D2.3: the key IS
            //       the next slot under identity mapping).
            //   (2) idx0 <u cap   — room without a realloc. `asize == idx0` from (1), so
            //       comparing idx0 (not a reloaded len) against cap is equivalent and
            //       needs no third register.
            //   (3) hash.size == 0 — the hash is empty, so tier-0's `migrateFromHash`
            //       would be a no-op; a non-empty hash means a contiguous successor
            //       could live there, so side-exit and let tier-0 handle the migrate.
            // Any miss side-exits to tier-0, which reallocs / migrates and re-enters —
            // so the on-trace append (astore_append) never allocates [determinism: the
            // realloc only ever runs as this side-exit, identically across all tiers].
            .guard_append => {
                const aref_ins = t.instrs[ins.a];
                const ireg = try refBaseReg(a, alloc, ins.a, .rcx); // idx0
                const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax); // table ptr
                try a.cmpRegMem(ireg, tbreg, ArrLayout.array_base + ArrLayout.asize);
                try jccNativeExit(a, exit_labels, i, .ne); // idx0 != asize → not the append successor
                try a.cmpRegMem(ireg, tbreg, ArrLayout.array_base + ArrLayout.cap);
                try jccNativeExit(a, exit_labels, i, .ae); // idx0 (==asize) >=u cap → would realloc
                try a.cmpDwordMemImm(tbreg, ArrLayout.hash_size, 0);
                try jccNativeExit(a, exit_labels, i, .ne); // hash non-empty → migrate possible
            },
            // alen (doc 23 D3): the `#t` fast-case border, `max(asize−1, 0)`.
            // Re-verifies the same premises tier-1a checks — hash empty,
            // presence-bitmap lane, (asize ≤ 1 ∨ present(asize−1)) — with
            // memory-operand compares mirroring guard_append, side-exiting to
            // tier-0 (which owns the general border search) on any miss. The
            // bitmap-lane test is a single unsigned range compare: the bitmap
            // lanes are exactly the contiguous ordinals `i8..u8` (pinned by a
            // comptime assert against `Lane.usesPresenceBitmap` below).
            .alen => {
                comptime {
                    for (@typeInfo(arr.Lane).@"enum".field_values) |fv| {
                        const l: arr.Lane = @enumFromInt(fv);
                        const in_range = fv >= @intFromEnum(arr.Lane.i8) and fv <= @intFromEnum(arr.Lane.u8);
                        std.debug.assert(l.scalarPresenceLane() == in_range);
                    }
                }
                const tbreg = try refBaseReg(a, alloc, ins.a, .rax); // table ptr
                try a.cmpDwordMemImm(tbreg, ArrLayout.hash_size, 0);
                try jccNativeExit(a, exit_labels, i, .ne); // hash non-empty → general border
                try a.cmpByteMemImm(tbreg, ArrLayout.array_base + ArrLayout.lane, @intFromEnum(arr.Lane.i8));
                try jccNativeExit(a, exit_labels, i, .b); // below i8 → .value/.boolean (in-band)
                try a.cmpByteMemImm(tbreg, ArrLayout.array_base + ArrLayout.lane, @intFromEnum(arr.Lane.u8));
                try jccNativeExit(a, exit_labels, i, .a); // above u8 → grid
                try a.movRegMem(.rcx, tbreg, ArrLayout.array_base + ArrLayout.asize); // rcx = asize
                const skip_presence = try a.label();
                try a.cmpRegImm32(.rcx, 1);
                try a.jcc(.be, skip_presence); // asize ≤ 1 → border 0, nothing to probe
                try a.movRegMem(.rax, tbreg, ArrLayout.array_base + ArrLayout.present);
                try a.cmpRegImm32(.rax, 0);
                try jccNativeExit(a, exit_labels, i, .e); // no bitmap allocated → side-exit
                try a.subRegImm32(.rcx, 1); // rcx = asize − 1 (the border candidate)
                try a.btMemReg(.rax, 0, .rcx); // CF = present(asize−1)
                try jccNativeExit(a, exit_labels, i, .ae); // bit clear → trailing hole → tier-0
                const done = try a.label();
                try a.jmp(done);
                a.bind(skip_presence);
                try a.xorRegReg(.rcx, .rcx); // asize ≤ 1 → border 0
                a.bind(done);
                try regToPlace(a, placeOfRef(alloc, i), .rcx);
            },
            // astore_append (B5-grow): commit one boolean to `data[asize]` and bump asize.
            // guard_append proved `idx0 == asize < cap` and an empty hash, so this is the
            // bool-lane byte store (`1=false, 2=true`, value+1 — presence is in-band)
            // followed by an in-place `inc qword [tbl+len]`. len has NO register home
            // for an append trace (the home-reservation switch skips astore_append), so
            // the table struct stays the single source of truth: the bump is immediately
            // visible to ANY later guard's side-exit, with no register→regs[] writeback.
            // Later guards DO follow in the body (the loop's index guards / continuation
            // `guard_true`), and a side-exit there is sound: that guard's snapshot resumes
            // tier-0 *past* the already-committed store, so the append + len bump happen
            // exactly once — identical to a pure tier-0 run. (Even in the degenerate case
            // where an exit were to replay the store, len is already bumped, so it lands
            // as an idempotent in-bounds overwrite of the same slot, never a 2nd append.)
            // Were len instead register-homed and flushed only at the back-edge, a
            // post-bump exit would persist a STALE len — which is precisely why len lives
            // in memory here. The realloc a full `append` would do never appears on-trace
            // — it was peeled to the guard_append side-exit.
            //
            // Register discipline: rax/rcx are scratch and are never allocation homes
            // (ALLOC_ORDER excludes them), so no operand of this op is *homed* in rax/rcx
            // — the byte store may clobber rax freely, then `refBaseReg(table, .rax)`
            // re-materializes the table pointer (a callee-saved home reg is returned
            // as-is; a spilled home is reloaded fresh into rax) for the len bump.
            .astore_append => {
                const aref_ins = t.instrs[ins.a];
                if (ins.aux == BOOL_LANE) {
                    // bool-lane byte store, identical to the in-bounds astore bool path.
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.leaRegMemSib(.rax, datareg, ireg, 1, 0); // rax = &data[idx0]
                    try placeToReg(a, .rcx, placeOfRef(alloc, ins.b)); // value 0/1 → rcx
                    try a.incReg(.rcx); // 0→1 (false), 1→2 (true)
                    try a.storeMemReg(.rax, 1, 0, .rcx); // mov byte [rax], cl
                } else {
                    // int lane (i8…i64): identical to the in-bounds astore int path —
                    // width-truncating data store (guard_fits proved it fits) followed
                    // by the presence bit. Unlike the bool byte, the presence bitmap is
                    // a *separate* write, so this is two stores; both must land before
                    // the len bump publishes the slot as live.
                    const w = intLaneWidth(ins.aux);
                    const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
                    const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.leaRegMemSib(.rax, datareg, ireg, w, 0); // rax = &data[idx0]
                    try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
                    try a.storeMemReg(.rax, w, 0, .rcx); // [rax] = (lane-width) value
                    // presence bit: bts [present], idx0. [I5] commit point for the
                    // absent→present transition (recArraySet refuses nil/out-of-lane,
                    // so this never clears). Re-materialize present base + idx0 (the
                    // data store clobbered rax/rcx if they were the fallback homes).
                    const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
                    const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
                    try a.btsMemReg(preg, 0, pireg);
                }
                // len += 1, in place in the table struct (no len_home for appends). The
                // table pointer is re-fetched into rax (the value/presence stores above
                // clobbered it). Bumping len LAST publishes the fully-written slot —
                // identical for both lanes, and the single point any later guard's
                // side-exit observes the append as already committed.
                const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax);
                try a.incMemQword(tbreg, ArrLayout.array_base + ArrLayout.asize);
            },
            // --- flattened-grid cell path (doc 14, Phase 8) ---------------------
            // garow: materialize row0 = row - 1 (the 0-based row) into the garow token's
            // home, exactly like `aref`'s idx0. The grid table is reached lazily by each
            // consumer through `garow.a`; garow itself touches only the row operand (b).
            .garow => {
                const dst = placeOfRef(alloc, i);
                const rowp = placeOfRef(alloc, ins.b);
                switch (dst) {
                    .reg => |R| {
                        try placeToReg(a, R, rowp);
                        try a.subRegImm32(R, 1);
                    },
                    .mem => |D| {
                        try placeToReg(a, .rax, rowp);
                        try a.subRegImm32(.rax, 1);
                        try a.movMemReg(.rsp, D, .rax);
                    },
                    .xmm => unreachable, // row0 is an int (aref kind), never an XMM home
                }
            },
            // gcell: materialize the FLAT cell index flat = row0*stride + (col - 1) into
            // the gcell token's home. `row0` is the garow value (a), `col` the column
            // (b), and `stride` is folded as an immediate from the grid table slot — the
            // prologue `guard_stride` proved it equals the runtime stride, so the folded
            // multiply is exact for the whole native run.
            .gcell => {
                const garow_ins = t.instrs[ins.a];
                const sid = alloc.slot_id_of_ref[garow_ins.a]; // table slot (always homed)
                const stridev: i32 = alloc.slots[@intCast(sid)].grid_stride;
                try placeToReg(a, .rax, placeOfRef(alloc, ins.a)); // rax = row0
                try a.movRegImm64(.rcx, stridev); // rcx = stride
                try a.imulRegReg(.rax, .rcx); // rax = row0*stride
                try placeToReg(a, .rcx, placeOfRef(alloc, ins.b)); // rcx = col
                try a.addRegReg(.rax, .rcx); // rax = row0*stride + col
                try a.subRegImm32(.rax, 1); // flat = row0*stride + (col - 1)
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            // guard_gcol: col in [1, stride], else side-exit. `col` is b; `stride` is
            // folded from the grid table slot (gcell.a = garow, garow.a = table slot).
            // Together with the garow's guard_bounds (row0 <u rows) this proves the flat
            // index lands inside the `cap*stride` buffer.
            .guard_gcol => {
                const gcell_ins = t.instrs[ins.a];
                const garow_ins = t.instrs[gcell_ins.a];
                const sid = alloc.slot_id_of_ref[garow_ins.a];
                const stridev: i32 = alloc.slots[@intCast(sid)].grid_stride;
                const colreg = try refBaseReg(a, alloc, ins.b, .rcx);
                try a.cmpRegImm32(colreg, 1);
                try jccNativeExit(a, exit_labels, i, .l); // col < 1 → side-exit (≤0 / grow)
                try a.cmpRegImm32(colreg, stridev);
                try jccNativeExit(a, exit_labels, i, .g); // col > stride → side-exit (grow)
            },
            // guard_gpresent: the cell must hold a value (a hole decodes as nil, which
            // the int cell kind can't carry). `bt [present], flat` against the per-cell
            // presence bitmap, indexed by the gcell flat index.
            .guard_gpresent => {
                const gcell_ins = t.instrs[ins.a];
                const garow_ins = t.instrs[gcell_ins.a];
                const preg = try arrayFieldReg(a, alloc, garow_ins.a, .present, .rax);
                const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
                try a.btMemReg(preg, 0, flatreg);
                try jccNativeExit(a, exit_labels, i, .ae); // CF==0 → hole → side-exit
            },
            // gload: load the grid cell at the flat index (gcell value) and decode by the
            // grid_elem width into the gload's home. Int lanes sign-extend (zero-extend
            // u8) into a GP home (matching `array.decodeGridCell`); the f64 lane `movsd`s
            // the raw 8-byte double at `[data + flat*8]` into an XMM/spill float home —
            // no decode/rounding (decodeGridCell for `.f64` is a raw `@bitCast`, so the
            // bits move byte-identically, 8-mode parity inherited). Mirrors the aload arm.
            .gload => {
                const gcell_ins = t.instrs[ins.a];
                const garow_ins = t.instrs[gcell_ins.a];
                const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
                const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
                if (ins.aux == F64_LANE) {
                    try a.leaRegMemSib(.rax, datareg, flatreg, 8, 0); // rax = &data[flat]
                    switch (placeOfRef(alloc, i)) {
                        .xmm => |x| try a.movsdRegMem(x, .rax, 0),
                        .mem => |d| {
                            try a.movsdRegMem(XMM_SCRATCH0, .rax, 0);
                            try a.movsdMemReg(.rsp, d, XMM_SCRATCH0);
                        },
                        .reg => unreachable, // a float never homes in a GP register
                    }
                } else if (ins.aux == U8_LANE) {
                    try a.loadRegMemSib(.rax, datareg, flatreg, 1, false, 0); // movzx
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                } else {
                    const w = intLaneWidth(ins.aux);
                    try a.loadRegMemSib(.rax, datareg, flatreg, w, true, 0); // sign-extend
                    try regToPlace(a, placeOfRef(alloc, i), .rax);
                }
            },
            // gstore: write the cell at the flat index, then set the presence bit LAST
            // (the absent→present commit point). An int lane does a width-truncating
            // store (guard_fits proved the value fits grid_elem); the f64 lane stages
            // the value into a scratch XMM and `movsd`s the raw double at `[data+flat*8]`
            // (full-width, no truncation — `encodeGridCell` for `.f64` is a raw
            // `@bitCast`, so the bits commit byte-identically). Mirrors the in-bounds
            // `astore` int / f64 paths.
            .gstore => {
                try emitGStore(a, t, alloc, ins);
            },
            .guard_true => switch (kinds[ins.a]) {
                .int => {}, // every int is truthy → guard always passes (no-op)
                .bool => {
                    switch (placeOfRef(alloc, ins.a)) {
                        .reg => |r| try a.cmpRegImm32(r, 0),
                        .mem => |d| try a.cmpQwordMemImm8(.rsp, d, 0),
                        .xmm => unreachable, // a bool is never homed in an XMM
                    }
                    try jccNativeExit(a, exit_labels, i, .e); // false (0) → side-exit
                },
                .none, .ptr, .aref, .float, .func, .href, .native, .heap => unreachable, // proveKinds restricts to int/bool
            },
            .guard_false => switch (kinds[ins.a]) {
                .int => try jmpNativeExit(a, exit_labels, i), // an int is never falsy → always side-exit
                .bool => {
                    switch (placeOfRef(alloc, ins.a)) {
                        .reg => |r| try a.cmpRegImm32(r, 0),
                        .mem => |d| try a.cmpQwordMemImm8(.rsp, d, 0),
                        .xmm => unreachable, // a bool is never homed in an XMM
                    }
                    try jccNativeExit(a, exit_labels, i, .ne); // true (≠0) → side-exit
                },
                .none, .ptr, .aref, .float, .func, .href, .native, .heap => unreachable, // proveKinds restricts to int/bool
            },
            .loop => {
                // [RV-2] write-only slots commit to regs[] BEFORE the shuffle, so the
                // shuffle can't clobber a write-only source that aliases a carried home.
                for (alloc.slots) |s| {
                    if (s.class != .write_only) continue;
                    // Commit the value at its store_ref location (the slot has no home).
                    // flushSlot tags by kind (TAG_FLOAT + movsd for a float store).
                    try flushSlot(a, @as(i32, s.slot), s.kind, placeOfRef(alloc, @intCast(s.store_ref)));
                }
                // PHI shuffle: carried home(slot) <- store_ref location. A win-2
                // coalesced slot already updated its home in place (the move would be a
                // self-move), so it is dropped from the parallel move entirely.
                var nmoves: usize = 0;
                for (alloc.slots) |s| {
                    if (s.class == .carried and !s.coalesced) nmoves += 1;
                }
                // Internal φs (Phase E2): each updates its computed home from its
                // back-edge value `b` in this same parallel shuffle — the move set
                // spans both register files, so a φ↔slot cycle is broken correctly.
                for (t.instrs) |p| {
                    if (p.op == .phi and p.aux == trace.PHI_INTERNAL) nmoves += 1;
                }
                const moves = try gpa.alloc(Move, nmoves);
                defer gpa.free(moves);
                const done = try gpa.alloc(bool, nmoves);
                defer gpa.free(done);
                var mi: usize = 0;
                for (alloc.slots) |s| {
                    if (s.class != .carried or s.coalesced) continue;
                    moves[mi] = .{
                        .dst = slotHomePlace(s),
                        .src = placeOfRef(alloc, @intCast(s.store_ref)),
                        .is_float = s.kind == .float,
                    };
                    mi += 1;
                }
                for (t.instrs, 0..) |p, pi| {
                    if (p.op != .phi or p.aux != trace.PHI_INTERNAL) continue;
                    moves[mi] = .{
                        .dst = placeOfRef(alloc, pi), // the φ's computed home
                        .src = placeOfRef(alloc, @intCast(p.b)), // its back-edge update
                        .is_float = kinds[pi] == .float,
                    };
                    mi += 1;
                }
                try emitParallelMove(a, moves, done);
                try a.incReg(.rbx);
                try a.jmp(loop_top);
            },
            .link => {
                // A link-terminated continuation is a one-shot hand-off, not a loop
                // back-edge. Flush every slot-bound φ snapshot directly into regs[]
                // so the linked inner root sees exactly the same entry state as the
                // tier-1a `.link` arm's `flushPhiWriteback`.
                for (alloc.slots) |s| {
                    if (s.store_ref < 0) continue;
                    try flushSlot(a, @as(i32, s.slot), s.kind, placeOfRef(alloc, @intCast(s.store_ref)));
                }
                try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
                try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), @intCast(i));
                if (shared_exit != null) {
                    const silent = try a.label();
                    patch_emissions[i] = .{ .kind = .link_terminal, .patch_off = a.code.items.len, .epilogue = silent };
                    try a.nop5();
                }
                // 2.3c-2a: record this `.link` transition (chain source C→I) before the
                // handoff. `exit_instr` = i is now in memory; `exit_reason` is the inherited
                // `.normal`.
                try emitLedgerAppend(a, t.id, .link_terminal);
                // Chainable: the `.link` terminal is a single-contract hand-off, so
                // its exit jumps through slot[i] (default `shared_exit`, armed → child).
                try emitReturn(a, frame, callee[0..callee_len], shared_exit, t.id, slotAddr(slots, i));
            },
            // A φ emits no code in the body: a slot-bound φ's writeback is driven by
            // its slot's `.carried`/`.write_only` class above (the back-edge shuffle /
            // deopt flush read `store_ref`, which was set from this φ's `b` in
            // `analyzeInner`). An internal φ's home is seeded at the `.preheader` arm
            // and updated in the back-edge shuffle — also nothing here.
            .phi => {},
            // Phase E1/E2: the preheader marker. The run-once region (instructions
            // before it) was just emitted by the loop above, physically ahead of
            // loop_top. Seed each internal φ's computed home from its init (a run-once
            // value, already materialized), then bind loop_top so everything below
            // repeats each iteration. A preheader-less trace bound loop_top earlier.
            .preheader => {
                for (t.instrs, 0..) |p, pi| {
                    if (p.op != .phi or p.aux != trace.PHI_INTERNAL) continue;
                    try movePlace(a, placeOfRef(alloc, pi), placeOfRef(alloc, @intCast(p.a)));
                }
                a.bind(loop_top);
            },
            else => unreachable, // proveKinds rejected everything else
        }
    }

    // Per-guard side-exit stubs. Each writes the deterministic failing IR index, RESOLVES
    // its dispatch target into the memory-staged `NativeResult.exit_target`, then jumps to
    // the shared single-snapshot flush (`deopt_exit`), which flushes carried homes, writes
    // `completed`, and jumps `qword [rdx+exit_target]` (2.3c-0). The resolved target lives
    // in a `*NativeResult` field (not a register) because `flushSlot`'s spilled-payload
    // path clobbers rax — a register-staged holder would not survive the flush.
    //
    // Ordinary guard: resolve THROUGH its OWN `slot[ei]` (deref it now — arming only
    // happens between native runs, so the value is stable across the flush) — default
    // `shared_exit` (byte-identical to 2.1's direct jump), armed to a child body entry in
    // 2.3c-1. Loop-done guard: the `linked_loop_done != 0` case jumps to the linked-
    // materialized stub (mode 1); the ORDINARY fallthrough (mode 0) must bypass `slot[ei]`
    // — that slot is EXCLUSIVELY the linked exit (P-C option (b) invariant) — so it
    // resolves directly to `shared_exit`.
    for (exit_labels, 0..) |maybe_l, ei| {
        if (maybe_l) |l| {
            a.bind(l);
            try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), @intCast(ei));
            if (isNumericForLoopDoneGuard(t, ei)) {
                try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 0);
                try a.jcc(.ne, try nativeLinkedLoopDoneLabel(a, linked_loop_done_labels, ei));
                // mode 0 (ordinary loop-done deopt): bypass slot[ei] → `shared_exit`.
                if (shared_exit) |se| {
                    try a.movRegImm64(.rax, @bitCast(@as(u64, se)));
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                }
            } else if (shared_exit) |se| {
                if (isCompositeBridgeCandidate(t, ei)) {
                    // Part A-v: generic edge-4 bridge stub. The slot remains
                    // `shared_exit` throughout A-v, so execution always branches to
                    // `ordinary_mini`; the armed body is dead scaffolding until A-vii.
                    const ordinary_mini = try a.label();

                    // Stub head: unarmed slots take today's ordinary deopt path.
                    try a.movRegImm64(.rax, @bitCast(@as(u64, slotAddr(slots, ei).?)));
                    try a.movRegMem(.rax, .rax, 0);
                    try a.movRegImm64(.rcx, @bitCast(@as(u64, se)));
                    try a.cmpRegReg(.rax, .rcx);
                    try a.jcc(.e, ordinary_mini);

                    // Cap check FIRST, before any VM-state or result mutation beyond
                    // the legacy exit_instr write above. Reserve two ledger cells:
                    // this bridge receipt and the successor's terminal receipt.
                    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "ledger_len"));
                    try a.cmpRegImm32(.rax, @intCast(irinterp.LEDGER_CAP - 2));
                    try a.jcc(.a, ordinary_mini);

                    try emitCompositeBridgeSnapshot(a, t, kinds, alloc, ei);
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
                    const silent = try a.label();
                    patch_emissions[ei] = .{ .kind = .region_bridge, .patch_off = a.code.items.len, .epilogue = silent };
                    try a.nop5();
                    try emitLedgerAppend(a, t.id, .region_bridge);

                    // Re-resolve after the snapshot/append clobbered scratch regs,
                    // stage in the flush-immune result field, then hand off directly.
                    try a.movRegImm64(.rax, @bitCast(@as(u64, slotAddr(slots, ei).?)));
                    try a.movRegMem(.rax, .rax, 0);
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                    try a.jmpMem(.rdx, @offsetOf(NativeResult, "exit_target"));

                    // Shared fallback for BOTH unarmed and ledger-full cases. This is
                    // VM-state/output-equivalent to the pre-A-v mini-stub.
                    a.bind(ordinary_mini);
                    try a.movRegImm64(.rax, @bitCast(@as(u64, se)));
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                } else {
                    // Non-candidate ordinary guard: preserve the exact pre-A-v
                    // emission — resolve through its own slot (deref → stage).
                    try a.movRegImm64(.rax, @bitCast(@as(u64, slotAddr(slots, ei).?)));
                    try a.movRegMem(.rax, .rax, 0);
                    try a.movMemReg(.rdx, @offsetOf(NativeResult, "exit_target"), .rax);
                }
            }
            if (shared_exit != null and !isNumericForLoopDoneGuard(t, ei) and !isCompositeBridgeCandidate(t, ei)) {
                const silent = try a.label();
                patch_emissions[ei] = .{ .kind = .deopt, .patch_off = a.code.items.len, .epilogue = silent };
            }
            try a.jmp(deopt_exit);
        }
    }

    // LINKED_LOOP_DONE_EXIT: only used by `runLinkedLoopDone`. The ordinary native
    // side-exit path leaves the failing iteration for tier-0 replay; a native link
    // chain consumes the post-loop continuation instead, so it must commit the
    // post-guard stores and phi snapshot before returning.
    for (linked_loop_done_labels, 0..) |maybe_l, ei| {
        if (maybe_l) |l| {
            a.bind(l);
            try emitLinkedLoopDoneSnapshot(a, t, kinds, alloc, ei);
            try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
            if (shared_exit != null) {
                const silent = try a.label();
                patch_emissions[ei] = .{ .kind = .loop_done_linked, .patch_off = a.code.items.len, .epilogue = silent };
                try a.nop5();
            }
            // 2.3c-2a: record this loop-done transition (chain source I→C once 2.3c-2c
            // arms slot[ei]) before the handoff. `exit_instr` = ei was written into memory
            // by the mini-stub (its `jne` reached here); `exit_reason` is `.normal`.
            try emitLedgerAppend(a, t.id, .loop_done_linked);
            // Chainable: the linked-loop-done stub commits the post-guard state, then
            // hands off through slot[ei] (default `shared_exit`, armed → continuation).
            try emitReturn(a, frame, callee[0..callee_len], shared_exit, t.id, slotAddr(slots, ei));
        }
    }

    // DEOPT_EXIT: the single snapshot flush. Write each carried home back to regs[]
    // — invariant + write-only slots are already coherent. Then write `completed`
    // to the native result out-param and return.
    a.bind(deopt_exit);
    for (alloc.slots) |s| {
        if (s.class != .carried) continue;
        // Re-box the carried home with its kind's tag: int homes write TAG_INT from a
        // GP reg / spill cell; a float home writes TAG_FLOAT + `movsd` from its XMM
        // (a register-homed float can't go through `movMemReg`). flushSlot dispatches.
        try flushSlot(a, @as(i32, s.slot), s.kind, slotHomePlace(s));
    }
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    // 2.3c-2a: record this ordinary / loop-done-ordinary transition. The mini-stub wrote
    // `exit_instr` = ei into memory and staged `exit_target` (its own `slot[ei]`, which
    // 2.3c-1 can arm to a child, making THIS a chain source too); `exit_reason` is
    // `.normal`. The append clobbers rax/rcx but not the memory-staged `exit_target` the
    // dispatch below reads. Precedes the final_trace_id stamp — harmless, `t.id` is the
    // same value we pass as the ledger id.
    try emitLedgerAppend(a, t.id, .deopt);
    // P-B: stamp the final trace id. `emitReturn` normally does this, but here the
    // dispatch target is the resolved value the mini-stub already staged into
    // `exit_target` (its own `slot[ei]`'s value, or `shared_exit` for a loop-done
    // ordinary exit), not a fixed address baked in this shared block — so inline the id
    // stamp + dispatch.
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(t.id));
    if (shared_exit) |se| {
        // 2.3c-0: frameless — dispatch through the memory-staged resolved target. The
        // mini-stub wrote `exit_target` BEFORE the flush ran, so the flush's rax clobber
        // (spilled-payload path) cannot destroy it. An unarmed ordinary `slot[ei]` holds
        // `shared_exit` (byte-identical to 2.1's direct jump); 2.3c-1 arms it to a child
        // body entry. 2.3c-2c: load the resolved target into rax and apply the forced-yield
        // cap (redirects an armed source-branch dispatch to `shared_exit` when the ledger is
        // full) before jumping.
        try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "exit_target"));
        try emitForcedYieldCheck(a, se);
        try a.jmpReg(.rax);
    } else {
        // Self-framed test page: no slot table, no shared trampoline — tear down the
        // per-trace frame and `ret` exactly as before (mini-stubs staged nothing here).
        try emitTeardown(a, frame, callee[0..callee_len]);
    }

    // PROLOGUE_FAIL: a hoisted type guard failed before this body committed any
    // iteration of its OWN loop. regs[] is untouched (the cut-1 EXIT would have
    // flushed half-initialized homes) and there is no per-body guard identity, so
    // `exit_instr = -1`. Not chainable outward (no child makes sense before the first
    // committed iteration), so it jumps straight to `shared_exit`.
    //
    // S3 (doc 17, 2.3b): write `completed = rbx`, NOT the literal 0. When this body
    // is entered fresh via the trampoline (`xor rbx,rbx`) — the only way it is
    // reached today, since nothing arms a link — rbx is provably 0 here (no `.loop`
    // back-edge `inc rbx` runs before the hoisted guards), so this is byte-identical
    // to the old `completed = 0`. Once a native parent `jmp`s into this body under
    // the shared frame (armed link, 2.3b), rbx already holds the PARENT's cumulative
    // iteration count; committing `rbx` here preserves that progress instead of
    // erasing it, so `completed = 0` at a chained child's entry-guard failure can no
    // longer wipe the chain's committed work. `movMemReg` is a full 64-bit store
    // (matching `deopt_exit`), so the `usize` field is fully written, not just its
    // low half.
    a.bind(prologue_fail);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), -1);
    // 2.3c-0b: stamp the reason so a consumer distinguishes THIS (native prologue-fail,
    // no local progress) from a tier-1a clean completion — both otherwise show
    // `exit_instr == maxInt`. Only this stub writes a non-`.normal` reason.
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(irinterp.ExitReason.prologue_fail));
    // 2.3c-2a: record the prologue-fail as the terminal transition. `exit_instr` = -1 and
    // `exit_reason` = `.prologue_fail` are in memory; a chained child's entry-guard failure
    // after the parent committed thus shows up in the ledger with its own `trace_id` and
    // zero local progress. Terminal (jumps to `shared_exit`), so it is always the LAST
    // ledger entry — never a chain source, no cap needed.
    try emitLedgerAppend(a, t.id, .prologue_fail);
    try emitReturn(a, frame, callee[0..callee_len], shared_exit, t.id, null);

    // SEED DECLINE exits (doc 22 §B.2): the entry seed prologue's callout declined
    // before the body ran — cloned from `prologue_fail` above (same pre-commit
    // shape: `completed = rbx` preserves a fused predecessor's cumulative progress,
    // no guard identity so `exit_instr = -1`, reason stamped BEFORE the ledger
    // append so `emitLedgerAppend`'s memory reads see it, terminal so always the
    // LAST ledger entry — never a chain source, no cap needed). Two distinct
    // reasons because the consumers differ: a hash decline reruns THIS entry on
    // tier-1a (slab already holds the VM-seeding-equivalent state, including the
    // 0-bits cell slot); a capacity decline moves to the next candidate (nothing
    // was written). Present iff the seed prologue is (same `plan.nonEmpty()` gate).
    if (seed_hash_exit) |hash_l| {
        a.bind(hash_l);
        try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), -1);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(irinterp.ExitReason.seed_hash_decline));
        try emitLedgerAppend(a, t.id, .seed_hash_decline);
        try emitReturn(a, frame, callee[0..callee_len], shared_exit, t.id, null);

        a.bind(seed_capacity_exit.?);
        try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_instr"), -1);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "exit_reason"), @intFromEnum(irinterp.ExitReason.seed_capacity_decline));
        try emitLedgerAppend(a, t.id, .seed_capacity_decline);
        try emitReturn(a, frame, callee[0..callee_len], shared_exit, t.id, null);
    }

    // B-3a: all silent epilogues live out of line in this same allocation. Their
    // metadata cells are null and no patch targets them yet, so they are unreachable
    // while the feature is off. Each kind's state materialization precedes its patch
    // point; ordinary deopt duplicates the shared carried-home flush here.
    if (shared_exit) |se| {
        for (patch_emissions, 0..) |maybe, ei| if (maybe) |em| {
            a.bind(em.epilogue);
            if (em.kind == .deopt) {
                for (alloc.slots) |s| {
                    if (s.class != .carried) continue;
                    try flushSlot(a, @as(i32, s.slot), s.kind, slotHomePlace(s));
                }
                try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
            }
            try emitSilentEpilogue(a, em.kind, &metadata_cells[ei], se, t.id);
        };
    }

    // LINKED_ENTRY (doc 17, 2.3b-0): a secondary entry point for an armed native
    // `.link`-terminal handoff. A parent whose slot is armed into THIS trace targets
    // this stub instead of `body_entry` so a numeric-for loop-done inside this body
    // materializes in linked mode (commit the final iteration + phi snapshot, then
    // hand to its continuation) exactly as `runLinkedLoopDone` sets up. It presets
    // `linked_loop_done = 1` — `movMemImm32` is REX.W `C7 /0` (`mov qword …, imm32`,
    // sign-extended), so it stores the FULL u64 = 1, matching the reader
    // (`cmpQwordMemImm8 … , 0; jne`, a full-width nonzero test) — then falls through to
    // `body_entry` (which snapshots `entry_rbx` and runs the hoisted guards). Emitted
    // only on the frameless production path; self-framed test pages never chain, so
    // their `linked_entry` stays `null`. INERT until 2.3b-1 arms a slot to it.
    var stubs = EntryStubs{};
    // §B.4 record: the prologue was emitted iff its decline labels exist. Both
    // secondary entries below `jmp body_entry`, so a seeded page seeds on EVERY
    // entry kind — this bit is entry-kind-independent by construction.
    stubs.seed_prologue = seed_hash_exit != null;
    if (shared_exit != null) {
        const linked_entry = try a.label();
        a.bind(linked_entry);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 1);
        try a.jmp(body_entry);
        stubs.linked_entry = a.labelOffset(linked_entry);

        // ORDINARY_ENTRY (doc 17, 2.3c-0): the dual of `linked_entry`. Presets
        // `linked_loop_done = 0` then falls into `body_entry`. A fused handoff inherits
        // the shared `NativeResult.linked_loop_done`, which `linked_entry` may have left
        // at 1; the inner→continuation slot (2.3c-2) targets THIS entry so the
        // continuation runs in ordinary mode regardless of the flag it inherited.
        // `movMemImm32` is REX.W (`C7 /0`, sign-extended) → full u64 = 0, matching the
        // full-width reader. INERT until 2.3c-2 arms a slot to it.
        const ordinary_entry = try a.label();
        a.bind(ordinary_entry);
        try a.movMemImm32(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 0);
        try a.jmp(body_entry);
        stubs.ordinary_entry = a.labelOffset(ordinary_entry);
    }
    return stubs;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The test suite lives in sibling `*_test.zig` files (split by theme). Zig only
// analyses a file that is reachable by import, so this block is what makes them
// run under `zig build test`.

test {
    _ = @import("nativegen_core_test.zig");
    _ = @import("nativegen_float_test.zig");
    _ = @import("nativegen_lowering_test.zig");
    _ = @import("nativegen_arrayread_test.zig");
    _ = @import("nativegen_arraywrite_test.zig");
    _ = @import("nativegen_carriedheap_test.zig");
}
