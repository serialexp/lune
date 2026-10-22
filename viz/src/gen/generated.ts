import { BitStreamEncoder, Endianness } from "./bit-stream.js";
import { SeekableBitStreamDecoder } from "./seekable-bit-stream.js";
import { createReader } from "./binary-reader.js";
import { crc32 } from "./crc32.js";
import { evaluateExpression } from "./expression-evaluator.js";
import { BinSchemaError, ErrorCode } from "./errors.js";

export interface ConstIntInput {
  /**
   * 64-bit Signed Integer
   * Fixed-width 64-bit signed integer (-9223372036854775808 to 9223372036854775807). Respects endianness configuration.
   */
  v: bigint;
}

export interface ConstIntOutput {
  /**
   * 64-bit Signed Integer
   * Fixed-width 64-bit signed integer (-9223372036854775808 to 9223372036854775807). Respects endianness configuration.
   */
  v: bigint;
}

export type ConstInt = ConstIntOutput;

export class ConstIntEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ConstIntInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeInt64(value.v, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ConstInt value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ConstInt): number {
    return 8; // v
  }
}

export class ConstIntDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ConstIntOutput {
    const value: any = {};

    value.v = this.readInt64("little_endian");
    return value;
  }
}

export interface ConstFloatInput {
  /**
   * 64-bit Floating Point
   * IEEE 754 double-precision floating point (64-bit). Provides ~15 decimal digits of precision.
   */
  v: number;
}

export interface ConstFloatOutput {
  /**
   * 64-bit Floating Point
   * IEEE 754 double-precision floating point (64-bit). Provides ~15 decimal digits of precision.
   */
  v: number;
}

export type ConstFloat = ConstFloatOutput;

export class ConstFloatEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ConstFloatInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeFloat64(value.v, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ConstFloat value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ConstFloat): number {
    return 8; // v
  }
}

export class ConstFloatDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ConstFloatOutput {
    const value: any = {};

    value.v = this.readFloat64("little_endian");
    return value;
  }
}

export interface ConstBoolInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  v: number;
}

export interface ConstBoolOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  v: number;
}

export type ConstBool = ConstBoolOutput;

export class ConstBoolEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ConstBoolInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.v);
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ConstBool value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ConstBool): number {
    return 1; // v
  }
}

export class ConstBoolDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ConstBoolOutput {
    const value: any = {};

    value.v = this.readUint8();
    return value;
  }
}

export interface ConstNilInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  pad: number;
}

export interface ConstNilOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  pad: number;
}

export type ConstNil = ConstNilOutput;

export class ConstNilEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ConstNilInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.pad);
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ConstNil value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ConstNil): number {
    return 1; // pad
  }
}

export class ConstNilDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ConstNilOutput {
    const value: any = {};

    value.pad = this.readUint8();
    return value;
  }
}

/**
 * A heap string constant: the raw bytes (mahina strings are byte strings, not necessarily UTF-8).
 */
export interface ConstStringInput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  v: number[];
}

/**
 * A heap string constant: the raw bytes (mahina strings are byte strings, not necessarily UTF-8).
 */
export interface ConstStringOutput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  v: number[];
}

export type ConstString = ConstStringOutput;

export class ConstStringEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ConstStringInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.v.length, "little_endian");
    for (let value_v__iter_index = 0; value_v__iter_index < value.v.length; value_v__iter_index++) {
      const value_v__iter = value.v[value_v__iter_index];
      this.writeUint8(value_v__iter);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ConstString value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ConstString): number {
    let size = 0;
    // v: bytes (kind: length_prefixed)
    size += value.v.length;
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class ConstStringDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ConstStringOutput {
    const value: any = {};

    value.v = [];
    const v_length = this.readUint32("little_endian");
    for (let i = 0; i < v_length; i++) {
      let v__iter: any;
      v__iter = this.readUint8();
      value.v.push(v__iter);
    }
    return value;
  }
}

/**
 * A trace constant. `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4). A heap_ref const is always a string (tables/closures are never compile-time constants).
 */
export interface ConstValueInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 5
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - ConstString (when value === 4)
   */
  body: { type: 'ConstNil'; value: ConstNilInput } | { type: 'ConstBool'; value: ConstBoolInput } | { type: 'ConstInt'; value: ConstIntInput } | { type: 'ConstFloat'; value: ConstFloatInput } | { type: 'ConstString'; value: ConstStringInput };
}

/**
 * A trace constant. `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4). A heap_ref const is always a string (tables/closures are never compile-time constants).
 */
export interface ConstValueOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 5
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - ConstString (when value === 4)
   */
  body: { type: 'ConstNil'; value: ConstNilOutput } | { type: 'ConstBool'; value: ConstBoolOutput } | { type: 'ConstInt'; value: ConstIntOutput } | { type: 'ConstFloat'; value: ConstFloatOutput } | { type: 'ConstString'; value: ConstStringOutput };
}

export type ConstValue = ConstValueOutput;

/**
 * Variant tags for ConstValue.body
 */
export const enum ConstValueBodyVariant {
  ConstNil = 'ConstNil',
  ConstBool = 'ConstBool',
  ConstInt = 'ConstInt',
  ConstFloat = 'ConstFloat',
  ConstString = 'ConstString',
}

export class ConstValueEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ConstValueInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.tag);
    if (value.body.type === 'ConstNil') {
      const encoder_value = new ConstNilEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstBool') {
      const encoder_value = new ConstBoolEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstInt') {
      const encoder_value = new ConstIntEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstFloat') {
      const encoder_value = new ConstFloatEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstString') {
      const encoder_value = new ConstStringEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type: ${(value.body as any).type}`);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ConstValue value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ConstValue): number {
    let size = 0;
    size += 1; // tag
    if (value.body.type === 'ConstNil') {
      const _enc = new ConstNilEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstBool') {
      const _enc = new ConstBoolEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstInt') {
      const _enc = new ConstIntEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstFloat') {
      const _enc = new ConstFloatEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstString') {
      const _enc = new ConstStringEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type for body: ${(value.body as any).type}`);
    }
    return size;
  }
}

export class ConstValueDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ConstValueOutput {
    const value: any = {};

    value.tag = this.readUint8();
    if (value.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstNil', value: payload };
    }
    else if (value.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstBool', value: payload };
    }
    else if (value.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstInt', value: payload };
    }
    else if (value.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.tag === 4) {
      const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstString', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.tag}`);
    }
    return value;
  }
}

/**
 * One SSA instruction: op, two operand refs, aux immediate, observed type, snapshot index, and `ord` (wire v6): the ordinal of the guest bytecode whose recording emitted it, an index into the trace's `src_by_ord` (0 = none — the entry prologue, the φ block and terminal, or a trace without the map).
 */
export interface IrInstrInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  op: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  a: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  b: number;
  /**
   * 32-bit Signed Integer
   * Fixed-width 32-bit signed integer (-2147483648 to 2147483647). Respects endianness configuration.
   */
  aux: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  ty: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  snap: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ord: number;
}

/**
 * One SSA instruction: op, two operand refs, aux immediate, observed type, snapshot index, and `ord` (wire v6): the ordinal of the guest bytecode whose recording emitted it, an index into the trace's `src_by_ord` (0 = none — the entry prologue, the φ block and terminal, or a trace without the map).
 */
export interface IrInstrOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  op: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  a: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  b: number;
  /**
   * 32-bit Signed Integer
   * Fixed-width 32-bit signed integer (-2147483648 to 2147483647). Respects endianness configuration.
   */
  aux: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  ty: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  snap: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ord: number;
}

export type IrInstr = IrInstrOutput;

export class IrInstrEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: IrInstrInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.op);
    this.writeUint16(value.a, "little_endian");
    this.writeUint16(value.b, "little_endian");
    this.writeInt32(value.aux, "little_endian");
    this.writeUint8(value.ty);
    this.writeUint32(value.snap, "little_endian");
    this.writeUint16(value.ord, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a IrInstr value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: IrInstr): number {
    return 16; // op + a + b + aux + ty + snap + ord
  }
}

export class IrInstrDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): IrInstrOutput {
    const value: any = {};

    value.op = this.readUint8();
    value.a = this.readUint16("little_endian");
    value.b = this.readUint16("little_endian");
    value.aux = this.readInt32("little_endian");
    value.ty = this.readUint8();
    value.snap = this.readUint32("little_endian");
    value.ord = this.readUint16("little_endian");
    return value;
  }
}

/**
 * A guest bytecode position: the proto's stable id and the bytecode index within it. The visualiser resolves it to a source line through the program's disassembly.
 */
export interface SourcePointInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  proto_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  pc: number;
}

/**
 * A guest bytecode position: the proto's stable id and the bytecode index within it. The visualiser resolves it to a source line through the program's disassembly.
 */
export interface SourcePointOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  proto_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  pc: number;
}

export type SourcePoint = SourcePointOutput;

export class SourcePointEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: SourcePointInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.proto_id, "little_endian");
    this.writeUint32(value.pc, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a SourcePoint value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: SourcePoint): number {
    return 8; // proto_id + pc
  }
}

export class SourcePointDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): SourcePointOutput {
    const value: any = {};

    value.proto_id = this.readUint32("little_endian");
    value.pc = this.readUint32("little_endian");
    return value;
  }
}

/**
 * A committed, cached trace. The anchor is a stable proto id (assigned at compile time) plus the loop-header pc; the in-memory *const Proto pointer is never serialized. `peeled` (doc 39, wire v3): 1 when the trace was committed from a type-stabilizing peel — its preheader run-once region is a REAL tier-0 iteration, so the first back-edge completes two iterations and a zero-completion deopt replays from the entry state. Semantic, not inferable from the marker (an LICM preheader completes zero iterations). `id` (doc 61 §7.1, wire v5): the trace's stable `Trace.id`, never reused; execution logs join to their trace by it. `src_by_ord` (wire v6): ordinal → the bytecode it stands for (entry 0 unused), so `instrs[i].ord` maps an instruction to its source; empty when the recording kept no map.
 */
export interface TraceInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  anchor_proto_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  anchor_pc: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  peeled: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  instrs: IrInstrInput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  consts: ConstValueInput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  entry_slots: number[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  src_by_ord: SourcePointInput[];
}

/**
 * A committed, cached trace. The anchor is a stable proto id (assigned at compile time) plus the loop-header pc; the in-memory *const Proto pointer is never serialized. `peeled` (doc 39, wire v3): 1 when the trace was committed from a type-stabilizing peel — its preheader run-once region is a REAL tier-0 iteration, so the first back-edge completes two iterations and a zero-completion deopt replays from the entry state. Semantic, not inferable from the marker (an LICM preheader completes zero iterations). `id` (doc 61 §7.1, wire v5): the trace's stable `Trace.id`, never reused; execution logs join to their trace by it. `src_by_ord` (wire v6): ordinal → the bytecode it stands for (entry 0 unused), so `instrs[i].ord` maps an instruction to its source; empty when the recording kept no map.
 */
export interface TraceOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  anchor_proto_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  anchor_pc: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  peeled: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  instrs: IrInstrOutput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  consts: ConstValueOutput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  entry_slots: number[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  src_by_ord: SourcePointOutput[];
}

export type Trace = TraceOutput;

