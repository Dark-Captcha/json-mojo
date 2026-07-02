# tape — stage 2: walk the structural index, validate the complete RFC 8259
# grammar (every reject citable, every error carrying its byte offset), and
# build the six-kind skip-link tape (ARCHITECTURE.md, Type Scheme Layer 1).
#
# Entries are uniform two-word records, so value i lives at words [2i, 2i+1]:
#
#   word 0: [ tag:8 | flags:8 | a:48 ]     word 1: [ b:64 ]
#
#   null      a,b unused          boolean  a = 0 or 1
#   number    a = span start, b = span end          (raw text, lossless)
#   string    a = content start, b = content end    (between the quotes;
#             FLAG_ESCAPED set iff a backslash occurs — the zero-copy hint;
#             FLAG_SHADOWED on a key iff a later duplicate superseded this
#             member under LAST_WINS — readers present survivors only)
#   array     a = element count, b = skip (entry index past the subtree)
#   object    a = member count,  b = skip; members are key string + value
#             (a counts SURVIVING members — shadowed pairs stay on the tape
#             physically but are excluded from the count)
#
# Grammar walking is iterative — the explicit frame stack is bounded by
# `options.max_depth` (hostile-input contract; the one runtime counter).
# Atoms (numbers, true/false/null) never appear in the structural index;
# they are found in the gaps between structurals and validated against the
# RFC 8259 §6 number grammar / exact literal spelling. Strings are
# validated at parse time — control bytes, escape validity, `\uXXXX` hex,
# and surrogate pairing (unpaired escapes rejected always: a lone
# surrogate is unencodable in a UTF-8 String) — so access never re-checks.

from std.bit import count_trailing_zeros
from std.memory.unsafe import pack_bits

from json._internal.stage_one import StructuralIndex
from json._internal.unicode import decode_escaped_string, validate_utf8_span
from json.options import ParseOptions


comptime TAG_NULL: UInt8 = UInt8(0)
comptime TAG_BOOLEAN: UInt8 = UInt8(1)
comptime TAG_NUMBER: UInt8 = UInt8(2)
comptime TAG_STRING: UInt8 = UInt8(3)
comptime TAG_ARRAY: UInt8 = UInt8(4)
comptime TAG_OBJECT: UInt8 = UInt8(5)

comptime FLAG_ESCAPED: UInt8 = UInt8(1)
comptime FLAG_SHADOWED: UInt8 = UInt8(2)

comptime _A_MASK: UInt64 = (UInt64(1) << 48) - 1


@always_inline
def make_word0(tag: UInt8, flags: UInt8, a: Int) -> UInt64:
    debug_assert(
        a >= 0 and UInt64(a) <= _A_MASK, "tape a-field exceeds 48 bits"
    )
    return (UInt64(tag) << 56) | (UInt64(flags) << 48) | (UInt64(a) & _A_MASK)


@always_inline
def entry_tag(word0: UInt64) -> UInt8:
    return UInt8(word0 >> 56)


@always_inline
def entry_flags(word0: UInt64) -> UInt8:
    return UInt8((word0 >> 48) & UInt64(0xFF))


@always_inline
def entry_a(word0: UInt64) -> Int:
    return Int(word0 & _A_MASK)


@always_inline
def skip_past(tape: Span[UInt64, _], entry: Int) -> Int:
    """The entry index just past the value at `entry` — containers hop their
    skip-link, scalars advance by one. The tape-walking primitive shared by
    the cursor, its iterators, and the serializer."""
    var tag = entry_tag(tape[entry * 2])
    if tag == TAG_ARRAY or tag == TAG_OBJECT:
        return Int(tape[entry * 2 + 1])
    return entry + 1


# --- Grammar states (one per open container frame) ----------------------------

comptime _EXPECT_KEY_OR_CLOSE: UInt8 = UInt8(0)  # after '{'
comptime _EXPECT_KEY: UInt8 = UInt8(1)  # after ',' in object
comptime _EXPECT_COLON: UInt8 = UInt8(2)  # after a key
comptime _EXPECT_OBJECT_VALUE: UInt8 = UInt8(3)  # after ':'
comptime _EXPECT_OBJECT_NEXT: UInt8 = UInt8(4)  # after a member value
comptime _EXPECT_FIRST_OR_CLOSE: UInt8 = UInt8(5)  # after '['
comptime _EXPECT_ELEMENT: UInt8 = UInt8(6)  # after ',' in array
comptime _EXPECT_ARRAY_NEXT: UInt8 = UInt8(7)  # after an element


