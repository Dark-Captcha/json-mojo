# benchmarks/micro.mojo — the retired prototype's micro corpora, byte-for-byte
# (small / nested / array_80 / string_heavy / string_huge / floats_200), so its
# historical scorecard cells can be audited under one machine and one protocol.
# Reports avg (the prototype's metric) AND min. The input copy feeding move-in
# runs inside the clock — the prototype's `loads` copied internally, so this
# keeps the accounting identical.

from std.time import perf_counter_ns

from json import dumps, loads

comptime MB: Float64 = 1024.0 * 1024.0


def _bench(name: StaticString, payload: String, iterations: Int) raises:
    var size = payload.byte_length()
    var doc = loads(payload.copy())  # warm-up + validity

    var total = UInt(0)
    var best = UInt(1) << 62
    var sink = 0
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var parsed = loads(payload.copy())
        var t1 = perf_counter_ns()
        sink += Int(parsed.kind()._code)
        total += t1 - t0
        if t1 - t0 < best:
            best = t1 - t0
    var avg_parse = (Float64(size) * Float64(iterations) / MB) / (
        Float64(total) / 1e9
    )
    var best_parse = (Float64(size) / MB) / (Float64(best) / 1e9)

    total = UInt(0)
    best = UInt(1) << 62
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var out = dumps(doc)
        var t1 = perf_counter_ns()
        sink += out.byte_length()
        total += t1 - t0
        if t1 - t0 < best:
            best = t1 - t0
    var avg_dump = (Float64(size) * Float64(iterations) / MB) / (
        Float64(total) / 1e9
    )
    var best_dump = (Float64(size) / MB) / (Float64(best) / 1e9)

    print(
        name,
        "\tbytes=",
        size,
        "\tparse best/avg=",
        best_parse,
        "/",
        avg_parse,
        "\tdump best/avg=",
        best_dump,
        "/",
        avg_dump,
        "MB/s",
    )
    if sink < 0:
        print("sink", sink)


def main() raises:
    print("json-mojo micro corpora (prototype-compatible cells)")
    _bench("small     ", '{"name":"Alice","age":30,"active":true}', 200)
    _bench(
        "nested    ",
        (
            '{"image":{"w":800,"h":600,"title":"View"},"ids":[1,2,3,4,5,6,7,8],"active":false}'
        ),
        200,
    )
    var big = String("[")
    for i in range(80):
        if i > 0:
            big += ","
        big += '{"id":'
        big += String(i)
        big += ',"name":"item-'
        big += String(i)
        big += '","ok":true}'
    big += "]"
    _bench("array_80  ", big, 200)
    var strdoc = String('{"text":"')
    for _ in range(40):
        strdoc += "the quick brown fox jumps over the lazy dog "
    strdoc += '","count":42}'
    _bench("str_heavy ", strdoc, 200)
    var big_str = String('{"text":"')
    for _ in range(400):
        big_str += "the quick brown fox jumps over the lazy dog "
    big_str += '","count":42}'
    _bench("str_huge  ", big_str, 50)
    var floats = String("[")
    for i in range(200):
        if i > 0:
            floats += ","
        floats += "3.14"
    floats += "]"
    _bench("floats_200", floats, 200)
