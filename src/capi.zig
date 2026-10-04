//! mahina — the C-ABI embedding surface (`libmahina`), doc 59.
//!
//! The ONE file that speaks C ABI (Rule Z-2): a host application (the
//! motivating case: a Rust app via `embed/rust/`) links `libmahina.a` and
//! drives the VM through the `mh_*` exports declared in `include/mahina.h`.
//! The VM core knows nothing about C — the three seams it carries for
//! embedding (`Vm.host_refs`/`parked_results` roots, `function.HostBinding`,
//! the `loaded_chunks` program-image ownership) are generic Zig.
//!
//! The load-bearing contracts (all from doc 59, reviewed):
//!
//! **Rooting (§3.3).** Three `.gc`-walk-only roots cover every way a heap
//! value can be live on the host side: `host_refs` (explicit, generational,
//! long-lived), `parked_results` (every heap value an entry hands out is
//! copied here first), and the callback window (a host fn's `args` live in
//! the caller's rooted registers). The park is cleared only at an **idle-VM**
//! entry (depth 0, no native reentry) that may allocate or run guest code —
//! and such an entry re-parks its own heap-value *arguments* before doing
//! anything that can collect, so "pass a parked value back in" is race-free.
//! Nested entries (from inside a host callback) never clear, so values a
//! callback creates stay rooted until the host's outermost call completes.
//!
//! **Program images (§3.2).** `mh_compile`/`mh_eval` append to
//! `vm.loaded_chunks` — the VM owns every compiled chunk + source copy until
//! `mh_vm_free`, exactly like guest `load()`. Proto ids come from
//! `vm.next_proto_id` so they are VM-unique (the JIT's `guard_func` keys on
//! them). `mh_script_free` frees only the handle.
//!
//! **Protected entries (§3.6).** Every entry that runs guest code captures
//! the VM boundary and, on a catchable fault, renders the located message
//! (while the faulting frames are live) and restores depth/stack/upvalues/
//! region state — the `pcall` recipe — so the VM stays reusable. A
//! non-catchable fault (OOM, replay integrity) marks the VM fatal: further
//! guest-running entries refuse with `MH_ERR_API`.
//!
//! **Values.** `mh_value` is layout-identical to `value.Value` (asserted
//! below) but opaque to the embedder: the public type surface is `mh_type`
//! via `mh_value_type`; internal tag ordinals are not ABI. Tag bytes arriving
//! from C are validated before the value touches the VM; `row_view` never
//! crosses in either direction.
//!
//! Thread discipline: one VM, one thread at a time. Not thread-safe.

const std = @import("std");
const builtin = @import("builtin");
const mahina = @import("mahina");

const interp = mahina.interp;
const function = mahina.function;
const value = mahina.value;
const compiler = mahina.compiler;
const parser = mahina.parser;
const diag = mahina.diag;
const table = mahina.table;
const mem = mahina.mem;
const io = mahina.io;
const key_order = mahina.key_order;

const Value = mahina.Value;
const Vm = interp.Vm;
const Table = table.Table;
const Proto = mahina.bytecode.Proto;

/// Backing allocator for the exported entry points: malloc, the natural
/// choice for a C library (tests use `createVm` with `std.testing.allocator`
/// instead, so leaks fail the suite).
const c_gpa = std.heap.c_allocator;

/// Doc 60 §3.1: whether this target links the hand-written host-call entry
/// (`src/asm/hostcall_x64.S`). The same predicate gates the file in
/// `build.zig`, so the entry is linked exactly when `mh_call` refers to it.
const hostcall_asm = @import("asm/target.zig").hostcallEntry(&builtin.target);

/// The `.S` entry: `mh_call`'s signature, under `mh_call`'s narrow contract
/// (§4.1). Hidden, the reference included (§6.3 checks it per object); only
/// `mh_call` calls it, as a tail call.
const asm_entry = if (hostcall_asm) struct {
    const mahina_hostcall_entry = @extern(
        *const fn (vm: ?*VmBox, callee: mh_value, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: ?*usize) callconv(.c) mh_status,
        .{ .name = "mahina_hostcall_entry", .visibility = .hidden },
    );
} else struct {};

comptime {
    if (hostcall_asm) {
        // The comptime check of the offsets file the entry is assembled with.
        _ = @import("asm/offsets_x64.zig");
        // H1, under the name the entry's fallback edge jumps to. Hidden: the
        // only default-visibility host-call symbol stays `mh_call` (§4.2).
        @export(&hostcallSlow, .{ .name = "mahina_hostcall_slow", .visibility = .hidden });
    }
}

// The static library is linked by a foreign toolchain (cc, rustc), so it must
// supply `__zig_probe_stack` — the x86 stack-probe routine LLVM calls for
// frames larger than a page — itself. It must NOT bundle the rest of Zig's
// compiler-rt: that brings its own memset/memcpy/memmove, which the host's
// linker then resolves for the WHOLE host process instead of libc's (Zig's
// memset is a byte loop — it made the Rust crate's call 47% memset). Weak, so
// another Zig library carrying full compiler-rt in the same host still links.
// Body: lib/compiler_rt/stack_probe.zig of the pinned toolchain.
comptime {
    if (builtin.output_mode == .Lib and builtin.cpu.arch == .x86_64)
        @export(&zigProbeStack, .{ .name = "__zig_probe_stack", .linkage = .weak, .visibility = .hidden });
}

fn zigProbeStack() callconv(.naked) void {
    // %rax = probe length, %rsp = stack pointer. Touch every page between the
    // current and the new stack pointer so a guard page is never skipped.
    asm volatile (
        \\        push   %%rcx
        \\        mov    %%rax, %%rcx
        \\        cmp    $0x1000,%%rcx
        \\        jb     2f
        \\ 1:
        \\        sub    $0x1000,%%rsp
        \\        orl    $0,16(%%rsp)
        \\        sub    $0x1000,%%rcx
        \\        cmp    $0x1000,%%rcx
        \\        ja     1b
        \\ 2:
        \\        sub    %%rcx, %%rsp
        \\        orl    $0,16(%%rsp)
        \\        add    %%rax,%%rsp
        \\        pop    %%rcx
        \\        ret
    );
}

// ---------------------------------------------------------------------------
// public C types (mirrored in include/mahina.h — keep in lockstep)
// ---------------------------------------------------------------------------

pub const mh_status = enum(c_int) {
    ok = 0,
    err_compile = 1,
    err_runtime = 2,
    err_oom = 3,
    err_api = 4,
};

/// The public value *type* — a stable wire enum, deliberately decoupled from
/// the internal `value.Tag` ordinals (which may churn; these must not).
pub const mh_type = enum(c_int) {
    nil = 0,
    boolean = 1,
    int = 2,
    float = 3,
    string = 4,
    table = 5,
    function = 6,
    other = 7,
};

/// Borrowed bytes + length (never NUL-terminated by contract).
pub const mh_str = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

