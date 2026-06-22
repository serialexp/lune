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
const regwindow = @import("regwindow.zig");
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
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;

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
    /// A `file_read` effect ran (in `off`/`record` mode) but no `fs_source` was
    /// injected. Mirrors `EnvUnavailable`: the VM holds no filesystem of its own —
    /// `loadfile`/`dofile` read through the embedder's `FsSource`. Replay needs none
    /// (the file content is in the log).
    FsUnavailable,
    /// Allocation failure (register stack, future heap).
    OutOfMemory,
    /// A lune program raised a VALUE via `error(obj)`/`assert` (or a runtime fault
    /// re-raised through a protected boundary). The value itself rides
    /// `Vm.pending_error`; this Zig tag is only the unwinding signal. Caught by
    /// `pcall`/`xpcall`, which read+clear `pending_error`.
    LuaError,
    /// An `__index`/`__newindex` table chain exceeded `max_metatable_chain` hops
    /// — almost certainly a metatable cycle (`setmetatable(t, {__index=t})` and
    /// kin). Surfaced as a located runtime fault rather than hanging the VM.
    MetatableChainLoop,
    /// Replay's recorded `unicode_version` effect (S-C) names a Unicode version
    /// that differs from the one this binary's case table was compiled against.
    /// `upper`/`lower` would map differently, breaking byte-identical replay, so
    /// the run refuses rather than silently diverging. Fatal like
    /// `EffectKindMismatch` — NOT a catchable `LuaError`.
    UnicodeVersionMismatch,
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

/// Maximum nesting of native→VM reentry (`callValue`). Each level is a native
/// (e.g. `pcall`/`table.sort`/`gsub`) that calls back into the dispatch loop on
/// the **Zig host stack** — distinct from `max_call_depth`, which bounds the Lua
/// frame stack. A `pcall(pcall(pcall(…)))` chain or a comparator that recurses
/// through `table.sort` grows this; the cap turns host-stack exhaustion into a
/// clean `StackOverflow` instead of a crash.
const max_native_reentry: u16 = 200;

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

/// An embedder-supplied filesystem read seam, backing the `file_read` effect
/// (`loadfile`/`dofile`). The VM holds no filesystem of its own — so it still
/// compiles to `wasm32-freestanding`, where the host injects a null source (or an
/// in-memory one). Consulted in `off`/`record`; `replay` reads the file content
/// from the log and never touches disk. With no source set, `loadfile`/`dofile`
/// fail with `FsUnavailable`. The returned bytes are **borrowed** (valid only for
/// the call) — the native interns them into the heap immediately, exactly like
/// `HostEnv.getenv`. `null` ⇒ the file could not be opened (any reason); the
/// caller turns that into Lua's `(nil, "cannot open <path>")`. The path is plain
/// program data, so the source need not record it — only the content is the input.
pub const FsSource = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, path: []const u8) ?[]const u8,
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
    stdbase.natives ++ stdbasic.natives ++ stdstring.natives ++ stderrors.natives ++
    stddebug.natives ++ stdload.natives ++ stdpackage.natives;

