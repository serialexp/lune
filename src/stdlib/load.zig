//! lune stdlib — runtime compilation: `load`, `loadfile`, `dofile`.
//!
//! `load(chunk [, chunkname])` compiles a source **string** into a callable
//! closure at runtime, reusing the very same `parser.parse` →
//! `compiler.compileWithOptions` → `heap.newClosure` path the CLI uses for the
//! main chunk (`main.zig`). It is the single biggest Lua-usability unlock left,
//! and lune already owns the whole compiler.
//!
//! `loadfile(path)` / `dofile(path)` (L-3) read the source from a file first,
//! through the `file_read` record/replay effect (`interp.obtainFileRead`): the file
//! content is a nondeterministic input, logged on record and fed back on replay
//! (the path is ordinary program data — only the content is the effect, so replay
//! never touches disk). Both then reuse the exact `load` compile path
//! (`compileToClosure`). `loadfile` returns `(nil, msg)` on a read/compile error
//! (never raised); `dofile` instead **runs** the loaded chunk and **raises** on
//! any read/compile error — Lua-shaped.
//!
//! Determinism: compilation is a pure function of the source bytes (no clock, no
//! entropy, no environment), so `load` is **not** an effect — like every native
//! it is a trace barrier, but it logs nothing and replays identically. (`loadfile`/
//! `dofile` ARE effectful, but only via the `file_read` boundary; the compile that
//! follows is pure.) The proto tree it produces is owned by the VM
//! (`Vm.loaded_chunks`) because a loaded closure can outlive the call that created
//! it; the source is duplicated and kept alongside the `Chunk` so `Proto.source`
//! (error line numbers) stays valid and the keyframe can recompile it on restore.
//!
//! Contract (Lua-shaped subset): on success `load`/`loadfile` return the closure;
//! on a **syntax error** they return `nil, message` (never raised). A non-string
//! `chunk`/`path` argument is a hard `bad argument` error (raised), matching Lua.
//! Deferred: the reader-function form of `chunk`, the `mode` argument (`"t"`/`"b"`
//! — lune has no binary bytecode and excludes `string.dump`), the `env` argument
//! (lune has no `_ENV` upvalue), and the no-path `loadfile()`/`dofile()` stdin
//! form (the deterministic VM has no stdin).

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const parser = @import("../parser.zig");
const compiler = @import("../compiler.zig");
const diag = @import("../diag.zig");

const Value = value.Value;
const Vm = interp.Vm;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// The first `error`-severity diagnostic in `diags`, or null if none.
fn firstError(diags: *const diag.Diagnostics) ?diag.Diagnostic {
    for (diags.list.items) |d| {
        if (d.severity == .@"error") return d;
    }
    return null;
}

/// `load(chunk [, chunkname])`. Reads the source **string** and optional chunk
/// name from `args`, then hands off to `compileToClosure`. A non-string `chunk`
/// raises `bad argument` (Lua). MUST read everything from `args` before writing
/// `out` (the multi-native aliasing contract) — it reads both args here, and
/// `compileToClosure` dups the source/name before its first `out` write.
fn loadCore(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    const chunk_arg = if (args.len >= 1) args[0] else Value.nil();
    const src_bytes = interp.strBytes(chunk_arg) orelse
        return vm.badArg(1, "string", if (args.len >= 1) chunk_arg else null);

    // Chunk name for messages. Default `"(load)"`; an explicit string overrides.
    var chunk_name: []const u8 = "(load)";
    if (args.len >= 2 and !args[1].isNil()) {
        chunk_name = interp.strBytes(args[1]) orelse
            return vm.badArg(2, "string", args[1]);
    }
    return compileToClosure(vm, src_bytes, chunk_name, out);
}