/// A guest value crossing the boundary. Layout-identical to `value.Value`
/// (asserted below); treat as opaque 16 bytes — construct and inspect only
/// through the `mh_*` value functions.
pub const mh_value = extern struct {
    tag: u8 = 0,
    _pad: [7]u8 = @splat(0),
    payload: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(mh_value) == 16);
    std.debug.assert(@sizeOf(Value) == 16);
    std.debug.assert(@offsetOf(mh_value, "payload") == 8);
    std.debug.assert(@offsetOf(Value, "payload") == 8);
    std.debug.assert(@sizeOf(mh_str) == @sizeOf(usize) * 2);
}

/// VM creation options. Zero-initialized = defaults. `jit`: 0 = default (on),
/// 1 = on, 2 = off — a tri-state so "default" and "explicitly off" are
/// distinguishable (doc 59 §3.7).
pub const mh_config = extern struct {
    jit: c_int = 0,
};

pub const mh_mem_stats = extern struct {
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    total_bytes: usize = 0,
    live_allocations: usize = 0,
};

/// A registered host function (doc 59 §3.5). Multi-result from day one: write
/// up to `max_results` values into `results`, set `*nresults`, return
/// `MH_OK`. Any other status raises a guest error (catchable by `pcall`)
/// carrying the message last set with `mh_error_set`. `args` and `results`
/// never alias. The `vm` handle may be used reentrantly (call back into the
/// guest) — but never `mh_vm_free`d from inside the callback.
pub const mh_host_fn = *const fn (
    vm: ?*VmBox,
    userdata: ?*anyopaque,
    args: ?[*]const mh_value,
    nargs: usize,
    results: ?[*]mh_value,
    max_results: usize,
    nresults: *usize,
) callconv(.c) mh_status;

pub const mh_host_fn_destroy = *const fn (userdata: ?*anyopaque) callconv(.c) void;

// ---------------------------------------------------------------------------
// handles
// ---------------------------------------------------------------------------

/// The `mh_vm` handle: the VM plus everything box-level the C surface needs.
/// Field order matters for init (tracking before vm — the allocator handle
/// stores a pointer back into the box, which must be at its final address).
pub const VmBox = struct {
    /// Allocates the box itself + handle boxes + error buffers. The VM's own
    /// memory goes through `tracking` so `mh_mem_stats` sees it.
    backing: std.mem.Allocator,
    tracking: mem.TrackingAllocator,
    vm: Vm,
    /// `print`/`io.write` and `warn` sinks (doc 59 §3.7: nothing escapes to
    /// the process's real stdout/stderr).
    out_sink: io.Writer.Allocating,
    err_sink: io.Writer.Allocating,
    /// Rendered message of the last failing call (`mh_last_error`).
    last_error: std.ArrayList(u8) = .empty,
    /// Message staged by `mh_error_set` for the next failing host callback.
    host_error: std.ArrayList(u8) = .empty,
    /// A non-catchable fault (OOM, replay integrity) poisoned the VM: no more
    /// guest-running entries (doc 59 §3.6).
    fatal: bool = false,
};

/// The `mh_script` handle: a VM-owned program image (see file header). The
/// box is just `{owner, root proto}` — freeing it frees nothing of the image.
pub const ScriptBox = struct {
    owner: *VmBox,
    proto: *const Proto,
};

/// A table iterator (doc 59 §3.4): the deterministic key order materialized
/// ONCE (array part ascending, then hash keys in canonical order — exactly
/// `next`'s order) into a guest table rooted by a host ref, then walked in
/// O(1) per step. Values are read live at each step; keys deleted since
/// `iter_new` are skipped, insertions are not observed.
pub const IterBox = struct {
    owner: *VmBox,
    tbl_ref: u64,
    keys_ref: u64,
    len: usize,
    idx: usize = 0,
};

// ---------------------------------------------------------------------------
// value conversion + validation
// ---------------------------------------------------------------------------

// Conversions are built field by field, never `@bitCast` between the two
// 16-byte structs: a bitcast round-trips through memory as a tag-byte store
// plus a 16-byte reload, which cannot store-forward (see `Value.storeWords`).
// Field-wise, both halves stay in registers — an `mh_value` passed or
// returned by value travels as two 8-byte words.
inline fn toC(v: Value) mh_value {
    std.debug.assert(v.tag != .row_view); // never escapes (doc 59 §3.2)
    return .{ .tag = @intFromEnum(v.tag), .payload = v.payload.bits };
}

/// Write `v` to a C out-pointer as two whole words (`Value.storeWords`), so
/// the host's 8-byte reads of the result forward instead of stalling.
inline fn putC(o: *mh_value, v: Value) void {
    std.debug.assert(v.tag != .row_view); // never escapes (doc 59 §3.2)
    Value.storeWords(@ptrCast(o), v);
}

/// Validate a value arriving from C. Rejects unknown tag bytes, `row_view`
/// (never handed out, so receiving one is API misuse), and a null heap
/// pointer. Garbage *non-null* heap pointers are undetectable — the usual
/// Lua-C-API-grade unsafety, documented in the header.
fn fromC(cv: mh_value) ?Value {
    const max_tag = @intFromEnum(value.Tag.row_view);
    if (cv.tag >= max_tag) return null; // unknown tags AND row_view
    if (cv.tag == @intFromEnum(value.Tag.heap_ref) and cv.payload == 0) return null;
    return .{ .tag = @enumFromInt(cv.tag), .payload = .{ .bits = cv.payload } };
}

fn typeOf(v: Value) mh_type {
    return switch (v.tag) {
        .nil => .nil,
        .boolean => .boolean,
        .int => .int,
        .float => .float,
        .heap_ref => switch (v.heapType()) {
            .string => .string,
            .table, .typed_array => .table,
            .function, .native => .function,
            else => .other,
        },
        .row_view => .other, // unreachable by contract; stay defensive
    };
}

fn strSlice(s: mh_str) ?[]const u8 {
    if (s.len == 0) return "";
    const p = s.ptr orelse return null;
    return p[0..s.len];
}

