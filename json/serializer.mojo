"""Provides document serialization and a typed JSON writer."""

# serializer — tape → JSON text (RFC 8259 §10) plus `Serializer`, the sink
# `ToJson` implementations write into (ARCHITECTURE.md, Public Surface).
#
# Hot-path design, carried from the retired prototype's dominant writer:
#  - Output flows through a `ChunkWriter` — each byte copied into the output
#    exactly once, small writes batched on the stack, long spans bulk-appended.
#  - Re-emission is span concatenation: the tape stores strings and numbers as
#    raw spans of the ORIGINAL text (still escaped), so `dumps` writes
#    quote + span + quote with no escape scan at all. A round-tripped document
#    dumps at memory-bandwidth speed by construction.
#  - Escaping exists only where new text enters the world: `Serializer`'s
#    string writer (the serde path) SIMD-scans 64 bytes at a time for
#    `"  \  <0x20` and bulk-copies the clean runs between escapes.
#  - Integers via the two-digit-table writer; floats via the Writer protocol
#    (shortest-round-trip digits straight into the buffer, no temporary
#    String per value).
#  - `pretty` is a comptime knob: the indent branches erase from the compact
#    path entirely (.probe/SYNTAX.md, finding 16).

from std.bit import count_trailing_zeros
from std.memory.unsafe import pack_bits

