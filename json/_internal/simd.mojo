# simd — the branchless lane idioms stage 1 is built from: nibble-lookup
# byte classification, per-bit prefix XOR, and the escape-run scanner.
# All operate on 64-byte blocks reduced to UInt64 masks via `pack_bits`.
#
# Algorithms after simdjson (Langdale & Lemire, "Parsing Gigabytes of JSON
# per Second", Apache-2.0); Mojo idioms cross-checked against the working
# ehsanmok/json stage 1 (MIT). Carry-less-multiply prefix XOR is available
# on x86 (.probe/probe_clmul.mojo); the six-shift software form below is
# ISA-free and within budget — swap under a comptime gate only if the
# corpus benches say so.

comptime BLOCK_WIDTH: Int = 64

# Classification categories — one bit per category so a single AND answers
# "is this byte in category X".
comptime CATEGORY_QUOTE: UInt8 = 0x01
comptime CATEGORY_BACKSLASH: UInt8 = 0x10
comptime CATEGORY_STRUCTURAL: UInt8 = 0xEE  # {} [] , : collectively


@always_inline
def classify_block(
    block: SIMD[DType.uint8, BLOCK_WIDTH]
) -> SIMD[DType.uint8, BLOCK_WIDTH]:
    """Two-table nibble lookup: category bits for every byte in the block.
    A byte's category is `LOW[b & 0xF] & HIGH[b >> 4]` — the classic
    PSHUFB-pair classifier, lowered to one shuffle per table."""
    comptime LOW_TABLE = SIMD[DType.uint8, 16](
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x02,
        0x44,
        0x30,
        0x88,
        0x00,
        0x00,
    )
    comptime HIGH_TABLE = SIMD[DType.uint8, 16](
        0x00,
        0x00,
        0x21,
        0x02,
        0x00,
        0x1C,
        0x00,
        0xC0,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    )
    var low_nibble = block & 0x0F
    var high_nibble = block >> 4
    return LOW_TABLE._dynamic_shuffle(low_nibble) & HIGH_TABLE._dynamic_shuffle(
        high_nibble
    )


@always_inline
def prefix_xor64(mask: UInt64) -> UInt64:
    """Per-bit prefix XOR: bit i of the result is the XOR of bits 0..i.
    Applied to an unescaped-quote mask this yields the in-string mask —
    state flips at every quote. Six shift-XOR pairs, ISA-free."""
    var r = mask
    r ^= r << 1
    r ^= r << 2
    r ^= r << 4
    r ^= r << 8
    r ^= r << 16
    r ^= r << 32
    return r


@always_inline
def find_escape_mask64(backslash: UInt64, mut prev_escape: UInt64) -> UInt64:
    """Bit-mask of bytes escaped by a backslash within this block,
    branchless over backslash runs of any length and parity.

    `prev_escape` is the cross-block carry (0 or 1): on entry, whether
    byte 0 of this block is escaped by a trailing backslash of the prior
    block; on exit, the same flag for the next block."""
    if backslash == 0:
        var escaped = prev_escape
        prev_escape = 0
        return escaped

    var incoming_escape = prev_escape

    # Backslashes that are themselves escaped do not start runs.
    var run_starts_input = backslash & ~prev_escape
    # Only a byte immediately following an unescaped backslash can be escaped.
    var follows_escape = (run_starts_input << 1) | prev_escape

    # Runs starting on odd bit positions flip the parity trick below.
    comptime EVEN_BITS: UInt64 = 0x5555555555555555
    var odd_run_starts = run_starts_input & ~EVEN_BITS & ~follows_escape

    # Adding the backslash mask propagates a carry through each contiguous
    # run that starts at an odd position; the add's overflow is exactly the
    # carry into the next block.
    var sum = odd_run_starts + run_starts_input
    prev_escape = UInt64(1) if sum < odd_run_starts else UInt64(0)

    # XOR restores per-run parity; keep only bytes that follow a backslash.
    var escaped = (sum ^ backslash ^ ~EVEN_BITS) & follows_escape
    return escaped | incoming_escape
