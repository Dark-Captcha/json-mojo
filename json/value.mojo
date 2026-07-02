# Value — the lazy cursor into a document's tape (ARCHITECTURE.md, Public
# Surface). A Value is two spans (input bytes, tape words) plus an entry
# index, borrowing its Document through an inferred origin: access chains
# and loops never name a lifetime, and the compiler refuses a cursor that
# would outlive its bytes.
#
# Object member lookup is a forward scan with first-wins early exit over the
# skip-link tape (ARCHITECTURE.md, ParseOptions defaults). Escaped member
# names are decoded before comparison, so lookup is by string value, not by
# raw spelling. Everything here trusts stage 2's validation — spans are
# well-formed by invariant, which is what makes the non-validating String
# construction in the escape decoder sound.

from std.builtin.rebind import downcast
from std.reflection import reflect

from json._internal.bytes import B_0, B_1, B_9, B_SLASH, B_TILDE
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


struct ValueKind(Comparable, Copyable, Movable, TrivialRegisterPassable):
    """One of RFC 8259's six kinds — the entire tape alphabet."""

    var _code: UInt8

    @always_inline
    def __init__(out self, *, code: UInt8):
        self._code = code

    @always_inline
    def __eq__(self, other: ValueKind) -> Bool:
        return self._code == other._code

    @always_inline
    def __ne__(self, other: ValueKind) -> Bool:
        return self._code != other._code

    @always_inline
    def __lt__(self, other: ValueKind) -> Bool:
        return self._code < other._code

    @always_inline
    def __le__(self, other: ValueKind) -> Bool:
        return self._code <= other._code

    @always_inline
    def __gt__(self, other: ValueKind) -> Bool:
        return self._code > other._code

    @always_inline
    def __ge__(self, other: ValueKind) -> Bool:
        return self._code >= other._code

    comptime NULL: ValueKind = ValueKind(code=UInt8(0))
    comptime BOOLEAN: ValueKind = ValueKind(code=UInt8(1))
    comptime NUMBER: ValueKind = ValueKind(code=UInt8(2))
    comptime STRING: ValueKind = ValueKind(code=UInt8(3))
    comptime ARRAY: ValueKind = ValueKind(code=UInt8(4))
    comptime OBJECT: ValueKind = ValueKind(code=UInt8(5))


