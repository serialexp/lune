//! mahina stdlib — the module system: `require` + the `package` table.
//!
//! `require(name)` is the single Lua-usability unlock that lets one script pull in
//! another. mahina builds it out of pieces that already exist, inventing **no new
//! host seam and no new effect kind**:
//!
//!   * `package.path` templating — pure string substitution (`?` → the dotted
//!     module name with `.` mapped to `/`).
//!   * file content via `interp.obtainFileRead` — the existing `fs_source` host
//!     seam + the `.file_read` record/replay effect. The *content* is the only
//!     nondeterministic input (logged on record, fed back on replay); the path is
//!     ordinary program data. This is what makes `require` **base-host**: a game or
//!     embedding host that injects its own `fs_source` (a memory FS, an archive)
//!     gets `require` for free, and determinism is already covered.
//!   * `load.compileToClosure` — the same VM-owned-chunk compile path `load`/
//!     `loadfile` use, so a module compiles identically to any other runtime chunk.
//!   * `package.loaded` cache + `package.searchers` iteration via `Vm.callValue`
//!     (the F2 reentrant primitive) — so a module loads at most once and loaders
//!     may themselves `require` (reentrancy rides `native_reentry_depth`).
//!
//! Searchers are real functions in the `package.searchers` array (Bart: "if we
//! expose them, actually support the searchers"), so a host can prepend/replace
//! one. The two built-ins — `searchPreload` (consults `package.preload`) and
//! `searchPath` (walks `package.path`) — are registered as **`manual`** natives:
//! they live in `base_natives` only so the keyframe restorer can rebind them by
//! name, and `installPackageRuntime` creates the live heap `Native`s and places
//! them in the array (they have no global/module slot of their own).
//!
//! Out of scope (determinism-hostile or unneeded): C/native loading
//! (`package.loadlib`, the C-path searcher); `package.cpath` is kept as an inert
//! empty field only so module code that reads it doesn't fault.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const table_mod = @import("../table.zig");
const load = @import("load.zig");

const Value = value.Value;
const Vm = interp.Vm;
const Table = table_mod.Table;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// A heap value is callable iff it is a closure or a native.
fn isCallable(v: Value) bool {
    return v.isHeap() and (v.heapType() == .function or v.heapType() == .native);
}

/// The `package` module table (always present after `installBaseLib`).
fn packageTable(vm: *Vm) interp.Error!*Table {
    return vm.getOrCreateModuleTable("package");
}

/// `package[field]` as a `Value` (nil if absent). `field` is interned (cheap; the
/// name is almost always already in the string heap).
fn packageField(vm: *Vm, field: []const u8) interp.Error!Value {
    const tbl = try packageTable(vm);
    return tbl.get(try vm.heap.internValue(field));
}

/// Re-derive `package.<field>` as a live `*Table`, validating it is a table.
/// Always reached fresh from `vm.globals` (which is permanently GC-rooted), so the
/// returned pointer is safe to use *immediately*. Callers that re-enter the VM via
/// `callValue` (i.e. `require`) MUST re-call this afterwards rather than caching the
/// pointer: a loader could reassign `package`, `package.loaded`, or
/// `package.searchers`, orphaning the old table so a GC at a nested safepoint sweeps
/// it. `field_name` names the field in the "must be a table" error.
fn requirePackageSubTable(vm: *Vm, field: []const u8, field_name: []const u8) anyerror!*Table {
    const pkg_v = vm.globals.get(try vm.heap.internValue("package"));
    if (!(pkg_v.isHeap() and pkg_v.heapType() == .table))
        return vm.raiseLocatedError("'package' must be a table", 0);
    const pkg = Table.fromHeader(pkg_v.asHeap());
    const sub = pkg.get(try vm.heap.internValue(field));
    if (!(sub.isHeap() and sub.heapType() == .table)) {
        const msg = try std.fmt.allocPrint(vm.gpa, "'{s}' must be a table", .{field_name});
        defer vm.gpa.free(msg);
        return vm.raiseLocatedError(msg, 0);
    }
    return Table.fromHeader(sub.asHeap());
}

// ---------------------------------------------------------------------------
// package.searchpath(name, path [, sep [, rep]])
// ---------------------------------------------------------------------------