fn asStr(bytes: []const u8) mh_str {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

// ---------------------------------------------------------------------------
// box plumbing: errors, parking, protected entries
// ---------------------------------------------------------------------------

fn setLastError(box: *VmBox, msg: []const u8) void {
    box.last_error.clearRetainingCapacity();
    box.last_error.appendSlice(box.backing, msg) catch {};
}

fn setLastErrorFmt(box: *VmBox, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    setLastError(box, msg);
}

/// True when the VM is idle (no guest frames, no native reentry) — the only
/// state in which the parked-results root may be cleared (doc 59 §3.3).
inline fn vmIdle(box: *const VmBox) bool {
    return box.vm.depth == 0 and box.vm.native_reentry_depth == 0;
}

/// Entry prologue for every call that may allocate or run guest code: clear
/// the park iff idle. Callers with heap-value *arguments* must re-park them
/// (`park`) immediately after this, before anything that can collect.
fn parkClearIfIdle(box: *VmBox) void {
    if (vmIdle(box)) {
        box.vm.parked_inline_len = 0;
        box.vm.parked_results.clearRetainingCapacity();
    }
}

/// Root a value in the park. Appending never triggers a collection (the GC
/// runs only at VM allocation sites), so parking freshly-received C arguments
/// is safe even before they are otherwise rooted. The inline slots in the Vm
/// struct take the common 1–3 values of an entry (warm lines — see the
/// `parked_inline` doc comment); the ArrayList is overflow only.
fn park(box: *VmBox, v: Value) mh_status {
    if (!v.isHeap()) return .ok;
    const vm = &box.vm;
    if (vm.parked_inline_len < vm.parked_inline.len) {
        Value.storeWords(&vm.parked_inline[vm.parked_inline_len], v);
        vm.parked_inline_len += 1;
        return .ok;
    }
    vm.parked_results.append(vm.gpa, v) catch return oom(box);
    return .ok;
}

fn oom(box: *VmBox) mh_status {
    setLastError(box, "out of memory");
    return .err_oom;
}

/// Handle a fault from guest execution: render the located message while the
/// faulting frames are live, then either restore the boundary (catchable —
/// the `pcall` recipe, doc 59 §3.6) or mark the VM fatal (non-catchable).
fn guestFault(box: *VmBox, entry_depth: u32, entry_top: usize, err: interp.Error) mh_status {
    const vm = &box.vm;
    renderFault(box, err);
    if (!interp.catchable(err)) {
        box.fatal = true;
        return if (err == error.OutOfMemory) .err_oom else .err_runtime;
    }
    vm.pending_error = null;
    vm.closeUpvaluesFrom(entry_top);
    vm.dropRegionActivationsFromDepth(entry_depth);
    vm.depth = entry_depth;
    vm.stack_top = entry_top;
    vm.final_cut = null;
    return .err_runtime;
}

/// Render a runtime fault into `last_error`, Lua-style (`name:line: msg`)
/// when a location is known. Reads the still-live faulting frames; a failure
/// to allocate the pretty message degrades to the bare error name.
fn renderFault(box: *VmBox, err: interp.Error) void {
    const vm = &box.vm;
    var arena = std.heap.ArenaAllocator.init(box.backing);
    defer arena.deinit();
    const fault = vm.describeFault("", err, arena.allocator()) catch {
        setLastError(box, @errorName(err));
        return;
    };
    if (!fault.self_located and fault.line > 0 and fault.frames.len > 0) {
        setLastErrorFmt(box, "{s}:{d}: {s}", .{ fault.frames[0].name, fault.line, fault.message });
    } else {
        setLastError(box, fault.message);
    }
}

/// Refuse entry when a prior non-catchable fault poisoned the VM.
fn checkFatal(box: *VmBox) ?mh_status {
    if (box.fatal) {
        setLastError(box, "VM is in a fatal state (prior non-catchable error)");
        return .err_api;
    }
    return null;
}

/// Run `callee(args...)` protected, writing into `results` (pre-nil-filled
/// here). On success parks every heap result and returns the produced count
/// via `nresults`. `inline`: two callers, and as a separate function it was
/// a second prologue/epilogue plus argument shuffle on every embedder call.
inline fn runProtected(box: *VmBox, callee: Value, args: []const Value, results: []Value, nresults: *usize) mh_status {
    const vm = &box.vm;
    nresults.* = 0;
    // No defensive nil-fill of `results`: the contract (mahina.h) is that only
    // results[0..*nresults] are defined. `callValue` writes exactly the
    // `produced` prefix it reports, and the fill cost O(max_results) stores on
    // every call (17+ instructions even for a 1-slot buffer).
    const entry_depth = vm.depth;
    const entry_top = vm.stack_top;
    const produced = vm.callValue(callee, args, results) catch |e| return guestFault(box, entry_depth, entry_top, e);
    std.debug.assert(vm.pending_error == null);
    for (results[0..produced]) |*r| {
        if (park(box, Value.loadWords(r)) != .ok) return .err_oom;
    }
    nresults.* = produced;
    return .ok;
}

// ---------------------------------------------------------------------------
// VM lifecycle
// ---------------------------------------------------------------------------

/// Host clock/seed sources — the CLI's real ones (`main.zig`), Linux-only
/// like the CLI; the VM core never sees a syscall.
var host_src_ctx: u8 = 0;

fn hostClockNs(_: *anyopaque) i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

fn hostRandomSeed(_: *anyopaque) u64 {
    var bytes: [8]u8 = undefined;
    _ = std.os.linux.getrandom(&bytes, bytes.len, 0);
    return std.mem.readInt(u64, &bytes, .little);
}

/// Internal constructor, parameterized on the backing allocator so tests run
/// on `std.testing.allocator` (leak-checked) while the C export uses malloc.
pub fn createVm(backing: std.mem.Allocator, config: mh_config) !*VmBox {
    // Doc 60 §3.2: what comptime can't check about the entry's offsets is a
    // hard stop here, for every VM (the tests' included), never a silent
    // miscompute — the slices' {ptr, len} word order (Q12 (a)), and that the
    // `.S` was assembled with this build's safety-mode offsets block.
    if (hostcall_asm) {
        const offsets = @import("asm/offsets_x64.zig");
        if (!offsets.verifySliceLayout())
            @panic("mahina: slice layout differs from src/asm/offsets_x64.inc (doc 60 Q12)");
        if (!offsets.verifyAssembledMode())
            @panic("mahina: hostcall_x64.S was assembled for the other runtime-safety mode (doc 60 §3.2)");
    }
    if (config.jit < 0 or config.jit > 2) return error.InvalidConfig;
    const box = try backing.create(VmBox);
    errdefer backing.destroy(box);
    box.* = .{
        .backing = backing,
        .tracking = mem.TrackingAllocator.init(backing),
        .vm = undefined,
        .out_sink = undefined,
        .err_sink = undefined,
    };
    // `tracking` is at its final address now — safe to hand out its handle.
    box.vm = try Vm.init(box.tracking.allocator());
    errdefer box.vm.deinit();
    box.out_sink = io.Writer.Allocating.init(box.tracking.allocator());
    box.err_sink = io.Writer.Allocating.init(box.tracking.allocator());
    box.vm.out = &box.out_sink.writer;
    box.vm.err = &box.err_sink.writer;
    box.vm.clock_source = .{ .ctx = &host_src_ctx, .nowNs = &hostClockNs };
    box.vm.random_seed_source = .{ .ctx = &host_src_ctx, .seed = &hostRandomSeed };
    // Effects stay `.off` (doc 59 §3.7): plain embedding, no replay. Env/fs
    // sources stay absent — an embedded guest sees the host's environment
    // only if the host grants it (future setters).
    if (config.jit != 2) {
        // Default/on: the CLI's production shape (--trace --jit-native).
        box.vm.trace.config.enabled = true;
        box.vm.trace.config.execute = true;
        box.vm.trace.config.optimize = true;
        box.vm.trace.config.native_codegen = true;
    }
    return box;
}

pub fn destroyVm(box: *VmBox) void {
    const backing = box.backing;
    box.vm.deinit();
    box.out_sink.deinit();
    box.err_sink.deinit();
    box.last_error.deinit(backing);
    box.host_error.deinit(backing);
    backing.destroy(box);
}

pub export fn mh_vm_new(config: ?*const mh_config, out: ?**VmBox) mh_status {
    const o = out orelse return .err_api;
    const cfg: mh_config = if (config) |c| c.* else .{};
    o.* = createVm(c_gpa, cfg) catch |e| switch (e) {
        error.OutOfMemory => return .err_oom,
        else => return .err_api,
    };
    return .ok;
}

pub export fn mh_vm_free(vm: ?*VmBox) mh_status {
    const box = vm orelse return .ok;
    // Freeing mid-callback (or with guest frames live) would free the stack
    // under the running guest — a checked API error (doc 59 §3.2).
    if (!vmIdle(box)) {
        setLastError(box, "mh_vm_free while the VM is executing");
        return .err_api;
    }
    destroyVm(box);
    return .ok;
}

pub export fn mh_last_error(vm: ?*VmBox) mh_str {
    const box = vm orelse return .{};
    return asStr(box.last_error.items);
}

pub export fn mh_output(vm: ?*VmBox) mh_str {
    const box = vm orelse return .{};
    return asStr(box.out_sink.written());
}

pub export fn mh_output_clear(vm: ?*VmBox) void {
    const box = vm orelse return;
    box.out_sink.clearRetainingCapacity();
}

pub export fn mh_warnings(vm: ?*VmBox) mh_str {
    const box = vm orelse return .{};
    return asStr(box.err_sink.written());
}

pub export fn mh_warnings_clear(vm: ?*VmBox) void {
    const box = vm orelse return;
    box.err_sink.clearRetainingCapacity();
}

pub export fn mh_mem_stats_get(vm: ?*VmBox, out: ?*mh_mem_stats) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    o.* = .{
        .live_bytes = box.tracking.stats.live_bytes,
        .peak_bytes = box.tracking.stats.peak_bytes,
        .total_bytes = box.tracking.stats.total_bytes,
        .live_allocations = box.tracking.stats.live_allocations,
    };
    return .ok;
}