struct Value[origin: ImmutOrigin](Copyable, Movable):
    """A lazy cursor: nothing is converted or allocated until asked."""

    var _bytes: Span[UInt8, Self.origin]
    var _tape: Span[UInt64, Self.origin]
    var _entry: Int

    @always_inline
    def __init__(
        out self,
        *,
        bytes: Span[UInt8, Self.origin],
        tape: Span[UInt64, Self.origin],
        entry: Int,
    ):
        self._bytes = bytes
        self._tape = tape
        self._entry = entry

    # --- Inspection -----------------------------------------------------------

    @always_inline
    def kind(self) -> ValueKind:
        return ValueKind(code=entry_tag(self._tape[self._entry * 2]))

    def __len__(self) raises -> Int:
        """Element count of an array, member count of an object."""
        var tag = entry_tag(self._tape[self._entry * 2])
        if tag != TAG_ARRAY and tag != TAG_OBJECT:
            raise Error("json.value: len() on a non-container value")
        return entry_a(self._tape[self._entry * 2])

    # --- Number introspection (ARCHITECTURE.md: the honest surface) -----------

    @always_inline
    def _number_is_json5(self) -> Bool:
        return (
            entry_flags(self._tape[self._entry * 2]) & FLAG_REENCODE
        ) != UInt8(0)

    def fits_int64(self) -> Bool:
        if entry_tag(self._tape[self._entry * 2]) != TAG_NUMBER:
            return False
        if self._number_is_json5():
            return Bool(
                json5_number_to_int64(
                    self._bytes, self._number_start(), self._number_end()
                )
            )
        return Bool(
            parse_int64(self._bytes, self._number_start(), self._number_end())
        )

    def fits_uint64(self) -> Bool:
        if entry_tag(self._tape[self._entry * 2]) != TAG_NUMBER:
            return False
        if self._number_is_json5():
            return Bool(
                json5_number_to_uint64(
                    self._bytes, self._number_start(), self._number_end()
                )
            )
        return Bool(
            parse_uint64(self._bytes, self._number_start(), self._number_end())
        )

    def fits_float64(self) -> Bool:
        """Converts to a FINITE Float64 — JSON5's Infinity/NaN answer False
        here (they convert via `to[Float64]()` regardless)."""
        if entry_tag(self._tape[self._entry * 2]) != TAG_NUMBER:
            return False
        if self._number_is_json5():
            var value = json5_number_to_float(
                self._bytes, self._number_start(), self._number_end()
            )
            if not value:
                return False
            var f = value.value()
            return (
                f == f and f <= Float64.MAX_FINITE and f >= -Float64.MAX_FINITE
            )
        return Bool(
            parse_float(self._bytes, self._number_start(), self._number_end())
        )

    # --- Access ----------------------------------------------------------------

    def __getitem__(self, key: String) raises -> Value[Self.origin]:
        """Object member lookup — forward scan, first-wins early exit.
        Members shadowed at parse time (LAST_WINS) are skipped, so the first
        live match IS the last occurrence."""
        var word0 = self._tape[self._entry * 2]
        if entry_tag(word0) != TAG_OBJECT:
            raise Error("json.value: [key] on a non-object value")
        var member_count = entry_a(word0)
        var entry = self._entry + 1
        var walked = 0
        while walked < member_count:
            var key_word0 = self._tape[entry * 2]
            if (entry_flags(key_word0) & FLAG_SHADOWED) != UInt8(0):
                entry = self._skip_past(entry + 1)
                continue  # not a live member — doesn't count
            if self._key_matches(entry, key):
                return Value[Self.origin](
                    bytes=self._bytes, tape=self._tape, entry=entry + 1
                )
            entry = self._skip_past(entry + 1)
            walked += 1
        raise Error("json.value: member not found: " + key)

    def __getitem__(self, index: Int) raises -> Value[Self.origin]:
        """Array element access by position."""
        var word0 = self._tape[self._entry * 2]
        if entry_tag(word0) != TAG_ARRAY:
            raise Error("json.value: [index] on a non-array value")
        var element_count = entry_a(word0)
        if index < 0 or index >= element_count:
            raise Error(
                "json.value: index "
                + String(index)
                + " out of range for array of "
                + String(element_count)
            )
        var entry = self._entry + 1
        for _ in range(index):
            entry = self._skip_past(entry)
        return Value[Self.origin](
            bytes=self._bytes, tape=self._tape, entry=entry
        )

    # --- Iteration (RFC 8259's own nouns: elements, members) --------------------

    def elements(self) raises -> _ElementIter[Self.origin]:
        """Iterate an array's elements in document order."""
        var word0 = self._tape[self._entry * 2]
        if entry_tag(word0) != TAG_ARRAY:
            raise Error("json.value: elements() on a non-array value")
        return _ElementIter[Self.origin](
            bytes=self._bytes,
            tape=self._tape,
            entry=self._entry + 1,
            remaining=entry_a(word0),
        )

    def members(self) raises -> _MemberIter[Self.origin]:
        """Iterate an object's members in document order — every member that
        survived the parse-time duplicate policy: all occurrences under the
        default FIRST_WINS (no detection is paid), survivors only under
        LAST_WINS."""
        var word0 = self._tape[self._entry * 2]
        if entry_tag(word0) != TAG_OBJECT:
            raise Error("json.value: members() on a non-object value")
        return _MemberIter[Self.origin](
            bytes=self._bytes,
            tape=self._tape,
            entry=self._entry + 1,
            remaining=entry_a(word0),
        )

    # --- RFC 6901 JSON Pointer ---------------------------------------------------

    def at(self, pointer: String) raises -> Value[Self.origin]:
        """Resolve an RFC 6901 JSON Pointer (`/a/b/0`; `~0` → `~`, `~1` → `/`).
        The empty pointer addresses this value itself."""
        var pointer_bytes = pointer.as_bytes()
        var n = len(pointer_bytes)
        if n == 0:
            return Value[Self.origin](
                bytes=self._bytes, tape=self._tape, entry=self._entry
            )
        if pointer_bytes[0] != B_SLASH:
            raise Error(
                "json.value: JSON Pointer must be empty or start with '/'"
            )
        var current = Value[Self.origin](
            bytes=self._bytes, tape=self._tape, entry=self._entry
        )
        var i = 1
        while i <= n:
            # Decode one reference token (up to the next '/' or the end).
            var token = String("")
            while i < n and pointer_bytes[i] != B_SLASH:
                var c = pointer_bytes[i]
                if c == B_TILDE:
                    if i + 1 >= n:
                        raise Error(
                            "json.value: JSON Pointer ends in a bare '~'"
                        )
                    var next = pointer_bytes[i + 1]
                    if next == B_0:
                        token += "~"
                    elif next == B_1:
                        token += "/"
                    else:
                        raise Error(
                            "json.value: invalid JSON Pointer escape '~"
                            + chr(Int(next))
                            + "'"
                        )
                    i += 2
                else:
                    token += chr(Int(c))
                    i += 1
            var tag = entry_tag(current._tape[current._entry * 2])
            if tag == TAG_OBJECT:
                current = current[token]
            elif tag == TAG_ARRAY:
                current = current[_pointer_index(token)]
            else:
                raise Error(
                    "json.value: JSON Pointer descends into a non-container"
                )
            i += 1  # step past the '/' (or beyond the end, ending the loop)
        return current^

    # --- Conversion: the one generic gateway (Type Scheme, Layer 2) -------------

    def to[T: _ConvertBase](self) raises -> T:
        """Convert this value to `T` — the one generic gateway (Type Scheme,
        Layer 2): a `FromJson` conformance when declared, the reflection
        field walk otherwise. There is no container arm: List/Dict reading
        is blocked by a compiler ICE on cross-module conformance queries
        (finding 36 — the ownership wall itself fell, mechanism retained in
        .probe/) — the typed container read path is the cursor walk
        (`elements()` / `members()`). The bound stays loose so trait-typed
        references (the field walk's downcasts) satisfy it."""
        comptime if conforms_to(T, FromJson):
            # Direct static call — the comptime-if condition is the bound
            # evidence (findings 24/35); `downcast` here ICEs the compiler
            # on extension conformances with bodies (finding 36 notes).
            return T.from_json(self)
        else:
            return default_from_json[T](self)

    # --- Typed readers (the primitive conformances are built on these) ----------

    def _read_bool(self) raises -> Bool:
        var word0 = self._tape[self._entry * 2]
        if entry_tag(word0) != TAG_BOOLEAN:
            raise Error("json.value: expected a boolean")
        return entry_a(word0) == 1

    def _read_int64(self) raises -> Int64:
        if entry_tag(self._tape[self._entry * 2]) != TAG_NUMBER:
            raise Error("json.value: expected a number")
        var parsed: Optional[Int64]
        if self._number_is_json5():
            parsed = json5_number_to_int64(
                self._bytes, self._number_start(), self._number_end()
            )
        else:
            parsed = parse_int64(
                self._bytes, self._number_start(), self._number_end()
            )
        if not parsed:
            raise Error("json.value: number is not representable as Int64")
        return parsed.value()

    def _read_uint64(self) raises -> UInt64:
        if entry_tag(self._tape[self._entry * 2]) != TAG_NUMBER:
            raise Error("json.value: expected a number")
        var parsed: Optional[UInt64]
        if self._number_is_json5():
            parsed = json5_number_to_uint64(
                self._bytes, self._number_start(), self._number_end()
            )
        else:
            parsed = parse_uint64(
                self._bytes, self._number_start(), self._number_end()
            )
        if not parsed:
            raise Error("json.value: number is not representable as UInt64")
        return parsed.value()

    def _read_float64(self) raises -> Float64:
        if entry_tag(self._tape[self._entry * 2]) != TAG_NUMBER:
            raise Error("json.value: expected a number")
        var parsed: Optional[Float64]
        if self._number_is_json5():
            parsed = json5_number_to_float(
                self._bytes, self._number_start(), self._number_end()
            )
        else:
            parsed = parse_float(
                self._bytes, self._number_start(), self._number_end()
            )
        if not parsed:
            raise Error("json.value: number overflows Float64")
        return parsed.value()

    def _read_string(self) raises -> String:
        var word0 = self._tape[self._entry * 2]
        if entry_tag(word0) != TAG_STRING:
            raise Error("json.value: expected a string")
        var start = entry_a(word0)
        var end = Int(self._tape[self._entry * 2 + 1])
        if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
            return decode_json5_string(self._bytes, start, end)
        if (entry_flags(word0) & FLAG_ESCAPED) != UInt8(0):
            return decode_escaped_string(self._bytes, start, end)
        return String(unsafe_from_utf8=self._bytes[start:end])

    # --- Private tape walking ----------------------------------------------------

    @always_inline
    def _number_start(self) -> Int:
        return entry_a(self._tape[self._entry * 2])

    @always_inline
    def _number_end(self) -> Int:
        return Int(self._tape[self._entry * 2 + 1])

    @always_inline
    def _skip_past(self, entry: Int) -> Int:
        """The entry index just past the value at `entry`."""
        return skip_past(self._tape, entry)

    def _key_matches(self, key_entry: Int, key: String) -> Bool:
        var word0 = self._tape[key_entry * 2]
        var start = entry_a(word0)
        var end = Int(self._tape[key_entry * 2 + 1])
        var key_bytes = key.as_bytes()
        if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
            return decode_json5_string(self._bytes, start, end) == key
        if (entry_flags(word0) & FLAG_ESCAPED) != UInt8(0):
            # Escaped names compare by decoded value, not raw spelling.
            var decoded = decode_escaped_string(self._bytes, start, end)
            return decoded == key
        if end - start != len(key_bytes):
            return False
        for k in range(len(key_bytes)):
            if self._bytes[start + k] != key_bytes[k]:
                return False
        return True


