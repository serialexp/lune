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
const array = @import("array.zig");
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
    /// A fresh top-level `run`/`start` was entered on a VM whose call stack is not
    /// empty (`depth != 0`) — a **dirty** entry. `run`/`start` allocate and push a
    /// fresh top-level frame; they never continue a live stack (suspension resume
    /// goes through `exec()`, not `start()`). So a non-empty stack at entry is caller
    /// misuse: a suspended or faulted VM re-driven through the wrong door. Rejected
    /// fail-closed BEFORE any epoch mutation (doc 17, H-3 / 9-A(ii)) so the dirty
    /// entry can't corrupt the resumable epoch. Release-enforced (an assert would
    /// vanish under ReleaseFast).
    DirtyTopLevelEntry,
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

comptime {
    // `pure ⇒ !effect` (doc 17, H-4 / 9-A(i)). `pure` and `effect` are independent
    // nullable fields (`function.zig`), and a JIT `recCall` inlines a `pure` builtin
    // as a leaf op — so a builtin that set BOTH would inline a host effect past the
    // `.host_barrier`, silently committing it on-trace. Enforce the invariant
    // structurally over the whole static registry (covers `manual` entries, which
    // carry the fields even without an install slot) — this catches it at compile
    // time, not one install-site assert `manual`/restore/package paths would bypass.
    for (base_natives) |bn| {
        if (bn.pure != null and bn.effect != null)
            @compileError("builtin '" ++ bn.name ++ "' sets both `pure` and `effect`; pure ⇒ !effect must hold (doc 17 H-4)");
    }
}

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
    /// Transient activation identity for JIT-tiering state. Assigned exactly once
    /// at the physical frame-push choke point; traces never read or mutate it in
    /// A-iii. Keyframes deliberately omit it and restore re-keys live frames.
    call_seq: u64,
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
pub const SuspendCtl = struct {
    min_depth: u32 = 0,
    after_safepoints: u64 = 0,
    /// Optional tier-independent logical cut: suspend at the first otherwise
    /// eligible tier-0 boundary at or after this many effects have committed.
    after_committed_effects: ?u64 = null,
};

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
    /// `"__sar"` — `a ~>> b` (arithmetic right shift; lune extension).
    sar: Value = Value.nil(),
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
    /// Next transient activation identity. Monotonic for this VM run; exhaustion
    /// is checked at frame push so a wrapped/duplicate identity is never exposed.
    next_call_seq: u64 = 0,
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
    /// Mode-independent logical count of successfully committed host effects.
    /// Unlike `effect_cursor` (replay-only), this advances once in off, record,
    /// and replay through `onEffectCommitted`. It is replay-driver state rather
    /// than semantic keyframe state and is not serialized.
    committed_effect_seq: u64 = 0,
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

    /// Host-registered proto trees kept GC-alive across the **compile→run window**
    /// (docs/design/03 §"Chunk-constant rooting"). A compiled `Chunk`'s interned
    /// string constants are otherwise rooted only transitively via a live closure
    /// (`gc.markProtoConstants`, reached from a frame closure) — so a host that
    /// compiles chunk B, then runs chunk A (which GCs), then runs B would have B's
    /// literals swept before B ever runs, dangling its `load_const`s. `retainChunk`
    /// adds B's root proto here; `forEachRootHeader` roots its whole tree's heap
    /// constants in BOTH the `.gc` and `.snapshot` walks (the latter so their ids
    /// survive a snapshot straddle — retained chunks are host-authored program
    /// image, re-supplied on restore like the main `root`).
    ///
    /// **Borrows only** (non-owning): the host still owns each `Chunk` and frees it.
    /// Contract: `releaseChunk(proto)` BEFORE the host `Chunk.deinit()`s the tree,
    /// and one `retainChunk` per `releaseChunk`. The snapshot guarantee is scoped to
    /// UNRUN chunks (once run, a closure roots the constants → `releaseChunk`).
    retained_chunks: std.ArrayList(*const Proto) = .empty,

    /// A runtime-compiled chunk owned by the VM: the `Chunk` (whose arena owns the
    /// proto tree) and the NUL-terminated source the protos borrow.
    pub const LoadedChunk = struct {
        chunk: compiler.Chunk,
        source: [:0]u8,
    };

    /// Keep a host-compiled proto tree's constants GC-rooted across the compile→run
    /// window (see `retained_chunks`). Borrow only — the caller keeps ownership and
    /// MUST `releaseChunk` before freeing the `Chunk`.
    pub fn retainChunk(self: *Vm, proto: *const Proto) Error!void {
        try self.retained_chunks.append(self.gpa, proto);
    }

    /// Drop a `retainChunk` root. `orderedRemove` (NOT `swapRemove`) so surviving
    /// borrows keep their relative order — retained constants serialize in
    /// root-discovery order, so reordering survivors would change snapshot bytes
    /// (docs/design/03). A pointer not currently retained is a no-op.
    pub fn releaseChunk(self: *Vm, proto: *const Proto) void {
        for (self.retained_chunks.items, 0..) |p, i| {
            if (p == proto) {
                _ = self.retained_chunks.orderedRemove(i);
                return;
            }
        }
    }

    /// Root every heap constant in a proto tree through `cb` (mirrors
    /// `gc.markProtoConstants`, but emits headers so it serves both the collector and
    /// the snapshot walk). Compiler-produced protos only (the `retainChunk` contract):
    /// the compiler emits exactly interned-string and scalar constants, never a
    /// `row_view` fat value — so `isHeap → asHeap` is complete, matching the item-5
    /// trace-const loop.
    fn rootProtoConsts(
        proto: *const Proto,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), *object.GcHeader) void,
    ) void {
        for (proto.constants) |v| if (v.isHeap()) cb(ctx, v.asHeap());
        for (proto.protos) |child| rootProtoConsts(child, ctx, cb);
    }

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
        // Borrows only — free the list, never the borrowed chunks (the host owns
        // those and must have released them before its own `Chunk.deinit`).
        self.retained_chunks.deinit(self.gpa);
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

    /// Cross-frame tracing cluster sub-lever 1: seed a trace's synthetic
    /// upvalue/global inputs and return the executor `RegWindow` widened to cover
    /// them, or `null` if the widened window would overflow the register stack
    /// (decline the entry → tier-0 owns the loop). An input-free trace returns the
    /// caller's narrow window unchanged (the common case, no allocation/seeding).
    ///
    /// Each input is loop-invariant for the traced region, so it is re-resolved and
    /// re-seeded on *every* entry (`upvalGet`/`globals.get`, against the anchor
    /// frame's `closure`/`proto` — the recorder only ever snapshots anchor-frame
    /// reads). The synthetic slots live in the dead scratch above the anchor frame
    /// window (`[base+num_registers, …)`), which holds no live child frame at a
    /// loop back-edge entry, so writing them clobbers nothing tier-0 will read. The
    /// trace's `slot_load`s read them back; a `guard_func` (or a downstream type
    /// guard) deopts if the snapshot changed since recording.
    ///
    /// `native_eligible` (caller pre-set to `true`) is cleared iff a `hash_cell`
    /// seed (H1, doc 11 §5) fails to resolve/validate at this entry — the table
    /// isn't a metatable-free table, the constant key is absent, or the recorded
    /// population changed. The caller then runs this entry on **tier-1a** instead of
    /// native: the oracle re-derives the cell from `href`'s operands and side-exits
    /// at the same `guard_table`/`guard_hash` native would have, so the outcome is
    /// byte-identical (zero-iteration exit → tier-0 re-runs). `upvalue`/`global`
    /// seeds never touch it (their staleness is caught by an ordinary guard on the
    /// trace, not at seed time).
    fn seedTraceInputs(self: *Vm, ct: *const trace.Trace, base: usize, closure: *const function.Closure, proto: *const Proto, narrow: RegWindow, native_eligible: *bool) ?RegWindow {
        if (ct.inputs.len == 0) return narrow;
        var count: usize = proto.num_registers;
        for (ct.inputs) |seed| count = @max(count, @as(usize, seed.slot) + 1);
        if (base + count > self.regCapacity()) return null;
        for (ct.inputs) |seed| {
            const v = switch (seed.kind) {
                .upvalue => self.upvalGet(closure.upvalues[seed.source]),
                .global => self.globals.get(proto.constants[seed.source]),
                .hash_cell => blk: {
                    // Resolve the loop-invariant value-cell pointer and stash it raw
                    // for the native prologue (`[rsi + slot*8]`). Validate exactly the
                    // oracle's per-iteration `guard_hash`: metatable-free, key present,
                    // population unchanged. A `0` result means "ineligible" — a real
                    // cell pointer is never null — so native declines and tier-1a owns
                    // this entry. The slot is tagged `.int` so the raw pointer is never
                    // mistaken for a `GcHeader` by a GC scan of this dead scratch.
                    const vtab = self.regGet(base + seed.table_reg);
                    var cell_bits: u64 = 0;
                    if (vtab.isHeap() and vtab.heapType() == .table) {
                        const tbl = table.Table.fromHeader(vtab.asHeap());
                        if (tbl.metatable == null) {
                            if (tbl.fieldPtr(ct.consts[seed.source])) |cell| {
                                if (tbl.hash.count() == seed.expected_count)
                                    cell_bits = @intFromPtr(cell);
                            }
                        }
                    }
                    if (cell_bits == 0) native_eligible.* = false;
                    break :blk Value{ .tag = .int, .payload = .{ .bits = cell_bits } };
                },
            };
            self.regSet(base + seed.slot, v);
        }
        return self.frameWindow(base, count);
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
        native.pure = bn.pure; // null unless a JIT-inlinable pure builtin (e.g. sqrt)
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

    /// 2c-F (doc 17): a fresh top-level execution epoch must not inherit armed
    /// native links from a prior completed run on this VM. An armed exit slot left
    /// over from a previous epoch could still point at a live, in-cache child body
    /// and fire a native→native handoff on this run's first hot entry — bypassing
    /// the dispatcher's safepoint/GC boundary with fresh-run register/stack state
    /// the handoff never established. That is the layout-dependent rerun hazard the
    /// codex `gpt-5.6-sol` review flagged as a blocker: the exit-slot hardening
    /// (`armNativeLink` derive-not-trust + `compileImpl` in-page validation) proves
    /// address provenance but NOT dynamic-entry validity across an epoch, so a
    /// stale-but-in-bounds link can still fire. Reset every armed slot to
    /// `shared_exit` here; links re-arm from observations made during THIS run.
    /// Applies ONLY to the fresh `run`/`start` entry — NOT `exec()` resume after a
    /// `.suspended` (a continuation of the SAME epoch, where the dispatcher's
    /// observation-window disarm, 2.3c-0e, governs) and not nested function calls.
    /// Begin a fresh top-level tiering epoch (every `run`/`start`). Fail-closed on a
    /// dirty entry (`depth != 0`) BEFORE mutating any epoch state — see
    /// `Error.DirtyTopLevelEntry`. A genuine fresh entry always has `depth == 0`
    /// (init 0; a successful top-level return decrements back to 0; suspend/error
    /// deliberately leave frames live, and those resume via `exec()`, never here).
    /// When the region-accounting map lands (doc 17, H-3 / Increment 3) its
    /// `clearRetainingCapacity()` goes here too, after this same guard.
    fn beginTopLevelEpoch(self: *Vm) Error!void {
        if (self.depth != 0) return error.DirtyTopLevelEntry;
        self.trace.disarmAllLinks();
        // Retire the whole trace cache at the epoch boundary (doc 17 H-2 part 3): a
        // trace's proto-literal string konsts must not root interned strings across a
        // top-level run, or a record mode carries a static literal alive into the next
        // epoch while `.off` sweeps it, diverging the re-interned id. Runs AFTER
        // `disarmAllLinks` (which empties `armed_links`) so no inbound native link
        // touches a freed trace. A no-op for the common single-`run` case (empty cache).
        self.trace.clearCache();
    }

    pub fn run(self: *Vm, proto: *const Proto) Error!Value {
        // JIT coverage time attribution (gated): bracket the whole run for the
        // denominator (`run_cycles`) and seed `last_event_tsc` so the first tier-0
        // span isn't a bogus delta-from-zero. Host TSC only (0 on wasm). See
        // `trace.readCycles` for the determinism argument (diagnostic, report-only).
        const cov_run_start = if (self.trace.config.coverage) trace.readCycles() else 0;
        if (self.trace.config.coverage) self.trace.last_event_tsc = cov_run_start;
        defer if (self.trace.config.coverage) {
            self.trace.run_cycles +|= trace.cycleDelta(trace.readCycles(), cov_run_start);
        };
        try self.beginTopLevelEpoch();
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
        try self.beginTopLevelEpoch();
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
                .band, .bor, .bxor, .shl, .shr, .sar => try bitwiseFaultMessage(arena, firstNonInteger(regs.get(instr.b), regs.get(instr.c))),
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
        const call_seq = self.next_call_seq;
        if (call_seq == std.math.maxInt(u64)) @panic("VM call_seq space exhausted");
        self.next_call_seq = call_seq + 1;
        self.frames[self.depth] = .{
            .closure = closure,
            .call_seq = call_seq,
            .base = base,
            .pc = 0,
            .ret_dest = ret_dest,
            .ret_count = ret_count,
            .varargs_base = varargs_base,
            .varargs_count = varargs_count,
        };
        self.depth += 1;
        self.stack_top = base + nreg;
        self.trace.setRegionContext(self.depth, call_seq);
    }

    /// Drop transient region accounting for every physical activation destroyed
    /// by an explicit depth restore (pcall/xpcall unwind). Call before publishing
    /// the smaller depth so the dying frames' activation ids are still available.
    pub fn dropRegionActivationsFromDepth(self: *Vm, new_depth: u32) void {
        if (new_depth > self.depth) @panic("region activation unwind raised depth");
        var i = self.depth;
        while (i > new_depth) {
            i -= 1;
            self.trace.dropRegionActivation(self.frames[i].call_seq);
        }
        if (new_depth > 0)
            self.trace.setRegionContext(new_depth, self.frames[new_depth - 1].call_seq);
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
        self.forEachRootHeader(.gc, &self.heap, gc.Heap.markHeader);
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
    ///   5. trace constants (**`.gc` kind ONLY** — see `RootKind`) — a cached trace
    ///      (or the in-progress recording) may hold heap values in its const pool
    ///      (e.g. a string `load_const`). A cached trace can outlive its proto's
    ///      reachability, so its consts must be GC-liveness roots in their own right
    ///      (docs/design/03-gc-memory.md). They are DELIBERATELY excluded from the
    ///      `.snapshot` walk (doc 17, H-2 / G-2): a heap object reachable *only* via
    ///      a trace const is (a) unnamable by the restored guest (no other
    ///      reference), and (b) tiering-dependent — a `.off`/tier-0 run never
    ///      records the trace, so the object is collected there. Serializing it
    ///      would make snapshot bytes differ by JIT mode. Excluding it makes the
    ///      snapshot JIT-independent by construction and cannot dangle (a sole-root
    ///      object has no other pointer in the serialized graph).
    ///   6. effect-log heap results — a string-valued effect (`getenv`/`argv`)
    ///      parked in `effect_log` must outlive collection until it is serialized
    ///      (record) or fed back to the program (replay). Without this root, the
    ///      sweep would de-intern and free an otherwise-unreferenced result string.
    pub const RootKind = enum {
        /// The collector's root set: every live pointer, including trace-const
        /// GC-liveness roots (a cached trace's const must not be swept while the
        /// trace can still execute).
        gc,
        /// The snapshot's *semantic* root set: what the restored guest can name.
        /// Excludes trace consts (transient JIT state; see item 5) so snapshot
        /// bytes are identical whether or not the JIT recorded anything.
        snapshot,
    };
    pub fn forEachRootHeader(
        self: *Vm,
        comptime kind: RootKind,
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
        // Host-retained chunks (docs/design/03 §"Chunk-constant rooting"): keep a
        // compiled-but-not-yet-run chunk's interned constants alive across the
        // compile→run window. Rooted in BOTH walks (unlike trace consts, item 5):
        // membership is a mode-invariant host action, so serializing their ids in the
        // `.snapshot` walk is byte-identical across all modes and lets a snapshot
        // straddle preserve constant-id continuity (the host re-supplies + re-retains
        // on restore, like the main `root`). Discovery order = retain order.
        for (self.retained_chunks.items) |proto| rootProtoConsts(proto, ctx, cb);
        // Trace consts are GC-liveness roots ONLY — never snapshot semantic roots
        // (doc 17 H-2/G-2). See the item-5 note above.
        if (kind == .gc) {
            for (self.trace.cache.items) |t| {
                for (t.consts) |v| if (v.isHeap()) cb(ctx, v.asHeap());
            }
            if (self.trace.isRecording()) {
                for (self.trace.rec.consts.items) |v| if (v.isHeap()) cb(ctx, v.asHeap());
            }
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
        errdefer self.trace.clearPendingExitAnchor();
        while (true) {
            const step = if (self.runFastPath())
                try self.execImpl(.fast, stop_depth)
            else
                try self.execImpl(.full, stop_depth);
            switch (step) {
                .finished => |fr| {
                    self.trace.clearPendingExitAnchor();
                    return .{ .finished = fr };
                },
                .suspended => {
                    self.trace.clearPendingExitAnchor();
                    return .suspended;
                },
                .switch_mode => continue,
            }
        }
    }

    /// May the dispatch loop run with the off-by-default prologue hooks compiled
    /// out? Only when none is live: no pending suspend cut, no replay line
    /// recording, not mid-trace-recording, and no continuation recording pending
    /// activation. The GC safepoint is *not* gated on here — `.fast` keeps it, so
    /// `gc_stress` stays correct without forcing `.full`. These flags are stable
    /// across an `exec` invocation except `isRecording()` (arms at a back-edge,
    /// caught there) and `pending_exit_anchor` (set on a productive side-exit): a
    /// pending continuation must hold `.full` so the dispatch-prologue activation
    /// hook (`maybeStartContinuation`, `.full`-only) fires when tier-0's
    /// final-iteration deopt-replay reaches the non-header anchor pc. The window is
    /// short — the hook consumes the pending anchor at the very next reach of that
    /// pc — after which `.fast` resumes.
    inline fn runFastPath(self: *const Vm) bool {
        return !(self.suspend_ctl != null or self.record_safepoint_lines or
            self.trace.isRecording() or self.trace.pending_exit_anchor != null or
            self.trace.pending_replay_anchor != null);
    }

    /// Per-instruction prologue + fetch for the threaded dispatch loop, factored
    /// out of `execImpl` so every opcode arm can re-dispatch with `continue :sw
    /// (try self.nextOp(...) orelse return .suspended)`. Runs **between every pair
    /// of instructions in both modes**, so GC timing, `safepoint_seq` counting,
    /// suspend points, replay-line recording, and the trace recording mirror stay
    /// byte-identical to the old centralized `while`-loop prologue.
    ///
    /// Returns the next opcode to dispatch, or `null` when a `.full`-mode suspend
    /// fires (the caller turns that into `return .suspended`). `frame.pc`,
    /// `cur_pc`, `instr`, and `a` are written through the out-pointers; `pc` is
    /// advanced past the fetched instruction. `inline` so the loop locals stay in
    /// registers and the `.fast` instantiation compiles the full-only hooks out.
    inline fn nextOp(
        self: *Vm,
        comptime mode: ExecMode,
        frame: *CallFrame,
        closure: *const Closure,
        proto: *const Proto,
        code: []const Instr,
        regs: RegWindow,
        pc: *usize,
        cur_pc: *usize,
        instr: *Instr,
        a: *usize,
    ) Error!?bytecode.OpCode {
        // GC safepoint — see the long note at the call-equivalent site in the old
        // loop: every live value is rooted here, the collection is non-moving, and
        // it is suppressed while a multret result set is pending.
        if (!self.reg_top_pending and self.heap.shouldCollect()) self.collect();

        // Free-running safepoint counter — must advance every instruction in both
        // modes so replay cuts land identically (keyframeser reads it as the total).
        self.safepoint_seq += 1;

        // Replay line-index recorder — `.full` only (compiled out in `.fast`).
        if (mode == .full and self.record_safepoint_lines) {
            const sp_src = if (proto.source.len > 0) proto.source else self.source;
            const sp_line: u32 = if (pc.* < proto.spans.len)
                compiler.lineFromOffset(sp_src, proto.spans[pc.*].start)
            else
                0;
            try self.safepoint_lines.append(self.gpa, sp_line);
        }

        // Mid-execution suspend point — an instruction boundary. `.full` only.
        if (mode == .full) {
            if (self.suspend_ctl) |sc| {
                const effect_cut_reached = if (sc.after_committed_effects) |n|
                    self.committed_effect_seq >= n
                else
                    true;
                if (!self.reg_top_pending and effect_cut_reached and
                    self.safepoint_seq >= sc.after_safepoints and self.depth >= sc.min_depth)
                {
                    std.debug.assert(self.pending_error == null);
                    frame.pc = pc.*;
                    return null;
                }
            }
        }

        const cur = pc.*;
        cur_pc.* = cur;
        // A-iv logical-region departure observer. The empty-map common path does
        // not call into the observer and cannot allocate; activation context is
        // refreshed only on frame reload (execImpl/push/pop), not per instruction.
        // A-vii-e.2: with a region live, `observeFast` answers the overwhelmingly
        // common survive verdict inline (bit test against the cached hot span) so
        // the loop never pays the observer's call frame; anything it cannot answer
        // falls through to the pre-e.2 call, unchanged. The empty-map test stays
        // FIRST and stays the only unconditional work: probing the hot cache ahead
        // of it would touch a second `TraceState` line on every instruction of
        // every region-free program, which measured +11% on scimark-sor tier-0.
        if (self.trace.regionProfitCount() != 0 and
            !self.trace.observeFast(proto.id, @intCast(cur), self.depth, frame.call_seq))
            self.trace.observeRegionProgramPoint(proto.id, @intCast(cur), self.depth, frame.call_seq);
        // Keep the faulting location recoverable (see the old loop's note).
        frame.pc = cur;
        const i = code[cur];
        pc.* = cur + 1;
        instr.* = i;
        a.* = i.a;

        // Nested-loop continuation (Phase 1): a continuation recording armed by a
        // hot inner loop-done exit begins at its (non-header) anchor pc, which
        // tier-0 reaches here — *before* the mirror below, so the anchor
        // instruction is recorded as the trace's first op (exactly as a root
        // trace's anchor is). A cheap optional-null read when nothing is pending.
        if (mode == .full and self.trace.pending_exit_anchor != null) {
            self.trace.maybeStartContinuation(proto, @intCast(cur));
        }

        // Coherent-state chaining (doc 16, Phase 2): a prime side-trace armed on a
        // productive branch-guard exit begins at the failed trace's own coherent
        // anchor (the outer header), which tier-0 reaches here with registers already
        // coherent — no deopt-replay needed. Same `.full`-only, before-the-mirror
        // placement so the anchor instruction is the recording's first op.
        if (mode == .full and self.trace.pending_replay_anchor != null) {
            self.trace.maybeStartReplaySide(proto, @intCast(cur));
        }

        // Recording mirror — `.full` only. Mirrors this instruction (and its
        // observed operand types) into the trace IR *before* tier-0 executes it.
        if (mode == .full and self.trace.isRecording()) {
            const resolved: Value = switch (i.op) {
                .get_upval => self.upvalGet(closure.upvalues[i.b]),
                .get_global => self.globals.get(proto.constants[i.b]),
                else => Value.nil(),
            };
            self.trace.recordInstr(i, regs, proto, @intCast(pc.*), resolved);
        }
        return i.op;
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
        self.trace.setRegionContext(self.depth, frame.call_seq);
        // Threaded-dispatch loop locals. `step` writes `cur_pc`/`instr`/`a` and
        // advances `pc` on every fetch; declared here so each opcode arm can
        // re-dispatch with `continue :sw`. Always set by `step` before any use.
        var cur_pc: usize = undefined;
        var instr: Instr = undefined;
        var a: usize = undefined;

        // `outer:` is retained for the back-edge epilogue's two `continue :outer`
        // deopt re-entries and the post-epilogue header re-fetch. The central
        // dispatch is now a labeled `sw: switch`: straight-line arms thread
        // directly to the next instruction via `continue :sw (try self.nextOp(...)
        // orelse return .suspended)`, and the epilogue below is reached *only* via
        // `break :sw` from a jump arm on a real loop back-edge. Everything else
        // threads or `continue :outer`s: `.call`'s Lua-function and `.ret` arms
        // reload frame locals and `continue :outer`; `.call`'s native/`__call`
        // arms thread with an explicit `continue :sw` tail (they advance `pc` past
        // the call like any straight-line op). The whole per-instruction prologue
        // (GC safepoint, `safepoint_seq`, suspend, replay, recording mirror) lives
        // in `nextOp`, so it still runs between every pair of instructions in both
        // modes — byte-identical to the old inlined prologue.
        outer: while (true) {
            sw: switch (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended) {
                // ---- loads & moves ---- (direct lane writes; no `Value` built)
                .load_nil => {
                    regs.setNil(a);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .load_bool => {
                    regs.setBool(a, instr.b != 0);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .load_int => {
                    regs.setInt(a, instr.aux);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .load_const => {
                    regs.set(a, proto.constants[instr.b]);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .move => {
                    regs.copy(a, instr.b);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- arithmetic (semantics live in arith.zig) ----
                // The hot both-int / both-float cases compute on the raw payload
                // lanes directly (no 16-byte `Value` materialized — the SoA win);
                // every other operand mix falls back to the exact `arith.*` +
                // `arithMeta` path (mixed promotion, `__add`/… metamethod, or a
                // propagated error like `DivisionByZero`). Numbers carry no
                // metatable, so the common path never touches dispatch.
                .add => {
                    try self.binNum(regs, a, instr.b, instr.c, .add, self.mm.add);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .sub => {
                    try self.binNum(regs, a, instr.b, instr.c, .sub, self.mm.sub);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .mul => {
                    try self.binNum(regs, a, instr.b, instr.c, .mul, self.mm.mul);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
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
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .idiv => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.floorDiv(lhs, rhs), self.mm.idiv, lhs, rhs));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .mod => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.mod(lhs, rhs), self.mm.mod, lhs, rhs));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .pow => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.pow(lhs, rhs), self.mm.pow, lhs, rhs));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- bitwise ---- (both-int fast lane; else `arith.*` + meta)
                .band => {
                    try self.binBit(regs, a, instr.b, instr.c, .band, self.mm.band);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .bor => {
                    try self.binBit(regs, a, instr.b, instr.c, .bor, self.mm.bor);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .bxor => {
                    try self.binBit(regs, a, instr.b, instr.c, .bxor, self.mm.bxor);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .shl => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.shl(lhs, rhs), self.mm.shl, lhs, rhs));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .shr => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.shr(lhs, rhs), self.mm.shr, lhs, rhs));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .sar => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, try self.arithMeta(arith.sar(lhs, rhs), self.mm.sar, lhs, rhs));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .not => {
                    regs.setBool(a, !regs.get(instr.b).isTruthy());
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .bnot => {
                    const v = regs.get(instr.b);
                    regs.set(a, try self.unArithMeta(arith.bnot(v), self.mm.bnot, v));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                // `#t` honours `__len` for tables; strings/raw-length fall through.
                .len => {
                    regs.set(a, try self.lenValue(regs.get(instr.b)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- concat ---- `__concat` on `TypeError` (a non-concatable
                // operand); the located fault is preserved when neither has one.
                .concat => {
                    const lhs = regs.get(instr.b);
                    const rhs = regs.get(instr.c);
                    regs.set(a, self.concat(lhs, rhs) catch |e| switch (e) {
                        Error.TypeError => try self.binMeta(self.mm.concat, lhs, rhs, Error.TypeError),
                        else => return e,
                    });
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- comparisons → boolean register ----
                // `gt`/`ge` reuse `lt`/`le` with operands swapped (a>b ≡ b<a).
                // `eq`/`ne` consult `__eq` only for two raw-unequal tables;
                // `lt`/`le` consult `__lt`/`__le` when not raw-comparable.
                .eq => {
                    regs.setBool(a, try self.valuesEqual(regs.get(instr.b), regs.get(instr.c)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .ne => {
                    regs.setBool(a, !try self.valuesEqual(regs.get(instr.b), regs.get(instr.c)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .lt => {
                    regs.setBool(a, try self.compareMeta(.lt, regs.get(instr.b), regs.get(instr.c)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .le => {
                    regs.setBool(a, try self.compareMeta(.le, regs.get(instr.b), regs.get(instr.c)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .gt => {
                    regs.setBool(a, try self.compareMeta(.lt, regs.get(instr.c), regs.get(instr.b)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .ge => {
                    regs.setBool(a, try self.compareMeta(.le, regs.get(instr.c), regs.get(instr.b)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- control flow ----
                // Jumps stay threaded for the *forward* (and not-taken) case —
                // `continue :sw` re-dispatches the next instruction directly. Only
                // a real loop back-edge (`pc <= cur_pc` while tracing is enabled —
                // exactly the epilogue's guard) breaks out to run the back-edge
                // epilogue below; when tracing is off the epilogue is inert, so a
                // back-edge threads too. `cur_pc` is this jump's own pc (set by
                // `step`), so the test sees the post-jump target.
                .jmp => {
                    pc = applyJump(pc, instr.aux);
                    if (self.trace.config.enabled and pc <= cur_pc) break :sw;
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .jmp_if_false => {
                    if (!regs.get(a).isTruthy()) pc = applyJump(pc, instr.aux);
                    if (self.trace.config.enabled and pc <= cur_pc) break :sw;
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .jmp_if_true => {
                    if (regs.get(a).isTruthy()) pc = applyJump(pc, instr.aux);
                    if (self.trace.config.enabled and pc <= cur_pc) break :sw;
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .jmp_if_not_nil => {
                    if (!regs.get(a).isNil()) pc = applyJump(pc, instr.aux);
                    if (self.trace.config.enabled and pc <= cur_pc) break :sw;
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                    // `for_prep` always jumps forward to the matching `for_loop`, so
                    // this never back-edges; kept uniform with the other jumps.
                    if (self.trace.config.enabled and pc <= cur_pc) break :sw;
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                    if (self.trace.config.enabled and pc <= cur_pc) break :sw;
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                    if (self.trace.config.enabled and pc <= cur_pc) break :sw;
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- tables ----
                .new_table => {
                    const t = try self.heap.newTable();
                    regs.set(a, Value.heap(&t.header));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                            // A grid table's `t[i]` is a transient `row_view`, not a
                            // raw slot — skip the fast path and let `indexGet →
                            // Table.getInt` mint the handle. (Phase 3, doc 14.)
                            if (!tbl.array.isGrid() and i >= 1 and i <= @as(i64, @intCast(tbl.array.len))) {
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
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                            // A grid store is an outer row (re)assignment — a Phase 5
                            // deflation trigger owned by `indexSet`; never raw-stored
                            // here (and `fits(nil)` is `true`, so without this guard a
                            // `nil` store would reach `array.get` on a grid).
                            if (!tbl.array.isGrid() and i >= 1 and i <= @as(i64, @intCast(tbl.array.len)) and tbl.array.fits(val)) {
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
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .get_index2 => {
                    // Fused two-level read `R[a] = R[b][R[c]][R[aux]]`. On a grid
                    // (doc 14) this reads the flat cell directly — the *only* grid
                    // reader, so it never mints a `row_view`. On a nested table it is
                    // exactly two `indexGet`s, semantically identical to the unfused
                    // form (metatables on either level still dispatch).
                    const container = regs.get(instr.b);
                    const key1 = regs.get(instr.c);
                    const key2 = regs.get(@as(u16, @intCast(instr.aux)));
                    regs.set(a, try self.fusedGet(container, key1, key2));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .set_index2 => {
                    // Fused two-level store `R[a][R[b]][R[c]] = R[aux]`. The grid
                    // inflation trigger and the in-grid cell store (with
                    // reshape-on-overflow) live in `fusedStore` (doc 14, Phase 4b).
                    const container = regs.get(a);
                    const key1 = regs.get(instr.b);
                    const key2 = regs.get(instr.c);
                    const val = regs.get(@as(u16, @intCast(instr.aux)));
                    try self.fusedStore(container, key1, key2, val);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- globals ----
                .get_global => {
                    regs.set(a, self.globals.get(proto.constants[instr.b]));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .set_global => {
                    const v = regs.get(a);
                    try self.globals.set(self.gpa, proto.constants[instr.b], v);
                    self.heap.writeBarrier(&self.globals.header, v); // no-op until Phase 4
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

                // ---- functions ----
                .closure => {
                    const child = proto.protos[instr.b];
                    const cl = try self.makeClosure(closure, child, base);
                    regs.set(a, Value.heap(&cl.header));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .get_upval => {
                    regs.set(a, self.upvalGet(closure.upvalues[instr.b]));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .set_upval => {
                    const v = regs.get(a);
                    self.upvalSet(closure.upvalues[instr.b], v);
                    self.heap.writeBarrier(&closure.upvalues[instr.b].header, v); // no-op until generational
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .close_upvalues => {
                    self.closeUpvaluesFrom(base + a);
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },

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
                            self.trace.setRegionContext(self.depth, frame.call_seq);
                            // Reloaded onto the callee frame; re-enter the outer
                            // loop so `step` fetches the callee's first instruction
                            // with a full prologue (GC/seq/suspend/recording).
                            continue :outer;
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
                    // The native and `__call` arms run inline (no frame push) and
                    // leave `pc` one past the call, exactly like a straight-line op,
                    // so they thread to the next instruction. (The `.function` arm
                    // never reaches here — it `continue :outer`s after reloading
                    // onto the callee frame.) Threading here keeps the back-edge
                    // epilogue reachable *only* via `break :sw`.
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                        self.trace.dropRegionActivation(frame.call_seq);
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
                    self.trace.dropRegionActivation(frame.call_seq);
                    self.depth -= 1;
                    frame = &self.frames[self.depth - 1];
                    closure = frame.closure;
                    proto = closure.proto;
                    code = proto.code;
                    base = frame.base;
                    regs = self.frameWindow(base, proto.num_registers);
                    pc = frame.pc;
                    self.trace.setRegionContext(self.depth, frame.call_seq);
                    self.stack_top = base + proto.num_registers;
                    // Reloaded onto the parent frame; re-enter the outer loop so
                    // `step` fetches the parent's next instruction with a full
                    // prologue. (The parent `pc` is already past the call.)
                    continue :outer;
                },

                // ---- varargs ---- read the current frame's `...` cursor. The
                // surplus-arg region lives below `base` (in the caller's window),
                // stable and GC-rooted; these never relocate it.
                .vararg_first => {
                    regs.set(a, if (frame.varargs_count >= 1) self.regGet(frame.varargs_base) else Value.nil());
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
                .vararg_len => {
                    regs.set(a, Value.int(@intCast(frame.varargs_count)));
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
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
                    continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                },
            }

            // Phase 5 hotness seam: a backward (or self) jump just took us to
            // `pc <= cur_pc` — a loop back-edge whose target `pc` is the loop
            // header (anchor). Count it, and arm/close a recording. Gated on
            // `enabled`, so it is inert until `--trace`.
            if (self.trace.config.enabled and pc <= cur_pc) {
                const anchor_pc: u32 = @intCast(pc);
                // JIT coverage (gated): arriving at a back-edge means tier-0 just
                // interpreted one loop-body iteration. Classify it covered (a trace
                // exists at this anchor — the fallback-despite-a-trace smell) vs
                // uncovered, and charge the cycles that body iteration took (the span
                // since the last coverage event — another back-edge or a trace-region
                // exit) to this anchor. Trace-run iterations/cycles are counted
                // separately (`onSideExit` + the trace-exec bracket below); the two
                // are disjoint (a trace's committed count excludes the deopt iteration
                // tier-0 redoes on side-exit), so there is no double count.
                if (self.trace.config.coverage) {
                    const now = trace.readCycles();
                    self.trace.noteInterpIter(proto, anchor_pc, trace.cycleDelta(now, self.trace.last_event_tsc));
                    self.trace.last_event_tsc = now;
                }
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
                        // Native safety net (see the skip below): set when a
                        // fingerprint-matching trace at this anchor compiled to
                        // native-*unsupported*. If the walk then ends with no
                        // productive entry, we gate the anchor so tier-0 owns the
                        // loop rather than re-walking (or falling to tier-1a) every
                        // back-edge.
                        var saw_native_unsupported = false;
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
                            null)
                        {
                            // Mark visited *before* the body so the loop continuation
                            // excludes `ct` (and everything tried so far) — this is
                            // what makes the walk finite.
                            if (nvisited < visited.len) {
                                visited[nvisited] = ct;
                                nvisited += 1;
                            }
                            // `.link` traces are continuations entered only by
                            // exit-PC chaining after an inner loop-done exit. Never
                            // trial-enter one through the same-anchor walk, even if
                            // a malformed or future bytecode shape puts it at a
                            // back-edge pc.
                            if (ct.instrs.len != 0 and ct.instrs[ct.instrs.len - 1].op == .link) continue;
                            // --- type fingerprint (step 5) ---
                            // Skip this trace if the current register types don't
                            // match its entry type guards.  Avoids trial entries
                            // that would immediately fail on a guard_int/guard_float
                            // mismatch.  Branch-direction guards (guard_true/false)
                            // aren't fingerprinted — they depend on computed values.
                            if (!ct.matchesFingerprint(regs)) continue;
                            any_fingerprint_matched = true;
                            // Native safety net: under `--jit-native`, a trace that
                            // records but can't compile to native (unsupported op /
                            // type) would otherwise run on the tier-1a IR-interpreter,
                            // which is ~equal-to-slower than tier-0 on these bodies —
                            // so enabling native codegen *regresses* the loop vs plain
                            // tier-0. Decline to enter it (skip, never tier-1a) and note
                            // it; the post-walk fall-through gates the anchor *only* if
                            // nothing productive ran — so a native-supported sibling at
                            // the same anchor still runs and never thrashes the gate.
                            // `nativeFor` compiles lazily and memoizes the verdict, so
                            // this is one compile attempt then an O(1) `union` tag read
                            // forever (the supported path below re-reads the page).
                            if (self.trace.config.native_codegen and self.trace.nativeFor(ct) == null) {
                                saw_native_unsupported = true;
                                continue;
                            }
                            // Cluster sub-lever 1: a trace that reaches a callee
                            // through an upvalue/global carries synthetic entry
                            // inputs. Seed each into the dead slab region above the
                            // anchor window and widen the executor window to cover
                            // them; an input-free trace reuses the narrow `regs`. A
                            // capacity overflow declines the entry (run tier-0).
                            // `native_eligible` stays true unless a `hash_cell` seed
                            // can't resolve this entry (H1) — then native declines and
                            // tier-1a owns the entry (byte-identical, see
                            // `seedTraceInputs`).
                            var native_eligible = true;
                            const trace_regs = self.seedTraceInputs(ct, base, closure, proto, regs, &native_eligible) orelse continue;
                            if (self.trace.valuesScratch(ct.instrs.len)) |buf| {
                                self.trace.entries +%= 1;
                                // JIT coverage time attribution (gated): open the
                                // trace-exec region. `last_hop_tsc` marks the first
                                // hop's start; each `onSideExit` (per hop, inc. every
                                // `driveChain` hop) charges its span to its OWN anchor
                                // and advances the boundary — so per-anchor traced time
                                // follows the hops, not the entry anchor. The `defer`
                                // then re-stamps `last_event_tsc` (catching every exit,
                                // incl. the productive `continue :outer` paths) so the
                                // next tier-0 span's cycles start after the region and
                                // don't count trace time. The prep between the back-edge
                                // and here (seeding, scratch) falls into neither bucket
                                // (residual "other"), not misattributed.
                                if (self.trace.config.coverage) self.trace.last_hop_tsc = trace.readCycles();
                                defer if (self.trace.config.coverage) {
                                    self.trace.last_event_tsc = trace.readCycles();
                                };
                                var ran_native = false;
                                var ran_native_link_mode = false;
                                // 2.3b-1 (doc 17): a `driveChain` burst may persistently
                                // arm a `.link` slot only when no safepoint-line/suspend
                                // recording is active — an mcode fusion collapses the
                                // 8-hop observation boundary and would widen the blackout.
                                // (record_exec_log already precludes the native path.)
                                const safe_to_arm = self.suspend_ctl == null and !self.record_safepoint_lines;
                                // 2.3c-0e (doc 17): disarm-on-unsafe. We're about to
                                // (possibly) run native; if an observation/suspend/replay
                                // window is active, first reset every patched slot to
                                // `shared_exit` so no native→native handoff fires through it
                                // and skips this dispatcher's safepoint/GC boundary. The
                                // handoff then re-enters here and re-establishes the boundary.
                                // Inert until 2.3c arms slots (empty registry → single length
                                // check); load-bearing once the continuation↔inner cycle
                                // closes in 2.3c-2. exec-log is not gated here: it takes the
                                // non-native branch below, so no slot can fire under it.
                                if (!safe_to_arm) self.trace.disarmAllLinks();
                                // Part S (doc 17): the dispatcher has now SELECTED and
                                // is about to ENTER `ct`. If a burst terminal recently
                                // crossed the handoff threshold at a same-anchor
                                // sibling's ordinary deopt exit, arm that exit to jump
                                // straight here next time — the native compilation of
                                // doc 16's coherent-anchor chain. Armed at the real
                                // selection site precisely so the target is the trace
                                // the deterministic dispatch actually runs, never a
                                // hit-count guess made at receipt time.
                                self.trace.tryArmSiblingHandoff(ct, safe_to_arm);
                                const result = if (self.trace.config.record_exec_log) blk: {
                                    const tid = self.trace.traceIndex(ct) orelse break :blk irinterp.execute(ct, trace_regs, buf);
                                    const rec = self.trace.execRecorderFor(tid) orelse break :blk irinterp.execute(ct, trace_regs, buf);
                                    break :blk irinterp.executeTraced(rec, ct, trace_regs, buf);
                                } else if (self.trace.config.native_codegen) blk: {
                                    if (native_eligible) {
                                        if (self.trace.nativeFor(ct)) |nt| {
                                            ran_native = true;
                                            self.trace.native_entries +%= 1;
                                            ran_native_link_mode = self.trace.hasNativeLoopDoneLink(ct, proto);
                                            // 2.3c-2d (D2a): capture the per-transition
                                            // ledger, preserving the materialization mode
                                            // (linked → `runLinkedLoopDoneCapturing`,
                                            // ordinary → `runCapturingLedger`). Pre-2c-E
                                            // `ct` never fuses forward, so this yields the
                                            // SAME scalar `result` as the old non-capturing
                                            // calls and the scalar/M1 consumer below reads
                                            // only those fields — byte-identical; the
                                            // `ledger_scratch` fill is inert until D2b
                                            // activates the `ledger_len > 1` replay.
                                            self.trace.prepareNativeEntry(); // B-3a direct-entry sweep hook
                                            break :blk if (ran_native_link_mode)
                                                nt.runLinkedLoopDoneCapturing(trace_regs, &self.trace.ledger_scratch, self.trace.silentStaging())
                                            else
                                                nt.runCapturingLedger(trace_regs, &self.trace.ledger_scratch, self.trace.silentStaging());
                                        }
                                    }
                                    break :blk irinterp.execute(ct, trace_regs, buf);
                                } else irinterp.execute(ct, trace_regs, buf);
                                if (ran_native) {
                                    if (self.trace.driveDispatcherSilentResult(ct, result, proto, regs, safe_to_arm)) |chain| {
                                        if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                        const armed_side = self.trace.consumeSideTraceWantAtResume(proto, @intCast(pc));
                                        for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                        if (armed_side and mode == .fast) {
                                            frame.pc = pc;
                                            return .switch_mode;
                                        }
                                        continue :outer;
                                    }
                                }
                                // B-2b: `tryArmSiblingHandoff` is entry-sited above,
                                // before lazy native compilation. This post-receipt
                                // safe point lets a provenance edge publish as soon as
                                // that child has compiled even when the result is the
                                // scalar (`ledger_len <= 1`) path. Multi-row receipts
                                // also drain after replay; the exact-arm fast reject
                                // makes the second call inert.
                                self.trace.drainProvenanceArms(safe_to_arm);
                                // Always record the exit instruction — useful for
                                // per-guard PC debugging even on productive exits.
                                self.trace.last_exit_instr = result.exit_instr;

                                // P-B (doc 17): resolve the FINAL trace in the chain
                                // from the id baked into the native exit stub. The
                                // consumers below route through `final` — the trace that
                                // performed the final native exit — which for a directly-
                                // entered UNARMED trace is `ct`, but for an ARMED parent
                                // whose slot fused into a child is the CHILD (a distinct
                                // id ≠ ct.id). 2.3b-1 arms the first `.link` slot, so
                                // `final == ct` no longer holds and its assert is dropped
                                // (as this comment always promised: "dropped there").
                                // Fail closed (2.3b-1): a native exit ALWAYS bakes a live
                                // trace id (P-B), and under an ARMED slot that id can be a
                                // fused child ≠ ct. Native resolution is therefore STRICT —
                                // a null here means the baked id is missing/retired (the
                                // dangling-link bug P-E guards against) and there is no safe
                                // `ct` substitute (routing a child's exit through `ct`'s
                                // instrs would misclassify the guard / resume PC). Panic
                                // rather than silently fall back, in release builds too.
                                // tier-1a never arms, so its `final` is unconditionally `ct`.
                                const resolved: ?*trace.Trace = self.trace.traceById(result.final_trace_id);
                                const final: *trace.Trace = if (ran_native)
                                    (resolved orelse @panic("dispatcher: native final_trace_id did not resolve"))
                                else
                                    ct;

                                // 2.3c-0d (doc 17): the sibling-retry `driveChain`s below
                                // seed `initially_excluded` with the walk's `visited` set so
                                // they neither re-run the trace we entered nor a sibling
                                // already tried this back-edge. `visited` holds only the
                                // `ct`s trial-entered at THIS anchor — it does NOT contain a
                                // fused child (`final != ct`), which lives at its own anchor.
                                // Once a slot is armed a child prologue-fail can surface
                                // `final` here; without excluding it a sibling retry could
                                // immediately re-pick the just-failed child. Build the
                                // exclusion set once = `visited ∪ {final}`. Byte-identical
                                // now: `final == ct`, and `ct ∈ visited`, so the union adds
                                // nothing.
                                //
                                // ORDER `final` FIRST (blocker-3 fix): `driveChain` copies
                                // `initially_excluded` into its OWN `[8]` visited and breaks
                                // at 8 (trace.zig). When the walk already visited 8 traces,
                                // a trailing `final` (excl[8]) would be truncated away and
                                // driveChain could re-pick the just-failed child. Placing
                                // `final` at excl[0] guarantees it survives the copy; a later
                                // already-visited sibling is dropped instead — harmless, as
                                // driveChain bounds its own hops regardless.
                                var excl: [visited.len + 1]*trace.Trace = undefined;
                                var nexcl: usize = 0;
                                if (final != ct) {
                                    excl[nexcl] = final;
                                    nexcl += 1;
                                }
                                for (visited[0..nvisited]) |v| {
                                    if (nexcl >= excl.len) break;
                                    excl[nexcl] = v;
                                    nexcl += 1;
                                }

                                // 2.3b-1 (doc 17): every EXIT consumer below routes
                                // through `final` (the trace that performed the final
                                // native exit), not `ct` (the trace we entered). With no
                                // link armed yet they are the same object, so this is
                                // byte-identical; once `driveChain` arms a `C.link →
                                // I.linked_entry` handoff, a direct native run of the
                                // continuation `C` can fuse straight into the inner root
                                // `I` and return `final == I ≠ ct`, and the exit identity
                                // (guard PC, resume, side-exit accounting) belongs to `I`.
                                //
                                // `local_done` is the FINAL trace's OWN committed count:
                                // on the native path `result.local_completed`
                                // (= completed − entry_rbx), which equals `completed` for
                                // an un-fused run but is the child's local count once
                                // fused (never the cumulative `rbx`); on the tier-1a path
                                // `local_completed` is defaulted 0 and unused, so fall
                                // back to `completed`. Every productivity/guard-failure
                                // decision uses `local_done`; only chain-cumulative
                                // resume accounting (inside `driveChain`) uses `completed`.
                                const local_done: usize = if (ran_native) result.local_completed else result.completed;

                                // 2c-E: native ONE-TRIP linked loop-done. A linked-mode
                                // native entry commits its final-iteration snapshot at
                                // the loop-done exit even when `local_completed == 0`
                                // (a one-iteration inner: the loop-done guard fires
                                // before any back-edge `rbx` increment) — regs ARE
                                // coherent at the post-loop PC and one enclosing
                                // iteration completed, exactly the event `replayLedger`
                                // accounts as `onSideExit(I, max(local, 1))`. The scalar
                                // zero path below would misread it as a failed entry
                                // (guard-failure count + penalty + no chain). Recognize
                                // it and route it through the PRODUCTIVE path with an
                                // effective productivity of 1, passing the ORIGINAL
                                // `result` to `driveChain` (real exit identity — the
                                // chain classifies the loop-done itself; no fabricated
                                // count). Native-only: tier-1a has NOT committed the
                                // final iteration at this point (it still owes
                                // `flushNumericForLoopDone`), so counting 1 there would
                                // charge phantom progress. Bounds-check `exit_instr`
                                // BEFORE the guard-shape probe (maxInt = prologue-fail).
                                if (ran_native) self.trace.dbg("receipt: pc={d} link_mode={} local={d} exit={d} ledger_len={d} completed={d}", .{ ct.anchor.pc, ran_native_link_mode, local_done, result.exit_instr, result.ledger_len, result.completed });
                                const linked_one_trip = ran_native and ran_native_link_mode and
                                    local_done == 0 and
                                    result.exit_reason == .normal and
                                    result.exit_instr != std.math.maxInt(u32) and
                                    result.exit_instr < final.instrs.len and
                                    trace.isLoopDoneGuardIndex(final, result.exit_instr);

                                // 2.3c-1 (M1 half-fusion, doc 17): fused top-level
                                // `.link` consumer. When `driveChain` armed `ct`'s
                                // source-branch guard slot → a prime-side ramp's
                                // `ordinary_entry`, a native run of `ct` (the skip
                                // trace) can fuse straight into that ramp under the
                                // shared frame: skip commits its composites, hits the
                                // armed guard, jumps into the ramp, which runs to its
                                // `.link` terminal committing ZERO of its OWN
                                // iterations. The receipt is then `final = ramp`,
                                // `result.completed == entry_rbx ==` skip's own count
                                // (so `local_done == 0`), and regs are coherent at the
                                // ramp's INNER-loop PC — NOT the outer header. The plain
                                // dispatcher below would misread `local_done == 0` as a
                                // skip zero-exit, call `onSideExit(final, 0)`, and drive
                                // `.ordinary_header` off `final.anchor.pc` (the outer
                                // header) — a semantic misresume from the wrong coherent
                                // PC (doc 17 §Increment 2.3c). Through 2.3c-1 a bespoke
                                // scalar recognizer (armed-edge provenance) handled it
                                // here; 2.3c-2d folds that steering into `replayLedger`.
                                //
                                // 2.3c-2d (D2b-ii, doc 17): a dispatcher native entry that
                                // fused forward through an armed slot returns a MULTI-ENTRY
                                // per-transition ledger (`ledger_len > 1`) describing the
                                // whole fused span. Drain it through the authoritative
                                // `replayLedger` graph-walk (origin `.dispatcher_root`) —
                                // the same drain the in-burst continuation call uses —
                                // instead of the bespoke scalar M1 recognizer this
                                // replaces. `replayLedger`'s `.deopt` non-last arm
                                // reproduces the old `onSideExit(ct, skip_local)` +
                                // sub-case (a)/(b) steering byte-for-byte.
                                //
                                // 2c-E: gated on bare `ledger_len > 1` — a fused span that
                                // TERMINATED in `.prologue_fail` must also drain (the
                                // scalar code below only knows the final body: it would
                                // read `local_done == 0` off the failing successor, drop
                                // the span's committed prefix on the floor, and misroute
                                // the zero-exit path). `replayLedger` models both
                                // prologue-fail-terminated grammars: `[skip.deopt(M1),
                                // ramp.prologue_fail]` (sub-case (c): `onSideExit(skip,
                                // local)` + `onSideExit(ramp, 0)` + resume at the skip's
                                // anchor — exactly the unarmed native steering) and
                                // `[I.loop_done_linked, C.prologue_fail]` (the committed
                                // loop-done accounts, the fail breaks the burst at the
                                // post-loop PC).
                                if (ran_native and result.ledger_len > 1) {
                                    const chain = self.trace.driveDispatcherLedger(ct, self.trace.ledger_scratch[0..result.ledger_len], proto, regs, safe_to_arm);
                                    if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                    // Side-trace precision: if this burst's terminal
                                    // crossed the hotguard threshold, arm the recording
                                    // AT the resume so it captures the failing
                                    // iteration's re-run — the back-edge consumption is
                                    // one iteration late and records the wrong shape on
                                    // alternating loops (see the fn doc). Armed via the
                                    // replay-side pending anchor, which the `.full`
                                    // prologue consumes at the anchor pc — so a `.fast`
                                    // dispatch must switch up, exactly as the
                                    // `wants_prime_side` consumption below does.
                                    const armed_side = self.trace.consumeSideTraceWantAtResume(proto, @intCast(pc));
                                    for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                    if (armed_side and mode == .fast) {
                                        frame.pc = pc;
                                        return .switch_mode; // → .full
                                    }
                                    continue :outer;
                                }

                                // --- hot-exit counting (step 4) ---
                                // Pall's `trace_hotside` (lj_trace.c:798): EVERY
                                // taken side exit — productive or not — charges
                                // its own per-(trace, exit) counter; crossing
                                // `hotexit` wants a side trace for the alternate
                                // path. Loop-done exits are excluded: they are
                                // productive completions owned by the
                                // continuation machinery, not side-trace
                                // candidates (`linked_one_trip` exits are
                                // loop-done by construction and fall out of the
                                // same check).
                                if (result.exit_instr != std.math.maxInt(u32) and
                                    result.exit_instr < final.instrs.len and
                                    !trace.isLoopDoneGuardIndex(final, result.exit_instr))
                                {
                                    self.trace.noteTakenExit(final, result.exit_instr, local_done, proto);
                                }

                                if (local_done > 0 or linked_one_trip) {
                                    // This trace did useful work — keep its result.
                                    // (`linked_one_trip`: the committed loop-done IS one
                                    // enclosing iteration, replayLedger's `max(local, 1)`.)
                                    self.trace.onSideExitReceipt(
                                        final,
                                        if (linked_one_trip) 1 else local_done,
                                        result.exit_instr,
                                        if (linked_one_trip or trace.isLoopDoneGuardIndex(final, result.exit_instr)) 1 else local_done,
                                        .deferred,
                                    );
                                    // Nested-loop linking (Phase 1): if this is an
                                    // inner numeric-`for` running to completion (its
                                    // terminal loop guard failed) and the exit lands
                                    // on an enclosing loop, arm a continuation
                                    // recording at the post-loop pc. Records the
                                    // outer body forward; Phase 2 links it back here.
                                    // Output-neutral (the recording aborts at the
                                    // inner `for_prep` until Phase 2).
                                    self.trace.maybeArmContinuation(final, result.exit_instr, proto);
                                    // Coherent-state chaining (doc 16, Phase 2): the
                                    // prime-side arm counter now lives in the unified
                                    // hotexit charge above (`noteTakenExit` routes
                                    // source-branch guard exits to `wants_prime_side`
                                    // at the `hotexit` threshold), so no separate
                                    // `countProductiveBranchExit` charge remains — one
                                    // counter per exit, Pall's `snap->count`.
                                    // Retire any dead-marked traces before leaving the
                                    // walk so a stale narrow-lane trace doesn't linger
                                    // in a slot just because a later trace succeeded.
                                    // Safe: `continue :outer` abandons the walk, so the
                                    // freed `*Trace`s are never revisited.
                                    for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                    // Nested-loop linking (Phase 1): a continuation
                                    // recording just armed (pending at the post-loop
                                    // pc). Its dispatch-prologue activation hook is
                                    // `.full`-only, so the inner loop's final-iteration
                                    // deopt-replay — which walks tier-0 from the inner
                                    // anchor up to that post-loop pc — must run in
                                    // `.full`. In `.fast` (the steady state of a hot
                                    // inner loop) switch up; in `.full` just stay.
                                    if (self.trace.pending_exit_anchor != null) {
                                        if (mode == .fast) {
                                            frame.pc = pc;
                                            return .switch_mode; // → .full
                                        }
                                        continue :outer; // already `.full`
                                    }
                                    // Coherent-state chaining (doc 16, Phase 2): the
                                    // productive branch-guard exit just crossed the arm
                                    // threshold (`wants_prime_side` set for THIS anchor).
                                    // Record the current prime iteration as a `.side`
                                    // trace anchored at this outer header — regs are
                                    // already coherent here, so tier-0 re-enters at the
                                    // anchor with no deopt-replay and records
                                    // `guard_true(p[i]) → inner for_prep → link`. Force
                                    // `.full` so the replay-side prologue hook fires; do
                                    // NOT advance pc (regs coherent at `ct.anchor`).
                                    // Self-limiting: `countTracesAt >= 2` (in
                                    // `noteTakenExit`'s branch route) stops re-arming
                                    // once the prime side-trace exists, and the commit
                                    // DONE-latches the parent exit.
                                    if (self.trace.wants_prime_side) |want| {
                                        if (want.proto == final.anchor.proto and want.pc == final.anchor.pc and
                                            !self.trace.isRecording() and
                                            self.trace.pending_replay_anchor == null and
                                            !self.trace.isGated(final.anchor))
                                        {
                                            self.trace.pending_replay_anchor = final.anchor;
                                            // Hotexit provenance rides into the replay
                                            // recording for the commit's DONE latch.
                                            self.trace.pending_replay_src = self.trace.prime_want_src;
                                            self.trace.prime_want_src = null;
                                            self.trace.wants_prime_side = null;
                                            self.trace.prime_side_arms +|= 1;
                                            for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                            if (mode == .fast) {
                                                frame.pc = pc;
                                                return .switch_mode; // → .full
                                            }
                                            continue :outer; // already `.full`
                                        }
                                    }
                                    // Nested-loop linking (Phase 3): once the
                                    // continuation trace exists, a productive
                                    // inner loop-done exit can chain to it. The
                                    // chainer commits the final inner iteration
                                    // from `buf`, runs continuation ⇄ inner-root
                                    // for a bounded burst, and tells us where
                                    // tier-0 should resume when it yields.
                                    if (ran_native and ran_native_link_mode) {
                                        if (self.trace.driveChain(final, result, proto, trace_regs, .native_only, .native_numeric_for_done, &.{}, safe_to_arm)) |chain| {
                                            if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                            for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                            continue :outer;
                                        }
                                    } else if (!ran_native) {
                                        if (self.trace.driveChain(final, result, proto, trace_regs, .ir, .{ .ir_numeric_for_done = buf }, &.{}, safe_to_arm)) |chain| {
                                            if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                            for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                            continue :outer;
                                        }
                                    }
                                    // Coherent-state chaining (doc 16, Phase 2): a
                                    // productive *source-level branch-guard* exit
                                    // (nsieve's `guard_false(p[i])` firing on a prime
                                    // after committing composite iterations) leaves regs
                                    // coherent at the outer header — the same loop-header
                                    // re-entry deopt discipline as the zero-exit path
                                    // below. Chain to a same-anchor sibling the cold walk
                                    // didn't run — the prime side-trace armed by 2D — so
                                    // the prime iteration + following composites run in
                                    // the linked burst instead of dropping to tier-0.
                                    // Seed `initially_excluded` with the walk's `visited`
                                    // set (don't re-run the skip trace or a sibling
                                    // already tried this back-edge). Native tier when the
                                    // failed trace ran native (chain native→native),
                                    // tier-1a otherwise. Null (no prime side-trace yet, or
                                    // its inner guards failed) falls through to the T3
                                    // handoff → tier-0 at the header, unchanged: the skip
                                    // trace already committed its composites, so `i` has
                                    // advanced and tier-0 runs the prime iteration and
                                    // makes progress (no spin).
                                    //
                                    // `regs` (the live tier-0 register file) is
                                    // passed, not a trace-local `trace_regs`,
                                    // and that is intentional: driveChain only
                                    // ever enters zero-input traces (findLinkTrace
                                    // requires `t.inputs.len == 0`; loop/link
                                    // roots read state from the coherent register
                                    // file at their anchor). There is no input
                                    // remapping to thread, so the live regs are
                                    // exactly the coherent state each entered
                                    // trace expects.
                                    if (self.trace.isSourceBranchGuardExit(final, result.exit_instr, proto)) {
                                        if (ran_native) {
                                            if (self.trace.driveChain(final, result, proto, regs, .native_only, .ordinary_header, excl[0..nexcl], safe_to_arm)) |chain| {
                                                if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                                for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                                continue :outer;
                                            }
                                        } else {
                                            if (self.trace.driveChain(final, result, proto, regs, .ir, .ordinary_header, excl[0..nexcl], safe_to_arm)) |chain| {
                                                if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                                for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                                continue :outer;
                                            }
                                        }
                                    }
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
                                self.trace.onSideExitReceipt(final, 0, result.exit_instr, 0, .deferred);

                                // Widen-eviction: if this trace's array lane guard
                                // can never pass again (the live array widened past
                                // it, monotonically), mark it for retirement so its
                                // anchor slot frees for the stabilised wider-lane
                                // trace. Deferred to after the walk (see `dead`).
                                //
                                // 2.3c-0d (doc 17): eviction retires the trace we ENTERED at
                                // this anchor (`ct`). `dead ⊆ visited` (both capped at 8), and
                                // a fused child (`final != ct`) is not a member of this
                                // anchor's walk — it lives at its own anchor and widen-evicts
                                // itself there (P-E then resets `ct`'s arm). So eviction stays
                                // a `ct`-slot question even though the failing lane-guard shape
                                // is a `final` fact; gate on `final == ct` to keep a fused
                                // child out of this anchor's `dead` list. Byte-identical now
                                // (`final == ct` always).
                                if (final == ct and ndead < dead.len and self.trace.laneWidenedPast(ct, regs)) {
                                    dead[ndead] = ct;
                                    ndead += 1;
                                }

                                // --- coherent-anchor chaining (doc 16) ---
                                // After this zero-exit the registers are coherent at
                                // `ct.anchor`, so chain to a same-anchor sibling the
                                // cold walk hasn't run (e.g. an outer-header prime
                                // side-trace). Seed `initially_excluded` with the
                                // walk's `visited` set so we neither re-run the trace
                                // that just failed nor re-penalize a sibling already
                                // tried this back-edge.
                                //
                                // Tier selection mirrors the productive branch-guard
                                // site above: chain native→native when the failed
                                // trace ran native (`ran_native`, set at trace entry),
                                // tier-1a otherwise. Previously this site hardcoded
                                // `.ir` even under `--jit-native`, so a native
                                // zero-exit that chained a same-anchor sibling dropped
                                // that sibling to tier-1a — the coherent regs are
                                // identical, so it was inert at the default
                                // `min_useful`, but latent once chaining fires. Keying
                                // off `ran_native` (a mode-invariant fact — the trace
                                // either has native code or it doesn't) preserves C5.
                                // `tier` is a comptime param, so branch on `ran_native`
                                // into two literal-tier calls (as the branch-guard site
                                // above does) rather than a runtime tier value.
                                if (ran_native) {
                                    if (self.trace.driveChain(final, result, proto, regs, .native_only, .ordinary_header, excl[0..nexcl], safe_to_arm)) |chain| {
                                        if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                        for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                        continue :outer;
                                    }
                                } else {
                                    if (self.trace.driveChain(final, result, proto, regs, .ir, .ordinary_header, excl[0..nexcl], safe_to_arm)) |chain| {
                                        if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                                        for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
                                        continue :outer;
                                    }
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
                        // Native safety net (part 2): we reach here only when no trace
                        // ran productively (a productive entry does `continue :outer`).
                        // If the walk skipped a native-unsupported trace, gate the
                        // anchor so its next back-edges hit the hot-count skip and
                        // tier-0 owns the loop — rather than re-walking + re-compiling
                        // every iteration. Guarded on "nothing productive ran", so a
                        // native-supported sibling that *did* run never gets gated
                        // (it `continue :outer`s and bypasses this). Self-heals via the
                        // gate's backoff + `onSideExit` clear.
                        if (saw_native_unsupported) {
                            self.trace.gateNativeUnsupported(.{ .proto = proto, .pc = anchor_pc });
                        }
                        // Coherent-state chaining (doc 16, Phase 2) diagnostic: tier-0
                        // is about to run this *traced* anchor's body because no trace
                        // or chain took over this back-edge — the design's REQUIRED
                        // tier-0-outer-body signal. (The back-edge counter is the wrong
                        // one: `onBackEdge` returns before incrementing once any trace
                        // exists here, so it flattens even under full tier-0 fallback.)
                        // Guarded on a trace existing so untraced hot loops don't
                        // inflate it; a productive trace/chain entry `continue :outer`s
                        // above and never reaches here. Under Phase 2 the prime path
                        // chains instead of dropping here, so this trends to ~0.
                        if (self.trace.hasTrace(.{ .proto = proto, .pc = anchor_pc })) {
                            self.trace.tier0_outer_body_entries +|= 1;
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
    // ===================================================================
    // Fused two-level index (doc 14) — the grid gate.
    //
    // `a[i][j]` / `a[i][j]=v` compile to single `get_index2`/`set_index2` ops. On a
    // flattened grid these read/write the flat cell *directly* (never minting a
    // `row_view`); on a plain nested table they fall back to two ordinary index
    // steps. A store may inflate a homogeneous-numeric `a` into a grid, and grows
    // the grid (stride / cell lane) on overflow rather than deflating — only a
    // genuine type change deflates (Bart's escape model, 2026-06-26).
    // ===================================================================

    /// `R[a] = container[key1][key2]`. Grid → direct cell read; else two index steps.
    fn fusedGet(self: *Vm, container: Value, key1: Value, key2: Value) Error!Value {
        if (container.isHeap() and container.heapType() == .table) {
            const t = table.Table.fromHeader(container.asHeap());
            if (t.array.isGrid()) return self.gridCellGet(t, key1, key2);
        }
        const mid = try self.indexGet(container, key1);
        return self.indexGet(mid, key2);
    }

    /// Read grid cell `t[i][j]` faithfully, reproducing the nested-table semantics
    /// so no deflation is needed on the read path: an in-range row with an
    /// in-stride present int column yields the cell; an in-range row with any other
    /// inner key yields `nil` (a numeric row holds only its cells); an out-of-range
    /// or non-integer outer key means `t[i]` is `nil`, so indexing it faults exactly
    /// like the unfused `nil[j]` ("attempt to index a nil value").
    fn gridCellGet(self: *Vm, t: *table.Table, key1: Value, key2: Value) Error!Value {
        const k1 = table.normalizeKey(key1);
        if (k1.isInt()) {
            const i = k1.asInt();
            if (i >= 1 and i <= @as(i64, @intCast(t.array.gridRows()))) {
                const k2 = table.normalizeKey(key2);
                if (k2.isInt()) {
                    const j = k2.asInt();
                    if (j >= 1 and j <= @as(i64, @intCast(t.array.stride)))
                        return t.array.gridGet(@intCast(i - 1), @intCast(j - 1));
                }
                return Value.nil(); // inner miss on a numeric row ⇒ nil
            }
        }
        // Outer miss: `t[i]` is nil (a grid only holds rows 1..rows). Index the nil
        // exactly as the unfused two-step would — same "index a nil value" fault.
        return self.indexGet(Value.nil(), key2);
    }

    /// `container[key1][key2] = val`. On a grid (or a freshly inflated one) stores
    /// the cell directly, growing stride/lane on overflow; a store that can't be a
    /// grid cell (type change, non-int key, out-of-range row) deflates and retries
    /// as a nested store. On a plain table, attempts inflation first, else two steps.
    fn fusedStore(self: *Vm, container: Value, key1: Value, key2: Value, val: Value) Error!void {
        if (container.isHeap() and container.heapType() == .table) {
            const t = table.Table.fromHeader(container.asHeap());
            // Inflation trigger (Phase 4b): a homogeneous-numeric nested table
            // becomes a grid on the first fused store; `no_grid` makes the (≤ O(cells))
            // scan fire at most once per table.
            if (!t.array.isGrid() and !t.no_grid) {
                if (!self.heap.inflateToGrid(t)) t.no_grid = true;
            }
            if (t.array.isGrid()) {
                if (try self.gridCellStore(t, key1, key2, val)) return;
                // Could not stay a grid cell: the grid was deflated; fall through to
                // the nested store on the now-real row.
            }
        }
        const mid = try self.indexGet(container, key1);
        try self.indexSet(mid, key2, val);
    }

    /// Store grid cell `t[i][j] = val`, returning `true` once stored in-grid. Grows
    /// the stride and/or widens the cell lane (geometrically) when the in-family
    /// store overflows the current shape. Returns `false` after deflating the grid
    /// when the store can't be a grid cell — a non-int key, an out-of-range row, or
    /// a value whose numeric family differs from the cell lane (int↔float) or which
    /// is non-numeric — leaving the caller to do an ordinary nested store.
    fn gridCellStore(self: *Vm, t: *table.Table, key1: Value, key2: Value, val: Value) Error!bool {
        const k1 = table.normalizeKey(key1);
        const k2 = table.normalizeKey(key2);
        if (k1.isInt() and k2.isInt()) {
            const i = k1.asInt();
            const j = k2.asInt();
            if (i >= 1 and i <= @as(i64, @intCast(t.array.gridRows())) and j >= 1) {
                const row: usize = @intCast(i - 1);
                const col: usize = @intCast(j - 1);
                if (val.isNil()) {
                    // A nil store clears a cell; past the stride it is already absent
                    // (no-op, no growth — matches `row[j]=nil` for an unset key).
                    if (j <= @as(i64, @intCast(t.array.stride))) t.array.gridSet(row, col, val);
                    return true;
                }
                // Same numeric family as the cell lane? f64 grid ↔ float; int grid ↔ int.
                const same_family = if (t.array.grid_elem == .f64) val.isFloat() else val.isInt();
                if (same_family) {
                    if (j > @as(i64, @intCast(t.array.stride)))
                        try t.array.gridGrowStride(self.gpa, col + 1);
                    if (!array.ArrayPart.laneFits(t.array.grid_elem, val)) {
                        // Same family but wider int ⇒ climb the cell lane ladder.
                        const target = array.ArrayPart.gridWidenTargetForInt(t.array.grid_elem, val).?;
                        try t.array.gridWidenElem(self.gpa, target);
                    }
                    t.array.gridSet(row, col, val);
                    return true;
                }
                // Family mismatch (float into int grid, int into f64 grid) ⇒ deflate.
            }
        }
        try self.heap.deflateGrid(t);
        return false;
    }

    fn indexGet(self: *Vm, container: Value, key: Value) Error!Value {
        var cur = container;
        var hops: usize = 0;
        while (true) : (hops += 1) {
            if (hops >= max_metatable_chain) return Error.MetatableChainLoop;
            // A `row_view` (transient grid row, doc 14) has no metatable and no
            // hash part: `row[j]` forwards straight into the parent grid's flat
            // cells. (An *outer* grid `t[i]` already minted this handle via
            // `Table.getInt`; this is the *inner* index.)
            if (cur.isRowView()) return table.Table.rowViewGet(cur, key);
            // Raw read when `cur` is a table; a present field short-circuits.
            if (cur.isHeap() and cur.heapType() == .table) {
                // Gate (doc 14, Phase 4c): a grid is touched *only* by the fused
                // `get_index2`/`set_index2` ops (which read cells directly). Any
                // other outer access — a bare `a[i]`, a metamethod chain, a library
                // call — deflates first, so a `row_view` never escapes into a
                // register/heap slot (the swap/identity hazard). Deflation restores
                // byte-identical nested tables, so the read below is then ordinary.
                {
                    const t0 = table.Table.fromHeader(cur.asHeap());
                    if (t0.array.isGrid()) try self.heap.deflateGrid(t0);
                }
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
            // Inner store into a grid row: `row[j] = v` forwards into the parent
            // grid's flat cells when it fits (int key, in-stride, value fits the
            // cell lane). A store that can't stay in the grid (non-int key,
            // past-stride index, wider value) means the row must deflate to a real
            // table — Phase 5; not yet implemented. (doc 14.)
            if (cur.isRowView()) {
                if (table.Table.rowViewSet(cur, key, val)) {
                    self.heap.writeBarrier(cur.rowViewParent(), val); // no-op until Phase 4
                    return;
                }
                // A store that can't stay in the row's grid cells: deflate the
                // parent grid and retry the store on the now-real row table. Under
                // the gate a `row_view` only reaches here via a hand-built grid
                // (tests); the runtime fused path never mints one. (doc 14.)
                const parent = table.Table.fromHeader(cur.rowViewParent());
                const row_idx = cur.rowViewRow();
                try self.heap.deflateGrid(parent);
                cur = parent.getInt(@as(i64, @intCast(row_idx)) + 1); // the real row table now
                continue;
            }
            if (cur.isHeap() and cur.heapType() == .table) {
                const t = table.Table.fromHeader(cur.asHeap());
                // Gate (doc 14, Phase 4c): a bare outer store `t[i] = v` on a grid
                // (row reassignment / a structural change) deflates first, then the
                // store proceeds on the nested table below. Only the fused
                // `set_index2` path stores grid cells; everything else deflates, so a
                // `row_view` never escapes.
                if (t.array.isGrid()) try self.heap.deflateGrid(t);
                // A present (non-nil) raw key bypasses `__newindex`. With no
                // metatable there is no `__newindex` at all, so the presence probe
                // is pure waste — both branches below just raw-store. Short-circuit
                // it (the `or` skips `t.get`) so a plain `t[i] = v` never pays a
                // redundant `Table.get` per store on the hot array-build path.
                if (t.metatable == null or !t.get(key).isNil()) {
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
        // A top-level `run`/`start` contract violation — it can never surface inside
        // a `pcall`/`xpcall` (those don't re-enter top-level), so it is unreachable
        // here; classified not-catchable for completeness (doc 17, H-3 / 9-A(ii)).
        Error.DirtyTopLevelEntry,
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
    onEffectCommitted(self);
    return result;
}

/// The single definition of a successfully committed host effect. Every effect
/// family calls this only after its own result/shape/version validation passes.
fn onEffectCommitted(self: *Vm) void {
    if (self.committed_effect_seq == std.math.maxInt(u64))
        @panic("VM committed effect sequence exhausted");
    self.committed_effect_seq += 1;
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
    const seed = switch (self.effect_mode) {
        .off, .record => blk: {
            const src = self.random_seed_source orelse return Error.RandomUnavailable;
            const seed = src.seed(src.ctx);
            if (self.effect_mode == .record) try logEffect(self, .random_seed, Value.int(@bitCast(seed)));
            break :blk seed;
        },
        .replay => blk: {
            const v = try nextLoggedEffect(self, .random_seed);
            break :blk @as(u64, @bitCast(v.asInt()));
        },
    };
    onEffectCommitted(self);
    return seed;
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
    var committed = true;
    switch (self.effect_mode) {
        .off => {},
        .record => try logEffect(self, .unicode_version, Value.int(unicode_case.unicode_version_packed)),
        .replay => {
            // On a snapshot-resume the version may have been pinned before the cut;
            // its effect then sits behind the cursor — don't consume a second one.
            if (versionAlreadyConsumed(self)) {
                committed = false;
            } else {
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
    if (committed) onEffectCommitted(self);
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
    onEffectCommitted(self);
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
    // `#row_view` — the grid row's logical border (its `row_len` high-water).
    if (v.isRowView()) return Value.int(table.Table.rowViewLen(v));
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
    return runCapturedTuned(gpa, source, sink, stress, mode, .{});
}

/// Knobs for a `runCaptured` pass that needs more than the default wiring.
/// `inspect` runs against the live VM after the program completes and before it
/// is destroyed — the only way for a matrix leg to assert on transient JIT state
/// (region discovery, window flushes) that does not survive `deinit`.
const CapturedOpts = struct {
    hotguard: ?u32 = null,
    inspect: ?*const fn (*Vm, TraceMode) anyerror!void = null,
};

fn runCapturedTuned(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    sink: *io.Writer,
    stress: bool,
    mode: TraceMode,
    opts: CapturedOpts,
) !void {
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
    if (opts.hotguard) |hg| vm.trace.config.hotguard = hg;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    if (opts.inspect) |inspect| try inspect(&vm, mode);
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
    return expectProgramTuned(source, expected, .{});
}

/// `expectProgram` with harness knobs — same ten legs, same output oracle, plus
/// whatever per-leg configuration and post-run assertions `opts` carries.
fn expectProgramTuned(source: [:0]const u8, expected: []const u8, opts: CapturedOpts) !void {
    inline for (.{ false, true }) |stress| {
        inline for (.{ .off, .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            var buf: [256]u8 = undefined;
            var sink = io.Writer.fixed(&buf);
            try runCapturedTuned(testing.allocator, source, &sink, stress, mode, opts);
            try testing.expectEqualStrings(expected, sink.buffered());
        }
    }
}

// --- cross-frame tracing (8-mode parity) -------------------------------------

test "cross-frame: a fixed-arity leaf call inlines and stays byte-identical" {
    // The load-bearing replay-safety proof for Phase 0. The hot loop body calls a
    // non-recursive, fixed-arity Lua leaf; the recorder inlines it (guard_func +
    // seeded callee slots + return mapping). This must compute exactly what tier-0
    // computes by really calling `f`, across all 8 modes AND across a keyframe
    // restore — which is what proves `guard_func` keying on the stable `Proto.id`
    // (not a raw pointer) survives replay, where heap objects come back at a new
    // address with the same preserved id.
    try expectProgram(
        \\local function f(x) return x * x + 1 end
        \\local s = 0
        \\for i = 1, 200 do s = s + f(i) end
        \\print(s)
        \\
    ,
        "2686900\n",
    );
}

test "cross-frame: a two-deep call chain inlines and stays byte-identical" {
    // Genuine depth-2 inlining: g is inlined into the loop body, and the `fn(x)`
    // call *inside* g inlines h one level deeper (verified by --dump-traces emitting
    // two guard_func ops). The callee `h` is passed as a parameter, NOT read through
    // an upvalue — upvalue access in a callee is still an abort in Phase 0, so a
    // `local h; local function g() return h(...) end` chain would silently fall back
    // to tier-0 and prove nothing. Exercises the recorder frame stack push/pop and
    // base_off restore across two levels; deopt still replays the whole iteration
    // from the outer header.
    try expectProgram(
        \\local function h(y) return y + 3 end
        \\local function g(fn, x) return fn(x) * 2 end
        \\local s = 0
        \\for i = 1, 120 do s = s + g(h, i) end
        \\print(s)
        \\
    ,
        "15240\n",
    );
}

test "cross-frame: a callee reached through an upvalue inlines and stays byte-identical" {
    // Cluster sub-lever 1, the canonical replay-safety proof. The hot loop lives in
    // `inner`, whose body calls `A` — reached not as a local/param but through an
    // *upvalue* (`get_upval`). The recorder cannot read an upvalue from the executor
    // (no `*Vm`, no closure there), so it snapshots the loop-invariant callee into a
    // synthetic slab slot above the anchor window, emits a `slot_load` + `guard_func`,
    // and the dispatch loop re-seeds that slot every entry. This must match what
    // tier-0 computes by really resolving the upvalue and calling `A`, across all 8
    // modes AND a keyframe restore — proving the snapshot+guard is deterministic and
    // that `guard_func` keyed on the stable `Proto.id` survives replay.
    try expectProgram(
        \\local function A(i, j) return i * 100 + j end
        \\local function inner()
        \\  local s = 0
        \\  for j = 1, 200 do s = s + A(2, j) end
        \\  return s
        \\end
        \\print(inner())
        \\
    ,
        "60100\n",
    );
}

test "cross-frame: a callee reached through a global inlines and stays byte-identical" {
    // The global analogue of the upvalue case. `A` is a loop-invariant *global*
    // (`get_global`, a raw `globals.get` with no `__index` dispatch), snapshotted and
    // guarded the same way. Byte-identical across all 8 modes + keyframe restore is
    // the proof the global snapshot+guard replays deterministically.
    try expectProgram(
        \\function A(i, j) return i * 100 + j end
        \\local s = 0
        \\for j = 1, 200 do s = s + A(2, j) end
        \\print(s)
        \\
    ,
        "60100\n",
    );
}

test "cross-frame: a changed upvalue callee deopts the snapshot and replays byte-identically" {
    // The snapshot's load-bearing guard. The first `inner()` records a trace whose
    // `guard_func` pins proto X (the first `A`). Reassigning the captured upvalue `A`
    // to a different-proto closure means the second `inner()` re-resolves the snapshot
    // to proto Y on entry; `guard_func` must fail and side-exit to tier-0, which
    // computes the second sum by really calling the new `A`. Byte-identical across all
    // 8 modes + keyframe restore proves the per-entry re-resolve + guard is what keeps
    // the snapshot sound when the loop-invariant cell changes between entries.
    try expectProgram(
        \\local A = function(i, j) return i + j end
        \\local function inner()
        \\  local s = 0
        \\  for j = 1, 200 do s = s + A(1, j) end
        \\  return s
        \\end
        \\print(inner())
        \\A = function(i, j) return i * j end
        \\print(inner())
        \\
    ,
        "20300\n20100\n",
    );
}

test "nested-loop: a linked 2-deep numeric-for nest is byte-identical across all modes (Phase 3)" {
    // The end-to-end output gate for nested-loop trace linking
    // (`docs/design/15-nested-loop-linking.md`). The inner loop traces as a root;
    // its loop-done exit arms a continuation at the post-inner-loop pc; the
    // continuation records the remaining outer-body work, reaches the next inner
    // `for_prep`, and links back to the inner root. Phase 3 executes that tier-1a
    // chain, including the nsieve-shaped statement between the inner loop and the
    // outer back-edge. Output must stay byte-identical to tier-0 across
    // {gc_stress × {off, record-only, no-opt, record-execute, native}}. Inner trip
    // count (30) clears `min_trip_entry` so the inner trace is genuinely entered
    // and the linked path can run in the executing modes.
    try expectProgram(
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do
        \\    s = s + i * j
        \\  end
        \\  s = s + i
        \\end
        \\print(s)
        \\
    ,
        "382120\n",
    );
}

test "nested-loop link: a float for_prep hand-off uses (init−step)+step, not init" {
    // Regression for the codex-flagged BLOCKER in `recForPrepLink`: the link
    // hand-off's first-iteration bounds test and published entry state must be
    // `(init−step)+step` — computed with the SAME float rounding tier-0's
    // `for_prep` + `for_loop` pair applies — not `init` (the "(init−step)+step =
    // init" shortcut only holds for ints). The inner loop gets hot with a benign
    // float step (1.0), so the continuation records a link with float-typed
    // control guards; the LAST outer iteration re-enters that link with
    // `step = 1e16`, where `(1.0 − 1e16) + 1e16 = 0.0 ≠ 1.0`. tier-0 runs that
    // inner loop once with `j = 0.0`; the pre-fix trace handed the inner root
    // `j = 1.0` and printed 18136 instead of 18135. The step comes from an array
    // (not a branch) so no branch guard side-exits before the link is reached.
    try expectProgram(
        \\local steps = {}
        \\for i = 1, 40 do steps[i] = 1.0 end
        \\steps[40] = 1e16
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1.0, 30.0, steps[i] do
        \\    s = s + j
        \\  end
        \\end
        \\print(s)
        \\
    ,
        "18135\n",
    );
}

// --- hash-field (string-keyed) tracing (8-mode parity) -----------------------
// `obj.field` get/set on the hash part records a trace via href/guard_hash/hload/
// hstore (doc 11). These prove the recorded trace is byte-identical to tier-0
// across {gc_stress × {off, record-only, no-opt, record-execute, native}} + a
// keyframe restore — the replay-safety proof. With H1 landed the four ops lower to
// native (seed-resolved invariant cell pointer + typed tag-checked load/store), so
// the `record_execute_native` mode now genuinely exercises the native field path; a
// per-entry seed-resolution miss routes that entry to the tier-1a oracle, which
// side-exits identically — so the matrix stays byte-identical either way.

test "hash field: a constant-key field read loop is byte-identical across all 8 modes" {
    // The minimal read shape: `t.x` is a present, constant-key, int field. Records
    // guard_table → href → guard_hash → hload → guard_int and runs every iteration
    // through the cell.
    try expectProgram(
        \\local t = {x = 7}
        \\local s = 0
        \\for i = 1, 200 do s = s + t.x end
        \\print(s)
        \\
    ,
        "1400\n",
    );
}

test "hash field: an RMW field store (t.n = t.n + 1) is byte-identical across all 8 modes" {
    // The read-modify-write shape OOP code is built from. The hstore sinks below the
    // loop close (C1), so a guard side-exit leaves it unexecuted and deopt-replay
    // applies it exactly once — the double-apply hazard this matrix would catch.
    try expectProgram(
        \\local t = {n = 0}
        \\for i = 1, 200 do t.n = t.n + 1 end
        \\print(t.n)
        \\
    ,
        "200\n",
    );
}

test "hash field: a float-valued field RMW is byte-identical across all 8 modes" {
    // nbody-shaped float arithmetic on a hash field (`p.x = p.x + 0.5`). Float is the
    // second in-scope scalar type; guard_float pins it.
    try expectProgram(
        \\local p = {x = 0.0}
        \\for i = 1, 100 do p.x = p.x + 0.5 end
        \\print(p.x)
        \\
    ,
        "50\n",
    );
}

test "hash field: two distinct constant keys record distinct cells, byte-identical" {
    // `t.a` and `t.b` resolve to two different hoistable cells in the same table; the
    // recorder emits two independent href/guard_hash/hload chains.
    try expectProgram(
        \\local t = {a = 3, b = 4}
        \\local s = 0
        \\for i = 1, 100 do s = s + t.a * t.b end
        \\print(s)
        \\
    ,
        "1200\n",
    );
}

test "hash field: a field whose type changes mid-loop deopts and replays byte-identically" {
    // The type-guard's load-bearing proof. The trace records `t.x` as an int
    // (guard_int on the hload). At i==50 tier-0 stores a float into `t.x`; on the next
    // entry the guard_int fails, side-exits to tier-0, and the sum continues in float.
    // Byte-identical across all 8 modes + keyframe restore proves the field type guard
    // side-exits on the same iteration the oracle and (eventually) native would.
    try expectProgram(
        \\local t = {x = 1}
        \\local s = 0.0
        \\for i = 1, 100 do
        \\  if i == 50 then t.x = 1.5 end
        \\  s = s + t.x
        \\end
        \\print(s)
        \\
    ,
        "125.5\n",
    );
}

test "hash field: a table that grows between trace entries re-resolves the cell (no dangle)" {
    // The cell-dangle proof for Approach B. The hot inner loop traces `t.n` (a present
    // cell). Between inner-loop entries the outer loop inserts a NEW key, growing `t`'s
    // hash part — a rehash that can MOVE the value cell. Because the seeded cell pointer
    // is re-resolved (`getPtr`) and its `hash.count()` re-validated at every entry
    // (never serialized, never assumed stable), a grown table fails the count check →
    // that entry declines native and runs the tier-1a oracle, whose guard_hash side-
    // exits to tier-0. The hoisted pointer can therefore never dangle. Byte-identical
    // across all 8 modes + keyframe restore is the proof.
    try expectProgram(
        \\local t = {n = 0}
        \\local total = 0
        \\for outer = 1, 5 do
        \\  for i = 1, 200 do t.n = t.n + 1 end
        \\  t["k" .. outer] = outer
        \\  total = total + t.n
        \\end
        \\print(t.n, total)
        \\
    ,
        "1000\t3000\n",
    );
}

// --- pure-builtin tracing (math.sqrt → guard_pure/fsqrt, 8-mode parity) -------
// `sqrt(x)` on a float in a hot loop records a trace (guard_pure pins the callee
// identity, fsqrt computes @sqrt) instead of aborting `.host_barrier` (doc 12).
// In F0 native declines any trace carrying the two new ops: the tier-1a oracle
// runs them under the record-execute / record-execute-noopt modes, while the
// `record_execute_native` mode skips the non-compilable trace and falls back to
// tier-0. Both the oracle's `fsqrt` arm and tier-0's `mSqrt` use `@sqrt`, which
// agrees bit-for-bit with the future native `sqrtsd` under the default MXCSR — so
// all five trace modes are byte-identical now and stay so when F1 lands.

test "pure-builtin: a sqrt float-reduction loop is byte-identical across all 8 modes" {
    // The nbody-shaped inner-loop call: `sqrt` reaches the loop as a loop-invariant
    // upvalue (`local sqrt = math.sqrt`), guard_pure re-proves its identity, and
    // fsqrt computes the result from the guarded-float argument every iteration.
    try expectProgram(
        \\local sqrt = math.sqrt
        \\local s = 0.0
        \\for i = 1, 300 do s = s + sqrt(i * 1.0) end
        \\print(s)
        \\
    ,
        "3472.556388576408\n",
    );
}

test "pure-builtin: a rebound sqrt upvalue deopts via guard_pure and replays byte-identically" {
    // guard_pure's load-bearing proof. The first `run()` records a trace pinning the
    // `sqrt` builtin. Reassigning the captured upvalue to an ordinary Lua function
    // means the second `run()` re-resolves the seeded callee to a non-pure value on
    // entry; guard_pure must fail closed and side-exit to tier-0, which really calls
    // the new `sqrt`. Byte-identical across all 8 modes + keyframe restore proves the
    // per-entry callee re-resolve + identity guard keeps the inlined builtin sound
    // when the loop-invariant cell changes between entries.
    try expectProgram(
        \\local sqrt = math.sqrt
        \\local function run()
        \\  local s = 0.0
        \\  for i = 1, 300 do s = s + sqrt(i * 1.0) end
        \\  return s
        \\end
        \\print(run())
        \\sqrt = function(x) return x + 1.0 end
        \\print(run())
        \\
    ,
        "3472.556388576408\n45450\n",
    );
}

test "pure-builtin: NaN and -0.0 sqrt results through a traced loop are byte-identical" {
    // The IEEE edge cases the trace must reproduce exactly: `sqrt(-1.0)` is a quiet
    // NaN (sign bit set on x86-64 → prints `-nan`) and `sqrt(-0.0)` is `-0.0`. Both
    // flow through a hot traced loop (loop-invariant const arg → konst + guard_float
    // + fsqrt), and `fsqrt` is deliberately never constant-folded, so the value is
    // produced by `@sqrt` on every tier identically.
    try expectProgram(
        \\local sqrt = math.sqrt
        \\local n = 0.0
        \\for i = 1, 300 do n = sqrt(-1.0) end
        \\print(n)
        \\local z = 1.0
        \\for i = 1, 300 do z = sqrt(-0.0) end
        \\print(z)
        \\
    ,
        "-nan\n-0\n",
    );
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

test "nil-coalescing: ?? returns rhs only on pure nil, short-circuits" {
    try expectProgram(
        \\print(nil ?? 5)
        \\print(7 ?? 5)
        \\-- pure-nil: a non-nil-but-falsy lhs is KEPT (this is the `or` pitfall ?? avoids)
        \\print(false ?? 9)
        \\print(0 ?? 9)
        \\print("" ?? 9)
        \\-- left-assoc chain: first non-nil wins
        \\print(nil ?? nil ?? 3)
        \\print(nil ?? 2 ?? 3)
        \\-- short-circuit: rhs not evaluated when lhs is non-nil
        \\local hit = false
        \\local function side() hit = true; return 1 end
        \\local _ = 42 ?? side()
        \\print(hit)
        \\local _ = nil ?? side()
        \\print(hit)
        \\
    ,
        "5\n7\nfalse\n0\n\n3\n2\nfalse\ntrue\n",
    );
}

test "nil-coalescing: ?? precedence sits at the or level" {
    try expectProgram(
        \\-- `or` and `??` share a level, left-assoc: evaluate left to right.
        \\print(false or nil ?? 8)
        \\-- (false or nil) ?? 8  ->  nil ?? 8  ->  8
        \\print(nil ?? false or 8)
        \\-- (nil ?? false) or 8  ->  false or 8  ->  8
        \\
    ,
        "8\n8\n",
    );
}

test "customary operators: ! && || != alias not/and/or/~=" {
    try expectProgram(
        \\print(!true)
        \\print(!false)
        \\print(!nil)
        \\print(1 == 1 && 2 == 2)
        \\print(1 == 2 || 3 == 3)
        \\print(1 != 2)
        \\print(1 != 1)
        \\-- short-circuit must match `and`/`or`: the RHS is not evaluated
        \\local hit = false
        \\local function side() hit = true; return true end
        \\local _ = false && side()
        \\print(hit)
        \\local _ = true || side()
        \\print(hit)
        \\-- value-returning (not boolean-coercing), exactly like and/or
        \\print(nil || 7)
        \\print(5 && 9)
        \\
    ,
        "false\ntrue\ntrue\ntrue\ntrue\ntrue\nfalse\nfalse\nfalse\n7\n9\n",
    );
}

test "compound assignment: every operator on a name target" {
    try expectProgram(
        \\local a = 10
        \\a += 5;   print(a)   -- 15
        \\a -= 3;   print(a)   -- 12
        \\a *= 2;   print(a)   -- 24
        \\a //= 5;  print(a)   -- 4
        \\a %= 3;   print(a)   -- 1
        \\a <<= 4;  print(a)   -- 16
        \\a >>= 1;  print(a)   -- 8
        \\a |= 1;   print(a)   -- 9
        \\a &= 12;  print(a)   -- 8
        \\a ~= 5;   print(a)   -- 13  (xor-assign, NOT inequality)
        \\a ~>>= 1; print(a)   -- 6   (arithmetic right shift)
        \\local f = 7.0
        \\f /= 2;   print(f)   -- 3.5  (true division)
        \\local s = "foo"
        \\s ..= "bar"; print(s) -- foobar
        \\
    ,
        "15\n12\n24\n4\n1\n16\n8\n9\n8\n13\n6\n3.5\nfoobar\n",
    );
}

test "compound assignment: ~= is xor-assign in statement context, inequality elsewhere" {
    // The same `~=` token means xor-assign as a statement and ~= (inequality) in
    // an expression — disambiguated purely by parse position.
    try expectProgram(
        \\local a = 12
        \\a ~= 10           -- xor-assign: 12 ~ 10 = 6
        \\print(a)          -- 6
        \\print(a ~= 6)     -- inequality: false
        \\print(a ~= 7)     -- inequality: true
        \\
    ,
        "6\nfalse\ntrue\n",
    );
}

test "compound assignment: field and index targets, prefix evaluated exactly once" {
    try expectProgram(
        \\-- index target with a side-effecting key: must be evaluated once.
        \\local calls = 0
        \\local function idx() calls = calls + 1; return 2 end
        \\local t = {10, 20, 30}
        \\t[idx()] += 100
        \\print(t[2], calls)   -- 120  1
        \\-- field target
        \\local o = { n = 5 }
        \\o.n *= 4
        \\print(o.n)           -- 20
        \\-- side-effecting object prefix evaluated once, too
        \\local ocalls = 0
        \\local function obj() ocalls = ocalls + 1; return o end
        \\obj().n -= 3
        \\print(o.n, ocalls)   -- 17  1
        \\
    ,
        "120\t1\n20\n17\t1\n",
    );
}

test "bitwise: ~>> arithmetic right shift (sign-extending, 64-bit)" {
    try expectProgram(
        \\print(-8 ~>> 1)
        \\print(-1 ~>> 63)
        \\print(256 ~>> 4)
        \\print(-1 ~>> 100)
        \\print(1 ~>> -5)
        \\print((1 << 62) ~>> 60)
        \\
    ,
        // -4, -1 (sign fill, not 1), 16, -1 (overshift saturates to sign), 32 (neg
        // count = logical left), 4
        "-4\n-1\n16\n-1\n32\n4\n",
    );
}

test "metatable: bitwise metamethods (band/bor/bxor/shl/shr/sar/bnot)" {
    try expectProgram(
        \\local N = {}; N.__index = N
        \\local function n(x) return setmetatable({ v = x }, N) end
        \\N.__band = function(a, b) return a.v & b.v end
        \\N.__bor  = function(a, b) return a.v | b.v end
        \\N.__bxor = function(a, b) return a.v ~ b.v end
        \\N.__shl  = function(a, b) return a.v << b.v end
        \\N.__shr  = function(a, b) return a.v >> b.v end
        \\N.__sar  = function(a, b) return a.v ~>> b.v end
        \\N.__bnot = function(a) return ~a.v end
        \\print(n(6) & n(3))
        \\print(n(6) | n(1))
        \\print(n(6) ~ n(3))
        \\print(n(1) << n(4))
        \\print(n(64) >> n(2))
        \\print(n(-8) ~>> n(1))
        \\print(~n(0))
        \\
    ,
        "2\n7\n5\n16\n16\n-4\n-1\n",
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
    var ffs = FakeFs{
        .entries = &.{
            .{ .path = "good.lua", .content = "return 1" },
            .{ .path = "bad.lua", .content = "\xFF\xFE" }, // not valid UTF-8
        },
    };
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

test "A-vi: committed effect sequence is mode-independent across all four commit families" {
    const gpa = testing.allocator;
    const effectser = @import("effectser.zig");
    const source: [:0]const u8 =
        \\local c = os.clock()
        \\local r = math.random()
        \\local u = string.upper("x")
        \\local v = string.lower("Y")
        \\local f = loadfile("effect.lua")
        \\print(c, r, u, v, f())
    ;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "effect.lua", .content = "return 42" },
    } };

    // Off mode commits the same four logical families without producing a log.
    {
        var clock = CounterClock{ .next = 1000 };
        var seed = FixedSeed{ .value = 0x1234 };
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        vm.clock_source = clock.source();
        vm.random_seed_source = seed.source();
        vm.fs_source = ffs.source();
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);
    }

    // Record produces clock, random_seed, unicode_version, file_read in order.
    var log_bytes: []u8 = undefined;
    {
        var clock = CounterClock{ .next = 1000 };
        var seed = FixedSeed{ .value = 0x1234 };
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        vm.effect_mode = .record;
        vm.clock_source = clock.source();
        vm.random_seed_source = seed.source();
        vm.fs_source = ffs.source();
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(@as(usize, 4), vm.effect_log.items.len);
        try testing.expectEqual(EffectKind.clock, vm.effect_log.items[0].kind);
        try testing.expectEqual(EffectKind.random_seed, vm.effect_log.items[1].kind);
        try testing.expectEqual(EffectKind.unicode_version, vm.effect_log.items[2].kind);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[3].kind);
        log_bytes = try effectser.encodeFile(gpa, vm.effect_log.items);
    }
    defer gpa.free(log_bytes);

    // Replay commits the identical four events with all host sources detached.
    // Re-entering the already-consumed Unicode pin models snapshot resume: no
    // new log entry is consumed, so the logical commit counter must not move.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        const log = try effectser.decodeFile(gpa, &vm.heap, log_bytes);
        defer gpa.free(log);
        try vm.effect_log.appendSlice(gpa, log);
        vm.effect_mode = .replay;
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(vm.effect_log.items.len, vm.effect_cursor);
        vm.unicode_version_pinned = false;
        try noteUnicodeVersion(&vm);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(vm.effect_log.items.len, vm.effect_cursor);
    }

    // A host failure occurs before commitment and leaves the counter untouched.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        try testing.expectError(error.ClockUnavailable, compileRun(gpa, &vm,
            \\local t = os.clock()
        ));
        try testing.expectEqual(@as(u64, 0), vm.committed_effect_seq);
    }
}

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
    var ffs = FakeFs{
        .entries = &.{
            .{ .path = "./m.lua", .content = "local x = 1" }, // returns no value
        },
    };
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

test "top-level re-entry on a suspended (dirty) VM fails closed (doc 17 H-3 / 9-A(ii))" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    const source =
        \\local function inner() return 1 end
        \\local function outer() return inner() end
        \\print(outer())
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
    vm.suspend_ctl = .{ .min_depth = 3, .after_safepoints = 0 };

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    // Suspend mid-execution: frames stay live, so `depth != 0`.
    const outcome = try vm.start(chunk.proto);
    try testing.expect(outcome == .suspended);
    try testing.expect(vm.depth != 0);
    const sentinel: trace.RegionKey = .{
        .region_id = @enumFromInt(0xA603),
        .activation = 999_999,
    };
    try vm.trace.region_profit.put(gpa, sentinel, .{
        .outer_traversals = 3,
        .root_frame_depth = vm.depth,
        .root_call_seq = sentinel.activation,
    });

    // A fresh top-level entry through the wrong door (`start`/`run` rather than
    // resuming via `exec()`) must be rejected BEFORE mutating any epoch state — a
    // bare assert would vanish under ReleaseFast, so this is a returned error.
    try testing.expectError(error.DirtyTopLevelEntry, vm.start(chunk.proto));
    try testing.expectError(error.DirtyTopLevelEntry, vm.run(chunk.proto));
    try testing.expect(vm.trace.region_profit.contains(sentinel));

    // The suspended epoch is still intact and resumes normally to completion
    // (clear the trigger first, else it re-suspends at the same depth).
    vm.suspend_ctl = null;
    switch (try vm.exec()) {
        .finished => {},
        .suspended => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("1\n", sink.buffered());
}

test "H-3: a clean fresh top-level epoch clears region_profit wholesale" {
    const gpa = testing.allocator;
    const source: [:0]const u8 = "return 1";
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    try testing.expectEqual(@as(u32, 0), vm.depth);
    try vm.trace.region_profit.put(gpa, .{
        .region_id = @enumFromInt(0xA604),
        .activation = 42,
    }, .{
        .outer_traversals = 5,
        .root_frame_depth = 1,
        .root_call_seq = 42,
    });
    try testing.expectEqual(@as(usize, 1), vm.trace.regionProfitCount());

    _ = try vm.run(chunk.proto);
    try testing.expectEqual(@as(usize, 0), vm.trace.regionProfitCount());
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

/// Configure `vm.trace` for `mode` (mirrors `runCaptured`'s mode wiring) with a small
/// `hotloop` so short test loops go hot. Shared by the two-epoch H-2 part-3 tests.
fn configTraceMode(vm: *Vm, mode: TraceMode) void {
    vm.trace.config.enabled = mode != .off;
    vm.trace.config.execute = mode == .record_execute or mode == .record_execute_noopt or mode == .record_execute_native;
    vm.trace.config.optimize = mode == .record_execute or mode == .record_execute_native;
    vm.trace.config.native_codegen = mode == .record_execute_native;
    vm.trace.config.hotloop = 4;
}

test "H-2 part 3: a trace const does not survive a top-level epoch boundary (cross-epoch id parity)" {
    // The end-to-end determinism regression for docs/design/17 H-2 part 3. On ONE VM:
    //   * epoch 1 runs a hot loop reading a *static* string key `t.foo` — recording a
    //     trace whose const pool holds the interned "foo" (id A). Epoch 1 returns, so at
    //     `depth==0` the static proto tree is unrooted; "foo" is now rooted ONLY by that
    //     cached trace's const.
    //   * epoch 2 (a second `vm.run` on the same VM) interns a marker at id B (> A),
    //     forces GC, re-interns "foo" AT RUNTIME (`"f".."oo"`), and reports the `pairs`
    //     order of {foo, marker}.
    // WITHOUT the `clearCache()` at the epoch boundary, a record mode keeps "foo" alive
    // at id A across the boundary, so it re-interns to A (< B) and sorts BEFORE the
    // marker — while `.off` sweeps it and re-interns to a fresh id C (> B). Divergent
    // `pairs` order. WITH the clear, the epoch-1 trace is retired before epoch 2 runs,
    // so "foo" is swept in every mode alike and all modes agree ("marker foo ").
    const gpa = testing.allocator;
    const s1: [:0]const u8 =
        \\local t = { foo = 1 }
        \\local s = 0
        \\for i = 1, 200 do s = s + t.foo end
        \\print(s)
    ;
    const s2: [:0]const u8 =
        \\local marker = "mar" .. "ker"
        \\for i = 1, 3000 do local junk = {} end
        \\local foo2 = "f" .. "oo"
        \\local tt = {}
        \\tt[foo2] = 1
        \\tt[marker] = 2
        \\local order = ""
        \\for k in pairs(tt) do order = order .. k .. " " end
        \\print(order)
    ;
    const H = struct {
        // Run s1 then s2 on ONE VM; return epoch-2's printed output (heap-owned).
        // NB: compile c2 *after* epoch 1 runs. String literals intern weakly (only
        // rooted via a live closure), so compiling c2 up front would let epoch 1's GC
        // (esp. under gc_stress) sweep c2's not-yet-live constants → dangling loads in
        // epoch 2. Interleaving compile+run keeps each chunk's constants live from the
        // moment they exist. (This models a real REPL: parse+compile+run per statement.)
        fn twoEpoch(a: std.mem.Allocator, src1: [:0]const u8, src2: [:0]const u8, mode: TraceMode, stress: bool) ![]u8 {
            const parser = @import("parser.zig");
            const diag = @import("diag.zig");
            var diags = diag.Diagnostics.init(a);
            defer diags.deinit();

            var vm = try Vm.init(a);
            defer vm.deinit();
            vm.heap.gc_stress = stress;
            configTraceMode(&vm, mode);

            // Epoch 1 — records the t.foo trace.
            var sink1_buf: [64]u8 = undefined;
            var sink1 = io.Writer.fixed(&sink1_buf);
            vm.out = &sink1;
            var t1 = try parser.parse(a, src1, &diags);
            defer t1.deinit();
            var c1 = try compiler.compile(a, &vm.heap, src1, t1.root, &diags);
            defer c1.deinit();
            try testing.expect(!diags.hasErrors());
            _ = try vm.run(c1.proto);

            // Epoch 2 — beginTopLevelEpoch clears epoch-1's cache first.
            var sink2_buf: [64]u8 = undefined;
            var sink2 = io.Writer.fixed(&sink2_buf);
            vm.out = &sink2;
            var t2 = try parser.parse(a, src2, &diags);
            defer t2.deinit();
            var c2 = try compiler.compile(a, &vm.heap, src2, t2.root, &diags);
            defer c2.deinit();
            try testing.expect(!diags.hasErrors());
            _ = try vm.run(c2.proto);
            return a.dupe(u8, sink2.buffered());
        }
    };
    inline for (.{ false, true }) |stress| {
        const off = try H.twoEpoch(gpa, s1, s2, .off, stress);
        defer gpa.free(off);
        // Every record mode's epoch-2 output must match `.off` (and the fixed order).
        inline for (.{ .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            const rec = try H.twoEpoch(gpa, s1, s2, mode, stress);
            defer gpa.free(rec);
            try testing.expectEqualStrings(off, rec);
        }
        try testing.expectEqualStrings("marker foo \n", off);
    }
}

test "H-2 part 3: clearCache retires every trace + resets all derived tiering/diagnostic state" {
    // The direct guard on `clearCache`'s reset set (docs/design/17 H-2 part 3): run a
    // program that populates the trace cache + exec logs + the abort log, then call
    // `clearCache` and assert EVERY field in the reset set is empty/null — so a future
    // field added to the recorder that clearCache forgets is caught here rather than as
    // a cross-epoch use-after-free or a stale-index diagnostic corruption.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local t = { k = 1 }
        \\local s = 0
        \\for i = 1, 200 do s = s + t.k end
        \\local u = 0
        \\for i = 1, 200 do u = u + #tostring(i) end
        \\print(s + u)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.record_exec_log = true; // populate exec_logs
    vm.trace.config.record_aborts = true; // populate abort_log (the tostring loop is a host barrier)
    vm.trace.config.coverage = true; // populate the coverage map (so its clear is load-bearing)
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    // Sanity: the run actually populated the structures we care about (so the post-clear
    // assertions below aren't trivially satisfied by an already-empty state).
    try testing.expect(vm.trace.cache.items.len >= 1);
    try testing.expect(vm.trace.exec_logs.items.len >= 1);
    try testing.expect(vm.trace.abort_log.items.len >= 1);
    try testing.expect(vm.trace.coverage.count() >= 1);

    vm.trace.clearCache();

    // Everything in the reset set is empty/null after the clear.
    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.counters.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.penalty.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.guard_failures.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.exec_logs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.coverage.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.abort_log.items.len);
    try testing.expect(vm.trace.wants_side_trace == null);
    try testing.expect(vm.trace.wants_prime_side == null);
    try testing.expect(vm.trace.pending_exit_anchor == null);
    try testing.expect(vm.trace.pending_replay_anchor == null);
    if (vm.trace.exec_recorder) |*r| try testing.expect(r.log == null);
    for (vm.trace.hotcount) |h| try testing.expectEqual(@as(u16, 0), h);
    // A-ii: the structural-edge cache + the whole region model (logical defs/intern
    // AND the physical classification indices) all empty after the flush.
    try testing.expectEqual(@as(usize, 0), vm.trace.edge_cache.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.region_defs.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.region_intern.entries.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.source_exit_regions.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.dest_entry_regions.count());
}

test "H-2 part 3: the JIT still records fresh traces in a second epoch after the cache clear" {
    // Guard against the counter/gate reset in `clearCache` accidentally wedging
    // re-recording: after the epoch-1 clear, an epoch-2 hot loop must still record.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const src: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 200 do s = s + i end
        \\print(s)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, &vm.heap, src, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto); // epoch 1
    try testing.expect(vm.trace.cache.items.len >= 1);
    _ = try vm.run(chunk.proto); // epoch 2 — beginTopLevelEpoch cleared the cache first
    // A fresh trace was recorded in epoch 2 (not left wedged by the reset).
    try testing.expect(vm.trace.cache.items.len >= 1);
}

test "chunk rooting: a host-compiled retained chunk survives GC before it runs" {
    // docs/design/03 §"Chunk-constant rooting" — the regression. A host compiles chunk
    // B (whose distinctive literal is a `load_const`), retains it, runs chunk A (which
    // GCs at every safepoint under stress), then runs B. WITHOUT `retainChunk`, B's
    // "compdeferlit" is swept during A's run (B has no closure yet → its constants are
    // unrooted) and B's `load_const` dangles. WITH it, the retain roots B's whole tree
    // so the literal survives and B prints it. (Negative control: removing the
    // `retained_chunks` loop in `forEachRootHeader` reddens/UAFs this.)
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    const src_a: [:0]const u8 = "for i = 1, 3000 do local junk = {} end\n";
    const src_b: [:0]const u8 = "print(\"compdeferlit\")\n";

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.heap.gc_stress = true; // sweep at every safepoint during A's run

    // Compile B first (interns "compdeferlit"), then A. Neither is run yet.
    var tb = try parser.parse(gpa, src_b, &diags);
    defer tb.deinit();
    var cb = try compiler.compile(gpa, &vm.heap, src_b, tb.root, &diags);
    defer cb.deinit();
    var ta = try parser.parse(gpa, src_a, &diags);
    defer ta.deinit();
    var ca = try compiler.compile(gpa, &vm.heap, src_a, ta.root, &diags);
    defer ca.deinit();
    try testing.expect(!diags.hasErrors());

    try vm.retainChunk(cb.proto); // keep B alive across A's GC-heavy run — the fix

    var sink_a: [16]u8 = undefined;
    var wa = io.Writer.fixed(&sink_a);
    vm.out = &wa;
    _ = try vm.run(ca.proto); // GCs repeatedly; "compdeferlit" rooted only by the retain

    var sink_b: [32]u8 = undefined;
    var wb = io.Writer.fixed(&sink_b);
    vm.out = &wb;
    _ = try vm.run(cb.proto); // B's `load_const` must still resolve
    vm.releaseChunk(cb.proto);

    try testing.expectEqualStrings("compdeferlit\n", wb.buffered());
}

test "chunk rooting: releaseChunk unroots a retained chunk's constants" {
    // Retain roots the constants (survive a stress GC); release unroots them (swept by
    // the next stress GC). B is never run, so its only reference is the retain.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    const src_b: [:0]const u8 = "print(\"releaselit\")\n"; // never run; literal is a constant
    const src_c: [:0]const u8 = "for i = 1, 100 do local j = {} end\n"; // GC driver

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.heap.gc_stress = true;
    var sink: [16]u8 = undefined;
    var w = io.Writer.fixed(&sink);
    vm.out = &w;

    var tb = try parser.parse(gpa, src_b, &diags);
    defer tb.deinit();
    var cb = try compiler.compile(gpa, &vm.heap, src_b, tb.root, &diags);
    defer cb.deinit();
    var tc = try parser.parse(gpa, src_c, &diags);
    defer tc.deinit();
    var cc = try compiler.compile(gpa, &vm.heap, src_c, tc.root, &diags);
    defer cc.deinit();
    try testing.expect(!diags.hasErrors());

    try vm.retainChunk(cb.proto);
    _ = try vm.run(cc.proto); // stress GC — "releaselit" rooted by the retain
    try testing.expect(vm.heap.interned.get("releaselit") != null);

    vm.releaseChunk(cb.proto);
    _ = try vm.run(cc.proto); // stress GC — now unrooted
    try testing.expect(vm.heap.interned.get("releaselit") == null);
}

test "chunk rooting: releaseChunk preserves survivor order (orderedRemove, not swapRemove)" {
    // Root-discovery order = retain order (docs/design/03), so releasing a NON-last
    // borrow must keep the survivors' relative order: releasing X from [X,Y,Z] leaves
    // [Y,Z]. A `swapRemove` would leave [Z,Y] and shift snapshot bytes.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const sx: [:0]const u8 = "print(\"olx\")\n";
    const sy: [:0]const u8 = "print(\"oly\")\n";
    const sz: [:0]const u8 = "print(\"olz\")\n";
    var tx = try parser.parse(gpa, sx, &diags);
    defer tx.deinit();
    var cx = try compiler.compile(gpa, &vm.heap, sx, tx.root, &diags);
    defer cx.deinit();
    var ty = try parser.parse(gpa, sy, &diags);
    defer ty.deinit();
    var cy = try compiler.compile(gpa, &vm.heap, sy, ty.root, &diags);
    defer cy.deinit();
    var tz = try parser.parse(gpa, sz, &diags);
    defer tz.deinit();
    var cz = try compiler.compile(gpa, &vm.heap, sz, tz.root, &diags);
    defer cz.deinit();
    try testing.expect(!diags.hasErrors());

    try vm.retainChunk(cx.proto);
    try vm.retainChunk(cy.proto);
    try vm.retainChunk(cz.proto);
    vm.releaseChunk(cx.proto); // remove the FIRST — the case that distinguishes the two

    try testing.expectEqual(@as(usize, 2), vm.retained_chunks.items.len);
    try testing.expectEqual(@as(*const Proto, cy.proto), vm.retained_chunks.items[0]);
    try testing.expectEqual(@as(*const Proto, cz.proto), vm.retained_chunks.items[1]);

    vm.releaseChunk(cy.proto);
    vm.releaseChunk(cz.proto);
}

test "chunk rooting: retained-chunk output is byte-identical across all 10 modes" {
    // Rooting retained chunks is a mode-invariant host action (unlike trace consts), so
    // a program that retains + runs a deferred chunk produces identical output in every
    // mode. B's literal `"alit"` is interned at B's compile (early), rooted across A's
    // GC-heavy run by the retain, and sorts BEFORE the runtime-built marker in `pairs`.
    const gpa = testing.allocator;
    const src_a: [:0]const u8 = "for i = 1, 3000 do local junk = {} end\n";
    const src_b: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 200 do s = s + i end
        \\local marker = "mar" .. "ker"
        \\local tt = {}
        \\tt["alit"] = 1
        \\tt[marker] = 2
        \\local order = ""
        \\for k in pairs(tt) do order = order .. k .. " " end
        \\print(order)
    ;
    const H = struct {
        fn run(a: std.mem.Allocator, sa: [:0]const u8, sb: [:0]const u8, mode: TraceMode, stress: bool) ![]u8 {
            const parser = @import("parser.zig");
            const diag = @import("diag.zig");
            var diags = diag.Diagnostics.init(a);
            defer diags.deinit();
            var vm = try Vm.init(a);
            defer vm.deinit();
            vm.heap.gc_stress = stress;
            configTraceMode(&vm, mode);

            var tbb = try parser.parse(a, sb, &diags);
            defer tbb.deinit();
            var cbb = try compiler.compile(a, &vm.heap, sb, tbb.root, &diags);
            defer cbb.deinit();
            var taa = try parser.parse(a, sa, &diags);
            defer taa.deinit();
            var caa = try compiler.compile(a, &vm.heap, sa, taa.root, &diags);
            defer caa.deinit();
            try testing.expect(!diags.hasErrors());

            try vm.retainChunk(cbb.proto);
            var dump: [16]u8 = undefined;
            var wd = io.Writer.fixed(&dump);
            vm.out = &wd;
            _ = try vm.run(caa.proto);

            var sink: [64]u8 = undefined;
            var w = io.Writer.fixed(&sink);
            vm.out = &w;
            _ = try vm.run(cbb.proto);
            vm.releaseChunk(cbb.proto);
            return a.dupe(u8, w.buffered());
        }
    };
    inline for (.{ false, true }) |stress| {
        const off = try H.run(gpa, src_a, src_b, .off, stress);
        defer gpa.free(off);
        inline for (.{ .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            const rec = try H.run(gpa, src_a, src_b, mode, stress);
            defer gpa.free(rec);
            try testing.expectEqualStrings(off, rec);
        }
        try testing.expectEqualStrings("alit marker \n", off);
    }
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

test "H-2 part 1: a hot loop inside a load-chunk is never traced (dynamic-proto gate)" {
    // The core regression guard for docs/design/17 H-2 part 1. An identical hot loop
    // records a trace when it lives in the STATIC main chunk, but records NOTHING when
    // it lives in a `load`ed chunk — because a `load`/`loadfile`/`dofile` chunk's sole
    // closure is not retained durably (`vm.loaded_chunks` holds only `{chunk, source}`),
    // so a trace over it could become the sole GC root of its proto-literal string
    // konsts and diverge string-intern ids between `.off` and record modes. The gate
    // (arm/maybeStart*/recCall check `Proto.dynamic`) refuses to record it.
    // Load-bearing: removing the `if (proto.dynamic) return;` in `arm` reddens the
    // dynamic case (it would record exactly one trace, like the static case).
    const gpa = testing.allocator;
    // STATIC: the loop is in the main chunk → records.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa,
            \\local t = { victim = 1 }
            \\local s = 0
            \\for i = 1, 200 do s = s + t.victim end
            \\print(s)
        , true);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    }
    // DYNAMIC: the same loop, compiled at runtime via `load` → never recorded.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa,
            \\local f = load([[
            \\  local t = { victim = 1 }
            \\  local s = 0
            \\  for i = 1, 200 do s = s + t.victim end
            \\  return s
            \\]])
            \\print(f())
        , true);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    }
}

test "H-2 part 1: dropped load-chunk string id is byte-identical across all modes (end-to-end)" {
    // The end-to-end determinism regression the gate exists to prevent (docs/design/17
    // H-2 part 1). A `load`ed chunk's hot loop reads a proto-literal string key
    // `t.victim` (interned at id A). The closure is dropped, a runtime-built marker
    // string is interned at id B (> A), a GC cycle is forced, then `"victim"` is
    // *re-interned at runtime* (`"vic".."tim"` — a *static* `"victim"` literal in the
    // main chunk would root it and defeat the test) and its id is observed through the
    // `pairs` order of a fresh table.
    //   * WITHOUT the gate, a record mode traces the dynamic loop; the trace konst
    //     keeps "victim" alive at id A, so it re-interns to A (< B) and sorts BEFORE
    //     the marker — while `.off` sweeps it, re-interns to a fresh id C (> B), and
    //     the marker sorts first. Divergent `pairs` order ⇒ divergent output.
    //   * WITH the gate, the dynamic loop is never traced, so "victim" is swept in
    //     EVERY mode alike and all 10 modes print the same order.
    // The 3000-table garbage loop forces a real collection even under `gc_stress=false`
    // (`collectgarbage` is unimplemented; the GC threshold starts at 1024 live objects),
    // so the non-stress half of the matrix actually sweeps too. Verified load-bearing at
    // the CLI: disabling the `arm` gate flips record modes to "victim marker ".
    try expectProgram(
        \\local f = load("local t = {victim=1} local s=0 for i=1,200 do s=s+t.victim end return s")
        \\local _ = f()
        \\f = nil
        \\local marker = "mar" .. "ker"
        \\for i = 1, 3000 do local junk = {} end
        \\local vic = "vic" .. "tim"
        \\local tt = {}
        \\tt[vic] = 1
        \\tt[marker] = 2
        \\local order = ""
        \\for k in pairs(tt) do order = order .. k .. " " end
        \\print(order)
        \\
    ,
        "marker victim \n",
    );
}

test "H-2 part 1: a static trace inlining a dynamic callee aborts with .dynamic_proto (gate 4)" {
    // Covers the recCall inlining gate: a trace anchored in a STATIC proto that
    // inline-calls a `load`ed callee each iteration must abort (embedding the dynamic
    // callee's proto-literal konsts into a static trace is the same H-2 hazard). The
    // callee must be a fixed-arity NESTED function — a directly-loaded root is vararg
    // (`load.zig` `vararg_root = true`) and already aborts at `cp.is_vararg`, which
    // would not prove the new gate fired. Load-bearing: removing the recCall
    // `if (cp.dynamic) return self.abort(.dynamic_proto);` lets the callee inline
    // (the abort row disappears / turns into a recorded trace).
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local g = load("return function(x) return x + 1 end")()
        \\local s = 0
        \\for i = 1, 300 do s = g(s) end
        \\print(s)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    vm.trace.config.record_aborts = true; // populate abort_log so we can read the reason
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // No trace survives (the static anchor keeps aborting on the dynamic callee)...
    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    // ...and the abort log carries a `.dynamic_proto` row (not `.cross_frame`).
    var saw_dynamic_proto = false;
    for (vm.trace.abort_log.items) |row| {
        if (row.reason == .dynamic_proto) saw_dynamic_proto = true;
    }
    try testing.expect(saw_dynamic_proto);
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

test "recorder: a non-recursive fixed-arity leaf call is inlined into one trace" {
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

    // Cross-frame tracing (Phase 0): the body's `call` to a fixed-arity, non-
    // recursive Lua leaf is inlined into the trace (guard_func + seeded callee
    // slots + return mapping) rather than aborting, so the loop records exactly
    // one trace, the recording closes cleanly, and the anchor is *not*
    // blacklisted (an aborted anchor would have been gated — `gate.count() >= 1`).
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expect(!vm.trace.isRecording());
}

test "recorder: a vararg call in the loop body still aborts cleanly" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(...) return 1 end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit();

    // A vararg callee has no compile-time-fixed register window to seed, so the
    // recorder must still abort (cross_frame) — no trace cached, recording done.
    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder: a callee reached through an upvalue records a snapshot input + guard_func" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Cluster sub-lever 1: `inner`'s hot loop calls `A`, reached through an upvalue
    // (`get_upval`). The recorder cannot read an upvalue in the executor, so it
    // snapshots the loop-invariant callee into a synthetic slab slot *above* the
    // anchor window, emits a `slot_load` on that slot (seeded by the dispatch loop)
    // and a `guard_func` pinning the runtime callee identity, and records exactly one
    // `InputSeed` describing how to re-resolve it on entry.
    var chunk = try runForTrace(&vm, gpa,
        \\local function A(i, j) return i * 100 + j end
        \\local function inner()
        \\  local s = 0
        \\  for j = 1, 80 do s = s + A(2, j) end
        \\  return s
        \\end
        \\print(inner())
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];

    // Exactly one synthetic input, resolved from an upvalue, slotted above the anchor.
    try testing.expectEqual(@as(usize, 1), t.inputs.len);
    try testing.expectEqual(trace.InputKind.upvalue, t.inputs[0].kind);
    try testing.expect(t.inputs[0].slot >= vm.trace.rec.anchor_num_registers);

    // The snapshot is read by a `slot_load` on exactly that synthetic slot, and a
    // `guard_func` pins the callee proto.
    var saw_input_load = false;
    var saw_guard_func = false;
    for (t.instrs) |ins| {
        if (ins.op == .slot_load and ins.aux == @as(i32, t.inputs[0].slot)) saw_input_load = true;
        if (ins.op == .guard_func) saw_guard_func = true;
    }
    try testing.expect(saw_input_load);
    try testing.expect(saw_guard_func);
}

test "recorder: a callee reached through a global records a snapshot input + guard_func" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The global analogue: `A` is a loop-invariant global (`get_global`, a raw
    // `globals.get`). Same snapshot+guard mechanism, but the `InputSeed.kind` is
    // `.global` and `source` indexes the constant pool (the global key).
    var chunk = try runForTrace(&vm, gpa,
        \\function A(i, j) return i * 100 + j end
        \\local s = 0
        \\for j = 1, 80 do s = s + A(2, j) end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    try testing.expectEqual(@as(usize, 1), t.inputs.len);
    try testing.expectEqual(trace.InputKind.global, t.inputs[0].kind);
    try testing.expect(t.inputs[0].slot >= vm.trace.rec.anchor_num_registers);

    var saw_guard_func = false;
    for (t.instrs) |ins| {
        if (ins.op == .guard_func) saw_guard_func = true;
    }
    try testing.expect(saw_guard_func);
}

test "recorder: a set_upval in the loop body aborts cleanly" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Snapshotting is only sound while the upvalue cell is *stable* across the traced
    // region. A `set_upval` writes the cell, so the recorder must abort (it is NOT in
    // the record switch) — no trace cached, the anchor gated.
    var chunk = try runForTrace(&vm, gpa,
        \\local up = 0
        \\local function inner()
        \\  for j = 1, 80 do up = up + j end
        \\  return up
        \\end
        \\print(inner())
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder: a set_global in the loop body aborts cleanly" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The global counterpart: a `set_global` writes the snapshotted cell, so the
    // recorder aborts rather than recording a stale-input trace.
    var chunk = try runForTrace(&vm, gpa,
        \\g = 0
        \\local s = 0
        \\for j = 1, 80 do g = g + j; s = s + j end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder S1: inlined callee slots are seeded — no callee-index slot_load" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The callee reads its parameter `x` and a non-param local `t`. S1 seeds every
    // callee slot `.def` at the `.call` (params → the arg's SSA ref, the rest →
    // konst(nil)), so when the body records, `refOf` resolves those reads to the
    // seeded SSA values and NEVER emits a `slot_load` on a callee register index
    // (slot >= the anchor frame's `num_registers`). A `slot_load` there would be an
    // out-of-window trace input reading uninitialised slab — the exact OOB S1 stops.
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(x) local t = x + 1 return t * t end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    const anchor_window: i32 = @intCast(chunk.proto.num_registers);

    // The inlining actually happened: a guard_func pins the runtime callee identity.
    var saw_guard_func = false;
    for (t.instrs) |ins| {
        if (ins.op == .guard_func) saw_guard_func = true;
        // S1 invariant: no trace input (`slot_load`) reads a callee-window slot.
        if (ins.op == .slot_load) try testing.expect(ins.aux < anchor_window);
    }
    try testing.expect(saw_guard_func);
}

test "recorder S2: callee SSA slots are dropped from the loop-closing phi set" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Callee slots are dead at the outer loop boundary (the call returns before the
    // loop closes), so `commit()`'s phi loop must cap writeback to the anchor window
    // and drop them. Every slot-bound phi (`aux >= 0`) must name a slot strictly
    // below the anchor frame's `num_registers`; a phi at a callee index would make
    // the `.loop` flush write OOB past the executor's single RegWindow.
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(x) local t = x + 1 return t * t end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    const anchor_window: i32 = @intCast(chunk.proto.num_registers);
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue; // skip the PHI_INTERNAL sentinel
        try testing.expect(ins.aux < anchor_window);
    }
}

test "recorder S3: the verifier window is the anchor frame, below the reserved scratch" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // S3 pins `assertWellFormed`'s slot bound to the executor's *real* window
    // (`anchor_num_registers`), NOT the grown `reg_map.len`. This test makes that
    // bound load-bearing: it confirms the recorder physically reserved callee
    // scratch ABOVE the anchor window (so callee slots were written at reg_map
    // indices the executor never touches), while the verifier bound stayed pinned
    // to the narrow anchor window. If the two coincided the S3 assertion would be
    // vacuous; here `reg_map.len` strictly exceeds it, so pinning to the narrow
    // bound is what actually catches an OOB callee `aux`.
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(x) local t = x + 1 return t * t end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    // The recorder's window bound equals the anchor (top-level main) frame's regs.
    try testing.expectEqual(chunk.proto.num_registers, vm.trace.rec.anchor_num_registers);
    // …and the reserved scratch genuinely extends past it (callee windows live here).
    try testing.expect(vm.trace.rec.reg_map.len > @as(usize, vm.trace.rec.anchor_num_registers));
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

// --- hash-field (string-keyed) tracing recorder units (doc 11, H0) ----------
// `obj.field` lowers to `get_index`/`set_index` with an interned *string* key, so
// the recorder routes it to `recHashGet`/`recHashSet` instead of the integer-array
// path. These drive real Lua source through `runForTrace` (so the key is a genuine
// `load_const` `konst`, which the const-key rule requires) and assert the recorded
// IR shape / the abort behaviour. The 8-mode byte-identical proof lives in the
// `expectProgram` tests above; these pin the *shape* the optimizer/native consume.

test "recorder (hash field): a constant-key field read records href + guard_hash + hload + type guard" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = 7}
        \\local s = 0
        \\for i = 1, 50 do s = s + t.x end
        \\print(s)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // The read decomposes into: guard_table(table) → href(table, "x") →
    // guard_hash(href) → hload(href) → guard_int (the field is an int, pinned so a
    // later type change side-exits). Mirrors the array aref/aload sequence.
    try testing.expect(std.mem.indexOf(u8, text, "guard_table") != null);
    try testing.expect(std.mem.indexOf(u8, text, "href") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_hash") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hload") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    // A pure field read sinks no store.
    try testing.expect(std.mem.indexOf(u8, text, "hstore") == null);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

test "recorder (hash field): an RMW field store (t.n = t.n + 1) sinks the hstore below the load" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {n = 0}
        \\for i = 1, 50 do t.n = t.n + 1 end
        \\print(t.n)
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // The read records an hload; the write is a read-modify-write, so its hstore is
    // deferred (C1 store-sinking) and flushed at trace close — it must appear *after*
    // the hload in the stream, never before. A store that landed inline (before the
    // loop close) would diverge on deopt-replay.
    const i_load = std.mem.indexOf(u8, text, "hload");
    const i_store = std.mem.indexOf(u8, text, "hstore");
    try testing.expect(i_load != null);
    try testing.expect(i_store != null);
    try testing.expect(i_load.? < i_store.?);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
}

test "recorder (hash field): a float-valued field RMW records (nbody-shaped arithmetic)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local p = {x = 0.0}
        \\for i = 1, 50 do p.x = p.x + 0.5 end
        \\print(p.x)
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // A float field is in scope (int/float are the two scalar-guardable types); the
    // field is pinned with guard_float, and the RMW store still sinks.
    try testing.expect(std.mem.indexOf(u8, text, "hload") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_float") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hstore") != null);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
}

test "recorder (hash field): an absent constant-key access aborts (no trace)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t.y` is absent at record time. The present-key rule forbids it: an absent-key
    // read is `__index`/migrate territory, and an absent-key store could grow/rehash
    // and dangle every hoisted cell. The recorder aborts → no trace, anchor gated.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = 1}
        \\local c = 0
        \\for i = 1, 50 do if t.y then c = c + 1 end end
        \\print(c)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field): a metatable-bearing table aborts (.has_metatable)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A present, constant-key, int field that would otherwise record — but the table
    // carries a metatable, so a present slot could go absent (or `__index` could fire)
    // on a later iteration. The recorder aborts on the metatable edge.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = setmetatable({x = 1}, {})
        \\local s = 0
        \\for i = 1, 50 do s = s + t.x end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field): a heap-valued (string) field aborts (scalar-only restriction)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The field value is a string (heap). Only int/float fields trace: the scalar
    // exec-log encoder can't serialize a heap value, and a non-scalar field has no
    // strict type guard to pin it across iterations. Aborts as a `.value` lane does.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = "hi"}
        \\local n = 0
        \\for i = 1, 50 do if t.x then n = n + 1 end end
        \\print(n)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field): a computed (non-konst) key aborts (const-key rule)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t[k]` with `k` a runtime variable reaches the hash path (k holds a string), but
    // its key ref is a `slot_load`, not a `konst`. A runtime-varying key cannot be
    // pinned to one cell, so the recorder aborts (v1 scope: only literal `t.field`).
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {a = 1}
        \\local k = "a"
        \\local s = 0
        \\for i = 1, 50 do s = s + t[k] end
        \\print(s)
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

test "nested-loop: a hot inner loop's continuation links to the inner root at the inner for_prep (Phase 2)" {
    // Phase 2 of nested-loop trace linking (`docs/design/15-nested-loop-linking.md`).
    // The inner numeric-`for` traces as a root; on its loop-done exit we arm a
    // *continuation* recording anchored at the **post-inner-loop pc** — a non-header
    // anchor (the Phase 1 machinery). That continuation records the outer body
    // forward and re-reaches the inner `for_prep`; because the inner root is already
    // cached, Phase 2 reconstructs the inner root's entry snapshot and **closes the
    // trace with a `.link`** to the inner root (instead of the Phase 1 LINNER abort).
    // Phase 3 may execute the link, but this shape test is still about the recorded
    // cache: prove the link committed by finding a `.link`-terminated trace alongside
    // the inner `.loop` root.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    // Inner trip count (30) exceeds `min_trip_entry` (24) so the inner trace is
    // actually *entered* — below it the dispatch declines tier-1 and the loop-done
    // exit never runs through `irinterp`, so the continuation could not arm.
    var chunk = try runExecForTrace(&vm, gpa,
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do
        \\    s = s + i * j
        \\  end
        \\end
        \\print(s)
    , &sink);
    defer chunk.deinit(); // keep the proto alive: anchors point into it

    // sum(1..40)=820, sum(1..30)=465, 820*465 = 381300.
    try testing.expectEqualStrings("381300\n", sink.buffered());

    // The cache holds the inner `.loop` root AND the continuation `.link` trace.
    var loop_traces: usize = 0;
    var link_traces: usize = 0;
    for (vm.trace.cache.items) |t| {
        try testing.expect(t.instrs.len >= 1);
        switch (t.instrs[t.instrs.len - 1].op) {
            .loop => loop_traces += 1,
            .link => link_traces += 1,
            else => {},
        }
    }
    try testing.expect(loop_traces >= 1); // the inner numeric-for root
    try testing.expect(link_traces >= 1); // the continuation linked, not aborted

    // The link trace's terminator carries the inner root's anchor pc, and that pc
    // really is the anchor of a cached root trace (the hand-off target — P2).
    for (vm.trace.cache.items) |t| {
        const term = t.instrs[t.instrs.len - 1];
        if (term.op != .link) continue;
        const inner_pc: u32 = @intCast(term.aux);
        var found_root = false;
        for (vm.trace.cache.items) |r| {
            if (r.anchor.proto == t.anchor.proto and r.anchor.pc == inner_pc and
                r.instrs[r.instrs.len - 1].op == .loop) found_root = true;
        }
        try testing.expect(found_root);
    }
}

test "nested-loop: linked continuation execution is observable (Phase 3)" {
    const source =
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do
        \\    s = s + i * j
        \\  end
        \\  s = s + i
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();

    try testing.expectEqualStrings(tier0.buffered(), jit.buffered());
    try testing.expect(vm.trace.link_ir_exits > 0);
    try testing.expect(vm.trace.link_follow_count > 0);
}

test "nested-loop: linked array stores commit exactly once at tier-1a boundary" {
    const source =
        \\local a = {}
        \\for k = 1, 200 do a[k] = 0 end
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 100 do
        \\    a[j] = a[j] + i
        \\  end
        \\  s = s + i
        \\end
        \\local sum = 0
        \\for k = 1, 200 do sum = sum + a[k] end
        \\print(sum)
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);
    try testing.expectEqualStrings("8020000\n80200\n", tier0.buffered());

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();

    try testing.expect(vm.trace.link_ir_exits > 0);
    try testing.expect(vm.trace.link_follow_count > 0);
    try testing.expectEqualStrings(tier0.buffered(), jit.buffered());
}

test "nested-loop: linked continuation execution goes native (Phase 4)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const source =
        \\local s = 0
        \\for i = 1, 50 do
        \\  for j = 1, 35 do
        \\    s = s + i * j
        \\  end
        \\  s = s + i
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &native);
    defer chunk.deinit();

    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    try testing.expect(vm.trace.native_link_exits > 0);
    try testing.expect(vm.trace.native_link_follow_count > 0);
}

test "nested-loop: native linked array stores commit exactly once (Phase 4)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const source =
        \\local a = {}
        \\for k = 1, 30 do a[k] = 0 end
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 30 do
        \\    a[j] = a[j] + i
        \\  end
        \\  s = s + i
        \\end
        \\local sum = 0
        \\for k = 1, 30 do sum = sum + a[k] end
        \\print(sum)
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);
    try testing.expectEqualStrings("2406000\n80200\n", tier0.buffered());

    const gpa = testing.allocator;
    var opt_vm = try Vm.init(gpa);
    defer opt_vm.deinit();
    var opt_buf: [64]u8 = undefined;
    var opt = io.Writer.fixed(&opt_buf);
    var opt_chunk = try runExecForTrace(&opt_vm, gpa, source, &opt);
    defer opt_chunk.deinit();
    try testing.expectEqualStrings(tier0.buffered(), opt.buffered());

    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var native_chunk = try runNativeForTrace(&native_vm, gpa, source, &native);
    defer native_chunk.deinit();

    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    try testing.expect(native_vm.trace.native_link_exits > 0);
    try testing.expect(native_vm.trace.native_link_follow_count > 0);
}

test "2c-E (doc 17): loop-done inner→continuation arm fires and closes the native cycle" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // A plain hot nested loop: the doc-15 chain (continuation ⇄ inner) runs every
    // outer iteration. 2c-E arms the inner's loop-done slot → the continuation's
    // `ordinary_entry` on the first accounted loop-done hop; every later native
    // loop-done then fuses `I→C` in ONE trampoline entry and the multi-entry
    // ledger drains through `replayLedger`.
    const source =
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 30 do
        \\    s = s + i
        \\  end
        \\  s = s + 1
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var native_chunk = try runNativeForTrace(&native_vm, gpa, source, &native);
    defer native_chunk.deinit();

    // Primary gate: byte-identical output with the cycle live.
    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    // The `I.loopdone → C.ordinary_entry` slot was actually armed (any of the
    // three arm sites) …
    try testing.expect(native_vm.trace.native_loopdone_link_arms > 0);
    // … and a subsequent native run actually FUSED through it — the consumer-side
    // proof (`replayLedger`'s non-last `.loop_done_linked` arm). Output equality
    // alone cannot distinguish the fused cycle from the unfused ping-pong.
    try testing.expect(native_vm.trace.native_loopdone_link_fused > 0);
}

test "2c-E (doc 17): native one-trip linked loop-done is productive, not a guard failure" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // One-trip reachability: a 2-trip inner loop's dispatcher entry happens on the
    // FIRST back-edge (tier-0 ran iteration 1), so the native trace runs exactly
    // one iteration and hits its loop-done LINKED with `local_completed == 0` (the
    // final linked snapshot commits WITHOUT the back-edge rbx increment). The warm
    // phase (m=30) records the inner root + continuation and compiles them native;
    // the m=2 phase then produces a one-trip linked receipt on every outer
    // iteration. Without the `linked_one_trip` fix each such receipt takes the
    // zero path and `countGuardFailure` charges the loop-done exit PC — at a PC
    // where the trace just SUCCEEDED (the linked snapshot committed).
    //
    // The `%` in the outer body is LOAD-BEARING twice over: it makes the
    // continuation nativegen-unsupported, so (a) `armLoopDoneLink` fails closed at
    // `nativeFor(cont).ordinary_entry` and the loop-done slot stays UNARMED — every
    // m=2 receipt therefore reaches the scalar dispatcher path instead of fusing
    // through the armed slot into the multi-entry ledger drain; and (b) the burst
    // never runs the continuation natively, so the one-trip receipts keep coming
    // via the dispatcher for the whole phase (gate-cooldown cycles re-admit them).
    const source =
        \\local s = 0
        \\local m = 30
        \\for i = 1, 300 do
        \\  if i == 60 then m = 2 end
        \\  for j = 1, m do s = s + 1 end
        \\  s = s % 100000007
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    // One-trip receipts are UNREACHABLE at the default `min_trip_entry` (24): the
    // dispatcher declines numeric-for entry when the EXACT remaining trip count
    // (`forRemainingTrips`) is below it, and the m=2 inner has 1 remaining trip at
    // its first back-edge. Disable the heuristic so the dispatcher actually enters
    // the trace and produces the one-trip linked receipts under test (same
    // precedent as the min_trip_entry=0 tests above; `runNativeForTrace` leaves
    // pre-set config keys alone).
    native_vm.trace.config.min_trip_entry = 0;
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var native_chunk = try runNativeForTrace(&native_vm, gpa, source, &native);
    defer native_chunk.deinit();

    // Primary gate — and the load-bearing one: byte-identical output. Verified by
    // disabling the fix (`false and` on `linked_one_trip`): without it the scalar
    // zero path MISRESUMES a one-trip linked receipt — the linked snapshot already
    // committed the final iteration into regs, and the zero path re-runs it —
    // printing 2253 vs tier-0's 2252. So the fix is a *correctness* fix, not just
    // accounting; at default config only `min_trip_entry` (24) keeps the broken
    // path unreachable (the dispatcher declines <24-remaining-trip entries).
    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    // Secondary gate (accounting): no guard-failure key was charged repeatedly.
    // Without the fix every one-trip linked receipt is misclassified as a
    // zero-yield entry and `countGuardFailure` charges the loop-done exit PC once
    // per dispatcher entry — bounded by the `max_penalty` (8) gate, so assert < 4,
    // not < hotguard. With the fix the one-trip receipts are productive and the
    // key never appears.
    // (Live diagnostics for this scenario: build with `-Djit-debug=true`, set
    // `native_vm.trace.config.debug_log = true` above, and use
    // `native_vm.trace.dbgDumpGuardFailures()` / `dbgDumpCache()` here.)
    var it = native_vm.trace.guard_failures.valueIterator();
    while (it.next()) |count| {
        try testing.expect(count.* < 4);
    }
}

test "2c-F (doc 17): a fresh top-level run disarms the prior epoch's LIVE armed cycle" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The load-bearing epoch-containment integration test (the same-VM two-phase
    // scenario the `disarmAllLinks` unit test at trace.zig can't reach). Phase A arms
    // + fuses the native `C↔I` cycle on a real VM and asserts the NEGATIVE CONTROL:
    // within a single execution epoch `disarmAllLinks` NEVER fires
    // (`native_link_disarms == 0`) even though slots are live and fused. Phase B
    // starts a FRESH top-level run of the SAME proto on the SAME VM: `Vm.run`'s
    // `beginTopLevelEpoch` (2c-F containment) tears the prior epoch's live cycle down
    // (`disarmAllLinks` resets both slots to `shared_exit`) BEFORE the first hot
    // dispatcher entry, so no armed exit left over from Phase A can fire a
    // native→native handoff into this run's fresh frame/register state. This is the
    // fix for the codex-flagged rerun blocker: the exit-slot hardening proves address
    // provenance but not dynamic-entry validity across an epoch — only the
    // fresh-run disarm restores the dispatcher boundary. The decisive facts: (1)
    // Phase B is byte-identical to tier-0 with NO observation window (the containment
    // is unconditional, not window-gated), and (2) the tear-down actually happened
    // over a non-empty registry — provable only by the counter, since a correct
    // byte-identical run looks the same whether the registry held zero or two links.
    // (The dispatcher's observation-window disarm, 2.3c-0e, remains reachable on the
    // SAME-epoch suspend/resume path, which `beginTopLevelEpoch` deliberately does
    // NOT touch; it is unit-covered by the `disarmAllLinks` test.)
    const source =
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 30 do
        \\    s = s + i
        \\  end
        \\  s = s + 1
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Phase A — arm + fuse the cycle (negative control: no disarm within one epoch).
    var phaseA_buf: [64]u8 = undefined;
    var phaseA = io.Writer.fixed(&phaseA_buf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &phaseA);
    defer chunk.deinit();
    try testing.expectEqualStrings(tier0.buffered(), phaseA.buffered());
    // The cycle is live: it was armed and fused …
    try testing.expect(vm.trace.native_loopdone_link_arms > 0);
    try testing.expect(vm.trace.native_loopdone_link_fused > 0);
    // … and nothing disarmed within the epoch (the negative control).
    try testing.expectEqual(@as(u64, 0), vm.trace.native_link_disarms);

    // Phase B — a FRESH top-level run of the same proto on the same VM, with NO
    // observation window. `beginTopLevelEpoch` must reset the still-armed Phase-A
    // cycle before any hot entry.
    var phaseB_buf: [64]u8 = undefined;
    var phaseB = io.Writer.fixed(&phaseB_buf);
    vm.out = &phaseB;
    _ = try vm.run(chunk.proto);

    // (1) Correctness across the epoch boundary: byte-identical to tier-0 with no
    // window in play — the containment is unconditional.
    try testing.expectEqualStrings(tier0.buffered(), phaseB.buffered());
    // (2) The fresh-run epoch boundary actually tore down the LIVE cycle armed in
    // Phase A — the load-bearing signal a byte-identical run alone can't provide.
    try testing.expect(vm.trace.native_link_disarms > 0);
}

test "2c-F (doc 17): a hot armed cycle inside a repeatedly-called function stays correct on re-entry" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The supported cold-re-entry regression guard. The armed `C↔I` cycle lives
    // inside `f`, which is called 20 times: after the first call fuses and arms the
    // slots, every later call is a FRESH frame that re-enters the very anchors whose
    // slots are already live — a cold re-entry of an armed cycle. This is the common
    // real-world shape (a hot-loop helper called in a loop) and it must be
    // deterministically byte-identical to tier-0. (A live cycle re-entered from a new
    // frame is precisely the state the disarm-on-unsafe path guards for the
    // observation window; here, on the ordinary path, the fused handoff must simply
    // be correct — verified across many ASLR layouts.)
    const source =
        \\local function f(base)
        \\  local s = 0
        \\  for i = 1, 400 do
        \\    for j = 1, 30 do
        \\      s = s + i
        \\    end
        \\    s = s + base
        \\  end
        \\  return s
        \\end
        \\local total = 0
        \\for c = 1, 20 do total = total + f(c) end
        \\print(total)
    ;
    var t0_buf: [64]u8 = undefined;
    var t0 = io.Writer.fixed(&t0_buf);
    try runCaptured(testing.allocator, source, &t0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nb: [64]u8 = undefined;
    var n = io.Writer.fixed(&nb);
    var chunk = try runNativeForTrace(&vm, gpa, source, &n);
    defer chunk.deinit();

    // Byte-identical to tier-0 …
    try testing.expectEqualStrings(t0.buffered(), n.buffered());
    // … with the cycle genuinely armed AND fused (so the re-entries above really did
    // exercise the live fused handoff, not a degraded ping-pong).
    try testing.expect(vm.trace.native_loopdone_link_arms > 0);
    try testing.expect(vm.trace.native_loopdone_link_fused > 0);
}

// Like `runNativeForTrace` but also flips on JIT coverage accounting so the
// iteration counters (`iters_traced` / `iters_tier0_covered` /
// `iters_tier0_uncovered`) are populated. Used by the self-consistency tests
// below (Phase 1 of the coverage-instrumentation arc).
fn runCoverageForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) !compiler.Chunk {
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
    vm.trace.config.coverage = true;
    vm.trace.config.hotloop = 4;
    vm.out = sink;

    var chunk = try compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

test "jit coverage: iteration accounting is self-consistent with the analytic trip count" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // A single hot numeric `for` loop of a known trip count. Every loop-body
    // iteration is accounted exactly once: either the trace executed it
    // (`iters_traced`, committed in `onSideExit`) or tier-0 interpreted it
    // (`iters_tier0_*`, counted at the back-edge). The two are disjoint by
    // construction — a trace's committed count excludes the deopt iteration
    // tier-0 redoes on side-exit — so the three counters must sum to the exact
    // number of loop-body iterations, which for `for i=1,N` is exactly N.
    const N = 5000;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runCoverageForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 5000 do acc = acc + i end
        \\print(acc)
    , &sink);
    defer chunk.deinit();

    // Correctness first: same result tier-0 produces.
    try testing.expectEqualStrings("12502500\n", sink.buffered());

    const t = &vm.trace;
    const total = t.iters_traced + t.iters_tier0_covered + t.iters_tier0_uncovered;
    // Exhaustive + disjoint == exact analytic count (N loop-body iterations).
    try testing.expectEqual(@as(u64, N), total);
    // The loop genuinely tiered up — most iterations really ran as a trace …
    try testing.expect(t.iters_traced > 0);
    // … and this is the *clean* case: a single monotype loop, so once the
    // trace commits nothing ever falls back to tier-0. `iters_tier0_covered`
    // (interpreted-despite-a-trace) is therefore zero — the remaining tier-0
    // iterations are the pre-commit warmup, classified `uncovered` because no
    // trace existed yet when they ran. (Contrast the nested test below, which
    // deliberately produces a non-zero covered gap.)
    try testing.expectEqual(@as(u64, 0), t.iters_tier0_covered);

    // Time attribution (x86_64 TSC): the exact cycle values are nondeterministic,
    // so assert only structural invariants. The run was bracketed (`run_cycles`
    // populated), the loop really ran as a trace for a while (`cycles_traced > 0`),
    // and traced time is a subset of the whole run (its brackets nest inside the
    // run bracket, so the bound holds regardless of TSC skew).
    try testing.expect(t.run_cycles > 0);
    try testing.expect(t.cycles_traced > 0);
    try testing.expect(t.cycles_traced <= t.run_cycles);
}

test "jit coverage: the covered-but-interpreted gap is populated (fallback despite a trace)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The smell Bart wants exposed: an anchor that HAS a trace yet keeps
    // dropping to tier-0. An nsieve-shaped nest — an outer scan whose body
    // branches, and a nested marking loop — produces exactly this: the outer
    // header traces but its many short/branchy re-entries deopt, so
    // `iters_tier0_covered` (interpreted-despite-a-trace) is non-zero WHILE
    // `iters_traced` is also non-zero. This is the relationship the report
    // makes visible.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runCoverageForTrace(&vm, gpa,
        \\local count = 0
        \\local n = 4000
        \\local p = {}
        \\for i = 2, n do p[i] = true end
        \\for i = 2, n do
        \\  if p[i] then
        \\    count = count + 1
        \\    local k = i + i
        \\    while k <= n do
        \\      p[k] = false
        \\      k = k + i
        \\    end
        \\  end
        \\end
        \\print(count)
    , &sink);
    defer chunk.deinit();

    const t = &vm.trace;
    // Self-consistency still holds across the whole nest: every counted
    // iteration is accounted exactly once. (We don't pin the exact total here
    // — the point of this test is the *gap*, verified by the two-sided bound
    // below — but both classes must be genuinely populated.)
    try testing.expect(t.iters_traced > 0);
    // The gap: iterations that fell back to tier-0 even though a trace exists
    // at their anchor. If this were zero, "covered" would trivially equal
    // "executed natively" and there would be nothing to expose.
    try testing.expect(t.iters_tier0_covered > 0);
}

test "coherent-state chaining (doc 16, Phase 2): nsieve prime path chains, not tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // Faithful nsieve shape: an outer loop whose body branches on a boolean
    // array (`if p[i]`) and, on the taken (prime) branch, runs a nested marking
    // loop. Pre-Phase-2 the *skip* trace (composite path) runs native but every
    // prime iteration drops to tier-0 with no trace at the coherent anchor. Phase
    // 2 records a prime side-trace at the outer header and chains
    // skip → prime-side → inner → continuation, all native.
    const source =
        \\local function nsieve(m)
        \\  local p = {}
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
        \\print(nsieve(100000))
    ;
    // 9592 = π(100000), the number of primes ≤ 100000. A single call at this m
    // is what lets the *skip* trace productively exit on primes often enough to
    // cross the (default) `hotguard` arm threshold — the 3-call benchmark warms
    // it during its first (much larger) call. Runs in ~0.04s Debug, so it stays
    // fast even under the leak-checking test allocator.
    const expected = "9592\n";

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);
    try testing.expectEqualStrings(expected, tier0.buffered());

    // Inline native harness with the *default* thresholds (mirrors the CLI's
    // `--trace --jit-native`, not `runNativeForTrace`'s lowered `hotloop=4` —
    // the low hot-count records the outer header on an early prime iteration and
    // never lands on the composite-skip shape the mechanism keys off).
    const gpa = testing.allocator;
    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    {
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        native_vm.trace.config.enabled = true;
        native_vm.trace.config.execute = true;
        native_vm.trace.config.optimize = true;
        native_vm.trace.config.native_codegen = true;
        native_vm.out = &native;
        var chunk = try compiler.compile(gpa, &native_vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try native_vm.run(chunk.proto);
    }

    // Correctness: native output byte-identical to tier-0 — the primary gate.
    try testing.expectEqualStrings(tier0.buffered(), native.buffered());

    // Phase-2-specific signals — output equality alone can't prove the chain
    // fired (full tier-0 fallback also produces the right answer):
    //  1. a prime side-trace was actually armed (2C/2D), and
    //  2. its coherent-anchor link-burst was actually *entered* (2E) — the
    //     `.ordinary_header`-only follow counter isolates it from loop-done
    //     continuation bursts.
    try testing.expect(native_vm.trace.prime_side_arms > 0);
    // B-2b's provenance arm can supersede the prime-side registry record before
    // its first firing (relaxed sibling watch arms at a productive terminal);
    // the identical native same-anchor entry then counts as a sibling-handoff
    // fuse instead of a prime-side chain follow. Either form proves the
    // coherent-anchor link-burst was entered.
    try testing.expect(native_vm.trace.prime_side_chain_follows +
        native_vm.trace.sibling_handoff_fused > 0);

    // The design's tier-0-outer-body signal: without chaining, every prime
    // iteration drops to tier-0 at the outer header (≈9592 of them). With the
    // prime chain the prime path stays native, so the chain fires far more often
    // than tier-0 runs the outer body. Self-relative so it's robust to warm-up
    // length and threshold changes.
    // B-2b may republish the same physical source slot through the shared
    // `.sibling_handoff` funnel once its commit provenance exists, so count both
    // registry-recognized forms of the native same-anchor transition.
    try testing.expect(native_vm.trace.prime_side_chain_follows +
        native_vm.trace.sibling_handoff_fused > native_vm.trace.tier0_outer_body_entries);

    // 2.3c-1 (M1 half-fusion, doc 17): the skip trace's source-branch guard slot was
    // armed → the prime-side ramp's `ordinary_entry` (arm), and on a subsequent
    // productive exit skip fused straight into the ramp under the shared frame and the
    // dispatcher's M1 fused-`.link` consumer drained the receipt (fused). Output
    // equality above already proves the fused receipt is drained byte-identically; these
    // two counters prove the arm path AND the consumer path are exercised at all (either
    // staying 0 would mean the M1 mechanism silently never fired).
    // B-2b's provenance publication can claim the physical source slot before
    // the ordinary M1 registry record ever arms (same shared `publishSiblingArm`
    // funnel); either arm counter proves a native same-anchor source-slot arm
    // was published, and either fused counter proves the consumer drained it.
    try testing.expect(native_vm.trace.native_source_link_arms +
        native_vm.trace.sibling_handoff_arms > 0);
    try testing.expect(native_vm.trace.native_source_link_fused +
        native_vm.trace.sibling_handoff_fused > 0);
}

test "coherent-state chaining (doc 16, Phase 2): TraceKind link-permission (root loops, continuation links)" {
    // The 2A `TraceKind` gate in `recForPrepLink` (trace.zig): a `.root` recording
    // that reaches an inner `for_prep` aborts LINNER and never anchors a `.link`,
    // while a `.side`/`.continuation` recording links to the inner root. Asserted
    // here at the trace-shape level: a 2-level nest produces at least one `.loop`
    // root (the inner loop header) AND at least one `.link` continuation. If the
    // gate wrongly let roots link (or wrongly blocked continuations), one of these
    // populations would vanish. (The `.side` half of the permission is exercised
    // end-to-end by the nsieve prime-chain test above; root-never-links is also
    // pinned by the 10-mode determinism matrix, which any output drift would trip.)
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa,
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do s = s + i * j end
        \\  s = s + i
        \\end
        \\print(s)
    , &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings("382120\n", sink.buffered());

    var loop_traces: usize = 0;
    var link_traces: usize = 0;
    for (vm.trace.cache.items) |t| {
        if (t.instrs.len == 0) continue;
        switch (t.instrs[t.instrs.len - 1].op) {
            .loop => loop_traces += 1,
            .link => link_traces += 1,
            else => {},
        }
    }
    try testing.expect(loop_traces > 0);
    try testing.expect(link_traces > 0);
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

/// Post-run oracle for the A-vii-c matrix: the EXERCISED form the A-vii-c review
/// asked for. Every execute leg must prove the flipped gate really ran — a live
/// armable region, physical members indexed against it, and at least one
/// authoritative window flush — so a discovery/armability regression cannot
/// quietly degrade this into an ordinary output test.
///
/// History (kept because the sequence is the load-bearing insight): the A-vii-c
/// landing found this shape's cycle minted with `armable = false` and asserted
/// that dormancy as a tripwire. A-vii-d.0 then established WHY: a cycle is
/// necessarily minted before its external-entry side trace records (the internal
/// cycle triggers minting; the entry is a guard-hot side trace recorded later),
/// so first sight is always owner-not-unique — and armability was frozen
/// monotone-decreasing at first sight, making it unreachable for every recorded
/// shape (measured on nsieve: `both_count` evolves 0→0→1 across rebuilds while
/// the frozen bit stayed false). Discovery now recomputes armability on every
/// rebind (only `tombstoned` is sticky), the tripwire fired exactly as designed,
/// and this is its mandated upgrade.
fn assertRegionGateExercised(vm: *Vm, mode: TraceMode) anyerror!void {
    // Only the executing legs can form the region at all: the cross-anchor cycle
    // closes through SIDE traces, and side-trace recording is driven by guard
    // failures during trace EXECUTION. With `.off` there is no recorder, and with
    // `.record_only` the roots are recorded but never entered, so no guard fails
    // and discovery sees no cycle (measured: `region_defs.count() == 0`). Those
    // legs still carry the output oracle.
    if (mode == .off or mode == .record_only) return;

    try testing.expect(vm.trace.region_defs.count() >= 1);

    var armable: usize = 0;
    var defs = vm.trace.region_defs.valueIterator();
    while (defs.next()) |def| {
        if (def.armable) armable += 1;
    }
    var live_members: usize = 0;
    var members = vm.trace.dest_entry_regions.iterator();
    while (members.next()) |entry| {
        for (entry.value_ptr.*) |id| {
            const def = vm.trace.region_defs.get(id) orelse continue;
            if (def.armable) {
                live_members += 1;
                break;
            }
        }
    }
    try testing.expect(armable >= 1);
    try testing.expect(live_members >= 1);
    try testing.expect(vm.trace.region_profit_flushes >= 1);
}

test "A-vii-c: a region-forming sieve shape stays byte-identical across all 10 modes" {
    // The gate-consumption flip (doc 17 §A8-iii, A-vii.1) is the FIRST
    // selection-diverging change: region-member traces' penalty/gate now comes
    // from region window flushes keyed on the OWNER anchor, so trace selection
    // for genuine cross-anchor cycles may differ from the pre-flip machine. The
    // contract is output identity, not selection identity (P-EBP-1) — so pin the
    // 10-mode matrix on a program SHAPED to mint a cross-trace-cycle region
    // (branchy outer scan whose taken arm runs an inner numeric-for: the
    // skip/ramp/inner/cont shape; a `while` inner does NOT close the cycle).
    // π(80) = 22 primes.
    //
    // A-vii-d.0: every execute leg additionally proves it really exercised the
    // flipped gate (`assertRegionGateExercised`) — live armable region, indexed
    // members, at least one authoritative window flush — so a discovery or
    // armability regression cannot quietly turn this into an ordinary output
    // test. `hotguard = 3` records side traces early enough for the cross-anchor
    // cycle to close inside the matrix's short loops.
    try expectProgramTuned(
        \\local count = 0
        \\local flags = {}
        \\for j = 1, 5 do
        \\  count = 0
        \\  for i = 2, 80 do flags[i] = true end
        \\  for i = 2, 80 do
        \\    if flags[i] then
        \\      count = count + 1
        \\      for k = i + i, 80, i do flags[k] = false end
        \\    end
        \\  end
        \\end
        \\print(count)
    , "22\n", .{ .hotguard = 3, .inspect = &assertRegionGateExercised });
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

// --- the grid gate: bare index access deflates (Phase 4c, doc 14) ------------
//
// Row forwarding through a live `row_view` (Phase 3) is exercised directly in
// table.zig ("grid row_view: get/set forward …"). At the *interpreter* boundary
// the escape model forbids ever handing a bare `row_view` to user code: any
// ordinary `indexGet`/`indexSet` on a grid table deflates it back to real row
// Tables first, so no stale-alias hazard can arise. These tests pin that gate.

test "grid gate: a bare indexGet on a grid deflates it and returns a real row table" {
    const arr = @import("array.zig");
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Hand-built grid, off the GC list (plain create/destroy). deflateGrid mints
    // the row Tables via the heap, so those land on the GC list and free at deinit.
    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try arr.ArrayPart.initGrid(gpa, 2, 3, .i32); // 2 rows × 3 i32 cells
    t.array.gridSet(0, 0, Value.int(10));
    t.array.gridSet(0, 1, Value.int(20));
    t.array.gridSet(1, 0, Value.int(70));
    const g = Value.heap(&t.header);

    // A bare outer `g[1]` deflates the grid and yields a *real* heap Table — never
    // a row_view. The parent is now nested and flagged so it won't re-inflate.
    const r1 = try vm.indexGet(g, Value.int(1));
    try testing.expect(!r1.isRowView());
    try testing.expect(r1.isHeap() and r1.heapType() == .table);
    try testing.expect(!t.array.isGrid());
    try testing.expect(t.no_grid);

    // The rebuilt row reproduces the cells (cols 0,1 set ⇒ keys 1,2; col 2 a hole).
    try testing.expectEqual(@as(i64, 10), (try vm.indexGet(r1, Value.int(1))).asInt());
    try testing.expectEqual(@as(i64, 20), (try vm.indexGet(r1, Value.int(2))).asInt());
    try testing.expect((try vm.indexGet(r1, Value.int(3))).isNil());
    try testing.expectEqual(@as(i64, 2), (try lenOf(r1)).asInt());

    // `#g` is still the row count; the second row is an independent table.
    try testing.expectEqual(@as(i64, 2), (try lenOf(g)).asInt());
    const r2 = try vm.indexGet(g, Value.int(2));
    try testing.expect(r2.isHeap() and r2.heapType() == .table);
    try testing.expect(!r1.eql(r2));
    try testing.expectEqual(@as(i64, 70), (try vm.indexGet(r2, Value.int(1))).asInt());
}

test "grid gate: a bare indexSet on a grid deflates it, then stores the whole row" {
    const arr = @import("array.zig");
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try arr.ArrayPart.initGrid(gpa, 2, 3, .i32);
    t.array.gridSet(0, 0, Value.int(10));
    t.array.gridSet(1, 0, Value.int(70));
    const g = Value.heap(&t.header);

    // A bare outer store replaces the whole slot — that is only meaningful on a
    // nested table, so the grid deflates first, then the store lands as a scalar.
    try vm.indexSet(g, Value.int(1), Value.int(9));
    try testing.expect(!t.array.isGrid());
    try testing.expect(t.no_grid);
    try testing.expectEqual(@as(i64, 9), (try vm.indexGet(g, Value.int(1))).asInt());

    // Row 2 survived the deflation as a real row table.
    const r2 = try vm.indexGet(g, Value.int(2));
    try testing.expectEqual(@as(i64, 70), (try vm.indexGet(r2, Value.int(1))).asInt());
}

// --- Phase 4b: inflation + reshape through the fused store path (doc 14) ------

test "fused store: a homogeneous-numeric matrix inflates, reshapes, then deflates on type change" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Build nested `{ {1,2}, {3,4} }` on the heap (everything GC-linked; freed at
    // deinit whether or not it's rooted, so no globals dance is needed).
    const a = try vm.heap.newTable();
    const r0 = try vm.heap.newTable();
    const r1 = try vm.heap.newTable();
    try r0.set(gpa, Value.int(1), Value.int(1));
    try r0.set(gpa, Value.int(2), Value.int(2));
    try r1.set(gpa, Value.int(1), Value.int(3));
    try r1.set(gpa, Value.int(2), Value.int(4));
    try a.set(gpa, Value.int(1), Value.heap(&r0.header));
    try a.set(gpa, Value.int(2), Value.heap(&r1.header));
    const av = Value.heap(&a.header);

    // First fused store inflates `a` into a grid and writes the cell in-grid.
    try vm.fusedStore(av, Value.int(1), Value.int(1), Value.int(9));
    try testing.expect(a.array.isGrid());
    try testing.expectEqual(@as(i64, 9), (try vm.fusedGet(av, Value.int(1), Value.int(1))).asInt());
    try testing.expectEqual(@as(i64, 4), (try vm.fusedGet(av, Value.int(2), Value.int(2))).asInt());

    // Reshape on stride overflow: column 3 outruns the stride-2 grid → geometric
    // grow (stays a grid, never deflates — Bart's reshape-on-overflow rule).
    try vm.fusedStore(av, Value.int(1), Value.int(3), Value.int(7));
    try testing.expect(a.array.isGrid());
    try testing.expect(a.array.stride >= 3);
    try testing.expectEqual(@as(i64, 7), (try vm.fusedGet(av, Value.int(1), Value.int(3))).asInt());

    // Lane widen: a value past the current int lane climbs the cell-lane ladder
    // in place, still a grid.
    try vm.fusedStore(av, Value.int(2), Value.int(1), Value.int(100000));
    try testing.expect(a.array.isGrid());
    try testing.expectEqual(@as(i64, 100000), (try vm.fusedGet(av, Value.int(2), Value.int(1))).asInt());

    // Type change (float into an int grid) is the one trigger that deflates; the
    // store still lands, now nested, and the earlier cells survive intact.
    try vm.fusedStore(av, Value.int(1), Value.int(1), Value.float(1.5));
    try testing.expect(!a.array.isGrid());
    try testing.expect(a.no_grid);
    try testing.expectEqual(@as(f64, 1.5), (try vm.fusedGet(av, Value.int(1), Value.int(1))).asFloat());
    try testing.expectEqual(@as(i64, 7), (try vm.fusedGet(av, Value.int(1), Value.int(3))).asInt());
    try testing.expectEqual(@as(i64, 100000), (try vm.fusedGet(av, Value.int(2), Value.int(1))).asInt());

    // Hysteresis: a deflated matrix does not re-inflate on the next fused store.
    try vm.fusedStore(av, Value.int(2), Value.int(2), Value.int(8));
    try testing.expect(!a.array.isGrid());
    try testing.expectEqual(@as(i64, 8), (try vm.fusedGet(av, Value.int(2), Value.int(2))).asInt());
}

// --- Phase 4a: fused two-level index (get_index2 / set_index2) ---------------

test "fused index: chained get/set on nested tables is byte-identical across 8 modes" {
    try expectProgram(
        \\local a = { {10,20,30}, {40,50,60} }
        \\a[1][2] = 99
        \\print(a[1][2], a[2][3], a[1][1])
        \\local b = { { {7,8} } }
        \\b[1][1][2] = 88
        \\print(b[1][1][2], b[1][1][1])
        \\
    ,
        "99\t60\t10\n88\t7\n",
    );
}

test "fused index: __index / __newindex on the inner level still dispatch" {
    try expectProgram(
        \\local proto = { z = 42 }
        \\local row = setmetatable({}, { __index = proto })
        \\local outer = { row }
        \\print(outer[1]["z"])
        \\local log = {}
        \\local mrow = setmetatable({}, { __newindex = function(t,k,v) log[k]=v end })
        \\local o2 = { mrow }
        \\o2[1]["hit"] = 7
        \\print(log["hit"], rawget(mrow, "hit"))
        \\
    ,
        "42\n7\tnil\n",
    );
}

test "fused index: evaluation order matches the unfused RHS-first convention" {
    // Single-level store is RHS-first (`g[k(1)]=k(2)` ⇒ 2 then 1); the fused
    // two-level store must keep the same order: value, then the two keys L→R.
    try expectProgram(
        \\local order = {}
        \\local function k(n) order[#order+1] = n; return n end
        \\local g = { {0,0,0} }
        \\g[k(1)][k(2)] = k(3)
        \\print(order[1], order[2], order[3])
        \\local rd = {}
        \\local function r(n) rd[#rd+1] = n; return n end
        \\local a = { {5} }
        \\local _ = a[r(1)][r(2)]
        \\print(rd[1], rd[2])
        \\
    ,
        "3\t1\t2\n1\t2\n",
    );
}

// --- Phase 4b/4c: grids end-to-end from Lua (8-mode byte-identical) -----------
// A grid is logically transparent: every program below must print exactly what
// the equivalent nested-table program would, in all 8 execution modes. That the
// matrix flattens (or reshapes, or deflates) underneath is invisible to the user.

test "grid e2e: fill a matrix with fused stores then read it back" {
    try expectProgram(
        \\local m = { {1,2,3}, {4,5,6}, {7,8,9} }
        \\for i=1,3 do for j=1,3 do m[i][j] = m[i][j] * 10 end end
        \\local s = 0
        \\for i=1,3 do for j=1,3 do s = s + m[i][j] end end
        \\print(s, m[1][1], m[3][3])
        \\
    ,
        "450\t10\t90\n",
    );
}

test "grid e2e: an f64 cell grid fills, accumulates, and reads back (native XMM cells)" {
    // The float twin of the fill test, sized to tier up so the f64 grid cell path
    // (gload/gstore via `movsd`, doc 14 Phase 8 Stage C) runs natively under
    // `record_execute_native` — byte-identical to tier-0 across all 8 modes. The
    // rows start as dense f64 arrays (`0.0`) so inflation unifies the cell lane to
    // f64; the hot inner loop both reads and writes f64 cells.
    try expectProgram(
        \\local m = {}
        \\for i=1,8 do local r={} for j=1,8 do r[j]=0.0 end m[i]=r end
        \\for i=1,8 do for j=1,8 do m[i][j] = i*0.5 + j*0.25 end end  -- inflate → f64 grid
        \\local s = 0.0
        \\for rep=1,40 do
        \\  for i=1,8 do for j=1,8 do s = s + m[i][j] * 2.0 end end
        \\end
        \\for i=1,8 do m[i][i] = s end                                -- f64 cell stores
        \\print(string.format("%.2f %.2f %.2f", s, m[1][1], m[8][8]))
        \\
    ,
        "17280.00 17280.00 17280.00\n",
    );
}

test "grid e2e: a fused store past the stride grows the grid (reshape-on-overflow)" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 9          -- inflate
        \\m[1][3] = 7          -- column 3 outruns stride 2 → grow, stay flat
        \\m[2][4] = 8          -- column 4 fits the grown stride; still flat
        \\print(m[1][1], m[1][2], m[1][3], m[2][4], m[1][4])
        \\
    ,
        "9\t2\t7\t8\tnil\n",
    );
}

test "grid e2e: a wider int store climbs the cell lane in place" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 1          -- inflate at a tiny lane
        \\m[2][2] = 1000000    -- past the lane → widen, stay flat
        \\print(m[2][2], m[1][1], m[2][1])
        \\
    ,
        "1000000\t1\t3\n",
    );
}

test "grid e2e: a float into an int grid deflates, and the value still lands" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 9          -- inflate (int grid)
        \\m[2][2] = 1.5        -- type change → deflate, store nested
        \\print(m[1][1], m[2][2], m[1][2], m[2][1])
        \\
    ,
        "9\t1.5\t2\t3\n",
    );
}

test "grid e2e: bare row access deflates yet stays correct (pairs, escape, equality)" {
    try expectProgram(
        \\local m = { {10,20}, {30,40} }
        \\m[1][1] = 11                 -- inflate
        \\local row = m[1]             -- bare access ⇒ deflate; row is a real table
        \\row[2] = 22                  -- mutating the escaped row is visible in m
        \\local sum = 0
        \\for _,v in ipairs(m[1]) do sum = sum + v end
        \\print(m[1][1], m[1][2], sum, m[1] == m[1], m[2][2])
        \\
    ,
        "11\t22\t33\ttrue\t40\n",
    );
}

test "grid e2e: table.insert on the matrix deflates and appends a whole row" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 9                  -- inflate
        \\table.insert(m, {5,6})       -- bare op on the matrix ⇒ deflate
        \\print(#m, m[3][1], m[3][2], m[1][1])
        \\
    ,
        "3\t5\t6\t9\n",
    );
}

test "grid e2e: an in-place row swap (the motivating counterexample) stays correct" {
    // `tmp = a[i]` is a bare access ⇒ the grid deflates and `tmp` is a real row
    // table, so the stale-alias hazard the gate was designed to avoid cannot arise.
    try expectProgram(
        \\local a = { {1,2,3}, {4,5,6} }
        \\a[1][1] = 10                 -- inflate
        \\local tmp = a[1]             -- bare access ⇒ deflate; tmp aliases the real row
        \\a[1] = a[2]
        \\a[2] = tmp
        \\print(a[1][1], a[1][3], a[2][1], a[2][3])
        \\
    ,
        "4\t6\t10\t3\n",
    );
}

test "grid e2e: table.sort over rows by a key deflates and orders correctly" {
    try expectProgram(
        \\local a = { {3,30}, {1,10}, {2,20} }
        \\a[1][1] = 3                  -- inflate (no-op value, just to flatten)
        \\table.sort(a, function(x,y) return x[1] < y[1] end)
        \\print(a[1][1], a[2][1], a[3][1], a[1][2], a[3][2])
        \\
    ,
        "1\t2\t3\t10\t30\n",
    );
}

// ---------------------------------------------------------------------------
// array-of-structs (.value-lane table load) — the bodies[i].x pattern
// ---------------------------------------------------------------------------

test "array-of-structs: read-only loop over .value-lane table array is byte-identical" {
    // A small array of tables with scalar fields — the canonical `bodies[i].x`
    // pattern. The hot loop reads float fields from each element. Before the
    // .value-lane table support, the recorder aborted here (nyi_opcode on
    // get_index); Phase 1 let tier-1a trace the loop, and Phase F (native codegen
    // for .value-lane table loads) now compiles it to x86-64 as well. The 10-mode
    // matrix proves byte-identical output across all tiers.
    try expectProgram(
        \\local bodies = {}
        \\for i = 1, 100 do
        \\  bodies[i] = { x = i * 1.5, y = i * 2.5 }
        \\end
        \\local sx, sy = 0.0, 0.0
        \\for i = 1, 100 do
        \\  local b = bodies[i]
        \\  sx = sx + b.x
        \\  sy = sy + b.y
        \\end
        \\print(sx, sy)
    , "7575\t12625\n");
}

test "array-of-structs: single-field read accumulation across element tables" {
    // A loop that reads one scalar field from each element table in an array,
    // accumulating the values. Exercises the aload(.value, ty=.heap) →
    // guard_table(aload) → href → guard_hash → hload chain — the full
    // array-of-structs read path. No field writes, so no store-sinking
    // interaction. Byte-identical across the 10-mode matrix.
    try expectProgram(
        \\local items = {}
        \\for i = 1, 50 do
        \\  items[i] = { val = i * 1.0 }
        \\end
        \\local total = 0.0
        \\for i = 1, 50 do
        \\  total = total + items[i].val
        \\end
        \\print(total)
    , "1275\n");
}

/// A-viii (doc 17 §A8 step 8): the sieve shape that closes the OUTER cycle
/// `skip → … → cont → skip` — the A-vii-c region shape, scaled until the
/// region-profit gate qualifies the region and `tryArmRegionBridge` actually
/// arms edge 4 (measured: 39 bridge arms / 156 fused bridge hops, peak 3
/// simultaneously-armed links). π(600) = 109.
const aviii_outer_cycle_source: [:0]const u8 =
    \\local count = 0
    \\local flags = {}
    \\for j = 1, 40 do
    \\  count = 0
    \\  for i = 2, 600 do flags[i] = true end
    \\  for i = 2, 600 do
    \\    if flags[i] then
    \\      count = count + 1
    \\      for k = i + i, 600, i do flags[k] = false end
    \\    end
    \\  end
    \\end
    \\print(count)
;

/// The same sieve, with a host-native probe call at the end of each outer
/// iteration. The probe is deliberately OUTSIDE every hot inner loop — it runs
/// on the tier-0 outer body, so it neither perturbs the inner traces nor the
/// region the bridge is armed against; it only observes and, once, flips the
/// observation window open. Same answer: π(600) = 109.
const aviii_mid_epoch_source: [:0]const u8 =
    \\local count = 0
    \\local flags = {}
    \\for j = 1, 40 do
    \\  count = 0
    \\  for i = 2, 600 do flags[i] = true end
    \\  for i = 2, 600 do
    \\    if flags[i] then
    \\      count = count + 1
    \\      for k = i + i, 600, i do flags[k] = false end
    \\    end
    \\    if i == 499 then aviii_probe() end
    \\  end
    \\end
    \\print(count)
;

/// What one A-viii leg observed. Counters are lifetime totals for the run
/// except `peak`, which is the simultaneous high-water mark.
const OuterCycleRun = struct {
    out: [16]u8,
    out_len: usize,
    bridge_arms: u64,
    bridge_fused: u64,
    loopdone_fused: u64,
    disarms: u64,
    peak: usize,
    entries: u64,
    fn output(self: *const OuterCycleRun) []const u8 {
        return self.out[0..self.out_len];
    }
};

/// Run the outer-cycle sieve on a fresh native-JIT VM, with the observation
/// window (`record_safepoint_lines` — the same `!safe_to_arm` predicate a
/// suspend arms) either open for the whole run or closed.
fn runOuterCycle(gpa: std.mem.Allocator, window_open: bool) !OuterCycleRun {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, aviii_outer_cycle_source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [16]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    vm.source = aviii_outer_cycle_source;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotguard = 3; // close the cross-anchor cycle inside a short run
    vm.record_safepoint_lines = window_open;

    var chunk = try compiler.compile(gpa, &vm.heap, aviii_outer_cycle_source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    var result: OuterCycleRun = .{
        .out = undefined,
        .out_len = sink.buffered().len,
        .bridge_arms = vm.trace.native_region_bridge_arms,
        .bridge_fused = vm.trace.native_region_bridge_fused,
        .loopdone_fused = vm.trace.native_loopdone_link_fused,
        .disarms = vm.trace.native_link_disarms,
        .peak = vm.trace.native_link_peak,
        .entries = vm.trace.entries,
    };
    @memcpy(result.out[0..result.out_len], sink.buffered());
    return result;
}

/// A-viii mid-epoch capture. The window-open event happens INSIDE a running
/// epoch, from a host native, so the only way to observe the registry at that
/// instant is to record it from the native itself; by the time `vm.run` returns
/// the blackout has already erased the evidence.
const AviiiMidEpoch = struct {
    /// Phase 0 → 1: the outer cycle closed and we flipped the window open.
    opened: bool = false,
    /// Snapshot taken at the window-open instant, before the flag is set.
    armed_at_open: usize = 0,
    /// Bitmask over `trace.ArmKind` ordinals present in the registry at open.
    kinds_at_open: u8 = 0,
    /// `(parent.id, child.id)` of every link live at open (capped; the cycle is 3–4).
    edges_at_open: [16][2]u32 = undefined,
    disarms_at_open: u64 = 0,
    native_entries_at_open: u64 = 0,
    /// Phase 1 observations, refreshed on every post-open probe call.
    post_calls: u64 = 0,
    armed_after: usize = 0,
    disarms_after: u64 = 0,
    native_entries_after: u64 = 0,

    fn kindBit(k: trace.ArmKind) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(k));
    }
    fn hasKind(self: *const AviiiMidEpoch, k: trace.ArmKind) bool {
        return (self.kinds_at_open & kindBit(k)) != 0;
    }
};

/// Single-threaded test state; `zig test` runs the tests in a binary in order on
/// one thread, and `threadlocal` keeps that assumption explicit.
threadlocal var aviii_mid: AviiiMidEpoch = .{};

/// Does the captured `(parent.id, child.id)` edge list contain a directed cycle?
/// Visited-set BFS from each edge's head, asking whether it can reach that
/// edge's tail. With ≤16 edges there are ≤32 distinct node ids, so a queue of 32
/// suffices — but ONLY because a node is marked visited when it is *enqueued*,
/// never when it is dequeued: marking on dequeue lets duplicate endpoints of a
/// branching graph fill the queue before every distinct node is in it, which
/// silently drops reachable nodes and reports a false negative. (Marking on
/// enqueue makes each node enter the queue at most once, so `tail` can never
/// exceed the number of distinct ids.) Neither variant can produce a false
/// positive: every enqueued node sits at the end of a real directed path.
fn capturedGraphHasCycle(edges: []const [2]u32) bool {
    for (edges) |seed| {
        var queue: [32]u32 = undefined; // doubles as the visited set: queue[0..tail]
        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = seed[1];
        tail += 1;
        while (head < tail) {
            const node = queue[head];
            head += 1;
            if (node == seed[0]) return true; // walked back to the seed's parent
            for (edges) |e| {
                if (e[0] != node) continue;
                var enqueued = false;
                for (queue[0..tail]) |q| {
                    if (q == e[1]) enqueued = true;
                }
                if (enqueued or tail == queue.len) continue;
                queue[tail] = e[1];
                tail += 1;
            }
        }
    }
    return false;
}

/// The host native the A-viii mid-epoch program calls once per outer iteration.
/// It receives `*Vm` (interp.zig's `nat.func(@ptrCast(self), args)` call site),
/// which is exactly the reachability that makes this test possible: a host
/// native CAN flip `record_safepoint_lines` while an epoch and a fully-armed
/// link registry are live. Phase 0 waits for the outer cycle to close, captures
/// it, and opens the window; phase 1 just keeps re-reading the counters so the
/// test can assert against the last post-open observation.
fn aviiiProbe(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const m = &aviii_mid;
    if (!m.opened) {
        const links = vm.trace.armed_links.items;
        // Wait for a multi-edge cycle to stand: ≥3 links live at once.
        if (links.len < 3 or links.len > m.edges_at_open.len) return Value.nil();
        var kinds: u8 = 0;
        for (links) |l| kinds |= AviiiMidEpoch.kindBit(l.kind);

        m.armed_at_open = links.len;
        m.kinds_at_open = kinds;
        for (links, 0..) |l, i| m.edges_at_open[i] = .{ l.parent.id, l.child.id };
        m.disarms_at_open = vm.trace.native_link_disarms;
        m.native_entries_at_open = vm.trace.native_entries;
        m.opened = true;
        // THE EVENT: open the observation window over a live armed registry.
        vm.record_safepoint_lines = true;
        return Value.nil();
    }
    m.post_calls += 1;
    m.armed_after = vm.trace.armed_links.items.len;
    m.disarms_after = vm.trace.native_link_disarms;
    m.native_entries_after = vm.trace.native_entries;
    return Value.nil();
}

test "A-viii (doc 17 §A8 step 8): opening the window MID-EPOCH over a live armed link cycle tears it down" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The same-epoch half of §A8 step 8's oracle, and the one the two-leg test
    // below structurally cannot reach: there, the window is either open for the
    // whole run (so nothing ever arms — the teardown path is never exercised) or
    // closed for the whole run. The interesting transition is *arm the cycle,
    // THEN open the window*, and the reachable trigger for it is a host-installed
    // native: `nat.func(@ptrCast(self), args)` hands every native a `*Vm`, so
    // host code can set `record_safepoint_lines` with an epoch and a full link
    // registry live. (An earlier landing recorded that no such path existed. That
    // was wrong; codex found it, and this test is the correction.)
    //
    // What it pins, all scoped to the window-open EVENT rather than inferred
    // across two whole runs:
    //  1. the registry really did hold a multi-kind link graph containing a
    //     CYCLE at that instant — captured by kind and by `(parent.id,
    //     child.id)`, which a lifetime high-water mark cannot show;
    //  2. after further hot work under the open window the registry is EMPTY and
    //     every captured link was charged a disarm;
    //  3. the run is still trace-driven afterwards (`entries` advances) — the
    //     blackout removes the native→native handoffs, not the traces (R2-4).
    //
    // Scope boundary, stated rather than glossed: the live set captured here is
    // `.link_terminal` + `.loop_done_linked` + `.ordinary_guard`, NOT A-vii's
    // `.region_bridge`. That is measured, not assumed — the probe call is itself
    // a tier-0 effect inside the scan loop, and its presence changes the region
    // shape enough that the profit gate never qualifies the region, so edge 4
    // never arms in the probed variant (`native_region_bridge_arms == 0`), while
    // the unprobed program above arms it 39 times. Every attempted placement of
    // the probe that leaves the bridge armed also finds the registry empty at
    // the call instant — an empirical result, not a causal one: what actually
    // empties it between outer iterations is not pinned down (a region
    // activation is keyed to the frame's `call_seq`, not to one scan-loop
    // invocation, and `closeRegion` drops profitability state without itself
    // disarming a physical link). So the split is: the bridge's *arming and firing*
    // are covered by the two-leg test below, its *teardown* byte-for-byte by the
    // trace.zig unit test (which walks all four `ArmKind`s), and the mid-epoch
    // window transition over a live registry by this test.
    const gpa = testing.allocator;
    aviii_mid = .{};

    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, aviii_mid_epoch_source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [16]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    vm.source = aviii_mid_epoch_source;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotguard = 3;

    const native = try vm.heap.newNative(aviiiProbe, "aviii_probe");
    try vm.globals.set(gpa, try vm.heap.internValue("aviii_probe"), Value.heap(&native.header));

    var chunk = try compiler.compile(gpa, &vm.heap, aviii_mid_epoch_source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    // The program computes the same answer whatever the registry did.
    try testing.expectEqualStrings("109\n", sink.buffered());

    const m = &aviii_mid;
    // The premise: the cycle DID close mid-run and we DID flip the window over
    // it. If this ever stops holding the rest of the test is vacuous, so it is
    // an assertion, not a skip.
    try testing.expect(m.opened);
    try testing.expect(m.armed_at_open >= 3);
    // …and it is a genuine multi-kind cycle, not three copies of one edge kind.
    try testing.expect(m.hasKind(.link_terminal));
    try testing.expect(m.hasKind(.loop_done_linked));
    // B-2b can republish the historical ordinary source arm as the equivalent
    // registry-recognized sibling handoff from its persistent provenance edge.
    try testing.expect(m.hasKind(.ordinary_guard) or m.hasKind(.sibling_handoff));
    // …and the captured graph CONTAINS a cycle — at least one native→native
    // handoff that would loop forever without ever returning to the dispatcher
    // if the blackout missed it. (Not every live link need be on the cycle:
    // ramp-in edges into the cycle are armed too, and the measured capture is
    // exactly that shape — a 2-cycle plus a feeder.)
    try testing.expect(capturedGraphHasCycle(m.edges_at_open[0..m.armed_at_open]));

    // Real hot work ran after the flip — the teardown is not being read off an
    // immediately-terminating program.
    try testing.expect(m.post_calls >= 2);
    // (2) the whole registry is gone, and EXACTLY the captured edges were
    // charged: once the window is open `safe_to_arm` is false forever after, so
    // nothing can re-arm and the first blackout charges the captured set and
    // nothing else. An inequality here would tolerate a re-arm/re-disarm churn
    // that the invariant forbids.
    try testing.expectEqual(@as(usize, 0), m.armed_after);
    try testing.expectEqual(@as(u64, m.armed_at_open), m.disarms_after - m.disarms_at_open);
    // (3) still running NATIVE trace bodies under the open window, entered
    // through the dispatcher every time. `entries` alone would not carry this:
    // it is bumped before the native-vs-tier-1a choice, so a run that fell back
    // to the IR interpreter for every entry would still advance it. R2-4's claim
    // is specifically that the blackout removes the native→native handoffs, not
    // the native bodies — hence `native_entries`.
    try testing.expect(m.native_entries_after > m.native_entries_at_open);
    // (4) the documented scope boundary, pinned rather than only asserted in
    // prose: the probe's presence really does keep edge 4 from arming in this
    // variant, which is why the live set above has no `.region_bridge` in it.
    // If a future change makes the bridge survive a probed region, this fails
    // and the comment above must be revisited (a good failure to get).
    try testing.expectEqual(@as(u64, 0), vm.trace.native_region_bridge_arms);
}

test "A-viii (doc 17 §A8 step 8): the OUTER cycle arms as a closed cycle and fires; an open observation window contains it" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // §A8 step 8's oracle (round-3 review finding 4), in the terms the tree can
    // actually observe. The 2c-F test covers the INNER cycle (`C↔I`) across an
    // epoch boundary; this covers the OUTER cycle `skip → … → cont → skip`,
    // whose closing edge is A-vii's composite bridge (edge 4).
    //
    // The pair of legs is the test:
    //  * **Window closed (the positive leg):** the outer cycle must actually
    //    close and fire — a `.region_bridge` arm, fused bridge hops, and fused
    //    loop-done hops. (These are lifetime totals and cannot by themselves
    //    tell a standing closed cycle from edges armed and torn down in turn;
    //    the mid-epoch test above is what pins simultaneity, by capturing the
    //    live registry's kinds and `(parent, child)` ids at one instant.)
    //  * **Window open (the containment leg / negative control):** with
    //    `!safe_to_arm` the dispatcher must leave the whole registry empty —
    //    NOTHING arms (peak 0, zero bridge arms) — so no native→native handoff
    //    can fire through a patched slot and skip the dispatcher's
    //    safepoint/GC boundary. Per R2-4 that is NOT a collapse to tier-0
    //    bodies: traces still run, reached through the dispatcher every time,
    //    which is what `entries > 0` on this leg pins.
    // Both legs print the same answer, so containment is output-transparent.
    const gpa = testing.allocator;
    const armed = try runOuterCycle(gpa, false);
    const contained = try runOuterCycle(gpa, true);

    // (1) Output identity: containment cannot change what the program computes.
    try testing.expectEqualStrings("109\n", armed.output());
    try testing.expectEqualStrings("109\n", contained.output());

    // (2) Positive leg: the outer cycle is real, closed, and hot.
    try testing.expect(armed.bridge_arms > 0); // edge 4 armed at least once
    try testing.expect(armed.bridge_fused > 0); // …and a fused bridge hop ran
    try testing.expect(armed.loopdone_fused > 0); // …as did the inner loop-done edge
    try testing.expect(armed.peak >= 3); // …and ≥3 links were live at once at some point
    try testing.expect(armed.entries > 0);

    // (3) Containment leg: an open window keeps the registry empty for the whole
    // run — nothing armed, so nothing could fire through a stale slot.
    try testing.expectEqual(@as(u64, 0), contained.bridge_arms);
    try testing.expectEqual(@as(u64, 0), contained.bridge_fused);
    try testing.expectEqual(@as(u64, 0), contained.loopdone_fused);
    try testing.expectEqual(@as(usize, 0), contained.peak);
    // Nothing to tear down, so the disarm path never charges a slot either.
    try testing.expectEqual(@as(u64, 0), contained.disarms);

    // (4) …and the contained run is still trace-driven, NOT collapsed to tier-0
    // bodies (R2-4): traces still run, reached through the dispatcher every time.
    // Only the *existence* of dispatcher-mediated trace entries is asserted here.
    // Comparing the two legs' `entries` totals would NOT be sound — the legs
    // select different traces (the armed leg's fused hops change which exits are
    // ever taken, hence which side traces get recorded at all), so neither
    // direction of the inequality is a law. The event-scoped version of this
    // claim — `entries` advancing *after* a mid-run blackout within one run — is
    // in the mid-epoch test above, where both sides of the comparison come from
    // the same selection history.
    try testing.expect(contained.entries > 0);
}