/// Force a full GC cycle. Non-clearing (parked results are roots and must
/// survive an explicit collect — that is the park's whole purpose).
pub export fn mh_collect(vm: ?*VmBox) mh_status {
    const box = vm orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    box.vm.collect();
    return .ok;
}

// ---------------------------------------------------------------------------
// compile / run / eval
// ---------------------------------------------------------------------------

/// Parse + compile into a VM-owned program image (the `load()` recipe:
/// VM-unique proto ids, VM-lifetime chunk + source ownership). On
/// `error.Compile` the diagnostics are already rendered into `last_error`.
fn compileImage(box: *VmBox, src: []const u8, name: []const u8) error{ Compile, OutOfMemory }!*const Proto {
    const vm = &box.vm;
    const owned = try vm.gpa.allocSentinel(u8, src.len, 0);
    @memcpy(owned, src);

    var diags = diag.Diagnostics.init(vm.gpa);
    defer diags.deinit();

    var tree = parser.parse(vm.gpa, owned, &diags) catch {
        setErrorFromDiags(box, &diags);
        vm.gpa.free(owned);
        return error.Compile;
    };
    defer tree.deinit();
    if (diags.hasErrors()) {
        setErrorFromDiags(box, &diags);
        vm.gpa.free(owned);
        return error.Compile;
    }

    var chunk = compiler.compileWithOptions(vm.gpa, vm.heap, owned, tree.root, &diags, .{
        .known_globals = &interp.builtin_global_names,
        .id_base = vm.next_proto_id,
        // Embedder chunks are vararg like `load()`ed ones (top-level `...`).
        .vararg_root = true,
    }) catch {
        setErrorFromDiags(box, &diags);
        vm.gpa.free(owned);
        return error.Compile;
    };
    if (diags.hasErrors()) {
        setErrorFromDiags(box, &diags);
        chunk.deinit();
        vm.gpa.free(owned);
        return error.Compile;
    }

    // Name the top-level proto so faults report `name:line:`. Arena-owned,
    // same as `load()`.
    chunk.proto.name = chunk.arena.allocator().dupe(u8, name) catch {
        chunk.deinit();
        vm.gpa.free(owned);
        return error.OutOfMemory;
    };

    // Ownership handoff — append-first, exactly like `load()` (on an append
    // failure neither is VM-owned yet; after it, both are freed at deinit).
    vm.appendLoadedChunk(.{ .chunk = chunk, .source = owned }) catch {
        chunk.deinit();
        vm.gpa.free(owned);
        return error.OutOfMemory;
    };
    vm.next_proto_id += chunk.proto_count;
    return chunk.proto;
}

fn setErrorFromDiags(box: *VmBox, diags: *const diag.Diagnostics) void {
    box.last_error.clearRetainingCapacity();
    for (diags.list.items) |d| {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}: {s}: {s}\n", .{ d.line, @tagName(d.severity), d.message }) catch continue;
        box.last_error.appendSlice(box.backing, line) catch return;
    }
    if (box.last_error.items.len == 0) setLastError(box, "compile error");
}

/// Run a root proto: fresh closure + protected call. The closure is rooted
/// by the frame the instant `callValue` pushes it; between `newClosure` and
/// that push nothing allocates (straight-line), so no collect window exists.
fn runProto(box: *VmBox, proto: *const Proto, results: []Value, nresults: *usize) mh_status {
    const cl = box.vm.heap.newClosure(proto, 0) catch return oom(box);
    return runProtected(box, Value.heap(&cl.header), &.{}, results, nresults);
}

pub export fn mh_compile(vm: ?*VmBox, src: mh_str, name: mh_str, out: ?**ScriptBox) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const src_bytes = strSlice(src) orelse return badStr(box);
    const name_bytes = strSlice(name) orelse return badStr(box);
    parkClearIfIdle(box);
    const proto = compileImage(box, src_bytes, if (name_bytes.len > 0) name_bytes else "chunk") catch |e| switch (e) {
        error.Compile => return .err_compile,
        error.OutOfMemory => return oom(box),
    };
    const sb = box.backing.create(ScriptBox) catch return oom(box);
    sb.* = .{ .owner = box, .proto = proto };
    o.* = sb;
    return .ok;
}

pub export fn mh_script_free(script: ?*ScriptBox) void {
    const sb = script orelse return;
    sb.owner.backing.destroy(sb);
}

pub export fn mh_run(vm: ?*VmBox, script: ?*ScriptBox, results: ?[*]mh_value, max_results: usize, nresults: ?*usize) mh_status {
    const box = vm orelse return .err_api;
    const sb = script orelse return .err_api;
    const nres = nresults orelse return .err_api;
    nres.* = 0;
    if (checkFatal(box)) |s| return s;
    if (sb.owner != box) {
        setLastError(box, "script belongs to a different VM");
        return .err_api;
    }
    parkClearIfIdle(box);
    return runProto(box, sb.proto, resultsSlice(results, max_results), nres);
}

