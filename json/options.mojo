# options — the comptime knobs (ARCHITECTURE.md, Public Surface). Every
# field is policy, not grammar; defaults were chosen by hot-path analysis.
# Passed as comptime parameters, each distinct value monomorphizes its own
# specialized parser and disabled branches erase (.probe/SYNTAX.md,
# finding 16). The `dialect` field joins post-v1 without breaking a caller.


struct DuplicatePolicy(Comparable, Copyable, Movable, TrivialRegisterPassable):
    """What an object does about repeated member names. `FIRST_WINS` is the
    default: lookups early-exit and parsing pays nothing. `LAST_WINS` and
    `REJECT` (the I-JSON stance) pay the same per-key detection at parse
    time — the former shadows the earlier member on the tape, the latter
    raises. Detection compares decoded names (RFC 7493 character equality),
    matching the lookup path."""

    var _code: UInt8

    @always_inline
    def __init__(out self, *, code: UInt8):
        self._code = code

    @always_inline
    def __eq__(self, other: DuplicatePolicy) -> Bool:
        return self._code == other._code

    @always_inline
    def __ne__(self, other: DuplicatePolicy) -> Bool:
        return self._code != other._code

    @always_inline
    def __lt__(self, other: DuplicatePolicy) -> Bool:
        return self._code < other._code

    @always_inline
    def __le__(self, other: DuplicatePolicy) -> Bool:
        return self._code <= other._code

    @always_inline
    def __gt__(self, other: DuplicatePolicy) -> Bool:
        return self._code > other._code

    @always_inline
    def __ge__(self, other: DuplicatePolicy) -> Bool:
        return self._code >= other._code

    comptime FIRST_WINS: DuplicatePolicy = DuplicatePolicy(code=UInt8(0))
    comptime LAST_WINS: DuplicatePolicy = DuplicatePolicy(code=UInt8(1))
    comptime REJECT: DuplicatePolicy = DuplicatePolicy(code=UInt8(2))


struct ParseMode(Comparable, Copyable, Movable, TrivialRegisterPassable):
    """Strictness profile within the JSON grammar: `STANDARD` (RFC 8259) or
    `I_JSON` (RFC 7493 §2 — duplicate names rejected, noncharacters rejected
    raw or escaped; a leading BOM is rejected too, a strictness this library
    adds beyond the RFC and documents here)."""

    var _code: UInt8

    @always_inline
    def __init__(out self, *, code: UInt8):
        self._code = code

    @always_inline
    def __eq__(self, other: ParseMode) -> Bool:
        return self._code == other._code

    @always_inline
    def __ne__(self, other: ParseMode) -> Bool:
        return self._code != other._code

    @always_inline
    def __lt__(self, other: ParseMode) -> Bool:
        return self._code < other._code

    @always_inline
    def __le__(self, other: ParseMode) -> Bool:
        return self._code <= other._code

    @always_inline
    def __gt__(self, other: ParseMode) -> Bool:
        return self._code > other._code

    @always_inline
    def __ge__(self, other: ParseMode) -> Bool:
        return self._code >= other._code

    comptime STANDARD: ParseMode = ParseMode(code=UInt8(0))
    comptime I_JSON: ParseMode = ParseMode(code=UInt8(1))


struct Dialect(Comparable, Copyable, Movable, TrivialRegisterPassable):
    """Which TEXT grammar is being read (extension tier 1): `JSON`
    (RFC 8259) or `JSON5` (json5.org — comments, trailing commas, unquoted
    identifier keys, single quotes, extended numbers and escapes). `mode`
    answers "how strict within it"; binary wire formats are front-end
    libraries, never dialect values."""

    var _code: UInt8

    @always_inline
    def __init__(out self, *, code: UInt8):
        self._code = code

    @always_inline
    def __eq__(self, other: Dialect) -> Bool:
        return self._code == other._code

    @always_inline
    def __ne__(self, other: Dialect) -> Bool:
        return self._code != other._code

    @always_inline
    def __lt__(self, other: Dialect) -> Bool:
        return self._code < other._code

    @always_inline
    def __le__(self, other: Dialect) -> Bool:
        return self._code <= other._code

    @always_inline
    def __gt__(self, other: Dialect) -> Bool:
        return self._code > other._code

    @always_inline
    def __ge__(self, other: Dialect) -> Bool:
        return self._code >= other._code

    comptime JSON: Dialect = Dialect(code=UInt8(0))
    comptime JSON5: Dialect = Dialect(code=UInt8(1))


struct ParseOptions(Copyable, Movable, TrivialRegisterPassable):
    """The reserved comptime slot (extension tier 1). Defaults per the
    hot-path analysis in ARCHITECTURE.md."""

    var max_depth: Int
    var duplicates: DuplicatePolicy
    var mode: ParseMode
    var dialect: Dialect

    @always_inline
    def __init__(
        out self,
        *,
        max_depth: Int = 1024,
        duplicates: DuplicatePolicy = DuplicatePolicy.FIRST_WINS,
        mode: ParseMode = ParseMode.STANDARD,
        dialect: Dialect = Dialect.JSON,
    ):
        self.max_depth = max_depth
        self.duplicates = duplicates
        self.mode = mode
        self.dialect = dialect

    @always_inline
    def rejects_duplicates(self) -> Bool:
        """The effective duplicate stance — `I_JSON` mode forces rejection."""
        return (
            self.duplicates == DuplicatePolicy.REJECT
            or self.mode == ParseMode.I_JSON
        )

    @always_inline
    def rejects_noncharacters(self) -> Bool:
        """RFC 7493 §2.1: I-JSON strings must not contain Unicode
        noncharacters (U+FDD0..U+FDEF and the last two code points of every
        plane), raw or escaped."""
        return self.mode == ParseMode.I_JSON

    @always_inline
    def shadows_duplicates(self) -> Bool:
        """`LAST_WINS` shadows earlier duplicates at parse time — unless the
        mode already escalates duplicates to rejection."""
        return (
            self.duplicates == DuplicatePolicy.LAST_WINS
            and not self.rejects_duplicates()
        )


struct SerializeOptions(Copyable, Movable, TrivialRegisterPassable):
    """Serialization knobs. Version one: compact or pretty with a fixed
    two-space indent; further fields join without breaking callers."""

    var pretty: Bool

    @always_inline
    def __init__(out self, *, pretty: Bool = False):
        self.pretty = pretty