export class TraceEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: TraceInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.id, "little_endian");
    this.writeUint32(value.anchor_proto_id, "little_endian");
    this.writeUint32(value.anchor_pc, "little_endian");
    this.writeUint8(value.peeled);
    this.writeUint16(value.instrs.length, "little_endian");
    for (let value_instrs__iter_index = 0; value_instrs__iter_index < value.instrs.length; value_instrs__iter_index++) {
      const value_instrs__iter = value.instrs[value_instrs__iter_index];
      const encoder_value_instrs__iter = new IrInstrEncoder();
      const encoded_value_instrs__iter = encoder_value_instrs__iter.encode(value_instrs__iter);
      for (const byte of encoded_value_instrs__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint16(value.consts.length, "little_endian");
    for (let value_consts__iter_index = 0; value_consts__iter_index < value.consts.length; value_consts__iter_index++) {
      const value_consts__iter = value.consts[value_consts__iter_index];
      const encoder_value_consts__iter = new ConstValueEncoder();
      const encoded_value_consts__iter = encoder_value_consts__iter.encode(value_consts__iter);
      for (const byte of encoded_value_consts__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint16(value.entry_slots.length, "little_endian");
    for (let value_entry_slots__iter_index = 0; value_entry_slots__iter_index < value.entry_slots.length; value_entry_slots__iter_index++) {
      const value_entry_slots__iter = value.entry_slots[value_entry_slots__iter_index];
      this.writeUint16(value_entry_slots__iter, "little_endian");
    }
    this.writeUint32(value.src_by_ord.length, "little_endian");
    for (let value_src_by_ord__iter_index = 0; value_src_by_ord__iter_index < value.src_by_ord.length; value_src_by_ord__iter_index++) {
      const value_src_by_ord__iter = value.src_by_ord[value_src_by_ord__iter_index];
      const encoder_value_src_by_ord__iter = new SourcePointEncoder();
      const encoded_value_src_by_ord__iter = encoder_value_src_by_ord__iter.encode(value_src_by_ord__iter);
      for (const byte of encoded_value_src_by_ord__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a Trace value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: Trace): number {
    let size = 0;
    size += 13; // id + anchor_proto_id + anchor_pc + peeled
    // instrs: array (kind: length_prefixed)
    for (const item of value.instrs) {
      const instrs_itemEncoder = new IrInstrEncoder();
      size += instrs_itemEncoder.calculateSize(item);
    }
    size += 2; // length prefix (uint16)
    // consts: array (kind: length_prefixed)
    for (const item of value.consts) {
      const consts_itemEncoder = new ConstValueEncoder();
      size += consts_itemEncoder.calculateSize(item);
    }
    size += 2; // length prefix (uint16)
    // entry_slots: array (kind: length_prefixed)
    for (const item of value.entry_slots) {
      size += 2;
    }
    size += 2; // length prefix (uint16)
    // src_by_ord: array (kind: length_prefixed)
    for (const item of value.src_by_ord) {
      const src_by_ord_itemEncoder = new SourcePointEncoder();
      size += src_by_ord_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class TraceDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): TraceOutput {
    const value: any = {};

    value.id = this.readUint32("little_endian");
    value.anchor_proto_id = this.readUint32("little_endian");
    value.anchor_pc = this.readUint32("little_endian");
    value.peeled = this.readUint8();
    value.instrs = [];
    const instrs_length = this.readUint16("little_endian");
    for (let i = 0; i < instrs_length; i++) {
      let instrs__iter: any;
      instrs__iter = {};
      instrs__iter.op = this.readUint8();
      instrs__iter.a = this.readUint16("little_endian");
      instrs__iter.b = this.readUint16("little_endian");
      instrs__iter.aux = this.readInt32("little_endian");
      instrs__iter.ty = this.readUint8();
      instrs__iter.snap = this.readUint32("little_endian");
      instrs__iter.ord = this.readUint16("little_endian");
      value.instrs.push(instrs__iter);
    }
    value.consts = [];
    const consts_length = this.readUint16("little_endian");
    for (let i = 0; i < consts_length; i++) {
      let consts__iter: any;
      consts__iter = {};
      consts__iter.tag = this.readUint8();
      if (consts__iter.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), consts__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        consts__iter.body = { type: 'ConstNil', value: payload };
      }
      else if (consts__iter.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), consts__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        consts__iter.body = { type: 'ConstBool', value: payload };
      }
      else if (consts__iter.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), consts__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        consts__iter.body = { type: 'ConstInt', value: payload };
      }
      else if (consts__iter.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), consts__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        consts__iter.body = { type: 'ConstFloat', value: payload };
      }
      else if (consts__iter.tag === 4) {
        const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), consts__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        consts__iter.body = { type: 'ConstString', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${consts__iter.tag}`);
      }
      value.consts.push(consts__iter);
    }
    value.entry_slots = [];
    const entry_slots_length = this.readUint16("little_endian");
    for (let i = 0; i < entry_slots_length; i++) {
      let entry_slots__iter: any;
      entry_slots__iter = this.readUint16("little_endian");
      value.entry_slots.push(entry_slots__iter);
    }
    value.src_by_ord = [];
    const src_by_ord_length = this.readUint32("little_endian");
    for (let i = 0; i < src_by_ord_length; i++) {
      let src_by_ord__iter: any;
      src_by_ord__iter = {};
      src_by_ord__iter.proto_id = this.readUint32("little_endian");
      src_by_ord__iter.pc = this.readUint32("little_endian");
      value.src_by_ord.push(src_by_ord__iter);
    }
    return value;
  }
}

/**
 * The top-level artifact: a version word followed by the whole trace cache. The richer recording header (hash seed, FP mode, env snapshot) belongs with effect-recording and is deferred to a later phase.
 */
export interface TraceFileInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  traces: TraceInput[];
}

/**
 * The top-level artifact: a version word followed by the whole trace cache. The richer recording header (hash seed, FP mode, env snapshot) belongs with effect-recording and is deferred to a later phase.
 */
export interface TraceFileOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  traces: TraceOutput[];
}

export type TraceFile = TraceFileOutput;

export class TraceFileEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: TraceFileInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.version, "little_endian");
    this.writeUint32(value.traces.length, "little_endian");
    for (let value_traces__iter_index = 0; value_traces__iter_index < value.traces.length; value_traces__iter_index++) {
      const value_traces__iter = value.traces[value_traces__iter_index];
      const encoder_value_traces__iter = new TraceEncoder();
      const encoded_value_traces__iter = encoder_value_traces__iter.encode(value_traces__iter);
      for (const byte of encoded_value_traces__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a TraceFile value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: TraceFile): number {
    let size = 0;
    size += 4; // version
    // traces: array (kind: length_prefixed)
    for (const item of value.traces) {
      const traces_itemEncoder = new TraceEncoder();
      size += traces_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class TraceFileDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): TraceFileOutput {
    const value: any = {};

    value.version = this.readUint32("little_endian");
    value.traces = [];
    const traces_length = this.readUint32("little_endian");
    for (let i = 0; i < traces_length; i++) {
      let traces__iter: any;
      traces__iter = {};
      traces__iter.id = this.readUint32("little_endian");
      traces__iter.anchor_proto_id = this.readUint32("little_endian");
      traces__iter.anchor_pc = this.readUint32("little_endian");
      traces__iter.peeled = this.readUint8();
      traces__iter.instrs = [];
      const traces__iter_instrs_length = this.readUint16("little_endian");
      for (let i = 0; i < traces__iter_instrs_length; i++) {
        let traces__iter_instrs__iter: any;
        traces__iter_instrs__iter = {};
        traces__iter_instrs__iter.op = this.readUint8();
        traces__iter_instrs__iter.a = this.readUint16("little_endian");
        traces__iter_instrs__iter.b = this.readUint16("little_endian");
        traces__iter_instrs__iter.aux = this.readInt32("little_endian");
        traces__iter_instrs__iter.ty = this.readUint8();
        traces__iter_instrs__iter.snap = this.readUint32("little_endian");
        traces__iter_instrs__iter.ord = this.readUint16("little_endian");
        traces__iter.instrs.push(traces__iter_instrs__iter);
      }
      traces__iter.consts = [];
      const traces__iter_consts_length = this.readUint16("little_endian");
      for (let i = 0; i < traces__iter_consts_length; i++) {
        let traces__iter_consts__iter: any;
        traces__iter_consts__iter = {};
        traces__iter_consts__iter.tag = this.readUint8();
        if (traces__iter_consts__iter.tag === 0) {
          const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), traces__iter_consts__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          traces__iter_consts__iter.body = { type: 'ConstNil', value: payload };
        }
        else if (traces__iter_consts__iter.tag === 1) {
          const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), traces__iter_consts__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          traces__iter_consts__iter.body = { type: 'ConstBool', value: payload };
        }
        else if (traces__iter_consts__iter.tag === 2) {
          const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), traces__iter_consts__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          traces__iter_consts__iter.body = { type: 'ConstInt', value: payload };
        }
        else if (traces__iter_consts__iter.tag === 3) {
          const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), traces__iter_consts__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          traces__iter_consts__iter.body = { type: 'ConstFloat', value: payload };
        }
        else if (traces__iter_consts__iter.tag === 4) {
          const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), traces__iter_consts__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          traces__iter_consts__iter.body = { type: 'ConstString', value: payload };
        } else {
          throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${traces__iter_consts__iter.tag}`);
        }
        traces__iter.consts.push(traces__iter_consts__iter);
      }
      traces__iter.entry_slots = [];
      const traces__iter_entry_slots_length = this.readUint16("little_endian");
      for (let i = 0; i < traces__iter_entry_slots_length; i++) {
        let traces__iter_entry_slots__iter: any;
        traces__iter_entry_slots__iter = this.readUint16("little_endian");
        traces__iter.entry_slots.push(traces__iter_entry_slots__iter);
      }
      traces__iter.src_by_ord = [];
      const traces__iter_src_by_ord_length = this.readUint32("little_endian");
      for (let i = 0; i < traces__iter_src_by_ord_length; i++) {
        let traces__iter_src_by_ord__iter: any;
        traces__iter_src_by_ord__iter = {};
        traces__iter_src_by_ord__iter.proto_id = this.readUint32("little_endian");
        traces__iter_src_by_ord__iter.pc = this.readUint32("little_endian");
        traces__iter.src_by_ord.push(traces__iter_src_by_ord__iter);
      }
      value.traces.push(traces__iter);
    }
    return value;
  }
}

/**
 * A reference to a heap object by its stable GcHeader.id (src/gc.zig). Every inter-object edge in a snapshot is one of these — never a pointer (an address would leak ASLR and break deterministic replay; docs/design/02-determinism.md).
 */
export interface HeapRefInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  id: number;
}

/**
 * A reference to a heap object by its stable GcHeader.id (src/gc.zig). Every inter-object edge in a snapshot is one of these — never a pointer (an address would leak ASLR and break deterministic replay; docs/design/02-determinism.md).
 */
export interface HeapRefOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  id: number;
}

export type HeapRef = HeapRefOutput;

export class HeapRefEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: HeapRefInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.id, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a HeapRef value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: HeapRef): number {
    return 4; // id
  }
}

export class HeapRefDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): HeapRefOutput {
    const value: any = {};

    value.id = this.readUint32("little_endian");
    return value;
  }
}

/**
 * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
 */
export interface SnapValueInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 5
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - HeapRef (when value === 4)
   */
  body: { type: 'ConstNil'; value: ConstNilInput } | { type: 'ConstBool'; value: ConstBoolInput } | { type: 'ConstInt'; value: ConstIntInput } | { type: 'ConstFloat'; value: ConstFloatInput } | { type: 'HeapRef'; value: HeapRefInput };
}

/**
 * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
 */
export interface SnapValueOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 5
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - HeapRef (when value === 4)
   */
  body: { type: 'ConstNil'; value: ConstNilOutput } | { type: 'ConstBool'; value: ConstBoolOutput } | { type: 'ConstInt'; value: ConstIntOutput } | { type: 'ConstFloat'; value: ConstFloatOutput } | { type: 'HeapRef'; value: HeapRefOutput };
}

export type SnapValue = SnapValueOutput;

/**
 * Variant tags for SnapValue.body
 */
export const enum SnapValueBodyVariant {
  ConstNil = 'ConstNil',
  ConstBool = 'ConstBool',
  ConstInt = 'ConstInt',
  ConstFloat = 'ConstFloat',
  HeapRef = 'HeapRef',
}

export class SnapValueEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: SnapValueInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.tag);
    if (value.body.type === 'ConstNil') {
      const encoder_value = new ConstNilEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstBool') {
      const encoder_value = new ConstBoolEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstInt') {
      const encoder_value = new ConstIntEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstFloat') {
      const encoder_value = new ConstFloatEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'HeapRef') {
      const encoder_value = new HeapRefEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type: ${(value.body as any).type}`);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a SnapValue value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: SnapValue): number {
    let size = 0;
    size += 1; // tag
    if (value.body.type === 'ConstNil') {
      const _enc = new ConstNilEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstBool') {
      const _enc = new ConstBoolEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstInt') {
      const _enc = new ConstIntEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstFloat') {
      const _enc = new ConstFloatEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'HeapRef') {
      const _enc = new HeapRefEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type for body: ${(value.body as any).type}`);
    }
    return size;
  }
}

export class SnapValueDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): SnapValueOutput {
    const value: any = {};

    value.tag = this.readUint8();
    if (value.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstNil', value: payload };
    }
    else if (value.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstBool', value: payload };
    }
    else if (value.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstInt', value: payload };
    }
    else if (value.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.tag === 4) {
      const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'HeapRef', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.tag}`);
    }
    return value;
  }
}

/**
 * A register tombstone (doc 61 Phase K): the slot was dead at capture, so its contents are not part of the program's state. Restore writes nil.
 */
export interface DeadSlotInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  pad: number;
}

/**
 * A register tombstone (doc 61 Phase K): the slot was dead at capture, so its contents are not part of the program's state. Restore writes nil.
 */
export interface DeadSlotOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  pad: number;
}

export type DeadSlot = DeadSlotOutput;

export class DeadSlotEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: DeadSlotInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.pad);
    return this.finish();
  }

  /**
   * Calculate the encoded size of a DeadSlot value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: DeadSlot): number {
    return 1; // pad
  }
}

export class DeadSlotDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): DeadSlotOutput {
    const value: any = {};

    value.pad = this.readUint8();
    return value;
  }
}

/**
 * One register in Keyframe.stack: a SnapValue (same tags and ordinals) or, at tag 255 (outside the Value.Tag space), a DeadSlot tombstone. Only the stack can hold a tombstone; heap edges are SnapValue.
 */
export interface StackValueInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 6
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - HeapRef (when value === 4)
   * - DeadSlot (when value === 255)
   */
  body: { type: 'ConstNil'; value: ConstNilInput } | { type: 'ConstBool'; value: ConstBoolInput } | { type: 'ConstInt'; value: ConstIntInput } | { type: 'ConstFloat'; value: ConstFloatInput } | { type: 'HeapRef'; value: HeapRefInput } | { type: 'DeadSlot'; value: DeadSlotInput };
}

/**
 * One register in Keyframe.stack: a SnapValue (same tags and ordinals) or, at tag 255 (outside the Value.Tag space), a DeadSlot tombstone. Only the stack can hold a tombstone; heap edges are SnapValue.
 */
export interface StackValueOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 6
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - HeapRef (when value === 4)
   * - DeadSlot (when value === 255)
   */
  body: { type: 'ConstNil'; value: ConstNilOutput } | { type: 'ConstBool'; value: ConstBoolOutput } | { type: 'ConstInt'; value: ConstIntOutput } | { type: 'ConstFloat'; value: ConstFloatOutput } | { type: 'HeapRef'; value: HeapRefOutput } | { type: 'DeadSlot'; value: DeadSlotOutput };
}

export type StackValue = StackValueOutput;

/**
 * Variant tags for StackValue.body
 */
export const enum StackValueBodyVariant {
  ConstNil = 'ConstNil',
  ConstBool = 'ConstBool',
  ConstInt = 'ConstInt',
  ConstFloat = 'ConstFloat',
  HeapRef = 'HeapRef',
  DeadSlot = 'DeadSlot',
}

export class StackValueEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: StackValueInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.tag);
    if (value.body.type === 'ConstNil') {
      const encoder_value = new ConstNilEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstBool') {
      const encoder_value = new ConstBoolEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstInt') {
      const encoder_value = new ConstIntEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstFloat') {
      const encoder_value = new ConstFloatEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'HeapRef') {
      const encoder_value = new HeapRefEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'DeadSlot') {
      const encoder_value = new DeadSlotEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type: ${(value.body as any).type}`);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a StackValue value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: StackValue): number {
    let size = 0;
    size += 1; // tag
    if (value.body.type === 'ConstNil') {
      const _enc = new ConstNilEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstBool') {
      const _enc = new ConstBoolEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstInt') {
      const _enc = new ConstIntEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstFloat') {
      const _enc = new ConstFloatEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'HeapRef') {
      const _enc = new HeapRefEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'DeadSlot') {
      const _enc = new DeadSlotEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type for body: ${(value.body as any).type}`);
    }
    return size;
  }
}

export class StackValueDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): StackValueOutput {
    const value: any = {};

    value.tag = this.readUint8();
    if (value.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstNil', value: payload };
    }
    else if (value.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstBool', value: payload };
    }
    else if (value.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstInt', value: payload };
    }
    else if (value.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.tag === 4) {
      const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'HeapRef', value: payload };
    }
    else if (value.tag === 255) {
      const decoder = new DeadSlotDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'DeadSlot', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.tag}`);
    }
    return value;
  }
}

/**
 * One key/value pair from a table's hash part. Array-part entries are stored positionally in HeapTable.array; everything else lands here.
 */
export interface TableEntryInput {
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  key: SnapValueInput;
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  val: SnapValueInput;
}

/**
 * One key/value pair from a table's hash part. Array-part entries are stored positionally in HeapTable.array; everything else lands here.
 */
export interface TableEntryOutput {
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  key: SnapValueOutput;
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  val: SnapValueOutput;
}

export type TableEntry = TableEntryOutput;

export class TableEntryEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: TableEntryInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    const encoder_key = new SnapValueEncoder();
    const encoded_key = encoder_key.encode(value.key);
    for (const byte of encoded_key) {
      this.writeUint8(byte);
    }
    const encoder_val = new SnapValueEncoder();
    const encoded_val = encoder_val.encode(value.val);
    for (const byte of encoded_val) {
      this.writeUint8(byte);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a TableEntry value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: TableEntry): number {
    let size = 0;
    // key: custom type (SnapValue)
    const key_encoder = new SnapValueEncoder();
    size += key_encoder.calculateSize(value.key);
    // val: custom type (SnapValue)
    const val_encoder = new SnapValueEncoder();
    size += val_encoder.calculateSize(value.val);
    return size;
  }
}

export class TableEntryDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): TableEntryOutput {
    const value: any = {};

