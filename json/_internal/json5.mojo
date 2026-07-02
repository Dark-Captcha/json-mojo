# json5 — `Dialect.JSON5` (extension tier 1): a self-contained scalar
# tokenizer + tape builder for the JSON5 grammar (json5.org, over ES5.1).
# It emits the SAME six-kind tape as stage 2 — every consumer (cursor,
# serde, `dumps`) inherits JSON5 for free — and shares stage 2's frame
# machinery, duplicate policies, and error/path conventions by import.
#
# The RFC 8259 engine is untouched: `parse` routes here only when the
# comptime dialect says so, and the Performance Promise stays scoped to
# `Dialect.JSON` (this pass is scalar by design — JSON5 is configs, not
# firehoses; PERF.md states it).
#
# Lexemes whose raw bytes are not valid RFC 8259 content carry
# `FLAG_REENCODE` (single-quoted strings with quotes/escapes/controls,
# JSON5-only escapes, raw controls, hex numbers, Infinity/NaN, `+` signs,
# bare-dot decimals): readers decode them with the JSON5 decoder and
# `dumps` re-encodes them as standard JSON.

from json._internal.bytes import (
    B_0,
    B_9,
    B_BSLASH,
    B_COLON,
    B_COMMA,
    B_CR,
    B_DOT,
    B_E_LOWER,
    B_E_UPPER,
    B_LBRACE,
    B_LBRACK,
    B_LF,
    B_MINUS,
    B_PLUS,
    B_QUOTE,
    B_RBRACE,
    B_RBRACK,
    B_SLASH,
    B_SPACE,
    B_TAB,
    B_U,
)
from json._internal.tape import (
    FLAG_ESCAPED,
    FLAG_REENCODE,
    TAG_ARRAY,
    TAG_BOOLEAN,
    TAG_NULL,
    TAG_NUMBER,
    TAG_OBJECT,
    TAG_STRING,
    _EXPECT_ARRAY_NEXT,
    _EXPECT_COLON,
    _EXPECT_ELEMENT,
    _EXPECT_FIRST_OR_CLOSE,
    _EXPECT_KEY,
    _EXPECT_KEY_OR_CLOSE,
    _EXPECT_OBJECT_NEXT,
    _EXPECT_OBJECT_VALUE,
    _Frame,
    _begin_value,
    _check_duplicate_key,
    _describe_path,
    _end_value,
    _error,
    _shadow_duplicate_key,
    entry_tag,
    make_word0,
)
from json._internal.unicode import HIGH_BIT, validate_utf8_span
from json._internal.unicode_id import is_id_continue, is_id_start
from json.options import ParseOptions


comptime _QUOTE_SINGLE: UInt8 = UInt8(0x27)  # '
comptime _VT: UInt8 = UInt8(0x0B)
comptime _FF: UInt8 = UInt8(0x0C)
comptime _DOLLAR: UInt8 = UInt8(0x24)  # $
comptime _UNDERSCORE: UInt8 = UInt8(0x5F)  # _
comptime _STAR: UInt8 = UInt8(0x2A)  # *
comptime _X_LOWER: UInt8 = UInt8(0x78)  # x
comptime _X_UPPER: UInt8 = UInt8(0x58)  # X


def build_tape_json5[
    options: ParseOptions
](text: String, start: Int) raises -> List[UInt64]:
    """The JSON5 counterpart of `build_tape` — same wrapper contract: parse
    errors gain the RFC 6901 path of the open position."""
    var stack = List[_Frame]()
    try:
        return _build_json5_inner[options](text, start, stack)
    except error:
        var path = _describe_path(stack, text.as_bytes())
        if path.byte_length() > 0:
            raise Error(String(error) + " in " + path)
        raise error^


# --- Whitespace and comments -------------------------------------------------------


