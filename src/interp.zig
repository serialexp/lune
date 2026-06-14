//! Tier-0 interpreter — executes register bytecode (`bytecode.zig`).
//!
//! This is the **correctness oracle** for the whole engine: the IR-interpreter
//! (tier-1a) and native codegen (tier-1b) are validated by differential testing
//! *against* this tier (docs/design/00-architecture.md §Testing strategy). So it
//! is written for clarity and obvious-correctness, not speed: a plain
//! `while (true) switch (op)` dispatch loop.
//!
//! Phase 0 proved that guaranteed tail calls (`@call(.always_tail)`) work on the
//! pinned toolchain (LLVM backend), which is the *threaded-dispatch* speed-up we
//! can graft onto this loop later if tier-0 dispatch ever shows up in a profile.
//! It deliberately does not here — tier-0 is the slow, always-correct tier, and
//! a switch is easier to read, extend, and trust as the oracle.
//!
//! The interpreter is built up across the Phase 3 increments. Opcodes whose
//! runtime support has not landed yet return `error.Unimplemented` rather than
//! silently misbehaving.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;

/// Runtime errors surfaced to the host. A superset of `arith.Error` so pure
/// numeric ops coerce in with a bare `try`.
pub const Error = error{
    /// Operand had the wrong type for an operation (e.g. `nil + 1`).
    TypeError,
    /// Integer `//` or `%` by zero.
    DivisionByZero,
    /// An opcode whose runtime support has not been implemented yet.
    Unimplemented,
    /// Call/register stack exhausted, or tier-0's native-recursion guard tripped.
    StackOverflow,
    /// A native (host) function failed with an error outside the known set.
    HostError,
    /// Allocation failure (register stack, future heap).
    OutOfMemory,
};

/// Fixed VM register/call stack: every frame's register window is a slice of
/// this one buffer. It is allocated once and **never reallocated**, so a slice
/// handed to one frame stays valid while a nested call runs above it. 64Ki
/// `Value` slots = 1 MiB.
const stack_slots: usize = 1 << 16;

/// Maximum call depth for the tier-0 interpreter. `exec` runs on an explicit
/// `Vm.frames` call-stack array of this fixed size (no host-stack recursion per
/// Lua call), so this bounds how deep a Lua program may recurse before we report
/// `StackOverflow` — `pushFrame` is the single guard. Tier-0 is the correctness
/// oracle, not the deep-recursion tier.
const max_call_depth: u32 = 200;

/// One built-in native: the global name it installs under and its function.
pub const BaseNative = struct { name: []const u8, func: function.NativeFn };

/// The single source of truth for built-in natives. `installBaseLib` installs
/// every entry into a fresh VM's globals, and the keyframe restorer
/// (`keyframeser.zig`) looks a serialized native up here by name to rebind it —
/// so a native added here is automatically both installable and restorable, and
/// the two paths can never diverge. The serialized form of a `Native` is just its
/// name (`keyframeser.toSchemaHeapObject`), which is meaningful only against this
/// registry. Currently just `print`; `tostring`, `type`, … attach here.
pub const base_natives = [_]BaseNative{
    .{ .name = "print", .func = &nativePrint },
};

/// Result of running one frame: the `count` return values live at
/// `regs[reg .. reg + count]` of that frame's window (i.e. `stack[base + reg]`).
const FrameResult = struct { reg: u16, count: u16 };

/// An open upvalue: a cell still pointing at the live stack slot `index`. Tracked
/// so that two closures capturing the same variable share one cell, and so the
/// cell can be *closed* (detached) when its slot is about to be freed. Public so
/// the keyframe restorer (`keyframeser.zig`) can rebuild the open-upvalue list.
pub const OpenUpvalue = struct { index: usize, cell: *function.Upvalue };

/// One active call frame in the **explicit** VM call stack. Tier-0 no longer
/// recurses on the host stack; instead `exec` runs an iterative loop over a
/// `frames[0..depth]` array, each entry carrying everything needed to (a) run the
/// frame, (b) return its results into its parent, and (c) be **captured and
/// resumed mid-execution** (the keyframe records `pc`/`base`/return-wiring per
/// frame). Windows stack contiguously upward: `frames[i+1].base == frames[i].base
/// + frames[i].closure.proto.num_registers`.
pub const CallFrame = struct {
    /// The closure executing in this frame (its proto = code/constants/upvalues).
    closure: *const Closure,
    /// Register-window start: this frame's registers are `stack[base .. base+nreg]`.
    base: usize,
    /// Resumable cursor: index of the next instruction in `closure.proto.code`.
    pc: usize = 0,
    /// Where this frame's results land in its **parent's** window, as a
    /// caller-relative register (the call instruction's `a`). Unused for the
    /// bottom frame (no parent — `run` consumes its `FrameResult` directly).
    ret_dest: u16 = 0,
    /// How many results the parent wants (the call instruction's `c`). Unused for
    /// the bottom frame.
    ret_count: u16 = 0,
};

/// The outcome of an `exec` run: either the bottom frame returned (carrying the
/// top-level `FrameResult`), or a mid-execution suspend point was hit (all VM
/// state left intact and capturable). `suspended` is only ever returned when
/// `suspend_ctl` is armed (a test / future debugger hook); `run` leaves it null.
pub const ExecOutcome = union(enum) { finished: FrameResult, suspended };

/// Mid-execution suspend trigger (test / debugger hook; null = never suspend, the
/// normal `run` path). At each dispatch-loop safepoint, `exec` suspends the first
/// time both conditions hold: at least `after_safepoints` safepoints have elapsed
/// **and** the live call depth is `>= min_depth`. The depth gate lets a test
/// capture *inside a nested call* (`min_depth = 2`) rather than at an arbitrary
/// point; the safepoint count lets it capture mid-loop in a single frame.
pub const SuspendCtl = struct { min_depth: u32 = 0, after_safepoints: u64 = 0 };