/// The interpreter's own natives. `print` is pure output; `clock` is the first
/// nondeterministic input.
const core_natives = [_]BaseNative{
    .{ .name = "print", .func = &nativePrint },
    // `warn` is a pure host output to stderr (no effect, like `print`); the `@on`/
    // `@off` control state lives in `Vm.warn_enabled`.
    .{ .name = "warn", .func = &nativeWarn },
    // `os.clock` (float seconds) + `os.nsclock` (int nanoseconds, a lune extension)
    // share the `.clock` effect. `.name` stays bare (`clock`/`nsclock`) — the
    // serialized keyframe identity; `.module`/`.field` only drive table install,
    // exactly as `math.random` did. This drops the flat `clock` global and makes
    // `os` a known builtin via `builtin_global_names` (`bn.module orelse bn.name`).
    .{ .name = "clock", .func = &nativeClock, .effect = .clock, .module = "os", .field = "clock" },
    .{ .name = "nsclock", .func = &nativeNsClock, .effect = .clock, .module = "os", .field = "nsclock" },
    // `random`/`randomseed` carry no `effect`: the call itself isn't the boundary —
    // the *seed* is (acquired once, inside the native, as `.random_seed`). So the
    // dispatch calls them directly; the seed goes through record/replay internally.
    // Installed into the `math` table (Lua-shaped namespacing); the `.name` stays
    // bare — it is the serialized keyframe identity, the module/field only drive
    // table install. Both are Vm-touching natives, so they live here, not in the
    // pure `stdlib/math.zig`.
    .{ .name = "random", .func = &nativeRandom, .module = "math", .field = "random" },
    .{ .name = "randomseed", .func = &nativeRandomseed, .module = "math", .field = "randomseed" },
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
    var tmp: [base_natives.len + 3][]const u8 = undefined;
    var n: usize = 0;
    outer: for (base_natives) |bn| {
        // `manual` natives have no global/module slot (restore-only — e.g. the
        // default `package.searchers`), so they contribute no known global name.
        if (bn.manual) continue;
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
    // `_G` is the global environment table (seeded in `installBaseLib` as a
    // self-reference); programs reference it for reflection, so the lint knows it.
    tmp[n] = "_G";
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
    /// True when `message` already carries its own `chunk:line:` location — a
    /// raised Lua value (`error`/`assert`/`badArg`), which Lua prints verbatim.
    /// The reporter must NOT append a second " at chunk:line" suffix in this case
    /// (the type-name faults, which are not self-located, still rely on it).
    self_located: bool = false,
};

/// A resolved call site: the frame, its faulting/call instruction, and its source
/// span/line. The single source of truth for "where is the call `level` frames up"
/// — shared by `describeFault`'s `.call` arm, `Vm.badArg`, and `error(msg, level)`
/// so their location logic can never drift.
pub const CallSite = struct {
    proto: *const Proto,
    base: usize,
    pc: usize,
    span: bytecode.Span,
    line: u32,
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
/// The interned metamethod-name strings the VM dispatches on, built once in
/// `Vm.init` so a metamethod lookup never re-interns a `"__index"` key on the
/// hot path. Each is a heap-string `Value` (or `nil` before `init` runs / in a
/// bare VM). GC-rooted via `forEachRootHeader` so a collection mid-dispatch
/// cannot sweep them. Chunk 2a needs only these three; chunk 2b grows the set
/// (`__add`, `__eq`, `__concat`, …) the same way.
/// The interned metamethod-name strings, cached once so dispatch never
/// re-interns. Each field `foo` holds the interned string `"__foo"` — the
/// `"__" ++ field` mapping is exploited by `internMetamethodNames` and
/// `forEachRootHeader` (both `inline for` over these fields), so adding a
/// metamethod is a one-line field addition here. All `nil` in a bare VM.
const MetamethodNames = struct {
    // -- chunk 2a: indexing + metatable protection --
    /// `"__index"` — read fallback for an absent key (table or function).
    index: Value = Value.nil(),
    /// `"__newindex"` — write fallback for an absent key (table or function).
    newindex: Value = Value.nil(),
    /// `"__metatable"` — when present, `getmetatable` returns it and
    /// `setmetatable` refuses to change the (protected) metatable.
    metatable: Value = Value.nil(),
    // -- chunk 2b: arithmetic (fired when an operand is not a number) --
    add: Value = Value.nil(),
    sub: Value = Value.nil(),
    mul: Value = Value.nil(),
    div: Value = Value.nil(),
    mod: Value = Value.nil(),
    pow: Value = Value.nil(),
    idiv: Value = Value.nil(),
    /// `"__unm"` — unary minus; handler called as `h(v, v)` (operand twice).
    unm: Value = Value.nil(),
    // -- chunk 2b: bitwise (fired when an operand has no integer form) --
    band: Value = Value.nil(),
    bor: Value = Value.nil(),
    bxor: Value = Value.nil(),
    /// `"__bnot"` — unary bitwise-not; handler called as `h(v, v)`.
    bnot: Value = Value.nil(),
    shl: Value = Value.nil(),
    shr: Value = Value.nil(),
    // -- chunk 2b: other operators --
    /// `"__concat"` — `a .. b` when an operand is not a string/number.
    concat: Value = Value.nil(),
    /// `"__len"` — `#t` for a table (overrides the raw border length).
    len: Value = Value.nil(),
    /// `"__eq"` — `a == b` only when both are tables and raw-unequal.
    eq: Value = Value.nil(),
    /// `"__lt"` — `a < b` (and `a > b` ≡ `b < a`) when not raw-comparable.
    lt: Value = Value.nil(),
    /// `"__le"` — `a <= b` (and `a >= b` ≡ `b <= a`) when not raw-comparable.
    le: Value = Value.nil(),
    /// `"__call"` — calling a non-callable value: `h(value, args...)`.
    call: Value = Value.nil(),
    /// `"__tostring"` — `tostring(v)` / `print(v)`; must return a string.
    tostring: Value = Value.nil(),
};

pub const Vm = struct {
    gpa: std.mem.Allocator,
    /// The object heap (strings, tables, closures, …). Owns every heap value a
    /// running program produces; freed wholesale by `deinit`.
    heap: gc.Heap,
    /// The global environment: a table keyed by interned name strings. Free
    /// (non-local) names read and write here; the base library installs here.
    globals: *table.Table,
    /// Shared register/call stack, **struct-of-arrays** (docs/design/09): the
    /// `Value.Tag` discriminant lane and the raw 8-byte `Value.payload.bits` lane,
    /// stored in parallel so the hot tier-0 arms address a 1-byte tag (scale-1)
    /// and an 8-byte payload (scale-8) with no 16-byte index scaling and no
    /// 16-byte arithmetic-temporary spill. Both fixed-size and never reallocated
    /// (see `stack_slots`), so frame windows stay valid across nested calls.
    /// `tags.len == payloads.len == stack_slots` always.
    tags: []u8,
    payloads: []u64,
    /// A reusable `[]Value` scratch buffer, absolute-indexed exactly like the
    /// register file, used **only** at the native / `callValue` boundary to
    /// materialize the contiguous `[]Value` arg/result slices the native ABI
    /// still speaks (gather operands in, scatter results back). Off the hot
    /// arithmetic path. Nesting-safe: `callValue` parks nested args at higher
    /// absolute indices, so a nested native's scratch region is disjoint from its
    /// caller's — the same disjointness the SoA register file itself relies on.
    boundary_scratch: []Value,
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
    /// Current native→VM reentry nesting (`callValue`). Bounded by
    /// `max_native_reentry` to keep a `pcall`/comparator chain from overflowing the
    /// Zig host stack. Incremented around each nested `execWith`, restored after.
    native_reentry_depth: u16 = 0,
    /// The in-flight Lua error value, set by `error`/`assert` (and read by
    /// `pcall`/`xpcall`). Non-null only between a raise and the nearest protected
    /// boundary that catches it — every `pcall` clears it. A **GC root while set**
    /// (`forEachRootHeader`) and **transient**: like `reg_top`, it is never
    /// serialized and must be null at any suspend safepoint (a snapshot taken
    /// mid-unwind could not resume). Runtime faults (`TypeError`, …) leave this
    /// null and are turned into a value lazily at the catch via `synthErrorValue`.
    pending_error: ?Value = null,
    /// Open upvalues, keyed by absolute stack index. Searched on capture (to
    /// share a cell) and on scope/frame exit (to close cells over dying slots).
    open_upvalues: std.ArrayList(OpenUpvalue) = .empty,
    /// Where the `print` host-effect writes. `null` means the process's buffered
    /// stdout (`io.zig`); a test (or a future effect recorder) can point this at
    /// an in-memory writer to capture output without touching the real stdout.
    out: ?*io.Writer = null,
    /// Where `warn` writes (parallel to `out`). `null` means the process's buffered
    /// stderr (`io.zig`); a test points this at an in-memory writer to capture the
    /// warning text. Diagnostics go to stderr so they never interleave with a
    /// program's stdout.
    err: ?*io.Writer = null,
    /// Lua 5.4 `warn` system enabled, toggled by the `@on`/`@off` control messages.
    /// Per-session runtime state — NOT serialized (a warning preference, not
    /// replayed program behaviour); a restored VM starts enabled like a fresh one.
    warn_enabled: bool = true,
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
    /// S-C: whether this session has already pinned its Unicode version (logged in
    /// `record` / consumed in `replay`) at the first `upper`/`lower`. In-memory
    /// only — deliberately NOT serialized: on a snapshot-resume it is re-derived
    /// from the supplied `(effect_log, effect_cursor)` by `noteUnicodeVersion`
    /// (scanning for an already-consumed `.unicode_version`), exactly as the PRNG
    /// is not persisted either. See `noteUnicodeVersion`.
    unicode_version_pinned: bool = false,
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
    /// Embedder-supplied filesystem read seam for `loadfile`/`dofile` (null = none).
    /// Read in `off`/`record` (`main.zig` native = real disk, the wasm host = a
    /// null/in-memory source); `replay` feeds file content from the log. No source
    /// set ⇒ `FsUnavailable`.
    fs_source: ?FsSource = null,
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
    /// Interned metamethod-name strings (`__index`/`__newindex`/`__metatable`),
    /// built once in `init`. Left all-`nil` in a bare VM (`initBare`); the
    /// keyframe restorer rebuilds them after seeding the heap. GC-rooted via
    /// `forEachRootHeader`.
    mm: MetamethodNames = .{},
    /// The shared built-in **string metatable** (chunk 2a / M3): a table whose
    /// `__index` is the `string` module table, so indexing a string with an
    /// absent raw key flows through to the string library and `("x"):upper()`
    /// works. Built once after `installBaseLib`; `null` in a bare VM until the
    /// restorer rebinds it. Referenced from the VM (not `globals`), so it is
    /// GC-rooted explicitly via `forEachRootHeader`.
    string_metatable: ?*table.Table = null,
    /// Chunks compiled at runtime by `load`/`loadfile`/`dofile`. A `load` closure
    /// can outlive the call that created it, so the VM owns each compiled `Chunk`
    /// (its arena holds the proto tree) plus a NUL-terminated copy of the source
    /// the protos point at (`Proto.source`, used for error line numbers and, in
    /// L-2, recompile-on-restore). Freed in `deinit` in append order.
    loaded_chunks: std.ArrayList(LoadedChunk) = .empty,
    /// Next proto id to hand out. Seeded to the static chunk's proto count in
    /// `run`/`start` so every dynamically-`load`ed proto gets a globally-unique id
    /// across the static + dynamic trees — purely so snapshot serialization can
    /// resolve a `proto_id` to exactly one proto (the pointer-based JIT ignores
    /// ids). 0 until seeded.
    next_proto_id: u32 = 0,

    /// A runtime-compiled chunk owned by the VM: the `Chunk` (whose arena owns the
    /// proto tree) and the NUL-terminated source the protos borrow.
    pub const LoadedChunk = struct {
        chunk: compiler.Chunk,
        source: [:0]u8,
    };

    pub fn init(gpa: std.mem.Allocator) Error!Vm {
        var vm = try initBare(gpa);
        errdefer gpa.free(vm.tags);
        errdefer gpa.free(vm.payloads);
        errdefer gpa.free(vm.boundary_scratch);
        errdefer vm.heap.deinit();
        // The globals table lives on the heap like any other table (id 0), then
        // the base library installs (the `print` native + its interned name).
        vm.globals = try vm.heap.newTable();
        try vm.installBaseLib();
        try vm.initMetatableSupport();
        return vm;
    }

    /// Build the metamethod-name string cache and the shared string metatable.
    /// Split out of `init` so the keyframe restorer can rebuild the *same*
    /// runtime-derived state after it reseeds the heap (the names re-intern to
    /// the already-present ids; the string metatable is rebound to its restored
    /// table). Idempotent w.r.t. interning — `internValue` returns the existing
    /// string when the bytes are already present.
    /// Intern every `"__<field>"` metamethod name into `self.mm`. Idempotent
    /// (`internValue` returns the existing string), so both `init` and the
    /// keyframe restorer can call it — restore re-interns to the already-present
    /// ids. Single source of truth for the name set: one `inline for` over the
    /// `MetamethodNames` fields, so adding a metamethod needs no edit here.
    pub fn internMetamethodNames(self: *Vm) std.mem.Allocator.Error!void {
        inline for (@typeInfo(MetamethodNames).@"struct".field_names) |name| {
            @field(self.mm, name) = try self.heap.internValue("__" ++ name);
        }
    }

    fn initMetatableSupport(self: *Vm) Error!void {
        try self.internMetamethodNames();
        // The shared string metatable: `__index` → the `string` module table, so
        // `s:method(...)` (compiled as `get_index` + `call` with `self`) resolves
        // `method` through the string library. Built only when the string module
        // exists (it always does after `installBaseLib`).
        const string_mod = try self.getOrCreateModuleTable("string");
        const smt = try self.heap.newTable();
        try smt.set(self.gpa, self.mm.index, Value.heap(&string_mod.header));
        self.string_metatable = smt;
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
        const tags = try gpa.alloc(u8, stack_slots);
        errdefer gpa.free(tags);
        const payloads = try gpa.alloc(u64, stack_slots);
        errdefer gpa.free(payloads);
        const boundary_scratch = try gpa.alloc(Value, stack_slots);
        errdefer gpa.free(boundary_scratch);
        return Vm{
            .gpa = gpa,
            .heap = gc.Heap.init(gpa),
            .globals = undefined,
            .tags = tags,
            .payloads = payloads,
            .boundary_scratch = boundary_scratch,
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
        for (self.loaded_chunks.items) |*lc| {
            lc.chunk.deinit();
            self.gpa.free(lc.source);
        }
        self.loaded_chunks.deinit(self.gpa);
        self.heap.deinit();
        self.gpa.free(self.tags);
        self.gpa.free(self.payloads);
        self.gpa.free(self.boundary_scratch);
    }

    // ---- register-file storage seam (SoA flip, docs/design/09) --------------
    // Every per-slot read/write of the register stack goes through these
    // accessors (absolute index) or a `RegWindow` (frame-relative). Phase 2: the
    // backing is struct-of-arrays (`tags` + `payloads`); these gather/scatter the
    // two lanes with raw payload bits (no recanonicalization). `inline`, so the
    // cold consumers compile to the same two natural-stride loads/stores.

    /// Read the register at absolute stack index `i` (gather both lanes).
    pub inline fn regGet(self: *const Vm, i: usize) Value {
        return .{ .tag = @enumFromInt(self.tags[i]), .payload = .{ .bits = self.payloads[i] } };
    }

    /// Write the register at absolute stack index `i` (scatter both lanes; raw
    /// payload bits).
    pub inline fn regSet(self: *Vm, i: usize, v: Value) void {
        self.tags[i] = @intFromEnum(v.tag);
        self.payloads[i] = v.payload.bits;
    }

    /// Total register slots the stack can hold. Used by the structural bounds
    /// checks (`base + nreg > capacity` → StackOverflow).
    pub inline fn regCapacity(self: *const Vm) usize {
        return self.payloads.len;
    }

    /// Nil-fill `count` registers starting at absolute index `from` — set the tag
    /// lane to nil and zero the payload lane (mirrors `Value.nil()` exactly so a
    /// gathered slot is byte-identical to the AoS layout).
    pub inline fn fillNil(self: *Vm, from: usize, count: usize) void {
        @memset(self.tags[from .. from + count], @intFromEnum(value.Tag.nil));
        @memset(self.payloads[from .. from + count], 0);
    }

    /// A frame-relative window over `count` registers based at absolute `base`
    /// (`R[slot]` == register `base + slot`). The per-frame consumers (the hot
    /// tier-0 arms, the trace recorder, `irinterp`) take one of these.
    pub inline fn frameWindow(self: *Vm, base: usize, count: usize) RegWindow {
        return RegWindow.of(self.tags[base .. base + count], self.payloads[base .. base + count]);
    }

    // ---- native / callValue boundary scratch --------------------------------
    // The native ABI (`NativeFn`/`NativeMultiFn`/`callValue`) speaks contiguous
    // `[]Value` slices, which the SoA register file cannot view directly. These
    // materialize the slice into `boundary_scratch` (absolute-indexed like the
    // register file) — gather operands in before the call, scatter results back
    // after. Cold (a native call is a trace barrier), so the per-element copy is
    // off the path SoA exists to speed up.

    /// Gather registers `[lo, hi)` into `boundary_scratch` and return that slice
    /// as a contiguous `[]Value` (read-only operand view for a native).
    inline fn gatherScratch(self: *Vm, lo: usize, hi: usize) []Value {
        var i = lo;
        while (i < hi) : (i += 1) self.boundary_scratch[i] = self.regGet(i);
        return self.boundary_scratch[lo..hi];
    }

    /// A writable `boundary_scratch` slice `[lo, hi)` for a native's result `out`
    /// (write-only; the contents are undefined until the native fills them).
    inline fn scratchOut(self: *Vm, lo: usize, hi: usize) []Value {
        return self.boundary_scratch[lo..hi];
    }

    /// Scatter `boundary_scratch[lo, hi)` back into the register file after a
    /// native wrote its results there.
    inline fn scatterScratch(self: *Vm, lo: usize, hi: usize) void {
        var i = lo;
        while (i < hi) : (i += 1) self.regSet(i, self.boundary_scratch[i]);
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
        // `_G` — the global environment exposed as a global referencing *itself*
        // (Lua's reflective handle: `_G[name]`, `_G.x = v`, `pairs(_G)`). The
        // globals table is an ordinary heap table (id 0), so this is just one more
        // entry whose value is a `HeapRef` back to that same table. The
        // self-referential edge serializes as `HeapRef{id=0}` and round-trips
        // through the two-pass keyframe restore like any other table edge (capture
        // stores ids, never recurses into the referent — no cycle hazard).
        try self.globals.set(self.gpa, try self.heap.internValue("_G"), Value.heap(&self.globals.header));
        // The module system's runtime tables (`package.loaded`/`preload`/`path`/
        // `searchers`/…). Runs after the `defineNative` loop, which has created the
        // `package` table (via the `searchpath` registry entry) and the `require`
        // global. Pure heap tables/strings/natives off `globals` → captured/restored
        // by the keyframe path; the searcher natives rebind by name (manual entries).
        try stdpackage.installPackageRuntime(self);
    }

    fn defineNative(self: *Vm, bn: BaseNative) Error!void {
        // `manual` natives have no install slot — they exist in `base_natives` only
        // so the keyframe restorer can rebind them by name (e.g. the default
        // `package.searchers`, which `installPackageRuntime` places into an array).
        if (bn.manual) return;
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
        // S-B: command-line arguments are host text and must be valid UTF-8 before
        // they enter the string heap, so the `arg[]` table (and its keyframe) holds
        // only valid UTF-8. Validate *all* args first so a malformed later arg leaves
        // the table untouched rather than half-filled — population is atomic.
        // Load-time (no Lua frame) → level 0, message verbatim.
        for (argv) |a| {
            if (!std.unicode.utf8ValidateSlice(a))
                return self.raiseLocatedError("command-line argument is not valid UTF-8", 0);
        }
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
    /// `pub` so `stdlib/package.zig`'s `installPackageRuntime` can populate the
    /// `package` table after the registry install loop.
    pub fn getOrCreateModuleTable(self: *Vm, name: []const u8) Error!*table.Table {
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
    /// Seed `next_proto_id` from the static chunk's proto tree so runtime-`load`ed
    /// protos receive globally-unique ids. Ids are assigned pre-order from 0, so
    /// the count of protos equals (max id + 1). Idempotent-ish: takes the max of
    /// the current counter and the tree's count, so calling it on the main chunk
    /// after loads have already bumped the counter never lowers it.
    pub fn seedProtoIds(self: *Vm, proto: *const Proto) void {
        const count = countProtos(proto);
        if (count > self.next_proto_id) self.next_proto_id = count;
    }

    fn countProtos(proto: *const Proto) u32 {
        var n: u32 = 1;
        for (proto.protos) |child| n += countProtos(child);
        return n;
    }

    pub fn run(self: *Vm, proto: *const Proto) Error!Value {
        self.seedProtoIds(proto);
        if (proto.num_registers > self.regCapacity()) return Error.StackOverflow;
        self.fillNil(0, proto.num_registers);
        // The main chunk runs as a closure with no upvalues. It is GC-linked and
        // freed at `deinit`; its `proto` pointer is only dereferenced during this
        // call, so a stack-local test `Proto` is fine.
        const top = try self.heap.newClosure(proto, 0);
        try self.pushFrame(top, 0, 0, 0);
        // `run` never arms `suspend_ctl`, so `exec` always finishes here.
        switch (try self.exec()) {
            .finished => |fr| return if (fr.count >= 1) self.regGet(fr.reg) else Value.nil(),
            .suspended => unreachable,
        }
    }

    /// Like `run`, but returns the raw `ExecOutcome` so a caller that armed
    /// `suspend_ctl` can observe a mid-execution `.suspended`. Sets up the main
    /// chunk's frame exactly as `run` does. Resume after a `.suspended` by
    /// calling `exec()` again (the cursor is parked in `frames[depth-1]`).
    pub fn start(self: *Vm, proto: *const Proto) Error!ExecOutcome {
        self.seedProtoIds(proto);
        if (proto.num_registers > self.regCapacity()) return Error.StackOverflow;
        self.fillNil(0, proto.num_registers);
        const top = try self.heap.newClosure(proto, 0);
        try self.pushFrame(top, 0, 0, 0);
        return self.exec();
    }

    /// Locate the call site `level` frames up from the top of the live stack.
    /// `level == 1` is the topmost frame — its live pc is the in-flight call/fault
    /// (a native runs inline, so when it faults the topmost frame is its caller and
    /// that pc is the `.call`). Deeper levels are *parent* frames whose pc is the
    /// resume cursor (one past their outgoing call), so the call-site instruction is
    /// `pc -| 1` — the same leaf-vs-parent rule as `backtraceFrames`. Returns
    /// `null` for `level == 0`, `level > depth` (past the stack — Lua suppresses
    /// the location prefix in that case), or an empty stack.
    pub fn callSiteAt(self: *Vm, level: usize) ?CallSite {
        if (self.depth == 0 or level == 0 or level > self.depth) return null;
        const idx = self.depth - level;
        const f = &self.frames[idx];
        const proto = f.closure.proto;
        const is_top = idx == self.depth - 1;
        const pc: usize = if (is_top) f.pc else f.pc -| 1;
        const span: bytecode.Span = if (pc < proto.spans.len) proto.spans[pc] else .{};
        // Resolve the line against the proto's *own* source when it has one (a
        // runtime-`load`ed chunk), falling back to the VM's main source for
        // statically-compiled / hand-built protos. Without this, errors raised
        // inside loaded code would report line numbers against the main chunk.
        const src = if (proto.source.len > 0) proto.source else self.source;
        return .{
            .proto = proto,
            .base = f.base,
            .pc = pc,
            .span = span,
            .line = compiler.lineFromOffset(src, span.start),
        };
    }

    /// The display name for a native in an error message: the field part of its
    /// registered name (`string.sub` → `sub`), matching how Lua names the called
    /// function. A top-level native (`print`) has no module prefix and passes through.
    fn nativeDisplayName(nat: *const function.Native) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, nat.name, '.')) |dot| return nat.name[dot + 1 ..];
        return nat.name;
    }

    /// Render an error *value* (the `pending_error` of a raised `LuaError`) to text,
    /// Lua-style: a string is its own bytes, a number its decimal text (both via
    /// `coerceConcat`), and anything else becomes `(error object is a <type> value)`.
    /// `arena` owns the result.
    pub fn renderErrorValue(ev: Value, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        var nbuf: [64]u8 = undefined;
        if (coerceConcat(ev, &nbuf)) |bytes| {
            return arena.dupe(u8, bytes);
        } else |_| {
            return std.fmt.allocPrint(arena, "(error object is a {s} value)", .{ev.typeName()});
        }
    }

    /// The native at the current call site (the `.call` that invoked the running
    /// native), plus its caller's chunk name and the call line — everything a
    /// "bad argument" message needs, all recovered from live state so the caller
    /// passes none of it. `null` only if there is no resolvable native call site.
    const NativeSite = struct { fname: []const u8, chunk: []const u8, line: u32 };
    fn nativeSite(self: *Vm) ?NativeSite {
        const cs = self.callSiteAt(1) orelse return null;
        if (cs.pc >= cs.proto.code.len) return null;
        const instr = cs.proto.code[cs.pc];
        if (instr.op != .call) return null;
        const callee = self.regGet(cs.base + instr.a);
        if (!(callee.isHeap() and callee.heapType() == .native)) return null;
        return .{
            .fname = nativeDisplayName(function.Native.fromHeader(callee.asHeap())),
            .chunk = cs.proto.name,
            .line = cs.line,
        };
    }

    /// Intern `body` (already a complete "bad argument …" clause) as the in-flight
    /// error value, prefixed with the `chunk:line:` of the call site when one is
    /// resolvable, and return the unwinding signal. Shared tail of `badArg`/
    /// `badArgReason` so their location handling can't drift. Deterministic: reads
    /// only the call site and interns an id-stable string.
    fn raiseBadArg(self: *Vm, site: ?NativeSite, body: []const u8) Error {
        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();
        const full = if (site) |s|
            try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ s.chunk, s.line, body })
        else
            body;
        self.pending_error = try self.heap.internValue(full);
        return Error.LuaError;
    }

    /// Raise Lua's canonical type-mismatch argument error from inside a native:
    /// `"<chunk:line>: bad argument #<n> to '<fname>' (<expected> expected, got
    /// <type|no value>)"`. `got == null` ⇒ the argument was absent ("no value").
    /// Name + location come from the live call site (`nativeSite`); the caller
    /// supplies only the 1-based index, the expected type, and the offending value.
    pub fn badArg(self: *Vm, n: usize, expected: []const u8, got: ?Value) Error {
        const site = self.nativeSite();
        const fname = if (site) |s| s.fname else "?";
        const got_name = if (got) |g| g.typeName() else "no value";
        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const body = try std.fmt.allocPrint(
            arena_inst.allocator(),
            "bad argument #{d} to '{s}' ({s} expected, got {s})",
            .{ n, fname, expected, got_name },
        );
        return self.raiseBadArg(site, body);
    }

    /// Like `badArg`, but with a free-text reason inside the parentheses (e.g.
    /// "number has no integer representation", "index out of range", "value
    /// expected") instead of the "X expected, got Y" form.
    pub fn badArgReason(self: *Vm, n: usize, reason: []const u8) Error {
        const site = self.nativeSite();
        const fname = if (site) |s| s.fname else "?";
        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const body = try std.fmt.allocPrint(
            arena_inst.allocator(),
            "bad argument #{d} to '{s}' ({s})",
            .{ n, fname, reason },
        );
        return self.raiseBadArg(site, body);
    }

    /// Raise `bytes` as the in-flight error value, prepending the `chunk:line:`
    /// location of the call site `level` frames up (Lua's `error(msg, level)`
    /// semantics: `level == 1` is the function that called `error`, `level == 2`
    /// its caller, …). `level == 0` — or no resolvable call site — stores `bytes`
    /// verbatim. Shared with `error()` so the location logic matches `badArg`'s.
    /// Deterministic: reads only the call site and interns an id-stable string.
    pub fn raiseLocatedError(self: *Vm, bytes: []const u8, level: usize) Error {
        const cs = if (level == 0) null else self.callSiteAt(level);
        if (cs) |site| {
            var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_inst.deinit();
            const full = try std.fmt.allocPrint(
                arena_inst.allocator(),
                "{s}:{d}: {s}",
                .{ site.proto.name, site.line, bytes },
            );
            self.pending_error = try self.heap.internValue(full);
        } else {
            self.pending_error = try self.heap.internValue(bytes);
        }
        return Error.LuaError;
    }

    /// S-B (design doc 06): every program-visible string is valid UTF-8. Host
    /// inputs (`getenv`/`argv`/`file_read`/the `arg[]` table) can supply arbitrary
    /// bytes, so the host-input boundary validates here and raises a *catchable*
    /// error on malformed input — mirroring `string.decode`. Determinism: a pure
    /// function of the bytes, and (for the recorded `getenv`/`argv` effects) called
    /// on the *logged* result, so `record` (fresh intern) and `replay` (re-intern
    /// from the log) validate the identical bytes and raise identically. The error
    /// message embeds no raw bytes (which would itself be a malformed string).
    fn validateHostText(self: *Vm, v: Value) Error!void {
        if (!v.isHeap() or v.heapType() != .string) return; // nil / non-string: nothing to check
        const s = string.String.fromHeader(v.asHeap()).bytes();
        if (!std.unicode.utf8ValidateSlice(s))
            return self.raiseLocatedError("host input is not valid UTF-8", 1);
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

        // A raised Lua value (`error`/`assert`/`badArg`): the value *is* the
        // message, already self-located, so the reporter must not append a second
        // location. The leaf frame is the raiser's caller — `callSiteAt(1)` gives
        // its line for the traceback header.
        if (err == Error.LuaError) {
            const message = if (self.pending_error) |ev|
                try renderErrorValue(ev, arena)
            else
                try arena.dupe(u8, "error");
            const cs = self.callSiteAt(1);
            return .{
                .message = message,
                .line = if (cs) |c| c.line else 0,
                .start = if (cs) |c| c.span.start else 0,
                .end = if (cs) |c| c.span.end else 0,
                .frames = try self.backtraceFrames(source, arena),
                .self_located = true,
            };
        }

        const frame = &self.frames[self.depth - 1];
        const proto = frame.closure.proto;
        const pc = frame.pc;
        if (pc >= proto.code.len) return .{ .message = try arena.dupe(u8, @errorName(err)) };

        const instr = proto.code[pc];
        const regs = self.frameWindow(frame.base, proto.num_registers);
        const span: bytecode.Span = if (pc < proto.spans.len) proto.spans[pc] else .{};
        // Per-proto source so a fault inside a `load`ed chunk reports its own line.
        const leaf_src = if (proto.source.len > 0) proto.source else source;
        const line = compiler.lineFromOffset(leaf_src, span.start);

        const message: []const u8 = switch (err) {
            Error.StackOverflow => try arena.dupe(u8, "stack overflow"),
            Error.DivisionByZero => try arena.dupe(u8, "attempt to perform integer division or modulo by zero"),
            Error.MetatableChainLoop => try arena.dupe(u8, "'__index' chain too long; possible loop"),
            else => switch (instr.op) {
                .add, .sub, .mul, .div, .idiv, .mod, .pow => try std.fmt.allocPrint(
                    arena,
                    "attempt to perform arithmetic on a {s} value",
                    .{firstNonNumber(regs.get(instr.b), regs.get(instr.c)).typeName()},
                ),
                // Bitwise ops want an integer operand: a float (no integer form)
                // and a non-number get distinct Lua-5.4-shaped messages.
                .band, .bor, .bxor, .shl, .shr => try bitwiseFaultMessage(arena, firstNonInteger(regs.get(instr.b), regs.get(instr.c))),
                .neg => try std.fmt.allocPrint(arena, "attempt to perform arithmetic on a {s} value", .{regs.get(instr.b).typeName()}),
                .bnot => try bitwiseFaultMessage(arena, regs.get(instr.b)),
                .len => try std.fmt.allocPrint(arena, "attempt to get length of a {s} value", .{regs.get(instr.b).typeName()}),
                .concat => try std.fmt.allocPrint(arena, "attempt to concatenate a {s} value", .{firstNonConcatable(regs.get(instr.b), regs.get(instr.c)).typeName()}),
                .lt, .le, .gt, .ge => try std.fmt.allocPrint(arena, "attempt to compare {s} with {s}", .{ regs.get(instr.b).typeName(), regs.get(instr.c).typeName() }),
                .get_index => try std.fmt.allocPrint(arena, "attempt to index a {s} value", .{regs.get(instr.b).typeName()}),
                .set_index => try std.fmt.allocPrint(arena, "attempt to index a {s} value", .{regs.get(instr.a).typeName()}),
                .call => blk: {
                    // A native runs inline (no child frame), so when one returns a
                    // bare fault the leaf instruction is the `.call` to it — the
                    // callee is perfectly callable. Name it generically instead of
                    // the misleading "attempt to call". Detailed per-argument
                    // messages come from `Vm.badArg` (which raises `LuaError`, so it
                    // never reaches this non-LuaError arm). A genuine non-callable
                    // (nil/number/…) keeps the real "attempt to call a X value".
                    const callee = regs.get(instr.a);
                    if (callee.isHeap() and callee.heapType() == .native and err == Error.TypeError)
                        break :blk try std.fmt.allocPrint(arena, "bad argument to '{s}'", .{nativeDisplayName(function.Native.fromHeader(callee.asHeap()))});
                    if (callee.isHeap() and (callee.heapType() == .native or callee.heapType() == .function))
                        break :blk try arena.dupe(u8, @errorName(err));
                    break :blk try std.fmt.allocPrint(arena, "attempt to call a {s} value", .{callee.typeName()});
                },
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
            // Per-proto source (a `load`ed chunk reports its own lines), falling
            // back to the passed source for statically-compiled protos.
            const fsrc = if (fp.source.len > 0) fp.source else source;
            frames[self.depth - 1 - i] = .{
                .name = fp.name,
                .line = compiler.lineFromOffset(fsrc, fspan.start),
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
        if (base + nreg > self.regCapacity()) return Error.StackOverflow;
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

    /// Call a lune callable from native (host) code, run it to completion, write up
    /// to `results_out.len` results into `results_out`, and return the count
    /// actually written. `callee` must be a closure or native `Value` (else
    /// `TypeError`). This is the keystone reentrancy primitive: a native that holds
    /// `*Vm` via its ctx (`pcall`/`xpcall`, the `table.sort` comparator, `gsub`
    /// function-replacement) drives a lune function and gets its results back.
    ///
    /// It runs a **depth-bounded** nested dispatch (`execWith(entry_depth + 1)`)
    /// that returns the instant the nested top frame returns. It mutates only
    /// `self.{frames[entry_depth..], depth, stack_top, native_reentry_depth}` — the
    /// outer dispatch loop's hot locals (`frame/base/regs/pc`) live on the Zig
    /// stack of the *outer* `execImpl` and are never touched. On **success** it
    /// restores `stack_top` to the entry value (`depth` is already back via the
    /// bounded `ret`). On **error** it deliberately does NOT unwind — frames are
    /// left live so the catcher (`pcall`) can read them via `describeFault` before
    /// it restores `depth`/`stack_top`. This matches the whole-VM invariant that a
    /// runtime error leaves `self.frames` intact for fault description.
    ///
    /// Preconditions (asserted): no multret pair is pending (`!reg_top_pending`),
    /// and no suspend is armed (`suspend_ctl == null` — a suspend taken across a
    /// native's Zig frame would have no resume cursor). Both hold for the chunk-1
    /// callers; a future host-mediated-suspension chunk revisits the latter.
    ///
    /// GC contract for callers: `results_out` heap values are rooted only while the
    /// caller's own register window / scratch holds them; consume them before the
    /// next allocation without stashing a raw `Value` across a safepoint.
    pub fn callValue(self: *Vm, callee: Value, args: []const Value, results_out: []Value) Error!usize {
        if (!callee.isHeap()) return Error.TypeError;
        std.debug.assert(!self.reg_top_pending);
        std.debug.assert(self.suspend_ctl == null);
        if (self.native_reentry_depth >= max_native_reentry) return Error.StackOverflow;
        self.native_reentry_depth += 1;
        defer self.native_reentry_depth -= 1;

        switch (callee.heapType()) {
            // Native callee: no frame — mirror the `.call` `.native` dispatch arm.
            // Results go straight into `results_out` (a concrete count is always
            // wanted here; the `all_results` stamping path is dispatch-only).
            .native => {
                const nat = function.Native.fromHeader(callee.asHeap());
                if (nat.effect) |kind| {
                    const r = try performEffect(self, kind, nat, args);
                    if (results_out.len == 0) return 0;
                    results_out[0] = r;
                    return 1;
                } else if (nat.multi != null and results_out.len >= 2) {
                    // `out` does not overlap `args`: for a direct call they are the
                    // caller's two distinct buffers; for a `__call` redirect `args`
                    // is the parked window at/above `pbase` while `results_out` is
                    // the original caller's buffer below it. Either way a
                    // strictly-safer case of the NativeMultiFn alias contract.
                    const produced = nat.multi.?(@ptrCast(self), args, results_out) catch |e| return narrowError(e);
                    return @min(produced, results_out.len);
                } else {
                    const r = nat.func(@ptrCast(self), args) catch |e| return narrowError(e);
                    if (results_out.len == 0) return 0;
                    results_out[0] = r;
                    return 1;
                }
            },
            // Closure callee: lay out a fresh window at `stack_top`, bind params
            // exactly like the `.call` arm, push, and run a bounded nested exec.
            .function => {
                const cl = Closure.fromHeader(callee.asHeap());
                const cp = cl.proto;
                const entry_depth = self.depth;
                const saved_top = self.stack_top;
                if (self.depth >= max_call_depth) return Error.StackOverflow;
                // Args land in a fresh region at `arg_base`; the callee window sits
                // directly above them. Surplus varargs stay in the arg region (below
                // `callee_base`), stable and — once `pushFrame` raises `stack_top` —
                // GC-rooted, exactly as the `.call` arm leaves them in the caller's
                // window. Reserve `args.len + num_registers` slots.
                const arg_base = self.stack_top;
                const callee_base = arg_base + args.len;
                if (callee_base + cp.num_registers > self.regCapacity()) return Error.StackOverflow;
                // Straight-line, allocation-free up to `pushFrameVararg` (which
                // raises `stack_top`): no safepoint may intervene, so the args we
                // park above `stack_top` are never seen unrooted by the collector.
                for (args, 0..) |v, i| self.regSet(arg_base + i, v);
                var i: usize = 0;
                while (i < cp.num_registers) : (i += 1) {
                    self.regSet(callee_base + i, if (i < cp.num_params and i < args.len)
                        self.regGet(arg_base + i)
                    else
                        Value.nil());
                }
                const va_count: usize = if (cp.is_vararg and args.len > cp.num_params) args.len - cp.num_params else 0;
                const va_base: usize = if (va_count > 0) arg_base + cp.num_params else 0;
                try self.pushFrameVararg(cl, callee_base, 0, 0, va_base, va_count);

                // No `errdefer` restore: a runtime error must leave `self.frames`
                // live (depth raised) so the catching `pcall` can synthesize the
                // located message before it restores the boundary — the whole-VM
                // "errors don't unwind frames" invariant. Success falls through to
                // the explicit `stack_top` restore below.
                const outcome = try self.execWith(entry_depth + 1);
                const fr = switch (outcome) {
                    .finished => |f| f,
                    // `suspend_ctl == null` (asserted above) ⇒ exec never suspends.
                    .suspended => unreachable,
                };
                // The boundary frame is popped (`depth == entry_depth`) but
                // `stack_top` is still raised over its window, so its result
                // registers are live and rooted. Copy them out before shrinking.
                const src = callee_base + fr.reg;
                const n = @min(@as(usize, fr.count), results_out.len);
                var k: usize = 0;
                while (k < n) : (k += 1) results_out[k] = self.regGet(src + k);
                self.stack_top = saved_top;
                return n;
            },
            // `__call` from a host reentry (`pcall`/`xpcall`/`table.sort`
            // comparator/`gsub` fn): a non-callable heap value with a `__call`
            // metamethod is invoked as `handler(value, args...)`, identically to
            // the bytecode `.call` arm — both redirect through `callValue`, so a
            // callable table is callable from *every* site, not just bytecode.
            // We park `[callee, args...]` contiguously at `stack_top` and raise
            // `stack_top` over it so the collector roots the redirect args, then
            // recurse. The recursion chains a deeper `__call` naturally, bounded
            // by `native_reentry_depth` (a `__call` cycle surfaces as a catchable
            // StackOverflow, never a hang). On success we shrink back; on error
            // we leave `stack_top` raised — the catcher (`protectedCall`) restores
            // its own captured boundary, which subsumes this region, and reads the
            // still-live faulting frames for `describeFault` first.
            else => {
                const handler = self.metamethod(callee, self.mm.call);
                if (handler.isNil()) return Error.TypeError;
                const need = 1 + args.len;
                const pbase = self.stack_top;
                if (pbase + need > self.regCapacity()) return Error.StackOverflow;
                self.regSet(pbase, callee);
                for (args, 0..) |v, i| self.regSet(pbase + 1 + i, v);
                self.stack_top = pbase + need; // root the parked redirect args
                const n = try self.callValue(handler, self.gatherScratch(pbase, pbase + need), results_out);
                self.stack_top = pbase; // success only (see note above)
                return n;
            },
        }
    }

    /// Turn a runtime fault (a non-`LuaError` Error raised with no `pending_error`)
    /// into the interned message string that becomes the caught error value. Reuses
    /// `describeFault`'s located-message synthesis against the **still-live**
    /// faulting frames — so it MUST run before the catcher restores `depth`. Reads
    /// only deterministic state (opcodes, operand types, source spans), so the same
    /// fault yields the same value bytes across all tiers and record/replay.
    pub fn synthErrorValue(self: *Vm, e: Error) Error!Value {
        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();
        const fault = try self.describeFault(self.source, e, a);
        // A raised value (`error`/`assert`/`badArg`) already carries its own
        // `chunk:line:`; intern it verbatim. A bare runtime fault (`nil + 1`,
        // indexing nil, a native's generic bad-argument) is reported by Lua with a
        // `chunk:line:` prefix on the *caught* value too — prepend it from the leaf
        // frame's chunk (its proto name) and the fault line. Deterministic: proto
        // name is static and the line derives from a source offset.
        if (fault.self_located or fault.line == 0 or self.depth == 0)
            return self.heap.internValue(fault.message);
        const chunk = self.frames[self.depth - 1].closure.proto.name;
        const full = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ chunk, fault.line, fault.message });
        return self.heap.internValue(full);
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
        {
            var i: usize = 0;
            while (i < self.stack_top) : (i += 1) {
                const v = self.regGet(i);
                if (v.isHeap()) cb(ctx, v.asHeap());
            }
        }
        for (self.frames[0..self.depth]) |f| cb(ctx, @constCast(&f.closure.header));
        for (self.open_upvalues.items) |ou| cb(ctx, &ou.cell.header);
        for (self.trace.cache.items) |t| {
            for (t.consts) |v| if (v.isHeap()) cb(ctx, v.asHeap());
        }
        if (self.trace.isRecording()) {
            for (self.trace.rec.consts.items) |v| if (v.isHeap()) cb(ctx, v.asHeap());
        }
        for (self.effect_log.items) |e| if (e.result.isHeap()) cb(ctx, e.result.asHeap());
        // 7. the in-flight Lua error value — rooted while parked between a raise and
        //    its catch. Load-bearing for the `xpcall` handler path, which allocates
        //    (and so may collect) while the error value waits to be handed over.
        if (self.pending_error) |ev| if (ev.isHeap()) cb(ctx, ev.asHeap());
        // 8. metamethod-dispatch roots: every interned metamethod-name string and
        //    the shared string metatable. Referenced from the VM (not `globals`),
        //    so they must be marked explicitly or a collection mid-dispatch would
        //    sweep them. All `nil`/`null` in a bare VM, so the guards skip them.
        inline for (@typeInfo(MetamethodNames).@"struct".field_names) |name| {
            const v = @field(self.mm, name);
            if (v.isHeap()) cb(ctx, v.asHeap());
        }
        if (self.string_metatable) |smt| cb(ctx, &smt.header);
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
        return self.execWith(1);
    }

    /// `exec`, bounded by a stop depth. The dispatch loop returns `.finished` the
    /// instant a `.ret`/`.halt` pops the frame at `stop_depth` (the top-level main
    /// frame for `stop_depth == 1`; a reentrant `callValue`'s nested top frame for
    /// `stop_depth == entry_depth + 1`). Threads `stop_depth` through the
    /// `switch_mode` re-entry so a mode flip mid-nested-run resumes the same bound.
    fn execWith(self: *Vm, stop_depth: u32) Error!ExecOutcome {
        while (true) {
            const step = if (self.runFastPath())
                try self.execImpl(.fast, stop_depth)
            else
                try self.execImpl(.full, stop_depth);
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

    fn execImpl(self: *Vm, comptime mode: ExecMode, stop_depth: u32) Error!ExecStep {
        // Hot top-frame state, reloaded from `frames[depth-1]` after every push/pop.
        var frame: *CallFrame = &self.frames[self.depth - 1];
        var closure = frame.closure;
        var proto = closure.proto;
        var code = proto.code;
        var base = frame.base;
        var regs = self.frameWindow(base, proto.num_registers);
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
                // Per-proto source so a safepoint inside a `load`ed chunk maps to
                // its own line (deterministic: a pure function of proto + source).
                const sp_src = if (proto.source.len > 0) proto.source else self.source;
                const sp_line: u32 = if (pc < proto.spans.len)
                    compiler.lineFromOffset(sp_src, proto.spans[pc].start)
                else
                    0;
                try self.safepoint_lines.append(self.gpa, sp_line);
            }
            if (mode == .full) {
                if (self.suspend_ctl) |sc| {
                    // Never suspend mid-multret (see the GC note above): `reg_top` is
                    // transient and unserialized, so a snapshot here could not resume.
                    if (!self.reg_top_pending and self.safepoint_seq >= sc.after_safepoints and self.depth >= sc.min_depth) {
                        // `pending_error` is transient and unserialized, like
                        // `reg_top`: a snapshot mid-unwind could not resume. Error
                        // propagation never reaches a safepoint (it returns straight
                        // out via `try`), so it is always null here.
                        std.debug.assert(self.pending_error == null);
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
                // ---- loads & moves ---- (direct lane writes; no `Value` built)
                .load_nil => regs.setNil(a),
                .load_bool => regs.setBool(a, instr.b != 0),
                .load_int => regs.setInt(a, instr.aux),
                .load_const => regs.set(a, proto.constants[instr.b]),
                .move => regs.copy(a, instr.b),

                // ---- arithmetic (semantics live in arith.zig) ----
                // The hot both-int / both-float cases compute on the raw payload
                // lanes directly (no 16-byte `Value` materialized — the SoA win);
                // every other operand mix falls back to the exact `arith.*` +
                // `arithMeta` path (mixed promotion, `__add`/… metamethod, or a
                // propagated error like `DivisionByZero`). Numbers carry no
                // metatable, so the common path never touches dispatch.
                .add => try self.binNum(regs, a, instr.b, instr.c, .add, self.mm.add),
                .sub => try self.binNum(regs, a, instr.b, instr.c, .sub, self.mm.sub),
                .mul => try self.binNum(regs, a, instr.b, instr.c, .mul, self.mm.mul),
                .div => {
                    const tb = regs.tagAt(instr.b);
                    const tc = regs.tagAt(instr.c);
                    if (tb == .float and tc == .float) {
                        @setFloatMode(.strict);
                        regs.setFloat(a, @as(f64, @bitCast(regs.bitsAt(instr.b))) / @as(f64, @bitCast(regs.bitsAt(instr.c))));
                    } else {
                        const lhs = regs.get(instr.b);
                        const rhs = regs.get(instr.c);
                        regs.set(a, try self.arithMeta(arith.div(lhs, rhs), self.mm.div, lhs, rhs));
                    }
                },
                .idiv => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.floorDiv(lhs, rhs), self.mm.idiv, lhs, rhs));
                },
                .mod => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.mod(lhs, rhs), self.mm.mod, lhs, rhs));
                },
                .pow => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.pow(lhs, rhs), self.mm.pow, lhs, rhs));
                },

                // ---- bitwise ---- (both-int fast lane; else `arith.*` + meta)
                .band => try self.binBit(regs, a, instr.b, instr.c, .band, self.mm.band),
                .bor => try self.binBit(regs, a, instr.b, instr.c, .bor, self.mm.bor),
                .bxor => try self.binBit(regs, a, instr.b, instr.c, .bxor, self.mm.bxor),
                .shl => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.shl(lhs, rhs), self.mm.shl, lhs, rhs));
                },
                .shr => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.shr(lhs, rhs), self.mm.shr, lhs, rhs));
                },

                // ---- unary ----
                .neg => {
                    switch (regs.tagAt(instr.b)) {
                        .int => regs.setInt(a, 0 -% @as(i64, @bitCast(regs.bitsAt(instr.b)))),
                        .float => {
                            @setFloatMode(.strict);
                            regs.setFloat(a, -@as(f64, @bitCast(regs.bitsAt(instr.b))));
                        },
                        else => {
                            const v = regs.get(instr.b);
                            regs.set(a, try self.unArithMeta(arith.neg(v), self.mm.unm, v));
                        },
                    }
                },
                .not => regs.setBool(a, !regs.get(instr.b).isTruthy()),
                .bnot => {
                    const v = regs.get(instr.b);
                    regs.set(a, try self.unArithMeta(arith.bnot(v), self.mm.bnot, v));
                },
                // `#t` honours `__len` for tables; strings/raw-length fall through.
                .len => regs.set(a, try self.lenValue(regs.get(instr.b))),

                // ---- concat ---- `__concat` on `TypeError` (a non-concatable
                // operand); the located fault is preserved when neither has one.
                .concat => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, self.concat(lhs, rhs) catch |e| switch (e) {
                        Error.TypeError => try self.binMeta(self.mm.concat, lhs, rhs, Error.TypeError),
                        else => return e,
                    });
                },

                // ---- comparisons → boolean register ----
                // `gt`/`ge` reuse `lt`/`le` with operands swapped (a>b ≡ b<a).
                // `eq`/`ne` consult `__eq` only for two raw-unequal tables;
                // `lt`/`le` consult `__lt`/`__le` when not raw-comparable.
                .eq => regs.setBool(a, try self.valuesEqual(regs.get(instr.b), regs.get(instr.c))),
                .ne => regs.setBool(a, !try self.valuesEqual(regs.get(instr.b), regs.get(instr.c))),
                .lt => regs.setBool(a, try self.compareMeta(.lt, regs.get(instr.b), regs.get(instr.c))),
                .le => regs.setBool(a, try self.compareMeta(.le, regs.get(instr.b), regs.get(instr.c))),
                .gt => regs.setBool(a, try self.compareMeta(.lt, regs.get(instr.c), regs.get(instr.b))),
                .ge => regs.setBool(a, try self.compareMeta(.le, regs.get(instr.c), regs.get(instr.b))),

                // ---- control flow ----
                .jmp => pc = applyJump(pc, instr.aux),
                .jmp_if_false => if (!regs.get(a).isTruthy()) {
                    pc = applyJump(pc, instr.aux);
                },
                .jmp_if_true => if (regs.get(a).isTruthy()) {
                    pc = applyJump(pc, instr.aux);
                },

                // ---- numeric for ----
                // R[a..a+3) = (idx, limit, step). Validate numbers, pre-subtract
                // step from idx (so the first for_loop re-adds it), then jump to
                // the matching for_loop test.
                .for_prep => {
                    if (!regs.get(a).isNumber() or !regs.get(a + 1).isNumber() or !regs.get(a + 2).isNumber()) {
                        return Error.TypeError;
                    }
                    regs.set(a, try arith.sub(regs.get(a), regs.get(a + 2)));
                    pc = applyJump(pc, instr.aux);
                },
                // idx += step; if still within limit (direction by step sign),
                // publish idx to the loop var R[a+3] and take the back-edge.
                .for_loop => {
                    regs.set(a, try arith.add(regs.get(a), regs.get(a + 2)));
                    const idx = regs.get(a);
                    const limit = regs.get(a + 1);
                    const step = regs.get(a + 2);
                    const ascending = !(try arith.lt(step, Value.int(0)));
                    const within = if (ascending)
                        try arith.le(idx, limit)
                    else
                        try arith.le(limit, idx);
                    if (within) {
                        regs.set(a + 3, idx);
                        pc = applyJump(pc, instr.aux);
                    }
                },
                // generic-for test: the preceding `call` filled R[a+3..] with the
                // iterator's results. Continue iff the first var is non-nil (Lua
                // stops only on nil; `false` continues), publishing it as the next
                // control R[a+2] and taking the back-edge. Else fall through (exit).
                .tfor_loop => {
                    if (!regs.get(a + 3).isNil()) {
                        regs.set(a + 2, regs.get(a + 3));
                        pc = applyJump(pc, instr.aux);
                    }
                },

                // ---- tables ----
                .new_table => {
                    const t = try self.heap.newTable();
                    regs.set(a, Value.heap(&t.header));
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
                    const container = regs.get(instr.b);
                    const key = regs.get(instr.c);
                    regs.set(a, blk: {
                        if (container.isHeap() and container.heapType() == .table and key.isInt()) {
                            const tbl = table.Table.fromHeader(container.asHeap());
                            const i = key.asInt();
                            if (i >= 1 and i <= @as(i64, @intCast(tbl.array.len))) {
                                // A *present* (non-nil) in-bounds slot is a raw read
                                // regardless of any metatable — Lua only consults
                                // `__index` for an absent key. A hole (nil) falls
                                // through to `indexGet`, which checks `__index`.
                                const v = tbl.array.get(@intCast(i));
                                if (!v.isNil()) break :blk v;
                            }
                        }
                        break :blk try self.indexGet(container, key);
                    });
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
                    const container = regs.get(a);
                    const key = regs.get(instr.b);
                    const val = regs.get(instr.c);
                    fast: {
                        if (container.isHeap() and container.heapType() == .table and key.isInt()) {
                            const tbl = table.Table.fromHeader(container.asHeap());
                            const i = key.asInt();
                            if (i >= 1 and i <= @as(i64, @intCast(tbl.array.len)) and tbl.array.fits(val)) {
                                // `__newindex` fires only for an *absent* key on a
                                // metatable-bearing table. A metatable-free table
                                // (the overwhelming common case — one predictable
                                // load) takes the raw store directly; with a
                                // metatable, only a present (non-nil) slot may be
                                // stored raw — a hole routes through `indexSet`.
                                if (tbl.metatable == null or !tbl.array.get(@intCast(i)).isNil()) {
                                    tbl.array.setInLane(@intCast(i), val);
                                    self.heap.writeBarrier(&tbl.header, val); // no-op until Phase 4
                                    break :fast;
                                }
                            }
                        }
                        try self.indexSet(container, key, val);
                    }
                },

                // ---- globals ----
                .get_global => regs.set(a, self.globals.get(proto.constants[instr.b])),
                .set_global => {
                    const v = regs.get(a);
                    try self.globals.set(self.gpa, proto.constants[instr.b], v);
                    self.heap.writeBarrier(&self.globals.header, v); // no-op until Phase 4
                },

                // ---- functions ----
                .closure => {
                    const child = proto.protos[instr.b];
                    const cl = try self.makeClosure(closure, child, base);
                    regs.set(a, Value.heap(&cl.header));
                },
                .get_upval => regs.set(a, self.upvalGet(closure.upvalues[instr.b])),
                .set_upval => {
                    const v = regs.get(a);
                    self.upvalSet(closure.upvalues[instr.b], v);
                    self.heap.writeBarrier(&closure.upvalues[instr.b].header, v); // no-op until generational
                },
                .close_upvalues => self.closeUpvaluesFrom(base + a),

                // ---- calls ---- a Lua call pushes a frame and reloads onto it; a
                // native runs inline (no frame) as the current frame's top activity.
                .call => {
                    const callee = regs.get(a);
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
                            if (callee_base + cp.num_registers > self.regCapacity()) return Error.StackOverflow;
                            // Lay out the callee window: bind fixed params (nil-fill
                            // any not supplied), nil the rest. Straight-line and
                            // allocation-free — these slots sit above the current
                            // `stack_top` until `pushFrame` raises it, so no safepoint
                            // may intervene here (none does).
                            var i: usize = 0;
                            while (i < cp.num_registers) : (i += 1) {
                                self.regSet(callee_base + i, if (i < cp.num_params and i < nargs)
                                    self.regGet(base + a + 1 + i)
                                else
                                    Value.nil());
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
                            regs = self.frameWindow(base, proto.num_registers);
                            pc = frame.pc;
                            continue;
                        },
                        .native => {
                            const nat = function.Native.fromHeader(callee.asHeap());
                            const nwanted: usize = instr.c;
                            // Materialize the args into the absolute-indexed boundary
                            // scratch so the native ABI keeps speaking `[]Value` after
                            // the register file split (SoA). The scratch is laid out at
                            // the same absolute slot indices as the registers, so the
                            // `out`-aliases-`args` overlap multi natives rely on is
                            // preserved exactly; nesting is safe because a deeper call
                            // parks its own args at higher absolute indices.
                            const args = self.gatherScratch(base + a + 1, base + a + 1 + nargs);
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
                                // `out` aliases `args` in scratch (same overlap as the
                                // old stack slices); the native writes results into
                                // scratch, then we scatter them back into the registers.
                                const out = if (all) self.scratchOut(base + a, self.regCapacity()) else self.scratchOut(base + a, base + a + nwanted);
                                const produced = nat.multi.?(@ptrCast(self), args, out) catch |e| return narrowError(e);
                                if (all) {
                                    std.debug.assert(!self.reg_top_pending);
                                    self.scatterScratch(base + a, base + a + produced);
                                    self.reg_top = base + a + produced;
                                    self.reg_top_pending = true;
                                } else {
                                    var k: usize = produced;
                                    while (k < nwanted) : (k += 1) out[k] = Value.nil();
                                    self.scatterScratch(base + a, base + a + nwanted);
                                }
                            } else {
                                const result = nat.func(@ptrCast(self), args) catch |e| return narrowError(e);
                                if (all) self.stampSingleResult(base, a, result) else writeSingleResult(regs, a, nwanted, result);
                            }
                        },
                        // `__call`: a non-callable heap value (typically a table)
                        // with a `__call` metamethod is invoked as
                        // `handler(value, args...)`. The arguments already sit
                        // contiguously as `[callee, args...]` at `stack[base+a..]`
                        // — exactly the handler's argument list, so no copy is
                        // needed; `callValue` reads it before writing results.
                        // Results honour `nwanted`/`all_results` like the native
                        // arm. A nil/non-heap callee, or a callee whose `__call`
                        // chain bottoms out in a non-callable, stays the located
                        // "attempt to call a <type> value" fault. A `__call` whose
                        // handler is itself a `__call` table chains through
                        // `callValue` (bounded by `native_reentry_depth`; a cycle
                        // surfaces as a catchable StackOverflow, never a hang).
                        else => {
                            const handler = self.metamethod(callee, self.mm.call);
                            if (handler.isNil()) return Error.TypeError;
                            const nwanted: usize = instr.c;
                            // `[callee, args...]` is exactly the handler's argument
                            // list — gather it into the absolute-indexed scratch (the
                            // result `out` aliases it, same overlap as the old stack
                            // slices; `callValue` reads its args before writing out).
                            const call_args = self.gatherScratch(base + a, base + a + 1 + nargs);
                            if (nwanted == bytecode.all_results) {
                                const n = try self.callValue(handler, call_args, self.scratchOut(base + a, self.regCapacity()));
                                std.debug.assert(!self.reg_top_pending);
                                self.scatterScratch(base + a, base + a + n);
                                self.reg_top = base + a + n;
                                self.reg_top_pending = true;
                            } else {
                                const out = self.scratchOut(base + a, base + a + nwanted);
                                const n = try self.callValue(handler, call_args, out);
                                var k: usize = n;
                                while (k < nwanted) : (k += 1) out[k] = Value.nil();
                                self.scatterScratch(base + a, base + a + nwanted);
                            }
                        },
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
                    if (self.depth == stop_depth) {
                        // Pop the boundary frame. For the top level (stop_depth == 1)
                        // this nets `depth == 0` exactly as before; for a reentrant
                        // `callValue` (stop_depth == entry_depth + 1) it leaves the
                        // outer frames intact at `depth == entry_depth`. Results stay
                        // in this frame's window (at `base + result.reg`) until the
                        // caller copies them out — `stack_top` is not shrunk here, so
                        // the live-register scan still roots them.
                        self.depth -= 1;
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
                        self.regSet(dst + k, if (k < result.count)
                            self.regGet(src + k)
                        else
                            Value.nil());
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
                    regs = self.frameWindow(base, proto.num_registers);
                    pc = frame.pc;
                    self.stack_top = base + proto.num_registers;
                    continue;
                },

                // ---- varargs ---- read the current frame's `...` cursor. The
                // surplus-arg region lives below `base` (in the caller's window),
                // stable and GC-rooted; these never relocate it.
                .vararg_first => {
                    regs.set(a, if (frame.varargs_count >= 1) self.regGet(frame.varargs_base) else Value.nil());
                },
                .vararg_len => {
                    regs.set(a, Value.int(@intCast(frame.varargs_count)));
                },
                .vararg_get => {
                    // 1-based, bounds-checked; out of range or non-int index → nil.
                    const idx_v = regs.get(instr.b);
                    var out = Value.nil();
                    if (idx_v.isInt()) {
                        const idx = idx_v.asInt();
                        if (idx >= 1 and idx <= @as(i64, @intCast(frame.varargs_count))) {
                            out = self.regGet(frame.varargs_base + @as(usize, @intCast(idx - 1)));
                        }
                    }
                    regs.set(a, out);
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
                    if (dest + count > self.regCapacity()) return Error.StackOverflow;
                    var k: usize = 0;
                    while (k < count) : (k += 1) self.regSet(dest + k, self.regGet(frame.varargs_base + k));
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
                        forRemainingTrips(regs.get(a), regs.get(a + 1), regs.get(a + 2))
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

    /// The metatable governing `v`, or null. A table carries its own
    /// (`Table.metatable`); every string shares the built-in `string_metatable`;
    /// no other value type has one in chunk 2a (numbers/booleans/nil/functions
    /// would need `debug.setmetatable`, which is excluded). The keystone of
    /// metamethod dispatch — every `__index`/`__newindex` (and chunk 2b's arith/
    /// compare metamethods) routes through here.
    pub fn metatableOf(self: *Vm, v: Value) ?*table.Table {
        if (!v.isHeap()) return null;
        return switch (v.heapType()) {
            .table => table.Table.fromHeader(v.asHeap()).metatable,
            .string => self.string_metatable,
            else => null,
        };
    }

    /// Raw-fetch metamethod `name` (an interned `self.mm.*` key) from `v`'s
    /// metatable, or `nil` if `v` has no metatable or the field is absent. Pure
    /// (no dispatch) — the caller decides whether the result is a handler to call,
    /// a table to chain through, or a sentinel.
    fn metamethod(self: *Vm, v: Value, name: Value) Value {
        const mt = self.metatableOf(v) orelse return Value.nil();
        return mt.get(name);
    }

    // ---- chunk 2b: operator metamethod dispatch -----------------------------
    // Every operator metamethod routes through these few helpers, so the
    // dispatch semantics (operand order, handler-call shape, fault fallback)
    // live in one place. A handler call goes through `callValue` (the reentrant
    // primitive) and is therefore a trace barrier — which is exactly why the
    // recorder, whose arith/compare/eq arms abort on any non-number operand,
    // never needs to know these exist.

    /// Call a metamethod `handler` (function, native, or a `__call`-bearing
    /// value) with `args`, returning its first result (or nil). `callValue`
    /// raises `TypeError` only when `handler`'s `__call` chain bottoms out in a
    /// non-callable.
    fn callMeta(self: *Vm, handler: Value, args: []const Value) Error!Value {
        var out: [1]Value = .{Value.nil()};
        const n = try self.callValue(handler, args, &out);
        return if (n >= 1) out[0] else Value.nil();
    }

    /// Binary metamethod dispatch for an operator that faulted on its raw
    /// operands. Tries `a`'s metamethod `name`, then `b`'s; the first found is
    /// called as `handler(a, b)` and its first result returned. If neither has
    /// it, re-raise `fault` (the located arithmetic/concat/compare `TypeError`).
    fn binMeta(self: *Vm, name: Value, a: Value, b: Value, fault: Error) Error!Value {
        var handler = self.metamethod(a, name);
        if (handler.isNil()) handler = self.metamethod(b, name);
        if (handler.isNil()) return fault;
        return self.callMeta(handler, &.{ a, b });
    }

    /// Unary metamethod dispatch (`__unm`/`__bnot`): the handler is called with
    /// the operand twice (`handler(v, v)`), matching Lua's convention.
    fn unMeta(self: *Vm, name: Value, v: Value, fault: Error) Error!Value {
        const handler = self.metamethod(v, name);
        if (handler.isNil()) return fault;
        return self.callMeta(handler, &.{ v, v });
    }

    /// Wrap a raw binary arithmetic/bitwise result: on `TypeError` (an operand
    /// the operator doesn't accept) fall back to the binary metamethod `name`;
    /// any other arith error (e.g. `DivisionByZero`) propagates unchanged.
    /// `R[a] = R[b] <op> R[c]` for add/sub/mul, computing the hot both-int and
    /// both-float cases directly on the raw payload lanes (no `Value` built — the
    /// SoA spill/scale win), and deferring every other operand mix to the exact
    /// `arith.*` + `arithMeta` path. Byte-identical to the AoS arms: the int path
    /// mirrors `Value.int(x +% y)`, the float path mirrors
    /// `Value.float(x + y)` under `@setFloatMode(.strict)`.
    inline fn binNum(self: *Vm, regs: RegWindow, a: usize, b: usize, c: usize, comptime op: enum { add, sub, mul }, name: Value) Error!void {
        const tb = regs.tagAt(b);
        const tc = regs.tagAt(c);
        if (tb == .int and tc == .int) {
            const x: i64 = @bitCast(regs.bitsAt(b));
            const y: i64 = @bitCast(regs.bitsAt(c));
            regs.setInt(a, switch (op) {
                .add => x +% y,
                .sub => x -% y,
                .mul => x *% y,
            });
        } else if (tb == .float and tc == .float) {
            @setFloatMode(.strict);
            const x: f64 = @bitCast(regs.bitsAt(b));
            const y: f64 = @bitCast(regs.bitsAt(c));
            regs.setFloat(a, switch (op) {
                .add => x + y,
                .sub => x - y,
                .mul => x * y,
            });
        } else {
            const lhs = regs.get(b);
            const rhs = regs.get(c);
            const raw = switch (op) {
                .add => arith.add(lhs, rhs),
                .sub => arith.sub(lhs, rhs),
                .mul => arith.mul(lhs, rhs),
            };
            regs.set(a, try self.arithMeta(raw, name, lhs, rhs));
        }
    }

    /// `R[a] = R[b] <op> R[c]` for band/bor/bxor. Bitwise ops require integer
    /// operands, so the only fast lane is both-int (computed directly); anything
    /// else (a float, a non-number) routes through `arith.*` which raises
    /// `TypeError` → `__band`/… metamethod, exactly as the AoS arm did.
    inline fn binBit(self: *Vm, regs: RegWindow, a: usize, b: usize, c: usize, comptime op: enum { band, bor, bxor }, name: Value) Error!void {
        if (regs.tagAt(b) == .int and regs.tagAt(c) == .int) {
            const x: i64 = @bitCast(regs.bitsAt(b));
            const y: i64 = @bitCast(regs.bitsAt(c));
            regs.setInt(a, switch (op) {
                .band => x & y,
                .bor => x | y,
                .bxor => x ^ y,
            });
        } else {
            const lhs = regs.get(b);
            const rhs = regs.get(c);
            const raw = switch (op) {
                .band => arith.band(lhs, rhs),
                .bor => arith.bor(lhs, rhs),
                .bxor => arith.bxor(lhs, rhs),
            };
            regs.set(a, try self.arithMeta(raw, name, lhs, rhs));
        }
    }

    fn arithMeta(self: *Vm, raw: arith.Error!Value, name: Value, a: Value, b: Value) Error!Value {
        return raw catch |e| switch (e) {
            error.TypeError => self.binMeta(name, a, b, Error.TypeError),
            else => |other| other,
        };
    }

    /// Wrap a raw unary arithmetic/bitwise result (`__unm`/`__bnot`).
    fn unArithMeta(self: *Vm, raw: arith.Error!Value, name: Value, v: Value) Error!Value {
        return raw catch |e| switch (e) {
            error.TypeError => self.unMeta(name, v, Error.TypeError),
            else => |other| other,
        };
    }

    /// `a < b` / `a <= b` with `__lt`/`__le` fallback. Raw comparison faults with
    /// `TypeError` exactly when the operands aren't both numbers (or both
    /// strings) — which is when Lua consults the metamethod. The handler's result
    /// is taken for its truthiness.
    fn compareMeta(self: *Vm, comptime op: enum { lt, le }, a: Value, b: Value) Error!bool {
        const raw = switch (op) {
            .lt => arith.lt(a, b),
            .le => arith.le(a, b),
        };
        return raw catch |e| switch (e) {
            error.TypeError => {
                const name = switch (op) {
                    .lt => self.mm.lt,
                    .le => self.mm.le,
                };
                const r = try self.binMeta(name, a, b, Error.TypeError);
                return r.isTruthy();
            },
            else => |other| other,
        };
    }

    /// `a == b` with `__eq` fallback. Raw/primitive equality (`arith.eq`, which
    /// includes table identity) wins first. `__eq` is consulted **only** when
    /// both operands are tables and raw-unequal (Lua restricts it to same-type
    /// table/userdata pairs; lune has only tables). The handler result is taken
    /// for truthiness.
    fn valuesEqual(self: *Vm, a: Value, b: Value) Error!bool {
        if (arith.eq(a, b)) return true;
        if (a.isHeap() and a.heapType() == .table and b.isHeap() and b.heapType() == .table) {
            var handler = self.metamethod(a, self.mm.eq);
            if (handler.isNil()) handler = self.metamethod(b, self.mm.eq);
            if (!handler.isNil()) {
                const r = try self.callMeta(handler, &.{ a, b });
                return r.isTruthy();
            }
        }
        return false;
    }

    /// `#v` with `__len` fallback. A table with a `__len` metamethod calls it
    /// (`handler(t)` → first result); otherwise a table yields its raw border
    /// length and a string its byte length (`lenOf`). A non-table/non-string with
    /// no metamethod faults (`TypeError`, located).
    fn lenValue(self: *Vm, v: Value) Error!Value {
        if (v.isHeap() and v.heapType() == .table) {
            const handler = self.metamethod(v, self.mm.len);
            if (!handler.isNil()) return self.callMeta(handler, &.{v});
        }
        return lenOf(v);
    }

    /// The `__tostring` rendering of `v`, or `null` when `v` has no `__tostring`
    /// (the caller then applies the default rendering). The handler must return a
    /// string — Lua raises "'__tostring' must return a string" otherwise, which
    /// we surface as `TypeError`.
    pub fn metaToString(self: *Vm, v: Value) Error!?Value {
        const handler = self.metamethod(v, self.mm.tostring);
        if (handler.isNil()) return null;
        const r = try self.callMeta(handler, &.{v});
        if (!(r.isHeap() and r.heapType() == .string)) return Error.TypeError;
        return r;
    }

    /// Upper bound on `__index`/`__newindex` table-chain hops before we declare a
    /// loop. Deterministic and generous — real inheritance chains are a handful
    /// deep; this only fires on a (meta)table cycle, which would otherwise hang.
    const max_metatable_chain = 2000;

    /// `container[key]` with `__index` dispatch. A present (non-nil) raw field is
    /// returned directly (metatable irrelevant — Lua only consults `__index` for
    /// an *absent* key). Otherwise:
    ///   - no metatable / no `__index` → a table yields `nil`; a non-indexable
    ///     value faults (`TypeError`, located by `describeFault`).
    ///   - `__index` is a table → repeat the raw-or-meta lookup on it (chained,
    ///     bounded by `max_metatable_chain`).
    ///   - `__index` is any other value (a function, typically) → call it as
    ///     `handler(container, key)` and return its first result.
    fn indexGet(self: *Vm, container: Value, key: Value) Error!Value {
        var cur = container;
        var hops: usize = 0;
        while (true) : (hops += 1) {
            if (hops >= max_metatable_chain) return Error.MetatableChainLoop;
            // Raw read when `cur` is a table; a present field short-circuits.
            if (cur.isHeap() and cur.heapType() == .table) {
                const raw = table.Table.fromHeader(cur.asHeap()).get(key);
                if (!raw.isNil()) return raw;
            }
            const handler = self.metamethod(cur, self.mm.index);
            if (handler.isNil()) {
                // No `__index`: an absent table key is `nil`; a non-table here is
                // the original "attempt to index a <type> value" fault.
                if (cur.isHeap() and cur.heapType() == .table) return Value.nil();
                return Error.TypeError;
            }
            if (handler.isHeap() and handler.heapType() == .table) {
                cur = handler; // chain: look the key up in the `__index` table
                continue;
            }
            // Functional `__index`: `handler(cur, key)` → first result.
            var out: [1]Value = .{Value.nil()};
            const n = try self.callValue(handler, &.{ cur, key }, &out);
            return if (n >= 1) out[0] else Value.nil();
        }
    }

    /// `container[key] = val` with `__newindex` dispatch. A raw-present key is a
    /// raw store (metatable irrelevant — `__newindex` fires only for an *absent*
    /// key). Otherwise:
    ///   - no metatable / no `__newindex` → raw set (creates the key); a
    ///     non-indexable value faults (`TypeError`).
    ///   - `__newindex` is a table → repeat the set on it (chained, bounded).
    ///   - `__newindex` is any other value (a function) → call it as
    ///     `handler(container, key, val)` (no result).
    fn indexSet(self: *Vm, container: Value, key: Value, val: Value) Error!void {
        var cur = container;
        var hops: usize = 0;
        while (true) : (hops += 1) {
            if (hops >= max_metatable_chain) return Error.MetatableChainLoop;
            if (cur.isHeap() and cur.heapType() == .table) {
                const t = table.Table.fromHeader(cur.asHeap());
                // A present (non-nil) raw key bypasses `__newindex`.
                if (!t.get(key).isNil()) {
                    try t.set(self.gpa, key, val);
                    self.heap.writeBarrier(&t.header, val); // no-op until Phase 4
                    return;
                }
                const handler = self.metamethod(cur, self.mm.newindex);
                if (handler.isNil()) {
                    // No `__newindex`: a plain raw store that creates the key.
                    try t.set(self.gpa, key, val);
                    self.heap.writeBarrier(&t.header, val); // no-op until Phase 4
                    return;
                }
                if (handler.isHeap() and handler.heapType() == .table) {
                    cur = handler; // chain the set into the `__newindex` table
                    continue;
                }
                var out: [1]Value = .{Value.nil()};
                _ = try self.callValue(handler, &.{ cur, key, val }, &out);
                return;
            }
            // `cur` is not a table: only a `__newindex` can rescue it.
            const handler = self.metamethod(cur, self.mm.newindex);
            if (handler.isNil()) return Error.TypeError;
            if (handler.isHeap() and handler.heapType() == .table) {
                cur = handler;
                continue;
            }
            var out: [1]Value = .{Value.nil()};
            _ = try self.callValue(handler, &.{ cur, key, val }, &out);
            return;
        }
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
        const cell = try self.heap.newUpvalue(index);
        try self.open_upvalues.append(self.gpa, .{ .index = index, .cell = cell });
        return cell;
    }

    /// Read an upvalue cell's value. Vm-mediated because an *open* cell's value
    /// lives in the live register stack (the cell holds only the slot index).
    pub fn upvalGet(self: *const Vm, uv: *const function.Upvalue) Value {
        return switch (uv.loc) {
            .open => |index| self.regGet(index),
            .closed => |v| v,
        };
    }

    /// Write an upvalue cell's value. Open ⇒ write through to the live stack slot;
    /// closed ⇒ update the owned value.
    pub fn upvalSet(self: *Vm, uv: *function.Upvalue, v: Value) void {
        switch (uv.loc) {
            .open => |index| self.regSet(index, v),
            .closed => uv.loc = .{ .closed = v },
        }
    }

    /// Close (detach) every open upvalue whose slot index is `>= from`: snapshot
    /// the live value into the cell and drop it from the open list. Called when a
    /// scope's registers (or a whole frame) are about to be freed — including the
    /// protected-call error unwind (`stdlib/errors.zig`), which discards the
    /// faulting frames' registers and so must close their upvalues (otherwise an
    /// escaped closure's cell stays open over a slot above the restored
    /// `stack_top`, which the GC root scan no longer covers — a dangling value).
    pub fn closeUpvaluesFrom(self: *Vm, from: usize) void {
        var i = self.open_upvalues.items.len;
        while (i > 0) {
            i -= 1;
            const ou = self.open_upvalues.items[i];
            if (ou.index >= from) {
                // Snapshot the live slot value into the cell (the VM owns the stack).
                ou.cell.closeWith(self.regGet(ou.index));
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
        self.regSet(base + a, result);
        self.reg_top = base + a + 1;
        self.reg_top_pending = true;
    }
};

/// Place a single native result into the caller's window: the value into the
/// first wanted slot, `nil` into the rest. Shared by the effect and pure-single
/// native paths. `nwanted == 0` discards the result (statement-context call).
fn writeSingleResult(regs: RegWindow, a: usize, nwanted: usize, result: Value) void {
    var k: usize = 0;
    while (k < nwanted) : (k += 1) regs.set(a + k, if (k == 0) result else Value.nil());
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
        error.LuaError => Error.LuaError,
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
        // `loadfile`/`dofile` drive the `file_read` effect from inside their
        // native (via `obtainFileRead`), so the missing-source signal narrows here.
        error.FsUnavailable => Error.FsUnavailable,
        error.EffectLogExhausted => Error.EffectLogExhausted,
        error.EffectKindMismatch => Error.EffectKindMismatch,
        // `upper`/`lower` pin the `unicode_version` effect from inside their
        // native, so a replay version mismatch narrows here — and must stay fatal
        // (not fall through to the catchable `HostError`).
        error.UnicodeVersionMismatch => Error.UnicodeVersionMismatch,
        else => Error.HostError,
    };
}

/// Which runtime errors `pcall`/`xpcall` may catch. The allowlist deliberately
/// EXCLUDES the determinism / replay-integrity faults: `OutOfMemory` (catching it
/// would let a program observe heap pressure, which varies with GC timing across
/// modes) and every effect-log error (`EffectLogExhausted`/`EffectKindMismatch`/
/// `*Unavailable`, whose catching would mask a replay divergence). `StackOverflow`
/// IS catchable — it is a deterministic function of call depth (identical across
/// all 8 modes) and Lua reports it as an ordinary catchable error. Exhaustive over
/// `Error` so a newly added tag forces an explicit catchable/not decision here.
pub fn catchable(e: Error) bool {
    return switch (e) {
        Error.LuaError,
        Error.TypeError,
        Error.DivisionByZero,
        Error.StackOverflow,
        Error.HostError,
        Error.Unimplemented,
        Error.MetatableChainLoop,
        => true,
        Error.OutOfMemory,
        Error.EffectLogExhausted,
        Error.EffectKindMismatch,
        Error.ClockUnavailable,
        Error.RandomUnavailable,
        Error.EnvUnavailable,
        Error.FsUnavailable,
        Error.UnicodeVersionMismatch,
        => false,
    };
}

/// For an arithmetic fault on `x op y`, the operand that wasn't a number (the
/// one to blame). Falls back to `x` if both are numbers (shouldn't happen — the
/// op only faults when one isn't).
fn firstNonNumber(x: Value, y: Value) Value {
    return if (!x.isNumber()) x else y;
}

/// The operand a bitwise op couldn't use: the first that is not an integer. A
/// float counts as non-integer here — lune's bitwise ops require integer operands
/// and (deliberately) do not coerce even integral-valued floats.
fn firstNonInteger(x: Value, y: Value) Value {
    return if (!x.isInt()) x else y;
}

/// Message for a bitwise fault, Lua-5.4-shaped: a number operand that isn't an
/// integer "has no integer representation"; anything else is the wrong type for a
/// "bitwise operation". `bad` is the offending operand (`firstNonInteger`).
fn bitwiseFaultMessage(arena: std.mem.Allocator, bad: Value) std.mem.Allocator.Error![]const u8 {
    if (bad.isNumber()) return arena.dupe(u8, "number has no integer representation");
    return std.fmt.allocPrint(arena, "attempt to perform bitwise operation on a {s} value", .{bad.typeName()});
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
    const result = switch (self.effect_mode) {
        .off => nat.func(@ptrCast(self), args) catch |e| return narrowError(e),
        .record => blk: {
            const r = nat.func(@ptrCast(self), args) catch |e| return narrowError(e);
            try logEffect(self, kind, r);
            break :blk r;
        },
        .replay => try nextLoggedEffect(self, kind),
    };
    // S-B: string-producing effects (`getenv`, `argv`) are host text and must be
    // valid UTF-8. Validating *after* logging keeps record/replay in lockstep:
    // both modes hold the identical bytes here and raise (or pass) identically.
    // `clock`/`argc`/`random_seed` return ints → `validateHostText` no-ops.
    try self.validateHostText(result);
    return result;
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

/// Has a `.unicode_version` effect already been consumed earlier this session?
/// Used only on a snapshot-resume: the keyframe carries no "already pinned" flag,
/// so the first `upper`/`lower` after a restore derives it from the re-attached
/// log + cursor instead of re-consuming an effect that was pinned before the cut.
fn versionAlreadyConsumed(self: *Vm) bool {
    const upto = @min(self.effect_cursor, self.effect_log.items.len);
    for (self.effect_log.items[0..upto]) |e| if (e.kind == .unicode_version) return true;
    return false;
}

/// Pin the active Unicode version through the record/replay boundary (S-C). The
/// case tables are a compiled-in constant, but their content churns between
/// Unicode releases, so the version is recorded **once per session** (at the first
/// `string.upper`/`string.lower`) and re-pinned on replay — mirroring the RNG seed
/// (`obtainRandomSeed`). In `off` it is a no-op marker; in `record` it logs the
/// compiled-in packed version; in `replay` it consumes that effect and refuses
/// (`UnicodeVersionMismatch`) if the recording was made under a different version
/// than this binary's table — a silent case-mapping divergence would break replay.
/// Called by `upper`/`lower` (stdlib/string.zig); idempotent after the first call.
///
/// Snapshot interaction: a *replay* resume is correct (the cursor-prefix scan above
/// avoids a double-consume). A *record*-mode resume of a once-per-session pin —
/// snapshotting a live recording and continuing to record — would re-log the pin,
/// exactly as it would re-log the RNG seed; that "resume a live recording" flow is
/// the documented out-of-scope follow-up in TODO.md (it needs the keyframe to carry
/// `effect_log`/`effect_cursor`), not a partial fix here.
pub fn noteUnicodeVersion(self: *Vm) Error!void {
    if (self.unicode_version_pinned) return;
    switch (self.effect_mode) {
        .off => {},
        .record => try logEffect(self, .unicode_version, Value.int(unicode_case.unicode_version_packed)),
        .replay => {
            // On a snapshot-resume the version may have been pinned before the cut;
            // its effect then sits behind the cursor — don't consume a second one.
            if (!versionAlreadyConsumed(self)) {
                const v = try nextLoggedEffect(self, .unicode_version);
                // The shared scalar shape-gate (effectser.checkResultShape) accepts
                // *either* int or float, so a corrupt log could park a float here;
                // `asInt()` asserts int. Treat a non-int version as a mismatch (a log
                // we cannot read the version from is, for our purposes, the wrong
                // version) rather than asserting on hostile bytes.
                if (v.tag != .int or v.asInt() != @as(i64, unicode_case.unicode_version_packed))
                    return Error.UnicodeVersionMismatch;
            }
        },
    }
    self.unicode_version_pinned = true;
}

/// Read a file's content through the `file_read` record/replay boundary, for
/// `loadfile`/`dofile`. In `off`/`record` it reads the injected `fs_source` (else
/// `FsUnavailable`) and, in `record`, logs the result once as `.file_read`. In
/// `replay` it reads the content back from the log and never touches disk. The
/// result is an interned heap **string** of the file bytes, or `nil` if the file
/// could not be opened (the caller turns that into Lua's `cannot open` message).
/// Public so the `loadfile`/`dofile` natives (stdlib/load.zig) can drive it — the
/// call site is the effect boundary, exactly like `clock`/`getenv`.
pub fn obtainFileRead(self: *Vm, path: []const u8) Error!Value {
    const result = switch (self.effect_mode) {
        .off, .record => blk: {
            const src = self.fs_source orelse return Error.FsUnavailable;
            const r = if (src.read(src.ctx, path)) |bytes|
                try self.heap.internValue(bytes)
            else
                Value.nil();
            if (self.effect_mode == .record) try logEffect(self, .file_read, r);
            break :blk r;
        },
        .replay => try nextLoggedEffect(self, .file_read),
    };
    // S-B: file content is host text and must be valid UTF-8 (a missing file is a
    // non-string `nil` → no-op). Validated after logging for the same record/replay
    // lockstep reason as `performEffect`.
    try self.validateHostText(result);
    return result;
}

/// `os.clock()` — the canonical first nondeterministic *input* (doc 02). Returns
/// the host monotonic clock as **seconds, a float** (Lua-faithful; `os.nsclock`
/// exposes the raw integer nanoseconds). Pure-nondeterministic: two calls differ,
/// which is exactly why it must be recorded to replay deterministically. The
/// recorded `.clock` effect carries this float value (the `EffectResult` codec
/// round-trips float scalars; `replay` returns it verbatim without re-dividing).
/// Ignores its arguments. Reads the value through the embedder-injected
/// `Vm.clock_source` — the interpreter holds no platform clock of its own, so the
/// VM core compiles to any target (including `wasm32-freestanding`, which has no
/// clock syscall). With no source injected this is `ClockUnavailable`; the
/// `replay` path never reaches here (it feeds the log back in `performEffect`).
fn nativeClock(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const src = vm.clock_source orelse return Error.ClockUnavailable;
    return Value.float(@as(f64, @floatFromInt(src.nowNs(src.ctx))) / 1e9);
}

/// `os.nsclock()` — a lune extension (no Lua equivalent): the same host monotonic
/// clock as `os.clock`, but returned as **integer nanoseconds** for high-resolution
/// timing. Shares `EffectKind.clock`; the recorded result is the int ns. Mixing
/// `os.clock` (float) and `os.nsclock` (int) in one run interleaves float/int
/// `.clock` entries in the log, consumed by call order on replay (the scalar shape
/// gate accepts both — see `effectser.resultShapeOf`).
fn nativeNsClock(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const src = vm.clock_source orelse return Error.ClockUnavailable;
    return Value.int(src.nowNs(src.ctx));
}

/// Uniform `u64` in `[0, span]` inclusive, drawn from `rng`. Mirrors PUC Lua's
/// `project` (lmathlib.c): spread `span`'s bits rightward into the smallest
/// Mersenne number `lim >= span`, mask each raw word with `lim`, and reject any
/// result still above `span` — so every value in `[0, span]` is equally likely
/// regardless of whether the interval size is a power of two. Implemented on the
/// raw `Xoshiro256.next()` word stream (not `std.Random.intRangeAtMost`) to keep
/// the integer draw a pure function of *our* code plus the pinned engine, off the
/// churning std surface (Rule Z-2) — so the stream is reproducible across runs,
/// replay, and the native/wasm engines. `span == maxInt(u64)` makes `lim` all-ones
/// (no rejection); `span == 0` returns 0 after consuming one word.
fn projectU64(rng: *std.Random.Xoshiro256, span: u64) u64 {
    var lim = span;
    var sh: u6 = 1;
    while (lim & (lim +% 1) != 0) : (sh = sh *% 2) lim |= lim >> sh;
    var r = rng.next() & lim;
    while (r > span) r = rng.next() & lim;
    return r;
}

/// Fetch `random`/`randomseed` argument `i` (0-based) as an integer, raising the
/// located Lua bad-argument error: `(number expected, got <type|no value>)` when
/// missing or non-numeric, `(number has no integer representation)` for a
/// non-integral float. Mirrors `stdlib/table.zig`'s `intArg`.
fn randIntArg(vm: *Vm, args: []const Value, i: usize) Error!i64 {
    if (i >= args.len) return vm.badArg(i + 1, "number", null);
    const v = args[i];
    if (!v.isNumber()) return vm.badArg(i + 1, "number", v);
    if (v.isInt()) return v.asInt();
    const f = v.asFloat();
    const two_pow_63 = 9223372036854775808.0; // 2^63, exact in f64
    if (std.math.isFinite(f) and f == @trunc(f) and f >= -two_pow_63 and f < two_pow_63)
        return @intFromFloat(f);
    return vm.badArgReason(i + 1, "number has no integer representation");
}

/// `math.random([m [, n]])` — drawn from the VM's own PRNG. The nondeterministic
/// *input* is a single seed (the `.random_seed` effect), obtained lazily on the
/// first call (or set explicitly by `math.randomseed`) and recorded once; every
/// draw after that is pure VM state, so replay reproduces the whole stream from
/// that one logged seed. The PRNG is `std.Random.Xoshiro256` (pinned by name —
/// see `Vm.rng`), so a given seed yields the same sequence across runs and across
/// the native/wasm engines. Three forms (Lua 5.4):
///   - no args → float in `[0,1)`;
///   - one arg `n` → integer in `[1,n]`, except `n == 0` → a full-width random
///     integer (all 64 bits);
///   - two args `m,n` → integer in `[m,n]` inclusive (`m > n` is "interval is
///     empty", a bad-argument error).
/// lune is Lua-*shaped*, not stream-compatible: the distribution matches PUC's
/// (uniform via `projectU64`) but the byte sequence does not (different engine).
fn nativeRandom(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));

    // Validate ALL arguments and the interval BEFORE acquiring the seed, so an
    // invalid call (bad arg type, empty interval) raises its bad-argument error
    // without ever touching the entropy/effect boundary — otherwise a first-call
    // `math.random("x")`/`math.random(5,2)` would lazily pull (and in `record`
    // mode log, in `replay` consume) a `.random_seed` effect before erroring,
    // making invalid calls part of the recorded determinism (reviewers' catch).
    var low: i64 = 1;
    var up: i64 = undefined;
    var full_width = false; // the `math.random(0)` special case: a full 64-bit int
    if (args.len >= 1) {
        if (args.len == 1) {
            up = try randIntArg(vm, args, 0);
            if (up == 0) full_width = true;
        } else {
            low = try randIntArg(vm, args, 0);
            up = try randIntArg(vm, args, 1);
        }
        if (!full_width and low > up)
            return vm.badArgReason(if (args.len == 1) 1 else 2, "interval is empty");
    }

    // Known-valid (or the 0-arg float form): now seed lazily — on the first draw,
    // or honour an explicit `math.randomseed` that already set `vm.rng`.
    if (vm.rng == null) vm.rng = std.Random.Xoshiro256.init(try obtainRandomSeed(vm));
    const rng = &vm.rng.?;

    if (args.len == 0) return Value.float(rng.random().float(f64));
    if (full_width) return Value.int(@bitCast(rng.next()));
    // Project a raw word into [0, up-low] (unsigned span: can't overflow even for
    // the full [mininteger, maxinteger] interval), then shift back up to [low, up].
    const span: u64 = @as(u64, @bitCast(up)) -% @as(u64, @bitCast(low));
    const p = projectU64(rng, span);
    return Value.int(@bitCast(@as(u64, @bitCast(low)) +% p));
}