/// Substitute the dotted module `name` into a `;`-separated `path` template list,
/// probing each candidate via the `file_read` effect. Returns the first readable
/// path as `out[0]` (count 1); on no match returns `(nil, "\n\tno file '<cand>'"…)`
/// (count 2). `sep` (default `"."`) is the substring of `name` replaced by `rep`
/// (default `"/"`, the mahina path separator) before the `?` substitution.
///
/// Reads every argument before writing `out`, then accumulates into a `gpa` buffer
/// that is interned (copied) before the first `out` write — so no `out`/arg alias.
fn searchpathCore(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    const name = interp.strBytes(if (args.len >= 1) args[0] else Value.nil()) orelse
        return vm.badArg(1, "string", if (args.len >= 1) args[0] else null);
    const path = interp.strBytes(if (args.len >= 2) args[1] else Value.nil()) orelse
        return vm.badArg(2, "string", if (args.len >= 2) args[1] else null);
    const sep = if (args.len >= 3 and !args[2].isNil())
        interp.strBytes(args[2]) orelse return vm.badArg(3, "string", args[2])
    else
        ".";
    const rep = if (args.len >= 4 and !args[3].isNil())
        interp.strBytes(args[3]) orelse return vm.badArg(4, "string", args[3])
    else
        "/";

    // `name` with `sep` mapped to `rep` (e.g. `a.b` → `a/b`). An empty `sep` would
    // loop forever in `std.mem.replace`; Lua treats it as "no mapping", so reuse
    // `name` verbatim. Owned scratch, freed before return.
    const mapped = if (sep.len == 0)
        try vm.gpa.dupe(u8, name)
    else
        try replaceAlloc(vm.gpa, name, sep, rep);
    defer vm.gpa.free(mapped);

    var notfound: std.ArrayList(u8) = .empty;
    defer notfound.deinit(vm.gpa);
    var cand: std.ArrayList(u8) = .empty;
    defer cand.deinit(vm.gpa);

    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |templ| {
        if (templ.len == 0) continue; // a trailing/empty `;;` segment is skipped
        cand.clearRetainingCapacity();
        try substituteQuestion(&cand, vm.gpa, templ, mapped);
        const content = try interp.obtainFileRead(vm, cand.items);
        if (!content.isNil()) {
            out[0] = try vm.heap.internValue(cand.items);
            return 1;
        }
        try notfound.appendSlice(vm.gpa, "\n\tno file '");
        try notfound.appendSlice(vm.gpa, cand.items);
        try notfound.appendSlice(vm.gpa, "'");
    }

    out[0] = Value.nil();
    if (out.len < 2) return 1;
    out[1] = try vm.heap.internValue(notfound.items);
    return 2;
}

/// Append `template` to `buf`, replacing every `?` with `repl`.
fn substituteQuestion(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, template: []const u8, repl: []const u8) !void {
    for (template) |c| {
        if (c == '?') try buf.appendSlice(gpa, repl) else try buf.append(gpa, c);
    }
}

/// `std.mem.replace` into a freshly allocated, exactly-sized buffer.
fn replaceAlloc(gpa: std.mem.Allocator, input: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    const count = std.mem.count(u8, input, needle);
    const out_len = input.len - count * needle.len + count * repl.len;
    const buf = try gpa.alloc(u8, out_len);
    errdefer gpa.free(buf);
    _ = std.mem.replace(u8, input, needle, repl, buf);
    return buf;
}

fn searchpath1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [2]Value = .{ Value.nil(), Value.nil() };
    _ = try searchpathCore(vmOf(ctx), args, b[0..2]);
    return b[0];
}

fn searchpathN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return searchpathCore(vmOf(ctx), args, out);
}

// ---------------------------------------------------------------------------
// Built-in searchers (manual natives placed in package.searchers)
// ---------------------------------------------------------------------------

/// `searchers[1]` — the preload searcher. If `package.preload[name]` is a callable,
/// returns `(loader, ":preload:")` (count 2); otherwise returns the not-found
/// string `"\n\tno field package.preload['<name>']"` (count 1). The `name` is read
/// before `out` is written; the not-found string is interned (copied) first.
fn searchPreloadCore(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    // Searchers are only ever called by `require`, which has already type-checked
    // `name`; tolerate a missing/non-string arg by reporting "not found".
    const name = interp.strBytes(if (args.len >= 1) args[0] else Value.nil()) orelse {
        out[0] = try vm.heap.internValue("\n\tno field package.preload");
        return 1;
    };
    const preload = try packageField(vm, "preload");
    if (preload.isHeap() and preload.heapType() == .table) {
        const pt = Table.fromHeader(preload.asHeap());
        const loader = pt.get(args[0]);
        if (isCallable(loader)) {
            out[0] = loader;
            if (out.len >= 2) out[1] = try vm.heap.internValue(":preload:");
            return if (out.len >= 2) 2 else 1;
        }
    }
    const msg = try std.fmt.allocPrint(vm.gpa, "\n\tno field package.preload['{s}']", .{name});
    defer vm.gpa.free(msg);
    out[0] = try vm.heap.internValue(msg);
    return 1;
}

