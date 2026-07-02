# io — whole documents in and out: JSON Lines (NDJSON), RFC 7464 text
# sequences, and file sugar. All of it is engine-neutral composition over
# `parse` and `dumps` (ROADMAP "Near — capability", landed in 1.1.0): records
# are split at the byte level, then each parses as its own `Document`, so
# every guarantee the engine makes (validation, error offsets, lazy tape)
# holds per record unchanged.
#
# Line records are compact by construction — `dumps` in compact mode never
# emits a newline, so `dumps_lines`/`dumps_seq` output is well-formed framing
# by definition, not by escaping.

from json.document import Document, loads_bytes, parse
from json.serializer import dumps


comptime _LF: UInt8 = UInt8(0x0A)
comptime _CR: UInt8 = UInt8(0x0D)
comptime _RS: UInt8 = UInt8(0x1E)  # RFC 7464 record separator
comptime _SPACE: UInt8 = UInt8(0x20)
comptime _TAB: UInt8 = UInt8(0x09)


def _is_blank(bytes: Span[UInt8, _], start: Int, end: Int) -> Bool:
    for i in range(start, end):
        var b = bytes[i]
        if b != _SPACE and b != _TAB and b != _CR and b != _LF:
            return False
    return True


def _parse_record(
    bytes: Span[UInt8, _], start: Int, end: Int, record: Int, label: String
) raises -> Document:
    """Copy one record's bytes into an owned String and parse it; failures
    carry the record number on top of the engine's byte offset and path."""
    var text = String(unsafe_from_utf8=bytes[start:end])
    try:
        return parse(text^)
    except error:
        raise Error(String(error) + " in " + label + " " + String(record))


def loads_lines(var text: String) raises -> List[Document]:
    """Parse JSON Lines (NDJSON): one document per line, `\\n` or `\\r\\n`
    delimited. Blank lines are skipped. Errors name the 1-based line."""
    var bytes = text.as_bytes()
    var docs = List[Document]()
    var start = 0
    var line = 1
    var length = text.byte_length()
    for i in range(length + 1):
        if i < length and bytes[i] != _LF:
            continue
        var end = i
        if end > start and bytes[end - 1] == _CR:
            end -= 1
        if not _is_blank(bytes, start, end):
            docs.append(_parse_record(bytes, start, end, line, "line"))
        start = i + 1
        line += 1
    return docs^


def dumps_lines(docs: List[Document]) raises -> String:
    """Emit JSON Lines: each document compact on its own `\\n`-terminated
    line."""
    var out = String("")
    for i in range(len(docs)):
        out += dumps(docs[i])
        out += "\n"
    return out^


def loads_seq(var text: String) raises -> List[Document]:
    """Parse an RFC 7464 JSON text sequence: records begin with RS (0x1E).
    Content before the first RS must be blank; blank records are skipped.
    Errors name the 1-based record."""
    var bytes = text.as_bytes()
    var length = text.byte_length()
    var docs = List[Document]()
    var start = 0
    var record = 0
    for i in range(length + 1):
        if i < length and bytes[i] != _RS:
            continue
        if record == 0:
            # Bytes before the first RS: only blankness is a valid preamble.
            if not _is_blank(bytes, start, i):
                raise Error(
                    "json.parse: text sequence must begin with RS (0x1E)"
                )
        elif not _is_blank(bytes, start, i):
            docs.append(_parse_record(bytes, start, i, record, "record"))
        start = i + 1
        record += 1
    return docs^


def dumps_seq(docs: List[Document]) raises -> String:
    """Emit an RFC 7464 text sequence: `RS json LF` per record (§2.2)."""
    var out = String("")
    for i in range(len(docs)):
        out += "\x1e"
        out += dumps(docs[i])
        out += "\n"
    return out^


def load(path: String) raises -> Document:
    """Read a file and parse it — `load` is `loads` for a path. Bytes reach
    this library's validator directly (no decoding layer)."""
    with open(path, "r") as f:
        return loads_bytes(f.read_bytes())


def dump(doc: Document, path: String) raises:
    """Serialize a document (compact) and write it to a file."""
    with open(path, "w") as f:
        f.write(dumps(doc))