/// `math.randomseed([x])` — (re)seed the VM's PRNG. With an integer argument the
/// seed is deterministic (a pure function of the program, so it logs no effect and
/// in `replay` re-seeds identically without consuming the log). With no argument it
/// draws one fresh seed from the host entropy source through the `.random_seed`
/// record/replay boundary (`obtainRandomSeed`) — exactly like `random()`'s lazy
/// seed, so the entropy form is recorded and replayed for free, and is
/// `RandomUnavailable` when no source is injected. lune's Xoshiro256 takes a single
/// `u64` seed (not PUC's two words), so this returns the one seed actually used.
fn nativeRandomseed(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const seed: u64 = if (args.len == 0 or args[0].isNil())
        try obtainRandomSeed(vm)
    else
        @bitCast(try randIntArg(vm, args, 0));
    vm.rng = std.Random.Xoshiro256.init(seed);
    return Value.int(@bitCast(seed));
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
        // Honour `__tostring` when present; otherwise the default rendering
        // (no interning on the common path).
        if (try vm.metaToString(arg)) |s| {
            try w.writeAll(strBytes(s).?);
        } else {
            try io.writeValue(w, arg);
        }
    }
    try w.writeAll("\n");
    if (to_stdout) io.flush();
    return Value.nil();
}

/// `warn(msg1, ···)` — Lua 5.4 diagnostic warnings (lbaselib.c `luaB_warn` +
/// lauxlib.c default handler). Every argument must be a string. A *single* piece
/// beginning with `@` is a control message — recognized even while warnings are
/// off, so `@on` can re-enable: `@off` stops emission, `@on` restarts, any other
/// `@…` is ignored. Otherwise, when enabled, the string arguments are concatenated
/// and emitted as one line, prefixed `lune warning: `, to stderr (`Vm.err`, or the
/// process stderr). Pure output, NOT a recorded effect (like `print`): the call is
/// a trace barrier and is never replayed, so it carries no `EffectKind`.
fn nativeWarn(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    // At least one argument, and every argument must be a string — Lua checks all
    // pieces before any emission (so a bad piece never half-prints a warning).
    if (args.len < 1) return vm.badArg(1, "string", null);
    for (args, 0..) |a, i| {
        if (strBytes(a) == null) return vm.badArg(i + 1, "string", a);
    }
    // Control message: a single piece beginning with '@'. Checked before the
    // enabled-gate so `@on` works while warnings are off (Lua's `checkcontrol`
    // runs from both the on and off handlers).
    if (args.len == 1) {
        const b = strBytes(args[0]).?;
        if (b.len >= 1 and b[0] == '@') {
            if (std.mem.eql(u8, b, "@off")) {
                vm.warn_enabled = false;
            } else if (std.mem.eql(u8, b, "@on")) {
                vm.warn_enabled = true;
            }
            // unknown `@…` control messages are ignored
            return Value.nil();
        }
    }
    if (!vm.warn_enabled) return Value.nil();
    const to_stderr = vm.err == null;
    const w = vm.err orelse io.stderrWriter();
    // Diagnostics are **best-effort**: swallow any write/flush error (like
    // `io.eprint`) so `warn` can never turn a closed-stderr or full-buffer into a
    // VM fault. This is what keeps the unserialized `warn_enabled` sound — warn
    // touches only stderr (outside the byte-identical-stdout + effect-log replay
    // contract) and never the VM's success/error outcome, so a keyframe restore
    // resetting `warn_enabled` cannot perturb replayed execution.
    emitWarning(w, args) catch {};
    if (to_stderr) w.flush() catch {};
    return Value.nil();
}