pub export fn mh_eval(vm: ?*VmBox, src: mh_str, name: mh_str, results: ?[*]mh_value, max_results: usize, nresults: ?*usize) mh_status {
    const box = vm orelse return .err_api;
    const nres = nresults orelse return .err_api;
    nres.* = 0;
    if (checkFatal(box)) |s| return s;
    const src_bytes = strSlice(src) orelse return badStr(box);
    const name_bytes = strSlice(name) orelse return badStr(box);
    parkClearIfIdle(box);
    const proto = compileImage(box, src_bytes, if (name_bytes.len > 0) name_bytes else "chunk") catch |e| switch (e) {
        error.Compile => return .err_compile,
        error.OutOfMemory => return oom(box),
    };
    return runProto(box, proto, resultsSlice(results, max_results), nres);
}

fn badStr(box: *VmBox) mh_status {
    setLastError(box, "invalid mh_str (null ptr with non-zero len)");
    return .err_api;
}

/// Reinterpret the C results buffer as `[]Value` (layout-identical).
fn resultsSlice(results: ?[*]mh_value, max: usize) []Value {
    if (max == 0) return &.{};
    const p = results orelse return &.{};
    const vp: [*]Value = @ptrCast(p);
    return vp[0..max];
}

// ---------------------------------------------------------------------------
// call-in
// ---------------------------------------------------------------------------

/// Doc 60 §4.1 layer 1: the public checks, then a tail call into the entry
/// with the identical signature — H1 (`hostcallSlow`) today; on targets
/// with a hand-written entry (H3) that entry, which falls back to H1 itself.
/// `always_tail` is deliberate: if the toolchain cannot tail-call this
/// seven-parameter C-ABI shape it is a compile error, never a silent extra
/// frame (doc 60 Q11).
pub export fn mh_call(vm: ?*VmBox, callee: mh_value, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: ?*usize) mh_status {
    const box = vm orelse return .err_api;
    const nres = nresults orelse return .err_api;
    nres.* = 0;
    if (checkFatal(box)) |s| return s;
    // A null buffer already meant "no results" (`resultsSlice`); normalizing
    // here means no inner layer sees a null `results` with a nonzero length.
    const max = if (results == null) 0 else max_results;
    if (hostcall_asm)
        return @call(.always_tail, asm_entry.mahina_hostcall_entry, .{ box, callee, args, nargs, results, max, nres });
    return @call(.always_tail, hostcallSlow, .{ box, callee, args, nargs, results, max, nres });
}

/// Doc 60 H1: the minimal-work host call, in Zig — the reference entry, the
/// fallback for every pre-commit rejection of a hand-written entry, and the
/// whole path on targets without one. Narrow contract (established by
/// `mh_call`): `vm`/`nresults` non-null, VM not fatal, `*nresults == 0`,
/// `results` non-null whenever `max_results > 0`. Closure callees take the
/// dedicated push + `runPushedFrame` path; natives, `__call` targets and
/// type errors keep going through `callValue` (`runProtected`) unchanged.
fn hostcallSlow(vm: ?*VmBox, callee: mh_value, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: ?*usize) callconv(.c) mh_status {
    const box = vm.?;
    const nres = nresults.?;
    // Doc 60 §5.4 check site 3: every H1 entry, whatever routed it here.
    if (std.debug.runtime_safety) std.debug.assert(box.vm.trace.fast_block == box.vm.fastBlockReference());
    std.debug.assert(nres.* == 0 and !box.fatal and (max_results == 0 or results != null));
    const cv = fromC(callee) orelse return badValue(box);
    const cargs = argsSlice(box, args, nargs) orelse return badValue(box);
    // Doc 59 §3.3: clear-then-re-park — the incoming values may live only in
    // the (just-cleared) park, so root them again before anything collects.
    parkClearIfIdle(box);
    if (park(box, cv) != .ok) return .err_oom;
    for (cargs) |*a| if (park(box, Value.loadWords(a)) != .ok) return .err_oom;
    const out = resultsSlice(results, max_results);
    if (cv.isHeap() and cv.heapType() == .function)
        return callClosure(box, function.Closure.fromHeader(cv.asHeap()), cargs, out, nres);
    return runProtected(box, cv, cargs, out, nres);
}

/// Doc 60 H1 closure path: `callValue`'s closure arm without its generic
/// dispatch, wrapped like `runProtected` — push, run, copy out, restore,
/// park results. The observable contract (results, parks, errors, VM state)
/// is `runProtected`'s; the stage-1 differential tests hold it to that.
inline fn callClosure(box: *VmBox, cl: *const function.Closure, args: []const Value, results: []Value, nres: *usize) mh_status {
    const vm = &box.vm;
    const entry_depth = vm.depth;
    const entry_top = vm.stack_top;
    const base = vm.pushHostCall(cl, args) catch |e| return guestFault(box, entry_depth, entry_top, e);
    const fr = vm.runPushedFrame(entry_depth, base) catch |e| return guestFault(box, entry_depth, entry_top, e);
    std.debug.assert(vm.pending_error == null);
    // The boundary frame is popped but `stack_top` still covers its window,
    // so the result registers are live and rooted: copy out, then shrink.
    const produced = @min(@as(usize, fr.count), results.len);
    // One pass: copy each result out and park it. Parking never collects
    // (`park`), so the registers stay intact for the rest of the walk. The
    // parks land in the same order as `runProtected`'s copy-then-park, and
    // on OOM `*nresults` stays 0, so the copied prefix is undefined either
    // way (mahina.h). The window is taken once; through `vm` every result
    // store may alias the lane bases (doc 60 §5.6).
    const w = vm.frameWindow(base + fr.reg, produced);
    var status: mh_status = .ok;
    for (results[0..produced], 0..) |*r, k| {
        const v = w.get(k);
        // Whole-word stores: the C side reads `results` as 8-byte words.
        Value.storeWords(r, v);
        if (park(box, v) != .ok) {
            status = .err_oom;
            break;
        }
    }
    vm.stack_top = entry_top;
    if (status != .ok) return status;
    nres.* = produced;
    return .ok;
}

/// Doc 60 §6.1 stage 1: the pre-H1 `mh_call`, kept verbatim as the
/// differential tests' reference leg (`mh_call` → `callValue` for every
/// callee). Not exported and not called by the library.
pub fn hostcallReference(vm: ?*VmBox, callee: mh_value, args: ?[*]const mh_value, nargs: usize, results: ?[*]mh_value, max_results: usize, nresults: ?*usize) mh_status {
    const box = vm orelse return .err_api;
    const nres = nresults orelse return .err_api;
    nres.* = 0;
    if (checkFatal(box)) |s| return s;
    const cv = fromC(callee) orelse return badValue(box);
    const cargs = argsSlice(box, args, nargs) orelse return badValue(box);
    // Doc 59 §3.3: clear-then-re-park — the incoming values may live only in
    // the (just-cleared) park, so root them again before anything collects.
    parkClearIfIdle(box);
    if (park(box, cv) != .ok) return .err_oom;
    for (cargs) |*a| if (park(box, Value.loadWords(a)) != .ok) return .err_oom;
    return runProtected(box, cv, cargs, resultsSlice(results, max_results), nres);
}

