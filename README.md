# json-mojo

> **Version:** 1.6.0 | **Updated:** 2026-07-07

Spec-exact, SIMD-accelerated JSON for Mojo — a lazy tape engine with Python-easy verbs, zero dependencies, and a measured performance record.

```mojo
from json import loads, deserialize, serialize, dumps

var data = loads('{"name": "Alice", "scores": [95, 87, 92]}')
print(data["name"].to[String]())        # Alice
print(data["scores"][0].to[Int]())      # 95

for score in data["scores"].elements():
    print(score.to[Int64]())

print(data.at("/scores/2").to[Int]())   # RFC 6901 JSON Pointer

struct Server(Copyable, Defaultable, Movable):  # no trait needed —
    var host: String                            # serde derives both
    var port: Int64                             # directions by reflection
    def __init__(out self):
        self.host = ""
        self.port = 0

var server = deserialize[Server]('{"host":"api.example.com","port":8443}')
print(serialize(server))                # {"host":"api.example.com","port":8443}
var servers = deserialize[List[Server]](
    '[{"host":"api.example.com","port":8443}]'
)
print(dumps(data))                      # byte-faithful re-emission
```

---

| #   | Section                                     |
| --- | ------------------------------------------- |
| 1   | [Why](#why)                                 |
| 2   | [Install](#install)                         |
| 3   | [Surface](#surface)                         |
| 4   | [Runtime Model](#runtime-model)             |
| 5   | [Verification Record](#verification-record) |
| 6   | [Performance](#performance)                 |
| 7   | [Limits](#limits)                           |
| 8   | [Documents](#documents)                     |
| 9   | [License](#license)                         |

---

## Why

JSON is how software talks — every API response, every config file, every AI-agent tool call. The fastest parsers live in C++ with dependency chains and a memory model where one mistake is a vulnerability; the easy libraries live in slow interpreters. json-mojo is the marriage: simdjson-class techniques (SIMD structural indexing, a lazy six-kind tape, Eisel-Lemire numbers) in pure Mojo, behind verbs a Python user already knows. See ARCHITECTURE.md for the full purpose and contracts.

---

## Install

Not yet on a package channel. A tested modular-community recipe is prepared in
`conda.recipe/`; consume 1.6.0 from source until Mojo `1.0.0b3` reaches the
stable compiler channel and the recipe is accepted:

```bash
git clone <this repository> json-mojo
cd json-mojo && pixi install && pixi run test   # toolchain pinned by pixi.toml
```

Then build your program with this repository on the include path:

```bash
mojo build -I path/to/json-mojo your_program.mojo
```

Pure Mojo — no C toolchain, no FFI, no transitive native dependencies.

Supported Pixi targets are `linux-64`, `linux-aarch64`, and `osx-arm64`.
Windows users run through WSL; native Windows and Intel macOS are not listed
until upstream `mojo` packages exist for those targets.

---

## Surface

Sixteen functions, eleven types at the package root (ARCHITECTURE.md, Public Surface):

| Name                                                                      | Purpose                                                                                                                                                                                         |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `parse[options](var text)` / `loads(var text)` / `loads_bytes(var bytes)` | Text or bytes → `Document`, taken by move (`parse(body^)`) — zero copies                                                                                                                        |
| `try_parse[options]` / `try_deserialize[T]`                               | Non-raising twins returning `Optional`                                                                                                                                                          |
| `dumps[options](doc)`                                                     | Re-emit a document — compact by default; `SerializeOptions(pretty=True, indent=4)` for Python/JS-style indentation (`indent_byte=0x09` for tabs; `indent=0` = newlines only)                    |
| `deserialize[T]` / `serialize`                                            | Typed serde; plain structs derive both directions via reflection, no trait required                                                                                                             |
| `Document`                                                                | Owns the input and the tape; exposes its root's access surface directly                                                                                                                         |
| `Value` / `ValueKind`                                                     | The lazy cursor: `kind()`, `to[T]()`, `["key"]` / `[index]`, `elements()`, `members()`, `at("/pointer")`, `fits_int64/uint64/float64`                                                           |
| `ParseOptions` / `ParseMode` / `DuplicatePolicy` / `SerializeOptions`     | Comptime policy knobs — each combination compiles its own specialized parser                                                                                                                    |
| `FromJson` / `ToJson` / `Serializer`                                      | The conversion protocol, for custom control                                                                                                                                                     |
| `loads_lines` / `dumps_lines` / `loads_seq` / `dumps_seq`                 | JSON Lines (NDJSON) and RFC 7464 text sequences — one `Document` per record, errors name the record (1.1.0)                                                                                     |
| `load(path)` / `dump(doc, path)`                                          | File sugar — bytes reach this library's validator directly (1.1.0)                                                                                                                              |
| `apply_patch` / `merge_patch`                                             | RFC 6902 JSON Patch and RFC 7396 Merge Patch, over the public cursor surface (1.2.0)                                                                                                            |
| `ParseOptions(dialect=Dialect.JSON5)`                                     | The full JSON5 grammar — comments, trailing commas, unquoted keys, single quotes, hex, `Infinity` — `dumps` normalizes to JSON (1.2.0)                                                          |
| `msgpack` / `bson` / `cbor` siblings                                      | Binary front-ends over the stable tape contract — each decodes to a `Document` AND encodes back (`decode` / `dumps`); `json.dumps` of any decoded document is transcoding to JSON (1.2.0–1.3.0) |

### Format coverage

| Format      | Decode                                | Encode                                        | Gate                                             |
| ----------- | ------------------------------------- | --------------------------------------------- | ------------------------------------------------ |
| JSON        | `loads` — RFC 8259, spec-exact        | `dumps` — byte-faithful re-emission           | JSONTestSuite 283/0 + 95/95 round-trip           |
| JSON5       | `parse[dialect=JSON5]` — full grammar | `dumps` normalizes to JSON (valid JSON5)      | json5-tests 112/0                                |
| MessagePack | `msgpack.decode` — full for JSON data | `msgpack.dumps` — smallest-width, full        | 37+5 decode / 17 encode / 37 round-trips, 0 fail |
| BSON        | `bson.decode` — JSON-typed elements   | `bson.dumps` — int32/64+double width-selected | 16 decode / 10 encode / 16 round-trips, 0 fail   |
| CBOR        | `cbor.decode` — incl. indefinite+f16  | `cbor.dumps` — shortest-form heads            | RFC 8949 App. A: 44/17/44, 0 fail                |

Foreign types no JSON kind can hold (BSON ObjectId/datetime/binary…, CBOR byte strings/tags, msgpack bin/ext) are **rejected by name** — mapping them is a caller decision, never a silent one. Each format package imports only the public `json.tape` contract module — `json._internal` stays private to `json`.

Errors carry the byte offset **and** the RFC 6901 path of the failure:

```text
json.parse: unrecognized literal at byte 21 in /config/retries
```

Numbers are lossless raw text on the tape — a 300-digit integer round-trips exactly; `fits_*` tells you what a number can safely become before you convert.

---

## Runtime Model

The core is synchronous and CPU-bound. It owns input buffers, builds a tape, and returns owned results; it does not own a task runtime, worker pool, queue, timeout, or cancellation policy.

Use async at the I/O edge: await network/file bytes in your framework, then call `loads_bytes` / `dumps`. For batch throughput, shard independent documents across a caller-owned worker pool with explicit bounds. `load` and `dump` are blocking convenience helpers for scripts and tests, not hidden async I/O.

---

## Verification Record

Every release re-earns all of it (`pixi run test` plus `pixi run verify`;
commands in PERF.md, Reproducing):

| Gate                                        | Result                                                                        |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| JSONTestSuite (318 cases)                   | 283 must-pass / **0 failures**; implementation-defined: 12 accept / 23 reject |
| Float differential vs C `strtod`            | **1,500 / 1,500 bit-exact**, including >19-digit rounding-boundary cases      |
| Structural fuzz                             | 400/400 byte-exact round-trips; 350/350 hostile inputs without a crash        |
| UTF-8 differential (strict RFC 3629 oracle) | 424 / 424                                                                     |
| `dumps ∘ loads` idempotence                 | 95/95 corpus files, byte-exact (part of the suite gate's RESULT line)         |
| json5-tests (Dialect.JSON5)                 | 112 accept+reject cases / **0 failures**                                      |
| MessagePack vectors (generated)             | 37 accept / 5 float / 14 reject — 0 failures                                  |
| Unit battery                                | 44 / 44                                                                       |

---

## Performance

Full record with conditions, protocols, and weaknesses in PERF.md. Headlines (AMD 7950X3D, release build):

| Measure                                | Result                                                                                    |
| -------------------------------------- | ----------------------------------------------------------------------------------------- |
| Corpus parse (twitter / citm / canada) | 0.82–1.29 GB/s — **1.8–2.9× EmberJson** measured on the same machine                      |
| vs C++ simdjson (same-machine ceiling) | canada at **58%** of the reference; twitter/citm at 14–19% — the named frontier (PERF.md) |
| Corpus dumps                           | 2.3–8.3 GB/s (raw-span re-emission)                                                       |
| Giant-string parse                     | up to 20 GB/s (SIMD skip + lazy per-body UTF-8)                                           |
| 32-worker aggregate                    | ~15 GB/s parse throughput                                                                 |

---

## Limits

Stated, not hidden:

| Limit                      | Detail                                                                                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Struct derivation contract | Be `Defaultable`, or have only trivially-destructible fields                                                                                      |
| Platform                   | Pixi lock covers `linux-64`, `linux-aarch64`, and `osx-arm64`; Windows is supported through WSL until upstream Mojo ships native `win-*` packages |

---

## Documents

| Document             | Holds                                                                      |
| -------------------- | -------------------------------------------------------------------------- |
| ARCHITECTURE.md      | Purpose, contracts, type scheme, public surface, system map                |
| PERF.md              | The measured record: scorecards, stage breakdown, scaling, weaknesses      |
| references/README.md | The standards map — five vendored RFCs and the constraints drawn from each |
| .probe/SYNTAX.md     | 37 verified toolchain findings this library is built on                    |

---

## License

Apache-2.0 WITH LLVM-exception.
