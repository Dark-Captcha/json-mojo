# UTF-8 validation (RFC 8259 §8.1 / RFC 3629). Only string bodies can legally
# contain non-ASCII bytes — every other part of a JSON text is ASCII and the
# parser rejects stray high bytes there — so the parser validates a string body
# only when it actually saw a byte >= 0x80 (tracked for free during the string
# scan). For pure-ASCII input this code never runs.
#
# `validate_utf8_span` itself skips runs of ASCII 64 bytes at a time (SIMD) and
# validates multi-byte sequences scalar-ly: rejects invalid lead/continuation
# bytes, overlong encodings, surrogates (U+D800..U+DFFF), and > U+10FFFF.

from std.memory.unsafe import pack_bits

from json._internal.bytes import (
    B_A,
    B_A_UPPER,
    B_B,
    B_BSLASH,
    B_F,
    B_N,
    B_QUOTE,
    B_R,
    B_SLASH,
    B_T,
    B_U,
    B_0,
    B_9,
    CTRL_BS,
    CTRL_CR,
    CTRL_FF,
    CTRL_LF,
    CTRL_TAB,
)


# UTF-8 structure (RFC 3629 §3) as named comptime masks: a lead byte's
# high bits encode the sequence length; continuations are 10xxxxxx.
comptime HIGH_BIT: UInt8 = UInt8(0x80)  # ASCII / non-ASCII boundary
comptime _CONT_MASK: UInt8 = UInt8(0xC0)
comptime _CONT_BITS: UInt8 = UInt8(0x80)  # 10xxxxxx
comptime _LEAD2_MASK: UInt8 = UInt8(0xE0)
comptime _LEAD2_BITS: UInt8 = UInt8(0xC0)  # 110xxxxx
comptime _LEAD3_MASK: UInt8 = UInt8(0xF0)
comptime _LEAD3_BITS: UInt8 = UInt8(0xE0)  # 1110xxxx
comptime _LEAD4_MASK: UInt8 = UInt8(0xF8)
comptime _LEAD4_BITS: UInt8 = UInt8(0xF0)  # 11110xxx
comptime _PAYLOAD2: UInt8 = UInt8(0x1F)
comptime _PAYLOAD3: UInt8 = UInt8(0x0F)
comptime _PAYLOAD4: UInt8 = UInt8(0x07)
comptime _PAYLOAD_CONT: UInt8 = UInt8(0x3F)
comptime _NIBBLE: UInt8 = UInt8(0x0F)
comptime B_LF_BYTE: UInt8 = UInt8(0x0A)
comptime B_CR_BYTE: UInt8 = UInt8(0x0D)


