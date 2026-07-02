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
# Atoms (numbers, true/false/null) enter the structural index as
# pseudo-structural START positions (stage 1's scalar-edge mask), so every
# value dispatches from a position — no whitespace gap is ever re-scanned —
# and the atom validators fuse span discovery with the RFC 8259 §6 number
# grammar / exact literal spelling, touching each byte once. Strings are
# validated at parse time — control bytes, escape validity, `\uXXXX` hex,
# and surrogate pairing (unpaired escapes rejected always: a lone
# surrogate is unencodable in a UTF-8 String) — so access never re-checks.

from std.bit import count_trailing_zeros
from std.memory.unsafe import pack_bits

from json._internal.bytes import (
    B_0,
    B_1,
    B_9,
    B_A,
    B_A_UPPER,
    B_B,
    B_BSLASH,
    B_COLON,
    B_COMMA,
    B_CR,
    B_DOT,
    B_E_LOWER,
    B_E_UPPER,
    B_F,
    B_F_UPPER,
    B_L,
    B_LBRACE,
    B_LBRACK,
    B_LF,
    B_MINUS,
    B_N,
    B_PLUS,
    B_QUOTE,
    B_R,
    B_RBRACE,
    B_RBRACK,
    B_S,
    B_SLASH,
    B_SPACE,
    B_T,
    B_TAB,
    B_TILDE,
    B_U,
)
from json._internal.stage_one import StructuralIndex
from json._internal.unicode import (
    HIGH_BIT,
    decode_escaped_string,
    decode_json5_string,
    validate_utf8_span,
)
from json.options import ParseOptions


comptime TAG_NULL: UInt8 = UInt8(0)
comptime TAG_BOOLEAN: UInt8 = UInt8(1)
comptime TAG_NUMBER: UInt8 = UInt8(2)
comptime TAG_STRING: UInt8 = UInt8(3)
comptime TAG_ARRAY: UInt8 = UInt8(4)
comptime TAG_OBJECT: UInt8 = UInt8(5)

comptime FLAG_ESCAPED: UInt8 = UInt8(1)
comptime FLAG_SHADOWED: UInt8 = UInt8(2)
# Reserved (tier-2 contract, unset by this parser): marks a span that points
# into a decoder-owned side arena rather than the input — binary front-ends
# (MessagePack/CBOR/BSON) materialize number text there (ARCHITECTURE.md,
# extension tiers; ROADMAP.md).
comptime FLAG_ARENA: UInt8 = UInt8(4)
# JSON5 lexemes whose raw span is NOT valid RFC 8259 content (single-quoted
# strings with embedded quotes/escapes, JSON5-only escapes, hex numbers,
# Infinity/NaN, leading '+' or bare-dot decimals): readers decode via the
# JSON5 decoder and `dumps` re-encodes to standard JSON instead of re-emitting
# the span verbatim.
comptime FLAG_REENCODE: UInt8 = UInt8(8)

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
    # Current member key span and flags (objects) — three stores per member,
    # read only when an error needs its RFC 6901 path.
    var key_start: Int
    var key_end: Int
    var key_flags: UInt8

    @always_inline
    def __init__(out self, *, tape_entry: Int, state: UInt8, is_object: Bool):
        self.tape_entry = tape_entry
        self.state = state
        self.count = 0
        self.is_object = is_object
        self.key_start = 0
        self.key_end = 0
        self.key_flags = 0


def _error(message: String, offset: Int) raises:
    raise Error("json.parse: " + message + " at byte " + String(offset))


def _pointer_token(key: String) -> String:
    """One RFC 6901 reference token: `~` → `~0`, `/` → `~1` (§3); all other
    bytes pass through exactly (the key is already valid UTF-8)."""
    var out = List[UInt8]()
    var bytes = key.as_bytes()
    for k in range(len(bytes)):
        var byte = bytes[k]
        if byte == B_TILDE:
            out.append(B_TILDE)
            out.append(B_0)
        elif byte == B_SLASH:
            out.append(B_TILDE)
            out.append(B_1)
        else:
            out.append(byte)
    return String(unsafe_from_utf8=out)


