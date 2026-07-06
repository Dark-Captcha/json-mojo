"""Provides reflection-derived and trait-controlled typed JSON serde."""

# serde — the typed layer (ARCHITECTURE.md, Type Scheme Layers 2–3):
# `ToJson` completes the two-trait protocol, `serialize`/`deserialize` are the
# typed verbs, and compile-time reflection derives both directions for user
# structs that conform without writing a body (the trait default IS the
# reflection walk — override either method for custom control).
#
# Deserialization never materializes a DOM: `deserialize[T]` parses to the
# tape and reads `T` straight off the root cursor. Field walks mirror the
# working EmberJson shapes on this toolchain: `conforms_to` dispatch inside
# `comptime if`, `r.field_ref[i](value)` for field access, `comptime assert
# conforms_to(...)` evidence for writable field refs, `result = {}` for
# Defaultable init, and the trivial-destructor guard for non-Defaultable
# targets.
#
# Derivation contract for user structs: conform to `FromJson` and/or `ToJson`;
# for `FromJson`, be `Defaultable` (or have only trivially-destructible
# fields). `Optional[T]` fields read a missing member as `None`. Duplicate
# member names in the input follow the parse-time policy — the field walk
# reads through member lookup, so it sees first-wins by default and the
# survivor under LAST_WINS.

from std.builtin.rebind import rebind
from std.reflection import reflect

from json.document import parse
from json.options import ParseOptions
from json.serializer import Serializer
from json.value import _ConvertBase


# --- The serialize gateway ----------------------------------------------------------


trait ToJson:
    """How a type writes itself into a `Serializer` — conform to take custom
    control. Plain structs need no conformance: `serialize` derives them
    through the reflection walk automatically (declaration-only body for the
    same probed reason as `FromJson`)."""

    def to_json(self, mut serializer: Serializer) raises:
        """Writes this value to a serializer.

        Args:
            serializer: The destination JSON serializer.

        Raises:
            If the value cannot be represented as JSON.
        """
        ...


def to_json_value[T: AnyType, //](value: T, mut serializer: Serializer) raises:
    """Writes a value through trait dispatch or reflection.

    Parameters:
        T: The source value type.

    Args:
        value: The value to serialize.
        serializer: The destination serializer.

    Raises:
        If the value cannot be represented as JSON.
    """
    comptime if conforms_to(T, ToJson):
        value.to_json(serializer)
    else:
        _default_to_json(value, serializer)


def _default_to_json[
    T: AnyType, //
](value: T, mut serializer: Serializer) raises:
    comptime r = reflect[T]
    comptime assert (
        r.is_struct()
    ), "json.serialize: cannot serialize a non-struct type"
    comptime field_names = r.field_names()
    serializer.begin_object()
    comptime for i in range(r.field_count()):
        comptime if i > 0:
            serializer.separator()
        serializer.key(field_names[i])
        to_json_value(r.field_ref[i](value), serializer)
    serializer.end_object()


# --- The typed verbs -----------------------------------------------------------------


def serialize[T: AnyType, //](value: T) raises -> String:
    """Serializes a typed value as JSON text.

    Parameters:
        T: The source value type.

    Args:
        value: A trait-controlled or reflection-derived value.

    Returns:
        Compact JSON text.

    Raises:
        If the value cannot be represented as JSON.
    """
    var serializer = Serializer()
    to_json_value(value, serializer)
    return serializer^.finish()


def deserialize[
    T: _ConvertBase, options: ParseOptions = ParseOptions()
](var text: String) raises -> T:
    """Parses JSON directly into a typed value.

    Parameters:
        T: The target value type.
        options: The parsing policy.

    Args:
        text: Source JSON text taken by move.

    Returns:
        The deserialized value.

    Raises:
        If parsing or typed conversion fails.
    """
    var doc = parse[options](text^)
    return doc.to[T]()


def try_deserialize[
    T: _ConvertBase, options: ParseOptions = ParseOptions()
](var text: String) -> Optional[T]:
    """Attempts typed deserialization without raising.

    Parameters:
        T: The target value type.
        options: The parsing policy.

    Args:
        text: Source JSON text taken by move.

    Returns:
        The deserialized value, or `None` on failure.
    """
    try:
        return deserialize[T, options](text^)
    except error:
        return None


# --- ToJson conformances: primitives ---------------------------------------------------


__extension Bool(ToJson):
    def to_json(self, mut serializer: Serializer) raises:
        serializer.write_bool(self)


__extension String(ToJson):
    def to_json(self, mut serializer: Serializer) raises:
        serializer.write_string(self)


__extension SIMD(ToJson):
    def to_json(self, mut serializer: Serializer) raises:
        comptime assert (
            Self.size == 1
        ), "json.serialize: SIMD targets must be scalar"
        comptime if Self.dtype.is_floating_point():
            serializer.write_float(self[0].cast[DType.float64]())
        elif Self.dtype.is_numeric():
            comptime if Self.dtype.is_signed():
                serializer.write_int(self[0].cast[DType.int64]())
            else:
                serializer.write_uint(self[0].cast[DType.uint64]())
        else:
            comptime assert (
                False
            ), "json.serialize: unsupported SIMD scalar type"


# --- ToJson conformances: containers ----------------------------------------------------


__extension List(ToJson):
    def to_json(self, mut serializer: Serializer) raises:
        serializer.begin_array()
        for i in range(len(self)):
            if i > 0:
                serializer.separator()
            to_json_value(self[i], serializer)
        serializer.end_array()


__extension Optional(ToJson):
    def to_json(self, mut serializer: Serializer) raises:
        if self:
            to_json_value(self.value(), serializer)
        else:
            serializer.write_null()


__extension Dict(ToJson):
    def to_json(self, mut serializer: Serializer) raises:
        comptime assert (
            reflect[Self.K].base_name() == "String"
        ), "json.serialize: Dict keys must be String"
        serializer.begin_object()
        var first = True
        for entry in self.items():
            if not first:
                serializer.separator()
            first = False
            serializer.key(rebind[String](entry.key.copy()))
            to_json_value(entry.value, serializer)
        serializer.end_object()