/// Write one assembled `lune warning: <args…>\n` line. Split out so `nativeWarn`
/// can treat the whole emission as a single best-effort unit (`catch {}`).
fn emitWarning(w: *io.Writer, args: []const Value) !void {
    try w.writeAll("lune warning: ");
    for (args) |a| try w.writeAll(strBytes(a).?);
    try w.writeAll("\n");
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

/// `#v` — length of a string (code points, S-B) or table (border). Other types
/// error. Strings are code-point-native (design doc 06): `#s` reports the number
/// of Unicode characters via the cached `cp_len`, not the byte length. O(1).
fn lenOf(v: Value) Error!Value {
    if (v.isHeap()) {
        return switch (v.heapType()) {
            .string => Value.int(@intCast(string.String.fromHeader(v.asHeap()).cpLen())),
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
    vm.source = source; // back located error messages (error level prefix, faults)
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

// --- long-bracket string literals (8-mode parity) ----------------------------

test "long string: plain, concat, and length" {
    try expectProgram(
        "print([[hello]] .. [[ world]], #[[abc]])\n",
        "hello world\t3\n",
    );
}

test "long string: a leading newline is dropped, later newlines kept" {
    // The newline right after `[[` is not part of the string; the one before
    // `]]` is. So the value is "hi\n" (length 3).
    try expectProgram(
        "local s = [[\nhi\n]]\nprint(#s)\n",
        "3\n",
    );
}

test "long string: no escape interpretation" {
    // Backslash-t inside a long string is two literal bytes, not a tab.
    try expectProgram(
        "print([[a\\tb]])\n",
        "a\\tb\n",
    );
}

test "long string: leveled brackets pass through inner ]] verbatim" {
    try expectProgram(
        "print([==[x]]y]==])\n",
        "x]]y\n",
    );
}

test "leveled long comment is ignored between statements" {
    try expectProgram(
        "print(1)--[=[ hidden ]] still hidden ]=]\nprint(2)\n",
        "1\n2\n",
    );
}

test "foundations: pcall catches a bare runtime fault (synthesized message)" {
    try expectProgram(
        "print(pcall(function() return nil + 1 end))\n",
        "false\tanonymous:1: attempt to perform arithmetic on a nil value\n",
    );
}

test "pcall unwind closes the faulting frame's escaped upvalue" {
    // A closure captures a local inside the protected function and escapes (stored
    // in an outer variable) before the call errors. On unwind the faulting frame's
    // registers are discarded, so its open upvalue MUST be closed — otherwise it
    // stays open over a slot that (a) falls above the restored `stack_top`, off the
    // GC root scan, and (b) gets overwritten by the next call that reuses it. The
    // `clobber()` call reuses those high slots; `saved()` must still read "live"
    // (closed snapshot), not the clobbered ints. (Regression: SoA Phase 0
    // index-based upvalues + pcall unwind.)
    try expectProgram(
        \\local saved
        \\local ok = pcall(function()
        \\  local x = "live"
        \\  saved = function() return x end
        \\  error("boom")
        \\end)
        \\local function clobber() local a, b, c = 11, 22, 33 return a + b + c end
        \\clobber()
        \\print(ok, saved())
        \\
    ,
        "false\tlive\n",
    );
}

test "xpcall unwind closes the faulting frame's escaped upvalue (after handler)" {
    // Same invariant on the xpcall path: the boundary is restored only after the
    // message handler runs, and the close must accompany that restore. `clobber()`
    // reuses the discarded slots; `saved()` must read the closed snapshot 42.
    try expectProgram(
        \\local saved
        \\local ok = xpcall(function()
        \\  local y = 42
        \\  saved = function() return y end
        \\  error("boom")
        \\end, function(e) return "handled" end)
        \\local function clobber() local a, b, c = 11, 22, 33 return a + b + c end
        \\clobber()
        \\print(ok, saved())
        \\
    ,
        "false\t42\n",
    );
}

// --- error-message polish: located messages across all 8 modes ---------------

test "errmsg: error(msg) renders located through the pcall path" {
    try expectProgram(
        "print(pcall(function() error(\"boom\") end))\n",
        "false\tanonymous:1: boom\n",
    );
}

test "errmsg: error(msg, 0) suppresses the location prefix" {
    try expectProgram(
        "print(pcall(function() error(\"x\", 0) end))\n",
        "false\tx\n",
    );
}

test "errmsg: error(msg, 2) points at the caller's caller" {
    try expectProgram(
        \\local function f() error("deep", 2) end
        \\print(pcall(function() f() end))
        \\
    ,
        "false\tanonymous:2: deep\n",
    );
}

test "errmsg: a non-string error object passes through unprefixed and keeps its type" {
    try expectProgram(
        \\local ok, e = pcall(function() error({code = 1}) end)
        \\print(ok, type(e), e.code)
        \\
    ,
        "false\ttable\t1\n",
    );
}

test "errmsg: a converted native gives the detailed located bad-argument message" {
    try expectProgram(
        "print(pcall(function() return string.sub(nil, 1) end))\n",
        "false\tanonymous:1: bad argument #1 to 'sub' (string expected, got nil)\n",
    );
}

test "errmsg: a non-integral float arg reports the integer-representation reason" {
    try expectProgram(
        "print(pcall(function() return string.sub(\"abc\", 1.5) end))\n",
        "false\tanonymous:1: bad argument #2 to 'sub' (number has no integer representation)\n",
    );
}

test "errmsg: error() with invalid level type or non-integral float raises bad argument" {
    try expectProgram(
        "print(pcall(function() error(\"boom\", \"invalid\") end))\n",
        "false\tanonymous:1: bad argument #2 to 'error' (number expected, got string)\n",
    );
    try expectProgram(
        "print(pcall(function() error(\"boom\", 2.5) end))\n",
        "false\tanonymous:1: bad argument #2 to 'error' (number has no integer representation)\n",
    );
}

test "errmsg: error() with level past depth suppresses location" {
    try expectProgram(
        \\local function f() error("deep", 4) end
        \\print(pcall(function() f() end))
        \\
    ,
        "false\tdeep\n",
    );
}

test "errmsg: select() with float arguments handles conversion and bounds checks" {
    try expectProgram(
        "print(select(2.0, 'a', 'b', 'c'))\n",
        "b\tc\n",
    );
    try expectProgram(
        "print(pcall(function() select(1e20, 'a') end))\n",
        "false\tanonymous:1: bad argument #1 to 'select' (number has no integer representation)\n",
    );
}


test "errmsg: an unconverted (pure) native still names the function, located" {
    try expectProgram(
        "print(pcall(function() return math.floor(\"x\") end))\n",
        "false\tanonymous:1: bad argument to 'floor'\n",
    );
}

// --- load (chunk L-1): runtime compilation -----------------------------------
// `load` compiles a source string into a closure at runtime. It is a pure
// function of the source bytes (no host effect), so every program below runs
// byte-identical across all modes via `expectProgram`. A `load` native is a
// trace barrier like any native, so the compile never perturbs the JIT.

test "string.encode: s:encode() yields a byte array (UTF-8) across all modes" {
    try expectProgram(
        \\local b = ("Hi"):encode()
        \\print(b[1], b[2], #b)
        \\local e = ("é"):encode()
        \\print(e[1], e[2], #e)
        \\
    ,
        "72\t105\t2\n195\t169\t2\n",
    );
}

test "string.decode: round-trips encode and reads a hand-built byte array" {
    try expectProgram(
        \\print(string.decode(("héllo"):encode()) == "héllo")
        \\print(string.decode({72, 105, 33}))
        \\
    ,
        "true\nHi!\n",
    );
}

test "string.decode: malformed UTF-8 is a catchable error" {
    try expectProgram(
        \\local ok, msg = pcall(string.decode, {0xA9})
        \\print(ok, type(msg))
        \\
    ,
        "false\tstring\n",
    );
}

// --- S-E: the u8 (byte) array lane, byte-identical across all 8 modes ---------

test "S-E: a byte-array workload is byte-identical across all modes (u8 lane)" {
    // Dense fill with values in [0,255] commits the u8 lane (1 byte/slot); the hot
    // read loop tiers the u8 `aload` to native. High bytes (>=128) must ZERO-extend
    // — a wrong sign-extend would make t[200]=199 read as a negative and diverge the
    // sum. Identical output in record_execute_native vs tier-0 proves the native
    // movzx matches array.decode's zero-extend.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = (i - 1) % 256 end
        \\local sum = 0
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do sum = sum + t[i] end
        \\end
        \\print(sum)
        \\print(t[129], t[200], t[256])
        \\
    ,
        "3264000\n128\t199\t255\n",
    );
}

test "S-E: a u8->i16 mid-run widen stays deterministic across all modes" {
    // The array commits u8 (bytes 0..255), then a 5000 store widens it to i16
    // (u8's combined-range widen → the smallest signed lane covering [0,5000]). The
    // subsequent hot read loop runs on the widened i16 lane natively. Byte-identical
    // output confirms the widen + widen-eviction path is deterministic under record/
    // replay and native compilation.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 256 do t[i] = i - 1 end
        \\t[100] = 5000
        \\local sum = 0
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do sum = sum + t[i] end
        \\end
        \\print(sum)
        \\print(t[100], t[256])
        \\
    ,
        "3754100\n5000\t255\n",
    );
}

// --- Phase D Gap A: the f64 (double) array lane, byte-identical across all modes -

test "f64 lane: a float-array read reduction is byte-identical across all modes" {
    // Dense fill with doubles commits the f64 lane (8 bytes/slot); the hot read loop
    // tiers the f64 `aload` to native (`lea` + `movsd` into an XMM, `addsd` to the
    // carried float accumulator). The load moves raw bits — `array.decode` for `.f64`
    // is a `@bitCast` — so record_execute_native must match tier-0 bit-for-bit. The
    // sum (and the spot reads) are exactly representable, so the text is unambiguous.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\local sum = 0.0
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do sum = sum + t[i] end
        \\end
        \\print(sum)
        \\print(t[1], t[129], t[256])
        \\
    ,
        "1644800\n0.5\t64.5\t128\n",
    );
}

test "f64 lane: a constant float-array fill is byte-identical across all modes" {
    // The hot write loop tiers the f64 `astore` to native (`movsd` store + presence
    // `bts`). guard_fits is a no-op for f64 (every double fits) and tropt folds it for
    // the constant store, so this also exercises the proveKinds path that admits an
    // f64 astore with no `fits_ok` coverage. Slots 257..300 stay at their fill value
    // (the hot loop only writes 1..256), proving the store is correctly bounded.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do t[i] = 2.5 end
        \\end
        \\local s = 0.0
        \\for i = 1, 256 do s = s + t[i] end
        \\print(s)
        \\print(t[1], t[200], t[256], t[300])
        \\
    ,
        "640\n2.5\t2.5\t2.5\t150\n",
    );
}

// --- Gap B: read-modify-write store-sinking, byte-identical across all modes ----

test "f64 RMW: a read-modify-write float loop is byte-identical across all modes" {
    // The hot inner loop is `t[i] = t[i] + 1.0` — an `aload` of t[i] feeds the value
    // that the `astore` writes back. Under the old C1 rule this aborted recording
    // ("astore after aload"); store-sinking (doc 07) defers the single astore below
    // every loop-exit guard so it lands just before `.loop`.
    //
    // This is the load-bearing idempotence test. lune's deopt re-runs a whole
    // iteration from the loop header: a trace completes N iterations, then on the
    // loop-back guard side-exit tier-0 re-runs iteration N+1 from bytecode. Because
    // the store is sunk *below* that guard, the side-exiting iteration never executed
    // its store inside the trace, so tier-0 applies `+1.0` exactly once. If the store
    // were *not* sunk, the boundary iteration would double-apply (+2.0) and
    // record_execute_native would diverge from tier-0. The accumulate makes any
    // double-apply visible in the printed bits.
    //
    // After 100 reps over 1..256: t[i] = i*0.5 + 100 (exactly representable);
    // t[257..300] stay at their fill value, proving the sunk store stays in bounds.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\for rep = 1, 100 do
        \\  for i = 1, 256 do t[i] = t[i] + 1.0 end
        \\end
        \\print(t[1], t[128], t[256], t[300])
        \\
    ,
        "100.5\t164\t228\t150\n",
    );
}

test "f64 multi-store RMW: a two-store butterfly loop is byte-identical across all modes" {
    // Gap C (doc 08): the inner loop reads two slots then writes both back
    // (`a=t[i]; b=t[i+1]; t[i]=a+1; t[i+1]=b+2`) — TWO read-modify-write stores per
    // iteration, the shape Gap B's single-store rule aborted on (the 2nd store hit
    // `pending_store != null`). Multi-store sinking defers both stores and flushes
    // them, in recorded order, below every loop-exit guard.
    //
    // Same load-bearing idempotence argument as Gap B, now for K=2: on a side-exit
    // (incl. the loop-back `guard_true`) NEITHER sunk store has executed on-trace, so
    // tier-0 re-runs the iteration from the header and applies each `+1.0`/`+2.0`
    // exactly once. A double-apply on the boundary iteration would shift t[253]/t[254]
    // by their increment — visible in the printed bits. All reads precede all stores,
    // so the "no aload after a sunk store" invariant holds.
    //
    // After 100 reps over odd i in 1..253 (writing t[i], t[i+1]): t[i] = i*0.5 + 100,
    // t[i+1] = (i+1)*0.5 + 200 (exactly representable). t[255] stays at its fill value
    // (the loop's last i is 253, writing t[253],t[254]) — proving the sunk stores stay
    // in bounds.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 300 do t[i] = i * 0.5 end
        \\for rep = 1, 100 do
        \\  for i = 1, 254, 2 do
        \\    local a = t[i]
        \\    local b = t[i+1]
        \\    t[i]   = a + 1.0
        \\    t[i+1] = b + 2.0
        \\  end
        \\end
        \\print(t[1], t[2], t[253], t[254], t[255])
        \\
    ,
        "100.5\t201\t226.5\t327\t127.5\n",
    );
}