/// `searchers[2]` — the path searcher. Walks `package.path` (dotted `name` mapped
/// `.`→`/`), reading each candidate's content directly via the `file_read` effect
/// (no separate `searchpath` probe — avoids a double read). The first readable
/// candidate is compiled to a closure and returned as `(closure, path)` (count 2);
/// a syntax error in a *found* module is **raised** (Lua semantics). On no match,
/// returns the accumulated `"\n\tno file '<cand>'"…` string (count 1).
fn searchPathCore(vm: *Vm, args: []const Value, out: []Value) anyerror!usize {
    std.debug.assert(out.len >= 1);
    const name = interp.strBytes(if (args.len >= 1) args[0] else Value.nil()) orelse {
        out[0] = try vm.heap.internValue("\n\tno file (bad module name)");
        return 1;
    };
    const path = interp.strBytes(try packageField(vm, "path")) orelse {
        // `package.path` missing/non-string → nothing to search.
        out[0] = try vm.heap.internValue("\n\tno file (package.path is not a string)");
        return 1;
    };

    const mapped = try replaceAlloc(vm.gpa, name, ".", "/");
    defer vm.gpa.free(mapped);

    var notfound: std.ArrayList(u8) = .empty;
    defer notfound.deinit(vm.gpa);
    var cand: std.ArrayList(u8) = .empty;
    defer cand.deinit(vm.gpa);

    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |templ| {
        if (templ.len == 0) continue;
        cand.clearRetainingCapacity();
        try substituteQuestion(&cand, vm.gpa, templ, mapped);
        const content = try interp.obtainFileRead(vm, cand.items);
        if (content.isNil()) {
            try notfound.appendSlice(vm.gpa, "\n\tno file '");
            try notfound.appendSlice(vm.gpa, cand.items);
            try notfound.appendSlice(vm.gpa, "'");
            continue;
        }
        // Found. Compile its content with the candidate path as the chunk name.
        // `compileToClosure` dups both before writing `out`, so passing `cand`
        // (about to be freed) is safe.
        const n = try load.compileToClosure(vm, interp.strBytes(content).?, cand.items, out);
        if (out[0].isNil()) {
            // Syntax error in a found module → raise, carrying the compiler message.
            const detail = if (n >= 2) interp.strBytes(out[1]) orelse "syntax error" else "syntax error";
            const emsg = try std.fmt.allocPrint(vm.gpa, "error loading module '{s}' from file '{s}':\n\t{s}", .{ name, cand.items, detail });
            defer vm.gpa.free(emsg);
            return vm.raiseLocatedError(emsg, 0);
        }
        // Success: out[0] is the closure; add the resolved path as out[1].
        if (out.len >= 2) {
            out[1] = try vm.heap.internValue(cand.items);
            return 2;
        }
        return 1;
    }

    out[0] = try vm.heap.internValue(notfound.items);
    return 1;
}

fn searchPreload1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [2]Value = .{ Value.nil(), Value.nil() };
    _ = try searchPreloadCore(vmOf(ctx), args, b[0..2]);
    return b[0];
}
fn searchPreloadN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return searchPreloadCore(vmOf(ctx), args, out);
}
fn searchPath1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    var b: [2]Value = .{ Value.nil(), Value.nil() };
    _ = try searchPathCore(vmOf(ctx), args, b[0..2]);
    return b[0];
}
fn searchPathN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    return searchPathCore(vmOf(ctx), args, out);
}

// ---------------------------------------------------------------------------
// require(name)
// ---------------------------------------------------------------------------