    value.key = {};
    value.key.tag = this.readUint8();
    if (value.key.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value.key);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.key.body = { type: 'ConstNil', value: payload };
    }
    else if (value.key.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value.key);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.key.body = { type: 'ConstBool', value: payload };
    }
    else if (value.key.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value.key);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.key.body = { type: 'ConstInt', value: payload };
    }
    else if (value.key.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value.key);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.key.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.key.tag === 4) {
      const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), value.key);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.key.body = { type: 'HeapRef', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.key.tag}`);
    }
    value.val = {};
    value.val.tag = this.readUint8();
    if (value.val.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value.val);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.val.body = { type: 'ConstNil', value: payload };
    }
    else if (value.val.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value.val);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.val.body = { type: 'ConstBool', value: payload };
    }
    else if (value.val.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value.val);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.val.body = { type: 'ConstInt', value: payload };
    }
    else if (value.val.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value.val);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.val.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.val.tag === 4) {
      const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), value.val);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.val.body = { type: 'HeapRef', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.val.tag}`);
    }
    return value;
  }
}

/**
 * A heap string object's raw bytes (mahina strings are byte strings, not necessarily UTF-8). Interned at restore.
 */
export interface HeapStringInput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  bytes: number[];
}

/**
 * A heap string object's raw bytes (mahina strings are byte strings, not necessarily UTF-8). Interned at restore.
 */
export interface HeapStringOutput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  bytes: number[];
}

export type HeapString = HeapStringOutput;

export class HeapStringEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: HeapStringInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.bytes.length, "little_endian");
    for (let value_bytes__iter_index = 0; value_bytes__iter_index < value.bytes.length; value_bytes__iter_index++) {
      const value_bytes__iter = value.bytes[value_bytes__iter_index];
      this.writeUint8(value_bytes__iter);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a HeapString value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: HeapString): number {
    let size = 0;
    // bytes: bytes (kind: length_prefixed)
    size += value.bytes.length;
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class HeapStringDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): HeapStringOutput {
    const value: any = {};

    value.bytes = [];
    const bytes_length = this.readUint32("little_endian");
    for (let i = 0; i < bytes_length; i++) {
      let bytes__iter: any;
      bytes__iter = this.readUint8();
      value.bytes.push(bytes__iter);
    }
    return value;
  }
}

/**
 * A flattened grid array part (doc 14), carried as a grid (doc 61 Phase K) so restore rebuilds the same representation. `elem` is the cell lane (array.Lane ordinal, a fixed-width bitmap lane), `stride` the cells per row, `row_len[r]` row r's logical length, and `cells` the rows*stride cells row-major, nil for a hole.
 */
export interface GridPartInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  elem: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  stride: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  row_len: number[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  cells: SnapValueInput[];
}

/**
 * A flattened grid array part (doc 14), carried as a grid (doc 61 Phase K) so restore rebuilds the same representation. `elem` is the cell lane (array.Lane ordinal, a fixed-width bitmap lane), `stride` the cells per row, `row_len[r]` row r's logical length, and `cells` the rows*stride cells row-major, nil for a hole.
 */
export interface GridPartOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  elem: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  stride: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  row_len: number[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  cells: SnapValueOutput[];
}

export type GridPart = GridPartOutput;

export class GridPartEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: GridPartInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.elem);
    this.writeUint32(value.stride, "little_endian");
    this.writeUint32(value.row_len.length, "little_endian");
    for (let value_row_len__iter_index = 0; value_row_len__iter_index < value.row_len.length; value_row_len__iter_index++) {
      const value_row_len__iter = value.row_len[value_row_len__iter_index];
      this.writeUint32(value_row_len__iter, "little_endian");
    }
    this.writeUint32(value.cells.length, "little_endian");
    for (let value_cells__iter_index = 0; value_cells__iter_index < value.cells.length; value_cells__iter_index++) {
      const value_cells__iter = value.cells[value_cells__iter_index];
      const encoder_value_cells__iter = new SnapValueEncoder();
      const encoded_value_cells__iter = encoder_value_cells__iter.encode(value_cells__iter);
      for (const byte of encoded_value_cells__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a GridPart value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: GridPart): number {
    let size = 0;
    size += 5; // elem + stride
    // row_len: array (kind: length_prefixed)
    for (const item of value.row_len) {
      size += 4;
    }
    size += 4; // length prefix (uint32)
    // cells: array (kind: length_prefixed)
    for (const item of value.cells) {
      const cells_itemEncoder = new SnapValueEncoder();
      size += cells_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class GridPartDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): GridPartOutput {
    const value: any = {};

    value.elem = this.readUint8();
    value.stride = this.readUint32("little_endian");
    value.row_len = [];
    const row_len_length = this.readUint32("little_endian");
    for (let i = 0; i < row_len_length; i++) {
      let row_len__iter: any;
      row_len__iter = this.readUint32("little_endian");
      value.row_len.push(row_len__iter);
    }
    value.cells = [];
    const cells_length = this.readUint32("little_endian");
    for (let i = 0; i < cells_length; i++) {
      let cells__iter: any;
      cells__iter = {};
      cells__iter.tag = this.readUint8();
      if (cells__iter.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), cells__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        cells__iter.body = { type: 'ConstNil', value: payload };
      }
      else if (cells__iter.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), cells__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        cells__iter.body = { type: 'ConstBool', value: payload };
      }
      else if (cells__iter.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), cells__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        cells__iter.body = { type: 'ConstInt', value: payload };
      }
      else if (cells__iter.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), cells__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        cells__iter.body = { type: 'ConstFloat', value: payload };
      }
      else if (cells__iter.tag === 4) {
        const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), cells__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        cells__iter.body = { type: 'HeapRef', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${cells__iter.tag}`);
      }
      value.cells.push(cells__iter);
    }
    return value;
  }
}

/**
 * A table object: the dense array part (keys 0..asize-1, positionally — entry i IS logical key i, slot-0 hole included in-band; doc 18) plus the hash part (every other key; an array-covered integer key in the hash is invalid and rejected at restore). Edges are SnapValue heap_refs. metatable_id is the table's metatable as a 1-based optional id (header.id + 1), or 0 when it has none — id 0 IS a live object (the first allocation gets id 0), so a bare id cannot be the none sentinel. The array part's representation rides along (doc 61 Phase K), because it decides later grid inflation and so later allocations: `lane` is its array.Lane ordinal, `flags` bit 0 is `frozen` and bit 1 the table's `no_grid`. A grid (lane = grid) has an empty `array` and exactly one `grid` entry; any other lane has none. `rehash_threshold` is the hash population at which the next new integer key re-splits array and hash (Table.rehash). It depends on the table's history and decides where later keys land, which `#t` and `next` can observe, so it is carried rather than recomputed; it is always at least 4.
 */
export interface HeapTableInput {
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  array: SnapValueInput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  entries: TableEntryInput[];
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  metatable_id: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  lane: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  flags: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  rehash_threshold: bigint;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint8
   */
  grid: GridPartInput[];
}

/**
 * A table object: the dense array part (keys 0..asize-1, positionally — entry i IS logical key i, slot-0 hole included in-band; doc 18) plus the hash part (every other key; an array-covered integer key in the hash is invalid and rejected at restore). Edges are SnapValue heap_refs. metatable_id is the table's metatable as a 1-based optional id (header.id + 1), or 0 when it has none — id 0 IS a live object (the first allocation gets id 0), so a bare id cannot be the none sentinel. The array part's representation rides along (doc 61 Phase K), because it decides later grid inflation and so later allocations: `lane` is its array.Lane ordinal, `flags` bit 0 is `frozen` and bit 1 the table's `no_grid`. A grid (lane = grid) has an empty `array` and exactly one `grid` entry; any other lane has none. `rehash_threshold` is the hash population at which the next new integer key re-splits array and hash (Table.rehash). It depends on the table's history and decides where later keys land, which `#t` and `next` can observe, so it is carried rather than recomputed; it is always at least 4.
 */
export interface HeapTableOutput {
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  array: SnapValueOutput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  entries: TableEntryOutput[];
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  metatable_id: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  lane: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  flags: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  rehash_threshold: bigint;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint8
   */
  grid: GridPartOutput[];
}

export type HeapTable = HeapTableOutput;

export class HeapTableEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: HeapTableInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.array.length, "little_endian");
    for (let value_array__iter_index = 0; value_array__iter_index < value.array.length; value_array__iter_index++) {
      const value_array__iter = value.array[value_array__iter_index];
      const encoder_value_array__iter = new SnapValueEncoder();
      const encoded_value_array__iter = encoder_value_array__iter.encode(value_array__iter);
      for (const byte of encoded_value_array__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint32(value.entries.length, "little_endian");
    for (let value_entries__iter_index = 0; value_entries__iter_index < value.entries.length; value_entries__iter_index++) {
      const value_entries__iter = value.entries[value_entries__iter_index];
      const encoder_value_entries__iter = new TableEntryEncoder();
      const encoded_value_entries__iter = encoder_value_entries__iter.encode(value_entries__iter);
      for (const byte of encoded_value_entries__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint32(value.metatable_id, "little_endian");
    this.writeUint8(value.lane);
    this.writeUint8(value.flags);
    this.writeUint64(value.rehash_threshold, "little_endian");
    this.writeUint8(value.grid.length);
    for (let value_grid__iter_index = 0; value_grid__iter_index < value.grid.length; value_grid__iter_index++) {
      const value_grid__iter = value.grid[value_grid__iter_index];
      const encoder_value_grid__iter = new GridPartEncoder();
      const encoded_value_grid__iter = encoder_value_grid__iter.encode(value_grid__iter);
      for (const byte of encoded_value_grid__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a HeapTable value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: HeapTable): number {
    let size = 0;
    // array: array (kind: length_prefixed)
    for (const item of value.array) {
      const array_itemEncoder = new SnapValueEncoder();
      size += array_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    // entries: array (kind: length_prefixed)
    for (const item of value.entries) {
      const entries_itemEncoder = new TableEntryEncoder();
      size += entries_itemEncoder.calculateSize(item);
    }
    size += 18; // length prefix (uint32) + metatable_id + lane + flags + rehash_threshold
    // grid: array (kind: length_prefixed)
    for (const item of value.grid) {
      const grid_itemEncoder = new GridPartEncoder();
      size += grid_itemEncoder.calculateSize(item);
    }
    size += 1; // length prefix (uint8)
    return size;
  }
}

export class HeapTableDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): HeapTableOutput {
    const value: any = {};

    value.array = [];
    const array_length = this.readUint32("little_endian");
    for (let i = 0; i < array_length; i++) {
      let array__iter: any;
      array__iter = {};
      array__iter.tag = this.readUint8();
      if (array__iter.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), array__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        array__iter.body = { type: 'ConstNil', value: payload };
      }
      else if (array__iter.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), array__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        array__iter.body = { type: 'ConstBool', value: payload };
      }
      else if (array__iter.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), array__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        array__iter.body = { type: 'ConstInt', value: payload };
      }
      else if (array__iter.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), array__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        array__iter.body = { type: 'ConstFloat', value: payload };
      }
      else if (array__iter.tag === 4) {
        const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), array__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        array__iter.body = { type: 'HeapRef', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${array__iter.tag}`);
      }
      value.array.push(array__iter);
    }
    value.entries = [];
    const entries_length = this.readUint32("little_endian");
    for (let i = 0; i < entries_length; i++) {
      let entries__iter: any;
      entries__iter = {};
      entries__iter.key = {};
      entries__iter.key.tag = this.readUint8();
      if (entries__iter.key.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), entries__iter.key);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.key.body = { type: 'ConstNil', value: payload };
      }
      else if (entries__iter.key.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), entries__iter.key);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.key.body = { type: 'ConstBool', value: payload };
      }
      else if (entries__iter.key.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), entries__iter.key);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.key.body = { type: 'ConstInt', value: payload };
      }
      else if (entries__iter.key.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), entries__iter.key);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.key.body = { type: 'ConstFloat', value: payload };
      }
      else if (entries__iter.key.tag === 4) {
        const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), entries__iter.key);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.key.body = { type: 'HeapRef', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${entries__iter.key.tag}`);
      }
      entries__iter.val = {};
      entries__iter.val.tag = this.readUint8();
      if (entries__iter.val.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), entries__iter.val);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.val.body = { type: 'ConstNil', value: payload };
      }
      else if (entries__iter.val.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), entries__iter.val);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.val.body = { type: 'ConstBool', value: payload };
      }
      else if (entries__iter.val.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), entries__iter.val);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.val.body = { type: 'ConstInt', value: payload };
      }
      else if (entries__iter.val.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), entries__iter.val);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.val.body = { type: 'ConstFloat', value: payload };
      }
      else if (entries__iter.val.tag === 4) {
        const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), entries__iter.val);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        entries__iter.val.body = { type: 'HeapRef', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${entries__iter.val.tag}`);
      }
      value.entries.push(entries__iter);
    }
    value.metatable_id = this.readUint32("little_endian");
    value.lane = this.readUint8();
    value.flags = this.readUint8();
    value.rehash_threshold = this.readUint64("little_endian");
    value.grid = [];
    const grid_length = this.readUint8();
    for (let i = 0; i < grid_length; i++) {
      let grid__iter: any;
      grid__iter = {};
      grid__iter.elem = this.readUint8();
      grid__iter.stride = this.readUint32("little_endian");
      grid__iter.row_len = [];
      const grid__iter_row_len_length = this.readUint32("little_endian");
      for (let i = 0; i < grid__iter_row_len_length; i++) {
        let grid__iter_row_len__iter: any;
        grid__iter_row_len__iter = this.readUint32("little_endian");
        grid__iter.row_len.push(grid__iter_row_len__iter);
      }
      grid__iter.cells = [];
      const grid__iter_cells_length = this.readUint32("little_endian");
      for (let i = 0; i < grid__iter_cells_length; i++) {
        let grid__iter_cells__iter: any;
        grid__iter_cells__iter = {};
        grid__iter_cells__iter.tag = this.readUint8();
        if (grid__iter_cells__iter.tag === 0) {
          const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), grid__iter_cells__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          grid__iter_cells__iter.body = { type: 'ConstNil', value: payload };
        }
        else if (grid__iter_cells__iter.tag === 1) {
          const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), grid__iter_cells__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          grid__iter_cells__iter.body = { type: 'ConstBool', value: payload };
        }
        else if (grid__iter_cells__iter.tag === 2) {
          const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), grid__iter_cells__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          grid__iter_cells__iter.body = { type: 'ConstInt', value: payload };
        }
        else if (grid__iter_cells__iter.tag === 3) {
          const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), grid__iter_cells__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          grid__iter_cells__iter.body = { type: 'ConstFloat', value: payload };
        }
        else if (grid__iter_cells__iter.tag === 4) {
          const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), grid__iter_cells__iter);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          grid__iter_cells__iter.body = { type: 'HeapRef', value: payload };
        } else {
          throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${grid__iter_cells__iter.tag}`);
        }
        grid__iter.cells.push(grid__iter_cells__iter);
      }
      value.grid.push(grid__iter);
    }
    return value;
  }
}

/**
 * A closure: a stable proto id (rebound from the program image at restore, never serialized inline — same stance as a trace anchor) plus the ids of its captured upvalue cells.
 */
export interface HeapClosureInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  proto_id: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  upvalue_ids: number[];
}

/**
 * A closure: a stable proto id (rebound from the program image at restore, never serialized inline — same stance as a trace anchor) plus the ids of its captured upvalue cells.
 */
export interface HeapClosureOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  proto_id: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  upvalue_ids: number[];
}

