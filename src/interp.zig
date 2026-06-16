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
const execlog = @import("execlog.zig");
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
    /// Replay consumed the whole effect log but the program asked for another
    /// effect — the log is too short for this run (it diverged, or is truncated).
    EffectLogExhausted,
    /// Replay's next logged effect is a different kind than the program just
    /// requested — the recording doesn't match this program/run.
    EffectKindMismatch,
    /// A `clock`-kind effect ran (in `off`/`record` mode) but no `clock_source`
    /// was injected by the embedder. The interpreter holds no platform clock of
    /// its own — the host that constructs the VM must supply one (`main.zig` on
    /// native, the JS host on wasm, a fake in tests). Replay needs none.
    ClockUnavailable,
    /// `random()` needed its seed (in `off`/`record` mode) but no
    /// `random_seed_source` was injected. Mirrors `ClockUnavailable`: the VM holds
    /// no entropy source of its own. Replay needs none (the seed is in the log).
    RandomUnavailable,
    /// A `getenv`/`argc`/`argv` effect ran (in `off`/`record` mode) but no
    /// `host_env` source was injected. Mirrors `ClockUnavailable`: the VM holds no
    /// platform environment/args of its own. Replay needs none (the results are in
    /// the log). One error covers all three — they share the single `HostEnv` seam.
    EnvUnavailable,
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

/// Which nondeterministic input a native represents (record/replay boundary), or
/// null for a pure host call. Defined on `function` (the `Native` carrier) to keep
/// it cycle-free; re-exported here because effects are an interpreter concept.
pub const EffectKind = function.EffectKind;

/// One recorded nondeterministic input: the effect that produced it and the
/// `Value` it returned. The `effect_log` is an **ordered** list consumed in call
/// order on replay (the kind + result fully describe it). `result` may be a heap
/// **string** (`getenv`/`argv`); such results are GC roots while parked in the log
/// (see `forEachRootHeader`) and serialize as inline bytes (`effectser`).
pub const Effect = struct { kind: EffectKind, result: Value };

/// Record / replay / off — the effect-log mode. `off` (default) is the
/// pre-F2d behaviour: every native runs normally and nothing is logged.
pub const EffectMode = enum { off, record, replay };

/// An embedder-supplied wall/monotonic clock. The interpreter carries **no**
/// platform clock of its own — `clock()` reads its value through here, so the
/// VM core stays free of any host/OS dependency (this is what lets it compile to
/// `wasm32-freestanding`, where there is no clock syscall). The host that
/// constructs the VM injects one: `main.zig` supplies the Linux monotonic clock,
/// the wasm host imports `performance.now()`, tests supply a deterministic
/// counter. `record`/`off` call `nowNs`; `replay` never does (it feeds the log
/// back). `ctx` is an opaque pointer to whatever state the source needs.
pub const ClockSource = struct {
    ctx: *anyopaque,
    nowNs: *const fn (ctx: *anyopaque) i64,
};

/// An embedder-supplied source of one nondeterministic seed for `random()`.
/// Mirrors `ClockSource`: the VM holds no entropy of its own, so the host injects
/// one (`main.zig` reads OS entropy, the wasm host imports `crypto.getRandomValues`,
/// tests supply a fixed seed). Consulted once per run — lazily, on the first
/// `random()` call — in `off`/`record`; `replay` reads the seed from the log.
pub const RandomSeedSource = struct {
    ctx: *anyopaque,
    seed: *const fn (ctx: *anyopaque) u64,
};

/// An embedder-supplied window onto the process environment and command-line
/// args, backing the `getenv`/`argc`/`argv` effects. One combined source (not
/// three) because they are the same host facility — the VM holds no platform
/// access of its own (so it still compiles to `wasm32-freestanding`, where the
/// browser host injects a null source). Consulted in `off`/`record`; `replay`
/// reads results from the log. With no source set, those effects fail with
/// `EnvUnavailable`. Returned byte slices are **borrowed** — valid only for the
/// duration of the call — so the native interns them into the heap immediately.
pub const HostEnv = struct {
    ctx: *anyopaque,
    /// Look up an environment variable by name. Null ⇒ unset (distinct from a
    /// set-but-empty `""`, which returns a zero-length slice).
    getenv: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
    /// The number of command-line arguments visible to the program.
    argCount: *const fn (ctx: *anyopaque) i64,
    /// The i-th command-line argument. Null ⇒ index out of range (the source owns
    /// the bounds check, so any out-of-range `i` — including negative — is null).
    arg: *const fn (ctx: *anyopaque, i: i64) ?[]const u8,
};

/// One built-in native. `name` is the native's **serialized identity** — the key
/// the keyframe restorer (`keyframeser.zig`) looks up to rebind it — so it must be
/// unique across the registry; for a module function it is qualified
/// (`"string.format"`). When `module` is set the native is installed as a field of
/// that module's global table (under `field`) instead of as a bare global; a plain
/// entry (`module == null`) installs under `name`. `effect` null = pure host call.
pub const BaseNative = struct {
    name: []const u8,
    func: function.NativeFn,
    effect: ?EffectKind = null,
    /// If set, install into this module table (a global table) rather than as a
    /// top-level global. The unknown-global lint then knows `module` (not `name`).
    module: ?[]const u8 = null,
    /// Key within the module table (required iff `module` is set), e.g. `"format"`.
    field: ?[]const u8 = null,
};

/// The single source of truth for built-in natives. `installBaseLib` installs
/// every entry into a fresh VM's globals, and the keyframe restorer
/// (`keyframeser.zig`) looks a serialized native up here by name to rebind it —
/// so a native added here is automatically both installable and restorable, and
/// the two paths can never diverge. The serialized form of a `Native` is just its
/// name (`keyframeser.toSchemaHeapObject`), which is meaningful only against this
/// registry. The `effect` tag is likewise sourced here (install + restore both
/// read it), so what counts as an effect is defined in exactly one place.
/// `print` is pure output; `clock` is the first nondeterministic input.
pub const base_natives = [_]BaseNative{
    .{ .name = "print", .func = &nativePrint },
    .{ .name = "clock", .func = &nativeClock, .effect = .clock },
    // `random` carries no `effect`: the call itself isn't the boundary — its
    // *seed* is (acquired once, inside `nativeRandom`, as `.random_seed`). So the
    // dispatch calls it directly; the seed goes through record/replay internally.
    .{ .name = "random", .func = &nativeRandom },
    // env/args inputs — `clock`-style (the call site is the boundary). `getenv`
    // and `argv` return heap strings, so the effect log carries inline bytes.
    .{ .name = "getenv", .func = &nativeGetenv, .effect = .getenv },
    .{ .name = "argc", .func = &nativeArgc, .effect = .argc },
    .{ .name = "argv", .func = &nativeArgv, .effect = .argv },
    // Minimal host stdlib for benchmark harnesses (pure host calls — no effects).
    // `tonumber` is a bare global; `string.format`/`io.write` install into their
    // module tables. Qualified names keep the serialized identity unique.
    .{ .name = "tonumber", .func = &nativeTonumber },
    .{ .name = "string.format", .func = &nativeStringFormat, .module = "string", .field = "format" },
    .{ .name = "io.write", .func = &nativeIoWrite, .module = "io", .field = "write" },
};

