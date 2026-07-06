from json import deserialize, loads, serialize


def main() raises:
    var document = loads('{"values":[1,2,3]}')
    if document["values"][1].to[Int64]() != 2:
        raise Error("installed json package failed cursor access")

    var values = deserialize[List[Int64]]("[1,2,3]")
    if values[0] + values[1] + values[2] != 6:
        raise Error("installed json package failed typed container serde")
    if serialize(values) != "[1,2,3]":
        raise Error("installed json package failed typed serialization")