/// Compile `src_bytes` into a VM-owned chunk named `chunk_name` and return the
/// top-level closure as `out[0]` (count 1). On a parse/compile error, write
/// `out[0] = nil`, `out[1] = "<chunkname>:<line>: <message>"` and return 2
/// (truncated to `out.len`). Shared by `load`, `loadfile`, and `dofile`.
///
/// `src_bytes`/`chunk_name` must NOT alias `out` (they are dup'd before the first
/// `out` write, but callers pass either heap-string bytes or freshly read file
/// bytes, neither of which lives in `out`).
///
/// `pub` so the `package`/`require` module system (`stdlib/package.zig`) compiles a
/// module's source through the exact same VM-owned-chunk path as `load`/`loadfile`.
pub fn compileToClosure(vm: *Vm, src_bytes: []const u8, chunk_name: []const u8, out: []Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    // Own the source for the chunk's lifetime (NUL-terminated, as parser/compiler
    // require). `owned` has exactly one owner at every point: `loadError` frees it
    // on a parse/compile error, the VM's `loaded_chunks` owns it on success, and
    // the append-failure path below frees it explicitly. No `errdefer` (that would
    // double-free against `loadError`, which is not an error return).
    const owned: [:0]u8 = try vm.gpa.dupeSentinel(u8, src_bytes, 0);

    var diags = diag.Diagnostics.init(vm.gpa);
    defer diags.deinit();

    // --- parse ---
    var tree = parser.parse(vm.gpa, owned, &diags) catch {
        return loadError(vm, owned, chunk_name, &diags, out);
    };
    defer tree.deinit();
    if (diags.hasErrors()) return loadError(vm, owned, chunk_name, &diags, out);

    // --- compile --- (pass builtin globals so the unknown-global lint doesn't
    // flag `print`/`clock`; offset proto ids so every loaded proto is globally
    // unique for snapshot serialization). Warnings are discarded for loaded code.
    var chunk = compiler.compileWithOptions(vm.gpa, &vm.heap, owned, tree.root, &diags, .{
        .known_globals = &interp.builtin_global_names,
        .id_base = vm.next_proto_id,
        // Lua loaded chunks are vararg: `load("return ...")(1, 2)` yields 1, 2.
        // (Loaded chunks trace like static code as of doc 19: their proto
        // constants are rooted VM-lifetime via `loaded_chunks` in both root
        // walks, so the old H-2 "never JIT loaded code" gate is gone.)
        .vararg_root = true,
    }) catch {
        return loadError(vm, owned, chunk_name, &diags, out);
    };
    if (diags.hasErrors()) {
        chunk.deinit();
        return loadError(vm, owned, chunk_name, &diags, out);
    }

    // Name the top-level proto after the chunk so a runtime fault in loaded code
    // reports e.g. `(load):2:`, not the static chunk's `main:2:`. Dup into the
    // chunk's own arena (VM-owned for the proto's lifetime); `chunk_name` may
    // borrow a GC-managed heap string, so we must not keep that borrow. Only the
    // top-level proto is renamed — nested protos keep their function names. An OOM
    // here propagates (chunk + owned are not VM-owned yet) rather than silently
    // mislabelling faults — OOM is a non-catchable, fatal condition.
    chunk.proto.name = chunk.arena.allocator().dupe(u8, chunk_name) catch |e| {
        chunk.deinit();
        vm.gpa.free(owned);
        return e;
    };

    // Take ownership BEFORE creating the closure: the VM now frees `chunk` +
    // `owned` at teardown. Append-first is deliberate — `newClosure` GC-links the
    // closure to `chunk.proto`, so on a `newClosure` OOM we must NOT deinit the
    // chunk (a later GC sweep would dereference the freed proto). The chunk simply
    // stays VM-owned until teardown; the proto-id range is consumed but never
    // reused, so no id ever collides. (OOM is non-catchable → the VM tears down
    // anyway, so this retention is benign.) If the append itself fails, free both
    // here — neither is VM-owned yet.
    vm.loaded_chunks.append(vm.gpa, .{ .chunk = chunk, .source = owned }) catch |e| {
        chunk.deinit();
        vm.gpa.free(owned);
        return e;
    };
    vm.next_proto_id += chunk.proto_count;

    // The top-level chunk is a vararg function with no upvalues (lune has no
    // `_ENV` cell), exactly like the main chunk.
    const closure = try vm.heap.newClosure(chunk.proto, 0);
    out[0] = Value.heap(&closure.header);
    return 1;
}

/// Build `(nil, "<chunkname>:<line>: <message>")` into `out` and free `owned`
/// (the chunk never took ownership). Returns the result count (≤ `out.len`).
fn loadError(vm: *Vm, owned: [:0]u8, chunk_name: []const u8, diags: *const diag.Diagnostics, out: []Value) anyerror!usize {
    vm.gpa.free(owned);
    out[0] = Value.nil();
    if (out.len < 2) return 1;
    // Allocate the message so an arbitrarily long `chunk_name` is reported in full
    // (no fixed-buffer truncation/degradation). `internValue` copies it into the
    // heap, so the scratch is freed immediately after. OOM propagates (non-catchable,
    // fatal) rather than silently mangling the message.
    const msg = if (firstError(diags)) |d|
        try std.fmt.allocPrint(vm.gpa, "{s}:{d}: {s}", .{ chunk_name, d.line, d.message })
    else
        try std.fmt.allocPrint(vm.gpa, "{s}: compile error", .{chunk_name});
    defer vm.gpa.free(msg);
    out[1] = try vm.heap.internValue(msg);
    return 2;
}

fn nLoadN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return loadCore(vmOf(ctx), args, out);
}

