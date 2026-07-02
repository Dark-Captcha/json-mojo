# benchmarks/scaling.mojo — the diagnostic suite: WHERE parse time goes and
# HOW throughput scales across cores. This is the "know what we're weak at"
# data (ARCHITECTURE.md, Measurement Discipline).
#
# Section 1 — stage breakdown, single thread: stage 1 (structural index) and
# stage 2 (grammar + tape, which now owns lazy per-body UTF-8 validation)
# timed separately per corpus, with each stage's share of full `parse`. The
# residual between the stage sum and full parse is copy/reserve/assembly
# overhead. There is no separate UTF-8 pass to time — it was folded into
# string validation (the optimization pass).
#
# Section 2 — core scaling: N workers (1,2,4,8,16,32 on this 16C/32T box),
# each parsing its own copy of the document `reps` times. Aggregate MB/s,
# speedup vs one worker, efficiency. Each iteration copies the input (the
# move-in feed), so this measures parser + allocator under parallel load —
# flat efficiency means compute-bound; decaying means allocation or memory
# bandwidth contention.

from std.algorithm import parallelize
from std.time import perf_counter_ns

from json import dumps, parse
from json._internal.simd import BLOCK_WIDTH
from json._internal.stage_one import build_structural_index
from json._internal.tape import build_tape

comptime CORPUS_DIR: StaticString = "references/EmberJson/bench_data/data/"
comptime MB: Float64 = 1024.0 * 1024.0


def _read_corpus(name: String) raises -> String:
    var path = String(CORPUS_DIR) + name
    try:
        with open(path, "r") as f:
            var text = String(unsafe_from_utf8=f.read_bytes())
            text.reserve(text.byte_length() + BLOCK_WIDTH)
            return text^
    except _:
        raise Error(
            "corpus file missing: "
            + path
            + " — clone EmberJson into references/"
        )


def _mbps(size_bytes: Int, best_ns: UInt) -> Float64:
    return (Float64(size_bytes) / MB) / (Float64(best_ns) / 1e9)


# --- Section 1: stage breakdown ----------------------------------------------------


def _stage_breakdown(name: String, iterations: Int) raises:
    var text = _read_corpus(name)
    var size = text.byte_length()
    print("── stages:", name, "(", size, "bytes )")

    # Stage 1 alone.
    var best_s1 = UInt(1) << 62
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var index = build_structural_index(text)
        var t1 = perf_counter_ns()
        if len(index.positions) == 0:
            print("impossible")  # sink
        if t1 - t0 < best_s1:
            best_s1 = t1 - t0

    # Stage 2 alone (index built once, outside the clock).
    var index = build_structural_index(text)
    var best_s2 = UInt(1) << 62
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var tape = build_tape(text, index)
        var t1 = perf_counter_ns()
        if len(tape) == 0:
            print("impossible")  # sink
        if t1 - t0 < best_s2:
            best_s2 = t1 - t0

    # Full parse (copy outside the clock) and dumps.
    var best_parse = UInt(1) << 62
    for _ in range(iterations):
        var body = text.copy()
        var t0 = perf_counter_ns()
        var doc = parse(body^)
        var t1 = perf_counter_ns()
        if doc.kind()._code > UInt8(5):
            print("impossible")  # sink
        if t1 - t0 < best_parse:
            best_parse = t1 - t0
    var doc = parse(text.copy())
    var best_dumps = UInt(1) << 62
    for _ in range(iterations):
        var t0 = perf_counter_ns()
        var out = dumps(doc)
        var t1 = perf_counter_ns()
        if out.byte_length() == 0:
            print("impossible")  # sink
        if t1 - t0 < best_dumps:
            best_dumps = t1 - t0

    var stage_sum = best_s1 + best_s2
    var pct_s1 = 100.0 * Float64(best_s1) / Float64(best_parse)
    var pct_s2 = 100.0 * Float64(best_s2) / Float64(best_parse)
    var pct_rest = (
        100.0
        * Float64(best_parse - stage_sum)
        / Float64(best_parse) if best_parse
        > stage_sum else 0.0
    )

    print("  stage1  ", _mbps(size, best_s1), "MB/s\t", pct_s1, "% of parse")
    print("  stage2  ", _mbps(size, best_s2), "MB/s\t", pct_s2, "% of parse")
    print("  overhead (copy/assembly)\t\t", pct_rest, "% of parse")
    print("  parse   ", _mbps(size, best_parse), "MB/s")
    print("  dumps   ", _mbps(size, best_dumps), "MB/s")


# --- Section 2: core scaling --------------------------------------------------------


def _scaling(name: String, reps: Int) raises:
    var text = _read_corpus(name)
    var size = text.byte_length()
    _ = parse(text.copy())  # warmup + validity guarantee
    print("── scaling:", name, "(", size, "bytes,", reps, "parses/worker )")

    var ladder = List[Int]()
    ladder.append(1)
    ladder.append(2)
    ladder.append(4)
    ladder.append(8)
    ladder.append(16)
    ladder.append(32)

    var baseline = 0.0
    for w in range(len(ladder)):
        var workers = ladder[w]
        var sinks = List[Int](capacity=workers)
        for _ in range(workers):
            sinks.append(0)
        var sink_ptr = sinks.unsafe_ptr()

        @parameter
        def work(i: Int):
            var local = 0
            for _ in range(reps):
                try:
                    var body = text.copy()
                    var doc = parse(body^)
                    local += Int(doc.kind()._code)
                except _:
                    local -= 1_000_000
            sink_ptr[i] = local

        var t0 = perf_counter_ns()
        parallelize[work](workers, workers)
        var t1 = perf_counter_ns()

        var checksum = 0
        for i in range(workers):
            checksum += sinks[i]
        if checksum < 0:
            print("  PARSE FAILURES under parallel load at", workers, "workers")

        var wall_s = Float64(t1 - t0) / 1e9
        var aggregate = (
            Float64(size) * Float64(reps) * Float64(workers) / MB
        ) / wall_s
        if workers == 1:
            baseline = aggregate
        var speedup = aggregate / baseline
        var efficiency = 100.0 * speedup / Float64(workers)
        print(
            "  workers=",
            workers,
            "\taggregate=",
            aggregate,
            "MB/s\tspeedup=",
            speedup,
            "x\tefficiency=",
            efficiency,
            "%",
        )


def main() raises:
    print("json-mojo diagnostics — AMD 7950X3D 16C/32T")
    print("")
    _stage_breakdown("twitter.json", 30)
    _stage_breakdown("citm_catalog.json", 20)
    _stage_breakdown("canada.json", 15)
    print("")
    _scaling("twitter.json", 200)
    _scaling("citm_catalog.json", 100)
    _scaling("canada.json", 60)