export type HeapClosure = HeapClosureOutput;

export class HeapClosureEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: HeapClosureInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.proto_id, "little_endian");
    this.writeUint16(value.upvalue_ids.length, "little_endian");
    for (let value_upvalue_ids__iter_index = 0; value_upvalue_ids__iter_index < value.upvalue_ids.length; value_upvalue_ids__iter_index++) {
      const value_upvalue_ids__iter = value.upvalue_ids[value_upvalue_ids__iter_index];
      this.writeUint32(value_upvalue_ids__iter, "little_endian");
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a HeapClosure value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: HeapClosure): number {
    let size = 0;
    size += 4; // proto_id
    // upvalue_ids: array (kind: length_prefixed)
    for (const item of value.upvalue_ids) {
      size += 4;
    }
    size += 2; // length prefix (uint16)
    return size;
  }
}

export class HeapClosureDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): HeapClosureOutput {
    const value: any = {};

    value.proto_id = this.readUint32("little_endian");
    value.upvalue_ids = [];
    const upvalue_ids_length = this.readUint16("little_endian");
    for (let i = 0; i < upvalue_ids_length; i++) {
      let upvalue_ids__iter: any;
      upvalue_ids__iter = this.readUint32("little_endian");
      value.upvalue_ids.push(upvalue_ids__iter);
    }
    return value;
  }
}

/**
 * A captured-variable cell. closed=1: `value` is the held value. closed=0 (open): `value` is the CURRENT contents of the stack slot at capture; restore re-derives the live slot from the saved stack window + Keyframe.open_upvalues (F2b).
 */
export interface HeapUpvalueInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  closed: number;
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  value: SnapValueInput;
}

/**
 * A captured-variable cell. closed=1: `value` is the held value. closed=0 (open): `value` is the CURRENT contents of the stack slot at capture; restore re-derives the live slot from the saved stack window + Keyframe.open_upvalues (F2b).
 */
export interface HeapUpvalueOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  closed: number;
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors mahina's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  value: SnapValueOutput;
}

export type HeapUpvalue = HeapUpvalueOutput;

export class HeapUpvalueEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: HeapUpvalueInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.closed);
    const encoder_value = new SnapValueEncoder();
    const encoded_value = encoder_value.encode(value.value);
    for (const byte of encoded_value) {
      this.writeUint8(byte);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a HeapUpvalue value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: HeapUpvalue): number {
    let size = 0;
    size += 1; // closed
    // value: custom type (SnapValue)
    const value_encoder = new SnapValueEncoder();
    size += value_encoder.calculateSize(value.value);
    return size;
  }
}

export class HeapUpvalueDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): HeapUpvalueOutput {
    const value: any = {};

    value.closed = this.readUint8();
    value.value = {};
    value.value.tag = this.readUint8();
    if (value.value.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstNil', value: payload };
    }
    else if (value.value.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstBool', value: payload };
    }
    else if (value.value.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstInt', value: payload };
    }
    else if (value.value.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.value.tag === 4) {
      const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'HeapRef', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.value.tag}`);
    }
    return value;
  }
}

/**
 * A native (host/builtin) function, identified by name. Rebound to the installed base library by name at restore (the function pointer is meaningless on disk), so only the name is serialized.
 */
export interface HeapNativeInput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  name: number[];
}

/**
 * A native (host/builtin) function, identified by name. Rebound to the installed base library by name at restore (the function pointer is meaningless on disk), so only the name is serialized.
 */
export interface HeapNativeOutput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  name: number[];
}

export type HeapNative = HeapNativeOutput;

export class HeapNativeEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: HeapNativeInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.name.length, "little_endian");
    for (let value_name__iter_index = 0; value_name__iter_index < value.name.length; value_name__iter_index++) {
      const value_name__iter = value.name[value_name__iter_index];
      this.writeUint8(value_name__iter);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a HeapNative value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: HeapNative): number {
    let size = 0;
    // name: bytes (kind: length_prefixed)
    size += value.name.length;
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class HeapNativeDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): HeapNativeOutput {
    const value: any = {};

    value.name = [];
    const name_length = this.readUint32("little_endian");
    for (let i = 0; i < name_length; i++) {
      let name__iter: any;
      name__iter = this.readUint8();
      value.name.push(name__iter);
    }
    return value;
  }
}

/**
 * One heap object in a snapshot, tagged by `obj_type` (mirrors object.ObjectType: string=0, table=1, function=2, native=3, upvalue=4). `id` is the object's stable GcHeader.id and the key every HeapRef points at. typed_array(5)/host(6) have no variant yet — emitting one is a serializer bug (UnsupportedObject), not a silent drop.
 */
export interface HeapObjectInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  id: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  obj_type: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'obj_type'
   * Variants: 5
   * - HeapString (when value === 0)
   * - HeapTable (when value === 1)
   * - HeapClosure (when value === 2)
   * - HeapNative (when value === 3)
   * - HeapUpvalue (when value === 4)
   */
  body: { type: 'HeapString'; value: HeapStringInput } | { type: 'HeapTable'; value: HeapTableInput } | { type: 'HeapClosure'; value: HeapClosureInput } | { type: 'HeapNative'; value: HeapNativeInput } | { type: 'HeapUpvalue'; value: HeapUpvalueInput };
}

/**
 * One heap object in a snapshot, tagged by `obj_type` (mirrors object.ObjectType: string=0, table=1, function=2, native=3, upvalue=4). `id` is the object's stable GcHeader.id and the key every HeapRef points at. typed_array(5)/host(6) have no variant yet — emitting one is a serializer bug (UnsupportedObject), not a silent drop.
 */
export interface HeapObjectOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  id: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  obj_type: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'obj_type'
   * Variants: 5
   * - HeapString (when value === 0)
   * - HeapTable (when value === 1)
   * - HeapClosure (when value === 2)
   * - HeapNative (when value === 3)
   * - HeapUpvalue (when value === 4)
   */
  body: { type: 'HeapString'; value: HeapStringOutput } | { type: 'HeapTable'; value: HeapTableOutput } | { type: 'HeapClosure'; value: HeapClosureOutput } | { type: 'HeapNative'; value: HeapNativeOutput } | { type: 'HeapUpvalue'; value: HeapUpvalueOutput };
}

export type HeapObject = HeapObjectOutput;

/**
 * Variant tags for HeapObject.body
 */
export const enum HeapObjectBodyVariant {
  HeapString = 'HeapString',
  HeapTable = 'HeapTable',
  HeapClosure = 'HeapClosure',
  HeapNative = 'HeapNative',
  HeapUpvalue = 'HeapUpvalue',
}

export class HeapObjectEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: HeapObjectInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.id, "little_endian");
    this.writeUint8(value.obj_type);
    if (value.body.type === 'HeapString') {
      const encoder_value = new HeapStringEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'HeapTable') {
      const encoder_value = new HeapTableEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'HeapClosure') {
      const encoder_value = new HeapClosureEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'HeapNative') {
      const encoder_value = new HeapNativeEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'HeapUpvalue') {
      const encoder_value = new HeapUpvalueEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type: ${(value.body as any).type}`);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a HeapObject value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: HeapObject): number {
    let size = 0;
    size += 5; // id + obj_type
    if (value.body.type === 'HeapString') {
      const _enc = new HeapStringEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'HeapTable') {
      const _enc = new HeapTableEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'HeapClosure') {
      const _enc = new HeapClosureEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'HeapNative') {
      const _enc = new HeapNativeEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'HeapUpvalue') {
      const _enc = new HeapUpvalueEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type for body: ${(value.body as any).type}`);
    }
    return size;
  }
}

export class HeapObjectDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): HeapObjectOutput {
    const value: any = {};

    value.id = this.readUint32("little_endian");
    value.obj_type = this.readUint8();
    if (value.obj_type === 0) {
      const decoder = new HeapStringDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'HeapString', value: payload };
    }
    else if (value.obj_type === 1) {
      const decoder = new HeapTableDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'HeapTable', value: payload };
    }
    else if (value.obj_type === 2) {
      const decoder = new HeapClosureDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'HeapClosure', value: payload };
    }
    else if (value.obj_type === 3) {
      const decoder = new HeapNativeDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'HeapNative', value: payload };
    }
    else if (value.obj_type === 4) {
      const decoder = new HeapUpvalueDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'HeapUpvalue', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.obj_type}`);
    }
    return value;
  }
}

/**
 * An open upvalue's binding: the absolute stack index its cell points at, and the cell's object id. Lets restore re-point the cell into the rebuilt stack window. F2a (final-state capture) emits none; load-bearing in F2b.
 */
export interface OpenUpvalueRefInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  stack_index: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  upvalue_id: number;
}

/**
 * An open upvalue's binding: the absolute stack index its cell points at, and the cell's object id. Lets restore re-point the cell into the rebuilt stack window. F2a (final-state capture) emits none; load-bearing in F2b.
 */
export interface OpenUpvalueRefOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  stack_index: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  upvalue_id: number;
}

export type OpenUpvalueRef = OpenUpvalueRefOutput;

export class OpenUpvalueRefEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: OpenUpvalueRefInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.stack_index, "little_endian");
    this.writeUint32(value.upvalue_id, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a OpenUpvalueRef value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: OpenUpvalueRef): number {
    return 8; // stack_index + upvalue_id
  }
}

export class OpenUpvalueRefDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): OpenUpvalueRefOutput {
    const value: any = {};

    value.stack_index = this.readUint32("little_endian");
    value.upvalue_id = this.readUint32("little_endian");
    return value;
  }
}

/**
 * One active call frame, with the execution cursor needed to RESUME it mid-execution (F2c): the executing closure's id, the resumable program counter, the register-window base on the shared stack, the return-wiring (where this frame's results land in its parent, and how many the parent wants), the live vararg cursor, and the frame's control byte (`interp.FrameCtl`: v11 sets only `protect`, the tag of a function a `pcall`/`xpcall` protects, doc 68 §5). Windows stack contiguously: frames[i+1].base == frames[i].base + frames[i].closure.proto.num_registers. A non-empty vararg range lies below its frame base inside the live stack prefix; an empty range is encoded as base/count zero. The bottom (main) frame leaves ret_dest/ret_count unused.
 */
export interface FrameRefInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  closure_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  pc: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  base: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ret_dest: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ret_count: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  varargs_base: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  varargs_count: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  ctl: number;
}

/**
 * One active call frame, with the execution cursor needed to RESUME it mid-execution (F2c): the executing closure's id, the resumable program counter, the register-window base on the shared stack, the return-wiring (where this frame's results land in its parent, and how many the parent wants), the live vararg cursor, and the frame's control byte (`interp.FrameCtl`: v11 sets only `protect`, the tag of a function a `pcall`/`xpcall` protects, doc 68 §5). Windows stack contiguously: frames[i+1].base == frames[i].base + frames[i].closure.proto.num_registers. A non-empty vararg range lies below its frame base inside the live stack prefix; an empty range is encoded as base/count zero. The bottom (main) frame leaves ret_dest/ret_count unused.
 */
export interface FrameRefOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  closure_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  pc: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  base: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ret_dest: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ret_count: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  varargs_base: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  varargs_count: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  ctl: number;
}

export type FrameRef = FrameRefOutput;

export class FrameRefEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: FrameRefInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.closure_id, "little_endian");
    this.writeUint32(value.pc, "little_endian");
    this.writeUint32(value.base, "little_endian");
    this.writeUint16(value.ret_dest, "little_endian");
    this.writeUint16(value.ret_count, "little_endian");
    this.writeUint32(value.varargs_base, "little_endian");
    this.writeUint32(value.varargs_count, "little_endian");
    this.writeUint8(value.ctl);
    return this.finish();
  }

  /**
   * Calculate the encoded size of a FrameRef value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: FrameRef): number {
    return 25; // closure_id + pc + base + ret_dest + ret_count + varargs_base + varargs_count + ctl
  }
}

export class FrameRefDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): FrameRefOutput {
    const value: any = {};

    value.closure_id = this.readUint32("little_endian");
    value.pc = this.readUint32("little_endian");
    value.base = this.readUint32("little_endian");
    value.ret_dest = this.readUint16("little_endian");
    value.ret_count = this.readUint16("little_endian");
    value.varargs_base = this.readUint32("little_endian");
    value.varargs_count = this.readUint32("little_endian");
    value.ctl = this.readUint8();
    return value;
  }
}

/**
 * One runtime-`load`ed chunk's recompile inputs (L-2): its source text and the chunk name it was loaded under. Restore re-parses + re-compiles `source` (compile is deterministic) and renames the root proto to `name`, so a live `load` closure — and any post-restore fault it raises — is byte-identical to the pre-snapshot VM.
 */
export interface LoadedChunkInput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  source: number[];
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  name: number[];
}

/**
 * One runtime-`load`ed chunk's recompile inputs (L-2): its source text and the chunk name it was loaded under. Restore re-parses + re-compiles `source` (compile is deterministic) and renames the root proto to `name`, so a live `load` closure — and any post-restore fault it raises — is byte-identical to the pre-snapshot VM.
 */
export interface LoadedChunkOutput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  source: number[];
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  name: number[];
}

export type LoadedChunk = LoadedChunkOutput;

export class LoadedChunkEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: LoadedChunkInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.source.length, "little_endian");
    for (let value_source__iter_index = 0; value_source__iter_index < value.source.length; value_source__iter_index++) {
      const value_source__iter = value.source[value_source__iter_index];
      this.writeUint8(value_source__iter);
    }
    this.writeUint32(value.name.length, "little_endian");
    for (let value_name__iter_index = 0; value_name__iter_index < value.name.length; value_name__iter_index++) {
      const value_name__iter = value.name[value_name__iter_index];
      this.writeUint8(value_name__iter);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a LoadedChunk value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: LoadedChunk): number {
    let size = 0;
    // source: bytes (kind: length_prefixed)
    size += value.source.length;
    size += 4; // length prefix (uint32)
    // name: bytes (kind: length_prefixed)
    size += value.name.length;
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class LoadedChunkDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): LoadedChunkOutput {
    const value: any = {};

    value.source = [];
    const source_length = this.readUint32("little_endian");
    for (let i = 0; i < source_length; i++) {
      let source__iter: any;
      source__iter = this.readUint8();
      value.source.push(source__iter);
    }
    value.name = [];
    const name_length = this.readUint32("little_endian");
    for (let i = 0; i < name_length; i++) {
      let name__iter: any;
      name__iter = this.readUint8();
      value.name.push(name__iter);
    }
    return value;
  }
}

/**
 * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of EVERY unswept object, in ascending id order (doc 61 Phase K: garbage included, so a restored VM gets the same intern hits and collection points); roots are the globals table id, the shared string-metatable id (1-based optional id: header.id + 1, or 0 = none), the live register window (a slot dead at capture is a DeadSlot tombstone), the active frame closures, and the open upvalues. `next_gc` is the heap's collection threshold (live-object count that triggers the next collection). F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture. `next_obj_id` is the heap's monotonic allocation counter (the next `GcHeader.id` to hand out): serialized so restore reproduces the id timeline EXACTLY even when objects were allocated and swept before the cut (a swept object bumped the counter but leaves no entry in `objects`, so reconstructing the counter as max(id)+1 would drift it low and diverge subsequent ids — which are observable via table/pairs ordering). `loaded_chunks` (L-2) carries every runtime-`load`ed chunk's source + name in load order: restore RE-COMPILES each (compile is deterministic) to regenerate identical protos/ids, so a live `load` closure survives snapshot→restore without serializing bytecode.
 */
