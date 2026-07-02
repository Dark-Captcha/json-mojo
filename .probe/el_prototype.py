#!/usr/bin/env python3
# Eisel-Lemire prototype + power-of-five table generator, VERIFIED bit-for-bit
# against Python's float() (= C strtod). Once this matches the oracle for
# millions of cases, the table + algorithm are proven correct and get ported
# to Mojo verbatim. (Lemire, "Number Parsing at a Gigabyte per Second".)
import math
import random
import struct

MASK64 = (1 << 64) - 1
MANT_BITS = 52
MIN_EXP = -1023  # minimum_exponent (biased-exp offset use)
INF_POWER = 0x7FF
SMALLEST_P10 = -342
LARGEST_P10 = 308
SMALLEST_P5 = -342
MIN_RTE = -4  # round-to-even special window for binary64
MAX_RTE = 23
BIT_PRECISION = MANT_BITS + 3  # 55
PRECISION_MASK = MASK64 >> BIT_PRECISION  # 0x1FF


def gen_pow5(q):
    """128-bit normalized 5^q (top bit set, truncated)."""
    if q >= 0:
        c = 5**q
        b = c.bit_length()
        if b <= 128:
            c <<= 128 - b
        else:
            c >>= b - 128
        return c
    else:
        p = 5 ** (-q)
        b = p.bit_length()
        shift = b + 127
        c = (1 << shift) // p
        if (1 << shift) % p != 0:
            c += 1
        bb = c.bit_length()
        if bb > 128:
            c >>= bb - 128
        elif bb < 128:
            c <<= 128 - bb
        return c


# table[2k] = high 64 of 5^(k-342), table[2k+1] = low 64
TABLE = []
for q in range(SMALLEST_P5, LARGEST_P10 + 1):
    v = gen_pow5(q)
    TABLE.append(v >> 64)
    TABLE.append(v & MASK64)


def full_mult(a, b):
    p = a * b
    return (p >> 64, p & MASK64)


def power(q):
    return ((152170 + 65536) * q >> 16) + 63


def compute_product(q, w):
    idx = 2 * (q - SMALLEST_P5)
    fhi, flo = full_mult(w, TABLE[idx])
    if (fhi & PRECISION_MASK) == PRECISION_MASK:
        shi, slo = full_mult(w, TABLE[idx + 1])
        flo = (flo + shi) & MASK64
        if shi > flo:
            fhi = (fhi + 1) & MASK64
    return fhi, flo


def compute_float(q, w):
    """Returns IEEE-754 bits (no sign) or None to signal 'use fallback'."""
    if w == 0 or q < SMALLEST_P10:
        return 0
    if q > LARGEST_P10:
        return INF_POWER << MANT_BITS
    lz = 64 - w.bit_length()
    w = (w << lz) & MASK64
    fhi, flo = compute_product(q, w)
    upperbit = fhi >> 63
    mantissa = fhi >> (upperbit + 64 - MANT_BITS - 3)
    power2 = power(q) + upperbit - lz - MIN_EXP
    if power2 <= 0:  # subnormal / zero
        if -power2 + 1 >= 64:
            return 0
        mantissa >>= -power2 + 1
        mantissa += mantissa & 1
        mantissa >>= 1
        p2 = 1 if mantissa >= (1 << MANT_BITS) else 0
        return (p2 << MANT_BITS) | mantissa
    # round-to-even ambiguity guard
    if (
        flo <= 1
        and MIN_RTE <= q <= MAX_RTE
        and (mantissa & 3) == 1
        and (mantissa << (upperbit + 64 - MANT_BITS - 3)) == fhi
    ):
        mantissa &= ~1
    mantissa += mantissa & 1
    mantissa >>= 1
    if mantissa >= (1 << (MANT_BITS + 1)):
        mantissa = 1 << MANT_BITS
        power2 += 1
    mantissa &= ~(1 << MANT_BITS)
    if power2 >= INF_POWER:
        return INF_POWER << MANT_BITS
    return (power2 << MANT_BITS) | mantissa


def parse_decimal(s):
    """Return (w, q, negative): w = up to 19 SIGNIFICANT digits (leading zeros
    skipped — they don't consume the budget), q = power-of-ten exponent."""
    neg = s[0] == "-"
    i = 1 if neg else 0
    n = len(s)
    w = 0
    digit_count = 0
    dec_exp = 0
    seen_dot = False
    started = False  # passed the first non-zero significant digit?
    truncated = False
    while i < n and (s[i].isdigit() or s[i] == "."):
        c = s[i]
        if c == ".":
            seen_dot = True
            i += 1
            continue
        d = ord(c) - 48
        if not started:
            if d == 0:
                if seen_dot:
                    dec_exp -= 1  # leading zero after dot: scales magnitude
                i += 1
                continue
            started = True
        if digit_count < 19:
            w = w * 10 + d
            digit_count += 1
            if seen_dot:
                dec_exp -= 1
        else:
            if d != 0:
                truncated = True  # a nonzero significant digit was dropped
            if not seen_dot:
                dec_exp += 1  # 20th+ integer digit scales up
        i += 1
    exp = int(s[i + 1 :]) if i < n and s[i] in "eE" else 0
    return w, dec_exp + exp, neg, truncated


