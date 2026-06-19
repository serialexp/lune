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
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
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

/// The built-in-native registry descriptor and the module-constant descriptor now
/// live in `function.zig` (the dependency-light home alongside `NativeFn`/
/// `EffectKind`), so a stdlib module can declare its own slices without importing
/// `interp`. Re-exported here because `base_natives`, `defineNative`, and the
/// keyframe restorer (`keyframeser.interp.BaseNative`) reference them by this name.
pub const BaseNative = function.BaseNative;
pub const ModuleConst = function.ModuleConst;

/// The single source of truth for built-in natives. `installBaseLib` installs
/// every entry into a fresh VM's globals, and the keyframe restorer
/// (`keyframeser.zig`) looks a serialized native up here by name to rebind it —
/// so a native added here is automatically both installable and restorable, and
/// the two paths can never diverge. The serialized form of a `Native` is just its
/// name (`keyframeser.toSchemaHeapObject`), which is meaningful only against this
/// registry. The `effect` tag is likewise sourced here (install + restore both
/// read it), so what counts as an effect is defined in exactly one place.
///
/// The interpreter owns only `core_natives` (host effects + the minimal bench
/// stdlib); each standalone stdlib **library** declares its own slice and is
/// concatenated in here, so library code never piles into the interpreter core.
/// To add a library: append `<lib>.natives` below (and `<lib>.constants` to
/// `base_constants`).
/// The value of the bare global `_VERSION`. A fixed, deterministic string (it is
/// observable program output, so it must never derive from a runtime/host source).
pub const lune_version = "lune 0.0.0";

pub const base_natives = core_natives ++ stdmath.natives ++ stdtable.natives ++
    stdbase.natives ++ stdbasic.natives ++ stdstring.natives;

/// The interpreter's own natives. `print` is pure output; `clock` is the first
/// nondeterministic input.
const core_natives = [_]BaseNative{
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
    // `io.write` is a host-output call (no effect), installed into the `io` module
    // table. (`tonumber` and `string.format` moved to `stdlib/basic.zig` and
    // `stdlib/string.zig` respectively, keeping their serialized names.)
    .{ .name = "io.write", .func = &nativeIoWrite, .module = "io", .field = "write" },
};

/// Built-in module constants (non-heap `Value` fields like `math.pi`). Like
/// `base_natives`, each library contributes its own `constants` slice.
pub const base_constants = stdmath.constants;

/// The top-level global names `installBaseLib` seeds, derived from the single
/// `base_natives` registry plus the host-populated `arg` table. The compiler's
/// unknown-global lint treats these as defined so it never warns about
/// `print`/`string`/`io`. A module native contributes its *module* name (the bare
/// global a program references — `string`, not `string.format`); duplicates from
/// sibling module fields are collapsed. Deriving from `base_natives` keeps the two
/// in lockstep — add a native and its top-level name is known here.
pub const builtin_global_names = blk: {
    @setEvalBranchQuota(10_000);
    var tmp: [base_natives.len + 2][]const u8 = undefined;
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
    // `_VERSION` is a bare global string (seeded in `installBaseLib`), not a
    // native; programs reference it, so the lint must know it too.
    tmp[n] = "_VERSION";
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
    /// Varargs cursor: absolute stack index of this frame's first `...` value.
    /// The extra arguments (beyond `proto.num_params`) are left in the *caller's*
    /// window by the `.call` layout and never relocated — the shared `stack` is a
    /// fixed slab, so this region is stable and GC-rooted for the frame's lifetime.
    /// Only meaningful when `varargs_count > 0`.
    varargs_base: usize = 0,
    /// Number of `...` values for this frame (`nargs - num_params`, clamped at 0).
    /// Zero for non-vararg callees and vararg callees called with no extra args.
    varargs_count: usize = 0,
};

/// The outcome of an `exec` run: either the bottom frame returned (carrying the
/// top-level `FrameResult`), or a mid-execution suspend point was hit (all VM
/// state left intact and capturable). `suspended` is only ever returned when
/// `suspend_ctl` is armed (a test / future debugger hook); `run` leaves it null.
pub const ExecOutcome = union(enum) { finished: FrameResult, suspended };

/// Dispatch mode for the two `execImpl` instantiations (T3 hook-elision).
/// `.fast` compiles out the off-by-default per-instruction prologue hooks
/// (line-record, suspend check, recording mirror); `.full` keeps them. Both keep
/// the GC safepoint and `safepoint_seq` increment — those are load-bearing for
/// replay determinism and never elided. The opcode bodies are one source of
/// truth shared by both instantiations, so the modes cannot diverge.
const ExecMode = enum { fast, full };

