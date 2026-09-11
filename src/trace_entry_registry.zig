//! VM-local patched bytecode images and stable entry-patch slots.
//!
//! This is the physical owner of entry patch storage and mutation. Policy
//! (qualification, drain ordering, and lifecycle routing) remains in the trace
//! coordinator. The registry has no coordinator back-reference.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const trace_record = @import("trace_record.zig");
const trace_code = @import("trace_code.zig");

const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const Trace = trace_record.TraceRecord;

pub const EntryPatch = struct {
    trace: *Trace,
    trace_id: u32,
    proto: *const Proto,
    patch_pc: u32,
    orig: Instr,
    /// The op written into the image (doc 44 codex round 1: a first-class
    /// field, never re-derived from `orig` — a head patch overwrites an
    /// ARBITRARY pc-0 instruction, so `patchedEntryOp(orig.op)` is null
    /// for it and only the loop kinds can re-derive).
    patched_op: OpCode,
    live: bool = true,
    pending_unpatch: bool = false,
    tombstone: bool = false,
    strikes: u8 = 0,
    seed_count: u32,
    /// Doc 45 D6.1 (native safety net, one-shot flavor): the `cache_gen` at
    /// which a FULL, non-truncated `enterPatchedTrace` walk declined EVERY
    /// candidate at this anchor as native-unsupported (under
    /// `native_codegen`), with no steering fired. While it matches the live
    /// `cache_gen`, `opJFuncHead`/`opJCont` tail-dispatch the canonical
    /// tier-0 instruction without walking — the patch stays installed (an
    /// unpatch would churn: `maybeRepatchHead`/`maybeRepatchCont` reinstall
    /// without a native-support check), but per-call cost drops to one
    /// compare. Any commit/retirement bumps `cache_gen` and naturally
    /// invalidates the memo, so a later native-capable sibling re-enables
    /// the walk. 0 = no memo (`cache_gen` is never 0).
    native_decline_gen: u32 = 0,
};

pub const InstallResult = union(enum) {
    installed,
    no_patch_pc,
    incumbent: u16,
    capacity,
    oom,
};

