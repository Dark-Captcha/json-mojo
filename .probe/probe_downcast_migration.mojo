# Probe: can the deprecated `trait_downcast[Trait](ref)` in the reflection
# field walk be replaced by the compiler-suggested `conforms_to` evidence —
# i.e. a plain `ref field = r.field_ref[i](result)` binding inside a
# `comptime if conforms_to(field_type, ...)` branch?

from std.reflection import reflect

comptime _CB = ImplicitlyDeletable & Movable


struct Point(Copyable, Defaultable, Movable):
    var x: Int64

    def __init__(out self):
        self.x = 0


def give[T: _CB]() raises -> T:
    comptime if conforms_to(T, Defaultable):
        var out: T = {}
        return out^
    else:
        raise Error("not defaultable")


def fill_a[T: _CB](out result: T) raises:
    comptime r = reflect[T]
    comptime if conforms_to(T, Defaultable):
        result = {}
    else:
        raise Error("probe only handles Defaultable")
    comptime field_types = r.field_types()
    comptime for i in range(r.field_count()):
        comptime if conforms_to(field_types[i], _CB & Defaultable):
            ref field = r.field_ref[i](result)
            field = give[type_of(field)]()
        else:
            raise Error("field lacks conformance")


def fill_b[T: _CB](out result: T) raises:
    comptime r = reflect[T]
    comptime if conforms_to(T, Defaultable):
        result = {}
    else:
        raise Error("probe only handles Defaultable")
    comptime field_types = r.field_types()
    comptime for i in range(r.field_count()):
        comptime assert conforms_to(
            field_types[i], _CB & Defaultable
        ), "field must convert"
        ref field = r.field_ref[i](result)
        field = give[type_of(field)]()


def main() raises:
    var p: Point = fill_a[Point]()
    print("variant A ok, x =", p.x)
    var q: Point = fill_b[Point]()
    print("variant B ok, x =", q.x)
