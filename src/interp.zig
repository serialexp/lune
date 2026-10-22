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
const builtin = @import("builtin");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const fmath = @import("fmath.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const trace_exec = @import("trace_exec.zig");
const table_runtime = @import("table_runtime.zig");
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
    /// A mahina program raised a VALUE via `error(obj)`/`assert` (or a runtime fault
    /// re-raised through a protected boundary). The value itself rides
    /// `Vm.pending_error`; this Zig tag is only the unwinding signal. Caught by
    /// `pcall`/`xpcall`, which read+clear `pending_error`.
    LuaError,
    /// An `__index`/`__newindex` table chain exceeded `max_metatable_chain` hops
    /// — almost certainly a metatable cycle (`setmetatable(t, {__index=t})` and
    /// kin). Surfaced as a located runtime fault rather than hanging the VM.
    MetatableChainLoop,
    /// A numeric `for` whose step is zero (`0` or `±0.0`). Raised by
    /// `for_prep` before the loop runs, as Lua 5.4's `forprep` does; without
    /// it the loop never ends.
    ForStepZero,
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
pub const max_call_depth: u32 = 200;

/// Maximum nesting of native→VM reentry (`callValue`). Each level is a native
/// (e.g. `pcall`/`table.sort`/`gsub`) that calls back into the dispatch loop on
/// the **Zig host stack** — distinct from `max_call_depth`, which bounds the Lua
/// frame stack. A `pcall(pcall(pcall(…)))` chain or a comparator that recurses
/// through `table.sort` grows this; the cap turns host-stack exhaustion into a
/// clean `StackOverflow` instead of a crash.
pub const max_native_reentry: u16 = 200;

/// Most results one host fn call may return (its `max_results`), also when the
/// caller wants all of them (`return host()`). Bounding it lets each active
/// host call hold a private range of `Vm.host_out`. Host calls nest at most
/// `max_native_reentry + 1` deep (each nested one runs under a `callValue`), so
/// `host_out_slots` is enough for the deepest possible nesting.
pub const max_host_results: usize = 256;
const host_out_slots: usize = (@as(usize, max_native_reentry) + 1) * max_host_results;

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
pub const mahina_version = "mahina 0.0.0";

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
    // `os.clock` (float seconds) + `os.nsclock` (int nanoseconds, a mahina extension)
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
    .{ .name = "io.flush", .func = &nativeIoFlush, .module = "io", .field = "flush" },
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
/// Packed into one word so `opRet` publishes it with a single 4-byte store:
/// as two `u16` fields it was written half by half and then read back whole
/// by the boundary (`callValue`'s `st.step` switch), a load that cannot be
/// store-forwarded — the single biggest stall of an embedder call.
pub const FrameResult = packed struct(u32) { reg: u16, count: u16 };

/// Doc 21 Phase A: the top-level result span published at a genuine finish.
/// `stack_top` is the (possibly B-6-raised) value the description is valid
/// for — capture rejects the cut if the live `stack_top` no longer matches.
pub const FinalCut = struct { result_base: u32, result_count: u32, stack_top: u32 };

/// An open upvalue: a cell still pointing at the live stack slot `index`. Tracked
/// so that two closures capturing the same variable share one cell, and so the
/// cell can be *closed* (detached) when its slot is about to be freed. Public so
/// the keyframe restorer (`keyframeser.zig`) can rebuild the open-upvalue list.
pub const OpenUpvalue = struct { index: usize, cell: *function.Upvalue };

// Doc 61 §6: word-level helpers over the collector's keep-set (`Vm.gc_keep`).
comptime {
    std.debug.assert(stack_slots % 64 == 0);
}

/// The low `n` bits of a word (all of it for `n >= 64`).
fn lowBits(n: usize) u64 {
    return if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
}

/// Bits `[lo, hi)` within word `wi`.
fn rangeWord(wi: usize, lo: usize, hi: usize) u64 {
    const w_lo = wi * 64;
    return lowBits(hi -| w_lo) & ~lowBits(lo -| w_lo);
}

fn setBitRange(bits: []u64, lo: usize, hi: usize) void {
    if (lo >= hi) return;
    for (lo / 64..(hi - 1) / 64 + 1) |wi| bits[wi] |= rangeWord(wi, lo, hi);
}

fn clearBitRange(bits: []u64, lo: usize, hi: usize) void {
    if (lo >= hi) return;
    for (lo / 64..(hi - 1) / 64 + 1) |wi| bits[wi] &= ~rangeWord(wi, lo, hi);
}

/// OR the first `n` bits of `row` into `bits`, starting at bit `at`.
fn orBitsAt(bits: []u64, at: usize, row: []const u64, n: usize) void {
    var wi: usize = 0;
    while (wi * 64 < n) : (wi += 1) {
        const w = row[wi] & lowBits(n - wi * 64);
        if (w == 0) continue;
        const bit = at + wi * 64;
        const sh: u6 = @intCast(bit % 64);
        bits[bit / 64] |= w << sh;
        if (sh != 0) {
            const spill = w >> @intCast(@as(u7, 64) - sh);
            if (spill != 0) bits[bit / 64 + 1] |= spill;
        }
    }
}

/// One active call frame in the **explicit** VM call stack. Tier-0 no longer
/// recurses on the host stack; instead `exec` runs an iterative loop over a
/// `frames[0..depth]` array, each entry carrying everything needed to (a) run the
/// frame, (b) return its results into its parent, and (c) be **captured and
/// resumed mid-execution** (the keyframe records `pc`/`base`/return-wiring per
/// frame). Windows stack contiguously upward: `frames[i+1].base == frames[i].base
/// + frames[i].closure.proto.num_registers`.
/// Doc 68 §4.3: what a frame's return means for its parent. `.none` is the
/// ordinary result wiring through `ret_dest`/`ret_count`; the others arrive
/// with the continuation frames of doc 68 P1/P2.
pub const Cont = enum(u2) {
    none,
    /// Finish the parent's in-flight instruction with this frame's results
    /// (a metamethod's continuation, `luaV_finishOp`-style).
    finish_op,
    /// Step the parent native activation with this frame's results.
    native_resume,
};

/// Doc 68 §4.1/§4.3: the activation's kind and its continuation, one byte so
/// `CallFrame` keeps its stride. Every push writes the zero default: the Zig
/// funnel through the struct literal, the inline native push and the `.S`
/// host-call frame write with a byte store, so a reused slot never keeps an
/// old continuation.
pub const FrameCtl = packed struct(u8) {
    /// A native activation (doc 68 §5) rather than a Lua frame. None exist yet.
    native: bool = false,
    cont: Cont = .none,
    /// Which half of a fused `get_index2`/`set_index2` a `.finish_op`
    /// continuation is finishing (doc 68 §6).
    phase: u1 = 0,
    _pad: u4 = 0,
};

comptime {
    // Doc 68: the inline native push and the `.S` host-call frame write clear
    // `in_flight` and `ctl` with one 16-bit store at `in_flight`.
    std.debug.assert(@offsetOf(CallFrame, "ctl") == @offsetOf(CallFrame, "in_flight") + 1);
    std.debug.assert(@sizeOf(bool) == 1 and @sizeOf(FrameCtl) == 1);
}

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
    /// Doc 44 D9 (S4): the frame's cached doc-20 fetch image — one `codeFor`
    /// hash per (frame, image generation) instead of one per push/pop boundary
    /// crossing (`opRet`'s per-pop hash was 1.4% of recursive-fib inside
    /// `getIndex` alone). Gen `CODE_CACHE_GEN_INVALID` = invalid; gen 0 is a
    /// REAL generation and an empty image is a cacheable value, so neither
    /// doubles as the validity bit. Push-time defaults are the invalidation (a
    /// full struct-literal reassignment covers frame-slot reuse and keyframe
    /// restore, which recreates frames through `pushFrameVararg`). Transient —
    /// keyframes omit it, exactly like `call_seq`.
    ///
    /// Doc 54 P0: the validity encoding is a plain-u64 sentinel, not `?u64` —
    /// the inline native push (which replicates this struct literal's
    /// invalidation as one qword store of `-1`) cannot encode an optional's
    /// unspecified layout. `cachedCodeFor` refuses to hit OR fill when the
    /// registry gen itself equals the sentinel (a 2⁶⁴-bump wrap), so a stale
    /// sentinel-gen frame can never false-hit — fail closed, no panic needed.
    code_cache: []const Instr = &.{},
    code_cache_gen: u64 = CODE_CACHE_GEN_INVALID,
    /// Doc 61 §4.2: this frame is inside instruction `pc`, which is running
    /// other code: a native it called, or a re-entry (`callValue`) for a
    /// metamethod or a native's callback. Without it a non-innermost frame
    /// is suspended at a Lua `.call`, with `pc` one past it. Set on entry,
    /// restored to the previous value on success, and left set on error,
    /// where the frame is retained until a catcher discards it (it restores
    /// the one surviving frame, `frames[entry_depth - 1]`). Every push
    /// initialises it false: this default, the native inline push and the
    /// `.S` host-call frame write. Transient: keyframes refuse capture while
    /// any frame has it set, so it is never serialized.
    in_flight: bool = false,
    /// Doc 61 §5 (B): the dynamic end of a multret consumer's argument span,
    /// window-relative and clamped to `num_registers`. Written by the `.call`
    /// opcode with `b = all_results` before anything in it can fail, and read
    /// only while the frame is in flight at that `.call`, so no push needs to
    /// initialise it. The registers in `[multret_top, num_registers)` were
    /// not written by the producer and are masked out. Transient, like
    /// `in_flight`.
    multret_top: u16 = 0,
    /// Doc 68: kind and continuation. Always the default until doc 68 P1.
    ctl: FrameCtl = .{},
};

/// Doc 54 P0: `CallFrame.code_cache_gen`'s "no cached image" sentinel. All-ones
/// so the emitted inline push invalidates with a single sign-extended
/// `mov qword [frame+gen], -1`.
pub const CODE_CACHE_GEN_INVALID: u64 = std.math.maxInt(u64);

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
    /// The frame's `Proto.id`: names the chunk (and so the file) `line` is in,
    /// via `Vm.loadedChunkIndexOf`.
    proto_id: u32 = 0,
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
    /// The `Proto.id` the location (`line`/`start`/`end`) is in, which names
    /// its chunk and so its file (`Vm.loadedChunkIndexOf`).
    proto_id: u32 = 0,
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
    /// With `record_safepoint_lines` on, the most entries `safepoint_lines`
    /// takes while this is armed; later safepoints still count in
    /// `safepoint_seq` but are not recorded. A replay driver whose stop is a
    /// step cap sets it to the cap: a cap that falls inside nested code is
    /// deferred until the code returns (doc 68 §8), and without the limit the
    /// index would grow as long as the nested call runs. It lives here, in
    /// `min_depth`'s padding, because a new `Vm` field reshuffles the
    /// asm-visible `Vm` offsets.
    index_limit: u32 = std.math.maxInt(u32),
    after_safepoints: u64 = 0,
    /// Optional tier-independent logical cut: suspend at the first otherwise
    /// eligible tier-0 boundary at or after this many effects have committed.
    after_committed_effects: ?u64 = null,
};

comptime {
    // `index_limit` must stay in padding (see its doc).
    std.debug.assert(@sizeOf(SuspendCtl) == 32);
}

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
    /// `"__sar"` — `a ~>> b` (arithmetic right shift; mahina extension).
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
    /// Doc 61 §6.1: the collector's register keep-set, one bit per stack slot
    /// (`stack_slots` bits, 8 KiB), rebuilt by every root walk
    /// (`fillKeep`) over `[0, stack_top)`. A set bit is rooted; a clear
    /// bit is a dead window slot that `collect` scrubs to nil before the
    /// sweep. Allocated once at init, so a collection allocates nothing.
    gc_keep: []u64,
    /// Every host fn writes its results here (`callHostNative`), never into
    /// its caller's `out`. The caller's `out` can alias the host's `args`
    /// (`pcall`, `__call`), and it can reach past `stack_top`, where a nested
    /// `mh_call` from the host would overwrite results the host already
    /// wrote. A stack: each active host call holds `[lo, lo + want)` and
    /// nested ones go above it. Allocated on the first host call, so a VM
    /// with no host fns doesn't pay for it. Not a GC root, as `out` never was:
    /// the host keeps what it returns alive until it returns.
    host_out: []Value = &.{},
    host_out_top: usize = 0,
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
    /// Doc 54 P1: mutated ONLY through the centralized methods that own
    /// `open_upvalue_ceiling` (`appendOpenUpvalue`, `closeUpvaluesFrom`,
    /// `clearOpenUpvalues`) — direct list writes would let the ceiling go
    /// stale-LOW, the one unsound direction.
    open_upvalues: std.ArrayList(OpenUpvalue) = .empty,
    /// Doc 54 P1: upper bound on `index + 1` over `open_upvalues` — the
    /// inline native pop's one-load check (`ceiling <= popped frame.base` ⇒
    /// no open cell at or above the popped window, replacing the helper's
    /// full-list scan). Raised via `@max` on open, recomputed exactly in
    /// `closeUpvaluesFrom` (which already walks the list), reset on clear;
    /// the keyframe restorer republishes it through `appendOpenUpvalue`.
    /// Stale-HIGH only declines a pop spuriously — fail closed.
    open_upvalue_ceiling: usize = 0,
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
    /// Write through `setSuspendCtl` only (it owns a `trace.fast_block` bit).
    suspend_ctl: ?SuspendCtl = null,
    /// Doc 21 Phase A (the H-5(i) fix): absolute description of the only live
    /// stack content after a genuine top-level finish — the returned result
    /// span. Published by public `exec` alone (the single top-level authority;
    /// a reentrant depth-0 `callValue` boundary pop must never stamp it),
    /// VALIDATED — not trusted — by snapshot capture (`depth == 0`, matching
    /// `stack_top`, in-bounds span), and invalidated by anything that reuses
    /// the stack (`pushFrameVararg`, `beginTopLevelEpoch`, `callValue` entry,
    /// the `protectedCall` manual unwind). Through `fillKeep`, the collector
    /// roots only the span and capture tombstones every slot outside it, so
    /// the final snapshot is a pure function of the program's logical result
    /// regardless of which tier produced the state.
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
    /// When true, append the source line of each safepoint's pending
    /// instruction to `safepoint_lines` (the replay driver's line-grain index).
    /// Off by default so tier-0 pays nothing — the normal run path is untouched.
    /// Write through `setRecordSafepointLines` only (it owns a `trace.fast_block` bit).
    record_safepoint_lines: bool = false,
    /// Line-per-safepoint index built when `record_safepoint_lines` is on:
    /// `safepoint_lines[k-1]` is where the instruction pending at safepoint k
    /// is (1-based, matching `safepoint_seq`). Owned by the VM; lets the
    /// replay UI offer line-grain stepping with no extra wasm round-trips.
    safepoint_lines: std.ArrayList(SafepointLine) = .empty,
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
    /// it was compiled from (the keyframe recompiles it on restore, L-2). Freed
    /// in `deinit` in append order.
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
    /// constants, so a keyframe (which carries every unswept object, doc 61
    /// Phase K) keeps their ids across a snapshot straddle — retained chunks
    /// are host-authored program image, re-supplied on restore like the main
    /// `root`.
    ///
    /// **Borrows only** (non-owning): the host still owns each `Chunk` and frees it.
    /// Contract: `releaseChunk(proto)` BEFORE the host `Chunk.deinit()`s the tree,
    /// and one `retainChunk` per `releaseChunk`. The snapshot guarantee is scoped to
    /// UNRUN chunks (once run, a closure roots the constants → `releaseChunk`).
    retained_chunks: std.ArrayList(*const Proto) = .empty,

    /// Embedding (doc 59 §3.2): the host-ref registry backing the C API's
    /// `mh_ref` — values the host holds across the boundary, GC-rooted for as
    /// long as the ref lives. Slots are generational (a freed-and-reused index
    /// bumps `generation`, so a stale ref is a deterministic API error, never a
    /// dangling read); freed slots hold nil so the root walk cannot mark stale
    /// pointers. Rooted by the collector (`forEachRootHeader`). Host refs are
    /// host state, not guest-deterministic state, and keyframes do not carry
    /// them.
    host_refs: std.ArrayList(HostRefSlot) = .empty,
    /// Free slot indices for `host_refs` (LIFO reuse).
    host_ref_free_list: std.ArrayList(u32) = .empty,
    /// Embedding (doc 59 §3.3): the parked-results root. `callValue` unroots its
    /// results the moment it returns (it restores `stack_top`), so the C API
    /// copies every heap value it hands across the boundary in here; the park is
    /// cleared at the next idle-VM C entry that can allocate or run guest code.
    /// `.gc` walk only, like `host_refs`.
    ///
    /// Split for locality: the first `parked_inline.len` values live inline in
    /// the Vm struct (lines the entry path keeps warm), the ArrayList is
    /// overflow only. The typical entry parks 1–3 values (callee + args, or a
    /// result); storing those into a separately heap-allocated backing buffer
    /// made the park store the single hottest instruction of `mh_call` (a cold
    /// line touched once per call, ~1/3 of the whole crossing). The logical
    /// park is the concatenation inline[0..parked_inline_len] ++ items.
    parked_results: std.ArrayList(Value) = .empty,
    parked_inline: [6]Value = @splat(Value.nil()),
    parked_inline_len: u32 = 0,
    /// Test builds only (doc 60 §6.1): when set, `runFastPath` decides from
    /// the ten fields directly (`fastBlockReference`) instead of the packed
    /// `trace.fast_block`, so a differential test's reference leg cannot share
    /// a mask bug with the leg under test. Read only under `builtin.is_test`,
    /// but a plain `bool` in every build: the hand-written host-call entry's
    /// offsets file (doc 60 §3.2) must hold for test and library builds
    /// alike, so no `Vm` field's type may depend on the build.
    reference_dispatch: bool = false,

    /// One `safepoint_lines` entry: the 1-based source line of a safepoint's
    /// pending instruction (0 = no span) and the `Proto.id` it is in, which
    /// names its chunk and so its file (`loadedChunkIndexOf`).
    pub const SafepointLine = struct {
        proto_id: u32,
        line: u32,
        /// Whether a suspend due at this safepoint stops here
        /// (`canSuspendHere`). False inside a native's Zig re-entry, where a
        /// suspend is deferred to the first boundary after it returns
        /// (doc 68 §8), and while a multret result is pending. The replay UI
        /// offers only stoppable steps.
        stoppable: bool,
    };

    /// A runtime-compiled chunk owned by the VM: the `Chunk` (whose arena owns the
    /// proto tree) and the NUL-terminated source the protos borrow.
    pub const LoadedChunk = struct {
        chunk: compiler.Chunk,
        source: [:0]u8,
    };

    /// One `host_refs` slot: the rooted value and the slot's generation counter.
    pub const HostRefSlot = struct {
        value: Value = Value.nil(),
        generation: u32 = 0,
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
    /// the loaded-chunk pin). Compiler-produced protos only (the `retainChunk` contract):
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

    fn pinHeader(_: void, h: *object.GcHeader) void {
        h.flags.pinned = true;
    }

    /// Take VM-lifetime ownership of a dynamically compiled chunk (`load`, the
    /// C API's compile/eval, keyframe restore — the single funnel for all
    /// `loaded_chunks` appends). Appends, then **pins** every heap constant in
    /// the proto tree: `loaded_chunks` never shrinks, so its constants are
    /// immortal, and pinning lets the `.gc` root walk skip them entirely.
    /// Re-rooting every loaded chunk's constant tree each GC cycle made every
    /// cycle O(all chunks ever loaded) — quadratic for a guest (or embedder)
    /// that compiles in a loop. Pinned objects survive sweep unmarked
    /// (`gc.Heap.sweep`) and are freed at heap teardown like everything else;
    /// liveness is unchanged (these constants were unconditionally rooted
    /// before), so determinism and heap ids are untouched. Keyframes carry
    /// them like every other unswept object (doc 61 Phase K) and know nothing
    /// of pinning. On append failure the caller still owns
    /// chunk + source (the append-first OOM contracts at the call sites hold).
    /// The index into `loaded_chunks` of the chunk that compiled proto `id`, or
    /// null for the host's static chunk (ids below the first loaded chunk's).
    /// Each chunk owns the id range `[root.id, root.id + proto_count)`. Cold:
    /// error reporting and tooling only.
    pub fn loadedChunkIndexOf(self: *const Vm, id: u32) ?usize {
        for (self.loaded_chunks.items, 0..) |lc, i| {
            const first = lc.chunk.proto.id;
            if (id >= first and id - first < lc.chunk.proto_count) return i;
        }
        return null;
    }

    pub fn appendLoadedChunk(self: *Vm, lc: LoadedChunk) !void {
        try self.loaded_chunks.append(self.gpa, lc);
        rootProtoConsts(lc.chunk.proto, {}, pinHeader);
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
        // Doc 43 §3.2 (P0b): hand the recorder the globals table's header so it can
        // recognise a store into `_G` and keep it from staling a global snapshot.
        vm.trace.rec_globals_header = &vm.globals.header;
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
    /// Doc 54 P0: the `Vm`/`CallFrame` offset descriptor for inline native
    /// frame motion (see `trace_code.FrameMotionAbi`). Computed here — the
    /// one module that can name every involved type — entirely at comptime,
    /// so a layout change recomputes it on the next build. The width asserts
    /// pin every field size the emitted store/compare forms assume (a dword
    /// depth store against a widened `depth` would silently corrupt the
    /// neighbouring field — Z-1: fail the build instead).
    const frame_motion_abi: trace.FrameMotionAbi = blk: {
        const TraceState = trace.TraceState;
        const RegionPolicy = @FieldType(TraceState, "region_policy");
        const RegionContext = trace.RegionContext;
        // Pinned widths (one per emitted access form). Only the x86-64 emitter
        // consumes this descriptor; on any other target (wasm32, where pointers
        // and usizes are 4 bytes) native codegen is `UnsupportedTarget`, so the
        // widths are pinned only where they are load-bearing.
        if (nativegen.is_x64_linux) {
            std.debug.assert(@sizeOf(@FieldType(Vm, "depth")) == 4); // dword load/store + dword wall cmp
            std.debug.assert(@sizeOf(@FieldType(Vm, "stack_top")) == 8);
            std.debug.assert(@sizeOf(@FieldType(Vm, "next_call_seq")) == 8); // qword cmp -1 wall
            std.debug.assert(@sizeOf(@FieldType(RegionContext, "depth")) == 4);
            std.debug.assert(@sizeOf(@FieldType(RegionContext, "call_seq")) == 8);
            std.debug.assert(@sizeOf(@FieldType(RegionPolicy, "region_context_valid")) == 1);
            std.debug.assert(@sizeOf(@FieldType(TraceState, "tick")) == 8);
            std.debug.assert(@sizeOf(@FieldType(TraceState, "self_call_pushes")) == 8);
            std.debug.assert(@sizeOf(@FieldType(TraceState, "self_ret_pops")) == 8);
            std.debug.assert(@sizeOf(@FieldType(Vm, "open_upvalue_ceiling")) == 8); // qword cmp vs popped base
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "closure")) == 8);
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "call_seq")) == 8);
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "base")) == 8);
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "pc")) == 8); // qword imm32 store (pc always < 2³¹)
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "ret_dest")) == 2); // word store
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "ret_count")) == 2);
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "varargs_base")) == 8);
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "varargs_count")) == 8);
            std.debug.assert(@sizeOf(@FieldType(CallFrame, "code_cache_gen")) == 8); // qword -1 = CODE_CACHE_GEN_INVALID
        }
        const trace_off = @offsetOf(Vm, "trace");
        const policy_off = trace_off + @offsetOf(TraceState, "region_policy");
        const rctx_off = policy_off + @offsetOf(RegionPolicy, "region_context");
        break :blk .{
            .vm_depth_off = @offsetOf(Vm, "depth"),
            .vm_stack_top_off = @offsetOf(Vm, "stack_top"),
            .vm_frames_off = @offsetOf(Vm, "frames"),
            .vm_next_call_seq_off = @offsetOf(Vm, "next_call_seq"),
            .vm_region_depth_off = rctx_off + @offsetOf(RegionContext, "depth"),
            .vm_region_call_seq_off = rctx_off + @offsetOf(RegionContext, "call_seq"),
            .vm_region_valid_off = policy_off + @offsetOf(RegionPolicy, "region_context_valid"),
            .vm_tick_off = trace_off + @offsetOf(TraceState, "tick"),
            .vm_self_call_pushes_off = trace_off + @offsetOf(TraceState, "self_call_pushes"),
            .vm_self_ret_pops_off = trace_off + @offsetOf(TraceState, "self_ret_pops"),
            .vm_open_upvalue_ceiling_off = @offsetOf(Vm, "open_upvalue_ceiling"),
            .frame_size = @sizeOf(CallFrame),
            .frame_closure_off = @offsetOf(CallFrame, "closure"),
            .frame_call_seq_off = @offsetOf(CallFrame, "call_seq"),
            .frame_base_off = @offsetOf(CallFrame, "base"),
            .frame_pc_off = @offsetOf(CallFrame, "pc"),
            .frame_ret_dest_off = @offsetOf(CallFrame, "ret_dest"),
            .frame_ret_count_off = @offsetOf(CallFrame, "ret_count"),
            .frame_varargs_base_off = @offsetOf(CallFrame, "varargs_base"),
            .frame_varargs_count_off = @offsetOf(CallFrame, "varargs_count"),
            .frame_code_cache_gen_off = @offsetOf(CallFrame, "code_cache_gen"),
            .frame_in_flight_off = @offsetOf(CallFrame, "in_flight"),
            .max_call_depth = max_call_depth,
        };
    };

    pub fn initBare(gpa: std.mem.Allocator) std.mem.Allocator.Error!Vm {
        const tags = try gpa.alloc(u8, stack_slots);
        errdefer gpa.free(tags);
        const payloads = try gpa.alloc(u64, stack_slots);
        errdefer gpa.free(payloads);
        const boundary_scratch = try gpa.alloc(Value, stack_slots);
        errdefer gpa.free(boundary_scratch);
        const gc_keep = try gpa.alloc(u64, stack_slots / 64);
        errdefer gpa.free(gc_keep);
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
            .gc_keep = gc_keep,
            .trace = trace.TraceState.init(gpa),
        };
        // Registry allocates a stable context; no pointer into movable Vm storage.
        try vm.trace.registry.createSeedContext(.{
            .seed_fn = &nativeSeedFn,
            .seed_tier1a_fn = &nativeSeedTier1aFn,
            // Doc 54 P1: the structural-invariant assert callout exists only
            // in -Djit-debug builds; normal builds emit no callout at all.
            .frame_motion_assert_fn = if (@import("jitdbg.zig").enabled) &nativeFrameMotionAssert else null,
            .frame_abi = frame_motion_abi,
        });
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
        self.host_refs.deinit(self.gpa);
        self.host_ref_free_list.deinit(self.gpa);
        self.parked_results.deinit(self.gpa);
        self.heap.deinit();
        self.gpa.destroy(self.heap);
        self.gpa.free(self.tags);
        self.gpa.free(self.payloads);
        self.gpa.free(self.boundary_scratch);
        self.gpa.free(self.gc_keep);
        self.gpa.free(self.host_out);
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
    fn seedTraceInputs(self: *Vm, ct: *const trace.TraceCode, base: usize, closure: *const function.Closure, proto: *const Proto, narrow: RegWindow, native_eligible: *bool) ?RegWindow {
        if (ct.inputs.len == 0) return narrow;
        var count: usize = proto.num_registers;
        for (ct.inputs) |seed| count = @max(count, @as(usize, seed.slot) + 1);
        if (base + count > self.regCapacity()) return null;
        for (ct.inputs) |seed| {
            // Doc 43 P5: an `upvalue_cell` seed resolves `&cell.loc.closed` (a
            // `*Value`) — writer paths stash it raw (tagged `.int`, the
            // hash_cell discipline), verifier paths re-resolve and must AGREE
            // with the writer's slot, re-proving the record-time alias class.
            // ANY failure (open/missing cell, non-function callee, verifier
            // mismatch) declines the whole candidate to tier-0 (`return null`
            // → `.next_candidate`): `uref` has no operands to re-derive the
            // cell from, so — unlike `hash_cell` — no tier-1a downgrade
            // exists. Earlier seeds may already have written their (dead
            // scratch) slots; that is harmless, nothing runs this trace.
            if (seed.kind == .upvalue_cell) {
                const bits = self.resolveUpvalueCellBits(base, closure, seed) orelse return null;
                if (seed.verify) {
                    if (self.regGet(base + seed.slot).payload.bits != bits) return null;
                } else {
                    self.regSet(base + seed.slot, Value{ .tag = .int, .payload = .{ .bits = bits } });
                }
                continue;
            }
            // Doc 53: validation-only — re-prove the open-cell↔anchor-slot
            // relation for the canonicalized upvalue read; any failure declines
            // the whole candidate (same grammar as `upvalue_cell`, same reason:
            // nothing to re-derive from).
            if (seed.kind == .upvalue_slot_alias) {
                if (!self.upvalueSlotAliasOk(base, seed)) return null;
                continue;
            }
            const v = switch (seed.kind) {
                .upvalue_cell, .upvalue_slot_alias => unreachable, // handled above
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
                // Doc 36: resolve a callee's upvalue by reading the callee closure
                // from its slab slot (already seeded earlier in this loop — ordering
                // guaranteed by append order) and then resolving its upvalue.
                // Defensive: the callee slot might hold a non-function between entries
                // (guard_func fires AFTER seeding). Seed nil and let the guard deopt.
                .callee_upvalue => blk: {
                    const callee_val = self.regGet(base + seed.callee_slot);
                    if (!callee_val.isHeap() or callee_val.heapType() != .function) break :blk Value.nil();
                    const callee_cl = function.Closure.fromHeader(callee_val.asHeap());
                    if (seed.source >= callee_cl.upvalues.len) break :blk Value.nil();
                    break :blk self.upvalGet(callee_cl.upvalues[seed.source]);
                },
                // Doc 43 P4: a global read inside an inlined callee — the name
                // was copied into the TRACE's const pool at record time (the
                // hash_cell precedent), so resolution is proto-free.
                .callee_global => self.globals.get(ct.consts[seed.source]),
            };
            self.regSet(base + seed.slot, v);
        }
        return self.frameWindow(base, count);
    }

    /// Doc 43 P5: resolve one `upvalue_cell` access path to the raw address of
    /// the closed cell's owned `Value` (`&cell.loc.closed`), or null when the
    /// path no longer resolves (callee slot not a function, upvalue index out
    /// of range, or the cell is OPEN — v1 records closed cells only; a cell
    /// can never re-open, so a successful resolution is stable for the whole
    /// episode and needs no per-iteration guard). Shared by all three seeding
    /// twins so their validation is byte-identical.
    /// Doc 53: validate one `upvalue_slot_alias` seed — the recorder
    /// canonicalized an inlined callee's OPEN-upvalue read to the aliased
    /// anchor slot's SSA value, and this re-proves the relation for the
    /// closure the trace will actually call: the value in `callee_slot` is a
    /// function closure whose `upvalues[source]` is OPEN over exactly
    /// `base + seed.slot`. `guard_func` pins only proto id, so a same-proto
    /// closure from another live activation (aliasing a different frame's
    /// slot) must be refused here — this is mahina's per-entry flavor of
    /// LuaJIT `rec_upvalue`'s `REF_BASE` relation guard. Validation-only (no
    /// slab write); shared by all three seeding twins so the check is
    /// byte-identical. False → decline the WHOLE candidate to tier-0 (the
    /// `upvalue_cell` grammar — the canonicalized slot read has nothing to
    /// re-derive from, so no tier-1a downgrade exists). Single-slab
    /// assumption: coroutines are excluded by design, so `loc.open` indices
    /// are all coordinates of one slab; if multiple stacks ever appear this
    /// comparison must gain slab identity.
    fn upvalueSlotAliasOk(self: *const Vm, base: usize, seed: trace.InputSeed) bool {
        const cv = self.regGet(base + seed.callee_slot);
        if (!cv.isHeap() or cv.heapType() != .function) return false;
        const cl = function.Closure.fromHeader(cv.asHeap());
        if (seed.source >= cl.upvalues.len) return false;
        return switch (cl.upvalues[seed.source].loc) {
            .open => |idx| idx == base + seed.slot,
            .closed => false,
        };
    }

    fn resolveUpvalueCellBits(self: *const Vm, base: usize, closure: *const function.Closure, seed: trace.InputSeed) ?u64 {
        const cl: *const function.Closure = blk: {
            if (seed.callee_slot == trace.UPVALUE_CELL_ANCHOR) break :blk closure;
            const cv = self.regGet(base + seed.callee_slot);
            if (!cv.isHeap() or cv.heapType() != .function) return null;
            break :blk function.Closure.fromHeader(cv.asHeap());
        };
        if (seed.source >= cl.upvalues.len) return null;
        const cell = cl.upvalues[seed.source];
        return switch (cell.loc) {
            .open => null,
            .closed => |*v| @intFromPtr(v),
        };
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
    ///   `SEED_CAPACITY_DECLINE` if the seed slots don't fit (before ANY slab
    ///   write) or — doc 43 P5 — an `upvalue_cell` seed failed to resolve /
    ///   verify (mid-loop; earlier seeds' dead-scratch slots may already be
    ///   written, which is harmless since the decline means nothing runs this
    ///   candidate), `SEED_HASH_DECLINE` if a hash_cell seed failed validation
    ///   (the 0-bits slot is still written, exactly like the original, so
    ///   tier-1a sees the same slab state), else `SEED_OK`.
    /// - Allocation-free and GC-safe: resolution + validation only (upvalue
    ///   reads, global lookups, hash-chain walks). Deliberately NOT a
    ///   `nativegen.BodyCallout` row — that enum answers "can a heap φ die
    ///   across this MID-ITERATION call site", and this runs once at entry
    ///   before any φ is live. See the `BodyCallout` header.
    fn nativeSeedFn(
        ctx: *const trace.NativeSeedCtx,
        ct: *const trace.TraceCode,
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
            // Doc 43 P5: upvalue_cell resolution/verification failure declines
            // the whole candidate (the capacity grammar — the emitted prologue
            // routes it to the capacity exit → `.next_candidate`); tier-1a
            // must not run either (`uref` has nothing to re-derive from).
            if (seed.kind == .upvalue_cell) {
                const bits = self.resolveUpvalueCellBits(ctx.base, closure, seed) orelse
                    return trace.NativeSeedCtx.SEED_CAPACITY_DECLINE;
                if (seed.verify) {
                    if (self.regGet(ctx.base + seed.slot).payload.bits != bits)
                        return trace.NativeSeedCtx.SEED_CAPACITY_DECLINE;
                } else {
                    self.regSet(ctx.base + seed.slot, Value{ .tag = .int, .payload = .{ .bits = bits } });
                }
                continue;
            }
            // Doc 53: same validation + decline grammar as `seedTraceInputs`'s
            // arm — whole-candidate decline, nothing to re-derive from.
            if (seed.kind == .upvalue_slot_alias) {
                if (!self.upvalueSlotAliasOk(ctx.base, seed))
                    return trace.NativeSeedCtx.SEED_CAPACITY_DECLINE;
                continue;
            }
            const v = switch (seed.kind) {
                .upvalue_cell, .upvalue_slot_alias => unreachable, // handled above
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
                // Doc 36: same as seedTraceInputs's callee_upvalue arm.
                // Defensive: seed nil if the callee changed; guard_func deopts.
                .callee_upvalue => blk: {
                    const callee_val = self.regGet(ctx.base + seed.callee_slot);
                    if (!callee_val.isHeap() or callee_val.heapType() != .function) break :blk Value.nil();
                    const callee_cl = function.Closure.fromHeader(callee_val.asHeap());
                    if (seed.source >= callee_cl.upvalues.len) break :blk Value.nil();
                    break :blk self.upvalGet(callee_cl.upvalues[seed.source]);
                },
                // Doc 43 P4: same as seedTraceInputs's callee_global arm — the
                // name lives in the trace const pool, resolution is proto-free.
                .callee_global => self.globals.get(ct.consts[seed.source]),
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
    fn nativeSeedTier1aFn(ctx: *const trace.NativeSeedCtx, ct: *const trace.TraceCode) u64 {
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

    // (Doc 44 D11's `nativeSelfCallPush` C-ABI push helper lived here until
    // doc 54 P2 rebuilt its last caller — the continuation-page push
    // epilogue — on the inline emitted sequence (`emitInlineSelfPush`) and
    // deleted it. Every check it re-derived per push is now an emit-time
    // static, the per-episode `descent_ok` byte, or an inline wall; its
    // VM-state effect survives byte-for-byte in the emitted sequence, and
    // its structural premises keep jit-debug asserts in
    // `nativeFrameMotionAssert` below.)

    /// Doc 54 P1: the jit-debug-only structural-invariant assert for inline
    /// native frame motion, installed into
    /// `NativeSeedCtx.frame_motion_assert_fn` ONLY in `-Djit-debug` builds
    /// and called by the emitted pop sequence after its net-pushed floor.
    /// This is where every frame-identity check the old `nativeSelfRetPop`
    /// helper re-derived per pop keeps a debug assert that can bite (the
    /// doc's sabotage protocol): the checks were dropped from the hot path
    /// because their premises are episode-LOCAL — nothing but this episode's
    /// own emitted code mutates `frames[]`/`depth` mid-episode (tier-0
    /// dispatch, host reentry, and error unwind are all episode
    /// terminators), so with net > 0 the top frame is one THIS episode
    /// pushed (step 6 of the inline push), and its identity/adjacency hold
    /// by construction. The final two asserts pin the descent gate's
    /// region premise: receipts stay inert for the whole episode, so
    /// `dropRegionActivation` can close nothing and reduces to the emitted
    /// context-clear replica.
    fn nativeFrameMotionAssert(ctx: *const trace.NativeSeedCtx, nreg: u64) callconv(.c) void {
        const self: *Vm = @ptrCast(@alignCast(ctx.vm));
        std.debug.assert(self.depth >= 2);
        const frame = &self.frames[self.depth - 1];
        const parent = &self.frames[self.depth - 2];
        std.debug.assert(frame.base == ctx.base);
        std.debug.assert(frame.call_seq == ctx.call_seq);
        const proto: *const Proto = @ptrCast(@alignCast(ctx.proto.?));
        std.debug.assert(frame.closure.proto == proto);
        std.debug.assert(parent.closure.proto == proto);
        std.debug.assert(frame.base == parent.base + nreg);
        std.debug.assert(!self.reg_top_pending);
        std.debug.assert(self.final_cut == null);
        std.debug.assert(self.trace.region_policy.receiptsInert());
        std.debug.assert(self.trace.region_policy.activeRegionFor(frame.call_seq) == null);
    }

    /// Doc 22 §B.1: publish the current activation into the per-VM seeding ctx
    /// at native-episode start, so a seeded page's baked `&ctx` (B-ii) and
    /// `driveChain`'s tier-1a seeding (B-iii) describe THIS entry. `proto` +
    /// `call_seq` are the freshness stamp consumers check (`stubEnterable`,
    /// B-iv). No-op when the ctx is absent (hand-built test TraceStates).
    /// Pub for the doc 54 P0 gate-publication test only — production callers
    /// are all inside this file.
    pub fn prepareNativeEpisode(self: *Vm, closure: *const function.Closure, proto: *const Proto, base: usize) void {
        const ctx = self.trace.registry.native_seed_ctx orelse return;
        ctx.vm = self;
        ctx.closure = closure;
        ctx.base = base;
        ctx.reg_capacity = self.regCapacity();
        ctx.proto = proto;
        ctx.call_seq = self.frames[self.depth - 1].call_seq;
        // Doc 54 P2: new episode → all row-free hit-counter records go cold
        // (their `gen` no longer matches) and the touched drain list starts
        // empty. This funnel is the episode-entry init point: every
        // frame-motion-capable entry passes through here (the quiet and full
        // head paths both prepare before running), and unprepared episodes
        // (pure loop chains) have no frame-motion slots to publish with.
        // Since doc 54 P2 deleted the push helper, nothing calls this
        // mid-episode — the inline push refreshes closure/base/call_seq
        // directly in emitted code and deliberately leaves gen/touched alone.
        //
        // Rollover discipline (amendment, codex round-2 blocker): the gen
        // SATURATES at maxInt — skipping 0 would be insufficient because
        // every nonzero generation is eventually reused, and an ancient
        // record stamped `gen = k` would falsely match a reused
        // `episode_gen = k`, silently skipping the counter reset/touched
        // publication. Advance FIRST, then compute `descent_ok` from the
        // resulting generation (codex round-3 pin), so the saturated state
        // is self-consistent: at maxInt the descent gate is dead, no
        // frame-motion sequence commits, `frame_motion_taken` never sets,
        // and therefore no rowless follow or counter publication can occur
        // ever again — permanent fail-closed disable at zero emitted-code
        // cost. Gen 0 stays the permanent cold sentinel (records start
        // there; the first prepared episode is gen 1).
        if (ctx.episode_gen != std.math.maxInt(u64)) ctx.episode_gen += 1;
        ctx.touched_len = 0;
        // Doc 54 P0 (+P2 amendment conjunct): the episode descent gate —
        // all conjuncts are episode-invariant (see
        // `NativeSeedCtx.descent_ok`), so the byte published here holds for
        // every inline push in the episode.
        ctx.descent_ok = @intFromBool(self.trace.region_policy.receiptsInert() and
            !self.reg_top_pending and self.final_cut == null and
            ctx.episode_gen != std.math.maxInt(u64));
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
        try self.globals.set(self.gpa, try self.heap.internValue("_VERSION"), try self.heap.internValue(mahina_version));
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
        self.retireFinalCut(); // doc 21: the previous run's cut is stale now
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
    /// `pc -| 1`, unless the parent is in flight (doc 61 §4.2: it re-entered from
    /// inside its own instruction, which `pc` names) — the same leaf-vs-parent rule
    /// as `backtraceFrames`. Returns
    /// `null` for `level == 0`, `level > depth` (past the stack — Lua suppresses
    /// the location prefix in that case), or an empty stack.
    pub fn callSiteAt(self: *Vm, level: usize) ?CallSite {
        if (self.depth == 0 or level == 0 or level > self.depth) return null;
        const idx = self.depth - level;
        const f = &self.frames[idx];
        const proto = f.closure.proto;
        const is_top = idx == self.depth - 1;
        // Doc 61 §4.2: a parent in flight is inside its own instruction (a
        // metamethod's `.add`, a native's `.call`), not one past a call.
        const pc: usize = if (is_top or f.in_flight) f.pc else f.pc -| 1;
        // The compiler stamped the span with its line in the proto's own chunk,
        // so a runtime-`load`ed chunk reports its own lines.
        const span: bytecode.Span = if (pc < proto.spans.len) proto.spans[pc] else .{};
        return .{
            .proto = proto,
            .base = f.base,
            .pc = pc,
            .span = span,
            .line = span.line,
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
        const call = bytecode.callOperandsOf(cs.proto.code[cs.pc]) orelse return null;
        const callee = self.regGet(cs.base + call.a);
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
    pub fn describeFault(self: *Vm, err: Error, arena: std.mem.Allocator) std.mem.Allocator.Error!Fault {
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
                .proto_id = if (cs) |c| c.proto.id else 0,
                .line = if (cs) |c| c.line else 0,
                .start = if (cs) |c| c.span.start else 0,
                .end = if (cs) |c| c.span.end else 0,
                .frames = try self.backtraceFrames(arena),
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
        const line = span.line;

        const message: []const u8 = switch (err) {
            Error.StackOverflow => try arena.dupe(u8, "stack overflow"),
            Error.DivisionByZero => try arena.dupe(u8, "attempt to perform integer division or modulo by zero"),
            Error.MetatableChainLoop => try arena.dupe(u8, "'__index' chain too long; possible loop"),
            Error.ForStepZero => try arena.dupe(u8, "'for' step is zero"),
            // Doc 66 P3: the register and constant forms alike, over the
            // operands in source order.
            else => if (bytecode.arithFormOf(instr.op)) |f| blk: {
                const o = arithOperandValues(proto, regs, instr, f.shape);
                break :blk switch (f.base) {
                    // Bitwise ops want an integer operand: a float (no integer
                    // form) and a non-number get distinct Lua-5.4-shaped messages.
                    .band, .bor, .bxor, .shl, .shr, .sar => try bitwiseFaultMessage(arena, firstNonInteger(o[0], o[1])),
                    else => try std.fmt.allocPrint(
                        arena,
                        "attempt to perform arithmetic on a {s} value",
                        .{firstNonNumber(o[0], o[1]).typeName()},
                    ),
                };
            } else switch (instr.op) {
                .neg => try std.fmt.allocPrint(arena, "attempt to perform arithmetic on a {s} value", .{regs.get(instr.b).typeName()}),
                .bnot => try bitwiseFaultMessage(arena, regs.get(instr.b)),
                .len => try std.fmt.allocPrint(arena, "attempt to get length of a {s} value", .{regs.get(instr.b).typeName()}),
                .concat => try std.fmt.allocPrint(arena, "attempt to concatenate a {s} value", .{firstNonConcatable(regs.get(instr.b), regs.get(instr.c)).typeName()}),
                .lt, .le, .gt, .ge, .jlt, .jle, .jgt, .jge => try std.fmt.allocPrint(arena, "attempt to compare {s} with {s}", .{ regs.get(instr.b).typeName(), regs.get(instr.c).typeName() }),
                // Doc 66 P4: in source order, which put the constant on the
                // left when `cmp_k_left` is set.
                .jlt_k, .jle_k, .jgt_k, .jge_k => blk: {
                    const x = regs.get(instr.b).typeName();
                    const k = proto.constants[instr.c].typeName();
                    const k_left = instr.a & bytecode.cmp_k_left != 0;
                    break :blk try std.fmt.allocPrint(arena, "attempt to compare {s} with {s}", .{ if (k_left) k else x, if (k_left) x else k });
                },
                // Lua 5.4's `forprep` wording, first non-number in operand order.
                .for_prep => try arena.dupe(u8, if (!regs.get(instr.a).isNumber())
                    "'for' initial value must be a number"
                else if (!regs.get(instr.a + 1).isNumber())
                    "'for' limit must be a number"
                else
                    "'for' step must be a number"),
                // The container is a register in all four forms; the field
                // forms' key is a constant, which the message never reads.
                .get_index, .get_field => try std.fmt.allocPrint(arena, "attempt to index a {s} value", .{regs.get(instr.b).typeName()}),
                .set_index, .set_field => try std.fmt.allocPrint(arena, "attempt to index a {s} value", .{regs.get(instr.a).typeName()}),
                // Doc 66 P1: an `itern` faults only in the call it makes.
                .call, .itern => blk: {
                    // A native runs inline (no child frame), so when one returns a
                    // bare fault the leaf instruction is the `.call` to it — the
                    // callee is perfectly callable. Name it generically instead of
                    // the misleading "attempt to call". Detailed per-argument
                    // messages come from `Vm.badArg` (which raises `LuaError`, so it
                    // never reaches this non-LuaError arm). A genuine non-callable
                    // (nil/number/…) keeps the real "attempt to call a X value".
                    const callee = regs.get(bytecode.callOperandsOf(instr).?.a);
                    if (callee.isHeap() and callee.heapType() == .native and err == Error.TypeError)
                        break :blk try std.fmt.allocPrint(arena, "bad argument to '{s}'", .{nativeDisplayName(function.Native.fromHeader(callee.asHeap()))});
                    if (callee.isHeap() and (callee.heapType() == .native or callee.heapType() == .function))
                        break :blk try arena.dupe(u8, @errorName(err));
                    break :blk try std.fmt.allocPrint(arena, "attempt to call a {s} value", .{callee.typeName()});
                },
                else => try arena.dupe(u8, @errorName(err)),
            },
        };

        const frames = try self.backtraceFrames(arena);
        return .{ .message = message, .proto_id = proto.id, .line = line, .start = span.start, .end = span.end, .frames = frames };
    }

    /// Walk the live call stack into `FaultFrame` rows, **deepest-first** (leaf at
    /// index 0). `exec` does not unwind `self.frames` on error or suspend, so every
    /// live frame is intact when this is called. The leaf's pc is its pending /
    /// faulting instruction; a parent's pc is the *resume cursor* — one past its
    /// outgoing `call` (set at the call site before pushing the child) — so its
    /// call-site instruction is `pc -| 1` — unless it is in flight (doc 61 §4.2:
    /// a metamethod or a native's callback re-entered from inside its own
    /// instruction, which `pc` names). Shared by `describeFault` (runtime
    /// errors) and the replay driver (per-step backtrace), so the leaf-vs-call-site
    /// logic can never drift. `arena` owns the returned slice.
    pub fn backtraceFrames(self: *Vm, arena: std.mem.Allocator) std.mem.Allocator.Error![]FaultFrame {
        const frames = try arena.alloc(FaultFrame, self.depth);
        var i: usize = self.depth;
        while (i > 0) {
            i -= 1;
            const f = &self.frames[i];
            const fp = f.closure.proto;
            const fpc: usize = if (i == self.depth - 1 or f.in_flight) f.pc else f.pc -| 1;
            const fspan: bytecode.Span = if (fpc < fp.spans.len) fp.spans[fpc] else .{};
            frames[self.depth - 1 - i] = .{
                .name = fp.name,
                .proto_id = fp.id,
                .line = fspan.line,
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
        self.pushFrameTrusted(closure, nreg, base, ret_dest, ret_count, varargs_base, varargs_count);
        self.trace.setRegionContext(self.depth, self.frames[self.depth - 1].call_seq);
    }

    /// The trusted core of `pushFrameVararg` for `callValue`'s two closure
    /// arms: the caller has ALREADY proven `depth < max_call_depth` and
    /// `base + nreg <= regCapacity()` (it had to, to lay out the callee
    /// window first), and the very next thing it does re-derives the region
    /// context (the host-entry `ExecState` build / `reloadTopFrame`), so
    /// neither check nor the context store is repeated here. Cold callers
    /// (`run`, keyframe restore) go through the checked `pushFrameVararg`
    /// above, which also publishes the region context. The `.call` opcode
    /// arm deliberately does NOT use this: inlining the push there grew the
    /// hottest handler and cost scalar ~4% wall from pure code placement
    /// (fewer instructions, more cycles — measured 2026-10-01), so it keeps
    /// the outlined checked call.
    pub inline fn pushFrameTrusted(self: *Vm, closure: *const Closure, nreg: usize, base: usize, ret_dest: u16, ret_count: u16, varargs_base: usize, varargs_count: usize) void {
        std.debug.assert(self.final_cut == null);
        std.debug.assert(self.depth < max_call_depth);
        std.debug.assert(base + nreg <= self.regCapacity());
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

    /// Lay out a host-entered closure's window at `stack_top`, bind `args`
    /// exactly like the `.call` arm, and push its frame; returns the callee
    /// base. Shared by `callValue`'s closure arm and the doc 60 H1 host-call
    /// entry (`pushHostCall`). Fails, with nothing mutated, on the depth limit
    /// or register capacity (`StackOverflow`).
    /// Straight-line and allocation-free through the push (which raises
    /// `stack_top`): no safepoint may intervene, so the args written above
    /// `stack_top` are never seen unrooted by the collector.
    inline fn bindAndPushClosure(self: *Vm, cl: *const Closure, args: []const Value) Error!usize {
        const cp = cl.proto;
        if (self.depth >= max_call_depth) return Error.StackOverflow;
        if (!cp.is_vararg or args.len <= cp.num_params) {
            // No surplus varargs ⇒ the separate arg region below the
            // window is redundant: bind params straight into the callee
            // window (one copy, not two — this is the common boundary
            // crossing, and the double copy was ~30 instructions/call
            // in the embedding callgrind profile). Surplus args to a
            // non-vararg callee are simply dropped, exactly what the
            // two-region layout did by never reading them.
            const cb = self.stack_top;
            const nreg: usize = cp.num_registers;
            if (cb + nreg > self.regCapacity()) return Error.StackOverflow;
            const np = @min(cp.num_params, args.len);
            // The window, lane bases and register count are taken once:
            // through `self`/`cp` every lane store may alias them, so LLVM
            // reloaded both bases and `num_registers` on every iteration
            // (doc 60 §5.6).
            const w = self.frameWindow(cb, nreg);
            for (args[0..np], 0..) |v, i| w.set(i, v);
            var i: usize = np;
            while (i < nreg) : (i += 1) w.setNil(i);
            self.pushFrameTrusted(cl, cp.num_registers, cb, 0, 0, 0, 0);
            return cb;
        }
        // Surplus varargs: args land in a region at `arg_base`; the callee
        // window sits directly above. The surplus stays in the arg region
        // (below the callee base), stable and — once the push raises
        // `stack_top` — GC-rooted, exactly as the `.call` arm leaves them in
        // the caller's window. Reserves `args.len + num_registers` slots.
        const arg_base = self.stack_top;
        const cb = arg_base + args.len;
        if (cb + cp.num_registers > self.regCapacity()) return Error.StackOverflow;
        for (args, 0..) |v, i| self.regSet(arg_base + i, v);
        var i: usize = 0;
        while (i < cp.num_registers) : (i += 1) {
            self.regSet(cb + i, if (i < cp.num_params)
                self.regGet(arg_base + i)
            else
                Value.nil());
        }
        const va_count: usize = args.len - cp.num_params;
        const va_base: usize = arg_base + cp.num_params;
        self.pushFrameTrusted(cl, cp.num_registers, cb, 0, 0, va_base, va_count);
        return cb;
    }

    /// Doc 60 H1: the push half of a host call into a closure — everything
    /// `callValue` does before it runs the frame, minus the generic callee
    /// dispatch and the reentry increment (which `runPushedFrame` owns).
    /// Same checks in the same order as `callValue` (the `final_cut` clear,
    /// then the reentry limit, then depth and capacity), so a rejection leaves
    /// the VM exactly as `callValue` would. Returns the callee base.
    /// `inline`: an out-of-line `Error!usize` comes back through memory as a
    /// 2-byte error store plus an 8-byte payload store that the caller reads
    /// as one 16-byte load — a store-forwarding stall on every call
    /// (measured, doc 60 H1).
    pub inline fn pushHostCall(self: *Vm, cl: *const Closure, args: []const Value) Error!usize {
        std.debug.assert(!self.reg_top_pending);
        if (self.final_cut != null) self.retireFinalCut(); // doc 21: host reentry reuses the stack
        if (self.native_reentry_depth >= max_native_reentry) return Error.StackOverflow;
        return self.bindAndPushClosure(cl, args);
    }

    /// Doc 60 §4.1: run the frame a host entry just pushed at
    /// `frames[entry_depth]` (callee window at `base`) to its boundary return.
    /// VM-owned, no C-API dependency: H1 calls it after `pushHostCall`, and
    /// the H3 `.S` entry reaches it through `capi.mahina_hostcall_chain` after
    /// its own push. It owns `native_reentry_depth` on both edges (the same
    /// `defer` `callValue` uses), so callbacks during the run see the raised
    /// count and the decrement lands before the caller's fault handling or
    /// result parking. Dispatch is `execWithEntry`'s: `.fast` iff
    /// `runFastPath()`, else `.full` through `execWith`, with its errdefers
    /// (`abortRaised`, then `clearPendingExitAnchor`). On an error the frames
    /// stay live for the caller's `describeFault`, as in `callValue`.
    /// On success `depth == entry_depth` and `stack_top` is still raised over
    /// the popped window, so the `FrameResult` registers are readable; the
    /// caller copies them out and restores `stack_top`.
    /// `inline` for the same reason as `pushHostCall`: its callers (H1's
    /// `callClosure`, H3's chain function) each want it flattened, not an
    /// extra frame passing an error union through memory.
    pub inline fn runPushedFrame(self: *Vm, entry_depth: u32, base: usize) Error!FrameResult {
        std.debug.assert(self.depth == entry_depth + 1);
        // Doc 61 §4.2: a host entry needs no marking of its own. At depth > 0
        // it runs inside a host fn, whose caller frame the dispatch native
        // arm or `callValue` already marked in flight.
        std.debug.assert(entry_depth == 0 or self.frames[entry_depth - 1].in_flight);
        self.native_reentry_depth += 1;
        defer self.native_reentry_depth -= 1;
        if (self.final_cut != null) self.retireFinalCut();
        const cl = self.frames[entry_depth].closure;
        return switch (try self.execWithEntry(cl, cl.proto, base, entry_depth + 1)) {
            .finished => |fr| fr,
            // `native_reentry_depth` is raised above, so a due suspend is
            // deferred past this run (doc 68 §8): exec never suspends here.
            .suspended => unreachable,
        };
    }

    /// Call a mahina callable from native (host) code, run it to completion, write up
    /// to `results_out.len` results into `results_out`, and return the count
    /// actually written. `callee` must be a closure or native `Value` (else
    /// `TypeError`). This is the keystone reentrancy primitive: a native that holds
    /// `*Vm` via its ctx (`pcall`/`xpcall`, the `table.sort` comparator, `gsub`
    /// function-replacement) drives a mahina function and gets its results back.
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
    /// Precondition (asserted): no multret pair is pending (`!reg_top_pending`).
    /// An armed suspend is fine: the raised `native_reentry_depth` defers it
    /// past the nested run (doc 68 §8), because a suspend taken across this
    /// Zig frame would have no resume cursor. Doc 68's continuation frames
    /// retire this function for the VM's own natives and metamethods.
    ///
    /// GC contract for callers: `results_out` heap values are rooted only while the
    /// caller's own register window / scratch holds them; consume them before the
    /// next allocation without stashing a raw `Value` across a safepoint.
    /// Embedding (doc 59 §3.5): invoke an embedder-registered host function —
    /// the SINGLE funnel for every host-native invocation (the dispatch `.call`
    /// native arm and `callValue`'s `.native` arm both route here, so a future
    /// effect-recording chunk cannot miss a path). The binding owns its own
    /// result protocol (`host != null ⇒ effect/multi/recorded all null`).
    ///
    /// The host never writes its caller's destination. Host callbacks are
    /// arbitrary embedder code, so the NativeMultiFn read-args-first
    /// discipline can't be imposed on them, and the destination may alias
    /// `args` (`pcall`'s results sit one slot below its args, a `__call`
    /// redirect's at the same slot). It may also reach past `stack_top`,
    /// where a nested `mh_call` from the host lays out its frames. So the host
    /// writes a private range of `host_out` (at most `max_host_results` of the
    /// `want` asked for), and the returned slice of it holds the results. The
    /// range is free again once this returns: the caller copies the slice out
    /// before anything else can run a host fn. Inline, because both callers
    /// are on the host-call path and a call here costs more than the work.
    inline fn callHostNative(self: *Vm, nat: *function.Native, args: []const Value, want: usize) Error![]const Value {
        const hb = nat.host.?;
        std.debug.assert(nat.effect == null and nat.multi == null and nat.recorded == null);
        if (self.host_out.len == 0) self.host_out = try self.gpa.alloc(Value, host_out_slots);
        const n = @min(want, max_host_results);
        const lo = self.host_out_top;
        if (lo + n > self.host_out.len) return Error.StackOverflow;
        self.host_out_top = lo + n;
        // Error or not, the host has returned and its range is free again.
        defer self.host_out_top = lo;
        // Doc 63 §5.9: a call during which the epoch moved disturbs. Counted
        // in a `defer` so a failing call counts the same as a successful one.
        const epoch = self.heap.host_epoch;
        defer if (self.heap.host_epoch != epoch) {
            nat.disturbs +|= 1;
        };
        const buf = self.host_out[lo .. lo + n];
        const produced = hb.call(hb.ctx, @ptrCast(self), args, buf) catch |e| return narrowError(e);
        return buf[0..@min(produced, n)];
    }

    /// `callValue`'s native dispatch once `args` are rooted (the caller parked
    /// them). Results go straight into `results_out` (a concrete count is always
    /// wanted here; the `all_results` stamping path is dispatch-only).
    fn callNativeUnparked(self: *Vm, nat: *function.Native, args: []const Value, results_out: []Value) Error!usize {
        if (nat.host != null) {
            // Embedder host fn (doc 59 §3.5): the single invocation
            // funnel. `results_out` may alias `args` (`pcall` passes slices
            // of its own args and out); the funnel's private buffer makes
            // that safe.
            const res = try self.callHostNative(nat, args, results_out.len);
            // Whole-word stores: `results_out` is often a host buffer the C
            // side reads as 8-byte words (`Value.storeWords`).
            for (res, 0..) |v, k| Value.storeWords(&results_out[k], v);
            return res.len;
        }
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
    }

    pub fn callValue(self: *Vm, callee: Value, args: []const Value, results_out: []Value) Error!usize {
        if (!callee.isHeap()) return Error.TypeError;
        std.debug.assert(!self.reg_top_pending);
        if (self.final_cut != null) self.retireFinalCut(); // doc 21: host reentry reuses the stack
        if (self.native_reentry_depth >= max_native_reentry) return Error.StackOverflow;
        self.native_reentry_depth += 1;
        defer self.native_reentry_depth -= 1;
        // Doc 63 §5.6: re-entry, including metamethod dispatch (`indexGet`'s
        // `__index`), can change anything a trace relies on. A closure
        // callee bumps again in `execWithEntry`; a native callee only here.
        self.heap.bumpHostEpoch();

        // Doc 61 §4.2: the current frame is in flight inside its instruction
        // while the re-entered code runs (a metamethod, a native's callback,
        // a host `mh_call`), whether that pushes a frame above it or runs a
        // native that might. Restored on success only: an error leaves it set
        // with the retained faulting frames, for the catcher. For an `xpcall`
        // handler the current frame is the topmost faulting one, so this is
        // also §4.4's mark.
        if (self.depth == 0) return self.callValueIn(callee, args, results_out);
        const fr = &self.frames[self.depth - 1];
        const prev_in_flight = fr.in_flight;
        fr.in_flight = true;
        const n = try self.callValueIn(callee, args, results_out);
        fr.in_flight = prev_in_flight;
        return n;
    }

    /// `callValue`'s dispatch on the callee kind, once the re-entry is
    /// counted and the current frame marked in flight.
    inline fn callValueIn(self: *Vm, callee: Value, args: []const Value, results_out: []Value) Error!usize {
        switch (callee.heapType()) {
            // Native callee: no frame — mirror the `.call` `.native` dispatch arm.
            // Results go straight into `results_out` (a concrete count is always
            // wanted here; the `all_results` stamping path is dispatch-only).
            .native => {
                const nat = function.Native.fromHeader(callee.asHeap());
                // Doc 61 P3: a native callee gets `args` straight from the
                // caller, often Zig locals (the fused `a[i][j]` intermediate,
                // gsub captures, a synthesized error value, a searcher's loader
                // data) that nothing roots. A native that re-enters the VM
                // (`table.sort`'s comparator, `print`'s `__tostring`, a host
                // fn calling `mh_collect`) could then have them swept while it
                // still holds them. The callee itself is no better off: a
                // metamethod native whose callback drops the last reference to
                // it (and collects) would be freed while it runs, along with a
                // host fn's ctx. Park the callee and a copy of `args` at
                // `stack_top`, the shape of a Lua call's function slot plus its
                // arguments, and raise `stack_top` over them, so they stay
                // rooted for the call and every re-entry lays its window (and
                // scratch) above them. The native still reads the caller's
                // `args`, so the alias relationships between `args` and
                // `results_out` are unchanged. Restored on success; an error
                // leaves it raised for the catcher (as the `__call` arm).
                const pbase = self.stack_top;
                if (pbase + 1 + args.len > self.regCapacity()) return Error.StackOverflow;
                self.regSet(pbase, callee);
                for (args, 0..) |v, i| self.regSet(pbase + 1 + i, v);
                self.stack_top = pbase + 1 + args.len;
                const n = try self.callNativeUnparked(nat, args, results_out);
                self.stack_top = pbase;
                return n;
            },
            // Closure callee: lay out a fresh window at `stack_top`, bind params
            // exactly like the `.call` arm, push, and run a bounded nested exec.
            .function => {
                const cl = Closure.fromHeader(callee.asHeap());
                const cp = cl.proto;
                const entry_depth = self.depth;
                const saved_top = self.stack_top;
                const callee_base = try self.bindAndPushClosure(cl, args);

                // No `errdefer` restore: a runtime error must leave `self.frames`
                // live (depth raised) so the catching `pcall` can synthesize the
                // located message before it restores the boundary — the whole-VM
                // "errors don't unwind frames" invariant. Success falls through to
                // the explicit `stack_top` restore below.
                const outcome = try self.execWithEntry(cl, cp, callee_base, entry_depth + 1);
                const res = switch (outcome) {
                    .finished => |f| f,
                    // `callValue` raised `native_reentry_depth`, so a due
                    // suspend is deferred past this run (doc 68 §8).
                    .suspended => unreachable,
                };
                // The boundary frame is popped (`depth == entry_depth`) but
                // `stack_top` is still raised over its window, so its result
                // registers are live and rooted. Copy them out before shrinking.
                const src = callee_base + res.reg;
                const n = @min(@as(usize, res.count), results_out.len);
                var k: usize = 0;
                // Whole-word stores: `results_out` is often a host buffer the
                // C side reads as 8-byte words (`Value.storeWords`).
                while (k < n) : (k += 1) Value.storeWords(&results_out[k], self.regGet(src + k));
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
        const fault = try self.describeFault(e, a);
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
        if (std.debug.runtime_safety) self.assertFrameShapesKnown();
        if (builtin.is_test) if (test_collect_probe) |probe| probe(self);
        self.heap.beginCollect() catch return;
        // Doc 63 §5.6/§5.7: every collection moves the epoch. A skipped cycle
        // (above) changed nothing, so it doesn't.
        self.heap.bumpHostEpoch();
        // The root set is defined once in `forEachRootHeader`; marking is just
        // "call `markHeader` on each root".
        self.forEachRootHeader(self.heap, gc.Heap.markHeader);
        self.heap.traceAll();
        self.invalidateDeadTraceConsts();
        self.scrubDeadRegisters();
        self.heap.sweep();
    }

    /// Doc 61 §7.1 item 2: trace constant pools are not roots, so between
    /// mark and sweep every trace, and the in-flight recording, that names a
    /// constant the sweep will free goes first. A trace is retired through
    /// the batch path; the recording is cancelled without `abort`'s peel
    /// rewind (which could close a `.link` that keeps the pool). No trace
    /// code is on the stack here (collection runs only at the tier-0
    /// safepoint or from `mh_collect`), so nothing observes the retirement
    /// mid-flight. One colour read per heap constant; the doomed list was
    /// reserved at publish, so nothing here allocates for it.
    fn invalidateDeadTraceConsts(self: *Vm) void {
        const ts = &self.trace;
        std.debug.assert(!ts.registry.native_physical.inReplayWalk());
        if (ts.isRecording()) {
            for (ts.rec.consts.items) |v| {
                if (v.isHeap() and gc.Heap.willFree(v.asHeap())) {
                    ts.cancelRecording(.const_swept);
                    break;
                }
            }
        }
        const doomed = &ts.registry.batch_scratch;
        doomed.clearRetainingCapacity();
        for (ts.registry.cache.items) |t| {
            for (t.code.heap_consts) |i| {
                if (gc.Heap.willFree(t.code.consts[i].asHeap())) {
                    const dying = t.code.consts[i];
                    const bytes: []const u8 = if (dying.heapType() == .string) string.String.fromHeader(dying.asHeap()).bytes() else "";
                    ts.dbg("const-swept: t={d} const={d} type={s} bytes=\"{s}\"", .{ t.id, i, @tagName(dying.heapType()), bytes });
                    doomed.appendAssumeCapacity(t);
                    break;
                }
            }
        }
        ts.removeTraces(doomed.items);
        doomed.clearRetainingCapacity();
    }

    /// Test builds only: called at the start of every `collect` on this
    /// thread, to observe the frame state a collection sees (doc 61 §4.1's
    /// innermost pc). Thread-local, so VMs on other threads are unaffected;
    /// `collect` never reads it outside test builds.
    pub threadlocal var test_collect_probe: ?*const fn (*Vm) void = null;

    /// Doc 61 §4: the shape of a live frame at a collection, read from
    /// recorded state (`in_flight`, `pc`, the opcode before `pc`), never
    /// guessed. It names the pc whose `Proto.reg_live` row is the frame's
    /// mask.
    pub const FrameShape = struct {
        kind: Kind,
        /// The mask row: `live_in[pc]` (§4.1, §4.2), intersected with
        /// `[0, call_a)` for `.suspended_call` (§4.3).
        pc: usize,
        /// `.suspended_call` only: the base `a` of the `.call` at `pc - 1`.
        call_a: u16 = 0,

        pub const Kind = enum {
            /// §4.1: the top frame, between instructions (`pc` is the next
            /// one) or inside one that runs no other code.
            innermost,
            /// §4.2: inside instruction `pc`, which is running other code.
            in_flight,
            /// §4.3: below the top, one past the `.call` that pushed the frame
            /// above it.
            suspended_call,
            /// §4.5: none of the above; the frame is scanned whole.
            unknown,
        };
    };

    pub fn frameShape(self: *const Vm, i: usize) FrameShape {
        std.debug.assert(i < self.depth);
        const f = &self.frames[i];
        if (f.in_flight) return .{ .kind = .in_flight, .pc = f.pc };
        if (i == self.depth - 1) return .{ .kind = .innermost, .pc = f.pc };
        const code = f.closure.proto.code;
        // `pc == 0` would read before the code; no `.call` can precede it.
        if (f.pc == 0 or f.pc > code.len) return .{ .kind = .unknown, .pc = f.pc };
        const call = bytecode.callOperandsOf(code[f.pc - 1]) orelse return .{ .kind = .unknown, .pc = f.pc };
        return .{ .kind = .suspended_call, .pc = f.pc, .call_a = call.a };
    }

    /// Doc 61 §4.5: every frame of a maskable proto lands in a known shape,
    /// with its mask pc inside the code. Checked at every collection in
    /// safety builds (the gc-stress test legs collect at every safepoint).
    fn assertFrameShapesKnown(self: *const Vm) void {
        for (0..self.depth) |i| {
            const proto = self.frames[i].closure.proto;
            if (!proto.maskable) continue;
            const shape = self.frameShape(i);
            // The mask row `live_in[pc]` must exist (a `.call` is never a
            // proto's last instruction: the compiler ends every body in
            // `ret`/`halt`).
            const in_code = shape.kind != .unknown and shape.pc < proto.code.len;
            if (!in_code) std.debug.panic("doc 61: frame {d}/{d} ({s}) has no known shape: {s} at pc {d} of {d}", .{
                i, self.depth, proto.name, @tagName(shape.kind), shape.pc, proto.code.len,
            });
        }
        // §6.2: every window lies below `stack_top`, so whatever is parked at
        // `stack_top` (P3) or above it sits in a gap, never in a masked window.
        if (self.depth > 0) {
            const f = &self.frames[self.depth - 1];
            std.debug.assert(f.base + f.closure.proto.num_registers <= self.stack_top);
        }
    }

    /// Doc 61 §4: the masked part of frame `i`'s window: `live_in` at the
    /// frame's shape pc, cut at `limit` window-relative registers. Null when
    /// the frame is kept whole (§4.5: a non-maskable proto or an unknown
    /// shape). `fillKeep` adds varargs spans and open upvalues on top.
    const FrameMask = struct { row: []const u64, limit: usize };

    fn frameMask(self: *const Vm, i: usize) ?FrameMask {
        const f = &self.frames[i];
        const proto = f.closure.proto;
        if (!proto.maskable) return null;
        const shape = self.frameShape(i);
        if (shape.kind == .unknown or shape.pc >= proto.code.len) return null;
        const nreg: usize = proto.num_registers;
        const limit: usize = switch (shape.kind) {
            // §4.3: slots at or above the call base are not yet the caller's.
            .suspended_call => shape.call_a,
            // §5 (B): inside a multret consumer, only its dynamic span was
            // written. The opcode recorded its end before anything in it can
            // fail. A frame in flight at a consumer is always inside it: no
            // suspend point or host entry sits between a producer and its
            // consumer (`reg_top_pending`), so `pc` never names one that has
            // not started.
            .in_flight => blk: {
                const call = bytecode.callOperandsOf(proto.code[shape.pc]);
                break :blk if (call != null and call.?.b == bytecode.all_results) f.multret_top else nreg;
            },
            .innermost, .unknown => nreg,
        };
        return .{ .row = proto.reg_live.row(@intCast(shape.pc)), .limit = @min(limit, nreg) };
    }

    /// Doc 21 Phase A: the published final cut, if it still describes this VM.
    /// All upvalues are closed before every pop, so open ones mean invalid
    /// metadata. Any miss returns null, and `fillKeep` then keeps the whole
    /// depth-0 stack, the fail-safe.
    pub fn validFinalCut(self: *const Vm) ?FinalCut {
        if (self.depth != 0) return null;
        const fc = self.final_cut orelse return null;
        if (fc.stack_top != self.stack_top) return null;
        if (@as(usize, fc.result_base) + fc.result_count > self.stack_top) return null;
        if (self.open_upvalues.items.len != 0) return null;
        return fc;
    }

    /// Invalidate the final cut before anything reuses the stack (a host
    /// reentry, a fresh run, a C-API fault). At a validated cut every slot
    /// outside the result span is dead: capture tombstoned it, and a restored
    /// VM holds nil there. Nil it here as well. Otherwise, once the cut is
    /// gone, `fillKeep` keeps the old prefix whole and roots the stale values
    /// the restored VM never had (Codex review of doc 61 Phase K). O(stack_top)
    /// once per finished run; later clears find no cut.
    pub fn retireFinalCut(self: *Vm) void {
        if (self.validFinalCut()) |fc| {
            const end = @as(usize, fc.result_base) + fc.result_count;
            self.fillNil(0, fc.result_base);
            self.fillNil(end, self.stack_top - end);
        }
        self.setFinalCut(null);
    }

    /// Doc 61 §6.1/§6.2: fill `keep` (at least `stack_top / 64` rounded up
    /// words) over `[0, stack_top)`. At a validated final state
    /// (`validFinalCut`) only the top-level result span is kept: nothing
    /// reads the rest before the stack is reused, which clears the cut.
    /// Otherwise gaps between windows (host argument regions, parked callees,
    /// dynamic spans) and unmasked windows are kept whole. A masked window
    /// keeps its frame's mask, every frame's varargs span and every open
    /// upvalue's slot. All windows are cleared before any mask is ORed in, so
    /// even overlapping windows could only keep more, never drop a slot
    /// another frame needs. O(stack_top / 64 + Σ window words + aliases), no
    /// allocation. The collector fills `gc_keep`; keyframe capture fills its
    /// own buffer and tombstones the rest (Phase K), so both drop exactly the
    /// same slots, and a restored VM, which re-derives the cut, keeps the
    /// same ones.
    pub fn fillKeep(self: *const Vm, keep_buf: []u64) void {
        const top = self.stack_top;
        const keep = keep_buf[0 .. (top + 63) / 64];
        if (self.validFinalCut()) |fc| {
            @memset(keep, 0);
            setBitRange(keep, fc.result_base, @as(usize, fc.result_base) + fc.result_count);
            return;
        }
        @memset(keep, ~@as(u64, 0));
        for (0..self.depth) |i| {
            if (self.frameMask(i) == null) continue;
            const f = &self.frames[i];
            const hi = @min(f.base + f.closure.proto.num_registers, top);
            if (f.base < hi) clearBitRange(keep, f.base, hi);
        }
        for (0..self.depth) |i| {
            const f = &self.frames[i];
            if (self.frameMask(i)) |m| {
                if (f.base < top) orBitsAt(keep, f.base, m.row, @min(m.limit, top - f.base));
            }
            if (f.varargs_count > 0 and f.varargs_base < top)
                setBitRange(keep, f.varargs_base, @min(f.varargs_base + f.varargs_count, top));
        }
        for (self.open_upvalues.items) |ou| {
            if (ou.index < top) keep[ou.index / 64] |= @as(u64, 1) << @intCast(ou.index % 64);
        }
    }

    /// Bit `i` is set when register `at + i` has tag `tag`. `at` is a
    /// multiple of 64 below `stack_slots` (itself a multiple of 64), so the
    /// 64-tag block is in bounds. One vector compare per 64 registers keeps
    /// both register passes of a collection a linear scan of the tag bytes.
    inline fn tagMask(self: *const Vm, at: usize, tag: value.Tag) u64 {
        const block: @Vector(64, u8) = self.tags[at..][0..64].*;
        return @bitCast(block == @as(@Vector(64, u8), @splat(@intFromEnum(tag))));
    }

    /// `cb` on every kept register holding a heap value, in stack order. A
    /// `row_view` (doc 14) is not a heap value but borrows its parent grid
    /// table's cells, so it roots that table, as `Heap.markValue` has it.
    fn forEachKeptRegister(self: *Vm, ctx: anytype, comptime cb: fn (@TypeOf(ctx), *object.GcHeader) void) void {
        const top = self.stack_top;
        for (self.gc_keep[0 .. (top + 63) / 64], 0..) |word, wi| {
            const at = wi * 64;
            const refs = self.tagMask(at, .heap_ref) | self.tagMask(at, .row_view);
            var w = word & lowBits(top - at) & refs;
            while (w != 0) : (w &= w - 1) {
                const v = self.regGet(at + @ctz(w));
                cb(ctx, if (v.isRowView()) v.rowViewParent() else v.asHeap());
            }
        }
    }

    /// Doc 61 §6.4: nil every register below `stack_top` that the last
    /// `.gc` walk did not keep. Each is a window slot dead at its frame's
    /// pc, written before any read on every path from there, so the program
    /// cannot see the nil; afterwards no register points to a swept object,
    /// and every tier holds the same nil.
    fn scrubDeadRegisters(self: *Vm) void {
        const top = self.stack_top;
        const nil = Value.nil();
        for (self.gc_keep[0 .. (top + 63) / 64], 0..) |word, wi| {
            const at = wi * 64;
            // A dead slot already nil (every one scrubbed before and not
            // written since) needs no store, so a steady state stores
            // almost nothing.
            var dead = ~word & lowBits(top - at) & ~self.tagMask(at, .nil);
            while (dead != 0) : (dead &= dead - 1) self.regSet(at + @ctz(dead), nil);
        }
    }

    /// Visit every GC root that is a heap object, invoking `cb(ctx, header)` once
    /// per root edge. This is the **single source of truth** for "what is live
    /// from outside the heap", driven by the collector (`collect`, with
    /// `cb = markHeader`). Keyframe capture does not walk roots: it serializes
    /// every unswept object (doc 61 Phase K). A non-heap root `Value` (a scalar
    /// register/const) is skipped here — `cb` only ever sees heap headers.
    ///
    /// Roots, in a fixed order:
    ///   1. globals — user globals and the installed natives (e.g. `print`),
    ///      plus their interned name keys.
    ///   2. the registers the doc 61 keep-set names (`fillKeep`); `collect`
    ///      scrubs the rest before the sweep.
    ///   3. the closures executing in each active frame (`frames[0..depth]` —
    ///      keeps their proto constants reachable).
    ///   4. open upvalue cells (live by construction — about to be closed).
    ///   5. (none — trace constants are NOT roots in either walk; doc 61 §7.1.)
    ///      Rooting a trace's const pool made liveness tier-dependent: a string
    ///      only a trace names survived in the JIT legs and was swept in tier-0,
    ///      so a later re-intern took a different object id. Instead `collect`
    ///      retires every trace (and cancels the recording) that names a
    ///      constant the sweep will free (`invalidateDeadTraceConsts`), so
    ///      liveness is identical in every tier and no trace keeps a dangling
    ///      constant.
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
        self.fillKeep(self.gc_keep);
        self.forEachKeptRegister(ctx, cb);
        for (self.frames[0..self.depth]) |f| cb(ctx, @constCast(&f.closure.header));
        for (self.open_upvalues.items) |ou| cb(ctx, &ou.cell.header);
        // Host-retained chunks (docs/design/03 §"Chunk-constant rooting"): keep a
        // compiled-but-not-yet-run chunk's interned constants alive across the
        // compile→run window.
        for (self.retained_chunks.items) |proto| rootProtoConsts(proto, ctx, cb);
        // Loaded chunks (docs/design/19) are NOT re-rooted here: a
        // `load`/`loadfile`/`dofile`/`require` chunk's protos are VM-owned until
        // deinit, and `appendLoadedChunk` pinned their interned constants once
        // (sweep never frees a pinned object). Walking every loaded tree every
        // cycle made GC cost grow with every `load`/`mh_eval`. The pin also means
        // a trace const over a loaded proto never dooms its trace
        // (`Heap.willFree` excludes pinned).
        //
        // Embedding (doc 59 §3.3): host-held refs and parked C-boundary results
        // (freed ref slots hold nil, so no stale marks).
        for (self.host_refs.items) |slot| if (slot.value.isHeap()) cb(ctx, slot.value.asHeap());
        for (self.parked_inline[0..self.parked_inline_len]) |v| if (v.isHeap()) cb(ctx, v.asHeap());
        for (self.parked_results.items) |v| if (v.isHeap()) cb(ctx, v.asHeap());
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
        // Doc 63 §5.6: every guest execution moves the epoch. `run`, `start`
        // and a resume reach the dispatch loop here, not via `execWithEntry`.
        self.heap.bumpHostEpoch();
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
                self.setFinalCut(.{
                    .result_base = fr.reg,
                    .result_count = fr.count,
                    .stack_top = @intCast(self.stack_top),
                });
            }
        }
        return outcome;
    }

    /// `exec`, bounded by a stop depth. The dispatch loop returns `.finished` the
    /// instant a `.ret`/`.halt` pops the frame at `stop_depth` (the top-level main
    /// frame for `stop_depth == 1`; a reentrant `callValue`'s nested top frame for
    /// `stop_depth == entry_depth + 1`). Threads `stop_depth` through the
    /// `switch_mode` re-entry so a mode flip mid-nested-run resumes the same bound.
    /// Host-entry fast path (doc 59): enter the dispatch chain for the frame
    /// `callValue` JUST pushed, building `ExecState` from the values it still
    /// holds in registers (`cl`/`cp`/`base`, pc = 0) instead of re-deriving
    /// the frame→closure→proto→code pointer chain through `execWith` →
    /// `execImpl`. That re-derivation is a serial dependent-load spine the
    /// boundary crossing pays on every entry; nothing else differs — same
    /// errdefers, same exit handling, and a `.switch_mode` (or a non-fast VM
    /// state) falls through to the general `execWith` loop.
    inline fn execWithEntry(self: *Vm, cl: *const Closure, cp: *const Proto, base: usize, stop_depth: u32) Error!ExecOutcome {
        // Doc 63 §5.6: guest execution entered from native code (`callValue`,
        // H1's `runPushedFrame`, H3's chain) can change anything a trace
        // relies on.
        self.heap.bumpHostEpoch();
        errdefer self.trace.clearPendingExitAnchor();
        errdefer self.trace.abortRaised(); // guarded no-op when idle (doc 26 D1a)
        if (self.runFastPath()) {
            const frame = &self.frames[self.depth - 1];
            var st: ExecState = .{
                .vm = self,
                .frame = frame,
                .closure = cl,
                .proto = cp,
                .code = self.cachedCodeFor(frame, cp), // doc 20 image
                .code_gen = self.trace.registry.entry_registry.image_gen,
                .base = base,
                .regs = self.frameWindow(base, cp.num_registers),
                .stop_depth = stop_depth,
                .step = undefined,
                .err = null,
            };
            self.trace.setRegionContext(self.depth, frame.call_seq);
            switch (@call(.never_inline, chainEntry(.fast), .{ &st, 0, undefined, self, st.regs.tags, st.regs.payloads })) {
                .finished => {
                    self.trace.clearPendingExitAnchor();
                    return .{ .finished = switch (st.step) {
                        .finished => |fr| fr,
                        else => unreachable, // chain `.finished` always stamps `.step`
                    } };
                },
                .suspended => {
                    self.trace.clearPendingExitAnchor();
                    return .suspended;
                },
                .switch_mode => {}, // mode flip parked `frame.pc`; general loop resumes
                .err => return st.err.?,
            }
        }
        // The nested errdefers in `execWith` re-run ours on an error edge;
        // both are idempotent (anchor clear, guarded abort).
        return self.execWith(stop_depth);
    }

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
    ///
    /// Doc 60 §5.4: the eleven conditions are packed into `trace.fast_block`, so
    /// this is one 16-bit load and compare. Debug builds check the word
    /// bit-for-bit against `fastBlockReference` on every call.
    inline fn runFastPath(self: *const Vm) bool {
        if (builtin.is_test and self.reference_dispatch) return self.fastBlockReference() == 0;
        if (std.debug.runtime_safety) std.debug.assert(self.trace.fast_block == self.fastBlockReference());
        return self.trace.fast_block == 0;
    }

    /// Doc 63 §5.9: the JIT is suspended, as the dispatch handlers see it.
    /// Suspension is a `fast_block` bit, so a suspended VM always dispatches
    /// `.full`, and in `.fast` this is comptime false: the gates cost the hot
    /// path nothing.
    inline fn jitSuspended(self: *const Vm, comptime mode: ExecMode) bool {
        if (mode == .fast) {
            std.debug.assert(!self.trace.suspended());
            return false;
        }
        return self.trace.suspended();
    }

    /// Doc 60 §5.4: the `fast_block` word recomputed from the eleven fields it
    /// mirrors — the reference the packed word is asserted against.
    pub fn fastBlockReference(self: *const Vm) u16 {
        const FastBit = trace.TraceState.FastBit;
        var w = self.trace.traceFastBits();
        if (self.suspend_ctl != null) w |= FastBit.vm_suspend;
        if (self.record_safepoint_lines) w |= FastBit.vm_safepoint_lines;
        if (self.final_cut != null) w |= FastBit.vm_final_cut;
        return w;
    }

    /// Publish (or, with null, drop) the final cut. Use `retireFinalCut` to
    /// drop it before reusing the stack.
    pub fn setFinalCut(self: *Vm, fc: ?FinalCut) void {
        self.final_cut = fc;
        self.trace.setFastBit(trace.TraceState.FastBit.vm_final_cut, fc != null);
    }

    /// Whether a due suspend may stop at the current safepoint. Not while a
    /// native runs code through a Zig re-entry (doc 68 §8, defer: that Zig
    /// frame could not be resumed), nor while a multret result is pending
    /// (`reg_top_pending`: its producer and consumer are one step). The
    /// replay index records the same predicate per safepoint, so the steps
    /// it offers are exactly the ones a replay stops at.
    pub inline fn canSuspendHere(self: *const Vm) bool {
        return self.native_reentry_depth == 0 and !self.reg_top_pending;
    }

    /// Arm (or, with null, disarm) the mid-execution suspend trigger.
    pub fn setSuspendCtl(self: *Vm, ctl: ?SuspendCtl) void {
        self.suspend_ctl = ctl;
        self.trace.setFastBit(trace.TraceState.FastBit.vm_suspend, ctl != null);
    }

    /// Turn the replay driver's per-safepoint line index on or off.
    pub fn setRecordSafepointLines(self: *Vm, on: bool) void {
        self.record_safepoint_lines = on;
        self.trace.setFastBit(trace.TraceState.FastBit.vm_safepoint_lines, on);
    }

    // ------------------------------------------------------------------------
    // Doc 42: tail-call threaded dispatch — one handler FUNCTION per opcode,
    // dispatched with `@call(.always_tail)` through a per-mode fn-pointer
    // table. Rationale (doc 42 §1–2): each handler is its own symbol, so LLVM
    // lays it out (and allocates registers for it) independently — the
    // interpreter's speed is no longer hostage to basic-block placement of a
    // single ~48KB megafunction re-rolled by every trace-helper edit. This is
    // the real interpreter behind the `dispatch.zig` capability gate ("the toy
    // loop is temporary; the capability is the pillar" — architecture doc 00,
    // principle #4).
    // ------------------------------------------------------------------------

    /// Doc 42 §4.1: everything one `execImpl` invocation threads through its
    /// handler chain, EXCEPT the two hottest data (`pc`, `instr`), which ride
    /// as by-value musttail arguments. Owned by `execImpl`'s frame — the chain
    /// is entered by an ORDINARY call (never a musttail from `execImpl`), so a
    /// pointer to this state can never outlive the frame it lives on. Handlers
    /// and the dispatch helper musttail among themselves; any exit event
    /// returns through the whole chain in one `ret`.
    const ExecState = struct {
        vm: *Vm,
        /// Hot top-frame state, re-derived by `reloadTopFrame` after every
        /// real push/pop (`.call` Lua entry, `.ret`).
        frame: *CallFrame,
        closure: *const Closure,
        proto: *const Proto,
        /// Doc 20: dispatch fetches from the VM-local copy-on-patch image when
        /// one exists (canonical `proto.code` otherwise — the empty-map
        /// early-out makes that one counter load). `code_gen` memoizes the
        /// image generation; the patched-entry and back-edge sites re-resolve
        /// when it moves (§R2-1).
        code: []const Instr,
        code_gen: u64,
        base: usize,
        regs: RegWindow,
        stop_depth: u32,
        /// Exit payload: written by the `.ret`/`.halt` handler before it
        /// returns `.finished` (the only `HandlerResult` carrying a payload).
        step: ExecStep,
        /// Doc 42 §4.3: the parked error. A musttail chain cannot thread an
        /// error-union return (§3.1: sret breaks musttail — verified compile
        /// error), so every error edge in a handler parks here and returns
        /// `.err`; `execImpl` re-raises it at the chain boundary, which keeps
        /// `execWith`'s errdefers and every enclosing pcall byte-identical.
        /// Initialized `null` on EVERY entry.
        err: ?Error,
    };

    /// Doc 42 §4.1: register-sized handler return. A handler that continues
    /// execution never returns — it tail-jumps to the next dispatch; only exit
    /// events return, and they return through the whole musttail chain in one
    /// `ret` to `execImpl`.
    const HandlerResult = enum(u8) { finished, suspended, switch_mode, err };

    /// The uniform musttail signature. Every handler, the dispatch helper, and
    /// the back-edge trampoline share it EXACTLY, so every hop in the chain is
    /// a guaranteed tail call (`dispatch.zig` is the permanent capability gate
    /// for the mechanism; `interp_dispatch_test.zig` T-6 gates the real
    /// handlers).
    const HandlerFn = fn (st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult;

    const op_count = @typeInfo(bytecode.OpCode).@"enum".field_names.len;

    /// Doc 42 §4.3: park-and-return — the mechanical translation of every
    /// error edge that used to `try`/`return err` out of an opcode arm. The
    /// happy path pays nothing (no error-union ABI on the tail chain at all);
    /// the error path pays one store+branch and is already the slow path.
    inline fn parkErr(st: *ExecState, e: Error) HandlerResult {
        st.err = e;
        return .err;
    }

    /// Doc 42 §4.4: re-derive the hot top-frame state after a REAL push/pop
    /// (`.call` Lua entry, `.ret`) — the old explicit reload blocks, verbatim,
    /// including `setRegionContext`. The surrounding boundary ORDER
    /// (callee-window init without safepoint → park caller pc → push → reload;
    /// close upvalues → copy results while the callee window is rooted → pop →
    /// reload → shrink `stack_top`) is owned by the call/ret handlers, not by
    /// this helper. Trace/deopt resumes must NOT use this — they re-resolve
    /// nothing (no `codeFor`, no `setRegionContext`; adding those would change
    /// observer behavior and cost on productive resumes) and just
    /// tail-dispatch at the new pc.
    /// Doc 44 D9 (S4): resolve `proto`'s current doc-20 fetch image through
    /// the frame's cache — the `codeFor` hash is paid once per (frame, image
    /// generation), not on every push/pop boundary crossing. The cache is
    /// implicitly keyed by the frame's closure (immutable for a live frame);
    /// push-time defaults invalidate on slot reuse.
    inline fn cachedCodeFor(self: *Vm, frame: *CallFrame, proto: *const Proto) []const Instr {
        const gen = self.trace.registry.entry_registry.image_gen;
        // Doc 54 P0: `gen == INVALID` (a 2⁶⁴-bump wrap onto the sentinel) must
        // neither hit (a sentinel-gen frame is INVALID, not "cached at gen
        // maxInt") nor fill (the fill would be indistinguishable from
        // invalid). One predictable compare; the cache simply never hits for
        // that one generation — fail closed.
        if (frame.code_cache_gen == gen and gen != CODE_CACHE_GEN_INVALID)
            return frame.code_cache;
        const img = self.trace.codeFor(proto);
        if (gen != CODE_CACHE_GEN_INVALID) {
            frame.code_cache = img;
            frame.code_cache_gen = gen;
        }
        return img;
    }

    inline fn reloadTopFrame(st: *ExecState) void {
        const vm = st.vm;
        st.frame = &vm.frames[vm.depth - 1];
        st.closure = st.frame.closure;
        st.proto = st.closure.proto;
        st.code = vm.cachedCodeFor(st.frame, st.proto); // doc 20 image
        st.code_gen = vm.trace.registry.entry_registry.image_gen;
        st.base = st.frame.base;
        st.regs = vm.frameWindow(st.base, st.proto.num_registers);
        vm.trace.setRegionContext(vm.depth, st.frame.call_seq);
    }

    /// The per-mode handler tables, comptime-built from `handlerFor`. Two
    /// instantiations so the `.full`-only prologue hooks compile out of the
    /// `.fast` handlers exactly as the old `nextOp` instantiations did.
    /// `bytecode.zig`'s comptime density assert is what makes the bare
    /// `[@intFromEnum(op)]` indexing total and correct.
    const handler_table_fast = buildHandlerTable(.fast);
    const handler_table_full = buildHandlerTable(.full);

    fn buildHandlerTable(comptime mode: ExecMode) [op_count]*const HandlerFn {
        @setEvalBranchQuota(10_000);
        var t: [op_count]*const HandlerFn = undefined;
        inline for (@typeInfo(bytecode.OpCode).@"enum".field_names, 0..) |name, i| {
            t[i] = handlerFor(mode, @field(bytecode.OpCode, name));
        }
        return t;
    }

    inline fn handlerTable(comptime mode: ExecMode) *const [op_count]*const HandlerFn {
        return if (mode == .fast) &handler_table_fast else &handler_table_full;
    }

    /// The per-mode slow-handler tables (doc 62 §4.3, follow-up): for an op
    /// whose fast path calls nothing, the handler that does the rest. A
    /// fast handler leaves through `slowTail`, a tail jump through this
    /// table indexed by the instruction's own opcode. That index is a
    /// runtime value, so LLVM cannot fold the jump into a direct call and
    /// inline the slow handler back, whose calls would make every fast hit
    /// save and restore five callee-saved registers. Ops without a split
    /// map to `noSlowPath`.
    const slow_table_fast = buildSlowTable(.fast);
    const slow_table_full = buildSlowTable(.full);

    fn buildSlowTable(comptime mode: ExecMode) [op_count]*const HandlerFn {
        var t: [op_count]*const HandlerFn = undefined;
        for (&t) |*h| h.* = noSlowPath;
        t[@intFromEnum(bytecode.OpCode.get_global)] = opGetGlobalSlow(mode);
        t[@intFromEnum(bytecode.OpCode.get_index)] = opGetIndexSlow(mode);
        t[@intFromEnum(bytecode.OpCode.set_index)] = opSetIndexSlow(mode);
        t[@intFromEnum(bytecode.OpCode.get_field)] = opGetFieldSlow(mode);
        t[@intFromEnum(bytecode.OpCode.set_field)] = opSetFieldSlow(mode);
        inline for (.{ .idiv, .mod, .idiv_rk, .mod_rk, .idiv_kr, .mod_kr }) |op| t[@intFromEnum(@as(bytecode.OpCode, op))] = opModIdivSlow(mode, op);
        inline for (.{ .eq, .ne }) |op| t[@intFromEnum(@as(bytecode.OpCode, op))] = opEqNeSlow(mode, op);
        inline for (.{ .eq_n, .ne_n }) |op| t[@intFromEnum(@as(bytecode.OpCode, op))] = opEqNSlow(mode, op);
        inline for (.{ .lt, .le, .gt, .ge }) |op| t[@intFromEnum(@as(bytecode.OpCode, op))] = opCompareSlow(mode, op);
        inline for (.{ .jlt, .jle, .jgt, .jge, .jlt_k, .jle_k, .jgt_k, .jge_k }) |op| t[@intFromEnum(@as(bytecode.OpCode, op))] = opJOrderSlow(mode, op);
        inline for (.{ .jeq, .jeq_n }) |op| t[@intFromEnum(@as(bytecode.OpCode, op))] = opJEqSlow(mode, op);
        t[@intFromEnum(bytecode.OpCode.itern)] = opIternSlow(mode);
        return t;
    }

    fn noSlowPath(_: *ExecState, _: usize, instr: *const Instr, _: *Vm, _: [*]u8, _: [*]u64) HandlerResult {
        std.debug.panic("no slow handler for {s}", .{@tagName(instr.op)});
    }

    /// Leave a fast handler for its op's slow handler (`buildSlowTable`),
    /// with the handler's own arguments: the slow handler runs the
    /// instruction from the start.
    inline fn slowTail(comptime mode: ExecMode, st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
        const table_ = if (mode == .fast) &slow_table_fast else &slow_table_full;
        return @call(.always_tail, table_[@intFromEnum(instr.op)], .{ st, pc, instr, vm, tags, payloads });
    }

    /// Doc 42 §4.2: the dispatch tail — the complete per-instruction prologue
    /// followed by the table jump, `inline` so it expands INTO every handler
    /// tail and the `@call(.always_tail)` at its end jumps handler→handler
    /// directly (true direct threading: each handler carries its own copy of
    /// the prologue and its own indirect-jump site, exactly as the old 61
    /// `nextOp` thread sites did — a first cut through a shared non-inline
    /// dispatch function measured +37.7% on pi_leibniz tier-0 from the
    /// per-instruction call frame it added). Runs **between every pair of
    /// instructions in both modes**, so GC timing, `safepoint_seq` counting,
    /// suspend points, replay-line recording, and the trace recording mirror
    /// stay byte-identical to the old `nextOp` prologue. The numbered step
    /// order below is the determinism contract (doc 42 §4.2 — normative; do
    /// not reorder).
    /// `&instr[1]` — the next-instruction pointer for a straight-line fall
    /// through. Zig single-item pointers have no arithmetic, so bounce
    /// through a many-item pointer.
    inline fn instrNext(instr: *const Instr) *const Instr {
        const many: [*]const Instr = @ptrCast(instr);
        return &many[1];
    }

    /// General dispatch: `pc` is an arbitrary target (jump, frame reload,
    /// chain entry), so derive the fetch pointer from the cached image.
    inline fn dispatchTail(comptime mode: ExecMode, st: *ExecState, pc: usize, vm: *Vm) HandlerResult {
        // Lanes re-derived from `st.regs` — the authoritative window for an
        // arbitrary target (post-reload, post-epilogue); identical reads to
        // the pre-widening general path.
        return dispatchTailFrom(mode, st, pc, &st.code[pc], vm, st.regs.tags, st.regs.payloads);
    }

    /// Dispatch with a caller-supplied fetch pointer (`iptr == &st.code[pc]`).
    /// Straight-line handlers pass `instrNext(instr)` — the identity
    /// `instr == &st.code[pc - 1]` holds at every handler entry, so
    /// `instr + 1 == &st.code[pc]` against the SAME cached image (identical
    /// staleness semantics to the general path; no new hazard). What it buys:
    /// the opcode-load address is ready at handler ENTRY instead of behind an
    /// `st.code` load, shortening the dependency chain into the indirect
    /// table jump — the chain the megafunction never paid because it kept
    /// `code` in a register.
    inline fn dispatchTailFrom(comptime mode: ExecMode, st: *ExecState, pc: usize, iptr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
        const self = vm;
        // (1) GC safepoint — every live value is rooted here, the
        // collection is non-moving, and it is suppressed while a
        // multret result set is pending.
        //
        // Hot-path shape (doc 42 §4.2 amendment): the `.fast` prologue must
        // stay CALL-FREE — a callable site anywhere in a handler forces
        // callee-saved spills (push/pop ×5, measured) on EVERY hop, even when
        // the call never runs, because LLVM's shrink-wrapping cannot sink
        // them past the tail jump. The two calls this prologue can make —
        // `collect` here and the region observer's slow path in step (5) —
        // are outlined as handler-shaped trampolines the dispatch musttails
        // INTO; each does its call and re-enters the remaining prologue, so
        // the §4.2 step order is preserved exactly and the hot handlers stay
        // frameless.
        if (!self.reg_top_pending and self.heap.shouldCollect())
            return @call(.always_tail, gcTrampoline(mode), .{ st, pc, iptr, vm, tags, payloads });
        return dispatchPostGc(mode, st, pc, iptr, vm, tags, payloads);
    }

    /// Cold half of prologue step (1): run the collection, then re-enter the
    /// prologue at step (2). Handler-shaped so the hot path can musttail here
    /// instead of calling — see the shape note in `dispatchTail`.
    fn gcTrampoline(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                // `.cold` (not `noinline` — that would change the fn TYPE and
                // break the musttail type match) is what actually keeps this
                // outlined: without it LLVM inlines the trampoline back into
                // every handler and the spills return.
                @branchHint(.cold);
                // `instr` carries the fetch pointer (`&st.code[pc]`) through
                // the trampoline. It survives `collect()`: the collector is
                // non-moving and never swaps the cached code image.
                // Doc 61 §4.1: publish the innermost frame's true next pc
                // before collecting (step 6 would store the same value just
                // after), so the collector reads `frame.pc` for every frame.
                st.frame.pc = pc;
                vm.collect();
                return dispatchPostGc(mode, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    /// Prologue steps (2)–(5 hot half); step (5)'s slow observer call exits
    /// via `regionTrampoline`.
    inline fn dispatchPostGc(comptime mode: ExecMode, st: *ExecState, pc: usize, iptr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
        const self = vm;
        // (2) Free-running safepoint counter — must advance every
        // instruction in both modes so replay cuts land identically
        // (keyframeser reads it as the total).
        self.safepoint_seq += 1;

        // (3) Replay line-index recorder — `.full` only (compiled out
        // in `.fast`). A failed append parks-and-returns leaving
        // exactly the old partial state: `safepoint_seq` already
        // incremented, nothing after this step run (§4.2).
        if (mode == .full and self.record_safepoint_lines) {
            const proto = st.proto;
            const sp_line: u32 = if (pc < proto.spans.len) proto.spans[pc].line else 0;
            const limit: usize = if (self.suspend_ctl) |sc| sc.index_limit else std.math.maxInt(usize);
            if (self.safepoint_lines.items.len < limit) {
                self.safepoint_lines.append(self.gpa, .{
                    .proto_id = proto.id,
                    .line = sp_line,
                    .stoppable = self.canSuspendHere(),
                }) catch |e| return parkErr(st, e);
            }
        }

        // (4) Mid-execution suspend point — an instruction boundary,
        // BEFORE the fetch and all recording hooks. `.full` only.
        // Doc 68 §8, defer: while a native runs code through a Zig re-entry
        // (`callValue`, `runPushedFrame`), that Zig frame could not be
        // resumed, so a due suspend waits for the first boundary after the
        // re-entry returns. This is what makes the nested `.suspended`
        // arms unreachable.
        if (mode == .full) {
            if (self.suspend_ctl) |sc| {
                const effect_cut_reached = if (sc.after_committed_effects) |n|
                    self.committed_effect_seq >= n
                else
                    true;
                if (self.canSuspendHere() and effect_cut_reached and
                    self.safepoint_seq >= sc.after_safepoints and self.depth >= sc.min_depth)
                {
                    std.debug.assert(self.pending_error == null);
                    st.frame.pc = pc;
                    return .suspended;
                }
            }
        }

        // (5) A-iv logical-region departure observer. The empty-map
        // common path does not call into the observer and cannot
        // allocate; activation context is refreshed only on frame
        // reload (`execImpl`/push/pop), not per instruction. The
        // empty-map test stays FIRST and stays the only unconditional
        // work: probing the hot cache ahead of it would touch a second
        // `TraceState` line on every instruction of every region-free
        // program, which measured +11% on scimark-sor tier-0.
        //
        // The WHOLE probe — `observeFast` inline verdict included —
        // lives behind the trampoline: inlined here, its bit-test
        // machinery needs enough temporaries that LLVM allocates
        // callee-saved registers (push/pop ×3, measured on the
        // widened ABI) in EVERY fast handler, taxing every hop of
        // every region-free program for state only region profiling
        // touches. Behind the musttail the hot prologue keeps only
        // this one counter test, and a regions-live program pays one
        // extra tail jump per instruction — still call-frame-free
        // (A-vii-e.2's point), just one hop farther out of line.
        if (self.trace.regionProfitCount() != 0)
            return @call(.always_tail, regionTrampoline(mode), .{ st, pc, iptr, vm, tags, payloads });
        return dispatchPostObserve(mode, st, pc, iptr, vm, tags, payloads);
    }

    /// Out-of-line prologue step (5) for regions-live programs: the
    /// A-vii-e.2 inline verdict, falling through to the real observer only
    /// when the hot cache cannot answer, then re-enter the prologue at
    /// step (6).
    fn regionTrampoline(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                @branchHint(.cold); // keep outlined — see gcTrampoline's note
                // `instr` carries the fetch pointer, as in `gcTrampoline`.
                if (!vm.trace.observeFast(st.proto.id, @intCast(pc), vm.depth, st.frame.call_seq))
                    vm.trace.observeRegionProgramPoint(st.proto.id, @intCast(pc), vm.depth, st.frame.call_seq);
                return dispatchPostObserve(mode, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    /// Prologue steps (6)–(11) + the table jump into the next handler.
    inline fn dispatchPostObserve(comptime mode: ExecMode, st: *ExecState, pc: usize, iptr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
        const self = vm;
        const cur = pc;
        // (6) Keep the faulting location recoverable (see the old
        // loop's note): `frame.pc` points at the instruction about to
        // execute.
        st.frame.pc = cur;
        // (7) Fetch. The handler receives `cur + 1` as its `pc` (one
        // past itself — `cur_pc` is derivable as `pc - 1`).
        const i = iptr.*;
        // Doc 63 §5.9: while the JIT is suspended, steps (8)–(11) neither
        // close, start nor feed a recording, and leave every pending anchor
        // for the code that set it.
        const jit_live = mode == .full and !self.jitSuspended(mode);

        // (8) A recording is one CFG cycle, not necessarily one
        // syntactic back-edge. Close before mirroring when forward
        // flow re-enters its anchor (nested loops can do this after an
        // enclosing back-edge). The ordinary matching back-edge
        // already closed in `onBackEdge`, making this a cheap no-op.
        if (jit_live and self.trace.isRecording())
            self.trace.maybeCloseAtAnchor(st.proto, @intCast(cur), st.regs);
        // (9) Nested-loop continuation (Phase 1): a continuation
        // recording armed by a hot inner loop-done exit, or (doc 56) by
        // a wanted exit-side exit materialized at its resume pc, begins
        // at its (non-header) anchor pc, which tier-0 reaches here — *before*
        // the mirror below, so the anchor instruction is recorded as
        // the trace's first op (exactly as a root trace's anchor is).
        // A cheap optional-null read when nothing is pending.
        if (jit_live and self.trace.pending_exit_anchor != null) {
            self.trace.maybeStartContinuation(st.proto, @intCast(cur));
        }
        // (10) Coherent-state chaining (doc 16, Phase 2): a prime
        // side-trace armed on a productive branch-guard exit begins at
        // the failed trace's own coherent anchor (the outer header),
        // which tier-0 reaches here with registers already coherent —
        // no deopt-replay needed. Same `.full`-only, before-the-mirror
        // placement so the anchor instruction is the recording's
        // first op.
        if (jit_live and self.trace.pending_replay_anchor != null) {
            self.trace.maybeStartReplaySide(st.proto, @intCast(cur));
        }
        // (10b) Function-head anchor (doc 44 P0): a hot call flagged in
        // `opCall` arms a `.head` recording the moment the prologue reaches
        // the callee's pc 0. Same `.full`-only, before-the-mirror placement
        // as (9)/(10) so pc 0's instruction is the recording's first op.
        // `maybeStartHead` consumes-or-discards the pending unconditionally
        // (`call_seq`-pinned), so a stale pending self-cleans right here.
        if (jit_live and self.trace.pending_call_anchor != null) {
            _ = self.trace.maybeStartHead(st.proto, @intCast(cur), st.base, st.frame.call_seq);
        }
        // (10c) Continuation anchor (doc 44 D12b): a hot post-call resume pc
        // flagged in `opRet` arms a `.cont` recording the moment the prologue
        // reaches the caller's frozen cursor. Same `.full`-only,
        // before-the-mirror placement and consume-or-discard self-cleaning
        // as (10b).
        if (jit_live and self.trace.pending_ret_anchor != null) {
            _ = self.trace.maybeStartCont(st.proto, @intCast(cur), st.base, st.frame.call_seq);
        }
        // (11) Recording mirror — `.full` only. Mirrors this
        // instruction (and its observed operand types) into the trace
        // IR *before* tier-0 executes it.
        if (jit_live and self.trace.isRecording()) {
            // Doc 20 §R1-3: the mirror always records the CANONICAL
            // instruction. `i` came from the fetch `code` slice, which
            // may be a patched image — a recording crossing a patched
            // pc (a sibling loop of the one being recorded) must see
            // the virgin back-edge (`.for_loop`, `.tfor_loop`, or — doc
            // 58 — the `.loop` marker) and virgin shape checks,
            // byte-identical with or without the patch. `proto.code` is
            // canonical by construction (§R1).
            const mi = recordingMirrorInstr(st.proto, cur, i);
            const resolved: Value = switch (mi.op) {
                .get_upval => self.upvalGet(st.closure.upvalues[mi.b]),
                .get_global => self.globals.get(st.proto.constants[mi.b]),
                else => Value.nil(),
            };
            // Doc 43 §3.1 (P0a): supply an OPEN get_upval cell's backing slab
            // index so the recorder can reject a snapshot that aliases the
            // trace-writable window. Closed cells and non-upvalue ops → null.
            self.trace.rec_upval_open = switch (mi.op) {
                .get_upval => switch (st.closure.upvalues[mi.b].loc) {
                    .open => |idx| idx,
                    .closed => null,
                },
                else => null,
            };
            // Doc 43 P5: supply the resolved `*Upvalue` cell for both upvalue
            // ops — `st.closure` is the EXECUTING frame's closure, so this is
            // correct at any inline depth the recorder mirrors. The recorder
            // keys closed-cell alias classes on the cell's address.
            self.trace.rec_upval_cell = switch (mi.op) {
                .get_upval, .set_upval => st.closure.upvalues[mi.b],
                else => null,
            };
            // Refresh the recorder's read-only heap channel (doc 23
            // D2) — the same supply-per-call pattern as `resolved`, so
            // the recorder never holds a `*Heap` it wasn't just handed
            // by its driver.
            self.trace.rec_heap = self.heap;
            self.trace.recordInstr(mi, st.regs, st.proto, @intCast(cur + 1), resolved);
        }
        // The instruction rides as a POINTER into the fetch image (or
        // `patch.orig`), not by value: a by-value 12-byte `Instr`
        // lowers to a byval STACK argument on wasm32, and wasm tail
        // calls reject stack arguments outright ("does not support
        // tail calling with stack arguments") — found by the T-7 wasm
        // build, doc 42 §4.1 amendment. `*const Instr` is
        // register-sized on every target; the pointee is the code
        // image element just fetched (same hot cache line).
        return @call(.always_tail, handlerTable(mode)[@intFromEnum(i.op)], .{ st, cur + 1, iptr, vm, tags, payloads });
    }

    /// Doc 42 §4.1: the ORDINARY (non-musttail) entry into the handler chain.
    /// A real `noinline` function with the uniform handler signature: its own
    /// frame is the disposable one the first musttail hop replaces, while
    /// `execImpl`'s frame — which owns the `ExecState` — sits safely beneath,
    /// reached only by the chain's single final `ret`.
    fn chainEntry(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            // Plain fn, NOT `noinline`: in this toolchain `noinline` is part
            // of the function TYPE, and a musttail caller's type must match
            // its callee's exactly — a noinline entry cannot tail-call the
            // plain handlers. The no-inline property lives at `execImpl`'s
            // call site (`@call(.never_inline, …)`) instead.
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                _ = instr; // uniform signature; nothing has executed yet
                _ = tags; // general dispatch re-derives lanes from st.regs
                _ = payloads;
                return dispatchTail(mode, st, pc, vm);
            }
        }.h;
    }

    /// What the extracted back-edge epilogue tells its trampoline to do.
    /// `dispatch_at` = the old `continue :outer` (pc possibly advanced by a
    /// chain resume): tail-dispatch at that pc with a full prologue,
    /// re-resolving NOTHING. `switch_mode_at` = park pc and flip the dispatch
    /// mode (the old `frame.pc = npc; return .switch_mode`).
    /// Doc 45 D5: the raise payload both directive unions share — a precise
    /// trace's effect error and the bytecode pc to park it at.
    const RaiseAt = struct { pc: usize, err: Error };

    const BackEdgeDirective = union(enum) {
        dispatch_at: usize,
        switch_mode_at: usize,
        /// Doc 45 D5: relay of `EntryDirective.raise_at` — a precise
        /// trace's effect error to park at its bytecode (see that variant).
        raise_at: RaiseAt,
    };

    /// Doc 42 §4.4: the back-edge trampoline. Jump handlers musttail here on a
    /// real loop back-edge (target `pc <= cur_pc` while tracing is enabled),
    /// presenting the CANONICAL instruction (`patch.orig` from the patched
    /// arms); it runs the `noinline` epilogue and acts on the directive. The
    /// `frame.pc` write for a mode switch lives HERE, not in the epilogue —
    /// the epilogue must never write the jump target into `frame.pc` (§4.4
    /// invariant: `frame.pc` stays at the executed back-edge until the next
    /// prologue, except an explicit mode-switch park).
    /// The loop handlers' back-edge entry while tracing is enabled, in front of
    /// `backEdgeHandler`. A loop the JIT has given up on is gated, and its
    /// hot-count slot skips its next back-edges (`afterBackEdge`). Reaching
    /// that test through the out-of-line epilogue cost ~95 instructions per
    /// iteration, on every iteration of every untraceable loop; this handler
    /// makes the test call-free and continues at the anchor exactly as the
    /// epilogue's `.dispatch_at` would. Its own handler rather than inlined
    /// into the loop handlers, so their tracing-off paths keep their code.
    /// `.fast` only: in `.full` the epilogue also decides the switch back to
    /// `.fast`. Coverage runs need the epilogue's per-iteration attribution.
    fn gatedBackEdgeHandler(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                if (mode == .fast and !vm.trace.config.coverage and
                    vm.trace.skipGatedBackEdge(st.proto, @intCast(pc)))
                {
                    return dispatchTail(mode, st, pc, vm);
                }
                return @call(.always_tail, backEdgeHandler(mode), .{ st, pc, instr, vm, tags, payloads });
            }
        }.h;
    }

    fn backEdgeHandler(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                // The epilogue may run traces/drains that move the lanes;
                // dispatchTail re-derives them from `st.regs`.
                _ = tags;
                _ = payloads;
                switch (backEdgeEpilogue(mode, st, pc, instr)) {
                    .dispatch_at => |npc| return dispatchTail(mode, st, npc, vm),
                    .switch_mode_at => |npc| {
                        st.frame.pc = npc;
                        return .switch_mode;
                    },
                    // Doc 45 D5: park the precise effect error at its
                    // bytecode — registers already snapshot-restored.
                    .raise_at => |r| {
                        st.frame.pc = r.pc;
                        return parkErr(st, r.err);
                    },
                }
            }
        }.h;
    }

    /// Phase 0a (doc 20): what the factored entry routine tells its caller's
    /// epilogue to do. `resume_tier0` = the old `continue :outer` (pc possibly
    /// advanced by a chain resume); `switch_mode_at` = park pc and flip the
    /// dispatch mode (the old `frame.pc = pc; return .switch_mode`).
    const EntryDirective = union(enum) {
        next_candidate,
        resume_tier0: usize,
        switch_mode_at: usize,
        /// Doc 44 D11/D12c: the native run moved real VM frames (self-call
        /// pushes, and now return-side pops). The dispatch site must
        /// `reloadTopFrame` and dispatch the NEW top frame at this pc —
        /// `head_terminal` completions resume at the leaf's `term.aux`;
        /// `.ret_pop` completions resume the popped-into CALLER at its frozen
        /// one-past-call cursor; every other disposition (deopt, yielded cut,
        /// prologue-fail, either seed decline) resumes the leaf at pc 0,
        /// where the jfunc_head arm runs the LEAF's own walk. Only the head
        /// patch site can receive it (loop pages never emit either epilogue;
        /// cont pages enter with net 0, so their pops decline in v1).
        resume_frame_motion: usize,
        /// Doc 45 D5: a PRECISE trace's effect shim raised a runtime error
        /// (`.precise_error`). The executor already restored the failing
        /// op's snapshot (pre-instruction registers; the iteration's earlier
        /// heap effects stand). The consumer parks `err` with `frame.pc =
        /// pc` — the bytecode the error belongs to — WITHOUT re-executing
        /// anything (execute-once: for OOM there is no effect to redo and a
        /// tier-0 re-run would be a forbidden retry). Never `pending_error`,
        /// never a mode switch, never a sibling/chain continuation.
        raise_at: RaiseAt,
    };

    /// Same-anchor trial-walk cap (visited/dead arrays; `dead ⊆ visited`).
    const trial_visited_cap = 8;

    /// Walk-owned state the entry routine reads/appends: the visited prefix
    /// (chain exclusion sets) and the widen-eviction dead list. The
    /// `.jfor_loop` arm (doc 20 Phase 1) passes `{ct}` — the chain-exclusion
    /// invariant is `ct ∈ visited` — and an empty dead list.
    const TrialWalkCtx = struct {
        visited: []const *trace.Trace,
        dead: *WalkDead,
    };

    /// The trial walk's widen-eviction dead list (`dead ⊆ visited`, capped
    /// alike). `retire` submits the batch and EMPTIES the list, so the entry
    /// routine's early-return retire and the walk owner's post-walk retire
    /// can never both submit it: `removeTraces` destroys the records, and a
    /// second submission would dereference freed traces (doc 61 Phase Q
    /// review — the old per-trace `removeTrace` searched the cache first, so
    /// a repeat was a silent no-op).
    pub const WalkDead = struct {
        items: [trial_visited_cap]*trace.Trace = undefined,
        len: usize = 0,

        pub fn full(self: *const WalkDead) bool {
            return self.len == self.items.len;
        }

        pub fn add(self: *WalkDead, t: *trace.Trace) void {
            std.debug.assert(!self.full());
            self.items[self.len] = t;
            self.len += 1;
        }

        pub fn retire(self: *WalkDead, ts: *trace.TraceState) void {
            if (self.len == 0) return;
            const batch = self.items[0..self.len];
            self.len = 0;
            ts.removeTraces(batch);
        }
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
    /// Doc 44 D9: the quiet predicate. Returns the compiled page iff NOTHING
    /// that could observe, steer, or account this head episode beyond the
    /// minimal receipt is live — every check is an O(1) load, computed fresh
    /// per entry (no cached flag to drift; the `captureProvenanceVerdicts`
    /// emptiness-over-counter rule). Each line names the machinery it proves
    /// inert; a false anywhere routes to the full `enterSelectedTrace`, so
    /// non-quiet states are byte-identical to before by construction.
    fn headEpisodeQuiet(self: *Vm, ct: *trace.Trace) ?*const nativegen.CompiledTrace {
        const ts = &self.trace;
        // `.compiled` alone ≠ "the config would run it native" (round 3).
        if (!ts.config.native_codegen) return null;
        if (ct.native != .compiled) return null;
        const nt = &ct.native.compiled;
        // The one decline needing the tier-1a rerun machinery.
        if (nt.has_hash_seed) return null;
        const phys = &ts.registry.native_physical;
        // Doc 44 D10 (quiet v2): armed links no longer force the full path —
        // a fused multi-row result routes through `consumeHeadBurst`, which
        // validates every transition against the live registry. This also
        // closes a Z-6 generality gap: v1's global `armedLinks` check made
        // the quiet path dead in any program with armed LOOP links.
        // `applyPendingDisarms`/`drainBarrier`/`syncNativeInvalidation` no-op.
        if (phys.pending_demote.items.len != 0 or phys.pending_teardown != .none) return null;
        if (phys.provenance_invalidated) return null;
        // `applyPendingDisarms` also syncs this field unconditionally; a
        // mismatch takes one full entry to synchronize (round 3).
        if (phys.debug_log != ts.config.debug_log) return null;
        // `prepareNativeEntry` no-op; `silentStaging() == .{}`.
        if (phys.promotedSets().len != 0) return null;
        // Provenance capture/settle/drain and sibling arming no-op.
        if (ts.provenance_edges.items.len != 0) return null;
        if (ts.pending_sibling_arm != null or ts.pending_bridge_arm != null) return null;
        // Frame-link requests are consumed only by the full entry path.
        if (ts.pending_ret_cont_arm != null or ts.pending_call_head_arm != null) return null;
        // `accountRegionProfit` returns false ⇒ legacy receipt.
        if (!ts.region_policy.receiptsInert()) return null;
        // The legacy productive removals no-op on empty maps; head gate READS
        // (want transfer, repatch) stay correct because non-empty forces full.
        if (ts.penalty.count() != 0 or ts.gate.count() != 0) return null;
        // Coverage runs want the tsc stamps (`--jit-stats` attribution).
        if (ts.config.coverage) return null;
        return nt;
    }

    /// Doc 44 D10: consume the walk-local head-handoff evidence at a terminal
    /// completion. If an EARLIER trace in this same `enterPatchedTrace` walk
    /// zero-exited on a real guard deopt and a DIFFERENT trace has now
    /// completed the call, that is one observation of the handoff-profitable
    /// pattern — charge the existing Part-S watch on the failer's exit
    /// (`noteSiblingTerminal`), which arms `.sibling_handoff` at `hotguard`.
    /// Shared by the quiet and full terminal consumers; clears the channel
    /// unconditionally (one observation per walk, by design).
    fn consumeHeadWalkFail(self: *Vm, completed_id: u32) void {
        const ts = &self.trace;
        const fk = ts.head_walk_fail orelse return;
        ts.head_walk_fail = null;
        if (fk.trace_id == completed_id) return;
        const failer = ts.traceById(fk.trace_id) orelse return;
        ts.noteSiblingTerminal(failer, fk.exit_instr);
    }

    /// Doc 44 D10: merge the last burst's entered-owner ids into the head
    /// walk's visited set — a burst owner already ran this activation and must
    /// not be re-selected by `nextTraceExcluding`. Deduped against the ids
    /// already visited; when the buffer fills, remaining ids are dropped and
    /// the walk's own cap branch reports truncation. Clears the scratch so a
    /// non-burst entry later in the walk merges nothing.
    fn mergeHeadBurstVisited(self: *Vm, visited: []*trace.Trace, nvisited: *usize) void {
        const ts = &self.trace;
        outer: for (ts.head_burst_visited[0..ts.head_burst_visited_len]) |vid| {
            if (nvisited.* >= visited.len) break;
            const t = ts.traceById(vid) orelse continue;
            for (visited[0..nvisited.*]) |v| {
                if (v == t) continue :outer;
            }
            visited[nvisited.*] = t;
            nvisited.* += 1;
        }
        ts.head_burst_visited_len = 0;
    }

    /// Doc 44 D10: the fused head-burst consumer. A head entry whose armed
    /// `.sibling_handoff` slot fired returns a multi-row ledger describing the
    /// whole native chain: `[A.deopt…, terminal]` where every intermediate row
    /// is an armed pre-effect branch-guard deopt that dispatched into the next
    /// row's owner, and the terminal row is one of the closed head grammar's
    /// five shapes (`head_terminal` completion, final `.deopt` zero exit,
    /// full-cap `.yielded` cut, `prologue_fail`, `seed_capacity_decline` —
    /// `seed_hash_decline` is excluded at ARM time). MUST run BEFORE the
    /// scalar terminal / head-zero consumers: those read only the terminal
    /// body's scalars and would silently drop the intermediate rows'
    /// accounting (round 4's factual correction — no panic saves us here; the
    /// `replayLedger` `head_terminal` panics are a backstop for ledgers that
    /// leak PAST this consumer, not a substitute for it).
    ///
    /// Ledger-shape violations panic in release too: a malformed burst means
    /// native code jumped somewhere the registry never armed — continuing
    /// would account (and resume) against fiction.
    /// Doc 44 D10/D11: resolve a fused-head-ledger row's owner and validate
    /// that it is a head trace of this anchor. Shared by `consumeHeadBurst`
    /// and the D11 pushed-descent consumer; violations panic in release too —
    /// a malformed ledger means native code jumped somewhere the registry
    /// never armed, and continuing would account (and resume) against fiction.
    /// (D12b round 6 change 4: validation is EXACT-anchor — a proto can now
    /// carry several one-shot anchors, and a row fused under anchor A must
    /// never validate against an entry at anchor B.)
    fn resolveHeadRowOwner(self: *Vm, row_id: u32, proto: *const Proto, anchor_pc: u32) *trace.Trace {
        const ts = &self.trace;
        const owner = ts.traceById(row_id) orelse @panic("head burst: row owner did not resolve");
        if (owner.code.anchor.proto != proto or owner.code.anchor.pc != anchor_pc)
            @panic("head burst: row owner is not a one-shot trace of this exact anchor");
        return owner;
    }

    /// Doc 44 D10/D11: validate + account one INTERMEDIATE fused-head row —
    /// an armed pre-effect branch-guard deopt that dispatched into
    /// `next_owner`, checked against the LIVE registry (adjacency per row).
    /// Entered-and-handed-off accounting: NO zero receipt (a sibling went on
    /// to finish the call) and NO hot-exit charge (the exit is already
    /// armed); the candidate charge resets the refusal streak, which
    /// `accountTraceRun` alone does not (round 4). Shared by
    /// `consumeHeadBurst` and the D11 pushed-descent consumer.
    fn accountHeadIntermediateRow(
        self: *Vm,
        owner: *trace.Trace,
        row: trace_exec.LedgerEntry,
        next_id: u32,
        seg_local: usize,
    ) void {
        const ts = &self.trace;
        if (row.kind != .deopt or row.outcome != .normal)
            @panic("head burst: intermediate row is not a dispatched deopt");
        const next_owner = ts.traceById(next_id) orelse
            @panic("head burst: successor owner did not resolve");
        if (!ts.hasArmedSiblingHandoff(owner, row.exit, next_owner))
            @panic("head burst: transition has no armed sibling handoff");
        ts.accountTraceRun(owner, seg_local);
        trace.TraceState.accountCandidateCharge(owner, .entered);
    }

    fn consumeHeadBurst(
        self: *Vm,
        ct: *trace.Trace,
        ledger: []const trace_exec.LedgerEntry,
        proto: *const Proto,
    ) EntryDirective {
        const ts = &self.trace;
        std.debug.assert(ledger.len > 1);
        if (ledger[0].id != ct.id) @panic("head burst: row 0 owner is not the entered trace");
        // Publish every entered owner for the walk's visited merge (deduped;
        // overflow stops recording — the walk's cap branch owns truncation).
        ts.head_burst_visited_len = 0;
        var i: usize = 0;
        while (i < ledger.len) : (i += 1) {
            const row = ledger[i];
            const owner = self.resolveHeadRowOwner(row.id, proto, ct.code.anchor.pc);
            if (dedup: {
                for (ts.head_burst_visited[0..ts.head_burst_visited_len]) |vid| {
                    if (vid == owner.id) break :dedup false;
                }
                break :dedup ts.head_burst_visited_len < ts.head_burst_visited.len;
            }) {
                ts.head_burst_visited[ts.head_burst_visited_len] = owner.id;
                ts.head_burst_visited_len += 1;
            }
            // Heads never increment `rbx` (no `.loop` terminal), but read the
            // segment local off the cumulative column anyway — the accounting
            // stays correct if a future head shape ever commits iterations.
            const seg_local: usize = row.cum - (if (i == 0) 0 else ledger[i - 1].cum);
            if (i != ledger.len - 1) {
                // INTERMEDIATE row: an armed dispatch, validated against the
                // live registry (adjacency per row — round 4; shared core).
                self.accountHeadIntermediateRow(owner, row, ledger[i + 1].id, seg_local);
                continue;
            }
            // TERMINAL row.
            switch (row.kind) {
                .head_terminal => {
                    if (row.outcome != .normal) @panic("head burst: yielded head_terminal");
                    if (row.exit >= owner.code.instrs.len or owner.code.instrs[row.exit].op != .terminal)
                        @panic("head burst: head_terminal row does not name a terminal instr");
                    const term = owner.code.instrs[row.exit];
                    ts.dbg("head-burst terminal: rows={d} final t={d} resume={d}", .{ ledger.len, owner.id, term.aux });
                    // Verbatim the scalar terminal consumer's receipt: one
                    // completed head run, productive (clears penalty/gate).
                    ts.onSideExitReceipt(owner, 1, row.exit, 1, .deferred, .entered);
                    ts.noteHeadSiblingCompletion(.{ .proto = owner.code.anchor.proto, .pc = owner.code.anchor.pc, .proto_id = owner.code.anchor.proto_id }, owner.id);
                    self.consumeHeadWalkFail(owner.id);
                    return .{ .resume_tier0 = @intCast(term.aux) };
                },
                .deopt => {
                    if (row.outcome == .yielded) {
                        // Full-cap forced yield: the chain was CUT, not
                        // failed — regs are entry-coherent (pre-effect
                        // guards only), so fall back to the walk. No
                        // hot-exit charge and no handoff evidence (the
                        // last exit is armed and live); the zero receipt
                        // keeps the thrash gate able to retire a
                        // pathological ping-pong pair.
                        if (ledger.len != trace_exec.LEDGER_CAP)
                            @panic("head burst: yielded row below full cap");
                        ts.dbg("head-burst yield: rows={d} last t={d} exit={d}", .{ ledger.len, owner.id, row.exit });
                        ts.onSideExitReceipt(owner, seg_local, row.exit, seg_local, .deferred, .entered);
                        return .next_candidate;
                    }
                    // Real zero exit of the LAST owner — verbatim the scalar
                    // head zero-exit consumer, including the walk-local
                    // handoff evidence (a later completer may extend the
                    // chain by arming THIS exit).
                    ts.dbg("head zero-exit: trace={d} native={} reason={s} exit={d} completed={d}", .{ owner.id, true, @tagName(row.reason), row.exit, row.cum });
                    if (row.exit != std.math.maxInt(u32))
                        ts.head_walk_fail = .{ .trace_id = owner.id, .exit_instr = row.exit };
                    ts.noteTakenExit(owner, row.exit, seg_local, .legacy);
                    ts.onSideExitReceipt(owner, seg_local, row.exit, seg_local, .deferred, .entered);
                    return .next_candidate;
                },
                .prologue_fail => {
                    // A fused successor's hoisted entry-type guard failed:
                    // scalar semantics (`exit == maxInt` bounds-refuses the
                    // hot-exit charge inside), `.entry_refusal` charge kind.
                    ts.dbg("head zero-exit: trace={d} native={} reason={s} exit={d} completed={d}", .{ owner.id, true, @tagName(row.reason), row.exit, row.cum });
                    ts.noteTakenExit(owner, row.exit, seg_local, .legacy);
                    ts.onSideExitReceipt(owner, seg_local, row.exit, seg_local, .deferred, .entry_refusal);
                    return .next_candidate;
                },
                .seed_capacity_decline => {
                    // Verbatim scalar decline semantics: no receipt, no
                    // strike — an entry-condition mismatch, not a failure.
                    ts.dbg("seed-capacity-decline: trace={d} anchor={d}", .{ owner.id, owner.code.anchor.pc });
                    ts.seed_capacity_declines +|= 1;
                    return .next_candidate;
                },
                else => @panic("head burst: terminal row kind outside the head grammar"),
            }
        }
        unreachable;
    }

    /// Doc 44 D11: the pushed-descent consumer — a SIBLING of
    /// `consumeHeadBurst` sharing the factored row-validation/accounting core
    /// but NONE of the walk-local state: no `head_burst_visited` publication
    /// and no `.next_candidate` — every disposition converts directly to
    /// `.resume_frame_motion` (the top frame is now the descent's leaf; the
    /// entry activation's walk cannot continue against it). D12a amended the
    /// original "no `head_walk_fail` pairing" rule with the two ACTIVATION-
    /// CORRECT evidence flows: the A1 funnel pairs a standing walk failer
    /// with the ENTERED trace (the descent handled the entry activation's
    /// call), and the A2 carry hands the final deopt — which happened in the
    /// LEAF activation — to the leaf's own walk, `call_seq`-pinned. Rows in
    /// between still cross activations and still pair nothing. The terminal
    /// grammar is SIX-way — the post-push `ordinary_entry` re-runs both the
    /// seed and hoisted-type prologues, so both seed declines can surface
    /// mid-descent; `seed_hash_decline` must NOT take the scalar tier-1a
    /// rerun (it would execute against the ENTRY activation's base/closure) —
    /// the reloaded leaf's own jfunc_head walk makes the rerun/downgrade
    /// decision (round 5 change 3). Non-terminal leaf dispositions charge
    /// NOTHING here: the leaf resumes at pc 0 where its own walk re-runs the
    /// entry and charges penalty / D8 wants / D10 evidence per-activation
    /// exactly as scalar entries do.
    fn consumePushedDescent(
        self: *Vm,
        ct: *trace.Trace,
        result: trace_exec.ExecResult,
        proto: *const Proto,
    ) EntryDirective {
        const ts = &self.trace;
        std.debug.assert(result.pushed_frames > 0);
        // D12c: the pop sequence's net floor makes popped-without-pushed
        // structurally impossible; a violation means the emitted preflight
        // computed net from the wrong counters.
        std.debug.assert(result.popped_frames <= result.pushed_frames);
        // The push sequence declines while region receipts are live (the
        // `descent_ok` gate), and heads never enter promoted silent cycles —
        // a silent descent result means native ran a shape the registry
        // never armed.
        if (result.silent_active != 0) @panic("pushed descent: silent result");
        if (result.ledger_len == 0) @panic("pushed descent: empty ledger");
        // Doc 54 P2: a row-free episode has NO positional grammar — zero
        // intermediate rows, and a final row owned by the exiting page
        // rather than the entered trace. Its accounting comes from the
        // touched-slot drain instead.
        if (result.frame_motion_taken) return self.consumeMotionTotals(ct, result, proto);
        const ledger = ts.ledger_scratch[0..result.ledger_len];
        if (ledger[0].id != ct.id) @panic("pushed descent: row 0 owner is not the entered trace");
        // Doc 44 D12a (A1): ONE evidence funnel per consumed descent, keyed on
        // the ENTERED trace — never the final row's owner (an armed handoff
        // diverges them, and `noteHeadSiblingCompletion` deliberately keeps a
        // want alive when the completer equals its source). A descent that
        // pushed real frames handled the entry activation's call productively:
        // pair a standing walk failer with it (`noteSiblingTerminal(failer)`
        // — arming failer@exit → this trace at `hotguard`), and retire a
        // standing head want exactly as a terminal completion does (without
        // this, the want lingers under descents and re-records duplicate
        // shapes to the population cap). Runs exactly once, disposition-
        // independent; the genuine `head_terminal` receipt stays separate.
        self.consumeHeadWalkFail(ct.id);
        ts.noteHeadSiblingCompletion(.{ .proto = ct.code.anchor.proto, .pc = ct.code.anchor.pc, .proto_id = ct.code.anchor.proto_id }, ct.id);
        var i: usize = 0;
        while (i < ledger.len) : (i += 1) {
            const row = ledger[i];
            const owner = ts.traceById(row.id) orelse @panic("pushed descent: row owner did not resolve");
            if (owner.code.anchor.proto != proto) @panic("pushed descent: row owner proto mismatch");
            if (trace.anchorKind(owner.code.anchor.pc) == .loop)
                @panic("pushed descent: loop owner in one-shot ledger");
            if (row.outcome == .yielded) {
                if (i != ledger.len - 1 or ledger.len != trace_exec.LEDGER_CAP)
                    @panic("pushed descent: yield must end a full ledger");
                ts.frame_link_cap_yields +|= 1;
            }
            const seg_local: usize = row.cum - (if (i == 0) 0 else ledger[i - 1].cum);
            if (i != ledger.len - 1) {
                const next_owner = ts.traceById(ledger[i + 1].id) orelse @panic("pushed descent: successor did not resolve");
                switch (row.kind) {
                    .ret_pop => {
                        if (!ts.hasArmedFrameLink(owner, trace.entryPc(next_owner.code.anchor.pc), next_owner, .ret_cont))
                            @panic("pushed descent: ret_pop without live ret_cont");
                        ts.ret_cont_link_hits +|= 1;
                        ts.accountTraceRun(owner, seg_local);
                        trace.TraceState.accountCandidateCharge(owner, .entered);
                    },
                    .call_push => {
                        if (!ts.hasArmedFrameLink(owner, row.exit, next_owner, .call_head))
                            @panic("pushed descent: call_push without live call_head");
                        ts.call_head_link_hits +|= 1;
                        ts.accountTraceRun(owner, seg_local);
                        trace.TraceState.accountCandidateCharge(owner, .entered);
                    },
                    else => self.accountHeadIntermediateRow(owner, row, ledger[i + 1].id, seg_local),
                }
                continue;
            }
            // TERMINAL row.
            return self.consumeDescentTerminalRow(owner, row, result, ledger.len);
        }
        unreachable;
    }

    /// Doc 44 D11 / doc 54 P2: the shared TERMINAL-row disposition of a
    /// pushed-descent episode — factored out of `consumePushedDescent`'s
    /// positional walk so the row-free totals path (`consumeMotionTotals`)
    /// dispatches the identical six-way grammar on its single final row.
    /// `ledger_len` is the consumed ledger's length (always 1 on the totals
    /// path, where the full-cap `.yielded` shapes are structurally
    /// impossible and the caller has already rejected them).
    fn consumeDescentTerminalRow(
        self: *Vm,
        owner: *trace.Trace,
        row: trace_exec.LedgerEntry,
        result: trace_exec.ExecResult,
        ledger_len: usize,
    ) EntryDirective {
        const ts = &self.trace;
        switch (row.kind) {
                .head_terminal => {
                    // The descent's LAST activation refused a further push
                    // (depth/capacity wall, rebound callee, …) and ran the
                    // plain terminal: a genuine completion of that
                    // activation's body. Verbatim the scalar terminal
                    // receipt; the reloaded leaf resumes AT the unexecuted
                    // self-call, which tier-0 re-executes generically
                    // (raising any overflow error with intact frames).
                    if (row.outcome != .normal) @panic("pushed descent: yielded head_terminal");
                    if (row.exit >= owner.code.instrs.len or owner.code.instrs[row.exit].op != .terminal)
                        @panic("pushed descent: head_terminal row does not name a terminal instr");
                    const term = owner.code.instrs[row.exit];
                    ts.dbg("pushed-descent terminal: pushed={d} rows={d} final t={d} resume={d}", .{ result.pushed_frames, ledger_len, owner.id, term.aux });
                    ts.onSideExitReceipt(owner, 1, row.exit, 1, .deferred, .entered);
                    // D12a: want retirement moved to the single funnel above
                    // (keyed on the ENTERED trace, round-6 change 5 — a second
                    // call here would double-fire with a different id).
                    return .{ .resume_frame_motion = @intCast(term.aux) };
                },
                .call_push => {
                    // A cont page committed a real push but its call-head slot
                    // missed (or the cap forced a cut before the jump). The new
                    // top frame is the callee at pc 0. Record the deterministic
                    // arm request only here, after observing the actual push;
                    // the next selected head page supplies the child.
                    if (row.outcome == .yielded and ledger_len != trace_exec.LEDGER_CAP)
                        @panic("pushed descent: yielded call_push below full cap");
                    if (row.exit >= owner.code.instrs.len or owner.code.instrs[row.exit].op != .terminal)
                        @panic("pushed descent: final call_push does not name a terminal instr");
                    if (trace.anchorKind(owner.code.anchor.pc) != .cont)
                        @panic("pushed descent: final call_push owner is not cont");
                    ts.onSideExitReceipt(owner, 1, row.exit, 1, .deferred, .entered);
                    // A cap cut followed an already armed slot, not a miss.
                    // B1' (task 27 / codex 01a08f8d): the per-owner watch keeps
                    // accumulating even while the single pending slot is
                    // occupied — an owner that independently re-crosses
                    // `hotguard` DISPLACES a stale request under a different
                    // key. Without this, one unsatisfiable request (e.g. a
                    // precise-declined head anchor that can never supply the
                    // child) starves every other proto's frame links forever.
                    if (row.outcome == .normal) {
                        owner.call_head_watch_count +|= 1;
                        if (owner.call_head_watch_count >= ts.config.hotguard) {
                            owner.call_head_watch_count = 0;
                            const req: trace.ExitKey = .{ .trace_id = owner.id, .exit_instr = row.exit };
                            if (ts.pending_call_head_arm) |cur| {
                                if (cur.trace_id != req.trace_id or cur.exit_instr != req.exit_instr) {
                                    ts.setPendingCallHeadArm(req);
                                    ts.dbg("call-head arm request DISPLACED: old t={d} ei={d} -> parent t={d} anchor={d} exit={d}", .{ cur.trace_id, cur.exit_instr, owner.id, owner.code.anchor.pc, row.exit });
                                }
                                // Same key re-crossing: request already filed.
                            } else {
                                ts.setPendingCallHeadArm(req);
                                ts.dbg("call-head arm request: parent t={d} anchor={d} exit={d}", .{ owner.id, owner.code.anchor.pc, row.exit });
                            }
                        }
                    }
                    return .{ .resume_frame_motion = 0 };
                },
                .ret_pop => {
                    // Doc 44 D12c: the final activation COMMITTED a native
                    // frame pop (`return_interp` terminal, inline pop) — the top
                    // frame is the popped-into CALLER and its `pc` is the
                    // frozen one-past-call cursor the push wrote. Resume
                    // there: that pc may hold a `jcont` patch, making the
                    // continuation the very next episode (`.ret_cont` links
                    // will later take this hop without leaving native). A
                    // DECLINED final pop appends `head_terminal` instead and
                    // takes the arm above (leaf re-executes its `ret`).
                    if (row.outcome == .yielded and ledger_len != trace_exec.LEDGER_CAP)
                        @panic("pushed descent: yielded ret_pop below full cap");
                    if (result.popped_frames == 0) @panic("pushed descent: ret_pop row without pops");
                    if (row.exit >= owner.code.instrs.len or owner.code.instrs[row.exit].op != .terminal)
                        @panic("pushed descent: ret_pop row does not name a terminal instr");
                    ts.dbg("pushed-descent ret-pop: pushed={d} popped={d} rows={d} final t={d} resume={d}", .{ result.pushed_frames, result.popped_frames, ledger_len, owner.id, self.frames[self.depth - 1].pc });
                    ts.onSideExitReceipt(owner, 1, row.exit, 1, .deferred, .entered);
                    const resume_pc: u32 = @intCast(self.frames[self.depth - 1].pc);
                    ts.noteRetContTransition(owner, resume_pc);
                    return .{ .resume_frame_motion = resume_pc };
                },
                .deopt => {
                    // Guard deopt at some depth (normal), or a full-cap
                    // `.yielded` cut: either way the deopt flush left the
                    // LEAF window coherent at pc 0 and the leaf's own walk
                    // owns the event's accounting on re-entry — charging it
                    // here too would double-count one semantic failure.
                    if (row.outcome == .yielded and ledger_len != trace_exec.LEDGER_CAP)
                        @panic("pushed descent: yielded row below full cap");
                    // Doc 44 D12a (A2): the final real-guard deopt happened IN
                    // the leaf activation — carry it as walk-local failer
                    // evidence for the leaf's own upcoming walk, pinned to the
                    // leaf frame's `call_seq` (consume-or-discard at the walk
                    // start). Never for `.yielded` (a CUT, not a failure —
                    // the last exit is armed and live, the D10 rationale) and
                    // only for a real guard exit (the scalar provenance bar).
                    if (row.outcome == .normal and row.exit != std.math.maxInt(u32)) {
                        ts.pending_descent_fail = .{
                            .exit = .{ .trace_id = owner.id, .exit_instr = row.exit },
                            .call_seq = self.frames[self.depth - 1].call_seq,
                        };
                    }
                    ts.dbg("pushed-descent deopt: pushed={d} rows={d} last t={d} exit={d} yielded={}", .{ result.pushed_frames, ledger_len, owner.id, row.exit, row.outcome == .yielded });
                    return .{ .resume_frame_motion = trace.entryPc(owner.code.anchor.pc) };
                },
                .prologue_fail => {
                    // Arg types changed at some depth: the post-push re-entry
                    // refused before touching regs. Leaf walk owns it.
                    ts.dbg("pushed-descent prologue-fail: pushed={d} rows={d} last t={d}", .{ result.pushed_frames, ledger_len, owner.id });
                    return .{ .resume_frame_motion = trace.entryPc(owner.code.anchor.pc) };
                },
                .seed_capacity_decline, .seed_hash_decline => {
                    // The post-push seed prologue declined. Both resume the
                    // leaf at pc 0 — the hash decline explicitly must not
                    // take the entry activation's scalar tier-1a rerun.
                    ts.dbg("pushed-descent seed-decline: pushed={d} rows={d} last t={d} kind={s}", .{ result.pushed_frames, ledger_len, owner.id, @tagName(row.kind) });
                    return .{ .resume_frame_motion = trace.entryPc(owner.code.anchor.pc) };
                },
                else => @panic("pushed descent: terminal row kind outside the head grammar"),
            }
    }

    /// Doc 54 P2: the row-free frame-motion consumer — the totals path of
    /// `consumePushedDescent`. A row-free episode's ledger is always
    /// empty-plus-final: zero intermediate rows (armed cross-page frame
    /// hops were taken row-free while the ledger was empty; P2-amendment
    /// rowless SIBLING hops — gate-approved one-shot→one-shot
    /// `.sibling_handoff` follows, at most one per committed motion —
    /// likewise; every other armed non-frame arm refused), and one final
    /// row whose owner is the page performing the final exit — NOT the
    /// entered trace. Entry
    /// identity for the A1 funnel is therefore the dispatcher's own `ct`
    /// (round-2 should-fix 6), and per-transition accounting comes from the
    /// bounded touched-slot drain instead of positional rows.
    fn consumeMotionTotals(
        self: *Vm,
        ct: *trace.Trace,
        result: trace_exec.ExecResult,
        proto: *const Proto,
    ) EntryDirective {
        const ts = &self.trace;
        if (result.ledger_len != 1) @panic("motion totals: ledger must be empty-plus-final");
        // Zero-work invariant (normative): one-shot frame pages never
        // advance the rbx iteration counter, and a row-free episode can
        // only ever run head/cont pages, so it commits zero back-edges.
        // Drained transition counts are transition counts — never
        // reinterpreted as completed iterations (`completed >= min_useful`
        // feeds steering, so conflating them would corrupt qualification).
        if (result.completed != 0) @panic("motion totals: nonzero iteration work in a frame-motion episode");
        const row = ts.ledger_scratch[0];
        const owner = ts.traceById(row.id) orelse @panic("motion totals: final row owner did not resolve");
        if (owner.code.anchor.proto != proto) @panic("motion totals: final row owner proto mismatch");
        if (trace.anchorKind(owner.code.anchor.pc) == .loop)
            @panic("motion totals: loop owner in a frame-motion episode");
        // A row-free episode's ledger holds at most this one row, so the
        // forced-yield cap can never have fired; the motion-refusal
        // redirect deliberately leaves outcome `.normal`.
        if (row.outcome != .normal) @panic("motion totals: yielded final row in a row-free episode");
        // Doc 44 D12a (A1) — verbatim the rows path's single evidence
        // funnel, keyed on the ENTERED trace.
        self.consumeHeadWalkFail(ct.id);
        ts.noteHeadSiblingCompletion(.{ .proto = ct.code.anchor.proto, .pc = ct.code.anchor.pc, .proto_id = ct.code.anchor.proto_id }, ct.id);
        // Bounded drain: walk the records this episode's row-free hits
        // published — O(distinct slots touched), ≤ `TOUCHED_CAP`, never a
        // registry scan (Rule #20). Per record, the drained count feeds the
        // link-hit diagnostics; per distinct OWNER (deduped below),
        // `accountTraceRun(owner, 0)` — zero work, the invariant asserted
        // above — and `accountCandidateCharge(.entered)` once, preserving
        // the rows path's one-shot intermediate semantics.
        const ctx = ts.registry.native_seed_ctx orelse @panic("motion totals: no seed ctx");
        std.debug.assert(ctx.touched_len >= 1 and ctx.touched_len <= trace.TOUCHED_CAP);
        const touched = ctx.touched[0..ctx.touched_len];
        for (touched, 0..) |addr, ti| {
            const rec: *const nativegen.LinkHitCounter = @ptrFromInt(addr);
            std.debug.assert(rec.gen == ctx.episode_gen);
            std.debug.assert(rec.count > 0);
            switch (@as(nativegen.LinkHitKind, @enumFromInt(rec.kind))) {
                .ret_cont => ts.ret_cont_link_hits +|= rec.count,
                .call_head => ts.call_head_link_hits +|= rec.count,
                // Doc 56 Phase 5: exit-side cells are never followed
                // rowlessly, so their records are never published.
                .exit_side => @panic("motion totals: exit-side record published"),
                .sibling_handoff => {
                    // P2 amendment: rowless sibling records validate STRONGLY
                    // against the registry (immutable between episode start
                    // and this drain — no arm/disarm can run while native
                    // code executes). The record must be an ORDINARY cell of
                    // a compiled ONE-SHOT owner's counter array; anything
                    // else means a stray publication and is a bug.
                    const rec_owner = ts.traceById(rec.owner_id) orelse
                        @panic("motion totals: sibling record owner did not resolve");
                    if (trace.anchorKind(rec_owner.code.anchor.pc) == .loop)
                        @panic("motion totals: sibling record on a loop-page owner");
                    const oc = switch (rec_owner.native) {
                        .compiled => |*cc| cc,
                        else => @panic("motion totals: sibling record owner not compiled"),
                    };
                    const base = @intFromPtr(oc.link_hit_counters.ptr);
                    if (addr < base) @panic("motion totals: sibling record below owner counters");
                    const off = addr - base;
                    if (off % @sizeOf(nativegen.LinkHitCounter) != 0)
                        @panic("motion totals: sibling record misaligned in owner counters");
                    if (off / @sizeOf(nativegen.LinkHitCounter) >= rec_owner.code.instrs.len)
                        @panic("motion totals: sibling record outside the ordinary cells");
                    ts.sibling_link_hits +|= rec.count;
                },
            }
            var seen = false;
            for (touched[0..ti]) |prev_addr| {
                const prev: *const nativegen.LinkHitCounter = @ptrFromInt(prev_addr);
                if (prev.owner_id == rec.owner_id) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            const rec_owner = ts.traceById(rec.owner_id) orelse @panic("motion totals: drained owner did not resolve");
            ts.accountTraceRun(rec_owner, 0);
            trace.TraceState.accountCandidateCharge(rec_owner, .entered);
        }
        ts.dbg("motion totals: pushed={d} popped={d} slots={d} final t={d} kind={s}", .{ result.pushed_frames, result.popped_frames, ctx.touched_len, owner.id, @tagName(row.kind) });
        return self.consumeDescentTerminalRow(owner, row, result, 1);
    }

    /// Doc 44 D9: the quiet head episode — the full dispatcher episode
    /// reduced to what a head entry can actually reach when the quiet
    /// predicate holds. Every skipped call is proven no-op by a predicate
    /// line; every taken action is verbatim the full path's (byte-identical
    /// by construction, hashgate-pinned). The head result grammar is closed
    /// (D5/D8): terminal completion, seed capacity decline, or a zero
    /// exit / prologue-fail into the D8 sibling walk. `seed_hash_decline`
    /// is excluded at compile time (`has_hash_seed`), fusion/silent/ledger
    /// shapes by the empty arm registry.
    fn enterHeadNativeQuiet(
        self: *Vm,
        ct: *trace.Trace,
        nt: *const nativegen.CompiledTrace,
        closure: *const function.Closure,
        proto: *const Proto,
        regs: RegWindow,
        base: usize,
    ) EntryDirective {
        const ts = &self.trace;
        // The `jfunc_head` §R1-5 bypass set already excluded every
        // observation/recording entry mode; assert rather than re-check.
        std.debug.assert(!ts.config.record_exec_log);
        std.debug.assert(!ts.isRecording());
        std.debug.assert(self.suspend_ctl == null and !self.record_safepoint_lines);
        // Doc 26 D1 tripwire, same as the full path.
        if (ct.code.requires_unicode_pin) std.debug.assert(self.unicode_version_pinned);
        ts.entries +%= 1;
        // Doc 22 §B.1: the native page seeds itself from this ctx.
        self.prepareNativeEpisode(closure, proto, base);
        ts.native_entries +%= 1;
        const result = nt.runCapturingLedger(regs, &ts.ledger_scratch, .{});
        // What the predicate bought (no promoted sets ⇒ no silent state):
        std.debug.assert(result.silent_active == 0);
        // Doc 44 D11: a pushed descent — the native run changed the VM frame
        // stack, so it MUST branch before every other consumer (they all
        // reason against the ENTRY activation; the top frame is now the
        // descent's leaf). Pushes mutate no receipt state, so the quiet
        // predicate needed no new line.
        if (result.pushed_frames > 0) {
            ts.last_exit_instr = result.exit_instr;
            return self.consumePushedDescent(ct, result, proto);
        }
        // Doc 44 D10 (quiet v2): an armed `.sibling_handoff` slot fired —
        // the whole chain is described by the multi-row ledger; the shared
        // burst consumer owns validation, accounting, and resumption. May
        // set `pending_sibling_arm` / penalty state, which correctly ends
        // quietness for the NEXT entry.
        if (result.ledger_len > 1) {
            ts.last_exit_instr = result.exit_instr; // full-path diagnostic parity
            return self.consumeHeadBurst(ct, ts.ledger_scratch[0..result.ledger_len], proto);
        }
        std.debug.assert(result.final_trace_id == ct.id);
        std.debug.assert(result.exit_reason != .seed_hash_decline);
        if (result.exit_reason == .seed_capacity_decline) {
            // Verbatim the full path's handler: an entry-condition mismatch,
            // not a guard failure — no receipt, no `last_exit_instr`.
            ts.dbg("seed-capacity-decline: trace={d} anchor={d}", .{ ct.id, ct.code.anchor.pc });
            ts.seed_capacity_declines +|= 1;
            return .next_candidate;
        }
        ts.last_exit_instr = result.exit_instr;
        if (result.exit_instr != std.math.maxInt(u32) and
            result.exit_instr < ct.code.instrs.len and
            ct.code.instrs[result.exit_instr].op == .terminal)
        {
            const term = ct.code.instrs[result.exit_instr];
            ts.dbg("terminal: trace={d} kind={d} resume={d}", .{ ct.id, term.a, term.aux });
            // `onSideExitReceipt(ct, 1, exit, 1, .deferred, .entered)` reduced
            // under the predicate: the while-probe rejects on op (terminal is
            // not `guard_true`), the region machine returns false
            // (`receiptsInert`), and the legacy productive path's two map
            // removals no-op on empty maps — leaving exactly these two calls.
            ts.accountTraceRun(ct, 1);
            trace.TraceState.accountCandidateCharge(ct, .entered);
            // Doc 44 D8: a completion by a NON-source sibling retires a
            // standing head-sibling want.
            ts.noteHeadSiblingCompletion(.{ .proto = ct.code.anchor.proto, .pc = ct.code.anchor.pc, .proto_id = ct.code.anchor.proto_id }, ct.id);
            // Doc 44 D10: an earlier walk failer + this completion = one
            // handoff observation. May set `pending_sibling_arm`, which
            // correctly ends quietness for the NEXT entry (the arm needs
            // the full path's selection-sited `tryArmSiblingHandoff`).
            self.consumeHeadWalkFail(ct.id);
            return .{ .resume_tier0 = @intCast(term.aux) };
        }
        // Head guard-fail zero exit / prologue-fail — deopt to function entry.
        // The receipt calls are the REAL funnels, verbatim semantics: they
        // mutate penalty/want state, correctly ending quietness for
        // subsequent entries. `.next_candidate` feeds the D8 sibling walk.
        const local_done: usize = result.local_completed;
        ts.dbg("head zero-exit: trace={d} native={} reason={s} exit={d} completed={d}", .{ ct.id, true, @tagName(result.exit_reason), result.exit_instr, result.completed });
        // Doc 44 D10: a REAL guard deopt (never a prologue-fail — that says
        // nothing about the branch) records the walk-local handoff evidence.
        if (result.exit_instr != std.math.maxInt(u32))
            ts.head_walk_fail = .{ .trace_id = ct.id, .exit_instr = result.exit_instr };
        ts.noteTakenExit(ct, result.exit_instr, local_done, .legacy);
        ts.onSideExitReceipt(
            ct,
            local_done,
            result.exit_instr,
            local_done,
            .deferred,
            if (result.exit_reason == .prologue_fail) .entry_refusal else .entered,
        );
        return .next_candidate;
    }

    /// Doc 56 Phases 3–4: consume a direct `.exit_side` exit of `ct`, from
    /// tier-1a (`tier == .ir`) or a native exit adapter (`.native_only`).
    /// The executor already applied the earlier bytecodes' sunk stores and
    /// the exit snapshot, so `regs` is coherent at the exit's resume pc `P`
    /// and the run committed `result.completed` iterations plus the start of
    /// the interrupted one, which the child or tier-0 finishes from `P`.
    ///   1. Receipt: count the firing (a wanted exit may give up here) and
    ///      charge it as productive — `completed + 1`, the interrupted
    ///      iteration being committed forward, like a loop-done completion.
    ///   2. Chain into a `.link` continuation at `P`. One that runs to its
    ///      `.link` serves the exit: bind a wanted exit to it.
    ///   3. Otherwise resume tier-0 at `P`; a still-wanted exit first asks
    ///      for a continuation recording there (`maybeArmExitSide`), which
    ///      needs `.full` mode for the dispatch prologue to start it.
    fn consumeExitSide(
        self: *Vm,
        comptime mode: ExecMode,
        comptime tier: trace.ChainTier,
        ct: *trace.Trace,
        result: trace_exec.ExecResult,
        proto: *const Proto,
        regs: RegWindow,
        base: usize,
        safe_to_arm: bool,
    ) EntryDirective {
        const ts = &self.trace;
        const ei = result.exit_instr;
        std.debug.assert(ct.exitSideAt(ei).materializes());
        const p = ct.code.exitResumePc(ei).?;
        ts.exit_side_hops +|= 1;
        if (tier == .native_only) ts.exit_side_native_hops +|= 1;
        const done = result.completed + 1;
        ts.dbg("exit-side hop: trace={d} exit={d} state={s} tier={s} resume pc={d} completed={d}", .{ ct.id, ei, @tagName(ct.exitSideAt(ei)), @tagName(tier), p, result.completed });
        ts.noteTakenExit(ct, ei, done, if (tier == .native_only) .native_direct else .tier1a_direct);
        ts.onSideExitReceipt(ct, done, ei, done, .deferred, .entered);
        return self.routeExitSide(mode, tier, ct, result, proto, regs, base, safe_to_arm);
    }

    /// Doc 56 Phase 5: an UNARMED exit adapter ended a replayed native
    /// ledger (`ChainResult.exit_side`). The replay already charged its row
    /// (region receipt and selection) and published `P` as the resume; the
    /// hot-exit count and the routing run here, after the walk, because
    /// routing can arm.
    fn consumeExitSideTerminal(
        self: *Vm,
        comptime mode: ExecMode,
        es: trace.ExitSideTerminal,
        proto: *const Proto,
        regs: RegWindow,
        base: usize,
        safe_to_arm: bool,
    ) EntryDirective {
        const ts = &self.trace;
        std.debug.assert(es.trace.exitSideAt(es.exit).materializes());
        ts.dbg("exit-side hop: trace={d} exit={d} state={s} tier=native_ledger resume pc={d} done={d}", .{ es.trace.id, es.exit, @tagName(es.trace.exitSideAt(es.exit)), es.trace.code.exitResumePc(es.exit).?, es.done });
        ts.noteTakenExit(es.trace, es.exit, es.done, .native_direct);
        return self.routeExitSide(mode, .native_only, es.trace, .{ .completed = es.done -| 1, .exit_instr = es.exit }, proto, regs, base, safe_to_arm);
    }

    /// Doc 56 Phase 5: the routing half of `consumeExitSide` — everything
    /// after the receipt. Also run for an exit whose unarmed adapter ended a
    /// replayed native ledger (`consumeExitSideTerminal`).
    ///   0. Doc 64 step 3: a loop root behind the `.loop` marker at `P` that
    ///      fits the slab serves the exit first (bind, arm, resume at `P`).
    ///   1. Chain into a `.link` continuation at `P`. One that runs to its
    ///      `.link` serves the exit: bind a wanted exit to it, and (native)
    ///      arm the adapter to jump straight into it next time.
    ///   2. Otherwise resume tier-0 at `P`; a still-wanted exit first asks
    ///      for a continuation recording there (`maybeArmExitSide`), which
    ///      needs `.full` mode for the dispatch prologue to start it.
    /// A LINKED chain without a resume pc resumes at the loop header, `ct`'s
    /// anchor (`ChainResult`'s convention: the `.link` closed the iteration
    /// there). A chain that did not link always publishes one under
    /// `.exit_side` materialization — the slab is coherent at `P` or later,
    /// never back at the header — so a missing pc there is a broken
    /// invariant, not a default.
    fn routeExitSide(
        self: *Vm,
        comptime mode: ExecMode,
        comptime tier: trace.ChainTier,
        ct: *trace.Trace,
        result: trace_exec.ExecResult,
        proto: *const Proto,
        regs: RegWindow,
        base: usize,
        safe_to_arm: bool,
    ) EntryDirective {
        const ts = &self.trace;
        const ei = result.exit_instr;
        const p = ct.code.exitResumePc(ei).?;
        const anchor_pc: usize = ct.code.anchor.pc;
        // Doc 64 §10 step 3 (3b): a loop root behind the `.loop` marker at
        // `P` whose entry types the slab satisfies serves the exit, ahead of
        // any continuation at `P`. Bind (and natively arm) the exit to it,
        // then resume tier-0 at `P`: the marker's entry patch enters the
        // root there, through its ordinary entry and entry checks.
        if (ts.exitSideRootServes(ct, ei, regs)) |root| {
            ts.exit_side_root_routes +|= 1;
            ts.noteExitSideChain(ct, ei, .served);
            ts.bindExitSide(ct, ei, .root, root);
            ts.setExitSideEntry(ct, ei, root);
            if (tier == .native_only) ts.armExitSide(ct, ei, root, safe_to_arm);
            if (mode == .full and self.runFastPath()) return .{ .switch_mode_at = p };
            return .{ .resume_tier0 = p };
        }
        const chained = ts.driveChain(ct, result, proto, regs, tier, .{ .exit_side = p }, &.{}, safe_to_arm, self.unicode_version_pinned);
        // §4.8.3 R4: an attached exit whose chain keeps missing gives up;
        // doc 64 §10 step 2: a chain that ran into the end of an enclosing
        // loop is no miss.
        ts.noteExitSideChain(ct, ei, ts.exitSideChainOutcome(ct, ei, chained));
        if (chained) |chain| {
            if (chain.linked_trace) |child| {
                ts.exit_side_chains +|= 1;
                ts.bindExitSide(ct, ei, .chain, child);
                ts.setExitSideEntry(ct, ei, child);
                if (tier == .native_only) ts.armExitSide(ct, ei, child, safe_to_arm);
                return .{ .resume_tier0 = chain.resume_pc orelse anchor_pc };
            }
            // No continuation ran to its `.link`. One that deopted before it
            // resumes at `P` (its receipt charged), and a wanted exit records
            // a sibling below. But a native one can also deopt through an
            // armed handoff into a same-anchor sibling that carries the run
            // on elsewhere: honour the chain's resume, and record nothing —
            // tier-0 is no longer at `P`.
            const rpc = chain.resume_pc orelse
                @panic("routeExitSide: an exit-side chain that did not link left no resume pc");
            if (rpc != p) return .{ .resume_tier0 = rpc };
        }
        if (ct.exitSideAt(ei) == .wanted and ts.maybeArmExitSide(ct, ei, proto, p, base)) {
            if (mode == .fast) return .{ .switch_mode_at = p };
            return .{ .resume_tier0 = p };
        }
        if (mode == .full and self.runFastPath()) return .{ .switch_mode_at = p };
        return .{ .resume_tier0 = p };
    }

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
        // Doc 45 D8 interim: a PRECISE trace cannot serialize yet
        // (`traceser` has no snapshot schema until the format bump), so under
        // an exec-log recording session it must not RUN either — its exec-log
        // rows would reference a trace absent from the session's trace file,
        // breaking the visualiser's record. Decline here (not only in the
        // back-edge walk) so patched head/cont entries are covered too;
        // tier-0 owns precise anchors for the session. Deterministic: a pure
        // function of config + the trace's committed mode.
        if (ct.code.deopt_mode == .precise and self.trace.config.record_exec_log)
            return .next_candidate;
        // Doc 26 D1 tripwire: a trace carrying `supper`/`slower` can only have
        // committed after a successful tier-0 upper/lower pinned the session's
        // Unicode version, and the pin is monotone for this VM's lifetime — so
        // it MUST hold at every entry. (Patched native→native transfers have
        // no vm in reach; a pin that holds when their link is armed holds
        // forever after, so entry + arm coverage is complete.) Free in release.
        if (ct.code.requires_unicode_pin) std.debug.assert(self.unicode_version_pinned);
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
            self.seedTraceInputs(&ct.code, base, closure, proto, regs, &native_eligible) orelse return .next_candidate;
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
            buf = self.trace.valuesPush(ct.code.instrs.len) catch
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
            self.trace.tryArmFrameLinks(ct, safe_to_arm);
            // Doc 56 Phase 3: every direct tier-1a run of `ct` (plain,
            // exec-log, seed-hash-decline rerun) honours its exit-side
            // state; a wanted/attached exit comes back `.exit_side`.
            const ir_ctx: irinterp.ExecCtx = .{ .heap = self.heap, .exit_side = ct.exit_side };
            var result = if (self.trace.config.record_exec_log) blk: {
                const rec = self.trace.execRecorderFor(ct.id) orelse break :blk irinterp.executeCtx(ir_ctx, &ct.code, trace_regs, buf);
                break :blk irinterp.executeTracedCtx(ir_ctx, rec, &ct.code, trace_regs, buf);
            } else blk: {
                // Doc 22 §B.2: `native_page` was resolved above (before VM-side
                // seeding); non-null implies native_codegen && !record_exec_log.
                if (native_page) |nt| {
                    ran_native = true;
                    self.trace.native_entries +%= 1;
                    // A page whose loop-done guard declined the linked flush
                    // (`CompiledTrace.linked_loop_done_ok`) ends that loop in
                    // an ordinary deopt even in link mode, and the chain
                    // below would then resume past the uncommitted final
                    // iteration: run it in ordinary mode.
                    ran_native_link_mode = nt.linked_loop_done_ok and self.trace.hasNativeLoopDoneLink(ct, proto);
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
                    // Doc 56 Phase 4: the one native call that may take an
                    // exit adapter; its `.exit_side` result is consumed by
                    // the arm below, before any ledger replay.
                    const exit_side_ok = self.trace.exitSideNative();
                    break :blk if (ran_native_link_mode)
                        nt.runLinkedLoopDoneCapturingEntry(trace_regs, &self.trace.ledger_scratch, self.trace.silentStaging(), exit_side_ok)
                    else
                        nt.runCapturingLedgerEntry(trace_regs, &self.trace.ledger_scratch, self.trace.silentStaging(), exit_side_ok);
                }
                break :blk irinterp.executeCtx(ir_ctx, &ct.code, trace_regs, buf);
            };
            // Doc 44 D11: a pushed descent — the native run changed the VM
            // frame stack, so it MUST branch before EVERY other consumer
            // below (silent drain, seed-decline handlers, D10 burst, scalar
            // heads): they all reason against the ENTRY activation, and a
            // pushed-descent ledger can be `len == 1` (round 5 change 3).
            if (ran_native and result.pushed_frames > 0) {
                self.trace.last_exit_instr = result.exit_instr;
                const d = self.consumePushedDescent(ct, result, proto);
                wctx.dead.retire(&self.trace);
                return d;
            }
            if (ran_native) {
                if (self.trace.driveDispatcherSilentResult(ct, result, proto, regs, safe_to_arm)) |chain| {
                    if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                    // Doc 56 Phase 6 (§4.8.2 item 7): silence can end in a
                    // reporting suffix whose last row is an UNARMED exit
                    // adapter's (an unpromoted adapter takes its reporting
                    // path under silence). The slab is coherent at `pc`, its
                    // resume pc; route it exactly as the ledger branch does.
                    if (chain.exit_side) |es| {
                        const d = self.consumeExitSideTerminal(mode, es, proto, regs, base, safe_to_arm);
                        wctx.dead.retire(&self.trace);
                        return d;
                    }
                    const armed_side = self.trace.consumeSideTraceWantAtResume(proto, @intCast(pc));
                    wctx.dead.retire(&self.trace);
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
                self.trace.dbg("seed-capacity-decline: trace={d} anchor={d}", .{ ct.id, ct.code.anchor.pc });
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
                self.trace.dbg("seed-hash-decline: trace={d} anchor={d} -> tier-1a rerun", .{ ct.id, ct.code.anchor.pc });
                self.trace.seed_hash_declines +|= 1;
                trace_regs = self.seedTraceInputs(&ct.code, base, closure, proto, regs, &native_eligible) orelse return .next_candidate;
                // The downgrade is the one native road back onto the tier-1a
                // executor, and native entries skip the entry push above — so
                // take the frame here. The mark is fresh, not the entry's:
                // `values_mark` is `undefined` on this path, and retaking it is
                // also correct in itself (everything the native run's burst
                // machinery pushed above was released before we got here, so
                // the stack is back at its entry state).
                values_mark = self.trace.valuesMark();
                buf = self.trace.valuesPush(ct.code.instrs.len) catch
                    return .next_candidate; // OOM: same skip as the entry push
                buf_live = true;
                result = irinterp.executeCtx(ir_ctx, &ct.code, trace_regs, buf);
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

            // Doc 44 D10: fused head burst. MUST precede the scalar terminal /
            // head-zero consumers below — they read only the TERMINAL body's
            // scalars and would silently mis-consume a multi-row head ledger,
            // dropping the intermediate rows' accounting and validation
            // (round 4's factual correction). Loop-anchor multi-row ledgers
            // still flow to `driveDispatcherLedger` further down.
            if (ran_native and result.ledger_len > 1 and
                trace.anchorKind(ct.code.anchor.pc) != .loop)
            {
                const d = self.consumeHeadBurst(ct, self.trace.ledger_scratch[0..result.ledger_len], proto);
                wctx.dead.retire(&self.trace);
                return d;
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
            // Doc 44 P0: a `.terminal` exit is a COMPLETION of a head trace,
            // NOT a side exit — the φ writeback already published the end
            // state, and tier-0 resumes AT the still-unexecuted ret/self-call
            // (`terminal.aux`). It bypasses the entire exit-consumer grammar
            // below by design (review round 1: no strike, no hot-exit charge,
            // no side-trace want, no chain — those all reason about loop
            // anchors and would misread a straight-line completion with
            // `completed == 0` as a failed entry).
            if (result.exit_instr != std.math.maxInt(u32) and
                result.exit_instr < final.code.instrs.len and
                final.code.instrs[result.exit_instr].op == .terminal)
            {
                const term = final.code.instrs[result.exit_instr];
                self.trace.dbg("terminal: trace={d} kind={d} resume={d}", .{ final.id, term.a, term.aux });
                // A PRODUCTIVE receipt — the run completed the whole recorded
                // body, so it must both attribute coverage AND clear the
                // penalty/gate state (doc 31 D2 clear-on-productive; without
                // this, base-case zero exits would ratchet a gate the head's
                // successes could never un-earn — exactly the str_gmatch
                // starvation shape). One completed head run = one iteration.
                self.trace.onSideExitReceipt(final, 1, result.exit_instr, 1, .deferred, .entered);
                // Doc 44 D8: a completion by a NON-source sibling retires a
                // standing head-sibling want (clear + DONE-latch the raising
                // exit) — the walk only reached this trace past the source's
                // zero exit, so the failing path is covered now.
                self.trace.noteHeadSiblingCompletion(.{ .proto = final.code.anchor.proto, .pc = final.code.anchor.pc, .proto_id = final.code.anchor.proto_id }, final.id);
                // Doc 44 D10: earlier walk failer + this completion = one
                // handoff observation on the failer's exit.
                self.consumeHeadWalkFail(final.id);
                wctx.dead.retire(&self.trace);
                return .{ .resume_tier0 = @intCast(term.aux) };
            }
            // Doc 45 D6: tier-1a PRECISE deopt. The executor already
            // materialized the failing op's per-bytecode snapshot into the
            // guest registers, so the ONLY sound continuation is tier-0 at
            // the snapshot's `resume_pc` — for every anchor kind (a precise
            // head/cont deopt bypasses the entry pc; a loop deopt bypasses
            // the anchor). Registers are MID-ITERATION state now: no sibling
            // trial (`.next_candidate` would enter a sibling on non-entry
            // regs), no chain, no continuation arm, no side-trace want
            // (`noteTakenExit` skipped — a want here would bucket an
            // entry-replay successor on a mid-body resume pc, D6's
            // mis-bucketed-fallthrough hazard). The ordinary receipt still
            // charges productivity/penalty so a thrashing precise anchor
            // gates and tier-0 takes it back. `final == ct` holds for BOTH
            // executors: a precise page never links/fuses, so a native
            // exit's baked final id is always the entered trace's own.
            // Doc 45 D5: a precise effect shim raised a runtime error — the
            // executor restored the failing op's snapshot (pre-instruction
            // registers; the iteration's earlier committed effects stand,
            // partial heap preserved) and the error is about to unwind, so
            // NO tiering accounting runs: no receipt, no strike, no
            // side-trace want, no chain/sibling continuation, no mode
            // switch. Validate exactly like `.precise_resume`, map the shim
            // status to the guest error, and hand the raise directive up —
            // the consumer parks the error at the snapshot's pc without
            // re-executing the bytecode (execute-once, never an OOM retry).
            // Doc 45 D6: the native executor produces both precise reasons
            // now (per-snapshot materializers restored the window before the
            // exit), so these arms validate rather than assume tier-1a.
            if (result.exit_reason == .precise_error) {
                // Doc 45 D6: BOTH executors produce this reason now. A precise
                // page never links/fuses (arm-side prohibitions), so the
                // native final id must resolve to the entered trace itself,
                // with a single terminal non-yielded ledger row whose kind
                // agrees with the reason, and no silent/frame-motion state.
                std.debug.assert(final == ct);
                if (ran_native) {
                    std.debug.assert(result.ledger_len == 1);
                    std.debug.assert(result.silent_active == 0);
                    std.debug.assert(result.pushed_frames == 0 and result.popped_frames == 0);
                    std.debug.assert(self.trace.ledger_scratch[0].kind == .precise_error);
                    std.debug.assert(self.trace.ledger_scratch[0].outcome == .normal);
                    std.debug.assert(self.trace.ledger_scratch[0].id == result.final_trace_id);
                    std.debug.assert(self.trace.ledger_scratch[0].exit == result.exit_instr);
                }
                std.debug.assert(ct.code.deopt_mode == .precise);
                std.debug.assert(result.snapshot_id >= 1 and result.snapshot_id <= ct.code.snapshots.len);
                std.debug.assert(result.activation_base == 0 and result.activation_depth == 0);
                const snap = ct.code.snapshots[result.snapshot_id - 1];
                std.debug.assert(snap.register_count == proto.num_registers);
                std.debug.assert(snap.resume_pc < proto.code.len);
                self.trace.dbg("precise-error raw: trace={d} native={} exit={d} snap={d} status={d}", .{ ct.id, ran_native, result.exit_instr, result.snapshot_id, result.runtime_error });
                // `.ok` cannot reach here: the executor sets `runtime_error`
                // only on failure. Today only `tnew` and the string helpers
                // fail (`out_of_memory`); doc 63's host call adds the rest.
                const err: Error = table_runtime.toError(@enumFromInt(result.runtime_error));
                self.trace.dbg("precise-error: trace={d} exit={d} snap={d} raise_pc={d} status={d}", .{ ct.id, result.exit_instr, result.snapshot_id, snap.resume_pc, result.runtime_error });
                self.trace.precise_errors +|= 1;
                wctx.dead.retire(&self.trace);
                return .{ .raise_at = .{ .pc = @intCast(snap.resume_pc), .err = err } };
            }
            if (result.exit_reason == .precise_resume) {
                // Doc 45 D6: both executors — same validation grammar as the
                // `.precise_error` arm above.
                std.debug.assert(final == ct);
                if (ran_native) {
                    std.debug.assert(result.ledger_len == 1);
                    std.debug.assert(result.silent_active == 0);
                    std.debug.assert(result.pushed_frames == 0 and result.popped_frames == 0);
                    std.debug.assert(self.trace.ledger_scratch[0].kind == .precise_deopt);
                    std.debug.assert(self.trace.ledger_scratch[0].outcome == .normal);
                    std.debug.assert(self.trace.ledger_scratch[0].id == result.final_trace_id);
                    std.debug.assert(self.trace.ledger_scratch[0].exit == result.exit_instr);
                }
                std.debug.assert(ct.code.deopt_mode == .precise);
                std.debug.assert(result.activation_base == 0 and result.activation_depth == 0);
                // D6 dispatcher validation — internal invariant failures,
                // never a replay fallback.
                std.debug.assert(result.snapshot_id >= 1 and result.snapshot_id <= ct.code.snapshots.len);
                const snap = ct.code.snapshots[result.snapshot_id - 1];
                std.debug.assert(snap.register_count == proto.num_registers);
                std.debug.assert(snap.resume_pc < proto.code.len);
                const done: usize = result.completed;
                self.trace.dbg("precise-resume: trace={d} exit={d} snap={d} resume_pc={d} completed={d}", .{ ct.id, result.exit_instr, result.snapshot_id, snap.resume_pc, done });
                self.trace.precise_resumes +|= 1;
                self.trace.onSideExitReceipt(ct, done, result.exit_instr, done, .deferred, .entered);
                wctx.dead.retire(&self.trace);
                if (mode == .full and self.runFastPath()) {
                    return .{ .switch_mode_at = @intCast(snap.resume_pc) };
                }
                return .{ .resume_tier0 = @intCast(snap.resume_pc) };
            }
            // Doc 56 Phases 3–4: an exit-side exit (tier-1a, or a native exit
            // adapter). The slab is coherent at the exit's resume pc, so none
            // of the anchor-coherent grammar below applies (no sibling trial,
            // no anchor chain, no deopt replay). This arm owns only the
            // scalar case, the entered trace's own adapter as the only row
            // (doc 56 Phase 5): a longer native ledger ending in an adapter
            // row (a yield at the adapter, or an unarmed exit reached after
            // chained rows) must replay its prefix, so it flows to
            // `driveDispatcherLedger` below.
            if (result.exit_reason == .exit_side and (!ran_native or result.ledger_len <= 1)) {
                std.debug.assert(final == ct);
                if (ran_native) std.debug.assert(result.ledger_len == 1 and
                    self.trace.ledger_scratch[0].kind == .exit_side and
                    self.trace.ledger_scratch[0].id == ct.id and
                    result.local_completed == result.completed);
                const d = if (ran_native)
                    self.consumeExitSide(mode, .native_only, ct, result, proto, trace_regs, base, safe_to_arm)
                else
                    self.consumeExitSide(mode, .ir, ct, result, proto, trace_regs, base, safe_to_arm);
                wctx.dead.retire(&self.trace);
                return d;
            }
            // Doc 44 P0/D12b: a one-shot trace's (head or cont) guard-fail
            // exit — deopt to its entry pc (regs untouched since entry). The
            // loop-anchor grammar below (hot-exit wants, continuations,
            // prime sides, chains) reasons about back-edge anchors; none of
            // it applies to a sentinel/tagged anchor, and `noteTakenExit`'s
            // side-trace want would only UNPATCH the sole entry. Charge the
            // ordinary zero receipt — the thrash gate stays live, so a
            // one-shot page that keeps failing its guards still retires —
            // and fall to `.next_candidate`: the patch arm then runs the
            // canonical instruction (returning `.resume_tier0(entry)` here
            // would re-dispatch the patch and spin).
            if (trace.anchorKind(final.code.anchor.pc) != .loop) {
                self.trace.dbg("head zero-exit: trace={d} native={} reason={s} exit={d} completed={d}", .{ final.id, ran_native, @tagName(result.exit_reason), result.exit_instr, result.completed });
                // Doc 44 D10: a REAL native guard deopt records the walk-local
                // handoff evidence (native-only, matching Part S — evidence
                // from a tier-1a run would memo-reject on the uncompiled
                // parent; prologue-fail carries no branch information).
                if (ran_native and result.exit_instr != std.math.maxInt(u32))
                    self.trace.head_walk_fail = .{ .trace_id = final.id, .exit_instr = result.exit_instr };
                // Doc 44 D8: head guard fails DO accrue hot-exit hotness now —
                // `noteTakenExit`'s head route raises the sibling want without
                // ever unpatching (the pc-0 patch is the sole entry). A
                // prologue-fail exit (`exit_instr == maxInt`) is bounds-refused
                // inside, exactly like the loop arms.
                self.trace.noteTakenExit(final, result.exit_instr, local_done, .legacy);
                self.trace.onSideExitReceipt(
                    final,
                    local_done,
                    result.exit_instr,
                    local_done,
                    .deferred,
                    if (result.exit_reason == .prologue_fail) .entry_refusal else .entered,
                );
                wctx.dead.retire(&self.trace);
                return .next_candidate;
            }
            // Doc 45 D6: a PRECISE loop trace's remaining `.normal` exits are
            // PROLOGUE failures (`IrInstr.snap == 0` — the per-iteration
            // `slot_load`s and eager `guard_gc` re-execute each pass on the
            // dupe path, so a fail here is iteration-entry coherent: regs
            // untouched since the last φ flush). The ordinary ENTRY contract
            // applies, minus everything D6 suppresses for precise pages — no
            // side-trace wants (`noteTakenExit` below is skipped), no
            // continuation arms, no prime sides, no chains, no
            // widen-eviction probe. Productive → receipt + tier-0 at the
            // anchor (`pc` is unadvanced here); zero → penalty receipt +
            // next candidate (regs entry-coherent, so the sibling trial walk
            // stays sound). One-shot precise prologue exits took the head
            // zero-exit arm above — same entry contract, same soundness.
            if (ct.code.deopt_mode == .precise) {
                std.debug.assert(final == ct);
                if (ran_native) {
                    // Doc 45 D6: a NATIVE precise page's remaining exits are
                    // the eager guard_gc's snap==0 exit (`.normal` through
                    // the ordinary carried-home flush — iteration-entry
                    // coherent, exactly this arm's contract, even after
                    // completed iterations) and the hoisted-guard
                    // `.prologue_fail` (pre-entry, regs untouched). Single
                    // terminal non-yielded row, no silent/frame motion.
                    std.debug.assert(result.exit_reason == .normal or result.exit_reason == .prologue_fail);
                    std.debug.assert(result.ledger_len == 1);
                    std.debug.assert(result.silent_active == 0);
                    std.debug.assert(result.pushed_frames == 0 and result.popped_frames == 0);
                }
                self.trace.dbg("precise prologue-exit: trace={d} exit={d} completed={d}", .{ ct.id, result.exit_instr, local_done });
                self.trace.onSideExitReceipt(ct, local_done, result.exit_instr, local_done, .deferred, .entered);
                wctx.dead.retire(&self.trace);
                if (local_done > 0) {
                    if (mode == .full and self.runFastPath()) {
                        return .{ .switch_mode_at = pc };
                    }
                    return .{ .resume_tier0 = pc };
                }
                return .next_candidate;
            }
            if (ran_native) self.trace.dbg("receipt: pc={d} t={d} link_mode={} local={d} exit={d} ledger_len={d} completed={d}", .{ ct.code.anchor.pc, ct.id, ran_native_link_mode, local_done, result.exit_instr, result.ledger_len, result.completed });
            const linked_one_trip = ran_native and ran_native_link_mode and
                local_done == 0 and
                result.exit_reason == .normal and
                result.exit_instr != std.math.maxInt(u32) and
                result.exit_instr < final.code.instrs.len and
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
            // `.ordinary_header` off `final.code.anchor.pc` (the outer
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
                // Doc 56 Phase 5: the span ended on an unarmed exit
                // adapter; the slab is coherent at `pc` (its resume pc).
                if (chain.exit_side) |es| {
                    const d = self.consumeExitSideTerminal(mode, es, proto, regs, base, safe_to_arm);
                    wctx.dead.retire(&self.trace);
                    return d;
                }
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
                wctx.dead.retire(&self.trace);
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
            // path.
            //
            // A numeric-`for` loop-done exit is a productive completion owned
            // by the continuation machinery (`maybeArmContinuation` below), so
            // it is not counted (`linked_one_trip` exits are loop-done by
            // construction and fall out of the same check).
            //
            // Doc 58 B2 review, blocker 2: a `while`/`repeat` loop's OWN test
            // (`isOwnLoopTest`) IS counted. Its post-loop continuation has no
            // `maybeArmContinuation` leg any more — doc 56's exit-side route
            // is what records it, and that route is fed only from here.
            // `noteTakenExit` routes it to exit-side first and stops it
            // before every legacy route (§4.3, review r3 finding 1: a legacy
            // want would unpatch the entry and record a pass that can only
            // end in LLEAVE). Excluding it here starved exit-side completely.
            //
            // Classify ONCE — this is the per-completion hot path (2M+
            // entries/run on scimark-lu) and each classifier walks trace instrs
            // + proto code.
            const exit_ok = result.exit_instr != std.math.maxInt(u32) and
                result.exit_instr < final.code.instrs.len;
            const numeric_for_done = exit_ok and
                trace.isLoopDoneGuardIndex(final, result.exit_instr);
            const any_loop_done = exit_ok and
                (numeric_for_done or trace.isOwnLoopTestIndex(final, result.exit_instr));
            const count_exit = exit_ok and !numeric_for_done;
            if (exit_ok and local_done == 0 and !linked_one_trip and
                final.code.isSteadyRegionExit(result.exit_instr))
                self.trace.peeled_steady_zero_exits +|= 1;
            if (count_exit) {
                // Doc 56 Phases 3–4: a direct run may take the exit-side
                // route — tier-1a always (its executor honours the exit-side
                // state), native when its page carries exit adapters and the
                // exit is the entered trace's own.
                const route: trace.TraceState.ExitRoute = if (!ran_native)
                    .tier1a_direct
                else if (self.trace.exitSideNative() and final == ct)
                    .native_direct
                else
                    .legacy;
                self.trace.noteTakenExit(final, result.exit_instr, local_done, route);
            }

            if (local_done > 0 or linked_one_trip) {
                // This trace did useful work — keep its result.
                // (`linked_one_trip`: the committed loop-done IS one
                // enclosing iteration, replayLedger's `max(local, 1)`.)
                self.trace.onSideExitReceipt(
                    final,
                    if (linked_one_trip) 1 else local_done,
                    result.exit_instr,
                    if (linked_one_trip or any_loop_done) 1 else local_done,
                    .deferred,
                    .entered,
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
                wctx.dead.retire(&self.trace);
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
                // NOT advance pc (regs coherent at `ct.code.anchor`).
                // Self-limiting: `countTracesAt >= 2` (in
                // `noteTakenExit`'s branch route) stops re-arming
                // once the prime side-trace exists, and the commit
                // DONE-latches the parent exit.
                if (self.trace.wants_prime_side) |want| {
                    if (want.proto == final.code.anchor.proto and want.pc == final.code.anchor.pc and
                        !self.trace.isRecording() and
                        self.trace.pending_replay_anchor == null and
                        !self.trace.isGated(final.code.anchor))
                    {
                        self.trace.setPendingReplayAnchor(final.code.anchor);
                        // Hotexit provenance rides into the replay
                        // recording for the commit's DONE latch.
                        self.trace.pending_replay_src = self.trace.prime_want_src;
                        self.trace.prime_want_src = null;
                        self.trace.wants_prime_side = null;
                        self.trace.prime_side_arms +|= 1;
                        wctx.dead.retire(&self.trace);
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
                // Doc 58: only a numeric `for` loop-done chains here. A
                // `while`/`repeat` condition guard is an ordinary exit — its
                // continuation at the post-loop pc is reached through the
                // exit-side route, not through a loop-done materialization.
                if (ran_native and ran_native_link_mode) {
                    if (self.trace.driveChain(final, result, proto, trace_regs, .native_only, .native_numeric_for_done, &.{}, safe_to_arm, self.unicode_version_pinned)) |chain| {
                        if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                        wctx.dead.retire(&self.trace);
                        return .{ .resume_tier0 = pc };
                    }
                } else if (!ran_native) {
                    if (self.trace.driveChain(final, result, proto, trace_regs, .ir, .{ .ir_numeric_for_done = buf }, &.{}, safe_to_arm, self.unicode_version_pinned)) |chain| {
                        if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                        wctx.dead.retire(&self.trace);
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
                // SEEDED continuations, so `t.code.inputs.len` is
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
                // Doc 58 §4.3: a loop's own test has the SHAPE of a source-branch
                // guard (`guard_true` from a `jmp_if_false`) but it is a
                // COMPLETION — chaining to a same-anchor sibling could only
                // re-check a finished loop. `isSourceBranchGuardExit` excludes
                // it, so no test is needed here.
                if (self.trace.isSourceBranchGuardExit(final, result.exit_instr)) {
                    if (ran_native) {
                        if (self.trace.driveChain(final, result, proto, regs, .native_only, .ordinary_header, excl[0..nexcl], safe_to_arm, self.unicode_version_pinned)) |chain| {
                            if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                            wctx.dead.retire(&self.trace);
                            return .{ .resume_tier0 = pc };
                        }
                    } else {
                        if (self.trace.driveChain(final, result, proto, regs, .ir, .ordinary_header, excl[0..nexcl], safe_to_arm, self.unicode_version_pinned)) |chain| {
                            if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                            wctx.dead.retire(&self.trace);
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
            self.trace.onSideExitReceipt(
                final,
                0,
                result.exit_instr,
                0,
                .deferred,
                if (result.exit_reason == .prologue_fail) .entry_refusal else .entered,
            );

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
            if (final == ct and !wctx.dead.full() and self.trace.laneWidenedPast(ct, regs)) {
                wctx.dead.add(ct);
            }

            // --- coherent-anchor chaining (doc 16) ---
            // After this zero-exit the registers are coherent at
            // `ct.code.anchor`, so chain to a same-anchor sibling the
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
                if (self.trace.driveChain(final, result, proto, regs, .native_only, .ordinary_header, excl[0..nexcl], safe_to_arm, self.unicode_version_pinned)) |chain| {
                    if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                    wctx.dead.retire(&self.trace);
                    return .{ .resume_tier0 = pc };
                }
            } else {
                if (self.trace.driveChain(final, result, proto, regs, .ir, .ordinary_header, excl[0..nexcl], safe_to_arm, self.unicode_version_pinned)) |chain| {
                    if (chain.resume_pc) |resume_pc| pc = @intCast(resume_pc);
                    wctx.dead.retire(&self.trace);
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
        // Doc 44 D12b (round 6 change 4): one-shot is a BEHAVIOR class (head
        // + cont share the walk/retention/want/evidence machinery), but every
        // per-anchor operation below is keyed on the EXACT anchor pc — a
        // proto now has many one-shot anchors, and a cont-anchor-A row must
        // never validate (or select siblings) against cont-anchor-B.
        const anchor_pc = ct.code.anchor.pc;
        const is_head = trace.anchorKind(anchor_pc) == .head;
        const one_shot = trace.anchorKind(anchor_pc) != .loop;
        var dead: WalkDead = .{};
        // The walk marks each candidate visited before entering. Seed the
        // exclusion set with the incumbent; the head sibling walk below grows it.
        var visited: [trial_visited_cap]*trace.Trace = undefined;
        visited[0] = ct;
        var nvisited: usize = 1;
        var wctx: TrialWalkCtx = .{
            .visited = visited[0..1],
            .dead = &dead,
        };
        // Doc 44 D10: fresh evidence channel per walk — a failer recorded by
        // a PREVIOUS activation's walk must never pair with this walk's
        // completion (the "different trace completed the SAME call" claim
        // only holds within one walk). Same freshness rule for the burst
        // visited scratch: stale ids from a prior activation's burst must
        // not shrink THIS walk's candidate set.
        if (one_shot) {
            self.trace.head_walk_fail = null;
            self.trace.head_burst_visited_len = 0;
        }
        if (is_head) {
            // Doc 44 D12a (A2): consume the descent-bottom failer carry. The
            // `call_seq` pin proves this walk belongs to the very activation
            // the descent deopted in (globally monotone — a stale carry can
            // never false-match); a mismatch means that activation died, so
            // discard. On match the carry seeds `head_walk_fail` AFTER the
            // freshness reset above — this walk's completion then pairs with
            // the descender's bottom exit (`noteSiblingTerminal`), which is
            // what arms descender@exit → base-case sibling and lets the
            // descent finish natively next time (the fib(27)-shape fix).
            if (self.trace.pending_descent_fail) |pdf| {
                self.trace.pending_descent_fail = null;
                if (pdf.call_seq == self.frames[self.depth - 1].call_seq)
                    self.trace.head_walk_fail = pdf.exit;
            }
        }
        // A1' (doc 45 / task 27, codex 01a08f8d): ordinary-probe consumer.
        // BEFORE the native-decline check and before attempting the (possibly
        // precise) incumbent — so the probe fires at the same deterministic
        // entry in native AND tier-1a modes and the population stays
        // mode-independent. The steady-state cost is one branch
        // (`ordinary_probe_count == 0`). Transfer rules mirror the head-want
        // transfer below: never while a recording or another pending is in
        // flight; a gate-barred or population-full anchor resolves the probe
        // as hopeless instead (which re-opens the D6.1 decline memo).
        if (one_shot and self.trace.ordinaryProbeNeeded(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id })) {
            const akey = trace.AnchorKey{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id };
            if (self.trace.recordingAbandoned(akey) or
                self.trace.countTracesAt(akey) >= self.trace.config.max_traces_per_anchor)
            {
                // PERMANENT resolution only — a transient strike cooldown
                // skips the transfer below (recordingBarred) but keeps the
                // probe alive for a retry once the window elapses.
                self.trace.clearOrdinaryProbe(akey);
            } else if (!self.trace.isRecording() and !self.trace.recordingBarred(akey) and
                self.trace.pending_call_anchor == null and
                self.trace.pending_ret_anchor == null)
            {
                // The flag is NOT cleared here: it survives an aborted probe
                // (retries bounded by the record gate) and resolves only on
                // ordinary commit / barred / full. Nothing below ran yet — no
                // dead traces, no patch mutation — so returning directly is
                // safe (§R6-1 order untouched).
                self.trace.dbg("ordinary-probe transfer: arming forced-ordinary recording at anchor pc={d}", .{anchor_pc});
                if (is_head) {
                    self.trace.setPendingCallAnchor(.{
                        .proto = proto,
                        .base = base,
                        .call_seq = self.frames[self.depth - 1].call_seq,
                        .force_ordinary = true,
                    });
                } else {
                    self.trace.setPendingRetAnchor(.{
                        .proto = proto,
                        .resume_pc = trace.entryPc(anchor_pc),
                        .base = base,
                        .call_seq = self.frames[self.depth - 1].call_seq,
                        .force_ordinary = true,
                    });
                }
                return .{ .switch_mode_at = pc };
            }
        }
        // Doc 45 D6.1 (native safety net, one-shot flavor — codex-reviewed):
        // under `--jit-native`, a one-shot candidate that cannot run natively
        // (`nativeFor == null`, e.g. a precise trace — the native acceptance
        // checklist is loop-anchor-only) is NEVER entered on tier-1a: per-call
        // one-shot entries have no iteration amortization, so tier-1a entry +
        // receipt + (for precise) snapshot materialization is a strict loss vs
        // the tier-0 body (binary-trees: 1.32M such entries cost +40% wall).
        // A declined candidate is indistinguishable from an unselected one —
        // no receipts, no accounting. Loop-anchor patched entries are
        // untouched (a budget-bailed precise LOOP trace amortizes tier-1a
        // over its iterations and has nowhere else to run — codex point 9).
        const native_mode = self.trace.config.native_codegen;
        // Memo eligibility: stays true only while EVERY visited candidate was
        // a native-unsupported decline (any real entry or steering kills it).
        var all_nonnative_declines = one_shot and native_mode;
        // Doc 44 D9: quiet-first for one-shot anchors (head + cont, D12b) —
        // the lean episode when nothing that could observe or steer it is
        // live; the full path otherwise. (`enterHeadNativeQuiet` is
        // anchor-exact throughout: every receipt/evidence call keys on
        // `ct.code.anchor`, and cont pages never emit the push epilogue.)
        var directive: EntryDirective = undefined;
        if (one_shot and native_mode and self.trace.nativeFor(ct) == null) {
            self.trace.dbg("one-shot native-unsupported decline: trace={d}", .{ct.id});
            directive = .next_candidate;
        } else if (one_shot) {
            all_nonnative_declines = false;
            directive = if (self.headEpisodeQuiet(ct)) |nt|
                self.enterHeadNativeQuiet(ct, nt, closure, proto, regs, base)
            else
                self.enterSelectedTrace(mode, ct, closure, proto, regs, base, pc, &wctx);
        } else {
            directive = self.enterSelectedTrace(mode, ct, closure, proto, regs, base, pc, &wctx);
        }
        // Doc 44 D10: a fused burst entered several owners — exclude them
        // from re-selection this walk.
        if (one_shot) {
            self.mergeHeadBurstVisited(visited[0..], &nvisited);
            wctx.visited = visited[0..nvisited];
        }
        // Doc 44 D8 (P1a): the one-shot sibling walk. On a zero exit from the
        // incumbent, try the EXACT anchor's other traces —
        // `nextTraceExcluding` is the same deterministic selection the loop
        // walk uses (highest hit_count, registry insertion order as
        // tiebreak). Each candidate's entry is coherent (a one-shot guard
        // fail leaves regs untouched at the entry pc). Removal stays safe
        // mid-walk: `removeTrace` is cache-scan-guarded (idempotent), and
        // every candidate is selected from the LIVE cache immediately before
        // entry.
        var walk_truncated = false;
        if (one_shot) {
            while (directive == .next_candidate) {
                if (nvisited >= trial_visited_cap) {
                    // Capacity: unvisited siblings may remain — all-declined
                    // strike semantics require all-visited (review round 2).
                    walk_truncated = self.trace.nextTraceExcluding(proto, anchor_pc, visited[0..nvisited]) != null;
                    break;
                }
                const sib = self.trace.nextTraceExcluding(proto, anchor_pc, visited[0..nvisited]) orelse break;
                visited[nvisited] = sib;
                nvisited += 1;
                wctx.visited = visited[0..nvisited];
                // D6.1: same native safety net per sibling — a compiled
                // sibling after an unsupported incumbent still gets tried
                // (the decline leaves `.next_candidate`, so the walk moves
                // on rather than refusing the whole anchor).
                if (native_mode and self.trace.nativeFor(sib) == null) {
                    self.trace.dbg("one-shot native-unsupported decline: trace={d}", .{sib.id});
                    continue;
                }
                all_nonnative_declines = false;
                // D9: each sibling retries the quiet path — a prior zero
                // exit's penalty insert correctly forces the full path.
                directive = if (self.headEpisodeQuiet(sib)) |nt|
                    self.enterHeadNativeQuiet(sib, nt, closure, proto, regs, base)
                else
                    self.enterSelectedTrace(mode, sib, closure, proto, regs, base, pc, &wctx);
                // Doc 44 D10: merge this entry's fused-burst owners too.
                self.mergeHeadBurstVisited(visited[0..], &nvisited);
                wctx.visited = visited[0..nvisited];
            }
            // Doc 44 D8: every candidate declined this activation — consume a
            // standing sibling want on the CURRENT activation (review round
            // 2's reframe): transfer it into the kind-matching pending
            // (`pending_call_anchor` for a head, `pending_ret_anchor` for a
            // cont — D12b) pinned to this frame's `call_seq` and park through
            // the `.full` prologue, so the matching consumer arms at the
            // entry pc of the very activation whose path just failed every
            // candidate. EXACT-key match (round 6 change 4). Transfer rules:
            // never while a recording is active or another pending exists;
            // re-check the gate.
            if (directive == .next_candidate) {
                if (self.trace.wants_head_sibling) |wanted| {
                    if (wanted.proto == proto and wanted.pc == anchor_pc and
                        !self.trace.isRecording() and self.trace.pending_call_anchor == null and
                        self.trace.pending_ret_anchor == null and
                        !self.trace.recordingBarred(wanted))
                    {
                        self.trace.wants_head_sibling = null;
                        const src = self.trace.head_want_src;
                        self.trace.head_want_src = null;
                        self.trace.dbg("head-want transfer: arming sibling recording on current activation (src t={?})", .{if (src) |s| s.trace_id else null});
                        if (is_head) {
                            self.trace.setPendingCallAnchor(.{
                                .proto = proto,
                                .base = base,
                                .call_seq = self.frames[self.depth - 1].call_seq,
                            });
                        } else {
                            self.trace.setPendingRetAnchor(.{
                                .proto = proto,
                                .resume_pc = trace.entryPc(anchor_pc),
                                .base = base,
                                .call_seq = self.frames[self.depth - 1].call_seq,
                            });
                        }
                        directive = .{ .switch_mode_at = pc };
                    }
                }
            }
        }
        // A patched entry has no back-edge sibling walk. If a zero-progress
        // exit made a LOOP side want hot, consume it at the coherent header
        // now; otherwise the back-edge arm is one iteration late and records
        // the old shape again. (Loop anchors only — one-shot wants are
        // consumed above.)
        if (!one_shot and directive == .next_candidate and self.trace.consumeSideTraceWantAtResume(proto, @intCast(pc))) {
            directive = if (mode == .fast)
                .{ .switch_mode_at = pc }
            else
                .{ .resume_tier0 = pc };
        }
        // §R6-1/§R7-1 strict order: inspect the stable slot before the drain,
        // mark strike exhaustion, retire dead traces, drain the entire pending
        // set, then never touch `patch` again (the slot may have been reused).
        // D6.1 memo: a FULL walk that declined every candidate as
        // native-unsupported (nothing entered, nothing steered, not
        // truncated) short-circuits future `opJFuncHead`/`opJCont` entries to
        // the canonical tier-0 instruction until the next cache mutation
        // (`cache_gen` bump — a later native-capable sibling reopens the
        // walk). The patch itself stays installed: unpatching would churn
        // through `maybeRepatchHead`/`maybeRepatchCont`, which reinstall
        // without a native-support check.
        // A1' guard: while an ordinary probe is outstanding at this anchor
        // (transfer conditions above didn't hold this entry — e.g. a recording
        // was in flight), the memo must NOT arm: the fast path would bypass
        // this walk and the probe could never fire again. The probe resolves
        // (commit / barred / full) in bounded time, re-opening the memo.
        if (patch.live and all_nonnative_declines and !walk_truncated and
            directive == .next_candidate and
            !self.trace.ordinaryProbeNeeded(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id }))
        {
            patch.native_decline_gen = self.trace.registry.cache_gen;
            self.trace.dbg("one-shot native-decline memo: anchor pc={d} gen={d}", .{ anchor_pc, patch.native_decline_gen });
        }
        if (patch.live) {
            if (directive == .next_candidate) {
                // Doc 44 D8 (review round 2 blocker 1): a one-shot patch
                // accrues NO retirement strikes while the EXACT anchor is
                // below sibling capacity or the walk truncated —
                // `patch_strikes (4) < hotexit (10)` would retire the SOLE
                // entry before any exit could ever get hot, reproducing the
                // P0 coverage collapse. At capacity, with every sibling
                // visited, ordinary strikes resume.
                const head_retention = one_shot and (walk_truncated or
                    self.trace.countTracesAt(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id }) < self.trace.config.max_traces_per_anchor);
                if (!head_retention) {
                    patch.strikes +|= 1;
                    if (patch.strikes >= self.trace.config.patch_strikes)
                        self.trace.markEntryPatchPending(slot);
                }
            } else {
                patch.strikes = 0;
            }
        }
        dead.retire(&self.trace);
        self.trace.drainEntryPatchWork();
        return directive;
    }

    /// Doc 42: one `execImpl` invocation = build the chain state on THIS
    /// frame, enter the handler chain with an ordinary call, and translate its
    /// register-sized result back into `Error!ExecStep` (re-raising a parked
    /// error as a real Zig error, so `execWith`'s errdefers and every
    /// enclosing pcall behave exactly as before). The old labeled-switch loop
    /// is gone: control flow lives in the per-op handlers below, threaded by
    /// `@call(.always_tail)` through `dispatchTail`. Mode switches and
    /// suspension keep their old shape — the chain returns, this state dies,
    /// and the next invocation reloads from `CallFrame`.
    fn execImpl(self: *Vm, comptime mode: ExecMode, stop_depth: u32) Error!ExecStep {
        const frame = &self.frames[self.depth - 1];
        const proto = frame.closure.proto;
        var st: ExecState = .{
            .vm = self,
            .frame = frame,
            .closure = frame.closure,
            .proto = proto,
            .code = self.cachedCodeFor(frame, proto), // doc 20 image
            .code_gen = self.trace.registry.entry_registry.image_gen,
            .base = frame.base,
            .regs = self.frameWindow(frame.base, proto.num_registers),
            .stop_depth = stop_depth,
            .step = undefined,
            .err = null,
        };
        self.trace.setRegionContext(self.depth, frame.call_seq);
        switch (@call(.never_inline, chainEntry(mode), .{ &st, frame.pc, undefined, self, st.regs.tags, st.regs.payloads })) {
            .finished => return st.step,
            .suspended => return .suspended,
            .switch_mode => return .switch_mode,
            .err => return st.err.?,
        }
    }

    /// Doc 42 §4.5: the op → handler map, one entry per opcode; the comptime
    /// density assert in `bytecode.zig` keeps this and the table index in
    /// lockstep. The handler bodies are the old `execImpl` arms moved verbatim
    /// under the five mechanical translation rules (§4.5): error edge → park;
    /// `continue :sw` → tail-dispatch; push/pop reload → `reloadTopFrame` +
    /// dispatch; resume-only → tail-dispatch at the resume pc (no re-resolve);
    /// `break :sw` → musttail into `backEdgeHandler`.
    fn handlerFor(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        return switch (op) {
            .load_nil, .load_bool, .load_int, .load_const, .move => opLoad(mode, op),
            .add, .sub, .mul, .add_rk, .sub_rk, .mul_rk, .add_kr, .sub_kr, .mul_kr => opBinNum(mode, op),
            .div, .div_rk, .div_kr => opDiv(mode, op),
            .idiv, .mod, .idiv_rk, .mod_rk, .idiv_kr, .mod_kr => opModIdiv(mode, op),
            .pow, .pow_rk, .pow_kr => opPow(mode, op),
            .band, .bor, .bxor, .shl, .shr, .sar, .band_rk, .bor_rk, .bxor_rk, .shl_rk, .shr_rk => opBinBit(mode, op),
            .neg => opNeg(mode),
            .not => opNot(mode),
            .bnot => opBnot(mode),
            .len => opLen(mode),
            .concat => opConcat(mode),
            .eq, .ne => opEqNe(mode, op),
            .eq_p, .ne_p => opEqP(mode, op),
            .eq_s, .ne_s => opEqS(mode, op),
            .eq_n, .ne_n => opEqN(mode, op),
            .lt, .le, .gt, .ge => opCompare(mode, op),
            .jlt, .jle, .jgt, .jge, .jlt_k, .jle_k, .jgt_k, .jge_k => opJOrder(mode, op),
            .jeq, .jeq_p, .jeq_s, .jeq_n => opJEq(mode, op),
            .jmp, .jmp_if_false, .jmp_if_true, .jmp_if_not_nil => opJump(mode, op),
            .for_prep => opForPrep(mode),
            .for_loop => opForLoop(mode),
            .jfor_loop => opJForLoop(mode),
            .jloop => opJLoop(mode),
            .jfunc_head => opJFuncHead(mode),
            .jcont => opJCont(mode),
            .tfor_loop => opTForLoop(mode),
            .itern => opItern(mode),
            .new_table => opNewTable(mode),
            .get_index => opGetIndex(mode),
            .set_index => opSetIndex(mode),
            .get_field => opGetField(mode),
            .set_field => opSetField(mode),
            .get_index2 => opGetIndex2(mode),
            .set_index2 => opSetIndex2(mode),
            .get_global => opGetGlobal(mode),
            .set_global => opSetGlobal(mode),
            .closure => opClosure(mode),
            .get_upval => opGetUpval(mode),
            .set_upval => opSetUpval(mode),
            .close_upvalues => opCloseUpvalues(mode),
            .loop => opLoop(mode),
            .call => opCall(mode),
            .ret, .halt => opRet(mode),
            .vararg_first => opVarargFirst(mode),
            .vararg_len => opVarargLen(mode),
            .vararg_get => opVarargGet(mode),
            .vararg_spread => opVarargSpread(mode),
        };
    }

    // ---- loads & moves ---- (direct lane writes; no `Value` built)
    fn opLoad(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const a: usize = instr.a;
                switch (op) {
                    .load_nil => regs.setNil(a),
                    .load_bool => regs.setBool(a, instr.b != 0),
                    .load_int => regs.setInt(a, instr.aux),
                    .load_const => regs.set(a, st.proto.constants[instr.b]),
                    .move => regs.copy(a, instr.b),
                    else => unreachable,
                }
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // ---- arithmetic (semantics live in arith.zig) ----
    // The hot both-int / both-float cases compute on the raw payload lanes
    // directly (no 16-byte `Value` materialized — the SoA win); every other
    // operand mix falls back to the exact `arith.*` + `arithMeta` path (mixed
    // promotion, `__add`/… metamethod, or a propagated error like
    // `DivisionByZero`). Numbers carry no metatable, so the common path never
    // touches dispatch. Doc 66 P3: each handler is built per opcode, register
    // form and constant forms alike, and reads its operands through
    // `arithOperands`; the lanes are the same for every shape.

    /// Doc 66 P3: an arithmetic or bitwise instruction's operands in source
    /// order, as raw lanes. The register form reads `R[b]` and `R[c]`; a
    /// constant form reads `R[b]` and the number constant `K[c]` on the side
    /// its shape names. The tags are read up front; the payloads stay behind
    /// pointers so each lane loads only what it uses, straight into the
    /// register it computes in (a float lane's load folds into `vdivsd`
    /// instead of passing through a general register: 3 instructions on `/`).
    /// Every lane reads its operands before it writes `R[a]`, which may be
    /// either of them.
    const ArithOperands = struct {
        lt: value.Tag,
        rt: value.Tag,
        lp: *const u64,
        rp: *const u64,

        inline fn lb(self: ArithOperands) u64 {
            return self.lp.*;
        }

        inline fn rb(self: ArithOperands) u64 {
            return self.rp.*;
        }

        inline fn lhs(self: ArithOperands) Value {
            return .{ .tag = self.lt, .payload = .{ .bits = self.lb() } };
        }

        inline fn rhs(self: ArithOperands) Value {
            return .{ .tag = self.rt, .payload = .{ .bits = self.rb() } };
        }

        inline fn bothInt(self: ArithOperands) bool {
            return self.lt == .int and self.rt == .int;
        }

        inline fn bothFloat(self: ArithOperands) bool {
            return self.lt == .float and self.rt == .float;
        }

        inline fn bothNumber(self: ArithOperands) bool {
            return (self.lt == .int or self.lt == .float) and (self.rt == .int or self.rt == .float);
        }

        /// A number operand as a float, as `Value.toFloat` converts it.
        inline fn lhsFloat(self: ArithOperands) f64 {
            return laneFloat(self.lt, self.lb());
        }

        inline fn rhsFloat(self: ArithOperands) f64 {
            return laneFloat(self.rt, self.rb());
        }

        /// The operands the other way round: `x > y` is `y < x`.
        inline fn swapped(self: ArithOperands) ArithOperands {
            return .{ .lt = self.rt, .rt = self.lt, .lp = self.rp, .rp = self.lp };
        }
    };

    inline fn laneFloat(t: value.Tag, bits: u64) f64 {
        return if (t == .int) @floatFromInt(@as(i64, @bitCast(bits))) else @bitCast(bits);
    }

    inline fn arithOperands(comptime shape: bytecode.ArithShape, st: *const ExecState, regs: RegWindow, instr: *const Instr) ArithOperands {
        switch (shape) {
            .rr => return .{ .lt = regs.tagAt(instr.b), .rt = regs.tagAt(instr.c), .lp = &regs.payloads[instr.b], .rp = &regs.payloads[instr.c] },
            .rk => {
                const k = &st.proto.constants[instr.c];
                return .{ .lt = regs.tagAt(instr.b), .rt = k.tag, .lp = &regs.payloads[instr.b], .rp = &k.payload.bits };
            },
            .kr => {
                const k = &st.proto.constants[instr.c];
                return .{ .lt = k.tag, .rt = regs.tagAt(instr.b), .lp = &k.payload.bits, .rp = &regs.payloads[instr.b] };
            },
        }
    }

    /// `arith`'s operation for register-form operator `base`.
    inline fn arithRaw(comptime base: bytecode.OpCode, lhs: Value, rhs: Value) arith.Error!Value {
        return switch (base) {
            .add => arith.add(lhs, rhs),
            .sub => arith.sub(lhs, rhs),
            .mul => arith.mul(lhs, rhs),
            .div => arith.div(lhs, rhs),
            .idiv => arith.floorDiv(lhs, rhs),
            .mod => arith.mod(lhs, rhs),
            .pow => arith.pow(lhs, rhs),
            .band => arith.band(lhs, rhs),
            .bor => arith.bor(lhs, rhs),
            .bxor => arith.bxor(lhs, rhs),
            .shl => arith.shl(lhs, rhs),
            .shr => arith.shr(lhs, rhs),
            .sar => arith.sar(lhs, rhs),
            else => comptime unreachable,
        };
    }

    /// `R[a] = lhs op rhs` through `arith` and the operator's metamethod:
    /// every handler's last resort.
    inline fn arithGeneric(self: *Vm, comptime base: bytecode.OpCode, regs: RegWindow, a: usize, o: ArithOperands) Error!void {
        const lhs = o.lhs();
        const rhs = o.rhs();
        regs.set(a, try self.arithMeta(arithRaw(base, lhs, rhs), @field(self.mm, @tagName(base)), lhs, rhs));
    }

    /// `+`, `-`, `*`: both-int (wrapping) and both-float lanes, then the
    /// mixed one (both as floats, as `arith.add` computes it), then `arith`.
    fn opBinNum(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.arithFormOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                vm.binNum(regs, instr.a, arithOperands(f.shape, st, regs, instr), f.base) catch |e| return parkErr(st, e);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `/`: always a float, so any two numbers divide on the lanes.
    fn opDiv(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.arithFormOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const o = arithOperands(f.shape, st, regs, instr);
                @setFloatMode(.strict);
                if (o.bothFloat()) {
                    regs.setFloat(instr.a, @as(f64, @bitCast(o.lb())) / @as(f64, @bitCast(o.rb())));
                } else if (o.bothNumber()) {
                    regs.setFloat(instr.a, o.lhsFloat() / o.rhsFloat());
                } else {
                    vm.arithGeneric(.div, regs, instr.a, o) catch |e| return parkErr(st, e);
                }
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `^`: always a float, through the one `fmath.powRuntime` kernel
    /// `arith.pow` uses, so any two numbers take the lane.
    fn opPow(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.arithFormOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const o = arithOperands(f.shape, st, regs, instr);
                if (o.bothNumber()) {
                    regs.setFloat(instr.a, fmath.powRuntime(o.lhsFloat(), o.rhsFloat()));
                } else {
                    vm.arithGeneric(.pow, regs, instr.a, o) catch |e| return parkErr(st, e);
                }
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// The `arith.* → arithMeta` path on its own: `opModIdivSlow`'s last
    /// resort.
    fn opArithMeta(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.arithFormOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                vm.arithGeneric(f.base, regs, instr.a, arithOperands(f.shape, st, regs, instr)) catch |e| return parkErr(st, e);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `%` and `//` on two ints, on the raw lanes, with `arith.mod`'s and
    /// `arith.floorDiv`'s exact `-1` cases (`minInt // -1` wraps to
    /// `minInt`; neither reaches the trapping `idiv`). A zero divisor (which
    /// raises), floats and everything else leave for `opModIdivSlow`. The
    /// float lane lives there because its kernel call cost the int lane
    /// 8 instructions when it sat here.
    fn opModIdiv(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.arithFormOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const o = arithOperands(f.shape, st, regs, instr);
                if (o.bothInt()) {
                    const x: i64 = @bitCast(o.lb());
                    const y: i64 = @bitCast(o.rb());
                    if (y != 0) {
                        regs.setInt(instr.a, switch (f.base) {
                            .mod => if (y == -1) 0 else @mod(x, y),
                            .idiv => if (y == -1) 0 -% x else @divFloor(x, y),
                            else => comptime unreachable,
                        });
                        return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                    }
                }
                return slowTail(mode, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    /// `opModIdiv`'s slow half: two numbers that are not both ints (so the
    /// result is a float) through the same `fmath` kernels `arith.mod`/
    /// `arith.floorDiv` use, everything else through `opArithMeta` (the
    /// zero-divisor error, `__mod`/`__idiv`).
    fn opModIdivSlow(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.arithFormOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const o = arithOperands(f.shape, st, regs, instr);
                if (o.bothNumber() and !o.bothInt()) {
                    const x = o.lhsFloat();
                    const y = o.rhsFloat();
                    regs.setFloat(instr.a, switch (f.base) {
                        .mod => fmath.fmodRuntime(x, y),
                        .idiv => fmath.floordivRuntime(x, y),
                        else => comptime unreachable,
                    });
                    return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                }
                return @call(.always_tail, opArithMeta(mode, op), .{ st, pc, instr, vm, tags, payloads });
            }
        }.h;
    }

    // ---- bitwise ---- (both-int fast lane; else `arith.*` + meta)
    fn opBinBit(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.arithFormOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const o = arithOperands(f.shape, st, regs, instr);
                if (o.bothInt()) {
                    const x: i64 = @bitCast(o.lb());
                    const y: i64 = @bitCast(o.rb());
                    regs.setInt(instr.a, switch (f.base) {
                        .band => x & y,
                        .bor => x | y,
                        .bxor => x ^ y,
                        .shl => arith.shiftLeft(x, y),
                        .shr => arith.shiftRight(x, y),
                        .sar => arith.shiftRightArith(x, y),
                        else => comptime unreachable,
                    });
                } else {
                    vm.arithGeneric(f.base, regs, instr.a, o) catch |e| return parkErr(st, e);
                }
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // ---- unary ----
    fn opNeg(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const self = vm;
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const a: usize = instr.a;
                switch (regs.tagAt(instr.b)) {
                    .int => regs.setInt(a, 0 -% @as(i64, @bitCast(regs.bitsAt(instr.b)))),
                    .float => {
                        @setFloatMode(.strict);
                        regs.setFloat(a, -@as(f64, @bitCast(regs.bitsAt(instr.b))));
                    },
                    else => {
                        const v = regs.get(instr.b);
                        regs.set(a, self.unArithMeta(arith.neg(v), self.mm.unm, v) catch |e| return parkErr(st, e));
                    },
                }
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opNot(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                regs.setBool(instr.a, !regs.get(instr.b).isTruthy());
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opBnot(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const self = vm;
                const v = regs.get(instr.b);
                regs.set(instr.a, self.unArithMeta(arith.bnot(v), self.mm.bnot, v) catch |e| return parkErr(st, e));
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `#t` honours `__len` for tables; strings/raw-length fall through.
    fn opLen(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                // Inline string fast path: `#s` is a cached-field read
                // (`cp_len`, S-B) and strings can't carry `__len`, so the
                // outlined `lenValue` call — whose error-union struct return
                // alone measured ~86 cycles/op via a store-forward stall
                // (str_gmatch profile, 2026-08-29: 20% of the bench) — is pure
                // overhead here. Tables (metamethod dispatch), row views, and
                // error cases keep the slow path.
                const v = regs.get(instr.b);
                if (v.isHeap() and v.heapType() == .string) {
                    regs.setInt(instr.a, @intCast(string.String.fromHeader(v.asHeap()).cpLen()));
                } else {
                    regs.set(instr.a, vm.lenValue(v) catch |e| return parkErr(st, e));
                }
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // ---- concat ---- `__concat` on `TypeError` (a non-concatable operand);
    // the located fault is preserved when neither has one.
    fn opConcat(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const self = vm;
                const lhs = regs.get(instr.b);
                const rhs = regs.get(instr.c);
                regs.set(instr.a, self.concat(lhs, rhs) catch |e| switch (e) {
                    Error.TypeError => self.binMeta(self.mm.concat, lhs, rhs, Error.TypeError) catch |e2| return parkErr(st, e2),
                    else => return parkErr(st, e),
                });
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // ---- comparisons → boolean register ----
    // `eq`/`ne` decide two same-tag primitives, or two heap values that are
    // the same object or not both tables, on the raw lanes (`Value.eql`:
    // strings are interned, so identity is equality). Mixed numbers, two
    // distinct tables (`__eq`) and row views leave for `opEqNeSlow`.
    fn opEqNe(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const l = eqLanes(regs, instr.b, instr.c);
                if (l == .slow) return slowTail(mode, st, pc, instr, vm, tags, payloads);
                const eqv = l == .yes;
                regs.setBool(instr.a, if (op == .eq) eqv else !eqv);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opEqNeSlow(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const eqv = vm.valuesEqual(regs.get(instr.b), regs.get(instr.c)) catch |e| return parkErr(st, e);
                regs.setBool(instr.a, if (op == .eq) eqv else !eqv);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // Doc 66 P5: equality against a constant (LuaJIT `ISEQP`/`ISEQS`/
    // `ISEQN`). A constant is never a table, so `__eq` cannot fire and each
    // handler decides every operand on its own, with no slow half; each is
    // exactly `Value.eql` against the constant.

    /// `eq_p`/`ne_p`: nil by its tag, a boolean by tag and truth (`asBool`).
    fn opEqP(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const negate = comptime bytecode.eqFormOf(op).?.negate;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const eqv = eqPrimLane(regs, instr.b, instr.c);
                regs.setBool(instr.a, eqv != negate);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `eq_s`/`ne_s`: strings are interned, so a string equals the constant
    /// exactly when it is the same object.
    fn opEqS(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const negate = comptime bytecode.eqFormOf(op).?.negate;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const eqv = eqStrLane(regs, instr.b, &st.proto.constants[instr.c]);
                regs.setBool(instr.a, eqv != negate);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `eq_n`/`ne_n`: the same number type on the raw lanes (a float
    /// compares as IEEE, so NaN is unequal and `-0.0 == 0.0`), anything but
    /// a number unequal; the other number type leaves for `opEqNSlow`, so the
    /// common lanes keep a frame with no callee-saved registers.
    fn opEqN(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const negate = comptime bytecode.eqFormOf(op).?.negate;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const l = eqNumLane(regs, instr.b, &st.proto.constants[instr.c]);
                if (l == .slow) return slowTail(mode, st, pc, instr, vm, tags, payloads);
                regs.setBool(instr.a, (l == .yes) != negate);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `opEqN`'s slow half: an int against a float constant or a float
    /// against an int one, compared exactly (`compareNumeric`, `1 == 1.0`).
    fn opEqNSlow(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const negate = comptime bytecode.eqFormOf(op).?.negate;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const eqv = value.compareNumeric(regs.get(instr.b), st.proto.constants[instr.c]) == .eq;
                regs.setBool(instr.a, eqv != negate);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // `gt`/`ge` reuse `lt`/`le` with operands swapped (a>b ≡ b<a). Two ints
    // or two floats compare on the raw lanes (`value.compareNumeric` is
    // exactly IEEE order there); a mixed pair, strings and `__lt`/`__le`
    // leave for `opCompareSlow`.
    fn opCompare(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const o = arithOperands(.rr, st, regs, instr);
                const l = orderLanes(op == .lt or op == .gt, if (op == .gt or op == .ge) o.swapped() else o);
                if (l == .slow) return slowTail(mode, st, pc, instr, vm, tags, payloads);
                regs.setBool(instr.a, l == .yes);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opCompareSlow(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const self = vm;
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const raw = switch (op) {
                    .lt => self.compareMeta(.lt, regs.get(instr.b), regs.get(instr.c)),
                    .le => self.compareMeta(.le, regs.get(instr.b), regs.get(instr.c)),
                    .gt => self.compareMeta(.lt, regs.get(instr.c), regs.get(instr.b)),
                    .ge => self.compareMeta(.le, regs.get(instr.c), regs.get(instr.b)),
                    else => unreachable,
                };
                regs.setBool(instr.a, raw catch |e| return parkErr(st, e));
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // Doc 66 P4/P5: the raw lanes of `==` and of the order relations, one
    // definition for the value forms and the compare-and-branch forms.

    /// A lane's verdict: decided, or the operands need the op's slow half.
    /// An enum, not a `?bool`: LLVM keeps it in a register, where an
    /// optional result went through the stack and cost the value forms 3–5
    /// instructions.
    const Lane = enum(u8) {
        no = 0,
        yes = 1,
        slow = 2,

        inline fn of(b: bool) Lane {
            return @enumFromInt(@intFromBool(b));
        }
    };

    /// `R[b] == R[c]` when both have the same type, and unequal across
    /// types other than two numbers; slow for an int against a float, two
    /// distinct tables (`__eq`) and a row view.
    inline fn eqLanes(regs: RegWindow, b: u16, c: u16) Lane {
        const tb = regs.tagAt(b);
        const tc = regs.tagAt(c);
        const pb = regs.bitsAt(b);
        const pc_ = regs.bitsAt(c);
        if (tb == tc) return switch (tb) {
            .int => Lane.of(pb == pc_),
            .float => blk: {
                @setFloatMode(.strict);
                break :blk Lane.of(@as(f64, @bitCast(pb)) == @as(f64, @bitCast(pc_)));
            },
            .nil => .yes,
            .boolean => Lane.of((pb != 0) == (pc_ != 0)),
            .heap_ref => blk: {
                // Through the payload union, not `@ptrFromInt`: a
                // pointer is narrower than the 64-bit word on wasm32.
                const x = (Value{ .tag = .heap_ref, .payload = .{ .bits = pb } }).asHeap();
                const y = (Value{ .tag = .heap_ref, .payload = .{ .bits = pc_ } }).asHeap();
                if (x.id == y.id) break :blk .yes;
                if (x.type == .table and y.type == .table) break :blk .slow;
                break :blk .no;
            },
            .row_view => .slow,
        };
        if ((tb == .int or tb == .float) and (tc == .int or tc == .float)) return .slow;
        return .no;
    }

    /// `R[b]` against the `Prim` immediate `c`: nil by its tag, a boolean by
    /// tag and truth (`asBool`).
    inline fn eqPrimLane(regs: RegWindow, b: u16, c: u16) bool {
        const t = regs.tagAt(b);
        return switch (@as(bytecode.Prim, @enumFromInt(c))) {
            .nil => t == .nil,
            .@"false" => t == .boolean and regs.bitsAt(b) == 0,
            .@"true" => t == .boolean and regs.bitsAt(b) != 0,
        };
    }

    /// `R[b]` against an interned string constant: strings are interned, so
    /// a string equals it exactly when it is the same object.
    inline fn eqStrLane(regs: RegWindow, b: u16, k: *const Value) bool {
        // Through the payload union, not `@ptrFromInt`: a pointer is
        // narrower than the 64-bit word on wasm32.
        return regs.tagAt(b) == .heap_ref and
            (Value{ .tag = .heap_ref, .payload = .{ .bits = regs.bitsAt(b) } }).asHeap() == k.asHeap();
    }

    /// `R[b]` against a number constant: the same number type on the raw
    /// lanes (a float compares as IEEE, so NaN is unequal and
    /// `-0.0 == 0.0`), anything but a number unequal; slow for the other
    /// number type.
    inline fn eqNumLane(regs: RegWindow, b: u16, k: *const Value) Lane {
        const t = regs.tagAt(b);
        if (t == k.tag) {
            if (t == .int) return Lane.of(regs.bitsAt(b) == k.payload.bits);
            @setFloatMode(.strict);
            return Lane.of(@as(f64, @bitCast(regs.bitsAt(b))) == @as(f64, @bitCast(k.payload.bits)));
        }
        if (t == .int or t == .float) return .slow;
        return .no;
    }

    /// `lhs < rhs` (`strict`) or `lhs <= rhs` over two ints or two floats
    /// (`value.compareNumeric` is exactly IEEE order there); slow for a
    /// mixed pair, strings and `__lt`/`__le`.
    inline fn orderLanes(comptime strict: bool, o: ArithOperands) Lane {
        if (o.bothInt()) {
            const p: i64 = @bitCast(o.lb());
            const q: i64 = @bitCast(o.rb());
            return Lane.of(if (strict) p < q else p <= q);
        }
        if (o.bothFloat()) {
            @setFloatMode(.strict);
            const p: f64 = @bitCast(o.lb());
            const q: f64 = @bitCast(o.rb());
            return Lane.of(if (strict) p < q else p <= q);
        }
        return .slow;
    }

    // ---- compare-and-branch (doc 66 P4) ----
    // Each is its value form's lanes followed by a jump instead of a
    // register write: `holds` against the polarity in `a`. The slow halves
    // run the full relation, metamethods included.

    /// Jump when the comparison's outcome is the instruction's polarity.
    inline fn cmpBranchTail(comptime mode: ExecMode, st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, holds: bool) HandlerResult {
        const npc = if (holds == (instr.a & bytecode.cmp_on_true != 0)) applyJump(pc, instr.aux) else pc;
        return dispatchTail(mode, st, npc, vm);
    }

    /// An ordered compare-and-branch's operands in relation order: `R[b]`
    /// and `R[c]` or `K[c]`, swapped for `>`/`>=`.
    inline fn orderOperands(comptime f: bytecode.CmpForm, st: *const ExecState, regs: RegWindow, instr: *const Instr) ArithOperands {
        const o = arithOperands(if (f.rhs == .reg) .rr else .rk, st, regs, instr);
        return if (f.rel == .gt or f.rel == .ge) o.swapped() else o;
    }

    fn opJOrder(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.cmpBranchOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const l = orderLanes(f.rel == .lt or f.rel == .gt, orderOperands(f, st, regs, instr));
                if (l == .slow) return slowTail(mode, st, pc, instr, vm, tags, payloads);
                return cmpBranchTail(mode, st, pc, instr, vm, l == .yes);
            }
        }.h;
    }

    fn opJOrderSlow(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.cmpBranchOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const o = orderOperands(f, st, regs, instr);
                const raw = if (f.rel == .lt or f.rel == .gt)
                    vm.compareMeta(.lt, o.lhs(), o.rhs())
                else
                    vm.compareMeta(.le, o.lhs(), o.rhs());
                return cmpBranchTail(mode, st, pc, instr, vm, raw catch |e| return parkErr(st, e));
            }
        }.h;
    }

    fn opJEq(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.cmpBranchOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const l: Lane = switch (f.rhs) {
                    .reg => eqLanes(regs, instr.b, instr.c),
                    .prim => Lane.of(eqPrimLane(regs, instr.b, instr.c)),
                    .str => Lane.of(eqStrLane(regs, instr.b, &st.proto.constants[instr.c])),
                    .num => eqNumLane(regs, instr.b, &st.proto.constants[instr.c]),
                };
                if (l == .slow) return slowTail(mode, st, pc, instr, vm, tags, payloads);
                return cmpBranchTail(mode, st, pc, instr, vm, l == .yes);
            }
        }.h;
    }

    /// `jeq`'s and `jeq_n`'s slow halves: `__eq` for two tables, and an
    /// int against a float compared exactly (`1 == 1.0`).
    fn opJEqSlow(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        const f = comptime bytecode.cmpBranchOf(op).?;
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const holds = switch (f.rhs) {
                    .reg => vm.valuesEqual(regs.get(instr.b), regs.get(instr.c)) catch |e| return parkErr(st, e),
                    .num => value.compareNumeric(regs.get(instr.b), st.proto.constants[instr.c]) == .eq,
                    .prim, .str => comptime unreachable,
                };
                return cmpBranchTail(mode, st, pc, instr, vm, holds);
            }
        }.h;
    }

    // ---- control flow ----
    // Jumps stay threaded for the *forward* (and not-taken) case — the tail
    // dispatch re-enters the next instruction directly. Only a real loop
    // back-edge (`npc <= cur_pc` while tracing is enabled — exactly the
    // epilogue's guard) musttails into `backEdgeHandler`; when tracing is off
    // the epilogue is inert, so a back-edge threads too. `cur_pc` is this
    // jump's own pc (`pc - 1`), so the test sees the post-jump target.
    fn opJump(comptime mode: ExecMode, comptime op: bytecode.OpCode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                var npc = pc;
                switch (op) {
                    .jmp => npc = applyJump(pc, instr.aux),
                    .jmp_if_false => {
                        if (!regs.get(instr.a).isTruthy()) npc = applyJump(pc, instr.aux);
                    },
                    .jmp_if_true => {
                        if (regs.get(instr.a).isTruthy()) npc = applyJump(pc, instr.aux);
                    },
                    .jmp_if_not_nil => {
                        if (!regs.get(instr.a).isNil()) npc = applyJump(pc, instr.aux);
                    },
                    else => unreachable,
                }
                // Doc 58 §4.2: no jump is a back-edge any more. The only
                // backward jumps the compiler emits are the two loop closers
                // (`while`'s `jmp` to its condition, `repeat`'s `jmp_if_false`
                // to its marker), and the marker is the back-edge that counts
                // the iteration. `for_loop`/`tfor_loop` keep their own.
                return dispatchTail(mode, st, npc, vm);
            }
        }.h;
    }

    // ---- numeric for ----
    // R[a..a+3) = (init, limit, step), as Lua 5.4's `forprep`: validate them,
    // raise on a zero step, and test the first index (`arith.forFirstIndex`,
    // a float unless init and step are both ints) against the limit. If the
    // loop runs, publish it to R[a] and the loop variable R[a+3] and enter the
    // body at `pc`; else jump past the `for_loop` (`aux` targets the
    // `for_loop`). No pre-subtracted index: `init - step` can wrap, which made
    // a real overflow in `for_loop` indistinguishable from the first add
    // undoing it, and is inexact for floats. Entering the body takes the
    // back-edge path the first `for_loop` used to: the header's hot count,
    // trip gate and trace entry see the first iteration, as before — through
    // the patched entry when the `for_loop` is patched (`patchedForEntry`).
    fn opForPrep(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const a: usize = instr.a;
                const limit = regs.get(a + 1);
                const step = regs.get(a + 2);
                if (!regs.get(a).isNumber() or !limit.isNumber() or !step.isNumber()) {
                    return parkErr(st, Error.TypeError);
                }
                if (arith.forStepIsZero(step)) return parkErr(st, Error.ForStepZero);
                const first = arith.forFirstIndex(regs.get(a), step);
                if (!arith.forWithin(first, limit, step))
                    return dispatchTail(mode, st, applyJump(pc, instr.aux) + 1, vm);
                regs.set(a, first);
                regs.set(a + 3, first);
                if (!vm.trace.config.enabled) return dispatchTail(mode, st, pc, vm);
                const fl = &st.code[applyJump(pc, instr.aux)];
                if (fl.op == .jfor_loop) {
                    const slot: u16 = fl.b;
                    const patch = vm.trace.registry.entry_registry.entry_patches.items[slot];
                    const enter = patch.live and !vm.jitSuspended(mode);
                    if (enter) vm.trace.for_prep_patched +|= 1;
                    return patchedForEntry(mode, st, pc, instr, patch, slot, enter, vm, tags, payloads);
                }
                return @call(.always_tail, gatedBackEdgeHandler(mode), .{ st, pc, instr, vm, tags, payloads });
            }
        }.h;
    }

    // idx += step; if still within limit (direction by step sign) and the int
    // add didn't overflow, publish idx to the loop var R[a+3] and take the
    // back-edge.
    fn opForLoop(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const a: usize = instr.a;
                const within = forLoopStep(regs, a) catch |e| return parkErr(st, e);
                const cur_pc = pc - 1;
                var npc = pc;
                if (within) {
                    regs.copy(a + 3, a);
                    npc = applyJump(pc, instr.aux);
                }
                if (vm.trace.config.enabled and npc <= cur_pc)
                    return @call(.always_tail, gatedBackEdgeHandler(mode), .{ st, npc, instr, vm, tags, payloads });
                return dispatchTail(mode, st, npc, vm);
            }
        }.h;
    }

    // Doc 20 Phase 1 (patched trace entry, the BC_JFORL analogue): only ever
    // fetched from a per-VM copy-on-patch code image over a qualified
    // `.for_loop`; canonical `Proto.code` never contains it. §R2-3 discipline:
    // the shared `for_loop` step runs EXACTLY once, and every non-entered
    // back-edge reaches the ordinary epilogue presenting the canonical
    // instruction (`patch.orig`, §R2-5) — no shortcut, no rewind/refetch.
    fn opJForLoop(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr_in: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const self = vm;
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const cur_pc = pc - 1;
                const slot: u16 = instr_in.b;
                const patch = self.trace.registry.entry_registry.entry_patches.items[slot];
                const live = patch.live;
                // Doc 63 §5.9: a suspended handler neither recovers nor enters;
                // it runs the step and takes the virgin path below, whose
                // epilogue is gated too. `patch.orig` stays readable: nothing
                // drains while suspended.
                const suspended = self.jitSuspended(mode);
                if (!live and !suspended) {
                    // §R6-1 pre-step recovery — a LEGITIMATE deferred-unpatch
                    // state, not a defensive-unreachable one (codex
                    // post-landing review of 7fa7e1a): marks can originate
                    // outside any drained grammar — recorder aborts
                    // (`gateAnchor(rec.anchor)`) fire mid-dispatch where
                    // draining would install under a frame that cannot
                    // re-resolve its image pointer, and the walk's
                    // post-epilogue retire/miss/gate sites mark after their
                    // turn's drain. This arm is the sole slot-pointer holder
                    // and sits outside any receipt grammar, so the complete
                    // synchronous unpatch transaction is safe here; then
                    // continue as the virgin `.for_loop` arm (musttail into
                    // the epilogue after the step). `patch.orig` stays
                    // readable through the tombstone: reuse only happens in a
                    // drain's install pass, and none runs between here and the
                    // step.
                    self.trace.unpatchSlot(slot);
                }
                // §R2-5: everything downstream — the epilogue's
                // `instr.op == .for_loop` reads, the recorder mirror — sees
                // the canonical instruction. Same `a`/`aux` operands by
                // construction (install preserves them).
                // Pointer, not a local copy: the musttail chain outlives this
                // handler's frame, so anything passed onward must be
                // frame-independent — `patch.orig` is slot-stable (reuse only
                // happens in a drain's install pass; the epilogue copies what
                // it needs before its drains run).
                const instr = &patch.orig;
                const a: usize = instr.a;
                // The shared numeric-`for` step, exactly once — INCLUDING the
                // internal-index increment, the `.for_loop` arm's first line
                // (omitting it re-takes the back-edge with a stale index: the
                // §R2-3 hazard, caught as +strikes×n guest corruption in the
                // T3 e2e test). `forLoopStep` does the increment.
                const within = forLoopStep(regs, a) catch |e| return parkErr(st, e);
                var npc = pc;
                if (within) {
                    regs.copy(a + 3, a);
                    npc = applyJump(pc, instr.aux);
                }
                // Loop exit → thread exactly as `.for_loop` (the back-edge
                // machinery is never visited — `npc <= cur_pc` is false). A
                // patch exists ⇒ tracing is enabled, so the plain comparison
                // is the same predicate `.for_loop` uses.
                if (!(npc <= cur_pc)) {
                    return dispatchTail(mode, st, npc, vm);
                }
                // Defensive-unpatched: virgin cascade (cold path IS the
                // existing cascade, reached by unpatching BEFORE the step ran
                // above — §R2-3's double-increment hazard avoided). Also the
                // suspended path (doc 63 §5.9).
                return patchedForEntry(mode, st, npc, instr, patch, slot, live and !suspended, vm, tags, payloads);
            }
        }.h;
    }

    /// The patched numeric-`for` entry (doc 20) at the loop header `npc`,
    /// with the iteration's index already published. Shared by `.jfor_loop`
    /// after its step and by a `for_prep` entering the body of a loop whose
    /// `for_loop` is patched: LuaJIT patches FORI to JFORI alongside JFORL
    /// (`lj_trace.c` `trace_stop`), so a loop's first trip enters its trace
    /// the way every later trip does. Through the discovery walk instead, a
    /// first-trip zero-progress exit left a hot side want to the next
    /// `onBackEdge`, one iteration late — recording the parent's own shape
    /// again as a duplicate sibling (euler14-bit). `instr` is the canonical
    /// instruction a bypass presents (`patch.orig`, or the `for_prep`);
    /// `enter` is false when the slot is dead or the JIT suspended.
    inline fn patchedForEntry(
        comptime mode: ExecMode,
        st: *ExecState,
        npc: usize,
        instr: *const Instr,
        patch: *trace.EntryPatch,
        slot: u16,
        enter: bool,
        vm: *Vm,
        tags: [*]u8,
        payloads: [*]u64,
    ) HandlerResult {
        const self = vm;
        const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
        if (!enter) return @call(.always_tail, backEdgeHandler(mode), .{ st, npc, instr, vm, tags, payloads });
        // §R1-5 bypass set — live authoritative fields, no maintained
        // flag: the `runFastPath` `.full` set plus exec-log and
        // coverage. Take the back-edge through the ordinary epilogue
        // with the canonical instruction presented, so recording, coverage
        // attribution, `onBackEdge`, and trace closure all see virgin
        // behaviour.
        if (self.trace.isRecording() or self.suspend_ctl != null or
            self.record_safepoint_lines or self.trace.config.record_exec_log or
            self.trace.pending_exit_anchor != null or
            self.trace.pending_replay_anchor != null or
            self.trace.config.coverage)
        {
            return @call(.always_tail, backEdgeHandler(mode), .{ st, npc, instr, vm, tags, payloads });
        }
        // Patched entry: skip exactly the discovery/selection prefix
        // (hot-count probe, counters hashmap, trip computation,
        // isGated, walk, fingerprint — the native prologue's
        // fail-closed type check subsumes the fingerprint at entry,
        // per the B-4 discipline) and run the identical entry/receipt
        // routine the walk uses.
        const directive = self.enterPatchedTrace(mode, patch, slot, st.closure, st.proto, regs, st.base, npc);
        if (self.trace.registry.entry_registry.image_gen != st.code_gen) {
            st.code = self.cachedCodeFor(st.frame, st.proto);
            st.code_gen = self.trace.registry.entry_registry.image_gen;
        }
        switch (directive) {
            .next_candidate => {
                // Fall through to the tier-0 body. Mirror the walk's
                // T3 invariant: a recording must never run under
                // `.fast` (its prologue elides the mirror).
                if (mode == .fast and self.trace.isRecording()) {
                    st.frame.pc = npc;
                    return .switch_mode;
                }
                return dispatchTail(mode, st, npc, vm);
            },
            .resume_tier0 => |rpc| return dispatchTail(mode, st, rpc, vm),
            .switch_mode_at => |rpc| {
                st.frame.pc = rpc;
                return .switch_mode;
            },
            // Doc 44 D11: only head pages emit the push epilogue.
            .resume_frame_motion => @panic("native frame motion from a loop-anchor entry"),
            // Doc 45 D5: park the precise effect error at its
            // bytecode — registers already snapshot-restored.
            .raise_at => |r| {
                st.frame.pc = r.pc;
                return parkErr(st, r.err);
            },
        }
    }

    // Doc 20 Phase 3: patched entry for the loop-closing jumps the compiler
    // actually emits — `.jmp` for `while`, and `.jmp_if_false` for `repeat`.
    // The slot's canonical `orig` selects the exact jump semantics; only a
    // taken back-edge may enter native. All bypasses present `orig` to the
    // ordinary back-edge epilogue, exactly like `.jfor_loop`.
    fn opJLoop(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr_in: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const self = vm;
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const slot: u16 = instr_in.b;
                const patch = self.trace.registry.entry_registry.entry_patches.items[slot];
                const live = patch.live;
                // Doc 63 §5.9: as the numeric-for arm.
                const suspended = self.jitSuspended(mode);
                if (!live and !suspended) {
                    // Same deferred-unpatch recovery as the numeric-for arm:
                    // complete the transaction before executing the canonical
                    // instruction once.
                    self.trace.unpatchSlot(slot);
                }
                // Pointer, not a local copy: the musttail chain outlives this
                // handler's frame, so anything passed onward must be
                // frame-independent — `patch.orig` is slot-stable (reuse only
                // happens in a drain's install pass; the epilogue copies what
                // it needs before its drains run).
                const instr = &patch.orig;
                const a: usize = instr.a;
                var npc = pc;
                // Doc 58 §4.2: `took` replaces the old `npc <= cur_pc` test.
                // A `loop` marker's header is FORWARD (`pc`, the body start),
                // so the back-edge cannot be recognised by direction any more.
                var took = false;
                switch (instr.op) {
                    // Doc 58: the loop marker always takes its back-edge —
                    // reaching it means the `while`/`repeat` condition already
                    // said "run the body". Execution falls through to `pc`,
                    // which is the header.
                    .loop => took = true,
                    // Generic-for test+continue (doc 30 c5): first loop var
                    // non-nil → publish it as ctrl and take the back-edge;
                    // nil → fall through (loop done). Byte-identical to the
                    // canonical `.tfor_loop` arm.
                    .tfor_loop => if (!regs.get(a + 3).isNil()) {
                        regs.set(a + 2, regs.get(a + 3));
                        npc = applyJump(pc, instr.aux);
                        took = true;
                    },
                    else => unreachable, // install accepts only loop back-edges
                }
                // A generic-for whose control var went nil leaves the loop.
                if (!took) {
                    return dispatchTail(mode, st, npc, vm);
                }
                if (!live or suspended) return @call(.always_tail, backEdgeHandler(mode), .{ st, npc, instr, vm, tags, payloads }); // restored virgin cascade
                if (self.trace.isRecording() or self.suspend_ctl != null or
                    self.record_safepoint_lines or self.trace.config.record_exec_log or
                    self.trace.pending_exit_anchor != null or
                    self.trace.pending_replay_anchor != null or
                    self.trace.config.coverage)
                {
                    return @call(.always_tail, backEdgeHandler(mode), .{ st, npc, instr, vm, tags, payloads });
                }
                const directive = self.enterPatchedTrace(mode, patch, slot, st.closure, st.proto, regs, st.base, npc);
                if (self.trace.registry.entry_registry.image_gen != st.code_gen) {
                    st.code = self.cachedCodeFor(st.frame, st.proto);
                    st.code_gen = self.trace.registry.entry_registry.image_gen;
                }
                switch (directive) {
                    .next_candidate => {
                        if (mode == .fast and self.trace.isRecording()) {
                            st.frame.pc = npc;
                            return .switch_mode;
                        }
                        return dispatchTail(mode, st, npc, vm);
                    },
                    .resume_tier0 => |rpc| return dispatchTail(mode, st, rpc, vm),
                    .switch_mode_at => |rpc| {
                        st.frame.pc = rpc;
                        return .switch_mode;
                    },
                    // Doc 44 D11: only head pages emit the push epilogue.
                    .resume_frame_motion => @panic("native frame motion from a loop-anchor entry"),
                    // Doc 45 D5: park the precise effect error at its
                    // bytecode — registers already snapshot-restored.
                    .raise_at => |r| {
                        st.frame.pc = r.pc;
                        return parkErr(st, r.err);
                    },
                }
            }
        }.h;
    }

    // Doc 44 P0: patched FUNCTION-HEAD trace entry (LuaJIT JFUNCF analogue).
    // Written only into a per-VM image over a head-qualified proto's pc 0.
    // Unlike `.jfor_loop`/`.jloop` the patched-over instruction is ARBITRARY,
    // so this handler owns no canonical step of its own: every decline/bypass
    // tail-dispatches `patch.orig` through the ordinary handler table (the
    // recorder mirror already presents the canonical instruction, §R1-3).
    fn opJFuncHead(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr_in: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const self = vm;
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const cur_pc = pc - 1; // == patch_pc == 0 by construction
                const slot: u16 = instr_in.b;
                const patch = self.trace.registry.entry_registry.entry_patches.items[slot];
                // Every decline/bypass below dispatches `&st.proto.code[cur_pc]`
                // (canonical-identical to `patch.orig` by the install
                // invariant) — NEVER `&patch.orig`: straight-line handlers
                // walk `instrNext(instr)` and a detached struct pointer has
                // no successor instruction behind it. Walking on into
                // `proto.code` is sound (virgin ops, canonical semantics);
                // the next jump/call re-derives from `st.code` and re-sees
                // any patched pcs.
                //
                // Doc 63 §5.9: suspended, run the canonical instruction
                // before the non-live recovery, without touching the patch.
                if (self.jitSuspended(mode)) {
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                if (!patch.live) {
                    // §R6-1 deferred-unpatch recovery, exactly the loop arms'
                    // discipline: complete the transaction, then run the
                    // canonical instruction.
                    self.trace.unpatchSlot(slot);
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                // §R1-5 bypass set (the loop arms' set + the pending call
                // anchor): under any live observation/recording hook, present
                // the canonical instruction to the ordinary handler so
                // recording and replay see virgin behaviour. Coverage is NOT
                // in this set (unlike the loop arms): a loop anchor still
                // enters its trace through the back-edge walk under coverage,
                // but the pc-0 patch is a head's ONLY entry — bypassing here
                // would make `--jit-stats` report 0%% head residency by
                // construction. The terminal consumer attributes the hop.
                if (self.trace.isRecording() or self.suspend_ctl != null or
                    self.record_safepoint_lines or self.trace.config.record_exec_log or
                    self.trace.pending_exit_anchor != null or
                    self.trace.pending_replay_anchor != null or
                    self.trace.pending_call_anchor != null)
                {
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                // Doc 45 D6.1 fast decline: a prior full walk proved every
                // candidate at this anchor is native-unsupported (memo keyed
                // to `cache_gen`; any commit/retirement invalidates it). Run
                // the canonical tier-0 instruction — one compare instead of a
                // decline-walk per call. A standing sibling want forces the
                // full walk (its transfer must be consumed there).
                if (self.trace.config.native_codegen and
                    patch.native_decline_gen == self.trace.registry.cache_gen and
                    self.trace.wants_head_sibling == null)
                {
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                // Patched entry: the identical entry/receipt routine the loop
                // arms use. Guard failures leave regs untouched since entry
                // (tier-1a/native evaluate into scratch; only φ-writeback and
                // committed flushes touch the file), so the zero-exit resume
                // at `cur_pc` re-runs the body on tier-0 from the same state —
                // the function-entry deopt snapshot IS pc 0's register state.
                const directive = self.enterPatchedTrace(mode, patch, slot, st.closure, st.proto, regs, st.base, cur_pc);
                if (self.trace.registry.entry_registry.image_gen != st.code_gen) {
                    st.code = self.cachedCodeFor(st.frame, st.proto);
                    st.code_gen = self.trace.registry.entry_registry.image_gen;
                }
                switch (directive) {
                    .next_candidate => {
                        // Tier-0 owns the body. T3 invariant: a recording must
                        // never run under `.fast` (its prologue elides the
                        // mirror) — park at pc 0; the `.full` re-entry's
                        // bypass above then routes to the canonical handler.
                        if (mode == .fast and self.trace.isRecording()) {
                            st.frame.pc = cur_pc;
                            return .switch_mode;
                        }
                        return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                    },
                    // A `.terminal` completion resumes AT the unexecuted
                    // ret/self-call; a guard-fail zero exit resumes at pc 0 —
                    // both are ordinary tier-0 dispatches. pc 0 re-dispatch
                    // cannot loop: a failed entry returns `.next_candidate`
                    // (handled above), never `.resume_tier0(0)`.
                    .resume_tier0 => |rpc| return dispatchTail(mode, st, rpc, vm),
                    .switch_mode_at => |rpc| {
                        st.frame.pc = rpc;
                        return .switch_mode;
                    },
                    // Doc 44 D11: the native run pushed real frames — the top
                    // frame is now the descent's leaf. Reload onto it and
                    // dispatch: `term.aux` re-executes the leaf's refused
                    // self-call generically; pc 0 runs the leaf's own
                    // jfunc_head walk (which owns the failure accounting).
                    .resume_frame_motion => |rpc| {
                        reloadTopFrame(st);
                        return dispatchTail(mode, st, rpc, vm);
                    },
                    // Doc 45 D5: park the precise effect error at its
                    // bytecode — registers already snapshot-restored.
                    .raise_at => |r| {
                        st.frame.pc = r.pc;
                        return parkErr(st, r.err);
                    },
                }
            }
        }.h;
    }

    // Doc 44 D12b: patched CONTINUATION trace entry (the return-side
    // `jfunc_head` twin). Written only into a per-VM image over a hot
    // post-call resume pc. Like `.jfunc_head` the patched-over instruction is
    // ARBITRARY, so every decline/bypass tail-dispatches the canonical
    // instruction through the ordinary handler table. Entered from `opRet`'s
    // dispatchTail — and from straight-line flow into the same pc, which is
    // free extra coverage (the trace guards its own entry types).
    fn opJCont(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr_in: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const self = vm;
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const cur_pc = pc - 1; // == patch_pc == the resume pc
                const slot: u16 = instr_in.b;
                const patch = self.trace.registry.entry_registry.entry_patches.items[slot];
                // Every decline/bypass below dispatches `&st.proto.code[cur_pc]`
                // (canonical-identical to `patch.orig` by the install
                // invariant) — never `&patch.orig` (no successor instruction
                // behind a detached struct pointer; the jfunc_head note).
                //
                // Doc 63 §5.9: as jfunc_head.
                if (self.jitSuspended(mode)) {
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                if (!patch.live) {
                    // §R6-1 deferred-unpatch recovery.
                    self.trace.unpatchSlot(slot);
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                // §R1-5 bypass set: jfunc_head's set + the pending RET anchor
                // (a `.cont` recording arming at this very pc must see the
                // virgin instruction). Coverage is NOT in the set for the same
                // reason as jfunc_head: this patch is the anchor's ONLY entry.
                if (self.trace.isRecording() or self.suspend_ctl != null or
                    self.record_safepoint_lines or self.trace.config.record_exec_log or
                    self.trace.pending_exit_anchor != null or
                    self.trace.pending_replay_anchor != null or
                    self.trace.pending_call_anchor != null or
                    self.trace.pending_ret_anchor != null)
                {
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                // Doc 45 D6.1 fast decline (jfunc_head twin): every candidate
                // proved native-unsupported by a prior full walk — canonical
                // tier-0 dispatch until the next `cache_gen` bump.
                if (self.trace.config.native_codegen and
                    patch.native_decline_gen == self.trace.registry.cache_gen and
                    self.trace.wants_head_sibling == null)
                {
                    return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                }
                // Patched entry: the identical entry/receipt routine. Guard
                // failures leave regs untouched since entry, so the zero-exit
                // resume at `cur_pc` re-runs the continuation on tier-0 from
                // the same state — the entry deopt snapshot IS this pc's
                // register state.
                const directive = self.enterPatchedTrace(mode, patch, slot, st.closure, st.proto, regs, st.base, cur_pc);
                if (self.trace.registry.entry_registry.image_gen != st.code_gen) {
                    st.code = self.cachedCodeFor(st.frame, st.proto);
                    st.code_gen = self.trace.registry.entry_registry.image_gen;
                }
                switch (directive) {
                    .next_candidate => {
                        // T3: a recording must never run under `.fast`.
                        if (mode == .fast and self.trace.isRecording()) {
                            st.frame.pc = cur_pc;
                            return .switch_mode;
                        }
                        return @call(.always_tail, handlerTable(mode)[@intFromEnum(st.proto.code[cur_pc].op)], .{ st, pc, &st.proto.code[cur_pc], vm, tags, payloads });
                    },
                    .resume_tier0 => |rpc| return dispatchTail(mode, st, rpc, vm),
                    .switch_mode_at => |rpc| {
                        st.frame.pc = rpc;
                        return .switch_mode;
                    },
                    // Doc 44 D12c: a continuation can now commit either a
                    // self-call push (unarmed call-head miss) or return pops
                    // before its frame link misses/cap-yields. Reload the
                    // actual top frame and dispatch the explicit final resume
                    // pc exactly as the head-entry motion path does.
                    .resume_frame_motion => |rpc| {
                        reloadTopFrame(st);
                        return dispatchTail(mode, st, rpc, vm);
                    },
                    // Doc 45 D5: park the precise effect error at its
                    // bytecode — registers already snapshot-restored.
                    .raise_at => |r| {
                        st.frame.pc = r.pc;
                        return parkErr(st, r.err);
                    },
                }
            }
        }.h;
    }

    // generic-for test: the preceding `call` filled R[a+3..] with the
    // iterator's results. Continue iff the first var is non-nil (Lua stops
    // only on nil; `false` continues), publishing it as the next control
    // R[a+2] and taking the back-edge. Else fall through (exit).
    fn opTForLoop(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const a: usize = instr.a;
                const cur_pc = pc - 1;
                var npc = pc;
                if (!regs.get(a + 3).isNil()) {
                    regs.set(a + 2, regs.get(a + 3));
                    npc = applyJump(pc, instr.aux);
                }
                if (vm.trace.config.enabled and npc <= cur_pc)
                    return @call(.always_tail, gatedBackEdgeHandler(mode), .{ st, npc, instr, vm, tags, payloads });
                return dispatchTail(mode, st, npc, vm);
            }
        }.h;
    }

    /// Is `f` the `next` builtin? `itern`'s fast-lane test (doc 66 P1).
    inline fn isNextNative(f: Value) bool {
        return f.isHeap() and f.heapType() == .native and stdbase.isNext(function.Native.fromHeader(f.asHeap()));
    }

    /// One `next` step's results as the `call a+3, 2, want` it stands for
    /// leaves them: the key, the value when two or more are wanted, then nil
    /// (`key` nil at the end of the traversal, when `next` returns none).
    inline fn writeIternStep(regs: RegWindow, a: usize, want: u16, key: Value, val: Value) void {
        regs.set(a + 3, key);
        if (want >= 2) regs.set(a + 4, val);
        var k: usize = 2;
        while (k < want) : (k += 1) regs.set(a + 3 + k, Value.nil());
    }

    /// Doc 66 P1: the generic-`for` step, `itern a, c`. Its fast lane is
    /// `next`'s array part over a plain table, inline and call-free: the
    /// `nextStep` scan from the control key. The hash part, a `row_view`, a
    /// grid, a float-spelled control and every other iterator leave for
    /// `opIternSlow`.
    fn opItern(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const a: usize = instr.a;
                const s = regs.get(a + 1);
                if (isNextNative(regs.get(a)) and s.isHeap() and s.heapType() == .table) {
                    const t = table.Table.fromHeader(s.asHeap());
                    const ctrl = regs.get(a + 2);
                    // Where `nextStep` resumes in the array part: at its
                    // start, or after an integer key inside it.
                    const resume_at: ?i64 = if (ctrl.isNil())
                        0
                    else if (ctrl.isInt() and array.ArrayPart.inArray(ctrl.asInt(), t.array.asize))
                        ctrl.asInt() + 1
                    else
                        null;
                    if (resume_at) |first| if (!t.array.isGrid()) {
                        const n: i64 = @intCast(t.array.asize);
                        var i = first;
                        while (i < n) : (i += 1) {
                            const v = t.array.get(@intCast(i));
                            if (!v.isNil()) {
                                writeIternStep(regs, a, instr.c, Value.int(i), v);
                                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                            }
                        }
                        // Past the array part, an empty hash part ends the
                        // traversal, unless `nextLive` has a view to free.
                        if (t.hash.live == 0 and t.hash.iter_keys == null) {
                            writeIternStep(regs, a, instr.c, Value.nil(), Value.nil());
                            return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                        }
                    };
                }
                return slowTail(mode, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    /// `itern` off its call-free lane. With the `next` builtin, the step
    /// `stdbase.iternStep` takes without allocating: the hash part once its
    /// view is built, or a `row_view`. Anything else is exactly the sequence
    /// `itern` replaced, `move a+3,a; move a+4,a+1; move a+5,a+2` then the
    /// `call a+3, 2, c` (`callTail`): another iterator, a grid to deflate, a
    /// view to build, a bad argument to raise.
    fn opIternSlow(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const a: usize = instr.a;
                const f = regs.get(a);
                const s = regs.get(a + 1);
                const ctrl = regs.get(a + 2);
                if (isNextNative(f)) {
                    if (stdbase.iternStep(vm.gpa, s, ctrl)) |step| {
                        if (step.found)
                            writeIternStep(regs, a, instr.c, step.key, step.val)
                        else
                            writeIternStep(regs, a, instr.c, Value.nil(), Value.nil());
                        return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                    }
                }
                regs.set(a + 3, f);
                regs.set(a + 4, s);
                regs.set(a + 5, ctrl);
                return callTail(mode, .itern, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    // ---- tables ----
    fn opNewTable(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const t = vm.heap.newTable() catch |e| return parkErr(st, e);
                regs.set(instr.a, Value.heap(&t.header));
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opGetIndex(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                // Array fast-path: a table indexed by an in-range integer key
                // reads straight from the typed array part, skipping the
                // `indexGet → Table.get → normalizeKey → getInt` call layering
                // (the ~22% `Table.get` in the nsieve profile). This is a pure
                // shortcut to the exact value `getInt` would return for an
                // in-bounds int key (table.zig:105); every other shape — float
                // key, out-of-range, hash-resident, non-table — falls through
                // to the unchanged helper, so semantics and determinism are
                // identical (no allocation on either branch).
                //
                // Both fast paths call nothing; everything else leaves for
                // `opGetIndexSlow`, so a hit saves no registers.
                const self = vm;
                const container = regs.get(instr.b);
                const key = regs.get(instr.c);
                const hit: ?Value = blk: {
                    if (container.isHeap() and container.heapType() == .table and key.isInt()) {
                        const tbl = table.Table.fromHeader(container.asHeap());
                        const i = key.asInt();
                        // A grid table's `t[i]` is a transient `row_view`, not
                        // a raw slot — skip the fast path and let `indexGet →
                        // Table.getInt` mint the handle. (Phase 3, doc 14.)
                        if (!tbl.array.isGrid()) {
                            if (array.ArrayPart.inArray(i, tbl.array.asize)) {
                                // A *present* (non-nil) in-bounds slot is a raw
                                // read regardless of any metatable — Lua only
                                // consults `__index` for an absent key.
                                const v = tbl.array.get(@intCast(i));
                                if (!v.isNil()) break :blk v;
                            } else if (tbl.hash.liveIntNode(i)) |n| {
                                // Past the array part only the hash part can
                                // hold the key (`Table.getInt`).
                                break :blk n.value;
                            }
                            // Absent (a hole, or past the end: `tree[2]` on a
                            // leaf): nil, unless an `__index` must be asked.
                            if (tbl.metatable == null) break :blk Value.nil();
                        }
                    }
                    // Heap-key fast path (`t.name`, `o:method`): the lookup
                    // and any `__index` chain of plain tables, inline.
                    if (container.isHeap() and container.heapType() == .table and key.isHeap()) {
                        break :blk self.heapKeyChainGet(table.Table.fromHeader(container.asHeap()), key);
                    }
                    break :blk null;
                };
                if (hit) |v| {
                    regs.set(instr.a, v);
                    return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                } else {
                    @branchHint(.cold);
                    return slowTail(mode, st, pc, instr, vm, tags, payloads);
                }
            }
        }.h;
    }

    /// `get_index` off its fast paths: `indexGet`, with its metamethods,
    /// grid deflation and errors.
    fn opGetIndexSlow(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const v = vm.indexGet(regs.get(instr.b), regs.get(instr.c)) catch |e| return parkErr(st, e);
                regs.set(instr.a, v);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opSetIndex(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                // Array fast-path mirror of `.get_index`: an in-bounds integer
                // store whose value already fits the current lane is the exact
                // work `Table.set`'s in-bounds branch does (table.zig:121 →
                // `setInPlace`, which with a fitting value is just `encode` —
                // no widen, no `migrateFromHash`, no allocation). `setInLane`
                // (array.zig:209) is that allocation-free `encode`. A
                // lane-missing value, append (`i == len+1`), out-of-range,
                // float/nil/NaN key, or non-table all fall through to the
                // unchanged `indexSet`, which owns widen/append/hash/delete.
                //
                // Both fast paths call nothing; everything else leaves for
                // `opSetIndexSlow`, so a fast store saves no registers.
                const self = vm;
                const container = regs.get(instr.a);
                const key = regs.get(instr.b);
                const val = regs.get(instr.c);
                fast: {
                    if (container.isHeap() and container.heapType() == .table and key.isInt()) {
                        const tbl = table.Table.fromHeader(container.asHeap());
                        const i = key.asInt();
                        // A grid store is an outer row (re)assignment — a
                        // Phase 5 deflation trigger owned by `indexSet`; never
                        // raw-stored here (and `fits(nil)` is `true`, so
                        // without this guard a `nil` store would reach
                        // `array.get` on a grid).
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
                    // Heap-key mirror (`t.name = v`): a key live in the hash
                    // part takes a non-nil value in place, which is what
                    // `Table.set` does for it (`HashPart.put`'s live arm: no
                    // rehash, no new key), and `__newindex` never fires for a
                    // present key. A deletion, a new key, and a grid take
                    // `indexSet`.
                    if (container.isHeap() and container.heapType() == .table and key.isHeap() and !val.isNil()) {
                        const tbl = table.Table.fromHeader(container.asHeap());
                        if (!tbl.array.isGrid()) {
                            if (tbl.hash.liveHeapNode(key)) |n| {
                                n.value = val;
                                self.heap.writeBarrier(&tbl.header, val); // no-op until Phase 4
                                break :fast;
                            }
                        }
                    }
                    return slowTail(mode, st, pc, instr, vm, tags, payloads);
                }
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// `set_index` off its fast paths: `indexSet`, with `__newindex`,
    /// appends, deletions, grid deflation and errors.
    fn opSetIndexSlow(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                vm.indexSet(regs.get(instr.a), regs.get(instr.b), regs.get(instr.c)) catch |e| return parkErr(st, e);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// Doc 66 P2: `get_field a, b, c` is `R[a] = R[b][K[c]]` with `K[c]` an
    /// interned string, `get_index` without the key's `load_const`. The fast
    /// lane is `get_index`'s heap-key lane: the lookup and any `__index`
    /// chain of plain tables, inline. It declines a grid, so it never
    /// allocates; everything else leaves for `opGetFieldSlow`.
    fn opGetField(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const container = regs.get(instr.b);
                if (container.isHeap() and container.heapType() == .table) {
                    if (vm.heapKeyChainGet(table.Table.fromHeader(container.asHeap()), st.proto.constants[instr.c])) |v| {
                        regs.set(instr.a, v);
                        return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                    }
                }
                return slowTail(mode, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    /// `get_field` off its fast lane: `indexGet`, as `opGetIndexSlow`.
    fn opGetFieldSlow(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const v = vm.indexGet(regs.get(instr.b), st.proto.constants[instr.c]) catch |e| return parkErr(st, e);
                regs.set(instr.a, v);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// Doc 66 P2: `set_field a, b, c` is `R[a][K[b]] = R[c]` with `K[b]` an
    /// interned string. The fast lane is `set_index`'s heap-key lane: a key
    /// live in the hash part takes a non-nil value in place. A deletion, a
    /// new key and a grid take `opSetFieldSlow`.
    fn opSetField(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const container = regs.get(instr.a);
                const val = regs.get(instr.c);
                if (container.isHeap() and container.heapType() == .table and !val.isNil()) {
                    const tbl = table.Table.fromHeader(container.asHeap());
                    if (!tbl.array.isGrid()) {
                        if (tbl.hash.liveHeapNode(st.proto.constants[instr.b])) |n| {
                            n.value = val;
                            vm.heap.writeBarrier(&tbl.header, val); // no-op until Phase 4
                            return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                        }
                    }
                }
                return slowTail(mode, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    /// `set_field` off its fast lane: `indexSet`, as `opSetIndexSlow`.
    fn opSetFieldSlow(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                vm.indexSet(regs.get(instr.a), st.proto.constants[instr.b], regs.get(instr.c)) catch |e| return parkErr(st, e);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opGetIndex2(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                // Fused two-level read `R[a] = R[b][R[c]][R[aux]]`. On a grid
                // (doc 14) this reads the flat cell directly — the *only* grid
                // reader, so it never mints a `row_view`. On a nested table it
                // is exactly two `indexGet`s, semantically identical to the
                // unfused form (metatables on either level still dispatch).
                const container = regs.get(instr.b);
                const key1 = regs.get(instr.c);
                const key2 = regs.get(@as(u16, @intCast(instr.aux)));
                regs.set(instr.a, vm.fusedGet(container, key1, key2) catch |e| return parkErr(st, e));
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opSetIndex2(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                // Fused two-level store `R[a][R[b]][R[c]] = R[aux]`. The grid
                // inflation trigger and the in-grid cell store (with
                // reshape-on-overflow) live in `fusedStore` (doc 14, Phase 4b).
                const container = regs.get(instr.a);
                const key1 = regs.get(instr.b);
                const key2 = regs.get(instr.c);
                const val = regs.get(@as(u16, @intCast(instr.aux)));
                vm.fusedStore(container, key1, key2, val) catch |e| return parkErr(st, e);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // ---- globals ----
    fn opGetGlobal(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                // Fast path: the global is where this name's slot hint says.
                // It calls nothing, so the handler needs no saved registers;
                // everything else tail-calls the slow handler.
                const hints = st.proto.global_slot_hints;
                const hit: ?Value = if (instr.b < hints.len)
                    vm.globals.heapHintHit(st.proto.constants[instr.b], hints[instr.b])
                else
                    null;
                if (hit) |v| {
                    const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                    regs.set(instr.a, v);
                    return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
                } else {
                    @branchHint(.cold);
                    return slowTail(mode, st, pc, instr, vm, tags, payloads);
                }
            }
        }.h;
    }

    /// `get_global` when the slot hint misses (or the proto has none): the
    /// full lookup, which also moves the hint to where the global was found.
    fn opGetGlobalSlow(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const key = st.proto.constants[instr.b];
                const hints = st.proto.global_slot_hints;
                const v = if (instr.b < hints.len) vm.globals.getHinted(key, &hints[instr.b]) else vm.globals.get(key);
                regs.set(instr.a, v);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opSetGlobal(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const self = vm;
                const v = regs.get(instr.a);
                const key = st.proto.constants[instr.b];
                const hints = st.proto.global_slot_hints;
                const stored = if (instr.b < hints.len)
                    self.globals.setHinted(self.gpa, key, v, &hints[instr.b])
                else
                    self.globals.set(self.gpa, key, v);
                stored catch |e| return parkErr(st, e);
                self.heap.writeBarrier(&self.globals.header, v); // no-op until Phase 4
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // ---- functions ----
    fn opClosure(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const child = st.proto.protos[instr.b];
                const cl = vm.makeClosure(st.closure, child, st.base) catch |e| return parkErr(st, e);
                regs.set(instr.a, Value.heap(&cl.header));
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opGetUpval(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                regs.set(instr.a, vm.upvalGet(st.closure.upvalues[instr.b]));
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opSetUpval(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                const self = vm;
                const v = regs.get(instr.a);
                self.upvalSet(st.closure.upvalues[instr.b], v);
                self.heap.writeBarrier(&st.closure.upvalues[instr.b].header, v); // no-op until generational
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// Doc 58: the loop marker (LuaJIT `BC_LOOP`). B1: a pure no-op — it
    /// always falls through, and its `aux` (the loop's exit offset) is never
    /// a jump.
    // Doc 58 §4.2: the loop marker (LuaJIT `BC_LOOP`) is the back-edge of a
    // `while`/`repeat` loop. It always "takes" it — execution falls through to
    // `pc`, which IS the loop header (the body start), so hot counting, trace
    // entry, gates and coverage run exactly once per iteration keyed on the
    // body start, exactly as `for_loop` does. With tracing off it is a no-op.
    fn opLoop(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                if (vm.trace.config.enabled)
                    return @call(.always_tail, gatedBackEdgeHandler(mode), .{ st, pc, instr, vm, tags, payloads });
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opCloseUpvalues(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                vm.closeUpvaluesFrom(st.base + instr.a);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    // ---- calls ---- a Lua call pushes a frame and reloads onto it; a native
    // runs inline (no frame) as the current frame's top activity.
    fn opCall(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                return callTail(mode, .call, st, pc, instr, vm, tags, payloads);
            }
        }.h;
    }

    /// The callee slot of the call `instr` (a `.call` or an `itern`, `of`)
    /// makes, as `bytecode.callOperandsOf` has it. Read from `instr` at each
    /// use, like `.call`'s handler always did: holding the operands from the
    /// top of `callTail` costs `.call` registers across its whole body.
    inline fn callA(comptime of: bytecode.OpCode, instr: *const Instr) u16 {
        return if (of == .itern) instr.a + 3 else instr.a;
    }

    /// The argument count operand of `callA`'s call.
    inline fn callB(comptime of: bytecode.OpCode, instr: *const Instr) u16 {
        return if (of == .itern) 2 else instr.b;
    }

    /// `.call`'s body, shared with `itern`'s fallback (doc 66 P1): `of` names
    /// the opcode `instr` is, and the operands are the call it makes
    /// (`callA`/`callB`; `c` is the same field for both).
    inline fn callTail(comptime mode: ExecMode, comptime of: bytecode.OpCode, st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
        comptime std.debug.assert(of == .call or of == .itern);
        const self = vm;
        const a: usize = callA(of, instr);
        const base = st.base;
        // Resolve the argument count first: nothing before it may
        // fail. `all_results` (the consumer half of dynamic multret,
        // e.g. the outer `print` in `print(unpack(t))`) takes every
        // value the immediately-preceding producer left, from the
        // first argument slot up to `reg_top`. Taking it clears
        // `reg_top_pending`, which must not outlive a fault here.
        // Doc 61 §5 (B): the frame keeps the span's end, so a
        // collection while it is in flight here (a native or
        // `__call` callee, or a fault under `xpcall`) masks the
        // unwritten window above it.
        const nargs: usize = if (callB(of, instr) == bytecode.all_results) blk: {
            self.reg_top_pending = false;
            st.frame.multret_top = @intCast(@min(self.reg_top - base, st.proto.num_registers));
            break :blk self.reg_top - (base + a + 1);
        } else callB(of, instr);
        const callee = st.regs.get(a);
        if (!callee.isHeap()) return parkErr(st, Error.TypeError);
        switch (callee.heapType()) {
            .function => {
                const cl = Closure.fromHeader(callee.asHeap());
                const cp = cl.proto;
                // The callee window sits above the caller's window AND
                // above the argument span (doc 61 P1, LuaJIT's vararg
                // frame layout). A dynamic (`all_results`) span can end
                // past the caller window; laying the callee at the
                // window end would overwrite the surplus varargs it
                // then reads, and make the param copy below overlap.
                // A fixed span always fits, so this is the window end.
                const callee_base = @max(base + st.proto.num_registers, base + a + 1 + nargs);
                if (self.depth >= max_call_depth) return parkErr(st, Error.StackOverflow);
                if (callee_base + cp.num_registers > self.regCapacity()) return parkErr(st, Error.StackOverflow);
                // Lay out the callee window: bind fixed params
                // (nil-fill any not supplied), nil the rest.
                // Straight-line and allocation-free — these slots sit
                // above the current `stack_top` until `pushFrame`
                // raises it, so no safepoint may intervene here (none
                // does).
                var i: usize = 0;
                while (i < cp.num_registers) : (i += 1) {
                    self.regSet(callee_base + i, if (i < cp.num_params and i < nargs)
                        self.regGet(base + a + 1 + i)
                    else
                        Value.nil());
                }
                // Varargs cursor: a vararg callee handed more args
                // than it has fixed params keeps the surplus where
                // they already sit — below `callee_base`, in the
                // caller's window or in the span above it. They stay valid (the stack slab never
                // moves) and GC-rooted (`forEachRootHeader` scans the
                // whole live prefix) for the callee's lifetime.
                // Recorded per-callee so a non-vararg or no-surplus
                // callee gets a zero cursor (never inherits one).
                const va_count: usize = if (cp.is_vararg and nargs > cp.num_params) nargs - cp.num_params else 0;
                const va_base: usize = if (va_count > 0) base + a + 1 + cp.num_params else 0;
                // Freeze the caller's resume cursor (already one past
                // this call), push the callee, and reload onto it.
                // Doc 61 §4.3: a caller suspended at a Lua call is
                // out of flight with `pc` one past a `.call`.
                std.debug.assert(!st.frame.in_flight);
                st.frame.pc = pc;
                self.pushFrameVararg(cl, callee_base, callA(of, instr), instr.c, va_base, va_count) catch |e| {
                    // Doc 61 §4.4 fault-pc invariant: a frame left
                    // faulting names its faulting instruction, the
                    // `.call` (as the early checks above leave it).
                    st.frame.pc = pc - 1;
                    return parkErr(st, e);
                };
                reloadTopFrame(st);
                // Doc 44: count this SUCCESSFUL Lua-callee entry
                // toward the callee's function-head anchor (after the
                // push — failed calls never count). A hot verdict
                // sets `pending_call_anchor`; the very next prologue
                // (the dispatchTail below lands on callee pc 0) arms
                // it under `.full` — never here (T-2/T-3 discipline).
                // `st.code` is the callee's image, just reloaded above
                // — passing it makes the patched steady state hash-free
                // (doc 44 D9 S1).
                self.trace.onCallEntry(cp, st.base, st.frame.call_seq, st.code);
                // A hot verdict under `.fast` needs the `.full`
                // prologue's consumer (step 10b) at callee pc 0 —
                // park and flip, exactly the back-edge arming
                // discipline (`runFastPath` holds `.full` while the
                // pending exists; it is consumed on the very next
                // prologue, so the stint is one instruction on a
                // mismatch).
                if (mode == .fast and self.trace.pending_call_anchor != null)
                    return .switch_mode;
                // Reloaded onto the callee frame; tail-dispatch its
                // first instruction with a full prologue
                // (GC/seq/suspend/recording) — exactly one prologue at
                // the call boundary (T-2).
                return dispatchTail(mode, st, st.frame.pc, vm);
            },
            .native => {
                const nat = function.Native.fromHeader(callee.asHeap());
                const nwanted: usize = instr.c;
                // Doc 61 P2: a dynamic argument span can end past the
                // window, above `stack_top`. Cover it for the call:
                // the GC roots it, and a re-entry lays its window (and
                // gathers its natives' scratch) above it. Restored on
                // success; an error leaves it raised for the catcher,
                // which resets `stack_top` when it discards frames.
                const entry_top = self.stack_top;
                const args_end = base + a + 1 + nargs;
                if (args_end > entry_top) self.stack_top = args_end;
                // Doc 61 §4.2: the frame is in flight at this `.call`
                // for the native's whole duration, so every frame a
                // callback or a host entry pushes above it finds its
                // caller marked. Cleared on success; an error leaves it
                // set for the catcher, like `stack_top`.
                std.debug.assert(!st.frame.in_flight);
                st.frame.in_flight = true;
                // Materialize the args into the absolute-indexed
                // boundary scratch so the native ABI keeps speaking
                // `[]Value` after the register file split (SoA). The
                // scratch is laid out at the same absolute slot
                // indices as the registers, so the `out`-aliases-`args`
                // overlap multi natives rely on is preserved exactly;
                // nesting is safe because a deeper call parks its own
                // args at higher absolute indices.
                const args = self.gatherScratch(base + a + 1, base + a + 1 + nargs);
                // `all` = the caller wants *every* result (dynamic
                // count, the producer half of `print(unpack(t))` /
                // `return f()`): results land starting at `regs[a]`
                // and `reg_top` records their end for the adjacent
                // consumer. Otherwise a concrete `nwanted` is written
                // and the tail nil-padded.
                //
                // Three native shapes, in priority order:
                //  1. effect native (clock/getenv/…): one result
                //     through the record/replay boundary — effects are
                //     inherently single.
                //  2. multi-result native: write straight into the
                //     destination slots. `out` aliases `args` (see
                //     NativeMultiFn), which is why the native reads
                //     its args first. For `all`, `out` spans to the
                //     end of the register stack (bounded → no OOB; the
                //     native caps at `out.len`).
                //  3. otherwise (pure single, or a multi native with
                //     0/1 wanted): call `func` (the primary-value
                //     projection) and write one.
                // A native call is a trace barrier (recording aborts
                // at it), so none of this touches the JIT.
                const all = nwanted == bytecode.all_results;
                if (nat.host != null) {
                    // Embedder host fn (doc 59 §3.5): the results land
                    // in the destination slots from `regs[a]`. The
                    // host wrote them to a private buffer
                    // (`callHostNative`), so they never aliased
                    // `args` or anything a nested call wrote.
                    const out_lo = base + a;
                    const want: usize = if (all) self.regCapacity() -| out_lo else nwanted;
                    if (out_lo + want > self.regCapacity()) return parkErr(st, Error.StackOverflow);
                    const res = self.callHostNative(nat, args, want) catch |e| return parkErr(st, e);
                    const produced = res.len;
                    // Straight-line from here to the register writes —
                    // no allocation, so the results (rooted only via
                    // the host's park/refs) can't be swept mid-copy.
                    var k: usize = 0;
                    while (k < produced) : (k += 1) self.regSet(out_lo + k, res[k]);
                    if (all) {
                        std.debug.assert(!self.reg_top_pending);
                        self.reg_top = base + a + produced;
                        self.reg_top_pending = true;
                    } else {
                        while (k < nwanted) : (k += 1) self.regSet(base + a + k, Value.nil());
                    }
                } else if (nat.effect) |kind| {
                    const result = performEffect(self, kind, nat, args) catch |e| return parkErr(st, e);
                    if (all) self.stampSingleResult(base, a, result) else writeSingleResult(st.regs, a, nwanted, result);
                } else if (nat.multi != null and (all or nwanted >= 2)) {
                    // `out` aliases `args` in scratch (same overlap as
                    // the old stack slices); the native writes results
                    // into scratch, then we scatter them back into the
                    // registers.
                    const out = if (all) self.scratchOut(base + a, self.regCapacity()) else self.scratchOut(base + a, base + a + nwanted);
                    const produced = nat.multi.?(@ptrCast(self), args, out) catch |e| return parkErr(st, narrowError(e));
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
                    const result = nat.func(@ptrCast(self), args) catch |e| return parkErr(st, narrowError(e));
                    if (all) self.stampSingleResult(base, a, result) else writeSingleResult(st.regs, a, nwanted, result);
                }
                st.frame.in_flight = false;
                self.stack_top = entry_top;
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
                if (handler.isNil()) return parkErr(st, Error.TypeError);
                const nwanted: usize = instr.c;
                // Doc 61 P2, as in the native arm: cover a dynamic
                // argument span past the window while the handler runs.
                const entry_top = self.stack_top;
                const args_end = base + a + 1 + nargs;
                if (args_end > entry_top) self.stack_top = args_end;
                // `[callee, args...]` is exactly the handler's
                // argument list — gather it into the absolute-indexed
                // scratch (the result `out` aliases it, same overlap
                // as the old stack slices; `callValue` reads its args
                // before writing out).
                const call_args = self.gatherScratch(base + a, base + a + 1 + nargs);
                if (nwanted == bytecode.all_results) {
                    const n = self.callValue(handler, call_args, self.scratchOut(base + a, self.regCapacity())) catch |e| return parkErr(st, e);
                    std.debug.assert(!self.reg_top_pending);
                    self.scatterScratch(base + a, base + a + n);
                    self.reg_top = base + a + n;
                    self.reg_top_pending = true;
                } else {
                    const out = self.scratchOut(base + a, base + a + nwanted);
                    const n = self.callValue(handler, call_args, out) catch |e| return parkErr(st, e);
                    var k: usize = n;
                    while (k < nwanted) : (k += 1) out[k] = Value.nil();
                    self.scatterScratch(base + a, base + a + nwanted);
                }
                self.stack_top = entry_top;
            },
        }
        // The native and `__call` arms run inline (no frame push) and
        // leave `pc` one past the call, exactly like a straight-line
        // op, so they thread to the next instruction. (The `.function`
        // arm never reaches here — it tail-dispatches after reloading
        // onto the callee frame.)
        return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
    }

    // ---- returns ---- pop this frame; copy results into the parent's window
    // (or, for the bottom frame, hand the `FrameResult` to `run`/`exec`'s
    // caller). Close any upvalues over this frame first. Shared by `.ret` and
    // `.halt` (the old combined arm).
    fn opRet(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                _ = pc;
                // Frame pop ahead: lanes change under this handler, so it
                // works through `st` and dispatches on the general path.
                _ = tags;
                _ = payloads;
                const self = vm;
                const a: usize = instr.a;
                const base = st.base;
                self.closeUpvaluesFrom(base);
                // Resolve how many values this frame returns. `ret a
                // all_results` (the producer half of `return f()` /
                // `return unpack(t)`) returns everything the
                // immediately-preceding multret call left, from `a` up to
                // `reg_top`.
                const ret_count: u16 = if (instr.op == .ret and instr.b == bytecode.all_results) blk: {
                    self.reg_top_pending = false;
                    break :blk @intCast(self.reg_top - (base + a));
                } else if (instr.op == .ret) instr.b else 0;
                const result: FrameResult = .{ .reg = @intCast(a), .count = ret_count };
                if (self.depth == st.stop_depth) {
                    // Pop the boundary frame. For the top level
                    // (stop_depth == 1) this nets `depth == 0` exactly as
                    // before; for a reentrant `callValue`
                    // (stop_depth == entry_depth + 1) it leaves the outer
                    // frames intact at `depth == entry_depth`. Results stay in
                    // this frame's window (at `base + result.reg`) until the
                    // caller copies them out — `stack_top` is not shrunk here,
                    // so the live-register scan still roots them.
                    self.trace.dropRegionActivation(st.frame.call_seq);
                    self.depth -= 1;
                    st.step = .{ .finished = result };
                    return .finished;
                }
                // Copy results into the parent *while* `stack_top` still
                // covers this (callee) window — no allocation or safepoint
                // between here and the `stack_top` shrink below, so a result
                // can't be collected before it lands in the parent's (scanned)
                // registers. `want` uses the stored return-wiring, never a
                // re-decode of the caller's call instruction. When the caller
                // wanted *all* results (`call … c=all_results`, e.g.
                // `print(g())`), take everything the callee produced and stamp
                // `reg_top` so the parent's adjacent consumer instruction can
                // expand them.
                // Doc 68 P0: no frame carries a continuation yet; P1 routes
                // the others to their finish before the ordinary wiring.
                std.debug.assert(st.frame.ctl.cont == .none);
                const parent = &self.frames[self.depth - 2];
                const wants_all = st.frame.ret_count == bytecode.all_results;
                const want: usize = if (wants_all) result.count else st.frame.ret_count;
                const dst = parent.base + st.frame.ret_dest;
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
                // Pop and reload locals onto the parent (its `pc` is already
                // past the call), shrinking `stack_top` to the parent's
                // window. Then tail-dispatch the parent's next instruction
                // with exactly one full prologue (T-3).
                self.trace.dropRegionActivation(st.frame.call_seq);
                self.depth -= 1;
                reloadTopFrame(st);
                self.stack_top = st.base + st.proto.num_registers;
                // Doc 44 D12b: count this return toward the CALLER's
                // continuation anchor at the frozen cursor (`st` is the
                // caller now; `st.code` its freshly-reloaded image). The
                // boundary return above never reaches here, so `stop_depth`
                // returns are structurally excluded. A hot verdict sets
                // `pending_ret_anchor`; the very next prologue (the
                // dispatchTail below lands on the resume pc) arms it under
                // `.full` — park and flip in `.fast`, the opCall discipline.
                self.trace.onRetResume(st.proto, @intCast(st.frame.pc), st.base, st.frame.call_seq, st.code);
                if (mode == .fast and self.trace.pending_ret_anchor != null)
                    return .switch_mode;
                return dispatchTail(mode, st, st.frame.pc, vm);
            }
        }.h;
    }

    // ---- varargs ---- read the current frame's `...` cursor. The
    // surplus-arg region lives below `base` (in the caller's window), stable
    // and GC-rooted; these never relocate it.
    fn opVarargFirst(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                regs.set(instr.a, if (st.frame.varargs_count >= 1) vm.regGet(st.frame.varargs_base) else Value.nil());
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opVarargLen(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                regs.set(instr.a, Value.int(@intCast(st.frame.varargs_count)));
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opVarargGet(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                const regs: RegWindow = .{ .tags = tags, .payloads = payloads, .n = st.regs.n };
                // 1-based, bounds-checked; out of range or non-int index → nil.
                const idx_v = regs.get(instr.b);
                var out = Value.nil();
                if (idx_v.isInt()) {
                    const idx = idx_v.asInt();
                    if (idx >= 1 and idx <= @as(i64, @intCast(st.frame.varargs_count))) {
                        out = vm.regGet(st.frame.varargs_base + @as(usize, @intCast(idx - 1)));
                    }
                }
                regs.set(instr.a, out);
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    fn opVarargSpread(comptime mode: ExecMode) *const HandlerFn {
        return struct {
            fn h(st: *ExecState, pc: usize, instr: *const Instr, vm: *Vm, tags: [*]u8, payloads: [*]u64) HandlerResult {
                // The dynamic-multret producer half: copy every vararg into
                // R[a..a+count) and stamp `reg_top` for the adjacent consumer
                // (a `call`/`ret` with `all_results`). Bound against the whole
                // stack, not the static window — like the native multret, the
                // values may land above `stack_top`, covered by the
                // `reg_top_pending` safepoint suppression until consumed.
                const self = vm;
                std.debug.assert(!self.reg_top_pending);
                const count = st.frame.varargs_count;
                const dest = st.base + instr.a;
                if (dest + count > self.regCapacity()) return parkErr(st, Error.StackOverflow);
                var k: usize = 0;
                while (k < count) : (k += 1) self.regSet(dest + k, self.regGet(st.frame.varargs_base + k));
                self.reg_top = dest + count;
                self.reg_top_pending = true;
                return dispatchTailFrom(mode, st, pc, instrNext(instr), vm, tags, payloads);
            }
        }.h;
    }

    /// Doc 42 §4.4: the back-edge epilogue — the Phase 5 hotness seam,
    /// coverage attribution, `onBackEdge`, the same-anchor trial walk /
    /// tier-entry machinery, and the T3 fast/slow handoff, moved verbatim from
    /// the bottom of the old dispatch loop. Reached only via `backEdgeHandler`
    /// when a backward (or self) jump took `pc` to `<= cur_pc` — a loop
    /// back-edge whose target is the loop header (anchor) — while
    /// `trace.config.enabled`; inert otherwise (the jump handlers thread
    /// straight past it).
    ///
    /// `noinline` is mandatory (doc 42 §4.4): an ordinary function would be
    /// re-inlined by ReleaseFast into every jump handler, re-creating exactly
    /// the layout coupling this arc removes. Two invariants: it never writes
    /// the jump target into `frame.pc` (the trampoline owns the mode-switch
    /// park; `frame.pc` stays at the executed back-edge until the next
    /// prologue), and every image-generation reload point stays inside it.
    noinline fn backEdgeEpilogue(comptime mode: ExecMode, st: *ExecState, pc: usize, instr: *const Instr) BackEdgeDirective {
        const self = st.vm;
        const proto = st.proto;
        const regs = st.regs;
        // Copy the presented (canonical) instruction up front: `instr` may
        // point at `patch.orig`, which is only guaranteed stable until the
        // next entry-patch drain — and this epilogue runs drains. The copy
        // makes every later read (`for_trips` below, future edits) safe by
        // construction instead of by ordering argument.
        const inst: Instr = instr.*;
        const anchor_pc: u32 = @intCast(pc);
        // JIT coverage (gated): arriving at a back-edge means tier-0 just
        // interpreted one loop-body iteration. Classify it covered (a trace
        // exists at this anchor — the fallback-despite-a-trace smell) vs
        // uncovered, and charge the cycles that body iteration took (the span
        // since the last coverage event — another back-edge or a trace-region
        // exit) to this anchor. Trace-run iterations/cycles are counted
        // separately (`onSideExit` + the trace-exec bracket in
        // `enterSelectedTrace`); the two are disjoint (a trace's committed
        // count excludes the deopt iteration tier-0 redoes on side-exit), so
        // there is no double count.
        if (self.trace.config.coverage) {
            const now = trace.readCycles();
            self.trace.noteInterpIter(proto, anchor_pc, trace.cycleDelta(now, self.trace.last_event_tsc));
            self.trace.last_event_tsc = now;
        }
        // Cheap direct-mapped hot-count pre-filter. A gated/dead loop (the
        // canonical case: nsieve's array-growing init loop, which can't be
        // traced) skips the per-back-edge hashmap bookkeeping in `onBackEdge`
        // + the trace-entry lookup entirely — it just decrements a `u16` slot
        // and falls back to tier-0. The global `tick` still advances (inside
        // `skipBackEdge`), so a transiently gated loop's backoff cooldown
        // keeps elapsing across the skip. Hot traced loops and warming loops
        // keep a 0 slot and always take the slow path below, so their
        // behaviour is unchanged.
        // Doc 63 §5.9: a suspended JIT still counts (`skipBackEdge` advances
        // the hot slot and `tick`), but everything past it is a JIT decision
        // or JIT-state write — the recorder's slab base, selection, cached
        // entry, the skip windows — so the whole slow path is skipped.
        if (!self.trace.skipBackEdge(proto, anchor_pc) and !self.jitSuspended(mode)) {
            // Doc 43 §3.1 (P0a): hand the recorder this frame's absolute slab base
            // so a fresh arming can decide open-upvalue aliasing. Any arm inside
            // `onBackEdge` reads it immediately; a stale value between arms is
            // never consumed.
            self.trace.pending_anchor_base = st.base;
            self.trace.onBackEdge(proto, anchor_pc, regs);

            // Phase 6 tier-1a entry: if a trace is cached for this loop header
            // and we're not mid-recording, execute it. `irinterp.execute`
            // returns with `regs` coherent for the header — it side-exits
            // *before* committing a partial iteration — so we resume
            // **without** advancing `pc`: tier-0 then re-runs the loop header
            // to redo the (pure, side-effect-free) deopt iteration. A trace is
            // only ever entered at exactly its anchor pc, so re-entry is
            // sound. Per-entry trip-count gating: for a numeric-`for`, decline
            // to enter the trace when the remaining iteration count is below
            // `min_trip_entry` — tier-0 runs the short loop and we skip the
            // `onSideExit` penalty, so the inner loop's trivial large-stride
            // runs never gate its profitable long runs. `null` for any
            // non-`for_loop` back-edge (while/repeat) ⇒ always eligible. A
            // `for_prep` entering its body arrives here too, with the first
            // index already in `R[a]`, exactly as a `for_loop` back-edge leaves it.
            const a: usize = inst.a;
            const for_trips: ?u64 = if (inst.op == .for_loop or inst.op == .for_prep)
                forRemainingTrips(regs.get(a), regs.get(a + 1), regs.get(a + 2))
            else
                null;
            const eligible = self.trace.config.execute and !self.trace.isRecording() and
                !self.trace.isGated(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id });
            const trip_ok = for_trips == null or for_trips.? >= self.trace.config.min_trip_entry;
            if (eligible and trip_ok) {
                // A gated anchor has proven it thrashes: every entry committed
                // fewer than `min_useful` iterations until the re-entry
                // penalty maxed out. The canonical case is a
                // strictly-alternating branch (stable types, so fingerprinting
                // can't tell the arms apart) where no single straight-line
                // trace can amortize entry/exit over more than one iteration —
                // running the trace was *slower* than tier-0. Gating entry
                // (not just re-arming, as before) lets tier-0 own the loop and
                // removes the slowdown. The gate retries the anchor on an
                // exponential backoff and clears the moment an entry finally
                // proves useful, so a loop that only thrashes transiently
                // still recovers. Works on the native path too: the penalty
                // keys only on `completed`, which native execution reports.
                //
                // Same-anchor chaining: if multiple traces exist for this loop
                // header (e.g. different type specializations), try each in
                // turn until one commits at least one iteration. All traces
                // share the same loop-header re-entry deopt discipline, so
                // `regs` is valid for every attempt.
                // Same-anchor trial walk. We iterate by an explicit *visited*
                // set (`nextTraceExcluding`) rather than the single-`skip`
                // `findNextTrace`, so each candidate is tried exactly once and
                // the walk always terminates — two equal-priority traces that
                // both zero-exit would otherwise cycle `A→B→A→…` forever
                // (e.g. two stale narrow-lane traces once the live array has
                // widened past both).
                var visited: [trial_visited_cap]*trace.Trace = undefined;
                var nvisited: usize = 0;
                var any_fingerprint_matched = false;
                // Native safety net (see the skip below): set when a
                // fingerprint-matching trace at this anchor compiled to
                // native-*unsupported*. If the walk then ends with no
                // productive entry, we gate the anchor so tier-0 owns the loop
                // rather than re-walking (or falling to tier-1a) every
                // back-edge.
                var saw_native_unsupported = false;
                // Widen-eviction: traces whose `guard_lane` pins a lane the
                // live array has monotonically widened past can never match
                // again. Collect them during the trial walk and retire them
                // when we leave it — removing a trace frees the `*Trace`, so
                // we must not do it while the walk could still revisit the
                // cache. `dead` is a subset of `visited`, so it never
                // overflows past the visited cap.
                var dead: WalkDead = .{};
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
                    // `.link` traces are continuations entered only by exit-PC
                    // chaining after an inner loop-done exit. Never
                    // trial-enter one through the same-anchor walk, even if a
                    // malformed or future bytecode shape puts it at a
                    // back-edge pc.
                    if (ct.code.instrs.len != 0 and ct.code.instrs[ct.code.instrs.len - 1].op == .link) continue;
                    // Doc 45 D6: PRECISE traces execute on tier-1a (the
                    // snapshot-restore executor) and, since the native
                    // precise executor landed, on tier-1b when `compileImpl`
                    // accepts them. One standing decline remains: exec-log
                    // sessions (handled inside `enterSelectedTrace` — no
                    // serialization schema until D8's format bump). A
                    // precise candidate whose native compile BAILED falls
                    // through to tier-1a below instead of the
                    // native-unsupported skip — see that arm.
                    // --- type fingerprint (step 5) ---
                    // Skip this trace if the current register types don't
                    // match its entry type guards.  Avoids trial entries that
                    // would immediately fail on a guard_int/guard_float
                    // mismatch.  Branch-direction guards (guard_true/false)
                    // aren't fingerprinted — they depend on computed values.
                    if (!ct.code.matchesFingerprint(regs)) continue;
                    // Doc 24 D8 observation blackout: while a suspend cut or
                    // safepoint-line recording is armed, decline to enter any
                    // ALLOCATING trace (`alloc_bound > 0`) — a mid-burst
                    // observation would see a heap `next_obj_id` tier-0 only
                    // reaches after the whole burst, breaking §T-A.2 keyframe
                    // byte-identity. Identical condition to `safe_to_arm`
                    // downstream; tier-0 owns allocating loops for the
                    // window's duration. Ordered after the fingerprint so a
                    // blacked-out candidate still counts as matched (no
                    // spurious side-trace pressure).
                    any_fingerprint_matched = true;
                    if (ct.code.alloc_bound > 0 and
                        (self.suspend_ctl != null or self.record_safepoint_lines)) continue;
                    // Native safety net: under `--jit-native`, a trace that
                    // records but can't compile to native (unsupported op /
                    // type) would otherwise run on the tier-1a
                    // IR-interpreter, which is ~equal-to-slower than tier-0 on
                    // these bodies — so enabling native codegen *regresses*
                    // the loop vs plain tier-0. Decline to enter it (skip,
                    // never tier-1a) and note it; the post-walk fall-through
                    // gates the anchor *only* if nothing productive ran — so a
                    // native-supported sibling at the same anchor still runs
                    // and never thrashes the gate. `nativeFor` compiles lazily
                    // and memoizes the verdict, so this is one compile attempt
                    // then an O(1) `union` tag read forever (the supported
                    // path below re-reads the page).
                    if (self.trace.config.native_codegen and self.trace.nativeFor(ct) == null) {
                        // Doc 45 D6: a PRECISE candidate that failed native
                        // compilation (unsupported ref shape, materializer
                        // store budget, …) still ENTERS on tier-1a — the
                        // precise executor there is the only one that can run
                        // it, and skipping would orphan the trace forever
                        // (its recording already consumed the anchor's
                        // hot-count; nothing would ever re-record it). The
                        // tier-1a-slower-than-tier-0 rationale behind the
                        // skip is about entry-replay bodies tier-0 can
                        // replay for free; a precise body records effects
                        // tier-0 would re-execute from the anchor anyway.
                        if (ct.code.deopt_mode != .precise) {
                            saw_native_unsupported = true;
                            continue;
                        }
                    }
                    // Phase 0a (doc 20): the whole per-candidate entry +
                    // receipt grammar lives in `enterSelectedTrace`; this
                    // switch is the caller-owned epilogue the safe-point drain
                    // hooks (§R3-3).
                    var wctx: TrialWalkCtx = .{
                        .visited = visited[0..nvisited],
                        .dead = &dead,
                    };
                    const directive = self.enterSelectedTrace(mode, ct, st.closure, proto, regs, st.base, pc, &wctx);
                    // Doc 20 safe-point drain: runs BEFORE acting on any
                    // directive (§R3-1) — every unpatch-producing event inside
                    // the entry routine is flushed here, same turn. Then
                    // re-resolve the fetch image if its generation moved (a
                    // Phase-1 install, or the first clone of this proto's
                    // image).
                    self.trace.drainEntryPatchWork();
                    if (self.trace.registry.entry_registry.image_gen != st.code_gen) {
                        st.code = self.cachedCodeFor(st.frame, proto);
                        st.code_gen = self.trace.registry.entry_registry.image_gen;
                    }
                    switch (directive) {
                        .next_candidate => {},
                        .resume_tier0 => |npc| return .{ .dispatch_at = npc },
                        .switch_mode_at => |npc| return .{ .switch_mode_at = npc },
                        // Doc 44 D11: only head pages emit the push epilogue.
                        .resume_frame_motion => @panic("native frame motion from a loop-anchor entry"),
                        // Doc 45 D5: relay the precise effect error to the
                        // trampoline (which parks it — never a retry).
                        .raise_at => |r| return .{ .raise_at = r },
                    }
                }
                // Retire traces the walk found permanently dead (lane widened
                // past their guard). Safe now that the same-anchor walk is
                // complete — removing frees the `*Trace` and would otherwise
                // dangle the iterator cursor.
                dead.retire(&self.trace);
                // All traces at this anchor failed, OOM'd, or didn't match the
                // fingerprint.  If at least one trace exists but none matched,
                // count it for side-trace recording.
                if (!any_fingerprint_matched and self.trace.hasTrace(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id })) {
                    self.trace.countFingerprintMiss(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id });
                }
                // Native safety net (part 2): we reach here only when no trace
                // ran productively (a productive entry returns a directive).
                // If the walk skipped a native-unsupported trace, gate the
                // anchor so its next back-edges hit the hot-count skip and
                // tier-0 owns the loop — rather than re-walking + re-compiling
                // every iteration. Guarded on "nothing productive ran", so a
                // native-supported sibling that *did* run never gets gated (it
                // returns `.dispatch_at` and bypasses this). Self-heals via
                // the gate's backoff + `onSideExit` clear.
                if (saw_native_unsupported) {
                    self.trace.gateNativeUnsupported(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id });
                }
                // Doc 20 §R5-1 (codex post-landing blocker on 7fa7e1a): the
                // three sites above — dead-trace retirement, fingerprint-miss,
                // native-unsupported gating — all run AFTER this turn's
                // epilogue drain and can mark bound patches pending. Drain
                // again so the image and registry re-agree same-turn (the
                // `.jfor_loop` arm's §R6-1 recovery would self-heal a missed
                // one, but same-turn is the cheap, prompt path), and
                // re-resolve the fetch image if a drain moved the generation.
                self.trace.drainEntryPatchWork();
                if (self.trace.registry.entry_registry.image_gen != st.code_gen) {
                    st.code = self.cachedCodeFor(st.frame, proto);
                    st.code_gen = self.trace.registry.entry_registry.image_gen;
                }
                // Coherent-state chaining (doc 16, Phase 2) diagnostic: tier-0
                // is about to run this *traced* anchor's body because no trace
                // or chain took over this back-edge — the design's REQUIRED
                // tier-0-outer-body signal. (The back-edge counter is the
                // wrong one: `onBackEdge` returns before incrementing once any
                // trace exists here, so it flattens even under full tier-0
                // fallback.) Guarded on a trace existing so untraced hot loops
                // don't inflate it; a productive trace/chain entry returns a
                // directive above and never reaches here. Under Phase 2 the
                // prime path chains instead of dropping here, so this trends
                // to ~0.
                if (self.trace.hasTrace(.{ .proto = proto, .pc = anchor_pc, .proto_id = proto.id })) {
                    self.trace.tier0_outer_body_entries +|= 1;
                }
                // Fall through to tier-0.
            } else if (eligible and !trip_ok) {
                // Declined a numeric-`for` purely on trip count: cheap-skip
                // the rest of this short invocation so its remaining
                // back-edges don't each re-pay full `onBackEdge` bookkeeping.
                // `trip - 1` exactly covers the remainder (the final
                // `for_loop` exits without a back-edge), so the window never
                // bleeds into the next invocation's (possibly profitable)
                // entry at this same anchor.
                if (for_trips.? >= 2) {
                    self.trace.armShortLoopSkip(proto, anchor_pc, for_trips.? - 1);
                }
            }
            // Reached only when no trace ran this back-edge — a successful
            // trace entry above returns a directive and never gets here. If
            // the anchor is gated, install a hot-count skip window so its next
            // back-edges bypass all of the above.
            self.trace.afterBackEdge(proto, anchor_pc);
        }
        // T3 fast/slow handoff — back-edges are the *only* point a recording
        // can arm (`onBackEdge`), so the check lives here, not
        // per-instruction. `.fast`: if a recording just armed, the loop header
        // (the next instruction) must be mirrored, which `.fast` elides —
        // re-enter `.full`. `.full`: once recording has finished or aborted
        // and no other hook is live, drop back to `.fast`. The back-edge
        // instruction itself is never part of the recorded body (its prologue
        // mirror ran before `onBackEdge` armed), so handing off here is
        // byte-identical to an always-`.full` recording run. The trampoline
        // parks `pc` before handing off, exactly as the `.suspended` path
        // does: re-entry reloads `pc = frame.pc`, so without this the other
        // mode would resume at `cur_pc` and re-run this back-edge.
        if (mode == .fast) {
            if (self.trace.isRecording()) return .{ .switch_mode_at = pc };
        } else {
            if (self.runFastPath()) return .{ .switch_mode_at = pc };
        }
        return .{ .dispatch_at = pc };
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

    /// `R[a] = lhs <op> rhs` for add/sub/mul, computing the hot both-int,
    /// both-float and mixed cases directly on the raw payload lanes (no `Value`
    /// built — the SoA spill/scale win), and deferring every other operand mix
    /// to the exact `arith.*` + `arithMeta` path. Byte-identical to `arith`:
    /// the int path mirrors `Value.int(x +% y)`, the float and mixed paths
    /// `Value.float(x.toFloat() + y.toFloat())` under `@setFloatMode(.strict)`.
    inline fn binNum(self: *Vm, regs: RegWindow, a: usize, o: ArithOperands, comptime base: bytecode.OpCode) Error!void {
        if (o.bothInt()) {
            const x: i64 = @bitCast(o.lb());
            const y: i64 = @bitCast(o.rb());
            regs.setInt(a, switch (base) {
                .add => x +% y,
                .sub => x -% y,
                .mul => x *% y,
                else => comptime unreachable,
            });
        } else if (o.bothFloat()) {
            @setFloatMode(.strict);
            regs.setFloat(a, floatBin(base, @bitCast(o.lb()), @bitCast(o.rb())));
        } else if (o.bothNumber()) {
            @setFloatMode(.strict);
            regs.setFloat(a, floatBin(base, o.lhsFloat(), o.rhsFloat()));
        } else {
            try self.arithGeneric(base, regs, a, o);
        }
    }

    inline fn floatBin(comptime base: bytecode.OpCode, x: f64, y: f64) f64 {
        @setFloatMode(.strict);
        return switch (base) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            else => comptime unreachable,
        };
    }

    /// The numeric-`for` step shared by `for_loop` and `jfor_loop`, over
    /// `R[a..a+3) = (idx, limit, step)`: `idx += step`, written back, then the
    /// limit test in the step's direction. Returns whether the loop goes on.
    /// An int index with an int step, or a float index with a float step,
    /// computes on the raw lanes with exactly `arith`'s semantics: the float
    /// add is strict, a limit of the other number type compares exactly
    /// (`compareNumeric`, as `arith.forWithin` does), and a NaN fails the test
    /// (`.unordered`). An int add that overflows ends the loop, as in Lua 5.4:
    /// the true sum is past every int, so past an int limit and past the int
    /// Lua 5.4 clips a float limit to (the wrapped sum is written back,
    /// unread). Any other mix takes `arith`.
    inline fn forLoopStep(regs: RegWindow, a: usize) Error!bool {
        const ti = regs.tagAt(a);
        const tl = regs.tagAt(a + 1);
        const ts = regs.tagAt(a + 2);
        if (ti == .int and ts == .int and (tl == .int or tl == .float)) {
            const step: i64 = @bitCast(regs.bitsAt(a + 2));
            const sum = @addWithOverflow(@as(i64, @bitCast(regs.bitsAt(a))), step);
            const idx: i64 = sum[0];
            regs.setInt(a, idx);
            if (sum[1] != 0) return false;
            if (tl == .int) {
                const limit: i64 = @bitCast(regs.bitsAt(a + 1));
                return if (step > 0) idx <= limit else limit <= idx;
            }
            // `for i = 1, n / 2`: an int loop with a float limit.
            const o = value.compareNumeric(Value.int(idx), Value.float(@bitCast(regs.bitsAt(a + 1))));
            return if (step > 0) o == .lt or o == .eq else o == .gt or o == .eq;
        }
        if (ti == .float and ts == .float and (tl == .float or tl == .int)) {
            @setFloatMode(.strict);
            const step: f64 = @bitCast(regs.bitsAt(a + 2));
            const idx: f64 = @as(f64, @bitCast(regs.bitsAt(a))) + step;
            regs.setFloat(a, idx);
            if (tl == .float) {
                const limit: f64 = @bitCast(regs.bitsAt(a + 1));
                return if (step > 0) idx <= limit else limit <= idx;
            }
            const o = value.compareNumeric(Value.float(idx), Value.int(@bitCast(regs.bitsAt(a + 1))));
            return if (step > 0) o == .lt or o == .eq else o == .gt or o == .eq;
        }
        return forLoopStepMixed(regs, a);
    }

    /// `forLoopStep`'s mixed-type remainder (a float index with an int step:
    /// `for_prep` makes the index a float whenever the step is one), kept out
    /// of line so the raw lanes above don't share a frame with the `arith`
    /// calls. The add can't overflow, as its result is a float.
    noinline fn forLoopStepMixed(regs: RegWindow, a: usize) Error!bool {
        regs.set(a, try arith.add(regs.get(a), regs.get(a + 2)));
        const limit = regs.get(a + 1);
        if (!limit.isNumber()) return Error.TypeError;
        return arith.forWithin(regs.get(a), limit, regs.get(a + 2));
    }

    /// Wrap a raw binary arithmetic/bitwise result: on `TypeError` (an operand
    /// the operator doesn't accept) fall back to the binary metamethod `name`;
    /// any other arith error (e.g. `DivisionByZero`) propagates unchanged.
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
    /// table/userdata pairs; mahina has only tables). The handler result is taken
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
            // scan fire at most once per table. The globals table never
            // qualifies: global stores (`set_global`, the C API) write it raw,
            // and a grid takes no raw store (Table.set).
            if (!t.array.isGrid() and !t.no_grid) {
                if (t == self.globals or !self.heap.inflateToGrid(t)) t.no_grid = true;
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

    /// `indexGet` of heap key `key` on table `first`, for as long as every
    /// step is a raw probe: the value along the `__index` chain of tables,
    /// or null when the chain reaches what only `indexGet` handles (a grid,
    /// which it deflates; a functional `__index`; a chain of
    /// `max_metatable_chain` hops, where it raises). A heap key lives only in
    /// a hash part, and a metatable's `__index` is a raw read, so the answer
    /// is `indexGet`'s. Calls nothing, so `get_index` keeps it inline.
    inline fn heapKeyChainGet(self: *Vm, first: *table.Table, key: Value) ?Value {
        var t = first;
        var hops: usize = 0;
        while (hops < max_metatable_chain) : (hops += 1) {
            if (t.array.isGrid()) return null;
            if (t.hash.liveHeapNode(key)) |n| return n.value;
            const mt = t.metatable orelse return Value.nil();
            const handler = (mt.hash.liveHeapNode(self.mm.index) orelse return Value.nil()).value;
            if (!(handler.isHeap() and handler.heapType() == .table)) return null;
            t = table.Table.fromHeader(handler.asHeap());
        }
        return null;
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
        try self.appendOpenUpvalue(index, cell);
        return cell;
    }

    /// Doc 54 P1: the ONLY append into `open_upvalues` — owns the ceiling
    /// raise (`@max`, so the watermark can never go stale-LOW on an open).
    /// Pub for the keyframe restorer's list rebuild and for tests; interp-
    /// internal opens (`captureUpvalue`) route through here too.
    pub fn appendOpenUpvalue(self: *Vm, index: usize, cell: *function.Upvalue) std.mem.Allocator.Error!void {
        try self.open_upvalues.append(self.gpa, .{ .index = index, .cell = cell });
        self.open_upvalue_ceiling = @max(self.open_upvalue_ceiling, index + 1);
    }

    /// Doc 54 P1: the ONLY wholesale clear of `open_upvalues` (tests) — the
    /// ceiling resets with the list, keeping the pair coherent.
    pub fn clearOpenUpvalues(self: *Vm) void {
        self.open_upvalues.clearRetainingCapacity();
        self.open_upvalue_ceiling = 0;
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
        // Doc 54 P1: exact ceiling recompute — this call already visits the
        // whole list, so the survivor pass keeps the watermark tight (and 0
        // on empty) with no separate maintenance site to forget.
        var ceiling: usize = 0;
        for (self.open_upvalues.items) |ou| ceiling = @max(ceiling, ou.index + 1);
        self.open_upvalue_ceiling = ceiling;
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
        Error.ForStepZero,
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

/// Doc 66 P3: an arithmetic or bitwise instruction's operands in source
/// order, for fault rendering: a constant form's `K[c]` on its side.
fn arithOperandValues(proto: *const bytecode.Proto, regs: RegWindow, instr: Instr, shape: bytecode.ArithShape) [2]Value {
    return switch (shape) {
        .rr => .{ regs.get(instr.b), regs.get(instr.c) },
        .rk => .{ regs.get(instr.b), proto.constants[instr.c] },
        .kr => .{ proto.constants[instr.c], regs.get(instr.b) },
    };
}

/// For an arithmetic fault on `x op y`, the operand that wasn't a number (the
/// one to blame). Falls back to `x` if both are numbers (shouldn't happen — the
/// op only faults when one isn't).
fn firstNonNumber(x: Value, y: Value) Value {
    return if (!x.isNumber()) x else y;
}

/// The operand a bitwise op couldn't use: the first that is not an integer. A
/// float counts as non-integer here — mahina's bitwise ops require integer operands
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

/// For a concatenation fault, the operand mahina's `concat` couldn't coerce —
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
///
/// The cursor advances ONLY on acceptance — a rejected entry (wrong kind) stays
/// IN FRONT of the cursor. Cursor position is thereby a truthful record of
/// "entries consumed successfully", which `versionAlreadyConsumed`'s prefix scan
/// depends on: were a failed entry left behind the cursor, a later retry (a host
/// re-running a faulted-but-live VM, or a snapshot-resume) would mistake it for
/// a validated pin. Consumers whose validation goes BEYOND the kind (the Unicode
/// version check) must follow the same rule: peek via `peekLoggedEffect`,
/// validate, and only then advance.
fn nextLoggedEffect(self: *Vm, kind: EffectKind) Error!Value {
    const v = try peekLoggedEffect(self, kind);
    self.effect_cursor += 1;
    return v;
}

/// The non-consuming half of `nextLoggedEffect`: bounds- and kind-check the
/// entry at the cursor and return its result WITHOUT advancing. For consumers
/// that must validate the value itself before committing the consume
/// (`noteUnicodeVersion`) — see the cursor-truthfulness contract above.
fn peekLoggedEffect(self: *Vm, kind: EffectKind) Error!Value {
    if (self.effect_cursor >= self.effect_log.items.len) return Error.EffectLogExhausted;
    const e = self.effect_log.items[self.effect_cursor];
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
                // Peek, validate, THEN consume (the cursor-truthfulness contract
                // on `nextLoggedEffect`): on a mismatch the wrong-version entry
                // must stay IN FRONT of the cursor, so any later retry — a host
                // re-running this faulted-but-live VM, or a resumed session —
                // re-validates and re-raises instead of finding the entry behind
                // the cursor via `versionAlreadyConsumed` and silently pinning
                // the MISMATCHED table.
                const v = try peekLoggedEffect(self, .unicode_version);
                // The shared scalar shape-gate (effectser.checkResultShape) accepts
                // *either* int or float, so a corrupt log could park a float here;
                // `asInt()` asserts int. Treat a non-int version as a mismatch (a log
                // we cannot read the version from is, for our purposes, the wrong
                // version) rather than asserting on hostile bytes.
                if (v.tag != .int or v.asInt() != @as(i64, unicode_case.unicode_version_packed))
                    return Error.UnicodeVersionMismatch;
                self.effect_cursor += 1; // accepted — consume
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

/// `os.nsclock()` — a mahina extension (no Lua equivalent): the same host monotonic
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
/// mahina is Lua-*shaped*, not stream-compatible: the distribution matches PUC's
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
/// `RandomUnavailable` when no source is injected. mahina's Xoshiro256 takes a single
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
    if (to_stdout) io.stdoutWrote(true);
    return Value.nil();
}

/// `warn(msg1, ···)` — Lua 5.4 diagnostic warnings (lbaselib.c `luaB_warn` +
/// lauxlib.c default handler). Every argument must be a string. A *single* piece
/// beginning with `@` is a control message — recognized even while warnings are
/// off, so `@on` can re-enable: `@off` stops emission, `@on` restarts, any other
/// `@…` is ignored. Otherwise, when enabled, the string arguments are concatenated
/// and emitted as one line, prefixed `mahina warning: `, to stderr (`Vm.err`, or the
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

/// Write one assembled `mahina warning: <args…>\n` line. Split out so `nativeWarn`
/// can treat the whole emission as a single best-effort unit (`catch {}`).
fn emitWarning(w: *io.Writer, args: []const Value) !void {
    try w.writeAll("mahina warning: ");
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
    var newline = false;
    for (args) |a| {
        const bytes = try coerceConcat(a, &buf);
        try w.writeAll(bytes);
        if (to_stdout and !newline) newline = std.mem.indexOfScalar(u8, bytes, '\n') != null;
    }
    if (to_stdout) io.stdoutWrote(newline);
    return Value.nil();
}

/// `io.flush()`: push buffered output out now. stdout is fully buffered when
/// it is not a terminal (doc 65 §6), so a script that wants a progress line
/// seen before a long computation flushes it. Flushes the VM's output seam
/// (`Vm.out`) when one is set, else the process stdout. Returns `true`, as
/// Lua's does; a failed flush raises (doc 65 §4.4).
fn nativeIoFlush(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const w = vm.out orelse io.stdout();
    try w.flush();
    return Value.boolean(true);
}

/// Coerce a concat operand to bytes: a string's own bytes, or a number formatted
/// into `buf` (at least `io.float_text_max` bytes) as `tostring` renders it.
/// Returns a slice valid until `buf` is reused.
pub fn coerceConcat(v: Value, buf: []u8) Error![]const u8 {
    return switch (v.tag) {
        .heap_ref => if (v.heapType() == .string)
            string.String.fromHeader(v.asHeap()).bytes()
        else
            Error.TypeError,
        .int => std.fmt.bufPrint(buf, "{d}", .{v.asInt()}) catch unreachable,
        .float => io.formatFloat(buf, v.asFloat()),
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
    return if (fetched.op == .jfor_loop or fetched.op == .jloop or fetched.op == .jfunc_head or fetched.op == .jcont) proto.code[pc] else fetched;
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
    _ = @import("interp_dispatch_test.zig");
    _ = @import("interp_gc_test.zig");
    _ = @import("interp_phaseq_test.zig");
    _ = @import("interp_trace_test.zig");
    _ = @import("interp_fastblock_test.zig");
    _ = @import("interp_tier1a_test.zig");
    _ = @import("interp_native_test.zig");
    _ = @import("interp_lanes_test.zig");
    _ = @import("interp_exit_side_test.zig");
    _ = @import("interp_nest_test.zig");
    _ = @import("interp_bool_test.zig");
}