/// Internal result of one `execImpl` invocation. Extends `ExecOutcome` with
/// `switch_mode`, the request to re-enter under the other `ExecMode` (recording
/// just armed → need `.full`; or every hook cleared → drop to `.fast`). The
/// `exec` wrapper consumes `switch_mode`; it never escapes to a real caller.
const ExecStep = union(enum) { finished: FrameResult, suspended, switch_mode };

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
    /// Dynamic multi-return "top": the absolute end of the live results a multret
    /// producer (`call`/`ret`/native with `c == all_results`) just wrote. Valid
    /// **only** for the single instruction that immediately follows the producer —
    /// its designated consumer (an outer call's argument list, or a `ret`). The
    /// compiler emits producer and consumer adjacently, and `reg_top_pending`
    /// makes that one-instruction gap atomic w.r.t. the GC/suspend safepoint, so
    /// `reg_top` never has to be GC-rooted or serialized: no collection or
    /// snapshot can land between the two.
    reg_top: usize = 0,
    /// Set by a multret producer, cleared by its consumer. Gates the safepoint
    /// (`exec` loop) so a producer→consumer pair is indivisible — see `reg_top`.
    reg_top_pending: bool = false,
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
        for (base_constants) |c| try self.defineConstant(c);
        // `arg` is a real (initially empty) table so the lint, tests, the wasm
        // host, and keyframe restore all see a table; `arg[i]` is nil until the
        // CLI host fills it from process args (`main.zig`, at the host boundary).
        const arg_table = try self.heap.newTable();
        try self.globals.set(self.gpa, try self.heap.internValue("arg"), Value.heap(&arg_table.header));
        // `_VERSION` — a bare global string (Lua seeds its own value here). A
        // normal interned heap string in `globals`, so it serializes/restores
        // through the keyframe path with no special-casing.
        try self.globals.set(self.gpa, try self.heap.internValue("_VERSION"), try self.heap.internValue(lune_version));
    }

    fn defineNative(self: *Vm, bn: BaseNative) Error!void {
        const native = try self.heap.newNative(bn.func, bn.name);
        native.effect = bn.effect; // null for pure host calls (e.g. print)
        native.multi = bn.multi; // null unless the native can return ≥2 results
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

    /// Install a module constant (e.g. `math.pi`) as a field of its module table.
    /// The value is a non-heap `Value` literal from the registry, so there is no
    /// allocation beyond the (interned) key and the on-demand module table.
    fn defineConstant(self: *Vm, c: ModuleConst) Error!void {
        const tbl = try self.getOrCreateModuleTable(c.module);
        const fkey = try self.heap.internValue(c.field);
        try tbl.set(self.gpa, fkey, c.value);
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
        return self.pushFrameVararg(closure, base, ret_dest, ret_count, 0, 0);
    }

    /// `pushFrame` plus an explicit varargs cursor (`.call` computes it for vararg
    /// callees; everyone else uses the zero defaults via `pushFrame`).
    pub fn pushFrameVararg(self: *Vm, closure: *const Closure, base: usize, ret_dest: u16, ret_count: u16, varargs_base: usize, varargs_count: usize) Error!void {
        if (self.depth >= max_call_depth) return Error.StackOverflow;
        const nreg = closure.proto.num_registers;
        if (base + nreg > self.stack.len) return Error.StackOverflow;
        self.frames[self.depth] = .{
            .closure = closure,
            .base = base,
            .pc = 0,
            .ret_dest = ret_dest,
            .ret_count = ret_count,
            .varargs_base = varargs_base,
            .varargs_count = varargs_count,
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
    ///
    /// Thin wrapper over the comptime-specialised `execImpl` (T3 hook-elision).
    /// Runs `.fast` (off-by-default prologue hooks compiled out) whenever no hook
    /// is live, else `.full`. A `switch_mode` request — recording armed mid-`.fast`
    /// (the next instruction needs the recording hook), or every hook cleared
    /// mid-`.full` — re-enters under the other mode at the parked cursor; it never
    /// reaches a caller. Both modes share one opcode body, so they cannot diverge.
    pub fn exec(self: *Vm) Error!ExecOutcome {
        while (true) {
            const step = if (self.runFastPath())
                try self.execImpl(.fast)
            else
                try self.execImpl(.full);
            switch (step) {
                .finished => |fr| return .{ .finished = fr },
                .suspended => return .suspended,
                .switch_mode => continue,
            }
        }
    }

    /// May the dispatch loop run with the off-by-default prologue hooks compiled
    /// out? Only when none is live: no pending suspend cut, no replay line
    /// recording, and not mid-trace-recording. The GC safepoint is *not* gated on
    /// here — `.fast` keeps it, so `gc_stress` stays correct without forcing
    /// `.full`. These three flags are stable across an `exec` invocation except
    /// `isRecording()`, which can only arm at a back-edge and is caught there.
    inline fn runFastPath(self: *const Vm) bool {
        return !(self.suspend_ctl != null or self.record_safepoint_lines or self.trace.isRecording());
    }

    fn execImpl(self: *Vm, comptime mode: ExecMode) Error!ExecStep {
        // Hot top-frame state, reloaded from `frames[depth-1]` after every push/pop.
        var frame: *CallFrame = &self.frames[self.depth - 1];
        var closure = frame.closure;
        var proto = closure.proto;
        var code = proto.code;
        var base = frame.base;
        var regs = self.stack[base .. base + proto.num_registers];
        var pc = frame.pc;

        outer: while (true) {
            // GC safepoint. Here every live value is reachable from a root (all
            // registers are settled, no half-built object is exposed), so a
            // stop-the-world collection is safe. Non-moving, so surviving
            // pointers in `regs` stay valid.
            //
            // Suppressed while a multret result set is pending (`reg_top_pending`):
            // a producer (e.g. `table.unpack` with `c == all_results`) may have
            // written results *above* this frame's `num_registers`, which the root
            // walk (bounded by `stack_top`) would not scan. Producer and consumer
            // are adjacent instructions and neither allocates in the gap, so
            // skipping exactly this one safepoint is sound — and it keeps `reg_top`
            // out of both the GC root set and any keyframe snapshot.
            if (!self.reg_top_pending and self.heap.shouldCollect()) self.collect();

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
            // `.fast` compiles these two prologue hooks out entirely (it is only
            // entered when both flags are off — `runFastPath`). `safepoint_seq`
            // above is *not* gated: it must count every instruction in both modes
            // so replay cuts land identically (keyframeser reads it as the total).
            if (mode == .full and self.record_safepoint_lines) {
                const sp_line: u32 = if (pc < proto.spans.len)
                    compiler.lineFromOffset(self.source, proto.spans[pc].start)
                else
                    0;
                try self.safepoint_lines.append(self.gpa, sp_line);
            }
            if (mode == .full) {
                if (self.suspend_ctl) |sc| {
                    // Never suspend mid-multret (see the GC note above): `reg_top` is
                    // transient and unserialized, so a snapshot here could not resume.
                    if (!self.reg_top_pending and self.safepoint_seq >= sc.after_safepoints and self.depth >= sc.min_depth) {
                        frame.pc = pc;
                        return .suspended;
                    }
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
            // Recording mirror — `.full` only. `.fast` is never entered while
            // recording is live (`runFastPath`), and the back-edge handoff below
            // flips to `.full` the instant `onBackEdge` arms a recording, so the
            // very next instruction is mirrored.
            if (mode == .full and self.trace.isRecording()) self.trace.recordInstr(instr, regs, proto, @intCast(pc));
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
                // generic-for test: the preceding `call` filled R[a+3..] with the
                // iterator's results. Continue iff the first var is non-nil (Lua
                // stops only on nil; `false` continues), publishing it as the next
                // control R[a+2] and taking the back-edge. Else fall through (exit).
                .tfor_loop => {
                    if (!regs[a + 3].isNil()) {
                        regs[a + 2] = regs[a + 3];
                        pc = applyJump(pc, instr.aux);
                    }
                },

                // ---- tables ----
                .new_table => {
                    const t = try self.heap.newTable();
                    regs[a] = Value.heap(&t.header);
                },
                .get_index => {
                    // Array fast-path: a table indexed by an in-range integer key
                    // reads straight from the typed array part, skipping the
                    // `indexGet → Table.get → normalizeKey → getInt` call layering
                    // (the ~22% `Table.get` in the nsieve profile). This is a pure
                    // shortcut to the exact value `getInt` would return for an
                    // in-bounds int key (table.zig:105); every other shape — float
                    // key, out-of-range, hash-resident, non-table — falls through
                    // to the unchanged helper, so semantics and determinism are
                    // identical (no allocation on either branch).
                    const container = regs[instr.b];
                    const key = regs[instr.c];
                    regs[a] = blk: {
                        if (container.isHeap() and container.heapType() == .table and key.isInt()) {
                            const tbl = table.Table.fromHeader(container.asHeap());
                            const i = key.asInt();
                            if (i >= 1 and i <= @as(i64, @intCast(tbl.array.len)))
                                break :blk tbl.array.get(@intCast(i));
                        }
                        break :blk try indexGet(container, key);
                    };
                },
                .set_index => {
                    // Array fast-path mirror of `.get_index`: an in-bounds integer
                    // store whose value already fits the current lane is the exact
                    // work `Table.set`'s in-bounds branch does (table.zig:121 →
                    // `setInPlace`, which with a fitting value is just `encode` —
                    // no widen, no `migrateFromHash`, no allocation). `setInLane`
                    // (array.zig:209) is that allocation-free `encode`. A
                    // lane-missing value, append (`i == len+1`), out-of-range,
                    // float/nil/NaN key, or non-table all fall through to the
                    // unchanged `indexSet`, which owns widen/append/hash/delete.
                    const container = regs[a];
                    const key = regs[instr.b];
                    const val = regs[instr.c];
                    fast: {
                        if (container.isHeap() and container.heapType() == .table and key.isInt()) {
                            const tbl = table.Table.fromHeader(container.asHeap());
                            const i = key.asInt();
                            if (i >= 1 and i <= @as(i64, @intCast(tbl.array.len)) and tbl.array.fits(val)) {
                                tbl.array.setInLane(@intCast(i), val);
                                self.heap.writeBarrier(&tbl.header, val); // no-op until Phase 4
                                break :fast;
                            }
                        }
                        try self.indexSet(container, key, val);
                    }
                },

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
                    // Resolve the argument count. `all_results` (the consumer half
                    // of dynamic multret, e.g. the outer `print` in
                    // `print(unpack(t))`) takes every value the immediately-preceding
                    // producer left, from the first argument slot up to `reg_top`.
                    const nargs: usize = if (instr.b == bytecode.all_results) blk: {
                        self.reg_top_pending = false;
                        break :blk self.reg_top - (base + a + 1);
                    } else instr.b;
                    switch (callee.heapType()) {
                        .function => {
                            const cl = Closure.fromHeader(callee.asHeap());
                            const cp = cl.proto;
                            const callee_base = base + proto.num_registers;
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
                            // Varargs cursor: a vararg callee handed more args than
                            // it has fixed params keeps the surplus where they already
                            // sit — in the caller's window, below `callee_base`. They
                            // stay valid (the stack slab never moves) and GC-rooted
                            // (`forEachRootHeader` scans the whole live prefix) for the
                            // callee's lifetime. Recorded per-callee so a non-vararg or
                            // no-surplus callee gets a zero cursor (never inherits one).
                            const va_count: usize = if (cp.is_vararg and nargs > cp.num_params) nargs - cp.num_params else 0;
                            const va_base: usize = if (va_count > 0) base + a + 1 + cp.num_params else 0;
                            // Freeze the caller's resume cursor (already one past this
                            // call), push the callee, and reload locals onto it.
                            frame.pc = pc;
                            try self.pushFrameVararg(cl, callee_base, instr.a, instr.c, va_base, va_count);
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
                            const nwanted: usize = instr.c;
                            const args = self.stack[base + a + 1 .. base + a + 1 + nargs];
                            // `all` = the caller wants *every* result (dynamic count,
                            // the producer half of `print(unpack(t))` / `return f()`):
                            // results land starting at `regs[a]` and `reg_top` records
                            // their end for the adjacent consumer. Otherwise a concrete
                            // `nwanted` is written and the tail nil-padded.
                            //
                            // Three native shapes, in priority order:
                            //  1. effect native (clock/getenv/…): one result through the
                            //     record/replay boundary — effects are inherently single.
                            //  2. multi-result native: write straight into the destination
                            //     slots. `out` aliases `args` (see NativeMultiFn), which is
                            //     why the native reads its args first. For `all`, `out`
                            //     spans to the end of the register stack (bounded → no OOB;
                            //     the native caps at `out.len`).
                            //  3. otherwise (pure single, or a multi native with 0/1 wanted):
                            //     call `func` (the primary-value projection) and write one.
                            // A native call is a trace barrier (recording aborts at it), so
                            // none of this touches the JIT.
                            const all = nwanted == bytecode.all_results;
                            if (nat.effect) |kind| {
                                const result = try performEffect(self, kind, nat, args);
                                if (all) self.stampSingleResult(base, a, result) else writeSingleResult(regs, a, nwanted, result);
                            } else if (nat.multi != null and (all or nwanted >= 2)) {
                                const out = if (all) self.stack[base + a ..] else regs[a .. a + nwanted];
                                const produced = nat.multi.?(@ptrCast(self), args, out) catch |e| return narrowError(e);
                                if (all) {
                                    std.debug.assert(!self.reg_top_pending);
                                    self.reg_top = base + a + produced;
                                    self.reg_top_pending = true;
                                } else {
                                    var k: usize = produced;
                                    while (k < nwanted) : (k += 1) regs[a + k] = Value.nil();
                                }
                            } else {
                                const result = nat.func(@ptrCast(self), args) catch |e| return narrowError(e);
                                if (all) self.stampSingleResult(base, a, result) else writeSingleResult(regs, a, nwanted, result);
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
                    // Resolve how many values this frame returns. `ret a all_results`
                    // (the producer half of `return f()` / `return unpack(t)`) returns
                    // everything the immediately-preceding multret call left, from
                    // `a` up to `reg_top`.
                    const ret_count: u16 = if (instr.op == .ret and instr.b == bytecode.all_results) blk: {
                        self.reg_top_pending = false;
                        break :blk @intCast(self.reg_top - (base + @as(usize, a)));
                    } else if (instr.op == .ret) instr.b else 0;
                    const result: FrameResult = .{ .reg = @intCast(a), .count = ret_count };
                    if (self.depth == 1) {
                        self.depth = 0;
                        return .{ .finished = result };
                    }
                    // Copy results into the parent *while* `stack_top` still covers
                    // this (callee) window — no allocation or safepoint between here
                    // and the `stack_top` shrink below, so a result can't be
                    // collected before it lands in the parent's (scanned) registers.
                    // `want` uses the stored return-wiring, never a re-decode of the
                    // caller's call instruction. When the caller wanted *all* results
                    // (`call … c=all_results`, e.g. `print(g())`), take everything the
                    // callee produced and stamp `reg_top` so the parent's adjacent
                    // consumer instruction can expand them.
                    const parent = &self.frames[self.depth - 2];
                    const wants_all = frame.ret_count == bytecode.all_results;
                    const want: usize = if (wants_all) result.count else frame.ret_count;
                    const dst = parent.base + frame.ret_dest;
                    const src = base + result.reg;
                    var k: usize = 0;
                    while (k < want) : (k += 1) {
                        self.stack[dst + k] = if (k < result.count)
                            self.stack[src + k]
                        else
                            Value.nil();
                    }
                    if (wants_all) {
                        std.debug.assert(!self.reg_top_pending);
                        self.reg_top = dst + want;
                        self.reg_top_pending = true;
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

                // ---- varargs ---- read the current frame's `...` cursor. The
                // surplus-arg region lives below `base` (in the caller's window),
                // stable and GC-rooted; these never relocate it.
                .vararg_first => {
                    regs[a] = if (frame.varargs_count >= 1) self.stack[frame.varargs_base] else Value.nil();
                },
                .vararg_len => {
                    regs[a] = Value.int(@intCast(frame.varargs_count));
                },
                .vararg_get => {
                    // 1-based, bounds-checked; out of range or non-int index → nil.
                    const idx_v = regs[instr.b];
                    var out = Value.nil();
                    if (idx_v.isInt()) {
                        const idx = idx_v.asInt();
                        if (idx >= 1 and idx <= @as(i64, @intCast(frame.varargs_count))) {
                            out = self.stack[frame.varargs_base + @as(usize, @intCast(idx - 1))];
                        }
                    }
                    regs[a] = out;
                },
                .vararg_spread => {
                    // The dynamic-multret producer half: copy every vararg into
                    // R[a..a+count) and stamp `reg_top` for the adjacent consumer
                    // (a `call`/`ret` with `all_results`). Bound against the whole
                    // stack, not the static window — like the native multret, the
                    // values may land above `stack_top`, covered by the
                    // `reg_top_pending` safepoint suppression until consumed.
                    std.debug.assert(!self.reg_top_pending);
                    const count = frame.varargs_count;
                    const dest = base + a;
                    if (dest + count > self.stack.len) return Error.StackOverflow;
                    var k: usize = 0;
                    while (k < count) : (k += 1) self.stack[dest + k] = self.stack[frame.varargs_base + k];
                    self.reg_top = dest + count;
                    self.reg_top_pending = true;
                },
            }

            // Phase 5 hotness seam: a backward (or self) jump just took us to
            // `pc <= cur_pc` — a loop back-edge whose target `pc` is the loop
            // header (anchor). Count it, and arm/close a recording. Gated on
            // `enabled`, so it is inert until `--trace`.
            if (self.trace.config.enabled and pc <= cur_pc) {
                const anchor_pc: u32 = @intCast(pc);
                // Cheap direct-mapped hot-count pre-filter. A gated/dead loop (the
                // canonical case: nsieve's array-growing init loop, which can't be
                // traced) skips the per-back-edge hashmap bookkeeping in
                // `onBackEdge` + the trace-entry lookup entirely — it just
                // decrements a `u16` slot and falls back to tier-0. The global
                // `tick` still advances (inside `skipBackEdge`), so a transiently
                // gated loop's backoff cooldown keeps elapsing across the skip.
                // Hot traced loops and warming loops keep a 0 slot and always take
                // the slow path below, so their behaviour is unchanged.
                if (!self.trace.skipBackEdge(proto, anchor_pc)) {
                    self.trace.onBackEdge(proto, anchor_pc, regs);

                    // Phase 6 tier-1a entry: if a trace is cached for this loop header
                    // and we're not mid-recording, execute it. `irinterp.execute`
                    // returns with `regs` coherent for the header — it side-exits
                    // *before* committing a partial iteration — so we `continue`
                    // **without** advancing `pc`: tier-0 then re-runs the loop header
                    // to redo the (pure, side-effect-free) deopt iteration. A trace is
                    // only ever entered at exactly its anchor pc, so re-entry is sound.
                    // Per-entry trip-count gating: for a numeric-`for`, decline to
                    // enter the trace when the remaining iteration count is below
                    // `min_trip_entry` — tier-0 runs the short loop and we skip the
                    // `onSideExit` penalty, so the inner loop's trivial large-stride
                    // runs never gate its profitable long runs. `null` for any
                    // non-`for_loop` back-edge (while/repeat) ⇒ always eligible.
                    const for_trips: ?u64 = if (instr.op == .for_loop)
                        forRemainingTrips(regs[a], regs[a + 1], regs[a + 2])
                    else
                        null;
                    const eligible = self.trace.config.execute and !self.trace.isRecording() and
                        !self.trace.isGated(.{ .proto = proto, .pc = anchor_pc });
                    const trip_ok = for_trips == null or for_trips.? >= self.trace.config.min_trip_entry;
                    if (eligible and trip_ok) {
                        // A gated anchor has proven it thrashes: every entry
                        // committed fewer than `min_useful` iterations until the
                        // re-entry penalty maxed out. The canonical case is a
                        // strictly-alternating branch (stable types, so fingerprinting
                        // can't tell the arms apart) where no single straight-line
                        // trace can amortize entry/exit over more than one iteration —
                        // running the trace was *slower* than tier-0. Gating entry
                        // (not just re-arming, as before) lets tier-0
                        // own the loop and removes the slowdown. The gate retries the
                        // anchor on an exponential backoff and clears the moment an
                        // entry finally proves useful, so a loop that only thrashes
                        // transiently still recovers. Works on the native
                        // path too: the penalty keys only on `completed`, which native
                        // execution reports.
                        //
                        // Same-anchor chaining: if multiple traces exist for this
                        // loop header (e.g. different type specializations), try
                        // each in turn until one commits at least one iteration.
                        // All traces share the same loop-header re-entry deopt
                        // discipline, so `regs` is valid for every attempt.
                        // Same-anchor trial walk. We iterate by an explicit
                        // *visited* set (`nextTraceExcluding`) rather than the
                        // single-`skip` `findNextTrace`, so each candidate is tried
                        // exactly once and the walk always terminates — two
                        // equal-priority traces that both zero-exit would otherwise
                        // cycle `A→B→A→…` forever (e.g. two stale narrow-lane traces
                        // once the live array has widened past both).
                        var visited: [8]*trace.Trace = undefined;
                        var nvisited: usize = 0;
                        var any_fingerprint_matched = false;
                        // Widen-eviction: traces whose `guard_lane` pins a lane the
                        // live array has monotonically widened past can never match
                        // again. Collect them during the trial walk and retire them
                        // when we leave it — removing a trace frees the `*Trace`, so
                        // we must not do it while the walk could still revisit the
                        // cache. `dead` is a subset of `visited`, so it never
                        // overflows past the visited cap.
                        var dead: [8]*trace.Trace = undefined;
                        var ndead: usize = 0;
                        var t: ?*trace.Trace = self.trace.nextTraceExcluding(proto, @intCast(pc), visited[0..0]);
                        while (t) |ct| : (t = if (nvisited < visited.len)
                            self.trace.nextTraceExcluding(proto, @intCast(pc), visited[0..nvisited])
                        else
                            null) {
                            // Mark visited *before* the body so the loop continuation
                            // excludes `ct` (and everything tried so far) — this is
                            // what makes the walk finite.
                            if (nvisited < visited.len) {
                                visited[nvisited] = ct;
                                nvisited += 1;
                            }
                            // --- type fingerprint (step 5) ---
                            // Skip this trace if the current register types don't
                            // match its entry type guards.  Avoids trial entries
                            // that would immediately fail on a guard_int/guard_float
                            // mismatch.  Branch-direction guards (guard_true/false)
                            // aren't fingerprinted — they depend on computed values.
                            if (!ct.matchesFingerprint(regs)) continue;
                            any_fingerprint_matched = true;
                            if (self.trace.valuesScratch(ct.instrs.len)) |buf| {
                                self.trace.entries +%= 1;
                                const result = if (self.trace.config.record_exec_log) blk: {
                                    const tid = self.trace.traceIndex(ct) orelse break :blk irinterp.execute(ct, regs, buf);
                                    const rec = self.trace.execRecorderFor(tid) orelse break :blk irinterp.execute(ct, regs, buf);
                                    break :blk irinterp.executeTraced(rec, ct, regs, buf);
                                } else if (self.trace.config.native_codegen) blk: {
                                    if (self.trace.nativeFor(ct)) |nt| break :blk irinterp.ExecResult{ .completed = nt.run(regs), .exit_instr = std.math.maxInt(u32) };
                                    break :blk irinterp.execute(ct, regs, buf);
                                } else irinterp.execute(ct, regs, buf);
                                // Always record the exit instruction — useful for
                                // per-guard PC debugging even on productive exits.
                                self.trace.last_exit_instr = result.exit_instr;

                                // --- guard-failure counting (step 4) ---
                                // Count guard failures on zero-iteration exits
                                // (type mismatches that passed the fingerprint
                                // but failed a non-type guard, e.g. branch direction).
                                // Resolve the PC through `guardExitPc`: array guards
                                // store a lane ordinal in `aux`, not a PC, and must
                                // not be counted as guard-PC failures.
                                if (result.completed == 0) {
                                    if (result.exit_instr != std.math.maxInt(u32)) {
                                        if (trace.guardExitPc(ct.instrs[result.exit_instr])) |exit_pc| {
                                            if (exit_pc > 0) {
                                                self.trace.countGuardFailure(ct.anchor, exit_pc);
                                            }
                                        }
                                    }
                                }

                                if (result.completed > 0) {
                                    // This trace did useful work — keep its result.
                                    self.trace.onSideExit(ct, result.completed);
                                    // Retire any dead-marked traces before leaving the
                                    // walk so a stale narrow-lane trace doesn't linger
                                    // in a slot just because a later trace succeeded.
                                    // Safe: `continue :outer` abandons the walk, so the
                                    // freed `*Trace`s are never revisited.
                                    for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                    // T3 drop-to-fast on the productive-trace path.
                                    // The handoff at the bottom of the back-edge
                                    // block is bypassed by this `continue :outer`,
                                    // so without this a loop that just finished
                                    // recording and now enters its native trace
                                    // every iteration would stay in `.full` forever
                                    // (correct, but it keeps the elided prologue
                                    // hooks on the tier-0 deopt iterations). Once
                                    // recording is done and no other hook is live,
                                    // park `pc` and re-enter `.fast`. Taken once at
                                    // the transition; in `.fast` this is compiled
                                    // out, so steady-state native entry is unbranched.
                                    if (mode == .full and self.runFastPath()) {
                                        frame.pc = pc;
                                        return .switch_mode;
                                    }
                                    continue :outer;
                                }
                                // Zero iterations: apply the penalty, then try
                                // the next trace at this anchor.
                                self.trace.onSideExit(ct, 0);

                                // Widen-eviction: if this trace's array lane guard
                                // can never pass again (the live array widened past
                                // it, monotonically), mark it for retirement so its
                                // anchor slot frees for the stabilised wider-lane
                                // trace. Deferred to after the walk (see `dead`).
                                if (ndead < dead.len and self.trace.laneWidenedPast(ct, regs)) {
                                    dead[ndead] = ct;
                                    ndead += 1;
                                }

                                // --- exit-PC chaining (step 3) ---
                                // If the failing guard was recorded at a different
                                // PC, look for a side trace there.  This fires
                                // only after step 4 (side traces) populates the
                                // cache at non-anchor PCs.
                                if (self.trace.tryChainExit(ct, result.exit_instr, proto, regs)) |_| {
                                    for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                    continue :outer;
                                }
                            } else |_| {} // OOM: skip this trace, try next
                        }
                        // Retire traces the walk found permanently dead (lane widened
                        // past their guard). Safe now that the same-anchor walk is
                        // complete — removing frees the `*Trace` and would otherwise
                        // dangle the iterator cursor.
                        for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                        // All traces at this anchor failed, OOM'd, or didn't match
                        // the fingerprint.  If at least one trace exists but none
                        // matched, count it for side-trace recording.
                        if (!any_fingerprint_matched and self.trace.hasTrace(.{ .proto = proto, .pc = anchor_pc })) {
                            self.trace.countFingerprintMiss(.{ .proto = proto, .pc = anchor_pc });
                        }
                        // Fall through to tier-0.
                    } else if (eligible and !trip_ok) {
                        // Declined a numeric-`for` purely on trip count: cheap-skip
                        // the rest of this short invocation so its remaining
                        // back-edges don't each re-pay full `onBackEdge`
                        // bookkeeping. `trip - 1` exactly covers the remainder (the
                        // final `for_loop` exits without a back-edge), so the window
                        // never bleeds into the next invocation's (possibly
                        // profitable) entry at this same anchor.
                        if (for_trips.? >= 2) {
                            self.trace.armShortLoopSkip(proto, anchor_pc, for_trips.? - 1);
                        }
                    }
                    // Reached only when no trace ran this back-edge — a successful
                    // trace entry above does `continue :outer` and never gets here.
                    // If the anchor is gated, install a hot-count skip window so its
                    // next back-edges bypass all of the above.
                    self.trace.afterBackEdge(proto, anchor_pc);
                }
                // T3 fast/slow handoff — back-edges are the *only* point a
                // recording can arm (`onBackEdge`), so the check lives here, not
                // per-instruction. `.fast`: if a recording just armed, the loop
                // header (the next instruction) must be mirrored, which `.fast`
                // elides — re-enter `.full`. `.full`: once recording has finished
                // or aborted and no other hook is live, drop back to `.fast`. The
                // back-edge instruction itself is never part of the recorded body
                // (its prologue mirror ran before `onBackEdge` armed), so handing
                // off here is byte-identical to an always-`.full` recording run.
                // Park `pc` before handing off, exactly as the `.suspended` path
                // does: re-entry reloads `pc = frame.pc`, so without this the other
                // mode would resume at `cur_pc` and re-run this back-edge.
                if (mode == .fast) {
                    if (self.trace.isRecording()) {
                        frame.pc = pc;
                        return .switch_mode;
                    }
                } else {
                    if (self.runFastPath()) {
                        frame.pc = pc;
                        return .switch_mode;
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

    /// Place a single native result at `regs[a]` (absolute `stack[base + a]`) and
    /// record `reg_top` for the adjacent consumer — the `all_results` path for an
    /// effect or pure-single native (e.g. `print(clock())`). One result, so the
    /// live top is just past it.
    fn stampSingleResult(self: *Vm, base: usize, a: usize, result: Value) void {
        std.debug.assert(!self.reg_top_pending); // exactly one producer pending at a time
        self.stack[base + a] = result;
        self.reg_top = base + a + 1;
        self.reg_top_pending = true;
    }
};

/// Place a single native result into the caller's window: the value into the
/// first wanted slot, `nil` into the rest. Shared by the effect and pure-single
/// native paths. `nwanted == 0` discards the result (statement-context call).
fn writeSingleResult(regs: []Value, a: usize, nwanted: usize, result: Value) void {
    var k: usize = 0;
    while (k < nwanted) : (k += 1) regs[a + k] = if (k == 0) result else Value.nil();
}

/// Remaining iterations a numeric-`for` will still execute from its current
/// state, *including* the iteration whose back-edge we are on:
/// `(limit - idx)/step + 1`, clamped to `[0, u64max]`. `idx/limit/step` are
/// `R[a]/R[a+1]/R[a+2]` of the just-executed `for_loop`.
///
/// Used only as a heuristic gate on trace *entry* (see the dispatch back-edge
/// handler): a numeric-for whose remaining trip count is tiny is cheaper to run
/// on tier-0 than to enter a native trace for, and — more importantly — declining
/// to enter means no `onSideExit` penalty, so a loop that is profitable for some
/// strides (many iterations) and trivial for others (a handful) never gates its
/// shared anchor on the trivial runs. The exact value never affects correctness
/// (tier-0 and the trace are equivalent), only whether entry is worth it, so the
/// int path (exact, the common case) and the float fallback need only agree
/// monotonically around the threshold. Computed in `i128`/`f64` to avoid overflow
/// on extreme bounds.
fn forRemainingTrips(idx: Value, limit: Value, step: Value) u64 {
    const cap = std.math.maxInt(u64);
    if (idx.isInt() and limit.isInt() and step.isInt()) {
        const s: i128 = step.asInt();
        if (s == 0) return cap; // degenerate (Lua would error); don't gate
        const diff: i128 = @as(i128, limit.asInt()) - @as(i128, idx.asInt());
        // For descending loops `diff` and `s` are both negative, so `@divFloor`
        // still yields the correct non-negative quotient.
        const cnt: i128 = @divFloor(diff, s) + 1;
        if (cnt <= 0) return 0;
        if (cnt >= cap) return cap;
        return @intCast(cnt);
    }
    const s = step.toFloat();
    if (s == 0) return cap;
    const rem = (limit.toFloat() - idx.toFloat()) / s; // negative if past the end
    if (!(rem >= 0)) return 0; // also catches NaN
    if (rem >= @as(f64, @floatFromInt(cap - 1))) return cap;
    return @as(u64, @intFromFloat(@floor(rem))) + 1;
}

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
// Minimal host stdlib (benchmark harness): io.write, plus the shared coercion
// helpers (`strBytes`, `coerceConcat`) the stdlib modules reuse. All pure host
// calls (no effects). See `base_natives`.
// ---------------------------------------------------------------------------

/// The bytes of `v` if it is a heap string, else null. Public so the stdlib
/// modules (`stdlib/basic.zig`, `stdlib/string.zig`) can reuse it qualified,
/// rather than each re-deriving the string-arg projection.
pub fn strBytes(v: Value) ?[]const u8 {
    if (v.isHeap() and v.heapType() == .string) return string.String.fromHeader(v.asHeap()).bytes();
    return null;
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

/// Coerce a concat operand to bytes: a string's own bytes, or a number formatted
/// into `buf`. Returns a slice valid until `buf` is reused.
pub fn coerceConcat(v: Value, buf: []u8) Error![]const u8 {
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
        Instr.opAx(.load_int, 1, 1),
        Instr.opAx(.load_int, 2, 10),
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 2),
        Instr.opAx(.load_int, 2, 20),
        Instr.opABC(.set_index, 0, 1, 2),
        Instr.opAx(.load_int, 1, 3),
        Instr.opAx(.load_int, 2, 30),
        Instr.opABC(.set_index, 0, 1, 2),
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

// ---------------------------------------------------------------------------
// Varargs V1 — the frame cursor + the four opcodes, exercised on hand-built
// protos (the compiler lowering lands in V2). A vararg callee with one fixed
// param, called with extra args, leaves the surplus in the caller's window;
// the cursor (`varargs_base`/`varargs_count`) points at it with no copy.
// ---------------------------------------------------------------------------

/// Build a `main` that creates a closure over `child`, loads `args` into the
/// call window, and calls it wanting `want` results, returning the first.
fn runVararg(child: *Proto, args: []const i64, want: u16) Error!Value {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    // main: R0 = closure(child); R1.. = args; call R0(args) want `want`; ret R0
    var code: std.ArrayList(Instr) = .empty;
    defer code.deinit(testing.allocator);
    try code.append(testing.allocator, Instr.opAB(.closure, 0, 0));
    for (args, 0..) |v, i| try code.append(testing.allocator, Instr.opAx(.load_int, @intCast(1 + i), @intCast(v)));
    try code.append(testing.allocator, Instr.opABC(.call, 0, @intCast(args.len), want));
    // Sum up to `want` results so a spread's values are observable (want<=3 here).
    var r: u16 = 1;
    while (r < want) : (r += 1) try code.append(testing.allocator, Instr.opABC(.add, 0, 0, r));
    try code.append(testing.allocator, Instr.opAB(.ret, 0, 1));
    const protos = [_]*const Proto{child};
    const main = Proto{ .code = code.items, .num_registers = @intCast(1 + args.len + 2), .protos = &protos, .name = "main" };
    return vm.run(&main);
}

test "vararg_len counts the surplus args (and is 0 with none)" {
    const child_code = [_]Instr{ Instr.opA(.vararg_len, 0), Instr.opAB(.ret, 0, 1) };
    var child = Proto{ .code = &child_code, .num_registers = 1, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expectEqual(@as(i64, 3), (try runVararg(&child, &.{ 10, 20, 30, 40 }, 1)).asInt());
    try testing.expectEqual(@as(i64, 0), (try runVararg(&child, &.{10}, 1)).asInt());
}

test "vararg_first yields the first surplus arg, or nil when there are none" {
    const child_code = [_]Instr{ Instr.opA(.vararg_first, 0), Instr.opAB(.ret, 0, 1) };
    var child = Proto{ .code = &child_code, .num_registers = 1, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expectEqual(@as(i64, 20), (try runVararg(&child, &.{ 10, 20, 30 }, 1)).asInt());
    try testing.expect((try runVararg(&child, &.{10}, 1)).isNil());
}

test "vararg_get is 1-based and bounds-checked (nil out of range)" {
    // child: idx in R1; R0 = vararg[R1]; return R0.
    const in_range = [_]Instr{ Instr.opAx(.load_int, 1, 2), Instr.opAB(.vararg_get, 0, 1), Instr.opAB(.ret, 0, 1) };
    var c1 = Proto{ .code = &in_range, .num_registers = 2, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expectEqual(@as(i64, 30), (try runVararg(&c1, &.{ 10, 20, 30, 40 }, 1)).asInt()); // varargs 20,30,40 → [2]=30
    const out_of_range = [_]Instr{ Instr.opAx(.load_int, 1, 5), Instr.opAB(.vararg_get, 0, 1), Instr.opAB(.ret, 0, 1) };
    var c2 = Proto{ .code = &out_of_range, .num_registers = 2, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expect((try runVararg(&c2, &.{ 10, 20, 30, 40 }, 1)).isNil());
    const zero_index = [_]Instr{ Instr.opAx(.load_int, 1, 0), Instr.opAB(.vararg_get, 0, 1), Instr.opAB(.ret, 0, 1) };
    var c3 = Proto{ .code = &zero_index, .num_registers = 2, .num_params = 1, .is_vararg = true, .name = "f" };
    try testing.expect((try runVararg(&c3, &.{ 10, 20, 30, 40 }, 1)).isNil());
}

test "vararg_spread feeds all surplus args to the caller via all_results" {
    // child: spread all varargs from R0, return them all (producer half).
    const child_code = [_]Instr{ Instr.opA(.vararg_spread, 0), Instr.opAB(.ret, 0, bytecode.all_results) };
    var child = Proto{ .code = &child_code, .num_registers = 1, .num_params = 1, .is_vararg = true, .name = "f" };
    // main wants 3 results and sums them: 20 + 30 + 40 = 90.
    try testing.expectEqual(@as(i64, 90), (try runVararg(&child, &.{ 10, 20, 30, 40 }, 3)).asInt());
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
        // Dynamic multret (`all_results`) inside a hot loop. The `reg_top`
        // producer→consumer pair brackets a safepoint, so this run diverges in
        // trace/snapshot bytes if `reg_top` ever leaked into capturable state
        // (it must not — the safepoint is suppressed while a multret is pending).
        \\local function pair(i) return i, i * i end
        \\local s = 0
        \\for i = 1, 100 do
        \\  local a, b = pair(i)
        \\  s = s + a + b
        \\end
        \\print(s, pair(7))
        ,
        // Generic-for over `pairs` — the deterministic-iteration core guarantee.
        // Two tables receive the SAME keys in OPPOSITE insertion order; both are
        // traversed via `pairs` and accumulated into strings. Canonical key order
        // (tag → heap id → bits) erases the insertion order, so the printed output
        // is identical between p and q AND stable across the two independent runs.
        // The string keys also land in the heap, so the snapshot bytes only agree
        // if iteration is address-independent.
        \\local p = {}
        \\p.a = 1
        \\p.b = 2
        \\p.c = 3
        \\local q = {}
        \\q.c = 3
        \\q.b = 2
        \\q.a = 1
        \\local sp = ""
        \\for k, v in pairs(p) do sp = sp .. k .. v end
        \\local sq = ""
        \\for k, v in pairs(q) do sq = sq .. k .. v end
        \\print(sp)
        \\print(sq)
        ,
        // Varargs (`...`): destructure surplus, tail-spread forwarding, and
        // `return ...`. A vararg function aborts trace formation (nyi_opcode), so
        // this exercises the interpreter/snapshot path; the spread sets `reg_top`
        // exactly like a multret call, so divergence here would catch any address
        // or transient-state leak into the serialized bytes.
        \\local function head(...)
        \\  local a, b = ...
        \\  return a, b
        \\end
        \\local function tail(x, ...)
        \\  print(x, ...)
        \\end
        \\local s = 0
        \\for i = 1, 20 do
        \\  local a, b = head(i, i * i, i * i * i)
        \\  s = s + a + b
        \\end
        \\tail(s, head(s, s))
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

test "e2e: multi-return — native (math.modf) and closure, with adjustment rules" {
    try expectProgram(
        \\local i, f = math.modf(3.5)
        \\print(i, f)                  -- 3  0.5
        \\local x = math.modf(3.5)
        \\print(x)                     -- 3   (nwanted=1 truncates the second result)
        \\local a, b, c = math.modf(3.5)
        \\print(a, b, c)               -- 3  0.5  nil   (extra target nil-padded)
        \\local p, q = math.modf(3.5), 9
        \\print(p, q)                  -- 3  9   (call not in last position ⇒ no expand)
        \\local g, h = 0, 0
        \\g, h = math.modf(-3.25)
        \\print(g, h)                  -- -3  -0.25 (multi-target assignment)
        \\local m, n = (function() return 11, 22 end)()
        \\print(m, n)                  -- 11  22  (closure multret via the same ABI)
        \\local r, s, t = (function() return 1, 2 end)()
        \\print(r, s, t)               -- 1  2  nil
    ,
        "3\t0.5\n3\n3\t0.5\tnil\n3\t9\n-3\t-0.25\n11\t22\n1\t2\tnil\n",
    );
}

test "e2e: dynamic multret — call-arg and return position expand (all_results)" {
    // Exercises the `all_results` sentinel through `expectProgram`, which runs all
    // five modes *and* stress GC (collect at every safepoint). The safepoint
    // between a multret producer and its consumer is gated by `reg_top_pending`,
    // so stress mode here is the real test that transient results above
    // `num_registers` are never collected and `reg_top` never leaks into a
    // snapshot.
    try expectProgram(
        \\local function f() return 1, 2, 3 end
        \\print(f())                              -- call-arg expands: 1 2 3
        \\print(0, f())                           -- last arg expands, earlier kept: 0 1 2 3
        \\print(f(), 9)                           -- non-last call truncates to 1: 1 9
        \\local g = function() return f() end      -- `return f()` forwards all
        \\print(g())                              -- 1 2 3
        \\print((function() return f() end)())     -- nested forward: 1 2 3
        \\print(f(f()))                           -- inner f feeds outer f: 1 2 3
        \\local function h() return end            -- zero results
        \\print("x", h())                         -- zero-expand: x
        \\local o = { go = function(self, n) return n, n + 1 end }
        \\print(o:go(10))                         -- method-call expand: 10 11
        \\print(o:go(f()))                        -- method + multret last arg: self,1 → 1 2
    ,
        "1\t2\t3\n0\t1\t2\t3\n1\t9\n1\t2\t3\n1\t2\t3\n1\t2\t3\nx\n10\t11\n1\t2\n",
    );
}

test "e2e: table library — unpack/pack/insert/remove/concat/move" {
    // Drives `stdlib/table.zig` through all five modes + stress GC. `unpack` is a
    // multi native, so `print(table.unpack(t))` also re-exercises the `all_results`
    // path end-to-end via the library (not just the closure/`math.modf` cases).
    try expectProgram(
        \\local function f() return 1, 2, 3 end
        \\print(table.unpack({10, 20, 30}))            -- multret call-arg: 10 20 30
        \\print(table.unpack({10, 20, 30, 40}, 2, 3))  -- sub-range: 20 30
        \\local a, b = table.unpack({7, 8, 9})         -- fixed truncation: 7 8
        \\print(a, b)
        \\local p = table.pack(f())                    -- pack multret: n=3
        \\print(p.n, p[1], p[2], p[3])
        \\print(table.pack().n)                        -- empty pack: 0
        \\local t = {1, 2, 3}
        \\table.insert(t, 4)                           -- append
        \\table.insert(t, 1, 0)                        -- positional insert
        \\print(table.concat(t, ","))                  -- 0,1,2,3,4
        \\local r1 = table.remove(t)                   -- remove tail → 4
        \\local r2 = table.remove(t, 1)                -- remove head → 0
        \\print(r1, r2, table.concat(t, ","))          -- 4 0 1,2,3
        \\print(table.concat({9, 8, 7, 6}, "-", 2, 3)) -- ranged concat: 8-7
        \\local m = {1, 2, 3, 4, 5}
        \\table.move(m, 1, 3, 3)                        -- overlap-up copy
        \\print(table.concat(m, ","))                  -- 1,2,1,2,3
        \\local dst = {0, 0, 0, 0, 0}
        \\table.move({1, 2, 3}, 1, 3, 2, dst)          -- copy into another table
        \\print(table.concat(dst, ","))                -- 0,1,2,3,0
    ,
        "10\t20\t30\n20\t30\n7\t8\n3\t1\t2\t3\n0\n0,1,2,3,4\n4\t0\t1,2,3\n8-7\n1,2,1,2,3\n0,1,2,3,0\n",
    );
}

test "e2e: generic-for + pairs/ipairs/next" {
    // Drives `compileGenericFor` + `stdlib/base.zig` through all five modes +
    // stress GC. Covers: ipairs (array, ascending), ipairs stops at the first nil
    // hole, pairs over a string-keyed hash (canonical interning-id order),
    // n=1 `for k in pairs` (the `func` primary-projection path), mixed array+hash,
    // `false` values continue (only nil stops), break, empty table (zero
    // iterations), and a user-defined stateless 3-value iterator (`tri, nil, 0`).
    try expectProgram(
        \\local a = {10, 20, 30}
        \\for i, v in ipairs(a) do print(i, v) end
        \\local h = {1, 2, nil, 4}
        \\for i, v in ipairs(h) do print("h", i, v) end
        \\local t = {}
        \\t.x = 1
        \\t.y = 2
        \\t.z = 3
        \\for k, v in pairs(t) do print(k, v) end
        \\for k in pairs(t) do print(k) end
        \\local m = {100, 200}
        \\m.tag = 9
        \\for k, v in pairs(m) do print("m", k, v) end
        \\local ft = {}
        \\ft.p = false
        \\local c = 0
        \\for k, v in pairs(ft) do c = c + 1 end
        \\print("false-count", c)
        \\for i, v in ipairs({5, 6, 7, 8}) do
        \\  if v == 7 then break end
        \\  print("br", i, v)
        \\end
        \\for k, v in pairs({}) do print("nope") end
        \\print("empty-ok")
        \\local function tri(s, j)
        \\  j = j + 1
        \\  if j > 2 then return nil end
        \\  return j, j * 2, j * 3
        \\end
        \\for x, y, z in tri, nil, 0 do print("tri", x, y, z) end
    ,
        "1\t10\n2\t20\n3\t30\n" ++
            "h\t1\t1\nh\t2\t2\n" ++
            "x\t1\ny\t2\nz\t3\n" ++
            "x\ny\nz\n" ++
            "m\t1\t100\nm\t2\t200\nm\ttag\t9\n" ++
            "false-count\t1\n" ++
            "br\t1\t5\nbr\t2\t6\n" ++
            "empty-ok\n" ++
            "tri\t1\t2\t3\ntri\t2\t4\t6\n",
    );
}

test "e2e: generic-for delete current key during traversal (Lua-legal)" {
    // Deleting the key currently being visited is allowed; the strictly-greater
    // successor search in `next` continues correctly without crash or repeat.
    // Build a 3-key hash, delete each key as we visit it, assert all three are
    // seen exactly once and the table ends empty.
    try expectProgram(
        \\local t = {}
        \\t.a = 1
        \\t.b = 2
        \\t.c = 3
        \\local count = 0
        \\for k, v in pairs(t) do
        \\  count = count + v
        \\  t[k] = nil
        \\end
        \\print(count)
        \\local left = 0
        \\for k, v in pairs(t) do left = left + 1 end
        \\print(left)
    , "6\n0\n");
}

test "e2e: repeat/until across all modes" {
    // Post-test loop driven through every execution + GC mode. Covers: body runs
    // before the test, `until` referencing a body-local, a nested repeat, and
    // break. The accumulation is numeric so the trace recorder has a hot loop to
    // chew on without heap churn.
    try expectProgram(
        \\local i = 0
        \\local sum = 0
        \\repeat
        \\  i = i + 1
        \\  sum = sum + i
        \\  local stop = 100
        \\until sum >= stop
        \\print(i, sum)
        \\local outer = 0
        \\local total = 0
        \\repeat
        \\  outer = outer + 1
        \\  local inner = 0
        \\  repeat
        \\    inner = inner + 1
        \\    total = total + 1
        \\  until inner >= 3
        \\until outer >= 4
        \\print(outer, total)
        \\local k = 0
        \\repeat
        \\  k = k + 1
        \\  if k == 5 then break end
        \\until k >= 100
        \\print(k)
    , "14\t105\n4\t12\n5\n");
}

test "e2e: T3 hook-elision handoff — a hot loop records then runs native, byte-identical across modes" {
    // Exercises the T3 fast/slow dispatch seam end to end. `.off` (always `.fast`,
    // pure tier-0) is the oracle. The recording modes drive both transitions:
    // `.fast`→`.full` when the hotcount arms a recording at a back-edge (the next
    // instruction needs the recording mirror that `.fast` elides), then
    // `.full`→`.fast` once the trace compiles and runs as native steady state. A
    // handoff that mis-parks `pc` (the bug that hung the gate) would either
    // diverge from the oracle here or fail to terminate. The loop count is modest
    // so the GC-stress arms (which collect every instruction) finish quickly.
    try expectProgram(
        \\local acc = 0
        \\for i = 1, 300 do acc = acc + i end
        \\print(acc)
    , "45150\n");
}

test "e2e: LICM hoists a loop-invariant subexpression, transparently (all modes)" {
    // `a * b` is recomputed in the loop body every iteration, but `a` and `b`
    // are loop-invariant locals → the recorder sees an invariant `mul`, which
    // E1 LICM hoists into the preheader (computed once). The `.off` (tier-0)
    // arm is the real correctness gate: it never runs the optimizer, so its
    // output proves the hoisted optimized/native arms didn't change the value.
    // A second invariant chain (`a + b`, also hoistable) exercises a >1-deep
    // preheader cone. 1000 iters: acc = 1000*(12 + 7) = 19000.
    try expectProgram(
        \\local a = 3
        \\local b = 4
        \\local acc = 0
        \\for i = 1, 1000 do
        \\  acc = acc + a * b + (a + b)
        \\end
        \\print(acc)
    , "19000\n");
}

test "e2e: varargs spread, destructure, and nil-padding across all modes" {
    // Bare `...`: forward (`print(...)`), single-value (`local x = ...`),
    // destructure with surplus and with nil-padding (`local a, b = ...`), a
    // leading fixed param plus tail spread (`f(x, ...)`), and the empty case
    // (`...` with no surplus args). Driven through every execution + GC mode.
    try expectProgram(
        \\local function fwd(...)
        \\  print(...)
        \\end
        \\local function head(...)
        \\  local x = ...
        \\  return x
        \\end
        \\local function first2(...)
        \\  local a, b = ...
        \\  return a, b
        \\end
        \\local function tailcat(x, ...)
        \\  print(x, ...)
        \\end
        \\fwd(1, 2, 3)
        \\fwd()
        \\print(head(7, 8))
        \\print(first2(10, 20, 30))
        \\print(first2(5))
        \\tailcat(1, 2, 3)
        \\tailcat(9)
    , "1\t2\t3\n\n7\n10\t20\n5\tnil\n1\t2\t3\n9\n");
}

test "e2e: varargs forwarding through return and nested calls, method spread" {
    // `return ...` forwards all values; a nested `f(g(...))` chains two spreads;
    // a method `obj:m(...)` carries `self` plus the spread tail.
    try expectProgram(
        \\local function g(...)
        \\  return ...
        \\end
        \\local function f(...)
        \\  print(g(...))
        \\end
        \\f(1, 2)
        \\f(3, 4, 5)
        \\local obj = { name = "lune" }
        \\obj.greet = function(self, ...)
        \\  print(self.name, ...)
        \\end
        \\obj:greet("a", "b")
        \\obj:greet()
    , "1\t2\n3\t4\t5\nlune\ta\tb\nlune\n");
}

test "e2e: parenthesized varargs truncate to a single value" {
    // `(...)` is the Lua paren-truncation rule: even in a tail position it yields
    // exactly one value (the first), so `return (...)` and `f((...))` are single.
    try expectProgram(
        \\local function pick(...)
        \\  return (...)
        \\end
        \\local function wrap(...)
        \\  print((...), "end")
        \\end
        \\print(pick(10, 20, 30))
        \\print(pick())
        \\wrap(1, 2, 3)
    , "10\nnil\n1\tend\n");
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

test "e2e: basic + string stdlib are byte-identical across all modes" {
    // Exercises the S1/S2 pure natives, including string ops called inside a hot
    // loop (so recording + native compilation cross a native call). Output must be
    // identical across {off, record_only, noopt, record_execute, native} × stress.
    try expectProgram(
        \\for i = 1, 3 do
        \\  print(string.format("%d:%s", i, string.rep("ab", i)))
        \\end
        \\print(type("x"), math.type(1), math.type(1.5), _VERSION)
        \\print(select("#", 1, 2, 3), select(2, "a", "b"))
        \\print(string.sub("hello", 2, 4), string.byte("A"))
    ,
        "1:ab\n2:abab\n3:ababab\n" ++
            "string\tinteger\tfloat\tlune 0.0.0\n" ++
            "3\tb\n" ++
            "ell\t65\n",
    );
}

test "e2e: string pattern matching is byte-identical across all modes" {
    // find/match/gmatch/gsub through the VM. The 50-iteration loop calling a
    // pattern native makes the recorder cross a native call in a hot loop; the
    // gmatch generic-for exercises the state-table iterator. Output must be
    // identical across {off, record_only, noopt, record_execute, native} × stress.
    try expectProgram(
        \\local c = 0
        \\for i = 1, 50 do
        \\  if string.find("hello world", "world") then c = c + 1 end
        \\end
        \\print(c, string.match("k=v", "(%w+)=(%w+)"))
        \\print(string.find("abcabc", "b", 3))
        \\local n = 0
        \\for w in string.gmatch("a b c d", "%a") do n = n + 1 end
        \\print(n, (string.gsub("hello", "l", "L")))
    ,
        "50\tk\tv\n" ++
            "5\t5\n" ++
            "4\theLLo\n",
    );
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
    // Baseline = the permanent base-library footprint (every installed native +
    // its module tables + the `arg` table), captured right after init. Measuring
    // against this keeps the bound robust as the stdlib grows instead of baking a
    // magic total that breaks each time a library lands.
    const base_objects = vm.heap.object_count;
    vm.heap.gc_stress = true;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("200\n", sink.buffered());

    // The decisive assertion: the live set is bounded, *not* proportional to the
    // 200 iterations. Beyond the permanent base set, only a handful survive (the
    // main closure, "last"/literals, and a couple of still-rooted tables) — far
    // below the ~200 a missing collector would leave.
    try testing.expect(vm.heap.object_count < base_objects + 24);
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

test "per-guard PC: last_exit_instr is set on zero-iteration guard failure" {
    // A loop where types change mid-run so the recorded trace fails a guard
    // on its very first execution. With hotloop=4, iteration 5 records and
    // iteration 6 executes — the `if i == 6` branch changes direction, so
    // guard_false on the eq result fails with completed=0.
    const gpa = testing.allocator;
    const source =
        \\local x = 0
        \\for i = 1, 100 do
        \\    if i == 6 then x = x + 0.5 else x = x + 1 end
        \\end
        \\print(x)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.hotguard = 1000; // prevent fingerprint-miss side traces
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    // The trace MUST have been executed and failed at a guard.
    try testing.expect(vm.trace.last_exit_instr != std.math.maxInt(u32));
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    const ei = vm.trace.last_exit_instr;
    try testing.expect(ei < t.instrs.len);

    // The failing instruction must be a guard.
    const failed = t.instrs[ei];
    try testing.expect(switch (failed.op) {
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false => true,
        else => false,
    });
    // And its aux must carry the bytecode PC where it was recorded.
    try testing.expect(failed.aux > 0);
}

test "side traces: type-changing loop records a second trace at the same anchor" {
    // When a guard in the root trace fails repeatedly (type change), a side
    // trace is recorded at the same loop header, and same-anchor chaining
    // runs the correct trace for each iteration's types.
    const gpa = testing.allocator;
    const source =
        \\local x = 0
        \\for i = 1, 20 do
        \\    if i == 6 then x = x + 0.5 else x = x + 1 end
        \\end
        \\print(x)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotguard = 3; // low threshold for test
    vm.trace.config.min_trip_entry = 0; // exercise side traces on a short test loop
    vm.trace.config.record_exec_log = true;

    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    // Two traces should exist at the same anchor: the root trace (int path)
    // and the side trace (float path, recorded after guard failures).
    try testing.expect(vm.trace.cache.items.len >= 2);
    // Guard failures are cleared when the side trace arms, and no new
    // failures are counted once 2+ traces exist (avoids unbounded growth).
    // Output must be correct despite the type change mid-loop.
    // i=1..5: x=5 (int); i=6: x=5.5 (float); i=7..20: x=19.5.
    try testing.expectEqualStrings("19.5\n", sink.buffered());
}

test "side traces: without side traces the anchor blacklists; with them it stays live" {
    // Run the same type-changing program twice: once with a hotguard threshold
    // so high that no side trace fires (the anchor blacklists), and once with
    // a low threshold (side trace keeps the anchor alive).  Both must produce
    // correct output — side traces are a performance optimisation, not a
    // correctness requirement.
    const gpa = testing.allocator;
    const source =
        \\local x = 0
        \\for i = 1, 30 do
        \\    if i == 6 then x = x + 0.5 else x = x + 1 end
        \\end
        \\print(x)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // --- Run 1: no side traces (hotguard > iteration count) ---
    {
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        try testing.expect(!diags.hasErrors());

        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.hotloop = 4;
        vm.trace.config.hotguard = 1000; // effectively never
        vm.trace.config.min_trip_entry = 0; // exercise entry on a short test loop
        vm.trace.config.max_penalty = 8; // blacklists after 8 zero-yield entries

        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        _ = try vm.run(chunk.proto);

        // Only the root trace exists — no side trace was ever recorded.
        try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
        // The anchor is NOT blacklisted: type fingerprinting skips the
        // trace when x becomes float instead of entering-and-failing,
        // so no penalty accumulates.
        try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
        // Output is still correct — tier-0 handles the type-changed iterations.
        // i=1..5: x=5; i=6: x=5.5; i=7..30: x = 5.5 + 24 = 29.5.
        try testing.expectEqualStrings("29.5\n", sink.buffered());
    }

    // --- Run 2: side traces enabled (hotguard = 3) ---
    {
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        try testing.expect(!diags.hasErrors());

        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.hotloop = 4;
        vm.trace.config.hotguard = 3; // fire a side trace after 3 guard failures
        vm.trace.config.min_trip_entry = 0; // exercise side traces on a short test loop
        vm.trace.config.max_penalty = 8; // (would blacklist without side traces)

        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        _ = try vm.run(chunk.proto);

        // Two traces: the root trace (int path) and the side trace (float path).
        try testing.expect(vm.trace.cache.items.len >= 2);
        // The anchor is NOT blacklisted — the float side trace commits useful
        // iterations (> min_useful), clearing the penalty before it maxes out.
        try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
        // Same correct output.
        try testing.expectEqualStrings("29.5\n", sink.buffered());
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
    // acc and the loop index are loop-carried, so they surface as slot-bound φs.
    var n_phi: usize = 0;
    for (t.instrs) |ins| {
        if (ins.op == .phi and ins.aux >= 0) n_phi += 1;
    }
    try testing.expect(n_phi >= 1);
    try testing.expect(t.entry_slots.len >= 1);
    // No host/cross-frame op was hit, so nothing was blacklisted.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
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

    // Every surviving slot-bound φ is either below the watermark (a real local /
    // loop control) or a slot the trace actually read — never a dead temporary.
    var saw_acc = false;
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        const was_read = std.mem.indexOfScalar(u16, t.entry_slots, slot) != null;
        try testing.expect(@as(usize, slot) < watermark or was_read);
        if (slot == 0) saw_acc = true; // `acc` is the first local → slot 0
    }
    // The loop-carried accumulator is still committed.
    try testing.expect(saw_acc);
    // And no high write-only temporary leaked through.
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        if (@as(usize, slot) >= watermark)
            try testing.expect(std.mem.indexOfScalar(u16, t.entry_slots, slot) != null);
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
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        if (std.mem.indexOfScalar(u16, t.entry_slots, slot) == null) saw_write_only = true;
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
    try testing.expect(vm.trace.gate.count() >= 1);
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
    try testing.expect(vm.trace.gate.count() >= 1);
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
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
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

test "native: a float-accumulate loop compiles to the XMM path (Phase D / F1)" {
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

    // Phase D: the float add (carried float accumulator + int-controlled for loop)
    // is now inside the native subset — the compiler lowers it to the SSE2/XMM path
    // (cvtsi2sd-free here: both add operands are float) and memoizes `.compiled`.
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expect(vm.trace.cache.items[0].native == .compiled);

    // Decisive soundness check: native output is byte-identical to a plain tier-0 run
    // (strict-FP addsd matches the oracle bit-for-bit — 150.0).
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

test "native: int_of_float — a float-limit loop compiles native, then deopts on a non-integral limit, matching tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The numeric-for limit is a FLOAT that is integral (`100.0`), so the recorder
    // emits `int_of_float` to convert it to an exact i64 once (LICM-hoisted into the
    // preheader), making the body compare int-vs-int — the whole reason `proveKinds`
    // accepts the trace and it lowers to machine code. The function is called first
    // with an integral float limit (compiles native + runs it), then with a
    // *non-integral* limit (`100.5`): the native trace's `int_of_float` round-trip
    // check (cvttsd2si;cvtsi2sd;ucomisd;jne/jp) fails and side-exits to tier-0, which
    // runs the loop with the exact mixed int-vs-float compare. The result must equal a
    // plain tier-0 run to the last unit — proving the convert-or-deopt is sound.
    const source =
        \\local function f(m)
        \\  local acc = 0
        \\  for i = 1, m do acc = acc + i end
        \\  return acc
        \\end
        \\local s = 0
        \\for _ = 1, 8 do s = s + f(100.0) end
        \\s = s + f(100.0)
        \\s = s + f(100.5)
        \\print(s)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // The float-limit loop did lower to machine code (int_of_float made it native-able)...
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
    // ...and the native run (deopt on 100.5 included) is byte-identical to tier-0.
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "int_of_float: float-limit loop is byte-identical across all 8 modes (deopt on non-integral limit)" {
    // Same convert-then-deopt shape, but pinned through the full mode matrix
    // (off / record_only / record_execute_noopt / record_execute / native) × GC
    // stress. record_execute_noopt keeps `int_of_float` in-body (one extra idempotent
    // convert per iteration); record_execute / native hoist it into the preheader —
    // all five must agree to the byte. The non-integral final call exercises the
    // side-exit in every mode that runs the op.
    try expectProgram(
        \\local function f(m)
        \\  local acc = 0
        \\  for i = 1, m do acc = acc + i end
        \\  return acc
        \\end
        \\local s = 0
        \\for _ = 1, 8 do s = s + f(100.0) end
        \\s = s + f(100.5)
        \\print(s)
    , "45450\n");
}

test "native: a bool-lane growth loop compiles native (astore_append) and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=2,N do t[i]=true end` grows the boolean array part. After the first
    // rehash narrows to the bool lane and drains the hash, every iteration is an
    // append (idx == len+1): the recorder emits guard_append + astore_append, and
    // proveKinds accepts the bool-lane grow store so it lowers to machine code (a
    // byte store + an in-place `inc qword [tbl+len]`; the realloc on a cap-doubling
    // boundary is peeled to a guard_append side-exit, never on-trace).
    const source =
        \\local t = {}
        \\for i = 2, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // Some cached trace is the grow loop and carries an astore_append — and that
    // trace lowered to machine code (proveKinds admitted the bool-lane grow store).
    var saw_append = false;
    var compiled_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op == .astore_append) {
                saw_append = true;
                if (tr.native == .compiled) compiled_append = true;
            }
        }
    }
    try testing.expect(saw_append);
    try testing.expect(compiled_append);
    // The native run (grow loop + read loop) is byte-identical to pure tier-0.
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "astore_append: a bool-lane growth loop is byte-identical across all 8 modes" {
    // The grow store through the full matrix (off / record_only / record_execute_noopt
    // / record_execute / native) × GC stress. The realloc-as-side-exit design is sound
    // only if `len`/`cap`/`data` land identically in tier-0, tier-1a, and native — a
    // divergence (a missed len bump, a wrong byte, a realloc leaking on-trace) prints a
    // different count here. The read loop afterward observes the grown array, so a
    // mis-sized grow would change the printed total.
    try expectProgram(
        \\local t = {}
        \\for i = 2, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    , "4999\n");
}

test "eager commit: a dense-from-1 bool fill traces + compiles native (no hole, no rehash detour)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=1,N do t[i]=true end` — the common array-fill idiom, dense from index
    // 1. Without eager lane commitment this stays on the `.value` lane forever (the
    // append fast path keeps the hash empty so Table.rehash never fires) and the
    // recorder aborts on every store. Eager commit narrows to the boolean lane on
    // the FIRST append, so the steady-state append loop records guard_append +
    // astore_append and lowers to native — exactly like the hole-at-1 shape, but
    // for real dense-from-1 code.
    const source =
        \\local t = {}
        \\for i = 1, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    var saw_append = false;
    var compiled_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op == .astore_append) {
                saw_append = true;
                if (tr.native == .compiled) compiled_append = true;
            }
        }
    }
    try testing.expect(saw_append);
    try testing.expect(compiled_append);
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "eager commit: a dense-from-1 bool fill is byte-identical across all 8 modes" {
    // The eager-commit representation change is determinism-adjacent: it changes
    // *when* the lane narrows (append-time vs rehash-time). The lane is never
    // serialized and keyframe restore re-derives it by replaying these same
    // appends, so every mode must evolve it identically. A mis-timed commit, a
    // wrong byte, or an on-trace realloc would change the printed count here.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    , "5000\n");
}

test "astore_append (int lane): a dense-from-1 fill (t[i]=i) compiles native and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=1,N do t[i]=i end` — the int analogue of the bool fill, storing the loop
    // counter. Eager commit narrows to `.i8` on the first append; the value then
    // outgrows the lane (i==128) and `guard_fits` side-exits to tier-0, which WIDENS
    // (i8→i16) and re-enters, so the steady-state append trace records on the i16 lane.
    // The recorder emits guard_append + guard_fits + astore_append and proveKinds now
    // admits the int grow store, so it lowers to a width store + `bts [present]` +
    // `inc [len]` (Phase B). The read loop sums the values, exercising int aload too.
    // (A *constant* fill like `t[i]=7` stays tier-1a today: the optimizer folds the
    // provably-in-range guard_fits, leaving no fits proof — a pre-existing gap shared
    // with the in-bounds int astore, tracked separately. A dynamic value is the case
    // Phase B targets.)
    const source =
        \\local t = {}
        \\for i = 1, 5000 do t[i] = i end
        \\local c = 0
        \\for i = 1, 5000 do c = c + t[i] end
        \\print(c)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    var saw_append = false;
    var compiled_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op == .astore_append) {
                saw_append = true;
                if (tr.native == .compiled) compiled_append = true;
            }
        }
    }
    try testing.expect(saw_append);
    try testing.expect(compiled_append);
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "widen-eviction: a lane-crossing fill retires the narrow trace and stabilises on the wider one" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=1,5000 do t[i]=i end` eager-commits `.i8`, records an i8 append
    // trace, then crosses i8→i16 at i=128. Pre-eviction the dead i8 trace
    // lingered (consuming a per-anchor slot) and the loop ran the i16 tail under
    // a permanently-failing guard. Widen-eviction retires the i8 trace the first
    // time its `guard_lane` fails against the now-wider live array, and reopens
    // the anchor so the *stable* i16 lane records + compiles. We assert the
    // surviving append trace guards i16 (ordinal 3), NOT i8 (ordinal 2), proving
    // the dead narrow trace was evicted and the wider one took its place.
    const arr = @import("array.zig");
    const i8_ord = @intFromEnum(arr.Lane.i8);
    const i16_ord = @intFromEnum(arr.Lane.i16);
    const source =
        \\local t = {}
        \\for i = 1, 5000 do t[i] = i end
        \\print(t[5000])
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    var saw_i16_append = false;
    var saw_i8_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op != .astore_append) continue;
            // The append's lane lives in its own `aux`; the leading guard_lane
            // carries the same ordinal. Read the op directly.
            if (ins.aux == i16_ord and tr.native == .compiled) saw_i16_append = true;
            if (ins.aux == i8_ord) saw_i8_append = true;
        }
    }
    try testing.expect(saw_i16_append); // the stable wider lane records + compiles
    try testing.expect(!saw_i8_append); // the dead narrow trace was evicted
    try testing.expectEqualStrings("5000\n", nsink.buffered());
}

test "astore_append (int lane): a widening int fill is byte-identical across all 8 modes" {
    // The full matrix for an int grow store that crosses a lane boundary. The grow
    // store, its guard_fits side-exit, the tier-0 widen, and the separate presence
    // bitmap must all land identically in tier-0, tier-1a, and native — a missed len
    // bump, a wrong width store, or an unset presence bit would change the printed sum.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 5000 do t[i] = i end
        \\local c = 0
        \\for i = 1, 5000 do c = c + t[i] end
        \\print(c)
    , "12502500\n");
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

test "executor: a variable that flips int->float mid-loop deopts to tier-0 and still matches tier-0" {
    // Recorded as an integer loop (the `i == 20` branch is not taken when it goes
    // hot). At i == 20 tier-0 takes the branch and `x` becomes a float; every later
    // back-edge is a fingerprint mismatch — the trace is skipped, tier-0 runs the
    // tail directly. No failed entries, no blacklisting. The result must still
    // equal tier-0's to the last decimal.
    const source =
        \\local x = 0
        \\for i = 1, 200 do
        \\  if i == 20 then x = x + 0.5 end
        \\  x = x + 1
        \\end
        \\print(x)
    ;
    try expectTier0Equiv(source);

    // Introspect: the type flip causes fingerprint mismatches, not blacklisting.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    // The anchor is NOT blacklisted — fingerprinting skips the trace after the
    // type change instead of trial-entering and failing.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
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
    try testing.expect(vm.trace.gate.count() >= 1);
    // The blacklist must GATE ENTRY, not merely be set: once the anchor maxes out
    // its penalty (≤ ~max_penalty productive-but-low-yield entries), the dispatch
    // loop stops entering the cached trace and tier-0 owns the remaining ~180
    // iterations. Without the entry-gate this loop entered the trace ~100 times
    // (once per even iteration) and ran *slower* than tier-0. Bound it well under
    // that to prove re-entry actually halts.
    try testing.expect(vm.trace.entries < 30);
}

test "executor: a thrashing anchor that later stabilizes recovers from the gate" {
    // The gate is not a death sentence — an anchor that thrashes transiently must
    // come back. The branch `i % 100 < 90` is a SINGLE guard that oscillates in
    // phases: 90 iterations true (the trace, recorded on the true arm at i=5, runs
    // one long useful entry) then 10 iterations false (the trace is entered and the
    // guard fails immediately → < min_useful → the penalty climbs and, at
    // max_penalty, gates the anchor with backoff). Crucially the next true-phase
    // re-enters the SAME cached trace on the SAME guard and commits a long useful
    // run, which CLEARS the gate. The loop ends deep in a true-phase (i=389,
    // i%100=89) well past the last gate's cooldown, so recovery has completed and
    // the gate is empty. A permanent blacklist would have abandoned the anchor on
    // the first low-yield burst and left it gated forever.
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 389 do
        \\  if i % 100 < 90 then s = s + 1 else s = s + 2 end
        \\end
        \\print(s)
    ;
    try expectTier0Equiv(source);

    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.max_penalty = 8; // gate after 8 low-yield entries
    vm.trace.config.backoff_base = 16; // short cooldown so recovery fits in 400 iters

    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    // `else` (s+2) taken when i%100 ∈ {90..99}: i ∈ {90..99,190..199,290..299} = 30.
    // `then` (s+1) the other 359. s = 359×1 + 30×2 = 419.
    try testing.expectEqualStrings("419\n", sink.buffered());
    // Recovered: the long stable tail committed a useful entry which removed the
    // gate. If recovery were broken (permanent abandonment) the gate would persist.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
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