struct _Frame(Copyable, Movable, TrivialRegisterPassable):
    var tape_entry: Int  # this container's entry index (to patch a and b)
    var state: UInt8
    var count: Int
    var is_object: Bool
    # Current member key span (objects) — two stores per member, read only
    # when an error needs its RFC 6901 path.
    var key_start: Int
    var key_end: Int

    @always_inline
    def __init__(out self, *, tape_entry: Int, state: UInt8, is_object: Bool):
        self.tape_entry = tape_entry
        self.state = state
        self.count = 0
        self.is_object = is_object
        self.key_start = 0
        self.key_end = 0


def _error(message: String, offset: Int) raises:
    raise Error("json.parse: " + message + " at byte " + String(offset))


def _describe_path(stack: List[_Frame], bytes: Span[UInt8, _]) -> String:
    """The RFC 6901 path of the open position — appended to parse errors so a
    failure inside a large document is findable. Built only on the error
    path; the hot loop pays nothing beyond the per-member key-span stores."""
    var path = String("")
    for i in range(len(stack)):
        path += "/"
        if stack[i].is_object:
            if stack[i].key_end > stack[i].key_start:
                for k in range(stack[i].key_start, stack[i].key_end):
                    path += chr(Int(bytes[k]))
            else:
                path += "?"
        else:
            path += String(stack[i].count)
    return path^


# --- Atom validators -----------------------------------------------------------


@always_inline
def _is_whitespace(byte: UInt8) -> Bool:
    # RFC 8259 §2: space, tab, line feed, carriage return — nothing else.
    return (
        byte == UInt8(0x20)
        or byte == UInt8(0x09)
        or byte == UInt8(0x0A)
        or byte == UInt8(0x0D)
    )


def _validate_number(bytes: Span[UInt8, _], start: Int, end: Int) raises:
    """RFC 8259 §6: -?(0|[1-9]digits)(.digits)?([eE][+-]?digits)?"""
    var i = start
    if i < end and bytes[i] == UInt8(ord("-")):
        i += 1
    if i >= end:
        _error("number is missing digits", start)
    if bytes[i] == UInt8(ord("0")):
        i += 1
    elif bytes[i] >= UInt8(ord("1")) and bytes[i] <= UInt8(ord("9")):
        while (
            i < end
            and bytes[i] >= UInt8(ord("0"))
            and bytes[i] <= UInt8(ord("9"))
        ):
            i += 1
    else:
        _error("number has an invalid leading digit", i)
    if i < end and bytes[i] == UInt8(ord(".")):
        i += 1
        if i >= end or bytes[i] < UInt8(ord("0")) or bytes[i] > UInt8(ord("9")):
            _error("number has a bare decimal point", i)
        while (
            i < end
            and bytes[i] >= UInt8(ord("0"))
            and bytes[i] <= UInt8(ord("9"))
        ):
            i += 1
    if i < end and (bytes[i] == UInt8(ord("e")) or bytes[i] == UInt8(ord("E"))):
        i += 1
        if i < end and (
            bytes[i] == UInt8(ord("+")) or bytes[i] == UInt8(ord("-"))
        ):
            i += 1
        if i >= end or bytes[i] < UInt8(ord("0")) or bytes[i] > UInt8(ord("9")):
            _error("number has an empty exponent", i)
        while (
            i < end
            and bytes[i] >= UInt8(ord("0"))
            and bytes[i] <= UInt8(ord("9"))
        ):
            i += 1
    if i != end:
        _error("number has trailing characters", i)


