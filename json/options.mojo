"""Defines compile-time JSON parsing and serialization policies."""

# options — the comptime knobs (ARCHITECTURE.md, Public Surface). Every
# field is policy, not grammar; defaults were chosen by hot-path analysis.
# Passed as comptime parameters, each distinct value monomorphizes its own
# specialized parser and disabled branches erase (.probe/SYNTAX.md,
# finding 16). The `dialect` field joins post-v1 without breaking a caller.

from json._internal.bytes import B_SPACE


struct DuplicatePolicy(Comparable, Copyable, Movable, TrivialRegisterPassable):
    """What an object does about repeated member names. `FIRST_WINS` is the
    default: lookups early-exit and parsing pays nothing. `LAST_WINS` and
    `REJECT` (the I-JSON stance) pay the same per-key detection at parse
    time — the former shadows the earlier member on the tape, the latter
    raises. Detection compares decoded names (RFC 7493 character equality),
    matching the lookup path."""

    var _code: UInt8

    @doc_hidden
    @always_inline
    def __init__(out self, *, code: UInt8):
        self._code = code

    @doc_hidden
    @always_inline
    def __eq__(self, other: DuplicatePolicy) -> Bool:
        return self._code == other._code

    @doc_hidden
    @always_inline
    def __ne__(self, other: DuplicatePolicy) -> Bool:
        return self._code != other._code

    @doc_hidden
    @always_inline
    def __lt__(self, other: DuplicatePolicy) -> Bool:
        return self._code < other._code

    @doc_hidden
    @always_inline
    def __le__(self, other: DuplicatePolicy) -> Bool:
        return self._code <= other._code

    @doc_hidden
    @always_inline
    def __gt__(self, other: DuplicatePolicy) -> Bool:
        return self._code > other._code

    @doc_hidden
    @always_inline
    def __ge__(self, other: DuplicatePolicy) -> Bool:
        return self._code >= other._code

    comptime FIRST_WINS: DuplicatePolicy = DuplicatePolicy(code=UInt8(0))
    """Keeps the first occurrence of a duplicate member name."""
    comptime LAST_WINS: DuplicatePolicy = DuplicatePolicy(code=UInt8(1))
    """Keeps the last occurrence of a duplicate member name."""
    comptime REJECT: DuplicatePolicy = DuplicatePolicy(code=UInt8(2))
    """Rejects duplicate member names."""


struct ParseMode(Comparable, Copyable, Movable, TrivialRegisterPassable):
    """Strictness profile within the JSON grammar: `STANDARD` (RFC 8259) or
    `I_JSON` (RFC 7493 §2 — duplicate names rejected, noncharacters rejected
    raw or escaped; a leading BOM is rejected too, a strictness this library
    adds beyond the RFC and documents here)."""

    var _code: UInt8

    @doc_hidden
    @always_inline
    def __init__(out self, *, code: UInt8):
        self._code = code

    @doc_hidden
    @always_inline
    def __eq__(self, other: ParseMode) -> Bool:
        return self._code == other._code

    @doc_hidden
    @always_inline
    def __ne__(self, other: ParseMode) -> Bool:
        return self._code != other._code

    @doc_hidden
    @always_inline
    def __lt__(self, other: ParseMode) -> Bool:
        return self._code < other._code

    @doc_hidden
    @always_inline
    def __le__(self, other: ParseMode) -> Bool:
        return self._code <= other._code

    @doc_hidden
    @always_inline
    def __gt__(self, other: ParseMode) -> Bool:
        return self._code > other._code

    @doc_hidden
    @always_inline
    def __ge__(self, other: ParseMode) -> Bool:
        return self._code >= other._code

    comptime STANDARD: ParseMode = ParseMode(code=UInt8(0))
    """Applies RFC 8259 parsing semantics."""
    comptime I_JSON: ParseMode = ParseMode(code=UInt8(1))
    """Applies the stricter RFC 7493 I-JSON profile."""


