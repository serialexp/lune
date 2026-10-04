#!/usr/bin/env bash
# Doc 60 §6.3: build acceptance for the hand-written host-call entry
# (src/asm/hostcall_x64.S), Linux x86-64 only. Run it via `just
# hostcall-acceptance [optimize]` (default ReleaseFast).
#
# It builds libmahina twice — position-independent, and again with frame
# pointers kept for the frame-pointer walks — and checks:
#   - visibility, per archive object: every mahina_hostcall_* symbol,
#     definitions and undefined references alike, is HIDDEN; mh_call is
#     GLOBAL DEFAULT;
#   - relocations, in real links made with -z text (a text relocation is a
#     link error): the whole archive into a shared library, and the host
#     fixture (tests/hostcall_accept.c) into a PIE; the entry is present in
#     both, no internal symbol is dynamically exported, there's no TEXTREL,
#     and the stack isn't executable; both fixtures run;
#   - the tail call: the linked mh_call jumps to the entry and never calls it;
#   - unwinding, per path, in gdb (tools/hostcall_walk.py), once with DWARF
#     CFI (gdb's frame-debug log must show every frame accepted by its
#     dwarf2 unwinder, the entry's pre-commit stretch included) and once
#     along the raw rbp chain, each walk back to main.
# Negative controls show the visibility, -z text, DWARF and frame-pointer
# checks each catch a failure.
#
# The walks follow §3.3's table for the paths this revision of the entry
# has; H3 adds the admitted path's and the park helper's.
set -euo pipefail

optimize=${1:-ReleaseFast}
cc=${CC:-cc}
root=$(cd "$(dirname "$0")/.." && pwd)
out=${HOSTCALL_ACCEPTANCE_DIR:-${TMPDIR:-/tmp}/mahina-hostcall-acceptance}
failures=0

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}
pass() { echo "ok: $*"; }

# Every mahina_hostcall_* symbol is HIDDEN; with require=1, also: mh_call is
# defined GLOBAL DEFAULT, and the three internal symbols are defined.
check_visibility() {
    readelf -sW "$1" | awk -v require="$2" '
        /^File: / { file = $2 }
        $8 ~ /^mahina_hostcall_/ {
            if ($6 != "HIDDEN") {
                printf "  %s: %s is %s%s\n", file, $8, $6, ($7 == "UND" ? " (undefined reference)" : "")
                bad = 1
            }
            if ($7 != "UND") defined[$8] = 1
        }
        $8 == "mh_call" && $7 != "UND" {
            mh_call = 1
            if ($5 != "GLOBAL" || $6 != "DEFAULT") { printf "  mh_call is %s %s\n", $5, $6; bad = 1 }
        }
        END {
            if (require) {
                if (!mh_call) { print "  mh_call is not defined"; bad = 1 }
                n = split("mahina_hostcall_entry mahina_hostcall_slow mahina_hostcall_offsets_safety", want, " ")
                for (i = 1; i <= n; i++)
                    if (!(want[i] in defined)) { printf "  %s is not defined\n", want[i]; bad = 1 }
            }
            exit bad
        }'
}

# The linked-output checks shared by the library and the PIE.
check_linked() {
    local what=$1 file=$2
    if readelf -sW "$file" | awk '$8 == "mahina_hostcall_entry" { found = 1 } END { exit !found }'; then
        pass "$what: mahina_hostcall_entry is present"
    else
        fail "$what: mahina_hostcall_entry is missing (was the archive pulled in?)"
    fi
    local exported
    exported=$(readelf --dyn-syms -W "$file" | awk '$8 ~ /^mahina_hostcall_/ { print $8 }')
    if [ -z "$exported" ]; then pass "$what: no internal symbol is dynamically exported"; else fail "$what: dynamically exports $exported"; fi
    if readelf -dW "$file" | grep -q TEXTREL; then fail "$what: has TEXTREL"; else pass "$what: no TEXTREL"; fi
    if readelf -lW "$file" | awk '$1 == "GNU_STACK" { stack = 1; if ($7 ~ /E/) exec = 1 } END { exit !(stack && !exec) }'; then
        pass "$what: non-executable stack"
    else
        fail "$what: executable or unmarked stack"
    fi
}