export interface KeyframeInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  globals_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  string_metatable_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  next_obj_id: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  next_gc: bigint;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  objects: HeapObjectInput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  stack: StackValueInput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  frames: FrameRefInput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  open_upvalues: OpenUpvalueRefInput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  loaded_chunks: LoadedChunkInput[];
}

/**
 * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of EVERY unswept object, in ascending id order (doc 61 Phase K: garbage included, so a restored VM gets the same intern hits and collection points); roots are the globals table id, the shared string-metatable id (1-based optional id: header.id + 1, or 0 = none), the live register window (a slot dead at capture is a DeadSlot tombstone), the active frame closures, and the open upvalues. `next_gc` is the heap's collection threshold (live-object count that triggers the next collection). F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture. `next_obj_id` is the heap's monotonic allocation counter (the next `GcHeader.id` to hand out): serialized so restore reproduces the id timeline EXACTLY even when objects were allocated and swept before the cut (a swept object bumped the counter but leaves no entry in `objects`, so reconstructing the counter as max(id)+1 would drift it low and diverge subsequent ids — which are observable via table/pairs ordering). `loaded_chunks` (L-2) carries every runtime-`load`ed chunk's source + name in load order: restore RE-COMPILES each (compile is deterministic) to regenerate identical protos/ids, so a live `load` closure survives snapshot→restore without serializing bytecode.
 */
export interface KeyframeOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  globals_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  string_metatable_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  next_obj_id: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  next_gc: bigint;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  objects: HeapObjectOutput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  stack: StackValueOutput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  frames: FrameRefOutput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint16
   */
  open_upvalues: OpenUpvalueRefOutput[];
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  loaded_chunks: LoadedChunkOutput[];
}

export type Keyframe = KeyframeOutput;

