# Probe: List construction/length APIs for an unchecked tape-append fast
# path — the growth branch per append is provably dead when capacity is an
# exact upper bound (tape accounting: words <= 2*positions + 8), so the
# question is how to write through the buffer and set the final length.
# Candidates: (a) List(unsafe_uninit_length=n), (b) resize forms,
# (c) a steal constructor from a raw pointer. A compile error names the
# real API; that is the finding.
# Run: pixi run mojo run .probe/probe_list_uninit.mojo


def main():
    # (a) uninit-length constructor, String-style.
    var tape = List[UInt64](unsafe_uninit_length=8)
    var pointer = tape.unsafe_ptr()
    pointer[0] = UInt64(41)
    pointer[1] = UInt64(42)
    print(len(tape))  # 8 if the ctor exists and sets length
    print(tape[0], tape[1])  # 41 42

    # (b) shrink to the written prefix.
    tape.shrink(2)
    print(len(tape))  # 2
