# examples/formats.mojo — a tour of the format front-ends: the JSON5
# dialect and the three binary siblings (MessagePack, BSON, CBOR), plus the
# RFC 6902 / RFC 7396 patch functions. Every format flows through the same
# six-kind tape, so one Document/Value surface reads them all and
# `json.dumps` is the universal transcoder.
# Run: pixi run example

from bson import decode as bson_decode
from bson import dumps as bson_dumps
from cbor import decode as cbor_decode
from cbor import dumps as cbor_dumps
from json import (
    Dialect,
    ParseOptions,
    apply_patch,
    dumps,
    loads,
    merge_patch,
    parse,
)
from msgpack import decode as msgpack_decode
from msgpack import dumps as msgpack_dumps


def main() raises:
    print("== JSON5 dialect: comments, unquoted keys, trailing commas ==")
    comptime J5 = ParseOptions(dialect=Dialect.JSON5)
    var five = parse[J5](
        String(
            "{\n"
            "  // config files are the JSON5 habitat\n"
            "  retries: 3,\n"
            "  host: 'db.local',\n"
            "  timeout: .5,\n"
            "}"
        )
    )
    print("retries   :", five["retries"].to[Int64]())
    print("as JSON   :", dumps(five))  # dumps NORMALIZES to standard JSON

    print("")
    print("== MessagePack: JSON -> bytes -> JSON, one tape ==")
    var tweet = loads(String('{"name":"json-mojo","stars":[1,2,3]}'))
    var packed = msgpack_dumps(tweet)
    print("packed    :", len(packed), "bytes")
    var unpacked = msgpack_decode(packed^)
    print("transcoded:", dumps(unpacked))

    print("")
    print("== BSON: object documents, width-selected integers ==")
    var record = loads(String('{"id":4294967296,"name":"é\\n水","ok":true}'))
    var bson_bytes = bson_dumps(record)
    print("framed    :", len(bson_bytes), "bytes (length-prefixed document)")
    var from_bson = bson_decode(bson_bytes^)
    print("transcoded:", dumps(from_bson))

    print("")
    print("== CBOR: shortest-form heads, RFC 8949 ==")
    var mixed = loads(String('[0,23,24,255,65536,-1.5,"text",null]'))
    var cbor_bytes = cbor_dumps(mixed)
    print("encoded   :", len(cbor_bytes), "bytes")
    var from_cbor = cbor_decode(cbor_bytes^)
    print("transcoded:", dumps(from_cbor))

    print("")
    print("== RFC 6902 patch / RFC 7396 merge patch ==")
    var base = loads(String('{"config":{"retries":3,"debug":true}}'))
    var operations = loads(
        String(
            '[{"op":"replace","path":"/config/retries","value":5},'
            '{"op":"remove","path":"/config/debug"}]'
        )
    )
    print("patched   :", dumps(apply_patch(base, operations)))
    var merged = merge_patch(
        loads(String('{"keep":1,"drop":2}')),
        loads(String('{"drop":null,"add":3}')),
    )
    print("merged    :", dumps(merged))