/// The tier-0 virtual machine. Owns the resources a running program needs that
/// outlive a single frame: the object heap, the global table, and the shared
/// register/call stack.
pub const Vm = struct {
    gpa: std.mem.Allocator,
    /// The object heap (strings, tables, closures, …). Owns every heap value a
    /// running program produces; freed wholesale by `deinit`.
    heap: gc.Heap,
    /// The global environment: a table keyed by interned name strings. Free
    /// (non-local) names read and write here; the base library installs here.
    globals: *table.Table,
    /// Shared register/call stack. Fixed-size and never reallocated (see
    /// `stack_slots`), so frame windows stay valid across nested calls.
    stack: []Value,
    /// Current call depth (number of active frames; guarded by `max_call_depth`).
    depth: u32 = 0,
    /// High-water mark of live register slots across all active frames:
    /// `stack[0 .. stack_top]` is exactly the live window the collector scans.
    /// Raised atomically with each `pushFrame` and recomputed on every pop, so it
    /// always reflects the deepest active frame (frame windows stack contiguously
    /// upward).
    stack_top: usize = 0,
    /// The **explicit** call stack: `frames[0..depth]` are the active frames,
    /// bottom (main) at index 0. Replaces host-stack recursion — `exec` loops over
    /// this array, so each frame's cursor (`pc`/`base`/return-wiring) is first-class
    /// state that the collector roots (via `forEachRootHeader`, keeping every
    /// frame's prototype constants alive) and the keyframe serializer captures for
    /// mid-execution resume. Sized to the call-depth bound, so it never allocates.
    frames: [max_call_depth]CallFrame = undefined,
    /// Open upvalues, keyed by absolute stack index. Searched on capture (to
    /// share a cell) and on scope/frame exit (to close cells over dying slots).
    open_upvalues: std.ArrayList(OpenUpvalue) = .empty,
    /// Where the `print` host-effect writes. `null` means the process's buffered
    /// stdout (`io.zig`); a test (or a future effect recorder) can point this at
    /// an in-memory writer to capture output without touching the real stdout.
    out: ?*io.Writer = null,
    /// Trace recorder state: hotness counters, the trace cache, and the
    /// in-progress recording. Disabled by default (`trace.config.enabled`), so
    /// the VM behaves exactly as before Phase 5 until `--trace` flips it on.
    /// Recording is transparent — tier-0 still executes everything.
    trace: trace.TraceState,
    /// Monotonic count of dispatch-loop safepoints reached (one per instruction
    /// boundary, before dispatch). Drives the `suspend_ctl` trigger. Free-running;
    /// GC frequency is independent of it (a collection is invisible).
    safepoint_seq: u64 = 0,
    /// Mid-execution suspend trigger, or null (never suspend — the normal path).
    /// Armed by a test / future debugger to capture a resumable keyframe.
    suspend_ctl: ?SuspendCtl = null,

    pub fn init(gpa: std.mem.Allocator) Error!Vm {
        var vm = try initBare(gpa);
        errdefer gpa.free(vm.stack);
        errdefer vm.heap.deinit();
        // The globals table lives on the heap like any other table (id 0), then
        // the base library installs (the `print` native + its interned name).
        vm.globals = try vm.heap.newTable();
        try vm.installBaseLib();
        return vm;
    }

    /// Build a VM with **no seeded heap**: an empty heap (`next_obj_id == 0`, no
    /// globals, no natives, empty interned map), an allocated register stack, and
    /// trace state — but `globals` left `undefined`. This is the substrate the
    /// keyframe restorer (`keyframeser.restoreSnapshot`) builds on: it rebuilds
    /// the globals table and the natives from the snapshot with their *original*
    /// ids, which a normally-seeded `init` would pre-occupy. `init` is exactly
    /// `initBare` + globals + base lib, so its observable behaviour (ids 0/1/2 for
    /// globals / `print` native / `"print"` string) is unchanged. The caller MUST
    /// assign `globals` before using the VM. Only fails on allocation (the stack),
    /// so the narrow error set lets the keyframe restorer keep a tight `RestoreError`.
    pub fn initBare(gpa: std.mem.Allocator) std.mem.Allocator.Error!Vm {
        const stack = try gpa.alloc(Value, stack_slots);
        errdefer gpa.free(stack);
        return Vm{
            .gpa = gpa,
            .heap = gc.Heap.init(gpa),
            .globals = undefined,
            .stack = stack,
            .trace = trace.TraceState.init(gpa),
        };
    }

    /// Frees the heap (and every object on it, including globals) and the
    /// register stack. Any `Value` returned by `run` that is a heap reference
    /// dangles after this — inspect results first.
    pub fn deinit(self: *Vm) void {
        self.trace.deinit();
        self.open_upvalues.deinit(self.gpa);
        self.heap.deinit();
        self.gpa.free(self.stack);
    }

    /// Install the built-in globals (the host-effect boundary) from the single
    /// `base_natives` registry — the same table the keyframe restorer reads to
    /// rebind a serialized native by name, so install and restore can never drift.
    fn installBaseLib(self: *Vm) Error!void {
        for (base_natives) |bn| try self.defineNative(bn.name, bn.func);
    }

    fn defineNative(self: *Vm, name: []const u8, func: function.NativeFn) Error!void {
        const native = try self.heap.newNative(func, name);
        const key = try self.heap.internValue(name);
        try self.globals.set(self.gpa, key, Value.heap(&native.header));
    }

    /// Execute a top-level chunk and return its first returned value (`nil` if it
    /// returns nothing or falls off the end via `halt`).
    pub fn run(self: *Vm, proto: *const Proto) Error!Value {
        if (proto.num_registers > self.stack.len) return Error.StackOverflow;
        @memset(self.stack[0..proto.num_registers], Value.nil());
        // The main chunk runs as a closure with no upvalues. It is GC-linked and
        // freed at `deinit`; its `proto` pointer is only dereferenced during this
        // call, so a stack-local test `Proto` is fine.
        const top = try self.heap.newClosure(proto, 0);
        try self.pushFrame(top, 0, 0, 0);
        // `run` never arms `suspend_ctl`, so `exec` always finishes here.
        switch (try self.exec()) {
            .finished => |fr| return if (fr.count >= 1) self.stack[fr.reg] else Value.nil(),
            .suspended => unreachable,
        }
    }

    /// Like `run`, but returns the raw `ExecOutcome` so a caller that armed
    /// `suspend_ctl` can observe a mid-execution `.suspended`. Sets up the main
    /// chunk's frame exactly as `run` does. Resume after a `.suspended` by
    /// calling `exec()` again (the cursor is parked in `frames[depth-1]`).
    pub fn start(self: *Vm, proto: *const Proto) Error!ExecOutcome {
        if (proto.num_registers > self.stack.len) return Error.StackOverflow;
        @memset(self.stack[0..proto.num_registers], Value.nil());
        const top = try self.heap.newClosure(proto, 0);
        try self.pushFrame(top, 0, 0, 0);
        return self.exec();
    }

    /// Push a new activation onto the explicit call stack and make it the top
    /// frame. The single chokepoint for both the main chunk (`run`) and nested
    /// `call`s, so the depth/stack bounds and the `stack_top` raise are enforced
    /// in one place. **Raises `stack_top` to cover the new window atomically with
    /// the push**, so the very next safepoint scans the callee's registers — the
    /// caller must therefore have already written any argument values into that
    /// window (a straight-line, allocation-free stretch) before calling this.
    pub fn pushFrame(self: *Vm, closure: *const Closure, base: usize, ret_dest: u16, ret_count: u16) Error!void {
        if (self.depth >= max_call_depth) return Error.StackOverflow;
        const nreg = closure.proto.num_registers;
        if (base + nreg > self.stack.len) return Error.StackOverflow;
        self.frames[self.depth] = .{
            .closure = closure,
            .base = base,
            .pc = 0,
            .ret_dest = ret_dest,
            .ret_count = ret_count,
        };
        self.depth += 1;
        self.stack_top = base + nreg;
    }

    /// Run one stop-the-world collection. Invoked only at the dispatch-loop
    /// safepoint. The VM supplies the root set — everything a running program can
    /// still reach — and the heap owns the mark/sweep mechanism (`gc.zig`).
    ///
    /// Marking cannot fail once `beginCollect` reserves the worklist, so on the
    /// rare reservation OOM we skip the cycle: nothing has been coloured, the heap
    /// is untouched, and the program continues (the triggering allocation may
    /// still OOM on its own, which is reported normally).
    fn collect(self: *Vm) void {
        self.heap.beginCollect() catch return;
        // The root set is defined once in `forEachRootHeader`; marking is just
        // "call `markHeader` on each root".
        self.forEachRootHeader(&self.heap, gc.Heap.markHeader);
        self.heap.traceAll();
        self.heap.sweep();
    }

    /// Visit every GC root that is a heap object, invoking `cb(ctx, header)` once
    /// per root edge. This is the **single source of truth** for "what is live
    /// from outside the heap." Both consumers drive it, so they can never drift:
    /// the collector (`collect`, with `cb = markHeader`) and the keyframe
    /// serializer (`keyframeser.encodeSnapshot`, which seeds its reachable-set
    /// walk). A non-heap root `Value` (a scalar register/const) is skipped here —
    /// `cb` only ever sees heap headers.
    ///
    /// Roots, in a fixed order (so a snapshot's object ordering is deterministic):
    ///   1. globals — user globals and the installed natives (e.g. `print`),
    ///      plus their interned name keys.
    ///   2. live registers across every active frame.
    ///   3. the closures executing in each active frame (`frames[0..depth]` —
    ///      keeps their proto constants reachable).
    ///   4. open upvalue cells (live by construction — about to be closed).
    ///   5. trace constants — a cached trace (or the in-progress recording) may
    ///      hold heap values in its const pool (e.g. a string `load_const`). A
    ///      cached trace can outlive its proto's reachability, so its consts must
    ///      be roots in their own right (docs/design/03-gc-memory.md).
    pub fn forEachRootHeader(
        self: *Vm,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), *object.GcHeader) void,
    ) void {
        cb(ctx, &self.globals.header);
        for (self.stack[0..self.stack_top]) |v| if (v.isHeap()) cb(ctx, v.asHeap());
        for (self.frames[0..self.depth]) |f| cb(ctx, @constCast(&f.closure.header));
        for (self.open_upvalues.items) |ou| cb(ctx, &ou.cell.header);
        for (self.trace.cache.items) |t| {
            for (t.consts) |v| if (v.isHeap()) cb(ctx, v.asHeap());
        }
        if (self.trace.isRecording()) {
            for (self.trace.rec.consts.items) |v| if (v.isHeap()) cb(ctx, v.asHeap());
        }
    }

    /// The tier-0 dispatch loop over the **explicit** call stack. Runs the top
    /// frame (`frames[depth-1]`), pushing a frame on a Lua `call` and popping on
    /// `ret`/`halt` — no host-stack recursion — so execution can be **suspended at
    /// a safepoint and resumed**, which is the basis for mid-execution keyframe
    /// capture. The hot per-frame state (`proto`/`code`/`regs`/`base`/`pc`) is
    /// cached in locals and reloaded from the top frame after every push/pop.
    ///
    /// Returns `.finished` when the bottom (main) frame returns — carrying its
    /// `FrameResult` for `run` — or `.suspended` when `suspend_ctl` fires at a
    /// safepoint (all VM state left intact and capturable). `exec` may be called
    /// again to resume: it simply re-reads the top frame's cursor, so a freshly
    /// **restored** VM resumes by calling `exec` with no special entry point.
    pub fn exec(self: *Vm) Error!ExecOutcome {
        // Hot top-frame state, reloaded from `frames[depth-1]` after every push/pop.
        var frame: *CallFrame = &self.frames[self.depth - 1];
        var closure = frame.closure;
        var proto = closure.proto;
        var code = proto.code;
        var base = frame.base;
        var regs = self.stack[base .. base + proto.num_registers];
        var pc = frame.pc;

        while (true) {
            // GC safepoint. Here every live value is reachable from a root (all
            // registers are settled, no half-built object is exposed), so a
            // stop-the-world collection is safe. Non-moving, so surviving
            // pointers in `regs` stay valid.
            if (self.heap.shouldCollect()) self.collect();

            // Mid-execution suspend point — an instruction boundary, never
            // mid-opcode or mid-native. Sync `pc` into the top frame first so the
            // captured cursor resumes exactly here. `safepoint_seq` is free-running
            // (extra safepoints from the explicit-stack pop are harmless: a
            // collection is invisible, and the counter only drives this test hook).
            self.safepoint_seq += 1;
            if (self.suspend_ctl) |sc| {
                if (self.safepoint_seq >= sc.after_safepoints and self.depth >= sc.min_depth) {
                    frame.pc = pc;
                    return .suspended;
                }
            }

            const cur_pc = pc;
            const instr = code[pc];
            pc += 1;
            // Phase 5 recording hook: while a trace is being recorded, mirror this
            // instruction (and its observed operand types) into the trace IR
            // *before* tier-0 executes it. Recording is transparent — tier-0 still
            // performs the operation below.
            if (self.trace.isRecording()) self.trace.recordInstr(instr, regs, proto);
            const a: usize = instr.a;
            switch (instr.op) {
                // ---- loads & moves ----
                .load_nil => regs[a] = Value.nil(),
                .load_bool => regs[a] = Value.boolean(instr.b != 0),
                .load_int => regs[a] = Value.int(instr.aux),
                .load_const => regs[a] = proto.constants[instr.b],
                .move => regs[a] = regs[instr.b],

                // ---- arithmetic (semantics live in arith.zig) ----
                .add => regs[a] = try arith.add(regs[instr.b], regs[instr.c]),
                .sub => regs[a] = try arith.sub(regs[instr.b], regs[instr.c]),
                .mul => regs[a] = try arith.mul(regs[instr.b], regs[instr.c]),
                .div => regs[a] = try arith.div(regs[instr.b], regs[instr.c]),
                .idiv => regs[a] = try arith.floorDiv(regs[instr.b], regs[instr.c]),
                .mod => regs[a] = try arith.mod(regs[instr.b], regs[instr.c]),
                .pow => regs[a] = try arith.pow(regs[instr.b], regs[instr.c]),

                // ---- bitwise ----
                .band => regs[a] = try arith.band(regs[instr.b], regs[instr.c]),
                .bor => regs[a] = try arith.bor(regs[instr.b], regs[instr.c]),
                .bxor => regs[a] = try arith.bxor(regs[instr.b], regs[instr.c]),
                .shl => regs[a] = try arith.shl(regs[instr.b], regs[instr.c]),
                .shr => regs[a] = try arith.shr(regs[instr.b], regs[instr.c]),

                // ---- unary ----
                .neg => regs[a] = try arith.neg(regs[instr.b]),
                .not => regs[a] = Value.boolean(!regs[instr.b].isTruthy()),
                .bnot => regs[a] = try arith.bnot(regs[instr.b]),
                .len => regs[a] = try lenOf(regs[instr.b]),

                // ---- concat ----
                .concat => regs[a] = try self.concat(regs[instr.b], regs[instr.c]),

                // ---- comparisons → boolean register ----
                // `gt`/`ge` reuse `lt`/`le` with operands swapped (a>b ≡ b<a).
                .eq => regs[a] = Value.boolean(arith.eq(regs[instr.b], regs[instr.c])),
                .ne => regs[a] = Value.boolean(!arith.eq(regs[instr.b], regs[instr.c])),
                .lt => regs[a] = Value.boolean(try arith.lt(regs[instr.b], regs[instr.c])),
                .le => regs[a] = Value.boolean(try arith.le(regs[instr.b], regs[instr.c])),
                .gt => regs[a] = Value.boolean(try arith.lt(regs[instr.c], regs[instr.b])),
                .ge => regs[a] = Value.boolean(try arith.le(regs[instr.c], regs[instr.b])),

                // ---- control flow ----
                .jmp => pc = applyJump(pc, instr.aux),
                .jmp_if_false => if (!regs[a].isTruthy()) {
                    pc = applyJump(pc, instr.aux);
                },
                .jmp_if_true => if (regs[a].isTruthy()) {
                    pc = applyJump(pc, instr.aux);
                },

                // ---- numeric for ----
                // R[a..a+3) = (idx, limit, step). Validate numbers, pre-subtract
                // step from idx (so the first for_loop re-adds it), then jump to
                // the matching for_loop test.
                .for_prep => {
                    if (!regs[a].isNumber() or !regs[a + 1].isNumber() or !regs[a + 2].isNumber()) {
                        return Error.TypeError;
                    }
                    regs[a] = try arith.sub(regs[a], regs[a + 2]);
                    pc = applyJump(pc, instr.aux);
                },
                // idx += step; if still within limit (direction by step sign),
                // publish idx to the loop var R[a+3] and take the back-edge.
                .for_loop => {
                    regs[a] = try arith.add(regs[a], regs[a + 2]);
                    const idx = regs[a];
                    const limit = regs[a + 1];
                    const step = regs[a + 2];
                    const ascending = !(try arith.lt(step, Value.int(0)));
                    const within = if (ascending)
                        try arith.le(idx, limit)
                    else
                        try arith.le(limit, idx);
                    if (within) {
                        regs[a + 3] = idx;
                        pc = applyJump(pc, instr.aux);
                    }
                },

                // ---- tables ----
                .new_table => {
                    const t = try self.heap.newTable();
                    regs[a] = Value.heap(&t.header);
                },
                .get_index => regs[a] = try indexGet(regs[instr.b], regs[instr.c]),
                .set_index => try self.indexSet(regs[a], regs[instr.b], regs[instr.c]),

                // ---- globals ----
                .get_global => regs[a] = self.globals.get(proto.constants[instr.b]),
                .set_global => {
                    try self.globals.set(self.gpa, proto.constants[instr.b], regs[a]);
                    self.heap.writeBarrier(&self.globals.header, regs[a]); // no-op until Phase 4
                },

                // ---- functions ----
                .closure => {
                    const child = proto.protos[instr.b];
                    const cl = try self.makeClosure(closure, child, base);
                    regs[a] = Value.heap(&cl.header);
                },
                .get_upval => regs[a] = closure.upvalues[instr.b].get(),
                .set_upval => {
                    closure.upvalues[instr.b].set(regs[a]);
                    self.heap.writeBarrier(&closure.upvalues[instr.b].header, regs[a]); // no-op until generational
                },
                .close_upvalues => self.closeUpvaluesFrom(base + a),

                // ---- calls ---- a Lua call pushes a frame and reloads onto it; a
                // native runs inline (no frame) as the current frame's top activity.
                .call => {
                    const callee = regs[a];
                    if (!callee.isHeap()) return Error.TypeError;
                    switch (callee.heapType()) {
                        .function => {
                            const cl = Closure.fromHeader(callee.asHeap());
                            const cp = cl.proto;
                            const callee_base = base + proto.num_registers;
                            const nargs: usize = instr.b;
                            if (self.depth >= max_call_depth) return Error.StackOverflow;
                            if (callee_base + cp.num_registers > self.stack.len) return Error.StackOverflow;
                            // Lay out the callee window: bind fixed params (nil-fill
                            // any not supplied), nil the rest. Straight-line and
                            // allocation-free — these slots sit above the current
                            // `stack_top` until `pushFrame` raises it, so no safepoint
                            // may intervene here (none does).
                            var i: usize = 0;
                            while (i < cp.num_registers) : (i += 1) {
                                self.stack[callee_base + i] = if (i < cp.num_params and i < nargs)
                                    self.stack[base + a + 1 + i]
                                else
                                    Value.nil();
                            }
                            // Freeze the caller's resume cursor (already one past this
                            // call), push the callee, and reload locals onto it.
                            frame.pc = pc;
                            try self.pushFrame(cl, callee_base, instr.a, instr.c);
                            frame = &self.frames[self.depth - 1];
                            closure = frame.closure;
                            proto = closure.proto;
                            code = proto.code;
                            base = frame.base;
                            regs = self.stack[base .. base + proto.num_registers];
                            pc = frame.pc;
                            continue;
                        },
                        .native => {
                            const nat = function.Native.fromHeader(callee.asHeap());
                            const nargs: usize = instr.b;
                            const nwanted: usize = instr.c;
                            const args = self.stack[base + a + 1 .. base + a + 1 + nargs];
                            const result = nat.func(@ptrCast(self), args) catch |e| return narrowError(e);
                            // Natives return a single value (multi-return is later).
                            var k: usize = 0;
                            while (k < nwanted) : (k += 1) {
                                regs[a + k] = if (k == 0) result else Value.nil();
                            }
                        },
                        else => return Error.TypeError,
                    }
                },

                // ---- returns ---- pop this frame; copy results into the parent's
                // window (or, for the bottom frame, hand the `FrameResult` to
                // `run`/`exec`'s caller). Close any upvalues over this frame first.
                .ret, .halt => {
                    self.closeUpvaluesFrom(base);
                    const result: FrameResult = if (instr.op == .ret)
                        .{ .reg = @intCast(a), .count = instr.b }
                    else
                        .{ .reg = 0, .count = 0 };
                    if (self.depth == 1) {
                        self.depth = 0;
                        return .{ .finished = result };
                    }
                    // Copy results into the parent *while* `stack_top` still covers
                    // this (callee) window — no allocation or safepoint between here
                    // and the `stack_top` shrink below, so a result can't be
                    // collected before it lands in the parent's (scanned) registers.
                    // `want` uses the stored return-wiring, never a re-decode of the
                    // caller's call instruction. (`all_results` is dead today — the
                    // compiler emits c∈{0,1} — but clamp it so a stray sentinel
                    // can't smash the stack; see docs/design note in the plan.)
                    const parent = &self.frames[self.depth - 2];
                    const want: usize = if (frame.ret_count == bytecode.all_results)
                        result.count
                    else
                        frame.ret_count;
                    const dst = parent.base + frame.ret_dest;
                    const src = base + result.reg;
                    var k: usize = 0;
                    while (k < want) : (k += 1) {
                        self.stack[dst + k] = if (k < result.count)
                            self.stack[src + k]
                        else
                            Value.nil();
                    }
                    // Pop and reload locals onto the parent (its `pc` is already past
                    // the call), shrinking `stack_top` to the parent's window.
                    self.depth -= 1;
                    frame = &self.frames[self.depth - 1];
                    closure = frame.closure;
                    proto = closure.proto;
                    code = proto.code;
                    base = frame.base;
                    regs = self.stack[base .. base + proto.num_registers];
                    pc = frame.pc;
                    self.stack_top = base + proto.num_registers;
                    continue;
                },
            }

            // Phase 5 hotness seam: a backward (or self) jump just took us to
            // `pc <= cur_pc` — a loop back-edge whose target `pc` is the loop
            // header (anchor). Count it, and arm/close a recording. Gated on
            // `enabled`, so it is inert until `--trace`.
            if (self.trace.config.enabled and pc <= cur_pc) {
                self.trace.onBackEdge(proto, @intCast(pc), regs);

                // Phase 6 tier-1a entry: if a trace is cached for this loop header
                // and we're not mid-recording, execute it. `irinterp.execute`
                // returns with `regs` coherent for the header — it side-exits
                // *before* committing a partial iteration — so we `continue`
                // **without** advancing `pc`: tier-0 then re-runs the loop header
                // to redo the (pure, side-effect-free) deopt iteration. A trace is
                // only ever entered at exactly its anchor pc, so re-entry is sound.
                if (self.trace.config.execute and !self.trace.isRecording()) {
                    if (self.trace.findTrace(proto, @intCast(pc))) |t| {
                        if (self.trace.valuesScratch(t.instrs.len)) |buf| {
                            const completed = irinterp.execute(t, regs, buf);
                            self.trace.onSideExit(t, completed);
                            continue;
                        } else |_| {} // OOM growing scratch: let tier-0 run the loop
                    }
                }
            }
        }
    }

    /// `R[b] .. R[c]` — string concatenation. Strings concatenate directly;
    /// numbers coerce to their text form (Lua-shaped). Anything else errors.
    /// The result is interned.
    fn concat(self: *Vm, a: Value, b: Value) Error!Value {
        var buf_a: [64]u8 = undefined;
        var buf_b: [64]u8 = undefined;
        const sa = try coerceConcat(a, &buf_a);
        const sb = try coerceConcat(b, &buf_b);

        const tmp = try self.gpa.alloc(u8, sa.len + sb.len);
        defer self.gpa.free(tmp);
        @memcpy(tmp[0..sa.len], sa);
        @memcpy(tmp[sa.len..], sb);
        return self.heap.internValue(tmp);
    }

    /// `container[key]`. Only tables are indexable in v1 (no string indexing /
    /// metatables yet).
    fn indexGet(container: Value, key: Value) Error!Value {
        if (container.isHeap() and container.heapType() == .table) {
            return table.Table.fromHeader(container.asHeap()).get(key);
        }
        return Error.TypeError;
    }

    /// `container[key] = val`. The write-barrier seam fires here: a value stored
    /// into a heap container.
    fn indexSet(self: *Vm, container: Value, key: Value, val: Value) Error!void {
        if (container.isHeap() and container.heapType() == .table) {
            const t = table.Table.fromHeader(container.asHeap());
            try t.set(self.gpa, key, val);
            self.heap.writeBarrier(&t.header, val); // no-op until Phase 4
            return;
        }
        return Error.TypeError;
    }

    /// Instantiate a closure for `child_proto`, filling each upvalue cell per the
    /// proto's capture plan: either capture a local of the *enclosing* frame (an
    /// open cell pointing into `stack[base + index]`) or inherit one of the
    /// enclosing closure's own upvalues.
    fn makeClosure(self: *Vm, parent: *const Closure, child_proto: *const Proto, base: usize) Error!*Closure {
        const cl = try self.heap.newClosure(child_proto, child_proto.upvalues.len);
        for (child_proto.upvalues, 0..) |desc, i| {
            cl.upvalues[i] = if (desc.in_stack)
                try self.captureUpvalue(base + desc.index)
            else
                parent.upvalues[desc.index];
        }
        return cl;
    }

    /// Find-or-create the open upvalue for stack slot `index`. Two closures
    /// capturing the same live variable thereby share one cell (so a write
    /// through one is seen through the other).
    fn captureUpvalue(self: *Vm, index: usize) Error!*function.Upvalue {
        for (self.open_upvalues.items) |ou| {
            if (ou.index == index) return ou.cell;
        }
        const cell = try self.heap.newUpvalue(&self.stack[index]);
        try self.open_upvalues.append(self.gpa, .{ .index = index, .cell = cell });
        return cell;
    }

    /// Close (detach) every open upvalue whose slot index is `>= from`: snapshot
    /// the live value into the cell and drop it from the open list. Called when a
    /// scope's registers (or a whole frame) are about to be freed.
    fn closeUpvaluesFrom(self: *Vm, from: usize) void {
        var i = self.open_upvalues.items.len;
        while (i > 0) {
            i -= 1;
            const ou = self.open_upvalues.items[i];
            if (ou.index >= from) {
                ou.cell.close();
                _ = self.open_upvalues.swapRemove(i);
            }
        }
    }

};

