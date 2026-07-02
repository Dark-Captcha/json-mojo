# encoder — the json-mojo tape → MessagePack bytes: `msgpack.dumps` completes
# the transcoding pair (`decode` landed at 1.2.0). The walk is the serializer's
# iterative pattern — innermost frame in locals, ancestors on a heap stack,
# LAST_WINS-shadowed members skipped — emitting the SMALLEST-width encoding
# for every integer (fixint → int8/16/32/64, uint64 above Int64.MAX).
#
# Numbers come off the tape as raw text: Int64 first, UInt64 next, Float64
# last (JSON5 spellings route through the JSON5 readers — and JSON5
# `Infinity`/`NaN` ENCODE here as float64 ±inf/nan, which MessagePack holds
# natively; the asymmetry with `json.dumps`, which refuses them, is the
# formats' own difference, stated).
#
# Strings: a flag-free span IS the decoded content (no escapes occurred) and
# copies straight through; escaped/JSON5 spellings decode first.

from json._internal.number import (
    json5_number_to_float,
    json5_number_to_int64,
    json5_number_to_uint64,
    parse_float,
    parse_int64,
    parse_uint64,
)
from json._internal.tape import (
    FLAG_ESCAPED,
    FLAG_REENCODE,
    FLAG_SHADOWED,
    TAG_ARRAY,
    TAG_BOOLEAN,
    TAG_NULL,
    TAG_NUMBER,
    TAG_OBJECT,
    TAG_STRING,
    entry_a,
    entry_flags,
    entry_tag,
    skip_past,
)
from json._internal.unicode import decode_escaped_string, decode_json5_string
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
    """Encode a whole document as MessagePack — `dumps(doc)` is
    `dumps(doc.root())`."""
    return dumps(doc.root())