def _ws_run(bytes: Span[UInt8, _], length: Int, at: Int) -> Int:
    """Bytes consumed by ONE JSON5 whitespace char at `at` (0 = not ws).
    Set per json5.org: TAB LF VT FF CR SPACE NBSP LS PS BOM + Unicode Zs."""
    var b = bytes[at]
    if (
        b == B_SPACE
        or b == B_TAB
        or b == B_LF
        or b == B_CR
        or b == _VT
        or b == _FF
    ):
        return 1
    if b < HIGH_BIT:
        return 0
    # Multi-byte candidates, matched by exact encoding.
    if b == UInt8(0xC2) and at + 1 < length and bytes[at + 1] == UInt8(0xA0):
        return 2  # U+00A0 NBSP
    if b == UInt8(0xE1):  # U+1680 OGHAM SPACE MARK: e1 9a 80
        if (
            at + 2 < length
            and bytes[at + 1] == UInt8(0x9A)
            and bytes[at + 2] == UInt8(0x80)
        ):
            return 3
        return 0
    if b == UInt8(0xE2) and at + 2 < length:
        var b1 = bytes[at + 1]
        var b2 = bytes[at + 2]
        if b1 == UInt8(0x80):
            # U+2000–U+200A (80–8A), U+2028 LS (A8), U+2029 PS (A9),
            # U+202F NNBSP (AF)
            if (
                (b2 >= UInt8(0x80) and b2 <= UInt8(0x8A))
                or b2 == UInt8(0xA8)
                or b2 == UInt8(0xA9)
                or b2 == UInt8(0xAF)
            ):
                return 3
        elif b1 == UInt8(0x81) and b2 == UInt8(0x9F):
            return 3  # U+205F MMSP
        return 0
    if b == UInt8(0xE3):  # U+3000 IDEOGRAPHIC SPACE: e3 80 80
        if (
            at + 2 < length
            and bytes[at + 1] == UInt8(0x80)
            and bytes[at + 2] == UInt8(0x80)
        ):
            return 3
        return 0
    if b == UInt8(0xEF):  # U+FEFF BOM: ef bb bf
        if (
            at + 2 < length
            and bytes[at + 1] == UInt8(0xBB)
            and bytes[at + 2] == UInt8(0xBF)
        ):
            return 3
        return 0
    return 0


def _is_line_terminator(bytes: Span[UInt8, _], length: Int, at: Int) -> Int:
    """Bytes of a LineTerminator at `at` (LF, CR, LS, PS) — 0 if none."""
    var b = bytes[at]
    if b == B_LF or b == B_CR:
        return 1
    if (
        b == UInt8(0xE2)
        and at + 2 < length
        and bytes[at + 1] == UInt8(0x80)
        and (bytes[at + 2] == UInt8(0xA8) or bytes[at + 2] == UInt8(0xA9))
    ):
        return 3
    return 0


def _skip_ws_and_comments(
    bytes: Span[UInt8, _], length: Int, var pos: Int
) raises -> Int:
    while pos < length:
        var run = _ws_run(bytes, length, pos)
        if run > 0:
            pos += run
            continue
        if bytes[pos] == B_SLASH and pos + 1 < length:
            var next = bytes[pos + 1]
            if next == B_SLASH:  # // to line end
                pos += 2
                while pos < length:
                    var lt = _is_line_terminator(bytes, length, pos)
                    if lt > 0:
                        pos += lt
                        break
                    pos += 1
                continue
            if next == _STAR:  # /* to */
                var scan = pos + 2
                while True:
                    if scan + 1 >= length:
                        _error("unterminated block comment", pos)
                    if bytes[scan] == _STAR and bytes[scan + 1] == B_SLASH:
                        pos = scan + 2
                        break
                    scan += 1
                continue
        break
    return pos


# --- Strings -----------------------------------------------------------------------


def _hex_value(b: UInt8) raises -> Int:
    if b >= B_0 and b <= B_9:
        return Int(b - B_0)
    if b >= UInt8(0x61) and b <= UInt8(0x66):  # a-f
        return Int(b - UInt8(0x61)) + 10
    if b >= UInt8(0x41) and b <= UInt8(0x46):  # A-F
        return Int(b - UInt8(0x41)) + 10
    raise Error("json.parse: invalid hex digit in escape")