/// Narrow a native's `anyerror` back into the interpreter's error set. Known
/// runtime errors map across; anything else is surfaced as a `HostError`.
fn narrowError(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => Error.OutOfMemory,
        error.TypeError => Error.TypeError,
        error.DivisionByZero => Error.DivisionByZero,
        error.StackOverflow => Error.StackOverflow,
        error.Unimplemented => Error.Unimplemented,
        else => Error.HostError,
    };
}

/// The `print` built-in — the canonical host-effect at the embedding boundary.
/// Writes its arguments tab-separated, newline-terminated, to stdout (`io.zig`,
/// the one churny-writer wrapper) and returns `nil`. In a later phase this is
/// where an effect is *recorded* for deterministic replay
/// (docs/design/02-determinism.md); for now it just performs it.
fn nativePrint(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const to_stdout = vm.out == null;
    const w = vm.out orelse io.stdout();
    for (args, 0..) |arg, i| {
        if (i != 0) try w.writeAll("\t");
        try io.writeValue(w, arg);
    }
    try w.writeAll("\n");
    if (to_stdout) io.flush();
    return Value.nil();
}

/// Coerce a concat operand to bytes: a string's own bytes, or a number formatted
/// into `buf`. Returns a slice valid until `buf` is reused.
fn coerceConcat(v: Value, buf: []u8) Error![]const u8 {
    return switch (v.tag) {
        .heap_ref => if (v.heapType() == .string)
            string.String.fromHeader(v.asHeap()).bytes()
        else
            Error.TypeError,
        .int => std.fmt.bufPrint(buf, "{d}", .{v.asInt()}) catch unreachable,
        .float => std.fmt.bufPrint(buf, "{d}", .{v.asFloat()}) catch unreachable,
        else => Error.TypeError,
    };
}