pub const EntryRegistry = struct {
    gpa: std.mem.Allocator,
    code_images: std.AutoHashMapUnmanaged(*const Proto, []Instr) = .empty,
    image_gen: u64 = 0,
    entry_patches: std.ArrayListUnmanaged(*EntryPatch) = .empty,
    entry_patch_free: std.ArrayListUnmanaged(u16) = .empty,
    /// Owner-internal work counter; advance via `markEntryPatchPending` /
    /// `markInstallPending`, consume via `takeDirty` — never write directly.
    entry_patch_dirty: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) EntryRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EntryRegistry) void {
        self.dropEntryPatchState();
        self.code_images.deinit(self.gpa);
        self.entry_patches.deinit(self.gpa);
        self.entry_patch_free.deinit(self.gpa);
    }

    pub inline fn codeFor(self: *const EntryRegistry, proto: *const Proto) []const Instr {
        if (self.code_images.count() == 0) return proto.code;
        return self.code_images.get(proto) orelse proto.code;
    }

    pub fn ensureImage(self: *EntryRegistry, proto: *const Proto) ![]Instr {
        const gop = try self.code_images.getOrPut(self.gpa, proto);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.gpa.dupe(Instr, proto.code) catch |err| {
                self.code_images.removeByPtr(gop.key_ptr);
                return err;
            };
            self.image_gen +%= 1;
        }
        return gop.value_ptr.*;
    }

    pub fn patchedEntryOp(op: OpCode) ?OpCode {
        return switch (op) {
            .for_loop => .jfor_loop,
            .jmp, .jmp_if_false, .tfor_loop => .jloop,
            else => null,
        };
    }

    pub fn resolvePatchPc(proto: *const Proto, anchor_pc: u32) ?u32 {
        // Doc 44: a function-head anchor patches the callee's pc 0 (the
        // LuaJIT FUNCF→JFUNCF analogue) — no back-edge scan applies. A
        // continuation anchor (D12b) patches its resume pc directly.
        switch (trace_code.anchorKind(anchor_pc)) {
            .head => return 0,
            .cont => {
                const pc = trace_code.entryPc(anchor_pc);
                return if (pc < proto.code.len) pc else null;
            },
            .loop => {},
        }
        var found: ?u32 = null;
        for (proto.code, 0..) |ins, i| {
            if (patchedEntryOp(ins.op) == null) continue;
            const target: i64 = @as(i64, @intCast(i + 1)) + ins.aux;
            if (target == anchor_pc and target <= @as(i64, @intCast(i))) {
                if (found != null) return null;
                found = @intCast(i);
            }
        }
        return found;
    }

    /// Fully initializes a stable slot before publishing its index in the image.
    pub fn installEntryPatch(self: *EntryRegistry, t: *Trace) InstallResult {
        std.debug.assert(t.entry_slot == null);
        const patch_pc = resolvePatchPc(t.code.anchor.proto, t.code.anchor.pc) orelse return .no_patch_pc;
        const img = self.ensureImage(t.code.anchor.proto) catch return .oom;
        const orig = t.code.anchor.proto.code[patch_pc];
        const patched_op: OpCode = switch (trace_code.anchorKind(t.code.anchor.pc)) {
            .head => .jfunc_head,
            .cont => .jcont,
            .loop => patchedEntryOp(orig.op) orelse unreachable,
        };
        if (img[patch_pc].op == .jfor_loop or img[patch_pc].op == .jloop or
            img[patch_pc].op == .jfunc_head or img[patch_pc].op == .jcont)
            return .{ .incumbent = img[patch_pc].b };

        const idx: u16 = if (self.entry_patch_free.pop()) |free_idx|
            free_idx
        else blk: {
            if (self.entry_patches.items.len > std.math.maxInt(u16)) return .capacity;
            const p = self.gpa.create(EntryPatch) catch return .oom;
            self.entry_patches.append(self.gpa, p) catch {
                self.gpa.destroy(p);
                return .oom;
            };
            break :blk @intCast(self.entry_patches.items.len - 1);
        };
        var seed_count: u32 = t.code.anchor.proto.num_registers;
        for (t.code.inputs) |seed| seed_count = @max(seed_count, @as(u32, seed.slot) + 1);
        const p = self.entry_patches.items[idx];
        p.* = .{
            .trace = t,
            .trace_id = t.id,
            .proto = t.code.anchor.proto,
            .patch_pc = patch_pc,
            .orig = orig,
            .patched_op = patched_op,
            .seed_count = seed_count,
        };
        t.entry_slot = idx;
        var patched = orig;
        patched.op = patched_op;
        patched.b = idx;
        img[patch_pc] = patched;
        self.image_gen +%= 1;
        return .installed;
    }

    pub fn markEntryPatchPending(self: *EntryRegistry, idx: u16) void {
        const p = self.entry_patches.items[idx];
        if (p.tombstone or p.pending_unpatch) return;
        p.live = false;
        p.pending_unpatch = true;
        self.entry_patch_dirty += 1;
    }

    /// Mark a qualified trace for install at the next safe-point drain: the
    /// record transition and the dirty bump are one owner operation, so no
    /// caller ever advances `entry_patch_dirty` by hand.
    pub fn markInstallPending(self: *EntryRegistry, t: *Trace) void {
        t.entry_patch = .pending;
        self.entry_patch_dirty += 1;
    }

    /// Consume the drain request: returns false on a quiet turn (one load),
    /// true after zeroing the counter — the caller then owns this drain.
    pub fn takeDirty(self: *EntryRegistry) bool {
        if (self.entry_patch_dirty == 0) return false;
        self.entry_patch_dirty = 0;
        return true;
    }

    /// Physical restore and retirement. `live_records` is explicit so this owner
    /// can resolve identity and wake waiters without depending on a coordinator.
    pub fn unpatchSlot(self: *EntryRegistry, idx: u16, live_records: []const *Trace) void {
        const p = self.entry_patches.items[idx];
        if (self.code_images.get(p.proto)) |img| {
            std.debug.assert(img[p.patch_pc].op == p.patched_op and img[p.patch_pc].b == idx);
            std.debug.assert(std.meta.eql(p.orig, p.proto.code[p.patch_pc]));
            img[p.patch_pc] = p.orig;
        }
        for (live_records) |t| {
            if (t.id == p.trace_id) {
                t.entry_slot = null;
                if (t.entry_patch == .bound) t.entry_patch = .eligible;
                break;
            }
        }
        p.live = false;
        p.pending_unpatch = false;
        p.tombstone = true;
        for (live_records) |t| switch (t.entry_patch) {
            .suppressed_capacity => t.entry_patch = .eligible,
            .suppressed_incumbent => if (t.entry_patch_incumbent == idx) {
                t.entry_patch = .eligible;
            },
            else => {},
        };
        self.entry_patch_free.append(self.gpa, idx) catch {};
    }

    pub fn dropEntryPatchState(self: *EntryRegistry) void {
        var it = self.code_images.valueIterator();
        while (it.next()) |img| self.gpa.free(img.*);
        self.code_images.clearRetainingCapacity();
        for (self.entry_patches.items) |p| self.gpa.destroy(p);
        self.entry_patches.clearRetainingCapacity();
        self.entry_patch_free.clearRetainingCapacity();
        self.entry_patch_dirty = 0;
        self.image_gen +%= 1;
    }
};

