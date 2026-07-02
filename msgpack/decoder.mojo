# decoder — MessagePack bytes → the json-mojo six-kind tape (extension
# tier 2, ARCHITECTURE.md). The decode loop is iterative (explicit frame
# stack, hostile-input depth cap — msgpack is length-prefixed, so bombs are
# cheap to write), and the output buffer is the APPENDED-TAIL pattern the
# tier-2 contract describes: string spans point zero-copy into the input
# where the bytes are already valid escaped-JSON content; everything the
# tape must carry as text but the input does not contain (numbers, strings
# needing JSON escaping) is rendered once past the input's end.
#
# Type policy (stated, per the tier-2 rule that the six tape tags never
# grow): map keys must be strings; `bin`, `ext`, and non-finite floats are
# REJECTED with named errors — mapping them is a caller decision, not a
# silent one.
#
# Contract discipline: this package imports ONLY `json.tape` (the tier-2
# contract's public front door) and the public `Document`/`Serializer`
# surfaces — never `json._internal.*`. Any out-of-repo sibling gets the
# identical diet.

from json.tape import (
    FLAG_ESCAPED,
    TAG_ARRAY,
    TAG_BOOLEAN,
    TAG_NULL,
    TAG_NUMBER,
    TAG_OBJECT,
    TAG_STRING,
    make_word0,
    validate_utf8_span,
)
from json.document import Document
from json.serializer import Serializer

# Local byte constants — a front-end defines its own alphabet rather than
# importing json's internals (the tier-2 rule: `json.tape` and the public
# surfaces only).
comptime _B_QUOTE: UInt8 = UInt8(0x22)  # "
comptime _B_BSLASH: UInt8 = UInt8(0x5C)  # backslash
comptime _B_CONTROL_MAX: UInt8 = UInt8(0x20)
comptime _CTRL_BS: UInt8 = UInt8(0x08)  # \b
comptime _CTRL_TAB: UInt8 = UInt8(0x09)  # \t
comptime _CTRL_LF: UInt8 = UInt8(0x0A)  # \n
comptime _CTRL_FF: UInt8 = UInt8(0x0C)  # \f
comptime _CTRL_CR: UInt8 = UInt8(0x0D)  # \r


comptime _MAX_DEPTH: Int = 1024

# MessagePack format bytes (msgpack spec §formats) — the whole first-byte
# alphabet, named. Fix-family ranges carry their payload in the low bits.
comptime _POS_FIXINT_MAX: UInt8 = UInt8(0x7F)  # 0x00–0x7f
comptime _FIXMAP_LO: UInt8 = UInt8(0x80)
comptime _FIXMAP_HI: UInt8 = UInt8(0x8F)
comptime _FIXARRAY_LO: UInt8 = UInt8(0x90)
comptime _FIXARRAY_HI: UInt8 = UInt8(0x9F)
comptime _FIXSTR_LO: UInt8 = UInt8(0xA0)
comptime _FIXSTR_HI: UInt8 = UInt8(0xBF)
comptime _F_NIL: UInt8 = UInt8(0xC0)
comptime _F_NEVER: UInt8 = UInt8(0xC1)  # spec: never used
comptime _F_FALSE: UInt8 = UInt8(0xC2)
comptime _F_TRUE: UInt8 = UInt8(0xC3)
comptime _F_BIN8: UInt8 = UInt8(0xC4)
comptime _F_BIN32: UInt8 = UInt8(0xC6)
comptime _F_EXT8: UInt8 = UInt8(0xC7)
comptime _F_EXT32: UInt8 = UInt8(0xC9)
comptime _F_FLOAT32: UInt8 = UInt8(0xCA)
comptime _F_FLOAT64: UInt8 = UInt8(0xCB)
comptime _F_UINT8: UInt8 = UInt8(0xCC)
comptime _F_UINT16: UInt8 = UInt8(0xCD)
comptime _F_UINT32: UInt8 = UInt8(0xCE)
comptime _F_UINT64: UInt8 = UInt8(0xCF)
comptime _F_INT8: UInt8 = UInt8(0xD0)
comptime _F_INT16: UInt8 = UInt8(0xD1)
comptime _F_INT32: UInt8 = UInt8(0xD2)
comptime _F_INT64: UInt8 = UInt8(0xD3)
comptime _F_FIXEXT1: UInt8 = UInt8(0xD4)
comptime _F_FIXEXT16: UInt8 = UInt8(0xD8)
comptime _F_STR8: UInt8 = UInt8(0xD9)
comptime _F_STR16: UInt8 = UInt8(0xDA)
comptime _F_STR32: UInt8 = UInt8(0xDB)
comptime _F_ARRAY16: UInt8 = UInt8(0xDC)
comptime _F_ARRAY32: UInt8 = UInt8(0xDD)
comptime _F_MAP16: UInt8 = UInt8(0xDE)
comptime _F_MAP32: UInt8 = UInt8(0xDF)
comptime _NEG_FIXINT_LO: UInt8 = UInt8(0xE0)  # 0xe0–0xff
comptime _FIXSTR_LEN: UInt8 = UInt8(0x1F)
comptime _FIX_LEN: UInt8 = UInt8(0x0F)
comptime _NIBBLE: UInt8 = UInt8(0x0F)


