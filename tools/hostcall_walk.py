# Doc 60 §6.3: the unwinding walks of the host-call build acceptance, as gdb
# commands. Sourced by tools/hostcall-acceptance.sh; not run on its own.
#
#   expect-walk <label> <pattern> [<pattern> ...]
#
# Walks the stack from the selected stop, innermost first, over PHYSICAL
# frames only (inlined frames share their caller's machine frame, and the
# §3.3 table is about machine frames). Each frame is named by its ELF symbol
# (`info symbol`), so a hidden export reads as its linker name
# (`mahina_hostcall_slow`), not as the Zig function behind it. The walk stops
# at `main`. The names must match the patterns in order: a pattern is an
# fnmatch glob for exactly one frame, and `...` matches any run of frames,
# including none. A mismatch prints the walk and makes gdb exit 1.
#
# This is the DWARF walk, and it checks that it is one. gdb's prologue
# analyser fills in wherever CFI is missing or rejected, and gdb 15 can't
# switch it off (`maint frame-unwinder disable` arrived in gdb 16). So the
# walk runs with `set debug frame on`, logged to a file, after flushing the
# frame cache: the log names the unwinder that accepted each frame level
# (`frame_unwind_try_unwinder: yes`), and every machine frame must have been
# accepted by `dwarf2`. That is gdb's own verdict, so an FDE gdb rejects (an
# unsupported CIE version, say) fails the walk too.
#
#   expect-fp-walk <label> <pattern> [<pattern> ...]
#
# The same names, but the walk follows the raw rbp chain (saved rbp at [rbp],
# return address at [rbp+8]) and uses no unwinder at all — gdb's own
# non-DWARF fallback analyses prologues, so it would pass without frame
# pointers. The frame-pointer walk must also name exactly the frames gdb's
# walk names: a frame that drops out of the rbp chain (a function that
# doesn't keep rbp) shows up as a difference, which a `...` pattern alone
# would hide.

import fnmatch
import os
import re
import tempfile

import gdb


def _symbol(pc):
    text = gdb.execute("info symbol 0x%x" % pc, to_string=True).strip()
    if text.startswith("No symbol"):
        return "?0x%x" % pc
    return text.split(" ")[0]


def _physical_walk():
    # (name, frame level) per machine frame.
    frames = []
    frame = gdb.newest_frame()
    while frame is not None:
        if frame.type() != gdb.INLINE_FRAME:
            # A caller's pc is its return address, which can sit just past
            # the function when the call is its last instruction.
            pc = frame.pc() if not frames else frame.pc() - 1
            frames.append((_symbol(pc), frame.level()))
            if frames[-1][0] == "main":
                break
        frame = frame.older()
    return frames


def _logged_walk():
    # The walk, plus the unwinder gdb chose for each frame level, from its
    # frame-debug log. Flushing the frame cache makes gdb choose afresh.
    # The logging commands must not run under `to_string=True`: inside that
    # capture the debug stream never reaches the log file.
    fd, log = tempfile.mkstemp(prefix="hostcall-walk-", suffix=".log")
    os.close(fd)
    try:
        for cmd in ("set logging file " + log, "set logging overwrite on", "set logging debugredirect on",
                    "set logging enabled on", "maint flush register-cache", "set debug frame on"):
            gdb.execute(cmd)
        try:
            frames = _physical_walk()
        finally:
            gdb.execute("set debug frame off")
            gdb.execute("set logging enabled off")
        with open(log) as f:
            text = f.read()
    finally:
        os.unlink(log)
    unwinders = {}
    level, trying = None, None
    for line in text.splitlines():
        m = re.search(r"frame_unwind_find_by_frame: this_frame=(-?\d+)", line)
        if m:
            level = int(m.group(1))
            continue
        m = re.search(r'frame_unwind_try_unwinder: trying unwinder "([^"]*)"', line)
        if m:
            trying = m.group(1)
            continue
        if re.search(r"frame_unwind_try_unwinder: yes$", line) and level is not None:
            unwinders[level] = trying
    return frames, unwinders