# --- Iterators and members --------------------------------------------------------
#
# The Python-style iterator protocol on this toolchain: `__iter__` returns
# Self, `__next__` raises `StopIteration` when exhausted (EmberJson evidence).
# `Member` is the yield type of `members()` — package-public but deliberately
# not re-exported: callers meet it through iteration, like a stdlib DictEntry.


def _pointer_index(token: String) raises -> Int:
    """RFC 6901 §4 array index: digits only, no leading zero except `0`
    itself. `-` (past-the-end) is always out of range for a read."""
    var token_bytes = token.as_bytes()
    var n = len(token_bytes)
    if n == 0:
        raise Error("json.value: empty JSON Pointer array index")
    if n > 1 and token_bytes[0] == B_0:
        raise Error("json.value: JSON Pointer index has a leading zero")
    var index = 0
    for k in range(n):
        var c = token_bytes[k]
        if c < B_0 or c > B_9:
            raise Error(
                "json.value: JSON Pointer index is not a number: " + token
            )
        index = index * 10 + Int(c - B_0)
        if index > (1 << 47):
            raise Error("json.value: JSON Pointer index out of range")
    return index


struct _ElementIter[origin: ImmutOrigin](Copyable, Movable, Sized):
    var _bytes: Span[UInt8, Self.origin]
    var _tape: Span[UInt64, Self.origin]
    var _entry: Int
    var _remaining: Int

    @always_inline
    def __init__(
        out self,
        *,
        bytes: Span[UInt8, Self.origin],
        tape: Span[UInt64, Self.origin],
        entry: Int,
        remaining: Int,
    ):
        self._bytes = bytes
        self._tape = tape
        self._entry = entry
        self._remaining = remaining

    @always_inline
    def __iter__(self) -> Self:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Value[Self.origin]:
        if self._remaining == 0:
            raise StopIteration()
        var value = Value[Self.origin](
            bytes=self._bytes, tape=self._tape, entry=self._entry
        )
        self._entry = skip_past(self._tape, self._entry)
        self._remaining -= 1
        return value^

    @always_inline
    def __len__(self) -> Int:
        return self._remaining