def _describe_path(stack: List[_Frame], bytes: Span[UInt8, _]) -> String:
    """The RFC 6901 path of the open position — appended to parse errors so a
    failure inside a large document is findable. Tokens are the DECODED
    member names with `~`/`/` escaped per §3, so the emitted pointer
    round-trips. Built only on the error path; the hot loop pays nothing
    beyond the per-member key-span stores."""
    var path = String("")
    for i in range(len(stack)):
        path += "/"
        if stack[i].is_object:
            if stack[i].key_end > stack[i].key_start:
                var key: String
                if (stack[i].key_flags & FLAG_REENCODE) != UInt8(0):
                    key = decode_json5_string(
                        bytes, stack[i].key_start, stack[i].key_end
                    )
                elif (stack[i].key_flags & FLAG_ESCAPED) != UInt8(0):
                    key = decode_escaped_string(
                        bytes, stack[i].key_start, stack[i].key_end
                    )
                else:
                    key = String(
                        unsafe_from_utf8=bytes[
                            stack[i].key_start : stack[i].key_end
                        ]
                    )
                path += _pointer_token(key)
            else:
                path += "?"
        else:
            path += String(stack[i].count)
    return path^


# --- Atom validators -----------------------------------------------------------


@always_inline
def _is_whitespace(byte: UInt8) -> Bool:
    # RFC 8259 §2: space, tab, line feed, carriage return — nothing else.
    return byte == B_SPACE or byte == B_TAB or byte == B_LF or byte == B_CR


@always_inline
def _digit_run_end(bytes: Span[UInt8, _], start: Int, end: Int) -> Int:
    """First index in [start, end) that is not an ASCII digit — hopping 16
    bytes per step. The 64-byte input tail padding makes every load legal;
    the clamp to `end` guards against padding bytes that happen to be
    digits when a number ends the document."""
    comptime W = 16
    var ptr = bytes.unsafe_ptr()
    var i = start
    while i < end:
        var chunk = ptr.load[width=W](i)
        var is_digit = chunk.ge(B_0) & chunk.le(B_9)
        var mask = pack_bits(is_digit)
        var run = Int(count_trailing_zeros(~UInt64(mask)))
        if run < W:
            i += run
            return min(i, end)
        i += W
    return end


@always_inline
def _is_atom_terminator(byte: UInt8) -> Bool:
    """A byte that may legally end an atom's span: whitespace or any byte
    stage 1 emits a position for. The grammar walker rejects misplaced
    values at their own positions — this check only stops fused garbage
    (`1x`, `trueX`) with the byte-precise error the gap design gave."""
    return (
        _is_whitespace(byte)
        or byte == B_COMMA
        or byte == B_COLON
        or byte == B_RBRACE
        or byte == B_RBRACK
        or byte == B_LBRACE
        or byte == B_LBRACK
        or byte == B_QUOTE
    )


def _validate_number_end(
    bytes: Span[UInt8, _], start: Int, limit: Int
) raises -> Int:
    """RFC 8259 §6: -?(0|[1-9]digits)(.digits)?([eE][+-]?digits)? —
    validated from `start`, returning the exclusive end of the span.
    Digit runs — the dominant bytes of number-heavy documents — advance via
    the SIMD hop above instead of per-byte compares. Span discovery and
    validation are one pass: each byte is touched exactly once, and the
    byte after the span must be an atom terminator."""
    var i = start
    if i < limit and bytes[i] == B_MINUS:
        i += 1
    if i >= limit:
        _error("number is missing digits", start)
    if bytes[i] == B_0:
        i += 1
    elif bytes[i] >= B_1 and bytes[i] <= B_9:
        i = _digit_run_end(bytes, i + 1, limit)
    else:
        _error("number has an invalid leading digit", i)
    if i < limit and bytes[i] == B_DOT:
        i += 1
        if i >= limit or bytes[i] < B_0 or bytes[i] > B_9:
            _error("number has a bare decimal point", i)
        i = _digit_run_end(bytes, i + 1, limit)
    if i < limit and (bytes[i] == B_E_LOWER or bytes[i] == B_E_UPPER):
        i += 1
        if i < limit and (bytes[i] == B_PLUS or bytes[i] == B_MINUS):
            i += 1
        if i >= limit or bytes[i] < B_0 or bytes[i] > B_9:
            _error("number has an empty exponent", i)
        i = _digit_run_end(bytes, i + 1, limit)
    if i < limit and not _is_atom_terminator(bytes[i]):
        _error("number has trailing characters", i)
    return i