/// The top-level global names `installBaseLib` seeds, derived from the single
/// `base_natives` registry plus the host-populated `arg` table. The compiler's
/// unknown-global lint treats these as defined so it never warns about
/// `print`/`string`/`io`. A module native contributes its *module* name (the bare
/// global a program references — `string`, not `string.format`); duplicates from
/// sibling module fields are collapsed. Deriving from `base_natives` keeps the two
/// in lockstep — add a native and its top-level name is known here.
pub const builtin_global_names = blk: {
    @setEvalBranchQuota(10_000);
    var tmp: [base_natives.len + 1][]const u8 = undefined;
    var n: usize = 0;
    outer: for (base_natives) |bn| {
        const top = bn.module orelse bn.name;
        for (tmp[0..n]) |existing| {
            if (std.mem.eql(u8, existing, top)) continue :outer;
        }
        tmp[n] = top;
        n += 1;
    }
    // `arg` is a host-populated table (the CLI fills it from process args), not a
    // native — but programs reference it, so the lint must know it.
    tmp[n] = "arg";
    n += 1;
    var names: [n][]const u8 = undefined;
    for (&names, 0..) |*slot, i| slot.* = tmp[i];
    break :blk names;
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

/// One row of a runtime-error backtrace: a function name plus the source span of
/// the active instruction in that frame (the faulting instruction for the leaf;
/// the outgoing call site for every parent). `line` is 1-based.
pub const FaultFrame = struct {
    name: []const u8,
    line: u32 = 0,
    start: u32 = 0,
    end: u32 = 0,
};

/// A located, human-readable description of a runtime error — what
/// `describeFault` synthesizes from the faulting frame. `start`/`end` are byte
/// offsets into the source (the faulting instruction's span); `line` is 1-based.
/// `frames` is the full call chain, **deepest-first** (leaf at index 0); the
/// top-level `message`/`line`/`start`/`end` describe that leaf frame.
pub const Fault = struct {
    message: []const u8,
    line: u32 = 0,
    start: u32 = 0,
    end: u32 = 0,
    frames: []const FaultFrame = &.{},
};

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
    /// Effect-log mode (F2d): `off` (default — natives run normally, nothing
    /// logged), `record` (run effects + append each result to `effect_log`), or
    /// `replay` (do NOT call effects — feed back the logged result in call order).
    effect_mode: EffectMode = .off,
    /// The ordered nondeterministic-input log. In `record` it grows; in `replay`
    /// it is consumed front-to-back via `effect_cursor`. Owned by the VM.
    effect_log: std.ArrayList(Effect) = .empty,
    /// Replay read position into `effect_log` (next effect to feed back).
    effect_cursor: usize = 0,
    /// Embedder-supplied clock for `clock()` (null = none injected). The
    /// interpreter holds no platform clock; the host that builds the VM sets this
    /// (`main.zig` native, the JS host on wasm, a fake in tests). A `clock()` in
    /// `off`/`record` mode with no source set fails with `ClockUnavailable`;
    /// `replay` never reads it.
    clock_source: ?ClockSource = null,
    /// Embedder-supplied entropy for `random()`'s seed (null = none injected).
    /// Read once, lazily, on the first `random()` in `off`/`record`; `replay`
    /// reads the seed from the log instead. No source set ⇒ `RandomUnavailable`.
    random_seed_source: ?RandomSeedSource = null,
    /// Embedder-supplied env/args window for `getenv`/`argc`/`argv` (null = none).
    /// Read in `off`/`record` (`main.zig` native = real process env + argv, the
    /// wasm host = a null source); `replay` feeds results from the log. No source
    /// set ⇒ `EnvUnavailable`.
    host_env: ?HostEnv = null,
    /// The VM's PRNG, seeded lazily from the first `random()` call's seed (an
    /// effect). `std.Random.Xoshiro256` is pinned *by name* (not `DefaultPrng`) so
    /// the draw stream is a stable part of the language: a given seed reproduces
    /// the same sequence across runs and across the native/wasm engines.
    rng: ?std.Random.Xoshiro256 = null,
    /// Source text, set only when `record_safepoint_lines` is on (the replay
    /// driver needs it to map each safepoint's pending instruction span to a
    /// 1-based line). Empty otherwise; the hot path never reads it unless
    /// recording is enabled.
    source: []const u8 = "",
    /// When true, append the 1-based source line of each safepoint's pending
    /// instruction to `safepoint_lines` (the replay driver's line-grain index).
    /// Off by default so tier-0 pays nothing — the normal run path is untouched.
    record_safepoint_lines: bool = false,
    /// Line-per-safepoint index built when `record_safepoint_lines` is on:
    /// `safepoint_lines[k-1]` is the source line of the instruction pending at
    /// safepoint k (1-based, matching `safepoint_seq`). Owned by the VM; lets the
    /// replay UI offer line-grain stepping with no extra wasm round-trips.
    safepoint_lines: std.ArrayList(u32) = .empty,

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
        self.effect_log.deinit(self.gpa);
        self.safepoint_lines.deinit(self.gpa);
        self.heap.deinit();
        self.gpa.free(self.stack);
    }

    /// Install the built-in globals (the host-effect boundary) from the single
    /// `base_natives` registry — the same table the keyframe restorer reads to
    /// rebind a serialized native by name, so install and restore can never drift.
    fn installBaseLib(self: *Vm) Error!void {
        for (base_natives) |bn| try self.defineNative(bn);
        // `arg` is a real (initially empty) table so the lint, tests, the wasm
        // host, and keyframe restore all see a table; `arg[i]` is nil until the
        // CLI host fills it from process args (`main.zig`, at the host boundary).
        const arg_table = try self.heap.newTable();
        try self.globals.set(self.gpa, try self.heap.internValue("arg"), Value.heap(&arg_table.header));
    }

    fn defineNative(self: *Vm, bn: BaseNative) Error!void {
        const native = try self.heap.newNative(bn.func, bn.name);
        native.effect = bn.effect; // null for pure host calls (e.g. print)
        if (bn.module) |mod| {
            const tbl = try self.getOrCreateModuleTable(mod);
            const fkey = try self.heap.internValue(bn.field.?);
            try tbl.set(self.gpa, fkey, Value.heap(&native.header));
        } else {
            const key = try self.heap.internValue(bn.name);
            try self.globals.set(self.gpa, key, Value.heap(&native.header));
        }
    }

    /// Fill the global `arg` table from host program arguments: `arg[0]` is the
    /// script path (`argv[0]`), `arg[i]` the i-th argument — the Lua convention.
    /// This is a **load-time host input**, set once at the host boundary
    /// (`main.zig`), so the interpreter exec core never reads argv mid-run and
    /// stays deterministic. The table is a normal heap table → serializes through
    /// the keyframe path. (The dynamic `argv()`/`argc()` effect natives are
    /// unaffected — they remain the per-call nondeterministic-input boundary.)
    pub fn populateArgs(self: *Vm, argv: []const []const u8) Error!void {
        const v = self.globals.get(try self.heap.internValue("arg"));
        if (!(v.isHeap() and v.heapType() == .table)) return; // installBaseLib guarantees a table
        const tbl = table.Table.fromHeader(v.asHeap());
        for (argv, 0..) |a, idx| {
            try tbl.set(self.gpa, Value.int(@intCast(idx)), try self.heap.internValue(a));
        }
    }

    /// Fetch the global module table `name`, creating and binding it on first use.
    /// Module tables are ordinary heap tables reachable from `globals`, so they
    /// capture/restore through the keyframe path with no special-casing.
    fn getOrCreateModuleTable(self: *Vm, name: []const u8) Error!*table.Table {
        const key = try self.heap.internValue(name);
        const existing = self.globals.get(key);
        if (existing.isHeap() and existing.heapType() == .table) {
            return table.Table.fromHeader(existing.asHeap());
        }
        const tbl = try self.heap.newTable();
        try self.globals.set(self.gpa, key, Value.heap(&tbl.header));
        return tbl;
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

    /// Build a located, human-readable description of a runtime error, read from
    /// the un-popped top frame (`exec` does not unwind `self.frames` on error —
    /// see the `frame.pc = cur_pc` sync in `exec`). The faulting instruction's
    /// opcode and live operand *values* tell us the operation and the offending
    /// type; its `Proto.spans[pc]` gives the source range and line.
    ///
    /// Call only immediately after `run`/`exec` returned `err`: it inspects live
    /// registers, so nothing must have executed since. `arena` owns the returned
    /// message.
    pub fn describeFault(self: *Vm, source: []const u8, err: Error, arena: std.mem.Allocator) std.mem.Allocator.Error!Fault {
        // No frame (e.g. main chunk too big for the stack) → just the error name.
        if (self.depth == 0) return .{ .message = try arena.dupe(u8, @errorName(err)) };

        const frame = &self.frames[self.depth - 1];
        const proto = frame.closure.proto;
        const pc = frame.pc;
        if (pc >= proto.code.len) return .{ .message = try arena.dupe(u8, @errorName(err)) };

        const instr = proto.code[pc];
        const regs = self.stack[frame.base .. frame.base + proto.num_registers];
        const span: bytecode.Span = if (pc < proto.spans.len) proto.spans[pc] else .{};
        const line = compiler.lineFromOffset(source, span.start);

        const message: []const u8 = switch (err) {
            Error.StackOverflow => try arena.dupe(u8, "stack overflow"),
            Error.DivisionByZero => try arena.dupe(u8, "attempt to perform integer division or modulo by zero"),
            else => switch (instr.op) {
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr => try std.fmt.allocPrint(
                    arena,
                    "attempt to perform arithmetic on a {s} value",
                    .{firstNonNumber(regs[instr.b], regs[instr.c]).typeName()},
                ),
                .neg, .bnot => try std.fmt.allocPrint(arena, "attempt to perform arithmetic on a {s} value", .{regs[instr.b].typeName()}),
                .len => try std.fmt.allocPrint(arena, "attempt to get length of a {s} value", .{regs[instr.b].typeName()}),
                .concat => try std.fmt.allocPrint(arena, "attempt to concatenate a {s} value", .{firstNonConcatable(regs[instr.b], regs[instr.c]).typeName()}),
                .lt, .le, .gt, .ge => try std.fmt.allocPrint(arena, "attempt to compare {s} with {s}", .{ regs[instr.b].typeName(), regs[instr.c].typeName() }),
                .get_index => try std.fmt.allocPrint(arena, "attempt to index a {s} value", .{regs[instr.b].typeName()}),
                .set_index => try std.fmt.allocPrint(arena, "attempt to index a {s} value", .{regs[instr.a].typeName()}),
                .call => try std.fmt.allocPrint(arena, "attempt to call a {s} value", .{regs[instr.a].typeName()}),
                else => try arena.dupe(u8, @errorName(err)),
            },
        };

        const frames = try self.backtraceFrames(source, arena);
        return .{ .message = message, .line = line, .start = span.start, .end = span.end, .frames = frames };
    }

    /// Walk the live call stack into `FaultFrame` rows, **deepest-first** (leaf at
    /// index 0). `exec` does not unwind `self.frames` on error or suspend, so every
    /// live frame is intact when this is called. The leaf's pc is its pending /
    /// faulting instruction; a parent's pc is the *resume cursor* — one past its
    /// outgoing `call` (set at the call site before pushing the child) — so its
    /// call-site instruction is `pc -| 1`. Shared by `describeFault` (runtime
    /// errors) and the replay driver (per-step backtrace), so the leaf-vs-call-site
    /// logic can never drift. `arena` owns the returned slice.
    pub fn backtraceFrames(self: *Vm, source: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]FaultFrame {
        const frames = try arena.alloc(FaultFrame, self.depth);
        var i: usize = self.depth;
        while (i > 0) {
            i -= 1;
            const f = &self.frames[i];
            const fp = f.closure.proto;
            const fpc: usize = if (i == self.depth - 1) f.pc else f.pc -| 1;
            const fspan: bytecode.Span = if (fpc < fp.spans.len) fp.spans[fpc] else .{};
            frames[self.depth - 1 - i] = .{
                .name = fp.name,
                .line = compiler.lineFromOffset(source, fspan.start),
                .start = fspan.start,
                .end = fspan.end,
            };
        }
        return frames;
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
    ///   6. effect-log heap results — a string-valued effect (`getenv`/`argv`)
    ///      parked in `effect_log` must outlive collection until it is serialized
    ///      (record) or fed back to the program (replay). Without this root, the
    ///      sweep would de-intern and free an otherwise-unreferenced result string.
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
        for (self.effect_log.items) |e| if (e.result.isHeap()) cb(ctx, e.result.asHeap());
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
            // Replay line-index recorder (off by default — the wasm record run
            // and the replay tests turn it on). Append the 1-based source line of
            // the instruction *about to run* at this safepoint, so the UI can map
            // safepoint k → its line for line-grain stepping. One branch + one
            // append per safepoint; tier-0's correctness oracle pays nothing when
            // off.
            if (self.record_safepoint_lines) {
                const sp_line: u32 = if (pc < proto.spans.len)
                    compiler.lineFromOffset(self.source, proto.spans[pc].start)
                else
                    0;
                try self.safepoint_lines.append(self.gpa, sp_line);
            }
            if (self.suspend_ctl) |sc| {
                if (self.safepoint_seq >= sc.after_safepoints and self.depth >= sc.min_depth) {
                    frame.pc = pc;
                    return .suspended;
                }
            }

            const cur_pc = pc;
            // Keep the faulting location recoverable: on a runtime error a `try`
            // below propagates straight out of `exec` (the explicit frame stack
            // is *not* unwound), so the top frame's `pc` is what `describeFault`
            // reads. One store/iteration; tier-0 is the correctness oracle, not a
            // hot tier (the JIT is the speed story).
            frame.pc = cur_pc;
            const instr = code[pc];
            pc += 1;
            // Phase 5 recording hook: while a trace is being recorded, mirror this
            // instruction (and its observed operand types) into the trace IR
            // *before* tier-0 executes it. Recording is transparent — tier-0 still
            // performs the operation below.
            if (self.trace.isRecording()) self.trace.recordInstr(instr, regs, proto, @intCast(pc));
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
                            // An effect native (clock) goes through the record/replay
                            // boundary; a pure host call (print) runs directly. A
                            // native call is already a trace barrier (recording
                            // aborts at it), so this seam doesn't touch the JIT.
                            const result = if (nat.effect) |kind|
                                try performEffect(self, kind, nat, args)
                            else
                                nat.func(@ptrCast(self), args) catch |e| return narrowError(e);
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
                            // Instrumented path (viz): record this entry's per-iteration
                            // events + exit ramp into the trace's exec log. Falls back
                            // to the uninstrumented executor if the recorder can't be
                            // set up. Observation-only — same `completed`/`regs`.
                            const completed = if (self.trace.config.record_exec_log)
                                blk: {
                                    const tid = self.trace.traceIndex(t) orelse break :blk irinterp.execute(t, regs, buf);
                                    const rec = self.trace.execRecorderFor(tid) orelse break :blk irinterp.execute(t, regs, buf);
                                    break :blk irinterp.executeTraced(rec, t, regs, buf);
                                }
                            else if (self.trace.config.native_codegen)
                                // Tier-1b: run compiled machine code if this trace is
                                // in the proven-int/bool subset; otherwise fall back to
                                // tier-1a. Mutually exclusive with the exec-log path
                                // above (the viz instrumentation observes the executor).
                                blk: {
                                    if (self.trace.nativeFor(t)) |ct| break :blk ct.run(regs);
                                    break :blk irinterp.execute(t, regs, buf);
                                }
                            else
                                irinterp.execute(t, regs, buf);
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
        error.ClockUnavailable => Error.ClockUnavailable,
        // `random()` reaches the effect machinery from *inside* its native (the
        // seed, not the call, is the boundary), so these surface through here —
        // unlike `clock`, which goes via `performEffect` and never narrows.
        error.RandomUnavailable => Error.RandomUnavailable,
        // `getenv`/`argc`/`argv` go through `performEffect`, which narrows their
        // native errors — so the missing-source signal must survive the round-trip.
        error.EnvUnavailable => Error.EnvUnavailable,
        error.EffectLogExhausted => Error.EffectLogExhausted,
        error.EffectKindMismatch => Error.EffectKindMismatch,
        else => Error.HostError,
    };
}

