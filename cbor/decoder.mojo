# decoder — CBOR bytes → the json-mojo six-kind tape (extension tier 2,
# RFC 8949). Iterative frame walk; definite AND indefinite arrays/maps
# (the break byte closes; counts patch at close exactly like the JSON
# parser's frames), indefinite TEXT strings concatenate their definite
# chunks into the appended tail. float16/32/64 all decode (half-precision
# expanded manually).
#
# Type policy (stated; the six tape tags never grow): unsigned and negative
# integers within Int64/UInt64, text strings, arrays, maps with text keys,
# false/true/null, finite floats. REJECTED BY NAME: byte strings (major 2),
# tags (major 6), `undefined`, simple values, non-finite floats, and
# negative integers below Int64.MIN (CBOR reaches -2^64; JSON's lossless
# path has nowhere to hold them).

from json._internal.bytes import B_BSLASH, B_CONTROL_MAX, B_QUOTE
from json._internal.tape import (
    FLAG_ESCAPED,
    TAG_ARRAY,
    TAG_BOOLEAN,
    TAG_NULL,
    TAG_NUMBER,
    TAG_OBJECT,
    TAG_STRING,
    make_word0,
)
from json._internal.unicode import validate_utf8_span
from json.document import Document
from json.serializer import Serializer


comptime _MAX_DEPTH: Int = 1024
comptime _BREAK: UInt8 = UInt8(0xFF)


struct _Frame(Copyable, Movable, TrivialRegisterPassable):
    var tape_entry: Int
    var remaining: Int  # children still expected (definite); -1 = indefinite
    var count: Int  # children seen (patched into the tape at close)
    var is_map: Bool
    var want_key: Bool

    @always_inline
    def __init__(out self, *, tape_entry: Int, remaining: Int, is_map: Bool):
        self.tape_entry = tape_entry
        self.remaining = remaining
        self.count = 0
        self.is_map = is_map
        self.want_key = is_map


def _error(message: String, offset: Int) raises:
    raise Error("cbor.decode: " + message + " at byte " + String(offset))


def _half_to_double(bits: UInt64) -> Float64:
    """IEEE 754 binary16 → binary64 (RFC 8949 Appendix D's algorithm)."""
    var sign = (bits >> 15) & 1
    var exponent = Int((bits >> 10) & 0x1F)
    var mantissa = bits & 0x3FF
    var out_bits: UInt64
    if exponent == 0:
        if mantissa == 0:
            out_bits = sign << 63
        else:
            # Subnormal half: normalize into double.
            var e = -15
            var m = mantissa
            while (m & 0x400) == 0:
                m <<= 1
                e -= 1
            m &= 0x3FF
            out_bits = (
                (sign << 63) | (UInt64(e + 1023 + 1) << 52) | (m << UInt64(42))
            )
    elif exponent == 31:
        out_bits = (sign << 63) | (UInt64(0x7FF) << 52) | (mantissa << 42)
    else:
        out_bits = (
            (sign << 63)
            | (UInt64(exponent - 15 + 1023) << 52)
            | (mantissa << UInt64(42))
        )
    return UnsafePointer[UInt64](to=out_bits).bitcast[Float64]()[]


