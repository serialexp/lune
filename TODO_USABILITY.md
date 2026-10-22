# Usability study findings (2026-10-20)

From a usability study against the v0.1.2 release (`~/.local/bin/mahina`
and the release vendor bundle): the CLI as a newcomer, a Lua-compatibility
corpus diffed against lua5.4/luajit, the visualiser driven in headless
Chrome, and Rust + C embedding hosts built from the bundle. Plain and
`--jit-native` runs agreed byte-for-byte everywhere, so nothing here is a
JIT-correctness bug. Items marked **(verified)** were re-run by hand after
the study; the rest come from the agents' repros. Scratch work, test
programs and screenshots: `/tmp/mstudy-{compat,viz,docs,embed}/`.

## 1. CLI host library: `io` and `os` (first up)

All 27 `cli-binding` rows in `docs/lua-stdlib-inventory.csv` are
`not-started`. A script cannot read stdin or a file, write a file, exit
with a status, or read the environment or the time. Route them through the
effect log so runs stay replayable (doc 02).

- [ ] `io.read`, `io.lines`, `io.open`, `io.close`, `io.input`,
      `io.output`, `io.flush`, `io.type`, `io.tmpfile`; `io.stdin`,
      `io.stdout`, `io.stderr`; `file:read/write/lines/seek/flush/setvbuf/close`.
- [ ] `os.exit`, `os.getenv`, `os.time`, `os.date`, `os.remove`,
      `os.rename`, `os.tmpname`.
- [x] The inventory says `io.write` is `not-started`, but it works: fix the
      row (Rule Z-5). Doc 65 Phase 0; `io.flush` added too.
- [ ] `collectgarbage` is `core` + `not-started` (not excluded); at least
      `"count"` and `"collect"` are used by ordinary code.
- [x] `prog > log 2>&1` mangles stdout: stderr overwrites the start of the
      shared file. Positional writes; doc 65 Phase 0 made stdout/stderr
      streaming writers, with C-stdio buffering.
- [ ] `os.clock()` returns an absolute value (~4.5e6); Lua's is CPU time
      since start. Deltas work.

## 2. CLI entry points

- [ ] No REPL: `mahina` with no args prints help (exit 0); `-i` → `cannot
      read '-i'`. **(verified)**
- [ ] `mahina -` → `cannot read '-': FileNotFound`; `echo … | mahina`
      prints help. **(verified)**
- [ ] A `#!/usr/bin/env mahina` first line is a syntax error.
- [ ] `...` in the main chunk → `cannot use '...' outside a vararg
      function` + `compile failed: CompileError` (internal name leaks).
      **(verified)** Script args only reach `arg`.
- [ ] `--help` is ~20 JIT-developer flags ("Phase 5a", "doc 56 ablation");
      split user flags from developer flags.
- [ ] Defaults: plain `mahina` ≈ 3× slower than lua5.4, `--trace` (help
      calls it "enable the tracing JIT") ≈ 15× slower, only `--jit-native`
      beats Lua (fib(32): lua 0.077s, mahina 0.273s, `--trace` 1.19s,
      `--jit-native` 0.115s; loaded machine). Decide the default tier and
      what `--trace` should mean to a user.
- [ ] `_VERSION` is `mahina 0.0.0`; `--version` says 0.1.2. Take it from
      build.zig.zon.
- [ ] Undefined-global warnings fire for globals set in another module or
      via `_G.x = …`, with no flag to silence them.

## 3. Language bugs (not deliberate)

- [ ] `{...}` / `{f()}` keep only the first value (also TODO.md).
      `local function v(...) return {...} end print(#v(5,6,7))` → 1.
      **(verified)**
- [ ] Call depth capped at 200 (`max_call_depth`, `src/interp.zig:132`) and
      no proper tail calls: `d(250)` and a 1000-deep tail loop overflow.
      **(verified)** Lua: ~190000 / unbounded.
- [ ] `pairs`/`next` over the hash part is quadratic: 8000 string keys
      3.7s (lua 0.00s), 16000 18s, 200k > 60s. Sparse int keys too.
      **(verified)** Global Rule #20.