def dumps[origin: ImmutOrigin, //](value: Value[origin]) raises -> List[UInt8]:
    """Encode the value under the cursor as MessagePack bytes."""
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
            # `entry` is a member key; shadowed pairs are not live.
            if (entry_flags(word0) & FLAG_SHADOWED) != UInt8(0):
                entry = skip_past(tape, entry + 1)
                continue
            _emit_string(out, bytes, word0, Int(tape[entry * 2 + 1]))
            entry += 1
            word0 = tape[entry * 2]

        var tag = entry_tag(word0)
        if tag == TAG_OBJECT or tag == TAG_ARRAY:
            var is_object = tag == TAG_OBJECT
            _emit_container_header(out, entry_a(word0), is_object)
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
            _emit_string(out, bytes, word0, Int(tape[entry * 2 + 1]))
            entry += 1
        elif tag == TAG_NUMBER:
            _emit_number(out, bytes, word0, Int(tape[entry * 2 + 1]))
            entry += 1
        elif tag == TAG_BOOLEAN:
            out.append(UInt8(0xC3) if entry_a(word0) == 1 else UInt8(0xC2))
            entry += 1
        else:  # TAG_NULL
            out.append(UInt8(0xC0))
            entry += 1


# --- Emitters ----------------------------------------------------------------------


def _be16(mut out: List[UInt8], v: UInt64):
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _be32(mut out: List[UInt8], v: UInt64):
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


def _be64(mut out: List[UInt8], v: UInt64):
    _be32(out, v >> 32)
    _be32(out, v & 0xFFFFFFFF)


def _emit_container_header(
    mut out: List[UInt8], count: Int, is_object: Bool
) raises:
    if is_object:
        if count < 16:
            out.append(UInt8(0x80) | UInt8(count))
        elif count < 65536:
            out.append(UInt8(0xDE))
            _be16(out, UInt64(count))
        else:
            out.append(UInt8(0xDF))
            _be32(out, UInt64(count))
    else:
        if count < 16:
            out.append(UInt8(0x90) | UInt8(count))
        elif count < 65536:
            out.append(UInt8(0xDC))
            _be16(out, UInt64(count))
        else:
            out.append(UInt8(0xDD))
            _be32(out, UInt64(count))


def _emit_str_header(mut out: List[UInt8], n: Int):
    if n < 32:
        out.append(UInt8(0xA0) | UInt8(n))
    elif n < 256:
        out.append(UInt8(0xD9))
        out.append(UInt8(n))
    elif n < 65536:
        out.append(UInt8(0xDA))
        _be16(out, UInt64(n))
    else:
        out.append(UInt8(0xDB))
        _be32(out, UInt64(n))


def _emit_string(
    mut out: List[UInt8], bytes: Span[UInt8, _], word0: UInt64, end: Int
) raises:
    var start = entry_a(word0)
    var flags = entry_flags(word0)
    if (flags & FLAG_REENCODE) != UInt8(0):
        var decoded5 = decode_json5_string(bytes, start, end)
        _emit_str_header(out, decoded5.byte_length())
        out.extend(decoded5.as_bytes())
        return
    if (flags & FLAG_ESCAPED) != UInt8(0):
        var decoded = decode_escaped_string(bytes, start, end)
        _emit_str_header(out, decoded.byte_length())
        out.extend(decoded.as_bytes())
        return
    _emit_str_header(out, end - start)
    out.extend(bytes[start:end])


def _emit_int(mut out: List[UInt8], v: Int64):
    if v >= 0:
        if v < 128:
            out.append(UInt8(v))
        elif v < 256:
            out.append(UInt8(0xCC))
            out.append(UInt8(v))
        elif v < 65536:
            out.append(UInt8(0xCD))
            _be16(out, UInt64(v))
        elif v < 4294967296:
            out.append(UInt8(0xCE))
            _be32(out, UInt64(v))
        else:
            out.append(UInt8(0xD3))
            _be64(out, UInt64(v))
        return
    if v >= -32:
        out.append(UInt8(256 + Int(v)))
    elif v >= -128:
        out.append(UInt8(0xD0))
        out.append(UInt8(Int(v) + 256))
    elif v >= -32768:
        out.append(UInt8(0xD1))
        _be16(out, UInt64(Int(v) + 65536))
    elif v >= -2147483648:
        out.append(UInt8(0xD2))
        _be32(out, UInt64(Int(v) + 4294967296))
    else:
        out.append(UInt8(0xD3))
        _be64(out, UInt64(v))


def _emit_float(mut out: List[UInt8], v: Float64):
    out.append(UInt8(0xCB))
    var bits = UnsafePointer[Float64](to=v).bitcast[UInt64]()[]
    _be64(out, bits)


def _emit_number(
    mut out: List[UInt8], bytes: Span[UInt8, _], word0: UInt64, end: Int
) raises:
    var start = entry_a(word0)
    if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
        # JSON5 spelling: hex/`+`/bare-dot/Infinity/NaN via the JSON5 readers.
        var as_int5 = json5_number_to_int64(bytes, start, end)
        if as_int5:
            _emit_int(out, as_int5.value())
            return
        var as_uint5 = json5_number_to_uint64(bytes, start, end)
        if as_uint5:
            out.append(UInt8(0xCF))
            _be64(out, as_uint5.value())
            return
        var as_float5 = json5_number_to_float(bytes, start, end)
        if as_float5:
            _emit_float(out, as_float5.value())  # ±inf/nan encode natively
            return
        raise Error("msgpack.dumps: number does not fit any encoding")
    var as_int = parse_int64(bytes, start, end)
    if as_int:
        _emit_int(out, as_int.value())
        return
    var as_uint = parse_uint64(bytes, start, end)
    if as_uint:
        out.append(UInt8(0xCF))
        _be64(out, as_uint.value())
        return
    var as_float = parse_float(bytes, start, end)
    if as_float:
        _emit_float(out, as_float.value())
        return
    # Lossless raw text beyond every 64-bit and Float64 range (e.g. a
    # 300-digit integer): MessagePack has no representation for it.
    raise Error("msgpack.dumps: number exceeds every MessagePack numeric type")
