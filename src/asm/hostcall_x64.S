/*
 * Doc 60: the hand-written host-call entry, Linux x86-64 (SysV, ELF).
 *
 * `mh_call` (capi.zig) does the public checks, then tail-calls
 * `mahina_hostcall_entry` with its own seven-argument signature:
 *
 *   rdi  vm (non-null)          rsi, rdx  callee (tag word, payload word)
 *   rcx  args                   r8   nargs
 *   r9   results                [rsp+8]   max_results (0 when results is null)
 *   [rsp+16]  nresults (non-null, *nresults already 0)
 *
 * Narrow contract, established by mh_call: the VM is not fatal.
 *
 * The entry admits a closure callee with at most ARGS_MAX valid arguments
 * when the VM can run it on the fast dispatch path without any limit,
 * capacity or park check failing (section 4.1). Every rejection is a bare
 * jump to `mahina_hostcall_slow` (H1, capi.zig) before the prologue and
 * before any VM write, with the argument registers and both stack arguments
 * untouched, so H1 sees exactly the call mh_call made and does every
 * rejection and diagnostic itself. The pre-commit checks use only rax, r10
 * and r11.
 *
 * An admitted call then does what H1's closure path does, in the order of
 * section 4.3: the idle park clear, the callee and argument parks, the bind,
 * the frame push, the run (`mahina_hostcall_chain`, Zig), and the copy-out
 * with result parks (`mahina_hostcall_park_rest`, Zig, once the inline park
 * is full). From the prologue on it is an ordinary SysV function: rbp frame,
 * callee-saved registers preserved, rsp 16-byte aligned at each call, CFI
 * throughout.
 *
 * Object-format specifics stay behind the macros below, so a later Mach-O
 * port changes only them (symbol prefix, section, private visibility).
 */

/* The build passes MAHINA_RUNTIME_SAFETY from the optimize mode: std's hash
 * maps are larger under runtime safety, which moves some Vm fields, so the
 * offsets file carries a block per mode (offsets_x64.zig explains). */
#if !defined(MAHINA_RUNTIME_SAFETY)
#error "MAHINA_RUNTIME_SAFETY must be defined (build.zig derives it from the optimize mode)"
#endif
#include "offsets_x64.inc"

#define SYM(name) name
#define HIDDEN(name) .hidden name
#define FUNC_BEGIN(name) \
    .globl SYM(name); HIDDEN(SYM(name)); .type SYM(name), @function; .p2align 4; SYM(name):
#define FUNC_END(name) .size SYM(name), . - SYM(name)

/* A Vm field, addressed from the VmBox pointer (the Vm is embedded). */
#define VM(field) VMBOX_VM + field

/* The offsets file checks every number against the Zig layout; these check
 * what the instructions below assume about those numbers: the access width
 * each one is encoded with, and the few constant shapes the code relies on.
 * A layout change that breaks one fails the assembly. */