struct Member[origin: ImmutOrigin](Copyable, Movable):
    """One object member: a decoded key plus a lazy value cursor."""

    var _bytes: Span[UInt8, Self.origin]
    var _tape: Span[UInt64, Self.origin]
    var _key_entry: Int

    @always_inline
    def __init__(
        out self,
        *,
        bytes: Span[UInt8, Self.origin],
        tape: Span[UInt64, Self.origin],
        key_entry: Int,
    ):
        self._bytes = bytes
        self._tape = tape
        self._key_entry = key_entry

    def key(self) -> String:
        """The member name, escape-decoded."""
        var word0 = self._tape[self._key_entry * 2]
        var start = entry_a(word0)
        var end = Int(self._tape[self._key_entry * 2 + 1])
        if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
            return decode_json5_string(self._bytes, start, end)
        if (entry_flags(word0) & FLAG_ESCAPED) != UInt8(0):
            return decode_escaped_string(self._bytes, start, end)
        return String(unsafe_from_utf8=self._bytes[start:end])

    @always_inline
    def value(self) -> Value[Self.origin]:
        """The member's value as a lazy cursor."""
        return Value[Self.origin](
            bytes=self._bytes, tape=self._tape, entry=self._key_entry + 1
        )


struct _MemberIter[origin: ImmutOrigin](Copyable, Movable, Sized):
    var _bytes: Span[UInt8, Self.origin]
    var _tape: Span[UInt64, Self.origin]
    var _entry: Int  # next key entry
    var _remaining: Int

    @always_inline
    def __init__(
        out self,
        *,
        bytes: Span[UInt8, Self.origin],
        tape: Span[UInt64, Self.origin],
        entry: Int,
        remaining: Int,
    ):
        self._bytes = bytes
        self._tape = tape
        self._entry = entry
        self._remaining = remaining

    @always_inline
    def __iter__(self) -> Self:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Member[Self.origin]:
        if self._remaining == 0:
            raise StopIteration()
        # Hop members shadowed at parse time (LAST_WINS) — `_remaining`
        # counts survivors, so a live member is guaranteed ahead.
        while (
            entry_flags(self._tape[self._entry * 2]) & FLAG_SHADOWED
        ) != UInt8(0):
            self._entry = skip_past(self._tape, self._entry + 1)
        var member = Member[Self.origin](
            bytes=self._bytes, tape=self._tape, key_entry=self._entry
        )
        self._entry = skip_past(self._tape, self._entry + 1)
        self._remaining -= 1
        return member^

    @always_inline
    def __len__(self) -> Int:
        return self._remaining


