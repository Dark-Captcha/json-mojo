# PERF — json-mojo Performance Record

> **Version:** 1.2.0 | **Updated:** 2026-07-03

The measured scorecard the Performance Promise (ARCHITECTURE.md) is judged by: corpus and micro throughput versus the incumbents, where parse time goes, how throughput scales across cores, and the named weaknesses — no silent wins.

---

| #   | Section                                                 |
| --- | ------------------------------------------------------- |
| 1   | [Conditions](#conditions)                               |
| 2   | [Corpus Scorecard](#corpus-scorecard)                   |
| 3   | [Micro Scorecard](#micro-scorecard)                     |
| 4   | [Where Time Goes](#where-time-goes)                     |
| 5   | [Core Scaling](#core-scaling)                           |
| 6   | [What Made It Fast](#what-made-it-fast)                 |
| 7   | [Weaknesses and Roadmap](#weaknesses-and-roadmap)       |
| 8   | [Prototype Scorecard Audit](#prototype-scorecard-audit) |
| 9   | [Reproducing](#reproducing)                             |

---

## Conditions

| Item             | Detail                                                                                                                                                                                                                                                                                            |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Machine          | AMD Ryzen 9 7950X3D — 16 cores / 32 threads, Linux (Arch)                                                                                                                                                                                                                                         |
| Toolchain        | Mojo `1.0.0b3.dev2026070206`, `mojo build -D ASSERT=none` (release posture; `mojo run` JIT is ~35% slower)                                                                                                                                                                                        |
| Protocol         | Min-of-N wall time via `perf_counter_ns`; the input copy feeding move-in ownership is inside the clock for micro cells (matching the prototype's accounting) and outside for corpus cells. Cells under ~100 B discretize on timer granularity — their best-of quantizes to a few nanosecond ticks |
| Corpus           | `twitter.json` (632 KB), `citm_catalog.json` (1.7 MB), `canada.json` (2.2 MB) — the exact bytes in the EmberJson clone, so both libraries measure identical input                                                                                                                                 |
| Variance         | Numbers are reported as observed ranges where runs disagree: absolute throughput drifted up to ~10% across this session (boost/thermal state — the untouched `dumps` path moved with it). Comparisons within one run are exact                                                                    |
| Correctness gate | Every number below was taken with all gates green: 40/40 unit, JSONTestSuite 283/0 with 95/95 `dumps ∘ loads` round-trip, json5-tests 112/0, MessagePack vectors 55/0, float differential 1,500/0, fuzz 750/0, UTF-8 differential 424/0. Dialects and siblings never touch the measured RFC 8259 path (comptime erasure) |

---

## Corpus Scorecard

json-mojo measured under this repository's pin; EmberJson measured **on the same machine under its own pinned toolchain** (its source does not compile on this repository's newer nightly — "released best" per the measurement discipline).

| Corpus  | json-mojo parse | EmberJson parse | Ratio        | json-mojo dumps | EmberJson stringify |
| ------- | --------------- | --------------- | ------------ | --------------- | ------------------- |
| twitter | 0.82–0.97 GB/s  | 0.40 GB/s       | **2.0–2.4×** | 5.0–5.5 GB/s    | not captured        |
| citm    | 1.11–1.29 GB/s  | 0.61 GB/s       | **1.8–2.1×** | 7.1–8.3 GB/s    | not captured        |
| canada  | 0.86–0.88 GB/s  | 0.30 GB/s       | **2.9×**     | 2.3–2.6 GB/s    | 0.40 GB/s (**~6×**) |

1.1.0 re-measure: canada rose from 0.72–0.80 to **0.86–0.88 GB/s** — the SIMD digit-run scan in number validation — in a session where the machine sat at the LOW end of its recorded state (the twitter/citm control cells landed at their range bottoms). The twitter/citm spans above merge both sessions' observations.

Like-for-like caveats, stated: EmberJson's parse builds its eager DOM (numbers converted at parse); json-mojo's parse builds the lazy tape (numbers converted at access — the float differential suite prices that conversion at 1,500/1,500 bit-exact). These are each library's user-facing parse verb. On canada, the eager/lazy difference favors the lazy design by construction.

Provenance note on the `dumps` column: those cells were recorded with the pre-audit recursive emitter. The shipped serializer is the iterative walker (depth-unbounded by design); it measures neutral-to-faster on every standalone dump cell (Micro Scorecard below), but corpus re-measurement needs the gitignored EmberJson clone restored (Reproducing).

Other incumbents:

| Incumbent      | Standing                              | Status here                                                                                                                                                                 |
| -------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ehsanmok/json  | ~1.06 GB/s twitter parse (its README) | Still unverifiable: re-attempted 2026-07-03 on this pin — its stage 1 fails SIMD width inference (`_classify_chunk`, unresolved `W`). The published claim remains an open same-machine target |
| simdjson (C++) | multi-GB/s reference class            | **Measured** (same machine, gcc 16.1.1 `-O3 -march=native`, latest single-header release, DOM parse, min-of-N — `benchmarks/simdjson_bench.cpp`): twitter **5.9–6.0 GB/s**, citm **5.8–6.0**, canada **1.49–1.53**. json-mojo stands at 14% / 19% / **58%** of that ceiling — the structural-corpora gap is the roadmap                                                                                                                             |

---

## Micro Scorecard

The retired prototype's exact corpora (`benchmarks/micro.mojo`), best-column MB/s reported as min–max spans across this session's runs. Prototype cells are its historical claims (its environment is no longer constructible — see the audit); EmberJson measured under its own pin (`benchmarks/emberjson_micro_audit.mojo`, copied into the clone).

| Cell (parse)       | Prototype claimed | EmberJson today | **json-mojo today** |
| ------------------ | ----------------- | --------------- | ------------------- |
| small (39 B)       | 207               | 169             | **246–266**         |
| nested (81 B)      | 163               | 126             | **248–275**         |
| array_80 (2.9 KB)  | 350               | 153             | **458–536**         |
| str_heavy (1.8 KB) | 8,165             | 6,536           | **7,081–7,389**     |
| str_huge (18 KB)   | 13,547            | 22,990          | **19,496–20,223**   |
| floats_200 (1 KB)  | —                 | 223             | **339–447**         |

Dump cells below are the shipped iterative walker's measurements (the audit-hardening rewrite — see What Made It Fast):

| Cell (dump) | Prototype claimed | EmberJson today | **json-mojo today** |
| ----------- | ----------------- | --------------- | ------------------- |
| small       | 511               | 531             | **531–930**         |
| nested      | 522               | 515             | **702**             |
| array_80    | 952               | 816             | **1,443–1,539**     |
| str_heavy   | 21,803            | 13,073          | **24,278–33,989**   |
| str_huge    | 48,848            | 19,054          | **64,637–73,068**   |
| floats_200  | —                 | 132             | **1,177–1,207**     |

Standing: against the prototype's claims json-mojo wins or ties every cell except str_heavy parse (7,081–7,389 vs its claimed 8,165, ~−10% — its environment cannot be rebuilt, so the claim is unfalsifiable but recorded as a loss, not a tie). Against EmberJson it wins ten of twelve outright; small-doc dump quantizes to a tie at worst (both libraries are timer-tick-bound at 39 bytes), and str_huge parse trails by 13% — the price of eagerly validating string bytes at all; EmberJson's scan does less work there.

---

## Where Time Goes

Single-thread stage shares of full `parse` (`benchmarks/scaling.mojo`), after the optimization pass:

| Stage                                          | twitter | citm    | canada  | Standalone throughput |
| ---------------------------------------------- | ------- | ------- | ------- | --------------------- |
| Stage 1 — SIMD structural index                | 10%     | 14%     | 6%      | 8.5–12.2 GB/s         |
| **Stage 2 — grammar + tape (owns lazy UTF-8)** | **82%** | **86%** | **94%** | 0.77–1.44 GB/s        |
| Copy / reserve / assembly                      | 0–8%    | —       | —       | —                     |

Stage 2 is the library's entire remaining performance frontier. There is no separate UTF-8 pass — validation is folded into string validation and costs nothing on ASCII bodies.

---

## Core Scaling

N workers, each parsing its own copy `reps` times (`benchmarks/scaling.mojo`); aggregate MB/s. The per-iteration input copy is inside the loop, so high-worker decay includes copy bandwidth by design.

| Workers | twitter | citm   | canada | Efficiency band |
| ------- | ------- | ------ | ------ | --------------- |
| 1       | 847     | 1,135  | 688    | 100%            |
| 2       | 1,690   | 2,296  | 1,353  | 98–101%         |
| 4       | 3,230   | 4,492  | 2,621  | 95–99%          |
| 8       | 5,556   | 7,952  | 4,947  | 82–90%          |
| 16      | 8,911   | 10,247 | 7,949  | 56–72%          |
| 32      | 11,850  | 14,734 | 8,502  | 39–44%          |

Reading: near-linear to 4 workers (compute-bound; no allocator or lock collapse anywhere), a knee at 8 (the 7950X3D's dual-CCD topology), and SMT still adds absolute throughput to a ~15 GB/s aggregate peak.

---

## What Made It Fast

| Mechanism                                                                  | Effect                                                                                                                                                                                   |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Move-in ownership + self-guaranteed 64-byte tail padding                   | Zero owning copies on the parse path; every stage-1 block load is legal                                                                                                                  |
| Two-stage design: branchless SIMD structural index → iterative tape build  | Per-byte questions become mask arithmetic; depth is a counter, not a call stack                                                                                                          |
| Six-kind tape with raw spans (lazy everything)                             | Numbers and strings cost nothing until read; `dumps` re-emits spans verbatim — a round-tripped document serializes at memcpy class                                                       |
| Lazy per-body UTF-8 validation                                             | RFC 8259's grammar confines non-ASCII to string bodies; ASCII documents pay zero validation                                                                                              |
| SIMD string validation + in-string block skip (the optimization pass)      | str_huge parse 1,955 → 19,983 MB/s (10.2×), str_heavy 4.4×, twitter +12% — with every correctness gate unchanged                                                                         |
| Iterative dumps walker, innermost frame cached in locals (audit hardening) | Depth-unbounded serialization — no native stack, symmetric with the parser's bomb defense — measured neutral-to-faster (str_heavy dump best +20% over the recursive emitter it replaced) |
| SIMD digit-run scanning in number validation (1.1.0)                       | Digit runs hop 16 bytes per step instead of per-byte compares; canada parse 0.72–0.80 → 0.86–0.88 GB/s, now 58% of the C++ simdjson ceiling on that corpus                               |
| Eisel-Lemire in, two-digit-table integers out, stack-buffered chunk writer | Bit-exact floats (1,500/0 differential); each output byte copied exactly once                                                                                                            |
| Monomorphized comptime options                                             | Policy knobs cost zero runtime branches                                                                                                                                                  |

---

## Weaknesses and Roadmap

| #   | Weakness (measured)                                                                             | Attack                                                                                                                                                                  |
| --- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Stage 2 is 82–94% of parse; the structural corpora sit at 14–19% of the measured simdjson ceiling | Stage-1 atom hints to stop gap re-scanning; tape-append fast path (capacity is already exact-bounded — the growth branch remains); close the string/key machinery gap |
| 2   | str_huge parse trails EmberJson by 13%; str_heavy parse trails the prototype's claim by ~10%    | The eager-validation price; acceptable, revisit only after weakness 1                                                                                                   |
| 3   | ehsanmok's published 1.06 GB/s twitter claim stands above our 0.82–0.97, unverifiable           | 2026-07-03 re-attempt still fails to compile; close via weakness 1, retry each nightly                                                                                  |
| 4   | canada stands at 58% of the simdjson ceiling despite the digit-run win                          | The number-heavy residue: validate-then-reparse overlap — candidate is stage-2 emitting digit-run hints the access-time Eisel-Lemire path can reuse                     |
| 5   | Scaling knee at 8 workers                                                                       | Topology, not code (untouched dumps moves identically); NUMA/CCD pinning experiments post-v1                                                                            |

---

## Prototype Scorecard Audit

The retired prototype's PERF scorecard was audited on demand. Verdict: **honest.** Its "user-supplied" EmberJson column reproduces within noise today under EmberJson's own pin on this machine (all five cells — `benchmarks/emberjson_micro_audit.mojo` run inside the clone); its own giant-string cells match fused-single-pass physics that EmberJson independently exhibits; and it recorded its own str_huge loss, which today's data confirms was real. Its ehsanmok column remains unverifiable (that library did not compile then and does not now). The prototype's environment itself is no longer constructible (a package re-solve mixed its pinned compiler with a newer stdlib), so its own cells are historical claims — consistent, but not re-runnable.

---

## Reproducing

```bash
# One-time: the conformance corpus and the benchmark corpus are gitignored clones.
git clone https://github.com/nst/JSONTestSuite references/JSONTestSuite
git clone https://github.com/bgreni/EmberJson  references/EmberJson   # corpus + head-to-head

pixi run test                          # 36 unit tests
bash tests/run_suite.sh                # JSONTestSuite: 283 must-pass / 0 failures,
                                       #   plus the 95/95 dumps∘loads round-trip gate
python3 tests/gen_float_fuzz.py && pixi run mojo run -I . tests/floatdiff_generated.mojo
python3 tests/gen_fuzz.py       && pixi run mojo run -I . tests/fuzz_generated.mojo
python3 tests/gen_utf8_fuzz.py  && pixi run mojo run -I . tests/utf8_generated.mojo
pixi run format                        # generators emit raw source; formatting restores
                                       #   the committed bytes (regeneration is then
                                       #   byte-identical — verify with git diff)

pixi run mojo build -I . -D ASSERT=none benchmarks/run_benchmarks.mojo -o .build/bench   && .build/bench
pixi run mojo build -I . -D ASSERT=none benchmarks/micro.mojo          -o .build/micro   && .build/micro
pixi run mojo build -I . -D ASSERT=none benchmarks/scaling.mojo        -o .build/scaling && .build/scaling

# C++ simdjson ceiling (single-header release; harness pinned in-repo):
curl -sL -o .build/simdjson.h   https://github.com/simdjson/simdjson/releases/latest/download/simdjson.h
curl -sL -o .build/simdjson.cpp https://github.com/simdjson/simdjson/releases/latest/download/simdjson.cpp
g++ -O3 -march=native -std=c++17 -o .build/simdjson_bench benchmarks/simdjson_bench.cpp .build/simdjson.cpp -I .build
.build/simdjson_bench

# EmberJson head-to-head, run under ITS own pin inside the clone:
cp benchmarks/emberjson_micro_audit.mojo references/EmberJson/
cd references/EmberJson && pixi run mojo build emberjson_micro_audit.mojo
./emberjson_micro_audit && pixi run bench
```
