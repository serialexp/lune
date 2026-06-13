import { BitStreamEncoder, Endianness } from "./bit-stream.js";
import { SeekableBitStreamDecoder } from "./seekable-bit-stream.js";
import { createReader } from "./binary-reader.js";
import { crc32 } from "./crc32.js";
import { evaluateExpression } from "./expression-evaluator.js";
import { BinSchemaError, ErrorCode } from "./errors.js";

function __bs_get<T>(expr: () => T): T | undefined {
  try {
    return expr();
  } catch {
    return undefined;
  }
}

function __bs_numeric(value: any): any {
  if (typeof value === "bigint") {
    return value;
  }
  if (typeof value === "number" && Number.isInteger(value)) {
    return BigInt(value);
  }
  return value;
}

function __bs_literal(value: number): number | bigint {
  if (Number.isInteger(value)) {
    return BigInt(value);
  }
  return value;
}

function __bs_checkCondition(expr: () => any): boolean {
  try {
    const result = expr();
    if (typeof result === "bigint") {
      return result !== 0n;
    }
    return !!result;
  } catch {
    return false;
  }
}

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
    let size = 0;
    size += 8; // v
    return size;
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
    let size = 0;
    size += 8; // v
    return size;
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
    let size = 0;
    size += 1; // v
    return size;
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
    let size = 0;
    size += 1; // pad
    return size;
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
    let size = 0;
    size += 1; // op
    size += 2; // a
    size += 2; // b
    size += 4; // aux
    size += 1; // ty
    size += 4; // snap
    return size;
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
    let size = 0;
    size += 2; // slot
    size += 2; // ref
    return size;
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
    size += 4; // anchor_proto_id
    size += 4; // anchor_pc
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

