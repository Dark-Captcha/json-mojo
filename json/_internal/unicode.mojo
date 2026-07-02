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


def validate_utf8_span(bytes: Span[UInt8, _], a: Int, b: Int) raises:
    var ptr = bytes.unsafe_ptr()
    var i = a
    comptime W = 64
    var v80 = SIMD[DType.uint8, W](UInt8(0x80))
    var v0 = SIMD[DType.uint8, W](UInt8(0))
    while i < b:
        var c = ptr[i]
        if c < UInt8(0x80):
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
        if (c & UInt8(0xE0)) == UInt8(0xC0):
            seqlen = 2
            mincp = 0x80
            cp = Int(c & UInt8(0x1F))
        elif (c & UInt8(0xF0)) == UInt8(0xE0):
            seqlen = 3
            mincp = 0x800
            cp = Int(c & UInt8(0x0F))
        elif (c & UInt8(0xF8)) == UInt8(0xF0):
            seqlen = 4
            mincp = 0x10000
            cp = Int(c & UInt8(0x07))
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
            if (cb & UInt8(0xC0)) != UInt8(0x80):
                raise Error(
                    "json.parse: invalid UTF-8 continuation byte at byte "
                    + String(i + k)
                )
            cp = (cp << 6) | Int(cb & UInt8(0x3F))
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
        i += seqlen


def _hex2(x: UInt8) -> String:
    comptime HEX = "0123456789abcdef"
    var hb = HEX.as_bytes()
    var s = String("")
    s += chr(Int(hb[Int((x >> UInt8(4)) & UInt8(0x0F))]))
    s += chr(Int(hb[Int(x & UInt8(0x0F))]))
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
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
