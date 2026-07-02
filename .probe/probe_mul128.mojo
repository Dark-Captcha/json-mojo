# probe_mul128.mojo — probe 128-bit / wide multiply availability.
# Checks: DType.uint128, UInt128, mul_hi/widening intrinsics,
# llvm widening mul, schoolbook fallback.

from std.sys.intrinsics import llvm_intrinsic

def main():
    # --- 1. Does UInt128 type exist? ---
    var u: UInt128 = UInt128(0xFFFFFFFFFFFFFFFF) * UInt128(2)
    print("UInt128 construct + mul:", u)  # 36893488147419103230

    # --- 2. Can we use it for wide multiply (u64 × u64 → u128)? ---
    var a = UInt128(0xFFFFFFFFFFFFFFFF)
    var b = UInt128(0xFFFFFFFFFFFFFFFF)
    var prod = a * b
    print("u128 wide mul high half:", (prod >> 64).cast[DType.uint64]())
    print("u128 wide mul low  half:", prod.cast[DType.uint64]())

    # --- 3. Does DType.uint128 exist for SIMD? ---
    # (unlikely but check)
    # var s128 = SIMD[DType.uint128, 1](UInt128(42))
    # print("SIMD uint128:", s128[0])
    # Commented out — will break if not available. We'll try a compile trick below.

    # --- 4. Try llvm widening mul intrinsic: umul.with.overflow.i64 ---
    # Returns {i64, i1}; the bit is the overflow flag.
    # In Mojo this should be SIMD[DType.uint64,1] + Bool or similar struct.
    # Actually llvm.umul.with.overflow returns a {value, overflow_flag}.
    # Try it — if it errors at codegen we'll know.
    # Note: We skip this since UInt128 multiplication already gives us the
    # full 128-bit product. Just verify the high word extraction.

    # --- 5. Verify schoolbook 32-bit split works ---
    # a64 × b64 → 128 bits via four 32×32 multiplications
    var a64: UInt64 = UInt64(0xFFFFFFFFFFFFFFFE)
    var b64: UInt64 = UInt64(0xFFFFFFFFFFFFFFFE)
    var lo_a = UInt64(a64 & UInt64(0xFFFFFFFF))
    var hi_a = UInt64(a64 >> 32)
    var lo_b = UInt64(b64 & UInt64(0xFFFFFFFF))
    var hi_b = UInt64(b64 >> 32)
    var ll = lo_a * lo_b
    var lh = lo_a * hi_b
    var hl = hi_a * lo_b
    var hh = hi_a * hi_b
    var mid = lh + hl
    var carry = UInt64(1) if mid < lh else UInt64(0)
    var lo64 = ll + (mid << 32)
    var carry2 = UInt64(1) if lo64 < ll else UInt64(0)
    var hi64 = hh + (mid >> 32) + (carry << 32) + carry2

    # Compare against UInt128 ground truth
    var truth = UInt128(a64) * UInt128(b64)
    var truth_lo = truth.cast[DType.uint64]()
    var truth_hi = (truth >> 64).cast[DType.uint64]()
    print("schoolbook lo64:", lo64, "== truth_lo:", truth_lo, "match:", lo64 == truth_lo)
    print("schoolbook hi64:", hi64, "== truth_hi:", truth_hi, "match:", hi64 == truth_hi)

    print("PROBE_MUL128 DONE: UInt128 EXISTS, wide mul via UInt128 works")
