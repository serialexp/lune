//! lune CLI — run a lune program through the tier-0 interpreter.
//!
//! Usage:
//!   lune <script.lua>   run a script file
//!   lune -e <chunk>     run a chunk given inline on the command line
//!
//! The driver walks the same path the test suite exercises —
//! parse → compile → tier-0 interpret — and just wires it to argv and the
//! process stdout/stderr. A program's own output (via `print`) goes to stdout
//! through the host-effect seam (`Vm.out`); parse/compile diagnostics and driver
//! errors go to stderr. Exit code is 0 on success, 1 on an I/O / syntax /
//! compile / runtime error, 2 on a usage error.

const std = @import("std");
const lune = @import("lune");

const Diagnostics = lune.diag.Diagnostics;

const usage =
    \\lune — a Lua-shaped language (tier-0 interpreter)
    \\
    \\usage:
    \\  lune <script.lua>   run a script file
    \\  lune -e <chunk>     run a chunk given inline
    \\
;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;

    var it = init.minimal.args.iterate();
    defer it.deinit(); // no-op on Linux; correct on Windows/WASI
    _ = it.skip(); // skip argv[0]

    const first = it.next() orelse {
        lune.io.eprint("{s}", .{usage});
        return 2;
    };

    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        lune.io.print("{s}", .{usage});
        return 0;
    }

    if (std.mem.eql(u8, first, "-e")) {
        // argv strings are already NUL-terminated, so this is a `[:0]const u8`.
        const chunk = it.next() orelse {
            lune.io.eprint("lune: error: -e requires a chunk argument\n", .{});
            return 2;
        };
        return runSource(gpa, "=(command line)", chunk);
    }

    // Otherwise the first argument is a script path.
    const source = lune.io.readFileZ(gpa, init.io, first) catch |err| {
        lune.io.eprint("lune: error: cannot read '{s}': {s}\n", .{ first, @errorName(err) });
        return 1;
    };
    defer gpa.free(source);
    return runSource(gpa, first, source);
}

/// Parse, compile, and run one source chunk. Returns the process exit code.
/// `name` labels the chunk in diagnostics (a file path or a synthetic name).
fn runSource(gpa: std.mem.Allocator, name: []const u8, source: [:0]const u8) u8 {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();

    // --- parse ---
    var tree = lune.parser.parse(gpa, source, &diags) catch |err| {
        reportDiagnostics(name, &diags);
        lune.io.eprint("lune: error: parse failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer tree.deinit();
    if (diags.hasErrors()) {
        reportDiagnostics(name, &diags);
        return 1;
    }

    // The VM owns the heap that string constants are interned into, so it must
    // outlive the chunk. Bring it up before compiling.
    var vm = lune.interp.Vm.init(gpa) catch |err| {
        lune.io.eprint("lune: error: vm init failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer vm.deinit();

    // --- compile ---
    var chunk = lune.compiler.compile(gpa, &vm.heap, source, tree.root, &diags) catch |err| {
        reportDiagnostics(name, &diags);
        lune.io.eprint("lune: error: compile failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer chunk.deinit();
    if (diags.hasErrors()) {
        reportDiagnostics(name, &diags);
        return 1;
    }

    // --- run --- (a program's `print` output reaches stdout via Vm.out == null)
    _ = vm.run(chunk.proto) catch |err| {
        lune.io.eprint("lune: error: runtime: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Print every recorded diagnostic to stderr, one per line, with its 1-based
/// source line. v1 messages are static strings (see diag.zig).
fn reportDiagnostics(name: []const u8, diags: *const Diagnostics) void {
    for (diags.list.items) |d| {
        lune.io.eprint("{s}:{d}: {s}: {s}\n", .{
            name,
            d.line,
            @tagName(d.severity),
            d.message,
        });
    }
}

test "cli smoke" {
    // Keep the CLI module's test target non-empty so `zig build test` covers it.
    // The end-to-end run path is covered by the interp/compiler test suites,
    // which exercise parse → compile → run against an in-memory output sink.
    try std.testing.expectEqual(@as(u64, 5), lune.dispatch.run(5));
}
