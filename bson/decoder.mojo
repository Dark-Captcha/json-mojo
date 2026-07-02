# decoder — BSON bytes → the json-mojo six-kind tape (extension tier 2,
# bsonspec.org v1.1). Iterative frame walk (documents carry their byte
# length up front; the trailing 0x00 closes each), appended-tail pattern for
# rendered number text and re-escaped strings, hostile-input depth cap.
#
# Type policy (stated; the six tape tags never grow): double (0x01, finite
# only), string (0x02), document (0x03), array (0x04 — element order is
# taken as-is; the spec's decimal index keys are not re-validated), bool
# (0x08), null (0x0A), int32 (0x10), int64 (0x12). Everything else —
# binary, undefined, ObjectId, datetime, regex, DBPointer, code, symbol,
# code-with-scope, timestamp, decimal128, min/max keys — is REJECTED by
# name: mapping them into JSON is a caller decision, never a silent one.

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

comptime _T_DOUBLE: UInt8 = UInt8(0x01)
comptime _T_STRING: UInt8 = UInt8(0x02)
comptime _T_DOC: UInt8 = UInt8(0x03)
comptime _T_ARRAY: UInt8 = UInt8(0x04)
comptime _T_BINARY: UInt8 = UInt8(0x05)
comptime _T_UNDEFINED: UInt8 = UInt8(0x06)
comptime _T_OBJECTID: UInt8 = UInt8(0x07)
comptime _T_BOOL: UInt8 = UInt8(0x08)
comptime _T_DATETIME: UInt8 = UInt8(0x09)
comptime _T_NULL: UInt8 = UInt8(0x0A)
comptime _T_REGEX: UInt8 = UInt8(0x0B)
comptime _T_DBPOINTER: UInt8 = UInt8(0x0C)
comptime _T_CODE: UInt8 = UInt8(0x0D)
comptime _T_SYMBOL: UInt8 = UInt8(0x0E)
comptime _T_CODE_W_S: UInt8 = UInt8(0x0F)
comptime _T_INT32: UInt8 = UInt8(0x10)
comptime _T_TIMESTAMP: UInt8 = UInt8(0x11)
comptime _T_INT64: UInt8 = UInt8(0x12)
comptime _T_DECIMAL128: UInt8 = UInt8(0x13)
comptime _T_MINKEY: UInt8 = UInt8(0xFF)
comptime _T_MAXKEY: UInt8 = UInt8(0x7F)


struct _Frame(Copyable, Movable, TrivialRegisterPassable):
    var tape_entry: Int
    var end_pos: Int  # byte offset of this document's trailing 0x00
    var count: Int
    var is_array: Bool

    @always_inline
    def __init__(out self, *, tape_entry: Int, end_pos: Int, is_array: Bool):
        self.tape_entry = tape_entry
        self.end_pos = end_pos
        self.count = 0
        self.is_array = is_array


def _error(message: String, offset: Int) raises:
    raise Error("bson.decode: " + message + " at byte " + String(offset))


def _le32(bytes: List[UInt8], at: Int, length: Int) raises -> Int:
    if at + 4 > length:
        _error("truncated int32", at)
    return (
        Int(bytes[at])
        | (Int(bytes[at + 1]) << 8)
        | (Int(bytes[at + 2]) << 16)
        | (Int(bytes[at + 3]) << 24)
    )


def _le64(bytes: List[UInt8], at: Int, length: Int) raises -> UInt64:
    if at + 8 > length:
        _error("truncated int64", at)
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(bytes[at + k]) << UInt64(8 * k)
    return v


def _u64_to_i64(bits: UInt64) -> Int64:
    if bits >= (UInt64(1) << 63):
        if bits == (UInt64(1) << 63):
            return Int64.MIN
        return -Int64(~bits + 1)
    return Int64(bits)