def _scan_string5(
    bytes: Span[UInt8, _],
    length: Int,
    quote: UInt8,
    at: Int,
    mut flags: UInt8,
) raises -> Int:
    """Validate a JSON5 string starting at the opening quote `at`; return
    (position of the closing quote, tape flags). Escapes per ES5.1 +
    JSON5: any SourceCharacter may follow `\\` (escaping to itself), plus
    `\\x2h`, `\\u4h` with surrogate pairing, `\\0` (not before a digit),
    and line continuations. Raw LF/CR are errors; raw LS/PS and raw
    controls are legal JSON5 (controls force re-encoding for `dumps`)."""
    var i = at + 1
    var escaped = False
    var reencode = False
    var saw_high = False
    while True:
        if i >= length:
            _error("unterminated string", at)
        var c = bytes[i]
        if c == quote:
            break
        if c >= HIGH_BIT:
            saw_high = True
            i += 1
            continue
        if c == B_LF or c == B_CR:
            _error("raw line terminator in string (escape or continue it)", i)
        if c < UInt8(0x20):
            reencode = True  # legal JSON5, not legal RFC 8259 raw content
            i += 1
            continue
        if quote == _QUOTE_SINGLE and c == B_QUOTE:
            reencode = True  # a raw '"' cannot re-emit inside double quotes
            i += 1
            continue
        if c != B_BSLASH:
            i += 1
            continue
        # Escape sequence.
        escaped = True
        i += 1
        if i >= length:
            _error("unterminated escape", i - 1)
        var e = bytes[i]
        if e == B_U:
            if i + 4 >= length:
                _error("truncated \\u escape", i)
            var cp = 0
            for k in range(1, 5):
                cp = (cp << 4) | _hex_value(bytes[i + k])
            i += 5
            if cp >= 0xD800 and cp <= 0xDBFF:
                # High surrogate: the low half MUST follow as \uXXXX.
                if (
                    i + 5 >= length
                    or bytes[i] != B_BSLASH
                    or bytes[i + 1] != B_U
                ):
                    _error("unpaired surrogate escape", i - 6)
                var low = 0
                for k in range(2, 6):
                    low = (low << 4) | _hex_value(bytes[i + k])
                if low < 0xDC00 or low > 0xDFFF:
                    _error("unpaired surrogate escape", i - 6)
                i += 6
            elif cp >= 0xDC00 and cp <= 0xDFFF:
                _error("unpaired surrogate escape", i - 6)
            continue
        if e == _X_LOWER:
            if i + 2 >= length:
                _error("truncated \\x escape", i)
            _ = _hex_value(bytes[i + 1])
            _ = _hex_value(bytes[i + 2])
            reencode = True  # \xHH is not an RFC 8259 escape
            i += 3
            continue
        var lt = _is_line_terminator(bytes, length, i)
        if lt > 0:
            # Line continuation; CR+LF counts as one terminator.
            reencode = True
            if bytes[i] == B_CR and i + 1 < length and bytes[i + 1] == B_LF:
                i += 2
            else:
                i += lt
            continue
        if e == B_0:
            # \0 is NUL unless a decimal digit follows (ES5.1 restriction).
            if i + 1 < length and bytes[i + 1] >= B_0 and bytes[i + 1] <= B_9:
                _error("\\0 must not be followed by a digit", i)
            reencode = True
            i += 1
            continue
        if e >= UInt8(0x31) and e <= B_9:  # \1..\9
            _error("numeric escapes are not JSON5", i)
        # JSON-legal single-char escapes re-emit raw; every other
        # SourceCharacter escapes to itself and needs re-encoding.
        if (
            e == B_QUOTE
            or e == B_BSLASH
            or e == B_SLASH
            or e == UInt8(0x62)  # b
            or e == UInt8(0x66)  # f
            or e == UInt8(0x6E)  # n
            or e == UInt8(0x72)  # r
            or e == UInt8(0x74)  # t
        ):
            i += 1
            continue
        reencode = True  # \' \v and any self-escaping SourceCharacter
        if e >= HIGH_BIT:
            saw_high = True
            # Consume the full UTF-8 sequence of the escaped character.
            var step = 1
            if (e & UInt8(0xE0)) == UInt8(0xC0):
                step = 2
            elif (e & UInt8(0xF0)) == UInt8(0xE0):
                step = 3
            elif (e & UInt8(0xF8)) == UInt8(0xF0):
                step = 4
            i += step
        else:
            i += 1
    if saw_high:
        validate_utf8_span(bytes, at + 1, i)
    flags = UInt8(0)
    if escaped:
        flags |= FLAG_ESCAPED
    if reencode:
        flags |= FLAG_REENCODE | FLAG_ESCAPED
    return i


# --- Identifiers (ES5.1 IdentifierName, for member keys) ---------------------------


