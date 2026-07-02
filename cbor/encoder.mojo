# encoder — the json-mojo tape → CBOR bytes (RFC 8949): shortest-form
# integer heads, definite lengths everywhere, float64 for every decimal
# (valid, deterministic-adjacent CBOR — stated; shortest-float selection is
# a possible refinement). The walk is the shared iterative sibling pattern:
# innermost frame in locals, ancestors on a heap stack, LAST_WINS-shadowed
# members skipped. JSON5 `Infinity`/`NaN` encode as float64 ±inf/nan (CBOR
# holds them; `decode` of such bytes rejects, because JSON cannot).

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
from json.value import Value


struct _WalkFrame(Copyable, Movable, TrivialRegisterPassable):
    var end_entry: Int
    var is_object: Bool

    @always_inline
    def __init__(out self, *, end_entry: Int, is_object: Bool):
        self.end_entry = end_entry
        self.is_object = is_object


def dumps(doc: Document) raises -> List[UInt8]:
    """Encode a whole document as CBOR — `dumps(doc)` is
    `dumps(doc.root())`."""
    return dumps(doc.root())


def dumps[origin: ImmutOrigin, //](value: Value[origin]) raises -> List[UInt8]:
    """Encode the value under the cursor as CBOR bytes."""
    var out = List[UInt8](capacity=len(value._bytes) + 16)
    var bytes = value._bytes
    var tape = value._tape
    var root = value._entry
    var stack = List[_WalkFrame](capacity=64)
    var top_active = False
    var top_end = 0
    var top_is_object = False
    var entry = root
    while True:
        while top_active and entry == top_end:
            if len(stack) > 0:
                var parent = stack.pop()
                top_end = parent.end_entry
                top_is_object = parent.is_object
            else:
                top_active = False
        if not top_active and entry != root:
            return out^

        var word0 = tape[entry * 2]
        if top_active and top_is_object:
            if (entry_flags(word0) & FLAG_SHADOWED) != UInt8(0):
                entry = skip_past(tape, entry + 1)
                continue
            _emit_text(out, bytes, word0, Int(tape[entry * 2 + 1]))
            entry += 1
            word0 = tape[entry * 2]

        var tag = entry_tag(word0)
        if tag == TAG_OBJECT or tag == TAG_ARRAY:
            var is_object = tag == TAG_OBJECT
            _emit_head(
                out, UInt8(5) if is_object else UInt8(4), UInt64(entry_a(word0))
            )
            var end = Int(tape[entry * 2 + 1])
            if end != entry + 1:
                if top_active:
                    stack.append(
                        _WalkFrame(end_entry=top_end, is_object=top_is_object)
                    )
                top_active = True
                top_end = end
                top_is_object = is_object
            entry += 1
        elif tag == TAG_STRING:
            _emit_text(out, bytes, word0, Int(tape[entry * 2 + 1]))
            entry += 1
        elif tag == TAG_NUMBER:
            _emit_number(out, bytes, word0, Int(tape[entry * 2 + 1]))
            entry += 1
        elif tag == TAG_BOOLEAN:
            out.append(UInt8(0xF5) if entry_a(word0) == 1 else UInt8(0xF4))
            entry += 1
        else:  # TAG_NULL
            out.append(UInt8(0xF6))
            entry += 1


# --- Emitters ----------------------------------------------------------------------


def _emit_head(mut out: List[UInt8], major: UInt8, value: UInt64):
    """Shortest-form head (RFC 8949 §4.2.1 core requirement)."""
    var base = major << 5
    if value < 24:
        out.append(base | UInt8(value))
    elif value < 256:
        out.append(base | UInt8(24))
        out.append(UInt8(value))
    elif value < 65536:
        out.append(base | UInt8(25))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    elif value < 4294967296:
        out.append(base | UInt8(26))
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    else:
        out.append(base | UInt8(27))
        for k in range(8):
            out.append(UInt8((value >> UInt64(8 * (7 - k))) & 0xFF))


def _emit_text(
    mut out: List[UInt8], bytes: Span[UInt8, _], word0: UInt64, end: Int
) raises:
    var start = entry_a(word0)
    var flags = entry_flags(word0)
    if (flags & FLAG_REENCODE) != UInt8(0):
        var decoded5 = decode_json5_string(bytes, start, end)
        _emit_head(out, UInt8(3), UInt64(decoded5.byte_length()))
        out.extend(decoded5.as_bytes())
        return
    if (flags & FLAG_ESCAPED) != UInt8(0):
        var decoded = decode_escaped_string(bytes, start, end)
        _emit_head(out, UInt8(3), UInt64(decoded.byte_length()))
        out.extend(decoded.as_bytes())
        return
    _emit_head(out, UInt8(3), UInt64(end - start))
    out.extend(bytes[start:end])


def _emit_int(mut out: List[UInt8], v: Int64):
    if v >= 0:
        _emit_head(out, UInt8(0), UInt64(v))
    else:
        # major 1 argument: -1 - v (Int64.MIN's magnitude-1 fits UInt64).
        var n: UInt64
        if v == Int64.MIN:
            n = UInt64(1) << 63
            n -= 1
        else:
            n = UInt64(-(v + 1))
        _emit_head(out, UInt8(1), n)


def _emit_float(mut out: List[UInt8], v: Float64):
    out.append(UInt8(0xFB))
    var bits = UnsafePointer[Float64](to=v).bitcast[UInt64]()[]
    for k in range(8):
        out.append(UInt8((bits >> UInt64(8 * (7 - k))) & 0xFF))


def _emit_number(
    mut out: List[UInt8], bytes: Span[UInt8, _], word0: UInt64, end: Int
) raises:
    var start = entry_a(word0)
    if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
        var as_int5 = json5_number_to_int64(bytes, start, end)
        if as_int5:
            _emit_int(out, as_int5.value())
            return
        var as_uint5 = json5_number_to_uint64(bytes, start, end)
        if as_uint5:
            _emit_head(out, UInt8(0), as_uint5.value())
            return
        var as_float5 = json5_number_to_float(bytes, start, end)
        if as_float5:
            _emit_float(out, as_float5.value())
            return
        raise Error("cbor.dumps: number does not fit any encoding")
    var as_int = parse_int64(bytes, start, end)
    if as_int:
        _emit_int(out, as_int.value())
        return
    var as_uint = parse_uint64(bytes, start, end)
    if as_uint:
        _emit_head(out, UInt8(0), as_uint.value())
        return
    var as_float = parse_float(bytes, start, end)
    if as_float:
        _emit_float(out, as_float.value())
        return
    raise Error("cbor.dumps: number exceeds every CBOR numeric type")
