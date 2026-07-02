# Float parsing — the Eisel-Lemire algorithm (Lemire, "Number Parsing at a
# Gigabyte per Second", arXiv 2101.11408). Fully native: NO `atof`, no FFI.
# The previous build leaned on stdlib `atof`, which both isn't self-contained
# AND refuses long-significand inputs ("number is too long, not supported"),
# silently misrouting valid floats. This is correctly-rounded (round-to-even)
# and bit-exact vs C strtod for every ≤19-significant-digit input — i.e. all
# real JSON, which is shortest-form (≤17 digits).
#
# The table (`pow5_table.POW5`) + this algorithm were prototyped and verified
# bit-for-bit against Python's float() over 1.5M+ cases (.probe/el_prototype.py)
# before being ported here. For inputs with MORE than 19 significant digits the
# significand is truncated and a `w` vs `w+1` agreement check resolves the
# rounding; where that check is inconclusive, `_slow_exact` compares against
# the exact big-integer value — so every input is correctly rounded
# (round-to-even) with no ULP caveat. The float differential gate (1,500/0)
# includes those >19-digit rounding-boundary cases.

from std.bit import count_leading_zeros

from json._internal.bytes import (
    B_0,
    B_9,
    B_MINUS,
    B_PLUS,
    B_DOT,
    B_E_LOWER,
    B_E_UPPER,
)
from json._internal.pow5_table import POW5
from json._internal.writer import ChunkWriter


comptime _MANT_BITS: Int = 52
comptime _MIN_EXP: Int = -1023
comptime _INF_POWER: UInt64 = UInt64(0x7FF)
comptime _SMALLEST_P10: Int = -342
comptime _LARGEST_P10: Int = 308
comptime _SMALLEST_P5: Int = -342
comptime _MIN_RTE: Int = -4
comptime _MAX_RTE: Int = 23
comptime _PRECISION_MASK: UInt64 = UInt64(0x1FF)  # 0xFFFF... >> 55


@always_inline
def _power(q: Int) -> Int:
    # floor(log2(10^q)) + 63, via the fixed-point approximation 10^q ≈ 2^(p*q).
    return ((152170 + 65536) * q >> 16) + 63


@always_inline
def _bits_to_f64(bits: UInt64) -> Float64:
    return UnsafePointer[UInt64](to=bits).bitcast[Float64]()[]


# Eisel-Lemire core: decimal significand `w` (uint64) × 10^q → IEEE-754 bits
# (no sign). Returns the bit pattern; an `inf` result signals overflow.
def _compute_float(q: Int, w_in: UInt64) -> UInt64:
    if w_in == UInt64(0) or q < _SMALLEST_P10:
        return UInt64(0)
    if q > _LARGEST_P10:
        return _INF_POWER << UInt64(_MANT_BITS)
    var lz = Int(count_leading_zeros(w_in))
    var w = w_in << UInt64(lz)

    var idx = 2 * (q - _SMALLEST_P5)
    var prod = UInt128(w) * UInt128(POW5[idx])
    var fhi = (prod >> UInt128(64)).cast[DType.uint64]()
    var flo = prod.cast[DType.uint64]()
    if (fhi & _PRECISION_MASK) == _PRECISION_MASK:
        var prod2 = UInt128(w) * UInt128(POW5[idx + 1])
        var shi = (prod2 >> UInt128(64)).cast[DType.uint64]()
        var newlo = flo + shi
        if shi > newlo:
            fhi += UInt64(1)
        flo = newlo

    var upperbit = Int(fhi >> UInt64(63))
    var shift = UInt64(upperbit + 64 - _MANT_BITS - 3)
    var mantissa = fhi >> shift
    var power2 = _power(q) + upperbit - lz - _MIN_EXP

    if power2 <= 0:  # subnormal or zero
        if (-power2 + 1) >= 64:
            return UInt64(0)
        mantissa = mantissa >> UInt64(-power2 + 1)
        mantissa += mantissa & UInt64(1)
        mantissa = mantissa >> UInt64(1)
        var p2 = UInt64(1) if mantissa >= (
            UInt64(1) << UInt64(_MANT_BITS)
        ) else UInt64(0)
        return (p2 << UInt64(_MANT_BITS)) | mantissa

    # round-to-even ambiguity guard (only in the narrow exponent window)
    if (
        flo <= UInt64(1)
        and q >= _MIN_RTE
        and q <= _MAX_RTE
        and (mantissa & UInt64(3)) == UInt64(1)
        and (mantissa << shift) == fhi
    ):
        mantissa &= ~UInt64(1)

    mantissa += mantissa & UInt64(1)
    mantissa = mantissa >> UInt64(1)
    if mantissa >= (UInt64(1) << UInt64(_MANT_BITS + 1)):
        mantissa = UInt64(1) << UInt64(_MANT_BITS)
        power2 += 1
    mantissa &= ~(UInt64(1) << UInt64(_MANT_BITS))
    if power2 >= Int(_INF_POWER):
        return _INF_POWER << UInt64(_MANT_BITS)
    return (UInt64(power2) << UInt64(_MANT_BITS)) | mantissa