/// `#v` — length of a string (bytes) or table (border). Other types error.
fn lenOf(v: Value) Error!Value {
    if (v.isHeap()) {
        return switch (v.heapType()) {
            .string => Value.int(@intCast(string.String.fromHeader(v.asHeap()).len)),
            .table => Value.int(table.Table.fromHeader(v.asHeap()).length()),
            else => Error.TypeError,
        };
    }
    return Error.TypeError;
}

/// Apply a relative jump. `pc` has already advanced past the jump instruction,
/// so the offset is measured from the *next* instruction (offset 0 = no-op).
inline fn applyJump(pc: usize, offset: i32) usize {
    const signed: i64 = @as(i64, @intCast(pc)) + offset;
    return @intCast(signed);
}

// ---------------------------------------------------------------------------
// Tests — hand-assembled prototypes (no compiler yet; that is Increment C).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a one-off prototype, run it, and return the first result.
fn runCode(code: []const Instr, constants: []const Value, num_registers: u16) Error!Value {
    const proto = Proto{
        .code = code,
        .constants = constants,
        .num_registers = num_registers,
        .name = "test",
    };
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    return vm.run(&proto);
}

test "arithmetic: (2 + 3) * 4 == 20" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 2),
        Instr.opAx(.load_int, 1, 3),
        Instr.opABC(.add, 0, 0, 1), // r0 = 2 + 3
        Instr.opAx(.load_int, 1, 4),
        Instr.opABC(.mul, 0, 0, 1), // r0 = 5 * 4
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &.{}, 2);
    try testing.expect(r.isInt());
    try testing.expectEqual(@as(i64, 20), r.asInt());
}