def decode(var bytes: List[UInt8]) raises -> Document:
    """Decode one CBOR data item (any type at the root) into a
    `json.Document`. Every reject is named."""
    var length = len(bytes)
    var tail = String("")
    var tape = List[UInt64](capacity=16)
    var stack = List[_Frame]()
    var pos = 0
    var root_done = False

    while True:
        # Close definite containers whose children are all read; a closed
        # container is itself a completed value in ITS parent.
        while len(stack) > 0 and stack[len(stack) - 1].remaining == 0:
            _close_frame(tape, stack)
            if len(stack) == 0:
                root_done = True
            else:
                _complete_child(stack)
        if root_done:
            break
        if pos >= length:
            _error("truncated input", pos)

        var initial = bytes[pos]

        # Break: closes the innermost INDEFINITE container.
        if initial == _BREAK:
            if len(stack) == 0 or stack[len(stack) - 1].remaining != -1:
                _error("break outside an indefinite container", pos)
            if (
                stack[len(stack) - 1].is_map
                and not stack[len(stack) - 1].want_key
            ):
                _error("break splits a map pair", pos)
            _close_frame(tape, stack)
            pos += 1
            if len(stack) == 0:
                break
            _complete_child(stack)
            continue

        var in_map_key = False
        if len(stack) > 0 and stack[len(stack) - 1].is_map:
            in_map_key = stack[len(stack) - 1].want_key

        var major = initial >> 5
        var additional = initial & UInt8(0x1F)
        var value_completed = False

        if in_map_key and major != UInt8(3):
            _error("map keys must be text strings (policy)", pos)

        if major == UInt8(0):  # unsigned int
            var next0 = 0
            var v = _argument(bytes, pos, additional, length, next0)
            pos = next0
            if v > UInt64(Int64.MAX):
                _emit_uint_text(tape, tail, length, v)
            else:
                _emit_int_text(tape, tail, length, Int64(v))
            value_completed = True
        elif major == UInt8(1):  # negative int: -1 - n
            var next1 = 0
            var n = _argument(bytes, pos, additional, length, next1)
            pos = next1
            if n >= UInt64(1) << 63:
                _error(
                    "negative integer below Int64.MIN is not representable"
                    " (policy)",
                    pos,
                )
            var v1 = -1 - Int64(n)
            _emit_int_text(tape, tail, length, v1)
            value_completed = True
        elif major == UInt8(2):
            _error("byte strings are not representable in JSON (policy)", pos)
        elif major == UInt8(3):  # text string
            pos = _emit_text(bytes, tape, tail, length, pos, additional)
            value_completed = True
        elif major == UInt8(4) or major == UInt8(5):  # array / map
            var is_map = major == UInt8(5)
            if len(stack) >= _MAX_DEPTH:
                _error("nesting depth limit exceeded", pos)
            var entry = len(tape) // 2
            tape.append(
                make_word0(TAG_OBJECT if is_map else TAG_ARRAY, UInt8(0), 0)
            )
            tape.append(UInt64(0))
            if additional == UInt8(31):  # indefinite
                stack.append(
                    _Frame(tape_entry=entry, remaining=-1, is_map=is_map)
                )
                pos += 1
            else:
                var next2 = 0
                var count = Int(
                    _argument(bytes, pos, additional, length, next2)
                )
                pos = next2
                stack.append(
                    _Frame(
                        tape_entry=entry,
                        remaining=count,
                        is_map=is_map,
                    )
                )
            continue
        elif major == UInt8(6):
            _error("tags are not representable in JSON (policy)", pos)
        else:  # major 7: simple + floats
            if additional == UInt8(20) or additional == UInt8(21):
                tape.append(
                    make_word0(
                        TAG_BOOLEAN,
                        UInt8(0),
                        1 if additional == UInt8(21) else 0,
                    )
                )
                tape.append(UInt64(0))
                pos += 1
            elif additional == UInt8(22):  # null
                tape.append(make_word0(TAG_NULL, UInt8(0), 0))
                tape.append(UInt64(0))
                pos += 1
            elif additional == UInt8(23):
                _error("undefined is not representable in JSON (policy)", pos)
            elif additional == UInt8(25):  # float16
                var h = _be(bytes, pos + 1, 2, length)
                _emit_float(tape, tail, length, pos, _half_to_double(h))
                pos += 3
            elif additional == UInt8(26):  # float32
                var b32 = UInt32(_be(bytes, pos + 1, 4, length))
                var f32 = UnsafePointer[UInt32](to=b32).bitcast[Float32]()[]
                _emit_float(tape, tail, length, pos, Float64(f32))
                pos += 5
            elif additional == UInt8(27):  # float64
                var b64 = _be(bytes, pos + 1, 8, length)
                var f64 = UnsafePointer[UInt64](to=b64).bitcast[Float64]()[]
                _emit_float(tape, tail, length, pos, f64)
                pos += 9
            else:
                _error(
                    "simple values are not representable in JSON (policy)", pos
                )
            value_completed = True

        if value_completed:
            if len(stack) > 0:
                _complete_child(stack)
            elif len(tape) > 0:
                root_done = True

    if pos != length:
        _error("trailing bytes after the value", pos)
    if len(tape) == 0:
        _error("no value in input", 0)

    var buffer = String(unsafe_from_utf8=bytes)
    buffer += tail
    return Document(unsafe_buffer=buffer^, unsafe_tape=tape^)


