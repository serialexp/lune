//! Coroutine stacks and execution contexts (doc 73 §5.1).
//!
//! Every coroutine runs on its own `Stack`: the two register lanes, the
//! native-boundary scratch lane and the call-frame array, each allocated once
//! and never moved, so open upvalue cells and frame pointers into a suspended
//! stack stay valid. The main program runs on the VM's own `Stack`.
//!
//! The running stack's state lives in `Vm`'s own fields, so the interpreter's
//! hot path reads it directly. A switch saves those fields into the outgoing
//! context's `SavedContext` and loads the incoming one's (`save`/`load`).

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const object = @import("object.zig");
const gc = @import("gc.zig");
const stack_mem = @import("stack_mem.zig");

const Vm = interp.Vm;
const CallFrame = interp.CallFrame;
const Value = value.Value;
const GcHeader = object.GcHeader;

/// Doc 73: a coroutine whose body is a native runs it from a frame of this
/// function (`Vm.nativeBodyProto`), called with the native and the first
/// resume's values, so the native is called from Lua: a `coroutine.yield`
/// or `pcall` body switches and protects exactly as it would from Lua code.
/// To Lua the frame is the native itself (`Vm.isNativeBodyFrame`).
pub const native_body_source: [:0]const u8 = "return function(f, ...) return f(...) end";

/// The reserved proto id of that function, which keyframes name it by: at
/// the top of the id space (the compiler's counter ends one past it), far
/// above any program's or loaded chunk's.
pub const native_body_proto_id: u32 = std.math.maxInt(u32) - 1;

comptime {
    // The resumable natives' activations (doc 68 §5.1) take the ids below
    // this one's chunk (its root is `native_body_proto_id - 1`).
    std.debug.assert(@import("native_act.zig").first_id < native_body_proto_id - 1);
}

/// One stack's memory: a single block (`stack_mem`) holding the two register
/// lanes, the scratch lane and the frame array, each region starting on a
/// block-aligned offset.
pub const Stack = struct {
    block: stack_mem.Block,
    tags: []u8,
    payloads: []u64,
    /// `Vm.boundary_scratch` for this stack: absolute-indexed like the
    /// lanes, so it can't be shared between stacks (a native that re-enters
    /// Lua may resume a coroutine while its own scratch region is live).
    boundary_scratch: []Value,
    frames: *[interp.max_call_depth]CallFrame,

    const region_align = stack_mem.block_align.toByteUnits();
    const scratch_at = 0;
    const payloads_at = std.mem.alignForward(usize, scratch_at + interp.stack_slots * @sizeOf(Value), region_align);
    const tags_at = std.mem.alignForward(usize, payloads_at + interp.stack_slots * @sizeOf(u64), region_align);
    const frames_at = std.mem.alignForward(usize, tags_at + interp.stack_slots, region_align);
    const block_size = std.mem.alignForward(usize, frames_at + @sizeOf([interp.max_call_depth]CallFrame), region_align);
    /// GC pacing units a coroutine's stack is charged while held (doc 73):
    /// the memory even a shallow coroutine keeps committed, one page in
    /// each of the four regions, so dropped suspended coroutines bring the
    /// next collection forward. A deeper stack holds more than this.
    pub const gc_units = stack_mem.committedFloor(block_size, 4) / gc.nominal_object_bytes;

    comptime {
        std.debug.assert(region_align >= @alignOf(Value) and region_align >= @alignOf(CallFrame));
    }

    /// A stack in a freshly allocated block.
    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Stack {
        return carve(try gpa.alignedAlloc(u8, stack_mem.block_align, block_size));
    }

    /// A coroutine's stack: a block from the heap's pool when it has one.
    /// A pooled block holds what its last coroutine left; nothing reads a
    /// slot or frame the new one hasn't written.
    pub fn acquire(heap: *gc.Heap) std.mem.Allocator.Error!Stack {
        const s = if (heap.stack_pool.take()) |b| carve(b) else try init(heap.gpa);
        heap.chargeStack(gc_units);
        return s;
    }

    /// Give a coroutine's stack back to the heap's pool.
    pub fn release(self: Stack, heap: *gc.Heap) void {
        heap.refundStack(gc_units);
        heap.stack_pool.put(heap.gpa, self.block);
    }

    pub fn deinit(self: Stack, gpa: std.mem.Allocator) void {
        gpa.free(self.block);
    }

    fn carve(block: stack_mem.Block) Stack {
        std.debug.assert(block.len == block_size);
        return .{
            .block = block,
            .boundary_scratch = @as([*]Value, @ptrCast(@alignCast(block.ptr + scratch_at)))[0..interp.stack_slots],
            .payloads = @as([*]u64, @ptrCast(@alignCast(block.ptr + payloads_at)))[0..interp.stack_slots],
            .tags = block[tags_at..][0..interp.stack_slots],
            .frames = @ptrCast(@alignCast(block.ptr + frames_at)),
        };
    }
};