/// Validate + reinterpret the C args buffer as `[]const Value`.
fn argsSlice(box: *VmBox, args: ?[*]const mh_value, nargs: usize) ?[]const Value {
    _ = box;
    if (nargs == 0) return &.{};
    const p = args orelse return null;
    // Validate through the two words only — copying each `mh_value` whole
    // drags its padding through odd-sized stack moves that stall the reload.
    for (p[0..nargs]) |*cv| {
        if (fromC(.{ .tag = cv.tag, .payload = cv.payload }) == null) return null;
    }
    const vp: [*]const Value = @ptrCast(p);
    return vp[0..nargs];
}

fn badValue(box: *VmBox) mh_status {
    setLastError(box, "invalid mh_value (bad tag or null heap pointer)");
    return .err_api;
}

// ---------------------------------------------------------------------------
// values
// ---------------------------------------------------------------------------

pub export fn mh_nil() mh_value {
    return toC(Value.nil());
}

pub export fn mh_bool(b: c_int) mh_value {
    return toC(Value.boolean(b != 0));
}

pub export fn mh_int(i: i64) mh_value {
    return toC(Value.int(i));
}

pub export fn mh_float(f: f64) mh_value {
    return toC(Value.float(f));
}

pub export fn mh_value_type(v: mh_value) mh_type {
    const val = fromC(v) orelse return .other;
    return typeOf(val);
}

/// Lua truthiness (nil/false are false, everything else true).
pub export fn mh_value_truthy(v: mh_value) c_int {
    const val = fromC(v) orelse return 0;
    return @intFromBool(val.isTruthy());
}

pub export fn mh_value_int(v: mh_value, out: ?*i64) mh_status {
    const o = out orelse return .err_api;
    const val = fromC(v) orelse return .err_api;
    if (val.tag != .int) return .err_api;
    o.* = val.asInt();
    return .ok;
}

/// Numeric read: accepts both int and float tags.
pub export fn mh_value_float(v: mh_value, out: ?*f64) mh_status {
    const o = out orelse return .err_api;
    const val = fromC(v) orelse return .err_api;
    o.* = switch (val.tag) {
        .int => @floatFromInt(val.asInt()),
        .float => val.asFloat(),
        else => return .err_api,
    };
    return .ok;
}

pub export fn mh_value_bool(v: mh_value, out: ?*c_int) mh_status {
    const o = out orelse return .err_api;
    const val = fromC(v) orelse return .err_api;
    if (val.tag != .boolean) return .err_api;
    o.* = @intFromBool(val.isTruthy());
    return .ok;
}

/// Borrowed string bytes — stable while the value stays rooted (non-moving
/// GC): hold the park (until the next idle entry) or a ref.
pub export fn mh_value_str(vm: ?*VmBox, v: mh_value, out: ?*mh_str) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    const val = fromC(v) orelse return badValue(box);
    const bytes = interp.strBytes(val) orelse {
        setLastError(box, "value is not a string");
        return .err_api;
    };
    o.* = asStr(bytes);
    return .ok;
}

/// Intern host bytes as a guest string (parked).
pub export fn mh_string_new(vm: ?*VmBox, bytes: mh_str, out: ?*mh_value) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const b = strSlice(bytes) orelse return badStr(box);
    parkClearIfIdle(box);
    const v = box.vm.heap.internValue(b) catch return oom(box);
    if (park(box, v) != .ok) return .err_oom;
    putC(o, v);
    return .ok;
}

// ---------------------------------------------------------------------------
// globals
// ---------------------------------------------------------------------------

pub export fn mh_global_get(vm: ?*VmBox, name: mh_str, out: ?*mh_value) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const n = strSlice(name) orelse return badStr(box);
    parkClearIfIdle(box);
    const key = box.vm.heap.internValue(n) catch return oom(box);
    const v = box.vm.globals.get(key);
    if (park(box, v) != .ok) return .err_oom;
    putC(o, v);
    return .ok;
}

pub export fn mh_global_set(vm: ?*VmBox, name: mh_str, val: mh_value) mh_status {
    const box = vm orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const n = strSlice(name) orelse return badStr(box);
    const v = fromC(val) orelse return badValue(box);
    parkClearIfIdle(box);
    if (park(box, v) != .ok) return .err_oom;
    const key = box.vm.heap.internValue(n) catch return oom(box);
    box.vm.globals.set(box.vm.gpa, key, v) catch return oom(box);
    return .ok;
}

// ---------------------------------------------------------------------------
// refs (generational, doc 59 §3.2)
// ---------------------------------------------------------------------------

inline fn refPack(idx: u32, gen: u32) u64 {
    return (@as(u64, gen) << 32) | idx;
}

pub export fn mh_ref_create(vm: ?*VmBox, v: mh_value, out: ?*u64) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    const val = fromC(v) orelse return badValue(box);
    const vmi = &box.vm;
    if (vmi.host_ref_free_list.pop()) |idx| {
        const slot = &vmi.host_refs.items[idx];
        slot.value = val;
        o.* = refPack(idx, slot.generation);
        return .ok;
    }
    const idx: u32 = @intCast(vmi.host_refs.items.len);
    vmi.host_refs.append(vmi.gpa, .{ .value = val, .generation = 0 }) catch return oom(box);
    o.* = refPack(idx, 0);
    return .ok;
}

fn refSlot(box: *VmBox, ref: u64) ?*Vm.HostRefSlot {
    const idx: usize = @as(u32, @truncate(ref));
    const gen: u32 = @truncate(ref >> 32);
    if (idx >= box.vm.host_refs.items.len) return null;
    const slot = &box.vm.host_refs.items[idx];
    if (slot.generation != gen) return null;
    return slot;
}

pub export fn mh_ref_get(vm: ?*VmBox, ref: u64, out: ?*mh_value) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    const slot = refSlot(box, ref) orelse return staleRef(box);
    putC(o, slot.value);
    return .ok;
}

pub export fn mh_ref_free(vm: ?*VmBox, ref: u64) mh_status {
    const box = vm orelse return .err_api;
    const slot = refSlot(box, ref) orelse return staleRef(box);
    slot.value = Value.nil(); // freed slots hold nil — no stale marks
    slot.generation +%= 1; // stale refs now miss deterministically
    const idx: u32 = @truncate(ref);
    box.vm.host_ref_free_list.append(box.vm.gpa, idx) catch return oom(box);
    return .ok;
}

fn staleRef(box: *VmBox) mh_status {
    setLastError(box, "stale or invalid mh_ref");
    return .err_api;
}

// ---------------------------------------------------------------------------
// host functions (doc 59 §3.5)
// ---------------------------------------------------------------------------

/// Per-registration C context the generic `HostBinding` points at.
const CHostCtx = struct {
    cfn: mh_host_fn,
    userdata: ?*anyopaque,
    user_destroy: ?mh_host_fn_destroy,
    box: *VmBox,
    gpa: std.mem.Allocator,
};

/// `HostBinding.destroy`: runs at GC time when the guest drops the last
/// reference to the Native (or at VM teardown). Calls the embedder's
/// destructor, then frees the context.
fn cHostDestroy(ctx: ?*anyopaque) void {
    const h: *CHostCtx = @ptrCast(@alignCast(ctx.?));
    if (h.user_destroy) |d| d(h.userdata);
    const gpa = h.gpa;
    gpa.destroy(h);
}

