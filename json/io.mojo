"""Provides JSON file, JSON Lines, and JSON text-sequence helpers."""

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
    """Parses JSON Lines or NDJSON text.

    Args:
        text: Newline-delimited JSON text taken by move.

    Returns:
        One document per non-blank line.

    Raises:
        If any record is invalid; the error names its one-based line.
    """
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
    """Serializes documents as JSON Lines.

    Args:
        docs: The documents to serialize.

    Returns:
        Compact JSON records terminated by newlines.

    Raises:
        If a document cannot be serialized.
    """
    var out = String("")
    for i in range(len(docs)):
        out += dumps(docs[i])
        out += "\n"
    return out^


def loads_seq(var text: String) raises -> List[Document]:
    """Parses an RFC 7464 JSON text sequence.

    Args:
        text: Record-separator-delimited JSON text taken by move.

    Returns:
        One document per non-blank record.

    Raises:
        If framing or a record is invalid.
    """
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
    """Serializes documents as an RFC 7464 text sequence.

    Args:
        docs: The documents to serialize.

    Returns:
        One `RS json LF` frame per document.

    Raises:
        If a document cannot be serialized.
    """
    var out = String("")
    for i in range(len(docs)):
        out += "\x1e"
        out += dumps(docs[i])
        out += "\n"
    return out^


def load(path: String) raises -> Document:
    """Reads and parses a JSON file.

    Args:
        path: The input file path.

    Returns:
        The parsed document.

    Raises:
        If the file cannot be read or does not contain valid JSON.
    """
    with open(path, "r") as f:
        return loads_bytes(f.read_bytes())


def dump(doc: Document, path: String) raises:
    """Serializes a document to a file.

    Args:
        doc: The document to serialize.
        path: The output file path.

    Raises:
        If serialization or file writing fails.
    """
    with open(path, "w") as f:
        f.write(dumps(doc))
