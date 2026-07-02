# probe_clmul.mojo — probe carryless multiply / PCLMULQDQ availability.
# Attempts multiple import paths. Reports what succeeds.

from std.sys.intrinsics import llvm_intrinsic

def main():
    # Try llvm_intrinsic for PCLMULQDQ.
    # LLVM intrinsic: llvm.x86.pclmulqdq takes two <2 x i64> args + i8 imm.
    # In Mojo, SIMD[DType.uint64, 2] maps to <2 x i64>.
    var a = SIMD[DType.uint64, 2](UInt64(0xDEADBEEF), UInt64(0))
    var b = SIMD[DType.uint64, 2](UInt64(0xFFFFFFFFFFFFFFFF), UInt64(0))
    # imm8=0x00 means low-half × low-half carryless multiply
    var result = llvm_intrinsic["llvm.x86.pclmulqdq", SIMD[DType.uint64, 2]](a, b, UInt8(0))
    print("pclmulqdq result[0]:", result[0])
    print("pclmulqdq result[1]:", result[1])
    # 0xDEADBEEF × all-ones under GF(2) = prefix_xor of 0xDEADBEEF repeated
    # Just print them; any non-crash means the intrinsic is available.
    print("PCLMULQDQ via llvm_intrinsic: AVAILABLE")