#define EXPECT(cond, msg) .if !(cond); .error msg; .endif
    EXPECT(VM_DEPTH_SIZE == 4, "the entry assumes a 32-bit Vm.depth")
    EXPECT(VM_NATIVE_REENTRY_DEPTH_SIZE == 2, "the entry assumes a 16-bit Vm.native_reentry_depth")
    EXPECT(TRACE_FAST_BLOCK_SIZE == 2, "the entry assumes a 16-bit fast_block")
    EXPECT(VM_NEXT_CALL_SEQ_SIZE == 8, "the entry assumes a 64-bit Vm.next_call_seq")
    EXPECT(VM_STACK_TOP_SIZE == 8, "the entry assumes a 64-bit Vm.stack_top")
    EXPECT(VM_PARKED_INLINE_LEN_SIZE == 4, "the entry assumes a 32-bit Vm.parked_inline_len")
    EXPECT(SLICE_SIZE == 16, "the entry assumes two-word slices")
    EXPECT(CF_CLOSURE_SIZE == 8 && CF_CALL_SEQ_SIZE == 8 && CF_BASE_SIZE == 8 && CF_PC_SIZE == 8, "the entry assumes 64-bit CallFrame closure, call_seq, base and pc")
    EXPECT(CF_VARARGS_BASE_SIZE == 8 && CF_VARARGS_COUNT_SIZE == 8 && CF_CODE_CACHE_GEN_SIZE == 8, "the entry assumes 64-bit CallFrame varargs and code_cache_gen")
    EXPECT(CF_RET_DEST_SIZE == 2 && CF_RET_COUNT_SIZE == 2, "the entry assumes 16-bit CallFrame ret_dest and ret_count")
    EXPECT(PROTO_NUM_PARAMS_SIZE == 1 && PROTO_IS_VARARG_SIZE == 1, "the entry assumes byte-wide Proto.num_params and is_vararg")
    EXPECT(PROTO_NUM_REGISTERS_SIZE == 2, "the entry assumes a 16-bit Proto.num_registers")
    EXPECT(GCHEADER_TYPE_SIZE == 1, "the entry assumes a byte-wide heap type")
    EXPECT(VALUE_SIZE == 16, "the entry assumes 16-byte values (it indexes them with shl 4)")
    EXPECT(TAG_NIL == 0, "the entry assumes nil is tag 0 (its nil fill stores zeros)")
    EXPECT(ARGS_MAX < 256, "the entry assumes an argument limit that fits a byte compare")
    EXPECT(FRAMERESULT_SIZE == 4, "the entry assumes a 32-bit FrameResult")
    EXPECT(FRAMERESULT_REG_BIT == 0 && FRAMERESULT_COUNT_BIT == 16, "the entry assumes FrameResult.reg in bits 0-15 and count in 16-31")
    EXPECT(CHAINRESULT_SIZE == 8 && CHAINRESULT_STATUS == 0 && CHAINRESULT_FRAME_RESULT == 4, "the entry assumes ChainResult.status in eax and frame_result in the upper half of rax")
    EXPECT(MH_OK == 0, "the entry assumes MH_OK is 0")

/* Bind the argument at rcx into the registers at rdi (tag lane) and rsi
 * (payload lane), and park it at r10 when it is a heap value; advance all
 * four. Scratch: rax, r11. Stores are whole words (`Value.storeWords`). */
.macro BIND_PARK_ARG
    movzbl VALUE_TAG(%rcx), %eax
    mov VALUE_PAYLOAD(%rcx), %r11
    mov %al, (%rdi)
    mov %r11, (%rsi)
    cmp $TAG_HEAP_REF, %eax
    jne 1f
    mov %rax, VALUE_TAG(%r10)
    mov %r11, VALUE_PAYLOAD(%r10)
    add $VALUE_SIZE, %r10
1:  add $VALUE_SIZE, %rcx
    inc %rdi
    add $8, %rsi
.endm

/* The same without the register store: an argument past the parameters of
 * a non-vararg callee is dropped, but still parked (section 4.3 step 2). */
.macro PARK_ARG
    cmpb $TAG_HEAP_REF, VALUE_TAG(%rcx)
    jne 1f
    mov VALUE_PAYLOAD(%rcx), %r11
    movq $TAG_HEAP_REF, VALUE_TAG(%r10)
    mov %r11, VALUE_PAYLOAD(%r10)
    add $VALUE_SIZE, %r10
1:  add $VALUE_SIZE, %rcx
.endm

/* The same without the park: a vararg callee's parameters, copied a second
 * time into its window (the first copy, in the arg region, parked them). */
.macro COPY_ARG
    movzbl VALUE_TAG(%rcx), %eax
    mov VALUE_PAYLOAD(%rcx), %r11
    mov %al, (%rdi)
    mov %r11, (%rsi)
    add $VALUE_SIZE, %rcx
    inc %rdi
    add $8, %rsi