export class KeyframeEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: KeyframeInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.globals_id, "little_endian");
    this.writeUint32(value.string_metatable_id, "little_endian");
    this.writeUint32(value.next_obj_id, "little_endian");
    this.writeUint64(value.next_gc, "little_endian");
    this.writeUint32(value.objects.length, "little_endian");
    for (let value_objects__iter_index = 0; value_objects__iter_index < value.objects.length; value_objects__iter_index++) {
      const value_objects__iter = value.objects[value_objects__iter_index];
      const encoder_value_objects__iter = new HeapObjectEncoder();
      const encoded_value_objects__iter = encoder_value_objects__iter.encode(value_objects__iter);
      for (const byte of encoded_value_objects__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint32(value.stack.length, "little_endian");
    for (let value_stack__iter_index = 0; value_stack__iter_index < value.stack.length; value_stack__iter_index++) {
      const value_stack__iter = value.stack[value_stack__iter_index];
      const encoder_value_stack__iter = new StackValueEncoder();
      const encoded_value_stack__iter = encoder_value_stack__iter.encode(value_stack__iter);
      for (const byte of encoded_value_stack__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint16(value.frames.length, "little_endian");
    for (let value_frames__iter_index = 0; value_frames__iter_index < value.frames.length; value_frames__iter_index++) {
      const value_frames__iter = value.frames[value_frames__iter_index];
      const encoder_value_frames__iter = new FrameRefEncoder();
      const encoded_value_frames__iter = encoder_value_frames__iter.encode(value_frames__iter);
      for (const byte of encoded_value_frames__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint16(value.open_upvalues.length, "little_endian");
    for (let value_open_upvalues__iter_index = 0; value_open_upvalues__iter_index < value.open_upvalues.length; value_open_upvalues__iter_index++) {
      const value_open_upvalues__iter = value.open_upvalues[value_open_upvalues__iter_index];
      const encoder_value_open_upvalues__iter = new OpenUpvalueRefEncoder();
      const encoded_value_open_upvalues__iter = encoder_value_open_upvalues__iter.encode(value_open_upvalues__iter);
      for (const byte of encoded_value_open_upvalues__iter) {
        this.writeUint8(byte);
      }
    }
    this.writeUint32(value.loaded_chunks.length, "little_endian");
    for (let value_loaded_chunks__iter_index = 0; value_loaded_chunks__iter_index < value.loaded_chunks.length; value_loaded_chunks__iter_index++) {
      const value_loaded_chunks__iter = value.loaded_chunks[value_loaded_chunks__iter_index];
      const encoder_value_loaded_chunks__iter = new LoadedChunkEncoder();
      const encoded_value_loaded_chunks__iter = encoder_value_loaded_chunks__iter.encode(value_loaded_chunks__iter);
      for (const byte of encoded_value_loaded_chunks__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a Keyframe value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: Keyframe): number {
    let size = 0;
    size += 20; // globals_id + string_metatable_id + next_obj_id + next_gc
    // objects: array (kind: length_prefixed)
    for (const item of value.objects) {
      const objects_itemEncoder = new HeapObjectEncoder();
      size += objects_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    // stack: array (kind: length_prefixed)
    for (const item of value.stack) {
      const stack_itemEncoder = new StackValueEncoder();
      size += stack_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    // frames: array (kind: length_prefixed)
    for (const item of value.frames) {
      const frames_itemEncoder = new FrameRefEncoder();
      size += frames_itemEncoder.calculateSize(item);
    }
    size += 2; // length prefix (uint16)
    // open_upvalues: array (kind: length_prefixed)
    for (const item of value.open_upvalues) {
      const open_upvalues_itemEncoder = new OpenUpvalueRefEncoder();
      size += open_upvalues_itemEncoder.calculateSize(item);
    }
    size += 2; // length prefix (uint16)
    // loaded_chunks: array (kind: length_prefixed)
    for (const item of value.loaded_chunks) {
      const loaded_chunks_itemEncoder = new LoadedChunkEncoder();
      size += loaded_chunks_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class KeyframeDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): KeyframeOutput {
    const value: any = {};

    value.globals_id = this.readUint32("little_endian");
    value.string_metatable_id = this.readUint32("little_endian");
    value.next_obj_id = this.readUint32("little_endian");
    value.next_gc = this.readUint64("little_endian");
    value.objects = [];
    const objects_length = this.readUint32("little_endian");
    for (let i = 0; i < objects_length; i++) {
      let objects__iter: any;
      objects__iter = {};
      objects__iter.id = this.readUint32("little_endian");
      objects__iter.obj_type = this.readUint8();
      if (objects__iter.obj_type === 0) {
        const decoder = new HeapStringDecoder(this.bytes.slice(this.byteOffset), objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        objects__iter.body = { type: 'HeapString', value: payload };
      }
      else if (objects__iter.obj_type === 1) {
        const decoder = new HeapTableDecoder(this.bytes.slice(this.byteOffset), objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        objects__iter.body = { type: 'HeapTable', value: payload };
      }
      else if (objects__iter.obj_type === 2) {
        const decoder = new HeapClosureDecoder(this.bytes.slice(this.byteOffset), objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        objects__iter.body = { type: 'HeapClosure', value: payload };
      }
      else if (objects__iter.obj_type === 3) {
        const decoder = new HeapNativeDecoder(this.bytes.slice(this.byteOffset), objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        objects__iter.body = { type: 'HeapNative', value: payload };
      }
      else if (objects__iter.obj_type === 4) {
        const decoder = new HeapUpvalueDecoder(this.bytes.slice(this.byteOffset), objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        objects__iter.body = { type: 'HeapUpvalue', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${objects__iter.obj_type}`);
      }
      value.objects.push(objects__iter);
    }
    value.stack = [];
    const stack_length = this.readUint32("little_endian");
    for (let i = 0; i < stack_length; i++) {
      let stack__iter: any;
      stack__iter = {};
      stack__iter.tag = this.readUint8();
      if (stack__iter.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        stack__iter.body = { type: 'ConstNil', value: payload };
      }
      else if (stack__iter.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        stack__iter.body = { type: 'ConstBool', value: payload };
      }
      else if (stack__iter.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        stack__iter.body = { type: 'ConstInt', value: payload };
      }
      else if (stack__iter.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        stack__iter.body = { type: 'ConstFloat', value: payload };
      }
      else if (stack__iter.tag === 4) {
        const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        stack__iter.body = { type: 'HeapRef', value: payload };
      }
      else if (stack__iter.tag === 255) {
        const decoder = new DeadSlotDecoder(this.bytes.slice(this.byteOffset), stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        stack__iter.body = { type: 'DeadSlot', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${stack__iter.tag}`);
      }
      value.stack.push(stack__iter);
    }
    value.frames = [];
    const frames_length = this.readUint16("little_endian");
    for (let i = 0; i < frames_length; i++) {
      let frames__iter: any;
      frames__iter = {};
      frames__iter.closure_id = this.readUint32("little_endian");
      frames__iter.pc = this.readUint32("little_endian");
      frames__iter.base = this.readUint32("little_endian");
      frames__iter.ret_dest = this.readUint16("little_endian");
      frames__iter.ret_count = this.readUint16("little_endian");
      frames__iter.varargs_base = this.readUint32("little_endian");
      frames__iter.varargs_count = this.readUint32("little_endian");
      frames__iter.ctl = this.readUint8();
      value.frames.push(frames__iter);
    }
    value.open_upvalues = [];
    const open_upvalues_length = this.readUint16("little_endian");
    for (let i = 0; i < open_upvalues_length; i++) {
      let open_upvalues__iter: any;
      open_upvalues__iter = {};
      open_upvalues__iter.stack_index = this.readUint32("little_endian");
      open_upvalues__iter.upvalue_id = this.readUint32("little_endian");
      value.open_upvalues.push(open_upvalues__iter);
    }
    value.loaded_chunks = [];
    const loaded_chunks_length = this.readUint32("little_endian");
    for (let i = 0; i < loaded_chunks_length; i++) {
      let loaded_chunks__iter: any;
      loaded_chunks__iter = {};
      loaded_chunks__iter.source = [];
      const loaded_chunks__iter_source_length = this.readUint32("little_endian");
      for (let i = 0; i < loaded_chunks__iter_source_length; i++) {
        let loaded_chunks__iter_source__iter: any;
        loaded_chunks__iter_source__iter = this.readUint8();
        loaded_chunks__iter.source.push(loaded_chunks__iter_source__iter);
      }
      loaded_chunks__iter.name = [];
      const loaded_chunks__iter_name_length = this.readUint32("little_endian");
      for (let i = 0; i < loaded_chunks__iter_name_length; i++) {
        let loaded_chunks__iter_name__iter: any;
        loaded_chunks__iter_name__iter = this.readUint8();
        loaded_chunks__iter.name.push(loaded_chunks__iter_name__iter);
      }
      value.loaded_chunks.push(loaded_chunks__iter);
    }
    return value;
  }
}

/**
 * The top-level keyframe artifact. Versioned independently of TraceFile (its own `version` word) — a distinct record family sharing the same binschema encoding, NOT fused with the trace artifact (docs/design/04: 'two artifacts, one substrate').
 */
export interface SnapshotFileInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of EVERY unswept object, in ascending id order (doc 61 Phase K: garbage included, so a restored VM gets the same intern hits and collection points); roots are the globals table id, the shared string-metatable id (1-based optional id: header.id + 1, or 0 = none), the live register window (a slot dead at capture is a DeadSlot tombstone), the active frame closures, and the open upvalues. `next_gc` is the heap's collection threshold (live-object count that triggers the next collection). F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture. `next_obj_id` is the heap's monotonic allocation counter (the next `GcHeader.id` to hand out): serialized so restore reproduces the id timeline EXACTLY even when objects were allocated and swept before the cut (a swept object bumped the counter but leaves no entry in `objects`, so reconstructing the counter as max(id)+1 would drift it low and diverge subsequent ids — which are observable via table/pairs ordering). `loaded_chunks` (L-2) carries every runtime-`load`ed chunk's source + name in load order: restore RE-COMPILES each (compile is deterministic) to regenerate identical protos/ids, so a live `load` closure survives snapshot→restore without serializing bytecode.
   */
  keyframe: KeyframeInput;
}

/**
 * The top-level keyframe artifact. Versioned independently of TraceFile (its own `version` word) — a distinct record family sharing the same binschema encoding, NOT fused with the trace artifact (docs/design/04: 'two artifacts, one substrate').
 */
export interface SnapshotFileOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of EVERY unswept object, in ascending id order (doc 61 Phase K: garbage included, so a restored VM gets the same intern hits and collection points); roots are the globals table id, the shared string-metatable id (1-based optional id: header.id + 1, or 0 = none), the live register window (a slot dead at capture is a DeadSlot tombstone), the active frame closures, and the open upvalues. `next_gc` is the heap's collection threshold (live-object count that triggers the next collection). F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture. `next_obj_id` is the heap's monotonic allocation counter (the next `GcHeader.id` to hand out): serialized so restore reproduces the id timeline EXACTLY even when objects were allocated and swept before the cut (a swept object bumped the counter but leaves no entry in `objects`, so reconstructing the counter as max(id)+1 would drift it low and diverge subsequent ids — which are observable via table/pairs ordering). `loaded_chunks` (L-2) carries every runtime-`load`ed chunk's source + name in load order: restore RE-COMPILES each (compile is deterministic) to regenerate identical protos/ids, so a live `load` closure survives snapshot→restore without serializing bytecode.
   */
  keyframe: KeyframeOutput;
}

export type SnapshotFile = SnapshotFileOutput;

export class SnapshotFileEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: SnapshotFileInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.version, "little_endian");
    const encoder_keyframe = new KeyframeEncoder();
    const encoded_keyframe = encoder_keyframe.encode(value.keyframe);
    for (const byte of encoded_keyframe) {
      this.writeUint8(byte);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a SnapshotFile value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: SnapshotFile): number {
    let size = 0;
    size += 4; // version
    // keyframe: custom type (Keyframe)
    const keyframe_encoder = new KeyframeEncoder();
    size += keyframe_encoder.calculateSize(value.keyframe);
    return size;
  }
}

export class SnapshotFileDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): SnapshotFileOutput {
    const value: any = {};

    value.version = this.readUint32("little_endian");
    value.keyframe = {};
    value.keyframe.globals_id = this.readUint32("little_endian");
    value.keyframe.string_metatable_id = this.readUint32("little_endian");
    value.keyframe.next_obj_id = this.readUint32("little_endian");
    value.keyframe.next_gc = this.readUint64("little_endian");
    value.keyframe.objects = [];
    const keyframe_objects_length = this.readUint32("little_endian");
    for (let i = 0; i < keyframe_objects_length; i++) {
      let keyframe_objects__iter: any;
      keyframe_objects__iter = {};
      keyframe_objects__iter.id = this.readUint32("little_endian");
      keyframe_objects__iter.obj_type = this.readUint8();
      if (keyframe_objects__iter.obj_type === 0) {
        const decoder = new HeapStringDecoder(this.bytes.slice(this.byteOffset), keyframe_objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_objects__iter.body = { type: 'HeapString', value: payload };
      }
      else if (keyframe_objects__iter.obj_type === 1) {
        const decoder = new HeapTableDecoder(this.bytes.slice(this.byteOffset), keyframe_objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_objects__iter.body = { type: 'HeapTable', value: payload };
      }
      else if (keyframe_objects__iter.obj_type === 2) {
        const decoder = new HeapClosureDecoder(this.bytes.slice(this.byteOffset), keyframe_objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_objects__iter.body = { type: 'HeapClosure', value: payload };
      }
      else if (keyframe_objects__iter.obj_type === 3) {
        const decoder = new HeapNativeDecoder(this.bytes.slice(this.byteOffset), keyframe_objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_objects__iter.body = { type: 'HeapNative', value: payload };
      }
      else if (keyframe_objects__iter.obj_type === 4) {
        const decoder = new HeapUpvalueDecoder(this.bytes.slice(this.byteOffset), keyframe_objects__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_objects__iter.body = { type: 'HeapUpvalue', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${keyframe_objects__iter.obj_type}`);
      }
      value.keyframe.objects.push(keyframe_objects__iter);
    }
    value.keyframe.stack = [];
    const keyframe_stack_length = this.readUint32("little_endian");
    for (let i = 0; i < keyframe_stack_length; i++) {
      let keyframe_stack__iter: any;
      keyframe_stack__iter = {};
      keyframe_stack__iter.tag = this.readUint8();
      if (keyframe_stack__iter.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), keyframe_stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_stack__iter.body = { type: 'ConstNil', value: payload };
      }
      else if (keyframe_stack__iter.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), keyframe_stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_stack__iter.body = { type: 'ConstBool', value: payload };
      }
      else if (keyframe_stack__iter.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), keyframe_stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_stack__iter.body = { type: 'ConstInt', value: payload };
      }
      else if (keyframe_stack__iter.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), keyframe_stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_stack__iter.body = { type: 'ConstFloat', value: payload };
      }
      else if (keyframe_stack__iter.tag === 4) {
        const decoder = new HeapRefDecoder(this.bytes.slice(this.byteOffset), keyframe_stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_stack__iter.body = { type: 'HeapRef', value: payload };
      }
      else if (keyframe_stack__iter.tag === 255) {
        const decoder = new DeadSlotDecoder(this.bytes.slice(this.byteOffset), keyframe_stack__iter);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        keyframe_stack__iter.body = { type: 'DeadSlot', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${keyframe_stack__iter.tag}`);
      }
      value.keyframe.stack.push(keyframe_stack__iter);
    }
    value.keyframe.frames = [];
    const keyframe_frames_length = this.readUint16("little_endian");
    for (let i = 0; i < keyframe_frames_length; i++) {
      let keyframe_frames__iter: any;
      keyframe_frames__iter = {};
      keyframe_frames__iter.closure_id = this.readUint32("little_endian");
      keyframe_frames__iter.pc = this.readUint32("little_endian");
      keyframe_frames__iter.base = this.readUint32("little_endian");
      keyframe_frames__iter.ret_dest = this.readUint16("little_endian");
      keyframe_frames__iter.ret_count = this.readUint16("little_endian");
      keyframe_frames__iter.varargs_base = this.readUint32("little_endian");
      keyframe_frames__iter.varargs_count = this.readUint32("little_endian");
      keyframe_frames__iter.ctl = this.readUint8();
      value.keyframe.frames.push(keyframe_frames__iter);
    }
    value.keyframe.open_upvalues = [];
    const keyframe_open_upvalues_length = this.readUint16("little_endian");
    for (let i = 0; i < keyframe_open_upvalues_length; i++) {
      let keyframe_open_upvalues__iter: any;
      keyframe_open_upvalues__iter = {};
      keyframe_open_upvalues__iter.stack_index = this.readUint32("little_endian");
      keyframe_open_upvalues__iter.upvalue_id = this.readUint32("little_endian");
      value.keyframe.open_upvalues.push(keyframe_open_upvalues__iter);
    }
    value.keyframe.loaded_chunks = [];
    const keyframe_loaded_chunks_length = this.readUint32("little_endian");
    for (let i = 0; i < keyframe_loaded_chunks_length; i++) {
      let keyframe_loaded_chunks__iter: any;
      keyframe_loaded_chunks__iter = {};
      keyframe_loaded_chunks__iter.source = [];
      const keyframe_loaded_chunks__iter_source_length = this.readUint32("little_endian");
      for (let i = 0; i < keyframe_loaded_chunks__iter_source_length; i++) {
        let keyframe_loaded_chunks__iter_source__iter: any;
        keyframe_loaded_chunks__iter_source__iter = this.readUint8();
        keyframe_loaded_chunks__iter.source.push(keyframe_loaded_chunks__iter_source__iter);
      }
      keyframe_loaded_chunks__iter.name = [];
      const keyframe_loaded_chunks__iter_name_length = this.readUint32("little_endian");
      for (let i = 0; i < keyframe_loaded_chunks__iter_name_length; i++) {
        let keyframe_loaded_chunks__iter_name__iter: any;
        keyframe_loaded_chunks__iter_name__iter = this.readUint8();
        keyframe_loaded_chunks__iter.name.push(keyframe_loaded_chunks__iter_name__iter);
      }
      value.keyframe.loaded_chunks.push(keyframe_loaded_chunks__iter);
    }
    return value;
  }
}

/**
 * An effect's recorded result. Its OWN tag space (deliberately NOT a Value.Tag mirror like SnapValue): scalars plus an inline string, never a heap_ref. A standalone effect log has no idmap, so a string result (getenv/argv) is carried as inline length-prefixed bytes (ConstString) and re-interned on replay; tables/closures are never effect results. tag: nil=0, bool=1, int=2, float=3, string=4.
 */
export interface EffectResultInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 5
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - ConstString (when value === 4)
   */
  body: { type: 'ConstNil'; value: ConstNilInput } | { type: 'ConstBool'; value: ConstBoolInput } | { type: 'ConstInt'; value: ConstIntInput } | { type: 'ConstFloat'; value: ConstFloatInput } | { type: 'ConstString'; value: ConstStringInput };
}

/**
 * An effect's recorded result. Its OWN tag space (deliberately NOT a Value.Tag mirror like SnapValue): scalars plus an inline string, never a heap_ref. A standalone effect log has no idmap, so a string result (getenv/argv) is carried as inline length-prefixed bytes (ConstString) and re-interned on replay; tables/closures are never effect results. tag: nil=0, bool=1, int=2, float=3, string=4.
 */
export interface EffectResultOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  tag: number;
  /**
   * Discriminated Union
   * Type that can be one of several variants, chosen based on a discriminator value. Supports peek-based (read ahead) or field-based (reference earlier field) discrimination.
   *
   * @remarks
   *
   * Discriminator: field 'tag'
   * Variants: 5
   * - ConstNil (when value === 0)
   * - ConstBool (when value === 1)
   * - ConstInt (when value === 2)
   * - ConstFloat (when value === 3)
   * - ConstString (when value === 4)
   */
  body: { type: 'ConstNil'; value: ConstNilOutput } | { type: 'ConstBool'; value: ConstBoolOutput } | { type: 'ConstInt'; value: ConstIntOutput } | { type: 'ConstFloat'; value: ConstFloatOutput } | { type: 'ConstString'; value: ConstStringOutput };
}

export type EffectResult = EffectResultOutput;

/**
 * Variant tags for EffectResult.body
 */
export const enum EffectResultBodyVariant {
  ConstNil = 'ConstNil',
  ConstBool = 'ConstBool',
  ConstInt = 'ConstInt',
  ConstFloat = 'ConstFloat',
  ConstString = 'ConstString',
}

export class EffectResultEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: EffectResultInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.tag);
    if (value.body.type === 'ConstNil') {
      const encoder_value = new ConstNilEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstBool') {
      const encoder_value = new ConstBoolEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstInt') {
      const encoder_value = new ConstIntEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstFloat') {
      const encoder_value = new ConstFloatEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    }
    else if (value.body.type === 'ConstString') {
      const encoder_value = new ConstStringEncoder();
      const encoded_value = encoder_value.encode(value.body.value);
      for (const byte of encoded_value) {
        this.writeUint8(byte);
      }
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type: ${(value.body as any).type}`);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a EffectResult value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: EffectResult): number {
    let size = 0;
    size += 1; // tag
    if (value.body.type === 'ConstNil') {
      const _enc = new ConstNilEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstBool') {
      const _enc = new ConstBoolEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstInt') {
      const _enc = new ConstIntEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstFloat') {
      const _enc = new ConstFloatEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else if (value.body.type === 'ConstString') {
      const _enc = new ConstStringEncoder();
      size += _enc.calculateSize(value.body.value);
    }
    else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown variant type for body: ${(value.body as any).type}`);
    }
    return size;
  }
}

export class EffectResultDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): EffectResultOutput {
    const value: any = {};

    value.tag = this.readUint8();
    if (value.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstNil', value: payload };
    }
    else if (value.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstBool', value: payload };
    }
    else if (value.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstInt', value: payload };
    }
    else if (value.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.tag === 4) {
      const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.body = { type: 'ConstString', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.tag}`);
    }
    return value;
  }
}

/**
 * One recorded nondeterministic INPUT: the host effect that produced it and the Value it returned. `kind` mirrors mahina's interp.EffectKind enum (clock=0, random_seed=1, getenv=2, argc=3, argv=4). The log is consumed in call order on replay; kind + result fully describe each entry (effect args are re-supplied by re-executing the same instruction stream). `result` is an EffectResult — scalars (clock/argc/random_seed) plus inline string bytes (getenv/argv), never a heap_ref.
 */
export interface EffectInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  kind: number;
  /**
   * An effect's recorded result. Its OWN tag space (deliberately NOT a Value.Tag mirror like SnapValue): scalars plus an inline string, never a heap_ref. A standalone effect log has no idmap, so a string result (getenv/argv) is carried as inline length-prefixed bytes (ConstString) and re-interned on replay; tables/closures are never effect results. tag: nil=0, bool=1, int=2, float=3, string=4.
   */
  result: EffectResultInput;
}

/**
 * One recorded nondeterministic INPUT: the host effect that produced it and the Value it returned. `kind` mirrors mahina's interp.EffectKind enum (clock=0, random_seed=1, getenv=2, argc=3, argv=4). The log is consumed in call order on replay; kind + result fully describe each entry (effect args are re-supplied by re-executing the same instruction stream). `result` is an EffectResult — scalars (clock/argc/random_seed) plus inline string bytes (getenv/argv), never a heap_ref.
 */
export interface EffectOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  kind: number;
  /**
   * An effect's recorded result. Its OWN tag space (deliberately NOT a Value.Tag mirror like SnapValue): scalars plus an inline string, never a heap_ref. A standalone effect log has no idmap, so a string result (getenv/argv) is carried as inline length-prefixed bytes (ConstString) and re-interned on replay; tables/closures are never effect results. tag: nil=0, bool=1, int=2, float=3, string=4.
   */
  result: EffectResultOutput;
}

export type Effect = EffectOutput;

export class EffectEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: EffectInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.kind);
    const encoder_result = new EffectResultEncoder();
    const encoded_result = encoder_result.encode(value.result);
    for (const byte of encoded_result) {
      this.writeUint8(byte);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a Effect value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: Effect): number {
    let size = 0;
    size += 1; // kind
    // result: custom type (EffectResult)
    const result_encoder = new EffectResultEncoder();
    size += result_encoder.calculateSize(value.result);
    return size;
  }
}

export class EffectDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): EffectOutput {
    const value: any = {};

    value.kind = this.readUint8();
    value.result = {};
    value.result.tag = this.readUint8();
    if (value.result.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value.result);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.result.body = { type: 'ConstNil', value: payload };
    }
    else if (value.result.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value.result);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.result.body = { type: 'ConstBool', value: payload };
    }
    else if (value.result.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value.result);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.result.body = { type: 'ConstInt', value: payload };
    }
    else if (value.result.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value.result);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.result.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.result.tag === 4) {
      const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), value.result);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.result.body = { type: 'ConstString', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.result.tag}`);
    }
    return value;
  }
}

/**
 * The top-level effect-log artifact (F2d): the ordered list of recorded nondeterministic inputs for one run. Its own `version` word — a third record family sharing the binschema encoding with the trace and keyframe artifacts, never fused (docs/design/04 'two artifacts, one substrate'). Replay restores a keyframe and feeds these back in order so re-execution past an effect is reproducible.
 */
export interface EffectFileInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  effects: EffectInput[];
}

/**
 * The top-level effect-log artifact (F2d): the ordered list of recorded nondeterministic inputs for one run. Its own `version` word — a third record family sharing the binschema encoding with the trace and keyframe artifacts, never fused (docs/design/04 'two artifacts, one substrate'). Replay restores a keyframe and feeds these back in order so re-execution past an effect is reproducible.
 */
export interface EffectFileOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  effects: EffectOutput[];
}

export type EffectFile = EffectFileOutput;

export class EffectFileEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: EffectFileInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.version, "little_endian");
    this.writeUint32(value.effects.length, "little_endian");
    for (let value_effects__iter_index = 0; value_effects__iter_index < value.effects.length; value_effects__iter_index++) {
      const value_effects__iter = value.effects[value_effects__iter_index];
      const encoder_value_effects__iter = new EffectEncoder();
      const encoded_value_effects__iter = encoder_value_effects__iter.encode(value_effects__iter);
      for (const byte of encoded_value_effects__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a EffectFile value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: EffectFile): number {
    let size = 0;
    size += 4; // version
    // effects: array (kind: length_prefixed)
    for (const item of value.effects) {
      const effects_itemEncoder = new EffectEncoder();
      size += effects_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class EffectFileDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): EffectFileOutput {
    const value: any = {};

    value.version = this.readUint32("little_endian");
    value.effects = [];
    const effects_length = this.readUint32("little_endian");
    for (let i = 0; i < effects_length; i++) {
      let effects__iter: any;
      effects__iter = {};
      effects__iter.kind = this.readUint8();
      effects__iter.result = {};
      effects__iter.result.tag = this.readUint8();
      if (effects__iter.result.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), effects__iter.result);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        effects__iter.result.body = { type: 'ConstNil', value: payload };
      }
      else if (effects__iter.result.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), effects__iter.result);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        effects__iter.result.body = { type: 'ConstBool', value: payload };
      }
      else if (effects__iter.result.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), effects__iter.result);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        effects__iter.result.body = { type: 'ConstInt', value: payload };
      }
      else if (effects__iter.result.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), effects__iter.result);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        effects__iter.result.body = { type: 'ConstFloat', value: payload };
      }
      else if (effects__iter.result.tag === 4) {
        const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), effects__iter.result);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        effects__iter.result.body = { type: 'ConstString', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${effects__iter.result.tag}`);
      }
      value.effects.push(effects__iter);
    }
    return value;
  }
}

/**
 * One event in a trace entry's execution stream (the viz iteration animation). `kind`: value=0 (a non-guard IR instruction produced `value`; `ref` = its SSA index), guard_pass=1 (a guard survived; `value` = the checked operand), commit=2 (a loop back-edge closed; `ref`/`value` unused), exit=3 (the entry side-exited at IR `ref`; terminal; `value` = the failing guard's operand or nil for an arith error). `value` reuses EffectResult — trace values are scalars at this phase (no heap/table IR ops; those abort tracing), so the self-contained scalar-or-inline-string encoding fits exactly.
 */
export interface ExecEventInput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  kind: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  ref: number;
  /**
   * An effect's recorded result. Its OWN tag space (deliberately NOT a Value.Tag mirror like SnapValue): scalars plus an inline string, never a heap_ref. A standalone effect log has no idmap, so a string result (getenv/argv) is carried as inline length-prefixed bytes (ConstString) and re-interned on replay; tables/closures are never effect results. tag: nil=0, bool=1, int=2, float=3, string=4.
   */
  value: EffectResultInput;
}

/**
 * One event in a trace entry's execution stream (the viz iteration animation). `kind`: value=0 (a non-guard IR instruction produced `value`; `ref` = its SSA index), guard_pass=1 (a guard survived; `value` = the checked operand), commit=2 (a loop back-edge closed; `ref`/`value` unused), exit=3 (the entry side-exited at IR `ref`; terminal; `value` = the failing guard's operand or nil for an arith error). `value` reuses EffectResult — trace values are scalars at this phase (no heap/table IR ops; those abort tracing), so the self-contained scalar-or-inline-string encoding fits exactly.
 */
export interface ExecEventOutput {
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  kind: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  ref: number;
  /**
   * An effect's recorded result. Its OWN tag space (deliberately NOT a Value.Tag mirror like SnapValue): scalars plus an inline string, never a heap_ref. A standalone effect log has no idmap, so a string result (getenv/argv) is carried as inline length-prefixed bytes (ConstString) and re-interned on replay; tables/closures are never effect results. tag: nil=0, bool=1, int=2, float=3, string=4.
   */
  value: EffectResultOutput;
}

export type ExecEvent = ExecEventOutput;

export class ExecEventEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ExecEventInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint8(value.kind);
    this.writeUint32(value.ref, "little_endian");
    const encoder_value = new EffectResultEncoder();
    const encoded_value = encoder_value.encode(value.value);
    for (const byte of encoded_value) {
      this.writeUint8(byte);
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ExecEvent value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ExecEvent): number {
    let size = 0;
    size += 5; // kind + ref
    // value: custom type (EffectResult)
    const value_encoder = new EffectResultEncoder();
    size += value_encoder.calculateSize(value.value);
    return size;
  }
}

export class ExecEventDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ExecEventOutput {
    const value: any = {};

    value.kind = this.readUint8();
    value.ref = this.readUint32("little_endian");
    value.value = {};
    value.value.tag = this.readUint8();
    if (value.value.tag === 0) {
      const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstNil', value: payload };
    }
    else if (value.value.tag === 1) {
      const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstBool', value: payload };
    }
    else if (value.value.tag === 2) {
      const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstInt', value: payload };
    }
    else if (value.value.tag === 3) {
      const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstFloat', value: payload };
    }
    else if (value.value.tag === 4) {
      const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), value.value);
      const payload = decoder.decode();
      this.byteOffset += decoder.byteOffset;
      value.value.body = { type: 'ConstString', value: payload };
    } else {
      throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${value.value.tag}`);
    }
    return value;
  }
}

