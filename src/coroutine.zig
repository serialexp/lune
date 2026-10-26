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

const Vm = interp.Vm;
const CallFrame = interp.CallFrame;
const Value = value.Value;

/// One stack's memory. Large enough allocations come from mmap on every
/// real backing allocator, so pages commit only when touched.
pub const Stack = struct {
    tags: []u8,
    payloads: []u64,
    /// `Vm.boundary_scratch` for this stack: absolute-indexed like the
    /// lanes, so it can't be shared between stacks (a native that re-enters
    /// Lua may resume a coroutine while its own scratch region is live).
    boundary_scratch: []Value,
    frames: *[interp.max_call_depth]CallFrame,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Stack {
        const tags = try gpa.alloc(u8, interp.stack_slots);
        errdefer gpa.free(tags);
        const payloads = try gpa.alloc(u64, interp.stack_slots);
        errdefer gpa.free(payloads);
        const boundary_scratch = try gpa.alloc(Value, interp.stack_slots);
        errdefer gpa.free(boundary_scratch);
        const frames = try gpa.create([interp.max_call_depth]CallFrame);
        return .{ .tags = tags, .payloads = payloads, .boundary_scratch = boundary_scratch, .frames = frames };
    }

    pub fn deinit(self: Stack, gpa: std.mem.Allocator) void {
        gpa.free(self.tags);
        gpa.free(self.payloads);
        gpa.free(self.boundary_scratch);
        gpa.destroy(self.frames);
    }
};

/// The `Vm` fields that belong to the running stack. Each field has the name
/// and type of a `Vm` field (checked below), and `save`/`load` copy every one,
/// so adding a per-stack field here is the whole change.
///
/// Not saved, because a switch only happens where they are idle (asserted in
/// `assertSwitchable`): `reg_top_pending`, `pending_error`, `unparked_native`.
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
    native_reentry_depth: u16 = 0,

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

test "save then load restores every per-stack field" {
    const gpa = std.testing.allocator;
    var vm = try Vm.initBare(gpa);
    defer vm.deinit();
    vm.depth = 3;
    vm.stack_top = 40;
    vm.reg_top = 12;
    vm.open_upvalue_ceiling = 7;
    vm.native_reentry_depth = 2;
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
    try std.testing.expectEqual(@as(u16, 2), vm.native_reentry_depth);
    try std.testing.expectEqual(main.tags.ptr, vm.tags.ptr);
}
