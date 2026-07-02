# Probe: compile-time reflection field walk, conformance checks, comptime
# loops, and trait default-method bodies — the mechanisms Layer 3 serde and
# the to[T] gateway matcher rest on.
# Run: pixi run mojo run .probe/probe_reflection.mojo
# Evidence source: the EmberJson clone in references/ uses all of these on
# recent nightlies; this file verifies them on this exact toolchain.

from std.reflection import reflect


trait Greet:
    def greet(self) -> String:
        return String("default greeting")  # default body — newer than the ported sheet


struct Point(Copyable, Greet, Movable):
    var x: Int
    var y: Float64
    var name: String

    def __init__(out self):
        self.x = 1
        self.y = 2.5
        self.name = "p"


def main():
    comptime r = reflect[Point]
    print("is_struct:", r.is_struct())
    print("field_count:", r.field_count())
    comptime names = r.field_names()
    comptime for i in range(r.field_count()):
        print("field:", names[i])

    print("Point conforms Greet:", conforms_to(Point, Greet))
    print("Int conforms Greet:", conforms_to(Int, Greet))  # retrofit check: expect False

    var p = Point()
    print("default trait body:", p.greet())

    ref first = r.field_ref[0](p)
    print("field_ref[0]:", first)
