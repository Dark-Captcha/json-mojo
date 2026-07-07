"""Exports the stable tape contract for alternate format front-ends."""

# tape — the PUBLIC face of extension tier 2 (ARCHITECTURE.md): everything a
# binary front-end may use to build or walk this library's six-kind tape.
# The layout — uniform two-word entries `[tag:8 | flags:8 | a:48][b:64]`,
# six tags, skip-links, survivor counts — is a stability-promised contract;
# this module is that contract's front door. Format packages (`msgpack`,
# `bson`, `cbor`, and any future sibling) import from HERE and from the
# public `Document`/`Serializer`/`Value` surfaces — never from
# `json._internal.*`, whose layout may move without notice.
#
# What is deliberately NOT here: the parser's grammar machinery, the SIMD
# stage, byte alphabets, and every other implementation detail. A front-end
# that needs a byte constant defines its own.

from json._internal.bytes import (
    B_BSLASH,
    B_CONTROL_MAX,
    B_QUOTE,
    B_TAB,
    CTRL_BS,
    CTRL_CR,
    CTRL_FF,
    CTRL_LF,
)
from json._internal.number import (
    json5_number_to_float,
    json5_number_to_int64,
    json5_number_to_uint64,
    parse_float,
    parse_int64,
    parse_uint64,
)
from json._internal.tape import (
    FLAG_ARENA,
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
    make_word0,
    skip_past,
)
from json._internal.unicode import (
    decode_escaped_string,
    decode_json5_string,
    validate_utf8_span,
)


comptime _HEX = String("0123456789abcdef")


def append_number_span(mut tape: List[UInt64], mut arena: String, text: String):
    """Appends rendered JSON number text to a decoder arena and emits a tape
    number entry.

    Binary front-ends use this helper instead of pointing number spans into
    their source bytes. The document storage remains valid JSON text only,
    while the tape still carries the same raw-number span contract.

    Args:
        tape: The tape being built.
        arena: The UTF-8 arena owned by the resulting document.
        text: The rendered JSON number text.
    """
    var start = arena.byte_length()
    arena += text
    tape.append(make_word0(TAG_NUMBER, UInt8(0), start))
    tape.append(UInt64(arena.byte_length()))


def append_string_span(
    bytes: Span[UInt8, _],
    mut tape: List[UInt64],
    mut arena: String,
    start: Int,
    end: Int,
) raises:
    """Appends validated string content to a decoder arena and emits a tape
    string entry.

    Clean UTF-8 content is copied as-is with no flags. Content containing JSON
    escape-sensitive bytes (`"`, `\\`, or control bytes) is written as escaped
    JSON string-body text and marked `FLAG_ESCAPED`, matching the parser tape
    invariant.

    Args:
        bytes: The source byte storage.
        tape: The tape being built.
        arena: The UTF-8 arena owned by the resulting document.
        start: The first source byte of the string content.
        end: The exclusive end byte of the string content.

    Raises:
        If the source span is not valid UTF-8.
    """
    var out_start = arena.byte_length()
    var flags = FLAG_ESCAPED if append_string_body(
        bytes, arena, start, end
    ) else UInt8(0)
    tape.append(make_word0(TAG_STRING, flags, out_start))
    tape.append(UInt64(arena.byte_length()))


def append_string_body(
    bytes: Span[UInt8, _],
    mut arena: String,
    start: Int,
    end: Int,
) raises -> Bool:
    """Appends validated JSON string-body text to a decoder arena.

    This is the chunk-level companion to `append_string_span`: definite
    strings use the one-call helper above, while CBOR indefinite text strings
    append several chunks and emit one final tape entry.

    Args:
        bytes: The source byte storage.
        arena: The UTF-8 arena owned by the resulting document.
        start: The first source byte of the string content.
        end: The exclusive end byte of the string content.

    Returns:
        True when the appended body contains JSON escapes and the eventual
        tape entry must be marked `FLAG_ESCAPED`.

    Raises:
        If the source span is not valid UTF-8.
    """
    validate_utf8_span(bytes, start, end)
    var needs_escape = False
    for i in range(start, end):
        var c = bytes[i]
        if c == B_QUOTE or c == B_BSLASH or c < B_CONTROL_MAX:
            needs_escape = True
            break

    if not needs_escape:
        arena += String(unsafe_from_utf8=bytes[start:end])
        return False

    _append_escaped_string_body(arena, bytes, start, end)
    return True


def _append_escaped_string_body(
    mut arena: String, bytes: Span[UInt8, _], start: Int, end: Int
):
    var hex_bytes = _HEX.as_bytes()
    var chunk = List[UInt8]()
    for i in range(start, end):
        var c = bytes[i]
        if c == B_QUOTE:
            chunk.extend('\\"'.as_bytes())
        elif c == B_BSLASH:
            chunk.extend("\\\\".as_bytes())
        elif c == CTRL_BS:
            chunk.extend("\\b".as_bytes())
        elif c == B_TAB:
            chunk.extend("\\t".as_bytes())
        elif c == CTRL_LF:
            chunk.extend("\\n".as_bytes())
        elif c == CTRL_FF:
            chunk.extend("\\f".as_bytes())
        elif c == CTRL_CR:
            chunk.extend("\\r".as_bytes())
        elif c < B_CONTROL_MAX:
            chunk.extend("\\u00".as_bytes())
            chunk.append(hex_bytes[Int((c >> UInt8(4)) & UInt8(0x0F))])
            chunk.append(hex_bytes[Int(c & UInt8(0x0F))])
        else:
            chunk.append(c)
    arena += String(unsafe_from_utf8=chunk)