test "load: compiles and runs a returning chunk" {
    try expectProgram(
        "local f = load(\"return 6 * 7\"); print(f())\n",
        "42\n",
    );
}

test "load: loaded chunk sees globals and prints" {
    try expectProgram(
        \\local f = load("print('hi from load')")
        \\f()
        \\
    ,
        "hi from load\n",
    );
}

test "load: a syntax error returns (nil, message) rather than raising" {
    try expectProgram(
        "local f, e = load(\"return ++\"); print(f, type(e))\n",
        "nil\tstring\n",
    );
}

test "load: the error message carries the chunk name and line" {
    try expectProgram(
        "local f, e = load(\"return ++\"); print(e)\n",
        "(load):1: expected an expression\n",
    );
}

test "load: an explicit chunk name appears in the error message" {
    try expectProgram(
        "local f, e = load(\"x x\", \"mychunk\"); print(e)\n",
        "mychunk:1: expected a statement (assignment or call)\n",
    );
}

test "load: a runtime fault in loaded code reports the loaded chunk's line" {
    try expectProgram(
        \\local f = load("local x = 1\nreturn nil + x")
        \\print(pcall(f))
        \\
    ,
        "false\t(load):2: attempt to perform arithmetic on a nil value\n",
    );
}

test "load: a single-result call yields only the closure (primary projection)" {
    try expectProgram(
        "print(type(load(\"return 1\")))\n",
        "function\n",
    );
}

