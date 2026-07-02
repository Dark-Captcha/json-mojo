# Document — the parse result: owns the moved-in input String plus the
# six-kind tape, and exposes its root's access surface directly so `loads`
# returns it without any cursor outliving its bytes (ARCHITECTURE.md,
# Public Surface). Ownership is what makes stage 1 legal: the constructor
# reserves BLOCK_WIDTH bytes of tail padding (probed: String.reserve), so
# every 64-byte block load stays in bounds.
#
# The parse pipeline: rule on a leading BOM (RFC 8259 §8.1: skipped in
# standard mode, an error in I-JSON) → reserve tail padding → stage 1 builds
# the structural index → stage 2 validates the grammar, validates string
# bodies (incl. lazy per-body UTF-8 — the grammar confines non-ASCII to
# string bodies, so there is no whole-input pass), and builds the tape.

from std.builtin.rebind import rebind

from json._internal.bytes import B_BOM_0, B_BOM_1, B_BOM_2
from json._internal.simd import BLOCK_WIDTH
from json._internal.stage_one import build_structural_index
from json._internal.json5 import build_tape_json5
from json._internal.tape import build_tape
from json.options import Dialect, ParseMode, ParseOptions
from json.value import (
    Value,
    ValueKind,
    _ConvertBase,
    _ElementIter,
    _MemberIter,
)


struct Document(Movable):
    """A parsed JSON document: input bytes and tape, one owner, no copies."""

    var _input: String
    var _tape: List[UInt64]

    def __init__(out self, *, var input: String, var tape: List[UInt64]):
        self._input = input^
        self._tape = tape^

    def __init__(
        out self, *, var unsafe_buffer: String, var unsafe_tape: List[UInt64]
    ):
        """Extension tier 2's entry: wrap a decoder-built buffer + tape as a
        Document — every consumer (cursor, serde, `dumps`) is inherited
        unchanged. UNSAFE: the caller vouches that the tape is a well-formed
        six-kind tape (ARCHITECTURE.md, Layer 1), every span is in-bounds,
        string spans are UTF-8-validated *escaped-JSON* content, and number
        spans are RFC 8259 number grammar. Decoder-rendered text (numbers,
        re-escaped strings) lives PAST the original input in the same buffer
        — the appended-tail pattern; `FLAG_ARENA` stays reserved for true
        side-arenas. Tail padding is (re)established here."""
        unsafe_buffer.reserve(unsafe_buffer.byte_length() + BLOCK_WIDTH)
        self._input = unsafe_buffer^
        self._tape = unsafe_tape^

    # --- The root's access surface, forwarded ----------------------------------

    def root(ref self) -> Value[origin_of(self)]:
        """The document's root value as a lazy cursor. Field origins widen
        to the whole document's origin — safe (the fields live exactly as
        long as the document) and it keeps `Value` to a single origin."""
        return Value[origin_of(self)](
            bytes=rebind[Span[UInt8, origin_of(self)]](self._input.as_bytes()),
            tape=rebind[Span[UInt64, origin_of(self)]](Span(self._tape)),
            entry=0,
        )

    @always_inline
    def kind(ref self) -> ValueKind:
        return self.root().kind()

    def __len__(ref self) raises -> Int:
        return self.root().__len__()

    def __getitem__(ref self, key: String) raises -> Value[origin_of(self)]:
        return self.root()[key]

    def __getitem__(ref self, index: Int) raises -> Value[origin_of(self)]:
        return self.root()[index]

    def to[T: _ConvertBase](ref self) raises -> T:
        return self.root().to[T]()

    def elements(ref self) raises -> _ElementIter[origin_of(self)]:
        return self.root().elements()

    def members(ref self) raises -> _MemberIter[origin_of(self)]:
        return self.root().members()

    def at(ref self, pointer: String) raises -> Value[origin_of(self)]:
        return self.root().at(pointer)


# --- Parsing entry points --------------------------------------------------------


def parse[
    options: ParseOptions = ParseOptions()
](var text: String) raises -> Document:
    """Parse `text` (taken by move — `parse(body^)`; temporaries need
    nothing; keep your copy with `parse(text.copy())`)."""
    var start = 0
    var length = text.byte_length()
    if length >= 3:
        var head = text.as_bytes()
        if head[0] == B_BOM_0 and head[1] == B_BOM_1 and head[2] == B_BOM_2:
            comptime if options.mode == ParseMode.I_JSON:
                raise Error(
                    "json.parse: byte-order mark rejected in I-JSON mode"
                    " at byte 0"
                )
            else:
                start = 3

    # The stage-1 padding contract (probed: capacity grows, content intact).
    text.reserve(length + BLOCK_WIDTH)

    comptime if options.dialect == Dialect.JSON5:
        comptime assert options.mode == ParseMode.STANDARD, (
            "json.parse: I-JSON is an RFC 8259 profile — it cannot govern"
            " JSON5 text"
        )
        var tape5 = build_tape_json5[options](text, start)
        return Document(input=text^, tape=tape5^)
    else:
        var index = build_structural_index(text)
        var tape = build_tape[options](text, index, start)
        return Document(input=text^, tape=tape^)


def loads(var text: String) raises -> Document:
    """`parse` with default options — the Python-named minute-one verb."""
    return parse(text^)


def loads_bytes(var bytes: List[UInt8]) raises -> Document:
    """`loads` from raw bytes — network bodies arrive as bytes, and invalid
    UTF-8 must reach OUR validator (RFC 8259 §8.1), not a decoding layer."""
    return parse(String(unsafe_from_utf8=bytes))


def try_parse[
    options: ParseOptions = ParseOptions()
](var text: String) -> Optional[Document]:
    """`parse`, returning None instead of raising."""
    try:
        return parse[options](text^)
    except error:
        return None
