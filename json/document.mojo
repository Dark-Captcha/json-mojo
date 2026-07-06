"""Defines owned parsed JSON documents and parsing entry points."""

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
        """Creates a document from validated input and tape storage.

        Args:
            input: The owned source text.
            tape: The validated six-kind tape.
        """
        self._input = input^
        self._tape = tape^

    def __init__(
        out self, *, var unsafe_buffer: String, var unsafe_tape: List[UInt64]
    ):
        """Wraps a decoder-built buffer and tape as a document.

        Args:
            unsafe_buffer: The owned source and decoder arena bytes.
            unsafe_tape: A well-formed six-kind tape whose spans reference
                `unsafe_buffer`.

        The caller must guarantee that every span is in bounds, strings hold
        validated escaped JSON content, and numbers follow RFC 8259 grammar.
        """
        unsafe_buffer.reserve(unsafe_buffer.byte_length() + BLOCK_WIDTH)
        self._input = unsafe_buffer^
        self._tape = unsafe_tape^

    # --- The root's access surface, forwarded ----------------------------------

    def root(ref self) -> Value[origin_of(self)]:
        """Gets the document's root as a lazy cursor.

        Returns:
            A value borrowing the document's input and tape.
        """
        return Value[origin_of(self)](
            bytes=rebind[Span[UInt8, origin_of(self)]](self._input.as_bytes()),
            tape=rebind[Span[UInt64, origin_of(self)]](Span(self._tape)),
            entry=0,
        )

    @always_inline
    def kind(ref self) -> ValueKind:
        """Gets the root value kind.

        Returns:
            The root's JSON kind.
        """
        return self.root().kind()

    def __len__(ref self) raises -> Int:
        """Gets the root container length.

        Returns:
            The array element or object member count.

        Raises:
            If the root is not an array or object.
        """
        return self.root().__len__()

    def __getitem__(ref self, key: String) raises -> Value[origin_of(self)]:
        """Looks up an object member at the root.

        Args:
            key: The decoded member name.

        Returns:
            The matching member value.

        Raises:
            If the root is not an object or the key is absent.
        """
        return self.root()[key]

    def __getitem__(ref self, index: Int) raises -> Value[origin_of(self)]:
        """Looks up an array element at the root.

        Args:
            index: The zero-based element index.

        Returns:
            The requested element.

        Raises:
            If the root is not an array or the index is out of range.
        """
        return self.root()[index]

    def to[T: _ConvertBase](ref self) raises -> T:
        """Converts the root value to a target type.

        Parameters:
            T: The target type.

        Returns:
            The converted value.

        Raises:
            If the root cannot be converted to `T`.
        """
        return self.root().to[T]()

    def elements(ref self) raises -> _ElementIter[origin_of(self)]:
        """Iterates the root array.

        Returns:
            A lazy array-element iterator.

        Raises:
            If the root is not an array.
        """
        return self.root().elements()

    def members(ref self) raises -> _MemberIter[origin_of(self)]:
        """Iterates the root object.

        Returns:
            A lazy object-member iterator.

        Raises:
            If the root is not an object.
        """
        return self.root().members()

    def at(ref self, pointer: String) raises -> Value[origin_of(self)]:
        """Resolves an RFC 6901 JSON Pointer from the root.

        Args:
            pointer: The JSON Pointer expression.

        Returns:
            The addressed value.

        Raises:
            If the pointer is malformed or cannot be resolved.
        """
        return self.root().at(pointer)


# --- Parsing entry points --------------------------------------------------------


def parse[
    options: ParseOptions = ParseOptions()
](var text: String) raises -> Document:
    """Parses JSON text using compile-time options.

    Parameters:
        options: The parsing policy.

    Args:
        text: Source text taken by move.

    Returns:
        The owned parsed document.

    Raises:
        If the input violates the selected grammar or policy.
    """
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
    """Parses JSON text with default options.

    Args:
        text: Source text taken by move.

    Returns:
        The owned parsed document.

    Raises:
        If the input is not valid JSON.
    """
    return parse(text^)


def loads_bytes(var bytes: List[UInt8]) raises -> Document:
    """Parses raw JSON bytes with default options.

    Args:
        bytes: Source bytes taken by move.

    Returns:
        The owned parsed document.

    Raises:
        If the bytes are not valid UTF-8 JSON.
    """
    return parse(String(unsafe_from_utf8=bytes))


def try_parse[
    options: ParseOptions = ParseOptions()
](var text: String) -> Optional[Document]:
    """Attempts to parse JSON without raising.

    Parameters:
        options: The parsing policy.

    Args:
        text: Source text taken by move.

    Returns:
        The parsed document, or `None` on failure.
    """
    try:
        return parse[options](text^)
    except error:
        return None
