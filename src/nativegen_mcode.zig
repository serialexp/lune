//! Executable-memory plumbing for tier-1b native codegen (split from
//! `nativegen.zig`, file-split pass): the `ExecPage` handle, the standalone
//! `mapExecutable`, and the shared `McodeArena` — LuaJIT-style co-located
//! mcode regions (W^X: RW only while a compile writes a slot) and the
//! frameless trampoline.
//!
//! x86-64/Linux only at runtime; every OS-specific reference
//! (`std.posix.mmap`, `mprotect`) sits behind a
//! `comptime !is_x64_linux` gate, so other targets (wasm) prune it.

const std = @import("std");
const builtin = @import("builtin");
const x64 = @import("x64.zig");

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
        return @ptrCast(@alignCast(self.code.ptr));
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

/// A shared, contiguous machine-code arena — the mahina analogue of LuaJIT's
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
    const LivePage = struct { region: u32, offset: usize };

    gpa: std.mem.Allocator,
    regions: std.ArrayListUnmanaged(Region) = .empty,
    /// Invariant: `capacity >= len + live_pages.count()`, reserved by `alloc`,
    /// so `free` never allocates — a collection retiring a batch of compiled
    /// traces frees their pages without touching the allocator (doc 61 §7.1).
    free_list: std.ArrayListUnmanaged(FreeBlock) = .empty,
    /// Pages handed out and not yet freed, keyed by their unique generation:
    /// `free` validates and removes in O(1) (a linear scan made a batch
    /// retirement of D pages O(D·P) — codex Phase Q review).
    live_pages: std.AutoHashMapUnmanaged(u64, LivePage) = .empty,
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
        if (comptime !is_x64_linux) return error.UnsupportedTarget;
        const prot: std.posix.PROT = if (exec)
            .{ .READ = true, .EXEC = true }
        else
            .{ .READ = true, .WRITE = true };
        switch (std.posix.errno(std.posix.system.mprotect(mem.ptr, mem.len, prot))) {
            .SUCCESS => {},
            else => return error.MprotectFailed,
        }
    }

    /// Flip only the page-aligned window of `mem` covering `[off, off+len)`.
    /// An mprotect's direct cost scales with the range (PTE rewrite + per-page
    /// TLB invalidation), and flipping unrelated pages RX→RW→RX additionally
    /// forces instruction refetch for every other trace co-located in the
    /// 1 MiB region, so the window stays proportional to the bytes actually
    /// written. (Runtime code patching is gone since doc 55 §2d; the silent
    /// switch is a data cell. Only compile-time allocation writes code now.)
    fn protectWindow(mem: []align(page_align) u8, off: usize, len: usize, exec: bool) MapError!void {
        if (comptime !is_x64_linux) return error.UnsupportedTarget;
        const page = std.heap.pageSize();
        const start = std.mem.alignBackward(usize, off, page);
        // Region lengths are page-rounded at map time, so the clamp only
        // guards the theoretical last-page overshoot of alignForward.
        const end = @min(std.mem.alignForward(usize, off + len, page), mem.len);
        const window: []align(page_align) u8 = @alignCast(mem[start..end]);
        return protectRegion(window, exec);
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
        // Reserve before any mutation: the new live entry, and free-list room
        // for every live page (including this one) to come back without
        // allocating (see `free_list`).
        try self.live_pages.ensureUnusedCapacity(self.gpa, 1);
        try self.free_list.ensureTotalCapacity(self.gpa, self.free_list.items.len + self.live_pages.count() + 1);

        // 1. First-fit reuse of a retired slot.
        for (self.free_list.items, 0..) |fb, i| {
            if (fb.cap >= cap) {
                const region_mem = self.regions.items[fb.region].mem;
                try protectWindow(region_mem, fb.offset, code.len, false);
                @memcpy(region_mem[fb.offset..][0..code.len], code);
                try protectWindow(region_mem, fb.offset, code.len, true);
                const generation = self.takePageGeneration();
                self.live_pages.putAssumeCapacityNoClobber(generation, .{ .region = fb.region, .offset = fb.offset });
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
        try protectWindow(region.mem, off, code.len, false);
        @memcpy(region.mem[off..][0..code.len], code);
        try protectWindow(region.mem, off, code.len, true);
        const generation = self.takePageGeneration();
        self.live_pages.putAssumeCapacityNoClobber(generation, .{ .region = region_idx, .offset = off });
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

    /// Return a slot to the free-list. O(1) and allocation-free (the free-list
    /// room was reserved when the page was handed out). A stale or repeated
    /// free (generation not live, or naming a different slot) is ignored.
    pub fn free(self: *McodeArena, region: u32, offset: usize, cap: usize, generation: u64) void {
        const live = self.live_pages.get(generation) orelse return;
        if (live.region != region or live.offset != offset) return;
        _ = self.live_pages.remove(generation);
        self.free_list.appendAssumeCapacity(.{ .region = region, .offset = offset, .cap = cap });
    }
};