/**
 * One trace entry = one IR-interpreter execute() call (an 'exit ramp'): the iterations it spun and the side-exit that ended it. `iterations` is the executor's yield (accurate even when `capped`). `exit_ref` = the faulting IR instruction; `exit_kind`: guard=0 / arith=1 / clean=2. `capped` = the per-entry `events` detail was truncated at the iteration cap (the terminal `exit` event is still present).
 */
export interface TraceEntryInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  iterations: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  exit_ref: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  exit_kind: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  capped: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  events: ExecEventInput[];
}

/**
 * One trace entry = one IR-interpreter execute() call (an 'exit ramp'): the iterations it spun and the side-exit that ended it. `iterations` is the executor's yield (accurate even when `capped`). `exit_ref` = the faulting IR instruction; `exit_kind`: guard=0 / arith=1 / clean=2. `capped` = the per-entry `events` detail was truncated at the iteration cap (the terminal `exit` event is still present).
 */
export interface TraceEntryOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  iterations: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  exit_ref: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  exit_kind: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  capped: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  events: ExecEventOutput[];
}

export type TraceEntry = TraceEntryOutput;

export class TraceEntryEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: TraceEntryInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.iterations, "little_endian");
    this.writeUint32(value.exit_ref, "little_endian");
    this.writeUint8(value.exit_kind);
    this.writeUint8(value.capped);
    this.writeUint32(value.events.length, "little_endian");
    for (let value_events__iter_index = 0; value_events__iter_index < value.events.length; value_events__iter_index++) {
      const value_events__iter = value.events[value_events__iter_index];
      const encoder_value_events__iter = new ExecEventEncoder();
      const encoded_value_events__iter = encoder_value_events__iter.encode(value_events__iter);
      for (const byte of encoded_value_events__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a TraceEntry value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: TraceEntry): number {
    let size = 0;
    size += 10; // iterations + exit_ref + exit_kind + capped
    // events: array (kind: length_prefixed)
    for (const item of value.events) {
      const events_itemEncoder = new ExecEventEncoder();
      size += events_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class TraceEntryDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): TraceEntryOutput {
    const value: any = {};

    value.iterations = this.readUint32("little_endian");
    value.exit_ref = this.readUint32("little_endian");
    value.exit_kind = this.readUint8();
    value.capped = this.readUint8();
    value.events = [];
    const events_length = this.readUint32("little_endian");
    for (let i = 0; i < events_length; i++) {
      let events__iter: any;
      events__iter = {};
      events__iter.kind = this.readUint8();
      events__iter.ref = this.readUint32("little_endian");
      events__iter.value = {};
      events__iter.value.tag = this.readUint8();
      if (events__iter.value.tag === 0) {
        const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), events__iter.value);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        events__iter.value.body = { type: 'ConstNil', value: payload };
      }
      else if (events__iter.value.tag === 1) {
        const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), events__iter.value);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        events__iter.value.body = { type: 'ConstBool', value: payload };
      }
      else if (events__iter.value.tag === 2) {
        const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), events__iter.value);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        events__iter.value.body = { type: 'ConstInt', value: payload };
      }
      else if (events__iter.value.tag === 3) {
        const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), events__iter.value);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        events__iter.value.body = { type: 'ConstFloat', value: payload };
      }
      else if (events__iter.value.tag === 4) {
        const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), events__iter.value);
        const payload = decoder.decode();
        this.byteOffset += decoder.byteOffset;
        events__iter.value.body = { type: 'ConstString', value: payload };
      } else {
        throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${events__iter.value.tag}`);
      }
      value.events.push(events__iter);
    }
    return value;
  }
}

/**
 * All recorded entries (exit ramps) for one cached trace, keyed by `trace_id` — the trace's stable `Trace.id`, matching `Trace.id` in the trace file (a retired trace's log is dropped with it). `entries_capped` = the entry cap was hit and further entries were not recorded.
 */
export interface TraceExecLogInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  trace_id: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  entries_capped: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  entries: TraceEntryInput[];
}

/**
 * All recorded entries (exit ramps) for one cached trace, keyed by `trace_id` — the trace's stable `Trace.id`, matching `Trace.id` in the trace file (a retired trace's log is dropped with it). `entries_capped` = the entry cap was hit and further entries were not recorded.
 */
export interface TraceExecLogOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  trace_id: number;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  entries_capped: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  entries: TraceEntryOutput[];
}

export type TraceExecLog = TraceExecLogOutput;

export class TraceExecLogEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: TraceExecLogInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.trace_id, "little_endian");
    this.writeUint8(value.entries_capped);
    this.writeUint32(value.entries.length, "little_endian");
    for (let value_entries__iter_index = 0; value_entries__iter_index < value.entries.length; value_entries__iter_index++) {
      const value_entries__iter = value.entries[value_entries__iter_index];
      const encoder_value_entries__iter = new TraceEntryEncoder();
      const encoded_value_entries__iter = encoder_value_entries__iter.encode(value_entries__iter);
      for (const byte of encoded_value_entries__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a TraceExecLog value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: TraceExecLog): number {
    let size = 0;
    size += 5; // trace_id + entries_capped
    // entries: array (kind: length_prefixed)
    for (const item of value.entries) {
      const entries_itemEncoder = new TraceEntryEncoder();
      size += entries_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class TraceExecLogDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): TraceExecLogOutput {
    const value: any = {};

    value.trace_id = this.readUint32("little_endian");
    value.entries_capped = this.readUint8();
    value.entries = [];
    const entries_length = this.readUint32("little_endian");
    for (let i = 0; i < entries_length; i++) {
      let entries__iter: any;
      entries__iter = {};
      entries__iter.iterations = this.readUint32("little_endian");
      entries__iter.exit_ref = this.readUint32("little_endian");
      entries__iter.exit_kind = this.readUint8();
      entries__iter.capped = this.readUint8();
      entries__iter.events = [];
      const entries__iter_events_length = this.readUint32("little_endian");
      for (let i = 0; i < entries__iter_events_length; i++) {
        let entries__iter_events__iter: any;
        entries__iter_events__iter = {};
        entries__iter_events__iter.kind = this.readUint8();
        entries__iter_events__iter.ref = this.readUint32("little_endian");
        entries__iter_events__iter.value = {};
        entries__iter_events__iter.value.tag = this.readUint8();
        if (entries__iter_events__iter.value.tag === 0) {
          const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), entries__iter_events__iter.value);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          entries__iter_events__iter.value.body = { type: 'ConstNil', value: payload };
        }
        else if (entries__iter_events__iter.value.tag === 1) {
          const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), entries__iter_events__iter.value);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          entries__iter_events__iter.value.body = { type: 'ConstBool', value: payload };
        }
        else if (entries__iter_events__iter.value.tag === 2) {
          const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), entries__iter_events__iter.value);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          entries__iter_events__iter.value.body = { type: 'ConstInt', value: payload };
        }
        else if (entries__iter_events__iter.value.tag === 3) {
          const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), entries__iter_events__iter.value);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          entries__iter_events__iter.value.body = { type: 'ConstFloat', value: payload };
        }
        else if (entries__iter_events__iter.value.tag === 4) {
          const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), entries__iter_events__iter.value);
          const payload = decoder.decode();
          this.byteOffset += decoder.byteOffset;
          entries__iter_events__iter.value.body = { type: 'ConstString', value: payload };
        } else {
          throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${entries__iter_events__iter.value.tag}`);
        }
        entries__iter.events.push(entries__iter_events__iter);
      }
      value.entries.push(entries__iter);
    }
    return value;
  }
}

/**
 * The top-level trace execution-log artifact (the JIT-trace iteration animation): per-trace execution logs for one run. Its own `version` word — a FOURTH record family sharing the binschema encoding with the trace/keyframe/effect artifacts, never fused (docs/design/04 'two artifacts, one substrate', now four). Unlike the effect log it is an *observation* log, not a replay input — nothing feeds it back; the visualizer animates it.
 */
export interface ExecLogFileInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  logs: TraceExecLogInput[];
}

/**
 * The top-level trace execution-log artifact (the JIT-trace iteration animation): per-trace execution logs for one run. Its own `version` word — a FOURTH record family sharing the binschema encoding with the trace/keyframe/effect artifacts, never fused (docs/design/04 'two artifacts, one substrate', now four). Unlike the effect log it is an *observation* log, not a replay input — nothing feeds it back; the visualizer animates it.
 */
export interface ExecLogFileOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  logs: TraceExecLogOutput[];
}

export type ExecLogFile = ExecLogFileOutput;

export class ExecLogFileEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: ExecLogFileInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.version, "little_endian");
    this.writeUint32(value.logs.length, "little_endian");
    for (let value_logs__iter_index = 0; value_logs__iter_index < value.logs.length; value_logs__iter_index++) {
      const value_logs__iter = value.logs[value_logs__iter_index];
      const encoder_value_logs__iter = new TraceExecLogEncoder();
      const encoded_value_logs__iter = encoder_value_logs__iter.encode(value_logs__iter);
      for (const byte of encoded_value_logs__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a ExecLogFile value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: ExecLogFile): number {
    let size = 0;
    size += 4; // version
    // logs: array (kind: length_prefixed)
    for (const item of value.logs) {
      const logs_itemEncoder = new TraceExecLogEncoder();
      size += logs_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class ExecLogFileDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): ExecLogFileOutput {
    const value: any = {};

    value.version = this.readUint32("little_endian");
    value.logs = [];
    const logs_length = this.readUint32("little_endian");
    for (let i = 0; i < logs_length; i++) {
      let logs__iter: any;
      logs__iter = {};
      logs__iter.trace_id = this.readUint32("little_endian");
      logs__iter.entries_capped = this.readUint8();
      logs__iter.entries = [];
      const logs__iter_entries_length = this.readUint32("little_endian");
      for (let i = 0; i < logs__iter_entries_length; i++) {
        let logs__iter_entries__iter: any;
        logs__iter_entries__iter = {};
        logs__iter_entries__iter.iterations = this.readUint32("little_endian");
        logs__iter_entries__iter.exit_ref = this.readUint32("little_endian");
        logs__iter_entries__iter.exit_kind = this.readUint8();
        logs__iter_entries__iter.capped = this.readUint8();
        logs__iter_entries__iter.events = [];
        const logs__iter_entries__iter_events_length = this.readUint32("little_endian");
        for (let i = 0; i < logs__iter_entries__iter_events_length; i++) {
          let logs__iter_entries__iter_events__iter: any;
          logs__iter_entries__iter_events__iter = {};
          logs__iter_entries__iter_events__iter.kind = this.readUint8();
          logs__iter_entries__iter_events__iter.ref = this.readUint32("little_endian");
          logs__iter_entries__iter_events__iter.value = {};
          logs__iter_entries__iter_events__iter.value.tag = this.readUint8();
          if (logs__iter_entries__iter_events__iter.value.tag === 0) {
            const decoder = new ConstNilDecoder(this.bytes.slice(this.byteOffset), logs__iter_entries__iter_events__iter.value);
            const payload = decoder.decode();
            this.byteOffset += decoder.byteOffset;
            logs__iter_entries__iter_events__iter.value.body = { type: 'ConstNil', value: payload };
          }
          else if (logs__iter_entries__iter_events__iter.value.tag === 1) {
            const decoder = new ConstBoolDecoder(this.bytes.slice(this.byteOffset), logs__iter_entries__iter_events__iter.value);
            const payload = decoder.decode();
            this.byteOffset += decoder.byteOffset;
            logs__iter_entries__iter_events__iter.value.body = { type: 'ConstBool', value: payload };
          }
          else if (logs__iter_entries__iter_events__iter.value.tag === 2) {
            const decoder = new ConstIntDecoder(this.bytes.slice(this.byteOffset), logs__iter_entries__iter_events__iter.value);
            const payload = decoder.decode();
            this.byteOffset += decoder.byteOffset;
            logs__iter_entries__iter_events__iter.value.body = { type: 'ConstInt', value: payload };
          }
          else if (logs__iter_entries__iter_events__iter.value.tag === 3) {
            const decoder = new ConstFloatDecoder(this.bytes.slice(this.byteOffset), logs__iter_entries__iter_events__iter.value);
            const payload = decoder.decode();
            this.byteOffset += decoder.byteOffset;
            logs__iter_entries__iter_events__iter.value.body = { type: 'ConstFloat', value: payload };
          }
          else if (logs__iter_entries__iter_events__iter.value.tag === 4) {
            const decoder = new ConstStringDecoder(this.bytes.slice(this.byteOffset), logs__iter_entries__iter_events__iter.value);
            const payload = decoder.decode();
            this.byteOffset += decoder.byteOffset;
            logs__iter_entries__iter_events__iter.value.body = { type: 'ConstString', value: payload };
          } else {
            throw new BinSchemaError(ErrorCode.INVALID_VARIANT, `Unknown discriminator value: ${logs__iter_entries__iter_events__iter.value.tag}`);
          }
          logs__iter_entries__iter.events.push(logs__iter_entries__iter_events__iter);
        }
        logs__iter.entries.push(logs__iter_entries__iter);
      }
      value.logs.push(logs__iter);
    }
    return value;
  }
}

/**
 * The raw JIT event counters (TraceState, src/trace.zig), mirroring the '--jit-stats' event-counter block. Always live regardless of the coverage gate — they cost nothing on the hot path. link arm/fuse/disarm track the native chaining machinery; the *link_exits/*follow* pairs count exit-chaining hops; prime_side_* the coherent-state-chaining source arming.
 */
export interface JitCountersInput {
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  entries: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_source_link_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_loopdone_link_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_source_link_fused: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_loopdone_link_fused: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_disarms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_exits: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_follow_count: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  link_ir_exits: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  link_follow_count: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  prime_side_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  prime_side_chain_follows: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  tier0_outer_body_entries: bigint;
}

/**
 * The raw JIT event counters (TraceState, src/trace.zig), mirroring the '--jit-stats' event-counter block. Always live regardless of the coverage gate — they cost nothing on the hot path. link arm/fuse/disarm track the native chaining machinery; the *link_exits/*follow* pairs count exit-chaining hops; prime_side_* the coherent-state-chaining source arming.
 */
export interface JitCountersOutput {
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  entries: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_source_link_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_loopdone_link_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_source_link_fused: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_loopdone_link_fused: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_disarms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_exits: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  native_link_follow_count: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  link_ir_exits: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  link_follow_count: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  prime_side_arms: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  prime_side_chain_follows: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  tier0_outer_body_entries: bigint;
}

export type JitCounters = JitCountersOutput;

export class JitCountersEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: JitCountersInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint64(value.entries, "little_endian");
    this.writeUint64(value.native_link_arms, "little_endian");
    this.writeUint64(value.native_source_link_arms, "little_endian");
    this.writeUint64(value.native_loopdone_link_arms, "little_endian");
    this.writeUint64(value.native_source_link_fused, "little_endian");
    this.writeUint64(value.native_loopdone_link_fused, "little_endian");
    this.writeUint64(value.native_link_disarms, "little_endian");
    this.writeUint64(value.native_link_exits, "little_endian");
    this.writeUint64(value.native_link_follow_count, "little_endian");
    this.writeUint64(value.link_ir_exits, "little_endian");
    this.writeUint64(value.link_follow_count, "little_endian");
    this.writeUint64(value.prime_side_arms, "little_endian");
    this.writeUint64(value.prime_side_chain_follows, "little_endian");
    this.writeUint64(value.tier0_outer_body_entries, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a JitCounters value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: JitCounters): number {
    return 112; // entries + native_link_arms + native_source_link_arms + native_loopdone_link_arms + native_source_link_fused + native_loopdone_link_fused + native_link_disarms + native_link_exits + native_link_follow_count + link_ir_exits + link_follow_count + prime_side_arms + prime_side_chain_follows + tier0_outer_body_entries
  }
}