test "load: passing a non-string chunk raises a bad-argument error" {
    try expectProgram(
        "print(pcall(function() return load(42) end))\n",
        "false\tanonymous:1: bad argument #1 to 'load' (string expected, got number)\n",
    );
}

test "load: a long chunk name is reported in full (allocated message, no truncation)" {
    // The error message is allocated, not written into a fixed buffer, so an
    // arbitrarily long chunk name appears in full as the `<name>:<line>: <msg>`
    // prefix — verified by checking the 600-char name is the message's prefix and
    // the message extends past it with the location/syntax text.
    try expectProgram(
        \\local name = string.rep("a", 600)
        \\local f, e = load("x x", name)
        \\print(f, e:sub(1, 600) == name, #e > 600)
        \\
    ,
        "nil\ttrue\ttrue\n",
    );
}

test "load: a loaded chunk is vararg — arguments arrive through ..." {
    try expectProgram(
        \\local add = load("local a, b = ...\nreturn a + b")
        \\print(add(2, 3), add(10, 20))
        \\
    ,
        "5\t30\n",
    );
}

// --- metatables (chunk 2a): __index / __newindex + set/getmetatable ----------
// Each program runs byte-identical across all 8 modes (gc_stress × 5 trace
// modes). Metatable-bearing tables abort trace recording (`has_metatable`), so
// the metamethod path is the tier-0 dispatch under every mode.

test "metatable: __index table gives class/inheritance method lookup" {
    try expectProgram(
        \\local Animal = {}
        \\Animal.__index = Animal
        \\function Animal.new(name) return setmetatable({ name = name }, Animal) end
        \\function Animal:speak() return self.name .. " speaks" end
        \\local a = Animal.new("rex")
        \\print(a:speak())
        \\print(a.name)
        \\
    ,
        "rex speaks\nrex\n",
    );
}

test "metatable: __index function form" {
    try expectProgram(
        \\local t = setmetatable({}, { __index = function(_, k) return "<" .. k .. ">" end })
        \\print(t.foo)
        \\t.foo = 1
        \\print(t.foo)
        \\
    ,
        "<foo>\n1\n",
    );
}

test "metatable: __newindex function fires only for absent keys" {
    try expectProgram(
        \\local n = 0
        \\local t = setmetatable({}, { __newindex = function(tt, k, v) n = n + 1; rawset(tt, k, v) end })
        \\t.a = 1
        \\t.a = 2
        \\t.b = 3
        \\print(n, t.a, t.b)
        \\
    ,
        "2\t2\t3\n",
    );
}

test "metatable: __newindex table redirects writes" {
    try expectProgram(
        \\local backing = {}
        \\local t = setmetatable({}, { __newindex = backing })
        \\t.x = 10
        \\print(rawget(t, "x"), backing.x)
        \\
    ,
        "nil\t10\n",
    );
}

test "metatable: getmetatable and __metatable protection" {
    try expectProgram(
        \\local mt = { __metatable = "locked" }
        \\local t = setmetatable({}, mt)
        \\print(getmetatable(t))
        \\print(pcall(setmetatable, t, {}))
        \\
    ,
        "locked\nfalse\tmain:4: cannot change a protected metatable\n",
    );
}

test "metatable: setmetatable(t, nil) clears the metatable" {
    try expectProgram(
        \\local t = setmetatable({}, { __index = function() return 7 end })
        \\print(t.missing)
        \\setmetatable(t, nil)
        \\print(t.missing)
        \\print(getmetatable(t))
        \\
    ,
        "7\nnil\nnil\n",
    );
}

test "metatable: string methods resolve through the shared string metatable" {
    try expectProgram(
        \\print(("foo"):upper())
        \\print(("hello"):len())
        \\print(("a,b,c"):gsub(",", ";"))
        \\print(getmetatable("") ~= nil)
        \\
    ,
        "FOO\n5\na;b;c\t2\ntrue\n",
    );
}

test "metatable: __index chain (multi-level inheritance) is bounded and resolves" {
    try expectProgram(
        \\local A = {}; A.__index = A; A.kind = "A"
        \\local B = setmetatable({}, A); B.__index = B
        \\local obj = setmetatable({}, B)
        \\print(obj.kind)
        \\
    ,
        "A\n",
    );
}

test "metatable: a self-referential __index chain raises rather than hanging" {
    try expectProgram(
        \\local loop = {}
        \\setmetatable(loop, { __index = loop })
        \\print(pcall(function() return loop.nope end))
        \\
    ,
        "false\tanonymous:3: '__index' chain too long; possible loop\n",
    );
}

test "metatable: setmetatable rejects a non-table/non-nil metatable argument" {
    try expectProgram(
        \\print(pcall(function() return setmetatable({}, 5) end))
        \\
    ,
        "false\tanonymous:1: bad argument #2 to 'setmetatable' (nil or table expected, got number)\n",
    );
}

// Recorder/JIT safety (reviewer-found, chunk 2a): a hot array loop forms a
// native trace on a metatable-free table; if `setmetatable` later adds a
// metatable, the cached trace must side-exit to tier-0 (the `guard_table`
// no-metatable half) so `__newindex` still fires. A wrong (raw native store)
// would diverge the native mode from tier-0 — caught by all 8 modes here.

test "metatable: setmetatable mid-hot-loop still dispatches __newindex (trace guard)" {
    try expectProgram(
        \\local t, n = {}, 0
        \\local mt = { __newindex = function(tt, k, v) n = n + 1; rawset(tt, k, v) end }
        \\for i = 1, 100 do
        \\  if i == 30 then setmetatable(t, mt) end
        \\  t[i] = true
        \\end
        \\print(n)
        \\
    ,
        "71\n",
    );
}

test "metatable: a native trace re-entered on a metatable'd table dispatches __newindex" {
    try expectProgram(
        \\local function fill(t) for i = 1, 60 do t[i] = i end end
        \\local a = {}
        \\fill(a)
        \\local log = {}
        \\local b = setmetatable({}, { __newindex = function(_, _, v) log[#log + 1] = v end })
        \\fill(b)
        \\print(#a, #log, rawlen(b))
        \\
    ,
        "60\t60\t0\n",
    );
}

// ── Chunk 2b: arithmetic / compare / __concat / __len / __call / __tostring
// metamethods. Each routes the tier-0 op's TypeError (or non-callable) path
// through the shared dispatch helpers, which call into the VM via `callValue`
// — a trace barrier, so every recorded op already aborts on a non-number
// operand and side-exits to tier-0, keeping all 8 modes byte-identical.

test "metatable: arithmetic metamethods (add/sub/mul/div/mod/pow/idiv)" {
    try expectProgram(
        \\local V = {}; V.__index = V
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\V.__add  = function(a, b) return v(a.n + b.n) end
        \\V.__sub  = function(a, b) return v(a.n - b.n) end
        \\V.__mul  = function(a, b) return v(a.n * b.n) end
        \\V.__div  = function(a, b) return a.n / b.n end
        \\V.__mod  = function(a, b) return a.n % b.n end
        \\V.__pow  = function(a, b) return a.n ^ b.n end
        \\V.__idiv = function(a, b) return a.n // b.n end
        \\print((v(2) + v(3)).n)
        \\print((v(7) - v(4)).n)
        \\print((v(3) * v(5)).n)
        \\print(v(7) / v(2))
        \\print(v(7) % v(3))
        \\print(v(2) ^ v(10))
        \\print(v(7) // v(2))
        \\
    ,
        "5\n3\n15\n3.5\n1\n1024\n3\n",
    );
}

test "metatable: bitwise metamethods (band/bor/bxor/shl/shr/bnot)" {
    try expectProgram(
        \\local N = {}; N.__index = N
        \\local function n(x) return setmetatable({ v = x }, N) end
        \\N.__band = function(a, b) return a.v & b.v end
        \\N.__bor  = function(a, b) return a.v | b.v end
        \\N.__bxor = function(a, b) return a.v ~ b.v end
        \\N.__shl  = function(a, b) return a.v << b.v end
        \\N.__shr  = function(a, b) return a.v >> b.v end
        \\N.__bnot = function(a) return ~a.v end
        \\print(n(6) & n(3))
        \\print(n(6) | n(1))
        \\print(n(6) ~ n(3))
        \\print(n(1) << n(4))
        \\print(n(64) >> n(2))
        \\print(~n(0))
        \\
    ,
        "2\n7\n5\n16\n16\n-1\n",
    );
}

test "metatable: unary minus __unm" {
    try expectProgram(
        \\local V = {}
        \\V.__unm = function(a) return -a.n end
        \\local x = setmetatable({ n = 9 }, V)
        \\print(-x)
        \\print(-setmetatable({ n = -4 }, V))
        \\
    ,
        "-9\n4\n",
    );
}

test "metatable: __add dispatches from the right operand when the left lacks it" {
    try expectProgram(
        \\local V = {}
        \\V.__add = function(a, b)
        \\  local an = type(a) == "table" and a.n or a
        \\  local bn = type(b) == "table" and b.n or b
        \\  return an + bn
        \\end
        \\local x = setmetatable({ n = 10 }, V)
        \\print(x + 5)
        \\print(5 + x)
        \\
    ,
        "15\n15\n",
    );
}

test "metatable: __eq fires only between two tables" {
    try expectProgram(
        \\local V = {}
        \\V.__eq = function(a, b) return a.n == b.n end
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\print(v(2) == v(2))
        \\print(v(2) == v(3))
        \\print(v(2) ~= v(3))
        \\print(v(2) == 2)
        \\print(v(2) == "x")
        \\
    ,
        "true\nfalse\ntrue\nfalse\nfalse\n",
    );
}

test "metatable: comparison __lt/__le with gt/ge via operand swap" {
    try expectProgram(
        \\local V = {}
        \\V.__lt = function(a, b) return a.n < b.n end
        \\V.__le = function(a, b) return a.n <= b.n end
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\print(v(1) < v(2), v(2) < v(2))
        \\print(v(2) <= v(2), v(3) <= v(2))
        \\print(v(3) > v(1), v(1) > v(3))
        \\print(v(2) >= v(5), v(5) >= v(2))
        \\
    ,
        "true\tfalse\ntrue\tfalse\ntrue\tfalse\nfalse\ttrue\n",
    );
}

test "metatable: __concat dispatches from either operand" {
    try expectProgram(
        \\local V = {}
        \\V.__concat = function(a, b)
        \\  local an = type(a) == "table" and a.n or a
        \\  local bn = type(b) == "table" and b.n or b
        \\  return "C(" .. an .. "," .. bn .. ")"
        \\end
        \\local x = setmetatable({ n = 4 }, V)
        \\print(x .. "z")
        \\print("z" .. x)
        \\print(x .. x)
        \\
    ,
        "C(4,z)\nC(z,4)\nC(4,4)\n",
    );
}

test "metatable: __len overrides table length" {
    try expectProgram(
        \\local V = {}
        \\V.__len = function(a) return a.size end
        \\local x = setmetatable({ 1, 2, size = 42 }, V)
        \\print(#x)
        \\local plain = { 1, 2, 3 }
        \\print(#plain)
        \\
    ,
        "42\n3\n",
    );
}

test "metatable: __call single and multi-return" {
    try expectProgram(
        \\local adder = setmetatable({ base = 10 }, {
        \\  __call = function(self, x, y) return self.base + x + y end,
        \\})
        \\print(adder(3, 4))
        \\local multi = setmetatable({}, {
        \\  __call = function(self, a, b) return a, b, a + b end,
        \\})
        \\local x, y, z = multi(2, 5)
        \\print(x, y, z)
        \\local sum = 0
        \\for i = 1, 5 do sum = sum + adder(i, 0) end
        \\print(sum)
        \\
    ,
        "17\n2\t5\t7\n65\n",
    );
}

test "metatable: a callable table dispatches __call through host reentry (pcall, table.sort)" {
    // `callValue` (the pcall/sort/gsub reentry primitive) honours `__call`
    // identically to the bytecode call arm — a callable table is callable from
    // every site, not just direct `t(...)`.
    try expectProgram(
        \\local c = setmetatable({}, { __call = function(self, a, b) return a + b end })
        \\print(pcall(c, 3, 4))
        \\local items = { 3, 1, 2 }
        \\local cmp = setmetatable({}, { __call = function(self, x, y) return x < y end })
        \\table.sort(items, cmp)
        \\print(items[1], items[2], items[3])
        \\
    ,
        "true\t7\n1\t2\t3\n",
    );
}

test "metatable: a __call cycle is caught as a stack overflow, not a hang" {
    try expectProgram(
        \\local loop = {}
        \\setmetatable(loop, { __call = loop })
        \\print(pcall(function() return loop() end))
        \\
    ,
        "false\tanonymous:3: stack overflow\n",
    );
}

test "metatable: __tostring via tostring(), print(), and concat" {
    try expectProgram(
        \\local Pt = { __tostring = function(p) return "Pt(" .. p.x .. "," .. p.y .. ")" end }
        \\local p = setmetatable({ x = 1, y = 2 }, Pt)
        \\print(tostring(p))
        \\print(p)
        \\print("p=" .. tostring(p))
        \\
    ,
        "Pt(1,2)\nPt(1,2)\np=Pt(1,2)\n",
    );
}

test "metatable: arithmetic on a table without the metamethod still raises located TypeError" {
    try expectProgram(
        \\print(pcall(function() local t = {}; return t + 1 end))
        \\print(pcall(function() return {} .. "x" end))
        \\print(pcall(function() return -({}) end))
        \\
    ,
        "false\tanonymous:1: attempt to perform arithmetic on a table value\n" ++
            "false\tanonymous:2: attempt to concatenate a table value\n" ++
            "false\tanonymous:3: attempt to perform arithmetic on a table value\n",
    );
}

test "bitwise faults report integer-representation / bitwise-operation messages" {
    // lune is strict integer-only for bitwise: a float operand (even integral)
    // gets "number has no integer representation"; a non-number operand gets
    // "attempt to perform bitwise operation on a <type> value" — distinct from
    // the arithmetic message, matching Lua 5.4's split.
    try expectProgram(
        \\print(pcall(function() return 3.5 & 1 end))
        \\print(pcall(function() return 1 << 2.0 end))
        \\print(pcall(function() return 1 | {} end))
    ,
        "false\tanonymous:1: number has no integer representation\n" ++
            "false\tanonymous:2: number has no integer representation\n" ++
            "false\tanonymous:3: attempt to perform bitwise operation on a table value\n",
    );
}

test "metatable: calling a table with no __call raises a located TypeError" {
    try expectProgram(
        \\print(pcall(function() local t = {}; return t() end))
        \\
    ,
        "false\tanonymous:1: attempt to call a table value\n",
    );
}

test "metatable: __tostring returning a non-string is rejected" {
    try expectProgram(
        \\local bad = setmetatable({}, { __tostring = function() return 42 end })
        \\print(pcall(function() return tostring(bad) end))
        \\
    ,
        "false\tanonymous:2: bad argument to 'tostring'\n",
    );
}

// --- _G (the global environment table) ---------------------------------------

test "_G: reflective access through the global environment table" {
    try expectProgram(
        \\print(_G.print == print)
        \\_G.x = 5
        \\print(_G.x)
        \\print(_G._G == _G)
        \\print(_G._VERSION ~= nil)
        \\
    ,
        "true\n5\ntrue\ntrue\n",
    );
}

test "_G: globals and _G are the same table in both directions" {
    try expectProgram(
        \\g = 42
        \\print(_G.g)
        \\_G.h = 7
        \\print(_G.h)
        \\print(_G._G._G.g)
        \\
    ,
        "42\n7\n42\n",
    );
}

// --- xpcall before-unwind handler + debug.traceback --------------------------

test "xpcall: message handler transforms the error value" {
    try expectProgram(
        "print(xpcall(function() error(\"boom\") end, function(e) return \"H:\" .. e end))\n",
        "false\tH:anonymous:1: boom\n",
    );
}

test "xpcall: a handler that itself errors yields the fixed message" {
    try expectProgram(
        "print(xpcall(function() error(\"x\") end, function(e) error(\"handler boom\") end))\n",
        "false\terror in error handling\n",
    );
}

test "xpcall: pcall behaviour is unchanged (false + located value)" {
    try expectProgram(
        "print(pcall(function() error(\"boom\") end))\n",
        "false\tanonymous:1: boom\n",
    );
}

test "debug.traceback: handler sees the live faulting stack" {
    try expectProgram(
        \\local ok, tb = xpcall(function()
        \\  local t = nil
        \\  return t.x
        \\end, debug.traceback)
        \\print(ok)
        \\print(string.find(tb, "stack traceback:", 1, true) ~= nil)
        \\print(string.find(tb, "attempt to index", 1, true) ~= nil)
        \\
    ,
        "false\ntrue\ntrue\n",
    );
}

test "debug.traceback: message prefix + exact format at top level" {
    try expectProgram(
        "print(debug.traceback(\"x\"))\n",
        "x\nstack traceback:\n\tmain:1: in main chunk\n",
    );
}

test "debug.traceback: a non-stringable message (table) is returned unchanged" {
    try expectProgram(
        \\local t = {}
        \\print(debug.traceback(t) == t)
        \\
    ,
        "true\n",
    );
}

test "debug.traceback: a number message is coerced (Lua's lua_tostring quirk)" {
    try expectProgram(
        "print(debug.traceback(42))\n",
        "42\nstack traceback:\n\tmain:1: in main chunk\n",
    );
}

test "debug.traceback: level skips frames (level past the top is empty)" {
    try expectProgram(
        "print(debug.traceback(\"x\", 99))\n",
        "x\nstack traceback:\n",
    );
}

test "debug.traceback: an out-of-range float level is a bad argument, not a trap" {
    try expectProgram(
        \\local ok, e = pcall(function() return debug.traceback("x", 1e100) end)
        \\print(ok, string.find(e, "integer representation", 1, true) ~= nil)
        \\
    ,
        "false\ttrue\n",
    );
}

// Determinism corpus: a hot loop summing __add-bearing vector objects. The
// metamethod call is a trace barrier so the loop never tiers up past the call,
// but the output and the captured snapshot bytes must be byte-identical across
// two independent runs (proves no nondeterminism leaks through the dispatch
// helpers). expectProgram already runs this across all 8 modes.

test "metatable: hot loop accumulating through __add is deterministic across modes" {
    try expectProgram(
        \\local V = {}; V.__index = V
        \\V.__add = function(a, b) return setmetatable({ n = a.n + b.n }, V) end
        \\local function v(n) return setmetatable({ n = n }, V) end
        \\local acc = v(0)
        \\for i = 1, 200 do acc = acc + v(i) end
        \\print(acc.n)
        \\
    ,
        "20100\n",
    );
}

test "errmsg: a converted table native reports the located bad-argument message" {
    try expectProgram(
        "print(pcall(function() return table.insert(nil, 1) end))\n",
        "false\tanonymous:1: bad argument #1 to 'insert' (table expected, got nil)\n",
    );
}

test "foundations: error raises an arbitrary value caught by pcall" {
    try expectProgram(
        \\local ok, e = pcall(function() error({code = 42}) end)
        \\print(ok, type(e), e.code)
        \\
    ,
        "false\ttable\t42\n",
    );
}

test "foundations: recursive pcall — inner result flows out of the outer" {
    try expectProgram(
        "print(pcall(function() return pcall(function() error(\"x\") end) end))\n",
        "true\tfalse\tanonymous:1: x\n",
    );
}

test "foundations: table.sort default comparator (ascending)" {
    try expectProgram(
        \\local t = {3, 1, 2}
        \\table.sort(t)
        \\print(t[1], t[2], t[3])
        \\
    ,
        "1\t2\t3\n",
    );
}

test "foundations: table.sort with a custom comparator (descending)" {
    try expectProgram(
        \\local t = {5, 3, 8, 1}
        \\table.sort(t, function(a, b) return a > b end)
        \\print(t[1], t[2], t[3], t[4])
        \\
    ,
        "8\t5\t3\t1\n",
    );
}

test "foundations: a sort comparator that errors propagates to an enclosing pcall" {
    try expectProgram(
        "print(pcall(function() table.sort({1, 2}, function() error(\"cmp\") end) end))\n",
        "false\tanonymous:1: cmp\n",
    );
}

test "foundations: string.gsub function replacement substitutes each match" {
    try expectProgram(
        "print(string.gsub(\"hello\", \"l\", function(c) return c .. c end))\n",
        "hellllo\t2\n",
    );
}

test "foundations: string.gsub function returning nil keeps the original text" {
    try expectProgram(
        "print(string.gsub(\"a1b2c3\", \"%a\", function(c) if c == \"b\" then return \"B\" end end))\n",
        "a1B2c3\t3\n",
    );
}

test "foundations: assert passes its arguments through when truthy" {
    try expectProgram(
        "print(assert(5, \"msg\"))\n",
        "5\tmsg\n",
    );
}

test "foundations: assert raises its message when falsy, caught by pcall" {
    try expectProgram(
        "print(pcall(function() assert(false, \"boom\") end))\n",
        "false\tboom\n",
    );
}

test "foundations: xpcall runs the message handler on the error value" {
    try expectProgram(
        \\local ok, r = xpcall(function() error("orig") end, function(m) return "handled:" .. m end)
        \\print(ok, r)
        \\
    ,
        "false\thandled:anonymous:1: orig\n",
    );
}

test "strings: lexicographic ordering with < <= > >=" {
    try expectProgram(
        \\print("a" < "b", "b" < "a", "a" < "a")
        \\print("ab" < "abc", "abc" < "ab", "Z" < "a")
        \\print("a" <= "a", "b" <= "a", "ab" >= "ab")
        \\print("apple" > "apricot", "banana" > "apple")
        \\
    ,
        "true\tfalse\tfalse\n" ++
            "true\tfalse\ttrue\n" ++
            "true\tfalse\ttrue\n" ++
            "false\ttrue\n",
    );
}

test "strings: table.sort orders a string list with the default comparator" {
    try expectProgram(
        \\local t = {"cherry", "apple", "banana"}
        \\table.sort(t)
        \\print(t[1], t[2], t[3])
        \\
    ,
        "apple\tbanana\tcherry\n",
    );
}

test "strings: comparing a string with a number is a catchable type error" {
    try expectProgram(
        "print(pcall(function() return \"a\" < 1 end))\n",
        "false\tanonymous:1: attempt to compare string with number\n",
    );
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
        // Reentrant call (`Vm.callValue`) inside a hot loop: a sort with a custom
        // comparator and a gsub with a function replacement, both driven each
        // iteration. The comparator/replacement reenter the dispatch loop on the
        // host stack; the captured/argument values are interned strings and table
        // elements. If reentry leaked an address into the parked error value, the
        // arg window, or the serialized trace/snapshot, the bytes would diverge.
        \\local total = 0
        \\for i = 1, 30 do
        \\  local t = {(i * 7) % 11, (i * 3) % 11, i % 11, (i * 5) % 11}
        \\  table.sort(t, function(a, b) return a > b end)
        \\  total = total + t[1]
        \\  local r = string.gsub("abc", "%a", function(c) return c .. tostring(i % 3) end)
        \\  total = total + #r
        \\end
        \\print(total)
        ,
        // Error raising + located message synthesis inside a hot loop. Each
        // iteration `pcall`s a function that raises both a Lua value (`error`,
        // prefixed via the call-site locator) and triggers a native bad-argument
        // fault (`string.sub(nil)`, located via `Vm.badArg`), accumulating the
        // caught message lengths. The interned located strings (`chunk:line: …`)
        // must be byte-identical across runs — a leaked address or a per-run line
        // would diverge the output AND the snapshot (the strings land in the heap).
        \\local total = 0
        \\for i = 1, 40 do
        \\  local ok1, e1 = pcall(function() error("loop") end)
        \\  total = total + #e1
        \\  local ok2, e2 = pcall(function() return string.sub(nil, i) end)
        \\  total = total + #e2
        \\end
        \\print(total)
        ,
        // Metatables (chunk 2a): a class via `__index` built and read in a hot
        // loop, plus a `__newindex` logger. Each object carries a metatable — a
        // new heap edge the snapshot serializes (`HeapTable.metatable_id`) and the
        // GC marks. The shared `string_metatable` and the interned `__index`/
        // `__newindex` names are VM-level roots captured by the snapshot too, so a
        // divergent id (a rebuilt-not-rebound metatable, an address leak through
        // the metatable edge) would split the snapshot bytes here. The objects
        // carry metatables, so trace recording aborts (`has_metatable`) and this
        // runs the tier-0 dispatch path under all modes.
        \\local Vec = {}
        \\Vec.__index = Vec
        \\function Vec.new(x) return setmetatable({ x = x }, Vec) end
        \\function Vec:double() return self.x * 2 end
        \\local log = {}
        \\local sink = setmetatable({}, { __newindex = function(t, k, v) log[#log + 1] = v end })
        \\local total = 0
        \\for i = 1, 60 do
        \\  local v = Vec.new(i)
        \\  total = total + v:double()
        \\  sink[i] = i
        \\end
        \\total = total + #log
        \\print(total)
        \\print(("lune"):upper())
        ,
        // _G (the global environment self-reference): write and read globals
        // through `_G` in a hot loop, then chase the self-edge (`_G._G._G…`). The
        // globals table (id 0) now holds a self-referential entry serialized as
        // `HeapRef{id=0}`; a divergent id or a leaked address through that edge
        // would split the snapshot bytes. Writing through `_G` mutates the same
        // globals table the snapshot captures, so the final heap state is fully
        // exercised by the run-twice + snapshot equality checks.
        \\local total = 0
        \\for i = 1, 50 do
        \\  _G.acc = (_G.acc or 0) + i
        \\  total = total + (_G["acc"] % 7)
        \\end
        \\total = total + (_G._G._G._G.acc % 13)
        \\print(total)
        \\print(_G._G == _G)
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
        if (std.mem.eql(u8, name, "BADUTF8")) return "\xFF\xFE"; // not valid UTF-8 (S-B boundary)
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
        \\for i = 1, 4 do print(os.clock()) end
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
        \\print(os.clock()); print(os.clock())
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
    const run = try effectRun(gpa, "print(os.clock() > 0)", .off, &.{}, &clk, null);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), run.log.len);
    try testing.expectEqualStrings("true\n", run.out);
}

test "F2d: clock() with no injected source is ClockUnavailable" {
    const gpa = testing.allocator;
    // The interpreter holds no clock of its own; record/off with no source set
    // surfaces a clear error rather than reaching for a platform clock.
    try testing.expectError(error.ClockUnavailable, effectRun(gpa, "print(os.clock())", .record, &.{}, null, null));
}

test "F2d: os.clock is float seconds, os.nsclock is int nanoseconds (same source)" {
    const gpa = testing.allocator;
    // Pin the clock so both reads see the same instant (2.5e9 ns = 2.5 s). os.clock
    // divides to a float; os.nsclock hands back the raw integer nanoseconds.
    var clk = CounterClock{ .next = 2_500_000_000, .step = 0 };
    const run = try effectRun(gpa,
        \\print(os.clock() == 2.5)
        \\print(os.nsclock() == 2500000000)
        \\print(math.type(os.clock()), math.type(os.nsclock()))
    , .off, &.{}, &clk, null);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\ntrue\nfloat\tinteger\n", run.out);
    try testing.expectEqual(@as(usize, 0), run.log.len); // off mode logs nothing
}

test "F2d: a run mixing os.clock (float) and os.nsclock (int) records + replays byte-identically" {
    const gpa = testing.allocator;
    // Both natives share EffectKind.clock; the log interleaves float and int
    // scalars, consumed by call order on replay. The shared-effect replay path is
    // the thing this exercises (the off-mode shape test above doesn't).
    const source =
        \\print(os.clock()); print(os.nsclock()); print(os.clock())
    ;
    var clk = CounterClock{ .next = 1_500_000_000, .step = 1_000_000_000 };
    const rec = try effectRun(gpa, source, .record, &.{}, &clk, null);
    defer rec.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), rec.log.len); // 2 os.clock + 1 os.nsclock
    // Replay feeds the log back (no clock injected) → byte-identical output.
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    try testing.expectEqual(rec.log.len, rep.log.len);
}

// ---------------------------------------------------------------------------
// warn — Lua 5.4 diagnostic warnings (pure stderr output, NOT a recorded effect)
// ---------------------------------------------------------------------------

const OutErr = struct { out: []const u8, err: []const u8 };

/// Run `source` capturing stdout (`vm.out`) into `out_buf` and `warn` output
/// (`vm.err`) into `err_buf`; returns slices into those caller-owned buffers.
fn runOutErr(gpa: std.mem.Allocator, source: [:0]const u8, out_buf: []u8, err_buf: []u8) !OutErr {
    var out = io.Writer.fixed(out_buf);
    var err = io.Writer.fixed(err_buf);
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = &out;
    vm.err = &err;
    vm.source = source;
    try compileRun(gpa, &vm, source);
    return .{ .out = out.buffered(), .err = err.buffered() };
}

test "warn: concatenates string args into one stderr line, separate from stdout" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("a", "b", "c")
        \\print("x")
    , &ob, &eb);
    try testing.expectEqualStrings("lune warning: abc\n", r.err);
    try testing.expectEqualStrings("x\n", r.out);
}

test "warn: @off suppresses, @on re-enables (control while off is still honoured)" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("one")
        \\warn("@off")
        \\warn("two")
        \\warn("@on")
        \\warn("three")
    , &ob, &eb);
    // "two" is suppressed; "@on" re-enables even though the system was off.
    try testing.expectEqualStrings("lune warning: one\nlune warning: three\n", r.err);
}

test "warn: unknown @control is ignored (system stays on, no line emitted for it)" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("@frobnicate")
        \\warn("still on")
    , &ob, &eb);
    try testing.expectEqualStrings("lune warning: still on\n", r.err);
}

test "warn: a leading-@ piece is only a control message when it is the sole arg" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("@x", "y")
    , &ob, &eb);
    // Two pieces → not a control message → emitted verbatim (concatenated).
    try testing.expectEqualStrings("lune warning: @xy\n", r.err);
}