def _validate_literal(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> UInt64:
    """Exact `true` / `false` / `null` spelling. Returns the tape word0."""
    var length = end - start
    if length == 4 and bytes[start] == UInt8(ord("t")):
        if (
            bytes[start + 1] == UInt8(ord("r"))
            and bytes[start + 2] == UInt8(ord("u"))
            and bytes[start + 3] == UInt8(ord("e"))
        ):
            return make_word0(TAG_BOOLEAN, UInt8(0), 1)
    elif length == 5 and bytes[start] == UInt8(ord("f")):
        if (
            bytes[start + 1] == UInt8(ord("a"))
            and bytes[start + 2] == UInt8(ord("l"))
            and bytes[start + 3] == UInt8(ord("s"))
            and bytes[start + 4] == UInt8(ord("e"))
        ):
            return make_word0(TAG_BOOLEAN, UInt8(0), 0)
    elif length == 4 and bytes[start] == UInt8(ord("n")):
        if (
            bytes[start + 1] == UInt8(ord("u"))
            and bytes[start + 2] == UInt8(ord("l"))
            and bytes[start + 3] == UInt8(ord("l"))
        ):
            return make_word0(TAG_NULL, UInt8(0), 0)
    _error("unrecognized literal", start)
    return 0  # unreachable


@always_inline
def _hex_value(byte: UInt8) -> Int:
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return Int(byte - UInt8(ord("0")))
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("f")):
        return Int(byte - UInt8(ord("a"))) + 10
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("F")):
        return Int(byte - UInt8(ord("A"))) + 10
    return -1


def _read_hex4(bytes: Span[UInt8, _], i: Int, end: Int) raises -> Int:
    if i + 4 > end:
        _error("truncated \\u escape", i)
    var code = 0
    for k in range(4):
        var v = _hex_value(bytes[i + k])
        if v < 0:
            _error("non-hexadecimal digit in \\u escape", i + k)
        code = code * 16 + v
    return code