export class JitCountersDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): JitCountersOutput {
    const value: any = {};

    value.entries = this.readUint64("little_endian");
    value.native_link_arms = this.readUint64("little_endian");
    value.native_source_link_arms = this.readUint64("little_endian");
    value.native_loopdone_link_arms = this.readUint64("little_endian");
    value.native_source_link_fused = this.readUint64("little_endian");
    value.native_loopdone_link_fused = this.readUint64("little_endian");
    value.native_link_disarms = this.readUint64("little_endian");
    value.native_link_exits = this.readUint64("little_endian");
    value.native_link_follow_count = this.readUint64("little_endian");
    value.link_ir_exits = this.readUint64("little_endian");
    value.link_follow_count = this.readUint64("little_endian");
    value.prime_side_arms = this.readUint64("little_endian");
    value.prime_side_chain_follows = this.readUint64("little_endian");
    value.tier0_outer_body_entries = this.readUint64("little_endian");
    return value;
  }
}

/**
 * Per-loop-header JIT execution coverage (AnchorCoverage, src/trace.zig), keyed by the anchor's stable proto id (never the *const Proto pointer) plus loop-header pc. `traced_iters`/`interp_iters` are back-edge counts (ran-as-trace vs fell-back-to-tier-0); `traced_cycles`/`interp_cycles` are the per-hop TSC attribution (0 on a target without rdtsc). `fallback_iters` is the part of `interp_iters` taken after a trace existed here (the rest is warm-up before the trace was committed), so `fallback_iters` vs `traced_iters` says whether the loop ran native once it could. `has_trace` = a compiled trace exists at this anchor — so an anchor with has_trace=1 and traced_iters=0 is the smell: it has a trace but ran fully interpreted.
 */
export interface CoverageAnchorInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  proto_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  pc: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  traced_iters: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  interp_iters: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  fallback_iters: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  traced_cycles: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  interp_cycles: bigint;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  has_trace: number;
}

/**
 * Per-loop-header JIT execution coverage (AnchorCoverage, src/trace.zig), keyed by the anchor's stable proto id (never the *const Proto pointer) plus loop-header pc. `traced_iters`/`interp_iters` are back-edge counts (ran-as-trace vs fell-back-to-tier-0); `traced_cycles`/`interp_cycles` are the per-hop TSC attribution (0 on a target without rdtsc). `fallback_iters` is the part of `interp_iters` taken after a trace existed here (the rest is warm-up before the trace was committed), so `fallback_iters` vs `traced_iters` says whether the loop ran native once it could. `has_trace` = a compiled trace exists at this anchor — so an anchor with has_trace=1 and traced_iters=0 is the smell: it has a trace but ran fully interpreted.
 */
export interface CoverageAnchorOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  proto_id: number;
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  pc: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  traced_iters: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  interp_iters: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  fallback_iters: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  traced_cycles: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  interp_cycles: bigint;
  /**
   * 8-bit Unsigned Integer
   * Fixed-width 8-bit unsigned integer (0-255). Single byte, no endianness concerns.
   */
  has_trace: number;
}

export type CoverageAnchor = CoverageAnchorOutput;

export class CoverageAnchorEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: CoverageAnchorInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.proto_id, "little_endian");
    this.writeUint32(value.pc, "little_endian");
    this.writeUint64(value.traced_iters, "little_endian");
    this.writeUint64(value.interp_iters, "little_endian");
    this.writeUint64(value.fallback_iters, "little_endian");
    this.writeUint64(value.traced_cycles, "little_endian");
    this.writeUint64(value.interp_cycles, "little_endian");
    this.writeUint8(value.has_trace);
    return this.finish();
  }

  /**
   * Calculate the encoded size of a CoverageAnchor value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: CoverageAnchor): number {
    return 49; // proto_id + pc + traced_iters + interp_iters + fallback_iters + traced_cycles + interp_cycles + has_trace
  }
}

export class CoverageAnchorDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): CoverageAnchorOutput {
    const value: any = {};

    value.proto_id = this.readUint32("little_endian");
    value.pc = this.readUint32("little_endian");
    value.traced_iters = this.readUint64("little_endian");
    value.interp_iters = this.readUint64("little_endian");
    value.fallback_iters = this.readUint64("little_endian");
    value.traced_cycles = this.readUint64("little_endian");
    value.interp_cycles = this.readUint64("little_endian");
    value.has_trace = this.readUint8();
    return value;
  }
}

/**
 * The top-level JIT-coverage artifact (Phase 2): the aggregate native-vs-tier-0 execution split by iterations AND by TSC time, the raw event counters, and the per-anchor breakdown. Its own `version` word — a FIFTH record family sharing the binschema encoding, never fused (docs/design/04 'two artifacts, one substrate'). An *observation* artifact, not a replay input. `cycles_*`/`run_cycles` are 0 on a target without rdtsc (the wasm VM), in which case the visualizer shows time as n/a and weighs by iterations only. `anchors` is sorted (proto_id, pc) for a reproducible artifact.
 */
export interface CoverageFileInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  iters_traced: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  iters_tier0_covered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  iters_tier0_uncovered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  cycles_traced: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  cycles_tier0_covered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  cycles_tier0_uncovered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  run_cycles: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  run_nanos: bigint;
  /**
   * The raw JIT event counters (TraceState, src/trace.zig), mirroring the '--jit-stats' event-counter block. Always live regardless of the coverage gate — they cost nothing on the hot path. link arm/fuse/disarm track the native chaining machinery; the *link_exits/*follow* pairs count exit-chaining hops; prime_side_* the coherent-state-chaining source arming.
   */
  counters: JitCountersInput;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  anchors: CoverageAnchorInput[];
}

/**
 * The top-level JIT-coverage artifact (Phase 2): the aggregate native-vs-tier-0 execution split by iterations AND by TSC time, the raw event counters, and the per-anchor breakdown. Its own `version` word — a FIFTH record family sharing the binschema encoding, never fused (docs/design/04 'two artifacts, one substrate'). An *observation* artifact, not a replay input. `cycles_*`/`run_cycles` are 0 on a target without rdtsc (the wasm VM), in which case the visualizer shows time as n/a and weighs by iterations only. `anchors` is sorted (proto_id, pc) for a reproducible artifact.
 */
export interface CoverageFileOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  version: number;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  iters_traced: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  iters_tier0_covered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  iters_tier0_uncovered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  cycles_traced: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  cycles_tier0_covered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  cycles_tier0_uncovered: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  run_cycles: bigint;
  /**
   * 64-bit Unsigned Integer
   * Fixed-width 64-bit unsigned integer (0-18446744073709551615). Respects endianness configuration.
   */
  run_nanos: bigint;
  /**
   * The raw JIT event counters (TraceState, src/trace.zig), mirroring the '--jit-stats' event-counter block. Always live regardless of the coverage gate — they cost nothing on the hot path. link arm/fuse/disarm track the native chaining machinery; the *link_exits/*follow* pairs count exit-chaining hops; prime_side_* the coherent-state-chaining source arming.
   */
  counters: JitCountersOutput;
  /**
   * Array
   * Collection of elements of the same type. Supports fixed-length, length-prefixed, byte-length-prefixed, field-referenced, and null-terminated arrays.
   *
   * @remarks
   *
   * Array kind: length_prefixed
   * Length prefix type: uint32
   */
  anchors: CoverageAnchorOutput[];
}

export type CoverageFile = CoverageFileOutput;

export class CoverageFileEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: CoverageFileInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint32(value.version, "little_endian");
    this.writeUint64(value.iters_traced, "little_endian");
    this.writeUint64(value.iters_tier0_covered, "little_endian");
    this.writeUint64(value.iters_tier0_uncovered, "little_endian");
    this.writeUint64(value.cycles_traced, "little_endian");
    this.writeUint64(value.cycles_tier0_covered, "little_endian");
    this.writeUint64(value.cycles_tier0_uncovered, "little_endian");
    this.writeUint64(value.run_cycles, "little_endian");
    this.writeUint64(value.run_nanos, "little_endian");
    const encoder_counters = new JitCountersEncoder();
    const encoded_counters = encoder_counters.encode(value.counters);
    for (const byte of encoded_counters) {
      this.writeUint8(byte);
    }
    this.writeUint32(value.anchors.length, "little_endian");
    for (let value_anchors__iter_index = 0; value_anchors__iter_index < value.anchors.length; value_anchors__iter_index++) {
      const value_anchors__iter = value.anchors[value_anchors__iter_index];
      const encoder_value_anchors__iter = new CoverageAnchorEncoder();
      const encoded_value_anchors__iter = encoder_value_anchors__iter.encode(value_anchors__iter);
      for (const byte of encoded_value_anchors__iter) {
        this.writeUint8(byte);
      }
    }
    return this.finish();
  }

  /**
   * Calculate the encoded size of a CoverageFile value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: CoverageFile): number {
    let size = 0;
    size += 68; // version + iters_traced + iters_tier0_covered + iters_tier0_uncovered + cycles_traced + cycles_tier0_covered + cycles_tier0_uncovered + run_cycles + run_nanos
    // counters: custom type (JitCounters)
    const counters_encoder = new JitCountersEncoder();
    size += counters_encoder.calculateSize(value.counters);
    // anchors: array (kind: length_prefixed)
    for (const item of value.anchors) {
      const anchors_itemEncoder = new CoverageAnchorEncoder();
      size += anchors_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    return size;
  }
}

export class CoverageFileDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): CoverageFileOutput {
    const value: any = {};

    value.version = this.readUint32("little_endian");
    value.iters_traced = this.readUint64("little_endian");
    value.iters_tier0_covered = this.readUint64("little_endian");
    value.iters_tier0_uncovered = this.readUint64("little_endian");
    value.cycles_traced = this.readUint64("little_endian");
    value.cycles_tier0_covered = this.readUint64("little_endian");
    value.cycles_tier0_uncovered = this.readUint64("little_endian");
    value.run_cycles = this.readUint64("little_endian");
    value.run_nanos = this.readUint64("little_endian");
    value.counters = {};
    value.counters.entries = this.readUint64("little_endian");
    value.counters.native_link_arms = this.readUint64("little_endian");
    value.counters.native_source_link_arms = this.readUint64("little_endian");
    value.counters.native_loopdone_link_arms = this.readUint64("little_endian");
    value.counters.native_source_link_fused = this.readUint64("little_endian");
    value.counters.native_loopdone_link_fused = this.readUint64("little_endian");
    value.counters.native_link_disarms = this.readUint64("little_endian");
    value.counters.native_link_exits = this.readUint64("little_endian");
    value.counters.native_link_follow_count = this.readUint64("little_endian");
    value.counters.link_ir_exits = this.readUint64("little_endian");
    value.counters.link_follow_count = this.readUint64("little_endian");
    value.counters.prime_side_arms = this.readUint64("little_endian");
    value.counters.prime_side_chain_follows = this.readUint64("little_endian");
    value.counters.tier0_outer_body_entries = this.readUint64("little_endian");
    value.anchors = [];
    const anchors_length = this.readUint32("little_endian");
    for (let i = 0; i < anchors_length; i++) {
      let anchors__iter: any;
      anchors__iter = {};
      anchors__iter.proto_id = this.readUint32("little_endian");
      anchors__iter.pc = this.readUint32("little_endian");
      anchors__iter.traced_iters = this.readUint64("little_endian");
      anchors__iter.interp_iters = this.readUint64("little_endian");
      anchors__iter.fallback_iters = this.readUint64("little_endian");
      anchors__iter.traced_cycles = this.readUint64("little_endian");
      anchors__iter.interp_cycles = this.readUint64("little_endian");
      anchors__iter.has_trace = this.readUint8();
      value.anchors.push(anchors__iter);
    }
    return value;
  }
}