# --- The conversion protocol (Type Scheme, Layer 2) -----------------------------
#
# Two traits are the entire machinery; primitives conform via `__extension`
# below, so `to[T]` is trait dispatch all the way down — no type matcher.
# One SIMD conformance covers every scalar width through `Self.dtype`.

comptime _ConvertBase = ImplicitlyDeletable & Movable


trait FromJson(_ConvertBase):
    """How a type reads itself out of a `Value` — conform to take custom
    control. Plain structs need no conformance at all: `to[T]` derives them
    through the reflection walk (`default_from_json`) automatically. A trait
    default body would be the natural spelling, but it breaks generic
    `__extension` conformance checks on this toolchain (probed)."""

    @staticmethod
    def from_json[
        origin: ImmutOrigin, //
    ](value: Value[origin], out result: Self) raises:
        ...


def default_from_json[
    origin: ImmutOrigin, //, T: _ConvertBase
](value: Value[origin], out result: T) raises:
    """Fill a struct's fields by name from an object value — the derivation
    behind `FromJson`'s trait default. Field types dispatch through their own
    `FromJson` conformances."""
    comptime r = reflect[T]
    comptime assert (
        r.is_struct()
    ), "json.deserialize: cannot deserialize a non-struct type"
    # The walk reads members by name — anything but an object is a caller
    # error, surfaced here so an all-Optional struct cannot silently absorb
    # a scalar into defaults.
    if value.kind() != ValueKind.OBJECT:
        raise Error("json.deserialize: struct fields read from an object value")
    comptime if conforms_to(T, Defaultable):
        result = {}
    else:
        comptime assert _all_dtors_trivial[T](), (
            "json.deserialize: a non-Defaultable struct must have only"
            " trivially-destructible fields (add a no-argument __init__)"
        )
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(result)
        )
    comptime field_names = r.field_names()
    comptime field_types = r.field_types()
    comptime for i in range(r.field_count()):
        comptime name = field_names[i]
        comptime if reflect[field_types[i]].base_name() == "Optional":
            # A missing or null member reads as None; a present member of the
            # wrong kind still raises (the probe try covers lookup only).
            comptime assert conforms_to(
                field_types[i], _ConvertBase & Defaultable
            ), "json.deserialize: Optional field type must be convertible"
            ref field = r.field_ref[i](result)
            var probe = Optional[Value[origin]](None)
            try:
                probe = Optional[Value[origin]](value[String(name)])
            except error:
                pass  # missing member — reads as None below
            if probe:
                # Present: the Optional conformance handles null → None and
                # lets a kind mismatch raise (never swallowed).
                field = probe.value().to[type_of(field)]()
            else:
                field = {}
        else:
            comptime assert conforms_to(
                field_types[i], _ConvertBase
            ), "json.deserialize: field type must be convertible"
            ref field = r.field_ref[i](result)
            field = value[String(name)].to[type_of(field)]()