test "load_const pulls float literals from the pool" {
    const consts = [_]Value{ Value.float(1.5), Value.float(2.5) };
    const code = [_]Instr{
        Instr.opAB(.load_const, 0, 0),
        Instr.opAB(.load_const, 1, 1),
        Instr.opABC(.add, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &consts, 2);
    try testing.expectEqual(@as(f64, 4.0), r.asFloat());
}

test "comparison writes a boolean; not inverts truthiness" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 3),
        Instr.opAx(.load_int, 1, 5),
        Instr.opABC(.lt, 0, 0, 1), // r0 = 3 < 5 = true
        Instr.opAB(.not, 0, 0), // r0 = not true = false
        Instr.opAB(.ret, 0, 1),
    };
    const r = try runCode(&code, &.{}, 2);
    try testing.expect(r.isBool());
    try testing.expectEqual(false, r.asBool());
}

test "gt/ge are lt/le with swapped operands" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opAx(.load_int, 1, 3),
        Instr.opABC(.gt, 0, 0, 1), // 5 > 3 = true
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectEqual(true, (try runCode(&code, &.{}, 2)).asBool());
}

test "forward jump skips an instruction" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 1),
        Instr.opJ(.jmp, 1), // skip the next instruction
        Instr.opAx(.load_int, 0, 999), // skipped
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectEqual(@as(i64, 1), (try runCode(&code, &.{}, 1)).asInt());
}

test "conditional jump + back-edge: sum 1..5 == 15" {
    // r0 = i (counter, counts down 5..1), r1 = acc, r2 = scratch
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5), //  0: i = 5
        Instr.opAx(.load_int, 1, 0), //  1: acc = 0
        // loop:
        Instr.opAx(.load_int, 2, 0), //  2: scratch = 0
        Instr.opABC(.le, 2, 0, 2), //  3: scratch = (i <= 0)
        Instr.opAx(.jmp_if_true, 2, 4), //  4: if i<=0 goto end (pc 9)
        Instr.opABC(.add, 1, 1, 0), //  5: acc += i
        Instr.opAx(.load_int, 2, 1), //  6: scratch = 1
        Instr.opABC(.sub, 0, 0, 2), //  7: i -= 1
        Instr.opJ(.jmp, -7), //  8: goto loop (back to pc 2)
        // end:
        Instr.opAB(.ret, 1, 1), //  9: return acc
    };
    const r = try runCode(&code, &.{}, 3);
    try testing.expectEqual(@as(i64, 15), r.asInt());
}

test "numeric for: sum i=1..5 == 15 via for_prep/for_loop" {
    // r0=acc, r1=idx, r2=limit, r3=step, r4=loop var
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 0), // 0: acc = 0
        Instr.opAx(.load_int, 1, 1), // 1: idx = 1
        Instr.opAx(.load_int, 2, 5), // 2: limit = 5
        Instr.opAx(.load_int, 3, 1), // 3: step = 1
        Instr.opAx(.for_prep, 1, 1), // 4: prep, jump to for_loop (pc 6)
        Instr.opABC(.add, 0, 0, 4), // 5: body: acc += i
        Instr.opAx(.for_loop, 1, -2), // 6: step+test, back-edge to body (pc 5)
        Instr.opAB(.ret, 0, 1), // 7: return acc
    };
    try testing.expectEqual(@as(i64, 15), (try runCode(&code, &.{}, 5)).asInt());
}

test "type error propagates from a bad operand" {
    const code = [_]Instr{
        Instr.opA(.load_nil, 0),
        Instr.opAx(.load_int, 1, 1),
        Instr.opABC(.add, 0, 0, 1), // nil + 1
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

test "ret with no values yields nil; halt yields nil" {
    const r0 = try runCode(&[_]Instr{Instr.opAB(.ret, 0, 0)}, &.{}, 1);
    try testing.expect(r0.isNil());
    const r1 = try runCode(&[_]Instr{Instr.op0(.halt)}, &.{}, 1);
    try testing.expect(r1.isNil());
}

test "new_table + set_index + get_index round-trips a value" {
    // local t = {}; t[1] = 42; return t[1]
    const code = [_]Instr{
        Instr.opA(.new_table, 0),
        Instr.opAx(.load_int, 1, 1), // key
        Instr.opAx(.load_int, 2, 42), // value
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opABC(.get_index, 1, 0, 1),
        Instr.opAB(.ret, 1, 1),
    };
    // Result is a scalar int, so the deinit-after-return helper is safe here.
    try testing.expectEqual(@as(i64, 42), (try runCode(&code, &.{}, 3)).asInt());
}

test "#t counts the sequence border" {
    // t = {10, 20, 30}; return #t
    const code = [_]Instr{
        Instr.opA(.new_table, 0),
        Instr.opAx(.load_int, 1, 1), Instr.opAx(.load_int, 2, 10), Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 2), Instr.opAx(.load_int, 2, 20), Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 3), Instr.opAx(.load_int, 2, 30), Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAB(.len, 1, 0),
        Instr.opAB(.ret, 1, 1),
    };
    try testing.expectEqual(@as(i64, 3), (try runCode(&code, &.{}, 3)).asInt());
}

test "indexing a non-table is a type error" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opAx(.load_int, 1, 1),
        Instr.opABC(.get_index, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

test "call a closure: double(21) == 42 via the call convention" {
    // child: double(x) -> x * 2
    const child_code = [_]Instr{
        Instr.opAx(.load_int, 1, 2), // R1 = 2
        Instr.opABC(.mul, 1, 0, 1), // R1 = x * 2
        Instr.opAB(.ret, 1, 1), // return R1
    };
    var child = Proto{ .code = &child_code, .num_registers = 2, .num_params = 1, .name = "double" };
    const protos = [_]*const Proto{&child};
    // main: f = closure(double); return f(21)
    const main_code = [_]Instr{
        Instr.opAB(.closure, 0, 0), // R0 = closure(double)
        Instr.opAx(.load_int, 1, 21), // R1 = 21 (arg)
        Instr.opABC(.call, 0, 1, 1), // call R0 with 1 arg, want 1 result → R0
        Instr.opAB(.ret, 0, 1),
    };
    const main = Proto{ .code = &main_code, .num_registers = 2, .protos = &protos, .name = "main" };
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 42), (try vm.run(&main)).asInt());
}

test "calling a non-function is a type error" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 5),
        Instr.opABC(.call, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    try testing.expectError(Error.TypeError, runCode(&code, &.{}, 2));
}