def validate_utf8_span[
    reject_noncharacters: Bool = False
](bytes: Span[UInt8, _], a: Int, b: Int) raises:
    var ptr = bytes.unsafe_ptr()
    var i = a
    comptime W = 64
    var v80 = SIMD[DType.uint8, W](HIGH_BIT)
    var v0 = SIMD[DType.uint8, W](UInt8(0))
    while i < b:
        var c = ptr[i]
        if c < HIGH_BIT:
            # ASCII — try to skip a whole SIMD chunk if it is all ASCII.
            if i + W <= b:
                var chunk = ptr.load[width=W](i)
                if pack_bits[dtype=DType.uint64](
                    (chunk & v80).ne(v0)
                ) == UInt64(0):
                    i += W
                    continue
            i += 1
            continue
        # Multi-byte lead byte: determine length, low bits, and the minimum
        # code point that legally needs this length (overlong check).
        var seqlen: Int
        var mincp: Int
        var cp: Int
        if (c & _LEAD2_MASK) == _LEAD2_BITS:
            seqlen = 2
            mincp = 0x80
            cp = Int(c & _PAYLOAD2)
        elif (c & _LEAD3_MASK) == _LEAD3_BITS:
            seqlen = 3
            mincp = 0x800
            cp = Int(c & _PAYLOAD3)
        elif (c & _LEAD4_MASK) == _LEAD4_BITS:
            seqlen = 4
            mincp = 0x10000
            cp = Int(c & _PAYLOAD4)
        else:
            raise Error(
                "json.parse: invalid UTF-8 lead byte 0x"
                + _hex2(c)
                + " at byte "
                + String(i)
            )
        if i + seqlen > b:
            raise Error(
                "json.parse: truncated UTF-8 sequence at byte " + String(i)
            )
        for k in range(1, seqlen):
            var cb = ptr[i + k]
            if (cb & _CONT_MASK) != _CONT_BITS:
                raise Error(
                    "json.parse: invalid UTF-8 continuation byte at byte "
                    + String(i + k)
                )
            cp = (cp << 6) | Int(cb & _PAYLOAD_CONT)
        if cp < mincp:
            raise Error(
                "json.parse: overlong UTF-8 encoding at byte " + String(i)
            )
        if cp > 0x10FFFF:
            raise Error(
                "json.parse: UTF-8 code point out of range at byte " + String(i)
            )
        if cp >= 0xD800 and cp <= 0xDFFF:
            raise Error(
                "json.parse: UTF-8 surrogate code point at byte " + String(i)
            )
        comptime if reject_noncharacters:
            # RFC 7493 §2.1: I-JSON strings must not contain noncharacters
            # (U+FDD0..U+FDEF and the last two code points of every plane).
            if (cp >= 0xFDD0 and cp <= 0xFDEF) or (cp & 0xFFFE) == 0xFFFE:
                raise Error(
                    "json.parse: noncharacter in I-JSON string at byte "
                    + String(i)
                )
        i += seqlen


def _hex2(x: UInt8) -> String:
    comptime HEX = "0123456789abcdef"
    var hb = HEX.as_bytes()
    var s = String("")
    s += chr(Int(hb[Int((x >> UInt8(4)) & _NIBBLE)]))
    s += chr(Int(hb[Int(x & _NIBBLE)]))
    return s


# --- Escape decoding (validated input) -----------------------------------------
#
# Ported from the retired prototype's decoder. The span was fully validated
# by stage 2 (escape characters legal, \uXXXX hex well-formed, surrogates
# paired, no raw control bytes), so this decoder carries no error paths —
# the invariant is the contract. Output is valid UTF-8 by construction:
# pass-through bytes come from a validated document and the encoder below
# emits well-formed sequences only.


def decode_escaped_string(bytes: Span[UInt8, _], a: Int, b: Int) -> String:
    """Decode a stage-2-validated string body containing at least one escape
    into an owned String."""
    var out = List[UInt8](capacity=b - a)
    var i = a
    while i < b:
        var c = bytes[i]
        if c != B_BSLASH:
            out.append(c)
            i += 1
            continue
        i += 1
        var escape = bytes[i]
        if escape == B_QUOTE:
            out.append(B_QUOTE)
        elif escape == B_BSLASH:
            out.append(B_BSLASH)
        elif escape == B_SLASH:
            out.append(B_SLASH)
        elif escape == B_B:
            out.append(CTRL_BS)
        elif escape == B_F:
            out.append(CTRL_FF)
        elif escape == B_N:
            out.append(CTRL_LF)
        elif escape == B_R:
            out.append(CTRL_CR)
        elif escape == B_T:
            out.append(CTRL_TAB)
        else:  # \uXXXX — validated, possibly a surrogate pair
            var code = _hex4_trusted(bytes, i + 1)
            i += 4
            if code >= 0xD800 and code <= 0xDBFF:
                # Validated: the low half follows as \uXXXX.
                var low = _hex4_trusted(bytes, i + 3)
                i += 6
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            _utf8_encode(out, code)
        i += 1
    return String(unsafe_from_utf8=out)


@always_inline
def _hex4_trusted(bytes: Span[UInt8, _], a: Int) -> Int:
    var value = 0
    for j in range(4):
        var c = bytes[a + j]
        var digit: Int
        if c >= B_0 and c <= B_9:
            digit = Int(c - B_0)
        elif c >= B_A:
            digit = Int(c - B_A) + 10
        else:
            digit = Int(c - B_A_UPPER) + 10
        value = (value << 4) | digit
    return value


