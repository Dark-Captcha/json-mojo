# Probe: String capacity introspection and reservation — what Document
# needs to guarantee its 64-byte SIMD tail padding after taking the input
# by move. Method names are candidates; a compile error names the real API.
# Run: pixi run mojo run .probe/probe_string_capacity.mojo


def main():
    var text = String("hello")
    print("length:", text.byte_length())
    print("capacity:", text.capacity())
    text.reserve(128)
    print("capacity after reserve(128):", text.capacity())
    print("content intact:", text)
