# stage_one — the SIMD structural indexer: one pass over the input emitting
# the byte offsets of every structural character ({ } [ ] , :) outside
# strings, every unescaped quote (the string boundaries stage 2 walks
# between), and the START byte of every atom — a pseudo-structural, after
# simdjson, so stage 2 dispatches each value directly from a position and
# never re-scans whitespace gaps. All per-byte questions become branchless
# mask arithmetic on 64-byte blocks; the only loop body branch-work is
# walking set bits.
#
# Padding contract: the caller guarantees at least BLOCK_WIDTH readable
# bytes past `byte_length` (Document reserves them — .probe/SYNTAX.md,
# finding 17), so every block load is legal; tail bits beyond the length
# are masked off before use — including the scalar mask, so padding
# garbage can never mint an atom position past the input.
#
# Algorithm after simdjson (Langdale & Lemire, Apache-2.0); cross-checked
# against ehsanmok/json (MIT). Equivalence with the scalar mirror in
# tests/run_tests.mojo is the correctness gate (contract 2: the fallback
# is byte-for-byte identical).

from std.bit import count_trailing_zeros
from std.memory.unsafe import pack_bits

from json._internal.bytes import B_CR, B_LF, B_SPACE, B_TAB
from json._internal.simd import (
    BLOCK_WIDTH,
    CATEGORY_BACKSLASH,
    CATEGORY_QUOTE,
    CATEGORY_STRUCTURAL,
    classify_block,
    find_escape_mask64,
    prefix_xor64,
)


struct StructuralIndex(Movable):
    """The stage-1 product: ascending byte offsets of structural characters,
    unescaped quotes, and atom starts. Stage 2 walks this instead of the
    raw bytes."""

    var positions: List[UInt32]

    def __init__(out self, *, capacity: Int):
        self.positions = List[UInt32](capacity=capacity)


def build_structural_index(text: String) -> StructuralIndex:
    """Scan `text` in 64-byte blocks and return its structural index.
    Requires the padding contract described in the module header."""
    var bytes_view = text.as_bytes()
    var length = len(bytes_view)
    var pointer = bytes_view.unsafe_ptr()
    var index = StructuralIndex(capacity=length // 4 + 8)

    # Cross-block carries: `prev_in_string` is all-ones while inside a
    # string (an XOR mask for the prefix-XOR result); `prev_escape` is the
    # single-bit "byte 0 is escaped" carry maintained by the escape scanner;
    # `prev_scalar` is the single-bit "byte 63 was a non-quote scalar
    # outside strings" carry that keeps an atom spanning two blocks from
    # minting a second start position.
    var prev_in_string = UInt64(0)
    var prev_escape = UInt64(0)
    var prev_scalar = UInt64(0)

    var offset = 0
    while offset < length:
        var block = pointer.load[width=BLOCK_WIDTH](offset)
        var classified = classify_block(block)

        comptime V = SIMD[DType.uint8, BLOCK_WIDTH]
        var structural_mask = pack_bits[dtype=DType.uint64](
            (classified & V(CATEGORY_STRUCTURAL)).ne(V(0))
        )
        var quote_mask = pack_bits[dtype=DType.uint64](
            (classified & V(CATEGORY_QUOTE)).ne(V(0))
        )
        var backslash_mask = pack_bits[dtype=DType.uint64](
            (classified & V(CATEGORY_BACKSLASH)).ne(V(0))
        )
        var ws_mask = pack_bits[dtype=DType.uint64](
            block.eq(V(B_SPACE))
            | block.eq(V(B_TAB))
            | block.eq(V(B_LF))
            | block.eq(V(B_CR))
        )

        # Tail block: bits at and past `length` are padding garbage.
        var valid = ~UInt64(0)
        var remaining = length - offset
        if remaining < BLOCK_WIDTH:
            valid = (UInt64(1) << UInt64(remaining)) - 1
            structural_mask &= valid
            quote_mask &= valid
            backslash_mask &= valid
            ws_mask &= valid

        # Fast path A: entirely inside a string with no specials — the block
        # emits nothing and no carry changes (the giant-string-body skip).
        # Entering here implies `prev_scalar == 0` (the prior block's byte
        # 63 was inside the string); byte 63 here is in-string too.
        if (
            quote_mask == 0
            and backslash_mask == 0
            and prev_in_string == ~UInt64(0)
            and prev_escape == 0
        ):
            prev_scalar = UInt64(0)
            offset += BLOCK_WIDTH
            continue

        # Fast path B: no quotes, no backslashes, no carried string/escape
        # state — structurals and atom starts come from plain mask math.
        if (
            quote_mask == 0
            and backslash_mask == 0
            and prev_in_string == 0
            and prev_escape == 0
        ):
            var scalar = ~(structural_mask | ws_mask) & valid
            var atom_starts = scalar & ~((scalar << 1) | prev_scalar)
            prev_scalar = scalar >> UInt64(63)
            var bits = structural_mask | atom_starts
            while bits != 0:
                index.positions.append(
                    UInt32(offset + Int(count_trailing_zeros(bits)))
                )
                bits &= bits - 1
            offset += BLOCK_WIDTH
            continue

        var escape_mask = find_escape_mask64(backslash_mask, prev_escape)
        var unescaped_quotes = quote_mask & ~escape_mask
        var in_string_mask = prefix_xor64(unescaped_quotes) ^ prev_in_string
        var scalar = (
            ~(structural_mask | ws_mask | quote_mask) & ~in_string_mask & valid
        )
        var atom_starts = scalar & ~((scalar << 1) | prev_scalar)
        var emit_mask = (
            (structural_mask & ~in_string_mask) | unescaped_quotes | atom_starts
        )

        prev_in_string = ~UInt64(0) if (in_string_mask >> UInt64(63)) & UInt64(
            1
        ) else UInt64(0)
        prev_scalar = scalar >> UInt64(63)

        var bits = emit_mask
        while bits != 0:
            index.positions.append(
                UInt32(offset + Int(count_trailing_zeros(bits)))
            )
            bits &= bits - 1
        offset += BLOCK_WIDTH

    return index^