/// For an arithmetic fault on `x op y`, the operand that wasn't a number (the
/// one to blame). Falls back to `x` if both are numbers (shouldn't happen — the
/// op only faults when one isn't).
fn firstNonNumber(x: Value, y: Value) Value {
    return if (!x.isNumber()) x else y;
}

/// For a concatenation fault, the operand lune's `concat` couldn't coerce —
/// anything that is neither a number nor a string.
fn firstNonConcatable(x: Value, y: Value) Value {
    return if (!concatable(x)) x else y;
}

fn concatable(v: Value) bool {
    return v.isNumber() or (v.isHeap() and v.heapType() == .string);
}

/// The `print` built-in — the canonical host-effect at the embedding boundary.
/// Writes its arguments tab-separated, newline-terminated, to stdout (`io.zig`,
/// the one churny-writer wrapper) and returns `nil`. In a later phase this is
/// where an effect is *recorded* for deterministic replay
/// (docs/design/02-determinism.md); for now it just performs it.
/// Run a nondeterministic-input effect through the record/replay boundary.
///   - `off`    — call it normally (default; no log touched).
///   - `record` — call it, append `{kind, result}` to the ordered `effect_log`.
///   - `replay` — do NOT call it (the host clock would differ); feed back the
///                next logged result in call order. A mismatch in length or kind
///                means the recording doesn't match this run.
/// The log is consumed strictly in call order — `clock()` has no inputs, so the
/// instruction stream re-executed on replay requests effects in the same order
/// they were recorded.
fn performEffect(self: *Vm, kind: EffectKind, nat: *const function.Native, args: []const Value) Error!Value {
    switch (self.effect_mode) {
        .off => return nat.func(@ptrCast(self), args) catch |e| return narrowError(e),
        .record => {
            const result = nat.func(@ptrCast(self), args) catch |e| return narrowError(e);
            try logEffect(self, kind, result);
            return result;
        },
        .replay => return nextLoggedEffect(self, kind),
    }
}

/// Append one effect result to the ordered log (record mode). Shared by
/// `performEffect` (native-backed effects like `clock`) and the seed path.
fn logEffect(self: *Vm, kind: EffectKind, result: Value) Error!void {
    try self.effect_log.append(self.gpa, .{ .kind = kind, .result = result });
}

/// Consume the next logged effect in call order (replay mode), checking the run
/// hasn't outgrown or diverged from the recording. Shared by `performEffect` and
/// the seed path so both enforce the same `EffectLogExhausted`/`EffectKindMismatch`
/// guarantees.
fn nextLoggedEffect(self: *Vm, kind: EffectKind) Error!Value {
    if (self.effect_cursor >= self.effect_log.items.len) return Error.EffectLogExhausted;
    const e = self.effect_log.items[self.effect_cursor];
    self.effect_cursor += 1;
    if (e.kind != kind) return Error.EffectKindMismatch;
    return e.result;
}

/// Obtain `random()`'s one seed through the record/replay boundary. In
/// `off`/`record` it reads the injected entropy source (else `RandomUnavailable`)
/// and, in `record`, logs it once as `.random_seed` (a non-heap int — no schema
/// change). In `replay` it reads the seed back from the log. Called lazily by
/// `nativeRandom` the first time `random()` runs; subsequent draws need no effect.
fn obtainRandomSeed(self: *Vm) Error!u64 {
    switch (self.effect_mode) {
        .off, .record => {
            const src = self.random_seed_source orelse return Error.RandomUnavailable;
            const seed = src.seed(src.ctx);
            if (self.effect_mode == .record) try logEffect(self, .random_seed, Value.int(@bitCast(seed)));
            return seed;
        },
        .replay => {
            const v = try nextLoggedEffect(self, .random_seed);
            return @bitCast(v.asInt());
        },
    }
}

/// `clock()` — the canonical first nondeterministic *input* (doc 02). Returns the
/// host monotonic clock as integer nanoseconds. Pure-nondeterministic: two calls
/// differ, which is exactly why it must be recorded to replay deterministically.
/// Ignores its arguments. Reads the value through the embedder-injected
/// `Vm.clock_source` — the interpreter holds no platform clock of its own, so the
/// VM core compiles to any target (including `wasm32-freestanding`, which has no
/// clock syscall). With no source injected this is `ClockUnavailable`; the
/// `replay` path never reaches here (it feeds the log back in `performEffect`).
fn nativeClock(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const src = vm.clock_source orelse return Error.ClockUnavailable;
    return Value.int(src.nowNs(src.ctx));
}

/// `random()` — a float in `[0,1)`, drawn from the VM's own PRNG. The
/// nondeterministic *input* is a single seed (the `.random_seed` effect), obtained
/// lazily on the first call and recorded once; every draw after that is pure VM
/// state, so replay reproduces the whole stream from that one logged seed. The
/// PRNG is `std.Random.Xoshiro256` (pinned by name — see `Vm.rng`), so a given
/// seed yields the same sequence across runs and across the native/wasm engines.
/// Ignores its arguments for now (ranges are pure computation atop this — later).
fn nativeRandom(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    if (vm.rng == null) vm.rng = std.Random.Xoshiro256.init(try obtainRandomSeed(vm));
    return Value.float(vm.rng.?.random().float(f64));
}

/// `getenv(name)` — read an environment variable. A nondeterministic input (the
/// `.getenv` effect): the host environment differs between machines/runs, so it
/// is recorded and replayed. Reads through the embedder-injected `Vm.host_env`
/// (the VM holds no platform env of its own). Returns the value as an interned
/// heap string, or `nil` if unset — note a *set-but-empty* var returns an empty
/// string, distinct from `nil`. The `replay` path never reaches here (the logged
/// result is fed back in `performEffect`).
fn nativeGetenv(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    if (args.len < 1 or !args[0].isHeap() or args[0].heapType() != .string)
        return Error.TypeError;
    const name = string.String.fromHeader(args[0].asHeap()).bytes();
    const env = vm.host_env orelse return Error.EnvUnavailable;
    if (env.getenv(env.ctx, name)) |val| {
        return vm.heap.internValue(val);
    }
    return Value.nil();
}

