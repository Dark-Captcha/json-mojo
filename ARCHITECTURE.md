# Architecture — json-mojo

> **Version:** 1.6.0 | **Updated:** 2026-07-06

Purpose, binding contracts, and system map of json-mojo — the criteria every structural decision in this library is judged against.

---

| #   | Section                                                         |
| --- | --------------------------------------------------------------- |
| 1   | [Purpose](#purpose)                                             |
| 2   | [Contracts](#contracts)                                         |
| 3   | [Audience](#audience)                                           |
| 4   | [Performance Promise](#performance-promise)                     |
| 5   | [Type Scheme](#type-scheme)                                     |
| 6   | [Public Surface](#public-surface)                               |
| 7   | [Non-Goals and Extension Paths](#non-goals-and-extension-paths) |
| 8   | [Open Decisions](#open-decisions)                               |
| 9   | [Standards](#standards)                                         |
| 10  | [System Map](#system-map)                                       |

---

## Purpose

json-mojo makes the world's default data format cost almost nothing to read and write.

JSON is not one protocol among many — it is how software talks. Every API response, every configuration file, every log pipeline, every AI-agent tool call is JSON; in the agent era the volume only multiplies, because every step of every conversation between models and tools crosses a JSON boundary. A cost on JSON is a tax on everything.

The fastest parsers ever written proved that hardware can eat JSON at gigabytes per second — but they live in C and C++: dependency chains that fight every build system, and a memory model where one mistake is a vulnerability. The easy libraries live in slow interpreters. Nobody has married the two. Mojo is the first language that can — portable SIMD up through AVX-512 as a first-class citizen, an ownership model that makes leaks and use-after-free unrepresentable, and syntax a Python user already reads. That marriage is this library's reason to exist.

Every ecosystem's JSON library sets that ecosystem's ceiling. Mojo has no native answer, and an ecosystem built for AI workloads will live and die by JSON throughput. Solving it correctly and at hardware speed, once, at the bottom of the stack, raises the ceiling for every Mojo program at once.

---

## Contracts

Everything the library does serves one of these four contracts. Anything that serves none of them does not belong.

| #   | Contract                     | Obligation                                                                                                                                                                                                                                                                                   |
| --- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Spec-exact correctness       | RFC 8259 to the byte — every accept and every reject citable to a section, verified against the public conformance corpus. A fast parser that is 99% correct is not 99% useful; it is a security-bug generator. Speed never buys a conformance exception.                                    |
| 2   | Hardware-speed processing    | SIMD-first by design, not as an afterthought: the machine's vector width is the budget, gigabytes per second is the class. Portability comes from Mojo's portable SIMD types (one source, any target width); equivalence is enforced by a differential scalar mirror in the test suite.      |
| 3   | Python-easy, dependency-free | One obvious line to parse, one to serialize. No C toolchain, no linker flags, no submodules — pure Mojo, installed like any package, memory-safe by construction.                                                                                                                            |
| 4   | Safe under hostile input     | JSON is the format of untrusted data — network payloads, user uploads, model outputs. Malformed UTF-8, nesting bombs, pathological numbers, and truncated documents are inputs to handle, not edge cases: explicit limits, total validation, no undefined behavior for any input whatsoever. |

**The purpose test:** every proposed feature must name the contract it serves. A feature that names none is out of scope, regardless of how useful it sounds.

---

## Audience

| Priority  | Audience                                                                         | Requirement                                                                         |
| --------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Primary   | Libraries and services — HTTP clients, agent frameworks, log processors, loaders | Parse thousands of documents per second; inherit every weakness of their JSON layer |
| Secondary | Application and script authors                                                   | One import, familiar verbs, results that behave like the data they represent        |

Both audiences ride one engine. Ergonomics is a layer, never a fork.

---

## Performance Promise

json-mojo is not "a JSON implementation." It is the fastest JSON parser and serializer available to Mojo — measured on the standard corpus against every incumbent, including C++ simdjson. Correctness is the entry fee (contract 1); this promise is the reason the library exists at all.

### The Field

| Incumbent                                                | Published standing                                                                       | Stated or visible limitation                                                                                                                     |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| [ehsanmok/json](https://github.com/ehsanmok/json) (Mojo) | ~1.06 GB/s parse on `twitter.json` (own README) via simdjson stage-1 techniques in Mojo  | Names its own gaps: "no Eisel-Lemire float fast path, no AVX-512 64-byte chunks"; ships C++ simdjson as a transitive dependency for its FFI shim |
| [EmberJson](https://github.com/bgreni/EmberJson) (Mojo)  | ~0.4 GB/s parse on `twitter.json`, ~0.2 on float-heavy `canada.json` (own bench records) | No vectorized core; float parsing visibly dominates — yet its lazy reflection path reaches ~3.7 GB/s, proving laziness pays in Mojo              |
| [simdjson](https://github.com/simdjson/simdjson) (C++)   | The multi-GB/s reference class: DOM and On-Demand APIs                                   | The reasons this library exists: build-system friction and a memory model where one mistake is a vulnerability                                   |

The prototype's archival record adds two facts: it already outran both Mojo incumbents on most micro-benchmark cells — every serialization cell decisively — and its known weakness was an owning input copy on the parse path. Nobody, in Mojo or any memory-safe language with Python ergonomics, has assembled the complete simdjson playbook plus the pieces simdjson's Mojo imitators say they are missing. That assembly is this library.

### Why the Promise Is Credible

| Technique                                                                                                             | Evidence                                                                                                                |
| --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Stage-1 structural indexing — 64-byte SIMD blocks, table-lookup byte classification, carry-less-multiply string-state | Proven in pure Mojo by ehsanmok/json; carry-less multiply probed working in this repository (`.probe/probe_clmul.mojo`) |
| Eisel-Lemire number parsing (the named gap)                                                                           | Requires a 128-bit widening multiply — probed working in this repository (`.probe/probe_mul128.mojo`)                   |
| AVX-512 64-byte lanes (the named gap)                                                                                 | First-class in Mojo's portable SIMD types — the language advantage                                                      |
| Lazy, On-Demand-class access API                                                                                      | EmberJson's lazy path already demonstrates the ceiling in Mojo                                                          |
| Serialization: Teju-class shortest float formatting, SIMD escaping, stack-buffered chunk writing                      | The prototype's dominant cells; Teju Jagua is Apache-2.0                                                                |
| Comptime-specialized parse options, no FFI boundary anywhere                                                          | Mojo-unique — configuration costs zero runtime branches, and there is no C toolchain to fight                           |

### Measurement Discipline

A promise is only as good as its proof. The scorecard lives in PERF.md and every release re-earns it.

| Rule           | Detail                                                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Corpus         | The industry trio — `twitter.json`, `citm_catalog.json`, `canada.json` — plus JSONTestSuite as the correctness gate speed never buys out of |
| Conditions     | Same machine, same day, min-time protocol, competitors built at their released best (`ASSERT=none` posture on all Mojo builds)              |
| Like for like  | This DOM versus their DOM; this lazy layer versus simdjson On-Demand — no category tricks                                                   |
| No silent wins | Losing cells are published with the winning number, not omitted                                                                             |

### What the Promise Forces on the Design

A two-stage architecture (SIMD structural index feeding a tape), a lazy access layer as a first-class API — a DOM alone cannot beat On-Demand — comptime-parameterized options, Eisel-Lemire and Teju-class number paths in both directions, and zero owning copies on the parse path.

---

## Type Scheme

Every type is supported through three layers, each with exactly one source of truth. Adding a supported type touches one layer, in one place — duplication is structurally impossible.

### Layer 1 — Wire Kinds

RFC 8259 defines exactly six kinds; the tape alphabet is those six tags and never grows.

| Kind      | Tape representation                                                                                                                                                                                                                                   |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `null`    | Tag only                                                                                                                                                                                                                                              |
| `boolean` | Tag carries the value                                                                                                                                                                                                                                 |
| `number`  | Raw JSON number-text span — parsed into a concrete type only when asked. `Int64`, `UInt64`, `Float64`, and arbitrary-precision integers are four _interpretations_ of one kind, not four kinds; the JSON parser never converts, so it never truncates |
| `string`  | Raw JSON string-body span, UTF-8-validated at parse; unescaped on demand. Strict JSON escape-free strings slice out of the input zero-copy; binary front-ends copy validated text into a JSON-valid arena; JSON5 spellings carry `FLAG_REENCODE`      |
| `array`   | Tag plus a skip-link to the container's end — lean tape, forward iteration is the cheap direction                                                                                                                                                     |
| `object`  | Tag plus a skip-link to the container's end — member lookup scans forward and early-exits, honoring the parse-time duplicate policy (members shadowed under `last_wins` are invisible to lookup, iteration, `len`, and `dumps`)                       |

The contract has a front door in code: the public `json.tape` module exports exactly the symbols a front-end may use (tags, flags, entry accessors, `make_word0`, `skip_past`, the span decoders and number readers, plus arena helpers for validated string and number spans) — format packages import it and the public `Document`/`Serializer`/`Value` surfaces, never `json._internal.*`. Spans-until-asked is also the lazy architecture the Performance Promise forces — this layer _is_ the On-Demand design. Typed deserialization and the serializer are both consumers of the same tape; a second parser never exists. The entry layout above — uniform two-word records, `[tag:8 | flags:8 | a:48][b:64]` — is the **stable contract of extension tier 2**: a binary front-end emits this tape over a JSON-valid document arena and inherits every consumer unchanged. `FLAG_ARENA` remains reserved; current front-ends keep all spans in the document-owned buffer.

### Layer 2 — The Protocol

Two traits are the entire conversion machinery, and one generic gateway replaces a method per type:

```mojo
trait FromJson:   # how a type reads itself out of a Value
trait ToJson:     # how a type writes itself into a Serializer

value.to[Int64]()      # one method name — comptime-dispatched
value.to[Float64]()    # to the FromJson conformance of the target
value.to[MyStruct]()   # structs derive via reflection — no conformance
```

The honest mechanics under the gateway, settled by probes (`.probe/SYNTAX.md`, findings 20–37): `__extension` retroactive conformance exists on this toolchain, so primitives (`Bool`, `String`, every SIMD scalar width), `Optional`, `List`, and `Dict` conform to `FromJson`; all containers conform to `ToJson`. Accumulating container reads consume a partially initialized container with `destroy_with` before propagating an element error, preserving ownership on every raising path. Extensions must live in the trait's own module. Plain structs need no conformance in either direction — `to[T]`, `deserialize[T]`, and `serialize` derive them through the reflection field walk; conforming to a trait is only for custom control.

Numbers get one honest introspection surface instead of guesswork: `kind()`, plus — for numbers — whether the value fits `Int64`, fits `UInt64`, converts to a finite `Float64` (IEEE 754 round-to-even — overflow is the only refusal), or exceeds all three; the raw span is always available.

### Layer 3 — The Bindings

Reading (`to[T]` / `deserialize[T]`): `Bool`; every integer width `Int8`…`Int64`, `UInt8`…`UInt64`, `Int` (narrow targets are exact-or-error, never a silent truncation); `Float32`/`Float64`; `String`; `Optional[T]` (missing member and `null` both read as `None`); `List[T]`; `Dict[String, V]`; and structs via compile-time reflection with zero ceremony — no conformance declared (be `Defaultable`, or have only trivially-destructible fields). Containers compose recursively and may contain reflection-derived structs.

Writing (`serialize` / `dumps`): everything — the same scalar tower plus `List[T]`, `Dict[String, V]`, `Optional[T]`, and reflection-derived structs, composing recursively.

### Settled Edges

| Edge                | Ruling                                                                                                                                                                                                                                                                 |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Arbitrary precision | Parse and serialization are lossless always — raw digits in, exact digits out. Arbitrary-precision _arithmetic_ is a numerics library's job; a future big-integer conformance is one trait implementation away, and nothing this library does ever destroys the digits |
| Endianness          | JSON is text; it has no byte order. The in-memory tape is native-order and never leaves the process — a non-issue by construction                                                                                                                                      |
| Unicode             | UTF-8 validation at the boundary is mandatory (hostile-input contract); escape decoding incl. surrogate pairs is lazy; raw and decoded access both exist — pipelines want the bytes, applications want the text                                                        |

---

## Public Surface

Two layers, one engine: a surface the README shows in five lines, over a core whose stability is itself a promise (extension tier 2).

### Surface — the everyday 99%

```mojo
def parse[options: ParseOptions = ParseOptions()](var text: String) raises -> Document
def loads(var text: String) raises -> Document   # parse with defaults — the Python-named verb
def loads_bytes(var bytes: List[UInt8]) raises -> Document  # network bodies are bytes
def try_parse[options: ParseOptions = ParseOptions()](var text: String) -> Optional[Document]

def dumps[options: SerializeOptions = SerializeOptions()](value) raises -> String
def deserialize[T](text) raises -> T     # typed serde — never materializes a DOM
def try_deserialize[T](text) -> Optional[T]
def serialize[T](value) raises -> String

# 1.1.0, additive: whole documents in and out (engine-neutral composition)
def loads_lines(var text) raises -> List[Document]   # JSON Lines / NDJSON
def dumps_lines(docs) raises -> String
def loads_seq(var text) raises -> List[Document]     # RFC 7464 text sequences
def dumps_seq(docs) raises -> String
def load(path) raises -> Document                    # file sugar
def dump(doc, path) raises

# 1.2.0, additive: extension tier 3's first residents
def apply_patch(doc, patch) raises -> Document       # RFC 6902
def merge_patch(doc, patch) raises -> Document       # RFC 7396
```

(`loads_bytes` is a recorded freeze amendment: the fuzz layer requires a bytes
entry point, and invalid UTF-8 must reach this library's validator rather than
a decoding layer.)

`ParseOptions` is the reserved comptime slot (extension tier 1). Version one carries policy fields only, with defaults chosen by hot-path analysis, not convention:

| Field        | Default      | Performance rationale                                                                                                                                                                                                                                                                                         |
| ------------ | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `duplicates` | `first_wins` | Early-exit member lookup on a skip-link tape; parsing pays nothing, so `len()` and iteration see members as written. `last_wins` (Python semantics) pays per-key detection at parse time and shadows the superseded member on the tape — lookup stays early-exit; `reject` pays the same detection and raises |
| `max_depth`  | `1024`       | One register compare per container; stage 2 walks iteratively, so the value is pure bomb defense                                                                                                                                                                                                              |
| `mode`       | `standard`   | `i_json` (RFC 7493) flips duplicates to reject and the BOM to an error                                                                                                                                                                                                                                        |
| `dialect`    | `json`       | Which TEXT grammar is read (tier 1): `json5` opts into the full JSON5 grammar via a dedicated scalar scanner onto the same tape; the RFC 8259 engine and its promise are untouched by erasure                                                                                                                 |

Why these are COMPTIME parameters and not runtime keywords (`loads(text, dialect=...)`): a runtime knob taxes every caller — both engines live in every binary, plus a branch deciding between them on every parse — while a comptime knob monomorphizes. Each distinct `ParseOptions` value compiles its own specialized parser; untaken `comptime if` branches ERASE (finding 16), so the default parser is byte-identical to one built from a library with no dialects in it — the Performance Promise holds by construction, not by branch prediction. Dead code stays dead too: a program that never names `Dialect.JSON5` never compiles the JSON5 scanner or its Unicode identifier tables. And the knobs are typed comptime values, so a misspelled option is a compile error, never a runtime surprise. The cost, stated: a dialect cannot be selected from runtime data inside the library — a caller deciding by file extension writes one branch at the call site, each arm still fully specialized.

Duplicate detection (`last_wins` / `reject` / `i_json`) compares member names by CHARACTER (RFC 7493 §2.3) — an escaped spelling of the same name cannot evade it — matching the lookup path, which decodes escaped names before comparing. Two behaviors are fixed rather than fields: a leading BOM is skipped (a once-per-document 3-byte check; RFC 8259 §8.1 sanctions ignoring it, and `i_json` rejects it), and trailing non-whitespace after the document is rejected (once-per-document EOF check; trailing whitespace itself is grammar-legal).

Unpaired surrogates in escapes are rejected always — not policy: Mojo Strings are UTF-8 and a lone surrogate is unencodable, so acceptance would break the library's own string-soundness invariant.

Grammar supersets join post-v1 as a typed field with a default that preserves every existing caller: `dialect: Dialect = Dialect.JSON`, gaining values like `Dialect.JSON5` — a comptime value-struct with constants, never a string. `dialect` answers "which text grammar am I reading" (binary wire formats are front-end libraries, never dialect values); `mode` answers "how strict within it". Two knobs, orthogonal, both typed.

### Core — the engine room, public and contract-stable

| Name                                | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Document`                          | The parse result: owns the input String (taken by move) plus the six-kind tape — ownership lets it guarantee its own 64-byte SIMD tail padding via `reserve` (probed). Exposes its root's entire access surface (`doc["key"]`, `elements()`, `to[T]`), so `loads` returns it directly and no cursor can outlive its bytes                                                                                                                                                                   |
| `Value` / `ValueKind`               | Lazy cursor into the tape: `kind()`, `to[T]()`, `value["key"]` / `value[index]`, `elements()` for arrays, `members()` for objects (RFC 8259's own nouns), RFC 6901 `at("/path")`, number introspection `fits_int64` / `fits_uint64` / `fits_float64` plus the raw span. A `Value` borrows its `Document` with an inferred origin: access chains and loops never name a lifetime; storing a cursor beyond its document is the one expert case, and the compiler refuses the dangling version |
| `ParseOptions` / `SerializeOptions` | The comptime knobs; `ParseMode` and `DuplicatePolicy` are their typed field values                                                                                                                                                                                                                                                                                                                                                                                                          |
| `FromJson` / `ToJson`               | The conversion protocol (Type Scheme, Layer 2)                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `Serializer`                        | What `ToJson` implementations write into — Writer-backed                                                                                                                                                                                                                                                                                                                                                                                                                                    |

Twenty-seven public names in total — sixteen functions (the eight frozen at 0.1.0: `parse`, `try_parse`, `loads`, `loads_bytes`, `dumps`, `deserialize`, `try_deserialize`, `serialize`; six added at 1.1.0: `loads_lines`, `dumps_lines`, `loads_seq`, `dumps_seq`, `load`, `dump`; two at 1.2.0: `apply_patch`, `merge_patch`), eleven types (`Dialect` joined at 1.2.0). The `msgpack`, `bson`, and `cbor` sibling packages each add `decode` and `dumps` under their own namespaces — every binary format is bidirectional over the tape contract as of 1.3.0. `Member`, the yield type of `members()`, is package-public but deliberately un-exported — callers meet it through iteration, like a stdlib dict entry.

### Decisions This Surface Settles

| Decision            | Ruling                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Error model         | `raises` carrying byte offset and path context; `try_` twins return `Optional` — a parser's errors are API, and hostile input deserves precise, safe reporting                                                                                                                                                                                                                                                                                                                               |
| Default entry point | The lazy `Document`/`Value` cursor is the only engine; `loads` is sugar reaching its root. On-Demand is the default, not an expert mode                                                                                                                                                                                                                                                                                                                                                      |
| Mutation            | The tape is immutable. Construction flows through the serde path; in-place document editing is deferred — a mutable tape forfeits the memory story and the speed story at once                                                                                                                                                                                                                                                                                                               |
| Input ownership     | The document takes the input by move (`var text: String`) — zero copies without one lifetime annotation: `parse(body^)` hands the buffer over, temporaries need nothing, keeping your text is an explicit `text.copy()`. Ownership is also what makes stage 1 legal: 64-byte SIMD blocks read past the text's end, and the owning document guarantees its own tail padding — a borrowed view never could. A zero-copy borrowed view is a post-v1 candidate behind an origin-ergonomics probe |

### Zero-Cost Discipline

Multi-protocol support must never tax the strict path. Two mechanisms carry that guarantee, and two costs are named rather than hidden.

| Mechanism / cost              | Detail                                                                                                                                                                             |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Monomorphized options         | Each `ParseOptions` value compiles its own specialized parser; disabled features erase at compile time (comptime-if DCE, probed) — zero runtime branches for features that are off |
| Closed tape alphabet          | Six kinds, forever: extensions map into them or are refused — consumers stay untaxed no matter how many front-ends exist                                                           |
| Named cost: binary size       | One parser copy per instantiated options combination; real programs use one or two                                                                                                 |
| Named cost: the depth counter | The stack-safety limit is the one irreducible runtime check — approximately one register                                                                                           |

---

## Non-Goals and Extension Paths

| Excluded                                | Reason                                                                 | Belongs to                                                                        |
| --------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Query engine (JSONPath, RFC 9535)       | Selection expressions are a language of their own                      | A library that builds on this one                                                 |
| Schema validation                       | A constraint language above the data layer                             | A library that builds on this one                                                 |
| Native Windows package target           | Mojo is currently installed on Windows through WSL, not native `win-*` | Add when upstream `mojo` packages and a supported runner exist for native Windows |
| Additional binary foreign-type mappings | BSON/CBOR/MessagePack can encode data outside JSON's six-kind alphabet | Explicit opt-in policy knobs; never a silent default                              |

Struct binding, JSON Lines/RFC 7464 I/O, JSON5, RFC 6902/RFC 7396 patches, and the three binary siblings are now settled in scope and shipped.

### Extension Paths

Non-goals are rulings on the v1 core, not locked doors. Each class of exclusion has a designed comeback path, and v1 carries exactly two obligations to keep those paths open.

| Tier | Excluded class                                       | Future form                                                                                                                                        | What v1 must do about it now                                                                                                 |
| ---- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1    | Grammar supersets — JSON5, comments, trailing commas | `dialect: Dialect` values on the parse-options parameter: branches erase at compile time, so the strict path pays zero when a dialect is off       | Reserve the comptime options parameter in the v1 signature (policy knobs only), so the `dialect` field never breaks a caller |
| 2    | Different wire formats — BSON, CBOR, MessagePack     | Sibling front-end libraries that decode into this library's tape — every consumer (`Value`, `to[T]`, serde, serialization) works on them unchanged | Treat the tape layout and `Value` API as a stable, documented contract — not a private detail                                |
| 3    | Document operations — JSONPath, Patch, Schema        | Independent libraries consuming the public `Value` surface like any other caller                                                                   | Nothing — the public API is already the extension point                                                                      |

---

## Open Decisions

None. Every design question raised in this document has been settled by ruling or resolved by probe — the record lives in `.probe/SYNTAX.md` (findings 13–19 from the probe phase; findings 20–37 taught by the compiler during the build, including the `__extension` rules that shaped Layer 2's final form).

---

## Standards

Every byte this library parses or emits has a named authority. The vendored specification texts, the linked external standards, and the design constraints drawn from each live in [references/README.md](references/README.md). Module headers cite entries from that index rather than restating specification text.

---

## System Map

```text
json/
├── __init__.mojo        # re-exports only — the package root's public names
├── options.mojo         # ParseOptions, SerializeOptions, ParseMode, DuplicatePolicy
├── document.mojo        # Document + parse / try_parse / loads / loads_bytes
├── value.mojo           # Value, ValueKind, Member, iterators, FromJson + conformances,
│                        #   the to[T] gateway, the reflection read walk
├── io.mojo              # JSON Lines, RFC 7464 sequences, load/dump file sugar
├── patch.mojo           # RFC 6902 + RFC 7396 over the public Value surface (tier 3)
├── serde.mojo           # ToJson + conformances, deserialize / try_deserialize / serialize
├── serializer.mojo      # Serializer + dumps (iterative tape re-emission) + SIMD escaping
├── tape.mojo            # the tier-2 contract's PUBLIC front door (re-exports)
└── _internal/
    ├── bytes.mojo       # the byte-constant alphabet (RFC 8259)
    ├── simd.mojo        # lane idioms: classification tables, prefix-XOR, escape scanner
    ├── stage_one.mojo   # the SIMD structural indexer
    ├── tape.mojo        # stage 2: grammar validation + tape build + lazy UTF-8 gate
    ├── json5.mojo       # Dialect.JSON5 scalar scanner + tape builder (tier 1)
    ├── unicode_id.mojo  # GENERATED by tests/gen_unicode_id.py (ES5.1 identifiers)
    ├── unicode.mojo     # UTF-8 validation, escape decoding
    ├── number.mojo      # Eisel-Lemire in; integer writers; stdlib shortest-round-trip
    │                    #   floats out via the Writer protocol
    ├── pow5_table.mojo  # GENERATED by tests/gen_pow5_table.py
    └── writer.mojo      # ChunkWriter — the stack-buffered output sink
```

Dependency direction — imports point down, with one deliberate upward edge out of `_internal/`:

```text
__init__ ──→ { document, options, serde, serializer, value }
serde ──→ { document, options, serializer, value }     io ──→ { document, serializer }
patch ──→ { document, serializer, value }     json5 ──→ { bytes, tape, unicode, unicode_id, options }
document ──→ { options, value, _internal/{simd, stage_one, tape} }
serializer ──→ { document, options, value, _internal/{bytes, number, tape, writer} }
value ──→ _internal/{number, tape, unicode}
stage_one ──→ simd     tape ──→ { stage_one, unicode, options }     unicode ──→ bytes
number ──→ { bytes, pow5_table, writer }     options, simd, writer ──→ (leaf)
```

`document` imports `value` (a parse returns the cursor's home); `value` never imports `document` — the once-anticipated mutual edge turned out one-way. `tape → unicode` exists because stage 2 owns the lazy per-body UTF-8 gate; `tape → options` is the one edge pointing up out of `_internal/` — the tape builder monomorphizes over the public `ParseOptions`, and `options` is itself a leaf. Everything is strictly acyclic.

The verification and measurement assets around the package: `tests/run_tests.mojo` (unit battery), `tests/suite_checker.mojo` + `tests/run_suite.sh` (the JSONTestSuite gate), four `tests/gen_*.py` generators with their committed generated suites (float differential, structural fuzz, UTF-8 differential, the pow5 table — generator and output are one unit), and `benchmarks/{run_benchmarks, micro, scaling, compare_emberjson, emberjson_micro_audit}.mojo` (see PERF.md).