- [ ] `s = s .. "x"` in a loop: 2.34s vs lua 0.07s at 80k, worse than
      quadratic.
- [ ] No string→number coercion: `"10"+5`, `-"2"` error. **(verified)**
      Nor number/string coercion of string-function args:
      `string.rep(5,2)`, `("abc"):sub("2")`, `format("%d","10")`.
- [ ] `load` ignores its env: `load("return x","c","t",{x=5})()` → nil,
      and `load("y=10",…,env)` writes the real global. **(verified)**
      `load(readerFunction)` unsupported. `local _ENV = {}` ignored;
      `setmetatable(_G, {__index/__newindex})` ignored (strict.lua).
- [ ] `goto`/labels unsupported (deferred in 00-architecture.md:76).
      **(verified)**
- [ ] Call sugar `f{...}`, `f"str"` / `require"x"` unsupported (deferred).
- [ ] `local x <const>` / `<close>`, hex floats (`0x1p4`), the `\z` escape,
      `'\xff'` don't parse.
- [ ] Multiple-assignment order: `local i,t=1,{} i, t[i] = i+1, 20` sets
      `t[2]`; the 5.4 manual's order sets `t[1]`.
- [ ] Integral floats rejected by bitwise ops (`3.0 & 1`, `2^31 | 0`) and
      `math.floor(1e100)`.
- [ ] `table.sort` without a comparator rejects elements that only have
      `__lt`.