test "warn: non-string and missing arguments are bad-argument errors" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // Every piece is checked before any emission (Lua semantics): a bad 2nd arg
    // raises even though the 1st is a valid string.
    try testing.expectError(error.LuaError, runOutErr(testing.allocator, "warn(\"ok\", 5)", &ob, &eb));
    try testing.expectError(error.LuaError, runOutErr(testing.allocator, "warn()", &ob, &eb));
}

// ---------------------------------------------------------------------------
// F2e — seed-based randomness (`math.random` / `math.randomseed`)
//
// `math.random()` is a nondeterministic *input* like `clock()`, but seed-based:
// the single recorded effect is one `random_seed`, acquired lazily on the first
// call, from which a VM-internal PRNG reproduces the entire draw stream on replay.
// So a multi-draw program records exactly ONE effect, and replaying that one seed
// reproduces every draw byte-identically. These tests prove (1) record→replay
// fidelity with a single logged seed, (2) different seeds yield different streams
// (the PRNG genuinely varies), (3) a missing seed in the log is reported, (4) no
// injected source is a clear error, (5) draws lie in [0,1), (6) the integer forms
// `math.random(n)` / `math.random(m,n)` stay in range and reject empty intervals,
// and (7) `math.randomseed` re-seeds deterministically (and its no-arg entropy
// form records/replays through the same boundary).
// ---------------------------------------------------------------------------

test "F2e: replaying the recorded seed reproduces the whole draw stream" {
    const gpa = testing.allocator;
    // Three draws — proving the single seed drives the entire stream, not one call.
    const source =
        \\print(math.random()); print(math.random()); print(math.random())
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
        \\print(math.random()); print(math.random())
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
    try testing.expectError(error.EffectLogExhausted, effectRun(gpa, "print(math.random())", .replay, &.{}, null, null));
}

test "F2e: math.random() with no injected source is RandomUnavailable" {
    const gpa = testing.allocator;
    // The VM owns the PRNG but not the seed; record/off with no source set
    // surfaces a clear error rather than reaching for OS entropy itself.
    try testing.expectError(error.RandomUnavailable, effectRun(gpa, "print(math.random())", .record, &.{}, null, null));
}

test "F2e: draws lie in [0,1)" {
    const gpa = testing.allocator;
    // `r < 1 and r >= 0` over several draws — the float() contract.
    const source =
        \\local ok = true
        \\for i = 1, 50 do
        \\  local r = math.random()
        \\  if r < 0 or r >= 1 then ok = false end
        \\end
        \\print(ok)
    ;
    var sd = FixedSeed{ .value = 42 };
    const run = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\n", run.out);
}

test "F2e: math.random(m,n) stays in [m,n] and hits both ends" {
    const gpa = testing.allocator;
    // Over many draws of a small interval every result must be in [m,n], and the
    // bounds must actually be reachable (the projection isn't off-by-one).
    const source =
        \\local lo, hi = 3, 8
        \\local ok, sawlo, sawhi = true, false, false
        \\for i = 1, 400 do
        \\  local r = math.random(lo, hi)
        \\  if r < lo or r > hi then ok = false end
        \\  if r == lo then sawlo = true end
        \\  if r == hi then sawhi = true end
        \\end
        \\print(ok, sawlo, sawhi)
    ;
    var sd = FixedSeed{ .value = 42 };
    const run = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\ttrue\ttrue\n", run.out);
}

test "F2e: math.random(n) is [1,n]; (1,1) is always 1; (0) spans negatives" {
    const gpa = testing.allocator;
    const source =
        \\local ok = true
        \\for i = 1, 200 do
        \\  local r = math.random(6)         -- [1,6]
        \\  if r < 1 or r > 6 then ok = false end
        \\  if math.random(1, 1) ~= 1 then ok = false end
        \\end
        \\-- random(0) is a full-width integer: over many draws at least one is
        \\-- negative (the high bit set), proving it isn't clamped to non-negative.
        \\local sawneg = false
        \\for i = 1, 200 do if math.random(0) < 0 then sawneg = true end end
        \\print(ok, sawneg)
    ;
    var sd = FixedSeed{ .value = 7 };
    const run = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\ttrue\n", run.out);
}

test "F2e: math.random empty interval and non-integer args are bad-argument errors" {
    const gpa = testing.allocator;
    var sd = FixedSeed{ .value = 1 };
    // m > n → "interval is empty".
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random(5, 2))", .record, &.{}, null, &sd));
    var sd2 = FixedSeed{ .value = 1 };
    // a non-integral float → "number has no integer representation".
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random(1.5))", .record, &.{}, null, &sd2));
    var sd3 = FixedSeed{ .value = 1 };
    // a non-number → "number expected".
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random('x'))", .record, &.{}, null, &sd3));
}

test "F2e: an invalid math.random call raises before touching the seed/effect boundary" {
    const gpa = testing.allocator;
    // Reviewers' catch: arg/interval validation must happen BEFORE the lazy seed,
    // so an invalid *first* call doesn't consume the entropy/effect boundary. Proof:
    // in replay mode with an EMPTY log, an invalid call surfaces its bad-argument
    // LuaError — NOT EffectLogExhausted (which is what trying to read a seed first
    // would yield). Both the empty-interval and the bad-type forms.
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random(5, 2))", .replay, &.{}, null, null));
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random('x'))", .replay, &.{}, null, null));
    // And in record mode with a seed source: an invalid first call logs ZERO
    // effects (the seed was never acquired). Inspect the log on a live VM.
    var sd = FixedSeed{ .value = 1 };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.random_seed_source = sd.source();
    try testing.expectError(error.LuaError, compileRun(gpa, &vm, "math.random(5, 2)"));
    try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);
}

test "F2e: math.randomseed(x) re-seeds deterministically (same seed → same stream)" {
    const gpa = testing.allocator;
    // Explicit-seed form logs NO effect (the seed is in the program), and seeding
    // twice with the same x reproduces the stream — proving the re-seed is a pure
    // function of x, independent of the lazy entropy seed.
    const source =
        \\math.randomseed(123)
        \\local a = {}
        \\for i = 1, 5 do a[i] = math.random(1, 1000) end
        \\math.randomseed(123)
        \\local same = true
        \\for i = 1, 5 do if math.random(1, 1000) ~= a[i] then same = false end end
        \\print(same)
    ;
    // No seed source injected: an explicit randomseed needs none, and no lazy seed
    // is acquired (rng is set before the first draw), so this records zero effects.
    const run = try effectRun(gpa, source, .off, &.{}, null, null);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\n", run.out);
    try testing.expectEqual(@as(usize, 0), run.log.len);
}