fn nLoad1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [2]Value = undefined;
    _ = try loadCore(vmOf(ctx), args, b[0..2]);
    return b[0];
}

// ---------------------------------------------------------------------------
// loadfile / dofile (L-3) — read a file via the `file_read` effect, then compile
// ---------------------------------------------------------------------------

/// Read the file at `args[0]` (a string path) through the `file_read` effect and
/// compile it. Returns the closure as `out[0]`, or `(nil, msg)` on a read/compile
/// error (never raised). The `mode`/`env` args are accepted but ignored (deferred).
/// MUST read the path before writing `out`: it does — `obtainFileRead` consumes
/// the path, and the returned file bytes / the `cannot open` message are dup'd or
/// interned (copying) before the first `out` write.
fn loadfileCore(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    const path_arg = if (args.len >= 1) args[0] else Value.nil();
    const path = interp.strBytes(path_arg) orelse
        return vm.badArg(1, "string", if (args.len >= 1) path_arg else null);

    // The file content rides the record/replay boundary (nil ⇒ couldn't open).
    const content = try interp.obtainFileRead(vm, path);
    if (content.isNil()) return cannotOpen(vm, path, out);
    // `content` is a heap string; its bytes don't alias `out`.
    return compileToClosure(vm, interp.strBytes(content).?, path, out);
}

/// Build `(nil, "cannot open <path>")` into `out`. The message is a deterministic
/// function of the path only — NOT the host's errno text — so it replays
/// byte-identically across machines. Returns the result count (≤ `out.len`).
fn cannotOpen(vm: *Vm, path: []const u8, out: []Value) anyerror!usize {
    out[0] = Value.nil();
    if (out.len < 2) return 1;
    // Allocate so an arbitrarily long path is reported in full; `internValue` copies
    // it, so the scratch is freed right after. OOM propagates (non-catchable, fatal).
    const msg = try std.fmt.allocPrint(vm.gpa, "cannot open {s}", .{path});
    defer vm.gpa.free(msg);
    out[1] = try vm.heap.internValue(msg);
    return 2;
}

fn nLoadfileN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return loadfileCore(vmOf(ctx), args, out);
}

fn nLoadfile1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [2]Value = undefined;
    _ = try loadfileCore(vmOf(ctx), args, b[0..2]);
    return b[0];
}

/// `dofile(path)` — `loadfile` the path, then **run** the chunk with no arguments
/// and return its results. Unlike `loadfile`, a read or compile error is **raised**
/// (Lua semantics), carrying the same message `loadfile` would have returned as the
/// second value. Reads the path before writing `out`; the loaded closure is run via
/// `callValue`, whose results land directly in `out`.
fn dofileCore(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    const path_arg = if (args.len >= 1) args[0] else Value.nil();
    const path = interp.strBytes(path_arg) orelse
        return vm.badArg(1, "string", if (args.len >= 1) path_arg else null);

    // Compile into a private 2-slot buffer so a `(nil, msg)` outcome can be turned
    // into a raise rather than a return (dofile never yields `(nil, msg)`).
    var loaded: [2]Value = undefined;
    const content = try interp.obtainFileRead(vm, path);
    if (content.isNil()) {
        _ = try cannotOpen(vm, path, loaded[0..2]);
        return raiseLoadError(vm, loaded[1]);
    }
    const n = try compileToClosure(vm, interp.strBytes(content).?, path, loaded[0..2]);
    if (loaded[0].isNil()) {
        // Compile error: `loaded[1]` is the message (present iff n == 2).
        return raiseLoadError(vm, if (n >= 2) loaded[1] else Value.nil());
    }

    // Run the loaded chunk with no arguments; its results fill `out` directly.
    return vm.callValue(loaded[0], &.{}, out);
}

/// Raise `msg` (a heap string or nil) as the in-flight Lua error for `dofile`. The
/// message is stored verbatim (no extra location prefix — it already reads e.g.
/// `cannot open x` or `x:1: <syntax>`), mirroring Lua's `dofile` re-raise.
fn raiseLoadError(vm: *Vm, msg: Value) anyerror!usize {
    const bytes = interp.strBytes(msg) orelse "cannot load file";
    return vm.raiseLocatedError(bytes, 0);
}

fn nDofileN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return dofileCore(vmOf(ctx), args, out);
}

fn nDofile1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [1]Value = undefined;
    const n = try dofileCore(vmOf(ctx), args, b[0..1]);
    return if (n >= 1) b[0] else Value.nil();
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const natives = [_]function.BaseNative{
    .{ .name = "load", .func = &nLoad1, .multi = &nLoadN },
    .{ .name = "loadfile", .func = &nLoadfile1, .multi = &nLoadfileN },
    .{ .name = "dofile", .func = &nDofile1, .multi = &nDofileN },
};