def _validate_string(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> Bool:
    """Validate a string body (between the quotes) per RFC 8259 §7: no raw
    control bytes, only legal escapes, `\\uXXXX` well-formed, surrogates
    paired. Returns True iff the body contains any escape (the lazy-decode
    hint).

    UTF-8 validity (RFC 3629) is checked HERE, lazily: the RFC 8259 grammar
    confines non-ASCII to string bodies (stage 2 rejects any high byte in
    atoms, and structurals/whitespace are ASCII by definition), so a body
    that never sees a byte >= 0x80 needs no UTF-8 work at all — and there is
    no whole-input validation pass. Clean runs are skipped 64 bytes at a
    time; only escapes and control bytes drop to the scalar walk."""
    var has_escape = False
    var saw_high = False
    var ptr = bytes.unsafe_ptr()
    comptime W = 64
    comptime V = SIMD[DType.uint8, W]
    var i = start
    while i < end:
        # SIMD skip over clean interior: no backslash, no control byte.
        while i + W <= end:
            var chunk = ptr.load[width=W](i)
            if pack_bits[dtype=DType.uint64](
                (chunk & V(UInt8(0x80))).ne(V(0))
            ) != UInt64(0):
                saw_high = True
            var special = pack_bits[dtype=DType.uint64](
                chunk.eq(V(UInt8(0x5C)))
            ) | pack_bits[dtype=DType.uint64](chunk.lt(V(UInt8(0x20))))
            if special == UInt64(0):
                i += W
                continue
            i += Int(count_trailing_zeros(special))
            break
        if i >= end:
            break
        var byte = bytes[i]
        if byte >= UInt8(0x80):
            saw_high = True
            i += 1
            continue
        if byte < UInt8(0x20):
            _error("raw control character in string", i)
        if byte != UInt8(ord("\\")):
            i += 1
            continue
        has_escape = True
        i += 1
        if i >= end:
            _error("string ends in a bare backslash", i)
        var escape = bytes[i]
        if (
            escape == UInt8(ord('"'))
            or escape == UInt8(ord("\\"))
            or escape == UInt8(ord("/"))
            or escape == UInt8(ord("b"))
            or escape == UInt8(ord("f"))
            or escape == UInt8(ord("n"))
            or escape == UInt8(ord("r"))
            or escape == UInt8(ord("t"))
        ):
            i += 1
            continue
        if escape != UInt8(ord("u")):
            _error("invalid escape character", i)
        var code = _read_hex4(bytes, i + 1, end)
        i += 5
        if code >= 0xD800 and code <= 0xDBFF:
            # High surrogate: the low half must follow immediately.
            if (
                i + 1 >= end
                or bytes[i] != UInt8(ord("\\"))
                or bytes[i + 1] != UInt8(ord("u"))
            ):
                _error("unpaired high surrogate escape", i)
            var low = _read_hex4(bytes, i + 2, end)
            if low < 0xDC00 or low > 0xDFFF:
                _error("invalid low surrogate escape", i + 2)
            i += 6
        elif code >= 0xDC00 and code <= 0xDFFF:
            _error("unpaired low surrogate escape", i)
    if saw_high:
        # Non-ASCII present: validate this body as UTF-8 (RFC 3629) — string
        # bodies are the only place non-ASCII can legally occur, so this IS
        # the document's UTF-8 gate. Pure-ASCII bodies pay nothing.
        validate_utf8_span(bytes, start, end)
    return has_escape


# --- Stage 2 -------------------------------------------------------------------


def build_tape[
    options: ParseOptions = ParseOptions()
](text: String, index: StructuralIndex, start: Int = 0) raises -> List[UInt64]:
    """Validate the document and build its tape. Raises `json.parse:` errors
    carrying the byte offset and the RFC 6901 path of the failure; on success
    the tape's entry 0 is the root. `start` skips a leading byte-order mark
    the caller already ruled on."""
    var stack = List[_Frame](capacity=16)
    try:
        return _build_tape_inner[options](text, index, start, stack)
    except error:
        var path = _describe_path(stack, text.as_bytes())
        if path.byte_length() > 0:
            raise Error(String(error) + " in " + path)
        raise error^


def _build_tape_inner[
    options: ParseOptions
](
    text: String,
    index: StructuralIndex,
    start: Int,
    mut stack: List[_Frame],
) raises -> List[UInt64]:
    var bytes = text.as_bytes()
    var length = len(bytes)
    ref positions = index.positions

    var tape = List[UInt64](capacity=len(positions) * 2 + 8)
    var root_seen = False

    # `cursor` walks raw bytes between structurals; `p` walks the index.
    var cursor = start
    var p = 0

    while True:
        var next_structural = length if p >= len(positions) else Int(
            positions[p]
        )

        # --- The gap before the next structural may hold one atom. --------
        while cursor < next_structural and _is_whitespace(bytes[cursor]):
            cursor += 1
        if cursor < next_structural:
            var atom_start = cursor
            while cursor < next_structural and not _is_whitespace(
                bytes[cursor]
            ):
                cursor += 1
            var atom_end = cursor
            while cursor < next_structural and _is_whitespace(bytes[cursor]):
                cursor += 1
            if cursor < next_structural:
                _error("unexpected characters after value", cursor)
            _begin_value(stack, root_seen, atom_start)
            var first = bytes[atom_start]
            if first == UInt8(ord("-")) or (
                first >= UInt8(ord("0")) and first <= UInt8(ord("9"))
            ):
                _validate_number(bytes, atom_start, atom_end)
                tape.append(make_word0(TAG_NUMBER, UInt8(0), atom_start))
                tape.append(UInt64(atom_end))
            else:
                tape.append(_validate_literal(bytes, atom_start, atom_end))
                tape.append(UInt64(0))
            _end_value(stack, root_seen)

        if p >= len(positions):
            break
        var at = Int(positions[p])
        var byte = bytes[at]
        p += 1

        if byte == UInt8(ord('"')):
            # The matching close is the next structural — stage 1 emits both.
            if p >= len(positions) or bytes[Int(positions[p])] != UInt8(
                ord('"')
            ):
                _error("unterminated string", at)
            var close = Int(positions[p])
            p += 1
            var escaped = _validate_string(bytes, at + 1, close)
            var flags = FLAG_ESCAPED if escaped else UInt8(0)

            # A string is either an object key or a value.
            var is_key = False
            if len(stack) > 0:
                var state = stack[len(stack) - 1].state
                if state == _EXPECT_KEY_OR_CLOSE or state == _EXPECT_KEY:
                    is_key = True
            if is_key:
                comptime if options.rejects_duplicates():
                    _check_duplicate_key(
                        bytes,
                        tape,
                        stack[len(stack) - 1],
                        at + 1,
                        close,
                        escaped,
                    )
                comptime if options.shadows_duplicates():
                    if _shadow_duplicate_key(
                        bytes,
                        tape,
                        stack[len(stack) - 1],
                        at + 1,
                        close,
                        escaped,
                    ):
                        stack[len(stack) - 1].count -= 1
                stack[len(stack) - 1].state = _EXPECT_COLON
                stack[len(stack) - 1].key_start = at + 1
                stack[len(stack) - 1].key_end = close
                tape.append(make_word0(TAG_STRING, flags, at + 1))
                tape.append(UInt64(close))
            else:
                _begin_value(stack, root_seen, at)
                tape.append(make_word0(TAG_STRING, flags, at + 1))
                tape.append(UInt64(close))
                _end_value(stack, root_seen)
            cursor = close + 1
            continue

        if byte == UInt8(ord("{")) or byte == UInt8(ord("[")):
            _begin_value(stack, root_seen, at)
            if len(stack) >= options.max_depth:
                _error("nesting depth limit exceeded", at)
            var is_object = byte == UInt8(ord("{"))
            var entry = len(tape) // 2
            tape.append(
                make_word0(TAG_OBJECT if is_object else TAG_ARRAY, UInt8(0), 0)
            )
            tape.append(UInt64(0))
            stack.append(
                _Frame(
                    tape_entry=entry,
                    state=_EXPECT_KEY_OR_CLOSE if is_object else _EXPECT_FIRST_OR_CLOSE,
                    is_object=is_object,
                )
            )
            cursor = at + 1
            continue

        if byte == UInt8(ord("}")) or byte == UInt8(ord("]")):
            if len(stack) == 0:
                _error("close with no open container", at)
            var frame = stack[len(stack) - 1]
            var closing_object = byte == UInt8(ord("}"))
            if frame.is_object != closing_object:
                _error("mismatched container close", at)
            if closing_object:
                if (
                    frame.state != _EXPECT_KEY_OR_CLOSE
                    and frame.state != _EXPECT_OBJECT_NEXT
                ):
                    _error("unexpected '}'", at)
            else:
                if (
                    frame.state != _EXPECT_FIRST_OR_CLOSE
                    and frame.state != _EXPECT_ARRAY_NEXT
                ):
                    _error("unexpected ']'", at)
            _ = stack.pop()
            # Patch count and skip-link into the container's entry.
            var word0 = tape[frame.tape_entry * 2]
            tape[frame.tape_entry * 2] = make_word0(
                entry_tag(word0), UInt8(0), frame.count
            )
            tape[frame.tape_entry * 2 + 1] = UInt64(len(tape) // 2)
            _end_value(stack, root_seen)
            cursor = at + 1
            continue

        if byte == UInt8(ord(",")):
            if len(stack) == 0:
                _error("',' outside any container", at)
            var state = stack[len(stack) - 1].state
            if stack[len(stack) - 1].is_object:
                if state != _EXPECT_OBJECT_NEXT:
                    _error("unexpected ','", at)
                stack[len(stack) - 1].state = _EXPECT_KEY
            else:
                if state != _EXPECT_ARRAY_NEXT:
                    _error("unexpected ','", at)
                stack[len(stack) - 1].state = _EXPECT_ELEMENT
            cursor = at + 1
            continue

        # ':'
        if len(stack) == 0 or not stack[len(stack) - 1].is_object:
            _error("':' outside an object", at)
        if stack[len(stack) - 1].state != _EXPECT_COLON:
            _error("unexpected ':'", at)
        stack[len(stack) - 1].state = _EXPECT_OBJECT_VALUE
        cursor = at + 1

    if len(stack) != 0:
        _error("unterminated container at end of input", length)
    if not root_seen:
        _error("no value in document", 0)
    return tape^


def _begin_value(mut stack: List[_Frame], mut root_seen: Bool, at: Int) raises:
    """A value is about to be emitted — legal here?"""
    if len(stack) == 0:
        if root_seen:
            _error("trailing content after the document", at)
        return
    var state = stack[len(stack) - 1].state
    if stack[len(stack) - 1].is_object:
        if state != _EXPECT_OBJECT_VALUE:
            _error("value where a key or separator is required", at)
    else:
        if state != _EXPECT_FIRST_OR_CLOSE and state != _EXPECT_ELEMENT:
            _error("value where a separator is required", at)


def _end_value(mut stack: List[_Frame], mut root_seen: Bool):
    """A value finished — advance the enclosing frame's state."""
    if len(stack) == 0:
        root_seen = True
        return
    stack[len(stack) - 1].count += 1
    if stack[len(stack) - 1].is_object:
        stack[len(stack) - 1].state = _EXPECT_OBJECT_NEXT
    else:
        stack[len(stack) - 1].state = _EXPECT_ARRAY_NEXT


def _keys_equal(
    bytes: Span[UInt8, _],
    a_start: Int,
    a_end: Int,
    a_escaped: Bool,
    b_start: Int,
    b_end: Int,
    b_escaped: Bool,
) -> Bool:
    """Member-name equality by CHARACTER (RFC 7493 §2.3), matching the lookup
    path's `_key_matches`: escaped spellings decode before comparing, so
    `"\\u0061"` and `"a"` are the same name to every duplicate policy. Both
    spans were validated when their strings were parsed, which is what makes
    the trusted decoder sound here."""
    if not a_escaped and not b_escaped:
        if a_end - a_start != b_end - b_start:
            return False
        for k in range(a_end - a_start):
            if bytes[a_start + k] != bytes[b_start + k]:
                return False
        return True
    var a = decode_escaped_string(
        bytes, a_start, a_end
    ) if a_escaped else String(unsafe_from_utf8=bytes[a_start:a_end])
    var b = decode_escaped_string(
        bytes, b_start, b_end
    ) if b_escaped else String(unsafe_from_utf8=bytes[b_start:b_end])
    return a == b


@always_inline
def _next_member(tape: List[UInt64], entry: Int) -> Int:
    """From a key entry to the next member's key entry (hop the value)."""
    var value_entry = entry + 1
    var value_word0 = tape[value_entry * 2]
    var value_tag = entry_tag(value_word0)
    if value_tag == TAG_ARRAY or value_tag == TAG_OBJECT:
        return Int(tape[value_entry * 2 + 1])
    return value_entry + 1


def _check_duplicate_key(
    bytes: Span[UInt8, _],
    tape: List[UInt64],
    frame: _Frame,
    start: Int,
    end: Int,
    escaped: Bool,
) raises:
    """REJECT policy: compare the new key against every earlier key in this
    object. Priced honestly in ARCHITECTURE.md — only compiled in when the
    policy asks for it. No shadowed entries can exist here: rejection raises
    on the first duplicate, so every walked key is live."""
    var entry = frame.tape_entry + 1  # first child entry
    var walked = 0
    while walked < frame.count:
        # Key entry for member `walked`.
        var word0 = tape[entry * 2]
        if _keys_equal(
            bytes,
            entry_a(word0),
            Int(tape[entry * 2 + 1]),
            (entry_flags(word0) & FLAG_ESCAPED) != UInt8(0),
            start,
            end,
            escaped,
        ):
            _error("duplicate object member name", start)
        entry = _next_member(tape, entry)
        walked += 1


def _shadow_duplicate_key(
    bytes: Span[UInt8, _],
    mut tape: List[UInt64],
    frame: _Frame,
    start: Int,
    end: Int,
    escaped: Bool,
) -> Bool:
    """LAST_WINS policy: if an earlier live member has this name, mark its key
    entry FLAG_SHADOWED and report True (the caller drops it from the frame's
    count). At most one live match can exist — every earlier duplicate was
    shadowed when its successor arrived — so the walk stops at the first."""
    var entry = frame.tape_entry + 1  # first child entry
    var walked = 0
    while walked < frame.count:
        var word0 = tape[entry * 2]
        # Shadowed entries are not live members: skip without counting.
        if (entry_flags(word0) & FLAG_SHADOWED) != UInt8(0):
            entry = _next_member(tape, entry)
            continue
        if _keys_equal(
            bytes,
            entry_a(word0),
            Int(tape[entry * 2 + 1]),
            (entry_flags(word0) & FLAG_ESCAPED) != UInt8(0),
            start,
            end,
            escaped,
        ):
            tape[entry * 2] = word0 | (UInt64(FLAG_SHADOWED) << 48)
            return True
        entry = _next_member(tape, entry)
        walked += 1
    return False