/// `HostBinding.call`: the generic→C adaptation. A non-OK status raises a
/// located guest error carrying the `mh_error_set` message (so `pcall`
/// observes the embedder's text, not a generic HostError — doc 59 §3.5).
fn cHostCall(ctx: ?*anyopaque, vm_opaque: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const h: *CHostCtx = @ptrCast(@alignCast(ctx.?));
    const vm: *Vm = @ptrCast(@alignCast(vm_opaque));
    std.debug.assert(vm == &h.box.vm);
    var nres: usize = 0;
    const st = h.cfn(
        h.box,
        h.userdata,
        if (args.len > 0) @ptrCast(args.ptr) else null,
        args.len,
        if (out.len > 0) @ptrCast(out.ptr) else null,
        out.len,
        &nres,
    );
    if (st != .ok) {
        const msg: []const u8 = if (h.box.host_error.items.len > 0) h.box.host_error.items else "host function error";
        const e = vm.raiseLocatedError(msg, 1);
        h.box.host_error.clearRetainingCapacity();
        return e;
    }
    // Validate what the C side wrote before it becomes guest state.
    const n = @min(nres, out.len);
    const raw: [*]const mh_value = @ptrCast(out.ptr);
    for (raw[0..n]) |cv| {
        if (fromC(cv) == null) return error.TypeError;
    }
    return n;
}

/// `Native.func` for host natives — never invoked (the invocation funnel
/// short-circuits on `host != null`); a defensive fault, not `unreachable`,
/// in case an unknown path ever calls it.
fn hostFnStub(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    _ = args;
    return error.TypeError;
}

/// Stage the message for the next failing return from a host callback.
pub export fn mh_error_set(vm: ?*VmBox, msg: mh_str) void {
    const box = vm orelse return;
    const m = strSlice(msg) orelse return;
    box.host_error.clearRetainingCapacity();
    box.host_error.appendSlice(box.backing, m) catch {};
}

pub export fn mh_register_fn(vm: ?*VmBox, name: mh_str, cfn: ?mh_host_fn, userdata: ?*anyopaque, destroy: ?mh_host_fn_destroy) mh_status {
    const box = vm orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const f = cfn orelse return .err_api;
    const n = strSlice(name) orelse return badStr(box);
    if (n.len == 0) {
        setLastError(box, "empty host function name");
        return .err_api;
    }
    // Doc 59 §3.5 / codex #8: a name colliding with a builtin would silently
    // restore AS the builtin from a future keyframe — reject outright. Bare
    // names check the installed-global namespace (which includes module
    // tables like `string`); dotted names check the registry's qualified
    // names (`string.format`).
    for (interp.base_natives) |bn| {
        if (std.mem.eql(u8, bn.name, n)) return nameCollision(box, n);
    }
    for (interp.builtin_global_names) |g| {
        if (std.mem.eql(u8, g, n)) return nameCollision(box, n);
    }
    if (std.mem.indexOfScalar(u8, n, '.')) |dot| {
        const field = n[dot + 1 ..];
        if (dot == 0 or field.len == 0 or std.mem.indexOfScalar(u8, field, '.') != null) {
            setLastError(box, "host function name must be 'name' or 'module.field'");
            return .err_api;
        }
    }
    parkClearIfIdle(box);

    const vmi = &box.vm;
    const gpa = vmi.gpa;

    const hctx = gpa.create(CHostCtx) catch return oom(box);
    hctx.* = .{ .cfn = f, .userdata = userdata, .user_destroy = destroy, .box = box, .gpa = gpa };
    const binding = gpa.create(function.HostBinding) catch {
        gpa.destroy(hctx);
        return oom(box);
    };
    const name_copy = gpa.dupe(u8, n) catch {
        gpa.destroy(binding);
        gpa.destroy(hctx);
        return oom(box);
    };
    binding.* = .{ .call = &cHostCall, .ctx = hctx, .destroy = &cHostDestroy, .name = name_copy };

    // From here the Native owns the binding: any later failure leaves an
    // unreferenced heap Native whose sweep runs the destroy hook — no leak,
    // no double free.
    const native = vmi.heap.newNative(&hostFnStub, name_copy) catch {
        gpa.free(name_copy);
        gpa.destroy(binding);
        gpa.destroy(hctx);
        return oom(box);
    };
    native.host = binding;

    if (std.mem.indexOfScalar(u8, n, '.')) |dot| {
        const mod = n[0..dot];
        const field = n[dot + 1 ..];
        const tbl = vmi.getOrCreateModuleTable(mod) catch return oom(box);
        const fkey = vmi.heap.internValue(field) catch return oom(box);
        tbl.set(gpa, fkey, Value.heap(&native.header)) catch return oom(box);
    } else {
        const key = vmi.heap.internValue(n) catch return oom(box);
        vmi.globals.set(gpa, key, Value.heap(&native.header)) catch return oom(box);
    }
    return .ok;
}

fn nameCollision(box: *VmBox, name: []const u8) mh_status {
    setLastErrorFmt(box, "'{s}' collides with a builtin name", .{name});
    return .err_api;
}

// ---------------------------------------------------------------------------
// tables
// ---------------------------------------------------------------------------

/// Resolve a C value to a `*Table`, deflating a grid first (doc 14's gate:
/// any bare host access sees real row tables, never `row_view`s).
fn tableOf(box: *VmBox, v: Value) ?*Table {
    if (!v.isHeap() or v.heapType() != .table) return null;
    const t = Table.fromHeader(v.asHeap());
    if (t.array.isGrid()) box.vm.heap.deflateGrid(t) catch return null;
    return t;
}

pub export fn mh_table_new(vm: ?*VmBox, out: ?*mh_value) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    parkClearIfIdle(box);
    const t = box.vm.heap.newTable() catch return oom(box);
    const v = Value.heap(&t.header);
    if (park(box, v) != .ok) return .err_oom;
    putC(o, v);
    return .ok;
}

pub export fn mh_table_get(vm: ?*VmBox, tbl: mh_value, key: mh_value, out: ?*mh_value) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const tv = fromC(tbl) orelse return badValue(box);
    const kv = fromC(key) orelse return badValue(box);
    parkClearIfIdle(box);
    if (park(box, tv) != .ok) return .err_oom;
    if (park(box, kv) != .ok) return .err_oom;
    // Metamethod-aware (guest `t[k]` semantics) — may run guest code, so a
    // protected entry.
    const ed = box.vm.depth;
    const et = box.vm.stack_top;
    const v = box.vm.indexGet(tv, kv) catch |e| return guestFault(box, ed, et, e);
    if (park(box, v) != .ok) return .err_oom;
    putC(o, v);
    return .ok;
}

