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
    B_COLON,
    B_COMMA,
    B_LBRACE,
    B_LBRACK,
    B_LF,
    B_QUOTE,
    B_RBRACE,
    B_RBRACK,
    B_SPACE,
)
from json._internal.number import write_int_i64, write_uint_u64
from json._internal.tape import (
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
from json._internal.writer import ChunkWriter
from json.document import Document
from json.options import SerializeOptions
from json.value import Value


comptime _INDENT_WIDTH: Int = 2
comptime _HEX = String("0123456789abcdef")


# --- dumps: re-emit a parsed document or any cursor into it ----------------------


def dumps[
    origin: ImmutOrigin,
    //,
    options: SerializeOptions = SerializeOptions(),
](value: Value[origin]) raises -> String:
    """Render the value under `value` as JSON text. Compact by default;
    `SerializeOptions(pretty=True)` indents with two spaces."""
    var writer = ChunkWriter(capacity_hint=len(value._bytes) + 32)
    _write_tape[options](writer, value._bytes, value._tape, value._entry)
    return writer^.finish()


def dumps[
    options: SerializeOptions = SerializeOptions()
](doc: Document) raises -> String:
    """Render a whole document — `dumps(doc)` is `dumps(doc.root())`."""
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
                _write_newline_indent(writer, len(stack))
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
                _write_newline_indent(writer, len(stack) + 1)
            if top_is_object:
                writer.byte(B_QUOTE)
                writer.span(bytes[entry_a(word0) : Int(tape[entry * 2 + 1])])
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
            # Raw span re-emission: the body is original text, escapes intact.
            writer.byte(B_QUOTE)
            writer.span(bytes[entry_a(word0) : Int(tape[entry * 2 + 1])])
            writer.byte(B_QUOTE)
            entry += 1
        elif tag == TAG_NUMBER:
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
def _write_newline_indent(mut writer: ChunkWriter, depth: Int):
    writer.byte(B_LF)
    for _ in range(_INDENT_WIDTH * depth):
        writer.byte(B_SPACE)


# --- Serializer: the sink ToJson implementations write into -----------------------


struct Serializer(Movable):
    """Streaming JSON emitter over a `ChunkWriter`. `ToJson` conformances call
    these primitives; correctness of separator placement is the caller's
    contract (the serde layer drives it), keeping every write branch-free."""

    var _writer: ChunkWriter

    def __init__(out self, *, capacity_hint: Int = 256):
        self._writer = ChunkWriter(capacity_hint=capacity_hint)

    def finish(deinit self) -> String:
        return self._writer^.finish()

    # --- Scalars ---------------------------------------------------------------

    @always_inline
    def write_null(mut self):
        self._writer.lit("null")

    @always_inline
    def write_bool(mut self, value: Bool):
        if value:
            self._writer.lit("true")
        else:
            self._writer.lit("false")

    @always_inline
    def write_int(mut self, value: Int64):
        write_int_i64(self._writer, value)

    @always_inline
    def write_uint(mut self, value: UInt64):
        write_uint_u64(self._writer, value)

    def write_float(mut self, value: Float64) raises:
        # RFC 8259 §6: NaN and Infinity are not JSON numbers.
        if value != value:
            raise Error("json.serialize: NaN is not representable in JSON")
        if value > Float64.MAX_FINITE or value < -Float64.MAX_FINITE:
            raise Error("json.serialize: infinity is not representable in JSON")
        # Shortest-round-trip digits via the Writer protocol — no temp String.
        value.write_to(self._writer)

    def write_string(mut self, value: StringSlice):
        """Quote and escape new text (the serde path — parsed spans never
        come through here)."""
        self._writer.byte(B_QUOTE)
        _escape_into(self._writer, value.as_bytes())
        self._writer.byte(B_QUOTE)

    # --- Structure (driven by the serde layer) ----------------------------------

    @always_inline
    def begin_object(mut self):
        self._writer.byte(B_LBRACE)

    @always_inline
    def end_object(mut self):
        self._writer.byte(B_RBRACE)

    @always_inline
    def begin_array(mut self):
        self._writer.byte(B_LBRACK)

    @always_inline
    def end_array(mut self):
        self._writer.byte(B_RBRACK)

    @always_inline
    def separator(mut self):
        self._writer.byte(B_COMMA)

    def key(mut self, name: StringSlice):
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
    var v_backslash = SIMD[DType.uint8, W](UInt8(0x5C))
    var v_control = SIMD[DType.uint8, W](UInt8(0x20))
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
        if c == B_QUOTE or c == UInt8(0x5C) or c < UInt8(0x20):
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
    elif c == UInt8(0x5C):
        writer.lit("\\\\")
    elif c == UInt8(0x08):
        writer.lit("\\b")
    elif c == UInt8(0x09):
        writer.lit("\\t")
    elif c == UInt8(0x0A):
        writer.lit("\\n")
    elif c == UInt8(0x0C):
        writer.lit("\\f")
    elif c == UInt8(0x0D):
        writer.lit("\\r")
    else:
        # Any other control byte < 0x20 → \u00XX.
        writer.lit("\\u00")
        var hex_bytes = _HEX.as_bytes()
        writer.byte(hex_bytes[Int((c >> UInt8(4)) & UInt8(0x0F))])
        writer.byte(hex_bytes[Int(c & UInt8(0x0F))])