def _close_frame(mut tape: List[UInt64], mut stack: List[_Frame]):
    var frame = stack.pop()
    tape[frame.tape_entry * 2] = make_word0(
        TAG_OBJECT if frame.is_map else TAG_ARRAY, UInt8(0), frame.count
    )
    tape[frame.tape_entry * 2 + 1] = UInt64(len(tape) // 2)


def _complete_child(mut stack: List[_Frame]):
    if stack[len(stack) - 1].is_map:
        if stack[len(stack) - 1].want_key:
            stack[len(stack) - 1].want_key = False
            return  # a key does not finish the pair
        stack[len(stack) - 1].want_key = True
    stack[len(stack) - 1].count += 1
    if stack[len(stack) - 1].remaining > 0:
        stack[len(stack) - 1].remaining -= 1


def _argument(
    bytes: List[UInt8],
    pos: Int,
    additional: UInt8,
    length: Int,
    mut next_pos: Int,
) raises -> UInt64:
    """The head's argument value; `next_pos` lands just past the head."""
    if additional < UInt8(24):
        next_pos = pos + 1
        return UInt64(additional)
    if additional == UInt8(24):
        next_pos = pos + 2
        return _be(bytes, pos + 1, 1, length)
    if additional == UInt8(25):
        next_pos = pos + 3
        return _be(bytes, pos + 1, 2, length)
    if additional == UInt8(26):
        next_pos = pos + 5
        return _be(bytes, pos + 1, 4, length)
    if additional == UInt8(27):
        next_pos = pos + 9
        return _be(bytes, pos + 1, 8, length)
    _error("reserved additional-information value", pos)
    return UInt64(0)  # unreachable


def _be(bytes: List[UInt8], start: Int, n: Int, length: Int) raises -> UInt64:
    if start + n > length:
        _error("truncated input", start)
    var v = UInt64(0)
    for i in range(n):
        v = (v << 8) | UInt64(bytes[start + i])
    return v


def _emit_int_text(
    mut tape: List[UInt64], mut tail: String, input_length: Int, v: Int64
) raises:
    var s = Serializer(capacity_hint=24)
    s.write_int(v)
    _append_number(tape, tail, input_length, s^.finish())


def _emit_uint_text(
    mut tape: List[UInt64], mut tail: String, input_length: Int, v: UInt64
) raises:
    var s = Serializer(capacity_hint=24)
    s.write_uint(v)
    _append_number(tape, tail, input_length, s^.finish())


def _emit_float(
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
    pos: Int,
    v: Float64,
) raises:
    var s = Serializer(capacity_hint=32)
    try:
        s.write_float(v)  # refuses non-finite: the policy
    except _:
        _ = s^.finish()
        _error("non-finite float is not representable in JSON (policy)", pos)
        return
    _append_number(tape, tail, input_length, s^.finish())


def _append_number(
    mut tape: List[UInt64], mut tail: String, input_length: Int, text: String
):
    var start = input_length + tail.byte_length()
    tail += text
    tape.append(make_word0(TAG_NUMBER, UInt8(0), start))
    tape.append(UInt64(input_length + tail.byte_length()))


def _emit_text(
    bytes: List[UInt8],
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
    pos: Int,
    additional: UInt8,
) raises -> Int:
    """A text string — definite (zero-copy span where clean) or indefinite
    (definite chunks concatenated into the tail, RFC 8949 §3.2.3)."""
    if additional != UInt8(31):
        var start = 0
        var n = Int(_argument(bytes, pos, additional, input_length, start))
        if start + n > input_length:
            _error("truncated text string", pos)
        _emit_text_span(bytes, tape, tail, input_length, start, start + n)
        return start + n
    # Indefinite: chunks must be DEFINITE text strings; break ends it.
    var scan = pos + 1
    var out_start = input_length + tail.byte_length()
    var any_bytes = False
    while True:
        if scan >= input_length:
            _error("unterminated indefinite text string", pos)
        var b = bytes[scan]
        if b == _BREAK:
            scan += 1
            break
        if (b >> 5) != UInt8(3) or (b & UInt8(0x1F)) == UInt8(31):
            _error("indefinite text chunks must be definite text", scan)
        var cstart = 0
        var n = Int(
            _argument(bytes, scan, b & UInt8(0x1F), input_length, cstart)
        )
        if cstart + n > input_length:
            _error("truncated text chunk", scan)
        validate_utf8_span(bytes, cstart, cstart + n)
        _escape_into_tail(bytes, tail, cstart, cstart + n)
        any_bytes = True
        scan = cstart + n
    _ = any_bytes
    tape.append(make_word0(TAG_STRING, FLAG_ESCAPED, out_start))
    tape.append(UInt64(input_length + tail.byte_length()))
    return scan


def _emit_text_span(
    bytes: List[UInt8],
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
    start: Int,
    end: Int,
) raises:
    validate_utf8_span(bytes, start, end)
    var dirty = False
    for i in range(start, end):
        var c = bytes[i]
        if c == B_QUOTE or c == B_BSLASH or c < B_CONTROL_MAX:
            dirty = True
            break
    if not dirty:
        tape.append(make_word0(TAG_STRING, UInt8(0), start))
        tape.append(UInt64(end))
        return
    var out_start = input_length + tail.byte_length()
    _escape_into_tail(bytes, tail, start, end)
    tape.append(make_word0(TAG_STRING, FLAG_ESCAPED, out_start))
    tape.append(UInt64(input_length + tail.byte_length()))


def _escape_into_tail(
    bytes: List[UInt8], mut tail: String, start: Int, end: Int
):
    comptime HEX = "0123456789abcdef"
    var hex_bytes = HEX.as_bytes()
    for i in range(start, end):
        var c = bytes[i]
        if c == B_QUOTE:
            tail += '\\"'
        elif c == B_BSLASH:
            tail += "\\\\"
        elif c == UInt8(0x08):
            tail += "\\b"
        elif c == UInt8(0x09):
            tail += "\\t"
        elif c == UInt8(0x0A):
            tail += "\\n"
        elif c == UInt8(0x0C):
            tail += "\\f"
        elif c == UInt8(0x0D):
            tail += "\\r"
        elif c < B_CONTROL_MAX:
            tail += "\\u00"
            tail += chr(Int(hex_bytes[Int((c >> UInt8(4)) & UInt8(0x0F))]))
            tail += chr(Int(hex_bytes[Int(c & UInt8(0x0F))]))
        else:
            tail += chr(Int(c))