/// `argc()` — the number of command-line arguments. A nondeterministic input
/// (the `.argc` effect). Ignores its arguments; reads through `Vm.host_env`.
fn nativeArgc(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const env = vm.host_env orelse return Error.EnvUnavailable;
    return Value.int(env.argCount(env.ctx));
}

/// `argv(i)` — the i-th command-line argument as an interned heap string, or
/// `nil` if the index is out of range (the host source owns the bounds check, so
/// negative and oversized indices both yield `nil`). A nondeterministic input
/// (the `.argv` effect); reads through `Vm.host_env`.
fn nativeArgv(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    if (args.len < 1 or args[0].tag != .int) return Error.TypeError;
    const env = vm.host_env orelse return Error.EnvUnavailable;
    if (env.arg(env.ctx, args[0].asInt())) |s| {
        return vm.heap.internValue(s);
    }
    return Value.nil();
}

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

// ---------------------------------------------------------------------------
// Minimal host stdlib (benchmark harness): tonumber, string.format, io.write.
// All pure host calls (no effects). See `base_natives`.
// ---------------------------------------------------------------------------

/// The bytes of `v` if it is a heap string, else null.
fn strBytes(v: Value) ?[]const u8 {
    if (v.isHeap() and v.heapType() == .string) return string.String.fromHeader(v.asHeap()).bytes();
    return null;
}

/// `tonumber(v [, base])`. Numbers pass through. A string is trimmed and parsed:
/// with an explicit `base` as an integer in that base; otherwise auto (int first —
/// honoring a `0x` prefix — then float). Anything unparseable / non-numeric → nil.
fn nativeTonumber(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    if (args.len == 0) return Value.nil();
    const v = args[0];

    // Explicit base form: `tonumber(s, base)` — string interpreted as an integer.
    if (args.len >= 2 and args[1].isNumber()) {
        const base_i = args[1].toFloat();
        if (base_i < 2 or base_i > 36) return Value.nil();
        const base: u8 = @intFromFloat(base_i);
        const s = strBytes(v) orelse return Value.nil();
        const t = std.mem.trim(u8, s, " \t\n\r");
        if (t.len == 0) return Value.nil();
        const parsed = std.fmt.parseInt(i64, t, base) catch return Value.nil();
        return Value.int(parsed);
    }

    switch (v.tag) {
        .int, .float => return v,
        else => {},
    }
    const s = strBytes(v) orelse return Value.nil();
    const t = std.mem.trim(u8, s, " \t\n\r");
    if (t.len == 0) return Value.nil();
    if (std.fmt.parseInt(i64, t, 0)) |iv| {
        return Value.int(iv);
    } else |_| {}
    if (std.fmt.parseFloat(f64, t)) |fv| {
        return Value.float(fv);
    } else |_| {}
    return Value.nil();
}

/// `io.write(...)`: write each argument's bytes to the VM's output with no
/// separators and no trailing newline (contrast `print`). Strings write their
/// bytes; numbers format like concat (`coerceConcat`). Non-string/number → error.
fn nativeIoWrite(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const to_stdout = vm.out == null;
    const w = vm.out orelse io.stdout();
    var buf: [64]u8 = undefined;
    for (args) |a| {
        const bytes = try coerceConcat(a, &buf);
        try w.writeAll(bytes);
    }
    if (to_stdout) io.flush();
    return Value.nil();
}

/// A parsed `%`-conversion specifier: `%[-+ 0#][width][.prec]<conv>`.
const FormatSpec = struct {
    minus: bool = false, // '-' left-justify
    zero: bool = false, // '0' zero-pad
    plus: bool = false, // '+' force sign on positives
    space: bool = false, // ' ' leading space on positives
    hash: bool = false, // '#' alternate form (o/x/X)
    width: usize = 0,
    precision: ?usize = null,
    conv: u8 = 0,
};

fn appendN(out: *std.ArrayList(u8), gpa: std.mem.Allocator, byte: u8, n: usize) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) try out.append(gpa, byte);
}

/// Emit a numeric field: optional `prefix` (sign and/or `0x`), then `digits`,
/// applying integer `precision` (minimum digit count → zero-extend) and field
/// `width` with the `-`/`0` flags. Used by both integer and float conversions
/// (floats pass `precision == null`, having already rendered their fraction).
fn emitNumeric(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    prefix: []const u8,
    digits: []const u8,
    spec: FormatSpec,
) !void {
    var zext: usize = 0; // precision-driven zero extension of the digits
    if (spec.precision) |p| {
        if (digits.len < p) zext = p - digits.len;
    }
    const body_len = prefix.len + zext + digits.len;
    const pad: usize = if (spec.width > body_len) spec.width - body_len else 0;
    // C/Lua: the `0` flag is ignored when an explicit precision is given for ints.
    const zero_pad = spec.zero and !spec.minus and spec.precision == null;

    if (spec.minus) {
        try out.appendSlice(gpa, prefix);
        try appendN(out, gpa, '0', zext);
        try out.appendSlice(gpa, digits);
        try appendN(out, gpa, ' ', pad);
    } else if (zero_pad) {
        try out.appendSlice(gpa, prefix);
        try appendN(out, gpa, '0', pad);
        try appendN(out, gpa, '0', zext);
        try out.appendSlice(gpa, digits);
    } else {
        try appendN(out, gpa, ' ', pad);
        try out.appendSlice(gpa, prefix);
        try appendN(out, gpa, '0', zext);
        try out.appendSlice(gpa, digits);
    }
}

/// Coerce a `string.format` numeric argument to a signed integer, truncating a
/// float toward zero. Errors on a non-number or an out-of-range / non-finite float.
fn argToInt(v: Value) Error!i64 {
    switch (v.tag) {
        .int => return v.asInt(),
        .float => {
            const f = v.asFloat();
            if (!std.math.isFinite(f) or f >= 9.223372036854776e18 or f < -9.223372036854776e18) {
                return Error.TypeError;
            }
            return @intFromFloat(@trunc(f));
        },
        else => return Error.TypeError,
    }
}

fn signPrefix(neg: bool, spec: FormatSpec) []const u8 {
    if (neg) return "-";
    if (spec.plus) return "+";
    if (spec.space) return " ";
    return "";
}

/// `string.format(fmt, ...)` — a focused C-`printf` supporting Lua's conversions:
/// `d i u o x X c` (integers), `f F e E g G` (floats), `s` (strings, precision =
/// max length), `q` (Lua-quoted), and `%%`. Honors the `- + space 0 #` flags,
/// width, and precision.
fn nativeStringFormat(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    if (args.len < 1) return Error.TypeError;
    const fmt = strBytes(args[0]) orelse return Error.TypeError;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    const gpa = vm.gpa;

    var argi: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        i += 1; // consume '%'
        if (i >= fmt.len) return Error.TypeError;
        if (fmt[i] == '%') {
            try out.append(gpa, '%');
            i += 1;
            continue;
        }

        var spec: FormatSpec = .{};
        // flags
        flags: while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => spec.minus = true,
                '0' => spec.zero = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '#' => spec.hash = true,
                else => break :flags,
            }
        }
        // width
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
            spec.width = spec.width * 10 + (fmt[i] - '0');
        }
        // precision
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            var p: usize = 0;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                p = p * 10 + (fmt[i] - '0');
            }
            spec.precision = p;
        }
        if (i >= fmt.len) return Error.TypeError;
        spec.conv = fmt[i];
        i += 1;

        // `%%` already handled; every remaining conversion consumes one argument.
        if (argi >= args.len) return Error.TypeError;
        const arg = args[argi];
        argi += 1;

        var nbuf: [512]u8 = undefined;
        switch (spec.conv) {
            'd', 'i' => {
                const n = try argToInt(arg);
                const neg = n < 0;
                const un: u64 = @bitCast(n);
                const mag: u64 = if (neg) (~un +% 1) else un; // |n| in two's complement (safe at minInt)
                const digits = std.fmt.bufPrint(&nbuf, "{d}", .{mag}) catch unreachable;
                try emitNumeric(&out, gpa, signPrefix(neg, spec), digits, spec);
            },
            'u' => {
                const n = try argToInt(arg);
                const digits = std.fmt.bufPrint(&nbuf, "{d}", .{@as(u64, @bitCast(n))}) catch unreachable;
                try emitNumeric(&out, gpa, "", digits, spec);
            },
            'o' => {
                const n = try argToInt(arg);
                const digits = std.fmt.bufPrint(&nbuf, "{o}", .{@as(u64, @bitCast(n))}) catch unreachable;
                const prefix: []const u8 = if (spec.hash and !(digits.len == 1 and digits[0] == '0')) "0" else "";
                try emitNumeric(&out, gpa, prefix, digits, spec);
            },
            'x', 'X' => {
                const n = try argToInt(arg);
                const u: u64 = @bitCast(n);
                const digits = if (spec.conv == 'x')
                    std.fmt.bufPrint(&nbuf, "{x}", .{u}) catch unreachable
                else
                    std.fmt.bufPrint(&nbuf, "{X}", .{u}) catch unreachable;
                const prefix: []const u8 = if (spec.hash and u != 0)
                    (if (spec.conv == 'x') "0x" else "0X")
                else
                    "";
                try emitNumeric(&out, gpa, prefix, digits, spec);
            },
            'c' => {
                const n = try argToInt(arg);
                const ch: u8 = @truncate(@as(u64, @bitCast(n)));
                try emitNumeric(&out, gpa, "", &[_]u8{ch}, .{ .minus = spec.minus, .width = spec.width });
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                if (!arg.isNumber()) return Error.TypeError;
                const f = arg.toFloat();
                const neg = std.math.signbit(f) and !std.math.isNan(f);
                const mag = if (neg) -f else f;
                const lower = spec.conv == 'f' or spec.conv == 'e' or spec.conv == 'g';
                const mode: std.fmt.float.Mode = switch (spec.conv) {
                    'e', 'E' => .scientific,
                    else => .decimal,
                };
                // `%f/%e` default to 6 fractional digits; `%g` defaults to shortest.
                const prec: ?usize = spec.precision orelse switch (spec.conv) {
                    'g', 'G' => null,
                    else => 6,
                };
                var rbuf: [512]u8 = undefined;
                const rendered = std.fmt.float.render(&rbuf, mag, .{ .mode = mode, .precision = prec }) catch
                    return Error.TypeError;
                // `render` lower-cases the exponent 'e'; upper-case for E/G.
                var body = rendered;
                if (!lower) {
                    for (rbuf[0..rendered.len], 0..) |rc, k| {
                        if (rc == 'e') rbuf[k] = 'E';
                    }
                    body = rbuf[0..rendered.len];
                }
                // Float precision is already applied: pass precision=null to emit.
                var fspec = spec;
                fspec.precision = null;
                try emitNumeric(&out, gpa, signPrefix(neg, spec), body, fspec);
            },
            's' => {
                if (strBytes(arg)) |full| {
                    const body = if (spec.precision) |p| full[0..@min(p, full.len)] else full;
                    try emitString(&out, gpa, body, spec);
                } else if (arg.isNumber()) {
                    var sbuf: [64]u8 = undefined;
                    const full = try coerceConcat(arg, &sbuf);
                    const body = if (spec.precision) |p| full[0..@min(p, full.len)] else full;
                    try emitString(&out, gpa, body, spec);
                } else {
                    try formatNonStr(&out, gpa, arg, spec);
                }
            },
            'q' => {
                const s = strBytes(arg) orelse return Error.TypeError;
                try out.append(gpa, '"');
                for (s) |qc| switch (qc) {
                    '"' => try out.appendSlice(gpa, "\\\""),
                    '\\' => try out.appendSlice(gpa, "\\\\"),
                    '\n' => try out.appendSlice(gpa, "\\n"),
                    '\r' => try out.appendSlice(gpa, "\\r"),
                    0 => try out.appendSlice(gpa, "\\0"),
                    else => try out.append(gpa, qc),
                };
                try out.append(gpa, '"');
            },
            else => return Error.TypeError, // unknown conversion
        }
    }

    return vm.heap.internValue(out.items);
}