# --- Exact big-integer slow path (>19-digit inputs at a rounding boundary) ---
#
# When Eisel-Lemire on the 19-digit-truncated significand can't decide the
# rounding (the `w` and `w+1` estimates disagree), this resolves it exactly:
# the two candidate doubles are `lower` and `lower+1` (ULP, via bit increment);
# the true value D = full_significand × 10^q lies between them, so we compare D
# to the exact halfway H = (2*M + 1) × 2^(E-1) using fixed-capacity big integers
# (multiply-by-small + compare only — no division). Verified bit-exact vs C
# strtod in .probe/el_prototype.py over millions of >19-digit cases.

comptime _BIG_LIMBS: Int = 96  # 6144 bits — covers any double's exact compare
comptime _MAX_SIG_DIGITS: Int = 768  # beyond this, extra digits only set sticky


struct _Big(Copyable, Movable):
    var limbs: InlineArray[UInt64, _BIG_LIMBS]  # little-endian, base 2^64
    var n: Int  # used limbs (top limb nonzero; n == 0 means value 0)

    @always_inline
    def __init__(out self):
        self.limbs = InlineArray[UInt64, _BIG_LIMBS](uninitialized=True)
        self.n = 0

    @always_inline
    def set_u64(mut self, v: UInt64):
        if v == UInt64(0):
            self.n = 0
        else:
            self.limbs[0] = v
            self.n = 1

    @always_inline
    def mul_small(mut self, m: UInt64):
        var carry: UInt64 = UInt64(0)
        for i in range(self.n):
            var p = UInt128(self.limbs[i]) * UInt128(m) + UInt128(carry)
            self.limbs[i] = p.cast[DType.uint64]()
            carry = (p >> UInt128(64)).cast[DType.uint64]()
        if carry != UInt64(0):
            debug_assert(self.n < _BIG_LIMBS, "_Big limb overflow")
            self.limbs[self.n] = carry
            self.n += 1

    @always_inline
    def add_small(mut self, d: UInt64):
        var carry = d
        var i = 0
        while carry != UInt64(0):
            if i >= self.n:
                debug_assert(i < _BIG_LIMBS, "_Big limb overflow")
                self.limbs[i] = UInt64(0)
                self.n = i + 1
            var s = UInt128(self.limbs[i]) + UInt128(carry)
            self.limbs[i] = s.cast[DType.uint64]()
            carry = (s >> UInt128(64)).cast[DType.uint64]()
            i += 1


def _big_cmp(a: _Big, b: _Big) -> Int:
    if a.n != b.n:
        return -1 if a.n < b.n else 1
    var i = a.n - 1
    while i >= 0:
        if a.limbs[i] != b.limbs[i]:
            return -1 if a.limbs[i] < b.limbs[i] else 1
        i -= 1
    return 0


