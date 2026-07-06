# RFC 8259 JSON Support in the Mojo Standard Library

Huynh Bao Bien, Created July 7, 2026

**Status**: Draft

## Summary

Add a dependency-free `std.json` package that parses, inspects, serializes, and performs typed conversion for RFC 8259 JSON. The proposed implementation uses owned input storage, a validated lazy tape, explicit hostile-input limits, and compile-time trait/reflection dispatch.

This proposal covers only the JSON standard-library core. JSON5, JSON Patch, Merge Patch, MessagePack, BSON, CBOR, JSONPath, JSON Schema, and canonical JSON remain outside this proposal.

## Motivation

JSON is required by package tooling, network clients, configuration systems, model-serving APIs, structured logs, and Python interoperability. Leaving the only baseline implementation to third-party resolution creates a bootstrap problem for tools that need JSON before dependencies are available and encourages incompatible value models across foundational libraries.

Mojo also needs a security baseline for untrusted structured text. A standard implementation can establish consistent behavior for UTF-8 validation, nesting limits, duplicate names, number conversion, error locations, and serialization of non-finite numbers.

Issue #478 requested JSON in 2023 and was closed while core collections and package distribution were still being established. Mojo now has the required collections, ownership tools, compile-time reflection, external standard-library contribution process, and community package channel. A working implementation can therefore be evaluated from measured behavior instead of designed from scratch.

## Goals

- Implement the RFC 8259 grammar with strict UTF-8 validation.
- Provide explicit resource and duplicate-member policies.
- Support owned documents and lazy, lifetime-safe cursors.
- Support compact and pretty serialization.
- Support typed serde through opt-in traits and reflection-derived structs.
- Remain pure Mojo with no standard-library dependency additions.
- Behave consistently on every platform supported by the Mojo standard library.
- Provide actionable errors with byte offsets and RFC 6901-style paths.

## Non-Goals

- JSON5 or other non-standard text grammars.
- JSON Patch, Merge Patch, JSONPath, or JSON Schema.
- MessagePack, BSON, CBOR, or other binary formats.
- Arbitrary-precision arithmetic. Raw number text remains lossless, while conversion targets retain explicit range checks.
- A mutable universal DOM in the first version.
- Canonical JSON or key sorting in the first version.

## Proposed API

The final names should follow maintainer feedback and existing standard-library conventions. The candidate surface is:

```mojo
from std.json import (
    Document,
    DuplicatePolicy,
    FromJson,
    ParseOptions,
    SerializeOptions,
    Serializer,
    ToJson,
    Value,
    ValueKind,
    deserialize,
    dump,
    dumps,
    load,
    loads,
    loads_bytes,
    parse,
    serialize,
    try_deserialize,
    try_parse,
)
```

Typical use:

```mojo
from std.json import deserialize, dumps, loads, serialize

var document = loads('{"name":"Mojo","values":[1,2,3]}')
print(document["name"].to[String]())
print(dumps(document))

struct Config(Defaultable, Movable):
    var name: String
    var values: List[Int]

    def __init__(out self):
        self.name = ""
        self.values = []

var config = deserialize[Config]('{"name":"Mojo","values":[1,2,3]}')
print(serialize(config))
```

### Parsing

```mojo
def parse[options: ParseOptions = ParseOptions()](var text: String) raises -> Document
def loads(var text: String) raises -> Document
def loads_bytes(var bytes: List[UInt8]) raises -> Document
def try_parse[options: ParseOptions = ParseOptions()](var text: String) -> Optional[Document]
```

Input is taken by move so the returned document owns the bytes referenced by its tape. `ParseOptions` is compile-time configuration and includes maximum depth, duplicate-member behavior, and an optional I-JSON profile.

### Lazy Values

`Document` owns source bytes and the validated tape. `Value[origin]` borrows both and exposes:

- `kind()` and `len()`.
- Object and array indexing.
- `elements()` and `members()` iteration.
- `to[T]()` typed conversion.
- Exact integer and finite-float fit checks.

The cursor cannot outlive its document because its storage origin is carried in the type.

### Serialization

```mojo
def dumps[options: SerializeOptions = SerializeOptions()](doc: Document) raises -> String
def dump(doc: Document, path: String) raises
```

Compact output is the default. Pretty formatting is compile-time configuration. NaN and infinity are always rejected because RFC 8259 has no representation for them.

### Typed Serde

```mojo
trait FromJson(ImplicitlyDeletable & Movable):
    @staticmethod
    def from_json[origin: ImmutOrigin, //](
        value: Value[origin], out result: Self
    ) raises:
        ...

trait ToJson:
    def to_json(self, mut serializer: Serializer) raises:
        ...
```

Primitive types, `Optional[T]`, `List[T]`, and `Dict[String, V]` have standard conformances. Plain structs derive through compile-time reflection without declaring either trait. Traits remain available for validation, renaming, or custom representations.