.endm

    .text

    /* Undefined references are hidden too (doc 60 section 4.2): the
     * per-object visibility check holds for references as well as
     * definitions. */
    HIDDEN(SYM(mahina_hostcall_slow))
    HIDDEN(SYM(mahina_hostcall_chain))
    HIDDEN(SYM(mahina_hostcall_park_rest))

FUNC_BEGIN(mahina_hostcall_entry)
    .cfi_startproc

    /* ---- Pre-commit: rax, r10, r11 only; any failure is H1's call. ---- */

    /* The fast word (section 5.4): no recording, pending anchor or arm
     * request, suspend cut or line index. */
    cmpw $0, VM(VM_TRACE + TRACE_FAST_BLOCK)(%rdi)
    jne SYM(mahina_hostcall_slow)
    /* A closure callee. Only the tag byte of the first word is defined. */
    cmpb $TAG_HEAP_REF, %sil
    jne SYM(mahina_hostcall_slow)
    test %rdx, %rdx
    jz SYM(mahina_hostcall_slow)
    cmpb $OBJ_FUNCTION, GCHEADER_TYPE(%rdx)
    jne SYM(mahina_hostcall_slow)
    /* The straight-line argument limit, then the VM limits. */
    cmp $ARGS_MAX, %r8
    ja SYM(mahina_hostcall_slow)
    cmpl $MAX_CALL_DEPTH, VM(VM_DEPTH)(%rdi)
    jae SYM(mahina_hostcall_slow)
    cmpw $MAX_NATIVE_REENTRY, VM(VM_NATIVE_REENTRY_DEPTH)(%rdi)
    jae SYM(mahina_hostcall_slow)
    cmpq $-1, VM(VM_NEXT_CALL_SEQ)(%rdi)
    je SYM(mahina_hostcall_slow)

    /* Every argument valid (`fromC`): a known tag that isn't row_view, and a
     * non-null heap pointer. r11 counts the values to park: the callee, and
     * each heap argument. */
    mov $1, %r11d
    test %r8, %r8
    jz 2f
    test %rcx, %rcx
    jz SYM(mahina_hostcall_slow)
    mov %rcx, %r10
    mov %r8, %rax
1:  cmpb $TAG_ROW_VIEW, VALUE_TAG(%r10)
    jae SYM(mahina_hostcall_slow)
    cmpb $TAG_HEAP_REF, VALUE_TAG(%r10)
    jne 3f
    cmpq $0, VALUE_PAYLOAD(%r10)
    je SYM(mahina_hostcall_slow)
    inc %r11d
3:  add $VALUE_SIZE, %r10
    dec %rax
    jnz 1b
2:
    /* Register capacity for the callee window at stack_top, which a vararg
     * callee with surplus arguments places above an arg region of nargs
     * slots (`bindAndPushClosure`). */
    mov CLOSURE_PROTO(%rdx), %r10
    movzwl PROTO_NUM_REGISTERS(%r10), %eax
    cmpb $0, PROTO_IS_VARARG(%r10)
    je 4f
    cmpb %r8b, PROTO_NUM_PARAMS(%r10)
    jae 4f
    add %r8, %rax
4:  add VM(VM_STACK_TOP)(%rdi), %rax
    cmp VM(VM_PAYLOADS + SLICE_LEN)(%rdi), %rax
    ja SYM(mahina_hostcall_slow)

    /* Input park capacity: the inline slots free after the idle clear must
     * hold every value counted above. r10d stays zero iff the VM is idle,
     * for the clear after the commit; r11d stays the count. */
    movzwl VM(VM_NATIVE_REENTRY_DEPTH)(%rdi), %r10d
    or VM(VM_DEPTH)(%rdi), %r10d
    mov %r11d, %eax
    jz 5f
    add VM(VM_PARKED_INLINE_LEN)(%rdi), %eax