/// Emit a string field with width + `-` justification (the `0` flag is ignored
/// for `%s`, matching C/Lua).
fn emitString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, body: []const u8, spec: FormatSpec) !void {
    const pad: usize = if (spec.width > body.len) spec.width - body.len else 0;
    if (spec.minus) {
        try out.appendSlice(gpa, body);
        try appendN(out, gpa, ' ', pad);
    } else {
        try appendN(out, gpa, ' ', pad);
        try out.appendSlice(gpa, body);
    }
}

/// `%s` fallback for nil/boolean (Lua applies `tostring`).
fn formatNonStr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: Value, spec: FormatSpec) !void {
    const body: []const u8 = switch (v.tag) {
        .nil => "nil",
        .boolean => if (v.asBool()) "true" else "false",
        else => return Error.TypeError,
    };
    const trimmed = if (spec.precision) |p| body[0..@min(p, body.len)] else body;
    try emitString(out, gpa, trimmed, spec);
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

test "describeFault: arithmetic on a nil value names the op, type, line, and span" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const src =
        \\local s = 0
        \\s = s + d
    ;
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compiler.compile(testing.allocator, &vm.heap, src, tree.root, &diags);
    defer chunk.deinit();

    try testing.expectError(Error.TypeError, vm.run(chunk.proto));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fault = try vm.describeFault(src, Error.TypeError, arena.allocator());
    try testing.expectEqual(@as(u32, 2), fault.line);
    try testing.expect(std.mem.indexOf(u8, fault.message, "arithmetic") != null);
    try testing.expect(std.mem.indexOf(u8, fault.message, "nil") != null);
    // The faulting span underlines the whole `s + d` operation on line 2.
    try testing.expectEqualStrings("s + d", src[fault.start..fault.end]);
}

test "describeFault: calling a nil value names the call and the type" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const src =
        \\local f
        \\f()
    ;
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compiler.compile(testing.allocator, &vm.heap, src, tree.root, &diags);
    defer chunk.deinit();

    try testing.expectError(Error.TypeError, vm.run(chunk.proto));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fault = try vm.describeFault(src, Error.TypeError, arena.allocator());
    try testing.expectEqual(@as(u32, 2), fault.line);
    try testing.expect(std.mem.indexOf(u8, fault.message, "call") != null);
    try testing.expect(std.mem.indexOf(u8, fault.message, "nil") != null);
}

test "describeFault: a nested fault yields a deepest-first backtrace (leaf + call site)" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    // `f` faults on line 2 (nil arithmetic); it is called from `main` on line 5.
    const src =
        \\function f(x)
        \\  return x + nope
        \\end
        \\local s = 0
        \\s = f(1)
    ;
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compiler.compile(testing.allocator, &vm.heap, src, tree.root, &diags);
    defer chunk.deinit();

    try testing.expectError(Error.TypeError, vm.run(chunk.proto));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fault = try vm.describeFault(src, Error.TypeError, arena.allocator());

    // Two live frames at the fault: f (leaf) called from main.
    try testing.expectEqual(@as(usize, 2), fault.frames.len);
    // Leaf = f, faulting on line 2; top-level fields mirror the leaf.
    try testing.expectEqualStrings("f", fault.frames[0].name);
    try testing.expectEqual(@as(u32, 2), fault.frames[0].line);
    try testing.expectEqual(@as(u32, 2), fault.line);
    try testing.expect(std.mem.indexOf(u8, fault.message, "arithmetic") != null);
    // Parent = main, located at the call site `f(1)` on line 5 (pc -| 1).
    try testing.expectEqualStrings("main", fault.frames[1].name);
    try testing.expectEqual(@as(u32, 5), fault.frames[1].line);
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
// Minimal host stdlib — tonumber / string.format / io.write / arg.
// Driven through the full front end so the module-table dispatch
// (get_global → get_index → call) and the lint-known globals are exercised.
// ---------------------------------------------------------------------------

/// Run `source` (tier-0, no GC stress) and return the captured output bytes in
/// `sink` for assertion.
fn runOut(source: [:0]const u8, sink: *io.Writer) !void {
    try runCaptured(testing.allocator, source, sink, false, .off);
}

test "stdlib: tonumber parses ints, floats, hex, explicit base; passes numbers; nil otherwise" {
    var buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\print(tonumber("42"))
        \\print(tonumber("  3.5 "))
        \\print(tonumber("0x1F"))
        \\print(tonumber("777", 8))
        \\print(tonumber(123))
        \\print(tonumber("abc"))
        \\print(tonumber(nil))
    , &sink);
    try testing.expectEqualStrings("42\n3.5\n31\n511\n123\nnil\nnil\n", sink.buffered());
}

test "stdlib: string.format covers d/width/justify/zero, float, hex, string precision, q, %%" {
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\print(string.format("%d", 42))
        \\print(string.format("[%8d]", 40000))
        \\print(string.format("[%-8d]", 42))
        \\print(string.format("[%08d]", 42))
        \\print(string.format("%d", 3.0))
        \\print(string.format("[%5.2f]", 3.14159))
        \\print(string.format("%x/%X", 255, 255))
        \\print(string.format("[%.3s]", "hello"))
        \\print(string.format("%q", "a\"b"))
        \\print(string.format("100%%"))
    , &sink);
    try testing.expectEqualStrings(
        "42\n" ++
            "[   40000]\n" ++
            "[42      ]\n" ++
            "[00000042]\n" ++
            "3\n" ++
            "[ 3.14]\n" ++
            "ff/FF\n" ++
            "[hel]\n" ++
            "\"a\\\"b\"\n" ++
            "100%\n",
        sink.buffered(),
    );
}

test "stdlib: io.write emits args with no separators and no trailing newline" {
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\io.write("a", 1, "b")
        \\io.write("!")
    , &sink);
    try testing.expectEqualStrings("a1b!", sink.buffered());
}

test "stdlib: the exact nsieve format line matches LuaJIT byte-for-byte" {
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\io.write(string.format("Primes up to %8d %8d\n", 40000, 4203))
    , &sink);
    try testing.expectEqualStrings("Primes up to    40000     4203\n", sink.buffered());
}

test "stdlib: arg is an empty table by default (no host args)" {
    var buf: [32]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\print(arg[1])
        \\print(tonumber(arg and arg[1]) or 7)
    , &sink);
    // `arg` exists (a table) so `arg and arg[1]` is nil → tonumber(nil) → nil → 7.
    try testing.expectEqualStrings("nil\n7\n", sink.buffered());
}