struct Dialect(Comparable, Copyable, Movable, TrivialRegisterPassable):
    """Which TEXT grammar is being read (extension tier 1): `JSON`
    (RFC 8259) or `JSON5` (json5.org — comments, trailing commas, unquoted
    identifier keys, single quotes, extended numbers and escapes). `mode`
    answers "how strict within it"; binary wire formats are front-end
    libraries, never dialect values."""

    var _code: UInt8

    @doc_hidden
    @always_inline
    def __init__(out self, *, code: UInt8):
        self._code = code

    @doc_hidden
    @always_inline
    def __eq__(self, other: Dialect) -> Bool:
        return self._code == other._code

    @doc_hidden
    @always_inline
    def __ne__(self, other: Dialect) -> Bool:
        return self._code != other._code

    @doc_hidden
    @always_inline
    def __lt__(self, other: Dialect) -> Bool:
        return self._code < other._code

    @doc_hidden
    @always_inline
    def __le__(self, other: Dialect) -> Bool:
        return self._code <= other._code

    @doc_hidden
    @always_inline
    def __gt__(self, other: Dialect) -> Bool:
        return self._code > other._code

    @doc_hidden
    @always_inline
    def __ge__(self, other: Dialect) -> Bool:
        return self._code >= other._code

    comptime JSON: Dialect = Dialect(code=UInt8(0))
    """Selects the RFC 8259 JSON grammar."""
    comptime JSON5: Dialect = Dialect(code=UInt8(1))
    """Selects the JSON5 grammar."""


struct ParseOptions(Copyable, Movable, TrivialRegisterPassable):
    """The reserved comptime slot (extension tier 1). Defaults per the
    hot-path analysis in ARCHITECTURE.md."""

    var max_depth: Int
    """The maximum permitted array and object nesting depth."""
    var duplicates: DuplicatePolicy
    """The duplicate object-member policy."""
    var mode: ParseMode
    """The JSON strictness profile."""
    var dialect: Dialect
    """The input text grammar."""

    @always_inline
    def __init__(
        out self,
        *,
        max_depth: Int = 1024,
        duplicates: DuplicatePolicy = DuplicatePolicy.FIRST_WINS,
        mode: ParseMode = ParseMode.STANDARD,
        dialect: Dialect = Dialect.JSON,
    ):
        """Creates a parsing policy.

        Args:
            max_depth: The maximum container nesting depth.
            duplicates: The duplicate member-name policy.
            mode: The JSON strictness profile.
            dialect: The input text grammar.
        """
        self.max_depth = max_depth
        self.duplicates = duplicates
        self.mode = mode
        self.dialect = dialect

    @always_inline
    def rejects_duplicates(self) -> Bool:
        """Checks the effective duplicate-name policy.

        Returns:
            True when duplicate member names must be rejected.
        """
        return (
            self.duplicates == DuplicatePolicy.REJECT
            or self.mode == ParseMode.I_JSON
        )

    @always_inline
    def rejects_noncharacters(self) -> Bool:
        """Checks whether Unicode noncharacters must be rejected.

        Returns:
            True for the RFC 7493 I-JSON profile.
        """
        return self.mode == ParseMode.I_JSON

    @always_inline
    def shadows_duplicates(self) -> Bool:
        """Checks whether later duplicate members shadow earlier ones.

        Returns:
            True for effective last-wins parsing.
        """
        return (
            self.duplicates == DuplicatePolicy.LAST_WINS
            and not self.rejects_duplicates()
        )


struct SerializeOptions(Copyable, Movable, TrivialRegisterPassable):
    """Serialization knobs — comptime, so every combination monomorphizes
    and the compact path never carries a pretty branch.

    `pretty` switches indented emission on; `indent` is the width per depth
    level (Python `indent=N`, JS `space=N`; `0` emits newlines without
    indentation, matching Python's `indent=0`) and `indent_byte` the fill
    byte (`B_TAB` covers Python `indent="\\t"` / JS `space="\\t"`).

    Deliberately absent, with reasons: `sort_keys` belongs to the future
    JCS (RFC 8785) canonical mode — a half-canonical knob invites
    confusion; replacer/default callbacks are the `Value`/serde transform
    layer's job (function-typed comptime parameters are unusable on this
    pin, .probe/SYNTAX.md finding 8); `allow_nan` is fixed by contract
    (`dumps` refuses non-finite); `check_circular` is free — the tape is
    acyclic by construction. Further fields join without breaking
    callers."""

    var pretty: Bool
    """Whether to emit line breaks and indentation."""
    var indent: Int
    """The indentation width per container depth."""
    var indent_byte: UInt8
    """The byte used for indentation."""

    @always_inline
    def __init__(
        out self,
        *,
        pretty: Bool = False,
        indent: Int = 2,
        indent_byte: UInt8 = B_SPACE,
    ):
        """Creates a serialization policy.

        Args:
            pretty: Whether to emit formatted output.
            indent: The indentation width per depth level.
            indent_byte: The indentation byte, normally space or tab.
        """
        debug_assert(indent >= 0, "indent width must be non-negative")
        self.pretty = pretty
        self.indent = indent
        self.indent_byte = indent_byte