test "F2e: math.randomseed() entropy form records and replays the seed" {
    const gpa = testing.allocator;
    // No-arg randomseed pulls one entropy seed through the .random_seed boundary,
    // so a draw afterward is reproduced byte-for-byte on replay of that one effect.
    const source =
        \\math.randomseed()
        \\print(math.random(1, 1000000))
    ;
    var sd = FixedSeed{ .value = 0xABCDEF };
    const rec = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer rec.deinit(gpa);
    // Exactly one effect: the no-arg randomseed's entropy draw (the later
    // math.random reuses that PRNG state, logging nothing).
    try testing.expectEqual(@as(usize, 1), rec.log.len);
    try testing.expectEqual(EffectKind.random_seed, rec.log[0].kind);
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
}

test "F2e: math.randomseed() with no injected source is RandomUnavailable" {
    const gpa = testing.allocator;
    // The no-arg entropy form needs a seed source, exactly like a lazy random().
    try testing.expectError(error.RandomUnavailable, effectRun(gpa, "math.randomseed()", .record, &.{}, null, null));
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

test "S-B: getenv/argv of non-UTF-8 host bytes raises a catchable error" {
    const gpa = testing.allocator;
    // An env with one valid arg and one invalid-UTF-8 arg.
    var fenv = FakeEnv{ .args = &.{ "prog", "\xFF\xFE" } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();

    try compileRun(gpa, &vm,
        \\print(getenv("HOME"))                 -- valid: still works
        \\print(argv(0))                          -- valid: "prog"
        \\local ok, e = pcall(getenv, "BADUTF8")  -- invalid env value → catchable error
        \\print(ok, type(e))
        \\local ok2, e2 = pcall(argv, 1)          -- invalid arg → catchable error
        \\print(ok2, type(e2))
    );
    // Valid reads pass through; the two invalid reads raise a string error value.
    try testing.expectEqualStrings(
        "/home/bart\nprog\nfalse\tstring\nfalse\tstring\n",
        sink.buffered(),
    );
}

test "S-B: a recorded non-UTF-8 getenv replays byte-identically (validate-after-log)" {
    const gpa = testing.allocator;
    const src =
        \\local ok, e = pcall(getenv, "BADUTF8")
        \\print(ok, type(e))
    ;
    // Record: the invalid bytes ARE logged (validation runs after logEffect), the
    // error is caught by pcall. Capture output + the effect log.
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    // Exactly one getenv effect logged, holding the raw invalid bytes.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.getenv, vm.effect_log.items[0].kind);

    // Replay the same VM's log (string result lives in this heap) with no host_env:
    // the native is not called, the logged bytes are re-validated → same raise,
    // same caught error, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.host_env = null;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-B: a recorded non-UTF-8 argv replays byte-identically (validate-after-log)" {
    const gpa = testing.allocator;
    const src =
        \\local ok, e = pcall(argv, 1)
        \\print(ok, type(e))
    ;
    // Record: arg 1 is invalid UTF-8. The bytes ARE logged (validation runs after
    // logEffect), the error is caught by pcall. argv is a distinct EffectKind from
    // getenv, so it exercises the same performEffect path under a different kind.
    var fenv = FakeEnv{ .args = &.{ "prog", "\xFF\xFE" } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.argv, vm.effect_log.items[0].kind);

    // Replay the same VM's log with no host_env: the native is not called, the
    // logged bytes are re-validated → same raise, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.host_env = null;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-B: loadfile of non-UTF-8 file content raises a catchable error" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "good.lua", .content = "return 1" },
        .{ .path = "bad.lua", .content = "\xFF\xFE" }, // not valid UTF-8
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\print((loadfile("good.lua"))())     -- valid file still compiles + runs
        \\print(pcall(loadfile, "bad.lua"))   -- invalid bytes → catchable error
    );
    // The valid file returns 1; the bad read raises a string error value caught by pcall.
    const out = sink.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "1\nfalse\t"));
}

test "S-B: a recorded non-UTF-8 loadfile replays byte-identically (validate-after-log)" {
    const gpa = testing.allocator;
    const src =
        \\local ok, e = pcall(loadfile, "bad.lua")
        \\print(ok, type(e))
    ;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "bad.lua", .content = "\xFF\xFE" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    // Exactly one file_read effect logged, holding the raw invalid bytes.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[0].kind);

    // Replay the same VM's log with no fs_source:
    // the logged bytes are re-validated -> same raise, same caught error, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.fs_source = null;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-B: populateArgs rejects a non-UTF-8 command-line argument" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A valid argv populates fine; an invalid one raises before it can enter `arg`.
    try vm.populateArgs(&.{ "prog", "ok" });
    try testing.expectError(error.LuaError, vm.populateArgs(&.{ "prog", "\xFF\xFE" }));

    // Atomicity: a malformed *later* arg must leave `arg[]` untouched, not
    // half-filled. Validate all args first, then mutate. Here arg[0]="prog" is
    // valid but arg[1] is invalid — the raise happens before any `tbl.set`, so a
    // fresh VM's `arg` table has neither entry.
    var vm2 = try Vm.init(gpa);
    defer vm2.deinit();
    try testing.expectError(error.LuaError, vm2.populateArgs(&.{ "prog", "\xFF\xFE" }));
    const argt = vm2.globals.get(try vm2.heap.internValue("arg"));
    try testing.expect(argt.isHeap() and argt.heapType() == .table);
    const tbl = table.Table.fromHeader(argt.asHeap());
    try testing.expect(tbl.get(Value.int(0)).isNil()); // "prog" never entered
    try testing.expect(tbl.get(Value.int(1)).isNil());
}

// ---------------------------------------------------------------------------
// S-C — Unicode-aware `upper`/`lower` + the `unicode_version` session effect.
// The case table is a compiled-in constant whose content churns between Unicode
// releases, so the active version is recorded once per session (at the first
// case op) and re-pinned on replay — a determinism gate. These tests prove (1)
// the version is pinned exactly once regardless of how many case ops run, (2) a
// recorded session replays byte-identically, and (3) a replay under a different
// version refuses (fatal, uncatchable) rather than silently diverging.
// ---------------------------------------------------------------------------

test "S-C: Unicode upper/lower is byte-identical across all modes" {
    try expectProgram(
        \\print(string.upper("café"), string.lower("ΑΒΓ"))
        \\print(#string.upper("héllo"))
        \\
    ,
        "CAFÉ\tαβγ\n5\n",
    );
}

test "S-C: case ops pin the unicode_version exactly once; replay is byte-identical" {
    const gpa = testing.allocator;
    const src =
        \\print(string.upper("café"))
        \\print(string.lower("ΑΒΓ"))
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("CAFÉ\nαβγ\n", recorded);
    // Two case operations, but the version is pinned only ONCE.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.unicode_version, vm.effect_log.items[0].kind);

    // Replay the same log → byte-identical (the recorded version equals this
    // binary's compiled version, so the re-pin passes and the tables match).
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.unicode_version_pinned = false;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-C: a replay log with a wrong unicode_version is a fatal, uncatchable error" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .replay;
    // A log claiming a Unicode version this binary's table was NOT built against.
    try vm.effect_log.append(gpa, .{ .kind = .unicode_version, .result = Value.int(0xDEAD) });
    // Even wrapped in pcall, the mismatch is a determinism fault: NOT catchable.
    try testing.expectError(error.UnicodeVersionMismatch, compileRun(gpa, &vm,
        \\print(pcall(string.upper, "x"))
    ));
}

test "S-C: a unicode_version log entry with a non-int (float) result is rejected, not asserted" {
    // The shared scalar shape-gate accepts int OR float, so a corrupt log could
    // park a float-tagged result on a .unicode_version entry. noteUnicodeVersion
    // must turn that into a clean UnicodeVersionMismatch rather than asserting in
    // asInt() on hostile bytes.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .replay;
    try vm.effect_log.append(gpa, .{ .kind = .unicode_version, .result = Value.float(16.0) });
    try testing.expectError(error.UnicodeVersionMismatch, compileRun(gpa, &vm,
        \\print(pcall(string.lower, "X"))
    ));
}

test "S-D: pattern matching over multibyte text is byte-identical across all modes" {
    // find/match/gmatch/gsub on a code-point-native string: character indices,
    // whole-code-point `.`, and multibyte gsub. Pattern ops are pure natives (JIT
    // trace barriers), so 8-mode parity is inherited — assert it. No host effect,
    // so this needs no recorded input.
    try expectProgram(
        \\local s = "héllo wörld"
        \\print(s:find("l"))            -- char start/end of first 'l'
        \\print(s:match("h(.)"))        -- captures the whole 'é'
        \\print(s:find("w()"))          -- start,end then position capture (char index)
        \\local t = {}
        \\for c in s:gmatch("%a") do t[#t+1] = c end
        \\print(#t, t[1], t[6])         -- ASCII-class only matches ASCII letters
        \\print((s:gsub(".", "x")))     -- every code point replaced once
        \\print(s:sub(s:find("wörld"))) -- find result composes with char-indexed sub
        \\
    ,
        "3\t3\n" ++
            "é\n" ++
            "7\t7\t8\n" ++
            "8\th\tr\n" ++
            "xxxxxxxxxxx\n" ++
            "wörld\n",
    );
}

// ---------------------------------------------------------------------------
// L-3 — `loadfile`/`dofile` + the `file_read` effect. A file read is a
// nondeterministic input (the filesystem differs between machines/runs), so the
// content rides the record/replay boundary exactly like `getenv`/`argv`: a heap
// string (or nil) logged on record, fed back on replay (the path is plain program
// data — only the content is the effect). These tests prove (1) `loadfile`/`dofile`
// work against an injected FS, (2) a record→serialize→replay round-trip reproduces
// the output with the FS DETACHED on replay (so the content provably came from the
// log, not disk), (3) a missing file is `(nil, msg)` for `loadfile` and a *raise*
// for `dofile`, and (4) no injected source is a clear `FsUnavailable`.
// ---------------------------------------------------------------------------

/// A deterministic in-memory filesystem for the `file_read` effect: a fixed map of
/// path → content. Any unknown path reads as `null` (couldn't open). Injected as a
/// `FsSource` so tests never touch the real disk.
const FakeFs = struct {
    entries: []const struct { path: []const u8, content: []const u8 },
    fn readFn(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| if (std.mem.eql(u8, e.path, path)) return e.content;
        return null;
    }
    fn source(self: *FakeFs) FsSource {
        return .{ .ctx = self, .read = &FakeFs.readFn };
    }
};

test "L-3: loadfile reads + compiles a file via the file_read effect (record)" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "lib.lua", .content = "return 6 * 7" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\local f = loadfile("lib.lua")
        \\print(f())
    );
    try testing.expectEqualStrings("42\n", sink.buffered());
    // Exactly one file_read effect logged (the single loadfile read).
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[0].kind);
}

test "L-3: dofile runs the file and returns its results (record)" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "answer.lua", .content = "local a, b = ...\nreturn 40 + 2, 'ok'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\print(dofile("answer.lua"))
    );
    // dofile runs the chunk with no args; the chunk returns two values.
    try testing.expectEqualStrings("42\tok\n", sink.buffered());
}

test "L-3: record→serialize→replay reproduces output with the FS detached" {
    const gpa = testing.allocator;
    const effectser = @import("effectser.zig");
    // `add.lua` is a vararg chunk loaded by `loadfile` and then called with args;
    // `const.lua` is run directly by `dofile`. Two distinct file_read effects.
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "add.lua", .content = "local a, b = ...\nreturn a + b" },
        .{ .path = "const.lua", .content = "return 100" },
    } };
    const driver: [:0]const u8 =
        \\print(loadfile("add.lua")(3, 4))
        \\print(dofile("const.lua"))
    ;

    // --- record: run against the in-memory FS, capture output + serialized log ---
    var rec_out_buf: [128]u8 = undefined;
    var log_bytes: []u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rec_out_buf);
        vm.out = &sink;
        vm.effect_mode = .record;
        vm.fs_source = ffs.source();
        try compileRun(gpa, &vm, driver);
        // Two file reads (loadfile + dofile), both file_read effects.
        try testing.expectEqual(@as(usize, 2), vm.effect_log.items.len);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[0].kind);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[1].kind);
        log_bytes = try effectser.encodeFile(gpa, vm.effect_log.items);
    }
    defer gpa.free(log_bytes);

    // --- replay: a fresh VM with NO fs_source. The serialized log is decoded into
    // its heap and fed back; if any read reached for disk it would be FsUnavailable
    // (no source) — so byte-identical output proves the content came from the log. ---
    var rep_out_buf: [128]u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rep_out_buf);
        vm.out = &sink;
        const log = try effectser.decodeFile(gpa, &vm.heap, log_bytes);
        defer gpa.free(log);
        try vm.effect_log.appendSlice(gpa, log);
        vm.effect_mode = .replay;
        // No fs_source set on purpose.
        try compileRun(gpa, &vm, driver);
    }
    // loadfile("add.lua")(3,4) = 7; dofile("const.lua") = 100.
    try testing.expectEqualStrings("7\n100\n", rep_out_buf[0..6]);
    // Record and replay produced byte-identical output.
    try testing.expectEqualStrings(rep_out_buf[0..6], rec_out_buf[0..6]);
}

test "L-3: loadfile of a missing file is (nil, msg); dofile raises" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} }; // empty FS: every path is missing
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\local f, e = loadfile("nope.lua")
        \\print(f, e)
        \\local ok, err = pcall(dofile, "nope.lua")
        \\print(ok, err)
    );
    // loadfile → (nil, "cannot open nope.lua"); dofile raises the same message,
    // caught by pcall as (false, msg). The message is a function of the path only
    // (no host errno), so it is deterministic.
    try testing.expectEqualStrings(
        "nil\tcannot open nope.lua\nfalse\tcannot open nope.lua\n",
        sink.buffered(),
    );
}

test "L-3: loadfile/dofile with no fs_source injected is FsUnavailable" {
    const gpa = testing.allocator;
    inline for (.{ "loadfile(\"x.lua\")", "dofile(\"x.lua\")" }) |s| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.effect_mode = .record; // no fs_source set
        try testing.expectError(error.FsUnavailable, compileRun(gpa, &vm, s));
    }
}

test "L-3: a non-string path argument is a bad-argument error" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();
    // A numeric path raises `bad argument` (raised, not (nil,msg)) — matching Lua.
    try testing.expectError(error.LuaError, compileRun(gpa, &vm, "loadfile(42)"));
}

// ---------------------------------------------------------------------------
// P3 — `require` / `package`. The module system is built on the existing
// `fs_source` + `file_read` effect (no new seam, no new effect kind): module
// content is the only nondeterministic input, so `require` programs record/replay
// byte-identically and snapshot like any other heap state. These tests inject an
// in-memory `FakeFs` (the default `package.path` resolves to `./?.lua` etc.) and
// prove: load+cache (read once), preload beats path, dotted-name→path mapping, the
// not-found message, an empty module defaulting to `true`, transitive require,
// record→replay parity, and a user-replaced searcher closure.
// ---------------------------------------------------------------------------

/// Build a VM wired with `out`, `.record` mode, and an injected `FakeFs`, then run
/// `source`. Shared scaffolding for the require tests. `sink` must outlive the call.
fn requireRun(gpa: std.mem.Allocator, vm: *Vm, ffs: *FakeFs, sink: *io.Writer, source: [:0]const u8) !void {
    vm.out = sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();
    try compileRun(gpa, vm, source);
}

test "P3: require loads, caches, and reads the file exactly once" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.lua", .content = "return {v = 99}" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\local a = require("m")
        \\local b = require("m")
        \\print(a.v, a == b)
    );
    try testing.expectEqualStrings("99\ttrue\n", sink.buffered());
    // The preload searcher returns a string (no read); the path searcher reads
    // "./m.lua" once. The second `require` is served from `package.loaded` → still
    // exactly one `file_read` effect.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[0].kind);
}

test "P3: package.preload beats the path searcher and seeds package.loaded" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.lua", .content = "return 'from-file'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\package.preload["m"] = function(name) return "preload:" .. name end
        \\print(require("m"))
        \\print(package.loaded.m)
    );
    try testing.expectEqualStrings("preload:m\npreload:m\n", sink.buffered());
    // Preload won before the path searcher ran → no file was ever read.
    try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);
}

test "P3: a dotted module name maps dots to the path separator" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./a/b.lua", .content = "return 'nested'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("a.b"))
    );
    try testing.expectEqualStrings("nested\n", sink.buffered());
}

test "P3: require of a missing module raises the accumulated not-found message" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} }; // empty FS
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\local ok, e = pcall(require, "ghost")
        \\print(ok)
        \\print(e)
    );
    // Every searcher contributes a line: preload's "no field", then the two path
    // candidates from the default `package.path`.
    try testing.expectEqualStrings(
        "false\n" ++
            "module 'ghost' not found:\n" ++
            "\tno field package.preload['ghost']\n" ++
            "\tno file './ghost.lua'\n" ++
            "\tno file './ghost/init.lua'\n",
        sink.buffered(),
    );
}

test "P3: a module that returns nothing caches as true" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.lua", .content = "local x = 1" }, // returns no value
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("m"))
        \\print(package.loaded.m)
    );
    try testing.expectEqualStrings("true\ntrue\n", sink.buffered());
}

test "P3: transitive require (a loader requires another module)" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./top.lua", .content = "local s = require('sub')\nreturn s + 1" },
        .{ .path = "./sub.lua", .content = "return 41" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("top"))
    );
    try testing.expectEqualStrings("42\n", sink.buffered());
}

test "P3: record→serialize→replay reproduces a require program with the FS detached" {
    const gpa = testing.allocator;
    const effectser = @import("effectser.zig");
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./greeter.lua", .content = "local m = {}\nfunction m.hi(w) return 'hi ' .. w end\nreturn m" },
    } };
    const driver: [:0]const u8 =
        \\local g = require("greeter")
        \\print(g.hi("lune"))
    ;

    var rec_out_buf: [64]u8 = undefined;
    var log_bytes: []u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rec_out_buf);
        try requireRun(gpa, &vm, &ffs, &sink, driver);
        try testing.expectEqualStrings("hi lune\n", sink.buffered());
        // One file_read (the path searcher found "./greeter.lua" on the first probe).
        try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
        log_bytes = try effectser.encodeFile(gpa, vm.effect_log.items);
    }
    defer gpa.free(log_bytes);

    var rep_out_buf: [64]u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rep_out_buf);
        vm.out = &sink;
        const log = try effectser.decodeFile(gpa, &vm.heap, log_bytes);
        defer gpa.free(log);
        try vm.effect_log.appendSlice(gpa, log);
        vm.effect_mode = .replay; // NO fs_source — content must come from the log
        try compileRun(gpa, &vm, driver);
        try testing.expectEqualStrings("hi lune\n", sink.buffered());
    }
    try testing.expectEqualStrings(rec_out_buf[0.."hi lune\n".len], rep_out_buf[0.."hi lune\n".len]);
}

test "P3: a user-replaced searcher (a Lua closure) is honoured" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    // Replace the preload searcher (index 1) with a closure returning a loader.
    try requireRun(gpa, &vm, &ffs, &sink,
        \\package.searchers[1] = function(name)
        \\  return function() return "custom:" .. name end
        \\end
        \\print(require("anything"))
    );
    try testing.expectEqualStrings("custom:anything\n", sink.buffered());
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
        \\print(string.sub("hello", 2, 4), string.codepoint("A"))
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

test "e2e: code-point-native strings are byte-identical across all modes" {
    // S-B (design doc 06): #, sub, reverse, char, codepoint, codes, %c, %.Ns and
    // \u{} all index by Unicode code point, not byte. All of these run tier-0 (the
    // recorder aborts on `len`, and the rest are native string calls), so the
    // output must be identical across {off, record_only, noopt, record_execute,
    // native} × stress.
    try expectProgram(
        \\print(#"héllo", #"ab😀")
        \\print(("héllo"):sub(2, 2), ("héllo"):sub(2))
        \\print(("ab😀"):reverse())
        \\print(string.char(0x1F600), string.char(72, 0xE9))
        \\print(("héllo"):codepoint(2), string.codepoint("ab😀", 3))
        \\local idx, cps = "", ""
        \\for i, c in ("aé"):codes() do idx = idx .. i; cps = cps .. c .. " " end
        \\print(idx, cps)
        \\print(string.format("%c%c", 0x41, 0x1F600))
        \\print(string.format("%.2s", "héllo"))
        \\print("\u{E9}" == "é", "\u{1F600}" == "😀")
    ,
        "5\t3\n" ++
            "é\téllo\n" ++
            "😀ba\n" ++
            "😀\tHé\n" ++
            "233\t128512\n" ++
            "12\t97 233 \n" ++
            "A😀\n" ++
            "hé\n" ++
            "true\ttrue\n",
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
    // `for i=1,5000 do t[i]=i end` eager-commits `.u8` (the byte lane — values
    // start in [0,255]), records a u8 append trace, then crosses u8→i16 at i=256
    // (value 256 escapes the byte range). Pre-eviction the dead u8 trace lingered
    // (consuming a per-anchor slot) and the loop ran the i16 tail under a
    // permanently-failing guard. Widen-eviction retires the u8 trace the first time
    // its `guard_lane` fails against the now-wider live array, and reopens the
    // anchor so the *stable* i16 lane records + compiles. We assert the surviving
    // append trace guards i16, NOT u8, proving the dead narrow trace was evicted and
    // the wider one took its place.
    const arr = @import("array.zig");
    const u8_ord = @intFromEnum(arr.Lane.u8);
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
    var saw_u8_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op != .astore_append) continue;
            // The append's lane lives in its own `aux`; the leading guard_lane
            // carries the same ordinal. Read the op directly.
            if (ins.aux == i16_ord and tr.native == .compiled) saw_i16_append = true;
            if (ins.aux == u8_ord) saw_u8_append = true;
        }
    }
    try testing.expect(saw_i16_append); // the stable wider lane records + compiles
    try testing.expect(!saw_u8_append); // the dead narrow trace was evicted
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