5:  cmp $PARKED_INLINE_CAP, %eax
    ja SYM(mahina_hostcall_slow)

    /* ---- Commit: an ordinary SysV frame from here on. ---- */

    push %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    mov %rsp, %rbp
    .cfi_def_cfa_register %rbp
    push %rbx
    .cfi_offset %rbx, -24
    push %r12
    .cfi_offset %r12, -32
    push %r13
    .cfi_offset %r13, -40
    push %r14
    .cfi_offset %r14, -48
    /* Five pushes: rsp is 16-byte aligned for the calls below. The stack
     * arguments are now at 16(%rbp) (max_results) and 24(%rbp) (nresults).
     * Kept across the calls: rbx box, r12 results, r13 entry_top, r14 base. */
    mov %rdi, %rbx
    mov %r9, %r12

    /* 1. The idle park clear (`parkClearIfIdle`): the inline fill and the
     * overflow list's length (`clearRetainingCapacity`, Q12 (a)). */
    test %r10d, %r10d
    jnz 6f
    movl $0, VM(VM_PARKED_INLINE_LEN)(%rbx)
    movq $0, VM(VM_PARKED_RESULTS + PARKLIST_ITEMS + SLICE_LEN)(%rbx)
6:
    /* 2. Park the callee, then (in the bind below) each heap argument in
     * order, into the inline slots taken here; r10 is the next slot. */
    mov VM(VM_PARKED_INLINE_LEN)(%rbx), %eax
    add %eax, %r11d
    mov %r11d, VM(VM_PARKED_INLINE_LEN)(%rbx)
    shl $4, %rax
    lea VM(VM_PARKED_INLINE)(%rbx,%rax), %r10
    movq $TAG_HEAP_REF, VALUE_TAG(%r10)
    mov %rdx, VALUE_PAYLOAD(%r10)
    add $VALUE_SIZE, %r10

    /* 3. Capture the entry state; 5 (first half). Take a call_seq and write
     * the frame's fixed fields into frames[entry_depth]: closure, call_seq,
     * pc, ret_dest, ret_count, and the code-cache sentinel (section 3.2:
     * `code_cache` itself is not written, the generation invalidates it). */
    mov VM(VM_STACK_TOP)(%rbx), %r13
    mov VM(VM_DEPTH)(%rbx), %eax
    imul $CF_SIZE, %rax, %r9
    lea VM(VM_FRAMES)(%rbx,%r9), %r9
    mov %rdx, CF_CLOSURE(%r9)
    mov VM(VM_NEXT_CALL_SEQ)(%rbx), %rax
    mov %rax, CF_CALL_SEQ(%r9)
    inc %rax
    mov %rax, VM(VM_NEXT_CALL_SEQ)(%rbx)
    movq $0, CF_PC(%r9)
    movw $0, CF_RET_DEST(%r9)
    movw $0, CF_RET_COUNT(%r9)
    movq $CODE_CACHE_GEN_INVALID, CF_CODE_CACHE_GEN(%r9)

    /* 4. Bind, as `bindAndPushClosure`. rdi/rsi walk the tag and payload
     * lanes from entry_top; they stay contiguous through the arg region (if
     * any), the window and its nil fill, and end at base + num_registers.
     * rdx = num_registers, eax = num_params. */
    mov CLOSURE_PROTO(%rdx), %rax
    movzwl PROTO_NUM_REGISTERS(%rax), %edx
    movzbl PROTO_IS_VARARG(%rax), %r11d
    movzbl PROTO_NUM_PARAMS(%rax), %eax
    mov VM(VM_TAGS + SLICE_PTR)(%rbx), %rdi
    add %r13, %rdi
    mov VM(VM_PAYLOADS + SLICE_PTR)(%rbx), %rsi
    lea (%rsi,%r13,8), %rsi
    mov %r13, %r14
    cmp %rax, %r8
    jbe .Lbind_window
    test %r11d, %r11d
    jnz .Lbind_surplus