Partially initialized containers are consumed with `destroy_with` before conversion errors propagate.

## Representation

Parsing has two stages:

1. SIMD structural indexing identifies structural bytes and scalar starts while tracking string state.
2. An iterative validator builds a six-kind tape for null, boolean, number, string, array, and object values.

Each tape entry uses two machine words. Containers carry skip links, and strings and numbers retain spans into owned input until conversion is requested. The tape is process-local and is not a persistence or interchange format.

This representation gives the parser one validated source of truth for lazy access, typed deserialization, and serialization. It avoids a second parser or eagerly allocated node tree.

## Correctness and Security

- Validate UTF-8 according to RFC 3629, including overlong encodings and surrogate encodings.
- Recombine valid JSON surrogate pairs and reject malformed pairs when decoded.
- Enforce an explicit default maximum depth.
- Reject malformed and truncated input without unchecked reads.
- Preserve raw number spelling and range-check every typed conversion.
- Reject non-finite serialization.
- Make duplicate-member behavior explicit: first wins, last wins, or reject.
- Include byte offset and logical path in parse errors.
- Keep parser and serializer iteration off the native call stack for hostile nesting.

Unsafe operations are isolated behind validated bounds and documented invariants. Standard-library review should treat those invariants as part of the API-independent implementation contract.

## Performance

Correctness is required independent of performance. The implementation uses portable Mojo SIMD and has no target-specific source fork.

Performance changes require same-machine benchmarks and must not weaken conformance. The candidate repository includes corpus throughput, stage timing, scaling, and same-machine comparisons against another Mojo parser and C++ simdjson. These benchmarks should be adapted to the standard-library benchmark harness before upstreaming.

## Testing

The upstream module should include:

- Focused unit tests mirroring the source layout.
- JSONTestSuite accept/reject coverage.
- UTF-8 differential vectors.
- Float conversion differential vectors.
- Structural and malformed-input fuzz vectors.
- Parse/serialize round trips.
- Typed serde tests for primitives, optionals, recursive containers, reflected structs, custom traits, and partial-construction errors.
- Platform CI for Linux x86-64, Linux ARM64, and Apple Silicon, plus future standard-library platforms when available.
- `mojo doc --diagnose-missing-doc-strings -Werror` validation.

## Staged Contribution Plan

The implementation is larger than a normal pull request. After proposal approval, split review by stable boundaries:

1. Public options, value kinds, and internal byte/tape contracts.
2. UTF-8, string, and number validation utilities with focused tests.
3. Structural indexing and iterative tape construction.
4. `Document` and lazy `Value` access.
5. Compact and pretty serialization.
6. Typed serde traits, reflection derivation, and container conformances.
7. File helpers, conformance corpora, benchmarks, and user documentation.

No implementation pull request should be opened until maintainers approve the issue and staging strategy.

## Compatibility

- Public APIs follow normal Mojo standard-library stability policy.
- Internal tape layout remains private and may change without notice.
- Parsing defaults remain RFC 8259 compatible.
- New strictness options may be added without changing default behavior.
- Platform-specific acceleration must retain a portable fallback.

## Alternatives Considered

### Keep JSON Only in the Package Ecosystem

This is viable and remains the fallback. The package can be distributed through `modular-community`. The disadvantage is that foundational tooling cannot rely on a common JSON type or parser before dependency resolution, and ecosystem libraries may expose incompatible value models.

### Wrap a C or C++ JSON Library

This can provide high throughput but adds toolchain, linkage, ABI, and platform complexity to a foundational module. It also weakens the goal of a portable pure-Mojo baseline.

### Eager Mutable DOM

An eager tree is familiar but allocates and converts every value even when callers inspect only a few fields. A mutable DOM can be layered above the proposed lazy value surface without making every parse pay that cost.

### Python Interoperability Only

Python's `json` module is useful when Python is present, but it cannot serve standalone Mojo binaries, package bootstrapping, GPU-adjacent services, or predictable high-throughput paths.

## Packaging and Incubation

Before standard-library acceptance, publish the complete external package to the Modular community channel and use installation, compatibility, and maintenance history as incubation evidence. The package and proposed standard-library core share the Apache-2.0 WITH LLVM-exception license.

## Open Questions

- Should the initial package name be `std.json` or another namespace chosen by Modular?
- Should file helpers land initially or remain in a later `io` submodule?
- Should I-JSON mode be in the first release?
- Should reflection-derived serde land with the parser or in a follow-up proposal?
- Which error type and structured error fields best match the evolving standard library?
- Does Modular prefer source import, history-preserving subtree import, or a clean-room port into the stdlib tree?

## AI Assistance Disclosure

This draft was prepared with AI assistance and must be reviewed and owned by the human contributor before upstream submission.

Assisted-by: AI