/// A coroutine: Lua's `thread` value. Its stack exists from creation until it
/// dies; while it isn't running, `saved` holds that stack's state.
pub const Thread = struct {
    header: GcHeader,
    /// Freed when the coroutine dies, so a dead coroutine that stays
    /// reachable holds no stack.
    stack: ?Stack,
    saved: SavedContext,
    status: Status = .suspended,
    /// The function the coroutine runs; consumed by the first resume.
    body: Value,
    /// Who resumed it, while it runs or is `normal` (null = the main stack).
    resumer: ?*Thread = null,
    /// The error that killed it, kept for `coroutine.close`.
    death: ?Value = null,
    /// While it runs or is `normal`: where its resume's results land in the
    /// resumer's stack (the call's base slot) and how many the call wants.
    ret_lo: usize = 0,
    ret_c: u16 = 0,
    /// While it runs or is `normal`: resumed by its `coroutine.wrap`
    /// function, so its results land without resume's leading `true`, and
    /// an error that kills it is raised again in the resumer. Set for a
    /// resume from Zig too (`wrapSync`), where `runSync` places the results
    /// itself; there it tells a debug session the error goes on (doc 86
    /// §5.4).
    wrapped: bool = false,
    /// While suspended at a yield: where the next resume's values land (the
    /// yield call's base slot) and how many the call wants.
    yield_lo: usize = 0,
    yield_c: u16 = 0,
    /// `Vm.native_reentry_depth` when it was last resumed. It can yield only
    /// while no Zig frame has been entered since (`Vm.canYield`).
    reentry_base: u16 = 0,
    /// `Vm.native_reentry_depth` when it last resumed another coroutine, for
    /// `coroutine.isyieldable` while it is `normal`.
    reentry_at_resume: u16 = 0,
    /// Resumed from Zig (`Vm.resumeSync`) rather than by an instruction.
    /// Its yielded values wait at `xfer_lo` (`xfer_n` of them) for it.
    sync: bool = false,
    xfer_lo: usize = 0,
    xfer_n: usize = 0,

    pub const Status = enum(u8) {
        /// Not started, or stopped at a yield.
        suspended,
        running,
        /// Resumed another coroutine and waits for it.
        normal,
        dead,
    };

    pub fn create(heap: *gc.Heap, body: Value) std.mem.Allocator.Error!*Thread {
        const self = try heap.gpa.create(Thread);
        errdefer heap.gpa.destroy(self);
        const stack = try Stack.acquire(heap);
        self.* = .{ .header = GcHeader.init(.thread), .stack = stack, .saved = SavedContext.fresh(stack), .body = body };
        return self;
    }

    /// Release the stack once the coroutine can't run again.
    pub fn releaseStack(self: *Thread, heap: *gc.Heap) void {
        if (self.stack) |s| {
            self.saved.open_upvalues.deinit(heap.gpa);
            self.saved.open_upvalues = .empty;
            s.release(heap);
            self.stack = null;
        }
    }

    pub fn destroy(self: *Thread, heap: *gc.Heap) void {
        self.releaseStack(heap);
        heap.gpa.destroy(self);
    }

    pub fn fromHeader(h: *GcHeader) *Thread {
        std.debug.assert(h.type == .thread);
        // `@alignCast` for wasm32, as in `File.fromHeader`.
        return @alignCast(@fieldParentPtr("header", h));
    }
};

/// Allocate a coroutine running `body` and register it with the heap.
pub fn newThread(heap: *gc.Heap, body: Value) std.mem.Allocator.Error!*Thread {
    const t = try Thread.create(heap, body);
    heap.linkThread(&t.header);
    return t;
}

/// The main program's `thread` value (`coroutine.running()`): no stack, its
/// status follows whether a coroutine runs.
pub fn newMainThread(heap: *gc.Heap) std.mem.Allocator.Error!*Thread {
    const t = try heap.gpa.create(Thread);
    t.* = .{ .header = GcHeader.init(.thread), .stack = null, .saved = undefined, .status = .running, .body = Value.nil() };
    heap.linkThread(&t.header);
    return t;
}

/// A coroutine shell for keyframe restore (`keyframeser`): with a fresh
/// stack when `has_stack`; the restorer fills in the rest.
pub fn createRestored(heap: *gc.Heap, has_stack: bool) std.mem.Allocator.Error!*Thread {
    if (has_stack) return Thread.create(heap, Value.nil());
    const t = try heap.gpa.create(Thread);
    t.* = .{ .header = GcHeader.init(.thread), .stack = null, .saved = undefined, .body = Value.nil() };
    return t;
}