.Lbind_window:
    /* No surplus varargs: base = entry_top, no varargs. Bind the first
     * min(num_params, nargs) arguments, park (only) the ones past the
     * parameters, and nil-fill the rest of the window. */
    mov %r14, CF_BASE(%r9)
    movq $0, CF_VARARGS_BASE(%r9)
    movq $0, CF_VARARGS_COUNT(%r9)
    mov %rax, %r9
    cmp %r8, %r9
    cmova %r8, %r9
    sub %r9, %rdx
    sub %r9, %r8
    test %r9, %r9
    jz 11f
10: BIND_PARK_ARG
    dec %r9
    jnz 10b
11: test %r8, %r8
    jz .Lnil_fill
12: PARK_ARG
    dec %r8
    jnz 12b
    jmp .Lnil_fill

.Lbind_surplus:
    /* Surplus varargs: every argument into the arg region at entry_top
     * (parked), the window at base = entry_top + nargs, varargs at
     * entry_top + num_params, nargs - num_params of them. The window's
     * parameters are a second copy of the first num_params arguments. */
    lea (%r13,%r8), %r14
    mov %r14, CF_BASE(%r9)
    lea (%r13,%rax), %r11
    mov %r11, CF_VARARGS_BASE(%r9)
    mov %r8, %r11
    sub %rax, %r11
    mov %r11, CF_VARARGS_COUNT(%r9)
    sub %rax, %rdx
    mov %rax, %r9
13: BIND_PARK_ARG
    dec %r8
    jnz 13b
    mov %r14, %rax
    sub %r13, %rax
    shl $4, %rax
    sub %rax, %rcx
    test %r9, %r9
    jz .Lnil_fill
14: COPY_ARG
    dec %r9
    jnz 14b

.Lnil_fill:
    /* rdx registers from rdi/rsi on: nil tags, zero payloads (`fillNil`).
     * Eight at a time, then one at a time. */
    xor %eax, %eax
    cmp $8, %rdx
    jb 21f
    pxor %xmm0, %xmm0
20: mov %rax, (%rdi)
    movups %xmm0, (%rsi)
    movups %xmm0, 16(%rsi)
    movups %xmm0, 32(%rsi)
    movups %xmm0, 48(%rsi)
    add $8, %rdi
    add $64, %rsi
    sub $8, %rdx
    cmp $8, %rdx
    jae 20b
21: test %rdx, %rdx
    jz 23f
22: movb $TAG_NIL, (%rdi)
    movq $0, (%rsi)
    inc %rdi
    add $8, %rsi
    dec %rdx
    jnz 22b
23:
    /* 5 (second half). The push: stack_top over the window (rdi has
     * reached tags + base + num_registers), then depth + 1. ecx is loaded
     * with entry_depth here as the chain's fourth argument, below. */
    sub VM(VM_TAGS + SLICE_PTR)(%rbx), %rdi
    mov %rdi, VM(VM_STACK_TOP)(%rbx)
    mov VM(VM_DEPTH)(%rbx), %ecx
    lea 1(%rcx), %eax
    mov %eax, VM(VM_DEPTH)(%rbx)

    /* 6. Run: mahina_hostcall_chain(box, base, entry_top, entry_depth),
     * with entry_depth already in ecx (step 5). On an error the fault
     * contract has run; eax is the status. */
    mov %rbx, %rdi
    mov %r14, %rsi
    mov %r13, %rdx
    call SYM(mahina_hostcall_chain)
    test %eax, %eax
    jnz .Lreturn

    /* 7-8. produced = min(count, max_results), from the FrameResult in the
     * upper half of rax; the results start at base + reg. */
    mov %rax, %rcx
    shr $(8 * CHAINRESULT_FRAME_RESULT + FRAMERESULT_COUNT_BIT), %rcx
    shr $(8 * CHAINRESULT_FRAME_RESULT), %rax
    movzwl %ax, %eax
    mov 16(%rbp), %rdx
    cmp %rdx, %rcx
    cmova %rdx, %rcx
    /* 9. Restore stack_top. Nothing below collects (parking never does), so
     * the popped window's registers stay as they are while they're read. */
    mov %r13, VM(VM_STACK_TOP)(%rbx)
    mov %rcx, %r13
    add %r14, %rax
    mov VM(VM_TAGS + SLICE_PTR)(%rbx), %rdi
    add %rax, %rdi
    mov VM(VM_PAYLOADS + SLICE_PTR)(%rbx), %rsi
    lea (%rsi,%rax,8), %rsi
    mov %r12, %r9
    mov VM(VM_PARKED_INLINE_LEN)(%rbx), %r8d

    /* 8 and 10, in one pass: copy each result out as two whole words and
     * park each heap one in the next inline slot. Slots taken during the
     * call (a callback's nested API calls) are seen here, through r8d. */
    test %rcx, %rcx
    jz 31f