def _validate_literal_at(
    bytes: Span[UInt8, _], start: Int, limit: Int
) raises -> UInt64:
    """Exact `true` / `false` / `null` spelling at `start`, terminator-
    checked. Returns the tape word0."""
    var byte = bytes[start]
    if byte == B_T and start + 4 <= limit:
        if (
            bytes[start + 1] == B_R
            and bytes[start + 2] == B_U
            and bytes[start + 3] == B_E_LOWER
            and (start + 4 == limit or _is_atom_terminator(bytes[start + 4]))
        ):
            return make_word0(TAG_BOOLEAN, UInt8(0), 1)
    elif byte == B_F and start + 5 <= limit:
        if (
            bytes[start + 1] == B_A
            and bytes[start + 2] == B_L
            and bytes[start + 3] == B_S
            and bytes[start + 4] == B_E_LOWER
            and (start + 5 == limit or _is_atom_terminator(bytes[start + 5]))
        ):
            return make_word0(TAG_BOOLEAN, UInt8(0), 0)
    elif byte == B_N and start + 4 <= limit:
        if (
            bytes[start + 1] == B_U
            and bytes[start + 2] == B_L
            and bytes[start + 3] == B_L
            and (start + 4 == limit or _is_atom_terminator(bytes[start + 4]))
        ):
            return make_word0(TAG_NULL, UInt8(0), 0)
    _error("unrecognized literal", start)
    return 0  # unreachable


@always_inline
def _hex_value(byte: UInt8) -> Int:
    if byte >= B_0 and byte <= B_9:
        return Int(byte - B_0)
    if byte >= B_A and byte <= B_F:
        return Int(byte - B_A) + 10
    if byte >= B_A_UPPER and byte <= B_F_UPPER:
        return Int(byte - B_A_UPPER) + 10
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