from json._internal.bytes import (
    B_BSLASH,
    B_COLON,
    B_COMMA,
    B_LBRACE,
    B_LBRACK,
    B_LF,
    B_QUOTE,
    B_RBRACE,
    B_RBRACK,
    B_SPACE,
    B_TAB,
    CTRL_BS,
    CTRL_CR,
    CTRL_FF,
    CTRL_LF,
    B_CONTROL_MAX,
)
from json._internal.number import (
    json5_hex_to_uint,
    write_int_i64,
    write_uint_u64,
)
from json._internal.tape import (
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
from json._internal.unicode import decode_json5_string
from json._internal.writer import ChunkWriter
from json.document import Document
from json.options import SerializeOptions
from json.value import Value


comptime _NIBBLE: UInt8 = UInt8(0x0F)
comptime _HEX = String("0123456789abcdef")


# --- dumps: re-emit a parsed document or any cursor into it ----------------------


def dumps[
    origin: ImmutOrigin,
    //,
    options: SerializeOptions = SerializeOptions(),
](value: Value[origin]) raises -> String:
    """Serializes a lazy JSON value.

    Parameters:
        origin: The value's borrowed storage origin.
        options: The serialization policy.

    Args:
        value: The value to serialize.

    Returns:
        Serialized JSON text.

    Raises:
        If the value cannot be represented under the selected options.
    """
    var writer = ChunkWriter(capacity_hint=len(value._bytes) + 32)
    _write_tape[options](writer, value._bytes, value._tape, value._entry)
    return writer^.finish()


def dumps[
    options: SerializeOptions = SerializeOptions()
](doc: Document) raises -> String:
    """Serializes a complete JSON document.

    Parameters:
        options: The serialization policy.

    Args:
        doc: The document to serialize.

    Returns:
        Serialized JSON text.

    Raises:
        If the document cannot be represented under the selected options.
    """
    return dumps[options=options](doc.root())


# --- The tape walker --------------------------------------------------------------


struct _WalkFrame(Copyable, Movable, TrivialRegisterPassable):
    """One suspended ancestor container in the iterative tape walk."""

    var end_entry: Int  # entry index just past this container's subtree
    var emitted: Int  # children written so far (separator logic)
    var is_object: Bool

    @always_inline
    def __init__(out self, *, end_entry: Int, emitted: Int, is_object: Bool):
        self.end_entry = end_entry
        self.emitted = emitted
        self.is_object = is_object


def _write_tape[
    options: SerializeOptions
](
    mut writer: ChunkWriter,
    bytes: Span[UInt8, _],
    tape: Span[UInt64, _],
    root: Int,
) raises:
    """Emit the value rooted at `root` by walking the tape iteratively —
    depth lives in a heap frame stack, never on the native call stack, so a
    document parsed under any `max_depth` serializes safely (the parser's
    hostile-input hardening, kept symmetric on the way out). The innermost
    open container is cached in locals — the per-child hot path is register
    arithmetic; the List holds only suspended ancestors and is touched once
    per container open/close."""
    # Reserved past any real-world nesting up front — one allocation, no
    # growth churn on descent; hostile depth still grows amortized.
    var stack = List[_WalkFrame](capacity=64)
    var top_active = False
    var top_end = 0
    var top_emitted = 0
    var top_is_object = False
    var entry = root
    while True:
        # Close every container whose subtree just finished. A pushed frame
        # always emitted at least one child (empty containers close inline
        # below), so the pretty branch matches the recursive layout exactly.
        while top_active and entry == top_end:
            comptime if options.pretty:
                _write_newline_indent[options](writer, len(stack))
            writer.byte(B_RBRACE if top_is_object else B_RBRACK)
            if len(stack) > 0:
                var parent = stack.pop()
                top_end = parent.end_entry
                top_emitted = parent.emitted
                top_is_object = parent.is_object
            else:
                top_active = False
        if not top_active and entry != root:
            return  # the root value is complete

        var word0 = tape[entry * 2]
        if top_active:
            if top_is_object:
                # `entry` is a member key. Pairs shadowed at parse time
                # (LAST_WINS) are not live — hop key and value silently.
                if (entry_flags(word0) & FLAG_SHADOWED) != UInt8(0):
                    entry = skip_past(tape, entry + 1)
                    continue
            if top_emitted > 0:
                writer.byte(B_COMMA)
            top_emitted += 1
            comptime if options.pretty:
                _write_newline_indent[options](writer, len(stack) + 1)
            if top_is_object:
                if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
                    _reencode_string(
                        writer,
                        bytes,
                        entry_a(word0),
                        Int(tape[entry * 2 + 1]),
                    )
                else:
                    writer.byte(B_QUOTE)
                    writer.span(
                        bytes[entry_a(word0) : Int(tape[entry * 2 + 1])]
                    )
                    writer.byte(B_QUOTE)
                writer.byte(B_COLON)
                comptime if options.pretty:
                    writer.byte(B_SPACE)
                entry += 1
                word0 = tape[entry * 2]

        var tag = entry_tag(word0)
        if tag == TAG_OBJECT or tag == TAG_ARRAY:
            var is_object = tag == TAG_OBJECT
            writer.byte(B_LBRACE if is_object else B_LBRACK)
            var end = Int(tape[entry * 2 + 1])
            if end == entry + 1:  # empty — close inline, no indent
                writer.byte(B_RBRACE if is_object else B_RBRACK)
            else:
                if top_active:
                    stack.append(
                        _WalkFrame(
                            end_entry=top_end,
                            emitted=top_emitted,
                            is_object=top_is_object,
                        )
                    )
                top_active = True
                top_end = end
                top_emitted = 0
                top_is_object = is_object
            entry += 1
        elif tag == TAG_STRING:
            if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
                # JSON5 spelling: decode, then emit standard JSON.
                _reencode_string(
                    writer, bytes, entry_a(word0), Int(tape[entry * 2 + 1])
                )
            else:
                # Raw span re-emission: original text, escapes intact.
                writer.byte(B_QUOTE)
                writer.span(bytes[entry_a(word0) : Int(tape[entry * 2 + 1])])
                writer.byte(B_QUOTE)
            entry += 1
        elif tag == TAG_NUMBER:
            if (entry_flags(word0) & FLAG_REENCODE) != UInt8(0):
                _reencode_number(
                    writer, bytes, entry_a(word0), Int(tape[entry * 2 + 1])
                )
            else:
                writer.span(bytes[entry_a(word0) : Int(tape[entry * 2 + 1])])
            entry += 1
        elif tag == TAG_BOOLEAN:
            if entry_a(word0) == 1:
                writer.lit("true")
            else:
                writer.lit("false")
            entry += 1
        else:  # TAG_NULL
            writer.lit("null")
            entry += 1


@always_inline
def _write_newline_indent[
    options: SerializeOptions
](mut writer: ChunkWriter, depth: Int):
    writer.byte(B_LF)
    for _ in range(options.indent * depth):
        writer.byte(options.indent_byte)


def _reencode_string(
    mut writer: ChunkWriter, bytes: Span[UInt8, _], start: Int, end: Int
) raises:
    """A JSON5 string spelling (FLAG_REENCODE) emits as standard JSON:
    decode with the JSON5 decoder, escape with the serializer's scanner."""
    var decoded = decode_json5_string(bytes, start, end)
    writer.byte(B_QUOTE)
    _escape_into(writer, decoded.as_bytes())
    writer.byte(B_QUOTE)


def _reencode_number(
    mut writer: ChunkWriter, bytes: Span[UInt8, _], start: Int, end: Int
) raises:
    """A JSON5 number spelling emits as standard JSON, value-exactly where
    text transforms suffice: `+` strips, bare dots gain their zero, hex
    re-bases through UInt64 (Float64 beyond 64 bits — ES numbers are
    doubles). Infinity/NaN refuse, per the serializer's RFC 8259 contract."""
    var i = start
    var negative = False
    if bytes[i] == UInt8(0x2D):  # -
        negative = True
        i += 1
    elif bytes[i] == UInt8(0x2B):  # + strips
        i += 1
    if bytes[i] == UInt8(0x49) or bytes[i] == UInt8(0x4E):  # Infinity / NaN
        raise Error(
            "json.serialize: JSON5 Infinity/NaN are not representable in"
            " RFC 8259 output"
        )
    if (
        i + 1 < end
        and bytes[i] == UInt8(0x30)
        and (bytes[i + 1] == UInt8(0x78) or bytes[i + 1] == UInt8(0x58))
    ):
        var exact = json5_hex_to_uint(bytes, i, end)
        if exact:
            if negative:
                writer.byte(UInt8(0x2D))
            write_uint_u64(writer, exact.value())
            return
        var value = Float64(0.0)
        var k = i + 2
        while k < end:
            var c = bytes[k]
            var d: Int
            if c >= UInt8(0x30) and c <= UInt8(0x39):
                d = Int(c - UInt8(0x30))
            elif c >= UInt8(0x61) and c <= UInt8(0x66):
                d = Int(c - UInt8(0x61)) + 10
            else:
                d = Int(c - UInt8(0x41)) + 10
            value = value * 16.0 + Float64(d)
            k += 1
        if negative:
            value = -value
        value.write_to(writer)
        return
    if negative:
        writer.byte(UInt8(0x2D))
    if bytes[i] == UInt8(0x2E):  # .5 -> 0.5
        writer.byte(UInt8(0x30))
    var k2 = i
    var last_dot = False
    while k2 < end:
        writer.byte(bytes[k2])
        last_dot = bytes[k2] == UInt8(0x2E)
        k2 += 1
    if last_dot:  # 5. -> 5.0
        writer.byte(UInt8(0x30))


# --- Serializer: the sink ToJson implementations write into -----------------------


struct Serializer(Movable):
    """Streaming JSON emitter over a `ChunkWriter`. `ToJson` conformances call
    these primitives; correctness of separator placement is the caller's
    contract (the serde layer drives it), keeping every write branch-free."""

    var _writer: ChunkWriter

    def __init__(out self, *, capacity_hint: Int = 256):
        """Creates a serializer with an initial capacity hint.

        Args:
            capacity_hint: The expected output byte count.
        """
        self._writer = ChunkWriter(capacity_hint=capacity_hint)

    def finish(deinit self) -> String:
        """Finishes serialization and returns the output.

        Returns:
            The accumulated JSON text.
        """
        return self._writer^.finish()

    # --- Scalars ---------------------------------------------------------------

    @always_inline
    def write_null(mut self):
        """Writes a JSON null value."""
        self._writer.lit("null")

    @always_inline
    def write_bool(mut self, value: Bool):
        """Writes a JSON boolean.

        Args:
            value: The boolean value.
        """
        if value:
            self._writer.lit("true")
        else:
            self._writer.lit("false")

    @always_inline
    def write_int(mut self, value: Int64):
        """Writes a signed JSON integer.

        Args:
            value: The integer value.
        """
        write_int_i64(self._writer, value)

    @always_inline
    def write_uint(mut self, value: UInt64):
        """Writes an unsigned JSON integer.

        Args:
            value: The integer value.
        """
        write_uint_u64(self._writer, value)

    def write_float(mut self, value: Float64) raises:
        """Writes a finite JSON number.

        Args:
            value: The floating-point value.

        Raises:
            If `value` is NaN or infinity.
        """
        # RFC 8259 §6: NaN and Infinity are not JSON numbers.
        if value != value:
            raise Error("json.serialize: NaN is not representable in JSON")
        if value > Float64.MAX_FINITE or value < -Float64.MAX_FINITE:
            raise Error("json.serialize: infinity is not representable in JSON")
        # Shortest-round-trip digits via the Writer protocol — no temp String.
        value.write_to(self._writer)

    def write_string(mut self, value: StringSlice):
        """Writes quoted and escaped JSON text.

        Args:
            value: The string content.
        """
        self._writer.byte(B_QUOTE)
        _escape_into(self._writer, value.as_bytes())
        self._writer.byte(B_QUOTE)

    # --- Structure (driven by the serde layer) ----------------------------------

    @always_inline
    def begin_object(mut self):
        """Writes an object-opening delimiter."""
        self._writer.byte(B_LBRACE)

    @always_inline
    def end_object(mut self):
        """Writes an object-closing delimiter."""
        self._writer.byte(B_RBRACE)

    @always_inline
    def begin_array(mut self):
        """Writes an array-opening delimiter."""
        self._writer.byte(B_LBRACK)

    @always_inline
    def end_array(mut self):
        """Writes an array-closing delimiter."""
        self._writer.byte(B_RBRACK)

    @always_inline
    def separator(mut self):
        """Writes a value separator."""
        self._writer.byte(B_COMMA)

    def key(mut self, name: StringSlice):
        """Writes an escaped object key and colon.

        Args:
            name: The object member name.
        """
        self.write_string(name)
        self._writer.byte(B_COLON)


# --- String escaping — SIMD scan for `" \ <0x20`, bulk-copy the clean runs -------


def _escape_into(mut writer: ChunkWriter, bytes: Span[UInt8, _]):
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var i = 0
    var start = 0
    comptime W = 64
    var v_quote = SIMD[DType.uint8, W](B_QUOTE)
    var v_backslash = SIMD[DType.uint8, W](B_BSLASH)
    var v_control = SIMD[DType.uint8, W](B_CONTROL_MAX)
    while i + W <= n:
        var chunk = ptr.load[width=W](i)
        var mask = pack_bits[dtype=DType.uint64](
            chunk.eq(v_quote) | chunk.eq(v_backslash) | chunk.lt(v_control)
        )
        if mask == UInt64(0):
            i += W
            continue
        var bits = mask
        while bits != UInt64(0):
            var pos = i + Int(count_trailing_zeros(bits))
            if pos > start:
                writer.span(Span(ptr=ptr + start, length=pos - start))
            _emit_escape(writer, ptr[pos])
            start = pos + 1
            bits &= bits - UInt64(1)
        i += W
    while i < n:
        var c = ptr[i]
        if c == B_QUOTE or c == B_BSLASH or c < B_CONTROL_MAX:
            if i > start:
                writer.span(Span(ptr=ptr + start, length=i - start))
            _emit_escape(writer, c)
            start = i + 1
        i += 1
    if start < n:
        writer.span(Span(ptr=ptr + start, length=n - start))


@always_inline
def _emit_escape(mut writer: ChunkWriter, c: UInt8):
    if c == B_QUOTE:
        writer.lit('\\"')
    elif c == B_BSLASH:
        writer.lit("\\\\")
    elif c == CTRL_BS:
        writer.lit("\\b")
    elif c == B_TAB:
        writer.lit("\\t")
    elif c == CTRL_LF:
        writer.lit("\\n")
    elif c == CTRL_FF:
        writer.lit("\\f")
    elif c == CTRL_CR:
        writer.lit("\\r")
    else:
        # Any other control byte < 0x20 → \u00XX.
        writer.lit("\\u00")
        var hex_bytes = _HEX.as_bytes()
        writer.byte(hex_bytes[Int((c >> UInt8(4)) & _NIBBLE)])
        writer.byte(hex_bytes[Int(c & _NIBBLE)])