def _slow_exact(
    bytes: Span[UInt8, _], start: Int, end: Int, lower: UInt64
) -> UInt64:
    # Re-extract the FULL significand (capped, with a sticky bit) and exponent.
    var i = start
    if bytes[i] == B_MINUS:
        i += 1
    var sig = _Big()
    var digit_count = 0
    var dec_exp = 0
    var seen_dot = False
    var sticky = False
    while i < end:
        var c = bytes[i]
        if c == B_DOT:
            seen_dot = True
            i += 1
            continue
        if c == B_E_LOWER or c == B_E_UPPER:
            break
        var d = Int(c) - Int(B_0)
        if digit_count == 0 and d == 0:
            if seen_dot:
                dec_exp -= 1
            i += 1
            continue
        if digit_count < _MAX_SIG_DIGITS:
            sig.mul_small(UInt64(10))
            sig.add_small(UInt64(d))
            digit_count += 1
            if seen_dot:
                dec_exp -= 1
        else:
            if d != 0:
                sticky = True
            if not seen_dot:
                dec_exp += 1
        i += 1
    var exp_val = 0
    if i < end and (bytes[i] == B_E_LOWER or bytes[i] == B_E_UPPER):
        i += 1
        var eneg = False
        if i < end and bytes[i] == B_MINUS:
            eneg = True
            i += 1
        elif i < end and bytes[i] == B_PLUS:
            i += 1
        while i < end:
            exp_val = exp_val * 10 + (Int(bytes[i]) - Int(B_0))
            i += 1
        if eneg:
            exp_val = -exp_val
    var q = dec_exp + exp_val

    # Decode the lower candidate double → (M, E) with value = M * 2^E.
    var ef = Int((lower >> UInt64(_MANT_BITS)) & _INF_POWER)
    var frac = lower & ((UInt64(1) << UInt64(_MANT_BITS)) - UInt64(1))
    var bigM: UInt64
    var bigE: Int
    if ef == 0:
        bigM = frac
        bigE = -1074
    else:
        bigM = frac | (UInt64(1) << UInt64(_MANT_BITS))
        bigE = ef - 1075

    # Compare A = S*10^q against B = (2M+1) * 2^(E-1), clearing denominators by
    # multiplying the appropriate side (no division).
    var hn = UInt64(2) * bigM + UInt64(1)
    var he = bigE - 1
    var a = sig.copy()
    var b = _Big()
    b.set_u64(hn)
    if q >= 0:
        for _ in range(q):
            a.mul_small(UInt64(10))
    else:
        for _ in range(-q):
            b.mul_small(UInt64(10))
    if he >= 0:
        for _ in range(he):
            b.mul_small(UInt64(2))
    else:
        for _ in range(-he):
            a.mul_small(UInt64(2))

    var cmp = _big_cmp(a, b)
    if cmp < 0:
        return lower
    if cmp > 0:
        return lower + UInt64(1)
    # Exactly at the halfway: dropped (sticky) digits push it up; else round even.
    if sticky:
        return lower + UInt64(1)
    return lower if (bigM & UInt64(1)) == UInt64(0) else lower + UInt64(1)


def parse_float(
    bytes: Span[UInt8, _], start: Int, end: Int
) -> Optional[Float64]:
    """Parse the validated number span [start, end) as a Float64. Returns None
    only on magnitude overflow (so the caller preserves the raw text as a
    big-number); underflow rounds to 0.0 as it should."""
    var i = start
    var neg = False
    if bytes[i] == B_MINUS:
        neg = True
        i += 1

    var w: UInt64 = UInt64(0)
    var digit_count = 0
    var dec_exp = 0
    var seen_dot = False
    var started = False
    var truncated = False  # a nonzero significant digit was dropped past 19

    while i < end:
        var c = bytes[i]
        if c == B_DOT:
            seen_dot = True
            i += 1
            continue
        if c == B_E_LOWER or c == B_E_UPPER:
            break
        var d = Int(c) - Int(B_0)
        if not started:
            if d == 0:
                if seen_dot:
                    dec_exp -= 1
                i += 1
                continue
            started = True
        if digit_count < 19:
            w = w * UInt64(10) + UInt64(d)
            digit_count += 1
            if seen_dot:
                dec_exp -= 1
        else:
            if d != 0:
                truncated = True
            if not seen_dot:
                dec_exp += 1
        i += 1

    var exp_val = 0
    if i < end and (bytes[i] == B_E_LOWER or bytes[i] == B_E_UPPER):
        i += 1
        var eneg = False
        if i < end and bytes[i] == B_MINUS:
            eneg = True
            i += 1
        elif i < end and bytes[i] == B_PLUS:
            i += 1
        while i < end:
            exp_val = exp_val * 10 + (Int(bytes[i]) - Int(B_0))
            i += 1
        if eneg:
            exp_val = -exp_val

    var q = dec_exp + exp_val

    var bits = _compute_float(q, w)
    if truncated:
        # The 19-digit estimate is uncertain. If the `w` and `w+1` results round
        # apart, resolve the rounding EXACTLY with the big-integer slow path.
        var bits2 = _compute_float(q, w + UInt64(1))
        if bits2 != bits:
            var lower = bits if bits < bits2 else bits2
            bits = _slow_exact(bytes, start, end, lower)

    # Overflow → let the caller keep the raw text as a big-number.
    if ((bits >> UInt64(_MANT_BITS)) & _INF_POWER) == _INF_POWER:
        return None

    if neg:
        bits |= UInt64(1) << UInt64(63)
    return _bits_to_f64(bits)


