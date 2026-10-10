// Doc 60 section 3.2: every number hostcall_x64.S depends on. Checked line by line
// at compile time against the Zig layout by src/asm/offsets_x64.zig: a wrong
// value, an unknown name, a duplicate or a missing name fails the build, and
// the error prints the corrected lines. To add a number, add it to that
// file's table first, then copy the line its error prints. The checker
// accepts only what the preprocessor and assembler read the same way: blank
// lines, // comments, the three mode directives and `.set NAME, N` in plain
// decimal, in printable ASCII, with no line ending in a backslash.
//
// Test and library builds share one layout. Runtime safety does not: std's
// hash maps carry a one-byte SafetyLock under Debug/ReleaseSafe, which
// padding makes 8 more bytes per map, and that moves
// TraceState.fast_block and the Vm fields placed after `trace`. Those names
// live in the #if MAHINA_RUNTIME_SAFETY blocks below; the build defines it
// from the optimize mode, and a build checks its own block.

// VmBox and the Vm fields the entry reads or writes.
.set VMBOX_VM, 80
.set VM_TAGS, 24
.set VM_PAYLOADS, 40
.set VM_DEPTH_SIZE, 4
.set VM_STACK_TOP, 16368
.set VM_STACK_TOP_SIZE, 8
.set VM_NEXT_CALL_SEQ, 16248
.set VM_NEXT_CALL_SEQ_SIZE, 8
.set VM_NATIVE_REENTRY_DEPTH_SIZE, 2
.set VM_FRAMES, 248
.set VM_TRACE, 16376
.set TRACE_FAST_BLOCK_SIZE, 2
.set VM_PARKED_INLINE, 96
.set VM_PARKED_INLINE_LEN_SIZE, 4
.set VM_PARKED_RESULTS, 224
.set PARKLIST_ITEMS, 0

// The safety-dependent offsets.
#if MAHINA_RUNTIME_SAFETY
.set VM_DEPTH, 27692
.set VM_NATIVE_REENTRY_DEPTH, 27700
.set TRACE_FAST_BLOCK, 6464
.set VM_PARKED_INLINE_LEN, 27696
#else
.set VM_DEPTH, 27444
.set VM_NATIVE_REENTRY_DEPTH, 27452
.set TRACE_FAST_BLOCK, 6216
.set VM_PARKED_INLINE_LEN, 27448
#endif

// Slices (Q12 (a)): {ptr, len} words. The order is checked at run time
// (verifySliceLayout: a unit test, and every capi.createVm).
.set SLICE_SIZE, 16
.set SLICE_PTR, 0
.set SLICE_LEN, 8

// CallFrame: the frame-array stride and the ten plain fields.
.set CF_SIZE, 80
.set CF_CLOSURE, 0
.set CF_CLOSURE_SIZE, 8
.set CF_CALL_SEQ, 8
.set CF_CALL_SEQ_SIZE, 8
.set CF_BASE, 16
.set CF_BASE_SIZE, 8
.set CF_PC, 24
.set CF_PC_SIZE, 8
.set CF_RET_DEST, 72
.set CF_RET_DEST_SIZE, 2
.set CF_RET_COUNT, 74
.set CF_RET_COUNT_SIZE, 2
.set CF_VARARGS_BASE, 32
.set CF_VARARGS_BASE_SIZE, 8
.set CF_VARARGS_COUNT, 40
.set CF_VARARGS_COUNT_SIZE, 8
.set CF_CODE_CACHE_GEN, 64
.set CF_CODE_CACHE_GEN_SIZE, 8
.set CF_IN_FLIGHT, 76
.set CF_IN_FLIGHT_SIZE, 1

// Closure, Proto, and the heap object header's type byte.
.set CLOSURE_PROTO, 16
.set PROTO_NUM_PARAMS, 190
.set PROTO_NUM_PARAMS_SIZE, 1
.set PROTO_NUM_REGISTERS, 188
.set PROTO_NUM_REGISTERS_SIZE, 2
.set PROTO_IS_VARARG, 191
.set PROTO_IS_VARARG_SIZE, 1
.set GCHEADER_TYPE, 0
.set GCHEADER_TYPE_SIZE, 1

// Value: two words, tag then payload, and the tag numbers used.
.set VALUE_SIZE, 16
.set VALUE_TAG, 0
.set VALUE_PAYLOAD, 8
.set TAG_NIL, 0
.set TAG_BOOLEAN, 1
.set TAG_HEAP_REF, 4
.set TAG_ROW_VIEW, 5
.set OBJ_FUNCTION, 2

// Limits and sentinels.
.set CODE_CACHE_GEN_INVALID, -1
.set MAX_CALL_DEPTH, 200
.set MAX_NATIVE_REENTRY, 200
.set PARKED_INLINE_CAP, 6
.set ARGS_MAX, 8

// FrameResult: a packed u32, reg in the low half, count in the high.
.set FRAMERESULT_SIZE, 4
.set FRAMERESULT_REG_BIT, 0
.set FRAMERESULT_COUNT_BIT, 16

// ChainResult: status, then the FrameResult, returned whole in rax.
.set CHAINRESULT_SIZE, 8
.set CHAINRESULT_STATUS, 0
.set CHAINRESULT_FRAME_RESULT, 4
.set MH_OK, 0

// Alignments the code relies on.
.set VMBOX_ALIGN, 8
.set VM_ALIGN, 8
.set CF_ALIGN, 8
.set VALUE_ALIGN, 8
