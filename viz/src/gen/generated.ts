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
 * A heap string constant: the raw bytes (lune strings are byte strings, not necessarily UTF-8).
 */
export interface ConstStringInput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  v: number[];
}

/**
 * A heap string constant: the raw bytes (lune strings are byte strings, not necessarily UTF-8).
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
 * A trace constant. `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4). A heap_ref const is always a string (tables/closures are never compile-time constants).
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
 * A trace constant. `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4). A heap_ref const is always a string (tables/closures are never compile-time constants).
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
 * One SSA instruction: op, two operand refs, aux immediate, observed type, snapshot index.
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
}

/**
 * One SSA instruction: op, two operand refs, aux immediate, observed type, snapshot index.
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
    return this.finish();
  }

  /**
   * Calculate the encoded size of a IrInstr value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: IrInstr): number {
    return 14; // op + a + b + aux + ty + snap
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
    return value;
  }
}

/**
 * A loop-carried writeback: tier-0 register `slot` <- IR value `ref` at the back-edge.
 */
export interface SlotStoreInput {
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  slot: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ref: number;
}

/**
 * A loop-carried writeback: tier-0 register `slot` <- IR value `ref` at the back-edge.
 */
export interface SlotStoreOutput {
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  slot: number;
  /**
   * 16-bit Unsigned Integer
   * Fixed-width 16-bit unsigned integer (0-65535). Respects endianness configuration (big-endian or little-endian).
   */
  ref: number;
}

export type SlotStore = SlotStoreOutput;

export class SlotStoreEncoder extends BitStreamEncoder {
  private compressionDict: Map<string, number> = new Map();

  constructor() {
    super("lsb_first");
  }

  encode(value: SlotStoreInput): Uint8Array {
    // Reset compression dictionary for each encode
    this.compressionDict.clear();

    this.writeUint16(value.slot, "little_endian");
    this.writeUint16(value.ref, "little_endian");
    return this.finish();
  }

  /**
   * Calculate the encoded size of a SlotStore value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: SlotStore): number {
    return 4; // slot + ref
  }
}

export class SlotStoreDecoder extends SeekableBitStreamDecoder {
  constructor(input: Uint8Array | number[] | string, private context?: any) {
    const reader = createReader(input);
    super(reader, "lsb_first");
  }

  decode(): SlotStoreOutput {
    const value: any = {};

    value.slot = this.readUint16("little_endian");
    value.ref = this.readUint16("little_endian");
    return value;
  }
}

/**
 * A committed, cached trace. The anchor is a stable proto id (assigned at compile time) plus the loop-header pc; the in-memory *const Proto pointer is never serialized.
 */
export interface TraceInput {
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
   * Length prefix type: uint16
   */
  exit_stores: SlotStoreInput[];
}

/**
 * A committed, cached trace. The anchor is a stable proto id (assigned at compile time) plus the loop-header pc; the in-memory *const Proto pointer is never serialized.
 */
export interface TraceOutput {
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
   * Length prefix type: uint16
   */
  exit_stores: SlotStoreOutput[];
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