test "stdlib: nsieve runs end-to-end and matches LuaJIT (correctness milestone)" {
    // Full program from `~/Projects/LuaJIT/bench/nsieve.lua`. No host args, so
    // `N` defaults to 1 → clamped to 2 → primes up to 40000/20000/10000.
    const nsieve =
        \\local function nsieve(p, m)
        \\  for i=2,m do p[i] = true end
        \\  local count = 0
        \\  for i=2,m do
        \\    if p[i] then
        \\      for k=i+i,m,i do p[k] = false end
        \\      count = count + 1
        \\    end
        \\  end
        \\  return count
        \\end
        \\
        \\local N = tonumber(arg and arg[1]) or 1
        \\if N < 2 then N = 2 end
        \\local primes = {}
        \\
        \\for i=0,2 do
        \\  local m = (2^(N-i))*10000
        \\  io.write(string.format("Primes up to %8d %8d\n", m, nsieve(primes, m)))
        \\end
    ;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(nsieve, &sink);
    try testing.expectEqualStrings(
        "Primes up to    40000     4203\n" ++
            "Primes up to    20000     2262\n" ++
            "Primes up to    10000     1229\n",
        sink.buffered(),
    );
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
///  * `record_execute_native`— Phase-8: run cached traces as native machine code
///    where they fall in the proven-int/bool subset (silent tier-1a fallback else).
const TraceMode = enum { off, record_only, record_execute_noopt, record_execute, record_execute_native };

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
    vm.trace.config.execute = mode == .record_execute or mode == .record_execute_noopt or mode == .record_execute_native;
    vm.trace.config.optimize = mode == .record_execute or mode == .record_execute_native;
    vm.trace.config.native_codegen = mode == .record_execute_native;
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
        inline for (.{ .off, .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
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

// ---------------------------------------------------------------------------
// F2d — effect record / replay
//
// `clock()` is the first nondeterministic *input*: two calls differ, so two
// independent runs of a clock()-using program print different output. Recording
// the effect log and replaying it makes re-execution reproducible — the
// foundation deterministic replay (restore a keyframe, feed effects back) stands
// on. These tests prove (1) replay reproduces the recorded output exactly, (2)
// two fresh records genuinely differ (the nondeterminism is real), and (3) a
// short / exhausted log is reported, not silently wrong.
// ---------------------------------------------------------------------------

const EffectRun = struct {
    out: []u8,
    log: []Effect,
    fn deinit(self: EffectRun, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.log);
    }
};

/// A deterministic test clock: returns `next`, `next+step`, `next+2*step`, …
/// Injected as a `ClockSource` so tests don't depend on the wall clock. Two
/// distinct counters model the nondeterminism a real clock has between runs.
const CounterClock = struct {
    next: i64,
    step: i64 = 1,
    fn nowNs(ctx: *anyopaque) i64 {
        const self: *CounterClock = @ptrCast(@alignCast(ctx));
        const v = self.next;
        self.next += self.step;
        return v;
    }
    fn source(self: *CounterClock) ClockSource {
        return .{ .ctx = self, .nowNs = &CounterClock.nowNs };
    }
};

/// A deterministic test seed source: always hands back the same `value`. Injected
/// as a `RandomSeedSource` so `random()` tests don't depend on OS entropy. Two
/// distinct fixed seeds model the nondeterminism a real seed has between runs.
const FixedSeed = struct {
    value: u64,
    fn seed(ctx: *anyopaque) u64 {
        const self: *FixedSeed = @ptrCast(@alignCast(ctx));
        return self.value;
    }
    fn source(self: *FixedSeed) RandomSeedSource {
        return .{ .ctx = self, .seed = &FixedSeed.seed };
    }
};

/// A deterministic test env/args source for `getenv`/`argc`/`argv`. Holds a tiny
/// fixed environment + argv so tests don't depend on the real process. `HOME` is
/// set, `EMPTY` is set-but-empty (to exercise the ""-vs-unset distinction), and
/// every other name is unset (→ nil).
const FakeEnv = struct {
    home: []const u8 = "/home/bart",
    args: []const []const u8 = &.{ "prog", "alpha", "beta" },
    fn getenvFn(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "HOME")) return self.home;
        if (std.mem.eql(u8, name, "EMPTY")) return ""; // set, but empty — not nil
        return null;
    }
    fn argCountFn(ctx: *anyopaque) i64 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        return @intCast(self.args.len);
    }
    fn argFn(ctx: *anyopaque, i: i64) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        if (i < 0 or i >= self.args.len) return null;
        return self.args[@intCast(i)];
    }
    fn source(self: *FakeEnv) HostEnv {
        return .{
            .ctx = self,
            .getenv = &FakeEnv.getenvFn,
            .argCount = &FakeEnv.argCountFn,
            .arg = &FakeEnv.argFn,
        };
    }
};

/// Compile + run `source` on an already-configured `vm` (out sink, effect mode,
/// and any injected sources set by the caller). Kept separate from `effectRun` so
/// env tests can inspect `vm.effect_log` (whose string results live in `vm.heap`)
/// while the VM is still alive — `effectRun` dupes the log across `vm.deinit`,
/// which would dangle a heap-string result.
fn compileRun(gpa: std.mem.Allocator, vm: *Vm, source: [:0]const u8) !void {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());
    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
}

/// Compile + run `source` with the given effect mode. `preload` (replay only)
/// seeds the effect log fed back in call order. `clock` (record/off only) is the
/// injected deterministic clock; replay needs none (it feeds the log back).
/// Returns owned copies of the printed output and the resulting effect log
/// (`clock` results are ints, so the log is self-contained — safe past `vm.deinit`).
fn effectRun(gpa: std.mem.Allocator, source: [:0]const u8, mode: EffectMode, preload: []const Effect, clock: ?*CounterClock, seed: ?*FixedSeed) !EffectRun {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = mode;
    if (clock) |c| vm.clock_source = c.source();
    if (seed) |s| vm.random_seed_source = s.source();
    if (preload.len > 0) try vm.effect_log.appendSlice(gpa, preload);

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    return .{
        .out = try gpa.dupe(u8, sink.buffered()),
        .log = try gpa.dupe(Effect, vm.effect_log.items),
    };
}

test "F2d: replaying a recorded effect log reproduces the recorded output" {
    const gpa = testing.allocator;
    // Output that *depends on* the clock values, so replay fidelity is observable.
    const source =
        \\for i = 1, 4 do print(clock()) end
    ;

    // Record a run against a known clock sequence (1000, 1001, …): the printed
    // values land in `out`, the effects in `log`.
    var clk = CounterClock{ .next = 1000 };
    const rec = try effectRun(gpa, source, .record, &.{}, &clk, null);
    defer rec.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), rec.log.len);

    // Replay the SAME log into a fresh VM with NO clock injected: clock() is not
    // called — the logged values are fed back — so output is byte-identical.
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    // Replay re-emits the same effects into its own log (every clock() consumed one).
    try testing.expectEqual(rec.log.len, rep.log.len);

    // A second record against a DIFFERENT clock sequence (9000, 9001, …) genuinely
    // differs — modelling the nondeterminism a real clock has between runs, which is
    // exactly what the log captures. (With injection the clock is deterministic, so
    // we vary it explicitly rather than leaning on wall-clock advance.)
    var clk2 = CounterClock{ .next = 9000 };
    const rec2 = try effectRun(gpa, source, .record, &.{}, &clk2, null);
    defer rec2.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, rec.out, rec2.out));
}

test "F2d: replay with a too-short log reports EffectLogExhausted (no silent divergence)" {
    const gpa = testing.allocator;
    const source =
        \\print(clock()); print(clock())
    ;
    // A one-entry log for a program that asks for two effects. Replay feeds the
    // log back (no clock needed) and runs out on the second call.
    const short = [_]Effect{.{ .kind = .clock, .result = Value.int(123) }};
    try testing.expectError(error.EffectLogExhausted, effectRun(gpa, source, .replay, &short, null, null));
}

test "F2d: off mode logs nothing and calls effects normally (default behaviour)" {
    const gpa = testing.allocator;
    // Off mode calls the injected clock directly and logs nothing.
    var clk = CounterClock{ .next = 1 };
    const run = try effectRun(gpa, "print(clock() > 0)", .off, &.{}, &clk, null);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), run.log.len);
    try testing.expectEqualStrings("true\n", run.out);
}

test "F2d: clock() with no injected source is ClockUnavailable" {
    const gpa = testing.allocator;
    // The interpreter holds no clock of its own; record/off with no source set
    // surfaces a clear error rather than reaching for a platform clock.
    try testing.expectError(error.ClockUnavailable, effectRun(gpa, "print(clock())", .record, &.{}, null, null));
}

// ---------------------------------------------------------------------------
// F2e — seed-based randomness
//
// `random()` is a nondeterministic *input* like `clock()`, but seed-based: the
// single recorded effect is one `random_seed`, acquired lazily on the first call,
// from which a VM-internal PRNG reproduces the entire draw stream on replay. So a
// multi-draw program records exactly ONE effect, and replaying that one seed
// reproduces every draw byte-identically. These tests prove (1) record→replay
// fidelity with a single logged seed, (2) different seeds yield different streams
// (the PRNG genuinely varies), (3) a missing seed in the log is reported, (4) no
// injected source is a clear error, and (5) draws lie in [0,1).
// ---------------------------------------------------------------------------

test "F2e: replaying the recorded seed reproduces the whole draw stream" {
    const gpa = testing.allocator;
    // Three draws — proving the single seed drives the entire stream, not one call.
    const source =
        \\print(random()); print(random()); print(random())
    ;

    var sd = FixedSeed{ .value = 0xC0FFEE };
    const rec = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer rec.deinit(gpa);
    // Exactly one effect logged regardless of draw count: the seed, acquired once.
    try testing.expectEqual(@as(usize, 1), rec.log.len);
    try testing.expectEqual(EffectKind.random_seed, rec.log[0].kind);

    // Replay the one-entry log into a fresh VM with NO seed source: random() is
    // still called (it is a pure native), but the seed comes from the log, so the
    // PRNG reproduces the identical stream and output is byte-identical.
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    try testing.expectEqual(rec.log.len, rep.log.len);
}

test "F2e: different seeds yield different draw streams" {
    const gpa = testing.allocator;
    const source =
        \\print(random()); print(random())
    ;
    var sd_a = FixedSeed{ .value = 1 };
    var sd_b = FixedSeed{ .value = 2 };
    const a = try effectRun(gpa, source, .record, &.{}, null, &sd_a);
    defer a.deinit(gpa);
    const b = try effectRun(gpa, source, .record, &.{}, null, &sd_b);
    defer b.deinit(gpa);
    // Same seed would mean same stream; two distinct seeds must differ (this is
    // the nondeterminism the log captures — two fresh records use fresh seeds).
    try testing.expect(!std.mem.eql(u8, a.out, b.out));
}