# Run the walks in gdb against a fixture binary, with `expect-walk` (DWARF,
# every frame unwound by gdb's dwarf2 unwinder) or `expect-fp-walk` (the raw rbp chain, which
# must match gdb's walk). The DWARF leg also stops in the entry itself, on
# its pre-commit `jmp`: that stretch has no frame of its own and is described
# by the entry-state CFI alone (§3.3), so only the DWARF leg can walk it.
check_walks() {
    local what=$1 exe=$2 walk=$3
    local log="$out/walks-$what.log" entry=() want=3
    if [ "$walk" = expect-walk ]; then
        entry=(-ex "break mahina_hostcall_entry" -ex run -ex "$walk entry mahina_hostcall_entry main")
        want=4
    fi
    gdb --batch -nx \
        -ex "set pagination off" -ex "set confirm off" -ex "set breakpoint pending off" \
        -ex "source $root/tools/hostcall_walk.py" \
        "${entry[@]}" \
        -ex "break mahina_hostcall_slow" -ex "break host_cb" \
        -ex "$([ ${#entry[@]} -eq 0 ] && echo run || echo continue)" \
        -ex "$walk fallback mahina_hostcall_slow main" \
        -ex continue \
        -ex "$walk callback host_cb ... mahina_hostcall_slow main" \
        -ex "rbreak ^interp\\.Vm\\.opRet" -ex continue \
        -ex "$walk guest-handler interp.Vm.opRet* ... mahina_hostcall_slow main" \
        -ex kill \
        "$exe" >"$log" 2>&1 || true
    local ok
    ok=$(grep -c '^walk ok:' "$log" || true)
    grep -E '^walk (ok|FAILED)|^  (expected|got):' "$log" | sed "s/^/  [$what] /"
    if [ "$ok" -eq "$want" ] && ! grep -q '^walk FAILED' "$log"; then
        pass "$what unwinding: $want walks back to main"
    else
        fail "$what unwinding: $ok of $want walks passed (log: $log)"
    fi
}

rm -rf "$out"
mkdir -p "$out"
cd "$root"

echo "== building libmahina ($optimize): PIC, and PIC with frame pointers"
zig build lib -Doptimize="$optimize" -Dlib-pic=true --prefix "$out/pic"
zig build lib -Doptimize="$optimize" -Dlib-pic=true -Dlib-frame-pointers=true --prefix "$out/fp"
lib="$out/pic/lib/libmahina.a"

echo "== visibility"
if check_visibility "$lib" 1; then pass "every mahina_hostcall_* symbol is HIDDEN, mh_call is GLOBAL DEFAULT"; else fail "visibility"; fi

echo "== links (-z text)"
"$cc" -shared -o "$out/libmahina.so" -Wl,-z,text -Wl,--whole-archive "$lib" -Wl,--no-whole-archive -lm \
    && pass "shared library links" || fail "shared library link"
fixture_flags=(-std=c99 -O1 -g -Iinclude -fPIE -funwind-tables -fasynchronous-unwind-tables)
"$cc" "${fixture_flags[@]}" tests/hostcall_accept.c -pie -Wl,-z,text -o "$out/accept-pie" "$lib" -lm \
    && pass "PIE links" || fail "PIE link"
"$cc" "${fixture_flags[@]}" tests/hostcall_accept.c -Wl,-z,text -o "$out/accept-shared" \
    -L"$out" -lmahina -Wl,-rpath,"$out" \
    && pass "fixture links against the shared library" || fail "fixture link against the shared library"
check_linked "shared library" "$out/libmahina.so"
check_linked "PIE" "$out/accept-pie"
for exe in accept-pie accept-shared; do
    if [ -x "$out/$exe" ] && "$out/$exe" >/dev/null; then pass "$exe runs"; else fail "$exe run"; fi
done

echo "== tail call"
objdump -d --no-show-raw-insn "$out/accept-pie" \
    | awk '/^[0-9a-f]+ <mh_call>:/ { f = 1; next } f && /^$/ { f = 0 } f' >"$out/mh_call.dis"
if grep -qE 'jmp +[0-9a-f]+ <mahina_hostcall_entry>' "$out/mh_call.dis" \
    && ! grep -qE 'call +[0-9a-f]+ <mahina_hostcall_entry>' "$out/mh_call.dis"; then
    pass "mh_call jumps to mahina_hostcall_entry and never calls it"
else
    fail "mh_call does not tail-call mahina_hostcall_entry (see $out/mh_call.dis)"
