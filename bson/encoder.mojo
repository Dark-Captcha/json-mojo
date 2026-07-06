"""Encodes JSON objects as BSON documents."""

# encoder — the json-mojo tape → BSON bytes. The root must be a JSON object
# (BSON's top level is always a document; an array root is REJECTED by name,
# not silently wrapped). Document byte lengths back-patch through an offset
# stack; array members get their spec-mandated decimal index names.
#
# Numbers: int32 where the value fits, int64 next, double last. A UInt64
# beyond Int64.MAX is REJECTED by name (BSON has no unsigned 64-bit type —
# silently rounding it through a double would violate losslessness). JSON5
# `Infinity`/`NaN` ENCODE as doubles (BSON holds them; decode of such a
# document rejects, because JSON cannot). Member names must be NUL-free
# (BSON cstrings) — a key containing U+0000 is rejected by name.

from json.tape import (
    FLAG_ESCAPED,
    FLAG_REENCODE,
    FLAG_SHADOWED,
    TAG_ARRAY,
    TAG_BOOLEAN,
    TAG_NULL,
    TAG_NUMBER,
    TAG_OBJECT,
    TAG_STRING,
    decode_escaped_string,
    decode_json5_string,
    entry_a,
    entry_flags,
    entry_tag,
    json5_number_to_float,
    json5_number_to_int64,
    json5_number_to_uint64,
    parse_float,
    parse_int64,
    parse_uint64,
    skip_past,
)
from json.document import Document
from json.value import Value, ValueKind


struct _Frame(Copyable, Movable, TrivialRegisterPassable):
    var end_entry: Int
    var len_offset: Int  # where this document's int32 length back-patches
    var index: Int  # next array index name
    var is_array: Bool

    @always_inline
    def __init__(out self, *, end_entry: Int, len_offset: Int, is_array: Bool):
        self.end_entry = end_entry
        self.len_offset = len_offset
        self.index = 0
        self.is_array = is_array


def dumps(doc: Document) raises -> List[UInt8]:
    """Encodes a complete JSON object document as BSON.

    Args:
        doc: The document to encode.

    Returns:
        BSON bytes.

    Raises:
        If the root is not an object or a value has no BSON representation.
    """
    return dumps(doc.root())


def dumps[origin: ImmutOrigin, //](value: Value[origin]) raises -> List[UInt8]:
    """Encodes a lazy JSON object as BSON.

    Parameters:
        origin: The value's borrowed storage origin.

    Args:
        value: The object value to encode.

    Returns:
        BSON bytes.

    Raises:
        If the value is not an object or has no BSON representation.
    """
    if value.kind() != ValueKind.OBJECT:
        raise Error(
            "bson.dumps: BSON's top level is a document — the root must be"
            " a JSON object"
        )
    var bytes = value._bytes
    var tape = value._tape
    var out = List[UInt8](capacity=len(bytes) + 32)
    var stack = List[_Frame](capacity=64)

    var root_word0 = tape[value._entry * 2]
    _open_doc(out, stack, Int(tape[value._entry * 2 + 1]), False)
    _ = root_word0
    var entry = value._entry + 1

    while len(stack) > 0:
        while len(stack) > 0 and entry == stack[len(stack) - 1].end_entry:
            var frame = stack.pop()
            out.append(UInt8(0x00))
            _patch_len(out, frame.len_offset)
        if len(stack) == 0:
            break

        var word0 = tape[entry * 2]
        var name_start = 0
        var name_end = 0
        var name_flags = UInt8(0)
        if stack[len(stack) - 1].is_array:
            pass  # index name generated at emission
        else:
            if (entry_flags(word0) & FLAG_SHADOWED) != UInt8(0):
                entry = skip_past(tape, entry + 1)
                continue
            name_start = entry_a(word0)
            name_end = Int(tape[entry * 2 + 1])
            name_flags = entry_flags(word0)
            entry += 1
            word0 = tape[entry * 2]

        var tag = entry_tag(word0)
        var type_byte: UInt8
        if tag == TAG_OBJECT:
            type_byte = UInt8(0x03)
        elif tag == TAG_ARRAY:
            type_byte = UInt8(0x04)
        elif tag == TAG_STRING:
            type_byte = UInt8(0x02)
        elif tag == TAG_BOOLEAN:
            type_byte = UInt8(0x08)
        elif tag == TAG_NULL:
            type_byte = UInt8(0x0A)
        else:
            type_byte = _number_type(bytes, word0, Int(tape[entry * 2 + 1]))
        out.append(type_byte)
        if stack[len(stack) - 1].is_array:
            _emit_index_name(out, stack[len(stack) - 1].index)
            stack[len(stack) - 1].index += 1
        else:
            _emit_name(out, bytes, name_start, name_end, name_flags)

        if tag == TAG_OBJECT or tag == TAG_ARRAY:
            var end = Int(tape[entry * 2 + 1])
            _open_doc(out, stack, end, tag == TAG_ARRAY)
            entry += 1
        elif tag == TAG_STRING:
            _emit_string(out, bytes, word0, Int(tape[entry * 2 + 1]))
            entry += 1
        elif tag == TAG_BOOLEAN:
            out.append(UInt8(1) if entry_a(word0) == 1 else UInt8(0))
            entry += 1
        elif tag == TAG_NULL:
            entry += 1
        else:  # TAG_NUMBER — type byte already decided the encoding
            _emit_number(out, bytes, word0, Int(tape[entry * 2 + 1]), type_byte)
            entry += 1

    return out^


# --- Emitters ----------------------------------------------------------------------


def _le32_at(mut out: List[UInt8], offset: Int, v: Int):
    out[offset] = UInt8(v & 0xFF)
    out[offset + 1] = UInt8((v >> 8) & 0xFF)
    out[offset + 2] = UInt8((v >> 16) & 0xFF)
    out[offset + 3] = UInt8((v >> 24) & 0xFF)


def _le32_append(mut out: List[UInt8], v: Int):
    out.append(UInt8(v & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 24) & 0xFF))