pub const thread_ops: gc.ThreadOps = .{ .blacken = blackenThread, .destroy = destroyThread };

fn blackenThread(heap: *gc.Heap, h: *GcHeader) void {
    const t = Thread.fromHeader(h);
    heap.markValue(t.body);
    if (t.death) |d| heap.markValue(d);
    if (t.resumer) |r| heap.markHeader(&r.header);
    // The running coroutine's stack is the VM's own, walked as a root; a
    // stack that isn't running waits for the VM (`Vm.walkSavedStacks`).
    if (t.stack != null and t.status != .running) heap.threads_to_walk.appendAssumeCapacity(h);
}

fn destroyThread(heap: *gc.Heap, h: *GcHeader) void {
    Thread.fromHeader(h).destroy(heap);
}

/// The `Vm` fields that belong to the running stack. Each field has the name
/// and type of a `Vm` field (checked below), and `save`/`load` copy every one,
/// so adding a per-stack field here is the whole change.
///
/// Not saved, because a switch only happens where they are idle (asserted in
/// `assertSwitchable`): `reg_top_pending`, `pending_error`, `unparked_native`.
/// `native_reentry_depth` counts Zig frames across every stack, since they
/// all share the one Zig stack it bounds.
pub const SavedContext = struct {
    tags: []u8,
    payloads: []u64,
    boundary_scratch: []Value,
    frames: *[interp.max_call_depth]CallFrame,
    depth: u32 = 0,
    stack_top: usize = 0,
    reg_top: usize = 0,
    open_upvalues: std.ArrayList(interp.OpenUpvalue) = .empty,
    open_upvalue_ceiling: usize = 0,
    final_cut: ?interp.FinalCut = null,

    /// A fresh, empty context over `stack`.
    pub fn fresh(stack: Stack) SavedContext {
        return .{
            .tags = stack.tags,
            .payloads = stack.payloads,
            .boundary_scratch = stack.boundary_scratch,
            .frames = stack.frames,
        };
    }
};

const context_fields = @typeInfo(SavedContext).@"struct".field_names;

comptime {
    for (context_fields) |name| {
        if (!@hasField(Vm, name)) @compileError("SavedContext." ++ name ++ " is not a Vm field");
        if (@FieldType(Vm, name) != @FieldType(SavedContext, name)) @compileError("SavedContext." ++ name ++ " has a different type from Vm." ++ name);
    }
}

/// Copy the running stack's state out of `vm`.
pub fn save(vm: *const Vm, into: *SavedContext) void {
    inline for (context_fields) |name| @field(into, name) = @field(vm, name);
}

/// Make `from` the running stack's state.
pub fn load(vm: *Vm, from: *const SavedContext) void {
    inline for (context_fields) |name| @field(vm, name) = @field(from, name);
}

/// The fields `SavedContext` leaves out must be idle at a switch.
pub fn assertSwitchable(vm: *const Vm) void {
    std.debug.assert(!vm.reg_top_pending);
    std.debug.assert(vm.pending_error == null);
    std.debug.assert(vm.unparked_native == null);
}

/// Where context `t`'s state is kept while it isn't running (null = the main
/// stack).
pub fn savedOf(vm: *Vm, t: ?*Thread) *SavedContext {
    return if (t) |x| &x.saved else &vm.main_saved;
}

/// Make context `to` (null = the main stack) the running one, keeping the
/// running one's state.
pub fn switchTo(vm: *Vm, to: ?*Thread) void {
    assertSwitchable(vm);
    std.debug.assert(to != vm.current);
    save(vm, savedOf(vm, vm.current));
    load(vm, savedOf(vm, to));
    vm.current = to;
}

test "save then load restores every per-stack field" {
    const gpa = std.testing.allocator;
    var vm = try Vm.initBare(gpa);
    defer vm.deinit();
    vm.depth = 3;
    vm.stack_top = 40;
    vm.reg_top = 12;
    vm.open_upvalue_ceiling = 7;
    var main: SavedContext = undefined;
    save(&vm, &main);

    const other = try Stack.init(gpa);
    defer other.deinit(gpa);
    const fresh = SavedContext.fresh(other);
    load(&vm, &fresh);
    try std.testing.expectEqual(@as(u32, 0), vm.depth);
    try std.testing.expectEqual(other.tags.ptr, vm.tags.ptr);
    try std.testing.expectEqual(other.frames, vm.frames);

    load(&vm, &main);
    try std.testing.expectEqual(@as(u32, 3), vm.depth);
    try std.testing.expectEqual(@as(usize, 40), vm.stack_top);
    try std.testing.expectEqual(@as(usize, 12), vm.reg_top);
    try std.testing.expectEqual(@as(usize, 7), vm.open_upvalue_ceiling);
    try std.testing.expectEqual(main.tags.ptr, vm.tags.ptr);
}
