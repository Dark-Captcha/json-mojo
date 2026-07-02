# examples/basic_usage.mojo — the front-door tour: parse, access, iterate,
# point, introspect, serialize, derive. Run with `pixi run example`.

from json import ValueKind, deserialize, dumps, loads, serialize


struct Server(Copyable, Defaultable, Movable):
    """A plain struct — no trait conformance, no boilerplate: `deserialize`
    and `serialize` derive both directions through compile-time reflection."""

    var host: String
    var port: Int64
    var secure: Bool

    def __init__(out self):
        self.host = ""
        self.port = 0
        self.secure = False


def main() raises:
    # Minute one — parse and read.
    var data = loads('{"name":"Alice","scores":[95,87,92],"active":true}')
    print("name:    ", data["name"].to[String]())
    print("first:   ", data["scores"][0].to[Int]())
    print("active:  ", data["active"].to[Bool]())

    # Iterate arrays and objects.
    var total = Int64(0)
    for score in data["scores"].elements():
        total += score.to[Int64]()
    print("total:   ", total)
    for member in data.members():
        print("member:  ", member.key(), "->", member.value().kind()._code)

    # Address into the document with an RFC 6901 JSON Pointer.
    print("pointer: ", data.at("/scores/2").to[Int]())

    # Numbers are lossless raw text — introspect before converting.
    var big = loads('{"id":9223372036854775808}')
    print("fits Int64? ", big["id"].fits_int64())
    print("fits UInt64?", big["id"].fits_uint64())

    # dumps re-emits the parsed document, compact and byte-faithful.
    print("compact: ", dumps(data))

    # Typed serde — the struct above declares nothing and still round-trips.
    var server = deserialize[Server](
        '{"host":"api.example.com","port":8443,"secure":true}'
    )
    print("server:  ", server.host, server.port, server.secure)
    print("json:    ", serialize(server))

    # Errors carry the byte offset AND the path to the failure.
    try:
        _ = loads('{"config":{"retries":nope}}')
    except error:
        print("error:   ", String(error))
