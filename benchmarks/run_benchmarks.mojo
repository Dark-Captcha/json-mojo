# benchmarks/run_benchmarks.mojo — corpus throughput for json-mojo's two hot
# verbs: `parse` (move-in, stage 1 + stage 2) and `dumps` (tape re-emission).
#
# Corpus: the industry trio (twitter / citm_catalog / canada), read from the
# EmberJson reference clone so the head-to-head comparison measures the exact
# same bytes (`git clone https://github.com/bgreni/EmberJson
# references/EmberJson` if absent — references/ is gitignored).
#
# Protocol (ARCHITECTURE.md, Measurement Discipline): min-of-N wall time via
# `perf_counter_ns` — the minimum is the least-noise estimator on a loaded
# box; throughput = bytes / min_seconds. The input copy for move-in parsing
# is taken OUTSIDE the timed window. Sinks defeat dead-code elimination.

from std.sys import argv
from std.time import perf_counter_ns

from json import dumps, loads, parse

comptime CORPUS_DIR: StaticString = "references/EmberJson/bench_data/data/"
comptime MB: Float64 = 1024.0 * 1024.0


def _read_corpus(name: String) raises -> String:
    var path = String(CORPUS_DIR) + name
    try:
        with open(path, "r") as f:
            return String(unsafe_from_utf8=f.read_bytes())
    except _:
        raise Error(
            "corpus file missing: "
            + path
            + " — clone EmberJson into references/ (see module header)"
        )


def _report(label: String, size_bytes: Int, best_ns: UInt):
    var seconds = Float64(best_ns) / 1e9
    var throughput = (Float64(size_bytes) / MB) / seconds
    print(
        label,
        "\t",
        Float64(best_ns) / 1e6,
        "ms\t",
        throughput,
        "MB/s",
    )


def _bench_file(name: String, iterations: Int) raises:
    var text = _read_corpus(name)
    var size = text.byte_length()
    print("──", name, "(", size, "bytes, best of", iterations, ")")

    # parse — the copy that feeds move-in ownership is made outside the clock.
    var best_parse = UInt(1) << 62
    var parse_sink = 0
    for _ in range(iterations):
        var body = text.copy()
        var t0 = perf_counter_ns()
        var doc = parse(body^)
        var t1 = perf_counter_ns()
        parse_sink += Int(doc.kind()._code)
        if t1 - t0 < best_parse:
            best_parse = t1 - t0
    _report("  parse", size, best_parse)

    # dumps — one parsed document, re-emitted per iteration.
    var doc = parse(text.copy())
    var best_dumps = UInt(1) << 62
    var dumps_sink = 0
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var out = dumps(doc)
        var t1 = perf_counter_ns()
        dumps_sink += out.byte_length()
        if t1 - t0 < best_dumps:
            best_dumps = t1 - t0
    _report("  dumps", size, best_dumps)

    if parse_sink < 0 or dumps_sink < 0:
        print("sink", parse_sink, dumps_sink)  # never taken — DCE guard


def main() raises:
    print("json-mojo corpus benchmarks")
    _bench_file("twitter.json", 40)
    _bench_file("citm_catalog.json", 30)
    _bench_file("canada.json", 20)