def _le64_append(mut out: List[UInt8], bits: UInt64):
    for k in range(8):
        out.append(UInt8((bits >> UInt64(8 * k)) & 0xFF))


def _open_doc(
    mut out: List[UInt8],
    mut stack: List[_Frame],
    end_entry: Int,
    is_array: Bool,
) raises:
    if len(stack) >= 1024:
        raise Error("bson.dumps: nesting depth limit exceeded")
    var len_offset = len(out)
    _le32_append(out, 0)  # patched at close
    stack.append(
        _Frame(end_entry=end_entry, len_offset=len_offset, is_array=is_array)
    )


def _patch_len(mut out: List[UInt8], len_offset: Int):
    _le32_at(out, len_offset, len(out) - len_offset)


def _emit_index_name(mut out: List[UInt8], index: Int) raises:
    var name = String(index)
    out.extend(name.as_bytes())
    out.append(UInt8(0x00))


def _decoded_text(
    bytes: Span[UInt8, _], start: Int, end: Int, flags: UInt8
) raises -> String:
    if (flags & FLAG_REENCODE) != UInt8(0):
        return decode_json5_string(bytes, start, end)
    if (flags & FLAG_ESCAPED) != UInt8(0):
        return decode_escaped_string(bytes, start, end)
    return String(unsafe_from_utf8=bytes[start:end])


def _emit_name(
    mut out: List[UInt8],
    bytes: Span[UInt8, _],
    start: Int,
    end: Int,
    flags: UInt8,
) raises:
    var name = _decoded_text(bytes, start, end, flags)
    var raw = name.as_bytes()
    for i in range(len(raw)):
        if raw[i] == UInt8(0x00):
            raise Error(
                "bson.dumps: member names are cstrings — a key containing"
                " U+0000 is not encodable"
            )
    out.extend(raw)
    out.append(UInt8(0x00))


def _emit_string(
    mut out: List[UInt8], bytes: Span[UInt8, _], word0: UInt64, end: Int
) raises:
    var text = _decoded_text(bytes, entry_a(word0), end, entry_flags(word0))
    _le32_append(out, text.byte_length() + 1)
    out.extend(text.as_bytes())
    out.append(UInt8(0x00))


def _number_type(
    bytes: Span[UInt8, _], word0: UInt64, end: Int
) raises -> UInt8:
    """0x10 int32 / 0x12 int64 / 0x01 double — decided before the name is
    written (BSON puts the type byte first)."""
    var start = entry_a(word0)
    if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
        var i5 = json5_number_to_int64(bytes, start, end)
        if i5:
            var v = i5.value()
            if v >= -2147483648 and v < 2147483648:
                return UInt8(0x10)
            return UInt8(0x12)
        if json5_number_to_uint64(bytes, start, end):
            raise Error(
                "bson.dumps: BSON has no unsigned 64-bit type — value"
                " exceeds Int64"
            )
        if json5_number_to_float(bytes, start, end):
            return UInt8(0x01)
        raise Error("bson.dumps: number does not fit any BSON numeric type")
    var i64 = parse_int64(bytes, start, end)
    if i64:
        var v = i64.value()
        if v >= -2147483648 and v < 2147483648:
            return UInt8(0x10)
        return UInt8(0x12)
    if parse_uint64(bytes, start, end):
        raise Error(
            "bson.dumps: BSON has no unsigned 64-bit type — value exceeds"
            " Int64"
        )
    if parse_float(bytes, start, end):
        return UInt8(0x01)
    raise Error("bson.dumps: number exceeds every BSON numeric type")


def _emit_number(
    mut out: List[UInt8],
    bytes: Span[UInt8, _],
    word0: UInt64,
    end: Int,
    type_byte: UInt8,
) raises:
    var start = entry_a(word0)
    var is_json5 = (entry_flags(word0) & FLAG_REENCODE) != UInt8(0)
    if type_byte == UInt8(0x10) or type_byte == UInt8(0x12):
        var v: Int64
        if is_json5:
            v = json5_number_to_int64(bytes, start, end).value()
        else:
            v = parse_int64(bytes, start, end).value()
        if type_byte == UInt8(0x10):
            _le32_append(out, Int(v) & 0xFFFFFFFF)
        else:
            _le64_append(out, UInt64(v))
        return
    var f: Float64
    if is_json5:
        f = json5_number_to_float(bytes, start, end).value()
    else:
        f = parse_float(bytes, start, end).value()
    var bits = UnsafePointer[Float64](to=f).bitcast[UInt64]()[]
    _le64_append(out, bits)