def decode(var bytes: List[UInt8]) raises -> Document:
    """Decode one BSON document (the root is always an object) into a
    `json.Document`. Raises on truncation, trailing bytes, length
    mismatches, depth > 1024, invalid UTF-8, non-finite doubles, and every
    JSON-unrepresentable BSON type — each reject is named."""
    var length = len(bytes)
    var tail = String("")
    var tape = List[UInt64](capacity=16)
    var stack = List[_Frame]()

    if length < 5:
        _error("input shorter than an empty document", 0)
    var root_len = _le32(bytes, 0, length)
    if root_len != length:
        _error("document length does not match input", 0)

    var entry0 = len(tape) // 2
    tape.append(make_word0(TAG_OBJECT, UInt8(0), 0))
    tape.append(UInt64(0))
    stack.append(_Frame(tape_entry=entry0, end_pos=length - 1, is_array=False))
    var pos = 4

    while len(stack) > 0:
        var frame_end = stack[len(stack) - 1].end_pos
        if pos == frame_end:
            if bytes[pos] != UInt8(0x00):
                _error("document missing its trailing 0x00", pos)
            var frame = stack.pop()
            var word0 = tape[frame.tape_entry * 2]
            tape[frame.tape_entry * 2] = make_word0(
                TAG_ARRAY if frame.is_array else TAG_OBJECT,
                UInt8(0),
                frame.count,
            )
            tape[frame.tape_entry * 2 + 1] = UInt64(len(tape) // 2)
            _ = word0
            pos += 1
            continue
        if pos > frame_end:
            _error("element overruns its document", pos)

        var element_type = bytes[pos]
        pos += 1
        # cstring element name.
        var name_start = pos
        while pos < length and bytes[pos] != UInt8(0x00):
            pos += 1
        if pos >= length:
            _error("unterminated element name", name_start)
        var name_end = pos
        pos += 1
        if not stack[len(stack) - 1].is_array:
            _emit_string_span(bytes, tape, tail, length, name_start, name_end)
        # (array index names are read and dropped — order is authoritative)

        if element_type == _T_DOUBLE:
            var bits = _le64(bytes, pos, length)
            var f = UnsafePointer[UInt64](to=bits).bitcast[Float64]()[]
            if f != f or f > Float64.MAX_FINITE or f < -Float64.MAX_FINITE:
                _error("non-finite double is not representable in JSON", pos)
            var s = Serializer(capacity_hint=32)
            s.write_float(f)
            _append_number_text(tape, tail, length, s^.finish())
            pos += 8
        elif element_type == _T_STRING:
            var slen = _le32(bytes, pos, length)  # includes trailing 0x00
            if slen < 1 or pos + 4 + slen > length:
                _error("string length out of bounds", pos)
            var s_start = pos + 4
            var s_end = s_start + slen - 1
            if bytes[s_end] != UInt8(0x00):
                _error("string missing its trailing 0x00", s_end)
            _emit_string_span(bytes, tape, tail, length, s_start, s_end)
            stack[len(stack) - 1].count += 1
            pos = s_end + 1
            continue
        elif element_type == _T_DOC or element_type == _T_ARRAY:
            if len(stack) >= _MAX_DEPTH:
                _error("nesting depth limit exceeded", pos)
            var dlen = _le32(bytes, pos, length)
            if dlen < 5 or pos + dlen > length:
                _error("document length out of bounds", pos)
            var child_entry = len(tape) // 2
            var child_is_array = element_type == _T_ARRAY
            tape.append(
                make_word0(
                    TAG_ARRAY if child_is_array else TAG_OBJECT, UInt8(0), 0
                )
            )
            tape.append(UInt64(0))
            stack[len(stack) - 1].count += 1
            stack.append(
                _Frame(
                    tape_entry=child_entry,
                    end_pos=pos + dlen - 1,
                    is_array=child_is_array,
                )
            )
            pos += 4
            continue
        elif element_type == _T_BOOL:
            if pos >= length:
                _error("truncated bool", pos)
            var b = bytes[pos]
            if b > UInt8(1):
                _error("bool byte must be 0x00 or 0x01", pos)
            tape.append(make_word0(TAG_BOOLEAN, UInt8(0), Int(b)))
            tape.append(UInt64(0))
            pos += 1
        elif element_type == _T_NULL:
            tape.append(make_word0(TAG_NULL, UInt8(0), 0))
            tape.append(UInt64(0))
        elif element_type == _T_INT32:
            var v32 = _le32(bytes, pos, length)
            if v32 >= (1 << 31):
                v32 -= 1 << 32
            var s32 = Serializer(capacity_hint=16)
            s32.write_int(Int64(v32))
            _append_number_text(tape, tail, length, s32^.finish())
            pos += 4
        elif element_type == _T_INT64:
            var v64 = _u64_to_i64(_le64(bytes, pos, length))
            var s64 = Serializer(capacity_hint=24)
            s64.write_int(v64)
            _append_number_text(tape, tail, length, s64^.finish())
            pos += 8
        elif element_type == _T_BINARY:
            _error("binary is not representable in JSON (policy)", pos)
        elif element_type == _T_UNDEFINED:
            _error("undefined is not representable in JSON (policy)", pos)
        elif element_type == _T_OBJECTID:
            _error("ObjectId is not representable in JSON (policy)", pos)
        elif element_type == _T_DATETIME:
            _error("datetime is not representable in JSON (policy)", pos)
        elif element_type == _T_REGEX:
            _error("regex is not representable in JSON (policy)", pos)
        elif element_type == _T_DBPOINTER:
            _error("DBPointer is not representable in JSON (policy)", pos)
        elif element_type == _T_CODE or element_type == _T_CODE_W_S:
            _error("code is not representable in JSON (policy)", pos)
        elif element_type == _T_SYMBOL:
            _error("symbol is not representable in JSON (policy)", pos)
        elif element_type == _T_TIMESTAMP:
            _error("timestamp is not representable in JSON (policy)", pos)
        elif element_type == _T_DECIMAL128:
            _error("decimal128 is not representable in JSON (policy)", pos)
        elif element_type == _T_MINKEY or element_type == _T_MAXKEY:
            _error("min/max keys are not representable in JSON (policy)", pos)
        else:
            _error("unknown element type", pos - 1)
        stack[len(stack) - 1].count += 1

    if pos != length:
        _error("trailing bytes after the document", pos)

    var buffer = String(unsafe_from_utf8=bytes)
    buffer += tail
    return Document(unsafe_buffer=buffer^, unsafe_tape=tape^)


def _append_number_text(
    mut tape: List[UInt64], mut tail: String, input_length: Int, text: String
):
    var start = input_length + tail.byte_length()
    tail += text
    tape.append(make_word0(TAG_NUMBER, UInt8(0), start))
    tape.append(UInt64(input_length + tail.byte_length()))


def _emit_string_span(
    bytes: List[UInt8],
    mut tape: List[UInt64],
    mut tail: String,
    input_length: Int,
    start: Int,
    end: Int,
) raises:
    """UTF-8-validate a BSON string/name span; clean content is a zero-copy
    span into the input, content needing JSON escaping renders into the
    tail (the msgpack sibling's exact pattern)."""
    validate_utf8_span(bytes, start, end)
    var dirty = False
    for i in range(start, end):
        var c = bytes[i]
        if c == _B_QUOTE or c == _B_BSLASH or c < _B_CONTROL_MAX:
            dirty = True
            break
    if not dirty:
        tape.append(make_word0(TAG_STRING, UInt8(0), start))
        tape.append(UInt64(end))
        return
    comptime HEX = "0123456789abcdef"
    var hex_bytes = HEX.as_bytes()
    var out_start = input_length + tail.byte_length()
    # The re-escaped text accumulates as BYTES: escapes are ASCII and every
    # other byte — including multibyte UTF-8 — passes through exactly.
    # Building through `chr` would re-encode bytes >= 0x80 as two-byte code
    # points and silently corrupt non-ASCII text.
    var chunk = List[UInt8]()
    for i in range(start, end):
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
            chunk.append(hex_bytes[Int((c >> UInt8(4)) & UInt8(0x0F))])
            chunk.append(hex_bytes[Int(c & UInt8(0x0F))])
        else:
            chunk.append(c)
    tail += String(unsafe_from_utf8=chunk)
    tape.append(make_word0(TAG_STRING, FLAG_ESCAPED, out_start))
    tape.append(UInt64(input_length + tail.byte_length()))