test "F2e: replay with no seed in the log reports EffectLogExhausted" {
    const gpa = testing.allocator;
    // An empty log for a program that needs the seed: replay runs out immediately.
    try testing.expectError(error.EffectLogExhausted, effectRun(gpa, "print(random())", .replay, &.{}, null, null));
}

test "F2e: random() with no injected source is RandomUnavailable" {
    const gpa = testing.allocator;
    // The VM owns the PRNG but not the seed; record/off with no source set
    // surfaces a clear error rather than reaching for OS entropy itself.
    try testing.expectError(error.RandomUnavailable, effectRun(gpa, "print(random())", .record, &.{}, null, null));
}

test "F2e: draws lie in [0,1)" {
    const gpa = testing.allocator;
    // `r < 1 and r >= 0` over several draws — the float() contract.
    const source =
        \\local ok = true
        \\for i = 1, 50 do
        \\  local r = random()
        \\  if r < 0 or r >= 1 then ok = false end
        \\end
        \\print(ok)
    ;
    var sd = FixedSeed{ .value = 42 };
    const run = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\n", run.out);
}

// ---------------------------------------------------------------------------
// env/args effects — `getenv`/`argc`/`argv` as nondeterministic inputs. These
// are the first effects whose result is a heap *string*, so they exercise (a)
// the value semantics (set vs unset vs empty, argv bounds), (b) the replay
// feed-back of a string result, and (c) the GC-root that keeps a parked string
// result alive across a collection. The cross-run *byte* equivalence (serialize
// → replay) is proven in `effectser`'s round-trip test, where a standalone
// effect-log blob sidesteps cross-heap string lifetimes.
// ---------------------------------------------------------------------------

test "env: getenv reads set/unset/empty; argc/argv read the args (record)" {
    const gpa = testing.allocator;
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();

    try compileRun(gpa, &vm,
        \\print(getenv("HOME"))
        \\print(getenv("MISSING"))
        \\print(getenv("EMPTY") == "")
        \\print(argc())
        \\print(argv(0)); print(argv(2))
        \\print(argv(5))
    );
    // HOME set; MISSING → nil; EMPTY is set-but-empty (== "" is true, not nil);
    // argc = 3; argv(0)/argv(2) in range; argv(5) out of range → nil.
    try testing.expectEqualStrings(
        "/home/bart\nnil\ntrue\n3\nprog\nbeta\nnil\n",
        sink.buffered(),
    );
    // One effect logged per effect call: 3 getenv + 1 argc + 3 argv = 7.
    try testing.expectEqual(@as(usize, 7), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.getenv, vm.effect_log.items[0].kind);
    try testing.expectEqual(EffectKind.argc, vm.effect_log.items[3].kind);
    try testing.expectEqual(EffectKind.argv, vm.effect_log.items[4].kind);
}

test "env: getenv/argc/argv with no host_env injected is EnvUnavailable" {
    const gpa = testing.allocator;
    inline for (.{ "print(getenv(\"X\"))", "print(argc())", "print(argv(0))" }) |src| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.effect_mode = .record; // no host_env set
        try testing.expectError(error.EnvUnavailable, compileRun(gpa, &vm, src));
    }
}

test "env: a recorded string result survives a GC collection while parked in the log" {
    const gpa = testing.allocator;
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    vm.host_env = fenv.source();

    // Read HOME but discard the result — nothing references the string except the
    // effect log. A collection would de-intern + free it without the new root.
    try compileRun(gpa, &vm, "getenv(\"HOME\")");
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);

    vm.collect(); // force a stop-the-world sweep

    // The logged result must still be a live string reading "/home/bart".
    const res = vm.effect_log.items[0].result;
    try testing.expect(res.isHeap() and res.heapType() == .string);
    try testing.expectEqualStrings("/home/bart", string.String.fromHeader(res.asHeap()).bytes());
}

test "env: replay feeds back a logged string result without calling the native" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    // Preload a getenv result interned into *this* VM's heap, then replay with no
    // host_env injected: getenv is not called — the logged string is fed back.
    const logged = try vm.heap.internValue("REPLAYED");
    try vm.effect_log.append(gpa, .{ .kind = .getenv, .result = logged });
    vm.effect_mode = .replay;

    try compileRun(gpa, &vm, "print(getenv(\"IGNORED\"))");
    try testing.expectEqualStrings("REPLAYED\n", sink.buffered());
}

// ---------------------------------------------------------------------------
// v8 — replay-to-k core: the safepoint-line recorder + the stateless
// "replay to safepoint k" model the in-browser step-debugger drives.
//
// The browser never holds a live VM: to show the program at step k it
// re-compiles and re-runs forward to the k-th instruction-boundary safepoint
// (suspend_ctl.after_safepoints = k), then snapshots. These tests prove the two
// properties that make that sound and useful: (1) re-running to the same k is
// *consistent* (same pending line + same stdout-so-far every time — the
// determinism payoff), and (2) running past the last safepoint reproduces the
// uninterrupted full run exactly (no off-by-one swallows or duplicates the tail).
// The line index `safepoint_lines` underpins the UI's line-grain stepping.
// ---------------------------------------------------------------------------

/// The state observed at a single replay stop: the pending source line, a copy
/// of stdout-so-far, the live call depth, and whether the program had already
/// finished before reaching `stop_after`.
const ReplayProbe = struct {
    line: u32,
    stdout: []u8,
    depth: u32,
    finished: bool,
    fn deinit(self: ReplayProbe, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Compile `source` and run it forward to safepoint `stop_after`, returning the
/// pending line + stdout-so-far + depth at that point (or the final state, with
/// `finished = true`, if the program completed first). A fresh VM each call —
/// exactly the stateless "replay to k" the browser driver performs.
fn replayProbe(gpa: std.mem.Allocator, source: [:0]const u8, stop_after: u64) !ReplayProbe {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [1024]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.suspend_ctl = .{ .after_safepoints = stop_after };

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    const outcome = try vm.start(chunk.proto);
    var line: u32 = 0;
    var finished = false;
    switch (outcome) {
        .suspended => {
            const frame = &vm.frames[vm.depth - 1];
            const proto = frame.closure.proto;
            if (frame.pc < proto.spans.len) {
                line = compiler.lineFromOffset(source, proto.spans[frame.pc].start);
            }
        },
        .finished => finished = true,
    }
    return .{
        .line = line,
        .stdout = try gpa.dupe(u8, sink.buffered()),
        .depth = vm.depth,
        .finished = finished,
    };
}

/// Run `source` to completion with the safepoint-line recorder on, returning the
/// per-safepoint line index (owned). Its length is the total safepoint count.
fn recordSafepointLines(gpa: std.mem.Allocator, source: [:0]const u8) ![]u32 {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [1024]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.source = source;
    vm.record_safepoint_lines = true;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    return gpa.dupe(u32, vm.safepoint_lines.items);
}

test "replay: re-running to the same safepoint k is consistent (line + stdout-so-far)" {
    const gpa = testing.allocator;
    const source: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 5 do
        \\  s = s + i
        \\  print(s)
        \\end
        \\print("done")
    ;
    // Probe every k from 1 up to a generous bound and assert a second probe to
    // the same k reproduces the identical (line, stdout-so-far, depth) tuple.
    var k: u64 = 1;
    while (k <= 80) : (k += 1) {
        const a = try replayProbe(gpa, source, k);
        defer a.deinit(gpa);
        const b = try replayProbe(gpa, source, k);
        defer b.deinit(gpa);
        try testing.expectEqual(a.line, b.line);
        try testing.expectEqual(a.depth, b.depth);
        try testing.expectEqual(a.finished, b.finished);
        try testing.expectEqualStrings(a.stdout, b.stdout);
    }
}

test "replay: stdout-so-far grows monotonically and the pending line stays in range" {
    const gpa = testing.allocator;
    const source: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 3 do
        \\  s = s + i
        \\  print(s)
        \\end
    ;
    var prev_len: usize = 0;
    var k: u64 = 1;
    while (k <= 60) : (k += 1) {
        const p = try replayProbe(gpa, source, k);
        defer p.deinit(gpa);
        // stdout-so-far is a prefix-growing log: it never shrinks as k advances.
        try testing.expect(p.stdout.len >= prev_len);
        prev_len = p.stdout.len;
        // A pending line (when suspended) lies within the 4-line source.
        if (!p.finished) try testing.expect(p.line >= 1 and p.line <= 4);
    }
}

test "replay: running past the last safepoint reproduces the uninterrupted full run" {
    const gpa = testing.allocator;
    const programs = [_][:0]const u8{
        \\local s = 0
        \\for i = 1, 10 do s = s + i end
        \\print(s)
        ,
        \\local function f(x) return x * 2 end
        \\for i = 1, 4 do print(f(i)) end
        ,
    };
    inline for (programs) |source| {
        const lines = try recordSafepointLines(gpa, source);
        defer gpa.free(lines);
        const total: u64 = lines.len;
        try testing.expect(total > 0);
        // Every recorded line is a real, in-range source line (1-based).
        for (lines) |ln| try testing.expect(ln >= 1);

        // Replaying to total+1 never trips the suspend (max safepoint_seq == total),
        // so it runs to completion — byte-identical stdout to the full run.
        const replayed = try replayProbe(gpa, source, total + 1);
        defer replayed.deinit(gpa);
        try testing.expect(replayed.finished);

        // And a separate uninterrupted run prints the same thing.
        var ref_buf: [1024]u8 = undefined;
        var ref_sink = io.Writer.fixed(&ref_buf);
        try runCaptured(gpa, source, &ref_sink, false, .off);
        try testing.expectEqualStrings(ref_sink.buffered(), replayed.stdout);
    }
}

test "replay: backtraceFrames reports a deepest-first chain at a suspend inside a call" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source: [:0]const u8 =
        \\local function inner(x)
        \\  local y = x + 1
        \\  return y
        \\end
        \\local function outer(n)
        \\  return inner(n)
        \\end
        \\print(outer(7))
    ;
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
    // Suspend the first time we are at least 3 frames deep (main → outer → inner).
    vm.suspend_ctl = .{ .min_depth = 3, .after_safepoints = 0 };

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    const outcome = try vm.start(chunk.proto);
    try testing.expect(outcome == .suspended);
    try testing.expectEqual(@as(u32, 3), vm.depth);

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const frames = try vm.backtraceFrames(source, arena_inst.allocator());
    // Deepest-first: inner (leaf), outer, main.
    try testing.expectEqual(@as(usize, 3), frames.len);
    try testing.expectEqualStrings("inner", frames[0].name);
    try testing.expectEqualStrings("outer", frames[1].name);
    try testing.expectEqualStrings("main", frames[2].name);
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

/// Run `source` with tier-1a execution **and** exec-log recording on (small
/// `hotloop` so test loops go hot), capturing `print` output into `sink`. Returns
/// the compiled chunk so the caller can inspect `vm.trace.exec_logs` while the
/// anchor proto stays alive (free the chunk after asserting). `record` selects the
/// instrumented executor — pass false to exercise the uninstrumented path with an
/// otherwise identical config (the parity canary).
fn runForExecLog(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer, record: bool) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.out = sink;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.record_exec_log = record;
    vm.trace.config.hotloop = 4; // record short test loops

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

test "exec log captures a hot loop's iterations and its exit ramp" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    // One cached trace → one exec log keyed by its cache index (0).
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 1), vm.trace.exec_logs.items.len);
    const log = vm.trace.exec_logs.items[0];
    try testing.expectEqual(@as(u32, 0), log.trace_id);
    try testing.expect(!log.entries_capped);
    try testing.expect(log.entries.items.len >= 1);

    const entry = log.entries.items[0];
    // The trace spun real iterations before deopting.
    try testing.expect(entry.iterations > 0);
    // The event stream carries values, at least one surviving guard, commits, and a
    // terminal side-exit (the loop-bound guard failing is the exit ramp).
    var values: usize = 0;
    var guards: usize = 0;
    var commits: usize = 0;
    for (entry.events) |e| switch (e.kind) {
        .value => values += 1,
        .guard_pass => guards += 1,
        .commit => commits += 1,
        .exit => {},
    };
    try testing.expect(values > 0);
    try testing.expect(guards > 0);
    try testing.expect(commits > 0);
    // The last event is the exit ramp, and it names a real IR instruction.
    const last = entry.events[entry.events.len - 1];
    try testing.expectEqual(execlog.ExecEventKind.exit, last.kind);
    try testing.expect(last.ref < vm.trace.cache.items[0].instrs.len);
    try testing.expectEqual(execlog.ExitKind.guard, entry.exit_kind);
    try testing.expectEqual(@as(u32, last.ref), entry.exit_ref);
}