def parse_via_el(s):
    w, q, neg, truncated = parse_decimal(s)
    bits = compute_float(q, w)
    if truncated:
        # True value lies strictly in (w, w+1)*10^q. If both ends round to the
        # same double, that's the answer; otherwise the dropped digits decide.
        bits2 = compute_float(q, w + 1)
        if bits2 != bits:
            bits = _slow_exact(s, min(bits, bits2))
    if neg:
        bits |= 1 << 63
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


_slow_calls = [0]


def _decode(bits):
    ef = (bits >> 52) & 0x7FF
    frac = bits & ((1 << 52) - 1)
    if ef == 0:
        return frac, -1074
    return frac | (1 << 52), ef - 1075


def _slow_exact(s, lower):
    # EXACT slow path. `lower` and `lower+1` (ULP, via bit-pattern increment) are
    # the two adjacent candidate doubles; the true value D = full_significand ×
    # 10^q lies between them. Decide by comparing D to the exact halfway point
    # H = (2*M_lower + 1) * 2^(E_lower - 1) with big integers (multiply/shift +
    # compare only — no division). Ties round to even. This is what makes the
    # parser bit-exact for >19-digit inputs at a rounding boundary too.
    _slow_calls[0] += 1
    neg = s[0] == "-"
    body = s[1:] if neg else s
    if "e" in body or "E" in body:
        mant, _, e = body.replace("E", "e").partition("e")
        exp = int(e)
    else:
        mant, exp = body, 0
    if "." in mant:
        ip, fp = mant.split(".")
    else:
        ip, fp = mant, ""
    S = int(ip + fp) if (ip + fp) else 0  # full significand (all digits)
    q = exp - len(fp)  # value = S * 10^q

    M, E = _decode(lower)
    HN = 2 * M + 1
    HE = E - 1
    A = S  # D numerator before clearing denominators
    B = HN
    if q >= 0:
        A *= 10**q
    else:
        B *= 10 ** (-q)
    if HE >= 0:
        B <<= HE
    else:
        A <<= -HE
    if A < B:
        return lower
    if A > B:
        return lower + 1
    return lower if (M & 1) == 0 else lower + 1  # tie → round to even


# ---- verification against the float() oracle ------------------------------
random.seed(1)
fails = 0
total = 0
examples = []


def check(s):
    global fails, total
    try:
        want = float(s)
    except Exception:
        return
    if not math.isfinite(want):
        return
    total += 1
    got = parse_via_el(s)
    # bit-compare
    if struct.pack("<d", got) != struct.pack("<d", want):
        global examples
        if len(examples) < 20:
            examples.append((s, got, want))
        fails += 1


# realistic shortest-form doubles
for _ in range(300000):
    u = random.getrandbits(64)
    f = struct.unpack("<d", struct.pack("<Q", u))[0]
    if math.isfinite(f):
        check(repr(f))

# hand cases
for s in [
    "0.3",
    "0.1",
    "0.2",
    "3.14",
    "2.5",
    "1e10",
    "1e-10",
    "5e-324",
    "1.7976931348623157e308",
    "2.2250738585072014e-308",
    "9007199254740993",
    "1.5e-2",
    "100.0",
    "0.30000000000000004",
]:
    check(s)

print("EL prototype: total=%d fails=%d" % (total, fails))
for s, got, want in examples:
    print(
        "  MISMATCH s=%s got=%r (%016x) want=%r (%016x)"
        % (
            s,
            got,
            struct.unpack("<Q", struct.pack("<d", got))[0],
            want,
            struct.unpack("<Q", struct.pack("<d", want))[0],
        )
    )


# ---- stress the >19-significant-digit truncation path ---------------------
def rand_long_num():
    import random as _r

    sign = "-" if _r.random() < 0.3 else ""
    intp = str(_r.randint(1, 9)) + "".join(
        _r.choice("0123456789") for _ in range(_r.randint(0, 25))
    )
    s = sign + intp
    if _r.random() < 0.8:
        s += "." + "".join(_r.choice("0123456789") for _ in range(_r.randint(1, 30)))
    if _r.random() < 0.5:
        e = _r.randint(-40, 40)
        s += "e" + str(e)
    return s


random.seed(7)
long_total = 0
long_fails = 0
long_ex = []
for _ in range(1000000):
    s = rand_long_num()
    try:
        want = float(s)
    except Exception:
        continue
    if not math.isfinite(want):
        continue
    long_total += 1
    got = parse_via_el(s)
    if struct.pack("<d", got) != struct.pack("<d", want):
        long_fails += 1
        if len(long_ex) < 12:
            long_ex.append((s, got, want))
print(
    "LONG (>19 digit) cases: total=%d fails=%d (%.4f%%)"
    % (long_total, long_fails, 100.0 * long_fails / max(long_total, 1))
)
for s, got, want in long_ex:
    print(
        "  s=%s got=%016x want=%016x"
        % (
            s,
            struct.unpack("<Q", struct.pack("<d", got))[0],
            struct.unpack("<Q", struct.pack("<d", want))[0],
        )
    )
print(
    "slow-path (w/w+1 disagree) invocations: %d of %d long cases (%.5f%%)"
    % (_slow_calls[0], long_total, 100.0 * _slow_calls[0] / max(long_total, 1))
)