- [ ] `string.format`: `%s` of a table (even with `__tostring`) or function
      errors; `%q` of numbers and `%a` fail; `%d` of 3.5 gives 3 (Lua
      errors). `%q` of `"a\nb"` writes `\n` where Lua writes `\` + newline.
- [ ] Hangs instead of errors: `for i=1,10,0` loops forever (Lua: `'for'
      step is zero`); `for i=maxint-2,maxint` wraps forever;
      `string.rep("x",1e10)` allocates until killed.
- [ ] Small: `next({})` returns nothing (Lua `nil`); `tonumber("inf")` →
      inf; `tonumber()`/base 99 return nil instead of erroring;
      `math.tointeger("8")` → nil; `__name` ignored; internal names leak
      into `_G` (`@ipairs_iter`, `@gmatch_iter`, `@codes_iter`).

## 4. Error messages

- [ ] No variable names: `attempt to index a nil value` where Lua says
      `(local 't')` / `(field 'x')` / `(global 'f')` / `(method 'm')`.
- [~] Locations name the function, not the file: `anonymous:11:`,
      `main:10:`, `f:1:`; tracebacks have no file names. **Partly done
      (multi-file viz, 2026-10-22):** a type fault inside a `require`d /
      `dofile`d / `load`ed chunk is now blamed on that chunk's file in the
      CLI's ` at file:line` suffix (`Fault.proto_id`), and the visualiser
      names the file of every location. Still open: an `error()` message's
      prefix and the CLI traceback rows keep the function name
      (`boom:3`), where Lua writes `lib/mod.mah:3:`. **Decided
      2026-10-22** (Bart asked coral-raven to break the tie): switch to
      Lua-style `chunk:line:`. The chunk is the file path for a loaded file,
      the script path for the entry, and the `load` chunkname otherwise.
      This needs a per-proto chunk name from the compiler, and touches
      `raiseLocatedError`, `raiseBadArg`/`nativeSite`, `synthErrorValue`,
      `capi.zig:424`, `stdlib/load.zig:174`, main.zig's traceback and about
      48 test expectations (`anonymous:N`/`main:N`). Queued behind
      coral-marten's doc 66 P5, which holds interp.zig.
- [ ] Uncaught errors put the location last (`… at file.lua:33`), caught
      ones first.
- [ ] Bare native errors: `bad argument to 'insert'/'sort'/'concat'/
      'format'/'floor'` with no position or type; bad patterns →
      `HostError`; `t[nil]=1` → `attempt to index a table value`.
- [ ] Excluded functions fail as `attempt to call a nil value`
      (`("x"):byte()`): say "string.byte is not available in mahina; use
      string.codepoint".
- [ ] An uncaught error object with `__tostring` prints `(error object is a
      table value)`.

## 5. Deliberate divergences that bite (decide / document)

- [ ] No coroutines, and the "async primitives" they were excluded for
      don't exist yet. Game scripting (wait/cutscenes/per-entity
      behaviours) and generator code can't be written.
- [ ] No `string.byte`; `string.char` takes code points, so byte-oriented
      UTF-8 encoders silently produce mojibake (`string.char(195,169)` →
      `Ã©`) rather than erroring.
- [ ] No LuaJIT/5.1 globals: `unpack`, `loadstring`, `setfenv`/`getfenv`,
      `bit`, `table.getn/maxn`, `math.pow`, `module`.
- [ ] README says "LuaJIT-era programs mostly run unmodified";
      00-architecture.md says "No Lua source compatibility". Of 5 larger
      programs only 2 ran unmodified (class lib, CSV); JSON, a template
      engine and a Brainfuck interpreter failed.
- [ ] Integral floats print as integers (`1.0` → `1`, `10/2` → `5`);
      `1e100` prints 101 digits.

## 6. Visualiser (`mahina viz`)

- [x] **In-browser Run was broken in v0.1.2:** the worker fetched
      `./mahina.wasm` relative to its own script → `/assets/mahina.wasm`
      404. Fixed (2026-10-21): `resolveWasmUrl` in
      `viz/src/wasm/mahina-client.ts` resolves against `document.baseURI`;
      `viz/test/wasm-url.test.ts` pins it. Verified by clicking Run in
      headless Chrome on a `-Dviz-dist` build (v0.1.2 404s, fixed prints
      `5050`). Needs a v0.1.3 to reach users.
- [x] A permanent click-Run smoke test (2026-10-21):
      `viz/e2e/browser-smoke.ts` drives `mahina viz` in headless Chrome
      (trace load, Run, Run both + diff, Replay); the `viz-browser-smoke`
      job in `bundle.yml` runs it and gates releases.
- [x] No source mapping: traces were `proto 0:6` (bytecode pcs) with no
      line info. The trace format (v6) now carries each instruction's
      bytecode ordinal and the ordinal → `{proto_id, pc}` table; the viz
      shows each IR row's line, marks it in the editor on hover/click, and
      marks the rows from the editor cursor's line.
  - [ ] A loaded `.mahinatrace` isn't mapped: its proto ids are another
        compile's. Needs the source paired with it (compile it to get the
        disasm), i.e. the `mahina viz prog.lua` item below.
  - [ ] `for_loop` carries the span of the body's last statement (the
        compiler never resets `cur_span` before the back-edge), so the loop
        test/increment rows map to the body's last line, not the `for`
        line. Fixing it also changes line-grain replay stepping.
- [ ] No IR vocabulary: no op tooltips/legend (`slot_load`, `phi`, `snap`,
      `entry`); registers never show variable names (IR or replay LOCALS).
      (Op tooltips wait on the in-flight `viz/src/enums.ts` edit landing.)
  - [x] `%3` links to its definition (hover marks the row, click scrolls
        and flashes it) — 9fbbffd.
- [ ] Side traces shown as unrelated flat rows (no parent/exit/link tree).
- [x] "Recorded but never executed" shown for traces that ran — a
      `.mahinatrace` now says it holds no execution log and points at
      Run (wasm) to animate.
- [ ] Abort reasons (`--dump-aborts`) never reach the UI; a program whose
      loops all abort gets "A program with a hot loop records a trace."
- [ ] `mahina viz x.mahinatrace` shows the trace under the default
      playground source; keyframe/effects/coverage files can't be loaded.
      Consider `mahina viz prog.lua`, or embed the source in the trace.
- [x] Wrong file types load as garbage source / sticky decode error. The
      artifacts have no magic bytes, so: a strict trace decode (version
      word + exact length, with a reason), and binary/non-UTF-8 files are
      refused as source with a visible error.
- [x] Loading new source during replay leaves stale state, then a
      CodeMirror `Position … out of range` crash on Run. Fixed (replay
      closes, highlight clears on doc change); the browser smoke covers it.
- [x] Stop for a runaway wasm run; disabled buttons look disabled; muted
      text 4.5:1+ at 0.75rem; `aria-label`s; Ctrl/⌘+Enter, Shift+…, Esc and
      replay transport keys; GLOBALS no longer wraps and hides builtins
      behind a toggle.
  - [ ] Panes are still fixed (no resize).
- [x] Editor stripes have a legend and per-line tooltips, and warm-up no
      longer outvotes native: the coverage artifact (v2) carries a
      per-anchor `fallback_iters` (tier-0 iterations once the anchor had a
      trace), and `classifyLine` ignores the warm-up before it.
- [x] `viz/README.md` rewritten for the current features.

## 7. Embedding (C API + Rust crates)

- [ ] No instruction budget / interrupt: `while true do end` hangs the
      host; a cooperative host-fn budget is defeated by `pcall` (doc 59
      E9).
- [ ] `require`/`dofile`/`loadfile`/`getenv` raise a non-catchable
      `FsUnavailable`/`EnvUnavailable` that poisons the VM (every later
      call: "VM is in a fatal state"); the header says only OOM poisons.
      No module-source hook (doc 59 §3.7 promises one).
- [ ] Not deterministic by default: two VMs give different
      `math.random`; `os.clock` is host time; no clock/RNG injection in
      `mh_config` (only `jit`). Transcendentals come from the host libm.
- [ ] No snapshot/restore/record/replay surface; refused with host fns
      (doc 59 E6/E8).
- [ ] No memory cap (a doubling string reached 2.1 GB, then OOM poisoned
      the VM); no userdata/host objects (E9).
- [ ] Host calls block tracing: ~38× slower hot loop per host call
      (indicative, loaded machine).
- [ ] Rust ergonomics: no `From<&str>` for `Value` (`Table::set_str(k,
      "x")` fails); callback errors are `String` (no `?` on
      `mahina::Error`); untyped callbacks; `Vm` is `!Send` though the C
      header allows one-thread-at-a-time; `print` only via polled
      `take_output`, no `take_warnings`; thrown tables reach the host as
      `(error object is a table value)`, no traceback in `Error`;
      compile errors drop the chunk name.
- [ ] The C link needs `-lm` (undocumented); the archive references
      `fork`/`execve`/`socket`/`getaddrinfo`.
- [ ] The bundle has no README (`MAHINA_PREBUILT_ROOT` is documented only
      in `mahina-sys/build.rs`); it unpacks into `mahina-bundle-<tag>/`,
      not `<dir>/lib` as the release notes imply. Crates not on crates.io.

## 8. Docs, licensing, ecosystem

- [ ] No LICENSE in the repo or any release archive (`gh repo view` →
      `licenseInfo: null`).
- [ ] No user-facing docs: all of `docs/design/` is internal. Proposed
      site: Why mahina → Install → Hello world → Coming from Lua
      (generated from the inventory CSV) → Language reference → Stdlib
      reference → Determinism & replay → Embedding guide → Performance
      guide → CLI reference → Changelog → Internals.
- [ ] README: no hello-world, says `script.mahina` (the extension is
      `.mah`; also in the release-notes template in `bundle.yml`), never
      mentions embedding.
- [ ] Release notes are a commit hash + checksums; no CHANGELOG,
      CONTRIBUTING, issue templates, repo topics or homepage.
- [ ] No editor support (TextMate/tree-sitter grammar, LSP, formatter), no
      test runner, no package manager / registry story (LuaRocks
      libraries hit call sugar, coroutines, `string.byte`).
- [ ] Windows: a bare zip (no README/LICENSE, no PATH setup, no
      winget/scoop), unsigned exe, and no native JIT, so always the
      slower-than-Lua interpreter.
- [ ] `math.random` seeds differently per CLI run; undocumented for a
      language whose headline is determinism.