fi

echo "== unwinding"
check_walks dwarf "$out/accept-pie" expect-walk
"$cc" "${fixture_flags[@]}" -fno-omit-frame-pointer tests/hostcall_accept.c -pie -Wl,-z,text \
    -o "$out/accept-pie-fp" "$out/fp/lib/libmahina.a" -lm
check_walks frame-pointer "$out/accept-pie-fp" expect-fp-walk

echo "== negative controls"
mkdir -p "$out/neg"
printf '\t.text\n\t.globl mahina_hostcall_bogus\nmahina_hostcall_bogus:\n\tret\n\t.section .note.GNU-stack,"",@progbits\n' >"$out/neg/vis.s"
"$cc" -c "$out/neg/vis.s" -o "$out/neg/vis.o"
ar rcs "$out/neg/vis.a" "$out/neg/vis.o"
if check_visibility "$out/neg/vis.a" 0 >/dev/null; then fail "the visibility check passed a DEFAULT symbol"; else pass "the visibility check rejects a DEFAULT symbol"; fi
# A 64-bit absolute address in .text: a shared object can still be linked
# from it, as a text relocation, unless -z text forbids it. (A 32-bit one
# would fail without -z text too, and prove nothing about the flag.)
printf '\t.text\n\t.globl f\nf:\n\tmovabs $f, %%rax\n\tret\n\t.section .note.GNU-stack,"",@progbits\n' >"$out/neg/abs.s"
"$cc" -c "$out/neg/abs.s" -o "$out/neg/abs.o"
if "$cc" -shared -o "$out/neg/abs-permissive.so" "$out/neg/abs.o" 2>/dev/null \
    && readelf -dW "$out/neg/abs-permissive.so" | grep -q TEXTREL; then
    if "$cc" -shared -Wl,-z,text -o "$out/neg/abs.so" "$out/neg/abs.o" 2>/dev/null; then
        fail "-z text accepted a text relocation"
    else
        pass "-z text rejects a text relocation that links without it"
    fi
else
    fail "the text-relocation control didn't produce a TEXTREL without -z text"
fi
# Without unwind tables or debug info, the callback has no FDE. gdb's
# prologue analyser still walks it to main, which is exactly what the DWARF
# walk has to notice.
"$cc" -std=c99 -O1 -Iinclude -fPIE -fno-asynchronous-unwind-tables -fno-unwind-tables \
    tests/hostcall_accept.c -pie -Wl,-z,text -o "$out/neg/accept-pie-nocfi" "$lib" -lm
gdb --batch -nx -ex "set pagination off" -ex "set confirm off" \
    -ex "source $root/tools/hostcall_walk.py" -ex "break host_cb" -ex run \
    -ex "expect-walk callback host_cb ... mahina_hostcall_slow main" -ex kill \
    "$out/neg/accept-pie-nocfi" >"$out/neg/walk-nocfi.log" 2>&1 || true
if grep -q '^walk FAILED: callback: not unwound from CFI: host_cb by ' "$out/neg/walk-nocfi.log"; then
    pass "the DWARF walk rejects a frame without CFI"
else
    fail "the DWARF walk passed a frame without CFI (log: $out/neg/walk-nocfi.log)"
fi
# The callback drops out of the rbp chain when the fixture omits frame
# pointers, so the frame-pointer walk from inside it must fail.
"$cc" "${fixture_flags[@]}" -fomit-frame-pointer tests/hostcall_accept.c -pie -Wl,-z,text \
    -o "$out/neg/accept-pie-nofp" "$out/fp/lib/libmahina.a" -lm
gdb --batch -nx -ex "set pagination off" -ex "set confirm off" \
    -ex "source $root/tools/hostcall_walk.py" -ex "break host_cb" -ex run \
    -ex "expect-fp-walk callback host_cb ... mahina_hostcall_slow main" -ex kill \
    "$out/neg/accept-pie-nofp" >"$out/neg/walk.log" 2>&1 || true
if grep -q '^walk FAILED: callback: the rbp chain differs' "$out/neg/walk.log"; then
    pass "the frame-pointer walk rejects a frame without rbp"
else
    fail "the frame-pointer walk passed a frame without rbp"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "hostcall acceptance ($optimize): all checks passed"
else
    echo "hostcall acceptance ($optimize): $failures check(s) FAILED"
    exit 1
fi