test "entry owner publishes metadata before dispatch and retires without dead record" {
    const testing = std.testing;
    var registry = EntryRegistry.init(testing.allocator);
    defer registry.deinit();
    var code = [_]Instr{ Instr.op0(.ret), .{ .op = .for_loop, .aux = -2 } };
    const proto = Proto{ .code = &code, .id = 1, .name = "owner", .num_registers = 4 };
    var record = Trace{ .id = 17, .code = undefined };
    record.code.anchor = .{ .proto = &proto, .pc = 0 };
    record.code.inputs = &.{};
    try testing.expectEqual(InstallResult.installed, registry.installEntryPatch(&record));
    const slot = record.entry_slot.?;
    const patch = registry.entry_patches.items[slot];
    try testing.expectEqual(@as(u32, 17), patch.trace_id);
    try testing.expectEqual(@as(u32, 4), patch.seed_count);
    try testing.expectEqual(OpCode.jfor_loop, registry.codeFor(&proto)[1].op);
    try testing.expectEqual(slot, registry.codeFor(&proto)[1].b);
    try testing.expectEqual(OpCode.for_loop, code[1].op);
    registry.markEntryPatchPending(slot);
    registry.markEntryPatchPending(slot);
    try testing.expectEqual(@as(u32, 1), registry.entry_patch_dirty);
    try testing.expect(!patch.live);
    // Retired record is absent: restore must not dereference the saved pointer.
    patch.trace = undefined;
    registry.unpatchSlot(slot, &.{});
    try testing.expect(patch.tombstone);
    try testing.expectEqual(OpCode.for_loop, registry.codeFor(&proto)[1].op);
    record.entry_slot = null;
    try testing.expectEqual(InstallResult.installed, registry.installEntryPatch(&record));
    try testing.expectEqual(patch, registry.entry_patches.items[record.entry_slot.?]);
}

test "entry owner allocation refusal leaves canonical dispatch and no binding" {
    const testing = std.testing;
    var storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    var registry = EntryRegistry.init(allocator.allocator());
    defer registry.deinit();
    var code = [_]Instr{ Instr.op0(.ret), .{ .op = .for_loop, .aux = -2 } };
    const proto = Proto{ .code = &code, .id = 1, .name = "oom", .num_registers = 4 };
    var record = Trace{ .code = undefined };
    record.code.anchor = .{ .proto = &proto, .pc = 0 };
    record.code.inputs = &.{};
    try testing.expectEqual(InstallResult.oom, registry.installEntryPatch(&record));
    try testing.expectEqual(@as(?u16, null), record.entry_slot);
    try testing.expectEqual(@as(usize, 0), registry.entry_patches.items.len);
    try testing.expectEqual(proto.code.ptr, registry.codeFor(&proto).ptr);
}

test "cont entry patch (doc 44 D12b): install writes .jcont at the resume pc, unpatch restores, cross-kind incumbents exclude" {
    const testing = std.testing;
    var registry = EntryRegistry.init(testing.allocator);
    defer registry.deinit();
    var code = [_]Instr{ Instr.op0(.ret), .{ .op = .add, .a = 1 }, Instr.op0(.ret) };
    const proto = Proto{ .code = &code, .id = 1, .name = "cont", .num_registers = 4 };
    var record = Trace{ .id = 21, .code = undefined };
    record.code.anchor = .{ .proto = &proto, .pc = trace_code.contAnchorPc(1) };
    record.code.inputs = &.{};
    try testing.expectEqual(InstallResult.installed, registry.installEntryPatch(&record));
    const slot = record.entry_slot.?;
    const patch = registry.entry_patches.items[slot];
    try testing.expectEqual(@as(u32, 1), patch.patch_pc);
    try testing.expectEqual(OpCode.jcont, patch.patched_op);
    try testing.expectEqual(OpCode.jcont, registry.codeFor(&proto)[1].op);
    try testing.expectEqual(slot, registry.codeFor(&proto)[1].b);
    // Canonical code untouched (copy-on-patch image only).
    try testing.expectEqual(OpCode.add, code[1].op);
    // One patch per physical pc: a second cont trace at the SAME resume pc is
    // an incumbent, not a second install.
    var record2 = Trace{ .id = 22, .code = undefined };
    record2.code.anchor = .{ .proto = &proto, .pc = trace_code.contAnchorPc(1) };
    record2.code.inputs = &.{};
    try testing.expectEqual(InstallResult{ .incumbent = slot }, registry.installEntryPatch(&record2));
    // Unpatch restores the canonical instruction in the image.
    registry.markEntryPatchPending(slot);
    registry.unpatchSlot(slot, &.{});
    try testing.expectEqual(OpCode.add, registry.codeFor(&proto)[1].op);
    // An out-of-bounds cont resume pc refuses cleanly.
    var record3 = Trace{ .id = 23, .code = undefined };
    record3.code.anchor = .{ .proto = &proto, .pc = trace_code.contAnchorPc(99) };
    record3.code.inputs = &.{};
    try testing.expectEqual(InstallResult.no_patch_pc, registry.installEntryPatch(&record3));
}