test "print is installed as a native global; output goes through the sink" {
    // Exercises the host-effect seam end to end, capturing output in a buffer
    // (never the real stdout — the test runner owns fd 1).
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    const consts = [_]Value{
        try vm.heap.internValue("print"),
        try vm.heap.internValue("ok"),
    };
    const code = [_]Instr{
        Instr.opAB(.get_global, 0, 0), // R0 = print
        Instr.opAB(.load_const, 1, 1), // R1 = "ok"
        Instr.opABC(.call, 0, 1, 1), // print("ok") → R0  (R0=fn, 1 arg in R1)
        Instr.opAB(.ret, 0, 1),
    };
    const proto = Proto{ .code = &code, .constants = &consts, .num_registers = 2, .name = "t" };
    try testing.expect((try vm.run(&proto)).isNil());
    try testing.expectEqualStrings("ok\n", sink.buffered());
}

test "concat joins strings and coerces numbers; result is interned" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    // "x=" .. 42  ->  "x=42"
    const consts = [_]Value{try vm.heap.internValue("x=")};
    const code = [_]Instr{
        Instr.opAB(.load_const, 0, 0),
        Instr.opAx(.load_int, 1, 42),
        Instr.opABC(.concat, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    const proto = Proto{ .code = &code, .constants = &consts, .num_registers = 2, .name = "t" };
    const r = try vm.run(&proto); // inspect before deinit (heap result)
    try testing.expect(r.isHeap());
    try testing.expectEqualStrings("x=42", string.String.fromHeader(r.asHeap()).bytes());
}

// ---------------------------------------------------------------------------
// End-to-end integration — source text → parse → compile → run.
//
// The hand-assembled tests above pin individual opcodes; these drive the whole
// Phase 3 pipeline (front end + compiler + tier-0 interpreter + heap) the way
// the CLI runs a real program, and assert on the captured `print` output. The
// front-end imports are function-local so the production interpreter keeps no
// dependency on the parser/compiler — only this test path does.
// ---------------------------------------------------------------------------

/// How the trace machinery participates in a `runCaptured` pass:
///  * `off`            — Phase-0 behaviour: no counting, recording, or execution.
///  * `record_only`         — Phase-5a: record hot loops but tier-0 executes all.
///  * `record_execute_noopt`— Phase-6a: run cached *unoptimized* traces.
///  * `record_execute`      — Phase-6b: run cached traces through the optimizer.
const TraceMode = enum { off, record_only, record_execute_noopt, record_execute };

/// Run `source` to completion, capturing everything `print` emits into `sink`.
/// With `stress`, the collector runs at *every* safepoint — the GC torture test.
/// `mode` selects how the tracing JIT participates (with a low hotness threshold
/// so even short test loops go hot) — used to assert the JIT stays transparent:
/// recording, and now *executing* traces, must not change a program's output.
fn runCaptured(gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer, stress: bool, mode: TraceMode) !void {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = sink;
    vm.heap.gc_stress = stress;
    vm.trace.config.enabled = mode != .off;
    vm.trace.config.execute = mode == .record_execute or mode == .record_execute_noopt;
    vm.trace.config.optimize = mode == .record_execute;
    vm.trace.config.hotloop = 4; // record short test loops

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
}

/// Run `source` across the full matrix of GC discipline × trace mode and assert
/// it prints exactly `expected` every time. Three invariants ride on this:
///  * **GC**: the stress pass frees aggressively — a wrongly-collected live
///    object diverges or faults.
///  * **Recording transparency**: the recorder must not perturb tier-0.
///  * **Execution transparency (Phase 6)**: a trace executed by the tier-1a
///    IR-interpreter must produce byte-identical output to tier-0 — a wrong arith
///    mapping, a bad guard, a deopt mistake, or an exit-store error all diverge here.
fn expectProgram(source: [:0]const u8, expected: []const u8) !void {
    inline for (.{ false, true }) |stress| {
        inline for (.{ .off, .record_only, .record_execute_noopt, .record_execute }) |mode| {
            var buf: [256]u8 = undefined;
            var sink = io.Writer.fixed(&buf);
            try runCaptured(testing.allocator, source, &sink, stress, mode);
            try testing.expectEqualStrings(expected, sink.buffered());
        }
    }
}

// ---------------------------------------------------------------------------
// Determinism self-check — the regression spine for deterministic replay
// (docs/design/02-determinism.md §Replay verification). Replay reconstructs any
// past moment by restoring a keyframe and re-executing forward; that is only
// *sound* if an identical program run is bit-reproducible. The VM has no
// nondeterministic inputs (only `print`, an output) and no keyframes yet, so the
// honest current form of "record-then-replay equivalence" is run-twice
// equivalence: two *independent* VM instances running the same source must agree
// on every observable — printed output AND the serialized trace cache. Any
// address leaking into either (the old `@intFromPtr` render, or an
// address-keyed structure) breaks it. This is the spine effect-logging and
// keyframes plug into later, when "replay" becomes literal.
// ---------------------------------------------------------------------------

/// Run `source` with recording enabled (low hot threshold so test loops go hot),
/// capturing `print` output into `sink`, and return the **serialized trace
/// cache** wire bytes (owned by `gpa`, freed by the caller). Mirrors
/// `runCaptured`, but encodes the cache before the VM is destroyed so two
/// independent runs can be compared byte-for-byte.
fn recordRun(gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) ![]u8 {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const traceser = @import("traceser.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = sink;
    vm.trace.config.enabled = true;
    vm.trace.config.hotloop = 4;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    // Self-contained wire bytes (copied out of the cache), safe past `vm.deinit`.
    return traceser.encodeFile(gpa, vm.trace.cache.items);
}

/// Run `source` (no tracing — a keyframe is a heap artifact, independent of the
/// JIT), then serialize a whole-VM keyframe snapshot and return its wire bytes
/// (owned by `gpa`, freed by the caller). The keyframe analogue of `recordRun`:
/// two independent runs must produce a byte-identical snapshot, which is only
/// true if the heap graph is fully id-keyed (no address leaks into the bytes,
/// including hash-map iteration order — see `table.ValueContext.hash`).
fn snapshotRun(gpa: std.mem.Allocator, source: [:0]const u8) ![]u8 {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const keyframeser = @import("keyframeser.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    // Self-contained wire bytes, safe past `vm.deinit`.
    return keyframeser.encodeSnapshot(gpa, &vm);
}

test "determinism: print of a heap object renders a stable id, not its address" {
    // The address-leak canary. A real pointer on a 64-bit target is enormous
    // (≥ ~0x550000000000); the heap-assigned identity is tiny and monotonic. We
    // assert the rendered hex is small, which distinguishes an id from an address
    // without coupling the test to the VM's exact init allocation order.
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runCaptured(testing.allocator, "print({})", &sink, false, .off);
    const out = sink.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "table: 0x"));
    var hex = out["table: 0x".len..];
    if (hex.len > 0 and hex[hex.len - 1] == '\n') hex = hex[0 .. hex.len - 1];
    const id = try std.fmt.parseInt(u64, hex, 16);
    try testing.expect(id < 0x1000); // an id, never an ASLR address
}

test "determinism: two independent runs agree on output, traces, and snapshots" {
    const programs = [_][:0]const u8{
        // A long hot integer loop — records and (had we executed) runs a trace.
        \\local s = 0
        \\for i = 1, 200 do s = s + i end
        \\print(s)
        ,
        // Tables + a hot summing loop over heap-stored values.
        \\local t = {}
        \\for i = 1, 50 do t[i] = i * i end
        \\local s = 0
        \\for i = 1, 50 do s = s + t[i] end
        \\print(s)
        ,
        // Prints a heap object's identity — would diverge if it were an address.
        \\local t = {}
        \\print(t)
        ,
        // Multiple top-level globals + a string-keyed table, all reachable from
        // `globals` at end-of-run. The globals table's hash part holds several
        // string keys; the snapshot serializes them in hash-iteration order, which
        // is deterministic ONLY if heap keys hash by their stable id, not their
        // address (table.ValueContext.hash). Reverting that fix diverges the
        // snapshot bytes here even though the printed output stays identical.
        \\config = {}
        \\config.width = 64
        \\config.height = 48
        \\config.name = "lune"
        \\alpha = 1
        \\beta = 2
        \\gamma = 3
        \\print(config.name)
        ,
    };
    inline for (programs) |src| {
        var buf_a: [256]u8 = undefined;
        var buf_b: [256]u8 = undefined;
        var sink_a = io.Writer.fixed(&buf_a);
        var sink_b = io.Writer.fixed(&buf_b);
        const traces_a = try recordRun(testing.allocator, src, &sink_a);
        defer testing.allocator.free(traces_a);
        const traces_b = try recordRun(testing.allocator, src, &sink_b);
        defer testing.allocator.free(traces_b);
        // Observable output is identical across independent runs...
        try testing.expectEqualStrings(sink_a.buffered(), sink_b.buffered());
        // ...and so is the serialized trace cache (no address-dependent bytes)...
        try testing.expectEqualSlices(u8, traces_a, traces_b);
        // ...and so is a whole-VM keyframe snapshot of the final heap state.
        const snap_a = try snapshotRun(testing.allocator, src);
        defer testing.allocator.free(snap_a);
        const snap_b = try snapshotRun(testing.allocator, src);
        defer testing.allocator.free(snap_b);
        try testing.expectEqualSlices(u8, snap_a, snap_b);
    }
}

test "e2e: recursion, loop, locals — fib and a summing loop" {
    try expectProgram(
        \\local function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n - 1) + fib(n - 2)
        \\end
        \\local total = 0
        \\for i = 1, 10 do total = total + i end
        \\print(fib(10), total)
    , "55\t55\n"); // fib(10) == 55, sum 1..10 == 55
}