30: movzbl (%rdi), %eax
    mov (%rsi), %r11
    mov %rax, VALUE_TAG(%r9)
    mov %r11, VALUE_PAYLOAD(%r9)
    cmp $TAG_HEAP_REF, %eax
    jne 32f
    cmp $PARKED_INLINE_CAP, %r8d
    jae .Lpark_overflow
    mov %r8, %r10
    shl $4, %r10
    mov %rax, VM(VM_PARKED_INLINE + VALUE_TAG)(%rbx,%r10)
    mov %r11, VM(VM_PARKED_INLINE + VALUE_PAYLOAD)(%rbx,%r10)
    inc %r8d
32: inc %rdi
    add $8, %rsi
    add $VALUE_SIZE, %r9
    dec %rcx
    jnz 30b
31: mov %r8d, VM(VM_PARKED_INLINE_LEN)(%rbx)

.Lreport:
    /* 11. *nresults = produced; MH_OK. */
    mov 24(%rbp), %rdx
    mov %r13, (%rdx)
    xor %eax, %eax

.Lreturn:
    .cfi_remember_state
    pop %r14
    .cfi_restore %r14
    pop %r13
    .cfi_restore %r13
    pop %r12
    .cfi_restore %r12
    pop %rbx
    .cfi_restore %rbx
    pop %rbp
    .cfi_restore %rbp
    .cfi_def_cfa %rsp, 8
    ret
    .cfi_restore_state

.Lpark_overflow:
    /* 10, once a heap result finds the inline park full: publish the fill,
     * copy the remaining results out, then park results[from..produced]
     * through `park` (`mahina_hostcall_park_rest`). On its OOM, *nresults
     * stays 0 and the VM is not poisoned, as in H1. */
    mov %r8d, VM(VM_PARKED_INLINE_LEN)(%rbx)
    mov %r13, %r14
    sub %rcx, %r14
    jmp 41f
40: movzbl (%rdi), %eax
    mov (%rsi), %r11
    mov %rax, VALUE_TAG(%r9)
    mov %r11, VALUE_PAYLOAD(%r9)
41: inc %rdi
    add $8, %rsi
    add $VALUE_SIZE, %r9
    dec %rcx
    jnz 40b
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %r14, %rdx
    mov %r13, %rcx
    call SYM(mahina_hostcall_park_rest)
    test %eax, %eax
    jnz .Lreturn
    jmp .Lreport

    .cfi_endproc
FUNC_END(mahina_hostcall_entry)

    /* The offsets block this object was assembled with; every VM's creation
     * (capi.createVm) and a unit test compare it with the Zig side's
     * runtime_safety. */
    .section .rodata
    .globl SYM(mahina_hostcall_offsets_safety)
    HIDDEN(SYM(mahina_hostcall_offsets_safety))
    .type SYM(mahina_hostcall_offsets_safety), @object
    .size SYM(mahina_hostcall_offsets_safety), 1
SYM(mahina_hostcall_offsets_safety):
    .byte MAHINA_RUNTIME_SAFETY

    /* No executable stack. */
    .section .note.GNU-stack, "", @progbits
