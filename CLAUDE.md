# lune — project instructions

lune is a Lua-shaped (not Lua-compatible), dynamically-typed language with a
tracing JIT and a time-travel trace visualiser, written in Zig. Start with
`docs/design/00-architecture.md`; the companion docs (`01`–`04`) own the trace
lifecycle, determinism, GC/memory, and the snapshot/replay schema.

## Rules

### Rule Z-1: Verify the Zig stdlib before relying on it — do not trust memory.

We pin a `-dev` Zig toolchain (`.zig-version`). The stdlib is a moving target and
your training data about it is stale — function names, signatures, the whole
`std.Io` writer/reader model, build-system APIs, and `std.fmt` have all churned
and will keep churning. **Before you call or depend on any stdlib API, confirm
what it actually is in the pinned toolchain.** Read the source under
`$(dirname $(readlink -f $(which zig)))/../lib/std/` (or wherever `.zig-version`
resolves to) and check the real signature, fields, and behaviour. `zig init` is
the source of truth for current `build.zig`/`build.zig.zon` shape.

Concretely:
- Grep/read the actual `lib/std/**.zig` for the symbol; don't guess the name or
  arguments. (`std.Io.File.stdout()`, `File.Writer` via `@fieldParentPtr`, the
  `Io.Threaded` instance, `Writer.fixed`, etc. are all things memory gets wrong.)
- If a build fails with "no member named X" or a signature mismatch, the fix is
  to read the current source, not to try variations.
- Things already verified the hard way (see `00-architecture.md`): guaranteed
  tail calls are **LLVM-backend only** (`use_llvm = true`); `refAllDeclsRecursive`
  is gone; `**`/array-repeat wants symmetric whitespace; the stdout writer needs
  an `Io` instance and a stably-addressed `File.Writer`.

### Rule Z-2: Confine the churning frontier to wrappers.

Per architecture principle #4 we stay on Zig's bedrock (manual memory, comptime,
tail calls, inline asm, C ABI) and avoid the churn (async/`std.Io`, bleeding-edge
stdlib). Where we genuinely need a churny surface, confine it to one wrapper so a
toolchain bump is a one-file fix, not a sweep. Example: all `std.Io` writer use
and `Value` text rendering live in `src/io.zig`; the VM core and `Value` stay
free of it.

### Rule Z-3: Keep it green and tested.

Every phase lands behind `zig build test`. Pure logic (numeric semantics, the
value model, lexer/parser rules) gets its shape pinned with tests. Don't proclaim
success while anything is red (global Rule #3).

### Rule Z-4: Inject allocators; account at the boundary.

Allocation is the runtime's main enemy. Every subsystem takes an
`std.mem.Allocator` parameter — never reach for a global heap (the only
deliberate exception is the diagnostic stdout path in `src/io.zig`, which is not
VM data). Tests run on `std.testing.allocator`, which leak-checks; a `defer
…deinit()` for every owning structure is mandatory, not optional. For runtime /
embedding memory introspection, wrap the backing allocator once in
`mem.TrackingAllocator` (live/peak/total bytes, outstanding-allocation count,
`assertNoLeaks()`) and feed every subsystem from it. Prefer arenas for
parse-once/free-all lifetimes (the AST already does this).

### Rule Z-5: Keep the stdlib inventory in lockstep with the stdlib.

`docs/lua-stdlib-inventory.csv` is the canonical map of the Lua 5.4 standard
library we draw from: one row per function/constant, columns
`category,function,tier,status,description`. `tier` is the disposition
(`core` = pure deterministic language; `base-host` = host effects installed in
every VM; `cli-binding` = the OS world the default CLI ships and a game host
omits; `excluded` = won't implement, determinism-hostile or out of scope), and
`status` is implementation progress (`implemented`/`partial`/`not-started`, or
`n/a` for excluded rows). Whenever you add, finish, rename, namespace, or drop a
stdlib function, update its row in the **same change** — flip `status`, move the
`tier`, or add the row — so the inventory never drifts from the tree (global
Rule #3 spirit). It's the at-a-glance "what's left to replicate" for lune.

## Build

- `zig build` — build the CLI.
- `zig build test` — run all unit tests (the gate).
- `zig build run` — run the CLI.
- `zig build -Denforce-zig-version=true` — hard-fail on toolchain drift (CI).