test "e2e: tables and string concat" {
    try expectProgram(
        \\local t = {}
        \\t.name = "lune"
        \\t.answer = 40 + 2
        \\print("hello, " .. t.name)
        \\print("answer=" .. t.answer)
    , "hello, lune\nanswer=42\n");
}

test "e2e: closures capture per-iteration bindings; higher-order print" {
    try expectProgram(
        \\local function adder(x)
        \\  return function(y) return x + y end
        \\end
        \\local add10 = adder(10)
        \\local add20 = adder(20)
        \\print(add10(1), add20(1), add10(add20(0)))
    , "11\t21\t30\n"); // 11, 21, add10(20) == 30
}

test "e2e: while loop with a table accumulator" {
    try expectProgram(
        \\local t = {}
        \\local i = 1
        \\while i <= 3 do
        \\  t[i] = i * i
        \\  i = i + 1
        \\end
        \\print(t[1], t[2], t[3], #t)
    , "1\t4\t9\t3\n");
}

// ---------------------------------------------------------------------------
// GC-specific behaviour (Phase 4). The stress mode above already proves
// behaviour-invariance for the realistic programs; these target the two
// failure modes that only a collector can have: a wrongly-freed constant, and
// a failure to reclaim at all.
// ---------------------------------------------------------------------------

test "gc: a constant printed only after a GC-heavy loop still survives" {
    // Under stress, GC runs at every safepoint in the loop — long before the
    // "survivor" literal is ever loaded into a register. It lives only in the
    // chunk's constant pool until then, so it survives iff proto-constant marking
    // works (the dangling-constant hazard).
    try expectProgram(
        \\local x = 0
        \\for i = 1, 8 do x = x + i end
        \\print("survivor", x)
    , "survivor\t36\n"); // sum 1..8 == 36
}

test "gc: per-iteration garbage is reclaimed (heap stays bounded)" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const gpa = testing.allocator;

    // Each iteration builds a fresh table that becomes unreachable on the next
    // iteration. Without a collector the heap would hold ~200 tables; with one
    // (stress mode) at most a couple are live at any safepoint.
    const source =
        \\local last = 0
        \\for i = 1, 200 do
        \\  local t = {}
        \\  t[1] = i
        \\  last = t[1]
        \\end
        \\print(last)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var buf: [32]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = &sink;
    vm.heap.gc_stress = true;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("200\n", sink.buffered());

    // The decisive assertion: the live set is bounded, *not* proportional to the
    // 200 iterations. (globals, the main closure, "last"/literals, and a handful
    // of still-rooted tables — comfortably under 32.)
    try testing.expect(vm.heap.object_count < 32);
}

// ---------------------------------------------------------------------------
// Trace recorder wiring (Phase 5). The IR + counting unit tests live in
// `trace.zig`; these prove the interpreter actually drives the recorder — the
// `enabled` toggle gates counting, and a hot loop registers a back-edge anchor.
// ---------------------------------------------------------------------------

/// Compile+run `source` with the recorder `enabled`, leaving `vm` inspectable.
/// Returns the compiled `Chunk` — the caller **must** `deinit` it, but only after
/// inspecting any cached traces: a `Trace`'s `anchor.proto` points into the
/// chunk's arena, so freeing the chunk first would dangle it.
fn runForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, enabled: bool) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.trace.config.enabled = enabled;
    // This harness inspects *recording* in isolation (Phase 5a). Keep tier-1a
    // execution off so back-edge counts / cache shape reflect pure recording;
    // Phase-6 execution is exercised by `expectProgram` and its own tests. Keep
    // the optimizer off too, so `dumpTrace` shape assertions see the *raw*
    // recorded IR (folding/CSE/DCE are exercised by the `tropt` tests).
    vm.trace.config.execute = false;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4; // record short test loops
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

test "trace toggle gates back-edge counting" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    // Disabled: the hotness seam is inert — no counters touched.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa, source, false);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 0), vm.trace.counters.count());
    }
    // Enabled: the loop's anchor goes hot and a trace is recorded.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa, source, true);
        defer chunk.deinit();
        try testing.expect(vm.trace.counters.count() >= 1);
        // The hottest anchor crossed the hotness threshold (one back-edge per
        // iteration; one is consumed by trace close, so it lands just under 100).
        var it = vm.trace.counters.valueIterator();
        var max: u32 = 0;
        while (it.next()) |v| max = @max(max, v.*);
        try testing.expect(max >= vm.trace.config.hotloop);
        try testing.expect(max <= 100);
        // The simple counting loop is fully recordable → exactly one cached trace.
        try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    }
}

/// Disassemble a `vm`'s sole cached trace into `buf` for shape assertions. `buf`
/// is sized comfortably above any test trace. The caller must keep the trace's
/// `anchor.proto` alive (see `runForTrace`) — `writeTrace` prints `proto.name`.
fn dumpTrace(buf: []u8, vm: *Vm) ![]const u8 {
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    var w = io.Writer.fixed(buf);
    try trace.writeTrace(&w, vm.trace.cache.items[0]);
    return w.buffered();
}

test "recorder: a numeric-for loop records guards + arithmetic + a loop close" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // Inputs are read as slot_loads; integer operands are pinned with guard_int;
    // the body `acc + i` and the for-loop increment are `add`; the iteration is
    // closed by `loop`.
    try testing.expect(std.mem.indexOf(u8, text, "slot_load") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_true") != null); // for-loop continuation
    try testing.expect(std.mem.indexOf(u8, text, "loop") != null);

    const t = vm.trace.cache.items[0];
    // acc and the loop index are loop-carried, so they surface in the exit snapshot.
    try testing.expect(t.exit_stores.len >= 1);
    try testing.expect(t.entry_slots.len >= 1);
    // No host/cross-frame op was hit, so nothing was blacklisted.
    try testing.expectEqual(@as(usize, 0), vm.trace.blacklist.count());
}

test "recorder: a while loop records a truthiness guard on its condition" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local i = 1
        \\local acc = 0
        \\while i <= 50 do acc = acc + i; i = i + 1 end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // The `i <= 50` test compiles to `le` + a conditional jump; tier-0 takes the
    // loop body, so the recorder pins the condition true (guard_true).
    try testing.expect(std.mem.indexOf(u8, text, "le") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_true") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "loop") != null);
}

test "recorder: a recurring literal is interned to one const-pool entry" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `i * 7` appears twice; before konst interning that recorded two separate
    // `7` constants. runForTrace keeps the optimizer OFF, so the const pool here
    // reflects pure recording — the literal must appear exactly once.
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i * 7 + i * 7 end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    var sevens: usize = 0;
    for (t.consts) |c| {
        if (c.isInt() and c.asInt() == 7) sevens += 1;
    }
    try testing.expectEqual(@as(usize, 1), sevens);
}

test "konst interning lets CSE collapse a repeated subexpression end-to-end" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const source =
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i * 7 + i * 7 end
        \\print(acc)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // Record AND run the optimizer at commit (execute stays on tier-0 — we only
    // inspect the committed, optimized trace, not tier-1a output).
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false;
    vm.trace.config.optimize = true;
    vm.trace.config.hotloop = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    // The two `i * 7` subexpressions are now identical (same slot_load ref + same
    // interned konst ref), so CSE collapses them to a single `mul`. Before konst
    // interning, CSE could not fire here and both muls survived.
    var muls: usize = 0;
    for (t.instrs) |ins| {
        if (ins.op == .mul) muls += 1;
    }
    try testing.expectEqual(@as(usize, 1), muls);
}

