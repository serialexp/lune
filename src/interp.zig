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
const nativegen = @import("nativegen.zig");
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
        if (bn.recorded != null and bn.effect != null)
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

/// Doc 21 Phase A: the top-level result span published at a genuine finish.
/// `stack_top` is the (possibly B-6-raised) value the description is valid
/// for — capture rejects the cut if the live `stack_top` no longer matches.
pub const FinalCut = struct { result_base: u32, result_count: u32, stack_top: u32 };

/// Doc 21 Phase A: the capture-policy mask handed to the `.snapshot` root
/// walk — only stack slots inside `[base, base+len)` seed the walk.
pub const ResultSpan = struct { base: u32, len: u32 };

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
    /// running program produces; freed wholesale by `deinit`. **Heap-allocated
    /// with a stable address** (doc 24 D3/D5): `Vm` is a by-value struct that
    /// may move, but tier-1b native pages bake `&heap.gc_stress` /
    /// `&heap.object_count` / `&heap.next_gc` (the `guard_gc` budget guard) and
    /// the `*Heap` itself (the `tostr_*` callout arg) as imm64s — the same
    /// stability contract as `NativeSeedCtx`. Created by `initBare`; owned
    /// here (`deinit` destroys it).
    heap: *gc.Heap,
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
    /// Doc 21 Phase A (the H-5(i) fix): absolute description of the only live
    /// stack content after a genuine top-level finish — the returned result
    /// span. Published by public `exec` alone (the single top-level authority;
    /// a reentrant depth-0 `callValue` boundary pop must never stamp it),
    /// VALIDATED — not trusted — by snapshot capture (`depth == 0`, matching
    /// `stack_top`, in-bounds span), and invalidated by anything that reuses
    /// the stack (`pushFrameVararg`, `beginTopLevelEpoch`, `callValue` entry,
    /// the `protectedCall` manual unwind). Capture canonicalizes every final
    /// stack slot OUTSIDE the span to nil in the `.snapshot` walk + stack
    /// serialization, making the final snapshot a pure function of the
    /// program's logical result regardless of which tier produced the state.
    final_cut: ?FinalCut = null,
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
        // Doc 22 §B.1: the native seeding ctx. Heap-allocated so compiled pages
        // can bake its address as an imm64 (`Vm` is by-value and may move; this
        // may not). Created here rather than in `TraceState.init` to keep that
        // init infallible for its ~120 hand-built test call sites; ownership
        // (the free) lives in `TraceState.deinit`.
        const seed_ctx = try gpa.create(trace.NativeSeedCtx);
        errdefer gpa.destroy(seed_ctx);
        seed_ctx.* = .{ .seed_fn = &nativeSeedFn, .seed_tier1a_fn = &nativeSeedTier1aFn };
        // Stable-address heap (see the `heap` field doc): native pages bake
        // pointers to its collection counters, so it cannot live inside the
        // movable `Vm` by value.
        const heap = try gpa.create(gc.Heap);
        errdefer gpa.destroy(heap);
        heap.* = gc.Heap.init(gpa);
        var vm = Vm{
            .gpa = gpa,
            .heap = heap,
            .globals = undefined,
            .tags = tags,
            .payloads = payloads,
            .boundary_scratch = boundary_scratch,
            .trace = trace.TraceState.init(gpa),
        };
        vm.trace.native_seed_ctx = seed_ctx;
        // Doc 24 D5: the stable mutable heap channel for allocating traces
        // (tier-1a `.alloc` arms + tier-1b baked callouts). Safe to store once
        // because `heap` is a stable gpa allocation, unlike `&vm.heap`-style
        // interior pointers into the movable Vm.
        vm.trace.exec_heap = heap;
        return vm;
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
        self.gpa.destroy(self.heap);
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

    /// Doc 22 §B.2: the C-ABI seeding twin of `seedTraceInputs`, installed once
    /// into `NativeSeedCtx.seed_fn` at VM init. Called from a seeded page's
    /// entry prologue (B-ii) and from `driveChain`'s tier-1a seeding (B-iii),
    /// where no `*Vm` argument exists — everything comes through the ctx the VM
    /// filled at episode start (`prepareNativeEpisode`).
    ///
    /// Differences from the tier-0 original, by design:
    /// - Resolves only the plan's ACTIVE seeds (§A.1b): a seed the carried-heap
    ///   rewrite made redundant is skipped entirely — its slab slot stays
    ///   unwritten and its validation cannot spuriously decline the entry.
    /// - Returns the tri-state decline grammar instead of (null, *bool):
    ///   `SEED_CAPACITY_DECLINE` before ANY slab write if the seed slots don't
    ///   fit, `SEED_HASH_DECLINE` if a hash_cell seed failed validation (the
    ///   0-bits slot is still written, exactly like the original, so tier-1a
    ///   sees the same slab state), else `SEED_OK`.
    /// - Allocation-free and GC-safe: resolution + validation only (upvalue
    ///   reads, global lookups, hash-chain walks). Deliberately NOT a
    ///   `nativegen.BodyCallout` row — that enum answers "can a heap φ die
    ///   across this MID-ITERATION call site", and this runs once at entry
    ///   before any φ is live. See the `BodyCallout` header.
    fn nativeSeedFn(
        ctx: *const trace.NativeSeedCtx,
        ct: *const trace.Trace,
        plan_bits: u64,
    ) callconv(.c) u64 {
        // The plan arrives by value (see `NativeSeedCtx.seed_fn`): reconstruct the
        // bitmap wrapper locally.
        const plan = nativegen.SeedPlan{ .bits = plan_bits };
        const self: *Vm = @ptrCast(@alignCast(ctx.vm));
        const closure: *const function.Closure = @ptrCast(@alignCast(ctx.closure));
        const proto: *const Proto = @ptrCast(@alignCast(ctx.proto.?));
        // Capacity over ACTIVE seeds only — an inactive seed's slot is never
        // written, so it cannot demand slab room.
        var count: usize = proto.num_registers;
        for (ct.inputs, 0..) |seed, i| {
            if (!plan.isActive(i)) continue;
            count = @max(count, @as(usize, seed.slot) + 1);
        }
        if (ctx.base + count > ctx.reg_capacity) return trace.NativeSeedCtx.SEED_CAPACITY_DECLINE;
        var ok = true;
        for (ct.inputs, 0..) |seed, i| {
            if (!plan.isActive(i)) continue;
            const v = switch (seed.kind) {
                .upvalue => self.upvalGet(closure.upvalues[seed.source]),
                .global => self.globals.get(proto.constants[seed.source]),
                .hash_cell => blk: {
                    const vtab = self.regGet(ctx.base + seed.table_reg);
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
                    if (cell_bits == 0) ok = false;
                    break :blk Value{ .tag = .int, .payload = .{ .bits = cell_bits } };
                },
            };
            self.regSet(ctx.base + seed.slot, v);
        }
        return if (ok) trace.NativeSeedCtx.SEED_OK else trace.NativeSeedCtx.SEED_HASH_DECLINE;
    }

    /// Doc 22 §B.3: the tier-1a seeding twin, installed into
    /// `NativeSeedCtx.seed_tier1a_fn` at VM init and called from `driveChain`'s
    /// chain seams (trace.zig `seedForTier1a`) before each `irinterp.execute`
    /// of a seeded successor. Unlike the C-ABI plan twin (`nativeSeedFn`) it
    /// resolves the FULL input set — tier-1a's `slot_load`s read every
    /// synthetic slot; a seed plan is a native-page concept (carried-heap
    /// rewrites) that never deactivates tier-1a's needs — so it delegates to
    /// `seedTraceInputs` itself, guaranteeing byte-identical resolution +
    /// validation to a dispatcher entry, and maps the (window, native_eligible)
    /// result onto the ctx tri-state:
    /// - null window → SEED_CAPACITY_DECLINE (nothing written),
    /// - hash-cell validation failure → SEED_HASH_DECLINE (the 0-bits slot IS
    ///   written, exactly like the dispatcher — tier-1a's `href` re-derives the
    ///   cell and side-exits at the same guard, so it remains runnable),
    /// - else SEED_OK.
    /// The returned (widened) window is discarded: chain seams execute with the
    /// caller's window, whose lane pointers view the same slab — the synthetic
    /// slots sit in dead scratch above the frame that the capacity check just
    /// bounded, and `RegWindow` accessors are unbounded pointer offsets.
    fn nativeSeedTier1aFn(ctx: *const trace.NativeSeedCtx, ct: *const trace.Trace) u64 {
        const self: *Vm = @ptrCast(@alignCast(ctx.vm));
        const closure: *const function.Closure = @ptrCast(@alignCast(ctx.closure));
        const proto: *const Proto = @ptrCast(@alignCast(ctx.proto.?));
        var native_eligible = true;
        _ = self.seedTraceInputs(ct, ctx.base, closure, proto, RegWindow.empty, &native_eligible) orelse
            return trace.NativeSeedCtx.SEED_CAPACITY_DECLINE;
        return if (native_eligible)
            trace.NativeSeedCtx.SEED_OK
        else
            trace.NativeSeedCtx.SEED_HASH_DECLINE;
    }

    /// Doc 22 §B.1: publish the current activation into the per-VM seeding ctx
    /// at native-episode start, so a seeded page's baked `&ctx` (B-ii) and
    /// `driveChain`'s tier-1a seeding (B-iii) describe THIS entry. `proto` +
    /// `call_seq` are the freshness stamp consumers check (`stubEnterable`,
    /// B-iv). No-op when the ctx is absent (hand-built test TraceStates).
    fn prepareNativeEpisode(self: *Vm, closure: *const function.Closure, proto: *const Proto, base: usize) void {
        const ctx = self.trace.native_seed_ctx orelse return;
        ctx.vm = self;
        ctx.closure = closure;
        ctx.base = base;
        ctx.reg_capacity = self.regCapacity();
        ctx.proto = proto;
        ctx.call_seq = self.frames[self.depth - 1].call_seq;
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
        native.recorded = bn.recorded; // null unless a JIT-inlinable pure builtin (e.g. sqrt)
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
        self.final_cut = null; // doc 21: the previous run's cut is stale now
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
        // Doc 21: a frame push implies the cut is already invalid — every
        // execution path reaching here started at a cold boundary that nulled
        // it (`beginTopLevelEpoch` for run/start, `callValue` entry for host
        // reentry, and an exec-resume implies a suspended VM that never
        // finished, so no cut was ever published). Assert the invariant
        // instead of paying a per-call store in the dispatch hot path.
        std.debug.assert(self.final_cut == null);

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
        self.final_cut = null; // doc 21: host reentry reuses the stack
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
    pub fn collect(self: *Vm) void {
        self.heap.beginCollect() catch return;
        // The root set is defined once in `forEachRootHeader`; marking is just
        // "call `markHeader` on each root".
        self.forEachRootHeader(.gc, null, self.heap, gc.Heap.markHeader);
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
        snapshot_mask: ?ResultSpan,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), *object.GcHeader) void,
    ) void {
        // Doc 21 Phase A: at a validated final-state capture the `.snapshot`
        // walk seeds ONLY from the top-level result span — a heap object whose
        // only reference is a dead slot is semantic garbage, and excluding it
        // makes the reachable SET (not just the stack bytes) a pure function
        // of the program's logical state. The `.gc` walk never masks: the
        // collector's view of liveness is not the snapshot's business.
        if (kind == .gc) std.debug.assert(snapshot_mask == null);
        cb(ctx, &self.globals.header);
        {
            var i: usize = if (snapshot_mask) |m| m.base else 0;
            const hi: usize = if (snapshot_mask) |m| @as(usize, m.base) + m.len else self.stack_top;
            while (i < hi) : (i += 1) {
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
        // Loaded chunks (docs/design/19): a `load`/`loadfile`/`dofile`/`require`
        // chunk's protos are VM-owned until deinit (`loaded_chunks` never shrinks),
        // so their interned constants are rooted for the VM's lifetime too — in
        // BOTH walks, like `retained_chunks` above: membership is deterministic
        // guest behaviour, hence mode-invariant, so the `.snapshot` walk stays
        // byte-identical across modes and restore preserves constant-id
        // continuity (keyframe v8's zero-allocation recompile invariant). This
        // makes a trace const over a loaded proto ALWAYS redundant, which is what
        // licenses tracing the loaded tree (doc 17's H-2 dynamic-proto gate,
        // lifted by doc 19).
        for (self.loaded_chunks.items) |lc| rootProtoConsts(lc.chunk.proto, ctx, cb);
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
        // Doc 21 Phase A: public `exec` is the SINGLE publication authority for
        // `final_cut` — `run`/`start` route through here, while a reentrant
        // depth-0 `callValue` uses private `execWith` and therefore never
        // stamps (codex doc-21 B-1: the stop-depth pop alone cannot tell the
        // two apart). The root window base is 0 by construction for every
        // sanctioned entry (`run`/`start` push at 0; restore enforces
        // `frames[0].base == 0` via FrameWindowMismatch) — cache-and-validate
        // it here rather than trusting it, and never read the popped frame's
        // stale storage afterwards.
        const root_base_ok = self.depth >= 1 and self.frames[0].base == 0;
        const outcome = try self.execWith(1);
        if (outcome == .finished and self.depth == 0 and root_base_ok) {
            const fr = outcome.finished;
            // Codex doc-21 B-6: an `all_results` return resolves its count from
            // the dynamic `reg_top`, so the span can extend past the static
            // root window that `stack_top` covers after the pop — and capture
            // serializes only `stack[0..stack_top]`, which would silently drop
            // the surplus results. Raise `stack_top` over the span BEFORE
            // publishing so every returned value is rooted and capturable;
            // an out-of-capacity span publishes nothing (fail-safe: capture
            // then masks nothing, exactly today's behaviour).
            const result_end = @as(usize, fr.reg) + fr.count;
            if (result_end <= self.regCapacity()) {
                if (result_end > self.stack_top) self.stack_top = result_end;
                self.final_cut = .{
                    .result_base = fr.reg,
                    .result_count = fr.count,
                    .stack_top = @intCast(self.stack_top),
                };
            }
        }
        return outcome;
    }

    /// `exec`, bounded by a stop depth. The dispatch loop returns `.finished` the
    /// instant a `.ret`/`.halt` pops the frame at `stop_depth` (the top-level main
    /// frame for `stop_depth == 1`; a reentrant `callValue`'s nested top frame for
    /// `stop_depth == entry_depth + 1`). Threads `stop_depth` through the
    /// `switch_mode` re-entry so a mode flip mid-nested-run resumes the same bound.
    fn execWith(self: *Vm, stop_depth: u32) Error!ExecOutcome {
        errdefer self.trace.clearPendingExitAnchor();
        // Doc 26 D1a: an error unwinding through the dispatch loop kills any
        // active recording — the raise is invisible to the recorded IR, so a
        // surviving recording would splice an enclosing pcall's continuation
        // onto the partial iteration. Guarded no-op when idle; suspension is a
        // normal return (`.suspended`), so suspend/resume recordings are
        // untouched.
        errdefer self.trace.abortRaised();
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

        // A recording is one CFG cycle, not necessarily one syntactic back-edge.
        // Close before mirroring when forward flow re-enters its anchor (nested
        // loops can do this after an enclosing back-edge). The ordinary matching
        // back-edge already closed in `onBackEdge`, making this a cheap no-op.
        if (mode == .full and self.trace.isRecording())
            self.trace.maybeCloseAtAnchor(proto, @intCast(cur), regs);
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
            // Doc 20 §R1-3: the mirror always records the CANONICAL
            // instruction. `i` came from the fetch `code` slice, which may be
            // a patched image — a recording crossing a patched pc (a sibling
            // loop of the one being recorded) must see the virgin loop closer
            // (`.for_loop`, `.jmp`, or `.jmp_if_false`) and virgin shape checks,
            // byte-identical with or without the patch. `proto.code` is
            // canonical by construction (§R1).
            const mi = recordingMirrorInstr(proto, cur, i);
            const resolved: Value = switch (mi.op) {
                .get_upval => self.upvalGet(closure.upvalues[mi.b]),
                .get_global => self.globals.get(proto.constants[mi.b]),
                else => Value.nil(),
            };
            // Refresh the recorder's read-only heap channel (doc 23 D2) — the
            // same supply-per-call pattern as `resolved`, so the recorder never
            // holds a `*Heap` it wasn't just handed by its driver.
            self.trace.rec_heap = self.heap;
            self.trace.recordInstr(mi, regs, proto, @intCast(pc.*), resolved);
        }
        return i.op;
    }

    /// Phase 0a (doc 20): what the factored entry routine tells its caller's
    /// epilogue to do. `resume_tier0` = the old `continue :outer` (pc possibly
    /// advanced by a chain resume); `switch_mode_at` = park pc and flip the
    /// dispatch mode (the old `frame.pc = pc; return .switch_mode`).
    const EntryDirective = union(enum) {
        next_candidate,
        resume_tier0: usize,
        switch_mode_at: usize,
    };

    /// Same-anchor trial-walk cap (visited/dead arrays; `dead ⊆ visited`).
    const trial_visited_cap = 8;

    /// Walk-owned state the entry routine reads/appends: the visited prefix
    /// (chain exclusion sets) and the widen-eviction dead list. The
    /// `.jfor_loop` arm (doc 20 Phase 1) passes `{ct}` — the chain-exclusion
    /// invariant is `ct ∈ visited` — and an empty dead list.
    const TrialWalkCtx = struct {
        visited: []const *trace.Trace,
        dead: *[trial_visited_cap]*trace.Trace,
        ndead: *usize,
    };

    /// Phase 0a (doc 20 §R1-4/§R3-3): the single factored per-candidate entry +
    /// receipt routine — seed resolution, scratch borrow, coverage brackets,
    /// `safe_to_arm`, `disarmAllLinks`, `tryArmSiblingHandoff`,
    /// `prepareNativeEntry`, native/tier-1a execution, and the FULL result
    /// grammar (silent + multi-row ledger drains, hotexit counting, receipts,
    /// continuation/prime arming, chain driving, the T3 handoff). Moved verbatim
    /// from the same-anchor trial walk; both the walk and (Phase 1) the
    /// `.jfor_loop` arm call it and act on the returned directive in their own
    /// caller-owned epilogue — the future safe-point drain site (doc 20).
    fn enterSelectedTrace(
        self: *Vm,
        comptime mode: ExecMode,
        ct: *trace.Trace,
        closure: *const function.Closure,
        proto: *const Proto,
        regs: RegWindow,
        base: usize,
        pc_in: usize,
        wctx: *TrialWalkCtx,
    ) EntryDirective {
        var pc = pc_in;
        // Doc 22 §B.2: resolve the native page BEFORE any VM-side seeding, so the
        // two seeding paths never both run (the dedup half of B-ii). A page whose
        // seed plan is non-empty seeds ITSELF in its entry prologue (via the
        // baked `NativeSeedCtx`), so a native entry passes the NARROW `regs` —
        // pointer-identical to the widened window (`frameWindow` slices the same
        // slab base; native code addresses slots by offset from the base pointers
        // and never reads the slice length). VM-side seeding remains for every
        // non-native run: exec-log, tier-1a (no page / hash-decline rerun).
        // Hoisting the lazy `nativeFor` compile above `seedTraceInputs`/
        // `tryArmSiblingHandoff` can complete a compile one entry earlier than
        // before — sound (arming choices steer tiers, never output) and verified
        // by the 8-mode gate.
        const native_page: ?*const nativegen.CompiledTrace =
            if (self.trace.config.native_codegen and !self.trace.config.record_exec_log)
                self.trace.nativeFor(ct)
            else
                null;
        // Cluster sub-lever 1: a trace that reaches a callee
        // through an upvalue/global carries synthetic entry
        // inputs. Seed each into the dead slab region above the
        // anchor window and widen the executor window to cover
        // them; an input-free trace reuses the narrow `regs`. A
        // capacity overflow declines the entry (run tier-0).
        // `native_eligible` is the H1 hash_cell out-flag; with the
        // native path now seeding itself it only ever accompanies a
        // run that is ALREADY tier-1a, so its value is no longer
        // consulted (the prologue's SEED_HASH_DECLINE is the native
        // twin of the downgrade it used to signal).
        var native_eligible = true;
        var trace_regs = if (native_page != null)
            regs
        else
            self.seedTraceInputs(ct, base, closure, proto, regs, &native_eligible) orelse return .next_candidate;
        // The entering trace's executor frame — pushed ONLY when the tier-1a
        // executor can actually run, i.e. no native page resolved
        // (`native_page == null` also covers exec-log, which forces the page
        // null above). A successful native entry touches the scratch nowhere:
        // not the executor, not the exec-log path, not the
        // `.ir_numeric_for_done` chain — every `buf` consumer below sits on a
        // road native cannot reach. Yet the unconditional push made the native
        // path pay the most for the discipline while using it least (+0.43%
        // scimark-fft, +0.59% scimark-lu by instruction count, at 1.0M/2.5M
        // entries). The one native road BACK onto the executor — the
        // seed-hash-decline downgrade — re-pushes at its rerun site below.
        //
        // The frame must stay valid for the whole block: `driveChain` is
        // handed this exact slice as the `.ir_numeric_for_done` payload and
        // pushes frames of its own on top, so the release is deferred on
        // `buf_live` rather than scoped to the `execute` call. The flag (not
        // the block structure, as before) is now what keeps the release off
        // the paths that never pushed — including every native return.
        // `values_mark` is taken only alongside a push; it is `undefined`
        // otherwise and the flag guard is what makes that sound.
        var values_mark: trace.TraceState.ValuesMark = undefined;
        var buf: []Value = &.{};
        var buf_live = false;
        if (native_page == null) {
            values_mark = self.trace.valuesMark();
            buf = self.trace.valuesPush(ct.instrs.len) catch
                return .next_candidate; // OOM: skip this trace, try next
            buf_live = true;
        }
        {
            defer if (buf_live) self.trace.valuesRelease(values_mark);
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
            // Doc 22 §B.1: publish this activation into the seeding ctx once
            // per episode. This single funnel covers every consumer — the
            // direct-native run below (its seeded prologue, B-ii), the tier-1a
            // `driveChain` path (its seeding twin, B-iii), and patched entries
            // (`enterPatchedTrace` funnels through here too).
            self.prepareNativeEpisode(closure, proto, base);
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
            var result = if (self.trace.config.record_exec_log) blk: {
                const tid = self.trace.traceIndex(ct) orelse break :blk irinterp.executeCtx(.{ .heap = self.heap }, ct, trace_regs, buf);
                const rec = self.trace.execRecorderFor(tid) orelse break :blk irinterp.executeCtx(.{ .heap = self.heap }, ct, trace_regs, buf);
                break :blk irinterp.executeTracedCtx(.{ .heap = self.heap }, rec, ct, trace_regs, buf);
            } else blk: {
                // Doc 22 §B.2: `native_page` was resolved above (before VM-side
                // seeding); non-null implies native_codegen && !record_exec_log.
                if (native_page) |nt| {
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
                break :blk irinterp.executeCtx(.{ .heap = self.heap }, ct, trace_regs, buf);
            };
            if (ran_native) {
                if (self.trace.driveDispatcherSilentResult(ct, result, proto, regs, safe_to_arm)) |chain| {
                    if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                    const armed_side = self.trace.consumeSideTraceWantAtResume(proto, @intCast(pc));
                    for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                    if (armed_side and mode == .fast) {
                        return .{ .switch_mode_at = pc };
                    }
                    return .{ .resume_tier0 = pc };
                }
            }
            // Doc 22 §B.2: seed-decline dispatch. A seeded page's entry prologue
            // declined BEFORE its body ran (nothing committed, regs untouched at
            // this anchor). Neither decline charges a strike or feeds the receipt
            // funnel — the decline is an entry-condition mismatch, not a guard
            // failure. B-iv: these direct handlers own ONLY the scalar
            // `ledger_len <= 1` case (the directly-entered trace itself
            // declined). A FUSED span that reaches a seeded successor's
            // prologue stamps the same shared `exit_reason` but carries a
            // committed prefix in its multi-row ledger — it must flow to the
            // `driveDispatcherLedger` consumer below, whose replay walks the
            // prefix and applies the §B.2 fused-decline directive; rerunning
            // `ct` (the ENTERED trace, not the decliner) here would discard
            // that prefix.
            if (ran_native and result.ledger_len <= 1 and
                result.exit_reason == .seed_capacity_decline)
            {
                // The native twin of `seedTraceInputs` returning null (the seed
                // slots don't fit the register slab): the candidate itself is
                // unusable at this depth — same directive as the VM-side wall.
                self.trace.dbg("seed-capacity-decline: trace={d} anchor={d}", .{ ct.id, ct.anchor.pc });
                self.trace.seed_capacity_declines +|= 1;
                return .next_candidate;
            }
            if (ran_native and result.ledger_len <= 1 and
                result.exit_reason == .seed_hash_decline)
            {
                // The native twin of the pre-B-ii `native_eligible = false`
                // downgrade (H1): a hash_cell seed failed validation, so THIS
                // entry runs on tier-1a. The prologue's seeding twin already
                // wrote the slab (including the 0-bits cell slot); the VM-side
                // rerun below re-derives the identical state and widens the
                // window for tier-1a's synthetic slots. The tier-1a result then
                // feeds the FULL ordinary consumer grammar below with
                // `ran_native = false` — byte-identical to the old route (the
                // oracle side-exits at the same `guard_table`/`guard_hash`).
                self.trace.dbg("seed-hash-decline: trace={d} anchor={d} -> tier-1a rerun", .{ ct.id, ct.anchor.pc });
                self.trace.seed_hash_declines +|= 1;
                trace_regs = self.seedTraceInputs(ct, base, closure, proto, regs, &native_eligible) orelse return .next_candidate;
                // The downgrade is the one native road back onto the tier-1a
                // executor, and native entries skip the entry push above — so
                // take the frame here. The mark is fresh, not the entry's:
                // `values_mark` is `undefined` on this path, and retaking it is
                // also correct in itself (everything the native run's burst
                // machinery pushed above was released before we got here, so
                // the stack is back at its entry state).
                values_mark = self.trace.valuesMark();
                buf = self.trace.valuesPush(ct.instrs.len) catch
                    return .next_candidate; // OOM: same skip as the entry push
                buf_live = true;
                result = irinterp.executeCtx(.{ .heap = self.heap }, ct, trace_regs, buf);
                ran_native = false;
                ran_native_link_mode = false;
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
            var excl: [trial_visited_cap + 1]*trace.Trace = undefined;
            var nexcl: usize = 0;
            if (final != ct) {
                excl[nexcl] = final;
                nexcl += 1;
            }
            for (wctx.visited) |v| {
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
            //
            // Doc 22 §B.2 (B-iv): fused SEED-DECLINE terminals drain
            // here too — the direct handlers above are gated to
            // `ledger_len <= 1`, so a span like `[T.link_terminal,
            // U.seed_hash_decline]` reaches `replayLedger`'s decline
            // arms, which walk the committed prefix and resume
            // deterministic selection at the DECLINER's coherent
            // anchor (no strike, no receipt — a decline is an
            // entry-condition mismatch, not a guard failure). The
            // hash rerun/downgrade happens on re-selection via the
            // direct-entry H1 path, never in-drain.
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
                for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                if (armed_side and mode == .fast) {
                    return .{ .switch_mode_at = pc }; // → .full
                }
                return .{ .resume_tier0 = pc };
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
                for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
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
                        return .{ .switch_mode_at = pc }; // → .full
                    }
                    return .{ .resume_tier0 = pc }; // already `.full`
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
                        for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                        if (mode == .fast) {
                            return .{ .switch_mode_at = pc }; // → .full
                        }
                        return .{ .resume_tier0 = pc }; // already `.full`
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
                        for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                        return .{ .resume_tier0 = pc };
                    }
                } else if (!ran_native) {
                    if (self.trace.driveChain(final, result, proto, trace_regs, .ir, .{ .ir_numeric_for_done = buf }, &.{}, safe_to_arm)) |chain| {
                        if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                        for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                        return .{ .resume_tier0 = pc };
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
                // passed, not a trace-local `trace_regs`, and
                // that is intentional. NOT because the entered
                // traces are input-free — since B-iii/B-iv
                // (doc 22 §B.3/§B.5) `findLinkTrace` admits
                // SEEDED continuations, so `t.inputs.len` is
                // routinely nonzero. The reason is that a
                // trace's `inputs` are non-register state
                // (upvalues, globals, hash cells) resolved
                // through the seed path into its own slab —
                // never a remapping OF registers. Loop/link
                // roots still read their register state
                // directly from the coherent file at their
                // anchor, so there is nothing to thread and
                // the live regs remain exactly what each
                // entered trace expects.
                if (self.trace.isSourceBranchGuardExit(final, result.exit_instr, proto)) {
                    if (ran_native) {
                        if (self.trace.driveChain(final, result, proto, regs, .native_only, .ordinary_header, excl[0..nexcl], safe_to_arm)) |chain| {
                            if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                            for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                            return .{ .resume_tier0 = pc };
                        }
                    } else {
                        if (self.trace.driveChain(final, result, proto, regs, .ir, .ordinary_header, excl[0..nexcl], safe_to_arm)) |chain| {
                            if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                            for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                            return .{ .resume_tier0 = pc };
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
                    return .{ .switch_mode_at = pc };
                }
                return .{ .resume_tier0 = pc };
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
            if (final == ct and wctx.ndead.* < wctx.dead.len and self.trace.laneWidenedPast(ct, regs)) {
                wctx.dead[wctx.ndead.*] = ct;
                wctx.ndead.* += 1;
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
                    for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                    return .{ .resume_tier0 = pc };
                }
            } else {
                if (self.trace.driveChain(final, result, proto, regs, .ir, .ordinary_header, excl[0..nexcl], safe_to_arm)) |chain| {
                    if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                    for (wctx.dead[0..wctx.ndead.*]) |dt| self.trace.removeTrace(dt);
                    return .{ .resume_tier0 = pc };
                }
            }
        }
        return .next_candidate;
    }

    /// Doc 20 Phase 3: common patched-entry tail for `.jfor_loop` and
    /// `.jloop`. The opcode arms own their exact canonical step semantics;
    /// once a back-edge is taken they both enter through the one Phase-0a
    /// `enterSelectedTrace` routine and share strike/unpatch accounting.
    inline fn enterPatchedTrace(
        self: *Vm,
        comptime mode: ExecMode,
        patch: *trace.EntryPatch,
        slot: u16,
        closure: *const function.Closure,
        proto: *const Proto,
        regs: RegWindow,
        base: usize,
        pc: usize,
    ) EntryDirective {
        const ct = patch.trace; // live pre-drain ⇒ valid (§R7-2)
        var dead: [trial_visited_cap]*trace.Trace = undefined;
        var ndead: usize = 0;
        // The walk marks each candidate visited before entering. A patched
        // entry has no walk, so seed the exclusion set with exactly `ct`.
        var visited_ct = [1]*trace.Trace{ct};
        var wctx: TrialWalkCtx = .{
            .visited = visited_ct[0..1],
            .dead = &dead,
            .ndead = &ndead,
        };
        var directive = self.enterSelectedTrace(mode, ct, closure, proto, regs, base, pc, &wctx);
        // A patched entry has no sibling walk. If its zero-progress exit made a
        // side want hot, consume it at the coherent header now; otherwise the
        // back-edge arm is one iteration late and records the old shape again.
        if (directive == .next_candidate and self.trace.consumeSideTraceWantAtResume(proto, @intCast(pc))) {
            directive = if (mode == .fast)
                .{ .switch_mode_at = pc }
            else
                .{ .resume_tier0 = pc };
        }
        // §R6-1/§R7-1 strict order: inspect the stable slot before the drain,
        // mark strike exhaustion, retire dead traces, drain the entire pending
        // set, then never touch `patch` again (the slot may have been reused).
        if (patch.live) {
            if (directive == .next_candidate) {
                patch.strikes +|= 1;
                if (patch.strikes >= self.trace.config.patch_strikes)
                    self.trace.markEntryPatchPending(slot);
            } else {
                patch.strikes = 0;
            }
        }
        for (dead[0..ndead]) |dt| self.trace.removeTrace(dt);
        self.trace.drainEntryPatchWork();
        return directive;
    }

    fn execImpl(self: *Vm, comptime mode: ExecMode, stop_depth: u32) Error!ExecStep {
        // Hot top-frame state, reloaded from `frames[depth-1]` after every push/pop.
        var frame: *CallFrame = &self.frames[self.depth - 1];
        var closure = frame.closure;
        var proto = closure.proto;
        // Doc 20: dispatch fetches from the VM-local copy-on-patch image when
        // one exists (canonical `proto.code` otherwise — the empty-map early-out
        // makes that one counter load). `code_gen` memoizes the image
        // generation; the back-edge epilogue re-resolves when it moves (§R2-1).
        var code = self.trace.codeFor(proto);
        var code_gen = self.trace.image_gen;
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
                // Doc 20 Phase 1 (patched trace entry, the BC_JFORL analogue):
                // only ever fetched from a per-VM copy-on-patch code image
                // over a qualified `.for_loop`; canonical `Proto.code` never
                // contains it. §R2-3 discipline: the shared `for_loop` step
                // runs EXACTLY once, and every non-entered back-edge reaches
                // the ordinary epilogue presenting the canonical instruction
                // (`patch.orig`, §R2-5) — no shortcut, no rewind/refetch.
                .jfor_loop => {
                    const slot: u16 = instr.b;
                    const patch = self.trace.entry_patches.items[slot];
                    const live = patch.live;
                    if (!live) {
                        // §R6-1 pre-step recovery — a LEGITIMATE deferred-
                        // unpatch state, not a defensive-unreachable one
                        // (codex post-landing review of 7fa7e1a): marks can
                        // originate outside any drained grammar — recorder
                        // aborts (`gateAnchor(rec.anchor)`) fire mid-dispatch
                        // where draining would install under a frame that
                        // cannot re-resolve its image pointer, and the walk's
                        // post-epilogue retire/miss/gate sites mark after
                        // their turn's drain. This arm is the sole
                        // slot-pointer holder and sits outside any receipt
                        // grammar, so the complete synchronous unpatch
                        // transaction is safe here; then continue as the
                        // virgin `.for_loop` arm below (`break :sw` after the
                        // step). `patch.orig` stays readable through the
                        // tombstone: reuse only happens in a drain's install
                        // pass, and none runs between here and the step.
                        self.trace.unpatchSlot(slot);
                    }
                    // §R2-5: everything downstream — the epilogue's
                    // `instr.op == .for_loop` reads, the recorder mirror —
                    // sees the canonical instruction. Same `a`/`aux`
                    // operands by construction (install preserves them).
                    instr = patch.orig;
                    // The shared numeric-`for` step, exactly once — INCLUDING
                    // the internal-index increment, the `.for_loop` arm's
                    // first line (omitting it re-takes the back-edge with a
                    // stale index: the §R2-3 hazard, caught as +strikes×n
                    // guest corruption in the T3 e2e test).
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
                    // Loop exit → fall through exactly as `.for_loop` (the
                    // back-edge block is never revisited — `pc <= cur_pc`).
                    // A patch exists ⇒ tracing is enabled, so the plain
                    // comparison is the same predicate `.for_loop` uses.
                    if (!(pc <= cur_pc)) {
                        continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                    }
                    // Defensive-unpatched: virgin cascade (cold path IS the
                    // existing cascade, reached by unpatching BEFORE the step
                    // ran above — §R2-3's double-increment hazard avoided).
                    if (!live) break :sw;
                    // §R1-5 bypass set — live authoritative fields, no
                    // maintained flag: the `runFastPath` `.full` set plus
                    // exec-log and coverage. Take the back-edge through the
                    // ordinary epilogue with `patch.orig` presented, so
                    // recording, coverage attribution, `onBackEdge`, and
                    // trace closure all see virgin `.for_loop` behaviour.
                    if (self.trace.isRecording() or self.suspend_ctl != null or
                        self.record_safepoint_lines or self.trace.config.record_exec_log or
                        self.trace.pending_exit_anchor != null or
                        self.trace.pending_replay_anchor != null or
                        self.trace.config.coverage)
                    {
                        break :sw;
                    }
                    // Patched entry: skip exactly the discovery/selection
                    // prefix (hot-count probe, counters hashmap, trip
                    // computation, isGated, walk, fingerprint — the native
                    // prologue's fail-closed type check subsumes the
                    // fingerprint at entry, per the B-4 discipline) and run
                    // the identical entry/receipt routine the walk uses.
                    const directive = self.enterPatchedTrace(mode, patch, slot, closure, proto, regs, base, pc);
                    if (self.trace.image_gen != code_gen) {
                        code = self.trace.codeFor(proto);
                        code_gen = self.trace.image_gen;
                    }
                    switch (directive) {
                        .next_candidate => {
                            // Fall through to the tier-0 body. Mirror the
                            // walk's T3 invariant: a recording must never run
                            // under `.fast` (its prologue elides the mirror).
                            if (mode == .fast and self.trace.isRecording()) {
                                frame.pc = pc;
                                return .switch_mode;
                            }
                            continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                        },
                        .resume_tier0 => |npc| {
                            pc = npc;
                            continue :outer;
                        },
                        .switch_mode_at => |npc| {
                            frame.pc = npc;
                            return .switch_mode;
                        },
                    }
                },
                // Doc 20 Phase 3: patched entry for the loop-closing jumps the
                // compiler actually emits — `.jmp` for `while`, and
                // `.jmp_if_false` for `repeat`. The slot's canonical `orig`
                // selects the exact jump semantics; only a taken back-edge may
                // enter native. All bypasses present `orig` to the ordinary
                // back-edge epilogue, exactly like `.jfor_loop`.
                .jloop => {
                    const slot: u16 = instr.b;
                    const patch = self.trace.entry_patches.items[slot];
                    const live = patch.live;
                    if (!live) {
                        // Same load-bearing deferred-unpatch recovery as the
                        // numeric-for arm: complete the transaction before
                        // executing the canonical jump once.
                        self.trace.unpatchSlot(slot);
                    }
                    instr = patch.orig;
                    a = instr.a;
                    switch (instr.op) {
                        .jmp => pc = applyJump(pc, instr.aux),
                        .jmp_if_false => if (!regs.get(a).isTruthy()) {
                            pc = applyJump(pc, instr.aux);
                        },
                        else => unreachable, // install accepts only compiler loop closers
                    }
                    // A repeat condition that is true exits the loop. `while`'s
                    // unconditional closer always takes its back-edge.
                    if (!(pc <= cur_pc)) {
                        continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                    }
                    if (!live) break :sw; // restored virgin cascade
                    if (self.trace.isRecording() or self.suspend_ctl != null or
                        self.record_safepoint_lines or self.trace.config.record_exec_log or
                        self.trace.pending_exit_anchor != null or
                        self.trace.pending_replay_anchor != null or
                        self.trace.config.coverage)
                    {
                        break :sw;
                    }
                    const directive = self.enterPatchedTrace(mode, patch, slot, closure, proto, regs, base, pc);
                    if (self.trace.image_gen != code_gen) {
                        code = self.trace.codeFor(proto);
                        code_gen = self.trace.image_gen;
                    }
                    switch (directive) {
                        .next_candidate => {
                            if (mode == .fast and self.trace.isRecording()) {
                                frame.pc = pc;
                                return .switch_mode;
                            }
                            continue :sw (try self.nextOp(mode, frame, closure, proto, code, regs, &pc, &cur_pc, &instr, &a) orelse return .suspended);
                        },
                        .resume_tier0 => |npc| {
                            pc = npc;
                            continue :outer;
                        },
                        .switch_mode_at => |npc| {
                            frame.pc = npc;
                            return .switch_mode;
                        },
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
                            if (!tbl.array.isGrid() and array.ArrayPart.inArray(i, tbl.array.asize)) {
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
                            if (!tbl.array.isGrid() and array.ArrayPart.inArray(i, tbl.array.asize) and tbl.array.fits(val)) {
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
                            code = self.trace.codeFor(proto); // doc 20 image
                            code_gen = self.trace.image_gen;
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
                    code = self.trace.codeFor(proto); // doc 20 image
                    code_gen = self.trace.image_gen;
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
                        var visited: [trial_visited_cap]*trace.Trace = undefined;
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
                        var dead: [trial_visited_cap]*trace.Trace = undefined;
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
                            // Doc 24 D8 observation blackout: while a suspend
                            // cut or safepoint-line recording is armed, decline
                            // to enter any ALLOCATING trace (`alloc_bound > 0`)
                            // — a mid-burst observation would see a heap
                            // `next_obj_id` tier-0 only reaches after the whole
                            // burst, breaking §T-A.2 keyframe byte-identity.
                            // Identical condition to `safe_to_arm` below;
                            // tier-0 owns allocating loops for the window's
                            // duration. Ordered after the fingerprint so a
                            // blacked-out candidate still counts as matched
                            // (no spurious side-trace pressure).
                            any_fingerprint_matched = true;
                            if (ct.alloc_bound > 0 and
                                (self.suspend_ctl != null or self.record_safepoint_lines)) continue;
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
                            // Phase 0a (doc 20): the whole per-candidate entry + receipt
                            // grammar lives in `enterSelectedTrace`; this switch is the
                            // caller-owned epilogue the safe-point drain will hook (§R3-3).
                            var wctx: TrialWalkCtx = .{
                                .visited = visited[0..nvisited],
                                .dead = &dead,
                                .ndead = &ndead,
                            };
                            const directive = self.enterSelectedTrace(mode, ct, closure, proto, regs, base, pc, &wctx);
                            // Doc 20 safe-point drain: runs BEFORE acting on any
                            // directive (§R3-1) — every unpatch-producing event
                            // inside the entry routine is flushed here, same
                            // turn. Then re-resolve the fetch image if its
                            // generation moved (a Phase-1 install, or the first
                            // clone of this proto's image).
                            self.trace.drainEntryPatchWork();
                            if (self.trace.image_gen != code_gen) {
                                code = self.trace.codeFor(proto);
                                code_gen = self.trace.image_gen;
                            }
                            switch (directive) {
                                .next_candidate => {},
                                .resume_tier0 => |npc| {
                                    pc = npc;
                                    continue :outer;
                                },
                                .switch_mode_at => |npc| {
                                    frame.pc = npc;
                                    return .switch_mode;
                                },
                            }
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
                        // Doc 20 §R5-1 (codex post-landing blocker on
                        // 7fa7e1a): the three sites above — dead-trace
                        // retirement, fingerprint-miss, native-unsupported
                        // gating — all run AFTER this turn's epilogue drain
                        // and can mark bound patches pending. Drain again so
                        // the image and registry re-agree same-turn (the
                        // `.jfor_loop` arm's §R6-1 recovery would self-heal a
                        // missed one, but same-turn is the cheap, prompt
                        // path), and re-resolve the fetch image if a drain
                        // moved the generation.
                        self.trace.drainEntryPatchWork();
                        if (self.trace.image_gen != code_gen) {
                            code = self.trace.codeFor(proto);
                            code_gen = self.trace.image_gen;
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
    pub fn fusedGet(self: *Vm, container: Value, key1: Value, key2: Value) Error!Value {
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
    pub fn fusedStore(self: *Vm, container: Value, key1: Value, key2: Value, val: Value) Error!void {
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

    pub fn indexGet(self: *Vm, container: Value, key: Value) Error!Value {
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
    pub fn indexSet(self: *Vm, container: Value, key: Value, val: Value) Error!void {
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
pub fn lenOf(v: Value) Error!Value {
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

/// Doc 20 §R1-3 / Phase 3: patched opcodes are dispatch-image details, never
/// recorder input. A recording that crosses a patched pc mirrors the immutable
/// canonical instruction, so trace IR is byte-identical to an unpatched run.
pub inline fn recordingMirrorInstr(proto: *const Proto, pc: usize, fetched: Instr) Instr {
    return if (fetched.op == .jfor_loop or fetched.op == .jloop) proto.code[pc] else fetched;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The test suite lives in sibling `*_test.zig` files (split by theme). Zig only
// analyses a file that is reachable by import, so this block is what makes them
// run under `zig build test`.

test {
    _ = @import("interp_bytecode_test.zig");
    _ = @import("interp_stdlib_test.zig");
    _ = @import("interp_semantics_test.zig");
    _ = @import("interp_determinism_test.zig");
    _ = @import("interp_effects_test.zig");
    _ = @import("interp_modules_test.zig");
    _ = @import("interp_replay_test.zig");
    _ = @import("interp_gc_test.zig");
    _ = @import("interp_trace_test.zig");
    _ = @import("interp_tier1a_test.zig");
    _ = @import("interp_native_test.zig");
    _ = @import("interp_lanes_test.zig");
}