def _finish_prologue():
    # gdb may stop on a function's first instruction, before it has pushed
    # rbp. When the function opens with the standard `[endbr64] push %rbp;
    # mov %rsp,%rbp`, single-step to just past the mov so rbp is its frame.
    # A function that doesn't open that way is walked as it stands (and, if
    # it never keeps rbp, drops out of the chain — the failure this catches).
    # The machine function's start, from its ELF symbol: `info symbol` says
    # "name + offset in section .text" (no "+ offset" at the start itself).
    # Debug-info blocks would name an inlined function instead.
    pc = int(gdb.parse_and_eval("$pc"))
    words = gdb.execute("info symbol 0x%x" % pc, to_string=True).split()
    if not words or words[0] == "No":
        return
    start = pc - (int(words[2]) if len(words) > 2 and words[1] == "+" else 0)
    arch = gdb.selected_frame().architecture()
    insns = arch.disassemble(start, count=3)
    asm = [" ".join(i["asm"].split()) for i in insns]
    if asm and asm[0].startswith("endbr64"):
        insns, asm = insns[1:], asm[1:]
    if len(asm) < 2 or asm[0] != "push %rbp" or asm[1] != "mov %rsp,%rbp":
        return
    past_mov = insns[1]["addr"] + insns[1]["length"]
    while start <= pc < past_mov:
        gdb.execute("stepi", to_string=True)
        pc = int(gdb.parse_and_eval("$pc"))


def _fp_walk():
    _finish_prologue()
    inferior = gdb.selected_inferior()
    names = [_symbol(int(gdb.parse_and_eval("$pc")))]
    rbp = int(gdb.parse_and_eval("(unsigned long)$rbp"))
    while names[-1] != "main" and rbp != 0 and len(names) < 256:
        words = inferior.read_memory(rbp, 16).tobytes()
        saved_rbp = int.from_bytes(words[0:8], "little")
        ret = int.from_bytes(words[8:16], "little")
        names.append(_symbol(ret - 1))
        rbp = saved_rbp
    return names


def _matches(names, patterns):
    if not patterns:
        return not names
    if patterns[0] == "...":
        return any(_matches(names[i:], patterns[1:]) for i in range(len(names) + 1))
    return bool(names) and fnmatch.fnmatchcase(names[0], patterns[0]) and _matches(names[1:], patterns[1:])


class ExpectWalk(gdb.Command):
    def __init__(self, name, frame_pointers):
        super().__init__(name, gdb.COMMAND_USER)
        self.frame_pointers = frame_pointers

    def invoke(self, arg, from_tty):
        words = gdb.string_to_argv(arg)
        label, patterns = words[0], words[1:]
        frames, unwinders = _logged_walk()
        names = [name for name, _ in frames]
        problem = None
        if not names or names[-1] != "main":
            problem = "the walk does not reach main"
        elif not _matches(names, patterns):
            problem = "the frames don't match"
        elif self.frame_pointers:
            cfi = names
            names = _fp_walk()
            if names != cfi:
                problem = "the rbp chain differs from gdb's walk (%s)" % " <- ".join(cfi)
        else:
            # main's own unwinder is never needed (the walk ends there).
            others = ["%s by %s" % (name, unwinders.get(level, "an unlogged unwinder"))
                      for name, level in frames[:-1] if unwinders.get(level) != "dwarf2"]
            if others:
                problem = "not unwound from CFI: %s" % ", ".join(others)
        if problem is None:
            print("walk ok: %s: %s" % (label, " <- ".join(names)))
            return
        print("walk FAILED: %s: %s" % (label, problem))
        print("  expected: %s" % " <- ".join(patterns))
        print("  got:      %s" % " <- ".join(names))
        gdb.execute("kill")
        gdb.execute("quit 1")


ExpectWalk("expect-walk", frame_pointers=False)
ExpectWalk("expect-fp-walk", frame_pointers=True)
