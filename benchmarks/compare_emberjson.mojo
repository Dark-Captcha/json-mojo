# benchmarks/compare_emberjson.mojo — same-machine, same-binary head-to-head
# against EmberJson on the corpus trio (ARCHITECTURE.md, Measurement
# Discipline: same machine, same day, like for like, no silent wins).
#
# STATUS: this single-binary harness needs a toolchain BOTH libraries compile
# under, and EmberJson does not build on this repository's newer nightly
# (PERF.md, Corpus Scorecard). It is kept for the day that changes; until
# then the head-to-head runs under EmberJson's own pin via
# benchmarks/emberjson_micro_audit.mojo (copy instructions in PERF.md).
#
# Build and run, once compatible (the clone is gitignored, NOT a pixi task):
#   git clone https://github.com/bgreni/EmberJson references/EmberJson
#   pixi run mojo build -I . -I references/EmberJson -D ASSERT=none \
#       benchmarks/compare_emberjson.mojo -o .build/compare && .build/compare
#
# Category note, stated rather than hidden: our `parse` builds the lazy
# six-kind tape; EmberJson's `parse` builds its eager Value DOM. These are
# each library's user-facing "parse this document" verb — the product
# comparison — not identical amounts of work. Our move-in copy is taken
# outside the clock; EmberJson borrows and needs no copy.

from std.time import perf_counter_ns

from emberjson import parse as ember_parse
from emberjson import to_string as ember_to_string

from json import dumps as our_dumps
from json import parse as our_parse
from json._internal.simd import BLOCK_WIDTH

comptime CORPUS_DIR: StaticString = "references/EmberJson/bench_data/data/"
comptime MB: Float64 = 1024.0 * 1024.0


def _read_corpus(name: String) raises -> String:
    var path = String(CORPUS_DIR) + name
    with open(path, "r") as f:
        var text = String(unsafe_from_utf8=f.read_bytes())
        text.reserve(text.byte_length() + BLOCK_WIDTH)
        return text^


def _mbps(size_bytes: Int, best_ns: UInt) -> Float64:
    return (Float64(size_bytes) / MB) / (Float64(best_ns) / 1e9)


def _compare(name: String, iterations: Int) raises:
    var text = _read_corpus(name)
    var size = text.byte_length()
    print("──", name, "(", size, "bytes, best of", iterations, ")")

    # --- parse: ours ---------------------------------------------------------
    var best_ours = UInt(1) << 62
    var sink = 0
    for _ in range(iterations):
        var body = text.copy()
        var t0 = perf_counter_ns()
        var doc = our_parse(body^)
        var t1 = perf_counter_ns()
        sink += Int(doc.kind()._code)
        if t1 - t0 < best_ours:
            best_ours = t1 - t0

    # --- parse: EmberJson ----------------------------------------------------
    var best_ember = UInt(1) << 62
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var value = ember_parse(text)
        var t1 = perf_counter_ns()
        sink += 1 if value.is_object() or value.is_array() else 0
        if t1 - t0 < best_ember:
            best_ember = t1 - t0

    var ours_parse_mbps = _mbps(size, best_ours)
    var ember_parse_mbps = _mbps(size, best_ember)
    print(
        "  parse   json-mojo:",
        ours_parse_mbps,
        "MB/s\temberjson:",
        ember_parse_mbps,
        "MB/s\tratio:",
        ours_parse_mbps / ember_parse_mbps,
        "x",
    )

    # --- serialize: ours ------------------------------------------------------
    var doc = our_parse(text.copy())
    var best_ours_ser = UInt(1) << 62
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var out = our_dumps(doc)
        var t1 = perf_counter_ns()
        sink += out.byte_length()
        if t1 - t0 < best_ours_ser:
            best_ours_ser = t1 - t0

    # --- serialize: EmberJson -------------------------------------------------
    var value = ember_parse(text)
    var best_ember_ser = UInt(1) << 62
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var out = ember_to_string(value)
        var t1 = perf_counter_ns()
        sink += out.byte_length()
        if t1 - t0 < best_ember_ser:
            best_ember_ser = t1 - t0

    var ours_ser_mbps = _mbps(size, best_ours_ser)
    var ember_ser_mbps = _mbps(size, best_ember_ser)
    print(
        "  dump    json-mojo:",
        ours_ser_mbps,
        "MB/s\temberjson:",
        ember_ser_mbps,
        "MB/s\tratio:",
        ours_ser_mbps / ember_ser_mbps,
        "x",
    )
    if sink < 0:
        print("sink", sink)


def main() raises:
    print("json-mojo vs EmberJson — same machine, same binary, same bytes")
    _compare("twitter.json", 30)
    _compare("citm_catalog.json", 20)
    _compare("canada.json", 15)
