# Probe (finding 36): the container-deserialization ownership wall FELL —
# an __extension body may accumulate across raising calls when the raise
# path consumes the partial container via destroy_with, with comptime-assert
# element evidence. This file compiles and runs green AS A STANDALONE MODULE.
#
# Re-landing in json/value.mojo is blocked by a compiler ICE on this pin:
# once `__extension List(FromJson)` exists in value.mojo, any CROSS-MODULE
# `conforms_to(List[X], FromJson)` query (the to[T] gateway's comptime-if)
# crashes decl-body resolution — even with a trivial extension body. The
# same query against ToJson works. Minimal reproducer:
#     from json.value import FromJson
#     print(conforms_to(List[Int64], FromJson))   # ICE
# Re-attempt each nightly; the mechanism below is the implementation to
# re-land.

from json.value import Value
from json import loads

comptime _CB = ImplicitlyDeletable & Movable


trait FromX(_CB):
    @staticmethod
    def from_x[origin: ImmutOrigin, //](value: Value[origin], out result: Self) raises:
        ...


__extension SIMD(FromX):
    @staticmethod
    def from_x[origin: ImmutOrigin, //](value: Value[origin], out result: Self) raises:
        result = value.to[Self]()


def _drop_element[T: ImplicitlyDeletable](var item: T):
    pass


__extension List(FromX):
    @staticmethod
    def from_x[origin: ImmutOrigin, //](value: Value[origin], out result: Self) raises:
        comptime assert conforms_to(Self.T, FromX), "element must convert"
        comptime assert conforms_to(
            Self.T, ImplicitlyDeletable
        ), "element must be deletable"
        result = Self()
        try:
            for element in value.elements():
                result.append(Self.T.from_x(element))
        except error:
            result^.destroy_with(_drop_element[Self.T])
            raise error^


def _drop_pair[K: ImplicitlyDeletable, V: ImplicitlyDeletable](
    var key: K, var value: V
):
    pass


__extension Dict(FromX):
    @staticmethod
    def from_x[origin: ImmutOrigin, //](value: Value[origin], out result: Self) raises:
        comptime assert conforms_to(Self.V, FromX), "value must convert"
        comptime assert conforms_to(
            Self.V, ImplicitlyDeletable
        ), "value must be deletable"
        comptime assert conforms_to(
            Self.K, ImplicitlyDeletable
        ), "key must be deletable"
        result = Self()
        try:
            for member in value.members():
                var item: Self.V = Self.V.from_x(member.value())
                result[rebind_var[Self.K](member.key())] = item^
        except error:
            result^.destroy_with(_drop_pair[Self.K, Self.V])
            raise error^


def main() raises:
    var doc = loads("[1,2,3]")
    var numbers: List[Int64] = List[Int64].from_x(doc.root())
    var total = Int64(0)
    for n in numbers:
        total += n
    print("wall check:", total)  # expect 6

    var obj = loads('{"a":1,"b":2}')
    var mapping: Dict[String, Int64] = Dict[String, Int64].from_x(obj.root())
    print("dict check:", mapping["a"] + mapping["b"])  # expect 3

    # Error path: partial container must be consumed, error surfaced.
    var bad = loads('[1,"x",3]')
    try:
        var broken: List[Int64] = List[Int64].from_x(bad.root())
        print("error path FAILED — no raise")
    except error:
        print("error path ok:", String(error))