/// `require(name)` — Lua-shaped. Returns `package.loaded[name]` if already loaded;
/// otherwise iterates `package.searchers` in order. The first searcher returning a
/// callable loader wins: the loader is called as `loader(name, data)` and its
/// result (or `true` if it returned nothing) is cached in `package.loaded[name]`
/// and returned. Searchers returning a string contribute to the not-found message;
/// no loader → a raised `module '<name>' not found:…` error.
///
/// Reentrant: a loader may `require` further modules (rides `native_reentry_depth`
/// through `callValue`). A `require` cycle currently bottoms out in `StackOverflow`
/// rather than a dedicated "loop" message (see TODO).
fn requireCore(vm: *Vm, args: []const Value) anyerror!Value {
    // `name_val` is an argument → it lives in the caller's register window, which
    // stays GC-rooted for the whole native call (every nested `callValue` raises
    // `stack_top` above it). So the `Value` (and the string bytes it points at) are
    // stable across the reentrant calls below. The `package.*` *tables*, by contrast,
    // are reached through mutable fields and must be re-derived after each call —
    // never cached — via `requirePackageSubTable` (see its doc comment).
    const name_val = if (args.len >= 1) args[0] else Value.nil();
    const name = interp.strBytes(name_val) orelse return vm.badArg(1, "string", if (args.len >= 1) name_val else null);

    // Already loaded (or loading-in-progress) → return the cached value.
    {
        const loaded = try requirePackageSubTable(vm, "loaded", "package.loaded");
        const cached = loaded.get(name_val);
        if (!cached.isNil()) return cached;
    }

    // Accumulate the not-found message from string-returning searchers.
    var notfound: std.ArrayList(u8) = .empty;
    defer notfound.deinit(vm.gpa);

    var loader: Value = Value.nil();
    var loader_data: Value = Value.nil();
    var i: i64 = 1;
    while (true) : (i += 1) {
        // Re-derive `searchers` each iteration: the previous iteration ran a searcher
        // via `callValue`, which could have reassigned `package.searchers` (orphaning
        // a cached pointer for GC).
        const searchers = try requirePackageSubTable(vm, "searchers", "package.searchers");
        const s = searchers.getInt(i);
        if (s.isNil()) break; // end of the searcher array
        var res: [2]Value = .{ Value.nil(), Value.nil() };
        const got = try vm.callValue(s, &.{name_val}, res[0..2]);
        const r0 = res[0];
        const r1 = if (got >= 2) res[1] else Value.nil();
        if (isCallable(r0)) {
            loader = r0;
            loader_data = r1;
            break;
        } else if (interp.strBytes(r0)) |msg| {
            try notfound.appendSlice(vm.gpa, msg);
        }
        // nil / false / any non-string, non-callable → skip this searcher.
    }

    if (!isCallable(loader)) {
        const emsg = try std.fmt.allocPrint(vm.gpa, "module '{s}' not found:{s}", .{ name, notfound.items });
        defer vm.gpa.free(emsg);
        return vm.raiseLocatedError(emsg, 0);
    }

    // Run the loader: `loader(name, data)` → one result.
    var lr: [1]Value = .{Value.nil()};
    _ = try vm.callValue(loader, &.{ name_val, loader_data }, lr[0..1]);
    const result = lr[0];

    // Cache per Lua's rule: a non-nil loader result is the module; otherwise, if the
    // loader left `loaded[name]` unset, default the entry to `true`. Re-derive
    // `loaded` after the loader call (it may have replaced `package.loaded`); a
    // loader that assigned `package.loaded[name]` itself is then honoured by the
    // re-fetch below.
    const loaded = try requirePackageSubTable(vm, "loaded", "package.loaded");
    if (!result.isNil()) {
        try loaded.set(vm.gpa, name_val, result);
    }
    var cur = loaded.get(name_val);
    if (cur.isNil()) {
        try loaded.set(vm.gpa, name_val, Value.boolean(true));
        cur = Value.boolean(true);
    }
    return cur;
}

fn require1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    return requireCore(vmOf(ctx), args);
}

// ---------------------------------------------------------------------------
// Runtime install — populate the `package` table after the registry loop
// ---------------------------------------------------------------------------

/// `package.config` — the constant layout string Lua exposes: dir separator, path
/// separator, the `?` template mark, the `!` exec-dir mark, the `-` ignore mark.
const config_string = "/\n;\n?\n!\n-\n";
/// Default `package.path`. Both source extensions are searched, `.mah` first.
///
/// The extension is a claim about which *language* the file is written in, and
/// therefore about who can run it:
///
///   * `.mah` — a mahina program. May use anything mahina offers (freezable
///     shapes, optional type annotations, host-mediated suspension), so stock
///     Lua cannot necessarily even parse it. mahina only.
///   * `.lua` — a Lua program. Runs under `lua`/`luajit` *and* mahina, since Lua
///     is a subset of what mahina accepts. The LuaJIT parity benchmarks are
///     genuinely this, and stay `.lua` permanently rather than by grandfather.
///
/// `.mah` is searched first so a project can shadow a Lua module with a mahina
/// one: you are running the mahina binary, so the mahina-specific file wins.
const default_path = "./?.mah;./?/init.mah;./?.lua;./?/init.lua";