test "recorder: a call in the loop body aborts cleanly and blacklists the anchor" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local function id(x) return x end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + id(i) end
        \\print(acc)
    , true);
    defer chunk.deinit();

    // The body's `call` is cross-frame, so the recording aborts — no trace is
    // cached and the loop anchor is blacklisted so it is not re-recorded.
    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.blacklist.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder: maxrecord bounds trace length (overlong traces abort)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A body that emits more than two IR instructions per iteration; with a tiny
    // budget the recording trips `too_long` and is discarded.
    vm.trace.config.maxrecord = 2;
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i + i + i end
        \\print(acc)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.blacklist.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

// ---------------------------------------------------------------------------
// Tier-1a executor shape + deopt (Phase 6). The `expectProgram` matrix above
// already proves output transparency across {off, record_only, record_execute}
// × gc_stress; these target the executor-specific behaviours that the matrix
// can't *observe*: that a cached trace genuinely runs (back-edge counts collapse
// once it takes over), that a guard/arith failure side-exits and tier-0 resumes
// byte-identically, and that the re-entry brake blacklists a thrashing anchor.
// ---------------------------------------------------------------------------

/// Like `runForTrace` but with tier-1a execution ON, capturing `print` output
/// into `sink`. Leaves `vm` inspectable (cache / penalty / blacklist / back-edge
/// counters). The caller must `deinit` the returned chunk only *after* inspecting
/// traces (an anchor points into the chunk arena — see `runForTrace`).
fn runExecForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.out = sink;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

/// Assert `source` prints byte-identically in tier-0 and in record+execute — the
/// equivalence check for deopt-heavy programs whose output (e.g. a float) is
/// tedious to spell but must match tier-0 regardless of how the trace side-exits.
fn expectTier0Equiv(source: [:0]const u8) !void {
    var buf0: [256]u8 = undefined;
    var s0 = io.Writer.fixed(&buf0);
    try runCaptured(testing.allocator, source, &s0, false, .off);
    var buf1: [256]u8 = undefined;
    var s1 = io.Writer.fixed(&buf1);
    try runCaptured(testing.allocator, source, &s1, false, .record_execute);
    try testing.expectEqualStrings(s0.buffered(), s1.buffered());
}

test "executor: a hot numeric-for sum runs via the IR-interpreter (back-edges collapse)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    , &sink);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    // Correct result (sum 1..100).
    try testing.expectEqualStrings("5050\n", sink.buffered());

    // One clean trace, never blacklisted, penalty cleared by the big yield.
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.blacklist.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.penalty.count());

    // The decisive "it actually executed" signal: tier-0 saw back-edges only
    // until the trace was cached (== hotloop). The remaining ~95 iterations ran
    // inside the IR-interpreter, so the anchor's counter never climbed toward 100.
    const t = vm.trace.cache.items[0];
    try testing.expectEqual(vm.trace.config.hotloop, vm.trace.backEdgeCount(t.anchor));
}

test "executor: integer //-by-zero inside a hot loop side-exits; tier-0 re-raises identically" {
    const source =
        \\local x = 0
        \\for i = 1, 100 do x = x + (100 // (50 - i)) end
        \\print(x)
    ;
    // The divisor `50 - i` is 0 at i == 50 — long after the loop has gone hot and
    // is running through the executor. `arith.floorDiv` returns `DivisionByZero`,
    // the executor side-exits, and tier-0 re-runs the partial iteration and raises
    // the *same* error. Tier-0 (execute off) raises it identically — same error,
    // same place — which is the whole point of re-running rather than reconstructing.
    inline for (.{ TraceMode.off, TraceMode.record_execute }) |mode| {
        const gpa = testing.allocator;
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.out = &sink;
        vm.trace.config.enabled = mode != .off;
        vm.trace.config.execute = mode == .record_execute;
        vm.trace.config.hotloop = 4;
        var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        try testing.expectError(Error.DivisionByZero, vm.run(chunk.proto));
    }
}

test "executor: a variable that flips int->float mid-loop deopts, blacklists, and still matches tier-0" {
    // Recorded as an integer loop (the `i == 20` branch is not taken when it goes
    // hot). At i == 20 tier-0 takes the branch and `x` becomes a float; every later
    // re-entry then fails its `guard_int` on `x` (zero-yield), so the re-entry
    // penalty climbs to `max_penalty` and the anchor is blacklisted — tier-0 owns
    // the tail. The result must still equal tier-0's to the last decimal.
    const source =
        \\local x = 0
        \\for i = 1, 200 do
        \\  if i == 20 then x = x + 0.5 end
        \\  x = x + 1
        \\end
        \\print(x)
    ;
    try expectTier0Equiv(source);

    // Introspect the brake: the type flip thrashes the trace until it blacklists.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expect(vm.trace.blacklist.count() >= 1);
}

test "executor: a branchy low-yield loop blacklists the thrashing anchor yet prints correctly" {
    // The trace records one parity of `if i % 2 == 0`; the opposite parity fails
    // its branch guard after ~1 committed iteration *every* entry. `completed > 0`
    // looks productive but never reaches `min_useful`, so the penalty accrues and
    // the anchor blacklists — the case both plan reviewers flagged. Output stays
    // exact (100 evens × 1 + 100 odds × 2 == 300).
    const source =
        \\local s = 0
        \\for i = 1, 200 do
        \\  if i % 2 == 0 then s = s + 1 else s = s + 2 end
        \\end
        \\print(s)
    ;
    try expectTier0Equiv(source);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings("300\n", sink.buffered());
    try testing.expect(vm.trace.blacklist.count() >= 1);
}

test "e2e (executor): a long hot loop stays correct across every trace + gc mode" {
    // Long enough to record, execute, side-exit at the loop close, and clear its
    // penalty — run under gc_stress too (record_execute × stress is in the matrix).
    try expectProgram(
        \\local acc = 0
        \\for i = 1, 64 do acc = acc + i end
        \\print(acc)
    , "2080\n"); // sum 1..64 == 2080
}

test "tropt: every loop-carried variable survives DCE (exit-store observability)" {
    // Three chained loop-carried variables, all read after the loop. The optimizer
    // must root *every* exit_store during dead-code elimination — drop any one and
    // tier-0 would resume with a stale register and the printed value would differ.
    // The 8-way matrix proves opt == noopt == tier-0 for all three.
    try expectProgram(
        \\local a = 0
        \\local b = 1
        \\local c = 2
        \\for i = 1, 50 do
        \\  a = a + i
        \\  b = b + a
        \\  c = c + b
        \\end
        \\print(a)
        \\print(b)
        \\print(c)
    , "1275\n22101\n292877\n");
}

test "tropt: seeded differential fuzz — tier-0 == execute-noopt == execute-opt" {
    // A fixed-seed PRNG generates small all-integer arithmetic loops. For each, the
    // three modes (tier-0, record+execute unoptimized, record+execute optimized)
    // must print byte-identically — the optimizer is output-invariant. Operands are
    // kept non-zero (b ∈ [1,9], the loop index i ∈ [1,k]) so `//`/`%` never divide
    // by zero; everything stays int so there are no type errors, only wrapping.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();
    const ops = [_][]const u8{ "+", "-", "*", "//", "%", "&", "|" };

    var iter: usize = 0;
    while (iter < 64) : (iter += 1) {
        const a0 = rnd.intRangeAtMost(i64, -20, 20);
        const b0 = rnd.intRangeAtMost(i64, 1, 9); // non-zero divisor
        const k = rnd.intRangeAtMost(i64, 5, 40);
        const op1 = ops[rnd.uintLessThan(usize, ops.len)];
        const op2 = ops[rnd.uintLessThan(usize, ops.len)];

        var src_buf: [256]u8 = undefined;
        const source = try std.fmt.bufPrintSentinel(&src_buf,
            \\local a = {d}
            \\local b = {d}
            \\for i = 1, {d} do a = (a {s} b) {s} i end
            \\print(a)
        , .{ a0, b0, k, op1, op2 }, 0);

        var b_off: [64]u8 = undefined;
        var s_off = io.Writer.fixed(&b_off);
        try runCaptured(gpa, source, &s_off, false, .off);
        var b_no: [64]u8 = undefined;
        var s_no = io.Writer.fixed(&b_no);
        try runCaptured(gpa, source, &s_no, false, .record_execute_noopt);
        var b_op: [64]u8 = undefined;
        var s_op = io.Writer.fixed(&b_op);
        try runCaptured(gpa, source, &s_op, false, .record_execute);

        try testing.expectEqualStrings(s_off.buffered(), s_no.buffered());
        try testing.expectEqualStrings(s_off.buffered(), s_op.buffered());
    }
}