def _decode_cp(
    bytes: Span[UInt8, _], length: Int, at: Int, mut step: Int
) raises -> Int:
    """Code point + byte length at `at` (input already known valid UTF-8 by
    the time keys are compared; here we bounds-check and trust shape)."""
    var b = bytes[at]
    if b < HIGH_BIT:
        step = 1
        return Int(b)
    if (b & UInt8(0xE0)) == UInt8(0xC0):
        if at + 1 >= length:
            _error("truncated UTF-8 in identifier", at)
        step = 2
        return ((Int(b) & 0x1F) << 6) | (Int(bytes[at + 1]) & 0x3F)
    if (b & UInt8(0xF0)) == UInt8(0xE0):
        if at + 2 >= length:
            _error("truncated UTF-8 in identifier", at)
        step = 3
        return (
            ((Int(b) & 0x0F) << 12)
            | ((Int(bytes[at + 1]) & 0x3F) << 6)
            | (Int(bytes[at + 2]) & 0x3F)
        )
    if at + 3 >= length:
        _error("truncated UTF-8 in identifier", at)
    step = 4
    return (
        ((Int(b) & 0x07) << 18)
        | ((Int(bytes[at + 1]) & 0x3F) << 12)
        | ((Int(bytes[at + 2]) & 0x3F) << 6)
        | (Int(bytes[at + 3]) & 0x3F)
    )


def _scan_identifier(
    bytes: Span[UInt8, _], length: Int, at: Int, mut flags: UInt8
) raises -> Int:
    """Validate an ES5.1 IdentifierName starting at `at`; return (end, tape
    flags). `\\uXXXX` escapes are legal identifier characters (checked
    against the identifier categories) and mark the span FLAG_ESCAPED."""
    var i = at
    var escaped = False
    var first = True
    while i < length:
        var c = bytes[i]
        var cp: Int
        var step: Int
        if c == B_BSLASH:
            if i + 5 >= length or bytes[i + 1] != B_U:
                _error("invalid identifier escape", i)
            cp = 0
            for k in range(2, 6):
                cp = (cp << 4) | _hex_value(bytes[i + k])
            step = 6
            escaped = True
        else:
            step = 0
            cp = _decode_cp(bytes, length, i, step)
        var ok: Bool
        if first:
            ok = is_id_start(cp)
        else:
            ok = is_id_continue(cp)
        if not ok:
            if first:
                _error("invalid identifier start", i)
            break
        first = False
        i += step
    if first:
        _error("empty identifier", at)
    var saw_high = False
    for k in range(at, i):
        if bytes[k] >= HIGH_BIT:
            saw_high = True
            break
    if saw_high:
        validate_utf8_span(bytes, at, i)
    flags = FLAG_ESCAPED if escaped else UInt8(0)
    return i


# --- Numbers -----------------------------------------------------------------------


def _match_word(
    bytes: Span[UInt8, _], length: Int, at: Int, word: StaticString
) -> Bool:
    var w = word.as_bytes()
    if at + len(w) > length:
        return False
    for k in range(len(w)):
        if bytes[at + k] != w[k]:
            return False
    return True


def _scan_number5(
    bytes: Span[UInt8, _], length: Int, at: Int, mut flags: UInt8
) raises -> Int:
    """Validate a JSON5 number starting at `at`; return (end, tape flags).
    Grammar: [+-]?(Infinity | NaN | 0x hex+ | decimal with optional bare
    leading/trailing dot). Anything RFC 8259 could not re-emit verbatim is
    FLAG_REENCODE."""
    var i = at
    var reencode = False
    if bytes[i] == B_PLUS:
        reencode = True  # '+' is not RFC 8259
        i += 1
    elif bytes[i] == B_MINUS:
        i += 1
    if i >= length:
        _error("number is missing digits", at)
    if _match_word(bytes, length, i, "Infinity"):
        flags = FLAG_REENCODE
        return i + 8
    if _match_word(bytes, length, i, "NaN"):
        flags = FLAG_REENCODE
        return i + 3
    var c = bytes[i]
    if (
        c == B_0
        and i + 1 < length
        and (bytes[i + 1] == _X_LOWER or bytes[i + 1] == _X_UPPER)
    ):
        i += 2
        var digits = 0
        while i < length:
            var h = bytes[i]
            if (
                (h >= B_0 and h <= B_9)
                or (h >= UInt8(0x61) and h <= UInt8(0x66))
                or (h >= UInt8(0x41) and h <= UInt8(0x46))
            ):
                digits += 1
                i += 1
            else:
                break
        if digits == 0:
            _error("hex number is missing digits", i)
        flags = FLAG_REENCODE
        return i
    # Decimal: IntegerPart? ('.' FractionPart?)? Exponent? — at least one
    # digit somewhere; no leading zeros on multi-digit integer parts.
    var int_digits = 0
    if c >= B_0 and c <= B_9:
        if c == B_0:
            int_digits = 1
            i += 1
            if i < length and bytes[i] >= B_0 and bytes[i] <= B_9:
                _error("leading zeros are not JSON5", i - 1)
        else:
            while i < length and bytes[i] >= B_0 and bytes[i] <= B_9:
                int_digits += 1
                i += 1
    var frac_digits = 0
    if i < length and bytes[i] == B_DOT:
        if int_digits == 0:
            reencode = True  # bare leading dot
        i += 1
        while i < length and bytes[i] >= B_0 and bytes[i] <= B_9:
            frac_digits += 1
            i += 1
        if frac_digits == 0:
            if int_digits == 0:
                _error("number has no digits", at)
            reencode = True  # bare trailing dot
    if int_digits == 0 and frac_digits == 0:
        _error("number has no digits", at)
    if i < length and (bytes[i] == B_E_LOWER or bytes[i] == B_E_UPPER):
        i += 1
        if i < length and (bytes[i] == B_PLUS or bytes[i] == B_MINUS):
            i += 1
        var exp_digits = 0
        while i < length and bytes[i] >= B_0 and bytes[i] <= B_9:
            exp_digits += 1
            i += 1
        if exp_digits == 0:
            _error("number has an empty exponent", i)
    flags = FLAG_REENCODE if reencode else UInt8(0)
    return i