def _utf8_encode(mut out: List[UInt8], cp: Int):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(_LEAD2_BITS | UInt8(cp >> 6))
        out.append(_CONT_BITS | UInt8(cp & 0x3F))
    elif cp < 0x10000:
        out.append(_LEAD3_BITS | UInt8(cp >> 12))
        out.append(_CONT_BITS | UInt8((cp >> 6) & 0x3F))
        out.append(_CONT_BITS | UInt8(cp & 0x3F))
    else:
        out.append(_LEAD4_BITS | UInt8(cp >> 18))
        out.append(_CONT_BITS | UInt8((cp >> 12) & 0x3F))
        out.append(_CONT_BITS | UInt8((cp >> 6) & 0x3F))
        out.append(_CONT_BITS | UInt8(cp & 0x3F))


def decode_json5_string(bytes: Span[UInt8, _], a: Int, b: Int) -> String:
    """Decode a JSON5-validated string body (single- or double-quoted
    content, `Dialect.JSON5`) into an owned String. Trusted like the RFC
    decoder above: `_scan_string5` already validated every escape."""
    var out = List[UInt8](capacity=b - a)
    var i = a
    while i < b:
        var c = bytes[i]
        if c != B_BSLASH:
            out.append(c)
            i += 1
            continue
        i += 1
        var e = bytes[i]
        if e == B_U:
            var code = _hex4_trusted(bytes, i + 1)
            i += 5
            if code >= 0xD800 and code <= 0xDBFF:
                var low = _hex4_trusted(bytes, i + 2)
                i += 6
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            _utf8_encode(out, code)
            continue
        if e == UInt8(0x78):  # \xHH
            var hi = _hex_digit_trusted(bytes[i + 1])
            var lo = _hex_digit_trusted(bytes[i + 2])
            _utf8_encode(out, (hi << 4) | lo)
            i += 3
            continue
        if e == B_LF_BYTE or e == B_CR_BYTE:
            # Line continuation: consumed, contributes nothing.
            if e == B_CR_BYTE and i + 1 < b and bytes[i + 1] == B_LF_BYTE:
                i += 2
            else:
                i += 1
            continue
        if (
            e == UInt8(0xE2)
            and i + 2 < b
            and bytes[i + 1] == UInt8(0x80)
            and (bytes[i + 2] == UInt8(0xA8) or bytes[i + 2] == UInt8(0xA9))
        ):
            i += 3  # \LS or \PS continuation
            continue
        if e == B_QUOTE:
            out.append(B_QUOTE)
        elif e == B_BSLASH:
            out.append(B_BSLASH)
        elif e == B_SLASH:
            out.append(B_SLASH)
        elif e == B_B:
            out.append(CTRL_BS)
        elif e == B_F:
            out.append(CTRL_FF)
        elif e == B_N:
            out.append(CTRL_LF)
        elif e == B_R:
            out.append(CTRL_CR)
        elif e == B_T:
            out.append(CTRL_TAB)
        elif e == UInt8(0x76):  # \v
            out.append(UInt8(0x0B))
        elif e == B_0:
            out.append(UInt8(0x00))
        elif e < HIGH_BIT:
            out.append(e)  # SourceCharacter escaping to itself
        else:
            # Self-escaped multi-byte character: copy its full sequence.
            var step = 2
            if (e & _LEAD3_MASK) == _LEAD3_BITS:
                step = 3
            elif (e & _LEAD4_MASK) == _LEAD4_BITS:
                step = 4
            for k in range(step):
                out.append(bytes[i + k])
            i += step
            continue
        i += 1
    return String(unsafe_from_utf8=out)


@always_inline
def _hex_digit_trusted(c: UInt8) -> Int:
    if c >= B_0 and c <= B_9:
        return Int(c - B_0)
    if c >= B_A:
        return Int(c - B_A) + 10
    return Int(c - B_A_UPPER) + 10