/// The two built-in searchers, as `manual` registry entries: present in
/// `base_natives` for keyframe restore by name, but never installed at a global/
/// module slot — `installPackageRuntime` creates the live heap natives and places
/// them into `package.searchers`. (Order matters: preload before path.)
pub const searcher_natives = [_]function.BaseNative{
    .{ .name = "package.searcher.preload", .func = &searchPreload1, .multi = &searchPreloadN, .manual = true },
    .{ .name = "package.searcher.path", .func = &searchPath1, .multi = &searchPathN, .manual = true },
};

/// Library natives concatenated into `interp.base_natives`. `require` is a bare
/// global; `searchpath` namespaces under `package`; the two searchers are manual.
pub const natives = [_]function.BaseNative{
    .{ .name = "require", .func = &require1 },
    .{ .name = "searchpath", .func = &searchpath1, .multi = &searchpathN, .module = "package", .field = "searchpath" },
} ++ searcher_natives;

/// Populate the `package` table's runtime fields. Called from `installBaseLib`
/// after the `defineNative` loop has created the `package` table (via the
/// `searchpath` registry entry) and the `require` global. Idempotent only in the
/// sense that it overwrites; it is invoked exactly once per VM init.
///
/// `loaded` is pre-seeded with the built-in module tables so `require"string"` etc.
/// short-circuit without a filesystem probe. `searchers` is an array of the two
/// built-in searcher natives, created here from `searcher_natives` (keeping their
/// `multi` projection so `require` can pull two results). Every field is an ordinary
/// heap table/string/native reachable from `globals`, so it captures/restores
/// through the keyframe path with no special-casing (the searcher natives rebind by
/// name via the `manual` registry entries).
pub fn installPackageRuntime(vm: *Vm) interp.Error!void {
    const pkg = try packageTable(vm);

    // package.loaded — pre-seeded with the built-in modules (plus _G and package).
    const loaded = try vm.heap.newTable();
    try pkg.set(vm.gpa, try vm.heap.internValue("loaded"), Value.heap(&loaded.header));
    try seedLoaded(vm, loaded);

    // package.preload — empty; a host/script fills it to register in-memory modules.
    const preload = try vm.heap.newTable();
    try pkg.set(vm.gpa, try vm.heap.internValue("preload"), Value.heap(&preload.header));

    // package.path / cpath / config.
    try pkg.set(vm.gpa, try vm.heap.internValue("path"), try vm.heap.internValue(default_path));
    try pkg.set(vm.gpa, try vm.heap.internValue("cpath"), try vm.heap.internValue(""));
    try pkg.set(vm.gpa, try vm.heap.internValue("config"), try vm.heap.internValue(config_string));

    // package.searchers — array of the built-in searcher natives, in order.
    const searchers = try vm.heap.newTable();
    try pkg.set(vm.gpa, try vm.heap.internValue("searchers"), Value.heap(&searchers.header));
    for (searcher_natives, 0..) |bn, idx| {
        const nat = try vm.heap.newNative(bn.func, bn.name);
        nat.multi = bn.multi; // searchers return (loader, data) → keep the 2-result projection
        try searchers.set(vm.gpa, Value.int(@as(i64, @intCast(idx)) + 1), Value.heap(&nat.header));
    }
}

/// Pre-seed `package.loaded` with the built-in module tables already installed on
/// `globals`, so `require` of a built-in returns the live module table. `_G` maps
/// to the globals table itself (Lua's `package.loaded._G == _G`).
fn seedLoaded(vm: *Vm, loaded: *Table) interp.Error!void {
    const builtins = [_][]const u8{ "package", "string", "table", "math", "os", "io" };
    for (builtins) |modname| {
        const key = try vm.heap.internValue(modname);
        const mod = vm.globals.get(key);
        if (mod.isHeap() and mod.heapType() == .table) try loaded.set(vm.gpa, key, mod);
    }
    // `_G` is the globals table itself (a reflective self-reference, like the `_G`
    // global seeded in `installBaseLib`).
    try loaded.set(vm.gpa, try vm.heap.internValue("_G"), Value.heap(&vm.globals.header));
}