    this.writeUint32(value.anchor_proto_id, "little_endian");
    this.writeUint32(value.anchor_pc, "little_endian");
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
    this.writeUint16(value.exit_stores.length, "little_endian");
    for (let value_exit_stores__iter_index = 0; value_exit_stores__iter_index < value.exit_stores.length; value_exit_stores__iter_index++) {
      const value_exit_stores__iter = value.exit_stores[value_exit_stores__iter_index];
      const encoder_value_exit_stores__iter = new SlotStoreEncoder();
      const encoded_value_exit_stores__iter = encoder_value_exit_stores__iter.encode(value_exit_stores__iter);
      for (const byte of encoded_value_exit_stores__iter) {
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
    size += 8; // anchor_proto_id + anchor_pc
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
    // exit_stores: array (kind: length_prefixed)
    for (const item of value.exit_stores) {
      const exit_stores_itemEncoder = new SlotStoreEncoder();
      size += exit_stores_itemEncoder.calculateSize(item);
    }
    size += 2; // length prefix (uint16)
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

    value.anchor_proto_id = this.readUint32("little_endian");
    value.anchor_pc = this.readUint32("little_endian");
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
    value.exit_stores = [];
    const exit_stores_length = this.readUint16("little_endian");
    for (let i = 0; i < exit_stores_length; i++) {
      let exit_stores__iter: any;
      exit_stores__iter = {};
      exit_stores__iter.slot = this.readUint16("little_endian");
      exit_stores__iter.ref = this.readUint16("little_endian");
      value.exit_stores.push(exit_stores__iter);
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
      traces__iter.anchor_proto_id = this.readUint32("little_endian");
      traces__iter.anchor_pc = this.readUint32("little_endian");
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
      traces__iter.exit_stores = [];
      const traces__iter_exit_stores_length = this.readUint16("little_endian");
      for (let i = 0; i < traces__iter_exit_stores_length; i++) {
        let traces__iter_exit_stores__iter: any;
        traces__iter_exit_stores__iter = {};
        traces__iter_exit_stores__iter.slot = this.readUint16("little_endian");
        traces__iter_exit_stores__iter.ref = this.readUint16("little_endian");
        traces__iter.exit_stores.push(traces__iter_exit_stores__iter);
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
 * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
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
 * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
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
 * One key/value pair from a table's hash part. Array-part entries are stored positionally in HeapTable.array; everything else lands here.
 */
export interface TableEntryInput {
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  key: SnapValueInput;
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  val: SnapValueInput;
}

/**
 * One key/value pair from a table's hash part. Array-part entries are stored positionally in HeapTable.array; everything else lands here.
 */
export interface TableEntryOutput {
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
   */
  key: SnapValueOutput;
  /**
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
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
 * A heap string object's raw bytes (lune strings are byte strings, not necessarily UTF-8). Interned at restore.
 */
export interface HeapStringInput {
  /**
   * Bytes
   * Raw byte array. Sugar for array of uint8 — same wire format, simpler schema definition.
   */
  bytes: number[];
}

/**
 * A heap string object's raw bytes (lune strings are byte strings, not necessarily UTF-8). Interned at restore.
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
 * A table object: the dense array part (keys 1..n, positionally) plus the hash part (every other key). Edges are SnapValue heap_refs.
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
}

/**
 * A table object: the dense array part (keys 1..n, positionally) plus the hash part (every other key). Edges are SnapValue heap_refs.
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
    size += 4; // length prefix (uint32)
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
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
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
   * A live runtime Value on the wire (src/value.zig). `tag` mirrors lune's Value.Tag enum (nil=0, boolean=1, int=2, float=3, heap_ref=4) — the same ordinals as ConstValue. Unlike a trace ConstValue, a heap_ref here may reference ANY heap object (table/closure/string/...), carried as the referenced object's id (HeapRef).
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
 * One active call frame, with the execution cursor needed to RESUME it mid-execution (F2c): the executing closure's id, the resumable program counter, the register-window base on the shared stack, and the return-wiring (where this frame's results land in its parent, and how many the parent wants). Windows stack contiguously: frames[i+1].base == frames[i].base + frames[i].closure.proto.num_registers. The bottom (main) frame leaves ret_dest/ret_count unused.
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
}

/**
 * One active call frame, with the execution cursor needed to RESUME it mid-execution (F2c): the executing closure's id, the resumable program counter, the register-window base on the shared stack, and the return-wiring (where this frame's results land in its parent, and how many the parent wants). Windows stack contiguously: frames[i+1].base == frames[i].base + frames[i].closure.proto.num_registers. The bottom (main) frame leaves ret_dest/ret_count unused.
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
    return this.finish();
  }

  /**
   * Calculate the encoded size of a FrameRef value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: FrameRef): number {
    return 16; // closure_id + pc + base + ret_dest + ret_count
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
    return value;
  }
}

/**
 * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of objects keyed by id; roots are the globals table id, the live register window, the active frame closures, and the open upvalues. F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture.
 */
export interface KeyframeInput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  globals_id: number;
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
  stack: SnapValueInput[];
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
}

/**
 * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of objects keyed by id; roots are the globals table id, the live register window, the active frame closures, and the open upvalues. F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture.
 */
export interface KeyframeOutput {
  /**
   * 32-bit Unsigned Integer
   * Fixed-width 32-bit unsigned integer (0-4294967295). Respects endianness configuration.
   */
  globals_id: number;
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
  stack: SnapValueOutput[];
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
      const encoder_value_stack__iter = new SnapValueEncoder();
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
    return this.finish();
  }

  /**
   * Calculate the encoded size of a Keyframe value.
   * Used for from_after_field computed lengths and buffer pre-allocation.
   */
  calculateSize(value: Keyframe): number {
    let size = 0;
    size += 4; // globals_id
    // objects: array (kind: length_prefixed)
    for (const item of value.objects) {
      const objects_itemEncoder = new HeapObjectEncoder();
      size += objects_itemEncoder.calculateSize(item);
    }
    size += 4; // length prefix (uint32)
    // stack: array (kind: length_prefixed)
    for (const item of value.stack) {
      const stack_itemEncoder = new SnapValueEncoder();
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
   * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of objects keyed by id; roots are the globals table id, the live register window, the active frame closures, and the open upvalues. F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture.
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
   * A whole-VM state snapshot at one moment (docs/design/04-snapshot-replay-schema.md). The heap is a flat array of objects keyed by id; roots are the globals table id, the live register window, the active frame closures, and the open upvalues. F2a captures the final state (empty stack/frames/open_upvalues); F2b adds mid-execution capture.
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
 * One recorded nondeterministic INPUT: the host effect that produced it and the Value it returned. `kind` mirrors lune's interp.EffectKind enum (clock=0, random_seed=1, getenv=2, argc=3, argv=4). The log is consumed in call order on replay; kind + result fully describe each entry (effect args are re-supplied by re-executing the same instruction stream). `result` is an EffectResult — scalars (clock/argc/random_seed) plus inline string bytes (getenv/argv), never a heap_ref.
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
 * One recorded nondeterministic INPUT: the host effect that produced it and the Value it returned. `kind` mirrors lune's interp.EffectKind enum (clock=0, random_seed=1, getenv=2, argc=3, argv=4). The log is consumed in call order on replay; kind + result fully describe each entry (effect args are re-supplied by re-executing the same instruction stream). `result` is an EffectResult — scalars (clock/argc/random_seed) plus inline string bytes (getenv/argv), never a heap_ref.
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