def _all_dtors_trivial[T: AnyType]() -> Bool:
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime field_type = r.field_types()[i]
        if not downcast[field_type, ImplicitlyDeletable].__del__is_trivial:
            return False
    return True


__extension Bool(FromJson):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, //
    ](value: Value[origin], out result: Self) raises:
        result = value._read_bool()


__extension String(FromJson):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, //
    ](value: Value[origin], out result: Self) raises:
        result = value._read_string()


# `Optional` conforms directly (no state is live across its raising calls).
# `List` and `Dict` accumulate across raising calls — the v1 wall — which the
# ownership checker now permits when the raise path explicitly consumes the
# partial container via `destroy_with` and comptime asserts supply the
# element evidence (SYNTAX.md, finding 36).


__extension Optional(FromJson):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, //
    ](value: Value[origin], out result: Self) raises:
        if value.kind() == ValueKind.NULL:
            result = Self(None)
        else:
            result = Self(value.to[downcast[Self.T, _ConvertBase]]())


# `List` and `Dict` reading: the ownership wall fell (finding 36 — an
# accumulating raising body is legal when the raise path consumes the partial
# container via `destroy_with`, with comptime-assert element evidence; probed
# in `.probe/probe_container_walls.mojo`), but re-landing is blocked by a
# compiler ICE on this pin: a CROSS-MODULE `conforms_to(List[X], FromJson)`
# query crashes decl-body resolution of the extension (the same query against
# `ToJson` is fine — serialization works). Re-attempt each nightly; until
# then the typed container read path remains the cursor walk.


__extension SIMD(FromJson):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, //
    ](value: Value[origin], out result: Self) raises:
        comptime assert (
            Self.size == 1
        ), "json.value: to[T] supports scalar SIMD targets only"
        # `Int` itself is a SIMD scalar alias on this toolchain, so this one
        # conformance covers every integer width plus Float32/Float64. The
        # round-trip check makes narrow targets exact-or-error, never a
        # silent truncation.
        comptime if Self.dtype.is_floating_point():
            result = value._read_float64().cast[Self.dtype]()
        elif Self.dtype.is_numeric():
            comptime if Self.dtype.is_signed():
                var wide = value._read_int64()
                result = wide.cast[Self.dtype]()
                if result.cast[DType.int64]() != wide:
                    raise Error(
                        "json.value: number does not fit the target width"
                    )
            else:
                var wide_u = value._read_uint64()
                result = wide_u.cast[Self.dtype]()
                if result.cast[DType.uint64]() != wide_u:
                    raise Error(
                        "json.value: number does not fit the target width"
                    )
        else:
            comptime assert (
                False
            ), "json.value: to[T] numeric targets only for SIMD scalars"