# 100 two-digit pairs "00010203…9899" — index `2*r` / `2*r+1` gives the tens
# and units ASCII of the remainder `r = n % 100`.
comptime _DD = String(
    "00010203040506070809"
    "10111213141516171819"
    "20212223242526272829"
    "30313233343536373839"
    "40414243444546474849"
    "50515253545556575859"
    "60616263646566676869"
    "70717273747576777879"
    "80818283848586878889"
    "90919293949596979899"
)


@always_inline
def write_int_i64(mut w: ChunkWriter, value: Int64):
    """Write the decimal text of a signed `value`. Handles Int64 MIN by taking
    the magnitude in UInt64 (avoids overflow on negation)."""
    var tmp = InlineArray[UInt8, 24](
        uninitialized=True
    )  # 20 digits + sign + slack
    var pos = 24
    var neg = value < 0
    var v: UInt64
    if neg:
        v = UInt64(0) - value.cast[DType.uint64]()
    else:
        v = value.cast[DType.uint64]()
    var pairs = _DD.as_bytes()
    while v >= UInt64(100):
        var q = v // UInt64(100)
        var r = Int(v - q * UInt64(100))
        pos -= 2
        tmp[pos] = pairs[r * 2]
        tmp[pos + 1] = pairs[r * 2 + 1]
        v = q
    if v >= UInt64(10):
        var r = Int(v)
        pos -= 2
        tmp[pos] = pairs[r * 2]
        tmp[pos + 1] = pairs[r * 2 + 1]
    else:
        pos -= 1
        tmp[pos] = UInt8(0x30) + UInt8(Int(v))
    if neg:
        pos -= 1
        tmp[pos] = UInt8(0x2D)  # '-'
    w.span(Span(ptr=tmp.unsafe_ptr() + pos, length=24 - pos))


@always_inline
def write_uint_u64(mut w: ChunkWriter, value: UInt64):
    """Write the decimal text of an unsigned `value` — the full UInt64 range,
    which `write_int_i64` cannot carry."""
    var tmp = InlineArray[UInt8, 24](uninitialized=True)
    var pos = 24
    var v = value
    var pairs = _DD.as_bytes()
    while v >= UInt64(100):
        var q = v // UInt64(100)
        var r = Int(v - q * UInt64(100))
        pos -= 2
        tmp[pos] = pairs[r * 2]
        tmp[pos + 1] = pairs[r * 2 + 1]
        v = q
    if v >= UInt64(10):
        var r = Int(v)
        pos -= 2
        tmp[pos] = pairs[r * 2]
        tmp[pos + 1] = pairs[r * 2 + 1]
    else:
        pos -= 1
        tmp[pos] = UInt8(0x30) + UInt8(Int(v))
    w.span(Span(ptr=tmp.unsafe_ptr() + pos, length=24 - pos))


def parse_int64(bytes: Span[UInt8, _], start: Int, end: Int) -> Optional[Int64]:
    """Interpret a validated number span as Int64 — integer form only
    (optional sign plus digits; any '.', 'e', or 'E' means "not an
    integer"), range-checked including Int64's minimum. None means "not
    representable as Int64", never a syntax error (stage 2 owns syntax)."""
    var i = start
    var negative = False
    if i < end and bytes[i] == B_MINUS:
        negative = True
        i += 1
    if i >= end:
        return None
    var magnitude: UInt64 = 0
    while i < end:
        var c = bytes[i]
        if c < B_0 or c > B_9:
            return None  # float form — dot or exponent
        var digit = UInt64(c - B_0)
        if magnitude > (UInt64(0xFFFFFFFFFFFFFFFF) - digit) // 10:
            return None  # would overflow even UInt64
        magnitude = magnitude * 10 + digit
        i += 1
    if negative:
        if magnitude > UInt64(0x8000000000000000):
            return None
        if magnitude == UInt64(0x8000000000000000):
            return Int64(-9223372036854775807) - 1
        return -Int64(magnitude)
    if magnitude > UInt64(0x7FFFFFFFFFFFFFFF):
        return None
    return Int64(magnitude)


def parse_uint64(
    bytes: Span[UInt8, _], start: Int, end: Int
) -> Optional[UInt64]:
    """Interpret a validated number span as UInt64 — unsigned integer form
    only. None means "not representable", never a syntax error."""
    var i = start
    if i >= end or bytes[i] == B_MINUS:
        return None
    var magnitude: UInt64 = 0
    while i < end:
        var c = bytes[i]
        if c < B_0 or c > B_9:
            return None
        var digit = UInt64(c - B_0)
        if magnitude > (UInt64(0xFFFFFFFFFFFFFFFF) - digit) // 10:
            return None
        magnitude = magnitude * 10 + digit
        i += 1
    return magnitude