# --- The builder -------------------------------------------------------------------


@always_inline
def _is_value_delimiter(bytes: Span[UInt8, _], length: Int, at: Int) -> Bool:
    """May a lexeme legally END here? ws / comment / , : ] } / EOF."""
    if at >= length:
        return True
    var b = bytes[at]
    if b == B_COMMA or b == B_COLON or b == B_RBRACE or b == B_RBRACK:
        return True
    if _ws_run(bytes, length, at) > 0:
        return True
    return (
        b == B_SLASH
        and at + 1 < length
        and (bytes[at + 1] == B_SLASH or bytes[at + 1] == _STAR)
    )


def _build_json5_inner[
    options: ParseOptions
](text: String, start: Int, mut stack: List[_Frame]) raises -> List[UInt64]:
    var bytes = text.as_bytes()
    var length = text.byte_length()
    var tape = List[UInt64](capacity=64)
    var root_seen = False
    var pos = start

    while True:
        pos = _skip_ws_and_comments(bytes, length, pos)
        if pos >= length:
            break
        var b = bytes[pos]

        # Is this position expecting an object KEY?
        var expects_key = False
        if len(stack) > 0 and stack[len(stack) - 1].is_object:
            var state = stack[len(stack) - 1].state
            expects_key = state == _EXPECT_KEY_OR_CLOSE or state == _EXPECT_KEY

        if b == B_LBRACE or b == B_LBRACK:
            _begin_value(stack, root_seen, pos)
            if len(stack) >= options.max_depth:
                _error("nesting depth limit exceeded", pos)
            var is_object = b == B_LBRACE
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
            pos += 1
            continue

        if b == B_RBRACE or b == B_RBRACK:
            if len(stack) == 0:
                _error("close with no open container", pos)
            var frame = stack[len(stack) - 1]
            var closing_object = b == B_RBRACE
            if frame.is_object != closing_object:
                _error("mismatched container close", pos)
            if closing_object:
                # Trailing comma: closing after ',' is legal JSON5.
                if (
                    frame.state != _EXPECT_KEY_OR_CLOSE
                    and frame.state != _EXPECT_OBJECT_NEXT
                    and frame.state != _EXPECT_KEY
                ):
                    _error("unexpected '}'", pos)
            else:
                if (
                    frame.state != _EXPECT_FIRST_OR_CLOSE
                    and frame.state != _EXPECT_ARRAY_NEXT
                    and frame.state != _EXPECT_ELEMENT
                ):
                    _error("unexpected ']'", pos)
            _ = stack.pop()
            var word0 = tape[frame.tape_entry * 2]
            tape[frame.tape_entry * 2] = make_word0(
                entry_tag(word0), UInt8(0), frame.count
            )
            tape[frame.tape_entry * 2 + 1] = UInt64(len(tape) // 2)
            _end_value(stack, root_seen)
            pos += 1
            continue

        if b == B_COMMA:
            if len(stack) == 0:
                _error("',' outside any container", pos)
            var state = stack[len(stack) - 1].state
            if stack[len(stack) - 1].is_object:
                if state != _EXPECT_OBJECT_NEXT:
                    _error("unexpected ','", pos)
                stack[len(stack) - 1].state = _EXPECT_KEY
            else:
                if state != _EXPECT_ARRAY_NEXT:
                    _error("unexpected ','", pos)
                stack[len(stack) - 1].state = _EXPECT_ELEMENT
            pos += 1
            continue

        if b == B_COLON:
            if len(stack) == 0 or not stack[len(stack) - 1].is_object:
                _error("':' outside an object", pos)
            if stack[len(stack) - 1].state != _EXPECT_COLON:
                _error("unexpected ':'", pos)
            stack[len(stack) - 1].state = _EXPECT_OBJECT_VALUE
            pos += 1
            continue

        if b == B_QUOTE or b == _QUOTE_SINGLE:
            var flags = UInt8(0)
            var close = _scan_string5(bytes, length, b, pos, flags)
            if expects_key:
                _emit_key[options](bytes, tape, stack, pos + 1, close, flags)
            else:
                _begin_value(stack, root_seen, pos)
                tape.append(make_word0(TAG_STRING, flags, pos + 1))
                tape.append(UInt64(close))
                _end_value(stack, root_seen)
            pos = close + 1
            continue

        if expects_key:
            # Unquoted ES5.1 IdentifierName key.
            var id_flags = UInt8(0)
            var id_end = _scan_identifier(bytes, length, pos, id_flags)
            _emit_key[options](bytes, tape, stack, pos, id_end, id_flags)
            pos = id_end
            continue

        # Value atoms: literals, Infinity/NaN, numbers.
        _begin_value(stack, root_seen, pos)
        if _match_word(bytes, length, pos, "true"):
            if not _is_value_delimiter(bytes, length, pos + 4):
                _error("unrecognized literal", pos)
            tape.append(make_word0(TAG_BOOLEAN, UInt8(0), 1))
            tape.append(UInt64(0))
            pos += 4
        elif _match_word(bytes, length, pos, "false"):
            if not _is_value_delimiter(bytes, length, pos + 5):
                _error("unrecognized literal", pos)
            tape.append(make_word0(TAG_BOOLEAN, UInt8(0), 0))
            tape.append(UInt64(0))
            pos += 5
        elif _match_word(bytes, length, pos, "null"):
            if not _is_value_delimiter(bytes, length, pos + 4):
                _error("unrecognized literal", pos)
            tape.append(make_word0(TAG_NULL, UInt8(0), 0))
            tape.append(UInt64(0))
            pos += 4
        elif (
            (b >= B_0 and b <= B_9)
            or b == B_MINUS
            or b == B_PLUS
            or b == B_DOT
            or b == UInt8(0x49)  # I
            or b == UInt8(0x4E)  # N
        ):
            var num_flags = UInt8(0)
            var num_end = _scan_number5(bytes, length, pos, num_flags)
            if not _is_value_delimiter(bytes, length, num_end):
                _error("number has trailing characters", num_end)
            tape.append(make_word0(TAG_NUMBER, num_flags, pos))
            tape.append(UInt64(num_end))
            pos = num_end
        else:
            _error("unrecognized literal", pos)
        _end_value(stack, root_seen)

    if len(stack) != 0:
        _error("unterminated container at end of input", length)
    if not root_seen:
        _error("no value in document", 0)
    return tape^


def _emit_key[
    options: ParseOptions
](
    bytes: Span[UInt8, _],
    mut tape: List[UInt64],
    mut stack: List[_Frame],
    key_start: Int,
    key_end: Int,
    flags: UInt8,
) raises:
    comptime if options.rejects_duplicates():
        _check_duplicate_key(
            bytes,
            tape,
            stack[len(stack) - 1],
            key_start,
            key_end,
            flags,
        )
    comptime if options.shadows_duplicates():
        if _shadow_duplicate_key(
            bytes,
            tape,
            stack[len(stack) - 1],
            key_start,
            key_end,
            flags,
        ):
            stack[len(stack) - 1].count -= 1
    stack[len(stack) - 1].state = _EXPECT_COLON
    stack[len(stack) - 1].key_start = key_start
    stack[len(stack) - 1].key_end = key_end
    stack[len(stack) - 1].key_flags = flags
    tape.append(make_word0(TAG_STRING, flags, key_start))
    tape.append(UInt64(key_end))