test "exec-log detail cap truncates iterations but keeps the count and exit" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.exec_log_max_iters = 2; // cap the spinning detail hard
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    const entry = vm.trace.exec_logs.items[0].entries.items[0];
    try testing.expect(entry.capped); // detail truncated
    // Detail truncated to <= 2 committed iterations of events…
    var commits: usize = 0;
    for (entry.events) |e| {
        if (e.kind == .commit) commits += 1;
    }
    try testing.expect(commits <= 2);
    // …but the real yield is still recorded, and the exit ramp survives the cap.
    try testing.expect(entry.iterations > 2);
    try testing.expectEqual(execlog.ExecEventKind.exit, entry.events[entry.events.len - 1].kind);
}

test "exec-log entry cap stops recording further entries" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.exec_log_max_entries = 0; // record nothing, just flag it
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    const log = vm.trace.exec_logs.items[0];
    try testing.expect(log.entries_capped);
    try testing.expectEqual(@as(usize, 0), log.entries.items.len);
}

test "exec-log recording is observation-only (record on/off agree)" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var off_buf: [64]u8 = undefined;
    var off_sink = io.Writer.fixed(&off_buf);
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForExecLog(&vm, gpa, source, &off_sink, false);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 0), vm.trace.exec_logs.items.len);
    }
    var on_buf: [64]u8 = undefined;
    var on_sink = io.Writer.fixed(&on_buf);
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForExecLog(&vm, gpa, source, &on_sink, true);
        defer chunk.deinit();
    }
    // Instrumentation must not perturb the program's observable output.
    try testing.expectEqualStrings(off_sink.buffered(), on_sink.buffered());
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

test "recorder: dead expression temporaries are dropped from the exit snapshot (task A)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `(i + 7) * (i + 7)` computes through expression-stack temporaries at slots
    // >= base+4. They are written and re-read within the iteration (never
    // slot_loaded → write-only), and dead at the loop header / after the loop, so
    // the recorder's watermark filter drops them from the exit snapshot.
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + (i + 7) * (i + 7) end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];

    // Recover the numeric-for base from the bytecode so the assertion does not
    // hard-code the compiler's register allocation. Control regs are base..base+3;
    // base+4 is the first temporary slot (the watermark).
    var base: ?u16 = null;
    for (chunk.proto.code) |ins| {
        if (ins.op == .for_loop) {
            base = ins.a;
            break;
        }
    }
    const watermark: usize = @as(usize, base.?) + 4;

    // Every surviving exit-store is either below the watermark (a real local /
    // loop control) or a slot the trace actually read — never a dead temporary.
    var saw_acc = false;
    for (t.exit_stores) |st| {
        const was_read = std.mem.indexOfScalar(u16, t.entry_slots, st.slot) != null;
        try testing.expect(@as(usize, st.slot) < watermark or was_read);
        if (st.slot == 0) saw_acc = true; // `acc` is the first local → slot 0
    }
    // The loop-carried accumulator is still committed.
    try testing.expect(saw_acc);
    // And no high write-only temporary leaked through.
    for (t.exit_stores) |st| {
        if (@as(usize, st.slot) >= watermark)
            try testing.expect(std.mem.indexOfScalar(u16, t.entry_slots, st.slot) != null);
    }
}

test "recorder: a while loop keeps its write-only temporaries (no for_loop watermark)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A while loop has no `for_loop`, so the watermark stays at its `maxInt`
    // sentinel and nothing is filtered. The `i <= 50` condition computes into a
    // write-only temporary (defined, never slot_loaded), which must survive in the
    // exit snapshot — proving the filter is inert without an anchoring for_loop.
    var chunk = try runForTrace(&vm, gpa,
        \\local i = 1
        \\local acc = 0
        \\while i <= 50 do acc = acc + i; i = i + 1 end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    const t = vm.trace.cache.items[0];
    // There must be at least one defined-but-never-read (write-only) slot still in
    // the snapshot — exactly what the for-loop filter would have removed.
    var saw_write_only = false;
    for (t.exit_stores) |st| {
        if (std.mem.indexOfScalar(u16, t.entry_slots, st.slot) == null) saw_write_only = true;
    }
    try testing.expect(saw_write_only);
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

// ---------------------------------------------------------------------------
// Tier-1b (native codegen) integration — the compiled trace must be *invisible*:
// identical output to tier-0 / tier-1a, plus the same deopt behaviour. The broad
// `expectProgram` matrix already exercises `.record_execute_native` across every
// program test (silent tier-1a fallback where a trace leaves the int/bool subset);
// these focused tests assert the decisive internal signal — that a supported loop
// was *actually lowered to machine code* (`.compiled`), and an unsupported one is
// terminally `.unsupported`.
// ---------------------------------------------------------------------------

/// `runExecForTrace` with native codegen on: a hot trace in the proven-int/bool
/// subset runs as machine code; anything else silently falls back to tier-1a.
fn runNativeForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.out = sink;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

test "native: a hot integer for-loop is lowered to machine code and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runNativeForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    , &sink);
    defer chunk.deinit();

    // Same result tier-0 produces — and the decisive signal that it ran natively.
    try testing.expectEqualStrings("5050\n", sink.buffered());
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
}

test "native: a multi-op for-loop with dropped temporaries lowers and matches tier-0 (task A)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    // The body computes `(i + 7) * (i + 7)` through write-only expression
    // temporaries that the recorder now drops from the exit snapshot. The trace
    // must still lower to machine code, and — the decisive soundness check — its
    // result must be bit-identical to the tier-0 oracle (413950). If dropping a
    // live value were unsound, native and tier-0 would diverge here.
    var chunk = try runNativeForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + (i + 7) * (i + 7) end
        \\print(acc)
    , &sink);
    defer chunk.deinit();

    try testing.expectEqualStrings("413950\n", sink.buffered());
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
}

test "native: a float loop is terminally unsupported and falls back to tier-1a" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const source =
        \\local acc = 0.0
        \\for i = 1, 100 do acc = acc + 1.5 end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // A trace was recorded, but the float add put it outside the int/bool subset:
    // the native compiler bailed and memoized `.unsupported` (tier-1a runs it).
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expect(vm.trace.cache.items[0].native == .unsupported);

    // Output is still byte-identical to a plain tier-0 run.
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "native: a compiled int loop that flips to float mid-run deopts and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // Recorded all-int (the `i == 50` branch isn't taken when it goes hot), so it
    // compiles to native code. At runtime the branch *is* taken: the native trace's
    // `guard_false` on `i == 50` fires, side-exits, and tier-0 turns `acc` into a
    // float — every later re-entry then fails `guard_int` on `acc`. The result must
    // still match tier-0 to the last decimal, proving native deopt is sound.
    const source =
        \\local acc = 0
        \\for i = 1, 100 do
        \\  if i == 50 then acc = acc + 0.5 end
        \\  acc = acc + i
        \\end
        \\print(acc)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // The pre-flip trace did compile to machine code...
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
    // ...and the native run's output equals a plain tier-0 run, deopt and all.
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
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