pub export fn mh_table_set(vm: ?*VmBox, tbl: mh_value, key: mh_value, val: mh_value) mh_status {
    const box = vm orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const tv = fromC(tbl) orelse return badValue(box);
    const kv = fromC(key) orelse return badValue(box);
    const vv = fromC(val) orelse return badValue(box);
    parkClearIfIdle(box);
    if (park(box, tv) != .ok) return .err_oom;
    if (park(box, kv) != .ok) return .err_oom;
    if (park(box, vv) != .ok) return .err_oom;
    const ed = box.vm.depth;
    const et = box.vm.stack_top;
    box.vm.indexSet(tv, kv, vv) catch |e| return guestFault(box, ed, et, e);
    return .ok;
}

/// Raw length (the `#` border for tables). No `__len` dispatch in v1.
pub export fn mh_table_len(vm: ?*VmBox, tbl: mh_value, out: ?*i64) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    const tv = fromC(tbl) orelse return badValue(box);
    const t = tableOf(box, tv) orelse {
        setLastError(box, "value is not a table");
        return .err_api;
    };
    o.* = @intCast(t.length());
    return .ok;
}

pub export fn mh_table_metatable_get(vm: ?*VmBox, tbl: mh_value, out: ?*mh_value) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    const tv = fromC(tbl) orelse return badValue(box);
    const t = tableOf(box, tv) orelse {
        setLastError(box, "value is not a table");
        return .err_api;
    };
    const v = if (t.metatable) |mt| Value.heap(&mt.header) else Value.nil();
    if (park(box, v) != .ok) return .err_oom;
    putC(o, v);
    return .ok;
}

/// Set (table metatable) or clear (nil) a metatable. No `__metatable`
/// protection in v1 (the host is trusted — it owns the VM).
pub export fn mh_table_metatable_set(vm: ?*VmBox, tbl: mh_value, mt: mh_value) mh_status {
    const box = vm orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const tv = fromC(tbl) orelse return badValue(box);
    const mv = fromC(mt) orelse return badValue(box);
    const t = tableOf(box, tv) orelse {
        setLastError(box, "value is not a table");
        return .err_api;
    };
    if (mv.isNil()) {
        t.metatable = null;
        return .ok;
    }
    const m = tableOf(box, mv) orelse {
        setLastError(box, "metatable must be a table or nil");
        return .err_api;
    };
    t.metatable = m;
    return .ok;
}

// ---------------------------------------------------------------------------
// table iteration (doc 59 §3.4 — O(1) per step, never `next`'s per-step sort)
// ---------------------------------------------------------------------------

pub export fn mh_table_iter_new(vm: ?*VmBox, tbl: mh_value, out: ?**IterBox) mh_status {
    const box = vm orelse return .err_api;
    const o = out orelse return .err_api;
    if (checkFatal(box)) |s| return s;
    const tv = fromC(tbl) orelse return badValue(box);
    parkClearIfIdle(box);
    if (park(box, tv) != .ok) return .err_oom;
    const t = tableOf(box, tv) orelse {
        setLastError(box, "value is not a table");
        return .err_api;
    };
    const vmi = &box.vm;
    const gpa = vmi.gpa;

    // Materialize the deterministic key order once: array part ascending
    // (identity keys `0..asize-1`, skipping nil holes — doc 18 slot0), then
    // hash keys in canonical `key_order`. Keys land in a guest table rooted
    // by a host ref, so ONE ref keeps the whole snapshot alive.
    const kt = vmi.heap.newTable() catch return oom(box);
    var kt_ref: u64 = 0;
    if (mh_ref_create(box, toC(Value.heap(&kt.header)), &kt_ref) != .ok) return .err_oom;
    var count: usize = 0;
    {
        var i: usize = 0;
        const n = t.array.asize;
        while (i < n) : (i += 1) {
            const av = t.array.get(i);
            if (av.isNil()) continue;
            kt.set(gpa, Value.int(@intCast(count + 1)), Value.int(@intCast(i))) catch return iterOom(box, kt_ref);
            count += 1;
        }
    }
    {
        const keys = gpa.alloc(Value, t.hash.count()) catch return iterOom(box, kt_ref);
        defer gpa.free(keys);
        var it = t.hash.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
        std.mem.sort(Value, keys, {}, key_order.less);
        for (keys) |k| {
            kt.set(gpa, Value.int(@intCast(count + 1)), k) catch return iterOom(box, kt_ref);
            count += 1;
        }
    }
    var tbl_ref: u64 = 0;
    if (mh_ref_create(box, toC(tv), &tbl_ref) != .ok) return iterOom(box, kt_ref);

    const ib = box.backing.create(IterBox) catch {
        _ = mh_ref_free(box, kt_ref);
        _ = mh_ref_free(box, tbl_ref);
        return oom(box);
    };
    ib.* = .{ .owner = box, .tbl_ref = tbl_ref, .keys_ref = kt_ref, .len = count };
    o.* = ib;
    return .ok;
}

fn iterOom(box: *VmBox, kt_ref: u64) mh_status {
    _ = mh_ref_free(box, kt_ref);
    return oom(box);
}

/// Advance: writes the next live `(key, value)` pair and `*done = 0`, or
/// `*done = 1` at the end. Values are read live (raw get); keys deleted since
/// `iter_new` are skipped. Both outputs are parked.
pub export fn mh_table_iter_next(vm: ?*VmBox, iter: ?*IterBox, key: ?*mh_value, val: ?*mh_value, done: ?*c_int) mh_status {
    const box = vm orelse return .err_api;
    const ib = iter orelse return .err_api;
    const ko = key orelse return .err_api;
    const vo = val orelse return .err_api;
    const do = done orelse return .err_api;
    if (ib.owner != box) {
        setLastError(box, "iterator belongs to a different VM");
        return .err_api;
    }
    const tbl_slot = refSlot(box, ib.tbl_ref) orelse return staleRef(box);
    const keys_slot = refSlot(box, ib.keys_ref) orelse return staleRef(box);
    const t = tableOf(box, tbl_slot.value) orelse return staleRef(box);
    const kt = tableOf(box, keys_slot.value) orelse return staleRef(box);

    while (ib.idx < ib.len) {
        ib.idx += 1;
        const k = kt.get(Value.int(@intCast(ib.idx)));
        const v = t.get(k);
        if (v.isNil()) continue; // deleted since iter_new
        if (park(box, k) != .ok) return .err_oom;
        if (park(box, v) != .ok) return .err_oom;
        putC(ko, k);
        putC(vo, v);
        do.* = 0;
        return .ok;
    }
    putC(ko, Value.nil());
    putC(vo, Value.nil());
    do.* = 1;
    return .ok;
}

pub export fn mh_table_iter_free(vm: ?*VmBox, iter: ?*IterBox) mh_status {
    const box = vm orelse return .err_api;
    const ib = iter orelse return .ok;
    if (ib.owner != box) {
        setLastError(box, "iterator belongs to a different VM");
        return .err_api;
    }
    _ = mh_ref_free(box, ib.tbl_ref);
    _ = mh_ref_free(box, ib.keys_ref);
    box.backing.destroy(ib);
    return .ok;
}

test {
    _ = @import("capi_test.zig");
    _ = @import("capi_hostcall_test.zig");
    if (hostcall_asm) _ = @import("asm/offsets_x64.zig");
}