def _validate_string[
    options: ParseOptions = ParseOptions()
](bytes: Span[UInt8, _], start: Int, end: Int) raises -> Bool:
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
                (chunk & V(HIGH_BIT)).ne(V(0))
            ) != UInt64(0):
                saw_high = True
            var special = pack_bits[dtype=DType.uint64](
                chunk.eq(V(B_BSLASH))
            ) | pack_bits[dtype=DType.uint64](chunk.lt(V(B_SPACE)))
            if special == UInt64(0):
                i += W
                continue
            i += Int(count_trailing_zeros(special))
            break
        if i >= end:
            break
        var byte = bytes[i]
        if byte >= HIGH_BIT:
            saw_high = True
            i += 1
            continue
        if byte < B_SPACE:
            _error("raw control character in string", i)
        if byte != B_BSLASH:
            i += 1
            continue
        has_escape = True
        i += 1
        if i >= end:
            _error("string ends in a bare backslash", i)
        var escape = bytes[i]
        if (
            escape == B_QUOTE
            or escape == B_BSLASH
            or escape == B_SLASH
            or escape == B_B
            or escape == B_F
            or escape == B_N
            or escape == B_R
            or escape == B_T
        ):
            i += 1
            continue
        if escape != B_U:
            _error("invalid escape character", i)
        var code = _read_hex4(bytes, i + 1, end)
        i += 5
        if code >= 0xD800 and code <= 0xDBFF:
            # High surrogate: the low half must follow immediately.
            if i + 1 >= end or bytes[i] != B_BSLASH or bytes[i + 1] != B_U:
                _error("unpaired high surrogate escape", i)
            var low = _read_hex4(bytes, i + 2, end)
            if low < 0xDC00 or low > 0xDFFF:
                _error("invalid low surrogate escape", i + 2)
            comptime if options.rejects_noncharacters():
                var code_point = (
                    0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                )
                if (code_point & 0xFFFE) == 0xFFFE:
                    _error("noncharacter escape in I-JSON string", i)
            i += 6
        elif code >= 0xDC00 and code <= 0xDFFF:
            _error("unpaired low surrogate escape", i)
        comptime if options.rejects_noncharacters():
            # RFC 7493 §2.1, escaped spellings (raw bytes are checked by the
            # UTF-8 gate below): BMP noncharacters via a single escape.
            if (code < 0xD800 or code > 0xDFFF) and (
                (code >= 0xFDD0 and code <= 0xFDEF) or (code & 0xFFFE) == 0xFFFE
            ):
                _error("noncharacter escape in I-JSON string", i - 5)
    if saw_high:
        # Non-ASCII present: validate this body as UTF-8 (RFC 3629) — string
        # bodies are the only place non-ASCII can legally occur, so this IS
        # the document's UTF-8 gate. Pure-ASCII bodies pay nothing. I-JSON
        # additionally rejects raw noncharacters here (RFC 7493 §2.1).
        validate_utf8_span[options.rejects_noncharacters()](bytes, start, end)
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

    # The capacity is an exact upper bound, not a guess — every two-word
    # entry consumes its own index position: an atom start and an open are
    # one position each, a string holds two (its quote pair), and closes,
    # commas, and colons hold positions while writing nothing. The growth
    # branch per append is therefore provably dead: writes go through the
    # raw pointer with `words` as the write cursor, `debug_assert` re-proves
    # the bound on every input in assertion builds, and the final `shrink`
    # sets the true length.
    var bound = len(positions) * 2 + 8
    var tape = List[UInt64](unsafe_uninit_length=bound)
    var tp = tape.unsafe_ptr()
    var words = 0
    var root_seen = False

    # `p` walks the index — every value starts AT a position (atom starts
    # are pseudo-structurals), so no byte between positions is re-scanned.
    # A leading BOM's bytes are scalars to stage 1: its positions fall
    # before `start` (the caller's BOM ruling) and are skipped. When the
    # root atom ABUTS the BOM (`EF BB BF` then `1`) the two form one scalar
    # run whose only start position lies inside the BOM — dispatch that
    # atom at `start` directly; its entry charges the skipped position, so
    # the capacity bound holds.
    var p = 0
    var skipped_scalar_run = False
    while p < len(positions) and Int(positions[p]) < start:
        skipped_scalar_run = True
        p += 1
    if skipped_scalar_run and start < length:
        var first = bytes[start]
        if not _is_whitespace(first) and not _is_atom_terminator(first):
            _begin_value(stack, root_seen, start)
            debug_assert(words + 2 <= bound, "tape bound overflow")
            if first == B_MINUS or (first >= B_0 and first <= B_9):
                var atom_end = _validate_number_end(bytes, start, length)
                tp[words] = make_word0(TAG_NUMBER, UInt8(0), start)
                tp[words + 1] = UInt64(atom_end)
            else:
                tp[words] = _validate_literal_at(bytes, start, length)
                tp[words + 1] = UInt64(0)
            words += 2
            _end_value(stack, root_seen)

    while p < len(positions):
        var at = Int(positions[p])
        var byte = bytes[at]
        p += 1

        if byte == B_QUOTE:
            # The matching close is the next structural — stage 1 emits both.
            if p >= len(positions) or bytes[Int(positions[p])] != UInt8(
                ord('"')
            ):
                _error("unterminated string", at)
            var close = Int(positions[p])
            p += 1
            var escaped = _validate_string[options](bytes, at + 1, close)
            var flags = FLAG_ESCAPED if escaped else UInt8(0)

            # A string is either an object key or a value.
            var is_key = False
            if len(stack) > 0:
                var state = stack[len(stack) - 1].state
                if state == _EXPECT_KEY_OR_CLOSE or state == _EXPECT_KEY:
                    is_key = True
            if is_key:
                var key_flags = FLAG_ESCAPED if escaped else UInt8(0)
                comptime if options.rejects_duplicates():
                    _check_duplicate_key(
                        bytes,
                        tape,
                        stack[len(stack) - 1],
                        at + 1,
                        close,
                        key_flags,
                    )
                comptime if options.shadows_duplicates():
                    if _shadow_duplicate_key(
                        bytes,
                        tape,
                        stack[len(stack) - 1],
                        at + 1,
                        close,
                        key_flags,
                    ):
                        stack[len(stack) - 1].count -= 1
                stack[len(stack) - 1].state = _EXPECT_COLON
                stack[len(stack) - 1].key_start = at + 1
                stack[len(stack) - 1].key_end = close
                stack[len(stack) - 1].key_flags = flags
                debug_assert(words + 2 <= bound, "tape bound overflow")
                tp[words] = make_word0(TAG_STRING, flags, at + 1)
                tp[words + 1] = UInt64(close)
                words += 2
            else:
                _begin_value(stack, root_seen, at)
                debug_assert(words + 2 <= bound, "tape bound overflow")
                tp[words] = make_word0(TAG_STRING, flags, at + 1)
                tp[words + 1] = UInt64(close)
                words += 2
                _end_value(stack, root_seen)
            continue

        if byte == B_LBRACE or byte == B_LBRACK:
            _begin_value(stack, root_seen, at)
            if len(stack) >= options.max_depth:
                _error("nesting depth limit exceeded", at)
            var is_object = byte == B_LBRACE
            var entry = words // 2
            debug_assert(words + 2 <= bound, "tape bound overflow")
            tp[words] = make_word0(
                TAG_OBJECT if is_object else TAG_ARRAY, UInt8(0), 0
            )
            tp[words + 1] = UInt64(0)
            words += 2
            stack.append(
                _Frame(
                    tape_entry=entry,
                    state=_EXPECT_KEY_OR_CLOSE if is_object else _EXPECT_FIRST_OR_CLOSE,
                    is_object=is_object,
                )
            )
            continue

        if byte == B_RBRACE or byte == B_RBRACK:
            if len(stack) == 0:
                _error("close with no open container", at)
            var frame = stack[len(stack) - 1]
            var closing_object = byte == B_RBRACE
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
            var word0 = tp[frame.tape_entry * 2]
            tp[frame.tape_entry * 2] = make_word0(
                entry_tag(word0), UInt8(0), frame.count
            )
            tp[frame.tape_entry * 2 + 1] = UInt64(words // 2)
            _end_value(stack, root_seen)
            continue

        if byte == B_COMMA:
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
            continue

        if byte == B_COLON:
            if len(stack) == 0 or not stack[len(stack) - 1].is_object:
                _error("':' outside an object", at)
            if stack[len(stack) - 1].state != _EXPECT_COLON:
                _error("unexpected ':'", at)
            stack[len(stack) - 1].state = _EXPECT_OBJECT_VALUE
            continue

        # --- Atom start (pseudo-structural from stage 1) -------------------
        _begin_value(stack, root_seen, at)
        debug_assert(words + 2 <= bound, "tape bound overflow")
        if byte == B_MINUS or (byte >= B_0 and byte <= B_9):
            var atom_end = _validate_number_end(bytes, at, length)
            tp[words] = make_word0(TAG_NUMBER, UInt8(0), at)
            tp[words + 1] = UInt64(atom_end)
        else:
            tp[words] = _validate_literal_at(bytes, at, length)
            tp[words + 1] = UInt64(0)
        words += 2
        _end_value(stack, root_seen)

    if len(stack) != 0:
        _error("unterminated container at end of input", length)
    if not root_seen:
        _error("no value in document", 0)
    tape.shrink(words)
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


@always_inline
def _decode_key(
    bytes: Span[UInt8, _], start: Int, end: Int, flags: UInt8
) -> String:
    if (flags & FLAG_REENCODE) != UInt8(0):
        return decode_json5_string(bytes, start, end)
    return decode_escaped_string(bytes, start, end)


def _keys_equal(
    bytes: Span[UInt8, _],
    a_start: Int,
    a_end: Int,
    a_flags: UInt8,
    b_start: Int,
    b_end: Int,
    b_flags: UInt8,
) -> Bool:
    """Member-name equality by CHARACTER (RFC 7493 §2.3), matching the lookup
    path's `_key_matches`: escaped spellings decode before comparing, so
    `"\\u0061"` and `"a"` are the same name to every duplicate policy —
    JSON5 spellings (FLAG_REENCODE) decode with the JSON5 decoder. Both
    spans were validated when their strings were parsed."""
    if a_flags == UInt8(0) and b_flags == UInt8(0):
        if a_end - a_start != b_end - b_start:
            return False
        for k in range(a_end - a_start):
            if bytes[a_start + k] != bytes[b_start + k]:
                return False
        return True
    var a = _decode_key(bytes, a_start, a_end, a_flags) if a_flags != UInt8(
        0
    ) else String(unsafe_from_utf8=bytes[a_start:a_end])
    var b = _decode_key(bytes, b_start, b_end, b_flags) if b_flags != UInt8(
        0
    ) else String(unsafe_from_utf8=bytes[b_start:b_end])
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
    flags: UInt8,
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
            entry_flags(word0),
            start,
            end,
            flags,
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
    flags: UInt8,
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
            entry_flags(word0),
            start,
            end,
            flags,
        ):
            tape[entry * 2] = word0 | (UInt64(FLAG_SHADOWED) << 48)
            return True
        entry = _next_member(tape, entry)
        walked += 1
    return False