struct _Frame(Copyable, Movable, TrivialRegisterPassable):
    var tape_entry: Int
    var remaining: Int  # values still to read (map: key+value pairs)
    var is_map: Bool
    var want_key: Bool

    @always_inline
    def __init__(out self, *, tape_entry: Int, remaining: Int, is_map: Bool):
        self.tape_entry = tape_entry
        self.remaining = remaining
        self.is_map = is_map
        self.want_key = is_map


def _error(message: String, offset: Int) raises:
    raise Error("msgpack.decode: " + message + " at byte " + String(offset))


def decode(var bytes: List[UInt8]) raises -> Document:
    """Decode one MessagePack value (any type at the root) into a
    `json.Document`. Raises on truncation, trailing bytes, depth > 1024,
    invalid UTF-8 in strings, non-string map keys, `bin`/`ext` types, and
    non-finite floats — every reject is named."""
    var length = len(bytes)
    var tail = String("")  # rendered numbers + re-escaped strings
    var tape = List[UInt64](capacity=16)
    var stack = List[_Frame]()
    var pos = 0
    var root_done = False

    while True:
        # Close every container whose children are all read; a closed
        # container is itself a completed value in ITS parent.
        while len(stack) > 0 and stack[len(stack) - 1].remaining == 0:
            var frame = stack.pop()
            tape[frame.tape_entry * 2 + 1] = UInt64(len(tape) // 2)
            if len(stack) == 0:
                root_done = True
            elif stack[len(stack) - 1].is_map:
                stack[len(stack) - 1].want_key = True
                stack[len(stack) - 1].remaining -= 1
            else:
                stack[len(stack) - 1].remaining -= 1
        if root_done:
            break
        if pos >= length:
            _error("truncated input", pos)

        var in_map_key = False
        if len(stack) > 0 and stack[len(stack) - 1].is_map:
            in_map_key = stack[len(stack) - 1].want_key

        var b = bytes[pos]
        var value_completed = False

        if in_map_key:
            # RFC 8259 objects key by strings — anything else is policy.
            if not _is_str_format(b):
                _error("map keys must be strings (policy)", pos)

        if b <= _POS_FIXINT_MAX:  # positive fixint
            pos = _emit_int(tape, tail, length, pos, 1, Int64(b))
            value_completed = True
        elif b >= _NEG_FIXINT_LO:  # negative fixint
            pos = _emit_int(tape, tail, length, pos, 1, Int64(b) - 256)
            value_completed = True
        elif b >= _FIXSTR_LO and b <= _FIXSTR_HI:  # fixstr
            pos = _emit_str(
                bytes, pos, 1, Int(b & _FIXSTR_LEN), tape, tail, length
            )
            value_completed = True
        elif b >= _FIXMAP_LO and b <= _FIXMAP_HI:  # fixmap
            pos = _open(tape, stack, pos, 1, Int(b & _FIX_LEN), True)
        elif b >= _FIXARRAY_LO and b <= _FIXARRAY_HI:  # fixarray
            pos = _open(tape, stack, pos, 1, Int(b & _FIX_LEN), False)
        elif b == _F_NIL:  # nil
            tape.append(make_word0(TAG_NULL, UInt8(0), 0))
            tape.append(UInt64(0))
            pos += 1
            value_completed = True
        elif b == _F_FALSE or b == _F_TRUE:  # false / true
            tape.append(
                make_word0(TAG_BOOLEAN, UInt8(0), 1 if b == _F_TRUE else 0)
            )
            tape.append(UInt64(0))
            pos += 1
            value_completed = True
        elif b == _F_FLOAT32:  # float32
            var bits32 = UInt32(_be(bytes, pos + 1, 4, length))
            var f32 = UnsafePointer[UInt32](to=bits32).bitcast[Float32]()[]
            pos = _emit_float(tape, tail, length, pos, 5, Float64(f32))
            value_completed = True
        elif b == _F_FLOAT64:  # float64
            var bits64 = _be(bytes, pos + 1, 8, length)
            var f64 = UnsafePointer[UInt64](to=bits64).bitcast[Float64]()[]
            pos = _emit_float(tape, tail, length, pos, 9, f64)
            value_completed = True
        elif b == _F_UINT8:  # uint8
            pos = _emit_uint(
                tape, tail, length, pos, 2, _be(bytes, pos + 1, 1, length)
            )
            value_completed = True
        elif b == _F_UINT16:  # uint16
            pos = _emit_uint(
                tape, tail, length, pos, 3, _be(bytes, pos + 1, 2, length)
            )
            value_completed = True
        elif b == _F_UINT32:  # uint32
            pos = _emit_uint(
                tape, tail, length, pos, 5, _be(bytes, pos + 1, 4, length)
            )
            value_completed = True
        elif b == _F_UINT64:  # uint64
            pos = _emit_uint(
                tape, tail, length, pos, 9, _be(bytes, pos + 1, 8, length)
            )
            value_completed = True
        elif b == _F_INT8:  # int8
            var v8 = Int64(_be(bytes, pos + 1, 1, length))
            if v8 >= 128:
                v8 -= 256
            pos = _emit_int(tape, tail, length, pos, 2, v8)
            value_completed = True
        elif b == _F_INT16:  # int16
            var v16 = Int64(_be(bytes, pos + 1, 2, length))
            if v16 >= (1 << 15):
                v16 -= 1 << 16
            pos = _emit_int(tape, tail, length, pos, 3, v16)
            value_completed = True
        elif b == _F_INT32:  # int32
            var v32 = Int64(_be(bytes, pos + 1, 4, length))
            if v32 >= (1 << 31):
                v32 -= 1 << 32
            pos = _emit_int(tape, tail, length, pos, 5, v32)
            value_completed = True
        elif b == _F_INT64:  # int64
            var bits = _be(bytes, pos + 1, 8, length)
            var v64: Int64
            if bits >= (UInt64(1) << 63):
                if bits == (UInt64(1) << 63):
                    v64 = Int64.MIN
                else:
                    v64 = -Int64(~bits + 1)
            else:
                v64 = Int64(bits)
            pos = _emit_int(tape, tail, length, pos, 9, v64)
            value_completed = True
        elif b == _F_STR8:  # str8
            var n8 = Int(_be(bytes, pos + 1, 1, length))
            pos = _emit_str(bytes, pos, 2, n8, tape, tail, length)
            value_completed = True
        elif b == _F_STR16:  # str16
            var n16 = Int(_be(bytes, pos + 1, 2, length))
            pos = _emit_str(bytes, pos, 3, n16, tape, tail, length)
            value_completed = True
        elif b == _F_STR32:  # str32
            var n32 = Int(_be(bytes, pos + 1, 4, length))
            pos = _emit_str(bytes, pos, 5, n32, tape, tail, length)
            value_completed = True
        elif b == _F_ARRAY16:  # array16
            pos = _open(
                tape, stack, pos, 3, Int(_be(bytes, pos + 1, 2, length)), False
            )
        elif b == _F_ARRAY32:  # array32
            pos = _open(
                tape, stack, pos, 5, Int(_be(bytes, pos + 1, 4, length)), False
            )
        elif b == _F_MAP16:  # map16
            pos = _open(
                tape, stack, pos, 3, Int(_be(bytes, pos + 1, 2, length)), True
            )
        elif b == _F_MAP32:  # map32
            pos = _open(
                tape, stack, pos, 5, Int(_be(bytes, pos + 1, 4, length)), True
            )
        elif b >= _F_BIN8 and b <= _F_BIN32:
            _error("bin is not representable in JSON (policy: rejected)", pos)
        elif (b >= _F_EXT8 and b <= _F_EXT32) or (
            b >= _F_FIXEXT1 and b <= _F_FIXEXT16
        ):
            _error("ext is not representable in JSON (policy: rejected)", pos)
        else:  # 0xC1
            _error("0xc1 is never a valid format byte", pos)

        # Container/frame bookkeeping for a COMPLETED value.
        if value_completed:
            if len(stack) > 0:
                if stack[len(stack) - 1].is_map:
                    if stack[len(stack) - 1].want_key:
                        stack[len(stack) - 1].want_key = False
                    else:
                        stack[len(stack) - 1].want_key = True
                        stack[len(stack) - 1].remaining -= 1
                else:
                    stack[len(stack) - 1].remaining -= 1
            elif len(tape) > 0:
                root_done = True

    if pos != length:
        _error("trailing bytes after the value", pos)
    if len(tape) == 0:
        _error("no value in input", 0)

    var buffer = String(unsafe_from_utf8=bytes)
    buffer += tail
    return Document(unsafe_buffer=buffer^, unsafe_tape=tape^)


# --- Emission helpers --------------------------------------------------------------


@always_inline
def _is_str_format(b: UInt8) -> Bool:
    return (b >= _FIXSTR_LO and b <= _FIXSTR_HI) or (
        b >= _F_STR8 and b <= _F_STR32
    )


def _be(bytes: List[UInt8], start: Int, n: Int, length: Int) raises -> UInt64:
    """Big-endian read with a truncation check."""
    if start + n > length:
        _error("truncated input", start)
    var value = UInt64(0)
    for i in range(n):
        value = (value << 8) | UInt64(bytes[start + i])
    return value


def _open(
    mut tape: List[UInt64],
    mut stack: List[_Frame],
    pos: Int,
    header: Int,
    count: Int,
    is_map: Bool,
) raises -> Int:
    if len(stack) >= _MAX_DEPTH:
        _error("nesting depth limit exceeded", pos)
    var entry = len(tape) // 2
    tape.append(
        make_word0(TAG_OBJECT if is_map else TAG_ARRAY, UInt8(0), count)
    )
    tape.append(UInt64(0))  # skip patched at close
    stack.append(_Frame(tape_entry=entry, remaining=count, is_map=is_map))
    return pos + header


def _emit_int(
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
    pos: Int,
    header: Int,
    value: Int64,
) raises -> Int:
    var serializer = Serializer(capacity_hint=24)
    serializer.write_int(value)
    var text = serializer^.finish()
    var start = input_length + tail.byte_length()
    tail += text
    tape.append(make_word0(TAG_NUMBER, UInt8(0), start))
    tape.append(UInt64(input_length + tail.byte_length()))
    return pos + header


def _emit_uint(
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
    pos: Int,
    header: Int,
    value: UInt64,
) raises -> Int:
    var serializer = Serializer(capacity_hint=24)
    serializer.write_uint(value)
    var text = serializer^.finish()
    var start = input_length + tail.byte_length()
    tail += text
    tape.append(make_word0(TAG_NUMBER, UInt8(0), start))
    tape.append(UInt64(input_length + tail.byte_length()))
    return pos + header


def _emit_float(
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
    pos: Int,
    header: Int,
    value: Float64,
) raises -> Int:
    var serializer = Serializer(capacity_hint=32)
    try:
        serializer.write_float(value)  # refuses NaN/Infinity — the policy
    except _:
        _ = serializer^.finish()
        _error("non-finite float is not representable in JSON (policy)", pos)
        return 0  # unreachable
    var text = serializer^.finish()
    var start = input_length + tail.byte_length()
    tail += text
    tape.append(make_word0(TAG_NUMBER, UInt8(0), start))
    tape.append(UInt64(input_length + tail.byte_length()))
    return pos + header


def _emit_str(
    bytes: List[UInt8],
    pos: Int,
    header: Int,
    n: Int,
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
) raises -> Int:
    var start = pos + header
    if start + n > input_length:
        _error("truncated string", pos)
    validate_utf8_span(bytes, start, start + n)
    # Clean bodies (no JSON escaping needed) are zero-copy spans into the
    # input; dirty ones render escaped into the tail, marked FLAG_ESCAPED so
    # decoded reads reverse the escaping.
    var dirty = False
    for i in range(start, start + n):
        var c = bytes[i]
        if c == _B_QUOTE or c == _B_BSLASH or c < _B_CONTROL_MAX:
            dirty = True
            break
    if not dirty:
        tape.append(make_word0(TAG_STRING, UInt8(0), start))
        tape.append(UInt64(start + n))
        return start + n
    comptime HEX = "0123456789abcdef"
    var hex_bytes = HEX.as_bytes()
    var out_start = input_length + tail.byte_length()
    # The re-escaped text accumulates as BYTES: escapes are ASCII and every
    # other byte — including multibyte UTF-8 — passes through exactly.
    # Building through `chr` would re-encode bytes >= 0x80 as two-byte code
    # points and silently corrupt non-ASCII text.
    var chunk = List[UInt8]()
    for i in range(start, start + n):
        var c = bytes[i]
        if c == _B_QUOTE:
            chunk.extend('\\"'.as_bytes())
        elif c == _B_BSLASH:
            chunk.extend("\\\\".as_bytes())
        elif c == _CTRL_BS:
            chunk.extend("\\b".as_bytes())
        elif c == _CTRL_TAB:
            chunk.extend("\\t".as_bytes())
        elif c == _CTRL_LF:
            chunk.extend("\\n".as_bytes())
        elif c == _CTRL_FF:
            chunk.extend("\\f".as_bytes())
        elif c == _CTRL_CR:
            chunk.extend("\\r".as_bytes())
        elif c < _B_CONTROL_MAX:
            chunk.extend("\\u00".as_bytes())
            chunk.append(hex_bytes[Int((c >> UInt8(4)) & _NIBBLE)])
            chunk.append(hex_bytes[Int(c & _NIBBLE)])
        else:
            chunk.append(c)
    tail += String(unsafe_from_utf8=chunk)
    tape.append(make_word0(TAG_STRING, FLAG_ESCAPED, out_start))
    tape.append(UInt64(input_length + tail.byte_length()))
    return start + n
