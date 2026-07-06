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
