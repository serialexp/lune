//! Doc 60 §3.1: the one predicate for "this target builds the hand-written
//! host-call entry". `build.zig` imports it to decide whether
//! `hostcall_x64.S` joins the library, and `capi.zig` imports it to decide
//! whether `mh_call` tail-calls into that entry — one definition, so the two
//! can never disagree (an entry referenced but not linked, or linked but
//! unreachable).
//!
//! The gate is the OS and ABI, not the CPU alone: the entry is SysV and ELF.
//! Windows x64 has a different calling convention, and the x32 ABI has 32-bit
//! pointers. Every other target runs H1 (`hostcallSlow`) as its whole path.

const std = @import("std");

/// The entry's straight-line argument limit (doc 60 §4.1): the Rust crate's
/// inline `ArgBuf` size. More arguments fall back to H1.
pub const args_max = 8;

pub fn hostcallEntry(t: *const std.Target) bool {
    return t.cpu.arch == .x86_64 and
        t.os.tag == .linux and
        t.ofmt == .elf and
        t.ptrBitWidth() == 64;
}
